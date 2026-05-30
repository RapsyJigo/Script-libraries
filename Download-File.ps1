<#
.SYNOPSIS
    Downloads a file from a URL and saves it to a specified directory preserving the original name.

.DESCRIPTION
    Downloads a file from the URL and saves it to the specified directory
    - does not rename the file

.EXAMPLE
    .\Download-File.ps1 -Url "https://example.com/report.pdf" -Destination "C:\Downloads"
    .\Download-File.ps1 -Url "https://example.com/archive.zip" -Destination "."   # current folder
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "The URL of the file to download.")]
    [string]$Url,

    [Parameter(Mandatory = $true, HelpMessage = "The folder where the file will be saved.")]
    [string]$Destination
)

# ── Resolve filename from URL ─────────────────────────────────────────────────
try {
    $uri      = [System.Uri]$Url
    $fileName = [System.IO.Path]::GetFileName($uri.LocalPath)
 
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        Write-Error "Could not determine a filename from the URL: '$Url'."
        exit 1
    }
} catch {
    Write-Error "Invalid URL: '$Url'. $_"
    exit 1
}
 
# ── Ensure destination folder exists ─────────────────────────────────────────
if (-not (Test-Path -Path $Destination -PathType Container)) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
}
 
$outputPath = Join-Path -Path $Destination -ChildPath $fileName
 
# ── Download ─────────────────────────────────────────────────────────────────
try {
    $client = [System.Net.WebClient]::new()
    $client.DownloadFile($Url, $outputPath)
    $client.Dispose()
} catch {
    Write-Error "Download error: $_"
    exit 1
}
 
# ── Verify ───────────────────────────────────────────────────────────────────
if (Test-Path -Path $outputPath) {
    $size = (Get-Item $outputPath).Length
    Write-Host "Done! '$fileName' saved ($size bytes) at '$Destination'." -ForegroundColor Green
} else {
    Write-Error "File was not saved. Something went wrong."
    exit 1
}