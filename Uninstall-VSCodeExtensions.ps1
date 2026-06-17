#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Uninstalls VSCode extensions from all users on the machine, running as SYSTEM.

.DESCRIPTION
    For each extension ID provided, the script:

    1. EXISTING USERS — Removes the extension folder(s) matching
       <publisher>.<name>-* from every user's %USERPROFILE%\.vscode\extensions\
       directory (handles any version that may be installed).

    2. EXTENSIONS REGISTRY — Removes the corresponding entry from each user's
       %USERPROFILE%\.vscode\extensions\extensions.json so VSCode does not
       reference a folder that no longer exists.

    3. BOOTSTRAP FOLDER — Removes the matching .vsix file(s) from the
       <VSCodeInstall>\bootstrap\extensions\ folder so the extension is not
       reinstalled for new users on their first launch.

    No RunAs or per-user process invocation is used; everything runs as SYSTEM.

.PARAMETER ExtensionsCsv
    Comma or newline-separated extension IDs in publisher.name format.

.PARAMETER VsCodeInstallPath
    Path to the VS Code installation directory. Auto-detected if omitted.

.PARAMETER UserProfilesRoot
    Root folder containing user profile directories. Defaults to C:\Users.

.EXAMPLE
    .\Uninstall-VSCodeExtensions.ps1 -ExtensionsCsv "ms-python.python,esbenp.prettier-vscode"

.EXAMPLE
    $csv = @"
ms-python.python
esbenp.prettier-vscode
"@
    .\Uninstall-VSCodeExtensions.ps1 -ExtensionsCsv $csv 
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory, HelpMessage = "Comma or newline-separated extension IDs (publisher.name).")]
    [string]$ExtensionsCsv,

    [string]$VsCodeInstallPath,

    [string]$UserProfilesRoot = 'C:\Users'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ────────────────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')]$Level = 'INFO')
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = @{ INFO = 'Cyan'; WARN = 'Yellow'; ERROR = 'Red' }[$Level]
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $color
}

# Remove all entries for the given extension IDs from a user's extensions.json.
# Preserves all other entries. Writes the file back only if something changed.
function Remove-ExtensionEntries {
    param(
        [string]$ExtensionsDir,
        [string[]]$IdsToRemove    # lower-case, e.g. @('ms-python.python')
    )

    $jsonPath = Join-Path $ExtensionsDir 'extensions.json'

    if (-not (Test-Path $jsonPath)) {
        return   # nothing to do
    }

    $raw = Get-Content $jsonPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) { return }

    try {
        $entries = $raw | ConvertFrom-Json
    } catch {
        Write-Log "    Could not parse extensions.json — skipping registry update." -Level WARN
        return
    }

    if ($null -eq $entries) { return }

    # ConvertFrom-Json may return a single object instead of an array
    $entries = @($entries)

    $before = $entries.Count
    $kept   = $entries | Where-Object {
        $entryId = $_.identifier.id.ToLower()
        $IdsToRemove -notcontains $entryId
    }
    $kept   = @($kept)   # ensure array even when one item remains
    $after  = $kept.Count

    if ($after -eq $before) {
        Write-Log "    No matching entries found in extensions.json."
        return
    }

    $removed = $before - $after
    Write-Log "    Removed $removed entr$(if ($removed -eq 1) {'y'} else {'ies'}) from extensions.json."

    if ($kept.Count -eq 0) {
        # Write an empty array rather than deleting the file, which is what
        # VSCode itself does when all extensions are uninstalled.
        Set-Content -Path $jsonPath -Value '[]' -Encoding UTF8 -Force
    } else {
        $kept | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8 -Force
    }
}

# ────────────────────────────────────────────────────────────────────────
# Step 1 – Parse and validate extension IDs
# ────────────────────────────────────────────────────────────────────────
Write-Log "Parsing extension list."

$ExtensionIdPattern = '^[A-Za-z0-9_-]+\.[A-Za-z0-9_.-]+$'

$extensionIds = $ExtensionsCsv -split '[,\r\n]+' |
    ForEach-Object { $_.Trim().ToLower() } |
    Where-Object   { $_ -ne '' -and $_ -ne 'extensionid' } |
    Where-Object   {
        if ($_ -notmatch $ExtensionIdPattern) {
            Write-Log "Skipping invalid extension ID: '$_'" -Level WARN
            $false
        } else { $true }
    } |
    Sort-Object -Unique

if ($extensionIds.Count -eq 0) {
    Write-Log "No valid extension IDs found in input. Exiting." -Level WARN
    exit 0
}

