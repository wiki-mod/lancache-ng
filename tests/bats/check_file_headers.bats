#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Regression coverage for scripts/untracked/check-file-headers.sh. Fixtures exercise the
# exact physical line contract, native comment syntax, duplicate/legacy-header
# rejection, and the pre-existing exclusion/path behavior. Whole-repository
# mode is also exercised now that the backfill is complete and hard-enforced.

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/untracked/check-file-headers.sh"
    fixture_dir="$BATS_TEST_TMPDIR/fx"
    mkdir -p "$fixture_dir"
}

@test "explicit-file mode passes a shell file with shebang on line 1" {
    printf '#!/usr/bin/env bash\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n# SPDX-License-Identifier: AGPL-3.0-or-later\necho hi\n' > "$fixture_dir/example.sh"
    run bash "$script" "$fixture_dir/example.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"canonical repository header"* ]]
}

@test "explicit-file mode passes a no-shebang file with blank line 1" {
    printf '\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n# SPDX-License-Identifier: AGPL-3.0-or-later\nkey: value\n' > "$fixture_dir/example.yml"
    run bash "$script" "$fixture_dir/example.yml"
    [ "$status" -eq 0 ]
}

@test "explicit-file mode rejects a no-shebang file that omits blank line 1" {
    printf '# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n# SPDX-License-Identifier: AGPL-3.0-or-later\nkey: value\n' > "$fixture_dir/example.yml"
    run bash "$script" "$fixture_dir/example.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"line 2 must be exactly"* ]]
}

@test "explicit-file mode rejects a missing project header" {
    printf '#!/usr/bin/env bash\n# not-the-project-header\n# SPDX-License-Identifier: AGPL-3.0-or-later\necho hi\n' > "$fixture_dir/example.sh"
    run bash "$script" "$fixture_dir/example.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"line 2 must be exactly"* ]]
}

@test "explicit-file mode rejects a missing SPDX identifier" {
    printf '#!/usr/bin/env bash\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n# not-the-spdx-line\necho hi\n' > "$fixture_dir/example.sh"
    run bash "$script" "$fixture_dir/example.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"line 3 must be exactly"* ]]
}

@test "explicit-file mode rejects the legacy lowercase project header" {
    printf '#!/usr/bin/env bash\n# lancache-ng (https://github.com/wiki-mod/lancache-ng)\n# SPDX-License-Identifier: AGPL-3.0-or-later\necho hi\n' > "$fixture_dir/example.sh"
    run bash "$script" "$fixture_dir/example.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"legacy lowercase lancache-ng header is not allowed"* ]]
}

@test "explicit-file mode rejects swapped project and SPDX lines" {
    printf '#!/usr/bin/env bash\n# SPDX-License-Identifier: AGPL-3.0-or-later\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\necho hi\n' > "$fixture_dir/example.sh"
    run bash "$script" "$fixture_dir/example.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"line 2 must be exactly"* ]]
    [[ "$output" == *"line 3 must be exactly"* ]]
}

@test "explicit-file mode rejects a duplicate canonical project header" {
    printf '#!/usr/bin/env bash\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n# SPDX-License-Identifier: AGPL-3.0-or-later\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\necho hi\n' > "$fixture_dir/example.sh"
    run bash "$script" "$fixture_dir/example.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"project header must appear exactly once"* ]]
}

@test "explicit-file mode rejects a duplicate SPDX identifier" {
    printf '#!/usr/bin/env bash\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n# SPDX-License-Identifier: AGPL-3.0-or-later\n# SPDX-License-Identifier: AGPL-3.0-or-later\necho hi\n' > "$fixture_dir/example.sh"
    run bash "$script" "$fixture_dir/example.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"SPDX identifier must appear exactly once"* ]]
}

@test "explicit-file mode rejects SPDX text embedded in executable JavaScript" {
    printf '\n// LanCache-NG (https://github.com/wiki-mod/lancache-ng)\nconst license = "SPDX-License-Identifier: AGPL-3.0-or-later";\n' > "$fixture_dir/example.js"
    run bash "$script" "$fixture_dir/example.js"
    [ "$status" -eq 1 ]
    [[ "$output" == *"line 3 must be exactly"* ]]
}

@test "explicit-file mode accepts complete standalone Tera header comments" {
    tera_dir="$fixture_dir/services/ui/src/templates"
    mkdir -p "$tera_dir"
    # Keep Tera's percent-delimited tag in data arguments, never in printf's
    # format string, so fixture creation cannot reinterpret template syntax.
    printf '%s\n' \
        '' \
        '{# LanCache-NG (https://github.com/wiki-mod/lancache-ng) #}' \
        '{# SPDX-License-Identifier: AGPL-3.0-or-later #}' \
        '{# Dashboard template purpose text. #}' \
        '{% extends "base.html" %}' > "$tera_dir/dashboard.html"
    run bash "$script" "$tera_dir/dashboard.html"
    [ "$status" -eq 0 ]
}

