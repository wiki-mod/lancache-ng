#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# CI runner host maintenance: safely apply the bounded-build-cache + log-
# rotation additions to a self-hosted runner host's /etc/docker/daemon.json.
#
# Background (issue #1255, section 7 / PR #1251's own "Scope Boundaries"):
# the 2026-07-25 runner-leak incident's root cause included an *unbounded*
# BuildKit build cache -- one runner host had accumulated ~40 GB of
# unreclaimed build cache before that incident's manual cleanup. AG-CI-016
# ("CI resource lifecycle: bounded, self-reaping, versioned, and re-measured")
# requires build caches to be size-bounded at the daemon level, never left
# unbounded between scheduled `lancache-ci-cleanup.sh` runs (that script
# prunes reclaimable cache on a timer; this script bounds how large the cache
# is allowed to grow *between* those runs in the first place). Real on-host
# investigation (issue #1255, 2026-07-25 comment) confirmed against the
# authoritative dockerd documentation that neither `builder` nor
# `log-driver`/`log-opts` is in dockerd's SIGHUP-reloadable config subset
# (only `debug`, `labels`, `live-restore`, `max-concurrent-*`, `runtimes`,
# `authorization-plugin`, registries, `shutdown-timeout`, and `features`
# are) -- applying either one REQUIRES A FULL `dockerd` RESTART, which drops
# every container currently running on that host, including in-flight CI
# jobs. That restart is why this script never performs it implicitly: per
# maintainer decision this is a go-gated, one-host-at-a-time, quiet-window
# action, never an automatic side effect of running this script.
#
# What this script does NOT assume: three of this project's four runner
# hosts (confirmed via direct SSH inspection, 2026-07-31) already carry a
# real /etc/docker/daemon.json with `max-concurrent-downloads`/`-uploads`
# and `storage-driver` set; one host (.243) has no daemon.json file at all
# (pure Docker defaults). This script must merge its additions into
# whatever is already there -- including a possible future `builder` block
# with unrelated sub-keys -- never blindly overwrite the live file, which is
# why the merge below uses jq's recursive `*` operator (deep-merges nested
# objects such as `builder.gc` instead of replacing the whole `builder` key).
#
# Key name (AG-VAL-023 -- checked upstream before writing an assumption into
# this rollout as fact): earlier drafts of this rollout (PR #1251,
# tools/runner-host/README.md) used `builder.gc.defaultKeepStorage`, which
# reads today's moby/moby documentation as a legacy name -- current docs and
# the `BuilderGCConfig` Go struct (daemon/config/builder.go) show
# `defaultReservedSpace`/`defaultMaxUsedSpace`/`defaultMinFreeSpace`
# instead, with no field literally named `defaultKeepStorage` in the current
# struct fields, which raised a real risk this rollout would be a silent
# no-op on the pinned Docker 29.6.x runner-host fleet: dockerd's daemon.json
# parser drops *any* unrecognized key without error (confirmed empirically,
# 2026-07-31: `dockerd --validate` against a config containing a deliberately
# nonsense key name also reports "configuration OK" -- validate cannot tell
# a real key from a typo). Verified directly against moby's actual
# `BuilderGCConfig.UnmarshalJSON` source AND against the literal compiled
# `/usr/bin/dockerd` binary's own embedded struct-reflection strings on a
# real runner host (`strings $(which dockerd) | grep -i keepstorage`, no
# restart needed): `defaultKeepStorage` IS still read by an explicit,
# deliberate backward-compatibility shim ("Deprecated option is now
# equivalent to DefaultReservedSpace") that assigns it into
# `DefaultReservedSpace` whenever the latter is empty -- so the original
# key was never actually broken. This script nonetheless emits the current,
# non-deprecated `defaultReservedSpace` key going forward rather than
# perpetuating a documented-deprecated spelling in new tooling.
#
# Modes (see --help): the default is a safe, read-only `check` that only
# prints the computed diff. Writing the live file (`apply`) never restarts
# dockerd by itself; actually restarting dockerd (`restart`) is a separate,
# explicitly-confirmed step so nobody can trigger the disruptive half of
# this script by muscle memory or a copy-pasted one-liner.
#
# Usage (see README.md in this directory for the full per-host rollout
# procedure): invoke with an explicit interpreter (`bash
# lancache-ci-docker-daemon-config.sh ...`), not `./lancache-ci-docker-
# daemon-config.sh` -- this repo's executable bit is unverifiable from a
# Windows authoring host with `core.filemode=false` (AG-VAL-024), so this
# script, like `lancache-ci-cleanup.sh`, must not depend on it being set.
set -euo pipefail

DAEMON_JSON="${DAEMON_JSON:-/etc/docker/daemon.json}"
# Tunables, overridable via env the same way lancache-ci-cleanup.sh's reap
# thresholds are -- lets a specific host deviate from the project default
# without forking the script.
BUILDER_GC_RESERVED_SPACE="${BUILDER_GC_RESERVED_SPACE:-20GB}"
LOG_MAX_SIZE="${LOG_MAX_SIZE:-10m}"
LOG_MAX_FILE="${LOG_MAX_FILE:-3}"

