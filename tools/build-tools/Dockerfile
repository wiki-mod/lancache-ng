
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
FROM golang:latest AS actionlint-builder

ARG ACTIONLINT_VERSION=1.7.12
ARG DOCKER_CLI_VERSION=29.7.2
ARG DOCKER_COMPOSE_VERSION=5.5.0
ARG DOCKER_BUILDX_VERSION=0.36.1
# What: pins buildx's vendored containerd/containerd/v2 dependency at or
# above buildx's own upstream go.mod floor.
# Why: earlier buildx releases have lagged a fixed containerd CVE class
# before catching up on their own (AGENTS.md AG-KD-003); buildx v0.36.1
# itself already floors at v2.3.3 (checked against that tag's go.mod), so
# 2.3.4 keeps this override one real patch ahead on the same line.
# From: Issue #1570 | PR #1571
ARG DOCKER_BUILDX_CONTAINERD_VERSION=2.3.4
# What: pins buildx/compose/cli's vendored google.golang.org/grpc dependency
# at or above their own go.mod/vendor.mod floor.
# Why: these tools' releases repeatedly lag a fixed grpc-go CVE before
# catching up (AG-KD-003); all three floor at v1.82.1, so 1.83.1 keeps this current.
# From: Issue #1570 | PR #1571 | Issue #1598
ARG GRPC_GO_VERSION=1.83.1
# What: pins buildx/compose/cli's vendored golang.org/x/text dependency at
# or above their own go.mod/vendor.mod floor (actionlint has no x/text
# dependency, so it needs no override).
# Why: same recurring lagged-CVE pattern as the grpc-go override above
# (AGENTS.md AG-KD-003); all three now floor at v0.40.0 themselves, so
# 0.41.0 -- the current upstream release -- keeps this override current.
# From: Issue #1570 | PR #1571
ARG GOLANG_X_TEXT_VERSION=0.41.0
# What: pins buildx's vendored github.com/moby/go-archive dependency (Docker
# CLI/compose already floor at v0.3.3, no override needed there).
# Why: same lagged-CVE pattern as the overrides above (AG-KD-003); buildx
# v0.36.1 floors at the CVE-2026-17106-affected v0.2.1.
# From: Issue #1598
ARG MOBY_GO_ARCHIVE_VERSION=0.3.3
# What: pins buildx/compose/cli's vendored golang.org/x/mod dependency.
# Why: same lagged-CVE pattern as the overrides above (AG-KD-003); all three
# floor at v0.38.0 (CVE-2026-56864/56865), so 0.40.0 -- the fix version --
# keeps this override current.
# From: Issue #1598
ARG GOLANG_X_MOD_VERSION=0.40.0

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
# Why: the same binary already used by proxy/dns/dhcp/ntp/ui (Issue #1556)
# is portable to a glibc host too (static, no dynamic curl dependency),
# so this image reuses it instead of Debian's own curl package.
# From: Issue #1304 | Issue #1556
FROM ghcr.io/wiki-mod/lancache-ng/utilities@sha256:718af4cf8f1352cee341e851cecb9821033de9a5c7804c64e1c6217b62c79186 AS utilities-tools

FROM rust:latest

LABEL org.opencontainers.image.description="Prebuilt lancache-ng CI and developer validation toolchain image."

# What: bumps the source-built sccache pin to its current upstream release.
# Why: sccache release notes occasionally add new behavior gated behind an
# opt-in flag; confirmed this bump enables nothing new by default before
# taking it, and the same check applies to any future bump too.
# From: Issue #1570 | PR #1571
# What: pins the source-built git version and its tarball checksum.
# Why: the Debian-packaged git pulls in libcurl3t64-gnutls/libcurl4-gnutls
# (transitively, via git-remote-https), which Trivy attributes 4 curl CVE
# IDs to independently of the curl CLI package (#1556's own investigation);
# building git from source against libcurl4-openssl-dev instead drops that
# dependency entirely, since no other package in this image needs it.
# From: Issue #1304 | Issue #1556
ARG GIT_VERSION=2.47.3
ARG GIT_SHA256=9c2eb1250781b3e5bfef098572d07fdf132d67e6c065e4307332ade9819a1501
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
# What: purges `git`/`git-man`/`curl` -- not just skips installing them --
# and only then installs this image's own package list, which excludes
# both; `libcurl4-openssl-dev`/`zlib1g-dev` are only git's from-source
# replacement's build deps (purged again once git is built).
# Why: `rust:latest` itself already ships Debian-packaged `git`/`curl`
# (confirmed live: rustup's own install needs them), so simply never
# naming them in this image's own install list is not sufficient -- the
# base image's copies, and the libcurl4-gnutls/libcurl3t64-gnutls chain
# git's `git-remote-https` pulls in, survive untouched otherwise, and the
# `dist-upgrade` step above only upgrades them in place rather than
# removing them. From: Issue #1304 | Issue #1556 (see the source-built
# git step and the utilities-tools COPY below this block).
RUN set -euo pipefail; \
    apt-get update; \
    apt-get purge -y git git-man curl; \
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
      jq \
      libcurl4-openssl-dev \
      libssl-dev \
      lld \
      make \
      pkg-config \
      shellcheck \
      sqlite3 \
      xz-utils \
      zlib1g-dev; \
    apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*

