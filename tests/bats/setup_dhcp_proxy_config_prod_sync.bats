#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
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
# These tests prove sync_dhcp_proxy_config_prod_env() instead treats
# config/prod/dhcp-proxy.env's own existing value as authoritative and
# only uses the .env-resolved fallback to converge a key neither file has
# set yet.

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
}

@test "an existing non-empty config/prod value is preserved, not overwritten by an empty .env-resolved fallback" {
    cat > "$config_prod_env" <<'EOF'
DHCP_PROXY_PXE_BOOT_SERVER=10.9.9.9
DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=real-pxelinux.0
DHCP_PROXY_PXE_BOOT_FILENAME_UEFI=
EOF

    sync_dhcp_proxy_config_prod_env "$install_dir" "" "" "" "" "" "" "" "" "" ""

    run get_env_var DHCP_PROXY_PXE_BOOT_SERVER "$config_prod_env"
    [ "$output" = "10.9.9.9" ]
    run get_env_var DHCP_PROXY_PXE_BOOT_FILENAME_BIOS "$config_prod_env"
    [ "$output" = "real-pxelinux.0" ]
}

@test "a key config/prod has not set yet converges from the .env-resolved fallback value" {
    cat > "$config_prod_env" <<'EOF'
DHCP_PROXY_PXE_BOOT_SERVER=
DHCP_PROXY_PXE_BOOT_FILENAME_UEFI=
EOF

    sync_dhcp_proxy_config_prod_env "$install_dir" "" "" "" "" "" "" "" "" "" "fallback-uefi.efi"

    run get_env_var DHCP_PROXY_PXE_BOOT_FILENAME_UEFI "$config_prod_env"
    [ "$output" = "fallback-uefi.efi" ]
}

@test "a non-deploy/prod install_dir is a true no-op (quickstart has no config/prod/dhcp-proxy.env to sync)" {
    quickstart_dir="$BATS_TEST_TMPDIR/opt-lancache-ng"
    mkdir -p "$quickstart_dir"

    run sync_dhcp_proxy_config_prod_env "$quickstart_dir" "" "" "" "" "" "" "" "10.1.1.1" "" ""
    [ "$status" -eq 0 ]
    [ ! -e "$quickstart_dir/../config" ]
}

@test "a missing config/prod/dhcp-proxy.env file (e.g. an unusual checkout) is a no-op, not a hard failure" {
    rm -f "$config_prod_env"

    run sync_dhcp_proxy_config_prod_env "$install_dir" "" "" "" "" "" "" "" "10.1.1.1" "" ""
    [ "$status" -eq 0 ]
    [ ! -e "$config_prod_env" ]
}
