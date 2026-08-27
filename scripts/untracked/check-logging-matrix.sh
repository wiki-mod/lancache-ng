#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Enforces that docs/architecture-ng.md's logging-matrix table (the
# maintained, authoritative statement of intent for #453's central
# syslog-ng/fluent-bit logging pipeline, see issue #633) never drifts apart
# from the real set of Compose services -- in either direction:
#   1. every real service in dev/prod/quickstart must have a matrix row, so
#      a newly added container can't ship without a declared logging path
#      (this is explicitly called out as a still-missing guard in
#      docs/architecture-ng.md's "Not implemented yet" list); and
#   2. every matrix row must correspond to a real service, so a renamed or
#      removed service can't leave a stale row behind.
#
# This intentionally does NOT check *how* a service is wired (that's a
# human judgment call recorded in the "Logging path" column, not something
# worth encoding as a second source of truth) -- only that a row exists at
# all. A service is free to have a "Not yet wired" row; it just cannot have
# no row.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
cd "$repo_root"

ARCHITECTURE_DOC=docs/architecture-ng.md

# deploy/full-setup (a CI-only harness) and deploy/secondary (generated per
# remote host, not part of this trust boundary) are the same documented
# exceptions scripts/untracked/check-naming-consistency.sh already carves out for its
# own Compose-file sweep. deploy/full-setup additionally never runs the
# `logging` profile at all today, so it has no fluent-bit/syslog-ng services
# to check in the first place.
COMPOSE_FILES=(deploy/prod/docker-compose.yml deploy/quickstart/docker-compose.yml)

failures=0

fail() {
  printf '::error::%s\n' "$1" >&2
  failures=$((failures + 1))
}

# --- Canonical set: parsed from the matrix table in architecture-ng.md ---
# The table's "Service" column sometimes names the Compose service directly
# (e.g. "dns-standard") and sometimes annotates it (e.g. "proxy (nginx)" or
# "fluent-bit (`syslog`)"), because the table is written for human readers
# first. Normalize both annotation styles down to the real Compose service
# name: a backtick-quoted override wins if present (it's the deliberate
# "the real name is different from the prose label" case), otherwise a
# trailing " (...)" parenthetical is stripped as pure human-readable gloss.
#
# This whole extraction runs as a single awk process rather than the
# previous "awk | sed | cut | sed | while read (grep|sed per row)" chain.
# That chain forked roughly 3 short-lived processes per table row. CI on
# this project's shared self-hosted runners hit a real flake traced to this
# script: two back-to-back v0.2.0 CI runs against byte-identical
# docs/architecture-ng.md and scripts/untracked/check-logging-matrix.sh content
# (commits c4e7ac9d then 9eef5d46, ~18 minutes apart, same build-tools
# image digest) produced "OK" and then a false "syslog-ng has no row"
# failure respectively, with no code change in between; re-running the
# second (failing) job against the same unmodified commit later passed
# with no changes at all, confirming it was a flake rather than a
# deterministic defect (see issue #633's comment history for the full
# reproduction). The leading hypothesis -- not proven, since the flake did
# not recur under direct local reproduction -- is a fork/exec hiccup
# silently dropping one row's output inside the old "while read" loop
# body, which `set -e`/`pipefail` cannot catch because the loop's own exit
# status is unaffected by an internal command failing partway through one
# iteration. Doing the whole per-row normalization inside one awk program
# removes that fork storm outright, and turns a failure of the awk process
# itself into a loud, `set -e`-triggered abort instead of a silently short
# result. The row-count assertion in the END block below additionally
# catches a distinct, narrower failure mode: two differently-worded rows
# that normalize to the same canonical name (a genuine duplicate/collapsed
# row). It does not, by itself, prove every possible silent-row-loss cause
# (e.g. a truncated read of $ARCHITECTURE_DOC would still show matching
# data-row and unique-name counts) -- it is defense in depth for one
# specific class of drift, not a guarantee against this exact flake
# recurring.
canonical_raw=$(awk '
  /\*\*Logging matrix\*\*/ { seen_marker = 1; next }
  seen_marker && /^\|/ {
    rows_seen = 1
    if ($0 ~ /^\|[[:space:]]*Service[[:space:]]*\|/) next
    if ($0 ~ /^\|[[:space:]]*-+[[:space:]]*\|/) next

    line = $0
    sub(/^\|[[:space:]]*/, "", line)
    n = split(line, parts, "|")
    cell = (n >= 1) ? parts[1] : ""
    sub(/[[:space:]]+$/, "", cell)

    name = cell
    if (match(cell, /`[a-z0-9-]+`/)) {
      name = substr(cell, RSTART + 1, RLENGTH - 2)
    } else {
      sub(/[[:space:]]*\([^)]*\)[[:space:]]*$/, "", name)
    }

    data_rows++
    if (!(name in seen)) {
      seen[name] = 1
      print name
    }
    next
  }
  # The marker line and the table itself are separated by a blank line in
  # the source Markdown -- only treat a non-"|" line as "table is over" once
  # actual "|"-prefixed rows have been seen, so that blank line does not
  # prematurely end the scan before a single row was read.
  seen_marker && rows_seen && !/^\|/ { exit }
  END {
    unique_count = 0
    for (k in seen) unique_count++
    print "##ROWS## " data_rows " " unique_count
  }
