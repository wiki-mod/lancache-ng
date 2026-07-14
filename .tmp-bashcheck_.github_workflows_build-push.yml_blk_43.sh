set -euo pipefail

docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -e CARGO_HOME=/tmp/cargo-home \
  -e CARGO_TARGET_DIR=/tmp/target-ui \
  -v "$PWD:/work" \
  -v "$PWD/coverage-ui:/coverage-ui" \
  -w /work \
  "${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}" \
  bash -c 'set -euo pipefail
    cargo tarpaulin \
      --engine llvm \
      --manifest-path services/ui/Cargo.toml \
      --locked \
      --timeout 300 \
      --out json \
      --output-dir /coverage-ui'
