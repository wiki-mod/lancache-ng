#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# Generator smoke test for the OpenVEX document (OSPS-VM-04.02).
#
# What: Validates vex JSON generation against .trivyignore.yaml
# Why: Catch generator bugs early (before post-merge discovery).
# From: Issue #1095 | PR #1620
set -euo pipefail

trivyignore="${1:-.trivyignore.yaml}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

output="$(bash "$script_dir/../untracked/generate-vex.sh" "$trivyignore")"

if ! jq empty <<<"$output" 2>/tmp/vex-smoke.err; then
  echo "::error::scripts/untracked/generate-vex.sh produced invalid JSON for $trivyignore." >&2
  cat /tmp/vex-smoke.err >&2
  exit 1
fi

# A generator that silently emits an empty statement list on real
# .trivyignore.yaml content is also broken, just not in a way `jq empty`
# alone would catch (empty statements is syntactically valid JSON).
entry_count="$(grep -c '^  - id:' "$trivyignore" || true)"
statement_count="$(jq '.statements | length' <<<"$output")"
if [ "$entry_count" -gt 0 ] && [ "$statement_count" -eq 0 ]; then
  echo "::error::$trivyignore has $entry_count entries but generate-vex.sh produced 0 statements." >&2
  exit 1
fi

echo "generate-vex.sh produces valid OpenVEX JSON for $trivyignore ($statement_count statement(s))."
