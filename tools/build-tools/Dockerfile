
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# CI and developer validation toolchain with Rust, sccache, ccache, distcc, and build utilities.
#
# Intentional build-tools default: use rust:latest so developer and CI
# validation sees current Rust tooling early. Production service Dockerfiles
# stay separately pinned for reproducible runtime image builds.
FROM golang:latest AS actionlint-builder

ARG ACTIONLINT_VERSION=1.7.12
ARG DOCKER_CLI_VERSION=29.7.2
ARG DOCKER_COMPOSE_VERSION=5.4.0
ARG DOCKER_BUILDX_VERSION=0.36.1
# buildx v0.35.0's go.mod pins github.com/containerd/containerd/v2 at v2.2.4,
# which carries three HIGH-severity CVEs (CVE-2026-53488/53489/53492) fixed in
# 2.2.5+ -- confirmed directly via Trivy scanning this image's first buildx
# build attempt. Unlike the docker/docker v28.5.2+incompatible case just below
# (no v29.x module tags exist at all, so that one genuinely cannot be bumped),
# containerd/containerd/v2 does publish a newer, non-breaking 2.2.x tag, so
# `go get` this exact module up to the fixed version before building instead
# of carrying the vulnerability forward. (Update, Issue #1570: buildx has
# since moved its own go.mod floor past the 2.2.x line entirely -- see the
# What/Why block immediately below for the current target and reasoning.)
# What: keeps this override current with buildx's own upstream go.mod floor.
# Why: buildx v0.36.1 itself already requires containerd/containerd/v2
# v2.3.3 as its go.mod floor (checked directly against that tag's go.mod),
# so the v2.2.x line this override used to target no longer applies -- 2.3.4
# is the next real patch tag on the SAME minor line buildx itself now
# uses, not a jump past what upstream already adopted.
# From: Issue #1570
ARG DOCKER_BUILDX_CONTAINERD_VERSION=2.3.4
# docker-buildx v0.35.0, docker-compose v5.2.0, AND the Docker CLI v29.6.1
# (its own vendor.mod pins the same version -- checked when auditing all
# four source-built tools for this same CVE class, not just the two CI
# originally flagged) pin google.golang.org/grpc at v1.81.1, which carries a
# HIGH-severity CVE (GHSA-hrxh-6v49-42gf, gRPC-Go xDS RBAC and HTTP/2
# vulnerabilities) fixed in 1.82.1 -- confirmed via Trivy scanning this image
# (CI run 29926535995 on PR #1070; tracked as issue #1080, the third
# confirmed instance of this CVE class per AGENTS.md's AG-KD-003). Same
# reasoning as the containerd override above: neither project had cut a
# release that resolved this on its own at the time. (Update, Issue #1570:
# buildx v0.36.1/compose v5.4.0/cli v29.7.2 now floor at v1.82.1 themselves,
# so this override today only carries the pin one further patch ahead --
# see the What/Why block immediately below.)
# What: keeps this override one patch ahead of buildx/compose/cli's own
# go.mod floor, which has itself already moved to v1.82.1 by the versions
# bumped in this same change (checked directly against their go.mod/
# vendor.mod at the new tags) -- 1.83.0 is the current upstream release.
# Why: no new CVE motivates this specific step; staying on the latest
# grpc-go tag needs no extra reasoning to re-justify later than the
# override mechanism itself already established (see the block above).
# From: Issue #1570
ARG GRPC_GO_VERSION=1.83.0
# docker-buildx v0.35.0 (go.mod: v0.37.0) and docker-compose v5.2.0 / the
# Docker CLI v29.6.1 (both: v0.38.0, checked when auditing all three
# source-built Go tools with a go.mod/vendor.mod for this same CVE class,
# not just the one CI happened to flag) pin golang.org/x/text at versions
# carrying CVE-2026-56852 (a norm.Iter infinite loop on malformed input),
# HIGH severity, fixed in v0.39.0 -- confirmed via Trivy scanning this image
# (the fourth confirmed instance of this CVE class per AGENTS.md's
# AG-KD-003). actionlint has no golang.org/x/text dependency at
# all (checked directly), so it needs no override. Same reasoning as the
# containerd/grpc overrides above: neither upstream project had cut a
# release that resolved this on its own at the time. Pinned to v0.40.0 (the
# actual latest tag as of this fix, one past the v0.39.0 minimum fix
# version) rather than the bare minimum, since there is no indication of a
# regression between the two and staying on latest needs no extra reasoning
# to re-justify later. (Update, Issue #1570: buildx v0.36.1/compose
# v5.4.0/cli v29.7.2 now floor at v0.40.0 themselves -- see the What/Why
# block immediately below for the current target.)
# What: same routine latest-tag bump as the grpc-go override above.
# Why: golang.org/x/text v0.41.0 is the current upstream release; no new
# CVE motivates this step specifically.
# From: Issue #1570
ARG GOLANG_X_TEXT_VERSION=0.41.0

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# actionlint, the Docker CLI, docker-compose, and the buildx CLI plugin are
# all Go binaries, and Go statically embeds its entire standard library into
# every compiled binary -- unlike a dynamically-linked C tool, there is no way
# to get security fixes into an already-built Go binary short of recompiling
# it. Each upstream project only cuts a new release when the tool itself has
# a feature/fix to ship, not on every Go stdlib security release, so their
# latest available release binaries can (and have: confirmed via Trivy
# scanning the exact official static binaries for actionlint v1.7.12 and
# Docker CLI/compose v29.6.1/v5.2.0) carry known stdlib CVEs from whatever Go
# toolchain happened to be current when that release was cut. Building from
# source with whatever Go toolchain `golang:latest` resolves to at build time
# is the only way to get a current, patched stdlib into these tools. buildx
# is built from source here as the same preventive measure for consistency,
# even though its official release binary hasn't been Trivy-scanned
# separately (issue #787 only required adding `docker buildx` support, not
# reproducing the CVE-2026-39822 investigation for it).
# cargo-audit and cargo-tarpaulin below don't have this problem: they are
# Rust binaries, not Go, so they carry no equivalent statically-embedded
# runtime to go stale.
# docker/cli deliberately ships a `vendor.mod`, not a `go.mod` -- its own
# build docs explain this keeps the CLI from being importable as a library
# dependency by other Go modules -- so a plain `go install .../cmd/docker@vX`
# does not work (the Go toolchain has no module file to resolve against).
# Cloning the tagged release (which ships its own complete vendor/ directory,
# so this needs no network access beyond the initial clone) and running its
# own `scripts/build/binary` reproduces upstream's exact official build. To
# bump the vendored grpc-go (same GHSA-hrxh-6v49-42gf CVE as buildx/compose
# below), `go get`/`go mod vendor` need an actual `go.mod` to detect the
# module root against -- `-modfile=vendor.mod` alone isn't enough, since Go
# still looks for a literal `go.mod` to establish the root before it will
# honor which *content* file to read/write. Symlinking `go.mod -> vendor.mod`
# (and `go.sum -> vendor.sum`) for the duration of the bump, then deleting
# the symlinks before `scripts/build/binary` runs, gives Go a real module
# root while still writing through to the real `vendor.mod`/`vendor.sum` the
# build actually uses -- confirmed working end-to-end (bump, re-vendor,
# build, run) against this exact tag.
# docker-compose is a normal Go-modules project, but its go.mod has `exclude`
# directives, which `go install pkg@version` rejects (it requires treating the
# target as if it were the main module, and `exclude` is only valid in a
# genuine main module) -- cloning and running a real local `go build` from
# within the checkout sidesteps that restriction.
# docker/buildx has neither the vendor.mod nor the exclude-directive problem
# (a plain go.mod, verified against its v0.35.0 tag), but it does need the
# containerd bump described above, which `go install pkg@version` has no way
# to apply (there is no go.mod in scope to `go get` against) -- so it is built
# the same clone-and-`go build` way as docker-compose below, not via a plain
# `go install` like actionlint. Its cmd package is named `buildx`, not
# `docker-buildx`, so the build output is named explicitly to match the
# `docker-<subcommand>` filename Docker's CLI plugin discovery requires.
# Unlike docker-compose, buildx's release tag ships a committed vendor/
# directory, which Go's toolchain auto-selects (`-mod=vendor`) whenever a
# vendor/modules.txt is present and go.mod's go directive is >= 1.14 -- `go
# get` alone only updates go.mod/go.sum, leaving vendor/modules.txt
# referencing the old containerd version, which then fails the build outright
# ("inconsistent vendoring") rather than silently using the wrong version.
# `go mod vendor` re-syncs vendor/ to the bumped go.mod before the build runs.
RUN set -euo pipefail; \
    GOBIN=/out go install "github.com/rhysd/actionlint/cmd/actionlint@v${ACTIONLINT_VERSION}"; \
    /out/actionlint --version; \
    buildx_src="$(mktemp -d)"; \
    git clone --depth 1 --branch "v${DOCKER_BUILDX_VERSION}" https://github.com/docker/buildx.git "$buildx_src"; \
    ( cd "$buildx_src" \
      && go get "github.com/containerd/containerd/v2@v${DOCKER_BUILDX_CONTAINERD_VERSION}" \
      && go get "google.golang.org/grpc@v${GRPC_GO_VERSION}" \
      && go get "golang.org/x/text@v${GOLANG_X_TEXT_VERSION}" \
      && go mod vendor \
      && go build -ldflags "-X github.com/docker/buildx/version.Version=v${DOCKER_BUILDX_VERSION}" -o /out/docker-buildx ./cmd/buildx ); \
    rm -rf "$buildx_src"; \
    /out/docker-buildx version; \
    docker_cli_src="$(go env GOPATH)/src/github.com/docker/cli"; \
    install -d "$(dirname "$docker_cli_src")"; \
    git clone --depth 1 --branch "v${DOCKER_CLI_VERSION}" https://github.com/docker/cli.git "$docker_cli_src"; \
    ( cd "$docker_cli_src" \
      && ln -s vendor.mod go.mod && ln -s vendor.sum go.sum \
      && go get "google.golang.org/grpc@v${GRPC_GO_VERSION}" \
      && go get "golang.org/x/text@v${GOLANG_X_TEXT_VERSION}" \
      && go mod vendor \
      && rm go.mod go.sum \
      && VERSION="${DOCKER_CLI_VERSION}" sh ./scripts/build/binary ); \
    install -m 0755 "$docker_cli_src/build/docker-$(go env GOOS)-$(go env GOARCH)" /out/docker; \
    rm -rf "$(go env GOPATH)/src/github.com"; \
    /out/docker --version; \
    compose_src="$(mktemp -d)"; \
    git clone --depth 1 --branch "v${DOCKER_COMPOSE_VERSION}" https://github.com/docker/compose.git "$compose_src"; \
    ( cd "$compose_src" \
      && go get "google.golang.org/grpc@v${GRPC_GO_VERSION}" \
      && go get "golang.org/x/text@v${GOLANG_X_TEXT_VERSION}" \
      && go build -ldflags "-X github.com/docker/compose/v5/internal.Version=${DOCKER_COMPOSE_VERSION}" -o /out/docker-compose ./cmd ); \
    rm -rf "$compose_src"; \
    /out/docker-compose version

