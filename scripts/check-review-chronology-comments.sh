#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Three related, mechanically-detectable AG-CODE-002/003/012 comment-content
# checks, kept in one file per the maintainer's explicit "more monolith, more
# functions per script" direction rather than one narrow script per pattern
# (2026-08-13 comment-guard generalization). Each check is its own function
# below; this header documents what each one matches, why, and -- just as
# important -- what related pattern was investigated and deliberately NOT
# automated, and why (AG-VAL-028 explicitly allows declining to add a check
# as long as the reason is recorded).
#
# ============================================================================
# Check 1: check_review_chronology() -- REVIEW-CHRONOLOGY COMMENTS
# ============================================================================
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
# this repository's own tracked files (2026-08-02) found eighteen genuine
# instances of exactly this review-chronology sub-pattern still present
# across fourteen files (.github/actions/rust-acceleration-preflight/
# action.yml, .github/workflows/build-push.yml x3, .github/workflows/
# gc-pr-staging-images.yml x2, scripts/dns-zone-rollback-simulation.sh,
# services/dns/nats-subscriber/src/main.rs, services/ui/src/main.rs,
# services/ui/src/routes/dhcp.rs, services/ui/src/routes/domains.rs,
# services/ui/src/syslog_client.rs, and five tests/bats/*.bats files
# [proxy_cert_generation.bats, retention_fluent_bit_selflog.bats,
# setup_nats_secondary_override.bats x2, setup_secondary_docker_compose.bats,
# watchdog_config_validation.bats] that an earlier, narrower manual grep pass
# -- scoped only to *.rs/*.sh/*.yml/*.yaml/*.conf/*.template -- had missed
# entirely) -- fixed alongside adding this guard so it starts clean.
# Stable historical references to a specific past issue/PR number cited as
# durable WHY-grounding for a technical claim (e.g. "confirmed live while
# building issue #400's integration test") are NOT what this script targets
# and must keep passing; only three prior closed issues (#673, #719, #722)
# established this exact review-chronology sub-pattern as a recurring, real
# violation class worth a standing mechanical guard rather than relying on
# manual review to catch it again each time (AG-VAL-028).
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
# ============================================================================
# Check 2: check_fragile_line_references() -- "(line ~N)" SELF-REFERENCES
# ============================================================================
# Flags a comment that points at another part of the same or a different
# file by raw line number -- "(line ~890)", "(see line ~1114)", "(line 15)".
# These go stale the moment either file is edited (a line inserted above the
# target silently makes the citation point at the wrong code, with nothing
# to catch the drift), unlike a reference by function/variable/step name,
# which keeps pointing at the right place across refactors as long as the
# name itself doesn't change. A real, 2026-08-13 repo-wide audit found five
# genuine instances, all now fixed alongside adding this check: setup.sh
# (x2, one already redundant with an adjacent function-name reference and
# simply dropped, one rewritten to name the docker-compose.yml port-mapping
# fallback it points at instead of a cross-file line number), tests/bats/
# setup_update_health_baseline.bats and setup_update_idempotence.bats (both
# citing "setup.sh's own top-level `set -euo pipefail` (line N)" -- the line
# number added nothing the surrounding sentence didn't already say, so it
# was dropped outright), and tests/setup-migration-semantics.sh (rewritten
# to name env_key_exists()/write_env_file() instead of their line numbers).
# The last of those five also surfaced a related, out-of-scope finding left
# for the maintainer rather than silently fixed here: the function this
# comment sits in, setup_sh_helpers(), is never called anywhere in this
# repository, and its own `sed -n '446,628p'` extraction range is *already*
# stale relative to those two functions' real current line numbers -- a
# dead-code/test-infrastructure defect, not a comment-content one, and
# outside this check's mandate to fix without a separate, verifiable pass.
#
# Pattern: an opening parenthesis, an optional "see ", the word "line", an
# optional "~", then a run of digits -- e.g. "(line 42)", "(see line ~200)".
# Requiring the literal "(line"/"(see line" sequence (not just \bline\b
# anywhere near a number) keeps this from matching unrelated prose that
# merely contains the word "line" near an unrelated number elsewhere in the
# same sentence (e.g. "port 8080" two words after "the command line" would
# not match, since no digits directly follow "line" itself).
#
# ============================================================================
# Check 3: check_bare_issue_ref_duplicates_from() -- REDUNDANT #NNN OUTSIDE From:
# ============================================================================
# AG-CODE-012 requires a comment naming a PR/Issue number to do so through
# exactly one bare `From: Issue #N` / `From: PR #N` / `From: #N` pointer --
# "never a retelling of that context" elsewhere in the same comment/file. A
# real ground-truth example (PR #1534, commit 787f04f7) shows the actual
# violation shape: `services/dns/Dockerfile` already carried a correct
# `From: Issue #887` pointer, and *also* repeated "(issue #887)" inline in
# three other places (an action `description:` field, a workflow step
# `name:`, and two more workflow comments) -- all three were fixed by
# deleting the redundant inline mention, not by rewording it, since the
# `From:` pointer already carries that exact context.
#
# This check reproduces that specific, narrow shape: for each file, collect
# every `#N` cited on a line containing "From:" (the pointer's own target
# numbers), then flag any *other* line in that same file that cites one of
# those same numbers outside a `From:` line -- a same-file duplicate of the
# file's own already-declared task/issue/PR reference. It deliberately does
# NOT flag a bare `#N` that cites a DIFFERENT number than any `From:` line in
# that file: a real, repo-wide sweep (2026-08-13) of every bare `#[0-9]+`
# reference outside a `From:` line, with no such same-file-duplicate
# narrowing, returned roughly 2,955 hits across this repository's tracked
# files -- overwhelmingly legitimate, accepted historical WHY-grounding
# prose this project already relies on constantly (e.g. "issue #1377's own
# repo-wide SIGPIPE audit", "the pre-#808 test", "(#623/#703/#820/#932)"
# citing four unrelated closed issues as prior-art evidence for one design
# decision). That number is itself the confirmation of AG-VAL-028's own
# already-recorded assessment of this broader pattern ("case (a)... remains
# exactly as hard to check cheaply as this note originally said"): a blanket
# "no bare #N outside From:" check is not viable at this repository's actual
# writing density, so this check is scoped to the one sub-shape that both has
# real ground-truth evidence and cannot produce that false-positive flood --
# a number a file has ALREADY placed in its own `From:` pointer, repeated a
# second time outside it. Two further sub-shapes were investigated and
# deliberately NOT automated, per AG-VAL-028's explicit allowance to decline
# as long as the reason is recorded:
#   - `#N` inside a GitHub Actions step `name:` field: a repo-wide sweep
#     found 13 existing, long-standing instances across .github/workflows/
#     build-push.yml and .github/actions/shellcheck-and-standing-guards/
#     action.yml (e.g. "Check pinned GitHub Actions for deprecated Node
#     runtimes (#801)") -- an established, deliberate labeling convention
#     for standing CI guards that has survived many prior review passes, not
#     an accidental leak. Flagging it would mean rewriting 13 pre-existing,
#     accepted step names as a side effect of a comment-content guard, which
#     needs the maintainer's explicit sign-off, not a mechanical check
#     silently declaring 13 years of convention non-compliant.
#   - `#N` inside an action `description:` input field: only 2 genuine hits
#     exist repo-wide (.github/actions/trivy-scan-with-cache/action.yml's
#     registry-username/registry-password inputs, both "...issue #1535"),
#     plus 2 build-matrix `description:` entries in build-push.yml (a
#     different kind of field -- matrix data, not a UI-facing input
#     description) citing "issue #1428". Small enough to be plausible for a
#     future check, but with the step-`name:` convention shown above to be
#     accepted, a `description:`-only check risks being an arbitrary,
#     inconsistent carve-out rather than a principled one; left as an open
#     item for the maintainer rather than encoded here.
# This check also does not attempt to catch PR #1534's own step-`name:`
# instance retroactively: that step's "(issue #887/#1535)" lived in
# build-push.yml while the `From: Issue #887` pointers it duplicated live in
# a different file (services/dns/Dockerfile) -- this check is deliberately
# scoped per-file, not cross-file, since cross-file number matching would
# immediately re-flag the 13 accepted step names above (many of which cite
# numbers that also happen to appear in some `From:` line somewhere else in
# this large a repository, coincidentally, with no redundancy relationship
# between them at all).
#
# ============================================================================
# Shared scanning behavior (all three checks)
# ============================================================================
# Detection is deliberately per-line, not a full-file/multiline scan: every
# real instance found in this repository's own audits had the offending
# phrase entirely on one line, and a per-line grep keeps the false-positive
# surface small and the match easy to point at with a file:line reference.
# The known, accepted tradeoff is that a phrase awkwardly split across a
# line wrap would not be caught -- the same simplicity tradeoff this
# project's other line-oriented guards (e.g. check-file-headers.sh,
# check-workflow-line-limit.sh) already make.
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
# independently. See "Check 1" above for what each alternative targets and
# why, and for the deliberately-excluded near-miss phrasings. Deliberately
# tight adjacency, not a wide free-text window: an earlier draft of this
# pattern used a generic "up to 40 characters of anything" gap between the
# discovery verb and "review", which would also match a sentence like
# "every service found in the matrix; review the list when adding one" -- a
# real risk against ~9000-line comment-heavy files like build-push.yml.
# [[:space:]] (POSIX, not the GNU-only \s) is used for whitespace, matching
# the convention scripts/check-governance-guards.sh already established for
# this kind of word-boundary regex in this repo.
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

