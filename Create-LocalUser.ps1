#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a new local Windows user.

.DESCRIPTION
    Creates a local user account with the following characteristics:
      - Password cannot be changed by the user
      - Password never expires
    Intended to be run remotely via RMM agents at SYSTEM level.

.PARAMETER Username
    The username for the new account. (Required)

.PARAMETER Password
    The password for the new account. (Required) Pass an empty string "" to create the account with no password.

.PARAMETER Group
    The local group to add the user to. Defaults to "Users".
    Common values: "Users", "Administrators", "Remote Desktop Users", "Power Users"

.EXAMPLE
    .\New-ManagedUser.ps1 -Username "servicedesk" -Password "P@ssw0rd!" -Group "Administrators"

.EXAMPLE
    .\New-ManagedUser.ps1 -Username "kiosk" -Password "" -Group "Users"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Password,

    [Parameter(Mandatory = $false)]
    [string]$Group = "Users"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ────────────────────────────────────────────────────────────────────────
# >> Main try/catch — single write to console on exit
# ────────────────────────────────────────────────────────────────────────
try {

# ────────────────────────────────────────────────────────────────────────
# >> 1. Build New-LocalUser parameter set
# ────────────────────────────────────────────────────────────────────────
    $newUserParams = @{
        Name                     = $Username
        PasswordNeverExpires     = $true
        UserMayNotChangePassword = $true
        AccountNeverExpires      = $true
    }

    if ($Password -eq "") {
        $newUserParams["NoPassword"] = $true
        $passwordMode = "no password"
    } else {
        $newUserParams["Password"] = ConvertTo-SecureString -String $Password -AsPlainText -Force
        $passwordMode = "password set"
    }

# ────────────────────────────────────────────────────────────────────────
# >> 2. Abort if user already exists
# ────────────────────────────────────────────────────────────────────────
    if (Get-LocalUser -Name $Username -ErrorAction SilentlyContinue) {
        throw "User '$Username' already exists."
    }

    New-LocalUser @newUserParams | Out-Null

# ────────────────────────────────────────────────────────────────────────
# >> 3. Validate group and add user membership
# ────────────────────────────────────────────────────────────────────────
    if (-not (Get-LocalGroup -Name $Group -ErrorAction SilentlyContinue)) {
        throw "Group '$Group' does not exist on this machine."
    }

    Add-LocalGroupMember -Group $Group -Member $Username

# ────────────────────────────────────────────────────────────────────────
# >> 4. Single success output
# ────────────────────────────────────────────────────────────────────────
    Write-Output "SUCCESS: User '$Username' created ($passwordMode), added to '$Group'."

} catch {
# ────────────────────────────────────────────────────────────────────────
# >> Single error output
# ────────────────────────────────────────────────────────────────────────
    Write-Error "ERROR: $_"
    exit 1
}
