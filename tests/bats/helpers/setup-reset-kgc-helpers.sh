#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads setup.sh's reset-to-last-known-good-config family --
# cmd_reset_to_last_known_good_config(), list_kea_snapshot_ids(),
# kea_ctrl_post(), reset_kea_to_last_known_good_config(), and the dns/pdns
# counterparts (canonical_dns_zone(), list_dns_zones_with_snapshots(),
# dns_zone_snapshot_entries(), dns_rollback_exec(),
# reset_dns_to_last_known_good_config()) -- without executing setup.sh's
# interactive install/update entrypoint or its top-level CLI dispatcher. This
# lets tests drive the mutating Kea/DNS recovery paths (which otherwise only
# run against a live Kea Control Agent / PowerDNS rollback listener) directly.
#
# The captured range is every contiguous function definition from
# cmd_reset_to_last_known_good_config() through just before the "update-ip
# subcommand" banner that follows reset_dns_to_last_known_good_config().
# `die` is stubbed to exit non-zero (not return) so the family's fail-closed
# `... || die` guards actually stop the function under `run`, matching the
# real script's behavior. The handful of cross-cutting helpers the family
# depends on but that are defined elsewhere in setup.sh (env/state-dir
# lookups, prompts, Compose project-name resolution) are stubbed here with
# test-controllable behavior rather than captured.

load_setup_reset_kgc_helpers() {
    local repo_root="$1" helper_file="$2"

    {
        # die must terminate (real setup.sh's die exits): a stub that only
        # `return`ed would let a tripped guard fall through to the next line
        # and defeat the fail-closed test.
        printf '%s\n' 'die() { printf "%s\n" "$*" >&2; exit 1; }'
        # die_no_stack_found (#1068 item 22): a cross-cutting helper defined
        # elsewhere in setup.sh (shared by 7 different commands, not specific
        # to this family), so -- same reasoning as the other stubs below --
        # it is stubbed here rather than captured by the awk range. Must
        # still produce the "No stack found" substring reset_kea's own guard
        # test asserts on.
        printf '%s\n' 'die_no_stack_found() { die "No stack found in $1"; }'
        printf '%s\n' 'print_step() { :; }'
        printf '%s\n' 'print_ok() { :; }'
        printf '%s\n' 'print_warn() { :; }'
        # confirm honors CONFIRM_REPLY (default: decline, so an
        # unconfirmed rollback aborts) -- lets a test opt into the yes path
        # without --yes when it wants to exercise the prompt branch.
        printf '%s\n' 'confirm() { [[ "${CONFIRM_REPLY:-N}" =~ ^[Yy]$ ]]; }'
        # get_env_var: minimal KEY=value reader over the fixture .env, enough
        # for the reset path (it only needs plain scalar values).
        printf '%s\n' 'get_env_var() { awk -F= -v k="$1" '"'"'$1==k{sub(/^[^=]*=/,"");print;exit}'"'"' "$2" 2>/dev/null || true; }'
        # State-dir/env-file resolution stubs: the tests set LANCACHE_STATE_DIR
        # in the fixture .env directly, so the legacy/production fallbacks are
        # never the value under test -- keep them simple and deterministic.
        printf '%s\n' 'runtime_env_file_for_install_dir() { printf "%s\n" "$1/.env"; }'
        printf '%s\n' 'legacy_state_root_or_default() { printf "%s\n" "$1"; }'
        printf '%s\n' 'production_state_root_default() { printf "%s\n" "$1"; }'
        # compose_project_name (setup.sh ~line 2889) is only a real dependency
        # of reset_dns_to_last_known_good_config's dns_rollback_exec calls --
        # it lives well outside this captured range, so it must be stubbed
        # like every other cross-cutting helper above rather than captured.
        printf '%s\n' 'compose_project_name() { printf "%s\n" "test-project"; }'
        awk '
            /^cmd_reset_to_last_known_good_config\(\)/ { capture = 1 }
            /^# ── update-ip subcommand/ { capture = 0 }
            capture { print }
        ' "$repo_root/setup.sh"
    } > "$helper_file"

    # shellcheck source=/dev/null
    source "$helper_file"
}