# What: curl comes from the shared utilities image instead of Debian's
# own curl package.
# Why: reuses the same statically-linked, feature-reduced binary already
# shipped to 5 other first-party images (Issue #1556), rather than
# reinstalling a separately-tracked, more heavily-CVE'd Debian package.
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

# What: builds git from source, linked against libcurl4-openssl-dev
# instead of Debian's packaged git (which pulls in libcurl4-gnutls via
# git-remote-https). Compiled through sccache, Redis-backed only once a
# real TCP probe confirms the Redis endpoint is actually reachable.
# Why: Trivy attributes 4 curl CVE IDs to libcurl4-gnutls regardless of
# the curl CLI package's own state (#1556); a bare unreachable
# SCCACHE_REDIS value hard-fails every single compile unit (sccache times
# out waiting for its own server to connect, confirmed empirically), so
# this must not be handed to sccache on faith.
# From: Issue #1304 | Issue #1556
RUN --mount=type=secret,id=sccache_redis_url \
    set -euo pipefail; \
    git_tmp="$(mktemp -d)"; \
    trap 'rm -rf "$git_tmp"' EXIT; \
    curl -fsSL -o "$git_tmp/git.tar.xz" "https://www.kernel.org/pub/software/scm/git/git-${GIT_VERSION}.tar.xz"; \
    printf '%s  %s\n' "$GIT_SHA256" "$git_tmp/git.tar.xz" | sha256sum -c -; \
    tar -xf "$git_tmp/git.tar.xz" -C "$git_tmp"; \
    if [ -s /run/secrets/sccache_redis_url ]; then \
      redis_url="$(cat /run/secrets/sccache_redis_url)"; \
      redis_hostport="${redis_url#redis://}"; redis_hostport="${redis_hostport#*@}"; redis_hostport="${redis_hostport%%/*}"; \
      redis_host="${redis_hostport%%:*}"; redis_port="${redis_hostport##*:}"; \
      if timeout 3 bash -c "exec 3<>/dev/tcp/${redis_host}/${redis_port}" 2>/dev/null; then \
        SCCACHE_REDIS="$redis_url"; export SCCACHE_REDIS; \
        export SCCACHE_REDIS_KEY_PREFIX=lancache-build-tools-git; \
      else \
        echo "[INFO] git build: sccache_redis_url secret present but ${redis_host}:${redis_port} did not accept a TCP connection within 3s; falling back to sccache's local disk cache." >&2; \
      fi; \
    else \
      echo "[INFO] git build: sccache running without Redis (no sccache_redis_url secret present)." >&2; \
    fi; \
    ( cd "$git_tmp/git-${GIT_VERSION}" \
      && make -j"$(nproc)" prefix=/usr/local CC="sccache gcc" NO_TCLTK=YesPlease NO_GETTEXT=YesPlease install ); \
    sccache --show-stats; \
    git --version; \
    git_remote_https="$(command -v git-remote-https || echo /usr/local/libexec/git-core/git-remote-https)"; \
    if ldd "$git_remote_https" | grep -q 'libcurl-gnutls'; then \
      echo "::error::git-remote-https unexpectedly linked against libcurl-gnutls after a from-source build." >&2; \
      exit 1; \
    fi; \
    ldd "$git_remote_https" | grep -q 'libcurl\.so' \
      || { echo "::error::git-remote-https did not link against libcurl.so.4 (OpenSSL variant) as expected." >&2; exit 1; }; \
    git ls-remote https://github.com/git/git.git HEAD >/dev/null; \
    if dpkg -s libcurl4-gnutls >/dev/null 2>&1; then \
      echo "::error::libcurl4-gnutls is installed despite git no longer depending on it -- investigate the new consumer before proceeding." >&2; \
      exit 1; \
    fi; \
    apt-get purge -y libcurl4-openssl-dev zlib1g-dev; \
    apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*; \
    git --version; \
    ldd "$git_remote_https" | grep -q 'libcurl\.so'

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
# that gap. python3 below is unrelated to this script -- it is required
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
    rm -rf /var/lib/apt/lists/*

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
