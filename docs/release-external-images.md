# Release External Images and Provenance

This document records how lancache-ng handles container images that are not
built from this repository. It does not cover how a first-party release is
actually cut (channel promotion, patch tagging, platform support, rollback);
see [docs/release-versioning.md](release-versioning.md) for that process --
its own "External Images" section links back here for the per-image table
and provenance/SBOM handling below.

Reviewed against the current release pipeline (`.github/workflows/build-push.yml`)
and `release/stack-images.yml`: the image list, digests, and the provenance/SBOM
status below are accurate as of this writing (re-verified when per-image SBOM
generation and the OpenVEX vulnerability-disposition document were added, refs
#1130).

## Policy

First-party images are stack release artifacts and are tracked in
`release/stack-images.yml`.

External images are third-party dependencies. They must be handled by the least
risky option that still supports the deployment profile:

1. pin by immutable digest
2. pin by version tag when digest pinning would make an example unusable
3. mirror into a controlled registry when upstream availability is part of the
   supported deployment promise
4. exclude from the supported profile when the image is only an optional helper

Mutable external tags are not authoritative release records.

## Current External Images

| Image | Role | Current policy |
| --- | --- | --- |
| `nats:2-alpine@sha256:c11af972c99ae542de8925e6a7d9c533aa1eb039660420d2074beed6089b3bf0` | DNS record sync message bus | Digest-pinned |
| `cr.fluentbit.io/fluent/fluent-bit:3.2.10@sha256:d6dec000c4929a439562525728c708f6e99800d7ddc82efd6aa4f45f3a20b562` | Optional log collector/forwarder (`syslog` service); forwards to `syslog-ng` (#453) | Digest-pinned; replaces the non-pullable `fluent/fluent-bit:3` reference |
| `balabit/syslog-ng:latest@sha256:78ad81d617f83e46bf6fa9f45d5c437a841464be5e1cddfda2745e01e87dd335` | Central log receiver (`syslog-ng` service, #453); maintained by the syslog-ng project (published under the `balabit/` Docker Hub namespace) | Digest-pinned |
| `tecnativa/docker-socket-proxy@sha256:1f3a6f303320723d199d2316a3e82b2e2685d86c275d5e3deeaf182573b47476` | Docker API guard for UI/watchdog | Digest-pinned |
| `netdata/netdata@sha256:a130dbbf3d6e6a5472efdebaa123797190a5822627e908106d34edae02bc8a74` | Optional monitoring helper | Digest-pinned |
| `busybox:stable-musl@sha256:3c6ae8008e2c2eedd141725c30b20d9c36b026eb796688f88205845ef17aa213` | Minimal base for the stack channel pointer image | Digest-pinned |
| `rust:latest` | Build-tools base image | Allowed for build-tools only when provenance records the resolved base digest |

## Provenance And SBOM Expectations

For first-party images, releases expose the currently available release
evidence and must not claim evidence that the pipeline does not produce yet.
The target evidence set is:

- image tag
- immutable digest
- source commit
- base image digest
- SBOM location
- provenance attestation location
- relevant bundled component versions

Current status:

- **Provenance** attestations are pushed to GHCR for every first-party image
  digest and the stack channel-pointer digest (see "Verifying Release
  Provenance" below).
- **SBOMs** are generated per released first-party image digest by the
  `release-sbom` job in `.github/workflows/build-push.yml`. That job runs on
  release tags, resolves each `vX.Y.Z` image reference to its immutable digest,
  runs the project's pinned Trivy action in CycloneDX SBOM mode against that
  digest, and attaches the result to the GitHub release for the tag as a
  `<service>.cdx.json` asset. The covered set is the Trivy-scanned first-party
  images: `proxy`, `dns`, `watchdog`, `dhcp`, `dhcp-proxy`, `ntp`, `ui`, and
  `build-tools`. The `stack` channel-pointer image is excluded on purpose: it is
  a busybox pointer image, not a compiled software asset, and is not
  vulnerability-scanned either.
- **VEX** (vulnerability disposition) for accepted findings is published as the
  `vex.openvex.json` release asset — see "Vulnerability Disposition (VEX)" below.

Because a release re-run is idempotent (the release job replaces same-named
assets rather than duplicating them), re-running a tag's release workflow
backfills SBOM and VEX assets for a release cut before this job existed.

For mirrored or repackaged external images, the mirrored artifact must carry the
project's own provenance and SBOM for the mirrored digest.

For upstream external images that are not mirrored, release notes or deployment
metadata must record the approved upstream digest.

## Vulnerability Disposition (VEX)

Accepted, deliberately-suppressed vulnerability findings live in the repo-root
`.trivyignore.yaml` (each entry: the CVE id, the affected file paths, a
`statement` explaining why it is accepted, and an `expired_at` date forcing
periodic re-review). That file is Trivy-specific and not something a downstream
consumer's non-Trivy tooling can parse.

`scripts/generate-vex.sh` converts those entries into a standard
[OpenVEX](https://openvex.dev) JSON document, committed at the repo root as
`vex.openvex.json`. Each accepted-vulnerability entry becomes an OpenVEX
statement: the vulnerable component is present and the finding is accepted or
deferred (typically because no fixed upstream version exists to bump to yet), so
the honest status is `affected` with an `action_statement` that carries the
acceptance rationale and the mandatory re-review date — not `not_affected`,
which would assert a non-exploitability claim these entries do not make. If a
future entry genuinely represents non-exploitability, its status mapping must be
revisited in the generator rather than blanket-applied.

The committed `vex.openvex.json` is kept in sync with `.trivyignore.yaml` by
`scripts/check-vex-drift.sh`, run as the "Check VEX document stays in sync" step
in the `validate-compose` job: a PR that edits `.trivyignore.yaml` without
regenerating the VEX document fails CI. The same document is attached to each
release as the `vex.openvex.json` asset. This complements the Vulnerability
Management Policy documentation in `SECURITY.md` (refs #1130 / #1185).

## Retention

Do not delete digests that are referenced by a supported release, rollback
procedure, or published deployment document. Keep at least the current stable
release and two previous stable release digests for first-party images and any
mirrored external image they depend on.

The stable release workflow enforces this conservatively: supported deployment
profiles must not move `latest` while external image references are still
floating. Pin by digest, mirror, or remove the external helper from the stable
profile before publishing a stable release.
