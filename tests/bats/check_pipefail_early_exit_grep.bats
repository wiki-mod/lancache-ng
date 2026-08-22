#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Coverage for scripts/untracked/check-pipefail-early-exit-grep.sh (AG-VAL-029 standing
# check for the confirmed real CI failure on issue #815's PR #1374, job
# 91393831566: `rustup target list --installed | grep -qx ...` /
# `rustc -vV | grep -qE ...` failed with exit 141/SIGPIPE under
# `set -euo pipefail`, because `grep -q` exits as soon as it finds a match,
# closing the pipe while the producer may still be writing).
#
# The guard's own `scan_files` is repo-wide (`git ls-files` over
# scripts/**, tools/**, setup.sh, per issue #1377's audit widening it past
# PR #1374's original tools/build-tools/Dockerfile-only scope), so each
# fixture here is its own minimal git repository (`git init` + `git add`)
# rather than a bare directory -- `git ls-files` only sees tracked files
# inside a real working tree, and a fixture that is never `git add`-ed
# would silently be invisible to the guard, making every "fails on ..."
# test below a false negative instead of exercising the real code path.
#
# The guard is invoked as `bash "$script"` per Rule-Ref: AG-VAL-024.

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/untracked/check-pipefail-early-exit-grep.sh"
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    fixture="$BATS_TEST_TMPDIR/fx"
    mkdir -p "$fixture/tools/build-tools"
    git -C "$fixture" init -q
    # A fixture-local identity: this repo's own real git config (name/email,
    # signing) must never leak into a throwaway test repository.
    git -C "$fixture" -c user.email="test@example.invalid" -c user.name="test" \
        commit -q --allow-empty -m "empty root commit"
}

# fixture_add: stage and commit every file currently under $fixture, so
# `git ls-files` (what the real guard uses to discover scan_files) actually
# sees it.
fixture_add() {
    git -C "$fixture" add -A
    git -C "$fixture" -c user.email="test@example.invalid" -c user.name="test" \
        commit -q -m "fixture update"
}

# write_dockerfile <line>...
# Writes a fixture Dockerfile with a pipefail RUN step containing the given
# extra lines verbatim (one per argument, each terminated with '; \'), then
# commits it into the fixture repo so `git ls-files` picks it up.
write_dockerfile() {
    {
        printf 'FROM scratch\n'
        printf 'RUN set -euo pipefail; \\\n'
        local line
        for line in "$@"; do
            printf '    %s; \\\n' "$line"
        done
        printf '    true\n'
    } > "$fixture/tools/build-tools/Dockerfile"
    fixture_add
}

# write_script <relative-path> <line>...
# Writes a fixture scripts/**-style shell file with a pipefail preamble
# containing the given extra lines verbatim, then commits it.
write_script() {
    local rel="$1"
    shift
    mkdir -p "$(dirname "$fixture/$rel")"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -euo pipefail\n'
        local line
        for line in "$@"; do
            printf '%s\n' "$line"
        done
    } > "$fixture/$rel"
    fixture_add
}

@test "passes on a Dockerfile with no pipefail usage at all" {
    printf 'FROM scratch\nRUN rustc -vV | grep -qE "host"\n' > "$fixture/tools/build-tools/Dockerfile"
    fixture_add
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "passes on a pipefail Dockerfile using the capture-into-variable pattern" {
    write_dockerfile \
        'installed_targets="$(rustup target list --installed)"' \
        'grep -qx "x86_64-unknown-linux-musl" <<<"${installed_targets}"' \
        'rustc_host_line="$(rustc -vV)"' \
        'grep -qE "^host: .*-gnu\$" <<<"${rustc_host_line}"'
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "fails on the exact real-incident pattern: grep -qx piped from a live producer under pipefail" {
    write_dockerfile 'rustup target list --installed | grep -qx "x86_64-unknown-linux-musl"'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"pipes a live command into an early-exiting consumer"* ]]
}

@test "fails on grep -qE piped from a live producer under pipefail" {
    write_dockerfile 'rustc -vV | grep -qE "^host: .*-gnu\$"'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"grep -qE"* ]] || [[ "$output" == *"early-exiting consumer"* ]]
}

