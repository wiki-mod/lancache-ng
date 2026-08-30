#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: repeat-run idempotence tests for migrate_env_for_upd
# Why: AG-OP-011/AG-OP-006 (no rewrite/no secret rotation on
#   only had "Manual review" as verification; no suite called the update-
#   migration path twice in a row to prove a stable fixed point.
# From: PR #1546

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    env_file="$BATS_TEST_TMPDIR/.env"
    helper_file="$BATS_TEST_TMPDIR/setup-update-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-update-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-update-helpers.sh"
    load_setup_update_helpers "$repo_root" "$helper_file"
}

# What: a fresh, fully-converged install's .env, every backf
# Why: a missing key would fail no-op test on its first run,
#   its second; recurred three times as new keys were added -- the guard
#   test below mechanically keeps this fixture in sync (AG-WF-025).
# From: PR #1546
write_converged_env_fixture() {
    printf '%s\n' \
        'IP_STANDARD=192.0.2.10' \
        'IP_SSL=192.0.2.11' \
        'SSL_ENABLED=1' \
        'UI_SESSION_TTL_SECONDS=86400' \
        'LANCACHE_STATE_DIR=/opt/lancache-ng/state' \
        'CACHE_DIR=/opt/lancache-ng/cache' \
        'CACHE_MAX_SIZE=50g' \
        'CACHE_MAX_GB=50' \
        'CACHE_MEM_MB=512' \
        'CACHE_SLICE_SIZE=8m' \
        'CACHE_VALID_HIT=365d' \
        'CACHE_VALID_ANY=1m' \
        'CACHE_INACTIVE=365d' \
        'PROXY_ALLOWED_CLIENT_CIDRS=' \
        'PROXY_SECURITY_MODE=lazy' \
        'NGINX_UPSTREAM_RESOLVER=8.8.8.8 8.8.4.4' \
        'LANCACHE_IMAGE_REGISTRY=ghcr.io' \
        'LANCACHE_IMAGE_PREFIX=wiki-mod/lancache-ng' \
        'LANCACHE_IMAGE_CHANNEL=pinned' \
        'LANCACHE_IMAGE_TAG=v0.2.0' \
        'UI_BIND_IP=192.0.2.10' \
        'DHCP_ENABLED=0' \
        'DHCP_MODE=disabled' \
        'DHCP_SUBNET=' \
        'DHCP_GATEWAY=' \
        'DHCP_RANGE_START=' \
        'DHCP_RANGE_END=' \
        'DHCP_SUBNET_START=' \
        'DHCP_DNS_PRIMARY=192.0.2.10' \
        'DHCP_DNS_SECONDARY=192.0.2.11' \
        'UPSTREAM_DHCP_IP=' \
        'DHCP_RELAY_LOCAL_ADDR=' \
        'DHCP_PROXY_INTERFACE=' \
        'DHCP_PROXY_ROUTER=' \
        'DHCP_NTP_SERVERS=' \
        'DHCP_PROXY_DOMAIN=' \
        'DHCP_PROXY_BOOT_FILENAME=' \
        'DHCP_PROXY_BOOT_SERVER=' \
        'DHCP_PROXY_CUSTOM_OPTIONS=' \
        'DHCP_PROXY_PXE_BOOT_SERVER=' \
        'DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=' \
        'DHCP_PROXY_PXE_BOOT_FILENAME_UEFI=' \
        'KEA_CTRL_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
        'DDNS_TSIG_KEY=YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYQ==' \
        'PDNS_API_KEY=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
        'NETDATA_ALARM_TOKEN=jjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjj' \
        'NATS_UI_USER=lancache-ui' \
        'NATS_UI_PASSWORD=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
        'NATS_DNS_WRITER_USER=lancache-dns-writer' \
        'NATS_DNS_WRITER_PASSWORD=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' \
        'NATS_DNS_REPLICA_USER=lancache-dns-replica' \
        'NATS_DNS_REPLICA_PASSWORD=gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg' \
        'NATS_CALLOUT_USER=lancache-nats-callout' \
        'NATS_CALLOUT_PASSWORD=hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh' \
        'NATS_SYS_USER=lancache-nats-sys' \
        'NATS_SYS_PASSWORD=iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii' \
        'SECONDARY_REGISTRATION_TOKEN=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' \
        'COMPOSE_PROFILES=ssl,logging' \
        'UI_AUTH_USER=admin' \
        'UI_AUTH_PASSWORD=RealAdminPassword123' \
        'ALLOW_INSECURE_UI=false' \
        'AUTO_UPDATE_ENABLED=0' \
        'NTP_ENABLED=0' \
        'LOGGING_ENABLED=1' \
        > "$env_file"
}

