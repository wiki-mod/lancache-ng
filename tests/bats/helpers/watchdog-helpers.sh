#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads services/watchdog/watchdog.sh's real config-default
# variables and stateful functions (check_and_maybe_restart, write_status,
# health_color, disk_info, resolve_cache_dir) without executing the script's
# top-level `while true; do ... done` monitoring loop.
#
# The captured range starts at the DOCKER_PROXY_URL default assignment (the
# first substantive line after `set -euo pipefail`) and ends right before the
# "Watchdog started." log line -- the first top-level executable statement
# after all function definitions. Everything in between is variable defaults
# and function definitions only, so sourcing it has no side effects beyond
# defining functions/variables (resolve_cache_dir() is invoked once at source
# time via `CACHE_DIR="$(resolve_cache_dir)"`, exactly as the real script
# does, so callers can pre-export CACHE_DIR to control its result).
#
# get_health() and restart_container() ARE captured verbatim (they are the
# real functions check_and_maybe_restart() calls), but they reach out to
# DOCKER_PROXY_URL via curl -- callers must redefine both after sourcing to
# drive deterministic health sequences instead of hitting a real Docker
# socket proxy.

load_watchdog_functions() {
    local repo_root="$1" helper_file="$2"

    {
        awk '
            /^DOCKER_PROXY_URL=/ { capture = 1 }
            /^log "Watchdog started\./ { capture = 0 }
            capture { print }
        ' "$repo_root/services/watchdog/watchdog.sh"
    } > "$helper_file"

    # #849 bug-hunt finding watchdog.md#12: the awk extraction above depends
    # on two literal-text anchors inside watchdog.sh (the DOCKER_PROXY_URL=
    # default assignment that starts capture, and the "Watchdog started." log
    # line that ends it). If either anchor's exact text or position in
    # watchdog.sh ever changes without a matching update here, awk silently
    # matches nothing (or a truncated range), `$helper_file` ends up empty or
    # missing the real function bodies, and a plain `source` on it succeeds
    # trivially with no error -- the only symptom would surface much later, as
    # a confusing "command not found" deep inside an unrelated @test body that
    # calls one of the now-undefined functions, not as a clear "the test
    # harness failed to extract functions" message right here at setup()
    # time. Fail loudly here instead of letting that happen silently.
    if [ ! -s "$helper_file" ]; then
        echo "load_watchdog_functions: extracted '$helper_file' is empty -- the awk anchors (DOCKER_PROXY_URL=/'Watchdog started.') no longer match services/watchdog/watchdog.sh; update tests/bats/helpers/watchdog-helpers.sh's anchors" >&2
        return 1
    fi

    # shellcheck source=/dev/null
    source "$helper_file"

    # disk_info() is one of the oldest, most stable functions this helper is
    # meant to expose (present since before this helper existed) -- if
    # sourcing the extracted file didn't define it, the captured range is
    # missing or truncated even though the file itself is non-empty (e.g. the
    # end anchor matched too early), so the empty-file check above alone is
    # not sufficient to catch every drift shape.
    if ! declare -F disk_info >/dev/null 2>&1; then
        echo "load_watchdog_functions: sourcing '$helper_file' did not define disk_info() -- the extracted range from services/watchdog/watchdog.sh is missing or truncated; update tests/bats/helpers/watchdog-helpers.sh's awk anchors" >&2
        return 1
    fi
}
