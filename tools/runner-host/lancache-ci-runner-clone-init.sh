#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# CI runner host bootstrap: prepare a freshly provisioned (or disk-cloned)
# self-hosted runner host for GitHub Actions registration, WITHOUT ever
# performing the registration itself.
#
# Background (issue #1622): new runner host VMs in this fleet (e.g. the
# .81/.82/.84 light/heavy hosts added 2026-08) are provisioned as disk
# clones of an existing, already-registered runner host (lancache-240).
# Confirmed by direct SSH inspection, 2026-08-21: a freshly cloned host's
# /opt/actions-runner-N directories are NOT empty -- they carry the SOURCE
# host's own .runner/.credentials/.credentials_rsaparams files (private key
# material a runner uses to authenticate to GitHub as one specific,
# already-registered identity), plus multi-GB leftover backup archives
# (runner*.tgz) from whatever imaging process produced the clone. A runner
# identity belonging to one host must never be left sitting on a different
# host (maintainer decision, issue #1622: not treated as an active
# credential-compromise incident since nothing on the clone side ever
# started the runner service or communicated with GitHub using it, but it
# must be detected and removed before the CLONE is put into service).
#
# This script only prepares a host up to the point of running the real
# actions-runner `config.sh` -- registration itself needs a short-lived
# GitHub registration token (`gh api -X POST
# repos/<org>/<repo>/actions/runners/registration-token`) and remains a
# separate, deliberate, human-run step, same as actually starting/enabling
# the resulting systemd service. Neither this script nor any subcommand of
# it ever calls config.sh, installs a systemd unit for a runner instance, or
# starts a runner process -- it stops at "ready to register".
#
# Modes (see --help):
#   check         Read-only. Reports clone-artifact findings, docker/sudoers/
#                 group state, and disk usage. Writes nothing.
#   clean         Removes ONLY the clone artifacts `check` already flagged as
#                 foreign to this host (re-verified immediately before each
#                 removal). Requires CONFIRM_CLEAN=yes. Refuses to remove
#                 anything not independently re-confirmed as foreign, so it
#                 can never wipe a host's own real, already-registered runner
#                 state even if run there by mistake.
#   host-prep     Idempotent, non-disruptive: sudoers NOPASSWD drop-in for
#                 the runner user, adds that user to the docker group,
#                 installs the /opt/lancache-ci-hooks/{pre,post}-job-
#                 cleanup.sh pair (host-local, not repo-tracked -- same as
#                 they already are on every existing runner host) and this
#                 repo's own lancache-ci-cleanup timer/service (installed
#                 from the sibling files in this same directory).
#   runner-fetch  Downloads, checksum-verifies (against the GitHub Releases
#                 API asset digest), and extracts a specific actions-runner
#                 release directly into a target instance directory --
#                 deliberately NOT via an intermediate "extract then `cp -a`
#                 to every instance" template step, which is what stalled
#                 for several minutes on a resource-constrained clone host
#                 during this issue's own investigation. Writes that
#                 instance's `.env` hook wiring (ACTIONS_RUNNER_HOOK_JOB_*)
#                 but does not run config.sh or touch systemd.
#
# Usage (see README.md in this directory for the full per-host rollout
# procedure): invoke with an explicit interpreter (`bash
# lancache-ci-runner-clone-init.sh ...`), not
# `./lancache-ci-runner-clone-init.sh` -- like this directory's other two
# scripts, this repo's executable bit is unverifiable from a Windows
# authoring host with `core.filemode=false` (AG-VAL-024), so this script
# must not depend on it being set.
set -euo pipefail