@test "fails on a live pipe into head" {
    write_dockerfile 'some_command | head -n1'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"early-exiting consumer"* ]]
}

@test "fails on a live pipe into sed -n" {
    write_dockerfile "some_command | sed -n '1p'"
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"early-exiting consumer"* ]]
}

@test "does not flag grep -F reading a file argument (not a live pipe)" {
    write_dockerfile 'grep -F "some-token" "some-file" >/dev/null'
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "does not self-trigger on a comment line quoting the dangerous pattern as prose" {
    {
        printf 'FROM scratch\n'
        printf '# This RUN previously used `producer | grep -q pattern` and failed.\n'
        printf 'RUN set -euo pipefail; true\n'
    } > "$fixture/tools/build-tools/Dockerfile"
    fixture_add
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "an inline trailing comment on a real bad line does not suppress the finding" {
    write_dockerfile 'rustup target list --installed | grep -qx "x86_64-unknown-linux-musl" # some unrelated comment'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"early-exiting consumer"* ]]
}

@test "a line marked pipefail-safe is not flagged" {
    write_dockerfile 'rustup target list --installed | grep -qx "x86_64-unknown-linux-musl" # pipefail-safe: reviewed, output is a single short line'
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

# --- Repo-wide scope coverage (issue #1377) -------------------------------
# The tests above only ever wrote into tools/build-tools/Dockerfile, which
# would still pass even if scan_files had silently stayed hardcoded to that
# one path -- these prove the widened scan_files genuinely reaches a
# scripts/**-style file too, not just the original Dockerfile.

@test "fails on the exact real-incident shape reproduced in a scripts/**-style file" {
    write_script "scripts/example-check.sh" \
        'result="$(some_producer_command)"' \
        'if some_other_producer | grep -q "needle"; then' \
        '  echo found' \
        'fi'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"scripts/example-check.sh"* ]]
    [[ "$output" == *"early-exiting consumer"* ]]
}

@test "passes on a scripts/**-style file using the capture-into-here-string pattern" {
    write_script "scripts/example-check.sh" \
        'producer_output="$(some_producer_command)"' \
        'if grep -q "needle" <<<"$producer_output"; then' \
        '  echo found' \
        'fi'
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "fails on the same pattern in a scripts/lib/**-style file" {
    write_script "scripts/lib/example-lib.sh" \
        'if docker logs some_container 2>&1 | grep -q "ready"; then' \
        '  echo ready' \
        'fi'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"scripts/lib/example-lib.sh"* ]]
}

@test "fails on the same pattern in a setup.sh-style file at the fixture root" {
    write_script "setup.sh" \
        'if some_producer | head -1 | grep -q "x"; then' \
        '  echo yes' \
        'fi'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"setup.sh"* ]]
}

@test "fails on the same pattern in a services/**-style entrypoint file" {
    # Pins the services/** pathspec itself: this is the exact class of real
    # bug found in services/dns/entrypoint.sh (a set -e script silently
    # dying on an unguarded printf | grep -qi). Without this fixture, an
    # accidental narrowing of scan_files that dropped 'services/*.sh'
    # 'services/**/*.sh' would leave the whole suite green.
    write_script "services/example-service/entrypoint.sh" \
        'if printf "%s" "$captured_value" | grep -qi "needle"; then' \
        '  echo found' \
        'fi'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"services/example-service/entrypoint.sh"* ]]
    [[ "$output" == *"early-exiting consumer"* ]]
}

@test "fails on the exact real-incident shape reproduced in a services/*/Dockerfile-style file" {
    # Service Dockerfiles need their own path fixture because shell scripts
    # under services/** do not prove the Dockerfile pathspec is retained.
    mkdir -p "$fixture/services/example-service"
    {
        printf 'FROM scratch\n'
        printf 'RUN set -euo pipefail; \\\n'
        printf '    rustup target list --installed | grep -qx "x86_64-unknown-linux-musl"\n'
    } > "$fixture/services/example-service/Dockerfile"
    fixture_add
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"services/example-service/Dockerfile"* ]]
    [[ "$output" == *"early-exiting consumer"* ]]
}

