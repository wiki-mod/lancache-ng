#!/bin/bash
set -euo pipefail

envsubst '${CACHE_MEM_MB} ${CACHE_MAX_SIZE} ${CACHE_INACTIVE}' \
    < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

echo "[lancache-standard] Validating nginx config..."
nginx -t

echo "[lancache-standard] Starting nginx..."
exec nginx -g "daemon off;"
