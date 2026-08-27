#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: real DNS/HTTP/HTTPS caching test against a genuinely fetchable target.
# Why: game CDN domains need signed/session URLs a plain curl can't satisfy;
#   deb.debian.org is already a cached distro mirror needing no custom image,
#   and proves dns-ssl's DNS answer leads to a genuinely distinct MITM endpoint.
# From: Issue #597 | Issue #668.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$repo_root"

# shellcheck source=scripts/lib/reserve-validation-subnet.sh
source "$repo_root/scripts/lib/reserve-validation-subnet.sh"

test_domain="deb.debian.org"
test_path="/debian/README"
# What: the SSL-mode leg uses a distinct path from the standard-mode leg.
# Why: the proxy cache key is $host$uri$slice_range (AGENTS.md AG-OP-001),
#   shared between HTTP and HTTPS on the same container -- reusing the same
#   path found it already cached, reporting a false HIT on the first request.
ssl_test_path="/debian/dists/stable/Release"
work_dir="$repo_root/.ssl-mitm-simulation-tmp"
rm -rf "$work_dir"
mkdir -p "$work_dir"

compose_project="${COMPOSE_PROJECT_NAME:-lancache-ng-validation}"
network_name="${compose_project}_validation"
# What: defaults must exactly match docker-compose.yml's own VALIDATION_* fallbacks.
# Why: `docker compose up` reads the same vars to decide the real container
#   IPs; a mismatch targets the wrong address. Overridden per-run by the
#   automatic concurrent-PR gate for collision-free subnets.
# From: Issue #667 | Issue #715.
proxy_ip="${VALIDATION_PROXY_IP:-172.30.99.2}"
dns_standard_ip="${VALIDATION_DNS_STANDARD_IP:-172.30.99.3}"
dns_ssl_ip="${VALIDATION_DNS_SSL_IP:-172.30.99.5}"
# What: never reads/hardcodes $VALIDATION_STANDARD_SHIM_IP directly.
# Why: unlike the dig-target IPs above, the shim's address is only ever a
#   dig ANSWER; hardcoding and asserting against it would reintroduce the
#   shallow check of comparing a DNS answer to a literal instead of proving
#   it leads somewhere real.
# From: Issue #668.
build_tools_image="${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}"
image_tag="${LANCACHE_IMAGE_TAG:-nightly}"
compose=(docker compose -p "$compose_project" -f deploy/full-setup/docker-compose.yml)

cleanup() {
    local status=$?
    validation_simulation_teardown "$compose_project" "$work_dir"
    exit "$status"
}
trap cleanup EXIT

# What: clears leftover compose state before `up -d` runs.
# Why: a killed (not exited) prior run skips the EXIT trap, leaving the
#   fixed-name proxy-cache volume populated -- this run's first request
#   would then come back a false HIT instead of the expected MISS.
# From: Issue #667.
echo "== Clearing any leftover state from a previous run =="
"${compose[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
validation_project_networks_teardown "$compose_project" || true

echo "== Pulling the published $image_tag images =="

# What: explicit pull before `up -d`; standard-passthrough-shim excluded.
# Why: Compose's pull_policy: missing would otherwise silently reuse a
#   locally cached image instead of the one actually published for this run.
#   The shim (plain Docker Hub alpine) is pulled/started by `up -d` itself.
# From: Issue #667.
LANCACHE_IMAGE_TAG="$image_tag" "${compose[@]}" pull --quiet proxy dns-standard dns-ssl nats

echo "== Starting proxy/dns-standard/dns-ssl/nats/standard-passthrough-shim from the published $image_tag images =="

# What: standard-passthrough-shim is named explicitly in `up -d`.
# Why: it is Compose-profile-gated; an explicitly-named service always
#   starts regardless of active profiles, so no --profile flag is needed.
LANCACHE_IMAGE_TAG="$image_tag" "${compose[@]}" up -d proxy dns-standard dns-ssl nats standard-passthrough-shim

