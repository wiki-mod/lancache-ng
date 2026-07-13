#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Real DNS/HTTP/HTTPS caching test against a genuinely fetchable target
# (issue #597, part of #557 scenario 1). Game CDN domains in cdn-domains.txt
# mostly need signed/session URLs and won't serve a plain curl request --
# but this project already caches Linux distro mirrors too (see the
# "Debian"/"Fedora"/etc. sections of services/dns/cdn-domains.txt), and
# deb.debian.org is one of them. That means this test needs no custom-built
# images at all: it uses the real, already-published dns/proxy images
# (matching the LANCACHE_IMAGE_CHANNEL default full-setup-validate.yml uses)
# and reuses deploy/full-setup/docker-compose.yml as-is for everything
# (NATS, networking, healthchecks already proven there).
#
# (An earlier version of this script built throwaway images with a domain
# appended to a test-only cdn-domains.txt copy, before noticing
# deb.debian.org was already a real entry -- that approach also hit a
# missing-buildx-plugin gap in the build-tools image. Not needed now, but
# worth remembering if a *different* test domain is ever needed here: that
# file is baked into the dns/proxy images at build time, no runtime
# override exists.)
#
# Also proves the property issue #668 found missing: that dns-ssl's own DNS
# answer for a CDN hostname leads to a genuinely distinct, MITM-capable
# endpoint -- not just "the one address this harness happens to share" (see
# the "DNS + port-routing proof" section below for the full mechanism).
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

test_domain="deb.debian.org"
test_path="/debian/README"
# A second, distinct real path on the same host for the SSL-mode leg: the
# cache key is $host$uri (see CLAUDE.md), shared between HTTP and HTTPS on
# the same proxy container, so reusing test_path here found it already
# cached by the standard-mode test above and reported HIT on its supposedly
# fresh first request -- confirmed directly. A different path guarantees an
# independent, genuinely fresh cache entry for this leg.
ssl_test_path="/debian/dists/stable/Release"
work_dir="$repo_root/.ssl-mitm-simulation-tmp"
rm -rf "$work_dir"
mkdir -p "$work_dir"

compose_project="${COMPOSE_PROJECT_NAME:-lancache-ng-validation}"
network_name="${compose_project}_validation"
# Must track deploy/full-setup/docker-compose.yml's own
# ${VALIDATION_PROXY_IP:-172.30.99.2}-style defaults exactly: `docker compose
# up` below (which reads these same VALIDATION_* vars from this script's
# process environment) decides the REAL container IPs, so a mismatch here
# would make every dig/curl call below target the wrong address. Falls back
# to the historical fixed IPs when unset (e.g. when called from the manual
# full-setup-validate.yml, which does not thread these through -- see that
# workflow's own compute-validation-network job/comment) so existing
# behaviour there is unchanged. The full-setup-deep-validate.yml automatic
# gate (#715) DOES set these, giving each concurrent PR run its own
# collision-free subnet instead of the fixed one (Codex review finding on
# #764: without this, two concurrent runs on the same self-hosted host could
# still overlap on the default subnet despite having distinct Compose
# project names).
proxy_ip="${VALIDATION_PROXY_IP:-172.30.99.2}"
dns_standard_ip="${VALIDATION_DNS_STANDARD_IP:-172.30.99.3}"
dns_ssl_ip="${VALIDATION_DNS_SSL_IP:-172.30.99.5}"
# Note: this script deliberately never reads $VALIDATION_STANDARD_SHIM_IP
# (or a hardcoded 172.30.99.10-style default for it) directly -- unlike
# proxy_ip/dns_standard_ip/dns_ssl_ip above, which are dig TARGETS (the
# nameserver to query), standard-passthrough-shim's address is only ever
# consumed as a dig ANSWER (whatever dns-standard resolves $test_domain to,
# captured below into $resolved_dns_standard) and as Docker Compose's own
# `up -d` env var for placing that container on the network. Hardcoding its
# expected value here and asserting against it would silently reintroduce
# exactly the shallow check issue #668 found: comparing a DNS answer to a
# hardcoded literal instead of proving the answer leads somewhere real.
build_tools_image="${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}"
image_tag="${LANCACHE_IMAGE_TAG:-edge}"
compose=(docker compose -p "$compose_project" -f deploy/full-setup/docker-compose.yml)

