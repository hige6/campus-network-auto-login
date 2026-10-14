$ErrorActionPreference = 'Stop'
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'CampusAutoLoginLauncher.cs'),[Text.Encoding]::UTF8)
$output = Join-Path $PSScriptRoot 'CampusAutoLogin.exe'
Add-Type -TypeDefinition $source -Language CSharp -ReferencedAssemblies System.Windows.Forms -OutputAssembly $output -OutputType WindowsApplication
Write-Host '构建完成：CampusAutoLogin.exe'

