
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# CI and developer validation toolchain with Rust, sccache, ccache, distcc, and build utilities.
#
# What: uses `rust:latest`/`golang:latest` as this image's base, unlike
# production service Dockerfiles.
# Why: developer and CI validation should see current Rust/Go tooling
# early; production service Dockerfiles stay separately pinned instead,
# for reproducible runtime image builds.
# From: Issue #1570 | PR #1571
# What: global ARG so the later utilities-tools FROM can use it.
# Why: an ARG used in a FROM must precede the file's first FROM to be
#   in scope there, matching dns/watchdog/ui's Dockerfiles.
# From: Issue #1095 | PR #1706
ARG UTILITIES_IMAGE=ghcr.io/wiki-mod/lancache-ng/utilities:latest
FROM golang:latest AS actionlint-builder

# What: shared version/security pins for both Go-tool build stages below.
# Why: actionlint-builder and actionlint-builder-alpine must not drift
# independently; two separate copies previously missed CVE overrides
# on the Alpine side (moby/go-archive, x/mod) and skewed on compose/grpc.
# From: Issue #1095 | Issue #1598
ARG ACTIONLINT_VERSION=1.7.12
ARG DOCKER_CLI_VERSION=29.7.2
ARG DOCKER_COMPOSE_VERSION=5.5.0
ARG DOCKER_BUILDX_VERSION=0.36.1
# What: pins buildx's vendored containerd/containerd/v2 dependency floor.
# Why: buildx releases lag a fixed containerd CVE before catching up
# (AG-KD-003); v0.36.1 floors at v2.3.3, so 2.3.4 stays one patch ahead.
# From: Issue #1570 | PR #1571
ARG DOCKER_BUILDX_CONTAINERD_VERSION=2.3.4
# What: pins buildx/compose/cli's vendored google.golang.org/grpc floor.
# Why: these tools repeatedly lag a fixed grpc-go CVE (AG-KD-003); all
# three floor at v1.82.1, so 1.83.1 keeps this current.
# From: Issue #1570 | PR #1571 | Issue #1598
ARG GRPC_GO_VERSION=1.83.1
# What: pins buildx/compose/cli's vendored golang.org/x/text floor.
# Why: same lagged-CVE pattern (AG-KD-003); all three floor at v0.40.0,
# so 0.41.0 keeps this current (actionlint has no x/text dependency).
# From: Issue #1570 | PR #1571
ARG GOLANG_X_TEXT_VERSION=0.41.0
# What: pins buildx's vendored github.com/moby/go-archive floor.
# Why: same lagged-CVE pattern (AG-KD-003); buildx v0.36.1 floors at the
# CVE-2026-17106-affected v0.2.1 (cli/compose already floor at v0.3.3).
# From: Issue #1598
ARG MOBY_GO_ARCHIVE_VERSION=0.3.3
# What: pins buildx/compose/cli's vendored golang.org/x/mod floor.
# Why: same lagged-CVE pattern (AG-KD-003); all three floor at v0.38.0
# (CVE-2026-56864/56865), so 0.40.0 -- the fix version -- stays current.
# From: Issue #1598
ARG GOLANG_X_MOD_VERSION=0.40.0

FROM golang:latest AS actionlint-builder

ARG ACTIONLINT_VERSION
ARG DOCKER_CLI_VERSION
ARG DOCKER_COMPOSE_VERSION
ARG DOCKER_BUILDX_VERSION
ARG DOCKER_BUILDX_CONTAINERD_VERSION
ARG GRPC_GO_VERSION
ARG GOLANG_X_TEXT_VERSION
ARG MOBY_GO_ARCHIVE_VERSION
ARG GOLANG_X_MOD_VERSION

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# What: builds actionlint/Docker CLI/docker-compose/buildx from source, with
# grpc-go/containerd/x-text/go-archive/x-mod vendor bumps applied via
# go.mod/vendor.mod swaps.
# Why: gets a current Go stdlib without waiting on upstream; each tool's own
# module quirks (vendor.mod-only, exclude directives) rule out `go install`.
# From: Issue #1570 | PR #1571 | Issue #1598
RUN set -euo pipefail; \
    GOBIN=/out go install "github.com/rhysd/actionlint/cmd/actionlint@v${ACTIONLINT_VERSION}"; \
    /out/actionlint --version; \
    buildx_src="$(mktemp -d)"; \
    git clone --depth 1 --branch "v${DOCKER_BUILDX_VERSION}" https://github.com/docker/buildx.git "$buildx_src"; \
    ( cd "$buildx_src" \
      && go get "github.com/containerd/containerd/v2@v${DOCKER_BUILDX_CONTAINERD_VERSION}" \
      && go get "google.golang.org/grpc@v${GRPC_GO_VERSION}" \
      && go get "golang.org/x/text@v${GOLANG_X_TEXT_VERSION}" \
      && go get "github.com/moby/go-archive@v${MOBY_GO_ARCHIVE_VERSION}" \
      && go get "golang.org/x/mod@v${GOLANG_X_MOD_VERSION}" \
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
      && go get "golang.org/x/mod@v${GOLANG_X_MOD_VERSION}" \
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
      && go get "golang.org/x/mod@v${GOLANG_X_MOD_VERSION}" \
      && go build -ldflags "-X github.com/docker/compose/v5/internal.Version=${DOCKER_COMPOSE_VERSION}" -o /out/docker-compose ./cmd ); \
    rm -rf "$compose_src"; \
    /out/docker-compose version

