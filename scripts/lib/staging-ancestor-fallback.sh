#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Shared recovery path for the untouched-service back-fill's PR base commit
# freshness wait: a PR's base commit can be one that build-push.yml's own
# `push` trigger `paths-ignore` deliberately never builds (a docs/governance-
# only commit). When that happens, the base commit's own per-commit image can
# never appear no matter how long the freshness wait runs, so this file adds
# a narrow, provably-safe fallback that walks the base commit's own ancestor
# history for the nearest commit that both has a real build and a freshness-
# confirmed per-commit image, and substitutes THAT ancestor's own immutable
# per-commit tag for the back-fill -- never falling back to the mutable
# nightly/latest channel, matching the fail-closed design
# scripts/lib/staging-image-freshness.sh's own header already documents.
#
# Sourced by scripts/tracked/ensure-pr-staging-images.sh and by build-push.yml's
# "Ensure PR staging tags exist for full-setup services" step, so the two
# independent copies this recovery path used to require stay a single
# implementation instead of drifting -- same reasoning, and the same
# sourcing convention, as scripts/lib/validation-image-tag.sh's own
# SOURCE OF TRUTH note.
#
# Depends on scripts/lib/staging-image-freshness.sh (sif_wait_for_fresh_base_image,
# for the actual per-commit freshness proof) and scripts/lib/ghcr-retry.sh
# (a generic retry loop this file reuses for the GitHub Actions API query
# below, not just GHCR registry operations -- see saf_query_run_count's own
# comment for why reusing that exact function, rather than writing a second
# near-identical retry loop, is the right call here). Callers must source
# both of those files before this one.
#
# Deliberately NOT `set -euo pipefail` at the top level, for the same reason
# ghcr-retry.sh/staging-image-freshness.sh aren't: this file only defines
# functions for a caller to invoke under the caller's own shell options.

# Process-lifetime cache for saf_find_built_ancestor's own per-candidate run
# lookups (see that function's own comment at its one read/write site for the
# full reasoning): a long docs-only chain means every untouched service's own
# call re-walks the SAME candidate commits and would otherwise re-query the
# SAME (repository, candidate) run-existence fact from scratch every time --
# a fact that cannot change mid-job, so repeating the query is pure waste
# against a shared, repository-scoped GitHub API rate limit.
#
# Deliberately a DIRECTORY OF FILES, not a shell associative array: both real
# callers (scripts/tracked/ensure-pr-staging-images.sh, build-push.yml's own step)
# invoke saf_resolve_untouched_backfill_source via
# `resolved_source="$(saf_resolve_untouched_backfill_source ...)"` once per
# service, inside a loop -- and `$(...)` command substitution ALWAYS forks a
# subshell in bash. An in-memory associative array populated inside that
# subshell (by saf_find_built_ancestor, called from deep inside that same
# `$(...)`) only ever exists in the subshell's own memory and is gone the
# instant that subshell exits and the loop moves to the next service -- an
# array-based cache would therefore never actually share anything across
# services in real production use, even though it can look like it works in
# a test that happens not to go through the same subshell-forking call
# shape (caught live while writing this file's own bats coverage: two
# `run`-wrapped calls -- `run` also forks a subshell for the same reason --
# could not observe the array-based version's cache hits at all). A real
# file on disk, by contrast, is written by one subshell and later read by a
# completely different (sibling) subshell without issue, since subshells
# share the same filesystem even though they don't share each other's
# in-memory shell state.
#
# The directory path itself is established ONCE, right here, at the moment
# this file is FIRST sourced -- which for both real callers happens directly
# in the top-level script process, before any subshell has been forked yet
# (the `for service in ...` loop that later forks one via `$(...)` per
# service comes afterward). `export`ing it here means every later subshell
# (no matter how deeply nested inside saf_resolve_untouched_backfill_source ->
# saf_find_built_ancestor -> ...) inherits the SAME value and therefore
# agrees on the SAME cache directory, even though none of them can see each
# other's own shell-variable writes. `mktemp -d` (not a fixed, predictable
# path) keeps two independent script runs on the same long-lived self-hosted
# runner host from ever colliding on the same directory; `:-}` guards against
# re-running this block if the file is somehow sourced twice in the same
# process (keep the first directory rather than silently orphaning it and
# starting a second, empty one).
#
# mktemp's own uniqueness means these never collide with a previous run's
# directory, but on a long-lived self-hosted runner "unique" is exactly what
# makes an ENTIRELY UNCLEANED directory a real, unbounded accumulation
# problem rather than a self-limiting one: every process that ever sources
# this file would otherwise leave its own never-reused directory behind
# forever, across every run the runner ever does.
#
# TWO independent defences, because neither alone is sufficient:
#
#   1. The parent directory is `$RUNNER_TEMP` when GitHub Actions sets it
#      (both real callers run as Actions steps, where it always is). Actions
#      wipes `RUNNER_TEMP` itself between jobs, so anything under it is
#      reclaimed even when this process never gets to run a single line of
#      its own cleanup -- the SIGKILL case a trap fundamentally cannot cover,
#      and exactly what a job-level `timeout-minutes` expiry does to a step
#      that overruns it. `${TMPDIR:-/tmp}` remains the fallback for a plain
#      local/bats invocation outside Actions.
#   2. An EXIT trap for the ordinary path (normal exit, and -- verified on
#      bash 5.2, the pinned build-tools image's version -- SIGINT/SIGTERM
#      with no explicit handler of their own, where bash still runs the EXIT
#      trap before dying).
#
# The trap must not be a bare `trap ... EXIT` (this is a sourced library, not
# the top-level script): registering one unconditionally would silently
# DISCARD any EXIT trap the caller had already set, since bash's `trap`
# replaces whatever was previously registered for a signal. So whatever EXIT
# trap is active at the moment this file is FIRST sourced is captured and
# re-invoked from a combined trap.
#
# SCOPE OF THAT COMPOSITION, stated honestly rather than overclaimed: it
# composes with a trap the caller registered BEFORE sourcing this file, and
# nothing else. A caller that registers its own EXIT trap AFTER the `source`
# line -- the more usual ordering, since scripts tend to source at the top
# and set traps later -- still replaces this combined trap outright, and this
# file has no way to detect or prevent that. Defence 1 above is what actually
# holds in that case. No caller in this repository registers an EXIT trap at
# all today (checked: scripts/tracked/ensure-pr-staging-images.sh, scripts/lib/
# ghcr-retry.sh, scripts/lib/staging-image-freshness.sh, scripts/lib/
# validation-image-tag.sh, and build-push.yml's own inline step), so the
# composition path is currently unexercised in production; it exists so a
# future caller that does set one before sourcing does not silently lose it.
#
# ORDER -- prior trap FIRST, cleanup SECOND -- is load-bearing, not cosmetic.
# `$?` on entry to an EXIT trap is the script's own real exit status, and a
# prior trap reading it (to log or propagate a genuine failure, a common CI
# pattern) must see that value. Running the cleanup first would overwrite
# `$?` with the cleanup's own successful `rm`, handing the prior trap a false
# "0" for a real failure. Restoring it afterwards is not an option: the only
# way to force `$?` back to a non-zero value is to run a command that fails,
# and under the `set -e` BOTH real callers use, a failing command inside a
# trap body aborts the trap immediately -- so the prior trap would not run at
# all, which is strictly worse than running with a wrong `$?`. (Both of those
# are real, reproduced behaviours on bash 5.2, not theory; the second one was
# introduced by an earlier attempt at the first and is why this ordering is
# now the mechanism instead of a save/restore dance.) Putting the prior trap
# first gets the correct `$?` for free, with no failing command anywhere in
# this trap's own body.
#
# Residual risk of that ordering, deliberately accepted and not papered over:
# if the prior trap itself exits or dies under `set -e`, this cleanup never
# runs. Neutralising that with `_saf_run_prior_exit_trap || :` would suppress
# `set -e` inside the caller's own trap body, i.e. silently change the
# caller's semantics to protect a temp directory -- the wrong trade. Defence
# 1 covers that case too.
if [[ -z "${SAF_ANCESTOR_RUN_CACHE_DIR:-}" ]]; then
  # A failure here is deliberately non-fatal rather than fail-closed: the
  # cache is a pure API-call optimisation, and every read/write site below is
  # already guarded on this variable being non-empty. Losing it costs
  # redundant GitHub API queries, never correctness -- so a `mktemp` failure
  # (a full or read-only $TMPDIR) must not take down a CI job that would
  # otherwise complete perfectly well without any caching at all. `2>/dev/null
  # || true` keeps that true under the callers' `set -e`.
  SAF_ANCESTOR_RUN_CACHE_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/saf-ancestor-run-cache.XXXXXX" 2>/dev/null || true)"
  if [[ -n "$SAF_ANCESTOR_RUN_CACHE_DIR" ]]; then
    _saf_prior_exit_trap_line="$(trap -p EXIT)"
    if [[ -n "$_saf_prior_exit_trap_line" ]]; then
      # trap -p EXIT prints: trap -- '<command>' EXIT, where '<command>' is
      # ALREADY a single, correctly bash-quoted word -- any single quote
      # <command> itself contains is represented using bash's own '\''
      # escaping convention. Naively slicing off just the outer quote
      # CHARACTERS leaves that internal '\'' escaping un-decoded, corrupting
      # <command> the moment it contains an embedded quote (e.g. a prior trap
      # running `printf "%s" "it's ok"` would silently become `it'\''s ok`
      # once re-embedded that way). Stripping the fixed "trap -- "/" EXIT"
      # wrapper textually is still safe (neither ever appears as <command>'s
      # own data, only at these fixed positions in trap -p's own output
      # format), but recovering <command> itself needs bash's OWN quote
      # removal, not manual slicing. Hence `eval`: it defines a wrapper
      # function whose stored body is `eval '<still-quoted word>'`, and
      # invoking that wrapper later performs the quote removal and re-parses
      # <command> exactly as originally registered.
      _saf_prior_exit_trap_line="${_saf_prior_exit_trap_line% EXIT}"
      _saf_prior_exit_trap_line="${_saf_prior_exit_trap_line#trap -- }"
      eval "_saf_run_prior_exit_trap() { eval ${_saf_prior_exit_trap_line}; }"
    else
      _saf_run_prior_exit_trap() { :; }
    fi
    _saf_cleanup_ancestor_run_cache_dir() {
      rm -rf "$SAF_ANCESTOR_RUN_CACHE_DIR" 2>/dev/null || true
    }
    trap '_saf_run_prior_exit_trap; _saf_cleanup_ancestor_run_cache_dir' EXIT
    unset _saf_prior_exit_trap_line
  fi
fi
export SAF_ANCESTOR_RUN_CACHE_DIR

# _saf_mktemp_body_file
#
# Internal helper: allocates the scratch file the GitHub API helpers below
# write a response body into. Placed INSIDE $SAF_ANCESTOR_RUN_CACHE_DIR
# whenever that exists, so the single `rm -rf` in the EXIT trap above (and
# `RUNNER_TEMP`'s own between-jobs wipe) reclaims every one of them together,
# instead of each call site's own `rm -f` being the only thing standing
# between a killed process and an orphaned file on a long-lived runner. Falls
# back to a plain `mktemp` when the cache directory could not be created --
# the same "the optimisation is optional, the query is not" posture as the
# cache itself.
_saf_mktemp_body_file() {
  if [[ -n "${SAF_ANCESTOR_RUN_CACHE_DIR:-}" ]]; then
    mktemp "${SAF_ANCESTOR_RUN_CACHE_DIR}/body.XXXXXX" 2>/dev/null && return 0
  fi
  mktemp
}

# _saf_ancestor_run_cache_key_to_path <repository> <candidate>
#
# Internal helper: turns a (repository, candidate) pair into a filesystem-safe
# path under $SAF_ANCESTOR_RUN_CACHE_DIR. <repository> contains a literal `/`
# (e.g. "wiki-mod/lancache-ng"), which is not a valid bare filename component
# on its own -- replace it with `_` (repository names and commit SHAs never
# contain `_` in a way that could collide with this substitution in practice
# for this project's own real values) rather than nesting an actual
# subdirectory per repository, which would need its own `mkdir -p` at every
# read AND write site for no benefit here (this cache only ever serves one
# repository per process anyway).
_saf_ancestor_run_cache_key_to_path() {
  local repository="$1" candidate="$2"
  printf '%s/%s__%s\n' "$SAF_ANCESTOR_RUN_CACHE_DIR" "${repository//\//_}" "$candidate"
}

