#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Exercises scripts/untracked/check-compose-healthchecks.sh (issue #1169) against small,
# throwaway deploy/*/docker-compose.yml fixture trees rather than this repo's
# own real compose files, so a positive (all healthchecked) and a negative
# (one missing) case are both proven -- per AG-VAL-024, a check that only
# ever runs against an already-green tree never actually proves its `set -e`
# fail-closed path is reachable at all.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/untracked/check-compose-healthchecks.sh"
    fixture_root="$(mktemp -d)"
    mkdir -p "$fixture_root/deploy/prod" "$fixture_root/deploy/quickstart"
}

teardown() {
    rm -rf "$fixture_root"
}

# fail <message>: neither bats-core nor this project defines a `fail` helper
# globally (confirmed empirically against the pinned build-tools image's bats
# 1.11.1 -- no tests/bats/*.bats file loads bats-support/bats-assert, the
# libraries that normally provide one), so it must be defined locally in
# every file that uses the `[ cond ] || fail "..."` assertion style, the same
# way tests/bats/healthcheck_service_lists.bats does. See that file's own
# comment for the full incident this was found from.
fail() {
    echo "$1" >&2
    return 1
}

# write_compose <path> <heredoc content via stdin>
write_compose() {
    cat > "$1"
}

@test "passes when every service in every deploy/*/docker-compose.yml has a healthcheck" {
    write_compose "$fixture_root/deploy/prod/docker-compose.yml" <<'EOF'
services:
  proxy:
    image: alpine:3.20
    healthcheck:
      test: ["CMD-SHELL", "true"]
      interval: 10s
  nats:
    image: nats:2-alpine
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8222/healthz"]
      interval: 30s

volumes:
  proxy-cache:
EOF
    write_compose "$fixture_root/deploy/quickstart/docker-compose.yml" <<'EOF'
services:
  proxy:
    image: alpine:3.20
    healthcheck:
      test: ["CMD-SHELL", "true"]
      interval: 10s
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"All 3 checked service(s)"* ]] || fail "unexpected output: $output"
}

@test "fails when a service is missing a healthcheck: block" {
    write_compose "$fixture_root/deploy/prod/docker-compose.yml" <<'EOF'
services:
  proxy:
    image: alpine:3.20
    healthcheck:
      test: ["CMD-SHELL", "true"]
      interval: 10s
  broken-service:
    image: alpine:3.20
    restart: always

networks:
  docker-api:
    internal: true
EOF
    write_compose "$fixture_root/deploy/quickstart/docker-compose.yml" <<'EOF'
services:
  proxy:
    image: alpine:3.20
    healthcheck:
      test: ["CMD-SHELL", "true"]
      interval: 10s
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"broken-service"* ]] || fail "expected diagnostic to name broken-service, got: $output"
    [[ "$output" == *"deploy/prod/docker-compose.yml"* ]] || fail "expected diagnostic to name the offending file, got: $output"
}

@test "does not misreport a network/volume entry that shares a service's 2-space-indented name shape" {
    # networks:/volumes: top-level sections use the exact same "  <name>:"
    # shape as a service declaration -- this guards against the parser
    # mistaking one for the other (the actual bug class this script's own
    # state-machine design exists to avoid, per its header comment).
    write_compose "$fixture_root/deploy/prod/docker-compose.yml" <<'EOF'
services:
  proxy:
    image: alpine:3.20
    healthcheck:
      test: ["CMD-SHELL", "true"]
      interval: 10s

networks:
  docker-api:
    internal: true

volumes:
  proxy-cache:
  watchdog-status:
EOF
    write_compose "$fixture_root/deploy/quickstart/docker-compose.yml" <<'EOF'
services:
  proxy:
    image: alpine:3.20
    healthcheck:
      test: ["CMD-SHELL", "true"]
      interval: 10s
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"All 2 checked service(s)"* ]] || fail "expected exactly 2 real services checked (networks/volumes must not be counted), got: $output"
}

@test "excludes dhcp-probe from the healthcheck mandate (documented one-shot helper exception)" {
    write_compose "$fixture_root/deploy/prod/docker-compose.yml" <<'EOF'
services:
  proxy:
    image: alpine:3.20
    healthcheck:
      test: ["CMD-SHELL", "true"]
      interval: 10s
  dhcp-probe:
    image: alpine:3.20
    restart: "no"
EOF
    write_compose "$fixture_root/deploy/quickstart/docker-compose.yml" <<'EOF'
services:
  proxy:
    image: alpine:3.20
    healthcheck:
      test: ["CMD-SHELL", "true"]
      interval: 10s
  dhcp-probe:
    image: alpine:3.20
    restart: "no"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ] || fail "expected dhcp-probe's documented exclusion to keep this green, got: $output"
}

@test "does not false-match a heredoc script body that merely contains the word healthcheck" {
    # A service whose `command: |` heredoc happens to contain a deeply
    # indented line mentioning "healthcheck" must not be mistaken for a real
    # `    healthcheck:` property (exactly 4-space indent) -- this is why the
    # script anchors on the literal 4-space-indented key, not a bare
    # substring grep for "healthcheck".
    write_compose "$fixture_root/deploy/prod/docker-compose.yml" <<'EOF'
services:
  tricky-service:
    image: alpine:3.20
    command:
      - |
        echo "this is not a real healthcheck: block"
    restart: always
EOF
    write_compose "$fixture_root/deploy/quickstart/docker-compose.yml" <<'EOF'
services:
  proxy:
    image: alpine:3.20
    healthcheck:
      test: ["CMD-SHELL", "true"]
      interval: 10s
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"tricky-service"* ]] || fail "expected tricky-service to be flagged despite the heredoc's fake 'healthcheck:' text, got: $output"
}

@test "fails closed (does not vacuously pass) when no deploy/*/docker-compose.yml files exist" {
    empty_root="$(mktemp -d)"
    run bash "$script" "$empty_root"
    rm -rf "$empty_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"No deploy"* ]] || fail "expected a 'no compose files found' diagnostic, got: $output"
}

@test "real repository compose files all pass this check (regression guard for the actual #1169 fix)" {
    run bash "$script"
    [ "$status" -eq 0 ] || fail "the real deploy/*/docker-compose.yml files should all pass after #1169; output: $output"
}
