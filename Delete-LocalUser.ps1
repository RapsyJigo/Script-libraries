<#
.SYNOPSIS
    Silently deletes a local Windows user account and all of their profile files.

.DESCRIPTION
    Designed for unattended/automated use (RMM, Task Scheduler, etc.). No prompts.
    Outputs only errors, warnings, and a final success message via Write-Host/
    Write-Warning/Write-Error. Exit code 0 = success, 1 = failure.

.PARAMETER Username
    The local username to delete.

.EXAMPLE
    .\Delete-LocalUser.ps1 -Username "jsmith"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = 'The username of the user to be deleted.')]
    [string]$Username
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ────────────────────────────────────────────────────────────────────────
# >> Blacklist: accounts that must never be deleted
# ────────────────────────────────────────────────────────────────────────
$Blacklist = @(
    'Administrator',
    'DefaultAccount',
    'Guest',
    'WDAGUtilityAccount',
    'SYSTEM',
    'LOCAL SERVICE',
    'NETWORK SERVICE'
)

# ────────────────────────────────────────────────────────────────────────
# >> 1. Self-elevate if not running as Administrator
# ────────────────────────────────────────────────────────────────────────
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Username `"$Username`""
    if ($ProfilePath) { $argList += " -ProfilePath `"$ProfilePath`"" }
    Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs -Wait
    exit $LASTEXITCODE
}

# ────────────────────────────────────────────────────────────────────────
# >> 2. Blacklist check
# ────────────────────────────────────────────────────────────────────────
if ($Blacklist -contains $Username) {
    Write-Error "Username '$Username' is on the protected blacklist. Deletion refused."
    exit 1
}

# ────────────────────────────────────────────────────────────────────────
# >> 3. Verify the user exists locally
# ────────────────────────────────────────────────────────────────────────
try {
    $localUser = Get-LocalUser -Name $Username
} catch {
    Write-Error "Local user '$Username' not found: $_"
    exit 1
}

# SID-based backstop: built-in Administrator (-500) and Guest (-501)
if ($localUser.SID.Value -match '-(500|501)$') {
    Write-Error "Refusing to delete built-in account '$Username' (SID: $($localUser.SID.Value))."
    exit 1
}

# ────────────────────────────────────────────────────────────────────────
# >> 4. Force log off ALL active user sessions
# ────────────────────────────────────────────────────────────────────────
try {
    $sessions = query session 2>$null |
        Select-String -Pattern "^\s*>?\s*\S+\s+\S+\s+(\d+)\s+(Active|Disc)" |
        ForEach-Object { ($_ -split '\s+' | Where-Object { $_ -ne '' })[2] }
 
    foreach ($sid in $sessions) {
        if ($sid -match '^\d+$') {
            logoff $sid 2>$null | Out-Null
        }
    }
} catch {
    Write-Warning "Session logoff had an issue: $_"
}

# ────────────────────────────────────────────────────────────────────────
# >> 5. Resolve the profile directory path
# ────────────────────────────────────────────────────────────────────────
$wmiProfile = Get-CimInstance -ClassName Win32_UserProfile | Where-Object { $_.SID -eq $localUser.SID.Value }

$ProfilePath = if ($wmiProfile) {
    $wmiProfile.LocalPath
} else {
    Join-Path $env:SystemDrive "Users\$Username"
}


$profileExists = Test-Path $ProfilePath

# ────────────────────────────────────────────────────────────────────────
# >> 6. Remove the local user account
# ────────────────────────────────────────────────────────────────────────
try {
    Remove-LocalUser -Name $Username
} catch {
    Write-Error "Failed to remove user account '$Username': $_"
    exit 1
}

# ────────────────────────────────────────────────────────────────────────
# >> 7. Delete the profile directory
# ────────────────────────────────────────────────────────────────────────
if ($profileExists) {
    try {
        $emptyDir = Join-Path $env:TEMP "EmptyDir_$(New-Guid)"
        New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
        robocopy $emptyDir $ProfilePath /MIR /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
        Remove-Item -LiteralPath $emptyDir -Recurse -Force
        Remove-Item -LiteralPath $ProfilePath -Recurse -Force
    } catch {
        Write-Warning "Profile directory '$ProfilePath' could not be fully deleted: $_"
    }
}

# ────────────────────────────────────────────────────────────────────────
# >> 8. Clean up WMI / registry profile entry
# ────────────────────────────────────────────────────────────────────────
try {
    $wmiProfile = Get-CimInstance -ClassName Win32_UserProfile |
        Where-Object { $_.SID -eq $localUser.SID.Value }
    if ($wmiProfile) { $wmiProfile | Remove-CimInstance }
} catch {
    Write-Warning "Could not remove WMI profile entry for '$Username': $_"
}

# ────────────────────────────────────────────────────────────────────────
# >> Done
# ────────────────────────────────────────────────────────────────────────
Write-Host "SUCCESS: User '$Username' and profile '$ProfilePath' removed."
exit 0
