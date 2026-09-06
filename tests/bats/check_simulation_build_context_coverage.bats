#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Coverage for scripts/tracked/check-simulation-build-context-coverage.sh:
# the standing guard that fails a build if a
# scripts/untracked/simulations/*.sh `docker build`/`docker buildx build`
# invocation targets a services/*/Dockerfile without a matching
# `--build-context <name>=...` for every `COPY --from=<name>` external
# named context that Dockerfile requires. Builds small synthetic Dockerfile
# and simulation-script fixtures under a scratch repo_root rather than only
# running the guard against today's real repo -- a happy-path check alone
# cannot prove the guard actually CATCHES a regression. The guard script
# accepts an optional repo_root argument for exactly this reason.

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/tracked/check-simulation-build-context-coverage.sh"
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    fixture_root="$BATS_TEST_TMPDIR/fixture-repo"
    mkdir -p "$fixture_root/services/widget" "$fixture_root/scripts/untracked/simulations"
}

fail() {
    echo "$1" >&2
    return 1
}

# A Dockerfile with one internal build stage (never a required context) and
# one external named context, "shared-scripts" -- the exact real-world shape
# of services/{proxy,dns,dhcp,dhcp-proxy,ui,watchdog}/Dockerfile.
write_widget_dockerfile() {
    cat > "$fixture_root/services/widget/Dockerfile" <<'EOF'
FROM alpine:3.24 AS builder
RUN echo build

FROM alpine:3.24
COPY --from=builder /out /usr/local/bin/out
COPY --from=shared-scripts verify-version-banner.sh /usr/local/bin/verify-version-banner.sh
EOF
}

write_widget_sim() {
    local build_line="$1"
    cat > "$fixture_root/scripts/untracked/simulations/widget-simulation.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
repo_root=\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/../../.." && pwd)
cd "\$repo_root"
$build_line
EOF
}

@test "passes when the required shared-scripts context is supplied" {
    write_widget_dockerfile
    write_widget_sim 'docker build -q -t widget --build-context "shared-scripts=$repo_root/scripts/lib" services/widget >/dev/null'

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "fails when the required shared-scripts context is missing (the real regression)" {
    write_widget_dockerfile
    write_widget_sim 'docker build -q -t widget services/widget >/dev/null'

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"shared-scripts"* ]]
    [[ "$output" == *"widget-simulation.sh"* ]]
}

@test "does not require a context for an internal FROM ... AS build stage" {
    write_widget_dockerfile
    # Supplies shared-scripts but never "builder" -- builder is an internal
    # stage (COPY --from=builder), not a named build context, so this must
    # still pass.
    write_widget_sim 'docker build -q -t widget --build-context "shared-scripts=$repo_root/scripts/lib" services/widget >/dev/null'

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "does not treat a real external image reference as a required named context" {
    cat > "$fixture_root/services/widget/Dockerfile" <<'EOF'
FROM alpine:3.24
COPY --from=docker/dockerfile:1 /dockerfile /dockerfile
EOF
    write_widget_sim 'docker build -q -t widget services/widget >/dev/null'

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "requires every context when a Dockerfile has more than one, like services/proxy" {
    cat > "$fixture_root/services/widget/Dockerfile" <<'EOF'
FROM alpine:3.24
COPY --from=shared-scripts verify-version-banner.sh /usr/local/bin/verify-version-banner.sh
COPY --from=dns-domains cdn-domains.txt /etc/nginx/cdn-domains.txt
EOF
    write_widget_sim 'docker build -q -t widget --build-context "shared-scripts=$repo_root/scripts/lib" services/widget >/dev/null'

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"dns-domains"* ]]
    [[ "$output" != *"shared-scripts -- this"* ]]
}

@test "passes with all contexts supplied when a Dockerfile has more than one" {
    cat > "$fixture_root/services/widget/Dockerfile" <<'EOF'
FROM alpine:3.24
COPY --from=shared-scripts verify-version-banner.sh /usr/local/bin/verify-version-banner.sh
COPY --from=dns-domains cdn-domains.txt /etc/nginx/cdn-domains.txt
EOF
    write_widget_sim 'docker build -q -t widget --build-context "dns-domains=$work_dir/fixture" --build-context "shared-scripts=$repo_root/scripts/lib" services/widget >/dev/null'

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "resolves the Dockerfile via -f, not the trailing context, and catches a missing context there too" {
    write_widget_dockerfile
    write_widget_sim 'docker build -q -t widget -f services/widget/Dockerfile "$repo_root" >/dev/null'

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"services/widget/Dockerfile"* ]]
}

@test "joins a backslash-continued multi-line invocation before checking it" {
    write_widget_dockerfile
    write_widget_sim 'docker build -q -t widget \
    -f services/widget/Dockerfile \
    --build-context "shared-scripts=$repo_root/scripts/lib" \
    "$repo_root" >/dev/null'

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "ignores a docker build invocation that does not target a services/*/Dockerfile" {
    write_widget_dockerfile
    mkdir -p "$fixture_root/tools/build-tools"
    cat > "$fixture_root/tools/build-tools/Dockerfile" <<'EOF'
FROM alpine:3.24
COPY --from=shared-scripts verify-version-banner.sh /usr/local/bin/verify-version-banner.sh
EOF
    # The tools/build-tools build never supplies shared-scripts, but it is
    # out of this guard's scope (not services/*/Dockerfile) and must not be
    # flagged; only the compliant services/widget build is examined.
    write_widget_sim 'docker build -q -t bt tools/build-tools >/dev/null
docker build -q -t widget --build-context "shared-scripts=$repo_root/scripts/lib" services/widget >/dev/null'

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 docker build invocation"* ]]
}

@test "does not count a comment merely mentioning docker build in prose" {
    write_widget_dockerfile
    write_widget_sim '# See docker build services/widget for the real invocation below.
docker build -q -t widget --build-context "shared-scripts=$repo_root/scripts/lib" services/widget >/dev/null'

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "reports every violating invocation across files, not just the first" {
    write_widget_dockerfile
    write_widget_sim 'docker build -q -t widget services/widget >/dev/null'
    cat > "$fixture_root/scripts/untracked/simulations/widget-two-simulation.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
docker build -q -t widget2 services/widget >/dev/null
EOF

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"widget-simulation.sh"* ]]
    [[ "$output" == *"widget-two-simulation.sh"* ]]
    [[ "$output" == *"2 violation(s)"* ]]
}

@test "self-diagnoses when zero docker build invocations are found at all" {
    mkdir -p "$fixture_root/scripts/untracked/simulations"

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"examined zero"* ]]
}

@test "the guard also passes when pointed at the real repository tree" {
    run "$script" "$repo_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}
