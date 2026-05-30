#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Logs on a specified local or domain user interactively from the SYSTEM context.
    Designed to be deployed via an RMM agent running as SYSTEM.

.DESCRIPTION
    Uses the Windows API (LogonUser) via P/Invoke to authenticate the user,
    then launches an interactive process (explorer.exe) in that user's logon session
    so a desktop session is created. Alternatively, it can use the "RunAs" technique
    via CreateProcessWithLogonW to spawn a process as the target user.

    Two modes are provided:
      1. CREATE_SESSION  – Creates a new interactive logon session for the user
                           (calls LogonUser + LoadUserProfile + CreateProcessAsUser).
      2. RUNAS           – Runs a specified process as the target user without
                           creating a full desktop session (lighter-weight).

.PARAMETER Username
    The username to log on. For domain accounts use "DOMAIN\User" or "user@domain.com".
    For local accounts use ".\Username" or just "Username".

.PARAMETER Password
    The plaintext password for the user. Passed as a SecureString conversion internally.

.PARAMETER Domain
    Optional. The domain name. If Username already contains a domain prefix,
    this parameter is ignored. Defaults to "." (local machine).

.PARAMETER Mode
    CREATE_SESSION  – Full interactive logon (default).
    RUNAS           – Spawn a process as the user (set -ProcessToRun).

.PARAMETER ProcessToRun
    The executable to launch when Mode is RUNAS. Defaults to "cmd.exe".

.EXAMPLE
    # Log on a local user interactively
    .\Invoke-UserLogon.ps1 -Username ".\jdoe" -Password "P@ssw0rd!"

.EXAMPLE
    # Log on a domain user interactively
    .\Invoke-UserLogon.ps1 -Username "CORP\jdoe" -Password "P@ssw0rd!" -Domain "CORP"

.EXAMPLE
    # Run a process as a user without a full session
    .\Invoke-UserLogon.ps1 -Username "jdoe" -Password "P@ssw0rd!" -Mode RUNAS -ProcessToRun "cmd.exe"

.NOTES
    - Must be run as SYSTEM or an account with SE_TCB_NAME (Act as part of the OS) privilege.
    - Audit logon events will be generated in the Security event log.
    - Tested on Windows 10/11 and Windows Server 2016/2019/2022.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [string]$Password,

    [Parameter(Mandatory = $false)]
    [string]$Domain = ".",

    [Parameter(Mandatory = $false)]
    [ValidateSet("CREATE_SESSION", "RUNAS")]
    [string]$Mode = "CREATE_SESSION",

    [Parameter(Mandatory = $false)]
    [string]$ProcessToRun = "cmd.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helper: Parse "DOMAIN\User" or "user@domain" out of Username if provided
# ---------------------------------------------------------------------------
function Resolve-UserDomain {
    param([string]$User, [string]$Dom)

    if ($User -match '^(.+)\\(.+)$') {
        return @{ Domain = $Matches[1]; User = $Matches[2] }
    }
    elseif ($User -match '^(.+)@(.+)$') {
        return @{ Domain = $Matches[2]; User = $Matches[1] }
    }
    else {
        return @{ Domain = $Dom; User = $User }
    }
}

$parsed  = Resolve-UserDomain -User $Username -Dom $Domain
$logUser = $parsed.User
$logDom  = $parsed.Domain

Write-Host "[*] Target user  : $logDom\$logUser"
Write-Host "[*] Mode         : $Mode"

# ---------------------------------------------------------------------------
# P/Invoke declarations
# ---------------------------------------------------------------------------
$NativeCode = @'
using System;
using System.Runtime.InteropServices;
using System.Security;

public static class NativeMethods
{
    // Logon types
    public const int LOGON32_LOGON_INTERACTIVE = 2;
    public const int LOGON32_LOGON_NETWORK     = 3;

    // Logon providers
    public const int LOGON32_PROVIDER_DEFAULT  = 0;

