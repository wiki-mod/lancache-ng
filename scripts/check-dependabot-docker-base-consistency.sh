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
# What this checks: extracts the `directories:` list from EACH of
# .github/dependabot.yml's docker-ecosystem blocks separately (a file can
# have more than one such block -- e.g. the documented remediation this
# script's own failure message suggests, splitting a diverged Dockerfile
# into its own block), reads each directory's own Dockerfile, takes the
# LAST `FROM` line in each (the final/runtime stage -- a multi-stage
# Dockerfile's earlier build-stage FROM lines, e.g. `FROM
# ${BUILD_TOOLS_IMAGE} AS builder`, are not the shipped base image and are
# deliberately not compared), normalizes it down to just the image
# reference (a named final stage, e.g. `FROM alpine:3.24 AS runtime`, must
# compare equal to an unnamed one, `FROM alpine:3.24`, for the same image --
# comparing the raw line text would false-positive on the stage name
# alone), and fails if any two directories WITHIN THE SAME BLOCK have a
# different final base image. Blocks are validated independently: a
# docker-ecosystem block groups its own directories into one PR on the
# assumption THAT block's Dockerfiles share a base image -- it says nothing
# about a different, separate block's directories, so comparing across
# block boundaries would make the documented remediation (splitting a
# diverged directory into its own block) impossible to ever pass. This does
# not re-derive dependabot.yml's own grouping decision -- it only proves the
# premise each existing grouping depends on still holds.
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

