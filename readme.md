# **A collection of more advanced scripts for incredibly specific things**

Script for creating an upload server where uploading isn't password protected but downloading is, useful for collecting exam files.

```
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/RapsyJigo/Script-libraries/refs/heads/main/Upload-Download-Server.ps1').Content)) -Port 80 -UploadFolder '.\uploads' -Password 'changeme'
```
