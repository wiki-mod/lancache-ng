#!/bin/bash
# lancache-ng — https://github.com/wiki-mod/lancache-ng
# Runs Docker-based Rust quality checks for the Admin UI without requiring host Rust tooling.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
UI_MANIFEST="services/ui/Cargo.toml"
# Intentional developer/check default: use the repository build-tools image.
# That image is the contract for local and CI-style UI checks and preinstalls
# rustfmt, clippy, sccache, and PATH smoke tests. This is separate from pinned
# production Dockerfiles.
RUST_IMAGE="${RUST_IMAGE:-ghcr.io/wiki-mod/lancache-ng/build-tools:latest}"
NETWORK_NAME=""
REDIS_CONTAINER=""
REDIS_URL="${SCCACHE_REDIS_URL:-}"
REDIS_URL_EXPLICIT=0
RUN_FMT_CHECK=1
RUN_CHECK=1
RUN_CLIPPY=1
RUN_TEST=1
RUN_BUILD=1
ENABLE_SCCACHE=0
START_REDIS=0

usage() {
  cat <<EOF
Usage: $0 [options]

Run local Docker-based Rust checks for the Admin UI without requiring host rustc.

Options:
  --manifest <path>         Cargo manifest path (default: services/ui/Cargo.toml)
  --rust-image <image>      Rust Docker image to use (default: ghcr.io/wiki-mod/lancache-ng/build-tools:latest)
  --fmt                     Run cargo fmt --all -- --check (default)
  --no-fmt                  Skip cargo fmt
  --check                   Run cargo check (default)
  --no-check                Skip cargo check
  --clippy                  Run cargo clippy -- -D warnings (default)
  --no-clippy               Skip cargo clippy
  --no-test                 Skip cargo test
  --no-build                Skip cargo build --locked --release
  --sccache                 Enable sccache for rustc invocation
  --sccache-redis <url>     Set SCCACHE_REDIS URL for cache sharing
  --with-redis              Start a temporary Redis container for sccache
  -h, --help                Show this help

Examples:
  $0
  $0 --rust-image rust:latest --no-fmt --no-clippy
  SCCACHE_REDIS_URL=redis://<redis-host>:6379/0 $0 --sccache
  $0 --with-redis --sccache

Notes:
  The build-tools image is the default contract for local and CI-style checks.
  Custom images must already include the Rust tools needed by the requested
  checks; plain rust:latest needs --no-fmt --no-clippy unless you prepare an
  image with rustfmt and clippy installed.
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${REDIS_CONTAINER}" ]]; then
    docker rm -f "${REDIS_CONTAINER}" >/dev/null 2>&1 || true
  fi

  if [[ -n "${NETWORK_NAME}" ]]; then
    docker network rm "${NETWORK_NAME}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)
      shift
      if [[ $# -eq 0 || "$1" == --* ]]; then
        fail "--manifest requires a value"
      fi
      UI_MANIFEST="${1}"
      shift
      ;;
    --rust-image)
      shift
      if [[ $# -eq 0 || "$1" == --* ]]; then
        fail "--rust-image requires a value"
      fi
      RUST_IMAGE="${1}"
      shift
      ;;
    --fmt)
      RUN_FMT_CHECK=1
      shift
      ;;
    --no-fmt)
      RUN_FMT_CHECK=0
      shift
      ;;
    --check)
      RUN_CHECK=1
      shift
      ;;
    --no-check)
      RUN_CHECK=0
      shift
      ;;
    --clippy)
      RUN_CLIPPY=1
      shift
      ;;
    --no-clippy)
      RUN_CLIPPY=0
      shift
      ;;
    --no-test)
      RUN_TEST=0
      shift
      ;;
    --no-build)
      RUN_BUILD=0
      shift
      ;;
    --sccache)
      ENABLE_SCCACHE=1
      shift
      ;;
    --sccache-redis)
      shift
      if [[ $# -eq 0 || "$1" == --* ]]; then
        fail "--sccache-redis requires a value"
      fi
      REDIS_URL="${1:-}"
      REDIS_URL_EXPLICIT=1
      shift
      ;;
    --with-redis)
      START_REDIS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "Unknown argument: $1"
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  fail "docker is not installed or not on PATH"
fi

UI_MANIFEST_ABS="${UI_MANIFEST}"
if [[ "${UI_MANIFEST}" != /* ]]; then
  UI_MANIFEST_ABS="${ROOT_DIR}/${UI_MANIFEST}"
fi

if [[ ! -f "${UI_MANIFEST_ABS}" ]]; then
  fail "Cannot find manifest at ${UI_MANIFEST}"
fi

if [[ ${RUN_FMT_CHECK} -eq 0 && ${RUN_CHECK} -eq 0 && ${RUN_CLIPPY} -eq 0 && ${RUN_TEST} -eq 0 && ${RUN_BUILD} -eq 0 ]]; then
  fail "No checks selected. Enable at least one with --no- flags removed"
fi

if [[ ${ENABLE_SCCACHE} -eq 0 && ${REDIS_URL_EXPLICIT} -eq 1 ]]; then
  fail "--sccache-redis requires --sccache"
fi

if [[ ${START_REDIS} -eq 1 && ${ENABLE_SCCACHE} -eq 0 ]]; then
  fail "--with-redis requires --sccache"
fi

if [[ ${ENABLE_SCCACHE} -eq 1 && ${START_REDIS} -eq 0 && -z "${REDIS_URL}" ]]; then
  fail "--sccache requires Redis. Use --sccache-redis <url> or --with-redis"
fi

if [[ ${ENABLE_SCCACHE} -eq 1 && ${START_REDIS} -eq 1 ]]; then
  SUFFIX="${RANDOM}"
  NETWORK_NAME="lancache-ui-rust-sccache-${SUFFIX}"
  REDIS_CONTAINER="lancache-ui-rust-sccache-${SUFFIX}"
  docker network create "${NETWORK_NAME}" >/dev/null
  REDIS_URL="redis://$REDIS_CONTAINER:6379/0"
  docker run -d --name "${REDIS_CONTAINER}" --network "${NETWORK_NAME}" redis:7-alpine \
    --save "" --appendonly no >/dev/null
fi

if [[ "${UI_MANIFEST_ABS}" == "${ROOT_DIR}"/* ]]; then
  UI_MANIFEST="${UI_MANIFEST_ABS#"$ROOT_DIR"/}"
else
  fail "Manifest path ${UI_MANIFEST} is outside the current repository root"
fi

DOCKER_ENVS=(
  -e CARGO_HOME=/tmp/cargo
  -e CARGO_TARGET_DIR=/tmp/target
  -e PATH=/tmp/cargo-tools/bin:/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
)

if [[ ${ENABLE_SCCACHE} -eq 1 ]]; then
  DOCKER_ENVS+=( -e RUSTC_WRAPPER=sccache )
  DOCKER_ENVS+=( -e SCCACHE_DIR=/tmp/sccache )
  DOCKER_ENVS+=( -e SCCACHE_REDIS_KEY_PREFIX=lancache-ui )
  DOCKER_ENVS+=( -e CARGO_INSTALL_ROOT=/tmp/cargo-tools )
  if [[ -n "${REDIS_URL}" ]]; then
    DOCKER_ENVS+=( -e SCCACHE_REDIS="${REDIS_URL}" )
  fi
fi

DOCKER_RUN_ARGS=(
  run --rm
  -v "${ROOT_DIR}:/workspace:ro"
  -w /workspace
  "${DOCKER_ENVS[@]}"
  -e "UI_MANIFEST=${UI_MANIFEST}"
)

if [[ -n "${NETWORK_NAME}" ]]; then
  DOCKER_RUN_ARGS+=( --network "${NETWORK_NAME}" )
fi

CONTAINER_CMD=$'set -euo pipefail\n'
CONTAINER_CMD+=$'require_tool() {\n'
CONTAINER_CMD+=$'  local tool="$1"\n'
CONTAINER_CMD+=$'  local message="$2"\n'
CONTAINER_CMD+=$'  if ! command -v "$tool" >/dev/null 2>&1; then\n'
CONTAINER_CMD+=$'    echo "Error: ${message}" >&2\n'
CONTAINER_CMD+=$'    exit 1\n'
CONTAINER_CMD+=$'  fi\n'
CONTAINER_CMD+=$'}\n'
CONTAINER_CMD+=$'require_cargo_subcommand() {\n'
CONTAINER_CMD+=$'  local subcommand="$1"\n'
CONTAINER_CMD+=$'  local message="$2"\n'
CONTAINER_CMD+=$'  if ! cargo "$subcommand" --version >/dev/null 2>&1; then\n'
CONTAINER_CMD+=$'    echo "Error: ${message}" >&2\n'
CONTAINER_CMD+=$'    exit 1\n'
CONTAINER_CMD+=$'  fi\n'
CONTAINER_CMD+=$'}\n'
CONTAINER_CMD+=$'require_tool cargo "cargo is required. Use the build-tools image or provide an image that already includes cargo."\n'
CONTAINER_CMD+=$'require_tool rustc "rustc is required. Use the build-tools image or provide an image that already includes rustc."\n'
if [[ ${ENABLE_SCCACHE} -eq 1 ]]; then
  CONTAINER_CMD+=$'require_tool sccache "sccache is required when --sccache is enabled. Use the build-tools image or provide an image that already includes sccache."\n'
fi
CONTAINER_CMD+=$'cargo --version\n'
CONTAINER_CMD+=$'rustc --version\n'
if [[ ${RUN_FMT_CHECK} -eq 1 ]]; then
  CONTAINER_CMD+=$'require_cargo_subcommand fmt "rustfmt is required for cargo fmt. Use the build-tools image or provide an image that already includes rustfmt."\n'
fi
if [[ ${RUN_CLIPPY} -eq 1 ]]; then
  CONTAINER_CMD+=$'require_cargo_subcommand clippy "clippy is required for cargo clippy. Use the build-tools image or provide an image that already includes clippy."\n'
fi
CONTAINER_CMD+=$'\n'

if [[ ${RUN_FMT_CHECK} -eq 1 ]]; then
  CONTAINER_CMD+="cargo fmt --all --manifest-path ${UI_MANIFEST} -- --check"$'\n'
fi
if [[ ${RUN_CHECK} -eq 1 ]]; then
  CONTAINER_CMD+="cargo check --locked --manifest-path ${UI_MANIFEST}"$'\n'
fi
if [[ ${RUN_CLIPPY} -eq 1 ]]; then
  CONTAINER_CMD+="cargo clippy --locked --manifest-path ${UI_MANIFEST} -- -D warnings"$'\n'
fi
if [[ ${RUN_TEST} -eq 1 ]]; then
  CONTAINER_CMD+="cargo test --locked --manifest-path ${UI_MANIFEST}"$'\n'
fi
if [[ ${RUN_BUILD} -eq 1 ]]; then
  CONTAINER_CMD+="cargo build --locked --release --manifest-path ${UI_MANIFEST}"$'\n'
fi

echo "Running local Rust UI checks in ${RUST_IMAGE} ..."
if [[ ${ENABLE_SCCACHE} -eq 1 && -n "${REDIS_URL}" ]]; then
  echo "SCCACHE_REDIS is configured for this run."
fi

docker "${DOCKER_RUN_ARGS[@]}" "${RUST_IMAGE}" bash -c "${CONTAINER_CMD}"
echo "Rust UI checks completed."
