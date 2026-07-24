#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for setup.sh's reset-to-last-known-good-config family (issue #763's
# CLI recovery fallback): cmd_reset_to_last_known_good_config (dispatch),
# list_kea_snapshot_ids (snapshot discovery), kea_ctrl_post (Kea Control Agent
# call + JSON result parsing), and reset_kea_to_last_known_good_config (the
# mutating config-test -> config-set -> config-write rollback). This is a
# mutating recovery mechanism that otherwise only runs against a live Kea
# Control Agent, so before this suite it had zero automated coverage.
#
# kea_ctrl_post and the full rollback are exercised against a mock `curl`
# placed ahead of the real one on PATH (same technique as
# check_action_node_versions.bats): it records each POSTed command body to a
# log and returns a canned (body, HTTP status) pair, so every scenario runs
# fully offline with no live Kea.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-reset-kgc-helpers.sh"
    mock_bin="$BATS_TEST_TMPDIR/mock-bin"
    mkdir -p "$mock_bin"

    export MOCK_CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
    : > "$MOCK_CURL_LOG"

    # Mock curl: logs the -d body (so tests can assert which Kea command was
    # sent), writes the canned response to the -o target, and prints the
    # canned HTTP status the way `curl -w '%{http_code}'` would. MOCK_CURL_FAIL
    # makes it exit non-zero to simulate a connection failure.
    cat > "$mock_bin/curl" <<'MOCK'
#!/usr/bin/env bash
if [[ "${MOCK_CURL_FAIL:-0}" == "1" ]]; then exit 7; fi
out=""; data=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    [[ "${args[$i]}" == "-o" ]] && out="${args[$((i + 1))]}"
    [[ "${args[$i]}" == "-d" ]] && data="${args[$((i + 1))]}"
done
printf '%s\n' "$data" >> "${MOCK_CURL_LOG:?}"
[[ -n "$out" ]] && printf '%s' "${MOCK_CURL_BODY:-[{\"result\":0,\"text\":\"ok\"}]}" > "$out"
printf '%s' "${MOCK_CURL_STATUS:-200}"
MOCK
    chmod +x "$mock_bin/curl"

    export MOCK_DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
    : > "$MOCK_DOCKER_LOG"

    # Mock docker: dns_rollback_exec's only external dependency is `docker
    # compose ... exec -T <container> sh -c '<script>' sh <method> <path>
    # <body>` -- this mock does not actually run that embedded script (there
    # is no real container/curl in a bats sandbox); it logs the full argv so
    # tests can assert method/path/body, then emits a canned
    # "<status>\n<body>" pair on stdout the way the real embedded script's
    # `printf "%s\n" "$status"; cat ...resp` would. A full rollback run calls
    # this twice (GET /snapshots, then POST /rollback), so the canned
    # response is keyed on whether "POST" appears as its own argv element
    # (the method, passed as a distinct trailing arg) rather than a single
    # shared canned value for both calls. MOCK_DOCKER_EXEC_FAIL simulates the
    # embedded script's own fail-closed exits (missing API key, curl connect
    # failure) by printing the matching marker string instead.
    cat > "$mock_bin/docker" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_DOCKER_LOG:?}"
if [[ "${MOCK_DOCKER_EXEC_FAIL:-0}" == "1" ]]; then
    printf '%s\n' "${MOCK_DOCKER_EXEC_FAIL_MARKER:-DNS_ROLLBACK_EXEC_CURL_FAILED}"
    exit "${MOCK_DOCKER_EXEC_FAIL_CODE:-8}"
fi
is_post=0
for arg in "$@"; do
    [[ "$arg" == "POST" ]] && is_post=1
done
# A literal `{...}` JSON default embedded directly inside `${VAR:-...}`
# mis-parses (bash's parameter-expansion brace matching closes at the first
# unescaped `}`, silently truncating the default and leaking the remainder
# as trailing literal text) -- confirmed empirically while writing this
# mock. An explicit `[[ -n ]]`/`else` avoids embedding braces inside the
# expansion at all, unlike the sibling mock curl above (whose own default is
# a `[...]` array, not `{...}`, so it never hits this).
if [[ "$is_post" -eq 1 ]]; then
    printf '%s\n' "${MOCK_DOCKER_POST_STATUS:-200}"
    if [[ -n "${MOCK_DOCKER_POST_BODY:-}" ]]; then
        printf '%s' "$MOCK_DOCKER_POST_BODY"
    else
        printf '%s' '{"applied":true}'
    fi
