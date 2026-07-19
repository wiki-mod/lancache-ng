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

    # shellcheck source=/dev/null
    source "$helper_file"
}
