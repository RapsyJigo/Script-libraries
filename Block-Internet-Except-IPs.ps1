#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Blocks all internet traffic except for a specified list of IP addresses.

.DESCRIPTION
    Uses Windows Firewall to:
      1. Set default outbound/inbound action to Block on all profiles
      2. Add explicit Allow rules (prefixed "IPAllowlist_") for each supplied IP

    No backup file is needed. Run Restore-Firewall.ps1 to undo.

.PARAMETER AllowedIPs
    Comma-separated string of IP addresses or CIDR ranges to allow.

.EXAMPLE
    .\Block-Internet-Except-IPs.ps1 -AllowedIPs "8.8.8.8,1.1.1.1,192.168.1.0/24"
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$AllowedIPs
)

$RulePrefix = "IPAllowlist_"

$IPList = $AllowedIPs -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

if ($IPList.Count -eq 0) {
    Write-Error "You must supply at least one IP address."
    exit 1
}

# ────────────────────────────────────────────────────────────────────────
# >> Clean up any stale rules from a previous run
# ────────────────────────────────────────────────────────────────────────
$stale = Get-NetFirewallRule -DisplayName "${RulePrefix}*" -ErrorAction SilentlyContinue
if ($stale) {
    Write-Host "[*] Removing stale IPAllowlist rules from a previous run ..." -ForegroundColor Cyan
    $stale | Remove-NetFirewallRule
}

# ────────────────────────────────────────────────────────────────────────
# >> Allow loopback so local services keep working
# ────────────────────────────────────────────────────────────────────────
Write-Host "[*] Adding loopback allow rules ..." -ForegroundColor Cyan
New-NetFirewallRule -Name "${RulePrefix}Allow_Loopback_Out" `
    -DisplayName "${RulePrefix}Allow_Loopback_Out" `
    -Description "IPAllowlist: loopback outbound" `
    -Direction Outbound -Action Allow `
    -RemoteAddress "127.0.0.0/8" -Profile Any -Enabled True | Out-Null

New-NetFirewallRule -Name "${RulePrefix}Allow_Loopback_In" `
    -DisplayName "${RulePrefix}Allow_Loopback_In" `
    -Description "IPAllowlist: loopback inbound" `
    -Direction Inbound -Action Allow `
    -RemoteAddress "127.0.0.0/8" -Profile Any -Enabled True | Out-Null

# ────────────────────────────────────────────────────────────────────────
# >> Add allow rules for each supplied IP
# ────────────────────────────────────────────────────────────────────────
Write-Host "[*] Creating allow rules for $($IPList.Count) IP(s) ..." -ForegroundColor Cyan
foreach ($ip in $IPList) {
    $ip      = $ip.Trim()
    $safe    = $ip -replace '[/\\:\*\?"<>\|]', '_'
    Write-Host "    + $ip" -ForegroundColor Yellow

    New-NetFirewallRule -Name "${RulePrefix}Allow_Out_${safe}" `
        -DisplayName "${RulePrefix}Allow_Out_${safe}" `
        -Description "IPAllowlist: allow outbound to $ip" `
        -Direction Outbound -Action Allow `
        -RemoteAddress $ip -Profile Any -Enabled True | Out-Null

    New-NetFirewallRule -Name "${RulePrefix}Allow_In_${safe}" `
        -DisplayName "${RulePrefix}Allow_In_${safe}" `
        -Description "IPAllowlist: allow inbound from $ip" `
        -Direction Inbound -Action Allow `
        -RemoteAddress $ip -Profile Any -Enabled True | Out-Null
}

# ────────────────────────────────────────────────────────────────────────
# >> Block everything else by changing global defaults
# ────────────────────────────────────────────────────────────────────────
Write-Host "[*] Setting default outbound/inbound action to BLOCK on all profiles ..." -ForegroundColor Cyan
Set-NetFirewallProfile -All -Enabled True -DefaultOutboundAction Block -DefaultInboundAction Block

Write-Host ""
Write-Host "Done. Internet is now restricted to:" -ForegroundColor Green
$IPList | ForEach-Object { Write-Host "    - $_" -ForegroundColor White }
Write-Host ""
Write-Host "Run Restore-Firewall.ps1 to re-open internet access." -ForegroundColor Cyan
