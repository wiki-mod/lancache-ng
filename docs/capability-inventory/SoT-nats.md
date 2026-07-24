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

> **Currency check (2026-07-18):** re-verified against `origin/v0.2.0` @
> `dc8d79c6`; see corrections below. Net change since this file was written:
> **PR #828 is now merged** (merge commit `4a5e0c11`, 2026-07-15T20:35Z), so
> the monitor-port/healthcheck gap this file describes as "pending that PR's
> merge" is now actually closed on `v0.2.0` — `http_port: 8222` and the real
> `wget .../healthz` probe are present in all four stacks today (verified by
> `git grep` on `origin/v0.2.0`). The one paragraph that still read the gap as
> "still fully unaddressed … nothing fixes it yet" (an internal contradiction
> with this file's own UPDATE/Section 3/Summary) was written before that merge
> and is corrected inline below. Note: the dev-branch commit `83567a8` cited
> throughout landed its *content* via the squashed/rebased merge commit
> `4a5e0c11`; the literal `83567a8` SHA is not in `v0.2.0` history. The
> full-setup dns-writer/replica JetStream-permission observation and the
> plaintext-`nats://`-to-remote-secondary finding are unchanged and remain
> valid.

## Correction to this issue's own body (superseded — see UPDATE below)

Issue #843's body says the "nats/ui missing-healthcheck finding" is
"#842, and the fix in PR #828", and separately calls out "tonight's
monitor-port gap" as an example of configured-but-dormant capability. Checked
directly against real diffs before writing this up (as of PR #828's head at
the time, before commit `83567a8`):

- **PR #828** (`test(ci): real syslog-ng -> Admin UI visibility E2E
  simulation`), at that point, only touched
  `.github/workflows/full-setup-deep-validate.yml` and
  `scripts/syslog-forwarding-simulation.sh`. It did **not** touch any
  `docker-compose.yml`, did **not** add a healthcheck to `nats`, and did
  **not** configure `http_port`/`8222` anywhere. It hardcoded
  `services_with_healthcheck="proxy dns-standard dns-ssl netdata"` —
  explicitly *not* including `nats` or `ui`.
- **Issue #842** is actually about `watchdog.sh` only monitoring
  `proxy`/`dns-standard`/`dns-ssl` and not `nats`/`ui`/`dhcp`/etc. It does not
  mention `http_port`/`8222` either.

**UPDATE (same day, after the above was written):** a different, parallel
agent pushed commit `83567a8` ("fix(nats,ui): add real Docker HEALTHCHECK for
nats and ui services") onto PR #828 at `2026-07-15T05:10:48Z`, shortly after
the check above was made. Re-verified directly against the live diff and the
commit message:

- `http_port: 8222` is now set in the generated `nats.conf` template across
  all 4 compose files (dev/prod/quickstart/full-setup) — 15 matches for
  `http_port` in the current `gh pr diff 828`.
- `nats`'s Docker healthcheck (all 4 stacks, replacing full-setup's old bare
  `nc -z 127.0.0.1 4222`) is now `wget -q -O /dev/null http://127.0.0.1:8222/healthz`.
- `ui` also gets a real healthcheck (`curl -sf http://127.0.0.1:8080/health`)
  in the same commit — closing the companion "no healthcheck on ui" gap noted
  in the full-setup JetStream-permission finding below.
- The commit message states this was verified live against the pinned
  `nats:2-alpine` image (nats-server 2.14.3): `/healthz` and `/varz` respond
  once the server logs "Server is ready".

**Net effect: the monitor-port (`8222`) gap and the "no real healthcheck
anywhere in the 3 real stacks" finding below are now closed by PR #828**,
pending that PR's merge — they were accurate findings at the time of the
original pass, not stale claims invented after the fact. The plaintext
`nats://` (no TLS) finding, the clustering/leafnodes/gateways/accounts/
websocket/mqtt findings, and the full-setup JetStream-permission question
are all unaffected by this commit and remain valid as written below.
- Repo-wide `git grep` for `8222|http_port|monitor_port` across
  `*.conf`/`*.yml`/`*.rs`/`*.sh`/`*.md` on `origin/v0.2.0`: this returned
  **zero matches at the time this file was first written** (before PR #828
  merged).

**Corrected 2026-07-18 (was: "the monitor-port gap is still fully
unaddressed — nothing fixes it yet"):** that sentence was written while PR
#828 was still open on `v0.2.0`, and it contradicted this same file's own
UPDATE note, Section 3, and Summary. PR #828 has since merged (merge commit
`4a5e0c11`, 2026-07-15T20:35Z). Re-running the same `git grep` on
`origin/v0.2.0` @ `dc8d79c6` now returns matches in all four
`deploy/*/docker-compose.yml` files: `http_port: 8222` is set in every
generated `nats.conf`, and each `nats` healthcheck is
`wget -q -O /dev/null http://127.0.0.1:8222/healthz`. **The monitor-port
(`8222`) / real-healthcheck gap is therefore now closed on `v0.2.0`**, as the
UPDATE/Section 3/Summary below already state — this paragraph is retained only
to record and correct the transient contradiction.

## 1. Structural comparison of the four `nats:` service blocks

**UPDATE (v0.3.0, #766): the `dev` column below is historical.**
`deploy/dev/docker-compose.yml` was deleted outright when the
`deploy/dev`/`config/dev` environment was retired -- it was never a
deliberately engineered second deployment, just an over-built AI
misinterpretation of the maintainer's original, much simpler intent (develop
on the `current_dev` git branch, not a parallel compose profile). The `dev`
column and every `dev`-column-specific finding below (in particular the "dead
bind mount" finding) describe a stack that no longer exists in this
repository; kept for historical comparison rather than rewritten, matching
how this file already treats other superseded findings above (see the
UPDATE/Corrected notes for the monitor-port gap).

| Aspect | dev (retired, v0.3.0) | prod | quickstart | full-setup |
|---|---|---|---|---|
| `container_name` | `lancache-nats` | `lancache-nats` | `lancache-nats` | *(none — validation network)* |
| Image | `nats:2-alpine@sha256:c11af9...` (same digest all 4) | same | same | same |
| Credentials | env vars, dev defaults (`${VAR:-...}`) | env vars, fail-closed (`${VAR:?...}`) | fail-closed (`${VAR:?...}`) | **hardcoded literals** (`validation-ui` / `validation-ui-password` etc.), no env indirection |
| Static IP | `172.28.0.8` on `lancache` network | none (default network) | none | `172.30.99.8` on `validation` network |
| `expose:` | not set | `["4222"]` | not set | not set |
| `ports:` (host publish) | not set | not set directly (only via optional `docker-compose.nats-secondary.yml` overlay) | not set | not set |
| `healthcheck:` (as originally checked) | **none** | **none** | **none** | `nc -z 127.0.0.1 4222` (bare TCP check) — **all 4 now fixed by PR #828 commit `83567a8`**: `http_port: 8222` + `wget .../healthz` real HTTP monitor probe everywhere, see UPDATE note above |
| `logging:` driver | not set (default) | `json-file`, 5m/2 files | `json-file`, 5m/2 files (inline map YAML style, cosmetically different from prod) | not set |
| `log_file` in generated nats.conf | `/var/log/lancache-nats/nats.log` | same | same | **not set at all** — stdout only, breaks the "central logging pipeline (#633)" pattern the other three follow |
| `/data`, `/etc/nats` volumes | named Docker volumes (`nats-data`, `nats-conf`) | **host bind-mounts** under `${LANCACHE_STATE_DIR:-/opt/lancache-ng}` | named Docker volumes | named Docker volumes |
| Reference `services/nats/nats.conf` bind-mounted | **yes**, at `/nats-default.conf:ro` (dead — never read by the entrypoint) | no | no | no |
| `restart:` | `unless-stopped` | `always` | `always` | `unless-stopped` |
| `jetstream.store_dir` | `/data` | `/data` | `/data` | `/data` |
| dns-writer/dns-replica permissions | full (`publish` incl. `$JS.API...LANCACHE_DNS` subjects + `subscribe`) | same as dev | same as dev | **`subscribe` only, no `publish` block at all** |

### Findings from the table

- **Dead bind mount, dev only (moot since v0.3.0, #766 -- the whole `dev`
  stack this described was deleted).** `deploy/dev/docker-compose.yml` used
  to mount `../../services/nats/nats.conf:/nats-default.conf:ro`, but the
  entrypoint script never read `/nats-default.conf` — it generates its own
  template inline via heredoc and writes straight to `/etc/nats/nats.conf`.
  `services/nats/nats.conf` is explicitly documented in its own header as
  "Reference copy only" (accurate), and the dev-only mount of that file into
  the container was dead weight: copied in, never read. prod/quickstart
  never had it.
- **`expose: ["4222"]` only in prod.** Documentation-only Compose field (does
  not itself publish anything), but inconsistently present — dev/quickstart/
  full-setup omit it even though the port is equally relevant there.
- **No real healthcheck anywhere in the three production-shaped stacks —
  ~~true when checked~~, now fixed by PR #828 commit `83567a8`.** At the time
  of this pass, only full-setup had any `healthcheck:`, and even that was a
  bare `nc -z` TCP check — proving the port accepts a TCP connection, not
  that `nats-server` is ready for the NATS protocol handshake or that
  JetStream is initialized (the same class of weak-check gap
  AG-VAL-019/AG-VAL-020 call out for DNS — `ping`/`ss` alone insufficient).
  Commit `83567a8` (same day, pushed shortly after this check) adds
  `http_port: 8222` to all 4 stacks and switches every `nats` healthcheck to
  `wget -q -O /dev/null http://127.0.0.1:8222/healthz` — a real HTTP monitor
  probe, not a bare TCP connect. See the UPDATE note above.
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

- **Monitoring/`http_port` (8222) — CLOSED by PR #828 commit `83567a8`,
  see UPDATE note above.** Was not configured in any of the 4 stacks when
  this pass originally checked (repo-wide `git grep` for
  `8222|http_port|monitor_port` returned zero matches on that check). As of
  `83567a8`, `http_port: 8222` is set in all 4 stacks' generated `nats.conf`,
  `/healthz` and `/varz` are live-verified responding (per that commit's
  message, against the pinned `nats:2-alpine`/nats-server 2.14.3), and it's
  now the basis for a real healthcheck (`wget .../healthz`) instead of the
  old bare TCP check. `/connz`, `/subsz`, `/jsz` are not specifically
  exercised by that commit's healthcheck but are now reachable on the same
  monitor port for ad-hoc introspection.
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

**Updated after initial posting**: the three real deployment stacks
(dev/prod/quickstart) were functionally consistent in what `nats.conf` itself
configured (same JetStream/auth setup, byte-identical generated templates),
but diverged in operational plumbing around the service block: healthchecks
(none anywhere in the 3 real stacks, at the time of the original check),
logging driver config, volume backing (named volume vs. host bind-mount),
credential-injection style, and one dead bind-mount unique to dev. **The
healthcheck gap is now closed** by PR #828 commit `83567a8` (`http_port: 8222`
+ a real `wget .../healthz` probe in all 4 stacks) — see the UPDATE note near
the top of this file. The full-setup validation harness still diverges in
one respect that `83567a8` does not touch: its authorization permissions for
the DNS-writer/replica roles are missing the JetStream `publish` grants the
real roles have, and it still doesn't wire `log_file` at all.

Beyond compose-level plumbing, this project uses a narrow, deliberate slice
of nats-server's real feature surface: single-node JetStream with
`auth_callout`-based dynamic authorization, plus (as of `83567a8`) the HTTP
monitor endpoint for healthchecks/introspection. Clustering, leafnodes,
gateways, TLS, WebSocket/MQTT gateways, and full account/JWT multi-tenancy
are all upstream capabilities that exist in the `nats:2-alpine` image but are
never activated anywhere in this repository. Most of that is a reasonable
match for the project's current single-primary, LAN-scale architecture — with
the monitor-port gap now closed, the one item that still looks like a real
gap rather than a deliberate scope choice is the plaintext `nats://` channel
to remote secondaries over `docker-compose.nats-secondary.yml` (no TLS
between the primary and any remote secondary connecting over LAN/VPN).