# What: an old install .env -- split cache keys, strict mode
# Why: ui_auth_user defaults to empty (insecure UI, common l
#   case); pass a value to exercise the "generate a password" branch.
# From: PR #1546
write_legacy_env_fixture() {
    local ui_auth_user="${1:-}"
    printf '%s\n' \
        'IP_STANDARD=192.0.2.20' \
        'IP_SSL=' \
        'CACHE_DIR_STANDARD=/srv/lancache/cache' \
        'CACHE_DIR_SSL=/srv/lancache/cache' \
        'PROXY_SECURITY_MODE=strict' \
        'PROXY_ALLOWED_CLIENT_CIDRS=' \
        'LANCACHE_IMAGE_TAG=v0.2.0' \
        "UI_AUTH_USER=${ui_auth_user}" \
        'UI_AUTH_PASSWORD=' \
        > "$env_file"
}

@test "migrate_env_for_update()'s unconditionally-written .env keys are all present in write_converged_env_fixture()" {
    # What: extracts both key sets from real source, names a
    # Why: bats runs @test blocks in file order, so this run
    #   no-op test below and gives a diagnostic instead of a bare hash
    #   mismatch on the next recurrence of this failure class.
    # From: PR #1546
    local setup_sh="$repo_root/setup.sh"
    local this_file="$BATS_TEST_DIRNAME/setup_update_idempotence.bats"
    local func_body_file="$BATS_TEST_TMPDIR/migrate_func_body.txt"
    local fixture_body_file="$BATS_TEST_TMPDIR/fixture_func_body.txt"
    local required_file="$BATS_TEST_TMPDIR/required_keys.txt"
    local excluded_file="$BATS_TEST_TMPDIR/excluded_keys.txt"
    local fixture_keys_file="$BATS_TEST_TMPDIR/fixture_keys.txt"
    local missing_file="$BATS_TEST_TMPDIR/missing_keys.txt"

    # What: isolates each function's own body (def line to c
    # Why: prevents extraction from picking up an unrelated
    #   keys from these large files.
    # From: PR #1546
    awk '/^migrate_env_for_update\(\) \{/,/^}/' "$setup_sh" > "$func_body_file"
    if [ ! -s "$func_body_file" ]; then
        echo "Could not locate migrate_env_for_update() in $setup_sh -- has it been renamed or restructured? Update this guard's extraction pattern to match." >&2
        return 1
    fi

    awk '/^write_converged_env_fixture\(\) \{/,/^}/' "$this_file" > "$fixture_body_file"
    if [ ! -s "$fixture_body_file" ]; then
        echo "Could not locate write_converged_env_fixture() in $this_file -- has it been renamed or restructured? Update this guard's extraction pattern to match." >&2
        return 1
    fi

    # What: collects keys written by five "write uncondition
    # Why: each is a "must already exist in a fully converge
    # From: PR #1546
    {
        grep -oE 'append_env_key_if_missing +[A-Za-z_][A-Za-z0-9_]*' "$func_body_file" | awk '{print $2}'
        grep -oE 'set_env_key_if_empty_or_missing +[A-Za-z_][A-Za-z0-9_]*' "$func_body_file" | awk '{print $2}'
        grep -oE '(^|[^_a-zA-Z])set_env_key +[A-Za-z_][A-Za-z0-9_]*' "$func_body_file" | awk '{print $NF}'
        grep -oE 'ensure_secret_env_key +[A-Za-z_][A-Za-z0-9_]*' "$func_body_file" | awk '{print $2}'
        grep -oE 'append_env_migrated_assignment_if_missing +[A-Za-z_][A-Za-z0-9_]*' "$func_body_file" | awk '{print $2}'
    } | sort -u > "$required_file"

    # What: excludes set_optional_env_path_override_if_neede
    # Why: a documented no-op whenever fixture's desired pat
    #   equals the derived default -- true here for every key it manages.
    # From: PR #1546
    grep -oE 'set_optional_env_path_override_if_needed +[A-Za-z_][A-Za-z0-9_]*' "$func_body_file" \
        | awk '{print $2}' | sort -u > "$excluded_file"

    grep -oE "^[[:space:]]*'[A-Za-z_][A-Za-z0-9_]*=" "$fixture_body_file" \
        | grep -oE '[A-Za-z_][A-Za-z0-9_]*' | sort -u > "$fixture_keys_file"

    comm -23 "$required_file" "$excluded_file" | comm -23 - "$fixture_keys_file" > "$missing_file"

    if [ -s "$missing_file" ]; then
        {
            echo "migrate_env_for_update() writes these .env key(s) unconditionally, but write_converged_env_fixture() does not pre-populate them:"
            cat "$missing_file"
            echo "Add each missing key to write_converged_env_fixture() in $this_file with a valid, non-placeholder value, mirroring the existing entries there."
            echo "See #819 (AUTO_UPDATE_ENABLED), #1082/#1171 (NTP_ENABLED), and #844/PR #1117 (DHCP_RELAY_LOCAL_ADDR) for the three prior occurrences of this exact failure class."
        } >&2
        return 1
    fi
}

