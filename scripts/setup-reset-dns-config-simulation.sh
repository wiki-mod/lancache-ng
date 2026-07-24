#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Real end-to-end proof for issue #836's CLI-fallback item: `setup.sh
# reset-to-last-known-good-config dns` must actually roll a real, running
# PowerDNS zone's live record data back to an earlier known-good snapshot via
# nats-subscriber's rollback listener -- not just return success. Mirrors
# scripts/setup-reset-kea-config-simulation.sh's rigor for the Kea target and
# reuses scripts/dns-zone-rollback-simulation.sh's proven stack/UI-mutation
# setup (issue #628) for standing up a real dns-standard/nats/ui trio and
# making real record changes, but exercises the CLI (`bash setup.sh
# reset-to-last-known-good-config dns ...`) instead of calling the rollback
# listener's HTTP API directly.
#
# What this script does:
#   1. Starts the real full-setup validation stack's proxy, docker-socket-
#      proxy, dns-standard, dns-ssl, nats, and ui services (published images),
#      same topology dns-zone-rollback-simulation.sh already proved this
#      mechanism against.
#   2. Through the Admin UI's real HTTP route, adds LAN record A (content
#      old_content), then changes it to content B (new_content) -- each
#      successful write triggers nats-subscriber's own post-write known-good
#      snapshot (handle_dns_record's maybe_snapshot_zone hook), so there is a
#      snapshot captured right after A (before B ever existed) and a later one
#      after B.
#   3. Runs the real `setup.sh reset-to-last-known-good-config dns
#      <install-dir> lan. <snapshot-after-A> --yes` against
#      deploy/full-setup/docker-compose.yml (the SAME compose file/project the
#      stack above is already running under) -- the CLI's
#      dns_rollback_exec -> `docker compose exec` -> curl chain against the
#      real rollback listener inside the real dns-standard container.
#   4. Confirms via a real `dig` query against dns-standard's own recursor
#      that the record now resolves to old_content again (content B is gone)
#      -- proof the CLI genuinely rolled PowerDNS's live data back, not just
#      that its own HTTP calls returned 2xx.
#
# Deliberately proves the exact gap an earlier draft of this CLI would have
# shipped with (found during design, before any code was written): the
# throwaway install-dir's own .env carries an INTENTIONALLY WRONG/placeholder
# PDNS_API_KEY (see install_env_pdns_api_key below). If dns_rollback_exec ever
# regressed to reading PDNS_API_KEY from this host-side .env and passing it
# into the container (rather than resolving it INSIDE the exec'd shell from
# the container's own environment/shared-secrets volume, per that function's
# own doc comment), every call in this script would 401 and the whole run
# would fail loudly -- this is a real regression guard, not just documentation
# of the design decision.
#
# What this script does NOT verify:
#   - The interactive confirmation prompt itself (ask()/confirm() read
#     /dev/tty; --yes exists so this command can be driven the same way
#     scripted/automated recovery would use it) -- same scope note as
#     setup-reset-kea-config-simulation.sh.
#   - The #858 shared-secrets first-writer-wins fallback path for
#     PDNS_API_KEY: this stack (deploy/full-setup/docker-compose.yml)
#     hardcodes a fixed PDNS_API_KEY on every relevant service rather than
#     leaving it blank, so that fallback is inert here (see
#     docs/known-good-config-snapshots.md and this stack's own "(inert here:
#     this validation stack hardcodes a consistent PDNS_API_KEY)" comments).
#     dns_rollback_exec's fallback-to-shared-secrets-file branch is therefore
#     exercised only by unit tests (tests/bats/setup_reset_last_known_good_
#     config.bats), not by this live run.
#   - The dns-ssl target (--service dns-ssl) or the "no zone given" listing
#     path -- covered by tests/bats/setup_reset_last_known_good_config.bats
#     instead, which does not need a live stack for either.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# shellcheck source=scripts/lib/reserve-validation-subnet.sh
source "$repo_root/scripts/lib/reserve-validation-subnet.sh"

test_name="issue836-reset-dns-test"
test_fqdn="${test_name}.lan."
old_content="203.0.113.80"
new_content="203.0.113.81"
work_dir="$repo_root/.setup-reset-dns-config-simulation-tmp"
rm -rf "$work_dir"
mkdir -p "$work_dir/shared"

