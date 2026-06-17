#Requires -Version 5.1
<#
.SYNOPSIS
  Finds a folder matching a regex pattern, zips it, and uploads the archive to
  an Upload-Download-Server instance.

.DESCRIPTION
  1. Scans -SearchPath for a sub-directory whose name matches -FolderRegex.
  2. Compresses the first match into a temporary .zip file.
  3. POSTs the zip to <ServerUrl>/upload-chunk as a multipart/form-data upload
     (the same endpoint used by the server's built-in progress uploader).
  4. Cleans up the temporary zip on exit.

.PARAMETER ServerUrl
  Base URL of the running Upload-Download-Server, e.g. http://192.168.1.10 or
  http://192.168.1.10:9090. No trailing slash required.

.PARAMETER SearchPath
  Directory to search for the target folder. Defaults to the current directory.

.PARAMETER FolderRegex
  Regular expression matched against sub-directory names found directly inside
  -SearchPath. The first match is used.

.PARAMETER Recurse
  When specified, searches all descendant directories, not just the immediate
  children of -SearchPath.

.EXAMPLE
  .\Send-FolderToServer.ps1 -ServerUrl "http://192.168.1.50" `
      -SearchPath "C:\Students" -FolderRegex "^JohnDoe_"

.EXAMPLE
  .\Send-FolderToServer.ps1 -ServerUrl "http://192.168.1.50:9090" `
      -SearchPath "D:\Work" -FolderRegex "Project_2026" -Recurse
#>
param(
    [Parameter(Mandatory = $true,  HelpMessage = "Base URL of the Upload-Download-Server (e.g. http://192.168.1.10:80)")]
    [string] $ServerUrl,

    [Parameter(Mandatory = $false, HelpMessage = "Directory to search in. Defaults to the current directory.")]
    [string] $SearchPath = ".",

    [Parameter(Mandatory = $true,  HelpMessage = "Regex pattern to match a sub-directory name.")]
    [string] $FolderRegex
)

$ErrorActionPreference = "Stop"

# ── Helpers ───────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [ValidateSet('Info','Ok','Warn','Error')][string]$Level = 'Info')
    $ts    = Get-Date -Format 'HH:mm:ss.fff'
    $color = switch ($Level) {
        'Ok'    { 'Green'  }
        'Warn'  { 'Yellow' }
        'Error' { 'Red'    }
        default { 'Gray'   }
    }
    Write-Host "[$ts] $Message" -ForegroundColor $color
}

# ── Validate inputs ───────────────────────────────────────────────────────────

# Normalise server URL (strip trailing slash)
$ServerUrl = $ServerUrl.TrimEnd('/')

# Validate regex syntax early
try {
    [void][System.Text.RegularExpressions.Regex]::new($FolderRegex)
} catch {
    Write-Log "Invalid -FolderRegex pattern: $_" -Level Error
    exit 1
}

# Resolve search path
$resolvedSearch = Resolve-Path -LiteralPath $SearchPath -ErrorAction SilentlyContinue
if (-not $resolvedSearch) {
    Write-Log "Search path not found: '$SearchPath'" -Level Error
    exit 1
}
$resolvedSearch = $resolvedSearch.ProviderPath
Write-Log "Search path : $resolvedSearch"
Write-Log "Pattern     : $FolderRegex"
Write-Log "Server      : $ServerUrl"

# ── Find the target folder ────────────────────────────────────────────────────

$getChildArgs = @{
    Path      = $resolvedSearch
    Directory = $true
}

$match = Get-ChildItem @getChildArgs |
         Where-Object { $_.Name -match $FolderRegex } |
         Select-Object -First 1

if (-not $match) {
    Write-Log "No directory matching '$FolderRegex' found under '$resolvedSearch'." -Level Error
    exit 1
}

$targetFolder = $match.FullName
Write-Log "Matched folder: $targetFolder" -Level Ok

# ── Zip the folder ────────────────────────────────────────────────────────────

