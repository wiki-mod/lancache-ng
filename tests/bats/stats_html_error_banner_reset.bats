#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for #849 bug-hunt finding observability.md#12: stats.html's
# refresh() used a fire-once `errorShown` flag for the netdata-unreachable
# banner that was set to true on the first failure but never reset back to
# false after a later successful refresh -- so a netdata outage that
# recovered and then failed again later in the same page load never
# re-displayed the banner; only a full page reload cleared the flag.
#
# This project has no JS test runner (Rust/Bash-only project language,
# AG-REL-004) and does not introduce one for a three-line template fix, so
# this is a structural grep-based guard on the inline <script> block rather
# than an executed JS test -- it asserts the reset line lives in the actual
# success path (before the `catch`), not merely that the string appears
# somewhere in the file.

bats_require_minimum_version 1.5.0

STATS_HTML="services/ui/src/templates/stats.html"

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    cd "$repo_root"
}

@test "stats.html declares errorShown as a mutable flag starting false" {
    grep -qE 'let errorShown = false;' "$STATS_HTML"
}

@test "stats.html's refresh() resets errorShown to false in the success path, before the catch block" {
    success_block=$(awk '/async function refresh\(\)/{flag=1} flag{print} /\} catch \(e\)/{exit}' "$STATS_HTML")
    [[ "$success_block" == *"errorShown = false;"* ]]
}

@test "stats.html's refresh() still sets errorShown = true on failure (fire-once-per-outage behavior preserved)" {
    failure_block=$(awk '/\} catch \(e\)/{flag=1} flag{print}' "$STATS_HTML")
    [[ "$failure_block" == *"errorShown = true;"* ]]
}
