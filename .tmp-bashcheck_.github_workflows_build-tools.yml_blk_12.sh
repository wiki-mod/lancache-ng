set -euo pipefail

docker run --rm --platform linux/arm64 "${BUILD_TOOLS_SCAN_IMAGE_ARM64:?BUILD_TOOLS_SCAN_IMAGE_ARM64 is required}" bash -c '
set -euo pipefail

required_tools=(
  actionlint
  bash
  bats
  cargo
  cargo-audit
  cargo-tarpaulin
  clippy-driver
  dig
  distcc
  distcc-pump
  docker
  envsubst
  jq
  rustc
  rustfmt
  sccache
  shellspec
  shellcheck
)

for tool in "${required_tools[@]}"; do
  command -v "$tool" >/dev/null
done

cargo --version
cargo audit --version
cargo-audit --version
cargo tarpaulin --version
cargo-tarpaulin --version
sccache --version
actionlint --version
bats --version
shellspec --version
shellcheck --version
distcc --version
distcc-pump --help >/dev/null
docker --version
docker compose version
'

