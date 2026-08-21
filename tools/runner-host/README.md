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
- `lancache-ci-runner-clone-init.sh` — one-time bootstrap for a newly
  provisioned or disk-cloned runner host, up to (but never including) actual
  GitHub registration (issue #1622). See its own header for the full
  background and its `--help` for the `check`/`clean`/`host-prep`/
  `runner-fetch` modes. In short: a host in this fleet added by cloning an
  existing host's disk carries that source host's own `.runner`/
  `.credentials`/`.credentials_rsaparams` (private key material for an
  identity already registered elsewhere) and multi-GB leftover imaging
  archives under `/opt` — confirmed real on `.81` during that issue's
  investigation. `check` detects this (and baseline sudoers/docker-group/
  hooks/timer state) read-only; `clean` removes only what `check` already
  flagged as foreign, gated on `CONFIRM_CLEAN=yes`; `host-prep` installs the
  sudoers NOPASSWD drop-in, docker group membership, the
  `/opt/lancache-ci-hooks/{pre,post}-job-cleanup.sh` pair (host-local, not
  repo-tracked, same as they already are on every existing runner host), and
  this directory's own cleanup timer; `runner-fetch` downloads, verifies
  (against the GitHub Releases API asset digest), and extracts a specific
  actions-runner release directly into a target instance directory. Actual
  `config.sh` registration, `svc.sh install`, and starting the resulting
  systemd service remain deliberate, separate, human-run steps — this script
  never performs any of them, and never touches `/etc/docker/daemon.json`
  (see the `lancache-ci-docker-daemon-config.sh` rollout above for that,
  including this fleet's LAN-proxy block).

  **Runner naming (maintainer decision, issue #1622, 2026-08-21):** for
  hosts in the `.80`-and-up fleet, `config.sh --name` must be the host's
  exact hostname (e.g. `gh-lancache-heavy-30-84` on that host) — never the
  pre-existing `229`/`240`/`241`/`243` fleet's letter-prefix scheme
  (`a-lancache-runner-240-1` etc.), which is specific to those older hosts
  and must not be copied onto a new one. `runner-fetch`'s own final output
  states this explicitly, including the exact value for the host it just
  ran on.

  **`purge-pve-check`/`purge-pve` (issue #1622, 2026-08-21):** every host
  in the `.80`-and-up fleet's template carries a complete, running Proxmox
  VE 9.2 management stack inside the guest itself (pveproxy, pve-cluster/
  pmxcfs, pve-ha-manager including its watchdog-mux, pve-firewall,
  proxmox-firewall, corosync, spiceproxy, qmeventd, pve-lxc-syscalld,
  pve-qemu-kvm, …) — almost certainly because the template disk was cloned
  from an actual Proxmox host. Measured on host `.81`: ~1.8-1.9 GB RSS held
  permanently by these processes alone, a significant fraction of a light
  host's 3.8 GB. `purge-pve-check` is a read-only inventory (installed
  packages, active services, `/etc/pve` dependents, current RSS held, a
  simulated purge preview); `purge-pve` (gated on `CONFIRM_PURGE_PVE=yes`)
  stops the services and purges the packages. **Permanently, deliberately
  excludes** `proxmox-kernel-*`/`proxmox-default-kernel`/`pve-firmware`/
  `pve-edk2-firmware*` — this fleet has no regular Debian kernel installed
  at all, only the Proxmox-branded ones, so purging those would leave a
  host unbootable; `purge-pve` re-simulates and fails closed if a
  kernel/firmware package would ever be touched. Before running against a
  host whose runner service is live, check GitHub's busy status and stop
  that service first; a real reboot test afterward is strongly
  recommended (verified end-to-end on host `.81` only, issue #1622: it came
  back on the identical `uname -r`, with docker/networking/the runner
  service all working -- this is not yet confirmed across the rest of the
  `.80`-and-up fleet, run `purge-pve` and its own reboot test per host
  before treating any other host as proven).

  **`sccache-check`/`sccache-fetch` (issue #1619/#1622, 2026-08-21):**
  `.github/actions/configure-rust-sccache` — used by every trusted Rust CI
  job routed to `lancache-heavy` (confirmed nowhere on `lancache-light`) —
  fails a real job outright with "sccache is required on the runner when
  Redis-backed sccache or sccache-dist is configured" if the `sccache`
  binary isn't on the runner's PATH. New heavy hosts never got this
  installed as part of host-prep. **Not `apt install sccache`** (Debian's
  packaged version has no Redis support) **and not rebuilt from source on
  each new host** — this project's sccache needs
  `--features redis,dist-client` (see `tools/build-tools/Dockerfile`'s own
  `cargo install sccache --no-default-features --features redis,dist-
  client`), and every existing heavy host's client-side sccache tooling
  was itself originally installed by copying the built binaries
  host-to-host at identical paths, not by rebuilding — confirmed
  directly on `lancache-240`. `sccache-check` (read-only) reports whether
  the tooling is present and executes the binary as the configured runner
  account; the scheduler URL and auth token are supplied only by
  each CI job's secret-backed `SCCACHE_CONF`. `sccache-fetch <dir>` installs
  the `sccache` and `sccache-dist` binaries already staged at `<dir>` on the
  host (copy them from a known-working heavy host such as `lancache-240`
  first — this mode does not build or download anything itself).
  `host-prep` reminds about this on any host whose hostname
  contains "heavy", since it cannot do the host-to-host copy unattended.
  Deliberately client-role only — `sccache-dist-server.service` (accepting
  distributed builds from other clients) needs a fresh, server-specific
  auth token issued by whoever administers the scheduler, so its config is
  never safely copyable between hosts, the same reason the client's own
  scheduler/auth configuration is no longer host-copied either (see above);
  standing up a new dist-server remains a separate, additional capacity
  decision.

### Full per-host rollout procedure (new or disk-cloned host)

The exact ordered sequence `lancache-ci-runner-clone-init.sh`'s own header
promises "the full per-host rollout procedure" for. Run each step from the
host itself (`bash lancache-ci-runner-clone-init.sh <mode> ...`), not via
`./lancache-ci-runner-clone-init.sh` (see the script's own usage comment).

```sh
# 1. Read-only survey: clone-artifact findings, docker/sudoers/group state.
bash lancache-ci-runner-clone-init.sh check

# 2. If check found foreign runner identities/archives, remove ONLY those
#    (re-verified immediately before each removal):
CONFIRM_CLEAN=yes bash lancache-ci-runner-clone-init.sh clean

# 3. Broader de-clone sweep: shell history, known_hosts, foreign
#    authorized_keys, stale journal/machine-id dirs, orphaned /home dirs,
#    template-authoring scripts, apt/dpkg history mentions. Read-only first:
bash lancache-ci-runner-clone-init.sh full-reset-check
CONFIRM_FULL_RESET=yes bash lancache-ci-runner-clone-init.sh full-reset-clean

# 4. If full-reset-check flagged a mismatched/leftover clone hostname,
#    apply the maintainer-confirmed correct one (see "Runner naming" above
#    for this fleet's naming convention):
sudo bash lancache-ci-runner-clone-init.sh set-hostname <correct-hostname>

# 5. If this is a Proxmox-templated VM (the `.80`-and-up fleet), remove the
#    accidentally-included nested PVE management stack -- read-only survey
#    first, see the dedicated section above for the destructive step and
#    its kernel/firmware exclusions:
bash lancache-ci-runner-clone-init.sh purge-pve-check
CONFIRM_PURGE_PVE=yes bash lancache-ci-runner-clone-init.sh purge-pve

# 6. Idempotent host setup: sudoers NOPASSWD drop-in, docker group, /opt
#    ownership convergence, the pre/post-job cleanup hooks, and this
#    directory's own cleanup timer. NOT non-disruptive -- runs a full
#    apt-get dist-upgrade/full-upgrade; only run during a maintenance
#    window (see the mode's own --help description):
bash lancache-ci-runner-clone-init.sh host-prep

# 7. Heavy-tier hosts only: verify/install the sccache client tooling (see
#    the dedicated sccache-check/sccache-fetch section above):
bash lancache-ci-runner-clone-init.sh sccache-check

# 8. If this host needs the LAN proxy other hosts use (host-prep never
#    touches /etc/docker/daemon.json), add a "proxies" block by hand and
#    restart dockerd -- e.g.:
#      { "proxies": { "http-proxy": "http://<lan-proxy-host>:3128",
#                      "https-proxy": "http://<lan-proxy-host>:3128",
#                      "no-proxy": "localhost,127.0.0.1" } }
#    Confirm which hosts actually need this with the maintainer; most of
#    this fleet does not.

# 9. Download, checksum-verify, and extract the actions-runner release,
#    writing its pre/post-job hook wiring (does not register or start it):
bash lancache-ci-runner-clone-init.sh runner-fetch /opt/actions-runner-1

# 10. Register with GitHub -- a short-lived registration token, human-run,
#     never done by this script (see the script's own header):
cd /opt/actions-runner-1
./config.sh --url <repo-url> --token <registration-token> --name <exact-hostname> --labels <labels>
sudo ./svc.sh install
# hold off on 'sudo ./svc.sh start' until the go-ahead to accept real jobs
```

Steps 2-5 and 7-8 are conditional (skip a step whose survey found nothing to
do); steps 1, 6, 9, and 10 apply to every new or disk-cloned host.

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
3. reaps stale per-branch Trivy cache directories (`/var/tmp/lancache-ng-
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
4. prunes stopped containers, build cache, unused images, and unreferenced
   anonymous volumes;
5. re-measures and logs the reclaimed delta, so a run that reclaimed nothing is
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
