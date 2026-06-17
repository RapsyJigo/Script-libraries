#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deploys VSCode extensions to all users on the machine, running as SYSTEM.

.DESCRIPTION
    Three things are done for each extension:

    1. EXISTING USERS — The .vsix is extracted directly into every user's
       %USERPROFILE%\.vscode\extensions\<publisher>.<name>-<version>\ folder,
       which is where VSCode scans for installed extensions on launch.

    2. EXTENSIONS REGISTRY — Each user's
       %USERPROFILE%\.vscode\extensions\extensions.json is updated with the
       correct metadata entry so VSCode recognises the extension as properly
       installed (not just a stray folder).

    3. NEW USERS (bootstrap) — The .vsix files are copied into
       <VSCodeInstall>\bootstrap\extensions\ so any first-time VSCode launch
       also picks them up silently.

    All metadata (UUID, publisherId, publisherDisplayName) is fetched live from
    the VS Marketplace gallery API so extensions.json entries are accurate.
    No RunAs or per-user process invocation is used; everything runs as SYSTEM.

.PARAMETER ExtensionsCsv
    Comma or newline-separated extension IDs in publisher.name format.

.PARAMETER VsCodeInstallPath
    Path to the VS Code installation directory. Auto-detected if omitted.

.PARAMETER UserProfilesRoot
    Root folder containing user profile directories. Defaults to C:\Users.

.EXAMPLE
    .\Install-VSCodeExtensions.ps1 -ExtensionsCsv "ms-python.python,esbenp.prettier-vscode"

.EXAMPLE
    $csv = @"
ms-python.python
esbenp.prettier-vscode
dbaeumer.vscode-eslint
"@
    .\Install-VSCodeExtensions.ps1 -ExtensionsCsv $csv
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

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')]$Level = 'INFO')
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = @{ INFO = 'Cyan'; WARN = 'Yellow'; ERROR = 'Red' }[$Level]
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $color
}

# Fetch rich metadata for one extension from the Marketplace gallery API.
# Returns a hashtable with: Id, Uuid, Version, PublisherId, PublisherDisplayName
function Get-MarketplaceMetadata {
    param([string]$ExtensionId)   # e.g. "ms-python.python"

    $uri     = 'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery'
    $headers = @{
        'Content-Type' = 'application/json'
        'Accept'       = 'application/json;api-version=7.2-preview.1'
    }
    $body = @{
        filters = @(@{
            criteria = @(@{ filterType = 7; value = $ExtensionId })
        })
        flags = 914   # IncludeVersions | IncludeFiles | IncludeVersionProperties | IncludeInstallationTargets
    } | ConvertTo-Json -Depth 5

    $response  = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $body -ErrorAction Stop
    $extension = $response.results[0].extensions[0]

    if (-not $extension) {
        throw "Extension '$ExtensionId' not found in the Marketplace."
    }

    $latestVersion = $extension.versions[0]

    return @{
        Id                   = $extension.extensionName          # e.g. "python"
        Publisher            = $extension.publisher.publisherName # e.g. "ms-python"
        FullId               = "$($extension.publisher.publisherName).$($extension.extensionName)"
        Uuid                 = $extension.extensionId            # GUID
        Version              = $latestVersion.version
        PublisherId          = $extension.publisher.publisherId  # GUID
        PublisherDisplayName = $extension.publisher.displayName
    }
}

# Extract the "extension/" subtree of a .vsix ZIP into $DestinationDir.
function Expand-Vsix {
    param([string]$VsixPath, [string]$DestinationDir)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($VsixPath)
    try {
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName -notlike 'extension/*') { continue }
            if ([string]::IsNullOrEmpty($entry.Name))   { continue }   # directory entry

            $relativePath = $entry.FullName.Substring('extension/'.Length)
            $targetPath   = Join-Path $DestinationDir $relativePath
            $targetFolder = Split-Path $targetPath -Parent

            if (-not (Test-Path $targetFolder)) {
                New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null
            }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $true)
        }
    } finally {
        $zip.Dispose()
    }
}

