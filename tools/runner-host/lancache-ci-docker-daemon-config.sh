#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: merges build-cache GC/log limits into daemon.json
# Why: AG-CI-016 requires bounded build caches on runners
# From: Issue #1255 | PR #1349

# What: aborts on errors, unset vars and pipe failures
# Why: a failed jq or validate step must not pass silently
set -euo pipefail

DAEMON_JSON="${DAEMON_JSON:-/etc/docker/daemon.json}"
# What: env-overridable target file, GC and log limits
# Why: hosts deviate by env var without forking the script
BUILDER_GC_RESERVED_SPACE="${BUILDER_GC_RESERVED_SPACE:-20GB}"
LOG_MAX_SIZE="${LOG_MAX_SIZE:-10m}"
LOG_MAX_FILE="${LOG_MAX_FILE:-3}"

# What: prints the additions as JSON on stdout
# Why: bats fixture calls this function after sourcing
daemon_config_additions_json() {
    jq -n \
        --arg reserved_space "$BUILDER_GC_RESERVED_SPACE" \
        --arg max_size "$LOG_MAX_SIZE" \
        --arg max_file "$LOG_MAX_FILE" \
        '{
            "builder": { "gc": { "enabled": true, "defaultReservedSpace": $reserved_space } },
            "log-driver": "json-file",
            "log-opts": { "max-size": $max_size, "max-file": $max_file }
        }'
}

# What: deep-merges additions into daemon.json, or into {}
# Why: jq * keeps unrelated keys; invalid JSON fails closed
merge_daemon_config() {
    local existing_file="$1"
    local existing_json="{}"
    if [[ -f "$existing_file" ]]; then
        existing_json="$(cat "$existing_file")"
        # What: rejects unparseable existing daemon.json
        # Why: invalid config only fails at the next restart
        if ! jq empty <<<"$existing_json" 2>/dev/null; then
            echo "ERROR: existing $existing_file is not valid JSON -- refusing to merge. Fix or remove it manually first." >&2
            return 1
        fi
    fi
    jq -s '.[0] * .[1]' <(echo "$existing_json") <(daemon_config_additions_json)
}

print_usage() {
    cat <<'EOF'
Usage: bash lancache-ci-docker-daemon-config.sh <mode>

Modes:
  check    (default) Read-only. Prints the current daemon.json (or "(none)"),
           the computed merged result, and a diff. Writes nothing.
  stage    Writes the merged config to <DAEMON_JSON>.staged next to the live
           file, for manual review, without touching the live file.
  apply    Backs up the live daemon.json (timestamped, next to the original)
           and installs the merged config as the new live daemon.json.
           Does NOT restart dockerd -- the new settings do not take effect
           until a restart happens (see "restart" below).
  restart  Restarts dockerd (systemctl restart docker) and verifies the new
           builder/log settings actually took effect via `docker info`. This
           is the disruptive step: every container currently running on this
           host is stopped. Requires CONFIRM_DOCKERD_RESTART=yes to be set
           in the environment, so it can never run from a copy-pasted
           one-liner without a deliberate extra step. Run this only during a
           pre-agreed quiet window, one host at a time (see README.md).

Env overrides: DAEMON_JSON (default /etc/docker/daemon.json),
BUILDER_GC_RESERVED_SPACE (default 20GB), LOG_MAX_SIZE (default 10m),
LOG_MAX_FILE (default 3).
EOF
}

# What: runs dockerd --validate; warns and skips if absent
# Why: a clean result does not prove key names are valid
# From: Issue #1255 | PR #1349
validate_with_dockerd() {
    local config_file="$1"
    if ! command -v dockerd >/dev/null 2>&1; then
        echo "WARNING: dockerd binary not found on PATH -- skipping the dockerd --validate preflight." >&2
        return 0
    fi
    if ! dockerd --validate --config-file "$config_file" >/dev/null 2>&1; then
        echo "ERROR: dockerd --validate rejected the computed config -- refusing to proceed." >&2
        dockerd --validate --config-file "$config_file" >&2 || true
        return 1
    fi
    return 0
}

cmd_check() {
    echo "--- Current $DAEMON_JSON ---"
    if [[ -f "$DAEMON_JSON" ]]; then
        cat "$DAEMON_JSON"
    else
        echo "(none -- file does not exist; docker is running on pure defaults)"
    fi
    echo
    echo "--- Computed merged result ---"
    merge_daemon_config "$DAEMON_JSON" | tee /dev/stderr | jq '.' >/dev/null
    echo
    echo "--- Diff (current vs. merged) ---"
    # What: diffs current config against merged result
    # Why: exit 1 means differences; set -e must not abort
    # From: Issue #1255 | PR #1349
    diff <(if [[ -f "$DAEMON_JSON" ]]; then jq -S '.' "$DAEMON_JSON"; else echo '{}'; fi) \
         <(merge_daemon_config "$DAEMON_JSON" | jq -S '.') || true
    echo
    echo "--- dockerd --validate preflight ---"
    local tmp_check
    tmp_check="$(mktemp)"
    merge_daemon_config "$DAEMON_JSON" | jq '.' > "$tmp_check"
    if validate_with_dockerd "$tmp_check"; then
        echo "dockerd --validate: configuration OK"
    fi
    rm -f "$tmp_check"
    echo "No files were written (check mode). Re-run with 'stage' or 'apply' to write."
}

