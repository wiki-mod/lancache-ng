
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# Runtime for lancache-warmer, the Steam cache-warming prefill daemon.
# Scaffold stage: builds and runs the credential-store and stream-fetch
# primitives only -- see services/warmer/src/main.rs's own module doc
# comment for what is deliberately not yet implemented.

# Intentional ARG default (overridable at build time via --build-arg).
# Actual digest pinning for release builds is tracked in issue #508 (same
# convention every other Rust service Dockerfile in this repo follows).
ARG BUILD_TOOLS_IMAGE=ghcr.io/wiki-mod/lancache-ng/build-tools:latest
FROM ${BUILD_TOOLS_IMAGE} AS warmer-builder

# What: verifies the build-tools contract (Rust toolchain, musl cross
#   target) is present before relying on any of it.
# Why: fail closed rather than a confusing mid-build "command not found"
#   if the pinned build-tools image ever regresses this contract.
# From: Issue #871
RUN set -eu; \
    for tool in cargo rustc rustup; do \
      command -v "$tool" >/dev/null; \
    done; \
    command -v musl-gcc >/dev/null; \
    case "$(uname -m)" in \
      x86_64) echo "x86_64-unknown-linux-musl" > /tmp/musl-target; ;; \
      aarch64) echo "aarch64-unknown-linux-musl" > /tmp/musl-target; ;; \
      *) echo "Unsupported architecture for musl cross-compilation target: $(uname -m)" >&2; exit 1; ;; \
    esac; \
    installed_musl_targets="$(rustup target list --installed)"; \
    grep -qx "$(cat /tmp/musl-target)" <<<"${installed_musl_targets}"

# What: deliberately NOT wired up in this PR: sccache/distcc/ccache build
#   acceleration (Rule-Ref: AG-CI-004/005/022), unlike
#   services/dns/Dockerfile, services/ui/Dockerfile, and
#   services/watchdog/Dockerfile's identical builder stages.
# Why: those wiring blocks are non-trivial, project-specific shell that
#   this PR's author could not build-test locally (no reachable Docker
#   daemon in the authoring environment -- see this PR's own body). Per
#   Rule-Ref: AG-CI-009, build acceleration is an optional CI/dev
#   optimization, never a functional requirement -- this crate builds
#   correctly without it, just without shared-cache speedup. Copying the
#   existing accelerated block by hand without any way to test it risked
#   a subtle, hard-to-debug CI failure for a marginal, deferrable benefit;
#   left as an explicit, named follow-up rather than silently shipped
#   either broken or absent with no explanation.
# From: Issue #871
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src/ ./src/
# What: exports CC/GCC/CXX/GXX explicitly before the build, matching
#   services/dns/Dockerfile, services/ui/Dockerfile, and
#   services/watchdog/Dockerfile's identical builder stages (every one of
#   their code paths, accelerated or not, sets these -- see each file's own
#   disable_distcc/disable_ccache fallback functions).
# Why: this crate pulls in `ring` (a real C-dependency compile) via
#   reqwest's rustls-tls feature, the same as those three crates' own
#   documented reason. On this image `cc`/`gcc` already default to
#   musl-targeting output (build-tools/Dockerfile's own comment: "musl is
#   already this image's default rustc triple"), so this export is
#   functionally a no-op today rather than a cross-compile requirement --
#   kept explicit anyway, matching the other three services' convention of
#   never relying on an implicit default for the C compiler a Rust build
#   script will invoke.
# From: Issue #871
RUN set -eu; \
    export CC=cc GCC=gcc CXX=c++ GXX=g++; \
    musl_target="$(cat /tmp/musl-target)"; \
    cargo build --release --locked --target "$musl_target"; \
    cp "target/${musl_target}/release/lancache-warmer" /build/lancache-warmer-out

FROM mirror.gcr.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

LABEL org.opencontainers.image.description="lancache-ng warmer: Steam cache-warming prefill daemon (scaffold, issue #871)."

# `apk upgrade --no-cache` (before the package install, same layer)
# upgrades packages already baked into the alpine:3.24 base layer itself
# -- see services/dhcp-proxy/Dockerfile's identical comment/block for the
# full rationale.
# What: declares APT_CACHE_BUST right before the RUN it busts.
# Why: without this, BuildKit's cache has no wall-clock expiry and can
#   replay a stale apk upgrade forever; see tools/build-tools/Dockerfile's
#   identical ARG for the full rationale.
# From: Issue #871
ARG APT_CACHE_BUST=""

# What: switches apk's own repositories to plain http.
# Why: Squid caches http; signed indices keep integrity.
# From: Issue #1095
RUN sed -i 's|^https://|http://|' /etc/apk/repositories

RUN : "apt-cache-bust=${APT_CACHE_BUST}" && \
    apk upgrade --no-cache && \
    apk add --no-cache ca-certificates
# ca-certificates: this crate's reqwest client uses plain rustls-tls
# (public webpki roots layered on top of this image's OS trust store is
# not needed the way services/watchdog's rustls-tls-native-roots choice
# is -- see services/warmer/Cargo.toml's own comment on that distinction),
# talking to Steam's public CDN over the public Internet CA chain.

COPY --from=warmer-builder /build/lancache-warmer-out /usr/local/bin/lancache-warmer

# Fixed uid/gid 10001, matching services/ui/Dockerfile's and
# services/watchdog/Dockerfile's existing `lancache` account of the same
# name/id -- this service never needs root (no privileged Docker/network
# operations, unlike watchdog's own restart/health-check duties).
RUN addgroup -g 10001 lancache && \
    adduser -D -H -u 10001 -G lancache -s /sbin/nologin lancache && \
    mkdir -p /data && \
    chown lancache:lancache /data
VOLUME ["/data"]
USER lancache

ENTRYPOINT ["/usr/local/bin/lancache-warmer"]
