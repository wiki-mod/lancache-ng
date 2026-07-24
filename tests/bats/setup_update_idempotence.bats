#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Repeat-run idempotence fixture tests for migrate_env_for_update(), the real
# function `setup.sh update` calls to converge an install's .env before
# pulling images and restarting containers.
#
# AG-OP-011 ("Re-running `setup.sh update` after a successful update should
# report no destructive changes and should not rewrite stable local files
# unnecessarily") and AG-OP-006 (no secret rotation on repeat runs) are
# currently documented in AGENTS.md with "Manual review" as their only listed
# verification method (see the AG-OP-006/AG-OP-007/AG-OP-011 rows in the
# compliance table). setup_env_migration.bats already covers several
# individual helper functions migrate_env_for_update() calls
# (append_env_migrated_assignment_if_missing, migrate_proxy_security_mode_for_update,
# image-tag resolution) in isolation, and scripts/setup-cli-simulation.sh
# exercises the real `setup.sh update` CLI end-to-end through Docker -- but
# neither ever calls the update-migration path a second time in a row to
# prove it lands on a stable fixed point. This file closes that gap: it
# drives migrate_env_for_update() itself (not a re-implementation of it)
# against realistic fixtures and asserts a second run changes nothing.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    env_file="$BATS_TEST_TMPDIR/.env"
    helper_file="$BATS_TEST_TMPDIR/setup-update-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-update-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-update-helpers.sh"
    load_setup_update_helpers "$repo_root" "$helper_file"
}

# A fresh, fully-converged install's .env: every key migrate_env_for_update()
# expects already present with a valid, non-placeholder value, and a pinned
# (non-network) image tag so resolve_lancache_image_tag() never needs to
# `docker pull` a channel pointer image. Includes DHCP_PROXY_INTERFACE/
# DHCP_PROXY_ROUTER/DHCP_NTP_SERVERS/DHCP_PROXY_DOMAIN/
# DHCP_PROXY_BOOT_FILENAME/DHCP_PROXY_BOOT_SERVER/DHCP_PROXY_CUSTOM_OPTIONS
# (#450), NATS_DNS_REPLICA_USER/NATS_DNS_REPLICA_PASSWORD/
# NATS_CALLOUT_USER/NATS_CALLOUT_PASSWORD (#583), AUTO_UPDATE_ENABLED
# (#819), and NTP_ENABLED (#1082, LanCache-NG-NTP): migrate_env_for_update()
# backfills all of these unconditionally when missing, so a fixture predating
# any of these features would no longer be "fully converged" and would make
# the no-op test below fail on its first run, not just its second --
# confirmed the hard way when #819's own PR broke this exact test on first CI
# run, and again by #1082's NTP feature (issue #1171), which is exactly the
# failure mode this comment exists to warn the next feature about.
#
# NTP_DATA_DIR is deliberately NOT listed here even though
# migrate_env_for_update() also sets it: it goes through
# set_optional_env_path_override_if_needed(), which is a no-op (writes
# nothing) whenever the key is absent and the desired path already equals the
# derived default -- exactly this fixture's case, since there is no legacy
# NTP state directory to migrate from. The same reasoning is why this fixture
# also omits KEA_DATA_DIR, PDNS_STANDARD_DIR/PDNS_SSL_DIR/
# PDNS_FILTER_STATE_DIR, NATS_DATA_DIR, and NATS_CONF_DIR: all go through the
# same helper and stay silent under these exact defaults.
#
# This exact "new key added to migrate_env_for_update() but never backfilled
# here" failure class has now recurred three times (#819 AUTO_UPDATE_ENABLED,
# #1082/#1171 NTP_ENABLED, #844/PR #1117 DHCP_RELAY_LOCAL_ADDR). Per AG-WF-025,
# a third recurrence requires a structural fix, not just fixing the instance
# again: the "migrate_env_for_update()'s unconditionally-written .env keys are
# all present in write_converged_env_fixture()" guard test below extracts both
# key sets from the real source (setup.sh and this file, never a
# hand-maintained duplicate list) and fails with the specific missing key
# name(s) before the no-op test below ever gets a chance to fail with a bare
# hash mismatch. Keep this comment as the human-readable explanation; the
# guard test is the mechanical enforcement.
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
        'DHCP_PROXY_INTERFACE=' \
        'DHCP_PROXY_ROUTER=' \
        'DHCP_NTP_SERVERS=' \
        'DHCP_PROXY_DOMAIN=' \
        'DHCP_PROXY_BOOT_FILENAME=' \
        'DHCP_PROXY_BOOT_SERVER=' \
        'DHCP_PROXY_CUSTOM_OPTIONS=' \
        'KEA_CTRL_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
        'DDNS_TSIG_KEY=YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYQ==' \
        'PDNS_API_KEY=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
        'NATS_UI_USER=lancache-ui' \
        'NATS_UI_PASSWORD=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
        'NATS_DNS_WRITER_USER=lancache-dns-writer' \
        'NATS_DNS_WRITER_PASSWORD=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' \
        'NATS_DNS_REPLICA_USER=lancache-dns-replica' \
        'NATS_DNS_REPLICA_PASSWORD=gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg' \
        'NATS_CALLOUT_USER=lancache-nats-callout' \
        'NATS_CALLOUT_PASSWORD=hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh' \
        'SECONDARY_REGISTRATION_TOKEN=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' \
        'COMPOSE_PROFILES=ssl' \
        'UI_AUTH_USER=admin' \
        'UI_AUTH_PASSWORD=RealAdminPassword123' \
        'ALLOW_INSECURE_UI=false' \
        'AUTO_UPDATE_ENABLED=0' \
        'NTP_ENABLED=0' \
        > "$env_file"
}

