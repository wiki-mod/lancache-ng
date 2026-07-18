# Self-hosted GitHub Actions runner

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
`tools/build-tools` nor the build workflow changed. Release tags always build the
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

`build-push.yml`'s `promote` job and `backfill-stack-latest.yml`'s `backfill-latest` job both move mutable GHCR channel tags (`latest`/`edge`) for the same images and must never run their tag-moving critical section at the same time as each other. This used to be enforced with a shared GitHub Actions job-level `concurrency:` group (`"Build & Push-promote"`), but that primitive was removed per issue #897: GitHub's concurrency admission can silently cancel a run that is still *queued* (not yet running) the moment another run requests the same group, which is exactly the failure #892 hit once multiple `promote`-reaching runs were able to build in parallel.

Real mutual exclusion now comes from `scripts/lib/promote-lock.sh`, a cross-host, cross-workflow lock backed by a dedicated non-branch/non-tag git ref (`refs/promote-lock/...`) on the shared GHCR-adjacent remote both workflows already push to — not a host-local `flock`, since the `lancache-heavy` runner label both jobs use is held by runners on multiple distinct physical hosts, so a `/tmp`-based lock would give each host its own, independently "uncontested" lock. Both jobs acquire/release this lock as explicit steps (see `promote`'s own step comments in `build-push.yml` and the "Acquire the cross-workflow promote lock" step in `backfill-stack-latest.yml`), giving the same any-promote-vs-any-backfill, any-ref exclusion the old concurrency group provided, without the queued-run-cancellation risk.

This lock applies only to the tag-moving critical section in these two jobs; it does not block routine CI runs or any other job.

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

Prebuilt service images (`proxy`, `dns`, `watchdog`, `dhcp`, `dhcp-proxy`, `ui`,
`build-tools`) publish both `linux/amd64` and `linux/arm64` under one coherent
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

## CodeQL

The CodeQL workflow uses advanced setup with `github/codeql-action` on self-hosted runners labeled `self-hosted`, `linux`, `lancache` and `codeql`. No separate CodeQL package needs to be installed on Debian; the action downloads and manages the CodeQL bundle during the workflow run.

Disable CodeQL default setup in GitHub before enabling this workflow. GitHub rejects SARIF uploaded by an advanced CodeQL workflow while default setup remains enabled for the repository.

The runner only needs outbound network access to GitHub to download actions, upload CodeQL results and fetch dependencies used by the repository checks.
