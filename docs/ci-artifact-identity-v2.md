# CI artifact identity v2

This document describes the opt-in matching-numbers CI path implemented by
`.github/workflows/ci-artifact-v2.yml`. It intentionally runs beside the
existing production pipeline until the dependency work named in the Draft PR,
plus the required live proof, is complete.

A same-repository Draft PR can exercise the candidate path through the temporary
`ci-v2-test` label. That entry point is test scaffolding. It may build, publish
quarantine transport refs, scan, and deeply validate candidates, but it is
structurally unable to publish a reusable accepted stack pointer.

## Invariant

An OCI digest is the artifact identity. A tag is only a reference to an
identity. Once a platform candidate has a digest, every security check, native
platform smoke, multi-platform assembly, stack lock, runtime validation,
acceptance, promotion, security refresh, and release operation refers to that
exact digest or to an index assembled exclusively from recorded child digests.

The candidate lifecycle is:

`BUILT or REUSED -> SECURITY_PASSED -> PLATFORM_SMOKE_PASSED -> INDEX_ASSEMBLED -> STACK_LOCKED -> FULL_STACK_VALIDATED -> RUNTIME_DEEP_VALIDATED -> ACCEPTED`

Any failed gate stops before `ACCEPTED`. Rejected candidates therefore never
receive a final acceptance record or final acceptance attestation.

## Records

`image-candidate-platform/v1` records one service/platform digest, the current
candidate source SHA, the artifact's actual origin SHA, its source fingerprint,
and whether it was built in the current run or reused from a previously
accepted stack. Reuse never rewrites origin identity to pretend old bytes were
built from a new commit.

`image-candidate-index/v1` records the multi-platform index digest plus the
exact amd64 and arm64 child digests used to assemble it, preserving the same
artifact source SHA and source fingerprint across both children.

`stack-lock/v1` freezes every runtime and tooling index digest, both required
platform children, the artifact source SHA, source fingerprint, and the
transport reference used by the current run.

`candidate-validation/v1` is a PR-only proof record. It explicitly states
`accepted:false` and `promotion_eligible:false`. It proves that the quarantine
candidate completed the configured validation gates without allowing a
synthetic PR workflow identity to become a reusable baseline.

`stack-acceptance/v1` is the reusable acceptance record. A normal accepted
pointer uses a unique tag shaped like
`accepted-v2-<source SHA>-<run id>-<attempt>`, so rerunning the same source
commit never overwrites a prior accepted pointer.

## Build provenance without changing child identity

The platform build intentionally sets Buildx `provenance: false`. An attested
single-platform Buildx result can otherwise be an OCI index containing the
runtime manifest plus an attestation manifest. That wrapper index is not the
runtime child digest the matching-numbers pipeline needs to carry forward.

V2 therefore records the real single-platform runtime digest first and
publishes build provenance separately, bound to that exact child digest.
Multi-platform assembly later combines only the recorded amd64 and arm64
runtime child digests.

## Source fingerprint and reuse

Reuse requires more than a path classifier verdict. `scripts/ci-source-fingerprint.sh`
computes a stable SHA-256 fingerprint over the effective Docker build inputs:

- the Docker context tree Git object;
- the Dockerfile blob;
- every named BuildKit context declared by the canonical image catalog;
- the effective weekly `APT_CACHE_BUST` value when that Dockerfile declares
  the corresponding build argument.

The commit SHA itself is deliberately not included, so two commits can prove
equivalent image source inputs. The artifact's original source SHA is stored
separately and is never rewritten.

Planning uses the current refresh bucket to decide whether accepted bytes remain
eligible for reuse. A new build has a stronger producer-side rule: the shared
build action persists the exact non-secret `APT_CACHE_BUST` value keyed by the
returned digest. `scripts/ci-write-candidate-record.sh` requires that marker for
a newly built digest and computes its final fingerprint from the value the
producer actually consumed. This prevents an ISO-week boundary crossed during a
long build from recording Monday's fingerprint for an image built with
Sunday's refresh input.

A service can be reused only when all of the following are true:

1. the baseline pointer passes the reusable-acceptance trust boundary below;
2. the baseline source commit is an ancestor of the current source commit;
3. `scripts/classify-image-impact.sh` reports that service unchanged;
4. the accepted and current source fingerprints are identical;
5. the accepted lock contains exactly the required amd64 and arm64 children.

Any missing or ambiguous proof falls back to a build.

## Reusable-acceptance trust boundary

`scripts/ci-extract-stack-lock.sh` first freezes a supplied accepted tag to an
OCI digest and then reads the pointer by that digest. It validates the lock and
acceptance schemas, recomputes the stack-lock SHA-256, and requires lock and
acceptance to name the same source commit.

