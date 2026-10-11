# Release Validation Plan

This plan defines how a release candidate is validated, on two layers:

- **CI**: the automated gates of `ci.yml`, `nightly.yml`, `release.yml`,
  `gc.yml` and `codeql.yml`. Every workflow job only calls
  `.github/scripts/ci.sh`; the gates, their error codes and their raw output
  live there. `.github/scripts/ci.bats` is the regression suite.
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
It holds:

- `last_stack_validation` and `last_ci_validation`: `commit`, `date`,
  `validator`, `scope`, `summary` and `evidence_ref` of the last completed
  run per layer. A `null` commit means never validated.
- `subsystem_validation.<name>`: `path_prefixes` (git pathspecs), `layer`
  (`stack` or `ci`), `commit`, `date`, `validator`, `evidence_ref`.
- `full_invalidation_triggers`: the cases that make every record stale.

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
| `nightly.yml` | `platform` (`channel-checkout nightly`), `validate`, `cargo-audit`, `nightly` (`promote nightly`, `nightly-status`) | schedule, dispatch |
| `release.yml` | `cut-release-tag`, `release-changelog`, `release-publish`, `release-vex`, `release-sbom-stack` | `v*` tag, dispatch |
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
| DHCP — Kea | ci.bats "dhcp kea ipv4 and ntp helpers per input", "dhcp kea templates render complete valid json", "dhcp kea runtime config migration converges"; `ci.sh validate` Kea leg (`_ci_validate_kea_rollback`: two Admin UI reservations, `setup.sh` rollback to the first snapshot, live `config-get`); `check setup-kea-preflight` and ci.bats "setup kea preflight asks before a second dhcp server" | a render or migration differs, the rollback leaves the second reservation in Kea's running config, or `setup.sh` stops calling the preflight |
| DHCP — dnsmasq (ProxyDHCP, relay) | ci.bats "dhcp-proxy optional and pxe directives render exactly per input", "setup dhcp mode, compose profiles and dnsmasq templates"; `check dhcp-proxy-env` | a rendered directive differs, or the compose file stops passing a template key |
| DNS | `ci.sh validate` (`_ci_validate_dns`: a real `dig`, the standard and ssl answers differ; `_ci_validate_dns_rollback`: snapshot and rollback round trip through the rollback listener); ci.bats "domain validator matches the parity fixture and the cdn list" | no answer, identical answers in both modes, or a rollback that does not revert the record |
| NATS | `ci.sh validate` (`_ci_validate_ui_nats_dns`: an Admin UI record resolves in both DNS modes through NATS and PowerDNS; `_ci_validate_secondary_identity`: two secondaries get distinct identities); ci.bats "setup secondary registration end to end per primary answer"; `check nats-atomic-write` | the record never resolves, two secondaries share an identity, or a shared config is written non-atomically |
| Proxy cache | `ci.sh validate` (`_ci_validate_proxy`: a real MISS, then a HIT); `check proxy-cache-env-doc-drift`; `check proxy-cert-volume` | the second request is not a HIT, a documented `CACHE_*` default differs from the shipped one, or the cert dir is not a named volume |
| Proxy routing and TLS | `ci.sh validate` (`_ci_validate_proxy_stream_map`: a wildcard SNI forwards to the requested name; `_ci_validate_ssl_mitm`: the ssl-mode certificate is issued by the LAN CA; `_ci_validate_ssl_dispatch_map`: a depth ≥ 2 SNI takes the passthrough relay); ci.bats "proxy ssl map, stream map and client acl render exactly per mode and input", "proxy CA, cert dir and CA rotation behave per state", "proxy leaf signing and default cert regen per input", "proxy registrable domain per public suffix rule"; `check proxy-nginx-policy` | a probe or render differs, or `/healthz` serves through `return` instead of `alias` |
| Stack bring-up | `ci.sh validate` waits for every service it starts: healthcheck services until healthy, the others until their state is stable, and ships state and logs of a failing service; `check compose-config` (every compose file renders in every profile); `check compose-healthchecks` | a service is unhealthy or restarting, a compose file does not render, or a service has no healthcheck |
| `setup.sh` | ci.bats `migrate_env_for_update` tests, "setup fresh install writes a config the prod compose takes", "setup update pulls the checkout and continues on its setup.sh", "setup backup and restore round-trip per target and host", "setup log bundle finds every managed secret and redacts it"; `check setup-update-safety`, `check prod-state-wiring`, `check prebuilt-prod`, `check image-channel-resolution` | a migration is not idempotent or convergent (AG-OP-006/007), a stable value rotates, or a secret reaches the log bundle |
| Images and supply chain | `plan` content identity (ci.bats "identity is keyed, deterministic, per target and platform"); `scan-stack` scans the published digest (ci.bats "scan outcome: every trivy scan status has its own code"); `check vex-drift`; `check mutable-refs`; `check stable-external-images`; ci.bats "oci labels: provenance from the SOT, the env and the checkout"; `check cargo-audit` | an identity ignores a build input, a scan status is read as clean, `.trivyignore.yaml` does not yield a complete OpenVEX document, a reference is mutable, or a dependency is vulnerable or yanked |
| Channels and release | `channel-checkout` (ci.bats "channel checkout: SOT source ref, pinned commit, coded misuse"); `promote-ref` supersede check and the AG-REL-011 gate; ci.bats "release tag: next patch from a tag string, an rc tag refused"; `check orphaned-branches` (ci.bats "orphaned branches: channel ref and source_ref branches are long-lived") | a channel run builds the wrong ref, a moved branch tip is promoted, a stale record releases, or a channel branch is reported as orphaned |
| Rust services | `test-stack` runs `cargo fmt --check`, `cargo clippy -- -D warnings` and `cargo test` per crate only when enabled; off by default (AG-VAL-008, ci.bats "test-stack: rust off by default, apk skips, cache errors coded"); `cargo check` is a manual developer step | a Rust check fails when enabled |
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
  compose file reaches the repository inputs it needs (`certs/`, `config/prod/`,
  `scripts/lib/shared-secret-bootstrap.sh`, `services/dns/cdn-domains.txt`,
  `services/syslog/netdata-web_log.conf`) through `../../` paths that exist in every
  real checkout. **`docker compose up` itself exits 0 even when a container
  later crash-loops**, so a validator relying on the `up` exit code alone will not see it;
  check `docker compose ps`/`docker inspect --format='{{.State.Health.Status}}'` per
  container instead.

  **Bring-up sequence:**
  1. On a real Linux host with Docker + Compose v2 and `expect` installed, derive the
     current real prompt sequence with `bash setup.sh list-prompts <answers-file>`
     (introspective — no root or Docker required). On a host where no LAN address is
     detected the server-IP prompt has no default, so the answers file must name it;
     `list-prompts` fails instead of looping when a prompt rejects its answer.
  2. Feed that sequence into the same `expect`-based driving mechanism
     `scripts/untracked/simulations/setup-cli-simulation.sh` already uses in CI
     (`build_expect_prompt_block`) to run `bash setup.sh` for real (`install` is the
     default action with no subcommand; a real install run needs root,
     `setup.sh` enforces `[[ "$(id -u)" = "0" ]]`). Set
     `LANCACHE_IMAGE_CHANNEL`/`LANCACHE_IMAGE_TAG` only as a per-command env prefix on this
     one invocation, never exported process-wide, so it cannot leak into a later
     update/migration phase that should read the channel back from the written runtime env.
     Prefer a dedicated loopback alias for `IP_STANDARD` (e.g. `127.0.0.2`) to avoid port contention with
     other work on a shared runner (the same reasoning `scripts/untracked/simulations/setup-cli-simulation.sh`
     already documents for itself).
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
- **Standard mode**: `dig @<IP_STANDARD> steamcontent.com` (or any
  configured CDN domain) resolves to the proxy's IP. Confirm the TLS handshake for
  that domain is **passthrough** (no interception) — `openssl s_client -connect
  <proxy>:443 -servername steamcontent.com` and confirm the presented certificate is
  the real CDN's own cert, not this project's CA. **Port correction (2026-08-05,
  issue #1391):** a prior version of this document named `:8443` here — that is
  only the container-**internal** listener port; every real deployment profile maps
  it to the standard HTTPS port externally (`deploy/prod/docker-compose.yml` publishes
  `${IP_STANDARD}:443:8443`) — `:443` is what an operator or
  validator actually connects to from outside the container.
- **SSL/MITM mode**: same `dig` against the SSL DNS instance; `openssl s_client
  -connect <proxy>:443 -servername steamcontent.com -CAfile <ca.crt>` and confirm the
  presented certificate **is** signed by the project's own CA (proves interception is
  actually happening, not merely configured). **CA path:** the CA lives in the
  directory the proxy service mounts at `/etc/nginx/ssl/ca`, resolved relative to that
  profile's own `docker-compose.yml` (this document's `AG-VAL-010` note on Compose
  path resolution). `deploy/prod/docker-compose.yml` mounts
  `../../certs:/etc/nginx/ssl/ca`, so for `deploy/prod` the path, run from the repo
  root, is `certs/ca.crt`; for any other profile read its own mount. Using the wrong
  path fails `openssl verify`/`s_client` with a misleading error that looks like broken
  interception but is only a wrong path.