cleanup() {
    local status=$?
    "${compose[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
    rm -rf "$work_dir"
    exit "$status"
}
trap cleanup EXIT

# A cancelled/crashed prior run only gets cleaned up by the EXIT trap above,
# which never runs if the process was killed rather than exited normally.
# That can leave the fixed-name "${compose_project}_proxy-cache" volume
# behind with entries from that earlier run, so this run's supposedly fresh
# first request would come back a false HIT instead of the expected MISS.
# Clearing it before `up -d` guarantees every run starts from an empty cache.
echo "== Clearing any leftover state from a previous run =="
"${compose[@]}" down -v --remove-orphans >/dev/null 2>&1 || true

echo "== Pulling the published $image_tag images =="

# Without an explicit pull, Compose's pull_policy: missing (see
# deploy/full-setup/docker-compose.yml) would silently reuse whatever image
# is already cached locally under this tag instead of the one actually
# published for this run -- matching the pull step the full-setup-validate
# job in the same workflow already runs before its own `up -d`. Note:
# standard-passthrough-shim (alpine, pulled straight from Docker Hub, not one
# of our own published images) is deliberately NOT in this pull list --
# `up -d` below pulls/starts it itself via Compose's default pull_policy.
LANCACHE_IMAGE_TAG="$image_tag" "${compose[@]}" pull --quiet proxy dns-standard dns-ssl nats

echo "== Starting proxy/dns-standard/dns-ssl/nats/standard-passthrough-shim from the published $image_tag images =="

# standard-passthrough-shim is named explicitly here because it is
# Compose-profile-gated (see its comment in docker-compose.yml) -- an
# explicitly-named service on the command line always starts regardless of
# which profiles are active, so no --profile flag is needed here even though
# no profile is enabled for this invocation.
LANCACHE_IMAGE_TAG="$image_tag" "${compose[@]}" up -d proxy dns-standard dns-ssl nats standard-passthrough-shim

# Mirrors the health-wait pattern already proven in full-setup-validate.yml
# and scripts/setup-cli-simulation.sh. ("compose" is already defined above,
# reused here for the health checks and later cleanup.)
deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
    all_ready=1
    for service in proxy dns-standard dns-ssl standard-passthrough-shim; do
        cid="$("${compose[@]}" ps -q "$service")"
        status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown")"
        [[ "$status" = "healthy" ]] || all_ready=0
    done
    [[ "$all_ready" -eq 1 ]] && break
    sleep 5
done
for service in proxy dns-standard dns-ssl standard-passthrough-shim; do
    cid="$("${compose[@]}" ps -q "$service")"
    status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown")"
    if [[ "$status" != "healthy" ]]; then
        echo "::error::$service did not become healthy (status: $status)" >&2
        "${compose[@]}" logs --no-color "$service"
        exit 1
    fi
done
echo "proxy, dns-standard, dns-ssl, and standard-passthrough-shim are healthy."

proxy_cid="$("${compose[@]}" ps -q proxy)"
docker cp "$proxy_cid:/etc/nginx/ssl/ca/ca.crt" "$work_dir/ca.crt"

# Each call is a brand new --rm container, so /tmp inside it never survives
# past that one call -- confirmed directly: comparing files written by two
# separate run_client calls always "failed" because neither file existed in
# either of the (also separate) containers doing the comparing. /shared is
# bind-mounted from work_dir (a real, persistent host directory) so files
# written by one call are actually still there for a later call, and so
# cmp/test below can run directly on the host instead of needing yet
# another container.
mkdir -p "$work_dir/shared"
run_client() {
    docker run --rm --network "$network_name" \
        -v "$work_dir/ca.crt:/ca.crt:ro" \
        -v "$work_dir/shared:/shared" \
        "$build_tools_image" bash -c "$1"
}

