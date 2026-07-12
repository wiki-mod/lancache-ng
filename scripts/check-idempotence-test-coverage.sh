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
MARKER_REGEX='(repeat|idempoten|converge)'

failures=0

fail() {
    printf '::error::%s\n' "$1" >&2
    failures=$((failures + 1))
}

has_bats_repeat_test() {
    local file="$1"
    grep -Eiq "@test \"[^\"]*${MARKER_REGEX}[^\"]*\"" "$file"
}

has_rust_repeat_test() {
    local file="$1"
    # Rust test attributes and the `fn` they annotate can be several lines
    # apart in this codebase's style (attribute, then a doc-comment-free
    # blank line is rare but not guaranteed), so this matches on the
    # attribute and function name independently: any #[test]/#[tokio::test]
    # line followed (not necessarily immediately) by a fn whose name carries
    # the marker. -P (PCRE) with -z (NUL-separated) lets `.` cross newlines
    # so a test's attribute and its fn signature can be matched as one unit
    # even when a line of `#[should_panic]` or similar sits between them.
    grep -Pzoq "(?s)#\[(test|tokio::test)\][^\n]*(\n[^\n]*)*?\n\s*(async )?fn [a-z0-9_]*${MARKER_REGEX}[a-z0-9_]*\s*\(" "$file"
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
