#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Real multi-service integration test for issue #583 (per-secondary NATS
# identity via auth callout, per #433's "finish the originally-intended
# design" decision). Drives the actual Admin UI HTTP routes and a real
# nats-server + nats-subscriber to prove the property the issue asks for:
#
#   - Two independently registered secondaries each get a genuinely unique,
#     working NATS credential (not the old shared DNS-reader token).
#   - Removing one secondary (DELETE /api/secondary/{name}) revokes exactly
#     that secondary's NATS access on its very next connection attempt --
#     with zero impact on a different, still-registered secondary.
#   - Rotating a secondary's credential (POST .../rotate-token) invalidates
#     the old credential immediately while issuing a new one that works.
#
# Reuses the same published-image/health-wait/ephemeral-client pattern
# already proven in ssl-mitm-cache-simulation.sh and
# ui-nats-dns-integration-simulation.sh.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# shellcheck source=scripts/lib/reserve-validation-subnet.sh
source "$repo_root/scripts/lib/reserve-validation-subnet.sh"

work_dir="$repo_root/.nats-auth-callout-simulation-tmp"
rm -rf "$work_dir"
mkdir -p "$work_dir/shared"

compose_project="${COMPOSE_PROJECT_NAME:-lancache-ng-validation}-auth-callout"
network_name="${compose_project}_validation"
# See ssl-mitm-cache-simulation.sh's identical comment: must track
# deploy/full-setup/docker-compose.yml's own VALIDATION_UI_IP default so this
# matches the real ui container IP `docker compose up` below assigns. Falls
# back to the fixed IP when unset (manual full-setup-validate.yml); the
# automatic full-setup-deep-validate.yml gate (#715) sets it per-run (Codex
# review finding on #764).
ui_ip="${VALIDATION_UI_IP:-172.30.99.9}"
registration_token="validation-secondary-registration-token"
build_tools_image="${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}"
image_tag="${LANCACHE_IMAGE_TAG:-edge}"
dns_image="${LANCACHE_IMAGE_REGISTRY:-ghcr.io}/${LANCACHE_IMAGE_PREFIX:-wiki-mod/lancache-ng}/dns:${image_tag}"

cleanup() {
    local status=$?
    docker compose -p "$compose_project" -f deploy/full-setup/docker-compose.yml \
        down -v --remove-orphans >/dev/null 2>&1 || true
    # `down` above can lose the "has active endpoints" race (see
    # validation_project_networks_teardown's own comment in reserve-validation-
    # subnet.sh) and silently leave this network non-empty, poisoning it for
    # whichever job/run reserves this octet next -- wait for and force a
    # real removal instead of trusting `down`'s own exit code.
    validation_project_networks_teardown "$compose_project" || true
    rm -rf "$work_dir"
    exit "$status"
}
trap cleanup EXIT

echo "== Starting proxy/docker-socket-proxy/dns-standard/dns-ssl/nats/ui from the published $image_tag images =="

LANCACHE_IMAGE_TAG="$image_tag" \
    docker compose -p "$compose_project" -f deploy/full-setup/docker-compose.yml \
    up -d proxy docker-socket-proxy dns-standard dns-ssl nats ui

compose=(docker compose -p "$compose_project" -f deploy/full-setup/docker-compose.yml)
deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
    all_ready=1
    for service in proxy dns-standard dns-ssl ui; do
        cid="$("${compose[@]}" ps -q "$service")"
        status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown")"
        [[ "$status" = "healthy" ]] || all_ready=0
    done
    [[ "$all_ready" -eq 1 ]] && break
    sleep 5
done
for service in proxy dns-standard dns-ssl ui; do
    cid="$("${compose[@]}" ps -q "$service")"
    status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown")"
    if [[ "$status" != "healthy" ]]; then
        echo "::error::$service did not become healthy (status: $status)" >&2
        "${compose[@]}" logs --no-color "$service"
        exit 1
    fi
done
echo "proxy, dns-standard, dns-ssl, and ui are healthy."

run_client() {
    docker run --rm --network "$network_name" \
        -v "$work_dir/shared:/shared" \
        "$build_tools_image" bash -c "$1"
}

echo "== UI: establishing a session and extracting its CSRF token =="

