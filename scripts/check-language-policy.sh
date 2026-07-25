#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Enforces AG-GOV-003 (project language: Rust and shell for code we write,
# other languages need explicit maintainer approval every time) by scanning
# git-tracked files for source extensions this project has explicitly decided
# not to write in. This is deliberately an inverted check compared to CodeQL's
# per-language analysis: CodeQL scans code IN a language for vulnerabilities,
# which is worthless once a language has zero files (as happened here after
# issue #1158's Rust rewrite of the last Python file, tools/pxe-client-probe)
# -- it just fails forever with "could not process any code". This check
# instead asserts the language's absence and fails the moment a file of a
# banned extension reappears, which is the actual governance property this
# project wants enforced. By default scans the whole repository; pass file
# paths as arguments to scan only those.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
cd "$repo_root"

# A vendored, third-party static asset served as-is (e.g. a minified
# frontend charting library) is not "code we write" -- AG-GOV-003 governs
# what this project authors, not what it serves unmodified from upstream.
# Vendored assets live under services/ui/src/static/ and are minified
# (*.min.js), which distinguishes them from a hand-authored source file.
is_vendored_asset() {
    case "$1" in
        services/ui/src/static/*.min.js) return 0 ;;
        *) return 1 ;;
    esac
}

# Extensions for languages this project has explicitly decided not to write
# in (AG-GOV-003). Extend this list if a new banned-language incident occurs
# -- do not silently work around a violation instead of updating the guard.
is_banned_extension() {
    is_vendored_asset "$1" && return 1
    case "$1" in
        *.py | *.pyc | *.pyw) return 0 ;;   # Python -- rewritten to Rust, #1158
        *.rb) return 0 ;;                   # Ruby
        *.php) return 0 ;;                  # PHP
        *.js | *.mjs | *.cjs | *.ts) return 0 ;;  # JavaScript/TypeScript
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
    if is_banned_extension "$path"; then
        offenders+=("$path")
    fi
done

if [ "${#offenders[@]}" -gt 0 ]; then
    echo "Files in a language this project has decided not to write in were found (AG-GOV-003 violation):" >&2
    printf '  %s\n' "${offenders[@]}" >&2
    echo "" >&2
    echo "Project language is Rust (and shell for scripts). Introducing another language requires" >&2
    echo "explicit maintainer approval every time, per AG-GOV-003 in AGENTS.md -- it is not a blanket" >&2
    echo "ban on ever invoking another language's toolchain (e.g. building a third-party Go tool with" >&2
    echo "golang:latest for a real CVE reason is fine), but new source files in a banned language" >&2
    echo "written by us are not." >&2
    exit 1
fi

echo "No files in a banned language found -- AG-GOV-003 holds."
