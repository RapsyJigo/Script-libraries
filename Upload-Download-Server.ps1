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
    [int]    $Port         = 80,
    [string] $UploadFolder = ".\uploads",
    [string] $Password     = "changeme"
)


# ── Self-Elevation ────────────────────────────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Not running as Administrator -- relaunching elevated..." -ForegroundColor Yellow
    $url     = 'https://raw.githubusercontent.com/RapsyJigo/Script-libraries/refs/heads/main/Upload-Download-Server.ps1'
    $argList = "-NoExit -ExecutionPolicy Bypass -Command `"& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing '$url').Content)) -Port $Port -UploadFolder '$UploadFolder' -Password '$Password'`""
    Start-Process powershell -Verb RunAs -ArgumentList $argList
    exit
}

# ── Setup ────────────────────────────────────────────────────────────────────
$ErrorActionPreference = "Stop"
$UploadFolder = (New-Item -ItemType Directory -Force -Path $UploadFolder).FullName

# Simple in-memory session store  { token -> expiry }
$Sessions = [System.Collections.Concurrent.ConcurrentDictionary[string,datetime]]::new()

function New-SessionToken {
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes) -replace '[/+=]', 'x'
}

function Test-Session([string]$token) {
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

# ── HTML Templates ────────────────────────────────────────────────────────────

$CSS_SHARED = @'
  @import url('https://fonts.googleapis.com/css2?family=Syne:wght@400;700;800&family=DM+Mono:wght@400;500&display=swap');
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  :root {
    --bg: #0d0d0f;
    --surface: #16161a;
    --border: #2a2a32;
    --accent: #166eac;
    --accent2: #00ddff;
    --text: #e8e8f0;
    --muted: #6b6b80;
    --danger: #ff5f5f;
    --radius: 12px;
    --font: 'Syne', sans-serif;
    --mono: 'DM Mono', monospace;
  }
  html, body { height: 100%; }
  body {
    background: var(--bg);
    color: var(--text);
    font-family: var(--font);
    min-height: 100vh;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 2rem;
    background-image:
      radial-gradient(ellipse 80% 50% at 20% 10%, rgba(200,241,53,.07) 0%, transparent 60%),
      radial-gradient(ellipse 60% 40% at 80% 90%, rgba(106,240,200,.06) 0%, transparent 60%);
  }
  .card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 20px;
    padding: 2.5rem 2.8rem;
    width: 100%;
    max-width: 540px;
    box-shadow: 0 24px 80px rgba(0,0,0,.5);
    position: relative;
    overflow: hidden;
  }
  .card::before {
    content: '';
    position: absolute;
    top: 0; left: 0; right: 0;
    height: 3px;
    background: linear-gradient(90deg, var(--accent), var(--accent2));
  }
  h1 { font-size: 3rem; font-weight: 300; letter-spacing: -.02em; margin-bottom: .35rem; }
  .sub { color: var(--muted); font-size: .9rem; margin-bottom: 2rem; font-family: var(--mono); }
  label { display: block; font-size: .8rem; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; color: var(--muted); margin-bottom: .5rem; margin-top: 1.2rem; }
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
    margin-top: 1.6rem; width: 100%; padding: .85rem 1.5rem;
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
  nav { margin-bottom: 2rem; text-align: center; }
  nav a { color: var(--muted); font-size: .85rem; text-decoration: none; font-family: var(--mono); border-bottom: 1px dashed var(--border); padding-bottom: 1px; }
  nav a:hover { color: var(--accent2); }
  .badge {
    display: inline-block; padding: .2rem .6rem; border-radius: 999px;
    font-size: .7rem; font-family: var(--mono); font-weight: 500;
    background: rgba(106,240,200,.12); color: var(--accent2);
    border: 1px solid rgba(106,240,200,.25); margin-left: .5rem; vertical-align: middle;
  }
'@

# -- Upload Page -------------------------------------------------------------
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
  .file-picker-wrap { margin-top: 1.2rem; }
  .file-picker-btn {
    display: inline-flex; align-items: center; gap: .6rem;
    padding: .7rem 1.2rem; background: #0066ff;
    border: 1.5px solid var(--border); border-radius: var(--radius);
    color: var(--text); font-family: var(--mono); font-size: .9rem;
    cursor: pointer; transition: border-color .2s, color .2s; width: 100%; justify-content: center;
  }
  .file-picker-btn:hover { border-color: var(--accent2); color: var(--accent2); }
  #file-preview {
    margin-top: .9rem; display: flex; flex-direction: column; gap: .4rem;
    max-height: 220px; overflow-y: auto;
  }
  #file-preview:empty::after {
    content: 'No file chosen';
    display: block; text-align: center;
    color: var(--muted); font-family: var(--mono); font-size: .82rem;
    padding: .6rem 0;
  }
  .fi {
    display: flex; align-items: center; gap: .7rem;
    background: var(--bg); border: 1px solid var(--border);
    border-radius: 8px; padding: .5rem .85rem;
    transition: border-color .3s;
  }
  .fi.uploading { border-color: var(--accent2); }
  .fi.done      { border-color: var(--accent); }
  .fi-icon { font-size: 1rem; flex-shrink: 0; }
  .fi-name { flex: 1; font-family: var(--mono); font-size: .82rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .fi-size { color: var(--muted); font-family: var(--mono); font-size: .75rem; flex-shrink: 0; }
  .fi-status { font-family: var(--mono); font-size: .75rem; flex-shrink: 0; color: var(--muted); min-width: 3.5rem; text-align: right; }
  /* Progress bar */
  #prog-wrap {
    display: none; margin-top: 1rem;
    background: var(--bg); border: 1px solid var(--border);
    border-radius: var(--radius); padding: .9rem 1rem; gap: .6rem;
    flex-direction: column;
  }
  #prog-wrap.active { display: flex; }
  #prog-header { display: flex; justify-content: space-between; align-items: center; }
  #prog-label  { font-family: var(--mono); font-size: .82rem; color: var(--text); }
  #prog-pct    { font-family: var(--mono); font-size: .82rem; color: var(--accent); font-weight: 700; }
  #prog-track  { height: 6px; background: var(--border); border-radius: 999px; overflow: hidden; }
  #prog-bar    {
    height: 100%; width: 0%;
    background: linear-gradient(90deg, var(--accent), var(--accent2));
    border-radius: 999px;
    transition: width .15s ease-out;
  }
  #prog-sub    { font-family: var(--mono); font-size: .75rem; color: var(--muted); }
</style></head><body>
<div class="card">
  <h1>File Upload <span class="badge">Public</span></h1>
  <p class="sub">Select files to upload &mdash; no login required</p>
  <nav><a href="/download">Go to Download Page &rarr;</a></nav>

  <form id="uploadForm" enctype="multipart/form-data">
    <label>Files</label>
    <div class="file-picker-wrap">
      <div class="file-picker-btn" id="browseBtn" onclick="document.getElementById('fileInput').click()">
        &#128193;&nbsp; Browse files&hellip;
      </div>
      <input type="file" id="fileInput" name="files" multiple
             style="position:absolute;width:1px;height:1px;opacity:0;pointer-events:none"
             onchange="updatePreview(this.files)">
    </div>
    <div id="file-preview"></div>

    <div id="prog-wrap">
      <div id="prog-header">
        <span id="prog-label">Preparing&hellip;</span>
        <span id="prog-pct">0%</span>
      </div>
      <div id="prog-track"><div id="prog-bar"></div></div>
      <div id="prog-sub">&nbsp;</div>
    </div>

    <button type="submit" class="btn" id="submitBtn" disabled
            style="opacity:.4;cursor:not-allowed">&#8593;&nbsp; Upload</button>
  </form>
  $msgHtml
</div>

<script>
let allFiles = [];

function escHtml(s){return s.replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));}
function fmtSize(b){if(b<1024)return b+' B';if(b<1048576)return (b/1024).toFixed(1)+' KB';return (b/1048576).toFixed(1)+' MB';}

function updatePreview(files) {
  allFiles = Array.from(files);
  const preview = document.getElementById('file-preview');
  const btn     = document.getElementById('submitBtn');
  if (!allFiles.length) {
    preview.innerHTML = '';
    btn.disabled = true; btn.style.opacity = '.4'; btn.style.cursor = 'not-allowed';
    return;
  }
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

  // Lock UI
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
            resolve(); // continue with remaining files
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

# ── Login Page ────────────────────────────────────────────────────────────────
function Get-LoginPage([bool]$failed = $false) {
    $errHtml = if ($failed) { "<div class='msg err'>&#10007;&nbsp; Incorrect password. Try again.</div>" } else { "" }
    return @"
<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Download — Sign In</title>
<style>$CSS_SHARED</style></head><body>
<div class="card">
  <h1>Download <span class="badge">Protected</span></h1>
  <p class="sub">Enter the password to access files</p>
  <nav><a href="/">&larr; Back to Upload</a></nav>
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

# ── Download Page ─────────────────────────────────────────────────────────────
function Get-DownloadPage {
    $files = Get-ChildItem -Path $UploadFolder -File | Sort-Object LastWriteTime -Descending
    $rows = if ($files.Count -eq 0) {
        "<tr><td colspan='3' style='text-align:center;color:var(--muted);padding:2rem;font-family:var(--mono)'>No files uploaded yet.</td></tr>"
    } else {
        ($files | ForEach-Object {
            $name = [System.Net.WebUtility]::HtmlEncode($_.Name)
            $enc  = [Uri]::EscapeDataString($_.Name)
            $size = if ($_.Length -lt 1024) { "$($_.Length) B" } elseif ($_.Length -lt 1MB) { "{0:N1} KB" -f ($_.Length/1KB) } else { "{0:N1} MB" -f ($_.Length/1MB) }
            $date = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
            "<tr><td><a href='/download/file?name=$enc' class='dl-link'>&#128196;&nbsp;$name</a></td><td>$size</td><td>$date</td></tr>"
        }) -join "`n"
    }
    return @"
