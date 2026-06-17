#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deploys VSCode extensions to all users on the machine, running as SYSTEM.

.DESCRIPTION
    Two complementary approaches are combined:

    1. EXISTING USERS — For every profile found under C:\Users, the script extracts
       each .vsix directly into that user's %USERPROFILE%\.vscode\extensions folder.
       VSCode treats any correctly-structured folder there as an installed extension;
       no RunAs or per-user process invocation is needed.

    2. NEW USERS (bootstrap) — The .vsix files are also placed in the
       bootstrap\extensions folder inside the VS Code installation directory so that
       any user who has never launched VS Code will have the extensions installed
       silently on their first launch.

    A .vsix is a ZIP archive. Its contents live under an internal "extension/"
    prefix. The script strips that prefix and extracts into a folder named
    "<publisher>.<name>-<version>" to match the layout VSCode expects.

.PARAMETER ExtensionsCsv
    A comma or newline-separated string of extension IDs in publisher.name format.

.PARAMETER VsCodeInstallPath
    Path to the VS Code installation directory. Auto-detected if omitted.

.PARAMETER UserProfilesRoot
    Root folder that contains user profile directories. Defaults to C:\Users.

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
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = @{ INFO = 'Cyan'; WARN = 'Yellow'; ERROR = 'Red' }[$Level]
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $color
}

