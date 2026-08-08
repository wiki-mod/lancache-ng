#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

write_reused_record() {
  local output="$1" platform="$2" child_digest="$3" index_digest="$4"
  jq -n \
    --arg platform "$platform" \
    --arg child_digest "$child_digest" \
    --arg index_digest "$index_digest" \
    '{
      schema:"image-candidate-platform/v1",
      scope:"runtime",
      service:"proxy",
      image:"ghcr.io/wiki-mod/lancache-ng/proxy",
      candidate_source_sha:"1111111111111111111111111111111111111111",
      artifact_source_sha:"1111111111111111111111111111111111111111",
      source_fingerprint:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      build_inputs:{build_args:{},build_contexts:{}},
      platform:$platform,
      digest:$child_digest,
      mode:"reused",
      reused_index_digest:$index_digest
    }' >"$output"
}

@test "reused platform record requires accepted index digest" {
  source "$REPO_ROOT/scripts/lib/ci-artifact-identity.sh"
  record="$BATS_TEST_TMPDIR/reused.json"
  child="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  index="sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

  write_reused_record "$record" linux/amd64 "$child" "$index"
  run ci_ai_validate_platform_record "$record"
  [ "$status" -eq 0 ]

  jq 'del(.reused_index_digest)' "$record" >"$record.tmp"
  mv "$record.tmp" "$record"
  run ci_ai_validate_platform_record "$record"
  [ "$status" -ne 0 ]
}

@test "reused service keeps accepted index and never creates replacement index" {
  records="$BATS_TEST_TMPDIR/records"
  index_record="$BATS_TEST_TMPDIR/index.json"
  fake_bin="$BATS_TEST_TMPDIR/bin"
  docker_log="$BATS_TEST_TMPDIR/docker.log"
  mkdir -p "$records" "$fake_bin"

  index="sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  amd64="sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  arm64="sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  write_reused_record "$records/proxy__amd64.json" linux/amd64 "$amd64" "$index"
  write_reused_record "$records/proxy__arm64.json" linux/arm64 "$arm64" "$index"

  cat >"$fake_bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"${FAKE_DOCKER_LOG:?}"
printf '\n' >>"$FAKE_DOCKER_LOG"
if [[ " $* " == *" imagetools create "* ]]; then
  echo "unexpected imagetools create" >&2
  exit 91
fi
if [[ " $* " == *" imagetools inspect "* ]]; then
  cat <<JSON
{"digest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","manifests":[{"digest":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","platform":{"os":"linux","architecture":"amd64"}},{"digest":"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","platform":{"os":"linux","architecture":"arm64"}}]}
JSON
  exit 0
fi
echo "unexpected docker invocation: $*" >&2
exit 92
SH
  chmod +x "$fake_bin/docker"

  run env \
    PATH="$fake_bin:$PATH" \
    FAKE_DOCKER_LOG="$docker_log" \
    GHCR_RETRY_MAX_ATTEMPTS=1 \
    bash "$REPO_ROOT/scripts/ci-assemble-service-index.sh" \
      proxy ghcr.io/wiki-mod/lancache-ng/proxy \
      1111111111111111111111111111111111111111 \
      candidate-v2-unused \
      "$records" "$index_record"

  if [ "$status" -ne 0 ]; then
    {
      printf 'ci-assemble-service-index failed with status %s:\n%s\n' "$status" "$output"
      if [ -f "$docker_log" ]; then
        printf '%s\n' 'docker invocations before failure:'
        cat "$docker_log"
      fi
    } >&3
  fi
  [ "$status" -eq 0 ]
  run jq -e --arg index "$index" '
    .digest == $index
    and .candidate_ref == ("ghcr.io/wiki-mod/lancache-ng/proxy@" + $index)
    and .build_inputs == {build_args:{},build_contexts:{}}
    and .platforms["linux/amd64"] == "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    and .platforms["linux/arm64"] == "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  ' "$index_record"
  [ "$status" -eq 0 ]

  run grep -F 'imagetools create' "$docker_log"
  [ "$status" -ne 0 ]
  run grep -F 'ghcr.io/wiki-mod/lancache-ng/proxy@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' "$docker_log"
  [ "$status" -eq 0 ]
}
