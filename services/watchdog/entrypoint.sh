#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# Generic container entrypoint wrapper: launches retention.sh (#842) as a
# supervised background process, then exec's into watchdog.sh.
#
# This exists as a single shared wrapper INSIDE the image, rather than
# duplicating the retention-launch logic in every deployment profile's own
# compose `command:` override, because this project ships three separate
# compose files with their own `watchdog:` service block (`deploy/prod`,
# `deploy/quickstart`, `deploy/full-setup`) and only two of them (`prod`,
# `quickstart`) override `entrypoint`/`command` at all -- `full-setup`
# deliberately runs this image's plain default `ENTRYPOINT` with no
# override (see that compose file's `watchdog:` service). Putting the
# retention-launch logic only in `prod`'s command override (an earlier,
# incomplete version of this change) would have left `quickstart` unaffected
# and `full-setup`'s validation stack never exercising retention.sh at
# all -- exactly the kind of silent per-profile gap AG-VAL-027 warns about
# for a new service, applied here to a new *process* within an existing
# service instead. Making this the image's own `ENTRYPOINT` means every
# profile gets retention.sh automatically, including any future one, with
# nothing extra for a new compose file to remember.
#
# Retention's own stdout/stderr is tee'd into its own log file
# (`retention.log`, mirroring watchdog.sh's own `watchdog.log` file the
# calling compose `command:` blocks already tee into) while still also
# reaching this process's own stdout/stderr -- so it shows up in `docker
# logs` either way, and additionally lands in `watchdog.log` too on any
# profile that further wraps this script's own output in an outer `tee`
# (prod/quickstart's command overrides do; full-setup's plain ENTRYPOINT
# invocation does not, and that is fine -- `docker logs` alone still shows
# it there).
set -uo pipefail

mkdir -p /var/log/lancache-watchdog

# Supervised background loop (#842): a bug or crash in destructive
# file-retention logic must never take down container health monitoring,
# which is exactly what would happen if retention.sh ran inline in
# watchdog.sh's own process instead of here. The `|| ...; sleep 5` respawn
# means a crash degrades to "retention paused for 5s, logged, and resumed,"
# not "retention silently stops forever" -- nothing about retention.sh's own
# liveness is otherwise reflected in this container's Docker healthcheck
# (that only watches watchdog.sh's status.json freshness, see
# healthcheck.sh), so an unsupervised crash here would be invisible.
(
    while true; do
        /retention.sh || echo "[retention-supervisor] retention.sh exited ($?), respawning in 5s" >&2
        sleep 5
    done
) > >(tee -a /var/log/lancache-watchdog/retention.log) 2>&1 &

exec /watchdog.sh
