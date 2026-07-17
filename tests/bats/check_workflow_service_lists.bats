#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for scripts/check-workflow-service-lists.sh (#822): the CI guard
# that fails a build if build-push.yml's several independent `services=(...)`
# arrays (which drive manifest merge, channel promotion, and release) ever
# diverge from the build matrix's canonical service set, or if
# `full_setup_services=(...)` gains a service that is not a real build-matrix
# service.
#
# The first 8 tests below (single-file invocation) write a small fixture
# workflow (only the lines this guard reads: a `- service:` matrix plus the
# array assignments) and point the script at it via its file argument, so
# the suite runs fully offline and does not depend on the real
# build-push.yml's current contents.
#
# The remaining tests cover the guard's extension (#822 pattern audit, beyond
# issue #935's original build-push.yml-only scope) to 3 more real files that
# duplicate the same service-list class: gc-pr-staging-images.yml,
# backfill-stack-latest.yml, and scripts/ensure-pr-staging-images.sh. These
# invoke the script with a matrix-source fixture PLUS additional fixture
# files, mirroring the script's own `[primary] [extra]...` argument shape.

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/check-workflow-service-lists.sh"
    fixture="$BATS_TEST_TMPDIR/build-push.yml"
    gc_fixture="$BATS_TEST_TMPDIR/gc-pr-staging-images.yml"
    backfill_fixture="$BATS_TEST_TMPDIR/backfill-stack-latest.yml"
    ensure_fixture="$BATS_TEST_TMPDIR/ensure-pr-staging-images.sh"
}

# Emits a matrix declaring all seven real services. The leading indentation
# matches the anchored `^\s+- service:` pattern the guard extracts from.
write_canonical_matrix() {
    cat <<'EOF'
jobs:
  build:
    strategy:
      matrix:
        include:
          - service: proxy
          - service: dns
          - service: watchdog
          - service: dhcp
          - service: dhcp-proxy
          - service: ui
          - service: build-tools
EOF
}

# The happy path: one matrix, four full `services=(...)` copies that all equal
# the canonical set, and a `full_setup_services=(...)` that is a proper subset.
# Proves the guard stays green on a correctly-synced workflow.
@test "passes when all services=() copies match the matrix and full_setup is a subset" {
    {
        write_canonical_matrix
        echo '          full_setup_services=(proxy dns watchdog ui build-tools)'
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)'
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)'
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)'
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)'
    } > "$fixture"

    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"consistent"* ]]
}

# The exact #822 recurrence shape: a new service was added to the matrix (and
# to three copies) but one `services=(...)` copy was missed. This is the
# silent-drop bug the guard exists to catch, so it must fail and name the
# drifted line.
@test "fails when one services=() copy is missing a service the matrix declares" {
    {
        write_canonical_matrix
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)'
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)'
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)'
        # One copy forgot the newly-added build-tools service.
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui)'
    } > "$fixture"

    run bash "$script" "$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"diverges"* ]]
}

# The inverse drift: a copy lists a service the matrix does not build. Must
# also fail, since it would try to merge/promote a non-existent image.
@test "fails when a services=() copy lists a service the matrix does not build" {
    {
        write_canonical_matrix
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools phantom)'
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)'
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)'
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)'
    } > "$fixture"

    run bash "$script" "$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"diverges"* ]]
}

# full_setup_services is allowed to be a strict subset (it deliberately omits
# dhcp/dhcp-proxy), so a subset must NOT trip the guard -- guarding against a
# naive "all lists identical" implementation that would false-positive here.
@test "passes when full_setup_services is a strict subset of the canonical set" {
    {
        write_canonical_matrix
        echo '          full_setup_services=(proxy dns watchdog)'
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)'
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)'
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)'
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)'
    } > "$fixture"

    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
}

# A typo'd/renamed service in full_setup_services (not present in the matrix)
# must fail: it would silently point full-setup validation at an image that
# never gets built.
@test "fails when full_setup_services contains a non-canonical service" {
    {
        write_canonical_matrix
        echo '          full_setup_services=(proxy dns watchdog ui build-tools typo)'
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)'
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)'
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)'
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)'
    } > "$fixture"

    run bash "$script" "$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a known build-matrix service"* ]]
}

# Defense against a self-defeating guard: if the `- service:` matrix cannot be
# parsed (empty canonical set), every equality check would pass vacuously, so
# the guard must instead fail closed and say why.
@test "fails closed when no matrix service entries can be extracted" {
    {
        echo 'jobs:'
        echo '  build:'
        echo '    steps: []'
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)'
    } > "$fixture"

    run bash "$script" "$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"vacuous"* ]]
}

