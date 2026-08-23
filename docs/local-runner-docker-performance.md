# Local Runner Docker Performance

This guide is for contributors and maintainers who run GitHub Actions or other
CI jobs on their own Linux machine.

You do not need a local runner to use lancache-ng. It is only useful if you
want to test pull requests, build images locally or reduce hosted CI usage.
Local runner settings are an optimization layer. Keep them optional and
documented so the project can move jobs back to GitHub-hosted runners without
rewriting Dockerfiles or build scripts.
This guide covers Dev/CI acceleration only. Production installs, setup/update
flows, and runtime service containers must continue to work from prebuilt
images without sccache, sccache-dist, distcc, distcc-pump, or local Buildx
cache state.

## When a local runner helps

A local runner can help when you:

- build Docker images often
- test changes before opening a pull request
- maintain your own fork
- want faster rebuilds through local Docker layer cache
- have enough CPU, memory and disk space for repeated builds

A local runner is not required for normal installation.

## Host requirements

Use a machine that can safely spend CPU, memory and disk I/O on builds.

Recommended baseline:

- Linux host
- Docker Engine with the Docker Compose plugin
- Docker BuildKit enabled
- at least 4 CPU cores
- at least 8 GB RAM
- enough free disk space for Docker images and build cache

For frequent Rust and UI image builds, more memory and faster storage make a
large difference.

## Keep the runner isolated

Do not run untrusted pull requests on a privileged machine that also stores
important secrets.

Practical isolation rules:

- use a dedicated user for the runner
- avoid running the runner as root
- keep Docker and runner state separate from production data
- do not store production `.env` files, certificates or API keys in the runner
  workspace
- only expose Docker credentials and registry tokens when the workflow really
  needs to push images

For public pull requests, prefer read-only validation unless you fully trust
the code being built.

## Docker storage

Docker builds are faster when the host uses a native and stable storage driver.

Check the current driver:

```bash
docker info --format '{{.Driver}}'
```

Common results:

| Driver | Meaning |
|---|---|
| `overlay2` | normal fast Linux Docker storage driver |
| `fuse-overlayfs` | often used by rootless Docker; can be slower |
| `vfs` | very slow fallback; avoid for regular builds |

Do not change Docker storage on a production host without a backup and a
maintenance window. Changing the storage driver can make existing local images
and containers unavailable until Docker is migrated correctly.

## BuildKit and layer cache

BuildKit should be enabled for modern Docker builds.

For one shell:

```bash
export DOCKER_BUILDKIT=1
export COMPOSE_DOCKER_CLI_BUILD=1
```

For GitHub Actions, prefer `docker/setup-buildx-action` and
`docker/build-push-action` with a cache location that belongs to the current
runner job.

Avoid shared world-writable cache directories. A safe pattern is to use a
runner-owned temporary path and keep one cache folder per service.

Example cache shape:

```text
$RUNNER_TEMP/lancache-ng-buildx-cache/proxy
$RUNNER_TEMP/lancache-ng-buildx-cache/dns
$RUNNER_TEMP/lancache-ng-buildx-cache/ui
```

This keeps parallel matrix jobs from fighting over the same cache path.

## Rust builds and sccache

Rust services can benefit from `sccache`.

If you enable `sccache`, use a cache backend that is reachable from the build
environment. Redis is a common choice for self-hosted runners.
For jobs that must also run on GitHub-hosted fallback, document whether Redis
backing is optional, preferred, or a hard gate and keep the job green when the
cache backend is unavailable.

Important rules:

- do not hardcode Redis URLs in Dockerfiles or workflow files
- do not pass secret Redis URLs through Docker build arguments
- prefer BuildKit secrets for Docker builds
- control usage through `SCCACHE_REDIS_MODE` (`required`, `optional`, `off`)
- keep cache keys separated between unrelated services
- keep `CARGO_HOME` separate when multiple jobs install command-line tools in
  parallel
- keep source-built sccache version-pinned and install only the Redis plus
  `dist-client` features unless a PR explicitly needs another backend
