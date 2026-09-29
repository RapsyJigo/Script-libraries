# Setup.ps1
# Requires -RunAsAdministrator

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ===================================================
# 1. INITIAL CLEANUP & FORCE KILL ACTIVE INSTANCES
# ===================================================
Write-Host "[*] Closing active VS Code and Python background processes..."
Stop-Process -Name "code" -Force -ErrorAction SilentlyContinue
Stop-Process -Name "python" -Force -ErrorAction SilentlyContinue
Stop-Process -Name "py" -Force -ErrorAction SilentlyContinue

# ===================================================
# 2. BRUTAL PURGE OF ALL EXISTING PYTHON INFRASTRUCTURE
# ===================================================
Write-Host "[!] Running automated uninstall loops on all ghost installations..."
$PythonKeys = Get-ItemProperty @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
) -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*Python*" -and $_.UninstallString }

foreach ($Key in $PythonKeys) {
    if ($Key.UninstallString -match '"([^"]+)"') { $Exe = $Matches[1] } else { $Exe = $Key.UninstallString.Split(' ')[0] }
    if (Test-Path $Exe) {
        Write-Host "[-] Executing silent uninstallation of: $($Key.DisplayName)"
        Start-Process -FilePath $Exe -ArgumentList "/quiet /uninstall" -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
    }
}

Write-Host "[*] Deleting residual local AppData files and user paths..."
Get-ChildItem -Path "C:\Users" -Directory | ForEach-Object {
    if ($_.Name -ne "Public") {
        $UserPath = $_.FullName
        Remove-Item -Path "$UserPath\AppData\Local\Programs\Python" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$UserPath\AppData\Local\pip" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$UserPath\AppData\Local\Microsoft\WindowsApps\python*.exe" -Force -ErrorAction SilentlyContinue
    }
}
Remove-Item -Path "C:\Program Files\Python*" -Recurse -Force -ErrorAction SilentlyContinue

# ===================================================
# 3. DEPLOY CORE APPLICATIONS (DIRECT SILENT INSTALLERS)
# ===================================================
# NOTE: winget is intentionally not used here. winget is an MSIX/UWP package,
# and MSIX packages only get registered for a user account during that user's
# interactive logon. An RMM running as SYSTEM never triggers that registration,
# so 'winget' can end up unavailable no matter how well it was provisioned.
# Direct silent installers sidestep that entirely and are what's used for
# Python below anyway, so this keeps the whole script consistent.
$ProgressPreference = 'SilentlyContinue'

Write-Host "[*] Installing Visual Studio Code (machine-wide, silent)..."
$VSCodeInstaller = Join-Path $env:TEMP "VSCodeSetup-x64.exe"
Invoke-WebRequest -Uri "https://update.code.visualstudio.com/latest/win32-x64/stable" -OutFile $VSCodeInstaller -UseBasicParsing
$Proc = Start-Process -FilePath $VSCodeInstaller -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/MERGETASKS=!runcode" -Wait -PassThru
if ($Proc.ExitCode -ne 0) { Write-Warning "[!] VS Code install exited with code $($Proc.ExitCode)" }
Remove-Item $VSCodeInstaller -Force -ErrorAction SilentlyContinue

Write-Host "[*] Installing MSYS2 (silent, unattended)..."
$Msys2Installer = Join-Path $env:TEMP "msys2-installer.exe"
# This GitHub URL is a plain asset redirect (releases/latest/download/...), not the
# rate-limited api.github.com REST endpoint, so it's safe to hit from many machines at once.
Invoke-WebRequest -Uri "https://github.com/msys2/msys2-installer/releases/latest/download/msys2-x86_64-latest.exe" -OutFile $Msys2Installer -UseBasicParsing
$Proc = Start-Process -FilePath $Msys2Installer -ArgumentList "in", "--confirm-command", "--accept-messages", "--root", "C:/msys64" -Wait -PassThru
if ($Proc.ExitCode -ne 0) { Write-Warning "[!] MSYS2 install exited with code $($Proc.ExitCode)" }
Remove-Item $Msys2Installer -Force -ErrorAction SilentlyContinue

