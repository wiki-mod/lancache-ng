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
# FORCE_FULL_IMAGE_REBUILD=true forces the same maximal verdict as
# --all-changed, checked before either form above. This is a standing
# override switch (a GitHub Actions repository variable at the call site),
# not a per-invocation flag, for a temporary "rebuild everything" need with
# no code change required.
#
# Output is machine-readable key=value lines on stdout. The human-readable
# changed-file list is written to stderr so callers can append stdout directly
# to GITHUB_OUTPUT or consume one verdict without filtering diagnostics.
set -euo pipefail

force_all=false
if [[ "${FORCE_FULL_IMAGE_REBUILD:-}" == "true" || "${1:-}" == "--all-changed" ]]; then
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

# What: actions whose own change plausibly affects every service candidate.
# Why: kept in touches_build_workflow()'s workflow-wide fallback rather than
#   narrowed to a per-service output, unlike the other 12 known actions.
# From: Issue #1095
GLOBAL_ACTIONS=(
    ghcr-build-push-retry trivy-scan-exact-digest ghcr-attest-retry
    buildx-setup-retry ghcr-attest-with-cache trivy-scan-with-cache
    trivy-scan-retry
)

# What: the remaining 12 known .github/actions/* directories -- each either
#   feeds one of the explicit touches_action() checks below, or (the 5
#   pure PR-gate actions) legitimately produces no build/test-scoping
#   output at all.
# Why: kept separate from GLOBAL_ACTIONS so neither list repeats the
#   other's 7 names; KNOWN_ACTIONS below is their union.
# From: Issue #1095
NON_GLOBAL_KNOWN_ACTIONS=(
    build-tools-candidate-smoke cargo-with-sccache-fallback
    compose-healthchecks-check configure-rust-sccache
    derive-validation-network file-headers-check
    pr-title-convention-check pr-tracking-metadata-fetch-and-validate
    reserve-validation-subnet-stack rust-acceleration-preflight
    shellcheck-and-standing-guards wait-validation-stack-health
)

# What: all 19 known .github/actions/* directory names.
# Why: touches_unmapped_action() fails closed to workflow=true for any
#   action directory not in this list (e.g. a brand-new one).
# From: Issue #1095
KNOWN_ACTIONS=("${GLOBAL_ACTIONS[@]}" "${NON_GLOBAL_KNOWN_ACTIONS[@]}")

# What: touches_action(), except a diff to $1 that _cii_path_is_comment_only
#   proves is comment/blank-only (base_ref/head_ref form only) does not
#   count as a touch.
# Why: same G14 principle as workflow_diff_is_comment_only, applied per
#   action -- a comment-compression pass on a shared action must not force
#   a rebuild for every one of its consumers either.
# From: Issue #1095
touches_action() {
    [[ "$force_all" == "true" ]] && return 0
    touches_prefix ".github/actions/$1/" || return 1
    [[ -n "${merge_base:-}" && -n "${head_ref:-}" ]] || return 0
    local path
    while IFS= read -r path; do
        [[ "$path" == ".github/actions/$1/"* ]] || continue
        _cii_path_is_comment_only "$path" || return 0
    done < "$changed_files"
    return 1
}