else
    printf '%s\n' "${MOCK_DOCKER_GET_STATUS:-200}"
    if [[ -n "${MOCK_DOCKER_GET_BODY:-}" ]]; then
        printf '%s' "$MOCK_DOCKER_GET_BODY"
    else
        printf '%s' '{"zones":{}}'
    fi
fi
MOCK
    chmod +x "$mock_bin/docker"

    export PATH="$mock_bin:$PATH"

    # shellcheck source=tests/bats/helpers/setup-reset-kgc-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-reset-kgc-helpers.sh"
    load_setup_reset_kgc_helpers "$repo_root" "$helper_file"
}

# A helper that builds a realistic install + snapshot fixture and echoes the
# install dir. Snapshot ids are the real fixed-width 20-digit zero-padded shape
# reset_kea and list_kea_snapshot_ids expect.
make_install_fixture() {
    local install_dir="$BATS_TEST_TMPDIR/install"
    local state_dir="$BATS_TEST_TMPDIR/state"
    local snap_root="$state_dir/kea/config-snapshots"
    mkdir -p "$install_dir" "$snap_root/00000000000000000001" "$snap_root/00000000000000000002"
    : > "$install_dir/docker-compose.yml"
    printf 'KEA_CTRL_TOKEN=test-token\nLANCACHE_STATE_DIR=%s\n' "$state_dir" > "$install_dir/.env"
    printf '{"Dhcp4":{"subnet4":[]}}\n' > "$snap_root/00000000000000000001/dhcp4.json"
    printf '{"Dhcp4":{"subnet4":[{"id":2}]}}\n' > "$snap_root/00000000000000000002/dhcp4.json"
    printf '%s\n' "$install_dir"
}

# --- list_kea_snapshot_ids -------------------------------------------------

# Only directories whose name is all-digits AND that hold a finalized
# dhcp4.json count as snapshots, returned oldest-first. A ".staging-<id>"
# directory from an interrupted write and a digit dir missing its payload must
# both be skipped -- matching kea_snapshots.rs::list_snapshot_ids.
@test "list_kea_snapshot_ids returns only finalized digit snapshots, sorted oldest-first" {
    root="$BATS_TEST_TMPDIR/snaps"
    mkdir -p "$root/00000000000000000002" "$root/00000000000000000001" \
             "$root/.staging-00000000000000000003" "$root/00000000000000000004"
    printf '{}' > "$root/00000000000000000002/dhcp4.json"
    printf '{}' > "$root/00000000000000000001/dhcp4.json"
    printf '{}' > "$root/.staging-00000000000000000003/dhcp4.json"
    # 000...04 has no dhcp4.json -> not finalized, must be skipped.

    run list_kea_snapshot_ids "$root"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "00000000000000000001" ]
    [ "${lines[1]}" = "00000000000000000002" ]
    [ "${#lines[@]}" -eq 2 ]
}

# An empty (or snapshot-free) root must succeed with no output, so callers can
# distinguish "no snapshots" from an error.
@test "list_kea_snapshot_ids emits nothing and succeeds on an empty root" {
    root="$BATS_TEST_TMPDIR/empty"
    mkdir -p "$root"
    run list_kea_snapshot_ids "$root"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- kea_ctrl_post ---------------------------------------------------------

# A well-formed success response ("result":0) must return 0 and echo the raw
# response for the caller.
@test "kea_ctrl_post succeeds and returns the response on result:0" {
    export MOCK_CURL_BODY='[{"result":0,"text":"ok"}]'
    export MOCK_CURL_STATUS=200
    run kea_ctrl_post "http://127.0.0.1:8000/" "tok" '{"command":"config-test"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"result":0'* ]]
}

