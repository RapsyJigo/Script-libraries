#Requires -Version 5.1
<#
.SYNOPSIS
    Simple HTTP File Server - Upload & Password-Protected Download

.DESCRIPTION
    Hosts two web pages:
      /         -> Upload page (anyone can upload files)
      /download -> Password-protected download page

.PARAMETER Port
    TCP port to listen on. Default: 80

.PARAMETER UploadFolder
    Folder where uploaded files are saved. Default: .\uploads

.PARAMETER Password
    Password required to access the download page. Default: changeme

.EXAMPLE
    .\FileServer.ps1
    .\FileServer.ps1 -Port 9090 -Password "s3cr3t!" -UploadFolder "C:\shared"
#>
param(
    [Parameter(Mandatory = $false, HelpMessage = "The port on which the server will be opened. Must have no other processes using this port.")]
    [int]    $Port         = 80,

    [Parameter(Mandatory = $false, HelpMessage = "The folder where all the files will be saved to, you can put your own files there if you only wish to use the download part of the server without going through uploading")]
    [string] $UploadFolder = ".\uploads",

    [Parameter(Mandatory = $true, HelpMessage = "The password to be used to access the download page. If the password is left as a blank string the server will run in unsecure mode.")]
    [AllowEmptyString()]
    [string] $Password     = ""
)

# ── Setup ────────────────────────────────────────────────────────────────────
$ErrorActionPreference = "Stop"
Write-Host "Server is starting please wait ... " -ForegroundColor White
$UploadFolder = (New-Item -ItemType Directory -Force -Path $UploadFolder).FullName

