#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Installs one checksum-pinned GitHub CLI binary into a caller-owned temporary
# directory for cryptographic artifact-attestation verification. This avoids
# assuming `gh` exists or is current on a self-hosted runner. The pinned v2.97.0
# release was re-read from cli/cli's official GitHub release API on 2026-08-08;
# GitHub marks that release immutable. The per-architecture SHA-256 values below
# are the release asset digests returned by that same API.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: ci-install-gh-attestation-verifier.sh DEST_DIR" >&2; exit 2; }
dest_dir="$1"
version="2.97.0"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/network-retry.sh"

case "$(uname -m)" in
  x86_64|amd64)
    arch=amd64
    expected_sha256="a2c9b8497e1f85b1ad0dfcb78b5a622e098801b8e461e459e88e1ee12f018112"
    ;;
  aarch64|arm64)
    arch=arm64
    expected_sha256="73ea440ecad9c9e284429997ee6f93577bc6f7bc6fba357ef62c53ad8fb641a5"
    ;;
  *)
    echo "ci-install-gh-attestation-verifier: unsupported architecture $(uname -m)" >&2
    exit 1
    ;;
esac

mkdir -p "$dest_dir"
archive="$dest_dir/gh_${version}_linux_${arch}.tar.gz"
extract_dir="$dest_dir/extract"
rm -rf "$extract_dir"
mkdir -p "$extract_dir"

url="https://github.com/cli/cli/releases/download/v${version}/gh_${version}_linux_${arch}.tar.gz"
network_retry -- \
  curl --fail --location --silent --show-error "$url" -o "$archive"
printf '%s  %s\n' "$expected_sha256" "$archive" | sha256sum -c - >/dev/null

tar -xzf "$archive" -C "$extract_dir"
gh_bin="$extract_dir/gh_${version}_linux_${arch}/bin/gh"
[[ -x "$gh_bin" ]] || { echo "ci-install-gh-attestation-verifier: extracted gh binary missing: $gh_bin" >&2; exit 1; }

actual_version="$("$gh_bin" version | awk 'NR == 1 { print $3 }')"
[[ "$actual_version" == "$version" ]] || {
  echo "ci-install-gh-attestation-verifier: expected gh $version, got ${actual_version:-<empty>}" >&2
  exit 1
}

printf '%s\n' "$gh_bin"
