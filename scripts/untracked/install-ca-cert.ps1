
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: installs CA cert into LocalMachine Root store
# Why: MITM-intercepted downloads must trust the LAN CA

# What: default ca.crt path is the script's own folder
# Why: the CA file is copied next to the script
param(
    [string]$CertPath = "$PSScriptRoot\ca.crt"
)

# What: pauses, then exits 1 unless run as Administrator
# Why: writing to LocalMachine\Root requires elevation
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Please run this script as Administrator." -ForegroundColor Red
    Write-Host "Right-click the script and select 'Run as Administrator'."
    pause
    exit 1
}

# What: pauses, then exits 1 when CertPath does not exist
# Why: gives a specific message instead of a load error
if (-not (Test-Path $CertPath)) {
    Write-Host "ERROR: Certificate not found at: $CertPath" -ForegroundColor Red
    Write-Host "Copy ca.crt to the same folder as this script, then run again."
    pause
    exit 1
}

Write-Host "Installing LanCache-NG CA certificate..." -ForegroundColor Cyan

# What: adds the cert to LocalMachine Root store
# Why: LocalMachine scope applies the trust to all users
try {
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertPath)
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
    $store.Open("ReadWrite")
    $store.Add($cert)
    $store.Close()
    Write-Host "Done! Certificate installed successfully." -ForegroundColor Green
    Write-Host "Restart your browser if it was open."
} catch {
    # What: prints the error text, pauses, exits 1
    # Why: error text stays visible until a key press
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    pause
    exit 1
}

# What: waits for a key press after success
# Why: keeps the success message readable in its window
pause
