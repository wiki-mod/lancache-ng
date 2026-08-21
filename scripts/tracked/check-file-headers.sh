#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Scans git-tracked files for the canonical repository header contract from
# AGENTS.md. Every non-excluded file must use the file format's native comment
# syntax. A genuinely required interpreter/parser marker occupies physical line 1;
# Rust uses a bare `//!` formatter-stable placeholder on line 1; otherwise line 1 is blank.
# The LanCache-NG project header stays on physical line 2 and SPDX stays on physical line 3.
set -euo pipefail

# Tracked separately from $# because the whole-repository branch below replaces
# the caller-provided file list with git ls-files output. Explicit-file mode
# intentionally keeps the caller's current directory so isolated Bats fixtures
# and PR-diff paths can be checked without pretending they live at repo root.
explicit_files=0
[ "$#" -gt 0 ] && explicit_files=1

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
if [ "$explicit_files" -eq 0 ]; then
    cd "$repo_root"
fi

HEADER_TEXT='LanCache-NG (https://github.com/wiki-mod/lancache-ng)'
LEGACY_HEADER_TEXT='lancache-ng (https://github.com/wiki-mod/lancache-ng)'
SPDX_TEXT='SPDX-License-Identifier: AGPL-3.0-or-later'
HEADER_SCAN_LINES=20

