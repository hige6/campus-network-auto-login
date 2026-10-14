# Windows Wi-Fi radio control. No adapter disabling and no automatic power-on.
function Initialize-CampusRadio {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Devices.Radios.Radio,Windows.System.Devices,ContentType=WindowsRuntime]
    $null = [Windows.Devices.Radios.RadioAccessStatus,Windows.System.Devices,ContentType=WindowsRuntime]
    $null = [Windows.Devices.Radios.RadioState,Windows.System.Devices,ContentType=WindowsRuntime]
}

function Wait-CampusRadioOperation($Operation, [type]$ResultType) {
    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and
        $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } | Select-Object -First 1
    if (-not $method) { throw '系统缺少无线开关控制组件。' }
    $task = $method.MakeGenericMethod($ResultType).Invoke($null,@($Operation))
    if (-not $task.Wait(10000)) { throw '等待无线开关操作超时。' }
    return $task.Result
}

function Get-CampusWifiRadios {
    Initialize-CampusRadio
    $type = [System.Collections.Generic.IReadOnlyList[Windows.Devices.Radios.Radio]]
    $radios = Wait-CampusRadioOperation ([Windows.Devices.Radios.Radio]::GetRadiosAsync()) $type
    return @($radios | Where-Object { [string]$_.Kind -eq 'WiFi' })
}

function Request-CampusWifiAccess {
    Initialize-CampusRadio
    $access = Wait-CampusRadioOperation ([Windows.Devices.Radios.Radio]::RequestAccessAsync()) ([Windows.Devices.Radios.RadioAccessStatus])
    if ([string]$access -ne 'Allowed') { throw 'Windows 未允许控制 Wi-Fi 开关，请检查系统权限设置。' }
}

function Set-CampusWifiRadioOff($Radio) {
    $access = Wait-CampusRadioOperation ($Radio.SetStateAsync([Windows.Devices.Radios.RadioState]::Off)) ([Windows.Devices.Radios.RadioAccessStatus])
    if ([string]$access -ne 'Allowed') { throw 'Windows 拒绝关闭 Wi-Fi 开关。' }
}

function Disable-CampusWifi {
    $radios = @(Get-CampusWifiRadios)
    if ($radios.Count -eq 0) { throw '未找到可控制的 Wi-Fi 开关。' }
    $on = @($radios | Where-Object { [string]$_.State -eq 'On' })
    if ($on.Count -eq 0) { return 'Wi-Fi 已处于关闭状态；不会自动开启。' }
    Request-CampusWifiAccess
    foreach ($radio in $on) { Set-CampusWifiRadioOff $radio }
    for ($i=0; $i -lt 10; $i++) {
        $remaining = @($radios | Where-Object { [string]$_.State -eq 'On' })
        if ($remaining.Count -eq 0) { return 'Wi-Fi 开关已关闭；一分钟后继续检测宽带，不会自动开启 Wi-Fi。' }
        Start-Sleep -Milliseconds 500
    }
    throw '已请求关闭 Wi-Fi，但系统尚未确认开关已关闭。请在系统设置中检查。'
}

