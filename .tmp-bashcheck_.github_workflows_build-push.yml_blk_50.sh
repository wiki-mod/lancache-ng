set -euo pipefail

docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -e CARGO_HOME=/tmp/cargo-home \
  -v "$PWD:/work:ro" \
  -w /work \
  "${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}" \
  bash -c 'set -euo pipefail
    audit_log="$(mktemp)"
    trap '"'"'rm -f "$audit_log"'"'"' EXIT
    if ! cargo audit --deny warnings --file services/ui/Cargo.lock >"$audit_log" 2>&1; then
      cat "$audit_log"
      exit 1
    fi
    cat "$audit_log"
    if grep -Eiq '"'"'(^|[[:space:]])warning:'"'"' "$audit_log"; then
      echo "::error::cargo-audit emitted warnings."
      exit 1
    fi'