RUNNER_OPT_ROOT="${RUNNER_OPT_ROOT:-/opt}"
RUNNER_HOOKS_DIR="${RUNNER_HOOKS_DIR:-/opt/lancache-ci-hooks}"
RUNNER_USER="${RUNNER_USER:-codex}"
# Minimum size before a stray /opt/*.tgz|*.tar.gz is flagged as a leftover
# clone-imaging backup rather than something intentionally placed there --
# the two confirmed real examples (issue #1622) were 6.7 GB and 14.3 GB.
STRAY_ARCHIVE_MIN_BYTES="${STRAY_ARCHIVE_MIN_BYTES:-1073741824}" # 1 GiB

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Derives a short "this host" token from `hostname` to compare against the
# host-number segment embedded in this fleet's actual runner-name convention
# (a-lancache-runner-240-1, b-lancache-runner-229-2, d-lancache-runner-241-1,
# gh-lancache-light-31-81, gh-lancache-heavy-30-84, ...): the LAST run of
# digits in the hostname. Confirmed against every runner name seen on the
# real fleet (2026-08-21 `gh api .../actions/runners` inspection) -- each
# one's trailing numeric segment is exactly the host's own last IP octet or
# equivalent host number, never shared between two different hosts.
own_host_token() {
    hostname | grep -oE '[0-9]+' | tail -n1
}

# True (exit 0) if a runner instance directory's recorded .runner identity
# belongs to a DIFFERENT host than this one -- i.e. is a clone leftover, not
# this host's own (possibly already-registered) identity. A directory with
# no .runner file at all is not "foreign" (it's simply unregistered yet) and
# is intentionally never flagged by this function.
is_foreign_runner_dir() {
    local dir="$1"
    local runner_json="$dir/.runner"
    [[ -f "$runner_json" ]] || return 1
    local agent_name
    agent_name="$(jq -r '.agentName // empty' "$runner_json" 2>/dev/null || true)"
    [[ -n "$agent_name" ]] || return 1
    local my_token
    my_token="$(own_host_token)"
    if [[ -z "$my_token" ]]; then
        echo "WARNING: could not derive a host token from 'hostname' output -- cannot safely classify $dir, treating as NOT foreign (fail closed, never auto-remove when unsure)." >&2
        return 1
    fi
    # agentName segments are hyphen-delimited (a-lancache-runner-240-1) --
    # match the host token as its own segment, not a substring, so host 1
    # can never accidentally match host 41's directory.
    if grep -qE "(^|-)${my_token}(-|$)" <<<"$agent_name"; then
        return 1 # belongs to this host
    fi
    return 0 # foreign
}

find_runner_dirs() {
    find "$RUNNER_OPT_ROOT" -maxdepth 1 -type d -name 'actions-runner*' 2>/dev/null | sort
}

find_stray_archives() {
    find "$RUNNER_OPT_ROOT" -maxdepth 1 -type f \( -name '*.tgz' -o -name '*.tar.gz' \) -size "+${STRAY_ARCHIVE_MIN_BYTES}c" 2>/dev/null | sort
}

