[CmdletBinding()]
param([switch]$Uninstall, [switch]$LibraryOnly, [string]$PreviewPath)
$ErrorActionPreference = 'Stop'
$InstallRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CampusAutoLogin'
$ApprovedInstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$SourceRoot = $PSScriptRoot
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunName = 'CampusAutoLogin'
$PowerShellExe = Join-Path $PSHOME 'powershell.exe'

function Get-CampusWorker {
    $file = Join-Path $InstallRoot 'worker.json'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try {
        $info = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$info.pid)" -ErrorAction Stop
        $engine = Join-Path $InstallRoot 'campus-login.ps1'
        if ($process.Name -eq 'powershell.exe' -and $process.CommandLine -and
            $process.CommandLine.IndexOf($engine,[StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            $process.CommandLine -match '(?i)\s-Watch(?:\s|$)') { return $process }
    } catch { }
    return $null
}

function Stop-CampusWorker {
    $process = Get-CampusWorker
    if ($process) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        for ($i=0; $i -lt 30; $i++) {
            if (-not (Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 100
        }
    }
    Remove-Item -LiteralPath (Join-Path $InstallRoot 'worker.json') -Force -ErrorAction SilentlyContinue
}

function Set-CampusAutostart([bool]$Enabled) {
    if ($Enabled) {
        if (-not (Test-Path -LiteralPath $RunKey)) { New-Item -Path $RunKey -Force | Out-Null }
        $command = '"' + (Join-Path $InstallRoot 'CampusAutoLogin.exe') + '" --watch'
        New-ItemProperty -LiteralPath $RunKey -Name $RunName -Value $command -PropertyType String -Force | Out-Null
    } else {
        Remove-ItemProperty -LiteralPath $RunKey -Name $RunName -ErrorAction SilentlyContinue
    }
}

function Install-CampusApp($Credential, [bool]$Autostart, [bool]$DisableWifiOnFailure = $false) {
    Stop-CampusWorker
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    foreach ($name in @('CampusAutoLogin.exe','campus-login.ps1','manager.ps1','wifi-radio.ps1','login.cmd','uninstall.cmd','使用说明.md')) {
        $source = Join-Path $SourceRoot $name
        $destination = Join-Path $InstallRoot $name
        if ([IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath($destination)) { Copy-Item -LiteralPath $source -Destination $destination -Force }
    }
    $Credential | Export-Clixml -LiteralPath (Join-Path $InstallRoot 'credential.xml')
    @{suffix=''; autostart=$Autostart; disableWifiOnFailure=$DisableWifiOnFailure} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $InstallRoot 'settings.json') -Encoding UTF8
    Remove-Item -LiteralPath (Join-Path $InstallRoot 'status.json') -Force -ErrorAction SilentlyContinue
    Set-CampusAutostart $Autostart
    # CREATE_NO_WINDOW avoids allocating a console, including with Windows Terminal.
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $PowerShellExe
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $InstallRoot 'campus-login.ps1') + '" -Watch'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $process = [Diagnostics.Process]::Start($startInfo)
    @{pid=$process.Id; started=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $InstallRoot 'worker.json') -Encoding UTF8
    return $process.Id
}

function Uninstall-CampusApp {
    $target = [IO.Path]::GetFullPath($InstallRoot)
    if ($target -ne $ApprovedInstallRoot -or [IO.Path]::GetFileName($target) -ne 'CampusAutoLogin') { throw '卸载目录校验失败，未删除任何文件。' }
    Set-CampusAutostart $false
    Stop-CampusWorker
    if (Test-Path -LiteralPath $target) {
        $directory = Get-Item -LiteralPath $target
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '安装目录是链接，已停止删除，请手动检查。' }
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}

if ($LibraryOnly) { return }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
if ($Uninstall) {
    try {
        Uninstall-CampusApp
        [Windows.Forms.MessageBox]::Show('卸载完成：已停止后台检测、移除开机自启并删除本机保存的账号密码。下载的安装包可自行删除。校园网当前在线会话不会被注销。','校园网自动登录') | Out-Null
        exit 0
    } catch { [Windows.Forms.MessageBox]::Show('卸载未完成：' + $_.Exception.Message,'校园网自动登录') | Out-Null; exit 1 }
}
$form = [Windows.Forms.Form]::new()
$form.Text = '校园网自动登录'
$form.ClientSize = [Drawing.Size]::new(560,515)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = [Drawing.Font]::new('Microsoft YaHei UI',10)
function Add-Label([string]$Text,[int]$X,[int]$Y,[int]$Width,[int]$Height=28) {
    $label = [Windows.Forms.Label]::new()
    $label.Text=$Text; $label.SetBounds($X,$Y,$Width,$Height); $form.Controls.Add($label)
    return $label
}
$null = Add-Label '填写一次，后台自动检测并在断线后重新登录。' 24 18 510
$null = Add-Label '学号 / 完整账号' 24 65 150
$accountBox = [Windows.Forms.TextBox]::new(); $accountBox.SetBounds(180,62,350,30); $form.Controls.Add($accountBox)
$null = Add-Label '校园网密码' 24 110 150
$passwordBox = [Windows.Forms.TextBox]::new(); $passwordBox.UseSystemPasswordChar=$true; $passwordBox.SetBounds(180,107,350,30); $form.Controls.Add($passwordBox)
$null = Add-Label '账号后缀' 24 155 150
$suffixBox = [Windows.Forms.ComboBox]::new(); $suffixBox.SetBounds(180,152,350,30); $suffixBox.DropDownStyle='DropDownList'
$suffixBox.Items.AddRange(@('移动校园（@cmccyx）','校园用户（@xyw）','校园电信（@dx）','校园联通（@lt）','无后缀'))
$suffixBox.SelectedIndex=0; $form.Controls.Add($suffixBox)
$null = Add-Label '已输入完整 @ 后缀时，不会额外追加后缀。' 180 187 350 40
$autoBox = [Windows.Forms.CheckBox]::new(); $autoBox.Text='开机自启（登录 Windows 后自动启动）'; $autoBox.SetBounds(24,235,510,28); $form.Controls.Add($autoBox)
$wifiBox = [Windows.Forms.CheckBox]::new(); $wifiBox.Text='认证失败或外网不通时关闭 Wi-Fi（不会自动打开）'; $wifiBox.SetBounds(24,270,510,28); $form.Controls.Add($wifiBox)
$null = Add-Label '此项用于有线宽带：每次启用最多关闭一次，之后需手动开启 Wi-Fi。' 24 303 510 40
$statusLabel = Add-Label '尚未启动。保存后后台持续运行，关闭本窗口不会停止检测。' 24 365 510 65
$enableButton = [Windows.Forms.Button]::new(); $enableButton.Text='保存并启用'; $enableButton.SetBounds(24,460,160,36); $form.Controls.Add($enableButton)
$webButton = [Windows.Forms.Button]::new(); $webButton.Text='打开登录网页'; $webButton.SetBounds(200,460,160,36); $form.Controls.Add($webButton)
$removeButton = [Windows.Forms.Button]::new(); $removeButton.Text='卸载'; $removeButton.SetBounds(376,460,154,36); $form.Controls.Add($removeButton)
$savedCredential = $null
try {
    if ($PreviewPath) { throw '预览使用空白配置。' }
    $savedCredential = Import-Clixml -LiteralPath (Join-Path $InstallRoot 'credential.xml')
    $accountBox.Text=$savedCredential.UserName
    $settings=Get-Content -LiteralPath (Join-Path $InstallRoot 'settings.json') -Raw | ConvertFrom-Json
    $autoBox.Checked=[bool]$settings.autostart
    $wifiBox.Checked=[bool]$settings.disableWifiOnFailure
    $null = Add-Label '密码留空可沿用已保存的密码。' 180 135 350 18
} catch { }
$webButton.Add_Click({ Start-Process 'http://172.16.253.3/' })
$enableButton.Add_Click({
    try {
        $account = $accountBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($account)) { throw '请输入学号或完整账号。' }
        if ($account -notmatch '@') { $account += @('@cmccyx','@xyw','@dx','@lt','')[$suffixBox.SelectedIndex] }
        if ($passwordBox.Text.Length -eq 0) {
            if ($savedCredential -and $savedCredential.UserName -ceq $account) { $credential=$savedCredential }
            else { throw '请输入校园网密码。' }
        } else {
            $secure=ConvertTo-SecureString $passwordBox.Text -AsPlainText -Force
            $credential=[Management.Automation.PSCredential]::new($account,$secure)
        }
        $enableButton.Enabled=$false
        if ($wifiBox.Checked) {
            . (Join-Path $SourceRoot 'wifi-radio.ps1')
            Request-CampusWifiAccess
        }
        $null = Install-CampusApp $credential $autoBox.Checked $wifiBox.Checked
        $script:savedCredential=$credential
        $passwordBox.Clear()
        $statusLabel.Text='已启用，正在检测网络。可以关闭窗口，后台将继续运行。'
    } catch { [Windows.Forms.MessageBox]::Show('未能启用：' + $_.Exception.Message,'校园网自动登录') | Out-Null }
    finally { $enableButton.Enabled=$true }
})
$removeButton.Add_Click({
    try {
        Uninstall-CampusApp
        [Windows.Forms.MessageBox]::Show('已卸载后台检测、自启项和本机配置。','校园网自动登录') | Out-Null
        $form.Close()
    } catch { [Windows.Forms.MessageBox]::Show('卸载未完成：' + $_.Exception.Message,'校园网自动登录') | Out-Null }
})
$timer=[Windows.Forms.Timer]::new(); $timer.Interval=2000
$timer.Add_Tick({
    try {
        $state=Get-Content -LiteralPath (Join-Path $InstallRoot 'status.json') -Raw | ConvertFrom-Json
        $statusLabel.Text=$state.time + '：' + $state.message
        if (-not (Get-CampusWorker)) { $statusLabel.Text += '（后台未运行，请重新启用。）' }
    } catch { }
})
$timer.Start()
$form.Add_FormClosed({ $timer.Stop(); $timer.Dispose() })
if ($PreviewPath) {
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    $bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height)
    $form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height))
    $bitmap.Save($PreviewPath,[Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose(); $form.Close(); $form.Dispose()
    exit 0
}
[Windows.Forms.Application]::Run($form)
$form.Dispose()