- `ping`/`ss` alone are not acceptable substitutes for either check (AG-VAL-013) — a
  real query/response or a real TLS handshake is required.
- **Wildcard scope at the DNS layer** (AG-OP-015): the proxy half of the rule is in CI
  (`_ci_validate_proxy_stream_map`, `_ci_validate_ssl_dispatch_map`, ci.bats "proxy
  ssl map, stream map and client acl render exactly per mode and input"). The DNS half
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
- **Correction (confirmed live, 2026-07-24, against v0.3.0/commit 88ddbf6a): standard-mode
  HTTPS is NOT cached, and this is not testable as a HIT/MISS check at all.** A prior
  version of this document claimed standard-mode passthrough HTTPS "should still cache"
  because "SNI-routed connections still terminate at nginx's `stream` block only for the
  TLS layer" — that premise is wrong. Per `CLAUDE.md`'s own architecture section, standard
  mode's `stream` block uses `ssl_preread` to read the ClientHello's SNI **without
  terminating TLS at all**; it then blindly forwards the still-encrypted bytes straight to
  the real origin (`proxy_pass` in the `stream` context). nginx never sees plaintext HTTP
  on this path, so it cannot apply `proxy_cache` and cannot add `X-Cache-Status` (confirmed
  live: a real request through the standard-mode HTTPS port returns the origin's own
  `Server` header directly, e.g. `Server: Apache` for a real mirror, with no
  `X-Cache-Status` header at all — compare against the passthrough certificate proof two
  bullets above, which already demonstrates the same blind-forward behavior at the TLS
  layer). Only **HTTP** is cached in standard mode. Do not attempt a HIT/MISS proof against
  standard-mode HTTPS — there is nothing to observe.
- SSL/MITM-mode intercepted HTTPS **is** cached (confirmed live: a real MISS-then-HIT with
  byte-identical bodies, same as the HTTP case above) — nginx genuinely terminates TLS here,
  so the request reaches the normal HTTP proxy/cache layer. Confirmed also that the cache is
  shared across all three reachable paths (standard-mode HTTP, SSL/MITM HTTP, SSL/MITM
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
  HAProxy deny, not the Docker API's 404/409. `check docker-socket-proxy` keeps the
  allowlist deny-by-default; the live negative control is not automated.
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
  `dns-standard`, `dns-ssl` (SSL-mode only), and `nats` (new) are monitored/restarted;
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
- **For `proxy`, `dns-standard`, and `dns-ssl` (multi-process containers), use
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
- Known open, non-blocking gap (#1166, surfaced during #1167's own live validation):
  `restart_container()`'s `CURL_MAX_TIME` (deployed value 5s, `config/prod/watchdog.env`) can be shorter than Docker's
  own restart grace period (10s) for a container slow to respond to SIGTERM, producing
  a spurious `WARNING: restart call failed` log line even when the restart actually
  succeeds a few seconds later. If you see this, cross-check `docker inspect
  --format='{{.State.StartedAt}}'` before concluding the restart genuinely failed —
  this is a known, separately-tracked cosmetic-log bug, not (yet) a real functional
  failure.

### 8. Central logging / syslog forwarding

- The `logging` profile is on by default since issue #1343 (a real opt-out remains
  via `LOGGING_ENABLED=0`, not an opt-in feature) — confirm real log lines from a
  monitored service actually arrive at the `syslog-ng`/fluent-bit target, not just
  that the containers are up. `syslog-forwarding-simulation` (part of
  `full-setup-deep-validate.yml`) is the reusable proof for this — invoke it directly
  or via `gh workflow run` rather than re-deriving a new check.
- **UPDATED (syslog+fluent-bit consolidation PR, 2026-08):** `syslog` and
  `syslog-ng` are no longer two separate containers -- they are one combined
  container (`services/syslog/`) running both processes, under the single
  Compose service name `syslog`. Its healthcheck
  (`services/syslog/healthcheck.sh`) is no longer a binary-presence-only
  check: it verifies fluent-bit AND syslog-ng independently (a real
  `syslog-ng-ctl stats` probe against the control socket, plus a
  cmdline-based process check for fluent-bit) and only reports healthy when
  both are, writing a structured status file
  (`/var/lib/lancache-syslog-data/health-status.json`, including a
  `data_loss_alert_active` field). Still validate the pipeline directly (a
  real log line arriving at the target) in addition to trusting this
  healthcheck, per `AG-VAL-023`'s netdata precedent -- a real check on top of
  a real check is the point, not a contradiction.
- **Standing check (AG-VAL-029, added by issue #1343):** `scripts/untracked/simulations/setup-cli-simulation.sh`'s
  Phase 1 now asserts, after a default fresh install (every wizard prompt answered
  with its default), that `.env` contains `LOGGING_ENABLED=1`, that `COMPOSE_PROFILES`
  includes `logging`, and that the real `syslog` container (the combined
  fluent-bit+syslog-ng container since the consolidation PR above) is actually
  running — guarding against a regression back to the bug this issue fixed (central
  logging silently never starting on a normal install). This runs as part of the same
  CI job the rest of this section already points at (`setup-cli-simulation` in
  `full-setup-sims.yml`), not a new standalone check.
- **Standing check (AG-VAL-029, added by the syslog+fluent-bit consolidation
  PR, 2026-08 -- real confirmed bug):** the combined `syslog` container ships
  a periodic silent-data-loss detector (`services/syslog/data-loss-detector.sh`,
  invoked from `entrypoint.sh`'s detector loop) comparing syslog-ng's own
  "processed" stats counter against real bytes landing on disk under the
  syslog-ng log root. This guards against a real, live-reproduced bug: a
  bind-mounted log-root directory left root-owned (Docker's own default when
  the host directory does not already exist before first container start)
  silently swallows every message a non-root syslog-ng receives --
  `syslog-ng-ctl stats` still increments its `processed` counter and
  syslog-ng logs no error at all, while zero bytes ever reach disk. Verified
  live on a self-hosted runner (see the PR body for the exact reproduction
  commands): the detector correctly fires (`processed_delta=1
  bytes_delta=0`, non-zero exit) against the broken condition and stays
  silent (`bytes_delta=71`, exit 0) against a matched, correctly-owned
  control run delivering the same message. `setup.sh` also now pre-creates
  and chowns this directory on fresh install specifically to prevent the
  condition from occurring in the first place (see setup.sh's own "Creating
  directories" step); this detector is the defense-in-depth backstop for an
  install that predates that fix, skipped the fix (e.g. a from-scratch
  manual deploy without running setup.sh), or has its permissions changed
  later.

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

`ntp` is profile-gated and runs with host networking; `ci.sh validate` does not start
it. Its config render is in CI (ci.bats "ntp config renders and validates exactly per
input"); clock discipline is live only.

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
and bind mounts stay. CI covers the migration and the checkout handoff (ci.bats
`migrate_env_for_update` tests, "setup update pulls the checkout and continues on its
setup.sh") and that the update pauses convergence first (`check
setup-update-safety`); the update of a running stack is live only:

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

No ci.bats test covers the baseline or the gate today (see Coverage Assessment).

---

## Coverage Assessment

Every confirmed bug, CI failure or infrastructure incident has a durable check here or
a stated reason it has none (AG-VAL-029).

### Covered

| Failure class | Durable check |
|---|---|
| Kea config render, migration or rollback drift | ci.bats "dhcp kea templates render complete valid json", "dhcp kea runtime config migration converges"; `_ci_validate_kea_rollback` |
| Kea starting next to another DHCP server on the LAN | `check setup-kea-preflight`; ci.bats "setup kea preflight asks before a second dhcp server" |
| dnsmasq directive or template-key drift | ci.bats "dhcp-proxy optional and pxe directives render exactly per input"; `check dhcp-proxy-env` |
| DNS split routing lost (standard and ssl answer alike) | `_ci_validate_dns` |
| DNS rollback that does not revert, or does not snapshot the restored state | `_ci_validate_dns_rollback` |
| Admin UI record not reaching PowerDNS in both modes | `_ci_validate_ui_nats_dns` |
| Two secondaries sharing one NATS identity | `_ci_validate_secondary_identity` |
| Torn shared-config write | `check nats-atomic-write` |
| Wildcard SNI forwarded to a fixed root (#1297) | `_ci_validate_proxy_stream_map`; ci.bats "proxy ssl map, stream map and client acl render exactly per mode and input" |
| Depth ≥ 2 SNI intercepted instead of relayed (#1276/#1322) | `_ci_validate_ssl_dispatch_map` |
| SSL mode not intercepting | `_ci_validate_ssl_mitm` |
| Stream-level client ACL missing on a listener | ci.bats "proxy ssl map, stream map and client acl render exactly per mode and input" |
| `/healthz` ACL bypassed by `return` | `check proxy-nginx-policy` |
| Documented `CACHE_*` default drifting from the shipped one | `check proxy-cache-env-doc-drift` |
| Cache not serving a HIT | `_ci_validate_proxy` |
| A service crash-looping after `docker compose up` exits 0 | the health and stability wait of `ci.sh validate` |
| `.env` migration not idempotent, rotating a secret or duplicating a key | ci.bats `migrate_env_for_update` tests |
| An update continuing on the old `setup.sh` after a pull | ci.bats "setup update pulls the checkout and continues on its setup.sh" |
| Image revision label or index tag naming another commit than the built tree | `_ci_head_commit`; ci.bats "oci labels: provenance from the SOT, the env and the checkout" |
| A scheduled channel run building the default branch instead of its source ref | `channel-checkout`; ci.bats "channel checkout: SOT source ref, pinned commit, coded misuse" |
| A scan of another image than the published digest | `scan-stack` scans `_ci_published_digest`; ci.bats "scan outcome: every trivy scan status has its own code" |
| A `.trivyignore.yaml` entry not yielding a complete OpenVEX statement | `check vex-drift` |
| Case-sensitive repository-name comparison | `_ci_repo` lowercases; ci.bats "action ref is external unless local, docker, or this repo" (upper-case owner case) |
| Live pipe into an early-exit consumer under `pipefail` (exit 141) | `check pipefail-early-exit` |
| Review chronology or stale line references in comments | `check review-chronology` |
| Closing keywords read outside the linked-issues section | `_ci_pr_section`; ci.bats "check pr-template: every real template section filled, one box marked", "pr markdown: comments strip, a section ends at any real heading" |
| A bats `[ ] && [ ]` check that cannot fail | `check bats-and-chain` |
| `$?` read from an `if` instead of the command | `check if-without-else-status` |
| An exit path losing its code, context or raw output | `check exit-evidence` |
| Mutable image or action reference | `check mutable-refs`; `check action-node-versions` |

### No durable check

- **`setup.sh update` health baseline and regression gate** (issue #1391): no ci.bats
  test; §12 is live only.
- **Dockerfile lint**: BuildKit's `docker buildx build --call check` (for example a
  trailing `\` that merges the next instruction into a `RUN`) runs in no job; such a
  Dockerfile fails only in `build`.
- **`FROM ${VAR}` without a global `ARG`**: `check dockerfile-stage-variables` covers
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
- **Comment claims drifting from code**: `check comment-length` checks structure; the
  truth of a claim is manual review.
- **Third-party reviewer output language** (AG-CC-004): manual review.

### Retired with their mechanism

No check is needed where the mechanism is no longer in the tree: the `build-push.yml`
self-modification trigger, the staging back-fill ancestor fallback, the sparse-checkout
restore of `gc-pr-staging-images.yml` (no workflow sets a sparse checkout), the
`utilities` SBOM merge, `docker run` heredocs without `-i` in workflow YAML, the
`build-tools.yml` nightly promotion branch, the `full-setup-deep-validate.yml` resync
guard, and the skip branches of the Dockerfile acceleration functions.

---

## Scope Boundaries

`ci.sh validate` starts the bridge-network services of `deploy/prod` with every compose
profile enabled; host-network
services (`retention`, `dhcp`, `dhcp-proxy`, `ntp`, `dhcp-probe`) cannot be isolated in
its /27 network and are not started. Covered only live in Part B:

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

Outside this plan: GHCR retention and GC policy are maintainer-owned; `gc.yml` runs
`ci.sh gc --apply`. The Rust checks of Part A are off by default (AG-VAL-008).

---

## Appendix — Commands

| Command | Proves |
|---|---|
| `bash .github/scripts/ci.sh validate` | the running-stack validation of Part A for the accepted stack candidate, on the runner host |
| `bash .github/scripts/ci.sh release-validation` | the AG-REL-011 gate over `docs/validation-state.json` for the checked-out commit |
| `bash .github/scripts/ci.sh check all`, `check <name>` | every repository guard, or one |
| `bats .github/scripts/ci.bats` in the `build-tools` image (AG-VAL-016) | the regression suite |
| `docker compose -f deploy/prod/docker-compose.yml run --rm dhcp-probe` | the DHCP conflict and client probe (§3) |