cmd_check() {
    echo "Host: $(hostname)   own_host_token=$(own_host_token)"
    echo
    echo "--- Runner instance directories under $RUNNER_OPT_ROOT ---"
    local dir found=0
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        found=1
        if is_foreign_runner_dir "$dir"; then
            local agent_name
            agent_name="$(jq -r '.agentName // "?"' "$dir/.runner" 2>/dev/null || echo '?')"
            echo "  FOREIGN CLONE ARTIFACT: $dir  (belongs to: $agent_name)"
            [[ -f "$dir/.credentials" ]] && echo "    -> carries .credentials (private key material for that identity)"
        elif [[ -f "$dir/.runner" ]]; then
            local agent_name
            agent_name="$(jq -r '.agentName // "?"' "$dir/.runner" 2>/dev/null || echo '?')"
            echo "  own/registered: $dir  (agentName: $agent_name)"
        else
            echo "  unregistered (no .runner yet): $dir"
        fi
    done < <(find_runner_dirs)
    [[ "$found" -eq 1 ]] || echo "  (none found)"
    echo
    echo "--- Stray large archives under $RUNNER_OPT_ROOT (>= ${STRAY_ARCHIVE_MIN_BYTES} bytes) ---"
    local archive found_archive=0
    while IFS= read -r archive; do
        [[ -n "$archive" ]] || continue
        found_archive=1
        echo "  $archive  ($(du -h "$archive" 2>/dev/null | cut -f1))"
    done < <(find_stray_archives)
    [[ "$found_archive" -eq 1 ]] || echo "  (none found)"
    echo
    echo "--- Sudoers / docker group for $RUNNER_USER ---"
    if sudo -n test -f "/etc/sudoers.d/${RUNNER_USER}-nopasswd" 2>/dev/null; then
        echo "  /etc/sudoers.d/${RUNNER_USER}-nopasswd: present"
    else
        echo "  /etc/sudoers.d/${RUNNER_USER}-nopasswd: MISSING"
    fi
    if id -nG "$RUNNER_USER" 2>/dev/null | grep -qw docker; then
        echo "  $RUNNER_USER in docker group: yes"
    else
        echo "  $RUNNER_USER in docker group: MISSING"
    fi
    echo
    echo "--- lancache-ci-hooks ---"
    for f in pre-job-cleanup.sh post-job-cleanup.sh; do
        if [[ -f "$RUNNER_HOOKS_DIR/$f" ]]; then
            echo "  $RUNNER_HOOKS_DIR/$f: present"
        else
            echo "  $RUNNER_HOOKS_DIR/$f: MISSING"
        fi
    done
    echo
    echo "--- lancache-ci-cleanup timer ---"
    if systemctl is-enabled lancache-ci-cleanup.timer >/dev/null 2>&1; then
        echo "  lancache-ci-cleanup.timer: $(systemctl is-enabled lancache-ci-cleanup.timer 2>/dev/null)/$(systemctl is-active lancache-ci-cleanup.timer 2>/dev/null)"
    else
        echo "  lancache-ci-cleanup.timer: not installed"
    fi
    echo
    echo "--- Disk usage ($RUNNER_OPT_ROOT's filesystem) ---"
    df -h "$RUNNER_OPT_ROOT"
    echo
    echo "No files were changed (check mode)."
}

cmd_clean() {
    if [[ "${CONFIRM_CLEAN:-}" != "yes" ]]; then
        echo "ERROR: refusing to remove anything without CONFIRM_CLEAN=yes." >&2
        echo "Run 'check' first and review its findings." >&2
        return 1
    fi
    local removed_any=0
    local dir
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        # Re-verify immediately before removal (not just trusting an earlier
        # check's output) -- defense in depth against this dir's contents
        # having changed between an operator's 'check' run and this 'clean'
        # run.
        if is_foreign_runner_dir "$dir"; then
            echo "Removing foreign clone artifact: $dir"
            sudo rm -rf -- "$dir"
            removed_any=1
        fi
    done < <(find_runner_dirs)
    local archive
    while IFS= read -r archive; do
        [[ -n "$archive" ]] || continue
        echo "Removing stray archive: $archive"
        sudo rm -f -- "$archive"
        removed_any=1
    done < <(find_stray_archives)
    if [[ "$removed_any" -eq 0 ]]; then
        echo "Nothing to remove -- no foreign runner directories or stray archives found."
    else
        echo "Clean complete. Re-run 'check' to confirm."
    fi
}

