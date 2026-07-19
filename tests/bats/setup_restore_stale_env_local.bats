#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Fixture tests for restore_clear_stale_env_local_if_unarchived(), the helper
# cmd_restore calls right after rsync-ing the archived install tree back into
# place. cmd_restore's rsync deliberately runs without --delete (a backup
# that predates the .env.local split, or a plain .env-only deploy/prod
# backup, must not have unrelated target-specific files nuked by a broad
# --delete), which means a .env.local already sitting at the restore target
# is left completely untouched whenever the archive itself has none.
# runtime_env_file_for_install_dir() prefers .env.local over .env whenever it
# exists, so without this helper every subsequent compose/update/debug call
# would keep reading the stale pre-restore override instead of the just-
# restored .env -- rollback would not actually roll back the active runtime
# config in that scenario. These tests exercise the helper directly against
# fixture directories rather than through the full tar/rsync/compose-stop
# machinery of cmd_restore itself.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-restore-helpers.sh"
    archived_root="$BATS_TEST_TMPDIR/archived"
    install_dir="$BATS_TEST_TMPDIR/install"
    mkdir -p "$archived_root" "$install_dir"

    # shellcheck source=tests/bats/helpers/setup-restore-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-restore-helpers.sh"
    load_setup_restore_helpers "$repo_root" "$helper_file"
}

@test "moves a stale .env.local aside when the archive has none" {
    printf 'IP_STANDARD=192.0.2.10\n' > "$install_dir/.env.local"

    run restore_clear_stale_env_local_if_unarchived "$archived_root" "$install_dir"
    [ "$status" -eq 0 ]

    [ ! -f "$install_dir/.env.local" ]
    # The stale file must be preserved (renamed), never deleted outright.
    stale_count=$(find "$install_dir" -maxdepth 1 -name '.env.local.pre-restore-*' | wc -l)
    [ "$stale_count" -eq 1 ]
}

@test "leaves .env.local alone when the archive also has one (rsync already restored it)" {
    printf 'IP_STANDARD=192.0.2.20\n' > "$archived_root/.env.local"
    printf 'IP_STANDARD=192.0.2.20\n' > "$install_dir/.env.local"

    run restore_clear_stale_env_local_if_unarchived "$archived_root" "$install_dir"
    [ "$status" -eq 0 ]

    [ -f "$install_dir/.env.local" ]
    grep -qx 'IP_STANDARD=192.0.2.20' "$install_dir/.env.local"
    stale_count=$(find "$install_dir" -maxdepth 1 -name '.env.local.pre-restore-*' | wc -l)
    [ "$stale_count" -eq 0 ]
}

@test "is a no-op when there is no .env.local at the restore target at all" {
    run restore_clear_stale_env_local_if_unarchived "$archived_root" "$install_dir"
    [ "$status" -eq 0 ]

    [ ! -f "$install_dir/.env.local" ]
    stale_count=$(find "$install_dir" -maxdepth 1 -name '.env.local.pre-restore-*' | wc -l)
    [ "$stale_count" -eq 0 ]
}

@test "is idempotent: a second call after the first finds nothing left to move" {
    printf 'IP_STANDARD=192.0.2.10\n' > "$install_dir/.env.local"

    run restore_clear_stale_env_local_if_unarchived "$archived_root" "$install_dir"
    [ "$status" -eq 0 ]
    first_run_stale_count=$(find "$install_dir" -maxdepth 1 -name '.env.local.pre-restore-*' | wc -l)
    [ "$first_run_stale_count" -eq 1 ]

    run restore_clear_stale_env_local_if_unarchived "$archived_root" "$install_dir"
    [ "$status" -eq 0 ]
    second_run_stale_count=$(find "$install_dir" -maxdepth 1 -name '.env.local.pre-restore-*' | wc -l)
    # No new stale file was created; the one from the first run is untouched.
    [ "$second_run_stale_count" -eq 1 ]
}
