#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Pure channel-name mapping for scripts/select-build-tools-image.sh: which
# GHCR "build-tools:<channel>" tag a given target ref should resolve to.
# Extracted into its own file (mirroring scripts/lib/ghcr-retry.sh's own
# convention, already sourced by select-build-tools-image.sh) specifically so
# this one mapping can be unit-tested with zero docker/network I/O -- the
# same reasoning setup.sh's lancache_stack_pointer_channel_for uses for the
# analogous operator-facing stack-channel mapping (see
# tests/bats/setup_channel_stable_nightly.bats's own header comment).
#
# Deliberately NOT `set -euo pipefail` at the top level: this file only
# defines a function for a caller to invoke under the caller's own shell
# options (same rationale as scripts/lib/ghcr-retry.sh).

# resolve_build_tools_channel <channel_ref>
#
# <channel_ref> is the caller's already-resolved target ref (normally
# ${GITHUB_BASE_REF:-${GITHUB_REF_NAME:-}}, so a PR resolves against what it
# will merge into, not its own feature-branch name).
#
# STATUS (2026-07-22, issue #1035, short-term "option 2"): `master` used to
# map to `nightly` (renamed from `edge` by #1056), but nothing has ever
# actively published a build-tools:nightly image -- `build-tools.yml`'s
# branch-triggered publish only ever writes `<sanitized-ref>-tc` and (default
# branch only) `latest`, and `build-push.yml`'s `promote` job only actively
# maintains `dev`. Every `master`-targeted PR was therefore resolving to a
# channel tag that could (and did) go silently stale/missing tools between
# the rare pushes to `master`, failing `select-build-tools-image.sh`'s own
# smoke test with an opaque "not pullable or did not satisfy smoke checks"
# error -- exactly the AG-VAL-026 failure class this script's own header
# comment warns about.
#
# Short-term fix: `master` now resolves to `dev` too, the same
# actively-maintained channel every other ref already uses below -- this
# does NOT stand up a new build-tools:nightly publisher (that remains
# issue #1035's open, deliberately-undecided long-term call, to be folded
# into the #825/#819 staged dev->nightly->latest channel-promotion design
# once that exists, matching how the equivalent *product* stack:nightly
# channel now gets a real scheduled promotion per #1056). This is narrowly
# a build-tools *tooling*-image channel change; it has no effect on the
# operator-facing LANCACHE_IMAGE_CHANNEL=nightly product channel, which
# already has its own working #1056 refresh.
resolve_build_tools_channel() {
    local channel_ref="$1"

    case "$channel_ref" in
        master)
            printf '%s\n' "dev"
            ;;
        *)
            # Every other ref this script is realistically invoked against --
            # v0.2.0/current_dev itself, or a feature/claude/* branch forked
            # from one of those without an open PR yet (e.g. a manual
            # workflow_dispatch run) -- is integration-branch work, so `dev`
            # (the channel those pushes actually promote) is the correct
            # default rather than the stable-only `latest`.
            printf '%s\n' "dev"
            ;;
    esac
}
