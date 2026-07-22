# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# CI and developer validation toolchain with Rust, sccache, distcc, and build utilities.
#
# Intentional build-tools default: use rust:latest so developer and CI
# validation sees current Rust tooling early. Production service Dockerfiles
# stay separately pinned for reproducible runtime image builds.
FROM golang:latest AS actionlint-builder

ARG ACTIONLINT_VERSION=1.7.12
ARG DOCKER_CLI_VERSION=29.6.1
ARG DOCKER_COMPOSE_VERSION=5.2.0
ARG DOCKER_BUILDX_VERSION=0.35.0
# buildx v0.35.0's go.mod pins github.com/containerd/containerd/v2 at v2.2.4,
# which carries three HIGH-severity CVEs (CVE-2026-53488/53489/53492) fixed in
# 2.2.5+ -- confirmed directly via Trivy scanning this image's first buildx
# build attempt. Unlike the docker/docker v28.5.2+incompatible case just below
# (no v29.x module tags exist at all, so that one genuinely cannot be bumped),
# containerd/containerd/v2 does publish a newer, non-breaking 2.2.x tag, so
# `go get` this exact module up to the fixed version before building instead
# of carrying the vulnerability forward.
ARG DOCKER_BUILDX_CONTAINERD_VERSION=2.2.6
# docker-buildx v0.35.0 and docker-compose v5.2.0 both pin
# google.golang.org/grpc at v1.81.1, which carries a HIGH-severity CVE
# (GHSA-hrxh-6v49-42gf, gRPC-Go xDS RBAC and HTTP/2 vulnerabilities) fixed
# in 1.82.1 -- confirmed via Trivy scanning this image (CI run 29926535995
# on PR #1070; tracked as issue #1080, the third confirmed instance of this
# CVE class per CLAUDE.md's AG-KD-003). Same reasoning as the containerd
# override above: neither project has cut a release that resolves this on
# its own yet, so `go get` the fixed version directly before building.
ARG GRPC_GO_VERSION=1.82.1

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
# own `scripts/build/binary` reproduces upstream's exact official build.
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
      && go mod vendor \
      && go build -ldflags "-X github.com/docker/buildx/version.Version=v${DOCKER_BUILDX_VERSION}" -o /out/docker-buildx ./cmd/buildx ); \
    rm -rf "$buildx_src"; \
    /out/docker-buildx version; \
    docker_cli_src="$(go env GOPATH)/src/github.com/docker/cli"; \
    install -d "$(dirname "$docker_cli_src")"; \
    git clone --depth 1 --branch "v${DOCKER_CLI_VERSION}" https://github.com/docker/cli.git "$docker_cli_src"; \
    ( cd "$docker_cli_src" && VERSION="${DOCKER_CLI_VERSION}" sh ./scripts/build/binary ); \
    install -m 0755 "$docker_cli_src/build/docker-$(go env GOOS)-$(go env GOARCH)" /out/docker; \
    rm -rf "$(go env GOPATH)/src/github.com"; \
    /out/docker --version; \
    compose_src="$(mktemp -d)"; \
    git clone --depth 1 --branch "v${DOCKER_COMPOSE_VERSION}" https://github.com/docker/compose.git "$compose_src"; \
    ( cd "$compose_src" \
      && go get "google.golang.org/grpc@v${GRPC_GO_VERSION}" \
      && go build -ldflags "-X github.com/docker/compose/v5/internal.Version=${DOCKER_COMPOSE_VERSION}" -o /out/docker-compose ./cmd ); \
    rm -rf "$compose_src"; \
    /out/docker-compose version

FROM rust:latest

LABEL org.opencontainers.image.description="Prebuilt lancache-ng CI and developer validation toolchain image."

ARG SCCACHE_VERSION=0.16.0
ARG CARGO_AUDIT_VERSION=0.22.2
ARG CARGO_AUDIT_SHA256_AMD64=ab28a1bdb54db4d5d8ad5981cf1f959410370b3d28250dbd35f6a44248620e39
ARG CARGO_AUDIT_SHA256_ARM64=c6603814ddaa45e51263dafd31c0ac98808f688d26f7395804f9670b0fd599dd
# Verified against the live crates.io index during development of the coverage
# CI job (a plain `cargo install cargo-tarpaulin` resolved to this exact
# version); re-verify before bumping if this drifts from the latest release.
ARG CARGO_TARPAULIN_VERSION=0.37.0
ARG CARGO_TARPAULIN_SHA256_AMD64=398ca437e9f2b2baee46ef9d3d03966112f03f2cce8b1655a8ba0b61cef08bff
ARG CARGO_TARPAULIN_SHA256_ARM64=d6ae06b7126fb44414dd65165f9aec9e330146513f709af69e6a7927093f277a
ARG DISTCC_PUMP_PACKAGE_VERSION=3.4+really3.4-12
ARG SHELLSPEC_VERSION=0.28.1
ARG SHELLSPEC_SHA256=350d3de04ba61505c54eda31a3c2ee912700f1758b1a80a284bc08fd8b6c5992
ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV PATH="/usr/local/cargo/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin" \
    CARGO_INSTALL_ROOT="/usr/local" \
    RUST_BACKTRACE=1

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
# scripts/dhcp-kea-lease-flow-simulation.sh (issue #448) to perform a real
# Discover/Offer/Request/Ack exchange against a Kea container on an isolated
# Docker bridge network, then read the resulting lease file's options. This
# is the same client binary services/ui/dhcp-probe.sh already uses for its
# own (separate, host-interface) dry-run check -- reusing it here keeps the
# project to one DHCP client implementation instead of two.
#
# python3-scapy + tcpdump are needed by
# scripts/dhcp-proxy-pxe-simulation.sh (issue #705) to craft a synthetic
# PXE client's DHCPDISCOVER (option 60=PXEClient, option 93=client-system-
# architecture) -- something no ordinary DHCP client like dhclient can be
# made to send -- and to reliably capture dnsmasq's real DHCPOFFER reply.
# Capture goes through tcpdump writing to a pcap file rather than scapy's
# own live-sniff path (srp1/sniff): confirmed directly during this issue's
# investigation that scapy's live sniff missed real, verified-via-tcpdump
# replies from this exact dnsmasq build inside a Docker bridge network,
# for reasons not fully diagnosed (dnsmasq's replies here carry a
# deliberately unusual UDP checksum, flagged "bad" by tcpdump itself,
# which is one plausible cause). Reading the same reply back from a
# tcpdump-written pcap file with scapy's offline rdpcap() is a separate,
# already-written-to-disk code path unaffected by that live-capture gap,
# and was confirmed reliable against the same real replies.
RUN set -euo pipefail; \
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
      python3-scapy \
      rsync \
      tcpdump; \
    # Base and tool packages can receive security fixes after the upstream
    # rust:latest image was published. Apply Debian upgrades before patching
    # distcc-pump so package updates cannot overwrite the warning fix below.
    apt-get upgrade -y; \
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
    # python3-scapy has no standalone binary worth checking via command -v
    # (Debian's package does ship a `scapy` console script, but
    # scripts/dhcp-proxy-pxe-simulation.sh only ever needs the importable
    # module) -- verify the actual thing that script depends on instead.
    python3 -c 'import scapy.all'; \
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
    bash -lc 'set -euo pipefail; cargo --version; rustc --version; rustfmt --version; cargo clippy --version'

WORKDIR /workspace

CMD ["bash"]
