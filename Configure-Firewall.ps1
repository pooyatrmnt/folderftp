[CmdletBinding()]
param([switch]$Remove)

$ErrorActionPreference = 'Stop'
$ruleName = 'Local FTP Share (Private local subnet)'

if ($Remove) {
    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    exit 0
}

Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule `
    -DisplayName $ruleName `
    -Description 'Allows the Local FTP Share context-menu tool only on private networks and from the local subnet.' `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalPort 2121,50000-50099 `
    -Profile Private `
    -RemoteAddress LocalSubnet | Out-Null

