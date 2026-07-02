# Release External Images and Provenance

This document records how lancache-ng handles container images that are not
built from this repository.

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
| `nats:2-alpine` | DNS record sync message bus | Pin or mirror before stable release |
| `fluent/fluent-bit:3` | Optional log forwarding helper | Pin before stable release when profile is supported |
| `tecnativa/docker-socket-proxy` | Docker API guard for UI/watchdog | Pin or mirror before stable release |
| `netdata/netdata` | Optional monitoring helper | Pin before stable release when profile is supported |
| `ghcr.io/nicholas-fedor/watchtower:latest` | Optional automatic update helper | Not release-authoritative; avoid relying on `latest` for stable profiles |
| `rust:latest` | Build-tools base image | Allowed for build-tools only when provenance records the resolved base digest |

## Provenance And SBOM Expectations

For first-party images, releases should expose:

- image tag
- immutable digest
- source commit
- base image digest
- SBOM location
- provenance attestation location
- relevant bundled component versions

For mirrored or repackaged external images, the mirrored artifact must carry the
project's own provenance and SBOM for the mirrored digest.

For upstream external images that are not mirrored, release notes or deployment
metadata must record the approved upstream digest.

## Retention

Do not delete digests that are referenced by a supported release, rollback
procedure, or published deployment document. Keep at least the current stable
release and two previous stable release digests for first-party images and any
mirrored external image they depend on.
