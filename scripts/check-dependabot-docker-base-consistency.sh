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
# deliberately narrow, line-based parse (not a real YAML parser -- cheap,
# host-runnable bash/awk/grep with no build-tools-image dependency of its
# own, matching this project's other lightweight guard scripts' shape,
# e.g. scripts/check-review-chronology-comments.sh): it looks for
# each `package-ecosystem: docker` line, incrementing the block index every
# time one is seen, and collects every subsequent `      - /path` entry
# (tab-separated with its block index) until the next top-level
# `- package-ecosystem:` block or end of file. Output lines are
# `<block_index>\t<directory>`. Both the ecosystem value and each directory
# entry may be a bare scalar or a single/double-quoted YAML string (e.g.
# `package-ecosystem: "docker"`, `- "/services/proxy"`) -- both forms parse
# identically, since YAML itself treats them as equivalent, so the pattern
# below strips a matching leading/trailing quote character (either kind)
# before comparing. Either line may also carry a trailing YAML comment
# (e.g. `package-ecosystem: docker # runtime services`, `- /services/proxy
# # primary`) -- YAML comments are valid anywhere after a scalar value, so
# both patterns tolerate an optional `# ...` tail before end of line, and
# the comment-stripping step below removes it from the extracted directory
# value too before quote-stripping. The awk program is fed via a quoted
# heredoc rather than this script's original bash single-quoted string,
# since the regex needs a literal `'` character in its own quote-stripping
# character class, which a bash single-quoted string cannot contain at all.
mapfile -t tagged_directories < <(awk -f - "$dependabot_file" <<'AWKPROG'
/^  - package-ecosystem:[[:space:]]*["']?[Dd]ocker["']?[[:space:]]*(#.*)?$/ { in_docker=1; block++; next }
/^  - package-ecosystem:/ && !/[Dd]ocker/ { in_docker=0 }
in_docker && /^      - / {
    path=$0
    sub(/^      - /, "", path)
    sub(/[[:space:]]*#.*$/, "", path)
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

    # Resolve an ARG-substituted image reference (e.g. `FROM ${RUNTIME_BASE}`)
    # rather than comparing the literal, unsubstituted string: two
    # Dockerfiles can both read `${RUNTIME_BASE}` in their final FROM line
    # while declaring genuinely different `ARG RUNTIME_BASE=...` defaults
    # above it, in which case comparing the raw `${RUNTIME_BASE}` text would
    # report both as "the same image" despite actually diverging. Only
    # global-scope ARGs (declared before the file's own last FROM line,
    # the only ones Docker itself makes visible to a FROM instruction's own
    # image reference) are collected; a later same-named ARG re-declared
    # inside a build stage does not change what an earlier FROM line reads.
    # Falls back to the literal string if there is nothing to substitute.
    if [[ "$normalized_image" == *'$'* ]]; then
        declare -A arg_defaults=()
        last_from_line_num=$(grep -niE '^[[:space:]]*FROM[[:space:]]' "$dockerfile" | tail -n1 | cut -d: -f1)
        while IFS= read -r arg_decl; do
            [ -n "$arg_decl" ] || continue
            arg_name="${arg_decl%%=*}"
            if [[ "$arg_decl" == *=* ]]; then
                arg_value="${arg_decl#*=}"
                # Strip one matching pair of surrounding quotes, if present.
                arg_value="${arg_value%\"}"; arg_value="${arg_value#\"}"
                arg_value="${arg_value%\'}"; arg_value="${arg_value#\'}"
                arg_defaults["$arg_name"]="$arg_value"
            fi
        done < <(head -n "$last_from_line_num" "$dockerfile" | grep -Ei '^[[:space:]]*ARG[[:space:]]+' | sed -E 's/^[[:space:]]*ARG[[:space:]]+//I')

        # Substitute every ${NAME} or $NAME this specific image reference
        # contains, using only the ARG defaults just collected -- a bash
        # associative array, not eval, so no other part of $normalized_image
        # is ever executed as code.
        resolved_image="$normalized_image"
        for arg_name in "${!arg_defaults[@]}"; do
            resolved_image="${resolved_image//\$\{$arg_name\}/${arg_defaults[$arg_name]}}"
            resolved_image="${resolved_image//\$$arg_name/${arg_defaults[$arg_name]}}"
        done

        if [[ "$resolved_image" == *'$'* ]]; then
            printf '::error::check-dependabot-docker-base-consistency: %s'"'"'s final FROM line (%s) references a variable this guard could not resolve to a plain image reference (no matching ARG default found before that FROM line) -- cannot prove this Dockerfile'"'"'s effective base image, failing closed rather than silently comparing an unresolved literal.\n' "$dockerfile" "$normalized_image" >&2
            exit 1
        fi
        normalized_image="$resolved_image"
    fi

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
    echo "This check only compares the Dockerfiles' own FROM lines -- it does not read dependabot.yml's comments at all, so editing that comment's wording cannot make this pass. Either change the diverged Dockerfile(s)' base image(s) so every directory in the block matches again, or split the diverged directory into its own separate dependabot.yml docker-ecosystem block/group so each block's own grouped-PR premise holds independently." >&2
    exit 1
fi

echo "check-dependabot-docker-base-consistency: OK (${#base_image_of[@]} Dockerfiles across ${#distinct_blocks[@]} docker-ecosystem block(s), each internally consistent)."
