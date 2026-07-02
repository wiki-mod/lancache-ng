#!/bin/bash
set -euo pipefail

CA_DIR="/etc/nginx/ssl/ca"
CERT_DIR="/etc/nginx/ssl/certs"
DOMAINS_FILE="/etc/nginx/cdn-ssl-domains.txt"
SSL_MAP_FILE="/etc/nginx/conf.d/00-ssl-map.conf"
STREAM_TARGET_FILE="/etc/nginx/stream.d/00-stream-targets.conf"
PROXY_SECURITY_MODE="${PROXY_SECURITY_MODE:-strict}"

# ────────────────────────────────────────────────────────────────────────────
# 0. Validate required environment variables
# ────────────────────────────────────────────────────────────────────────────
IP_STANDARD="${IP_STANDARD:?IP_STANDARD is required}"
IP_SSL="${IP_SSL:-}"
SSL_ENABLED="${SSL_ENABLED:-0}"
NGINX_UPSTREAM_RESOLVER="${NGINX_UPSTREAM_RESOLVER:-8.8.8.8 8.8.4.4}"
PROXY_SECURITY_MODE="${PROXY_SECURITY_MODE:-lazy}"
PROXY_ALLOWED_CLIENT_CIDRS="${PROXY_ALLOWED_CLIENT_CIDRS:-}"


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

# ────────────────────────────────────────────────────────────────────────────
# Domain validation: Mirrors the label-strict rules from Admin UI (domains.rs)
# to prevent invalid domains from being used in nginx maps, cert generation,
# and stream targets. Validation follows RFC 1035 and DNS best practices:
#
#   - Max 253 chars total length
#   - Min 2 labels (no single-label domains like "localhost")
#   - Each label: 1-63 chars, start/end with alphanumeric, contain only a-z/0-9/-
#   - Leading dot is stripped (optional in file notation)
#   - Input is trimmed and lowercased before validation
#   - Control characters and special chars are rejected
# ────────────────────────────────────────────────────────────────────────────

