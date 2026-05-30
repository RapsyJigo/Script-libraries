#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Restores normal internet access after Set-IPAllowlist.ps1 was run.

.DESCRIPTION
    1. Immediately resets global firewall defaults to Allow (unblocks traffic)
    2. Removes every rule prefixed with "IPAllowlist_"

    No backup file required — operates purely by rule prefix and profile defaults.

.EXAMPLE
    .\Restore-Firewall.ps1
#>

$RulePrefix = "IPAllowlist_"

# ── FIRST: reset global defaults so internet is unblocked immediately ─────────
# Do this before anything else so a mid-script error can't leave the machine locked.
Write-Host "[*] Resetting firewall profile defaults to Allow ..." -ForegroundColor Cyan
Set-NetFirewallProfile -All `
    -DefaultOutboundAction Allow `
    -DefaultInboundAction  Block    # Block unsolicited inbound — the normal Windows default
Write-Host "    Outbound traffic is now allowed." -ForegroundColor Green

# ── Remove all IPAllowlist_ rules ─────────────────────────────────────────────
Write-Host "[*] Removing all '${RulePrefix}*' firewall rules ..." -ForegroundColor Cyan
$rules = Get-NetFirewallRule -DisplayName "${RulePrefix}*" -ErrorAction SilentlyContinue
if ($rules) {
    $count = ($rules | Measure-Object).Count
    $rules | Remove-NetFirewallRule
    Write-Host "    Removed $count rule(s)." -ForegroundColor Green
} else {
    Write-Host "    No IPAllowlist rules found (already clean)." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Done. Internet access has been restored." -ForegroundColor Green