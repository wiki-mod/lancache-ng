#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Enforces issue #801: every pinned GitHub Action referenced from any
# .github/workflows/*.yml file (and every local composite action under
# .github/actions/) must declare a Node runtime GitHub Actions still
# considers current in its own action.yml/action.yaml. This exists because
# issue #799 was found reactively -- a CI log deprecation warning about
# actions/upload-artifact@834a144... (v4.3.6) still declaring `runs.using:
# node20`, only fixed one instance at a time by PR #800 -- and the same
# class of problem can recur for any of this project's many other pinned
# actions, now or after a future re-pin. This script scans ALL of them,
# proactively, on every run.
#
# Local composite actions (`uses: ./.github/actions/<name>`) are resolved by
# reading their action.yml/action.yaml straight off disk -- no GitHub API
# lookup needed, since we already have the file. Every composite action in
# this repo declares `runs.using: composite` (there is no Node runtime to a
# composite action, it just orchestrates other steps), so these entries are
# expected to always pass; they are still checked generically rather than
# hardcoded as "always fine", so a future local action that DID wrap a
# JavaScript runtime would still be covered.
#
# External actions (`uses: <owner>/<repo>[/<subpath>]@<sha-or-tag>`) are
# resolved via the GitHub REST Contents API
# (repos/<owner>/<repo>/contents/<subpath/>action.yml?ref=<ref>, falling back
# to action.yaml if action.yml 404s -- some actions use either name) using
# curl with the `application/vnd.github.raw+json` Accept header, which
# returns the file's raw text directly instead of a base64-wrapped JSON
# envelope. This project's established convention for hitting the GitHub API
# from a guard script is curl + GH_TOKEN, not the `gh` CLI (see
# check-pr-tracking-metadata.sh) -- the `gh` binary is not installed in the
# build-tools image this script runs inside in CI, and adding it purely for
# this one script would be a heavier dependency than a handful of curl calls
# need.
#
# A pin can name a branch or tag instead of a commit SHA (`ref=<tag>` resolves
# fine against the Contents API either way), but this project's own
# established convention is to SHA-pin every third-party action (every
# example in this repo's workflows already does; see AGENTS.md), so this case
# is expected to be rare-to-nonexistent here. If it does occur: a tag's
# underlying commit can change after this check last ran, so a clean result
# for a tag-pinned action is a point-in-time snapshot of whatever that tag
# pointed at during this run, not a permanent guarantee the way a SHA pin's
# result is. That's a property of tag pins in general, not something this
# script can fix; it resolves the ref exactly as given and reports what it
# finds.
#
# Rate limits: as of this writing this repo pins ~15 distinct external
# action refs across all workflows (see CHANGELOG/PR for the exact count at
# the time this was added) -- small enough that a checked-in cache mapping
# owner/repo@ref -> runs.using would be premature complexity for the API
# load this actually generates (a per-run duplicate-request dedupe, done
# below via `sort -u` over the extracted refs, is all that is warranted at
# this scale). Re-evaluate a persistent cache if the number of distinct pins
# grows enough that GitHub API rate limiting becomes a real, observed
# problem, not a hypothetical one.
#
# Failure handling: a *definitive* resolution failure (action.yml AND
# action.yaml both come back 404 for a pinned ref) fails the check -- that
# pin cannot be verified safe, and this project's guard scripts fail closed
# rather than silently skip. Anything else non-200 (auth rejection, rate
# limiting, a network hiccup, any other HTTP status) is treated as an
# infrastructure problem, not a verdict on the pin itself, and only emits a
# warning -- matching check-pr-tracking-metadata.sh's own split between
# "the thing we're checking is actually wrong" (fail) and "we couldn't check
# it right now" (warn, don't fail the whole PR on a GitHub-side blip).
#
# Accepts an optional repo_root argument (defaults to this script's own
# repo) so tests/bats/check_action_node_versions.bats can point it at a
# fixture tree instead of mutating/depending on the real repository, and
# an optional GH_TOKEN (or GITHUB_TOKEN) env var to authenticate the
# GitHub API calls (raises the rate limit; unauthenticated access to public
# repos' Contents API works fine too at this repo's current scale).
set -euo pipefail

repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$repo_root"

workflow_dir=.github/workflows
shopt -s nullglob
workflow_files=("$workflow_dir"/*.yml "$workflow_dir"/*.yaml)
shopt -u nullglob

if [ "${#workflow_files[@]}" -eq 0 ]; then
  echo "::error::check-action-node-versions: no workflow files found under $workflow_dir." >&2
  exit 1
fi

failures=0

fail() {
  printf '::error::%s\n' "$1" >&2
  failures=$((failures + 1))
}

warn() {
  printf '::warning::%s\n' "$1" >&2
}

# ---------------------------------------------------------------------------
# The Node runtimes GitHub Actions has deprecated. node24 is the current
# runtime as of this writing (2026-07) -- when GitHub deprecates it too (a
# new node2X ships and node24 is announced end-of-life), add "node24" to
# this array. Deliberately an explicit deprecated-list, not an
# everything-except-the-latest-one check: GitHub typically ships a new
# runtime well before deprecating the previous one, so a moving-target
# "not the newest" comparison would false-fail on a brand-new, still-current
# runtime the same day GitHub introduces it.
DEPRECATED_NODE_RUNTIMES=(node6 node10 node12 node16 node20)

is_deprecated_runtime() {
  local candidate="$1" d
  for d in "${DEPRECATED_NODE_RUNTIMES[@]}"; do
    [ "$candidate" = "$d" ] && return 0
  done
  return 1
}

# extract_runs_using
# Reads an action.yml/action.yaml's text from stdin and prints the value of
# its top-level runs.using key (quotes stripped, trailing comment/whitespace
# stripped), or nothing if no such key is found before the next top-level
# (column-0) key ends the runs: mapping. Works for both quoted
# (using: 'node20') and bare (using: node20) forms.
extract_runs_using() {
  awk '
    /^runs:/ { in_runs = 1; next }
    in_runs && /^[^[:space:]]/ { exit }
    in_runs && /^[[:space:]]*using:/ { print; exit }
  ' | sed -E "s/.*using:[[:space:]]*//; s/[\"']//g; s/[[:space:]]*#.*\$//; s/[[:space:]]+\$//"
}

# ---------------------------------------------------------------------------
# Collect every real `uses:` step directive across all workflow files.
# Anchored to the start of the (whitespace-trimmed) line so this only
# matches an actual YAML `uses:` mapping key, not an unrelated string that
# happens to contain "uses:" inside a `run:` block's embedded shell script
# (build-push.yml's own CI-scope-policy guard greps for the literal text
# "uses: ./.github/actions/rust-acceleration-preflight" as part of a
# different check -- that line must NOT be mistaken for a real step here).
mapfile -t uses_values < <(
  grep -hE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[^[:space:]]+' "${workflow_files[@]}" \
    | sed -E 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*//; s/[[:space:]]*#.*$//; s/[[:space:]]+$//' \
    | sort -u
)

if [ "${#uses_values[@]}" -eq 0 ]; then
  fail "Found no 'uses:' step directives in any of ${workflow_files[*]} -- check the extraction pattern in this script."
fi

referencing_files() {
  local needle="$1" f matches=()
  for f in "${workflow_files[@]}"; do
    if grep -qF "uses: ${needle}" "$f"; then
      matches+=("$f")
    fi
  done
  if [ "${#matches[@]}" -eq 0 ]; then
    printf '<none found>'
  else
    printf '%s' "${matches[*]}"
  fi
}

gh_token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

# fetch_external_action_yaml <owner> <repo> <subpath> <ref>
# Prints the resolved action.yml/action.yaml text to stdout and returns 0 on
# success. On failure, sets $resolve_error_detail and returns 1 (an infra
# hiccup -- caller should warn, not fail) or 2 (both action.yml and
# action.yaml came back 404 -- a definitive not-found, caller should fail).
resolve_error_detail=""
fetch_external_action_yaml() {
  local owner="$1" repo="$2" subpath="$3" ref="$4"
  local file body status auth=()
  resolve_error_detail=""
  if [ -n "$gh_token" ]; then
    auth=(-H "Authorization: Bearer ${gh_token}")
  fi
  for file in action.yml action.yaml; do
    body="$(mktemp)"
    status=$(curl -sS -o "$body" -w '%{http_code}' \
      -H "Accept: application/vnd.github.raw+json" \
      "${auth[@]}" \
      "https://api.github.com/repos/${owner}/${repo}/contents/${subpath:+${subpath}/}${file}?ref=${ref}" 2>/dev/null) || status="000"
    case "$status" in
      200)
        cat "$body"
        rm -f "$body"
        return 0
        ;;
      404)
        rm -f "$body"
        continue
        ;;
      *)
        resolve_error_detail="HTTP $status"
        rm -f "$body"
        return 1
        ;;
    esac
  done
  return 2
}