# A pre-#456-style old install: split cache keys, a legacy strict security
# mode with no allowlist, missing DHCP/NATS/secret keys entirely, and no
# image-channel keys at all -- the shape migrate_env_for_update() must
# converge on its first call. ui_auth_user defaults to empty (insecure UI,
# the common legacy case); pass a value to instead exercise the conditional
# "generate a password because a username was configured" branch.
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
    # Mechanical guard for the recurring failure class documented in the
    # comment above write_converged_env_fixture(): a new .env key gets added
    # to migrate_env_for_update() via one of its "write unconditionally if
    # missing" helpers, but write_converged_env_fixture() never gets updated
    # to include it, so the no-op test below fails with a bare hash mismatch
    # instead of naming the actual missing key (#819, #1082/#1171,
    # #844/PR #1117). Both key sets are extracted here from the real source --
    # never a hand-maintained duplicate list, which could itself drift -- and
    # this test runs before the no-op test in this file (bats runs @test
    # blocks in file order) so a fourth recurrence gets an immediately
    # diagnostic message instead of a bare hash mismatch.
    local setup_sh="$repo_root/setup.sh"
    local this_file="$BATS_TEST_DIRNAME/setup_update_idempotence.bats"
    local func_body_file="$BATS_TEST_TMPDIR/migrate_func_body.txt"
    local fixture_body_file="$BATS_TEST_TMPDIR/fixture_func_body.txt"
    local required_file="$BATS_TEST_TMPDIR/required_keys.txt"
    local excluded_file="$BATS_TEST_TMPDIR/excluded_keys.txt"
    local fixture_keys_file="$BATS_TEST_TMPDIR/fixture_keys.txt"
    local missing_file="$BATS_TEST_TMPDIR/missing_keys.txt"

    # Isolate each function's own body -- from its definition line to its
    # closing brace at column 0 -- so extraction below cannot pick up
    # unrelated keys from other functions in these large files.
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

    # append_env_key_if_missing / set_env_key_if_empty_or_missing / plain
    # set_env_key / ensure_secret_env_key / append_env_migrated_assignment_if_missing
    # all write their key argument unconditionally: the first, second, and
    # fifth whenever it is missing, ensure_secret_env_key whenever it is
    # missing or a known placeholder, and plain set_env_key on every call
    # regardless of prior state. All five are exactly the "must already exist
    # in a fully converged fixture" contract that #819/#1082/#844 broke.
    {
        grep -oE 'append_env_key_if_missing +[A-Za-z_][A-Za-z0-9_]*' "$func_body_file" | awk '{print $2}'
        grep -oE 'set_env_key_if_empty_or_missing +[A-Za-z_][A-Za-z0-9_]*' "$func_body_file" | awk '{print $2}'
        grep -oE '(^|[^_a-zA-Z])set_env_key +[A-Za-z_][A-Za-z0-9_]*' "$func_body_file" | awk '{print $NF}'
        grep -oE 'ensure_secret_env_key +[A-Za-z_][A-Za-z0-9_]*' "$func_body_file" | awk '{print $2}'
        grep -oE 'append_env_migrated_assignment_if_missing +[A-Za-z_][A-Za-z0-9_]*' "$func_body_file" | awk '{print $2}'
    } | sort -u > "$required_file"

    # set_optional_env_path_override_if_needed is deliberately excluded: it is
    # a documented no-op whenever the fixture's desired path already equals
    # the derived default, which is exactly this fixture's case for every key
    # it manages (NTP_DATA_DIR, KEA_DATA_DIR, the PDNS_* dirs, NATS_DATA_DIR,
    # NATS_CONF_DIR -- see the comment above write_converged_env_fixture).
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

    # The fixture is deliberately already fully converged, so even the first
    # run must not touch it.
    [ "$original_hash" = "$first_run_hash" ]

    run migrate_env_for_update "$(dirname "$env_file")"
    [ "$status" -eq 0 ]
    second_run_hash=$(sha256sum "$env_file" | awk '{print $1}')

    [ "$first_run_hash" = "$second_run_hash" ]
}

