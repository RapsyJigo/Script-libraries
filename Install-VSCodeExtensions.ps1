#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Pre-installs VSCode extensions for all users via the official bootstrap mechanism.

.DESCRIPTION
    Downloads .vsix files from the VS Code Marketplace and places them in the
    bootstrap\extensions folder inside the VS Code installation directory.
    On next launch, VS Code silently installs any extensions found in that folder
    for the current user — this is the Microsoft-intended enterprise deployment path.

    Supports both system-wide installs (C:\Program Files\Microsoft VS Code) and
    per-user installs (%LocalAppData%\Programs\Microsoft VS Code).

.PARAMETER ExtensionsCsv
    A comma or newline-separated string of extension IDs in publisher.name format.

.PARAMETER VsCodeInstallPath
    Path to the VS Code installation directory. If omitted, the script auto-detects
    the system install, then falls back to the current user's local install.

.EXAMPLE
    .\Install-VSCodeExtensions.ps1 -ExtensionsCsv "ms-python.python,esbenp.prettier-vscode"

.EXAMPLE
    $csv = @"
ms-python.python
esbenp.prettier-vscode
dbaeumer.vscode-eslint
"@
    .\Install-VSCodeExtensions.ps1 -ExtensionsCsv $csv

.NOTES
    Extensions are only installed on a user's FIRST launch of VS Code.
    If a user has already launched VS Code, this will not reinstall extensions
    they have previously uninstalled.

    References:
        https://code.visualstudio.com/docs/enterprise/extensions#_bootstrapping-extensions
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory, HelpMessage = "Comma or newline-separated extension IDs (publisher.name).")]
    [string]$ExtensionsCsv,

    [string]$VsCodeInstallPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helper: Write timestamped log lines
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = @{ INFO = 'Cyan'; WARN = 'Yellow'; ERROR = 'Red' }[$Level]
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $color
}

# ---------------------------------------------------------------------------
# Step 1 – Resolve VS Code installation path
# ---------------------------------------------------------------------------
if ($VsCodeInstallPath) {
    if (-not (Test-Path $VsCodeInstallPath)) {
        Write-Log "Specified VsCodeInstallPath does not exist: $VsCodeInstallPath" -Level ERROR
        exit 1
    }
} else {
    # Prefer the system-wide install (requires admin, covers all users cleanly)
    $systemInstall = "$env:ProgramFiles\Microsoft VS Code"
    $userInstall   = "$env:LOCALAPPDATA\Programs\Microsoft VS Code"

    if (Test-Path $systemInstall) {
        $VsCodeInstallPath = $systemInstall
        Write-Log "Detected system-wide VS Code install: $VsCodeInstallPath"
    } elseif (Test-Path $userInstall) {
        $VsCodeInstallPath = $userInstall
        Write-Log "Detected per-user VS Code install: $VsCodeInstallPath" -Level WARN
        Write-Log "Note: bootstrapping from a per-user install only affects that user." -Level WARN
    } else {
        Write-Log "VS Code installation not found. Pass -VsCodeInstallPath explicitly." -Level ERROR
        exit 1
    }
}

$bootstrapDir = Join-Path $VsCodeInstallPath 'bootstrap\extensions'

# ---------------------------------------------------------------------------
# Step 2 – Parse and validate the extension ID list
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

Write-Log "Found $($extensionIds.Count) extension(s) to process."

# ---------------------------------------------------------------------------
# Step 3 – Create bootstrap\extensions folder
# ---------------------------------------------------------------------------
if (-not (Test-Path $bootstrapDir)) {
    Write-Log "Creating bootstrap folder: $bootstrapDir"
    if ($PSCmdlet.ShouldProcess($bootstrapDir, 'Create directory')) {
        New-Item -ItemType Directory -Path $bootstrapDir -Force | Out-Null
    }
} else {
    Write-Log "Bootstrap folder already exists: $bootstrapDir"
}

# ---------------------------------------------------------------------------
# Step 4 – Download each extension as a .vsix from the marketplace
# ---------------------------------------------------------------------------
$successCount = 0
$failCount    = 0

foreach ($id in $extensionIds) {
    $publisher, $name = $id -split '\.', 2
    $vsixPath = Join-Path $bootstrapDir "$id.vsix"

    if (Test-Path $vsixPath) {
        Write-Log "  = Already present, skipping: $id"
        $successCount++
        continue
    }

    # Use the gallery CDN URL which supports /latest/ without needing a version lookup
    $downloadUrl = "https://$publisher.gallery.vsassets.io/_apis/public/gallery/publisher/$publisher/extension/$name/latest/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage"

    Write-Log "  + Downloading: $id"

    if ($PSCmdlet.ShouldProcess($id, 'Download VSIX')) {
        try {
            Invoke-WebRequest -Uri $downloadUrl -OutFile $vsixPath -UseBasicParsing -ErrorAction Stop
            $sizeMB = [math]::Round((Get-Item $vsixPath).Length / 1MB, 2)
            Write-Log "    Saved to: $vsixPath ($sizeMB MB)"
            $successCount++
        } catch {
            Write-Log "    Failed to download '$id': $_" -Level ERROR
            # Clean up a partial file if it exists
            if (Test-Path $vsixPath) { Remove-Item $vsixPath -Force }
            $failCount++
        }
    }
}

# ---------------------------------------------------------------------------
# Step 5 – Summary
# ---------------------------------------------------------------------------
Write-Log "Done. $successCount extension(s) ready in bootstrap folder, $failCount failed."
Write-Log "Path: $bootstrapDir"
Write-Log "VS Code will install these extensions silently on each user's first launch."