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

# shellcheck source=scripts/lib/reserve-validation-subnet.sh
source "$repo_root/scripts/lib/reserve-validation-subnet.sh"

# Which images the fresh-install phase (and every follow-on `setup.sh update`,
# via the .env it writes) brings the stack up on. The deep-validate workflow
# resolves these from the triggering event and passes them in:
#
#   * Same-repo PR  -> SETUP_SIM_IMAGE_CHANNEL=pinned + SETUP_SIM_IMAGE_TAG=
#     pr-<N>-sha-<short>, this PR's OWN immutable per-commit image set (built by
#     build-push, back-filled by ensure-pr-staging-images). This is the whole
#     point of the change that added these vars: the gate now tests THIS PR's
#     images against THIS PR's checked-out setup.sh/quickstart compose, so no
#     channel-promotion timing can ever make it validate stale, months-old code
#     (the old hardcoded `edge` did exactly that while master/edge sat frozen).
#   * workflow_dispatch / fork / Dependabot -> SETUP_SIM_IMAGE_CHANNEL set to
#     the base-ref channel (dev for a v0.2.0 PR, edge for master -- resolved by
#     the workflow, never hardcoded), SETUP_SIM_IMAGE_TAG empty. No PR staging
#     tag exists for those, so setup.sh's normal channel->stack-pointer->sha
#     resolution is exercised instead (and stays covered on those events).
#
# Defaults keep a bare local `bash scripts/setup-cli-simulation.sh` working:
# edge is the only channel guaranteed to have published images pre-1.0. CI
# always sets SETUP_SIM_IMAGE_CHANNEL explicitly, so this default is a
# local-run convenience only, not a hardcoded-channel CI gate.
#
# These are applied ONLY to the Phase 1 fresh-install invocation below (as a
# per-command env prefix on that one `expect` call), never exported process-
# wide: Phase 2's `setup.sh update` reads the channel/tag straight out of the
# .env Phase 1 wrote, and Phase 3 deliberately sabotages that .env's tag to
# force a pull failure -- a process-wide LANCACHE_IMAGE_TAG export would shadow
# that sabotaged .env value and make the rollback-safety phase silently pull a
# real image and pass for the wrong reason.
fresh_install_image_channel="${SETUP_SIM_IMAGE_CHANNEL:-edge}"
fresh_install_image_tag="${SETUP_SIM_IMAGE_TAG:-}"

# Without this, git inside this container treats the bind-mounted repo (owned
# by the host runner's UID, not this container's root) as having "dubious
# ownership" and refuses every git command, including the `git describe
# --tags --exact-match` setup.sh's derive_release_archive_image_tag() relies
# on to distinguish "no exact release tag, use the edge/latest channel"
# from "this is a source archive with no .git at all, read VERSION instead".
# Confirmed directly: without this line, a fresh install on a non-tagged
# commit incorrectly fell through to the VERSION file (currently "1.0.1")
# and tried to pull an ghcr.io/.../ui:v1.0.1 image that was never published,
# instead of resolving the intended edge/latest channel. This is likely a
# real latent issue for `sudo ./setup.sh` against a repo cloned by a
# different user too -- see issue filed against setup.sh separately.
git config --global --add safe.directory "$repo_root"