# Content copied verbatim from the live /opt/lancache-ci-hooks/pre-job-
# cleanup.sh and post-job-cleanup.sh on lancache-240 (2026-08-21) -- these
# hooks are host-local by design, same as they already are on every
# existing runner host (not repo-tracked, unlike lancache-ci-cleanup.sh).
install_ci_hooks() {
    sudo mkdir -p "$RUNNER_HOOKS_DIR"
    sudo tee "$RUNNER_HOOKS_DIR/pre-job-cleanup.sh" >/dev/null <<'HOOKEOF'
#!/bin/bash
# lancache-ng self-hosted runner pre-job hook (ACTIONS_RUNNER_HOOK_JOB_STARTED)
#
# What: resets $GITHUB_WORKSPACE ownership to this runner's own user before
#   checkout runs, mirroring post-job-cleanup.sh's own reset logic.
# Why: post-job-cleanup.sh only resets ownership as best-effort at the END
#   of the PREVIOUS job -- if that job was killed/crashed before its own
#   hook ran, foreign-UID files (e.g. a container test writing as a non-
#   host UID) can still block the NEXT job's `actions/checkout` cleanup
#   step with EACCES. Running the same reset again at job START makes this
#   independent of whether the previous job's own cleanup actually ran.
#   Confirmed real incident: PR #1532, 2026-08-15, actions-runner-1 on
#   lancache-241 -- .setup-cli-simulation-tmp left a file `checkout`
#   could not unlink even though the post-job hook had reported success.
set -euo pipefail

if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -d "$GITHUB_WORKSPACE" ]; then
    if sudo -n chown -R "$(id -u):$(id -g)" "$GITHUB_WORKSPACE" 2>/dev/null; then
        echo "[pre-job-hook] reset ownership of $GITHUB_WORKSPACE to $(id -un):$(id -gn)"
    else
        echo "[pre-job-hook] WARNING: could not reset ownership of $GITHUB_WORKSPACE (sudo unavailable or failed) -- checkout may hit EACCES if the workspace carries foreign-UID files"
    fi
fi
HOOKEOF
    sudo tee "$RUNNER_HOOKS_DIR/post-job-cleanup.sh" >/dev/null <<'HOOKEOF'
#!/bin/bash
# lancache-ng self-hosted runner post-job cleanup hook (ACTIONS_RUNNER_HOOK_JOB_COMPLETED)
#
# full-setup-validate.yml's own steps run `docker compose down --volumes
# --remove-orphans` as part of a normal, successful job -- this hook exists
# only as a safety net for the crash/cancel case, where a job is killed
# before its own teardown step can run, leaving a Docker bridge network
# (and its subnet) allocated on the host indefinitely. That leftover state
# is exactly what caused repeated "validation subnet overlaps existing
# network state" collisions this project has hit.
#
# Only removes lancache-ng-validation_* networks that currently have ZERO
# attached containers. A network with active containers is left alone
# unconditionally -- this host runs multiple runner processes sharing one
# Docker daemon, so a network could belong to a job still in progress on a
# sibling runner process right now, and this hook must never touch that.
set -euo pipefail

for net in $(docker network ls --filter name=lancache-ng-validation --format '{{.Name}}'); do
    containers=$(docker network inspect "$net" --format '{{len .Containers}}' 2>/dev/null || echo "0")
    if [ "$containers" -eq 0 ]; then
        echo "[cleanup-hook] removing orphaned validation network: $net (0 attached containers)"
        docker network rm "$net" || echo "[cleanup-hook] WARNING: failed to remove $net, leaving in place"
    else
        echo "[cleanup-hook] leaving $net alone, $containers active container(s) attached"
    fi
done

# Reset ownership of THIS job's own workspace back to the runner's own user.
# A test that bind-mounts a directory into a container writing as a non-host
# UID (e.g. a Kea/PDNS process UID) can leave files this runner's own user
# cannot remove. The NEXT job scheduled onto this same runner process then
# fails at its own `actions/checkout` cleanup step with `EACCES: permission
# denied, rmdir ...` trying to clear the old workspace -- confirmed live
# (2026-07-13, PR #794's Kea config-snapshot simulation left files owned by
# UID 10001 under .setup-reset-kea-config-simulation-tmp/, blocking every
# subsequent job on this runner slot until manually chowned via SSH).
#
# Scoped to exactly $GITHUB_WORKSPACE (this job's own checkout directory),
# never anything broader -- multiple runner processes share this host, and a
# recursive chown outside this one job's own workspace could touch another
# job's in-progress files. Best-effort: sudo may not be configured on every
# host/user combination, and this hook must never fail the job it's cleaning
# up after over a cosmetic ownership reset.
if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -d "$GITHUB_WORKSPACE" ]; then
    if sudo -n chown -R "$(id -u):$(id -g)" "$GITHUB_WORKSPACE" 2>/dev/null; then
        echo "[cleanup-hook] reset ownership of $GITHUB_WORKSPACE to $(id -un):$(id -gn)"
    else
        echo "[cleanup-hook] WARNING: could not reset ownership of $GITHUB_WORKSPACE (sudo unavailable or failed) -- a future checkout on this slot may hit EACCES if a job left foreign-UID files behind"
    fi
