#Requires -Version 5.1
<#
.SYNOPSIS
    Simple HTTP File Server - Upload & Password-Protected Download

.DESCRIPTION
    Hosts web pages:
      /         -> Upload page (anyone can upload files)
      /download -> Password-protected download page
      /admin    -> Localhost-only settings (live-updatable)

.PARAMETER Port
    TCP port to listen on. Default: 80

.PARAMETER UploadFolder
    Folder where uploaded files are saved. Default: .\uploads

.PARAMETER Password
    Password required to access the download page. Default: changeme

.PARAMETER UploadFileRegex
  Optional regex pattern upload filenames must match (original name, before save).
  Empty string disables validation. Can also be changed live on /admin (localhost only).

.PARAMETER MaxUploadSize
  Maximum upload size in bytes. 0 = unlimited. Can also be changed live on /admin (localhost only).

.EXAMPLE
    .\FileServer.ps1
    .\FileServer.ps1 -Port 9090 -Password "s3cr3t!" -UploadFolder "C:\shared"
    .\FileServer.ps1 -UploadFileRegex '\.(pdf|docx)$'
#>
param(
    [Parameter(Mandatory = $false, HelpMessage = "The port on which the server will be opened. Must have no other processes using this port.")]
    [int]    $Port         = 80,

    [Parameter(Mandatory = $false, HelpMessage = "The folder where all the files will be saved to, you can put your own files there if you only wish to use the download part of the server without going through uploading")]
    [string] $UploadFolder = ".\uploads",

    [Parameter(Mandatory = $true, HelpMessage = "The password to be used to access the download page. If the password is left as a blank string the server will run in unsecure mode.")]
    [AllowEmptyString()]
    [string] $Password     = "",

    [Parameter(Mandatory = $false, HelpMessage = "Regex pattern upload filenames must match. Empty = no restriction.")]
    [AllowEmptyString()]
    [string] $UploadFileRegex = "",

    [Parameter(Mandatory = $false, HelpMessage = "Maximum upload size in bytes. 0 = unlimited.")]
    [long] $MaxUploadSize = 0
)

# ── Setup ────────────────────────────────────────────────────────────────────
$ErrorActionPreference = "Stop"

function Write-ServerLog {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warn', 'Error', 'Debug', 'Ok')]
        [string]$Level = 'Info'
    )
    $ts = Get-Date -Format 'HH:mm:ss.fff'
    $color = switch ($Level) {
        'Error' { 'Red' }
        'Warn'  { 'Yellow' }
        'Ok'    { 'Green' }
        'Debug' { 'DarkGray' }
        default { 'Gray' }
    }
    Write-Host "[$ts] $Message" -ForegroundColor $color
}

Write-ServerLog "Server is starting..." -Level Info
$resolvedUploadFolder = (New-Item -ItemType Directory -Force -Path $UploadFolder).FullName
Write-ServerLog "Upload folder resolved: $resolvedUploadFolder" -Level Debug

# Live settings (also seeded from parameters; /admin can update at runtime)
$script:ServerSettings = @{
    UploadFileRegex = $UploadFileRegex
    Password        = $Password
    UploadFolder    = $resolvedUploadFolder
    MaxUploadSize   = $MaxUploadSize
}

