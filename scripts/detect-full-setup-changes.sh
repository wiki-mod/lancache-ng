#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Per-service change detection for the full-setup DEEP validation gate
# (#715). Emits `key=value` lines (proxy/dns_image/ui/watchdog/dhcp/
# dhcp_proxy/build_tools/deploy/scripts/setup_runtime/workflow/docs_only/
# should_run) describing what a PR actually changed, so the deep suite can
# (a) decide whether to run at all and (b) drive the same fail-closed
# staging-tag guard build-push.yml uses.
#
# SOURCE OF TRUTH NOTE: the path-to-service rules mirror the classifier
# build-push.yml's `detect-changes` job runs. As of #819 that job no longer
# carries the rules inline -- it delegates to scripts/classify-image-impact.sh,
# which is now the single authoritative copy of the shared per-path booleans.
# This script is STILL a hand-kept mirror of those rules (it adds its own
# should_run gate and omits classifier keys the deep gate does not need), a
# deliberate carry-over of the #715 choice to keep the two decoupled. If
# classify-image-impact.sh's path scoping changes, change this too.
# STATUS: as of 2026-07-14 this remains a separate mirror; folding it onto
# classify-image-impact.sh (source the shared booleans, keep should_run on top)
# is a viable next step but revisits #715's deliberate decoupling, so it is
# surfaced for maintainer review (#819) rather than done unilaterally here.
# Kept as a standalone script (not inline YAML) so
# tests/bats/detect_full_setup_changes.bats can exercise the rules against
# canned file lists without a runner.
#
# Input: a newline-separated list of changed paths, either from CHANGED_FILES
# (a file path) or, if unset, computed from the PR's real merge-base diff
# (BASE_SHA + GITHUB_SHA required in that case, exactly as build-push does).
# Output: written to GITHUB_OUTPUT when set, else stdout.
set -euo pipefail

changed_files=""
# Not `[[ -n ... ]] && rm -f ...`: under set -e, that guard's own false
# result (whenever _vit_tmp was never set, i.e. the CHANGED_FILES path was
# used instead of the git-diff path) becomes the script's exit code, making
# every otherwise-successful CHANGED_FILES-driven run report failure.
cleanup() {
    if [[ -n "${_vit_tmp:-}" ]]; then
        rm -f "$_vit_tmp"
    fi
}
trap cleanup EXIT

if [[ -n "${CHANGED_FILES:-}" ]]; then
    changed_files="$CHANGED_FILES"
else
    : "${BASE_SHA:?pull request base SHA is required when CHANGED_FILES is unset}"
    : "${GITHUB_SHA:?GitHub checkout SHA is required when CHANGED_FILES is unset}"
    # Diff from the real merge-base, never BASE_SHA directly: an unrelated PR
    # already merged into the base branch after this branch forked would
    # otherwise be misattributed as "this PR changed it" and defeat scoping
    # (build-push.yml hit this for real, #536). checkout must run with
    # fetch-depth: 0 for merge-base to have the history it needs.
    merge_base="$(git merge-base "$BASE_SHA" "$GITHUB_SHA")"
    _vit_tmp="$(mktemp)"
    git diff --name-only "$merge_base" "$GITHUB_SHA" > "$_vit_tmp"
    changed_files="$_vit_tmp"
fi

printf 'Changed files:\n' >&2
cat "$changed_files" >&2

touches_prefix() {
    local prefix="$1" path
    while IFS= read -r path; do
        [[ "$path" == "$prefix"* ]] && return 0
    done < "$changed_files"
    return 1
}

touches_exact() {
    local expected="$1" path
    while IFS= read -r path; do
        [[ "$path" == "$expected" ]] && return 0
    done < "$changed_files"
    return 1
}