# Extract each docker-ecosystem block's `directories:` list, tagged with a
# zero-based block index so blocks are never merged together. This is a
# deliberately narrow, line-based parse (not a real YAML parser -- this
# project's own convention for its lightweight guard scripts, matching
# scripts/check-short-sha-truncation.sh's identical choice): it looks for
# each `package-ecosystem: docker` line, incrementing the block index every
# time one is seen, and collects every subsequent `      - /path` entry
# (tab-separated with its block index) until the next top-level
# `- package-ecosystem:` block or end of file. Output lines are
# `<block_index>\t<directory>`. Both the ecosystem value and each directory
# entry may be a bare scalar or a single/double-quoted YAML string (e.g.
# `package-ecosystem: "docker"`, `- "/services/proxy"`) -- both forms parse
# identically, since YAML itself treats them as equivalent, so the pattern
# below strips a matching leading/trailing quote character (either kind)
# before comparing. The awk program is fed via a quoted heredoc rather than
# this script's original bash single-quoted string, since the regex needs a
# literal `'` character in its own quote-stripping character class, which a
# bash single-quoted string cannot contain at all.
mapfile -t tagged_directories < <(awk -f - "$dependabot_file" <<'AWKPROG'
/^  - package-ecosystem:[[:space:]]*["']?[Dd]ocker["']?[[:space:]]*$/ { in_docker=1; block++; next }
/^  - package-ecosystem:/ && !/[Dd]ocker/ { in_docker=0 }
in_docker && /^      - / {
    path=$0
    sub(/^      - /, "", path)
    gsub(/^["']|["'][[:space:]]*$/, "", path)
    if (path ~ /^\//) print block "\t" path
}
AWKPROG
)

if [ "${#tagged_directories[@]}" -eq 0 ]; then
    printf '::error::check-dependabot-docker-base-consistency: found no docker-ecosystem directories in %s -- did its structure change shape?\n' "$dependabot_file" >&2
    exit 1
fi

# base_image_of["<block>\t<dockerfile>"] = normalized image reference
declare -A base_image_of=()
missing_dockerfiles=()
blocks_seen=()
for entry in "${tagged_directories[@]}"; do
    block="${entry%%$'\t'*}"
    dir="${entry#*$'\t'}"
    dockerfile="${dir#/}/Dockerfile"
    if [ ! -f "$dockerfile" ]; then
        missing_dockerfiles+=("$dockerfile")
        continue
    fi
    # Last FROM line = final/runtime stage. A multi-stage Dockerfile's
    # earlier builder-stage FROM lines (e.g. FROM ${BUILD_TOOLS_IMAGE} AS
    # builder) are not the shipped base image and are deliberately excluded
    # by only taking the last match (tail -n1), not the first. Dockerfile
    # instruction names are case-insensitive (`from`/`FROM`/`From` are all
    # valid) and may carry leading whitespace, so the match is
    # case-insensitive with an optional leading-whitespace/no-space-required
    # form -- a case-sensitive `^FROM ` match silently found nothing for a
    # valid lowercase `from` line, which under `set -o pipefail` aborted
    # this whole script with no diagnostic (grep's own "no match" exit 1
    # propagating through the pipeline) instead of comparing base images.
    # `|| true` here is not hiding that failure (Rule-Ref: AG-VAL-004): the
    # explicit empty-check immediately below turns it into a clear,
    # diagnosed ::error:: instead of pipefail's unexplained abort.
    last_from_line=$(grep -Ei '^[[:space:]]*FROM[[:space:]]' "$dockerfile" | tail -n1 || true)
    if [ -z "$last_from_line" ]; then
        printf '::error::check-dependabot-docker-base-consistency: no FROM instruction found in %s\n' "$dockerfile" >&2
        exit 1
    fi
    # Normalize to just the image reference: drop the leading "FROM "
    # (case-insensitively, per the match above), any "--platform=..." flag,
    # and a trailing " AS <name>" stage alias -- `FROM alpine:3.24 AS
    # runtime`, `from alpine:3.24 AS runtime`, and `FROM alpine:3.24` must
    # all compare equal, since all three ship the identical base image.
    normalized_image=$(sed -E 's/^[[:space:]]*FROM[[:space:]]+(--platform=[^[:space:]]+[[:space:]]+)?//I; s/[[:space:]]+[Aa][Ss][[:space:]]+[^[:space:]]+[[:space:]]*$//' <<< "$last_from_line")
    base_image_of["${block}"$'\t'"${dockerfile}"]="$normalized_image"
    blocks_seen+=("$block")
done

if [ "${#missing_dockerfiles[@]}" -gt 0 ]; then
    printf '::error::check-dependabot-docker-base-consistency: no Dockerfile found for these dependabot.yml docker directories:\n' >&2
    printf '  %s\n' "${missing_dockerfiles[@]}" >&2
    exit 1
fi

# Validate each block independently: collect this block's own set of
# normalized images and fail only if THIS block's Dockerfiles diverge --
# a different block's directories are a separate grouping decision and
# must never be compared against this one.
mapfile -t distinct_blocks < <(printf '%s\n' "${blocks_seen[@]}" | sort -un)
overall_status=0
for block in "${distinct_blocks[@]}"; do
    block_images=()
    for key in "${!base_image_of[@]}"; do
        key_block="${key%%$'\t'*}"
        [ "$key_block" = "$block" ] || continue
        block_images+=("${base_image_of[$key]}")
    done
    distinct_in_block=$(printf '%s\n' "${block_images[@]}" | sort -u | grep -c .)
    if [ "$distinct_in_block" -gt 1 ]; then
        overall_status=1
        echo "::error::check-dependabot-docker-base-consistency: .github/dependabot.yml's docker-ecosystem block #${block} groups these directories into one PR on the assumption they share a final base image, but they do not:" >&2
        for key in "${!base_image_of[@]}"; do
            key_block="${key%%$'\t'*}"
            [ "$key_block" = "$block" ] || continue
            key_dockerfile="${key#*$'\t'}"
            printf '  %s: %s\n' "$key_dockerfile" "${base_image_of[$key]}" >&2
        done
    fi
done

if [ "$overall_status" -ne 0 ]; then
    echo "" >&2
    echo "Either update the stale base-image claim in dependabot.yml's own comment to match reality, or split the diverged Dockerfile(s) into their own dependabot.yml block/group so each block's own grouped-PR premise holds again." >&2
    exit 1
fi

echo "check-dependabot-docker-base-consistency: OK (${#base_image_of[@]} Dockerfiles across ${#distinct_blocks[@]} docker-ecosystem block(s), each internally consistent)."
