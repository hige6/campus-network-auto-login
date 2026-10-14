[CmdletBinding()]
param(
    [switch]$Setup,
    [switch]$Watch,
    [switch]$Probe,
    [switch]$LibraryOnly,
    [ValidateRange(60,3600)][int]$Interval = 60
)
$ErrorActionPreference = 'Stop'
$Base = 'http://172.16.253.3'
$Portal = 'http://172.16.253.3:801/eportal/'
$CredentialFile = Join-Path $PSScriptRoot 'credential.xml'
$SettingsFile = Join-Path $PSScriptRoot 'settings.json'

function Get-CampusText([string]$Url) {
    # Use a direct connection, independent of Windows/browser proxy settings.
    $request = [Net.HttpWebRequest]::Create($Url)
    $request.Proxy = $null
    $request.Timeout = 12000
    $request.ReadWriteTimeout = 12000
    $request.AllowAutoRedirect = $false
    $request.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
    $response = $request.GetResponse()
    try {
        if ([int]$response.StatusCode -ne 200) { throw '服务器返回了异常的 HTTP 状态。' }
        $stream = $response.GetResponseStream()
        # Some gateway assets are gzip files without a Content-Encoding header.
        $memory = [IO.MemoryStream]::new()
        $stream.CopyTo($memory)
        $bytes = $memory.ToArray()
        $memory.Dispose()
        if ($bytes.Length -gt 2 -and $bytes[0] -eq 31 -and $bytes[1] -eq 139) {
            $source = [IO.MemoryStream]::new($bytes)
            $gzip = [IO.Compression.GZipStream]::new($source,[IO.Compression.CompressionMode]::Decompress)
            $target = [IO.MemoryStream]::new()
            $gzip.CopyTo($target)
            $bytes = $target.ToArray()
            $gzip.Dispose(); $source.Dispose(); $target.Dispose()
        }
        return [Text.Encoding]::GetEncoding(936).GetString($bytes)
    } finally { $response.Dispose() }
}

function ConvertFrom-CampusJson([string]$Text) {
    $clean = $Text.Trim()
    if ($clean.StartsWith('{')) { return ($clean | ConvertFrom-Json) }
    if ($clean -match '^campus\s*\((\{[\s\S]*\})\)\s*;?\s*$') {
        return ($Matches[1] | ConvertFrom-Json)
    }
    throw '校园网接口返回了无法识别的内容。'
}

function Test-CampusInternet {
    # Require exact public connectivity-test content; redirects/captive pages fail.
    $checks = @(
        @{url='http://www.msftconnecttest.com/connecttest.txt'; expected='Microsoft Connect Test'},
        @{url='http://detectportal.firefox.com/canonical.html'; expected='success'}
    )
    foreach ($check in $checks) {
        try {
            if ((Get-CampusText $check.url).Trim() -ceq $check.expected) { return $true }
        } catch { }
    }
    return $false
}

function Get-CampusStatus {
    $device = ConvertFrom-CampusJson (Get-CampusText "$Base/drcom/chkstatus?callback=campus")
    $device | Add-Member -NotePropertyName kernel_result -NotePropertyValue $device.result -Force
    # chkstatus provides device context, but its result is not the Portal session state.
    $query = [ordered]@{
        c='Portal'; a='online_list'; callback='campus'
        user_account='drcom'; user_password='123'
        wlan_user_mac=$device.ss4; wlan_user_ip=$device.v46ip
        curr_user_ip=$device.v46ip; jsVersion='3.3.2'
    }
    $device.result = -1
    $device | Add-Member -NotePropertyName status_source -NotePropertyValue 'Portal online_list' -Force
    try {
        $reply = ConvertFrom-CampusJson (Get-CampusText ($Portal + '?' + (New-CampusQuery $query)))
        if ([string]$reply.result -in @('1','ok')) {
            $device.result = 1
        } elseif ([string]$reply.result -eq '0') {
            $emptyMessage = '"\u5728\u7ebf\u6570\u636e\u4e3a\u7a7a"' | ConvertFrom-Json
            if ([string]$reply.msg -eq $emptyMessage) { $device.result = 0 }
            # Other errors (including a query failure) mean unknown, not offline.
        }
    } catch { $device.result = -1 }
    $device | Add-Member -NotePropertyName portal_result -NotePropertyValue $device.result -Force
    # A working Internet connection should never trigger another login, even if
    # the school's session query is stale. This does not identify the account.
    $internet = Test-CampusInternet
    $device | Add-Member -NotePropertyName internet_access -NotePropertyValue $internet -Force
    if ($internet) {
        $device.result = 1
        $device.status_source = 'Internet connectivity verified'
    }
    return $device
}

function ConvertTo-IpNumber([string]$Ip) {
    $parts = $Ip.Split('.')
    if ($parts.Count -ne 4) { throw '未能获取有效的校园网 IPv4 地址。' }
    [long]$value = 0
    foreach ($part in $parts) {
        [int]$octet = 0
        if (-not [int]::TryParse($part,[ref]$octet) -or $octet -lt 0 -or $octet -gt 255) { throw '未能获取有效的校园网 IPv4 地址。' }
        $value = $value * 256 + $octet
    }
    return $value
}

