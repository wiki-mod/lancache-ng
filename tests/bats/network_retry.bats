#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  COUNTER_FILE="$BATS_TEST_TMPDIR/counter"
  FAKE_COMMAND="$BATS_TEST_TMPDIR/fake-network-command.sh"
}

@test "network retry succeeds after transient failures" {
  cat >"$FAKE_COMMAND" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
counter_file="$1"
count=0
[[ -f "$counter_file" ]] && count="$(cat "$counter_file")"
count=$((count + 1))
printf '%s\n' "$count" >"$counter_file"
(( count >= 3 ))
EOF
  chmod +x "$FAKE_COMMAND"

  run env \
    NETWORK_RETRY_MAX_ATTEMPTS=4 \
    NETWORK_RETRY_BACKOFF_SECONDS=0 \
    bash -c 'source "$1"; network_retry -- "$2" "$3"' _ \
      "$REPO_ROOT/scripts/lib/network-retry.sh" "$FAKE_COMMAND" "$COUNTER_FILE"

  [ "$status" -eq 0 ]
  [ "$(cat "$COUNTER_FILE")" -eq 3 ]
}

@test "network retry preserves the final failure status" {
  cat >"$FAKE_COMMAND" <<'EOF'
#!/usr/bin/env bash
exit 23
EOF
  chmod +x "$FAKE_COMMAND"

  run env \
    NETWORK_RETRY_MAX_ATTEMPTS=3 \
    NETWORK_RETRY_BACKOFF_SECONDS=0 \
    bash -c 'source "$1"; network_retry -- "$2"' _ \
      "$REPO_ROOT/scripts/lib/network-retry.sh" "$FAKE_COMMAND"

  [ "$status" -eq 23 ]
  [[ "$output" == *"after 3 attempts"* ]]
}

@test "network retry stops immediately on permanent failure signal" {
  cat >"$FAKE_COMMAND" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
counter_file="$1"
count=0
[[ -f "$counter_file" ]] && count="$(cat "$counter_file")"
count=$((count + 1))
printf '%s\n' "$count" >"$counter_file"
exit 99
EOF
  chmod +x "$FAKE_COMMAND"

  run env \
    NETWORK_RETRY_MAX_ATTEMPTS=4 \
    NETWORK_RETRY_BACKOFF_SECONDS=0 \
    bash -c 'source "$1"; network_retry -- "$2" "$3"' _ \
      "$REPO_ROOT/scripts/lib/network-retry.sh" "$FAKE_COMMAND" "$COUNTER_FILE"

  [ "$status" -eq 99 ]
  [ "$(cat "$COUNTER_FILE")" -eq 1 ]
  [[ "$output" == *"failed permanently"* ]]
}
