#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Real multi-service integration test (issue #400, sub-item of #398 priority
# 1): drives the actual UI -> NATS -> nats-subscriber -> PowerDNS flow
# end-to-end. Adds a LAN DNS record through the real Admin UI HTTP route,
# confirms the NATS message reaches nats-subscriber and lands in PowerDNS via
# a real DNS query, then removes the record the same way and confirms it's
# gone. Reuses the same published-image/health-wait/ephemeral-client pattern
# already proven in scripts/ssl-mitm-cache-simulation.sh.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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
# See ssl-mitm-cache-simulation.sh's identical comment: these must track
# deploy/full-setup/docker-compose.yml's own VALIDATION_*_IP defaults so the
# addresses this script queries match the real container IPs `docker compose
# up` below actually assigns. Falls back to the fixed IPs when unset
# (unchanged behaviour for the manual full-setup-validate.yml); the automatic
# full-setup-deep-validate.yml gate (#715) sets these per-run (Codex review
# finding on #764).
ui_ip="${VALIDATION_UI_IP:-172.30.99.9}"
dns_standard_ip="${VALIDATION_DNS_STANDARD_IP:-172.30.99.3}"
dns_ssl_ip="${VALIDATION_DNS_SSL_IP:-172.30.99.5}"
build_tools_image="${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}"
image_tag="${LANCACHE_IMAGE_TAG:-nightly}"

cleanup() {
    local status=$?
    docker compose -p "$compose_project" -f deploy/full-setup/docker-compose.yml \
        down -v --remove-orphans >/dev/null 2>&1 || true
    # `down` above can lose the "has active endpoints" race (see
    # validation_project_networks_teardown's own comment in reserve-validation-
    # subnet.sh) and silently leave this network non-empty, poisoning it for
    # whichever job/run reserves this slot next -- wait for and force a
    # real removal instead of trusting `down`'s own exit code.
    validation_project_networks_teardown "$compose_project" || true
    rm -rf "$work_dir"
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
        # Under `set -euo pipefail`, a bare `cid="$(cmd)"` with no adjacent
        # check aborts the whole script silently the instant `cmd` fails --
        # errexit fires right at this assignment, before any diagnostic ever
        # prints. Wrap it so a broken `compose ps` invocation (e.g. wrong
        # project name, daemon down) reports its own cause instead of a bare
        # "Process completed with exit code 1".
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

# Each call is a brand new --rm container, so nothing written to a container's
# own /tmp survives past that one call -- confirmed the hard way in
# ssl-mitm-cache-simulation.sh. /shared is bind-mounted from work_dir (a real,
# persistent host directory) so the cookie jar survives across the GET (which
# establishes the session) and the POST (which spends it).
run_client() {
    docker run --rm --network "$network_name" \
        -v "$work_dir/shared:/shared" \
        "$build_tools_image" bash -c "$1"
}

echo "== UI: establishing a session and extracting its CSRF token =="

# basic_auth's middleware issues a fresh session cookie
# (v1.<expires>.<csrf_token>.<signature>, see services/ui/src/session.rs) on
# any request when none is present yet, and requires that same csrf_token
# echoed back on every mutating request -- there is no way to skip this by
# setting ALLOW_INSECURE_UI=true, it only skips Basic Auth. A plain GET
# against a protected route establishes the session; the cookie's third
# dot-separated field is the CSRF token, no HTML scraping required.
run_client "curl -sS -c /shared/cookiejar -o /dev/null 'http://$ui_ip:8080/domains'"
# Under `set -euo pipefail`, a bare `var="$(cmd)"` with no adjacent check
# aborts the whole script silently the instant `cmd` fails -- errexit fires
# right at the assignment, before the "$cookie_value"/"$csrf_token" empty
# checks below ever get a chance to run. Wrap both so a broken awk/cut
# invocation reports its own cause instead of a bare "Process completed with
# exit code 1".
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

# Under `set -euo pipefail`, a bare `var="$(cmd)"` with no adjacent check
# aborts the whole script silently the instant `cmd` fails -- errexit fires
# right at the assignment, before the HTTP-code check below ever runs. Wrap
# it so a broken run_client/docker invocation (as opposed to curl merely
# returning a non-303 status, which the check below already catches) reports
# its own cause instead of a bare "Process completed with exit code 1".
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

# No fixed reload/notify step exists between nats-subscriber's PowerDNS API
# PATCH and a recursor query actually seeing it -- nats-subscriber's pull
# consumer has its own fetch-window latency (up to ~5s worst case), so poll
# instead of sleeping a fixed amount then checking once.
verify_record_resolves() {
    local label="$1"
    local dns_ip="$2"
    local attempt
    for attempt in $(seq 1 10); do
        # Under `set -euo pipefail`, `run_client ... | sort -u` can abort the
        # whole script silently before the resolved-value check below ever
        # runs: pipefail makes the pipeline's exit status reflect run_client's
        # own failure even though `sort -u` always succeeds on its own (it
        # happily sorts zero lines of input) -- wrap the assignment so a
        # failed dig/run_client invocation against this specific $dns_ip is
        # reported explicitly instead of dying with no explanation.
        if ! resolved="$(run_client "dig +time=2 +tries=1 +short @$dns_ip A $test_fqdn" | sort -u)"; then
            echo "::error::Failed to run dig against $label ($dns_ip) for $test_fqdn (run_client/docker invocation failed, attempt $attempt)." >&2
            exit 1
        fi
        [[ "$resolved" = "$test_content" ]] && { echo "$label resolves $test_fqdn to $test_content (attempt $attempt)."; return 0; }
        sleep 1
    done
    echo "::error::$label never resolved $test_fqdn to $test_content after 10 attempts (last saw: '${resolved:-<empty>}')." >&2
    return 1
}

verify_record_resolves "dns-standard" "$dns_standard_ip"
verify_record_resolves "dns-ssl" "$dns_ssl_ip"

echo "== UI: removing the LAN record via POST /domains/lan/remove =="

# Same reasoning as the add_http_code wrap above: catch a broken
# run_client/docker invocation itself, not just a non-303 curl result.
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
    local attempt
    for attempt in $(seq 1 10); do
        # Same pipefail hazard as verify_record_resolves above: wrap so a
        # failed dig/run_client invocation against this specific $dns_ip is
        # reported explicitly instead of silently aborting the script.
        if ! resolved="$(run_client "dig +time=2 +tries=1 +short @$dns_ip A $test_fqdn" | sort -u)"; then
            echo "::error::Failed to run dig against $label ($dns_ip) for $test_fqdn (run_client/docker invocation failed, attempt $attempt)." >&2
            exit 1
        fi
        [[ -z "$resolved" ]] && { echo "$label no longer resolves $test_fqdn (attempt $attempt)."; return 0; }
        sleep 1
    done
    echo "::error::$label still resolves $test_fqdn to '$resolved' after 10 attempts; removal did not take effect." >&2
    return 1
}

verify_record_gone "dns-standard" "$dns_standard_ip"
verify_record_gone "dns-ssl" "$dns_ssl_ip"

echo "ui-nats-dns-integration-simulation passed: UI -> NATS -> nats-subscriber -> PowerDNS add and remove both verified end-to-end via real DNS queries."
