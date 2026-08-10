#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Bats helper that loads services/dns/entrypoint.sh's real
# "_dns_generate_rpz_zone" and "_dns_ensure_zone_exists" functions without
# executing the full entrypoint (PDNS_API_KEY placeholder checks, daemon
# startup, etc.).
#
# Bug-hunt finding #8 (docs/bug-hunt/dns.md, re-verified 2026-08-06): this
# used to be a hand-extracted, independently-maintained copy of the RPZ
# generation loop with no guard against drifting from the real entrypoint
# logic. Rather than adding a separate sync-guard test to detect drift after
# the fact (the pattern used for the cross-*file* domain-validation/
# known-good-snapshot libraries, which genuinely must be duplicated because
# each service builds its own isolated Docker image), this dynamically
# extracts the real function bodies from services/dns/entrypoint.sh at test
# time and sources them directly -- the same technique already used by
# tests/bats/helpers/dns-known-good-snapshot-helpers.sh for this exact
# single-file scenario, which eliminates the drift risk entirely instead of
# merely detecting it.

load_dns_zone_helpers() {
    local repo_root="$1" helper_file="$2"

    awk '
        /^_dns_generate_rpz_zone\(\) \{/ { in_fn = 1 }
        /^_dns_ensure_zone_exists\(\) \{/ { in_fn = 1 }
        in_fn { print }
        in_fn && /^\}$/ { in_fn = 0 }
    ' "$repo_root/services/dns/entrypoint.sh" > "$helper_file"

    # shellcheck disable=SC1090
    source "$helper_file"
}

# generate_rpz_zone <domains_file> <output_file> <proxy_ip> [proxy_ipv6]
# Thin, stable name-compatible wrapper kept so existing callers
# (tests/bats/dns_zone_generation.bats) don't need to change: the real
# entrypoint function is now the only implementation, extracted and sourced
# by load_dns_zone_helpers() above.
generate_rpz_zone() {
    _dns_generate_rpz_zone "$@"
}