@test "explicit-file mode rejects the legacy multi-line Tera header shape" {
    tera_dir="$fixture_dir/services/ui/src/templates"
    mkdir -p "$tera_dir"
    printf '%s\n' \
        '' \
        '{# LanCache-NG (https://github.com/wiki-mod/lancache-ng)' \
        'SPDX-License-Identifier: AGPL-3.0-or-later #}' \
        '{% extends "base.html" %}' > "$tera_dir/dashboard.html"
    run bash "$script" "$tera_dir/dashboard.html"
    [ "$status" -eq 1 ]
    [[ "$output" == *"line 2 must be exactly"* ]]
}

@test "explicit-file mode rejects a real blank line before the Rust inner-doc header" {
    printf '\n//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n//! SPDX-License-Identifier: AGPL-3.0-or-later\nfn main() {}\n' > "$fixture_dir/example.rs"
    run bash "$script" "$fixture_dir/example.rs"
    [ "$status" -eq 1 ]
}

@test "explicit-file mode accepts Lua header syntax" {
    printf '\n-- LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n-- SPDX-License-Identifier: AGPL-3.0-or-later\nreturn true\n' > "$fixture_dir/example.lua"
    run bash "$script" "$fixture_dir/example.lua"
    [ "$status" -eq 0 ]
}

@test "explicit-file mode accepts JavaScript header syntax" {
    printf '\n// LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n// SPDX-License-Identifier: AGPL-3.0-or-later\nexport const ok = true;\n' > "$fixture_dir/example.js"
    run bash "$script" "$fixture_dir/example.js"
    [ "$status" -eq 0 ]
}

@test "explicit-file mode accepts CSS header syntax" {
    printf '\n/* LanCache-NG (https://github.com/wiki-mod/lancache-ng) */\n/* SPDX-License-Identifier: AGPL-3.0-or-later */\nbody {}\n' > "$fixture_dir/example.css"
    run bash "$script" "$fixture_dir/example.css"
    [ "$status" -eq 0 ]
}

@test "explicit-file mode accepts a Docker parser directive on line 1" {
    printf '# syntax=docker/dockerfile:1\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n# SPDX-License-Identifier: AGPL-3.0-or-later\nFROM scratch\n' > "$fixture_dir/Dockerfile"
    run bash "$script" "$fixture_dir/Dockerfile"
    [ "$status" -eq 0 ]
}

@test "explicit-file mode accepts Docker parser-directive case and whitespace variants" {
    # Docker documents directive keys as case-insensitive and permits
    # non-line-breaking whitespace around the key/value separator.
    printf '#  SyNtAx = docker/dockerfile:1\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n# SPDX-License-Identifier: AGPL-3.0-or-later\nFROM scratch\n' > "$fixture_dir/Dockerfile"
    run bash "$script" "$fixture_dir/Dockerfile"
    [ "$status" -eq 0 ]
}

@test "explicit-file mode rejects a second Docker parser directive occupying line 2" {
    printf '# syntax=docker/dockerfile:1\n# escape=`\n# SPDX-License-Identifier: AGPL-3.0-or-later\nFROM scratch\n' > "$fixture_dir/Dockerfile"
    run bash "$script" "$fixture_dir/Dockerfile"
    [ "$status" -eq 1 ]
    [[ "$output" == *"line 2 must be exactly"* ]]
}

@test "explicit-file mode respects the exclusion list for Markdown" {
    printf '# hello\n' > "$fixture_dir/example.md"
    run bash "$script" "$fixture_dir/example.md"
    [ "$status" -eq 0 ]
}

@test "explicit-file mode normalizes a caller-relative path before applying exclusions" {
    # The real Kea fixture is JSON despite its .conf extension. Invoking from
    # its own directory proves the repository-relative exclusion survives a
    # caller-relative path spelling instead of trying to add comments to JSON.
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    run bash -c "cd '$repo_root/services/dhcp' && bash '$script' 'kea-dhcp4.conf'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"canonical repository header"* ]]
}

@test "explicit-file mode treats an option-like root filename as a path" {
    fixture_file="$fixture_dir/-valid.sh"
    printf '#!/usr/bin/env bash\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n# SPDX-License-Identifier: AGPL-3.0-or-later\necho hi\n' > "$fixture_file"
    run bash -c "cd '$fixture_dir' && bash '$script' '-valid.sh'"
    [ "$status" -eq 0 ]
}

@test "explicit-file mode fails closed for an unrecognized non-excluded file type" {
    printf '\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n# SPDX-License-Identifier: AGPL-3.0-or-later\nopaque data\n' > "$fixture_dir/example.unknown"
    run bash "$script" "$fixture_dir/example.unknown"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no native header comment syntax is defined"* ]]
}

@test "whole-repo mode hard-enforces the completed backfill" {
    run bash "$script"
    [ "$status" -eq 0 ]
    [[ "$output" == *"All checked files carry the canonical repository header"* ]]
}

@test "explicit-file mode accepts the formatter-stable Rust line-1 placeholder" {
    printf '//!\n//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n//! SPDX-License-Identifier: AGPL-3.0-or-later\nfn main() {}\n' > "$fixture_dir/example.rs"
    run bash "$script" "$fixture_dir/example.rs"
    [ "$status" -eq 0 ]
}
