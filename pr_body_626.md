CLD-1783778780

> **Transparency notice:** This contribution was developed with AI assistance. I reviewed and tested the result, but the implementation may be partly or largely AI-generated.

## Summary

`validate full-setup image` never actually tested a PR's own code -- it tested whatever channel image the PR's base branch last published. This PR makes same-repo `pull_request` runs push a PR-scoped GHCR staging tag and points that job at it, so it actually validates the PR's own commits.

## Linked Issues

Closes #626

## What This Actually Changes

Before: on a `pull_request` event, `docker/build-push-action`'s `push` param was hardcoded `${{ github.event_name != 'pull_request' }}`, so service images were built (compile/structural validation only) but never pushed to GHCR. `validate full-setup image` then resolved a channel tag (`dev`/`edge`/`latest`) from the PR's *base branch* and pulled that -- which only reflects whatever the base branch last published via a real *push* event, completely disconnected from the PR's own commits. Confirmed live on PR #621: a changed error string in `services/ui/src/nats_config.rs` never showed up in the validated container's logs, because the job pulled `ui:dev` (last published by `v0.2.0`'s own push, PR #594), not #621's own build.

After: a same-repo PR (no fork PRs exist in this project today) pushes a `pr-<N>-sha-<short>` staging tag per touched service, and `validate full-setup image` resolves to that tag instead of the base-ref channel on `pull_request` events. Push events keep the exact same base-ref-channel behavior as before (unaffected by this change).

## What This PR Fixes / Adds

Fixes issue #626 in full, including a GC mechanism for the new staging tags (in scope per the issue's own "Proposed fix" section, which explicitly asked for a cleanup story). Everything the issue asked for is addressed in this PR.

## What Changed In Code

`build-push.yml` on `v0.2.0` is not the amd64-only single-job design issue #626's text describes -- it was restructured by #592 (native arm64 builds) after the issue was filed. `build` (self-hosted amd64) and `build-arm64` (GitHub-hosted `ubuntu-24.04-arm`) each push a per-arch tag (`sha-<short>-amd64` / `sha-<short>-arm64`), and `merge-manifests` combines them into the real `sha-<short>` multi-platform tag via `docker buildx imagetools create` (registry-side manifest merge, no rebuild). I traced this live plumbing before writing any code, since the issue's own described pattern (`sha-<commit>-standalone-<arch>` in `build-tools.yml`) no longer exists there either -- it was consolidated away in #606's arm64-native-split cleanup. The *idea* re-appeared in `build-push.yml`'s own arch split instead, so that's the pattern I mirrored.

1. **`build` / `build-arm64`**: new "Compute PR staging tag" step computes `pr-<N>-sha-<head-short>-{amd64,arm64}` from the PR's actual head commit -- not `docker/metadata-action`'s default `type=sha` behavior, which uses the ephemeral `pull_request` merge-commit SHA (confirmed against upstream `docker/metadata-action` docs), which would churn every time the base branch moves even with no new commits on the PR. `push:` and the "Log in to GHCR" steps (including the retry-path re-auth) now also fire for same-repo PRs, gated by a fork-safety check (`github.event.pull_request.head.repo.full_name == github.repository`) even though this repo has no fork PRs today. `packages: write` was already granted at the job level -- no permission change needed there.
2. **`merge-manifests`**: now also runs on `pull_request` and combines the two per-arch PR legs into the real `pr-<N>-sha-<short>` tag, mirroring its existing `sha-<short>` merge logic exactly (including the "amd64 leg exists but arm64 doesn't → error" invariant). The existing `sha-<short>` merge step stays gated `if: github.event_name != 'pull_request'` -- its inputs are never pushed on a PR, so running it there would just be seven no-op "skip" notices.
3. **`full-setup-validate`**: `needs: merge-manifests` added (alongside `promote`); its `if:` now branches on event type -- PR events wait for `merge-manifests`, push events keep waiting for `promote` exactly as before. **This ordering fix matters as much as the tag itself.** The job previously depended only on the lightweight `detect-changes` job on PR events, so it started (and often finished) long before `build`/`build-arm64` got through compiling Rust. Without fixing the ordering, the job would find no staging tags yet and silently fall back to stale base-channel content anyway -- reproducing this exact bug with the tag mechanism technically "in place." I traced the real timing (not just the tag-resolution logic) before deciding this was necessary.
   - `deploy/full-setup/docker-compose.yml` uses one `LANCACHE_IMAGE_TAG` for every service, but only touched services get a staging tag pushed (deliberate -- real additional push cost, not "rebuild everything per PR for free," per the issue's own scope note). A new "Ensure PR staging tags exist for full-setup services" step back-fills any untouched service (`proxy`/`dns`/`watchdog`/`ui`, plus `build-tools` for the "Run client simulation" step further down) with a cheap `imagetools create` copy from the base-ref channel image -- mirrors `promote`'s own pattern, no rebuild or re-pull.
   - "Show full-setup service logs" now dumps container logs unconditionally (not just on failure), so a *green* run is independently checkable as having actually tested the right image, not just trusted.
4. **New workflow `.github/workflows/gc-pr-staging-images.yml`**: reaps `pr-<N>-sha-*` tags once their PR closes (`pull_request: closed` trigger + a weekly scheduled sweep as a safety net for anything the close trigger misses).

## Why This Matters For Users / Operators

No operator-visible runtime change -- this is CI-only. The consequence is trust in CI signal: every PR touching a runtime service previously got a `validate full-setup image` result disconnected from its own diff, sometimes coincidentally green, sometimes red for reasons unrelated to the PR (seen repeatedly per the issue: #616, #619, #621, and a manual dispatch on #624's branch). That erodes confidence in the check and burns real review time chasing "failures" that are actually base-branch drift, or worse, missing real regressions because a red base channel masked them, or a stale-but-green channel hid an actual breakage in the PR itself.

## Scope Boundaries

- Does not change the `push`/`edge`/`latest`/`dev` channel *promotion* contract (`docs/release-versioning.md`) -- only what `validate full-setup image` consumes on `pull_request` events specifically.
- Does not touch `container-scan` (Trivy vulnerability scanning), which stays unconditionally `if: github.event_name != 'pull_request'` -- it never got an image on a PR before this change and still doesn't; expanding scan coverage to PR-pushed images is a separate cost/scope decision, not part of #626.
- Does not touch provenance attestation (`actions/attest`) for the new PR staging tags -- attestation stays trusted-ref-only, consistent with existing security scanning policy for PR builds.
- `.github/workflows/full-setup-validate.yml` (the separate, manually-dispatched standalone workflow) is unchanged -- see Local Scope Evidence for why.
- The GC workflow (`gc-pr-staging-images.yml`) needs a repo/org admin to create and add a classic PAT (`GHCR_PACKAGE_DELETE_PAT`, scopes `read:packages`+`delete:packages`) before it can actually delete anything -- see Validation for why the default `GITHUB_TOKEN` cannot do this. This is a deliberate human decision I did not make unattended (a new credential with org package-delete rights has real operational impact). Until that secret exists, the GC job detects its absence and skips with a loud warning instead of failing; staging tags accumulate in GHCR (harmlessly, just storage) in the meantime.

## Risk / Rollback / Follow-up

**Risk**: same-repo PRs now push real images to GHCR (additional network/storage cost per touched service per PR run) -- explicitly accepted as a deliberate tradeoff in the issue's own "Proposed fix" section, not an oversight. A fork PR (none exist today) would fail the "Log in to GHCR" step with a 403 rather than silently doing nothing, because GitHub's platform-level fork-PR token restriction is a backstop behind my own fork-safety `if:` checks -- that's a build failure, not a security hole, but worth knowing before this project ever accepts fork contributions.

**Rollback**: revert this commit. No data migration, no channel/tag contract change; only newly-created `pr-<N>-sha-*` tags in GHCR would need occasional manual cleanup if reverted before the GC workflow ever ran.

**Follow-up**: `GHCR_PACKAGE_DELETE_PAT` needs to be created and added as a secret for GC to actually function (see Scope Boundaries). Until then this is a monitor-only gap (GHCR storage growth), not a correctness risk.

## Local Scope Evidence

```text
.github/workflows/build-push.yml
.github/workflows/gc-pr-staging-images.yml
```

`full-setup-validate.yml` was deliberately NOT touched: it takes an explicit `workflow_dispatch` `image_tag` input (default `latest`), no automatic base-ref resolution at all, so there's no "silently wrong" illusion to fix there -- a human must explicitly type in the tag. #623/#624's `VALIDATION_SUBNET` per-run derivation is a different, already-solved problem. Once this PR merges, dispatching that workflow with `image_tag: pr-<N>-sha-<short>` becomes a valid way to manually re-validate a specific still-open PR's images, but no code change was needed to enable that.

## Validation

```bash
# actionlint (also shellchecks embedded run: blocks) against the full changed
# workflow set, run on a self-hosted runner inside the build-tools:edge
# container -- could not run locally, Rust/Docker toolchain is broken on the
# Windows dev machine (see AGENTS.md):
docker run --rm -v "$PWD:/work:ro" -w /work ghcr.io/wiki-mod/lancache-ng/build-tools:edge \
  bash -lc "actionlint -config-file .github/actionlint.yaml .github/workflows/*.yml"
# -> clean, no errors

# Manually verified the core docker buildx imagetools create retag mechanism
# end-to-end on a real self-hosted runner against the real registry: retagged
# ghcr.io/wiki-mod/lancache-ng/watchdog:edge to a throwaway
# pr-99999-sha-abcdef1 tag (registry-side copy, zero local pull), confirmed
# digests matched exactly, then confirmed docker compose resolves it:
docker buildx imagetools create --prefer-index=false \
  -t ghcr.io/wiki-mod/lancache-ng/watchdog:pr-99999-sha-abcdef1 \
  ghcr.io/wiki-mod/lancache-ng/watchdog:edge
LANCACHE_IMAGE_REGISTRY=ghcr.io LANCACHE_IMAGE_PREFIX=wiki-mod/lancache-ng \
  LANCACHE_IMAGE_TAG=pr-99999-sha-abcdef1 \
  docker compose -f deploy/full-setup/docker-compose.yml pull watchdog
# -> pulled ghcr.io/wiki-mod/lancache-ng/watchdog:pr-99999-sha-abcdef1 successfully

# This also surfaced the shared-digest/version collision the GC script now
# guards against: GHCR "package versions" are keyed by digest, not tag, and
# the retag above added pr-99999-sha-abcdef1 as an ALIAS on the same package
# version as the live edge and sha-6447b2c tags (confirmed via `gh api
# orgs/wiki-mod/packages/container/lancache-ng%2Fwatchdog/versions`) -- a
# naive "delete this tag's version" GC would have taken edge down with it.
# gc-pr-staging-images.yml only deletes a version when every tag on it is a
# closed-PR pr-<N>-sha-* tag; any channel/source tag on the same version
# protects the whole thing.

# GitHub-hosted PAT deletion requirement confirmed against GitHub's own REST
# API docs (not assumed): "Delete package version" endpoints require a
# classic PAT with read:packages+delete:packages; GITHUB_TOKEN cannot do it
# regardless of the packages: write permission granted to a job.

# Real GitHub Actions round-trip on this PR itself (the actual acceptance
# criterion -- confirms the validate job tests THIS PR's own commits, not
# stale base-branch content): [to be updated once the run completes]
```

## Type of change
- [x] Bug fix
- [ ] New feature
- [ ] Refactor
- [ ] Documentation
- [ ] Chore

## Changelog

Fixed: `validate full-setup image` CI check now tests a pull request's own code changes instead of stale content the base branch last published, for same-repo PRs that touch `deploy/` or CI workflow files. Adds a new `gc-pr-staging-images.yml` workflow to clean up the resulting per-PR GHCR staging tags once a PR closes (requires a repo/org admin to configure a `GHCR_PACKAGE_DELETE_PAT` secret before it becomes active).
