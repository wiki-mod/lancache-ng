#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: CI guard comparing netdata's actual pinned curl version against a
# known-fixed threshold.
# Why: netdata's statically-linked curl has no distro package for Trivy's
# os-pkg scanner to see -- a clean scan proves blindness, not safety.
# From: Issue #1304 | PR #1352
set -euo pipefail

# What: CURL_SAFE_THRESHOLD is confirmed real via curl.se's own CVE pages.
# Why: Debian's tracker misreports backports builds as still affected.
# From: Issue #1304 | PR #1662
CURL_SAFE_THRESHOLD="8.21.0"
TRACKED_CVES=(CVE-2026-12064 CVE-2026-8286 CVE-2026-8927 CVE-2026-8932 CVE-2026-9079 CVE-2026-9080 CVE-2026-9545)
TRACKED_CVES_SOURCE_DATE="2026-08-14"

# What: a time-boxed grace period -- a still-affected pin warns before this
# date, hard-fails on or after it.
# Why: an unconditional hard-fail would turn validate-compose permanently
# red for a risk this repo doesn't control the fix for.
# From: Issue #1304 | PR #1551
ACCEPTED_UNTIL="2030-12-31"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
dockerfile="${1:-${repo_root}/services/netdata/Dockerfile}"

# What: parses `ARG NETDATA_VERSION=vX.Y.Z` out of a Dockerfile, tolerating
# zero matches so the caller gets a clean error instead of an errexit abort.
# Why: kept as its own function so tests can feed it a fixture Dockerfile.
# From: Issue #1304 | PR #1352
extract_netdata_version() {
  local dockerfile_path="$1"
  local version
  local version_line
  # What: captures grep's output (|| true), then reads it via a here-string
  # instead of piping grep straight into head.
  # Why: || true avoids errexit on a legit zero-match; the capture avoids
  # SIGPIPE if a second match line ever appears.
  # From: Issue #1377 | PR #1414
  version_line="$(grep -E '^ARG NETDATA_VERSION=' "${dockerfile_path}" || true)"
  version="$(head -1 <<<"${version_line}" | cut -d= -f2 | tr -d '[:space:]')"
  if [ -z "${version}" ]; then
    echo "::error::Could not find 'ARG NETDATA_VERSION=' in ${dockerfile_path}" >&2
    return 1
  fi
  printf '%s\n' "${version}"
}

# What: parses `CURL_VERSION="curl-X_Y_Z"` out of netdata's own
# packaging/makeself/bundled-packages.version content, returning "X.Y.Z".
# Why: netdata's build recipe uses this git-tag string, not the same format
# its --version banner reports, so this is the reliable source to parse.
# From: Issue #1304 | PR #1352
extract_curl_version_tag() {
  local content="$1"
  local raw
  local curl_version_line
  # What: captures grep's output (|| true), then reads it via a here-string
  # instead of piping grep straight into head.
  # Why: || true avoids errexit on a legit zero-match; the capture avoids
  # SIGPIPE if a second match line ever appears.
  # From: Issue #1377 | PR #1414
  curl_version_line="$(grep -E '^CURL_VERSION=' <<<"${content}" || true)"
  raw="$(head -1 <<<"${curl_version_line}" | sed -E 's/^CURL_VERSION="?curl-([0-9_]+)"?.*/\1/' || true)"
  if [ -z "${raw}" ]; then
    echo "::error::Could not find a parseable CURL_VERSION=\"curl-X_Y_Z\" line in the given bundled-packages.version content" >&2
    return 1
  fi
  printf '%s\n' "${raw}" | tr '_' '.'
}

# What: true (exit 0) if $1 >= $2, treating both as dotted numeric versions.
# Why: sort -V already handles differing segment counts the way release
# comparison expects (e.g. "8.21" vs "8.21.0").
# From: Issue #1304 | PR #1352
version_ge() {
  local v1="$1" v2="$2"
  [ "$(printf '%s\n%s\n' "${v1}" "${v2}" | sort -V | tail -1)" = "${v1}" ]
}