<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Download Files</title>
<style>$CSS_SHARED
  .card { max-width: 720px; }
  table { width: 100%; border-collapse: collapse; margin-top: .5rem; }
  th { text-align: left; font-size: .75rem; letter-spacing: .08em; text-transform: uppercase; color: var(--muted); padding: .5rem .8rem; border-bottom: 1px solid var(--border); }
  td { padding: .65rem .8rem; border-bottom: 1px solid rgba(255,255,255,.04); font-size: .9rem; vertical-align: middle; }
  td:nth-child(2), td:nth-child(3) { color: var(--muted); font-family: var(--mono); font-size: .8rem; white-space: nowrap; }
  tr:hover td { background: rgba(255,255,255,.025); }
  .dl-link { color: var(--accent2); text-decoration: none; font-family: var(--mono); font-size: .85rem; }
  .dl-link:hover { color: var(--accent); }
  .logout { float: right; color: var(--danger); font-size: .8rem; font-family: var(--mono); text-decoration: none; opacity: .7; }
  .logout:hover { opacity: 1; }
</style></head><body>
<div class="card">
  <h1>Downloads <span class="badge">Secure</span></h1>
  <p class="sub" style="display:flex;justify-content:space-between;align-items:center">
    <span>$($files.Count) file(s) available</span>
    <a href='/download/logout' class='logout'>&#128274; Lock &amp; Exit</a>
  </p>
  <nav><a href="/">&larr; Back to Upload</a></nav>
  <table>
    <thead><tr><th>File</th><th>Size</th><th>Uploaded</th></tr></thead>
    <tbody>$rows</tbody>
  </table>