@test "fails when a service Dockerfile inherits pipefail from build-tools" {
    # BUILD_TOOLS_IMAGE supplies a Bash/pipefail SHELL to subsequent RUN
    # instructions, so the child does not need to repeat the word pipefail.
    mkdir -p "$fixture/services/example-service"
    {
        printf 'ARG BUILD_TOOLS_IMAGE=ghcr.io/example/build-tools:latest\n'
        printf 'FROM ${BUILD_TOOLS_IMAGE} AS builder\n'
        printf 'RUN rustup target list --installed | grep -qx "x86_64-unknown-linux-musl"\n'
    } > "$fixture/services/example-service/Dockerfile"
    fixture_add
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"services/example-service/Dockerfile"* ]]
    [[ "$output" == *"early-exiting consumer"* ]]
}

@test "fails when a service Dockerfile directly references a tagged build-tools image" {
    # Direct image references may select a tag or digest, both of which are
    # part of the image token and must not disable inherited-pipefail coverage.
    mkdir -p "$fixture/services/example-service"
    {
        printf 'FROM ghcr.io/wiki-mod/lancache-ng/build-tools:latest AS builder\n'
        printf 'RUN rustup target list --installed | grep -qx "x86_64-unknown-linux-musl"\n'
    } > "$fixture/services/example-service/Dockerfile"
    fixture_add
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"services/example-service/Dockerfile"* ]]
    [[ "$output" == *"early-exiting consumer"* ]]
}

@test "fails when a service Dockerfile inherits pipefail from build-tools via an indented FROM" {
    # The Dockerfile format reference documents leading whitespace before an
    # instruction as ignored, so an indented FROM must retain the same
    # inherited-pipefail coverage as one starting at column 0.
    mkdir -p "$fixture/services/example-service"
    {
        printf 'ARG BUILD_TOOLS_IMAGE=ghcr.io/example/build-tools:latest\n'
        printf '  FROM ${BUILD_TOOLS_IMAGE} AS builder\n'
        printf 'RUN rustup target list --installed | grep -qx "x86_64-unknown-linux-musl"\n'
    } > "$fixture/services/example-service/Dockerfile"
    fixture_add
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"services/example-service/Dockerfile"* ]]
    [[ "$output" == *"early-exiting consumer"* ]]
}

@test "fails when a service Dockerfile inherits pipefail from build-tools via a lowercase from" {
    # Dockerfile instruction names are case-insensitive -- Docker accepts
    # `from`/`From`/`FROM` identically -- so a differently-cased instruction
    # must retain the same inherited-pipefail coverage as uppercase FROM.
    mkdir -p "$fixture/services/example-service"
    {
        printf 'ARG BUILD_TOOLS_IMAGE=ghcr.io/example/build-tools:latest\n'
        printf 'from ${BUILD_TOOLS_IMAGE} AS builder\n'
        printf 'RUN rustup target list --installed | grep -qx "x86_64-unknown-linux-musl"\n'
    } > "$fixture/services/example-service/Dockerfile"
    fixture_add
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"services/example-service/Dockerfile"* ]]
    [[ "$output" == *"early-exiting consumer"* ]]
}

@test "fails when a service Dockerfile inherits pipefail from build-tools via a flagged FROM" {
    # `FROM` accepts optional `--flag`/`--flag=value` tokens (e.g.
    # `--platform=$BUILDPLATFORM`) before the image reference -- a real
    # multi-platform service builder commonly writes exactly this shape.
    # Valid flagged FROM instructions must retain the same inherited-pipefail
    # coverage that the sibling fixture proves for an unflagged FROM.
    mkdir -p "$fixture/services/example-service"
    {
        printf 'ARG BUILD_TOOLS_IMAGE=ghcr.io/example/build-tools:latest\n'
        printf 'FROM --platform=$BUILDPLATFORM ${BUILD_TOOLS_IMAGE} AS builder\n'
        printf 'RUN rustup target list --installed | grep -qx "x86_64-unknown-linux-musl"\n'
    } > "$fixture/services/example-service/Dockerfile"
    fixture_add
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"services/example-service/Dockerfile"* ]]
    [[ "$output" == *"early-exiting consumer"* ]]
}

