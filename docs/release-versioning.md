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
- `ntp`
- `ui`
- `syslog`

The first-party tooling package is:

- `build-tools`
- `utilities` (issue #1556; shared non-compiler CLI-tools image, not yet
  consumed by any other first-party image -- see `release/stack-images.yml`'s
  own entry for the current, deliberately empty `consumers:` list)

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
| `nightly` | Tested pre-stable integration channel, built from `current_dev`'s tip once a day (01:00 UTC) plus on-demand, gated on a full green build+scan (renamed from `edge` in v0.3.0, #1056; re-pointed from `master` to `current_dev` in v0.3.0, #825/#1141; changed from "republished on every current_dev push" to this once-daily/on-demand model in #1254/#1255, 2026-07-25) | Mutable | Operators who explicitly opt into pre-stable builds |
| `vX.Y.Z-rc.N` | Release candidate | Immutable | Pre-release validation; GitHub release must be marked prerelease |
| `vX.Y.Z` | Stable release | Immutable | Production release pinning |
| `latest` | Latest stable release, published continuously from `master` | Mutable | Default stable install path |
| `stable` | Operator-facing name for the same channel `latest` publishes | Mutable | `setup.sh`'s interactive channel picker (#819); no separate `stack:stable` GHCR tag exists -- `stable` and `latest` resolve to the identical pointer image |

