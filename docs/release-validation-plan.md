# Release Validation Plan

This is the repeatable, reusable test plan for validating lancache-ng before cutting
a release, on a real Linux Docker host. It exists because, as of 2026-07-24, no such
document existed: coverage was scattered across `tests/bats/*.bats`, `tests/shellspec/`,
each crate's `cargo test`, and the CI workflow YAML files themselves (whose job names
are the closest thing to an implicit checklist). This document is meant to be run
**every release**, not just once — subsystem checks are written to stay durable as
the codebase evolves; only the "Current known feature-specific checks" section below
is expected to age and needs pruning/updating release over release.

Two independent things are validated here, and both matter:

- **CI** — do the automated pipelines (`build-push.yml`, `build-tools.yml`,
  `full-setup-validate.yml`, `full-setup-deep-validate.yml`) actually enforce what they
  claim to enforce, verified with real executed runs, not static reading of the YAML.
- **Stack** — does the actual running system, brought up for real on a real Docker
  host, behave the way its features claim to behave.

Neither substitutes for the other. A green CI run does not prove the live stack
behaves correctly (CI's own simulation jobs are themselves a form of "stack" testing,
but a maintainer doing a pre-release pass on real hardware is exercising paths CI's
runner topology and job scoping do not always reach identically). A working live
stack does not prove CI's gates would have caught a regression before merge. Validate
both.

**Governing principle, threaded through every check below**: verification must go
beyond "does it compile / does the existing test suite pass" and prove the actual
claimed behavior is real. `cargo test`/`cargo clippy`/`bats` passing is necessary but
not sufficient — see the worked examples throughout this document, and the "Standing
checks" tables' "How to check it for real" column specifically. In a memory-safe Rust
codebase, "no leaks" is not the C/C++ heap-corruption question; the resource-leak
concern that actually applies here is whether processes, containers, connections, and
file descriptors are actually released when a service is removed, rotated, or
restarted — not just that an API call returned success. See the dedicated
"Resource-Leak / Cleanup Pass" section under Part B.

---

## Validation State Tracking (read this before running anything below)

Before starting any validation pass, answer these questions for real, from the
checkable record in [`docs/validation-state.json`](./validation-state.json) — never
from memory, from "someone said so in a PR comment once," or from assumption:

1. **What was the last verified state?** Read `last_stack_validation` and
   `last_ci_validation` in `docs/validation-state.json`: each names a `commit`, `date`,
   `validator`, `scope`, `summary`, and `evidence_ref` (a URL or file path to the real
   executed proof — a CI run, a PR/issue comment quoting command output, or a log
   file). A `null` commit means "never validated under this mechanism" — treat that
   exactly like a fresh install with no history.
2. **Am I about to test Stack, CI, or both?** Decide explicitly before starting; the
   two have independent records (see policy below) and independent procedures (Part A
   vs Part B of this document).
3. **Has Stack already been validated at or after the current commit?** Compare
   `last_stack_validation.commit` against the commit you intend to validate
   (`git rev-parse HEAD` on the branch/tag under test). If they're equal, Stack is
   current *only if* nothing relevant changed since — see question 5. If
   `last_stack_validation.commit` is not an ancestor of the current commit at all
   (history was rewritten), treat the record as void per `full_invalidation_triggers`
   in the state file, not as merely "stale."
4. **Has CI already been validated at or after the current commit?** Same check
   against `last_ci_validation.commit`.
5. **What changed since the last validation, so re-validation can be scoped?** Run:
   ```bash
   git fetch origin --tags
   git log --name-only <last_validation.commit>..<commit under test> -- .
   ```
   Then classify that diff using the **exact same classifier CI already uses for
   this purpose** — do not invent a second, drifting definition of "what counts as
   DHCP-relevant":
   ```bash
   bash scripts/classify-image-impact.sh <last_validation.commit> <commit under test>
   ```
   This prints the same `dns_rust`/`ui`/`watchdog`/`dhcp`/`dhcp_proxy`/`ntp`/`proxy`/
   `build_tools`/`workflow`/`docs`/`governance`/`setup_runtime`/`deploy`/
   `release_contract`/`scripts` booleans build-push.yml's `detect-changes` job and the
   `promote` job's version-bump logic both already consume. Cross-reference each
   `true` boolean against `docs/validation-state.json`'s `subsystem_validation` map
   (whose `path_prefixes` mirror the same classifier) to know exactly which
   subsystem-specific checks in Part A/B below need a fresh run, and which can be
   skipped as still-current. This is what makes re-validation **incremental**: only
   run the subsystem checks whose `path_prefixes` the diff actually touched, plus any
   check whose own doc entry says it depends on a subsystem that changed.
6. **Where is the record kept?** `docs/validation-state.json`, committed to the repo
   — not a PR comment, not a chat transcript, not tribal memory. It is versioned
   alongside the code it describes, so `git blame`/`git log` on the file itself is a
   real audit trail of who validated what, when.
7. **What counts as "stale"?** Per-subsystem, not all-or-nothing, using the same
   classifier as question 5: a subsystem's recorded validation is stale the moment
   `git log <its recorded commit>..HEAD -- <its path_prefixes>` is non-empty. A
   change to an unrelated subsystem's paths does **not** invalidate this one. Full,
   blanket invalidation (every subsystem, both layers) applies only for the three
   cases listed in `full_invalidation_triggers` in the state file: a governance
   (`AGENTS.md`/`.github/AGENTS.md`) change, an unreconstructable diff (the same case
   `classify-image-impact.sh --all-changed` exists for), or a history rewrite that
   makes the recorded commit not an ancestor of the current one.