# What: fetches netdata's bundled-packages.version for a given tag from its
# upstream repo, retrying transient failures with backoff.
# Why: a real 404 (missing tag/moved path) is a genuine failure and is not
# retried; only network/timeout/5xx responses get up to 2 more attempts.
# From: Issue #1304 | PR #1352
fetch_bundled_packages_version() {
  local netdata_version="$1"
  local url="https://raw.githubusercontent.com/netdata/netdata/${netdata_version}/packaging/makeself/bundled-packages.version"
  local attempt
  local status
  for attempt in 1 2 3; do
    # What: explicit if/then status=0/else status=$?/fi, not a bare
    # `local status=$?` after an else-less if.
    # Why: POSIX leaves $? at 0 after an if's false branch, silently
    # misreading every curl failure -- including a real 404 -- as success.
    # From: Issue #1449 | PR #1539
    if curl -fsSL "${url}"; then
      status=0
    else
      status=$?
    fi
    if [ "${status}" -eq 0 ]; then
      return 0
    fi
    if [ "${status}" -eq 22 ]; then
      echo "::error::${url} returned a real HTTP error (tag missing or path moved upstream) -- not retrying" >&2
      return 1
    fi
    echo "::warning::fetch attempt ${attempt}/3 for ${url} failed (curl exit ${status}), retrying..." >&2
    sleep $((attempt * 2))
  done
  echo "::error::Failed to fetch ${url} after 3 attempts" >&2
  return 1
}

main() {
  local netdata_version bundled_packages_content curl_version

  netdata_version="$(extract_netdata_version "${dockerfile}")"
  echo "Checking netdata ${netdata_version}'s pinned curl version against issue #1304's tracked CVE set (fixed at curl ${CURL_SAFE_THRESHOLD}, per curl.se as of ${TRACKED_CVES_SOURCE_DATE})..."

  # What: BUNDLED_PACKAGES_CONTENT_FILE, when set, substitutes a local
  # fixture for the real network fetch.
  # Why: keeps bats coverage offline and deterministic, independent of
  # GitHub's raw content host being reachable.
  # From: Issue #1304 | PR #1352
  if [ -n "${BUNDLED_PACKAGES_CONTENT_FILE:-}" ]; then
    bundled_packages_content="$(cat "${BUNDLED_PACKAGES_CONTENT_FILE}")"
  else
    bundled_packages_content="$(fetch_bundled_packages_version "${netdata_version}")"
  fi

  curl_version="$(extract_curl_version_tag "${bundled_packages_content}")"
  echo "netdata ${netdata_version} vendors curl ${curl_version} (from its own packaging/makeself/bundled-packages.version)."

  if version_ge "${curl_version}" "${CURL_SAFE_THRESHOLD}"; then
    echo "OK: ${curl_version} >= ${CURL_SAFE_THRESHOLD} -- not in the affected range for the tracked CVE set as of ${TRACKED_CVES_SOURCE_DATE}."
    return 0
  fi

  # What: NETDATA_CURL_PIN_TODAY, when set, substitutes for the real date.
  # Why: lets bats exercise both sides of the ACCEPTED_UNTIL boundary
  # deterministically instead of depending on the real wall-clock date.
  # From: Issue #1304 | PR #1352
  local today="${NETDATA_CURL_PIN_TODAY:-$(date -u +%F)}"
  local cve
  local finding_lines=()
  finding_lines+=("netdata ${netdata_version} vendors curl ${curl_version}, which is BELOW the ${CURL_SAFE_THRESHOLD} fixed-version threshold for issue #1304's tracked CVE set:")
  for cve in "${TRACKED_CVES[@]}"; do
    finding_lines+=("  - ${cve} (see https://curl.se/docs/${cve}.html)")
  done

  if [[ "${today}" > "${ACCEPTED_UNTIL}" ]]; then
    echo "::error::${finding_lines[0]}" >&2
    local line
    for line in "${finding_lines[@]:1}"; do
      echo "::error::${line}" >&2
    done
    echo "::error::This grace period (ACCEPTED_UNTIL=${ACCEPTED_UNTIL}, per issue #1304/PR #1352) has PASSED -- today is ${today}. This is now a hard failure, not a warning: re-review issue #1304's accept-and-VEX decision (its own dated checkpoint, currently ${ACCEPTED_UNTIL}), and either bump ACCEPTED_UNTIL after that re-review, update CURL_SAFE_THRESHOLD if a newer netdata release vendors a fixed curl, or resolve the underlying risk another way. Do not silently push this date out without an actual re-review." >&2
    return 1
  fi

  echo "::warning::${finding_lines[0]}"
  local line
  for line in "${finding_lines[@]:1}"; do
    echo "::warning::${line}"
  done
  echo "::warning::This is a known, deliberately time-boxed acceptance (maintainer decision (c) on PR #1352, issue #1304) -- non-blocking until ACCEPTED_UNTIL=${ACCEPTED_UNTIL} (today: ${today}), after which it becomes a hard failure. The statically-linked curl inside services/netdata's image is very likely still affected by these CVEs, invisible to Trivy."
  return 0
}

# What: allows this script to be sourced by tests (to reach the functions
# above without running main()) as well as executed directly in CI.
# Why: lets bats reach the functions directly without triggering the real
# network fetch main() would otherwise perform.
# From: Issue #1304 | PR #1352
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
