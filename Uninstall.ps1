[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$installFolder = Join-Path $env:LOCALAPPDATA 'LocalFtpShare'
$menuKey = 'HKCU:\Software\Classes\Directory\shell\LocalFtpShare'

if (Test-Path $menuKey) { Remove-Item -Path $menuKey -Recurse -Force }

$firewallScript = Join-Path $installFolder 'Configure-Firewall.ps1'
if (Test-Path -LiteralPath $firewallScript) {
    Write-Host 'Windows will ask for permission to remove the firewall rule.' -ForegroundColor Cyan
    Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $firewallScript), '-Remove'
    )
}

if (Test-Path -LiteralPath $installFolder) { Remove-Item -LiteralPath $installFolder -Recurse -Force }
Write-Host 'Local FTP Share was removed.' -ForegroundColor Green

