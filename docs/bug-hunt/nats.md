# Bug hunt: `nats` infrastructure (issue #849, umbrella #843)

Component: NATS infrastructure across all `deploy/*/docker-compose.yml` (auth,
JetStream, permissions), plus the code that actually consumes that
configuration (`services/dns/nats-subscriber`, `services/ui`'s NATS-related
modules), `setup.sh secondary`, and the remote-secondary compose files.
Starting point was `docs/capability-inventory/SoT-nats.md` (branch
`docs/inventory-nats`) and the corresponding audit comment on issue #843.
This pass follows the vacuum-first/filter-later methodology agreed with the
maintainer on 2026-07-15: everything noticed is recorded here, unfiltered;
verification happens in a later, separate phase.

All line numbers/commit references are against `origin/v0.2.0` at commit
`3f53ac3` ("fix: wait for real endpoint detach before removing validation
networks (#835)"), fetched fresh for this pass.

---

## Finding A — remote secondary registration always hands out an
unreachable, unconfigurable NATS URL (CRITICAL, functional, newly found)

`services/ui/src/routes/secondaries.rs::register_secondary` returns
`nats_url: state.config.nats_url.clone()` verbatim to whatever host calls
`POST /api/secondary/register`. `state.config.nats_url` comes from
`config.rs`'s `nats_url: env_str("NATS_URL", "nats://nats:4222")`.

In **all four** `deploy/*/docker-compose.yml` files, the `ui`, `dns-standard`,
and `dns-ssl` services set `NATS_URL=nats://nats:4222` as a **hardcoded
literal**, not `${NATS_URL:-nats://nats:4222}`:

```
deploy/prod/docker-compose.yml:78:      - NATS_URL=nats://nats:4222
deploy/prod/docker-compose.yml:145:     - NATS_URL=nats://nats:4222
deploy/prod/docker-compose.yml:1255:    - NATS_URL=nats://nats:4222
(identical pattern in dev/quickstart/full-setup)
```

Because there is no `${NATS_URL}` reference at all here, Compose's variable
interpolation cannot apply — setting `NATS_URL` in `.env`/`.env.local` has
**zero effect** on the primary's own `ui` container. There is no supported
configuration path to make the primary's `nats_url` anything other than the
Docker-internal service name `nats`, which only resolves inside the
primary's own Compose network.

`setup.sh::cmd_secondary` (the CLI a remote-secondary operator runs) takes
this field from the registration response and writes it verbatim:

```
setup.sh:4864:  nats_url=$(echo "$response" | grep -oP '"nats_url"\s*:\s*"\K[^"]*' ...)
setup.sh:5036:  NATS_URL=${nats_url}          # written into secondary_dir/.env
```

...then immediately (same function, no confirmation step, no connectivity
check) runs `docker compose ... up -d` and prints
`"Secondary DNS '${name}' is running. Configure this host's IP as DNS on
your clients."` — an unconditional success message.

The project *does* have a mechanism for exposing NATS to remote hosts
(`deploy/prod/docker-compose.nats-secondary.yml` + `NATS_BIND_IP`,
documented in `docs/architecture-ng.md`'s "Remote secondary NATS access"
section) — but nothing anywhere connects that mechanism's LAN-reachable
address back into what `register_secondary` actually hands out. The two
features (open the network path / tell the secondary where to connect) are
implemented completely independently and never wired together.

**Net effect**: registering a genuinely remote secondary (the documented,
advertised use case — AGENTS.md lists "optional DHCP and secondary DNS
features" as a real capability) always configures that secondary's
`nats-subscriber` with `NATS_URL=nats://nats:4222`, a hostname that cannot
resolve from outside the primary's own Docker network. `nats-subscriber`'s
own connect loop (`max_reconnects(None)`, indefinite backoff) means the
container never crashes — it just retries a DNS-resolution failure forever,
silently, while PowerDNS itself (co-located in the same container) keeps
answering queries normally and its own healthcheck (`rec_control ping`)
stays green. The operator is told the secondary "is running" and sees no
error anywhere; the secondary silently never receives a single DNS record
sync from the primary. Only a secondary that happens to be co-located on
the primary's own Docker network (defeating the point of "remote") would
work.

Confirmed by static trace only (config default -> hardcoded compose literal
-> setup.sh write -> auto-start -> success message), no runtime ambiguity
involved.

---

## Finding B — post-rollback recursor cache flush is permission-denied for
every real deployment, not just full-setup (HIGH, confirmed under either
NATS permission-semantics reading)

`services/dns/nats-subscriber/src/rollback_listener.rs::rollback_handler`
(~line 453) does:

```rust
if let Err(e) = state.js.publish("lancache.dns.flush", bytes.into()).await {
    eprintln!("...WARNING... failed to publish cache-flush for {name} after rollback: {e}");
}
```

`state.js` is the JetStream context built from *that specific container's*
own NATS identity — `NATS_DNS_WRITER_USER` for dns-standard,
`NATS_DNS_REPLICA_USER` for dns-ssl. In `dev`/`prod`/`quickstart`'s
generated `nats.conf` (byte-identical across all three), the `publish`
allow-list for those two users is:

- UI user: `publish = ["lancache.dns.record", "lancache.dns.flush"]`
- DNS-writer: `publish = ["lancache.dns.record", "$JS.API.STREAM.INFO...", ...]` — **no** `"lancache.dns.flush"`
- DNS-replica: `publish = ["$JS.API.STREAM.INFO...", ...]` — **no** `"lancache.dns.record"`, **no** `"lancache.dns.flush"`

Only the separate UI identity has `"lancache.dns.flush"` in its (explicit,
non-empty) publish list. Since both dns-writer's and dns-replica's publish
lists are explicitly present and non-empty but simply omit this one
subject, the publish is denied under nats-server's authorization semantics
*regardless* of how an entirely-omitted `publish` key would behave (see
Finding C) — this is not the contested case.

The failure is caught and only ever logged via `eprintln!` (container
stdout/log only); `rollback_handler`'s HTTP response still returns
`"applied": true` / `"republished_to_nats"` with no `flush_failed` field of
any kind — nothing surfaces this to the Admin UI or the operator.

**Net effect**: every operator-triggered zone/record rollback (the
`docs/known-good-config-snapshots.md` feature) correctly patches PowerDNS's
authoritative data, but the module's own doc comment's claim — "flush every
changed name from both recursors ... so this single publish reaches both
without this process reaching across containers itself" — is not actually
true for either identity that can call this code path. The stale,
rolled-back-away answer keeps being served from the recursor cache until
its original TTL naturally expires, which directly undermines the point of
an "instant" rollback. This is the same class of gap `handle_dns_flush`'s
own comment describes fixing for the *normal* (UI-triggered) flush path
(issue #400, switching from `?type=packet`/`?domain=.` to an exact-name
flush) — but the rollback path's flush was apparently never checked against
the actual permission grants for the identity that executes it.

---

## Finding C — full-setup's dns-writer/dns-replica users may or may not
have all JetStream API calls silently denied (CONTESTED — needs a live
test before treating as confirmed either way)

`deploy/full-setup/docker-compose.yml`'s `nats:` service bakes:

```
{ user: validation-dns-writer,  password: validation-nats-password,
  permissions = { subscribe = ["lancache.dns.>", "_INBOX.>"] } }
{ user: validation-dns-replica, password: validation-nats-password,
  permissions = { subscribe = ["lancache.dns.>", "_INBOX.>"] } }
```

Both users' `permissions` block contains **only** `subscribe` — the
`publish` key is entirely **absent** (not an empty list, just missing).

`services/dns/nats-subscriber/src/main.rs::main()` unconditionally (both
roles, at startup, before anything else) calls `js.get_stream("LANCACHE_DNS")`
and, on failure, `js.create_stream(...)`, `std::process::exit(1)` if that
also fails (main.rs:243-264) — both of these are JetStream *publish*
operations (`$JS.API.STREAM.INFO.LANCACHE_DNS` /
`$JS.API.STREAM.CREATE.LANCACHE_DNS`), as is the subsequent consumer
creation, message fetch, and ack (`$JS.API.CONSUMER.*`, `$JS.ACK.*`).

**The open question**: what does nats-server do when a user's
`permissions` block specifies `subscribe` but omits `publish` entirely?

- If omitted-publish means **implicitly denied**: every JetStream call
  above fails immediately, `nats-subscriber` calls `exit(1)`, and
  `services/dns/entrypoint.sh::run_nats_subscriber`'s `while true; ...;
  sleep 3` wrapper (line 780-793) restarts it forever — a permanent,
  silent crash-loop for full-setup's DNS-record NATS sync (the CI
  container itself stays "up" because this is a backgrounded subprocess of
  entrypoint.sh, not the container's PID 1).
- If omitted-publish means **unrestricted/allow-all** (nats-server's
  well-documented "leaving out a direction leaves it wide open" pattern —
  the same class of thing this repo's own AGENTS.md flags for DNS weak
  checks): all the JetStream calls above succeed fine, and the only real
  issue is a least-privilege gap (these two users can publish to *any*
  subject, not just what they need) — a much lower severity, since
  full-setup uses hardcoded, throwaway, CI-only credentials anyway.

I fetched NATS's own hosted docs twice (`authorization.md` page, both
directly and via its `.md?ask=` query mechanism) and both came back
inconclusive — the page does not spell out the omitted-key default
explicitly. A web search synthesis claimed "omitted publish = implicit
deny", but that summary's wording was internally garbled enough
("switches from an implicit deny all + allow") that I do not trust it as
an authoritative source on its own. I could not reach a nats-server source
excerpt to settle this from this environment.

**I am recording this explicitly as unverified/contested, not confirmed in
either direction** — this is exactly the same open question the SoT
document itself flagged and left unresolved ("an open, evidence-backed
question... not a confirmed runtime bug"). A conclusive live test would be:
start a bare `nats:2-alpine`, define one user with only
`permissions = { subscribe = ["foo.>"] }`, connect as that user, and
attempt to publish to any subject not in that list. A clean publish ack
means "omitted = allow" (this finding's crash-loop reading is wrong,
downgrade to an over-permissive/least-privilege note); a "Permissions
Violation" means "omitted = deny" (the crash-loop reading holds, and this
becomes a CRITICAL, confirmed finding on par with Finding A). I did not run
this test in this pass (would require a runner and was not in scope for
this static-analysis-first sweep) — flagging as the single highest-value
follow-up verification for the next phase.

---

## Finding D — dns-ssl (replica) can lose a startup race against
dns-standard (writer) for JetStream stream creation (MODERATE, self-healing)

By design, only the DNS-writer role's `publish` list includes
`$JS.API.STREAM.CREATE.LANCACHE_DNS` (dev/prod/quickstart); DNS-replica's
list has `$JS.API.STREAM.INFO.LANCACHE_DNS` but not `...STREAM.CREATE...`,
implying replica is expected to find the stream already created by writer.

`docker-compose.yml`'s `dns-standard`/`dns-ssl` both declare
`depends_on: [nats]` (list form, **no** `condition: service_healthy` —
and `nats` itself currently has no healthcheck at all in dev/prod/quickstart,
see Finding H) and have **no ordering dependency on each other**. If
dns-ssl's `nats-subscriber` reaches `get_stream`/`create_stream` before
dns-standard's has actually created `LANCACHE_DNS`, dns-ssl's process
`exit(1)`s (main.rs:243-264: replica lacks `STREAM.CREATE`, so the fallback
create also fails).

This is self-healing: `services/dns/entrypoint.sh::run_nats_subscriber`
wraps the binary in an unconditional restart loop (`sleep 3`), so once
dns-standard's stream exists, the next retry succeeds. But it is a real,
reproducible crash/restart window on every cold full-stack start, it is
noisy in logs, and there is no test anywhere covering it (see Finding I).

---

## Finding E — `reload_nats_conf`'s one-shot startup call is silently
best-effort; a transient failure permanently disables auth_callout with no
surfaced status (MODERATE)

`services/ui/src/main.rs` (~line 788):

```rust
if let Err(e) = routes::secondaries::reload_nats_conf(&state).await {
    tracing::warn!("Could not reload initial nats.conf: {}", e);
}
```

This is the **only** call site for `reload_nats_conf` anywhere in the
codebase, called exactly once at UI process startup.
`reload_nats_conf` = `update_nats_conf` (write the `auth_callout.conf`
fragment) + `docker_client::restart_service(docker, "nats")` (the only way
to make nats-server pick it up, since "config reload not supported for
AuthCallout" per the code's own comments).

If either step fails — e.g. a transient Docker-socket-proxy hiccup, the
`nats` container not fully up yet, or (in full-setup specifically) the
container-name mismatch in Finding F — the whole thing is logged as a
`tracing::warn!` and the UI process continues normally. There is:

- no retry (not even a single backoff-and-retry attempt),
- no periodic recheck,
- no surfaced status anywhere in the Admin UI (health endpoint, the
  secondaries page, anywhere) indicating "auth_callout is not actually
  active on the running nats-server".

**Net effect**: a single bad-timing failure on first boot can leave every
future external secondary permanently unable to authenticate via the
callout mechanism (nats-server keeps running with whatever
`auth_callout.conf` content — usually the empty placeholder — it read at
its own last start) until an operator manually restarts the `nats`
container by hand, with nothing in the product surfacing that state. This
runs against CONTRIBUTING.md's own stated principle: "Avoid hiding
operational failures... show a clear error instead of pretending that the
action succeeded."

---

## Finding F — full-setup's NATS restart-by-fixed-name always 404s (LOW —
already self-documented and deliberately mitigated)

`services/ui/src/docker_client.rs::container_name_for_service` hardcodes
`"nats" | "lancache-nats" => Ok("lancache-nats")`. `deploy/full-setup/
docker-compose.yml`'s `nats:` service deliberately has **no**
`container_name:` (to avoid collisions across concurrently-isolated
`-p <project>` CI runs on the same runner), so `restart_service(docker,
"nats")` in full-setup always fails to find a container literally named
`lancache-nats`.

This is **already known and explicitly documented** in the compose file's
own comment (lines 194-219): the workaround is a fixed literal
`NATS_ISSUER_SEED` baked into both the `ui` and `nats` bootstrap scripts so
nats-server is auth_callout-ready from its very first start and the
(known-to-no-op) restart is never actually required in that harness.

Recording for completeness per the vacuum-first rule ("already documented"
is not a reason to skip), and because it is the concrete full-setup
instance of a broader class: `container_name_for_service`'s other five
entries (`proxy`, `dns-standard`, `dns-ssl`, `dhcp`, `dhcp-proxy`,
`dhcp-probe`) use the exact same hardcoded-name pattern and would hit the
identical silent-404 gap for any topology (not just full-setup) that
doesn't pin `container_name` to the expected value — worth flagging to
whichever pass owns `docker_client.rs`/UI routes generally, since this is
one code pattern reused six times, not an isolated nats-only issue.

---

## Finding G — no healthcheck on `nats` in dev/prod/quickstart; full-setup
only has a bare TCP check (INFO — matches SoT, confirmed still
unresolved on this branch)

As of `origin/v0.2.0` @ `3f53ac3`, none of dev/prod/quickstart's `nats:`
compose blocks define a `healthcheck:` at all. full-setup's does, but only
`test: ["CMD-SHELL", "nc -z 127.0.0.1 4222 || exit 1"]` — proves the port
accepts a TCP connection, not that nats-server finished JetStream/
auth_callout initialization (the same class of weak-check gap
AGENTS.md/AG-VAL-019/AG-VAL-020 already call out for DNS: "ping"/"ss" alone
are not acceptable). Per the SoT document, PR #828 commit `83567a8` is
reported to add `http_port: 8222` + a real `wget .../healthz` check to all
four stacks, but that commit is **not yet present on this v0.2.0 branch** —
confirmed directly by reading all four compose files' `nats:` blocks; this
matches the SoT's own caveat that the fix is "pending that PR's merge".

---

## Finding H — no test anywhere validates that the configured NATS
permission set actually matches what the real client code calls (INFO,
test-coverage gap)

`tests/bats/nats_conf_entrypoint_idempotence.bats` thoroughly covers the
entrypoint's config-*generation* idempotence (byte-identical `nats.conf`
across restarts, never clobbering the UI's `auth_callout.conf` fragment, no
drift across dev/prod/quickstart) — but nothing in the bats suite or the
shell simulation scripts (`scripts/nats-secondary-auth-callout-simulation.sh`,
`scripts/ui-nats-dns-integration-simulation.sh`) asserts that the
*permission content* itself is sufficient for what `nats-subscriber`'s real
code actually calls. Neither the full-setup permission gap (Finding C) nor
the rollback-flush permission gap (Finding B) would have been caught by
any existing test before this bug hunt — both are real subject-string
mismatches between a static config file and a Rust call site, exactly the
kind of thing a targeted unit/integration test could assert directly (e.g.
"every subject nats-subscriber/rollback_listener ever publishes to is
present in every static role's compose-generated publish list").

---

## Finding I — plaintext `nats://` to remote secondaries, no TLS anywhere
(INFO, matches SoT, unaffected by anything above)

`deploy/prod/docker-compose.nats-secondary.yml` publishes NATS's plaintext
port directly to `NATS_BIND_IP` for remote secondaries; no `tls {}` block
exists in any of the four generated `nats.conf` templates. Credentials and
JetStream payloads for a remote secondary travel unencrypted over LAN/VPN.
`setup.sh`'s `nats_secondary_override_active_for_install_dir`/
`compose_file_args_for_install_dir` activation wiring (checks shell env
first, then persisted `.env.local`, always re-adds the base compose file
explicitly so Compose's override auto-merge isn't silently dropped) looks
correctly implemented on read-through — no additional bug found there
beyond the already-documented plaintext-transport gap itself. (Note:
Finding A means this is currently moot for a genuinely remote secondary
anyway, since the URL handed out doesn't let it connect in the first
place.)

---

## Finding J — dead dev-only bind mount of the reference `nats.conf` copy
(INFO, matches SoT, reconfirmed)

`deploy/dev/docker-compose.yml` mounts
`../../services/nats/nats.conf:/nats-default.conf:ro` into the `nats`
container. Repo-wide grep for `nats-default.conf` on this branch returns
**exactly one** hit — this mount line itself. Nothing in the entrypoint
script (the inline `command:` block) or anywhere else ever reads
`/nats-default.conf`. Confirmed dead weight, dev-only (prod/quickstart
correctly omit it); `services/nats/nats.conf`'s own header comment already
accurately documents itself as "Reference copy only", so this is a stray
mount rather than a documentation error.

---

## Non-finding (checked, ruled out): `$(mktemp ...)` vs `$$`-escaping in
the nats entrypoint heredoc

At first glance, `tmp_nats_conf="$(mktemp /etc/nats/.nats.conf.XXXXXX)"` in
all three real entrypoints looked inconsistent with the surrounding
`$$var`-style escaping used everywhere else in the same script (needed
because Compose un-escapes `$$` -> `$` before the shell ever sees it).
Checked directly: Compose's variable-interpolation pattern only matches
`$VAR`/`${VAR}`-shaped references; a bare `$(` is not a variable reference
shape at all, so Compose leaves it completely untouched and no escaping is
needed here. Not a bug — recording per the vacuum-first "collect
everything noticed" rule, since it read as suspicious before verification.

---

## Summary / suggested severity ranking for the later filter phase

1. **Finding A** (unreachable/unconfigurable secondary NATS URL) — CRITICAL, confirmed, novel.
2. **Finding B** (rollback flush permission gap) — HIGH, confirmed, novel.
3. **Finding C** (full-setup publish-omitted semantics) — potentially CRITICAL but CONTESTED; needs the live nats-server test described above before any fix is written.
4. **Finding D** (dns-replica stream-create startup race) — MODERATE, confirmed, self-healing.
5. **Finding E** (reload_nats_conf silent best-effort) — MODERATE, confirmed.
6. **Finding F** (full-setup restart-by-name 404) — LOW, already documented/mitigated; broader pattern (six hardcoded names) worth a cross-component note.
7. **Finding G** (no/weak nats healthcheck) — INFO, matches SoT, pending PR #828.
8. **Finding H** (no permission-sufficiency test coverage) — INFO, test gap.
9. **Finding I** (plaintext nats:// to remote secondaries) — INFO, matches SoT.
10. **Finding J** (dead dev-only bind mount) — INFO, matches SoT.
