#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for services/proxy/entrypoint.sh's
# _render_stream_client_acl() -- bug-hunt #849, finding N1: the stream-level
# externally-facing listeners (nginx.conf's static 8443 standard-mode
# passthrough server, and the dynamically-generated 443 SSL-mode dispatcher)
# had zero client-IP enforcement, regardless of PROXY_ALLOWED_CLIENT_CIDRS,
# because $lancache_client_allowed (the pre-existing geo-based approach) is
# an http-context-only variable that cannot cross into the stream {}
# context. Asserts against the real generated ngx_stream_access_module
# allow/deny directive text -- the same text nginx.conf's 8443 server block
# and entrypoint.sh's own 443 dispatcher server block both `include`.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/proxy-stream-client-acl-helpers.sh"

    # shellcheck source=tests/bats/helpers/proxy-stream-client-acl-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/proxy-stream-client-acl-helpers.sh"
    load_proxy_stream_client_acl_helpers "$repo_root" "$helper_file"
}

@test "empty PROXY_ALLOWED_CLIENT_CIDRS emits no allow/deny directives at all (implicit allow-all, matching the lazy default)" {
    PROXY_ALLOWED_CLIENT_CIDRS=""
    run _render_stream_client_acl
    [ "$status" -eq 0 ]
    [[ "$output" != *'allow '* ]]
    [[ "$output" != *'deny '* ]]
}

@test "a configured PROXY_ALLOWED_CLIENT_CIDRS emits an allow line per CIDR followed by deny all" {
    PROXY_ALLOWED_CLIENT_CIDRS="192.168.1.0/24 10.0.0.0/8"
    run _render_stream_client_acl
    [ "$status" -eq 0 ]
    [[ "$output" == *'allow 192.168.1.0/24;'* ]]
    [[ "$output" == *'allow 10.0.0.0/8;'* ]]
    [[ "$output" == *'deny all;'* ]]
}

# The exact regression this finding described: without this fix, no
# allow/deny lines existed anywhere in the stream {} context regardless of
# CIDR configuration. This proves the file the fix generates is never
# silently empty (beyond its own header comment) once CIDRs are configured
# -- an empty generated file would still `include` successfully (a no-op),
# masking the exact same unrestricted-relay bug this fix exists to close.
@test "the generated file is not merely the header comment once CIDRs are configured" {
    PROXY_ALLOWED_CLIENT_CIDRS="192.168.1.0/24"
    run _render_stream_client_acl
    [ "$status" -eq 0 ]
    directive_lines="$(grep -cE '^(allow|deny) ' <<<"$output")"
    [ "$directive_lines" -ge 2 ]
}

@test "deny all always comes after every allow line, never before" {
    PROXY_ALLOWED_CLIENT_CIDRS="192.168.1.0/24 10.0.0.0/8"
    run _render_stream_client_acl
    [ "$status" -eq 0 ]
    deny_line="$(grep -n '^deny all;' <<<"$output" | cut -d: -f1)"
    last_allow_line="$(grep -n '^allow ' <<<"$output" | tail -1 | cut -d: -f1)"
    [ -n "$deny_line" ]
    [ -n "$last_allow_line" ]
    [ "$deny_line" -gt "$last_allow_line" ]
}
