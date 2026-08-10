#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Bats helper that loads services/watchdog/retention.sh's real config-default
# variables, validate_retention_dir()/is_truthy()/resolve_cache_dir() helpers,
# and the three stateful retention functions (maybe_purge, maybe_prune_syslog,
# maybe_rotate_fluent_bit_selflog) without executing the script's top-level
# `while true; do ... done` loop.
#
# The captured range starts at the first function definition (`log()`, the
# first substantive line after `set -euo pipefail`) and ends right before the
# "Retention daemon started." log line -- the first top-level executable
# statement after all function definitions and variable defaults. Everything
# in between is variable defaults and function definitions only, so sourcing
# it has no side effects beyond defining functions/variables (resolve_cache_dir()
# is invoked once at source time via `CACHE_DIR="$(resolve_cache_dir)"`, exactly
# as the real script does, so callers can pre-export CACHE_DIR to control its
# result -- mirrors watchdog-helpers.sh's identical pattern for watchdog.sh).
#
# Every test that calls maybe_purge()/maybe_prune_syslog()/
# maybe_rotate_fluent_bit_selflog() against a BATS_TEST_TMPDIR fixture (never
# a real /var path) must also export CACHE_DIR_ALLOWED_PREFIX/
# SYSLOG_LOG_ROOT_ALLOWED_PREFIX/FLUENT_BIT_SELFLOG_DIR_ALLOWED_PREFIX to a
# prefix that actually contains that fixture (e.g. "$BATS_TEST_TMPDIR")
# *before* calling load_retention_functions() -- validate_retention_dir()
# fails closed otherwise, exactly as it should for a real, unexpected path.

load_retention_functions() {
    local repo_root="$1" helper_file="$2"

    {
        awk '
            /^log\(\) \{/ { capture = 1 }
            /^log "Retention daemon started\./ { capture = 0 }
            capture { print }
        ' "$repo_root/services/watchdog/retention.sh"
    } > "$helper_file"

    # shellcheck source=/dev/null
    source "$helper_file"
}