# ─────────────────────────────────────────────────────────────────────────
# DNS + port-routing proof (issue #668)
#
# Prior versions of this check asserted dns-standard AND dns-ssl both
# resolve $test_domain to the SAME hardcoded $proxy_ip -- which only proved
# "both nameservers answer with the one reachable address this harness
# shares," never that dns-ssl's answer actually leads anywhere different
# from dns-standard's. A dns-ssl wrongly wired to the standard-mode address
# would have passed that check identically (the issue's own finding).
#
# Prod's real distinguishing mechanism: IP_STANDARD:443 is Docker-port-
# published into the (single, unified) proxy container's internal :8443
# SNI-passthrough listener, while IP_SSL:443 is published into its internal
# :443 TLS-interception listener (entrypoint.sh's "Docker routes
# IP_SSL:443->container:443 and IP_STANDARD:443->container:8443" comment).
# That host-IP-scoped port-publish translation has no equivalent on this
# bridge-network validation harness by itself, so
# deploy/full-setup/docker-compose.yml now adds a small
# standard-passthrough-shim service that reproduces it directly: a real,
# separate address whose :443 forwards to proxy:8443 (passthrough), while
# dns-standard's PROXY_IP now points there instead of at the proxy
# container's own address (dns-ssl's PROXY_IP is unchanged -- proxy:443 IS
# the interception listener already).
#
# The proof below is deliberately driven by dig's ACTUAL answer, not by
# these hardcoded expected-default variables: it connects to whatever each
# DNS server returns and inspects the certificate presented there. If
# dns-ssl and dns-standard's PROXY_IP wiring were ever swapped (or either
# pointed at the wrong address), the certificate-issuer assertions below
# would fail for the right reason -- a real endpoint-behavior mismatch, not
# a string comparison against a value this same misconfiguration could
# trivially also satisfy.
echo "== DNS: resolving $test_domain against dns-standard and dns-ssl =="

resolved_dns_standard="$(run_client "dig +time=3 +tries=2 +short @$dns_standard_ip A $test_domain" | sort -u)"
# sort -u collapses PowerDNS RPZ answering with the same A record on
# multiple lines (seen during development) -- but a real ambiguity (more
# than one DISTINCT address, or none at all) leaves no well-defined target
# to connect to for the proof below, so that must fail loudly here rather
# than silently connecting to whichever line happened to be picked.
if [[ -z "$resolved_dns_standard" ]] || [[ "$resolved_dns_standard" == *$'\n'* ]]; then
    echo "::error::dns-standard returned an empty or ambiguous DNS answer for $test_domain: '$resolved_dns_standard'" >&2
    exit 1
fi
echo "dns-standard resolves $test_domain to $resolved_dns_standard."

resolved_dns_ssl="$(run_client "dig +time=3 +tries=2 +short @$dns_ssl_ip A $test_domain" | sort -u)"
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

# Our own LAN CA's subject becomes the ISSUER field of every certificate it
# signs -- this is the reference value both legs below are compared against.
ca_subject="$(run_client "openssl x509 -noout -subject -in /ca.crt" | sed 's/^subject=//')"
[[ -n "$ca_subject" ]] || { echo "::error::Could not read our own LAN CA's subject from ca.crt." >&2; exit 1; }
echo "LAN CA subject: $ca_subject"

# --- dns-ssl's resolved address: must present a certificate WE signed ---
# `openssl s_client` prints the peer's leaf certificate in PEM as part of
# its normal handshake output (no -showcerts needed); piping that into
# `openssl x509` extracts its issuer. `timeout` guards against s_client
# lingering after the handshake waiting for application data that never
# comes; `< /dev/null` signals EOF immediately instead of writing a stray
# newline the server might otherwise wait on.
ssl_issuer="$(run_client "timeout 10 openssl s_client -connect $resolved_dns_ssl:443 -servername $test_domain < /dev/null 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null" | sed 's/^issuer=//')"
if [[ "$ssl_issuer" != "$ca_subject" ]]; then
    echo "::error::dns-ssl resolved $test_domain to $resolved_dns_ssl, but the certificate presented on its port 443 was issued by '${ssl_issuer:-<none>}', not our own LAN CA ('$ca_subject'). dns-ssl is not routing to a genuine MITM endpoint." >&2
    exit 1