    // Process creation flags
    public const uint CREATE_NEW_CONSOLE       = 0x00000010;
    public const uint NORMAL_PRIORITY_CLASS    = 0x00000020;

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool LogonUser(
        string lpszUsername,
        string lpszDomain,
        string lpszPassword,
        int    dwLogonType,
        int    dwLogonProvider,
        out IntPtr phToken);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CreateProcessAsUser(
        IntPtr hToken,
        string lpApplicationName,
        string lpCommandLine,
        IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes,
        bool   bInheritHandles,
        uint   dwCreationFlags,
        IntPtr lpEnvironment,
        string lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CreateProcessWithLogonW(
        string lpUsername,
        string lpDomain,
        string lpPassword,
        uint   dwLogonFlags,
        string lpApplicationName,
        string lpCommandLine,
        uint   dwCreationFlags,
        IntPtr lpEnvironment,
        string lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("userenv.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool LoadUserProfile(
        IntPtr hToken,
        ref PROFILEINFO lpProfileInfo);

    [DllImport("userenv.dll", SetLastError = true)]
    public static extern bool UnloadUserProfile(
        IntPtr hToken,
        IntPtr hProfile);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool DuplicateTokenEx(
        IntPtr hExistingToken,
        uint   dwDesiredAccess,
        IntPtr lpTokenAttributes,
        int    ImpersonationLevel,
        int    TokenType,
        out IntPtr phNewToken);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO
    {
        public int    cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int    dwX, dwY, dwXSize, dwYSize;
        public int    dwXCountChars, dwYCountChars;
        public int    dwFillAttribute;
        public int    dwFlags;
        public short  wShowWindow;
        public short  cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int    dwProcessId;
        public int    dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PROFILEINFO
    {
        public int    dwSize;
        public int    dwFlags;
        public string lpUserName;
        public string lpProfilePath;
        public string lpDefaultPath;
        public string lpServerName;
        public string lpPolicyPath;
        public IntPtr hProfile;
    }

    // TOKEN_ALL_ACCESS
    public const uint TOKEN_ALL_ACCESS = 0x000F01FF;

    // Token types
    public const int TokenPrimary       = 1;
    public const int SecurityImpersonation = 2;
}
'@

Add-Type -TypeDefinition $NativeCode -Language CSharp

# ---------------------------------------------------------------------------
# Mode: RUNAS  –  CreateProcessWithLogonW (no SE_TCB needed, but no full session)
# ---------------------------------------------------------------------------
if ($Mode -eq "RUNAS") {
    Write-Host "[*] Launching '$ProcessToRun' as $logDom\$logUser via CreateProcessWithLogonW ..."

    $si = New-Object NativeMethods+STARTUPINFO
    $si.cb        = [System.Runtime.InteropServices.Marshal]::SizeOf($si)
    $si.lpDesktop = "winsta0\default"
    $pi = New-Object NativeMethods+PROCESS_INFORMATION

    $LOGON_WITH_PROFILE = 1
    $success = [NativeMethods]::CreateProcessWithLogonW(
        $logUser,
        $logDom,
        $Password,
        $LOGON_WITH_PROFILE,
        $null,
        $ProcessToRun,
        [NativeMethods]::CREATE_NEW_CONSOLE,
        [IntPtr]::Zero,
        $null,
        [ref]$si,
        [ref]$pi
    )

    if (-not $success) {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "CreateProcessWithLogonW failed. Win32 error: $err"
    }

    Write-Host "[+] Process launched successfully."
    Write-Host "    PID : $($pi.dwProcessId)"
    Write-Host "    TID : $($pi.dwThreadId)"

    [NativeMethods]::CloseHandle($pi.hProcess) | Out-Null
    [NativeMethods]::CloseHandle($pi.hThread)  | Out-Null
    exit 0
}

# ---------------------------------------------------------------------------
# Mode: CREATE_SESSION  –  LogonUser + LoadUserProfile + CreateProcessAsUser
# ---------------------------------------------------------------------------
Write-Host "[*] Calling LogonUser for $logDom\$logUser ..."

$hToken = [IntPtr]::Zero
$logonOk = [NativeMethods]::LogonUser(
    $logUser,
    $logDom,
    $Password,
    [NativeMethods]::LOGON32_LOGON_INTERACTIVE,
    [NativeMethods]::LOGON32_PROVIDER_DEFAULT,
    [ref]$hToken
)

if (-not $logonOk) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "LogonUser failed. Win32 error: $err  (Check credentials and that the account is not locked/disabled)"
}

Write-Host "[+] LogonUser succeeded. Token handle: $hToken"

# Duplicate token to a primary token (required by CreateProcessAsUser)
$hPrimaryToken = [IntPtr]::Zero
$dupOk = [NativeMethods]::DuplicateTokenEx(
    $hToken,
    [NativeMethods]::TOKEN_ALL_ACCESS,
    [IntPtr]::Zero,
    [NativeMethods]::SecurityImpersonation,
    [NativeMethods]::TokenPrimary,
    [ref]$hPrimaryToken
)

if (-not $dupOk) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    [NativeMethods]::CloseHandle($hToken) | Out-Null
    throw "DuplicateTokenEx failed. Win32 error: $err"
}

# Load user profile (creates HKCU hive, sets %USERPROFILE%, etc.)
Write-Host "[*] Loading user profile ..."
$profileInfo = New-Object NativeMethods+PROFILEINFO
$profileInfo.dwSize    = [System.Runtime.InteropServices.Marshal]::SizeOf($profileInfo)
$profileInfo.lpUserName = $logUser
$profileInfo.dwFlags   = 1   # PI_NOUI

$profileOk = [NativeMethods]::LoadUserProfile($hPrimaryToken, [ref]$profileInfo)
if (-not $profileOk) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Write-Warning "LoadUserProfile failed (Win32 error: $err). Continuing without profile load."
}
else {
    Write-Host "[+] User profile loaded."
}