function Get-CampusMethod([string]$Config, [string]$Ip) {
    if ($Config -notmatch 'pageSetting\s*=\s*2\s*;') { throw '学校认证配置已变化，需要更新程序。' }
    $entries = [regex]::Matches($Config,'ipPageAry\[(\d+)\]\s*=\s*"([^"]*)"')
    $ipValue = ConvertTo-IpNumber $Ip
    $defaultMethod = $null
    foreach ($entry in $entries) {
        $fields = $entry.Groups[2].Value.Split('|')
        if ($fields.Count -lt 8) { continue }
        $method = [int]$fields[$fields.Count-2]
        if ($entry.Groups[1].Value -eq '0') { $defaultMethod = $method; continue }
        if ($fields[5] -ne '1') { continue }
        $starts = $fields[1].Split(';'); $ends = $fields[2].Split(';')
        for ($i=0; $i -lt $starts.Count; $i++) {
            if ($ipValue -ge (ConvertTo-IpNumber $starts[$i]) -and $ipValue -le (ConvertTo-IpNumber $ends[$i])) { return $method }
        }
    }
    if ($null -eq $defaultMethod) { throw '未找到学校的 IP 认证配置。' }
    return $defaultMethod
}

function New-CampusQuery($Data) {
    ($Data.GetEnumerator() | ForEach-Object {
        [Uri]::EscapeDataString([string]$_.Key) + '=' + [Uri]::EscapeDataString([string]$_.Value)
    }) -join '&'
}

function Get-CampusLoginError($Reply, $Credential, [string]$Account) {
    $code = [string]$Reply.ret_code
    $labels = @{
        '1'='账号或密码被拒绝'; '2'='当前设备 IP 已在线'
        '3'='认证服务器繁忙'; '4'='未知认证错误'
        '5'='网络设备认证握手失败'; '6'='网络设备认证握手超时'
        '7'='账号认证失败'; '8'='账号认证超时'
        '9'='注销失败'; '10'='注销超时'; '11'='其他认证错误'
        '998'='认证参数不完整'
    }
    $reason = $labels[$code]
    if (-not $reason) { $reason = '认证被拒绝' }
    $detail = [string]$Reply.errcode
    if (-not $detail -and $Reply.msg) {
        $detail = [string]$Reply.msg
        # The official page decodes Portal msg as base64-encoded GBK.
        if ($detail.Length % 4 -eq 0 -and $detail -match '^[A-Za-z0-9+/]+={0,2}$') {
            try { $detail = [Text.Encoding]::GetEncoding(936).GetString([Convert]::FromBase64String($detail)) } catch { }
        }
    }
    # Show only selected diagnostic fields, never a raw response or request URL.
    $secrets = @($Credential.GetNetworkCredential().Password, $Account, $Credential.UserName, ($Credential.UserName -split '@')[0])
    foreach ($secret in $secrets) {
        if ($secret) {
            foreach ($variant in @($secret,[Uri]::EscapeDataString($secret))) { $detail = $detail.Replace($variant,'[已隐藏]') }
        }
    }
    $detail = [regex]::Replace($detail,'https?://\S+','[地址已隐藏]')
    $detail = [regex]::Replace($detail,'<[^>]*>|[\x00-\x1f\x7f]',' ')
    if ($detail.Length -gt 400) { $detail = $detail.Substring(0,400) }
    $safeCode = if ($code -match '^\d{1,6}$') { $code } else { '未知' }
    return "登录被拒绝。错误码=$safeCode；原因=$reason；详情=$detail"
}