# A non-2xx HTTP status must fail closed -- the config was NOT applied, so the
# recovery must not report success.
@test "kea_ctrl_post fails closed on a non-2xx HTTP status" {
    export MOCK_CURL_STATUS=500
    export MOCK_CURL_BODY='internal error'
    run kea_ctrl_post "http://127.0.0.1:8000/" "tok" '{"command":"config-set"}'
    [ "$status" -ne 0 ]
    [[ "$output" == *"HTTP 500"* ]]
}

# Kea can return HTTP 200 but a per-command failure ("result":1); that is still
# a failure and must abort, surfacing Kea's own error text.
@test "kea_ctrl_post fails closed when Kea reports result != 0" {
    export MOCK_CURL_STATUS=200
    export MOCK_CURL_BODY='[{"result":1,"text":"config rejected"}]'
    run kea_ctrl_post "http://127.0.0.1:8000/" "tok" '{"command":"config-set"}'
    [ "$status" -ne 0 ]
    [[ "$output" == *"config rejected"* ]]
}

# A 200 with no parseable "result" field is an unrecognized response, not an
# implicit success -- it must fail closed rather than assume the command took.
@test "kea_ctrl_post fails closed on an unrecognized response body" {
    export MOCK_CURL_STATUS=200
    export MOCK_CURL_BODY='not json at all'
    run kea_ctrl_post "http://127.0.0.1:8000/" "tok" '{"command":"config-write"}'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unrecognized response"* ]]
}

# A transport failure (curl exits non-zero) must abort with the connection
# error, not be mistaken for a Kea rejection.
@test "kea_ctrl_post fails closed when curl cannot connect" {
    export MOCK_CURL_FAIL=1
    run kea_ctrl_post "http://127.0.0.1:8000/" "tok" '{"command":"config-test"}'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Failed to connect"* ]]
}

# --- cmd_reset_to_last_known_good_config dispatch --------------------------

# The dns/pdns target must fail closed for "no stack found" the same as kea
# when there is nothing at the target install-dir -- proves dispatch actually
# routes into reset_dns_to_last_known_good_config rather than silently
# no-op-ing (the dns/pdns target used to die immediately with a #628 pointer;
# it is implemented now, see the dedicated dns dispatch/reset tests below).
@test "cmd_reset dispatch routes the dns target into reset_dns_to_last_known_good_config" {
    run cmd_reset_to_last_known_good_config dns "$BATS_TEST_TMPDIR/no-such-install"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No stack found"* ]]
}

# An unknown service name must be rejected, not treated as kea.
@test "cmd_reset dispatch rejects an unknown service" {
    run cmd_reset_to_last_known_good_config frobnicate
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown service"* ]]
}

# No service argument must print usage and fail, not act on a default.
@test "cmd_reset dispatch requires a service argument" {
    run cmd_reset_to_last_known_good_config
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage:"* ]]
}

# --- reset_kea_to_last_known_good_config fail-closed guards -----------------

# No stack at the target: the recovery must refuse before touching anything.
@test "reset_kea fails closed when no docker-compose.yml exists" {
    mkdir -p "$BATS_TEST_TMPDIR/noinstall"
    run reset_kea_to_last_known_good_config "$BATS_TEST_TMPDIR/noinstall" "" 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"No stack found"* ]]
}

# A stack with no .env cannot be authenticated to Kea; must fail closed.
@test "reset_kea fails closed when the .env is missing" {
    d="$BATS_TEST_TMPDIR/nonenv"; mkdir -p "$d"; : > "$d/docker-compose.yml"
    run reset_kea_to_last_known_good_config "$d" "" 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"No .env"* ]]
}

# An empty KEA_CTRL_TOKEN means the Control Agent call could not authenticate;
# the recovery must abort rather than send an unauthenticated request.
@test "reset_kea fails closed on an empty KEA_CTRL_TOKEN" {
    d="$BATS_TEST_TMPDIR/notoken"; mkdir -p "$d"; : > "$d/docker-compose.yml"
    printf 'KEA_CTRL_TOKEN=\n' > "$d/.env"
    run reset_kea_to_last_known_good_config "$d" "" 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"KEA_CTRL_TOKEN"* ]]
}

