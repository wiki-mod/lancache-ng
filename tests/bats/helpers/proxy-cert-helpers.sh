#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Bats helper that loads proxy entrypoint's certificate generation functions
# without executing the full entrypoint.

load_proxy_cert_helpers() {
    local repo_root="$1" helper_file="$2"

    {
        # What: domain-validation fns now come from the shared lib.
        # Why: entrypoint.sh sources it, no longer defines them.
        # From: Issue #1683
        cat "$repo_root/scripts/lib/domain-validation.sh"

        # Certificate-signing functions still live in entrypoint.sh itself
        # (image-local logic, not part of the domain-validation library).
        # `_sign_cert`/`_default_cert_needs_regen` are extracted as two
        # separate 4-space-indented ranges; `exit` after the second closing
        # `}` stops awk before entrypoint.sh's own startup script body,
        # which would otherwise run against paths this helper lacks.
        awk '
            /^    _sign_cert\(\) {/ { in_sign_cert = 1 }
            in_sign_cert { print }
            in_sign_cert && /^    \}$/ { in_sign_cert = 0 }
            /^    _default_cert_needs_regen\(\) {/ { in_needs_regen = 1 }
            in_needs_regen { print }
            in_needs_regen && /^    \}$/ { exit }
        ' "$repo_root/services/proxy/entrypoint.sh"
    } > "$helper_file"

    # shellcheck source=/dev/null
    source "$helper_file"
}
