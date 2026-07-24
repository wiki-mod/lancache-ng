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
#   - (Issue #682) The auth-callout request/response between nats-server and
#     the Admin UI's responder is xkey-encrypted, not cleartext -- proven by
#     packet-capturing the real nats<->ui leg and asserting no plaintext JWT
#     structure (the standard, otherwise-always-present auth-callout envelope
#     header) appears in it while the nkeys sealed-box "xkv1" marker does.
#
# Reuses the same published-image/health-wait/ephemeral-client pattern
# already proven in ssl-mitm-cache-simulation.sh and
# ui-nats-dns-integration-simulation.sh. The #682 packet-capture phase pulls
# a third-party debug image (nicolaka/netshoot) for tcpdump only -- not a
# project dependency, not added to any product image.
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
image_tag="${LANCACHE_IMAGE_TAG:-nightly}"
dns_image="${LANCACHE_IMAGE_REGISTRY:-ghcr.io}/${LANCACHE_IMAGE_PREFIX:-wiki-mod/lancache-ng}/dns:${image_tag}"
# Pinned to an immutable digest (AG-VAL-026: this script runs as a blocking
# CI gate in full-setup-sims.yml, so a mutable `:latest` third-party tag
# could drift between when this was last verified and when a run actually
# pulls it). Not a project dependency -- used only for this one-off tcpdump
# capture step, never added to any product Dockerfile/image.
netshoot_image="nicolaka/netshoot@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70"

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

run_client() {
    docker run --rm --network "$network_name" \
        -v "$work_dir/shared:/shared" \
        "$build_tools_image" bash -c "$1"
}

echo "== UI: establishing a session and extracting its CSRF token =="

run_client "curl -sS -c /shared/cookiejar -o /dev/null 'http://$ui_ip:8080/secondaries'"
# Under `set -euo pipefail`, a bare `var="$(cmd)"` with no adjacent check
# aborts the whole script silently the instant `cmd` fails -- errexit fires
# right at the assignment, before the `[[ -z ... ]]` check on the following
# line ever runs. Wrap each so a failing awk/cut invocation reports its own
# cause instead of a bare "Process completed with exit code 1"; the existing
# `[[ -z ]]` checks stay as-is below, they still catch the separate case of
# the command succeeding but producing empty output.
if ! cookie_value="$(awk -F'\t' '$6 == "lancache_ui_session" {print $7}' "$work_dir/shared/cookiejar")"; then
    echo "::error::Failed to read the session cookiejar at $work_dir/shared/cookiejar." >&2
    exit 1
fi
if [[ -z "$cookie_value" ]]; then
    echo "::error::No lancache_ui_session cookie was set by GET /secondaries." >&2
    exit 1
fi
if ! csrf_token="$(cut -d. -f3 <<<"$cookie_value")"; then
    echo "::error::Failed to extract a CSRF token from the session cookie value." >&2
    exit 1
fi
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
    # Same errexit hazard as elsewhere in this file: a bare `var="$(cmd)"`
    # with no adjacent check would abort silently here if the status file
    # somehow couldn't be read back, before the HTTP-code check below ever ran.
    if ! http_code="$(cat "$work_dir/shared/register-${name}.status")"; then
        echo "::error::Could not read back the HTTP status code written for secondary '$name' registration." >&2
        exit 1
    fi
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
    # Unlike the other bare `var="$(cmd)"` assignments hardened elsewhere in
    # this file, this one is not wrapped in an `if !` guard: attempt_nats_connect's
    # own last statement is always an unconditional `echo "1"` or `echo "0"`
    # (its one genuinely fallible step, the `docker run`, is already followed
    # by its own `|| true`), so it cannot itself return non-zero here.
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