@test "migrate_env_for_update on an already-converged .env is a true no-op on the second run" {
    write_converged_env_fixture
    original_hash=$(sha256sum "$env_file" | awk '{print $1}')

    run migrate_env_for_update "$(dirname "$env_file")"
    [ "$status" -eq 0 ]
    first_run_hash=$(sha256sum "$env_file" | awk '{print $1}')

    # What: fixture is already converged; even first run mus
    # Why: proves write_converged_env_fixture() is a true no
    # From: PR #1546
    [ "$original_hash" = "$first_run_hash" ]

    run migrate_env_for_update "$(dirname "$env_file")"
    [ "$status" -eq 0 ]
    second_run_hash=$(sha256sum "$env_file" | awk '{print $1}')

    [ "$first_run_hash" = "$second_run_hash" ]
}

@test "migrate_env_for_update on a quickstart (non-deploy/prod) install runs cleanly under set -u" {
    # What: enables `set -u` explicitly for this test.
    # Why: other tests run without nounset; on this quicksta
    #   prodsync_default_* locals stay unset (their branch never runs) --
    #   only real nounset catches an unconditional expansion aborting.
    # From: PR #1546
    set -u
    write_converged_env_fixture

    run migrate_env_for_update "$(dirname "$env_file")"
    [ "$status" -eq 0 ]
}

@test "migrate_env_for_update on a legacy .env converges once and is stable on the second run" {
    write_legacy_env_fixture

    # What: first run performs actual migration (cache/secur
    # Why: establishes converged state second run must not d
    # From: PR #1546
    run migrate_env_for_update "$(dirname "$env_file")"
    [ "$status" -eq 0 ]

    run ! grep -q '^CACHE_DIR_STANDARD=' "$env_file"
    run ! grep -q '^CACHE_DIR_SSL=' "$env_file"
    grep -qx 'CACHE_DIR=/srv/lancache/cache' "$env_file"
    grep -qx 'PROXY_SECURITY_MODE=lazy' "$env_file"

    after_first_run=$(cat "$env_file")
    secrets_after_first_run=$(grep -E '^(KEA_CTRL_TOKEN|DDNS_TSIG_KEY|PDNS_API_KEY|NETDATA_ALARM_TOKEN|NATS_UI_PASSWORD|NATS_DNS_WRITER_PASSWORD|NATS_DNS_REPLICA_PASSWORD|NATS_CALLOUT_PASSWORD|NATS_SYS_PASSWORD|SECONDARY_REGISTRATION_TOKEN)=' "$env_file" | sort)

    # What: second run against the now-converged file.
    # Why: must not change anything, in particular must not
    # From: PR #1546
    run migrate_env_for_update "$(dirname "$env_file")"
    [ "$status" -eq 0 ]

    after_second_run=$(cat "$env_file")
    secrets_after_second_run=$(grep -E '^(KEA_CTRL_TOKEN|DDNS_TSIG_KEY|PDNS_API_KEY|NETDATA_ALARM_TOKEN|NATS_UI_PASSWORD|NATS_DNS_WRITER_PASSWORD|NATS_DNS_REPLICA_PASSWORD|NATS_CALLOUT_PASSWORD|NATS_SYS_PASSWORD|SECONDARY_REGISTRATION_TOKEN)=' "$env_file" | sort)

    [ "$after_first_run" = "$after_second_run" ]
    [ "$secrets_after_first_run" = "$secrets_after_second_run" ]
}

