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

# What: touches_action() exempts comment/blank-only action diffs.
# Why: exempts G14's repo-wide comment-only exemption per action.
# From: Issue #1095
touches_action() {
    touches_prefix ".github/actions/$1/" || return 1
    [[ -n "${merge_base:-}" && -n "${head_ref:-}" ]] || return 0
    local path
    while IFS= read -r path; do
        [[ "$path" == ".github/actions/$1/"* ]] || continue
        _cii_path_is_comment_only "$path" || return 0
    done < "$changed_files"
    return 1
}

# What: actions forcing workflow=true for all services globally.
# Why: consumed globally; too infrequent to narrow further.
# From: Issue #1095
globally_triggering_actions=(
    ghcr-build-push-retry
    trivy-scan-exact-digest
    ghcr-attest-retry
    buildx-setup-retry
    ghcr-attest-with-cache
    trivy-scan-with-cache
    trivy-scan-retry
)

# What: list all recognized .github/actions/ directories.
# Why: unmapped actions fail closed; defaults to full rebuild.
# From: Issue #1095
known_actions=(
    "${globally_triggering_actions[@]}"
    rust-acceleration-preflight
    configure-rust-sccache
    cargo-with-sccache-fallback
    build-tools-candidate-smoke
    derive-validation-network
    reserve-validation-subnet-stack
    wait-validation-stack-health
    file-headers-check
    compose-healthchecks-check
    pr-tracking-metadata-fetch-and-validate
    pr-title-convention-check
    shellcheck-and-standing-guards
    # What: pure registry-auth wrapper, no image-content effect.
    # Why: it fails the job loudly, never produces a bad image.
    # From: Issue #1095
    docker-login-action-centralized-version
)

_cii_array_contains() {
    local needle="$1" straw
    shift
    for straw in "$@"; do
        [[ "$straw" == "$needle" ]] && return 0
    done
    return 1
}

touches_global_action() {
    local name
    for name in "${globally_triggering_actions[@]}"; do
        touches_action "$name" && return 0
    done
    return 1
}

