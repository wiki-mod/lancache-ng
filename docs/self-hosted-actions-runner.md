# Self-hosted GitHub Actions runner

## Current state (CI 2.0, Issue #1683)

CI jobs run on GitHub-hosted runners by default. The runner label and the
timeout of every job come from the SOT (`.github/yaml/build-manifest.yml`:
`platform_arch.<arch>.runner`, `ci_job_timeouts`) through `ci.sh job-settings`,
which the first job of each workflow runs; only that job carries a literal
runner and timeout, and the `workflow-job-settings` check rejects any other.
Setting the repository variable `PROJECT_SELFHOSTED_RUNNER_USAGE_CI` to exactly
`true` moves the jobs to `platform_arch.<arch>.runner_self_hosted`
(`lancache-heavy` for amd64); the first job of each workflow stays
GitHub-hosted. Every job runs in the
build-tools container, CodeQL included. A self-hosted runner therefore needs
Docker with Buildx and outbound network access; the project tools come from
the build-tools image.

## Job concurrency serialization

Two jobs move mutable GHCR channel tags: the `promote` job of `ci.yml`
(`bash .github/scripts/ci.sh promote-ref`) and the `nightly` job of
`nightly.yml` (`bash .github/scripts/ci.sh promote nightly`). No GitHub
Actions `concurrency:` group serializes them: GitHub's concurrency admission
can cancel a run that is still queued (issue #897).

`ci.sh` serializes them with one lock per channel: the git ref
`CI_PROMOTE_LOCK_REF/<channel>` (SOT value `refs/ci/promote-lock`) on the
repository remote, written by compare-and-swap. A git ref works across
runner hosts; a host-local `flock` would not. The lock note names the
holder run. A waiting run retries after `CI_LOCK_POLL_SECONDS`, at most
`CI_PROMOTE_LOCK_MAX` times, and takes the lock over only when the holder run
has ended.

The lock covers only the channel move; it does not block other jobs.

## Acceleration contract

Build acceleration is a CI optimization, not a runtime requirement. Jobs that
use Redis-backed `sccache`, `sccache-dist`, `distcc`, `distcc-pump`, or a local
Buildx cache must document whether that accelerator is optional, preferred, or
a hard gate. Jobs on GitHub-hosted runners must not inherit LAN-only
assumptions about Redis URLs, distcc schedulers, cache paths, or runner labels.

As a rule of thumb:

- optional: the job stays green without the accelerator
- preferred: use the accelerator when available, but keep a documented fallback
- gate: the job must have the accelerator or fail closed before doing work

## Native amd64 and arm64 builds

Every image publishes the platforms of the SOT `build_matrix.platforms`
(`linux/amd64`, `linux/arm64`) under one multi-platform tag. Each platform builds natively on
the runner of `platform_arch.<arch>` in the SOT, never through QEMU:

- `linux/amd64` builds on `runner` (`ubuntu-latest`), or on
  `runner_self_hosted` (`lancache-heavy`) when
  `PROJECT_SELFHOSTED_RUNNER_USAGE_CI` is `true`.
- `linux/arm64` builds on `ubuntu-24.04-arm` in both cases; the fleet has no
  arm64 host.

Each platform lane pushes its image by digest only. `ci.sh` then joins the
two digests into one tag with `docker buildx imagetools create`, so either
lane can fail or retry without racing the other for the same tag.

The `sccache-dist` scheduler and the `distcc` hosts are LAN-only. `ci.sh`
reads them only on a self-hosted runner and otherwise logs
`CI-INFO-VARIABLES-0024`, so a GitHub-hosted build compiles without them.

## Debian runner packages

On a Debian runner, install the baseline tools used by the workflows:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git sudo util-linux
```

Install Docker Engine and the Compose plugin from Docker's Debian repository, then add the GitHub Actions runner user to the `docker` group:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker actions-runner
```

Replace `actions-runner` with the actual Linux user that runs the GitHub Actions service. Restart the runner service or log the user out and back in so the new group membership is applied.

## Container privilege model (LXC/Proxmox)

If your self-hosted runner itself runs inside an LXC container (e.g. on
Proxmox), prefer an **unprivileged** container over a **privileged** one.
This is counter-intuitive -- "privileged" sounds like it should be strictly
more permissive -- but two independent, real incidents on this project's own
runner fleet found the opposite in practice:

- A privileged LXC container's root (UID 0 inside the container, unmapped to
  the host, i.e. `/proc/self/uid_map` reads `0 0 4294967295`) hit a
  **stricter** Proxmox-enforced AppArmor/MAC profile than the unprivileged
  containers running the exact same workload. A `docker run` job needing to
  write a lease file failed with `Permission denied` even as root against a
  `chmod 0777` directory -- a signature that is not explainable by ordinary
  DAC permission bits at all. Proxmox's default AppArmor profile for
  privileged containers is typically stricter than for unprivileged ones,
  specifically to compensate for the privileged container's full Linux
  capability set. The fix was reconciling the container to unprivileged, not
  loosening file permissions further (which cannot fix a MAC-layer denial).