_is_valid_domain_label() {
    local label="$1"

    # Label must not be empty
    [ -n "$label" ] || return 1

    # Label must be <= 63 chars
    [ ${#label} -le 63 ] || return 1

    # Label must not start or end with hyphen
    [[ "$label" != -* ]] && [[ "$label" != *- ]] || return 1

    # Label must only contain lowercase ASCII a-z, digits 0-9, or hyphen
    [[ "$label" =~ ^[a-z0-9-]+$ ]] || return 1

    return 0
}

# Prints the normalized form (trimmed, lowercased, leading dot stripped) of a
# domain to stdout. Callers must capture this and use it instead of the raw
# input for anything written to disk/config — _is_valid_domain() only reports
# whether a value validates, it does not mutate the caller's variable.
_normalize_domain() {
    local domain="$1"
    # Trim whitespace via pure parameter expansion, not xargs — xargs applies
    # shell-style unquoting/escaping first, which would let malformed manual
    # entries like a quoted "Example.COM" slip through as a clean example.com.
    domain="${domain#"${domain%%[![:space:]]*}"}"
    domain="${domain%"${domain##*[![:space:]]}"}"
    domain="${domain,,}"
    domain="${domain#.}"
    printf '%s' "$domain"
}

_is_valid_domain() {
    local domain
    domain="$(_normalize_domain "$1")"

    # Must not be empty after normalization
    [ -n "$domain" ] || return 1

    # Must be <= 253 chars total
    [ ${#domain} -le 253 ] || return 1

    # Check for trailing dot (RFC 1035 allows it, but we reject it like the Rust validator does)
    [[ "$domain" != *. ]] || return 1

    # Validate each label using a loop to properly handle empty labels
    # (bash word splitting would silently drop trailing empty labels,
    # but we want to reject domains like "example.com." explicitly)
    local label
    local remaining="$domain"

    while [ -n "$remaining" ]; do
        # Extract label up to next dot
        if [[ "$remaining" == *.* ]]; then
            label="${remaining%%.*}"
            remaining="${remaining#*.}"
        else
            label="$remaining"
            remaining=""
        fi

        _is_valid_domain_label "$label" || return 1
    done

    # Must have at least 2 labels (so the loop must execute at least twice)
    # We can check this by ensuring the domain contains at least one dot
    [[ "$domain" == *.* ]] || return 1

    return 0
}

for resolver in ${NGINX_UPSTREAM_RESOLVER}; do
    resolver="$(_normalize_resolver_token "$resolver")"
    if [ "$resolver" = "$IP_STANDARD" ] || { [ -n "$IP_SSL" ] && [ "$resolver" = "$IP_SSL" ]; }; then
        echo "[lancache] ERROR: NGINX_UPSTREAM_RESOLVER must not point to a LanCache DNS/proxy IP ($resolver)." >&2
        echo "[lancache] Use a real upstream resolver such as 8.8.8.8, 8.8.4.4, 1.1.1.1, or your upstream/corporate DNS." >&2
        exit 1
    fi
done

case "$PROXY_SECURITY_MODE" in
    lazy|strict) ;;
    *)
        echo "[lancache] ERROR: PROXY_SECURITY_MODE must be lazy or strict (got: $PROXY_SECURITY_MODE)." >&2
        exit 1
        ;;
esac

export NGINX_UPSTREAM_RESOLVER PROXY_SECURITY_MODE PROXY_ALLOWED_CLIENT_CIDRS
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
        if ! openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
            -subj "/CN=LanCache-NG CA/O=LanCache-NG/C=DE" \
            -keyout "$CA_DIR/ca.key" \
            -out    "$CA_DIR/ca.crt"; then
            echo "[lancache] ERROR: Failed to generate CA certificate" >&2
            exit 1
        fi
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

    worker_user=$(awk '$1 == "user" {gsub(/;/, "", $2); print $2; exit}' /etc/nginx/nginx.conf.template)
    worker_user="${worker_user:-nginx}"

    mkdir -p "$CERT_DIR"
    chgrp "$worker_user" "$CERT_DIR"
    chmod 2750 "$CERT_DIR"

    # Persist the serial counter in the CA volume so it survives container restarts (#71).
    # Initialized with a nanosecond timestamp on first use to avoid colliding with any
    # serials that were issued under the old "echo 01" scheme.
    SERIAL_FILE="$CA_DIR/ca.srl"
    if [ ! -f "$SERIAL_FILE" ]; then
        printf '%016x\n' "$(date +%s%N)" > "$SERIAL_FILE"
    fi

    _sign_cert() {
        local cn="$1" key="$2" crt="$3" ext="${4:-}"
        if ! openssl req -new -newkey rsa:2048 -nodes -subj "/CN=${cn}" \
            -keyout "$key" -out /tmp/lancache-cert.csr; then
            rm -f /tmp/lancache-cert.csr
            echo "[lancache] ERROR: Failed to generate certificate request for ${cn}" >&2
            return 1
        fi
        if [ -n "$ext" ]; then
            if ! openssl x509 -req -days 3650 \
                -in /tmp/lancache-cert.csr \
                -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" -CAserial "$SERIAL_FILE" \
                -extfile <(printf "%s" "$ext") \
                -out "$crt"; then
                rm -f /tmp/lancache-cert.csr
                echo "[lancache] ERROR: Failed to sign certificate for ${cn}" >&2
                return 1
            fi
        else
            if ! openssl x509 -req -days 3650 \
                -in /tmp/lancache-cert.csr \
                -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" -CAserial "$SERIAL_FILE" \
                -out "$crt"; then
                rm -f /tmp/lancache-cert.csr
                echo "[lancache] ERROR: Failed to sign certificate for ${cn}" >&2
                return 1
            fi
        fi
        rm -f /tmp/lancache-cert.csr
    }

    # Returns 0 (true = needs regen) if the default cert:
    #   - is missing (#72)
    #   - has no matching key (partial generation state)
    #   - has no SAN at all (CN-only cert from old deployments, #72)
    #   - has an IP SAN that does not match the current IP_SSL (operator changed IP)
    _default_cert_needs_regen() {
        if [ ! -f "$CERT_DIR/default.crt" ] || [ ! -f "$CERT_DIR/default.key" ]; then
            return 0
        fi
        local san
        san=$(openssl x509 -noout -ext subjectAltName -in "$CERT_DIR/default.crt" 2>/dev/null)
        echo "$san" | grep -q "DNS:" || return 0
        if [ -n "${IP_SSL}" ]; then
            echo "$san" | grep -q "IP Address:${IP_SSL}" || return 0
        fi
        return 1
    }

    if _default_cert_needs_regen; then
        # Generate or regenerate the fallback cert with a proper SAN (#72).
        # Include IP_SSL in the SAN so clients connecting to that IP also pass validation.
        _default_san="DNS:lancache-default"
        [ -n "${IP_SSL}" ] && _default_san="${_default_san},IP:${IP_SSL}"
        if ! _sign_cert "lancache-default" "$CERT_DIR/default.key" "$CERT_DIR/default.crt" \
            "subjectAltName=${_default_san}"; then
            echo "[lancache] ERROR: Failed to generate default certificate" >&2
            exit 1
        fi
    fi
    while IFS= read -r domain || [ -n "$domain" ]; do
        [[ -z "$domain" || "$domain" == \#* ]] && continue

        # Validate and normalize domain before using it in cert generation or filenames
        if ! _is_valid_domain "$domain"; then
            echo "[lancache] WARNING: skipping invalid domain entry: $domain" >&2
            continue
        fi
        domain="$(_normalize_domain "$domain")"

        [ -f "$CERT_DIR/${domain}.crt" ] && [ -f "$CERT_DIR/${domain}.key" ] && continue

        echo "[lancache] Generating cert for $domain..."
        if ! _sign_cert "$domain" \
            "$CERT_DIR/${domain}.key" \
            "$CERT_DIR/${domain}.crt" \
            "subjectAltName=DNS:${domain},DNS:*.${domain}"; then
            echo "[lancache] ERROR: Failed to generate certificate for domain $domain" >&2
            exit 1
        fi
    done < "$DOMAINS_FILE"

    # Keep new keys in the nginx group and make existing/generated keys readable
    # by nginx workers during TLS handshakes.
    if ! chgrp "$worker_user" "$CERT_DIR" || ! find "$CERT_DIR" -type f -name '*.key' -exec chgrp "$worker_user" {} + -exec chmod 0640 {} +; then
        echo "[lancache] ERROR: Failed to set certificate key permissions" >&2
        exit 1
    fi
    find "$CERT_DIR" -type f -name '*.crt' -exec chmod 0644 {} +
fi

# ────────────────────────────────────────────────────────────────────────────
# 2. Generate request-time access policy maps
#    lazy  = keep historical behavior and allow any requested upstream host
#    strict = only proxy hosts listed in cdn-ssl-domains.txt
# ────────────────────────────────────────────────────────────────────────────
{
    echo "# Auto-generated by entrypoint — do not edit"
    echo "map \$ssl_server_name \$ssl_cert_name {"
    echo "    hostnames;"
    while IFS= read -r domain || [ -n "$domain" ]; do
        [[ -z "$domain" || "$domain" == \#* ]] && continue

        # Validate and normalize domain before using it in nginx map entries
        if ! _is_valid_domain "$domain"; then
            echo "[lancache] WARNING: skipping invalid domain entry: $domain" >&2
            continue
        fi
        domain="$(_normalize_domain "$domain")"

        printf "    %-45s %s;\n" ".$domain"  "$domain"
    done < "$DOMAINS_FILE"
    echo "    default default;"
    echo "}"

    echo ""
    echo "map \$host \$cdn_host_allowed {"
    echo "    hostnames;"
    if [ "$PROXY_SECURITY_MODE" = "strict" ]; then
        echo "    default 0;"
        while IFS= read -r domain || [ -n "$domain" ]; do
            [[ -z "$domain" || "$domain" == \#* ]] && continue

            # Validate and normalize domain before using it in nginx map entries
            if ! _is_valid_domain "$domain"; then
                echo "[lancache] WARNING: skipping invalid domain entry: $domain" >&2
                continue
            fi
            domain="$(_normalize_domain "$domain")"

            printf "    %-45s 1;\n" ".$domain"
        done < "$DOMAINS_FILE"
    else
        echo "    default 1;"
    fi
    echo "}"

    echo ""
    echo "geo \$lancache_client_allowed {"
    if [ -n "$PROXY_ALLOWED_CLIENT_CIDRS" ]; then
        echo "    default 0;"
        for cidr in $PROXY_ALLOWED_CLIENT_CIDRS; do
            printf "    %-45s 1;\n" "$cidr"
        done
    else
        echo "    default 1;"
    fi
    echo "}"
} > "$SSL_MAP_FILE"

mkdir -p /etc/nginx/stream.d

{
    echo "# Auto-generated by entrypoint — do not edit"
    echo "map \$ssl_preread_server_name \$stream_backend {"
    echo "    hostnames;"
    if [ "$PROXY_SECURITY_MODE" = "lazy" ]; then
        echo "    default \$ssl_preread_server_name:443;"
    else
        echo "    default 127.0.0.1:9;"
        while IFS= read -r domain || [ -n "$domain" ]; do
            [[ -z "$domain" || "$domain" == \#* ]] && continue

            # Validate and normalize domain before using it in stream target entries
            if ! _is_valid_domain "$domain"; then
                echo "[lancache] WARNING: skipping invalid domain entry: $domain" >&2
                continue
            fi
            domain="$(_normalize_domain "$domain")"

            printf "    %-45s %s:443;\n" ".$domain" "$domain"
        done < "$DOMAINS_FILE"
    fi
    echo "}"
} > "$STREAM_TARGET_FILE"

# ────────────────────────────────────────────────────────────────────────────
# 3. Remove https.conf when SSL mode is disabled
#    (Docker routes IP_SSL:443→container:443 and IP_STANDARD:443→container:8443,
#    so https.conf can safely listen on 0.0.0.0:443 — only SSL clients reach it)
# ────────────────────────────────────────────────────────────────────────────
if [ "${SSL_ENABLED}" = "0" ]; then
    rm -f /etc/nginx/conf.d/https.conf
fi

# ────────────────────────────────────────────────────────────────────────────
# 4. Render nginx.conf and proxy-params from templates
# ────────────────────────────────────────────────────────────────────────────
envsubst '${CACHE_MEM_MB} ${CACHE_MAX_SIZE} ${CACHE_INACTIVE} ${NGINX_UPSTREAM_RESOLVER}' \
    < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

envsubst '${CACHE_SLICE_SIZE} ${CACHE_VALID_HIT} ${CACHE_VALID_ANY}' \
    < /etc/nginx/proxy-params.conf.template > /etc/nginx/proxy-params.conf

# ────────────────────────────────────────────────────────────────────────────
# 5. Validate config and start nginx
# ────────────────────────────────────────────────────────────────────────────
echo "[lancache] Validating nginx config..."
nginx -t

echo "[lancache] Starting nginx (IP_STANDARD=${IP_STANDARD}, SSL_ENABLED=${SSL_ENABLED})..."
exec nginx -g "daemon off;"