Add-Type -AssemblyName System.IO.Compression.FileSystem

$zipName    = "$($match.Name)_$(Get-Date -Format 'yyyyMMdd_HHmmss').zip"
$zipPath    = Join-Path $env:TEMP $zipName

Write-Log "Compressing to: $zipPath"
try {
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $targetFolder,
        $zipPath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $true   # include the root folder name inside the zip
    )
} catch {
    Write-Log "Failed to create zip archive: $_" -Level Error
    exit 1
}

$zipSize = (Get-Item $zipPath).Length
Write-Log "Archive size  : $([math]::Round($zipSize / 1MB, 2)) MB" -Level Ok

# ── Upload to server ──────────────────────────────────────────────────────────
# The server's /upload-chunk endpoint accepts a standard multipart/form-data
# POST with a single file field named "file".

$uploadUrl = "$ServerUrl/upload-chunk"
Write-Log "Uploading to  : $uploadUrl"

try {
    # Build multipart body manually for compatibility with PS 5.1
    $boundary  = "----PSUploadBoundary$([Guid]::NewGuid().ToString('N'))"
    $fileBytes = [System.IO.File]::ReadAllBytes($zipPath)
    $enc       = [System.Text.Encoding]::UTF8

    # Part header
    $partHeader  = "--$boundary`r`n"
    $partHeader += "Content-Disposition: form-data; name=`"file`"; filename=`"$zipName`"`r`n"
    $partHeader += "Content-Type: application/zip`r`n`r`n"

    # Part footer
    $partFooter  = "`r`n--$boundary--`r`n"

    $headerBytes = $enc.GetBytes($partHeader)
    $footerBytes = $enc.GetBytes($partFooter)

    # Combine into a single byte array
    $body = New-Object byte[] ($headerBytes.Length + $fileBytes.Length + $footerBytes.Length)
    [Buffer]::BlockCopy($headerBytes, 0, $body, 0,                                         $headerBytes.Length)
    [Buffer]::BlockCopy($fileBytes,   0, $body, $headerBytes.Length,                       $fileBytes.Length)
    [Buffer]::BlockCopy($footerBytes, 0, $body, $headerBytes.Length + $fileBytes.Length,   $footerBytes.Length)

    $webReq                 = [System.Net.WebRequest]::Create($uploadUrl)
    $webReq.Method          = "POST"
    $webReq.ContentType     = "multipart/form-data; boundary=$boundary"
    $webReq.ContentLength   = $body.Length
    $webReq.Timeout         = 300000   # 5 minutes

    $stream = $webReq.GetRequestStream()
    $stream.Write($body, 0, $body.Length)
    $stream.Close()

    $response   = $webReq.GetResponse()
    $reader     = New-Object System.IO.StreamReader($response.GetResponseStream())
    $responseBody = $reader.ReadToEnd()
    $reader.Close()
    $response.Close()

    $statusCode = [int]$response.StatusCode
    if ($statusCode -eq 200) {
        Write-Log "Upload successful! Server responded: $responseBody" -Level Ok
    } else {
        Write-Log "Server returned HTTP $statusCode : $responseBody" -Level Warn
        exit 1
    }
} catch [System.Net.WebException] {
    $webEx    = $_.Exception
    $errBody  = ""
    if ($webEx.Response) {
        try {
            $errReader = New-Object System.IO.StreamReader($webEx.Response.GetResponseStream())
            $errBody   = $errReader.ReadToEnd()
            $errReader.Close()
        } catch {}
        $httpStatus = [int]([System.Net.HttpWebResponse]$webEx.Response).StatusCode
        Write-Log "HTTP $httpStatus from server: $errBody" -Level Error
    } else {
        Write-Log "Network error: $($webEx.Message)" -Level Error
    }
    exit 1
} catch {
    Write-Log "Unexpected error during upload: $_" -Level Error
    exit 1
} finally {
    # ── Cleanup ───────────────────────────────────────────────────────────────
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        Write-Log "Temporary zip deleted." -Level Info
    }
}