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
    Can also be changed live on /admin (localhost only).

.PARAMETER Password
    Password required to access the download page. Mandatory requested on load

.PARAMETER UploadFileRegex
  Optional regex pattern upload filenames must match (original name, before save).
  Empty string disables validation. Can also be changed live on /admin (localhost only).

.PARAMETER MaxUploadSize
  Maximum upload size in bytes. 0 = unlimited. Can also be changed live on /admin (localhost only).

.PARAMETER UploadIPWhitelist
  Comma-separated list of IP addresses allowed to upload. Empty = allow all.
  Can also be changed live on /admin (localhost only).

.PARAMETER UploadWindowStart
  Optional upload window start (local time). ISO-8601 or "yyyy-MM-dd HH:mm". Empty = no start limit.
  Can also be changed live on /admin (localhost only).

.PARAMETER UploadWindowEnd
  Optional upload window end (local time). ISO-8601 or "yyyy-MM-dd HH:mm". Empty = no end limit.
  Can also be changed live on /admin (localhost only).

.EXAMPLE
  .\Upload-Download-Server-Local.ps1
  .\Upload-Download-Server-Local.ps1 -Port 9090 -Password "s3cr3t!" -UploadFolder "C:\shared"
  .\Upload-Download-Server-Local.ps1 -UploadFileRegex '\.(pdf|docx)$'
  .\Upload-Download-Server-Local.ps1 -Port 80 -Password "testing" -UploadFolder ".\uploads" -UploadFileRegex "\.(pdf|docx)" -UploadIPWhitelist "192.168.10.10, 192.168.10.11" -UploadWindowStart "2026.06.05 09:00" -UploadwindowEnd "2026.06.05 12:00"
#>
param(
    [Parameter(Mandatory = $false, HelpMessage = "The port on which the server will be opened. Must have no other processes using this port.")]
    [int]    $Port         = 80,

    [Parameter(Mandatory = $false, HelpMessage = "The folder where all the files will be saved to, you can put your own files there if you only wish to use the download part of the server without going through uploading")]
    [string] $UploadFolder = ".\uploads",

    [Parameter(Mandatory = $true, HelpMessage = "The password to be used to access the download page. If the password is left as a blank string the server will run in unsecure mode.")]
    [AllowEmptyString()]
    [string] $Password,

    [Parameter(Mandatory = $false, HelpMessage = "Regex pattern upload filenames must match. Empty = no restriction.")]
    [AllowEmptyString()]
    [string] $UploadFileRegex = "",

    [Parameter(Mandatory = $false, HelpMessage = "Maximum upload size in bytes. 0 = unlimited.")]
    [long] $MaxUploadSize = 0,

    [Parameter(Mandatory = $false, HelpMessage = "Comma-separated list of IP addresses allowed to upload. Empty = allow all.")]
    [AllowEmptyString()]
    [string] $UploadIPWhitelist = "",

    [Parameter(Mandatory = $false, HelpMessage = "Upload window start (local). Empty = no start limit.")]
    [AllowEmptyString()]
    [string] $UploadWindowStart = "",

    [Parameter(Mandatory = $false, HelpMessage = "Upload window end (local). Empty = no end limit.")]
    [AllowEmptyString()]
    [string] $UploadWindowEnd = ""
)

# ────────────────────────────────────────────────────────────────────────
# >> Setup
# ────────────────────────────────────────────────────────────────────────
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

function ConvertFrom-UploadWindowString([string]$text, [ref]$errorMsg) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $dt = $null
    if ([datetime]::TryParse($text.Trim(), [ref]$dt)) { return $dt }
    $formats = @('yyyy-MM-dd HH:mm', 'yyyy-MM-ddTHH:mm', 'yyyy/MM/dd HH:mm')
    foreach ($fmt in $formats) {
        if ([datetime]::TryParseExact($text.Trim(), $fmt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) {
            return $dt
        }
    }
    $errorMsg.Value = "Invalid date/time: '$text' (use yyyy-MM-dd HH:mm)"
    return $null
}

function ConvertFrom-UploadWindowPart($part, [ref]$errorMsg) {
    if ($null -eq $part) { return $null }
    $y = $part.year; $mo = $part.month; $d = $part.day; $h = $part.hour; $mi = $part.minute
    if ($null -eq $y -and $null -eq $mo -and $null -eq $d -and $null -eq $h -and $null -eq $mi) { return $null }
    try {
        return Get-Date -Year ([int]$y) -Month ([int]$mo) -Day ([int]$d) -Hour ([int]$h) -Minute ([int]$mi) -Second 0
    } catch {
        $errorMsg.Value = "Invalid upload window date: $($_.Exception.Message)"
        return $null
    }
}

function Get-UploadWindowPart([Nullable[datetime]]$dt) {
    if ($null -eq $dt) { return $null }
    return @{
        year   = $dt.Year
        month  = $dt.Month
        day    = $dt.Day
        hour   = $dt.Hour
        minute = $dt.Minute
    }
}

function Format-UploadWindowDisplay([Nullable[datetime]]$dt) {
    if ($null -eq $dt) { return '' }
    return $dt.ToString('yyyy-MM-dd HH:mm')
}

function ConvertTo-UnixTimeMs([Nullable[datetime]]$dt) {
    if ($null -eq $dt) { return $null }
    $local = $dt
    if ($local.Kind -eq [DateTimeKind]::Unspecified) {
        $local = [DateTime]::SpecifyKind($local, [DateTimeKind]::Local)
    }
    $epoch = New-Object datetime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
    return [int64](($local.ToUniversalTime() - $epoch).TotalMilliseconds)
}

function Get-UploadWindowState {
    if (-not $script:ServerSettings.UploadWindowEnabled) { return 'disabled' }
    $start = $script:ServerSettings.UploadWindowStart
    $end   = $script:ServerSettings.UploadWindowEnd
    if ($null -eq $start -and $null -eq $end) { return 'disabled' }
    $now = Get-Date
    if ($null -ne $start -and $now -lt $start) { return 'before' }
    if ($null -ne $end -and $now -ge $end) { return 'after' }
    return 'active'
}

function Test-UploadWindowOpen {
    $state = Get-UploadWindowState
    return ($state -eq 'disabled' -or $state -eq 'active')
}

$startupWindowErr = $null
$parsedWindowStart = ConvertFrom-UploadWindowString $UploadWindowStart ([ref]$startupWindowErr)
if ($startupWindowErr) {
    Write-ServerLog "Invalid -UploadWindowStart: $startupWindowErr" -Level Error
    exit 1
}
$parsedWindowEnd = ConvertFrom-UploadWindowString $UploadWindowEnd ([ref]$startupWindowErr)
if ($startupWindowErr) {
    Write-ServerLog "Invalid -UploadWindowEnd: $startupWindowErr" -Level Error
    exit 1
}
if ($null -ne $parsedWindowStart -and $null -ne $parsedWindowEnd -and $parsedWindowEnd -le $parsedWindowStart) {
    Write-ServerLog "Upload window end must be after start." -Level Error
    exit 1
}

# Live settings (also seeded from parameters; /admin can update at runtime)
$script:ServerSettings = @{
    UploadFileRegex      = $UploadFileRegex
    Password             = $Password
    UploadFolder         = $resolvedUploadFolder
    MaxUploadSize        = $MaxUploadSize
    UploadIPWhitelist    = @($UploadIPWhitelist -split '\s*,\s*' | Where-Object { $_ -ne '' })
    UploadWindowEnabled  = ($null -ne $parsedWindowStart -or $null -ne $parsedWindowEnd)
    UploadWindowStart    = $parsedWindowStart
    UploadWindowEnd      = $parsedWindowEnd
}

# ────────────────────────────────────────────────────────────────────────
# >> Self-Elevation
# ────────────────────────────────────────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-ServerLog "Not running as Administrator" -Level Warn
    Write-ServerLog "Please restart as administrator"
    Write-ServerLog "Auto closing in 30 seconds"
    Start-Sleep -Seconds 30
    exit
}

# Simple in-memory session store  { token -> expiry }
$Sessions = [System.Collections.Concurrent.ConcurrentDictionary[string,datetime]]::new()

Add-Type -AssemblyName System.IO.Compression

$script:UploadableFilesCache = @{
    Folder = $null
    Stamp  = $null
    Files  = $null
}

$script:AllSendersZipCache = @{
    Hash        = $null
    ZipPath     = $null
    DisplayName = "all-senders.zip"
    BuiltAt     = $null
}
$script:AllSendersZipLock = [object]::new()

$script:FirewallRuleName = "ScriptLibs-UploadDownloadServer-TCP-$Port"
$script:FirewallRuleCreated = $false

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