@test "passes on a services/*/Dockerfile-style file using the capture-into-here-string pattern" {
    mkdir -p "$fixture/services/example-service"
    {
        printf 'FROM scratch\n'
        printf 'RUN set -euo pipefail; \\\n'
        printf '    installed_targets="$(rustup target list --installed)"; \\\n'
        printf '    grep -qx "x86_64-unknown-linux-musl" <<<"${installed_targets}"\n'
    } > "$fixture/services/example-service/Dockerfile"
    fixture_add
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "an untracked scripts/**-style file (never git add-ed) is invisible to the guard" {
    # Documents scan_files' own real discovery mechanism (git ls-files): a
    # file that exists on disk but was never committed to the fixture repo
    # is not part of the scan, the same way a real untracked scratch file
    # in the actual repository would not be scanned either.
    mkdir -p "$fixture/scripts"
    printf '#!/usr/bin/env bash\nset -euo pipefail\nsome_producer | grep -q "needle"\n' \
        > "$fixture/scripts/untracked-check.sh"
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "fails closed (does not silently report OK) when pointed at a directory that is not a git work tree" {
    # A naive `mapfile -t scan_files < <(git ls-files ...)` would not
    # propagate the process substitution's own failure -- a broken
    # discovery (no .git here, or git itself missing) would otherwise
    # silently leave scan_files empty, the scan loop would iterate zero
    # times, and the script would report a false "OK" with exit 0. The
    # real script instead captures `git ls-files`'s own exit status
    # explicitly first. A non-git directory is the simplest real
    # reproduction of that failure mode (advisor review, issue #1377).
    non_git="$BATS_TEST_TMPDIR/not-a-git-repo"
    mkdir -p "$non_git/scripts"
    printf '#!/usr/bin/env bash\nset -euo pipefail\nsome_producer | grep -q "needle"\n' \
        > "$non_git/scripts/some-check.sh"
    run bash "$script" "$non_git"
    [ "$status" -ne 0 ]
    [[ "$output" != *"OK"* ]]
    [[ "$output" == *"git ls-files\` itself failed"* ]]
}

## --------------------------------------------------------------------------
## check_if_without_else_status() coverage (issue #1449, added alongside the
## fix for the confirmed real instance in
## scripts/untracked/check-netdata-curl-pin.sh's fetch_bundled_packages_version()).
## This second check is deliberately NOT gated on the file mentioning
## "pipefail" (see this guard's own header comment), so write_script's
## `set -euo pipefail` preamble is not load-bearing for these fixtures the
## way it is for the pipefail-consumer tests above -- kept anyway for
## consistency with this file's existing helper and because the real
## incident file also happened to use `set -euo pipefail`.
## --------------------------------------------------------------------------

@test "fails on the exact real-incident pattern: if-without-else immediately followed by a \$? read expecting the real status" {
    # Minimal reproduction of scripts/untracked/check-netdata-curl-pin.sh's
    # fetch_bundled_packages_version() shape before its fix: an
    # if-without-else whose then-branch returns early on success, with the
    # very next line reading $? expecting the tested command's real
    # (failure) exit status -- which POSIX instead reports as 0 whenever the
    # if takes no branch at all.
    write_script "scripts/fetch.sh" \
        'fetch() {' \
        '  if curl -fsSL "$1"; then' \
        '    return 0' \
        '  fi' \
        '  local status=$?' \
        '  return "$status"' \
        '}'
    run bash "$script" "$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"if-without-else-then-\$?"* || "$output" == *"has no else clause"* ]]
    # write_script's own shebang + "set -euo pipefail" preamble is 2 lines,
    # so within this fixture: fetch() {=3, if curl=4, return 0=5, fi=6,
    # local status=$?=7 -- the guard reports the $? line (the violation
    # itself), not the fi line, matching the real repo's own
    # scripts/untracked/check-netdata-curl-pin.sh:156 (fi at 155, $? read at 156) shape.
    [[ "$output" == *"scripts/fetch.sh:7"* ]]
}

@test "passes when the fix pattern (explicit if/else status capture) is used instead" {
    # scripts/lib/ghcr-retry.sh's/scripts/lib/git-fetch-retry.sh's own
    # already-established pattern for this exact case, and the pattern
    # scripts/untracked/check-netdata-curl-pin.sh was fixed to use.
    write_script "scripts/fetch.sh" \
        'fetch() {' \
        '  if curl -fsSL "$1"; then' \
        '    status=0' \
        '  else' \
        '    status=$?' \
        '  fi' \
        '  return "$status"' \
        '}'
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "passes on a guard-clause if-without-else whose fallthrough case does not read \$?" {
    # scripts/untracked/simulations/dhcp-kea-lease-flow-simulation.sh's kea_ctrl_add_reservation()
    # shape: the tested condition represents FAILURE, handled with an
    # explicit early return inside the then-branch; the untaken (success)
    # path correctly falls through to an implicit 0 with nothing after the
    # fi reading $? at all. This is the safe mirror image of the real bug
    # (which instead tests for success and leaves the untaken failure path
    # to incorrectly default to 0), and must not be flagged.
    write_script "scripts/reserve.sh" \
        'reserve() {' \
        '  if ! check_ok "$1"; then' \
        '    echo "failed" >&2' \
        '    return 1' \
        '  fi' \
        '  echo "reservation added"' \
        '}'
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "passes when a real command runs between the fi and the \$? read" {
    # The $? read here legitimately belongs to log_result, not to the
    # preceding if-without-else -- an intervening real command between the
    # fi and the $? read means $? was never the if's own masked status to
    # begin with, so this must not be flagged.
    write_script "scripts/fetch.sh" \
        'fetch() {' \
        '  if curl -fsSL "$1"; then' \
        '    echo "got it"' \
        '  fi' \
        '  log_result "$1"' \
        '  status=$?' \
        '  return "$status"' \
        '}'
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "passes on an if/else/fi (has a real else) immediately followed by a \$? read" {
    # A branch always runs here (either the then or the else), so $?
    # immediately after the fi genuinely reflects whichever branch's own
    # last command ran -- not the masked-0 case this guard targets.
    write_script "scripts/fetch.sh" \
        'fetch() {' \
        '  if curl -fsSL "$1"; then' \
        '    log_ok' \
        '  else' \
        '    log_fail' \
        '  fi' \
        '  status=$?' \
        '  return "$status"' \
        '}'
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "does not fail when the offending \$? line is marked reviewed-safe" {
    write_script "scripts/fetch.sh" \
        'fetch() {' \
        '  if curl -fsSL "$1"; then' \
        '    return 0' \
        '  fi' \
        '  local status=$? # if-status-safe: caller only checks $1 emptiness, never this status' \
        '  return "$status"' \
        '}'
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "fails on a nested if-without-else (depth 2) immediately followed by a \$? read" {
    # Confirms the nesting-depth tracking (not just a flat "last fi seen")
    # correctly attributes the missing-else check to the INNER if, not the
    # outer one, when the inner if is the one immediately followed by $?.
    write_script "scripts/fetch.sh" \
        'fetch() {' \
        '  if [ -n "$1" ]; then' \
        '    if curl -fsSL "$1"; then' \
        '      return 0' \
        '    fi' \
        '    local status=$?' \
        '    return "$status"' \
        '  fi' \
        '  return 1' \
        '}'
    run bash "$script" "$fixture"
    [ "$status" -ne 0 ]
    # Preamble is 2 lines (see the previous test's comment for the full
    # count convention); within this fixture: fetch() {=3, outer if=4,
    # inner if curl=5, return 0=6, inner fi=7, local status=$?=8 -- the
    # guard reports the $? line.
    [[ "$output" == *"scripts/fetch.sh:8"* ]]
}

# write_workflow <relative-path> <line>...
# Writes a fixture .github/workflows/**-style YAML file with the given lines
# verbatim, then commits it -- this check's own scan (`git ls-files` over
# .github/workflows/*.yml(.yaml) and .github/actions/**/*.yml(.yaml)) only
# sees tracked files, mirroring write_script's own rationale above.
write_workflow() {
    local rel="$1"
    shift
    mkdir -p "$(dirname "$fixture/$rel")"
    {
        local line
        for line in "$@"; do
            printf '%s\n' "$line"
        done
    } > "$fixture/$rel"
    fixture_add
}

@test "fails on a docker run feeding a stdin heredoc without -i (third check)" {
    # Minimal reproduction of the real v0.3.0 incident shape: build-push.yml's
    # release job reported success while its heredoc silently ran nothing.
    write_workflow ".github/workflows/release.yml" \
        'jobs:' \
        '  release:' \
        '    steps:' \
        '      - run: |' \
        '          docker run --rm \' \
        '            -e GITHUB_TOKEN \' \
        '            "$IMAGE" \' \
        '            bash -s <<'"'"'MARKER'"'"'' \
        '          echo hi' \
        '          MARKER'
    run bash "$script" "$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing -i"* ]]
    [[ "$output" == *".github/workflows/release.yml:"* ]]
}

@test "passes on a docker run feeding a stdin heredoc with -i (third check)" {
    write_workflow ".github/workflows/release.yml" \
        'jobs:' \
        '  release:' \
        '    steps:' \
        '      - run: |' \
        '          docker run --rm -i \' \
        '            -e GITHUB_TOKEN \' \
        '            "$IMAGE" \' \
        '            bash -s <<'"'"'MARKER'"'"'' \
        '          echo hi' \
        '          MARKER'
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "does not flag a docker run with no stdin heredoc at all (third check)" {
    write_workflow ".github/workflows/build.yml" \
        'jobs:' \
        '  build:' \
        '    steps:' \
        '      - run: docker run --rm "$IMAGE" cargo build'
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "skips a comment line quoting the missing-i pattern as documentation (third check)" {
    # Real false positive found by actually running an earlier version of
    # this check against vex-regenerate.yml: its own explanatory comment
    # (quoting "bash -s <<'MARKER'" verbatim) was misread as a real
    # invocation. This fixture reproduces that shape directly.
    write_workflow ".github/workflows/vex-regenerate.yml" \
        'jobs:' \
        '  regenerate-vex:' \
        '    steps:' \
        '      - run: |' \
        '          # stdin via the bash -s <<'"'"'MARKER'"'"' heredoc below. Without -i, docker' \
        '          # run never attaches container stdin.' \
        '          docker run --rm -i \' \
        '            "$IMAGE" \' \
        '            bash -s <<'"'"'MARKER'"'"'' \
        '          echo hi' \
        '          MARKER'
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "anchors on the LAST of two docker run invocations in the lookback window, not the first (third check)" {
    # Real repo shape (the VEX/SBOM upload steps): a plain generate call
    # with -i, then a separate heredoc-fed upload call ~10 lines later
    # missing -i. Anchoring on the FIRST docker run in the window would
    # silently pass this real violation because the earlier invocation
    # happens to carry -i.
    write_workflow ".github/workflows/release.yml" \
        'jobs:' \
        '  release:' \
        '    steps:' \
        '      - run: |' \
        '          docker run --rm -i \' \
        '            "$IMAGE" \' \
        '            bash generate.sh' \
        '' \
        '          docker run --rm \' \
        '            -e GITHUB_TOKEN \' \
        '            "$IMAGE" \' \
        '            bash -s <<'"'"'MARKER'"'"'' \
        '          echo hi' \
        '          MARKER'
    run bash "$script" "$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing -i"* ]]
}

@test "the real repository passes this guard repo-wide (scripts/**, tools/**, setup.sh, .github/workflows/**, .github/actions/**)" {
    # Defense-in-depth self-check: every file the real, repo-wide scan_files
    # and yaml_scan_files discover today must actually satisfy this guard,
    # so a future edit that reintroduces any of the three incident patterns
    # anywhere in scope is caught by this suite too, not only by the CI
    # guard step.
    run bash "$script" "$repo_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}
