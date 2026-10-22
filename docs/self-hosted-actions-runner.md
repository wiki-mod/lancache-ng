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
build-tools container, CodeQL included. The sections below describe the CI 1.x
self-hosted setup and are historical.

## CI 1.x setup (historical)

The repository workflows are configured to run the build, container checks and CodeQL jobs on self-hosted Linux runners with these labels:

- `self-hosted`
- `linux`
- `lancache`
- `lancache-light` or `lancache-heavy`, depending on the job tier

Register at least one runner for each tier before enabling the workflows. Light runners handle shell and compose validation, while heavy runners handle Docker builds, scans, promotion, release, and the dedicated build-tools publish workflow. The runner user must be able to run Docker builds; project validation tools are supplied by the repository build-tools image instead of being installed ad hoc on the runner.

The workflow also builds and publishes `ghcr.io/wiki-mod/lancache-ng/build-tools`.
That image is used by local developer checks and is intentionally based on
`rust:latest`. It carries project validation tools such as Rustfmt, Clippy,
ShellCheck, Actionlint, Cargo Audit, sccache, distcc, distcc-pump, and
DNS/setup/template fixture tools. Trivy image scanning remains a workflow
capability, not a tool bundled into the image. Production service images remain
separate.

Workflow jobs that only need these bundled validation tools should run them from
the prebuilt image instead of compiling or installing them per job. For example,
the Cargo Audit jobs use the image-provided `cargo-audit` binary.

The dedicated `Build Tools Image` workflow runs on `lancache-heavy` because it
builds and scans Docker images before publishing multi-architecture tags.

Routine pull requests skip the `build-tools` image build when neither
`.github/build-tools` nor the build workflow changed. Release tags always build the
tag-scoped build-tools image because release jobs must not use mutable `latest`
tooling.

The dedicated `Build Tools Image` workflow provides the normal refresh path for
that image. It runs when build-tools inputs change, can be triggered manually,
refreshes weekly, smoke-tests the bundled tools, scans the local image, and then
publishes `linux/amd64` and `linux/arm64` tags on trusted non-PR refs.

The build-tools image does not replace the baseline runner requirements below.
The GitHub workflows still need a working self-hosted runner, Docker daemon,
Buildx support, outbound network access, and CodeQL action setup.

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
a hard gate. GitHub-hosted fallback validation must not inherit LAN-only
assumptions about Redis URLs, distcc schedulers, cache paths, or runner labels.

As a rule of thumb:

- optional: the job stays green without the accelerator
- preferred: use the accelerator when available, but keep a documented fallback
- gate: the job must have the accelerator or fail closed before doing work

## Native arm64 builds on GitHub-hosted runners

Prebuilt service images (`proxy`, `dns`, `watchdog`, `dhcp`, `dhcp-proxy`,
`ntp`, `syslog`, `ui`, `build-tools`) publish both `linux/amd64` and
`linux/arm64` under one coherent
multi-platform tag per service. The two platforms are built natively in
separate lanes, never through QEMU emulation for these images:

- `linux/amd64` still builds on the self-hosted `lancache-heavy` runner pool
  described above, with the same Redis/sccache-dist/distcc acceleration
  contract.
