# Bug hunt: `services/proxy` (raw findings)

Part of the project-wide vacuum-first bug-hunt sweep, umbrella issue #849
(sub-issue of #843). This is a raw, unfiltered findings dump — collection
happens without self-verification or pre-filtering per the agreed
methodology (2026-07-15); verification of these findings happens in a later,
separate phase. "Already known / already in the SoT inventory" is
deliberately NOT a reason to omit a finding here.

Scope: `services/proxy/` (nginx TLS-interception + SNI-passthrough cache
proxy) read against `origin/v0.2.0`, plus its wiring in
`deploy/{dev,prod}/docker-compose.yml`, `config/{dev,prod}/proxy.env`,
`tests/bats/proxy_*.bats`, `tests/bats/known_good_snapshots_sync.bats`,
`scripts/ssl-mitm-cache-simulation.sh`, `docs/threat-model.md`,
`docs/known-good-config-snapshots.md`, `docs/install-ca-cert.md`,
`certs/generate-ca.sh`. Starting point was
`docs/capability-inventory/SoT-proxy.md` (branch `docs/inventory-proxy`);
every file it names was re-read directly, line by line, rather than trusted
from the inventory's summary.

Source of Truth companion doc:
https://github.com/wiki-mod/lancache-ng/blob/docs/inventory-proxy/docs/capability-inventory/SoT-proxy.md

---

## 1. [security] Auto-generated CA private key (`ca.key`) has no permission hardening — contradicts `certs/generate-ca.sh` and the threat model's own stated mitigation

`services/proxy/entrypoint.sh`'s first-boot CA generation:

```bash
if ! openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
    -subj "/CN=LanCache-NG CA/O=LanCache-NG/C=DE" \
    -keyout "$CA_DIR/ca.key" \
    -out    "$CA_DIR/ca.crt"; then
```

No `chmod`/`chgrp` call follows for `$CA_DIR` or `ca.key` anywhere in the
script. Compare this to the **standalone** `certs/generate-ca.sh` (the
"optional, recommended-for-prod" alternative CLAUDE.md points to):

```bash
openssl genrsa -out "$CA_KEY" 4096
openssl req -new -x509 -days 3650 -key "$CA_KEY" ... -out "$CA_CRT"
chmod 600 "$CA_KEY"
chmod 644 "$CA_CRT"
```

That script explicitly hardens `ca.key` to `600`. The in-container
auto-generation path — which is what fires for **every dev install by
default**, and for **any prod install where the operator skips the
"optional" `generate-ca.sh` step** (which CLAUDE.md literally phrases as
optional) — leaves `ca.key` at whatever OpenSSL's default `-keyout` file
mode is under the process umask. Empirically verified directly in this
session (OpenSSL 3.5.6, `umask 0022`, same `openssl req -newkey ... -keyout`
invocation pattern): the resulting private key file is created `-rw-r--r--`
(644, world-readable), not `600`. Root's default umask in the Debian
container is also 022, so the same result is expected there.

Meanwhile `entrypoint.sh` **does** carefully harden the *less* sensitive
per-domain cert directory a few lines later:

```bash
mkdir -p "$CERT_DIR"
chgrp "$worker_user" "$CERT_DIR"
chmod 2750 "$CERT_DIR"
...
find "$CERT_DIR" -type f -name '*.key' -exec chgrp "$worker_user" {} + -exec chmod 0640 {} +
```

So the codebase demonstrably knows how to lock down a cert/key directory —
it just never applies that same treatment to `$CA_DIR`/`ca.key`, the single
most sensitive secret in the whole system (whoever holds it can mint a
trusted MITM certificate for every client that installed the CA cert).

`docs/threat-model.md` T7 ("TLS impersonation of the proxy") states:

> **Residual risk**: Low — bounded by client trust of the CA and by the CA
> key staying secret (see T8/Assets).

The actual default runtime behavior does not enforce "the CA key staying
secret" at the filesystem level at all on the auto-gen path — it relies
entirely on host/bind-mount permissions the operator happens to have,
which the codebase's own security-conscious pattern for `CERT_DIR` (and the
standalone script) shows was clearly considered achievable and desirable
elsewhere, just not applied here.

**Severity assessment**: serious (security). No test in
`tests/bats/proxy_cert_generation.bats` asserts anything about `CA_DIR` or
`ca.key`'s file mode either (see finding #9).

---