fi
HOOKEOF
    sudo chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOOKS_DIR/pre-job-cleanup.sh" "$RUNNER_HOOKS_DIR/post-job-cleanup.sh"
    sudo chmod 0755 "$RUNNER_HOOKS_DIR/pre-job-cleanup.sh" "$RUNNER_HOOKS_DIR/post-job-cleanup.sh"
    echo "Installed $RUNNER_HOOKS_DIR/{pre,post}-job-cleanup.sh"
}

cmd_host_prep() {
    local sudoers_file="/etc/sudoers.d/${RUNNER_USER}-nopasswd"
    if sudo -n test -f "$sudoers_file" 2>/dev/null; then
        echo "$sudoers_file already present, leaving as-is."
    else
        echo "${RUNNER_USER} ALL=(ALL) NOPASSWD:ALL" | sudo tee "$sudoers_file" >/dev/null
        sudo chmod 0440 "$sudoers_file"
        sudo visudo -cf "$sudoers_file" || { echo "ERROR: visudo rejected $sudoers_file -- removing it." >&2; sudo rm -f "$sudoers_file"; return 1; }
        echo "Installed $sudoers_file"
    fi

    if id -nG "$RUNNER_USER" 2>/dev/null | grep -qw docker; then
        echo "$RUNNER_USER already in docker group, leaving as-is."
    else
        sudo usermod -aG docker "$RUNNER_USER"
        echo "Added $RUNNER_USER to docker group (takes effect on next login/SSH session)."
    fi

    install_ci_hooks

    if [[ -f "$SCRIPT_DIR/lancache-ci-cleanup.sh" ]]; then
        sudo install -m 0755 "$SCRIPT_DIR/lancache-ci-cleanup.sh" /usr/local/sbin/lancache-ci-cleanup.sh
        sudo install -m 0644 "$SCRIPT_DIR/lancache-ci-cleanup.service" /etc/systemd/system/lancache-ci-cleanup.service
        sudo install -m 0644 "$SCRIPT_DIR/lancache-ci-cleanup.timer" /etc/systemd/system/lancache-ci-cleanup.timer
        sudo systemctl daemon-reload
        sudo systemctl enable --now lancache-ci-cleanup.timer
        echo "Installed and enabled lancache-ci-cleanup.timer (see README.md in this directory)."
    else
        echo "WARNING: lancache-ci-cleanup.sh/.service/.timer not found next to this script ($SCRIPT_DIR) -- skipping. Copy the whole tools/runner-host/ directory to the host, not just this one file." >&2
    fi

    echo
    echo "host-prep complete. This does NOT touch /etc/docker/daemon.json (storage"
    echo "driver and other pre-existing host tuning are left exactly as they are);"
    echo "add a 'proxies' block manually per README.md if this host needs the LAN"
    echo "proxy other hosts use, and it does NOT run config.sh, install a runner"
    echo "systemd unit, or start any runner service."
}

