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
