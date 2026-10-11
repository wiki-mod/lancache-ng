#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: creates the root CA ca.key/ca.crt for HTTPS MITM.
# Why: prod needs own CA; watchdog creates one if absent.
# From: Issue #1683 | PR #1912

# What: exits on error, unset variable or failed pipe.
# Why: an openssl failure must not reach the Done output.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CA_KEY="$SCRIPT_DIR/ca.key"
CA_CRT="$SCRIPT_DIR/ca.crt"

# What: aborts if ca.crt and ca.key both exist.
# Why: regeneration requires deleting both files first.
if [ -f "$CA_CRT" ] && [ -f "$CA_KEY" ]; then
    echo "CA already exists. Delete ca.key and ca.crt first to regenerate."
    exit 1
fi

openssl genrsa -out "$CA_KEY" 4096
openssl req -new -x509 -days 3650 \
    -key "$CA_KEY" \
    -subj "/CN=LanCache-NG CA/O=LanCache-NG/C=DE" \
    -out "$CA_CRT"

# What: ca.key is mode 600, ca.crt mode 644.
# Why: the key stays private; ca.crt goes to clients.
chmod 600 "$CA_KEY"
chmod 644 "$CA_CRT"

echo ""
echo "Done."
echo "  Distribute to clients: $CA_CRT"
echo "  Keep secret:           $CA_KEY"