# What: reuses the health-wait pattern already proven elsewhere.
# Why: matches full-setup-validate.yml and setup-cli-simulation.sh so
#   readiness semantics stay consistent across simulations.
deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
    all_ready=1
    for service in proxy dns-standard dns-ssl standard-passthrough-shim; do
        # What: wraps `cid="$(compose ps -q ...)"` in an explicit `if !` check.
        # Why: under `set -euo pipefail`, a bare assignment aborts silently
        #   the instant the command fails, before any diagnostic prints.
        # From: Issue #841.
        if ! cid="$("${compose[@]}" ps -q "$service")"; then
            echo "::error::Could not query the compose container id for service '$service'." >&2
            exit 1
        fi
        status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown")"
        [[ "$status" = "healthy" ]] || all_ready=0
    done
    [[ "$all_ready" -eq 1 ]] && break
    sleep 5
done
for service in proxy dns-standard dns-ssl standard-passthrough-shim; do
    if ! cid="$("${compose[@]}" ps -q "$service")"; then
        echo "::error::Could not query the compose container id for service '$service'." >&2
        exit 1
    fi
    status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown")"
    if [[ "$status" != "healthy" ]]; then
        echo "::error::$service did not become healthy (status: $status)" >&2
        "${compose[@]}" logs --no-color "$service"
        exit 1
    fi
done
echo "proxy, dns-standard, dns-ssl, and standard-passthrough-shim are healthy."

if ! proxy_cid="$("${compose[@]}" ps -q proxy)"; then
    echo "::error::Could not query the compose container id for the proxy service." >&2
    exit 1
fi
docker cp "$proxy_cid:/etc/nginx/ssl/ca/ca.crt" "$work_dir/ca.crt"

# What: /shared is bind-mounted from work_dir into every run_client call.
# Why: each call is a brand new --rm container, so /tmp inside it never
#   survives past that one call -- files written by one call would not
#   exist for a later call, or for cmp/test on the host, without this.
mkdir -p "$work_dir/shared"
run_client() {
    docker run --rm --network "$network_name" \
        -v "$work_dir/ca.crt:/ca.crt:ro" \
        -v "$work_dir/shared:/shared" \
        "$build_tools_image" timeout --kill-after=30 --signal=KILL 120 bash -c "$1"
}

# ─────────────────────────────────────────────────────────────────────────
# What: proof is driven by dig's actual DNS answer; standard-passthrough-shim
#   reproduces prod's IP_STANDARD/IP_SSL port-publish split on this bridge.
# Why: asserting both nameservers resolve to one shared hardcoded address
#   only proves the harness is reachable, never that dns-ssl's answer leads
#   somewhere distinct -- a swapped/misrouted PROXY_IP would pass identically.
# From: Issue #668.
echo "== DNS: resolving $test_domain against dns-standard and dns-ssl =="

# What: wraps `resolved_dns_standard="$(run_client ... | sort -u)"` in `if !`.
# Why: `sort -u` always succeeds even on zero lines of input, so pipefail
#   alone would still mask a failed dig/run_client invocation with no
#   explanation once it reaches the empty/ambiguous check below.
# From: Issue #841.
if ! resolved_dns_standard="$(run_client "dig +time=3 +tries=2 +short @$dns_standard_ip A $test_domain" | sort -u)"; then
    echo "::error::Failed to run dig against dns-standard ($dns_standard_ip) for $test_domain (run_client/docker invocation failed)." >&2
    exit 1
fi
# What: `sort -u` collapses duplicate-but-identical DNS answers only.
# Why: a real ambiguity (more than one distinct address, or none) leaves no
#   well-defined target, and must fail loudly rather than silently picking
#   whichever line came first.
if [[ -z "$resolved_dns_standard" ]] || [[ "$resolved_dns_standard" == *$'\n'* ]]; then
    echo "::error::dns-standard returned an empty or ambiguous DNS answer for $test_domain: '$resolved_dns_standard'" >&2
    exit 1
fi
echo "dns-standard resolves $test_domain to $resolved_dns_standard."

if ! resolved_dns_ssl="$(run_client "dig +time=3 +tries=2 +short @$dns_ssl_ip A $test_domain" | sort -u)"; then
    echo "::error::Failed to run dig against dns-ssl ($dns_ssl_ip) for $test_domain (run_client/docker invocation failed)." >&2
    exit 1
fi
if [[ -z "$resolved_dns_ssl" ]] || [[ "$resolved_dns_ssl" == *$'\n'* ]]; then
    echo "::error::dns-ssl returned an empty or ambiguous DNS answer for $test_domain: '$resolved_dns_ssl'" >&2
    exit 1
