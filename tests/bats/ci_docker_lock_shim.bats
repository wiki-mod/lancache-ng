#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LOCK="$BATS_TEST_TMPDIR/stack-lock.json"
  FAKE_DOCKER="$BATS_TEST_TMPDIR/docker-real"
  LOG="$BATS_TEST_TMPDIR/docker.log"
  OVERRIDE_COPY="$BATS_TEST_TMPDIR/override.json"
  MODEL_COPY="$BATS_TEST_TMPDIR/model.json"

  cat >"$LOCK" <<'JSON'
{
  "schema":"stack-lock/v1",
  "source_sha":"1111111111111111111111111111111111111111",
  "candidate_tag":"candidate-v2-test",
  "runtime":{
    "proxy":{
      "image":"ghcr.io/wiki-mod/lancache-ng/proxy",
      "artifact_source_sha":"1111111111111111111111111111111111111111",
      "source_fingerprint":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "build_inputs":{"build_args":{},"build_contexts":{}},
      "digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "platforms":{
        "linux/amd64":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        "linux/arm64":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      }
    }
  },
  "tooling":{
    "build-tools":{
      "image":"ghcr.io/wiki-mod/lancache-ng/build-tools",
      "artifact_source_sha":"1111111111111111111111111111111111111111",
      "source_fingerprint":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
      "build_inputs":{"build_args":{},"build_contexts":{}},
      "digest":"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      "platforms":{
        "linux/amd64":"sha256:1212121212121212121212121212121212121212121212121212121212121212",
        "linux/arm64":"sha256:3434343434343434343434343434343434343434343434343434343434343434"
      }
    }
  }
}
JSON

  cat >"$FAKE_DOCKER" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"${FAKE_DOCKER_LOG:?}"
printf '\n' >>"$FAKE_DOCKER_LOG"

