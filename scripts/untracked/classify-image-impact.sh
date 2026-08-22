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

# What: true when a changed path falls under .github/actions/<name>/.
# Why: single helper so every per-action rule below and the global/unmapped
#   checks share one definition of "touched", instead of each repeating its
#   own prefix construction.
# From: Issue #1095 (G15)
touches_action() {
    touches_prefix ".github/actions/$1/"
}

# What: the subset of known .github/actions/ directories whose change must
#   keep forcing workflow=true (a full rebuild of all 10 services), because
#   they are consumed unconditionally by the shared build/merge-manifests/
#   promote pipeline (or run rarely enough that narrowing is not worth it).
# Why: PR #1634 proved a change to one narrowly-scoped action (an even
#   narrower case than these) forced all 10 services to rebuild; this array
#   is the audited, evidence-based list of actions where that blast radius
#   is actually correct, not incidental.
# From: Issue #1095 (G15)
globally_triggering_actions=(
    ghcr-build-push-retry
    trivy-scan-exact-digest
    ghcr-attest-retry
    buildx-setup-retry
    ghcr-attest-with-cache
    trivy-scan-with-cache
    trivy-scan-retry
)

# What: every .github/actions/ directory this script currently knows how to
#   categorize, global or narrow.
# Why: touches_unmapped_action() below needs this to recognize a brand-new,
#   not-yet-categorized action directory and fail closed for it, rather than
#   silently treating an unknown action as narrow-safe.
# From: Issue #1095 (G15)
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

# What: true when a changed .github/actions/<name>/ path's <name> is not in
#   known_actions.
# Why: fail-closed per Step 4's discipline -- a brand-new action directory
#   has no established consumer yet, so its blast radius is unknown until a
#   maintainer explicitly categorizes it above; under-triggering a stale
#   image is worse than an unnecessary rebuild.
# From: Issue #1095 (G15)
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

# What: true only in the <base_ref> <head_ref> form, when every touched
#   build-workflow path is a plain text modification whose comment/blank
#   lines are the only difference between its base and head content.
# Why: comparing the two normalized (block-scalar-safe comment/blank-stripped)
#   versions for exact equality proves nothing else changed, without having
#   to map individual diff hunk lines back to base/head line numbers.
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

    local p status added deleted base_hash head_hash
    for p in "${paths[@]}"; do
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
        [[ "$base_hash" == "$head_hash" ]] || return 1
    done

    return 0
}

touches_build_workflow() {
    # What: workflow-wide impact for build-push.yml/build-tools.yml itself, a
    #   genuinely-global action, or an unmapped action -- unless
    #   workflow_diff_is_comment_only proves the touched content is
    #   comment/blank-only outside any block scalar.
    # Why: G15 narrows this from "any .github/actions/* touch" (PR #1634's
    #   root cause: one narrowly-scoped action forced all 10 services to
    #   rebuild) to only the paths actually consumed globally; a
    #   dns/ui/watchdog/build-tools/full-setup-only action instead sets its
    #   own narrower output below, and an unmapped action still fails closed.
    # From: Issue #1095 (G14 | G15) | PR #1609 review
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

touches_codeql_rust() {
    # What: CodeQL's Rust database contains these three Rust crates. It also
    #   depends on the shared build workflow/actions and on its own
    #   workflow/config, so a change to any of those inputs must rerun the
    #   Rust extraction even when no Rust source file changed.
    # Why: codeql.yml's own Rust extraction job uses configure-rust-sccache
    #   and cargo-with-sccache-fallback directly (not just as a build-time
    #   optimization) -- G15's narrowing of touches_build_workflow() away
    #   from these two actions must not silently stop CodeQL from re-running
    #   when they change, since codeql.yml has a real, independent dependency
    #   on them that touches_prefix "services/ui/" etc. above cannot see.
    # From: Issue #1095 (G15)
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

# What: dns_rust/dns_image/ui/watchdog also true when a relocated-from-G15
#   action they actually consume changed, even though workflow itself no
#   longer does for that action (see touches_build_workflow's own comment).
# Why: rust-acceleration-preflight builds dns/ui in the `build` job
#   (matrix.rust); configure-rust-sccache/cargo-with-sccache-fallback are
#   used by dns/ui/watchdog's own quality/test/cargo-audit jobs -- narrowing
#   workflow must not silently stop re-running those jobs for a real change
#   to the action they depend on.
# From: Issue #1095 (G15)
touches_dns_rust() {
    touches_prefix "services/dns/nats-subscriber/" \
        || touches_action "configure-rust-sccache" \
        || touches_action "cargo-with-sccache-fallback"
}
touches_dns_image() {
    touches_prefix "services/dns/" \
        || touches_action "rust-acceleration-preflight"
}
touches_ui() {
    touches_prefix "services/ui/" \
        || touches_action "rust-acceleration-preflight" \
        || touches_action "configure-rust-sccache" \
        || touches_action "cargo-with-sccache-fallback"
}
touches_watchdog() {
    touches_prefix "services/watchdog/" \
        || touches_action "configure-rust-sccache" \
        || touches_action "cargo-with-sccache-fallback"
}

output_bool "dns_rust" touches_dns_rust
output_bool "dns_image" touches_dns_image
output_bool "ui" touches_ui
output_bool "watchdog" touches_watchdog
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

# What: build_tools also true when build-tools-candidate-smoke changed.
# Why: that action validates a build-tools candidate image; a real change to
#   it needs the same re-verification a tools/build-tools/ source change gets.
# From: Issue #1095 (G15)
touches_build_tools() {
    touches_prefix "tools/build-tools/" \
        || touches_action "build-tools-candidate-smoke"
}
output_bool "build_tools" touches_build_tools

# What: true when a full-setup-validate-only action (network derivation,
#   subnet reservation, or stack health wait) changed.
# Why: these actions have no build-image consumer at all -- narrowing
#   workflow away from them must not silently stop re-running the
#   full-setup-validate job that actually exercises them.
# From: Issue #1095 (G15)
touches_validation_infra() {
    touches_action "derive-validation-network" \
        || touches_action "reserve-validation-subnet-stack" \
        || touches_action "wait-validation-stack-health"
}
output_bool "validation_infra" touches_validation_infra

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
