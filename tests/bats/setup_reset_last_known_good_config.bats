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

# The dns/pdns target is deliberately not implemented yet (depends on #628); it
# must fail closed with the pointer, never silently no-op.
@test "cmd_reset dispatch fails closed for the not-yet-implemented dns target" {
    run cmd_reset_to_last_known_good_config dns
    [ "$status" -ne 0 ]
    [[ "$output" == *"#628"* ]]
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