## 2. `config/dev/proxy.env`'s default `PROXY_ALLOWED_CLIENT_CIDRS` is IPv4-only, silently 403ing every IPv6 LAN client by default — conflicts with the project's advertised full dual-stack IPv6 support

```bash
# config/dev/proxy.env
PROXY_ALLOWED_CLIENT_CIDRS="192.168.0.0/16 10.0.0.0/8 172.16.0.0/12"
```

`entrypoint.sh` generates the client-IP allowlist as:

```bash
echo "geo \$lancache_client_allowed {"
if [ -n "$PROXY_ALLOWED_CLIENT_CIDRS" ]; then
    echo "    default 0;"
    for cidr in $PROXY_ALLOWED_CLIENT_CIDRS; do
        printf "    %-45s 1;\n" "$cidr"
    done
else
    echo "    default 1;"
fi
```

Because the dev env file ships this variable **non-empty**, the generated
`geo` block defaults to **deny (0)** for anything not in the three listed
IPv4 ranges — there is no IPv6 range in the list at all. Both `http.conf`
and `https.conf`'s `location /` gate on `$lancache_client_allowed = 0` →
`return 403;`. Since `nginx.conf`/`https.conf`/the stream block all listen
on `[::]` as well as `0.0.0.0` (full dual-stack, per CLAUDE.md's headline
feature), a real IPv6 LAN client's `$remote_addr` will not match any of the
three IPv4 CIDRs and gets a 403 by default in the shipped dev configuration.

`prod`'s default (`config/prod/proxy.env`) ships `PROXY_ALLOWED_CLIENT_CIDRS=`
(empty → permissive `default 1`), so this specifically affects dev. The dev
file's own comment even self-acknowledges the gap without connecting it to
the IPv6 feature:

```
# Please set it, by default we limit it to IPv4 subnets
# This default works for 99%, but you should think about been more restrictive.
```

**Impact**: anyone doing local dev/testing of this project's IPv6
dual-stack behavior against the *shipped* dev defaults gets silently
403'd on the actual content-serving path, with no obvious pointer from the
403 itself back to `PROXY_ALLOWED_CLIENT_CIDRS` as the cause.

**Severity assessment**: moderate (dev-experience / feature-parity gap, not
a security bug — the restrictive default is otherwise a reasonable
security posture).

---

## 3. Per-domain SSL certs (`CERT_DIR`) have no dedicated named volume — every container recreate forces full cert regeneration, unlike the config-snapshot volume in the very same compose file

`deploy/dev/docker-compose.yml` and `deploy/prod/docker-compose.yml` both
only bind-mount the **CA** directory:

```yaml
volumes:
  - ../../certs:/etc/nginx/ssl/ca
  ...
  - proxy-config-snapshots:/var/lib/lancache-proxy   # dev only has this comment; prod has it too
```

`services/proxy/Dockerfile` declares `VOLUME ["/etc/nginx/ssl", "/var/cache/nginx/lancache"]`.
Because only the `/etc/nginx/ssl/ca` **subpath** gets an explicit
bind mount in Compose, Docker still creates an **anonymous** volume for the
rest of `/etc/nginx/ssl` (i.e. `/etc/nginx/ssl/certs`, where every
per-domain wildcard cert/key and `default.crt`/`default.key` live) at
container-create time. Anonymous volumes are not tracked/reused by name
across container recreation — only the named volumes declared in the
top-level `volumes:` section are. So a normal `docker compose down && up`,
`up --force-recreate`, or any image-update flow re-creates the proxy
container with a **fresh, empty** `/etc/nginx/ssl/certs`, forcing
`entrypoint.sh` to regenerate every single per-domain cert from scratch on
every such cycle (one `openssl req` + one `openssl x509 -req` per unique
root domain in `cdn-domains.txt`).

This is self-healing (idempotent, all still signed by the CA that *does*
persist via the real bind mount) — not data corruption — but it is a real,
repeated, avoidable cost, and the same compose file shows the team clearly
understands and applies the opposite pattern for a sibling artifact just a
few lines away:

```yaml
# Known-good nginx config snapshots (#415): must be a persistent,
# service-owned volume, not the ephemeral container layer, so
# rollback survives container restarts/recreates.
- proxy-config-snapshots:/var/lib/lancache-proxy
```

That same reasoning was never extended to `CERT_DIR`.