function Invoke-CampusLogin($Status, $Credential, [string]$Suffix, [int]$Method) {
    if ($Method -ne 1) { throw '当前网络使用其他认证协议，请通过网页登录并联系维护者更新程序。' }
    $account = $Credential.UserName
    if ($account -notmatch '@' -and $Suffix) { $account += $Suffix }
    # These fields match the gateway login_portal() implementation (a42.js).
    $data = [ordered]@{
        c='Portal'; a='login'; callback='campus'; login_method=1
        user_account=$account; user_password=$Credential.GetNetworkCredential().Password
        wlan_user_ip=$Status.v46ip; wlan_user_ipv6=$Status.myv6ip
        wlan_user_mac=$Status.ss4; wlan_ac_ip=''; wlan_ac_name=''; jsVersion='3.3.2'
    }
    try {
        $reply = ConvertFrom-CampusJson (Get-CampusText ($Portal + '?' + (New-CampusQuery $data)))
    } catch {
        # Do not print exception URLs: the gateway uses credentials in its query.
        throw '登录请求失败或超时，请检查是否已连接校园网。'
    } finally { $data.user_password = $null }
    if ([string]$reply.ret_code -eq '2') {
        $verified = Get-CampusStatus
        if ([string]$verified.result -eq '1') {
            Write-CampusMessage "当前设备已经在线，无需重复登录。"
            return
        }
        # Avoid repeatedly authenticating an IP that the Portal says is occupied.
        $script:StopCampusWatch = $true
        throw '认证服务器提示设备 IP 已在线，但联网检测尚未确认。请检查网页登录状态，将暂缓重复认证。'
    }
    if ([string]$reply.result -notin @('1','ok')) {
        throw (Get-CampusLoginError $reply $Credential $account)
    }
    Start-Sleep -Seconds 2
    try { $verified = Get-CampusStatus } catch { $verified = $null }
    if ($null -eq $verified -or [string]$verified.result -ne '1') {
        Write-CampusMessage '认证服务器已接受登录，但暂未确认外网可用；程序会继续检测。' -ForegroundColor Yellow
        if ($Watch) {
            $script:StopCampusWatch = $true
            Write-CampusMessage '暂缓重复认证，后台继续检查网络状态。' -ForegroundColor Yellow
        }
        return
    }
    if ($verified.internet_access) {
        Write-CampusMessage '登录成功，已验证外网连接。'
    } else {
        Write-CampusMessage '学校接口确认已在线，但暂未验证外网连接。' -ForegroundColor Yellow
    }
}

function Write-CampusMessage {
    param([string]$Message, [string]$ForegroundColor)
    $script:LastLoginMessage = $Message
    Write-Host $Message
}

function Save-CampusState([string]$State, [string]$Message) {
    $entry = [ordered]@{state=$State; message=$Message; time=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); pid=$PID}
    $temp = Join-Path $PSScriptRoot 'status.tmp'
    $entry | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination (Join-Path $PSScriptRoot 'status.json') -Force
}

if ($LibraryOnly) { return }
if ($Probe) {
    try {
        $status = Get-CampusStatus
        Write-Host "学校在线状态=$($status.portal_result)（1在线，0离线，-1未知）；外网可用=$($status.internet_access)"
        exit 0
    } catch { Write-Host '无法连接校园网检测接口，请先连接学校网络。'; exit 1 }
}
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$mutex = [Threading.Mutex]::new($false,"Local\CampusAutoLogin-$sid")
$ownsMutex = $false
try {
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { exit 0 }
    @{pid=$PID; started=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'worker.json') -Encoding UTF8
    $credential = Import-Clixml -LiteralPath $CredentialFile
    $settings = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
    $nextLogin = [datetime]::MinValue
    $authFailures = 0
    Save-CampusState 'checking' '后台检测已启动，正在检查校园网和外网连接。'
    do {
        try {
            $script:StopCampusWatch = $false
            $status = Get-CampusStatus
            if ($status.internet_access) {
                Save-CampusState 'online' '外网连接正常，后台每分钟自动检查。'
                $authFailures = 0
                $nextLogin = [datetime]::MinValue
            } elseif ([string]$status.result -eq '1') {
                Save-CampusState 'limited' '学校接口显示在线，外网暂不可用；继续检测，不重复认证。'
            } elseif ([string]$status.result -eq '0' -and (Get-Date) -ge $nextLogin) {
                $config = Get-CampusText ($Portal + 'extern/20180816/config.js')
                $method = Get-CampusMethod $config $status.v46ip
                Save-CampusState 'connecting' '检测到未登录，正在自动认证。'
                $nextLogin = (Get-Date).AddMinutes(5)
                try {
                    Invoke-CampusLogin $status $credential $settings.suffix $method
                    $authFailures = 0
                    Save-CampusState 'checked' $script:LastLoginMessage
                } catch {
                    $authFailures++
                    if ($authFailures -ge 3) { $nextLogin = (Get-Date).AddMinutes(30) }
                    Save-CampusState 'login_error' ($_.Exception.Message + ' 后台继续检测，稍后再尝试；账号有误请双击 login 重新设置。')
                }
            } elseif ([string]$status.result -eq '0') {
                Save-CampusState 'waiting' ('等待下次认证，避免重复提交。下次尝试：' + $nextLogin.ToString('HH:mm:ss'))
            } else {
                Save-CampusState 'unknown' '暂时无法确认在线状态，后台继续检测，不盲目提交登录。'
            }
        } catch {
            # Do not expose raw exception URLs or saved credentials in status files.
            Save-CampusState 'network_error' '暂时无法连接校园网接口。请连接学校 Wi-Fi 或网线，后台会自动重试。'
        }
        if ($Watch) { Start-Sleep -Seconds $Interval }
    } while ($Watch)
} catch {
    Save-CampusState 'config_error' '本机配置无法读取，请双击 login 重新输入账号密码。'
    exit 1
} finally {
    if ($ownsMutex) {
        Remove-Item -LiteralPath (Join-Path $PSScriptRoot 'worker.json') -Force -ErrorAction SilentlyContinue
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
