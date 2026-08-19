#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: three comment-content checks, one per function, in one script.
# Why: the maintainer's monolith-first direction; full evidence for each
#   check's pattern design lives in the PR/commit history (#1385, #1546).
# From: PR #1546
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
target_root="${1:-$repo_root}"
cd "$target_root"

# What: Excludes this script and its bats test from their own scan.
# Why: Both quote the banned phrases verbatim as documentation.
# From: PR #1546
is_self_reference() {
    case "$1" in
        scripts/untracked/check-review-chronology-comments.sh) return 0 ;;
        tests/bats/check_review_chronology_comments.bats) return 0 ;;
        *) return 1 ;;
    esac
}

# What: Files exempt from all three comment-content scans.
# Why: Mirrors check-file-headers.sh's is_excluded() -- docs/config/binary
#   files aren't hand-written code comments this guard targets.
# From: PR #1546
is_excluded() {
    case "$1" in
        *.md) return 0 ;;
        .env | .env.example | */.env | */.env.example) return 0 ;;
        Cargo.lock | */Cargo.lock) return 0 ;;
        .gitkeep | */.gitkeep) return 0 ;;
        VERSION) return 0 ;;
        LICENSE | COPYING) return 0 ;;
        services/dhcp/kea-dhcp4.conf | services/dhcp/kea-ctrl-agent.conf | services/dhcp/kea-dhcp-ddns.conf) return 0 ;;
        vex.openvex.json | */vex.openvex.json) return 0 ;;
        docs/validation-state.json | */docs/validation-state.json) return 0 ;;
        services/ui/src/static/chart.umd.min.js | services/ui/src/static/admin.css) return 0 ;;
        services/proxy/public_suffix_list.dat) return 0 ;;
        */fuzz/corpus/* | fuzz/corpus/*) return 0 ;;
        *.png | *.jpg | *.jpeg | *.gif | *.ico | *.svg | *.woff | *.woff2 | *.ttf | *.eot | *.crt | *.key | *.pem) return 0 ;;
        *) return 1 ;;
    esac
}

# What: Case-insensitive, per-line grep patterns for the checks below.
# Why: Tight adjacency (not a wide free-text window) avoids matching
#   unrelated prose like "review the list" in a 9000-line file; POSIX
#   [[:space:]] matches this repo's existing regex convention.
# From: PR #1546
DISCOVERY_VERBS='(caught|found|flagged|spotted|identified|discovered|noticed)'
# What: "<verb> in/during [a/the/this] [code/pr/peer] [self-]review".
# Why: Only whitespace and a small filler-word set allowed before "review",
#   so an unrelated clause breaks the match instead of being silently
#   absorbed.
# From: PR #1546
REVIEW_CHRONOLOGY_PATTERN="(\\b${DISCOVERY_VERBS}\\b[[:space:]]+(in|during)[[:space:]]+((a|the|this)[[:space:]]+)?(code[[:space:]]+|pr[[:space:]]+|peer[[:space:]]+)?(self-)?review\\b)"
# What: "review ... <verb>" (e.g. "a PR review (#765) found ...").
# Why: Gap restricted to non-letter chars so it can span a short
#   parenthetical without crossing into a new sentence.
# From: PR #1546
REVIEW_CHRONOLOGY_PATTERN+="|(\\breview\\b[^a-zA-Z.]{0,20}\\b${DISCOVERY_VERBS}\\b)"
# What: "before/prior to/until this fix/change/commit/patch" self-reference.
# Why: catches the deictic half of review-chronology narration.
# From: PR #1546
REVIEW_CHRONOLOGY_PATTERN+="|(\\b(before|prior to|until)[[:space:]]+this[[:space:]]+(fix|change|commit|patch)\\b)"
# The noun form "review finding" -- no adjacent discovery verb required,
# since "finding" itself already carries the chronology claim.
REVIEW_CHRONOLOGY_PATTERN+="|(\\breview[[:space:]]+finding\\b)"

# What: Matches "(line N)"/"(see line ~N)", case-insensitive.
# Why: this shape goes stale the moment the target line moves.
# From: PR #1546
FRAGILE_LINE_REF_PATTERN='\(([Ss]ee[[:space:]]+)?\bline\b[[:space:]]*~?[0-9]+'

# What: Checks each line of $1 against $REVIEW_CHRONOLOGY_PATTERN, then a
#   second pass joining each adjacent pair of hand-written comment lines.
# Why: -H forces the filename prefix; the second pass catches a chronology
#   phrase line-wrapped across two comment lines that neither line alone
#   contains (real gap found in this repo's own history).
# From: PR #1385, PR #1546
check_review_chronology() {
    grep -EinIH "$REVIEW_CHRONOLOGY_PATTERN" "$1" || true
    while IFS=$'\t' read -r line_no joined; do
        [ -n "$line_no" ] || continue
        if grep -Eiq "$REVIEW_CHRONOLOGY_PATTERN" <<<"$joined"; then
            printf '%s:%s: %s\n' "$1" "$line_no" "$joined"
        fi
    done < <(awk '
        function is_comment(line) {
            return line ~ /^[[:space:]]*(#|\/\/|--|\/\*|\*|<!--|\{#)/
        }
        function payload(line,    p) {
            p = line
            sub(/^[[:space:]]*(#|\/\/|--|\/\*|\*|<!--|\{#)[[:space:]]*/, "", p)
            return p
        }
        {
            cur_is_comment = is_comment($0)
            cur = cur_is_comment ? payload($0) : ""
            if (prev_is_comment && cur_is_comment) {
                printf "%d\t%s %s\n", NR - 1, prev, cur
            }
            prev_is_comment = cur_is_comment
            prev = cur
        }
    ' "$1")
}

