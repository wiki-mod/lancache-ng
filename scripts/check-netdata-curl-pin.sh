#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
#
# CI guard for issue #1304's netdata-specific finding, and the maintainer-
# approved tracking mechanism promised in PR #1352 (option (c): merge the
# Alpine/musl migration for its real, non-curl benefits, but do not let the
# now-invisible curl risk silently fall off radar).
#
# services/netdata/Dockerfile installs netdata's official static musl
# release build. That build statically links its OWN vendored curl, built
# from source at a pinned git tag (confirmed via `ldd` on the built image:
# the netdata binary is "not a valid dynamic program" -- no distro package
# for Trivy's os-pkg scanner to see). That means a clean Trivy scan of this
# image proves nothing about whether the vendored curl is actually patched;
# it only proves Trivy has no visibility into it at all. This script closes
# that visibility gap by checking the ACTUAL pinned version directly,
# instead of trusting scanner silence.
#
# Method: read NETDATA_VERSION from services/netdata/Dockerfile, fetch that
# exact tag's own packaging/makeself/bundled-packages.version from netdata's
# upstream repository (the real source of truth for what curl version this
# project's image actually vendors -- not assumed from a version banner,
# which PR #1352's own evaluation found to be a `-DEV` string that doesn't
# obviously map to a released version), extract CURL_VERSION, and compare it
# against CURL_SAFE_THRESHOLD below.
#
# CURL_SAFE_THRESHOLD provenance (curl's own vulnerability data,
# https://curl.se/docs/vuln.json, checked 2026-10-22): every one of the 7
# CVE IDs issue #1304 tracks (CVE-2026-12064, CVE-2026-8286, CVE-2026-8927,
# CVE-2026-8932, CVE-2026-9079, CVE-2026-9080, CVE-2026-9545) affects curl
# 8.17.0 up to (excluding) 8.20.1 and is fixed in 8.20.1 and in 8.21.0 --
# i.e. 8.20.1 is the lowest fixed version for every curl release this
# netdata line can vendor. This is a snapshot of that one specific,
# already-known CVE set, not a live feed: if curl discloses a NEW CVE with a
# later fixed version, this script's hardcoded threshold goes stale
# silently, since it has no way to know about a CVE that doesn't exist in
# this comment yet. Whoever bumps NETDATA_VERSION in
# services/netdata/Dockerfile must re-check curl's own vulnerability list
# (https://curl.se/docs/vulnerabilities.html) at that time and bump
# CURL_SAFE_THRESHOLD (and this comment's date) if a newer curl release has
# fixed something new since 2026-10-22.
#
# Standing exception (AG-KD-003, tool-specific, no deadline): the affected
# state is real today. Checked 2026-10-22: netdata v2.12.1 (latest release),
# v2.12.0, v2.11.1 and netdata master vendor curl-8_20_0, this project's pin
# v2.10.4 vendors curl-8_17_0; no netdata release vendors a fixed curl yet
# (latest curl release: 8.23.0). The fix lives in netdata's own upstream
# build recipe, not in this project's Dockerfile, so a hard failure here
# would only turn this project's whole `validate-compose` gate red without
# anything this repository can change (maintainer decision (c) on PR #1352:
# "merge for the benefits, track the risk"). While the pinned curl is below
# CURL_SAFE_THRESHOLD this check therefore reports a `::warning::` on every
# run, non-blocking and without any date. The exception ends by itself: as
# soon as a netdata release vendoring curl >= CURL_SAFE_THRESHOLD exists,
# NETDATA_VERSION is bumped to it and this check prints OK.
set -euo pipefail

CURL_SAFE_THRESHOLD="8.20.1"
TRACKED_CVES=(CVE-2026-12064 CVE-2026-8286 CVE-2026-8927 CVE-2026-8932 CVE-2026-9079 CVE-2026-9080 CVE-2026-9545)
TRACKED_CVES_SOURCE_DATE="2026-10-22"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
dockerfile="${1:-${repo_root}/services/netdata/Dockerfile}"

# Parses `ARG NETDATA_VERSION=vX.Y.Z` out of services/netdata/Dockerfile.
# Kept as its own function so tests can feed it a fixture Dockerfile
# snippet instead of the real one.
extract_netdata_version() {
  local dockerfile_path="$1"
  local version
  # `|| true` is intentional and required here (Rule-Ref: AG-VAL-024): under
  # `set -e -o pipefail`, a `grep` that legitimately finds zero matches (the
  # exact "malformed/missing input" case this function exists to detect and
  # report) would otherwise abort the whole script via errexit BEFORE the
  # `-z` check below ever runs -- the identical dead-fail-closed-branch
  # pattern PR #937 hit. Neutralizing the pipeline's own exit code here is
  # what lets the explicit check and friendly error message actually execute.
  version="$(grep -E '^ARG NETDATA_VERSION=' "${dockerfile_path}" | head -1 | cut -d= -f2 | tr -d '[:space:]' || true)"
  if [ -z "${version}" ]; then
    echo "::error::Could not find 'ARG NETDATA_VERSION=' in ${dockerfile_path}" >&2
    return 1
  fi
  printf '%s\n' "${version}"
}

