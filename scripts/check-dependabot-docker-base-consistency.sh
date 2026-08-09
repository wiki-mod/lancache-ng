#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Dependabot groups the Dockerfiles in each docker-ecosystem block into one
# update PR on the premise that their final-stage base images match. Keep
# each block independent and compare effective images, including global ARG
# defaults and aliases, so harmless Dockerfile syntax differences do not
# obscure either equality or real drift.
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

# This deliberately narrow parser handles the scalar forms used by this
# file without requiring host-side YAML packages. Every update entry ends
# the preceding block; comments therefore cannot keep Docker parsing active.
mapfile -t tagged_directories < <(awk -f - "$dependabot_file" <<'AWKPROG'
function scalar(line, value) {
    value=line
    sub(/^[^:]*:[[:space:]]*/, "", value)
    sub(/[[:space:]]*#.*$/, "", value)
    gsub(/^[[:space:]"'\047]+|[[:space:]"'\047]+$/, "", value)
    return value
}
/^  - package-ecosystem:/ {
    ecosystem=tolower(scalar($0))
    in_docker=(ecosystem == "docker")
    if (in_docker) block++
    next
}
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

resolve_final_image() {
    local dockerfile="$1" line instruction remainder image alias name value token
    local seen_from=0 final_image=""
    local -A global_args=() stage_images=()

    # Dockerfile heredoc bodies are data rather than instructions, while a
    # backslash-continued instruction is one logical line. Normalize those
    # two forms before looking for ARG and FROM instructions.
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        instruction="${line%%[[:space:]]*}"
        remainder="${line#"$instruction"}"
        remainder="${remainder#"${remainder%%[![:space:]]*}"}"

        if [ "$seen_from" -eq 0 ] && [[ "${instruction,,}" == "arg" ]]; then
            name="${remainder%%=*}"
            if [[ "$remainder" == *=* ]]; then
                value="${remainder#*=}"
                value="${value%\"}"; value="${value#\"}"
                value="${value%\'}"; value="${value#\'}"
                global_args["$name"]="$value"
            fi
            continue
        fi
        [[ "${instruction,,}" == "from" ]] || continue
        seen_from=1
        remainder="${remainder#--platform=* }"
        image="${remainder%%[[:space:]]*}"

        # Match complete Docker ARG tokens so prefix-related names cannot
        # affect one another through associative-array iteration order.
        while [[ "$image" =~ (\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)) ]]; do
            token="${BASH_REMATCH[1]}"
            name="${BASH_REMATCH[2]:-${BASH_REMATCH[3]}}"
            if [[ ! -v "global_args[$name]" ]]; then
                printf '::error::check-dependabot-docker-base-consistency: could not resolve global ARG %s in a FROM image in %s\n' "$name" "$dockerfile" >&2
                return 1
            fi
            image="${image/"$token"/${global_args[$name]}}"
        done
        if [[ "$image" == *'$'* ]]; then
            printf '::error::check-dependabot-docker-base-consistency: unsupported or unresolved ARG expression in a FROM image in %s: %s\n' "$dockerfile" "$image" >&2
            return 1
        fi

        # A final stage may inherit from an earlier named stage; compare the
        # originating external image rather than the local alias text.
        if [[ -v "stage_images[${image,,}]" ]]; then
            image="${stage_images[${image,,}]}"
        fi
        alias=""
        if [[ "$remainder" =~ [[:space:]][Aa][Ss][[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
            alias="${BASH_REMATCH[1],,}"
            stage_images["$alias"]="$image"
        fi
        final_image="$image"
    done < <(awk '
        function emit_logical(    marker, candidate) {
            print logical
            candidate=logical
            sub(/^[[:space:]]*/, "", candidate)
            # A comment can describe heredoc syntax without starting a
            # heredoc; only Dockerfile instructions can own payload lines.
            if (candidate !~ /^#/ && candidate ~ /^[A-Za-z]+[[:space:]]/ &&
                match(candidate, /<<-?[[:space:]]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?/)) {
                marker=substr(candidate, RSTART, RLENGTH)
                sub(/^<<-?[[:space:]]*/, "", marker)
                gsub(/["'"'"']/, "", marker)
                heredoc=marker
            }
            logical=""
        }
        heredoc != "" {
            candidate=$0
            sub(/^[[:space:]]*/, "", candidate)
            if (candidate == heredoc) heredoc=""
            next
        }
        {
            physical=$0
            if (physical ~ /\\[[:space:]]*$/) {
                sub(/\\[[:space:]]*$/, "", physical)
                logical=logical physical " "
                next
            }
            logical=logical physical
            emit_logical()
        }
        END { if (logical != "") emit_logical() }
    ' "$dockerfile")

    if [ -z "$final_image" ]; then
        printf '::error::check-dependabot-docker-base-consistency: no FROM instruction found in %s\n' "$dockerfile" >&2
        return 1
    fi
    printf '%s\n' "$final_image"
}

for entry in "${tagged_directories[@]}"; do
    block="${entry%%$'\t'*}"
    dir="${entry#*$'\t'}"
    dockerfile="${dir#/}/Dockerfile"
    if [ ! -f "$dockerfile" ]; then
        missing_dockerfiles+=("$dockerfile")
        continue
    fi
    normalized_image=$(resolve_final_image "$dockerfile") || exit 1

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
