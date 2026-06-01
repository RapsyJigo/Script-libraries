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
    [string] $UploadFileRegex = ""
)

# ── Setup ────────────────────────────────────────────────────────────────────
$ErrorActionPreference = "Stop"
Write-Host "Server is starting please wait ... " -ForegroundColor White
$resolvedUploadFolder = (New-Item -ItemType Directory -Force -Path $UploadFolder).FullName

# Live settings (also seeded from parameters; /admin can update at runtime)
$script:ServerSettings = @{
    UploadFileRegex = $UploadFileRegex
    Password        = $Password
    UploadFolder    = $resolvedUploadFolder
}

# ── Self-Elevation ───────────────────────────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Not running as Administrator -- relaunching elevated..." -ForegroundColor Yellow
    $url     = 'https://raw.githubusercontent.com/RapsyJigo/Script-libraries/refs/heads/main/Upload-Download-Server.ps1'
    $escapedRegex = $UploadFileRegex -replace "'", "''"
    $argList = "-NoExit -ExecutionPolicy Bypass -Command `"& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing '$url').Content)) -Port $Port -UploadFolder '$resolvedUploadFolder' -Password '$Password' -UploadFileRegex '$escapedRegex'`""
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
    if ([string]::IsNullOrEmpty($token)) { return $false }
    $expiry = [datetime]::MinValue
    if ($Sessions.TryGetValue($token, [ref]$expiry)) {
        if ((Get-Date) -lt $expiry) { return $true }
        $Sessions.TryRemove($token, [ref]$expiry) | Out-Null
    }
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

function Get-ServerSettingsObject {
    return @{
        uploadFileRegex = $script:ServerSettings.UploadFileRegex
        password        = $script:ServerSettings.Password
        uploadFolder    = $script:ServerSettings.UploadFolder
    }
}

function Get-ServerSettingsJson {
    return (Get-ServerSettingsObject | ConvertTo-Json -Compress)
}

if (-not [string]::IsNullOrWhiteSpace($UploadFileRegex)) {
    $regexStartupErr = $null
    if (-not (Test-RegexPattern $UploadFileRegex ([ref]$regexStartupErr))) {
        Write-Host "[ERROR] Invalid -UploadFileRegex: $regexStartupErr" -ForegroundColor Red
        exit 1
    }
}

function Set-ServerSettingsFromJson([string]$json, [ref]$errorMsg) {
    $errorMsg.Value = $null
    try {
        $data = $json | ConvertFrom-Json
    } catch {
        $errorMsg.Value = "Invalid JSON payload."
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
        } catch {
            $errorMsg.Value = "Invalid upload folder: $($_.Exception.Message)"
            return $false
        }
    }
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
    border-radius: var(--radius); padding: .9rem 1rem; gap: .6rem;
    flex-direction: column;
  }
  #prog-wrap.active { display: flex; }
  #prog-header { display: flex; justify-content: space-between; align-items: center; }
  #prog-label  { font-family: var(--mono); font-size: .82rem; color: var(--text); min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  #prog-pct    { font-family: var(--mono); font-size: .82rem; color: var(--accent2); font-weight: 700; flex-shrink: 0; }
  #prog-track  { height: 6px; background: var(--border); border-radius: 999px; overflow: hidden; }
  #prog-bar    {
    height: 100%; width: 0%;
    background: linear-gradient(90deg, var(--accent), var(--accent2));
    border-radius: 999px; transition: width .15s ease-out;
  }
  #prog-sub    { font-family: var(--mono); font-size: .75rem; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
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
          <div id="prog-header">
            <span id="prog-label">Preparing&hellip;</span>
            <span id="prog-pct">0%</span>
          </div>
          <div id="prog-track"><div id="prog-bar"></div></div>
          <div id="prog-sub">&nbsp;</div>
        </div>

        $regexHintHtml
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

function setProgress(pct, label, sub) {
  document.getElementById('prog-bar').style.width = pct + '%';
  document.getElementById('prog-pct').textContent  = Math.round(pct) + '%';
  if (label !== undefined) document.getElementById('prog-label').textContent = label;
  if (sub   !== undefined) document.getElementById('prog-sub').textContent   = sub;
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
  setProgress(0, 'Starting upload\u2026', ' ');

  const total = allFiles.length;
  let allOk = true;
  let lastErr = '';

  for (let i = 0; i < total; i++) {
    const f = allFiles[i];
    const fiEl   = document.getElementById('fi-' + i);
    const fiSt   = document.getElementById('fi-st-' + i);
    if (fiEl) fiEl.classList.add('uploading');
    if (fiSt) fiSt.textContent = 'uploading';

    const baseOffset = (i / total) * 100;
    const sliceSize  = 100 / total;

    try {
      await new Promise((resolve, reject) => {
        const fd = new FormData();
        fd.append('files', f);
        const xhr = new XMLHttpRequest();
        xhr.open('POST', '/upload-chunk');
        xhr.upload.onprogress = function(ev) {
          if (!ev.lengthComputable) return;
          const filePct = (ev.loaded / ev.total) * sliceSize;
          setProgress(
            baseOffset + filePct,
            'Uploading ' + (i+1) + ' / ' + total + ': ' + escHtml(f.name),
            fmtSize(ev.loaded) + ' / ' + fmtSize(ev.total)
          );
        };
        xhr.onload = function() {
          if (xhr.status >= 200 && xhr.status < 300) {
            if (fiEl) { fiEl.classList.remove('uploading'); fiEl.classList.add('done'); }
            if (fiSt) fiSt.textContent = 'done';
            setProgress(baseOffset + sliceSize, 'Uploaded: ' + escHtml(f.name), fmtSize(f.size));
            resolve();
          } else {
            if (fiSt) fiSt.textContent = 'rejected';
            var errMsg = (xhr.responseText || 'Upload rejected').trim();
            lastErr = errMsg;
            setProgress(baseOffset, 'Rejected: ' + escHtml(f.name), errMsg);
            allOk = false;
            reject(new Error(errMsg));
          }
        };
        xhr.onerror = function() { allOk = false; if (fiSt) fiSt.textContent = 'error'; reject(new Error('Network error')); };
        xhr.send(fd);
      });
    } catch(err) {
      allOk = false;
      if (err && err.message) {
        lastErr = err.message;
        setProgress(baseOffset, 'Failed: ' + escHtml(f.name), err.message);
      }
    }
  }

  setProgress(100, allOk ? 'All files uploaded!' : 'Done (some errors)', ' ');
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
    $files = Get-ChildItem -Path $script:ServerSettings.UploadFolder -File | Sort-Object LastWriteTime -Descending

    # Helper: extract the trailing IP from a filename stem, e.g. "report-10.0.0.1.pdf" -> "10.0.0.1"
    # Also handles IPv6 sanitised with hyphens like "file-2001-db8--1.txt"
    function Get-SenderIP([string]$filename) {
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($filename)
        # Match last segment after a hyphen that looks like an IPv4, or fall back to "Unknown"
        if ($stem -match '-(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?:_\d+)?$') {
            return $Matches[1]
        }
        # IPv6 sanitised (groups of hex separated by hyphens, at least 5 groups)
        if ($stem -match '-([0-9a-fA-F\-]{7,})(?:_\d+)?$') {
            return $Matches[1]
        }
        return "Unknown"
    }

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
    $grouped = $files | Group-Object { Get-SenderIP $_.Name } | Sort-Object Name

    $groupHtml = if ($files.Count -eq 0) {
        "<div class='empty-state'><div class='empty-state-icon'>&#128228;</div>No files uploaded yet.<br>Head to the upload page to send some files.</div>"
    } else {
        ($grouped | ForEach-Object {
            $ip       = [System.Net.WebUtility]::HtmlEncode($_.Name)
            $groupId  = "grp-" + ($ip -replace '[^a-zA-Z0-9]', '_')
            $count    = $_.Group.Count
            $rowsHtml = ($_.Group | ForEach-Object {
                $dispName = [System.Net.WebUtility]::HtmlEncode((Get-DisplayName $_.Name))
                $rawName  = [System.Net.WebUtility]::HtmlEncode($_.Name)
                $enc      = [Uri]::EscapeDataString($_.Name)
                $size     = if ($_.Length -lt 1024) { "$($_.Length) B" } elseif ($_.Length -lt 1MB) { "{0:N1} KB" -f ($_.Length/1KB) } else { "{0:N1} MB" -f ($_.Length/1MB) }
                $date     = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
                "<tr><td><a href='/download/file?name=$enc' class='dl-link' title='$rawName'>&#128196;&nbsp;$dispName</a></td><td>$size</td><td>$date</td></tr>"
            }) -join "`n"

            @"
