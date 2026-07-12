#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Guards the requirement #456's convergence/idempotence audit and its #640
# follow-up both state explicitly: every stateful config-writer entrypoint
# (setup.sh's .env migration, the nginx/dnsmasq/PowerDNS/Kea known-good-
# snapshot adapters, NATS's static nats.conf writer, the watchdog restart/
# status loop) must have at least one repeat-run/idempotence test that
# drives the REAL function twice and asserts the result converges, not just
# a one-shot "it works once" test. That pattern is easy to add for a new
# writer and just as easy to silently skip under time pressure -- this
# script makes "no repeat-run coverage" a CI failure instead of something
# that has to be remembered during review.
#
# This is deliberately a small, self-contained script with its own bats
# coverage (tests/bats/check_idempotence_test_coverage.bats), matching the
# project's existing guard-script convention (see check-naming-consistency.sh
# and check-mutable-refs.sh) rather than ad hoc CI-only shell.
#
# How it works: WRITER_TEST_EVIDENCE below pairs each known config-writer
# source file with the file that must contain its repeat-run test. For a
# `.bats` evidence file, that means at least one `@test "..."` whose name
# contains repeat/idempoten/converge (case-insensitive). For a `.rs`
# evidence file (Rust tests live inline, not in a separate test file), that
# means at least one `#[test]`/`#[tokio::test]`-attributed function whose
# name contains the same marker. Every fixed path is verified to actually
# exist too, so a future rename of either file surfaces as a guard failure
# instead of the check silently checking nothing.
#
# Usage:
#   scripts/check-idempotence-test-coverage.sh [repo_root]
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root="${1:-$(cd "$script_dir/.." && pwd)}"
cd "$repo_root"

# writer_path|evidence_path pairs. Kept as a flat array (not an associative
# array) so a single writer could in principle be checked against more than
# one evidence file later without changing this script's shape.
WRITER_TEST_EVIDENCE=(
    "setup.sh|tests/bats/setup_update_idempotence.bats"
    "services/dns/entrypoint.sh|tests/bats/dns_config_snapshot_idempotence.bats"
    "services/watchdog/watchdog.sh|tests/bats/watchdog_idempotence.bats"
    "services/ui/src/kea_snapshots.rs|services/ui/src/routes/dhcp.rs"
    "services/ui/src/routes/secondaries.rs|services/ui/src/routes/secondaries.rs"
)

# A marker substring is required inside a *test name*, not just anywhere in
# the file -- e.g. a doc comment that happens to mention "idempotent" must
# not satisfy this check on its own, or the guard would pass on a file that
# talks about idempotence without ever testing it twice.
#
# Deliberately implemented with plain bash string operations (parameter
# expansion, `case` globs) rather than any regex engine (grep -P/-z, or
# even a dynamic-alternation `~` match in awk): a `grep -Pzo` version of the
# Rust check below worked against a GNU grep with PCRE support but silently
# failed (falsely reporting no test found, exit 2 misread as "no match") on
# this project's self-hosted CI runners. A follow-up POSIX-awk rewrite using
# `lname ~ marker` with marker as a runtime alternation string still failed
# the same way there, most likely because the runner's `awk` is not a full
# POSIX/gawk implementation either. Bash's own `case` glob matching has no
# such engine-dependent alternation and is guaranteed identical everywhere
# this script's own `#!/usr/bin/env bash` shebang already requires.
failures=0

fail() {
    printf '::error::%s\n' "$1" >&2
    failures=$((failures + 1))
}

# name_has_marker <test-name>
# True if <test-name> (already known to be one @test title or one Rust test
# fn name) contains repeat/idempoten/converge, case-insensitively.
name_has_marker() {
    local name
    name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$name" in
        *repeat*|*idempoten*|*converge*) return 0 ;;
        *) return 1 ;;
    esac
}

# extract_bats_test_titles <file>
# Prints one line per `@test "..."` title in a bats file, using only bash
# parameter expansion (no sed/grep regex dependency) so this cannot drift
# from name_has_marker's own plain-bash matching style.
extract_bats_test_titles() {
    local file="$1" line rest
    while IFS= read -r line; do
        case "$line" in
            *'@test "'*)
                rest="${line#*@test \"}"
                printf '%s\n' "${rest%%\"*}"
                ;;
        esac
    done < "$file"
}