</div>
</body></html>
"@
}

# ── Multipart Parser ──────────────────────────────────────────────────────────
function Save-UploadedFile([System.Net.HttpListenerRequest]$req) {
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

    [byte[]]$dash2     = 45,45                        # "--"
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
                $destPath = Join-Path $UploadFolder $safeName
                $base = [System.IO.Path]::GetFileNameWithoutExtension($safeName)
                $ext  = [System.IO.Path]::GetExtension($safeName)
                $idx  = 1
                while (Test-Path $destPath) {
                    $destPath = Join-Path $UploadFolder "${base}_${idx}${ext}"; $idx++
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

# ── HTTP Server ───────────────────────────────────────────────────────────────
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$Port/")

try { $listener.Start() }
catch {
    Write-Host "[ERROR] Cannot start listener on port $Port. Try running as Administrator or choose another port." -ForegroundColor Red
    exit 1
}

$privateIP = (Get-NetIPConfiguration | Where-Object {$_.IPv4DefaultGateway -ne $null -and $_.NetAdapter.Status -ne "Disconnected"}).IPv4Address.IPAddress
$publicIP = (Invoke-WebRequest ifconfig.me/ip).Content.Trim()

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║       PowerShell File Server Running     ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Upload Page   : http://${privateIP}:$Port/" -ForegroundColor Blue
Write-Host "  Download Page : http://${privateIP}:$Port/download" -ForegroundColor Blue
Write-Host "  Password      : $Password" -ForegroundColor Magenta
Write-Host "  Upload Folder : $UploadFolder" -ForegroundColor Blue
Write-Host "  Local IP      : $privateIP" -ForegroundColor Blue
Write-Host "  Public IP     : $publicIP" -ForegroundColor Blue
Write-Host ""
Write-Host "  To access this file server from outside LAN you must open its corresponding port number " -ForegroundColor Green
Write-Host ""

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
      Write-Host "  $(Get-Date -Format 'HH:mm:ss') - $($req.RemoteEndPoint) - $method : $($req.Url.PathAndQuery)" -ForegroundColor DarkRed
    }


    try {
        # ── GET / ─────────────────────────────────────────────────────────────
        if ($path -eq "" -or $path -eq "/") {
            $ok = $req.QueryString["ok"]
            $err = $req.QueryString["err"]
            $msg = if ($err) { "Upload failed for one or more files." } elseif ($ok -and $ok -ne "1") { "Uploaded: $([Uri]::UnescapeDataString($ok))" } elseif ($ok) { "Files uploaded successfully!" } else { "" }
            $isErr = [bool]$err
            Send-Response $ctx (Get-UploadPage -msg $msg -isError $isErr)
        }

        # ── POST /upload ──────────────────────────────────────────────────────
        elseif ($path -eq "/upload" -and $method -eq "POST") {
            $names = Save-UploadedFile $req
            if ($names -and $names.Count -gt 0) {
                $enc = [Uri]::EscapeDataString(($names -join ", "))
                Send-Redirect $ctx "/?ok=$enc"
            } else {
                Send-Response $ctx (Get-UploadPage -msg "Upload failed — no file received." -isError $true) -status 400
            }
        }

        # ── POST /upload-chunk (single file per XHR, used by progress uploader) ─────
        elseif ($path -eq "/upload-chunk" -and $method -eq "POST") {
            $names = Save-UploadedFile $req
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

        # ── GET /download ─────────────────────────────────────────────────────
        elseif ($path -eq "/download") {
            $token = Get-CookieToken $req
            if (Test-Session $token) {
                Send-Response $ctx (Get-DownloadPage)
            } else {
                Send-Response $ctx (Get-LoginPage)
            }
        }

        # ── POST /download/login ──────────────────────────────────────────────
        elseif ($path -eq "/download/login" -and $method -eq "POST") {
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

        # ── GET /download/logout ──────────────────────────────────────────────
        elseif ($path -eq "/download/logout") {
            $token = Get-CookieToken $req
            if ($token) {
                $dummy = [datetime]::MinValue
                $Sessions.TryRemove($token, [ref]$dummy) | Out-Null
            }
            $ctx.Response.AppendHeader("Set-Cookie", "ds=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly")
            Send-Redirect $ctx "/download"
        }

        # ── GET /download/file?name=... ───────────────────────────────────────
        elseif ($path -eq "/download/file") {
            $token = Get-CookieToken $req
            $quickpass = $req.QueryString["password"]
            if (-not (Test-Session $token) -and -not($quickpass)) {
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

        # ── 404 ───────────────────────────────────────────────────────────────
        else {
            Send-Response $ctx "<h2 style='font-family:sans-serif;color:#888'>404 — Not Found</h2>" -status 404
        }
    }
    catch {
        Write-Host "  [ERROR] $_" -ForegroundColor Red
        try { Send-Response $ctx "<h2>500 — Internal Server Error</h2>" -status 500 } catch {}
    }
}