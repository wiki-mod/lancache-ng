# Capability inventory: `services/proxy` (Source of Truth / working notes)

Part of the project-wide capability inventory audit (umbrella issue #843).
This file is the personal safety-net / working copy for the `services/proxy`
component, committed incrementally on branch `docs/inventory-proxy` so no
research is lost if the session is interrupted. The authoritative, English
public log entry for this component is posted as a comment on issue #843:
https://github.com/wiki-mod/lancache-ng/issues/843#issuecomment-4977019630

Status: **research complete, comment posted**. This file mirrors that
comment's content (plus the same source citations) so it survives
independently of GitHub availability.

Scope: `services/proxy/` (nginx TLS-interception + SNI-passthrough cache
proxy), plus its wiring in `deploy/*/docker-compose.yml`, `config/{dev,prod}/proxy.env`,
and its test coverage. Read against **`origin/v0.2.0`** (this branch's own
base), since that is materially different (and considerably more
feature-complete) than what's on `master`/other integration branches at the
time of this audit — see "Branch divergence" at the end.

> **Currency check (2026-07-18):** re-verified against `origin/v0.2.0` @
> `dc8d79c6` (68 commits merged since this doc's `3f53ac3b` base). One
> clarification below (`PROXY_ALLOWED_CLIENT_CIDRS` enforcement scope) was
> sharpened after the sibling `bughunt-proxy` pass (issue #849) found the
> allowlist does not cover the standard-mode stream listener. Everything
> else in this doc remains accurate; no merged commit in that range touches
> `services/proxy`'s code paths.
>
> **Review-triage update (2026-07-18, round 1):** four PR-review findings
> were verified against current code and fixed here: the full-setup
> bind-mount claim (§3), dev's distinct port mapping (§5), the
> `PROXY_SECURITY_MODE=strict` 403 scope (§4), and the stale
> `cdn-ssl-domains.txt` threat-model reference (§7 — `docs/threat-model.md`
> itself was corrected, not just flagged).
>
> **Review-triage update (2026-07-18, round 2 — after Codex re-reviewed the
> round-1 push):** five more findings verified and fixed: strict-mode
> stream's target-selection gap, forwarding to the derived root rather than
> the literal SNI (§1); the rollback adapter's overstated "fully
> unit-tested" claim, missing both the degraded-domain-skip branch and the
> real 4-file candidate set (§1); strict mode's wildcard-root allowlist
> scope, which admits any subdomain of a derived root, not just the literal
> `cdn-domains.txt` entries (§4); and two more unscoped
> `PROXY_ALLOWED_CLIENT_CIDRS`/domain-allowlist claims plus a second stale
> `services/proxy-standard` reference in `docs/threat-model.md`'s
> architecture summary, T9, and T11 (§7). This file is now ahead of the
> mirrored public comment on issue #843
> (https://github.com/wiki-mod/lancache-ng/issues/843#issuecomment-4977019630);
> that comment has not been separately updated to match.

---

## 1. Startup / `entrypoint.sh` — function-by-function

| Function / block | Purpose | Test coverage |
|---|---|---|
| Env-var validation (`IP_STANDARD` required, `SSL_ENABLED`, `NGINX_UPSTREAM_RESOLVER` default incl. bracketed IPv6, `PROXY_SECURITY_MODE`, `PROXY_ALLOWED_CLIENT_CIDRS`, `KEEP_KNOWN_GOOD_CONFIGS`, `PROXY_CONFIG_SNAPSHOT_DIR`) | Fail closed on missing/bad config | Not unit-tested directly; exercised implicitly by every compose-based simulation job |
| Known-good-snapshot library (`kgs_log`, `kgs_new_snapshot_id`, `kgs_list_snapshots`, `kgs_snapshot_create`, `kgs_snapshot_prune`, `kgs_snapshot_apply`) — embedded byte-identical copy of `scripts/lib/known-good-snapshots.sh` (#415) | Generic validate→snapshot→rollback contract shared with dhcp-proxy/dns adapters | `tests/bats/known_good_snapshots_sync.bats` (drift guard: fails if this embedded copy ever diverges from the canonical file or from the dhcp-proxy/dns copies) |
| `_normalize_resolver_token` + loop-guard over `NGINX_UPSTREAM_RESOLVER` | Refuses to start if the configured upstream resolver is the LAN cache's own DNS IP (would infinite-loop CDN name resolution back into itself) | Not directly unit-tested; would surface as an immediate container-exit if broken |
| `_is_valid_domain_label` / `_normalize_domain` / `_is_valid_domain` | RFC 1035 domain validation (label ≤63, no leading/trailing hyphen, ≤253 total, ≥2 labels, lowercased/trimmed/leading-dot-stripped) — mirrors the Admin UI's Rust validator (`domains.rs`) | **Fully unit-tested**: `tests/bats/proxy_cert_generation.bats` (valid/invalid labels, hyphen edge cases, 63/253-char boundaries, normalization) |
| Public-suffix-aware root domain derivation (`_load_public_suffix_list`, `_suffix_from_end`, `_registrable_domain`, vendored `public_suffix_list.dat`, ICANN-section only) | Replaces the old hand-maintained `cdn-ssl-domains.txt` (retired in v0.2.0) — derives the correct wildcard-cert root for every `services/dns/cdn-domains.txt` entry via the real Mozilla PSL instead of a naive "last two labels" guess (fixes a real prior bug: `drivers.amd.com` had no cert because the hand-picked root was `downloads.amd.com`, not `amd.com`) | `tests/bats/proxy_registrable_domain.bats` (9 cases) directly drives `_registrable_domain` against the real vendored PSL, covering a compound-label public suffix (`co.uk`), the bare-suffix rejection case, PSL exception-rule precedence over the wildcard rule it carves out of (`kawasaki.jp`/`!city.kawasaki.jp`), and a plain single-label suffix (`.com`) baseline; also indirectly proven by `scripts/tracked/simulations/ssl-mitm-cache-simulation.sh` succeeding against `deb.debian.org` |
| `_collect_domain_rows` (dedup by derived root, tracks `_DOMAIN_ROWS_SKIPPED`) | Single read of the domain file → `_UNIQUE_DOMAINS` + `_DOMAIN_IS_ROOT`; skips invalid/unresolvable rows without failing the whole config, but flags the run as "degraded" | Used by the known-good-snapshot gate below — a config generated from a degraded domain list is **not** snapshotted as known-good (would prune a possibly-complete prior snapshot) |
| CA generation (first boot only, 4096-bit, 10y) + one-time operator banner | Self-signed root CA the operator installs once (`docs/install-ca-cert.md`) | `tests/bats/proxy_cert_dir_permissions.bats` drives the real `_ensure_ca_cert` function, checks generation and idempotence, and uses an insecure-key stub to prove the explicit `chmod 600` hardening; `scripts/tracked/simulations/ssl-mitm-cache-simulation.sh` also exercises generation end to end in a container |
| `_sign_cert` (2048-bit per-domain cert, CSR via `/tmp/lancache-cert.csr`, cleans up key **and** partial crt on signing failure, not just the CSR — fix for #655) | Issues one wildcard cert per derived root domain, plus (issue #1272) one additional cert for some entries a root-level wildcard SAN can't cover — the threshold differs by entry shape: a leading-dot wildcard-only entry needs its own deeper cert whenever it differs from the root at all (even by exactly one label, since its matched hosts are always one label deeper than the entry text itself); a bare exact-host entry needs its own cert only once it is *more than one* label past the root (exactly one label past root is already covered by the root's own `*.<root>` wildcard). Subject CN is always a fixed placeholder (`lancache-ng`), never the real hostname, since OpenSSL's default CN policy caps it at 64 bytes — well under the 253-byte domains this file allows; the real hostname lives only in the SAN. Deeper-entry cert/key filenames are a namespaced SHA-256 hash of the hostname (`_bounded_cert_name`), not the hostname itself, to stay under Linux's 255-byte filename limit. | **Fully unit-tested**: cert creation, correct CN, chain-of-trust via `openssl verify`, correct wildcard+bare SAN, 3650-day validity window, monotonic serial counter, serial-file survival across many signings, orphaned-CSR/key/crt cleanup on both the CSR-step and the sign-step failure paths, plus `tests/bats/proxy_sign_cert.bats` (real openssl CA, not stubbed) for the #1272 CN/filename-length paths. **Real end-to-end TLS-handshake coverage**: `scripts/tracked/simulations/proxy-deep-wildcard-tls-simulation.sh` (wired into `full-setup-sims.yml`'s `proxy-deep-wildcard-tls-simulation` job) builds a real proxy image against a synthetic `example.com`-rooted fixture, starts real nginx, and performs real `openssl s_client -verify_hostname` handshakes proving the depth-1 leading-dot path validates cleanly, the stream-target map forwards to the requested SNI (not the wildcard base), and the deep cert's CN is the fixed placeholder — a committed, repeatable CI check, not the one-off manual verification an earlier revision of this row claimed. **Former known limitation, connectivity gap closed 2026-08-05 (issue #1276/#1322, see the new "SSL-mode stream-level SNI depth-dispatch" row below):** a leading-dot entry's wildcard SAN only ever covers exactly one label of depth (RFC 6125); an SNI two or more labels below the entry (e.g. `a.b.cdn.ea.com` under a `.cdn.ea.com` entry) still cannot get a cert that validates for it. What changed: such a client no longer reaches this cert-selection path with a mismatched cert and fails outright -- the new stream-level dispatcher (see below) routes it to a passthrough relay instead, so the connection succeeds. What did NOT change: that depth still isn't cached or MITM'd -- only dynamic per-SNI certificate issuance at handshake time (a different architecture than this pre-generated-wildcard-cert design, see `AGENTS.md`'s `AG-KD-005` -- corrected 2026-08-05, issue #1391 doc-sweep audit: this used to cite `CLAUDE.md`'s "Pre-generated wildcard certs" decision, which moved to `AGENTS.md` on 2026-07-31) would close that residual gap, and that remains a separate, not-yet-scoped architecture question. The documented per-level mitigation (listing the specific deeper level as its own `cdn-domains.txt` entry, e.g. `.b.cdn.ea.com`, to get real MITM/caching for that one additional level) still works exactly as before and still does not generalize to unbounded depth. |
| `_default_cert_needs_regen` (anchored IP-SAN match, fix for #655) | Regenerates the fallback `default.crt` if missing, key-less, SAN-less (old CN-only certs), or if `IP_SSL` changed — previously used an **unanchored substring match** that would keep serving a stale cert if the new IP was a textual prefix of the old one (e.g. `192.168.1.11`→`192.168.1.1`) | **Fully unit-tested**, including the exact prefix-collision regression case |
| Request-policy map generation → `00-ssl-map.conf` | `map $ssl_server_name $ssl_cert_name` (per-root wildcard + bare-domain cert selection), `map $host $cdn_host_allowed` (lazy=allow-all vs strict=allowlist-only, derived from the same PSL-rooted domain list), `geo $lancache_client_allowed` (source-IP CIDR allowlist) | `tests/bats/proxy_ssl_map_generation.bats` (8 cases) drives the real `_render_ssl_map()` and isolates the generated map syntax directly: lazy/strict defaults and allowlist entries for `$cdn_host_allowed`, default/allow entries for `$lancache_client_allowed`, and that the two axes combine independently when both are configured together; also indirectly proven by `ssl-mitm-cache-simulation.sh` |
| Stream-target map generation → `stream.d/00-stream-targets.conf` | `map $ssl_preread_server_name $stream_backend` for SNI passthrough — lazy mode forwards blind to whatever SNI the client sent, strict mode only forwards to domains in the allowlist (else routes to a closed `127.0.0.1:9`). **Registrable-root target-selection gap, FIXED (issue #1297, folded into #1276):** for a matched registrable root, `entrypoint.sh` used to forward to `${domain}:443` — the *derived root* domain — instead of the literal `$ssl_preread_server_name` the client requested. E.g. a listed `drivers.amd.com` (PSL root `amd.com`) forwarded to `amd.com:443`, not `drivers.amd.com:443`, which could break strict-mode standard-mode traffic for any listed subdomain whose real origin doesn't serve that traffic from the root domain's IP. This was the same bug class already fixed for the deeper leading-dot wildcard base (issue #1272) in PR #1277; the `_UNIQUE_DOMAINS` loop's own, older instance of it is now fixed the same way — every branch of this map (registrable-root wildcard, registrable-root exact, deeper wildcard base, deeper exact host) now forwards to `$ssl_preread_server_name:443`, never a hardcoded derived-domain literal. | Real-handshake-verified for both cases: the #1272 wildcard-base case via `scripts/tracked/simulations/proxy-deep-wildcard-tls-simulation.sh`; the #1297 registrable-root case via `scripts/tracked/simulations/proxy-standard-mode-sni-routing-simulation.sh` (two distinct-cert backends reachable only via their own hostnames on a throwaway Docker network, a real proxy container in `strict` mode, and a real `openssl s_client` handshake through the standard-mode stream listener proving the *correct* backend's certificate comes back for a one-label-past-root SNI — plus a recorded negative-control run against the pre-fix code showing the same assertion fails as expected) |
| `https.conf` removal when `SSL_ENABLED=0` | Standard-mode-only installs never load the interception server block | Not unit-tested; would surface as a missing 443 SSL listener if broken |
| SSL-mode stream-level SNI depth-dispatch → `stream.d/01-ssl-dispatch.conf` (issue #1276/#1322, added 2026-08-05; only generated when `SSL_ENABLED=1`) | A stream-level `server` on the public `443` reads the SNI via `ssl_preread` (before any TLS termination) and routes to one of two internal-only relays via a regex-anchored `map` (NOT nginx's "hostnames" mode, which matches *any* depth for a `*.base` key and would silently reproduce the #1322 bug — confirmed live against this project's own real `$ssl_cert_name` map): a SNI exactly one label below a covered base (a derived root, an `_EXTRA_WILDCARD_BASES` entry, or an `_EXTRA_EXACT_HOSTS` exact host) routes to the MITM relay (`127.0.0.1:9445`); one two or more labels below a leading-dot base routes to the passthrough relay (`127.0.0.1:9446`) instead of a mismatched cert. Mirrors `_UNIQUE_DOMAINS`/`_DOMAIN_IS_ROOT`/`_EXTRA_WILDCARD_BASES`/`_EXTRA_EXACT_HOSTS`/`_ROOT_HAS_WILDCARD_ENTRY` (the same coverage the SSL-map generation above already computes) rather than re-deriving it, so the two can never drift apart. A symmetric two-relay design (not one relay for only the MITM branch) is required for `proxy_protocol` (used to preserve the real client IP across this stream-level hop) to apply correctly: it's a per-stream-server-block setting, not per-destination, so a single relay handling both branches would either corrupt the passthrough branch's raw bytes to a real external origin (if enabled) or lose the real client IP for the MITM branch (if not) — confirmed live during this fix's own development that a single-relay version does not work. The MITM relay forwards (with `proxy_protocol on`) to `conf.d/https.conf`'s real HTTPS server, now moved to an internal-only `127.0.0.1:8444` (see below); the passthrough relay re-reads the SNI and blind-forwards to `$ssl_preread_server_name:443`, structurally untouched by any of this. `_ROOT_HAS_WILDCARD_ENTRY` (new in `entrypoint.sh`, alongside the existing four coverage arrays) tracks whether a *root* domain is itself a leading-dot entry (e.g. `.steamcontent.com`) — a case the existing `_EXTRA_WILDCARD_BASES` array does not cover (a root-level entry needs no extra cert, but does have the same arbitrary-DNS-depth-vs-one-label-of-cert gap one level further down). | **Real end-to-end coverage**: `scripts/tracked/simulations/proxy-ssl-mode-two-relay-dispatch-simulation.sh` (wired into `full-setup-sims.yml`) — real depth-1 MITM handshake against the generated cert, real depth-2 passthrough handshake reaching a distinct real backend, and real client-IP preservation from two fixed-IP clients. The allowed client receives a non-403 HTTP result and appears as `$remote_addr` in the HTTP access log; the denied client is rejected by the outer stream ACL before TLS/HTTP, returns curl status `000`, and is absent from that HTTP log. The dedicated non-PROXY-protocol healthcheck port (`8445`) also works while the PROXY-protocol-only internal port (`8444`) correctly rejects a plain connection. This script does not rebuild a pre-fix image from git history as a live negative control; the durable checks exercise the current routing and denial behavior directly. `tests/bats/proxy_collect_domain_rows.bats` covers `_ROOT_HAS_WILDCARD_ENTRY`'s tracking logic in isolation. |
| Template rendering (`envsubst` for `nginx.conf`, `proxy-params.conf`) | Cache size/mem/slice/inactive/valid + upstream resolver substitution | Covered by `tests/bats/proxy_known_good_snapshot.bats`'s stub-nginx flow (validates the *rendered* file, not the substitution itself) |
| `_proxy_validate_snapshot_or_rollback` (#415) | `nginx -t` → snapshot on success (skipped if domain rows were skipped) → on failure, roll back newest-to-oldest through stored snapshots, re-validating each; fatal exit if nothing validates | `tests/bats/proxy_known_good_snapshot.bats` covers valid-config snapshot creation, invalid-config rollback, exhausted-snapshot refusal, retention pruning, and the candidate-set migration. The real five-file set is `nginx.conf`, `proxy-params.conf`, the SSL map, the stream-target map, and `00-stream-client-acl.conf`; migration backfills an empty ACL only when the saved `nginx.conf` predates the ACL include, while a current-schema snapshot missing that file remains invalid. The main validation cases still use a reduced fixture rather than all five real candidates, and no test sets `_DOMAIN_ROWS_SKIPPED=1` to exercise the degraded-domain-list skip-snapshot branch. |

## 2. nginx configuration surface

- **`conf.d/http.conf`** (port 80, always loaded): `/healthz` (ACL'd to
  `127.0.0.1/32`/`172.16.0.0/12` — denied sources get 403; allowed sources
  get 200 served from a generated alias file, no access log),
  `/nginx_status` (`stub_status`, ACL'd to `172.16.0.0/12` — the
  Docker bridge range; consumed by the Admin UI's `nginx_client.rs` for live
  stats), and the main `location /` gated by `$lancache_client_allowed` then
  `$cdn_host_allowed` before `proxy_pass https://$host$request_uri`.
- **`conf.d/https.conf`** (internal-only `127.0.0.1:8444`, plus a second,
  non-PROXY-protocol `127.0.0.1:8445` listener for the Compose healthcheck
  only — both only present when `SSL_ENABLED=1`, entrypoint deletes the
  file otherwise): same gating + dynamic per-SNI cert selection via
  `$ssl_cert_name`, TLS 1.2/1.3 only, `HIGH:!aNULL:!MD5` ciphers, 1-day
  session cache. **Since #1276/#1322 (2026-08-05): no longer listens on the
  public 443 directly** — see the stream-level SNI depth-dispatch row above
  and `nginx.conf`'s bullet below. `set_real_ip_from 127.0.0.1` /
  `real_ip_header proxy_protocol` trust the PROXY protocol header the
  internal MITM relay attaches, so `$remote_addr` (and therefore
  `$lancache_client_allowed`/access logging) still reflects the real client,
  not the relay's own loopback address. The `8445` listener has no
  PROXY-protocol requirement and is loopback-only by design — it only serves
  `/healthz`, gated by the same `127.0.0.1/32`/`172.16.0.0/12` ACL as
  `http.conf`'s copy (denied sources get 403; allowed sources get 200 from
  the same generated alias file, no upstream/cache access either way).
- **`nginx.conf`**: shared `proxy_cache_path` (one cache zone, `lancache`,
  for both HTTP and HTTPS legs — same cache key space), upstream `resolver`
  (must be real public/upstream DNS, never the LAN cache's own DNS —
  enforced by the loop-guard above), and the `stream {}` block on `:8443`
  (`ssl_preread on` → `$stream_backend`) that implements standard-mode's
  blind SNI passthrough, unaffected by the SSL-mode changes below. Docker's
  own port mapping (`IP_STANDARD:443→container:8443`,
  `IP_SSL:443→container:443`) still routes standard-mode clients to `:8443`
  and SSL-mode clients to `:443` exactly as before — but since #1276/#1322,
  container `:443` is no longer `conf.d/https.conf` directly: it's now
  `stream.d/01-ssl-dispatch.conf`'s entrypoint-generated stream-level SNI
  dispatcher (see the capability row above), which forwards to
  `conf.d/https.conf`'s new internal-only listener via one of two internal
  relays depending on requested-SNI depth. No Compose port-mapping change
  was needed — only what container `:443` itself now is changed.
- **`proxy-params.conf`** (shared by both server blocks): `slice`-based
  range caching, cache key `$host$uri$slice_range`, `proxy_cache_lock`
  (single-fetch-per-miss, 2h lock timeout for big files), `proxy_cache_valid`
  split between hit codes and everything else, deliberate
  `proxy_ignore_headers`/`proxy_hide_header` on
  `Cache-Control`/`Expires`/`Vary`/`Set-Cookie` (so upstream cache directives
  never override the "always cache game files" policy), real upstream TLS
  verification (`proxy_ssl_verify on`, depth 2, container's own CA bundle)
  even though the client-facing side is doing MITM, 50 GB temp-file
  ceiling, and the `X-Cache-Status`/`X-Served-By` response headers.

## 3. Docker image / build

- `Dockerfile` installs nginx from the **nginx.org mainline repo** (not
  Debian's own package). nginx.org's own package compiles the stream
  module in statically (confirmed via `nginx -V`:
  `--with-stream --with-stream_ssl_preread_module` etc.) — unlike Debian's
  own nginx package, which splits it into a separate `libnginx-mod-stream`
  package requiring a `load_module` directive. Neither a separate package
  nor `load_module` exists in this image or `nginx.conf`. (Corrected
  2026-07-30 — this line previously gave the opposite, incorrect reason.)
- Uses a **named additional build context** (`dns-domains` →
  `services/dns/`) to bake a **build-time snapshot** of `cdn-domains.txt`
  into the image as a fallback for deployments with no live bind-mount.
  dev/prod shadow this with a live bind-mount of the real file
  (`services/dns/cdn-domains.txt` → `/etc/nginx/cdn-domains.txt`) at
  container start. **`deploy/quickstart` and `deploy/full-setup` do not**
  (corrected 2026-07-18) — quickstart pulls a published image with no local
  repo checkout to bind-mount from, and full-setup's `proxy` service only
  mounts `proxy-cache:/var/cache/nginx/lancache` (no domain-list mount at
  all), so both fall back to the image-baked snapshot for the domain list.
  Anyone using full-setup's SSL-MITM harness to exercise a local
  `cdn-domains.txt` edit is actually exercising the image-baked snapshot,
  not the live file.
- `public_suffix_list.dat` (vendored, MPL-2.0) is baked in as static,
  non-user-editable data — not runtime-managed, not part of the
  known-good-snapshot mechanism.

## 4. Environment variables (behavior-controlling)

| Var | Where set | Effect |
|---|---|---|
| `IP_STANDARD`, `IP_SSL`, `SSL_ENABLED` | compose `environment:` | Mode selection, cert IP SAN, required-var gating |
| `CACHE_MAX_SIZE`, `CACHE_MEM_MB`, `CACHE_SLICE_SIZE`, `CACHE_VALID_HIT`, `CACHE_VALID_ANY`, `CACHE_INACTIVE` | `config/{dev,prod}/proxy.env` | Cache sizing/retention tuning, templated into `nginx.conf`/`proxy-params.conf` |
| `NGINX_UPSTREAM_RESOLVER` | `config/{dev,prod}/proxy.env` | Real upstream DNS for origin lookups (dual-stack default incl. bracketed IPv6 Google DNS) |
| `PROXY_SECURITY_MODE` (`lazy`\|`strict`) | `config/{dev,prod}/proxy.env` | `lazy` (default): proxy any host that reaches the cache. `strict`: for the `http{}`/`https{}` `location /` blocks, returns HTTP 403 for any host not derived from `cdn-domains.txt` (`$cdn_host_allowed`, `conf.d/http.conf`/`https.conf`). **Scope gap (confirmed 2026-07-18):** the standard-mode `stream{}` SNI-passthrough listener (`:8443`) enforces the same domain list differently — `entrypoint.sh` routes an unlisted SNI to a closed `127.0.0.1:9`, producing a failed/refused TCP connection, never an HTTP 403. Do not assume a 403 for strict-mode denials on the standard-mode listener. **Wildcard-root allowlist (confirmed 2026-07-18):** "not derived from `cdn-domains.txt`" is broader than the literal listed hostnames — for every derived root, `entrypoint.sh` emits both the bare root and `*.${root}` into the allow map (`conf.d/00-ssl-map.conf`'s `$cdn_host_allowed` and the stream target map alike), so a listed `drivers.amd.com` (PSL root `amd.com`) admits *any* `*.amd.com` host, and since the PSL derivation is ICANN-section-only, a listed CDN hostname under a broad platform root (e.g. `*.akamaized.net`) admits that entire platform root too. Strict mode allowlists by *derived root*, not by the exact hostnames in `cdn-domains.txt`. |
| `PROXY_ALLOWED_CLIENT_CIDRS` | `config/{dev,prod}/proxy.env` | Source-IP allowlist. For HTTP/HTTPS traffic: `geo $lancache_client_allowed` block, checked in `conf.d/http.conf`/`https.conf` (both `http{}` context); empty = allow all reachable clients. **Stream-level scope gap, FIXED (proxy-stream-sni-hardening):** ~~the `geo` variable is only checked in the `http{}` context — the standard-mode SNI-passthrough `stream{}` listener (`:8443`) never references it, so this allowlist is not enforced for standard-mode clients regardless of configuration~~. `$lancache_client_allowed`'s geo variable is still http-context-only and structurally unusable from `stream{}` (a geo variable cannot cross that context boundary), so the fix instead uses `ngx_stream_access_module`'s plain `allow`/`deny` directives, generated into `stream.d/access.d/00-stream-client-acl.conf` and `include`d by both the standard-mode `:8443` listener and the SSL-mode `:443` stream-level SNI dispatcher (see the stream-level SNI depth-dispatch row above) — a TCP-level accept/reject checked before `ssl_preread` even runs, so a denied client's connection is refused/reset outright rather than answered with an HTTP 403. Real-verified live (`scripts/tracked/simulations/proxy-ssl-mode-two-relay-dispatch-simulation.sh`) with two fixed-IP clients, one inside and one outside the configured CIDR. **Since #1276/#1322 (2026-08-05):** SSL-mode enforcement of this variable also depends on the two-relay chain correctly preserving the real client IP across the stream-level hop into `conf.d/https.conf`'s now-internal listener, for the *allowed* client's traffic once it passes the stream-level ACL above. |
| `KEEP_KNOWN_GOOD_CONFIGS` (default 3) | `config/{dev,prod}/proxy.env` | Snapshot retention depth for #415 rollback |
| `PROXY_CONFIG_SNAPSHOT_DIR` | entrypoint default (`/var/lib/lancache-proxy/config-snapshots`), volume `proxy-config-snapshots` per `docs/known-good-config-snapshots.md` | Where rollback snapshots persist across container recreation |

## 5. Docker Compose wiring across environments

- **prod/quickstart**: identical port-mapping trick —
  `IP_STANDARD:443→container:8443` (stream/SNI-passthrough),
  `IP_SSL:443→container:443` (interception), HTTP on host port 80 for both
  IPs.
- **dev** (corrected 2026-07-18 — this is *not* identical to prod/quickstart):
  same *container*-side ports, different *host*-side ports to dodge
  conflicts on a dev workstation — `IP_STANDARD:8080→container:80` (HTTP,
  not port 80) and `IP_STANDARD:8443→container:8443` (stream/SNI-passthrough,
  not `443→8443`); `IP_SSL:80→container:80` / `IP_SSL:443→container:443`
  match prod. Anyone reproducing standard-mode port-routing against a dev
  stack must target `8443`, not `443`.

  Healthcheck always checks `http://127.0.0.1/healthz`, and additionally
  `https://127.0.0.1/healthz` only when `SSL_ENABLED=1` — same script across
  dev/prod/quickstart.
- **`deploy/full-setup/`** (validation-only harness, not production):
  reproduces the same dual-listener architecture on a single bridge network
  via a `standard-passthrough-shim` (profile-gated `alpine`+`socat`
  container forwarding `:443`→`proxy:8443`) — added specifically to close
  **issue #668** (previously `dns-standard` and `dns-ssl` resolved to the
  *same* reachable address, so nothing proved SSL-mode genuinely lands on a
  distinct, MITM-capable endpoint). `dns-standard`'s `PROXY_IP` in this
  harness points at the shim, not at the proxy container directly.
- Cache volume is intentionally **one shared volume** across HTTP and HTTPS
  legs everywhere (dev/prod/quickstart) — matches the cache-key design
  (`$host$uri`, mode-agnostic).

## 6. Test coverage matrix

| Test | What it actually proves |
|---|---|
| `tests/bats/proxy_cert_generation.bats` | Domain validation, cert generation (CN/SAN/chain/validity), serial monotonicity, cleanup-on-failure regressions for #655 — all against the real extracted shell functions, not a reimplementation |
| `tests/bats/proxy_known_good_snapshot.bats` | The `_proxy_validate_snapshot_or_rollback` adapter end-to-end against a stubbed `nginx -t`, including retention pruning |
| `tests/bats/known_good_snapshots_sync.bats` | Drift guard: proxy's embedded snapshot-library copy stays byte-identical to the canonical `scripts/lib/known-good-snapshots.sh` and to the dhcp-proxy/dns copies |
| `scripts/tracked/simulations/ssl-mitm-cache-simulation.sh` (CI job `ssl-mitm-cache-simulation` in `full-setup-validate.yml`) | The only **real network E2E** test: brings up the actual published proxy/dns-standard/dns-ssl/nats images, resolves a real cacheable domain (`deb.debian.org`, chosen because game-CDN domains need signed URLs), and proves both HTTP caching (standard mode) and HTTPS MITM caching (SSL mode) work against a genuinely fetchable target — including proving (via the shim above) that the two modes land on distinct endpoints |
| `scripts/tracked/simulations/ui-reachability-crash-loop-simulation.sh` (job `ui-reachability-crash-loop-simulation`) | Not a proxy test per se, but deliberately crash-loops the **`proxy`** container to prove the Admin UI (a real `depends_on`) still starts and stays reachable (#763) — worth knowing proxy is the subject of another service's resilience test |

**Not tested at all / no dedicated coverage found:**
- `00-stream-targets.conf` map *syntax* in isolation (only proven indirectly
  via the one E2E script reaching `nginx -t`/actual traffic) — `00-ssl-map.conf`'s
  own map syntax is now covered directly by `tests/bats/proxy_ssl_map_generation.bats`
  (see §1's "Request-policy map generation" row above).
- `PROXY_SECURITY_MODE=strict` and `PROXY_ALLOWED_CLIENT_CIDRS` (403 paths)
  have no automated test — no simulation script or bats test drives a
  request through the `http{}`/`https{}` strict/CIDR-denied code paths and
  asserts a 403. **Partially closed (proxy-stream-sni-hardening):** the
  stream-level `PROXY_ALLOWED_CLIENT_CIDRS` enforcement added for the
  `:8443`/`:443` stream listeners (see §4's `PROXY_ALLOWED_CLIENT_CIDRS`
  row) is real-verified by `scripts/tracked/simulations/proxy-ssl-mode-two-relay-dispatch-simulation.sh`
  with two fixed-IP clients, one inside and one outside the configured
  CIDR — this closes the "missing code path" half of the original gap
  description for the SSL-mode dispatcher specifically; the plain HTTP/HTTPS
  403 path above, and the standard-mode `:8443` listener's own stream-level
  ACL, still have no dedicated automated coverage of their own.
- `/nginx_status`'s ACL and the Admin UI's consumption of it
  (`nginx_client.rs`) have no test found on either side.

## 7. Cross-referenced open issues / known gaps

- **#841** (open, CI reliability): confirms **at least 14 instances** of a
  silent-`set -e`-under-`set -euo pipefail` bug pattern specifically
  **inside `scripts/tracked/simulations/ssl-mitm-cache-simulation.sh`** — the one real E2E proof
  for this whole component. A failure partway through that script's ~14
  unguarded command-substitution assignments can currently produce a bare
  "exit code 1" with zero diagnostic output.
- **#842** (open, v0.3.0): `watchdog` *does* monitor `proxy` (one of only
  three containers it covers), but the issue is a useful adjacent
  cross-reference — no auto-restart/health story exists for
  `nats`/`ui`/`dhcp` even though the proxy container's own
  known-good-snapshot rollback (#415) has no equivalent external alerting
  either (see next point).
- **Documented-but-unresolved operational risk**
  (`docs/known-good-config-snapshots.md`, "Operational risk to know about"
  for nginx): if the automatic rollback path is ever taken, nginx keeps
  serving a **stale** known-good config indefinitely on every restart until
  the underlying bad input (`cdn-domains.txt` edit, `PROXY_SECURITY_MODE`,
  template/env change) is fixed by an operator — the only signal is a
  `WARNING`/`ERROR` log line, no separate health/status indicator, no open
  issue found specifically tracking "surface known-good-snapshot fallback
  state to the Admin UI or watchdog."
- **Stale doc cross-reference — fixed in this PR (2026-07-18)**:
  `docs/threat-model.md`'s "T2: LAN client poisons the cache" mitigation
  named `cdn-ssl-domains.txt` as what `PROXY_SECURITY_MODE=strict`
  restricts to. That file was **retired in the v0.2.0 refactor**
  (`entrypoint.sh`'s own comment: *"Before v0.2.0, cdn-ssl-domains.txt was a
  SEPARATE, hand-maintained list... it never was [kept in sync]... missing
  root coverage for at least one real DNS-listed domain"*) — strict mode now
  derives roots from `services/dns/cdn-domains.txt` via the vendored Public
  Suffix List. Per AG-DOC-001 (documentation drift is a defect, not
  follow-up work), `docs/threat-model.md`'s T2 section was updated in this
  PR to name `cdn-domains.txt` and the PSL-derivation mechanism instead of
  recording the mismatch only here. A second review pass (2026-07-18) found
  the same class of unscoped `PROXY_ALLOWED_CLIENT_CIDRS`/strict-mode claim
  repeated in `docs/threat-model.md`'s architecture summary and T9, plus a
  second stale `services/proxy-standard` reference in T11 — all three were
  fixed in the same commit as this update, so the two documents (this
  inventory's §4 scope notes and `docs/threat-model.md`'s T2/T9/architecture
  sections) no longer contradict each other anywhere.
- **Closed but worth citing for history**: #668 (ssl-mitm-cache-simulation
  couldn't prove SSL-mode reaches a distinct MITM endpoint — fixed via the
  `standard-passthrough-shim`) and #655 (the two
  `_sign_cert`/`_default_cert_needs_regen` bugs now covered by regression
  tests above) — both already resolved, listed here only because their
  fixes are load-bearing parts of the current entrypoint logic described
  above.

## Branch divergence (flagging, not fixing)

The `services/proxy` component on `origin/v0.2.0` is **substantially more
advanced** than what's checked out on other active branches at the time of
this audit: the domain-validation functions, PSL-based root derivation, the
entire known-good-snapshot/rollback mechanism (#415), and the
`standard-passthrough-shim` validation harness (#668) do not exist outside
`v0.2.0`. `cdn-ssl-domains.txt` still exists as a real, separately-maintained
file on those other branches. Anyone comparing this inventory against a
different checkout should expect it to look like an older component.

---

## Sources consulted (paths, all read from `origin/v0.2.0` unless noted)

- `services/proxy/entrypoint.sh`, `nginx.conf`, `proxy-params.conf`,
  `conf.d/http.conf`, `conf.d/https.conf`, `Dockerfile`,
  `public_suffix_list.dat` (presence/purpose only, not full content)
- `deploy/prod/docker-compose.yml`,
  `deploy/quickstart/docker-compose.yml`, `deploy/full-setup/docker-compose.yml`,
  `deploy/full-setup/Dockerfile`, `deploy/secondary/docker-compose.yml`
- `config/prod/proxy.env`
- `tests/bats/proxy_cert_generation.bats`, `tests/bats/proxy_known_good_snapshot.bats`,
  `tests/bats/known_good_snapshots_sync.bats`
- `scripts/tracked/simulations/ssl-mitm-cache-simulation.sh` (header/body read in full)
- `docs/known-good-config-snapshots.md` (read in full), `docs/threat-model.md`
  (T2 section), `docs/install-ca-cert.md` (referenced, not fully re-read)
- `.github/workflows/full-setup-validate.yml` (grepped for proxy/ssl-mitm job
  wiring, not read in full)
- `gh issue list` / `gh issue view` against `wiki-mod/lancache-ng` for open
  issues #841, #842, and closed #668, #655
- Local (non-`v0.2.0`) checkout of `services/proxy/` compared for the
  "Branch divergence" section (also confirmed `CLAUDE.md` on `master` still
  describes the retired two-service `proxy`/`proxy-standard` split, while
  `origin/v0.2.0`'s own `CLAUDE.md` has already been updated to the unified
  single-service model — not flagged as an issue since it does not apply to
  the `v0.2.0` branch this audit targets)
