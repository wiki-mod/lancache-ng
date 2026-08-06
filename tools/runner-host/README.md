# Runner-host maintenance (`lancache-ci-cleanup`)

Repository-versioned source of truth for the scheduled docker cleanup that runs
on every self-hosted CI runner host (AG-CI-016: any cleanup CI depends on must
live in the repo, PR-reviewable and consistent across all hosts).

## Files
- `lancache-ci-cleanup.sh` — the cleanup script.
- `lancache-ci-cleanup.service` / `lancache-ci-cleanup.timer` — systemd units.
- `lancache-ci-docker-daemon-config.sh` — the go-gated `/etc/docker/daemon.json`
  bounded-build-cache + log-rotation rollout (see below). Separate from the
  cleanup script above: the cleanup script reclaims space on a timer; this
  script bounds how large the build cache is allowed to grow *between* those
  runs in the first place, and (unlike the cleanup script) requires a full
  `dockerd` restart to take effect, which is why it is never wired into a
  timer and is only ever run by hand, one host at a time.

## Deploy (to **every** runner host — 229, 240, 241, 243, …)

> A prior host-local-only copy ran on just a subset of hosts, which is why one
> host accumulated ~40 GB of unreclaimed images/build cache while others were
> fine. Deploy identically to all of them.

```sh
sudo install -m 0755 lancache-ci-cleanup.sh /usr/local/sbin/lancache-ci-cleanup.sh
sudo install -m 0644 lancache-ci-cleanup.service /etc/systemd/system/lancache-ci-cleanup.service
sudo install -m 0644 lancache-ci-cleanup.timer   /etc/systemd/system/lancache-ci-cleanup.timer
sudo systemctl daemon-reload
sudo systemctl enable --now lancache-ci-cleanup.timer
# one manual run + read the log:
sudo systemctl start lancache-ci-cleanup.service
sudo tail -n 40 /var/log/lancache-ci-cleanup.log
```

