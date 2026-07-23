#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# Warn-only CI guard (issue #893, optional follow-up to #889/#890): flags a
# pull request that edits CHANGELOG.md directly, since #899 CHANGELOG.md is
# normally written automatically by .github/workflows/update-changelog.yaml
# (a bot commit triggered when a GitHub Release is published, never through a
# pull request) -- see CONTRIBUTING.md's "Releasing Changes to CHANGELOG.md".
# A hand-edit inside a PR is therefore usually unintended and, per #889's
# original incident, tends to cause a merge-conflict cascade once several
# open PRs all touch the same "### Fixed"-style heading.
#
# This check NEVER fails the build -- it only ever prints a GitHub Actions
# `::warning::`/`::notice::` annotation and always exits 0, per #893's
# explicit design request ("warn-only, not a hard failure, at least
# initially"). The `release` label (an existing repo label: "Component:
# release, channels, image publishing, and provenance") is treated as the
# exemption signal #893 asked for: a PR carrying it prints an informational
# notice instead of a warning, covering the one legitimate manual scenario
# CONTRIBUTING.md itself documents -- scripts/collect-changelog-entries.sh's
# fallback path, "useful for reconstructing history or if the automated
# pipeline is ever disabled". Getting this exemption wrong in either
# direction is low-risk exactly because the check never blocks a merge.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"

REPO_ROOT=""
CHANGED_FILES_FILE=""
LABELS_FILE=""
# GitHub Actions' `join(github.event.pull_request.labels.*.name, ',')` idiom
# produces a comma-separated string -- accept that shape directly from the
# workflow, with a file-based fixture path for bats coverage below.
GUARD_LABELS="${CHANGELOG_GUARD_PR_LABELS:-}"

usage() {
  cat <<'EOF'
Usage: check-changelog-direct-edit.sh [options]

Warn-only guard: never fails, only prints a GitHub Actions annotation when a
pull request edits CHANGELOG.md directly outside the automated release flow.

Options:
  --repo-root DIR            Repository root to inspect. Defaults to the current Git repository root.
  --changed-files-file FILE  Newline-separated list of changed paths, relative to the repository root.
  --labels-file FILE         Newline-separated list of the PR's labels (fixture/testing alternative to
                             CHANGELOG_GUARD_PR_LABELS below).
  -h, --help                 Show this help.

Environment:
  CHANGELOG_GUARD_PR_LABELS  Comma-separated PR label list (e.g. from
                             `join(github.event.pull_request.labels.*.name, ',')`).
  GOVERNANCE_BASE_SHA        Optional base SHA for auto-detecting changed files when no file list is provided.
  GOVERNANCE_HEAD_SHA        Optional head SHA for auto-detecting changed files when no file list is provided.
EOF
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# Prints changed paths one per line, from --changed-files-file if given,
# else from a GOVERNANCE_BASE_SHA/GOVERNANCE_HEAD_SHA diff (mirroring
# check-governance-guards.sh's existing convention so both guards are wired
# into build-push.yml the same way). Never fails: an unusable source simply
# yields no changed files, since a guard that cannot determine its input is
# not grounds to warn OR to break the build here.
collect_changed_files() {
  local path

  if [[ -n "$CHANGED_FILES_FILE" ]]; then
    if [[ ! -f "$CHANGED_FILES_FILE" ]]; then
      printf 'check-changelog-direct-edit: changed files list not found: %s\n' "$CHANGED_FILES_FILE" >&2
      return 0
    fi
    while IFS= read -r path || [[ -n "$path" ]]; do
      path="$(trim "$path")"
      [[ -n "$path" ]] || continue
      printf '%s\n' "$path"
    done < "$CHANGED_FILES_FILE"
    return 0
  fi

  if [[ -n "${GOVERNANCE_BASE_SHA:-}" && -n "${GOVERNANCE_HEAD_SHA:-}" ]]; then
    git -C "$ROOT_DIR" diff --name-only --diff-filter=ACMRTUXB "$GOVERNANCE_BASE_SHA" "$GOVERNANCE_HEAD_SHA" 2>/dev/null
    return 0
  fi

  printf 'check-changelog-direct-edit: no changed-files source available (--changed-files-file or GOVERNANCE_BASE_SHA/GOVERNANCE_HEAD_SHA); skipping\n' >&2
  return 0
}

# True (exit 0) if CHANGELOG.md (repo root only -- not some other path that
# merely ends in that name) is among the changed files.
changelog_directly_edited() {
  local path

  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ "$path" == "CHANGELOG.md" ]] && return 0
  done < <(collect_changed_files)

  return 1
}

# True (exit 0) if the PR carries the exemption label, read from
# --labels-file if given (newline-separated, for fixture testing) or else
# from the comma-separated CHANGELOG_GUARD_PR_LABELS/GUARD_LABELS value.
pr_has_release_label() {
  local label

  if [[ -n "$LABELS_FILE" ]]; then
    if [[ ! -f "$LABELS_FILE" ]]; then
      printf 'check-changelog-direct-edit: labels file not found: %s\n' "$LABELS_FILE" >&2
      return 1
    fi
    while IFS= read -r label || [[ -n "$label" ]]; do
      label="$(trim "$label")"
      [[ "$label" == "release" ]] && return 0
    done < "$LABELS_FILE"
    return 1
  fi

  IFS=',' read -ra _labels <<<"$GUARD_LABELS"
  for label in "${_labels[@]:-}"; do
    [[ "$(trim "$label")" == "release" ]] && return 0
  done
  return 1
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo-root)
        shift
        [[ $# -gt 0 && "$1" != --* ]] || { printf 'check-changelog-direct-edit: --repo-root requires a value\n' >&2; exit 0; }
        REPO_ROOT="$1"
        ;;
      --changed-files-file)
        shift
        [[ $# -gt 0 && "$1" != --* ]] || { printf 'check-changelog-direct-edit: --changed-files-file requires a value\n' >&2; exit 0; }
        CHANGED_FILES_FILE="$1"
        ;;
      --labels-file)
        shift
        [[ $# -gt 0 && "$1" != --* ]] || { printf 'check-changelog-direct-edit: --labels-file requires a value\n' >&2; exit 0; }
        LABELS_FILE="$1"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf 'check-changelog-direct-edit: unknown argument: %s\n' "$1" >&2
        exit 0
        ;;
    esac
    shift
  done

  if [[ -n "$REPO_ROOT" ]]; then
    ROOT_DIR="$REPO_ROOT"
  fi

  if ! changelog_directly_edited; then
    exit 0
  fi

  if pr_has_release_label; then
    echo "::notice::This PR edits CHANGELOG.md and carries the 'release' label, so this looks like an expected manual release-notes edit (e.g. the scripts/collect-changelog-entries.sh fallback path). No action needed."
  else
    echo "::warning::This PR edits CHANGELOG.md directly. Since #899, CHANGELOG.md is normally written automatically by .github/workflows/update-changelog.yaml when a GitHub Release is published -- see CONTRIBUTING.md's 'Releasing Changes to CHANGELOG.md'. A direct edit in a regular PR is usually unintended and risks a merge-conflict cascade with other open PRs (issue #889). This is a warn-only check (issue #893) and does not block merge; if this edit is deliberate, consider adding the 'release' label to silence this notice."
  fi

  exit 0
}

main "$@"
