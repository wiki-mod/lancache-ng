#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Fixture tests for restore_path_is_sed_safe(), the guard cmd_restore uses
# before rewriting the archived install path to the current one inside a
# restored .env/.env.local with `sed`. Both paths are operator-controlled
# filesystem locations, and the rewrite uses an `s#...#...#` command, so a
# `#` in either path breaks the command's delimiter and a `&` or `\` on the
# replacement side is a sed metacharacter that would corrupt the written
# value. cmd_restore now validates both paths through this function and fails
# closed, instead of silently leaving .env pointing at the old archived path
# (the original bug: the sed had no `|| die` and no character validation).
# These tests exercise the guard directly against string inputs rather than
# through the full tar/rsync/compose-stop machinery of cmd_restore itself.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-restore-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-restore-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-restore-helpers.sh"
    load_setup_restore_helpers "$repo_root" "$helper_file"
}

# The common case: a plain absolute install path must be accepted, or the
# guard would false-positive and break every legitimate restore.
@test "accepts a normal absolute install path" {
    run restore_path_is_sed_safe "/opt/lancache-ng"
    [ "$status" -eq 0 ]
}

# `.`, `-`, and spaces are legal in real install paths and cannot corrupt the
# sed command, so they must be accepted -- guarding against an over-strict
# allowlist that would reject valid operator directories.
@test "accepts paths containing dots, dashes, and spaces" {
    run restore_path_is_sed_safe "/opt/lancache.ng-2"
    [ "$status" -eq 0 ]
    run restore_path_is_sed_safe "/srv/lan cache/ng"
    [ "$status" -eq 0 ]
}

# `#` is the delimiter of the `s#...#...#` rewrite; a path containing it would
# terminate the command early and mangle the substitution, so it must be
# rejected.
@test "rejects a path containing the sed delimiter '#'" {
    run restore_path_is_sed_safe "/opt/lancache#ng"
    [ "$status" -ne 0 ]
}

# `&` on the replacement side expands to the whole matched text in sed; an
# install path containing it would corrupt the value written into .env, so it
# must be rejected.
@test "rejects a path containing the sed replacement metacharacter '&'" {
    run restore_path_is_sed_safe "/opt/lan&cache"
    [ "$status" -ne 0 ]
}

# `\` is sed's escape character; a path containing it could form an unintended
# escape sequence in the replacement, so it must be rejected.
@test "rejects a path containing a backslash" {
    run restore_path_is_sed_safe '/opt/lan\cache'
    [ "$status" -ne 0 ]
}

# A newline embedded in a path (pathological, but possible via a crafted
# backup metadata value) would split the sed script; the guard must reject it
# so the rewrite can never run on a multi-line path.
@test "rejects a path containing a newline" {
    run restore_path_is_sed_safe "$(printf '/opt/lan\ncache')"
    [ "$status" -ne 0 ]
}
