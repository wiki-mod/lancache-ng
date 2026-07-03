# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# Installs the LAN cache's CA certificate into the Windows Local Machine
# "Root" trust store so SSL-intercepted (MITM) downloads are trusted by this
# Windows client. Must be run elevated (Administrator).
# LanCache-NG CA Certificate Installer for Windows
# Run as Administrator: Right-click -> "Run with PowerShell" -> Yes

param(
    [string]$CertPath = "$PSScriptRoot\ca.crt"
)

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Please run this script as Administrator." -ForegroundColor Red
    Write-Host "Right-click the script and select 'Run as Administrator'."
    pause
    exit 1
}

if (-not (Test-Path $CertPath)) {
    Write-Host "ERROR: Certificate not found at: $CertPath" -ForegroundColor Red
    Write-Host "Copy ca.crt to the same folder as this script, then run again."
    pause
    exit 1
}

Write-Host "Installing LanCache-NG CA certificate..." -ForegroundColor Cyan

try {
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertPath)
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
    $store.Open("ReadWrite")
    $store.Add($cert)
    $store.Close()
    Write-Host "Done! Certificate installed successfully." -ForegroundColor Green
    Write-Host "Restart your browser if it was open."
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    pause
    exit 1
}

pause