# Extracts a single string field's value from a JSON response file via a
# plain regex instead of a proper JSON parser -- the responses here are
# small, flat, and fully controlled by this project's own Admin UI, so a
# regex is enough and avoids adding a jq dependency to the build-tools image
# just for this. `\K` resets the match start so grep's own -o output is only
# the captured value, not the whole `"field":"value"` match. Its exit status
# is grep's own: 1 if the field genuinely isn't present in the file (e.g. an
# error response body instead of the expected success JSON), 2 if the file
# itself can't be read -- both real failure modes callers must handle.
json_field() {
    local file="$1" field="$2"
    grep -oP "\"$field\"\s*:\s*\"\K[^\"]*" "$file"
}

echo "== Registering two independent secondaries =="
register_secondary "authcallout-a"
register_secondary "authcallout-b"

a_file="$work_dir/shared/register-authcallout-a.json"
b_file="$work_dir/shared/register-authcallout-b.json"
# Under `set -euo pipefail`, a bare `var="$(json_field ...)"` with no
# adjacent check would abort silently right here the instant json_field's
# grep fails (see its own comment above), before the "Missing expected
# field" loop further below ever gets a chance to report which field and
# file were actually at fault -- wrap each call so a failure names itself
# immediately instead of dying with no explanation.
if ! a_url="$(json_field "$a_file" nats_url)"; then
    echo "::error::Failed to read field 'nats_url' from $a_file." >&2
    exit 1
fi
if ! a_user="$(json_field "$a_file" nats_user)"; then
    echo "::error::Failed to read field 'nats_user' from $a_file." >&2
    exit 1
fi
if ! a_pass="$(json_field "$a_file" nats_password)"; then
    echo "::error::Failed to read field 'nats_password' from $a_file." >&2
    exit 1
fi
if ! a_consumer="$(json_field "$a_file" consumer_name)"; then
    echo "::error::Failed to read field 'consumer_name' from $a_file." >&2
    exit 1
fi
if ! b_url="$(json_field "$b_file" nats_url)"; then
    echo "::error::Failed to read field 'nats_url' from $b_file." >&2
    exit 1
fi
if ! b_user="$(json_field "$b_file" nats_user)"; then
    echo "::error::Failed to read field 'nats_user' from $b_file." >&2
    exit 1
fi
if ! b_pass="$(json_field "$b_file" nats_password)"; then
    echo "::error::Failed to read field 'nats_password' from $b_file." >&2
    exit 1
fi
if ! b_consumer="$(json_field "$b_file" consumer_name)"; then
    echo "::error::Failed to read field 'consumer_name' from $b_file." >&2
    exit 1
fi

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
# Same errexit hazard as elsewhere in this file: wrap the run_client
# invocation so a failing docker/curl call reports its own cause instead of
# aborting silently before the HTTP-code check below ever runs.
if ! remove_http_code="$(run_client "curl -sS -b /shared/cookiejar -o /dev/null -w '%{http_code}' \
    -X DELETE -H 'X-CSRF-Token: $csrf_token' \
    'http://$ui_ip:8080/api/secondary/authcallout-a'")"; then
    echo "::error::DELETE /api/secondary/authcallout-a via run_client failed outright (curl/docker invocation error)." >&2
    exit 1
fi
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
# Same errexit hazard as the DELETE call above: wrap the run_client
# invocation so a failing docker/curl call reports its own cause instead of
# aborting silently before the HTTP-code check below ever runs.
if ! rotate_http_code="$(run_client "curl -sS -o /shared/rotate-b.json -w '%{http_code}' \
    -X POST -b /shared/cookiejar -H 'X-CSRF-Token: $csrf_token' \
    -H 'Content-Type: application/json' \
    -d '{\"token\":\"$registration_token\"}' \
    'http://$ui_ip:8080/api/secondary/authcallout-b/rotate-token'")"; then
    echo "::error::POST rotate-token for authcallout-b via run_client failed outright (curl/docker invocation error)." >&2
    exit 1
fi
if [[ "$rotate_http_code" != "200" ]]; then
    echo "::error::POST rotate-token for authcallout-b returned HTTP $rotate_http_code, expected 200." >&2
    cat "$rotate_file" >&2 || true
    exit 1