8. **Who/what may update this record?** Only as a direct, atomic result of an actual
   completed validation run with real evidence attached — the same "real executed
   proof, not a static claim" principle `AG-CI-012` already established for
   branch-trigger completeness (see the proposed `AG-VAL-028` rule, below, which
   generalizes that principle to this record specifically). Never write a passing
   entry because a check "should" pass, because an earlier version of the code
   passed, or because a subagent reported success without the caller re-verifying the
   evidence per `AG-WF-021`. Update the specific layer(s) and specific
   `subsystem_validation` entries actually exercised in that run — do not blanket-mark
   every subsystem current just because one ran.
9. **Can Stack and CI have independently-current states, or does a stale one block
   trusting the other?** Answer, explicitly: **yes, they are tracked independently
   (they prove different claims — CI proves the automated gates enforce correctness
   on this commit; Stack proves the actual running system behaves correctly on this
   commit, and neither implies the other), but for a release-readiness declaration,
   both must be current as of the same commit (or a commit with no relevant changes
   since, per question 7).** A stale CI record does block a release-ready
   declaration even if Stack is fresh, and vice versa — do not let a fresh result in
   one layer paper over a stale result in the other. It is entirely valid, and
   expected in normal operation, for only one layer to need re-validation after an
   incremental change (e.g. a pure-docs PR only invalidates nothing per the
   classifier; a Rust-only PR with no workflow/script changes may leave CI's own
   pipeline-correctness proof untouched while still requiring a fresh Stack pass for
   the subsystem it touched) — track them separately, gate release-readiness on both.
10. **This mechanism is proposed as new `AGENTS.md` rules**, not yet adopted — see the
    accompanying PR body for the exact proposed rule text (`AG-VAL-028`,
    `AG-VAL-029`, `AG-CI-013`), submitted for maintainer review in the same spirit
    `AG-WF-025` itself requires for a new rule proposal.

**Practical update recipe** once a validation run actually completes with real
evidence:

```bash
# Example: after a completed Stack pass for the "admin-ui" and "watchdog" subsystems
# only (an Admin UI PR that didn't touch DHCP/DNS/NATS), edit docs/validation-state.json:
#   - last_stack_validation: commit/date/validator/scope="incremental:admin-ui,watchdog"
#     /summary/evidence_ref updated
#   - subsystem_validation.admin-ui and .watchdog: commit/date/validator/evidence_ref updated
#   - every other subsystem_validation entry: left untouched (still valid from its own
#     last recorded commit, per the per-subsystem staleness rule in question 7)
git diff docs/validation-state.json   # review the exact fields you changed before committing
```

---

## Part A — CI Test Plan

CI's job is to *automatically* catch a regression before merge. Validating CI means
proving each pipeline gate actually enforces what it claims, not just that the YAML
parses. Every entry below states what to check, how to check it for real (reusing an
already-existing proof where one exists — do not re-invent it), and pass/fail
criteria.

**Two different automation surfaces exist, and they are triggered differently — know
which one a given check actually runs under before treating "current_dev CI is green"
as proof of it:**

- `build-push.yml` / `build-tools.yml`: run automatically on every PR (`pull_request`)
  and push, including against `current_dev`. This is where `rust_coverage`,
  `dns_rust_quality`/`ui_rust_quality`, `dns_test`/`ui_test`/`watchdog_test`,
  `dns_cargo_audit`/`ui_cargo_audit`, `shellcheck`, `file-headers`, `validate-compose`
  (incl. the VEX-drift guard), `pr-tracking-metadata-check`, and `container-scan` live.
- `full-setup-validate.yml` (11 jobs incl. `full-setup-sims` composing the reusable
  `full-setup-sims.yml`) is **`workflow_dispatch`-only** — it does not run
  automatically on any PR; confirmed directly (2026-07-24): its `on:` block has no
  `pull_request` trigger at all.
