<#
.SYNOPSIS
    Temporarily disables physical mouse (and optionally keyboard/touch) input for all users.
    Designed to run as SYSTEM or elevated admin.

.EXAMPLES
    .\Set-InputLock.ps1 -Action Disable -Minutes 60      # lock mouse, auto-restore in 60 min
    .\Set-InputLock.ps1 -Action Disable -IncludeKeyboard # also lock keyboards (no auto-restore)
    .\Set-InputLock.ps1 -Action Disable -DryRun          # only list what WOULD be disabled
    .\Set-InputLock.ps1 -Action Enable                   # restore everything
    .\Set-InputLock.ps1 -Action Status                   # show current state

.NOTES
    - Only devices this script disabled are re-enabled (tracked in a state file).
    - Virtual/root-enumerated devices (remote-control drivers, VMs) are skipped by default.
    - -Minutes registers a SYSTEM scheduled task as a failsafe. It also triggers at startup,
      so a reboot restores input. Disabled PnP devices otherwise stay disabled across reboots.
    - No script file needs to exist on the device (works when pushed by an RMM tool). The
      failsafe task carries its own inline restore command and only reads the small state
      file in C:\ProgramData\InputLock. Running -Action Enable from the RMM also works, even
      if the state file is gone (it scans for disabled input devices instead).
#>
[CmdletBinding()]
param(
    [ValidateSet('Disable', 'Enable', 'Status')]
    [string]$Action = 'Status',

    [int]$Minutes = 0,                    # 0 = no timed auto-restore
    [switch]$IncludeKeyboard,
    [switch]$IncludeTouch,                # touchscreens
    [string[]]$ExcludePattern = @(),      # regex on FriendlyName, e.g. 'Logitech Receiver'
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$StateDir  = Join-Path $env:ProgramData 'InputLock'
$StateFile = Join-Path $StateDir 'state.json'
$TaskName  = 'InputLock-Restore'

# --- Elevation check ---------------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isSystem = $id.IsSystem
$isAdmin  = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not ($isSystem -or $isAdmin)) {
    Write-Error 'Run as SYSTEM or from an elevated PowerShell.'
    exit 1
}

function Write-Log($msg) { Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) }

function Get-TargetDevices {
    param([switch]$Disabled)   # -Disabled = find devices that are currently disabled instead

    $classes = @('Mouse')
    if ($IncludeKeyboard) { $classes += 'Keyboard' }

    $devs = @()
    foreach ($c in $classes) {
        $devs += Get-PnpDevice -Class $c -PresentOnly -ErrorAction SilentlyContinue
    }
    if ($IncludeTouch) {
        $devs += Get-PnpDevice -Class HIDClass -PresentOnly -ErrorAction SilentlyContinue |
                 Where-Object { $_.FriendlyName -match 'touch' }
    }

    # Skip software/virtual devices so remote-control input keeps working
    $skipInstance = '^(ROOT|SWD|TERMINPUT|UMB)\\'
    $skipName     = 'virtual|remote|vmware|hyper-v|citrix|vnc|teamviewer|anydesk'

    $devs | Where-Object {
        $(if ($Disabled) { $_.Problem -eq 'CM_PROB_DISABLED' } else { $_.Status -eq 'OK' }) -and
        $_.InstanceId -notmatch $skipInstance -and
        $_.FriendlyName -notmatch $skipName
    } | Where-Object {
        $name = $_.FriendlyName
        -not ($ExcludePattern | Where-Object { $name -match $_ })
    } | Sort-Object InstanceId -Unique
}

