# Release Versioning Policy

This document is the release-channel contract for lancache-ng images, setup
artifacts, and release notes.

## Core Rule

lancache-ng releases are stack releases. Runtime service images are not promoted
independently for operator consumption. A consumable channel tag must identify a
coherent stack built from the same source commit and the same release gate.

The first-party runtime package set is:

- `proxy`
- `dns`
- `watchdog`
- `dhcp`
- `dhcp-proxy`
- `ui`

The first-party tooling package is:

- `build-tools`

The authoritative machine-readable inventory is
`release/stack-images.yml`. Workflows, release notes, setup behavior, and docs
must stay consistent with that file.

## Channels

| Channel | Meaning | Mutability | Intended use |
| --- | --- | --- | --- |
| `sha-<commit>` | Immutable build identity for a source commit | Immutable | Debugging, rollback, provenance, and promotion source |
| `dev` | Explicit development/test channel | Mutable | Maintainer-triggered development checks only |
| `edge` | Tested pre-stable integration channel from `master` | Mutable | Operators who explicitly opt into pre-stable builds |
| `vX.Y.Z-rc.N` | Release candidate | Immutable | Pre-release validation; GitHub release must be marked prerelease |
| `vX.Y.Z` | Stable release | Immutable | Production release pinning |
| `latest` | Latest stable release only | Mutable | Default stable install path |

`latest` must not be moved by a normal `master` build. The `master` branch
publishes `edge` after the required checks pass. Stable release tags publish the
matching `vX.Y.Z` tag and may move `latest` to the same digest.

## Promotion

The release pipeline must build immutable `sha-<commit>` images first. Public
channel tags are promoted only after the full first-party package set has been
built and checked.

The promotion flow is:

1. build and scan the full package set
2. publish immutable `sha-<commit>` images
3. verify that every required image exists for the same commit
4. promote `edge`, `vX.Y.Z-rc.N`, `vX.Y.Z`, or `latest` according to the event
5. create or update release notes from the same package set

If one required image is missing, the channel must not be promoted.

## Setup And Update Selection

`LANCACHE_IMAGE_TAG` remains the operator-facing selector for first-party
runtime images.

Default behavior:

- fresh stable installs use `LANCACHE_IMAGE_TAG=latest`
- edge installs must explicitly set `LANCACHE_IMAGE_TAG=edge`
- release archives use their matching `vX.Y.Z` or `vX.Y.Z-rc.N` tag
- `setup.sh update` preserves an existing `LANCACHE_IMAGE_TAG`
- missing `LANCACHE_IMAGE_TAG` values are added during migration

`LANCACHE_IMAGE_REGISTRY` and `LANCACHE_IMAGE_PREFIX` are the registry and image
namespace selectors. Their defaults are:

```env
LANCACHE_IMAGE_REGISTRY=ghcr.io
LANCACHE_IMAGE_PREFIX=wiki-mod/lancache-ng
```

They exist so operators can later point the stack at a private mirror without
editing every compose file.

## Release Candidates

Tags matching `vX.Y.Z-rc.N` are release candidates. They must create or update a
GitHub prerelease. A release candidate must not move `latest`.

## Stable Releases

Tags matching `vX.Y.Z` are stable releases. They must create or update a normal
GitHub release. They may move `latest` after the full package set has passed the
release gate.

## Platform Support

The current supported prebuilt production platform is `linux/amd64`.
`release/stack-images.yml`, the build workflow, and `setup.sh` must agree on
that platform. Until the project deliberately enables another platform, setup
fails closed on non-amd64 hosts before pulling prebuilt production images.

Adding `linux/arm64` or another platform requires updating the manifest, build
workflow, setup platform guard, release notes, and validation together.

## External Images

External images are not part of the first-party stack tag. They remain explicit
dependencies and are tracked in `release/stack-images.yml`.

Before a stable release, each external image used by a supported deployment
profile must be pinned by digest, mirrored, or documented as intentionally
floating with a clear reason.

## Rollback

Rollback should use immutable `sha-<commit>` or `vX.Y.Z` tags whenever possible.
Backups record image revisions before updates so operators can recover from a
bad pull without guessing which image was running.

## Retention

`release/stack-images.yml` defines the retention contract. The project must keep
at least the current stable release and two previous stable releases for the
full first-party image set. Release digests, rollback digests, and `sha-*` tags
referenced by supported releases must not be deleted.

Mutable channels such as `latest` and `edge` may move, but the digests they
pointed to remain protected when they are also referenced by a supported
release, rollback path, or published deployment document.

Automated cleanup must be opt-in and must read the manifest retention section.
It must not delete release or rollback digests by pattern alone.

## CI Guardrails

The CI guardrails must fail closed when:

- compose image names drift from `release/stack-images.yml`
- the build matrix omits a first-party package
- `master` attempts to publish `latest`
- an RC tag attempts to create a non-prerelease
- a release job uses mutable `build-tools:latest`
- release notes omit a first-party package
- a public channel would be promoted before the full package set exists
- retention rules are missing from the stack image manifest
- stable release promotion would move `latest` while supported external images
  are still floating