- `full-setup-deep-validate.yml`'s `pull_request` trigger **does** include
  `current_dev` — `branches: [master, current_dev, "v[0-9]*"]`, confirmed directly
  (2026-07-24) against the workflow file itself (a prior version of this document
  claimed `current_dev` was excluded; it is not — see #709's audit, which restored
  `current_dev` here specifically to match `build-push.yml`'s own `pull_request`
  trigger). It does, however, carry a docs-only `paths-ignore` (`**/*.md`,
  `docs/**`, added by #1203), so a PR that touches only docs does not trigger it —
  do not treat a green `current_dev` PR as proof this workflow ran unless the diff
  also touched a non-docs path. For subsystems whose real E2E proof lives in one of
  these two workflows (DHCP relay, NATS active-disconnect/xkey, DNS reset-to-last-
  known-good, syslog forwarding, etc.), "repeatable CI validation" for
  `full-setup-validate.yml` specifically means actually invoking it —
  `gh workflow run full-setup-validate.yml --repo wiki-mod/lancache-ng --ref
  <branch>` — or running the underlying `scripts/*-simulation.sh` script directly
  against a real stack over SSH on a Linux host, not assuming a green `current_dev`
  PR check already covered it. Note also: `gh workflow run`'s own `image_tag` input
  defaults to `nightly` — before trusting that dispatch as evidence for a specific
  commit, confirm the `nightly` channel tag has actually been rebuilt from that
  commit (`build-push.yml`'s run for that exact SHA on `current_dev` must have
  completed and published), not just that the dispatch itself succeeded; a stale
  `nightly` silently validates the wrong content.

### Standing checks per subsystem

| Subsystem | What to check | How to check it for real | Pass/fail |
|---|---|---|---|
| **DHCP — Kea** | `dhcp_kea_config_generation.bats`/`dhcp_lease_flow_parsing.bats` pass, AND the real Kea Control Agent lease flow works | `bats tests/bats/dhcp_kea_config_generation.bats tests/bats/dhcp_lease_flow_parsing.bats` (build-tools container) for config-gen; `full-setup-validate.yml`'s `dhcp-kea-lease-flow-simulation` job (or `gh workflow run`) for a real DHCPDISCOVER→DHCPACK cycle against Kea, asserting a real lease was granted from the configured pool, not just that the container started | Fail if the bats config-gen tests fail, or if the lease-flow simulation does not show a granted IP from the correct pool |
| **DHCP — dnsmasq ProxyDHCP** | `dhcp_proxy_known_good_snapshot.bats`/`dhcp_proxy_optional_directives.bats` pass; PXE-relevant options actually get injected | Same bats files; `full-setup-validate.yml`'s `dhcp-proxy-pxe-simulation` job for a real PXE client boot-option probe | Fail if bats fail or the PXE simulation doesn't observe the expected boot options on the wire |
| **DHCP — dnsmasq relay** (new, PR #1117) | `dnsmasq-relay` mode genuinely **relays** (not just injects options) between two network segments | `bash scripts/dhcp-relay-flow-simulation.sh` (build-tools container / real Docker host) — this is the exact script #1117 used: two isolated bridges (client-net, server-net), a real `dhclient` DISCOVER on the client-net side, confirms the upstream DHCP server on the separate server-net received the request via the relay's `giaddr` and answered with a lease from the *client subnet's* pool. `tests/bats/setup_dhcp_mode.bats` for the mode-selection/config-render unit coverage | Fail unless the granted lease's subnet matches the client-side pool specifically (proves `giaddr` routing worked, not a coincidental same-subnet fallback) |
| **DNS — PowerDNS zones/RPZ** | Real DNS resolution (recursor + authoritative), zone writes propagate, RPZ wildcard coverage is correct | `dig` against `dns-standard`/`dns-ssl` for a known CDN domain and a known `.lan` record — `ping`/`ss` are explicitly **not** acceptable substitutes (`AG-VAL-019`/`AG-VAL-020`). `tests/bats/dns_zone_generation.bats`, `dns_known_good_snapshot.bats`, `dns_config_snapshot_idempotence.bats` | Fail if `dig` doesn't return the expected record, or any DNS bats file fails |
| **DNS — reset-to-known-good** (new, PR #1152) | `setup.sh reset-to-last-known-good-config dns <zone>` genuinely rolls a live PowerDNS zone back | `bash scripts/setup-reset-dns-config-simulation.sh` (real full-setup stack: makes two real UI-driven zone writes, each producing a real snapshot, then runs the actual CLI against the earlier snapshot, confirms via a real `dig` query that the record content actually reverted). Note from #1152 itself: this script's own real run required two environment-only deviations at the time (a locally built `dns` image; a patched healthcheck probe domain, both because of the unrelated, since-fixed #1150 bug) — when running it again, confirm no deviation is needed anymore before treating a clean run as fully representative | Fail unless the post-rollback `dig` result matches the earlier snapshot's content exactly, and the CLI genuinely used the in-container `PDNS_API_KEY` (the script deliberately seeds a wrong host-side key as a regression guard for this) |
| **NATS — secondary registration/rotation/removal** | Per-secondary credential isolation; rotation invalidates the old credential; removal actually blocks | `bash scripts/nats-secondary-auth-callout-simulation.sh` against a real `nats-server` + a real `nats-subscriber` built from the branch under test | Fail if an old credential still authenticates after rotation, or a removed secondary can still connect |
| **NATS — active disconnect on remove/rotate** (new, PR #1172) | A secondary already connected *at the exact moment* of removal/rotation is force-disconnected within seconds, not left connected until its next reconnect (up to 90 days under the old JWT TTL) | The same `nats-secondary-auth-callout-simulation.sh`, extended in #1172: hold a real `nats-subscriber` connection open, confirm it's live via `nats-server`'s own `connz` HTTP monitor endpoint, remove/rotate that secondary from the Admin UI **while still connected**, then **poll `connz` until the connection actually disappears** — the HTTP 200 from the removal API call is not the proof; the connection's disappearance from `connz` is | Fail if `connz` still lists the connection after a reasonable poll window, or if an unrelated secondary's connection is also kicked (over-broad `CONNZ` filter) |
| **NATS — xkey encryption** (new, PR #1168) | The auth-callout request/response is genuinely encrypted on the wire, not just configured | The packet-capture phase `nats-secondary-auth-callout-simulation.sh` gained in #1168: capture real `nats-server`↔Admin-UI traffic, assert the sealed-box `xkv1` marker is present AND the JWT's own literal base64 header marker is **absent** (checking for the raw password substring is **not sufficient** — the payload is always base64-JWT-encoded regardless of encryption, so a naive substring check "passes" unconditionally; #1168's own methodology note documents this exact false-positive trap). Run once with `xkey:` configured (must show encrypted) and once with it removed as a negative control (must show the plaintext marker) — a check that can't fail is not a check | Fail if the plaintext JWT header marker appears in a run where `xkey` is configured, or if the negative-control run does *not* show it (proves the assertion methodology itself still discriminates) |
| **Admin UI — cache-resize** (new, PR #1174) | A submitted resize genuinely changes what nginx enforces, not just what the dashboard displays | Submit a resize via the UI/API, wait for the ~5-minute `lancache-converge.service` tick, then `docker exec <proxy container> nginx -T 2\>&1 \| grep proxy_cache_path` and confirm the rendered `max_size=` value actually changed to the new target — a `200 OK` from the form or an unchanged dashboard number is **not** proof. On `deploy/quickstart` this reaches the real proxy; on a manual `deploy/prod` checkout it does **not** (documented gap in #1174 — the `ui` container's own display updates but `config/prod/proxy.env` is untouched) — validate against the deployment profile actually in use and do not assume `deploy/prod` behaves like `deploy/quickstart` here | Fail if `nginx -T`'s rendered `max_size` doesn't match the submitted value on quickstart; on `deploy/prod`, confirm this known-misleading-display gap is still documented, not silently "fixed" by an unrelated change without updating this plan |
| **Watchdog — dashboard health card** (new, PR #1165) | The dashboard's color indicators reflect real, live container health — not a frozen or fabricated state | Stop a monitored container (`docker stop lancache-dns-ssl`), wait one `watchdog.sh` cycle (default 30s), `curl http://<ui>/api/watchdog-status` and confirm the entry flips to `red`/`unhealthy`; restart it and confirm it flips back to `green`. Confirm a deliberately stale/missing `status.json` renders `Stale`/`Unavailable`, not a silently frozen last-known color | Fail if the API/dashboard doesn't reflect a real state transition within roughly one `CHECK_INTERVAL` |
| **Watchdog — NATS monitoring** (new, PR #1167) | A hung (not crashed) `nats` container gets detected and restarted | `docker kill --signal=STOP lancache-nats` from **outside** the container's PID namespace (an in-container `kill -STOP 1` is a no-op — PID 1 ignores unhandled stop/kill signals from within its own namespace, confirmed live in #1167), wait 3× `CHECK_INTERVAL`, confirm watchdog logs `RESTARTING lancache-nats` and `docker inspect --format='{{.State.StartedAt}}'` shows a genuinely new start time | Fail if no restart occurs after 3 consecutive unhealthy reads, or if `StartedAt` is unchanged (a restart request that silently failed) |
| **Edition-2024 build (PR #1179)** | All three Rust crates actually build/test/lint clean on the real target (Linux, build-tools container) — not just a Windows-side `cargo check` | For each of `services/ui`, `services/dns/nats-subscriber`, `tools/pxe-client-probe`, inside the build-tools container: `cargo fmt --manifest-path <crate>/Cargo.toml -- --check`, `cargo check --locked --all-targets --manifest-path <crate>/Cargo.toml`, `cargo clippy --locked --all-targets --manifest-path <crate>/Cargo.toml -- -D warnings`, `cargo test --locked --manifest-path <crate>/Cargo.toml`. A **Windows-authored** `cargo check` result is not acceptable evidence per `.github/AGENTS.md`'s build-tools-container contract — the Windows host cannot build Rust for this project's Linux/Docker targets at all | Fail on any non-zero exit from any of the four commands for any of the three crates, or if the check ran outside the pinned build-tools container |
| **SBOM/VEX generation (PR #1194)** | `scripts/generate-vex.sh`'s output matches the committed `vex.openvex.json` byte-for-byte, and the drift guard actually fails when it should | `bash scripts/check-vex-drift.sh` (must report in-sync); `bash scripts/generate-vex.sh \| jq empty` (must be valid JSON); as a negative control, mutate `.trivyignore.yaml` in a scratch copy and re-run the drift guard, confirming it exits non-zero with a clear diff (already proven once, 2026-07-24 — reuse this exact reusable check going forward rather than re-deriving it) | Fail if the drift guard passes on a real mismatch (the negative control), or if it reports drift on an untouched checkout |
| **Fixture key-drift guard (PR #1199)** | The bats guard actually catches a reintroduced historical `.env`-key gap, not just that it parses | `bats tests/bats/setup_update_idempotence.bats` (guard test runs first, must pass on a clean checkout). As a negative control, remove one known-required key (e.g. `NTP_ENABLED`) from `write_converged_env_fixture()` in a scratch copy and re-run — must fail naming that exact key (already proven once, 2026-07-24 — reuse this exact check) | Fail if the guard doesn't name the specific missing key on the negative control, or passes when a key truly is missing |
| **CI/build-tools infra** (path-filter narrowing, permissions hardening — PRs #1190/#1202/#1204) | The narrowed path filters/permissions still trigger for every real change they must cover, and don't over- or under-trigger | `bash scripts/check-bats-path-filter-coverage.sh` (asserts every real bats dependency is covered by `build-tools.yml`'s path filters); `bash scripts/check-workflow-service-lists.sh` (keeps hardcoded service arrays in sync across workflow files); `actionlint -config-file .github/actionlint.yaml <changed workflow files>` for syntax/permissions/runner-label review per `AG-VAL-011` | Fail if either check script reports a gap, or `actionlint` reports any finding |
| **Governance docs (AGPL/MAINTAINERS/OSPS/SBOM policy PRs)** | Documentation actually matches current code/CI behavior, not aspirational text | `bash scripts/check-file-headers.sh` (header contract); manual read-through of each touched doc against the actual current code path it describes, per `AG-DOC-001`. There is no automated drift-detection tool for this yet (`AGENTS.md`'s own "Known Gaps" section says so explicitly) — this remains a manual-review item | Fail (flag as a defect, not skip) if a doc's claim contradicts current code behavior |

---

## Part B — Stack Test Plan

Full end-to-end scenarios against the actually-running system on a real Docker host
(the Windows authoring/CI-orchestration environment cannot build or run this stack —
use a real Linux host, e.g. over SSH to a self-hosted runner, per
`.github/AGENTS.md`'s build-tools-container contract and the recurring
"no local Windows testing" note in prior validation passes).

### 1. Bring-up

- **Profile choice**: `deploy/dev/docker-compose.yml` for a fast day-to-day check
  (10 GB cache, dev DNS ports 5300/5353); `deploy/quickstart/docker-compose.yml` for
  the profile that most closely matches what `setup.sh install` actually produces for
  an operator (this is also the only profile the Admin UI's cache-resize convergence
  loop, PR #1174, actually reaches — see Part A); `deploy/prod/docker-compose.yml`
  when specifically validating prod-only divergences (e.g. the cache-resize
  misleading-display gap). `deploy/full-setup/docker-compose.yml` is CI's own
  self-contained validation harness, useful for reproducing exactly what
  `full-setup-validate.yml`/`full-setup-deep-validate.yml` do locally.
- Bring up: `docker compose -f deploy/<profile>/docker-compose.yml up -d --build`.
  Confirm every service reaches `healthy` (`docker compose ps`) within a reasonable
  window — `docker inspect --format='{{.State.Health.Status}}' <container>` for any
  service whose Compose `ps` summary looks ambiguous.
- **Known `deploy/dev`-only bring-up flake (issue #1215, confirmed live/reproduced 3/3,
  2026-07-24):** `deploy/dev/docker-compose.yml`'s `lancache` bridge network gives some
  services a static `ipv4_address` (`dns-standard`, `dns-ssl`, `dhcp`, `nats`, `syslog`,
  `syslog-ng`, `proxy`) but leaves others (`ui`, `watchdog`, `netdata`,
  `docker-socket-proxy`, `dhcp-probe`, `dhcp-proxy`, `ntp`) to Docker's dynamic IPAM pool
  in the same subnet, with no `ip_range` carve-out. Whenever a dynamic-IP service starts
  before a not-yet-running static-IP service claims its own address, `docker compose up`
  fails with `Error response from daemon: failed to set up container networking: Address
  already in use` for the static-IP service. This is most likely to bite when bringing a
  profile-gated service (`dhcp`, `syslog`, `syslog-ng`) up for the first time, or on the
  very first `--build` bring-up (a dynamic service can grab a base service's reserved
  address before that service starts). Not a sign of a broken build: `docker stop` the
  dynamic-IP service that won the race, bring up the static-IP one, then restart the
  dynamic one. Confirmed NOT present on `deploy/quickstart`/`deploy/prod` (no custom
  static-IP bridge there) or `deploy/full-setup` (every service has an explicit static IP).
- **Image-freshness trap (confirmed live, 2026-07-24):** `deploy/dev`'s `--build` flag
  builds every first-party image from the checked-out source, so it always tests the
  exact commit under test — use it whenever validating a specific pending branch/commit
  like a frozen release candidate. `deploy/quickstart`/`deploy/prod`/`deploy/full-setup`
  instead **pull** published `${LANCACHE_IMAGE_REGISTRY}/.../<service>:${LANCACHE_IMAGE_TAG}`
  images (default tag `latest`, or `nightly` if you set it) — these channel tags can lag
  the commit under test by a large number of commits (confirmed live: `nightly` was 29
  commits behind this same v0.3.0 commit, missing every feature merged that day) because
  the promote pipeline can be backlogged. Before trusting a pulled-image validation run as
  evidence for a specific commit, check the image's own revision label —
  `docker inspect <image> --format '{{index .Config.Labels "org.opencontainers.image.revision"}}'`
  — and confirm it descends from the commit under test; if it doesn't (or the tag doesn't
  exist yet for that commit), either build locally instead (`docker compose build
  <service>` against `deploy/dev`, then `docker tag` the result to the registry-style name
  the target compose file/script expects, e.g. `ghcr.io/wiki-mod/lancache-ng/dns:<local-tag>`,
  and point `LANCACHE_IMAGE_TAG` at `<local-tag>`) or wait for a fresh `build-push.yml` run
  against that exact commit. This applies to `scripts/*-simulation.sh` invocations too —
  `nats-secondary-auth-callout-simulation.sh` and `syslog-forwarding-simulation.sh` both
  default `LANCACHE_IMAGE_TAG` to a mutable channel and need the same treatment; the DHCP
  simulation scripts (`dhcp-kea-lease-flow-simulation.sh`, `dhcp-proxy-pxe-simulation.sh`,
  `dhcp-relay-flow-simulation.sh`) are unaffected — they always `docker build` their own
  images directly from the checked-out source, never from a registry tag.
- Tear down after the full pass: `docker compose -f deploy/<profile>/docker-compose.yml
  down -v`, and confirm via `docker ps -a` and `docker volume ls` that no stack
  containers or named volumes remain (see the Resource-Leak section below — this is
  itself the first, simplest instance of that check).

### 2. DNS resolution — both modes

- **Example-domain caveat (confirmed live, 2026-07-24):** not every domain in
  `services/dns/cdn-domains.txt` resolves publicly from every validation host/network path
  — `steamcontent.com`/`content1-5.steampowered.com`/`lancache.steampowered.com` returned no
  answer at all from one real validation host even via `8.8.8.8` directly (not a proxy
  problem, confirmed by querying public DNS with no proxy involved). If your chosen example
  domain doesn't resolve, don't treat that as a proxy/DNS-spoofing failure — pick a
  different entry from the same file (`download.epicgames.com` and `deb.debian.org` were
  confirmed reachable and were used for this pass's evidence) before concluding anything is
  broken.
- **Standard mode**: `dig @<IP_STANDARD or dev DNS port> steamcontent.com` (or any
  configured CDN domain) resolves to the proxy's IP. Confirm the TLS handshake for
  that domain is **passthrough** (no interception) — `openssl s_client -connect
  <proxy>:8443 -servername steamcontent.com` and confirm the presented certificate is
  the real CDN's own cert, not this project's CA.
- **SSL/MITM mode**: same `dig` against the SSL DNS instance; `openssl s_client
  -connect <proxy>:443 -servername steamcontent.com -CAfile certs/ca.crt` and confirm
  the presented certificate **is** signed by the project's own CA (proves
  interception is actually happening, not merely configured).
- `ping`/`ss` alone are not acceptable substitutes for either check (`AG-VAL-019`/
  `AG-VAL-020`) — a real query/response or a real TLS handshake is required.

### 3. DHCP — all three modes

- **Kea**: real DHCPDISCOVER→DHCPOFFER→DHCPREQUEST→DHCPACK cycle via
  `dhcp-kea-lease-flow-simulation` (or its underlying script run directly), confirm a
  real lease was granted from the configured pool and is visible via Kea's Control
  Agent API.
- **dnsmasq ProxyDHCP**: real PXE boot-option probe via
  `dhcp-proxy-pxe-simulation`/`tools/pxe-client-probe` (the Rust PXE probe rewritten
  in PR #1159), confirm the expected boot filename/next-server options are actually
  injected on the wire.
- **dnsmasq relay** (new): `bash scripts/dhcp-relay-flow-simulation.sh` — see Part A's
  entry for the exact mechanism; this is the canonical reusable proof, run it as-is
  rather than re-deriving a new one.
- Confirm the three modes are genuinely mutually exclusive at the config-render level
  (`DHCP_MODE` selects exactly one rendered `dnsmasq`/Kea config) — inspect the
  rendered config inside the running container, not just the env var.

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

### 5. NATS — full secondary lifecycle, incl. today's new mechanisms

Run `scripts/nats-secondary-auth-callout-simulation.sh` end-to-end (this single script
already covers, per PRs #1172/#1168's own extensions to it): registration with
distinct per-secondary credentials, isolation between two secondaries, credential
rotation invalidating the old credential, **active disconnect** of an already-live
connection on remove/rotate (verified via `connz` polling, not the HTTP response),
and **xkey-encrypted** auth-callout traffic (verified via packet capture with a
negative control). See Part A's NATS rows for the specific pass/fail criteria on each
sub-mechanism — this section is the "run it as one real end-to-end pass" framing,
Part A is the "what does each individual claim need to prove" framing.

### 6. Admin UI — reachability, dashboard, and today's new controls

- Reachability: `curl -u <user>:<pass> http://<ui host>:<port>/` (or confirm the
  fail-closed `Admin-UI authentication is required` restart-loop behavior is what you
  expect if `UI_AUTH_USER`/`ALLOW_INSECURE_UI` isn't configured — `AG-SEC-001`: this is
  intended security behavior, not a broken build).
- Watchdog health-dashboard card (new): see Part A's entry — the green→red→green
  live-transition proof, driven by an actual container stop/start, is the standard.
- Cache-resize control (new): see Part A's entry — the `nginx -T` rendered-config
  proof, not a `200 OK`.

### 7. Watchdog — auto-restart coverage

- Confirm coverage matches the **documented, deliberate** per-service decision table
  from PR #1167 exactly (`docs/architecture-ng.md`'s Watchdog section): `proxy`,
  `dns-standard`, `dns-ssl` (SSL-mode only), and `nats` (new) are monitored/restarted;
  `ui`, `dhcp` (Kea), `dhcp-proxy` (dnsmasq), `netdata`, `syslog`/`syslog-ng` are
  deliberately **not** — each for a distinct, documented reason (allowlist gaps for
  `ui`/`dhcp`, no meaningful healthcheck defined for `dhcp-proxy`/`netdata`, no fixed
  `container_name` for `syslog`). Do not treat an unmonitored service in this list as
  a regression — check `docs/architecture-ng.md`'s table before filing anything.
- For each monitored service, repeat the hung-not-crashed proof pattern from Part A's
  NATS-monitoring row (external `SIGSTOP`, not an in-container one) and confirm a
  genuine restart (new `StartedAt`).
- Known open, non-blocking gap (#1166, surfaced during #1167's own live validation):
  `restart_container()`'s `CURL_MAX_TIME` (default 5s) can be shorter than Docker's
  own restart grace period (10s) for a container slow to respond to SIGTERM, producing
  a spurious `WARNING: restart call failed` log line even when the restart actually
  succeeds a few seconds later. If you see this, cross-check `docker inspect
  --format='{{.State.StartedAt}}'` before concluding the restart genuinely failed —
  this is a known, separately-tracked cosmetic-log bug, not (yet) a real functional
  failure.

### 8. Central logging / syslog forwarding

- If the optional `logging` profile is enabled: confirm real log lines from a
  monitored service actually arrive at the `syslog-ng`/fluent-bit target, not just
  that the containers are up. `syslog-forwarding-simulation` (part of
  `full-setup-deep-validate.yml`) is the reusable proof for this — invoke it directly
  or via `gh workflow run` rather than re-deriving a new check.
- Confirm the healthcheck limitation this project has already documented for itself
  (`AG-VAL-023`'s netdata precedent, and `syslog`'s own compose-file comment): a
  binary-presence healthcheck (`fluent-bit -V`, `syslog-ng-ctl healthcheck`) proves
  the binary is intact, not that the tailing pipeline actually works — validate the
  pipeline directly (a real log line arriving at the target), don't trust the
  healthcheck alone.

### 9. Resource-Leak / Cleanup Pass (standing check, run every release)

Framing note: this project is written in Rust (memory-safe), so the classic
C-style heap-leak question does not apply the same way. The resource-leak concern
that **does** apply, and must be checked explicitly every release, is whether
processes, containers, connections, and file descriptors are actually released when
a service is removed, rotated, or restarted — not merely that the API call that
triggered the removal/rotation/restart returned success.

| What to check | How to check it for real | Pass/fail |
|---|---|---|
| A removed/rotated NATS secondary's live connection is actually gone, not just access-revoked | Reuse `scripts/nats-secondary-auth-callout-simulation.sh`'s `connz`-polling pattern from PR #1172: after removal, poll `nats-server`'s own `connz` HTTP monitor endpoint until the connection entry disappears — do not stop at the HTTP 200 from the removal API | Fail if the connection lingers in `connz` past a reasonable poll window |
| Watchdog-restarted containers leave no orphaned process/connection from the pre-restart instance | After a watchdog-triggered restart (Part B §7), `docker exec <host or a diagnostic container> ss -tnp` (or `netstat -tnp` if `ss` is unavailable) targeting the restarted service's port, confirm no stale connection to the old container's now-dead PID remains | Fail if a stale ESTABLISHED/CLOSE-WAIT connection to the pre-restart process persists |
| `docker compose down -v` genuinely removes every container and named volume for the stack | `docker ps -a --filter "name=lancache"` and `docker volume ls --filter "name=lancache"` immediately after teardown — both must return empty | Fail if any lancache-prefixed container or volume remains |
| A resized/rotated proxy container (cache-resize, PR #1174) doesn't leave the old container running alongside the new one | `docker ps --filter "name=lancache-proxy"` immediately after a convergence-triggered recreate — exactly one container, with a `StartedAt` matching the recreate, not two | Fail if more than one `lancache-proxy` container is running, or the old one's `StartedAt` is unchanged (recreate didn't actually happen) |
| No file-descriptor exhaustion from repeated watchdog restart cycles over a longer soak | `docker exec <container> ls /proc/1/fd \| wc -l` sampled before and after several forced restart cycles of the same service — should return to a stable baseline, not grow monotonically | Fail (flag for investigation) if FD count trends upward across cycles rather than stabilizing |

---

## Current Known Feature-Specific Checks (dated 2026-07-24 — prune/update every release)

This section names the concrete new features merged on 2026-07-24 that the Standing
checks above were written to cover generically. It exists so a future validator
knows *why* a given Standing check row exists and can retire the specific example
once it stops being new, without deleting the durable check itself:

- DHCP dnsmasq-relay mode (PR #1117, closes #844) — first real relay mode alongside
  ProxyDHCP; `scripts/dhcp-relay-flow-simulation.sh` is its canonical proof.
- NATS active-disconnect on secondary removal/rotation (PR #1172, closes #681) — closes
  a documented up-to-90-day access window; `connz`/`KICK` proof via the extended
  `nats-secondary-auth-callout-simulation.sh`.
- NATS auth-callout xkey encryption (PR #1168, closes #682) — packet-capture proof
  with a negative control, same script.
- Watchdog NATS monitoring (PR #1167, refs #842) — hung-container detection via
  external `SIGSTOP`; also surfaced #1166 (open, non-blocking) as a side effect.
- Admin UI watchdog health-dashboard card (PR #1165, closes #870) — live green/red
  transitions driven by a real container stop/start.
- Admin UI cache-resize capability (PR #1174, refs #1069 — deliberately `Refs`, not
  `Closes`, since #1069's expanded scope is only partially covered) — `nginx -T`
  rendered-config proof; known `deploy/prod` misleading-display gap.
- `setup.sh reset-to-last-known-good-config dns`/`pdns` (PR #1152, closes #836) — real
  CLI-driven PowerDNS zone rollback via `scripts/setup-reset-dns-config-simulation.sh`.
- Edition-2024 bump across all three Rust crates (PR #1179, closes #1178) — real
  fixes required (rustfmt style-edition drift, `unsafe` env-var-mutation annotations,
  collapsible-if-let clippy fixes), not a clean drop-in; validate on the real
  build-tools-container Linux target, not a Windows-side `cargo check`.
- Per-release CycloneDX SBOM + OpenVEX document (PR #1194, refs #1130) — drift guard
  (`scripts/check-vex-drift.sh`) already proven once against a real mismatch; the
  live GitHub Releases API upload path itself has **not** yet been exercised
  end-to-end (see Coverage Assessment below).
- `migrate_env_for_update()` key-drift guard (PR #1199, closes #1197) — mechanical
  bats guard, proven once against a reintroduced historical gap (`NTP_ENABLED`).
- CI build-tools path-filter narrowing + permissions hardening (PRs #1190/#1202/#1204)
  — verify via `check-bats-path-filter-coverage.sh`/`check-workflow-service-lists.sh`.
- Governance/OSPS-baseline docs: AGPL-3.0-or-later adoption (#1145/#1180),
  MAINTAINERS.md (#1182), OSPS Baseline Level 3 docs (#1185), various SECURITY.md/
  CONTRIBUTING.md updates (#1189/#1193/#1196) — manual doc-vs-code drift review per
  `AG-DOC-001`, no automated check exists yet.

## Coverage Assessment (from this survey — be honest about gaps)

**Well-covered, reusable, real proofs already exist for:**

- DHCP Kea lease flow, dnsmasq ProxyDHCP PXE options, and the new dnsmasq-relay mode
  (all three have a real E2E simulation script, not just config-render unit tests).
- NATS secondary lifecycle including both of today's new hardening mechanisms
  (active-disconnect, xkey) — both proven with negative controls, which is exactly
  the rigor this document asks for elsewhere.
- The SBOM/VEX drift guard and the `.env` key-drift bats guard — both already
  proven once against a real induced failure, on 2026-07-24, by an earlier agent
  pass; this document's job is to make sure that proof gets *reused*, not re-derived,
  every release.
- File-header, naming-consistency, and bats-path-filter-coverage CI guards — all
  mechanical, all scriptable, all already exist and run today.

**Genuinely under-tested today — do not assume these are covered without a fresh,
explicit pass:**

- **Admin UI cache-resize's full loop** (dashboard submission → `.env` write →
  `lancache-converge.service` tick → `docker compose up -d` recreate → nginx actually
  enforcing the new size) has never been run start-to-finish as a single live E2E
  proof — PR #1174 explicitly states this ("Could not run: a live end-to-end ...
  cycle"). The `deploy/prod` misleading-display gap is *documented* but not fixed.
  **Partially advanced, 2026-07-24** (still not fully closed — see below): confirmed
  live that a real UI form submission (`POST /cache/resize`) correctly persists
  `CACHE_MAX_GB` into the `ui-data` volume's `lancache-ui-settings.env`, and that
  `lancache-converge.service`'s ExecStart is actually **two separate steps**, not one —
  `setup.sh converge-reconcile <install_dir>` (merges the UI override into the deploy
  `.env`; confirmed live this correctly wrote `CACHE_MAX_SIZE`/`CACHE_MAX_GB`) followed by
  a distinct, pre-existing container-drift-convergence `ExecStart` line that actually runs
  `docker compose up -d` to recreate the drifted container. On a host with no
  `lancache-converge` systemd units installed (any manual `docker compose` bring-up, not a
  real `setup.sh install`), running `bash setup.sh converge-reconcile <install_dir>`
  by hand exercises step 1 only — `nginx -T` will still show the old `max_size` until
  something also runs `docker compose up -d proxy` (step 2). This pass did not run step 2
  against a real convergence-driven recreate, so `nginx -T`'s rendered `max_size` was
  **not** confirmed to change — the headline claim of this check remains unproven; do not
  record this subsystem as validated on the strength of step 1 alone.
- **`release-sbom`'s actual GitHub Releases API upload path** (PR #1194) has never
  been exercised against the live API — only the Trivy CycloneDX command and the
  shellchecked upload heredoc bodies were verified in isolation. This needs a real
  tag-triggered release run before being trusted.
- **Watchdog's `restart_container()` curl-timeout-vs-grace-period race** (#1166) is
  a known, open, non-blocking bug that produces a false-negative warning log on a
  slow-to-stop container — validators must know to cross-check `StartedAt` rather
  than trusting the warning literally.
- **Netdata-alarm → Admin UI notification integration** remains entirely unbuilt (PR
  #1165 explicitly marks this half of the original dashboard vision as still open,
  `docs/bug-hunt/observability.md` finding #3 "PARTIALLY FIXED").
- **The DNS reset-to-known-good E2E** (PR #1152) has only ever been run with two
  environment deviations in place (a locally built image, a patched healthcheck probe
  domain) due to the since-fixed #1150 bug — the *unmodified* real CI path for this
  script has never actually completed clean; confirm that on the next run rather than
  assuming it now works unmodified.
- **Kea/PDNS/NATS config-writer idempotence** is still manual-review-only per
  `.github/AGENTS.md`'s own enforcement matrix (`AG-OP-006`/`AG-OP-007` row) — only
  the `.env`-migration path and watchdog's restart-counter convergence have real
  repeat-run fixture coverage.
- **This document's own Validation State Tracking mechanism** (`docs/validation-
  state.json`) is brand new as of this PR — it starts with every field `null` and has
  not yet been exercised by a real validation pass. The first real run against it is
  itself a gap until it happens.

---

## Appendix — Reusable Scripts/Commands Index

| Script / command | Proves |
|---|---|
| `scripts/dhcp-relay-flow-simulation.sh` | Real two-segment DHCP relay (PR #1117) |
| `scripts/nats-secondary-auth-callout-simulation.sh` | NATS secondary lifecycle, active-disconnect (`connz`/`KICK`), xkey encryption (packet capture + negative control) |
| `scripts/setup-reset-dns-config-simulation.sh` | Real CLI-driven PowerDNS zone rollback (PR #1152) |
| `scripts/setup-reset-kea-config-simulation.sh` | Real CLI-driven Kea config rollback |
| `scripts/generate-vex.sh` / `scripts/check-vex-drift.sh` | OpenVEX document reproducibility and drift detection (PR #1194) |
| `tests/bats/setup_update_idempotence.bats` (first `@test`) | `.env` key-drift guard (PR #1199) |
| `scripts/check-idempotence-test-coverage.sh` | Every stateful config-writer has repeat-run/idempotence test coverage |
| `scripts/check-bats-path-filter-coverage.sh` | Every real bats dependency is covered by `build-tools.yml`'s path filters |
| `scripts/check-workflow-service-lists.sh` | Hardcoded service arrays stay in sync across workflow files |
| `scripts/check-naming-consistency.sh` | Container-name/allowlist/env-var naming contract (`docs/naming-conventions.md`) |
| `scripts/check-file-headers.sh` | File-header contract (`AG-HDR-*`) |
| `scripts/classify-image-impact.sh` | The single source of truth for "which subsystem does this diff touch" — reused by this document's own staleness reasoning, `detect-changes`, and the `promote` job's version-bump logic |
| `scripts/validate-stack-images.sh` | Release-notes/workflow status-line consistency |
| `scripts/select-build-tools-image.sh` | Resolves the pinned build-tools image/digest for every container-based check above |
| `scripts/full-setup-client-simulation.sh` | Full-setup harness client-side probe |
| `gh workflow run full-setup-validate.yml --repo wiki-mod/lancache-ng --ref <branch>` | Manually triggers the `workflow_dispatch`-only stack-simulation suite (does not run automatically on PRs) |