Write-Host "[*] Installing SQLite command-line tools..."
$SqlitePath = "C:\Program Files\SQLite"
# sqlite.org has no "latest" alias URL, so this is pinned like the Python installer
# below - bump the version/URL here occasionally.
$SqliteZipUrl = "https://www.sqlite.org/2026/sqlite-tools-win-x64-3530400.zip"
$SqliteZipPath = Join-Path $env:TEMP "sqlite-tools.zip"
Invoke-WebRequest -Uri $SqliteZipUrl -OutFile $SqliteZipPath -UseBasicParsing
New-Item -ItemType Directory -Path $SqlitePath -Force | Out-Null
Expand-Archive -Path $SqliteZipPath -DestinationPath $SqlitePath -Force
# The zip contains one nested "sqlite-tools-win-x64-<version>" folder - flatten it
# so sqlite3.exe ends up directly in $SqlitePath.
$NestedSqliteDir = Get-ChildItem -Path $SqlitePath -Directory | Select-Object -First 1
if ($NestedSqliteDir) {
    Get-ChildItem -Path $NestedSqliteDir.FullName | Move-Item -Destination $SqlitePath -Force
    Remove-Item -Path $NestedSqliteDir.FullName -Recurse -Force
}
Remove-Item $SqliteZipPath -Force -ErrorAction SilentlyContinue

# ===================================================
# 4. FULL NATIVE SYSTEM-WIDE PYTHON DEPLOYMENT
# ===================================================
Write-Host "[*] Downloading official, full Windows Python installer..."
$TargetDir = "C:\Program Files\Python313"
$InstallerPath = Join-Path $env:TEMP "python-full-installer.exe"

# Fetch the complete, heavy-duty executable installer from the official repository
$DownloadUrl = "https://www.python.org/ftp/python/3.13.4/python-3.13.4-amd64.exe"
Invoke-WebRequest -Uri $DownloadUrl -OutFile $InstallerPath -UserAgent "Mozilla/5.0"

Write-Host "[*] Executing enterprise installation wrapper..."
# Native Installer Arguments Explained:
# /quiet           -> Completely silent background execution context
# InstallAllUsers=1 -> Forces registration to the machine registry layer, not the profile
# TargetDir        -> Hard-locks the installer to drop files into our expected directory
# PrependPath=1    -> Globally injects it to the top of the system variables
# Include_launcher=1 -> Deploys the windows standard global 'py' management service
$InstallArgs = "/quiet InstallAllUsers=1 TargetDir=""$TargetDir"" PrependPath=1 Include_launcher=1 Include_test=0"

$Process = Start-Process -FilePath $InstallerPath -ArgumentList $InstallArgs -Wait -PassThru

# Verify exit status codes (0 is clean success)
if ($Process.ExitCode -ne 0) {
    Write-Warning "[!] Python deployment exited with error code: $($Process.ExitCode)"
}

# Clean installation artifacts
Remove-Item -Path $InstallerPath -Force -ErrorAction SilentlyContinue
# ===================================================
# 5. PROVISION C++ COMPILER TOOLCHAIN INSIDE MSYS2
# ===================================================
if (Test-Path "C:\msys64\usr\bin\bash.exe") {
    Write-Host "[*] Provisioning C++ Compiler toolchain (GCC/G++/GDB/Make)..."
    & "C:\msys64\usr\bin\bash.exe" -lc "pacman -S --noconfirm --needed mingw-w64-x86_64-toolchain base-devel"
}

# ===================================================
# 6. INJECT SYSTEM ENVIRONMENT PATH VARIABLES
# ===================================================
Write-Host "[*] Configuring System Environment PATH..."
$MsysPath = "C:\msys64\mingw64\bin"

