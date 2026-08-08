#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for scripts/check-file-headers.sh's explicit-file mode (issue
# #1510): AG-HDR-008's SPDX-License-Identifier line is hard-enforced when
# the script is given explicit file paths (CI's diff-scoped invocation, or
# a developer checking one file before committing), while a whole-repo scan
# (no arguments) stays soft/informational since the repo-wide backfill is
# not complete. Each test operates on an isolated fixture file under
# BATS_TEST_TMPDIR and invokes the real script with an explicit path to it,
# so no test here ever touches this repository's own tracked files.

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/check-file-headers.sh"
    fixture_dir="$BATS_TEST_TMPDIR/fx"
    mkdir -p "$fixture_dir"
}

@test "explicit-file mode fails on a file with the project header but no SPDX line" {
    printf '#!/usr/bin/env bash\n# lancache-ng (https://github.com/wiki-mod/lancache-ng)\necho hi\n' > "$fixture_dir/example.sh"
    run bash "$script" "$fixture_dir/example.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"SPDX-License-Identifier"* ]]
    [[ "$output" == *"$fixture_dir/example.sh"* ]]
}

@test "explicit-file mode passes on a file with both the header and the SPDX line" {
    printf '#!/usr/bin/env bash\n# SPDX-License-Identifier: AGPL-3.0-or-later\n# lancache-ng (https://github.com/wiki-mod/lancache-ng)\necho hi\n' > "$fixture_dir/example.sh"
    run bash "$script" "$fixture_dir/example.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"All checked files"* ]]
}

@test "explicit-file mode still hard-fails on the missing project header itself (pre-existing behavior)" {
    printf '#!/usr/bin/env bash\necho hi\n' > "$fixture_dir/example.sh"
    run bash "$script" "$fixture_dir/example.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Missing the required repository header"* ]]
}

@test "explicit-file mode respects the exclusion list (a .md file needs neither line)" {
    printf '# hello\n' > "$fixture_dir/example.md"
    run bash "$script" "$fixture_dir/example.md"
    [ "$status" -eq 0 ]
}

@test "whole-repo mode (no arguments) stays soft on missing SPDX lines in the real repository" {
    # Runs the real script against the real repo root (no fixture involved):
    # asserts the pre-existing invariant that a whole-repo scan never
    # hard-fails on AG-HDR-008 alone, which the new explicit-file hard-fail
    # branch above must not have broken.
    run bash "$script"
    [ "$status" -eq 0 ]
    [[ "$output" == *"All checked files"* ]]
}