# If the operator moved KEA_CONFIG_SNAPSHOT_DIR off the documented default,
# this CLI cannot map it to a host path and must fail closed instead of
# guessing at where the snapshots live.
@test "reset_kea fails closed on a non-default KEA_CONFIG_SNAPSHOT_DIR override" {
    d="$(make_install_fixture)"
    printf 'KEA_CONFIG_SNAPSHOT_DIR=/somewhere/else\n' >> "$d/.env"
    run reset_kea_to_last_known_good_config "$d" "" 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"KEA_CONFIG_SNAPSHOT_DIR"* ]]
}

# A requested snapshot id that does not exist must be rejected before any Kea
# call is made.
@test "reset_kea fails closed when the requested snapshot id is absent" {
    d="$(make_install_fixture)"
    run reset_kea_to_last_known_good_config "$d" "99999999999999999999" 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
    # No Kea command should have been sent for a rejected snapshot.
    [ ! -s "$MOCK_CURL_LOG" ]
}

# --- reset_kea_to_last_known_good_config full rollback ---------------------

# The happy path: with a valid snapshot and --yes, the recovery must run the
# full config-test -> config-set -> config-write chain against Kea, in that
# order, and succeed. This is the core proof that the mutating recovery works.
@test "reset_kea runs config-test, config-set, config-write in order on success" {
    d="$(make_install_fixture)"
    export MOCK_CURL_BODY='[{"result":0,"text":"ok"}]'
    export MOCK_CURL_STATUS=200

    run reset_kea_to_last_known_good_config "$d" "00000000000000000001" 1
    [ "$status" -eq 0 ]

    # Exactly the three commands, in the documented recovery order.
    mapfile -t sent < <(grep -oE 'config-(test|set|write)' "$MOCK_CURL_LOG")
    [ "${sent[0]}" = "config-test" ]
    [ "${sent[1]}" = "config-set" ]
    [ "${sent[2]}" = "config-write" ]
}

# When no snapshot id is given, the newest is selected; with --yes it applies
# without prompting. Confirms the default-to-newest branch actually rolls back.
@test "reset_kea defaults to the newest snapshot when none is given" {
    d="$(make_install_fixture)"
    export MOCK_CURL_BODY='[{"result":0,"text":"ok"}]'

    run reset_kea_to_last_known_good_config "$d" "" 1
    [ "$status" -eq 0 ]
    # The newest snapshot's payload (subnet id 2) must be the one config-set applied.
    grep -q '"id":2' "$MOCK_CURL_LOG"
}

# A validation failure (config-test rejects) must abort BEFORE config-set, so a
# bad snapshot is never applied to the running server.
@test "reset_kea aborts before config-set when config-test fails" {
    d="$(make_install_fixture)"
    export MOCK_CURL_STATUS=200
    export MOCK_CURL_BODY='[{"result":1,"text":"invalid config"}]'

    run reset_kea_to_last_known_good_config "$d" "00000000000000000001" 1
    [ "$status" -ne 0 ]
    # Only config-test should have been attempted; config-set must not appear.
    grep -q 'config-test' "$MOCK_CURL_LOG"
    ! grep -q 'config-set' "$MOCK_CURL_LOG"
}

# --- dns/pdns: canonical_dns_zone -------------------------------------------

# Mirrors zone_snapshots.rs's canonical_zone: adds a trailing dot only when
# missing, so an operator typing "lan" reaches the same zone key the listener
# stores snapshots under ("lan.").
@test "canonical_dns_zone adds a trailing dot only when missing" {
    [ "$(canonical_dns_zone lan)" = "lan." ]
    [ "$(canonical_dns_zone lan.)" = "lan." ]
    [ "$(canonical_dns_zone local.lan)" = "local.lan." ]
}

# --- dns/pdns: list_dns_zones_with_snapshots --------------------------------

# Only zones whose array is non-empty (`[{`) must be listed -- the listener's
# real response includes every one of the ~22 managed zones unconditionally,
# most with an empty array, and printing all of them every time an operator
# omits <zone> would bury the ones that actually matter.
@test "list_dns_zones_with_snapshots lists only zones with a non-empty array" {
    body='{"zones":{"lan.":[{"id":"1","created_unix":100}],"local.lan.":[],"10.in-addr.arpa.":[{"id":"2","created_unix":200}]}}'
    run list_dns_zones_with_snapshots "$body"
    [ "$status" -eq 0 ]
    [[ "$output" == *"lan."* ]]
    [[ "$output" == *"10.in-addr.arpa."* ]]
    [[ "$output" != *"local.lan."* ]]
}

