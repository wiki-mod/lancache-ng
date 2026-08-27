#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# Generator smoke test for the OpenVEX document (OSPS-VM-04.02).
#
# What: Runs scripts/tracked/generate-vex.sh against .trivyignore.yaml and
# asserts the output is valid JSON (`jq empty`). Nothing more.
#
# Why: vex.openvex.json is no longer committed to current_dev -- it used to
# be a second, independently-editable copy kept in sync with
# .trivyignore.yaml only by a human/agent remembering to re-run the
# generator in the same commit, which produced two real drift incidents on
# the same branch (see this repo's AGENTS.md AG-WF-025 note).
# Removing the committed copy removes the drift failure class itself -- there
# is no second copy left to compare against. What can still break is the
# generator: a syntax error in .trivyignore.yaml, or a bug introduced into
# generate-vex.sh, would otherwise only surface when the dedicated
# `vex-regenerate.yml` workflow runs after merge to current_dev, or worse,
# not until a release tag's own regeneration step (build-push.yml's "Attach
# OpenVEX document to the release") fails during an actual release. This
# script exists so a broken generator is caught in the PR that broke it
# (wired into validate-compose, triggered when .trivyignore.yaml OR
# generate-vex.sh itself changes -- a broken generator is a real problem even
# without a data change), not first discovered post-merge or at release time.
#
# From: Issue #1095 (F-22) | PR #1620 (superseded drift-comparison version)
set -euo pipefail

trivyignore="${1:-.trivyignore.yaml}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

output="$(bash "$script_dir/../untracked/generate-vex.sh" "$trivyignore")"

if ! jq empty <<<"$output" 2>/tmp/vex-smoke.err; then
  echo "::error::scripts/tracked/generate-vex.sh produced invalid JSON for $trivyignore." >&2
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