compose_project="${COMPOSE_PROJECT_NAME:-lancache-ng-validation}"
network_name="${compose_project}_validation"
# See ssl-mitm-cache-simulation.sh's identical comment: these must track
# deploy/full-setup/docker-compose.yml's own VALIDATION_*_IP defaults so the
# addresses this script queries match the real container IPs `docker compose
# up` below actually assigns.
ui_ip="${VALIDATION_UI_IP:-172.30.99.9}"
dns_standard_ip="${VALIDATION_DNS_STANDARD_IP:-172.30.99.3}"
build_tools_image="${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}"
image_tag="${LANCACHE_IMAGE_TAG:-nightly}"

# The throwaway install-dir's own .env deliberately does NOT carry this
# stack's real PDNS_API_KEY (validation-pdns-key, deploy/full-setup/docker-
# compose.yml) -- see this script's header comment: dns_rollback_exec must
# resolve the effective key from INSIDE the dns-standard container, never
# from this host-side file, and a placeholder here proves that.
install_env_pdns_api_key="CHANGE_ME_this_value_must_never_be_used"

# install_dir points at the repo's REAL deploy/full-setup directory (not a
# throwaway copy): dns_rollback_exec ultimately runs `docker compose ... -f
# <install-dir>/docker-compose.yml exec -T dns-standard ...`, which must
# resolve to the SAME running container `docker compose up` below starts --
# a copy elsewhere would still need every relative path inside that compose
# file (e.g. cdn-domains.txt) to resolve identically, which is fragile to
# guarantee, whereas using the file in place carries no such risk. Only the
# throwaway .env below is written into this directory, and removed again in
# the EXIT trap.
install_dir="$repo_root/deploy/full-setup"

cleanup() {
    local status=$?
    rm -f "$install_dir/.env"
    docker compose -p "$compose_project" -f deploy/full-setup/docker-compose.yml \
        down -v --remove-orphans >/dev/null 2>&1 || true
    # `down` above can lose the "has active endpoints" race (see
    # validation_project_networks_teardown's own comment in reserve-validation-
    # subnet.sh) and silently leave this network non-empty, poisoning it for
    # whichever job/run reserves this slot next -- wait for and force a real
    # removal instead of trusting `down`'s own exit code.
    validation_project_networks_teardown "$compose_project" || true
    rm -rf "$work_dir"
    exit "$status"
}
trap cleanup EXIT

echo "== Writing a throwaway .env at $install_dir (intentionally wrong PDNS_API_KEY -- see header comment) =="
printf 'PDNS_API_KEY=%s\nCOMPOSE_PROJECT_NAME=%s\n' "$install_env_pdns_api_key" "$compose_project" > "$install_dir/.env"

echo "== Pulling the published $image_tag images =="
# Without an explicit pull, Compose's pull_policy: missing would silently
# reuse whatever image is already cached locally under this tag -- see
# dns-zone-rollback-simulation.sh's identical step/comment (issue #809).
LANCACHE_IMAGE_TAG="$image_tag" \
    docker compose -p "$compose_project" -f deploy/full-setup/docker-compose.yml \
    pull --quiet proxy docker-socket-proxy dns-standard dns-ssl nats ui

echo "== Starting proxy/docker-socket-proxy/dns-standard/dns-ssl/nats/ui from the published $image_tag images =="
LANCACHE_IMAGE_TAG="$image_tag" \
    docker compose -p "$compose_project" -f deploy/full-setup/docker-compose.yml \
    up -d proxy docker-socket-proxy dns-standard dns-ssl nats ui

compose=(docker compose -p "$compose_project" -f deploy/full-setup/docker-compose.yml)
deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
    all_ready=1
    for service in proxy dns-standard dns-ssl ui; do
        if ! cid="$("${compose[@]}" ps -q "$service")"; then
            echo "::error::Could not query the compose container id for service '$service'." >&2
            exit 1
        fi
        status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown")"
        [[ "$status" = "healthy" ]] || all_ready=0
    done
    (( all_ready == 1 )) && break
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

# Each call is a brand new --rm container; /shared is bind-mounted from
# work_dir (a real, persistent host directory) so the cookie jar survives
# across calls -- same pattern as dns-zone-rollback-simulation.sh.
run_client() {
    docker run --rm --network "$network_name" \
        -v "$work_dir/shared:/shared" \
        "$build_tools_image" bash -c "$1"
}

echo "== UI: establishing a session and extracting its CSRF token =="
run_client "curl -sS -c /shared/cookiejar -o /dev/null 'http://$ui_ip:8080/domains'"
if ! cookie_value="$(awk -F'\t' '$6 == "lancache_ui_session" {print $7}' "$work_dir/shared/cookiejar")"; then
    echo "::error::Failed to read the session cookie value out of $work_dir/shared/cookiejar (awk invocation failed)." >&2
    exit 1
