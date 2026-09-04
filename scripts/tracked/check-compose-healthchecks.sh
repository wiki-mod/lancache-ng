#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
target_root="${1:-$repo_root}"
cd "$target_root"
shopt -s nullglob
compose_files=(deploy/*/docker-compose.yml)

if [ "${#compose_files[@]}" -eq 0 ]; then
    echo "No deploy/*/docker-compose.yml files found; refusing to run a vacuous check." >&2
    exit 1
fi


declare -A EXCLUDED_SERVICES=(
    ["deploy/prod/docker-compose.yml:dhcp-probe"]=1
    ["deploy/quickstart/docker-compose.yml:dhcp-probe"]=1
    ["deploy/prod/docker-compose.yml:syslog-logs-permissions"]=1
    ["deploy/quickstart/docker-compose.yml:syslog-logs-permissions"]=1
    ["deploy/prod/docker-compose.yml:retention"]=1
    ["deploy/quickstart/docker-compose.yml:retention"]=1
    ["deploy/full-setup/docker-compose.yml:retention"]=1
    ["deploy/prod/docker-compose.yml:cachehamster"]=1
    ["deploy/quickstart/docker-compose.yml:cachehamster"]=1
)

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    NC=''
fi

violations=0
checked=0


check_file() {
    local file="$1"
    local in_services=0 current_service="" current_has_hc=0
    local line lineno=0

  
    finish_service() {
        [[ -n "$current_service" ]] || return 0
        checked=$((checked + 1))
        if [[ "$current_has_hc" -eq 0 ]]; then
            if [[ -n "${EXCLUDED_SERVICES["${file}:${current_service}"]:-}" ]]; then
                return 0
            fi
            fail_service "$file" "$current_service"
        fi
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))

        if [[ "$in_services" -eq 0 ]]; then
    
            if [[ "$line" == "services:" ]]; then
                in_services=1
            fi
            continue
        fi

        if [[ "$line" =~ ^[A-Za-z] ]]; then
            finish_service
            in_services=0
            continue
        fi

        if [[ "$line" =~ ^\ \ [A-Za-z0-9_-]+:$ ]]; then
            finish_service
            current_service="${line#  }"
            current_service="${current_service%:}"
            current_has_hc=0
            continue
        fi


        if [[ -n "$current_service" && "$line" == "    healthcheck:" ]]; then
            current_has_hc=1
        fi
    done < "$file"

    if [[ "$in_services" -eq 1 ]]; then
        finish_service
    fi
}

fail_service() {
    local file="$1" service="$2"
    printf "%b[COMPOSE HEALTHCHECKS]%b %s: service '%s' has no healthcheck: block.\n" "$RED" "$NC" "$file" "$service" >&2
    violations=$((violations + 1))
}

for f in "${compose_files[@]}"; do
    [[ -f "$f" ]] || continue
    check_file "$f"
done

if [[ "$checked" -eq 0 ]]; then
    echo "No services found across ${compose_files[*]}; refusing to run a vacuous check." >&2
    exit 1
fi

if [[ "$violations" -gt 0 ]]; then
    printf "%b✗ %d service(s) missing a healthcheck: block.%b Every service in deploy/*/docker-compose.yml must define a real, specific healthcheck (see docs/architecture-ng.md's health-checks list for the established per-service patterns), or be added to this script's own documented EXCLUDED_SERVICES with a concrete reason; see issue #1169.\n" "$RED" "$violations" "$NC" >&2
    exit 1
fi

printf "%b✓ All %d checked service(s) across %s define a healthcheck (or are documented exclusions).%b\n" "$GREEN" "$checked" "${compose_files[*]}" "$NC"
exit 0