cmd_stage() {
    local staged="${DAEMON_JSON}.staged"
    merge_daemon_config "$DAEMON_JSON" | jq '.' > "$staged"
    echo "Staged merged config at: $staged"
    echo "Review it, then run 'apply' when ready. Nothing else was changed."
}

cmd_apply() {
    local merged
    merged="$(merge_daemon_config "$DAEMON_JSON")"
    # What: returns 1 unless merged JSON parses
    # Why: fail closed; daemon.json is not touched on error
    if ! jq empty <<<"$merged" 2>/dev/null; then
        echo "ERROR: computed merged config is not valid JSON -- aborting, nothing written." >&2
        return 1
    fi
    # What: runs dockerd --validate on the merged config
    # Why: last gate before the live file; key typos pass
    # From: Issue #1255 | PR #1349
    local tmp_validate
    tmp_validate="$(mktemp)"
    jq '.' <<<"$merged" > "$tmp_validate"
    if ! validate_with_dockerd "$tmp_validate"; then
        rm -f "$tmp_validate"
        return 1
    fi
    rm -f "$tmp_validate"
    if [[ -f "$DAEMON_JSON" ]]; then
        local backup
        backup="${DAEMON_JSON}.bak.$(date +%Y%m%dT%H%M%S)"
        cp "$DAEMON_JSON" "$backup"
        echo "Backed up existing config to: $backup"
    fi
    # What: writes a same-dir temp file, then mv into place
    # Why: same-dir rename is atomic; no half-written file
    local tmp
    tmp="$(mktemp "${DAEMON_JSON}.tmp.XXXXXX")"
    jq '.' <<<"$merged" > "$tmp"
    mv "$tmp" "$DAEMON_JSON"
    echo "Applied merged config to: $DAEMON_JSON"
    echo
    echo "dockerd has NOT been restarted -- builder/log-driver changes only take"
    echo "effect after a full restart (not SIGHUP-reloadable). Run this script's"
    echo "'restart' mode during an agreed quiet window when ready."
}

cmd_restart() {
    if [[ "${CONFIRM_DOCKERD_RESTART:-}" != "yes" ]]; then
        echo "ERROR: refusing to restart dockerd without CONFIRM_DOCKERD_RESTART=yes." >&2
        echo "This stops every container currently running on this host, including" >&2
        echo "any in-flight CI job -- it must be a deliberate, quiet-window action," >&2
        echo "never something this script does implicitly. See README.md." >&2
        return 1
    fi
    echo "Restarting docker.service ..."
    systemctl restart docker
    # What: polls docker info, fails after 30 tries of 1s
    # Why: systemctl returns before dockerd responds
    local attempt=0
    until docker info >/dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [[ "$attempt" -ge 30 ]]; then
            echo "ERROR: dockerd did not become responsive within 30s of restart." >&2
            return 1
        fi
        sleep 1
    done
    echo "dockerd is responsive. Verifying the new settings actually took effect ..."
    # What: checks LoggingDriver; prints builder from file
    # Why: this Docker version has no builder GC field
    # From: Issue #1255 | PR #1349
    local info_json
    info_json="$(docker info --format '{{json .}}')"
    local logging_driver
    logging_driver="$(jq -r '.LoggingDriver // empty' <<<"$info_json" 2>/dev/null || true)"
    echo "  LoggingDriver (from docker info): ${logging_driver:-<not reported>}"
    if [[ "$logging_driver" != "json-file" ]]; then
        echo "WARNING: LoggingDriver does not report json-file -- verify manually before" >&2
        echo "declaring this host's rollout complete." >&2
    fi
    echo "  Live $DAEMON_JSON builder.gc section (docker info does not expose this"
    echo "  in this Docker version, so this is read back from the config file"
    echo "  dockerd just loaded, not queried from a running-daemon API):"
    jq '.builder // "(no builder key present)"' "$DAEMON_JSON" 2>/dev/null || echo "  <could not read $DAEMON_JSON>"
    echo
    echo "Restart complete. Confirm the host resumes picking up CI jobs normally,"
    echo "then confirm the build-cache bound is actually holding over the following"
    echo "days via lancache-ci-cleanup.sh's own before/after disk-usage log, before"
    echo "moving on to the next host (one host at a time, per README.md)."
}

main() {
    local mode="${1:-check}"
    case "$mode" in
        check) cmd_check ;;
        stage) cmd_stage ;;
        apply) cmd_apply ;;
        restart) cmd_restart ;;
        -h|--help) print_usage ;;
        *)
            echo "ERROR: unknown mode '$mode'" >&2
            print_usage >&2
            return 1
            ;;
    esac
}

# What: runs main only when executed, not when sourced
# Why: bats tests source the file to call functions
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
