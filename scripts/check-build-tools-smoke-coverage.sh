#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Standing guard for issues #790/#791 (#822 Pattern G): keeps
# scripts/select-build-tools-image.sh's smoke_test_image() required-tools
# list from silently drifting behind tools/build-tools/Dockerfile's own
# final verification list. The Dockerfile installs and build-time-verifies a
# tool; the smoke test -- which runs against the *published/resolved* image
# at consumption time -- is supposed to re-verify the consumer-relevant
# subset. Repeatedly it did not: #775 (missing dhclient/expect/tcpdump/
# scapy), #787 (missing docker buildx), #790 (missing bats/shellspec), #791
# (docker buildx again) were all "a tool real consumers need is installed but
# the smoke test never checked it," each caught reactively after it broke or
# only during an audit.
#
# WHY A GUARD RATHER THAN DERIVING THE SMOKE LIST FROM THE DOCKERFILE:
# #822 Pattern G suggests generating smoke_test_image()'s list from the
# Dockerfile's list so the two "cannot diverge." A naive derive is not
# viable: the Dockerfile's final `required_tools=()` array is a build-time
# self-check that verifies *everything* the image installs -- including
# cargo-tarpaulin (deliberately opt-in for the smoke test via
# EXTRA_REQUIRED_TOOLS, not a global requirement) and ~40 standard coreutils
# / build-toolchain binaries (cc, g++, make, git, sed, tar, ...) that no
# consumer simulation script invokes directly and that the smoke test has
# never gated on. The two lists genuinely serve different purposes. So
# instead of forcing that superset into the runtime smoke test, this guard
# gives the same "cannot silently diverge" property the derive would: every
# tool the Dockerfile verifies must be EITHER covered by the smoke test OR
# named in this script's explicit, categorized exclusion list below. A future
# tool added to the Dockerfile that a consumer needs therefore cannot slip
# past the smoke test unnoticed -- it fails this guard until someone either
# adds it to the smoke list or makes a conscious, reviewable decision to
# exclude it. This is the scripts/check-*.sh + CI-job template #822 Pattern H
# names for closing exactly this class (cf. check-workflow-service-lists.sh,
# which cross-checks two hand-maintained lists in different files the same
# way).
#
# SCOPE: this guard checks one direction only -- that nothing the Dockerfile
# verifies is missing from the smoke test without an explicit exclusion. It
# does not assert the reverse (a smoke-test entry the Dockerfile does not
# install), because the smoke test legitimately verifies capabilities the
# Dockerfile expresses differently (e.g. scapy via `python3 -c import
# scapy.all`, not a `required_tools` entry). The Pattern G failure mode is
# always the missing-from-smoke direction.
#
# Deliberately plain bash + a single awk array-extractor (no YAML/Dockerfile
# parser, no non-shell runtime -- Rule-Ref: AG-REL-001), matching the sibling
# guards.
#
# Accepts an optional repo_root argument (defaults to this script's own repo)
# so tests/bats/check_build_tools_smoke_coverage.bats can point it at a
# fixture tree instead of depending on the real repository.
set -euo pipefail

repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$repo_root"

dockerfile="tools/build-tools/Dockerfile"
smoke_script="scripts/select-build-tools-image.sh"

for f in "$dockerfile" "$smoke_script"; do
  if [ ! -f "$f" ]; then
    printf '::error::check-build-tools-smoke-coverage: expected file not found: %s\n' "$f" >&2
    exit 1
  fi
done

# Tools the Dockerfile's final verification array lists but that the smoke
# test intentionally does NOT re-verify at consumption time. Every entry here
# is a conscious "not part of the smoke test's consumer-facing contract"
# decision; adding a Dockerfile tool to this list instead of to the smoke
# test must be a reviewed choice, which is the whole point of failing closed
# on anything that is in neither.
#   - Opt-in: verified only when a caller sets EXTRA_REQUIRED_TOOLS (the
#     coverage job does this for cargo-tarpaulin), never globally.
#   - Build toolchain: needed to *build* Rust/C-dependency crates, driven by
#     cargo, not invoked directly by any consumer simulation script; the
#     smoke test has never gated on them.
#   - Base utilities: standard coreutils / util-linux / base-image binaries
#     present in any Debian base, so their presence is not a meaningful "was
#     this image built correctly" signal the way a specialized tool is.
EXCLUDED_TOOLS=(
  # Opt-in (EXTRA_REQUIRED_TOOLS)
  cargo-tarpaulin
  # Build toolchain
  ar ranlib cc c++ g++ clang ld.lld make cmake pkg-config git gpg
  # Base utilities (coreutils / util-linux / base image)
  awk basename cat chgrp chmod chown cp curl dirname dpkg find flock getent
  grep gzip install mkdir mktemp mv printf ps rm sed sha256sum sort tar tee
  test timeout xargs xz
)

