#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Enforces AG-CODE-003 ("Do not reference the current task, PR number, or fix
# in a comment... that belongs in the PR/commit description, not in code
# that outlives the change") for one specific, mechanically-detectable
# sub-pattern: a comment that narrates the REVIEW CHRONOLOGY of the very
# change it sits in -- "caught in review", "found during self-review",
# "flagged in review on PR #743", "before this fix", "regression pin for a
# bug caught in review", and similar phrasings. These read as internal notes
# to the reviewer/author at the moment the PR was open, not durable
# technical rationale: a reader six months later has no way to know which
# review pass, or which "this fix", the comment means, and the phrase adds
# nothing the surrounding technical explanation doesn't already say on its
# own once the self-reference is removed.
#
# This is deliberately narrower than AG-CODE-003's full text (which also
# covers bare "fixed for #123"/task-ID references): a real audit against
# this repository's own tracked files (2026-08-02) found ten genuine
# instances of exactly this review-chronology sub-pattern still present
# across nine files (.github/actions/rust-acceleration-preflight/action.yml,
# .github/workflows/build-push.yml x3, .github/workflows/gc-pr-staging-
# images.yml x2, scripts/dns-zone-rollback-simulation.sh, services/dns/
# nats-subscriber/src/main.rs, services/ui/src/main.rs, services/ui/src/
# routes/dhcp.rs, services/ui/src/routes/domains.rs, services/ui/src/
# syslog_client.rs) -- fixed alongside adding this guard so it starts clean.
# Stable historical references to a specific past issue/PR number cited as
# durable WHY-grounding for a technical claim (e.g. "confirmed live while
# building issue #400's integration test") are NOT what this script targets
# and must keep passing; only three prior closed issues (#673, #719, #722)
# established this exact review-chronology sub-pattern as a recurring, real
# violation class worth a standing mechanical guard rather than relying on
# manual review to catch it again each time (AG-VAL-028).
#
# Detection is deliberately per-line, not a full-file/multiline scan: every
# real instance found in this repository's own audit had the offending
# phrase entirely on one line, and a per-line grep keeps the false-positive
# surface small and the match easy to point at with a file:line reference.
# The known, accepted tradeoff is that a phrase awkwardly split across a
# line wrap would not be caught -- the same simplicity tradeoff this
# project's other line-oriented guards (e.g. check-file-headers.sh,
# check-workflow-line-limit.sh) already make.
#
# Patterns matched (case-insensitive):
#   1. A discovery verb (caught/found/flagged/spotted/identified/discovered)
#      near "review" in EITHER order ("caught in review", "flagged in review
#      on PR #743", "a PR review found", "was caught during self-review").
#      "self-review" matches too: the hyphen is a non-word character, so
#      \breview\b still matches the "review" half of that compound word.
#   2. "before/prior to/until this fix/change/commit/patch" -- the deictic
#      "this <noun>" self-reference to whichever change introduced the
#      comment, independent of the review-discovery verbs in pattern 1.
#
# Deliberately NOT flagged, by construction, so as not to over-match a
# legitimate, permanently-valid comment that merely mentions code review as
# a general concept:
#   - "manual review", "code review" mentioned on their own with no adjacent
#     discovery verb (e.g. "...so that specific class of regression is
#     caught here mechanically instead of relying on manual review to
#     notice it" -- "review" and "notice" are far enough apart, and "notice"
#     is not one of the tracked discovery verbs, so this does not match).
#   - "remembered during review" (scripts/check-idempotence-test-
#     coverage.sh) -- "remembered" is deliberately not in the discovery-verb
#     list; it describes a general process improvement, not a chronology
#     claim about THIS comment's own discovery.
#   - "regression pin" alone (scripts/lib/shared-secret-bootstrap.sh and its
#     three sibling entrypoints) -- a legitimate, durable engineering term
#     for "this test exists to pin a regression," not review chronology,
#     unless it is actually paired with a discovery verb next to "review"
#     (pattern 1 above still catches that combined case, e.g. "regression
#     pin for a bug caught in review").
#   - "after this PR merges" / "until this PR's OWN builds" (scripts/check-
#     build-tools-smoke-coverage.sh, scripts/ensure-pr-staging-images.sh,
#     full-setup-deep-validate.yml) -- these describe live CI/workflow
#     semantics about whatever PR is CURRENTLY running through the
#     pipeline (a dynamic runtime referent, re-evaluated fresh on every
#     run), not a historical reference to the PR that introduced the
#     comment. Pattern 2 only matches "fix/change/commit/patch" nouns,
#     deliberately excluding "PR", so these stay unmatched.
#
# Accepts an optional repo_root argument (defaults to this script's own
# repo) so tests/bats/check_review_chronology_comments.bats can point it at
# a small fixture tree instead of mutating or depending on the real
# repository.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
target_root="${1:-$repo_root}"
cd "$target_root"