# ── Self-Elevation ───────────────────────────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Not running as Administrator -- relaunching elevated..." -ForegroundColor Yellow
    $url     = 'https://raw.githubusercontent.com/RapsyJigo/Script-libraries/refs/heads/main/Upload-Download-Server.ps1'
    $argList = "-NoExit -ExecutionPolicy Bypass -Command `"& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing '$url').Content)) -Port $Port -UploadFolder '$UploadFolder' -Password '$Password'`""
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
    if ([string]::IsNullOrEmpty($Password)) { return $true }  # open-access mode
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
            if (fiSt) fiSt.textContent = 'error';
            allOk = false;
            resolve();
          }
        };
        xhr.onerror = function() { allOk = false; if (fiSt) fiSt.textContent = 'error'; resolve(); };
        xhr.send(fd);
      });
    } catch(err) { allOk = false; }
  }

  setProgress(100, allOk ? 'All files uploaded!' : 'Done (some errors)', ' ');
  setTimeout(function() {
    window.location.href = allOk ? '/?ok=1' : '/?err=1';
  }, 700);
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
    $files = Get-ChildItem -Path $UploadFolder -File | Sort-Object LastWriteTime -Descending

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
  <span class="topbar-title">&#128229; Downloads $(if (-not [string]::IsNullOrEmpty($Password)) { "<span class='badge'>Secure</span>" } else { "<span class='badge'>Public</span>" })</span>
  <span class="topbar-meta">
    <span class="stat-pill">&#128196; <strong>$($files.Count)</strong> file$(if($files.Count -ne 1){'s'})</span>
    <span class="stat-pill">&#127760; <strong>$($grouped.Count)</strong> sender$(if($grouped.Count -ne 1){'s'})</span>
  </span>
  <nav class="topbar-nav">
    <a href="/">&larr; Upload</a>
    $(if (-not [string]::IsNullOrEmpty($Password)) { "<a href='/download/logout' class='danger'>&#128274; Lock &amp; Exit</a>" })
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

# ── Multipart Parser ─────────────────────────────────────────────────────────
function Save-UploadedFile([System.Net.HttpListenerRequest]$req, [string]$senderIP = "unknown") {
    $contentType = $req.ContentType
    if (-not $contentType -or $contentType -notmatch "multipart/form-data") { return $null }

    if ($contentType -match 'boundary="?([^";]+)"?') {
        $boundary = $Matches[1].Trim()
    } else { return $null }

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
    if ($cur -lt 0) { return $savedNames }
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
                $safeName = ([System.IO.Path]::GetFileName($origName)) -replace '[^\w\.\-_() ]',''
                if (-not $safeName) { $safeName = "upload_" + (Get-Date -Format 'yyyyMMddHHmmss') }
                $base = [System.IO.Path]::GetFileNameWithoutExtension($safeName)
                $ext  = [System.IO.Path]::GetExtension($safeName)
                # Sanitise the IP so it is safe for filenames (colons in IPv6 become hyphens)
                $safeIP = $senderIP -replace '[:\\/]','-'
                $safeName = "${base}-${safeIP}${ext}"
                $destPath = Join-Path $UploadFolder $safeName
                $idx  = 1
                while (Test-Path $destPath) {
                    $destPath = Join-Path $UploadFolder "${base}-${safeIP}_${idx}${ext}"; $idx++
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
    return $savedNames
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
Write-Host "  Upload Folder : $UploadFolder" -ForegroundColor DarkBlue
if ([string]::IsNullOrEmpty($Password)) {
  Write-Host "  Password      : Unsecure mode, no password needed" -ForegroundColor Red
}
else {
  Write-Host "  Password      : $Password" -ForegroundColor Magenta
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

Start-Process "http://${ip}:${Port}/"

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
            $msg = if ($err) { "Upload failed for one or more files." } elseif ($ok -and $ok -ne "1") { "Uploaded: $([Uri]::UnescapeDataString($ok))" } elseif ($ok) { "Files uploaded successfully!" } else { "" }
            $isErr = [bool]$err
            Send-Response $ctx (Get-UploadPage -msg $msg -isError $isErr)
        }

        # ── POST /upload ─────────────────────────────────────────────────────
        elseif ($path -eq "/upload" -and $method -eq "POST") {
            $names = Save-UploadedFile $req $req.RemoteEndPoint.Address.ToString()
            if ($names -and $names.Count -gt 0) {
                $enc = [Uri]::EscapeDataString(($names -join ", "))
                Send-Redirect $ctx "/?ok=$enc"
            } else {
                Send-Response $ctx (Get-UploadPage -msg "Upload failed — no file received." -isError $true) -status 400
            }
        }

        # ── POST /upload-chunk (single file per XHR, used by progress uploader)
        elseif ($path -eq "/upload-chunk" -and $method -eq "POST") {
            $names = Save-UploadedFile $req $req.RemoteEndPoint.Address.ToString()
            if ($names -and $names.Count -gt 0) {
                $ctx.Response.StatusCode  = 200
                $ctx.Response.ContentType = "text/plain; charset=utf-8"
                $okBytes = [System.Text.Encoding]::UTF8.GetBytes("ok")
                $ctx.Response.ContentLength64 = $okBytes.Length
                try { $ctx.Response.OutputStream.Write($okBytes, 0, $okBytes.Length) } catch {}
                try { $ctx.Response.OutputStream.Close() } catch {}
            } else {
                Send-Response $ctx "error" -status 400 -contentType "text/plain"
            }
        }

        # ── GET /download ────────────────────────────────────────────────────
        elseif ($path -eq "/download") {
            $token = Get-CookieToken $req
            if ([string]::IsNullOrEmpty($Password) -or (Test-Session $token)) {
                Send-Response $ctx (Get-DownloadPage)
            } else {
                Send-Response $ctx (Get-LoginPage)
            }
        }

        # ── POST /download/login ─────────────────────────────────────────────
        elseif ($path -eq "/download/login" -and $method -eq "POST") {
            if ([string]::IsNullOrEmpty($Password)) {
                Send-Redirect $ctx "/download"
            } else {
                $reader = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
                $body   = $reader.ReadToEnd()
                $parsed = [System.Web.HttpUtility]::ParseQueryString($body)
                $pw     = $parsed["password"]
                if ($pw -eq $Password) {
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
            $authorized = [string]::IsNullOrEmpty($Password) -or (Test-Session $token) -or $quickpass
            if (-not $authorized) {
                Send-Redirect $ctx "/download"
            } else {
                $name = $req.QueryString["name"]
                $safe = [System.IO.Path]::GetFileName($name)   # strip any path traversal
                $filePath = Join-Path $UploadFolder $safe
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