# What: source stage for the shared, statically-linked curl binary.
# Why: the same binary already used by proxy/dns/dhcp/ntp/ui is portable
# to a glibc host too (static, no dynamic curl dependency), so this image
# reuses it instead of Debian's own curl package. Mutable :latest tag per
# AG-KD-010, matching every other utilities consumer -- never digest-pin
# this image. UTILITIES_IMAGE is declared globally near the top of this
# file (required for use in a FROM), matching dns/watchdog/ui.
# From: Issue #1304 | Issue #1556 | Issue #1095 (AG-KD-010) | PR #1706
FROM ${UTILITIES_IMAGE} AS utilities-tools

# What: Alpine equivalent of actionlint-builder above (golang:alpine base).
# Why: kept as its own stage, not a conditional in the existing one, so
# the Debian stage above stays unchanged; opt-in only via `--target`.
# From: Issue #1095
FROM golang:alpine AS actionlint-builder-alpine

ARG ACTIONLINT_VERSION
ARG DOCKER_CLI_VERSION
ARG DOCKER_COMPOSE_VERSION
ARG DOCKER_BUILDX_VERSION
ARG DOCKER_BUILDX_CONTAINERD_VERSION
ARG GRPC_GO_VERSION
ARG GOLANG_X_TEXT_VERSION
ARG MOBY_GO_ARCHIVE_VERSION
ARG GOLANG_X_MOD_VERSION

SHELL ["/bin/sh", "-o", "pipefail", "-c"]

# What: builds the same four Go tools as actionlint-builder, on musl.
# Why: no cgo dependency in any of the four tools, so this needs no
# musl-specific build-tag or linker change versus the Debian stage.
# From: Issue #1095
RUN set -euo pipefail; \
    apk add --no-cache git build-base; \
    GOBIN=/out go install "github.com/rhysd/actionlint/cmd/actionlint@v${ACTIONLINT_VERSION}"; \
    /out/actionlint --version; \
    buildx_src="$(mktemp -d)"; \
    git clone --depth 1 --branch "v${DOCKER_BUILDX_VERSION}" https://github.com/docker/buildx.git "$buildx_src"; \
    ( cd "$buildx_src" \
      && go get "github.com/containerd/containerd/v2@v${DOCKER_BUILDX_CONTAINERD_VERSION}" \
      && go get "google.golang.org/grpc@v${GRPC_GO_VERSION}" \
      && go get "golang.org/x/text@v${GOLANG_X_TEXT_VERSION}" \
      && go get "github.com/moby/go-archive@v${MOBY_GO_ARCHIVE_VERSION}" \
      && go get "golang.org/x/mod@v${GOLANG_X_MOD_VERSION}" \
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
      && go get "golang.org/x/mod@v${GOLANG_X_MOD_VERSION}" \
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
      && go get "golang.org/x/mod@v${GOLANG_X_MOD_VERSION}" \
      && go build -ldflags "-X github.com/docker/compose/v5/internal.Version=${DOCKER_COMPOSE_VERSION}" -o /out/docker-compose ./cmd ); \
    rm -rf "$compose_src"; \
    /out/docker-compose version

# What: Alpine build-tools candidate stage, pinned to Alpine 3.24.
# Why: keeps Debian as `docker build`'s default (opt in via `--target
# alpine-final`); pinned because `clang22`/`lld22` below are release-
# specific names a later Alpine major could drop.
# From: Issue #1095
FROM rust:alpine3.24 AS alpine-final

LABEL org.opencontainers.image.description="Prebuilt lancache-ng CI and developer validation toolchain image (Alpine candidate)."

ARG SCCACHE_VERSION=0.17.0
ARG CARGO_AUDIT_VERSION=0.22.2
ARG CARGO_TARPAULIN_VERSION=0.37.1
ARG SHELLSPEC_VERSION=0.28.1
ARG SHELLSPEC_SHA256=350d3de04ba61505c54eda31a3c2ee912700f1758b1a80a284bc08fd8b6c5992

# What: uses plain /bin/sh (BusyBox ash) for the apk-install step only.
# Why: rust:alpine has no bash until the apk install below runs; SHELL
# switches to bash immediately after, for every step below it.
# From: Issue #1095
SHELL ["/bin/sh", "-c"]

ENV PATH="/usr/local/cargo/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin" \
    CARGO_INSTALL_ROOT="/usr/local" \
    RUST_BACKTRACE=1

# What: declares `APK_CACHE_BUST` right before the RUN step using it.
# Why: matches the `APT_CACHE_BUST` pattern below; an unrotated apk layer
# would replay indefinitely, missing Alpine security package updates.
# From: Issue #1095
ARG APK_CACHE_BUST=""

# What: installs bash, GNU coreutils, and this image's other apk packages.
# Why: Alpine's BusyBox applets differ from GNU behavior this project's
# scripts rely on (AG-VAL-034). `clang22`/`lld22` are Alpine 3.24's real
# package names, installing unversioned `clang`/`lld`/`ld.lld` binaries.
# From: Issue #1095
RUN set -euo pipefail; \
    : "apk-cache-bust=${APK_CACHE_BUST}"; \
    apk update; \
    apk upgrade --no-cache; \
    apk add --no-cache \
      bash \
      bats \
      bc \
      bind-tools \
      build-base \
      ca-certificates \
      ccache \
      clang22 \
      cmake \
      coreutils \
      curl \
      distcc \
      distcc-pump \
      expect \
      findutils \
      gawk \
      gettext \
      git \
      gnupg \
      grep \
      iproute2 \
      jq \
      lld22 \
      make \
      musl-dev \
      openssl \
      openssl-dev \
      openssl-libs-static \
      perl \
      pkgconf \
      procps-ng \
      python3 \
      rsync \
      sed \
      shellcheck \
      tcpdump \
      tzdata \
      util-linux \
      xz \
      zlib-dev \
      zlib-static; \
    ln -sf /usr/bin/pump /usr/bin/distcc-pump