fi
if [[ -z "$cookie_value" ]]; then
    echo "::error::No lancache_ui_session cookie was set by GET /domains." >&2
    exit 1
fi
if ! csrf_token="$(cut -d. -f3 <<<"$cookie_value")"; then
    echo "::error::Failed to extract the CSRF token segment from the session cookie (cut invocation failed)." >&2
    exit 1
fi
if [[ -z "$csrf_token" ]]; then
    echo "::error::Could not extract a CSRF token from the session cookie." >&2
    exit 1
fi
echo "Session established, CSRF token extracted."

add_lan_record() {
    local content="$1"
    local http_code
    if ! http_code="$(run_client "curl -sS -b /shared/cookiejar -o /shared/add-response -w '%{http_code}' \
        --data-urlencode 'csrf_token=$csrf_token' \
        --data-urlencode 'name=$test_name' \
        --data-urlencode 'record_type=A' \
        --data-urlencode 'content=$content' \
        --data-urlencode 'ttl=60' \
        'http://$ui_ip:8080/domains/lan/add'")"; then
        echo "::error::POST /domains/lan/add (content=$content) failed outright (run_client/curl invocation error)." >&2
        exit 1
    fi
    if [[ "$http_code" != "303" ]]; then
        echo "::error::POST /domains/lan/add (content=$content) returned HTTP $http_code, expected 303 (redirect to /domains)." >&2
        exit 1
    fi
}

# No fixed reload/notify step exists between nats-subscriber's PowerDNS API
# PATCH and a recursor query actually seeing it -- same reasoning as
# dns-zone-rollback-simulation.sh's identical helper -- so poll instead of
# sleeping a fixed amount then checking once.
verify_record_resolves() {
    local expected="$1"
    local attempt resolved
    for attempt in $(seq 1 15); do
        if ! resolved="$(run_client "dig +time=2 +tries=1 +short @$dns_standard_ip A $test_fqdn" | sort -u)"; then
            echo "::error::Failed to run dig against dns-standard ($dns_standard_ip) for $test_fqdn (run_client/docker invocation failed)." >&2
            return 1
        fi
        [[ "$resolved" = "$expected" ]] && { echo "dns-standard resolves $test_fqdn to $expected (attempt $attempt)."; return 0; }
        sleep 1
    done
    echo "::error::dns-standard never resolved $test_fqdn to $expected after 15 attempts (last saw: '${resolved:-<empty>}')." >&2
    return 1
}

# Direct HTTP calls to the rollback listener's own /snapshots, purely to
# discover the real snapshot ids this test needs to pass to the CLI below --
# this is baseline/setup bookkeeping, not the thing under test (the CLI's own
# GET /snapshots call, exercised via dns_rollback_exec, is what step 3 below
# actually proves).
get_newest_lan_snapshot_id() {
    run_client "curl -sS -H 'X-API-Key: validation-pdns-key' 'http://$dns_standard_ip:8083/snapshots'" \
        | jq -r '.zones["lan."][0].id // empty'
}

# Polls until the newest recorded snapshot for zone lan. differs from
# $previous -- same reasoning as dns-zone-rollback-simulation.sh's identical
# helper (comparing against the previous newest id, not merely "any id
# exists", so a pre-existing snapshot from an earlier run isn't mistaken for
# this test's own write).
poll_for_new_snapshot() {
    local previous="$1" label="$2"
    local id attempt
    for attempt in $(seq 1 15); do
        id="$(get_newest_lan_snapshot_id)" || id=""
        if [[ -n "$id" && "$id" != "$previous" ]]; then
            echo "$label: new known-good snapshot $id recorded (attempt $attempt)." >&2
            printf '%s\n' "$id"
            return 0
        fi
        sleep 1
    done
    echo "::error::$label: no new known-good snapshot for zone lan. appeared (still at '${previous:-<none>}')." >&2
    return 1
}

# dns-standard's Docker healthcheck only proves pdns_recursor itself answers,
# not that nats-subscriber's rollback listener (a separate process, bound
# after NATS connect + JetStream consumer setup) is already listening on 8083
# -- same startup-lag reasoning and observed CI timing as dns-zone-rollback-
# simulation.sh's identical wait_for_rollback_listener.
wait_for_rollback_listener() {
    local attempt
    for attempt in $(seq 1 30); do
        if run_client "curl -sS -o /dev/null -H 'X-API-Key: validation-pdns-key' 'http://$dns_standard_ip:8083/snapshots'"; then
            echo "Rollback listener on $dns_standard_ip:8083 is accepting connections (attempt $attempt)."
            return 0
        fi
        sleep 1
    done
    echo "::error::Rollback listener on $dns_standard_ip:8083 never accepted a connection after 30 attempts." >&2
    "${compose[@]}" logs --no-color dns-standard
    return 1
}

