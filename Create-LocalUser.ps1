#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a new local Windows user with managed password settings and suppressed OOBE/first-logon experience.

.DESCRIPTION
    Creates a local user account with the following characteristics:
      - Password cannot be changed by the user
      - Password never expires
      - Skips Windows first-logon OOBE messages and advertisements
    Intended to be run remotely via RMM agents at SYSTEM level.

.PARAMETER Username
    The username for the new account. (Required)

.PARAMETER Password
    The password for the new account. (Required) Pass an empty string "" to create the account with no password.

.PARAMETER Group
    The local group to add the user to. Defaults to "Users".
    Common values: "Users", "Administrators", "Remote Desktop Users", "Power Users"

.EXAMPLE
    .\New-ManagedUser.ps1 -Username "servicedesk" -Password "P@ssw0rd!" -Group "Administrators"

.EXAMPLE
    .\New-ManagedUser.ps1 -Username "kiosk" -Password "" -Group "Users"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Password,

    [Parameter(Mandatory = $false)]
    [string]$Group = "Users"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Main try/catch — all output is collected and written once at exit ─────────
try {

    # ── 1. Build New-LocalUser parameter set ─────────────────────────────────
    $newUserParams = @{
        Name                     = $Username
        PasswordNeverExpires     = $true
        UserMayNotChangePassword = $true
        AccountNeverExpires      = $true
    }

    if ($Password -eq "") {
        $newUserParams["NoPassword"] = $true
        $passwordMode = "no password"
    } else {
        $newUserParams["Password"] = ConvertTo-SecureString -String $Password -AsPlainText -Force
        $passwordMode = "password set"
    }

    # ── 2. Create the user account, abort if it already exists ───────────────
    if (Get-LocalUser -Name $Username -ErrorAction SilentlyContinue) {
        throw "User '$Username' already exists."
    }

    # ── 3. Validate group and add user membership ─────────────────────────────
    if (-not (Get-LocalGroup -Name $Group -ErrorAction SilentlyContinue)) {
        throw "Group '$Group' does not exist on this machine."
    }

    $alreadyMember = Get-LocalGroupMember -Group $Group -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*\$Username" -or $_.Name -eq $Username }

    if (-not $alreadyMember) {
        Add-LocalGroupMember -Group $Group -Member $Username
    }

    # ── 4. Resolve user SID for registry hive targeting ──────────────────────
    $userSID          = (Get-LocalUser -Name $Username).SID.Value
    $ntUserDat        = "$env:SystemDrive\Users\$Username\NTUSER.DAT"
    $hiveLoaded       = $false
    $hiveMountWarning = $null

    # ── 5. Mount user hive if not already loaded ──────────────────────────────
    if (-not (Test-Path "Registry::HKU\$userSID")) {
        if (Test-Path $ntUserDat) {
            reg load "HKU\$userSID" $ntUserDat | Out-Null
            $hiveLoaded = $true
        } else {
            # ── 5a. Force profile creation via a one-shot scheduled task ──────
            $taskName      = "CreateProfile_$Username"
            $taskAction    = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c exit"
            $taskSettings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -DeleteExpiredTaskAfter (New-TimeSpan -Seconds 1)
            $taskPrincipal = New-ScheduledTaskPrincipal -UserId $Username -LogonType Interactive

            Register-ScheduledTask -TaskName $taskName `
                -Action    $taskAction `
                -Settings  $taskSettings `
                -Principal $taskPrincipal `
                -Force | Out-Null

            Start-ScheduledTask -TaskName $taskName
            Start-Sleep -Seconds 5
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

            if (Test-Path $ntUserDat) {
                reg load "HKU\$userSID" $ntUserDat | Out-Null
                $hiveLoaded = $true
            } else {
                $hiveMountWarning = "Could not mount user hive — OOBE registry keys were skipped. They will apply on first logon if set via Default User profile separately."
            }
        }
    }

    # ── 6. Write OOBE / advertisement suppression registry keys ──────────────
    if (-not $hiveMountWarning) {
        $regSettings = @(
            # ── First-logon animation ─────────────────────────────────────────
            @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "DisableStartupSound";             Value = 1; Type = "DWord" },
            @{ Path = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon";     Name = "EnableFirstLogonAnimation";       Value = 0; Type = "DWord" },
            # ── Cortana / Search first-run ────────────────────────────────────
            @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search";          Name = "BingSearchEnabled";               Value = 0; Type = "DWord" },
            @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search";          Name = "CortanaConsent";                  Value = 0; Type = "DWord" },
            # ── Privacy consent OOBE screens ─────────────────────────────────
            @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\OOBE";            Name = "DisablePrivacyExperience";        Value = 1; Type = "DWord" },
            @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\OOBE";            Name = "PrivacyConsentStatus";            Value = 1; Type = "DWord" },
            @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\OOBE";            Name = "SkipMachineOOBE";                 Value = 1; Type = "DWord" },
            @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\OOBE";            Name = "SkipUserOOBE";                    Value = 1; Type = "DWord" },
            # ── "Finish setting up your device" / Windows Hello nudges ────────
            @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement"; Name = "ScoobeSystemSettingEnabled"; Value = 0; Type = "DWord" },
            # ── Windows Spotlight / lock screen ads ───────────────────────────
            @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-338389Enabled"; Value = 0; Type = "DWord" },
            @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-338388Enabled"; Value = 0; Type = "DWord" },
            @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-310093Enabled"; Value = 0; Type = "DWord" },
            @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-353698Enabled"; Value = 0; Type = "DWord" },
            @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SoftLandingEnabled";              Value = 0; Type = "DWord" },
            @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SystemPaneSuggestionsEnabled";    Value = 0; Type = "DWord" },
            # ── Tips and suggestions toast notifications ──────────────────────
            @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SilentInstalledAppsEnabled";      Value = 0; Type = "DWord" }
        )

        # ── Translate HKCU paths to the mounted HKU hive and apply ────────────
        foreach ($entry in $regSettings) {
            $hivePath = $entry.Path -replace "^HKCU:\\", "Registry::HKU\$userSID\"
            if (-not (Test-Path $hivePath)) {
                New-Item -Path $hivePath -Force | Out-Null
            }
            Set-ItemProperty -Path $hivePath -Name $entry.Name -Value $entry.Value -Type $entry.Type -Force
        }
    }

    # ── 7. Unload hive if we mounted it in this session ───────────────────────
    if ($hiveLoaded) {
        [gc]::Collect()
        Start-Sleep -Milliseconds 500
        reg unload "HKU\$userSID" | Out-Null
    }

    # ── 8. Single success output ──────────────────────────────────────────────
    $summary = "SUCCESS: User '$Username' $userAction ($passwordMode), added to '$Group', OOBE suppressed."
    if ($hiveMountWarning) { $summary += " WARNING: $hiveMountWarning" }
    Write-Output $summary

} catch {
    # ── Single error output ───────────────────────────────────────────────────
    Write-Output "ERROR: $_"
    exit 1
}