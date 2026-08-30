#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: coverage for check-executable-bits.sh, the CI guard.
# Why: every scenario invokes the guard via bash, not run.
# From: Issue #1019 | PR #1501

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/tracked/check-executable-bits.sh"
    fixture="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$fixture/.github/workflows"
    git -C "$fixture" init -q
    git -C "$fixture" config user.email test@example.com
    git -C "$fixture" config user.name "bats fixture"
    # Never block on a signing prompt in the sandbox.
    git -C "$fixture" config commit.gpgsign false
}

# What: add_script() stages a script, executable or not.
# Why: update-index --chmod sets mode deterministically.
# From: Issue #1019 | PR #1501
add_script() {
    local rel="$1" want_exec="$2"
    mkdir -p "$fixture/$(dirname "$rel")"
    printf '#!/usr/bin/env bash\necho hi\n' > "$fixture/$rel"
    git -C "$fixture" add "$rel"
    if [ "$want_exec" = yes ]; then
        git -C "$fixture" update-index --chmod=+x "$rel"
    else
        git -C "$fixture" update-index --chmod=-x "$rel"
    fi
}

# What: write_workflow() writes and stages a run: workflow.
# Why: a real file exercises the guard's YAML parsing path.
# From: Issue #1019 | PR #1501
write_workflow() {
    local body="$1"
    cat > "$fixture/.github/workflows/ci.yml" <<EOF
name: CI
on: push
jobs:
  build:
    steps:
      - name: step
        run: |
          set -euo pipefail
          $body
EOF
    git -C "$fixture" add .github/workflows/ci.yml
}

commit_fixture() {
    git -C "$fixture" commit -qm fixture
}

@test "fails on a bare-path invocation of a script committed 100644 (the #617/#711 regression shape)" {
    # The core defect: a workflow runs `scripts/foo.sh` directly while the
    # file is committed non-executable -- exactly what broke #617 and #711.
    add_script scripts/foo.sh no
    write_workflow 'scripts/foo.sh'
    commit_fixture

    run bash "$script" "$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"scripts/foo.sh"* ]]
    [[ "$output" == *"100644"* ]]
}

@test "passes once the same bare-path script is committed 100755" {
    # Proves the guard's pass condition is really the executable bit, not
    # merely 'the file exists' -- the only change from the failing case above
    # is the committed mode.
    add_script scripts/foo.sh yes
    write_workflow 'scripts/foo.sh'
    commit_fixture

    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "does not flag an interpreter-prefixed invocation (bash scripts/foo.sh) even when 100644" {
    # `bash scripts/foo.sh` reads the file as an argument to bash and never
    # execs it, so the executable bit is irrelevant -- the guard must not
    # false-fail here (this is why the four historical scripts with a `bash`
    # sibling invocation stayed latent instead of red).
    add_script scripts/foo.sh no
    write_workflow 'bash scripts/foo.sh'
    commit_fixture

    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
}

@test "does not flag a sourced script (. and source) even when 100644" {
    # `.`/`source` read the file into the current shell; no exec bit needed.
    add_script scripts/lib/util.sh no
    write_workflow '. scripts/lib/util.sh'
    commit_fixture

    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
}

@test "does not flag a script passed as a data argument (grep ... scripts/foo.sh) when 100644" {
    # Only the command *word* is checked; a script path handed to grep/cat as
    # an argument is not executed, so its mode is irrelevant. Guards against
    # over-matching any path-looking token.
    add_script scripts/foo.sh no
    write_workflow "grep -F needle scripts/foo.sh"
    commit_fixture

    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
}

@test "does not flag a script mentioned only in a shell comment when 100644" {
    # A workflow comment that merely names a script (as several real
    # workflows do in prose) must never be read as an invocation.
    add_script scripts/foo.sh no
    write_workflow '# note: scripts/foo.sh is run elsewhere'
    commit_fixture

    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
}

@test "flags a bare invocation that follows a command separator (cd x && scripts/foo.sh)" {
    # Command position is not only start-of-line: a script executed after
    # `&&` is still a bare exec and still needs the bit.
    add_script scripts/foo.sh no
    write_workflow 'cd "$GITHUB_WORKSPACE" && scripts/foo.sh'
    commit_fixture

    run bash "$script" "$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"scripts/foo.sh"* ]]
}

@test "fails when a .githooks/ hook is committed 100644 (the PR #804 .githooks/pre-push half)" {
    # git runs a hook by bare path unconditionally, so every tracked
    # .githooks/ file must be executable regardless of any workflow
    # reference -- this is the half of PR #804's incident a workflow-only
    # scan would miss.
    write_workflow 'bash scripts/noop.sh'
    add_script scripts/noop.sh yes
    add_script .githooks/pre-push no
    commit_fixture

    run bash "$script" "$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *".githooks/pre-push"* ]]
    [[ "$output" == *"100644"* ]]
}

@test "passes when a .githooks/ hook is committed 100755" {
    # The pass counterpart of the hook case: an executable hook is fine.
    write_workflow 'bash scripts/noop.sh'
    add_script scripts/noop.sh yes
    add_script .githooks/pre-push yes
    commit_fixture

    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
}

@test "scans composite-action files, not just workflows (bare invocation in action.yml, 100644)" {
    # A composite action's own run: step can execute a repo script bare; the
    # guard must cover .github/actions/**/action.yml too, matching
    # check-action-node-versions.sh's scan scope.
    add_script scripts/foo.sh no
    mkdir -p "$fixture/.github/actions/do-thing"
    cat > "$fixture/.github/actions/do-thing/action.yml" <<'EOF'
name: Do thing
runs:
  using: composite
  steps:
    - shell: bash
      run: |
        scripts/foo.sh
EOF
    # A workflow must exist too or the scan set would be empty for a
    # different reason; make it a clean interpreter-prefixed one.
    write_workflow 'bash scripts/foo.sh'
    git -C "$fixture" add .github/actions/do-thing/action.yml
    commit_fixture

    run bash "$script" "$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"scripts/foo.sh"* ]]
    [[ "$output" == *"action.yml"* ]]
}

@test "reports every offending file in one run, not just the first" {
    # A batch of bare-path invocations of non-executable scripts should all
    # be named, so a contributor fixes them in one pass.
    add_script scripts/a.sh no
    add_script scripts/b.sh no
    cat > "$fixture/.github/workflows/ci.yml" <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - name: step
        run: |
          set -euo pipefail
          scripts/a.sh
          scripts/b.sh
EOF
    git -C "$fixture" add .github/workflows/ci.yml
    commit_fixture

    run bash "$script" "$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"scripts/a.sh"* ]]
    [[ "$output" == *"scripts/b.sh"* ]]
    [[ "$output" == *"2 file(s)"* ]]
}

@test "would have caught #617: ui-nats-dns-integration-simulation.sh committed 100644 and invoked bare" {
    # Permanent regression proof reproducing #617's exact shape (the named
    # script, invoked directly from a workflow, committed non-executable) so
    # this suite is itself the evidence the guard would have caught it,
    # without a one-off manual verification that leaves no trace once merged.
    add_script scripts/untracked/simulations/ui-nats-dns-integration-simulation.sh no
    write_workflow 'scripts/untracked/simulations/ui-nats-dns-integration-simulation.sh'
    commit_fixture

    run bash "$script" "$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ui-nats-dns-integration-simulation.sh"* ]]
}

