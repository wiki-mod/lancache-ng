#!/bin/bash
# LanCache-NG CA Certificate Installer for Linux
# Usage: sudo ./install-ca-cert.sh [path/to/ca.crt]

set -e

CERT="${1:-$(dirname "$0")/ca.crt}"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Please run as root: sudo $0"
    exit 1
fi

if [ ! -f "$CERT" ]; then
    echo "ERROR: Certificate not found: $CERT"
    echo "Usage: sudo $0 /path/to/ca.crt"
    exit 1
fi

echo "Installing LanCache-NG CA certificate..."

# Detect distro and install accordingly
if [ -f /etc/debian_version ]; then
    # Debian / Ubuntu / Mint / Pop!_OS / SteamOS
    cp "$CERT" /usr/local/share/ca-certificates/lancache-ng.crt
    update-ca-certificates

elif [ -f /etc/fedora-release ] || [ -f /etc/redhat-release ]; then
    # Fedora / RHEL / Rocky / Alma / Nobara
    cp "$CERT" /etc/pki/ca-trust/source/anchors/lancache-ng.crt
    update-ca-trust

elif [ -f /etc/arch-release ]; then
    # Arch / Manjaro / CachyOS / EndeavourOS / Garuda
    cp "$CERT" /etc/ca-certificates/trust-source/anchors/lancache-ng.crt
    trust extract-compat

elif [ -f /etc/SuSE-release ] || [ -f /etc/opensuse-release ]; then
    # openSUSE
    cp "$CERT" /etc/pki/trust/anchors/lancache-ng.crt
    update-ca-certificates

else
    echo "Unknown distribution. Attempting generic install..."
    cp "$CERT" /usr/local/share/ca-certificates/lancache-ng.crt
    update-ca-certificates || true
fi

echo "Done! Certificate installed successfully."
echo "Note: Firefox uses its own certificate store — see docs/install-ca-cert.md."
