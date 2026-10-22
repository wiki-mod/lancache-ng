# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# CI and developer validation toolchain with Rust, sccache, distcc, and build utilities.
#
# Intentional build-tools default: use rust:latest so developer and CI
# validation sees current Rust tooling early. Production service Dockerfiles
# stay separately pinned for reproducible runtime image builds.
#
# No tool in this image is compiled from Go source (AG-KD-003: native package
# first, then the official release artifact with a checksum, source build
# only when neither satisfies): docker CLI and docker compose come from the
# Debian packages, docker buildx and actionlint are the official release
# binaries, checksum-verified below.
FROM rust:latest

LABEL org.opencontainers.image.description="Prebuilt lancache-ng CI and developer validation toolchain image."

ARG ACTIONLINT_VERSION=1.7.12
ARG ACTIONLINT_SHA256_AMD64=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
ARG ACTIONLINT_SHA256_ARM64=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6
ARG DOCKER_BUILDX_VERSION=0.38.1
ARG DOCKER_BUILDX_SHA256_AMD64=e25d5cd675092bb5d1d03632fdc46cdf3fede7b514dc5f023a105e00d3ce5ad4
ARG DOCKER_BUILDX_SHA256_ARM64=3b83b3731916ba433feccaaa689fe5bcdc81c641d92c8e6c2ea865dfa141c97a
ARG SCCACHE_VERSION=0.18.0
ARG CARGO_AUDIT_VERSION=0.22.2
ARG CARGO_AUDIT_SHA256_AMD64=ab28a1bdb54db4d5d8ad5981cf1f959410370b3d28250dbd35f6a44248620e39
ARG CARGO_AUDIT_SHA256_ARM64=c6603814ddaa45e51263dafd31c0ac98808f688d26f7395804f9670b0fd599dd
# Verified against the live crates.io index during development of the coverage
# CI job (a plain `cargo install cargo-tarpaulin` resolved to this exact
# version); re-verify before bumping if this drifts from the latest release.
ARG CARGO_TARPAULIN_VERSION=0.37.5
ARG CARGO_TARPAULIN_SHA256_AMD64=affb00dc5e82582fb8124efb39233ee8318980c3136b27931684d2804d9e3a54
ARG CARGO_TARPAULIN_SHA256_ARM64=dcbdecd73903ac9071d61d2003ff0c82568edb676cff5a557b8be26d78ae896b
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

RUN set -euo pipefail; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      bash \
      bats \
      bc \
      build-essential \
      ca-certificates \
      clang \
      cmake \
      curl \
      docker-cli \
      docker-compose \
      expect \
      git \
      jq \
      libssl-dev \
      lld \
      make \
      parallel \
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
# matching the shellspec pattern below. actionlint and docker buildx are
# fetched the same way further down; docker and docker compose are Debian
# packages (see the apt install list above).
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

RUN set -euo pipefail; \
    case "$(dpkg --print-architecture)" in \
      amd64) actionlint_sha256="${ACTIONLINT_SHA256_AMD64}"; actionlint_arch="amd64" ;; \
      arm64) actionlint_sha256="${ACTIONLINT_SHA256_ARM64}"; actionlint_arch="arm64" ;; \
      *) echo "Unsupported architecture for actionlint: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    actionlint_tmp="$(mktemp -d)"; \
    trap 'rm -rf "$actionlint_tmp"' EXIT; \
    curl -fsSL "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_${actionlint_arch}.tar.gz" \
      -o "$actionlint_tmp/actionlint.tar.gz"; \
    printf '%s  %s\n' "$actionlint_sha256" "$actionlint_tmp/actionlint.tar.gz" | sha256sum -c -; \
    tar -xzf "$actionlint_tmp/actionlint.tar.gz" -C "$actionlint_tmp" actionlint; \
    install -m 0755 "$actionlint_tmp/actionlint" /usr/local/bin/actionlint; \
    actionlint --version

RUN set -euo pipefail; \
    shellspec_tmp="$(mktemp -d)"; \
    trap 'rm -rf "$shellspec_tmp"' EXIT; \
    curl -fsSL "https://github.com/shellspec/shellspec/releases/download/${SHELLSPEC_VERSION}/shellspec-dist.tar.gz" \
      -o "$shellspec_tmp/shellspec-dist.tar.gz"; \
    printf '%s  %s\n' "${SHELLSPEC_SHA256}" "$shellspec_tmp/shellspec-dist.tar.gz" | sha256sum -c -; \
    tar -xzf "$shellspec_tmp/shellspec-dist.tar.gz" -C /opt; \
    ln -sf /opt/shellspec/shellspec /usr/local/bin/shellspec; \
    shellspec --version

# docker CLI and docker compose are the Debian packages installed above.
# docker buildx is the official release binary: the Debian package
# (0.13.1) has no `imagetools create --prefer-index`, which promote and the
# build-tools workflow call (issue #787 added the buildx plugin to this image
# for setup.sh's assert_resolved_image_tag_platform_supported() platform
# check in CI). A plugin under /usr/local/lib/docker/cli-plugins wins over
# the packaged one in /usr/libexec/docker/cli-plugins.
RUN set -euo pipefail; \
    case "$(dpkg --print-architecture)" in \
      amd64) buildx_sha256="${DOCKER_BUILDX_SHA256_AMD64}"; buildx_arch="amd64" ;; \
      arm64) buildx_sha256="${DOCKER_BUILDX_SHA256_ARM64}"; buildx_arch="arm64" ;; \
      *) echo "Unsupported architecture for docker buildx: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    install -d /usr/local/lib/docker/cli-plugins; \
    buildx_tmp="$(mktemp -d)"; \
    trap 'rm -rf "$buildx_tmp"' EXIT; \
    curl -fsSL "https://github.com/docker/buildx/releases/download/v${DOCKER_BUILDX_VERSION}/buildx-v${DOCKER_BUILDX_VERSION}.linux-${buildx_arch}" \
      -o "$buildx_tmp/docker-buildx"; \
    printf '%s  %s\n' "$buildx_sha256" "$buildx_tmp/docker-buildx" | sha256sum -c -; \
    install -m 0755 "$buildx_tmp/docker-buildx" /usr/local/lib/docker/cli-plugins/docker-buildx
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
    apt-get install -y --no-install-recommends --only-upgrade linux-libc-dev; \
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
