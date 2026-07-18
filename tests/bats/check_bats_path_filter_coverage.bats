#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for scripts/check-bats-path-filter-coverage.sh (#879): the CI
# guard that fails a build if .github/workflows/build-tools.yml's
# on.push.paths / on.pull_request.paths filter drifts out of sync with the
# real, non-fixture file dependencies of tests/bats/*.bats and
# tests/bats/helpers/*.sh.
#
# Mirrors check_idempotence_test_coverage.bats's pattern: this file does NOT
# merely run the guard against the real repo (that only proves "passes
# today," not that the guard actually catches a regression) -- it builds a
# small fixture repo (a fixture tests/bats/*.bats file plus a fixture
# .github/workflows/build-tools.yml) and exercises the guard's pass/fail
# branches directly, including the exact #880-warned failure mode ("added to
# one list, forgot the other") and the fixture/example-path exclusions #879
# itself calls out as the over-matching risk of a naive implementation.
#
# Invoked as `run bash "$script" ...` throughout (never `run "$script"
# ..."`), matching check_workflow_service_lists.bats's own convention: this
# removes any dependency on the committed executable bit, which AGENTS.md's
# AG-VAL-024 documents as unverifiable from a Windows/core.filemode=false
# authoring sandbox (the exact incident that broke PR #937's own bats
# fixtures on first real Linux CI run). The script is additionally
# `chmod +x`'d and its git index mode verified via `git ls-files -s` as
# defense in depth, but no call site here relies on that bit.

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/check-bats-path-filter-coverage.sh"
    fixture_root="$BATS_TEST_TMPDIR/fixture-repo"
    mkdir -p "$fixture_root/tests/bats/helpers"
    mkdir -p "$fixture_root/.github/workflows"
    # Same bats-preprocessor trap as check_idempotence_test_coverage.bats:
    # writing a literal `@test "..." {` line inside this file's own heredocs
    # would get transpiled by bats-core's own preprocessor before the heredoc
    # ever runs. Route it through a variable so this file's own source never
    # contains the literal string.
    at_test='@test'
}

# write_workflow <push_paths_string> <pull_request_paths_string>
# Writes a minimal, real-shape build-tools.yml fixture: same fixed
# indentation this script's extract_workflow_paths() anchors to (on: at
# column 0, push:/pull_request: at 2 spaces, paths: at 4, list items at 6).
# Each argument is a newline-separated list of quoted-path lines already
# formatted (e.g. '      - "setup.sh"').
write_workflow() {
    local push_paths="$1" pr_paths="$2"
    cat > "$fixture_root/.github/workflows/build-tools.yml" <<EOF
on:
  push:
    branches: [master]
    paths:
${push_paths}
  pull_request:
    branches: [master]
    paths:
${pr_paths}
EOF
}

@test "passes when every real dependency is covered by an exact filter entry in both lists" {
    printf '#!/usr/bin/env bash\n' > "$fixture_root/setup.sh"
    cat > "$fixture_root/tests/bats/setup_smoke.bats" <<EOF
setup() {
    repo_root="\$(cd "\$BATS_TEST_DIRNAME/../.." && pwd)"
}

${at_test} "reads setup.sh" {
    [ -f "\$repo_root/setup.sh" ]
}
EOF
    write_workflow '      - "setup.sh"' '      - "setup.sh"'

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"All"*"real bats dependencies are covered"* ]]
}