@test "migrate_env_for_update generates a UI password once and does not rotate it on the second run" {
    # What: the one conditional secret-generation branch, UI
    # Why: neither fixture hits it by default; this is shape
    #   bug would take, unlike ensure_secret_env_key's always-running path.
    # From: PR #1546
    write_legacy_env_fixture admin

    run migrate_env_for_update "$(dirname "$env_file")"
    [ "$status" -eq 0 ]

    grep -qx 'UI_AUTH_USER=admin' "$env_file"
    generated_password=$(grep '^UI_AUTH_PASSWORD=' "$env_file")
    [ -n "$generated_password" ]
    [ "$generated_password" != "UI_AUTH_PASSWORD=" ]

    run migrate_env_for_update "$(dirname "$env_file")"
    [ "$status" -eq 0 ]

    password_after_second_run=$(grep '^UI_AUTH_PASSWORD=' "$env_file")
    [ "$generated_password" = "$password_after_second_run" ]
}

@test "migrate_env_for_update never leaves duplicate assignments for any key after two runs" {
    write_legacy_env_fixture

    run migrate_env_for_update "$(dirname "$env_file")"
    [ "$status" -eq 0 ]
    run migrate_env_for_update "$(dirname "$env_file")"
    [ "$status" -eq 0 ]

    duplicate_keys=$(awk -F= '{print $1}' "$env_file" | sort | uniq -d)
    [ -z "$duplicate_keys" ]
}

@test "migrate_env_for_update on a deploy/prod install with no PXE keys in .env yet preserves an existing config/prod/dhcp-proxy.env PXE value across two runs (the confirmed real bug)" {
    # What: a deploy/prod install with PXE hand-edited only
    # Why: seeding backfill from $env_file's own prior state
    #   config/prod's real value) would defer the bug by one run, since run
    #   two's .env already carries run one's placeholder.
    # From: PR #1546
    prod_install_dir="$BATS_TEST_TMPDIR/scratch/deploy/prod"
    config_prod_dir="$BATS_TEST_TMPDIR/scratch/config/prod"
    mkdir -p "$prod_install_dir" "$config_prod_dir"
    config_prod_env="$config_prod_dir/dhcp-proxy.env"

    env_file="$prod_install_dir/.env"
    write_legacy_env_fixture

    cat > "$config_prod_env" <<'EOF'
DHCP_PROXY_PXE_BOOT_SERVER=10.9.9.9
DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=real-pxelinux.0
EOF

    run migrate_env_for_update "$prod_install_dir"
    [ "$status" -eq 0 ]

    # What: backfill converged to config/prod's real value,
    # Why: proves this test exercises real seeding path, not
    # From: PR #1546
    grep -qx 'DHCP_PROXY_PXE_BOOT_SERVER=10.9.9.9' "$env_file"
    grep -qx 'DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=real-pxelinux.0' "$env_file"

    run get_env_var DHCP_PROXY_PXE_BOOT_SERVER "$config_prod_env"
    [ "$output" = "10.9.9.9" ]
    run get_env_var DHCP_PROXY_PXE_BOOT_FILENAME_BIOS "$config_prod_env"
    [ "$output" = "real-pxelinux.0" ]

    # What: second run; .env already carries these keys from
    # Why: exactly state that would fool a fix relying on $e
    #   own prior existence instead of config/prod's real value.
    # From: PR #1546
    run migrate_env_for_update "$prod_install_dir"
    [ "$status" -eq 0 ]

    run get_env_var DHCP_PROXY_PXE_BOOT_SERVER "$config_prod_env"
    [ "$output" = "10.9.9.9" ]
    run get_env_var DHCP_PROXY_PXE_BOOT_FILENAME_BIOS "$config_prod_env"
    [ "$output" = "real-pxelinux.0" ]
}