# Build the extensions.json entry object for one extension, matching the
# schema VSCode writes when it installs an extension from the gallery.
function New-ExtensionEntry {
    param(
        [hashtable]$Meta,        # from Get-MarketplaceMetadata
        [string]$ProfilePath     # e.g. C:\Users\Alice
    )

    $folderName      = "$($Meta.FullId)-$($Meta.Version)"
    $locationPath    = "/$(($ProfilePath -replace '\\','/' -replace ':','').TrimStart('/'))/.vscode/extensions/$folderName"

    return [ordered]@{
        identifier       = [ordered]@{
            id   = $Meta.FullId
            uuid = $Meta.Uuid
        }
        version          = $Meta.Version
        location         = [ordered]@{
            '$mid' = 1
            path   = $locationPath
            scheme = 'file'
        }
        relativeLocation = $folderName
        metadata         = [ordered]@{
            installedTimestamp   = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            pinned               = $false
            source               = 'gallery'
            id                   = $Meta.Uuid
            publisherId          = $Meta.PublisherId
            publisherDisplayName = $Meta.PublisherDisplayName
            targetPlatform       = 'undefined'
            updated              = $false
            private              = $false
            isPreReleaseVersion  = $false
            hasPreReleaseVersion = $false
            preRelease           = $false
        }
    }
}

# Read, merge, and write a user's extensions.json.
# Adds or replaces the entry for each extension by matching on identifier.id.
function Update-ExtensionsJson {
    param(
        [string]$ExtensionsDir,
        [array]$NewEntries        # array of ordered hashtables from New-ExtensionEntry
    )

    $jsonPath = Join-Path $ExtensionsDir 'extensions.json'

    # Load existing list (may not exist yet)
    $existing = @()
    if (Test-Path $jsonPath) {
        try {
            $existing = (Get-Content $jsonPath -Raw | ConvertFrom-Json)
            # ConvertFrom-Json returns PSCustomObject; keep as array
            if ($null -eq $existing) { $existing = @() }
        } catch {
            Write-Log "    Could not parse existing extensions.json — will overwrite." -Level WARN
            $existing = @()
        }
    }

    # Index existing entries by lower-case id for fast lookup
    $map = [ordered]@{}
    foreach ($e in $existing) {
        $key = $e.identifier.id.ToLower()
        $map[$key] = $e
    }

    # Upsert new entries
    foreach ($entry in $NewEntries) {
        $key = $entry.identifier.id.ToLower()
        if ($map.Contains($key)) {
            Write-Log "    ~ Updating extensions.json entry: $($entry.identifier.id)"
        } else {
            Write-Log "    + Adding extensions.json entry:   $($entry.identifier.id)"
        }
        $map[$key] = $entry
    }

    $merged = @($map.Values)

    # Ensure the directory exists (profile may have .vscode but not extensions yet)
    if (-not (Test-Path $ExtensionsDir)) {
        New-Item -ItemType Directory -Path $ExtensionsDir -Force | Out-Null
    }

    # ConvertTo-Json depth must be high enough for the nested structure
    $merged | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8 -Force
}

# ---------------------------------------------------------------------------
# Step 1 – Parse and validate extension IDs
# ---------------------------------------------------------------------------
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

Write-Log "Found $($extensionIds.Count) extension(s) to deploy."

# ---------------------------------------------------------------------------
# Step 2 – Resolve VS Code install path (for bootstrap folder)
# ---------------------------------------------------------------------------
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
    Write-Log "VS Code installation not found — bootstrap folder will be skipped." -Level WARN
}

# ---------------------------------------------------------------------------
# Step 3 – Collect real user profiles
# ---------------------------------------------------------------------------
$skipNames = @('Public', 'Default', 'Default User', 'All Users', 'defaultuser0')

$userProfiles = Get-ChildItem -Path $UserProfilesRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $skipNames -notcontains $_.Name }

Write-Log "Found $($userProfiles.Count) user profile(s): $($userProfiles.Name -join ', ')"

# ---------------------------------------------------------------------------
# Step 4 – Fetch marketplace metadata for all extensions
# ---------------------------------------------------------------------------
Write-Log "Fetching marketplace metadata..."

$allMeta = [ordered]@{}   # extensionId (lower) -> hashtable

foreach ($id in $extensionIds) {
    try {
        $meta = Get-MarketplaceMetadata -ExtensionId $id
        $allMeta[$id] = $meta
        Write-Log "  $id  =>  v$($meta.Version)  uuid=$($meta.Uuid)"
    } catch {
        Write-Log "  FAILED to fetch metadata for '$id': $_" -Level ERROR
    }
}

if ($allMeta.Count -eq 0) {
    Write-Log "No metadata could be fetched. Exiting." -Level ERROR
    exit 1
}

# ---------------------------------------------------------------------------
# Step 5 – Download .vsix files to a shared staging directory
# ---------------------------------------------------------------------------
$stagingDir = Join-Path $env:TEMP 'VSCodeExtensionDeploy'
if (-not (Test-Path $stagingDir)) {
    New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
}
Write-Log "Staging directory: $stagingDir"

