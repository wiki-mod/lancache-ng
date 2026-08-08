#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Standing guard for a real, previously-undetected drift class: this repo's
# .github/dependabot.yml groups every service Dockerfile listed under its
# "docker" package-ecosystem block into ONE cross-service PR, on the
# explicit stated assumption that every one of those Dockerfiles pins the
# identical final-stage base image (see that file's own Docker-block
# comment). That assumption was true when the comment was first written,
# then went stale for real when one Dockerfile's base image changed without
# anyone noticing the comment no longer matched reality -- caught only by a
# human/agent manually re-reading the comment against the real Dockerfiles
# during an unrelated audit, not by any CI check (recorded as a reasoned,
# scoped exception in docs/release-validation-plan.md's Coverage Assessment
# for the general "any comment's factual claim can go stale" class, since
# that general class resists cheap mechanical detection -- but THIS specific
# recurring claim, about a bounded, named set of Dockerfiles' final base
# image, is concrete and mechanically checkable, so it gets a real guard
# rather than relying on the general exception alone).
#
# What this checks: extracts the `directories:` list from
# .github/dependabot.yml's docker-ecosystem block(s), reads each directory's
# own Dockerfile, takes the LAST `FROM` line in each (the final/runtime
# stage -- a multi-stage Dockerfile's earlier build-stage FROM lines, e.g.
# `FROM ${BUILD_TOOLS_IMAGE} AS builder`, are not the shipped base image and
# are deliberately not compared), and fails if any two directories' final
# base images differ. This does not re-derive dependabot.yml's own grouping
# decision -- it only proves the premise that decision depends on still
# holds.
#
# Accepts an optional repo_root argument (defaults to this script's own
# repo) so a bats test can point it at a throwaway fixture tree instead of
# mutating or depending on the real repository.
set -euo pipefail

if [ "$#" -gt 0 ]; then
    repo_root=$(cd "$1" && pwd)
else
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    repo_root=$(cd "$script_dir/.." && pwd)
fi
cd "$repo_root"

dependabot_file=".github/dependabot.yml"
if [ ! -f "$dependabot_file" ]; then
    printf '::error::check-dependabot-docker-base-consistency: %s not found\n' "$dependabot_file" >&2
    exit 1
fi

# Extract the docker-ecosystem block's `directories:` list. This is a
# deliberately narrow, line-based parse (not a real YAML parser -- this
# project's own convention for its lightweight guard scripts, matching
# scripts/check-short-sha-truncation.sh's identical choice) rather than
# a full YAML parse: it looks for the line `package-ecosystem: docker`,
# then collects every subsequent `      - /path` entry until the next
# top-level `- package-ecosystem:` block or end of file.
mapfile -t directories < <(awk '
  /^  - package-ecosystem: docker/ { in_docker=1; next }
  /^  - package-ecosystem:/ && !/docker/ { in_docker=0 }
  in_docker && /^      - \// { sub(/^      - /, ""); print }
' "$dependabot_file")

if [ "${#directories[@]}" -eq 0 ]; then
    printf '::error::check-dependabot-docker-base-consistency: found no docker-ecosystem directories in %s -- did its structure change shape?\n' "$dependabot_file" >&2
    exit 1
fi

declare -A base_images=()
missing_dockerfiles=()
for dir in "${directories[@]}"; do
    dockerfile="${dir#/}/Dockerfile"
    if [ ! -f "$dockerfile" ]; then
        missing_dockerfiles+=("$dockerfile")
        continue
    fi
    # Last FROM line = final/runtime stage. A multi-stage Dockerfile's
    # earlier builder-stage FROM lines (e.g. FROM ${BUILD_TOOLS_IMAGE} AS
    # builder) are not the shipped base image and are deliberately excluded
    # by only taking the last match (tail -n1), not the first.
    last_from=$(grep -E '^FROM ' "$dockerfile" | tail -n1)
    base_images["$dockerfile"]="$last_from"
done

if [ "${#missing_dockerfiles[@]}" -gt 0 ]; then
    printf '::error::check-dependabot-docker-base-consistency: no Dockerfile found for these dependabot.yml docker directories:\n' >&2
    printf '  %s\n' "${missing_dockerfiles[@]}" >&2
    exit 1
fi

# Collect the distinct set of final-stage FROM lines seen. More than one
# distinct value means dependabot.yml's single cross-service grouping
# assumption (and any comment asserting a shared base image) no longer
# holds for the real Dockerfiles it lists.
distinct_images=$(printf '%s\n' "${base_images[@]}" | sort -u)
distinct_count=$(printf '%s\n' "$distinct_images" | grep -c .)

if [ "$distinct_count" -gt 1 ]; then
    echo "::error::check-dependabot-docker-base-consistency: .github/dependabot.yml's docker-ecosystem block groups these directories into one PR on the assumption they share a final base image, but they do not:" >&2
    for dockerfile in "${!base_images[@]}"; do
        printf '  %s: %s\n' "$dockerfile" "${base_images[$dockerfile]}" >&2
    done
    echo "" >&2
    echo "Either update the stale base-image claim in dependabot.yml's own comment to match reality, or split the diverged Dockerfile(s) into their own dependabot.yml block/group so the grouped PR's premise holds again." >&2
    exit 1
fi

echo "check-dependabot-docker-base-consistency: OK (${#base_images[@]} Dockerfiles share one final base image)."