# Parses `CURL_VERSION="curl-X_Y_Z"` out of netdata's own
# packaging/makeself/bundled-packages.version content and returns "X.Y.Z".
# Netdata's own build recipe uses underscore-separated git-tag-style
# version strings (e.g. "curl-8_17_0"); this is NOT the same string curl's
# own `--version` banner reports (PR #1352 found that banner shows
# "8.17.0-DEV", not directly parseable as a release/tag comparison target),
# which is exactly why this script reads the upstream build recipe instead
# of trusting a version banner.
extract_curl_version_tag() {
  local content="$1"
  local raw
  # Same `|| true` reasoning as extract_netdata_version above: a `grep`
  # finding zero matches is the "unparseable content" case this function
  # must be able to detect and report, not something errexit should be
  # allowed to short-circuit past silently.
  raw="$(printf '%s\n' "${content}" | grep -E '^CURL_VERSION=' | head -1 | sed -E 's/^CURL_VERSION="?curl-([0-9_]+)"?.*/\1/' || true)"
  if [ -z "${raw}" ]; then
    echo "::error::Could not find a parseable CURL_VERSION=\"curl-X_Y_Z\" line in the given bundled-packages.version content" >&2
    return 1
  fi
  printf '%s\n' "${raw}" | tr '_' '.'
}

# True (exit 0) if $1 >= $2, treating both as dotted numeric versions.
# `sort -V` (GNU version sort, available in this project's build-tools
# container per AG-VAL-016) already handles differing segment counts
# (e.g. "8.21" vs "8.21.0") the way release-version comparison expects.
version_ge() {
  local v1="$1" v2="$2"
  [ "$(printf '%s\n%s\n' "${v1}" "${v2}" | sort -V | tail -1)" = "${v1}" ]
}

# Fetches netdata's own bundled-packages.version for the given tag from its
# real upstream repository. Retried a few times with backoff (Rule-Ref:
# AG-CI-013): this is a single small static-file GET, not a container
# registry push/pull, so it does not reuse scripts/lib/ghcr-retry.sh's
# registry-specific auth/retry semantics -- a plain small backoff loop is
# the right-sized tool for this narrower operation class. A genuine 404
# (the tag doesn't exist upstream, or netdata restructured this file's
# path) is NOT retried -- that is a real failure this script must surface,
# not a transient blip to wait out.
fetch_bundled_packages_version() {
  local netdata_version="$1"
  local url="https://raw.githubusercontent.com/netdata/netdata/${netdata_version}/packaging/makeself/bundled-packages.version"
  local attempt
  for attempt in 1 2 3; do
    if curl -fsSL "${url}"; then
      return 0
    fi
    local status=$?
    # curl's exit 22 (--fail HTTP error, e.g. a real 404) is not retried;
    # anything else (network/timeout/5xx) gets up to 2 more attempts.
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

  # Test hook: if BUNDLED_PACKAGES_CONTENT_FILE is set (bats fixtures use
  # this), read from that local file instead of hitting the real network --
  # keeps the version-comparison logic's own test coverage deterministic
  # and offline, while main() itself still exercises the full real path
  # when this variable is unset (the actual CI invocation).
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

  local cve
  local finding_lines=()
  finding_lines+=("netdata ${netdata_version} vendors curl ${curl_version}, which is BELOW the ${CURL_SAFE_THRESHOLD} fixed-version threshold for issue #1304's tracked CVE set:")
  for cve in "${TRACKED_CVES[@]}"; do
    finding_lines+=("  - ${cve} (see https://curl.se/docs/${cve}.html)")
  done

  echo "::warning::${finding_lines[0]}"
  local line
  for line in "${finding_lines[@]:1}"; do
    echo "::warning::${line}"
  done
  echo "::warning::This is a known, standing exception (maintainer decision (c) on PR #1352, issue #1304; AG-KD-003) without a date: it ends when a netdata release vendoring curl >= ${CURL_SAFE_THRESHOLD} exists and NETDATA_VERSION is bumped to it. The statically-linked curl inside services/netdata's image is very likely still affected by these CVEs, invisible to Trivy."
  return 0
}

# Allow this script to be sourced by tests (bats sources it to reach the
# functions above without running main()) as well as executed directly in
# CI, matching this project's existing script/test pattern.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
