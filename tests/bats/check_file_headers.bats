#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for scripts/check-file-headers.sh's explicit-file mode:
# AG-HDR-008's SPDX-License-Identifier line is hard-enforced when
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

@test "explicit-file mode fails when the SPDX line is present but not immediately after the shebang" {
    # AG-HDR-008 requires the SPDX line "immediately after the shebang line
    # (if there is one) and before the lancache-ng (...) header line" -- a
    # file with both required lines present, but in the wrong order (header
    # line first), does not actually satisfy that positional requirement
    # even though a plain substring-presence scan across the window would
    # wrongly call it clean.
    printf '#!/usr/bin/env bash\n# lancache-ng (https://github.com/wiki-mod/lancache-ng)\n# SPDX-License-Identifier: AGPL-3.0-or-later\necho hi\n' > "$fixture_dir/example.sh"
    run bash "$script" "$fixture_dir/example.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"SPDX-License-Identifier"* ]]
}

@test "explicit-file mode accepts the SPDX line at line 1 when the file has no shebang" {
    printf '# SPDX-License-Identifier: AGPL-3.0-or-later\n# lancache-ng (https://github.com/wiki-mod/lancache-ng)\nkey: value\n' > "$fixture_dir/example.yml"
    run bash "$script" "$fixture_dir/example.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"All checked files"* ]]
}

@test "explicit-file mode rejects SPDX text embedded in executable content" {
    printf 'const license = "SPDX-License-Identifier: AGPL-3.0-or-later";\n// lancache-ng (https://github.com/wiki-mod/lancache-ng)\n' > "$fixture_dir/example.js"
    run bash "$script" "$fixture_dir/example.js"
    [ "$status" -eq 1 ]
    [[ "$output" == *"SPDX-License-Identifier"* ]]
}

@test "explicit-file mode normalizes a caller-relative path before applying the exclusion list" {
    # services/dhcp/kea-dhcp4.conf is a real tracked file, excluded by exact
    # repo-relative literal (JSON despite the .conf extension -- a header
    # would corrupt its syntax). Invoked here from inside services/dhcp
    # itself, so the path this script actually receives is the bare
    # "kea-dhcp4.conf" -- a spelling that does not match the exclusion
    # list's repo-relative literal at all unless normalized first. Without
    # normalization, this hard-fails the JSON file for a "missing"
    # header/SPDX line it must never carry.
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    run bash -c "cd '$repo_root/services/dhcp' && bash '$script' 'kea-dhcp4.conf'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"All checked files"* ]]
}

@test "explicit-file mode treats an option-like root filename as a path" {
    fixture_file="$fixture_dir/-valid.sh"
    printf '#!/usr/bin/env bash\n# SPDX-License-Identifier: AGPL-3.0-or-later\n# lancache-ng (https://github.com/wiki-mod/lancache-ng)\necho hi\n' > "$fixture_file"
    run bash -c "cd '$fixture_dir' && bash '$script' '-valid.sh'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"All checked files"* ]]
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
