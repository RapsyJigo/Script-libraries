# **A collection of more advanced scripts for incredibly specific things**

## File server

Script for creating an upload server where uploading isn't password protected but downloading is, useful for collecting exam files. The server is incredibly robust and offers a ton of features including:

* admin pannel to change settings real time
* dynamic upload location
* password protecting download
  * quickpass for direct API access in case you wish to access the server in other ways
* file name regex to enforce a certain naming convention
* max upload size
* upload IP whitelist, while not password protected you can enforce only certain IPs to be able to upload
* upload time window, you can only upload in that time window

Even further, for the download page (intendet to be viewed by proctors only) all the possible ways to download in bulk including zipping, file grouping, IP grouping and everything in between, all accessible via API quickpass as well.

Check the synposis below the command for a full list of parameters, all except the port can be live changed.

```powershell
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/RapsyJigo/Script-libraries/refs/heads/main/Upload-Download-Server.ps1').Content))
```

```powershell
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

.PARAMETER UploadWindowStart
  Optional upload window start (local time). ISO-8601 or "yyyy-MM-dd HH:mm". Empty = no start limit.
  Can also be changed live on /admin (localhost only).

.PARAMETER UploadWindowEnd
  Optional upload window end (local time). ISO-8601 or "yyyy-MM-dd HH:mm". Empty = no end limit.
  Can also be changed live on /admin (localhost only).

.EXAMPLE
    .\FileServer.ps1
    .\FileServer.ps1 -Port 9090 -Password "s3cr3t!" -UploadFolder "C:\shared"
    .\FileServer.ps1 -UploadFileRegex '\.(pdf|docx)$'
#>
```

## Internet control

Script for blocking internet access except specified IPs, uses simple windows firewall rules so admin users can trivially bypass it. **Make sure to download the unblock script before blocking the internet access otherwise you're stuck. Highly recommend downloading both files before locking / unlocking internet.**

```powershell
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/RapsyJigo/Script-libraries/refs/heads/main/Block-Internet-Except-IPs.ps1').Content)) -AllowedIPs '0.0.0.0'
```

These scripts are not self elevating so make sure to run them as admin.

```powershell
.\Block-Internet-Except-IPs.ps1 -AllowedIPs '0.0.0.0, 1.1.1.1'
.\Unblock-Internet.ps1
```

## Download file from web

Downloads a file from the internet and saves it at the specified location.

```powershell
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/RapsyJigo/Script-libraries/refs/heads/main/Block-Internet-Except-IPs.ps1').Content)) -Url "https://example.com/report.pdf" -Destination "C:\Downloads"
```

## Remove localuser

Deletes a local user and all it's files from the computer.

```powershell
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/RapsyJigo/Script-libraries/refs/heads/main/Delete-LocalUser.ps1').Content)) -Username "test"
```

## Create localuser

Creates a new local user and skips all the first logon user ads and prompts from windows, to create a non-password user leave the password string blank.

```powershell
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/RapsyJigo/Script-libraries/refs/heads/main/Create-LocalUser.ps1').Content)) -Username "test" -Password "" -Group "Users"
```
