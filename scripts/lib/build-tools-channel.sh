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
# STATUS (2026-07-24, issue #1153, follow-through of #1142/#825): `dev` was
# retired outright by #1142 -- nothing publishes `build-tools:dev` anymore,
# so the previous "everything resolves to dev" mapping this function used
# (issue #1035's short-term fix) now fails outright (a hard "denied" pull,
# since the tag doesn't exist at all, not silently-stale content). #1142's
# own PR deliberately left this file untouched, since the build-tools
# *tooling*-image channel is a distinct concept from the runtime
# `LANCACHE_IMAGE_CHANNEL` product channel it was scoped to -- but the two
# now need the same underlying branch-to-channel mapping, since `promote`
# only actively maintains `latest` (from `master`) and `nightly` (from
# `current_dev`) going forward; nothing feeds `dev` at all anymore.
#
# Mapping now mirrors #1142's decision exactly: `master` -> `latest` (the
# stable channel), everything else (current_dev, a feature/claude/* branch
# forked from it without an open PR yet, etc.) -> `nightly` (the actively-
# maintained integration channel). This is narrowly a build-tools *tooling*-
# image channel change; it has no effect on the operator-facing
# LANCACHE_IMAGE_CHANNEL product channel, which already has its own #1142
# mapping.
resolve_build_tools_channel() {
    local channel_ref="$1"

    case "$channel_ref" in
        master)
            printf '%s\n' "latest"
            ;;
        *)
            # Every other ref this script is realistically invoked against --
            # current_dev itself, or a feature/claude/* branch forked from it
            # without an open PR yet (e.g. a manual workflow_dispatch run) --
            # is integration-branch work, so `nightly` (the channel those
            # pushes actually promote per #1142) is the correct default
            # rather than the stable-only `latest`.
            printf '%s\n' "nightly"
            ;;
    esac
}