- configure distributed Rust compilation as a complete pair:
  `SCCACHE_DIST_SCHEDULER_URL` as a repository variable and
  `SCCACHE_DIST_AUTH_TOKEN` as a repository secret
- do not set only the scheduler URL; sccache-dist requires client auth in
  `SCCACHE_CONF`

The goal is faster builds without leaking secrets into image history, logs or
repository files.

## Rust builds and distcc/pump

Some Rust crates still compile C or C++ helper code through build scripts.
For those cases, `distcc` with `pump` can offload part of the work to remote
compiler hosts.
As with `sccache`, this is a build-speed optimization only; setup and runtime
image pulls must not depend on it.

Use this as an opt-in setting:

- store the host list in a GitHub repository variable named `DISTCC_POTENTIAL_HOSTS`
- do not commit LAN IP addresses into Dockerfiles, workflows or docs
- include pump-capable entries with the `,cpp` option, for example
  `build-a build-b build-a,cpp,lzo build-b,cpp,lzo`
- keep `pump` enabled only for builders that do not generate C headers during
  the build; otherwise use normal distcc hosts from the same host list

Rust service builder images consume the host list through a BuildKit secret,
discover either `/usr/local/lib/distcc` or `/usr/lib/distcc`, put the discovered
wrapper directory first in `PATH`, export `CC=distcc`, `GCC=distcc`,
`CXX=distcc`, and `GXX=distcc`. Builders without generated C headers may start
with `eval \`distcc-pump --startup\`` before `cargo build` and shut it down
after the build with `distcc-pump --shutdown`. Builders with generated C
headers, such as the UI build through `aws-lc-sys`, must use normal distcc mode
instead so generated includes are preprocessed locally before remote compile.
When the distcc path is attempted, the build logs `[INFO] trying distcc path.`
and uses `DISTCC_FALLBACK=0` so project logic can explicitly retry once with
the normal local compiler if distcc is unavailable. Do not add `127.0.0.1` as
an implicit host.
Images that install Debian `distcc-pump` patch the package's known invalid
Python regex escapes before configuration and compile-check the result with
`SyntaxWarning` treated as an error.

Important:

- distcc helps the C/C++ parts of the build, not Rust codegen itself
- if the remote compiler hosts are unreachable, builds should fail fast
- keep the variable separate from the `SCCACHE_REDIS_URL` secret

## Rust builds and ccache (distcc C-dependency cache)

