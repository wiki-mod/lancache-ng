# Release Validation Plan

This plan defines how a release candidate is validated, on two layers:

- **CI**: the automated gates of `ci.yml`, `nightly.yml`, `release.yml`,
  `gc.yml` and `codeql.yml`. Every workflow job only calls
  `.github/scripts/ci.sh`; the gates, their error codes and their raw output
  live there. `.github/scripts/ci.bats` is the regression suite; it holds
  no test, and a new test needs a maintainer ACK (#1683).
- **Stack**: the running product. `ci.sh validate` brings the `deploy/prod`
  stack up in an isolated /27 network on the runner host and runs the live
  probes named in Part A. Part B lists the scenarios that need a real Linux
  host on a real LAN.

Neither layer replaces the other: a green CI run does not prove the live
stack, and a working live stack does not prove that the gates would catch a
regression. Rules that refer to this plan: AG-VAL-027 (a runtime service is
part of the running-stack validation), AG-VAL-029 (a confirmed bug, CI
failure or infrastructure incident gets a durable regression check, or its
reason under Coverage Assessment), AG-VAL-033 (a runtime behavior change
updates its scenario; missing live coverage goes under Scope Boundaries) and
AG-REL-011 (release readiness against `docs/validation-state.json`).

A check counts only if it can fail: each gate below has a case that passes
and a case that fails (AG-INT-002).

---

## Validation State Tracking

`docs/validation-state.json` is the validation record. Its path and the
governance paths come from the `release:` block of the SOT
`.github/yaml/build-manifest.yml` (`validation_state`, `governance_paths`).
It holds only records:

- `last_stack_validation` and `last_ci_validation`: `commit`, `date`,
  `validator`, `scope`, `summary` and `evidence_ref` of the last completed
  run per layer.
- `subsystem_validation.<build target>`: `commit`, `date`, `validator`,
  `evidence_ref` per SOT build target (product service or toolchain).

A missing record or a `null` commit means never validated. The scope of a
record comes from the SOT, not from the record:

- a build target: its `context` and the Rust workspace paths that ci.sh
  derives from `Cargo.toml`, the list `plan` uses (`_ci_target_paths`);
- a layer: the `pr_labels` path class that `release.validation_layers` names.

The gate loads the full history first, so it also works in the depth-1
checkout of a CI job.

A record is stale when content under its scope or a governance path changed
since its commit, when its commit is not an ancestor of the commit under
test, or when its key names no SOT target or layer. A scope path that matches
no tracked file stops the gate with `[CI-ERROR-RELEASE-0051]`.

The AG-REL-011 gate reports which records are stale for a commit:

```bash
git fetch origin --tags
git checkout <commit under test>
bash .github/scripts/ci.sh release-validation
```

It checks every record against the checked-out commit. A stale record ends
the run with `[CI-ERROR-RELEASE-0017]` (rc 1) and its reason in the raw
output; otherwise it prints `release-validation=fresh target=<commit>`. The
staleness rules are owned by `ci.sh` (`_ci_release_validation_valid`,
`_ci_release_record_stale`). The `promote` job of `ci.yml` runs the same gate
(`ci.sh promote-ref`) before a `v*` tag moves a release channel and refuses
with `[CI-ERROR-RELEASE-0001]` unless it is fresh.

A record changes only as the result of a completed run with evidence attached
(command output, a CI run URL, or a GitHub comment that quotes it), and only
for the layer and the `subsystem_validation` entries the run exercised. The
two layers are tracked independently; a release readiness claim needs both
current for the same commit.

---

## Part A — CI Gates

### Where the gates run

| Workflow | Jobs and `ci.sh` commands | Trigger |
|---|---|---|
| `ci.yml` | `plan` (`changed-files`, `plan-matrix`), `lint` (`check shellcheck`, `check actionlint`), `checks` (`check all`, which runs `check ci-bats`), `cargo-audit`, `build` (`ship`), `test` (`test-stack`), `scan` (`scan-stack`), `aggregate`, `assemble`, `validate`, `promote` (`promote-ref`), `result` (`result-gate`) | pull request, push to `current_dev`/`master`, `v*` tag, dispatch |
| `nightly.yml` | `platform` (`channel-checkout nightly`), `plan` (`identity --run-record`), `validate`, `cargo-audit`, `nightly` (`promote nightly`), `scan` (`scan-channel`), `report` (`nightly-report`) | schedule, dispatch |
| `release.yml` | `cut-release-tag`, `release-changelog`, `release-publish`, `release-vex`, `release-sbom-stack`, `release-images` (matrix of `actions/attest` in `release-provenance`) | `v*` tag, dispatch |
| `gc.yml` | `gc --apply`, `check orphaned-branches` | schedule, dispatch |
| `codeql.yml` | `codeql-impact`, `codeql-analyze <language>` | pull request, push, schedule, dispatch |

Every workflow bootstrap fetches the event commit (`GITHUB_SHA`). A nightly
run checks out `release.channels.nightly.source_ref` once in its `platform`
job and every later job pins that commit (`channel-checkout nightly
<commit>`). Tags, labels, diffs, promotion and release key on the checked-out
commit (`_ci_head_commit`).

### Standing checks per subsystem

| Subsystem | Gate | Fails when |
|---|---|---|
| DHCP — Kea | `ci.sh validate` Kea leg (`_ci_validate_kea_rollback`: two Admin UI reservations, `setup.sh` rollback to the first snapshot, live `config-get`); `check setup-kea-preflight` | the rollback leaves the second reservation in Kea's running config, or `setup.sh` stops calling the preflight |
| DNS | `ci.sh validate` (`_ci_validate_dns`: a real `dig`, the http and https answers differ; `_ci_validate_dns_rollback`: snapshot and rollback round trip through the rollback listener) | no answer, identical answers in both modes, or a rollback that does not revert the record |
| NATS | `ci.sh validate` (`_ci_validate_ui_nats_dns`: an Admin UI record resolves in both DNS modes through NATS and PowerDNS; `_ci_validate_secondary_identity`: two secondaries get distinct identities) | the record never resolves, or two secondaries share an identity |
| Proxy cache | `ci.sh validate` (`_ci_validate_proxy`: a real MISS, then a HIT); `check proxy-cache-env-doc-drift`; `check proxy-cert-volume` | the second request is not a HIT, a documented `CACHE_*` default differs from the shipped one, or the cert dir is not a named volume |
| Proxy routing and TLS | `ci.sh validate` (`_ci_validate_proxy_stream_map`: a wildcard SNI forwards to the requested name; `_ci_validate_https_mitm`: the https-mode certificate is issued by the LAN CA; `_ci_validate_https_dispatch_map`: a depth ≥ 2 SNI takes the passthrough relay); `check proxy-nginx-policy` | a probe differs, or `/healthz` serves through `return` instead of `alias` |
| Stack bring-up | `ci.sh validate` waits for every service it starts: healthcheck services until healthy, the others until their state is stable, and ships state and logs of a failing service; `check compose-config` (every compose file renders in every profile); `check compose-healthchecks` | a service is unhealthy or restarting, a compose file does not render, or a service has no healthcheck |
| `setup.sh` | `check setup-update-safety`, `check prod-state-wiring`, `check prebuilt-prod`, `check image-channel-resolution` | a guard reports a finding; migration idempotence and convergence (AG-OP-006/007), stable secrets and log-bundle redaction have no CI check (Coverage Assessment) |
| Images and supply chain | `scan-stack` scans the published digest; `check vex-drift`; `check mutable-refs`; `check stable-external-images`; `check cargo-audit` | `.trivyignore.yaml` does not yield a complete OpenVEX document, a reference is mutable, or a dependency is vulnerable or yanked |
| Channels and release | `promote-ref` supersede check and the AG-REL-011 gate | a moved branch tip is promoted, or a stale record releases |
| Rust services | `test-stack` runs `cargo fmt --check`, `cargo clippy -- -D warnings` and `cargo test` per crate only when enabled; off by default (AG-VAL-008); `cargo check` is a manual developer step | a Rust check fails when enabled |
| Repository guards | `ci.sh check all` runs every guard; `ci.sh check <name>` runs one; the guard list is `ci_cmd_check` in `ci.sh` | a guard reports a finding |

---

## Part B — Live Stack Scenarios

End-to-end scenarios against the running stack on a real Linux Docker host on a
real LAN. `ci.sh validate` covers the live probes named in Part A; the scenarios
below cover what it does not reach (see Scope Boundaries). Project tooling runs in
the matching `build-tools` environment (AG-VAL-016); product checks run against the
stack itself.

### 1. Bring-up

- **Real `setup.sh install` bring-up is the correct starting point, not a direct
  `docker compose up`.** `setup.sh` installs the checkout's `deploy/prod` (AG-KD-008), whose
  compose file reaches the repository input it needs (`services/dns/cdn-domains.txt`)
  through a `../../` path that exists in every real checkout. **`docker compose up` itself exits 0 even when a container
  later crash-loops**, so a validator relying on the `up` exit code alone will not see it;
  check `docker compose ps`/`docker inspect --format='{{.State.Health.Status}}'` per
  container instead.

  **Bring-up sequence:**
  1. On a real Linux host with Docker + Compose v2 and `expect` installed, derive the
     current real prompt sequence with `bash setup.sh list-prompts <answers-file>`
     (introspective — no root or Docker required). On a host where no LAN address is
     detected the server-IP prompt has no default, so the answers file must name it;
     `list-prompts` fails instead of looping when a prompt rejects its answer.
  2. Feed that sequence through `expect` to run `bash setup.sh` for real (`install` is the
     default action with no subcommand; a real install run needs root,
     `setup.sh` enforces `[[ "$(id -u)" = "0" ]]`). Set
     `LANCACHE_IMAGE_CHANNEL`/`LANCACHE_IMAGE_TAG` only as a per-command env prefix on this
     one invocation, never exported process-wide, so it cannot leak into a later
     update/migration phase that should read the channel back from the written runtime env.
     Prefer a dedicated loopback alias for `IP_HTTP` (e.g. `127.0.0.2`) to avoid port contention with
     other work on a shared runner.
  3. Expect `Stack started` as the success marker (`Failed to pull required container
     images` as the documented failure case).
  4. Only then run this section's remaining bring-up checks (`docker compose ps` health,
     etc.) against the resulting `deploy/prod` — this is the point where a real Part B
     pass confirms `docker-socket-proxy`/`nats` are healthy rather than trusting the
     `docker compose up` exit code.
