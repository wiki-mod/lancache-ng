#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Shared per-path change classifier for CI decisions that must agree about
# which repository paths affect which first-party images and validation gates.
# Keeping the path predicates here prevents build, CodeQL, release, and
# full-stack callers from growing independent copies of the same rules.
#
# Input, in mutually exclusive forms:
#   - --all-changed
#       Emits the maximal fail-safe verdict without reading a diff.
#   - classify-image-impact.sh <base_ref> <head_ref>
#       Diffs merge-base(base_ref, head_ref)..head_ref. Full git history is
#       required so a moving base branch cannot make unrelated changes look
#       like changes from the branch under test.
#   - CHANGED_FILES=<file>
#       Reads a newline-separated changed-path list. Tests and callers that
#       already resolved the event diff can use this without another git walk.
#
# Output is machine-readable key=value lines on stdout. The human-readable
# changed-file list is written to stderr so callers can append stdout directly
# to GITHUB_OUTPUT or consume one verdict without filtering diagnostics.
#
# Content-aware "workflow" refinement (issue #1095, G14): in the
# <base_ref> <head_ref> form only, a touched build-workflow path
# (build-push.yml/build-tools.yml/.github/actions/**) is downgraded from
# "workflow=true" to "workflow=false" when every one of its own changed lines
# is provably a blank line or a '#'-prefixed comment (see
# workflow_diff_is_comment_only below for why that is a real safety proof, not
# a heuristic). --all-changed and CHANGED_FILES carry no diff content to
# check, so they keep the original, fully conservative "any touch is
# build-affecting" behavior unchanged.
set -euo pipefail

force_all=false
if [[ "${1:-}" == "--all-changed" ]]; then
    force_all=true
fi

changed_files=""
cleanup() {
    # A CHANGED_FILES-driven run creates no temporary file. Use an explicit
    # guard so the false condition cannot become the EXIT trap's status under
    # callers that also use errexit.
    if [[ -n "${_cii_tmp:-}" ]]; then
        rm -f "$_cii_tmp"
    fi
}
trap cleanup EXIT

if [[ "$force_all" == "true" ]]; then
    : # No diff input is required when every path is deliberately considered changed.
elif [[ -n "${CHANGED_FILES:-}" ]]; then
    changed_files="$CHANGED_FILES"
else
    base_ref="${1:-}"
    head_ref="${2:-}"
    : "${base_ref:?base_ref (\$1) is required when CHANGED_FILES is unset}"
    : "${head_ref:?head_ref (\$2) is required when CHANGED_FILES is unset}"
    merge_base="$(git merge-base "$base_ref" "$head_ref")"
    _cii_tmp="$(mktemp)"
    git diff --name-only "$merge_base" "$head_ref" > "$_cii_tmp"
    changed_files="$_cii_tmp"
fi

if [[ "$force_all" == "true" ]]; then
    printf 'Changed files:\n(--all-changed: every path treated as changed)\n' >&2
else
    printf 'Changed files:\n' >&2
    cat "$changed_files" >&2
fi

touches_prefix() {
    [[ "$force_all" == "true" ]] && return 0
    local prefix="$1" path
    while IFS= read -r path; do
        [[ "$path" == "$prefix"* ]] && return 0
    done < "$changed_files"
    return 1
}

touches_exact() {
    [[ "$force_all" == "true" ]] && return 0
    local expected="$1" path
    while IFS= read -r path; do
        [[ "$path" == "$expected" ]] && return 0
    done < "$changed_files"
    return 1
}