if [[ "${1:-}" == compose ]]; then
  shift
  args=("$@")
  if [[ " ${args[*]} " == *" config --format json "* ]]; then
    if [[ "${FAKE_CONFIG_FAILURE:-false}" == true ]]; then
      exit 23
    fi
    cat <<'JSON'
{"name":"fixture-project","services":{"proxy":{"image":"ghcr.io/wiki-mod/lancache-ng/proxy:candidate-v2-test"},"external":{"image":"busybox:latest"}}}
JSON
    exit 0
  fi

  for ((i=0; i<${#args[@]}; i++)); do
    if [[ "${args[$i]}" == -f && $((i + 1)) -lt ${#args[@]} ]]; then
      candidate="${args[$((i + 1))]}"
      if [[ -f "$candidate" && -n "${FAKE_MODEL_COPY:-}" ]] \
          && jq -e '.services.external.image? // empty' "$candidate" >/dev/null 2>&1; then
        cp "$candidate" "$FAKE_MODEL_COPY"
      fi
      if [[ -f "$candidate" && -n "${FAKE_OVERRIDE_COPY:-}" ]] \
          && jq -e '.services.proxy.image? // empty' "$candidate" >/dev/null 2>&1 \
          && ! jq -e '.services.external.image? // empty' "$candidate" >/dev/null 2>&1; then
        cp "$candidate" "$FAKE_OVERRIDE_COPY"
      fi
    fi
  done
fi
exit 0
SH
  chmod +x "$FAKE_DOCKER"
}

@test "direct candidate transport tag is replaced by exact index digest" {
  run env \
    GITHUB_WORKSPACE="$REPO_ROOT" \
    CI_LOCKED_STACK_FILE="$LOCK" \
    CI_LOCKED_REAL_DOCKER="$FAKE_DOCKER" \
    CI_LOCKED_DOCKER_SHIM_DIR="$BATS_TEST_TMPDIR/shim" \
    FAKE_DOCKER_LOG="$LOG" \
    bash "$REPO_ROOT/scripts/ci-docker-lock-shim.sh" \
      pull ghcr.io/wiki-mod/lancache-ng/proxy:candidate-v2-test

  [ "$status" -eq 0 ]
  run grep -F 'ghcr.io/wiki-mod/lancache-ng/proxy@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$LOG"
  [ "$status" -eq 0 ]
  run grep -F 'ghcr.io/wiki-mod/lancache-ng/proxy:candidate-v2-test' "$LOG"
  [ "$status" -ne 0 ]
}

@test "direct mutable first-party tag is rejected under stack lock" {
  run env \
    GITHUB_WORKSPACE="$REPO_ROOT" \
    CI_LOCKED_STACK_FILE="$LOCK" \
    CI_LOCKED_REAL_DOCKER="$FAKE_DOCKER" \
    CI_LOCKED_DOCKER_SHIM_DIR="$BATS_TEST_TMPDIR/shim" \
    FAKE_DOCKER_LOG="$LOG" \
    bash "$REPO_ROOT/scripts/ci-docker-lock-shim.sh" \
      pull ghcr.io/wiki-mod/lancache-ng/proxy:latest

  [ "$status" -ne 0 ]
  [[ "$output" == *"mutable first-party tag is forbidden"* ]]
  [ ! -s "$LOG" ]
}

@test "direct wrong first-party digest is rejected under stack lock" {
  wrong="sha256:9999999999999999999999999999999999999999999999999999999999999999"
  run env \
    GITHUB_WORKSPACE="$REPO_ROOT" \
    CI_LOCKED_STACK_FILE="$LOCK" \
    CI_LOCKED_REAL_DOCKER="$FAKE_DOCKER" \
    CI_LOCKED_DOCKER_SHIM_DIR="$BATS_TEST_TMPDIR/shim" \
    FAKE_DOCKER_LOG="$LOG" \
    bash "$REPO_ROOT/scripts/ci-docker-lock-shim.sh" \
      pull "ghcr.io/wiki-mod/lancache-ng/proxy@$wrong"

  [ "$status" -ne 0 ]
  [[ "$output" == *"first-party digest differs from stack lock"* ]]
  [ ! -s "$LOG" ]
}

@test "compose candidate image receives a last-wins digest override" {
  base="$BATS_TEST_TMPDIR/base.yml"
  printf 'services: {}\n' >"$base"

  run env \
    GITHUB_WORKSPACE="$REPO_ROOT" \
    CI_LOCKED_STACK_FILE="$LOCK" \
    CI_LOCKED_REAL_DOCKER="$FAKE_DOCKER" \
    CI_LOCKED_DOCKER_SHIM_DIR="$BATS_TEST_TMPDIR/shim" \
    FAKE_DOCKER_LOG="$LOG" \
    FAKE_OVERRIDE_COPY="$OVERRIDE_COPY" \
    FAKE_MODEL_COPY="$MODEL_COPY" \
    bash "$REPO_ROOT/scripts/ci-docker-lock-shim.sh" \
      compose -f "$base" pull

  [ "$status" -eq 0 ]
  [ -f "$MODEL_COPY" ]
  [ -f "$OVERRIDE_COPY" ]
  run jq -e '.services.external.image == "busybox:latest"' "$MODEL_COPY"
  [ "$status" -eq 0 ]
  run jq -e '.services.proxy.image == "ghcr.io/wiki-mod/lancache-ng/proxy@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$OVERRIDE_COPY"
  [ "$status" -eq 0 ]
}

@test "bare compose keeps the complete discovered model before the digest override" {
  run env \
    GITHUB_WORKSPACE="$REPO_ROOT" \
    CI_LOCKED_STACK_FILE="$LOCK" \
    CI_LOCKED_REAL_DOCKER="$FAKE_DOCKER" \
    CI_LOCKED_DOCKER_SHIM_DIR="$BATS_TEST_TMPDIR/shim" \
    FAKE_DOCKER_LOG="$LOG" \
    FAKE_OVERRIDE_COPY="$OVERRIDE_COPY" \
    FAKE_MODEL_COPY="$MODEL_COPY" \
    bash "$REPO_ROOT/scripts/ci-docker-lock-shim.sh" \
      compose pull

  [ "$status" -eq 0 ]
  [ -f "$MODEL_COPY" ]
  [ -f "$OVERRIDE_COPY" ]

  run jq -e '.services.external.image == "busybox:latest"' "$MODEL_COPY"
  [ "$status" -eq 0 ]
  run jq -e '.services.proxy.image == "ghcr.io/wiki-mod/lancache-ng/proxy:candidate-v2-test"' "$MODEL_COPY"
  [ "$status" -eq 0 ]
  run jq -e '.services.proxy.image == "ghcr.io/wiki-mod/lancache-ng/proxy@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$OVERRIDE_COPY"
  [ "$status" -eq 0 ]

  mapfile -t calls <"$LOG"
  [ "${#calls[@]}" -eq 2 ]
  [[ "${calls[0]}" == *"compose config --format json"* ]]
  file_flag_count="$(grep -o -- '-f ' <<<"${calls[1]}" | wc -l | tr -d ' ')"
  [ "$file_flag_count" -eq 2 ]
}

@test "compose render failure preserves the real failing status" {
  base="$BATS_TEST_TMPDIR/base-failure.yml"
  printf 'services: {}\n' >"$base"

  run env \
    GITHUB_WORKSPACE="$REPO_ROOT" \
    CI_LOCKED_STACK_FILE="$LOCK" \
    CI_LOCKED_REAL_DOCKER="$FAKE_DOCKER" \
    CI_LOCKED_DOCKER_SHIM_DIR="$BATS_TEST_TMPDIR/shim" \
    FAKE_DOCKER_LOG="$LOG" \
    FAKE_CONFIG_FAILURE=true \
    bash "$REPO_ROOT/scripts/ci-docker-lock-shim.sh" \
      compose -f "$base" pull

  [ "$status" -eq 23 ]
}

@test "v2 caller passes the same stack-lock artifact into reusable simulations" {
  workflow="$REPO_ROOT/.github/workflows/ci-artifact-v2.yml"
  reusable="$REPO_ROOT/.github/workflows/full-setup-sims.yml"

  run grep -F 'stack_lock_artifact: stack-lock' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'stack_lock_artifact:' "$reusable"
  [ "$status" -eq 0 ]
  run grep -F 'uses: ./.github/actions/enable-locked-docker' "$reusable"
  [ "$status" -eq 0 ]
}
