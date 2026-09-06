#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: checks What/Why/From comment length + count.
# Why: the format cap was self-check-only before.
# From: Issue #1830
set -euo pipefail

# usage: check-comment-length.sh <file> [<file> ...]
# Each argument may be an absolute or relative path. For every
# "# What:" / "# Why:" / "# From:" comment line it enforces two hard
# AG-CODE-012 limits and nothing else (no semantic, From-format, or
# narrative judgement -- that stays human/review scope, by design):
#   1. the physical line is at most 60 characters
#   2. a contiguous run of such lines is at most 3 (the block ceiling)
# Exits 1 on any violation, 2 on a usage/argument error.

if [ "$#" -eq 0 ]; then
    echo "usage: $(basename "$0") <file> [<file> ...]" >&2
    exit 2
fi

status=0
for file in "$@"; do
    if [ ! -f "$file" ]; then
        echo "check-comment-length: not a file: $file" >&2
        status=2
        continue
    fi
    # A trailing CR (CRLF checkout) is stripped before measuring so the
    # count reflects the real comment text, not the line terminator.
    awk '
        function flush() {
            if (blocklen > 3) {
                printf "%s:%d: What/Why/From block has %d lines (max 3)\n", \
                    FILENAME, blockstart, blocklen
                viol++
            }
            blocklen = 0
        }
        {
            line = $0
            sub(/\r$/, "", line)
            if (line ~ /^[[:space:]]*#[[:space:]]*(What|Why|From):/) {
                if (blocklen == 0) blockstart = FNR
                blocklen++
                if (length(line) > 60) {
                    printf "%s:%d: %d chars (max 60): %s\n", \
                        FILENAME, FNR, length(line), line
                    viol++
                }
            } else if (blocklen > 0) {
                flush()
            }
        }
        END { if (blocklen > 0) flush(); if (viol > 0) exit 1 }
    ' "$file" || status=1
done

if [ "$status" -eq 0 ]; then
    echo "check-comment-length: OK"
fi
exit "$status"
