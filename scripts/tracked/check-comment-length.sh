#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: enforces AG-CODE-012 comment length/block limits.
# Why: mechanical size check only, no semantic judgment.
# From: Issue #1830
set -euo pipefail

# usage: check-comment-length.sh <file> [<file> ...]

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

    # What: story-telling scan v1 covers only "#".
    # Why: v1 scoped to bash/bats/yaml only, not Rust/JS.
    # From: Issue #1830
    case "$file" in
        *.yml|*.yaml) heredoc_on=0; yaml_on=1 ;;
        *)            heredoc_on=1; yaml_on=0 ;;
    esac
    awk -v heredoc_on="$heredoc_on" -v yaml_on="$yaml_on" '
        BEGIN {
            # A literal apostrophe cannot appear in this awk program text
            # (it is embedded in a single-quoted bash string), so the
            # heredoc quote-class is built at runtime via chr(39) instead.
            sq = sprintf("%c", 39)
            qclass = "[" sq "\"]"
            heredoc_open_re = "<<-?[[:space:]]*" qclass "?[A-Za-z_][A-Za-z0-9_]*" qclass "?"
            strip_lead_re = "^<<-?[[:space:]]*" qclass "?"
            strip_trail_re = qclass "?$"
        }
        { lines[FNR] = $0 }
        function flush_run() {
            if (real_len > 3) {
                printf "%s:%d: possible AG-CODE-012 story-telling block " \
                    "(%d contiguous comment lines, not a valid " \
                    "What/Why/From block)\n", \
                    FILENAME, block_start, real_len
                viol++
            }
            block_start = 0
            real_len = 0
        }
        END {
            n = FNR
            header_end = 0
            if (n >= 3 \
                && lines[2] ~ /^#[[:space:]]*LanCache-NG \(https:\/\/github\.com\/wiki-mod\/lancache-ng\)[[:space:]]*$/ \
                && lines[3] ~ /^#[[:space:]]*SPDX-License-Identifier: AGPL-3\.0-or-later[[:space:]]*$/) {
                header_end = 3
            }

            in_heredoc = 0; heredoc_delim = ""; heredoc_dash = 0
            in_yaml = 0; yaml_indent = -1
            block_start = 0; real_len = 0

            for (i = 1; i <= n; i++) {
                line = lines[i]
                sub(/\r$/, "", line)

                if (i <= header_end) { flush_run(); continue }

                # A heredoc body is DATA -- everything up to its closing
                # delimiter is skipped whole, even lines shaped like "#..."
                if (heredoc_on && in_heredoc) {
                    check_line = line
                    if (heredoc_dash) sub(/^\t+/, "", check_line)
                    if (check_line == heredoc_delim) in_heredoc = 0
                    flush_run()
                    continue
                }

                # A YAML block scalar (e.g. "run: |") is DATA for every
                # deeper-indented or blank line until it dedents back out.
                if (yaml_on && in_yaml) {
                    if (line ~ /^[[:space:]]*$/) { flush_run(); continue }
                    match(line, /[^ ]/)
                    if ((RSTART - 1) > yaml_indent) { flush_run(); continue }
                    in_yaml = 0
                }

                if (line ~ /^[[:space:]]*#/) {
                    stripped = line
                    sub(/^[[:space:]]*#[[:space:]]*/, "", stripped)
                    sub(/[[:space:]]+$/, "", stripped)
                    is_divider = (stripped ~ /^[-=~_*]{4,}$/) \
                        || (stripped ~ /^(─|━|═|┄|┈|╌|╍)/)
                    if (block_start == 0) block_start = i
                    if (!is_divider) real_len++
                    continue
                }

                # Not a comment: flush any run, then this real code line
                # may itself open a new heredoc or YAML block scalar.
                flush_run()
                if (heredoc_on) {
                    tmp = line
                    while (match(tmp, heredoc_open_re)) {
                        seg = substr(tmp, RSTART, RLENGTH)
                        heredoc_dash = (seg ~ /^<<-/)
                        d = seg
                        sub(strip_lead_re, "", d)
                        sub(strip_trail_re, "", d)
                        heredoc_delim = d
                        in_heredoc = 1
                        tmp = substr(tmp, RSTART + RLENGTH)
                    }
                }
                if (yaml_on && !in_heredoc) {
                    if (match(line, /^[[:space:]]*(-[[:space:]]+)?[A-Za-z0-9_.-]+:[[:space:]]*[|>][+-]?[0-9]?[[:space:]]*$/)) {
                        match(line, /[^ ]/)
                        yaml_indent = RSTART - 1
                        in_yaml = 1
                    }
                }
            }
            flush_run()
            if (viol > 0) exit 1
        }
    ' "$file" || status=1
done

if [ "$status" -eq 0 ]; then
    echo "check-comment-length: OK"
fi
exit "$status"