function Get-SessionCookieAttributes([System.Net.HttpListenerRequest]$req) {
    $attrs = "Path=/; HttpOnly; SameSite=Strict"
    if ($req -and $req.IsSecureConnection) { $attrs += "; Secure" }
    return $attrs
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

function Test-UploadIPAllowed([string]$ip) {
    $whitelist = $script:ServerSettings.UploadIPWhitelist
    if ($null -eq $whitelist -or $whitelist.Count -eq 0) { return $true }
    # Normalise IPv4-mapped IPv6 (e.g. ::ffff:192.168.1.1 -> 192.168.1.1)
    $normalized = $ip -replace '^::ffff:', ''
    foreach ($entry in $whitelist) {
        if ($entry.Trim() -eq $normalized) { return $true }
    }
    return $false
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

function Clear-UploadableFilesCache {
    $script:UploadableFilesCache.Folder = $null
    $script:UploadableFilesCache.Stamp = $null
    $script:UploadableFilesCache.Files = $null
    $script:AllSendersZipCache.Hash = $null
    $script:AllSendersZipCache.ZipPath = $null
    $script:AllSendersZipCache.BuiltAt = $null
}

function Get-UploadableFiles {
    $folder = $script:ServerSettings.UploadFolder
    $files = @(Get-ChildItem -Path $folder -File |
        Where-Object { $_.Name -notlike '.upload-parse-*' -and $_.Name -notlike '*.part' })

    $latestTicks = 0L
    foreach ($f in $files) {
        if ($f.LastWriteTimeUtc.Ticks -gt $latestTicks) { $latestTicks = $f.LastWriteTimeUtc.Ticks }
    }
    $stamp = "$($files.Count):$latestTicks"

    if ($script:UploadableFilesCache.Folder -eq $folder -and
        $script:UploadableFilesCache.Stamp -eq $stamp -and
        $null -ne $script:UploadableFilesCache.Files) {
        return $script:UploadableFilesCache.Files
    }

    $script:UploadableFilesCache.Folder = $folder
    $script:UploadableFilesCache.Stamp = $stamp
    $script:UploadableFilesCache.Files = $files
    return $files
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

function Find-SevenZipExe {
    $candidates = [System.Collections.Generic.List[string]]::new()
    if (${env:ProgramFiles}) { $candidates.Add((Join-Path ${env:ProgramFiles} '7-Zip\7z.exe')) }
    if (${env:ProgramFiles(x86)}) { $candidates.Add((Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe')) }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    $cmd = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Build-ZipCache([string]$destZip, $zipFiles) {
    Write-ServerLog "Build-ZipCache: building $($zipFiles.Count) file(s) -> $destZip" -Level Info
    $partPath = "$destZip.part"
    if (Test-Path -LiteralPath $partPath) { Remove-Item -LiteralPath $partPath -Force }
    $sevenZip = Find-SevenZipExe
    if ($sevenZip) {
        $listPath = "$partPath.files.txt"
        $zipFolder = $script:ServerSettings.UploadFolder
        try {
            $zipFiles | ForEach-Object { $_.Name } | Set-Content -LiteralPath $listPath -Encoding UTF8
            Push-Location $zipFolder
            try {
                & $sevenZip a -tzip -mx=1 $partPath "@$listPath" | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "7-Zip exited with code $LASTEXITCODE."
                }
            } finally {
                Pop-Location
            }
            Write-ServerLog "Build-ZipCache: used 7-Zip ($sevenZip)" -Level Debug
        } finally {
            Remove-Item -LiteralPath $listPath -Force -ErrorAction SilentlyContinue
        }
    } else {
        $fs = [System.IO.File]::Open($partPath, [System.IO.FileMode]::CreateNew)
        try {
            $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($f in $zipFiles) {
                    $entry = $zip.CreateEntry($f.Name, [System.IO.Compression.CompressionLevel]::Fastest)
                    $es = $entry.Open()
                    try {
                        $src = [System.IO.File]::OpenRead($f.FullName)
                        try { $src.CopyTo($es) } finally { $src.Dispose() }
                    } finally { $es.Dispose() }
                }
            } finally { $zip.Dispose() }
        } finally { $fs.Dispose() }
    }
    if (Test-Path -LiteralPath $destZip) { Remove-Item -LiteralPath $destZip -Force }
    Move-Item -LiteralPath $partPath -Destination $destZip -Force
    $zipSize = (Get-Item -LiteralPath $destZip).Length
    Write-ServerLog "Build-ZipCache: complete ($zipSize bytes)" -Level Ok
}

function Save-ZipCacheManifest([string]$manifestPath, $fingerprint) {
    @{ hash = (Get-ZipFingerprintHash $fingerprint) } | ConvertTo-Json -Compress |
        Set-Content -LiteralPath $manifestPath -Encoding UTF8 -NoNewline
}

function Get-AllSendersZipFingerprint($files) {
    $files | Sort-Object Name | ForEach-Object {
        [ordered]@{
            name  = $_.Name
            len   = $_.Length
            mtime = $_.LastWriteTimeUtc.ToString('o')
        }
    }
}

function Get-OrBuildSenderZip([string]$senderIp, $zipFiles) {
    $paths = Get-ZipCachePaths $senderIp
    $fingerprint = Get-ZipSourceFingerprint $zipFiles
    if (-not (Test-ZipCacheValid $paths.ManifestPath $paths.ZipPath $fingerprint)) {
        Write-ServerLog "Zip cache miss for sender $senderIp — rebuilding" -Level Info
        Build-ZipCache $paths.ZipPath $zipFiles
        Save-ZipCacheManifest $paths.ManifestPath $fingerprint
    } else {
        Write-ServerLog "Zip cache hit for sender $senderIp -> $($paths.ZipPath)" -Level Debug
    }
    return $paths
}

function Get-DisplayNameFromFileName([string]$filename) {
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($filename)
    $ext  = [System.IO.Path]::GetExtension($filename)
    $clean = $stem -replace '-\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(?:_\d+)?$', ''
    $clean = $clean -replace '-[0-9a-fA-F\-]{7,}(?:_\d+)?$', ''
    if (-not $clean) { $clean = $stem }
    return "$clean$ext"
}

function Get-FilenameZipCachePaths([string]$displayName) {
    $safe = ($displayName -replace '[^a-zA-Z0-9\.\-]', '_').TrimEnd('_')
    if (-not $safe) { $safe = "group" }
    $cacheDir = Get-ZipCacheDir
    @{
        ZipPath      = Join-Path $cacheDir "fname-$safe.zip"
        ManifestPath = Join-Path $cacheDir "fname-$safe.manifest.json"
        DisplayName  = "files-$safe.zip"
    }
}

function Get-OrBuildFilenameZip([string]$displayName, $zipFiles) {
    $paths = Get-FilenameZipCachePaths $displayName
    $fingerprint = Get-ZipSourceFingerprint $zipFiles
    if (-not (Test-ZipCacheValid $paths.ManifestPath $paths.ZipPath $fingerprint)) {
        Write-ServerLog "Zip cache miss for filename group '$displayName' — rebuilding" -Level Info
        Build-ZipCache $paths.ZipPath $zipFiles
        Save-ZipCacheManifest $paths.ManifestPath $fingerprint
    } else {
        Write-ServerLog "Zip cache hit for filename group '$displayName' -> $($paths.ZipPath)" -Level Debug
    }
    return $paths
}

function Get-MegaZipCachePaths([string]$mode) {
    $cacheDir = Get-ZipCacheDir
    @{
        ZipPath      = Join-Path $cacheDir "mega-$mode.zip"
        ManifestPath = Join-Path $cacheDir "mega-$mode.manifest.json"
        DisplayName  = "all-by-$mode.zip"
    }
}

function Get-OrBuildMegaZip([string]$mode, $allFiles) {
    $paths = Get-MegaZipCachePaths $mode

    # Collect the constituent group zips (building/caching each one first)
    $groupZips = [System.Collections.Generic.List[hashtable]]::new()
    if ($mode -eq 'fn') {
        $groups = @($allFiles | Group-Object { Get-DisplayNameFromFileName $_.Name } | Sort-Object Name)
        foreach ($g in $groups) {
            $gPaths = Get-OrBuildFilenameZip ([string]$g.Name) @($g.Group)
            $groupZips.Add($gPaths)
        }
    } else {
        # default: ip
        $groups = @($allFiles | Group-Object { Get-SenderIpFromFileName $_.Name } | Sort-Object Name)
        foreach ($g in $groups) {
            $gPaths = Get-OrBuildSenderZip ([string]$g.Name) @($g.Group)
            $groupZips.Add($gPaths)
        }
    }

    # Fingerprint = sorted list of constituent zip paths + their mtimes
    $fingerprint = ($groupZips | ForEach-Object {
        $zi = Get-Item -LiteralPath $_.ZipPath
        "$($_.ZipPath)|$($zi.LastWriteTimeUtc.Ticks)|$($zi.Length)"
    }) -join "`n"

    if ((Test-ZipCacheValid $paths.ManifestPath $paths.ZipPath $fingerprint)) {
        Write-ServerLog "Mega-zip cache hit ($mode) -> $($paths.ZipPath)" -Level Debug
        return $paths
    }

    Write-ServerLog "Mega-zip cache miss ($mode) — building zip of zips on disk" -Level Info
    $partPath = "$($paths.ZipPath).part"
    if (Test-Path -LiteralPath $partPath) { Remove-Item -LiteralPath $partPath -Force }

    $fs = [System.IO.File]::Open($partPath, [System.IO.FileMode]::CreateNew)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $usedNames = @{}
            foreach ($gp in $groupZips) {
                $entryName = $gp.DisplayName
                $baseName  = [System.IO.Path]::GetFileNameWithoutExtension($entryName)
                $ext       = [System.IO.Path]::GetExtension($entryName)
                if ([string]::IsNullOrEmpty($ext)) { $ext = '.zip' }
                $n = 1
                while ($usedNames.ContainsKey($entryName.ToLowerInvariant())) {
                    $n++
                    $entryName = "$baseName-$n$ext"
                }
                $usedNames[$entryName.ToLowerInvariant()] = $true
                $entry       = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::NoCompression)
                $entryStream = $entry.Open()
                try {
                    $src = [System.IO.File]::OpenRead($gp.ZipPath)
                    try { $src.CopyTo($entryStream) } finally { $src.Dispose() }
                } finally { $entryStream.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }

    if (Test-Path -LiteralPath $paths.ZipPath) { Remove-Item -LiteralPath $paths.ZipPath -Force }
    Move-Item -LiteralPath $partPath -Destination $paths.ZipPath -Force
    Save-ZipCacheManifest $paths.ManifestPath $fingerprint

    $zipSize = (Get-Item -LiteralPath $paths.ZipPath).Length
    Write-ServerLog "Mega-zip ($mode) built on disk ($zipSize bytes) -> $($paths.ZipPath)" -Level Ok
    return $paths
}

function Get-AllSendersZipCachePaths {
    $cacheDir = Get-ZipCacheDir
    @{
        ZipPath      = Join-Path $cacheDir "all-senders.zip"
        ManifestPath = Join-Path $cacheDir "all-senders.manifest.json"
        DisplayName  = "all-senders.zip"
    }
}

function Get-OrBuildAllSendersZip($files) {
    $fingerprint = Get-AllSendersZipFingerprint $files
    $hash = Get-ZipFingerprintHash $fingerprint
    $paths = Get-AllSendersZipCachePaths

    [System.Threading.Monitor]::Enter($script:AllSendersZipLock)
    try {
        if ($script:AllSendersZipCache.Hash -eq $hash -and
            $null -ne $script:AllSendersZipCache.ZipPath -and
            (Test-Path -LiteralPath $script:AllSendersZipCache.ZipPath)) {
            $cachedSize = (Get-Item -LiteralPath $script:AllSendersZipCache.ZipPath).Length
            Write-ServerLog "All-senders zip cache hit ($cachedSize bytes) -> $($script:AllSendersZipCache.ZipPath)" -Level Debug
            return @{
                ZipPath     = $script:AllSendersZipCache.ZipPath
                DisplayName = $script:AllSendersZipCache.DisplayName
            }
        }

        if (Test-ZipCacheValid $paths.ManifestPath $paths.ZipPath $fingerprint) {
            $diskSize = (Get-Item -LiteralPath $paths.ZipPath).Length
            Write-ServerLog "All-senders zip disk cache hit ($diskSize bytes) -> $($paths.ZipPath)" -Level Debug
            $script:AllSendersZipCache.Hash    = $hash
            $script:AllSendersZipCache.ZipPath = $paths.ZipPath
            $script:AllSendersZipCache.BuiltAt = Get-Date
            return @{
                ZipPath     = $paths.ZipPath
                DisplayName = $paths.DisplayName
            }
        }

        Write-ServerLog "All-senders zip cache miss — building mega zip on disk" -Level Info
        $grouped  = $files | Group-Object { Get-SenderIpFromFileName $_.Name } | Sort-Object Name
        $partPath = "$($paths.ZipPath).part"
        if (Test-Path -LiteralPath $partPath) { Remove-Item -LiteralPath $partPath -Force }

        $fs = [System.IO.File]::Open($partPath, [System.IO.FileMode]::CreateNew)
        try {
            $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                $usedNames = @{}
                foreach ($group in $grouped) {
                    $senderIp  = [string]$group.Name
                    $senderZip = Get-OrBuildSenderZip $senderIp @($group.Group)
                    $entryName = $senderZip.DisplayName
                    $baseName  = [System.IO.Path]::GetFileNameWithoutExtension($entryName)
                    $ext       = [System.IO.Path]::GetExtension($entryName)
                    if ([string]::IsNullOrEmpty($ext)) { $ext = ".zip" }
                    $n = 1
                    while ($usedNames.ContainsKey($entryName.ToLowerInvariant())) {
                        $n++
                        $entryName = "$baseName-$n$ext"
                    }
                    $usedNames[$entryName.ToLowerInvariant()] = $true

                    $entry       = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::NoCompression)
                    $entryStream = $entry.Open()
                    try {
                        $src = [System.IO.File]::OpenRead($senderZip.ZipPath)
                        try { $src.CopyTo($entryStream) } finally { $src.Dispose() }
                    } finally { $entryStream.Dispose() }
                }
            } finally { $zip.Dispose() }
        } finally { $fs.Dispose() }

        if (Test-Path -LiteralPath $paths.ZipPath) { Remove-Item -LiteralPath $paths.ZipPath -Force }
        Move-Item -LiteralPath $partPath -Destination $paths.ZipPath -Force
        Save-ZipCacheManifest $paths.ManifestPath $fingerprint

        $zipSize = (Get-Item -LiteralPath $paths.ZipPath).Length
        Write-ServerLog "All-senders zip built on disk ($zipSize bytes) -> $($paths.ZipPath)" -Level Ok

        $script:AllSendersZipCache.Hash    = $hash
        $script:AllSendersZipCache.ZipPath = $paths.ZipPath
        $script:AllSendersZipCache.BuiltAt = Get-Date
        return @{
            ZipPath     = $paths.ZipPath
            DisplayName = $paths.DisplayName
        }
    } finally {
        [System.Threading.Monitor]::Exit($script:AllSendersZipLock)
    }
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
    } catch [System.IO.IOException] {
        Write-ServerLog "Send-FileStreamResponse: client disconnected while sending '$downloadFileName' — $($_.Exception.Message)" -Level Warn
    } finally {
        $inStream.Dispose()
        try { $ctx.Response.OutputStream.Close() } catch {}
    }
}

function Get-ServerSettingsObject {
    return @{
        uploadFileRegex      = $script:ServerSettings.UploadFileRegex
        password             = $script:ServerSettings.Password
        uploadFolder         = $script:ServerSettings.UploadFolder
        maxUploadSize        = $script:ServerSettings.MaxUploadSize
        uploadIPWhitelist    = ($script:ServerSettings.UploadIPWhitelist -join ',')
        uploadWindowEnabled  = [bool]$script:ServerSettings.UploadWindowEnabled
        uploadWindowStart    = Get-UploadWindowPart $script:ServerSettings.UploadWindowStart
        uploadWindowEnd      = Get-UploadWindowPart $script:ServerSettings.UploadWindowEnd
    }
}

function Get-ServerSettingsJson {
    return (Get-ServerSettingsObject | ConvertTo-Json -Compress -Depth 6)
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
            $newFolder = (New-Item -ItemType Directory -Force -Path $folder).FullName
            if ($newFolder -ne $script:ServerSettings.UploadFolder) {
                $script:ServerSettings.UploadFolder = $newFolder
                Clear-UploadableFilesCache
                Write-ServerLog "Upload folder changed to $($script:ServerSettings.UploadFolder)" -Level Info
            }
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
    if ($null -ne $data.PSObject.Properties['uploadIPWhitelist']) {
        $raw = [string]$data.uploadIPWhitelist
        $ips = @($raw -split '\s*,\s*' | Where-Object { $_ -ne '' } | ForEach-Object { $_.Trim() })
        # Validate each entry is a plausible IP address
        foreach ($ip in $ips) {
            $parsed = $null
            if (-not [System.Net.IPAddress]::TryParse($ip, [ref]$parsed)) {
                $errorMsg.Value = "Invalid IP address in whitelist: '$ip'. Use plain IPv4 or IPv6 addresses separated by commas."
                return $false
            }
        }
        $script:ServerSettings.UploadIPWhitelist = $ips
        $countMsg = if ($ips.Count -eq 0) { 'disabled (all IPs allowed)' } else { "$($ips.Count) IP(s)" }
        Write-ServerLog "Upload IP whitelist updated — $countMsg" -Level Info
    }
    if ($null -ne $data.PSObject.Properties['uploadWindowEnabled']) {
        $script:ServerSettings.UploadWindowEnabled = [bool]$data.uploadWindowEnabled
    }
    if ($null -ne $data.PSObject.Properties['uploadWindowStart']) {
        $startDt = ConvertFrom-UploadWindowPart $data.uploadWindowStart ([ref]$errorMsg)
        if ($errorMsg.Value) { return $false }
        $script:ServerSettings.UploadWindowStart = $startDt
    }
    if ($null -ne $data.PSObject.Properties['uploadWindowEnd']) {
        $endDt = ConvertFrom-UploadWindowPart $data.uploadWindowEnd ([ref]$errorMsg)
        if ($errorMsg.Value) { return $false }
        $script:ServerSettings.UploadWindowEnd = $endDt
    }
    if ($script:ServerSettings.UploadWindowEnabled) {
        $ws = $script:ServerSettings.UploadWindowStart
        $we = $script:ServerSettings.UploadWindowEnd
        if ($null -eq $ws -and $null -eq $we) {
            $errorMsg.Value = "Upload time window is enabled but neither start nor end is set."
            return $false
        }
        if ($null -ne $ws -and $null -ne $we -and $we -le $ws) {
            $errorMsg.Value = "Upload window end must be after the start time."
            return $false
        }
        Write-ServerLog "Upload window: $(Format-UploadWindowDisplay $ws) → $(Format-UploadWindowDisplay $we)" -Level Info
    } else {
        Write-ServerLog "Upload time window disabled" -Level Info
    }
    Write-ServerLog "Settings applied — folder: $($script:ServerSettings.UploadFolder)" -Level Ok
    return $true
}

# ────────────────────────────────────────────────────────────────────────
# >> HTML Templates
# ────────────────────────────────────────────────────────────────────────

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

# ────────────────────────────────────────────────────────────────────────
# >> Upload Page
# ────────────────────────────────────────────────────────────────────────
function Get-UploadPage([string]$msg = "", [bool]$isError = $false, [bool]$ipBlocked = $false, [string]$clientIP = "") {
    $msgHtml = ""
    if ($msg) {
        $cls = if ($isError) { "err" } else { "ok" }
        $msgHtml = "<div class='msg $cls'>$([System.Net.WebUtility]::HtmlEncode($msg))</div>"
    }

    $windowState = Get-UploadWindowState
    $timeLocked = ($windowState -eq 'before' -or $windowState -eq 'after')
    $winStart = $script:ServerSettings.UploadWindowStart
    $winEnd = $script:ServerSettings.UploadWindowEnd
    $winStartMs = if ($null -ne $winStart) { ConvertTo-UnixTimeMs $winStart } else { 'null' }
    $winEndMs = if ($null -ne $winEnd) { ConvertTo-UnixTimeMs $winEnd } else { 'null' }
    $winStartDisplay = [System.Net.WebUtility]::HtmlEncode((Format-UploadWindowDisplay $winStart))
    $winEndDisplay = [System.Net.WebUtility]::HtmlEncode((Format-UploadWindowDisplay $winEnd))

    $timeWindowBannerHtml = ""
    if ($windowState -ne 'disabled') {
        $timeWindowBannerHtml = @"
        <div class="time-window-banner" id="timeWindowBanner">
          <div class="time-window-head">
            <span class="time-window-icon" id="timeWindowIcon">&#9200;</span>
            <div class="time-window-text" id="timeWindowText"></div>
          </div>
          <div class="time-window-countdown" id="timeWindowCountdown"></div>
        </div>
"@
    }

# ────────────────────────────────────────────────────────────────────────
# >> IP-blocked banner (shown instead of the normal message area)
# ────────────────────────────────────────────────────────────────────────
    $blockedBannerHtml = ""
    $blockedJs         = "false"
    if ($ipBlocked) {
        $safeIP = [System.Net.WebUtility]::HtmlEncode($clientIP)
        $blockedBannerHtml = @"
        <div class="ip-blocked-banner">
          <span class="ip-blocked-icon">&#128683;</span>
          <div>
            <strong>Upload not allowed</strong><br>
            Your IP address (<code>$safeIP</code>) is not on the upload whitelist.
            Contact the server administrator to be added.
          </div>
        </div>
"@
        $blockedJs = "true"
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
  /* ── IP-blocked banner ── */
  .ip-blocked-banner {
    display: flex; align-items: flex-start; gap: .9rem;
    margin-top: 1.2rem; padding: .9rem 1rem;
    background: rgba(255,95,95,.08); border: 1px solid rgba(255,95,95,.4);
    border-radius: var(--radius); font-size: .88rem; font-family: var(--mono);
    color: var(--danger); line-height: 1.55;
  }
  .ip-blocked-banner strong { display: block; margin-bottom: .15rem; }
  .ip-blocked-banner code {
    font-family: var(--mono); font-size: .84rem;
    background: rgba(255,95,95,.12); padding: .05rem .35rem; border-radius: 4px;
  }
  .ip-blocked-icon { font-size: 1.4rem; flex-shrink: 0; line-height: 1; margin-top: .05rem; }
  /* Blocked state: dim the whole drop zone and disable pointer events */
  .drop-zone.blocked {
    opacity: .35; pointer-events: none; cursor: not-allowed;
  }
  /* Blocked button override — keeps the grayed style even if JS tries to enable */
  #submitBtn.blocked {
    opacity: .35 !important; cursor: not-allowed !important; pointer-events: none;
  }
  .time-window-banner {
    margin-top: 1.2rem; padding: .95rem 1rem;
    background: rgba(0,221,255,.06); border: 1px solid rgba(0,221,255,.28);
    border-radius: var(--radius); font-family: var(--mono); font-size: .86rem;
    line-height: 1.55;
  }
  .time-window-banner.locked {
    background: rgba(255,95,95,.08); border-color: rgba(255,95,95,.4);
    color: var(--danger);
  }
  .time-window-banner.active-win {
    background: rgba(106,240,200,.08); border-color: rgba(106,240,200,.35);
  }
  .time-window-head { display: flex; align-items: flex-start; gap: .75rem; }
  .time-window-icon { font-size: 1.35rem; flex-shrink: 0; line-height: 1; }
  .time-window-text strong { display: block; margin-bottom: .2rem; color: var(--text); }
  .time-window-countdown {
    margin-top: .65rem; font-size: 1.05rem; font-weight: 700;
    color: var(--accent2); letter-spacing: .04em;
  }
  .time-window-banner.locked .time-window-countdown { color: var(--danger); }
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

      $blockedBannerHtml
      $timeWindowBannerHtml
      <form id="uploadForm" enctype="multipart/form-data">
        <div class="drop-zone$(if ($ipBlocked -or $timeLocked) { ' blocked' })" id="dropZone">
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
        <button type="submit" class="btn$(if ($ipBlocked -or $timeLocked) { ' blocked' })" id="submitBtn" disabled
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
const IP_BLOCKED = $blockedJs;
const TIME_WINDOW = {
  state: '$windowState',
  startMs: $winStartMs,
  endMs: $winEndMs,
  startLabel: '$winStartDisplay',
  endLabel: '$winEndDisplay'
};
const UPLOAD_LOCKED = IP_BLOCKED || TIME_WINDOW.state === 'before' || TIME_WINDOW.state === 'after';

function escHtml(s){return s.replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));}
function fmtSize(b){if(b<1024)return b+' B';if(b<1048576)return (b/1024).toFixed(1)+' KB';return (b/1048576).toFixed(1)+' MB';}