fi
echo "dns-ssl resolves $test_domain to $resolved_dns_ssl."

if [[ "$resolved_dns_standard" == "$resolved_dns_ssl" ]]; then
    echo "::error::dns-standard and dns-ssl resolved $test_domain to the SAME address ($resolved_dns_standard) -- they must resolve to distinct endpoints for the port-routing proof below to mean anything (issue #668)." >&2
    exit 1
fi

echo "== Port routing: proving dns-ssl's answer leads to genuine MITM interception and dns-standard's answer leads to genuine SNI passthrough (issue #668) =="

# What: reads our own LAN CA's subject as the issuer-comparison reference.
# Why: it becomes the ISSUER field of every certificate our CA signs, so
#   both legs below compare their presented issuer against this value.
# From: Issue #668.
if ! ca_subject="$(run_client "openssl x509 -noout -subject -in /ca.crt" | sed 's/^subject=//')"; then
    echo "::error::Failed to read our own LAN CA's subject from ca.crt (run_client/openssl invocation failed)." >&2
    exit 1
fi
[[ -n "$ca_subject" ]] || { echo "::error::Could not read our own LAN CA's subject from ca.crt." >&2; exit 1; }
echo "LAN CA subject: $ca_subject"

# --- dns-ssl's resolved address: must present a certificate WE signed ---
# What: pipes `openssl s_client`'s PEM handshake output into `openssl x509`
#   to extract the issuer, under a `timeout` with `< /dev/null` as stdin.
# Why: `s_client` prints the leaf certificate as normal handshake output (no
#   -showcerts needed); `timeout` stops it lingering for application data
#   that never comes, and `< /dev/null` signals EOF instead of a stray newline.
# From: Issue #668.
#
# What: openssl's own stderr is captured into /shared; only s_client's own
#   exit status fails the run_client call, not x509's.
# Why: x509 returning nothing is a legitimate "no certificate presented"
#   result, not an invocation failure -- the two must stay distinguishable.
# From: Issue #1095.
: >"$work_dir/shared/openssl-stderr-ssl.log"
if ! ssl_issuer="$(run_client "timeout 10 openssl s_client -connect $resolved_dns_ssl:443 -servername $test_domain < /dev/null 2>/shared/openssl-stderr-ssl.log | openssl x509 -noout -issuer 2>>/shared/openssl-stderr-ssl.log; s=\${PIPESTATUS[0]}; [[ \$s -eq 0 ]] || exit 1" | sed 's/^issuer=//')"; then
    echo "::error::Failed to complete a TLS handshake against dns-ssl's resolved endpoint ($resolved_dns_ssl) for $test_domain: $(cat "$work_dir/shared/openssl-stderr-ssl.log" 2>/dev/null)" >&2
    exit 1
fi
if [[ "$ssl_issuer" != "$ca_subject" ]]; then
    echo "::error::dns-ssl resolved $test_domain to $resolved_dns_ssl, but the certificate presented on its port 443 was issued by '${ssl_issuer:-<none>}', not our own LAN CA ('$ca_subject'). dns-ssl is not routing to a genuine MITM endpoint." >&2
    exit 1
fi
echo "dns-ssl's resolved address ($resolved_dns_ssl) presents a certificate issued by our own LAN CA -- genuine MITM interception confirmed, driven by the actual DNS answer."

# What: a plain curl (system CA trust store, no --cacert) must FAIL here.
# Why: success would mean the certificate is publicly trusted, which our
#   private LAN CA's certs never are -- the negative half of the MITM proof.
# From: Issue #668.
if run_client "curl -sS --connect-timeout 5 --max-time 10 --resolve $test_domain:443:$resolved_dns_ssl -o /dev/null 'https://$test_domain$ssl_test_path'"; then
    echo "::error::A plain curl (default system CA trust store, no --cacert) trusted dns-ssl's resolved endpoint's certificate. A genuinely intercepted connection should only validate against our own ca.crt, never the public trust store." >&2
    exit 1
fi
echo "dns-ssl's resolved endpoint's certificate is correctly rejected by the public/system CA trust store (only trusted via our own ca.crt) -- confirms interception, not passthrough."

