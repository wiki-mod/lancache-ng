set -euo pipefail
docker compose down --volumes --remove-orphans || true

# Release the host-local subnet lock the "Reserve a validation
# subnet and start the stack" step above acquired (see that step's
# own comment), so the octet becomes available to the next run
# immediately rather than waiting for this whole job's process tree
# to exit. $VALIDATION_LOCK_HOLDER_PID is only set once that step
# actually reserved a lock -- if it failed before reaching that
# point (e.g. every candidate in range was already locked or in
# use), there is nothing to release.
if [[ -n "${VALIDATION_LOCK_HOLDER_PID:-}" ]]; then
  kill "$VALIDATION_LOCK_HOLDER_PID" 2>/dev/null || true
fi

