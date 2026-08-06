#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
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
#
# IMPORTANT, found live during this fix's own review (2026-08-06/07): an
# EARLIER version of this same finding #11 fix served /healthz via a bare
# `return 200 "ok\n";` in the same location as the `allow`/`deny` ACL --
# every assertion in this file still passed against that version, because
# they only check the ACL text is PRESENT, never that nginx actually
# enforces it. A real differential live-container test (two real `proxy`
# containers, one queried from a genuinely excluded source IP on a
# dedicated Docker network, per docs/release-validation-plan.md's Standing
# checks row for finding #11) proved that version's ACL was a complete
# no-op: ANY source got 200, including a source outside both allowed
# CIDRs. Root cause: `return` is an ngx_http_rewrite_module directive that
# runs in nginx's rewrite phase, which executes BEFORE the access phase
# `allow`/`deny` are evaluated in -- confirmed in isolation on a stock,
# unmodified nginx:1.27-alpine image (not specific to this project's own
# build): a bare `deny all;` alone correctly returns 403; the identical
# `deny all;` alongside a `return` in the same location returns 200
# regardless of source. The fix (this file's current version) serves the
# body via `alias` to a real file instead (entrypoint.sh's own "3a."
# generates it at startup) -- `alias` uses ngx_http_static_module's
# content-phase handler, which runs AFTER the access phase and was
# confirmed live to enforce the ACL correctly in both directions. The two
# tests below guard specifically against reintroducing the `return`+`deny`
# shape in either file, since that is the one part of this regression a
# static grep-based check CAN catch cheaply and reliably, even without a
# live nginx harness.

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

@test "http.conf's /healthz block serves its body via alias (content phase), not a bare return (rewrite phase, bypasses the ACL above -- confirmed live)" {
    block="$(_healthz_block "$http_conf")"
    [[ "$block" == *'alias /etc/nginx/lancache-healthz-body.txt;'* ]]
    [[ "$block" != *'return '* ]]
}

@test "https.conf's /healthz block serves its body via alias too, not a bare return" {
    block="$(_healthz_block "$https_conf")"
    [[ "$block" == *'alias /etc/nginx/lancache-healthz-body.txt;'* ]]
    [[ "$block" != *'return '* ]]
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