# See "Check 2" above. Case-insensitive so "(Line 42)" matches too.
FRAGILE_LINE_REF_PATTERN='\(([Ss]ee[[:space:]]+)?\bline\b[[:space:]]*~?[0-9]+'

# Checks each line of $1 against $REVIEW_CHRONOLOGY_PATTERN, prefixed with
# filename:line like every other check here (-H forces the filename prefix
# even for a single-file invocation, which grep otherwise suppresses).
check_review_chronology() {
    grep -EinIH "$REVIEW_CHRONOLOGY_PATTERN" "$1" || true
}

# Checks each line of $1 against $FRAGILE_LINE_REF_PATTERN. See "Check 2"
# above for the pattern's exact shape and why it stays this narrow.
check_fragile_line_references() {
    grep -EinIH "$FRAGILE_LINE_REF_PATTERN" "$1" || true
}

# See "Check 3" above. Collects the numbers this file already declared via
# its own `From:` pointer line(s), then flags any OTHER line repeating one
# of those same numbers -- a same-file duplicate of an already-declared
# task/issue/PR reference, per AG-CODE-012's "never a retelling" rule.
check_bare_issue_ref_duplicates_from() {
    local path="$1" from_nums num
    # Cheap single-process short-circuit for the common case (this repo's own
    # sweep: the overwhelming majority of tracked files carry no `From:`
    # pointer at all yet, since AG-CODE-012 adoption is still in progress) --
    # skips the 4-process extraction pipeline below entirely for those files.
    # -I (not -a): consistent with every other grep in this script, a binary
    # file is never treated as a text match.
    grep -qEI 'From:' "$path" 2>/dev/null || return 0
    from_nums=$(grep -EI 'From:' "$path" 2>/dev/null | grep -oEI '#[0-9]+' | tr -d '#' | sort -u || true)
    [ -z "$from_nums" ] && return 0

    while IFS= read -r num; do
        [ -n "$num" ] || continue
        # Word-boundary-equivalent match on the number itself: "(^|[^0-9])"
        # before and "([^0-9]|$)" after keep "#887" from also matching inside
        # a longer number like "#8871" that merely happens to start with the
        # same digits. Lines containing "From:" are excluded here (that is
        # the one place this number is SUPPOSED to live); every other line
        # citing the same number is the redundant duplicate this check
        # exists to catch.
        grep -EnI "(^|[^0-9])#${num}([^0-9]|$)" "$path" 2>/dev/null | grep -vE 'From:' || true
    done <<< "$from_nums"
}

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