fi
echo "dns-ssl's resolved address ($resolved_dns_ssl) presents a certificate issued by our own LAN CA -- genuine MITM interception confirmed, driven by the actual DNS answer."

# A plain curl using the SYSTEM CA trust store (no --cacert) must FAIL here:
# if it succeeded, the certificate would have to be one a public trust store
# recognizes, which our own private LAN CA's certs never are. This is the
# negative-space half of the proof: not just "issued by our CA" (above) but
# "NOT independently, publicly trusted."
if run_client "curl -sS --connect-timeout 5 --max-time 10 --resolve $test_domain:443:$resolved_dns_ssl -o /dev/null 'https://$test_domain$ssl_test_path'"; then
    echo "::error::A plain curl (default system CA trust store, no --cacert) trusted dns-ssl's resolved endpoint's certificate. A genuinely intercepted connection should only validate against our own ca.crt, never the public trust store." >&2
    exit 1
fi
echo "dns-ssl's resolved endpoint's certificate is correctly rejected by the public/system CA trust store (only trusted via our own ca.crt) -- confirms interception, not passthrough."

# --- dns-standard's resolved address: must present the REAL origin's own certificate ---
standard_issuer="$(run_client "timeout 10 openssl s_client -connect $resolved_dns_standard:443 -servername $test_domain < /dev/null 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null" | sed 's/^issuer=//')"
[[ -n "$standard_issuer" ]] \
    || { echo "::error::dns-standard resolved $test_domain to $resolved_dns_standard, but no certificate at all was presented on its port 443 -- SNI passthrough to the real origin is not reaching it." >&2; exit 1; }
if [[ "$standard_issuer" == "$ca_subject" ]]; then
    echo "::error::dns-standard resolved $test_domain to $resolved_dns_standard, and its port 443 presented a certificate issued by OUR OWN LAN CA ('$ca_subject'). It should be blindly forwarding to the real origin's own certificate, not intercepting -- dns-standard is wrongly wired to a MITM endpoint. This is exactly the misconfiguration issue #668 warned the old check could not catch." >&2
    exit 1
fi
echo "dns-standard's resolved address ($resolved_dns_standard) presents a certificate NOT issued by our LAN CA (issuer: $standard_issuer) -- genuine SNI passthrough to the real origin confirmed, driven by the actual DNS answer."

# The inverse of the negative check above: a plain curl using the SYSTEM CA
# trust store MUST succeed here, since this is meant to be the real origin's
# own, publicly-trusted certificate, not ours.
run_client "curl -sS --connect-timeout 5 --max-time 10 --resolve $test_domain:443:$resolved_dns_standard -o /dev/null 'https://$test_domain$ssl_test_path'" \
    || { echo "::error::A plain curl (default system CA trust store, no --cacert) FAILED to validate dns-standard's resolved endpoint's certificate. Expected the real origin's own publicly-trusted certificate to validate cleanly there." >&2; exit 1; }
echo "dns-standard's resolved endpoint's certificate validates cleanly against the public/system CA trust store -- confirms this is the real origin's own certificate, not ours."

echo "Distinguishing property proven end-to-end (issue #668): dns-ssl's own DNS answer for $test_domain leads to a TLS endpoint presenting a certificate signed by our LAN CA (real MITM interception), while dns-standard's own DNS answer for the SAME domain leads to a genuinely different TLS endpoint presenting the real origin's own certificate (SNI passthrough, no interception) -- these are provably distinct endpoints determined by the DNS answer itself, not by a hardcoded address shared between both paths."

