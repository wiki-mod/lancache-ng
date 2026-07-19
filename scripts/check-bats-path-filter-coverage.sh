#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# CI guard for issue #879: keeps .github/workflows/build-tools.yml's
# `on.push.paths` / `on.pull_request.paths` filter in sync with the real,
# non-fixture file dependencies of tests/bats/*.bats and
# tests/bats/helpers/*.sh. build-tools.yml is the ONLY workflow that ever
# executes `bats tests/bats` (confirmed: it is the sole place `bats
# tests/bats` appears in .github/workflows/*.yml); if a bats suite depends on
# a file that is not covered by at least one of that workflow's path-filter
# entries, a PR that changes only that file never runs the suite written for
# it -- the regression net exists on paper but is blind to the exact change
# most likely to need it.
#
# #873/#880 already fixed the concrete filter gaps known at the time via a
# one-off manual trace, but explicitly did NOT build a guard preventing the
# same drift from recurring (see #880's PR body: "Deliberately not built in
# this PR: a guard that keeps this filter in sync automatically... tracked
# separately as follow-up #879"). This script is that guard.
#
# --- Extraction: how a "real dependency" is identified -----------------
# Every one of this project's tests/bats/*.bats files establishes its own
# repo root the same way: `repo_root="$(cd "$BATS_TEST_DIRNAME/../.." &&
# pwd)"` (confirmed: every .bats file in this repo uses this exact pattern,
# with the same variable name). Every real, on-disk file a bats test or
# helper reads is therefore referenced as a `$repo_root/<path>` (or
# `${repo_root}/<path>`) string somewhere in that file's text -- this is the
# ONE signal this script trusts. The four check_*.bats files that test this
# project's own scripts/check-*.sh guards are a second, narrower case: they
# reference their script-under-test directly as
# `$BATS_TEST_DIRNAME/../../scripts/<name>.sh`, bypassing repo_root entirely
# (there is nothing else in those files worth reading via repo_root), so that
# exact prefix is matched too.
#
# This is deliberately NOT a generic "any path-looking string" grep -- issue
# #879 itself warns that approach over-matches, and #873's own manual trace
# had to hand-filter exactly this noise. Two things a naive grep would wrongly
# treat as real dependencies are excluded BY CONSTRUCTION, not by a denylist:
#   1. Fixture paths written under a temp sandbox during a test (e.g.
#      check_idempotence_test_coverage.bats's seed_passing_fixture(), which
#      creates "$fixture_root/services/dns/entrypoint.sh" -- a path that
#      LOOKS like a real repo path but lives under $BATS_TEST_TMPDIR, never
#      under $repo_root). Since this script only ever matches the literal
#      variable name `repo_root` (never `fixture_root`, `BATS_TEST_TMPDIR`, or
#      any other sandbox-rooted variable), these never enter the candidate
#      set at all.
#   2. Example/negative-test path strings that don't correspond to a real
#      file (e.g. a "no such file" test case). These DO use `$repo_root/...`
#      syntax, so they must be filtered after extraction: any candidate that
#      does not exist on disk under the repo root being checked is dropped
#      silently (it cannot be "a real dependency of the bats suite" if there
#      is nothing there to depend on). A candidate produced by truncated
#      variable interpolation (e.g. a hypothetical
#      "$repo_root/services/$service/entrypoint.sh" -- none exist in this
#      repo today, but the extraction regex below cannot capture a `$`) is
#      caught by the same existence filter: an extraction that stops at a bare
#      trailing "/" either fails the existence check outright or, in the
#      pathological case where that partial prefix happens to be a real
#      directory, is dropped explicitly by the trailing-slash check below,
#      since a bare directory match is never what a `source`/read call
#      actually depends on.
#
# --- Coverage semantics --------------------------------------------------
# A path-filter entry ending in "/**" covers every real dependency whose path
# starts with that prefix (a directory wildcard, e.g. "services/dns/**").
# Any other entry is an exact, literal match only (e.g.
# "scripts/check-action-node-versions.sh" covers only that one file, not a
# sibling script). This mirrors how GitHub Actions' own `paths:` filter
# actually matches (npm-style glob semantics for `**`, exact string
# otherwise), and matches the individually-listed-script convention #880
# established for top-level scripts/*.sh files.
#
# --- Why both push AND pull_request are checked independently ------------
# #880's own PR body warns about exactly this failure mode: "every entry
# added to both -- easy to update one and miss the other." A dependency
# present in on.push.paths but silently missing from on.pull_request.paths
# (or vice versa) is a real, distinct gap -- PRs run under pull_request,
# so a push-only fix would still leave every PR blind to the dependency. This
# script therefore evaluates each list separately and reports which
# specific list is missing which specific path, rather than checking their
# union.
#
# Accepts an optional repo_root argument (defaults to this script's own repo)
# so tests/bats/check_bats_path_filter_coverage.bats can point it at a small
# fixture tree instead of mutating or depending on the real repository.
set -euo pipefail

repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$repo_root"

workflow_file=".github/workflows/build-tools.yml"

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    NC=''
fi

violations=0

fail() {
    printf "%b[BATS PATH FILTER]%b %s\n" "$RED" "$NC" "$1" >&2
    violations=$((violations + 1))
}

if [[ ! -f "$workflow_file" ]]; then
    printf "%b[BATS PATH FILTER]%b expected workflow not found: %s\n" "$RED" "$NC" "$workflow_file" >&2
    exit 1
fi

shopt -s nullglob
bats_files=(tests/bats/*.bats)
helper_files=(tests/bats/helpers/*.sh)
shopt -u nullglob
scan_files=("${bats_files[@]}" "${helper_files[@]}")

if [[ ${#scan_files[@]} -eq 0 ]]; then
    printf "%b[BATS PATH FILTER]%b found no tests/bats/*.bats or tests/bats/helpers/*.sh files -- check the glob in this script or the repo_root argument (%s).\n" "$RED" "$NC" "$repo_root" >&2
    exit 1
fi

# extract_workflow_paths <section>
# Prints one path-filter entry per line (quotes stripped) from
# build-tools.yml's on.<section>.paths list. Anchored to this file's exact,
# fixed indentation (on: at column 0; push:/pull_request: at 2 spaces;
# paths: at 4 spaces; list items at 6 spaces) -- the same
# tightly-coupled-to-current-layout tradeoff check-workflow-service-lists.sh
# makes for build-push.yml's `- service:` matrix, rather than pulling in a
# real YAML parser this project has never depended on (see AGENTS.md's
# Rust/shell-only project-language rule).
extract_workflow_paths() {
    local section="$1"
    awk -v section="$section" '
        $0 ~ ("^  " section ":") { in_section = 1; in_paths = 0; next }
        in_section && /^  [a-zA-Z_]+:/ { in_section = 0; in_paths = 0 }
        in_section && /^    paths:/ { in_paths = 1; next }
        in_paths && /^    [a-zA-Z_]+:/ { in_paths = 0 }
        in_paths && /^      - "/ { print }
    ' "$workflow_file" | sed -E 's/^[[:space:]]*-[[:space:]]*"//; s/"[[:space:]]*$//'
}

mapfile -t push_paths < <(extract_workflow_paths "push")
mapfile -t pr_paths < <(extract_workflow_paths "pull_request")

if [[ ${#push_paths[@]} -eq 0 ]]; then
    fail "could not extract any on.push.paths entries from $workflow_file -- refusing to run a vacuous check (parser bug or the paths list was renamed/refactored)."
fi
if [[ ${#pr_paths[@]} -eq 0 ]]; then
    fail "could not extract any on.pull_request.paths entries from $workflow_file -- refusing to run a vacuous check (parser bug or the paths list was renamed/refactored)."
fi
if [[ $violations -gt 0 ]]; then
    exit 1
fi

# Collect every "$repo_root/<path>" / "${repo_root}/<path>" candidate, plus
# every "$BATS_TEST_DIRNAME/../../<path>" candidate (the check_*.bats
# self-referencing form), across all scan_files. `|| true` on each grep is
# required: grep exits 1 on genuinely zero matches in a given file (e.g. a
# helper file with no BATS_TEST_DIRNAME reference at all), which is expected
# and must not trip `set -e` before the other pattern gets a chance to run.
mapfile -t raw_matches < <(
    { grep -hoE '\$\{?repo_root\}?/[A-Za-z0-9_./-]+' "${scan_files[@]}" || true
      grep -hoE '\$BATS_TEST_DIRNAME/\.\./\.\./[A-Za-z0-9_./-]+' "${scan_files[@]}" || true; }
)

if [[ ${#raw_matches[@]} -eq 0 ]]; then
    printf "%b[BATS PATH FILTER]%b found no \$repo_root/... or \$BATS_TEST_DIRNAME/../../... references in any of %d scanned bats/helper files -- check the extraction pattern in this script.\n" "$RED" "$NC" "${#scan_files[@]}" >&2
    exit 1
fi

mapfile -t candidates < <(
    printf '%s\n' "${raw_matches[@]}" \
        | sed -E 's#^\$\{?repo_root\}?/##; s#^\$BATS_TEST_DIRNAME/\.\./\.\./##' \
        | sort -u
)

deps=()
for candidate in "${candidates[@]}"; do
    # A trailing "/" means extraction stopped at a "$"-interpolated segment
    # (see the header comment on truncated dynamic paths) -- never a concrete
    # file, so it can never be "covered" or "missing" in any meaningful sense.
    [[ "$candidate" == */ ]] && continue
    # Existence filter: distinguishes a real dependency from an
    # example/negative-test path string that never corresponds to an actual
    # repo file (see header comment, exclusion case 2).
    [[ -e "$candidate" ]] || continue
    deps+=("$candidate")
