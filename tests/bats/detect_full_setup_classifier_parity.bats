#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Locks the full-setup detector's shared output contract to the authoritative
# image-impact classifier so future path additions cannot silently drift.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    detector="$repo_root/scripts/detect-full-setup-changes.sh"
    classifier="$repo_root/scripts/classify-image-impact.sh"
    files="$BATS_TEST_TMPDIR/changed.txt"
}

value_from() {
    local text="$1" wanted="$2" line
    while IFS= read -r line; do
        if [[ "$line" == "$wanted="* ]]; then
            printf '%s\n' "${line#*=}"
            return 0
        fi
    done <<< "$text"
    return 1
}

# This mixed diff exercises the special DNS-domain proxy dependency, a second
# service, build-tools, a shared action, setup runtime, and deploy assembly in
# one fixture. Every overlapping verdict must be byte-for-byte identical.
@test "full-setup shared verdicts exactly match the common classifier" {
    cat > "$files" <<'EOF'
services/dns/cdn-domains.txt
services/syslog/entrypoint.sh
tools/build-tools/Dockerfile
.github/actions/configure-rust-sccache/action.yml
setup.sh
deploy/full-setup/docker-compose.yml
EOF

    CHANGED_FILES="$files" GITHUB_OUTPUT="" run bash "$detector"
    [ "$status" -eq 0 ]
    detector_output="$output"

    CHANGED_FILES="$files" run bash "$classifier"
    [ "$status" -eq 0 ]
    classifier_output="$output"

    shared_keys=(
        proxy dns_image ui watchdog dhcp dhcp_proxy ntp syslog build_tools
        deploy scripts setup_runtime workflow docs_only
    )
    for key in "${shared_keys[@]}"; do
        detector_value="$(value_from "$detector_output" "$key")"
        classifier_value="$(value_from "$classifier_output" "$key")"
        [ "$detector_value" = "$classifier_value" ]
    done

    # The full-setup-only policy remains deliberately local and must still run
    # for this runtime/build/deploy-affecting mixed diff.
    [ "$(value_from "$detector_output" should_run)" = "true" ]
}
