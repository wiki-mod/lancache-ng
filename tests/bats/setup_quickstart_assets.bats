#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for setup.sh's install_quickstart_compose_assets(), which
# copies deploy/quickstart/docker-compose.yml plus the two scripts it
# bind-mounts (docker-socket-proxy.sh, dhcp-probe.sh) into a real install
# directory. Guards issue #538 (dhcp-probe.sh was never copied, breaking
# every quickstart install) and its PR #539 follow-up (a prior install that
# already hit #538 left the bind-mount target behind as an empty directory;
# GNU install(1) copies INTO an existing directory rather than replacing it,
# so a naive fix would silently fail to recover an already-broken install).

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-quickstart-helpers.sh"
    install_dir="$BATS_TEST_TMPDIR/install"
    mkdir -p "$install_dir"

    # shellcheck source=tests/bats/helpers/setup-quickstart-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-quickstart-helpers.sh"
    load_setup_quickstart_helpers "$repo_root" "$helper_file"
}

@test "fresh install copies docker-compose.yml and both scripts as real executable files" {
    run install_quickstart_compose_assets "$install_dir"
    [ "$status" -eq 0 ]

    [ -f "$install_dir/docker-compose.yml" ]
    [ -f "$install_dir/scripts/dhcp-probe.sh" ]
    [ -f "$install_dir/scripts/docker-socket-proxy.sh" ]
    [ -x "$install_dir/scripts/dhcp-probe.sh" ]
    [ -x "$install_dir/scripts/docker-socket-proxy.sh" ]

    # Content must match the real shipped sources, not a stub or partial copy.
    diff "$repo_root/services/ui/dhcp-probe.sh" "$install_dir/scripts/dhcp-probe.sh"
    diff "$repo_root/scripts/docker-socket-proxy.sh" "$install_dir/scripts/docker-socket-proxy.sh"
}

# The exact scenario from the PR #539 review finding: an install that already
# hit #538 has Docker's own auto-vivified bind-mount source sitting at the
# target path as an empty directory (docker compose creates one when the
# bind-mount source doesn't exist). Re-running setup.sh update must replace
# it with the real file, not copy into it as dhcp-probe.sh/dhcp-probe.sh
# while leaving the actual mount source a directory.
@test "recovers when the target paths already exist as stale directories" {
    mkdir -p "$install_dir/scripts/dhcp-probe.sh"
    mkdir -p "$install_dir/scripts/docker-socket-proxy.sh"

    run install_quickstart_compose_assets "$install_dir"
    [ "$status" -eq 0 ]

    [ -f "$install_dir/scripts/dhcp-probe.sh" ]
    [ ! -d "$install_dir/scripts/dhcp-probe.sh" ]
    [ -f "$install_dir/scripts/docker-socket-proxy.sh" ]
    [ ! -d "$install_dir/scripts/docker-socket-proxy.sh" ]

    # The bug this guards against would nest the real file one level deeper
    # instead of replacing the stale directory.
    [ ! -e "$install_dir/scripts/dhcp-probe.sh/dhcp-probe.sh" ]
    [ ! -e "$install_dir/scripts/docker-socket-proxy.sh/docker-socket-proxy.sh" ]

    diff "$repo_root/services/ui/dhcp-probe.sh" "$install_dir/scripts/dhcp-probe.sh"
    diff "$repo_root/scripts/docker-socket-proxy.sh" "$install_dir/scripts/docker-socket-proxy.sh"
}

@test "running install twice on an already-correct install stays idempotent" {
    install_quickstart_compose_assets "$install_dir"

    run install_quickstart_compose_assets "$install_dir"
    [ "$status" -eq 0 ]

    [ -f "$install_dir/scripts/dhcp-probe.sh" ]
    [ -x "$install_dir/scripts/dhcp-probe.sh" ]
    [ -f "$install_dir/scripts/docker-socket-proxy.sh" ]
    [ -x "$install_dir/scripts/docker-socket-proxy.sh" ]
}
