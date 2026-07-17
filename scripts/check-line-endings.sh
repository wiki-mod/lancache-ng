#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Scans git-tracked files for CRLF line endings (issue #601). .gitattributes
# already declares `* text=auto eol=lf`, which normalizes line endings for
# files git touches going forward, but does not catch files where that
# normalization was bypassed (e.g. a direct API write, or a file committed
# before the attribute existed and never renormalized). By default scans the
# whole repository; pass file paths as arguments to scan only those.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
cd "$repo_root"

# Binary/compiled asset types a line-ending check cannot apply to.
is_excluded() {
    case "$1" in
        *.png | *.jpg | *.jpeg | *.gif | *.ico | *.woff | *.woff2 | *.ttf | *.eot | *.crt | *.key | *.pem) return 0 ;;
        *) return 1 ;;
    esac
}

if [ "$#" -gt 0 ]; then
    files=("$@")
else
    mapfile -t files < <(git ls-files)
fi

offenders=()
for path in "${files[@]}"; do
    [ -f "$path" ] || continue
    is_excluded "$path" && continue
    # grep -a (treat every file as text) rather than -I: -I's binary-file
    # heuristic looks for a NUL byte and silently skips the file if found,
    # which also skips every UTF-16 text file (each ASCII character encodes
    # as <byte> 0x00 in UTF-16LE) -- including a genuine CRLF-terminated one
    # (0d 00 0a 00), such as a PowerShell script saved by Windows tooling.
    # -a scans raw bytes for \r in every file not already excluded above.
    if grep -aq $'\r' "$path" 2>/dev/null; then
        offenders+=("$path")
    fi
done

if [ "${#offenders[@]}" -gt 0 ]; then
    echo "Files with CRLF (Windows) line endings found -- this repo requires Unix (LF) line endings:" >&2
    printf '  %s\n' "${offenders[@]}" >&2
    echo "" >&2
    echo "Fix with: sed -i 's/\\r\$//' <file>" >&2
    exit 1
fi

echo "All checked files use Unix (LF) line endings."