# --- dns-standard's resolved address: must present the REAL origin's own certificate ---
# What: openssl's own stderr is captured into /shared; only s_client's own
#   exit status fails the run_client call, not x509's.
# Why: x509 returning nothing is a legitimate "no certificate presented"
#   result, handled by the explicit check below, not an invocation failure.
# From: Issue #1095.
: >"$work_dir/shared/openssl-stderr-standard.log"
if ! standard_issuer="$(run_client "timeout 10 openssl s_client -connect $resolved_dns_standard:443 -servername $test_domain < /dev/null 2>/shared/openssl-stderr-standard.log | openssl x509 -noout -issuer 2>>/shared/openssl-stderr-standard.log; s=\${PIPESTATUS[0]}; [[ \$s -eq 0 ]] || exit 1" | sed 's/^issuer=//')"; then
    echo "::error::Failed to complete a TLS handshake against dns-standard's resolved endpoint ($resolved_dns_standard) for $test_domain: $(cat "$work_dir/shared/openssl-stderr-standard.log" 2>/dev/null)" >&2
    exit 1
fi
[[ -n "$standard_issuer" ]] \
    || { echo "::error::dns-standard resolved $test_domain to $resolved_dns_standard, but no certificate at all was presented on its port 443 -- SNI passthrough to the real origin is not reaching it." >&2; exit 1; }
if [[ "$standard_issuer" == "$ca_subject" ]]; then
    echo "::error::dns-standard resolved $test_domain to $resolved_dns_standard, and its port 443 presented a certificate issued by OUR OWN LAN CA ('$ca_subject'). It should be blindly forwarding to the real origin's own certificate, not intercepting -- dns-standard is wrongly wired to a MITM endpoint. This is exactly the misconfiguration issue #668 warned the old check could not catch." >&2
    exit 1
fi
echo "dns-standard's resolved address ($resolved_dns_standard) presents a certificate NOT issued by our LAN CA (issuer: $standard_issuer) -- genuine SNI passthrough to the real origin confirmed, driven by the actual DNS answer."

# What: the inverse of the negative check above -- plain curl MUST succeed.
# Why: this leg is meant to reach the real origin's own publicly-trusted
#   certificate, not ours.
# From: Issue #668.
run_client "curl -sS --connect-timeout 5 --max-time 10 --resolve $test_domain:443:$resolved_dns_standard -o /dev/null 'https://$test_domain$ssl_test_path'" \
    || { echo "::error::A plain curl (default system CA trust store, no --cacert) FAILED to validate dns-standard's resolved endpoint's certificate. Expected the real origin's own publicly-trusted certificate to validate cleanly there." >&2; exit 1; }
echo "dns-standard's resolved endpoint's certificate validates cleanly against the public/system CA trust store -- confirms this is the real origin's own certificate, not ours."

echo "Distinguishing property proven end-to-end (issue #668): dns-ssl's own DNS answer for $test_domain leads to a TLS endpoint presenting a certificate signed by our LAN CA (real MITM interception), while dns-standard's own DNS answer for the SAME domain leads to a genuinely different TLS endpoint presenting the real origin's own certificate (SNI passthrough, no interception) -- these are provably distinct endpoints determined by the DNS answer itself, not by a hardcoded address shared between both paths."

# What: curl uses a 30s --max-time and inlines -w's quoted format string per run_client call.
# Why: these are real proxy fetches needing more headroom than a loopback
#   health check; a shared curl_opts array loses its quoting across
#   run_client's second, inner bash -c, and silently breaks the -w output.
# From: Issue #667.
curl_timeouts="-sS --connect-timeout 5 --max-time 30"

echo "== Standard mode: HTTP MISS then HIT for a real file =="

# What: uses $proxy_ip directly here, not a DNS-resolved address.
# Why: port 80 is shared/identical between both modes in prod too; there is
#   no per-mode HTTP behavior to distinguish, only the port-443 split above.
# From: Issue #668.
if ! http_status_1="$(run_client "curl $curl_timeouts -w '\nHTTP_STATUS:%{http_code}\n' -o /shared/body1 -D - -H 'Host: $test_domain' 'http://$proxy_ip$test_path'")"; then
    echo "::error::First standard-mode HTTP request via run_client failed outright (curl/docker invocation error)." >&2
    exit 1
fi
grep -qi '^X-Cache-Status: MISS' <<<"$http_status_1" \
    || { echo "::error::First standard-mode HTTP request was not a MISS." >&2; echo "$http_status_1" >&2; exit 1; }
