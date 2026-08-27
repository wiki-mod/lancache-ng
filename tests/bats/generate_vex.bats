#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Coverage for scripts/tracked/generate-vex.sh's per-entry status/justification
# handling: entries whose .trivyignore.yaml statement asserts a real
# non-exploitability finding
# (vulnerable code confirmed absent) must produce an OpenVEX `not_affected`
# statement with a `justification`, not the generator's long-standing
# `affected`/`action_statement` default meant for entries genuinely awaiting
# an upstream fix. Also guards against a real bug found while implementing
# this: the awk-to-bash handoff uses IFS=TAB `read` to split fields, and
# bash's IFS whitespace-collapse rule (TAB counts as whitespace, same as
# space/newline) silently drops a genuinely empty middle field and shifts
# every later field left by one -- confirmed empirically outside this
# suite (`printf 'a\tb\t\td\n' | IFS=$'\t' read -r f1 f2 f3 f4` yields
# f3=d, f4 empty, not f3 empty/f4=d). generate-vex.sh's nz()/sentinel-undo
# pair exists specifically to prevent that regression; these tests exercise
# exactly the entry shapes (an entry with `status:` set alongside an
# already-empty `expired_at`-less predecessor field) that would silently
# misalign without it.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/tracked/generate-vex.sh"
    fixture="$BATS_TEST_TMPDIR/trivyignore.yaml"
    # Deterministic output for every test in this file, matching how
    # scripts/untracked/check-vex-drift.sh feeds a fixed committed timestamp back in.
    export VEX_TIMESTAMP="2026-01-01T00:00:00Z"
}

@test "generate-vex.sh defaults an entry with no status field to affected/action_statement" {
    cat > "$fixture" <<'EOF'
vulnerabilities:
  - id: CVE-2026-00001
    paths:
      - usr/bin/example
    statement: >-
      Accepted, no fix available yet.
    expired_at: 2026-12-31
EOF

    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]

    run jq -r '.statements[0].status' <<<"$output"
    [ "$output" = "affected" ]
}

@test "generate-vex.sh maps status: not_affected to a real OpenVEX not_affected/justification statement" {
    cat > "$fixture" <<'EOF'
vulnerabilities:
  - id: CVE-2026-00002
    paths:
      - usr/bin/example
    statement: >-
      Not exploitable: the vulnerable code path is not compiled into this
      binary at all.
    status: not_affected
    expired_at: 2026-12-31
EOF

    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]

    parsed="$output"
    [ "$(jq -r '.statements[0].status' <<<"$parsed")" = "not_affected" ]
    [ "$(jq -r '.statements[0].justification' <<<"$parsed")" = "vulnerable_code_not_present" ]
    [ "$(jq -r '.statements[0].action_statement // "null"' <<<"$parsed")" = "null" ]
    [[ "$(jq -r '.statements[0].impact_statement' <<<"$parsed")" == *"not compiled into this binary"* ]]
}

@test "generate-vex.sh honors an explicit justification override for a not_affected entry" {
    cat > "$fixture" <<'EOF'
vulnerabilities:
  - id: CVE-2026-00003
    paths:
      - usr/bin/example
    statement: >-
      Not exploitable: this path can never be reached with attacker input.
    status: not_affected
    justification: vulnerable_code_cannot_be_controlled_by_adversary
    expired_at: 2026-12-31
EOF

    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.statements[0].justification' <<<"$output")" = "vulnerable_code_cannot_be_controlled_by_adversary" ]
}

# The real regression this suite exists to catch: a `not_affected` entry
# (empty justification field) followed immediately by an ordinary `affected`
# entry (no status/justification at all, both empty) -- two consecutive
# genuinely-empty middle fields in a row is exactly the shape that silently
# misaligned before the nz() sentinel fix, since a naive fix might only
# handle a single isolated empty field correctly.
@test "generate-vex.sh keeps fields correctly aligned across multiple entries with different empty-field shapes" {
    cat > "$fixture" <<'EOF'
vulnerabilities:
  - id: CVE-2026-00004
    paths:
      - usr/bin/first
    statement: >-
      Not exploitable: vulnerable code absent from this binary.
    status: not_affected
    expired_at: 2026-12-31
  - id: CVE-2026-00005
    paths:
      - usr/bin/second
    statement: >-
      Accepted, no fix available yet either.
    expired_at: 2026-12-31
EOF

    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    parsed="$output"

    [ "$(jq -r '.statements | length' <<<"$parsed")" -eq 2 ]
    [ "$(jq -r '.statements[0].vulnerability.name' <<<"$parsed")" = "CVE-2026-00004" ]
    [ "$(jq -r '.statements[0].status' <<<"$parsed")" = "not_affected" ]
    [ "$(jq -r '.statements[0].justification' <<<"$parsed")" = "vulnerable_code_not_present" ]
    [ "$(jq -r '.statements[0].products[0]."@id"' <<<"$parsed")" = "pkg:github/wiki-mod/lancache-ng" ]
    [ "$(jq -r '.statements[0].products[0].subcomponents[0]."@id"' <<<"$parsed")" = "usr/bin/first" ]

    [ "$(jq -r '.statements[1].vulnerability.name' <<<"$parsed")" = "CVE-2026-00005" ]
    [ "$(jq -r '.statements[1].status' <<<"$parsed")" = "affected" ]
    [ "$(jq -r '.statements[1].products[0].subcomponents[0]."@id"' <<<"$parsed")" = "usr/bin/second" ]
}

@test "generate-vex.sh is deterministic for identical input given a fixed VEX_TIMESTAMP" {
    cat > "$fixture" <<'EOF'
vulnerabilities:
  - id: CVE-2026-00006
    paths:
      - usr/bin/example
    statement: >-
      Not exploitable: vulnerable code absent.
    status: not_affected
    expired_at: 2026-12-31
EOF

    run bash "$script" "$fixture"
    first="$output"
    run bash "$script" "$fixture"
    second="$output"
    [ "$first" = "$second" ]
}
