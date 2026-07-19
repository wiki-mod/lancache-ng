#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for the six #669 backup/restore safety gaps fixed in this change,
# driving the real setup.sh functions (compose_project_name,
# compose_cache_volume_name, compose_volume_names, backup_compose_volumes,
# compose_stack_running, guard_restore_shared_project_volumes) rather than a
# re-implementation of them. Docker itself is mocked as a shell function per
# test (no real Docker daemon needed), since this file only needs to prove
# the gating/discovery/guard *logic* is correct, not that `docker run`/`docker
# volume` actually work.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-backup-restore-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-backup-restore-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-backup-restore-helpers.sh"
    load_setup_backup_restore_helpers "$repo_root" "$helper_file"

    compose_dir="$BATS_TEST_TMPDIR/install"
    mkdir -p "$compose_dir"
    cat > "$compose_dir/docker-compose.yml" <<'EOF'
name: lancache-ng

services:
  proxy:
    image: foo
EOF
}

teardown() {
    unset -f docker 2>/dev/null || true
    unset COMPOSE_PROJECT_NAME
}

@test "compose_project_name reads the name: key from docker-compose.yml" {
    run compose_project_name "$compose_dir" "$compose_dir/.env"
    [ "$status" -eq 0 ]
    [ "$output" = "lancache-ng" ]
}

@test "compose_project_name honors a COMPOSE_PROJECT_NAME environment override" {
    COMPOSE_PROJECT_NAME="operator-override" run compose_project_name "$compose_dir" "$compose_dir/.env"
    [ "$status" -eq 0 ]
    [ "$output" = "operator-override" ]
}

@test "compose_cache_volume_name derives the project-prefixed cache volume name" {
    run compose_cache_volume_name "$compose_dir" "$compose_dir/.env"
    [ "$status" -eq 0 ]
    [ "$output" = "lancache-ng_proxy-cache" ]
}

# #669 (1): backup_compose_volumes must skip the cache volume outside of
# --full mode, since the bind-backed prod proxy-cache volume can be hundreds
# of GB and config-mode backups (including the automatic pre-update rollback
# backup) are documented as excluding cache payloads.
@test "backup_compose_volumes excludes the cache volume in config mode" {
    compose_stack_available() { return 0; }
    compose_volume_names() { printf '%s\n' "lancache-ng_proxy-cache" "lancache-ng_nats-data"; }
    docker() {
        if [ "$1" = "run" ]; then
            shift $(($#-1))
            printf '%s\n' "$1" >> "$BATS_TEST_TMPDIR/archived.log"
        fi
    }

    run backup_compose_volumes "$compose_dir" "$BATS_TEST_TMPDIR/docker-volumes" "config"
    [ "$status" -eq 0 ]

    archived=$(sort "$BATS_TEST_TMPDIR/archived.log")
    [ "$archived" = "lancache-ng_nats-data" ]
}

@test "backup_compose_volumes includes the cache volume in full mode" {
    compose_stack_available() { return 0; }
    compose_volume_names() { printf '%s\n' "lancache-ng_proxy-cache" "lancache-ng_nats-data"; }
    docker() {
        if [ "$1" = "run" ]; then
            shift $(($#-1))
            printf '%s\n' "$1" >> "$BATS_TEST_TMPDIR/archived.log"
        fi
    }

    run backup_compose_volumes "$compose_dir" "$BATS_TEST_TMPDIR/docker-volumes" "full"
    [ "$status" -eq 0 ]

    archived=$(sort "$BATS_TEST_TMPDIR/archived.log")
    expected=$(printf '%s\n' "lancache-ng_nats-data" "lancache-ng_proxy-cache")
    [ "$archived" = "$expected" ]
}

# #669 (5): lancache.service's `ExecStop=docker compose down` removes
# containers, so after `systemctl stop lancache.service` a `ps --all` finds
# nothing. compose_volume_names must still discover the project's named
# volumes via the compose project label in that case.
@test "compose_volume_names falls back to label-based discovery when ps --all returns nothing" {
    compose_stack_available() { return 0; }
    runtime_env_file_for_install_dir() { printf '%s\n' "$compose_dir/.env"; }
    docker() {
        case "$1" in
            compose) return 0 ;; # ps --all -q: no containers, simulating post `compose down`
            volume) printf '%s\n' "lancache-ng_nats-data" "lancache-ng_pdns-ssl" ;;
        esac
    }

    run compose_volume_names "$compose_dir"
    [ "$status" -eq 0 ]
    expected=$(printf '%s\n' "lancache-ng_nats-data" "lancache-ng_pdns-ssl")
    [ "$output" = "$expected" ]
}

# #669 (3)/(4): compose_stack_running is what cmd_backup/cmd_restore now use
# to decide whether their cleanup traps should restart the stack, instead of
# unconditionally restarting it after every stop.
@test "compose_stack_running reports true when docker compose ps returns a running container" {
    compose_stack_available() { return 0; }
    runtime_env_file_for_install_dir() { printf '%s\n' "$compose_dir/.env"; }
    docker() { printf 'abc123\n'; }

    run compose_stack_running "$compose_dir"
    [ "$status" -eq 0 ]
}

@test "compose_stack_running reports false when docker compose ps returns nothing" {
    compose_stack_available() { return 0; }
    runtime_env_file_for_install_dir() { printf '%s\n' "$compose_dir/.env"; }
    docker() { return 0; }

    run compose_stack_running "$compose_dir"
    [ "$status" -eq 1 ]
}

# #669 (6): restoring into a different install-dir must not silently wipe
# volumes still owned by a running stack elsewhere on the same host, since
# the compose project name is fixed (not per-install-dir).
@test "guard_restore_shared_project_volumes is a no-op when Docker is unavailable" {
    # Stubs the `command` builtin itself (rather than relying on the test
    # host having no docker on PATH, which CI runners are not guaranteed to
    # satisfy) so this deterministically exercises guard's own
    # `command -v docker || return 0` early-exit branch.
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "docker" ]; then
            return 1
        fi
        builtin command "$@"
    }

    run guard_restore_shared_project_volumes "$compose_dir" "lancache-ng"
    unset -f command
    [ "$status" -eq 0 ]
}

@test "guard_restore_shared_project_volumes refuses when a different install-dir owns a running container for the project" {
    other_install="$BATS_TEST_TMPDIR/other-install"
    mkdir -p "$other_install"
    docker() {
        case "$1" in
            ps) printf 'abc123\n' ;;
            inspect) printf '%s\n' "$other_install" ;;
        esac
    }

    run guard_restore_shared_project_volumes "$compose_dir" "lancache-ng"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Refusing to restore"* ]]
}

@test "guard_restore_shared_project_volumes allows restore when the running container's working_dir matches the target" {
    docker() {
        case "$1" in
            ps) printf 'abc123\n' ;;
            inspect) printf '%s\n' "$compose_dir" ;;
        esac
    }

    run guard_restore_shared_project_volumes "$compose_dir" "lancache-ng"
    [ "$status" -eq 0 ]
}