# Multi-word capabilities the Dockerfile verifies via a subcommand invocation
# (`docker buildx version`, `docker compose version`) rather than a
# `required_tools` array entry -- so the array comparison below never sees
# them. Each is enforced separately: if the Dockerfile verifies it, the smoke
# script must too. #791 is exactly this case for `docker buildx`.
SPECIAL_CAPABILITIES=(
  "docker buildx"
  "docker compose"
)

failures=0
fail() {
  printf '::error::%s\n' "$1" >&2
  failures=$((failures + 1))
}

# extract_required_tools <file>
# Prints one tool name per line from the first `required_tools=( ... )` array
# in <file>. Strips line-continuation backslashes (the Dockerfile array uses
# them; the smoke array does not -- harmless either way) and skips blank and
# comment lines.
extract_required_tools() {
  awk '
    /required_tools=\(/ { in_arr = 1; next }
    in_arr && /\)/ { in_arr = 0 }
    in_arr {
      gsub(/\\/, "")
      gsub(/^[ \t]+|[ \t]+$/, "")
      if ($0 != "" && $0 !~ /^#/) print
    }
  ' "$1"
}

mapfile -t dockerfile_tools < <(extract_required_tools "$dockerfile" | sort -u)
mapfile -t smoke_tools < <(extract_required_tools "$smoke_script" | sort -u)

if [ "${#dockerfile_tools[@]}" -eq 0 ]; then
  fail "could not extract any required_tools from $dockerfile -- refusing to run a vacuous check (parser bug or the array was renamed/refactored)."
fi
if [ "${#smoke_tools[@]}" -eq 0 ]; then
  fail "could not extract any required_tools from $smoke_script's smoke_test_image() -- refusing to run a vacuous check (parser bug or the array was renamed/refactored)."
fi
if [ "$failures" -gt 0 ]; then
  exit 1
fi

in_list() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

# Direction that matters (Pattern G): every Dockerfile-verified tool must be
# covered by the smoke test or explicitly excluded.
for tool in "${dockerfile_tools[@]}"; do
  if in_list "$tool" "${smoke_tools[@]}"; then
    continue
  fi
  if in_list "$tool" "${EXCLUDED_TOOLS[@]}"; then
    continue
  fi
  fail "'$tool' is installed and verified in $dockerfile but is neither checked by smoke_test_image() in $smoke_script nor listed in this guard's EXCLUDED_TOOLS. Add it to the smoke test's required_tools (if a consumer needs it verified in the published image) or to EXCLUDED_TOOLS with a category (if it is a build-only/base utility). See issues #790/#791 / #822 Pattern G."
done

# Multi-word capabilities the array comparison cannot see. Matched on the
# actual `<cap> version` *invocation*, not the bare capability name, so a
# comment that merely mentions the capability (this guard's own smoke-test
# edits explain buildx in prose) is never mistaken for the real check.
for cap in "${SPECIAL_CAPABILITIES[@]}"; do
  if grep -qF "$cap version" "$dockerfile"; then
    if ! grep -qF "$cap version" "$smoke_script"; then
      fail "the build-tools Dockerfile verifies '$cap version' but smoke_test_image() in $smoke_script does not -- a consumer of the published image would not catch its absence. Add a '$cap version' check to the smoke test (see issue #791 for the docker buildx case / #822 Pattern G)."
    fi
  fi
done

if [ "$failures" -gt 0 ]; then
  printf '::error::check-build-tools-smoke-coverage: %d tool(s) verified by the build-tools Dockerfile are not covered by the smoke test (see issues #790/#791 / #822 Pattern G).\n' "$failures" >&2
  exit 1
fi

printf 'check-build-tools-smoke-coverage: OK (every build-tools Dockerfile-verified tool is covered by smoke_test_image() or explicitly excluded).\n'
