# **A collection of more advanced scripts for incredibly specific things**

## File server

Script for creating an upload server where uploading isn't password protected but downloading is, useful for collecting exam files.

```powershell
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/RapsyJigo/Script-libraries/refs/heads/main/Upload-Download-Server.ps1').Content)) -Port 80 -UploadFolder '.\uploads' -Password ''
```

## Internet control

Script for blocking internet access except specified IPs, uses simple windows firewall rules so admin users can trivially bypass it. **Make sure to download the unblock script before blocking the internet access otherwise you're stuck. Highly recommend downloading both files before locking / unlocking internet**

```powershell
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/RapsyJigo/Script-libraries/refs/heads/main/Block-Internet-Except-IPs.ps1').Content)) -AllowedIPs '0.0.0.0'
```

These scripts are nto self elevating so make sure to run them as admin

```powershell
.\Block-Internet-Except-IPs.ps1 -AllowedIPs '0.0.0.0, 1.1.1.1'
.\Unblock-Internet.ps1
```

## Download file from web

Downloads a file from the internet and saves it at the specified location

```powershell
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/RapsyJigo/Script-libraries/refs/heads/main/Block-Internet-Except-IPs.ps1').Content)) -Url "https://example.com/report.pdf" -Destination "C:\Downloads"
```
