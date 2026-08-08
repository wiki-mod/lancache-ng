#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Scans git-tracked files for the required repository header (see AGENTS.md's
# "File Headers" section) and, separately, for the SPDX-License-Identifier
# line (AG-HDR-008). By default scans the whole repository; pass file paths
# as arguments to scan only those (used by CI to check just a PR's diff, and
# by developers to check a file before committing it). The SPDX check is
# hard-enforced (exit 1) when explicit file paths are given, since the
# repo-wide backfill exception does not cover a file someone is actively
# touching; it stays soft/informational for a whole-repo scan, where the
# backfill is still incomplete.
set -euo pipefail

# Tracked separately from $# after this point ($files gets reassigned via
# mapfile in the whole-repo branch): whether the caller passed explicit
# paths determines whether a missing SPDX line below is a hard failure
# (this invocation is scanning a known, currently-being-touched file set --
# a PR's diff, or a developer checking one file before committing) or the
# existing soft/informational report (a whole-repo scan, where the backfill
# is deliberately still incomplete -- see AG-HDR-008's own text). Computed
# up front, before any `cd`, so it reflects the caller's real invocation.
explicit_files=0
[ "$#" -gt 0 ] && explicit_files=1

# Only the whole-repo scan (git ls-files) needs cwd forced to this script's
# own repo root -- an explicit-file invocation resolves its given paths
# relative to wherever the caller actually ran from, which is what makes an
# isolated bats fixture directory (a throwaway git repo elsewhere on disk,
# never the real repo) usable for testing the explicit-file mode without
# ever touching this repo's own tracked files.
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
if [ "$explicit_files" -eq 0 ]; then
    cd "$repo_root"
fi

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

if [ "$explicit_files" -eq 1 ]; then
    files=("$@")
else
    # Command substitution (not `mapfile -t files < <(git ls-files)`) so a
    # real `git ls-files` failure (a broken/missing .git, corrupted index)
    # is actually checkable: a process substitution's own exit status is
    # invisible to the reading command and to `set -e`/pipefail alike, which
    # would otherwise leave `files` silently empty and this scan reporting a
    # false "all checked files carry the header" instead of failing closed.
    if ! files_raw="$(git ls-files)"; then
        echo "::error::check-file-headers: \`git ls-files\` itself failed -- is $repo_root a real git work tree? Not treating this as a clean pass." >&2
        exit 1
    fi
    files=()
    if [ -n "$files_raw" ]; then
        mapfile -t files <<<"$files_raw"
    fi
fi

missing=()
missing_spdx=()
for path in "${files[@]}"; do
    [ -f "$path" ] || continue

    # is_excluded()'s case patterns are repository-relative literals (e.g.
    # "services/dhcp/kea-dhcp4.conf"), but an explicit-file invocation keeps
    # the caller's own working directory (see the cwd comment above) rather
    # than repo_root, so $path can be spelled relative to wherever the
    # caller ran from (e.g. "../../services/dhcp/kea-dhcp4.conf" from inside
    # services/dhcp) -- a spelling none of those literals match, which would
    # silently stop excluding a JSON/vendored file the exclusion list exists
    # specifically to protect. Normalize to repo_root-relative for the
    # exclusion check only; $path itself (whatever the caller passed) is
    # still what every read below (head/grep) uses, unchanged. Falls back to
    # the raw $path unchanged when it does not resolve under repo_root at
    # all (e.g. this script's own bats fixtures, isolated throwaway git
    # repos elsewhere on disk that were never meant to be repo_root-relative
    # in the first place).
    exclusion_key="$path"
    if abs_dir=$(cd "$(dirname "$path")" 2>/dev/null && pwd); then
        abs_path="$abs_dir/$(basename "$path")"
        case "$abs_path" in
            "$repo_root"/*) exclusion_key="${abs_path#"$repo_root"/}" ;;
        esac
    fi
    is_excluded "$exclusion_key" && continue

    # The SPDX-License-Identifier line (AG-HDR-008) is a positional
    # requirement, not a bare presence check: "placed immediately after the
    # shebang line (if there is one) and before the lancache-ng (...) header
    # line." A file with the right text buried later in the scanned window
    # (after real content, after the header itself, or inside a string
    # literal that happens to contain it) would satisfy a plain grep across
    # the whole window but does not actually satisfy the rule.
    if ! scanned="$(head -n "$HEADER_SCAN_LINES" "$path")"; then
        echo "::error::check-file-headers: could not read $path" >&2
        exit 1
    fi
    mapfile -t scanned_lines <<<"$scanned"
    if ! grep -qF "$HEADER_TEXT" <<<"$scanned"; then
        missing+=("$path")
    fi
    spdx_line_index=0
    if [[ "${scanned_lines[0]-}" == '#!'* ]]; then
        spdx_line_index=1
    fi
    if [[ "${scanned_lines[$spdx_line_index]-}" != *"$SPDX_TEXT"* ]]; then
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
# it if not" -- not a one-shot repo-wide backfill). A whole-repo scan (no
# path arguments, how build-push.yml's own file-headers/file-headers-hosted
# jobs invoke this script) stays soft/informational: as of this check's own
# introduction, this line exists in only a handful of files, so failing here
# would immediately block every PR on pre-existing files it never touched --
# see AG-HDR-008's own text for the same two-step rollout AG-HDR-009 already
# used for the header line itself.
#
# An explicit-file invocation is different: AG-HDR-008 already requires the
# line on "any file you are otherwise already editing," and this script's
# own top comment has documented an explicit-path mode as "used by CI to
# check just a PR's diff" since before this hard-fail branch existed. A
# diff-scoped CI step passing this script the PR's own changed files closes
# a real, previously-unenforced gap: a file actively being touched could
# still merge without this line, caught only by manual/external review.
if [ "${#missing_spdx[@]}" -gt 0 ]; then
    if [ "$explicit_files" -eq 1 ]; then
        echo "Missing the SPDX-License-Identifier line (AGENTS.md AG-HDR-008) on a file you are touching:" >&2
        printf '  %s\n' "${missing_spdx[@]}" >&2
        exit 1
    fi
    echo "Missing the SPDX-License-Identifier line (AGENTS.md AG-HDR-008) -- not yet enforced repo-wide, backfill in progress:" >&2
    printf '  %s\n' "${missing_spdx[@]}" >&2
fi

echo "All checked files carry the required repository header (or are exempt)."
