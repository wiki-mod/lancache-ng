#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads services/proxy/entrypoint.sh's REAL
# _render_stream_backend_map() via awk extraction, mirroring the technique
# already used by the other tests/bats/helpers/proxy-*.sh files for disjoint
# ranges of the same file. This is the $stream_backend map generator whose
# lazy-mode branch regressed issue #88 (empty SNI forwarding to the invalid
# ":443" target) -- bug-hunt #849, finding N4.

load_proxy_stream_backend_map_helpers() {
    local repo_root="$1" helper_file="$2"

    {
        awk '
            /^_render_stream_backend_map\(\) \{/ { in_fn = 1 }
            in_fn { print }
            in_fn && /^\}$/ { exit }
        ' "$repo_root/services/proxy/entrypoint.sh"
    } > "$helper_file"

    # shellcheck disable=SC1090
    source "$helper_file"

    # The real file assigns this immediately before defining the function
    # (see entrypoint.sh's own comment there); the awk range above starts at
    # the function definition itself, so the caller sets it explicitly.
    STREAM_EMPTY_SNI_BACKEND="127.0.0.1:9"
    declare -ag _UNIQUE_DOMAINS=()
    declare -Ag _DOMAIN_IS_ROOT=()
    declare -ag _EXTRA_WILDCARD_BASES=()
    declare -ag _EXTRA_EXACT_HOSTS=()
}
