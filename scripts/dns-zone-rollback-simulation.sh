#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Real end-to-end test (#628) of the PowerDNS zone/record known-good
# snapshot + rollback mechanism against a REAL running dns-standard
# container -- not mocks. The unit tests in zone_snapshots.rs/
# rollback_listener.rs/dns_snapshots.rs prove the diff/canonicalization/
# retention/auth logic in isolation; this proves the actual HTTP round-trip
# and PATCH/DELETE semantics against a real PowerDNS instance, which unit
# tests structurally cannot (no live PowerDNS in a `cargo test` process).
#
# Modeled on the proven pattern in scripts/ui-nats-dns-integration-
# simulation.sh (bring up the real stack, use the real UI route to make a
# real NATS-driven DNS change, verify via real `dig` queries), extended
# three ways this issue's design specifically needs proof of: (1) makes TWO
# real changes so there is a "before" snapshot and a different "current"
# state to roll back from, (2) calls the new rollback listener
# (services/dns/nats-subscriber/src/rollback_listener.rs, port 8083)
# directly over HTTP with the real X-API-Key, the same way the Admin UI's
# routes/dns_snapshots.rs forwards to it, rather than only exercising it
# indirectly, (3) confirms the recursor cache was actually flushed after
# rollback (a real `dig` against the same recursor that had the pre-
# rollback value cached with a real TTL), not just that PowerDNS's
# authoritative data changed underneath it.
#
# This stack's dns-standard/dns-ssl NATS identities carry no `publish`
# block at all in deploy/full-setup/docker-compose.yml (the compose file
# this script drives), which nats-server treats as unrestricted publish --
# unlike the restrictive dev/prod/quickstart allow-lists that actually
# shipped the missing-publish-on-lancache.dns.flush bug. So the dig-based
# flush proof below would have passed here even before that fix; it does
# not by itself prove the permission fix. The explicit `flush_ok` assertion
# added below IS a real
# regression guard though: it proves the response body's own
# success/failure signal (rollback_listener.rs's `rollback_response_body`)
# is actually wired to the real per-name publish/ack loop against a live
# NATS server, which the crate's unit tests (fed a hand-built
# flush_failed_names) cannot prove on their own.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# shellcheck source=scripts/lib/reserve-validation-subnet.sh
source "$repo_root/scripts/lib/reserve-validation-subnet.sh"

test_name="issue628-rollback-test"
test_fqdn="${test_name}.lan."
old_content="203.0.113.70"
new_content="203.0.113.71"
work_dir="$repo_root/.dns-zone-rollback-simulation-tmp"
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
# Matches deploy/full-setup/docker-compose.yml's fixed validation-only
# PDNS_API_KEY. The rollback listener authenticates every request against
# this same value (it reuses PDNS_API_KEY by design -- see
# docs/known-good-config-snapshots.md's "The rollback listener must require
# authentication"), the same key dns-standard's own PowerDNS API uses.
pdns_api_key="validation-pdns-key"
rollback_port=8083

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

echo "== Pulling the published $image_tag images =="

# Without an explicit pull, Compose's pull_policy: missing (see
# deploy/full-setup/docker-compose.yml) would silently reuse whatever image
# is already cached locally under this tag instead of the one actually
# published for this run -- confirmed live (2026-07-14, issue #809): a
# runner with an 11-hour-stale local `dns:dev` image (predating this script's
# own rollback listener entirely) silently ran that old binary instead of
# pulling the current one, producing a permanent "connection refused" that
# looked exactly like a startup race. Mirrors ssl-mitm-cache-simulation.sh's
# own pull step, added for the identical reason.
LANCACHE_IMAGE_TAG="$image_tag" \
    docker compose -p "$compose_project" -f deploy/full-setup/docker-compose.yml \
    pull --quiet proxy docker-socket-proxy dns-standard dns-ssl nats ui

echo "== Starting proxy/docker-socket-proxy/dns-standard/dns-ssl/nats/ui from the published $image_tag images =="

