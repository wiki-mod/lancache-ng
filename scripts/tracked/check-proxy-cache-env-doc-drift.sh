#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# CI guard for bug-hunt #849/#1068 item 11: docs/architecture-ng.md's nginx
# cache-configuration table hand-duplicates each CACHE_* variable's default
# value as a literal string, with nothing that ever checked it against the
# real shipped default in config/prod/proxy.env. This is the same failure
# class as scripts/untracked/check-setup-prompt-drift.sh (#1176) and
# scripts/untracked/check-naming-consistency.sh -- a fact hand-copied into
# documentation silently drifts once the real value changes elsewhere. This
# specific incident already happened: CACHE_MEM_MB's documented default was
# `200`, while the real shipped default (config/prod/proxy.env,
# deploy/quickstart/.env, setup.sh) had been `512` since the variable was
# introduced 2026-06-18/19 -- a ~7-week-old, unnoticed drift, per AG-VAL-029's
# requirement that a confirmed real defect get a durable, repeatable check
# rather than only a point fix.
#
# What this checks: for every `CACHE_*=value` line in config/prod/proxy.env
# (the authoritative shipped default, per docs/architecture-ng.md's own
# "Cache configuration (env vars set at setup.sh install time...)" framing),
# if docs/architecture-ng.md's nginx cache-configuration table has a row for
# that same variable name, its documented default value must match the real
# one exactly. A variable with no matching table row is not an error here --
# not every CACHE_* variable is necessarily meant to have a documentation
# table row -- this only catches a row that exists and disagrees with reality.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
proxy_env="$repo_root/config/prod/proxy.env"
arch_doc="$repo_root/docs/architecture-ng.md"

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    NC=''
fi

violations=0
fail() {
    printf "%b[PROXY CACHE ENV DOC DRIFT]%b %s\n" "$RED" "$NC" "$1" >&2
    violations=$((violations + 1))
}

scanned=0
checked=0
# Only plain, uncommented KEY=value lines for CACHE_* variables -- deliberately
# narrow to this project's own established naming convention, not a generic
# .env parser, since proxy.env also carries non-cache settings (resolver,
# security mode, CIDR allowlist) this check has no doc-table equivalent for.
while IFS='=' read -r key value; do
    [[ "$key" =~ ^CACHE_[A-Z_]+$ ]] || continue
    scanned=$((scanned + 1))

    # docs/architecture-ng.md's table format is exactly
    # "| `CACHE_MEM_MB` | `512` | description text |" -- extract the second
    # backtick-quoted cell on the matching row.
    doc_row="$(grep -E "^\| \`${key}\` \|" "$arch_doc" || true)"
    if [[ -z "$doc_row" ]]; then
        # No table row for this variable -- not this check's concern (see
        # header comment). CACHE_MEM_MB/CACHE_MAX_SIZE/CACHE_MIN_FREE/
        # CACHE_SLICE_SIZE/CACHE_VALID_HIT/CACHE_VALID_ANY/CACHE_INACTIVE are
        # the variables actually documented as of this writing; a future
        # CACHE_* addition without a doc row simply isn't checked until one
        # is added.
        continue
    fi
    checked=$((checked + 1))

    documented_value="$(printf '%s' "$doc_row" | sed -E 's/^\| `[A-Z_]+` \| `([^`]*)` \|.*/\1/')"
    if [[ "$documented_value" != "$value" ]]; then
        fail "config/prod/proxy.env sets $key=$value, but docs/architecture-ng.md's cache-configuration table documents its default as \`$documented_value\` -- update whichever one is stale."
    fi
done < <(grep -E '^CACHE_[A-Z_]+=' "$proxy_env")

if [[ "$violations" -gt 0 ]]; then
    printf "%b✗ %d proxy cache env/doc drift finding(s) found.%b See bug-hunt #849/#1068 item 11.\n" "$RED" "$violations" "$NC" >&2
    exit 1
fi

printf "%b✓ %d of %d CACHE_* variable(s) in config/prod/proxy.env have a docs/architecture-ng.md table row, and all of them match its real shipped default.%b\n" "$GREEN" "$checked" "$scanned" "$NC"
exit 0
