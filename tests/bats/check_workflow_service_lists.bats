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
# Each test writes a small fixture workflow (only the lines this guard reads:
# a `- service:` matrix plus the array assignments) and points the script at
# it via its optional file argument, so the suite runs fully offline and does
# not depend on the real build-push.yml's current contents.

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/check-workflow-service-lists.sh"
    fixture="$BATS_TEST_TMPDIR/build-push.yml"
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
