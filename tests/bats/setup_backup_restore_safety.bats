#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
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
    unset -f systemctl 2>/dev/null || true
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

@test "guard_restore_shared_project_volumes also refuses a stopped foreign install that still has compose containers" {
    other_install="$BATS_TEST_TMPDIR/stopped-other-install"
    mkdir -p "$other_install"
    docker() {
        case "$1" in
            ps)
                [[ "$2" = "-a" ]] || return 1
                printf 'stopped123\n'
                ;;
            inspect) printf '%s\n' "$other_install" ;;
        esac
    }

    run guard_restore_shared_project_volumes "$compose_dir" "lancache-ng"
    [ "$status" -ne 0 ]
    [[ "$output" == *"still has containers"* ]]
}

@test "restore_compose_volumes replaces existing content with the archived files including dotfiles" {
    volume_root="$BATS_TEST_TMPDIR/docker-volumes"
    volume_store="$BATS_TEST_TMPDIR/volume-store"
    mkdir -p "$volume_root" "$volume_store/lancache-ng_pdns-data"

    mkdir -p "$BATS_TEST_TMPDIR/archive-src/subdir" "$BATS_TEST_TMPDIR/archive-src/empty-dir"
    printf 'fresh\n' > "$BATS_TEST_TMPDIR/archive-src/subdir/restored.txt"
    printf 'hidden\n' > "$BATS_TEST_TMPDIR/archive-src/.pdns.env"
    tar -C "$BATS_TEST_TMPDIR/archive-src" -cpf "$volume_root/lancache-ng_pdns-data.tar" .

    printf 'stale\n' > "$volume_store/lancache-ng_pdns-data/stale.txt"
    printf 'old-hidden\n' > "$volume_store/lancache-ng_pdns-data/.stale"

    compose_stack_available() { return 0; }
    docker() {
        case "$1" in
            volume)
                [[ "$2" = "create" ]] || return 1
                mkdir -p "$volume_store/$3"
                ;;
            run)
                volume="${@: -1}"
                target="$volume_store/$volume"
                rm -rf "$target"/* "$target"/.[!.]* "$target"/..?* 2>/dev/null || true
                mkdir -p "$target"
                tar -C "$target" -xpf "$volume_root/$volume.tar"
                ;;
        esac
    }

    run restore_compose_volumes "$compose_dir" "$volume_root"
    [ "$status" -eq 0 ]
    [ ! -e "$volume_store/lancache-ng_pdns-data/stale.txt" ]
    [ ! -e "$volume_store/lancache-ng_pdns-data/.stale" ]
    [ "$(cat "$volume_store/lancache-ng_pdns-data/subdir/restored.txt")" = "fresh" ]
    [ "$(cat "$volume_store/lancache-ng_pdns-data/.pdns.env")" = "hidden" ]
    [ -d "$volume_store/lancache-ng_pdns-data/empty-dir" ]
}

@test "pause_lancache_convergence_for_update records and disables the previous timer state" {
    systemd_state="$BATS_TEST_TMPDIR/systemd-state"
    cat > "$systemd_state" <<'EOF'
timer_exists=1
timer_active=1
timer_enabled=1
service_exists=1
service_active=1
EOF
    SYSTEMD_LOG="$BATS_TEST_TMPDIR/systemd.log"
    export systemd_state SYSTEMD_LOG

    systemctl() {
        local cmd="$1" unit="${2:-}"
        local rc=0
        if [[ "$unit" = "--quiet" ]]; then
            unit="${3:-}"
        fi
        # shellcheck disable=SC1090
        source "$systemd_state"
        case "$cmd" in
            list-unit-files)
                case "$unit" in
                    lancache-converge.timer) [[ "$timer_exists" = "1" ]] || rc=1 ;;
                    lancache-converge.service) [[ "$service_exists" = "1" ]] || rc=1 ;;
                esac
                ;;
            is-active)
                case "$unit" in
                    lancache-converge.timer) [[ "$timer_active" = "1" ]] || rc=1 ;;
                    lancache-converge.service) [[ "$service_active" = "1" ]] || rc=1 ;;
                esac
                ;;
            is-enabled)
                [[ "$unit" = "lancache-converge.timer" && "$timer_enabled" = "1" ]] || rc=1
                ;;
            stop)
                case "$unit" in
                    lancache-converge.timer) timer_active=0 ;;
                    lancache-converge.service) service_active=0 ;;
                esac
                printf 'stop %s\n' "$unit" >> "$SYSTEMD_LOG"
                ;;
            disable)
                timer_enabled=0
                printf 'disable %s\n' "$unit" >> "$SYSTEMD_LOG"
                ;;
            start)
                case "$unit" in
                    lancache-converge.timer) timer_active=1 ;;
                    lancache-converge.service) service_active=1 ;;
                esac
                printf 'start %s\n' "$unit" >> "$SYSTEMD_LOG"
                ;;
            enable)
                timer_enabled=1
                printf 'enable %s\n' "$unit" >> "$SYSTEMD_LOG"
                ;;
        esac
        cat > "$systemd_state" <<EOF
timer_exists=$timer_exists
timer_active=$timer_active
timer_enabled=$timer_enabled
service_exists=$service_exists
service_active=$service_active
EOF
        return "$rc"
    }

    pause_lancache_convergence_for_update
    [ "$CONVERGENCE_TIMER_WAS_ACTIVE" -eq 1 ]
    [ "$CONVERGENCE_TIMER_WAS_ENABLED" -eq 1 ]
    [ "$CONVERGENCE_SERVICE_WAS_ACTIVE" -eq 1 ]
    log_output="$(cat "$SYSTEMD_LOG")"
    [[ "$log_output" == *"stop lancache-converge.timer"* ]]
    [[ "$log_output" == *"stop lancache-converge.service"* ]]
    [[ "$log_output" == *"disable lancache-converge.timer"* ]]
}

@test "resume_lancache_convergence_after_update restores only the state that pause recorded" {
    systemd_state="$BATS_TEST_TMPDIR/systemd-state"
    cat > "$systemd_state" <<'EOF'
timer_exists=1
timer_active=0
timer_enabled=0
service_exists=1
service_active=0
EOF
    SYSTEMD_LOG="$BATS_TEST_TMPDIR/systemd.log"
    export systemd_state SYSTEMD_LOG

    systemctl() {
        local cmd="$1" unit="${2:-}"
        local rc=0
        if [[ "$unit" = "--quiet" ]]; then
            unit="${3:-}"
        fi
        # shellcheck disable=SC1090
        source "$systemd_state"
        case "$cmd" in
            list-unit-files)
                case "$unit" in
                    lancache-converge.timer) [[ "$timer_exists" = "1" ]] || rc=1 ;;
                    lancache-converge.service) [[ "$service_exists" = "1" ]] || rc=1 ;;
                esac
                ;;
            is-active)
                case "$unit" in
                    lancache-converge.timer) [[ "$timer_active" = "1" ]] || rc=1 ;;
                    lancache-converge.service) [[ "$service_active" = "1" ]] || rc=1 ;;
                esac
                ;;
            is-enabled)
                [[ "$unit" = "lancache-converge.timer" && "$timer_enabled" = "1" ]] || rc=1
                ;;
            start)
                case "$unit" in
                    lancache-converge.timer) timer_active=1 ;;
                    lancache-converge.service) service_active=1 ;;
                esac
                printf 'start %s\n' "$unit" >> "$SYSTEMD_LOG"
                ;;
            enable)
                timer_enabled=1
                printf 'enable %s\n' "$unit" >> "$SYSTEMD_LOG"
                ;;
        esac
        cat > "$systemd_state" <<EOF
timer_exists=$timer_exists
timer_active=$timer_active
timer_enabled=$timer_enabled
service_exists=$service_exists
service_active=$service_active
EOF
        return "$rc"
    }

    CONVERGENCE_TIMER_WAS_ACTIVE=1
    CONVERGENCE_TIMER_WAS_ENABLED=1
    CONVERGENCE_SERVICE_WAS_ACTIVE=1

    resume_lancache_convergence_after_update true
    log_output="$(cat "$SYSTEMD_LOG")"
    [[ "$log_output" == *"start lancache-converge.service"* ]]
    [[ "$log_output" == *"enable lancache-converge.timer"* ]]
    [[ "$log_output" == *"start lancache-converge.timer"* ]]
}
