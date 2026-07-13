#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression coverage for #666: cmd_update_ip() used to be hardwired to
# $SCRIPT_DIR/deploy/prod and $SCRIPT_DIR/config/prod/dns-*.env -- the repo
# checkout's own manual-production tree -- no matter which install_dir the
# operator actually passed (or the guided-install hint banner's default of
# /opt/lancache-ng). That meant `./setup.sh update-ip` on a real quickstart
# install silently edited/read the wrong files, leaving the actual running
# stack's IPs unchanged.
#
# resolve_update_ip_config_paths() is the extracted, pure function
# cmd_update_ip() now calls to resolve its target files from an arbitrary
# install_dir, mirroring cmd_update()'s ${1:-/opt/lancache-ng} pattern. These
# tests exercise it directly (no interactive `ask` prompts, no docker) against
# both install-dir shapes it must distinguish:
#   - a quickstart install (any directory that is not a .../deploy/prod
#     checkout): deploy/quickstart/docker-compose.yml wires PROXY_IP straight
#     from ${IP_STANDARD}/${IP_SSL} in the main .env, so there is no separate
#     dns-standard.env/dns-ssl.env to resolve.
#   - a manual deploy/prod checkout: deploy/prod/docker-compose.yml's
#     dns-standard/dns-ssl services load env_file: ../../config/prod/dns-*.env,
#     i.e. two directories above install_dir, at the repo root.
#
# This reuses tests/bats/helpers/setup-update-helpers.sh's extraction range
# (is_valid_ipv4() through, but excluding, install_missing_tools()) rather
# than adding a second awk-range helper, since resolve_update_ip_config_paths()
# and its dependencies (is_deploy_prod_install_dir, deploy_prod_repo_root,
# runtime_env_file_for_install_dir) already live inside that existing range.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-update-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-update-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-update-helpers.sh"
    load_setup_update_helpers "$repo_root" "$helper_file"
}

@test "resolve_update_ip_config_paths on a quickstart install_dir resolves only .env, no dns-*.env" {
    install_dir="$BATS_TEST_TMPDIR/opt-lancache-ng"
    mkdir -p "$install_dir"
    : > "$install_dir/.env"

    run resolve_update_ip_config_paths "$install_dir"
    [ "$status" -eq 0 ]

    mapfile -t lines <<< "$output"
    [ "${lines[0]}" = "$install_dir/.env" ]
    [ -z "${lines[1]}" ]
    [ -z "${lines[2]}" ]
}

@test "resolve_update_ip_config_paths on a deploy/prod install_dir resolves repo-root config/prod/dns-*.env" {
    fake_repo="$BATS_TEST_TMPDIR/fake-repo"
    install_dir="$fake_repo/deploy/prod"
    mkdir -p "$install_dir" "$fake_repo/config/prod"
    : > "$install_dir/.env"

    run resolve_update_ip_config_paths "$install_dir"
    [ "$status" -eq 0 ]

    mapfile -t lines <<< "$output"
    [ "${lines[0]}" = "$install_dir/.env" ]
    [ "${lines[1]}" = "$fake_repo/config/prod/dns-standard.env" ]
    [ "${lines[2]}" = "$fake_repo/config/prod/dns-ssl.env" ]
}

@test "resolve_update_ip_config_paths on a deploy/prod install_dir prefers .env.local over .env" {
    fake_repo="$BATS_TEST_TMPDIR/fake-repo-local"
    install_dir="$fake_repo/deploy/prod"
    mkdir -p "$install_dir" "$fake_repo/config/prod"
    : > "$install_dir/.env"
    : > "$install_dir/.env.local"

    run resolve_update_ip_config_paths "$install_dir"
    [ "$status" -eq 0 ]

    mapfile -t lines <<< "$output"
    # Matches runtime_env_file_for_install_dir()'s existing untracked-override
    # behavior for manual deploy/prod checkouts (a git pull during update must
    # never clobber the operator's real production values).
    [ "${lines[0]}" = "$install_dir/.env.local" ]
}

@test "resolve_update_ip_config_paths on a directory literally named prod but not under deploy/ is treated as quickstart" {
    # is_deploy_prod_install_dir() requires both basename(install_dir) = prod
    # AND basename(dirname(install_dir)) = deploy -- a directory that merely
    # happens to be named "prod" elsewhere must not be misidentified as the
    # manual production checkout layout.
    install_dir="$BATS_TEST_TMPDIR/somewhere/prod"
    mkdir -p "$install_dir"
    : > "$install_dir/.env"

    run resolve_update_ip_config_paths "$install_dir"
    [ "$status" -eq 0 ]

    mapfile -t lines <<< "$output"
    [ "${lines[0]}" = "$install_dir/.env" ]
    [ -z "${lines[1]}" ]
    [ -z "${lines[2]}" ]
}
