#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Regression tests for setup.sh's sync_dhcp_proxy_config_prod_env(). A
# manual deploy/prod install's dhcp-proxy container reads
# config/prod/dhcp-proxy.env directly via `env_file:` in
# deploy/prod/docker-compose.yml -- not .env/.env.local at all, unlike
# deploy/quickstart's dhcp-proxy service, which wires each value through
# `environment: - KEY=${KEY:-}`. migrate_env_for_update() only ever
# resolves these values against .env/.env.local, so a naive unconditional
# write into config/prod/dhcp-proxy.env would silently overwrite a real,
# already-configured value there with an empty .env-resolved duplicate.
#
# config/prod/dhcp-proxy.env is permanently authoritative because it is the
# file deploy/prod actually consumes. A migrated .env contains every key, so
# its mere key presence cannot identify a later deliberate operator change.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-dhcp-proxy-config-prod-sync-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-dhcp-proxy-config-prod-sync-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-dhcp-proxy-config-prod-sync-helpers.sh"
    load_setup_dhcp_proxy_config_prod_sync_helpers "$repo_root" "$helper_file"

    scratch_repo="$BATS_TEST_TMPDIR/scratch-repo"
    mkdir -p "$scratch_repo/deploy/prod" "$scratch_repo/config/prod"
    install_dir="$scratch_repo/deploy/prod"
    config_prod_env="$scratch_repo/config/prod/dhcp-proxy.env"
    # A source .env/.env.local that never mentions any of these keys at all --
    # the "operator never used the documented .env path this run" case.
    source_env_file="$BATS_TEST_TMPDIR/dot-env-no-pxe-keys"
    printf 'SOME_UNRELATED_KEY=1\n' > "$source_env_file"
}

@test "config/prod's existing value is preserved when the source .env never had the key at all" {
    cat > "$config_prod_env" <<'EOF'
DHCP_PROXY_PXE_BOOT_SERVER=10.9.9.9
DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=real-pxelinux.0
DHCP_PROXY_PXE_BOOT_FILENAME_UEFI=
EOF

    sync_dhcp_proxy_config_prod_env "$install_dir" "$source_env_file" "" "" "" "" "" "" "" "" "" "" "" "" "" ""

    run get_env_var DHCP_PROXY_PXE_BOOT_SERVER "$config_prod_env"
    [ "$output" = "10.9.9.9" ]
    run get_env_var DHCP_PROXY_PXE_BOOT_FILENAME_BIOS "$config_prod_env"
    [ "$output" = "real-pxelinux.0" ]
}

@test "a key neither file has set yet converges from the resolved fallback value" {
    cat > "$config_prod_env" <<'EOF'
DHCP_PROXY_PXE_BOOT_SERVER=
EOF

    sync_dhcp_proxy_config_prod_env "$install_dir" "$source_env_file" "" "" "" "" "" "" "" "" "" "fallback-uefi.efi" "" "" "" ""

    run get_env_var DHCP_PROXY_PXE_BOOT_FILENAME_UEFI "$config_prod_env"
    [ "$output" = "fallback-uefi.efi" ]
}

@test "an explicit config/prod value survives a duplicate clear in the migrated source .env" {
    cat > "$config_prod_env" <<'EOF'
DHCP_PROXY_PXE_BOOT_SERVER=10.9.9.9
EOF
    # The duplicate in .env is empty, but config/prod remains authoritative.
    source_env_with_clear="$BATS_TEST_TMPDIR/dot-env-explicit-clear"
    printf 'DHCP_PROXY_PXE_BOOT_SERVER=\n' > "$source_env_with_clear"

    sync_dhcp_proxy_config_prod_env "$install_dir" "$source_env_with_clear" "" "" "" "" "" "" "" "" "" "" "" "" "" ""

    run get_env_var DHCP_PROXY_PXE_BOOT_SERVER "$config_prod_env"
    [ "$output" = "10.9.9.9" ]
}