# If the `services=(...)` arrays are renamed or refactored away entirely, the
# guard no longer protects anything; it must fail closed so the change is
# reviewed deliberately rather than silently leaving CI green.
@test "fails closed when no services=() arrays are present at all" {
    write_canonical_matrix > "$fixture"

    run bash "$script" "$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"renamed or refactored"* ]]
}

# Order independence: a copy that lists the same services in a different order
# is still correct and must pass, since the runtime loop order does not matter.
@test "treats service arrays as unordered sets" {
    {
        write_canonical_matrix
        echo '          services=(build-tools ui dhcp-proxy dhcp watchdog dns proxy)'
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)'
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)'
        echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)'
    } > "$fixture"

    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
}

# Writes correct, in-sync content for all 3 extended-scope fixtures, modeled
# on the real files: gc-pr-staging-images.yml equals the canonical set;
# backfill-stack-latest.yml deliberately excludes build-tools (a documented
# subset, matching its own "intentionally excludes build-tools" comment);
# ensure-pr-staging-images.sh declares full_setup_services=(...) at column 0
# (a plain shell script, not indented inside a YAML `run:` block).
write_good_extra_fixtures() {
    echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)' > "$gc_fixture"
    echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui)' > "$backfill_fixture"
    echo 'full_setup_services=(proxy dns watchdog ui build-tools)' > "$ensure_fixture"
}

# The matrix-source file itself always requires at least one of its own
# services=(...) copies too (matching real build-push.yml, which has 4) --
# these multi-file tests are about the 3 extra files, so this writes just
# one correct copy to keep that requirement trivially satisfied without
# distracting from what each test actually exercises.
write_matrix_source_with_services() {
    write_canonical_matrix
    echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)'
}

# The happy path for the extended multi-file invocation: matrix-source fixture
# plus 3 correctly-synced extra fixtures must pass as a whole.
@test "multi-file: passes when all 3 extended-scope files are in sync" {
    write_matrix_source_with_services > "$fixture"
    write_good_extra_fixtures

    run bash "$script" "$fixture" "$gc_fixture" "$backfill_fixture" "$ensure_fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"consistent"* ]]
}

# The exact #822 recurrence shape, now in gc-pr-staging-images.yml specifically:
# a service silently missing from its (must-equal-canonical) services=(...)
# copy must fail and name the file.
@test "multi-file: fails when gc-pr-staging-images.yml's services=() diverges from canonical" {
    write_matrix_source_with_services > "$fixture"
    write_good_extra_fixtures
    echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui)' > "$gc_fixture"

    run bash "$script" "$fixture" "$gc_fixture" "$backfill_fixture" "$ensure_fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"diverges"* ]]
    [[ "$output" == *"$gc_fixture"* ]]
}

# backfill-stack-latest.yml's services=(...) is a DELIBERATE subset (it
# excludes build-tools on purpose, per its own inline comment) -- this must
# NOT be flagged as a divergence, guarding against a naive
# "every services=() must equal canonical" implementation being wrongly
# applied to this file too.
@test "multi-file: backfill-stack-latest.yml's documented build-tools exclusion does not false-positive" {
    write_matrix_source_with_services > "$fixture"
    write_good_extra_fixtures
    # write_good_extra_fixtures already omits build-tools here; this test
    # exists to make that specific non-failure an explicit, named assertion
    # rather than an implicit side effect of the happy-path test above.

    run bash "$script" "$fixture" "$gc_fixture" "$backfill_fixture" "$ensure_fixture"
    [ "$status" -eq 0 ]
}

# backfill-stack-latest.yml's services=(...) must equal EXACTLY
# canonical-minus-{build-tools}, not just "no phantom members" -- a phantom
# member (a service the matrix doesn't build at all) must still fail.
@test "multi-file: fails when backfill-stack-latest.yml's services=() contains a non-canonical service" {
    write_matrix_source_with_services > "$fixture"
    write_good_extra_fixtures
    echo '          services=(proxy dns watchdog dhcp dhcp-proxy ui phantom)' > "$backfill_fixture"

    run bash "$script" "$fixture" "$gc_fixture" "$backfill_fixture" "$ensure_fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"diverges from the expected set"* ]]
    [[ "$output" == *"$backfill_fixture"* ]]
}

# The actual #822 failure mode for a subset-checked file: a real service
# silently DROPPED (here, watchdog -- missing on top of the documented
# build-tools exclusion) must fail. A membership-only "no phantom members"
# check would wrongly pass this, since a shorter list is still a valid
# subset by that weaker definition -- this is exactly the gap an exact
# canonical-minus-exclusions equality check exists to close.
@test "multi-file: fails when backfill-stack-latest.yml's services=() silently drops a real service" {
    write_matrix_source_with_services > "$fixture"
    write_good_extra_fixtures
    echo '          services=(proxy dns dhcp dhcp-proxy ui)' > "$backfill_fixture"

    run bash "$script" "$fixture" "$gc_fixture" "$backfill_fixture" "$ensure_fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"diverges from the expected set"* ]]
    [[ "$output" == *"$backfill_fixture"* ]]
}