touches_docs() {
    [[ "$force_all" == "true" ]] && return 0
    local path
    while IFS= read -r path; do
        case "$path" in
            *.md | docs/*)
                return 0
                ;;
        esac
    done < "$changed_files"
    return 1
}

# What: True only when merge_base/head_ref are set (the git-diff invocation
#   form) AND every changed line across the touched build-workflow paths is a
#   blank line or a '#'-prefixed comment.
# Why: A '#' has zero runtime effect in either YAML or the shell embedded in a
#   `run:` block, so a comment/blank-only diff is a real, provable proof the
#   touched content cannot have changed build/push behavior -- not a guess at
#   intent. Fails closed (returns 1) whenever no diff is available to check
#   (--all-changed/CHANGED_FILES) or any touched path has a real content line.
# From: Issue #1095 (G14)
workflow_diff_is_comment_only() {
    [[ -n "${merge_base:-}" && -n "${head_ref:-}" ]] || return 1

    # `${#paths[@]}` on a still-empty array is safe under `set -u` on bash
    # >= 4.4 (this repo's build-tools image is Debian-based rust:latest, per
    # AG-KD-009, always well past that); every other array in this codebase
    # (e.g. scripts/lib/known-good-snapshots.sh, scripts/untracked/check-
    # short-sha-truncation.sh) already relies on the identical baseline.
    local paths=() path
    while IFS= read -r path; do
        case "$path" in
            .github/workflows/build-push.yml | .github/workflows/build-tools.yml | .github/actions/*)
                paths+=("$path")
                ;;
        esac
    done < "$changed_files"
    [[ ${#paths[@]} -gt 0 ]] || return 1

    local line content
    while IFS= read -r line; do
        case "$line" in
            '+++ '* | '--- '*) continue ;;
            '+'* | '-'*)
                content="${line:1}"
                content="${content#"${content%%[![:space:]]*}"}"
                if [[ -n "$content" && "${content:0:1}" != "#" ]]; then
                    return 1
                fi
                ;;
        esac
    done < <(git --no-pager diff --no-color "$merge_base" "$head_ref" -- "${paths[@]}")

    return 0
}

touches_build_workflow() {
    # Changes here can alter how every service candidate is produced even when
    # no service source moved, so downstream build-sensitive gates must agree
    # that this is a workflow-wide impact -- unless workflow_diff_is_comment_only
    # (above) can prove the touched content is comment/blank-only, in which case
    # there is nothing here that could alter build/push behavior (issue #1095, G14).
    local touched=false
    if touches_exact ".github/workflows/build-push.yml" \
        || touches_exact ".github/workflows/build-tools.yml" \
        || touches_prefix ".github/actions/"; then
        touched=true
    fi
    [[ "$touched" == "true" ]] || return 1
    workflow_diff_is_comment_only && return 1
    return 0
}

touches_codeql_rust() {
    # CodeQL's Rust database contains these three Rust crates. It also depends
    # on the shared build workflow/actions and on its own workflow/config, so a
    # change to any of those inputs must rerun the Rust extraction even when no
    # Rust source file changed.
    touches_prefix "services/dns/nats-subscriber/" \
        || touches_prefix "services/ui/" \
        || touches_prefix "services/watchdog/" \
        || touches_build_workflow \
        || touches_exact ".github/workflows/codeql.yml" \
        || touches_prefix ".github/codeql/"
}

# docs_only is true only when at least one path changed and every changed path
# is documentation. An empty diff is not a docs-only skip. --all-changed is a
# deliberate fail-safe and therefore can never be docs-only.
docs_only=true
any_changed=false
if [[ "$force_all" == "true" ]]; then
    docs_only=false
else
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
fi

# IMAGE_IMPACT is deliberately broader than a service-image rebuild decision:
# operator-run deploy/config/setup/script changes also affect what is shipped,
# while pure documentation, GitHub plumbing, and tests do not alter a runtime
# artifact. The narrow exclusion keeps release traceability fail-closed.
image_impact=false
if [[ "$force_all" == "true" ]]; then
    image_impact=true
else
    while IFS= read -r path; do
        case "$path" in
            *.md | docs/* | .github/* | tests/*)
                ;;
            *)
                image_impact=true
                ;;
        esac
    done < "$changed_files"
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

output_bool "dns_rust" touches_prefix "services/dns/nats-subscriber/"
output_bool "dns_image" touches_prefix "services/dns/"
output_bool "ui" touches_prefix "services/ui/"
output_bool "watchdog" touches_prefix "services/watchdog/"
output_bool "dhcp" touches_prefix "services/dhcp/"
output_bool "dhcp_proxy" touches_prefix "services/dhcp-proxy/"
output_bool "ntp" touches_prefix "services/ntp/"
output_bool "syslog" touches_prefix "services/syslog/"

# utilities (issue #1556): the shared non-compiler CLI-tools image
# (curl/nano/lsof/ripgrep/findutils/coreutils/gettext-envsubst/jq/
# ca-certificates/zstd), wired into the build matrix below. Path-scoped the
# same way every other service is -- a change under services/utilities/
# rebuilds it; a change elsewhere in the repo (including an unrelated part
# of this workflow file) does not, beyond the existing workflow=true
# fallback every non-build-tools service already gets.
output_bool "utilities" touches_prefix "services/utilities/"

# services/proxy/Dockerfile COPYs services/dns/cdn-domains.txt into the image at
# build time (the dns-domains named build context), so a domain-list-only change
# must also rebuild the proxy image or its baked-in /etc/nginx/cdn-domains.txt
# goes stale until some unrelated services/proxy/ change next fires (#771).
# Independent of (not a replacement for) the services/proxy/ prefix rule and the
# separate dns_image rule above.
if touches_prefix "services/proxy/" \
    || touches_exact "services/dns/cdn-domains.txt"; then
    printf 'proxy=true\n'
else
    printf 'proxy=false\n'
fi

output_bool "build_tools" touches_prefix "tools/build-tools/"
output_bool "workflow" touches_build_workflow
output_bool "codeql_rust" touches_codeql_rust
output_bool "docs" touches_docs
printf 'docs_only=%s\n' "$docs_only"

if touches_exact "AGENTS.md" || touches_exact ".github/AGENTS.md"; then
    printf 'governance=true\n'
else
    printf 'governance=false\n'
fi

if touches_exact "setup.sh" || touches_prefix "scripts/"; then
    printf 'setup_runtime=true\n'
else
    printf 'setup_runtime=false\n'
fi

output_bool "deploy" touches_prefix "deploy/"

if touches_prefix "release/" \
    || touches_exact ".github/workflows/backfill-stack-latest.yml"; then
    printf 'release_contract=true\n'
else
    printf 'release_contract=false\n'
fi

output_bool "scripts" touches_prefix "scripts/"
printf 'IMAGE_IMPACT=%s\n' "$image_impact"
