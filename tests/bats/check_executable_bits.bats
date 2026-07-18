#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for scripts/check-executable-bits.sh (issue #1019 / #822
# Pattern B): the CI guard that fails a build when a repo script is invoked
# by a bare path in a workflow/composite-action file (or is a .githooks/
# hook) but is committed with a non-executable git mode.
#
# Every scenario builds a throwaway git fixture repo under $BATS_TEST_TMPDIR
# and commits files at deterministic modes (`git update-index --chmod=+x/-x`,
# independent of the fixture filesystem's own mode handling), then points the
# guard at it -- so the suite runs fully offline and never depends on or
# mutates the real repository. The guard is invoked as `bash "$script"`, not
# bare `run "$script"`, precisely so this exec-bit guard's own test cannot
# trip over the exec-bit bug it exists to catch (Rule-Ref: AG-VAL-024, "test
# harnesses included"; the same irony PR #804 hit and #822's Pattern H note
# calls out).

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/check-executable-bits.sh"
    fixture="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$fixture/.github/workflows"
    git -C "$fixture" init -q
    git -C "$fixture" config user.email test@example.com
    git -C "$fixture" config user.name "bats fixture"
    # Never block on a signing prompt in the sandbox.
    git -C "$fixture" config commit.gpgsign false
}

# add_script <relpath> <yes|no>
# Creates a script under the fixture and stages it as executable (yes) or
# non-executable (no) in git, deterministically via update-index --chmod so
# the committed mode does not depend on the fixture filesystem's umask or the
# host's core.filemode setting.
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

# write_workflow <shell-body-line>
# Writes a minimal single-step workflow whose run: block contains the given
# shell line, and stages it.
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
    add_script scripts/ui-nats-dns-integration-simulation.sh no
    write_workflow 'scripts/ui-nats-dns-integration-simulation.sh'
    commit_fixture

    run bash "$script" "$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ui-nats-dns-integration-simulation.sh"* ]]
}