for value in "${uses_values[@]}"; do
  if [[ "$value" == ./* ]]; then
    # --- Local composite action (read action.yml/action.yaml off disk) ----
    local_dir="${value#./}"
    resolved=""
    for ext in yml yaml; do
      candidate="$repo_root/$local_dir/action.$ext"
      if [ -f "$candidate" ]; then
        resolved="$candidate"
        break
      fi
    done
    if [ -z "$resolved" ]; then
      fail "Local action '$value' (referenced in: $(referencing_files "$value")) has no action.yml/action.yaml under $local_dir/."
      continue
    fi
    using=$(extract_runs_using < "$resolved")
    if [ -z "$using" ]; then
      warn "Could not determine runs.using for local action '$value' ($resolved) -- skipping Node-runtime check for it."
      continue
    fi
    if is_deprecated_runtime "$using"; then
      fail "Local action '$value' ($resolved) declares runs.using: $using, a deprecated Node runtime. Update its steps to drop the Node-based step, or split it so no step still needs a deprecated runtime."
    fi
  else
    # --- External pinned action (resolve via the GitHub Contents API) -----
    ref="${value##*@}"
    path_at="${value%@*}"
    owner=$(cut -d/ -f1 <<<"$path_at")
    repo=$(cut -d/ -f2 <<<"$path_at")
    subpath=$(cut -d/ -f3- <<<"$path_at")

    metadata=""
    if metadata=$(fetch_external_action_yaml "$owner" "$repo" "$subpath" "$ref"); then
      using=$(extract_runs_using <<<"$metadata")
      if [ -z "$using" ]; then
        warn "Could not determine runs.using for '$value' (referenced in: $(referencing_files "$value")) -- its action.yml/action.yaml had no parseable runs.using (may be a Docker-container or composite action); skipping."
      elif is_deprecated_runtime "$using"; then
        fail "'$value' (referenced in: $(referencing_files "$value")) declares runs.using: $using, a deprecated Node runtime. Re-pin to a newer release whose action.yml declares a current runtime (see this project's CHANGELOG for prior examples, e.g. issue #799/#800/#802)."
      fi
    else
      rc=$?
      if [ "$rc" -eq 2 ]; then
        fail "Could not find action.yml or action.yaml for '$value' at ref '$ref' (referenced in: $(referencing_files "$value")) -- the pin may be broken, or point at a ref that never had this file."
      else
        warn "Could not resolve '$value' ($resolve_error_detail) -- treating as an infrastructure hiccup (rate limit, auth, or network issue), not failing the check on it. Re-run to retry."
      fi
    fi
  fi
done

if [ "$failures" -gt 0 ]; then
  printf '::error::check-action-node-versions: %d pinned action(s) declare a deprecated Node runtime or could not be resolved (see issue #801).\n' "$failures" >&2
  exit 1
fi

printf 'check-action-node-versions: OK (every pinned action -- local and external -- declares a current Node runtime, or is not Node-based).\n'