# Resolve Python's install directory without relying on PATH at all:
# 1) We already dictated the install location ourselves above ($TargetDir) - check there first.
# 2) Fallback: the official python.org installer always registers itself under
#    HKLM:\Software\Python\PythonCore\<version>\InstallPath regardless of PATH state,
#    which also covers the case where Python was already present before this script ran.
$NativePythonPath = $null
if (Test-Path (Join-Path $TargetDir "python.exe")) {
    $NativePythonPath = $TargetDir
} else {
    $PyCoreKey = Get-Item -Path "HKLM:\Software\Python\PythonCore\*\InstallPath" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($PyCoreKey) {
        $RegPath = $PyCoreKey.GetValue('')
        if ($RegPath) { $NativePythonPath = $RegPath.TrimEnd('\') }
    }
}

if ($NativePythonPath) {
    $NativePythonScripts = "$NativePythonPath\Scripts"
    $NativePythonExe = Join-Path $NativePythonPath "python.exe"

    $CurrentMachinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $TargetPaths = @($NativePythonPath, $NativePythonScripts, $MsysPath, $SqlitePath)

    foreach ($Path in $TargetPaths) {
        if ($CurrentMachinePath -notlike "*$Path*") {
            $CurrentMachinePath = "$Path;$CurrentMachinePath"
        }
    }
    [Environment]::SetEnvironmentVariable("Path", $CurrentMachinePath, "Machine")

    # ===================================================
    # 7. PROACTIVE USER SETTINGS INJECTION
    # ===================================================
    Write-Host "[*] Injecting definitive Python default paths into VS Code user preferences..."
    # NOTE: ConvertTo-Json already escapes backslashes; do not pre-escape $NativePythonExe here
    # or the path gets double-escaped and settings.json ends up with corrupted (wrong) paths.

    $TargetSettingsPaths = @("C:\Users\Default\AppData\Roaming\Code\User")
    Get-ChildItem -Path "C:\Users" -Directory | ForEach-Object {
        if ($_.Name -ne "Public" -and $_.Name -ne "Default") {
            $TargetSettingsPaths += Join-Path $_.FullName "AppData\Roaming\Code\User"
        }
    }

    foreach ($SettingsDir in $TargetSettingsPaths) {
        if (!(Test-Path $SettingsDir)) { New-Item -ItemType Directory -Path $SettingsDir -Force | Out-Null }
        $SettingsFile = Join-Path $SettingsDir "settings.json"

        $SettingsObject = @{}
        if (Test-Path $SettingsFile) {
            $SettingsObject = Get-Content $SettingsFile | ConvertFrom-Json -ErrorAction SilentlyContinue
            if (!$SettingsObject) { $SettingsObject = @{} }
        }

        $SettingsObject | Add-Member -NotePropertyName "python.defaultInterpreterPath" -NotePropertyValue $NativePythonExe -Force
        $SettingsObject | ConvertTo-Json | Out-File $SettingsFile -Encoding utf8 -Force
    }
}

# ===================================================
# 8. MACHINE-WIDE EXTENSION INJECTION VIA GLOBAL SCRIPT
# ===================================================
Write-Host "[*] Gathering full production extension IDs..."

# Explicit array of the publisher.name extension string IDs
$ExtensionIDs = @(
    # Core C++ & Compilers
    "ms-vscode.cpptools",
    "ms-vscode.cmake-tools",

    # Python Suite (Full Stack)
    "ms-python.python",
    "ms-python.debugpy",
    "ms-python.vscode-pylance",

    # Web Stack & Parsers
    "formulahendry.code-runner",
    "esbenp.prettier-vscode",

    # Utility Viewers
    "ms-vscode.hexeditor",
    "tomoki1207.pdf",
    "mechatroner.rainbow-csv",

    # SQL Infrastructure
    "mtxr.sqltools",
    "qwtel.sqlite-viewer"
)

# Convert the array into a single string separated by commas
$CommaSeparatedList = $ExtensionIDs -join ","


Write-Host "[+] Triggering your machine-wide extension installer..."
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/RapsyJigo/Script-libraries/refs/heads/main/Install-VSCodeExtensions.ps1').Content)) -ExtensionsCsv $CommaSeparatedList


Write-Host "==================================================================="
Write-Host "[+] Environment Deployment Completed Successfully!"
Write-Host "[!] Please restart your machine manually to refresh environment shells."
Write-Host "==================================================================="