**Branch/channel model (#825/#1141, decided 2026-07-23 -- "master = stable,
current_dev = nightly, vY.X.Z = archived release, ganz simpel")**: `master`
publishes `latest` continuously after the required checks pass -- this is its
sole, permanent role, not an exception that needs a separate justification
each time. `vY.X.Z` branches (e.g. `v0.2.0`) are archived release freezes:
they still take deliberate backports, exactly as before, but publish no live
channel at all -- nothing tracks them as a rolling install target. Stable
release tags (`vX.Y.Z`) publish the matching immutable tag and move `latest`
(and, being the same pointer, `stable`) to the same digest.

**`current_dev` -> `nightly` publishing model changed (#1254/#1255, decided
2026-07-25 -- "nightly should be a real once-a-day build, like Firefox
Nightly, not republished on every push")**: originally (#825/#1141),
`current_dev` published `nightly` continuously from its own tip on every
push, taking over the role `master` used to have here before that decision.
In practice this meant `nightly` moved dozens of times a day, which defeated
the point of a distinct "tested" channel separate from the raw commit stream
and gave operators no meaningfully different guarantee than tracking
`current_dev` directly. The corrected model: a plain `current_dev` push no
longer moves the `nightly` channel tag at all -- it still builds, scans, and
publishes that commit's durable per-service `sha-<commit>` tags exactly as
before (unaffected by this change). `nightly` is instead refreshed exactly
once a day, by `.github/workflows/nightly-refresh.yml`'s `schedule` trigger
(`0 1 * * *`, i.e. 01:00 UTC == 02:00 CET in winter / 03:00 CEST in summer --
GitHub Actions cron has no timezone concept and always fires in UTC, so this
one-hour seasonal drift is deliberately accepted, matching the drift
`build-push.yml`'s own daily `latest` schedule already accepts for the same
reason), plus on-demand via that same workflow's `workflow_dispatch` trigger
or via `build-push.yml`'s own pre-existing `channel: nightly`
`workflow_dispatch` input dispatched directly against `current_dev`.
Either path runs build-push.yml's full pipeline (build, test, scan, then
`promote`) against `current_dev`'s tip, so `nightly` remains green-gated and
fail-closed by construction: `promote` only runs `needs: merge-manifests`
after the build/scan jobs succeed, so a broken `current_dev` tip simply never
reaches `promote` and `nightly` holds its last good state instead of being
force-moved onto a red commit. One known gap: GitHub's `schedule:` trigger
only ever fires from a workflow file as it exists on the repository's default
branch (`master`), so the daily cron does not actually start firing until
`nightly-refresh.yml` itself has been merged to `master` -- until then (and
whenever it lags `current_dev` afterward), `nightly` refreshes only via
manual dispatch. Per AG-CI-019 (AGENTS.md), this gap is not treated as a
long-term accepted tradeoff: it must reach `master` via its own dedicated
sync PR in reasonably short order, the same way `build-push.yml`'s own daily
`latest` schedule shares this identical GitHub limitation and the same
sync obligation. This change does not affect
#808's untouched-service PR backfill correctness guarantee: that mechanism no
longer depends on `nightly` staying continuously fresh at all -- see the
Promotion section below.

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

**Step 4, for `nightly` specifically, no longer fires on every `current_dev`
push (#1254/#1255)** -- see the "Branch/channel model" section above for the
full corrected model (once-daily scheduled + on-demand, still gated on steps
1-3 passing).

**PR validation's own untouched-service back-fill no longer depends on
`nightly` (#1254/#1255)**: a PR's full-setup validation back-fills any
full-setup service the PR itself did not touch so the suite still tests a
complete, coherent stack. Before #1254/#1255 this back-filled from the
`nightly`/`latest` base-channel tag (guarded by #808's "confirm the channel
image was actually built at or after this PR's base commit" ancestry check,
since a channel tag can lag). Now that `nightly` is no longer continuously
fresh, that channel tag is no longer a reliable "at or after PR base"
source, so the back-fill instead sources directly from the PR base commit's
own durable `sha-<base_sha>` per-commit image -- exactly the right
commit by construction, made possible because every non-PR push already
publishes a fresh per-commit tag for every service (see `build-push.yml`'s
"Ensure PR staging tags exist for full-setup services" step and
`scripts/untracked/ensure-pr-staging-images.sh`). #808's bounded-wait/ancestry-check
mechanism (`scripts/lib/staging-image-freshness.sh`) is unchanged and still
used: it doubles as the poll for the base commit's own push-triggered build
finishing, and still guards against a corrupted or mislabeled image.

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
   `scripts/untracked/classify-image-impact.sh` -- the same classifier `detect-changes`
   uses, not a second copy;
3. if that diff is image-affecting (`IMAGE_IMPACT=true`), computes the next
   patch version with `scripts/untracked/compute-next-release-tag.sh` and pushes an
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
  imagetools inspect`, mirroring `scripts/untracked/require-image-platforms.sh`'s
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

`release/stack-images.yml` defines the retention contract. The normal history
budget is `accepted_ordinary_roots_per_package: 30`: for each first-party
runtime or tooling package, keep the thirty newest **accepted ordinary root
identities**. The current accepted identity counts as one of those thirty, so
the rolling window is one current plus twenty-nine previous accepted roots.
(Raised from 10 to 30: a period with many concurrently open PRs that each
only change YAML/governance files still produces one new build-tools
`sha-<commit>` image per push, and a ten-slot window could evict still-live
history from those PRs before they merge.)

The budget counts stored root identity, not tag names. Multiple immutable
`sha-<commit>` aliases that resolve to the same root digest consume one ordinary
history slot. Platform child manifests and provenance/SBOM/referrer artifacts
also do not consume ordinary-history slots; they remain part of the required
artifact closure while a retained or otherwise protected root references them.

A legacy `sha-*` tag proves that an immutable build identity exists, but it does
not by itself prove that the artifact passed the acceptance gates. Rejected,
abandoned, failed, or acceptance-unknown candidates do not become accepted
ordinary history merely because they are new or carry a SHA-shaped tag. Until
canonical accepted-artifact evidence can prove acceptance for the exact root,
a retention audit must report that state conservatively and must not use it as
destructive deletion authority.

Protected references are exceptions to the rolling ordinary-history budget.
The exact digest/root identities required by `nightly`, `latest`, a supported
stable release, or an accepted stack identity remain protected together with
their required artifact closure even when they fall outside the thirty
ordinary accepted roots. Git ancestry can help classify where a legacy SHA
came from, but being an ancestor of a protected branch or tag is not by
itself a permanent storage exemption.

The project must additionally keep at least the current stable release and two
previous stable releases for the full first-party image set. Release digests,
rollback digests, and SHA identities referenced by those protected releases must
not be deleted.

Mutable channels such as `latest` and `nightly` may move, but the exact digests
they still reference are protected. Historical channel targets are not retained
merely because a mutable channel once pointed at them unless another retention
rule still protects that identity.

**The protected-reference model (issue #1501)**: the audit
(`scripts/lib/sha-retention-audit.sh`, `scripts/untracked/gc-sha-retention-audit.sh`)
checks every classified package version's attached tags against the
`nightly`/`latest`/supported-stable-release categories above (the "accepted
stack identity" category was already handled separately and unconditionally,
via the `metadata-stack-identity` reason for the `stack` pointer package) and
reports a specific reason instead of a generic one whenever a match is found:

- `nightly-channel-protected` — this exact digest currently carries the
  `nightly` tag.
- `latest-channel-protected` — this exact digest currently carries the
  `latest` tag.
- `stable-release-protected` — this exact digest carries a `vX.Y.Z` tag that
  is still among this package's `minimum_stable_releases` (3) newest stable
  releases, selected by real semver order from the package's own tag
  inventory rather than an extra GitHub Releases API call.

A digest can carry more than one of these at once (e.g. immediately after a
promotion, when `current_dev` and `master` briefly share a commit); the audit
reports every applicable reason, `+`-joined
(e.g. `nightly-channel-protected+stable-release-protected`), rather than
picking one arbitrarily.

This works because the promote job (`build-push.yml`) always retags an
existing digest (`docker buildx imagetools create --prefer-index=false`)
rather than rebuilding, so a currently active channel or release tag always
lands on the exact same GHCR package-version object as the `sha-<commit>` tag
it originated from — the audit does not need a second, separate
digest-matching pass to find this; it only needs to read the already-fetched
tag list honestly instead of collapsing it into a single generic bucket.

**Protection is current-state-only, never "was ever" (maintainer
clarification, 2026-08-14)**: a real live audit found 32,895 package
versions across the 9 first-party packages, which is far more than blanket
"anything ever nightly/latest stays protected forever" retention could
justify. This is why a tag-based check is the correct mechanism rather than
a source of over-protection: a registry tag name resolves to exactly one
digest at a time, so a GHCR package version's own `tags` array is, by
construction, the *live* pointer set, never a history of everything a tag
ever pointed at — once `nightly`/`latest` moves to a new digest, the old
digest's version object simply stops carrying that tag at all, and this
audit reads that same live state. The same applies to
`stable-release-protected`: it credits only a `vX.Y.Z` tag currently among
the newest `minimum_stable_releases`, never an older, no-longer-supported
release tag. A version whose only extra tag is unrecognized — a
release-candidate, a staging tag, or a release tag past
`minimum_stable_releases` — is **not** blanket-protected anymore: it falls
through into the same ordinary root-candidate ranking (`legacy_rank`,
budget) as a plain `sha-<commit>` root, since it still has a resolvable
git-history root to rank by. `non-sha-tag-attached`/`non-ordinary-version`
now only ever label a root with no *resolvable* commit history at all (the
`root_count==0` case), not "carries some extra tag."

**Deliberately not implemented: a "previous nightly" safety net.** The
maintainer's real operational intent for `nightly` protection is narrower
than "every digest nightly ever pointed at," but broader than "only the
current one" — in the case a broken `current_dev` tip gets built as
`nightly`, an operator needs to fall back to the last *working* nightly
build. This audit protects only the exact current `nightly` digest; it does
not separately protect whichever digest was `nightly` immediately before
that. Implementing that would require reading `nightly-refresh.yml`'s own
GitHub Actions run history (GHCR itself exposes no tag history at all, only
the current pointer) via a new Actions API surface and an `actions: read`
permission this audit's workflow does not currently have — a real, but
separate, follow-up scope, not a silent gap: `accepted_ordinary_roots_per_package`
(30) already retains far more than one prior build's `sha-<commit>` root as
ordinary history regardless of channel-tag status, so a last-known-good
nightly commit typically stays available as an ordinary root in practice
even without dedicated channel-level protection for it. See issue #1501's
comment thread for the maintainer decision on whether to build the
dedicated Actions-API lookup.

**Rollback digests: `retention.rollback_anchors` (status: implemented).**
`protect_release_and_rollback_digests` names two distinct protections: the
*release* half (`stable-release-protected`, described above) is derived
automatically from real Git release tags. The *rollback* half has no such
automatic source — "this digest is a designated rollback target" is not a
fact Git history or any existing GHCR/CI record can derive on its own, it is
an explicit maintainer judgment call, typically made right after a
regression is found ("the last known-good digest before this regression must
stay available"). `release/stack-images.yml`'s `retention.rollback_anchors`
key is exactly that judgment call, made queryable: a maintainer-curated list
of exact `sha256:<64-hex>` digests, initially empty, that stays empty unless
and until a maintainer deliberately adds one. Every rollback anchor digest is
checked against every classified package version *before* any other
classification rule (class, tag shape, release-tag status, ordinary-history
rank) and independent of all of them — `reason=explicit-rollback-anchor` — so
a declared anchor is protected unconditionally, even if it would otherwise
fall far outside the ordinary-history budget.

`rollback_anchors` entries are **digest-only, never a git tag or ref**: a tag
or ref can be moved or deleted out from under an anchor, silently repointing
or breaking the guarantee this mechanism exists to provide, without the audit
ever noticing — a content-addressed digest cannot.
`scripts/untracked/validate-stack-images.sh` statically rejects any entry
that is not an exact `sha256:<64-hex>` string (reusing
`scripts/lib/sha-retention-audit.sh`'s `sra_is_rollback_anchor_digest`, the
single canonical definition of the accepted shape). That static check cannot
prove a listed digest actually *exists* under its intended package, since it
has no GHCR access — `scripts/untracked/gc-sha-retention-audit.sh` does that
check for real, at audit time, against the package versions it fetches from
GHCR, and marks every declared anchor digest it actually observes. **Any
declared anchor digest never observed in any audited first-party package (a
typo, an already-deleted digest, one that never existed) fails the entire
audit run closed** — an unproven rollback declaration is never silently
ignored, the same fail-closed posture used throughout this audit.

`rollback_anchors` is a manually maintained list, not an automated feature:
there is no automated expiry, no TTL, and no automated pruning of stale
entries. A maintainer who adds an anchor after a regression is also
responsible for removing it later once it is no longer needed, or the list
grows without bound. This does not overlap `setup.sh`'s
`reset-to-last-known-good-config` (which restores local Kea/PowerDNS
*configuration* snapshots on an operator's own install and never touches a
GHCR image tag or digest) or `setup.sh update`'s own pre-update backup (which
archives `LANCACHE_IMAGE_TAG` only inside that one operator's own local
backup archive, never in GHCR or this repository) — neither is a
centrally-recorded, GHCR-queryable registry, which is exactly why
`rollback_anchors` had to be its own declared list rather than derived from
either.

**Correction (2026-08-16):** an earlier revision of this section stated that
a separate rollback-anchor check was "considered and rejected as a fabricated
check with no real data source." That reasoning applied to *inferring* a
rollback target automatically (from GHCR tag history GHCR does not expose, or
from an operator's own local backup this repository cannot see) — it does not
apply to a maintainer directly declaring a digest in the manifest, which
needs no inference at all and is the same kind of manually-maintained
declaration as every other key in this `retention:` block. The mechanism
above was already implemented before that revision was written; this section
now reflects the actually-shipped design.

Automated cleanup must be explicitly approved and must consume the manifest
retention contract plus canonical accepted/protected identity evidence. A
read-only audit may classify and report candidates, but must not expose a switch
that turns the audit itself into a package-version deletion path. Destructive
activation is a separate approval and validation boundary and must fail closed
when acceptance, package-version schema, protected references, or artifact-graph
closure cannot be proven.

The audit reports every package version beyond the accepted-roots budget as a
labeled dry-run candidate (`decision=would-delete`) rather than folding it into
the same blanket `protect` reason as a genuinely protected identity, and each
reported candidate carries the real GHCR `created_at` build date for that
specific package version alongside its tag and digest, so a maintainer reading
the report sees which build a candidate is, not only a count. `created_at` is
used for this display purpose only; it is never read as input to the
acceptance-ranking decision itself (that ranking is git-history-derived, see
above) — using package-registry timestamps to decide ranking was the exact
`created_at`-reuse defect this audit was rebuilt to avoid. If GHCR does not
return a usable build date for a specific version, that is treated as a real
data-quality defect in the build/publish pipeline (e.g. a missing container
timestamp), reported as its own distinct finding, and never silently folded
into an unrelated protect/would-delete reason.

**Deferred, not yet authorized:** a future destructive-activation pass is
expected to need selection by more than "beyond the ordinary-roots budget" —
concretely, filtering by an explicit date or date range, by a tag matched
against a time span, and by free-text/pattern input (a specific `sha-<commit>`
alias, a full `sha256:` digest, or a PR-associated tag). None of that selection
or activation logic exists yet. This note exists so the dry-run report's data
model (build date, tag, digest, rank) is not redesigned again once that
decision is made, not as a description of current behavior.

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