- **Profile**: `deploy/prod/docker-compose.yml` is the one deployment profile
  (AG-KD-008) and what `setup.sh install` produces; it references images by `image:`,
  not `build:`. `deploy/full-setup/` is a CI 1.x harness that is still in the tree; no
  `ci.sh` gate and no workflow uses it.
- Check every service: `docker compose -f deploy/prod/docker-compose.yml ps`, and
  `docker inspect --format='{{.State.Health.Status}}' <container>` where the summary is
  ambiguous.
- **Image freshness**: the stack pulls
  `${LANCACHE_IMAGE_REGISTRY}/${LANCACHE_IMAGE_PREFIX}/<service>:${LANCACHE_IMAGE_TAG}`.
  A channel tag (`latest`, `nightly`) can point at an older commit than the one under
  test. Where it exists, pin the per-commit tag of the commit under test,
  `sha-<full commit>` (AG-REL-015), through `LANCACHE_IMAGE_TAG`. The
  `org.opencontainers.image.revision` label names the commit whose CI run built the
  content; an image reused for unchanged content keeps that commit.
- Tear down after the full pass: `docker compose -f deploy/prod/docker-compose.yml
  down -v`; `docker ps -a` and `docker volume ls` must then list no stack container or
  named volume (see §9).

### 2. DNS resolution — both modes

