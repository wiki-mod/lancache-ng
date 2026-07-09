#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# ShellSpec tests for setup.sh parsing primitives used by host simulations.

Describe 'setup.sh .env parsing helpers'
  BeforeEach 'setup_shellspec_env'

  setup_shellspec_env() {
    repo_root="$(pwd)"
    helper_file="$SHELLSPEC_WORKDIR/setup-env-helpers.sh"
    env_file="$SHELLSPEC_WORKDIR/.env"

    # shellcheck source=tests/shellspec/helpers/setup-env-helpers.sh
    source tests/shellspec/helpers/setup-env-helpers.sh
    load_setup_env_helpers "$repo_root" "$helper_file"
  }

  reject_unsafe_cache_dir() {
    bash -c 'source "$1"; validate_env_value CACHE_DIR "$2"' bash "$helper_file" '/opt/lancache # broken'
  }

  It 'parses quoted Compose values before inline comments'
    printf '%s\n' 'CACHE_DIR="/opt/lancache cache" # fast disk' > "$env_file"

    When call get_env_var CACHE_DIR "$env_file"

    The status should be success
    The output should eq '/opt/lancache cache'
  End

  It 'rejects unsafe unescaped values before setup writes them'
    When call reject_unsafe_cache_dir

    The status should be failure
    The stderr should include 'CACHE_DIR contains unsafe characters for .env'
  End

  It 'allows an intentionally empty value for optional bind overrides'
    When call validate_env_value UI_BIND_IP ''

    The status should be success
    The output should eq ''
  End
End
