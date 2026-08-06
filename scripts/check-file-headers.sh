#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Scans git-tracked files for the required repository header (see AGENTS.md's
# "File Headers" section) and, separately, for the SPDX-License-Identifier
# line (AG-HDR-008). By default scans the whole repository; pass file paths
# as arguments to scan only those (used by CI to check just a PR's diff, and
# by developers to check a file before committing it).
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
cd "$repo_root"

HEADER_TEXT='lancache-ng (https://github.com/wiki-mod/lancache-ng)'
SPDX_TEXT='SPDX-License-Identifier: AGPL-3.0-or-later'
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
        # Machine-generated OpenVEX document (JSON has no comment syntax, so it
        # cannot carry the repo header); produced by scripts/generate-vex.sh
        # from .trivyignore.yaml and kept in sync by scripts/check-vex-drift.sh.
        vex.openvex.json | */vex.openvex.json) return 0 ;;
        # Validation-state tracking record (JSON, no comment syntax) referenced
        # by docs/release-validation-plan.md — same exclusion rationale as
        # vex.openvex.json above.
        docs/validation-state.json | */docs/validation-state.json) return 0 ;;
        # Vendored third-party file and generated/compiled build output.
        services/ui/src/static/chart.umd.min.js | services/ui/src/static/admin.css) return 0 ;;
        # Vendored third-party data file (Mozilla Public Suffix List) —
        # already carries its own upstream MPL-2.0 header.
        services/proxy/public_suffix_list.dat) return 0 ;;
        # Vendored third-party file (PowerDNS Authoritative Server's own
        # gsqlite3 backend schema, GPL-licensed upstream, not lancache-ng's
        # own AGPL source) — issue #815's services/dns Alpine migration.
        # Unlike public_suffix_list.dat above, the upstream file itself
        # carries no header at all, so this one keeps a plain provenance
        # comment (fetch source, why it's vendored) instead of either a
        # lancache-ng project header or an SPDX line that would misattribute
        # the license of literally-copied upstream content — see the file's
        # own comment block for the full reasoning.
        services/dns/schema.sqlite3.sql) return 0 ;;
        # cargo-fuzz seed corpus fixtures (issue #1252): raw bytes libFuzzer
        # feeds directly to the harness under test (JSON in this repo's
        # current targets, but this exclusion is by directory, not
        # extension, since a fuzz corpus is fixture data in whatever shape
        # the target parses). A header would corrupt the exact bytes being
        # fuzzed — the same reason JSON config files are excluded above.
        */fuzz/corpus/* | fuzz/corpus/*) return 0 ;;
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
missing_spdx=()
for path in "${files[@]}"; do
    [ -f "$path" ] || continue
    is_excluded "$path" && continue
    scanned="$(head -n "$HEADER_SCAN_LINES" "$path")"
    if ! grep -qF "$HEADER_TEXT" <<<"$scanned"; then
        missing+=("$path")
    fi
    if ! grep -qF "$SPDX_TEXT" <<<"$scanned"; then
        missing_spdx+=("$path")
    fi
done

if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing the required repository header (AGENTS.md 'File Headers'):" >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
fi

# AG-HDR-008 (decided 2026-08-02): every in-scope file should carry the SPDX
# line too, added incrementally ("touch a file, verify the line is there, add
# it if not" -- not a one-shot repo-wide backfill). Reported but NOT yet
# enforced (no exit 1) here: as of this check's own introduction, this line
# exists in only a handful of files, so failing on it in whole-repo scan mode
# (how build-push.yml's own file-headers job invokes this script today, no
# path arguments) would immediately block every PR on pre-existing files it
# never touched. Flip this to a hard failure only once the repo-wide backfill
# is tracked and materially underway -- see AG-HDR-008's own text for the
# same two-step rollout AG-HDR-009 already used for the header line itself.
if [ "${#missing_spdx[@]}" -gt 0 ]; then
    echo "Missing the SPDX-License-Identifier line (AGENTS.md AG-HDR-008) -- not yet enforced, backfill in progress:" >&2
    printf '  %s\n' "${missing_spdx[@]}" >&2
fi

echo "All checked files carry the required repository header (or are exempt)."