' "$ARCHITECTURE_DOC")

row_summary=$(printf '%s\n' "$canonical_raw" | grep -E '^##ROWS## ' || true)
canonical_services=$(printf '%s\n' "$canonical_raw" | grep -vE '^##ROWS## ' | sort -u)
raw_row_count=$(printf '%s\n' "$row_summary" | awk '{print $2}')
unique_row_count=$(printf '%s\n' "$row_summary" | awk '{print $3}')

if [ -z "$canonical_services" ]; then
  fail "Could not parse any rows out of $ARCHITECTURE_DOC's logging matrix table (expected a '**Logging matrix**' marker followed by a Markdown table)."
elif [ -n "$raw_row_count" ] && [ -n "$unique_row_count" ] && [ "$unique_row_count" -lt "$raw_row_count" ]; then
  fail "Parsed only $unique_row_count unique service name(s) out of $raw_row_count row(s) in $ARCHITECTURE_DOC's logging matrix table -- a row was silently dropped or collapsed during parsing (this can also happen transiently under CI resource pressure; re-run first, and if it persists, check for a genuine duplicate row before assuming the parser itself regressed)."
fi

service_in_canonical() {
  local name="$1"
  # Here-string, not `printf ... | grep -qxF`: this file sets `pipefail`, and
  # a live pipe into an early-exiting `grep -q` can SIGPIPE even from a
  # captured-variable producer (proven empirically, issue #1377) -- a
  # here-string has no second writer process to race.
  grep -qxF "$name" <<<"$canonical_services"
}

# --- Consumer set: real services from `docker compose config --services` --
# Robust against false positives a raw grep over the YAML would hit (a
# `networks:`/`volumes:` key that happens to look like a service name), and
# against false negatives from a service hidden behind an inactive profile.
all_consumer_services=""

for compose_file in "${COMPOSE_FILES[@]}"; do
  # Discover this file's own profile names via `config --profiles` instead
  # of a hand-maintained list: `docker compose config --services` silently
  # omits a service whose profile isn't activated, so every profile the
  # file declares must be passed to see the *full* service set it can
  # produce. A fixed list would drift the moment a new profile is added to
  # any of the 3 Compose files without also updating this script -- which
  # is exactly the kind of new-profiled-service-with-no-matrix-row drift
  # this guard exists to catch, so deriving the list keeps it self-updating.
  profiles=$(docker compose -f "$compose_file" config --profiles 2>&1) \
    || { fail "docker compose config --profiles failed for $compose_file: $profiles"; continue; }

  profile_flags=()
  while IFS= read -r profile; do
    [ -n "$profile" ] || continue
    profile_flags+=(--profile "$profile")
  done <<<"$profiles"

  services=$(docker compose -f "$compose_file" "${profile_flags[@]}" config --services 2>&1) \
    || { fail "docker compose config --services failed for $compose_file: $services"; continue; }

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! service_in_canonical "$name"; then
      fail "$compose_file defines service '$name', which has no row in $ARCHITECTURE_DOC's logging matrix table -- add one (even 'Not yet wired' with a tracking issue is fine, an absent row is not)."
    fi
  done <<<"$services"

  all_consumer_services="$all_consumer_services
$services"
done

all_consumer_services=$(printf '%s\n' "$all_consumer_services" | sed '/^$/d' | sort -u)

service_is_consumer() {
  local name="$1"
  # Here-string, not a live pipe -- same pipefail/SIGPIPE reasoning as
  # service_in_canonical() above (issue #1377).
  grep -qxF "$name" <<<"$all_consumer_services"
}

while IFS= read -r name; do
  [ -n "$name" ] || continue
  if ! service_is_consumer "$name"; then
    fail "$ARCHITECTURE_DOC's logging matrix table has a row for '$name', which is not a real Compose service in any of ${COMPOSE_FILES[*]} -- remove the stale row or fix the name."
  fi