has_bats_repeat_test() {
    local file="$1" title
    while IFS= read -r title; do
        name_has_marker "$title" && return 0
    done < <(extract_bats_test_titles "$file")
    return 1
}

# extract_rust_test_fn_names <file>
# Prints one line per test function name in a Rust file. Rust test
# attributes and the `fn` they annotate can be a line or two apart in this
# codebase's style (an attribute, then occasionally another attribute like
# #[should_panic], then the fn line), so this is a small state machine:
# `pending` latches on any #[test]/#[tokio::test] line and stays set across
# whatever follows (including other attributes) until the next line
# containing `fn NAME(`, whose name is then printed; `pending` clears there
# either way, so an unrelated non-matching test in between two real ones can
# never leak a stale match forward.
extract_rust_test_fn_names() {
    local file="$1" line pending=0 rest name
    while IFS= read -r line; do
        case "$line" in
            *'#[test]'*|*'#[tokio::test]'*)
                pending=1
                continue
                ;;
        esac
        if [ "$pending" -eq 1 ]; then
            case "$line" in
                *'fn '*'('*)
                    rest="${line#*fn }"
                    name="${rest%%(*}"
                    # Trailing generics/whitespace before the parenthesis
                    # (e.g. "fn foo<T>(" or "fn foo (") are not a shape any
                    # test fn in this codebase actually uses, but strip
                    # trailing whitespace defensively so a stray space
                    # before "(" can't produce a name that silently never
                    # matches name_has_marker's glob.
                    name="${name%%[[:space:]]*}"
                    printf '%s\n' "$name"
                    pending=0
                    ;;
            esac
        fi
    done < "$file"
}

has_rust_repeat_test() {
    local file="$1" name
    while IFS= read -r name; do
        name_has_marker "$name" && return 0
    done < <(extract_rust_test_fn_names "$file")
    return 1
}

for pair in "${WRITER_TEST_EVIDENCE[@]}"; do
    writer_path="${pair%%|*}"
    evidence_path="${pair##*|}"

    if [ ! -f "$writer_path" ]; then
        fail "check-idempotence-test-coverage: config-writer '$writer_path' no longer exists; update WRITER_TEST_EVIDENCE in scripts/check-idempotence-test-coverage.sh (or remove the entry if the writer itself was removed)."
        continue
    fi

    if [ ! -f "$evidence_path" ]; then
        fail "check-idempotence-test-coverage: '$writer_path' has no repeat-run/idempotence test -- expected evidence file '$evidence_path' does not exist."
        continue
    fi

    case "$evidence_path" in
        *.bats)
            if ! has_bats_repeat_test "$evidence_path"; then
                fail "check-idempotence-test-coverage: '$writer_path' has no repeat-run/idempotence test -- '$evidence_path' exists but has no @test name containing repeat/idempoten/converge."
            fi
            ;;
        *.rs)
            if ! has_rust_repeat_test "$evidence_path"; then
                fail "check-idempotence-test-coverage: '$writer_path' has no repeat-run/idempotence test -- '$evidence_path' exists but has no #[test]/#[tokio::test] fn whose name contains repeat/idempoten/converge."
            fi
            ;;
        *)
            fail "check-idempotence-test-coverage: unsupported evidence file type for '$evidence_path' (expected .bats or .rs); update scripts/check-idempotence-test-coverage.sh."
            ;;
    esac
done

if [ "$failures" -gt 0 ]; then
    printf '::error::check-idempotence-test-coverage: %d config-writer(s) missing repeat-run/idempotence test coverage (see scripts/check-idempotence-test-coverage.sh).\n' "$failures" >&2
    exit 1
fi

printf 'check-idempotence-test-coverage: OK (%d config-writer(s) all have repeat-run/idempotence test coverage).\n' "${#WRITER_TEST_EVIDENCE[@]}"