# ensure-pr-staging-images.sh declares full_setup_services=(...) at column 0
# (no leading whitespace, unlike every YAML-embedded copy) -- this is the
# concrete regex trap this extension had to account for
# (`^[[:space:]]*` vs `^[[:space:]]+`). A typo'd member here must still be
# caught, proving the column-0 array is actually being parsed, not silently
# skipped by an anchor that only matches indented copies.
@test "multi-file: fails when ensure-pr-staging-images.sh's column-0 full_setup_services=() contains a typo" {
    write_matrix_source_with_services > "$fixture"
    write_good_extra_fixtures
    echo 'full_setup_services=(proxy dns watchdog ui build-tools typo)' > "$ensure_fixture"

    run bash "$script" "$fixture" "$gc_fixture" "$backfill_fixture" "$ensure_fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"diverges from the expected set"* ]]
    [[ "$output" == *"$ensure_fixture"* ]]
}

# Same silent-drop failure mode as backfill-stack-latest.yml above, but for
# ensure-pr-staging-images.sh's full_setup_services=(...): dropping a real
# service (here, ui -- beyond the documented dhcp/dhcp-proxy exclusion) must
# fail. This is the specific gap that scoping this file into
# FULL_SETUP_EXACT_EXCLUSIONS (exact-equality) rather than leaving it on the
# original membership-only check exists to close.
@test "multi-file: fails when ensure-pr-staging-images.sh's full_setup_services=() silently drops a real service" {
    write_matrix_source_with_services > "$fixture"
    write_good_extra_fixtures
    echo 'full_setup_services=(proxy dns watchdog build-tools)' > "$ensure_fixture"

    run bash "$script" "$fixture" "$gc_fixture" "$backfill_fixture" "$ensure_fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"diverges from the expected set"* ]]
    [[ "$output" == *"$ensure_fixture"* ]]
}

# gc-pr-staging-images.yml and backfill-stack-latest.yml are both "required"
# services=(...) files (see REQUIRES_SERVICES_ARRAY in the script): if the
# array vanishes entirely (renamed, refactored away), the guard must fail
# closed instead of silently no-op'ing on that file.
@test "multi-file: fails closed when gc-pr-staging-images.yml's services=() array is gone entirely" {
    write_matrix_source_with_services > "$fixture"
    write_good_extra_fixtures
    echo '# no services array here anymore' > "$gc_fixture"

    run bash "$script" "$fixture" "$gc_fixture" "$backfill_fixture" "$ensure_fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no 'services=(...)' array found"* ]]
    [[ "$output" == *"$gc_fixture"* ]]
}

# ensure-pr-staging-images.sh is the one "required" full_setup_services=(...)
# file among the 3 extras (see REQUIRES_FULL_SETUP_ARRAY): losing that array
# entirely must also fail closed, the same class of guard as the services=()
# case above but for the other array kind.
@test "multi-file: fails closed when ensure-pr-staging-images.sh's full_setup_services=() array is gone entirely" {
    write_matrix_source_with_services > "$fixture"
    write_good_extra_fixtures
    echo '# no full_setup_services array here anymore' > "$ensure_fixture"

    run bash "$script" "$fixture" "$gc_fixture" "$backfill_fixture" "$ensure_fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no 'full_setup_services=(...)' array found"* ]]
    [[ "$output" == *"$ensure_fixture"* ]]
}

# If one of the extended-scope files itself disappears (moved, renamed,
# deleted) the guard must fail closed and say which file, rather than
# silently skipping it and reporting overall success.
@test "multi-file: fails closed when an extended-scope file argument does not exist" {
    write_matrix_source_with_services > "$fixture"
    write_good_extra_fixtures
    rm -f "$backfill_fixture"

    run bash "$script" "$fixture" "$gc_fixture" "$backfill_fixture" "$ensure_fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"expected file not found"* ]]
    [[ "$output" == *"$backfill_fixture"* ]]
}

# Defense-in-depth: proves the guard's default zero-argument production
# invocation -- the exact way build-push.yml's CI step calls it, covering
# the real build-push.yml plus the real gc-pr-staging-images.yml,
# backfill-stack-latest.yml, and scripts/ensure-pr-staging-images.sh -- is
# actually green today. Without this, a real drift in any of the 3 extended
# files could sit undetected by this suite (which otherwise only exercises
# synthetic fixtures) until CI's own build-push.yml step caught it.
@test "the guard also passes when pointed at the real repository tree (default zero-arg invocation)" {
    repo_root="$BATS_TEST_DIRNAME/../.."
    run bash -c "cd '$repo_root' && bash '$script'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"consistent"* ]]
}
