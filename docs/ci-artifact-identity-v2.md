# CI artifact identity v2

This document describes the opt-in matching-numbers CI path implemented by
`.github/workflows/ci-artifact-v2.yml`. It intentionally runs beside the
existing production pipeline until the dependency PRs named in the Draft PR,
plus the required live proof, are complete.

The candidate workflow can be exercised on a same-repository Draft PR through
the temporary `ci-v2-test` label. That PR entry point is test scaffolding. It
can build and validate quarantine candidates, but it is structurally unable to
publish a reusable accepted stack pointer.

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
platform children, the artifact source SHA, and the source fingerprint for one
candidate source commit.

`candidate-validation/v1` is a PR-only proof record. It explicitly states
`accepted:false` and `promotion_eligible:false`. It proves that the quarantine
candidate completed the configured validation gates without allowing a
synthetic PR workflow identity to become a reusable baseline.

`stack-acceptance/v1` is the reusable acceptance record. A normal accepted
pointer uses a unique tag shaped like
`accepted-v2-<source SHA>-<run id>-<attempt>`, so rerunning the same source
commit never overwrites a prior accepted pointer.

## Build provenance without changing the child identity

The platform build intentionally sets Buildx `provenance: false`. An attested
single-platform Buildx result can otherwise be an OCI index containing the
runtime manifest plus an attestation manifest. That wrapper index is not the
runtime child digest the matching-numbers pipeline needs to carry forward.

V2 therefore records the real single-platform runtime digest first and
publishes build provenance separately with `actions/attest`, bound to that
exact child digest. Multi-platform assembly later combines only the recorded
amd64 and arm64 runtime child digests.

## Source fingerprint and reuse

Reuse requires more than a path classifier verdict. `scripts/ci-source-fingerprint.sh`
computes a stable SHA-256 fingerprint over the source-controlled Docker inputs:

- the Docker context tree Git object,
- the Dockerfile blob,
- every named BuildKit context declared by the canonical image catalog,
- the effective weekly `APT_CACHE_BUST` value when that Dockerfile declares
  the corresponding build argument.

The commit SHA itself is deliberately not included, so two commits can prove
equivalent image source inputs. The artifact's original source SHA is still
stored separately and is never rewritten.

`scripts/ci-write-candidate-record.sh` recomputes the fingerprint after the
build. If the effective refresh input changed between planning and record
creation, such as crossing an ISO-week boundary, the run fails instead of
recording a fingerprint that does not describe the build that actually ran.

A service can be reused only when all of the following are true:

1. the baseline pointer passes the reusable-acceptance trust boundary below;
2. the baseline source commit is an ancestor of the current source commit;
3. `scripts/classify-image-impact.sh` reports that service unchanged;
4. the accepted and current source fingerprints are identical;
5. the accepted lock contains both required platform child digests.

Any missing or ambiguous proof falls back to a build.

## Reusable-acceptance trust boundary

`scripts/ci-extract-stack-lock.sh` first freezes a supplied accepted tag to an
OCI digest and then reads the pointer by that digest. It validates the lock and
acceptance schemas, recomputes the stack-lock SHA-256, and requires lock and
acceptance to name the same source commit.

Structural JSON validity is not enough. Reusable acceptance is allowed only
when the record names `refs/heads/current_dev` or `refs/heads/master`.
`scripts/ci-verify-acceptance-attestation.sh` then performs cryptographic
GitHub artifact-attestation verification against the exact pointer digest and
requires all of the following to match:

- repository `wiki-mod/lancache-ng`,
- signer workflow `.github/workflows/ci-artifact-v2.yml`,
- final-acceptance predicate type,
- the protected source branch ref from `acceptance.json`,
- the exact source commit from `acceptance.json`,
- the full signed predicate, equal to the embedded `acceptance.json` after
  canonical JSON parsing.

The verifier does not trust an ambient `gh` installation on a self-hosted
runner. `scripts/ci-install-gh-attestation-verifier.sh` downloads GitHub CLI
v2.97.0 and verifies the official release-asset SHA-256 for amd64 or arm64
before use.

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