# install_dir must be a path this container and the host Docker daemon both
# resolve to the same real directory. docker compose (run through the
# bind-mounted host socket) always resolves bind-mount sources against the
# HOST filesystem, not this container's -- a plain /tmp/... path only exists
# inside this container's own ephemeral layer, so the host daemon can't find
# it and silently auto-creates it as an empty directory instead, then fails
# trying to bind-mount that directory onto a file destination (e.g.
# dhcp-probe.sh). Confirmed directly: that produced exactly this "mount
# src=... dst=/usr/local/bin/dhcp-probe.sh: not a directory" failure. /work
# (this checkout, bind-mounted from the same host path the workflow step
# runs in) is the only path both sides agree on, so the install directory
# has to live under it instead of under /tmp.
# deploy/quickstart/docker-compose.yml pins a static top-level `name:
# lancache-ng`, and Compose prefers that yaml name over the --project-
# directory basename it would otherwise derive -- so every docker compose
# call below resolves to the SAME project (and therefore the same
# container/volume names) on every run unless COMPOSE_PROJECT_NAME is set,
# regardless of install_dir already being unique per run. Confirmed directly
# (run 29322035897): two concurrent runs on the shared self-hosted runner
# pool both resolved to project "lancache-ng", and setup.sh's own
# guard_restore_shared_project_volumes (#669) then correctly refused to
# proceed once it saw another active install under that name -- the guard
# is doing its job, this script just never gave concurrent runs the
# isolation it assumes. Deriving the project name from install_dir's own
# basename keeps it unique per run with zero new randomness/collision
# surface. Compose validates an explicit COMPOSE_PROJECT_NAME against
# ^[a-z0-9][a-z0-9_-]*$ (lowercase alnum/dash/underscore only), so the
# mktemp basename (e.g. "install.Tm4lJy": a literal dot, mixed-case letters)
# must be sanitized first, not exported verbatim. A real end-user install is
# unaffected: it never sets SETUP_SIM_INSTALL_DIR, so this function is only
# ever called by this simulation script -- the static "lancache-ng" name
# from the compose yaml stays exactly as-is for real installs (see #669 item
# 6 for why that stays intentionally fixed there).
sim_compose_project_name() {
    printf 'lancache-ng-sim-%s\n' "$(basename "$1" | tr 'A-Z.' 'a-z-')"
}

mkdir -p "$repo_root/.setup-cli-simulation-tmp"
install_dir="$(mktemp -d "$repo_root/.setup-cli-simulation-tmp/install.XXXXXX")"
# cmd_backup's --dest defaults to /var/backups/lancache-ng and cmd_update
# never overrides it, so that is where the pre-update rollback backup this
# script verifies in Phase 3 actually lands -- a container-local path with no
# effect outside this script's own container.
backup_root="/var/backups/lancache-ng"
export SETUP_SIM_INSTALL_DIR="$install_dir"
COMPOSE_PROJECT_NAME="$(sim_compose_project_name "$install_dir")"
export COMPOSE_PROJECT_NAME

cleanup() {
    local status=$?
    if [[ -f "$install_dir/docker-compose.yml" ]]; then
        docker compose --project-directory "$install_dir" -f "$install_dir/docker-compose.yml" --env-file "$install_dir/.env" down -v --remove-orphans >/dev/null 2>&1 || true
    fi
    # `down` above can lose the "has active endpoints" race (see
    # validation_project_networks_teardown's own comment in
    # reserve-validation-subnet.sh) and silently leave a network non-empty.
    # This project's name is unique per install_dir, so a lost race here
    # only leaks one orphaned network rather than poisoning a sibling job --
    # still needs a real wait+retry instead of leaking it forever.
    validation_project_networks_teardown "$COMPOSE_PROJECT_NAME" || true
    rm -rf "$install_dir" "$repo_root/.setup-cli-simulation-tmp" "$backup_root"
    exit "$status"
}
trap cleanup EXIT

# Mirrors the proven health-wait pattern from full-setup-validate.yml: only
# proxy and dns-standard declare a real healthcheck in this minimal profile
# (SSL/DHCP/scheduled-updates/logging all disabled), everything else is only
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

