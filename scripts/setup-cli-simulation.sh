#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Executes the real setup.sh CLI end-to-end instead of only bash -n syntax
# checking it (issue #403): a fresh install through its interactive prompts,
# an update/migration against a deliberately old-format .env fixture, and one
# rollback-safety scenario (a forced pull failure during update).
#
# The fresh-install phase drives setup.sh through expect because ask() reads
# explicitly from /dev/tty (so a plain `curl | bash` install still works),
# which means answers cannot be fed through a plain stdin pipe. This script
# is meant to run inside the build-tools container against the mounted
# Docker socket -- see docs/self-hosted-actions-runner.md.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
install_dir="$(mktemp -d /tmp/lancache-ng-setup-sim.XXXXXX)"
# cmd_backup's --dest defaults to /var/backups/lancache-ng and cmd_update
# never overrides it, so that is where the pre-update rollback backup this
# script verifies in Phase 3 actually lands -- a container-local path with no
# effect outside this script's own container.
backup_root="/var/backups/lancache-ng"
export SETUP_SIM_INSTALL_DIR="$install_dir"

cleanup() {
    local status=$?
    if [[ -f "$install_dir/docker-compose.yml" ]]; then
        docker compose --project-directory "$install_dir" -f "$install_dir/docker-compose.yml" --env-file "$install_dir/.env" down -v --remove-orphans >/dev/null 2>&1 || true
    fi
    rm -rf "$install_dir" "$backup_root"
    exit "$status"
}
trap cleanup EXIT

# Mirrors the proven health-wait pattern from full-setup-validate.yml: only
# proxy and dns-standard declare a real healthcheck in this minimal profile
# (SSL/DHCP/Watchtower/logging all disabled), everything else is only
# checked for "running" plus a restart-count ceiling (catches a crash loop
# without needing a healthcheck definition for every service).
wait_for_stack_healthy() {
    local compose=(docker compose --project-directory "$install_dir" -f "$install_dir/docker-compose.yml" --env-file "$install_dir/.env")
    local services_with_healthcheck="proxy dns-standard"
    local all_services="proxy dns-standard nats docker-socket-proxy watchdog ui netdata"
    local deadline=$((SECONDS + 90)) service cid status all_ready

    while (( SECONDS < deadline )); do
        all_ready=1
        for service in $services_with_healthcheck; do
            cid="$("${compose[@]}" ps -q "$service")"
            status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown")"
            [[ "$status" = "healthy" ]] || all_ready=0
        done
        [[ "$all_ready" -eq 1 ]] && break
        sleep 5
    done

    local failed=0
    for service in $all_services; do
        cid="$("${compose[@]}" ps -q "$service")"
        if [[ -z "$cid" ]]; then
            echo "::error::$service has no running container" >&2
            failed=1
            continue
        fi
        local restart_count container_status
        restart_count="$(docker inspect --format '{{.RestartCount}}' "$cid")"
        container_status="$(docker inspect --format '{{.State.Status}}' "$cid")"
        if [[ "$container_status" != "running" ]]; then
            echo "::error::$service is not running (state: $container_status)" >&2
            failed=1
        elif (( restart_count > 1 )); then
            echo "::error::$service has restarted $restart_count times (crash-loop suspected)" >&2
            failed=1
        fi
        if [[ " $services_with_healthcheck " == *" $service "* ]]; then
            status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown")"
            [[ "$status" = "healthy" ]] \
                || { echo "::error::$service did not become healthy (status: $status)" >&2; failed=1; }
        fi
    done

    if [[ "$failed" -eq 1 ]]; then
        "${compose[@]}" ps
        "${compose[@]}" logs --no-color
        return 1
    fi
}

echo "== Phase 1: fresh install (expect-driven) =="

expect -f - <<'EXPECT_SCRIPT'
set timeout 60
log_user 1
set install_dir $env(SETUP_SIM_INSTALL_DIR)

proc expect_prompt {pattern reply} {
    expect {
        -re $pattern { send "$reply\r" }
        timeout { send_error "\n::error::setup.sh CLI simulation timed out waiting for prompt matching: $pattern\n"; exit 1 }
        eof { send_error "\n::error::setup.sh exited unexpectedly while waiting for prompt matching: $pattern\n"; exit 1 }
    }
}

spawn bash setup.sh