function Remove-RestoreTask {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Register-RestoreTask([int]$Mins) {
    # Self-contained: the task does NOT reference this script file. It reads the state
    # file (data only) and re-enables the devices listed there, then cleans up.
    $inline = '$s = Join-Path $env:ProgramData ''InputLock\state.json''; ' +
              'if (Test-Path $s) { ' +
                '$ok = $true; ' +
                '(Get-Content $s -Raw | ConvertFrom-Json).Devices | ForEach-Object { ' +
                  'try { Enable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction Stop } catch { $ok = $false } }; ' +
                'if ($ok) { Remove-Item $s -Force; Unregister-ScheduledTask -TaskName ''InputLock-Restore'' -Confirm:$false } ' +
              '} else { Unregister-ScheduledTask -TaskName ''InputLock-Restore'' -Confirm:$false }'

    $act = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "' + $inline + '"')
    $triggers = @(
        New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($Mins)
        New-ScheduledTaskTrigger -AtStartup
    )
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $triggers `
        -Principal $principal -Settings $settings -Force | Out-Null
    Write-Log "Failsafe restore scheduled in $Mins min (and at next startup)."
}

switch ($Action) {

    'Status' {
        if (Test-Path $StateFile) {
            $state = Get-Content $StateFile -Raw | ConvertFrom-Json
            Write-Log "Input LOCKED since $($state.Time). Disabled devices:"
            $state.Devices | ForEach-Object { Write-Output "  - $($_.Name)  [$($_.InstanceId)]" }
        } else {
            Write-Log 'Input not locked by this script.'
        }
        Write-Log 'Devices that would be targeted right now:'
        Get-TargetDevices | ForEach-Object { Write-Output "  - $($_.FriendlyName)  [$($_.InstanceId)]" }
    }

    'Disable' {
        $targets = @(Get-TargetDevices)
        if ($targets.Count -eq 0) { Write-Log 'No matching devices found.'; break }

        if ($DryRun) {
            Write-Log 'DRY RUN - would disable:'
            $targets | ForEach-Object { Write-Output "  - $($_.FriendlyName)  [$($_.InstanceId)]" }
            break
        }

        # Register the failsafe BEFORE disabling anything
        if ($Minutes -gt 0) { Register-RestoreTask $Minutes }

        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

        # Merge with any existing state so repeated runs don't lose track of devices
        $existing = @()
        if (Test-Path $StateFile) { $existing = @((Get-Content $StateFile -Raw | ConvertFrom-Json).Devices) }

        $done = @()
        foreach ($d in $targets) {
            try {
                Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false
                $done += [pscustomobject]@{ Name = $d.FriendlyName; InstanceId = $d.InstanceId }
                Write-Log "Disabled: $($d.FriendlyName)"
            } catch {
                Write-Warning "Failed to disable $($d.FriendlyName): $($_.Exception.Message)"
            }
        }

        $all = @($existing + $done) | Sort-Object InstanceId -Unique
        [pscustomobject]@{ Time = (Get-Date).ToString('s'); Devices = $all } |
            ConvertTo-Json -Depth 4 | Set-Content $StateFile -Encoding UTF8
    }

    'Enable' {
        if (Test-Path $StateFile) {
            $toEnable = @((Get-Content $StateFile -Raw | ConvertFrom-Json).Devices)
        } else {
            # No state (e.g. file was cleaned up): fall back to scanning for disabled devices.
            # Pass -IncludeKeyboard / -IncludeTouch if you disabled those classes too.
            Write-Log 'No saved state; scanning for disabled input devices.'
            $toEnable = @(Get-TargetDevices -Disabled | ForEach-Object {
                [pscustomobject]@{ Name = $_.FriendlyName; InstanceId = $_.InstanceId } })
        }
        if ($toEnable.Count -eq 0) {
            Write-Log 'Nothing to restore.'
            Remove-RestoreTask
            break
        }
        $failed = 0
        foreach ($d in $toEnable) {
            try {
                Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false
                Write-Log "Enabled: $($d.Name)"
            } catch {
                $failed++
                Write-Warning "Failed to enable $($d.Name): $($_.Exception.Message)"
            }
        }
        if ($failed -eq 0) {
            Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
            Remove-RestoreTask
        } else {
            Write-Warning 'Some devices failed to re-enable; state file kept so you can retry.'
        }
    }
}