run_fresh_install_expect() {
    # Per-command env prefix: exports LANCACHE_IMAGE_CHANNEL/TAG for this expect
    # process (and the `bash setup.sh` it spawns) only -- see the note at the
    # top of this script for why they must NOT leak into Phases 2-4. An empty
    # LANCACHE_IMAGE_TAG is equivalent to unset for setup.sh (it reads every
    # occurrence via ${LANCACHE_IMAGE_TAG:-} and -n guards), so the base-ref-
    # channel path passes it through harmlessly.
    LANCACHE_IMAGE_CHANNEL="$fresh_install_image_channel" \
    LANCACHE_IMAGE_TAG="$fresh_install_image_tag" \
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


# setup.sh must be told which images to install: its own deliberate default
# is the stable `latest` channel, which has no published images pre-1.0, so an
# unqualified fresh install correctly refuses to proceed (see
# resolve_lancache_image_channel's comment). The surrounding bash script has
# already exported LANCACHE_IMAGE_CHANNEL (and, for a same-repo PR, the pinned
# LANCACHE_IMAGE_TAG) with the values the deep-validate workflow resolved from
# the event; expect inherits that environment and spawn passes it straight
# through to setup.sh, so this phase installs the PR's own pinned image set on
# a PR and the base-ref channel otherwise -- never a hardcoded channel here.
spawn bash setup.sh

expect_prompt {Server IP \(Standard mode\)} "127.0.0.2"
expect_prompt {Enable SSL mode\? \[y/N\]} ""
expect_prompt {Directory[^\n]*\[} $install_dir
expect_prompt {Cache directory \(absolute path\)} ""
expect_prompt {Cache size in GiB} ""
expect_prompt {Cache RAM buffer in MB} ""
expect_prompt {Enable scheduled automatic updates\?} ""
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
}

# This runs on a shared self-hosted runner tier where other jobs (and other
# concurrent workflow runs) can bind the common 127.0.0.1 loopback address
# too. Confirmed directly: hit "port is already allocated" for
# 127.0.0.1:443 repeatedly, with no lingering container or bound port
# visible on the runner moments later -- not a stuck leftover from one
# specific job, just contention over the one address every other host-bound
# stack on this runner also defaults to. The real fix is IP_STANDARD =
# 127.0.0.2 above (loopback range is 127.0.0.0/8, so any 127.x.x.x address
# routes locally without needing a real interface) instead of 127.0.0.1,
# giving this simulation its own address nothing else on the runner
# specifically targets. This retry loop stays as a second line of defense
# in case something else ever binds 127.0.0.2 too, mirroring the existing
# retry-on-transient-GHCR-403 pattern already used elsewhere in this
# project's CI.
fresh_install_log="$repo_root/.setup-cli-simulation-tmp/fresh-install-attempt.log"
attempt=1
while true; do
    if run_fresh_install_expect >"$fresh_install_log" 2>&1; then
        cat "$fresh_install_log"
        break
    fi
    cat "$fresh_install_log"
    if grep -qF 'port is already allocated' "$fresh_install_log" && [[ "$attempt" -lt 5 ]]; then
        echo "::warning::Fresh install attempt $attempt hit a transient port-allocation race; retrying." >&2
        docker compose --project-directory "$install_dir" -f "$install_dir/docker-compose.yml" --env-file "$install_dir/.env" down -v --remove-orphans >/dev/null 2>&1 || true
        # Still under the OLD COMPOSE_PROJECT_NAME here (see the comment
        # below) -- must tear its network(s) down before it is reassigned,
        # for the same "has active endpoints" reason cleanup() does.
        validation_project_networks_teardown "$COMPOSE_PROJECT_NAME" || true
        rm -rf "$install_dir"
        install_dir="$(mktemp -d "$repo_root/.setup-cli-simulation-tmp/install.XXXXXX")"
        export SETUP_SIM_INSTALL_DIR="$install_dir"
        # Re-derive to match the new install_dir -- the preceding `down` call
        # above still ran under the OLD exported COMPOSE_PROJECT_NAME (correct:
        # it must tear down the failed attempt's own project), so this must be
        # reassigned only after that, not before.
        COMPOSE_PROJECT_NAME="$(sim_compose_project_name "$install_dir")"
        export COMPOSE_PROJECT_NAME
        fresh_install_log="$repo_root/.setup-cli-simulation-tmp/fresh-install-attempt.log"
        attempt=$((attempt + 1))
        sleep 10
        continue
    fi
    echo "::error::Fresh install failed (attempt $attempt)." >&2
    exit 1
done

[[ -f "$install_dir/.env" ]] \
    || { echo "::error::Fresh install did not produce $install_dir/.env." >&2; exit 1; }
grep -qF 'IP_STANDARD=127.0.0.2' "$install_dir/.env" \
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

echo "== Phase 2b: repeat-run idempotence (setup.sh update run twice in a row, same input) =="

# tests/bats/setup_update_idempotence.bats already proves migrate_env_for_update()
# itself is a stable fixed point on repeat calls, but only at the function
# boundary -- it deliberately pins the image tag so resolve_lancache_image_tag()
# never needs a real `docker pull`, and it never runs the surrounding
# cmd_update wrapper (install_quickstart_compose_assets, cmd_backup, the
# actual image pull/restart). This phase closes that gap: it runs the real
# `setup.sh update` CLI a second consecutive time against the exact .env
# Phase 2 just produced, with no input change in between, and asserts the
# real CLI -- not just the extracted function -- lands on the same fixed
# point instead of drifting or rotating secrets.
cp "$install_dir/.env" "$install_dir/.env.after-first-update"
secret_keys='^(KEA_CTRL_TOKEN|DDNS_TSIG_KEY|PDNS_API_KEY|NATS_UI_PASSWORD|NATS_DNS_WRITER_PASSWORD|NATS_DNS_REPLICA_PASSWORD|NATS_CALLOUT_PASSWORD|SECONDARY_REGISTRATION_TOKEN|UI_AUTH_PASSWORD)='
grep -E "$secret_keys" "$install_dir/.env.after-first-update" | sort > "$install_dir/.secrets-after-first-update"

bash setup.sh update "$install_dir"
wait_for_stack_healthy

# LANCACHE_IMAGE_TAG/CHANNEL are excluded from the byte-diff for the same
# reason Phase 3 already excludes them below. On the base-ref-channel path
# (dispatch/fork) this fixture carries a moving channel from Phase 1's fresh
# install, so resolve_lancache_image_tag() re-resolves it through a real
# `docker pull` of the channel pointer image on every update call -- expected,
# not drift, unless a real regression flips it to a *different* digest between
# two calls seconds apart. On the same-repo-PR path it carries CHANNEL=pinned +
# the immutable pr-<N>-sha tag, which resolves verbatim and would stay
# byte-identical anyway; excluding both keys keeps this assertion valid on
# either path without special-casing which one produced the .env.
diff -q \
    <(grep -Ev '^(LANCACHE_IMAGE_TAG|LANCACHE_IMAGE_CHANNEL)=' "$install_dir/.env.after-first-update") \
    <(grep -Ev '^(LANCACHE_IMAGE_TAG|LANCACHE_IMAGE_CHANNEL)=' "$install_dir/.env") >/dev/null \
    || { echo "::error::A second consecutive setup.sh update changed .env with no input change -- convergence/idempotence regression (AG-OP-011)." >&2; diff <(grep -Ev '^(LANCACHE_IMAGE_TAG|LANCACHE_IMAGE_CHANNEL)=' "$install_dir/.env.after-first-update") <(grep -Ev '^(LANCACHE_IMAGE_TAG|LANCACHE_IMAGE_CHANNEL)=' "$install_dir/.env") >&2; exit 1; }

grep -E "$secret_keys" "$install_dir/.env" | sort > "$install_dir/.secrets-after-second-update"
diff -q "$install_dir/.secrets-after-first-update" "$install_dir/.secrets-after-second-update" >/dev/null \
    || { echo "::error::A second consecutive setup.sh update rotated one or more stable secrets (AG-OP-006)." >&2; exit 1; }

echo "A second consecutive setup.sh update with no input change left .env and all stable secrets byte-identical."

echo "== Phase 3: rollback safety (forced platform-preflight failure during update) =="

cp "$install_dir/.env" "$install_dir/.env.before-forced-failure"
# LANCACHE_IMAGE_CHANNEL must be forced to "pinned" too, not just the tag,
# regardless of what Phase 1 left behind: on the base-ref-channel path the
# .env still names a moving channel (dev/edge), and with a moving channel set
# resolve_lancache_image_tag() resolves the tag from the channel pointer and
# never even looks at the literal LANCACHE_IMAGE_TAG value -- confirmed
# directly, the update just silently re-pulled the real channel images and
# succeeded instead of failing. pinned is the one channel value that makes
# resolution use LANCACHE_IMAGE_TAG verbatim (the same-repo-PR path is already
# pinned, so this sed is a no-op for CHANNEL there and only swaps the tag).
# The fake tag still has to match the real sha-* format (validate_lancache_
# image_tag rejects anything else before a pull is even attempted), so this is
# a syntactically valid but non-existent digest, not an arbitrary string.
sed -i \
    -e 's/^LANCACHE_IMAGE_CHANNEL=.*/LANCACHE_IMAGE_CHANNEL=pinned/' \
    -e 's/^LANCACHE_IMAGE_TAG=.*/LANCACHE_IMAGE_TAG=sha-0000000/' \
    "$install_dir/.env"

set +e
bash setup.sh update "$install_dir" >"$install_dir/update-failure.log" 2>&1
update_exit_code=$?
set -e

[[ "$update_exit_code" -ne 0 ]] \
    || { echo "::error::setup.sh update did not fail as expected against a non-existent image tag." >&2; cat "$install_dir/update-failure.log" >&2; exit 1; }
# assert_resolved_image_tag_platform_supported (#665) now runs at the very
# top of migrate_env_for_update, before the image pull this phase used to
# rely on failing -- `docker buildx imagetools inspect` against this
# non-existent sha-0000000 tag should fail closed with "Failed to inspect
# ...", not the old "Failed to pull required container images" from further
# down in cmd_update: with the platform preflight in place, this scenario is
# expected to never reach the actual `docker compose pull` step at all.
grep -qF 'Failed to inspect' "$install_dir/update-failure.log" \
    || { echo "::error::setup.sh update failed for an unexpected reason; expected the image-tag platform preflight to reject the non-existent tag." >&2; cat "$install_dir/update-failure.log" >&2; exit 1; }

[[ -s "$install_dir/.env" ]] \
    || { echo "::error::setup.sh update left .env empty after a failed update -- unsafe partial state." >&2; exit 1; }
diff -q \
    <(grep -Ev '^(LANCACHE_IMAGE_TAG|LANCACHE_IMAGE_CHANNEL)=' "$install_dir/.env.before-forced-failure") \
    <(grep -Ev '^(LANCACHE_IMAGE_TAG|LANCACHE_IMAGE_CHANNEL)=' "$install_dir/.env") >/dev/null \
    || { echo "::error::setup.sh update changed unrelated .env keys during a failed update -- unsafe partial state." >&2; exit 1; }
find "$backup_root" -name 'lancache-ng-config-*.tar.gz' -print -quit | grep -q . \
    || { echo "::error::setup.sh update did not create a pre-update rollback backup before failing." >&2; exit 1; }
echo "setup.sh update failed safely on a broken image tag at the platform preflight: .env is intact and a rollback backup exists."

# Not asserted: that the stack stays up and healthy through the failed
# attempt above. cmd_backup --config itself stops and restarts the stack
# for a consistent snapshot as the very first step of cmd_update, before
# the pull this phase deliberately breaks even runs -- and that restart
# uses the same already-poisoned .env, so it cannot come back up either.
# Confirmed directly: every service was stopped after the failed attempt,
# not merely left at its pre-update state. That's an unavoidable
# consequence of sabotaging .env before calling update, not a bug in
# setup.sh -- so the meaningful rollback-safety property to verify is
# recoverability, not zero downtime: restore the last-known-good .env and
# confirm setup.sh update actually recovers the stack.
cp "$install_dir/.env.before-forced-failure" "$install_dir/.env"
bash setup.sh update "$install_dir"
wait_for_stack_healthy
echo "setup.sh update recovered the stack once the .env was restored to its last-known-good state."

echo "== Phase 4: setup.sh restore re-converges .env (issue #639) =="

# Phase 4a: restoring an already-converged backup must be a no-op for .env,
# mirroring AG-OP-011's "repeat run changes nothing" property for update.
echo "-- Phase 4a: restoring an already-converged backup is a no-op for .env --"
bash setup.sh backup --config "$install_dir" --dest "$backup_root"
noop_backup="$(find "$backup_root" -maxdepth 1 -name 'lancache-ng-config-*.tar.gz' | sort | tail -1)"
[[ -n "$noop_backup" ]] \
    || { echo "::error::No config backup was found to test restore no-op convergence." >&2; exit 1; }

cp "$install_dir/.env" "$install_dir/.env.before-noop-restore"
bash setup.sh restore "$noop_backup" "$install_dir"
diff -q \
    <(grep -Ev '^(LANCACHE_IMAGE_TAG|LANCACHE_IMAGE_CHANNEL)=' "$install_dir/.env.before-noop-restore") \
    <(grep -Ev '^(LANCACHE_IMAGE_TAG|LANCACHE_IMAGE_CHANNEL)=' "$install_dir/.env") >/dev/null \
    || { echo "::error::setup.sh restore changed .env while restoring an already-converged backup -- expected a no-op (issue #639)." >&2; exit 1; }
wait_for_stack_healthy
echo "Restoring an already-converged backup left .env unchanged and the stack healthy."

# Phase 4b: a backup from an older install can carry a legacy-format .env
# (split cache keys, a stale strict security mode) captured verbatim at
# backup time. cmd_backup only ever archives the *current*, already-migrated
# .env, so the only way to reproduce a real legacy backup here is to take a
# known-good archive and rewrite its embedded .env to the pre-#456 shape --
# the same fixture shape tests/bats/setup_update_idempotence.bats and Phase 2
# above already use against migrate_env_for_update() directly, reused here
# against the real `setup.sh restore` CLI instead of the extracted function.
echo "-- Phase 4b: restoring a legacy-format backup converges .env the same way setup.sh update does --"
legacy_backup_root="$repo_root/.setup-cli-simulation-tmp/legacy-backup"
rm -rf "$legacy_backup_root"
mkdir -p "$legacy_backup_root"
tar -C "$legacy_backup_root" -xzf "$noop_backup"
legacy_stamp_dir="$(find "$legacy_backup_root" -mindepth 1 -maxdepth 1 -type d | head -1)"
[[ -n "$legacy_stamp_dir" ]] \
    || { echo "::error::Could not extract the synthetic legacy backup fixture." >&2; exit 1; }
legacy_env_path="$legacy_stamp_dir/rootfs${install_dir}/.env"
[[ -f "$legacy_env_path" ]] \
    || { echo "::error::Could not locate .env inside the synthetic legacy backup fixture." >&2; exit 1; }

# Point the split legacy keys at the install's real, already-populated cache
# directory instead of an arbitrary path: after migrate_env_for_update()
# collapses them back into CACHE_DIR, the post-restore stack actually mounts
# this path, so an arbitrary non-existent path would fail the health check
# below for an unrelated reason and mask what this phase is testing.
real_cache_dir=$(grep '^CACHE_DIR=' "$legacy_env_path" | head -1 | cut -d= -f2-)
[[ -n "$real_cache_dir" ]] \
    || { echo "::error::Synthetic legacy backup fixture has no CACHE_DIR to seed the legacy split keys from." >&2; exit 1; }
sed -i \
    -e '/^CACHE_DIR=/d' \
    -e "\$a CACHE_DIR_STANDARD=${real_cache_dir}" \
    -e "\$a CACHE_DIR_SSL=${real_cache_dir}" \
    -e 's/^PROXY_SECURITY_MODE=.*/PROXY_SECURITY_MODE=strict/' \
    -e 's/^PROXY_ALLOWED_CLIENT_CIDRS=.*/PROXY_ALLOWED_CLIENT_CIDRS=/' \
    "$legacy_env_path"
grep -qF 'PROXY_SECURITY_MODE=strict' "$legacy_env_path" \
    || { echo "::error::Could not seed the synthetic legacy backup's PROXY_SECURITY_MODE=strict fixture." >&2; exit 1; }

legacy_archive="$repo_root/.setup-cli-simulation-tmp/lancache-ng-config-legacy-restore-test.tar.gz"
tar -C "$legacy_backup_root" -czf "$legacy_archive" "$(basename "$legacy_stamp_dir")"

bash setup.sh restore "$legacy_archive" "$install_dir"

grep -qF "CACHE_DIR=${real_cache_dir}" "$install_dir/.env" \
    || { echo "::error::setup.sh restore did not collapse legacy CACHE_DIR_STANDARD/CACHE_DIR_SSL into CACHE_DIR (issue #639)." >&2; exit 1; }
grep -q '^CACHE_DIR_STANDARD=' "$install_dir/.env" \
    && { echo "::error::setup.sh restore left the legacy CACHE_DIR_STANDARD key behind (issue #639)." >&2; exit 1; }
grep -qF 'PROXY_SECURITY_MODE=lazy' "$install_dir/.env" \
    || { echo "::error::setup.sh restore did not migrate the legacy PROXY_SECURITY_MODE=strict value back to lazy (issue #639)." >&2; exit 1; }
wait_for_stack_healthy
echo "setup.sh restore converged a legacy-format backup's .env the same way setup.sh update does (issue #639)."

rm -rf "$legacy_backup_root" "$legacy_archive"

echo "setup.sh CLI simulation passed: fresh install, update/migration, rollback safety, and restore convergence all verified against the real CLI."