function pad2(n){ return (n < 10 ? '0' : '') + n; }
function formatCountdown(ms) {
  if (ms <= 0) return '0:00:00';
  var s = Math.floor(ms / 1000);
  var d = Math.floor(s / 86400); s -= d * 86400;
  var h = Math.floor(s / 3600); s -= h * 3600;
  var m = Math.floor(s / 60); s -= m * 60;
  var parts = [];
  if (d > 0) parts.push(d + 'd');
  parts.push(pad2(h) + ':' + pad2(m) + ':' + pad2(s));
  return parts.join(' ');
}

function refreshTimeWindowUI() {
  var banner = document.getElementById('timeWindowBanner');
  if (!banner || TIME_WINDOW.state === 'disabled') return;
  var textEl = document.getElementById('timeWindowText');
  var cdEl = document.getElementById('timeWindowCountdown');
  var now = Date.now();
  var state = TIME_WINDOW.state;
  if (TIME_WINDOW.startMs != null && now < TIME_WINDOW.startMs) state = 'before';
  else if (TIME_WINDOW.endMs != null && now >= TIME_WINDOW.endMs) state = 'after';
  else state = 'active';

  banner.classList.remove('locked', 'active-win');
  var targetMs = null;
  var cdPrefix = '';

  if (state === 'before') {
    banner.classList.add('locked');
    targetMs = TIME_WINDOW.startMs;
    textEl.innerHTML = '<strong>Uploads not open yet</strong>Uploads open at <code>' + escHtml(TIME_WINDOW.startLabel) + '</code>.';
    cdPrefix = 'Opens in ';
  } else if (state === 'after') {
    banner.classList.add('locked');
    textEl.innerHTML = '<strong>Upload concluded</strong>Upload concluded at time: <code>' + escHtml(TIME_WINDOW.endLabel) + '</code>.';
    cdEl.textContent = '';
    lockUploadControls(true);
    return;
  } else {
    banner.classList.add('active-win');
    if (TIME_WINDOW.endMs != null) {
      targetMs = TIME_WINDOW.endMs;
      textEl.innerHTML = '<strong>Uploads open</strong>Upload window closes at <code>' + escHtml(TIME_WINDOW.endLabel) + '</code>.';
      cdPrefix = 'Closes in ';
    } else {
      textEl.innerHTML = '<strong>Uploads open</strong>No scheduled close time.';
      cdEl.textContent = '';
      return;
    }
  }

  if (targetMs == null) { cdEl.textContent = ''; return; }
  var remaining = targetMs - now;
  cdEl.textContent = cdPrefix + formatCountdown(remaining);
  if (state === 'before') lockUploadControls(true);
  else lockUploadControls(false);
  if (remaining <= 0 && state === 'before') location.reload();
  else if (remaining <= 0 && state === 'active' && TIME_WINDOW.endMs != null) location.reload();
}

function lockUploadControls(locked) {
  var dz = document.getElementById('dropZone');
  var btn = document.getElementById('submitBtn');
  var browse = document.getElementById('browseBtn');
  if (locked || IP_BLOCKED) {
    if (dz) dz.classList.add('blocked');
    if (btn) { btn.disabled = true; btn.classList.add('blocked'); btn.style.opacity = '.4'; btn.style.cursor = 'not-allowed'; }
    if (browse) browse.style.pointerEvents = 'none';
  } else if (!IP_BLOCKED) {
    if (dz) dz.classList.remove('blocked');
    if (btn) btn.classList.remove('blocked');
    if (browse) browse.style.pointerEvents = '';
    if (allFiles.length) {
      btn.disabled = false; btn.style.opacity = '1'; btn.style.cursor = 'pointer';
    }
  }
}

if (TIME_WINDOW.state !== 'disabled') {
  refreshTimeWindowUI();
  setInterval(refreshTimeWindowUI, 1000);
}