# Expand a .vsix into a destination directory.
# A .vsix is a ZIP. All extension files live under an internal "extension/" folder.
# VSCode expects the layout: <publisher>.<name>-<version>\<files...>
function Expand-Vsix {
    param(
        [string]$VsixPath,
        [string]$DestinationDir   # full target path, e.g. …\.vscode\extensions\pub.name-1.2.3
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $zip = [System.IO.Compression.ZipFile]::OpenRead($VsixPath)
    try {
        foreach ($entry in $zip.Entries) {
            # Strip the leading "extension/" prefix that vsce puts on every file
            if ($entry.FullName -notlike 'extension/*') { continue }
            $relativePath = $entry.FullName.Substring('extension/'.Length)

            # Skip directory entries (they have empty Name)
            if ([string]::IsNullOrEmpty($entry.Name)) { continue }

            $targetPath = Join-Path $DestinationDir $relativePath
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

# Read the version from the package.json inside a .vsix without fully extracting it.
function Get-VsixVersion {
    param([string]$VsixPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($VsixPath)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq 'extension/package.json' } | Select-Object -First 1
        if (-not $entry) { return $null }
        $reader = [System.IO.StreamReader]::new($entry.Open())
        $json = $reader.ReadToEnd() | ConvertFrom-Json
        $reader.Dispose()
        return $json.version
    } finally {
        $zip.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Step 1 – Parse and validate the extension ID list
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
# Step 2 – Resolve VS Code installation path (for bootstrap folder)
# ---------------------------------------------------------------------------
if (-not $VsCodeInstallPath) {
    $systemInstall = "$env:ProgramFiles\Microsoft VS Code"
    $userInstall   = "$env:LOCALAPPDATA\Programs\Microsoft VS Code"

    if     (Test-Path $systemInstall) { $VsCodeInstallPath = $systemInstall }
    elseif (Test-Path $userInstall)   { $VsCodeInstallPath = $userInstall }
    else {
        Write-Log "VS Code installation not found. Bootstrap folder will be skipped." -Level WARN
        $VsCodeInstallPath = $null
    }
}

if ($VsCodeInstallPath) {
    Write-Log "VS Code install: $VsCodeInstallPath"
}

# ---------------------------------------------------------------------------
# Step 3 – Collect real user profiles (skip system/service accounts)
# ---------------------------------------------------------------------------
$skipNames = @('Public', 'Default', 'Default User', 'All Users', 'defaultuser0')

$userProfiles = Get-ChildItem -Path $UserProfilesRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $skipNames -notcontains $_.Name }

if ($userProfiles.Count -eq 0) {
    Write-Log "No user profiles found under $UserProfilesRoot." -Level WARN
}

Write-Log "Found $($userProfiles.Count) user profile(s): $($userProfiles.Name -join ', ')"

# ---------------------------------------------------------------------------
# Step 4 – Download all .vsix files to a temp staging directory
# ---------------------------------------------------------------------------
$stagingDir = Join-Path $env:TEMP 'VSCodeExtensionDeploy'
if (-not (Test-Path $stagingDir)) {
    New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
}
Write-Log "Staging directory: $stagingDir"

# Map of extensionId -> local .vsix path (only successfully downloaded ones)
$vsixFiles = @{}

foreach ($id in $extensionIds) {
    $vsixPath = Join-Path $stagingDir "$id.vsix"

    if (Test-Path $vsixPath) {
        Write-Log "  = Already staged: $id"
        $vsixFiles[$id] = $vsixPath
        continue
    }

    $publisher, $name = $id -split '\.', 2
    $url = "https://$publisher.gallery.vsassets.io/_apis/public/gallery/publisher/$publisher/extension/$name/latest/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage"

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
    Write-Log "No extensions were downloaded successfully. Exiting." -Level ERROR
    exit 1
}

# ---------------------------------------------------------------------------
# Step 5 – Extract version from each vsix so we can name the folder correctly
# ---------------------------------------------------------------------------
$extensionMeta = @{}   # id -> @{ Version; FolderName }

foreach ($id in $vsixFiles.Keys) {
    $version = Get-VsixVersion -VsixPath $vsixFiles[$id]
    if (-not $version) {
        Write-Log "Could not read version from $id — skipping." -Level WARN
        continue
    }
    $extensionMeta[$id] = @{
        Version    = $version
        FolderName = "$id-$version"   # e.g. esbenp.prettier-vscode-10.4.0
    }
    Write-Log "  $id  =>  version $version"
}

# ---------------------------------------------------------------------------
# Step 6 – Extract into every existing user's .vscode\extensions folder
# ---------------------------------------------------------------------------
$successUsers = 0
$failUsers    = 0

foreach ($profile in $userProfiles) {
    $extensionsDir = Join-Path $profile.FullName '.vscode\extensions'

    Write-Log "Processing user: $($profile.Name)"

    foreach ($id in $extensionMeta.Keys) {
        $meta      = $extensionMeta[$id]
        $targetDir = Join-Path $extensionsDir $meta.FolderName

        if (Test-Path $targetDir) {
            Write-Log "    = Already installed for $($profile.Name): $id"
            continue
        }

        if ($PSCmdlet.ShouldProcess($targetDir, "Extract $id for $($profile.Name)")) {
            try {
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                Expand-Vsix -VsixPath $vsixFiles[$id] -DestinationDir $targetDir
                Write-Log "    + Installed: $id  ->  $targetDir"
                $successUsers++
            } catch {
                Write-Log "    FAILED extracting '$id' for '$($profile.Name)': $_" -Level ERROR
                # Remove partially-extracted folder to avoid a broken state
                if (Test-Path $targetDir) { Remove-Item $targetDir -Recurse -Force -ErrorAction SilentlyContinue }
                $failUsers++
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Step 7 – Copy .vsix files into the bootstrap folder (for future new users)
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
            if ($PSCmdlet.ShouldProcess($dest, "Copy bootstrap VSIX for $id")) {
                Copy-Item -Path $vsixFiles[$id] -Destination $dest -Force
                Write-Log "  Bootstrap: copied $id.vsix"
            }
        } else {
            Write-Log "  Bootstrap: already present $id.vsix"
        }
    }
} else {
    Write-Log "Skipping bootstrap folder (VS Code install path not found)." -Level WARN
}

# ---------------------------------------------------------------------------
# Step 8 – Summary
# ---------------------------------------------------------------------------
Write-Log "Done."
Write-Log "  Extensions deployed to existing users : $successUsers install(s), $failUsers failure(s)"
Write-Log "  Bootstrap folder populated for new users: $($VsCodeInstallPath -ne $null)"