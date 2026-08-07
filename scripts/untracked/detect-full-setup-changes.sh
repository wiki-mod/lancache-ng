#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Per-service change detection for the full-setup DEEP validation gate
# (#715). Emits `key=value` lines (proxy/dns_image/ui/watchdog/dhcp/
# dhcp_proxy/ntp/syslog/build_tools/deploy/scripts/setup_runtime/workflow/
# docs_only/should_run) describing what a PR actually changed, so the deep
# suite can (a) decide whether to run at all and (b) drive the same
# fail-closed staging-tag guard build-push.yml uses.
#
# ntp (#1296, 2026-07-30): added alongside dhcp/dhcp_proxy so a PR that
# actually touches services/ntp/ is correctly treated as "touched" by
# ensure-pr-staging-images.sh's fail-closed guard, instead of being silently
# backfilled from the base channel/commit -- the same #626 stale-content bug
# class dhcp/dhcp_proxy were fixed for in #1305. See that script's own
# full_setup_services=(...) comment for why ntp itself now belongs in the
# full-setup service list.
#
# syslog (#1428, 2026-08): added the same way, for the same reason, once the
# combined fluent-bit+syslog-ng first-party image (services/syslog/) joined
# the build matrix.
#
# SOURCE OF TRUTH NOTE: the path-to-service rules mirror the classifier
# build-push.yml's `detect-changes` job runs. As of #819 that job no longer
# carries the rules inline -- it delegates to scripts/untracked/classify-image-impact.sh,
# which is now the single authoritative copy of the shared per-path booleans.
# This script is STILL a hand-kept mirror of those rules (it adds its own
# should_run gate and omits classifier keys the deep gate does not need), a
# deliberate carry-over of the #715 choice to keep the two decoupled. If
# classify-image-impact.sh's path scoping changes, change this too.
# STATUS: as of 2026-07-14 this remains a separate mirror; folding it onto
# classify-image-impact.sh (source the shared booleans, keep should_run on top)
# is a viable next step but revisits #715's deliberate decoupling, so it is
# surfaced for maintainer review (#819) rather than done unilaterally here.
# F-16 (#1095, 2026-07-31) note: should_run's ci_tooling_only_scripts
# allowlist (added below) is this script's own addition -- classify-
# image-impact.sh has no should_run concept and therefore no equivalent
# allowlist to mirror. Narrowing should_run here does not create mirror
# drift against classify-image-impact.sh's own `scripts`/`setup_runtime`
# outputs, which stay untouched and blunt (see that script's own comments --
# they only drive an informational ci_scope_policy notice, with no heavy-job
# effect, so narrowing them would carry real collision risk against PR #1331
# for zero CI-cost benefit).
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

# F-16 (issue #1095, 2026-07-31): scripts/ has no subdirectory structure to
# path-filter against, so before this allowlist existed ANY change under
# scripts/ -- including a pure CI/governance-lint script with zero product or
# stack dependency -- forced should_run=true below, running this suite's
# entire ~15-job real Docker-Compose deep validation (DNS/DHCP/NATS/proxy
# TLS/syslog/Admin UI). Confirmed for real against PR #1333 (changed only
# AGENTS.md + scripts/tracked/check-pr-title-convention.sh): run 30616274721 ran the
# full simulation suite end to end.
#
# Every script below was individually verified (not classified by name
# pattern alone, per AG-WF-028) via a full-repo grep sweep -- every
# .github/workflows/*.yml, every other scripts/** file, setup.sh, and every
# services/**/Dockerfile -- to confirm it is invoked only from build-push.yml's
# own PR-gate jobs, build-tools-smoke.yml, backfill-stack-latest.yml, or
# orphaned-branches.yml, none of which are part of this suite's job graph, and
# is never sourced/invoked/COPYed by anything
# full-setup-deep-validate.yml/full-setup-sims.yml/full-setup-validate.yml (or
# the simulation scripts they run) exercises. A change to one of these, and
# ONLY these, does not need to re-run the deep suite.
#
# Fail-closed by construction: this list may only ever be used to NARROW
# should_run for a script that has been individually re-verified this way --
# never to widen it by directory/prefix. Any scripts/ path not in this exact
# list (a brand-new script, an unclassified one, or anything under
# scripts/lib/) still counts as should_run-relevant, exactly as
# touches_prefix "scripts/" did before this allowlist existed.
#
# scripts/tracked/ vs scripts/untracked/ (issue #1095 F-16, decided
# 2026-07-31, not yet populated -- the directory-by-directory migration of
# the scripts above out of this array and into scripts/tracked/ is deferred
# until after the v0.3.0 release; "nothing happens before the release" is an
# explicit maintainer instruction, not an oversight): once a script has been
# individually re-verified and moved into scripts/tracked/, ANY path under
# that prefix is recognized as CI-tooling-only below, same as an exact match
# against the array -- this is the one deliberate, narrow exception to the
# "never widen by directory/prefix" rule just above, because scripts/tracked/
# is itself defined to contain only already-individually-verified scripts (the
# verification happens at move time, not at check time). scripts/untracked/
# (like scripts/lib/) is NOT given any special prefix handling -- it needs
# none, since anything not matched below already falls through to
# should_run-relevant by default, exactly like an unclassified script today.
ci_tooling_only_scripts=(
    "scripts/tracked/check-action-node-versions.sh"
    "scripts/tracked/check-bats-path-filter-coverage.sh"
    "scripts/tracked/check-build-tools-smoke-coverage.sh"
    "scripts/tracked/check-changelog-direct-edit.sh"
    "scripts/tracked/check-compose-healthchecks.sh"
    "scripts/tracked/check-executable-bits.sh"
    "scripts/tracked/check-file-headers.sh"
    "scripts/tracked/check-governance-guards.sh"
    "scripts/tracked/check-idempotence-test-coverage.sh"
    "scripts/tracked/check-language-policy.sh"
    "scripts/tracked/check-line-endings.sh"
    "scripts/tracked/check-logging-matrix.sh"
    "scripts/tracked/check-mutable-refs.sh"
    "scripts/tracked/check-naming-consistency.sh"
    "scripts/tracked/check-orphaned-branches.sh"
    "scripts/tracked/check-pr-title-convention.sh"
    "scripts/tracked/check-pr-tracking-metadata.sh"
    "scripts/tracked/check-setup-prompt-drift.sh"
    "scripts/tracked/check-stable-external-images.sh"
    "scripts/tracked/check-validation-subnet-wrapper-coverage.sh"
    "scripts/tracked/check-vex-drift.sh"
    "scripts/tracked/check-workflow-service-lists.sh"
    "scripts/tracked/test-governance-guards.sh"
    "scripts/tracked/validate-pr-template.sh"
)

