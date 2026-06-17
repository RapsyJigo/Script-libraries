# Download-File.ps1
# Downloads a file from a URL and saves it to a specified directory,
# preserving the original filename from the URL.
# If the file is an archive, it will be extracted automatically.
# Extraction uses 7-Zip if installed, otherwise falls back to Expand-Archive (zip only).
#
# USAGE:
#   .\Download-File.ps1 -Url <url> -Destination <folder>
#
# EXAMPLES:
#   .\Download-File.ps1 -Url "https://example.com/report.pdf" -Destination "C:\Downloads"
#   .\Download-File.ps1 -Url "https://example.com/archive.zip" -Destination "."
#   .\Download-File.ps1 -Url "https://example.com/download?name=archive.zip" -Destination "."

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "The URL of the file to download.")]
    [string]$Url,

    [Parameter(Mandatory = $true, HelpMessage = "The folder where the file will be saved.")]
    [string]$Destination
)

# --- Resolve filename ---
# Priority: 1) Content-Disposition header  2) URL path segment
function Resolve-Filename {
    param([string]$Url)

    $fileName = $null

    # Send a HEAD request to read headers without downloading the body
    try {
        $req                   = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method            = 'HEAD'
        $req.AllowAutoRedirect = $true
        $res                   = $req.GetResponse()

        # 1) Content-Disposition: attachment; filename="something.zip"
        $cd = $res.Headers['Content-Disposition']
        if ($cd -match 'filename\*=UTF-8''''(.+)') {
            $fileName = [System.Uri]::UnescapeDataString($Matches[1].Trim('"'))
        } elseif ($cd -match 'filename=["]?([^";]+)["]?') {
            $fileName = $Matches[1].Trim()
        }

        # 2) Fallback: last path segment of the URL (ignores query string)
        if ([string]::IsNullOrWhiteSpace($fileName)) {
            $uri     = [System.Uri]$Url
            $segment = [System.IO.Path]::GetFileName($uri.LocalPath)
            if (-not [string]::IsNullOrWhiteSpace($segment) -and $segment -ne '/') {
                $fileName = $segment
            }
        }

        $res.Close()
    } catch {
        # HEAD not supported — fall back to URL path only
        $uri     = [System.Uri]$Url
        $segment = [System.IO.Path]::GetFileName($uri.LocalPath)
        if (-not [string]::IsNullOrWhiteSpace($segment) -and $segment -ne '/') {
            $fileName = $segment
        }
    }

    return $fileName
}

try {
    $fileName = Resolve-Filename -Url $Url
} catch {
    Write-Error "Could not resolve filename: $_"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($fileName)) {
    Write-Error "Could not determine filename from URL or response headers. Try renaming the file on the server or setting a Content-Disposition header."
    exit 1
}
 
# ────────────────────────────────────────────────────────────────────────
# >> Ensure destination folder exists
# ────────────────────────────────────────────────────────────────────────
if (-not (Test-Path -Path $Destination -PathType Container)) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
}

$outputPath = Join-Path -Path $Destination -ChildPath $fileName
 
# ────────────────────────────────────────────────────────────────────────
# >> Comment
# ────────────────────────────────────────────────────────────────────────
try {
    $client = [System.Net.WebClient]::new()
    $client.DownloadFile($Url, $outputPath)
    $client.Dispose()
} catch {
    Write-Error "Download error: $_"
    exit 1
}

# ────────────────────────────────────────────────────────────────────────
# >> Verify
# ────────────────────────────────────────────────────────────────────────

if (Test-Path -Path $outputPath) {
    $size = (Get-Item $outputPath).Length
    Write-Host "Done! '$fileName' saved ($size bytes)." -ForegroundColor Green
} else {
    Write-Error "File was not saved. Something went wrong."
    exit 1
}


# --- Unzip if the downloaded file is an archive ---
$sevenZipExtensions = @('.7z', '.rar', '.tar', '.tar.gz', '.tgz', '.tar.bz2', '.tbz2', '.tar.xz', '.txz', '.gz', '.bz2', '.xz', '.iso', '.zip')
$zipOnlyExtensions  = @('.zip')

# Match extension — check compound extensions like .tar.gz first
$ext = $null
foreach ($candidate in ($sevenZipExtensions | Sort-Object { $_.Length } -Descending)) {
    if ($fileName.ToLower().EndsWith($candidate)) {
        $ext = $candidate
        break
    }
}

if ($ext) {
    $sevenZip = @(
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    try {
        if ($sevenZip) {
            & $sevenZip x $outputPath "-o$Destination" -y | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "7-Zip exited with code $LASTEXITCODE" }
            Write-Host "Extracted '$fileName' using 7-Zip." -ForegroundColor Green
        } elseif ($zipOnlyExtensions -contains $ext) {
            Expand-Archive -Path $outputPath -DestinationPath $Destination -Force
            Write-Host "Extracted '$fileName' using built-in Expand-Archive." -ForegroundColor Green
        } else {
            Write-Error "Cannot extract '$fileName': 7-Zip is required for '$ext' archives but was not found."
            exit 1
        }
    } catch {
        Write-Error "Extraction failed: $_"
        exit 1
    }
}