$vsixFiles = [ordered]@{}   # extensionId -> local .vsix path

foreach ($id in $allMeta.Keys) {
    $meta     = $allMeta[$id]
    $vsixPath = Join-Path $stagingDir "$id.vsix"

    if (Test-Path $vsixPath) {
        Write-Log "  = Already staged: $id"
        $vsixFiles[$id] = $vsixPath
        continue
    }

    $publisher = $meta.Publisher
    $name      = $meta.Id
    $url       = "https://$publisher.gallery.vsassets.io/_apis/public/gallery/publisher/$publisher/extension/$name/latest/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage"

    Write-Log "  + Downloading: $id"
    try {
        Invoke-WebRequest -Uri $url -OutFile $vsixPath -UseBasicParsing -ErrorAction Stop
        $vsixFiles[$id] = $vsixPath
        Write-Log "    OK ($([math]::Round((Get-Item $vsixPath).Length / 1MB, 2)) MB)"
    } catch {
        Write-Log "    FAILED to download '$id': $_" -Level ERROR
        if (Test-Path $vsixPath) { Remove-Item $vsixPath -Force }
    }
}

if ($vsixFiles.Count -eq 0) {
    Write-Log "No extensions downloaded successfully. Exiting." -Level ERROR
    exit 1
}

# ---------------------------------------------------------------------------
# Step 6 – Deploy to each existing user profile
# ---------------------------------------------------------------------------
foreach ($profile in $userProfiles) {
    $extensionsDir = Join-Path $profile.FullName '.vscode\extensions'
    Write-Log "Processing user: $($profile.Name)"

    $newEntries = @()

    foreach ($id in $vsixFiles.Keys) {
        $meta       = $allMeta[$id]
        $folderName = "$($meta.FullId)-$($meta.Version)"
        $targetDir  = Join-Path $extensionsDir $folderName

        # --- Extract VSIX ---
        if (Test-Path $targetDir) {
            Write-Log "    = Already extracted: $id"
        } else {
            if ($PSCmdlet.ShouldProcess($targetDir, "Extract $id")) {
                try {
                    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                    Expand-Vsix -VsixPath $vsixFiles[$id] -DestinationDir $targetDir
                    Write-Log "    + Extracted: $id -> $folderName"
                } catch {
                    Write-Log "    FAILED extracting '$id': $_" -Level ERROR
                    if (Test-Path $targetDir) { Remove-Item $targetDir -Recurse -Force -ErrorAction SilentlyContinue }
                    continue   # don't add a broken entry to extensions.json
                }
            }
        }

        # Collect entry regardless of whether we just extracted or it was already there,
        # so extensions.json stays consistent even on re-runs.
        $newEntries += New-ExtensionEntry -Meta $meta -ProfilePath $profile.FullName
    }

    # --- Update extensions.json ---
    if ($newEntries.Count -gt 0) {
        if ($PSCmdlet.ShouldProcess((Join-Path $extensionsDir 'extensions.json'), "Update extensions.json for $($profile.Name)")) {
            try {
                Update-ExtensionsJson -ExtensionsDir $extensionsDir -NewEntries $newEntries
                Write-Log "    extensions.json updated."
            } catch {
                Write-Log "    FAILED updating extensions.json for '$($profile.Name)': $_" -Level ERROR
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Step 7 – Populate bootstrap folder for future new users
# ---------------------------------------------------------------------------
if ($VsCodeInstallPath) {
    $bootstrapDir = Join-Path $VsCodeInstallPath 'bootstrap\extensions'

    if (-not (Test-Path $bootstrapDir)) {
        Write-Log "Creating bootstrap folder: $bootstrapDir"
        if ($PSCmdlet.ShouldProcess($bootstrapDir, 'Create directory')) {
            New-Item -ItemType Directory -Path $bootstrapDir -Force | Out-Null
        }
    }

    foreach ($id in $vsixFiles.Keys) {
        $dest = Join-Path $bootstrapDir "$id.vsix"
        if (-not (Test-Path $dest)) {
            if ($PSCmdlet.ShouldProcess($dest, "Copy VSIX to bootstrap")) {
                Copy-Item -Path $vsixFiles[$id] -Destination $dest -Force
                Write-Log "  Bootstrap: $id.vsix"
            }
        } else {
            Write-Log "  Bootstrap: already present — $id.vsix"
        }
    }
}

# ---------------------------------------------------------------------------
# Step 8 – Summary
# ---------------------------------------------------------------------------
Write-Log "Done. Processed $($vsixFiles.Count) extension(s) across $($userProfiles.Count) user profile(s)."