# docs_only is true only when at least one file changed AND every changed
# file is documentation (*.md or docs/**). An empty diff is NOT docs_only
# (nothing to reason about), matching build-push.yml's own handling.
docs_only=true
any_changed=false
while IFS= read -r path; do
    any_changed=true
    case "$path" in
        *.md | docs/*) ;;
        *) docs_only=false ;;
    esac
done < "$changed_files"
if [[ "$any_changed" == "false" ]]; then
    docs_only=false
fi

output_bool() {
    local name="$1"
    shift
    if "$@"; then
        printf '%s=true\n' "$name"
    else
        printf '%s=false\n' "$name"
    fi
}

emit() {
    # services/proxy/Dockerfile COPYs services/dns/cdn-domains.txt into the
    # image at build time (the dns-domains named build context), so a
    # domain-list-only change must also set proxy=true or the proxy image's
    # baked-in /etc/nginx/cdn-domains.txt goes stale until some unrelated
    # services/proxy/ change next fires (#771). Independent of (not a
    # replacement for) the services/proxy/ prefix rule and the dns_image rule
    # below. Must mirror build-push.yml's detect-changes job exactly (see
    # SOURCE OF TRUTH NOTE above) so this script's staging-tag guard never
    # waits on a proxy PR-staging tag build-push.yml doesn't push.
    if touches_prefix "services/proxy/" \
        || touches_exact "services/dns/cdn-domains.txt"; then
        printf 'proxy=true\n'
    else
        printf 'proxy=false\n'
    fi
    output_bool "dns_image" touches_prefix "services/dns/"
    output_bool "ui" touches_prefix "services/ui/"
    output_bool "watchdog" touches_prefix "services/watchdog/"
    output_bool "dhcp" touches_prefix "services/dhcp/"
    output_bool "dhcp_proxy" touches_prefix "services/dhcp-proxy/"
    output_bool "build_tools" touches_prefix "tools/build-tools/"
    output_bool "deploy" touches_prefix "deploy/"
    output_bool "scripts" touches_prefix "scripts/"

    if touches_exact "setup.sh" || touches_prefix "scripts/"; then
        printf 'setup_runtime=true\n'
    else
        printf 'setup_runtime=false\n'
    fi

    # `workflow` drives the fail-closed staging guard, so it must mirror
    # build-push.yml's detect-changes set EXACTLY -- i.e. only the files whose
    # change actually makes build/build-arm64 rebuild every service
    # (build-push.yml, build-tools.yml, .github/actions/). A change to THIS
    # deep workflow file must NOT set it: build-push does not rebuild any
    # service for such a change, so its staging tags would never appear and
    # the guard would fail closed on tags nobody pushed. (Running the suite
    # for a change to this file is handled by should_run below instead.)
    if touches_exact ".github/workflows/build-push.yml" \
        || touches_exact ".github/workflows/build-tools.yml" \
        || touches_prefix ".github/actions/"; then
        workflow=true
    else
        workflow=false
    fi
    printf 'workflow=%s\n' "$workflow"

    printf 'docs_only=%s\n' "$docs_only"

    # should_run gates the whole deep suite. It runs whenever the PR touches
    # anything the running stack, its images, its deploy assembly, its driver
    # scripts, or the CI contract depend on -- i.e. anything non-docs that a
    # real end-to-end simulation could catch a regression in. A docs-only (or
    # empty) diff skips the expensive suite. Deliberately broad: #715 states
    # CI time is not the constraint, catching real runtime regressions
    # automatically is.
    if [[ "$docs_only" == "true" || "$any_changed" == "false" ]]; then
        printf 'should_run=false\n'
        return 0
    fi
    # should_run is deliberately broader than the staging guard's `workflow`
    # flag: it also fires for a change to any workflow/action (including THIS
    # deep workflow file), because such a change can alter what the suite
    # itself does and should be exercised -- even though it does not force a
    # service rebuild in build-push.
    if touches_prefix "services/" \
        || touches_prefix "deploy/" \
        || touches_prefix "scripts/" \
        || touches_prefix "tools/build-tools/" \
        || touches_prefix ".github/workflows/" \
        || touches_prefix ".github/actions/" \
        || touches_exact "setup.sh" \
        || [[ "$workflow" == "true" ]]; then
        printf 'should_run=true\n'
    else
        printf 'should_run=false\n'
    fi
}

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    emit >> "$GITHUB_OUTPUT"
else
    emit
fi