run_client "curl -sS -c /shared/cookiejar -o /dev/null 'http://$ui_ip:8080/secondaries'"
cookie_value="$(awk -F'\t' '$6 == "lancache_ui_session" {print $7}' "$work_dir/shared/cookiejar")"
if [[ -z "$cookie_value" ]]; then
    echo "::error::No lancache_ui_session cookie was set by GET /secondaries." >&2
    exit 1
fi
csrf_token="$(cut -d. -f3 <<<"$cookie_value")"
if [[ -z "$csrf_token" ]]; then
    echo "::error::Could not extract a CSRF token from the session cookie." >&2
    exit 1
fi
echo "Session established, CSRF token extracted."

# Registers a secondary via the real, public (token-authenticated, no
# session/CSRF needed) /api/secondary/register route, exactly as setup.sh's
# `secondary` subcommand does, and extracts its per-secondary nats_url/
# nats_user/nats_password/consumer_name from the JSON response.
register_secondary() {
    local name="$1" response_file="$work_dir/shared/register-${1}.json"
    run_client "curl -sS -o /shared/register-${name}.json -w '%{http_code}' \
        -H 'Content-Type: application/json' \
        -d '{\"token\":\"$registration_token\",\"name\":\"$name\"}' \
        'http://$ui_ip:8080/api/secondary/register'" > "$work_dir/shared/register-${name}.status"
    local http_code
    http_code="$(cat "$work_dir/shared/register-${name}.status")"
    if [[ "$http_code" != "200" ]]; then
        echo "::error::Registering secondary '$name' returned HTTP $http_code" >&2
        cat "$response_file" >&2 || true
        exit 1
    fi
}

# Runs the real nats-subscriber binary (shipped inside the published `dns`
# image, the exact code a registered secondary actually runs) with a given
# set of NATS credentials, and reports whether it reached "Connected to NATS"
# within a short timeout. This exercises the real client-side auth path, not
# a reimplementation of it.
attempt_nats_connect() {
    local label="$1" nats_url="$2" nats_user="$3" nats_password="$4" consumer="$5"
    local log_file="$work_dir/shared/connect-${label}.log"
    docker run --rm --network "$network_name" \
        --entrypoint sh \
        -e "NATS_URL=$nats_url" \
        -e "NATS_USER=$nats_user" \
        -e "NATS_PASSWORD=$nats_password" \
        -e "NATS_CONSUMER=$consumer" \
        -e "PDNS_API_KEY=validation-pdns-key" \
        "$dns_image" \
        -c 'timeout 5 nats-subscriber || true' \
        > "$log_file" 2>&1 || true
    if grep -q "Connected to NATS" "$log_file"; then
        echo "1"
    else
        echo "0"
    fi
}

assert_connects() {
    local label="$1" nats_url="$2" nats_user="$3" nats_password="$4" consumer="$5"
    local ok
    ok="$(attempt_nats_connect "$label" "$nats_url" "$nats_user" "$nats_password" "$consumer")"
    if [[ "$ok" != "1" ]]; then
        echo "::error::Expected '$label' to connect to NATS successfully but it did not. Log:" >&2
        cat "$work_dir/shared/connect-${label}.log" >&2
        exit 1
    fi
    echo "$label: connected successfully, as expected."
}

assert_rejected() {
    local label="$1" nats_url="$2" nats_user="$3" nats_password="$4" consumer="$5"
    local ok
    ok="$(attempt_nats_connect "$label" "$nats_url" "$nats_user" "$nats_password" "$consumer")"
    if [[ "$ok" != "0" ]]; then
        echo "::error::Expected '$label' to be REJECTED by NATS but it connected. Log:" >&2
        cat "$work_dir/shared/connect-${label}.log" >&2
        exit 1
    fi
    echo "$label: rejected, as expected."
}

json_field() {
    local file="$1" field="$2"
    grep -oP "\"$field\"\s*:\s*\"\K[^\"]*" "$file"
}

echo "== Registering two independent secondaries =="
register_secondary "authcallout-a"
register_secondary "authcallout-b"

