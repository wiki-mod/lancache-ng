# Capability Inventory: `nats` infrastructure (shared service, not its consumers)

Part of the project-wide capability inventory (umbrella issue #843). This file
covers the `nats` service definition itself — how it is configured across all
four `deploy/*/docker-compose.yml` stacks and in `services/nats/nats.conf` —
**not** how `services/ui`/`services/dns` *use* NATS as a client. That side is
covered by other, parallel inventory passes.

Full findings posted as a comment on issue #843 (English, GitHub content
language rule). This file is the working copy / durable backup of that
research, kept in its own branch (`docs/inventory-nats`) per the umbrella
issue's parallel-audit workflow.

## Correction to this issue's own body

Issue #843's body says the "nats/ui missing-healthcheck finding" is
"#842, and the fix in PR #828", and separately calls out "tonight's
monitor-port gap" as an example of configured-but-dormant capability. Checked
directly against real diffs before writing this up:

- **PR #828** (`test(ci): real syslog-ng -> Admin UI visibility E2E
  simulation`) only touches `.github/workflows/full-setup-deep-validate.yml`
  and `scripts/syslog-forwarding-simulation.sh`. It does **not** touch any
  `docker-compose.yml`, does **not** add a healthcheck to `nats`, and does
  **not** configure `http_port`/`8222` anywhere. It hardcodes
  `services_with_healthcheck="proxy dns-standard dns-ssl netdata"` —
  explicitly *not* including `nats` or `ui`.
- **Issue #842** is actually about `watchdog.sh` only monitoring
  `proxy`/`dns-standard`/`dns-ssl` and not `nats`/`ui`/`dhcp`/etc. It does not
  mention `http_port`/`8222` either.
- Repo-wide `git grep` for `8222|http_port|monitor_port` across
  `*.conf`/`*.yml`/`*.rs`/`*.sh`/`*.md` on `origin/v0.2.0`: **zero matches**.

So the monitor-port (`8222`) gap is real and **still fully unaddressed** —
nothing fixes it yet. Noting this so the umbrella tracking doesn't drift into
believing it's already resolved.

## 1. Structural comparison of the four `nats:` service blocks

| Aspect | dev | prod | quickstart | full-setup |
|---|---|---|---|---|
| `container_name` | `lancache-nats` | `lancache-nats` | `lancache-nats` | *(none — validation network)* |
| Image | `nats:2-alpine@sha256:c11af9...` (same digest all 4) | same | same | same |
| Credentials | env vars, dev defaults (`${VAR:-...}`) | env vars, fail-closed (`${VAR:?...}`) | fail-closed (`${VAR:?...}`) | **hardcoded literals** (`validation-ui` / `validation-ui-password` etc.), no env indirection |
| Static IP | `172.28.0.8` on `lancache` network | none (default network) | none | `172.30.99.8` on `validation` network |
| `expose:` | not set | `["4222"]` | not set | not set |
| `ports:` (host publish) | not set | not set directly (only via optional `docker-compose.nats-secondary.yml` overlay) | not set | not set |
| `healthcheck:` | **none** | **none** | **none** | `nc -z 127.0.0.1 4222` (bare TCP check, not a real NATS/JetStream protocol probe) |
| `logging:` driver | not set (default) | `json-file`, 5m/2 files | `json-file`, 5m/2 files (inline map YAML style, cosmetically different from prod) | not set |
| `log_file` in generated nats.conf | `/var/log/lancache-nats/nats.log` | same | same | **not set at all** — stdout only, breaks the "central logging pipeline (#633)" pattern the other three follow |
| `/data`, `/etc/nats` volumes | named Docker volumes (`nats-data`, `nats-conf`) | **host bind-mounts** under `${LANCACHE_STATE_DIR:-/opt/lancache-ng}` | named Docker volumes | named Docker volumes |
| Reference `services/nats/nats.conf` bind-mounted | **yes**, at `/nats-default.conf:ro` (dead — never read by the entrypoint) | no | no | no |
| `restart:` | `unless-stopped` | `always` | `always` | `unless-stopped` |
| `jetstream.store_dir` | `/data` | `/data` | `/data` | `/data` |
| dns-writer/dns-replica permissions | full (`publish` incl. `$JS.API...LANCACHE_DNS` subjects + `subscribe`) | same as dev | same as dev | **`subscribe` only, no `publish` block at all** |

### Findings from the table

- **Dead bind mount, dev only.** `deploy/dev/docker-compose.yml` mounts
  `../../services/nats/nats.conf:/nats-default.conf:ro`, but the entrypoint
  script never reads `/nats-default.conf` — it generates its own template
  inline via heredoc and writes straight to `/etc/nats/nats.conf`.
  `services/nats/nats.conf` is explicitly documented in its own header as
  "Reference copy only" (accurate), but the dev-only mount of that file into
  the container itself is dead weight: copied in, never read. prod/quickstart
  correctly skip it.
- **`expose: ["4222"]` only in prod.** Documentation-only Compose field (does
  not itself publish anything), but inconsistently present — dev/quickstart/
  full-setup omit it even though the port is equally relevant there.
- **No real healthcheck anywhere in the three production-shaped stacks.**
  Only full-setup has any `healthcheck:`, and even that is a bare `nc -z` TCP
  check — proves the port accepts a TCP connection, not that `nats-server` is
  ready for the NATS protocol handshake or that JetStream is initialized.
  Same class of weak-check gap AG-VAL-019/AG-VAL-020 call out for DNS
  (`ping`/`ss` alone insufficient) — dev/prod/quickstart have *none* at all,
  not even the weak one.
- **full-setup's authorization block appears incompatible with the exact
  JetStream code path its own dns-standard/dns-ssl containers run.** Traced
  end to end, not just asserted:
  - `deploy/full-setup/docker-compose.yml` sets `NATS_USER=validation-dns-writer`
    for `dns-standard` and `NATS_USER=validation-dns-replica` for `dns-ssl`.
  - Both of those users, in full-setup's nats.conf template only, carry
    `subscribe` permissions and **no `publish` list at all**.
  - `services/dns/nats-subscriber/src/main.rs` (`main()`, ~line 240 on)
    unconditionally calls `js.get_stream("LANCACHE_DNS")` and, on failure,
    `js.create_stream(...)`, exiting the process (`std::process::exit(1)`) if
    that create also fails. Both of those JetStream API calls are NATS
    request-reply operations over `$JS.API.STREAM.INFO.LANCACHE_DNS` /
    `$JS.API.STREAM.CREATE.LANCACHE_DNS` — subjects neither validation user is
    authorized to publish to in full-setup's authorization block.
  - This is in tension with PR #828's own description, which says its new
    simulation does "one real DNS record add through the Admin UI
    (dns-standard + dns-ssl, since both independently consume the same NATS
    write)" — i.e. it assumes this exact path already works in full-setup.
  - I checked whether current CI already proves this one way or the other:
    PR #828's own new "Syslog forwarding + Admin UI visibility simulation"
    job is failing right now
    (https://github.com/wiki-mod/lancache-ng/actions/runs/29389730152/job/87270364373),
    but on a *different, earlier* symptom — `curl: (7) Failed to connect to
    127.0.72.2 port 8080` while establishing a CSRF session against the
    Admin UI, before the run ever reaches the DNS-record-add step that would
    exercise dns-writer/replica's JetStream calls. `lancache-ui` in that run's
    "Final container status" also has no `(healthy)` marker next to it, unlike
    dns-standard/dns-ssl/proxy/netdata/syslog-ng — consistent with the
    "no healthcheck on ui/nats" gap already tracked in #842, and plausibly why
    curl raced ahead of a still-initializing UI. That failure neither confirms
    nor refutes the JetStream-permission concern above; it just means CI
    hasn't actually exercised that code path yet in this PR. **This needs a
    real run that gets past the UI curl step to settle whether full-setup's
    dns-writer/replica JetStream calls succeed or fail against these
    permissions** — flagging as an open, evidence-backed question for the
    dns-side/full-setup-owning pass, not a confirmed runtime bug.
- **Credential-injection style differs by design across the four** (dev soft
  defaults, prod/quickstart hard-fail, full-setup hardcoded validation
  strings) — looks deliberate given each stack's differing purpose
  (convenience / production safety / reproducible CI fixture), not obviously
  a bug, but noted for completeness.

## 2. What `nats.conf` actually configures today

All three real stacks (dev/prod/quickstart) generate byte-for-byte the same
template; only credential-injection style differs:

- `jetstream { store_dir: /data }` — JetStream enabled, no
  `max_memory_store`, `max_file_store`, or `domain` set (all defaults).
- `log_file` pointed at `/var/log/lancache-nats/nats.log` (central logging
  pipeline, #633).
- `authorization { users = [...] }` — four static users (UI, DNS-writer,
  DNS-replica, auth-callout responder), all in the implicit default global
  account (`$G`) — no `accounts {}` block.
- `include "auth_callout.conf"` inside `authorization {}` — the actual
  `auth_callout {}` stanza (issuer NKey + `auth_users` list) is written
  separately and exclusively by the Admin UI
  (`services/ui/src/routes/secondaries.rs::update_nats_conf`), per issue
  #811's split-write fix (already merged — PR #817, 2026-07-14).

## 3. nats-server capabilities that exist upstream but are never activated here

Confirmed via repo-wide `git grep` (zero matches for all of the below across
`*.conf`/`*.yml`/`*.rs`/`*.sh`/`*.md` on `origin/v0.2.0`, except where noted):

- **Monitoring/`http_port` (8222)** — not configured in any of the 4 stacks
  (see correction above). No `/varz`, `/connz`, `/subsz`, `/jsz` endpoint is
  ever exposed — no introspection into connection count, subject-level
  stats, or JetStream account/stream stats short of parsing the log file or
  asking the client to self-report. Would also be the natural basis for a
  real healthcheck (`GET /healthz` on the monitor port) instead of the bare
  TCP check full-setup uses today.
- **Clustering (`cluster {}` / route URLs)** — entirely absent. Every
  deployment is a single `nats-server` process; no HA, no route protocol
  between peers. Consistent with the rest of the stack's single-primary
  design, but it does mean JetStream streams are unavoidably R1 (no
  replication) — confirmed in `services/dns/nats-subscriber/src/main.rs:251-252`,
  which sets `max_age`/`discard` on stream creation but never `num_replicas`
  (defaults to 1). A `nats` container crash/restart is a real availability
  gap for the DNS-sync pipeline, mitigated only by container `restart:`
  policy, not NATS-layer redundancy.
- **Leafnodes** — not configured. Would be the natural mechanism for a remote
  secondary's own local NATS instance to bridge into the primary's account,
  instead of every secondary DNS node connecting directly to the primary's
  exposed `4222` (as `deploy/secondary/docker-compose.yml` +
  `docker-compose.nats-secondary.yml` do today). Not used anywhere.
- **Gateways** (multi-cluster/supercluster federation) — not configured; not
  relevant at this project's single-cluster scale, but confirmed absent.
- **TLS between clients and nats-server** — not configured. Every `NATS_URL`
  in the repo (all 4 compose files, `services/dns/nats-subscriber/src/main.rs`,
  `services/ui/src/config.rs`, CI workflow env) uses plaintext `nats://`; no
  `tls {}` block exists in the generated `nats.conf`. Current NATS traffic
  stays inside the Docker bridge network, or — for remote secondaries — is
  exposed raw over `docker-compose.nats-secondary.yml`'s
  `NATS_BIND_IP:4222` port publish. Credentials and JetStream payloads travel
  in the clear between the primary and any remote secondary connecting over
  LAN/VPN. Worth flagging given this project already does TLS interception
  (MITM) for the proxy — the NATS control-plane channel to a *remote*
  secondary is comparatively less protected today.