# What: switches SHELL to bash for every RUN step from here on.
# Why: BusyBox ash cannot parse this file's bash-array/here-string RUN
# steps below; bash exists only after the apk install step above.
# From: Issue #1095
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# What: builds sccache from source, matching the Debian stage's features.
# Why: no prebuilt sccache release is used on either branch, so a native
# musl build behaves identically to the Debian glibc build.
# From: Issue #1095
RUN set -euo pipefail; \
    rustup component add rustfmt clippy; \
    cargo install sccache --version "${SCCACHE_VERSION}" --no-default-features --features redis,dist-client --root /usr/local; \
    for tool in cargo cargo-clippy cargo-fmt clippy-driver rustc rustdoc rustfmt rustup; do \
      ln -sf "/usr/local/cargo/bin/${tool}" "/usr/local/bin/${tool}"; \
    done; \
    rm -rf /usr/local/cargo/registry /usr/local/cargo/git

# What: builds cargo-audit/cargo-tarpaulin from source, not prebuilt.
# Why: the Debian stage's glibc release binaries do not run on musl
# (missing required glibc symbol versions); source build avoids that.
# From: Issue #1095
RUN set -euo pipefail; \
    cargo install cargo-audit --version "${CARGO_AUDIT_VERSION}" --locked --root /usr/local; \
    cargo install cargo-tarpaulin --version "${CARGO_TARPAULIN_VERSION}" --locked --root /usr/local

COPY --from=actionlint-builder-alpine /out/actionlint /usr/local/bin/actionlint

RUN set -euo pipefail; \
    shellspec_tmp="$(mktemp -d)"; \
    trap 'rm -rf "$shellspec_tmp"' EXIT; \
    curl -fsSL "https://github.com/shellspec/shellspec/releases/download/${SHELLSPEC_VERSION}/shellspec-dist.tar.gz" \
      -o "$shellspec_tmp/shellspec-dist.tar.gz"; \
    printf '%s  %s\n' "${SHELLSPEC_SHA256}" "$shellspec_tmp/shellspec-dist.tar.gz" | sha256sum -c -; \
    tar -xzf "$shellspec_tmp/shellspec-dist.tar.gz" -C /opt; \
    ln -sf /opt/shellspec/shellspec /usr/local/bin/shellspec; \
    shellspec --version

RUN install -d /usr/local/lib/docker/cli-plugins
COPY --from=actionlint-builder-alpine /out/docker /usr/local/bin/docker
COPY --from=actionlint-builder-alpine /out/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
COPY --from=actionlint-builder-alpine /out/docker-buildx /usr/local/lib/docker/cli-plugins/docker-buildx
RUN docker --version; \
    docker compose version; \
    docker buildx version

# What: no dhclient/isc-dhcp-client equivalent exists in Alpine 3.24.
# Why: only busybox-extras' udhcpc (a different implementation) is
# available; affects only two dhcp simulation scripts, documented, not
# silently dropped from required_tools.
# From: Issue #1095

# What: no separate musl cross-compile target step, unlike the Debian stage.
# Why: musl is already the default rustc host triple on this base image,
# asserted below via the same `rustc -vV` check the Debian stage uses.
# From: Issue #1095
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
      dig \
      dirname \
      distcc \
      distcc-pump \
      docker \
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
      mv \
      openssl \
      printf \
      ps \
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
    rustc_host_line="$(rustc -vV)"; \
    grep -qE '^host: .*-musl$' <<<"${rustc_host_line}"

WORKDIR /workspace

CMD ["bash"]

FROM rust:latest

LABEL org.opencontainers.image.description="Prebuilt lancache-ng CI and developer validation toolchain image."

