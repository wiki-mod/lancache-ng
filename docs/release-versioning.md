# Release Versioning Policy

This document is the release-channel contract for lancache-ng images, setup
artifacts, and release notes.

## Core Rule

lancache-ng releases are stack releases. Runtime service images are not promoted
independently for operator consumption. A consumable channel tag must identify a
coherent stack built from the same source commit and the same release gate.

The first-party runtime package set is the SOT `services` list in
`.github/yaml/build-manifest.yml`:

- `services` (watchdog, syslog-ng, chrony, netdata, retention and cachehamster)
- `proxy`
- `dns` (PowerDNS, dns-http, dns-https and NATS)
- `dhcp` (Kea or dnsmasq proxy/relay, one mode at a time)
- `ui`

The first-party tooling package is the SOT `build_toolchain` target
(`build-tools`).

(issue #1556 added a second tooling package, `utilities`, a shared
non-compiler CLI-tools image consumed via `COPY --from=` by seven
first-party images; issue #1781 removed it again -- each former consumer
now `apk add`s its own copy of what it used to `COPY` instead.)

There is no metadata or pointer package. A channel is the same tag on every
first-party image, moved together by one promotion (see Promotion below).

The authoritative machine-readable inventory is the SOT
`.github/yaml/build-manifest.yml`. Workflows, release notes, setup behavior,
and docs must stay consistent with it.

## Channels

| Channel | Meaning | Mutability | Intended use |
| --- | --- | --- | --- |
| `sha-<commit>` | Immutable tag for a source commit, always the full 40-hex SHA (`release.tag_commit`; `setup.sh` rejects a short SHA) | Immutable | Debugging, rollback, provenance, and promotion source |
| `nightly` | Tested pre-stable integration channel, moved by `nightly.yml` (schedule `23 3 * * *` plus dispatch) to the accepted `current_dev` stack after `validate`; never rebuilt | Mutable | Operators who explicitly opt into pre-stable builds |
| `vX.Y.Z-rc.N` | Release candidate | Immutable | Pre-release validation; GitHub release must be marked prerelease |
| `vX.Y.Z` | Stable release | Immutable | Production release pinning |
| `latest` | Latest stable release, published continuously from `master` | Mutable | Default stable install path |
| `stable` | Operator-facing name for the same channel `latest` publishes | Mutable | `setup.sh`'s interactive channel picker (#819); no separate `stable` GHCR tag exists -- `stable` is the SOT alias of `latest` (`release.channels.latest.aliases`) and resolves to the same tags |