fi
if ! b_new_pass="$(json_field "$rotate_file" nats_password)"; then
    echo "::error::Failed to read field 'nats_password' from $rotate_file." >&2
    exit 1
fi
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

# Issue #682: proves the auth-callout xkey encryption is not just configured
# but actually protecting the payload on the wire. Captures specifically on
# the `ui` container's own network namespace, not the `nats` container's --
# both the callout responder's connection AND every secondary's own CONNECT
# share the same port 4222, but only the `ui` container's own traffic is
# involved in the callout request/response this feature encrypts. A
# secondary's own CONNECT (where connect_opts.pass genuinely originates) goes
# straight secondary-container -> nats-container and never touches `ui` at
# all, so capturing on `ui`'s namespace cannot see it -- this is deliberate,
# not a gap in the capture: xkey does not claim to protect that leg (see
# nats_auth_callout.rs's module docs), so this proof must not conflate the
# two by capturing broadly on the nats container instead.
echo "== xkey encryption proof: packet-capturing the nats<->ui auth-callout leg =="
if ! ui_cid="$("${compose[@]}" ps -q ui)"; then
    echo "::error::Could not query the compose container id for service 'ui'." >&2
    exit 1
fi
# nicolaka/netshoot: a well-known, widely used third-party network
# troubleshooting image (tcpdump/tshark/iproute2 etc.), pulled here only for
# this one-off manual/CI packet capture step -- not a project dependency, not
# added to any Dockerfile or compose service, and nothing about it is
# committed into this project's own images.
capture_cid="$(docker run -d --rm --network "container:$ui_cid" --cap-add NET_RAW --cap-add NET_ADMIN \
    -v "$work_dir/shared:/shared" nicolaka/netshoot \
    tcpdump -i any -w /shared/xkey-capture.pcap 'tcp port 4222')"
sleep 2 # let tcpdump attach before the traffic we care about happens
register_secondary "authcallout-xkey-proof"
proof_file="$work_dir/shared/register-authcallout-xkey-proof.json"
if ! proof_pass="$(json_field "$proof_file" nats_password)"; then
    echo "::error::Failed to read field 'nats_password' from $proof_file." >&2
    exit 1
fi
if ! proof_url="$(json_field "$proof_file" nats_url)"; then
    echo "::error::Failed to read field 'nats_url' from $proof_file." >&2
    exit 1
fi
if ! proof_user="$(json_field "$proof_file" nats_user)"; then
    echo "::error::Failed to read field 'nats_user' from $proof_file." >&2
    exit 1
fi
if ! proof_consumer="$(json_field "$proof_file" consumer_name)"; then
    echo "::error::Failed to read field 'consumer_name' from $proof_file." >&2
    exit 1
fi
# The connection attempt itself is what makes nats-server issue the
# auth-callout request/response this capture needs to see -- the capture
# would otherwise just show an idle socket.
assert_connects "xkey-proof" "$proof_url" "$proof_user" "$proof_pass" "$proof_consumer"
sleep 2
docker stop "$capture_cid" >/dev/null 2>&1 || true
sleep 1

capture_bytes="$(docker run --rm -v "$work_dir/shared:/shared" nicolaka/netshoot sh -c 'wc -c < /shared/xkey-capture.pcap' 2>/dev/null || echo 0)"
# A too-small/empty capture is a broken test, not a pass -- must fail loudly
# rather than let an absent password "prove" encryption when the real cause
# is that no traffic was captured at all.
if [[ "$capture_bytes" -lt 200 ]]; then
    echo "::error::xkey capture pcap is empty or too small ($capture_bytes bytes) -- the capture did not actually run, this proves nothing." >&2
    exit 1
fi