- **Full account/JWT/operator-mode multi-tenancy** — not used. The project
  deliberately uses the lighter-weight `auth_callout` mechanism (documented
  at length in `services/nats/nats.conf` and
  `services/ui/src/nats_auth_callout.rs`) instead of a full NATS
  `operator`/`resolver` JWT deployment; every connecting identity (static or
  callout-issued) lands in the same implicit `$G` global account — confirmed
  by nats.conf's own header comment ("no `accounts {}` block needed —
  confirmed against a real nats-server 2.14.3"). Deliberate, documented
  design choice (issue #583/#811), not an overlooked gap — noted only for
  completeness of the capability inventory.
- **WebSocket and MQTT client protocols** (`websocket {}`, `mqtt {}` blocks)
  — not configured anywhere; only plain NATS/JetStream on `4222` is used. (A
  `tokio-websockets` crate appears in
  `services/dns/nats-subscriber/Cargo.lock`, but that's a transitive
  dependency of something else in the tree, not evidence that NATS's own
  WebSocket gateway is wired up — confirmed by the absence of any
  `websocket` config or port anywhere.)
- **JetStream stream-level tuning beyond what `nats-subscriber` sets
  client-side** — no `duplicate_window`, `max_msgs`, `max_bytes`, or
  `max_consumers` set anywhere (only `max_age: 7 days` and `discard: Old`,
  set in Rust code via the JetStream API, not in `nats.conf`, since streams
  are created via API rather than declared in server config). No `domain`
  (JetStream domain, used for domain-scoped API prefixes in multi-cluster
  setups) — irrelevant at single-node scale but confirmed absent.
- **`lame_duck_duration`, `max_payload`, `max_connections`,
  `max_control_line`, `write_deadline`** — none of these tuning knobs are set
  anywhere; nats-server defaults apply everywhere.
- **A `nats` CLI / `nats-box` debug container** — not present in any compose
  file. No lightweight way to `nats sub`/`nats stream ls` against the running
  instance from inside the stack; manual debugging today requires exec'ing
  into the `nats` container (Alpine image, has a shell, but no `nats` CLI
  binary installed) or writing a throwaway client.

## Summary

The three real deployment stacks (dev/prod/quickstart) are functionally
consistent in what `nats.conf` itself configures (same JetStream/auth setup,
byte-identical generated templates), but diverge in operational plumbing
around the service block: healthchecks (none anywhere in the 3 real stacks),
logging driver config, volume backing (named volume vs. host bind-mount),
credential-injection style, and one dead bind-mount unique to dev. The
full-setup validation harness diverges further and non-trivially: it has the
*only* healthcheck of the four, but its authorization permissions for the
DNS-writer/replica roles are missing the JetStream `publish` grants the real
roles have, and it doesn't wire `log_file` at all.

Beyond compose-level plumbing, this project uses a narrow, deliberate slice
of nats-server's real feature surface: single-node JetStream with
`auth_callout`-based dynamic authorization, and nothing else. Clustering,
leafnodes, gateways, TLS, WebSocket/MQTT gateways, and full account/JWT
multi-tenancy are all upstream capabilities that exist in the
`nats:2-alpine` image but are never activated anywhere in this repository.
Most of that is a reasonable match for the project's current single-primary,
LAN-scale architecture — the two items that look like real gaps rather than
deliberate scope choices are the missing monitor/`http_port` (no real
health/stats endpoint, and no better-than-bare-TCP healthcheck as a result)
and the plaintext `nats://` channel to remote secondaries over
`docker-compose.nats-secondary.yml`.
