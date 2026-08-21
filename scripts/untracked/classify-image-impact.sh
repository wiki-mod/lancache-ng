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

touches_build_workflow() {
    # Changes here can alter how every service candidate is produced even when
    # no service source moved, so downstream build-sensitive gates must agree
    # that this is a workflow-wide impact.
    touches_exact ".github/workflows/build-push.yml" \
        || touches_exact ".github/workflows/build-tools.yml" \
        || touches_prefix ".github/actions/"
}

# What: extracts one top-level job's YAML block (its header line up to, but
#   not including, the next top-level job header) from stdin.
# Why: shared by touches_build_content()'s base-vs-head block comparison
#   below; matches check-workflow-service-lists.sh's own job-block extractor
#   so both scripts agree on where one job's block ends.
# From: Issue #1095 | PR #1628
_cii_job_block() {
    local job="  ${1}:"
    awk -v job="$job" '
        $0 == job { found=1 }
        found && /^  [a-zA-Z][a-zA-Z0-9_-]*:[[:space:]]*$/ && $0 != job { exit }
        found { print }
    '
}

# What: narrower, additive "did this change alter published image bytes"
#   signal, for exactly the two should-build/reuse gates that otherwise force
#   a full rebuild+rescan of every service on ANY touch to build-push.yml --
#   even a change confined to an unrelated job (merge-manifests, promote, a
#   lint job) that cannot alter what `docker buildx build --push` produces,
#   since only the build/build-arm64 jobs invoke that command. Does NOT
#   replace touches_build_workflow()/the `workflow` output above, which ~20
#   other, unaudited consumers (rust-quality/test/coverage/staging-tag gates)
#   keep reading unchanged.
# Why: build-push.yml is touched by nearly every CI-focused PR in this repo,
#   and each such PR was rebuilding and rescanning every one of the 9
#   first-party images regardless of which job it edited -- real compute
#   spent on images that could not possibly have changed.
# From: Issue #1095 | PR #1628
touches_build_content() {
    [[ "$force_all" == "true" ]] && return 0
    touches_exact ".github/workflows/build-tools.yml" && return 0
    touches_prefix ".github/actions/" && return 0
    touches_exact ".github/workflows/build-push.yml" || return 1

    # CHANGED_FILES-only callers (codeql.yml today) have no base/head refs to
    # diff the two sides of build-push.yml with -- fail safe rather than guess.
    [[ -n "${merge_base:-}" && -n "${head_ref:-}" ]] || return 0

    local job base_block head_block combined_head=""
    for job in build build-arm64; do
        base_block="$(git show "${merge_base}:.github/workflows/build-push.yml" 2>/dev/null | _cii_job_block "$job")"
        head_block="$(git show "${head_ref}:.github/workflows/build-push.yml" 2>/dev/null | _cii_job_block "$job")"
        [[ -n "$base_block" && -n "$head_block" ]] || return 0
        [[ "$base_block" == "$head_block" ]] || return 0
        combined_head+="$head_block"$'\n'
    done

    # What: fails safe if build/build-arm64 reference a YAML anchor (*name)
    #   defined outside their own two (unchanged) blocks.
    # Why: unchanged block text only proves unchanged effective behavior when
    #   every alias the blocks use resolves inside those same blocks; an
    #   anchor defined elsewhere (e.g. in a later job) could still change
    #   without either block's own text changing.
    # From: Issue #1095 | PR #1628
    local alias
    while IFS= read -r alias; do
        [[ -z "$alias" ]] && continue
        grep -q "&${alias}\b" <<< "$combined_head" || return 0
    done < <(grep -oE '\*[a-zA-Z0-9_-]+' <<< "$combined_head" | sed 's/^\*//' | sort -u)

    return 1
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
output_bool "workflow_build_relevant" touches_build_content
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
