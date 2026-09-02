#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: merges utilities' SBOM filtered by COPY'd packages.
# Why: full SBOM over-reports un-COPY'd packages as shipped.
# From: Issue #1613 | PR #1703
set -euo pipefail

usage() {
  echo "usage: $0 <service> <service-cdx-json> <utilities-cdx-json>" >&2
}

service="${1:-}"
service_sbom="${2:-}"
utilities_sbom="${3:-}"

if [ -z "$service" ] || [ -z "$service_sbom" ] || [ -z "$utilities_sbom" ]; then
  usage
  exit 1
fi

command -v jq >/dev/null 2>&1 || {
  echo "error: jq is required to merge the utilities SBOM." >&2
  exit 1
}
[ -s "$service_sbom" ] || { echo "error: missing or empty $service_sbom." >&2; exit 1; }
[ -s "$utilities_sbom" ] || { echo "error: missing or empty $utilities_sbom." >&2; exit 1; }

# What: apk package names curl's shared libraries belong to.
# Why: verified live via `apk info --who-owns` per package.
# From: Issue #1781 | PR #1783
curl_packages="curl libcurl zlib c-ares nghttp2-libs libidn2 libpsl libssl3 libcrypto3 zstd-libs brotli-libs libunistring"

# apk package names each service's Dockerfile COPY's from utilities-tools.
# dhcp-proxy is deliberately excluded from $curl_packages: confirmed (grep)
# it never COPYs curl at all, unlike the other six real consumers.
case "$service" in
  proxy | dhcp | dns)
    allowed_packages="findutils gettext-envsubst libintl lsof ripgrep libgcc pcre2 $curl_packages"
    ;;
  dhcp-proxy)
    allowed_packages="findutils gettext-envsubst libintl lsof ripgrep libgcc pcre2"
    ;;
  ntp)
    allowed_packages="gettext-envsubst libintl $curl_packages"
    ;;
  watchdog)
    allowed_packages="findutils lsof ripgrep libgcc pcre2 $curl_packages"
    ;;
  ui)
    allowed_packages="lsof ripgrep libgcc pcre2 $curl_packages"
    ;;
  *)
    echo "error: no utilities-package allowlist defined for service '$service'." >&2
    exit 1
    ;;
esac

allowed_json="$(printf '%s\n' $allowed_packages | jq -R . | jq -s .)"

jq -s --argjson allowed "$allowed_json" '
  .[0] as $svc | .[1] as $utilities |
  $svc | .components = (
    (
      ($svc.components // [])
      + (($utilities.components // []) | map(select(.name as $n | $allowed | index($n) != null)))
    )
    | unique_by(.["bom-ref"] // .purl // (.name + "@" + (.version // "")))
  )
' "$service_sbom" "$utilities_sbom"