# saf_paths_are_ignorable <newline-separated-paths>
#
# Pure function: returns 0 if every path in the given newline-separated list
# matches build-push.yml's own `push` trigger `paths-ignore` patterns
# (`**/*.md`, `docs/**`, with `CHANGELOG.md` explicitly un-ignored -- mirrors
# that trigger's own `paths-ignore:` block exactly; keep both in sync by hand
# if that block ever changes). Returns 1 if any path does not match (a real,
# non-doc change was present). An empty input list is NOT treated as
# "everything ignorable" -- it returns 1, since an empty diff most likely
# means the diff itself could not be computed (see saf_base_commit_diff_paths
# below), and this function has no way to distinguish "genuinely zero
# changed paths" from "diff failed silently" -- callers that already know
# the diff succeeded and legitimately found zero paths should not call this
# function with an empty string in the first place.
saf_paths_are_ignorable() {
  local paths="$1"
  if [[ -z "$paths" ]]; then
    return 1
  fi
  local path
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    # `!CHANGELOG.md`: explicitly un-ignored by build-push.yml's own
    # paths-ignore block (so its own shellcheck/PR-body-scan guardrails still
    # see a CHANGELOG-only push) -- a change here is never a safe "deliberate
    # skip" signal on its own.
    if [[ "$path" == "CHANGELOG.md" ]]; then
      return 1
    fi
    # `**/*.md`: any path ending in .md, at any depth.
    if [[ "$path" == *.md ]]; then
      continue
    fi
    # `docs/**`: any path under a top-level docs/ directory.
    if [[ "$path" == docs/* ]]; then
      continue
    fi
    return 1
  done <<< "$paths"
  return 0
}

# saf_base_commit_diff_paths <sha> [git_dir]
#
# Echoes the newline-separated list of paths <sha> changed relative to its
# FIRST parent (`git diff-tree --no-commit-id --name-only -r <sha>^1 <sha>`),
# or returns non-zero with no output if <sha> has no parent (a root commit)
# or the diff otherwise fails. Using the first parent specifically (not a
# plain two-argument diff against every parent, and not `git show`'s default
# combined-diff behavior for a merge commit) matters because this project
# does not squash-merge: a PR merge commit's first parent is the target
# branch's own tip immediately before that merge landed, so this is "what did
# this push actually introduce relative to the branch's prior state" -- the
# same question GitHub's own `paths-ignore` evaluation answers for a push
# event. A second/later parent is the merged-in feature branch's own tip,
# which is not what either "should this push have been skipped" or
# "what commit represents the target branch just before this one" mean.
saf_base_commit_diff_paths() {
  local sha="${1:?saf_base_commit_diff_paths: sha is required}"
  local git_dir="${2:-.}"
  git -C "$git_dir" diff-tree --no-commit-id --name-only -r "${sha}^1" "$sha" 2>/dev/null
}

# saf_base_commit_paths_are_ignorable <sha> [git_dir]
#
# Answers "did <sha> only change paths build-push.yml's own push trigger
# would skip?" -- the missing half of the "was this commit deliberately
# skipped, or did it just never get a chance to build" question. A confirmed
# absence of any push-triggered run (saf_base_commit_has_confirmed_run below)
# is NOT enough on its own to unlock the ancestor fallback: it proves GitHub
# never created a run, but not that the commit's own changed paths actually
# matched the ignore list. If build-push.yml's `push` trigger were ever
# temporarily disabled while a real, service-changing commit landed and was
# later re-enabled, a bare "zero runs" reading would misidentify that outage
# as a deliberate skip and back-fill an untouched service from a stale
# ancestor -- silently validating content that omits the real base change.
# This is exactly the #626/#808 class of bug the whole ancestor-fallback
# mechanism must not reintroduce, so this positive path-level confirmation is
# a hard requirement before any caller treats "zero runs" as safe to act on.
#
# Returns 0 if every changed path matches the ignore patterns (a genuine
# deliberate-skip candidate) -- INCLUDING a commit that genuinely changed
# nothing at all (e.g. a real `git commit --allow-empty`): such a commit has
# no changed path that could possibly violate the ignore list, so it
# vacuously qualifies, and by construction can never trigger build-push.yml's
# path-filtered push workflow either, matching the "zero runs" reading
# exactly. Returns 1 if at least one path does not (a real change was present
# -- the confirmed-zero-runs reading must NOT be trusted; callers must treat
# this the same as "a run exists", i.e. no fallback). Returns 2 if the diff
# itself genuinely could not be computed (a root commit with no parent to
# diff against, a missing object, or any other real `git diff-tree` failure)
# -- also NOT safe to unlock the fallback on, for the same "can't prove it,
# don't act on it" reasoning saf_base_commit_has_confirmed_run's own header
# documents for its own inconclusive case.
#
# Distinguishing "genuinely zero changed paths" (safe, case 0 above) from "the
# diff command itself failed" (unsafe, case 2 above) requires checking
# saf_base_commit_diff_paths's own real exit status, NOT just whether its
# stdout happens to be empty -- both a root commit (no `sha^1` to diff
# against, a real git failure, empty stdout) and a genuine empty commit (a
# valid, successful diff that simply found no differences, also empty
# stdout) produce IDENTICAL empty output -- treating both as inconclusive
# would wrongly treat an unambiguously safe, common case (any `--allow-empty`
# commit, including ones this project's own tests construct routinely) the
# same as a genuine git failure -- missing the fast path and forcing a full,
# pointless freshness wait for an image that will never exist for a commit
# that changed nothing.
saf_base_commit_paths_are_ignorable() {
  local sha="${1:?saf_base_commit_paths_are_ignorable: sha is required}"
  local git_dir="${2:-.}"
  local paths diff_status
  paths="$(saf_base_commit_diff_paths "$sha" "$git_dir")"
  diff_status=$?
  if (( diff_status != 0 )); then
    return 2
  fi
  if [[ -z "$paths" ]]; then
    return 0
  fi
  if saf_paths_are_ignorable "$paths"; then
    return 0
  fi
  return 1
}

# saf_base_commit_service_untouched <sha> <classify_key> [git_dir]
#
# Narrower, SERVICE-SCOPED sibling to saf_base_commit_paths_are_ignorable's
# commit-wide "is everything here docs/governance" question. A commit can
# fail that broad check (a real, non-doc change is present) while still
# never touching THIS specific service at all -- e.g. a commit that only
# changes services/ui/ leaves proxy/dns/dhcp/etc. genuinely untouched, and
# build/build-arm64's own per-service matrix condition (the same one
# detect-changes computes) correctly skips them, exactly as it would for a
# docs-only commit. Before this function existed, saf_resolve_untouched_backfill_source
# only recognized the docs/governance case as safe to fall back on, so any
# commit that touched at least one OTHER service (the common case -- most
# commits touch 1-2 services, not all 8) made every OTHER untouched service
# pay the full base_freshness wait for a tag that could never appear, then
# hard-fail with "a push run exists, so this is a real build problem" --
# the wrong verdict for a deliberately-skipped service build. Confirmed live
# 2026-08-02: ui:sha-<commit> never gets created when Step 4 reuses
# ui for a push, for exactly this reason.
#
# Delegates to scripts/tracked/classify-image-impact.sh -- the same single-source-of-
# truth per-service classifier detect-changes and promote's own version-bump
# step already use -- fed via its CHANGED_FILES=<file> input mode with
# saf_base_commit_diff_paths' own already-computed path list, rather than
# re-deriving the diff a second time or hand-rolling a second copy of the
# per-service path-prefix rules here (exactly the kind of drift-prone
# duplication already flagged elsewhere in this pipeline).
#
# Returns 0 if classify-image-impact.sh confirms <classify_key> was NOT
# touched by <sha> itself relative to its own first parent (safe to treat as
# a deliberate, correct build-matrix skip for this service at this commit,
# for any reason -- docs-only, a different-service-only change, or a Step 4
# reuse). Returns 1 if <classify_key> WAS touched (a real service-affecting
# change is present; the base_freshness wait's failure needs a maintainer
# look, not a silent walk-past). Returns 2 if the diff itself could not be
# computed (a root commit, a missing object, or a classify-image-impact.sh
# failure) -- same "can't prove it, don't act on it" posture as
# saf_base_commit_paths_are_ignorable's own case 2.
saf_base_commit_service_untouched() {
  local sha="${1:?saf_base_commit_service_untouched: sha is required}"
  local classify_key="${2:?saf_base_commit_service_untouched: classify_key is required}"
  local git_dir="${3:-.}"
  local paths diff_status
  paths="$(saf_base_commit_diff_paths "$sha" "$git_dir")"
  diff_status=$?
  if (( diff_status != 0 )); then
    return 2
  fi
  if [[ -z "$paths" ]]; then
    return 0
  fi
  local classify_script paths_file classify_output value
  classify_script="$(dirname "${BASH_SOURCE[0]}")/../untracked/classify-image-impact.sh"
  paths_file="$(mktemp)" || return 2
  printf '%s\n' "$paths" > "$paths_file"
  classify_output="$(CHANGED_FILES="$paths_file" bash "$classify_script" 2>/dev/null)"
  local classify_status=$?
  rm -f "$paths_file"
  if (( classify_status != 0 )); then
    return 2
  fi
  # Here-string, not a live pipe into grep -m1 (issue #1377).
  value="$(grep -m1 "^${classify_key}=" <<<"$classify_output" | cut -d= -f2)"
  case "$value" in
    false) return 0 ;;
    true) return 1 ;;
    *) return 2 ;;
  esac
}

# _saf_github_api_get <url> <body_file>
#
# Internal helper: performs the actual HTTP GET and writes the response body
# to <body_file>, returning 0 only for a real HTTP 200. Called via
# ghcr_retry (see saf_query_run_count below) rather than passed bare curl
# directly: curl's OWN exit code stays 0 for a non-2xx HTTP response (only a
# network-level failure -- DNS, connection refused, timeout -- makes curl
# itself fail), so wrapping the status-code check in this function is what
# actually makes ghcr_retry's retry loop retry on a bad response, not just
# on a dropped connection.
#
# --connect-timeout/--max-time (matching the same flags/values reasoning
# scripts/tracked/simulations/ssl-mitm-cache-simulation.sh's own curl_timeouts comment documents
# for the identical hazard): without them, curl has no bound on either
# establishing the connection or on how long a stalled transfer can sit
# there once GitHub has accepted the connection but stops sending data --
# neither case is a curl-level failure on its own, so ghcr_retry's bounded
# retry loop would never even get a chance to run; the whole call (and the
# job around it) would simply hang until GitHub Actions' own job-level
# timeout eventually kills it, defeating this entire file's "bounded and
# reasoned about" design. 10s to establish the connection, 30s total transfer
# time -- generous for these small JSON responses, but still short enough
# that a real stall becomes a retryable failure well within one attempt
# instead of consuming a large fraction of the caller's own job budget.
#
# Deliberately does NOT take the token as a positional argument: ghcr_retry
# logs its own failing command verbatim via `$*` in its ::warning::/::error::
# lines on every failed attempt (see
# scripts/lib/ghcr-retry.sh lines around its retry-exhausted/backoff
# messages) -- a token passed as one of this function's own arguments would
# therefore be echoed into the job log in plain text on every retry, not just
# once. GitHub Actions masks an exact match of `secrets.GITHUB_TOKEN`'s own
# value in its own log viewer, but that masking is a best-effort safety net,
# not something this script should rely on as its only protection: it does
# not help at all when GH_TOKEN is a manually-supplied PAT (a real supported
# case -- neither caller requires GH_TOKEN to be exactly
# secrets.GITHUB_TOKEN), and a masking failure/partial-match on GitHub's side
# is not this script's to gamble with. Reading `$GH_TOKEN` directly from the
# environment here instead keeps it out of `"$@"`/`"$*"` entirely, so it can
# never appear in ghcr_retry's own diagnostic output regardless of how many
# attempts fail.
#
# For the same reason, the Authorization header itself is never passed as a
# literal `-H "Authorization: Bearer <token>"` argument either: curl's own
# argv (the expanded header value included) is visible for the lifetime of
# the curl process to any other process running as the same host user, e.g.
# via /proc/<pid>/cmdline on Linux -- a real exposure on a shared, long-lived
# self-hosted runner, not a hypothetical one, and one GitHub Actions' own log
# masking cannot help with at all since it only ever touches log output,
# never a live process's argv.
#
# A mode-600 temp file passed via `-H @<file>` would get the token out of
# argv, but not out of reach of another process running as the SAME host
# user: file permission bits protect against other USERS, not other
# processes owned by the identical UID, and that same-UID process could
# trivially derive the file's own path from curl's own argv (`-H @<path>`,
# itself still visible via /proc/<pid>/cmdline) and then just open() the file
# directly -- no real improvement against exactly the threat model this
# whole concern is about.
#
# curl's `-K -` (read config from stdin) closes that gap instead: config
# lines (`header = "..."`) are piped in via a bash here-string, which this
# project's own pinned bash (verified: bash 5.2, the build-tools image's
# version) implements as a PIPE, not a temp file on disk -- so no file with
# the token ever exists at any point for anything to open, and curl's own
# argv now only ever contains the literal, harmless string `-K -`, with
# nothing left for another process to even derive a path from. The
# underlying pipe's own buffer is finite and consumed by curl essentially
# immediately, narrowing the theoretical remaining same-UID exposure from
# "open a file at leisure over up to a 30-second window" down to "must
# already be actively intercepting this exact process's own pipe fd in real
# time" -- as close to eliminated as a single script can get without
# changing the runner's own same-UID process isolation, which is a genuine,
# separate architectural question this one function cannot resolve by
# itself (Unix file/process permissions fundamentally do not isolate
# same-UID processes from each other at all).
#
# A 401 (invalid/expired token) or 404 (wrong endpoint/repository) is a
# permanent, configuration-level failure -- no amount of retrying or
# re-authenticating (ghcr_retry's own relogin step needs a registry
# username/password anyway, which this call never has) fixes either, so
# exiting with GHCR_RETRY_PERMANENT_FAILURE_EXIT_CODE (see
# scripts/lib/ghcr-retry.sh) tells ghcr_retry to stop immediately instead of
# spending its whole backoff budget on an error retrying can never resolve --
# both real callers repeat this query once per untouched service, so a
# genuine auth/endpoint misconfiguration could otherwise burn a large
# fraction of the caller's own job timeout before reaching the inevitable
# failure. Every other non-200 status (5xx, 403/429 -- ambiguous between a
# real permission error and a transient rate limit -- a malformed/empty
# status) stays in the ordinary retryable path exactly as before:
# deliberately conservative, since misclassifying a genuinely transient
# error as permanent (giving up too early) is a worse failure mode here than
# a few extra retries on a real permanent one.
_saf_github_api_get() {
  local url="$1" body_file="$2"
  : "${GH_TOKEN:?_saf_github_api_get: GH_TOKEN is required}"
  local status curl_status header_config
  header_config="$(printf 'header = "Accept: application/vnd.github+json"\nheader = "Authorization: Bearer %s"\n' "$GH_TOKEN")"
  status="$(curl -sS --connect-timeout 10 --max-time 30 -o "$body_file" -w '%{http_code}' \
    -K - \
    "$url" 2>/dev/null <<< "$header_config")"
  curl_status=$?
  if (( curl_status != 0 )); then
    return 1
  fi
  if [[ "$status" == "200" ]]; then
    return 0
  fi
  case "$status" in
    401|404)
      return "$GHCR_RETRY_PERMANENT_FAILURE_EXIT_CODE"
      ;;
    *)
      return 1
      ;;
  esac
}

# saf_query_run_count <repository> <sha> <event-or-empty>
#
# Low-level GitHub Actions API query: echoes the number of build-push.yml
# runs recorded for <sha>, optionally filtered to a specific <event> type
# (e.g. "push"; pass an empty string for "any event"). Requires the FULL
# 40-character commit SHA -- the API silently matches nothing for an
# abbreviated short SHA.
#
# Talks to the GitHub REST API directly via `curl` + `GH_TOKEN`, never the
# `gh` CLI: AG-CI-001 requires assuming self-hosted runners do not provide
# project validation tools, and both real callers of this file
# (full-setup-deep-validate.yml's "ensure PR staging images" job,
# build-push.yml's own "Ensure PR staging tags exist" step) run this code
# directly on a bare `lancache-light` runner (AG-CI-002), not inside the
# pinned build-tools image -- `gh` is not guaranteed present there, and
# depending on it would make this whole file's ancestor-fallback mechanism
# silently unreachable on the real fleet whenever it's absent (every query
# would immediately report "inconclusive", which every caller must then
# treat as "a run exists" -- see saf_base_commit_has_confirmed_run's own
# header -- permanently blocking the exact fallback this file exists to
# provide). `curl` matches this project's own established precedent for
# exactly this situation (scripts/untracked/check-action-node-versions.sh's
# fetch_external_action_yaml(), scripts/untracked/check-pr-tracking-metadata.sh's
# project-board lookup -- both curl+GH_TOKEN specifically because `gh`
# cannot be assumed present either). Response parsing uses a bare `grep` on
# the `total_count` field, not `jq`/`python3`, for the same reason
# scripts/lib/staging-image-freshness.sh's sif_image_revision() already
# avoids jq -- neither is guaranteed present on this runner tier either (see
# that function's own header for the confirmed AG-CI-001/AG-VAL-017
# reasoning).
#
# `curl` ITSELF is also not blindly assumed present: AG-CI-001's own text
# requires "pinned GitHub Actions, the repository build-tools image, or
# explicit fail-closed capability checks instead of relying on host-
# installed utilities" -- it does not carve out an exception for `curl`
# just because it is a near-universal base-OS utility in practice. This
# function therefore explicitly checks `command -v curl` before ever
# invoking it, exactly the same explicit capability-check pattern the
# previous `gh`-based implementation already used (`command -v gh`),
# failing this query the same "inconclusive" way a missing `gh` did before,
# rather than assuming curl works and letting a genuinely tool-less runner
# fail with a raw "command not found" instead of this file's own
# documented, handled failure mode.
#
# Wrapped in scripts/lib/ghcr-retry.sh's ghcr_retry: this query's result is
# load-bearing -- turning a transient API hiccup into a hard "confirmed zero
# runs" or a false "a run exists" would either wrongly unlock or wrongly
# block the ancestor fallback. Reusing ghcr_retry directly (rather than
# writing a second near-identical backoff loop) is deliberate: this
# project's established retry-wrapper policy (bounded attempts, fixed
# backoff, ::warning::/::error:: logging) is exactly the right policy for
# any transient-failure-prone external call, GHCR-specific or not, and
# scripts/lib/ghcr-retry.sh's own header already documents that AG-CI-013
# requires reusing one documented wrapper rather than inventing a bespoke
# retry per call site. The registry/username/password parameters are unused
# here (this call needs no docker login) -- passing empty username/password
# means ghcr_retry's own "no credentials -- retry without a fresh login"
# branch applies, and the registry argument is a non-empty placeholder only
# because ghcr_retry's own required-argument check rejects an empty string;
# it is never actually used for anything when username/password are both
# empty.
#
# Returns non-zero with no output if the query fails even after retries
# (GH_TOKEN unset, `curl` missing, network error, non-200 response after
# retries, or a malformed response body with no parseable total_count).
saf_query_run_count() {
  local repository="${1:?saf_query_run_count: repository is required}"
  local sha="${2:?saf_query_run_count: sha is required}"
  local event="${3-}"
  if [[ -z "${GH_TOKEN:-}" ]]; then
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi
  local url="https://api.github.com/repos/${repository}/actions/workflows/build-push.yml/runs?head_sha=${sha}&per_page=1"
  if [[ -n "$event" ]]; then
    url="${url}&event=${event}"
  fi
  local body
  body="$(_saf_mktemp_body_file)"
  if ! ghcr_retry "n/a-not-a-real-registry" "" "" -- _saf_github_api_get "$url" "$body"; then
    rm -f "$body"
    return 1
  fi
  # Capture-first, then narrow the captured string -- deliberately NOT
  # `grep ... "$body" | head -1 | grep ...`. An early-exiting consumer (`head`,
  # `grep -q`/`-m`) piped from a still-writing producer can leave that producer
  # killed by SIGPIPE, which `set -o pipefail` (both real callers set it) then
  # reports as the whole pipeline's own failure -- exit 141 for a query that
  # actually succeeded. That is the same failure class this file's own
  # saf_find_built_ancestor header documents for `git log | head`, the same one
  # scripts/tracked/check-pipefail-early-exit-grep.sh was added to guard after it took
  # down a real CI job, and the same capture-first shape tools/build-tools/
  # Dockerfile was fixed into. `grep -m1` against the file directly has no live
  # producer process to signal, so the early exit is free here.
  local total_count_match run_count
  # `|| true`: a malformed/empty body makes grep exit 1, which must reach the
  # explicit `run_count` validation below as a normal "no parseable count"
  # answer rather than tripping a caller's `set -e` on the assignment itself.
  total_count_match="$(grep -m1 -o '"total_count"[[:space:]]*:[[:space:]]*[0-9]\+' "$body" || true)"
  rm -f "$body"
  run_count="${total_count_match##*[![:digit:]]}"
  if [[ ! "$run_count" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  printf '%s\n' "$run_count"
}

# saf_query_tag_publishing_run_count <repository> <sha>
#
# Like saf_query_run_count, but counts only runs whose trigger event
# actually publishes a per-commit sha-<sha> tag KEYED BY THIS EXACT COMMIT --
# push, workflow_dispatch, and schedule all check out <sha> itself as
# github.sha for that run (docker/metadata-action's `type=sha` tag in
# build-push.yml's "Extract metadata" step is therefore sha-<sha>), but a
# pull_request-triggered run's github.sha is the SYNTHETIC MERGE COMMIT for
# that specific PR event (see build-push.yml's own "Compute PR staging tag"
# step comment), a DIFFERENT value from <sha> even when <sha> is the exact
# head_sha the Actions API reports for that run (head_sha for a
# pull_request-triggered run is always the PR's real branch head -- see
# #975's own note on this same field/event distinction -- but github.sha
# inside that run is the merge commit, not head_sha). A pull_request run
# recorded against <sha> therefore proves nothing about whether
# ghcr.io/.../sha-<sha short> was ever published, and must not count as
# proof an ancestor candidate was built.
#
# Issues one saf_query_run_count call per allowed event type (push,
# workflow_dispatch, schedule), stopping at the FIRST non-zero count found,
# rather than one unfiltered query filtered client-side by each run's own
# `event` field: the Actions API's own `event=` filter already narrows
# server-side to exactly the trigger types that matter, so this reuses
# saf_query_run_count (and its curl/grep/retry machinery) unchanged instead
# of parsing an array of per-run event strings out of an unfiltered response
# with the same jq-free tooling constraint saf_query_run_count's own header
# documents. The exact count is never needed by any caller (only "zero" vs
# "at least one" -- see saf_base_commit_has_confirmed_run below), so
# returning as soon as any event type confirms at least one run avoids
# querying the remaining event types for no benefit.
#
# RATE-LIMIT NOTE: this still issues up to 3 queries per candidate in the
# genuinely-zero case (a real, unbroken run of docs-only commits with no
# build anywhere -- confirmed realistic in this project's own history, not
# a hypothetical), and saf_find_built_ancestor below can examine up to
# ancestor_search_depth candidates -- a pathological worst case is still
# real, just no longer the COMMON case (a candidate with any real run at all
# now costs exactly 1 query, not 3). GITHUB_TOKEN-authenticated Actions
# requests are rate-limited per-repository (not the higher personal-token
# limit), so a caller examining many services against a long docs-only
# chain should keep this in mind; the early-exit here is a real mitigation,
# not a full elimination of that exposure.
#
# Returns non-zero with no output if any queried event type's own query
# fails before a non-zero count is found (this function has no way to
# distinguish "genuinely zero tag-publishing runs so far" from "a
# sub-query failed", so a failure anywhere must propagate as inconclusive,
# not as a partial/zero count).
saf_query_tag_publishing_run_count() {
  local repository="${1:?saf_query_tag_publishing_run_count: repository is required}"
  local sha="${2:?saf_query_tag_publishing_run_count: sha is required}"
  local event count
  for event in push workflow_dispatch schedule; do
    count="$(saf_query_run_count "$repository" "$sha" "$event")" || return 1
    if (( count > 0 )); then
      printf '%s\n' "$count"
      return 0
    fi
  done
  printf '%s\n' "0"
}

# saf_candidate_run_is_active <repository> <sha>
#
# Answers whether any TAG-PUBLISHING-eligible run (push, workflow_dispatch,
# schedule -- see saf_query_tag_publishing_run_count's own header for why
# only these event types count) recorded for <sha> is still non-completed
# (queued, in_progress, or any other non-terminal status GitHub reports).
# Used by saf_find_built_ancestor to distinguish "this candidate's own
# build is still genuinely running" (a real, still-in-flight push landing
# very close in wall-clock time to the docs-only commit ahead of it in
# history -- confirmed as a real, not hypothetical, race: this project's
# own real build-push.yml runs have taken 34-90 minutes end to end, and
# "further back in a commit's own first-parent history" does not imply
# "further back in wall-clock time" when several commits merge in rapid
# succession) from "this candidate's build already finished (or never
# started) and its image still hasn't appeared" (no amount of further
# waiting will help -- a genuinely broken/stuck build, worth surfacing on
# its own, not hunting around).
#
# Fetches up to 20 recent runs per event type (matching
# build_push_run_active()'s own per_page=20 convention in
# scripts/tracked/ensure-pr-staging-images.sh) and inspects every returned run's
# own `status` field, not just the newest one -- the same "a single commit
# can have more than one recorded run" reasoning #975 already established
# for that congestion probe applies here too. Stops at the first event type
# that turns up a non-completed run, mirroring saf_query_tag_publishing_run_count's
# own early-exit reasoning (the caller only needs a yes/no answer).
#
# Returns 0 if at least one non-completed run is found (a real signal to
# extend the wait). Returns 1 if every queried event type positively
# confirms zero runs or all-completed runs. Returns 2 if any underlying
# query fails before a definitive answer is reached, or if GH_TOKEN/curl
# are unavailable -- an inconclusive activity check is deliberately NOT
# collapsed into either 0 or 1: callers must decide for themselves which
# direction is safe for their own use of this answer (saf_find_built_ancestor
# below treats 2 the same as 1 -- it does not extend the wait on an
# unconfirmed "maybe active" guess, since that would risk stacking an
# unbounded number of long waits for no positive reason).
#
# Indirection so tests can stub this without a real network call, same
# convention as saf_base_commit_has_confirmed_run's own
# STAGING_BASE_BUILD_RUN_EXISTS_CMD hook.
saf_candidate_run_is_active() {
  local repository="${1:?saf_candidate_run_is_active: repository is required}"
  local sha="${2:?saf_candidate_run_is_active: sha is required}"
  if [[ -n "${STAGING_CANDIDATE_RUN_ACTIVE_CMD:-}" ]]; then
    "$STAGING_CANDIDATE_RUN_ACTIVE_CMD" "$sha"
    return $?
  fi
  local event status
  for event in push workflow_dispatch schedule; do
    saf_event_has_incomplete_run "$repository" "$sha" "$event"
    status=$?
    if (( status != 1 )); then
      # 0 (an incomplete run found) or 2 (inconclusive) are both final
      # answers for this function -- only a positive "every run for this
      # event type is completed, or there are none" is worth continuing to
      # the next event type for.
      return "$status"
    fi
  done
  return 1
}

# saf_event_has_incomplete_run <repository> <sha> <event>
#
# The single low-level "is any build-push.yml run for <sha> triggered by
# <event> still non-completed?" query, shared by saf_candidate_run_is_active
# above (which asks it once per tag-publishing event type) and by
# scripts/tracked/ensure-pr-staging-images.sh's build_push_run_active() congestion
# probe (which asks it for `pull_request`). Those two used to be independent
# implementations of the same question against the same endpoint -- one on
# `curl`, one on the `gh` CLI -- which is exactly the duplication this file
# exists to remove; a fix or a fail-closed correction in one would silently
# not reach the other.
#
# Fetches up to 20 recent runs (matching the per_page=20 convention #975
# established for the congestion probe) and inspects EVERY returned run's own
# `status` field, not just the newest: a single push can produce more than one
# recorded run for the same head_sha (`synchronize` and `labeled` firing close
# together, confirmed live in #960), and the newest one completing or being
# cancelled must not hide an older one that is still genuinely building.
# Checks for the single terminal state (`completed`) rather than enumerating
# non-terminal ones, since the API can report `pending` as well as
# `queued`/`in_progress`.
#
# Returns 0 if at least one non-completed run exists, 1 if the query
# positively confirms none does (including zero runs at all), and 2 if the
# query could not be completed at all (GH_TOKEN unset, `curl` missing, API
# error after retries). 2 is deliberately not collapsed into 0 or 1 -- each
# caller decides which direction is safe for its own use.
saf_event_has_incomplete_run() {
  local repository="${1:?saf_event_has_incomplete_run: repository is required}"
  local sha="${2:?saf_event_has_incomplete_run: sha is required}"
  local event="${3:?saf_event_has_incomplete_run: event is required}"
  # `curl` is capability-checked rather than assumed present, per AG-CI-001 --
  # see saf_query_run_count's own header for why that applies to `curl` too
  # and not just to the `gh` CLI this function replaced.
  if [[ -z "${GH_TOKEN:-}" ]] || ! command -v curl >/dev/null 2>&1; then
    return 2
  fi
  local url body statuses
  url="https://api.github.com/repos/${repository}/actions/workflows/build-push.yml/runs?head_sha=${sha}&event=${event}&per_page=20"
  body="$(_saf_mktemp_body_file)"
  if ! ghcr_retry "n/a-not-a-real-registry" "" "" -- _saf_github_api_get "$url" "$body"; then
    rm -f "$body"
    return 2
  fi
  # Capture-first, then filter the captured string via a here-string --
  # deliberately NOT `grep -o ... | grep -qv ...`. `grep -q` exits at its
  # first match and closes the pipe, which can leave the still-scanning
  # producer killed by SIGPIPE; under `set -o pipefail` (every real caller)
  # that surfaces as a failed pipeline, so a genuinely incomplete run would be
  # misread as "none" and the extended retry silently skipped. Same failure
  # class, and same capture-first remedy, as saf_query_run_count above and
  # scripts/tracked/check-pipefail-early-exit-grep.sh's own guard.
  statuses="$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$body" || true)"
  rm -f "$body"
  if [[ -n "$statuses" ]] && grep -qv '"status"[[:space:]]*:[[:space:]]*"completed"' <<< "$statuses"; then
    return 0
  fi
  return 1
}

# saf_base_commit_has_confirmed_run <repository> <sha> <event-or-empty>
#
# Answers "does at least one build-push.yml run (optionally filtered to
# <event>) exist for <sha>?", used two different ways by the two callers in
# this file:
#   - Passed "push": asks specifically about a push-triggered run, for the
#     PR base-commit decision (paired with saf_base_commit_paths_are_ignorable
#     above -- see that function's header for why event=push alone is not
#     sufficient proof of a deliberate skip on its own).
#   - Passed "" (any TAG-PUBLISHING event): asks whether any run exists
#     whose trigger type actually publishes a per-commit sha-<sha> tag KEYED
#     BY <sha> ITSELF, for the ancestor-candidate pre-filter in
#     saf_find_built_ancestor below. Backed by
#     saf_query_tag_publishing_run_count (push, workflow_dispatch, schedule),
#     NOT a bare unfiltered "any event at all" query -- see that function's
#     own header for why a pull_request-triggered run must be excluded: its
#     github.sha is a synthetic merge commit, not <sha>, so it can never
#     have published the sha-<sha> tag this whole mechanism depends on,
#     regardless of what the Actions API's head_sha field reports for that
#     run. Treating a pull_request run as proof here would make the walk
#     wait out the full freshness ceiling against a tag a pull_request run
#     never produces, then give up (per saf_find_built_ancestor's own
#     JUDGMENT CALL) instead of correctly skipping past this candidate to an
#     older, genuinely push/dispatch/schedule-built ancestor.
#
# IMPORTANT SCOPING NOTE when called with "push": a "1" here means "no
# push-triggered run", not "this commit was never built by any means" --
# a non-push-triggered run for the exact same commit can independently exist
# and can have already produced a perfectly valid image, entirely regardless
# of whether a push-triggered run ever fired. This is why callers only ever
# consult this function (with "push") AFTER first trying the direct
# freshness/existence check against the commit's own image (see the exact-
# BASE_SHA wait in each caller) -- if that image already exists via any
# trigger, the direct check already succeeds and this function is never
# reached for that commit at all. A "1" is therefore never a false positive
# for "safe to fall back": it only ever fires once the commit's own image
# has already been confirmed unavailable by a real, direct check.
#
# Returns 0 if at least one matching run exists (regardless of conclusion --
# success, failure, or still in progress all count as "a real attempt
# happened"). Returns 1 ONLY when the query positively confirms zero
# matching runs -- the sole condition under which a caller may treat the
# commit as "no run of this kind was ever attempted". Returns 2 when the
# query itself could not be completed (GH_TOKEN unset, API error after
# retries, malformed response) -- deliberately NOT collapsed into "confirmed
# zero": this function's whole purpose (when checking the PR base commit
# specifically) is proving ABSENCE, and a failed query proves nothing about
# that. Every caller must treat 2 the same as 0 for that specific decision --
# collapsing 2 into "confirmed zero" would let a transient failure silently
# unlock a fallback path that requires positive proof.
#
# Indirection so tests can stub this without a real network call.
saf_base_commit_has_confirmed_run() {
  local repository="$1" sha="$2" event="${3-}"
  if [[ -n "${STAGING_BASE_BUILD_RUN_EXISTS_CMD:-}" ]]; then
    "$STAGING_BASE_BUILD_RUN_EXISTS_CMD" "$sha" "$event"
    return $?
  fi
  local run_count
  if [[ -n "$event" ]]; then
    run_count="$(saf_query_run_count "$repository" "$sha" "$event")" || return 2
  else
    run_count="$(saf_query_tag_publishing_run_count "$repository" "$sha")" || return 2
  fi
  if (( run_count == 0 )); then
    return 1
  fi
  return 0
}

# saf_legacy_sha_image_ref <repository> <service> <commit> <git_dir>
#
# What: probes <commit>'s legacy 7-char short-SHA tag for <service>, echoing
#   it only if the tag's own revision label matches <commit>.
# Why: `git rev-parse --short=7` (a real lookup, not a ${VAR:0:7} slice) is
#   exempt from check-deny-short-sha.sh's guard; the revision check stops a
#   short-SHA collision or overwritten tag from being accepted on label alone.
# From: Issue #1095 (G2) | PR #1611
saf_legacy_sha_image_ref() {
  local repository="${1:?saf_legacy_sha_image_ref: repository is required}"
  local service="${2:?saf_legacy_sha_image_ref: service is required}"
  local commit="${3:?saf_legacy_sha_image_ref: commit is required}"
  local git_dir="${4:?saf_legacy_sha_image_ref: git_dir is required}"

  local legacy_short legacy_image legacy_revision
  legacy_short="$(git -C "$git_dir" rev-parse --short=7 "$commit" 2>/dev/null)" || return 1
  [[ "$legacy_short" =~ ^[0-9a-f]{7}$ ]] || return 1
  legacy_image="ghcr.io/${repository}/${service}:sha-${legacy_short}"
  legacy_revision="$(sif_image_revision "$legacy_image" 2>/dev/null)" || return 1
  [[ "$legacy_revision" == "$commit" ]] || return 1
  printf '%s\n' "$legacy_image"
  return 0
}

# saf_resolve_sha_image_ref <repository> <service> <commit> [git_dir]
#
# Resolves <commit>'s own per-commit GHCR tag reference for <service>,
# tolerating the same legacy short-SHA tags saf_legacy_sha_image_ref
# documents: a single cheap sif_image_revision probe against the canonical
# full-SHA tag (`sha-<commit>`) is tried first; only on a miss does this
# fall back to saf_legacy_sha_image_ref. Neither probe succeeding echoes
# the canonical full-SHA reference anyway, so every caller's own freshness
# wait always targets the format any future build actually produces.
#
# Only appropriate for a caller with no freshness wait of its own already
# planned right after this call (e.g. this file's own final
# ancestor-substitution points, after an ancestor is already fully
# confirmed) -- a caller that is about to run its own
# sif_wait_for_fresh_base_image poll should construct the plain full-SHA
# reference directly instead and reach for saf_legacy_sha_image_ref only at
# its own give-up point, so the two probes are never stacked redundantly
# (see saf_find_built_ancestor's own candidate-walk for the pattern).
# From: Issue #1095 (G2)
saf_resolve_sha_image_ref() {
  local repository="${1:?saf_resolve_sha_image_ref: repository is required}"
  local service="${2:?saf_resolve_sha_image_ref: service is required}"
  local commit="${3:?saf_resolve_sha_image_ref: commit is required}"
  local git_dir="${4:-.}"
  local full_image="ghcr.io/${repository}/${service}:sha-${commit}"

  if sif_image_revision "$full_image" >/dev/null 2>&1; then
    printf '%s\n' "$full_image"
    return 0
  fi

  local legacy_image
  if legacy_image="$(saf_legacy_sha_image_ref "$repository" "$service" "$commit" "$git_dir")"; then
    printf '%s\n' "$legacy_image"
    return 0
  fi

  printf '%s\n' "$full_image"
  return 0
}

# saf_descendant_preserves_service_content <base_sha> <candidate_sha> <classify_key> [git_dir]
#
# Answers the descendant-side counterpart to saf_base_commit_service_untouched:
# is the service still provably content-equivalent between <base_sha> and the
# later first-parent commit <candidate_sha>? A later candidate is only safe
# when BOTH the service itself and build-affecting workflow wiring stayed
# unchanged across the FULL span -- a superseded service-changing commit or a
# later workflow/composite-action change anywhere in that span would make the
# descendant a different proof target from <base_sha>'s own image.
#
# Returns 0 only when classify-image-impact.sh reports both
# <classify_key>=false and workflow=false for the full span. Returns 1 when
# either changed, and 2 when the classify command itself is inconclusive.
saf_descendant_preserves_service_content() {
  local base_sha="${1:?saf_descendant_preserves_service_content: base_sha is required}"
  local candidate_sha="${2:?saf_descendant_preserves_service_content: candidate_sha is required}"
  local classify_key="${3:?saf_descendant_preserves_service_content: classify_key is required}"
  local git_dir="${4:-.}"
  local classify_script="${STAGING_DESCENDANT_CLASSIFY_SCRIPT:-$(dirname "${BASH_SOURCE[0]}")/../untracked/classify-image-impact.sh}"
  local classify_output changed_flag workflow_flag changed_files_tmp
  changed_files_tmp="$(mktemp)" || return 2

  if ! git -C "$git_dir" diff --name-only "$base_sha" "$candidate_sha" > "$changed_files_tmp" 2>/dev/null; then
    rm -f "$changed_files_tmp"
    return 2
  fi

  classify_output="$(CHANGED_FILES="$changed_files_tmp" bash "$classify_script" 2>/dev/null)" || {
    rm -f "$changed_files_tmp"
    return 2
  }
  rm -f "$changed_files_tmp"

  # What: reads the exact per-service key build-push.yml already routes on.
  # Why: avoids inventing a second service/path mapping for descendant rescue.
  # From: Issue #456 | PR #1673
  changed_flag="$(grep -m1 "^${classify_key}=" <<<"$classify_output" | cut -d= -f2)"
  if [[ "$changed_flag" != "false" ]]; then
    return 1
  fi

  # What: also requires workflow=false across the same full span.
  # Why: later images built under changed build wiring are not equivalent proof.
  # From: Issue #456 | PR #1673
  workflow_flag="$(grep -m1 '^workflow=' <<<"$classify_output" | cut -d= -f2)"
  if [[ "$workflow_flag" != "false" ]]; then
    return 1
  fi

  return 0
}

# saf_find_built_descendant <repository> <base_sha> <base_ref> <service> <classify_key> \
#     <search_depth> <freshness_timeout_seconds> <freshness_hard_ceiling_seconds> \
#     <freshness_poll_interval_seconds> <extended_timeout_seconds> \
#     <extended_hard_ceiling_seconds> [git_dir]
#
# Searches the later first-parent history of origin/<base_ref> for the nearest
# commit whose image for <service> can safely stand in for <base_sha>. This is
# the complement to saf_find_built_ancestor: a superseded service-changing
# commit can make the older-only walk fail even though the base branch later
# published the SAME unchanged service content, and that contradiction is
# exactly what this helper resolves.
#
# Safety bar: the full <base_sha>..<candidate> span must preserve both the
# service's own content and workflow wiring (saf_descendant_preserves_service_content),
# a tag-publishing run must exist for the candidate, and the candidate's own
# per-commit image must be freshness-confirmed at or after <base_sha>. Reverse
# ancestry is deliberately NOT accepted here: a descendant tag carrying a
# revision older than <base_sha> would not prove it includes <base_sha>'s
# service state.
#
# Returns 0 and echoes the qualifying descendant SHA on success, 1 when no
# qualifying descendant exists within the bounded search, and 2 when the
# descendant search itself is inconclusive.
saf_find_built_descendant() {
  local repository="${1:?saf_find_built_descendant: repository is required}"
  local base_sha="${2:?saf_find_built_descendant: base_sha is required}"
  local base_ref="${3:?saf_find_built_descendant: base_ref is required}"
  local service="${4:?saf_find_built_descendant: service is required}"
  local classify_key="${5:?saf_find_built_descendant: classify_key is required}"
  local search_depth="${6:?saf_find_built_descendant: search_depth is required}"
  local freshness_timeout_seconds="${7:?saf_find_built_descendant: freshness_timeout_seconds is required}"
  local freshness_hard_ceiling_seconds="${8:?saf_find_built_descendant: freshness_hard_ceiling_seconds is required}"
  local freshness_poll_interval_seconds="${9:?saf_find_built_descendant: freshness_poll_interval_seconds is required}"
  local extended_timeout_seconds="${10:?saf_find_built_descendant: extended_timeout_seconds is required}"
  local extended_hard_ceiling_seconds="${11:?saf_find_built_descendant: extended_hard_ceiling_seconds is required}"
  local git_dir="${12:-.}"
  local remote_ref="origin/${base_ref}"

  if ! git -C "$git_dir" cat-file -e "${remote_ref}^{commit}" 2>/dev/null; then
    echo "::warning::Descendant rescue could not inspect ${remote_ref}: the base branch ref is not present in local git history. Skipping the later-descendant search rather than guessing." >&2
    return 2
  fi

  local descendants
  descendants="$(git -C "$git_dir" rev-list --first-parent --ancestry-path --reverse --max-count="$search_depth" "${base_sha}..${remote_ref}" 2>/dev/null)" || return 2
  [[ -n "$descendants" ]] || return 1

  local candidate equivalence_status has_run activity_status descendant_image
  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue

    equivalence_status=0
    saf_descendant_preserves_service_content "$base_sha" "$candidate" "$classify_key" "$git_dir" || equivalence_status=$?
    if (( equivalence_status == 2 )); then
      echo "::warning::Descendant rescue could not prove whether $service stayed unchanged between $base_sha and later base-branch commit $candidate. Skipping the descendant search rather than guessing." >&2
      return 2
    fi
    if (( equivalence_status == 1 )); then
      # What: stops at the first later span that changes the service/workflow proof.
      # Why: every even-later descendant includes that same changed span too.
      # From: Issue #456 | PR #1673
      echo "::notice::Later base-branch commit $candidate changed $service ($classify_key) or build-affecting workflow wiring somewhere in the full $base_sha..$candidate span, so no still-later descendant can prove equivalence either. Stopping the descendant rescue here." >&2
      return 1
    fi

    has_run=0
    saf_base_commit_has_confirmed_run "$repository" "$candidate" "" || has_run=$?
    if (( has_run == 2 )); then
      echo "::warning::Descendant rescue could not positively determine whether later base-branch commit $candidate has a tag-publishing build-push.yml run. Skipping the descendant search rather than guessing." >&2
      return 2
    fi
    if (( has_run == 1 )); then
      continue
    fi

    descendant_image="ghcr.io/${repository}/${service}:sha-${candidate}"
    if sif_wait_for_fresh_base_image "$descendant_image" "$base_sha" "$service" \
      "$freshness_timeout_seconds" "$freshness_hard_ceiling_seconds" "$freshness_poll_interval_seconds" >/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi

    activity_status=0
    saf_candidate_run_is_active "$repository" "$candidate" || activity_status=$?
    if (( activity_status == 0 )); then
      echo "::warning::Later base-branch commit $candidate still appears to be actively building $service -- giving it one extended descendant-rescue retry before moving on." >&2
      if sif_wait_for_fresh_base_image "$descendant_image" "$base_sha" "$service" \
        "$extended_timeout_seconds" "$extended_hard_ceiling_seconds" "$freshness_poll_interval_seconds" >/dev/null; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  done <<< "$descendants"

  return 1
}

# saf_find_built_ancestor <repository> <base_sha> <service> <classify_key> <search_depth> \
#     <freshness_timeout_seconds> <freshness_hard_ceiling_seconds> \
#     <freshness_poll_interval_seconds> \
#     <extended_timeout_seconds> <extended_hard_ceiling_seconds> [git_dir]
#
# Only meaningful to call once the caller has already confirmed <base_sha>'s
# own image is unavailable via a direct check. Walks <base_sha>'s own
# FIRST-PARENT ancestor history (nearest-first), bounded to <search_depth>
# commits, for the nearest ancestor that both has at least one recorded
# build-push.yml run (any event -- see saf_base_commit_has_confirmed_run's
# header for why non-push runs count here) and a freshness-confirmed
# per-commit image for <service> (reusing sif_wait_for_fresh_base_image,
# never skipping that proof).
#
# TWO budget pairs, not one: <freshness_timeout_seconds>/<freshness_hard_ceiling_seconds>
# (short -- an already-confirmed-run historical candidate's image normally
# either exists already or never will) govern the FIRST attempt at each
# candidate. If that first attempt fails, this does NOT immediately give up
# the way it used to: it calls saf_candidate_run_is_active() to positively
# check whether that candidate's own build is still genuinely running (a
# real race this project has confirmed happens -- see that function's own
# header). Only when that check POSITIVELY confirms activity does this
# retry the SAME candidate once more, this time with
# <extended_timeout_seconds>/<extended_hard_ceiling_seconds> (the caller
# passes its own base_freshness_* pair here -- the same patience BASE_SHA's
# own possibly-in-progress build already gets, not a new invented number).
# An inconclusive or confirmed-not-active answer preserves the original
# JUDGMENT CALL below unchanged: stop, fail, do not walk further.
#
# A candidate with zero recorded runs is not simply skipped in favor of an
# older one: exactly the same "zero runs alone does not prove a deliberate
# skip" reasoning saf_base_commit_paths_are_ignorable's own header documents
# for <base_sha> applies to every candidate walked here too. Before walking
# past a run-less candidate, this positively confirms EITHER that
# <classify_key>'s own service was untouched by that candidate's own diff
# (saf_base_commit_service_untouched -- the same service-scoped route
# saf_resolve_untouched_backfill_source's own BASE_SHA decision uses) OR that
# every path it changed matches the commit-wide ignore list
# (saf_base_commit_paths_are_ignorable); if NEITHER is a positive
# confirmation, this stops and fails rather than silently substituting an
# older ancestor that could omit a real, unbuilt change at that candidate.
#
# A candidate whose run-check itself is INCONCLUSIVE (saf_base_commit_has_confirmed_run
# returns 2 -- GH_TOKEN unset, API error after retries, malformed response)
# is likewise never treated as safe to act on: it fails closed immediately,
# the same discipline BASE_SHA's own push-run check already applies. Falling
# through to the freshness check for an unconfirmed candidate would accept
# it as the resolved source purely because its image happens to satisfy
# sif_is_ancestor_or_equal, with no positive proof any build-push.yml run
# ever produced it -- exactly the missing proof this whole mechanism exists
# to require before substituting anything.
#
# `--first-parent`: this project does not squash-merge, so nearly every
# commit on a target branch is itself a merge commit. A plain `git log <sha>`
# walks EVERY parent of every merge commit it encounters, which can surface a
# built commit that only ever existed on a side/feature branch before
# reaching the actual previous target-branch state (<base_sha>^1). That
# side-branch commit's image does not represent "the target branch
# immediately before <base_sha>" and can omit real target-branch changes --
# exactly the kind of stale-content risk this whole mechanism exists to
# avoid. `--first-parent` walks only the same first-parent chain
# saf_base_commit_diff_paths already uses, so "nearest built ancestor" and
# "what changed to get to this commit" stay consistent with each other.
#
# `--max-count=$((search_depth + 1))` at the `git log` SOURCE, piped through
# only `tail -n +2` (never `head`): piping `git log`'s output through
# `head -n N` under `set -o pipefail` is a real SIGPIPE hazard -- `head`
# closes its read end once it has read N lines, and the writer (`tail`, or
# `git log` itself) can be signaled SIGPIPE for writing to a closed pipe,
# which `pipefail` then reports as pipeline failure. A small bats fixture
# with fewer real ancestors than `search_depth` never exercises this path,
# but any `BASE_SHA` with more than `search_depth` ancestors -- the common
# case for a mature branch -- would abort this function before it examines a
# single real candidate, always reporting "no usable ancestor" even when a
# perfectly good one sits a few commits back. Bounding at the `git log`
# source with `--max-count` avoids ever needing to close the pipe early.
#
# JUDGMENT CALL (flagged for maintainer review, matching this project's own
# convention for calling these out explicitly -- see
# scripts/lib/staging-image-freshness.sh's own JUDGMENT CALL comment): if a
# run-bearing candidate's freshness proof still fails even after the one
# activity-confirmed extended retry above, this function normally stops and
# reports failure immediately rather than walking further back -- UNLESS
# <classify_key>'s own service is confirmed untouched by that candidate's own
# diff (saf_base_commit_service_untouched), in which case the run existing
# says nothing on its own about whether a fresh per-commit tag for <service>
# is actually present (Step 4 reuse, confirmed live 2026-08-02, does
# not by itself prove a fresh per-commit tag exists yet for a reused
# service -- see the corrected note at the has_run==0 branch below for why
# this is a probe-and-move-on decision, not "it structurally never exists"),
# and this continues to the next candidate instead if that tag isn't there.
# Stacking many bounded waits (each up to <extended_hard_ceiling_seconds>)
# across up to <search_depth> candidates would still be a worse failure mode
# than the structural problem this mechanism exists to solve, and reaching
# further and further back in history for a substitute still risks the same
# stale-content class of bug this file exists to avoid -- so a candidate
# whose service WAS actually touched (or whose service-scoped check is
# inconclusive) still stops here: a real, seemingly-broken build for a
# service-affecting commit is a genuine CI problem worth surfacing on its
# own, not a reason to keep hunting for an even older substitute.
#
# 2026-08-07: the confirmed-untouched case described above used
# to be reached ONLY here, after paying the full wait -- a candidate whose
# own diff never touched <service> still burned the full wait, up to
# <freshness_hard_ceiling_seconds> (and, if a confirmed-active retry
# applied, <extended_hard_ceiling_seconds> on top) before this JUDGMENT CALL
# got a chance to walk past it. Confirmed live against PR #1468 (runs
# 31184925428/31187...): four services untouched by the same candidate
# commit each independently paid the full 600s ceiling waiting on a tag that
# was never going to appear, stacking to roughly 40 minutes for one job. The
# has_run==0 branch below now runs this identical service-scoped check
# BEFORE the wait, so the common "genuinely untouched" case is walked past in
# the time a git diff takes, not a network poll loop -- this JUDGMENT CALL
# and its own re-derivation of the check (the code immediately below) remain
# as the fail-closed path for the "service WAS touched" and "the pre-check
# was inconclusive" cases, which still need the real wait.
#
# Echoes the confirmed-good ancestor's full commit SHA on stdout on success;
# returns non-zero with no output if no usable ancestor is found within the
# bounded depth. All human-readable diagnostic output goes to stderr, same
# discipline as sif_wait_for_fresh_base_image.
saf_find_built_ancestor() {
  local repository="$1" base_sha="$2" service="$3" classify_key="$4" search_depth="$5"
  local freshness_timeout_seconds="$6" freshness_hard_ceiling_seconds="$7"
  local freshness_poll_interval_seconds="$8"
  local extended_timeout_seconds="$9" extended_hard_ceiling_seconds="${10}"
  local git_dir="${11:-.}"
  # sif_wait_for_fresh_base_image (called below) delegates its own ancestry
  # check to sif_is_ancestor_or_equal, which reads STAGING_FRESHNESS_GIT_DIR
  # from the environment rather than taking a git_dir argument -- setting it
  # here bridges this function's own explicit <git_dir> parameter through to
  # that mechanism, so a caller of THIS function never needs to know about
  # that env-var-based convention itself.
  #
  # `local -x`, not a bare `export`: still exported (so any subshell or child
  # process started from here inherits it), but dynamically scoped to this
  # function, so bash restores whatever the caller's own value was -- including
  # "unset" -- the moment this function returns. A bare `export` would leave
  # this function's <git_dir> permanently stamped on the caller's environment,
  # silently redirecting any LATER, unrelated sif_* call (or any child process
  # that reads it) at a directory it was never asked to use.
  local -x STAGING_FRESHNESS_GIT_DIR="$git_dir"

  local candidates
  candidates="$(git -C "$git_dir" log --first-parent --max-count=$((search_depth + 1)) --format=%H "$base_sha" 2>/dev/null | tail -n +2)" || return 1
  if [[ -z "$candidates" ]]; then
    return 1
  fi

  local candidate has_run ancestor_image candidate_paths_status
  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue

    # Cached by (repository, candidate) via a file under
    # $SAF_ANCESTOR_RUN_CACHE_DIR -- see that variable's own declaration-site
    # comment for the full "why a file, not a shell variable" reasoning (in
    # short: both real callers invoke this whole chain through a `$(...)`
    # command substitution once per service, which forks a fresh subshell
    # every time -- only a real file on disk, not an in-memory shell
    # variable, actually persists across those calls). Deliberately scoped
    # to ONLY this ancestor-candidate lookup, not to
    # saf_base_commit_has_confirmed_run generally: BASE_SHA's own push-run
    # check (saf_resolve_untouched_backfill_source's pre_run_status/
    # post_run_status pair) is INTENTIONALLY queried twice, independently,
    # specifically so a fast-path bug can only cost time, never safety (see
    # that function's own header) -- caching at a lower, shared level would
    # silently defeat that deliberate re-derivation. No such independent-
    # re-derivation requirement exists for an ancestor candidate: each
    # candidate's run-existence fact is looked up exactly once per call to
    # THIS function already, so sharing that same answer across repeated
    # calls for OTHER services walking the identical candidate chain removes
    # pure redundancy, not a safety check.
    #
    # Only a DEFINITIVE answer (0 = a run exists, 1 = confirmed zero) is ever
    # cached, never an inconclusive one (2): an inconclusive result reflects
    # a query failure, not a historical fact, and permanently caching it
    # could make a transient blip (that a later, independent query for a
    # different service might not have hit at all) needlessly fail every
    # subsequent service's own check too.
    local cache_file cache_file_content cache_file_valid=0
    cache_file="$(_saf_ancestor_run_cache_key_to_path "$repository" "$candidate")"
    cache_file_content=""
    if [[ -n "$SAF_ANCESTOR_RUN_CACHE_DIR" ]] && [[ -f "$cache_file" ]]; then
      cache_file_content="$(cat "$cache_file" 2>/dev/null)"
      # A cache file's content must be EXACTLY "0" or "1" to be trusted --
      # not just non-empty. A write that failed partway (e.g. the runner's
      # disk filling up mid-write) can leave an empty regular file behind
      # even with the write's own `|| true` swallowing the error; reading
      # that empty string back into an arithmetic comparison
      # (`(( has_run == 1 ))`/`(( has_run == 2 ))`) would silently evaluate
      # it as 0 -- the single MOST PERMISSIVE outcome ("a run positively
      # confirmed to exist"), the opposite of what a failed, unproven write
      # should ever be read back as. Anything other than exactly "0" or "1"
      # is treated as a cache miss and re-queried below instead.
      if [[ "$cache_file_content" == "0" ]] || [[ "$cache_file_content" == "1" ]]; then
        cache_file_valid=1
      fi
    fi
    if (( cache_file_valid )); then
      has_run="$cache_file_content"
    else
      has_run=0
      # Empty event filter ("any event"): see saf_base_commit_has_confirmed_run's
      # own header for why non-push-triggered runs must count for an ancestor
      # candidate, unlike the stricter push-only check used for BASE_SHA itself.
      saf_base_commit_has_confirmed_run "$repository" "$candidate" "" || has_run=$?
      if [[ -n "$SAF_ANCESTOR_RUN_CACHE_DIR" ]] && (( has_run == 0 || has_run == 1 )); then
        # Write via a temp file + atomic rename, not a direct redirection
        # into the final path: `mv` within the same directory/filesystem is
        # an atomic rename, so any reader of $cache_file either sees the
        # complete prior content (none yet, for a first write) or the
        # complete new content -- never a partially-written, torn file, even
        # if this process is killed mid-write. The `|| true` on this whole
        # attempt is still fine to keep permissive: a failed write here just
        # means the NEXT read finds no cache file at all (a clean miss,
        # re-queried like any cold cache entry), never a corrupted one.
        local cache_tmp_file
        cache_tmp_file="$(mktemp "${cache_file}.XXXXXX" 2>/dev/null)" && {
          printf '%s' "$has_run" > "$cache_tmp_file" 2>/dev/null && mv -f "$cache_tmp_file" "$cache_file" 2>/dev/null || rm -f "$cache_tmp_file" 2>/dev/null
        } || true
      fi
    fi
    if (( has_run == 1 )); then
      # Positively confirmed zero runs of any kind for THIS candidate -- but
      # zero runs alone is not proof this candidate was itself a deliberate
      # skip, exactly the same reasoning saf_base_commit_paths_are_ignorable's
      # own header documents for BASE_SHA. A candidate with zero runs could
      # be a genuine, unbuilt service change (e.g. build-push.yml's push
      # trigger was temporarily disabled for that one push, or some other
      # real CI outage), and silently walking past it to substitute an
      # older, built ancestor would back-fill content that omits that real
      # change -- the exact #626/#808 class of bug this whole mechanism must
      # not reintroduce. So before skipping this candidate and continuing
      # further back, positively confirm EITHER that <classify_key>'s own
      # service was untouched by this candidate's own diff (cheaper, checked
      # first) OR that its changed paths also all match the commit-wide
      # ignore list; only then is walking past it actually safe.
      candidate_service_untouched_status=0
      saf_base_commit_service_untouched "$candidate" "$classify_key" "$git_dir" || candidate_service_untouched_status=$?
      if (( candidate_service_untouched_status != 0 )); then
        candidate_paths_status=0
        saf_base_commit_paths_are_ignorable "$candidate" "$git_dir" || candidate_paths_status=$?
        if (( candidate_paths_status != 0 )); then
          # Before failing closed: "zero recorded runs" is only ever a PROXY
          # for "never built", and that proxy has a real blind spot GitHub
          # Actions itself creates -- workflow run history has a finite
          # retention window (project-configurable, commonly 90 days), while
          # this project's own durable per-commit `sha-<commit>` image tags
          # (docs/release-versioning.md) are not subject to that retention at
          # all. A candidate built long enough ago that its run record has
          # since expired would report "zero runs" here even though it
          # genuinely WAS built and its image still exists -- and since a real
          # (non-doc, service-affecting) candidate almost always fails both
          # checks above, this combination would make the whole
          # ancestor-fallback mechanism silently and permanently unusable past
          # that retention window for any repository/branch old enough to
          # have candidates that predate it. The image's own existence and
          # correct per-commit labeling (sif_wait_for_fresh_base_image,
          # exactly the same check the has_run==0 branch below already
          # performs, same short budget) is STRONGER, retention-independent
          # proof of a genuine build than the run-query's answer -- if it
          # succeeds, a real build unambiguously did happen here regardless of
          # what the (possibly expired) run record says, so this candidate is
          # exactly as safe to use as the has_run==0 case already is. Only
          # when the image ALSO does not exist does this remain a genuine,
          # unbuilt real change that must still fail closed.
          #
          # Plain full-SHA string construction, not saf_resolve_sha_image_ref:
          # the wait immediately below is this candidate's own real freshness
          # probe already, so pre-probing here would just duplicate it for
          # the common (new-format) case that is this project's own future
          # default. A legacy-tag attempt is still made below, but only at
          # this branch's own give-up point (after the full-SHA wait has
          # already failed) -- exactly the "zero recorded runs, run
          # retention expired" scenario this branch's own header comment
          # documents is likeliest to land on an OLD, legacy-tag-only
          # commit, so skipping the legacy check here would defeat the
          # transition support this file exists to provide for precisely
          # this case.
          ancestor_image="ghcr.io/${repository}/${service}:sha-${candidate}"
          # allow_reverse_ancestry=true: $ancestor_image is always an
          # immutable per-commit sha-tag here (never a mutable channel tag),
          # so a label that predates $candidate is exactly build-push.yml's
          # own Schritt 4 retag-unchanged-image signature, already verified
          # content-equivalent -- see sif_wait_for_fresh_base_image's own
          # header for the full reasoning.
          if sif_wait_for_fresh_base_image "$ancestor_image" "$candidate" "$service" \
            "$freshness_timeout_seconds" "$freshness_hard_ceiling_seconds" "$freshness_poll_interval_seconds" true >/dev/null; then
            printf '%s\n' "$candidate"
            return 0
          fi
          local legacy_image
          if legacy_image="$(saf_legacy_sha_image_ref "$repository" "$service" "$candidate" "$git_dir")"; then
            printf '%s\n' "$candidate"
            return 0
          fi
          echo "::error::Ancestor candidate $candidate (between $base_sha and its own ancestor history) has zero recorded build-push.yml runs, but neither $classify_key's own service-scoped diff nor its changed paths overall could be positively confirmed as untouched/ignorable (service status $candidate_service_untouched_status, paths status $candidate_paths_status -- see this file's own header for why an inconclusive result must not be treated as safe either), and its own per-commit image could not be confirmed to exist either under the full-SHA or legacy short-SHA tag (checked directly, independent of run history, precisely because run retention can expire while the image itself does not). Refusing to silently walk past it to an older substitute -- that could back-fill content omitting a real, unbuilt change at $candidate. This needs a maintainer look at $candidate's own build-push.yml history." >&2
          return 1
        fi
      fi
      continue
    fi
    if (( has_run == 2 )); then
      # Whether a run exists at all for this candidate could not be
      # positively determined (GH_TOKEN unset, API error after retries, a
      # malformed response) -- the same inconclusive outcome
      # saf_base_commit_has_confirmed_run's own header documents for
      # BASE_SHA's push-run check, and it must be handled with the same
      # "can't prove it, don't act on it" discipline here: falling through
      # to the freshness check below would accept this candidate as the
      # resolved source on nothing more than its image happening to satisfy
      # sif_is_ancestor_or_equal, with no positive proof a real
      # build-push.yml run ever produced it at all. Fail closed instead of
      # walking further or attempting the freshness check on an unconfirmed
      # candidate.
      echo "::error::Whether any build-push.yml run exists for ancestor candidate $candidate could not be positively determined (see the error above). Refusing to treat this candidate as usable without positive proof of a recorded run, and refusing to walk past it to an older substitute either -- failing closed rather than guessing." >&2
      return 1
    fi

    # has_run == 0 here: a build-push.yml run (any event) is positively
    # confirmed to exist for this candidate -- the remaining question is
    # whether that run actually produced a confirmed-fresh image for
    # <service>.
    #
    # 2026-08-07, confirmed live against runs 31184925428/
    # 31187... for PR #1468): four untouched services each independently
    # paid the full 600s ancestor-candidate ceiling waiting on the exact same
    # candidate commit, ~40 minutes total, when a cheap, no-network,
    # git-diff-based "was <service> even touched by <candidate>" answer could
    # settle it instead. That check now runs FIRST, before paying for the
    # network wait below, not only AFTER it has already failed (the JUDGMENT
    # CALL further down still performs this exact same check post-wait, for
    # the "service WAS touched, or the check is inconclusive" paths that
    # still need the wait).
    #
    # A push-reuse-eligible service does not structurally "never get a FRESH
    # per-commit tag" for an untouched candidate, and the full-budget wait is
    # not structurally guaranteed to time out either: a SUCCESSFULLY
    # COMPLETED build-push.yml run does create the combined tag for an
    # untouched service (the Step 4 retag, carrying the older commit's
    # revision label -- exactly the allow_reverse_ancestry shape), verified
    # directly against the registry. fb05ee33's tags were missing not
    # because the wait is structurally doomed, but because that specific
    # run's merge-manifests job aborted before ever reaching the untouched
    # services (a separate, still-open finding). The
    # real, narrower justification for skipping the full-budget wait below
    # is: if the run truly never completed (aborted, or genuinely never
    # produced this tag), waiting the full budget cannot help either, and
    # the single 0/0 probe two lines down is cheap enough to try regardless
    # of which case applies -- not that success is impossible.
    #
    # A confirmed-untouched candidate is NOT skipped outright, though --
    # "never touched by this commit's own diff" is not the same claim as
    # "this exact commit's tag can never exist": it can still exist via a
    # Step 4 reverse-ancestry retag (this candidate's own build reusing an
    # even older commit's content, see sif_wait_for_fresh_base_image's own
    # allow_reverse_ancestry doc), or, in principle, a real image that
    # genuinely got published for it despite the diff -- both real shapes
    # this project's own bats fixtures for this function already exercise
    # (a candidate with an installed image but no service-touching diff).
    # So a confirmed-untouched candidate pays for exactly ONE non-polling
    # (0/0 budget) probe against its own image, the same "single attempt,
    # never a full poll loop" shape saf_resolve_untouched_backfill_source's
    # own fast path already uses for BASE_SHA itself -- if that probe
    # resolves immediately, this candidate genuinely has a usable image and
    # is used directly; if not, this moves on to the next candidate without
    # ever entering the full-budget poll loop below.
    #
    # KNOWN, ACCEPTED TRADE-OFF (not a #808 fail-open break): the 0/0 probe
    # does not call saf_candidate_run_is_active() first, unlike the post-wait
    # JUDGMENT CALL further down. So if this candidate's own run is still
    # genuinely IN FLIGHT (not aborted, not yet reached the retag step), the
    # probe will not see the tag yet and this candidate is skipped in favor
    # of an older one -- where the earlier code would instead have waited
    # out the full budget and likely found it. This is a deliberate
    # freshness-for-speed trade, not an oversight: the older ancestor this
    # falls back to still carries the same full untouched-diff proof, so
    # nothing here weakens the fail-closed safety guarantee, only which
    # (still-valid) candidate gets picked. If this trade-off proves too
    # aggressive in practice, the fix is to call saf_candidate_run_is_active()
    # before the 0/0 probe and only skip on a confirmed-not-active answer --
    # deliberately not done here, to keep this change minimal and
    # single-purpose.
    local candidate_pre_service_untouched_status=0
    saf_base_commit_service_untouched "$candidate" "$classify_key" "$git_dir" || candidate_pre_service_untouched_status=$?
    # Plain full-SHA string construction, not saf_resolve_sha_image_ref: the
    # untouched-candidate fast path immediately below is itself a single
    # real probe against this exact reference (no pre-probing needed to
    # avoid duplicating it), and the run-bearing short/extended waits
    # further down are this candidate's own real freshness checks too --
    # legacy-tag support for a run-bearing candidate is handled once, at
    # this candidate's own give-up point (after both waits below have
    # failed), not pre-probed here.
    ancestor_image="ghcr.io/${repository}/${service}:sha-${candidate}"
    if (( candidate_pre_service_untouched_status == 0 )); then
      if sif_wait_for_fresh_base_image "$ancestor_image" "$candidate" "$service" 0 0 "$freshness_poll_interval_seconds" true >/dev/null; then
        printf '%s\n' "$candidate"
        return 0
      fi
      # What: tries $candidate's own legacy short-SHA tag once before this
      #   fast path gives up, matching the run-bearing waits below.
      # Why: without this, an untouched pre-cutover candidate whose only
      #   real tag is the legacy form was skipped past on a one-shot
      #   full-SHA miss that never reached the legacy probe.
      # From: Issue #1095 (G2) | PR #1611
      local legacy_image
      if legacy_image="$(saf_legacy_sha_image_ref "$repository" "$service" "$candidate" "$git_dir")"; then
        printf '%s\n' "$candidate"
        return 0
      fi
      echo "::notice::Ancestor candidate $candidate has a confirmed build-push.yml run, but $service ($classify_key) was not touched by it, and a single non-polling probe against its per-commit tag (both full-SHA and legacy short-SHA forms) found nothing yet -- either that run never completed (aborted or genuinely never retagged this service) or its retag simply hasn't landed yet. Skipping the full network wait and continuing to the next candidate, which still carries its own full untouched-diff proof." >&2
      continue
    fi

    # Deliberately NOT redirecting stderr here (only stdout): the
    # ::notice::/::warning::/::error:: diagnostic lines
    # sif_wait_for_fresh_base_image writes to stderr must still reach the job
    # log even though this function's own stdout is captured by its caller
    # via `$(...)`.
    # allow_reverse_ancestry=true: same immutable-per-commit-tag reasoning
    # as the has_run==1 branch above.
    if sif_wait_for_fresh_base_image "$ancestor_image" "$candidate" "$service" \
      "$freshness_timeout_seconds" "$freshness_hard_ceiling_seconds" "$freshness_poll_interval_seconds" true >/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi

    # The short-ceiling attempt failed. Before giving up per the JUDGMENT
    # CALL below, positively check whether this candidate's own build is
    # still genuinely running -- a real race (see saf_candidate_run_is_active's
    # own header), not a hypothetical: only a POSITIVE confirmation of
    # activity is worth a second, longer-budget attempt at the exact same
    # candidate; an inconclusive or confirmed-not-active answer changes
    # nothing about the JUDGMENT CALL that already applied before this
    # check existed.
    local activity_status=0
    saf_candidate_run_is_active "$repository" "$candidate" || activity_status=$?
    if (( activity_status == 0 )); then
      echo "::warning::Ancestor candidate $candidate's own build-push.yml run for $service appears to still be active (not yet completed) -- extending the wait to ${extended_hard_ceiling_seconds}s (the same patience BASE_SHA's own possibly-in-progress build gets) before giving up on this candidate." >&2
      # allow_reverse_ancestry=true: same immutable-per-commit-tag reasoning
      # as the two checks above.
      if sif_wait_for_fresh_base_image "$ancestor_image" "$candidate" "$service" \
        "$extended_timeout_seconds" "$extended_hard_ceiling_seconds" "$freshness_poll_interval_seconds" true >/dev/null; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi

    # Both the short attempt above and (if this candidate's own build was
    # confirmed still active) the extended retry have now failed against
    # the canonical full-SHA tag. Before falling through to the JUDGMENT
    # CALL below, try this candidate's own legacy 7-char tag exactly once
    # (a single non-polling probe, not a second full wait) -- this
    # candidate is, by construction, further back in history than
    # <base_sha>, so it is exactly the kind of pre-cutover commit whose
    # only real tag may still be the legacy short-SHA form.
    local legacy_image
    if legacy_image="$(saf_legacy_sha_image_ref "$repository" "$service" "$candidate" "$git_dir")"; then
      printf '%s\n' "$candidate"
      return 0
    fi

    # Found a run-bearing candidate whose image never became confirmed-fresh
    # under either tag format -- even after the activity-confirmed extended
    # retry, if one applied. Before applying the JUDGMENT CALL above (stop,
    # do not walk further):
    # re-derive the same service-scoped untouched check the PRE-wait check
    # above already ran. This is now normally redundant (a
    # positive pre-check already `continue`d past this candidate before ever
    # reaching the wait), EXCEPT when the pre-check was inconclusive (status
    # 2 -- a transient git/fetch issue), in which case the wait still ran per
    # the pre-check's own fall-through, and this independent re-derivation
    # gets a second chance to positively resolve it now. Kept deliberately
    # separate from the pre-check (not cached/shared) for the same reason
    # BASE_SHA's own pre/post push-run check stays independently re-derived
    # in saf_resolve_untouched_backfill_source: a fast-path bug can only cost
    # time this way, never safety. If <classify_key>'s own service was
    # untouched by THIS candidate's own diff, having reached this point means
    # even the full-budget wait above found no usable tag for it -- expected
    # for Step 4 reuse when the run never completed a retag for this
    # service (aborted, or the diff-implied reuse just never got confirmed
    # fresh in time), not proof of a broken build -- continue to the next
    # candidate instead of stopping. Only when the service WAS actually
    # touched (or the check is inconclusive here too) does the original
    # JUDGMENT CALL still apply: a real, seemingly-broken build for a
    # service-affecting commit is a genuine CI problem worth surfacing on its
    # own, not a reason to keep hunting for an even older substitute.
    local candidate_run_service_untouched_status=0
    saf_base_commit_service_untouched "$candidate" "$classify_key" "$git_dir" || candidate_run_service_untouched_status=$?
    if (( candidate_run_service_untouched_status == 0 )); then
      echo "::notice::Ancestor candidate $candidate has a confirmed build-push.yml run, but $service ($classify_key) was not touched by it, and even the full-budget wait found no usable tag for it -- expected for Step 4 reuse or an unrelated change when the retag never completed, not proof of a broken build. Continuing to the next candidate." >&2
      continue
    fi
    echo "::error::Ancestor candidate $candidate has a confirmed build-push.yml run and $classify_key's own service was touched by it (or that check was inconclusive, status $candidate_run_service_untouched_status), but its $service image never became confirmed-fresh. Stopping here instead of walking further back -- this needs a maintainer look at $candidate's own build-push.yml run." >&2
    return 1
  done <<< "$candidates"

  return 1
}

# saf_resolve_untouched_backfill_source <repository> <service> <classify_key> <base_sha> \
#     <base_freshness_timeout_seconds> <base_freshness_hard_ceiling_seconds> \
#     <ancestor_freshness_timeout_seconds> <ancestor_freshness_hard_ceiling_seconds> \
#     <ancestor_extended_freshness_timeout_seconds> <ancestor_extended_freshness_hard_ceiling_seconds> \
#     <freshness_poll_interval_seconds> <ancestor_search_depth> [git_dir] [base_ref]
#
# The single shared orchestrator both callers (scripts/tracked/ensure-pr-staging-images.sh
# and build-push.yml's own "Ensure PR staging tags exist for full-setup
# services" step) use to decide what to back-fill an untouched service's PR
# staging tag from. Neither caller reimplements this decision independently:
# both need the identical exact-BASE_SHA wait, the identical positive-proof
# gate before any fallback, and the identical bounded ancestor walk, so a
# workflow/deploy-changing PR based on a never-built commit must not hit an
# unwinnable wait in one caller's job while the other caller has already
# been fixed -- reimplementing this logic a second time anywhere is a defect
# in itself, not just a maintenance inconvenience.
#
# THREE SEPARATE budget pairs on purpose, not one shared pair:
#   - <base_freshness_timeout_seconds>/<base_freshness_hard_ceiling_seconds>
#     govern ONLY the wait against BASE_SHA's own image (the NORMAL PATH,
#     step 2 below). This is the one wait in this whole mechanism that can
#     legitimately be racing a real, still-building push run -- exactly the
#     scenario a confirmed push-triggered run (pre_run_status/post_run_status
#     == 0 below) describes -- so it needs the same congestion-scale headroom
#     wait_for_touched_image() in scripts/tracked/ensure-pr-staging-images.sh already
#     gets for the identical reason, not a short ceiling tuned for "this
#     should already exist or never will".
#   - <ancestor_freshness_timeout_seconds>/<ancestor_freshness_hard_ceiling_seconds>
#     govern ONLY saf_find_built_ancestor's per-candidate INITIAL freshness
#     checks (both the fast-path and step-3 call sites below). An ancestor
#     candidate is, by construction, a commit further back in history than
#     BASE_SHA that saf_base_commit_has_confirmed_run already confirmed has a
#     REAL recorded run -- if that run's image doesn't already exist by the
#     time this mechanism first looks, it never will (there is no
#     "still building" case for a commit further in the past than one already
#     checked), so a short ceiling here is a deliberate tuning choice, not a
#     correctness gap.
#   - <ancestor_extended_freshness_timeout_seconds>/<ancestor_extended_freshness_hard_ceiling_seconds>
#     govern ONLY the ONE-TIME extended retry saf_find_built_ancestor gives a
#     candidate whose own build-push.yml run is positively confirmed still
#     active (saf_candidate_run_is_active) after its initial short-budget
#     check above already failed. Deliberately NOT the same parameter as
#     base_freshness_* even though this project's own two real callers
#     currently pass the identical VALUE for both (900/5400) for
#     scripts/tracked/ensure-pr-staging-images.sh: reusing base_freshness_* here would
#     make build-push.yml's "Ensure PR staging tags exist for full-setup
#     services" step (inside the full-setup-validate job, timeout-minutes: 30)
#     implicitly inherit a fresh, up-to-5400s (90-minute) wait it structurally
#     cannot afford -- that job would simply be killed by its own GitHub
#     Actions job timeout partway through the extension, wasting the runner's
#     time on a wait that can never complete and never rescuing an image that
#     appears more than roughly the job's remaining budget into the
#     extension. Making this its own explicit parameter lets each of the two
#     real callers size it honestly against its OWN job envelope instead of
#     silently inheriting a value tuned for the other caller's very different
#     (100-minute) budget -- see each real call site's own comment for the
#     value it actually passes and why.
#   Collapsing any of these three into a shared pair is a real failure mode,
#   not a theoretical one: a short ceiling tuned for "an already-checked
#   historical ancestor commit's image either exists now or never will" is far
#   too short for BASE_SHA's own wait, where a confirmed push-triggered run
#   can still legitimately be mid-build; and a budget generous enough for a
#   100-minute-timeout caller's extended retry is not automatically safe for
#   every OTHER caller sharing this same function -- build-push.yml's own
#   30-minute-timeout call site is the concrete proof.
#
# Sequence:
#   1. FAST PATH (reordering): before running the full bounded freshness
#      wait, check whether BASE_SHA can already be POSITIVELY confirmed as a
#      deliberate skip for THIS service, via either of two independent
#      routes:
#        a. SERVICE-SCOPED (saf_base_commit_service_untouched): <classify_key>
#           itself was not touched by BASE_SHA's own diff against its first
#           parent -- sufficient on its own, no run-status check needed,
#           since a service build/build-arm64's own per-service matrix
#           condition would skip it here regardless of whether some OTHER
#           service's build for the same push is still in flight.
#        b. COMMIT-WIDE (the original check): every path BASE_SHA changed
#           matches the ignore-list (saf_base_commit_paths_are_ignorable) AND
#           no push-triggered run exists for it at all
#           (saf_base_commit_has_confirmed_run, event=push).
#      When either route positively confirms a deliberate skip, this skips
#      the long wait: try one single, non-polling existence/freshness
#      attempt against BASE_SHA's own image first (a non-push trigger, or a
#      push that built OTHER services, may already have produced a valid
#      image for this exact commit -- see saf_base_commit_has_confirmed_run's
#      own scoping note), and only if that also comes up empty, go straight
#      to the ancestor walk. This turns a never-going-to-build-THIS-SERVICE
#      base commit into a fast, seconds-scale failure/fallback instead of
#      waiting out the full freshness ceiling first for no reason.
#   2. NORMAL PATH: whenever neither route above positively confirms a
#      deliberate skip, run the full bounded sif_wait_for_fresh_base_image
#      wait exactly as before. This is the conservative default: it is what
#      actually protects the #626/#808 fail-closed property for a real,
#      in-flight, or broken build, and for a paths-check that could not
#      positively rule out a genuine service change riding along with the
#      docs change.
#   3. POST-WAIT DECISION: if the normal wait fails, re-derive (independently
#      of whatever the fast path found, so a fast-path bug can only cost
#      time, never safety) the same two routes. Only when at least one
#      positively confirms a deliberate skip does this proceed to the
#      ancestor walk; any other outcome (both inconclusive, or a real
#      service-affecting change confirmed present) preserves today's strict
#      failure with no fallback attempted.
#
# Echoes the resolved source image ref (e.g.
# ghcr.io/org/repo/service:sha-abc1234) on stdout on success -- this may be
# BASE_SHA's own image (the common case) or a substituted ancestor's image
# (the fallback case). All human-readable diagnostic output goes to stderr.
# Returns 0 on success, 1 on fail-closed (the caller must not back-fill
# anything and must treat this as a hard failure for the service, exactly as
# before this mechanism existed).
saf_resolve_untouched_backfill_source() {
  local repository="$1" service="$2" classify_key="$3" base_sha="$4"
  local base_freshness_timeout_seconds="$5" base_freshness_hard_ceiling_seconds="$6"
  local ancestor_freshness_timeout_seconds="$7" ancestor_freshness_hard_ceiling_seconds="$8"
  local ancestor_extended_freshness_timeout_seconds="$9" ancestor_extended_freshness_hard_ceiling_seconds="${10}"
  local freshness_poll_interval_seconds="${11}" ancestor_search_depth="${12}"
  local git_dir="${13:-.}"
  local base_ref="${14:-}"
  # See saf_find_built_ancestor's own comment for why this is set at all, and
  # why it is `local -x` (exported, but restored to the caller's own value when
  # this function returns) rather than a bare `export`:
  # sif_wait_for_fresh_base_image (called directly below, and indirectly via
  # saf_find_built_ancestor) reads STAGING_FRESHNESS_GIT_DIR from the
  # environment, not a parameter.
  local -x STAGING_FRESHNESS_GIT_DIR="$git_dir"

  # Plain full-SHA string construction, not saf_resolve_sha_image_ref: Step 1
  # and Step 2 below are $base_sha's own real freshness probes already, so
  # pre-probing here would just duplicate one of them for the common
  # (new-format) case. No legacy-tag fallback needed for $base_sha itself
  # either -- it is this PR's own current base commit (recent, not a
  # historical walk-back target), and if its image genuinely does not exist
  # under either tag format, both Step 1 and Step 2 already fall through to
  # saf_find_built_ancestor, whose own candidate walk carries its own
  # legacy-tag support for exactly the older commits that need it.
  local base_image
  base_image="ghcr.io/${repository}/${service}:sha-${base_sha}"
  local ancestor_sha

  # Step 1: fast-path pre-check (see this function's own header). Either
  # route (service-scoped or commit-wide) independently confirming a
  # deliberate skip is enough to skip the long wait; only when NEITHER does
  # this fall through to the normal (slow, but always-safe) path below.
  local fast_path_confirmed_zero=false
  local fast_path_reason=""
  local pre_service_untouched_status=0
  saf_base_commit_service_untouched "$base_sha" "$classify_key" "$git_dir" || pre_service_untouched_status=$?
  if (( pre_service_untouched_status == 0 )); then
    fast_path_confirmed_zero=true
    fast_path_reason="$service ($classify_key) was not touched by $base_sha itself"
  else
    local pre_paths_status=0
    saf_base_commit_paths_are_ignorable "$base_sha" "$git_dir" || pre_paths_status=$?
    if (( pre_paths_status == 0 )); then
      local pre_run_status=0
      saf_base_commit_has_confirmed_run "$repository" "$base_sha" "push" || pre_run_status=$?
      if (( pre_run_status == 1 )); then
        fast_path_confirmed_zero=true
        fast_path_reason="$base_sha has no push-triggered build-push.yml run, and every path it changed matches build-push.yml's own push paths-ignore"
      fi
    fi
  fi

  if [[ "$fast_path_confirmed_zero" == true ]]; then
    echo "::notice::$fast_path_reason -- skipping the long freshness wait for $service and checking directly for a usable image instead." >&2
    # Single non-polling attempt (0/0 budget): a non-push trigger may
    # already have produced a valid image for this exact commit despite the
    # confirmed absence of a push run (see saf_base_commit_has_confirmed_run's
    # own scoping note) -- worth one direct check before assuming the
    # ancestor walk is needed at all. If it's not already there, waiting
    # longer cannot help: no push run exists, and the paths are confirmed
    # ignorable, so there is no in-flight push build to wait out.
    #
    # allow_reverse_ancestry=true (2026-08-07): $base_image is
    # always an immutable per-commit sha-<base_sha> tag here, never a mutable
    # channel tag -- exactly the same safety condition
    # sif_wait_for_fresh_base_image's own allow_reverse_ancestry doc requires,
    # and exactly the same reasoning saf_find_built_ancestor's own candidate
    # checks already rely on (see that function's own comments). This
    # specific call site is the one F-20 named as exposed:
    # push-reuse (Step 4) can retag $base_image FOR $base_sha's own
    # commit while content-copying an older commit's build, which keeps that
    # older commit's org.opencontainers.image.revision label (imagetools
    # create copies labels byte-for-byte, never rewrites them) -- without
    # allow_reverse_ancestry, that legitimately-safe retag would be wrongly
    # reported as "stale" here and this would fall through to the ancestor
    # walk unnecessarily, even though $base_sha's own image already exists
    # and is exactly as safe to use as an ancestor candidate's own
    # reverse-ancestry match already is.
    if sif_wait_for_fresh_base_image "$base_image" "$base_sha" "$service" 0 0 "$freshness_poll_interval_seconds" true >/dev/null; then
      printf '%s\n' "$base_image"
      return 0
    fi
    if [[ -n "$base_ref" ]]; then
      local descendant_sha
      if descendant_sha="$(saf_find_built_descendant "$repository" "$base_sha" "$base_ref" "$service" "$classify_key" "$ancestor_search_depth" \
        "$ancestor_freshness_timeout_seconds" "$ancestor_freshness_hard_ceiling_seconds" "$freshness_poll_interval_seconds" \
        "$ancestor_extended_freshness_timeout_seconds" "$ancestor_extended_freshness_hard_ceiling_seconds" "$git_dir")"; then
        local descendant_image
        descendant_image="$(saf_resolve_sha_image_ref "$repository" "$service" "$descendant_sha" "$git_dir")"
        echo "::notice::Substituting later base-branch descendant $descendant_sha for base commit $base_sha ($service stayed provably unchanged from $base_sha through ${base_ref}, and that later commit published a freshness-confirmed per-commit image). (re)pointing at $descendant_image, its own immutable per-commit tag -- never the mutable nightly/latest channel." >&2
        printf '%s\n' "$descendant_image"
        return 0
      fi
    fi
    if ! ancestor_sha="$(saf_find_built_ancestor "$repository" "$base_sha" "$service" "$classify_key" "$ancestor_search_depth" \
      "$ancestor_freshness_timeout_seconds" "$ancestor_freshness_hard_ceiling_seconds" "$freshness_poll_interval_seconds" \
      "$ancestor_extended_freshness_timeout_seconds" "$ancestor_extended_freshness_hard_ceiling_seconds" "$git_dir")"; then
      echo "::error::No usable ancestor of $base_sha was found within $ancestor_search_depth commits with both a recorded build-push.yml run and a freshness-confirmed $service image. Refusing to back-fill $service's PR staging tag -- this needs a maintainer look at $base_sha's own ancestor history." >&2
      return 1
    fi
    local ancestor_image
    ancestor_image="$(saf_resolve_sha_image_ref "$repository" "$service" "$ancestor_sha" "$git_dir")"
    echo "::notice::Substituting nearest built ancestor $ancestor_sha for base commit $base_sha ($service was never built for $base_sha itself). (re)pointing at $ancestor_image, its own immutable per-commit tag -- never the mutable nightly/latest channel." >&2
    printf '%s\n' "$ancestor_image"
    return 0
  fi

  # Step 2: normal path -- the full bounded wait against BASE_SHA's own
  # image, unchanged from this mechanism's pre-fallback behavior. Uses the
  # LONG (base_freshness_*) budget deliberately -- see this function's own
  # header for why this specific wait, unlike the ancestor-candidate checks,
  # needs congestion-scale headroom.
  #
  # allow_reverse_ancestry=true (2026-08-07): same reasoning as
  # Step 1's fast-path call above -- $base_image is always an immutable
  # per-commit tag, so a push-reuse retag that kept an older source commit's
  # revision label is exactly as safe to accept here as it already is for
  # every ancestor-candidate check in saf_find_built_ancestor.
  echo "::notice::$service is untouched by this PR; waiting for its PR-base per-commit image ($base_image) to exist and be confirmed built at $base_sha before backfilling..." >&2
  if sif_wait_for_fresh_base_image "$base_image" "$base_sha" "$service" \
    "$base_freshness_timeout_seconds" "$base_freshness_hard_ceiling_seconds" "$freshness_poll_interval_seconds" true >/dev/null; then
    printf '%s\n' "$base_image"
    return 0
  fi

  # Step 3: post-wait decision -- re-derive independently of the fast-path
  # pre-check above (a stale/incorrect fast-path result must never be able
  # to unlock the fallback; only a fresh, positive confirmation right here
  # does). Same two independent routes as Step 1's fast path; the
  # service-scoped route is checked first and, if it confirms $service was
  # not touched by $base_sha, skips the run/paths checks entirely (they
  # exist to answer the same question a different, less direct way).
  local post_reason=""
  local post_service_untouched_status=0
  saf_base_commit_service_untouched "$base_sha" "$classify_key" "$git_dir" || post_service_untouched_status=$?
  if (( post_service_untouched_status == 0 )); then
    post_reason="$service ($classify_key) was not touched by $base_sha itself"
  else
    local post_run_status=0
    saf_base_commit_has_confirmed_run "$repository" "$base_sha" "push" || post_run_status=$?
    if (( post_run_status == 0 )); then
      echo "::error::Refusing to back-fill $service's PR staging tag from $base_image -- its base commit could not be confirmed fresh enough (see the error above), AND a push-triggered build-push.yml run does exist for $base_sha (so this is a real build problem, not an unbuildable commit -- no ancestor fallback applies here). Silently validating a stale base-channel image here is exactly the #626/#808 bug this mechanism must not reintroduce." >&2
      return 1
    fi
    if (( post_run_status == 2 )); then
      echo "::error::Refusing to back-fill $service's PR staging tag from $base_image -- its base commit could not be confirmed fresh enough, and whether build-push.yml ever ran for $base_sha on a push event could not be positively determined either (see above). Failing closed rather than assuming the ancestor-fallback path is safe." >&2
      return 1
    fi

    local post_paths_status=0
    saf_base_commit_paths_are_ignorable "$base_sha" "$git_dir" || post_paths_status=$?
    if (( post_paths_status != 0 )); then
      echo "::error::Refusing to back-fill $service's PR staging tag from $base_image -- its base commit could not be confirmed fresh enough, and its changed paths could not be positively confirmed to all match build-push.yml's own push paths-ignore list either (see this file's own header for why that distinction matters). Failing closed rather than assuming the ancestor-fallback path is safe -- a real, non-doc change riding along with this commit must not be silently skipped." >&2
      return 1
    fi
    post_reason="$base_sha has no push-triggered build-push.yml run, and every path it changed matches build-push.yml's own push paths-ignore"
  fi

  echo "::notice::$post_reason -- not a broken build. Searching up to $ancestor_search_depth ancestor commits for the nearest one with both a recorded build-push.yml run and a freshness-confirmed $service image to back-fill from instead." >&2
  if [[ -n "$base_ref" ]]; then
    local descendant_sha
    if descendant_sha="$(saf_find_built_descendant "$repository" "$base_sha" "$base_ref" "$service" "$classify_key" "$ancestor_search_depth" \
      "$ancestor_freshness_timeout_seconds" "$ancestor_freshness_hard_ceiling_seconds" "$freshness_poll_interval_seconds" \
      "$ancestor_extended_freshness_timeout_seconds" "$ancestor_extended_freshness_hard_ceiling_seconds" "$git_dir")"; then
      local descendant_image
      descendant_image="$(saf_resolve_sha_image_ref "$repository" "$service" "$descendant_sha" "$git_dir")"
      echo "::notice::Substituting later base-branch descendant $descendant_sha for base commit $base_sha ($service stayed provably unchanged from $base_sha through ${base_ref}, and that later commit published a freshness-confirmed per-commit image). (re)pointing at $descendant_image, its own immutable per-commit tag -- never the mutable nightly/latest channel." >&2
      printf '%s\n' "$descendant_image"
      return 0
    fi
  fi
  if ! ancestor_sha="$(saf_find_built_ancestor "$repository" "$base_sha" "$service" "$classify_key" "$ancestor_search_depth" \
    "$ancestor_freshness_timeout_seconds" "$ancestor_freshness_hard_ceiling_seconds" "$freshness_poll_interval_seconds" \
    "$ancestor_extended_freshness_timeout_seconds" "$ancestor_extended_freshness_hard_ceiling_seconds" "$git_dir")"; then
    echo "::error::No usable ancestor of $base_sha was found within $ancestor_search_depth commits with both a recorded build-push.yml run and a freshness-confirmed $service image. Refusing to back-fill $service's PR staging tag -- this needs a maintainer look at $base_sha's own ancestor history." >&2
    return 1
  fi
  local ancestor_image
  ancestor_image="$(saf_resolve_sha_image_ref "$repository" "$service" "$ancestor_sha" "$git_dir")"
  echo "::notice::Substituting nearest built ancestor $ancestor_sha for base commit $base_sha ($service was never built for $base_sha itself). (re)pointing at $ancestor_image, its own immutable per-commit tag -- never the mutable nightly/latest channel." >&2
  printf '%s\n' "$ancestor_image"
  return 0
}