## What it does (measure → clean → re-measure)
1. records disk usage on `/` before cleanup;
2. reaps **running** containers of specific known leak-prone kinds, each past
   its own age threshold — a container of any of these kinds alive that long
   is an orphaned/hung/crashed CI job whose own teardown step never ran
   (normal runs of any of these complete in minutes, not hours):
   - build-tools-image containers, `REAP_BUILD_TOOLS_AFTER_HOURS` (default 2h)
     — the 2026-07-25 actionlint-deadlock leak class; the SIGKILL guard fixes
     the source, this is defense-in-depth;
   - `lancache-ng-validation-*` containers, `REAP_VALIDATION_AFTER_HOURS`
     (default 2h) — full-setup-deep-validate compose stacks left running
     after a cancelled/crashed job never reached its own `docker compose down`;
   - `buildx_buildkit_builder-*` containers, `REAP_BUILDX_BUILDER_AFTER_HOURS`
     (default 3h) — buildx builders left running after a cancelled/crashed
     job never reached its own `docker buildx rm` (confirmed 2026-07-30: 19
     orphaned containers, mostly these last two kinds, had accumulated on one
     host over 6 days undetected, since neither kind was covered before);

   **The age check above keys on each container's own `.Created` timestamp,
   not `.State.StartedAt` (issue #1095, 2026-08-05 fix).** `StartedAt` is
   reset by any process restart, including the restart Docker's own restart
   manager performs for every non-`"no"`-policy container when the daemon
   itself (re)starts — so a container that leaked days before a host reboot
   looked freshly-started at every check afterward and this reap never
   tripped for it. Confirmed live on runner host `192.168.1.240` (2026-08-05):
   three `lancache-ng-validation-*-standard-passthrough-shim-1` containers
   created 2026-08-03 survived that host's reboot ~14h earlier, and every
   scheduled run since, because each run only ever saw the few-minutes-old
   post-reboot `StartedAt`. `deploy/full-setup/docker-compose.yml`'s
   `standard-passthrough-shim` service no longer carries a restart policy at
   all as of the same fix, closing the root cause for that specific service;
   keying this reap on `.Created` instead closes the general failure class
   for all three kinds above, regardless of whether some future leak-prone
   container happens to carry a restart policy too.
3. reaps `lancache-ng-validation-*` Docker networks left with zero attached
   containers AND older than the same `REAP_VALIDATION_AFTER_HOURS` threshold
   (issue #1095/#932 pattern: an orphaned validation network, not just its
   container, blocks a later run's subnet reservation on the same host —
   `docker rm -f` alone never touches the Compose-created bridge network a
   removed container was attached to). The age check matters, not just the
   zero-attached check: `docker compose up` creates a project's network
   *before* creating or starting its containers, so a zero-attached network
   can legitimately be a stack that is still mid-bringup (issue #834's
   network-teardown-race territory) rather than a leak. Conservative by
   construction: only ever removes a network Docker itself reports as having
   zero attached containers AND past its own age threshold, never a blanket
   sweep;
4. reaps stale per-branch Trivy cache directories (`/var/tmp/lancache-ng-
   trivy-cache/<service>-<arch>-<ref>`, by mtime, default past 1 day) — these
   belong to `build-push.yml`'s `container-scan` job and persist forever for a
   branch that stops being scanned (merged, deleted, abandoned scratch
   branch), since the workflow's own per-push generation-reset only fires on
   that ref's *next* scan, which never happens. Confirmed live, 2026-07-31:
   18-38 GB per host. The 1-day default (maintainer decision, 2026-07-31) is
   deliberately more aggressive than the workflow's own 14-day
   `TRIVY_CACHE_MAX_AGE_DAYS` generation-reset, trading some redundant
   cold-cache Trivy DB re-downloads (job routing across hosts is round-robin,
   not per-branch, so even an active branch can go >24h without a job landing
   on one specific host) for actually bounding disk growth — a 14-day default
   reclaimed nothing in practice at this project's actual branch-churn rate;
5. prunes stopped containers, build cache, unused images, and unreferenced
   anonymous volumes;
6. re-measures and logs the reclaimed delta, so a run that reclaimed nothing is
   visible instead of assumed successful.

Tunables (env): `REAP_BUILD_TOOLS_AFTER_HOURS`, `BUILD_TOOLS_IMAGE_MATCH`,
`REAP_VALIDATION_AFTER_HOURS`, `VALIDATION_NAME_MATCH`,
`REAP_BUILDX_BUILDER_AFTER_HOURS`, `BUILDX_BUILDER_NAME_MATCH`,
`TRIVY_CACHE_ROOT`, `REAP_TRIVY_CACHE_AFTER_DAYS`, `LANCACHE_CI_CLEANUP_LOG`.

## `daemon.json` build-cache-GC + log-rotation rollout (needs maintainer go — a daemon restart)

Bounds the docker build cache and container logs at the daemon level so they
can never grow unbounded between `lancache-ci-cleanup.sh` runs (that script's
own scheduled reap is what caused one host to accumulate ~40 GB before the
2026-07-25 incident, per section 7 of issue #1255). `lancache-ci-docker-
daemon-config.sh` (in this directory) applies these additions safely:

```json
{
  "builder": { "gc": { "enabled": true, "defaultReservedSpace": "20GB" } },
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
```

**Verified against the authoritative dockerd docs (issue #1255, 2026-07-25
comment): neither `builder` nor `log-driver`/`log-opts` is in dockerd's
SIGHUP-reloadable config subset** (only `debug`, `labels`, `live-restore`,
`max-concurrent-*`, `runtimes`, `authorization-plugin`, registries,
`shutdown-timeout`, and `features` are) — applying either one requires a full
`dockerd` restart, which drops every container currently running on that
host, including any in-flight CI job. There is no way to avoid that
disruption with a reload; the only lever is *when* the restart happens.

**Key-name correction (2026-07-31, AG-VAL-023):** the original draft above
(PR #1251) used `builder.gc.defaultKeepStorage`. Current moby/moby
documentation and the `BuilderGCConfig` Go struct
(`daemon/config/builder.go`) show `defaultReservedSpace` /
`defaultMaxUsedSpace` / `defaultMinFreeSpace` instead, which raised a real
risk this whole rollout would silently do nothing: dockerd's JSON parser
drops any unrecognized key without error (confirmed empirically —
`dockerd --validate` against a config with a deliberately nonsense key also
reports "configuration OK", so a clean validate result alone never proved
the key was real). Verified directly against moby's actual
`BuilderGCConfig.UnmarshalJSON` source **and** against the literal compiled
`/usr/bin/dockerd` binary's own embedded struct strings on a real runner
host (`strings $(which dockerd) | grep -i keepstorage`, no restart needed):
`defaultKeepStorage` **is** still honored, via a deliberate backward-
compatibility shim ("Deprecated option is now equivalent to
DefaultReservedSpace") that maps it onto `DefaultReservedSpace` whenever the
latter is empty — so the original rollout was never actually broken. This
repo's tooling now emits the current, non-deprecated `defaultReservedSpace`
key going forward rather than relying on a documented-deprecated alias.

**Verified real per-host state (direct SSH inspection, 2026-07-31):** three
of the four runner hosts (`.229`, `.240`, `.241`) already carry a real
`/etc/docker/daemon.json` with `max-concurrent-downloads`/`-uploads` and
`storage-driver` set; the fourth (`.243`) has no `daemon.json` at all (pure
Docker defaults, confirmed by an empty `/etc/docker/` directory). The script
below merges into whichever of these is actually present on a given host
rather than assuming a fixed starting point — it deep-merges its additions
via `jq`'s `*` operator, so a host's existing keys are always preserved.

### Rollout procedure (one host at a time, during an agreed quiet window)

The script defaults to safe, non-destructive modes; only its `restart` mode
is disruptive, and that mode refuses to run unless explicitly confirmed.

```sh
# 1. Copy the script to the target host (or `git pull` this repo there).
scp tools/runner-host/lancache-ci-docker-daemon-config.sh <host>:/tmp/

# 2. On the host: read-only preview of what would change. Writes nothing.
sudo bash /tmp/lancache-ci-docker-daemon-config.sh check

# 3. Write the merged config to a staged file for manual review (still does
#    not touch the live /etc/docker/daemon.json).
sudo bash /tmp/lancache-ci-docker-daemon-config.sh stage
cat /etc/docker/daemon.json.staged   # review

# 4. Back up the live file and install the merged config as the new live
#    file. Does NOT restart dockerd -- the new settings are inert until step 5.
sudo bash /tmp/lancache-ci-docker-daemon-config.sh apply

# 5. THE DISRUPTIVE STEP. Only during the agreed quiet window, one host at a
#    time: restarts dockerd (stopping every container currently running on
#    this host), confirms `docker info` reports the new logging driver (the
#    one setting `docker info` actually exposes in this Docker version --
#    the builder GC bound itself is not queryable that way, see the script's
#    own comment), and reads back the live config file dockerd just loaded.
#    Requires an explicit confirmation env var so it can never fire from a
#    copy-pasted one-liner without a deliberate extra step:
sudo CONFIRM_DOCKERD_RESTART=yes bash /tmp/lancache-ci-docker-daemon-config.sh restart

# 6. Confirm the runner picks up CI jobs normally again before moving on to
#    the next host. Repeat steps 1-6 per host -- never restart all four at
#    once.
```

If step 5 fails verification or the host misbehaves afterward, restore from
the timestamped backup step 4 created (`/etc/docker/daemon.json.bak.<timestamp>`)
and restart `docker.service` again.

Env overrides (same tunable-via-env style as `lancache-ci-cleanup.sh`):
`DAEMON_JSON` (default `/etc/docker/daemon.json`), `BUILDER_GC_RESERVED_SPACE`
(default `20GB`), `LOG_MAX_SIZE` (default `10m`), `LOG_MAX_FILE` (default `3`).

**Status as of 2026-07-31: the script above is prepared and verified (`bash
-n`, `shellcheck`, a 6-test bats suite for the merge logic, and a functional
`check`/`stage`/`apply` smoke test against a copy of each real host's actual
`daemon.json`, all run in the pinned build-tools container / on-host, never
against the live file). `check` and `apply` both also run dockerd's own
`--validate` preflight against the computed config before anything is
written or restarted. The actual `restart` step has deliberately NOT been
run against any real runner host — that remains a maintainer-scheduled
action for an agreed quiet window, one host at a time**, per issue #1255.
