#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: drives UI -> NATS -> PowerDNS end-to-end
# Why: validate LAN DNS add/remove end-to-end
# From: Issue #400
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$repo_root"

# shellcheck source=scripts/lib/reserve-validation-subnet.sh
source "$repo_root/scripts/lib/reserve-validation-subnet.sh"

test_name="issue400-test"
test_fqdn="${test_name}.lan."
test_content="203.0.113.55"
work_dir="$repo_root/.ui-nats-dns-simulation-tmp"
rm -rf "$work_dir"
mkdir -p "$work_dir/shared"

compose_project="${COMPOSE_PROJECT_NAME:-lancache-ng-validation}"
network_name="${compose_project}_validation"
# What: track docker-compose.yml's VALIDATION_*_IP defaults
# Why: script queries must match actual container IPs
# From: PR #715
ui_ip="${VALIDATION_UI_IP:-172.30.99.9}"
dns_standard_ip="${VALIDATION_DNS_STANDARD_IP:-172.30.99.3}"
dns_ssl_ip="${VALIDATION_DNS_SSL_IP:-172.30.99.5}"
build_tools_image="${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}"
image_tag="${LANCACHE_IMAGE_TAG:-nightly}"

cleanup() {
    local status=$?
    validation_simulation_teardown "$compose_project" "$work_dir"
    exit "$status"
}
trap cleanup EXIT

echo "== Starting proxy/docker-socket-proxy/dns-standard/dns-ssl/nats/ui from the published $image_tag images =="

# ui's own healthcheck (depends_on: docker-socket-proxy, proxy, nats) needs
# all three running first, or it never reaches a healthy state.
LANCACHE_IMAGE_TAG="$image_tag" \
    docker compose -p "$compose_project" -f deploy/full-setup/docker-compose.yml \
    up -d proxy docker-socket-proxy dns-standard dns-ssl nats ui

# Mirrors the health-wait pattern already proven in ssl-mitm-cache-simulation.sh.
compose=(docker compose -p "$compose_project" -f deploy/full-setup/docker-compose.yml)
deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
    all_ready=1
    for service in proxy dns-standard dns-ssl ui; do
        # What: wrap assignment to avoid silent errexit
        # Why: bare `cid="$(cmd)"` aborts if cmd fails
        if ! cid="$("${compose[@]}" ps -q "$service")"; then
            echo "::error::Could not query the compose container id for service '$service'." >&2
            exit 1
        fi
        status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown")"
        [[ "$status" = "healthy" ]] || all_ready=0
    done
    [[ "$all_ready" -eq 1 ]] && break
    sleep 5
done
for service in proxy dns-standard dns-ssl ui; do
    if ! cid="$("${compose[@]}" ps -q "$service")"; then
        echo "::error::Could not query the compose container id for service '$service'." >&2
        exit 1
    fi
    status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown")"
    if [[ "$status" != "healthy" ]]; then
        echo "::error::$service did not become healthy (status: $status)" >&2
        "${compose[@]}" logs --no-color "$service"
        exit 1
    fi
done
echo "proxy, dns-standard, dns-ssl, and ui are healthy."

# What: bind-mount /shared for cookie jar persistence
# Why: per-container /tmp is ephemeral across GET/POST calls
run_client() {
    docker run --rm --network "$network_name" \
        -v "$work_dir/shared:/shared" \
        "$build_tools_image" timeout --kill-after=30 --signal=KILL 120 bash -c "$1"
}

echo "== UI: establishing a session and extracting its CSRF token =="

# What: basic_auth issues session cookie with CSRF token
# Why: mutating requests require CSRF token echoed back
run_client "curl -sS -c /shared/cookiejar -o /dev/null 'http://$ui_ip:8080/domains'"
# What: wrap assignments to avoid silent errexit
# Why: bare `var="$(cmd)"` aborts if cmd fails
if ! cookie_value="$(awk -F'\t' '$6 == "lancache_ui_session" {print $7}' "$work_dir/shared/cookiejar")"; then
    echo "::error::Failed to read the session cookie from $work_dir/shared/cookiejar (awk invocation failed)." >&2
    exit 1
fi
if [[ -z "$cookie_value" ]]; then
    echo "::error::No lancache_ui_session cookie was set by GET /domains." >&2
    exit 1
fi
if ! csrf_token="$(cut -d. -f3 <<<"$cookie_value")"; then
    echo "::error::Failed to extract the CSRF token from the session cookie (cut invocation failed)." >&2
    exit 1
fi
if [[ -z "$csrf_token" ]]; then
    echo "::error::Could not extract a CSRF token from the session cookie." >&2
    exit 1
fi
echo "Session established, CSRF token extracted."

echo "== UI: adding a real LAN record via POST /domains/lan/add =="