# What: true if a changed path under .github/actions/ names a directory not
#   present in KNOWN_ACTIONS.
# Why: fail-closed default for a brand-new, not-yet-categorized action.
# From: Issue #1095
touches_unmapped_action() {
    [[ "$force_all" == "true" ]] && return 1
    local path action known name_matches
    while IFS= read -r path; do
        case "$path" in
            .github/actions/*)
                action="${path#.github/actions/}"
                action="${action%%/*}"
                known=false
                for name_matches in "${KNOWN_ACTIONS[@]}"; do
                    [[ "$action" == "$name_matches" ]] && { known=true; break; }
                done
                [[ "$known" == "true" ]] || return 0
                ;;
        esac
    done < "$changed_files"
    return 1
}

# What: prints $1 with every blank line and '#'-prefixed comment line
#   removed, except inside a YAML block-scalar body (a `key: |`/`key: >`
#   line and its more-indented or blank continuation lines), which is
#   printed byte-for-byte unchanged.
# Why: a leading '#' inside a block-scalar body is literal scalar data (e.g.
#   a heredoc body byte), not a parsed YAML/shell comment, so it must never
#   be stripped the way a real comment is.
# From: Issue #1095 (G14) | PR #1609 review
_cii_normalize_workflow_comments() {
    awk '
        BEGIN { in_block = 0; block_indent = -1 }
        {
            line = $0
            match(line, /^[ ]*/)
            indent = RLENGTH
            is_blank = (line ~ /^[ ]*$/)
            if (in_block) {
                if (is_blank || indent > block_indent) { print line; next }
                in_block = 0
            }
            if (!is_blank && match(line, /:[ ]*[|>][+-]?[0-9]?[ ]*(#.*)?$/)) {
                block_indent = indent
                in_block = 1
                print line
                next
            }
            stripped = line
            sub(/^[ ]*/, "", stripped)
            if (stripped == "" || substr(stripped, 1, 1) == "#") next
            print line
        }
    ' "$1"
}

# What: true only in the <base_ref> <head_ref> form, when $1's own diff is a
#   plain text modification whose comment/blank lines are the only
#   difference between its base and head content.
# Why: comparing the two normalized (block-scalar-safe comment/blank-stripped)
#   versions for exact equality proves nothing else changed, without having
#   to map individual diff hunk lines back to base/head line numbers. Shared
#   by workflow_diff_is_comment_only (repo-wide) and touches_action
#   (per-action) so both apply the identical, single-source check.
# From: Issue #1095 (G14) | PR #1609 review
_cii_path_is_comment_only() {
    local p="$1" status added deleted base_hash head_hash
    status="$(git diff --no-color --name-status "$merge_base" "$head_ref" -- "$p" | cut -f1)"
    [[ "$status" == "M" ]] || return 1

    read -r added deleted _ < <(git diff --no-color --numstat "$merge_base" "$head_ref" -- "$p")
    # What: binary shows numstat "-\t-" (fails the numeric check below); a
    #   mode-only change shows numeric "0\t0" (passes it, but its bytes
    #   are unchanged so the hash comparison below would too) -- both
    #   must fail closed rather than default to "no violation found".
    # Why: a status=M path with no real +/- content delta is not provably
    #   comment-only, it is simply unexamined by this function.
    # From: Issue #1095 (G14) | PR #1609 review
    [[ "$added" =~ ^[0-9]+$ && "$deleted" =~ ^[0-9]+$ ]] || return 1
    (( added > 0 || deleted > 0 )) || return 1

    base_hash="$(git show "${merge_base}:${p}" 2>/dev/null | _cii_normalize_workflow_comments /dev/stdin | sha256sum)"
    head_hash="$(git show "${head_ref}:${p}" 2>/dev/null | _cii_normalize_workflow_comments /dev/stdin | sha256sum)"
    [[ "$base_hash" == "$head_hash" ]]
}