@test "migrate_env_for_update on a legacy .env converges once and is stable on the second run" {
    write_legacy_env_fixture

    # First run performs the actual migration (split cache keys collapse,
    # strict-without-allowlist reverts to lazy, missing secrets/DHCP keys are
    # filled in).
    run migrate_env_for_update "$(dirname "$env_file")"
    [ "$status" -eq 0 ]

    run ! grep -q '^CACHE_DIR_STANDARD=' "$env_file"
    run ! grep -q '^CACHE_DIR_SSL=' "$env_file"
    grep -qx 'CACHE_DIR=/srv/lancache/cache' "$env_file"
    grep -qx 'PROXY_SECURITY_MODE=lazy' "$env_file"

    after_first_run=$(cat "$env_file")
    secrets_after_first_run=$(grep -E '^(KEA_CTRL_TOKEN|DDNS_TSIG_KEY|PDNS_API_KEY|NATS_UI_PASSWORD|NATS_DNS_WRITER_PASSWORD|NATS_DNS_REPLICA_PASSWORD|NATS_CALLOUT_PASSWORD|SECONDARY_REGISTRATION_TOKEN)=' "$env_file" | sort)

    # Second run against the now-converged file must not change anything --
    # in particular it must not rotate any of the secrets it just generated.
    run migrate_env_for_update "$(dirname "$env_file")"
    [ "$status" -eq 0 ]

    after_second_run=$(cat "$env_file")
    secrets_after_second_run=$(grep -E '^(KEA_CTRL_TOKEN|DDNS_TSIG_KEY|PDNS_API_KEY|NATS_UI_PASSWORD|NATS_DNS_WRITER_PASSWORD|NATS_DNS_REPLICA_PASSWORD|NATS_CALLOUT_PASSWORD|SECONDARY_REGISTRATION_TOKEN)=' "$env_file" | sort)

    [ "$after_first_run" = "$after_second_run" ]
    [ "$secrets_after_first_run" = "$secrets_after_second_run" ]
}

@test "migrate_env_for_update generates a UI password once and does not rotate it on the second run" {
    # Exercises the one *conditional* secret-generation branch neither fixture
    # above hits on its own: UI_AUTH_USER configured but UI_AUTH_PASSWORD
    # still empty. This is exactly the shape a rotation bug would take, since
    # (unlike ensure_secret_env_key's placeholder-based secrets) this branch
    # is gated on env_key_has_usable_secret rather than always running.
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
