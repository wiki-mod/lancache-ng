# Runner-host maintenance (`lancache-ci-cleanup`)

Repository-versioned source of truth for the scheduled docker cleanup that runs
on every self-hosted CI runner host (AG-CI-016: any cleanup CI depends on must
live in the repo, PR-reviewable and consistent across all hosts).

## Files
- `lancache-ci-cleanup.sh` — the cleanup script.
- `lancache-ci-cleanup.service` / `lancache-ci-cleanup.timer` — systemd units.

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
3. prunes stopped containers, build cache, unused images, and unreferenced
   anonymous volumes;
4. re-measures and logs the reclaimed delta, so a run that reclaimed nothing is
   visible instead of assumed successful.

Tunables (env): `REAP_BUILD_TOOLS_AFTER_HOURS`, `BUILD_TOOLS_IMAGE_MATCH`,
`REAP_VALIDATION_AFTER_HOURS`, `VALIDATION_NAME_MATCH`,
`REAP_BUILDX_BUILDER_AFTER_HOURS`, `BUILDX_BUILDER_NAME_MATCH`,
`LANCACHE_CI_CLEANUP_LOG`.

## Related, not done here (needs maintainer go — a daemon restart)
Bound the docker build cache and container logs at the daemon level so they can
never grow unbounded between cleanups. Proposed `/etc/docker/daemon.json`
additions (overlay2 is already active):

```json
{
  "builder": { "gc": { "enabled": true, "defaultKeepStorage": "20GB" } },
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
```
