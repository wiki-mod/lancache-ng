#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# CI drift guard for the committed OpenVEX document (vex.openvex.json): fails
# closed if that file is out of sync with .trivyignore.yaml. This is what wires
# "regenerate the VEX document whenever .trivyignore.yaml changes" (OSPS-VM-
# 04.02) into CI -- a PR that edits the accepted-vulnerability list but forgets
# to regenerate the VEX document is caught here instead of shipping a stale
# supply-chain artifact. Modeled on scripts/check-workflow-service-lists.sh's
# regenerate-and-diff pattern.
#
# Determinism: the committed document carries a timestamp that must not cause a
# false-positive drift on every run, so this reads the committed timestamp back
# and feeds it to the generator via $VEX_TIMESTAMP. The comparison is then a
# key-sorted (jq -S) semantic diff, so only a real content change between
# .trivyignore.yaml and vex.openvex.json fails the check -- never formatting or
# a fresh wall-clock timestamp.
set -euo pipefail

committed="${1:-vex.openvex.json}"
trivyignore="${2:-.trivyignore.yaml}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$committed" ]; then
  echo "::error::$committed is missing. Generate it with: bash scripts/generate-vex.sh > $committed" >&2
  exit 1
fi

committed_ts="$(jq -r '.timestamp // empty' "$committed")"
if [ -z "$committed_ts" ]; then
  echo "::error::$committed has no top-level .timestamp; cannot reproduce it deterministically." >&2
  exit 1
fi

regenerated="$(VEX_TIMESTAMP="$committed_ts" bash "$script_dir/generate-vex.sh" "$trivyignore")"

if ! diff -u \
    <(jq -S . "$committed") \
    <(printf '%s\n' "$regenerated" | jq -S .) >/tmp/vex-drift.diff 2>&1; then
  echo "::error::$committed is out of sync with $trivyignore." >&2
  echo "Regenerate it with:" >&2
  echo "  bash scripts/generate-vex.sh > $committed" >&2
  echo "Difference (committed vs. regenerated):" >&2
  cat /tmp/vex-drift.diff >&2
  exit 1
fi

echo "$committed is in sync with $trivyignore."