# Emits the additions this rollout applies, as JSON on stdout. Kept as its
# own function (rather than inlined at the call site) so a bats fixture can
# source this file and call it directly to assert the exact additions
# without re-deriving them.
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

# Deep-merges the additions into an existing daemon.json's content (or `{}`
# if the file does not exist -- confirmed a real case on host .243, not a
# hypothetical). jq's `*` operator recursively merges nested objects, so an
# existing `builder` key with unrelated sub-keys (or a future `ipv6`/
# `authorization-plugin`/etc. key this rollout doesn't touch) survives
# untouched -- only the specific leaves this script owns are added/updated.
# Fails closed (via `set -euo pipefail` + jq's own non-zero exit) if the
# existing file is not valid JSON, rather than silently discarding it.
merge_daemon_config() {
    local existing_file="$1"
    local existing_json="{}"
    if [[ -f "$existing_file" ]]; then
        existing_json="$(cat "$existing_file")"
        # Fail closed on a pre-existing daemon.json this script cannot parse
        # -- merging blindly on top of unparseable content could silently
        # produce an invalid config that fails dockerd startup after a
        # restart the operator has no way to preview beforehand.
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

# Runs dockerd's own `--validate` mode against a candidate config -- a
# read-only, no-restart-required static check dockerd itself provides
# (confirmed empirically on a real runner host, 2026-07-31, both a good and
# a deliberately bogus config exit identically fast with no daemon restart
# or root privilege involved). IMPORTANT caveat, also confirmed empirically:
# `--validate` only proves the file is syntactically valid JSON that dockerd
# can parse -- it does NOT catch an unrecognized/misspelled key inside a
# known object (a config with a deliberately nonsense builder.gc sub-key
# also reports "configuration OK"), so a clean validate result here is
# necessary but not sufficient proof the specific settings this script cares
# about will actually take effect. That is exactly why this script's own
# header documents having verified `defaultReservedSpace`/`defaultKeepStorage`
# against moby's real source and the actual compiled dockerd binary, rather
# than relying on `--validate` for that specific question.
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
    # `diff` exits 1 when it finds differences (the expected, normal case
    # here -- that's the whole point of this preview) and only exits >1 on a
    # real usage/read error; `|| true` absorbs the expected exit-1 so
    # `set -e` doesn't abort this read-only preview over an outcome that
    # isn't actually a failure.
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
    # Validate before touching anything live -- fail closed rather than
    # leaving the host with a half-written or invalid daemon.json.
    if ! jq empty <<<"$merged" 2>/dev/null; then
        echo "ERROR: computed merged config is not valid JSON -- aborting, nothing written." >&2
        return 1
    fi
    # Second, stronger preflight: ask dockerd itself whether it accepts this
    # exact config, before it ever becomes the live file. This still cannot
    # catch a misspelled key (see validate_with_dockerd's own comment), but
    # it does catch a config dockerd rejects outright (e.g. a genuinely
    # malformed value type) -- worth doing here since it costs nothing and
    # this is the last checkpoint before the file that a later restart will
    # actually load gets written.
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
    # Write to a temp file in the same directory and rename atomically, so a
    # crash or interrupted write mid-copy never leaves dockerd's config file
    # half-written (AG-OP-010: validation/atomicity before a state-owning
    # write that a later restart depends on).
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
    # docker.socket/service can report "active" briefly before the daemon has
    # actually finished re-reading its own config; poll `docker info` instead
    # of assuming the restart is complete the instant systemctl returns.
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
    # IMPORTANT (confirmed empirically, 2026-07-31): `docker info`'s own JSON
    # output has NO `BuilderConfig`/builder-GC field at all in this Docker
    # version -- an earlier draft of this check read a
    # `.BuilderConfig.GC.DefaultKeepStorage` path that does not exist in the
    # real `docker info --format '{{json .}}'` schema and would always have
    # silently reported "<not reported>", giving false confidence that
    # something had been checked. `LoggingDriver` IS a real top-level field
    # (confirmed present in real `docker info` JSON output), so that part is
    # genuinely verifiable this way; the builder GC policy is not exposed by
    # `docker info` in this Docker version, so this step instead reports what
    # is actually in the live config file dockerd just (re)loaded from, plus
    # an explicit note that the GC bound itself can only be confirmed
    # indirectly, over time, via lancache-ci-cleanup.sh's own disk-usage
    # measurements no longer showing unbounded build-cache growth.
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

# Guard direct-execution-only behavior so a bats fixture can `source` this
# file (to call daemon_config_additions_json/merge_daemon_config directly
# against a fixture) without also triggering a real run of main() against
# this process's actual argv/environment.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
