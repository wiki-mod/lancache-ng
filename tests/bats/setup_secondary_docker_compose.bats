#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for setup.sh's cmd_secondary() function, which generates
# a docker-compose.yml for secondary DNS nodes. Guards against issue #652,
# where the healthcheck block was missing from the generated heredoc and
# kept regressing on refactors.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "cmd_secondary heredoc in setup.sh contains healthcheck block" {
    # Regression test for #652: the heredoc that generates the secondary
    # docker-compose.yml must include a healthcheck block. This block is
    # critical for PowerDNS health detection in production.
    #
    # Extract the heredoc from setup.sh's cmd_secondary function (lines between
    # 'write_generated_runtime_file "${secondary_dir}/docker-compose.yml" <<EOF'
    # and the closing EOF), then verify it contains the healthcheck block with
    # all required fields in the correct YAML structure.

    local heredoc_start heredoc_end extracted_heredoc

    # Find the write_generated_runtime_file line that starts the docker-compose.yml heredoc
    heredoc_start=$(grep -n 'write_generated_runtime_file "${secondary_dir}/docker-compose.yml" <<EOF' \
        "$repo_root/setup.sh" | cut -d: -f1)

    [[ -n "$heredoc_start" ]] || skip "Could not find cmd_secondary heredoc start"

    # Extract lines from the start until the closing EOF on its own line
    # This is a simple regex-based extraction; sed is used to grab the range
    extracted_heredoc=$(sed -n "$((heredoc_start)),$((heredoc_start + 100))p" "$repo_root/setup.sh" \
        | sed '/^EOF$/q')

    # Verify the essential healthcheck fields are present in order
    echo "$extracted_heredoc" | grep -q "healthcheck:" \
        || fail "healthcheck: block missing"

    echo "$extracted_heredoc" | grep -q "test: \[\"CMD\", \"rec_control\", \"ping\"\]" \
        || fail "healthcheck test command missing or incorrect"

    echo "$extracted_heredoc" | grep -q "interval: 30s" \
        || fail "healthcheck interval missing"

    echo "$extracted_heredoc" | grep -q "timeout: 5s" \
        || fail "healthcheck timeout missing"

    echo "$extracted_heredoc" | grep -q "retries: 3" \
        || fail "healthcheck retries missing"

    echo "$extracted_heredoc" | grep -q "start_period: 20s" \
        || fail "healthcheck start_period missing"

    # Verify the healthcheck block comes after the ports block and before restart
    # by checking line ordering in the extracted heredoc
    local ports_line healthcheck_line restart_line

    ports_line=$(echo "$extracted_heredoc" | grep -n "ports:" | head -1 | cut -d: -f1)
    healthcheck_line=$(echo "$extracted_heredoc" | grep -n "healthcheck:" | head -1 | cut -d: -f1)
    restart_line=$(echo "$extracted_heredoc" | grep -n "restart: always" | head -1 | cut -d: -f1)

    [[ -n "$ports_line" && -n "$healthcheck_line" && -n "$restart_line" ]] \
        || fail "Could not determine line order of ports/healthcheck/restart blocks"

    [[ "$ports_line" -lt "$healthcheck_line" ]] \
        || fail "healthcheck block must come after ports block"

    [[ "$healthcheck_line" -lt "$restart_line" ]] \
        || fail "healthcheck block must come before restart block"
}

@test "cmd_secondary gives an actionable message for the issue #866 HTTP 503 refusal" {
    # Issue #866: register_secondary now refuses (HTTP 503) when the primary
    # has neither NATS_BIND_IP nor NATS_ADVERTISE_URL configured, instead of
    # silently handing out an unreachable NATS URL. Before this fix,
    # cmd_secondary's only non-2xx handling was one generic
    # "verify the registration token, secondary name, and primary server
    # logs" message -- accurate for a bad token/name (4xx), but actively
    # misleading for this 503 case, which is a primary-side configuration
    # gap the operator can't fix by re-checking their own command-line
    # arguments. Guards against that specific, more helpful branch
    # regressing back into the generic one on a future refactor.
    grep -q 'http_status" = "503"' "$repo_root/setup.sh" \
        || fail "cmd_secondary no longer special-cases HTTP 503"

    grep -q 'NATS_BIND_IP.*NATS_ADVERTISE_URL' "$repo_root/setup.sh" \
        || fail "the 503 die message no longer names NATS_BIND_IP/NATS_ADVERTISE_URL as the fix"

    # Setting NATS_BIND_IP/NATS_ADVERTISE_URL and restarting only the `ui`
    # container is not sufficient: the `nats` service itself still needs
    # docker-compose.nats-secondary.yml included (and to be recreated with
    # it) to actually publish port 4222 on that address. Guards against the
    # message regressing to only mention restarting `ui`, which would leave
    # an operator who follows it literally with the same silent
    # never-syncs failure mode issue #866 reports, just one step later.
    grep -q 'nats-secondary\.yml' "$repo_root/setup.sh" \
        || fail "the 503 die message no longer tells the operator to recreate the nats service with the nats-secondary.yml override"
}