// Drag & drop
var dz = document.getElementById('dropZone');
dz.addEventListener('dragover', function(e){ e.preventDefault(); if (!UPLOAD_LOCKED) dz.classList.add('dragover'); });
dz.addEventListener('dragleave', function(){ dz.classList.remove('dragover'); });
dz.addEventListener('drop', function(e){
  e.preventDefault(); dz.classList.remove('dragover');
  if (!UPLOAD_LOCKED && e.dataTransfer.files.length) { updatePreview(e.dataTransfer.files); }
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
  if (!UPLOAD_LOCKED) {
    btn.disabled = false; btn.style.opacity = '1'; btn.style.cursor = 'pointer';
  }
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
  if (!allFiles.length || UPLOAD_LOCKED) return;

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

# ────────────────────────────────────────────────────────────────────────
# >> Login Page
# ────────────────────────────────────────────────────────────────────────
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

# ────────────────────────────────────────────────────────────────────────
# >> Download Page
# ────────────────────────────────────────────────────────────────────────
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
    $grouped = @($files | Group-Object { Get-SenderIpFromFileName $_.Name } | Sort-Object Name)
    $senderIpsJson = ConvertTo-Json -InputObject @($grouped | ForEach-Object { [string]$_.Name }) -Compress
    if (-not $senderIpsJson) { $senderIpsJson = "[]" }

    # Group files by display filename (stripped of IP suffix)
    $groupedByName = @($files | Group-Object { Get-DisplayName $_.Name } | Sort-Object Name)
    $filenameGroupsJson = ConvertTo-Json -InputObject @($groupedByName | ForEach-Object { [string]$_.Name }) -Compress
    if (-not $filenameGroupsJson) { $filenameGroupsJson = "[]" }

    # Helper: render a single group card
    function Render-GroupCard([string]$groupId, [string]$icon, [string]$label, [string]$encListJson,
                              [string]$dlGroupAttr, [string]$zipAttrName, [string]$zipAttrValue,
                              [string]$rowsHtml, [int]$count) {
        $safeZipAttr = [System.Net.WebUtility]::HtmlEncode($zipAttrValue)
        @"
<div class="ip-group">
  <div class="ip-header-row">
    <button class="ip-header" onclick="toggleGroup('$groupId')" aria-expanded="true">
      <span class="ip-icon">$icon</span>
      <span class="ip-addr">$label</span>
      <span class="ip-count badge">$count file$(if($count -ne 1){'s'})</span>
      <span class="ip-chevron" id="chev-$groupId">&#9650;</span>
    </button>
    <button class="dl-all-btn" onclick="downloadAll(this)" data-group="$groupId" title="Download all files in this group">&#9196; Download All</button>
    <button class="zip-all-btn" onclick="zipAll(this)" $zipAttrName="$safeZipAttr" title="Zip and download all files in this group">&#128230; Zip &amp; Download</button>
  </div>
  <div class="ip-body" id="$groupId" data-files="[$encListJson]">
    <table>
      <colgroup><col class="col-file"><col class="col-size"><col class="col-date"><col class="col-action"></colgroup>
      <thead><tr><th>File</th><th>Size</th><th>Uploaded</th><th></th></tr></thead>
      <tbody>$rowsHtml</tbody>
    </table>
  </div>
</div>
"@
    }

    function Render-FileRows($fileList) {
        ($fileList | ForEach-Object {
            $dispName = [System.Net.WebUtility]::HtmlEncode((Get-DisplayName $_.Name))
            $rawName  = [System.Net.WebUtility]::HtmlEncode($_.Name)
            $enc      = [Uri]::EscapeDataString($_.Name)
            $size     = if ($_.Length -lt 1024) { "$($_.Length) B" } elseif ($_.Length -lt 1048576) { "{0:N1} KB" -f ($_.Length/1KB) } elseif ($_.Length -lt 1073741824) { "{0:N1} MB" -f ($_.Length/1MB) } else { "{0:N1} GB" -f ($_.Length/1GB) }
            $date     = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
            "<tr><td><a href='/download/file?name=$enc' class='dl-link dl-href' title='$rawName'>&#128196;&nbsp;$dispName</a></td><td>$size</td><td>$date</td><td><button class='copy-url-btn' data-name='$enc' onclick=`"copyUrl(this)`" title='Copy direct download link'>&#128279;<span class='url-label'> Copy URL</span></button></td></tr>"
        }) -join "`n"
    }

    $groupHtmlByIp = if ($files.Count -eq 0) {
        "<div class='empty-state'><div class='empty-state-icon'>&#128228;</div>No files uploaded yet.<br>Head to the upload page to send some files.</div>"
    } else {
        ($grouped | ForEach-Object {
            $ip         = [System.Net.WebUtility]::HtmlEncode($_.Name)
            $groupId    = "grp-ip-" + ($ip -replace '[^a-zA-Z0-9]', '_')
            $count      = $_.Group.Count
            $encListJson = ($_.Group | ForEach-Object { '&quot;' + [Uri]::EscapeDataString($_.Name) + '&quot;' }) -join ','
            $rowsHtml   = Render-FileRows $_.Group
            Render-GroupCard $groupId "&#127760;" $ip $encListJson "" "data-ip" $_.Name $rowsHtml $count
        }) -join "`n"
    }

    $groupHtmlByName = if ($files.Count -eq 0) {
        ""
    } else {
        ($groupedByName | ForEach-Object {
            $fname      = [System.Net.WebUtility]::HtmlEncode($_.Name)
            $groupId    = "grp-fn-" + (($_.Name) -replace '[^a-zA-Z0-9]', '_')
            $count      = $_.Group.Count
            $encListJson = ($_.Group | ForEach-Object { '&quot;' + [Uri]::EscapeDataString($_.Name) + '&quot;' }) -join ','
            $rowsHtml   = Render-FileRows $_.Group
            Render-GroupCard $groupId "&#128196;" $fname $encListJson "" "data-filename" $_.Name $rowsHtml $count
        }) -join "`n"
    }

    return @"
<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Download Files</title>
<style>$CSS_SHARED
  /* ── Download-specific ── */
  .dl-content { max-width: 1200px; margin: 0 auto; }
  .stat-pill {
    display: inline-flex; align-items: center; gap: .3rem;
    border-radius: 999px; padding: .25rem .75rem;
    font-family: var(--mono); font-size: .78rem; color: var(--muted);
    border: 1px solid var(--border); background: rgba(255,255,255,.04);
  }
  .stat-pill strong { color: var(--text); }

  /* ── View tabs ── */
  .view-tabs {
    display: flex; gap: .5rem; margin-bottom: 1.2rem; flex-wrap: wrap;
  }
  .view-tab {
    padding: .45rem 1.1rem; border-radius: 999px;
    font-family: var(--mono); font-size: .8rem; font-weight: 500;
    color: var(--muted); background: transparent;
    border: 1.5px solid var(--border); cursor: pointer;
    transition: color .15s, border-color .15s, background .15s;
    white-space: nowrap;
  }
  .view-tab:hover { color: var(--accent2); border-color: var(--accent2); background: rgba(0,221,255,.07); }
  .view-tab.active { color: #0d0d0f; background: var(--accent2); border-color: var(--accent2); }
  .view-panel { display: none; }
  .view-panel.active { display: block; }

  /* ── Group card ── */
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
  .ip-icon { font-size: 1rem; flex-shrink: 0; }
  .ip-addr { flex: 1; font-family: var(--mono); color: var(--accent2); font-size: .88rem;
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .ip-chevron { font-size: .65rem; color: var(--muted); transition: transform .2s; flex-shrink: 0; }
  .ip-chevron.collapsed { transform: rotate(180deg); }
  .ip-body.collapsed { display: none; }

  /* ── Table ── */
  table { width: 100%; border-collapse: collapse; table-layout: fixed; }
  col.col-file   { width: auto; }
  col.col-size   { width: 6rem; }
  col.col-date   { width: 9.5rem; }
  col.col-action { width: 8.5rem; }
  th {
    text-align: left; font-size: .72rem; letter-spacing: .08em; text-transform: uppercase;
    color: var(--muted); padding: .55rem 1.2rem; border-bottom: 1px solid var(--border);
    background: rgba(0,0,0,.2); overflow: hidden;
  }
  td {
    padding: .7rem 1.2rem; border-bottom: 1px solid rgba(255,255,255,.04);
    font-size: .9rem; vertical-align: middle; overflow: hidden;
  }
  /* filename cell: clamp to 3 lines then ellipsis */
  td:nth-child(1) {
    overflow: hidden;
  }
  .dl-link {
    color: var(--accent2); text-decoration: none; font-family: var(--mono); font-size: .85rem;
    display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical;
    overflow: hidden; word-break: break-all;
  }
  .dl-link:hover { color: var(--accent); }
  /* size + date columns */
  td:nth-child(2), td:nth-child(3) {
    color: var(--muted); font-family: var(--mono); font-size: .8rem; white-space: nowrap;
  }
  /* action column */
  td:nth-child(4) { white-space: nowrap; padding-right: 1rem; }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: rgba(255,255,255,.02); }

  /* ── Buttons ── */
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
  .dl-all-btn.busy { opacity: .45; cursor: default; pointer-events: none; }
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
  .zip-all-btn.busy { opacity: .45; cursor: default; pointer-events: none; }

  /* ── Download Everything bar (always full label, centered) ── */
  .dl-everything-bar {
    display: flex; justify-content: center; align-items: center;
    padding: .9rem 0 1.4rem;
  }
  .dl-everything-btn {
    display: inline-flex; align-items: center; gap: .5rem;
    padding: .65rem 1.5rem;
    font-family: var(--mono); font-size: .8rem; font-weight: 500;
    color: #0d0d0f; background: #22c55e;
    border: none; border-radius: var(--radius); cursor: pointer;
    transition: background .15s, opacity .15s, box-shadow .15s;
    white-space: nowrap; box-shadow: 0 0 0 0 rgba(34,197,94,0);
  }
  .dl-everything-btn:hover { background: #4ade80; box-shadow: 0 0 16px rgba(34,197,94,.35); }
  .dl-everything-btn:disabled { opacity: .45; cursor: default; pointer-events: none; }

  /* ── Zip progress panel ── */
  .zip-progress-bar {
    display: none; margin: 0 0 1rem;
    border: 1px solid var(--border); border-radius: var(--radius);
    background: var(--surface); overflow: hidden;
  }
  .zip-progress-bar.visible { display: block; }
  .zip-progress-header {
    padding: .6rem 1rem; background: var(--surface2);
    border-bottom: 1px solid var(--border);
    font-family: var(--mono); font-size: .75rem; color: var(--muted);
    display: flex; align-items: center; gap: .6rem;
  }
  .zip-progress-header strong { color: var(--accent2); }
  .zip-progress-track { height: 3px; background: var(--border); position: relative; overflow: hidden; }
  .zip-progress-fill { height: 100%; background: #22c55e; transition: width .3s ease; width: 0%; }
  .zip-progress-rows { padding: .5rem 1rem .6rem; }
  .zip-progress-row {
    display: flex; align-items: center; gap: .6rem;
    padding: .28rem 0; font-family: var(--mono); font-size: .76rem;
    border-bottom: 1px solid rgba(255,255,255,.03);
  }
  .zip-progress-row:last-child { border-bottom: none; }
  .zip-progress-ip { color: var(--accent2); flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .zip-progress-status { flex-shrink: 0; font-size: .72rem; }
  .zip-progress-status.waiting { color: var(--muted); }
  .zip-progress-status.zipping { color: #f0a500; }
  .zip-progress-status.done    { color: #22c55e; }
  .zip-progress-status.error   { color: var(--danger); }

  /* ── Empty state ── */
  .empty-state {
    text-align: center; color: var(--muted); padding: 5rem 2rem;
    font-family: var(--mono); font-size: .9rem;
    border: 1px dashed var(--border); border-radius: var(--radius);
  }
  .empty-state-icon { font-size: 2.5rem; margin-bottom: 1rem; }

  /* ── Mobile ── */
  @media (max-width: 700px) {
    /* Section action buttons: always show full label, shrink padding */
    .dl-all-btn, .zip-all-btn { padding: .5rem .65rem; font-size: .7rem; gap: .25rem; }
    /* Download Everything always shows full text — no collapse */
    .dl-everything-btn { padding: .6rem 1.2rem; font-size: .78rem; }
    /* Table: hide date column, shrink size column */
    col.col-date { display: none; }
    th:nth-child(3), td:nth-child(3) { display: none; }
    col.col-size   { width: 5rem; }
    col.col-action { width: 5.5rem; }
    th { padding: .5rem .75rem; }
    td { padding: .6rem .75rem; }
    td:nth-child(4) { padding-right: .6rem; }
    /* Copy URL button: icon only on very small screens */
    .copy-url-btn { padding: .3rem .5rem; }
    .copy-url-btn .url-label { display: none; }
    /* IP header row: tighter */
    .ip-header { padding: .75rem .85rem; gap: .5rem; }
    .ip-header .ip-count { display: none; }
  }
</style></head>
<body>
<div class="topbar">
  <span class="topbar-title">&#128229; Downloads $(if (-not [string]::IsNullOrEmpty($script:ServerSettings.Password)) { "<span class='badge'>Secure</span>" } else { "<span class='badge'>Public</span>" })</span>
  <span class="topbar-meta">
    <span class="stat-pill">&#128196; <strong>$($files.Count)</strong> file$(if($files.Count -ne 1){'s'})</span>
    <span class="stat-pill">&#127760; <strong>$($grouped.Count)</strong> sender$(if($grouped.Count -ne 1){'s'})</span>
    <span class="stat-pill">&#128196; <strong>$($groupedByName.Count)</strong> filename$(if($groupedByName.Count -ne 1){'s'})</span>
  </span>
  <nav class="topbar-nav">
    <a href="/">&larr; Upload</a>
    $(if (-not [string]::IsNullOrEmpty($script:ServerSettings.Password)) { "<a href='/download/logout' class='danger'>&#128274; Lock &amp; Exit</a>" })
  </nav>
</div>

<div class="page">
  <div class="dl-content">
    $(if ($files.Count -gt 0) {
      "<div class='dl-everything-bar'><button type='button' id='downloadEverythingBtn' class='dl-everything-btn' onclick='downloadEverything(this)'>&#128230; Download Everything</button></div>" +
      "<div class='zip-progress-bar' id='zipProgressBar'>" +
        "<div class='zip-progress-header'><span>&#9889; Packaging</span> <strong id='zipProgressLabel'>0 / ?</strong></div>" +
        "<div class='zip-progress-track'><div class='zip-progress-fill' id='zipProgressFill'></div></div>" +
        "<div class='zip-progress-rows' id='zipProgressRows'></div>" +
      "</div>"
    })
    $(if ($files.Count -gt 0) {
      "<div class='view-tabs'>" +
      "<button class='view-tab active' onclick=`"switchView('ip', this)`">&#127760; Group by Sender IP</button>" +
      "<button class='view-tab' onclick=`"switchView('fn', this)`">&#128196; Group by Filename</button>" +
      "</div>"
    })
    <div class="view-panel active" id="view-ip">$groupHtmlByIp</div>
    <div class="view-panel" id="view-fn">$groupHtmlByName</div>
  </div>
</div>

<script>
var DL_PASSWORD = $(if (-not [string]::IsNullOrEmpty($script:ServerSettings.Password)) { "'" + ($script:ServerSettings.Password -replace "'", "\\x27" -replace '\\', '\\\\') + "'" } else { 'null' });
var SENDER_IPS = $senderIpsJson;
var FILENAME_GROUPS = $filenameGroupsJson;
</script>
<script>
if (DL_PASSWORD) {
  document.querySelectorAll('a.dl-href').forEach(function(a) {
    a.href = a.getAttribute('href') + '&password=' + encodeURIComponent(DL_PASSWORD);
  });
}
function switchView(which, btn) {
  document.querySelectorAll('.view-tab').forEach(function(t) { t.classList.remove('active'); });
  btn.classList.add('active');
  document.querySelectorAll('.view-panel').forEach(function(p) { p.classList.remove('active'); });
  document.getElementById('view-' + which).classList.add('active');
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
function labelHtml(wide, short) {
  return wide; // no longer used for wide/short switching; kept for compat
}
function downloadAll(btn) {
  var groupId = btn.getAttribute('data-group');
  var body = document.getElementById(groupId);
  var files = JSON.parse(body.getAttribute('data-files'));
  var pw = (typeof DL_PASSWORD !== 'undefined' && DL_PASSWORD) ? '&password=' + encodeURIComponent(DL_PASSWORD) : '';
  btn.classList.add('busy');
  btn.textContent = '\u23f3 Downloading\u2026';
  var i = 0;
  function next() {
    if (i >= files.length) {
      setTimeout(function() {
        btn.classList.remove('busy');
        btn.textContent = '\u23ec Download All';
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
  var filename = btn.getAttribute('data-filename');
  var pw = (typeof DL_PASSWORD !== 'undefined' && DL_PASSWORD) ? '&password=' + encodeURIComponent(DL_PASSWORD) : '';
  var url;
  if (filename != null) {
    url = '/download/zip?filename=' + encodeURIComponent(filename) + pw;
  } else {
    url = '/download/zip?ip=' + encodeURIComponent(ip) + pw;
  }
  btn.classList.add('busy');
  btn.textContent = '\u23f3 Zipping\u2026';
  fetch(url)
    .then(function(res) {
      if (!res.ok) throw new Error('Server returned ' + res.status);
      var cd = res.headers.get('Content-Disposition') || '';
      var match = cd.match(/filename\*?=(?:UTF-8'')?([^;]+)/i);
      var fname = match ? decodeURIComponent(match[1].replace(/"/g, '')) : 'files.zip';
      return res.blob().then(function(blob) { return { blob: blob, filename: fname }; });
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
      btn.textContent = '\u{1F4E6} Zip & Download';
    });
}
async function downloadEverything(btn) {
  // Determine which view is active
  var activePanel = document.querySelector('.view-panel.active');
  var mode = activePanel && activePanel.id === 'view-fn' ? 'fn' : 'ip';
  var groups = mode === 'fn' ? FILENAME_GROUPS : SENDER_IPS;
  var icon   = mode === 'fn' ? '\uD83D\uDCC4' : '\uD83C\uDF10';

  if (!groups.length) return;

  var pw = (typeof DL_PASSWORD !== 'undefined' && DL_PASSWORD) ? '&password=' + encodeURIComponent(DL_PASSWORD) : '';
  var totalGroups = groups.length;

  btn.disabled = true;
  document.querySelectorAll('.dl-all-btn, .zip-all-btn').forEach(function(b) { b.classList.add('busy'); });

  // Build progress rows for just this view's groups
  var progressBar   = document.getElementById('zipProgressBar');
  var progressLabel = document.getElementById('zipProgressLabel');
  var progressFill  = document.getElementById('zipProgressFill');
  var progressRows  = document.getElementById('zipProgressRows');

  progressRows.innerHTML = groups.map(function(name) {
    var safeId = (mode + '_' + name).replace(/[^a-zA-Z0-9]/g, '_');
    var enc = encodeURIComponent(name).replace(/'/g, '%27');
    return "<div class='zip-progress-row'>" +
      "<span class='zip-progress-ip'>" + icon + " " + name.replace(/</g,'&lt;').replace(/>/g,'&gt;') + "</span>" +
      "<span class='zip-progress-status waiting' id='zprs-" + safeId + "'>\u25CB Waiting</span>" +
      "</div>";
  }).join('');

  progressLabel.textContent = '0 / ' + totalGroups;
  progressFill.style.width = '0%';
  progressBar.classList.add('visible');

  function setStatus(name, cls, html) {
    var safeId = (mode + '_' + name).replace(/[^a-zA-Z0-9]/g, '_');
    var el = document.getElementById('zprs-' + safeId);
    if (!el) return;
    el.className = 'zip-progress-status ' + cls;
    el.innerHTML = html;
  }

  var done = 0;

  // Step 1: zip each group on the server (builds + caches each group zip)
  for (var i = 0; i < groups.length; i++) {
    var name = groups[i];
    setStatus(name, 'zipping', '\u2699 Zipping\u2026');
    var zipUrl = mode === 'fn'
      ? '/download/zip?filename=' + encodeURIComponent(name) + pw
      : '/download/zip?ip='       + encodeURIComponent(name) + pw;
    try {
      var res = await fetch(zipUrl);
      if (!res.ok) throw new Error('HTTP ' + res.status);
      await res.blob(); // consume body so connection is released
      setStatus(name, 'done', '\u2713 Done');
    } catch (err) {
      setStatus(name, 'error', '\u2717 Failed');
    }
    done++;
    progressLabel.textContent = done + ' / ' + totalGroups;
    progressFill.style.width = Math.round(done / totalGroups * 88) + '%';
  }

  // Step 2 + 3: ask server to zip all the group zips into one mega zip, then download it
  try {
    progressLabel.textContent = 'Packaging\u2026';
    var megaUrl = '/download/zip-mega?mode=' + mode + pw;
    var megaRes = await fetch(megaUrl);
    if (!megaRes.ok) throw new Error('Server returned ' + megaRes.status);
    var cd = megaRes.headers.get('Content-Disposition') || '';
    var match = cd.match(/filename\*?=(?:UTF-8'')?([^;]+)/i);
    var filename = match ? decodeURIComponent(match[1].replace(/"/g, '')) : 'everything.zip';
    var blob = await megaRes.blob();
    progressFill.style.width = '100%';
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
  } catch (err) {
    alert('Download Everything failed: ' + err.message);
  } finally {
    setTimeout(function() {
      btn.disabled = false;
      document.querySelectorAll('.dl-all-btn, .zip-all-btn').forEach(function(b) { b.classList.remove('busy'); });
      progressBar.classList.remove('visible');
      progressFill.style.width = '0%';
      progressRows.innerHTML = '';
      progressLabel.textContent = '0 / ?';
    }, 1400);
  }
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

# ────────────────────────────────────────────────────────────────────────
# >> Admin Page
# ────────────────────────────────────────────────────────────────────────
function Get-AdminPage([string]$msg = "", [bool]$isError = $false) {
    $regexVal   = [System.Net.WebUtility]::HtmlEncode($script:ServerSettings.UploadFileRegex)
    $folderVal  = [System.Net.WebUtility]::HtmlEncode($script:ServerSettings.UploadFolder)
    $passwordVal = [System.Net.WebUtility]::HtmlEncode($script:ServerSettings.Password)
    $maxMbVal = if ($script:ServerSettings.MaxUploadSize -gt 0) {
        [math]::Round($script:ServerSettings.MaxUploadSize / 1048576, 2).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    } else { "0" }
    $ipWhitelistVal = [System.Net.WebUtility]::HtmlEncode(($script:ServerSettings.UploadIPWhitelist -join ', '))
    $regexStatusBadge    = if ([string]::IsNullOrWhiteSpace($script:ServerSettings.UploadFileRegex)) { "Disabled" } else { "Active" }
    $passwordStatusBadge = if ([string]::IsNullOrEmpty($script:ServerSettings.Password)) { "Unsecured" } else { "Protected" }
    $folderStatusBadge   = "Configured"
    $maxSizeStatusBadge  = if ($script:ServerSettings.MaxUploadSize -gt 0) { (Format-ByteSize $script:ServerSettings.MaxUploadSize) } else { "Unlimited" }
    $ipWLCount           = $script:ServerSettings.UploadIPWhitelist.Count
    $ipWLStatusBadge     = if ($ipWLCount -eq 0) { "Open" } else { "$ipWLCount IP(s)" }
    $ipWLStatusWarn      = if ($ipWLCount -eq 0) { " warn" } else { "" }
    $winEnabled          = [bool]$script:ServerSettings.UploadWindowEnabled
    $winStartPart        = Get-UploadWindowPart $script:ServerSettings.UploadWindowStart
    $winEndPart          = Get-UploadWindowPart $script:ServerSettings.UploadWindowEnd
    $winStartY  = if ($null -ne $winStartPart) { [string]$winStartPart.year } else { '' }
    $winStartMo = if ($null -ne $winStartPart) { [string]$winStartPart.month } else { '' }
    $winStartD  = if ($null -ne $winStartPart) { [string]$winStartPart.day } else { '' }
    $winStartH  = if ($null -ne $winStartPart) { [string]$winStartPart.hour } else { '' }
    $winStartMi = if ($null -ne $winStartPart) { [string]$winStartPart.minute } else { '' }
    $winEndY  = if ($null -ne $winEndPart) { [string]$winEndPart.year } else { '' }
    $winEndMo = if ($null -ne $winEndPart) { [string]$winEndPart.month } else { '' }
    $winEndD  = if ($null -ne $winEndPart) { [string]$winEndPart.day } else { '' }
    $winEndH  = if ($null -ne $winEndPart) { [string]$winEndPart.hour } else { '' }
    $winEndMi = if ($null -ne $winEndPart) { [string]$winEndPart.minute } else { '' }
    $winStatusBadge = if (-not $winEnabled) { "Off" }
        elseif ($null -ne $script:ServerSettings.UploadWindowStart -and $null -ne $script:ServerSettings.UploadWindowEnd) {
            "$(Format-UploadWindowDisplay $script:ServerSettings.UploadWindowStart) – $(Format-UploadWindowDisplay $script:ServerSettings.UploadWindowEnd)"
        }
        elseif ($null -ne $script:ServerSettings.UploadWindowStart) { "From $(Format-UploadWindowDisplay $script:ServerSettings.UploadWindowStart)" }
        else { "Until $(Format-UploadWindowDisplay $script:ServerSettings.UploadWindowEnd)" }
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
  /* ── IP tag list ── */
  .ip-tag-input-wrap {
    display: flex; flex-wrap: wrap; gap: .4rem; align-items: center;
    background: var(--bg); border: 1px solid var(--border);
    border-radius: var(--radius); padding: .5rem .7rem;
    cursor: text; min-height: 2.6rem;
    transition: border-color .2s;
  }
  .ip-tag-input-wrap:focus-within { border-color: var(--accent); }
  .ip-tag {
    display: inline-flex; align-items: center; gap: .3rem;
    background: rgba(0,221,255,.12); border: 1px solid rgba(0,221,255,.3);
    border-radius: 999px; padding: .18rem .55rem;
    font-family: var(--mono); font-size: .78rem; color: var(--accent2);
    white-space: nowrap;
  }
  .ip-tag-remove {
    background: none; border: none; cursor: pointer; padding: 0;
    color: var(--muted); font-size: .85rem; line-height: 1;
    transition: color .15s;
  }
  .ip-tag-remove:hover { color: var(--danger); }
  .ip-tag-text-input {
    flex: 1; min-width: 9rem; background: transparent; border: none;
    outline: none; color: var(--text); font-family: var(--mono); font-size: .9rem;
    padding: .1rem .2rem;
  }
  .dt-grid {
    display: grid; grid-template-columns: repeat(5, minmax(0, 1fr));
    gap: .5rem; margin-top: .35rem;
  }
  .dt-grid label { font-size: .7rem; margin: 0; color: var(--muted); }
  .dt-grid input {
    width: 100%; margin-top: .2rem; padding: .45rem .5rem;
    font-family: var(--mono); font-size: .85rem;
  }
  .dt-section { margin-top: 1.1rem; }
  .dt-section-title {
    font-family: var(--mono); font-size: .78rem; font-weight: 700;
    letter-spacing: .06em; text-transform: uppercase; color: var(--accent2);
    margin-bottom: .35rem;
  }
  .window-enable-row {
    display: flex; align-items: center; gap: 1rem;
    margin-top: 1.1rem; padding: .85rem 1rem;
    background: rgba(0,221,255,.04); border: 1px solid rgba(0,221,255,.18);
    border-radius: var(--radius);
  }
  .window-enable-row input[type=checkbox] { display: none; }
  .toggle-track {
    position: relative; flex-shrink: 0;
    width: 2.8rem; height: 1.5rem;
    background: var(--border); border-radius: 999px;
    cursor: pointer; transition: background .2s;
    border: 1.5px solid rgba(255,255,255,.08);
  }
  .toggle-track::after {
    content: ''; position: absolute;
    top: 50%; left: .2rem; transform: translateY(-50%);
    width: 1rem; height: 1rem; border-radius: 50%;
    background: var(--muted); transition: left .2s, background .2s;
  }
  #uploadWindowEnabled:checked ~ .window-enable-row .toggle-track,
  .toggle-track.on {
    background: var(--accent2); border-color: var(--accent2);
  }
  #uploadWindowEnabled:checked ~ .window-enable-row .toggle-track::after,
  .toggle-track.on::after {
    left: calc(100% - 1.2rem); background: #0d0d0f;
  }
  .window-enable-label {
    font-family: var(--mono); font-size: .9rem; font-weight: 700;
    color: var(--text); cursor: pointer; user-select: none;
    flex: 1;
  }
  .window-enable-label .sublabel {
    display: block; font-size: .75rem; font-weight: 400; color: var(--muted); margin-top: .15rem;
  }
  .window-enable-state {
    font-family: var(--mono); font-size: .72rem; font-weight: 700;
    letter-spacing: .06em; text-transform: uppercase;
    padding: .2rem .6rem; border-radius: 999px; flex-shrink: 0;
    background: rgba(160,160,184,.1); color: var(--muted);
    border: 1px solid rgba(160,160,184,.2); transition: all .2s;
  }
  .window-enable-state.active {
    background: rgba(0,221,255,.12); color: var(--accent2);
    border-color: rgba(0,221,255,.3);
  }
  @media (max-width: 640px) {
    .dt-grid { grid-template-columns: repeat(3, minmax(0, 1fr)); }
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

    <div class="setting-group">
      <button class="setting-header" type="button" onclick="toggleSetting('set-ipwl')" aria-expanded="true">
        <span class="setting-icon">&#128273;</span>
        <span class="setting-title">Upload IP whitelist</span>
        <span class="setting-status$ipWLStatusWarn" id="status-ipwl">$ipWLStatusBadge</span>
        <span class="setting-chevron" id="chev-set-ipwl">&#9650;</span>
      </button>
      <div class="setting-body" id="set-ipwl">
        <p class="setting-help">
          When set, only the listed IP addresses may upload files. All other clients receive a&nbsp;<code>403 Forbidden</code>.
          Leave empty to allow uploads from any IP. Supports both IPv4 (e.g. <code>192.168.1.50</code>) and IPv6.
          Type an address and press <strong>Enter</strong>, <strong>Tab</strong>, <strong>Space</strong>, or <strong>comma</strong> to add it. Click the &times; on a tag to remove it.
        </p>
        <label>Allowed uploader IPs</label>
        <div class="ip-tag-input-wrap" id="ipTagWrap" onclick="document.getElementById('ipRawInput').focus()">
          <input type="text" id="ipRawInput" class="ip-tag-text-input"
                 placeholder="e.g. 192.168.1.10" autocomplete="off" spellcheck="false"
                 aria-label="Add IP address">
        </div>
        <!-- Hidden field holding the comma-joined value sent to the server -->
        <input type="hidden" id="uploadIPWhitelist" name="uploadIPWhitelist" value="$ipWhitelistVal">
      </div>
    </div>

    <div class="setting-group">
      <button class="setting-header" type="button" onclick="toggleSetting('set-timewin')" aria-expanded="true">
        <span class="setting-icon">&#9200;</span>
        <span class="setting-title">Upload time window</span>
        <span class="setting-status$(if (-not $winEnabled) { ' warn' })" id="status-timewin">$([System.Net.WebUtility]::HtmlEncode($winStatusBadge))</span>
        <span class="setting-chevron" id="chev-set-timewin">&#9650;</span>
      </button>
      <div class="setting-body" id="set-timewin">
        <p class="setting-help">
          Restrict when the public upload page accepts files. Before the start time, uploads are locked and a countdown is shown.
          During the window, a countdown to close is shown. After the end time, uploads are locked and visitors see when uploads concluded.
          Times use this machine's local timezone.
        </p>
        <input type="checkbox" id="uploadWindowEnabled"$(if ($winEnabled) { ' checked' })>
        <div class="window-enable-row" id="windowEnableRow" onclick="toggleWindowEnabled()">
          <span class="toggle-track" id="toggleTrack"></span>
          <span class="window-enable-label">
            Enable upload time window
            <span class="sublabel">Lock or schedule when the upload page accepts files</span>
          </span>
          <span class="window-enable-state" id="windowEnableState">Off</span>
        </div>
        <script>
        (function(){
          var cb = document.getElementById('uploadWindowEnabled');
          var track = document.getElementById('toggleTrack');
          var state = document.getElementById('windowEnableState');
          function sync() {
            if (cb.checked) { track.classList.add('on'); state.textContent = 'On'; state.classList.add('active'); }
            else            { track.classList.remove('on'); state.textContent = 'Off'; state.classList.remove('active'); }
          }
          window.toggleWindowEnabled = function() { cb.checked = !cb.checked; sync(); };
          sync();
        })();
        </script>
        <div class="dt-section">
          <div class="dt-section-title">Window opens</div>
          <div class="dt-grid">
            <div><label for="winStartYear">Year</label><input type="number" id="winStartYear" min="1970" max="2100" placeholder="2026" value="$winStartY"></div>
            <div><label for="winStartMonth">Month</label><input type="number" id="winStartMonth" min="1" max="12" placeholder="6" value="$winStartMo"></div>
            <div><label for="winStartDay">Day</label><input type="number" id="winStartDay" min="1" max="31" placeholder="4" value="$winStartD"></div>
            <div><label for="winStartHour">Hour</label><input type="number" id="winStartHour" min="0" max="23" placeholder="9" value="$winStartH"></div>
            <div><label for="winStartMinute">Minute</label><input type="number" id="winStartMinute" min="0" max="59" placeholder="0" value="$winStartMi"></div>
          </div>
        </div>
        <div class="dt-section">
          <div class="dt-section-title">Window closes</div>
          <div class="dt-grid">
            <div><label for="winEndYear">Year</label><input type="number" id="winEndYear" min="1970" max="2100" placeholder="2026" value="$winEndY"></div>
            <div><label for="winEndMonth">Month</label><input type="number" id="winEndMonth" min="1" max="12" placeholder="6" value="$winEndMo"></div>
            <div><label for="winEndDay">Day</label><input type="number" id="winEndDay" min="1" max="31" placeholder="4" value="$winEndD"></div>
            <div><label for="winEndHour">Hour</label><input type="number" id="winEndHour" min="0" max="23" placeholder="17" value="$winEndH"></div>
            <div><label for="winEndMinute">Minute</label><input type="number" id="winEndMinute" min="0" max="59" placeholder="0" value="$winEndMi"></div>
          </div>
        </div>
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
  var ipEl = document.getElementById('status-ipwl');
  if (ipEl) {
    var wl = (s.uploadIPWhitelist || '').split(',').map(function(x){return x.trim();}).filter(Boolean);
    if (wl.length === 0) { ipEl.textContent = 'Open'; ipEl.classList.add('warn'); }
    else { ipEl.textContent = wl.length + ' IP(s)'; ipEl.classList.remove('warn'); }
  }
  var twEl = document.getElementById('status-timewin');
  if (twEl) {
    if (!s.uploadWindowEnabled) { twEl.textContent = 'Off'; twEl.classList.add('warn'); }
    else {
      twEl.classList.remove('warn');
      var a = formatWindowPart(s.uploadWindowStart);
      var b = formatWindowPart(s.uploadWindowEnd);
      if (a && b) twEl.textContent = a + ' – ' + b;
      else if (a) twEl.textContent = 'From ' + a;
      else if (b) twEl.textContent = 'Until ' + b;
      else twEl.textContent = 'Enabled (no times)';
    }
  }
}

function formatWindowPart(p) {
  if (!p || p.year == null) return '';
  return padDt(p.year) + '-' + padDt(p.month) + '-' + padDt(p.day) + ' ' + padDt(p.hour) + ':' + padDt(p.minute);
}
function padDt(n) { n = parseInt(n, 10); return (n < 10 ? '0' : '') + n; }

function readWindowPart(prefix) {
  var y = document.getElementById(prefix + 'Year').value.trim();
  if (!y) return null;
  return {
    year: parseInt(y, 10),
    month: parseInt(document.getElementById(prefix + 'Month').value, 10),
    day: parseInt(document.getElementById(prefix + 'Day').value, 10),
    hour: parseInt(document.getElementById(prefix + 'Hour').value, 10) || 0,
    minute: parseInt(document.getElementById(prefix + 'Minute').value, 10) || 0
  };
}

function fillWindowFields(prefix, part) {
  var ids = ['Year','Month','Day','Hour','Minute'];
  var keys = ['year','month','day','hour','minute'];
  for (var i = 0; i < ids.length; i++) {
    var el = document.getElementById(prefix + ids[i]);
    if (el) el.value = (part && part[keys[i]] != null) ? String(part[keys[i]]) : '';
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

// ── IP tag widget ─────────────────────────────────────────────────────────────
(function() {
  var wrap      = document.getElementById('ipTagWrap');
  var rawInput  = document.getElementById('ipRawInput');
  var hidden    = document.getElementById('uploadIPWhitelist');

  function getTags() {
    return hidden.value.split(',').map(function(s){ return s.trim(); }).filter(Boolean);
  }

  function renderTags() {
    // Remove all existing tag elements (leave the text input)
    Array.from(wrap.querySelectorAll('.ip-tag')).forEach(function(el){ el.remove(); });
    getTags().forEach(function(ip) {
      var tag = document.createElement('span');
      tag.className = 'ip-tag';
      tag.textContent = ip;
      var btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'ip-tag-remove';
      btn.innerHTML = '&times;';
      btn.title = 'Remove ' + ip;
      btn.addEventListener('click', function(e) {
        e.stopPropagation();
        var tags = getTags().filter(function(t){ return t !== ip; });
        hidden.value = tags.join(',');
        renderTags();
      });
      tag.appendChild(btn);
      wrap.insertBefore(tag, rawInput);
    });
  }

  function addIP(raw) {
    var ip = raw.trim().replace(/,+$/, '');
    if (!ip) return;
    // Basic sanity: must look like an IP
    if (!/^[\da-fA-F:.]+$/.test(ip)) { rawInput.style.color = 'var(--danger)'; return; }
    rawInput.style.color = '';
    var tags = getTags();
    if (tags.indexOf(ip) === -1) { tags.push(ip); hidden.value = tags.join(','); }
    rawInput.value = '';
    renderTags();
  }

  rawInput.addEventListener('keydown', function(e) {
    if (e.key === 'Enter' || e.key === 'Tab' || e.key === ',' || e.key === ' ') {
      if (rawInput.value.trim()) { e.preventDefault(); addIP(rawInput.value); }
    } else if (e.key === 'Backspace' && rawInput.value === '') {
      var tags = getTags();
      if (tags.length > 0) { tags.pop(); hidden.value = tags.join(','); renderTags(); }
    }
  });
  rawInput.addEventListener('blur', function() { if (rawInput.value.trim()) addIP(rawInput.value); });
  rawInput.addEventListener('paste', function(e) {
    e.preventDefault();
    var text = (e.clipboardData || window.clipboardData).getData('text');
    text.split(/[\s,]+/).forEach(function(part){ if (part.trim()) addIP(part); });
  });

  // Seed from the hidden field (populated server-side)
  renderTags();
})();

document.getElementById('applyBtn').addEventListener('click', async function() {
  const btn = document.getElementById('applyBtn');
  btn.disabled = true;
  try {
    const payload = {
      uploadFileRegex: document.getElementById('uploadFileRegex').value,
      uploadFolder: document.getElementById('uploadFolder').value,
      password: document.getElementById('downloadPassword').value,
      maxUploadSize: mbToBytes(document.getElementById('maxUploadSizeMb').value),
      uploadIPWhitelist: document.getElementById('uploadIPWhitelist').value,
      uploadWindowEnabled: document.getElementById('uploadWindowEnabled').checked,
      uploadWindowStart: readWindowPart('winStart'),
      uploadWindowEnd: readWindowPart('winEnd')
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
      document.getElementById('uploadIPWhitelist').value = data.settings.uploadIPWhitelist || '';
      document.getElementById('uploadWindowEnabled').checked = !!data.settings.uploadWindowEnabled;
      fillWindowFields('winStart', typeof data.settings.uploadWindowStart === 'string' ? JSON.parse(data.settings.uploadWindowStart) : data.settings.uploadWindowStart);
      fillWindowFields('winEnd',   typeof data.settings.uploadWindowEnd   === 'string' ? JSON.parse(data.settings.uploadWindowEnd)   : data.settings.uploadWindowEnd);
      // Re-render the tag widget from the server-confirmed value
      var wrap = document.getElementById('ipTagWrap');
      Array.from(wrap.querySelectorAll('.ip-tag')).forEach(function(el){ el.remove(); });
      var hidden = document.getElementById('uploadIPWhitelist');
      var rawInput = document.getElementById('ipRawInput');
      (hidden.value.split(',').map(function(s){return s.trim();}).filter(Boolean)).forEach(function(ip) {
        var tag = document.createElement('span');
        tag.className = 'ip-tag';
        tag.textContent = ip;
        var btn = document.createElement('button');
        btn.type = 'button'; btn.className = 'ip-tag-remove'; btn.innerHTML = '&times;';
        btn.addEventListener('click', function(e) {
          e.stopPropagation();
          var tags = hidden.value.split(',').map(function(s){return s.trim();}).filter(function(t){return t!==ip;});
          hidden.value = tags.join(',');
          wrap.querySelectorAll('.ip-tag').forEach(function(el){ el.remove(); });
        });
        tag.appendChild(btn);
        wrap.insertBefore(tag, rawInput);
      });
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

# ────────────────────────────────────────────────────────────────────────
# >> Multipart Parser
# ────────────────────────────────────────────────────────────────────────
#
# Performance design
# ──────────────────
# • Pending bytes are kept in a Queue[byte] (O(1) enqueue + dequeue) instead of
#   a List[byte] whose RemoveAt(0) was O(n) on every byte.
# • The raw InputStream is wrapped in a BufferedStream (256 KB) so .NET handles
#   large kernel-to-user-space copy batches instead of per-read syscalls.
# • Read-ParserBlock drains the pending queue with Array.Copy rather than a
#   byte-by-byte loop.
# • Read-ParserByte refills a small internal byte[] instead of calling
#   ReadByte() (a virtual dispatch + boxing) for every header character.
# • The boundary search uses Boyer-Moore-Horspool (BMH): bad-character skip
#   table built once per upload, typical skip = boundary-length per mismatch,
#   versus the old O(n*m) brute-force scan.
# • Read-MultipartLine reuses a single pre-allocated byte[] line buffer and
#   only allocates a string at return time.
# • Stream-FileUntilDelimiter uses a 256 KB I/O buffer (was 64 KB).

function Save-UploadedFile([System.Net.HttpListenerRequest]$req, [string]$senderIP = "unknown") {
    if (-not (Test-UploadWindowOpen)) {
        $winState = Get-UploadWindowState
        if ($winState -eq 'before') {
            $openAt = Format-UploadWindowDisplay $script:ServerSettings.UploadWindowStart
            return @{ Error = "Uploads are not open yet. They open at $openAt." }
        }
        $endedAt = Format-UploadWindowDisplay $script:ServerSettings.UploadWindowEnd
        return @{ Error = "Upload concluded at time: $endedAt" }
    }

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

    [byte[]]$delimiterBytes = [System.Text.Encoding]::ASCII.GetBytes("`r`n--$boundary")
    $boundaryLine = "--$boundary"
    $savedNames   = [System.Collections.Generic.List[string]]::new()
    $bodyCounter  = @{ Value = 0L }

# ────────────────────────────────────────────────────────────────────────
# >> Pending queue: O(1) Enqueue / Dequeue (replaces List[byte].RemoveAt(0))
# ────────────────────────────────────────────────────────────────────────
    $pending = [System.Collections.Generic.Queue[byte]]::new(512)

# ────────────────────────────────────────────────────────────────────────
# >> Wrap the raw InputStream in a BufferedStream for large-block reads
# ────────────────────────────────────────────────────────────────────────
    $bufferedInput = [System.IO.BufferedStream]::new($req.InputStream, 262144)  # 256 KB buffer

# ────────────────────────────────────────────────────────────────────────
# >> Single-byte refill buffer (avoids ReadByte() boxing overhead)
# ────────────────────────────────────────────────────────────────────────
    [byte[]]$oneByteBuf = New-Object byte[] 1

    function Add-BodyBytes([long]$count) {
        if ($count -le 0) { return }
        $bodyCounter.Value += $count
        if ($limit -gt 0 -and $bodyCounter.Value -gt $limit) {
            throw [System.IO.IOException]::new("Upload exceeds maximum size ($(Format-ByteSize $limit)).")
        }
    }

    function Read-ParserByte {
        if ($pending.Count -gt 0) { return [int]($pending.Dequeue()) }
        $n = $bufferedInput.Read($oneByteBuf, 0, 1)
        if ($n -le 0) { return -1 }
        Add-BodyBytes 1
        return [int]$oneByteBuf[0]
    }

    function Read-ParserBlock([byte[]]$buffer, [int]$offset, [int]$count) {
        $copied = 0
        # Drain the pending queue using Array.Copy for the bulk portion
        $pCount = $pending.Count
        if ($pCount -gt 0) {
            $take = [Math]::Min($pCount, $count)
            # Queue.CopyTo copies in FIFO order into a temp array, then bulk-copy
            [byte[]]$tmp = New-Object byte[] $take
            $pending.CopyTo($tmp, 0)
            [Array]::Copy($tmp, 0, $buffer, $offset, $take)
            for ($i = 0; $i -lt $take; $i++) { [void]$pending.Dequeue() }
            $copied = $take
        }
        if ($copied -lt $count) {
            $read = $bufferedInput.Read($buffer, $offset + $copied, $count - $copied)
            if ($read -gt 0) {
                Add-BodyBytes $read
                $copied += $read
            }
        }
        return $copied
    }

    # Reusable line buffer: avoids per-call List[byte] allocation
    [byte[]]$lineBuf    = New-Object byte[] 65536
    [int]   $lineBufLen = 0

    function Read-MultipartLine {
        $lineBufLen = 0
        while ($true) {
            $b = Read-ParserByte
            if ($b -lt 0) {
                if ($lineBufLen -eq 0) { return $null }
                break
            }
            if ($lineBufLen -ge $lineBuf.Length) {
                throw [System.IO.IOException]::new("Multipart header line is too large.")
            }
            $lineBuf[$lineBufLen++] = [byte]$b
            if ($b -eq 10) { break }
        }
        return [System.Text.Encoding]::ASCII.GetString($lineBuf, 0, $lineBufLen)
    }

    function Read-MultipartHeaders {
        $headers = [System.Text.StringBuilder]::new(512)
        while ($true) {
            $line = Read-MultipartLine
            if ($null -eq $line) { return $null }
            if ($line -eq "`r`n" -or $line -eq "`n") { return $headers.ToString() }
            if ($headers.Length + $line.Length -gt 65536) {
                throw [System.IO.IOException]::new("Multipart headers are too large.")
            }
            [void]$headers.Append($line)
        }
    }

# ────────────────────────────────────────────────────────────────────────
# >> Boyer-Moore-Horspool bad-character skip table
# ────────────────────────────────────────────────────────────────────────
    # Typical skip per mismatch ≈ boundary length (~30-70 bytes) vs old O(1) advance.
    [int[]]$bmhSkip = New-Object int[] 256
    $patLen = $delimiterBytes.Length
    for ($i = 0; $i -lt 256; $i++) { $bmhSkip[$i] = $patLen }
    for ($i = 0; $i -lt ($patLen - 1); $i++) { $bmhSkip[$delimiterBytes[$i]] = $patLen - 1 - $i }

    function Find-IndexOfBytesBMH([byte[]]$buffer, [int]$length, [int]$startIndex = 0) {
        # Returns index of $delimiterBytes in $buffer[0..$length-1], or -1.
        if ($length -lt $patLen) { return -1 }
        $last = $length - $patLen
        $i    = $startIndex
        while ($i -le $last) {
            # Compare last byte first (BMH heuristic)
            $j = $patLen - 1
            while ($j -ge 0 -and $buffer[$i + $j] -eq $delimiterBytes[$j]) { $j-- }
            if ($j -lt 0) { return $i }
            $skip = $bmhSkip[$buffer[$i + $patLen - 1]]
            if ($skip -lt 1) { $skip = 1 }
            $i += $skip
        }
        return -1
    }

    $ioBufSize = 262144  # 256 KB I/O buffer (was 64 KB)

    function Stream-FileUntilDelimiter([System.IO.Stream]$destStream) {
        [byte[]]$buffer = New-Object byte[] ($ioBufSize + $patLen)
        $carry     = 0
        $fileBytes = 0L
        while ($true) {
            $read = Read-ParserBlock $buffer $carry $ioBufSize
            if ($read -le 0) {
                throw [System.IO.IOException]::new("Multipart delimiter was not found.")
            }
            $windowLen = $carry + $read
            $idx = Find-IndexOfBytesBMH $buffer $windowLen 0
            if ($idx -ge 0) {
                if ($idx -gt 0 -and $null -ne $destStream) {
                    $destStream.Write($buffer, 0, $idx)
                    $fileBytes += $idx
                }
                if ($limit -gt 0 -and $fileBytes -gt $limit) {
                    throw [System.IO.IOException]::new("File exceeds maximum upload size ($(Format-ByteSize $limit)).")
                }
                $after = $idx + $patLen
                for ($i = $after; $i -lt $windowLen; $i++) {
                    $pending.Enqueue($buffer[$i])
                }
                return $fileBytes
            }

            $keep     = [Math]::Min($patLen - 1, $windowLen)
            $writeLen = $windowLen - $keep
            if ($writeLen -gt 0 -and $null -ne $destStream) {
                $destStream.Write($buffer, 0, $writeLen)
                $fileBytes += $writeLen
            }
            if ($limit -gt 0 -and $fileBytes -gt $limit) {
                throw [System.IO.IOException]::new("File exceeds maximum upload size ($(Format-ByteSize $limit)).")
            }
            if ($keep -gt 0) {
                [Array]::Copy($buffer, $writeLen, $buffer, 0, $keep)
            }
            $carry = $keep
        }
    }

    try {
        $firstLine = Read-MultipartLine
        if ($null -eq $firstLine -or $firstLine.TrimEnd([char[]]"`r`n") -ne $boundaryLine) {
            return @{ Names = $savedNames; Error = $null }
        }

        while ($true) {
            $hdrStr = Read-MultipartHeaders
            if ($null -eq $hdrStr) { break }

            $origName = $null
            if ($hdrStr -match 'filename="([^"]*)"') { $origName = $Matches[1] }

            if ([string]::IsNullOrEmpty($origName)) {
                [void](Stream-FileUntilDelimiter $null)
            } else {
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
                    # Use FileOptions.SequentialScan to hint the OS for large sequential writes
                    $destStream = [System.IO.FileStream]::new(
                        $partDest,
                        [System.IO.FileMode]::CreateNew,
                        [System.IO.FileAccess]::Write,
                        [System.IO.FileShare]::None,
                        65536,
                        [System.IO.FileOptions]::SequentialScan
                    )
                    try {
                        $dataLen = Stream-FileUntilDelimiter $destStream
                    } finally { $destStream.Dispose() }
                    Move-Item -LiteralPath $partDest -Destination $destPath -Force
                    $savedName = [System.IO.Path]::GetFileName($destPath)
                    $savedNames.Add($savedName)
                    Clear-UploadableFilesCache
                    Write-ServerLog "Save-UploadedFile: saved '$savedName' ($dataLen bytes) -> $destPath" -Level Ok
                } catch {
                    if (Test-Path -LiteralPath $partDest) {
                        Remove-Item -LiteralPath $partDest -Force -ErrorAction SilentlyContinue
                    }
                    Write-ServerLog "Save-UploadedFile: failed writing '$origName' — $($_.Exception.Message)" -Level Error
                    throw
                }
            }

            $suffix = Read-MultipartLine
            if ($null -eq $suffix -or $suffix.StartsWith("--")) { break }
        }
    } catch [System.IO.IOException] {
        return @{ Names = @(); Error = $_.Exception.Message }
    } finally {
        $bufferedInput.Dispose()
    }

    Write-ServerLog "Save-UploadedFile: done — $($savedNames.Count) file(s) saved" -Level Ok
    return @{ Names = $savedNames; Error = $null }
}

# ────────────────────────────────────────────────────────────────────────
# >> HTTP Server
# ────────────────────────────────────────────────────────────────────────
function Add-ServerFirewallRule {
    try {
        $existing = Get-NetFirewallRule -DisplayName $script:FirewallRuleName -ErrorAction SilentlyContinue
        if ($existing) {
            Write-ServerLog "Firewall: rule already present ($script:FirewallRuleName)" -Level Debug
            return
        }
        New-NetFirewallRule -DisplayName $script:FirewallRuleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port | Out-Null
        $script:FirewallRuleCreated = $true
        Write-ServerLog "Firewall: added TCP inbound rule for port $Port" -Level Info
    } catch {
        Write-ServerLog "Firewall: could not create TCP port rule — $($_.Exception.Message)" -Level Warn
    }
}

function Send-BytesResponse(
    [System.Net.HttpListenerContext]$ctx,
    [byte[]]$bytes,
    [string]$contentType,
    [string]$downloadFileName
) {
    Write-ServerLog "Send-BytesResponse: '$downloadFileName' ($($bytes.Length) bytes, $contentType)" -Level Info
    $encName = [Uri]::EscapeDataString($downloadFileName)
    $ctx.Response.ContentType = $contentType
    $ctx.Response.AddHeader("Content-Disposition", "attachment; filename*=UTF-8''$encName")
    $ctx.Response.ContentLength64 = $bytes.Length
    try {
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } catch [System.IO.IOException] {
        Write-ServerLog "Send-BytesResponse: client disconnected while sending '$downloadFileName' — $($_.Exception.Message)" -Level Warn
    } finally {
        try { $ctx.Response.OutputStream.Close() } catch {}
    }
}

function Remove-ServerFirewallRule {
    if (-not $script:FirewallRuleCreated) { return }
    try {
        Remove-NetFirewallRule -DisplayName $script:FirewallRuleName -ErrorAction SilentlyContinue
        $script:FirewallRuleCreated = $false
        Write-ServerLog "Firewall: removed rule $script:FirewallRuleName" -Level Info
    } catch {
        Write-ServerLog "Firewall: could not remove rule $script:FirewallRuleName — $($_.Exception.Message)" -Level Warn
    }
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://*:$Port/")

Add-ServerFirewallRule
$script:FirewallExitEvent = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Remove-ServerFirewallRule } -ErrorAction SilentlyContinue

try {
    $listener.Start()
    Write-ServerLog "HttpListener started on port $Port" -Level Ok
} catch {
    Write-ServerLog "Cannot start listener on port $Port — $($_.Exception.Message)" -Level Error
    Remove-ServerFirewallRule
    exit 1
}

$privateIP = (Get-NetIPConfiguration | Where-Object {$_.IPv4DefaultGateway -ne $null -and $_.NetAdapter.Status -ne "Disconnected"}).IPv4Address.IPAddress
$publicIP = "No Internet"
try {
  $publicIP  = (Invoke-WebRequest ifconfig.me/ip -UseBasicParsing).Content.Trim()
} catch {
  $publicIP = "No Internet"
}



# ────────────────────────────────────────────────────────────────────────
# >> Check whether port is reachable from the internet
# ────────────────────────────────────────────────────────────────────────
$portOpen = $false
try {
    $probe    = Invoke-WebRequest "https://portchecker.io/api/me/${port}" -UseBasicParsing -TimeoutSec 10
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
Write-Host "  Upload Folder : $($script:ServerSettings.UploadFolder)" -ForegroundColor DarkGreen
Write-Host "  Admin Page    : http://127.0.0.1:$Port/admin  (localhost only)" -ForegroundColor DarkCyan
if (-not [string]::IsNullOrWhiteSpace($script:ServerSettings.UploadFileRegex)) {
  Write-Host "  Upload Regex  : $($script:ServerSettings.UploadFileRegex)" -ForegroundColor DarkCyan
}
if ($script:ServerSettings.MaxUploadSize -gt 0) {
  Write-Host "  Max Upload    : $(Format-ByteSize $script:ServerSettings.MaxUploadSize)" -ForegroundColor DarkCyan
} else {
  Write-Host "  Max Upload    : Unlimited" -ForegroundColor DarkCyan
}
if ($script:ServerSettings.UploadWindowEnabled) {
  $ws = Format-UploadWindowDisplay $script:ServerSettings.UploadWindowStart
  $we = Format-UploadWindowDisplay $script:ServerSettings.UploadWindowEnd
  Write-Host "  Upload Window : $(if ($ws) { $ws } else { '(no start)' }) → $(if ($we) { $we } else { '(no end)' })" -ForegroundColor DarkCyan
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

function Handle-HttpContext([System.Net.HttpListenerContext]$ctx) {
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
# ────────────────────────────────────────────────────────────────────────
# >> GET /
# ────────────────────────────────────────────────────────────────────────
        if ($path -eq "" -or $path -eq "/") {
            $ok = $req.QueryString["ok"]
            $err = $req.QueryString["err"]
            $detail = $req.QueryString["msg"]
            $msg = if ($detail) { [Uri]::UnescapeDataString($detail) }
                   elseif ($err) { "Upload failed for one or more files." }
                   elseif ($ok -and $ok -ne "1") { "Uploaded: $([Uri]::UnescapeDataString($ok))" }
                   elseif ($ok) { "Files uploaded successfully!" } else { "" }
            $isErr = [bool]$err
            $visitorIP = $req.RemoteEndPoint.Address.ToString()
            $blocked = -not (Test-UploadIPAllowed $visitorIP)
            Send-Response $ctx (Get-UploadPage -msg $msg -isError $isErr -ipBlocked $blocked -clientIP $visitorIP)
        }

# ────────────────────────────────────────────────────────────────────────
# >> POST /upload
# ────────────────────────────────────────────────────────────────────────
        elseif ($path -eq "/upload" -and $method -eq "POST") {
            $uploaderIP = $req.RemoteEndPoint.Address.ToString()
            Write-ServerLog "POST /upload (form) from $uploaderIP" -Level Info
            if (-not (Test-UploadWindowOpen)) {
                $winMsg = if ((Get-UploadWindowState) -eq 'before') {
                    "Uploads are not open yet. They open at $(Format-UploadWindowDisplay $script:ServerSettings.UploadWindowStart)."
                } else {
                    "Upload concluded at time: $(Format-UploadWindowDisplay $script:ServerSettings.UploadWindowEnd)"
                }
                Send-Response $ctx (Get-UploadPage -msg $winMsg -isError $true -ipBlocked $false -clientIP $uploaderIP) -status 403
            } elseif (-not (Test-UploadIPAllowed $uploaderIP)) {
                Write-ServerLog "POST /upload blocked — IP $uploaderIP not in whitelist" -Level Warn
                Send-Response $ctx (Get-UploadPage -msg "" -isError $false -ipBlocked $true -clientIP $uploaderIP) -status 403
            } else {
            $uploadResult = Save-UploadedFile $req $uploaderIP
            if ($uploadResult.Error) {
                Send-Response $ctx (Get-UploadPage -msg $uploadResult.Error -isError $true -ipBlocked $false -clientIP $uploaderIP) -status 400
            } elseif ($uploadResult.Names -and $uploadResult.Names.Count -gt 0) {
                $enc = [Uri]::EscapeDataString(($uploadResult.Names -join ", "))
                Send-Redirect $ctx "/?ok=$enc"
            } else {
                Send-Response $ctx (Get-UploadPage -msg "Upload failed — no file received." -isError $true -ipBlocked $false -clientIP $uploaderIP) -status 400
            }
            }
        }

# ────────────────────────────────────────────────────────────────────────
# >> POST /upload-chunk (single file per XHR, used by progress uploader)
# ────────────────────────────────────────────────────────────────────────
        elseif ($path -eq "/upload-chunk" -and $method -eq "POST") {
            $uploaderIP = $req.RemoteEndPoint.Address.ToString()
            Write-ServerLog "POST /upload-chunk from $uploaderIP" -Level Info
            if (-not (Test-UploadWindowOpen)) {
                $winMsg = if ((Get-UploadWindowState) -eq 'before') {
                    "Uploads are not open yet. They open at $(Format-UploadWindowDisplay $script:ServerSettings.UploadWindowStart)."
                } else {
                    "Upload concluded at time: $(Format-UploadWindowDisplay $script:ServerSettings.UploadWindowEnd)"
                }
                Write-ServerLog "POST /upload-chunk blocked — outside upload window" -Level Warn
                Send-Response $ctx $winMsg -status 403 -contentType "text/plain; charset=utf-8"
            } elseif (-not (Test-UploadIPAllowed $uploaderIP)) {
                Write-ServerLog "POST /upload-chunk blocked — IP $uploaderIP not in whitelist" -Level Warn
                Send-Response $ctx "Upload not allowed: your IP address is not whitelisted." -status 403 -contentType "text/plain; charset=utf-8"
            } else {
            $uploadResult = Save-UploadedFile $req $uploaderIP
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
        }

# ────────────────────────────────────────────────────────────────────────
# >> GET /admin (localhost only)
# ────────────────────────────────────────────────────────────────────────
        elseif ($path -eq "/admin") {
            if (-not (Test-IsLocalRequest $req)) {
                Write-ServerLog "GET /admin denied — not localhost ($($req.RemoteEndPoint.Address))" -Level Warn
                Send-Response $ctx "<h2 style='font-family:sans-serif;color:#888'>403 — Admin is only available from localhost</h2>" -status 403
            } else {
                Write-ServerLog "GET /admin (localhost)" -Level Debug
                Send-Response $ctx (Get-AdminPage)
            }
        }

# ────────────────────────────────────────────────────────────────────────
# >> GET /admin/settings (localhost only)
# ────────────────────────────────────────────────────────────────────────
        elseif ($path -eq "/admin/settings" -and $method -eq "GET") {
            if (-not (Test-IsLocalRequest $req)) {
                Send-Response $ctx '{"ok":false,"error":"Forbidden"}' -status 403 -contentType "application/json; charset=utf-8"
            } else {
                Send-Response $ctx (Get-ServerSettingsJson) -contentType "application/json; charset=utf-8"
            }
        }

# ────────────────────────────────────────────────────────────────────────
# >> POST /admin/settings (localhost only)
# ────────────────────────────────────────────────────────────────────────
        elseif ($path -eq "/admin/settings" -and $method -eq "POST") {
            if (-not (Test-IsLocalRequest $req)) {
                Send-Response $ctx '{"ok":false,"error":"Forbidden"}' -status 403 -contentType "application/json; charset=utf-8"
            } else {
                $reader = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
                $body   = $reader.ReadToEnd()
                $setErr = $null
                if (Set-ServerSettingsFromJson $body ([ref]$setErr)) {
                    $s = Get-ServerSettingsObject
                    $winStartJson = if ($null -ne $s.uploadWindowStart) { $s.uploadWindowStart | ConvertTo-Json -Compress } else { 'null' }
                    $winEndJson   = if ($null -ne $s.uploadWindowEnd)   { $s.uploadWindowEnd   | ConvertTo-Json -Compress } else { 'null' }
                    $innerJson = (@{
                        uploadFileRegex     = $s.uploadFileRegex
                        password            = $s.password
                        uploadFolder        = $s.uploadFolder
                        maxUploadSize       = $s.maxUploadSize
                        uploadIPWhitelist   = $s.uploadIPWhitelist
                        uploadWindowEnabled = $s.uploadWindowEnabled
                    } | ConvertTo-Json -Compress -Depth 2)
                    $innerJson = $innerJson.TrimEnd('}') + ',' +
                        '"uploadWindowStart":' + $winStartJson + ',' +
                        '"uploadWindowEnd":' + $winEndJson + '}'
                    $payload = '{"ok":true,"settings":' + $innerJson + '}'
                    Send-Response $ctx $payload -contentType "application/json; charset=utf-8"
                } else {
                    $payload = (@{ ok = $false; error = $setErr } | ConvertTo-Json -Compress -Depth 2)
                    Send-Response $ctx $payload -status 400 -contentType "application/json; charset=utf-8"
                }
            }
        }

# ────────────────────────────────────────────────────────────────────────
# >> GET /download
# ────────────────────────────────────────────────────────────────────────
        elseif ($path -eq "/download") {
            $token = Get-CookieToken $req
            if ([string]::IsNullOrEmpty($script:ServerSettings.Password) -or (Test-Session $token)) {
                Send-Response $ctx (Get-DownloadPage)
            } else {
                Send-Response $ctx (Get-LoginPage)
            }
        }

# ────────────────────────────────────────────────────────────────────────
# >> POST /download/login
# ────────────────────────────────────────────────────────────────────────
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
                    $ctx.Response.AppendHeader("Set-Cookie", "ds=$token; $(Get-SessionCookieAttributes $req)")
                    Send-Redirect $ctx "/download"
                } else {
                    Write-ServerLog "Download login failed from $($req.RemoteEndPoint.Address)" -Level Warn
                    Send-Response $ctx (Get-LoginPage -failed $true)
                }
            }
        }

# ────────────────────────────────────────────────────────────────────────
# >> GET /download/logout
# ────────────────────────────────────────────────────────────────────────
        elseif ($path -eq "/download/logout") {
            $token = Get-CookieToken $req
            if ($token) {
                $dummy = [datetime]::MinValue
                $Sessions.TryRemove($token, [ref]$dummy) | Out-Null
            }
            $ctx.Response.AppendHeader("Set-Cookie", "ds=; Expires=Thu, 01 Jan 1970 00:00:00 GMT; $(Get-SessionCookieAttributes $req)")
            Send-Redirect $ctx "/download"
        }

# ────────────────────────────────────────────────────────────────────────
# >> GET /download/file?name=...
# ────────────────────────────────────────────────────────────────────────
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

# ────────────────────────────────────────────────────────────────────────
# >> GET /download/zip-all
# ────────────────────────────────────────────────────────────────────────
        elseif ($path -eq "/download/zip-all") {
            $token     = Get-CookieToken $req
            $quickpass = $req.QueryString["password"]
            $authorized = [string]::IsNullOrEmpty($script:ServerSettings.Password) -or (Test-Session $token) -or ($quickpass -eq $script:ServerSettings.Password)
            if (-not $authorized) {
                Send-Redirect $ctx "/download"
            } else {
                $allFiles = @(Get-UploadableFiles)
                if ($allFiles.Count -eq 0) {
                    Send-Response $ctx "<h2>404 — No files found</h2>" -status 404
                } else {
                    $megaZip = Get-OrBuildAllSendersZip $allFiles
                    Send-FileStreamResponse $ctx $megaZip.ZipPath 'application/zip' $megaZip.DisplayName
                }
            }
        }

# ────────────────────────────────────────────────────────────────────────
# >> GET /download/zip?ip=...  OR  /download/zip?filename=...
# ────────────────────────────────────────────────────────────────────────
        elseif ($path -eq "/download/zip") {
            $token     = Get-CookieToken $req
            $quickpass = $req.QueryString["password"]
            $authorized = [string]::IsNullOrEmpty($script:ServerSettings.Password) -or (Test-Session $token) -or ($quickpass -eq $script:ServerSettings.Password)
            if (-not $authorized) {
                Send-Redirect $ctx "/download"
            } else {
                $senderIp    = $req.QueryString["ip"]
                $filenameKey = $req.QueryString["filename"]
                if (-not [string]::IsNullOrEmpty($filenameKey)) {
                    # Group by display filename
                    $zipFiles = @(Get-UploadableFiles | Where-Object { (Get-DisplayNameFromFileName $_.Name) -eq $filenameKey })
                    if ($zipFiles.Count -eq 0) {
                        Send-Response $ctx "<h2>404 — No files found for that filename group</h2>" -status 404
                    } else {
                        $paths = Get-OrBuildFilenameZip $filenameKey $zipFiles
                        Send-FileStreamResponse $ctx $paths.ZipPath 'application/zip' $paths.DisplayName
                    }
                } else {
                    # Group by sender IP (original behaviour)
                    $zipFiles = @(Get-UploadableFiles | Where-Object { (Get-SenderIpFromFileName $_.Name) -eq $senderIp })
                    if ($zipFiles.Count -eq 0) {
                        Send-Response $ctx "<h2>404 — No files found for that sender</h2>" -status 404
                    } else {
                        $paths = Get-OrBuildSenderZip $senderIp $zipFiles
                        Send-FileStreamResponse $ctx $paths.ZipPath 'application/zip' $paths.DisplayName
                    }
                }
            }
        }

# ────────────────────────────────────────────────────────────────────────
# >> GET /download/zip-mega?mode=ip|filename
# ────────────────────────────────────────────────────────────────────────
        elseif ($path -eq "/download/zip-mega") {
            $token     = Get-CookieToken $req
            $quickpass = $req.QueryString["password"]
            $authorized = [string]::IsNullOrEmpty($script:ServerSettings.Password) -or (Test-Session $token) -or ($quickpass -eq $script:ServerSettings.Password)
            if (-not $authorized) {
                Send-Redirect $ctx "/download"
            } else {
                $mode = $req.QueryString["mode"]
                if ($mode -ne 'fn') { $mode = 'ip' }
                $allFiles = @(Get-UploadableFiles)
                if ($allFiles.Count -eq 0) {
                    Send-Response $ctx "<h2>404 — No files found</h2>" -status 404
                } else {
                    $megaZip = Get-OrBuildMegaZip $mode $allFiles
                    Send-FileStreamResponse $ctx $megaZip.ZipPath 'application/zip' $megaZip.DisplayName
                }
            }
        }

# ────────────────────────────────────────────────────────────────────────
# >> 404
# ────────────────────────────────────────────────────────────────────────
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

function New-RequestRunspacePool {
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $functionNames = @(
        'Write-ServerLog',
        'New-SessionToken',
        'Test-Session',
        'Get-CookieToken',
        'Get-SessionCookieAttributes',
        'Test-IsLocalRequest',
        'Test-RegexPattern',
        'Test-UploadFileName',
        'Test-UploadIPAllowed',
        'Format-ByteSize',
        'Get-SenderIpFromFileName',
        'Clear-UploadableFilesCache',
        'Get-UploadableFiles',
        'New-UploadFolderTempPath',
        'Find-IndexOfBytes',
        'Find-BytePatternInFileStream',
        'Get-ZipCacheDir',
        'Get-ZipCachePaths',
        'Get-ZipSourceFingerprint',
        'Get-ZipFingerprintHash',
        'Test-ZipCacheValid',
        'Find-SevenZipExe',
        'Build-ZipCache',
        'Save-ZipCacheManifest',
        'Get-MegaZipCachePaths',
        'Get-OrBuildMegaZip',
        'Get-DisplayNameFromFileName',
        'Get-FilenameZipCachePaths',
        'Get-OrBuildFilenameZip',
        'Get-AllSendersZipFingerprint',
        'Get-AllSendersZipCachePaths',
        'Get-OrBuildSenderZip',
        'Get-OrBuildAllSendersZip',
        'Send-FileStreamResponse',
        'Send-BytesResponse',
        'Get-ServerSettingsObject',
        'Get-ServerSettingsJson',
        'Set-ServerSettingsFromJson',
        'ConvertFrom-UploadWindowString',
        'ConvertFrom-UploadWindowPart',
        'Get-UploadWindowPart',
        'Format-UploadWindowDisplay',
        'ConvertTo-UnixTimeMs',
        'Get-UploadWindowState',
        'Test-UploadWindowOpen',
        'Get-UploadPage',
        'Get-LoginPage',
        'Get-DownloadPage',
        'Get-AdminPage',
        'Save-UploadedFile',
        'Send-Response',
        'Send-Redirect',
        'Handle-HttpContext'
    )
    foreach ($name in $functionNames) {
        $cmd = Get-Command $name -CommandType Function -ErrorAction Stop
        $iss.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($name, $cmd.Definition))
    }
    $iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('Sessions', $Sessions, 'Shared session store'))
    $iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('ServerSettings', $script:ServerSettings, 'Shared server settings'))
    $iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('UploadableFilesCache', $script:UploadableFilesCache, 'Shared upload listing cache'))
    $iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('AllSendersZipCache', $script:AllSendersZipCache, 'Shared all-senders zip cache'))
    $iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('AllSendersZipLock', $script:AllSendersZipLock, 'Shared all-senders zip cache lock'))
    $iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('CSS_SHARED', $CSS_SHARED, 'Shared CSS template'))
    $maxRunspaces = [Math]::Max(4, [Environment]::ProcessorCount * 4)
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $maxRunspaces, $iss, $Host)
    $pool.Open()
    return $pool
}

function Start-RequestWorker([System.Net.HttpListenerContext]$ctx) {
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.RunspacePool = $script:RequestRunspacePool
    [void]$ps.AddScript('param($ctx) Handle-HttpContext $ctx').AddArgument($ctx)
    $async = $ps.BeginInvoke()
    $script:ActiveRequestWorkers.Add([pscustomobject]@{ PowerShell = $ps; Async = $async })
}

function Clear-CompletedRequestWorkers {
    for ($i = $script:ActiveRequestWorkers.Count - 1; $i -ge 0; $i--) {
        $worker = $script:ActiveRequestWorkers[$i]
        if (-not $worker.Async.IsCompleted) { continue }
        try { $worker.PowerShell.EndInvoke($worker.Async) } catch {
            Write-ServerLog "Request worker failed: $($_.Exception.Message)" -Level Error
        } finally {
            $worker.PowerShell.Dispose()
            $script:ActiveRequestWorkers.RemoveAt($i)
        }
    }
}

$script:RequestRunspacePool = New-RequestRunspacePool
$script:ActiveRequestWorkers = [System.Collections.Generic.List[object]]::new()

Write-ServerLog "Entering request loop (listening)" -Level Ok

try {
    while ($listener.IsListening) {
        $async = $null
        try {
            $async = $listener.BeginGetContext($null, $null)
            while ($listener.IsListening -and -not $async.AsyncWaitHandle.WaitOne(250)) { }
            if (-not $listener.IsListening) { break }
            $ctx = $listener.EndGetContext($async)
        } catch {
            if ($listener.IsListening) {
                Write-ServerLog "BeginGetContext/EndGetContext ended: $($_.Exception.Message)" -Level Warn
            }
            break
        } finally {
            if ($async -and $async.AsyncWaitHandle) { $async.AsyncWaitHandle.Close() }
        }

        Clear-CompletedRequestWorkers
        Start-RequestWorker $ctx
    }
} finally {
    Clear-CompletedRequestWorkers
    foreach ($worker in @($script:ActiveRequestWorkers)) {
        try { $worker.PowerShell.EndInvoke($worker.Async) } catch {
            Write-ServerLog "Request worker failed during shutdown: $($_.Exception.Message)" -Level Error
        } finally {
            $worker.PowerShell.Dispose()
        }
    }
    if ($script:RequestRunspacePool) {
        $script:RequestRunspacePool.Close()
        $script:RequestRunspacePool.Dispose()
    }
    try {
        if ($listener.IsListening) { $listener.Stop() }
        $listener.Close()
    } catch {}
    Unregister-Event -SourceIdentifier PowerShell.Exiting -ErrorAction SilentlyContinue
    Remove-ServerFirewallRule
}
