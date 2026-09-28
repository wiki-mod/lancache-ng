#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: derives the build-tools smoke contract from Dockerfile
# Why: one owner covers tools and subcommands
# From: Issue #1095 | PR #1872
set -euo pipefail

if [[ "${1:-}" == "--print-required-tools" ]]; then
  repo_root="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
else
  repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
fi
cd "$repo_root"

dockerfile="tools/build-tools/Dockerfile"
smoke_script="scripts/untracked/select-build-tools-image.sh"
candidate_smoke=".github/actions/build-tools-candidate-smoke/action.yml"

# What: validates consumers derive the canonical tool inventory
# Why: installation and smoke checks must not own parallel inventories
# From: Issue #1095 | PR #1872
for f in "$dockerfile" "$smoke_script" "$candidate_smoke"; do
  if [ ! -f "$f" ]; then
    printf '::error::check-build-tools-smoke-coverage: expected file not found: %s\n' "$f" >&2
    exit 1
  fi
done

failures=0
fail() {
  printf '::error::%s\n' "$1" >&2
  failures=$((failures + 1))
}

# What: extracts required_tools entries from a file
# Why: consumers must derive the Dockerfile inventory
# From: Issue #1095 | PR #1872
extract_required_tools() {
  awk '
    /required_tools=\(/ { in_arr = 1; next }
    in_arr && /\)/ { in_arr = 0 }
    in_arr {
      gsub(/\\/, "")
      gsub(/^[ \t]+|[ \t]+$/, "")
      if ($0 != "" && $0 !~ /^#/) print
    }
  ' "$1"
}

if [[ "${1:-}" == "--print-required-tools" ]]; then
  extract_required_tools "$dockerfile"
  exit 0
fi

mapfile -t dockerfile_tools < <(extract_required_tools "$dockerfile" | sort -u)

if [ "${#dockerfile_tools[@]}" -eq 0 ]; then
  fail "could not extract any required_tools from $dockerfile -- refusing to run a vacuous check (parser bug or the array was renamed/refactored)."
fi
for consumer in "$smoke_script" "$candidate_smoke"; do
  if ! grep -qF 'check-build-tools-smoke-coverage.sh --print-required-tools' "$consumer"; then
    fail "$consumer does not derive its smoke inventory from $dockerfile"
  fi
done

for command in 'docker buildx version' 'docker compose version'; do
  if grep -qF "$command" "$dockerfile"; then
    for consumer in "$smoke_script" "$candidate_smoke"; do
      if ! grep -qF "$command" "$consumer"; then
        fail "$consumer does not verify $command"
      fi
    done
  fi
done

if [ "$failures" -gt 0 ]; then
  printf '::error::check-build-tools-smoke-coverage: %d build-tools smoke contract violation(s).\n' "$failures" >&2
  exit 1
fi

printf 'check-build-tools-smoke-coverage: OK (smoke consumers derive the Dockerfile tool inventory).\n'