cmd_runner_fetch() {
    local instance_dir="${1:?Usage: runner-fetch <instance-dir> [version]}"
    local version="${2:-2.336.0}"
    local tarball="actions-runner-linux-x64-${version}.tar.gz"
    local url="https://github.com/actions/runner/releases/download/v${version}/${tarball}"
    local tmp_tarball
    tmp_tarball="$(mktemp -t "${tarball}.XXXXXX")"

    echo "Fetching expected checksum for v${version} from the GitHub Releases API..."
    local expected_digest
    expected_digest="$(curl -fsSL "https://api.github.com/repos/actions/runner/releases/tags/v${version}" \
        | jq -r --arg name "$tarball" '.assets[] | select(.name == $name) | .digest' 2>/dev/null || true)"
    expected_digest="${expected_digest#sha256:}"
    if [[ -z "$expected_digest" ]]; then
        echo "ERROR: could not fetch an expected sha256 digest for $tarball from the GitHub API -- refusing to install unverified. Check the version string or network access." >&2
        rm -f "$tmp_tarball"
        return 1
    fi

    echo "Downloading $url ..."
    curl -fsSL -o "$tmp_tarball" "$url"
    local actual_digest
    actual_digest="$(sha256sum "$tmp_tarball" | awk '{print $1}')"
    if [[ "$actual_digest" != "$expected_digest" ]]; then
        echo "ERROR: checksum mismatch for $tarball -- expected $expected_digest, got $actual_digest. Refusing to extract." >&2
        rm -f "$tmp_tarball"
        return 1
    fi
    echo "Checksum verified: $actual_digest"

    sudo mkdir -p "$instance_dir"
    sudo tar xzf "$tmp_tarball" -C "$instance_dir"
    sudo chown -R "$RUNNER_USER:$RUNNER_USER" "$instance_dir"
    rm -f "$tmp_tarball"

    # Hook wiring -- must exist before the runner service is ever started,
    # or the pre/post-job-cleanup hooks are silently absent on the very
    # first job this instance picks up.
    cat <<ENVEOF | sudo tee "$instance_dir/.env" >/dev/null
LANG=C
ACTIONS_RUNNER_HOOK_JOB_STARTED=${RUNNER_HOOKS_DIR}/pre-job-cleanup.sh
ACTIONS_RUNNER_HOOK_JOB_COMPLETED=${RUNNER_HOOKS_DIR}/post-job-cleanup.sh
ENVEOF
    sudo chown "$RUNNER_USER:$RUNNER_USER" "$instance_dir/.env"

    echo
    echo "Extracted actions-runner v${version} into $instance_dir and wrote its .env"
    echo "hook wiring. NOT registered yet -- run config.sh there by hand with a fresh"
    echo "registration token (never pass it as a literal argv string over ssh; pipe"
    echo "it over stdin instead), then 'sudo ./svc.sh install' and hold off on"
    echo "'sudo ./svc.sh start' until the go-ahead to accept real jobs is confirmed."
}

print_usage() {
    cat <<'EOF'
Usage: bash lancache-ci-runner-clone-init.sh <mode> [args...]

Modes:
  check                        (default) Read-only report. Writes nothing.
  clean                        Removes clone artifacts 'check' flagged as
                                foreign. Requires CONFIRM_CLEAN=yes.
  host-prep                    Idempotent sudoers/docker-group/ci-hooks/
                                cleanup-timer setup. Never touches
                                daemon.json or runner registration.
  runner-fetch <dir> [version] Download+verify+extract a runner release
                                directly into <dir> (default version 2.336.0)
                                and write its .env hook wiring. Does not
                                register or start anything.

Env overrides: RUNNER_OPT_ROOT (default /opt), RUNNER_HOOKS_DIR
(default /opt/lancache-ci-hooks), RUNNER_USER (default codex),
STRAY_ARCHIVE_MIN_BYTES (default 1 GiB).
EOF
}

main() {
    local mode="${1:-check}"
    shift || true
    case "$mode" in
        check) cmd_check ;;
        clean) cmd_clean ;;
        host-prep) cmd_host_prep ;;
        runner-fetch) cmd_runner_fetch "$@" ;;
        -h|--help) print_usage ;;
        *)
            echo "ERROR: unknown mode '$mode'" >&2
            print_usage >&2
            return 1
            ;;
    esac
}

# Guard direct-execution-only behavior so a bats fixture can `source` this
# file (to call own_host_token/is_foreign_runner_dir directly against a
# fixture) without also triggering a real run of main() against this
# process's actual argv/environment.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