# ── Self-Elevation ───────────────────────────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-ServerLog "Not running as Administrator — relaunching elevated..." -Level Warn
    $url     = 'https://raw.githubusercontent.com/RapsyJigo/Script-libraries/refs/heads/main/Upload-Download-Server.ps1'
    $escapedRegex = $UploadFileRegex -replace "'", "''"
    $argList = "-NoExit -ExecutionPolicy Bypass -Command `"& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing '$url').Content)) -Port $Port -UploadFolder '$resolvedUploadFolder' -Password '$Password' -UploadFileRegex '$escapedRegex' -MaxUploadSize $MaxUploadSize`""
    Start-Process powershell -Verb RunAs -ArgumentList $argList
    exit
}

# Simple in-memory session store  { token -> expiry }
$Sessions = [System.Collections.Concurrent.ConcurrentDictionary[string,datetime]]::new()

function New-SessionToken {
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes) -replace '[/+=]', 'x'
}

function Test-Session([string]$token) {
    if ([string]::IsNullOrEmpty($script:ServerSettings.Password)) { return $true }  # open-access mode
    if ([string]::IsNullOrEmpty($token)) {
        Write-ServerLog "Session check: no token cookie" -Level Debug
        return $false
    }
    $expiry = [datetime]::MinValue
    if ($Sessions.TryGetValue($token, [ref]$expiry)) {
        if ((Get-Date) -lt $expiry) {
            Write-ServerLog "Session valid for token (expires $($expiry.ToString('HH:mm:ss')))" -Level Debug
            return $true
        }
        $Sessions.TryRemove($token, [ref]$expiry) | Out-Null
        Write-ServerLog "Session expired — removed token" -Level Debug
    }
    Write-ServerLog "Session invalid or unknown token" -Level Debug
    return $false
}

function Get-CookieToken([System.Net.HttpListenerRequest]$req) {
    $cookie = $req.Cookies["ds"]
    if ($cookie) { return $cookie.Value }
    return ""
}

function Test-IsLocalRequest([System.Net.HttpListenerRequest]$req) {
    if (-not $req.RemoteEndPoint) { return $false }
    return [System.Net.IPAddress]::IsLoopback($req.RemoteEndPoint.Address)
}

function Test-RegexPattern([string]$pattern, [ref]$errorMsg) {
    $errorMsg.Value = $null
    if ([string]::IsNullOrWhiteSpace($pattern)) { return $true }
    try {
        [void][System.Text.RegularExpressions.Regex]::new($pattern)
        return $true
    } catch {
        $errorMsg.Value = $_.Exception.Message
        return $false
    }
}

function Test-UploadFileName([string]$fileName) {
    $pattern = $script:ServerSettings.UploadFileRegex
    if ([string]::IsNullOrWhiteSpace($pattern)) { return @{ Ok = $true } }
    $regexErr = $null
    if (-not (Test-RegexPattern $pattern ([ref]$regexErr))) {
        return @{ Ok = $false; Message = "Server upload regex is invalid: $regexErr" }
    }
    $baseName = [System.IO.Path]::GetFileName($fileName)
    if ($baseName -match $pattern) { return @{ Ok = $true } }
    return @{
        Ok      = $false
        Message = "File name does not match the required pattern. Rejected: $baseName"
    }
}

function Format-ByteSize([long]$bytes) {
    if ($bytes -lt 1024) { return "$bytes B" }
    if ($bytes -lt 1048576) { return "{0:N1} KB" -f ($bytes / 1024) }
    if ($bytes -lt 1073741824) { return "{0:N1} MB" -f ($bytes / 1048576) }
    return "{0:N1} GB" -f ($bytes / 1073741824)
}

function Get-SenderIpFromFileName([string]$filename) {
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($filename)
    if ($stem -match '-(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?:_\d+)?$') { return $Matches[1] }
    if ($stem -match '-([0-9a-fA-F\-]{7,})(?:_\d+)?$') { return $Matches[1] }
    return "Unknown"
}

function Get-UploadableFiles {
    Get-ChildItem -Path $script:ServerSettings.UploadFolder -File |
        Where-Object { $_.Name -notlike '.upload-parse-*' }
}

function New-UploadFolderTempPath([string]$prefix) {
    $name = ".$prefix-$([Guid]::NewGuid().ToString('N')).tmp"
    return Join-Path $script:ServerSettings.UploadFolder $name
}

function Find-IndexOfBytes([byte[]]$buffer, [int]$length, [byte[]]$needle, [int]$startIndex = 0) {
    if ($null -eq $needle -or $needle.Length -eq 0 -or $length -lt $needle.Length) { return -1 }
    $last = $length - $needle.Length
    for ($i = $startIndex; $i -le $last; $i++) {
        if ($buffer[$i] -ne $needle[0]) { continue }
        $matched = $true
        for ($j = 1; $j -lt $needle.Length; $j++) {
            if ($buffer[$i + $j] -ne $needle[$j]) { $matched = $false; break }
        }
        if ($matched) { return $i }
    }
    return -1
}

function Find-BytePatternInFileStream([System.IO.FileStream]$stream, [byte[]]$needle, [long]$from) {
    if ($needle.Length -eq 0) { return [long]-1 }
    $overlap = $needle.Length - 1
    $bufSize = 1048576
    [byte[]]$buf = New-Object byte[] ($bufSize + $overlap)
    $stream.Position = $from
    $absBase = $from
    $carry = 0
    while ($absBase -lt $stream.Length) {
        $read = $stream.Read($buf, $carry, $bufSize)
        if ($read -le 0) { break }
        $winLen = $carry + $read
        $idx = Find-IndexOfBytes -buffer $buf -length $winLen -needle $needle -startIndex 0
        if ($idx -ge 0) { return $absBase - $carry + $idx }
        $carry = [Math]::Min($overlap, $winLen)
        if ($carry -gt 0) {
            [Array]::Copy($buf, $winLen - $carry, $buf, 0, $carry)
        }
        $absBase += $read
    }
    return [long]-1
}

function Get-ZipCacheDir {
    $dir = Join-Path $script:ServerSettings.UploadFolder '_zips'
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Get-ZipCachePaths([string]$senderIp) {
    $safeIp = $senderIp -replace '[^a-zA-Z0-9\.\-]', '_'
    $cacheDir = Get-ZipCacheDir
    @{
        ZipPath      = Join-Path $cacheDir "files-$safeIp.zip"
        ManifestPath = Join-Path $cacheDir "files-$safeIp.manifest.json"
        DisplayName  = "files-$safeIp.zip"
    }
}

function Get-ZipSourceFingerprint($zipFiles) {
    $zipFiles | Sort-Object Name | ForEach-Object {
        [ordered]@{
            name  = $_.Name
            len   = $_.Length
            mtime = $_.LastWriteTimeUtc.ToString('o')
        }
    }
}

function Get-ZipFingerprintHash($fingerprint) {
    $json = $fingerprint | ConvertTo-Json -Compress -Depth 6
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return [BitConverter]::ToString($hash).Replace('-', '').ToLower()
}

function Test-ZipCacheValid([string]$manifestPath, [string]$zipPath, $fingerprint) {
    if (-not ((Test-Path -LiteralPath $zipPath) -and (Test-Path -LiteralPath $manifestPath))) { return $false }
    try {
        $saved = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        return [string]$saved.hash -eq (Get-ZipFingerprintHash $fingerprint)
    } catch {
        return $false
    }
}

function Build-ZipCache([string]$destZip, $zipFiles) {
    Write-ServerLog "Build-ZipCache: building $($zipFiles.Count) file(s) -> $destZip" -Level Info
    Add-Type -AssemblyName System.IO.Compression
    $partPath = "$destZip.part"
    if (Test-Path -LiteralPath $partPath) { Remove-Item -LiteralPath $partPath -Force }
    $fs = [System.IO.File]::Open($partPath, [System.IO.FileMode]::CreateNew)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        foreach ($f in $zipFiles) {
            $entry = $zip.CreateEntry($f.Name, [System.IO.Compression.CompressionLevel]::Optimal)
            $es = $entry.Open()
            try {
                $src = [System.IO.File]::OpenRead($f.FullName)
                try { $src.CopyTo($es) } finally { $src.Dispose() }
            } finally { $es.Dispose() }
        }
        $zip.Dispose()
    } finally { $fs.Dispose() }
    if (Test-Path -LiteralPath $destZip) { Remove-Item -LiteralPath $destZip -Force }
    Move-Item -LiteralPath $partPath -Destination $destZip -Force
    $zipSize = (Get-Item -LiteralPath $destZip).Length
    Write-ServerLog "Build-ZipCache: complete ($zipSize bytes)" -Level Ok
}

function Save-ZipCacheManifest([string]$manifestPath, $fingerprint) {
    @{ hash = (Get-ZipFingerprintHash $fingerprint) } | ConvertTo-Json -Compress |
        Set-Content -LiteralPath $manifestPath -Encoding UTF8 -NoNewline
}

function Send-FileStreamResponse(
    [System.Net.HttpListenerContext]$ctx,
    [string]$filePath,
    [string]$contentType,
    [string]$downloadFileName
) {
    $info = Get-Item -LiteralPath $filePath
    Write-ServerLog "Send-FileStreamResponse: '$downloadFileName' ($($info.Length) bytes, $contentType)" -Level Info
    $encName = [Uri]::EscapeDataString($downloadFileName)
    $ctx.Response.ContentType = $contentType
    $ctx.Response.AddHeader("Content-Disposition", "attachment; filename*=UTF-8''$encName")
    $ctx.Response.ContentLength64 = $info.Length
    $inStream = [System.IO.File]::OpenRead($filePath)
    try {
        $inStream.CopyTo($ctx.Response.OutputStream)
    } finally {
        $inStream.Dispose()
        try { $ctx.Response.OutputStream.Close() } catch {}
    }
}

function Get-ServerSettingsObject {
    return @{
        uploadFileRegex = $script:ServerSettings.UploadFileRegex
        password        = $script:ServerSettings.Password
        uploadFolder    = $script:ServerSettings.UploadFolder
        maxUploadSize   = $script:ServerSettings.MaxUploadSize
    }
}

function Get-ServerSettingsJson {
    return (Get-ServerSettingsObject | ConvertTo-Json -Compress)
}

if (-not [string]::IsNullOrWhiteSpace($UploadFileRegex)) {
    $regexStartupErr = $null
    if (-not (Test-RegexPattern $UploadFileRegex ([ref]$regexStartupErr))) {
        Write-ServerLog "Invalid -UploadFileRegex: $regexStartupErr" -Level Error
        exit 1
    }
}

function Set-ServerSettingsFromJson([string]$json, [ref]$errorMsg) {
    $errorMsg.Value = $null
    Write-ServerLog "Applying settings from admin JSON ($($json.Length) chars)" -Level Info
    try {
        $data = $json | ConvertFrom-Json
    } catch {
        $errorMsg.Value = "Invalid JSON payload."
        Write-ServerLog "Settings update failed: invalid JSON — $($_.Exception.Message)" -Level Error
        return $false
    }
    if ($null -ne $data.PSObject.Properties['uploadFileRegex']) {
        $pattern = [string]$data.uploadFileRegex
        $regexErr = $null
        if (-not (Test-RegexPattern $pattern ([ref]$regexErr))) {
            $errorMsg.Value = "Invalid upload file regex: $regexErr"
            return $false
        }
        $script:ServerSettings.UploadFileRegex = $pattern
    }
    if ($null -ne $data.PSObject.Properties['password']) {
        $newPw = [string]$data.password
        if ($newPw -ne $script:ServerSettings.Password) {
            $script:ServerSettings.Password = $newPw
            $Sessions.Clear()
            Write-ServerLog "Download password changed — all sessions cleared" -Level Info
        }
    }
    if ($null -ne $data.PSObject.Properties['uploadFolder']) {
        $folder = [string]$data.uploadFolder
        if ([string]::IsNullOrWhiteSpace($folder)) {
            $errorMsg.Value = "Upload folder cannot be empty."
            return $false
        }
        try {
            $script:ServerSettings.UploadFolder = (New-Item -ItemType Directory -Force -Path $folder).FullName
            Write-ServerLog "Upload folder changed to $($script:ServerSettings.UploadFolder)" -Level Info
        } catch {
            $errorMsg.Value = "Invalid upload folder: $($_.Exception.Message)"
            Write-ServerLog "Invalid upload folder '$folder': $($_.Exception.Message)" -Level Error
            return $false
        }
    }
    if ($null -ne $data.PSObject.Properties['maxUploadSize']) {
        $size = 0L
        try { $size = [long]$data.maxUploadSize } catch {
            $errorMsg.Value = "Invalid max upload size."
            return $false
        }
        if ($size -lt 0) {
            $errorMsg.Value = "Max upload size cannot be negative (use 0 for unlimited)."
            return $false
        }
        $script:ServerSettings.MaxUploadSize = $size
        Write-ServerLog "Max upload size set to $(if ($size -gt 0) { Format-ByteSize $size } else { 'unlimited' })" -Level Info
    }
    Write-ServerLog "Settings applied — folder: $($script:ServerSettings.UploadFolder)" -Level Ok
    return $true
}

# ── HTML Templates ───────────────────────────────────────────────────────────

$CSS_SHARED = @'
  @import url('https://fonts.googleapis.com/css2?family=Syne:wght@400;700;800&family=DM+Mono:wght@400;500&display=swap');
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  :root {
    --bg: #0d0d0f;
    --surface: #16161a;
    --surface2: #1c1c22;
    --border: #2a2a32;
    --accent: #166eac;
    --accent2: #00ddff;
    --text: #e8e8f0;
    --muted: #a0a0b8;
    --danger: #ff5f5f;
    --radius: 10px;
    --font: 'Syne', sans-serif;
    --mono: 'DM Mono', monospace;
    --topbar: 90px;
  }
  html, body { height: 100%; overflow: hidden; }
  body {
    background: var(--bg);
    color: var(--text);
    font-family: var(--font);
    background-image:
      radial-gradient(ellipse 80% 50% at 20% 10%, rgba(200,241,53,.05) 0%, transparent 60%),
      radial-gradient(ellipse 60% 40% at 80% 90%, rgba(106,240,200,.05) 0%, transparent 60%);
  }
  /* ── Top bar ── */
  .topbar {
    position: fixed; top: 0; left: 0; right: 0; height: var(--topbar);
    background: rgba(22,22,26,.92); backdrop-filter: blur(12px);
    border-bottom: 1px solid var(--border);
    display: flex; align-items: center; padding: 0 2rem; gap: 1rem;
    z-index: 100;
  }
  .topbar::after {
    content: '';
    position: absolute; bottom: 0; left: 0; right: 0; height: 2px;
    background: linear-gradient(90deg, var(--accent), var(--accent2));
  }
  .topbar-title { font-size: 1.25rem; font-weight: 700; letter-spacing: -.01em; }
  .topbar-title .badge { margin-left: .6rem; }
  .topbar-meta { flex: 1; display: flex; align-items: center; gap: .5rem; font-family: var(--mono); font-size: .8rem; flex-wrap: wrap; }
  @media (max-width: 600px) { .topbar-meta { flex-direction: column; align-items: flex-start; gap: .3rem; } }
  .topbar-nav { display: flex; gap: .75rem; align-items: center; }
  .topbar-nav a {
    color: var(--accent2); font-size: .82rem; text-decoration: none;
    font-family: var(--mono); font-weight: 500;
    padding: .35rem .9rem; border-radius: 999px;
    border: 1.5px solid var(--accent2);
    background: rgba(0,221,255,.07);
    transition: background .15s, color .15s, border-color .15s;
    white-space: nowrap;
  }
  .topbar-nav a:hover { background: rgba(0,221,255,.18); color: #fff; border-color: #fff; }
  .topbar-nav a.danger {
    color: var(--danger); border-color: var(--danger);
    background: rgba(255,95,95,.07);
  }
  .topbar-nav a.danger:hover { background: rgba(255,95,95,.2); color: #fff; border-color: #fff; }
  /* ── Page content ── */
  .page {
    position: fixed; top: var(--topbar); left: 0; right: 0; bottom: 0;
    overflow-y: auto; padding: 2rem;
  }
  /* ── Shared form bits ── */
  h1 { font-size: 2rem; font-weight: 700; letter-spacing: -.02em; }
  .sub { color: var(--muted); font-size: .85rem; font-family: var(--mono); margin-top: .25rem; }
  label { display: block; font-size: .78rem; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; color: var(--muted); margin-bottom: .5rem; margin-top: 1.2rem; }
  input[type=password], input[type=text] {
    width: 100%; padding: .75rem 1rem;
    background: var(--bg); border: 1px solid var(--border);
    border-radius: var(--radius); color: var(--text);
    font-family: var(--mono); font-size: .95rem;
    outline: none; transition: border-color .2s;
  }
  input:focus { border-color: var(--accent); }
  .btn {
    display: inline-flex; align-items: center; justify-content: center; gap: .5rem;
    margin-top: 1.4rem; width: 100%; padding: .85rem 1.5rem;
    background: var(--accent); color: #0d0d0f;
    font-family: var(--font); font-weight: 700; font-size: 1rem;
    border: none; border-radius: var(--radius); cursor: pointer;
    transition: opacity .15s, transform .1s;
  }
  .btn:hover { opacity: .88; transform: translateY(-1px); }
  .btn:active { transform: translateY(0); }
  .btn.secondary {
    background: transparent; color: var(--accent);
    border: 1.5px solid var(--accent); margin-top: .8rem;
  }
  .msg {
    margin-top: 1.2rem; padding: .75rem 1rem;
    border-radius: var(--radius); font-size: .88rem; font-family: var(--mono);
  }
  .msg.ok  { background: rgba(21, 255, 33, 0.1);  color: var(--accent);  border: 1px solid rgba(21, 255, 33, 0.7); }
  .msg.err { background: rgba(255, 35, 35, 0.1);   color: var(--danger);  border: 1px solid rgba(255, 35, 35, 0.7); }
  .badge {
    display: inline-block; padding: .2rem .6rem; border-radius: 999px;
    font-size: .7rem; font-family: var(--mono); font-weight: 500;
    background: rgba(106,240,200,.12); color: var(--accent2);
    border: 1px solid rgba(106,240,200,.25); vertical-align: middle;
  }
  /* ── Centered card (login only) ── */
  .centered-wrap {
    min-height: 100%; display: flex; align-items: center; justify-content: center;
  }
  .card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 16px;
    padding: 2.4rem 2.6rem;
    width: 100%; max-width: 460px;
    box-shadow: 0 24px 80px rgba(0,0,0,.5);
    position: relative; overflow: hidden;
  }
  .card::before {
    content: '';
    position: absolute; top: 0; left: 0; right: 0; height: 3px;
    background: linear-gradient(90deg, var(--accent), var(--accent2));
  }
'@

# ── Upload Page ──────────────────────────────────────────────────────────────
function Get-UploadPage([string]$msg = "", [bool]$isError = $false) {
    $msgHtml = ""
    if ($msg) {
        $cls = if ($isError) { "err" } else { "ok" }
        $msgHtml = "<div class='msg $cls'>$([System.Net.WebUtility]::HtmlEncode($msg))</div>"
    }
    $regexHintHtml = ""
    if (-not [string]::IsNullOrWhiteSpace($script:ServerSettings.UploadFileRegex)) {
        $pat = [System.Net.WebUtility]::HtmlEncode($script:ServerSettings.UploadFileRegex)
        $regexHintHtml = @"
        <div class="regex-requirement">
          <span class="regex-requirement-label">Filenames must match</span>
          <code class="regex-requirement-pattern">$pat</code>
        </div>
"@
    }
    $maxSizeHintHtml = ""
    $maxUploadJs = '0'
    if ($script:ServerSettings.MaxUploadSize -gt 0) {
        $maxUploadJs = $script:ServerSettings.MaxUploadSize.ToString()
        $maxLabel = [System.Net.WebUtility]::HtmlEncode((Format-ByteSize $script:ServerSettings.MaxUploadSize))
        $maxSizeHintHtml = @"
        <div class="regex-requirement">
          <span class="regex-requirement-label">Maximum file size</span>
          <code class="regex-requirement-pattern">$maxLabel</code>
        </div>
"@
    }
    return @"
<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Upload Files</title>
<style>$CSS_SHARED
  /* ── Upload-specific ── */
  .upload-layout {
    display: grid;
    grid-template-columns: 380px 1fr;
    gap: 1.5rem;
    width: 100%;
    max-width: 1400px;
    margin: 0 auto;
    height: 100%;
    align-items: start;
    min-width: 0;
  }
  @media (max-width: 860px) {
    .upload-layout { grid-template-columns: 1fr; height: auto; }
  }
  .upload-panel {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 16px; padding: 2rem;
    position: sticky; top: 0;
    min-width: 0; width: 100%;
  }
  .upload-panel::before {
    content: ''; position: absolute; top: 0; left: 0; right: 0; height: 3px;
    background: linear-gradient(90deg, var(--accent), var(--accent2));
    border-radius: 16px 16px 0 0;
  }
  .upload-panel { position: relative; overflow: hidden; }
  .drop-zone {
    border: 2px dashed var(--border); border-radius: var(--radius);
    padding: 2.5rem 1rem; text-align: center; cursor: pointer;
    transition: border-color .2s, background .2s; margin-top: 1.2rem;
    background: transparent;
  }
  .drop-zone:hover, .drop-zone.dragover {
    border-color: var(--accent2); background: rgba(0,221,255,.04);
  }
  .drop-zone-icon { font-size: 2.2rem; margin-bottom: .6rem; }
  .drop-zone-text { font-family: var(--mono); font-size: .85rem; color: var(--muted); line-height: 1.6; }
  .drop-zone-text strong { color: var(--accent2); }
  .file-picker-btn {
    display: inline-flex; align-items: center; gap: .6rem;
    padding: .6rem 1.2rem; background: #0066ff;
    border: 1.5px solid var(--border); border-radius: var(--radius);
    color: var(--text); font-family: var(--mono); font-size: .85rem;
    cursor: pointer; transition: border-color .2s, color .2s; margin-top: .9rem;
  }
  .file-picker-btn:hover { border-color: var(--accent2); color: var(--accent2); }
  #prog-wrap {
    display: none; margin-top: 1rem;
    background: var(--bg); border: 1px solid var(--border);
    border-radius: var(--radius); padding: .9rem 1rem; gap: .85rem;
    flex-direction: column;
  }
  #prog-wrap.active { display: flex; }
  .prog-stage { display: flex; flex-direction: column; gap: .35rem; }
  .prog-stage-head {
    display: flex; justify-content: space-between; align-items: center; gap: .5rem;
  }
  .prog-stage-label {
    font-family: var(--mono); font-size: .72rem; font-weight: 700;
    letter-spacing: .06em; text-transform: uppercase; color: var(--muted);
  }
  .prog-stage-pct {
    font-family: var(--mono); font-size: .82rem; font-weight: 700; flex-shrink: 0;
  }
  #prog-upload-stage .prog-stage-pct { color: var(--accent2); }
  #prog-save-stage .prog-stage-pct { color: #6af0c8; }
  .prog-stage-track {
    height: 7px; background: var(--border); border-radius: 999px; overflow: hidden;
  }
  .prog-stage-bar {
    height: 100%; width: 0%; border-radius: 999px;
    transition: width .15s ease-out;
  }
  #upload-bar {
    background: linear-gradient(90deg, var(--accent), var(--accent2));
  }
  #save-bar {
    background: linear-gradient(90deg, #16a34a, #6af0c8);
    transition: width .35s linear;
  }
  #prog-save-stage.active #save-bar {
    background: linear-gradient(90deg, #16a34a, #6af0c8, #4ade80, #6af0c8);
    background-size: 220% 100%;
    animation: prog-save-pulse 1.4s ease-in-out infinite;
  }
  #prog-save-stage.indeterminate #save-bar {
    width: 38% !important;
    animation: prog-save-slide 1.35s ease-in-out infinite alternate,
               prog-save-pulse 1.4s ease-in-out infinite;
  }
  @keyframes prog-save-pulse {
    0% { background-position: 0% 50%; }
    100% { background-position: 100% 50%; }
  }
  @keyframes prog-save-slide {
    from { transform: translateX(0); }
    to   { transform: translateX(162%); }
  }
  .prog-stage-sub {
    font-family: var(--mono); font-size: .72rem; color: var(--muted);
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  }
  .prog-stage.idle .prog-stage-bar { opacity: .35; }
  .prog-overall-sub {
    font-family: var(--mono); font-size: .75rem; color: var(--text);
    padding-top: .15rem; border-top: 1px solid var(--border);
    margin-top: .1rem;
  }
  /* ── File list panel ── */
  .filelist-panel {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 16px; padding: 1.5rem 2rem;
    min-height: 300px; min-width: 0; width: 100%; overflow: hidden;
  }
  .filelist-header {
    display: flex; align-items: center; justify-content: space-between;
    margin-bottom: 1rem; padding-bottom: .75rem;
    border-bottom: 1px solid var(--border);
  }
  .filelist-title { font-size: 1rem; font-weight: 700; color: var(--muted); font-family: var(--mono); text-transform: uppercase; letter-spacing: .07em; }
  #file-preview { display: flex; flex-direction: column; gap: .4rem; width: 100%; }
  #file-preview:empty::after {
    content: 'No files selected yet — drag and drop or use the browse button';
    display: block; text-align: center;
    color: var(--muted); font-family: var(--mono); font-size: .82rem;
    padding: 3rem 0;
  }
  .fi {
    display: flex; align-items: center; gap: .7rem;
    background: var(--bg); border: 1px solid var(--border);
    border-radius: 8px; padding: .55rem .9rem;
    transition: border-color .3s; min-width: 0; overflow: hidden;
  }
  .fi.uploading { border-color: var(--accent2); }
  .fi.done      { border-color: var(--accent); }
  .fi-icon { font-size: 1rem; flex-shrink: 0; }
  .fi-name { flex: 1; font-family: var(--mono); font-size: .82rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
  .fi-size { color: var(--muted); font-family: var(--mono); font-size: .75rem; flex-shrink: 0; }
  .fi-status { font-family: var(--mono); font-size: .75rem; flex-shrink: 0; color: var(--muted); min-width: 3.5rem; text-align: right; }
  .regex-requirement {
    margin-top: 1rem; padding: .75rem .9rem;
    background: rgba(0,221,255,.06); border: 1px solid rgba(0,221,255,.25);
    border-radius: var(--radius);
  }
  .regex-requirement-label {
    display: block; font-size: .72rem; font-weight: 700; letter-spacing: .08em;
    text-transform: uppercase; color: var(--muted); margin-bottom: .45rem;
  }
  .regex-requirement-pattern {
    display: block; font-family: var(--mono); font-size: .82rem;
    color: var(--accent2); word-break: break-all; white-space: pre-wrap;
  }
  @media (max-width: 500px) {
    .page { padding: 1rem; }
    .upload-panel { padding: 1.25rem; }
    .filelist-panel { padding: 1.25rem; }
    .fi-size { display: none; }
  }
</style></head>
<body>
<div class="topbar">
  <span class="topbar-title">&#128193; File Upload <span class="badge">Public</span></span>
  <span class="topbar-meta"></span>
  <nav class="topbar-nav"><a href="/download">Download Page &rarr;</a></nav>
</div>

<div class="page">
  <div class="upload-layout">

    <div class="upload-panel">
      <h1>Upload</h1>
      <p class="sub">Drag &amp; drop or browse to select files</p>

      <form id="uploadForm" enctype="multipart/form-data">
        <div class="drop-zone" id="dropZone">
          <div class="drop-zone-icon">&#128228;</div>
          <div class="drop-zone-text">
            Drop files here<br>
            <strong>or</strong>
          </div>
          <div class="file-picker-btn" id="browseBtn">
            &#128193;&nbsp; Browse files&hellip;
          </div>
          <input type="file" id="fileInput" name="files" multiple
                 style="position:absolute;width:1px;height:1px;opacity:0;pointer-events:none"
                 onchange="updatePreview(this.files)">
        </div>

        <div id="prog-wrap">
          <div class="prog-stage" id="prog-upload-stage">
            <div class="prog-stage-head">
              <span class="prog-stage-label">&#128228; Uploading</span>
              <span class="prog-stage-pct" id="upload-pct">0%</span>
            </div>
            <div class="prog-stage-track"><div class="prog-stage-bar" id="upload-bar"></div></div>
            <div class="prog-stage-sub" id="upload-sub">&nbsp;</div>
          </div>
          <div class="prog-stage idle" id="prog-save-stage">
            <div class="prog-stage-head">
              <span class="prog-stage-label">&#128190; Saving on server</span>
              <span class="prog-stage-pct" id="save-pct">0%</span>
            </div>
            <div class="prog-stage-track"><div class="prog-stage-bar" id="save-bar"></div></div>
            <div class="prog-stage-sub" id="save-sub">Waiting&hellip;</div>
          </div>
          <div class="prog-overall-sub" id="prog-overall-sub">Preparing&hellip;</div>
        </div>

        $regexHintHtml
        $maxSizeHintHtml
        <button type="submit" class="btn" id="submitBtn" disabled
                style="opacity:.4;cursor:not-allowed">&#8593;&nbsp; Upload Files</button>
      </form>
      $msgHtml
    </div>

    <div class="filelist-panel">
      <div class="filelist-header">
        <span class="filelist-title">Selected Files</span>
        <span id="file-count" style="font-family:var(--mono);font-size:.8rem;color:var(--muted)"></span>
      </div>
      <div id="file-preview"></div>
    </div>

  </div>
</div>

<script>
let allFiles = [];
const MAX_UPLOAD_BYTES = $maxUploadJs;

function escHtml(s){return s.replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));}
function fmtSize(b){if(b<1024)return b+' B';if(b<1048576)return (b/1024).toFixed(1)+' KB';return (b/1048576).toFixed(1)+' MB';}

// Drag & drop
var dz = document.getElementById('dropZone');
dz.addEventListener('dragover', function(e){ e.preventDefault(); dz.classList.add('dragover'); });
dz.addEventListener('dragleave', function(){ dz.classList.remove('dragover'); });
dz.addEventListener('drop', function(e){
  e.preventDefault(); dz.classList.remove('dragover');
  if (e.dataTransfer.files.length) { updatePreview(e.dataTransfer.files); }
});
document.getElementById('browseBtn').addEventListener('click', function(e){
  e.stopPropagation();
  document.getElementById('fileInput').click();
});

function updatePreview(files) {
  allFiles = Array.from(files);
  const preview = document.getElementById('file-preview');
  const btn     = document.getElementById('submitBtn');
  const counter = document.getElementById('file-count');
  if (!allFiles.length) {
    preview.innerHTML = '';
    counter.textContent = '';
    btn.disabled = true; btn.style.opacity = '.4'; btn.style.cursor = 'not-allowed';
    return;
  }
  counter.textContent = allFiles.length + ' file' + (allFiles.length !== 1 ? 's' : '') + ' selected';
  preview.innerHTML = allFiles.map((f, i) =>
    '<div class="fi" id="fi-' + i + '">' +
      '<span class="fi-icon">&#128196;</span>' +
      '<span class="fi-name">' + escHtml(f.name) + '</span>' +
      '<span class="fi-size">' + fmtSize(f.size) + '</span>' +
      '<span class="fi-status" id="fi-st-' + i + '">queued</span>' +
    '</div>'
  ).join('');
  btn.disabled = false; btn.style.opacity = '1'; btn.style.cursor = 'pointer';
}

var saveProgressTimer = null;

function setOverallStatus(text) {
  document.getElementById('prog-overall-sub').textContent = text;
}

function setUploadBar(pct, sub, idle) {
  var stage = document.getElementById('prog-upload-stage');
  var bar = document.getElementById('upload-bar');
  var pctEl = document.getElementById('upload-pct');
  stage.classList.toggle('idle', !!idle);
  var display = idle ? 0 : Math.min(100, Math.round(pct));
  bar.style.width = display + '%';
  pctEl.textContent = idle ? '\u2014' : (display + '%');
  if (sub !== undefined) document.getElementById('upload-sub').textContent = sub;
}

function setSaveBar(pct, sub, active, opts) {
  opts = opts || {};
  var stage = document.getElementById('prog-save-stage');
  var bar = document.getElementById('save-bar');
  var pctEl = document.getElementById('save-pct');
  stage.classList.toggle('idle', !active);
  stage.classList.toggle('active', !!active);
  stage.classList.toggle('indeterminate', !!(active && opts.indeterminate));
  if (!opts.indeterminate) {
    bar.style.transform = '';
    var display = active ? Math.min(100, Math.round(pct)) : 0;
    bar.style.width = (active ? display : 0) + '%';
    pctEl.textContent = active ? (opts.pctText || (display + '%')) : '\u2014';
  }
  if (sub !== undefined) document.getElementById('save-sub').textContent = sub;
}

function stopSaveProgress() {
  if (saveProgressTimer) {
    clearInterval(saveProgressTimer);
    saveProgressTimer = null;
  }
}

function startSaveProgress(fileIndex, file, fileTotal) {
  stopSaveProgress();
  var sub = escHtml(file.name) + ' (' + (fileIndex + 1) + ' / ' + fileTotal + ')';
  setSaveBar(0, sub, true, { indeterminate: true, pctText: 'Saving\u2026' });
  document.getElementById('save-pct').textContent = 'Saving\u2026';
}

function resetSaveBarWaiting(hint) {
  stopSaveProgress();
  var stage = document.getElementById('prog-save-stage');
  stage.classList.remove('indeterminate', 'active');
  stage.classList.add('idle');
  document.getElementById('save-bar').style.width = '0%';
  document.getElementById('save-bar').style.transform = '';
  document.getElementById('save-pct').textContent = 'Waiting';
  document.getElementById('save-sub').textContent = hint || 'Waiting for file data\u2026';
}

function finishSaveProgress() {
  stopSaveProgress();
  var stage = document.getElementById('prog-save-stage');
  stage.classList.remove('indeterminate', 'idle');
  stage.classList.add('active');
  setSaveBar(100, 'All files saved', false, { pctText: '100%' });
  document.getElementById('save-bar').style.width = '100%';
  document.getElementById('save-bar').style.transform = '';
}

function uploadOneFile(fileIndex, fileTotal, onUploadBytesSent) {
  const i = fileIndex;
  const f = allFiles[i];
  const fiEl = document.getElementById('fi-' + i);
  const fiSt = document.getElementById('fi-st-' + i);

  return new Promise(function(resolve, reject) {
    if (MAX_UPLOAD_BYTES > 0 && f.size > MAX_UPLOAD_BYTES) {
      if (fiSt) fiSt.textContent = 'rejected';
      setUploadBar(0, 'Rejected: ' + escHtml(f.name), true);
      if (onUploadBytesSent) onUploadBytesSent();
      reject(new Error('File exceeds maximum upload size (' + fmtSize(MAX_UPLOAD_BYTES) + ').'));
      return;
    }
    if (fiEl) fiEl.classList.add('uploading');
    if (fiSt) fiSt.textContent = 'uploading';
    resetSaveBarWaiting('Waiting while file ' + (i+1) + ' uploads\u2026');
    setUploadBar(0, escHtml(f.name) + ' (' + (i+1) + ' / ' + fileTotal + ')', false);
    setOverallStatus('Uploading file ' + (i+1) + ' of ' + fileTotal + '\u2026');

    const fd = new FormData();
    fd.append('files', f);
    const xhr = new XMLHttpRequest();
    var bytesSent = false;

    function onBytesFullySent() {
      if (bytesSent) return;
      bytesSent = true;
      if (fiSt) fiSt.textContent = 'processing';
      setUploadBar(100, 'Sent \u2014 ' + escHtml(f.name), false);
      startSaveProgress(i, f, fileTotal);
      setOverallStatus('Saving file ' + (i+1) + ' on server' +
        (i + 1 < fileTotal ? ' \u00b7 next upload starting\u2026' : '\u2026'));
      if (onUploadBytesSent) onUploadBytesSent();
    }

    xhr.open('POST', '/upload-chunk');
    xhr.timeout = Math.min(600000, Math.max(120000, Math.ceil(f.size / 1048576) * 45000));
    xhr.ontimeout = function() {
      stopSaveProgress();
      setSaveBar(0, 'Timed out waiting for server', false);
      if (fiSt) fiSt.textContent = 'error';
      reject(new Error('Server took too long to save the file. Try a smaller file or check the server console.'));
    };
    xhr.upload.onprogress = function(ev) {
      if (!ev.lengthComputable) return;
      var pct = (ev.loaded / ev.total) * 100;
      setUploadBar(pct, fmtSize(ev.loaded) + ' / ' + fmtSize(ev.total), false);
      if (ev.loaded >= ev.total) onBytesFullySent();
    };
    xhr.upload.onloadend = onBytesFullySent;
    xhr.onload = function() {
      if (xhr.status >= 200 && xhr.status < 300) {
        if (fiEl) { fiEl.classList.remove('uploading'); fiEl.classList.add('done'); }
        if (fiSt) fiSt.textContent = 'done';
        resetSaveBarWaiting('Waiting for next file\u2026');
        setUploadBar(0, 'Waiting for next file\u2026', true);
        resolve();
      } else {
        stopSaveProgress();
        setSaveBar(0, 'Failed', false);
        if (fiSt) fiSt.textContent = 'rejected';
        var errMsg = (xhr.responseText || 'Upload rejected').trim();
        setUploadBar(0, errMsg, true);
        reject(new Error(errMsg));
      }
    };
    xhr.onerror = function() {
      stopSaveProgress();
      setSaveBar(0, 'Network error', false);
      if (fiSt) fiSt.textContent = 'error';
      reject(new Error('Network error'));
    };
    xhr.send(fd);
  });
}

document.getElementById('uploadForm').addEventListener('submit', async function(e) {
  e.preventDefault();
  if (!allFiles.length) return;

  const submitBtn  = document.getElementById('submitBtn');
  const browseBtn  = document.getElementById('browseBtn');
  const progWrap   = document.getElementById('prog-wrap');
  submitBtn.disabled = true; submitBtn.style.opacity = '.4'; submitBtn.style.cursor = 'not-allowed';
  browseBtn.style.pointerEvents = 'none'; browseBtn.style.opacity = '.5';
  document.getElementById('fileInput').disabled = true;
  progWrap.classList.add('active');
  stopSaveProgress();
  setUploadBar(0, 'Starting\u2026', true);
  resetSaveBarWaiting('Waiting\u2026');
  setOverallStatus('Starting\u2026');

  const total = allFiles.length;
  let allOk = true;
  let lastErr = '';
  let nextIndex = 0;
  const inflight = [];

  function kickNextUpload() {
    if (nextIndex >= total) return;
    const idx = nextIndex++;
    inflight.push(
      uploadOneFile(idx, total, kickNextUpload).catch(function(err) {
        allOk = false;
        if (err && err.message) lastErr = err.message;
      })
    );
  }

  kickNextUpload();
  await Promise.all(inflight);

  stopSaveProgress();
  if (allOk) {
    setUploadBar(100, 'All files sent', false);
    finishSaveProgress();
    setOverallStatus('All files uploaded!');
  } else {
    setUploadBar(0, lastErr || 'Some uploads failed', true);
    resetSaveBarWaiting('Stopped');
    setOverallStatus(lastErr || 'Done with errors');
  }
  setTimeout(function() {
    if (allOk) { window.location.href = '/?ok=1'; return; }
    var q = 'err=1';
    if (lastErr) q += '&msg=' + encodeURIComponent(lastErr);
    window.location.href = '/?' + q;
  }, 1200);
});
</script>
</body></html>
"@
}

# ── Login Page ───────────────────────────────────────────────────────────────
function Get-LoginPage([bool]$failed = $false) {
    $errHtml = if ($failed) { "<div class='msg err'>&#10007;&nbsp; Incorrect password. Try again.</div>" } else { "" }
    return @"
<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Download — Sign In</title>
<style>$CSS_SHARED
  html, body { overflow: auto; }
</style></head>
<body style="display:flex;align-items:center;justify-content:center;min-height:100vh;padding:2rem;">
<div class="card">
  <h1>Download <span class="badge">Protected</span></h1>
  <p class="sub" style="margin-top:.3rem;margin-bottom:1.8rem;">Enter the password to access files</p>
  <nav style="margin-bottom:1.5rem;"><a href="/" style="color:var(--muted);font-size:.85rem;text-decoration:none;font-family:var(--mono);border-bottom:1px dashed var(--border);padding-bottom:1px;">&larr; Back to Upload</a></nav>
  <form method="POST" action="/download/login">
    <label for="pw">Password</label>
    <input type="password" id="pw" name="password" placeholder="••••••••" autofocus>
    <button type="submit" class="btn">&#128274;&nbsp; Unlock</button>
  </form>
  $errHtml
</div>
</body></html>
"@
}

# ── Download Page ────────────────────────────────────────────────────────────
function Get-DownloadPage {
    $files = @(Get-UploadableFiles | Sort-Object LastWriteTime -Descending)

    # Helper: strip the IP suffix to get the display name
    function Get-DisplayName([string]$filename) {
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($filename)
        $ext  = [System.IO.Path]::GetExtension($filename)
        # Remove the trailing "-IP" or "-IP_N" suffix
        $clean = $stem -replace '-\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(?:_\d+)?$', ''
        $clean = $clean -replace '-[0-9a-fA-F\-]{7,}(?:_\d+)?$', ''
        if (-not $clean) { $clean = $stem }
        return "$clean$ext"
    }

    # Group files by sender IP
    $grouped = $files | Group-Object { Get-SenderIpFromFileName $_.Name } | Sort-Object Name

    $groupHtml = if ($files.Count -eq 0) {
        "<div class='empty-state'><div class='empty-state-icon'>&#128228;</div>No files uploaded yet.<br>Head to the upload page to send some files.</div>"
    } else {
        ($grouped | ForEach-Object {
            $ip       = [System.Net.WebUtility]::HtmlEncode($_.Name)
            $groupId  = "grp-" + ($ip -replace '[^a-zA-Z0-9]', '_')
            $count    = $_.Group.Count
            $encListJson = ($_.Group | ForEach-Object { '&quot;' + [Uri]::EscapeDataString($_.Name) + '&quot;' }) -join ','
            $rowsHtml = ($_.Group | ForEach-Object {
                $dispName = [System.Net.WebUtility]::HtmlEncode((Get-DisplayName $_.Name))
                $rawName  = [System.Net.WebUtility]::HtmlEncode($_.Name)
                $enc      = [Uri]::EscapeDataString($_.Name)
                $size     = if ($_.Length -lt 1024) { "$($_.Length) B" } elseif ($_.Length -lt 1MB) { "{0:N1} KB" -f ($_.Length/1KB) } else { "{0:N1} MB" -f ($_.Length/1MB) }
                $date     = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
                "<tr><td><a href='/download/file?name=$enc' class='dl-link dl-href' title='$rawName'>&#128196;&nbsp;$dispName</a></td><td>$size</td><td>$date</td><td><button class='copy-url-btn' data-name='$enc' onclick=`"copyUrl(this)`" title='Copy direct download link'>&#128279; Copy URL</button></td></tr>"
            }) -join "`n"

            @"
