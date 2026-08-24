#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Plans whether the full-setup deep validation needs to run for a PR diff.
# Shared service/build path classification comes from classify-image-impact.sh;
# only the full-setup-specific should_run policy remains here so the staging
# guard and the build pipeline cannot drift on which service a path affects.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
shared_classifier="$script_dir/classify-image-impact.sh"
: "${shared_classifier:?shared classifier path is required}"
[[ -f "$shared_classifier" ]] || {
    echo "Shared classifier '$shared_classifier' does not exist." >&2
    exit 1
}

changed_files=""
cleanup() {
    # CHANGED_FILES-driven callers create no temporary file. The explicit
    # branch prevents a false guard result from becoming the EXIT-trap status
    # under errexit.
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
    # Use the real merge-base so changes that reached the base branch after
    # this branch forked are not misattributed to the PR under validation.
    merge_base="$(git merge-base "$BASE_SHA" "$GITHUB_SHA")"
    _vit_tmp="$(mktemp)"
    git diff --name-only "$merge_base" "$GITHUB_SHA" > "$_vit_tmp"
    changed_files="$_vit_tmp"
fi

[[ -f "$changed_files" ]] || {
    echo "Changed-file input '$changed_files' does not exist." >&2
    exit 1
}

# should_run is intentionally broader than the shared service/build verdicts,
# so it still needs the raw path list for full-setup-only policy decisions.
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

# Issue #1095 (2026-07-31): scripts/ originally had no subdirectory
# structure to path-filter against, so before this allowlist existed ANY
# change under scripts/ -- including a pure CI/governance-lint script with
# zero product or stack dependency -- forced should_run=true below, running
# this suite's entire ~15-job real Docker-Compose deep validation (DNS/DHCP/
# NATS/proxy TLS/syslog/Admin UI). Confirmed for real against PR #1333
# (changed only AGENTS.md + the then-flat scripts/check-pr-title-convention.sh):
# run 30616274721 ran the full simulation suite end to end. PR #1341 (this
# same day) fixed it with a by-name array allowlist as an interim measure,
# since the real subdirectory move it should have been was blocked by
# concurrent in-flight PRs and an explicit "nothing happens before the
# v0.3.0 release" maintainer instruction (per issue #1095).
#
# scripts/tracked/ (issue #1095, executed post-v0.3.0-release): the 24
# scripts PR #1341 individually verified (full-repo grep sweep -- every
# .github/workflows/*.yml, every other scripts/** file, setup.sh, and every
# services/**/Dockerfile -- confirming each is invoked only from
# build-push.yml's own PR-gate jobs, build-tools-smoke.yml,
# backfill-stack-latest.yml, or orphaned-branches.yml, none of which are
# part of this suite's job graph, and is never sourced/invoked/COPYed by
# anything full-setup-deep-validate.yml/full-setup-sims.yml/
# full-setup-validate.yml or the simulation scripts they run exercises) have
# since actually moved into scripts/tracked/ (git mv, not a fresh file) and
# been dropped from the array below, which is now empty by design: ANY path
# under the scripts/tracked/ prefix is recognized as CI-tooling-only,
# exactly as an exact-match array entry used to be -- this is the one
# deliberate, narrow exception to "never widen should_run's narrowing by
# directory/prefix" below, because scripts/tracked/ is itself defined to
# contain only already-individually-verified scripts (the verification
# happens at move time, not at check time). A brand-new CI-tooling-only
# script gets this same treatment by being placed directly into
# scripts/tracked/ at creation, not by adding a new array entry here.
#
# Fail-closed by construction: this array (now empty, kept as a named,
# still-iterated variable rather than deleted outright, so a future
# individually-verified script that for some reason cannot move into
# scripts/tracked/ has a documented, tested fallback path) may only ever be
# used to NARROW should_run for a script that has been individually
# re-verified this way -- never to widen it by directory/prefix. Any
# scripts/ path that is neither under scripts/tracked/ nor listed here (a
# brand-new script, an unclassified one, anything under scripts/untracked/,
# or anything under scripts/lib/) still counts as should_run-relevant,
# exactly as touches_prefix "scripts/" did before this allowlist existed.
ci_tooling_only_scripts=()

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

# The shared classifier is the single source for every verdict that must agree
# with build-push. It writes diagnostics to stderr and machine-readable values
# to stdout, so command substitution retains only the key=value contract.
classifier_output="$(CHANGED_FILES="$changed_files" bash "$shared_classifier")"
declare -A shared=()
while IFS='=' read -r key value; do
    [[ -n "$key" ]] || continue
    shared["$key"]="$value"
done <<< "$classifier_output"

shared_keys=(
    proxy dns_image ui watchdog dhcp dhcp_proxy ntp syslog build_tools
    deploy scripts setup_runtime workflow workflow_reuse_scope docs_only
)
for key in "${shared_keys[@]}"; do
    case "${shared[$key]:-}" in
        true | false) ;;
        *)
            echo "Shared classifier did not emit a valid '$key' verdict." >&2
            exit 1
            ;;
    esac
done

# Empty and docs-only diffs are both cheap no-op cases, but they are distinct:
# the shared classifier intentionally reports docs_only=false for an empty diff.
any_changed=false
while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    any_changed=true
    break
done < "$changed_files"

full_setup_should_run() {
    if [[ "${shared[docs_only]}" == "true" || "$any_changed" == "false" ]]; then
        return 1
    fi

    # The deep suite is broader than service rebuild admission. Workflow files
    # can change the validation itself, deploy files change stack assembly, and
    # runtime-facing scripts can change behavior without changing an image path.
    # The scripts allowlist above is the one deliberate narrowing of this broad
    # fail-closed policy.
    if touches_prefix "services/" \
        || touches_prefix "deploy/" \
        || touches_scripts_beyond_ci_tooling_allowlist \
        || touches_prefix "tools/build-tools/" \
        || touches_prefix ".github/workflows/" \
        || touches_prefix ".github/actions/" \
        || touches_exact "setup.sh" \
        || [[ "${shared[workflow]}" == "true" ]]; then
        return 0
    fi
    return 1
}

emit() {
    local key
    # Preserve the detector's existing public output contract and order while
    # sourcing every shared value from one classifier implementation.
    for key in "${shared_keys[@]}"; do
        printf '%s=%s\n' "$key" "${shared[$key]}"
    done

    if full_setup_should_run; then
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