# What: bumps the source-built sccache pin to its current upstream release.
# Why: sccache release notes occasionally add new behavior gated behind an
# opt-in flag; confirmed this bump enables nothing new by default before
# taking it, and the same check applies to any future bump too.
# From: Issue #1570 | PR #1571
# What: pins the source-built git version and its tarball checksum.
# Why: builds git from source, statically linked against a
# feature-reduced curl (below) instead of Debian's packaged git, which
# pulls in libcurl3t64-gnutls/libcurl4-gnutls via git-remote-https.
# From: Issue #1304 | Issue #1556
ARG GIT_VERSION=2.47.3
ARG GIT_SHA256=9c2eb1250781b3e5bfef098572d07fdf132d67e6c065e4307332ade9819a1501
# What: pins the curl release/checksum also used by services/utilities/Dockerfile,
#   rebuilt natively here for glibc (not that image's static musl lib).
# Why: verified against curl.se's advisories, all 4 tracked CVEs are fixed at
#   8.21.0 -- trixie-backports still flags them (not a Security-Tracker channel).
# From: Issue #1304 | Issue #1556
ARG CURL_VERSION=8.21.0
ARG CURL_SHA256=aa1b66a70eace83dc624508745646c08ae561de512ab403adffb93ac87fc72e6
ARG SCCACHE_VERSION=0.17.0
ARG CARGO_AUDIT_VERSION=0.22.2
ARG CARGO_AUDIT_SHA256_AMD64=ab28a1bdb54db4d5d8ad5981cf1f959410370b3d28250dbd35f6a44248620e39
ARG CARGO_AUDIT_SHA256_ARM64=c6603814ddaa45e51263dafd31c0ac98808f688d26f7395804f9670b0fd599dd
# What: pins cargo-tarpaulin's prebuilt release binary and its checksums.
# Why: SHA256 values are recomputed against each pinned version's actual
# release assets, not carried forward from the previous version -- an
# unchanged checksum next to a bumped version number would silently break
# the build's own verification step.
# From: Issue #1570 | PR #1571
ARG CARGO_TARPAULIN_VERSION=0.37.2
ARG CARGO_TARPAULIN_SHA256_AMD64=8e47625d26c3c265886faf1ef8cfa3ccaf071abc87bf4854ef8e239f5ffeabd8
ARG CARGO_TARPAULIN_SHA256_ARM64=c8cc929a259871cfe4e3cda6e31975abe33b9b0a6078b76cbd466b6494c72792
ARG DISTCC_PUMP_PACKAGE_VERSION=3.4+really3.4-12
ARG SHELLSPEC_VERSION=0.28.1
ARG SHELLSPEC_SHA256=350d3de04ba61505c54eda31a3c2ee912700f1758b1a80a284bc08fd8b6c5992
ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV PATH="/usr/local/cargo/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin" \
    CARGO_INSTALL_ROOT="/usr/local" \
    RUST_BACKTRACE=1