@test "passes when a real dependency is covered only by a directory-wildcard entry" {
    mkdir -p "$fixture_root/services/dns"
    printf '#!/usr/bin/env bash\n' > "$fixture_root/services/dns/entrypoint.sh"
    cat > "$fixture_root/tests/bats/dns_smoke.bats" <<EOF
setup() {
    repo_root="\$(cd "\$BATS_TEST_DIRNAME/../.." && pwd)"
}

${at_test} "reads the dns entrypoint" {
    [ -f "\$repo_root/services/dns/entrypoint.sh" ]
}
EOF
    write_workflow '      - "services/dns/**"' '      - "services/dns/**"'

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "fails when a real dependency is missing from on.push.paths only" {
    printf '#!/usr/bin/env bash\n' > "$fixture_root/setup.sh"
    cat > "$fixture_root/tests/bats/setup_smoke.bats" <<EOF
setup() {
    repo_root="\$(cd "\$BATS_TEST_DIRNAME/../.." && pwd)"
}

${at_test} "reads setup.sh" {
    [ -f "\$repo_root/setup.sh" ]
}
EOF
    # The exact #880-warned failure mode: pull_request got the entry, push
    # did not ("easy to update one and miss the other").
    write_workflow '      - "tools/build-tools/**"' '      - "setup.sh"'

    run bash "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"'setup.sh'"* ]]
    [[ "$output" == *"on.push.paths"* ]]
}

@test "fails when a real dependency is missing from on.pull_request.paths only" {
    printf '#!/usr/bin/env bash\n' > "$fixture_root/setup.sh"
    cat > "$fixture_root/tests/bats/setup_smoke.bats" <<EOF
setup() {
    repo_root="\$(cd "\$BATS_TEST_DIRNAME/../.." && pwd)"
}

${at_test} "reads setup.sh" {
    [ -f "\$repo_root/setup.sh" ]
}
EOF
    write_workflow '      - "setup.sh"' '      - "tools/build-tools/**"'

    run bash "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"'setup.sh'"* ]]
    [[ "$output" == *"on.pull_request.paths"* ]]
}

@test "fails when a real dependency is missing from both lists" {
    mkdir -p "$fixture_root/services/watchdog"
    printf '#!/usr/bin/env bash\n' > "$fixture_root/services/watchdog/watchdog.sh"
    cat > "$fixture_root/tests/bats/watchdog_smoke.bats" <<EOF
setup() {
    repo_root="\$(cd "\$BATS_TEST_DIRNAME/../.." && pwd)"
}

${at_test} "reads the watchdog script" {
    [ -f "\$repo_root/services/watchdog/watchdog.sh" ]
}
EOF
    write_workflow '      - "tools/build-tools/**"' '      - "tools/build-tools/**"'

    run bash "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"services/watchdog/watchdog.sh"* ]]
    [[ "$output" == *"on.push.paths"* ]]
    [[ "$output" == *"on.pull_request.paths"* ]]
}

@test "does not require coverage for a fixture-sandbox path written under BATS_TEST_TMPDIR" {
    # Regression guard for the #879-warned over-match risk: a bats file that
    # builds its OWN nested fixture tree (like
    # check_idempotence_test_coverage.bats's seed_passing_fixture) writes
    # paths that look exactly like real repo paths (e.g.
    # services/dns/entrypoint.sh) but are rooted under a sandbox variable,
    # never under repo_root. Those must never be treated as dependencies
    # requiring their own filter coverage.
    printf '#!/usr/bin/env bash\n' > "$fixture_root/setup.sh"
    cat > "$fixture_root/tests/bats/nested_fixture_smoke.bats" <<EOF
setup() {
    repo_root="\$(cd "\$BATS_TEST_DIRNAME/../.." && pwd)"
    nested_fixture_root="\$BATS_TEST_TMPDIR/nested-fixture"
}

seed() {
    mkdir -p "\$nested_fixture_root/services/dns"
    printf '#!/usr/bin/env bash\n' > "\$nested_fixture_root/services/dns/entrypoint.sh"
}

${at_test} "reads setup.sh and seeds its own nested fixture" {
    seed
    [ -f "\$repo_root/setup.sh" ]
    [ -f "\$nested_fixture_root/services/dns/entrypoint.sh" ]
}
EOF
    # No services/dns/** entry anywhere -- if the sandbox path were wrongly
    # treated as a real dependency, this would fail; it must still pass,
    # since services/dns/entrypoint.sh does not exist under the fixture
    # repo's OWN root (only under the nested sandbox path).
    write_workflow '      - "setup.sh"' '      - "setup.sh"'

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "does not require coverage for an example path string that names no real file" {
    # A negative-test string like "$repo_root/scripts/does-not-exist.sh" uses
    # the real repo_root variable but names nothing that actually exists on
    # disk -- it must be dropped, not treated as a dependency the filter must
    # cover. Also references the real setup.sh alongside it (not covered by
    # the workflow fixture below) so this test proves the negative-test
    # string is silently dropped specifically -- rather than merely
    # exercising the separate "zero real dependencies found at all" fail-safe
    # this script also has, which a fixture with ONLY the non-existent
    # reference would hit instead, proving nothing about the exclusion this
    # test is actually named for.
    printf '#!/usr/bin/env bash\n' > "$fixture_root/setup.sh"
    cat > "$fixture_root/tests/bats/negative_smoke.bats" <<EOF
setup() {
    repo_root="\$(cd "\$BATS_TEST_DIRNAME/../.." && pwd)"
}

${at_test} "reads the real setup.sh" {
    [ -f "\$repo_root/setup.sh" ]
}

${at_test} "fails closed when a script does not exist" {
    [ ! -f "\$repo_root/scripts/does-not-exist.sh" ]
}
EOF
    write_workflow '      - "setup.sh"' '      - "setup.sh"'

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" != *"does-not-exist.sh"* ]]
}

@test "resolves the check_*.bats self-referencing BATS_TEST_DIRNAME/../../scripts form" {
    # The 4 real check_*.bats files (this one included) reference their own
    # script-under-test via $BATS_TEST_DIRNAME/../../scripts/<name>.sh
    # directly, bypassing repo_root entirely -- this must be recognized as a
    # real dependency too, not just the repo_root/... form.
    mkdir -p "$fixture_root/scripts"
    printf '#!/usr/bin/env bash\n' > "$fixture_root/scripts/check-something.sh"
    cat > "$fixture_root/tests/bats/check_something.bats" <<EOF
setup() {
    script="\$BATS_TEST_DIRNAME/../../scripts/check-something.sh"
}

${at_test} "the script under test exists" {
    [ -f "\$script" ]
}
EOF
    write_workflow '      - "tools/build-tools/**"' '      - "tools/build-tools/**"'

    run bash "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"scripts/check-something.sh"* ]]

    write_workflow '      - "scripts/check-something.sh"' '      - "scripts/check-something.sh"'
    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "fails closed when no tests/bats/*.bats or helper files exist" {
    rm -f "$fixture_root/tests/bats"/*.bats
    write_workflow '      - "setup.sh"' '      - "setup.sh"'

    run bash "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"found no tests/bats"* ]]
}

@test "fails closed when on.push.paths cannot be parsed at all" {
    printf '#!/usr/bin/env bash\n' > "$fixture_root/setup.sh"
    cat > "$fixture_root/tests/bats/setup_smoke.bats" <<EOF
setup() {
    repo_root="\$(cd "\$BATS_TEST_DIRNAME/../.." && pwd)"
}

${at_test} "reads setup.sh" {
    [ -f "\$repo_root/setup.sh" ]
}
EOF
    cat > "$fixture_root/.github/workflows/build-tools.yml" <<'EOF'
on:
  workflow_dispatch:
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"vacuous"* ]]
}

@test "fails closed when the workflow file itself is missing" {
    printf '#!/usr/bin/env bash\n' > "$fixture_root/setup.sh"
    cat > "$fixture_root/tests/bats/setup_smoke.bats" <<EOF
setup() {
    repo_root="\$(cd "\$BATS_TEST_DIRNAME/../.." && pwd)"
}

${at_test} "reads setup.sh" {
    [ -f "\$repo_root/setup.sh" ]
}
EOF
    rm -f "$fixture_root/.github/workflows/build-tools.yml"

    run bash "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"expected workflow not found"* ]]
}

@test "the guard also passes when pointed at the real repository tree" {
    real_repo_root="$BATS_TEST_DIRNAME/../.."
    run bash "$script" "$real_repo_root"
    [ "$status" -eq 0 ]
}