# What: true for changed actions not in known_actions list.
# Why: unmapped actions fail closed; stale worse than rebuild.
# From: Issue #1095
touches_unmapped_action() {
    [[ "$force_all" == "true" ]] && return 1
    local path action_name
    while IFS= read -r path; do
        case "$path" in
            .github/actions/*)
                action_name="${path#.github/actions/}"
                action_name="${action_name%%/*}"
                _cii_array_contains "$action_name" "${known_actions[@]}" || return 0
                ;;
        esac
    done < "$changed_files"
    return 1
}

# What: removes comments/blanks except in YAML block-scalar bodies.
# Why: literal '#' inside block-scalars is data, not a comment.
# From: Issue #1095 | PR #1609
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

# What: returns true when diff is comment/blank-only (git form).
# Why: shared by workflow_diff_is_comment_only and touches_action.
# From: Issue #1095 | PR #1609
_cii_path_is_comment_only() {
    local p="$1" status added deleted base_hash head_hash
    status="$(git diff --no-color --name-status "$merge_base" "$head_ref" -- "$p" | cut -f1)"
    [[ "$status" == "M" ]] || return 1

    read -r added deleted _ < <(git diff --no-color --numstat "$merge_base" "$head_ref" -- "$p")
    # What: binary/mode-only numstat shapes must fail closed, not pass.
    # Why: status=M paths without +/- delta are unexamined, not proven.
    # From: Issue #1095 | PR #1609
    [[ "$added" =~ ^[0-9]+$ && "$deleted" =~ ^[0-9]+$ ]] || return 1
    (( added > 0 || deleted > 0 )) || return 1

    base_hash="$(git show "${merge_base}:${p}" 2>/dev/null | _cii_normalize_workflow_comments /dev/stdin | sha256sum)"
    head_hash="$(git show "${head_ref}:${p}" 2>/dev/null | _cii_normalize_workflow_comments /dev/stdin | sha256sum)"
    [[ "$base_hash" == "$head_hash" ]]
}

# What: true when every touched build-workflow path is comment-only.
# Why: gate for touches_build_workflow's workflow-wide flag.
# From: Issue #1095 | PR #1609
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

# What: jobs (+ preamble) determining build/build-arm64 publication.
# Why: named explicitly so rename/removal fails closed.
# From: Issue #1095
build_push_build_affecting_jobs=(
    detect-changes
    determine-push-reuse-scope
    determine-build-admission
    build
    build-arm64
)

# What: extracts job body from build-push.yml or exits.
# Why: distinguishes missing jobs from legitimately empty bodies.
# From: Issue #1095
_cii_extract_build_push_job() {
    local ref="$1" job="$2"
    git show "${ref}:.github/workflows/build-push.yml" 2>/dev/null | awk -v job="$job" '
        $0 == "jobs:" { in_jobs = 1; next }
        in_jobs && !in_target && $0 == "  " job ":" { in_target = 1; found = 1; print; next }
        in_jobs && in_target {
            if ($0 ~ /^  [A-Za-z_][A-Za-z0-9_-]*:$/) { in_target = 0 } else { print; next }
        }
        END { if (!found) exit 1 }
    '
}

# What: extracts build-push.yml preamble up to the jobs: line.
# Why: on:/env:/etc apply globally to all jobs; build-affecting.
# From: Issue #1095
_cii_extract_build_push_preamble() {
    git show "${1}:.github/workflows/build-push.yml" 2>/dev/null | sed -n '1,/^jobs:$/p' | sed '$d'  # pipefail-safe: no q/Q, reads to EOF (AG-VAL-032)
}

# What: extracts preamble and build-affecting jobs in fixed order.
# Why: content comparison immune to line-shift; not diff-hunk math.
# From: Issue #1095
_cii_extract_build_push_build_regions() {
    local ref="$1" job out
    out="$(_cii_extract_build_push_preamble "$ref")"
    [[ -n "$out" ]] || return 1
    printf '%s\n' "$out"
    for job in "${build_push_build_affecting_jobs[@]}"; do
        _cii_extract_build_push_job "$ref" "$job" || return 1
    done
}

# What: returns true when build-push.yml regions changed content.
# Why: shared by touches_build_workflow_reuse_scope for narrowing.
# From: Issue #1095
touches_build_push_build_path() {
    touches_exact ".github/workflows/build-push.yml" || return 1
    # Fail closed: no diff-ref context (e.g. a caller supplying only
    # CHANGED_FILES) cannot extract per-region content, so treat the file
    # as touched rather than guess.
    [[ -n "${merge_base:-}" && -n "${head_ref:-}" ]] || return 0
    local base_regions head_regions
    # Fail closed: an extraction failure (job renamed/removed, unexpected
    # structure) means this classifier can no longer prove the change is
    # scoped outside the build-affecting regions -- treat as touched.
    base_regions="$(_cii_extract_build_push_build_regions "$merge_base")" || return 0
    head_regions="$(_cii_extract_build_push_build_regions "$head_ref")" || return 0
    [[ "$base_regions" != "$head_regions" ]]
}

touches_build_workflow() {
    # What: workflow-wide impact for global build-workflow paths only.
    # Why: narrowed scope; per-service actions set their own outputs.
    # From: Issue #1095 | PR #1609
    local touched=false
    if touches_exact ".github/workflows/build-push.yml" \
        || touches_exact ".github/workflows/build-tools.yml" \
        || touches_global_action \
        || touches_unmapped_action; then
        touched=true
    fi
    [[ "$touched" == "true" ]] || return 1
    workflow_diff_is_comment_only && return 1
    return 0
}

# What: touches_build_workflow but build-push.yml is region-scoped.
# Why: narrower scope for push-reuse.sh; other consumers untouched.
# From: Issue #1095
touches_build_workflow_reuse_scope() {
    local touched=false
    if touches_build_push_build_path \
        || touches_exact ".github/workflows/build-tools.yml" \
        || touches_global_action \
        || touches_unmapped_action; then
        touched=true
    fi
    [[ "$touched" == "true" ]] || return 1
    workflow_diff_is_comment_only && return 1
    return 0
}

touches_codeql_rust() {
    # What: returns true for paths CodeQL's Rust extraction depends on.
    # Why: codeql.yml directly uses rust actions; don't silently drop.
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

# What: per-service actions extension off the shared workflow rule.
# Why: run per-service tests; track per service, not globally.
# From: Issue #1095
touches_dns_rust() {
    touches_prefix "services/dns/nats-subscriber/" \
        || touches_action "configure-rust-sccache" \
        || touches_action "cargo-with-sccache-fallback"
}
# What: true when the shared-scripts named build context changed.
# Why: issue #1781 removed the utilities image; proxy/dns/dhcp/dhcp-proxy/
#   ui/watchdog now COPY scripts/lib/verify-version-banner.sh from this
#   named build context instead (ntp never used it, so it is excluded from
#   every caller below), mirroring the pre-existing dns-domains rule below
#   for the same "named build context lives outside the service's own path
#   prefix" reason.
# From: Issue #1781 | PR #1783
touches_shared_scripts() {
    touches_exact "scripts/lib/verify-version-banner.sh"
}

touches_dns_image() {
    touches_prefix "services/dns/" \
        || touches_action "rust-acceleration-preflight" \
        || touches_shared_scripts
}
touches_ui() {
    touches_prefix "services/ui/" \
        || touches_action "rust-acceleration-preflight" \
        || touches_action "configure-rust-sccache" \
        || touches_action "cargo-with-sccache-fallback" \
        || touches_shared_scripts
}
touches_watchdog() {
    touches_prefix "services/watchdog/" \
        || touches_action "rust-acceleration-preflight" \
        || touches_action "configure-rust-sccache" \
        || touches_action "cargo-with-sccache-fallback" \
        || touches_shared_scripts
}
touches_dhcp() {
    touches_prefix "services/dhcp/" || touches_shared_scripts
}
touches_dhcp_proxy() {
    touches_prefix "services/dhcp-proxy/" || touches_shared_scripts
}

output_bool "dns_rust" touches_dns_rust
output_bool "dns_image" touches_dns_image
output_bool "ui" touches_ui
output_bool "watchdog" touches_watchdog
output_bool "dhcp" touches_dhcp
output_bool "dhcp_proxy" touches_dhcp_proxy
output_bool "ntp" touches_prefix "services/ntp/"
output_bool "syslog" touches_prefix "services/syslog/"

# services/proxy/Dockerfile COPYs services/dns/cdn-domains.txt into the image at
# build time (the dns-domains named build context), so a domain-list-only change
# must also rebuild the proxy image or its baked-in /etc/nginx/cdn-domains.txt
# goes stale until some unrelated services/proxy/ change next fires (#771).
# Independent of (not a replacement for) the services/proxy/ prefix rule and the
# separate dns_image rule above. Also rebuilds on a shared-scripts change (see
# touches_shared_scripts above) since proxy COPYs from that named context too.
if touches_prefix "services/proxy/" \
    || touches_exact "services/dns/cdn-domains.txt" \
    || touches_shared_scripts; then
    printf 'proxy=true\n'
else
    printf 'proxy=false\n'
fi

# What: build_tools true when build-tools-candidate-smoke changed.
# Why: action validates candidates; changes need re-verification.
# From: Issue #1095
touches_build_tools() {
    touches_prefix "tools/build-tools/" \
        || touches_action "build-tools-candidate-smoke"
}
output_bool "build_tools" touches_build_tools

# What: true when a full-setup-validate-only action changed.
# Why: no build-image consumer; must not skip validation re-run.
# From: Issue #1095
touches_validation_infra() {
    touches_action "derive-validation-network" \
        || touches_action "reserve-validation-subnet-stack" \
        || touches_action "wait-validation-stack-health"
}
output_bool "validation_infra" touches_validation_infra

output_bool "workflow" touches_build_workflow
output_bool "workflow_reuse_scope" touches_build_workflow_reuse_scope
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