<div class="ip-group">
  <button class="ip-header" onclick="toggleGroup('$groupId')" aria-expanded="true">
    <span class="ip-icon">&#127760;</span>
    <span class="ip-addr">$ip</span>
    <span class="ip-count badge">$count file$(if($count -ne 1){'s'})</span>
    <span class="ip-chevron" id="chev-$groupId">&#9650;</span>
  </button>
  <div class="ip-body" id="$groupId">
    <table>
      <thead><tr><th>File</th><th>Size</th><th>Uploaded</th></tr></thead>
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
  .ip-header {
    width: 100%; display: flex; align-items: center; gap: .7rem;
    padding: .85rem 1.2rem; background: var(--surface2);
    border: none; border-bottom: 1px solid var(--border);
    color: var(--text); font-family: var(--font); font-size: .95rem; font-weight: 700;
    cursor: pointer; text-align: left; transition: background .15s;
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
  .empty-state {
    text-align: center; color: var(--muted); padding: 5rem 2rem;
    font-family: var(--mono); font-size: .9rem;
    border: 1px dashed var(--border); border-radius: var(--radius);
  }
  .empty-state-icon { font-size: 2.5rem; margin-bottom: 1rem; }
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

<script>
function toggleGroup(id) {
  var body  = document.getElementById(id);
  var chev  = document.getElementById('chev-' + id);
  var btn   = body.previousElementSibling;
  var collapsed = body.classList.toggle('collapsed');
  chev.classList.toggle('collapsed', collapsed);
  btn.setAttribute('aria-expanded', !collapsed);
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
    $regexStatusBadge = if ([string]::IsNullOrWhiteSpace($script:ServerSettings.UploadFileRegex)) { "Disabled" } else { "Active" }
    $passwordStatusBadge = if ([string]::IsNullOrEmpty($script:ServerSettings.Password)) { "Unsecured" } else { "Protected" }
    $folderStatusBadge = "Configured"
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
}

document.getElementById('applyBtn').addEventListener('click', async function() {
  const btn = document.getElementById('applyBtn');
  btn.disabled = true;
  try {
    const payload = {
      uploadFileRegex: document.getElementById('uploadFileRegex').value,
      uploadFolder: document.getElementById('uploadFolder').value,
      password: document.getElementById('downloadPassword').value
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
    if (-not $contentType -or $contentType -notmatch "multipart/form-data") { return @{ Names = @(); Error = $null } }

    if ($contentType -match 'boundary="?([^";]+)"?') {
        $boundary = $Matches[1].Trim()
    } else { return @{ Names = @(); Error = $null } }

    # Read entire body into byte array
    $ms = New-Object System.IO.MemoryStream
    $req.InputStream.CopyTo($ms)
    [byte[]]$body = $ms.ToArray()
    $ms.Dispose()

    # Inline byte-sequence search
    function Find-Seq([byte[]]$hay, [byte[]]$needle, [int]$from = 0) {
        $hLen = $hay.Length; $nLen = $needle.Length
        for ($i = $from; $i -le $hLen - $nLen; $i++) {
            $ok = $true
            for ($j = 0; $j -lt $nLen; $j++) { if ($hay[$i+$j] -ne $needle[$j]) { $ok=$false; break } }
            if ($ok) { return $i }
        }
        return -1
    }

    [byte[]]$boundB    = [System.Text.Encoding]::ASCII.GetBytes($boundary)
    [byte[]]$delimB    = [System.Text.Encoding]::ASCII.GetBytes("`r`n--$boundary")
    [byte[]]$dblCRLF   = 13,10,13,10

    $savedNames = [System.Collections.Generic.List[string]]::new()

    # Find first boundary
    $cur = Find-Seq $body ([System.Text.Encoding]::ASCII.GetBytes("--$boundary"))
    if ($cur -lt 0) { return @{ Names = $savedNames; Error = $null } }
    $cur += 2 + $boundB.Length   # skip "--boundary"

    while ($true) {
        # After boundary: expect CRLF (normal part) or "--" (final boundary)
        if ($cur + 1 -ge $body.Length) { break }
        if ($body[$cur] -eq 45 -and $body[$cur+1] -eq 45) { break }  # "--" = end
        $cur += 2   # skip CRLF after boundary line

        # Find double-CRLF that ends the part headers
        $hdrEnd = Find-Seq $body $dblCRLF $cur
        if ($hdrEnd -lt 0) { break }

        $hdrBytes = $body[$cur..($hdrEnd-1)]
        $hdrStr   = [System.Text.Encoding]::UTF8.GetString($hdrBytes)
        $dataStart = $hdrEnd + 4   # skip the double-CRLF

        # Find the next boundary delimiter (CRLF + "--" + boundary)
        $nextDelim = Find-Seq $body $delimB $dataStart
        if ($nextDelim -lt 0) { break }

        # The part data is everything from $dataStart up to (not including) the CRLF before next boundary
        $dataLen = $nextDelim - $dataStart
        if ($dataLen -lt 0) { $dataLen = 0 }

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
                # Sanitise the IP so it is safe for filenames (colons in IPv6 become hyphens)
                $safeIP = $senderIP -replace '[:\\/]','-'
                $safeName = "${base}-${safeIP}${ext}"
                $destPath = Join-Path $script:ServerSettings.UploadFolder $safeName
                $idx  = 1
                while (Test-Path $destPath) {
                    $destPath = Join-Path $script:ServerSettings.UploadFolder "${base}-${safeIP}_${idx}${ext}"; $idx++
                }
                if ($dataLen -gt 0) {
                    $fileData = New-Object byte[] $dataLen
                    [System.Array]::Copy($body, $dataStart, $fileData, 0, $dataLen)
                    [System.IO.File]::WriteAllBytes($destPath, $fileData)
                } else {
                    [System.IO.File]::WriteAllBytes($destPath, [byte[]]@())
                }
                $savedNames.Add([System.IO.Path]::GetFileName($destPath))
            }
        }

        # Advance past the delimiter we found (skip CRLF + "--" + boundary)
        $cur = $nextDelim + 2 + 2 + $boundB.Length   # CRLF + "--" + boundary
    }
    return @{ Names = $savedNames; Error = $null }
}

# ── HTTP Server ──────────────────────────────────────────────────────────────
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://*:$Port/")

$result = Get-NetFirewallRule -DisplayName "Powershell"
if (-not $result) {
  New-NetFirewallRule -DisplayName "Powershell" -Direction Inbound -Program "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -Action Allow | Out-Null
}

try { $listener.Start() }
catch {
    Write-Host "[ERROR] Cannot start listener on port $Port. Try running as Administrator or choose another port." -ForegroundColor Red
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

while ($listener.IsListening) {
    $ctx = $null
    try { $ctx = $listener.GetContext() } catch { break }

    $req  = $ctx.Request
    $path = $req.Url.AbsolutePath.TrimEnd('/').ToLower()
    $method = $req.HttpMethod.ToUpper()

    if ($method -eq "GET") {
      Write-Host "  $(Get-Date -Format 'HH:mm:ss') - $($req.RemoteEndPoint) - $method : $($req.Url.PathAndQuery)" -ForegroundColor DarkCyan
    }
    else {
      Write-Host "  $(Get-Date -Format 'HH:mm:ss') - $($req.RemoteEndPoint) - $method : $($req.Url.PathAndQuery)" -ForegroundColor DarkYellow
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
            $uploadResult = Save-UploadedFile $req $req.RemoteEndPoint.Address.ToString()
            if ($uploadResult.Error) {
                Send-Response $ctx $uploadResult.Error -status 400 -contentType "text/plain; charset=utf-8"
            } elseif ($uploadResult.Names -and $uploadResult.Names.Count -gt 0) {
                $ctx.Response.StatusCode  = 200
                $ctx.Response.ContentType = "text/plain; charset=utf-8"
                $okBytes = [System.Text.Encoding]::UTF8.GetBytes("ok")
                $ctx.Response.ContentLength64 = $okBytes.Length
                try { $ctx.Response.OutputStream.Write($okBytes, 0, $okBytes.Length) } catch {}
                try { $ctx.Response.OutputStream.Close() } catch {}
            } else {
                Send-Response $ctx "Upload failed — no file received." -status 400 -contentType "text/plain; charset=utf-8"
            }
        }

        # ── GET /admin (localhost only) ──────────────────────────────────────
        elseif ($path -eq "/admin") {
            if (-not (Test-IsLocalRequest $req)) {
                Send-Response $ctx "<h2 style='font-family:sans-serif;color:#888'>403 — Admin is only available from localhost</h2>" -status 403
            } else {
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
                    $ctx.Response.AppendHeader("Set-Cookie", "ds=$token; Path=/; HttpOnly; SameSite=Strict")
                    Send-Redirect $ctx "/download"
                } else {
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
            $authorized = [string]::IsNullOrEmpty($script:ServerSettings.Password) -or (Test-Session $token) -or $quickpass
            if (-not $authorized) {
                Send-Redirect $ctx "/download"
            } else {
                $name = $req.QueryString["name"]
                $safe = [System.IO.Path]::GetFileName($name)   # strip any path traversal
                $filePath = Join-Path $script:ServerSettings.UploadFolder $safe
                if ($safe -and (Test-Path $filePath -PathType Leaf)) {
                    $bytes = [System.IO.File]::ReadAllBytes($filePath)
                    $encName = [Uri]::EscapeDataString($safe)
                    $ctx.Response.ContentType = "application/octet-stream"
                    $ctx.Response.AddHeader("Content-Disposition", "attachment; filename*=UTF-8''$encName")
                    $ctx.Response.ContentLength64 = $bytes.Length
                    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $ctx.Response.OutputStream.Close()
                } else {
                    Send-Response $ctx "<h2>404 — File not found</h2>" -status 404
                }
            }
        }

        # ── 404 ──────────────────────────────────────────────────────────────
        else {
            Send-Response $ctx "<h2 style='font-family:sans-serif;color:#888'>404 — Not Found</h2>" -status 404
        }
    }
    catch {
        Write-Host "  [ERROR] $_" -ForegroundColor Red
        try { Send-Response $ctx "<h2>500 — Internal Server Error</h2>" -status 500 } catch {}
    }
}