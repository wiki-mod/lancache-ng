#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Scans git-tracked files for the required repository header (see AGENTS.md's
# "File Headers" section). By default scans the whole repository; pass file
# paths as arguments to scan only those (used by CI to check just a PR's
# diff, and by developers to check a file before committing it).
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
cd "$repo_root"

HEADER_TEXT='lancache-ng (https://github.com/wiki-mod/lancache-ng)'
HEADER_SCAN_LINES=20

# Mirrors AGENTS.md's "File Headers" exclusion list exactly — update both
# together if the policy changes.
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
        # JSON despite the .conf extension — see AGENTS.md for why these
        # three specifically are excluded.
        services/dhcp/kea-dhcp4.conf | services/dhcp/kea-ctrl-agent.conf | services/dhcp/kea-dhcp-ddns.conf) return 0 ;;
        # Vendored third-party file and generated/compiled build output.
        services/ui/src/static/chart.umd.min.js | services/ui/src/static/admin.css) return 0 ;;
        # Vendored third-party data file (Mozilla Public Suffix List) —
        # already carries its own upstream MPL-2.0 header.
        services/proxy/public_suffix_list.dat) return 0 ;;
        # Binary/compiled asset types a comment header cannot apply to.
        *.png | *.jpg | *.jpeg | *.gif | *.ico | *.svg | *.woff | *.woff2 | *.ttf | *.eot | *.crt | *.key | *.pem) return 0 ;;
        *) return 1 ;;
    esac
}

if [ "$#" -gt 0 ]; then
    files=("$@")
else
    mapfile -t files < <(git ls-files)
fi

missing=()
for path in "${files[@]}"; do
    [ -f "$path" ] || continue
    is_excluded "$path" && continue
    if ! head -n "$HEADER_SCAN_LINES" "$path" | grep -qF "$HEADER_TEXT"; then
        missing+=("$path")
    fi
done

if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing the required repository header (AGENTS.md 'File Headers'):" >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
fi

echo "All checked files carry the required repository header (or are exempt)."