# What: true only in the <base_ref> <head_ref> form, when every touched
#   build-workflow path is comment/blank-only per _cii_path_is_comment_only.
# Why: repo-wide gate for touches_build_workflow's own workflow-wide flag.
# From: Issue #1095 (G14) | PR #1609 review
workflow_diff_is_comment_only() {
    [[ -n "${merge_base:-}" && -n "${head_ref:-}" ]] || return 1

    local paths=() path
    while IFS= read -r path; do
        case "$path" in
            .github/workflows/build-push.yml | .github/workflows/build-tools.yml | .github/actions/*)
                paths+=("$path")
                ;;
        esac
    done < "$changed_files"
    [[ ${#paths[@]} -gt 0 ]] || return 1

    local p
    for p in "${paths[@]}"; do
        _cii_path_is_comment_only "$p" || return 1
    done

    return 0
}

touches_build_workflow() {
    # What: workflow-wide impact for build-push.yml/build-tools.yml, a
    #   genuinely-global action, or an unmapped (not-yet-categorized)
    #   action -- narrowed from a blanket ".github/actions/*" match.
    # Why: a single-consumer action (e.g. rust-acceleration-preflight,
    #   dns/ui only) must not force every service to rebuild; an unmapped
    #   action still fails closed to workflow-wide impact.
    # From: Issue #1095
    local touched=false name
    if touches_exact ".github/workflows/build-push.yml" \
        || touches_exact ".github/workflows/build-tools.yml"; then
        touched=true
    fi
    if [[ "$touched" == "false" ]]; then
        for name in "${GLOBAL_ACTIONS[@]}"; do
            if touches_action "$name"; then
                touched=true
                break
            fi
        done
    fi
    if [[ "$touched" == "false" ]] && touches_unmapped_action; then
        touched=true
    fi
    [[ "$touched" == "true" ]] || return 1
    workflow_diff_is_comment_only && return 1
    return 0
}

touches_codeql_rust() {
    # What: also fires on the two sccache actions codeql.yml itself
    #   consumes to compile the Rust database (verified: `uses:
    #   ./.github/actions/configure-rust-sccache` and
    #   `.../cargo-with-sccache-fallback` in that workflow file).
    # Why: touches_build_workflow no longer covers a single-consumer
    #   action; codeql.yml's own consumption is a separate signal.
    # From: Issue #1095
    touches_prefix "services/dns/nats-subscriber/" \
        || touches_prefix "services/ui/" \
        || touches_prefix "services/watchdog/" \
        || touches_build_workflow \
        || touches_action "configure-rust-sccache" \
        || touches_action "cargo-with-sccache-fallback" \
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

# What: dns_rust/ui/watchdog also fire on the two shared Rust-acceleration
#   quality/test/audit actions; dns_image/ui also fire on the shared
#   ccache-over-distcc preflight action (build-job impact, watchdog has no
#   compile step yet -- see AGENTS.md's AG-CI-002).
# Why: narrows touches_build_workflow()'s prior blanket ".github/actions/*"
#   match without losing per-service coverage for these two consumers.
# From: Issue #1095
if touches_prefix "services/dns/nats-subscriber/" \
    || touches_action "configure-rust-sccache" \
    || touches_action "cargo-with-sccache-fallback"; then
    printf 'dns_rust=true\n'
else
    printf 'dns_rust=false\n'
fi

if touches_prefix "services/dns/" || touches_action "rust-acceleration-preflight"; then
    printf 'dns_image=true\n'
else
    printf 'dns_image=false\n'
fi

if touches_prefix "services/ui/" \
    || touches_action "rust-acceleration-preflight" \
    || touches_action "configure-rust-sccache" \
    || touches_action "cargo-with-sccache-fallback"; then
    printf 'ui=true\n'
else
    printf 'ui=false\n'
fi

if touches_prefix "services/watchdog/" \
    || touches_action "configure-rust-sccache" \
    || touches_action "cargo-with-sccache-fallback"; then
    printf 'watchdog=true\n'
else
    printf 'watchdog=false\n'
fi
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

if touches_prefix "tools/build-tools/" || touches_action "build-tools-candidate-smoke"; then
    printf 'build_tools=true\n'
else
    printf 'build_tools=false\n'
fi

# What: true when a full-setup-validate-only action changed.
# Why: feeds that job's own gate instead of the workflow-wide fallback.
# From: Issue #1095
if touches_action "derive-validation-network" \
    || touches_action "reserve-validation-subnet-stack" \
    || touches_action "wait-validation-stack-health"; then
    printf 'validation_infra=true\n'
else
    printf 'validation_infra=false\n'
fi

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
