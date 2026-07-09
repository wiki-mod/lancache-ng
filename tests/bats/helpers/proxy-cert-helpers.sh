#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads proxy entrypoint's certificate generation functions
# without executing the full entrypoint.

load_proxy_cert_helpers() {
    local repo_root="$1" helper_file="$2"

    {
        # Extract domain validation and certificate signing functions from
        # entrypoint.sh as two separate ranges, not one contiguous span.
        # _is_valid_domain_label/_normalize_domain/_is_valid_domain are
        # adjacent function definitions, but the real file's next lines after
        # them are _collect_domain_rows's definition immediately followed by
        # a bare top-level call to it, then resolver/PROXY_SECURITY_MODE
        # validation — all of that is entrypoint.sh's own startup script
        # body, not function definitions. A single contiguous capture from
        # _is_valid_domain_label through _sign_cert would pull that
        # executable glue code into this helper file too, and sourcing it
        # would run `_collect_domain_rows` immediately against an unset
        # $DOMAINS_FILE (empty-path redirect -> "No such file or directory")
        # before ever reaching _sign_cert's definition.
        #
        # The awk program below runs a single pass over entrypoint.sh and
        # tracks two independent on/off flags to pull out those two disjoint
        # ranges in one go, printing a line whenever either flag is on:
        #   - `capture` toggles on at the `_is_valid_domain_label()` line and
        #     back off at the `_collect_domain_rows()` line. Because awk
        #     evaluates every pattern against a line before moving to the
        #     next one, the `_collect_domain_rows()` line itself flips
        #     `capture` to 0 *before* the `capture { print }` rule below it
        #     runs for that same line — so `_collect_domain_rows()`'s own
        #     definition is excluded, and only _is_valid_domain_label,
        #     _normalize_domain, and _is_valid_domain get copied.
        #   - `in_sign_cert` is a separate flag for a separate region further
        #     down the file: it turns on at the exact (4-space-indented)
        #     `_sign_cert() {` line and stays on until the matching 4-space
        #     `}` that closes it, at which point that closing line is printed
        #     too (print rules for a line run before the `exit` check) and
        #     `exit` stops awk from reading the rest of the file.
        awk '
            /^_is_valid_domain_label\(\)/ { capture = 1 }
            /^_collect_domain_rows\(\)/ { capture = 0 }
            capture { print }
            /^    _sign_cert\(\) {/ { in_sign_cert = 1 }
            in_sign_cert { print }
            in_sign_cert && /^    \}$/ { exit }
        ' "$repo_root/services/proxy/entrypoint.sh"
    } > "$helper_file"

    # shellcheck source=/dev/null
    source "$helper_file"
}
