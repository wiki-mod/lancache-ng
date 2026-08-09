#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads services/proxy/entrypoint.sh's REAL _render_ssl_map()
# (and the _bounded_cert_name() it calls) via awk extraction, mirroring the
# technique already used in tests/bats/helpers/proxy-cert-helpers.sh and
# tests/bats/helpers/proxy-cert-dir-permissions-helpers.sh for other disjoint
# ranges of the same file. _render_ssl_map generates the $cdn_host_allowed
# (PROXY_SECURITY_MODE strict/lazy) and $lancache_client_allowed
# (PROXY_ALLOWED_CLIENT_CIDRS) maps. The wrapper below deliberately restores
# the entrypoint's shell-option contract because the function's failure
# behavior is part of its production behavior, not merely a Bats detail.

load_proxy_ssl_map_generation_helpers() {
    local repo_root="$1" helper_file="$2"

    {
        awk '
            /^_bounded_cert_name\(\) \{/ { in_bcn = 1 }
            in_bcn { print }
            in_bcn && /^\}$/ { in_bcn = 0; next }
            /^_render_ssl_map\(\) \{/ { in_map = 1 }
            in_map { print }
            in_map && /^\}$/ { exit }
        ' "$repo_root/services/proxy/entrypoint.sh"
    } > "$helper_file"

    # shellcheck disable=SC1090
    source "$helper_file"

    # _render_ssl_map reads these globals unconditionally (empty arrays are
    # fine for tests that only care about the $cdn_host_allowed/
    # $lancache_client_allowed maps further down the generated output, not
    # the $ssl_cert_name map's own per-domain content).
    declare -ag _UNIQUE_DOMAINS=()
    declare -Ag _DOMAIN_IS_ROOT=()
    declare -ag _EXTRA_WILDCARD_BASES=()
    declare -ag _EXTRA_EXACT_HOSTS=()

    # Both values are initialized because production enables nounset before
    # calling the function. Individual tests override only the policy axis
    # relevant to their assertion, just as operators may configure either
    # axis independently.
    PROXY_SECURITY_MODE="lazy"
    PROXY_ALLOWED_CLIENT_CIDRS=""
}

run_render_ssl_map_with_production_options() {
    set -euo pipefail
    _render_ssl_map
}
