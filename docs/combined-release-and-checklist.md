# Combined Release and Checklist

This document is the single reference for releasing lancache-ng: the
release-channel contract, the handling of external images, the provenance
evidence of a release, and the validation hurdles a release candidate has to
pass before it is released.

Valid for `current_dev` at `e223782d`. Section 11.4 lists what is not
verified.

## Contents

1. [Sources of truth](#1-sources-of-truth)
2. [Release model](#2-release-model)
3. [External images](#3-external-images)
4. [Promotion, tags and releases](#4-promotion-tags-and-releases)
5. [Setup and update selection](#5-setup-and-update-selection)
6. [Provenance, SBOM and VEX](#6-provenance-sbom-and-vex)
7. [Rollback and retention](#7-rollback-and-retention)
8. [Validation layers](#8-validation-layers)
9. [Part A: CI gates](#9-part-a-ci-gates)
10. [Part B: live stack scenarios](#10-part-b-live-stack-scenarios)
11. [Coverage, scope and verification status](#11-coverage-scope-and-verification-status)
12. [Release checklist](#12-release-checklist)

---

## 1. Sources of truth

| What | Owner |
| --- | --- |
| Image inventory, channels, retention, platforms, base images | SOT `.github/yaml/build-manifest.yml` |
| Gates, error codes, promotion, tagging, garbage collection | `.github/scripts/ci.sh` (workflows only call it) |
| Workflows | `ci.yml`, `nightly.yml`, `release.yml`, `gc.yml`, `codeql.yml` |
| Install and update behavior | `setup.sh` |
| Binding rules | `AGENTS.md` (`AG-LAW-001`) |

This document names SOT keys and does not copy their values, except where a
value is part of the operator contract.

---

## 2. Release model

lancache-ng releases are stack releases. Runtime service images are not
promoted independently. A consumable channel tag identifies one coherent stack
built from the same source commit and the same release gate.

### 2.1 Package set

| Package | SOT entry | Content |
| --- | --- | --- |
| `services` | `services` | watchdog, syslog-ng, chrony, cachehamster |
| `proxy` | `services` | nginx cache proxy |
| `dns` | `services` | PowerDNS in HTTP and HTTPS mode |
| `dhcp` | `services` | Kea or dnsmasq (proxy or relay), one mode at a time |
| `ui` | `services` | Admin UI |
| `build-tools` | `build_toolchain` | CI and developer validation toolchain |

There is no metadata or pointer package. A channel is the same tag on every
first-party image, moved together by one promotion.

### 2.2 Tags and channels

| Tag | Meaning | Mutability |
| --- | --- | --- |
| `sha-<full-sha>` | One source commit; always the full 40-hex SHA (SOT `release.tag_commit`) | Immutable |
| `nightly` | `current_dev`, moved by `nightly.yml`; experimental, not for production | Mutable |
| `vX.Y.Z-rc.N` | Release candidate | Immutable |
| `vX.Y.Z` | Release | Immutable |
| `latest` | `master`; release tags `vX.Y.Z` move it (SOT `release.install_channel`) | Mutable |

- The mutable channels are exactly `latest` and `nightly`
  (SOT `release.channels`).
- `LANCACHE_IMAGE_CHANNEL=edge` and `=dev` are rejected with an error that
  names the valid channels (SOT `release.retired_channels`).
- `pinned` is a valid `LANCACHE_IMAGE_CHANNEL` value for one specific
  immutable tag. The interactive picker does not offer it.
- A short `sha-` tag is rejected. A build-identity tag uses the prefix
  `identity-` (SOT `release.tag_identity_prefix`), never `sha-`.

### 2.3 Branches and channels

| Branch | Channel | Rule |
| --- | --- | --- |
| `master` | `latest` | Publishes after the required checks pass. Release tags `vX.Y.Z` move `latest`. |
| `current_dev` | `nightly` | A normal push publishes the per-commit `sha-<full-sha>` tags only. `nightly` moves through `nightly.yml` (section 4.2). |
| archived `vX.Y.Z` branches | none | Frozen; they publish no live channel. |

**Direction of flow (maintainer decision, 07.11.2026 11:19 CET).**
`current_dev` always wins over `master`:

- `master` is always stale. `current_dev` runs ahead; `master` catches up
  through a release, never the other way round.
- A change made on `master` is history only. It never flows back into
  `current_dev`: nothing is backported or ported from `master` to
  `current_dev`, and doing so breaks AG-REL-013 (section 4.5).
- At a release, `master` is overwritten with the released state of
  `current_dev`. The state that applied at the time of the release is
  preserved in an immutable `release/*` ref (write-protected when created,
  AG-REL-014).

A search of `ci.sh` and the workflows on `current_dev` (`e223782d`) finds no
step that overwrites `master` or creates a `release/*` ref: `release.yml`
publishes tags, and the archived `vX.Y.Z` branches are the existing frozen
refs.

`schedule:` triggers run only from the workflow file on the default branch
(AG-CI-018). `nightly.yml` therefore refreshes `nightly` on schedule only from
the default branch; the manual dispatch works from any branch.

### 2.4 Platforms

The supported prebuilt platforms are the SOT `build_matrix.platforms`
(`linux/amd64`, `linux/arm64`). A build target may narrow the list and never
widen it. `setup.sh` stops before pulling prebuilt images when:

- the host architecture is not x86_64/amd64 or aarch64/arm64, or
- the resolved tag does not publish a manifest for the host architecture
  (checked with `docker buildx imagetools inspect`).

Adding a platform requires the SOT list, the `setup.sh` platform guard and the
validation to change together.

---

## 3. External images

External images are not part of the first-party stack tag. Their owner is the
SOT `base_images` block:

| SOT key | Role |
| --- | --- |
| `base_images.alpine` | Base of the first-party images and of `build-tools`; `setup.sh` helper image |
| `base_images.buildkit` | BuildKit daemon of the image builds |
| `base_images.trivy` | Trivy image; `ci.sh` copies the binary out |

- nginx, PowerDNS, syslog-ng, chrony, Kea and dnsmasq are apk packages inside
  the first-party images, not external images. The per-image SBOM lists them.
- A compose image outside the `${LANCACHE_*}` first-party references has to
  equal a SOT `base_images` value. `ci.sh check sot-external-images`
  reports every other value with `CI-ERROR-CHECK-0014`.
- No workflow step runs in a foreign container. A job runs in its own
  `build-tools` image, or, on a native host, through exactly one `docker run`
  of that image (`ci.sh build-tools-run`). `ci.sh check all` fails a
  `docker://` step that is not a SOT `base_images` value.
- GitHub Actions are named in the SOT `github_actions` block and are used with
  their major tag `vN` (AG-CI-001). The tag lives in `uses:`.
- Mutable external tags are not authoritative release records. A mirrored or
  repackaged external image carries the project's own provenance and SBOM for
  the mirrored digest.

---

## 4. Promotion, tags and releases

### 4.1 Promotion

Public channel tags move only after the full first-party package set has been
built and checked. GHCR has no transaction across packages, so `ci.sh promote`
works like this:

1. It takes the promote lock, the git ref below
   `release.promote_lock_ref` (`refs/ci/promote-lock`), one per channel.
2. It moves nothing for an incomplete or not validated stack.
3. It moves every image's channel tag.
4. It moves already moved tags back to their earlier digest when a later move
   fails.
5. When that move back fails, or a moved service had no earlier digest, the
   channel stays mixed. Then the run keeps the promote lock and marks its note
   `mixed` (`CI-ERROR-PROMOTE-0043`). `setup.sh` waits while the lock exists,
   `gc-refs` keeps a mixed lock, and the next promote run takes it over and
   moves the whole stack again. A run that finds the channel already complete
   frees a mixed lock.

Order of a release:

1. build and scan the full package set;
2. publish the immutable `sha-<full-sha>` images;
3. verify that every required image exists for the same commit;
4. promote the channel that belongs to the event;
5. create or update the release notes from the same package set.

If one required image is missing, the channel is not promoted. `promote-ref`
promotes every target the current ref maps to and refuses a moved branch tip.

`ci.sh validate` assembles the stack candidate of a pull request from exact
image digests: a changed service uses the digest built for its new identity, an
unchanged service reuses the digest accepted for that identity. Nothing is
retagged or pulled from a mutable channel to complete the stack.

On every push, `ci.sh assemble-stack` assembles the built services and every
service the plan did not build. An unchanged service gets the index of its
accepted digests under the new `sha-<full-sha>` tag; nothing is rebuilt. So a
`sha-<full-sha>` pin finds all five images (AG-REL-009).

### 4.2 `nightly`

- `nightly.yml` runs on schedule (`23 3 * * *`, UTC) and on
  `workflow_dispatch`. GitHub Actions cron has no time zone.
- Both paths validate the accepted `current_dev` stack and then run
  `ci.sh promote nightly`. `nightly` is never rebuilt.
- Promotion refuses an incomplete or not validated stack, so `nightly` keeps
  its last good state while `current_dev` is broken.

### 4.3 Release candidates and releases

| Tag | Result |
| --- | --- |
| `vX.Y.Z-rc.N` | GitHub prerelease; promotes only its own tag; never moves `latest` |
| `vX.Y.Z` | GitHub release; also moves the channels marked `release_tags: true` in the SOT (`latest`) after the full package set passed the release gate |

`release.yml` runs on a pushed `v*` tag and on `workflow_dispatch`. Its jobs:

| Job | Runs |
| --- | --- |
| `resolve-build-tools`, `plan`, `validate` | image resolution, plan, stack validation |
| `promote` | `promote-ref` |
| `release` | `release-changelog`, `release-images`, `release-publish`, `release-variable`, `release-vex` |
| `release-provenance` | one `actions/attest` per image digest named by `release-images` |
| `release-sbom` | `release-sbom-stack` |
| `cut-release-tag` | `cut-release-tag` (dispatch only) |

- `release-publish` creates a GitHub release once; a repeat only compares
  (AG-REL-014: CI never edits a published release).
- `release-changelog` writes the change list of a stable tag to `CHANGELOG.md`.
- `release-variable` sets `PROJECT_RELEASE_VERSION` to a stable tag.

### 4.4 Patch tags

`ci.sh cut-release-tag` cuts the next patch tag. It runs only for an explicit
`workflow_dispatch` of `release.yml` with `action: cut-patch`, because a tag
cut needs its own authorization (AG-REL-013). It refuses (exit 2) when:

- the event is not `workflow_dispatch` (`CI-ERROR-RELEASE-0039`);
- the ref is not the release ref (`CI-ERROR-RELEASE-0040`);
- no previous release tag exists; the first release tag is cut by hand
  (`CI-ERROR-RELEASE-0041`);
- the release ref tip is unreadable (`CI-ERROR-RELEASE-0016`) or moved during
  the run (`CI-ERROR-RELEASE-0042`).

Otherwise it pushes the annotated tag `vX.Y.(Z+1)` with the
`PROJECT_AUTOMATION_PAT` secret and prints `cut-tag=pushed`. A tag pushed with
the default `GITHUB_TOKEN` would not start the `v*` workflows, so the PAT is
required. Minor and major bumps are never automated (AG-REL-013).

### 4.5 Hard sequence for a promotion to `master` (AG-REL-013)

1. `master` is stale; the promotion replaces it with the state of
   `current_dev`. Nothing is backported or ported from `master` to
   `current_dev`; a backport or port is a rule violation.
2. The promotion pull request needs fresh green CI, including `validate`
   (AG-REL-011, section 8). Its invalidation triggers are checked directly;
   an invalidated state needs a fresh validation run first.
3. The promotion merge needs its explicit maintainer authorization.
4. Release-tag creation is a separate post-merge action with its own
   authorization.

---

## 5. Setup and update selection

`LANCACHE_IMAGE_CHANNEL` selects a mutable channel. `LANCACHE_IMAGE_TAG` is the
resolved immutable tag that Docker Compose pulls. Setup and update only pull
prebuilt first-party images; they never build the runtime stack, so build
accelerators are not part of the install contract.

| Situation | Behavior |
| --- | --- |
| fresh install | `latest` (SOT `release.install_channel`); `nightly` is offered with an experimental warning, shown again on every update |
| release archive | its own `vX.Y.Z` or `vX.Y.Z-rc.N` tag |
| `setup.sh update` | keeps the selected channel and refreshes the resolved `LANCACHE_IMAGE_TAG` |
| migration | adds missing image selector values |

Registry and namespace selectors and their defaults:

```env
LANCACHE_IMAGE_REGISTRY=ghcr.io
LANCACHE_IMAGE_PREFIX=wiki-mod/lancache-ng
LANCACHE_IMAGE_CHANNEL=latest
LANCACHE_IMAGE_TAG=sha-<full-sha>
```

A mutable channel resolves per image to
`ghcr.io/wiki-mod/lancache-ng/<image>:<channel>`. For every
`LANCACHE_IMAGE_REF_*` image of `deploy/prod/docker-compose.yml`, `setup.sh`:

1. reads the channel digest twice while the channel's promote lock is free;
2. accepts only two equal reads;
3. writes `LANCACHE_IMAGE_REF_<NAME>=<image>@<digest>`.

Docker Compose therefore pulls digests, never a mutable tag, and an install
never mixes two stacks while a promotion runs. A held lock or two different
reads retry after `release.install_lock_poll_seconds` (10), at most
`release.install_lock_tries` (30) times.

---

## 6. Provenance, SBOM and VEX

A release publishes the evidence below and claims no evidence the pipeline does
not produce.

| Evidence | Produced by |
| --- | --- |
| Provenance attestation per first-party image digest | `release-provenance` (`actions/attest`) |
| CycloneDX SBOM per image, asset `<service>.cdx.json` | `release-sbom` (`ci.sh release-sbom-stack`), Trivy against the digest |
| OpenVEX document, asset `vex.openvex.json` | `release-vex` (`ci.sh release-vex`) from the tag's own `.trivyignore.yaml` |

A release re-run never replaces an attached asset: an asset already attached
has to equal the one derived now, otherwise the job fails; a missing asset is
uploaded and read back.

### 6.1 Verifying provenance

The attestation binds the image digest to the workflow run (repository,
workflow file, commit) that built it. Resolve the tag to its digest, then
verify:

```bash
digest=$(docker inspect --format='{{index .RepoDigests 0}}' \
  ghcr.io/wiki-mod/lancache-ng/proxy:sha-<full-sha>)
gh attestation verify "oci://${digest}" --owner wiki-mod
```

Repeat for every first-party image. If verification reports no matching
attestation, or a builder identity outside `wiki-mod/lancache-ng`, treat the
image as unverified and do not deploy it.

### 6.2 Vulnerability disposition (VEX)

Accepted findings live in the repository-root `.trivyignore.yaml`. `ci.sh`
(`_ci_generate_vex`) turns each entry into one OpenVEX v0.2.0 statement:

| Entry | Statement |
| --- | --- |
| no `status` | `affected` with an `action_statement` carrying the acceptance rationale (accepted, tracked risk) |
| `status: not_affected` | `not_affected` with a `justification` (default `vulnerable_code_not_present`) and an `impact_statement` |

The reader parses the file with `yq` and accepts a YAML mapping whose entries
use only the keys `id`, `statement`, `status`, `justification` and `paths`,
with string values and `paths` as a list of strings. Any other key, status or
shape fails closed (`CI-ERROR-RELEASE-0035`).

`vex.openvex.json` is not committed. It is derived entirely from
`.trivyignore.yaml` and generated at release time. `ci.sh check vex-drift` runs
the generator on the checked-out file and requires one statement per entry.

---

## 7. Rollback and retention

Roll back with an immutable `sha-<full-sha>` or `vX.Y.Z` tag. Backups record
the image revisions before an update.

Retention is decided by reachability, not by a count budget. `ci.sh gc` decides
it; `gc.yml` runs it on schedule (`43 */3 * * *`, every three hours) and on
`workflow_dispatch`, with `--apply`. The policy values are the SOT
`release.retention` keys. `gc.yml` also runs `gc-refs --apply` (green refs of
closed pull requests, ended locks, dead marks) and
`check orphaned-branches`.

### 7.1 Protected roots

| Root | Reason |
| --- | --- |
| every acceptance-ledger record, in any state (git ref `CI_LEDGER_REF`) | a pending record is not garbage |
| every mutable channel of every build target | a channel protects the digest it points at now |
| the release tags of the newest `release.retention.keep_release_lines` release lines, plus `migration_releases` | released digests are not garbage |
| the layer-cache tags of every build target and platform | the cache is live |
| the index children of all of these | removing children orphans platform images |

A failed read of any root is UNKNOWN: the run stops and deletes nothing. An
empty root set also stops the run.

### 7.2 Verdict and deletion

Candidates are the GHCR versions of the SOT build targets only. Each gets one
verdict:

| Verdict | When |
| --- | --- |
| KEEP | the digest is a protected root |
| KEEP | it is a `sha256-<subject>` referrer (attestation, SBOM) of a protected root |
| KEEP | it is younger than `release.retention.unaggregated_grace_minutes` |
| DELETE | otherwise |

A candidate that cannot be classified stops the run. Without `--apply`, the
run only prints verdicts. With `--apply` it deletes only when
`release.retention.deletion_policy` is `manual-or-approved-automation-only` and
GHCR authentication is present (`gc.yml` passes `GHCR_PACKAGE_DELETE_PAT`).
Right before each delete the candidate is classified again; a candidate that is
referenced now is kept and logged.

---

## 8. Validation layers

A release candidate is validated on two layers:

| Layer | Content |
| --- | --- |
| **CI** | the automated gates of the five workflows (Part A, section 9). Every workflow job only calls `.github/scripts/ci.sh`; gates, error codes and raw output live there. |
| **Stack** | the running product. `ci.sh validate` starts the `deploy/prod` stack in an isolated /27 network on the runner host and runs the live probes named in section 9. Part B (section 10) covers the scenarios that need a real Linux host on a real LAN. |

Neither layer replaces the other. A green CI run does not prove the live stack,
and a working live stack does not prove that the gates catch a regression. A
check counts only if it can fail: every gate has a case that passes and a case
that fails (AG-INT-002).

Rules that refer to this document: AG-VAL-027 (a runtime service is part of
the running-stack validation), AG-VAL-029 (a confirmed bug, CI failure or
infrastructure incident gets its root cause fixed; existing coverage is reused,
a new check needs a shown gap and its authorization, and a class without
practical automation is listed in section 11 with reason and manual
validation), AG-VAL-033 (a runtime behavior change updates its scenario) and
AG-REL-011 (release readiness never rests on a stale or invalidated record).

Release readiness rests on the CI run of the exact commit: `result-gate`
passed and the `validate` job started the stack and passed its probes. There is
no hand-written validation record; a run on another commit does not count.

---

## 9. Part A: CI gates

### 9.1 Where the gates run

| Workflow | Jobs | Trigger |
| --- | --- | --- |
| `ci.yml` | `plan`, `build`, `cargo-audit`, `test`, `aggregate`, `assemble`, `validate`, `promote`, `close-linked-issues`, `checks`, `pr-admin`, `result` | pull request, push to `current_dev` and `master`, new issue, dispatch |
| `nightly.yml` | `platform`, `plan`, `build`, `aggregate`, `assemble`, `validate`, `cargo-audit`, `nightly`, `channel-check`, `scan`, `report` | schedule, dispatch |
| `release.yml` | `resolve-build-tools`, `plan`, `validate`, `promote`, `release`, `release-provenance`, `release-sbom`, `cut-release-tag` | `v*` tag, dispatch |
| `gc.yml` | `platform`, `gc`, `orphaned-branches` | schedule, dispatch |
| `codeql.yml` | `impact`, `analyze` | pull request, push, schedule, dispatch |

- `ci.sh result-gate` judges the `result` job: every phase of the SOT
  `ci_result_gate.required` list has to have run and succeeded.
- The `checks` job runs `ci.sh checks-plan`, which selects the guards whose
  input globs (SOT `ci_check_inputs`) changed, and then `ci.sh check all`.
  `ci.sh check <name>` runs one guard; the guard list is the `CI_CHECKS` table
  in `ci.sh`. A guard that `check all` does not run prints `<name>=NOT-RUN`
  with its reason.
- `nightly.yml` checks out `release.channels.nightly.source_ref` once in
  `platform`; later jobs pin that commit (`channel-checkout nightly <commit>`).
  Tags, labels, diffs, promotion and release key on the checked-out commit
  (`_ci_head_commit`).
- The `channel-check` job runs once per mutable channel of SOT
  `release.channels`. `channel-check` pulls the channel by its tag and starts
  the stack; a lost channel image fails before a user pulls. Nothing is
  rebuilt. `channel-report` files or closes the issue of that channel alone
  (label `channel-check-<channel>`). A dispatch with `channel` checks only that
  channel; `only-channel-check` skips `plan` and `cargo-audit`.
- The `scan` job of `nightly.yml` runs `scan-stack` and `scan-channel`, so an
  image that no build rebuilds is still scanned again.

### 9.2 Standing checks per subsystem

| Subsystem | Gate | Fails when |
| --- | --- | --- |
| DHCP (Kea) | `ci.sh validate` Kea leg (`_ci_validate_kea_rollback`: two Admin UI reservations, `setup.sh` rollback to the first snapshot, live `config-get`) | the rollback leaves the second reservation in Kea's running config |
| DNS | `ci.sh validate` (`_ci_validate_dns`: a real `dig`, the HTTP and HTTPS answers differ; `_ci_validate_dns_rollback`: snapshot and rollback round trip) | no answer, identical answers in both modes, or a rollback that does not revert the record |
| Zone transfer | `ci.sh validate` (`_ci_validate_ui_dns`: an Admin UI record resolves in both modes; `_ci_validate_secondary_identity`: the register answer carries TSIG key and primary) | the record never resolves, or two secondaries share an identity |
| Proxy cache | `ci.sh validate` (`_ci_validate_proxy`: a real MISS, then a HIT); `check proxy-cache-env-doc-drift`; `check proxy-cert-volume` | the second request is not a HIT, a documented `CACHE_*` default differs from the shipped one, or the cert directory is not a named volume |
| Proxy routing and TLS | `ci.sh validate` (`_ci_validate_proxy_stream_map`: a wildcard SNI forwards to the requested name; `_ci_validate_https_mitm`: the HTTPS-mode certificate is issued by the LAN CA; `_ci_validate_https_dispatch_map`: a depth >= 2 SNI takes the passthrough relay); `check proxy-nginx-policy` | a probe differs, or `/healthz` serves through `return` instead of `alias` |
| Stack bring-up | `ci.sh validate` waits for every service it starts and ships state and logs of a failing one; `check compose-config`; `check compose-healthchecks` | a service is unhealthy or restarting, a compose file does not render, or a service has no healthcheck |
| `setup.sh` | `check setup-update-safety`, `check prod-state-wiring`, `check prebuilt-prod`, `check image-channel-resolution` | a guard reports a finding |
| Images and supply chain | `scan-stack` scans the published digest; `check vex-drift`; `check mutable-refs`; `check sot-external-images`; `check cargo-audit` | `.trivyignore.yaml` does not yield a complete OpenVEX document, a reference is mutable, or a dependency is vulnerable or yanked |
| Channels and release | `promote-ref` supersede check | a moved branch tip is promoted |
| Rust services | `test-stack` runs `cargo fmt --check`, `cargo clippy -- -D warnings` and `cargo test` per crate only when enabled; off by default (AG-VAL-008); `cargo check` is a manual developer step | a Rust check fails when enabled |
| Repository guards | `ci.sh check all` (guards of the diff, repo and, with `PR_NUMBER` set, pull request scope) | a guard reports a finding |

`ci.sh validate` starts every `deploy/prod` service that does not use host
networking. `dhcp` runs with `network_mode: host`, cannot be isolated in the
/27 network and is left out of the stack start (`CI-INFO-VALIDATE-0055`).

---

## 10. Part B: live stack scenarios

End-to-end scenarios against the running stack on a real Linux Docker host on a
real LAN. `ci.sh validate` covers the probes of section 9; the scenarios below
cover what it does not reach. Project tooling runs in the matching
`build-tools` environment (AG-VAL-016); product checks run against the stack
itself. `ping`, `ss` or an open port alone never prove DNS or proxy health
(AG-VAL-013, AG-VAL-014).

### 10.1 Bring-up

1. Use a real `setup.sh install`, not a direct `docker compose up`. `setup.sh`
   installs the checkout's `deploy/prod` (AG-KD-008). `docker compose up` exits
   0 even when a container later crash-loops, so check `docker compose ps` and
   `docker inspect --format='{{.State.Health.Status}}' <container>` per
   container.
2. On a Linux host with Docker, Compose v2 and `expect`, derive the current
   prompt sequence with `bash setup.sh list-prompts <answers-file>` (no root or
   Docker required). Without a detected LAN address the server-IP prompt has no
   default, so the answers file names it; `list-prompts` fails instead of
   looping when a prompt rejects its answer.
3. Feed that sequence through `expect` to run `bash setup.sh install`; without a
   command `setup.sh` only prints its usage. A real install needs root. Set
   `LANCACHE_IMAGE_CHANNEL` and `LANCACHE_IMAGE_TAG` only as a per-command
   environment prefix on this one invocation, never exported process-wide.
4. Expect `Stack started`; `Failed to pull required container images` is the
   documented failure.
5. Check that all five containers (`services`, `proxy`, `dns`, `dhcp`, `ui`)
   are healthy.

Further requirements:

- `deploy/prod/docker-compose.yml` is the one deployment profile. It references
  images by `image:`, not `build:`, and declares no compose profile: all five
  services always start.
- A channel tag can point at an older commit than the one under test. Pin
  `sha-<full-sha>` through `LANCACHE_IMAGE_TAG`. The
  `org.opencontainers.image.revision` label names the commit whose CI run built
  the content; an image reused for unchanged content keeps that commit.
- Tear down after the full pass with
  `docker compose -f deploy/prod/docker-compose.yml down -v`; section 10.9
  checks the result.

### 10.2 DNS resolution in both modes

| Mode | DNS address | Proxy address | Pass |
| --- | --- | --- | --- |
| HTTP | `IP_HTTP` | `IP_HTTP` | the CDN name resolves to the proxy; TLS to port 443 is passthrough: the presented certificate is the real CDN's, not the project CA |
| HTTPS (MITM) | `IP_HTTPS` | `IP_HTTPS` | the CDN name resolves to the proxy; the presented certificate is signed by the project CA |

- Query with `dig @<address> <cdn domain>`. Check TLS with
  `openssl s_client -connect <proxy>:443 -servername <cdn domain>`; in HTTPS
  mode add `-CAfile <ca.crt>`.
- Port 443 is what a client connects to. `deploy/prod` publishes the HTTP-mode
  port 443 to the container passthrough port (SOT `NGINX_PASSTHROUGH_PORT`).
- The CA is in the directory the proxy mounts at `/etc/nginx/ssl/ca`; for
  `deploy/prod` that is `$CA_DIR/ca.crt`. A wrong path fails with a misleading
  error that looks like broken interception.
- Not every domain of `services/dns/cdn-domains.txt` resolves publicly from
  every network. If a domain gives no answer from a public resolver either,
  pick another entry before concluding that DNS or the proxy is broken.
- Wildcard scope (AG-OP-015): the proxy half is in CI. The DNS half is live
  only: pick a wildcard-only entry (`.example.com`) from
  `services/dns/cdn-domains.txt` or a scratch entry and query the wildcard's
  bare root, a subdomain and an unrelated domain. Pass: only the subdomain
  resolves to the proxy, unless the bare root is listed on its own.
- Upstream DNS (`DNS_UPSTREAM_SERVERS`, `DNS_UPSTREAM_ZONES`,
  `DNS_UPSTREAM_UNSIGNED_ZONES`) is set by `setup.sh install` or
  `./setup.sh configure-upstream-dns`:

  | Case | Input | Pass |
  | --- | --- | --- |
  | none | `DNS_UPSTREAM_SERVERS` empty | a public name resolves from the root servers |
  | change | `configure-upstream-dns` with a LAN resolver for zone `.` | the three keys are in the local env file, `dns` is recreated, the liveness check (`dns_upstream_is_live`) succeeds and a private name of that resolver answers |
  | DNSSEC kept | as change, private zone unsigned, `DNS_UPSTREAM_UNSIGNED_ZONES` empty | the private name gives `SERVFAIL`; `dnssec-failed.org` gives `SERVFAIL` |
  | unsigned zone | as before, `DNS_UPSTREAM_UNSIGNED_ZONES=<private zone>` | the private name answers; `dnssec-failed.org` still gives `SERVFAIL` |
  | loop | `127.0.0.1` or `IP_HTTP` | the entry is rejected, no upstream resolver is used and public names resolve as in none |
  | no address | `not-an-ip` | the entry is rejected, as in none |
  | bad unsigned zone | `DNS_UPSTREAM_UNSIGNED_ZONES=.` | the entry is rejected, as in none |
  | dead resolver | `configure-upstream-dns` with an address that runs no DNS | `setup.sh` reports the failed check and restores the three earlier values |

### 10.3 DHCP in all three modes

The `dhcp` container runs Kea or dnsmasq, one mode at a time (`DHCP_MODE`), on
the host network. The wire-level checks need a real LAN.

| Mode | Pass |
| --- | --- |
| Probe | the Admin UI DHCP page (`POST /dhcp/check`) shows `conflict` (other DHCP servers that offered) and `client` (whether the exchange completed); no answer within the wait time shows `unavailable` |
| Kea | a LAN client completes DISCOVER, OFFER, REQUEST, ACK; the address lies in the pool; the client receives the configured DNS and NTP options (AG-OP-014); a static reservation added through the Admin UI applies to the next lease of that MAC; the Admin UI rollback (`/dhcp/kea-rollback`) restores the earlier snapshot |
| dnsmasq ProxyDHCP | a PXE client receives the boot filename and next-server options; a non-PXE client receives none |
| dnsmasq relay | between two segments, the client's lease comes from the client subnet's pool through the relay's `giaddr`, not from a same-subnet fallback |
| One mode at a time | `DHCP_MODE` selects exactly one rendered dnsmasq or Kea config; inspect the rendered config inside the running container, not only the variable |
| Sub-mode switch | switching `dnsmasq-proxy` and `dnsmasq-relay` on the Admin UI `/dhcp/mode` form makes dnsmasq run with the new sub-mode while the container keeps running |

CI covers the Kea snapshot and rollback against Kea's running config; the
lease effect is live only.

### 10.4 Cache hit and miss

- Request a real CDN file through the proxy twice. The second response is a
  cache HIT (`$upstream_cache_status` in the nginx access log, or an
  `X-Cache-Status` header when configured) with bytes identical to the miss.
- The cache key ignores query-string signatures (AG-OP-001): the same path with
  two different query strings is served from one entry (the second request is a
  HIT).
- In HTTP mode only HTTP is cached. HTTP-mode HTTPS is a blind passthrough
  (`ssl_preread` reads the SNI without terminating TLS), so nginx cannot cache
  it or add `X-Cache-Status`; do not attempt a HIT/MISS proof there.
- In HTTPS (MITM) mode intercepted HTTPS is cached. The cache is shared across
  all three reachable paths (HTTP in HTTP mode, HTTP and HTTPS in MITM mode)
  because the key is `$host$uri`.

Hurdles:

| Hurdle | Pass | Fail |
| --- | --- | --- |
| An HTTP-only origin works (nginx fetches with the client's scheme) | a file from a host without port 443, requested twice through port 80: both `200`, the second a HIT, bytes identical | any `502`, or `proxy_pass` fixed to `https://`; negative probe: set the scheme back to `https://` on a scratch stack and confirm the step fails |
| An origin error is never cached | after a request that fails at the origin, the next request for the same URL reaches the origin again | a HIT on a `5xx` (only `404` may be held, see `proxy_cache_valid`) |
| The upstream resolver answers | after a download run the proxy log has no resolver failure; the default list is IPv4 only (`NGINX_UPSTREAM_RESOLVER`, `ipv6=off`) | a resolver address the host cannot reach turns every uncached lookup into a timeout |
| The Admin UI shows the cache size | after the cached download the Dashboard cache storage is greater than 0 GB | `0.0 GB` with a non-empty cache |

### 10.5 Zone transfer (secondary lifecycle)

CI covers the Admin UI to PowerDNS API write path and the register answer.
With real secondaries on a real stack:

- **Transfer**: a secondary pulls the zone by TSIG-signed AXFR after NOTIFY; an
  unsigned AXFR is refused.
- **Removal**: a removed secondary no longer appears on the dashboard; the
  others keep working.
- **Record removal**: a record deleted through the Admin UI stops resolving in
  both DNS modes; on the AXFR secondary the authoritative zone converges first,
  then the recursor answer expires within its cached TTL.

### 10.6 Admin UI

| Check | Pass |
| --- | --- |
| Reachability | `curl -u <user>:<pass> http://<ui host>:<port>/` succeeds. Without `UI_AUTH_USER` and `UI_AUTH_PASSWORD` and without `ALLOW_INSECURE_UI=true` the UI fails closed and restart-loops with `Admin-UI authentication is required` (AG-SEC-001); that is expected |
| Container health on the dashboard | stop a monitored container and wait one watchdog round; its entry turns unhealthy (`GET /api/status`) and healthy again after a restart; a stale or missing status renders as stale or unavailable, never as the last known color |
| Cache resize | change `CACHE_MAX_GB` on the Setup page and wait for the `lancache-converge.timer` run; `setup.sh converge-reconcile` writes the value into the runtime env and the proxy is recreated. Pass: `docker exec <proxy container> nginx -T` shows the new `max_size=` on `proxy_cache_path`; an HTTP `200` or `303` from the form is not the proof |
| Self-restart | `POST /api/restart-ui` (restart button) ends the UI process; compose `restart: always` starts it again. Pass: `docker inspect --format '{{.State.StartedAt}}' "$(docker compose -f deploy/prod/docker-compose.yml ps -q ui)"` is later and the page reloads |
| Start and stop of a container | the beam bar posts `{"state": "running"}` or `{"state": "stopped"}` to `POST /api/container/{service}`. Pass: a stopped service is listed as stopped by the user, the others stay healthy, Start brings it back |

### 10.7 Watchdog

The watchdog (`services/watchdog`) lists every container of the compose project
and reads its Docker health each round (`CHECK_INTERVAL`).

- A container whose health is failing for `RESTART_AFTER` rounds in a row is
  restarted through the Docker API, unless the restart limit is reached; a
  reached limit is a critical finding.
- A service stopped by the user (`SERVICES_STOPPED`) and `dhcp` while
  `DHCP_MODE=off` are not wanted and are never counted.
- Findings go to the alarm file that the Admin UI shows; the watchdog's own
  healthcheck is the freshness of that file
  (`CHECK_INTERVAL` times `RESTART_AFTER`).
- Hang check: run `docker top <container> -o pid`, then `kill -STOP` every
  listed PID from outside the container (root or `sudo`).
  `docker kill --signal=STOP` signals only PID 1 and the programs keep
  serving. `docker pause` marks the container
  unhealthy without running a probe (`FailingStreak` stays 0) and proves no hang
  detection. Pass: a real `FailingStreak` increase from failed probes (not
  only a `Status` flip) and a restart (new `StartedAt`).

### 10.8 Central logging

- One syslog-ng runs inside the `services` container. Every container logs
  through Docker's `syslog` driver (RFC 5424) to the loopback address and
  `LANCACHE_LOG_PORT` of the SOT; files land in
  `${SYSLOG_NG_LOG_DIR}/LanCache-NG-<service>/YYYYMMDD.log`. There is no
  separate syslog container. Pass: real log lines of `proxy`, `dns`, `dhcp` and
  `ui` arrive there.
- Logging is switched per service (`LOGGING_PROXY_ENABLED`,
  `LOGGING_DNS_ENABLED`, `LOGGING_DHCP_ENABLED`, `LOGGING_UI_ENABLED`, default
  `1`) on the Admin UI `/logs` page. Switch one service off: only its directory
  stops growing; the others and `LanCache-NG-services/` keep growing.
- With the proxy switch off the proxy access log gets no new lines, and the
  Admin UI statistics show no new traffic.
- Silent log loss: when logs arrive but no file is written, the watchdog
  reports a finding (`log_writing`). Live check: make the log root unwritable
  for syslog-ng and confirm the finding. `setup.sh` pre-creates and chowns the
  log root on a fresh install.

### 10.9 Resource release

The classic memory-leak question does not apply to Rust. What has to be
checked every release is whether processes, containers, connections and file
descriptors are released when a service is removed, rotated or restarted, not
only that the triggering call returned success.

| What | How | Fail when |
| --- | --- | --- |
| A watchdog-restarted container leaves no orphaned connection of the pre-restart instance | after a restart (section 10.7) run `ss -tnp` (or `netstat -tnp`) for the service's port | a stale `ESTABLISHED` or `CLOSE-WAIT` connection to the pre-restart process persists |
| `docker compose down -v` removes every container and named volume | `docker ps -a --filter "label=com.docker.compose.project=lancache-ng"` and `docker volume ls --filter "label=com.docker.compose.project=lancache-ng"` right after teardown | either command lists anything |
| A recreated proxy (cache resize) leaves no second container | `docker compose -f deploy/prod/docker-compose.yml ps -a proxy` right after the recreate | more than one `proxy` container, or the old `StartedAt` is unchanged |
| No file-descriptor growth over repeated restarts | `docker exec <container> ls /proc/1/fd \| wc -l` before and after several forced restarts | the count grows monotonically instead of returning to a baseline (flag for investigation) |

### 10.10 NTP

`chronyd` runs inside `services` while `NTP_ENABLED` is true (off in the SOT)
and the service is not stopped by the user; `NTP_UPSTREAM_SERVERS` and
`NTP_ALLOWED_CLIENT_CIDRS` configure it. Clock discipline is live only.

- With `NTP_ENABLED=1` (compose grants `services` the `SYS_TIME` capability),
  force a clock skew. Pass: `chronyc tracking` inside `services` returns to a
  `Leap status` of `Normal` with a stratum above 0. On a host that denies
  setting the clock (a nested or LXC host), record what `chronyd` logs.
- Change the upstream list on the Admin UI Setup page while NTP is enabled.
  Pass: `chronyc sources` lists the new servers.

### 10.11 `setup.sh update`

A `setup.sh` without its channel code next to it (fetched alone) first clones
that channel and continues with the channel's `setup.sh`, so a v0.3 quickstart
install is migrated. `setup.sh update` (`cmd_update`, `perform_stack_update_flow`) captures a health
baseline, takes a config backup, pulls the checkout and continues on the pulled
`setup.sh` (`update_repo_and_resume`), migrates `.env`
(`migrate_env_for_update`), pulls the images and applies the update service by
service with health gates (`apply_stack_update_ordered`); a failure rolls the
stack back (`rollback_stack_update`). The flow never runs
`docker compose down -v`, so named volumes and bind mounts stay.

1. Bring a stack up with `setup.sh install` (section 10.1).
2. Record each service's image ID (`docker inspect <image> --format '{{.Id}}'`)
   and `StartedAt`.
3. Run `bash setup.sh update`.
4. Pass: at least one image ID changed (a real pull), `StartedAt` advanced for
   every recreated container, and the contents of the `proxy-cache`, `ui-data`
   and `watchdog-status` volumes are unchanged.
5. Negative control: force a health-gate failure of one non-UI service (section
   10.12) and confirm that `rollback_stack_update` restores the pre-update
   state.

### 10.12 Update health gate

`capture_stack_health_baseline` samples each service's health three times before
the update and records it as healthy only if every sample agrees.
`wait_for_stack_health` fails the gate only for a service that was healthy
before (or has no baseline) and is unhealthy now.

| What | How | Pass |
| --- | --- | --- |
| A service already unhealthy before the update does not roll the update back | bring a stack up with a `docker-compose.override.yml` that makes one service (not `proxy` or `dns`) fail its healthcheck before and after the update; run `setup.sh update` | the update completes with `Proceeding despite service(s) unhealthy before this update started too` |
| A real regression rolls the update back | on a stack with every non-UI service healthy, add an override that makes one healthy service (not `proxy` or `dns`) fail its healthcheck after recreation; run `setup.sh update` | `Service(s) regressed from healthy to unhealthy during this update: <service>` and `rollback_stack_update` restores the backup |

---

## 11. Coverage, scope and verification status

### 11.1 Covered failure classes (durable check exists)

| Failure class | Durable check |
| --- | --- |
| Kea rollback leaving a reservation in the running config | `_ci_validate_kea_rollback` |
| DNS split routing lost (HTTP and HTTPS answer alike) | `_ci_validate_dns` |
| DNS rollback that does not revert or snapshot the restored state | `_ci_validate_dns_rollback` |
| Admin UI record not reaching PowerDNS in both modes | `_ci_validate_ui_dns` |
| Secondary register answer without TSIG key or primary | `_ci_validate_secondary_identity` |
| Wildcard SNI forwarded to a fixed root | `_ci_validate_proxy_stream_map` |
| Depth >= 2 SNI intercepted instead of relayed | `_ci_validate_https_dispatch_map` |
| HTTPS mode not intercepting | `_ci_validate_https_mitm` |
| `/healthz` ACL bypassed by `return` | `check proxy-nginx-policy` |
| Documented `CACHE_*` default drifting from the shipped one | `check proxy-cache-env-doc-drift` |
| Cache not serving a HIT | `_ci_validate_proxy` |
| A service crash-looping after `docker compose up` exits 0 | the health and stability wait of `ci.sh validate` for every service it starts |
| A `.trivyignore.yaml` entry not yielding a complete OpenVEX statement | `check vex-drift` |
| Live pipe into an early-exit consumer under `pipefail` (exit 141); `$?` read from an `if` | `check shell-guards` |
| Review chronology, stale line references, or a comment, heredoc or YAML text block breaking the What/Why/From contract | `check comments` |
| A bats `[ ] && [ ]` check that cannot fail | `check bats-and-chain` |
| An exit path losing its code, context or raw output | `check exit-evidence` |
| Mutable image or action reference | `check mutable-refs`; `check action-node-versions` |
| Two jobs of one run computing two identities for one target and platform | `_ci_identity_compute` runs only in a planner scope and fails closed beside a given `CI_RUN_IDENTITIES`; every other reader goes through `_ci_identity_for` |

### 11.2 No durable check

- Kea config render or migration drift; dnsmasq directive or template-key
  drift; a torn shared-config write; a missing stream-level client ACL on a
  listener.
- A `.env` migration that is not idempotent, rotates a secret or duplicates a
  key (`migrate_env_for_update`); an update that continues on the old
  `setup.sh` after a pull (`update_repo_and_resume`).
- An image revision label or index tag naming another commit than the built
  tree (`_ci_head_commit`); a scheduled channel run building the default branch
  instead of its source ref (`channel-checkout`).
- A validation environment binding the SOT state root instead of the per-run
  root (`_ci_validation_env`); a rollback leg handing `setup.sh` no per-run
  state root (`_ci_validate_setup_rollback`).
- A Trivy gate reading an unrecorded or stale database
  (`_ci_trivy_db_ensure_fresh`, `_ci_trivy_db_record`); a Trivy ignore entry
  that matches nothing (`scan-channel` and `_ci_trivyignore_stale`; a subset run
  prints `ignore-stale=NOT-RUN`).
- A LAN-only distribution scheduler or distcc hosts reaching a GitHub-hosted
  build (`_ci_set_runtime`); concurrent BuildKit builds on a shared self-hosted
  daemon (AG-CI-017).
- A build-identity tag starting with `sha-` (`_ci_image_tag`); a short
  `sha-` pin accepted as a commit pin (`release.tag_commit`).
- Two readers of the needs object classifying results differently
  (`_ci_needs_pairs`, `_ci_needs_class`); a zombie sccache server read as a live
  one (`_ci_sccache_reap`); a refresh run reusing an image whose apk packages
  the index has newer (`_ci_package_refresh_all`).
- A scan of another image than the published digest (`scan-stack` scans
  `_ci_published_digest`); a case-sensitive repository-name comparison
  (`_ci_repo`); closing keywords read outside the linked-issues section
  (`_ci_pr_section`).
- A Trivy finding, database outage or scan error that no issue reports; an
  image that no build rebuilds that is never scanned again (`scan-channel`); a
  released digest without a provenance attestation (`release-provenance`); a
  report step that does not start because the judged job failed (`report`
  job); a required-check gate that passes a skipped phase without a reason
  (`result-gate`).
- The `setup.sh` DHCP activation preflight (`run_kea_dhcp_activation_preflight`)
  has no CI check.
- The `setup.sh update` health baseline and regression gate: section 10.12 is
  live only.
- Dockerfile lint (`docker buildx build --call check`) runs in no job; `FROM
  ${VAR}` without a global `ARG`; a bare `!` inside a bats loop body; GNU-only
  constructs in Alpine or BusyBox images (AG-VAL-034); a proxy `slice` with a
  cached 301 or 302.
- Upstream DNS not reaching the recursor, or a wrong value not falling back:
  section 10.2 is live only.
- `check actionlint` has no per-command kill bound; the job timeout from the
  SOT applies. Comment claims drifting from code (`check comments` checks
  structure only) and third-party reviewer output language (AG-CC-004) are
  manual review. GC reachability (`ci.sh gc`): neither its argument guard nor
  its classification has a check.

### 11.3 Live-only scenarios

Covered only by Part B (section 10):

- wire-level DHCP in all three modes, the lease effect of an Admin UI
  reservation and the dnsmasq sub-mode switch (10.3);
- the DNS half of the wildcard scope rule and the upstream DNS change (10.2);
- secondary zone transfer and removal (10.5);
- the dashboard health card, cache resize, Admin UI self-restart and container
  start and stop (10.6);
- watchdog hang detection and restart (10.7);
- central logging (10.8);
- resource release on removal, rotation and restart (10.9);
- NTP clock discipline (10.10);
- `setup.sh install` and `setup.sh update` on a running stack (10.1, 10.11,
  10.12).

### 11.4 Open verification

Not verified against the code or a live stack:

- the exact log wording and status files of the supervisor-based scenarios (the
  dnsmasq sub-mode switch, the NTP upstream change, the container start and stop
  effect on the supervised programs) in sections 10.3, 10.6 and 10.10;
- the upstream DNS rejection log lines and the rendered recursor configuration
  in section 10.2;
- the dashboard cache-size source and the `FailingStreak` hang check (10.4,
  10.7);
- the rollback of already moved channel tags and the double digest read of
  `setup.sh` (sections 4.1 and 5);
- that a release re-run never replaces an attached asset, and that the SBOM is
  generated in Trivy CycloneDX mode (section 6);
- the `sha256-<subject>` referrer rule, the delete re-classification and the
  `release.retention` behavior beyond the values named (section 7);
- the proxy behavior of section 10.4 (blind passthrough in HTTP mode, shared
  cache key `$host$uri`, the four hurdles);
- the `setup.sh update` flow of sections 10.11 and 10.12;
- the pass criteria of sections 10.5, 10.8 and 10.9.

### 11.5 Failure classes from the release run

The scenario (Part B or 12.1) is the recurrence check. One row per
failure class.

| Failure class | Scenario | Fix |
| --- | --- | --- |
| `DHCP_PROXY_INTERFACE` without schema row: Kea opens no socket | 10.3 | `dd8aa722` |
| secondary TSIG set as API metadata: PowerDNS refuses, no transfer | 10.5 | `9365bd5f` |
| empty `DHCP_DNS_SERVERS`: empty DNS option to clients | 10.3 | `df805036` |
| zone transfer and NOTIFY on port 53 instead of the pdns port | 10.5 | `14948d8d` |
| new `pdns.conf` without pdns restart | 10.5 | `edfdef9f` |
| unanswering upstream DNS server stays active | 10.2 | `805fb763` |
| unrequested container stop shown gray, not red | 10.6 | `27dbfaec` |
| `log_writing` counter without `dst.file` rows is always 0 | 10.8 | `49f15bd7` |
| `DHCP_PROXY_PXE_*` missing in the ui environment: no PXE offer | 10.3 | `3a6be729` |
| dnsmasq sub-mode switch restarts the dhcp container | 10.3 | `4aafe168` |
| file check set without PR labels: changelog rule always fails | 12.1 | `cc5748c8` |
| PR into master reads build-tools `latest`: plan fails | 12.1 | `da958b3d` |

---

## 12. Release checklist

Tick every item for the commit under test. An item without evidence is not
ticked.

### 12.1 Before the release

- [ ] The release candidate commit is the tip of the release source branch.
- [ ] CI is green on the commit: `result-gate` passed, `ci.sh check all` has no
  finding, `validate` passed, `scan` reports no unreported finding.
- [ ] Every image of the package set exists for the commit as
  `sha-<full-sha>`, for every platform of `build_matrix.platforms`.
- [ ] Section 4.5 is followed: nothing backported or ported from `master`,
  promotion pull request has fresh green CI, the maintainer authorization of
  the promotion merge is recorded.
- [ ] The documentation matches the resulting behavior (AG-DOC-001), including
  this document and `AGENTS.md` references to it.

### 12.2 Part B pass (live stack on a real LAN)

- [ ] 10.1 Bring-up: `Stack started`, five healthy containers.
- [ ] 10.2 DNS in both modes, wildcard scope, upstream DNS cases.
- [ ] 10.3 DHCP in all three modes and the probe.
- [ ] 10.4 Cache: HIT in HTTP and MITM HTTPS, query-string key, the four
  hurdles.
- [ ] 10.5 Zone transfer: signed transfer, unsigned refusal, removal.
- [ ] 10.6 Admin UI: reachability, health card, cache resize, self-restart,
  container stop and start.
- [ ] 10.7 Watchdog: restart after `RESTART_AFTER` failing rounds, hang check.
- [ ] 10.8 Central logging: all four services arrive, per-service switch.
- [ ] 10.9 Resource release: no orphan connection, no leftover container or
  volume, one proxy container, stable file descriptors.
- [ ] 10.10 NTP clock discipline.
- [ ] 10.11 and 10.12 `setup.sh update` and the update health gate, including
  the negative control.

### 12.3 Release

- [ ] The release tag is created after the promotion merge, with its own
  maintainer authorization (AG-REL-013).
- [ ] The release tag matches `vX.Y.Z` or `vX.Y.Z-rc.N`; a release candidate
  creates a prerelease and does not move `latest`.
- [ ] `promote-ref` moved the channels.
- [ ] The GitHub release exists with the SBOM assets (`<service>.cdx.json` per
  image) and `vex.openvex.json`.
- [ ] `gh attestation verify "oci://<digest>" --owner wiki-mod` succeeds for
  every first-party image digest of the release.
- [ ] The `channel-check` job of `nightly.yml` passed for `latest` and
  `nightly` (section 9.1).

---

## Appendix: commands

| Command | Proves |
| --- | --- |
| `bash .github/scripts/ci.sh validate` | the running-stack validation for the accepted stack candidate, inside the `build-tools` container (AG-VAL-016) |
| `bash .github/scripts/ci.sh check all`, `check <name>` | the guards of the diff, repository and (with `PR_NUMBER`) pull request scope, or one named guard |
| `bats .github/scripts/ci.bats` in the `build-tools` image | the regression suite |
| `gh attestation verify "oci://<digest>" --owner wiki-mod` | provenance of one image digest |
| Admin UI DHCP page (`POST /dhcp/check`) | the DHCP conflict and client probe |

## Howto audit this file

The audit procedure of this file is `docs/policy/howto-audit-documentation.md`.