- The same privileged/unprivileged divergence separately caused a distinct
  failure for tooling that needs to mount its own nested `/proc` (e.g.
  `bwrap`-based sandboxing used by some distributed-compile tooling): the
  privileged container was missing the LXC **`security.nesting`** feature
  flag the unprivileged containers had, so nested mount syscalls the tooling
  needs were rejected with `Operation not permitted`.

If you must use a privileged LXC container for another reason, verify
`security.nesting=1` is set (needed by any tool that mounts its own nested
`/proc`, such as `bwrap`-based sandboxes) and be prepared for Proxmox's
stricter default AppArmor confinement to block operations that succeed
identically on an unprivileged container running the same workload --
`chmod`/DAC changes cannot work around a MAC-layer (AppArmor) denial, so
look at the container's privilege/confinement level first, not file
permissions, if a process running as root still gets `Permission denied`
against a world-writable path.

## Runner labels

A fleet runner carries the label of `platform_arch.amd64.runner_self_hosted`
in the SOT (`lancache-heavy`). CodeQL needs no extra label: it runs on the
same runner as every other job. Register the runner as described under
"Preparing a new or cloned host" below, with `--labels lancache-heavy`.

## Runner host maintenance (`ci.sh runner-host`)

Everything a runner host needs beyond the runner itself is one repo-versioned
engine, `.github/scripts/ci.sh runner-host <mode>` (AG-CI-016: cleanup that CI
depends on lives in the repo, PR-reviewable and identical on every host).
Every value (paths, ages, unit names, package lists) is the SOT block
`runner_host:` in `.github/yaml/build-manifest.yml`. The docker daemon limits
have their own mode, `ci.sh docker-daemon-config`.

**Prerequisites on a runner host:** a persistent clone of this repository
(for example `/opt/lancache-ng`, not a runner workspace, which checkout
cleans), `yq`, `jq`, and `GITHUB_REPOSITORY` in the environment. The generated
systemd unit sets `GITHUB_REPOSITORY` itself and points at the clone that ran
`units`, so re-run `units` after moving or re-cloning it.

### Scheduled cleanup (every host: 229, 240, 241, 243, ...)

```sh
sudo env GITHUB_REPOSITORY=wiki-mod/lancache-ng bash /opt/lancache-ng/.github/scripts/ci.sh runner-host units
sudo systemctl start lancache-ci-cleanup.service     # one manual run
sudo tail -n 40 /var/log/lancache-ci-cleanup.log
```

`units` writes `lancache-ci-cleanup.service` and `.timer` from the SOT
(`04:00` daily, `RandomizedDelaySec=900`) and enables the timer. A prior
host-local-only copy ran on a subset of hosts, which is why one host
accumulated ~40 GB of unreclaimed images and build cache: deploy to all.

`runner-host cleanup` measures, cleans, re-measures, and logs the reclaimed
delta so a run that reclaimed nothing is visible:

1. disk usage of `/` before;
2. reap **running** containers past an age (a normal run finishes in minutes,
   so one that old is an orphan whose teardown never ran): build-tools
   containers by image (2 h), validate stacks by compose project
   `<repo>-validate-*` (2 h), `buildx_buildkit_builder-*` by name (3 h);
3. reap `<repo>-validate-*` networks with zero containers **and** past the
   same age (`docker compose up` creates the network before its containers,
   so an empty young network may be mid-bringup);
4. reap CI 1.x per-branch Trivy cache dirs under
   `/var/tmp/lancache-ng-trivy-cache` older than 1 day (`-mmin`, exact; CI 2.0
   uses the shared `/mnt/trivy-db`, so this removes leftovers only);
5. prune stopped containers, build cache, unused images, unreferenced volumes;
6. disk usage after, and the reclaimed delta.