# ui's own healthcheck (depends_on: docker-socket-proxy, proxy, nats) needs
# all three running first, or it never reaches a healthy state; dns-ssl is
# not exercised by this test directly but its absence would leave the
# compose project half-started for the shared teardown trap, so bring up
# the same six services ui-nats-dns-integration-simulation.sh does.
LANCACHE_IMAGE_TAG="$image_tag" \
    docker compose -p "$compose_project" -f deploy/full-setup/docker-compose.yml \
    up -d proxy docker-socket-proxy dns-standard dns-ssl nats ui

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

# Each call is a brand new --rm container; /shared is bind-mounted from
# work_dir (a real, persistent host directory) so the cookie jar survives
# across calls -- same pattern proven in ui-nats-dns-integration-
# simulation.sh and ssl-mitm-cache-simulation.sh.
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
# ui-nats-dns-integration-simulation.sh's identical helper -- so poll instead
# of sleeping a fixed amount then checking once. Reused after the rollback
# PATCH too, where it doubles as the cache-flush proof: the recursor has
# $new_content cached with a real 60s TTL at that point, so if the post-
# rollback flush publish (`lancache.dns.flush`) did not actually reach and
# clear dns-standard's own recursor, this poll would keep seeing the stale
# cached $new_content and time out well before the TTL naturally expired.
verify_record_resolves() {
    local expected="$1"
    local attempt resolved
    for attempt in $(seq 1 15); do
        # Under `set -euo pipefail`, `run_client ... | sort -u` can abort the
        # whole script silently right here: pipefail makes the pipeline's exit
        # status reflect run_client's own failure even though `sort -u` always
        # succeeds on its own (it happily sorts zero lines of input) -- wrap
        # the assignment so a failed dig/run_client invocation is reported
        # explicitly instead of dying with no explanation.
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

# Direct HTTP calls to the rollback listener, exactly like routes/
# dns_snapshots.rs's fetch_zone_snapshot_groups/rollback_zone_snapshot do
# from inside the ui container, but from this ephemeral client container
# instead -- proving the listener's own HTTP surface, not the UI's
# thin forwarder around it.
get_newest_lan_snapshot_id() {
    run_client "curl -sS -H 'X-API-Key: $pdns_api_key' 'http://$dns_standard_ip:$rollback_port/snapshots'" \
        | jq -r '.zones["lan."][0].id // empty'
}

# Polls until the newest recorded snapshot for zone lan. differs from
# $previous (which may be empty, e.g. before this test's first change).
# Comparing against the PREVIOUS newest id, rather than merely "any id
# exists", is deliberate: a pre-existing snapshot from an earlier
# unrelated write on this fresh-per-run container must not be mistaken for
# the snapshot this test's own write is expected to trigger. Prints only
# the resulting id on stdout (progress goes to stderr) so callers can
# capture it directly via command substitution.
poll_for_new_snapshot() {
    local previous="$1" label="$2"
    local id attempt
    for attempt in $(seq 1 15); do
        # This function is called both directly (the final call near the
        # bottom of this script, errexit stays on) and via
        # `old_snapshot_id="$(poll_for_new_snapshot ...)"`-style command
        # substitution at the earlier call sites -- and command substitution
        # disables errexit in the subshell it runs in (bash only re-enables
        # that with
        # `shopt -s inherit_errexit`, not set here). So a bare `id="$(cmd)"`
        # here behaves differently depending on which caller invoked this
        # function. `|| id=""` sidesteps that entirely: it is safe under
        # errexit in both contexts, and treats a transient query failure the
        # same as "no snapshot yet" -- keep polling instead of aborting,
        # since the rollback listener can briefly 500/non-JSON right after
        # wait_for_rollback_listener's TCP-only readiness check passes (see
        # that function's own comment on this exact startup lag).
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

# dns-standard's Docker healthcheck (rec_control ping) only proves
# pdns_recursor itself answers -- it says nothing about nats-subscriber,
# a separate process entrypoint.sh backgrounds AFTER run_auth/run_recursor
# (see services/dns/entrypoint.sh's run_nats_subscriber). That process must
# still connect to NATS and set up its JetStream consumer before it ever
# reaches the tokio::spawn that binds DNS_ROLLBACK_LISTEN_ADDR (rollback_
# listener.rs, default 0.0.0.0:8083) -- so "healthy" can be true seconds
# before 8083 is actually listening. Observed in CI (run 29287590206, job
# "DNS zone/record rollback simulation"): containers reported healthy at
# 21:55:31.767Z, then this script's very first request to 8083 got
# `curl: (7) ... Connection refused ... after 0ms` at 21:55:32.132Z --
# exactly the "not bound yet" signature, not a timeout. Every other network
# call below already tolerates this kind of lag by polling for a specific
# expected VALUE (verify_record_resolves, poll_for_new_snapshot); this one
# can't do that because the very first read here is baseline_snapshot_id,
# which is legitimately allowed to be empty on a fresh container (see
# poll_for_new_snapshot's own comment) -- so instead poll for the listener
# to merely accept a TCP connection at all, then read the value once.
wait_for_rollback_listener() {
    local attempt
    for attempt in $(seq 1 30); do
        if run_client "curl -sS -o /dev/null -H 'X-API-Key: $pdns_api_key' 'http://$dns_standard_ip:$rollback_port/snapshots'"; then
            echo "Rollback listener on $dns_standard_ip:$rollback_port is accepting connections (attempt $attempt)."
            return 0
        fi
        sleep 1
    done
    echo "::error::Rollback listener on $dns_standard_ip:$rollback_port never accepted a connection after 30 attempts." >&2
    "${compose[@]}" logs --no-color dns-standard
    return 1
}

echo "== Waiting for the rollback listener (dns-standard's nats-subscriber, port $rollback_port) to be reachable =="
wait_for_rollback_listener

echo "== Recording the baseline known-good snapshot state for zone lan. before this test changes anything =="
if ! baseline_snapshot_id="$(get_newest_lan_snapshot_id)"; then
    echo "::error::Failed to query the baseline known-good snapshot id for zone lan. from the rollback listener." >&2
    exit 1
fi
echo "Baseline snapshot id: '${baseline_snapshot_id:-<none>}'"

echo "== Step 1: add the real LAN record (content=$old_content) via the UI, which should automatically trigger a known-good snapshot (services/dns/nats-subscriber's handle_dns_record post-write hook) =="
add_lan_record "$old_content"
verify_record_resolves "$old_content"
if ! old_snapshot_id="$(poll_for_new_snapshot "$baseline_snapshot_id" "after first change")"; then
    echo "::error::Failed to capture the post-first-change snapshot id (cause logged above)." >&2
    exit 1
fi

echo "== Step 2: change the record to content=$new_content via the UI (second real change), which should trigger another automatic snapshot =="
add_lan_record "$new_content"
verify_record_resolves "$new_content"
echo "dns-standard's recursor now has $test_fqdn=$new_content cached (TTL 60s)."
if ! new_snapshot_id="$(poll_for_new_snapshot "$old_snapshot_id" "after second change")"; then
    echo "::error::Failed to capture the post-second-change snapshot id (cause logged above)." >&2
    exit 1
fi

echo "== Bonus check: GET /snapshots must reject a missing or wrong X-API-Key =="
if ! unauth_code="$(run_client "curl -sS -o /dev/null -w '%{http_code}' 'http://$dns_standard_ip:$rollback_port/snapshots'")"; then
    echo "::error::GET /snapshots (no X-API-Key) request failed outright (run_client/curl invocation error)." >&2
    exit 1
fi
if [[ "$unauth_code" != "401" ]]; then
    echo "::error::GET /snapshots without X-API-Key returned HTTP $unauth_code, expected 401." >&2
    exit 1
fi
if ! wrong_key_code="$(run_client "curl -sS -o /dev/null -w '%{http_code}' -H 'X-API-Key: wrong-key' 'http://$dns_standard_ip:$rollback_port/snapshots'")"; then
    echo "::error::GET /snapshots (wrong X-API-Key) request failed outright (run_client/curl invocation error)." >&2
    exit 1
fi
if [[ "$wrong_key_code" != "401" ]]; then
    echo "::error::GET /snapshots with a wrong X-API-Key returned HTTP $wrong_key_code, expected 401." >&2
    exit 1
fi
echo "Rollback listener correctly rejects unauthenticated/wrongly-authenticated requests (401)."

echo "== Calling the rollback listener directly: POST /rollback to the earlier snapshot ($old_snapshot_id, content=$old_content) =="
if ! rollback_payload="$(jq -n --arg zone 'lan.' --arg id "$old_snapshot_id" '{zone: $zone, snapshot_id: $id}')"; then
    echo "::error::Failed to build the rollback request JSON payload (jq invocation failed)." >&2
    exit 1
fi
printf '%s' "$rollback_payload" > "$work_dir/shared/rollback-payload.json"
if ! rollback_response="$(run_client "curl -sS -X POST \
    -H 'X-API-Key: $pdns_api_key' \
    -H 'Content-Type: application/json' \
    --data-binary @/shared/rollback-payload.json \
    'http://$dns_standard_ip:$rollback_port/rollback'")"; then
    echo "::error::POST /rollback request failed outright (run_client/curl invocation error)." >&2
    exit 1
fi
echo "Rollback response: $rollback_response"
if ! applied="$(jq -r '.applied // false' <<<"$rollback_response")"; then
    echo "::error::Failed to parse 'applied' out of the rollback response (jq invocation failed): $rollback_response" >&2
    exit 1
fi
if [[ "$applied" != "true" ]]; then
    echo "::error::POST /rollback did not report applied=true: $rollback_response" >&2
    exit 1
fi
if ! changed_names="$(jq -r '(.changed_names // []) | join(",")' <<<"$rollback_response")"; then
    echo "::error::Failed to parse 'changed_names' out of the rollback response (jq invocation failed): $rollback_response" >&2
    exit 1
fi
if [[ "$changed_names" != *"$test_fqdn"* ]]; then
    echo "::error::Rollback response did not list $test_fqdn among changed_names: $rollback_response" >&2
    exit 1
fi
# Assert the response's OWN flush signal, not just that the flush happened
# to work (verify_record_resolves below proves that separately via a real
# dig). Before this fix, this identity's NATS publish permission on
# lancache.dns.flush was silently denied, and this field is the only thing
# that would have exposed that from the response itself; `flush_ok` and
# `flush_failed_names` are the pure-function-tested fields in
# rollback_listener.rs::rollback_response_body, so this line is what proves
# the loop-that-publishes actually wires into the response that reports it,
# not just that the shape is right in isolation.
if ! flush_ok="$(jq -r '.flush_ok // false' <<<"$rollback_response")"; then
    echo "::error::Failed to parse 'flush_ok' out of the rollback response (jq invocation failed): $rollback_response" >&2
    exit 1
fi
if [[ "$flush_ok" != "true" ]]; then
    echo "::error::POST /rollback did not report flush_ok=true: $rollback_response" >&2
    exit 1
fi
echo "Rollback applied; changed_names includes $test_fqdn; flush_ok=true."

echo "== Verifying the record actually rolled back to $old_content via a real DNS query against dns-standard's recursor (this also proves the post-rollback cache flush worked -- see verify_record_resolves's comment) =="
verify_record_resolves "$old_content"

echo "== Verifying a fresh known-good snapshot of the restored state was recorded post-rollback =="
poll_for_new_snapshot "$new_snapshot_id" "after rollback" >/dev/null

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

echo "dns-zone-rollback-simulation passed: automatic post-write snapshots, the rollback listener's real HTTP auth/list/rollback round-trip, the real PowerDNS PATCH, and the real post-rollback recursor cache-flush were all verified end-to-end against a live dns-standard container."