**Severity assessment**: moderate (startup-time/efficiency regression on
every recreate, proportional to `cdn-domains.txt` size; no correctness or
security impact by itself).

---

## 4. `scripts/ssl-mitm-cache-simulation.sh` — re-confirmed instance of the #841 silent-`set -e` pattern in the one real E2E test for this whole component

Already tracked by open issue #841 ("at least 14 instances... inside
`scripts/ssl-mitm-cache-simulation.sh`"). Re-verified directly against the
current `v0.2.0` copy rather than trusted from the issue description.
Concrete unguarded instances found by direct reading:

- `proxy_cid="$("${compose[@]}" ps -q proxy)"` (no fallback/guard) followed
  immediately by `docker cp "$proxy_cid:/etc/nginx/ssl/ca/ca.crt" ...` — if
  `ps -q proxy` ever returns empty (race, wrong project name, etc.), the
  script dies via bare `set -e` on the `docker cp` failure with only
  Docker's own raw error text, no `::error::`-annotated context line.
- All four cache-behavior curl calls (`http_status_1`, `http_status_2`,
  `https_status_1`, `https_status_2`) use plain `curl -sS ...` (no `-f`).
  `-sS` alone means an HTTP-level error status still returns exit 0 (caught
  later by the explicit `grep` assertions — that part is fine), **but** a
  hard connection failure (DNS resolution failure inside the throwaway
  client container, connection refused, TLS handshake failure before any
  HTTP status line) makes `curl` itself exit non-zero, which — because
  these assignments are plain `var="$(...)"` at top level under
  `set -euo pipefail`, not inside an `if`/`||` guard — aborts the whole
  script immediately with curl's bare exit code and none of the
  descriptive `::error::` messages that every other failure path in this
  same script deliberately has.

Given this script is documented (SoT-proxy.md) as "the only real network
E2E test" proving both standard-mode and SSL-mode caching actually work,
a connectivity blip here currently produces a much less actionable CI
failure than every other assertion in the same file.

**Severity assessment**: minor (already tracked by #841; re-confirmed still
present, with specific line-level instances for that issue if not already
enumerated there).

---

## 5. `docs/threat-model.md` T2 still names the retired `cdn-ssl-domains.txt`

```
- `PROXY_SECURITY_MODE=strict` limits proxied hosts to those in
  `cdn-ssl-domains.txt` (deny-by-default `$cdn_host_allowed` map), removing the
  "proxy anything" behaviour of the default `lazy` mode.
```

`cdn-ssl-domains.txt` was retired in the v0.2.0 refactor —
`entrypoint.sh`'s own comment documents this directly:

```bash
# Before v0.2.0, cdn-ssl-domains.txt was a SEPARATE, hand-maintained list of
# root domains for this file's wildcard cert generation, which an operator
# had to keep in sync by hand. In practice it never was...
```

Strict mode now derives roots from `services/dns/cdn-domains.txt` via the
vendored Public Suffix List (`_registrable_domain`). Confirmed via
`grep -rn "cdn-ssl-domains"` across the repo: the only two hits are this
stale doc line and the historical comment in `entrypoint.sh` explaining the
retirement. No functional impact — purely a stale doc pointing an operator
at a file that no longer exists.

**Severity assessment**: info (docs). Already flagged in SoT-proxy.md;
re-confirmed still unfixed at time of this bug-hunt.

---

## 6. `services/proxy/Dockerfile` installs nginx from the mainline apt repo with no version pin

```dockerfile
&& echo "deb http://nginx.org/packages/mainline/debian/ trixie nginx" > /etc/apt/sources.list.d/nginx.list \
&& apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    openssl \
    ...
```

No `nginx=<version>` pin. A rebuild of this image at a different point in
time can silently pick up a different nginx version — for a security- and
TLS-interception-sensitive component, this is the one major piece of the
image's supply chain left floating, in contrast to the base image being
pinned by full digest (`FROM ...debian:13-slim@sha256:...`) one line above,
and the project's broader stated preference for pinning (GitHub Actions
pinned to commit SHAs, per AGENTS.md).

**Severity assessment**: info/minor (build reproducibility, not a live
bug).

---

## 7. `Dockerfile`'s `EXPOSE 80 443` omits port 8443

```dockerfile
EXPOSE 80 443
```