done <<<"$canonical_services"

# --- Netdata web_log job-config parity (#849 bug-hunt finding
# observability.md#16) -----------------------------------------------------
# This is a DIFFERENT kind of check from everything above, and deliberately
# so: the matrix-row check's own header explicitly disclaims checking *how*
# a service is wired ("that's a human judgment call ... not something worth
# encoding as a second source of truth") -- a generic prod-vs-quickstart
# config-block diff would contradict that design stance. This check does not
# do that; it verifies one narrow, already-self-declared invariant instead.
# `deploy/prod`/`deploy/quickstart` bind-mount netdata's web_log collector
# config from services/syslog/netdata-web_log.conf directly (a real file,
# always in sync with itself by construction), but quickstart generates its
# OWN inline copy of that exact same job config in its `netdata:` service's
# `command:` heredoc, because quickstart's install_dir has no services/
# directory to bind-mount from (see that heredoc's own comment). That
# heredoc's comment already states the actual contract in prose: "Keep this
# content byte-identical to services/syslog/netdata-web_log.conf if that
# file ever changes" -- this section enforces that stated contract
# mechanically instead of relying on whoever next edits the real file to
# remember it. This is not a new source of truth invented here; it is the
# existing comment's own promise, made self-enforcing. Confirmed via a real
# incident this check would have caught: the real file's `log_type: nginx`
# field was removed 2026-07-31 after it caused netdata's web_log job to fail
# outright ("check failed: failed to create parser") on the pinned image,
# but quickstart's independent inline copy kept the stale, broken field
# until this check was added -- prod (bind-mounting the real file) picked up
# the fix automatically; quickstart silently did not.
WEB_LOG_CONF=services/syslog/netdata-web_log.conf
QUICKSTART_COMPOSE=deploy/quickstart/docker-compose.yml

if [ ! -f "$WEB_LOG_CONF" ]; then
  fail "$WEB_LOG_CONF does not exist -- cannot verify quickstart's inline netdata web_log job config against it."
elif [ ! -f "$QUICKSTART_COMPOSE" ]; then
  fail "$QUICKSTART_COMPOSE does not exist -- cannot verify its inline netdata web_log job config."
else
  # The real file's actual go.d job config starts at its own `jobs:` line
  # (everything above is header/rationale comments, which quickstart's
  # inline copy intentionally does not duplicate).
  real_web_log_jobs=$(awk '/^jobs:/{flag=1} flag{print}' "$WEB_LOG_CONF")
  # Quickstart's heredoc body, with its fixed 8-space YAML block-scalar
  # indent stripped so the comparison is content-for-content, not
  # indentation-for-indentation.
  quickstart_web_log_jobs=$(awk '
    /cat > \/etc\/netdata\/go\.d\/web_log\.conf <<.CONF./ { capture = 1; next }
    capture && /^        CONF$/ { capture = 0 }
    capture { print }
  ' "$QUICKSTART_COMPOSE" | sed 's/^        //')

  if [ -z "$real_web_log_jobs" ]; then
    fail "$WEB_LOG_CONF has no 'jobs:' section -- cannot verify quickstart's inline copy against it (did the real file's structure change?)."
  elif [ -z "$quickstart_web_log_jobs" ]; then
    fail "$QUICKSTART_COMPOSE's netdata service has no 'cat > /etc/netdata/go.d/web_log.conf <<...CONF ... CONF' heredoc to extract -- did its shape change? Update this script's extraction alongside it."
  elif [ "$real_web_log_jobs" != "$quickstart_web_log_jobs" ]; then
    fail "$QUICKSTART_COMPOSE's inline netdata web_log job config has drifted from $WEB_LOG_CONF -- that heredoc's own comment says to keep it byte-identical. Real file:
--- $WEB_LOG_CONF ---
$real_web_log_jobs
--- $QUICKSTART_COMPOSE (inline, indent-stripped) ---
$quickstart_web_log_jobs
--- end ---"
  fi
fi

if [ "$failures" -gt 0 ]; then
  printf '::error::check-logging-matrix: %d logging-matrix drift issue(s) found (see docs/architecture-ng.md and issue #633).\n' "$failures" >&2
  exit 1
fi

printf 'check-logging-matrix: OK (every Compose service has a logging-matrix row, every row names a real service, and quickstart'"'"'s inline netdata web_log job config matches services/syslog/netdata-web_log.conf).\n'