# Launch explorer.exe (or any shell) in the user's session
$shellProcess = "explorer.exe"
Write-Host "[*] Launching '$shellProcess' as the logged-on user ..."

$si2 = New-Object NativeMethods+STARTUPINFO
$si2.cb        = [System.Runtime.InteropServices.Marshal]::SizeOf($si2)
$si2.lpDesktop = "winsta0\default"
$pi2 = New-Object NativeMethods+PROCESS_INFORMATION

$createOk = [NativeMethods]::CreateProcessAsUser(
    $hPrimaryToken,
    $null,
    $shellProcess,
    [IntPtr]::Zero,
    [IntPtr]::Zero,
    $false,
    ([NativeMethods]::CREATE_NEW_CONSOLE -bor [NativeMethods]::NORMAL_PRIORITY_CLASS),
    [IntPtr]::Zero,
    $null,
    [ref]$si2,
    [ref]$pi2
)

if (-not $createOk) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    # Cleanup
    if ($profileInfo.hProfile -ne [IntPtr]::Zero) {
        [NativeMethods]::UnloadUserProfile($hPrimaryToken, $profileInfo.hProfile) | Out-Null
    }
    [NativeMethods]::CloseHandle($hPrimaryToken) | Out-Null
    [NativeMethods]::CloseHandle($hToken)        | Out-Null
    throw "CreateProcessAsUser failed. Win32 error: $err  (Ensure SYSTEM has SE_AssignPrimaryTokenPrivilege and SE_IncreaseQuotaPrivilege)"
}

Write-Host "[+] Session process launched successfully."
Write-Host "    PID : $($pi2.dwProcessId)"
Write-Host "    TID : $($pi2.dwThreadId)"

# Cleanup handles (profile stays loaded while the user session is alive)
[NativeMethods]::CloseHandle($pi2.hProcess) | Out-Null
[NativeMethods]::CloseHandle($pi2.hThread)  | Out-Null
[NativeMethods]::CloseHandle($hPrimaryToken) | Out-Null
[NativeMethods]::CloseHandle($hToken)        | Out-Null

Write-Host "[+] Done. User '$logDom\$logUser' is now logged on."