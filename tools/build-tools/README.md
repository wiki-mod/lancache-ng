
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# build-tools Alpine Evaluation

This document records the Alpine-Linux feasibility evaluation for this image, tracked under
issue #1095. It is a log of real, executed findings, not a design proposal. AG-KD-009 permits
Alpine as a supported build base for this image but requires full verification and maintainer
approval before any actual switch; nothing here constitutes that switch decision.

The Debian branch (`FROM golang:latest AS actionlint-builder` / `FROM rust:latest`, unnamed final
stage) is unchanged and remains this Dockerfile's default `docker build` target. The Alpine
candidate lives in two additional named stages earlier in the same file
(`actionlint-builder-alpine`, `alpine-final`), selected explicitly via `docker build --target
alpine-final`. Stage order matters: Docker's default build target is always the last stage in the
file when no `--target` is given, so the Alpine stages are placed before the unnamed Debian final
stage to keep the Debian branch building by default with zero caller changes.

## Prior work this evaluation builds on

A previous real-testing round (issue #1598) found: a plain `apk add curl gzip bzip2 util-linux
bash <...>` on Alpine 3.24.1 scored 0 Trivy findings; the same source-build-instead-of-apt
principle applied to Debian eliminated gzip's 2 CVE IDs but not curl's (curl's CLI swap does not
touch the system libcurl `git` links against transitively); a full-severity scan on the real
Debian base additionally found 10 currently-untracked curl CVE IDs missing from
`.trivyignore.yaml` (separate issue, not in this evaluation's scope). This document re-verifies
independently rather than assuming those numbers still hold.

## Command census (Phase 1)

The authoritative real-usage baseline is this Dockerfile's own build-time `required_tools=()`
self-check array (Debian stage). Real usage across `.github/workflows/build-push.yml` (36 real
`docker run ... "$BUILD_TOOLS_IMAGE"` call sites), the composite actions under `.github/actions/**`
that consume this image (`shellcheck-and-standing-guards`, `rust-acceleration-preflight`,
`file-headers-check`, `pr-title-convention-check`, `pr-tracking-metadata-fetch-and-validate`),
`scripts/tracked/**`/`scripts/untracked/**` (including all 13 `scripts/untracked/simulations/*.sh`),
and `tests/bats/**` (131 files) / `tests/shellspec/**` (1 spec file, run wholesale inside the
container by `build-tools-smoke.yml`/`.github/actions/build-tools-candidate-smoke`) was
cross-checked against that array. No command was found running inside a `BUILD_TOOLS_IMAGE`
container that is missing from the array.

Only one of the 13 simulation scripts (`syslog-forwarding-simulation.sh`) itself runs as the direct
payload of a `docker run ... "$BUILD_TOOLS_IMAGE"` call; the other 12 run on the bare runner host but
make their own internal `docker run ... "$BUILD_TOOLS_IMAGE" ...` sub-calls for `curl`/`dig`/`openssl`/
`cat`/`bash`/`timeout`/`sleep` against Kea/DNS/proxy containers on an isolated network -- those
sub-calls are real container-side command usage even though the wrapping script is host-side.

## AG-VAL-034 (GNU vs BusyBox) findings

- No `find -printf`, no `date +%N` usage found anywhere in the real command surface.
- No `readlink -f` usage found.
- `grep -oP` (PCRE) is real and used inside the container (several `tests/bats/*.bats`,
  `check-workflow-service-lists.sh`). Verified live on `alpine:3.24.1`: the `grep` apk package
  (3.12-r0) is real GNU grep with full PCRE support -- `echo test123 | grep -oP '\d+'` returns
  `123`, exit 0. Installing the `grep` apk package (not relying on the BusyBox applet) resolves
  this.
- `stat -c` is used in several `.bats` files. AG-VAL-034 itself already documents this construct as
  previously verified identical to GNU on a real `alpine:3.24` container (PR #1346); this
  evaluation additionally installs the `coreutils` apk package, which provides a real GNU `stat`.
- `sed -E` is used once in `build-push.yml` (line 1367); the `sed` apk package (4.9-r2) is real GNU
  sed with `-E` support, same package installed in the Alpine candidate stage.

## Package availability and versions (Phase 2, live `apk policy` on `alpine:3.24.1`)

Direct apk equivalents, all versions from a live pull on `lancache-240`:
bash 5.3.9-r1, git 2.54.0-r0, curl 8.21.0-r0, jq 1.8.1-r0, gzip 1.14-r2, bzip2 1.0.8-r6,
xz 5.8.3-r0, rsync 3.4.3-r1, openssl 3.5.7-r0, bind-tools 9.20.26-r0 (provides `dig`),
iproute2 7.0.0-r0 (provides `ip`), gettext 1.0-r0 (provides `envsubst`), tcpdump 4.99.6-r1,
gnupg 2.4.9-r1, python3 3.14.7-r1, distcc 3.4-r10, distcc-pump 3.4-r10 (native package -- no
Debian-style Python regex patch needed), shellcheck 0.11.0-r1, ccache 4.13.6-r0,
build-base 0.5-r4, cmake 4.2.3-r0, make 4.4.1-r4, pkgconf 2.5.1-r0, musl-dev 1.2.6-r2,
coreutils 9.11-r0, findutils 4.10.0-r1, grep 3.12-r0, sed 4.9-r2, gawk 5.3.2-r2,
expect 5.45.4-r5, util-linux 2.42.1-r0, ca-certificates, openssl-dev, openssl-libs-static
3.5.7-r0, zlib-dev/zlib-static, bats 1.13.0-r1, tzdata.

Naming differences from the Debian package list (real, not blockers):
- `clang` -> `clang22` (Alpine 3.24 has no unversioned `clang` meta-package).
- `lld` -> `lld22` (same reason).
- `procps` -> `procps-ng` (Alpine's real package name).

Real gap, no apk equivalent at all:
- **`dhclient`/isc-dhcp-client**: no Alpine package provides it. Only `busybox-extras`' `udhcpc`
  (a different, independent DHCP client implementation) exists. Affects
  `scripts/untracked/simulations/dhcp-kea-lease-flow-simulation.sh` and
  `syslog-forwarding-simulation.sh`, which currently perform a real DORA exchange against Kea via
  real ISC dhclient behavior. Does not affect `bats tests/bats`/`shellspec tests/shellspec` (Phase
  3 scope). Left as an open item: either adapt those two scripts to `udhcpc` (behavior not yet
  verified as equivalent) or another approach, pending a decision this evaluation does not make.

## Prebuilt-binary vs source-build ABI findings (Phase 2 point 4)

`cargo-audit` and `cargo-tarpaulin` are fetched as prebuilt, checksum-verified
`x86_64-unknown-linux-gnu` release binaries on the Debian branch. Both were real-tested against
Alpine 3.24.1:
- Without any compatibility layer: fails immediately, missing `libgcc_s.so.1` and dozens of glibc
  symbols.
- With `gcompat` (1.1.0-r4) + `libgcc` installed: still fails --
  `Error relocating [...]: __isoc23_sscanf/__isoc23_strtol/__res_init: symbol not found`. These are
  glibc-2.38+-era versioned symbols (and a libresolv symbol) gcompat 1.1.0 does not implement.
- Mitigation, real-tested and working: building both from source via `cargo install` (the same
  mechanism already used for `sccache` on the Debian branch) produces a native musl binary with no
  ABI dependency at all. `cargo-audit --version 0.22.2 --locked` built clean on `rust:alpine` in
  ~110s. `cargo-tarpaulin --version 0.37.1 --locked`'s first attempt failed
  (`cannot find -lssl`/`-lcrypto`, static-pie linking needs static libs); adding
  `openssl-libs-static`/`zlib-static` fixed it, real build succeeded in ~2m26s, both binaries run
  and report their correct version.

This mirrors the maintainer's explicit preference for this evaluation ("prefer Alpine-native over
external non-Alpine feeds when the CVE/currency bar is still met") -- source-building via `cargo
install` for these two Rust-native tools is not a CVE-avoidance compile per AG-KD-003's sense, it
is the same mechanism the project already uses for `sccache`.

## Go-toolchain / base-image parity (real, verified live)

AG-KD-009's `rust:latest`/`golang:latest` wording targets keeping a current toolchain, not the
literal tag (maintainer decision, this evaluation); `rust:alpine`/`golang:alpine` were checked for
real version parity, not assumed:
- `rust:latest` and `rust:alpine`: both `rustc 1.97.1 (8bab26f4f 2026-07-14)` / `cargo 1.97.1`.
- `golang:latest` and `golang:alpine`: both `go1.26.7 linux/amd64`.

All four Go-built tools (AG-KD-003's justification: avoiding a stale embedded Go stdlib in
prebuilt release binaries) build clean from source against `golang:alpine`, same versions/pins as
the Debian branch, using the identical `go install`/`go build`/vendor-override mechanism:
- `actionlint` v1.7.12: `built with go1.26.7 compiler for linux/amd64`.
- `docker-compose` v5.4.0: builds and runs.
- `docker-buildx` v0.36.1: builds and runs.
- `docker` CLI v29.7.2 (vendor.mod symlink approach): builds and runs, same static-pie
  linking flags as upstream's own `scripts/build/binary`.

None of the four needed a musl-specific build-tag or linker change; none has a cgo dependency.

## Musl target: not needed on the Alpine branch

The Debian branch's Dockerfile adds a musl cross-compilation target (`rustup target add
x86_64-unknown-linux-musl`) alongside its default `-gnu` host, for `services/ui`/`services/dns`'s
own musl-linked crates. On the Alpine candidate this step is unnecessary: `rust:alpine`'s default
rustc host triple already IS `x86_64-unknown-linux-musl` -- confirmed via `rustc -vV`'s own
`host:` line inside the built candidate image.

## Rebuild-avoidance wiring (Phase 4 investigation)

`build-tools` is **already** listed in `build-push.yml`'s `determine-push-reuse-scope` job
allowlist (`allowlist=(proxy dns ui watchdog dhcp dhcp-proxy ntp build-tools)`, issue #1095 / PR
#1532) and gets the same three-part `push_reuse_decide` check (revision label + git ancestry +
real content diff via `scripts/untracked/classify-image-impact.sh`, which already emits a
`build_tools` key) as every other service -- this feeds `build-push.yml`'s own container-scan
reuse decision for the build-tools channel image. The original premise that build-tools was never
connected to this machinery is only partially accurate.

What is genuinely disconnected: `build-tools.yml`'s own `determine-publish-scope` job (the one
that decides whether to actually rebuild+republish the image) uses a standalone, simpler
`git diff --name-only "$before_sha" "${{ github.sha }}" -- tools/build-tools
.github/workflows/build-tools.yml` check -- not `scripts/lib/push-reuse.sh`'s `push_reuse_decide`.
This is not an architectural impossibility: `push_reuse_decide` is a plain sourceable bash function
(`scripts/lib/push-reuse.sh`, `scripts/lib/ghcr-retry.sh`, `scripts/lib/staging-image-freshness.sh`,
`scripts/lib/build-tools-channel.sh`), the exact same pattern `build-tools.yml` already uses to
source `scripts/lib/ghcr-retry.sh`/`scripts/lib/docker-metadata.sh` elsewhere in the same file. No
one has wired it in yet.