chronology_violations=()
fragile_ref_violations=()
duplicate_ref_violations=()
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
    echo "directly, without the self-referential review/PR-chronology framing; see this" >&2
    echo "script's own header comment (Check 1) for worked examples of how prior real" >&2
    echo "instances in this repo were reworded." >&2
    echo "" >&2
fi

if [ "${#fragile_ref_violations[@]}" -gt 0 ]; then
    violations_found=1
    echo "Fragile line-number self-reference(s) found (AG-CODE-002 violation):" >&2
    printf '  %s\n' "${fragile_ref_violations[@]}" >&2
    echo "" >&2
    echo "\"(line ~N)\"/\"(see line N)\" references go stale the moment the target file is" >&2
    echo "edited, with nothing to catch the drift. Reference the function/variable/step name" >&2
    echo "instead -- it keeps pointing at the right place across refactors; see this script's" >&2
    echo "own header comment (Check 2) for worked examples." >&2
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
    echo "mention (the From: pointer already carries it); see this script's own header comment" >&2
    echo "(Check 3) for the real precedent this reproduces." >&2
    echo "" >&2
fi

if [ "$violations_found" -eq 1 ]; then
    exit 1
fi

echo "No review-chronology comments, fragile line-number self-references, or From:-duplicate issue references found -- AG-CODE-002/003/012 (comment-content sub-patterns) hold."