`nginx.conf`'s `stream {}` block listens on `8443`/`[::]:8443`
(SNI-passthrough for standard mode), and every compose file maps
`IP_STANDARD:443 → container:8443`. `EXPOSE` is documentation/metadata only
(does not itself gate the documented Compose port mappings, which all work
correctly), but it's an inconsistent/incomplete declaration of the image's
real listening surface — e.g. `docker run -P` (publish all exposed ports)
against this image alone would never publish the standard-mode listener.

**Severity assessment**: info.

---

## 8. `mkdir -p /var/cache/nginx/tmp` in the Dockerfile is dead

```dockerfile
RUN mkdir -p \
    /etc/nginx/ssl/ca \
    /etc/nginx/ssl/certs \
    /var/cache/nginx/lancache \
    /var/cache/nginx/tmp
```

`grep -rn "cache/nginx/tmp|proxy_temp_path|client_body_temp_path"` across
`services/proxy/`, `deploy/`, `config/` returns only this one `mkdir` line.
`nginx.conf`'s `proxy_cache_path ... use_temp_path=off` keeps temp files
inside the cache path tree itself, so nothing ever writes to
`/var/cache/nginx/tmp`. Harmless leftover, but dead.

**Severity assessment**: info.

---

## 9. Test-coverage gaps found by direct reading of the bats files

- `tests/bats/proxy_known_good_snapshot.bats` only ever calls
  `_proxy_validate_snapshot_or_rollback` with a **single** candidate file
  (`$nginx_conf`). The real call site in `entrypoint.sh` always passes
  **four**: `/etc/nginx/nginx.conf /etc/nginx/proxy-params.conf
  "$SSL_MAP_FILE" "$STREAM_TARGET_FILE"`. The "incomplete snapshot" rejection
  branch inside `kgs_snapshot_apply` (a snapshot missing one of several
  requested basenames must be rejected wholesale, not partially applied) has
  no test at all for the proxy adapter against a realistic multi-file
  candidate set.
- No test exercises `CA_DIR`/`ca.key`'s file permissions (see finding #1),
  nor `CERT_DIR`'s `chmod 2750`/`0640` hardening itself — the correctly
  implemented half of that same logic is also untested.
- Confirmed (matches SoT-proxy.md's own note, re-verified by hand-tracing
  the algorithm rather than trusting the claim): `_registrable_domain` has
  no dedicated test for a compound-label public suffix (`co.uk`-style) or
  for the PSL exception-rule interplay (`!city.kawasaki.jp`-style). Hand
  trace of the algorithm for both cases looked logically correct, but that
  is inference from reading, not from an executed test — a future edit
  could regress either path silently with nothing to catch it.
- `PROXY_SECURITY_MODE=strict` and `PROXY_ALLOWED_CLIENT_CIDRS` (the 403
  code paths) still have no automated test anywhere (matches SoT).

**Severity assessment**: info (test-coverage gaps, collected per the
methodology even though several are restatements of the SoT's own findings
— the instructions are explicit that "already in the inventory" is not a
reason to omit).

---

## 10. `/nginx_status` ACL is IPv4-only (`172.16.0.0/12`) — likely moot today, flagged as a latent gap

```nginx
location = /nginx_status {
    stub_status;
    allow 172.16.0.0/12;
    deny  all;
}
```

No docker-compose network definition in this repo sets `enable_ipv6: true`
for its bridge networks (`grep -rn "enable_ipv6"` across all `deploy/*`
compose files returns nothing), so inter-container traffic (e.g. the Admin
UI scraping this endpoint via `nginx_client.rs`) stays IPv4-only today
regardless of this ACL — this is currently **not** a live bug. Flagging as
low-confidence/speculative: if IPv6-only or dual-stack container networking
is ever adopted for the internal service mesh, this ACL would need an IPv6
range added too.

**Severity assessment**: info, low confidence / speculative.

---

## 11. `/healthz` has no access control at all (both `http.conf` and `https.conf`)

```nginx
location = /healthz {
    access_log off;
    return 200 "ok\n";
    add_header Content-Type text/plain;
}
```

No `allow`/`deny`, unlike `/nginx_status`. Reachable by anyone who can route
to the proxy at all, including the public internet if a port is ever
forwarded. Low sensitivity (returns a static "ok"), but it is an
unauthenticated fingerprint/probe surface for identifying a lancache-ng
deployment from outside the LAN, and — unlike the `/ca.crt` endpoint
proposal in `docs/install-ca-cert.md`, which explicitly discusses and
accepts this exact trade-off — this one isn't discussed anywhere as an
intentional decision.