# What: Checks each line of $1 against $FRAGILE_LINE_REF_PATTERN.
# Why: -H forces the filename prefix even for a single-file invocation.
# From: PR #1546
check_fragile_line_references() {
    grep -EinIH "$FRAGILE_LINE_REF_PATTERN" "$1" || true
}

# What: Flags a #N repeated outside this file's own From: pointer line(s).
# Why: AG-CODE-012 requires From: to be the sole place a comment names a
#   PR/Issue number; scoped per-file/already-declared-number to avoid a
#   large false-positive flood from legitimate historical references.
# From: PR #1546
check_bare_issue_ref_duplicates_from() {
    local path="$1" from_nums num
    # What: Skips files with no From: pointer (the common case).
    # Why: -I avoids treating a binary file as a text match.
    # From: PR #1546
    grep -qEI 'From:' "$path" 2>/dev/null || return 0
    from_nums=$(grep -EI 'From:' "$path" 2>/dev/null | grep -oEI '#[0-9]+' | tr -d '#' | sort -u || true)
    [ -z "$from_nums" ] && return 0

    while IFS= read -r num; do
        [ -n "$num" ] || continue
        # What: scans every #N on a line, skipping matches inside a string.
        # Why: a #N inside a string (e.g. an echo message) is not a
        #   governed comment; a `'` opens a string only when not preceded
        #   by a word char, so contractions like "it's" aren't misread.
        # From: PR #1546
        awk -v n="$num" '
            $0 ~ /From:/ { next }
            {
                line = $0
                in_q = ""
                matched = 0
                len = length(line)
                for (i = 1; i <= len; i++) {
                    c = substr(line, i, 1)
                    if (in_q == "") {
                        if (c == "\"") { in_q = c; continue }
                        if (c == "\x27") {
                            prevc = (i > 1) ? substr(line, i - 1, 1) : ""
                            if (prevc !~ /[A-Za-z0-9_]/) { in_q = c; continue }
                        }
                    } else if (c == in_q) {
                        in_q = ""; continue
                    }
                    if (in_q == "" && c == "#") {
                        rest = substr(line, i + 1, length(n))
                        if (rest == n) {
                            after = substr(line, i + 1 + length(n), 1)
                            before = (i > 1) ? substr(line, i - 1, 1) : ""
                            if (after !~ /[0-9]/ && before !~ /[0-9]/) { matched = 1 }
                        }
                    }
                }
                if (matched) print FILENAME ":" FNR ":" line
            }
        ' "$path"
    done <<< "$from_nums"
}