@test "a later direct config/prod edit survives a stale migrated source .env value" {
    cat > "$config_prod_env" <<'EOF'
DHCP_PROXY_PXE_BOOT_SERVER=10.9.9.9
EOF
    source_env_with_new_value="$BATS_TEST_TMPDIR/dot-env-new-value"
    printf 'DHCP_PROXY_PXE_BOOT_SERVER=10.5.5.5\n' > "$source_env_with_new_value"

    sync_dhcp_proxy_config_prod_env "$install_dir" "$source_env_with_new_value" "" "" "" "" "" "" "" "10.5.5.5" "" "" "" "" "" ""

    run get_env_var DHCP_PROXY_PXE_BOOT_SERVER "$config_prod_env"
    [ "$output" = "10.9.9.9" ]
}

@test "a non-deploy/prod install_dir with no provisioned config/prod is a true no-op" {
    quickstart_dir="$BATS_TEST_TMPDIR/opt-lancache-ng"
    mkdir -p "$quickstart_dir"

    # Issue #1095: a no-clone install_dir now resolves config/prod under
    # itself (config_prod_dir_for_install_dir()), not two levels up -- this
    # fixture never provisions it, so the file-existence guard still no-ops.
    run sync_dhcp_proxy_config_prod_env "$quickstart_dir" "$source_env_file" "" "" "" "" "" "" "" "10.1.1.1" "" "" "" "" "" ""
    [ "$status" -eq 0 ]
    [ ! -e "$quickstart_dir/config" ]
    [ ! -e "$quickstart_dir/../config" ]
}

@test "a missing config/prod/dhcp-proxy.env file (e.g. an unusual checkout) is a no-op, not a hard failure" {
    rm -f "$config_prod_env"

    run sync_dhcp_proxy_config_prod_env "$install_dir" "$source_env_file" "" "" "" "" "" "" "" "10.1.1.1" "" "" "" "" "" ""
    [ "$status" -eq 0 ]
    [ ! -e "$config_prod_env" ]
}

@test "migrate_env_for_update() calls sync_dhcp_proxy_config_prod_env() after every ensure_secret_env_key call, not before" {
    # Structural regression test, not a functional one: the real bug this
    # guards was migrate_env_for_update() writing config/prod/dhcp-proxy.env
    # -- a container's live, directly-consumed config -- BEFORE several
    # ensure_secret_env_key calls that can still `die` (e.g. an openssl
    # failure generating a secret). An aborted update must not leave that
    # one write applied while $env_file itself stays at its pre-update
    # state. A full functional simulation would need to fake an
    # ensure_secret_env_key failure inside the real 1000+-line
    # migrate_env_for_update(); a plain line-order check on the real
    # function body is cheap and catches the same regression (the call
    # moving back above any secret-generation step) just as reliably.
    func_body_file="$BATS_TEST_TMPDIR/migrate_env_for_update_body.txt"
    awk '/^migrate_env_for_update\(\) \{/,/^}/' "$repo_root/setup.sh" > "$func_body_file"
    [ -s "$func_body_file" ] || { echo "Could not locate migrate_env_for_update() in setup.sh -- has it been renamed or restructured? Update this guard's extraction pattern to match." >&2; return 1; }

    sync_line=$(grep -n '^\s*sync_dhcp_proxy_config_prod_env ' "$func_body_file" | head -1 | cut -d: -f1)
    [ -n "$sync_line" ] || { echo "sync_dhcp_proxy_config_prod_env is no longer called from migrate_env_for_update() at all -- update this guard if that call moved elsewhere." >&2; return 1; }

    last_secret_line=$(grep -n '^\s*ensure_secret_env_key ' "$func_body_file" | tail -1 | cut -d: -f1)
    [ -n "$last_secret_line" ] || { echo "No ensure_secret_env_key call found in migrate_env_for_update() -- update this guard's extraction if that helper was renamed." >&2; return 1; }

    [ "$sync_line" -gt "$last_secret_line" ]
}
