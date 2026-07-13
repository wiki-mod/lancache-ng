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
# source file with the file that must contain its repeat-run test (plus an
# optional third field, see the array's own comment). For a `.bats`
# evidence file, that means at least one ACTIVE `@test "..."` (a commented-
# out `# @test "..."` line does not count) whose name contains repeat/
# idempoten/converge (case-insensitive), and the optional extra_marker
# substring if one is set. For a `.rs` evidence file (Rust tests live
# inline, not in a separate test file), that means at least one active,
# non-`#[ignore]`d, non-commented-out `#[test]`/`#[tokio::test]`-attributed
# function whose name contains the same marker(s). Every fixed path is
# verified to actually exist too, so a future rename of either file surfaces
# as a guard failure instead of the check silently checking nothing.
#
# Usage:
#   scripts/check-idempotence-test-coverage.sh [repo_root]
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root="${1:-$(cd "$script_dir/.." && pwd)}"
cd "$repo_root"

# writer_path|evidence_path[|extra_marker] pairs. Kept as a flat array (not
# an associative array) so a single writer could in principle be checked
# against more than one evidence file later without changing this script's
# shape. The optional third field is a writer-specific substring that a
# matched test name must ALSO contain, on top of the generic repeat/
# idempoten/converge marker -- see the comment on the NATS entry below for
# why most entries leave it blank.
WRITER_TEST_EVIDENCE=(
    "setup.sh|tests/bats/setup_update_idempotence.bats"
    "services/dns/entrypoint.sh|tests/bats/dns_config_snapshot_idempotence.bats"
    "services/watchdog/watchdog.sh|tests/bats/watchdog_idempotence.bats"
    "services/proxy/entrypoint.sh|tests/bats/proxy_known_good_snapshot.bats"
    "services/dhcp-proxy/entrypoint.sh|tests/bats/dhcp_proxy_known_good_snapshot.bats"
    "services/ui/src/kea_snapshots.rs|services/ui/src/routes/dhcp.rs"
    # zone_snapshots.rs (#628) is its own evidence file, like secondaries.rs
    # below -- it's a brand-new file as of #628, so unlike secondaries.rs
    # there is no risk yet of an unrelated pre-existing test elsewhere in it
    # accidentally satisfying the generic repeat/idempoten/converge marker,
    # hence no extra_marker needed.
    "services/dns/nats-subscriber/src/zone_snapshots.rs|services/dns/nats-subscriber/src/zone_snapshots.rs"
    # secondaries.rs is its own evidence file (the NATS writer's tests live
    # inline, not in a separate test file), so an unrelated pre-existing test
    # elsewhere in the same file whose name merely contains "repeat" (e.g.
    # generate_nats_password_is_high_entropy_and_never_repeats, about key
    # generation, not config-writing) would otherwise satisfy the generic
    # marker on its own -- confirmed by review (#732): deleting the real
    # nats_conf_write_converges_... repeat-run test still left the guard
    # reporting OK. The extra_marker "nats_conf" narrows the match to test
    # names that are actually about the nats.conf writer.
    "services/ui/src/routes/secondaries.rs|services/ui/src/routes/secondaries.rs|nats_conf"
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

# name_has_marker <test-name> [extra-marker]
# True if <test-name> (already known to be one @test title or one Rust test
# fn name) contains repeat/idempoten/converge, case-insensitively. When
# [extra-marker] is non-empty, the name must ALSO contain it (also case-
# insensitively) -- see the WRITER_TEST_EVIDENCE comment on the NATS entry
# for why: a self-referential evidence file (writer == evidence) can contain
# unrelated tests whose name happens to match the generic marker alone.
name_has_marker() {
    local name extra
    name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$name" in
        *repeat*|*idempoten*|*converge*) ;;
        *) return 1 ;;
    esac
    extra=$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')
    if [ -n "$extra" ]; then
        case "$name" in
            *"$extra"*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

# strip_leading_whitespace <line>
# Prints <line> with any leading spaces/tabs removed, via the classic bash
# parameter-expansion idiom (no sed/grep dependency, same rationale as the
# rest of this script): "${line%%[^[:space:]]*}" greedily matches the
# longest suffix that starts with a non-space character -- i.e. everything
# from the first non-space character onward -- so subtracting it with "#"
# leaves just the leading whitespace run, which "${line#...}" then strips.
strip_leading_whitespace() {
    local line="$1" leading_ws
    leading_ws="${line%%[^[:space:]]*}"
    printf '%s' "${line#"$leading_ws"}"
}

