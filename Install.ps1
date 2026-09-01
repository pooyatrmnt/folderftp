[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$source = Split-Path -Parent $MyInvocation.MyCommand.Path
$installFolder = Join-Path $env:LOCALAPPDATA 'LocalFtpShare'

New-Item -ItemType Directory -Path $installFolder -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $source 'Start-FtpShare.ps1') -Destination $installFolder -Force
Copy-Item -LiteralPath (Join-Path $source 'Configure-Firewall.ps1') -Destination $installFolder -Force

$menuKey = 'HKCU:\Software\Classes\Directory\shell\LocalFtpShare'
$commandKey = Join-Path $menuKey 'command'
New-Item -Path $commandKey -Force | Out-Null
Set-Item -Path $menuKey -Value 'Share via local FTP'
New-ItemProperty -Path $menuKey -Name 'Icon' -Value 'shell32.dll,-16715' -PropertyType String -Force | Out-Null

$launcher = Join-Path $installFolder 'Start-FtpShare.ps1'
$command = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" "%1"' -f $launcher
Set-Item -Path $commandKey -Value $command

$firewallScript = Join-Path $installFolder 'Configure-Firewall.ps1'
Write-Host 'Windows will now ask for permission to create a local-subnet firewall rule.' -ForegroundColor Cyan
$process = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList @(
    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $firewallScript)
)
if ($process.ExitCode -ne 0) {
    Write-Warning 'The context-menu item was installed, but the firewall rule was not created. Run Install.ps1 again to retry.'
} else {
    Write-Host 'Local FTP Share was installed successfully.' -ForegroundColor Green
    Write-Host 'Right-click a folder. On Windows 11, choose Show more options, then Share via local FTP.'
}

