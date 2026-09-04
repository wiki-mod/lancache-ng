#!/bin/sh
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: verifies a copied tool's version banner has a marker.
# Why: exec-time failures surface only when the tool runs.
# From: Issue #1613

set -eu

if [ "$#" -lt 2 ]; then
  printf '%s\n' "usage: verify-version-banner.sh <expected-substring> <command> [args...]" >&2
  exit 2
fi

expected="$1"
shift
cmd="$1"
shift

# Step: run the tool, ignoring its own exit code (see header Why above).
out="$("$cmd" "$@" 2>&1)" || true

case "$out" in
  *"$expected"*) exit 0 ;;
  *)
    printf '%s\n' "ERROR: $cmd did not report its expected banner ('$expected'): $out" >&2
    exit 1
    ;;
esac