Structural JSON validity is not enough. Reusable acceptance is allowed only
when the record names `refs/heads/current_dev` or `refs/heads/master`.
`scripts/ci-verify-acceptance-attestation.sh` then performs cryptographic
artifact-attestation verification against the exact pointer digest and
requires all of the following to match:

- repository `wiki-mod/lancache-ng`;
- signer workflow `.github/workflows/ci-artifact-v2.yml`;
- final-acceptance predicate type;
- the protected source branch ref from `acceptance.json`;
- the exact source commit from `acceptance.json`;
- the full signed predicate, equal to the embedded `acceptance.json` after
  canonical JSON parsing.

The verifier does not trust an ambient `gh` installation on a self-hosted
runner. `scripts/ci-install-gh-attestation-verifier.sh` downloads one
checksum-pinned GitHub CLI release and verifies the architecture-specific
release asset before use.

A PR run therefore cannot become reusable merely because it can publish
quarantine content or an attestation. Its `refs/pull/*` source identity cannot
satisfy the reusable protected-branch policy.

## Exact full-stack validation

`scripts/ci-render-locked-compose.sh` renders the existing full-setup Compose
model and replaces every first-party runtime image present in that harness with
`image@sha256:<digest>` from the stack lock. The harness is intentionally a
subset of the complete runtime catalog, so services absent from that Compose
model are not fabricated merely to make a count match.

`scripts/ci-validate-locked-stack.sh` starts that rendered model inside the
existing collision-safe validation subnet mechanism. It queries the services
that actually started, not profile-gated services merely present in the Compose
file, waits for readiness, verifies that first-party containers retained their
digest-qualified references, and runs the existing full-setup client
simulation against that same rendered Compose file.

## Runtime deep validation

The exact full-setup harness does not contain every production runtime path, so
final acceptance also requires the mature NTP and quickstart/logging
simulations. Their behavioral scripts remain the source of truth, but V2 wraps
their image resolution so the actual containers start from the lock:

- `scripts/ci-run-locked-ntp-simulation.sh` delegates the established
  CAP_SYS_TIME test to `ntp-cap-sys-time-simulation.sh` while replacing its
  candidate transport ref with the exact NTP digest from the stack lock;
- `scripts/ci-run-locked-quickstart-simulation.sh` delegates the complete
  quickstart/logging path to `syslog-forwarding-simulation.sh`, regenerates a
  last-wins Compose override for every active profile set, and asserts the
  running first-party containers retained their digest-qualified references.

Candidate transport tags are still re-resolved against the lock before and
after these tests. That is an additional mutation detector, not the mechanism
that defines which artifact the test runs.

## Reusable supplemental simulations

`.github/workflows/full-setup-sims.yml` remains the shared implementation for
the existing full-setup integration suite. Normal callers retain their existing
tag/channel behavior. V2 passes the same-run `stack-lock` Actions artifact via
the optional `stack_lock_artifact` input.

When that input is present, `.github/actions/enable-locked-docker` installs a
Docker CLI boundary for the job and `.github/actions/resolve-simulation-build-tools`
selects the exact build-tools digest from the lock. The Docker boundary:

- replaces direct first-party candidate transport refs with `image@digest`;
- renders each Compose invocation and adds a last-wins image override from the
  same stack lock;
- regenerates the override when profile selection changes;
- after a successful `compose up`, compares every running first-party
  container's `.Config.Image` with the expected digest-qualified reference.

Some mature proxy/DHCP simulations intentionally create purpose-specific local
fixture images because their negative controls cannot be expressed against the
stock published image. Those remain additive source-regression tests. They do
not substitute for the exact candidate gates above, and first-party published
images they consume are still subject to the lock boundary.

Final candidate acceptance requires the exact locked-stack gate, both runtime
deep gates, and the reusable supplemental suite.

## Acceptance

PR validation stops at a non-promotable proof record. Reusable acceptance runs
only on an explicit `workflow_dispatch` whose source ref is protected and is
exactly `current_dev` or `master`.

The protected-branch acceptance job downloads every platform security/smoke
evidence record and requires a complete evidence set whose digest for each
service/platform equals the stack lock. It then re-resolves every candidate
transport reference immediately before acceptance.

Only after every required gate passes does it create `stack-acceptance/v1`,
build the multi-platform metadata pointer containing `stack-lock.json` and
`acceptance.json`, attach pointer provenance to the exact pointer digest, and
publish the custom final acceptance attestation last.