**Severity assessment**: info.

---

## 12. `docs/install-ca-cert.md`'s CA-cert distribution mechanism is explicitly unimplemented

The "Getting the `ca.crt` onto client devices" section is marked:

> **Status: proposal pending maintainer decision.** The mechanisms below are
> options with trade-offs, not all implemented yet.

So today there is no shipped, low-friction way for an operator to get
`ca.crt` onto every LAN client device besides manual copy/SSH/ad-hoc
`python3 -m http.server`. Not a code bug, but a real, still-open usability
gap in the SSL-mode onboarding flow for this component (this project's
`CLAUDE.md` "First-time Setup" section still just says "Copy `certs/ca.crt`
to clients and install it").

**Severity assessment**: info (product-completeness gap, not a code bug).

---

## 13. `resolver ipv6=on` set explicitly in the `http {}` block, left at nginx's version-dependent default in the `stream {}` block

```nginx
# nginx.conf, http {} block
resolver ${NGINX_UPSTREAM_RESOLVER} valid=300s ipv6=on;

# nginx.conf, stream {} block
resolver ${NGINX_UPSTREAM_RESOLVER} valid=300s;
```

Both share the same `NGINX_UPSTREAM_RESOLVER`. nginx's `resolver` directive
`ipv6` parameter's default flipped from `off` to `on` in 1.23.1 (2022) — the
unpinned mainline nginx install (finding #6) is currently well past that
version, so this is not observably broken today, but it is an inconsistent,
undocumented reliance on version-dependent default behavior rather than an
explicit, matching setting in both blocks. If a future rebuild ever pinned
or floated to something unexpected, standard-mode's SNI passthrough could
silently stop resolving AAAA-only CDN backends while SSL mode kept working
(or vice versa), with nothing pointing at the inconsistency as the cause.

**Severity assessment**: info, latent/version-dependent.

---

## 14. `slice` + cached 301/302 interaction is unverified

```nginx
slice                  ${CACHE_SLICE_SIZE};
proxy_cache_key        "$host$uri$slice_range";
proxy_set_header       Range $slice_range;
...
proxy_cache_valid      200 206 301 302 ${CACHE_VALID_HIT};
```

nginx's `slice` module is designed around byte-range-capable, direct
content responses; caching 301/302 redirects through the same
slice-enabled location is a known rough edge in the wider nginx community
(a redirect has no meaningful byte ranges, so what `$slice_range` means for
a request that ends up serving a redirect is not obviously well-defined).
No test in this repo (bats or the E2E simulation script) drives a
redirecting CDN response through the slice-enabled cache path, so this
specific combination's behavior is asserted by the config but not
empirically verified anywhere in this repo.

**Severity assessment**: info, unverified interaction (not confirmed
broken, flagged because no test covers it either way).

---

## 15. Upstream `Cache-Control`/`Expires` are ignored for the proxy's own caching decision but not hidden from the client

```nginx
proxy_ignore_headers   Cache-Control Expires Vary Set-Cookie;
proxy_hide_header      Set-Cookie;
proxy_hide_header      Vary;
```

`Set-Cookie` and `Vary` are both ignored *and* hidden from the client
response. `Cache-Control`/`Expires` are ignored for nginx's own cache
decision (so the proxy always caches per its own policy) but are **not**
hidden — the client still receives the origin's original
`Cache-Control`/`Expires` headers verbatim. Likely harmless in practice
(game-CDN responses are usually permissively cacheable already), but it
means a client/game-launcher that itself honors a restrictive
`Cache-Control` from the real origin could still choose not to reuse its
own local disk cache, even though the LAN proxy is transparently serving
the same bytes from its own cache underneath. Not confirmed to cause any
concrete problem, just a design asymmetry worth having on record.

**Severity assessment**: info.

---

## Cross-reference: SoT-proxy.md items independently re-confirmed, not re-derived here in full

The SoT document also already documents #841 and #842 as open cross-refs,
and the "known-good-snapshot fallback has no external alerting" operational
risk in `docs/known-good-config-snapshots.md`. Re-read directly during this
sweep and found accurate/still current as described; not repeated verbatim
above to avoid pure duplication, but they are part of this bug-hunt's
collected scope and should be considered "re-confirmed, not newly found" if
this file is used as an input to the later verification phase.
