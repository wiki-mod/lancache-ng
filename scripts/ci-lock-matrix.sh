#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
set -euo pipefail

[[ $# -ge 1 && $# -le 2 ]] || { echo "usage: ci-lock-matrix.sh LOCK [index|platform]" >&2; exit 2; }
lock="$1"; mode="${2:-index}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/ci-artifact-identity.sh"
ci_ai_validate_stack_lock "$lock"

case "$mode" in
    index)
        jq -c '{
          include: [
            (.runtime | to_entries[] | {scope:"runtime", service:.key, image:.value.image, digest:.value.digest}),
            (.tooling | to_entries[] | {scope:"tooling", service:.key, image:.value.image, digest:.value.digest})
          ]
        }' "$lock"
        ;;
    platform)
        jq -c '{
          include: [
            (.runtime | to_entries[] as $svc | $svc.value.platforms | to_entries[] |
              {
                scope:"runtime",
                service:$svc.key,
                image:$svc.value.image,
                platform:.key,
                arch:(if .key == "linux/arm64" then "arm64" else "amd64" end),
                digest:.value,
                runner:(if .key == "linux/arm64" then "ubuntu-24.04-arm" else ["self-hosted","linux","lancache","lancache-heavy"] end)
              }),
            (.tooling | to_entries[] as $svc | $svc.value.platforms | to_entries[] |
              {
                scope:"tooling",
                service:$svc.key,
                image:$svc.value.image,
                platform:.key,
                arch:(if .key == "linux/arm64" then "arm64" else "amd64" end),
                digest:.value,
                runner:(if .key == "linux/arm64" then "ubuntu-24.04-arm" else ["self-hosted","linux","lancache","lancache-heavy"] end)
              })
          ]
        }' "$lock"
        ;;
    *) echo "ci-lock-matrix: invalid mode $mode" >&2; exit 2 ;;
esac