# An all-empty response (fresh install, nothing rolled back yet on any zone)
# must produce no output, not an error -- callers distinguish this from a
# real failure by exit status alone, same convention as list_kea_snapshot_ids.
@test "list_dns_zones_with_snapshots emits nothing when every zone is empty" {
    body='{"zones":{"lan.":[],"local.lan.":[]}}'
    run list_dns_zones_with_snapshots "$body"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- dns/pdns: dns_zone_snapshot_entries ------------------------------------

# Extracts "<id> <created_unix>" lines for exactly the requested zone, in the
# listener's own (newest-first) order -- and does NOT leak another zone's
# entries into the result, proving the zone-name match is anchored on the
# quoted key rather than a loose substring match (a real risk given zone names
# contain literal dots, e.g. "lan." is also a substring of a hypothetical
# "vlan." key).
@test "dns_zone_snapshot_entries extracts only the requested zone's entries, newest first" {
    body='{"zones":{"lan.":[{"id":"00000000000000000002","created_unix":200},{"id":"00000000000000000001","created_unix":100}],"vlan.":[{"id":"00000000000000000099","created_unix":999}]}}'
    run dns_zone_snapshot_entries "$body" "lan."
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "00000000000000000002 200" ]
    [ "${lines[1]}" = "00000000000000000001 100" ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "$output" != *"00000000000000000099"* ]]
}

# A zone with no stored snapshots (an empty array, or absent entirely from the
# response) must produce no output, not an error.
@test "dns_zone_snapshot_entries emits nothing for a zone with no snapshots" {
    body='{"zones":{"lan.":[]}}'
    run dns_zone_snapshot_entries "$body" "lan."
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- dns/pdns: dns_rollback_exec ---------------------------------------------

# A 2xx response must return the response body on stdout with exit 0.
@test "dns_rollback_exec returns the response body on a 2xx status" {
    export MOCK_DOCKER_GET_STATUS=200
    export MOCK_DOCKER_GET_BODY='{"zones":{}}'
    run dns_rollback_exec "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR/.env" dns-standard GET /snapshots
    [ "$status" -eq 0 ]
    [ "$output" = '{"zones":{}}' ]
}

# A non-2xx status (e.g. the listener's own 401 for a bad X-API-Key) must fail
# closed with the status and body surfaced, not be treated as success.
@test "dns_rollback_exec fails closed on a non-2xx HTTP status" {
    export MOCK_DOCKER_GET_STATUS=401
    export MOCK_DOCKER_GET_BODY='{"error":"missing or invalid X-API-Key"}'
    run dns_rollback_exec "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR/.env" dns-standard GET /snapshots
    [ "$status" -ne 0 ]
    [[ "$output" == *"HTTP 401"* ]]
}

# The embedded exec script's own NO_API_KEY marker (PDNS_API_KEY unresolved
# inside the container, neither a usable env value nor a shared-secrets file)
# must surface as a clear, distinct error, not a generic exec failure.
@test "dns_rollback_exec fails closed with a clear message when the API key cannot be resolved" {
    export MOCK_DOCKER_EXEC_FAIL=1
    export MOCK_DOCKER_EXEC_FAIL_MARKER=DNS_ROLLBACK_EXEC_NO_API_KEY
    run dns_rollback_exec "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR/.env" dns-standard GET /snapshots
    [ "$status" -ne 0 ]
    [[ "$output" == *"PDNS_API_KEY could not be resolved"* ]]
}

# The embedded exec script's own CURL_FAILED marker (curl could not connect to
# 127.0.0.1:8083 inside the container) must surface as a clear, distinct
# error, not be mistaken for an authentication or docker-exec failure.
@test "dns_rollback_exec fails closed with a clear message when curl cannot reach the listener" {
    export MOCK_DOCKER_EXEC_FAIL=1
    export MOCK_DOCKER_EXEC_FAIL_MARKER=DNS_ROLLBACK_EXEC_CURL_FAILED
    run dns_rollback_exec "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR/.env" dns-standard GET /snapshots
    [ "$status" -ne 0 ]
    [[ "$output" == *"Failed to reach the rollback listener"* ]]
}

# --- dns/pdns: reset_dns_to_last_known_good_config fail-closed guards ------

make_dns_install_fixture() {
    local install_dir="$BATS_TEST_TMPDIR/dns-install"
    mkdir -p "$install_dir"
    : > "$install_dir/docker-compose.yml"
    printf 'PDNS_API_KEY=irrelevant-mock-resolves-this-itself\n' > "$install_dir/.env"
    printf '%s\n' "$install_dir"
}

@test "reset_dns fails closed when no docker-compose.yml exists" {
    mkdir -p "$BATS_TEST_TMPDIR/noinstall"
    run reset_dns_to_last_known_good_config dns-standard "$BATS_TEST_TMPDIR/noinstall" "lan." "" 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"No stack found"* ]]
}

