#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  WRAPPER="$REPO_ROOT/scripts/ci-run-locked-quickstart-simulation.sh"
}

@test "quickstart runtime gate delegates to the canonical Docker lock shim" {
  run grep -F 'CI_LOCKED_DOCKER_SHIM_SCRIPT="$repo_root/scripts/ci-docker-lock-shim.sh"' "$WRAPPER"
  [ "$status" -eq 0 ]

  run grep -F 'exec "${CI_LOCKED_DOCKER_SHIM_SCRIPT:?CI_LOCKED_DOCKER_SHIM_SCRIPT is required}" "$@"' "$WRAPPER"
  [ "$status" -eq 0 ]

  run grep -F 'source "$repo_root/scripts/syslog-forwarding-simulation.sh"' "$WRAPPER"
  [ "$status" -eq 0 ]
}

@test "quickstart wrapper does not carry a second compose parser or override builder" {
  run grep -F 'ci_locked_quickstart_split_compose_args' "$WRAPPER"
  [ "$status" -eq 1 ]

  run grep -F 'ci_locked_quickstart_build_override' "$WRAPPER"
  [ "$status" -eq 1 ]

  run grep -F 'CI_LOCKED_QUICKSTART_OVERRIDE' "$WRAPPER"
  [ "$status" -eq 1 ]
}

@test "locked quickstart shares the host-local mutex with existing quickstart jobs" {
  run grep -F -- '-v /tmp:/tmp' "$WRAPPER"
  [ "$status" -eq 0 ]

  run grep -F 'source scripts/lib/quickstart-compose-lock.sh' "$WRAPPER"
  [ "$status" -eq 0 ]

  run grep -F 'quickstart_compose_lock_acquire' "$WRAPPER"
  [ "$status" -eq 0 ]

  run grep -F 'CI_QUICKSTART_LOCK_CHILD=1' "$WRAPPER"
  [ "$status" -eq 0 ]
}

@test "host-lock child keeps the exact build-tools identity" {
  run grep -F '[[ "$BUILD_TOOLS_IMAGE" == *@sha256:* ]]' "$WRAPPER"
  [ "$status" -eq 0 ]

  run grep -F '"$BUILD_TOOLS_IMAGE" \' "$WRAPPER"
  [ "$status" -eq 0 ]
}

@test "quickstart runtime gate performs an independent final Docker identity readback" {
  run grep -F 'actual="$(command docker inspect --format' "$WRAPPER"
  [ "$status" -eq 0 ]

  run grep -F 'label=com.docker.compose.project=${compose_project' "$WRAPPER"
  [ "$status" -eq 0 ]

  run grep -F 'Quickstart deep validation final readback asserted' "$WRAPPER"
  [ "$status" -eq 0 ]
}