# Mirrors AGENTS.md's "File Headers" exclusion list exactly. This PR changes
# the required header layout only; it deliberately does not widen or narrow
# the pre-existing exclusion contract.
is_excluded() {
    case "$1" in
        *.md) return 0 ;;
        .env | .env.example | */.env | */.env.example) return 0 ;;
        Cargo.lock | */Cargo.lock) return 0 ;;
        .gitkeep | */.gitkeep) return 0 ;;
        VERSION) return 0 ;;
        # A LICENSE/COPYING file must contain unmodified license text for
        # tooling (GitHub's license detector, SPDX scanners) to recognize it;
        # a prepended repo header would corrupt that.
        LICENSE | COPYING) return 0 ;;
        # JSON despite the .conf extension -- see AGENTS.md for why these
        # three specifically are excluded.
        services/dhcp/kea-dhcp4.conf | services/dhcp/kea-ctrl-agent.conf | services/dhcp/kea-dhcp-ddns.conf) return 0 ;;
        # Validation-state tracking record (JSON, no comment syntax) referenced
        # by docs/release-validation-plan.md -- no comment syntax to carry a
        # header in, same exclusion rationale the removed vex.openvex.json
        # entry used to state before that file stopped being committed to
        # current_dev at all (Issue #1095 F-22).
        docs/validation-state.json | */docs/validation-state.json) return 0 ;;
        # Vendored third-party file and generated/compiled build output.
        services/ui/src/static/chart.umd.min.js | services/ui/src/static/admin.css) return 0 ;;
        # Vendored third-party data file (Mozilla Public Suffix List) --
        # already carries its own upstream MPL-2.0 header.
        services/proxy/public_suffix_list.dat) return 0 ;;
        # Vendored third-party file (PowerDNS Authoritative Server's own
        # gsqlite3 backend schema, GPL-licensed upstream, not LanCache-NG's
        # own AGPL source). The upstream copy keeps its provenance comment
        # instead of a first-party project/SPDX header.
        services/dns/schema.sqlite3.sql) return 0 ;;
        # cargo-fuzz seed corpus fixtures are raw bytes fed directly to the
        # harness under test. A comment header would change those fixture bytes.
        */fuzz/corpus/* | fuzz/corpus/*) return 0 ;;
        # Binary/compiled asset types a comment header cannot apply to.
        *.png | *.jpg | *.jpeg | *.gif | *.ico | *.svg | *.woff | *.woff2 | *.ttf | *.eot | *.crt | *.key | *.pem) return 0 ;;
        *) return 1 ;;
    esac
}

# Resolve the canonical native-comment representation from the file format,
# never by copying delimiters from whatever text happens to be in the file.
# That distinction matters for Tera: a multi-line `{# ... #}` purpose block is
# valid template syntax, but its opener alone is not a valid standalone header
# line to clone for the SPDX identifier.
set_expected_header_lines() {
    local path="$1"

    case "$path" in
        services/ui/src/templates/*.html | */services/ui/src/templates/*.html)
            expected_project_line="{# $HEADER_TEXT #}"
            expected_spdx_line="{# $SPDX_TEXT #}"
            ;;
        *.html)
            expected_project_line="<!-- $HEADER_TEXT -->"
            expected_spdx_line="<!-- $SPDX_TEXT -->"
            ;;
        *.rs)
            expected_project_line="//! $HEADER_TEXT"
            expected_spdx_line="//! $SPDX_TEXT"
            ;;
        *.lua)
            expected_project_line="-- $HEADER_TEXT"
            expected_spdx_line="-- $SPDX_TEXT"
            ;;
        *.js)
            expected_project_line="// $HEADER_TEXT"
            expected_spdx_line="// $SPDX_TEXT"
            ;;
        *.css)
            expected_project_line="/* $HEADER_TEXT */"
            expected_spdx_line="/* $SPDX_TEXT */"
            ;;
        *.sh | *.bats | *.yml | *.yaml | *.toml | *.conf | *.template | *.txt | *.env | *.service | *.timer | *.ps1 | *.dockerignore | Dockerfile | */Dockerfile | .gitattributes | .gitignore | */.gitignore | .shellspec | */.shellspec | CODEOWNERS | */CODEOWNERS | .githooks/* | */.githooks/*)
            expected_project_line="# $HEADER_TEXT"
            expected_spdx_line="# $SPDX_TEXT"
            ;;
        *)
            return 1
            ;;
    esac

    # The legacy form is derived only after the native syntax has been selected
    # explicitly above. It is used solely to reject a stale lowercase header.
    expected_legacy_project_line="${expected_project_line/"$HEADER_TEXT"/"$LEGACY_HEADER_TEXT"}"
}

# A shebang is a real interpreter marker. Docker parser directives are also
# recognized on line 1 using Docker's documented `# directive=value` grammar:
# syntax/escape/check keys are case-insensitive and allow non-line-breaking
# whitespace around the key/value separator. The fixed line-2/line-3 contract
# intentionally permits only one such leading directive; a Dockerfile needing
# multiple directives must fail closed instead of silently moving a directive
# below an ordinary comment where BuildKit would stop recognizing it.
is_allowed_line1() {
    local path="$1"
    local first_line="$2"
    local lower_first_line

    case "$path" in
        *.rs) [ "$first_line" = "//!" ] && return 0 || return 1 ;;
    esac

    [ -z "$first_line" ] && return 0
    [[ "$first_line" == '#!'* ]] && return 0

    case "$path" in
        Dockerfile | */Dockerfile)
            lower_first_line="${first_line,,}"
            [[ "$lower_first_line" =~ ^#[[:space:]]*(syntax|escape|check)[[:space:]]*=[[:space:]]*.+$ ]] && return 0
            ;;
    esac

    return 1
}

if [ "$explicit_files" -eq 1 ]; then
    files=("$@")
else
    # Command substitution (not process substitution) keeps git ls-files'
    # actual exit status observable so a broken work tree fails closed instead
    # of producing an empty list that could be mistaken for a clean scan.
    if ! files_raw="$(git ls-files)"; then
        echo "::error::check-file-headers: \`git ls-files\` itself failed -- is $repo_root a real git work tree? Not treating this as a clean pass." >&2
        exit 1
    fi
    files=()
    if [ -n "$files_raw" ]; then
        mapfile -t files <<<"$files_raw"
    fi
fi

failures=()
for path in "${files[@]}"; do
    [ -f "$path" ] || continue

    # is_excluded() uses repository-relative literals, while explicit-file
    # callers may spell a path relative to another directory. Normalize only
    # the exclusion/syntax key; keep the caller's original $path for all I/O.
    exclusion_key="$path"
    if abs_dir=$(cd "$(dirname -- "$path")" 2>/dev/null && pwd); then
        abs_path="$abs_dir/$(basename -- "$path")"
        case "$abs_path" in
            "$repo_root"/*) exclusion_key="${abs_path#"$repo_root"/}" ;;
        esac
    fi
    is_excluded "$exclusion_key" && continue

    if ! set_expected_header_lines "$exclusion_key"; then
        failures+=("$path: no native header comment syntax is defined for this file type")
        continue
    fi

    if ! scanned="$(head -n "$HEADER_SCAN_LINES" -- "$path")"; then
        echo "::error::check-file-headers: could not read $path" >&2
        exit 1
    fi
    mapfile -t scanned_lines <<<"$scanned"

    first_line="${scanned_lines[0]-}"
    if ! is_allowed_line1 "$exclusion_key" "$first_line"; then
        failures+=("$path: line 1 does not match the canonical placeholder/interpreter/parser-marker contract")
    fi

    if [ "${scanned_lines[1]-}" != "$expected_project_line" ]; then
        failures+=("$path: line 2 must be exactly: $expected_project_line")
    fi
    if [ "${scanned_lines[2]-}" != "$expected_spdx_line" ]; then
        failures+=("$path: line 3 must be exactly: $expected_spdx_line")
    fi

    project_count=0
    spdx_count=0
    legacy_count=0
    for scanned_line in "${scanned_lines[@]}"; do
        [ "$scanned_line" = "$expected_project_line" ] && project_count=$((project_count + 1))
        [ "$scanned_line" = "$expected_spdx_line" ] && spdx_count=$((spdx_count + 1))
        [ "$scanned_line" = "$expected_legacy_project_line" ] && legacy_count=$((legacy_count + 1))
    done

    [ "$project_count" -eq 1 ] || failures+=("$path: canonical project header must appear exactly once in the first $HEADER_SCAN_LINES lines (found $project_count)")
    [ "$spdx_count" -eq 1 ] || failures+=("$path: SPDX identifier must appear exactly once in the first $HEADER_SCAN_LINES lines (found $spdx_count)")
    [ "$legacy_count" -eq 0 ] || failures+=("$path: legacy lowercase lancache-ng header is not allowed")
done

if [ "${#failures[@]}" -gt 0 ]; then
    echo "Invalid repository file header layout (AGENTS.md 'File Headers'):" >&2
    printf '  %s\n' "${failures[@]}" >&2
    exit 1
fi

echo "All checked files carry the canonical repository header and SPDX identifier (or are exempt)."
