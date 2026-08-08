# CI artifact identity v2

This document describes the opt-in matching-numbers CI path implemented by
`.github/workflows/ci-artifact-v2.yml`. It intentionally runs beside the
existing production pipeline until maintainers have enough live evidence to
replace the old path.

The candidate workflow can be tested on this Draft PR through the temporary
`ci-v2-test` PR label. After the workflow has landed on the default branch it
can also be run explicitly through `workflow_dispatch`. The temporary PR-label
entry point is test scaffolding and must be reviewed again before this path is
made production-authoritative.

## Invariant

An OCI digest is the artifact identity. A tag is only a reference to an
identity. Once a platform candidate has a digest, every security check, native
platform smoke, multi-platform assembly, locked-stack validation, acceptance,
promotion, security refresh, and release operation refers to that exact digest
or to an index assembled exclusively from recorded child digests.

The state transition is:

`BUILT or REUSED -> SECURITY_PASSED -> PLATFORM_SMOKE_PASSED -> INDEX_ASSEMBLED -> STACK_LOCKED -> FULL_STACK_VALIDATED -> ACCEPTED`

Any failed gate stops before `ACCEPTED`. Rejected candidates therefore never
receive a final acceptance record or final acceptance attestation.

## Records

`image-candidate-platform/v1` records one service/platform digest, the current
candidate source SHA, the artifact's actual origin SHA, and whether it was
built in the current run or reused from a previously accepted stack. Reuse
never rewrites origin identity to pretend old bytes were built from a new
commit.

`image-candidate-index/v1` records the multi-platform index digest plus the
exact amd64 and arm64 child digests used to assemble it.

`stack-lock/v1` freezes every runtime and tooling index digest and its two
required platform children for one source commit. Full-stack validation renders
Compose with digest-qualified runtime references from this lock.

`stack-acceptance/v1` is created last. It contains the SHA-256 hash of the
stack lock, the unique immutable accepted tag, and a complete final gate map.
Normal candidate acceptance uses a unique tag shaped like
`accepted-v2-<source SHA>-<run id>-<attempt>` so rerunning the same source
commit never overwrites the previous accepted pointer.

## Build provenance without changing the child identity

The platform build intentionally sets Buildx `provenance: false`. On an
attested single-platform build, Buildx can otherwise return an OCI index whose
children are the actual runtime manifest plus an attestation manifest. That
wrapper index is not the runtime child digest the matching-numbers pipeline is
trying to carry forward.

V2 therefore records the real single-platform image digest first and publishes
build provenance separately with `actions/attest`, bound to that exact child
digest. Multi-platform assembly later combines only the recorded amd64 and
arm64 runtime child digests.

## Reuse trust boundary

Reuse is fail-closed. `scripts/ci-extract-stack-lock.sh` first freezes any
supplied accepted tag to an OCI digest, pulls and reads the pointer by that
digest, validates both JSON schemas, recomputes the stack-lock SHA-256, and
requires the lock and acceptance record to name the same source commit.

A self-consistent JSON file is still not enough. The script then invokes
`scripts/ci-verify-acceptance-attestation.sh`, which downloads a
checksum-pinned GitHub CLI verifier, performs cryptographic artifact-attestation
verification against the exact stack-pointer digest, restricts the signer to
`wiki-mod/lancache-ng/.github/workflows/ci-artifact-v2.yml`, restricts the
predicate type to the final-acceptance predicate, and requires the signed
predicate to equal the embedded `acceptance.json` after canonical JSON parsing.

The GitHub CLI verifier itself is not taken from an ambient self-hosted-runner
installation. `scripts/ci-install-gh-attestation-verifier.sh` pins GitHub CLI
v2.97.0 and the official amd64/arm64 release-asset SHA-256 digests. This keeps
verification independent of whatever version happens to be installed on a
runner host.