grep -q '^HTTP_STATUS:200$' <<<"$http_status_1" \
    || { echo "::error::First standard-mode HTTP request did not return HTTP 200." >&2; echo "$http_status_1" >&2; exit 1; }

if ! http_status_2="$(run_client "curl $curl_timeouts -w '\nHTTP_STATUS:%{http_code}\n' -o /shared/body2 -D - -H 'Host: $test_domain' 'http://$proxy_ip$test_path'")"; then
    echo "::error::Second standard-mode HTTP request via run_client failed outright (curl/docker invocation error)." >&2
    exit 1
fi
grep -qi '^X-Cache-Status: HIT' <<<"$http_status_2" \
    || { echo "::error::Second standard-mode HTTP request was not a HIT." >&2; echo "$http_status_2" >&2; exit 1; }
grep -q '^HTTP_STATUS:200$' <<<"$http_status_2" \
    || { echo "::error::Second standard-mode HTTP request did not return HTTP 200." >&2; echo "$http_status_2" >&2; exit 1; }

cmp -s "$work_dir/shared/body1" "$work_dir/shared/body2" \
    || { echo "::error::Standard-mode MISS and HIT responses had different bodies." >&2; exit 1; }
[[ -s "$work_dir/shared/body1" ]] \
    || { echo "::error::Standard-mode response body was empty." >&2; exit 1; }
echo "Standard mode: MISS then HIT confirmed, with identical real file content on both requests."

echo "== SSL mode: HTTPS MITM MISS then HIT for a real file =="

# What: --resolve targets $resolved_dns_ssl, the actual dns-ssl DNS answer.
# Why: like the port-routing proof above it, this cache test is driven by
#   DNS rather than by an address dns-ssl merely happens to share.
# From: Issue #668.
if ! https_status_1="$(run_client "curl $curl_timeouts -w '\nHTTP_STATUS:%{http_code}\n' --resolve $test_domain:443:$resolved_dns_ssl --cacert /ca.crt -o /shared/sbody1 -D - 'https://$test_domain$ssl_test_path'")"; then
    echo "::error::First SSL-mode HTTPS request via run_client failed outright (curl/docker invocation error)." >&2
    exit 1
fi
grep -qi '^X-Cache-Status: MISS' <<<"$https_status_1" \
    || { echo "::error::First SSL-mode HTTPS request was not a MISS." >&2; echo "$https_status_1" >&2; exit 1; }
grep -q '^HTTP_STATUS:200$' <<<"$https_status_1" \
    || { echo "::error::First SSL-mode HTTPS request did not return HTTP 200." >&2; echo "$https_status_1" >&2; exit 1; }

if ! https_status_2="$(run_client "curl $curl_timeouts -w '\nHTTP_STATUS:%{http_code}\n' --resolve $test_domain:443:$resolved_dns_ssl --cacert /ca.crt -o /shared/sbody2 -D - 'https://$test_domain$ssl_test_path'")"; then
    echo "::error::Second SSL-mode HTTPS request via run_client failed outright (curl/docker invocation error)." >&2
    exit 1
fi
grep -qi '^X-Cache-Status: HIT' <<<"$https_status_2" \
    || { echo "::error::Second SSL-mode HTTPS request was not a HIT." >&2; echo "$https_status_2" >&2; exit 1; }
grep -q '^HTTP_STATUS:200$' <<<"$https_status_2" \
    || { echo "::error::Second SSL-mode HTTPS request did not return HTTP 200." >&2; echo "$https_status_2" >&2; exit 1; }

cmp -s "$work_dir/shared/sbody1" "$work_dir/shared/sbody2" \
    || { echo "::error::SSL-mode MISS and HIT responses had different bodies." >&2; exit 1; }
[[ -s "$work_dir/shared/sbody1" ]] \
    || { echo "::error::SSL-mode response body was empty." >&2; exit 1; }
echo "SSL mode: MITM MISS then HIT confirmed -- the proxy decrypted, cached, and re-served a real file over HTTPS using our own CA."

echo "ssl-mitm-cache-simulation passed: DNS-driven MITM-vs-passthrough endpoint distinction, standard-mode HTTP caching, and SSL-mode MITM caching all verified against a real, fetchable file."