# What: adds trixie-backports as an apt source with a project-wide
# `Package: *` pin at Pin-Priority 500 (tied with the regular archive), then
# runs `apt-get dist-upgrade`/`full-upgrade` so any package either archive
# has already patched gets picked up on every rebuild -- including
# libexpat1/libexpat1-dev, a transitive dependency of the plain
# `rust:latest` base image never named in this Dockerfile's own install
# lists, which Trivy has repeatedly flagged with HIGH-severity CVEs.
# Why: this is the standard package-source pattern for every Debian-based
# image in this project (see services/proxy/Dockerfile), not a
# curl-only/package-scoped exception. The pin selector below MUST use
# `a=stable-backports`, not `a=trixie-backports` -- APT's `a=` selector
# matches the Release file's `Suite:` field, which trixie-backports
# declares as `stable-backports`; the codename alone silently matches
# nothing, leaving every "backports-sourced" package on its vulnerable
# plain-trixie version despite the pin file being present. Debian Security
# Tracker data for libexpat has flipped between "fixed" and "affected"
# once before without a package-version change (residual risk tracked in
# issue #1314) -- re-verify with a fresh Trivy scan before asserting its
# CVE status rather than trusting a comment's snapshot of it.
# From: Issue #1570 | PR #1571
RUN echo "deb http://deb.debian.org/debian trixie-backports main" > /etc/apt/sources.list.d/backports.list \
    && printf 'Package: *\nPin: release a=stable-backports\nPin-Priority: 500\n' > /etc/apt/preferences.d/backports \
    && apt-get update \
    && apt-get dist-upgrade -y \
    && apt-get full-upgrade -y \
    && rm -rf /var/lib/apt/lists/*

# What: installs ccache from Debian's own package (not source-built).
# Why: caches the C-dependency compile step (`-sys` crates, e.g. `ring`)
# that distcc alone only distributes, never caches. sccache (installed
# separately below) was ruled out for this specific job at the time this
# was written, because it shelled its own `-E` preprocessing pass through
# `CC` in a way that crashed against a `,cpp`-tagged distcc host list,
# while ccache preprocesses locally by default; re-verify against the
# sccache version pinned below before relying on this if sccache's
# preprocessing behavior is ever reconsidered for this job.
# From: Issue #1570 | PR #1571
#
# What: this same block also adds `sqlite3` (the CLI, not a library).
# Why: v1.2's GHCR retention-audit incremental cache reads
# and writes a small SQLite database from `scripts/lib/sha-retention-audit.sh`
# via the `sqlite3` command; `rusqlite`'s statically-linked SQLite inside the
# Admin UI Rust binary is a separate, unrelated build and provides no CLI.
# From: Issue #1585.
#
# What: purges git/git-man/curl before installing this image's own list
#   (excludes both); libssl-dev/zlib1g-dev are only the from-source builds' deps.
# Why: rust:latest already ships Debian's git/curl -- untouched by the
#   dist-upgrade above (which patches in place, never removes them).
# From: Issue #1304 | Issue #1556
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
      expect \
      gh \
      git \
      jq \
      libssl-dev \
      lld \
      make \
      pkg-config \
      shellcheck \
      sqlite3 \
      xz-utils \
      zlib1g-dev; \
      apt-get dist-upgrade -yy; \
      apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*

# What: curl comes from the shared utilities image instead of Debian's own package.
# Why: reuses the same statically-linked, feature-reduced binary already
#   shared by every other first-party image, rather than a separately-tracked,
#   more heavily-CVE'd Debian package.
# From: Issue #1304 | Issue #1556
COPY --from=utilities-tools /usr/local/bin/curl /usr/local/bin/curl
RUN curl --version >/dev/null

# What: builds sccache from source with --no-default-features, enabling
# only the redis and dist-client feature backends.
# Why: the official release binary's default feature set also bundles
# s3/memcached/gcs/azure/gha/webdav/oss/cos backends this project never
# uses; building only what's needed keeps the binary smaller and its
# dependency surface narrower.
# From: Issue #1570 | PR #1571
RUN set -euo pipefail; \
    rustup component add rustfmt clippy; \
    cargo install sccache --version "${SCCACHE_VERSION}" --no-default-features --features redis,dist-client --root /usr/local; \
    for tool in cargo cargo-clippy cargo-fmt clippy-driver rustc rustdoc rustfmt rustup; do \
      ln -sf "/usr/local/cargo/bin/${tool}" "/usr/local/bin/${tool}"; \
    done; \
    rm -rf /usr/local/cargo/registry /usr/local/cargo/git

# What: isc-dhcp-client (dhclient) supports
# scripts/untracked/simulations/dhcp-kea-lease-flow-simulation.sh and
# scripts/untracked/simulations/syslog-forwarding-simulation.sh, which perform a real
# Discover/Offer/Request/Ack exchange against a Kea container on an
# isolated Docker bridge network.
# Why: the Admin UI's own dhcp-probe feature now uses a native Rust DHCP
# client (services/ui/src/dhcp_probe_native.rs) with no dhclient
# dependency, so isc-dhcp-client is kept in this image solely for the two
# CI simulation scripts above, which test Kea's own server behavior and
# are a separate concern from the Admin UI's probe.
# From: Issue #1570 | PR #1571

# What: tcpdump supports scripts/untracked/simulations/dhcp-proxy-pxe-simulation.sh, capturing
# dnsmasq's real DHCPOFFER reply to a synthetic PXE DHCPDISCOVER
# (tools/pxe-client-probe, a Rust binary built from source by that script)
# to a pcap file rather than sniffing live in-process.
# Why: an in-process live sniff misses real replies from this dnsmasq
# build inside a Docker bridge network (plausibly because these replies
# carry a deliberately unusual UDP checksum tcpdump itself flags "bad");
# reading the same reply from a tcpdump-written pcap file is unaffected by
# that gap. python3 above is unrelated to this script -- it is required
# by distcc-pump.
# From: Issue #1570 | PR #1571

# What: declares `APT_CACHE_BUST` immediately before the one RUN step that
# references it (not with this stage's other ARGs near the top), forcing
# that RUN's BuildKit layer-cache key to change on a weekly cadence (CI
# passes a value that rotates once per ISO week).
# Why: BuildKit's cache has no wall-clock expiry, only cache-key (text)
# expiry, so an unreferenced ARG would let `apt-get dist-upgrade`/
# `full-upgrade` below replay a stale layer forever regardless of new
# Debian security fixes; an ARG's declaration point, not just where it's
# expanded, affects cache-key computation for every instruction after it
# in the same stage, so declaring it earlier (confirmed empirically, across
# real builds) needlessly busts unrelated, unchanged earlier layers on
# every rotation too.
# From: Issue #1570 | PR #1571
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
    # What: temporarily replaces /usr/sbin/invoke-rc.d with a no-op stub
    # for this RUN step, restored by the EXIT trap above.
    # Why: distcc-pump's package configuration below invokes service
    # management via invoke-rc.d, which has no real init system to act on
    # inside this container and would otherwise fail/hang `dpkg
    # --configure`; the original binary is restored so later RUN steps see
    # normal behavior.
    # From: Issue #1570 | PR #1571
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
    # What: runs dist-upgrade then full-upgrade before patching distcc-pump.
    # Why: base/tool packages can receive fixes after rust:latest was
    # published; applying upgrades first means later package updates
    # cannot overwrite the distcc-pump warning fix below. Both verbs are
    # kept explicit, matching the backports-pin RUN step above, even
    # though modern apt treats `full-upgrade` as the same operation
    # `dist-upgrade` performs.
    # From: Issue #1570 | PR #1571
    apt-get dist-upgrade -y; \
    apt-get full-upgrade -y; \
    # What: force-upgrades linux-libc-dev, jq, libjq1, libpq-dev, and libpq5 explicitly, beyond dist-upgrade/full-upgrade above.
    # Why: jq/libjq1 are confirmed transitively pulled in by an earlier, non-cache-busted
    #   apt-get install (CVE-2026-32316); libpq-dev/libpq5 hit the identical
    #   still-outdated-after-dist-upgrade symptom for CVE-2026-6473, though their own origin is not established here -- the same proven fix applies regardless.
    # From: Issue #1570 | PR #1571
    apt-get install -y --no-install-recommends --only-upgrade linux-libc-dev jq libjq1 libpq-dev libpq5; \
    distcc_pump_tmp="$(mktemp -d)"; \
    chmod 0755 "${distcc_pump_tmp}"; \
    # What: chowns the download temp dir to _apt:root before `apt-get
    # download` writes into it.
    # Why: `apt-get download` runs its actual fetch as the unprivileged
    # `_apt` user; a dir left owned by the build user would leave `_apt`
    # unable to write the downloaded .deb into it.
    # From: Issue #1570 | PR #1571
    chown _apt:root "${distcc_pump_tmp}"; \
    (cd "${distcc_pump_tmp}" && apt-get download "distcc-pump=${DISTCC_PUMP_PACKAGE_VERSION}"); \
    dpkg --unpack "${distcc_pump_tmp}"/distcc-pump_*.deb; \
    distcc_pump_parser="/usr/lib/python3/dist-packages/include_server/parse_command.py"; \
    grep -F "'-Wa,(%s\\.s)'" "${distcc_pump_parser}" >/dev/null; \
    grep -F "'-Wa,\\[(%s\\.s)\\]'" "${distcc_pump_parser}" >/dev/null; \
    # What: patches two invalid Python regex escapes in distcc-pump's own
    # parser before `dpkg --configure`, then compiles with warnings as
    # errors.
    # Why: Debian's distcc-pump 3.4+really3.4-12 package ships these
    # escapes as-is; compiling with `-Werror::SyntaxWarning` below would
    # otherwise fail package configuration on the unpatched file.
    # From: Issue #1570 | PR #1571
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
    distcc_bin="$(command -v distcc)"; \
    mkdir -p /usr/local/lib/distcc; \
    for wrapper in cc gcc c++ g++; do ln -sf "$distcc_bin" "/usr/local/lib/distcc/$wrapper"; done; \
    rm -rf /var/lib/apt/lists/*

# What: builds curl/git via a ccache-over-distcc cache, 3 fallback tiers.
# Why: sccache cannot compile C (AG-CI-022); mirrors services/dns and
#   services/utilities' proven pattern. Missing LAN-only secrets (fork
#   PRs, arm64/GitHub-hosted) degrade gracefully, never abort the build.
# From: Issue #1304 | Issue #1556 | PR #1661
RUN --mount=type=secret,id=distcc_potential_hosts \
    --mount=type=secret,id=ccache_redis_url \
    set -euo pipefail; \
    build_tmp="$(mktemp -d)"; \
    distcc_pump_running=0; \
    cleanup_curl_git_build() { \
      rm -rf "$build_tmp"; \
      if [ "$distcc_pump_running" = "1" ]; then distcc-pump --shutdown >/dev/null 2>&1 || true; fi; \
    }; \
    trap cleanup_curl_git_build EXIT; \
    curl -fsSL -o "$build_tmp/curl.tar.xz" "https://curl.se/download/curl-${CURL_VERSION}.tar.xz"; \
    printf '%s  %s\n' "$CURL_SHA256" "$build_tmp/curl.tar.xz" | sha256sum -c -; \
    curl -fsSL -o "$build_tmp/git.tar.xz" "https://www.kernel.org/pub/software/scm/git/git-${GIT_VERSION}.tar.xz"; \
    printf '%s  %s\n' "$GIT_SHA256" "$build_tmp/git.tar.xz" | sha256sum -c -; \
    distcc_enabled=0; \
    ccache_enabled=0; \
    original_path="$PATH"; \
    real_gcc="$(command -v gcc)"; \
    resolve_distcc_wrapper_dir() { \
      for candidate in /usr/local/lib/distcc /usr/lib/distcc; do \
        if [ -x "$candidate/cc" ] && [ -x "$candidate/gcc" ]; then \
          printf '%s\n' "$candidate"; \
          return 0; \
        fi; \
      done; \
      echo "distcc wrapper directory not found" >&2; \
      exit 1; \
    }; \
    extract_remote_toolchain_id() { \
      rm -f /tmp/ccache-remote-toolchain-id; \
      if command -v readelf >/dev/null 2>&1; then \
        readelf_comment_section="$(readelf -p .comment "$1" 2>/dev/null || true)"; \
        sed -n 's/^ *\[[^]]*\] *//p' <<<"$readelf_comment_section" > /tmp/ccache-remote-toolchain-id; \
      fi; \
    }; \
    disable_distcc() { \
      distcc_enabled=0; \
      unset DISTCC_POTENTIAL_HOSTS DISTCC_HOSTS DISTCC_FALLBACK; \
      PATH="$original_path"; export PATH; \
    }; \
    if [ -s /run/secrets/distcc_potential_hosts ]; then \
      distcc_probe_dir="$(mktemp -d)"; \
      DISTCC_POTENTIAL_HOSTS="$(cat /run/secrets/distcc_potential_hosts)"; export DISTCC_POTENTIAL_HOSTS; \
      distcc_wrapper_dir="$(resolve_distcc_wrapper_dir)"; \
      export PATH="$distcc_wrapper_dir:$PATH" DISTCC_FALLBACK=0; \
      if distcc_pump_env="$(distcc-pump --startup 2>"$distcc_probe_dir/pump.log")"; then \
        eval "$distcc_pump_env"; \
        distcc_pump_running=1; \
        printf '%s\n' 'int main(void) { return 0; }' > "$distcc_probe_dir/probe.c"; \
        if gcc -c "$distcc_probe_dir/probe.c" -o "$distcc_probe_dir/probe.o" >"$distcc_probe_dir/probe.log" 2>&1; then \
          distcc_enabled=1; \
          extract_remote_toolchain_id "$distcc_probe_dir/probe.o"; \
        else \
          echo "::notice::curl/git build: distcc probe compile failed; falling back to a plain, uncached compile." >&2; \
          disable_distcc; \
        fi; \
      else \
        echo "::notice::curl/git build: distcc-pump did not start (farm unreachable); falling back to a plain, uncached compile." >&2; \
        disable_distcc; \
      fi; \
      rm -rf "$distcc_probe_dir"; \
    else \
      echo "::notice::curl/git build: no distcc_potential_hosts secret; falling back to a plain, uncached compile." >&2; \
    fi; \
    if [ "$distcc_enabled" = "1" ] && [ -s /run/secrets/ccache_redis_url ]; then \
      if [ -s /tmp/ccache-remote-toolchain-id ]; then \
        ccache_probe_dir="$(mktemp -d)"; \
        ccache_redis_endpoint="$(cat /run/secrets/ccache_redis_url)"; \
        case "$ccache_redis_endpoint" in \
          redis://*|redis+unix:*) ;; \
          *) ccache_redis_endpoint="redis://$ccache_redis_endpoint" ;; \
        esac; \
        export CCACHE_REMOTE_STORAGE="$ccache_redis_endpoint" CCACHE_DIR=/tmp/ccache-build-tools-curl-git; \
        export CCACHE_PREFIX=distcc CCACHE_COMPILERCHECK=content; \
        export CCACHE_EXTRAFILES=/tmp/ccache-remote-toolchain-id CCACHE_BASEDIR="$build_tmp"; \
        printf '%s\n' 'int main(void) { return 0; }' > "$ccache_probe_dir/probe.c"; \
        if (cd "$ccache_probe_dir" && ccache "$real_gcc" -c probe.c -o probe.o) >"$ccache_probe_dir/probe.log" 2>&1 \
          && ccache --print-stats > "$ccache_probe_dir/stats.log" \
          && grep -qE '^remote_storage_(write|hit)[[:space:]]+[1-9]' "$ccache_probe_dir/stats.log" \
          && ! grep -qE '^remote_storage_error[[:space:]]+[1-9]' "$ccache_probe_dir/stats.log"; then \
          ccache_enabled=1; \
        else \
          echo "::notice::curl/git build: ccache_redis_url probe failed; using distcc alone (no cache)." >&2; \
          unset CCACHE_REMOTE_STORAGE CCACHE_DIR CCACHE_PREFIX CCACHE_COMPILERCHECK CCACHE_EXTRAFILES CCACHE_BASEDIR; \
        fi; \
        rm -rf "$ccache_probe_dir"; \
      else \
        echo "::notice::curl/git build: no verified remote distcc toolchain id; using distcc alone (no cache)." >&2; \
      fi; \
    elif [ "$distcc_enabled" = "1" ]; then \
      echo "::notice::curl/git build: no ccache_redis_url secret; using distcc alone (no cache)." >&2; \
    fi; \
    if [ "$ccache_enabled" = "1" ]; then \
      cc_wrapper="ccache $real_gcc"; \
    elif [ "$distcc_enabled" = "1" ]; then \
      cc_wrapper="gcc"; \
    else \
      cc_wrapper="$real_gcc"; \
      echo "::warning::curl/git build: distcc unavailable; compiling with no cache and no distribution at all (last line of defense before this build cannot compile)." >&2; \
    fi; \
    attempt_curl_git_build() { \
      rm -rf "$build_tmp/curl-${CURL_VERSION}" "$build_tmp/git-${GIT_VERSION}"; \
      tar -xJf "$build_tmp/curl.tar.xz" -C "$build_tmp"; \
      tar -xf "$build_tmp/git.tar.xz" -C "$build_tmp"; \
      ( cd "$build_tmp/curl-${CURL_VERSION}" \
        && ./configure \
          --disable-shared --enable-static \
          --disable-ftp --disable-file --disable-ldap --disable-ldaps \
          --disable-rtsp --disable-dict --disable-telnet --disable-tftp \
          --disable-pop3 --disable-imap --disable-smtp --disable-smb \
          --disable-gopher --disable-mqtt \
          --disable-scp --disable-sftp --without-libssh2 --without-libssh \
          --disable-ntlm --disable-kerberos-auth --disable-negotiate-auth \
          --disable-aws \
          --disable-manual --disable-libcurl-option \
          --disable-ipfs --disable-websockets \
          --without-librtmp --without-libidn2 --without-brotli --without-zstd \
          --without-nghttp2 --without-nghttp3 --without-ngtcp2 --without-libpsl \
          --with-openssl \
          --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
          --enable-http --enable-cookies --enable-ipv6 \
          CC="$cc_wrapper" \
        && make -j"$(nproc)" ) || return 1; \
      curl_src="$build_tmp/curl-${CURL_VERSION}"; \
      curl_libcurl="-Wl,-Bstatic -L${curl_src}/lib/.libs -lcurl -Wl,-Bdynamic -lssl -lcrypto -lz"; \
      ( cd "$build_tmp/git-${GIT_VERSION}" \
        && make -j"$(nproc)" prefix=/usr/local CC="$cc_wrapper" NO_TCLTK=YesPlease NO_GETTEXT=YesPlease \
          CURL_CFLAGS="-I${curl_src}/include" CURL_LIBCURL="$curl_libcurl" install ) || return 1; \
    }; \
    build_ok=0; \
    for tier in 1 2 3; do \
      if attempt_curl_git_build; then build_ok=1; break; fi; \
      if [ "$ccache_enabled" = "1" ]; then \
        echo "::notice::curl/git build: tier $tier (ccache-over-distcc) failed; retrying with plain distcc (no cache)." >&2; \
        unset CCACHE_REMOTE_STORAGE CCACHE_DIR CCACHE_PREFIX CCACHE_COMPILERCHECK CCACHE_EXTRAFILES CCACHE_BASEDIR; \
        ccache_enabled=0; cc_wrapper="gcc"; \
        distcc-pump --shutdown >/dev/null 2>&1 || true; \
        distcc_pump_running=0; \
        if distcc_pump_env="$(distcc-pump --startup 2>/dev/null)"; then \
          eval "$distcc_pump_env"; \
          distcc_pump_running=1; \
        else \
          echo "::notice::curl/git build: distcc-pump restart failed; retrying with a plain local compile." >&2; \
          disable_distcc; cc_wrapper="$real_gcc"; \
        fi; \
      elif [ "$distcc_enabled" = "1" ]; then \
        echo "::notice::curl/git build: tier $tier (distcc) failed; retrying with a plain local compile." >&2; \
        disable_distcc; cc_wrapper="$real_gcc"; \
      else \
        break; \
      fi; \
    done; \
    if [ "$build_ok" != "1" ]; then \
      echo "::error::curl/git build failed with no cache/distribution layer left to retry." >&2; \
      exit 1; \
    fi; \
    if [ "$ccache_enabled" = "1" ]; then \
      ccache -s; \
      ccache_final_stats="$(mktemp)"; \
      ccache --print-stats > "$ccache_final_stats"; \
      if grep -qE '^remote_storage_error[[:space:]]+[1-9]' "$ccache_final_stats"; then \
        echo "[INFO] ccache recorded a Redis remote-storage error during the real curl/git build; this build's binaries are already correct and unaffected, but the optional Redis cache layer degraded mid-build -- see services/dns/Dockerfile's identical diagnostic." >&2; \
        cat "$ccache_final_stats" >&2; \
      fi; \
      rm -f "$ccache_final_stats"; \
    fi; \
    rm -rf /tmp/ccache-build-tools-curl-git /tmp/ccache-remote-toolchain-id; \
    git --version; \
    git_remote_https="$(command -v git-remote-https || echo /usr/local/libexec/git-core/git-remote-https)"; \
    git_remote_https_ldd="$(ldd "$git_remote_https")"; \
    if grep -qi 'libcurl' <<<"$git_remote_https_ldd"; then \
      echo "::error::git-remote-https unexpectedly linked against a dynamic libcurl after a static-curl build." >&2; \
      exit 1; \
    fi; \
    git ls-remote https://github.com/git/git.git HEAD >/dev/null; \
    apt-get purge -y libssl-dev zlib1g-dev; \
    apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*; \
    for pkg in libcurl3t64-gnutls libcurl4-gnutls libcurl4-openssl-dev; do \
      if dpkg -s "$pkg" >/dev/null 2>&1; then \
        echo "::error::$pkg is still installed despite git no longer depending on any Debian curl/libcurl package -- investigate the new consumer before proceeding." >&2; \
        exit 1; \
      fi; \
    done; \
    dpkg -s libcurl4t64 >/dev/null 2>&1 \
      || { echo "::error::libcurl4t64 unexpectedly absent -- cmake's own real dependency on it (confirmed empirically: apt-get autoremove strips cmake if libcurl4t64 is purged) should keep it installed; investigate before proceeding." >&2; exit 1; }; \
    git --version; \
    git ls-remote https://github.com/git/git.git HEAD >/dev/null