Write-Log "Extensions to uninstall: $($extensionIds -join ', ')"

# ────────────────────────────────────────────────────────────────────────
# Step 2 – Resolve VS Code install path (for bootstrap folder)
# ────────────────────────────────────────────────────────────────────────
if (-not $VsCodeInstallPath) {
    $candidates = @(
        "$env:ProgramFiles\Microsoft VS Code",
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code"
    )
    $VsCodeInstallPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}

if ($VsCodeInstallPath) {
    Write-Log "VS Code install: $VsCodeInstallPath"
} else {
    Write-Log "VS Code installation not found — bootstrap cleanup will be skipped." -Level WARN
}

# ────────────────────────────────────────────────────────────────────────
# Step 3 – Collect real user profiles
# ────────────────────────────────────────────────────────────────────────
$skipNames = @('Public', 'Default', 'Default User', 'All Users', 'defaultuser0')

$userProfiles = Get-ChildItem -Path $UserProfilesRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $skipNames -notcontains $_.Name }

Write-Log "Found $($userProfiles.Count) user profile(s): $($userProfiles.Name -join ', ')"

# ────────────────────────────────────────────────────────────────────────
# Step 4 – Remove extension folders and registry entries from each user
# ────────────────────────────────────────────────────────────────────────
foreach ($profile in $userProfiles) {
    $extensionsDir = Join-Path $profile.FullName '.vscode\extensions'

    if (-not (Test-Path $extensionsDir)) {
        Write-Log "No .vscode\extensions folder for user '$($profile.Name)' — skipping."
        continue
    }

    Write-Log "Processing user: $($profile.Name)"

    foreach ($id in $extensionIds) {
        # An extension folder is named <publisher>.<name>-<version>.
        # We match on the prefix "<id>-" to catch any installed version.
        $matchingFolders = Get-ChildItem -Path $extensionsDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name.ToLower() -like "$id-*" -or $_.Name.ToLower() -eq $id }

        if ($matchingFolders.Count -eq 0) {
            Write-Log "    = Not installed for '$($profile.Name)': $id"
            continue
        }

        foreach ($folder in $matchingFolders) {
            if ($PSCmdlet.ShouldProcess($folder.FullName, "Remove extension folder")) {
                try {
                    Remove-Item -Path $folder.FullName -Recurse -Force
                    Write-Log "    - Removed folder: $($folder.Name)"
                } catch {
                    Write-Log "    FAILED removing '$($folder.FullName)': $_" -Level ERROR
                }
            }
        }
    }

    # Update extensions.json once per user, passing all IDs together
    if ($PSCmdlet.ShouldProcess((Join-Path $extensionsDir 'extensions.json'), "Update extensions.json for $($profile.Name)")) {
        try {
            Remove-ExtensionEntries -ExtensionsDir $extensionsDir -IdsToRemove $extensionIds
        } catch {
            Write-Log "    FAILED updating extensions.json for '$($profile.Name)': $_" -Level ERROR
        }
    }
}

# ────────────────────────────────────────────────────────────────────────
# Step 5 – Clean up the bootstrap folder
# ────────────────────────────────────────────────────────────────────────
if ($VsCodeInstallPath) {
    $bootstrapDir = Join-Path $VsCodeInstallPath 'bootstrap\extensions'

    if (-not (Test-Path $bootstrapDir)) {
        Write-Log "Bootstrap folder does not exist — nothing to clean up."
    } else {
        Write-Log "Cleaning bootstrap folder: $bootstrapDir"

        foreach ($id in $extensionIds) {
            # Match <id>.vsix exactly, or <id>-<version>.vsix if named that way
            $matchingFiles = Get-ChildItem -Path $bootstrapDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name.ToLower() -eq "$id.vsix" -or $_.Name.ToLower() -like "$id-*.vsix" }

            if ($matchingFiles.Count -eq 0) {
                Write-Log "  = Not in bootstrap folder: $id"
                continue
            }

            foreach ($file in $matchingFiles) {
                if ($PSCmdlet.ShouldProcess($file.FullName, "Remove bootstrap VSIX")) {
                    try {
                        Remove-Item -Path $file.FullName -Force
                        Write-Log "  - Removed: $($file.Name)"
                    } catch {
                        Write-Log "  FAILED removing '$($file.FullName)': $_" -Level ERROR
                    }
                }
            }
        }
    }
}

# ────────────────────────────────────────────────────────────────────────
# Step 6 – Summary
# ────────────────────────────────────────────────────────────────────────
Write-Log "Done. Uninstalled $($extensionIds.Count) extension(s) from $($userProfiles.Count) user profile(s)."