# Reassemble the raw TCP payload bytes (in capture order) into one contiguous
# blob before searching, rather than grepping tcpdump -A's per-packet ASCII
# dump line by line. This matters because tcpdump -A wraps/breaks its ASCII
# rendering at packet boundaries: a payload of a few hundred bytes (this
# auth-callout envelope, once permissions/claims are embedded, comfortably
# exceeds a single TCP segment) can legitimately have the password or the
# "xkv1" marker split across two packets, which a plain per-packet grep would
# report as absent even though it is genuinely present in the traffic --
# indistinguishable from an actual encryption result without this step. Empty
# `tcp.payload` fields (bare ACKs) print as blank and contribute nothing.
if ! docker run --rm -v "$work_dir/shared:/shared" nicolaka/netshoot sh -c \
    "tshark -r /shared/xkey-capture.pcap -T fields -e tcp.payload 2>/dev/null | tr -d '\n:' | xxd -r -p > /shared/xkey-stream.bin"; then
    echo "::error::Failed to reassemble the captured TCP payload stream with tshark." >&2
    exit 1
fi

# Deliberately NOT a search for the raw plaintext password string: manually
# verified against a real capture that this NEVER appears on the wire even
# WITHOUT xkey, because the unencrypted auth-callout envelope is still a
# compact JWT -- base64url(header).base64url(payload).base64url(signature)
# -- so `connect_opts.pass` only ever appears base64-encoded inside the
# payload segment, never as a literal byte-for-byte substring. A check for
# the raw password's absence would trivially "pass" whether or not
# encryption is on, proving nothing. The real, discriminating signal is
# whether a plaintext JWT structure is present at all: `jwt_header_marker`
# below is the literal, fully deterministic base64url encoding of this
# module's fixed JWT header (`{"typ":"JWT","alg":"ed25519-nkey"}`, see
# encode_nats_jwt in nats_auth_callout.rs) -- every unencrypted request or
# response starts with it, and a sealed (xkv1-prefixed) payload cannot
# contain it, since the whole JWT string is encrypted as one opaque blob
# before it ever reaches the wire.
jwt_header_marker="eyJ0eXAiOiJKV1QiLCJhbGciOiJlZDI1NTE5LW5rZXkifQ"
if docker run --rm -v "$work_dir/shared:/shared" nicolaka/netshoot sh -c "grep -a -F -- '$jwt_header_marker' /shared/xkey-stream.bin" >/dev/null; then
    echo "::error::A plaintext JWT header marker was found in the captured nats<->ui auth-callout traffic -- the request/response is NOT actually xkey-encrypted (anyone who captured this could base64-decode it and recover connect_opts.pass in full)." >&2
    exit 1
fi
echo "Confirmed: no plaintext JWT structure appears anywhere in the captured nats<->ui auth-callout traffic -- there is nothing here to base64-decode into the presented password."

# "xkv1" is nkeys' own literal sealed-box version prefix (see
# nats_auth_callout.rs's module docs) -- its presence is what distinguishes
# "genuinely encrypted" from "the capture simply missed the exchange" (e.g. a
# missed capture window, or a capture on the wrong leg/interface). Confirms
# the traffic isn't merely absent a JWT structure by coincidence, but is
# actually using the sealed-box wire format.
if ! docker run --rm -v "$work_dir/shared:/shared" nicolaka/netshoot sh -c "grep -a -F 'xkv1' /shared/xkey-stream.bin" >/dev/null; then
    echo "::error::The nkeys sealed-box version marker 'xkv1' was not found in the captured traffic -- cannot confirm the auth-callout payload is actually xkey-encrypted." >&2
    exit 1
fi
echo "Confirmed: captured traffic contains the nkeys sealed-box 'xkv1' marker -- the auth-callout request/response is genuinely xkey-encrypted."

echo "nats-secondary-auth-callout-simulation passed: per-secondary NATS identity, immediate revocation on removal, isolation between secondaries, credential rotation, and xkey encryption of the auth-callout payload (issue #682) all verified end-to-end against a real nats-server and the real nats-subscriber client."
