set -euo pipefail

if [ -n "${CARGO_BUILD_JOBS:-}" ]; then
  case "$CARGO_BUILD_JOBS" in
    ''|*[!0-9]*)
      echo "::error::CARGO_BUILD_JOBS must be a positive integer."
      exit 1
      ;;
  esac
  if [ "$CARGO_BUILD_JOBS" -le 0 ]; then
    echo "::error::CARGO_BUILD_JOBS must be greater than zero."
    exit 1
  fi
  jobs="$CARGO_BUILD_JOBS"
  echo "::notice::Using CARGO_BUILD_JOBS=$jobs from repository variable for Docker builds."
else
  detected_cores="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 2)"
  jobs=$((detected_cores - 2))
  if [ "$jobs" -lt 4 ]; then
    jobs=4
  fi
  echo "::notice::Using CARGO_BUILD_JOBS=$jobs from $detected_cores detected cores for Docker builds."
fi

echo "jobs=$jobs" >> "$GITHUB_OUTPUT"