@test "migrate_env_for_update preserves a direct config/prod edit made after the first migration" {
    prod_install_dir="$BATS_TEST_TMPDIR/scratch/deploy/prod"
    config_prod_dir="$BATS_TEST_TMPDIR/scratch/config/prod"
    mkdir -p "$prod_install_dir" "$config_prod_dir"
    config_prod_env="$config_prod_dir/dhcp-proxy.env"
    env_file="$prod_install_dir/.env"
    write_legacy_env_fixture

    cat > "$config_prod_env" <<'EOF'
DHCP_PROXY_PXE_BOOT_SERVER=10.0.0.1
DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=pxelinux.0
EOF

    run migrate_env_for_update "$prod_install_dir"
    [ "$status" -eq 0 ]
    grep -qx 'DHCP_PROXY_PXE_BOOT_SERVER=10.0.0.1' "$env_file"

    # What: operator edits config/prod directly after first
    # Why: the now-stale duplicate .env value must never ove
    # From: PR #1546
    set_env_key DHCP_PROXY_PXE_BOOT_SERVER "10.0.0.2" "$config_prod_env"
    run migrate_env_for_update "$prod_install_dir"
    [ "$status" -eq 0 ]

    run get_env_var DHCP_PROXY_PXE_BOOT_SERVER "$config_prod_env"
    [ "$output" = "10.0.0.2" ]
}

@test "migrate_env_for_update in dnsmasq-proxy mode does not die on an incomplete hand-edited PXE pair in config/prod/dhcp-proxy.env" {
    # What: a hand-edited PXE server value with no filename
    # Why: pxe_boot_pointer_answers_are_complete() requires
    #   together; confirms seeding this unvalidated cannot break an update.
    # From: PR #1546
    prod_install_dir="$BATS_TEST_TMPDIR/scratch/deploy/prod"
    config_prod_dir="$BATS_TEST_TMPDIR/scratch/config/prod"
    mkdir -p "$prod_install_dir" "$config_prod_dir"
    config_prod_env="$config_prod_dir/dhcp-proxy.env"

    env_file="$prod_install_dir/.env"
    write_legacy_env_fixture
    printf '%s\n' \
        'DHCP_MODE=dnsmasq-proxy' \
        'DHCP_SUBNET_START=192.0.2.0' \
        'DHCP_DNS_PRIMARY=192.0.2.20' \
        'UPSTREAM_DHCP_IP=192.0.2.1' \
        >> "$env_file"

    # What: incomplete on purpose -- a server with no filena
    # Why: exercises tolerated-incomplete-pair path, not a c
    # From: PR #1546
    cat > "$config_prod_env" <<'EOF'
DHCP_PROXY_PXE_BOOT_SERVER=10.9.9.9
EOF

    run migrate_env_for_update "$prod_install_dir"
    [ "$status" -eq 0 ]

    # What: the authoritative runtime file is not rewritten.
    # Why: entrypoint.sh retains its warning/no-directive be
    #   this hand-edited state.
    # From: PR #1546
    run get_env_var DHCP_PROXY_PXE_BOOT_SERVER "$config_prod_env"
    [ "$output" = "10.9.9.9" ]
}

@test "migrate_env_for_update in dnsmasq-proxy mode does not die on an invalid hand-edited value in config/prod/dhcp-proxy.env" {
    # What: a malformed IPv4 hand-edited into config/prod/dh
    # Why: a hand-edited file is never guaranteed to satisfy
    #   own stricter validation; must not abort a previously-working update.
    # From: PR #1546
    prod_install_dir="$BATS_TEST_TMPDIR/scratch/deploy/prod"
    config_prod_dir="$BATS_TEST_TMPDIR/scratch/config/prod"
    mkdir -p "$prod_install_dir" "$config_prod_dir"
    config_prod_env="$config_prod_dir/dhcp-proxy.env"

    env_file="$prod_install_dir/.env"
    write_legacy_env_fixture
    printf '%s\n' \
        'DHCP_MODE=dnsmasq-proxy' \
        'DHCP_SUBNET_START=192.0.2.0' \
        'DHCP_DNS_PRIMARY=192.0.2.20' \
        'UPSTREAM_DHCP_IP=192.0.2.1' \
        >> "$env_file"

    cat > "$config_prod_env" <<'EOF'
DHCP_PROXY_ROUTER=not-an-ip-address
EOF

    run migrate_env_for_update "$prod_install_dir"
    [ "$status" -eq 0 ]

    run get_env_var DHCP_PROXY_ROUTER "$config_prod_env"
    [ "$output" = "not-an-ip-address" ]
}
