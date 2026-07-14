#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Shared per-path change classifier for the Build & Push pipeline. Emits the
# same `key=value` booleans build-push.yml's `detect-changes` job used to
# compute inline, plus one additive verdict, `IMAGE_IMPACT`, describing whether
# the diff touches anything that ends up in a shipped container image or the
# artifacts operators actually run.
#
# WHY this exists as a standalone script: two independent consumers need the
# identical verdict and must not drift from each other:
#   1. build-push.yml's `detect-changes` job (PR path scoping), which used to
#      carry this exact logic inline.
#   2. the version-bump-and-tag step in the `promote` job (#819), which decides
#      whether a promote run warrants a new patch (Z) release by classifying
#      the diff from the last vX.Y.Z tag's commit to the current tip.
# A single script keeps "does this change affect a shipped image?" defined in
# exactly one place instead of a second, drifting copy.
#
# Input (two mutually exclusive forms):
#   - Positional: classify-image-impact.sh <base_ref> <head_ref>
#     Diffs from merge-base(base_ref, head_ref) to head_ref. For a base_ref
#     that is already an ancestor of head_ref (e.g. the last release tag's
#     commit vs. the branch tip), merge-base(base, head) == base, so this is a
#     plain base..head diff; for two independently-moved branch snapshots it
#     correctly ignores files an unrelated already-merged PR changed on the
#     base branch after this branch forked (build-push.yml hit this for real,
#     #536). Requires full history (checkout fetch-depth: 0).
#   - CHANGED_FILES=<file>: a newline-separated list of changed paths, used by
#     tests to exercise the rules against canned lists without a git repo.
# Output: `key=value` lines on stdout. Callers append to GITHUB_OUTPUT
# themselves (`>> "$GITHUB_OUTPUT"`) or grep a single verdict; the human-
# readable "Changed files:" listing goes to stderr so stdout stays a clean
# machine-readable stream.
set -euo pipefail

changed_files=""
# Guarded so a CHANGED_FILES-driven run (no temp file created) does not let the
# guard's own false result become the script's exit code under set -e.
cleanup() {
    if [[ -n "${_cii_tmp:-}" ]]; then
        rm -f "$_cii_tmp"
    fi
}
trap cleanup EXIT

if [[ -n "${CHANGED_FILES:-}" ]]; then
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

touches_docs() {
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

# docs_only is true only when at least one file changed AND every changed file
# is documentation. An empty diff is NOT docs_only (nothing to reason about),
# matching build-push.yml's original handling exactly.
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

# IMAGE_IMPACT is the additive verdict (nothing in build-push.yml's original
# detect-changes emitted it). A path is image-affecting unless it is purely
# workflow/docs/test plumbing that never lands in a published image digest nor
# in what an operator runs. The NON-impacting set is intentionally narrow --
# only `*.md`, `docs/**`, `.github/**`, and `tests/**` -- so that deploy/**,
# config/**, setup.sh, and scripts/** (which change operator-run behavior even
# when no service image digest moves) still count as impact for changelog/patch
# traceability, exactly as #819 Point 1 specifies. An empty diff is not impact.
image_impact=false
while IFS= read -r path; do
    case "$path" in
        *.md | docs/* | .github/* | tests/*)
            ;;
        *)
            image_impact=true
            ;;
    esac
done < "$changed_files"

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

if touches_exact ".github/workflows/build-push.yml" \
    || touches_exact ".github/workflows/build-tools.yml" \
    || touches_prefix ".github/actions/"; then
    printf 'workflow=true\n'
else
    printf 'workflow=false\n'
fi

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
