#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Fixture tests for nats_secondary_override_active_for_install_dir() and
# compose_file_args_for_install_dir(), the two helpers `setup.sh update` uses
# to decide whether to keep passing deploy/prod/docker-compose.nats-
# secondary.yml on every subsequent update. Before this fix, cmd_update's
# `docker compose ... pull` / `... up -d` never passed that override at all,
# so an operator who had enabled it manually (per the override file's own
# header comment) would silently lose the NATS host port publish on the next
# `setup.sh update`, disconnecting remote secondary DNS nodes.
#
# The second test group (compose_file_args_for_install_dir) exists because
# nats_secondary_override_active_for_install_dir() alone cannot catch the
# regression this fix is actually guarding against: Docker Compose disables
# its cwd auto-discovery of docker-compose.yml as soon as ANY -f flag is
# given, so a call site that appended only the override file (instead of the
# base file plus the override) would run the stack from the override's
# partial `services: nats: ports:` fragment alone. A boolean-only test would
# pass even with that bug present; asserting on the actual -f argument list
# is what catches it.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    env_file="$BATS_TEST_TMPDIR/.env"
    install_dir="$BATS_TEST_TMPDIR/install"
    helper_file="$BATS_TEST_TMPDIR/setup-update-helpers.sh"
    mkdir -p "$install_dir"

    # shellcheck source=tests/bats/helpers/setup-update-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-update-helpers.sh"
    load_setup_update_helpers "$repo_root" "$helper_file"
}

@test "nats_secondary_override_active_for_install_dir is false when the override file does not exist" {
    printf 'NATS_BIND_IP=192.0.2.5\n' > "$env_file"
    # Deliberately no docker-compose.nats-secondary.yml under install_dir.

    run nats_secondary_override_active_for_install_dir "$install_dir" "$env_file"
    [ "$status" -ne 0 ]
}

@test "nats_secondary_override_active_for_install_dir is false when NATS_BIND_IP is unset" {
    : > "$install_dir/docker-compose.nats-secondary.yml"
    printf 'IP_STANDARD=192.0.2.10\n' > "$env_file"

    run nats_secondary_override_active_for_install_dir "$install_dir" "$env_file"
    [ "$status" -ne 0 ]
}

@test "nats_secondary_override_active_for_install_dir is false when NATS_BIND_IP is present but empty" {
    : > "$install_dir/docker-compose.nats-secondary.yml"
    printf 'NATS_BIND_IP=\n' > "$env_file"

    run nats_secondary_override_active_for_install_dir "$install_dir" "$env_file"
    [ "$status" -ne 0 ]
}

@test "nats_secondary_override_active_for_install_dir is true when the override file exists and NATS_BIND_IP is set" {
    : > "$install_dir/docker-compose.nats-secondary.yml"
    printf 'NATS_BIND_IP=192.0.2.5\n' > "$env_file"

    run nats_secondary_override_active_for_install_dir "$install_dir" "$env_file"
    [ "$status" -eq 0 ]
}

@test "compose_file_args_for_install_dir returns only the base file when the override is inactive" {
    printf 'IP_STANDARD=192.0.2.10\n' > "$env_file"

    run compose_file_args_for_install_dir "$install_dir" "$env_file"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "-f" ]
    [ "${lines[1]}" = "$install_dir/docker-compose.yml" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "compose_file_args_for_install_dir keeps the base file first and appends the override when active" {
    : > "$install_dir/docker-compose.nats-secondary.yml"
    printf 'NATS_BIND_IP=192.0.2.5\n' > "$env_file"

    run compose_file_args_for_install_dir "$install_dir" "$env_file"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 4 ]
    # The base file must come first: Compose drops its own cwd
    # auto-discovery of docker-compose.yml the moment any -f is passed, so an
    # arg list with only the override would run the stack from that
    # partial-services fragment alone.
    [ "${lines[0]}" = "-f" ]
    [ "${lines[1]}" = "$install_dir/docker-compose.yml" ]
    [ "${lines[2]}" = "-f" ]
    [ "${lines[3]}" = "$install_dir/docker-compose.nats-secondary.yml" ]
}

@test "nats_secondary_override_active_for_install_dir is true when NATS_BIND_IP is only set in the shell environment" {
    : > "$install_dir/docker-compose.nats-secondary.yml"
    # Deliberately no NATS_BIND_IP in the env file: the override file's own
    # header comment documents this shell-exported form as the PRIMARY
    # activation example, and Compose's own interpolation precedence puts a
    # shell variable ahead of an --env-file value.
    printf 'IP_STANDARD=192.0.2.10\n' > "$env_file"

    NATS_BIND_IP=192.0.2.5 run nats_secondary_override_active_for_install_dir "$install_dir" "$env_file"
    [ "$status" -eq 0 ]
}

# Regression test for compose_file_args_for_install_dir auto-detecting a
# docker-compose.override.yml: before this fix, the helper always passed -f
# explicitly for the base file, which (per Compose's documented behavior)
# disables Compose's own cwd auto-discovery/merge of a sibling override file
# -- silently dropping any operator customization on every `setup.sh update`,
# even when the NATS-secondary override was never involved.
@test "compose_file_args_for_install_dir auto-includes a docker-compose.override.yml sitting next to the base file" {
    printf 'IP_STANDARD=192.0.2.10\n' > "$env_file"
    : > "$install_dir/docker-compose.override.yml"

    run compose_file_args_for_install_dir "$install_dir" "$env_file"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 4 ]
    [ "${lines[0]}" = "-f" ]
    [ "${lines[1]}" = "$install_dir/docker-compose.yml" ]
    [ "${lines[2]}" = "-f" ]
    [ "${lines[3]}" = "$install_dir/docker-compose.override.yml" ]
}

@test "compose_file_args_for_install_dir auto-includes a docker-compose.override.yaml sitting next to the base file" {
    printf 'IP_STANDARD=192.0.2.10\n' > "$env_file"
    : > "$install_dir/docker-compose.override.yaml"

    run compose_file_args_for_install_dir "$install_dir" "$env_file"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 4 ]
    [ "${lines[2]}" = "-f" ]
    [ "${lines[3]}" = "$install_dir/docker-compose.override.yaml" ]
}

@test "compose_file_args_for_install_dir includes the operator override and the NATS-secondary override together" {
    : > "$install_dir/docker-compose.override.yml"
    : > "$install_dir/docker-compose.nats-secondary.yml"
    printf 'NATS_BIND_IP=192.0.2.5\n' > "$env_file"

    run compose_file_args_for_install_dir "$install_dir" "$env_file"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 6 ]
    [ "${lines[0]}" = "-f" ]
    [ "${lines[1]}" = "$install_dir/docker-compose.yml" ]
    [ "${lines[2]}" = "-f" ]
    [ "${lines[3]}" = "$install_dir/docker-compose.override.yml" ]
    [ "${lines[4]}" = "-f" ]
    [ "${lines[5]}" = "$install_dir/docker-compose.nats-secondary.yml" ]
}
