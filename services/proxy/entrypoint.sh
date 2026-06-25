#!/bin/bash
set -euo pipefail

CA_DIR="/etc/nginx/ssl/ca"
CERT_DIR="/etc/nginx/ssl/certs"
DOMAINS_FILE="/etc/nginx/cdn-ssl-domains.txt"
SSL_MAP_FILE="/etc/nginx/conf.d/00-ssl-map.conf"
SERIAL_FILE="/tmp/lancache-ca.srl"

# ────────────────────────────────────────────────────────────────────────────
# 0. Validate required environment variables
# ────────────────────────────────────────────────────────────────────────────
IP_STANDARD="${IP_STANDARD:?IP_STANDARD is required}"
IP_SSL="${IP_SSL:-}"
SSL_ENABLED="${SSL_ENABLED:-0}"
NGINX_UPSTREAM_RESOLVER="${NGINX_UPSTREAM_RESOLVER:-8.8.8.8 8.8.4.4}"


_normalize_resolver_token() {
    local token="$1"

    # Nginx accepts IPv6 resolvers in brackets and optional ports for IPv4 or
    # bracketed IPv6. Normalize those forms before comparing against local IPs.
    if [[ "$token" == \[* ]]; then
        token="${token#\[}"
        token="${token%%\]*}"
    elif [[ "$token" == *:* && "$token" != *:*:* ]]; then
        token="${token%%:*}"
    fi

    printf '%s' "$token"
}

for resolver in ${NGINX_UPSTREAM_RESOLVER}; do
    resolver="$(_normalize_resolver_token "$resolver")"
    if [ "$resolver" = "$IP_STANDARD" ] || { [ -n "$IP_SSL" ] && [ "$resolver" = "$IP_SSL" ]; }; then
        echo "[lancache] ERROR: NGINX_UPSTREAM_RESOLVER must not point to a LanCache DNS/proxy IP ($resolver)." >&2
        echo "[lancache] Use a real upstream resolver such as 8.8.8.8, 8.8.4.4, 1.1.1.1, or your upstream/corporate DNS." >&2
        exit 1
    fi
done

export NGINX_UPSTREAM_RESOLVER
# ────────────────────────────────────────────────────────────────────────────
# 1. SSL mode: Generate CA and certs if needed
# ────────────────────────────────────────────────────────────────────────────
if [ "${SSL_ENABLED}" = "1" ]; then
    if [ -z "${IP_SSL}" ]; then
        echo "[lancache] ERROR: SSL_ENABLED=1 but IP_SSL is not set" >&2
        exit 1
    fi

    if [ ! -f "$CA_DIR/ca.crt" ] || [ ! -f "$CA_DIR/ca.key" ]; then
        echo "[lancache] Generating CA certificate (first-time setup)..."
        mkdir -p "$CA_DIR"
        openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
            -subj "/CN=LanCache-NG CA/O=LanCache-NG/C=DE" \
            -keyout "$CA_DIR/ca.key" \
            -out    "$CA_DIR/ca.crt" 2>/dev/null
        echo ""
        echo "╔══════════════════════════════════════════════════════════════════╗"
        echo "║              ACTION REQUIRED — READ BEFORE CONTINUING            ║"
        echo "╠══════════════════════════════════════════════════════════════════╣"
        echo "║                                                                  ║"
        echo "║  A CA certificate has been generated and saved to:               ║"
        echo "║    certs/ca.crt  (in your lancache-ng directory)                 ║"
        echo "║                                                                  ║"
        echo "║  Every client that uses the SSL mode MUST install this           ║"
        echo "║  certificate once. Without it, browsers will show a             ║"
        echo "║  security warning and downloads will fail.                       ║"
        echo "║                                                                  ║"
        echo "║  Instructions per OS: docs/install-ca-cert.md                   ║"
        echo "║                                                                  ║"
        echo "║  This message only appears once. The cert will be reused         ║"
        echo "║  on every subsequent start automatically.                        ║"
        echo "╚══════════════════════════════════════════════════════════════════╝"
        echo ""
    fi

    echo "01" > "$SERIAL_FILE"
    mkdir -p "$CERT_DIR"

    _sign_cert() {
        local cn="$1" key="$2" crt="$3" ext="${4:-}"
        openssl req -new -newkey rsa:2048 -nodes -subj "/CN=${cn}" \
            -keyout "$key" -out /tmp/lancache-cert.csr 2>/dev/null
        if [ -n "$ext" ]; then
            openssl x509 -req -days 3650 \
                -in /tmp/lancache-cert.csr \
                -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" -CAserial "$SERIAL_FILE" \
                -extfile <(printf "%s" "$ext") \
                -out "$crt" 2>/dev/null
        else
            openssl x509 -req -days 3650 \
                -in /tmp/lancache-cert.csr \
                -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" -CAserial "$SERIAL_FILE" \
                -out "$crt" 2>/dev/null
        fi
        rm -f /tmp/lancache-cert.csr
    }

    [ ! -f "$CERT_DIR/default.crt" ] && \
        _sign_cert "lancache-default" "$CERT_DIR/default.key" "$CERT_DIR/default.crt"

    while IFS= read -r domain || [ -n "$domain" ]; do
        [[ -z "$domain" || "$domain" == \#* ]] && continue
        [ -f "$CERT_DIR/${domain}.crt" ] && continue

        echo "[lancache] Generating cert for $domain..."
        _sign_cert "$domain" \
            "$CERT_DIR/${domain}.key" \
            "$CERT_DIR/${domain}.crt" \
            "subjectAltName=DNS:${domain},DNS:*.${domain}"
    done < "$DOMAINS_FILE"

    {
        echo "# Auto-generated by entrypoint — do not edit"
        echo "map \$ssl_server_name \$ssl_cert_name {"
        echo "    hostnames;"
        while IFS= read -r domain || [ -n "$domain" ]; do
            [[ -z "$domain" || "$domain" == \#* ]] && continue
            printf "    %-45s %s;\n" ".$domain"  "$domain"
        done < "$DOMAINS_FILE"
        echo "    default default;"
        echo "}"
    } > "$SSL_MAP_FILE"
fi

# ────────────────────────────────────────────────────────────────────────────
# 2. Remove https.conf when SSL mode is disabled
#    (Docker routes IP_SSL:443→container:443 and IP_STANDARD:443→container:8443,
#    so https.conf can safely listen on 0.0.0.0:443 — only SSL clients reach it)
# ────────────────────────────────────────────────────────────────────────────
if [ "${SSL_ENABLED}" = "0" ]; then
    rm -f /etc/nginx/conf.d/https.conf
fi

# ────────────────────────────────────────────────────────────────────────────
# 3. Render nginx.conf and proxy-params from templates
# ────────────────────────────────────────────────────────────────────────────
envsubst '${CACHE_MEM_MB} ${CACHE_MAX_SIZE} ${CACHE_INACTIVE} ${NGINX_UPSTREAM_RESOLVER}' \
    < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

envsubst '${CACHE_SLICE_SIZE} ${CACHE_VALID_HIT} ${CACHE_VALID_ANY}' \
    < /etc/nginx/proxy-params.conf.template > /etc/nginx/proxy-params.conf

# ────────────────────────────────────────────────────────────────────────────
# 4. Validate config and start nginx
# ────────────────────────────────────────────────────────────────────────────
echo "[lancache] Validating nginx config..."
nginx -t

echo "[lancache] Starting nginx (IP_STANDARD=${IP_STANDARD}, SSL_ENABLED=${SSL_ENABLED})..."
exec nginx -g "daemon off;"