FROM rust:latest

LABEL org.opencontainers.image.description="Prebuilt lancache-ng CI and developer validation toolchain image."

# What: bumps the source-built sccache pin to its current upstream release.
# Why: 0.17.0 adds an opt-in client-side architecture change that stays off
# by default (confirmed via upstream release notes); no config here enables
# it, so this is a routine version-currency bump only.
# From: Issue #1570
ARG SCCACHE_VERSION=0.17.0
ARG CARGO_AUDIT_VERSION=0.22.2
ARG CARGO_AUDIT_SHA256_AMD64=ab28a1bdb54db4d5d8ad5981cf1f959410370b3d28250dbd35f6a44248620e39
ARG CARGO_AUDIT_SHA256_ARM64=c6603814ddaa45e51263dafd31c0ac98808f688d26f7395804f9670b0fd599dd
# Verified against the live crates.io index during development of the coverage
# CI job (a plain `cargo install cargo-tarpaulin` resolved to this exact
# version); re-verify before bumping if this drifts from the latest release.
# What: bumps to the current upstream release and its real checksums.
# Why: both SHA256 values below were recomputed against the actual
# 0.37.1 release assets (not carried forward from 0.37.0) -- an
# unchanged checksum next to a bumped version number would silently
# break the build's own verification step.
# From: Issue #1570
ARG CARGO_TARPAULIN_VERSION=0.37.1
ARG CARGO_TARPAULIN_SHA256_AMD64=897731f07696af16ff725f90e718ac3fce4c5c3ca513945e4bc035ad2b7a89e0
ARG CARGO_TARPAULIN_SHA256_ARM64=3571a002bfc15c08e667523d7c97680f7e8281480029ee0cf739a0e8fef12343
ARG DISTCC_PUMP_PACKAGE_VERSION=3.4+really3.4-12
ARG SHELLSPEC_VERSION=0.28.1
ARG SHELLSPEC_SHA256=350d3de04ba61505c54eda31a3c2ee912700f1758b1a80a284bc08fd8b6c5992
ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV PATH="/usr/local/cargo/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin" \
    CARGO_INSTALL_ROOT="/usr/local" \
    RUST_BACKTRACE=1