- **Example domain**: not every domain in `services/dns/cdn-domains.txt` resolves
  publicly from every host and network path. If the chosen domain gives no answer even
  from a public resolver without the stack in the path, it is not a proxy or DNS
  failure: pick a
  different entry from the same file (`download.epicgames.com` and `deb.debian.org`
  answered publicly) before concluding anything is
  broken.
- **HTTP mode**: `dig @<IP_HTTP> steamcontent.com` (or any
  configured CDN domain) resolves to the proxy's IP. Confirm the TLS handshake for
  that domain is **passthrough** (no interception) — `openssl s_client -connect
  <proxy>:443 -servername steamcontent.com` and confirm the presented certificate is
  the real CDN's own cert, not this project's CA. **Port correction (2026-08-05,
  issue #1391):** a prior version of this document named `:8443` here — that is
  only the container-**internal** listener port; every real deployment profile maps
  it to the usual HTTPS port 443 externally (`deploy/prod/docker-compose.yml` publishes
  `${IP_HTTP}:443:8443`) — `:443` is what an operator or
  validator actually connects to from outside the container.
- **HTTPS/MITM mode**: same `dig` against the https side of the `dns` container; `openssl s_client
  -connect <proxy>:443 -servername steamcontent.com -CAfile <ca.crt>` and confirm the
  presented certificate **is** signed by the project's own CA (proves interception is
  actually happening, not merely configured). **CA path:** the CA lives in the
  directory the proxy service mounts at `/etc/nginx/ssl/ca`, resolved relative to that
  profile's own `docker-compose.yml` (this document's `AG-VAL-010` note on Compose
  path resolution). `deploy/prod/docker-compose.yml` mounts
  `CA_DIR` (default: the `STATE_SUBDIR_CA` folder below `LANCACHE_STATE_DIR`), so for
  `deploy/prod` the path is `$CA_DIR/ca.crt`; for any other profile read its own mount. Using the wrong
  path fails `openssl verify`/`s_client` with a misleading error that looks like broken
  interception but is only a wrong path.
- `ping`/`ss` alone are not acceptable substitutes for either check (AG-VAL-013) — a
  real query/response or a real TLS handshake is required.
- **Wildcard scope at the DNS layer** (AG-OP-015): the proxy half of the rule is in CI
  (`_ci_validate_proxy_stream_map`, `_ci_validate_https_dispatch_map`). The DNS half
  is live only: pick one wildcard-only entry (`.example.com`) from
  `services/dns/cdn-domains.txt` (or a scratch entry) and `dig` three names: the
  wildcard's bare root, a subdomain under it, and an unrelated domain. Pass: only the
  subdomain resolves to the proxy, unless the bare root is listed on its own.

### 3. DHCP — all three modes

`dhcp` (Kea) and `dhcp-proxy` (dnsmasq) are profile-gated and run with host
networking, as does the one-shot `dhcp-probe`; `ci.sh validate` starts none of them.
Its Kea leg runs Kea on its own containers (Part A). The wire-level checks below need
a real LAN.

- **Probe**: `docker compose -f deploy/prod/docker-compose.yml run --rm dhcp-probe`
  (`lancache-ui --dhcp-probe`) sends one DISCOVER and a REQUEST for the first offer
  from a random locally administered MAC and prints a JSON report after its result
  marker: `conflict` (other DHCP servers that offered) and `client` (whether the
  exchange completed).
- **Kea**: a real LAN client completes DISCOVER, OFFER, REQUEST, ACK; the address lies
  in the configured pool and the client receives the configured DNS and NTP options
  (AG-OP-014). A static reservation added through the Admin UI applies to the next
  lease of that MAC; the Admin UI rollback restores the earlier snapshot. CI covers the
  snapshot and the rollback against Kea's running config (`_ci_validate_kea_rollback`);
  the lease effect is live only.
- **dnsmasq ProxyDHCP**: a PXE client receives the boot filename and next-server
  options on the wire; a non-PXE client receives none.