**The container and network age keys on `.Created`, not `.State.StartedAt`
(issue #1095).** `StartedAt` is reset by every restart, including the one the
Docker restart manager performs when the daemon starts, so a container that
leaked days before a host reboot looked fresh at every later check. Confirmed
on host `.240` (2026-08-05): three validation containers created 2026-08-03
survived a reboot and every scheduled run since.

The log is `/var/log/lancache-ci-cleanup.log`, trimmed to its last 5 MiB at
the start of each run.

### Job hooks

`runner-host hooks` installs `pre-job-cleanup.sh` (resets the owner of
`$GITHUB_WORKSPACE`, so checkout can delete files a container left behind as
a foreign UID) and `post-job-cleanup.sh` (the same, plus removal of
`<repo>-validate-*` networks with zero containers older than a 120 s grace
window, so a sibling runner's network in bringup is never touched). The runner
`.env` wires them with `ACTIONS_RUNNER_HOOK_JOB_STARTED` and
`ACTIONS_RUNNER_HOOK_JOB_COMPLETED`.

### Preparing a new or cloned host

Read-only modes first; every destructive mode needs its `CONFIRM_*=yes`.

| Mode | What it does |
| --- | --- |
| `check` | Report runner dirs (own, foreign clone leftovers, ambiguous identity), stray archives, sudoers, docker group, hooks, timer. Writes nothing. |
| `clean` (`CONFIRM_CLEAN=yes`) | Stop and disable inherited units, remove runner dirs proven foreign. Archives are only listed. |
| `clean-archive <path>...` | Remove the exact archive paths that `check` lists. |
| `host-prep` | Idempotent: sudoers rule, docker group, `/opt` ownership, hooks, `apt-listchanges` purge, backports pin (Debian trixie only), cleanup timer. Never touches `daemon.json` or runner registration. |
| `runner-fetch <dir>` | Download, sha256-verify and extract the latest runner release into a new or empty dir directly under `/opt`; writes the hook wiring. Does not register or start it. |
| `runner-hook-env <dir>` | Re-write the hook lines in `.env`; run after `config.sh`, which truncates it. |
| `runner-restart-policy` | `Restart=on-failure` drop-in on every `actions.runner.*` unit; run after `svc.sh install`. |
| `full-reset-check` / `full-reset-clean` (`CONFIRM_FULL_RESET=yes`) | Survey, then truncate shell history and `known_hosts`, regenerate hostid, machine-id and SSH host keys, remove stale journal dirs and allowlisted template scripts. `authorized_keys`, `id_*` keys, orphaned `/home` dirs and apt history are reported, never changed. |
| `set-hostname <name>` | Apply the maintainer's hostname and the `127.0.1.1` line; the name is never derived. |
| `purge-pve-check` / `purge-pve` (`CONFIRM_PURGE_PVE=yes`) | Inventory, then remove a nested Proxmox VE stack. The kernel and firmware packages are never listed and the run refuses if a simulation touches them. Verified on host `.81` (issue #1622) including a reboot. |
| `sccache-check` / `sccache-fetch <dir>` | Heavy hosts only: check the sccache client tooling; install staged binaries after running them once. No scheduler token is stored on the host. |

For a fleet host, register the runner with `--name $(hostname)` exactly (not
the old letter-prefix scheme of 229/240/241/243), pipe the registration token
over stdin, run `runner-hook-env` after `config.sh`, then `svc.sh install`,
`runner-restart-policy`, and start the service only after the go-ahead.

### `daemon.json` build-cache GC and log rotation (needs a daemon restart)

`ci.sh docker-daemon-config` bounds the build cache and container logs at the
daemon level, so they cannot grow between cleanup runs:

```json
{
  "builder": { "gc": { "enabled": true, "defaultReservedSpace": "20GB" } },
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
```

Neither `builder` nor `log-driver`/`log-opts` is in dockerd's SIGHUP-reloadable
subset, so applying them needs a full `dockerd` restart, which stops every
container on that host including an in-flight CI job. The only lever is when.
`defaultReservedSpace` is the current key; the older `defaultKeepStorage` is
still honored through a compatibility shim, but dockerd silently drops any
unknown key (`dockerd --validate` still says OK), so a clean validate alone
never proves a key is real. The tool merges into the existing file with `jq`'s
`*`, so host keys such as `storage-driver` and `max-concurrent-*` survive.
Hosts `.229`, `.240`, `.241` carry such a file; `.243` has none.

One host at a time, in an agreed quiet window:

```sh
sudo bash .github/scripts/ci.sh docker-daemon-config check     # preview, writes nothing
sudo bash .github/scripts/ci.sh docker-daemon-config stage     # writes daemon.json.staged
sudo bash .github/scripts/ci.sh docker-daemon-config apply     # backup + install, no restart
sudo CONFIRM_DOCKERD_RESTART=yes bash .github/scripts/ci.sh docker-daemon-config restart
```

`check` and `apply` run dockerd's own `--validate` first. `restart` is the
only disruptive step; afterwards confirm the runner takes jobs before the next
host. To roll back, restore `/etc/docker/daemon.json.bak.<timestamp>` and
restart `docker.service`. The values come from `CI_BUILDER_GC_RESERVED_SPACE`,
`CI_DAEMON_LOG_MAX_SIZE`, `CI_DAEMON_LOG_MAX_FILE`, `CI_DAEMON_JSON` (SOT
`ci_variables`, overridable per host by environment).

## Rust build acceleration

`sccache`, `sccache-dist`, `distcc` and `ccache` are described in
[local-runner-docker-performance.md](local-runner-docker-performance.md);
`ci.sh rust-build` owns them.

## CodeQL

`ci.sh codeql-analyze <language>` downloads the CodeQL CLI bundle pinned in
the SOT (`external_versions.codeql`), creates the database with
`--build-mode=none` and uploads the SARIF with `codeql github upload-results`.
It runs in the build-tools container on the runner `ci.sh job-settings`
chose; the runner needs no CodeQL package and no extra label.

Disable CodeQL default setup in GitHub before enabling this workflow. GitHub rejects SARIF uploaded by an advanced CodeQL workflow while default setup remains enabled for the repository.

The runner only needs outbound network access to GitHub to download actions, upload CodeQL results and fetch dependencies used by the repository checks.