echo "== Waiting for the rollback listener (dns-standard's nats-subscriber, port 8083) to be reachable =="
wait_for_rollback_listener

echo "== Recording the baseline known-good snapshot state for zone lan. before this test changes anything =="
if ! baseline_snapshot_id="$(get_newest_lan_snapshot_id)"; then
    echo "::error::Failed to query the baseline known-good snapshot id for zone lan. from the rollback listener." >&2
    exit 1
fi
echo "Baseline snapshot id: '${baseline_snapshot_id:-<none>}'"

echo "== Step 1: add the real LAN record (content=$old_content) via the UI -- should trigger an automatic known-good snapshot =="
add_lan_record "$old_content"
verify_record_resolves "$old_content"
if ! snapshot_after_a="$(poll_for_new_snapshot "$baseline_snapshot_id" "after first change")"; then
    echo "::error::Failed to capture the post-first-change snapshot id (cause logged above)." >&2
    exit 1
fi

echo "== Step 2: change the record to content=$new_content via the UI (second real change) -- should trigger another automatic snapshot =="
add_lan_record "$new_content"
verify_record_resolves "$new_content"
echo "dns-standard's recursor now has $test_fqdn=$new_content cached (TTL 60s)."
if ! snapshot_after_b="$(poll_for_new_snapshot "$snapshot_after_a" "after second change")"; then
    echo "::error::Failed to capture the post-second-change snapshot id (cause logged above)." >&2
    exit 1
fi
echo "Snapshots on disk: baseline='${baseline_snapshot_id:-<none>}' after-A=$snapshot_after_a after-B=$snapshot_after_b"

echo "== Running the real 'setup.sh reset-to-last-known-good-config dns' CLI fallback against zone lan., snapshot $snapshot_after_a =="
if ! reset_output=$(COMPOSE_PROJECT_NAME="$compose_project" bash setup.sh reset-to-last-known-good-config dns "$install_dir" lan. "$snapshot_after_a" --yes 2>&1); then
    echo "::error::setup.sh reset-to-last-known-good-config dns failed:" >&2
    echo "$reset_output" >&2
    exit 1
fi
echo "$reset_output"
if [[ "$reset_output" != *"rolled back to known-good snapshot $snapshot_after_a"* ]]; then
    echo "::error::setup.sh did not report a successful rollback to $snapshot_after_a in its own output." >&2
    exit 1
fi
echo "setup.sh reported success rolling back zone lan. to snapshot $snapshot_after_a."

echo "== Verifying via a real dig query against dns-standard's recursor that the record genuinely rolled back (also proves the CLI's own post-rollback cache-flush worked) =="
verify_record_resolves "$old_content"

echo "== Verifying a fresh known-good snapshot of the restored state was recorded post-rollback =="
poll_for_new_snapshot "$snapshot_after_b" "after CLI rollback" >/dev/null

echo "== Cleaning up the test record =="
if ! remove_http_code="$(run_client "curl -sS -b /shared/cookiejar -o /shared/remove-response -w '%{http_code}' \
    --data-urlencode 'csrf_token=$csrf_token' \
    --data-urlencode 'name=$test_name' \
    --data-urlencode 'record_type=A' \
    --data-urlencode 'content=$old_content' \
    'http://$ui_ip:8080/domains/lan/remove'")"; then
    echo "::error::POST /domains/lan/remove failed outright (run_client/curl invocation error)." >&2
    exit 1
fi
if [[ "$remove_http_code" != "303" ]]; then
    echo "::error::POST /domains/lan/remove returned HTTP $remove_http_code, expected 303 (redirect to /domains)." >&2
    exit 1
fi

echo "setup-reset-dns-config-simulation passed: 'setup.sh reset-to-last-known-good-config dns' genuinely rolled a real, running PowerDNS zone's live record data back to an earlier known-good snapshot via nats-subscriber's real rollback listener (docker compose exec + curl inside dns-standard) -- confirmed by a fresh dig query showing the pre-rollback content gone and the rolled-back-to content restored, using a deliberately wrong host-side PDNS_API_KEY to prove the key is resolved inside the container, not read from this host's .env."
