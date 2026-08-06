#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression guard for bug-hunt #849 findings #11 (/healthz had no access
# control at all in either conf.d/http.conf or conf.d/https.conf) and #15
# (Cache-Control/Expires were ignored for caching but not hidden from the
# client, unlike Set-Cookie/Vary). These are static config files, not shell
# functions -- there is no `nginx -t`/live-request harness in this bats
# suite (no Docker/nginx available here, see tests/bats/proxy_cert_generation.bats's
# own "_bounded_cert_name is defined before the SSL_ENABLED conditional
# block" test for the established precedent of asserting a cheap, real,
# deterministic invariant instead of a runtime behavior a unit test can't
# reach). This file greps the real, checked-in config text directly (not a
# copy) so a future edit that silently removes either fix fails this suite
# immediately, even though it cannot prove nginx actually enforces these
# directives at runtime -- that live proof still needs a real container
# (deploy/prod's own healthcheck already exercises /healthz successfully on
# every real deployment, which is the closest existing live coverage for the
# "did we break the healthcheck" half of this change).

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    http_conf="$repo_root/services/proxy/conf.d/http.conf"
    https_conf="$repo_root/services/proxy/conf.d/https.conf"
    proxy_params="$repo_root/services/proxy/proxy-params.conf"
}

# Extracts the exact `location = /healthz { ... }` block text so assertions
# below can't accidentally match an unrelated `allow`/`deny` line elsewhere
# in the same file (e.g. /nginx_status's own, pre-existing ACL).
_healthz_block() {
    awk '/location = \/healthz \{/{f=1} f{print} f&&/^    \}$/{exit}' "$1"
}

@test "http.conf's /healthz block has an allow/deny ACL, not left wide open" {
    block="$(_healthz_block "$http_conf")"
    [[ "$block" == *'allow 127.0.0.1/32;'* ]]
    [[ "$block" == *'allow 172.16.0.0/12;'* ]]
    [[ "$block" == *'deny  all;'* ]]
}

@test "https.conf's /healthz block has the same allow/deny ACL" {
    block="$(_healthz_block "$https_conf")"
    [[ "$block" == *'allow 127.0.0.1/32;'* ]]
    [[ "$block" == *'allow 172.16.0.0/12;'* ]]
    [[ "$block" == *'deny  all;'* ]]
}

# deny must come after both allow lines in both files -- nginx's
# ngx_http_access_module evaluates allow/deny in file order and stops at the
# first match, so a misordered deny-before-allow would silently reject
# everyone, including the loopback healthcheck itself.
@test "deny comes after both allow lines in http.conf's /healthz block" {
    block="$(_healthz_block "$http_conf")"
    deny_line="$(grep -n 'deny' <<<"$block" | head -1 | cut -d: -f1)"
    last_allow_line="$(grep -n 'allow' <<<"$block" | tail -1 | cut -d: -f1)"
    [ -n "$deny_line" ]
    [ -n "$last_allow_line" ]
    [ "$deny_line" -gt "$last_allow_line" ]
}

@test "proxy-params.conf hides Cache-Control and Expires from the client" {
    grep -qE '^proxy_hide_header +Cache-Control;' "$proxy_params"
    grep -qE '^proxy_hide_header +Expires;' "$proxy_params"
}

# Contrast/non-regression: the pre-existing Set-Cookie/Vary hiding (never
# broken, not part of this finding) must still be present too -- proves this
# change added to the existing directives rather than accidentally
# replacing them.
@test "proxy-params.conf still hides Set-Cookie and Vary (pre-existing, unrelated to this fix)" {
    grep -qE '^proxy_hide_header +Set-Cookie;' "$proxy_params"
    grep -qE '^proxy_hide_header +Vary;' "$proxy_params"
}

@test "proxy-params.conf still ignores all four headers for its own caching decision" {
    grep -qE '^proxy_ignore_headers +Cache-Control Expires Vary Set-Cookie;' "$proxy_params"
}
