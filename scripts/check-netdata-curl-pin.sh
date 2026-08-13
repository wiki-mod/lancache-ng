#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
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
# CURL_SAFE_THRESHOLD provenance (verified against curl.se's own per-CVE
# pages, 2026-07-31, PR #1352): every one of the 7 CVE IDs issue #1304
# tracks (CVE-2026-12064, CVE-2026-8286, CVE-2026-8927, CVE-2026-8932,
# CVE-2026-9079, CVE-2026-9080, CVE-2026-9545) states "Not affected
# versions: curl < X and >= 8.21.0" -- i.e. 8.21.0 is the actual fixed
# version for every one of them. This is a snapshot of that one specific,
# already-known CVE set, not a live feed: if curl discloses a NEW CVE after
# 8.21.0 with a later fixed version, this script's hardcoded threshold goes
# stale silently, since it has no way to know about a CVE that doesn't
# exist in this comment yet. Whoever bumps NETDATA_VERSION in
# services/netdata/Dockerfile must re-check curl's own vulnerability list
# (https://curl.se/docs/vulnerabilities.html) at that time and bump
# CURL_SAFE_THRESHOLD (and this comment's date) if a newer curl release has
# fixed something new since 2026-07-31.
#
# ACCEPTED_UNTIL: the known-affected state is real TODAY (netdata v2.10.4
# vendors curl 8.17.0, confirmed below threshold) -- making this check a
# hard, unconditional failure the moment it merges would turn this
# project's whole `validate-compose` gate permanently red for every future
# PR, for a risk this repository does not control the fix for (it lives in
# netdata's own upstream build recipe, not this project's Dockerfile).
# That is not what the maintainer's option (c) decision on PR #1352 asked
# for ("merge for the benefits, track the risk", not "block all CI until
# netdata ships a fix"). So: below the threshold is a `::warning::`, not a
# blocking `::error::`, while today's date is on or before ACCEPTED_UNTIL --
# visible on every run, but non-blocking, mirroring the same time-boxed-
# acceptance shape this project already uses for `.trivyignore.yaml`'s own
# `expired_at` fields and `PR_TITLE_LINT_MODE`'s warn-then-block transition.
# Once ACCEPTED_UNTIL passes, a still-affected pin becomes a hard failure --
# this is a deliberate escalation, not a bug: the point of a checkpoint
# date is that silence past it is no longer acceptable, and whoever re-
# reviews issue #1304's accept-and-VEX decision at its own 2026-08-15
# checkpoint should update this date (and re-verify CURL_SAFE_THRESHOLD)
# together with that review, not treat them as unrelated.
set -euo pipefail

CURL_SAFE_THRESHOLD="8.21.0"
TRACKED_CVES=(CVE-2026-12064 CVE-2026-8286 CVE-2026-8927 CVE-2026-8932 CVE-2026-9079 CVE-2026-9080 CVE-2026-9545)
TRACKED_CVES_SOURCE_DATE="2026-07-31"
ACCEPTED_UNTIL="2026-08-15"

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
  # grep runs to completion into a variable first (the `|| true` above still
  # covers its own zero-match case), then `head -1` reads that captured
  # variable via a here-string instead of a live pipe from grep -- a live
  # `grep ... | head -1` pipe can SIGPIPE grep if the Dockerfile ever grows a
  # second matching ARG line (issue #1377's repo-wide pipefail/SIGPIPE audit).
  local version_line
  version_line="$(grep -E '^ARG NETDATA_VERSION=' "${dockerfile_path}" || true)"
  version="$(head -1 <<<"${version_line}" | cut -d= -f2 | tr -d '[:space:]')"
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
  # Here-string into grep, then grep's own output captured into a variable
  # before `head -1` reads it -- avoids a live pipe an early-exiting consumer
  # could SIGPIPE if the content ever has more than one matching line
  # (issue #1377).
  local curl_version_line
  curl_version_line="$(grep -E '^CURL_VERSION=' <<<"${content}" || true)"
  raw="$(head -1 <<<"${curl_version_line}" | sed -E 's/^CURL_VERSION="?curl-([0-9_]+)"?.*/\1/' || true)"
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
  local status
  for attempt in 1 2 3; do
    # Deliberately `if curl ...; then status=0; else status=$?; fi`, not the
    # more obvious `if curl ...; then return 0; fi` followed by a bare
    # `local status=$?`: per POSIX, an `if` with no `else` clause that takes
    # the false branch reports the WHOLE if-construct's own exit status (0)
    # on the next `$?` read, not curl's real failure code -- confirmed live
    # (`f() { return 22; }; if f; then :; fi; status=$?; echo "$status"`
    # prints 0, not 22). That silently broke the exit-22 (confirmed 404)
    # classification below: every curl failure, including a real 404, would
    # have read status=0 and fallen through to the generic
    # retry-then-give-up path instead. This project's own established
    # pattern for exactly this case (scripts/lib/ghcr-retry.sh's
    # ghcr_retry(), scripts/lib/git-fetch-retry.sh's git_fetch_retry()) uses
    # an explicit else branch instead; reused here per AG-CODE-011.
    if curl -fsSL "${url}"; then
      status=0
    else
      status=$?
    fi
    if [ "${status}" -eq 0 ]; then
      return 0
    fi
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

  # Test hook, same idea as BUNDLED_PACKAGES_CONTENT_FILE above: lets bats
  # exercise both sides of the ACCEPTED_UNTIL boundary deterministically,
  # without depending on (or waiting for) the real wall-clock date.
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
    echo "::error::This grace period (ACCEPTED_UNTIL=${ACCEPTED_UNTIL}, per issue #1304/PR #1352) has PASSED -- today is ${today}. This is now a hard failure, not a warning: re-review issue #1304's accept-and-VEX decision (its own 2026-08-15 checkpoint), and either bump ACCEPTED_UNTIL after that re-review, update CURL_SAFE_THRESHOLD if a newer netdata release vendors a fixed curl, or resolve the underlying risk another way. Do not silently push this date out without an actual re-review." >&2
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

# Allow this script to be sourced by tests (bats sources it to reach the
# functions above without running main()) as well as executed directly in
# CI, matching this project's existing script/test pattern.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