# What: wrap run_client invocation to catch docker errors
# Why: distinguish docker failures from curl non-303 results
if ! add_http_code="$(run_client "curl -sS -b /shared/cookiejar -o /shared/add-response -w '%{http_code}' \
    --data-urlencode 'csrf_token=$csrf_token' \
    --data-urlencode 'name=$test_name' \
    --data-urlencode 'record_type=A' \
    --data-urlencode 'content=$test_content' \
    --data-urlencode 'ttl=60' \
    'http://$ui_ip:8080/domains/lan/add'")"; then
    echo "::error::POST /domains/lan/add via run_client failed outright (curl/docker invocation error)." >&2
    exit 1
fi
if [[ "$add_http_code" != "303" ]]; then
    echo "::error::POST /domains/lan/add returned HTTP $add_http_code, expected 303 (redirect to /domains)." >&2
    exit 1
fi
echo "UI accepted the record add (303 redirect)."

echo "== Verifying the record reached PowerDNS via NATS -> nats-subscriber =="

# What: polls up to $3 times instead of fixed sleep
# Why: AXFR polling takes ~15-20s, not real-time
# From: Issue #1164 | PR #1667
verify_record_resolves() {
    local label="$1"
    local dns_ip="$2"
    local max_attempts="${3:-10}"
    local attempt
    for attempt in $(seq 1 "$max_attempts"); do
        # What: wrap pipeline to catch errexit
        # Why: pipefail aborts if any pipeline command fails
        if ! resolved="$(run_client "dig +time=2 +tries=1 +short @$dns_ip A $test_fqdn" | sort -u)"; then
            echo "::error::Failed to run dig against $label ($dns_ip) for $test_fqdn (run_client/docker invocation failed, attempt $attempt)." >&2
            exit 1
        fi
        [[ "$resolved" = "$test_content" ]] && { echo "$label resolves $test_fqdn to $test_content (attempt $attempt)."; return 0; }
        sleep 1
    done
    echo "::error::$label never resolved $test_fqdn to $test_content after $max_attempts attempts (last saw: '${resolved:-<empty>}')." >&2
    # What: dump dns-standard/dns-ssl/nats logs on failure
    # Why: teardown runs before logs are otherwise visible
    # From: PR #1775
    "${compose[@]}" logs --no-color --tail=200 dns-standard dns-ssl nats >&2 || true
    # What: show dns-ssl's IP address for verification
    # Why: verify ALSO-NOTIFY reached dns-ssl's actual IP
    # From: PR #1775
    "${compose[@]}" exec -T dns-standard sh -c \
        'pdnsutil --config-dir=/etc/pdns/auth get-meta lan ALSO-NOTIFY' >&2 || true
    "${compose[@]}" exec -T dns-ssl sh -c \
        'echo "dns-ssl own address:"; ip -4 -o addr show scope global 2>/dev/null' >&2 || true
    return 1
}

verify_record_resolves "dns-standard" "$dns_standard_ip"
verify_record_resolves "dns-ssl" "$dns_ssl_ip" 180

echo "== UI: removing the LAN record via POST /domains/lan/remove =="

# What: wrap run_client invocation to catch docker errors
# Why: distinguish docker failures from curl non-303 results
if ! remove_http_code="$(run_client "curl -sS -b /shared/cookiejar -o /shared/remove-response -w '%{http_code}' \
    --data-urlencode 'csrf_token=$csrf_token' \
    --data-urlencode 'name=$test_name' \
    --data-urlencode 'record_type=A' \
    --data-urlencode 'content=$test_content' \
    'http://$ui_ip:8080/domains/lan/remove'")"; then
    echo "::error::POST /domains/lan/remove via run_client failed outright (curl/docker invocation error)." >&2
    exit 1
fi
if [[ "$remove_http_code" != "303" ]]; then
    echo "::error::POST /domains/lan/remove returned HTTP $remove_http_code, expected 303 (redirect to /domains)." >&2
    exit 1
fi
echo "UI accepted the record removal (303 redirect)."

echo "== Verifying the record actually disappeared from PowerDNS =="

verify_record_gone() {
    local label="$1"
    local dns_ip="$2"
    local max_attempts="${3:-10}"
    local attempt
    for attempt in $(seq 1 "$max_attempts"); do
        # What: wrap dig/run_client to avoid silent errexit
        # Why: failed invocation must report explicitly
        if ! resolved="$(run_client "dig +time=2 +tries=1 +short @$dns_ip A $test_fqdn" | sort -u)"; then
            echo "::error::Failed to run dig against $label ($dns_ip) for $test_fqdn (run_client/docker invocation failed, attempt $attempt)." >&2
            exit 1
        fi
        [[ -z "$resolved" ]] && { echo "$label no longer resolves $test_fqdn (attempt $attempt)."; return 0; }
        sleep 1
    done
    echo "::error::$label still resolves $test_fqdn to '$resolved' after $max_attempts attempts; removal did not take effect." >&2
    "${compose[@]}" logs --no-color --tail=200 dns-standard dns-ssl nats >&2 || true
    return 1
}

verify_record_gone "dns-standard" "$dns_standard_ip"
verify_record_gone "dns-ssl" "$dns_ssl_ip" 180

echo "ui-nats-dns-integration-simulation passed: UI -> NATS -> nats-subscriber -> PowerDNS add and remove both verified end-to-end via real DNS queries."