# What: fetches and checksum-verifies prebuilt release binaries for
# cargo-audit and cargo-tarpaulin instead of building from source.
# Why: unlike sccache, neither needs a non-default feature set, so a
# source build would only add build time for no behavioral difference;
# actionlint/docker/docker-compose/buildx are built from source instead --
# see the actionlint-builder stage above for why.
# From: Issue #1570 | PR #1571
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

# What: copies docker/docker-compose/docker-buildx from the
# actionlint-builder stage above.
# Why: see that stage's own comments for why these are built from source
# rather than using official release binaries.
# From: Issue #1570 | PR #1571
RUN install -d /usr/local/lib/docker/cli-plugins
COPY --from=actionlint-builder /out/docker /usr/local/bin/docker
COPY --from=actionlint-builder /out/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
COPY --from=actionlint-builder /out/docker-buildx /usr/local/lib/docker/cli-plugins/docker-buildx
RUN docker --version; \
    docker compose version; \
    docker buildx version

# What: adds a permanent, shared musl-libc cross-compilation target to this
# image (Debian trixie's own musl-tools/musl-dev, 1.2.5-3.1~deb13u1, plus
# `rustup target add` for only this build's own host architecture,
# mirroring the cargo-audit/cargo-tarpaulin `case` block earlier in this
# stage).
# Why: proven by services/ui's real static-pie build (rusqlite/zstd/
# reqwest-on-aws-lc-rs all included) during issue #815's OS-evaluation
# research, so every musl consumer (services/ui, and separately
# services/dns's nats-subscriber) reuses this instead of repeating the same
# apt-get/rustup steps per crate; it only registers a second target's std
# library alongside the default (an ordinary build with no explicit
# `--target` is unaffected, confirmed via `rustc -vV`'s `host:` line
# staying the `-gnu` triple) and is native-arch only -- cross-compiling to
# the *other* architecture's musl target would additionally need a
# cross-linker this image does not carry.
# From: Issue #1570 | PR #1571
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

# What: captures `rustup target list --installed` and `rustc -vV` into
# shell variables first, then greps each variable via a here-string,
# rather than grepping their live stdout directly.
# Why: `grep -q` piped from a still-writing producer under `set -o
# pipefail` exits early on its first match and sends the producer SIGPIPE
# (exit 141) even though the match succeeded -- the same "early-exiting
# consumer piped from a still-writing producer" failure shape as PR
# #1371's `find_built_ancestor()`. Capturing full output first removes the
# live pipe an early exit could break; the distcc-pump-parser checks above
# sidestep the same class differently, by grepping a file rather than a
# live process's stdout.
# From: Issue #1570 | PR #1571
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
      gh \
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

# A generic default working directory for interactive/manual use of this
# image (e.g. a developer shelling in locally); CI callers never rely on
# it, since every CI invocation of this image explicitly bind-mounts the
# checked-out repository at /work and passes -w /work of its own accord.
WORKDIR /workspace

CMD ["bash"]
