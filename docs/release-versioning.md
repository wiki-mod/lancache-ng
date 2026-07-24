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

The first-party metadata package is:

- `stack`

`stack` is not a runtime service. It is the single mutable channel pointer used
by setup/update to resolve `latest` or `nightly` to one immutable `sha-*`
runtime image set.

The authoritative machine-readable inventory is
`release/stack-images.yml`. Workflows, release notes, setup behavior, and docs
must stay consistent with that file.

## Channels

| Channel | Meaning | Mutability | Intended use |
| --- | --- | --- | --- |
| `sha-<commit>` | Immutable build identity for a source commit | Immutable | Debugging, rollback, provenance, and promotion source |
| `nightly` | Tested pre-stable integration channel built continuously from `current_dev` (renamed from `edge` in v0.3.0, #1056; re-pointed from `master` to `current_dev` in v0.3.0, #825/#1141) | Mutable | Operators who explicitly opt into pre-stable builds |
| `vX.Y.Z-rc.N` | Release candidate | Immutable | Pre-release validation; GitHub release must be marked prerelease |
| `vX.Y.Z` | Stable release | Immutable | Production release pinning |
| `latest` | Latest stable release, published continuously from `master` | Mutable | Default stable install path |
| `stable` | Operator-facing name for the same channel `latest` publishes | Mutable | `setup.sh`'s interactive channel picker (#819); no separate `stack:stable` GHCR tag exists -- `stable` and `latest` resolve to the identical pointer image |

**Branch/channel model (#825/#1141, decided 2026-07-23 -- "master = stable,
current_dev = nightly, vY.X.Z = archived release, ganz simpel")**: `master`
publishes `latest` continuously after the required checks pass -- this is its
sole, permanent role, not an exception that needs a separate justification
each time. `current_dev` (the permanent active-development branch, decoupled
from any version number) publishes `nightly` continuously from its own tip,
taking over the role `master` used to have here before this decision.
`vY.X.Z` branches (e.g. `v0.2.0`) are archived release freezes: they still
take deliberate backports, exactly as before, but publish no live channel at
all -- nothing tracks them as a rolling install target. Stable release tags
(`vX.Y.Z`) publish the matching immutable tag and move `latest` (and, being
the same pointer, `stable`) to the same digest.

The `nightly` channel was named `edge` before v0.3.0 (#1056). The rename is a
deliberate breaking change with no alias: an install still carrying
`LANCACHE_IMAGE_CHANNEL=edge` is rejected with a clear error telling the
operator to switch to `nightly`, rather than being silently accepted.

**Retired: the `dev` channel (#825/#1141, v0.3.0).** Before this decision,
`dev` published automatically on every push to whichever branch matched
`vX.Y.Z` (the active pre-release integration branch of the time, e.g.
`v0.2.0`), separately from `master`'s own `nightly`/`edge` publishing. Once
`current_dev` became the permanent active-development branch, that role was
never re-pointed in code (the concrete gap #1141 found and fixed), and the
decision above formally retired `dev` rather than re-pointing it: archived
`vY.X.Z` branches are frozen release history now, not an active integration
branch, so there is no longer anything for a `dev` channel to mean. This is a
hard cut, not an alias, mirroring the `edge` -> `nightly` rename precedent
above: an install still carrying `LANCACHE_IMAGE_CHANNEL=dev` is rejected by
`setup.sh` with a clear error directing the operator to `nightly` (to track
ongoing development, now from `current_dev`) or `stable`/`latest` (to track
the stable release), rather than being silently accepted against an
increasingly stale, unmaintained image. `dev` was never offered by
`setup.sh`'s interactive picker (see below) or the Admin UI's channel
control, so this cut affects only operators who set
`LANCACHE_IMAGE_CHANNEL=dev` explicitly via `.env`/shell env or the
secondary-node registration flow.

`setup.sh`'s interactive install flow offers exactly two operator-facing
channel names: `nightly` (default pre-1.0) and `stable`, each with an inline
explanation of what it means. `stable` is not a new GHCR tag --
`resolve_lancache_stack_channel_tag` maps it onto the existing `latest`
pointer before pulling, so introducing it required no change to the
promotion/release pipeline. `pinned` remains a valid `LANCACHE_IMAGE_CHANNEL`
value (env var / `.env`, or the secondary-node registration flow) but is not
offered by the interactive picker -- it is a request for one specific
immutable tag, not a moving channel choice.

**Pre-1.0 default (#1068)**: the picker's default answer and its
"recommended" label were originally on `stable`, matching the plan when this
channel was introduced (#819) for a project that would soon cut a stable
release. In practice pre-1.0 has lasted long enough that this silently
walked a new operator's default "just press enter" choice into a
`docker pull` failure (`stack:latest` does not exist yet, since it is the
same underlying pointer `stable` maps to). The default and recommendation
were changed to `nightly` for as long as this project has no stable release;
`stable` remains a fully valid, non-removed answer -- choosing it explicitly
pre-1.0 still hits `resolve_lancache_stack_channel_tag`'s own clear
explanation rather than a raw Docker error, and it automatically becomes the
right default again once a real `vX.Y.Z` stable release exists and moves
`latest`. The Admin UI's own channel selector (`services/ui/src/routes/setup.rs`
/ `setup.html`) was checked separately and needs no equivalent change: it only
ever displays and edits an *existing* install's already-resolved channel
value, so it has no "default a new choice" moment the way the CLI installer
does.

## Promotion

The release pipeline must build immutable `sha-<commit>` images first. Public
service channel tags are promoted only after the full first-party package set
has been built and checked. The single `stack` channel pointer is moved last.

GHCR does not provide a true transaction that can atomically retag several
packages. The project therefore treats `ghcr.io/.../stack:<channel>` as the
authoritative mutable pointer for setup/update. Service channel tags may still
exist for human inspection, but setup resolves the stack pointer to an immutable
`sha-*` before pulling services.

The promotion flow is:

1. build and scan the full package set
2. publish immutable `sha-<commit>` images
3. verify that every required image exists for the same commit
4. promote `nightly`, `vX.Y.Z-rc.N`, `vX.Y.Z`, or `latest` according to the event
5. create or update release notes from the same package set

If one required image is missing, the channel must not be promoted.

## Setup And Update Selection

`LANCACHE_IMAGE_CHANNEL` is the operator-facing selector for mutable stack
channels. `LANCACHE_IMAGE_TAG` is the resolved immutable service-image tag that
Docker Compose actually pulls.
Setup and update are pull-only consumers of prebuilt first-party images; they
do not build the runtime stack locally, so Dev/CI accelerators are not part of
the install contract.

Default behavior:

- fresh installs use `LANCACHE_IMAGE_CHANNEL=nightly` by default pre-1.0
  (written by `setup.sh`'s interactive picker's default answer -- see the
  "Pre-1.0 default" note above); an operator can still explicitly choose
  `stable` at the same prompt, or set `LANCACHE_IMAGE_CHANNEL=stable`/`latest`
  directly, once a stable release exists
- `LANCACHE_IMAGE_CHANNEL=latest` remains valid and resolves identically to
  `stable` for existing installs and manual overrides
- release archives use their matching `vX.Y.Z` or `vX.Y.Z-rc.N` tag
- `setup.sh update` preserves the selected channel and refreshes the resolved
  `LANCACHE_IMAGE_TAG`
- missing image selector values are added during migration

Mutable channels are resolved through the single stack pointer image:

```text
ghcr.io/wiki-mod/lancache-ng/stack:<channel>
```

That image contains `stack.env`, including the immutable `sha-*` tag for the
coherent first-party image set. Setup resolves `latest` and `nightly`
through this pointer before `docker compose pull`, so a user install/update does
not consume per-service mutable tags while a promotion is in progress.

`LANCACHE_IMAGE_REGISTRY` and `LANCACHE_IMAGE_PREFIX` are the registry and image
namespace selectors. Their defaults are:

```env
LANCACHE_IMAGE_REGISTRY=ghcr.io
LANCACHE_IMAGE_PREFIX=wiki-mod/lancache-ng
LANCACHE_IMAGE_CHANNEL=latest
LANCACHE_IMAGE_TAG=sha-<commit>
```

They exist so operators can later point the stack at a private mirror without
editing every compose file.

## Automated Patch (Z) Tagging

The `promote` job in `build-push.yml` computes and cuts patch releases
automatically; it does not wait for a maintainer to push a `vX.Y.Z` tag by
hand for ordinary image-affecting changes.

On every push to the release-bearing branch (`master`), after the existing
channel-tag promotion and its `#777` debounce/coalesce check both succeed,
`promote` additionally:

1. resolves the current release with `git describe --tags --match
   'v[0-9]*.[0-9]*.[0-9]*' --abbrev=0`;
2. classifies every change since that tag's commit with
   `scripts/classify-image-impact.sh` -- the same classifier `detect-changes`
   uses, not a second copy;
3. if that diff is image-affecting (`IMAGE_IMPACT=true`), computes the next
   patch version with `scripts/compute-next-release-tag.sh` and pushes an
   annotated `vX.Y.Z` tag using the `PROJECT_AUTOMATION_PAT` secret;
4. otherwise cuts nothing and moves on.

Diffing from the last release's own commit (not "the previous push") means a
burst of several merges landing on `master` between two `promote` runs still
produces exactly one patch bump reflecting the whole burst, matching the
`#777` debounce this step runs after.

The tag is pushed with `PROJECT_AUTOMATION_PAT`, not `GITHUB_TOKEN`, because
GitHub does not re-trigger workflow runs for tags pushed by the default
`GITHUB_TOKEN` (a documented anti-recursion behavior). Pushing with a PAT
means the tag genuinely re-triggers `build-push.yml` on `refs/tags/v*`, so the
existing tag-triggered `release` job (GitHub release, `latest` move) runs
exactly as it does for a manually pushed tag -- this step never performs the
release itself, only cuts and pushes the tag.

Minor (`X`) and major (`Y`) bumps stay a deliberate, manual maintainer tag
push; nothing in this mechanism ever chooses to bump past a patch on its own.

This mechanism requires at least one real `vX.Y.Z` tag to already exist as its
starting point. Until that first tag is bootstrapped, the step is a documented
no-op (`::notice::`, not a failure) rather than guessing a starting version.

## Release Candidates

Tags matching `vX.Y.Z-rc.N` are release candidates. They must create or update a
GitHub prerelease. A release candidate must not move `latest`.

## Stable Releases

Tags matching `vX.Y.Z` are stable releases. They must create or update a normal
GitHub release. They may move `latest` after the full package set has passed the
release gate.

## Platform Support

The currently supported prebuilt production platforms are `linux/amd64` and
`linux/arm64`. `release/stack-images.yml`, the build workflow, and `setup.sh`
must agree on that platform list. `setup.sh` fails closed before pulling
prebuilt production images if either:

- the host architecture is not one setup.sh recognizes (only x86_64/amd64 and
  aarch64/arm64 are supported), or
- the specific tag/channel this install resolved to does not actually publish
  a manifest for this host's architecture (checked via `docker buildx
  imagetools inspect`, mirroring `scripts/require-image-platforms.sh`'s
  release/promotion guard).

Adding another platform beyond amd64/arm64 requires updating the manifest,
build workflow, setup platform guards, release notes, and validation together.

## External Images

External images are not part of the first-party stack tag. They remain explicit
dependencies and are tracked in `release/stack-images.yml`. See
[docs/release-external-images.md](release-external-images.md) for the
per-image table (role, digest, policy) and provenance/SBOM expectations --
this section states the policy only, not the current image list.

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

Mutable channels such as `latest` and `nightly` may move, but the digests they
pointed to remain protected when they are also referenced by a supported
release, rollback path, or published deployment document.

Automated cleanup must be opt-in and must read the manifest retention section.
It must not delete release or rollback digests by pattern alone.

## CI Guardrails

The CI guardrails must fail closed when:

- compose image names drift from `release/stack-images.yml`
- the build matrix omits a first-party package
- `latest` is published through any path other than the gated `promote` job
  (e.g. `docker/metadata-action`'s own `is_default_branch` auto-tag on a raw
  build step) -- `master`'s own `promote`-job publish of `latest` is the
  correct, audited path and is not what this guards against
- an RC tag attempts to create a non-prerelease
- a release job uses mutable `build-tools:latest`
- release notes omit a first-party package
- a public channel would be promoted before the full package set exists
- retention rules are missing from the stack image manifest
- stable release promotion would move `latest` while supported external images
  are still floating
- release or release-adjacent jobs that mention build acceleration do not state
  whether that accelerator is optional, preferred, or a gate
- normal setup/update validation would inherit LAN-only cache assumptions from
  a self-hosted runner path