Only after that trust proof succeeds does reuse additionally require the
accepted baseline source commit to be an ancestor of the current source and
`scripts/classify-image-impact.sh` to prove the individual service unchanged.
A missing field, unknown classifier key, non-ancestor baseline, invalid
signature, signer mismatch, predicate mismatch, or malformed digest causes a
rebuild rather than speculative reuse.

## Exact full-stack validation

`scripts/ci-render-locked-compose.sh` renders the existing full-setup Compose
model and overlays every first-party runtime image present in that harness with
`image@sha256:<digest>`. The full-setup harness is intentionally a subset of the
complete production runtime catalog, so runtime services absent from that
harness are not invented merely to make a count match.

`scripts/ci-validate-locked-stack.sh` starts the rendered model inside the
existing collision-safe validation subnet mechanism. It queries the services
that actually started, rather than profile-gated services merely present in the
Compose model, waits for runtime/health readiness, verifies that first-party
containers retained the digest-qualified references, and runs the existing
full-setup client simulation against the same rendered Compose file.

The existing reusable full-setup simulation suite also runs as a supplemental
gate using the unique per-run candidate transport tag. Final acceptance
requires both the exact digest-locked stack gate and the supplemental suite.

## Acceptance

The final job downloads every platform security/smoke evidence record and
requires a complete evidence set whose digest for each service/platform exactly
matches the stack lock. It then re-resolves every candidate transport tag to
catch a tag move before acceptance.

Only after all gates are complete does it create `stack-acceptance/v1`, build a
multi-platform metadata pointer containing `stack-lock.json` and
`acceptance.json`, attach build provenance to the exact pointer digest, and
publish the custom final-acceptance attestation last.

Build provenance, a clean vulnerability scan, a smoke test, an SBOM, or package
existence is never treated as final acceptance by itself.

## Promotion

`ci-promote-accepted-v2.yml` accepts only a positively and cryptographically
verified accepted pointer. The input tag is immediately frozen to its digest
and the lock is extracted from that digest-qualified pointer.

Promotion joins the same repository-wide `refs/promote-lock/global` mutex used
by the existing production promotion and latest-backfill paths. It verifies the
accepted source is the current tip of the selected channel branch, records the
previous digest of every mutable target, moves service/tooling references with
`docker buildx imagetools create`, writes the stack channel pointer last, and
re-reads every target digest after the writes.

If an error occurs after one or more mutable refs moved, the workflow attempts
a best-effort rollback to the previously recorded digests. No service image is
rebuilt during promotion.

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

Repository governance separately requires a tag-scoped build-tools image for a
release. The release workflow therefore resolves
`build-tools:<release tag>` to an exact index plus amd64/arm64 child digests,
inserts those identities into a release lock, and freshly scans and native
smokes every release child digest.

SPDX JSON SBOMs are generated from the exact release child digests and attached
through a GHCR SBOM-attestation retry wrapper. Publication defaults to dry-run:
release refs move only after the literal `PUBLISH` confirmation input.
Immediately before publication the governance build-tools release tag is
re-resolved and must still match the planned digest.

Runtime release refs are reference moves only. The release stack pointer is
multi-platform, carries the release lock and its complete acceptance record,
gets separate pointer provenance, and receives its release acceptance
attestation last. It is published under both the requested release tag and a
unique immutable `accepted-v2-release-*` tag.

## Registry lifecycle

This path publishes quarantine platform tags, unique candidate index tags, and
immutable accepted stack pointers. It does not enable package deletion.
Retention and destructive cleanup remain under the separately reviewed
registry-GC work. The intended policy is a small accepted history, with failed
and intermediate candidates removed aggressively only after the GC can prove
acceptance state and every protected channel/release reference without
ambiguity.

## Deliberately disabled optimization

BuildKit registry output with `push-by-digest=true,name-canonical=true` is not
enabled here. The current implementation pushes a unique quarantine tag and
immediately records the returned digest. The optimization may replace that
transport only after a real GHCR run proves project-specific pullability,
retry behavior, and attestation behavior for anonymously pushed digests.
