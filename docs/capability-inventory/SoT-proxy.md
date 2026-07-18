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
> **Review-triage update (2026-07-18):** four PR-review findings were
> verified against current code and fixed here: the full-setup bind-mount
> claim (§3), dev's distinct port mapping (§5), the
> `PROXY_SECURITY_MODE=strict` 403 scope (§4), and the stale
> `cdn-ssl-domains.txt` threat-model reference (§7 — `docs/threat-model.md`
> itself was corrected, not just flagged). This file is now ahead of the
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
| Public-suffix-aware root domain derivation (`_load_public_suffix_list`, `_suffix_from_end`, `_registrable_domain`, vendored `public_suffix_list.dat`, ICANN-section only) | Replaces the old hand-maintained `cdn-ssl-domains.txt` (retired in v0.2.0) — derives the correct wildcard-cert root for every `services/dns/cdn-domains.txt` entry via the real Mozilla PSL instead of a naive "last two labels" guess (fixes a real prior bug: `drivers.amd.com` had no cert because the hand-picked root was `downloads.amd.com`, not `amd.com`) | Not directly bats-tested (no dedicated PSL-derivation test found); indirectly proven by `scripts/ssl-mitm-cache-simulation.sh` succeeding against `deb.debian.org` |
| `_collect_domain_rows` (dedup by derived root, tracks `_DOMAIN_ROWS_SKIPPED`) | Single read of the domain file → `_UNIQUE_DOMAINS` + `_DOMAIN_IS_ROOT`; skips invalid/unresolvable rows without failing the whole config, but flags the run as "degraded" | Used by the known-good-snapshot gate below — a config generated from a degraded domain list is **not** snapshotted as known-good (would prune a possibly-complete prior snapshot) |
| CA generation (first boot only, 4096-bit, 10y) + one-time operator banner | Self-signed root CA the operator installs once (`docs/install-ca-cert.md`) | Not unit-tested (would need a full container boot); exercised end-to-end by `scripts/ssl-mitm-cache-simulation.sh` |
| `_sign_cert` (2048-bit per-domain cert, CSR via `/tmp/lancache-cert.csr`, cleans up key **and** partial crt on signing failure, not just the CSR — fix for #655) | Issues one wildcard cert per derived root domain | **Fully unit-tested**: cert creation, correct CN, chain-of-trust via `openssl verify`, correct wildcard+bare SAN, 3650-day validity window, monotonic serial counter, serial-file survival across many signings, orphaned-CSR/key/crt cleanup on both the CSR-step and the sign-step failure paths |
| `_default_cert_needs_regen` (anchored IP-SAN match, fix for #655) | Regenerates the fallback `default.crt` if missing, key-less, SAN-less (old CN-only certs), or if `IP_SSL` changed — previously used an **unanchored substring match** that would keep serving a stale cert if the new IP was a textual prefix of the old one (e.g. `192.168.1.11`→`192.168.1.1`) | **Fully unit-tested**, including the exact prefix-collision regression case |
| Request-policy map generation → `00-ssl-map.conf` | `map $ssl_server_name $ssl_cert_name` (per-root wildcard + bare-domain cert selection), `map $host $cdn_host_allowed` (lazy=allow-all vs strict=allowlist-only, derived from the same PSL-rooted domain list), `geo $lancache_client_allowed` (source-IP CIDR allowlist) | Indirectly proven by `ssl-mitm-cache-simulation.sh`; no unit test isolates the generated map syntax itself |
| Stream-target map generation → `stream.d/00-stream-targets.conf` | `map $ssl_preread_server_name $stream_backend` for SNI passthrough — lazy mode forwards blind to whatever SNI the client sent, strict mode only forwards to domains in the allowlist (else routes to a closed `127.0.0.1:9`) | Same as above — no isolated unit test |
| `https.conf` removal when `SSL_ENABLED=0` | Standard-mode-only installs never load the interception server block | Not unit-tested; would surface as a missing 443 SSL listener if broken |
| Template rendering (`envsubst` for `nginx.conf`, `proxy-params.conf`) | Cache size/mem/slice/inactive/valid + upstream resolver substitution | Covered by `tests/bats/proxy_known_good_snapshot.bats`'s stub-nginx flow (validates the *rendered* file, not the substitution itself) |
| `_proxy_validate_snapshot_or_rollback` (#415) | `nginx -t` → snapshot on success (skipped if domain rows were skipped) → on failure, roll back newest-to-oldest through stored snapshots, re-validating each; fatal exit if nothing validates | **Fully unit-tested** via a stubbed `nginx` binary: valid-config snapshot creation, invalid-config rollback to last-known-good, exhausted-snapshots refusal, retention pruning to `KEEP_KNOWN_GOOD_CONFIGS` |

## 2. nginx configuration surface

- **`conf.d/http.conf`** (port 80, always loaded): `/healthz` (plain 200, no
  access log), `/nginx_status` (`stub_status`, ACL'd to `172.16.0.0/12` — the
  Docker bridge range; consumed by the Admin UI's `nginx_client.rs` for live
  stats), and the main `location /` gated by `$lancache_client_allowed` then
  `$cdn_host_allowed` before `proxy_pass https://$host$request_uri`.
- **`conf.d/https.conf`** (port 443, only present when `SSL_ENABLED=1`,
  entrypoint deletes the file otherwise): same gating + dynamic per-SNI cert
  selection via `$ssl_cert_name`, TLS 1.2/1.3 only, `HIGH:!aNULL:!MD5`
  ciphers, 1-day session cache.
- **`nginx.conf`**: shared `proxy_cache_path` (one cache zone, `lancache`,
  for both HTTP and HTTPS legs — same cache key space), upstream `resolver`
  (must be real public/upstream DNS, never the LAN cache's own DNS —
  enforced by the loop-guard above), and the `stream {}` block on `:8443`
  (`ssl_preread on` → `$stream_backend`) that implements standard-mode's
  blind SNI passthrough. Docker's own port mapping
  (`IP_STANDARD:443→container:8443`, `IP_SSL:443→container:443`) is what
  actually routes standard-mode clients here instead of into the
  interception listener.
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
  Debian's own package) for `libnginx-mod-stream` availability.
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
| `PROXY_SECURITY_MODE` (`lazy`\|`strict`) | `config/{dev,prod}/proxy.env` | `lazy` (default): proxy any host that reaches the cache. `strict`: for the `http{}`/`https{}` `location /` blocks, returns HTTP 403 for any host not derived from `cdn-domains.txt` (`$cdn_host_allowed`, `conf.d/http.conf`/`https.conf`). **Scope gap (confirmed 2026-07-18):** the standard-mode `stream{}` SNI-passthrough listener (`:8443`) enforces the same domain list differently — `entrypoint.sh` routes an unlisted SNI to a closed `127.0.0.1:9`, producing a failed/refused TCP connection, never an HTTP 403. Do not assume a 403 for strict-mode denials on the standard-mode listener. |
| `PROXY_ALLOWED_CLIENT_CIDRS` | `config/{dev,prod}/proxy.env` | Source-IP allowlist (`geo $lancache_client_allowed` block); empty = allow all reachable clients. **Scope gap (confirmed 2026-07-18):** the `geo` variable is only checked in `conf.d/http.conf` and `conf.d/https.conf` (both `http{}` context) — the standard-mode SNI-passthrough `stream{}` listener (`:8443`) never references it, so this allowlist is **not enforced** for standard-mode clients regardless of configuration. See `bughunt-proxy` finding N1. |
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
| `scripts/ssl-mitm-cache-simulation.sh` (CI job `ssl-mitm-cache-simulation` in `full-setup-validate.yml`) | The only **real network E2E** test: brings up the actual published proxy/dns-standard/dns-ssl/nats images, resolves a real cacheable domain (`deb.debian.org`, chosen because game-CDN domains need signed URLs), and proves both HTTP caching (standard mode) and HTTPS MITM caching (SSL mode) work against a genuinely fetchable target — including proving (via the shim above) that the two modes land on distinct endpoints |
| `scripts/ui-reachability-crash-loop-simulation.sh` (job `ui-reachability-crash-loop-simulation`) | Not a proxy test per se, but deliberately crash-loops the **`proxy`** container to prove the Admin UI (a real `depends_on`) still starts and stays reachable (#763) — worth knowing proxy is the subject of another service's resilience test |

**Not tested at all / no dedicated coverage found:**
- Generated `00-ssl-map.conf` / `00-stream-targets.conf` map *syntax* in
  isolation (only proven indirectly via the one E2E script reaching
  `nginx -t`/actual traffic).
- The public-suffix root-derivation algorithm (`_registrable_domain`) has no
  dedicated unit test — no case exercises a compound-label TLD (e.g.
  `co.uk`-style) or the wildcard/exception PSL rule interplay directly; it's
  only proven end-to-end for the plain `.com` domains already in
  `cdn-domains.txt`.
- `PROXY_SECURITY_MODE=strict` and `PROXY_ALLOWED_CLIENT_CIDRS` (403 paths)
  have no automated test — no simulation script or bats test drives a
  request through the strict/CIDR-denied code paths and asserts a 403. This
  gap is compounded by the scope issue above: even a test targeting the
  `http{}` paths would not catch the stream-listener's total lack of
  enforcement, since that's a missing code path, not just missing coverage.
- `/nginx_status`'s ACL and the Admin UI's consumption of it
  (`nginx_client.rs`) have no test found on either side.

## 7. Cross-referenced open issues / known gaps

- **#841** (open, CI reliability): confirms **at least 14 instances** of a
  silent-`set -e`-under-`set -euo pipefail` bug pattern specifically
  **inside `scripts/ssl-mitm-cache-simulation.sh`** — the one real E2E proof
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
  recording the mismatch only here, and its `PROXY_ALLOWED_CLIENT_CIDRS`
  line was scoped to name the same standard-mode stream-listener
  enforcement gap this inventory documents above (§4), so the two documents
  no longer contradict each other.
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
- `deploy/dev/docker-compose.yml`, `deploy/prod/docker-compose.yml`,
  `deploy/quickstart/docker-compose.yml`, `deploy/full-setup/docker-compose.yml`,
  `deploy/full-setup/Dockerfile`, `deploy/secondary/docker-compose.yml`
- `config/dev/proxy.env`, `config/prod/proxy.env`
- `tests/bats/proxy_cert_generation.bats`, `tests/bats/proxy_known_good_snapshot.bats`,
  `tests/bats/known_good_snapshots_sync.bats`
- `scripts/ssl-mitm-cache-simulation.sh` (header/body read in full)
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