# What: Checks for ".git" directly under target_root, not an ancestor dir.
# Why: A bats fixture nested inside this repo's own working copy must stay
#   a plain fixture, not fall through to git ls-files on the outer repo.
# From: PR #1546
if [ -e "$target_root/.git" ]; then
    mapfile -t files < <(git ls-files)
else
    mapfile -t files < <(find . -type f -print | sed 's#^\./##')
fi

chronology_violations=()
fragile_ref_violations=()
duplicate_ref_violations=()
for path in "${files[@]}"; do
    [ -f "$path" ] || continue
    is_self_reference "$path" && continue
    is_excluded "$path" && continue

    # What: -I skips binary files during the match loop.
    # Why: without it, grep's own "Binary file ... matches" line would be
    #   wrongly recorded as a violation.
    # From: PR #1546
    while IFS= read -r match; do
        [ -n "$match" ] || continue
        chronology_violations+=("$match")
    done < <(check_review_chronology "$path")

    while IFS= read -r match; do
        [ -n "$match" ] || continue
        fragile_ref_violations+=("$match")
    done < <(check_fragile_line_references "$path")

    while IFS= read -r match; do
        [ -n "$match" ] || continue
        duplicate_ref_violations+=("$match")
    done < <(check_bare_issue_ref_duplicates_from "$path")
done

violations_found=0

if [ "${#chronology_violations[@]}" -gt 0 ]; then
    violations_found=1
    echo "Review-chronology comment(s) found (AG-CODE-003 violation):" >&2
    printf '  %s\n' "${chronology_violations[@]}" >&2
    echo "" >&2
    echo "These narrate the review/fix history of the change they sit in (e.g. \"caught in" >&2
    echo "review\", \"before this fix\") instead of documenting durable technical rationale --" >&2
    echo "that context belongs in the PR/commit description, not in code that outlives the" >&2
    echo "change (AGENTS.md AG-CODE-003). Reword to describe the technical behavior/WHY" >&2
    echo "directly, without the self-referential review/PR-chronology framing." >&2
    echo "" >&2
fi

if [ "${#fragile_ref_violations[@]}" -gt 0 ]; then
    violations_found=1
    echo "Fragile line-number self-reference(s) found (AG-CODE-002 violation):" >&2
    printf '  %s\n' "${fragile_ref_violations[@]}" >&2
    echo "" >&2
    echo "\"(line ~N)\"/\"(see line N)\" references go stale the moment the target file is" >&2
    echo "edited, with nothing to catch the drift. Reference the function/variable/step name" >&2
    echo "instead -- it keeps pointing at the right place across refactors." >&2
    echo "" >&2
fi

if [ "${#duplicate_ref_violations[@]}" -gt 0 ]; then
    violations_found=1
    echo "Issue/PR reference duplicated outside its own From: pointer (AG-CODE-012 violation):" >&2
    printf '  %s\n' "${duplicate_ref_violations[@]}" >&2
    echo "" >&2
    echo "This file already declares this number via a structured \`From: Issue #N\`/\`From:" >&2
    echo "PR #N\` pointer; AG-CODE-012 requires that pointer to be the sole place a comment" >&2
    echo "names the number -- \"never a retelling of that context.\" Remove the duplicate inline" >&2
    echo "mention (the From: pointer already carries it)." >&2
    echo "" >&2
fi

if [ "$violations_found" -eq 1 ]; then
    exit 1
fi

echo "No review-chronology comments, fragile line-number self-references, or From:-duplicate issue references found -- AG-CODE-002/003/012 (comment-content sub-patterns) hold."