expect_prompt {Server IP \(Standard mode\)} "127.0.0.1"
expect_prompt {Enable SSL mode\? \[y/N\]} ""
expect_prompt {Directory[^\n]*\[} $install_dir
expect_prompt {Cache directory \(absolute path\)} ""
expect_prompt {Cache size in GiB} ""
expect_prompt {Cache RAM buffer in MB} ""
expect_prompt {Enable optional Watchtower} ""
expect_prompt {DHCP mode \(disabled, kea, dnsmasq-proxy\)} ""
expect_prompt {Protect Admin-UI with password\? \[Y/n\]} ""
expect_prompt {Username[^\n]*\[admin\]} ""
expect_prompt {Start now\? \[Y/n\]} ""

set timeout 300
expect {
    -re {Stack started} {}
    -re {Failed to pull required container images} { send_error "\n::error::setup.sh CLI simulation: image pull failed during fresh install\n"; exit 1 }
    timeout { send_error "\n::error::setup.sh CLI simulation timed out waiting for the stack to start\n"; exit 1 }
    eof { send_error "\n::error::setup.sh exited before confirming the stack started\n"; exit 1 }
}

set timeout 10
expect eof
lassign [wait] pid spawnid os_error_flag exit_code
if {$exit_code != 0} {
    send_error "\n::error::setup.sh exited with code $exit_code during fresh install\n"
    exit $exit_code
}
EXPECT_SCRIPT

[[ -f "$install_dir/.env" ]] \
    || { echo "::error::Fresh install did not produce $install_dir/.env." >&2; exit 1; }
grep -qF 'IP_STANDARD=127.0.0.1' "$install_dir/.env" \
    || { echo "::error::.env is missing the expected IP_STANDARD value." >&2; exit 1; }
grep -qF 'UI_AUTH_USER=admin' "$install_dir/.env" \
    || { echo "::error::.env is missing the expected UI_AUTH_USER value." >&2; exit 1; }
wait_for_stack_healthy
echo "Fresh install produced a valid .env and a healthy running stack."

echo "== Phase 2: update/migration against a deliberately old-format .env =="

# Simulate an install that still carries the legacy strict-without-allowlist
# default this project moved away from (see setup.sh's
# migrate_proxy_security_mode_for_update, already covered at the unit level
# by tests/bats/setup_env_migration.bats) -- this phase proves the same
# migration also fires through the real `setup.sh update` CLI path, not only
# through the extracted-function bats fixture.
sed -i \
    -e 's/^PROXY_SECURITY_MODE=.*/PROXY_SECURITY_MODE=strict/' \
    -e 's/^PROXY_ALLOWED_CLIENT_CIDRS=.*/PROXY_ALLOWED_CLIENT_CIDRS=/' \
    "$install_dir/.env"
grep -qF 'PROXY_SECURITY_MODE=strict' "$install_dir/.env" \
    || { echo "::error::Could not seed the legacy PROXY_SECURITY_MODE=strict fixture." >&2; exit 1; }

bash setup.sh update "$install_dir"

grep -qF 'PROXY_SECURITY_MODE=lazy' "$install_dir/.env" \
    || { echo "::error::setup.sh update did not migrate the legacy PROXY_SECURITY_MODE=strict value back to lazy." >&2; exit 1; }
wait_for_stack_healthy
echo "setup.sh update migrated the legacy .env value and left a healthy running stack."

echo "== Phase 3: rollback safety (forced pull failure during update) =="

cp "$install_dir/.env" "$install_dir/.env.before-forced-failure"
sed -i 's/^LANCACHE_IMAGE_TAG=.*/LANCACHE_IMAGE_TAG=lancache-ng-setup-sim-nonexistent-tag/' "$install_dir/.env"

set +e
bash setup.sh update "$install_dir" >"$install_dir/update-failure.log" 2>&1
update_exit_code=$?
set -e

[[ "$update_exit_code" -ne 0 ]] \
    || { echo "::error::setup.sh update did not fail as expected against a non-existent image tag." >&2; cat "$install_dir/update-failure.log" >&2; exit 1; }
grep -qF 'Failed to pull required container images' "$install_dir/update-failure.log" \
    || { echo "::error::setup.sh update failed for an unexpected reason; expected an image pull failure." >&2; cat "$install_dir/update-failure.log" >&2; exit 1; }

[[ -s "$install_dir/.env" ]] \
    || { echo "::error::setup.sh update left .env empty after a failed update -- unsafe partial state." >&2; exit 1; }
diff -q <(grep -v '^LANCACHE_IMAGE_TAG=' "$install_dir/.env.before-forced-failure") <(grep -v '^LANCACHE_IMAGE_TAG=' "$install_dir/.env") >/dev/null \
    || { echo "::error::setup.sh update changed unrelated .env keys during a failed update -- unsafe partial state." >&2; exit 1; }
find "$backup_root" -name 'lancache-ng-config-*.tar.gz' -print -quit | grep -q . \
    || { echo "::error::setup.sh update did not create a pre-update rollback backup before failing." >&2; exit 1; }
wait_for_stack_healthy
echo "setup.sh update failed safely on a broken image tag: .env is intact, a rollback backup exists, and the previously-running stack is still healthy."

echo "setup.sh CLI simulation passed: fresh install, update/migration, and rollback safety all verified against the real CLI."