# --connect-timeout/--max-time: same flags scripts/full-setup-client-simulation.sh
# already uses for its own external-facing curl calls, so a hung connection
# or an origin that never responds fails fast with a clear error instead of
# hanging the job until the runner-level timeout. --max-time is higher here
# (30s, vs. that script's 10s) because these two requests are real fetches
# through the proxy out to deb.debian.org on a MISS, not a same-host health
# check -- a slow CI network path fetching a real file needs more headroom
# than a loopback health probe does.
#
# -w appends the actual HTTP status code after the headers so it can be
# asserted below alongside X-Cache-Status: services/proxy also caches 3xx
# responses (see CLAUDE.md), so a redirect could otherwise produce a
# plausible-looking MISS-then-HIT pair without ever fetching real content.
#
# The -w argument's single quotes must stay inline in each run_client
# command string below rather than living in a shared array/variable:
# run_client's "$1" is re-parsed by a *second*, inner bash (inside the
# container), and only quote characters that survive into that string
# literally are honored there. A shared curl_opts array flattened with
# "${curl_opts[*]}" loses its quoting in the outer bash before the inner
# bash ever sees it, leaving an unquoted "\n" that bash's own unquoted
# backslash-escaping then strips down to a bare "n" -- confirmed directly:
# curl received "nHTTP_STATUS:%{http_code}n" with no quotes and no
# newlines, so the assertion below could never match. Only inline,
# still-quoted text like the pre-existing -H 'Host: ...' below survives
# this same round trip correctly.
curl_timeouts="-sS --connect-timeout 5 --max-time 30"

echo "== Standard mode: HTTP MISS then HIT for a real file =="

# Deliberately uses $proxy_ip directly, NOT a DNS-resolved address: port 80
# is shared/identical between both modes in prod too (see
# deploy/prod/docker-compose.yml's "Port 80: HTTP caching (shared cache for
# both modes)" comment) -- there is no per-mode HTTP behavior to distinguish
# here, only the port-443 MITM-vs-passthrough split proven above.
http_status_1="$(run_client "curl $curl_timeouts -w '\nHTTP_STATUS:%{http_code}\n' -o /shared/body1 -D - -H 'Host: $test_domain' 'http://$proxy_ip$test_path'")"
grep -qi '^X-Cache-Status: MISS' <<<"$http_status_1" \
    || { echo "::error::First standard-mode HTTP request was not a MISS." >&2; echo "$http_status_1" >&2; exit 1; }
grep -q '^HTTP_STATUS:200$' <<<"$http_status_1" \
    || { echo "::error::First standard-mode HTTP request did not return HTTP 200." >&2; echo "$http_status_1" >&2; exit 1; }

http_status_2="$(run_client "curl $curl_timeouts -w '\nHTTP_STATUS:%{http_code}\n' -o /shared/body2 -D - -H 'Host: $test_domain' 'http://$proxy_ip$test_path'")"
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

# --resolve targets $resolved_dns_ssl (the ACTUAL dns-ssl answer captured
# above), not the separately-hardcoded $proxy_ip -- so this cache test, like
# the port-routing proof above it, is driven by DNS rather than by an
# address dns-ssl merely happens to share with the hardcoded default.
https_status_1="$(run_client "curl $curl_timeouts -w '\nHTTP_STATUS:%{http_code}\n' --resolve $test_domain:443:$resolved_dns_ssl --cacert /ca.crt -o /shared/sbody1 -D - 'https://$test_domain$ssl_test_path'")"
grep -qi '^X-Cache-Status: MISS' <<<"$https_status_1" \
    || { echo "::error::First SSL-mode HTTPS request was not a MISS." >&2; echo "$https_status_1" >&2; exit 1; }
grep -q '^HTTP_STATUS:200$' <<<"$https_status_1" \
    || { echo "::error::First SSL-mode HTTPS request did not return HTTP 200." >&2; echo "$https_status_1" >&2; exit 1; }

https_status_2="$(run_client "curl $curl_timeouts -w '\nHTTP_STATUS:%{http_code}\n' --resolve $test_domain:443:$resolved_dns_ssl --cacert /ca.crt -o /shared/sbody2 -D - 'https://$test_domain$ssl_test_path'")"
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