`services/dns/Dockerfile` and, since issue #1533, `services/ui/Dockerfile`
can layer `ccache` in front of distcc for their C-dependency compile paths
(`ring`/`aws-lc-sys`, via `rustls`), so a rebuild against unchanged C sources
reuses a previous compile's result from Redis instead of recompiling and
redistributing it every time. `services/ui/Dockerfile`'s custom
`lancache-distcc-wrapper` now understands both distcc calling conventions --
the original `$0`-basename masquerade dispatch, and ccache's `CCACHE_PREFIX`
convention (invoked as `distcc <real-compiler-path> <args>`, real compiler is
`$1`) -- disambiguated by checking `$0` first. **Known gap (confirmed
2026-08-20, issue #1533): `build-push.yml`'s real CI pipeline does not yet
populate the `ccache_redis_url` secret or the preflight action's
`ccache-redis-file` input at any call site, for either service -- this layer
has not been exercised against a real Redis endpoint in production CI yet.
See `AGENTS.md`'s `AG-CI-022` Known Gaps note.**

Important rules:

- ccache is enabled only once distcc itself is already enabled, and only when
  a ccache Redis endpoint (BuildKit secret `ccache_redis_url`) is present --
  it automatically reuses the `SCCACHE_REDIS_URL` secret already documented
  above for sccache, not a second Redis URL
- once both are enabled, `services/dns/Dockerfile` and `services/ui/Dockerfile`
  export `CC="ccache <real compiler>"` (not the plain `CC=distcc` every other
  distcc-enabled builder uses), with `CCACHE_PREFIX=distcc` so ccache still
  dispatches actual cache misses through distcc
- use `CCACHE_COMPILERCHECK=content`, not the ccache default of `mtime`,
  since a build-tools image rebuild changes the compiler's mtime but not
  necessarily its output
- `CCACHE_EXTRAFILES` folds two files into every cache key: the resolved
  `$BUILD_TOOLS_IMAGE` reference (so a client-side toolchain upgrade always
  produces a fresh key instead of reusing an object built by an older client
  compiler), and a verified remote toolchain identity read back from
  `configure_distcc()`'s own probe compile -- the `.comment` ELF section
  GCC/Clang embed in every object, extracted from an object that a real farm
  host actually produced, not assumed. If a farm host's compiler is upgraded
  between builds, the next build's probe reads a different `.comment` string
  and the cache key changes, so a stale remote object from the old toolchain
  cannot be served as a hit. `configure_ccache()` fails closed (plain distcc,
  no cache layer) if that identity cannot be read for any reason
- **known limitation:** this samples whichever single farm host answered one
  probe compile at the start of a build. It catches a farm upgraded *between*
  builds, but not a farm that is heterogeneous *within* one build -- e.g. if
  `192.168.1.229` and `192.168.1.240` (both natively installed, provisioned
  by hand, with no repository script that keeps them in lockstep) end up on
  different compiler versions from each other at the same moment, only the
  probe's own host is reflected in the cache key, not every host distcc might
  route individual `ring` C files to during the real build. Keep farm host
  compiler upgrades infrequent, deliberate, and applied to the whole pool at
  once until a per-object remote-identity check exists
- every ccache failure detected *before* the real Cargo build (a failed
  probe compile, or the probe's own Redis write/read check) falls back to
  plain distcc with no cache layer, rather than hard-failing the build; a
  Redis error that only surfaces *during* the real build itself cannot fall
  back after the fact, since the compile already succeeded -- that case is
  reported as an `[INFO]` diagnostic instead (see
  `services/dns/Dockerfile`'s post-build stats check)

See issue #887 for the full mechanism and `services/dns/Dockerfile`'s own
`configure_ccache()`/`disable_ccache()` comments for the implementation.

## Parallel jobs

Parallel CI jobs can reduce wall-clock time, but they also increase load.
Set the optional `CARGO_BUILD_JOBS` repository variable when the runner farm
should use a fixed Cargo job count. If it is unset, workflows and Rust service
Dockerfiles use detected CPU cores minus two, with a minimum of four jobs.
Invalid configured values fail closed instead of silently falling back.

Watch these host resources:

- CPU saturation
- memory pressure
- disk I/O wait
- Docker cache size
- network bandwidth for base image pulls

If the runner becomes unstable, reduce parallelism before adding more cache
layers. A slower reliable runner is better than a fast runner that fails with
random Docker or network errors.

## Registry mirrors

If base image pulls are slow or rate-limited, a registry mirror can help.

This is a host-level Docker setting and should be managed by the operator. Do
not require a mirror for contributors.

Example daemon configuration shape:

```json
{
  "registry-mirrors": ["https://mirror.example.local"]
}
```

Restarting Docker can interrupt running containers. Only change this during a
safe maintenance window.

## Cleanup

Local runners need regular cleanup. Docker caches and images can grow quickly.

Useful read-only checks:

```bash
docker system df
docker buildx du
```

Cleanup examples:

```bash
docker builder prune
docker image prune
```

Do not run broad prune commands on a production Docker host unless you know
which images, containers and volumes are safe to remove.

## Troubleshooting

If builds are slow:

- check whether Docker uses `overlay2`
- check whether base images are being pulled repeatedly
- check whether BuildKit cache paths are stable for the job
- check CPU, memory and disk I/O during the build
- check whether Rust dependencies are recompiling from scratch every time

If builds fail randomly:

- reduce parallelism
- isolate cache paths per job and service
- check available disk space
- check Docker daemon logs
- retry without remote cache to separate cache corruption from code failures

If a build contains secrets:

- stop using build arguments for secret values
- use BuildKit secret mounts instead
- rotate any secret that may have been written to logs or image layers