# What: four tests below cover the run: block-scalar parser.
# Why: block-scalar YAML needs its own parsing coverage.
# From: Issue #1019 | PR #1501
@test "does not treat a workflow paths filter entry as a script invocation" {
    # `on.*.paths` is YAML configuration data, not shell content. A path that
    # happens to name a non-executable script must not be classified as a
    # command merely because YAML represents the filter as a sequence item.
    add_script tests/bats/filter-only.bats no
    cat > "$fixture/.github/workflows/ci.yml" <<'EOF'
name: CI
on:
  pull_request:
    paths:
      - tests/bats/filter-only.bats
jobs:
  build:
    steps:
      - run: echo ok
EOF
    git -C "$fixture" add .github/workflows/ci.yml
    commit_fixture

    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "does not treat a backslash-continued for word list as separate commands" {
    # Words between `for ... in` and `; do` are iteration data. Joining the
    # physical continuation lines before command-word classification keeps a
    # script-looking data item attached to the `for` statement instead of
    # inventing a bare-path command that Bash would never execute there.
    add_script tests/bats/required-file.bats no
    cat > "$fixture/.github/workflows/ci.yml" <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - run: |
          set -euo pipefail
          for required in \
            tests/bats/required-file.bats; do
            test -f "$required"
          done
EOF
    git -C "$fixture" add .github/workflows/ci.yml
    commit_fixture

    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "still detects a bare script in an inline run scalar" {
    # Restricting the scanner to `run:` values must not narrow the original
    # protection to block scalars only; a direct inline command is equally an
    # exec-bit dependency.
    add_script scripts/inline.sh no
    cat > "$fixture/.github/workflows/ci.yml" <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - run: scripts/inline.sh
EOF
    git -C "$fixture" add .github/workflows/ci.yml
    commit_fixture

    run bash "$script" "$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"scripts/inline.sh"* ]]
}

@test "still detects a bare script in a folded run block" {
    # YAML permits folded (`>`) as well as literal (`|`) block scalars for a
    # `run` value. A simple one-command folded block must retain the same
    # direct-exec protection as the established literal-block fixtures.
    add_script scripts/folded.sh no
    cat > "$fixture/.github/workflows/ci.yml" <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - run: >-
          scripts/folded.sh
EOF
    git -C "$fixture" add .github/workflows/ci.yml
    commit_fixture

    run bash "$script" "$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"scripts/folded.sh"* ]]
}