done

if [[ ${#deps[@]} -eq 0 ]]; then
    printf "%b[BATS PATH FILTER]%b every extracted \$repo_root/... candidate was filtered out as nonexistent -- check the extraction pattern in this script (expected at least one real dependency, e.g. setup.sh or scripts/lib/**).\n" "$RED" "$NC" >&2
    exit 1
fi

# is_covered <dependency> <filter-entries...>
# A "/**"-suffixed entry covers every dependency under that directory prefix;
# any other entry must match the dependency exactly.
is_covered() {
    local dep="$1"
    shift
    local entry prefix
    for entry in "$@"; do
        if [[ "$entry" == */\*\* ]]; then
            prefix="${entry%/\*\*}"
            if [[ "$dep" == "$prefix" || "$dep" == "$prefix"/* ]]; then
                return 0
            fi
        elif [[ "$dep" == "$entry" ]]; then
            return 0
        fi
    done
    return 1
}

for dep in "${deps[@]}"; do
    if ! is_covered "$dep" "${push_paths[@]}"; then
        fail "'$dep' is a real bats dependency but is not covered by any on.push.paths entry in $workflow_file."
    fi
    if ! is_covered "$dep" "${pr_paths[@]}"; then
        fail "'$dep' is a real bats dependency but is not covered by any on.pull_request.paths entry in $workflow_file."
    fi
done

if [[ $violations -gt 0 ]]; then
    printf "%b✗ %d bats-dependency path-filter gap(s) found in %s.%b Add the missing path(s) to both on.push.paths and on.pull_request.paths, or a directory-wildcard entry covering them; see issue #879.\n" "$RED" "$violations" "$workflow_file" "$NC" >&2
    exit 1
fi

printf "%b✓ All %d real bats dependencies are covered by both on.push.paths and on.pull_request.paths in %s.%b\n" "$GREEN" "${#deps[@]}" "$workflow_file" "$NC"
exit 0
