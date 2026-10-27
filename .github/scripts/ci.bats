#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: A new test needs a prior maintainer ACK on the PR.
# Why: AG-WF-029 order, issue comment 6145242213.
# From: Issue #1683 | PR #1912

# What: run one base command, log its full output, keep rc.
# Why: one owner for the four base-fact tests below.
# From: Issue #1683 | PR #1858
base_fact() {
    run "$@"
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}

# What: logs uptime and load of the test host.
# Why: DoMe ACK 23.10. 21:40 CEST: base facts every run.
# From: Issue #1683 | PR #1858
@test "base: uptime" {
    base_fact uptime
}

# What: logs every process with full command lines.
# Why: DoMe ACK 23.10. 21:40 CEST: base facts every run.
# From: Issue #1683 | PR #1858
@test "base: ps auxwww" {
    base_fact ps auxwww
}

# What: logs disk usage of every mounted file system.
# Why: DoMe ACK 23.10. 21:40 CEST: base facts every run.
# From: Issue #1683 | PR #1858
@test "base: df -h" {
    base_fact df -h
}

# What: logs memory and swap use in MiB.
# Why: DoMe ACK 23.10. 21:40 CEST: base facts every run.
# From: Issue #1683 | PR #1858
@test "base: free -m" {
    base_fact free -m
}

# What: distinguish indexes by their accepted platform digests.
# Why: a dependency refresh can change images without a Git commit.
# From: Issue #1683
@test "assembly lookup uses exact platform set and rejects mismatch" {
    run bash -c '
        export CI_TMPDIR="${BATS_TEST_TMPDIR}"
        source .github/scripts/ci.sh
        _ci_image_ref() { printf "example/%s\\n" "$1"; }
        _ci_required_field() { printf "assembly-\\n"; }
        a="linux/amd64=sha256:$(printf %064d 1) linux/arm64=sha256:$(printf %064d 2) "
        b="linux/amd64=sha256:$(printf %064d 1) linux/arm64=sha256:$(printf %064d 3) "
        [ "$(_ci_assembly_tag dns "$a")" != "$(_ci_assembly_tag dns "$b")" ] || exit 1
        _ci_registry_probe() { printf "sha256:%064d\\n" 9; }
        _ci_index_children() { printf "%s\\n" "$a" | tr " " "\\n"; }
        [ "$(_ci_index_lookup dns "$a")" = "sha256:$(printf %064d 9)" ] || exit 1
        if _ci_index_lookup dns "$b" >/dev/null 2>&1; then exit 1; fi
        _ci_registry_probe() { return 1; }
        [ -z "$(_ci_reconcile_index dns "$a")" ] || exit 1
        _ci_registry_probe() { return 2; }
        if _ci_reconcile_index dns "$a" >/dev/null 2>&1; then exit 1; fi
    '
    [ "${status}" -eq 0 ]
}
