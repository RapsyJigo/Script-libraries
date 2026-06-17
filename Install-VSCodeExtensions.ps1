#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs VSCode extensions for all users on the system using Microsoft's
    bootstrapping mechanism (machine-wide extensions.json).

.DESCRIPTION
    Parses a CSV string of extension IDs and registers them in the machine-wide
    VSCode bootstrapping file (%ProgramData%\Microsoft\VSCode\extensions.json).
    VSCode reads this file on startup and automatically installs any listed
    extensions for the current user if they are not already installed.

    This uses the official Microsoft-intended approach for pre-deploying default
    extensions in enterprise/Intune scenarios — no per-user CLI invocation needed.

.PARAMETER ExtensionsCsv
    A CSV-formatted string of extension IDs.
    Values may be comma-separated, newline-separated, or both.
    Extension IDs must follow the format: publisher.extensionname
    An optional header token of "extensionid" is automatically skipped.

.PARAMETER Force
    If specified, overwrites the existing extensions.json entirely.
    By default, the script merges new IDs with any existing entries.

.EXAMPLE
    .\Install-VSCodeExtensions.ps1 -ExtensionsCsv "ms-python.python,esbenp.prettier-vscode,dbaeumer.vscode-eslint"

.EXAMPLE
    $csv = @"
ms-python.python
esbenp.prettier-vscode
dbaeumer.vscode-eslint
"@
    .\Install-VSCodeExtensions.ps1 -ExtensionsCsv $csv -Force

.NOTES
    References:
        https://code.visualstudio.com/docs/setup/enterprise#_default-extensions
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory, HelpMessage = "Comma or newline-separated extension IDs (publisher.name).")]
    [string]$ExtensionsCsv,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$BootstrapDir  = Join-Path $env:ProgramData 'Microsoft\VSCode'
$BootstrapFile = Join-Path $BootstrapDir    'extensions.json'

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
# Step 1 – Parse and validate the CSV string
# ---------------------------------------------------------------------------
Write-Log "Parsing extension list from input string."

$ExtensionIdPattern = '^[A-Za-z0-9_-]+\.[A-Za-z0-9_.-]+$'

# Split on commas and/or newlines, then normalise each token
$newIds = $ExtensionsCsv -split '[,\r\n]+' |
    ForEach-Object { $_.Trim().ToLower() } |
    Where-Object   { $_ -ne '' } |
    Where-Object   {
        # Skip an optional header token (e.g. "extensionid")
        if ($_ -eq 'extensionid') { return $false }

        if ($_ -notmatch $ExtensionIdPattern) {
            Write-Log "Skipping invalid extension ID: '$_'" -Level WARN
            $false
        } else { $true }
    } |
    Sort-Object -Unique

if ($newIds.Count -eq 0) {
    Write-Log "No valid extension IDs found in the input. Exiting." -Level WARN
    exit 0
}

Write-Log "Found $($newIds.Count) valid extension ID(s)."

# ---------------------------------------------------------------------------
# Step 2 – Load existing bootstrap file (merge unless -Force)
# ---------------------------------------------------------------------------
$mergedIds = [System.Collections.Generic.List[string]]::new()

if (-not $Force -and (Test-Path $BootstrapFile)) {
    Write-Log "Merging with existing bootstrap file: $BootstrapFile"
    try {
        $existing = Get-Content -Path $BootstrapFile -Raw | ConvertFrom-Json

        # The file is a JSON array of strings
        if ($existing -is [System.Array]) {
            foreach ($id in $existing) {
                $normalised = $id.Trim().ToLower()
                if ($normalised -ne '' -and $mergedIds -notcontains $normalised) {
                    $mergedIds.Add($normalised)
                }
            }
            Write-Log "Loaded $($mergedIds.Count) existing extension ID(s)."
        } else {
            Write-Log "Existing file is not a JSON array — treating as empty." -Level WARN
        }
    } catch {
        Write-Log "Could not parse existing extensions.json: $_" -Level WARN
        Write-Log "Proceeding with input entries only." -Level WARN
    }
} elseif ($Force) {
    Write-Log "-Force specified: existing bootstrap file will be overwritten."
}

# Merge new IDs
foreach ($id in $newIds) {
    if ($mergedIds -notcontains $id) {
        $mergedIds.Add($id)
        Write-Log "  + Adding: $id"
    } else {
        Write-Log "  = Already present: $id"
    }
}

# ---------------------------------------------------------------------------
# Step 3 – Write the bootstrap file
# ---------------------------------------------------------------------------
if (-not (Test-Path $BootstrapDir)) {
    Write-Log "Creating directory: $BootstrapDir"
    if ($PSCmdlet.ShouldProcess($BootstrapDir, 'Create directory')) {
        New-Item -ItemType Directory -Path $BootstrapDir -Force | Out-Null
    }
}

$json = $mergedIds | ConvertTo-Json -Depth 1

if ($PSCmdlet.ShouldProcess($BootstrapFile, 'Write extensions.json')) {
    Set-Content -Path $BootstrapFile -Value $json -Encoding UTF8 -Force
    Write-Log "Bootstrap file written: $BootstrapFile"
}

# ---------------------------------------------------------------------------
# Step 4 – Summary
# ---------------------------------------------------------------------------
Write-Log "Done. $($mergedIds.Count) total extension(s) registered."
Write-Log "VSCode will install missing extensions automatically on next launch per user."