## Complete runtime deep validation

The exact digest-locked full-setup harness does not contain every production
runtime service. Final acceptance therefore also requires two existing,
service-specific integration paths against the unique candidate tag, with the
entire tag set verified against the frozen stack lock immediately before and
after each simulation:

- `scripts/ntp-cap-sys-time-simulation.sh` proves the candidate NTP image can
  execute its real CAP_SYS_TIME clock-discipline path on a GitHub-hosted VM;
- `scripts/syslog-forwarding-simulation.sh` runs the complete quickstart and
  central-logging path using the candidate runtime tag and the exact
  build-tools digest from the stack lock. This covers the quickstart service
  set including syslog, DHCP, and DHCP proxy behavior already exercised by
  that mature simulation.

The reusable `.github/workflows/full-setup-sims.yml` suite remains an
additional gate. Final acceptance requires the exact locked-stack gate, both
runtime-deep gates, and the supplemental full-setup suite.

## Acceptance

PR validation stops at a non-promotable proof record. Reusable acceptance runs
only on an explicit `workflow_dispatch` whose source ref is protected and is
exactly `current_dev` or `master`.

The protected-branch acceptance job downloads every platform security/smoke
evidence record and requires a complete evidence set whose digest for each
service/platform equals the stack lock. It re-resolves every candidate
transport tag immediately before acceptance.

Only then does it create `stack-acceptance/v1`, build the multi-platform
metadata pointer containing `stack-lock.json` and `acceptance.json`, attach
pointer provenance to the exact pointer digest, and publish the custom final
acceptance attestation last.

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
best-effort rollback to the previous digests. No service image is rebuilt.

## Security refresh

`ci-security-refresh-v2.yml` cryptographically extracts an accepted stack and
re-runs Trivy against the exact accepted child digests with the current
vulnerability database. Refreshed security evidence is attached to those same
OCI digests through the GHCR attestation retry path. A stale vulnerability
verdict therefore causes a rescan, not a rebuild.

## Release

`ci-release-accepted-v2.yml` consumes a cryptographically verified accepted
runtime lock. The release Git tag must resolve to the accepted source commit.
Runtime services are never rebuilt.

Repository governance separately requires `build-tools:<release tag>`. The v2
release path currently accepts that tag only when it resolves to the exact
already-accepted build-tools index and platform child digests. It deliberately
fails closed if the release tag contains a distinct rebuild rather than copying
the accepted artifact's old source fingerprint onto different bytes. A future
integration with the release build-tools producer must provide a signed
identity record for that distinct digest before this restriction can be safely
relaxed.

Every release child digest is freshly scanned and native-smoked, and an SPDX
JSON SBOM is generated and attached to that exact digest through the GHCR SBOM
attestation retry wrapper.

Publication defaults to validation/SBOM-only. When the literal `PUBLISH`
confirmation is supplied, the release path still performs no mutable reference
move until the release stack pointer has already been built under a unique
`accepted-v2-release-*` tag and has both pointer provenance and release
acceptance evidence.

Only then does the workflow acquire the same global promotion mutex used by
normal channel promotion. The final critical section records previous runtime
release refs, moves runtime release refs to the recorded digests, moves the
coherent stack release pointer last, reads every final digest back, and attempts
best-effort rollback if a partial publication fails.

## Regression coverage

`tests/bats/ci_artifact_identity.bats` is the durable regression suite for the
confirmed defects found while implementing this path. In addition to schema and
catalog tests, it checks the protected-branch reuse policy, the PR/non-promotable
boundary, single-platform provenance separation, active-service health polling,
release pointer-before-reference ordering, and the shared-lock/rollback
requirements for promotion and release.

The v2 plan job runs Bash syntax checks, ShellCheck, actionlint, the repository
workflow line/byte limit guard, and this Bats suite inside the immutable
published build-tools image selected by `scripts/select-build-tools-image.sh`.

## Registry lifecycle

This path publishes quarantine platform tags, unique candidate index tags, and
immutable accepted stack pointers. It does not enable package deletion.
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
