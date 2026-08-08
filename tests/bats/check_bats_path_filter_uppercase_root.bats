#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/check-bats-path-filter-coverage.sh"
    fixture_root="$BATS_TEST_TMPDIR/fixture-repo"
    mkdir -p "$fixture_root/tests/bats" "$fixture_root/.github/workflows" "$fixture_root/scripts"
    printf '#!/usr/bin/env bash\n' > "$fixture_root/scripts/runtime-helper.sh"
}

write_workflow() {
    local path="$1"
    cat > "$fixture_root/.github/workflows/build-tools-smoke.yml" <<EOF
on:
  push:
    paths:
      - "$path"
  pull_request:
    paths:
      - "$path"
EOF
}

@test "uppercase REPO_ROOT dependency is enforced by the path-filter guard" {
    cat > "$fixture_root/tests/bats/runtime.bats" <<'EOF'
setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "reads the runtime helper" {
    [ -f "$REPO_ROOT/scripts/runtime-helper.sh" ]
}
EOF

    write_workflow "setup.sh"
    run bash "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"scripts/runtime-helper.sh"* ]]

    write_workflow "scripts/runtime-helper.sh"
    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}