`nightly`'s history: renamed from `edge` in v0.3.0 (#1056); re-pointed from
`master` to `current_dev` in v0.3.0 (#825/#1141); changed from "republished on
every `current_dev` push" to the once-daily/on-demand model below in
#1254/#1255, 2026-07-25.

### Branch/channel model

Decided 2026-07-23 (#825/#1141): "master = stable, current_dev = nightly,
vY.X.Z = archived release, ganz simpel."

- **`master`** publishes `latest` continuously after the required checks
  pass. This is its sole, permanent role, not an exception needing separate
  justification each time.
- **`vY.X.Z` branches** (e.g. `v0.2.0`) are archived release freezes: they
  still take deliberate backports, exactly as before, but publish no live
  channel at all -- nothing tracks them as a rolling install target.
- **Stable release tags** (`vX.Y.Z`) publish the matching immutable tag and
  move `latest` (and, being the same pointer, `stable`) to the same digest.

### `current_dev` -> `nightly` publishing model

Decided 2026-07-25 (#1254/#1255): "nightly should be a real once-a-day build,
like Firefox Nightly, not republished on every push."

- **Before:** `current_dev` published `nightly` continuously from its own
  tip on every push (taking over the role `master` used to have, per
  #825/#1141). In practice `nightly` moved dozens of times a day, defeating
  the point of a "tested" channel distinct from the raw commit stream and
  giving operators no guarantee beyond tracking `current_dev` directly.
- **After:** a plain `current_dev` push no longer moves the `nightly`
  channel tag. It still builds, scans, and publishes that commit's durable
  per-service `sha-<commit>` tags exactly as before (unaffected). `nightly`
  refreshes through `.github/workflows/nightly.yml`:
  - once a day via its `schedule` trigger (`23 3 * * *` = 03:23 UTC =
    04:23 CET winter / 05:23 CEST summer -- GitHub Actions cron has no
    timezone concept, so this one-hour seasonal drift is deliberately
    accepted);
  - on-demand via its `workflow_dispatch`.
  - Either path validates the accepted `current_dev` stack and then runs
    `ci.sh promote nightly`; it never rebuilds `current_dev`. Promotion
    refuses an incomplete or not validated stack, so a broken `current_dev`
    tip never reaches `nightly` and `nightly` holds its last good state.
- **Known gap:** GitHub's `schedule:` trigger only fires from a workflow file
  as it exists on the default branch (`master`), so the daily cron does not
  start firing until `nightly.yml` itself is merged to `master` -- until
  then (and whenever it lags `current_dev` afterward), `nightly` refreshes
  only via manual dispatch. Per AG-CI-019 (AGENTS.md) this is not an accepted
  long-term tradeoff: it must reach `master` via its own sync PR in
  reasonably short order.
- This change does not affect #808's untouched-service PR backfill
  correctness guarantee -- that mechanism no longer depends on `nightly`
  staying continuously fresh at all (see Promotion below).

The `nightly` channel was named `edge` before v0.3.0 (#1056). The rename is a
deliberate breaking change with no alias: an install still carrying
`LANCACHE_IMAGE_CHANNEL=edge` is rejected with a clear error telling the
operator to switch to `nightly`, rather than being silently accepted.

### Retired: the `dev` channel (#825/#1141, v0.3.0)

- **Before:** `dev` published automatically on every push to whichever
  branch matched `vX.Y.Z` (the active pre-release integration branch of the
  time, e.g. `v0.2.0`), separately from `master`'s own `nightly`/`edge`
  publishing.
- **What changed:** once `current_dev` became the permanent active-development
  branch, that role was never re-pointed in code (the concrete gap #1141
  found and fixed). The decision above formally retired `dev` rather than
  re-pointing it: archived `vY.X.Z` branches are frozen release history now,
  not an active integration branch, so there is nothing left for a `dev`
  channel to mean.
- **Cutover:** a hard cut, not an alias -- mirroring the `edge` -> `nightly`
  rename precedent above. An install still carrying
  `LANCACHE_IMAGE_CHANNEL=dev` is rejected by `setup.sh` with a clear error
  directing the operator to `nightly` (ongoing development, now from
  `current_dev`) or `stable`/`latest` (the stable release), rather than
  being silently accepted against an increasingly stale image. `dev` was
  never offered by `setup.sh`'s interactive picker or the Admin UI's channel
  control, so this cut affects only operators who set
  `LANCACHE_IMAGE_CHANNEL=dev` explicitly via `.env`/shell env or the
  secondary-node registration flow.

### Operator-facing channel picker

`setup.sh`'s interactive install flow offers exactly two operator-facing
channel names: `nightly` (default pre-1.0) and `stable`, each with an inline
explanation of what it means.

- `stable` is not a new GHCR tag -- `setup.sh` maps it onto the `latest`
  tags before pulling (SOT `release.channels.latest.aliases`), so
  introducing it required no change to the promotion/release pipeline.
- `pinned` remains a valid `LANCACHE_IMAGE_CHANNEL` value (env var / `.env`,
  or the secondary-node registration flow) but is not offered by the
  interactive picker -- it is a request for one specific immutable tag, not
  a moving channel choice.

**Pre-1.0 default (#1068).** The picker's default answer and "recommended"
label were originally on `stable`, matching the plan when this channel was
introduced (#819) for a project expected to soon cut a stable release. In
practice, pre-1.0 lasted long enough that this silently walked a new
operator's "just press enter" choice into a `docker pull` failure
(no `latest` tag exists yet, and `stable` maps to it). The default and
recommendation were changed to `nightly` for as long as this project has no
stable release; `stable` remains a fully valid, non-removed answer --
choosing it explicitly pre-1.0 still hits `setup.sh`'s clear explanation
("Cannot resolve the 'stable' release channel") rather than a raw Docker
error, and it automatically becomes the right default again once a
real `vX.Y.Z` stable release exists and moves `latest`. The Admin UI's own
channel selector (`services/ui/src/main.rs` / `setup.html`) needs no
equivalent change: it only ever displays and edits an *existing* install's
already-resolved channel value, so it has no "default a new choice" moment.

## Promotion

The release pipeline must build immutable `sha-<commit>` images first. Public
channel tags are promoted only after the full first-party package set has been
built and checked.

GHCR does not provide a true transaction that can atomically retag several
packages. `ci.sh promote` therefore moves every image's channel tag inside one
promote lock (the git ref `CI_PROMOTE_LOCK_REF/<channel>` in the SOT), moves
nothing for an incomplete or not validated stack, and moves already moved tags
back to their earlier digest when a later move fails. `setup.sh` reads every
image's channel digest twice while that lock is free and pins each image to
its digest only when both reads are equal (see Setup And Update Selection).

The promotion flow is:

1. build and scan the full package set
2. publish immutable `sha-<commit>` images
3. verify that every required image exists for the same commit
4. promote `nightly`, `vX.Y.Z-rc.N`, `vX.Y.Z`, or `latest` according to the event
5. create or update release notes from the same package set

If one required image is missing, the channel must not be promoted.

**Step 4, for `nightly`, no longer fires on every `current_dev` push
(#1254/#1255)** -- see "`current_dev` -> `nightly` publishing model" above
for the full corrected model (once-daily scheduled + on-demand, still gated
on steps 1-3 passing).

**PR validation needs no backfill and no retag.** `ci.sh validate` assembles
the PR's stack candidate from exact image digests: a service the PR changed
uses the digest built for its new build identity, an unchanged service reuses
the digest already accepted for its unchanged identity. No untouched service
is copied, retagged, or re-pulled from a mutable channel to complete the stack
(docs/ci-2.0-architecture.md sections 27, 28 and 48).

## Setup And Update Selection

`LANCACHE_IMAGE_CHANNEL` is the operator-facing selector for mutable stack
channels. `LANCACHE_IMAGE_TAG` is the resolved immutable service-image tag that
Docker Compose actually pulls. Setup and update are pull-only consumers of
prebuilt first-party images; they do not build the runtime stack locally, so
Dev/CI accelerators are not part of the install contract.

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

Mutable channels are resolved per image:

```text
ghcr.io/wiki-mod/lancache-ng/<image>:<channel>
```

For every `LANCACHE_IMAGE_REF_*` image of `deploy/prod/docker-compose.yml`,
`setup.sh` reads the channel tag's digest twice while the channel's promote
lock is free. Only two equal reads count; it then writes
`LANCACHE_IMAGE_REF_<NAME>=<image>@<digest>` for each image, so Docker Compose
pulls digests, never a mutable tag, and an install/update never mixes two
stacks while a promotion is in progress. A held lock or two different reads
retry after `CI_LOCK_POLL_SECONDS`, at most `CI_PROMOTE_LOCK_MAX` times.

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

`ci.sh cut-release-tag` computes and cuts patch releases automatically; it does
not wait for a maintainer to push a `vX.Y.Z` tag by hand for ordinary
image-affecting changes. `ci.yml` runs it on every push to the release-bearing
branch (`master`), after that push's channel promotion succeeded. It:

1. resolves the current release (the newest plain `vX.Y.Z` tag);
2. compares, for every published first-party image, the digest of this
   commit's `sha-<commit>` image with the digest at that release tag -- content
   identity, not a path heuristic;
3. if any digest differs, computes the next patch version and pushes an
   annotated `vX.Y.Z` tag using the `PROJECT_AUTOMATION_PAT` secret, unless
   `master` has already moved past this commit or the tag already exists;
4. otherwise cuts nothing (`cut-tag=noop`).

Comparing against the last release's own images (not "the previous push")
means a burst of several merges landing on `master` still produces exactly one
patch bump reflecting the whole burst.

The tag is pushed with `PROJECT_AUTOMATION_PAT`, not `GITHUB_TOKEN`, because
GitHub does not re-trigger workflow runs for tags pushed by the default
`GITHUB_TOKEN` (a documented anti-recursion behavior). Pushing with a PAT
means the tag genuinely triggers the `v*` tag workflows (`release.yml` for the
GitHub release, its notes, SBOM and VEX), exactly as for a manually pushed tag
-- this step never performs the release itself, only cuts and pushes the tag.

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

The supported prebuilt production platforms are the SOT
`build_matrix.platforms` list in `.github/yaml/build-manifest.yml`; a build
target may narrow it, never widen it. `ci.sh` reads that list for the build
matrix. `setup.sh` fails closed before pulling prebuilt
production images if either:

- the host architecture is not one setup.sh recognizes (only x86_64/amd64 and
  aarch64/arm64 are supported), or
- the specific tag/channel this install resolved to does not actually publish
  a manifest for this host's architecture (checked via `docker buildx
  imagetools inspect`).

Adding another platform requires updating the SOT list, the setup platform
guard, and validation together.

## External Images

External images are not part of the first-party stack tag. They are the SOT
`base_images` entries. See
[docs/release-external-images.md](release-external-images.md) for the
per-image table (role, policy) and provenance/SBOM expectations -- this
section states the policy only, not the current image list.

Every external image must be pinned by digest in the SOT `base_images`;
`ci.sh check all` runs the `stable-external-images` check on every CI run
except issue events.

## Rollback

Rollback should use immutable `sha-<commit>` or `vX.Y.Z` tags whenever possible.
Backups record image revisions before updates so operators can recover from a
bad pull without guessing which image was running.

## Retention

GHCR retention is reachability, not a count budget. `ci.sh gc` decides it;
`.github/workflows/gc.yml` runs it once a day and on `workflow_dispatch`,
with `--apply`. The policy values are the SOT `release.retention` keys.

### Protected roots

`ci.sh gc` builds one protected root set before it looks at any version:

- every record of the acceptance ledger (the git ref named by the
  `CI_LEDGER_REF` variable), in any state;
- every mutable channel (SOT `release.channels`) of every build target;
- the layer cache tags of every build target and platform;
- the index children of each of these.

A failed read of any of these sources is UNKNOWN: the run stops and deletes
nothing. An empty protected root set stops the run too.

### Candidates and verdict

The candidates are the GHCR versions of the SOT build targets only, never
other packages of the owner. Each candidate gets one verdict:

- KEEP when its digest is in the protected root set;
- KEEP when it is a `sha256-<subject>` referrer (attestation, SBOM) of a
  protected root;
- KEEP when it is younger than `release.retention.unaggregated_grace_minutes`,
  so a build that is still being aggregated is not removed;
- DELETE otherwise.

A candidate that cannot be classified stops the run.

### Deleting

Without `--apply`, `ci.sh gc` only prints the verdicts. With `--apply` it
deletes only when `release.retention.deletion_policy` is
`manual-or-approved-automation-only` and GHCR auth is present; `gc.yml`
passes `GHCR_PACKAGE_DELETE_PAT` for the delete calls.

Right before each delete the candidate is classified again; a candidate that
is now referenced is kept and logged. A delete counts as done when GitHub
answers HTTP 404 or the version reads back with `deleted_at` set; any other
answer stops the run. The run ends with one line that counts kept, deleted
and classified versions.

A digest with a ledger record stays as long as that record exists, so a
released digest is not garbage. A mutable channel protects only the digest
it points at now.

## CI Guardrails

`ci.sh check all` runs in the `checks` job of every CI run except issue
events. The run fails
closed when:

- a compose image is neither a first-party `LANCACHE_*` image nor a digest
  pin from the SOT `base_images` (`stable-external-images`);
- a changed file uses a mutable image reference (`mutable-refs`);
- channel or tag resolution does not come from one config across
  `setup.sh`, the UI and compose (`image-channel-resolution`);
- a production install path builds instead of pulling prebuilt images
  (`prebuilt-prod`);
- a SOT-owned job does not take its runner and timeout from
  `ci.sh job-settings` (`workflow-job-settings`);
- one of the SOT `ci_result_gate.required` phases did not run and succeed.

Channel moves happen only in `ci.sh promote`, under the promote lock. A
`vX.Y.Z-rc.N` tag creates a prerelease and promotes only its own tag; a
final `vX.Y.Z` tag also moves the channels marked `release_tags: true` in
the SOT.