- `linux/arm64` builds natively on GitHub-hosted `ubuntu-24.04-arm` runners (or
  a newer non-EOL arm64 hosted image — never pin to a runner image GitHub has
  marked for retirement). These runners are free for public repositories and
  give real arm64 CPUs, so `ui` and `dns` (the two services that compile Rust
  from source) build at native speed instead of under QEMU emulation, which
  was judged too slow and too failure-prone for real `cargo build --release`
  runs when this was last evaluated (issues #348 / #395).

Each platform lane pushes its image by digest only (no mutable tag). A
separate merge step combines the two digests into the real `sha-<commit>` tag
per service with `docker buildx imagetools create` -- the same tool the
`promote` job already uses to move channel tags without rebuilding anything.
This keeps the amd64 and arm64 build lanes fully independent: either one can
fail, retry, or take longer without racing the other for the same tag.

GitHub-hosted arm64 runners are outside the self-hosted LAN, so they cannot
reach the Redis-backed `sccache` cache, the `sccache-dist` scheduler, or the
`distcc` hosts described in the Acceleration contract above. The arm64 lane
therefore always builds as an uncached, optional-acceleration `cargo build
--release` -- slower per build than the accelerated amd64 lane, but still a
native compile, not an emulated one. This is a deliberate, documented
tradeoff and not a bug: extending the LAN-only acceleration infrastructure to
a transient cloud runner is out of scope here.

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

When configuring the runner, include the custom `lancache` label plus the
appropriate tier label. For example:

```bash
./config.sh --url https://github.com/<owner>/<repo> --token <registration-token> --labels lancache,lancache-light
sudo ./svc.sh install
sudo ./svc.sh start
```

Heavy runners use the same base labels with `lancache-heavy` instead:

```bash
./config.sh --url https://github.com/<owner>/<repo> --token <registration-token> --labels lancache,lancache-heavy
sudo ./svc.sh install
sudo ./svc.sh start
```

If the runner will also execute CodeQL workflows, add the `codeql` label:

```bash
./config.sh --url https://github.com/<owner>/<repo> --token <registration-token> --labels lancache,lancache-heavy,codeql
sudo ./svc.sh install
sudo ./svc.sh start
```

CodeQL requires the `codeql` label to match the `runs-on` configuration in `.github/workflows/codeql.yml`.

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
| `runner-fetch <dir> [version]` | Download, sha256-verify and extract a runner release into a new or empty dir directly under `/opt`; writes the hook wiring. Does not register or start it. |
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

## Local Docker build cache

The build and build-tools workflows use a local Buildx cache under
`/var/tmp/lancache-ng-buildx-cache` instead of GitHub's `type=gha` cache
backend. This keeps Docker layer cache traffic on the self-hosted runner and
avoids consuming GitHub Actions cache quota for image builds.

Create the cache directory once if your runner has restricted `sudo` rules:

```bash
sudo mkdir -p /var/tmp/lancache-ng-buildx-cache
sudo chown -R actions-runner:actions-runner /var/tmp/lancache-ng-buildx-cache
```

Replace `actions-runner:actions-runner` with the runner account and group. The
workflow does not use `sudo` for cache rotation; the runner account must be able
to create and replace service-specific cache directories below this path.
The workflow uses `flock` from `util-linux` so concurrent runs cannot rotate the
same service cache while another run is importing it.

## Rust compiler cache

Rust checks and Rust image builds use Redis-backed `sccache` when the repository
is configured for it.

Configure this repository variable:

- `SCCACHE_REDIS_MODE`: `required`, `optional` or `off`.

Configure this GitHub Actions secret:

- `SCCACHE_REDIS_URL`: Redis URL used by sccache.

Use `required` for trusted self-hosted LAN runners where Redis is expected to
be reachable. Use `optional` or `off` when moving jobs to runners that do not
have access to the Redis cache.

When `SCCACHE_REDIS_MODE=required`, the runner must have `sccache` available in
`PATH`. Install it from source and keep the installed binary on the runner
service account's `PATH`.

### ccache reuse for the Rust service images' C-dependency compiles

The C-dependency compile paths (`ring`, via distcc) of
`services/dhcp/Dockerfile`, `services/dns/Dockerfile`,
`services/proxy/Dockerfile`, `services/ui/Dockerfile` and
`services/watchdog/Dockerfile` can layer `ccache` in front of distcc when
both a distcc host list and a ccache Redis endpoint are configured.

**Correction (2026-09-01, Issue #1781):** this paragraph used to also claim
`.github/build-tools/Dockerfile`'s "from-source curl/git compile" inherited
this same ccache-over-distcc mechanism since issue #1304/PR #1661.
`.github/build-tools/Dockerfile` has no such compile and never wired
`CC=distcc`/`CC="ccache ..."` for one -- curl and git are both plain
`apk add`/`apt-get install` packages there (curl was `COPY`'d from the
shared `services/utilities` image's own from-source build, not compiled
in `.github/build-tools/Dockerfile` itself, until Issue #1781 replaced that
`COPY` with this stage's own `apk add`/`apt-get install curl` too). The
ccache/distcc-accelerated from-source build this correction refers to only
ever existed in `services/utilities/Dockerfile`'s now-removed
`curl-builder` stage. In CI 2.0, `ci.sh` (`_ci_set_runtime`) writes the
`ccache_redis_url` and `distcc_potential_hosts` secrets only for Rust
builds (kind `rust`), never for the build-tools image.

This is not a separate secret: it automatically reuses the same
`SCCACHE_REDIS_URL` value already configured for `sccache` above, on the
same Redis instance,
whenever `DISTCC_POTENTIAL_HOSTS` is also set — `ccache`'s own fixed `ccache:`
key namespace never collides with `sccache`'s distinct
`SCCACHE_REDIS_KEY_PREFIX`-based one. There is no separate `CCACHE_REDIS_MODE`
toggle; every ccache failure detected before the real Cargo build falls back
to plain distcc (no cache layer) instead of hard-failing the build. A Redis
error surfacing only during the real build cannot fall back after the fact
(the compile already succeeded) and is reported as an `[INFO]` diagnostic
instead. Unlike other Rust service builders, `services/dns/Dockerfile`,
`services/ui/Dockerfile`, and `services/watchdog/Dockerfile` export
`CC="ccache <real compiler>"` (not the plain `CC=distcc` documented under
[Rust builds and distcc/pump](local-runner-docker-performance.md#rust-builds-and-distccpump))
once both distcc and ccache are enabled. See those Dockerfiles' own
`configure_ccache()`/`disable_ccache()` comments and issue #887/#1533/#1095
for the full mechanism.

## CodeQL

The CodeQL workflow uses advanced setup with `github/codeql-action` on self-hosted runners labeled `self-hosted`, `linux`, `lancache` and `codeql`. No separate CodeQL package needs to be installed on Debian; the action downloads and manages the CodeQL bundle during the workflow run.

Disable CodeQL default setup in GitHub before enabling this workflow. GitHub rejects SARIF uploaded by an advanced CodeQL workflow while default setup remains enabled for the repository.

The runner only needs outbound network access to GitHub to download actions, upload CodeQL results and fetch dependencies used by the repository checks.