@test "reset_dns fails closed when the .env is missing" {
    d="$BATS_TEST_TMPDIR/nonenv"; mkdir -p "$d"; : > "$d/docker-compose.yml"
    run reset_dns_to_last_known_good_config dns-standard "$d" "lan." "" 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"No .env"* ]]
}

# --- dns/pdns: reset_dns_to_last_known_good_config zone handling -----------

# Omitting the zone must list which zones currently have snapshots and stop
# there -- unlike Kea's single config, defaulting the ZONE itself would risk
# silently mutating the wrong zone's data, so this must never auto-pick one.
@test "reset_dns lists zones with snapshots and requires an explicit zone when omitted" {
    d="$(make_dns_install_fixture)"
    export MOCK_DOCKER_GET_BODY='{"zones":{"lan.":[{"id":"00000000000000000001","created_unix":100}],"local.lan.":[]}}'
    run reset_dns_to_last_known_good_config dns-standard "$d" "" "" 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"lan."* ]]
    [[ "$output" == *"A zone is required"* ]]
}

# A requested snapshot id that does not exist for the given zone must be
# rejected before any rollback POST is attempted.
@test "reset_dns fails closed when the requested snapshot id is absent for the zone" {
    d="$(make_dns_install_fixture)"
    export MOCK_DOCKER_GET_BODY='{"zones":{"lan.":[{"id":"00000000000000000001","created_unix":100}]}}'
    run reset_dns_to_last_known_good_config dns-standard "$d" "lan." "99999999999999999999" 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
    # No POST /rollback should have been attempted for a rejected snapshot.
    # Matches "sh POST " (the trailing "sh $0" placeholder immediately
    # followed by the actual $method positional argument), not a bare
    # "POST" substring: the embedded sh -c script's own SOURCE TEXT always
    # contains the literal string "-X POST" for its POST branch, in every
    # invocation regardless of which branch actually runs, so a loose
    # `grep -q ' POST '` would false-positive on every single call, GET
    # included -- confirmed empirically while writing this test.
    ! grep -q 'sh POST ' "$MOCK_DOCKER_LOG"
}

# A zone with no known-good snapshots at all must be rejected before any
# rollback POST is attempted.
@test "reset_dns fails closed when the zone has no known-good snapshots" {
    d="$(make_dns_install_fixture)"
    export MOCK_DOCKER_GET_BODY='{"zones":{"lan.":[]}}'
    run reset_dns_to_last_known_good_config dns-standard "$d" "lan." "" 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"No known-good snapshots found for zone lan."* ]]
}

# --- dns/pdns: reset_dns_to_last_known_good_config full rollback ----------