# extract_bats_test_titles <file>
# Prints one line per *active* `@test "..."` title in a bats file, using
# only bash parameter expansion (no sed/grep regex dependency) so this
# cannot drift from name_has_marker's own plain-bash matching style. Lines
# that are comments once leading whitespace is stripped (`# @test "..."`)
# are skipped -- otherwise a disabled repeat-run test would still satisfy
# the guard even though bats never executes it (#732 review).
extract_bats_test_titles() {
    local file="$1" line stripped rest
    while IFS= read -r line; do
        stripped=$(strip_leading_whitespace "$line")
        case "$stripped" in
            '#'*) continue ;;
        esac
        case "$line" in
            *'@test "'*)
                rest="${line#*@test \"}"
                printf '%s\n' "${rest%%\"*}"
                ;;
        esac
    done < "$file"
}

has_bats_repeat_test() {
    local file="$1" extra_marker="${2:-}" title
    while IFS= read -r title; do
        name_has_marker "$title" "$extra_marker" && return 0
    done < <(extract_bats_test_titles "$file")
    return 1
}

# extract_rust_test_fn_names <file>
# Prints one line per *active, non-ignored* test function name in a Rust
# file. Rust test attributes and the `fn` they annotate can be a line or two
# apart in this codebase's style (an attribute, then occasionally another
# attribute like #[should_panic], then the fn line), so this is a small
# state machine: `pending` latches on any #[test]/#[tokio::test] line and
# stays set across whatever follows (including other attributes) until the
# next line containing `fn NAME(`, whose name is then printed; `pending`
# clears there either way, so an unrelated non-matching test in between two
# real ones can never leak a stale match forward.
#
# Two things deliberately do NOT count as evidence, even though the naive
# substring scan below would otherwise catch their fn name (#732 review):
#   - A line that is a comment once leading whitespace is stripped (e.g.
#     `// #[test]` or `// fn nats_conf_write_converges...`) is skipped
#     entirely -- normal `cargo test` never runs commented-out code, so it
#     must not be able to satisfy this guard either.
#   - A #[test]/#[tokio::test] followed by #[ignore] (with or without a
#     `= "reason"}`, hence the prefix match rather than an exact `#[ignore]`
#     line) is disqualified: `disqualified` latches until the eventual `fn`
#     line, whose name is then consumed (so the state machine still resyncs
#     correctly for the next test) but NOT printed. Normal CI does not run
#     #[ignore]d tests, so a writer must not silently lose its enforced
#     repeat-run proof just because the test was temporarily ignored.
extract_rust_test_fn_names() {
    local file="$1" line stripped pending=0 disqualified=0 rest name
    while IFS= read -r line; do
        stripped=$(strip_leading_whitespace "$line")
        case "$stripped" in
            '//'*) continue ;;
        esac
        case "$line" in
            *'#[test]'*|*'#[tokio::test]'*)
                pending=1
                disqualified=0
                continue
                ;;
        esac
        if [ "$pending" -eq 1 ]; then
            case "$line" in
                *'#[ignore'*)
                    disqualified=1
                    continue
                    ;;
            esac
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
                    if [ "$disqualified" -eq 0 ]; then
                        printf '%s\n' "$name"
                    fi
                    pending=0
                    disqualified=0
                    ;;
            esac
        fi
    done < "$file"
}

has_rust_repeat_test() {
    local file="$1" extra_marker="${2:-}" name
    while IFS= read -r name; do
        name_has_marker "$name" "$extra_marker" && return 0
    done < <(extract_rust_test_fn_names "$file")
    return 1
}

for pair in "${WRITER_TEST_EVIDENCE[@]}"; do
    # Up to three '|'-delimited fields: writer_path|evidence_path[|extra_marker].
    # `IFS='|' read -ra` (not the old two-field %%/## slicing) so a pair
    # without a third field leaves extra_marker unset/empty rather than
    # colliding with evidence_path -- required now that a field can follow
    # evidence_path instead of always being the last one.
    IFS='|' read -ra fields <<< "$pair"
    writer_path="${fields[0]}"
    evidence_path="${fields[1]}"
    extra_marker="${fields[2]:-}"

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
            if ! has_bats_repeat_test "$evidence_path" "$extra_marker"; then
                fail "check-idempotence-test-coverage: '$writer_path' has no repeat-run/idempotence test -- '$evidence_path' exists but has no active @test name containing repeat/idempoten/converge${extra_marker:+ and '$extra_marker'}."
            fi
            ;;
        *.rs)
            if ! has_rust_repeat_test "$evidence_path" "$extra_marker"; then
                fail "check-idempotence-test-coverage: '$writer_path' has no repeat-run/idempotence test -- '$evidence_path' exists but has no active, non-ignored #[test]/#[tokio::test] fn whose name contains repeat/idempoten/converge${extra_marker:+ and '$extra_marker'}."
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
