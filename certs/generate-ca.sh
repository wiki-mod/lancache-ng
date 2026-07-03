#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# Generates the LAN cache's root CA (ca.key/ca.crt) used to sign per-domain
# wildcard certs for SSL interception (MITM) mode.
#
# Run this once to generate a CA certificate for SSL interception.
# The proxy auto-generates one if this is missing (dev convenience).
# In prod, use this to generate a dedicated CA and keep ca.key secret.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CA_KEY="$SCRIPT_DIR/ca.key"
CA_CRT="$SCRIPT_DIR/ca.crt"

if [ -f "$CA_CRT" ] && [ -f "$CA_KEY" ]; then
    echo "CA already exists. Delete ca.key and ca.crt first to regenerate."
    exit 1
fi

openssl genrsa -out "$CA_KEY" 4096
openssl req -new -x509 -days 3650 \
    -key "$CA_KEY" \
    -subj "/CN=LanCache CA/O=LanCache/C=DE" \
    -out "$CA_CRT"

chmod 600 "$CA_KEY"
chmod 644 "$CA_CRT"

echo ""
echo "Done."
echo "  Distribute to clients: $CA_CRT"
echo "  Keep secret:           $CA_KEY"