a_file="$work_dir/shared/register-authcallout-a.json"
b_file="$work_dir/shared/register-authcallout-b.json"
a_url="$(json_field "$a_file" nats_url)"
a_user="$(json_field "$a_file" nats_user)"
a_pass="$(json_field "$a_file" nats_password)"
a_consumer="$(json_field "$a_file" consumer_name)"
b_url="$(json_field "$b_file" nats_url)"
b_user="$(json_field "$b_file" nats_user)"
b_pass="$(json_field "$b_file" nats_password)"
b_consumer="$(json_field "$b_file" consumer_name)"

for value_name in a_url a_user a_pass a_consumer b_url b_user b_pass b_consumer; do
    if [[ -z "${!value_name}" ]]; then
        echo "::error::Missing expected field '$value_name' in a secondary registration response." >&2
        exit 1
    fi
done

if [[ "$a_user" == "$b_user" || "$a_pass" == "$b_pass" ]]; then
    echo "::error::Two independently registered secondaries received the same NATS identity (user='$a_user' vs '$b_user'). Per-secondary identity is not actually unique." >&2
    exit 1
fi
echo "Secondaries 'authcallout-a' and 'authcallout-b' each received distinct NATS credentials."

echo "== Verifying both freshly registered secondaries can connect to NATS with their own credentials =="
assert_connects "a-initial" "$a_url" "$a_user" "$a_pass" "$a_consumer"
assert_connects "b-initial" "$b_url" "$b_user" "$b_pass" "$b_consumer"

echo "== Removing secondary 'authcallout-a' via DELETE /api/secondary/authcallout-a =="
remove_http_code="$(run_client "curl -sS -b /shared/cookiejar -o /dev/null -w '%{http_code}' \
    -X DELETE -H 'X-CSRF-Token: $csrf_token' \
    'http://$ui_ip:8080/api/secondary/authcallout-a'")"
if [[ "$remove_http_code" != "200" ]]; then
    echo "::error::DELETE /api/secondary/authcallout-a returned HTTP $remove_http_code, expected 200." >&2
    exit 1
fi
echo "Secondary 'authcallout-a' removed."

echo "== Verifying the removed secondary's OLD credential is now rejected =="
assert_rejected "a-after-remove" "$a_url" "$a_user" "$a_pass" "$a_consumer"

echo "== Verifying the still-registered secondary 'authcallout-b' is completely unaffected =="
assert_connects "b-after-a-removed" "$b_url" "$b_user" "$b_pass" "$b_consumer"

echo "== Rotating secondary 'authcallout-b's credential via POST rotate-token =="
rotate_file="$work_dir/shared/rotate-b.json"
rotate_http_code="$(run_client "curl -sS -o /shared/rotate-b.json -w '%{http_code}' \
    -X POST -b /shared/cookiejar -H 'X-CSRF-Token: $csrf_token' \
    -H 'Content-Type: application/json' \
    -d '{\"token\":\"$registration_token\"}' \
    'http://$ui_ip:8080/api/secondary/authcallout-b/rotate-token'")"
if [[ "$rotate_http_code" != "200" ]]; then
    echo "::error::POST rotate-token for authcallout-b returned HTTP $rotate_http_code, expected 200." >&2
    cat "$rotate_file" >&2 || true
    exit 1
fi
b_new_pass="$(json_field "$rotate_file" nats_password)"
if [[ -z "$b_new_pass" ]]; then
    echo "::error::rotate-token response for authcallout-b did not include nats_password." >&2
    exit 1
fi
if [[ "$b_new_pass" == "$b_pass" ]]; then
    echo "::error::rotate-token for authcallout-b returned the SAME password as before -- rotation did not actually change anything." >&2
    exit 1
fi
echo "authcallout-b's credential was rotated to a new value."

echo "== Verifying authcallout-b's OLD (pre-rotation) credential is now rejected =="
assert_rejected "b-old-cred-after-rotate" "$b_url" "$b_user" "$b_pass" "$b_consumer"

echo "== Verifying authcallout-b's NEW (post-rotation) credential works =="
assert_connects "b-new-cred-after-rotate" "$b_url" "$b_user" "$b_new_pass" "$b_consumer"

echo "nats-secondary-auth-callout-simulation passed: per-secondary NATS identity, immediate revocation on removal, isolation between secondaries, and credential rotation all verified end-to-end against a real nats-server and the real nats-subscriber client."