# This script's own file, and its dedicated bats test, legitimately quote
# the banned phrases verbatim as documentation of what they detect (the
# header comment above, and the test's positive-fixture cases) -- excluded
# from the scan by construction so the guard does not fail on its own
# documentation.
is_self_reference() {
    case "$1" in
        scripts/check-review-chronology-comments.sh) return 0 ;;
        tests/bats/check_review_chronology_comments.bats) return 0 ;;
        *) return 1 ;;
    esac
}

# Mirrors check-file-headers.sh's is_excluded() exactly: both checks care
# about the same set of files ("files that carry our own hand-written
# comments"), so a file exempt from the header requirement (documentation
# prose, JSON-only config, vendored/generated/binary content) is exempt
# here too. Documentation files (*.md) matter most here: this project's own
# governance docs and closed-issue write-ups permanently and legitimately
# narrate past review history in prose (e.g. this very script's header
# above) -- AG-CODE-003 targets code comments that "outlive the change,"
# not the durable historical record governance docs are explicitly meant
# to be (AG-WF-026).
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

# Extended regex, matched case-insensitively (grep -Ei) against each line
# independently. See the header comment above for what each alternative
# targets and why, and for the deliberately-excluded near-miss phrasings.
# Deliberately tight adjacency, not a wide free-text window: an earlier
# draft of this pattern used a generic "up to 40 characters of anything"
# gap between the discovery verb and "review", which would also match a
# sentence like "every service found in the matrix; review the list when
# adding one" -- a real risk against ~9000-line comment-heavy files like
# build-push.yml. [[:space:]] (POSIX, not the GNU-only \s) is used for
# whitespace, matching the convention scripts/check-governance-guards.sh
# already established for this kind of word-boundary regex in this repo.
DISCOVERY_VERBS='(caught|found|flagged|spotted|identified|discovered|noticed)'
# "<verb> in/during [a/the/this] [code/pr/peer] [self-]review" -- the verb
# must be immediately followed by in/during (only whitespace between), and
# only a small, explicit set of filler words is allowed before "review"
# itself, so a real intervening clause (a different noun, a semicolon, a new
# sentence) breaks the match instead of silently being absorbed by a wide
# window.
REVIEW_CHRONOLOGY_PATTERN="(\\b${DISCOVERY_VERBS}\\b[[:space:]]+(in|during)[[:space:]]+((a|the|this)[[:space:]]+)?(code[[:space:]]+|pr[[:space:]]+|peer[[:space:]]+)?(self-)?review\\b)"
# "review ... <verb>" (e.g. "a PR review (#765) found ..."): the gap between
# "review" and the verb is restricted to non-letter, non-period characters
# (digits, spaces, parens, #, hyphens) so it can span a short parenthetical
# issue-number citation without crossing into a new word or a new sentence.
REVIEW_CHRONOLOGY_PATTERN+="|(\\breview\\b[^a-zA-Z.]{0,20}\\b${DISCOVERY_VERBS}\\b)"
# "before/prior to/until this fix/change/commit/patch" -- the deictic
# self-reference to whichever change introduced the comment.
REVIEW_CHRONOLOGY_PATTERN+="|(\\b(before|prior to|until)[[:space:]]+this[[:space:]]+(fix|change|commit|patch)\\b)"

# Checks for ".git" directly under target_root itself, not "somewhere in an
# enclosing directory" (which `git rev-parse --is-inside-work-tree` would
# also report true for): a bats fixture tree created under a temp directory
# that happens to be nested inside this very repository's own working copy
# must still be treated as a plain, non-git fixture, not accidentally fall
# through to `git ls-files` on the OUTER real repository.
if [ -e "$target_root/.git" ]; then
    mapfile -t files < <(git ls-files)
else
    mapfile -t files < <(find . -type f -print | sed 's#^\./##')
fi

violations=()
for path in "${files[@]}"; do
    [ -f "$path" ] || continue
    is_self_reference "$path" && continue
    is_excluded "$path" && continue

    # -I: never treat a binary file (e.g. an accidentally-unlisted image or
    # font) as a text match -- without it, grep would print a bogus
    # "Binary file ... matches" line that this loop would then wrongly
    # record as a real violation.
    while IFS= read -r match; do
        [ -n "$match" ] || continue
        violations+=("$match")
    done < <(grep -EinIH "$REVIEW_CHRONOLOGY_PATTERN" "$path" || true)
done

if [ "${#violations[@]}" -gt 0 ]; then
    echo "Review-chronology comment(s) found (AG-CODE-003 violation):" >&2
    printf '  %s\n' "${violations[@]}" >&2
    echo "" >&2
    echo "These narrate the review/fix history of the change they sit in (e.g. \"caught in" >&2
    echo "review\", \"before this fix\") instead of documenting durable technical rationale --" >&2
    echo "that context belongs in the PR/commit description, not in code that outlives the" >&2
    echo "change (AGENTS.md AG-CODE-003). Reword to describe the technical behavior/WHY" >&2
    echo "directly, without the self-referential review/PR-chronology framing; see" >&2
    echo "scripts/check-review-chronology-comments.sh's own header comment for worked" >&2
    echo "examples of how prior real instances in this repo were reworded." >&2
    exit 1
fi

echo "No review-chronology comments found -- AG-CODE-003 (review-chronology sub-pattern) holds."