Build provenance, a clean vulnerability scan, a smoke test, an SBOM, package
existence, or a PR validation proof is never final acceptance by itself.

## Promotion

`ci-promote-accepted-v2.yml` accepts only a reusable, cryptographically
verified accepted pointer. The input tag is frozen to its digest before the
lock is extracted.

Promotion joins the existing repository-wide `refs/promote-lock/global` mutex.
It verifies the accepted source is the current tip of the selected channel
branch, records the previous digest of every mutable target, moves the recorded
service/tooling references, writes the coherent stack channel pointer last,
and reads every target back after the writes.

If an error occurs after one or more refs moved, the workflow attempts a
best-effort rollback to previous digests. No service image is rebuilt.

## Security refresh

`ci-security-refresh-v2.yml` cryptographically extracts an accepted stack and
re-runs Trivy against the exact accepted child digests with the current
vulnerability database. Refreshed security evidence is attached to those same
OCI digests. A stale vulnerability verdict therefore causes a rescan, not a
rebuild.

## Release

`ci-release-accepted-v2.yml` consumes a cryptographically verified accepted
runtime lock. The release Git tag must resolve to the same source commit.
Runtime services are never rebuilt.

Repository governance separately requires a fresh, tag-scoped build-tools
artifact for each release. V2 therefore treats release build-tools as a new,
truthful tooling identity instead of pretending that different bytes are the
previous accepted artifact:

1. amd64 and arm64 build-tools children are built once from the exact release
   tag source using one frozen refresh bucket;
2. each child records its exact producer fingerprint and receives build
   provenance bound to its digest;
3. `ci-assemble-service-index.sh` assembles the multi-platform build-tools index
   from those recorded children without rebuilding them;
4. the resulting index is inserted into a release lock while every accepted
   runtime digest remains unchanged;
5. `ci-assemble-release-lock.sh` records that runtime came from the accepted
   stack and build-tools came from the fresh release build;
6. every release platform child is freshly scanned and native-smoked, and an
   SPDX JSON SBOM is generated and attested to that exact digest;
7. release build-tools additionally executes the V2 shell/Bats validation
   contract natively on both target architectures.

`ci_ai_validate_release_acceptance` requires release-specific evidence in
addition to the normal acceptance gate map, including preservation of accepted
runtime identity, the fresh release build-tools producer, tooling provenance,
and complete release exact-digest evidence.

Publication defaults to validation/SBOM-only. When the literal `PUBLISH`
confirmation is supplied, the workflow first builds the release stack pointer
under a unique `accepted-v2-release-*` tag and publishes pointer provenance plus
the release acceptance attestation. No mutable release reference has moved yet.

Only then does the workflow acquire the same global promotion mutex used by
channel promotion. Runtime and tooling release refs move to the exact digests
recorded in the release lock, the coherent stack release pointer moves last,
and all refs are read back before success is reported. If a previously existing
ref was moved before a later failure, the workflow attempts to restore its old
digest. A newly created component ref with no predecessor is explicitly
non-authoritative unless the stack release pointer also advances successfully.

## Regression coverage

The V2-specific durable regression suites are:

- `tests/bats/ci_artifact_identity.bats` for catalog/schema/reuse/acceptance and
  ordering invariants;
- `tests/bats/ci_release_identity.bats` for the fresh release tooling identity,
  release-lock assembly, and release acceptance policy;
- `tests/bats/ci_docker_lock_shim.bats` for direct tag-to-digest rewriting,
  Compose overrides, lock wiring, and preservation of real failure statuses;
- `tests/bats/network_retry.bats` for the shared external read retry contract.

The V2 plan runs Bash syntax checks, ShellCheck, actionlint, the workflow
line/byte limit guard, and its focused regression suites inside the immutable
published build-tools image selected by `scripts/select-build-tools-image.sh`.
The repository's normal Build Tools Smoke workflow additionally discovers and
runs the complete Bats tree.

## Registry lifecycle

This path publishes quarantine platform tags, unique candidate index tags,
release tooling candidate tags, and immutable accepted stack pointers. It does
not enable package deletion.

Retention and destructive cleanup remain under the separately reviewed
registry-GC work. The intended ordinary history is a small set of accepted
unique digests, while failed/intermediate candidates become cleanup candidates
only after the GC can prove acceptance state and every protected
channel/release/rollback reference without ambiguity.

## Deliberately disabled optimization

BuildKit registry output with `push-by-digest=true,name-canonical=true` remains
disabled. The implementation pushes a unique quarantine tag and immediately
records the returned digest. That optimization may replace the transport only
after a real project-specific GHCR run proves pullability, retry behavior, and
attestation behavior for anonymously pushed digests.