# True when at least one changed path is under scripts/ AND that path is NOT
# on the allowlist above. False when every scripts/-prefixed changed path is a
# known-safe CI-tooling script, or when nothing under scripts/ changed at all
# (mirrors touches_prefix's own "no match" semantics so the should_run clause
# below reads as a drop-in narrowing of the old touches_prefix "scripts/"
# check, not a different kind of condition).
touches_scripts_beyond_ci_tooling_allowlist() {
    local path allowed known
    while IFS= read -r path; do
        [[ "$path" == "scripts/"* ]] || continue
        allowed=false
        if [[ "$path" == "scripts/tracked/"* ]]; then
            allowed=true
        else
            for known in "${ci_tooling_only_scripts[@]}"; do
                if [[ "$path" == "$known" ]]; then
                    allowed=true
                    break
                fi
            done
        fi
        [[ "$allowed" == "false" ]] && return 0
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
    output_bool "ntp" touches_prefix "services/ntp/"
    # syslog (issue #1428): mirrors classify-image-impact.sh's own new
    # syslog output (see SOURCE OF TRUTH NOTE above) -- needed so
    # ensure-pr-staging-images.sh's fail-closed guard can tell a PR that
    # actually touched services/syslog/ apart from one that did not,
    # instead of always falling through to its untouched-service backfill
    # path for this service.
    output_bool "syslog" touches_prefix "services/syslog/"
    output_bool "build_tools" touches_prefix "tools/build-tools/"
    output_bool "deploy" touches_prefix "deploy/"
    # `scripts`/`setup_runtime` deliberately stay a blunt, unnarrowed
    # touches_prefix "scripts/" here (unlike should_run's own scripts/ clause
    # below, which the F-16 allowlist narrows) -- neither is declared as an
    # output of full-setup-deep-validate.yml's `plan` job (confirmed: only
    # should_run/image_tag/pr_staging_available/base_channel_tag/workflow/
    # proxy/dns_image/watchdog/ui/build_tools/dhcp/dhcp_proxy/ntp are), so
    # narrowing them would change nothing any consumer reads. They exist here
    # only as a raw "did anything under scripts/ change at all" signal for
    # anyone reading this script's own stdout/log output directly.
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
    # automatically is -- see the scripts/ clause below (F-16, #1095) for the
    # one place this pass narrows that breadth, and why #715's own intent is
    # preserved rather than overridden.
    if [[ "$docs_only" == "true" || "$any_changed" == "false" ]]; then
        printf 'should_run=false\n'
        return 0
    fi
    # should_run is deliberately broader than the staging guard's `workflow`
    # flag: it also fires for a change to any workflow/action (including THIS
    # deep workflow file), because such a change can alter what the suite
    # itself does and should be exercised -- even though it does not force a
    # service rebuild in build-push.
    #
    # The scripts/ clause is intentionally narrower than a plain
    # touches_prefix "scripts/" (F-16, #1095): #715's "driver scripts" intent
    # was scripts the running stack actually exercises (the *-simulation.sh
    # scripts, setup.sh's own helpers, etc.), not a pure CI/governance-lint
    # script with zero stack dependency -- see
    # touches_scripts_beyond_ci_tooling_allowlist's own header comment above
    # for exactly which scripts were verified to fall in the latter bucket and
    # how. This still fails closed: any scripts/ change NOT on that verified
    # allowlist keeps firing should_run exactly as the old blanket prefix
    # check did.
    if touches_prefix "services/" \
        || touches_prefix "deploy/" \
        || touches_scripts_beyond_ci_tooling_allowlist \
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