<div class="ip-group">
  <div class="ip-header-row">
    <button class="ip-header" onclick="toggleGroup('$groupId')" aria-expanded="true">
      <span class="ip-icon">&#127760;</span>
      <span class="ip-addr">$ip</span>
      <span class="ip-count badge">$count file$(if($count -ne 1){'s'})</span>
      <span class="ip-chevron" id="chev-$groupId">&#9650;</span>
    </button>
    <button class="dl-all-btn" onclick="downloadAll(this)" data-group="$groupId" title="Download all files from this sender">&#11123; Download All</button>
    <button class="zip-all-btn" onclick="zipAll(this)" data-ip="$ip" title="Zip and download all files from this sender">&#128230; Zip &amp; Download</button>
  </div>
  <div class="ip-body" id="$groupId" data-files="[$encListJson]">
    <table>
      <thead><tr><th>File</th><th>Size</th><th>Uploaded</th><th></th></tr></thead>
      <tbody>$rowsHtml</tbody>
    </table>
  </div>
</div>
"@
        }) -join "`n"
    }

    return @"
<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Download Files</title>
<style>$CSS_SHARED
  /* ── Download-specific ── */
  .dl-content {
    max-width: 1200px; margin: 0 auto;
  }
  .stat-pill {
    display: inline-flex; align-items: center; gap: .3rem;
    border-radius: 999px; padding: .25rem .75rem;
    font-family: var(--mono); font-size: .78rem; color: var(--muted);
    border: 1px solid var(--border); background: rgba(255,255,255,.04);
  }
  .stat-pill strong { color: var(--text); }
  .ip-group {
    margin-bottom: 1rem; border: 1px solid var(--border);
    border-radius: var(--radius); overflow: hidden;
    background: var(--surface);
  }
  .ip-header-row {
    display: flex; align-items: stretch;
    background: var(--surface2);
    border-bottom: 1px solid var(--border);
  }
  .ip-header {
    flex: 1; display: flex; align-items: center; gap: .7rem;
    padding: .85rem 1.2rem;
    background: transparent; border: none;
    color: var(--text); font-family: var(--font); font-size: .95rem; font-weight: 700;
    cursor: pointer; text-align: left; transition: background .15s;
    min-width: 0;
  }
  .ip-header:hover { background: rgba(255,255,255,.05); }
  .ip-icon { font-size: 1rem; }
  .ip-addr { flex: 1; font-family: var(--mono); color: var(--accent2); font-size: .88rem; }
  .ip-chevron { font-size: .65rem; color: var(--muted); transition: transform .2s; }
  .ip-chevron.collapsed { transform: rotate(180deg); }
  .ip-body.collapsed { display: none; }
  table { width: 100%; border-collapse: collapse; }
  th {
    text-align: left; font-size: .72rem; letter-spacing: .08em; text-transform: uppercase;
    color: var(--muted); padding: .55rem 1.2rem; border-bottom: 1px solid var(--border);
    background: rgba(0,0,0,.2);
  }
  td { padding: .7rem 1.2rem; border-bottom: 1px solid rgba(255,255,255,.04); font-size: .9rem; vertical-align: middle; }
  td:nth-child(2), td:nth-child(3) { color: var(--muted); font-family: var(--mono); font-size: .8rem; white-space: nowrap; }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: rgba(255,255,255,.02); }
  .dl-link { color: var(--accent2); text-decoration: none; font-family: var(--mono); font-size: .85rem; }
  .dl-link:hover { color: var(--accent); }
  .copy-url-btn {
    display: inline-flex; align-items: center; gap: .35rem;
    padding: .3rem .7rem; border-radius: 6px;
    font-family: var(--mono); font-size: .75rem; font-weight: 500;
    color: var(--muted); background: transparent;
    border: 1px solid var(--border); cursor: pointer;
    transition: color .15s, border-color .15s, background .15s;
    white-space: nowrap;
  }
  .copy-url-btn:hover { color: var(--accent2); border-color: var(--accent2); background: rgba(0,221,255,.07); }
  .copy-url-btn.copied { color: #15ff21; border-color: rgba(21,255,33,.6); background: rgba(21,255,33,.07); }
  .dl-all-btn {
    display: inline-flex; align-items: center; gap: .35rem;
    padding: .5rem 1rem;
    font-family: var(--mono); font-size: .75rem; font-weight: 500;
    color: #0d0d0f; background: var(--accent2);
    border: none; border-left: 1px solid var(--border); cursor: pointer;
    transition: color .15s, background .15s, opacity .15s;
    white-space: nowrap; flex-shrink: 0;
  }
  .dl-all-btn:hover { background: #fff; }
  .dl-all-btn.busy { opacity: .45; cursor: default; }
  .zip-all-btn {
    display: inline-flex; align-items: center; gap: .35rem;
    padding: .5rem 1rem;
    font-family: var(--mono); font-size: .75rem; font-weight: 500;
    color: #0d0d0f; background: #22c55e;
    border: none; border-left: 1px solid var(--border); cursor: pointer;
    transition: background .15s, opacity .15s;
    white-space: nowrap; flex-shrink: 0;
  }
  .zip-all-btn:hover { background: #4ade80; }
  .zip-all-btn.busy { opacity: .45; cursor: default; }
  .empty-state {
    text-align: center; color: var(--muted); padding: 5rem 2rem;
    font-family: var(--mono); font-size: .9rem;
    border: 1px dashed var(--border); border-radius: var(--radius);
  }
  .empty-state-icon { font-size: 2.5rem; margin-bottom: 1rem; }
  td:nth-child(4) { width: 1%; white-space: nowrap; padding-right: 1rem; }
</style></head>
<body>
<div class="topbar">
  <span class="topbar-title">&#128229; Downloads $(if (-not [string]::IsNullOrEmpty($script:ServerSettings.Password)) { "<span class='badge'>Secure</span>" } else { "<span class='badge'>Public</span>" })</span>
  <span class="topbar-meta">
    <span class="stat-pill">&#128196; <strong>$($files.Count)</strong> file$(if($files.Count -ne 1){'s'})</span>
    <span class="stat-pill">&#127760; <strong>$($grouped.Count)</strong> sender$(if($grouped.Count -ne 1){'s'})</span>
  </span>
  <nav class="topbar-nav">
    <a href="/">&larr; Upload</a>
    $(if (-not [string]::IsNullOrEmpty($script:ServerSettings.Password)) { "<a href='/download/logout' class='danger'>&#128274; Lock &amp; Exit</a>" })
  </nav>
</div>

<div class="page">
  <div class="dl-content">
    $groupHtml
  </div>
</div>

<script>var DL_PASSWORD = $(if (-not [string]::IsNullOrEmpty($script:ServerSettings.Password)) { "'" + ($script:ServerSettings.Password -replace "'", "\\x27" -replace '\\', '\\\\') + "'" } else { 'null' });</script>
<script>
if (DL_PASSWORD) {
  document.querySelectorAll('a.dl-href').forEach(function(a) {
    a.href = a.getAttribute('href') + '&password=' + encodeURIComponent(DL_PASSWORD);
  });
}
function toggleGroup(id) {
  var body  = document.getElementById(id);
  var chev  = document.getElementById('chev-' + id);
  var row   = body.previousElementSibling;
  var btn   = row.querySelector('.ip-header');
  var collapsed = body.classList.toggle('collapsed');
  chev.classList.toggle('collapsed', collapsed);
  btn.setAttribute('aria-expanded', !collapsed);
}
function downloadAll(btn) {
  var groupId = btn.getAttribute('data-group');
  var body = document.getElementById(groupId);
  var files = JSON.parse(body.getAttribute('data-files'));
  var pw = (typeof DL_PASSWORD !== 'undefined' && DL_PASSWORD) ? '&password=' + encodeURIComponent(DL_PASSWORD) : '';
  btn.classList.add('busy');
  btn.innerHTML = '&#8987; Downloading…';
  var i = 0;
  function next() {
    if (i >= files.length) {
      setTimeout(function() {
        btn.classList.remove('busy');
        btn.innerHTML = '&#11123; Download All';
      }, 1000);
      return;
    }
    var a = document.createElement('a');
    a.href = '/download/file?name=' + files[i] + pw;
    a.download = '';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    i++;
    setTimeout(next, 600);
  }
  next();
}
function zipAll(btn) {
  var ip = btn.getAttribute('data-ip');
  var pw = (typeof DL_PASSWORD !== 'undefined' && DL_PASSWORD) ? '&password=' + encodeURIComponent(DL_PASSWORD) : '';
  btn.classList.add('busy');
  btn.innerHTML = '&#8987; Zipping…';
  fetch('/download/zip?ip=' + encodeURIComponent(ip) + pw)
    .then(function(res) {
      if (!res.ok) throw new Error('Server returned ' + res.status);
      var cd = res.headers.get('Content-Disposition') || '';
      var match = cd.match(/filename\*?=(?:UTF-8'')?([^;]+)/i);
      var filename = match ? decodeURIComponent(match[1].replace(/"/g, '')) : 'files.zip';
      return res.blob().then(function(blob) { return { blob: blob, filename: filename }; });
    })
    .then(function(r) {
      var url = URL.createObjectURL(r.blob);
      var a = document.createElement('a');
      a.href = url;
      a.download = r.filename;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
    })
    .catch(function(err) { alert('Zip failed: ' + err.message); })
    .finally(function() {
      btn.classList.remove('busy');
      btn.innerHTML = '&#128230; Zip &amp; Download';
    });
}
function copyUrl(btn) {
  var name = btn.getAttribute('data-name');
  var pw = (typeof DL_PASSWORD !== 'undefined' && DL_PASSWORD) ? '&password=' + encodeURIComponent(DL_PASSWORD) : '';
  var url = window.location.origin + '/download/file?name=' + name + pw;
  navigator.clipboard.writeText(url).then(function() {
    var orig = btn.innerHTML;
    btn.innerHTML = '&#10003; Copied!';
    btn.classList.add('copied');
    setTimeout(function() { btn.innerHTML = orig; btn.classList.remove('copied'); }, 2000);
  }).catch(function() {
    window.prompt('Copy this URL:', url);
  });
}
</script>
</body></html>
"@
}

# ── Admin Page ───────────────────────────────────────────────────────────────
function Get-AdminPage([string]$msg = "", [bool]$isError = $false) {
    $regexVal   = [System.Net.WebUtility]::HtmlEncode($script:ServerSettings.UploadFileRegex)
    $folderVal  = [System.Net.WebUtility]::HtmlEncode($script:ServerSettings.UploadFolder)
    $passwordVal = [System.Net.WebUtility]::HtmlEncode($script:ServerSettings.Password)
    $maxMbVal = if ($script:ServerSettings.MaxUploadSize -gt 0) {
        [math]::Round($script:ServerSettings.MaxUploadSize / 1048576, 2).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    } else { "0" }
    $regexStatusBadge = if ([string]::IsNullOrWhiteSpace($script:ServerSettings.UploadFileRegex)) { "Disabled" } else { "Active" }
    $passwordStatusBadge = if ([string]::IsNullOrEmpty($script:ServerSettings.Password)) { "Unsecured" } else { "Protected" }
    $folderStatusBadge = "Configured"
    $maxSizeStatusBadge = if ($script:ServerSettings.MaxUploadSize -gt 0) { (Format-ByteSize $script:ServerSettings.MaxUploadSize) } else { "Unlimited" }
    $msgHtml = ""
    if ($msg) {
        $cls = if ($isError) { "err" } else { "ok" }
        $msgHtml = "<div class='msg $cls' id='admin-flash'>$([System.Net.WebUtility]::HtmlEncode($msg))</div>"
    }
    return @"
<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Server Admin</title>
<style>$CSS_SHARED
  .admin-content { max-width: 900px; margin: 0 auto; }
  .setting-group {
    margin-bottom: 1rem; border: 1px solid var(--border);
    border-radius: var(--radius); overflow: hidden;
    background: var(--surface);
  }
  .setting-header {
    width: 100%; display: flex; align-items: center; gap: .7rem;
    padding: .85rem 1.2rem; background: var(--surface2);
    border: none; border-bottom: 1px solid var(--border);
    color: var(--text); font-family: var(--font); font-size: .95rem; font-weight: 700;
    cursor: pointer; text-align: left; transition: background .15s;
  }
  .setting-header:hover { background: rgba(255,255,255,.05); }
  .setting-icon { font-size: 1rem; }
  .setting-title { flex: 1; font-family: var(--mono); color: var(--accent2); font-size: .88rem; }
  .setting-status {
    font-family: var(--mono); font-size: .7rem; font-weight: 500;
    padding: .2rem .55rem; border-radius: 999px; flex-shrink: 0;
    background: rgba(106,240,200,.12); color: var(--accent2);
    border: 1px solid rgba(106,240,200,.25);
  }
  .setting-status.warn {
    background: rgba(255,95,95,.1); color: var(--danger);
    border-color: rgba(255,95,95,.35);
  }
  .setting-chevron { font-size: .65rem; color: var(--muted); transition: transform .2s; margin-left: .35rem; }
  .setting-chevron.collapsed { transform: rotate(180deg); }
  .setting-body { padding: 1.2rem 1.4rem 1.4rem; }
  .setting-body.collapsed { display: none; }
  .setting-help {
    color: var(--muted); font-family: var(--mono); font-size: .78rem;
    line-height: 1.55; margin-bottom: 1rem;
  }
  .setting-body input[type=text] { margin-top: 0; }
  .apply-bar {
    position: sticky; bottom: 0; margin-top: 1.5rem;
    padding: 1rem 0 .5rem;
    background: linear-gradient(transparent, var(--bg) 35%);
  }
  .apply-bar .btn { margin-top: 0; }
  .setting-help code {
    font-family: var(--mono); font-size: .76rem;
    background: var(--bg); padding: .1rem .35rem; border-radius: 4px;
  }
  .setting-help a { color: var(--accent2); }
  .setting-help a:hover { color: #fff; }
  .label-row {
    display: flex; align-items: center; gap: .5rem; margin-top: 1.2rem; margin-bottom: .5rem;
  }
  .label-row label { margin: 0; }
  .regex-help-link {
    display: inline-flex; align-items: center; justify-content: center;
    width: 1.35rem; height: 1.35rem; border-radius: 50%;
    font-family: var(--font); font-size: .85rem; font-weight: 800;
    color: var(--accent2); text-decoration: none;
    border: 1.5px solid var(--accent2); background: rgba(0,221,255,.08);
    transition: background .15s, color .15s, border-color .15s;
    flex-shrink: 0;
  }
  .regex-help-link:hover {
    background: rgba(0,221,255,.2); color: #fff; border-color: #fff;
  }
</style></head>
<body>
<div class="topbar">
  <span class="topbar-title">&#9881; Server Admin <span class="badge">Localhost</span></span>
  <span class="topbar-meta"></span>
  <nav class="topbar-nav">
    <a href="/">&larr; Upload</a>
    <a href="/download">Download</a>
  </nav>
</div>

<div class="page">
  <div class="admin-content">
    <h1 style="margin-bottom:.35rem;">Settings</h1>
    <p class="sub" style="margin-bottom:1.2rem;">Live server options — only reachable from this machine</p>
    $msgHtml

    <div class="setting-group">
      <button class="setting-header" type="button" onclick="toggleSetting('set-folder')" aria-expanded="true">
        <span class="setting-icon">&#128193;</span>
        <span class="setting-title">Upload location</span>
        <span class="setting-status" id="status-folder">$folderStatusBadge</span>
        <span class="setting-chevron" id="chev-set-folder">&#9650;</span>
      </button>
      <div class="setting-body" id="set-folder">
        <p class="setting-help">
          Folder where uploaded files are stored. The directory is created if it does not exist.
        </p>
        <label for="uploadFolder">Path</label>
        <input type="text" id="uploadFolder" name="uploadFolder" placeholder="e.g. C:\shared\uploads" value="$folderVal" autocomplete="off" spellcheck="false">
      </div>
    </div>

    <div class="setting-group">
      <button class="setting-header" type="button" onclick="toggleSetting('set-password')" aria-expanded="true">
        <span class="setting-icon">&#128274;</span>
        <span class="setting-title">Download password</span>
        <span class="setting-status $(if ([string]::IsNullOrEmpty($script:ServerSettings.Password)) { 'warn' })" id="status-password">$passwordStatusBadge</span>
        <span class="setting-chevron" id="chev-set-password">&#9650;</span>
      </button>
      <div class="setting-body" id="set-password">
        <p class="setting-help">
          Password required for the download page. Leave empty for unsecured (public) downloads.
          Changing the password clears active download sessions.
        </p>
        <label for="downloadPassword">Password</label>
        <input type="text" id="downloadPassword" name="downloadPassword" placeholder="empty = no password" value="$passwordVal" autocomplete="off" spellcheck="false">
      </div>
    </div>

    <div class="setting-group">
      <button class="setting-header" type="button" onclick="toggleSetting('set-regex')" aria-expanded="true">
        <span class="setting-icon">&#128196;</span>
        <span class="setting-title">Upload filename regex</span>
        <span class="setting-status $(if ([string]::IsNullOrWhiteSpace($script:ServerSettings.UploadFileRegex)) { 'warn' })" id="status-regex">$regexStatusBadge</span>
        <span class="setting-chevron" id="chev-set-regex">&#9650;</span>
      </button>
      <div class="setting-body" id="set-regex">
        <p class="setting-help">
          When set, each uploaded file's original name must match this .NET regex pattern or the upload is rejected.
          Leave empty to allow any filename. Example: <code>\.(pdf|docx)$</code>
          Not sure what to write? Ask an AI to build a pattern from a few example filenames you want to allow or block,
          then test it on <a href="https://regex101.com/" target="_blank" rel="noopener noreferrer">regex101.com</a>
          (select the <strong>.NET</strong> flavor).
        </p>
        <div class="label-row">
          <label for="uploadFileRegex">Pattern</label>
          <a href="https://regex101.com/" target="_blank" rel="noopener noreferrer" class="regex-help-link"
             title="Open regex101.com to test .NET patterns">?</a>
        </div>
        <input type="text" id="uploadFileRegex" name="uploadFileRegex" placeholder="e.g. \.(pdf|txt)$" value="$regexVal" autocomplete="off" spellcheck="false">
      </div>
    </div>

    <div class="setting-group">
      <button class="setting-header" type="button" onclick="toggleSetting('set-maxsize')" aria-expanded="true">
        <span class="setting-icon">&#128230;</span>
        <span class="setting-title">Max upload size</span>
        <span class="setting-status" id="status-maxsize">$maxSizeStatusBadge</span>
        <span class="setting-chevron" id="chev-set-maxsize">&#9650;</span>
      </button>
      <div class="setting-body" id="set-maxsize">
        <p class="setting-help">
          Maximum size per uploaded file. Set <code>0</code> for unlimited.
          Value is in megabytes (e.g. <code>100</code> = 100 MB).
        </p>
        <label for="maxUploadSizeMb">Megabytes (MB)</label>
        <input type="text" id="maxUploadSizeMb" name="maxUploadSizeMb" placeholder="0 = unlimited" value="$maxMbVal" autocomplete="off" spellcheck="false">
      </div>
    </div>

    <div class="apply-bar">
      <button type="button" class="btn" id="applyBtn">&#10003;&nbsp; Apply settings (live)</button>
    </div>
  </div>
</div>

<script>
function toggleSetting(id) {
  var body = document.getElementById(id);
  var chev = document.getElementById('chev-' + id);
  var btn  = body.previousElementSibling;
  var collapsed = body.classList.toggle('collapsed');
  chev.classList.toggle('collapsed', collapsed);
  btn.setAttribute('aria-expanded', !collapsed);
}

function showFlash(text, isErr) {
  var el = document.getElementById('admin-flash');
  if (!el) {
    el = document.createElement('div');
    el.id = 'admin-flash';
    document.querySelector('.admin-content').insertBefore(el, document.querySelector('.setting-group'));
  }
  el.className = 'msg ' + (isErr ? 'err' : 'ok');
  el.textContent = text;
}

function updateStatusBadges(s) {
  var regexEl = document.getElementById('status-regex');
  var pwEl = document.getElementById('status-password');
  var folderEl = document.getElementById('status-folder');
  if (regexEl) {
    var regexOn = !!(s.uploadFileRegex && s.uploadFileRegex.trim());
    regexEl.textContent = regexOn ? 'Active' : 'Disabled';
    regexEl.classList.toggle('warn', !regexOn);
  }
  if (pwEl) {
    var secured = !!(s.password && String(s.password).length);
    pwEl.textContent = secured ? 'Protected' : 'Unsecured';
    pwEl.classList.toggle('warn', !secured);
  }
  if (folderEl) folderEl.textContent = (s.uploadFolder && s.uploadFolder.trim()) ? 'Configured' : 'Not set';
  var maxEl = document.getElementById('status-maxsize');
  if (maxEl) {
    var lim = parseInt(s.maxUploadSize, 10) || 0;
    if (lim <= 0) { maxEl.textContent = 'Unlimited'; maxEl.classList.remove('warn'); }
    else {
      var mb = lim / 1048576;
      maxEl.textContent = (mb >= 1 ? mb.toFixed(mb % 1 === 0 ? 0 : 1) + ' MB' : (lim / 1024).toFixed(0) + ' KB');
      maxEl.classList.remove('warn');
    }
  }
}

function mbToBytes(mbStr) {
  var mb = parseFloat(String(mbStr).replace(',', '.'));
  if (isNaN(mb) || mb <= 0) return 0;
  return Math.round(mb * 1048576);
}

function bytesToMbStr(bytes) {
  var b = parseInt(bytes, 10) || 0;
  if (b <= 0) return '0';
  return String(Math.round((b / 1048576) * 100) / 100);
}

document.getElementById('applyBtn').addEventListener('click', async function() {
  const btn = document.getElementById('applyBtn');
  btn.disabled = true;
  try {
    const payload = {
      uploadFileRegex: document.getElementById('uploadFileRegex').value,
      uploadFolder: document.getElementById('uploadFolder').value,
      password: document.getElementById('downloadPassword').value,
      maxUploadSize: mbToBytes(document.getElementById('maxUploadSizeMb').value)
    };
    const res = await fetch('/admin/settings', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
    const data = await res.json();
    if (!res.ok || !data.ok) {
      throw new Error(data.error || 'Update failed');
    }
    if (data.settings) {
      document.getElementById('uploadFileRegex').value = data.settings.uploadFileRegex || '';
      document.getElementById('uploadFolder').value = data.settings.uploadFolder || '';
      document.getElementById('downloadPassword').value = data.settings.password || '';
      document.getElementById('maxUploadSizeMb').value = bytesToMbStr(data.settings.maxUploadSize);
      updateStatusBadges(data.settings);
    }
    showFlash('Settings applied — server is using the new configuration.', false);
  } catch (e) {
    showFlash(e.message || 'Update failed', true);
  } finally {
    btn.disabled = false;
  }
});
</script>
</body></html>
"@
}

# ── Multipart Parser ─────────────────────────────────────────────────────────
function Save-UploadedFile([System.Net.HttpListenerRequest]$req, [string]$senderIP = "unknown") {
    $contentType = $req.ContentType
    $bodyLen = $req.ContentLength64
    Write-ServerLog "Save-UploadedFile: begin from $senderIP (Content-Type: $contentType, Content-Length: $bodyLen)" -Level Info

    if (-not $contentType -or $contentType -notmatch "multipart/form-data") {
        Write-ServerLog "Save-UploadedFile: skipped — not multipart/form-data" -Level Warn
        return @{ Names = @(); Error = $null }
    }

    $limit = $script:ServerSettings.MaxUploadSize
    if ($limit -gt 0 -and $req.ContentLength64 -ge 0 -and $req.ContentLength64 -gt $limit) {
        Write-ServerLog "Save-UploadedFile: rejected — body $bodyLen exceeds limit $(Format-ByteSize $limit)" -Level Warn
        return @{
            Names = @()
            Error = "Upload exceeds maximum size ($(Format-ByteSize $limit))."
        }
    }

    if ($contentType -match 'boundary="?([^";]+)"?') {
        $boundary = $Matches[1].Trim()
        Write-ServerLog "Save-UploadedFile: multipart boundary length $($boundary.Length)" -Level Debug
    } else {
        Write-ServerLog "Save-UploadedFile: no boundary in Content-Type" -Level Warn
        return @{ Names = @(); Error = $null }
    }

    # ── Streaming multipart parser ────────────────────────────────────────────
    # Boundary markers as bytes
    [byte[]]$boundaryBytes  = [System.Text.Encoding]::ASCII.GetBytes("--$boundary")
    [byte[]]$delimBytes     = [System.Text.Encoding]::ASCII.GetBytes("`r`n--$boundary")
    [byte[]]$dblCRLF        = [byte[]](13,10,13,10)
    [byte[]]$CRLF           = [byte[]](13,10)

    $savedNames = [System.Collections.Generic.List[string]]::new()

    # Stream the entire request into a temp file in the upload folder (avoids 2 GB RAM limit)
    $tmpPath = New-UploadFolderTempPath 'upload-parse'
    Write-ServerLog "Save-UploadedFile: streaming body to temp $tmpPath" -Level Debug
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $tmpWrite = [System.IO.File]::OpenWrite($tmpPath)
        try { $req.InputStream.CopyTo($tmpWrite) } finally { $tmpWrite.Dispose() }
        $sw.Stop()
        $tmpSize = (Get-Item -LiteralPath $tmpPath).Length
        Write-ServerLog "Save-UploadedFile: body written ($tmpSize bytes) in $($sw.ElapsedMilliseconds) ms" -Level Info

        # Now parse the temp file using a FileStream — never loads the whole body into RAM
        $fs = [System.IO.File]::OpenRead($tmpPath)
        try {
            $fileLen = $fs.Length
            Write-ServerLog "Save-UploadedFile: parsing multipart ($fileLen bytes on disk)" -Level Debug

            # Helper: read a small slice of the stream into a string (for headers only)
            function Read-StreamSlice([System.IO.FileStream]$stream, [long]$start, [int]$length) {
                [byte[]]$slice = New-Object byte[] $length
                $stream.Position = $start
                $stream.Read($slice, 0, $length) | Out-Null
                return [System.Text.Encoding]::UTF8.GetString($slice)
            }

            # Helper: copy a section of the FileStream directly to a destination FileStream
            function Copy-StreamSection([System.IO.FileStream]$src, [long]$start, [long]$length, [System.IO.FileStream]$dst) {
                $src.Position = $start
                [byte[]]$buf = New-Object byte[] 65536   # 64 KB copy buffer
                $remaining = $length
                while ($remaining -gt 0) {
                    $toRead = [Math]::Min($buf.Length, $remaining)
                    $read = $src.Read($buf, 0, $toRead)
                    if ($read -eq 0) { break }
                    $dst.Write($buf, 0, $read)
                    $remaining -= $read
                }
            }

            # Locate first boundary
            $cur = Find-BytePatternInFileStream $fs $boundaryBytes 0
            if ($cur -lt 0) { return @{ Names = $savedNames; Error = $null } }
            $cur += $boundaryBytes.Length   # skip "--boundary"

            while ($true) {
                if ($cur + 1 -ge $fileLen) { break }
                # Check for final boundary ("--")
                [byte[]]$twoBytes = New-Object byte[] 2
                $fs.Position = $cur; $fs.Read($twoBytes, 0, 2) | Out-Null
                if ($twoBytes[0] -eq 45 -and $twoBytes[1] -eq 45) { break }
                $cur += 2   # skip CRLF after boundary line

                # Find end of part headers (double CRLF)
                $hdrEnd = Find-BytePatternInFileStream $fs $dblCRLF $cur
                if ($hdrEnd -lt 0) { break }

                $hdrLen = [int]($hdrEnd - $cur)
                if ($hdrLen -lt 0 -or $hdrLen -gt 65536) { break }
                $hdrStr    = Read-StreamSlice $fs $cur $hdrLen
                $dataStart = $hdrEnd + 4   # skip double-CRLF

                # Find next delimiter (CRLF + "--" + boundary)
                $nextDelim = Find-BytePatternInFileStream $fs $delimBytes $dataStart
                if ($nextDelim -lt 0) { break }

                $dataLen = $nextDelim - $dataStart

                if ($limit -gt 0 -and $dataLen -gt $limit) {
                    return @{
                        Names = @()
                        Error = "File exceeds maximum upload size ($(Format-ByteSize $limit))."
                    }
                }

                if ($hdrStr -match 'filename="([^"]*)"') {
                    $origName = $Matches[1]
                    if ($origName -ne '') {
                        $nameCheck = Test-UploadFileName $origName
                        if (-not $nameCheck.Ok) {
                            return @{ Names = $savedNames; Error = $nameCheck.Message }
                        }
                        $safeName = ([System.IO.Path]::GetFileName($origName)) -replace '[^\w\.\-_() ]',''
                        if (-not $safeName) { $safeName = "upload_" + (Get-Date -Format 'yyyyMMddHHmmss') }
                        $base = [System.IO.Path]::GetFileNameWithoutExtension($safeName)
                        $ext  = [System.IO.Path]::GetExtension($safeName)
                        $safeIP = $senderIP -replace '[:\\/]','-'
                        $safeName = "${base}-${safeIP}${ext}"
                        $destPath = Join-Path $script:ServerSettings.UploadFolder $safeName
                        $idx = 1
                        while (Test-Path $destPath) {
                            $destPath = Join-Path $script:ServerSettings.UploadFolder "${base}-${safeIP}_${idx}${ext}"; $idx++
                        }
                        $partDest = "$destPath.$([Guid]::NewGuid().ToString('N')).part"
                        try {
                            $destStream = [System.IO.File]::OpenWrite($partDest)
                            try {
                                if ($dataLen -gt 0) {
                                    Copy-StreamSection $fs $dataStart $dataLen $destStream
                                }
                            } finally { $destStream.Dispose() }
                            Move-Item -LiteralPath $partDest -Destination $destPath -Force
                            $savedName = [System.IO.Path]::GetFileName($destPath)
                            $savedNames.Add($savedName)
                            Write-ServerLog "Save-UploadedFile: saved '$savedName' ($dataLen bytes) -> $destPath" -Level Ok
                        } catch {
                            if (Test-Path -LiteralPath $partDest) {
                                Remove-Item -LiteralPath $partDest -Force -ErrorAction SilentlyContinue
                            }
                            Write-ServerLog "Save-UploadedFile: failed writing '$origName' — $($_.Exception.Message)" -Level Error
                            throw
                        }
                    }
                }

                # Advance: skip CRLF + "--" + boundary
                $cur = $nextDelim + 2 + 2 + $boundaryBytes.Length
            }
        } finally { $fs.Dispose() }
    } finally {
        Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
        Write-ServerLog "Save-UploadedFile: removed temp $tmpPath" -Level Debug
    }

    Write-ServerLog "Save-UploadedFile: done — $($savedNames.Count) file(s) saved" -Level Ok
    return @{ Names = $savedNames; Error = $null }
}

# ── HTTP Server ──────────────────────────────────────────────────────────────
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://*:$Port/")

try {
  $result = Get-NetFirewallRule -DisplayName "Powershell"
  if (-not $result) {
    New-NetFirewallRule -DisplayName "Powershell" -Direction Inbound -Program "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -Action Allow | Out-Null
    Write-ServerLog "Firewall: added inbound rule for PowerShell" -Level Info
  } else {
    Write-ServerLog "Firewall: PowerShell inbound rule already present" -Level Debug
  }
}
catch {
  New-NetFirewallRule -DisplayName "Powershell" -Direction Inbound -Program "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -Action Allow | Out-Null
  Write-ServerLog "Firewall: created rule (Get-NetFirewallRule unavailable)" -Level Warn
}


try {
    $listener.Start()
    Write-ServerLog "HttpListener started on port $Port" -Level Ok
} catch {
    Write-ServerLog "Cannot start listener on port $Port — $($_.Exception.Message)" -Level Error
    exit 1
}

$privateIP = (Get-NetIPConfiguration | Where-Object {$_.IPv4DefaultGateway -ne $null -and $_.NetAdapter.Status -ne "Disconnected"}).IPv4Address.IPAddress
$publicIP = "No Internet"
try {
  $publicIP  = (Invoke-WebRequest ifconfig.me/ip -UseBasicParsing).Content.Trim()
} catch {
  $publicIP = "No Internet"
}



# ── Check whether port is reachable from the internet ────────────────────────
$portOpen = $false
try {
    $probe    = Invoke-WebRequest "https://portchecker.io/api/me/${port}" -UseBasicParsing -TimeoutSec 10
    # portchecker returns JSON: {"status":"open"} or {"status":"closed"}
    $portOpen = $probe.Content -match 'True'
} catch {
    $portOpen = $false
}

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║       PowerShell File Server Running     ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
foreach ($ip in $privateIP) {
  Write-Host "  Upload Page   : http://${ip}:$Port/" -ForegroundColor Blue
  Write-Host "  Download Page : http://${ip}:$Port/download" -ForegroundColor Blue
}
Write-Host "  Upload Folder : $($script:ServerSettings.UploadFolder)" -ForegroundColor DarkBlue
Write-Host "  Admin Page    : http://127.0.0.1:$Port/admin  (localhost only)" -ForegroundColor DarkCyan
if (-not [string]::IsNullOrWhiteSpace($script:ServerSettings.UploadFileRegex)) {
  Write-Host "  Upload Regex  : $($script:ServerSettings.UploadFileRegex)" -ForegroundColor DarkCyan
}
if ($script:ServerSettings.MaxUploadSize -gt 0) {
  Write-Host "  Max Upload    : $(Format-ByteSize $script:ServerSettings.MaxUploadSize)" -ForegroundColor DarkCyan
} else {
  Write-Host "  Max Upload    : Unlimited" -ForegroundColor DarkCyan
}
if ([string]::IsNullOrEmpty($script:ServerSettings.Password)) {
  Write-Host "  Password      : Unsecure mode, no password needed" -ForegroundColor Red
}
else {
  Write-Host "  Password      : $($script:ServerSettings.Password)" -ForegroundColor Magenta
}
Write-Host "  Local IP      : $privateIP" -ForegroundColor DarkGray
Write-Host "  Public IP     : $publicIP" -ForegroundColor DarkGray
Write-Host ""
if ($upnpStatus) {
    $upnpColor = if ($upnpStatus -like "UPnP mapping added*") { "Green" } else { "Yellow" }
    Write-Host "  UPnP          : $upnpStatus" -ForegroundColor $upnpColor
}
if ($portOpen) {
    Write-Host "  Port $Port is open — server is reachable from the internet at http://${publicIP}:$Port/" -ForegroundColor Green
} else {
    Write-Host "  Port $Port is closed — to reach this server from outside your LAN, forward port $Port (TCP) on your router." -ForegroundColor Yellow
}Write-Host ""

Start-Process "http://127.0.0.1:${Port}/admin"

function Send-Response([System.Net.HttpListenerContext]$ctx, [string]$html, [int]$status=200, [string]$contentType="text/html; charset=utf-8", [byte[]]$rawBytes=$null) {
    $res = $ctx.Response
    $res.StatusCode = $status
    $res.ContentType = $contentType
    $bytes = if ($rawBytes) { $rawBytes } else { [System.Text.Encoding]::UTF8.GetBytes($html) }
    $res.ContentLength64 = $bytes.Length
    try { $res.OutputStream.Write($bytes, 0, $bytes.Length) } catch {}
    try { $res.OutputStream.Close() } catch {}
}

function Send-Redirect([System.Net.HttpListenerContext]$ctx, [string]$url) {
    $ctx.Response.StatusCode = 302
    $ctx.Response.RedirectLocation = $url
    try { $ctx.Response.OutputStream.Close() } catch {}
}

Write-ServerLog "Entering request loop (listening)" -Level Ok

while ($listener.IsListening) {
    $ctx = $null
    try { $ctx = $listener.GetContext() } catch {
        Write-ServerLog "GetContext ended: $($_.Exception.Message)" -Level Warn
        break
    }

    $req  = $ctx.Request
    $path = $req.Url.AbsolutePath.TrimEnd('/').ToLower()
    $method = $req.HttpMethod.ToUpper()

    $lenNote = if ($req.ContentLength64 -ge 0) { ", $($req.ContentLength64) bytes" } else { '' }
    if ($method -eq "GET") {
      Write-ServerLog "$($req.RemoteEndPoint) $method $($req.Url.PathAndQuery)$lenNote" -Level Debug
    } else {
      Write-ServerLog "$($req.RemoteEndPoint) $method $($req.Url.PathAndQuery)$lenNote" -Level Info
    }


    try {
        # ── GET / ────────────────────────────────────────────────────────────
        if ($path -eq "" -or $path -eq "/") {
            $ok = $req.QueryString["ok"]
            $err = $req.QueryString["err"]
            $detail = $req.QueryString["msg"]
            $msg = if ($detail) { [Uri]::UnescapeDataString($detail) }
                   elseif ($err) { "Upload failed for one or more files." }
                   elseif ($ok -and $ok -ne "1") { "Uploaded: $([Uri]::UnescapeDataString($ok))" }
                   elseif ($ok) { "Files uploaded successfully!" } else { "" }
            $isErr = [bool]$err
            Send-Response $ctx (Get-UploadPage -msg $msg -isError $isErr)
        }

        # ── POST /upload ─────────────────────────────────────────────────────
        elseif ($path -eq "/upload" -and $method -eq "POST") {
            Write-ServerLog "POST /upload (form) from $($req.RemoteEndPoint.Address)" -Level Info
            $uploadResult = Save-UploadedFile $req $req.RemoteEndPoint.Address.ToString()
            if ($uploadResult.Error) {
                Send-Response $ctx (Get-UploadPage -msg $uploadResult.Error -isError $true) -status 400
            } elseif ($uploadResult.Names -and $uploadResult.Names.Count -gt 0) {
                $enc = [Uri]::EscapeDataString(($uploadResult.Names -join ", "))
                Send-Redirect $ctx "/?ok=$enc"
            } else {
                Send-Response $ctx (Get-UploadPage -msg "Upload failed — no file received." -isError $true) -status 400
            }
        }

        # ── POST /upload-chunk (single file per XHR, used by progress uploader)
        elseif ($path -eq "/upload-chunk" -and $method -eq "POST") {
            Write-ServerLog "POST /upload-chunk from $($req.RemoteEndPoint.Address)" -Level Info
            $uploadResult = Save-UploadedFile $req $req.RemoteEndPoint.Address.ToString()
            if ($uploadResult.Error) {
                Write-ServerLog "/upload-chunk rejected: $($uploadResult.Error)" -Level Warn
                Send-Response $ctx $uploadResult.Error -status 400 -contentType "text/plain; charset=utf-8"
            } elseif ($uploadResult.Names -and $uploadResult.Names.Count -gt 0) {
                Write-ServerLog "/upload-chunk OK: $($uploadResult.Names -join ', ')" -Level Ok
                $ctx.Response.StatusCode  = 200
                $ctx.Response.ContentType = "text/plain; charset=utf-8"
                $okBytes = [System.Text.Encoding]::UTF8.GetBytes("ok")
                $ctx.Response.ContentLength64 = $okBytes.Length
                try { $ctx.Response.OutputStream.Write($okBytes, 0, $okBytes.Length) } catch {}
                try { $ctx.Response.OutputStream.Close() } catch {}
            } else {
                Write-ServerLog "/upload-chunk: no file in multipart body" -Level Warn
                Send-Response $ctx "Upload failed — no file received." -status 400 -contentType "text/plain; charset=utf-8"
            }
        }

        # ── GET /admin (localhost only) ──────────────────────────────────────
        elseif ($path -eq "/admin") {
            if (-not (Test-IsLocalRequest $req)) {
                Write-ServerLog "GET /admin denied — not localhost ($($req.RemoteEndPoint.Address))" -Level Warn
                Send-Response $ctx "<h2 style='font-family:sans-serif;color:#888'>403 — Admin is only available from localhost</h2>" -status 403
            } else {
                Write-ServerLog "GET /admin (localhost)" -Level Debug
                Send-Response $ctx (Get-AdminPage)
            }
        }

        # ── GET /admin/settings (localhost only) ─────────────────────────────
        elseif ($path -eq "/admin/settings" -and $method -eq "GET") {
            if (-not (Test-IsLocalRequest $req)) {
                Send-Response $ctx '{"ok":false,"error":"Forbidden"}' -status 403 -contentType "application/json; charset=utf-8"
            } else {
                Send-Response $ctx (Get-ServerSettingsJson) -contentType "application/json; charset=utf-8"
            }
        }

        # ── POST /admin/settings (localhost only) ────────────────────────────
        elseif ($path -eq "/admin/settings" -and $method -eq "POST") {
            if (-not (Test-IsLocalRequest $req)) {
                Send-Response $ctx '{"ok":false,"error":"Forbidden"}' -status 403 -contentType "application/json; charset=utf-8"
            } else {
                $reader = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
                $body   = $reader.ReadToEnd()
                $setErr = $null
                if (Set-ServerSettingsFromJson $body ([ref]$setErr)) {
                    $payload = (@{ ok = $true; settings = (Get-ServerSettingsObject) } | ConvertTo-Json -Compress -Depth 4)
                    Send-Response $ctx $payload -contentType "application/json; charset=utf-8"
                } else {
                    $payload = (@{ ok = $false; error = $setErr } | ConvertTo-Json -Compress -Depth 4)
                    Send-Response $ctx $payload -status 400 -contentType "application/json; charset=utf-8"
                }
            }
        }

        # ── GET /download ────────────────────────────────────────────────────
        elseif ($path -eq "/download") {
            $token = Get-CookieToken $req
            if ([string]::IsNullOrEmpty($script:ServerSettings.Password) -or (Test-Session $token)) {
                Send-Response $ctx (Get-DownloadPage)
            } else {
                Send-Response $ctx (Get-LoginPage)
            }
        }

        # ── POST /download/login ─────────────────────────────────────────────
        elseif ($path -eq "/download/login" -and $method -eq "POST") {
            if ([string]::IsNullOrEmpty($script:ServerSettings.Password)) {
                Send-Redirect $ctx "/download"
            } else {
                $reader = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
                $body   = $reader.ReadToEnd()
                $parsed = [System.Web.HttpUtility]::ParseQueryString($body)
                $pw     = $parsed["password"]
                if ($pw -eq $script:ServerSettings.Password) {
                    $token = New-SessionToken
                    $expiry = (Get-Date).AddHours(4)
                    $Sessions[$token] = $expiry
                    Write-ServerLog "Download login OK from $($req.RemoteEndPoint.Address) (session until $($expiry.ToString('HH:mm:ss')))" -Level Ok
                    $ctx.Response.AppendHeader("Set-Cookie", "ds=$token; Path=/; HttpOnly; SameSite=Strict")
                    Send-Redirect $ctx "/download"
                } else {
                    Write-ServerLog "Download login failed from $($req.RemoteEndPoint.Address)" -Level Warn
                    Send-Response $ctx (Get-LoginPage -failed $true)
                }
            }
        }

        # ── GET /download/logout ─────────────────────────────────────────────
        elseif ($path -eq "/download/logout") {
            $token = Get-CookieToken $req
            if ($token) {
                $dummy = [datetime]::MinValue
                $Sessions.TryRemove($token, [ref]$dummy) | Out-Null
            }
            $ctx.Response.AppendHeader("Set-Cookie", "ds=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly")
            Send-Redirect $ctx "/download"
        }

        # ── GET /download/file?name=... ──────────────────────────────────────
        elseif ($path -eq "/download/file") {
            $token     = Get-CookieToken $req
            $quickpass = $req.QueryString["password"]
            $authorized = [string]::IsNullOrEmpty($script:ServerSettings.Password) -or (Test-Session $token) -or ($quickpass -eq $script:ServerSettings.Password)
            if (-not $authorized) {
                Send-Redirect $ctx "/download"
            } else {
                $name = $req.QueryString["name"]
                $safe = [System.IO.Path]::GetFileName($name)   # strip any path traversal
                $filePath = Join-Path $script:ServerSettings.UploadFolder $safe
                if ($safe -and (Test-Path -LiteralPath $filePath -PathType Leaf)) {
                    Write-ServerLog "GET /download/file?name=$safe" -Level Info
                    Send-FileStreamResponse $ctx $filePath 'application/octet-stream' $safe
                } else {
                    Write-ServerLog "GET /download/file — not found: '$safe'" -Level Warn
                    Send-Response $ctx "<h2>404 — File not found</h2>" -status 404
                }
            }
        }

        # ── GET /download/zip?ip=... ─────────────────────────────────────────
        elseif ($path -eq "/download/zip") {
            $token     = Get-CookieToken $req
            $quickpass = $req.QueryString["password"]
            $authorized = [string]::IsNullOrEmpty($script:ServerSettings.Password) -or (Test-Session $token) -or ($quickpass -eq $script:ServerSettings.Password)
            if (-not $authorized) {
                Send-Redirect $ctx "/download"
            } else {
                $senderIp = $req.QueryString["ip"]
                $zipFiles = @(Get-UploadableFiles | Where-Object { (Get-SenderIpFromFileName $_.Name) -eq $senderIp })
                if ($zipFiles.Count -eq 0) {
                    Send-Response $ctx "<h2>404 — No files found for that sender</h2>" -status 404
                } else {
                    $paths = Get-ZipCachePaths $senderIp
                    $fingerprint = Get-ZipSourceFingerprint $zipFiles
                    if (-not (Test-ZipCacheValid $paths.ManifestPath $paths.ZipPath $fingerprint)) {
                        Write-ServerLog "Zip cache miss for sender $senderIp — rebuilding" -Level Info
                        Build-ZipCache $paths.ZipPath $zipFiles
                        Save-ZipCacheManifest $paths.ManifestPath $fingerprint
                    } else {
                        Write-ServerLog "Zip cache hit for sender $senderIp -> $($paths.ZipPath)" -Level Debug
                    }
                    Send-FileStreamResponse $ctx $paths.ZipPath 'application/zip' $paths.DisplayName
                }
            }
        }

        # ── 404 ──────────────────────────────────────────────────────────────
        else {
            Write-ServerLog "404 Not Found: $method $path" -Level Warn
            Send-Response $ctx "<h2 style='font-family:sans-serif;color:#888'>404 — Not Found</h2>" -status 404
        }
    }
    catch {
        Write-ServerLog "Request failed: $path — $_" -Level Error
        Write-ServerLog $_.ScriptStackTrace -Level Debug
        try { Send-Response $ctx "<h2>500 — Internal Server Error</h2>" -status 500 } catch {}
    }
}