- **dnsmasq relay**: between two segments, the client's lease comes from the client
  subnet's pool through the relay's `giaddr`, not from a same-subnet fallback.
- **One mode at a time**: `DHCP_MODE` selects exactly one rendered dnsmasq or Kea
  config; inspect the rendered config inside the running container, not only the env
  variable.
- **dnsmasq sub-mode switch** (issue #1486): with `dhcp-proxy` running as ProxyDHCP,
  switch to relay on the Admin UI `/dhcp/mode` form (or back). Pass: the container
  restarted (`docker inspect lancache-dhcp-proxy --format '{{.State.StartedAt}}'`
  is later) and the rendered dnsmasq config shows the new sub-mode.

### 4. Cache hit/miss — HTTP and HTTPS

- Request a real CDN file through the proxy twice; confirm the second response is a
  cache **HIT** (`$upstream_cache_status` in nginx's access log, or an
  `X-Cache-Status` header if configured) and that response bytes are byte-identical
  between the miss and the hit.
- Confirm the cache key genuinely ignores query-string signatures
  (`AG-OP-001`/`AG-OP-012`): request the same path with two different query strings,
  confirm both hit the same cache entry (second request is a HIT even though the
  query string differs).
- **Correction (confirmed live, 2026-07-24, against v0.3.0/commit 88ddbf6a): HTTP-mode
  HTTPS is NOT cached, and this is not testable as a HIT/MISS check at all.** A prior
  version of this document claimed HTTP-mode passthrough HTTPS "should still cache"
  because "SNI-routed connections still terminate at nginx's `stream` block only for the
  TLS layer" — that premise is wrong. Per `CLAUDE.md`'s own architecture section, HTTP
  mode's `stream` block uses `ssl_preread` to read the ClientHello's SNI **without
  terminating TLS at all**; it then blindly forwards the still-encrypted bytes straight to
  the real origin (`proxy_pass` in the `stream` context). nginx never sees plaintext HTTP
  on this path, so it cannot apply `proxy_cache` and cannot add `X-Cache-Status` (confirmed
  live: a real request through the HTTP-mode HTTPS port returns the origin's own
  `Server` header directly, e.g. `Server: Apache` for a real mirror, with no
  `X-Cache-Status` header at all — compare against the passthrough certificate proof two
  bullets above, which already demonstrates the same blind-forward behavior at the TLS
  layer). Only **HTTP** is cached in HTTP mode. Do not attempt a HIT/MISS proof against
  HTTP-mode HTTPS — there is nothing to observe.
- HTTPS/MITM-mode intercepted HTTPS **is** cached (confirmed live: a real MISS-then-HIT with
  byte-identical bodies, same as the HTTP case above) — nginx genuinely terminates TLS here,
  so the request reaches the normal HTTP proxy/cache layer. Confirmed also that the cache is
  shared across all three reachable paths (HTTP-mode HTTP, HTTPS/MITM HTTP, HTTPS/MITM
  HTTPS) since the cache key is `$host$uri` regardless of scheme or which mode's listener
  received the request — a request already cached via one path can come back as an
  immediate HIT via a different path for the same host+URI.

### 5. NATS — secondary lifecycle

CI covers the Admin UI → NATS → `nats-subscriber` → PowerDNS write path
(`_ci_validate_ui_nats_dns`) and distinct per-secondary identities
(`_ci_validate_secondary_identity`). With real secondaries on a real stack:

- **Isolation and rotation**: two secondaries hold distinct credentials; after a
  rotation the old credential no longer authenticates; a removed secondary cannot
  connect.
- **Active disconnect**: a secondary connected at the moment of its removal or
  rotation is disconnected within seconds. Proof: poll `nats-server`'s `connz` monitor
  endpoint until the connection is gone; the HTTP 200 of the removal call is not the
  proof. The connection of an unrelated secondary stays.
- **xkey encryption**: a packet capture of the auth-callout exchange between
  `nats-server` and the Admin UI shows the sealed-box `xkv1` marker and not the JWT's
  literal base64 header marker. Negative control: with `xkey` removed the plaintext
  marker appears.
- **Record removal**: a record deleted through the Admin UI stops resolving in both
  DNS modes; on the AXFR secondary the authoritative zone converges first, then the
  recursor answer expires within its cached TTL.

### 6. Admin UI — reachability, dashboard, controls

- **Reachability**: `curl -u <user>:<pass> http://<ui host>:<port>/`. Without
  `UI_AUTH_USER`/`UI_AUTH_PASSWORD` and without `ALLOW_INSECURE_UI=true` the ui fails
  closed and restart-loops with `Admin-UI authentication is required` (AG-SEC-001);
  that is expected behavior.
- **Watchdog card**: stop a monitored container, wait one watchdog cycle; the entry in
  `GET /api/watchdog-status` and on the dashboard turns unhealthy, and turns healthy
  again after a restart. A stale or missing status file renders as stale or
  unavailable, never as the last known color.
- **Cache resize**: submit a new size (`POST /cache/resize`) and wait for the
  `lancache-converge.timer` run; `setup.sh converge-reconcile` writes `CACHE_MAX_SIZE`
  and `CACHE_MAX_GB` into the runtime env and the proxy is recreated. Pass:
  `docker exec <proxy container> nginx -T` shows the new `max_size=` on
  `proxy_cache_path`; a `200`/`303` from the form is not the proof.
- **Self-restart** (issue #1486): submit the restart form on `/setup`
  (`POST /setup/restart-ui`). Pass: `docker inspect lancache-ui --format
  '{{.State.StartedAt}}'` is later, the acknowledgement page's `/health` poll sees the
  ui go away and come back and ends on `/setup`, and a raw `curl -X POST` through
  `docker-socket-proxy` against `lancache-syslog` or `lancache-watchdog` gets the
  HAProxy deny, not the Docker API's 404/409. No CI check covers the allowlist or the
  live negative control.
- **DHCP/NTP dock start and stop** (issue #1437): the dock's Start/Stop for `dhcp`,
  `dhcp-proxy` and `ntp` posts to `/api/services/{service}/desired-state`; the
  watchdog alone reads that state and starts or stops the container through
  `docker-socket-proxy`. Pass: Stop moves the container to `exited` within one
  watchdog cycle (`docker inspect --format '{{.State.Status}}'`), Start brings it back
  with a later `StartedAt`, and without a dock action (no state file, or the key
  absent) the watchdog never starts or stops either service. The watchdog and ui
  crates cover the reconcile logic and the file contract in their own tests.

### 7. Watchdog — auto-restart coverage

- Confirm coverage matches the **documented, deliberate** per-service decision table
  from PR #1167 exactly (`docs/architecture-ng.md`'s Watchdog section): `proxy`,
  `dns` (http and https recursors), and `nats` (new) are monitored/restarted;
  `ui`, `dhcp` (Kea), `dhcp-proxy` (dnsmasq), `netdata`, `syslog`/`syslog-ng` are
  deliberately **not** — each for a distinct, documented reason (allowlist gaps for
  `ui`/`dhcp`, no meaningful healthcheck defined for `dhcp-proxy`/`netdata`, no fixed
  `container_name` for `syslog`). Do not treat an unmonitored service in this list as
  a regression — check `docs/architecture-ng.md`'s table before filing anything.
  **This table is about health-triggered restart and remains unchanged by issue
  #1437**: `dhcp`/`dhcp-proxy`/`ntp` are still never *restarted* on an unhealthy
  reading. Issue #1437 adds a separate, narrower mechanism -- an explicit
  operator start/stop via the dock, reconciled against `desired-state.json` (see
  the "DHCP/NTP dock start and stop" item of §6) -- that only fires on
  an explicit dock action, never as a reaction to health state. The two
  mechanisms share the container but not the trigger, and they **do** interact
  in one known, accepted way: `resolve_alert_only_targets` (unchanged by issue
  #1437) still monitors `dhcp`/`dhcp-proxy`/`ntp` whenever provisioned, so
  stopping one via the dock reads as "unreachable" to that monitor and climbs
  its `AlertCounter` exactly like an unplanned outage would, producing a
  standing red row on the dashboard for as long as the operator leaves it
  stopped. This is not a bug and needs no fix -- it is the expected, visible
  cost of exposing a real stop control for a service that was previously
  always-on whenever provisioned. A Part B pass should confirm this specific
  behavior (red row appears on dock-initiated Stop, clears on dock-initiated
  Start) rather than treating red-while-deliberately-stopped as a regression.
- For `nats`, the only single-process monitored service, hang it with
  `docker kill --signal=STOP lancache-nats` from the host (external `SIGSTOP`, not an
  in-container one) and confirm a genuine restart (new `StartedAt`).
- **For `proxy` and `dns` (multi-process containers), use
  `docker top <container> -o pid` then `kill -STOP` every listed PID from outside
  the container (root/`sudo`), instead of `--signal=STOP` on the container** — see
  the reason here. `docker kill --signal=STOP` signals only PID 1; in a multi-process
  container the workers keep serving and the healthcheck stays green. Stopping every
  PID leaves the cgroup running, so Docker still starts healthcheck execs, and they
  time out. `docker pause` marks the container unhealthy without running a probe
  (`FailingStreak` stays 0) and proves no hang detection. Run the technique
  against the actual images, confirming a real `FailingStreak` increase from a
  timed-out probe (not just a `Status` flip) and a genuine watchdog-triggered
  restart (new `StartedAt`).

### 8. Central logging / syslog forwarding

- One syslog-ng runs inside the `services` container. Every container logs
  through Docker's `syslog` driver to `udp://127.0.0.1:${LANCACHE_LOG_PORT}`;
  files land in `${SYSLOG_NG_LOG_DIR}/LanCache-NG-<service>/YYYYMMDD.log`.
  There is no separate syslog container and no Fluent Bit. Confirm that real
  log lines of `proxy`, `dns`, `dhcp` and `ui` actually arrive there, not just
  that the containers are up.
- Logging is switched per service (`LOGGING_PROXY_ENABLED`,
  `LOGGING_DNS_ENABLED`, `LOGGING_DHCP_ENABLED`, `LOGGING_UI_ENABLED`, default
  `1`) on the Admin UI `/logs` page. The ui only saves the switch; the
  watchdog re-renders the syslog-ng config and restarts syslog-ng. Switch one
  service off and confirm that only its directory stops growing, the others
  and `LanCache-NG-services/` (the watchdog, never switchable) keep growing.
- With the proxy switch off the proxy access log gets no new lines; the Admin
  UI statistics and dashboard show no new traffic. Confirm the `/logs` page
  says so.
- **Standing checks (AG-VAL-029):** none. The Rust tests of the logging
  switches were removed. The four keys in a fresh `.env`, the migration of
  an old `LOGGING_ENABLED`, a UI switch reaching `.env` and the watchdog's
  syslog-ng filter per switch have no CI check (Coverage Assessment).
- **Known gap:** the silent-data-loss detector of the former combined `syslog`
  container is gone with that container; a log root that syslog-ng cannot
  write to is not detected by a dedicated check. `setup.sh` pre-creates and
  chowns the log root on fresh install.

### 9. Resource-Leak / Cleanup Pass (standing check, run every release)

Framing note: this project is written in Rust (memory-safe), so the classic
C-style heap-leak question does not apply the same way. The resource-leak concern
that **does** apply, and must be checked explicitly every release, is whether
processes, containers, connections, and file descriptors are actually released when
a service is removed, rotated, or restarted — not merely that the API call that
triggered the removal/rotation/restart returned success.

| What to check | How to check it for real | Pass/fail |
|---|---|---|
| A removed/rotated NATS secondary's live connection is actually gone, not just access-revoked | The `connz` polling of §5: after removal, poll `nats-server`'s `connz` monitor endpoint until the connection entry disappears — do not stop at the HTTP 200 from the removal API | Fail if the connection lingers in `connz` past a reasonable poll window |
| Watchdog-restarted containers leave no orphaned process/connection from the pre-restart instance | After a watchdog-triggered restart (Part B §7), `docker exec <host or a diagnostic container> ss -tnp` (or `netstat -tnp` if `ss` is unavailable) targeting the restarted service's port, confirm no stale connection to the old container's now-dead PID remains | Fail if a stale ESTABLISHED/CLOSE-WAIT connection to the pre-restart process persists |
| `docker compose down -v` genuinely removes every container and named volume for the stack | `docker ps -a --filter "name=lancache"` and `docker volume ls --filter "name=lancache"` immediately after teardown — both must return empty | Fail if any lancache-prefixed container or volume remains |
| A resized/rotated proxy container (cache-resize, PR #1174) doesn't leave the old container running alongside the new one | `docker ps --filter "name=lancache-proxy"` immediately after a convergence-triggered recreate — exactly one container, with a `StartedAt` matching the recreate, not two | Fail if more than one `lancache-proxy` container is running, or the old one's `StartedAt` is unchanged (recreate didn't actually happen) |
| No file-descriptor exhaustion from repeated watchdog restart cycles over a longer soak | `docker exec <container> ls /proc/1/fd \| wc -l` sampled before and after several forced restart cycles of the same service — should return to a stable baseline, not grow monotonically | Fail (flag for investigation) if FD count trends upward across cycles rather than stabilizing |

### 10. NTP — clock discipline

`ntp` is profile-gated and runs on the bridge network; `ci.sh validate` enables every
profile, so it starts `ntp` and waits for it. Its config render has no CI check;
clock discipline is live only.

- On a host that grants `CAP_SYS_TIME`, force a clock skew and confirm that
  `chronyc tracking` inside the `ntp` container returns to a `Leap status` of `Normal` with
  a stratum above 0. On a host that denies it (commonly a nested or LXC container
  host, issue #1296) the container logs a `WARNING` that it runs degraded: it tracks
  upstream and answers LAN queries but does not discipline the host clock.
- **Upstream change while enabled** (issue #1486): with `ntp` running, submit
  `/ntp/settings` with a changed `ntp_upstream_servers` list and `ntp_enabled` still
  on. Pass: a later `StartedAt` (`docker inspect lancache-ntp`) and the startup line
  `Starting LanCache-NG-NTP (chronyd) with upstream servers: ...` lists the new
  servers.

### 11. `setup.sh update` — live scenario

`setup.sh update` (`cmd_update`, `perform_stack_update_flow`) captures a health
baseline, takes a config backup (`cmd_backup --config`), pulls the checkout and
continues on the pulled `setup.sh` (`update_repo_and_resume`), migrates `.env`
(`migrate_env_for_update`), pulls the images and applies the update service by service
with health gates (`apply_stack_update_ordered`); a failure rolls the stack back
(`rollback_stack_update`). The flow runs no `docker compose down -v`, so named volumes
and bind mounts stay. CI checks only that the update pauses convergence first
(`check setup-update-safety`); the migration, the checkout handoff and the update of a
running stack are live only:

1. Bring a stack up with `setup.sh install` (§1).
2. Record each service's image ID (`docker inspect <image> --format '{{.Id}}'`) and
   `StartedAt`.
3. Run `bash setup.sh update`.
4. Pass: at least one image ID changed (a real pull), `StartedAt` advanced for every
   recreated container, and the contents of the `proxy-cache`, `ui-data` and `watchdog-status`
   volumes are unchanged.
5. Negative control: force a health-gate failure of one non-UI service (§12) and
   confirm that `rollback_stack_update` restores the pre-update state.

### 12. Update health gate — regression against a pre-existing failure

`capture_stack_health_baseline` samples each service's health three times before the
update and records it as healthy only if every sample agrees. After the update,
`wait_for_stack_health` fails the gate only for a service that was healthy before (or
has no baseline) and is unhealthy now; a service already unhealthy before the update
is named in a warning and does not block it.

| What to check | How to check it for real | Pass/fail |
|---|---|---|
| A service already unhealthy before the update does not roll the update back | Bring a stack up where an opt-in service stays unhealthy (for example `ntp` on a host that denies `CAP_SYS_TIME`), run `setup.sh update` | Pass if the update completes with `Proceeding despite service(s) unhealthy before this update started too`; fail if it rolls back for that service |
| A real regression still rolls the update back | On a stack with every non-UI service healthy, add a `docker-compose.override.yml` that makes one healthy service (not `proxy` or `dns`, whose functional probe would also fire) fail its healthcheck after recreation, run `setup.sh update` | Pass if it reports `Service(s) regressed from healthy to unhealthy during this update: <service>` and `rollback_stack_update` restores the backup; fail otherwise |

No CI check covers the baseline or the gate (see Coverage Assessment).

---

## Coverage Assessment

Every confirmed bug, CI failure or infrastructure incident has a durable check here or
a stated reason it has none (AG-VAL-029).

### Covered

| Failure class | Durable check |
|---|---|
| Kea rollback leaving a reservation in the running config | `_ci_validate_kea_rollback` |
| Kea starting next to another DHCP server on the LAN | `check setup-kea-preflight` |
| DNS split routing lost (http and https answer alike) | `_ci_validate_dns` |
| DNS rollback that does not revert, or does not snapshot the restored state | `_ci_validate_dns_rollback` |
| Admin UI record not reaching PowerDNS in both modes | `_ci_validate_ui_nats_dns` |
| Two secondaries sharing one NATS identity | `_ci_validate_secondary_identity` |
| Wildcard SNI forwarded to a fixed root (#1297) | `_ci_validate_proxy_stream_map` |
| Depth ≥ 2 SNI intercepted instead of relayed (#1276/#1322) | `_ci_validate_https_dispatch_map` |
| HTTPS mode not intercepting | `_ci_validate_https_mitm` |
| `/healthz` ACL bypassed by `return` | `check proxy-nginx-policy` |
| Documented `CACHE_*` default drifting from the shipped one | `check proxy-cache-env-doc-drift` |
| Cache not serving a HIT | `_ci_validate_proxy` |
| A service crash-looping after `docker compose up` exits 0 | the health and stability wait of `ci.sh validate`, for every service it starts (all but the host-network ones, see Scope Boundaries) |
| A `.trivyignore.yaml` entry not yielding a complete OpenVEX statement | `check vex-drift` |
| Live pipe into an early-exit consumer under `pipefail` (exit 141) | `check shell-guards` |
| Review chronology or stale line references in comments | `check comments` |
| A comment, heredoc or YAML text block breaking the What/Why/From contract, or carrying a bare issue number (`.trivyignore.yaml` statements went unread) | `check comments` (CHECK-0128, CHECK-0078, CHECK-0080) |
| A bats `[ ] && [ ]` check that cannot fail | `check bats-and-chain` |
| `$?` read from an `if` instead of the command | `check shell-guards` |
| An exit path losing its code, context or raw output | `check exit-evidence` |
| Mutable image or action reference | `check mutable-refs`; `check action-node-versions` |
| Two jobs of one run computing two identities for one target and platform | `_ci_identity_compute` runs only in a planner scope (`plan-matrix`, `identity`, `impact`) and fails closed beside a given `CI_RUN_IDENTITIES` (IDENTITY-0018); every other reader goes through `_ci_identity_for`, which reads only the run record and fails closed without it or without the pair (IDENTITY-0017, IDENTITY-0015) |

### No durable check

`.github/scripts/ci.bats` holds no test, so these classes have no regression
check; the named function or job is the fix, not a check that detects a
recurrence:

- **Kea config render or migration drift**: the Kea templates and their migration.
- **dnsmasq directive or template-key drift**: the dnsmasq templates and the compose
  keys that feed them.
- **Torn shared-config write**: the NATS shared-config writer.
- **Stream-level client ACL missing on a listener**: the proxy stream map render.
- **`.env` migration not idempotent, rotating a secret or duplicating a key**:
  `migrate_env_for_update` in `setup.sh`.
- **An update continuing on the old `setup.sh` after a pull**: `update_repo_and_resume`.
- **Image revision label or index tag naming another commit than the built tree**:
  `_ci_head_commit`.
- **A scheduled channel run building the default branch instead of its source ref**:
  `channel-checkout`.
- **Validation env binding the SOT state root instead of the per-run root**
  (compose then bound paths the runner does not have): `_ci_validation_env` takes
  the root as its argument. No CI check detects a recurrence; only the live
  `ci.sh validate` stack run exercises it, and a static guard would be a new
  test, which needs a maintainer ACK.
- **A Trivy gate reading an unrecorded or stale DB** (AG-VAL-026):
  `_ci_trivy_db_ensure_fresh` runs trivy's own refresh before every scan and
  `_ci_trivy_db_record` prints the DB version and sha256 into the scan result;
  no check detects a skipped refresh.
- **A rollback leg handing setup.sh no per-run state root** (VALIDATE-0043 at
  run time): `_ci_validate_setup_rollback` writes `LANCACHE_STATE_DIR` first into
  the one-run `.env.local` and fails without it; only the live `ci.sh validate`
  stack run exercises it.
- **A Trivy ignore entry matching nothing** (AG-VAL-007): `scan-channel` runs the
  second `--show-suppressed` pass and `_ci_trivyignore_stale` fails; a subset run
  prints `ignore-stale=NOT-RUN`, so a partial scan never finds a stale entry.
- **LAN-only dist scheduler or distcc hosts reaching a GitHub-hosted build**
  (AG-CI-002/003, AG-CI-011): `_ci_set_runtime` reads both only when
  `_ci_runner_self_hosted` and otherwise logs `VARIABLES-0024`; no CI check
  detects a recurrence, only a build on a hosted runner exercises it.
- **A build-identity tag starting with `sha-`** (AG-REL-015): `_ci_image_tag`
  renders `release.tag_identity_prefix` (`identity-`); no CI check detects a
  recurrence of the old `sha-<identity>-<arch>` form.
- **A scan of another image than the published digest**: `scan-stack` scans
  `_ci_published_digest`.
- **Case-sensitive repository-name comparison**: `_ci_repo` lowercases.
- **Closing keywords read outside the linked-issues section**: `_ci_pr_section`.
- **A Trivy finding, DB outage or scan error that no issue reports, or that one case
  closes for another**: the status and scan report steps.
- **An image no build rebuilds never scanned again**: `scan-channel` in the
  `nightly.yml` job `scan`.
- **A released image digest without a provenance attestation**: `release-provenance`
  (one `actions/attest` per `release-images` entry).
- **A report step that does not start because the job it judges failed**: the
  `nightly.yml` job `report` (own job, `!cancelled()`).
- **A required-check gate that passes a skipped phase without a reason**:
  `result-gate`.
- **`setup.sh update` health baseline and regression gate** (issue #1391): §12 is
  live only.
- **Dockerfile lint**: BuildKit's `docker buildx build --call check` (for example a
  trailing `\` that merges the next instruction into a `RUN`) runs in no job; such a
  Dockerfile fails only in `build`.
- **`FROM ${VAR}` without a global `ARG`**: `check dockerfiles` covers
  the stage `ARG`s of `ci.sh` stages only; the build fails.
- **A bare `!` inside a bats loop body**: shellcheck does not report this shape; no
  check.
- **GNU-only constructs in Alpine/BusyBox images** (AG-VAL-034): no check.
- **Proxy `slice` with a cached 301/302**: no live harness.
- **Netdata alarm to Admin UI notification**: not exercised end to end.
- **Concurrent BuildKit builds on a shared self-hosted daemon**: no source-level
  serialization in `ci.sh` (AG-CI-017).
- **`check actionlint`**: no per-command kill bound; the `lint` job timeout from the
  SOT applies.
- **Comment claims drifting from code**: `check comments` checks structure; the
  truth of a claim is manual review.
- **Third-party reviewer output language** (AG-CC-004): manual review.
- **GHCR GC reachability** (`ci.sh gc`, run by `gc.yml` with `--apply`): neither its
  argument guard nor the classification into kept and deleted versions has a check.

### Retired with their mechanism

No check is needed where the mechanism is no longer in the tree: the `build-push.yml`
self-modification trigger, the staging back-fill ancestor fallback, the sparse-checkout
restore of `gc-pr-staging-images.yml` (no workflow sets a sparse checkout), the
`utilities` SBOM merge, `docker run` heredocs without `-i` in workflow YAML, the
`build-tools.yml` nightly promotion branch, the `full-setup-deep-validate.yml` resync
guard, and the skip branches of the Dockerfile acceleration functions.

---

## Scope Boundaries

`ci.sh validate` enables every compose profile of `deploy/prod` and starts every service
that does not use host networking. The host-network services `dhcp`, `dhcp-proxy` and
`dhcp-probe` cannot be isolated in its /27 network and are not started; their checks
are the Kea leg of `ci.sh validate` (Kea on its own containers) and the live
scenarios of §3; the dnsmasq render has no check (Coverage Assessment). Covered only
live in Part B:

- wire-level DHCP in all three modes, the lease effect of an Admin UI reservation and
  the dnsmasq sub-mode switch (§3);
- the DNS half of the wildcard scope rule (§2);
- NATS rotation, active disconnect and xkey encryption (§5);
- the watchdog card, cache resize, Admin UI self-restart and dock start/stop (§6);
- watchdog hang detection and restart (§7);
- central logging (§8);
- resource release on removal, rotation and restart (§9);
- NTP clock discipline (§10);
- `setup.sh install` and `setup.sh update` on a running stack (§1, §11, §12).

The Rust checks of Part A are off by default (AG-VAL-008).

---

## Appendix — Commands

| Command | Proves |
|---|---|
| `bash .github/scripts/ci.sh validate` | the running-stack validation of Part A for the accepted stack candidate, inside the `build-tools` container (AG-VAL-016) |
| `bash .github/scripts/ci.sh release-validation` | the AG-REL-011 gate over `docs/validation-state.json` for the checked-out commit |
| `bash .github/scripts/ci.sh check all`, `check <name>` | every repository guard, or one |
| `bats .github/scripts/ci.bats` in the `build-tools` image (AG-VAL-016) | the regression suite; it holds no test, so `check ci-bats` reports `NOT-RUN` |
| `docker compose -f deploy/prod/docker-compose.yml run --rm dhcp-probe` | the DHCP conflict and client probe (§3) |