# trixie-backports is the standard package source for every Debian-based image in
# this project (maintainer decision, 2026-07-30; see services/proxy/Dockerfile,
# the template this block is copied from) -- not a curl-only or package-scoped
# exception: `Package: *` at Pin-Priority 500 (tied with the regular trixie
# archive) applies project-wide, so ordinary version-comparison rules pick
# whichever archive/pocket has the newer version for ANY package this stage ever
# installs, not a hand-picked subset. `apt-get dist-upgrade` then `apt-get
# full-upgrade` are both run deliberately (a maintainer decision to keep both
# explicit, even though modern apt treats `full-upgrade` as the same operation
# `dist-upgrade` performs) so any package a newer archive/pocket has already
# patched gets picked up on every rebuild, not only whatever this Dockerfile's own
# `apt-get install` lists happen to name.
#
# Real bug this addresses (partially -- see the honest caveat below, do not
# overclaim): a real Trivy scan of this image (arm64 build, PR #1306's CI run,
# 2026-07-30T14:41Z) found libexpat1/libexpat1-dev HIGH findings --
# CVE-2025-59375, CVE-2026-25210, CVE-2026-45186, CVE-2026-56131,
# CVE-2026-56408 -- on the plain `rust:latest` base image's own pre-installed
# libexpat 2.7.1-2 (confirmed via `docker run --rm rust:latest dpkg -l | grep
# expat` on lancache-240: libexpat was never named in this Dockerfile's own
# install lists at all -- it arrived as a transitive dependency already baked
# into the upstream base image, which is exactly why a plain `apt-get install`
# with no upgrade step, as this stage previously had, never touched it).
#
# This RUN step does upgrade libexpat1/libexpat1-dev to 2.8.2-1~deb13u1
# (confirmed on lancache-240, 2026-07-30: both a fresh unmodified-Dockerfile
# build and this modified one resolve to 2.8.2-1~deb13u1 after `apt-get
# dist-upgrade`/`full-upgrade`, from Debian-Security/`trixie-security`, already
# a default source in the base image -- trixie-backports itself has no newer
# candidate for this specific package, so the project-wide backports pin isn't
# what supplies this particular fix, though it is still added unconditionally
# per the maintainer decision above, and is what will pick up a genuinely
# backports-only fix the next time one is needed).
#
# HONEST CAVEAT, do not re-simplify this to "fixed": PR #1306's CI run showed
# these 5 CVE IDs as `Status: fixed` / `FixedVersion: 2.8.2-1~deb13u1` at
# 2026-07-30T14:41Z. A real, twice-repeated Trivy scan against this exact
# rebuilt image on lancache-240, using a freshly downloaded vulnerability DB at
# 2026-07-30T15:19Z (roughly 40 minutes later), instead shows all 5 IDs as
# `Status: affected` / `FixedVersion: None` against the very same installed
# version, 2.8.2-1~deb13u1 -- i.e. the Debian Security Tracker data Trivy
# consumes was revised, in the time between those two scans, from "fixed in
# this version" to "still open, no fix in any pocket." This means: the version
# bump this RUN step performs is real and still worth having (it is a strictly
# newer, more current package either way), but it does NOT make these 5 CVE
# IDs disappear from a Trivy scan as of the more recent tracker data -- do not
# claim otherwise without re-running the same before/after scan this comment
# is based on. This is the exact same class of mistake already made and
# corrected once in services/proxy/Dockerfile's curl-CVE comment (a claimed
# fix that was never re-verified against a fresh scan) -- residual risk and
# the resulting maintainer decision are tracked in issue #1314 (mirroring
# #1304's structure for curl), not asserted as resolved here.
#
# The pin selector below MUST use `a=stable-backports`, not `a=trixie-backports`:
# APT's `a=`/release-Archive selector matches the Release file's `Suite:` field,
# and trixie-backports' own Release file declares `Suite: stable-backports` /
# `Codename: trixie-backports` -- the two are not interchangeable. This exact
# mistake was made and caught once already in services/proxy/Dockerfile: a first
# version of that pin used `a=trixie-backports` and silently matched nothing
# (apt-cache policy still showed backports at its Debian-default priority 100),
# so every "backports-sourced" package silently stayed on its vulnerable
# plain-trixie version despite the pin file being present -- caught only by
# building the image for real and checking an installed package version rather
# than trusting the Dockerfile comment. Do not repeat that here.
RUN echo "deb http://deb.debian.org/debian trixie-backports main" > /etc/apt/sources.list.d/backports.list \
    && printf 'Package: *\nPin: release a=stable-backports\nPin-Priority: 500\n' > /etc/apt/preferences.d/backports \
    && apt-get update \
    && apt-get dist-upgrade -y \
    && apt-get full-upgrade -y \
    && rm -rf /var/lib/apt/lists/*

# What: installs ccache from Debian's own package (not source-built).
# Why: caches the C-dependency compile step (`-sys` crates, e.g. `ring`) that
# distcc alone only distributes, never caches; sccache was ruled out for this
# same job because it always shells its own `-E` pass through `CC`,
# which crashes against a `,cpp`-tagged distcc host list, while ccache
# preprocesses locally by default; no per-feature trimming reason exists to
# source-build it the way sccache's own install below does.
# From: Issue #887
RUN set -euo pipefail; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      bash \
      bats \
      bc \
      build-essential \
      ca-certificates \
      ccache \
      clang \
      cmake \
      curl \
      expect \
      git \
      jq \
      libssl-dev \
      lld \
      make \
      pkg-config \
      shellcheck \
      xz-utils; \
    rm -rf /var/lib/apt/lists/*

# Keep sccache source-built and version-pinned: the official release binary's
# default feature set also bundles s3/memcached/gcs/azure/gha/webdav/oss/cos
# backends this project never uses, so building --no-default-features with
# only the two backends actually needed (Redis and sccache-dist client
# support) keeps the binary smaller and its dependency surface narrower.
RUN set -euo pipefail; \
    rustup component add rustfmt clippy; \
    cargo install sccache --version "${SCCACHE_VERSION}" --no-default-features --features redis,dist-client --root /usr/local; \
    for tool in cargo cargo-clippy cargo-fmt clippy-driver rustc rustdoc rustfmt rustup; do \
      ln -sf "/usr/local/cargo/bin/${tool}" "/usr/local/bin/${tool}"; \
    done; \
    rm -rf /usr/local/cargo/registry /usr/local/cargo/git

# cargo-audit and cargo-tarpaulin publish prebuilt release binaries and,
# unlike sccache, neither needs a non-default feature set -- so building
# them from source would only add build time for no behavioral difference.
# Fetch and checksum-verify the official release asset for each instead,
# matching the shellspec pattern below. actionlint, docker, docker-compose,
# and buildx are not included here -- see the actionlint-builder stage above
# for why those four are built from source instead.
RUN set -euo pipefail; \
    case "$(dpkg --print-architecture)" in \
      amd64) \
        cargo_audit_arch="x86_64-unknown-linux-gnu"; cargo_audit_sha256="${CARGO_AUDIT_SHA256_AMD64}"; \
        tarpaulin_arch="x86_64-unknown-linux-gnu"; tarpaulin_sha256="${CARGO_TARPAULIN_SHA256_AMD64}" \
        ;; \
      arm64) \
        cargo_audit_arch="aarch64-unknown-linux-gnu"; cargo_audit_sha256="${CARGO_AUDIT_SHA256_ARM64}"; \
        tarpaulin_arch="aarch64-unknown-linux-gnu"; tarpaulin_sha256="${CARGO_TARPAULIN_SHA256_ARM64}" \
        ;; \
      *) echo "Unsupported architecture for prebuilt CI tool binaries: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    prebuilt_tmp="$(mktemp -d)"; \
    trap 'rm -rf "$prebuilt_tmp"' EXIT; \
    curl -fsSL "https://github.com/rustsec/rustsec/releases/download/cargo-audit/v${CARGO_AUDIT_VERSION}/cargo-audit-${cargo_audit_arch}-v${CARGO_AUDIT_VERSION}.tgz" \
      -o "$prebuilt_tmp/cargo-audit.tgz"; \
    printf '%s  %s\n' "$cargo_audit_sha256" "$prebuilt_tmp/cargo-audit.tgz" | sha256sum -c -; \
    tar -xzf "$prebuilt_tmp/cargo-audit.tgz" -C "$prebuilt_tmp" "cargo-audit-${cargo_audit_arch}-v${CARGO_AUDIT_VERSION}/cargo-audit"; \
    install -m 0755 "$prebuilt_tmp/cargo-audit-${cargo_audit_arch}-v${CARGO_AUDIT_VERSION}/cargo-audit" /usr/local/cargo/bin/cargo-audit; \
    curl -fsSL "https://github.com/xd009642/tarpaulin/releases/download/${CARGO_TARPAULIN_VERSION}/cargo-tarpaulin-${tarpaulin_arch}.tar.gz" \
      -o "$prebuilt_tmp/cargo-tarpaulin.tar.gz"; \
    printf '%s  %s\n' "$tarpaulin_sha256" "$prebuilt_tmp/cargo-tarpaulin.tar.gz" | sha256sum -c -; \
    tar -xzf "$prebuilt_tmp/cargo-tarpaulin.tar.gz" -C "$prebuilt_tmp" cargo-tarpaulin; \
    install -m 0755 "$prebuilt_tmp/cargo-tarpaulin" /usr/local/cargo/bin/cargo-tarpaulin; \
    ln -sf /usr/local/cargo/bin/cargo-audit /usr/local/bin/cargo-audit; \
    ln -sf /usr/local/cargo/bin/cargo-tarpaulin /usr/local/bin/cargo-tarpaulin

COPY --from=actionlint-builder /out/actionlint /usr/local/bin/actionlint

RUN set -euo pipefail; \
    shellspec_tmp="$(mktemp -d)"; \
    trap 'rm -rf "$shellspec_tmp"' EXIT; \
    curl -fsSL "https://github.com/shellspec/shellspec/releases/download/${SHELLSPEC_VERSION}/shellspec-dist.tar.gz" \
      -o "$shellspec_tmp/shellspec-dist.tar.gz"; \
    printf '%s  %s\n' "${SHELLSPEC_SHA256}" "$shellspec_tmp/shellspec-dist.tar.gz" | sha256sum -c -; \
    tar -xzf "$shellspec_tmp/shellspec-dist.tar.gz" -C /opt; \
    ln -sf /opt/shellspec/shellspec /usr/local/bin/shellspec; \
    shellspec --version

# Built from source in the actionlint-builder stage above (see its comment):
# the official static binaries for docker/docker-compose carry a known,
# fixed-upstream Go stdlib CVE (confirmed via Trivy) that only a rebuild
# against a current Go toolchain resolves; buildx is built from source there
# too, as the same preventive measure (issue #787: the build-tools image
# lacked a `docker buildx` plugin at all, which broke setup.sh's
# assert_resolved_image_tag_platform_supported() platform check in CI).
RUN install -d /usr/local/lib/docker/cli-plugins
COPY --from=actionlint-builder /out/docker /usr/local/bin/docker
COPY --from=actionlint-builder /out/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
COPY --from=actionlint-builder /out/docker-buildx /usr/local/lib/docker/cli-plugins/docker-buildx
RUN docker --version; \
    docker compose version; \
    docker buildx version

# isc-dhcp-client (dhclient) is needed by
# scripts/dhcp-kea-lease-flow-simulation.sh (issue #448) and
# scripts/syslog-forwarding-simulation.sh to perform a real
# Discover/Offer/Request/Ack exchange against a Kea container on an isolated
# Docker bridge network, then read the resulting lease file's options.
# STATUS (updated by issue #1288): the Admin UI's own dhcp-probe container
# used to rely on this exact same binary for a separate, host-interface dry
# run (services/ui/dhcp-probe.sh) -- that usage was replaced by a native
# Rust DHCP client (services/ui/src/dhcp_probe_native.rs) with no dhclient
# dependency at all, so `isc-dhcp-client` is kept in THIS image solely for
# the two CI simulation scripts named above, which test Kea's own server
# behavior in an isolated test network and are a genuinely separate concern
# from the Admin UI's probe feature.
#
# tcpdump is needed by scripts/dhcp-proxy-pxe-simulation.sh (issue #705) to
# reliably capture dnsmasq's real DHCPOFFER reply to the synthetic PXE
# client's DHCPDISCOVER (option 60=PXEClient, option 93=client-system-
# architecture) -- something no ordinary DHCP client like dhclient can be
# made to send. The synthetic client itself is the Rust binary
# tools/pxe-client-probe (built from source by that script using this
# image's own Rust toolchain), which crafts and raw-sends the frame; capture
# goes through tcpdump writing to a pcap file rather than any live in-process
# sniff. Confirmed directly during this issue's investigation that an
# in-process live sniff missed real, verified-via-tcpdump replies from this
# exact dnsmasq build inside a Docker bridge network, for reasons not fully
# diagnosed (dnsmasq's replies here carry a deliberately unusual UDP
# checksum, flagged "bad" by tcpdump itself, which is one plausible cause).
# Reading the same reply back from a tcpdump-written pcap file is a separate,
# already-written-to-disk code path unaffected by that live-capture gap, and
# was confirmed reliable against the same real replies. (python3 below is NOT
# for this script -- it is required by distcc-pump; the former python3-scapy
# dependency was removed when the probe was rewritten from Python to Rust.)
#
# APT_CACHE_BUST (issue #1147): BuildKit's local/gha layer cache has no
# wall-clock expiry of its own, only cache-key (instruction text) expiry --
# once this RUN's resolved command text has been built once, every later
# build with the identical text reuses that same cached layer forever,
# including its `apt-get dist-upgrade -y`/`apt-get full-upgrade -y` below,
# regardless of how much time has passed or how many new Debian security
# fixes (e.g. #1147's bind9-libs/bind9-dnsutils/bind9-host CVEs) have shipped
# to trixie-security (or, since 2026-07-30, trixie-backports) since.
# Referencing the ARG here (CI passes a value that changes once per ISO
# week; see the workflows that build this image) makes this RUN's own cache
# key change on that same weekly cadence, forcing `apt-get update`/`apt-get
# dist-upgrade -y`/`apt-get full-upgrade -y` to actually re-run against the
# then-current archive instead of silently replaying a stale layer.
#
# Declared here, immediately before the one RUN step that uses it -- NOT up
# with the image's other ARGs near the top of this stage -- because of a
# real, confirmed BuildKit caching behavior: an ARG's declaration point, not
# just the instructions that actually expand it, affects cache-key
# computation for every instruction from that point onward in the same
# stage. Declaring this ARG earlier (verified empirically while building
# this fix: three separate real builds on a disposable-per-run Buildx
# builder, mirroring this project's actual CI cache handoff) caused
# unrelated, unchanged earlier layers -- the first `apt-get install`,
# sccache's `cargo install`, and the cargo-audit/tarpaulin fetch -- to
# needlessly re-run on every APT_CACHE_BUST change too, exactly the
# "unrelated layer" cache-busting this ARG must NOT cause. Keeping the
# declaration immediately adjacent to its only use confines the weekly
# cache-key change to this RUN step (and whatever follows it), leaving
# every earlier, still-valid layer above (through the docker/compose/buildx
# COPY steps and the docker-version-check RUN) cache-stable.
ARG APT_CACHE_BUST=""
RUN set -euo pipefail; \
    : "apt-cache-bust=${APT_CACHE_BUST}"; \
    distcc_pump_tmp=""; \
    cleanup_build_tools_apt() { \
        if [ -n "${distcc_pump_tmp}" ]; then rm -rf "${distcc_pump_tmp}"; fi; \
        rm -f /usr/sbin/invoke-rc.d; \
        if [ -x /usr/sbin/invoke-rc.d.real ]; then mv /usr/sbin/invoke-rc.d.real /usr/sbin/invoke-rc.d; fi; \
    }; \
    trap cleanup_build_tools_apt EXIT; \
    if [ -x /usr/sbin/invoke-rc.d ]; then mv /usr/sbin/invoke-rc.d /usr/sbin/invoke-rc.d.real; fi; \
    printf '%s\n' '#!/bin/sh' 'exit 0' > /usr/sbin/invoke-rc.d; \
    chmod +x /usr/sbin/invoke-rc.d; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      bind9-dnsutils \
      distcc \
      gettext-base \
      gnupg \
      iproute2 \
      isc-dhcp-client \
      openssl \
      procps \
      python3 \
      rsync \
      tcpdump; \
    # Base and tool packages can receive security fixes after the upstream
    # rust:latest image was published. Apply Debian upgrades before patching
    # distcc-pump so package updates cannot overwrite the warning fix below.
    # dist-upgrade + full-upgrade (not plain `upgrade`), matching the
    # project-wide backports-pin RUN step above -- a maintainer decision to
    # keep both explicit even though modern apt treats `full-upgrade` as the
    # same operation `dist-upgrade` performs, so this weekly APT_CACHE_BUST
    # re-run keeps picking up newly available fixes from either the regular
    # archive or trixie-backports, not just packages this RUN happens to name.
    apt-get dist-upgrade -y; \
    apt-get full-upgrade -y; \
    # linux-libc-dev is pulled in by the toolchain layer and can lag behind the
    # base image even after a generic upgrade; force the current security-fixed
    # package so Trivy does not fail the build-tools image on stale headers.
    # jq/libjq1 need the same treatment for a different reason: they are
    # installed by an earlier, non-cache-busted RUN step above (plain
    # `apt-get install`, no APT_CACHE_BUST reference), so once that layer is
    # cached it never re-resolves against a newer mirror snapshot on its own --
    # confirmed live (CVE-2026-32316, fixed in 1.7.1-6+deb13u3) by a real Trivy
    # scan flagging exactly the version that layer had cached. dist-upgrade/
    # full-upgrade above already re-run weekly and would normally pick this
    # up, but a fix published mid-week is not visible until the following
    # week's APT_CACHE_BUST value rotates (confirmed: 1.7.1-6+deb13u3 was
    # already resolvable from trixie-security when this was diagnosed, yet
    # the already-cached weekly layer still held 1.7.1-6+deb13u2). Naming
    # jq/libjq1 explicitly here forces this one build to pick up the fix
    # immediately rather than waiting for next week's rotation.
    apt-get install -y --no-install-recommends --only-upgrade linux-libc-dev jq libjq1; \
    distcc_pump_tmp="$(mktemp -d)"; \
    chmod 0755 "${distcc_pump_tmp}"; \
    chown _apt:root "${distcc_pump_tmp}"; \
    (cd "${distcc_pump_tmp}" && apt-get download "distcc-pump=${DISTCC_PUMP_PACKAGE_VERSION}"); \
    dpkg --unpack "${distcc_pump_tmp}"/distcc-pump_*.deb; \
    distcc_pump_parser="/usr/lib/python3/dist-packages/include_server/parse_command.py"; \
    grep -F "'-Wa,(%s\\.s)'" "${distcc_pump_parser}" >/dev/null; \
    grep -F "'-Wa,\\[(%s\\.s)\\]'" "${distcc_pump_parser}" >/dev/null; \
    # Debian distcc-pump 3.4+really3.4-12 ships invalid Python regex escapes.
    # Patch them before package configuration and compile with warnings as errors.
    sed -i \
      -e 's/%s\\.s/%s\\\\.s/g' \
      -e 's/-Wa,\\\[/-Wa,\\\\[/g' \
      -e 's/)\\\]/)\\\\]/g' \
      "${distcc_pump_parser}"; \
    grep -F "'-Wa,(%s\\\\.s)'" "${distcc_pump_parser}" >/dev/null; \
    grep -F "'-Wa,\\\\[(%s\\\\.s)\\\\]'" "${distcc_pump_parser}" >/dev/null; \
    python3 -Werror::SyntaxWarning -m py_compile "${distcc_pump_parser}"; \
    dpkg --configure distcc-pump; \
    python3 -Werror::SyntaxWarning -m compileall -q /usr/lib/python3/dist-packages/include_server; \
    rm -rf /var/lib/apt/lists/*

# musl cross-compilation target (issue #815): #815's services/ui OS-evaluation
# research proved live, on this same unmodified build-tools image
# (2026-07-31, runner lancache-240), that `apt-get install musl-tools
# musl-dev` (Debian trixie's own repo, 1.2.5-3.1~deb13u1) plus `rustup target
# add x86_64-unknown-linux-musl` builds services/ui's real crate --
# `rusqlite` with bundled sqlite3, `zstd`'s C library, and `reqwest`'s rustls
# backend on aws-lc-rs/aws-lc-sys all included, none of which is a
# hypothetical toy dependency -- into a working static-pie binary with no
# dynamic library dependencies. This RUN step makes that proven toolchain a
# permanent, additive part of the shared image so every consumer that wants
# to cross-compile to musl can do so without repeating the ad hoc apt-get/
# rustup steps #815's research already validated once. #815 explicitly
# recommends adding this once for both of its known consumers rather than
# duplicating the toolchain setup per-crate: services/ui (this PR's own
# network-verification build) and services/dns's nats-subscriber crate (its
# own musl retargeting is a separate, not-in-scope-here migration -- see that
# crate's own follow-up -- but must not be precluded by this image lacking
# the toolchain).
#
# Deliberately additive only: this does not touch the image's existing
# default glibc toolchain or target in any way. `rustup target add` only
# downloads and registers a second target's prebuilt std library alongside
# the one every other Rust build in this image already uses by default
# (confirmed via `rustc -vV`'s own `host:` line, which stays the `-gnu`
# triple; `rustup target list` itself has no `(default)` marker at all, only
# an `(installed)` one, so this Dockerfile's own verification below checks
# `rustc -vV` instead of relying on `rustup target list`'s text -- nothing
# here runs `rustup default` or passes `--target` anywhere else in this
# Dockerfile) -- an ordinary `cargo build`/`cargo test` invocation with no
# explicit `--target` flag is completely unaffected by this block, it only
# becomes available as an opt-in choice for a build that explicitly requests
# musl.
#
# Native-arch target only, mirroring the cargo-audit/cargo-tarpaulin
# architecture `case` block earlier in this stage: this image is built
# separately for linux/amd64 and linux/arm64 (AG-CI-010), and each build gets
# the musl target matching its own host architecture
# (x86_64-unknown-linux-musl on amd64, aarch64-unknown-linux-musl on arm64)
# rather than a cross target that would additionally need a cross-linker this
# image does not otherwise carry. A future consumer that specifically needs
# to cross-compile to the *other* architecture's musl target from this image
# would need to add that cross-linker explicitly first -- it is not silently
# assumed to already work here.
RUN set -euo pipefail; \
    case "$(dpkg --print-architecture)" in \
      amd64) musl_target="x86_64-unknown-linux-musl" ;; \
      arm64) musl_target="aarch64-unknown-linux-musl" ;; \
      *) echo "Unsupported architecture for musl cross-compilation target: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      musl-dev \
      musl-tools; \
    rustup target add "${musl_target}"; \
    rm -rf /var/lib/apt/lists/*

# This RUN's own tail below adds two musl-related checks (musl-gcc present,
# the native-arch musl target registered, glibc still the default host
# triple) alongside its existing required_tools verification. Both checks
# were first written as `<producer> | grep -q...` and failed a real build on
# lancache-240 with exit code 141 (SIGPIPE), not a logic error, and a real
# CI run on this PR reproduced the identical failure: `grep -q` exits as
# soon as it finds its first match, closing its end of the pipe early --
# since the producer (`rustc -vV`, `rustup target list --installed`) is
# still writing further lines at that moment (`host:` is not the last line
# of `rustc -vV`'s output), it receives SIGPIPE, and bash's `pipefail`
# reports that as the pipeline's exit status even though `grep` itself
# matched successfully. This is the same "early-exiting consumer piped from
# a still-writing producer under pipefail" failure shape as PR #1371's
# `find_built_ancestor()` (`git log | tail | head -n 50`), just a different
# consumer command -- fixed here by capturing each producer's full output
# into a shell variable first (a command substitution runs the producer to
# completion before the variable is even assigned, so there is no live pipe
# for an early exit to break) and grepping the variable via a here-string,
# rather than merely dropping `-q` from a live pipe (which also would have
# worked here, but leaves the same footgun available for the next person to
# reintroduce `-q` without knowing why that regresses). This Dockerfile's
# earlier distcc-pump-parser checks sidestep the whole class differently,
# by grepping a file (`grep -F ... "$file" >/dev/null`) rather than a live
# process's stdout, which never has a producer to send SIGPIPE to.
RUN set -euo pipefail; \
    required_tools=( \
      bash \
      bats \
      cargo \
      rustc \
      rustup \
      rustfmt \
      clippy-driver \
      sccache \
      cargo-audit \
      cargo-tarpaulin \
      actionlint \
      shellspec \
      shellcheck \
      jq \
      git \
      gpg \
      pkg-config \
      cmake \
      ar \
      awk \
      basename \
      cat \
      chgrp \
      chmod \
      chown \
      clang \
      c++ \
      ccache \
      cp \
      curl \
      dhclient \
      dig \
      dirname \
      distcc \
      distcc-pump \
      docker \
      dpkg \
      envsubst \
      expect \
      find \
      flock \
      getent \
      grep \
      gzip \
      install \
      ip \
      ld.lld \
      make \
      mkdir \
      mktemp \
      musl-gcc \
      mv \
      openssl \
      printf \
      ps \
      ranlib \
      rm \
      rsync \
      sed \
      sha256sum \
      sort \
      tar \
      tcpdump \
      tee \
      test \
      timeout \
      xargs \
      xz \
      cc \
      g++ \
    ); \
    for tool in "${required_tools[@]}"; do \
      command -v "$tool" >/dev/null; \
    done; \
    cargo --version; \
    rustc --version; \
    cargo fmt --version; \
    cargo clippy --version; \
    sccache --version; \
    ccache --version; \
    cargo audit --version; \
    cargo tarpaulin --version; \
    actionlint --version; \
    bats --version; \
    shellspec --version; \
    shellcheck --version; \
    docker --version; \
    docker compose version; \
    docker buildx version; \
    expect -v; \
    printf 'PATH=%s\n' "$PATH"; \
    case ":$PATH:" in \
      *:/usr/local/cargo/bin:*) ;; \
      *) echo "/usr/local/cargo/bin is missing from PATH" >&2; exit 1 ;; \
    esac; \
    bash -lc 'set -euo pipefail; cargo --version; rustc --version; rustfmt --version; cargo clippy --version'; \
    musl-gcc --version; \
    case "$(dpkg --print-architecture)" in \
      amd64) musl_target_check="x86_64-unknown-linux-musl" ;; \
      arm64) musl_target_check="aarch64-unknown-linux-musl" ;; \
      *) echo "Unsupported architecture for musl target verification: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    installed_targets="$(rustup target list --installed)"; \
    grep -qx "${musl_target_check}" <<<"${installed_targets}"; \
    rustc_host_line="$(rustc -vV)"; \
    grep -qE '^host: .*-gnu$' <<<"${rustc_host_line}"

WORKDIR /workspace

CMD ["bash"]
