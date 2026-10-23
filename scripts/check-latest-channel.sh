#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
#
# Checks that a published channel (default `latest`) is installable: every
# first-party image in release/stack-images.yml (runtime, tooling and
# metadata) must resolve with all of its declared platforms through
# scripts/require-image-platforms.sh, then the full-setup stack must start
# from that channel and report healthy. Prints every finding and exits
# non-zero when any check fails. Used by .github/workflows/latest-health.yml.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
channel="${1:-latest}"
manifest="release/stack-images.yml"
registry_prefix="ghcr.io/wiki-mod/lancache-ng"
failures=0

# Prints "name platform,platform" for every image in the given manifest section.
section_images() {
  awk -v section="$1" '
    $0 == section ":" { in_section=1; next }
    in_section && /^[[:alnum:]_-]+:/ { in_section=0 }
    in_section && /^  - name: / { if (name != "") print name, plat; name=$3; plat=""; in_plat=0; next }
    in_section && /^    platforms:/ { in_plat=1; next }
    in_section && in_plat && /^      - / { plat = plat (plat == "" ? "" : ",") $2; next }
    in_section && /^    [^ ]/ { in_plat=0 }
    END { if (name != "") print name, plat }
  ' "$manifest"
}

echo "== Images on channel '$channel'"
for section in runtime tooling metadata; do
  while read -r name platforms; do
    [ -n "$name" ] || continue
    if [ -z "$platforms" ]; then
      echo "::error::$manifest declares no platforms for $name"
      failures=$((failures + 1))
      continue
    fi
    if ! bash scripts/require-image-platforms.sh "$registry_prefix/$name:$channel" "$platforms"; then
      failures=$((failures + 1))
    fi
  done < <(section_images "$section")
done

echo "== Starting the full-setup stack from '$channel'"
project="latest-health"
compose=(docker compose -p "$project" -f deploy/full-setup/docker-compose.yml)
services=(proxy standard-passthrough-shim dns-standard dns-ssl nats docker-socket-proxy watchdog ui)
healthy=0
# Polls instead of `up --wait`: the proxy reports unhealthy while it still
# generates its SSL certificates on first start, which `--wait` treats as final.
if LANCACHE_IMAGE_TAG="$channel" "${compose[@]}" up -d "${services[@]}"; then
  for _ in $(seq 1 60); do
    states="$("${compose[@]}" ps -a --format '{{.Service}} {{.Health}}' "${services[@]}")"
    if [ "$(grep -c " healthy$" <<< "$states")" -eq "${#services[@]}" ]; then healthy=1; break; fi
    sleep 5
  done
fi
if [ "$healthy" -eq 1 ]; then
  "${compose[@]}" ps
else
  echo "::error::the full-setup stack did not become healthy from '$channel'"
  "${compose[@]}" ps -a
  "${compose[@]}" logs --tail 40
  failures=$((failures + 1))
fi
"${compose[@]}" down -v --remove-orphans

if [ "$failures" -ne 0 ]; then
  echo "::error::channel '$channel' is not installable: $failures check(s) failed"
  exit 1
fi
echo "channel '$channel' is installable"
