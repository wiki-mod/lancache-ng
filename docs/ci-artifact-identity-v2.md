# CI artifact identity v2

This document describes the opt-in matching-numbers CI path implemented by
`.github/workflows/ci-artifact-v2.yml`. It intentionally runs beside the
existing production pipeline until maintainers have enough live evidence to
replace the old path.

## Invariant

An OCI digest is the artifact identity. A tag is only a reference to an
identity. Once a platform candidate has a digest, every security check, native
platform smoke, multi-platform assembly, locked-stack validation, acceptance,
promotion, security refresh, and release operation refers to that exact digest
or to an index assembled exclusively from recorded child digests.

The state transition is:

`BUILT or REUSED -> SECURITY_PASSED -> PLATFORM_SMOKE_PASSED -> INDEX_ASSEMBLED -> STACK_LOCKED -> FULL_STACK_VALIDATED -> ACCEPTED`

Any failed gate stops before `ACCEPTED`. Rejected candidates therefore never
receive a final acceptance record or acceptance attestation.

## Records

`image-candidate-platform/v1` records one service/platform digest, the current
candidate source SHA, the artifact's actual origin SHA, and whether it was
built in the current run or reused from a previously accepted stack. Reuse
never rewrites origin identity to pretend old bytes were built from a new commit.

`image-candidate-index/v1` records the multi-platform index digest plus the
exact amd64 and arm64 child digests used to assemble it.

`stack-lock/v1` freezes every runtime and tooling index digest for one source
commit. Full-stack validation renders Compose with digest-qualified runtime
references from this lock.

`stack-acceptance/v1` is created last. It contains the SHA-256 hash of the
stack lock and asserts only gates that already passed. The accepted stack
pointer image contains both files and receives a custom GitHub attestation.

## Reuse

Reuse is fail-closed. A baseline is eligible only when
`scripts/ci-extract-stack-lock.sh` proves that the referenced stack image
contains a valid positive acceptance record whose lock hash matches, the
baseline source commit is an ancestor of the current source, and
`scripts/classify-image-impact.sh` reports the service unchanged. A missing
field, unknown classifier key, non-ancestor baseline, or malformed digest
causes a rebuild rather than speculative reuse.

## Exact full-stack validation

`scripts/ci-render-locked-compose.sh` renders the existing full-setup Compose
model and overlays every first-party runtime image with
`image@sha256:<digest>`. `scripts/ci-validate-locked-stack.sh` starts this
rendered model, waits for health, verifies the running containers retained the
digest-qualified references, and runs the existing full-setup client
simulation against the same rendered Compose file.

The existing reusable full-setup simulation suite still runs as a supplemental
gate using a unique per-run candidate transport tag. Final acceptance requires
both the exact digest-locked stack gate and the supplemental suite.

## Promotion and release

`ci-promote-accepted-v2.yml` accepts only a positively accepted stack pointer
and moves mutable channel references with `docker buildx imagetools create`.
It asserts that the resulting digest is unchanged. No service is rebuilt.

`ci-release-accepted-v2.yml` consumes the accepted runtime lock. Runtime
services are reference-moved only. Repository governance separately requires a
tag-scoped build-tools image for a release, so the release workflow requires
`build-tools:<release tag>` to already exist with amd64 and arm64 manifests,
requires the release Git tag to resolve to the accepted source commit, uses
the tag-scoped build-tools digest in the release lock, freshly scans and
native-smokes both platform child digests, generates and attests SBOMs for
those exact child digests, and publishes a release stack pointer.

## Security refresh

`ci-security-refresh-v2.yml` re-runs Trivy against the exact accepted child
digests with the current vulnerability database and emits new digest-bound
security evidence. A stale security verdict therefore causes a rescan, not a
rebuild.

## Registry lifecycle

This path publishes quarantine platform tags, a unique candidate index tag,
and immutable accepted stack pointers. It does not enable package deletion.
Retention and destructive cleanup stay under the separately reviewed registry
GC policy. The intended policy is to retain a small accepted history and remove
failed/intermediate candidates aggressively only after the GC implementation
can classify acceptance records and protected channel/release references
without ambiguity.

## Deliberately disabled optimization

BuildKit registry output with `push-by-digest=true,name-canonical=true` is not
enabled here. The current implementation pushes a unique quarantine tag and
immediately records the returned digest. The optimization may replace that
transport only after a real GHCR run proves project-specific pullability,
retry behavior, and attestation behavior for anonymously pushed digests.