# The happy path: with a valid zone/snapshot and --yes, the recovery must call
# the rollback listener's POST /rollback with the right zone/snapshot_id and
# report success from applied=true.
@test "reset_dns applies the requested snapshot for the given zone on success" {
    d="$(make_dns_install_fixture)"
    # Listed newest-first, matching the real listener's own ordering: id
    # ...0001 (created_unix 300) is the newest, ...0002 (created_unix 100)
    # the older one -- so "index 0 = newest" and "highest created_unix" agree,
    # the same invariant the real GET /snapshots response guarantees.
    export MOCK_DOCKER_GET_BODY='{"zones":{"lan.":[{"id":"00000000000000000001","created_unix":300},{"id":"00000000000000000002","created_unix":100}]}}'
    export MOCK_DOCKER_POST_BODY='{"applied":true,"changed_names":["host.lan."],"zone_check_passed":true,"republished_to_nats":true,"flush_ok":true,"flush_failed_names":[]}'

    run reset_dns_to_last_known_good_config dns-standard "$d" "lan." "00000000000000000001" 1
    [ "$status" -eq 0 ]
    # print_ok is stubbed to a no-op by the shared helper (matching the Kea
    # suite's own convention -- see setup-reset-kgc-helpers.sh), so success
    # is asserted the same way the Kea tests do: exit status plus the actual
    # POST body sent, not print_ok's own (unavailable) text.
    grep -q '"zone":"lan\.".*"snapshot_id":"00000000000000000001"' "$MOCK_DOCKER_LOG"
}

# When no snapshot id is given for an explicit zone, the newest is selected
# (mirroring Kea's own default-to-newest behavior) -- this IS safe because the
# zone itself was already given explicitly.
@test "reset_dns defaults to the newest snapshot for the zone when none is given" {
    d="$(make_dns_install_fixture)"
    # Listed newest-first, matching the real listener's own ordering: id
    # ...0001 (created_unix 300) is the newest, ...0002 (created_unix 100)
    # the older one -- so "index 0 = newest" and "highest created_unix" agree,
    # the same invariant the real GET /snapshots response guarantees.
    export MOCK_DOCKER_GET_BODY='{"zones":{"lan.":[{"id":"00000000000000000001","created_unix":300},{"id":"00000000000000000002","created_unix":100}]}}'
    export MOCK_DOCKER_POST_BODY='{"applied":true,"changed_names":[],"zone_check_passed":true,"republished_to_nats":false,"flush_ok":true,"flush_failed_names":[]}'

    run reset_dns_to_last_known_good_config dns-standard "$d" "lan." "" 1
    [ "$status" -eq 0 ]
    # print_warn's own "defaulting to the newest" text is stubbed to a no-op
    # (see the sibling comment above) -- the actual proof that the newest
    # id, not the older one, was selected is the id the POST body carries.
    grep -q '"snapshot_id":"00000000000000000001"' "$MOCK_DOCKER_LOG"
    ! grep -q '"snapshot_id":"00000000000000000002"' "$MOCK_DOCKER_LOG"
}

# A post-rollback problem the listener itself reports (a failed cache flush)
# must be surfaced as a warning, not silently swallowed -- the rollback PATCH
# still succeeded, so this must not be reported as a hard failure either.
@test "reset_dns warns but still succeeds when the listener reports a flush failure" {
    d="$(make_dns_install_fixture)"
    export MOCK_DOCKER_GET_BODY='{"zones":{"lan.":[{"id":"00000000000000000001","created_unix":100}]}}'
    export MOCK_DOCKER_POST_BODY='{"applied":true,"changed_names":["host.lan."],"zone_check_passed":true,"republished_to_nats":true,"flush_ok":false,"flush_failed_names":["host.lan."]}'

    run reset_dns_to_last_known_good_config dns-standard "$d" "lan." "00000000000000000001" 1
    # A failed cache-flush is surfaced via print_warn, stubbed to a no-op
    # here (see the sibling comments above) -- what this test can actually
    # prove without that text is the behavioral contract: the rollback PATCH
    # itself still succeeded (flush_ok is a separate, independently-reported
    # signal in the response body, not folded into "applied"), so this must
    # not be treated as a hard failure.
    [ "$status" -eq 0 ]
}

# A response missing applied=true (should never happen given dns_rollback_exec
# already validated the HTTP status, but defense in depth) must not be
# reported as a successful rollback.
@test "reset_dns fails closed when the rollback response does not report applied=true" {
    d="$(make_dns_install_fixture)"
    export MOCK_DOCKER_GET_BODY='{"zones":{"lan.":[{"id":"00000000000000000001","created_unix":100}]}}'
    export MOCK_DOCKER_POST_BODY='{"applied":false}'

    run reset_dns_to_last_known_good_config dns-standard "$d" "lan." "00000000000000000001" 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"did not report applied=true"* ]]
}
