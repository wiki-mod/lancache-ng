
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# Runtime health-check/restart daemon (compiled Rust binary) plus the
# separate file-retention sidecar entrypoint for lancache-ng containers.

# Intentional ARG default (overridable at build time via --build-arg).
# Actual digest pinning for release builds is tracked in issue #508.
ARG BUILD_TOOLS_IMAGE=ghcr.io/wiki-mod/lancache-ng/build-tools:latest
# What: declared here (meta-arg, before any FROM) so it is usable by the
#   utilities-tools stage's own FROM further down -- an ARG declared after
#   the first FROM is not visible to a later FROM's image reference at all.
# Why: same override contract as BUILD_TOOLS_IMAGE above (AG-KD-010).
# From: Issue #1095 | AG-KD-010
ARG UTILITIES_IMAGE=ghcr.io/wiki-mod/lancache-ng/utilities:latest
FROM ${BUILD_TOOLS_IMAGE} AS watchdog-builder

# What: verifies the build-tools contract (Rust toolchain, sccache, distcc,
# distcc-pump, musl cross target) is present before relying on any of it.
# Why: fail closed rather than a confusing mid-build "command not found" if
# the pinned build-tools image ever regresses this contract.
# From: Issue #842 (this file's own sole pointer for that number -- every
# other mention below refers to it by description, not by number, per
# AG-CODE-012)
#
# musl cross-compilation (issue #815 pattern, mirrored from
# services/dns/Dockerfile's identical nats-subscriber builder stage): the
# final stage below runs on Alpine (musl), so this binary must be
# musl-linked. tools/build-tools/Dockerfile already carries the native-arch
# musl target (x86_64-unknown-linux-musl on amd64,
# aarch64-unknown-linux-musl on arm64) and musl-tools/musl-dev, so no
# separate cross-linker setup is needed here -- resolving the target by
# `dpkg --print-architecture` mirrors that established pattern exactly
# rather than inventing a new one.
RUN set -eu; \
    for tool in cargo rustc rustup rustfmt clippy-driver sccache distcc distcc-pump python3 pkg-config; do \
      command -v "$tool" >/dev/null; \
    done; \
    command -v musl-gcc >/dev/null; \
    command -v ccache >/dev/null; \
    case "$(dpkg --print-architecture)" in \
      amd64) echo "x86_64-unknown-linux-musl" > /tmp/musl-target; ;; \
      arm64) echo "aarch64-unknown-linux-musl" > /tmp/musl-target; ;; \
      *) echo "Unsupported architecture for musl cross-compilation target: $(dpkg --print-architecture)" >&2; exit 1; ;; \
    esac; \
    # Captured into a variable first, then grepped via a here-string
    # (AG-VAL-032): a live pipe into `grep -qx` is the exact SIGPIPE-under-
    # pipefail shape already confirmed in this project's own CI failures.
    # This stage is `FROM ${BUILD_TOOLS_IMAGE}`, which sets
    # `SHELL ["/bin/bash", "-o", "pipefail", "-c"]` and a child Dockerfile
    # with no SHELL override inherits that, so a live pipe here would be
    # exploitable, not merely at theoretical risk.
    installed_musl_targets="$(rustup target list --installed)"; \
    grep -qx "$(cat /tmp/musl-target)" <<<"${installed_musl_targets}"; \
    distcc_bin="$(command -v distcc)"; \
    mkdir -p /usr/local/lib/distcc; \
    for wrapper in cc gcc c++ g++; do ln -sf "$distcc_bin" "/usr/local/lib/distcc/$wrapper"; done; \
    printf '%s\n' \
      '#!/bin/sh' \
      'case "${1:-}" in' \
      '  distcc|*/distcc) exec "$@" ;;' \
      '  *) exec /usr/local/bin/sccache "$@" ;;' \
      'esac' \
      > /usr/local/bin/lancache-rustc-wrapper; \
    chmod +x /usr/local/bin/lancache-rustc-wrapper

ARG CARGO_BUILD_JOBS=
# What: redeclares BUILD_TOOLS_IMAGE (already set pre-FROM above) so it is
# visible as a shell variable inside this stage's RUN block.
# Why: Docker ARG scoping requires a bare post-FROM redeclaration; the
# ccache toolchain-identity key below needs this value.
# From: Issue #842 (mirrors services/dns/Dockerfile, Issue #887)
ARG BUILD_TOOLS_IMAGE

WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src/ ./src/
# The shell functions below (configure_sccache/configure_distcc/
# disable_distcc/resolve_distcc_wrapper_dir/extract_remote_toolchain_id/
# configure_ccache/disable_ccache/resolve_cargo_jobs/run_cargo_build) are
# byte-identical in structure and intent to services/dns/Dockerfile's own
# nats-subscriber builder stage (the ccache-over-distcc pattern, AG-CI-022)
# -- see that file's own extensive inline documentation for the
# full reasoning behind each step (probe-then-commit accelerator selection,
# three-tier fallback, remote-toolchain-identity verification). Only the
# per-crate identifiers differ: SCCACHE_REDIS_KEY_PREFIX/CCACHE_DIR use
# "lancache-watchdog" instead of "lancache-dns", and the copied binary is
# this crate's own `lancache-watchdog`, not `nats-subscriber`.
# What: builds the release binary with sccache + ccache-over-distcc
# acceleration (AG-CI-004/005/007/022), falling back through plain distcc
# then a normal local compiler if either accelerator's live probe fails.
# Why: this crate pulls in `ring` (a real C-dependency compile) via
# reqwest's rustls-tls-native-roots feature, so it needs the exact same
# build-acceleration wiring dns/ui already have, per the 2026-08-07
# maintainer decision (acceleration required from day one).
# From: Issue #842 | Issue #887 (pattern origin)
# NOTE: comments cannot be embedded inside this block itself -- Docker's
# line-continuation strips the backslash-newline entirely, so a "#" comment
# ending in "\" would swallow every following continuation line as
# commented-out text instead of executable shell (verified empirically on
# services/dns/Dockerfile's identical block).
RUN --mount=type=secret,id=sccache_redis_url \
    --mount=type=secret,id=sccache_dist_config \
    --mount=type=secret,id=distcc_potential_hosts \
    --mount=type=secret,id=ccache_redis_url \
    set -eu; \
    musl_target="$(cat /tmp/musl-target)"; \
    distcc_enabled=0; \
    ccache_enabled=0; \
    original_path="$PATH"; \
    real_cc="$(PATH="$original_path" command -v cc)"; \
    real_gcc="$(PATH="$original_path" command -v gcc)"; \
    real_cxx="$(PATH="$original_path" command -v c++)"; \
    real_gxx="$(PATH="$original_path" command -v g++)"; \
    configure_sccache() { \
      if [ -s /run/secrets/sccache_redis_url ] || [ -s /run/secrets/sccache_dist_config ]; then \
        unset CARGO_MAKEFLAGS MAKEFLAGS; \
        export RUSTC_WRAPPER=/usr/local/bin/lancache-rustc-wrapper SCCACHE_REDIS_KEY_PREFIX=lancache-watchdog; \
        if [ -s /run/secrets/sccache_redis_url ]; then \
        SCCACHE_REDIS="$(cat /run/secrets/sccache_redis_url)"; export SCCACHE_REDIS; \
        fi; \
        if [ -s /run/secrets/sccache_dist_config ]; then \
          export SCCACHE_CONF=/run/secrets/sccache_dist_config; \
          sccache --dist-status; \
        fi; \
      else \
        echo "[INFO] sccache disabled (no sccache_redis_url or sccache_dist_config secret present)." >&2; \
      fi; \
    }; \
    disable_distcc() { \
      if [ "${distcc_enabled:-0}" = "1" ]; then distcc-pump --shutdown >/dev/null 2>&1 || true; fi; \
      distcc_enabled=0; \
      trap - EXIT; \
      unset DISTCC_POTENTIAL_HOSTS DISTCC_HOSTS DISTCC_FALLBACK CC GCC CXX GXX INCLUDE_SERVER_PORT INCLUDE_SERVER_PID; \
      PATH="$original_path"; \
      export PATH; \
    }; \
    resolve_distcc_wrapper_dir() { \
      for candidate in /usr/local/lib/distcc /usr/lib/distcc; do \
        if [ -x "$candidate/cc" ] && [ -x "$candidate/gcc" ] && [ -x "$candidate/c++" ] && [ -x "$candidate/g++" ]; then \
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
        readelf_comment_section="$(readelf -p .comment "$1" 2>/dev/null)"; \
        sed -n 's/^ *\[[^]]*\] *//p' <<<"$readelf_comment_section" > /tmp/ccache-remote-toolchain-id; \
      fi; \
    }; \
    configure_distcc() { \
      if [ -s /run/secrets/distcc_potential_hosts ]; then \
        distcc_probe_dir="$(mktemp -d)"; \
        DISTCC_POTENTIAL_HOSTS="$(cat /run/secrets/distcc_potential_hosts)"; export DISTCC_POTENTIAL_HOSTS; \
        echo "[INFO] trying distcc path." >&2; \
        distcc_wrapper_dir="$(resolve_distcc_wrapper_dir)"; \
        export PATH="$distcc_wrapper_dir:$PATH" CC=cc GCC=gcc CXX=c++ GXX=g++ DISTCC_FALLBACK=0; \
        if ! distcc_pump_env="$(distcc-pump --startup 2>"$distcc_probe_dir/distcc-pump.log")"; then \
          disable_distcc; \
          rm -rf "$distcc_probe_dir"; \
          echo "[INFO] distcc pump unavailable; continuing with normal local C compiler." >&2; \
          return 0; \
        fi; \
        eval "$distcc_pump_env"; \
        PATH="$distcc_wrapper_dir:$PATH"; \
        export PATH; \
        export CC=cc GCC=gcc CXX=c++ GXX=g++; \
        distcc_enabled=1; \
        trap 'distcc-pump --shutdown' EXIT; \
        printf '%s\n' 'int main(void) { return 0; }' > "$distcc_probe_dir/distcc-probe.c"; \
        if ! cc -c "$distcc_probe_dir/distcc-probe.c" -o "$distcc_probe_dir/distcc-probe.o" >"$distcc_probe_dir/distcc-probe.log" 2>&1; then \
          disable_distcc; \
          rm -rf "$distcc_probe_dir"; \
          echo "[INFO] distcc probe unavailable; continuing with normal local C compiler." >&2; \
          return 0; \
        fi; \
        extract_remote_toolchain_id "$distcc_probe_dir/distcc-probe.o"; \
        rm -rf "$distcc_probe_dir"; \
      else \
        echo "[INFO] distcc disabled (no distcc_potential_hosts secret present)." >&2; \
      fi; \
    }; \
    disable_ccache() { \
      ccache_enabled=0; \
      unset CCACHE_REMOTE_STORAGE CCACHE_DIR CCACHE_COMPILERCHECK CCACHE_PREFIX CCACHE_EXTRAFILES CCACHE_BASEDIR; \
      rm -f /tmp/ccache-toolchain-id /tmp/ccache-remote-toolchain-id; \
      export CC=cc GCC=gcc CXX=c++ GXX=g++; \
    }; \
    configure_ccache() { \
      if [ "${distcc_enabled:-0}" = "1" ] && [ -s /run/secrets/ccache_redis_url ]; then \
        if [ ! -s /tmp/ccache-remote-toolchain-id ]; then \
          echo "[INFO] no verified remote distcc toolchain identity available (the distcc probe's compiled object carried no readable .comment identity, or readelf is missing); continuing with plain distcc (no cache layer) rather than risk a stale cross-toolchain cache hit." >&2; \
          return 0; \
        fi; \
        ccache_probe_dir="$(mktemp -d)"; \
        echo "[INFO] wrapping distcc with ccache (Redis remote storage)." >&2; \
        ccache_redis_endpoint="$(cat /run/secrets/ccache_redis_url)"; \
        case "$ccache_redis_endpoint" in \
          redis://*|redis+unix:*) ;; \
          *) ccache_redis_endpoint="redis://$ccache_redis_endpoint" ;; \
        esac; \
        export CCACHE_REMOTE_STORAGE="$ccache_redis_endpoint"; \
        export CCACHE_DIR=/tmp/ccache-watchdog; \
        export CCACHE_PREFIX=distcc; \
        export CCACHE_COMPILERCHECK=content; \
        printf '%s' "$BUILD_TOOLS_IMAGE" > /tmp/ccache-toolchain-id; \
        export CCACHE_EXTRAFILES="/tmp/ccache-toolchain-id:/tmp/ccache-remote-toolchain-id"; \
        export CCACHE_BASEDIR="$ccache_probe_dir"; \
        export CC="ccache $real_cc" GCC="ccache $real_gcc" CXX="ccache $real_cxx" GXX="ccache $real_gxx"; \
        ccache_enabled=1; \
        printf '%s\n' 'int main(void) { return 0; }' > "$ccache_probe_dir/ccache-probe.c"; \
        if ! (cd "$ccache_probe_dir" && $CC -c ccache-probe.c -o ccache-probe.o) >"$ccache_probe_dir/ccache-probe.log" 2>&1; then \
          cat "$ccache_probe_dir/ccache-probe.log" >&2; \
          disable_ccache; \
          rm -rf "$ccache_probe_dir"; \
          echo "[INFO] ccache probe unavailable; continuing with plain distcc (no cache layer)." >&2; \
          return 0; \
        fi; \
        ccache_probe_stats="$ccache_probe_dir/ccache-probe-stats.log"; \
        ccache --print-stats > "$ccache_probe_stats"; \
        if grep -qE '^remote_storage_error[[:space:]]+[1-9]' "$ccache_probe_stats" \
          || ! grep -qE '^remote_storage_(write|hit)[[:space:]]+[1-9]' "$ccache_probe_stats"; then \
          cat "$ccache_probe_stats" >&2; \
          disable_ccache; \
          rm -rf "$ccache_probe_dir"; \
          echo "[INFO] ccache probe's Redis remote-storage round trip failed (neither a write nor a hit was recorded); continuing with plain distcc (no cache layer)." >&2; \
          return 0; \
        fi; \
        rm -rf "$ccache_probe_dir"; \
      else \
        if [ "${distcc_enabled:-0}" != "1" ]; then \
          echo "[INFO] ccache disabled (distcc is not enabled, so there is nothing to wrap)." >&2; \
        else \
          echo "[INFO] ccache disabled (no ccache_redis_url secret present)." >&2; \
        fi; \
      fi; \
    }; \
    resolve_cargo_jobs() { \
      jobs="${CARGO_BUILD_JOBS:-}"; \
      if [ -z "$jobs" ]; then \
        cores="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 2)"; \
        jobs=$((cores - 2)); \
        if [ "$jobs" -lt 4 ]; then jobs=4; fi; \
        jobs_source="auto-detected from $cores core(s)"; \
      else \
        jobs_source="explicit CARGO_BUILD_JOBS"; \
      fi; \
      case "$jobs" in ''|*[!0-9]*) echo "CARGO_BUILD_JOBS must be a positive integer" >&2; exit 1;; esac; \
      if [ "$jobs" -le 0 ]; then echo "CARGO_BUILD_JOBS must be greater than zero" >&2; exit 1; fi; \
      echo "[INFO] using $jobs job(s) ($jobs_source)." >&2; \
      printf '%s\n' "$jobs"; \
    }; \
    run_cargo_build() { \
      cargo_log="$(mktemp)"; \
      cargo_status_file="$(mktemp)"; \
      { set +e; cargo build -j "$cargo_jobs" --release --locked --target "$musl_target" 2>&1; echo "$?" >"$cargo_status_file"; set -e; } | tee "$cargo_log"; \
      cargo_status="$(cat "$cargo_status_file")"; \
      rm -f "$cargo_status_file"; \
      if [ "$cargo_status" = "0" ]; then rm -f "$cargo_log"; return 0; fi; \
      if [ "${ccache_enabled:-0}" = "1" ]; then \
        disable_ccache; \
        echo "[INFO] ccache build path unavailable; retrying with plain distcc (no cache layer)." >&2; \
        ccache_retry_status_file="$(mktemp)"; \
        { set +e; cargo build -j "$cargo_jobs" --release --locked --target "$musl_target" 2>&1; echo "$?" >"$ccache_retry_status_file"; set -e; } | tee -a "$cargo_log"; \
        cargo_status="$(cat "$ccache_retry_status_file")"; \
        rm -f "$ccache_retry_status_file"; \
        if [ "$cargo_status" = "0" ]; then \
          echo "[INFO] plain distcc fallback (ccache disabled) completed." >&2; \
          rm -f "$cargo_log"; \
          return 0; \
        fi; \
        echo "[INFO] plain distcc fallback also failed; falling through to full local-compiler retry." >&2; \
      fi; \
      if [ "${distcc_enabled:-0}" = "1" ]; then \
        disable_distcc; \
        unset RUSTC_WRAPPER SCCACHE_REDIS SCCACHE_CONF SCCACHE_REDIS_KEY_PREFIX; \
        echo "[INFO] distcc build path unavailable; retrying with normal local C compiler." >&2; \
        if cargo build -j "$cargo_jobs" --release --locked --target "$musl_target"; then \
          echo "[INFO] normal local C compiler fallback completed." >&2; \
          rm -f "$cargo_log"; \
          return 0; \
        fi; \
        rm -f "$cargo_log"; \
        return 1; \
      fi; \
      if grep -Eqi 'sccache: error|Fixed token mismatch|Timed out waiting for server startup|SCCACHE_' "$cargo_log"; then \
        unset RUSTC_WRAPPER SCCACHE_REDIS SCCACHE_CONF SCCACHE_REDIS_KEY_PREFIX; \
        echo "[INFO] sccache build path unavailable; retrying with sccache disabled." >&2; \
        rm -f "$cargo_log"; \
        if cargo build -j "$cargo_jobs" --release --locked --target "$musl_target"; then \
          echo "[INFO] sccache-disabled fallback completed." >&2; \
          return 0; \
        fi; \
        return 1; \
      fi; \
      echo "[ERROR] cargo build failed for reasons unrelated to sccache or distcc; not retrying." >&2; \
      rm -f "$cargo_log"; \
      return "$cargo_status"; \
    }; \
    configure_sccache; \
    configure_distcc; \
    configure_ccache; \
    cargo_jobs="$(resolve_cargo_jobs)"; \
    run_cargo_build; \
    if [ "${ccache_enabled:-0}" = "1" ]; then \
      ccache -s; \
      ccache_final_stats="$(mktemp)"; \
      ccache --print-stats > "$ccache_final_stats"; \
      if grep -qE '^remote_storage_error[[:space:]]+[1-9]' "$ccache_final_stats"; then \
        echo "[INFO] ccache recorded a Redis remote-storage error during the real Cargo build; this build's binary is already correct and unaffected, but the optional Redis cache layer degraded mid-build -- later builds may miss cache reuse until Redis recovers." >&2; \
        cat "$ccache_final_stats" >&2; \
      fi; \
      rm -f "$ccache_final_stats"; \
    fi; \
    cp "target/${musl_target}/release/lancache-watchdog" /build/lancache-watchdog-out

# What: source stage for tools copied into the final image below.
# Why: uses the mutable `:latest` tag -- see services/proxy/Dockerfile's
#   identical stage comment and AG-KD-010 for the full rationale.
# From: Issue #1095 | AG-KD-010
FROM ${UTILITIES_IMAGE} AS utilities-tools

FROM mirror.gcr.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

LABEL org.opencontainers.image.description="lancache-ng watchdog: compiled Rust health-check/restart daemon plus the separate file-retention sidecar entrypoint."

# `apk upgrade --no-cache` (before the package install, same layer) upgrades
# packages already baked into the alpine:3.24 base layer itself -- see
# services/dhcp-proxy/Dockerfile's identical comment/block for the full
# rationale and the real verification behind it.
# What: declares APT_CACHE_BUST right before the RUN it busts.
# Why: without this, BuildKit's cache has no wall-clock expiry and can
#   replay a stale `apk upgrade` forever; see tools/build-tools/Dockerfile's
#   identical ARG for the full rationale.
# From: Issue #1095
ARG APT_CACHE_BUST=""
RUN : "apt-cache-bust=${APT_CACHE_BUST}" && \
    apk upgrade --no-cache && \
    apk add --no-cache \
    bash \
    ca-certificates \
    coreutils \
    util-linux \
    nano \
    zstd
# What: bash/coreutils/util-linux/zstd/ca-certificates plus nano.
# Why: retention.sh (find -printf, realpath -m, stat -c, zstd) and
# retention-entrypoint.sh (setpriv, from util-linux) still ship as bash
# scripts in this same image -- see this file's own ENTRYPOINT comment
# below for why the health-monitor binary and the retention sidecar remain
# two different executables sharing one image. `jq` is dropped: the
# compiled Rust binary parses JSON via serde internally (never shells out
# to jq), and no remaining script in this image ever called it -- confirmed
# by grepping healthcheck.sh/retention.sh/retention-entrypoint.sh, whose
# only real tool usage is find/realpath/stat/zstd/setpriv. ca-certificates
# is a direct apk install here, not copied from the shared `utilities`
# image: the compiled
# binary's reqwest client uses rustls-tls-native-roots (Cargo.toml), which
# reads this image's own OS trust store, and a fresh apk-installed bundle
# stays current independently of whichever utilities-image version might
# otherwise be copied in.
# From: Issue #842 | Issue #1360 (retention.sh extraction) | Issue #1556
#
# What: curl/findutils/lsof/ripgrep come from the shared utilities image.
# Why: same alpine:3.24 digest as utilities; keep the duplicated common
# tools in one image instead of separately apk-installing them here too.
# From: Issue #1556
#
# What: removes the BusyBox symlinks at these paths before the real binaries land.
# Why: COPY follows an existing symlink target instead of replacing the link,
#   which would overwrite /bin/busybox and break later /bin/sh-based RUNs.
# From: Issue #1556
RUN rm -f /usr/bin/find /usr/bin/xargs /usr/bin/lsof

COPY --from=utilities-tools /usr/local/bin/curl /usr/local/bin/curl
COPY --from=utilities-tools /usr/bin/find /usr/bin/find
COPY --from=utilities-tools /usr/bin/xargs /usr/bin/xargs
COPY --from=utilities-tools /usr/bin/lsof /usr/bin/lsof
COPY --from=utilities-tools /usr/bin/rg /usr/bin/rg
COPY --from=utilities-tools /usr/lib/libgcc_s.so.1 /usr/lib/libgcc_s.so.1
COPY --from=utilities-tools /usr/lib/libpcre2-8.so.0* /usr/lib/
COPY --from=utilities-tools /usr/local/bin/verify-version-banner.sh /usr/local/bin/verify-version-banner.sh

# What: verifies the copied binaries actually run.
# Why: a missing shared-library dependency fails at exec time, not at COPY
# time; the lsof check is delegated to a shared script (see that file).
# From: Issue #1613 | Issue #1556
RUN set -euo pipefail; \
    find . -maxdepth 0 -printf '%f\n' >/dev/null; \
    rg --version >/dev/null; \
    curl --version >/dev/null; \
    sh /usr/local/bin/verify-version-banner.sh "lsof version information" lsof -v

# nano/lsof/ripgrep/curl: in-container troubleshooting tools -- see
# services/proxy/Dockerfile's identical comment for the full rationale.
ENV EDITOR=nano
ENV VISUAL=$EDITOR

COPY --from=watchdog-builder /build/lancache-watchdog-out /usr/local/bin/lancache-watchdog
COPY healthcheck.sh /healthcheck.sh
COPY retention.sh /retention.sh
COPY retention-entrypoint.sh /retention-entrypoint.sh
RUN chmod +x /healthcheck.sh /retention.sh /retention-entrypoint.sh
VOLUME ["/var/run/watchdog"]

# `lancache` account (Teil 2, 2026-08-01): fixed uid/gid 10001,
# matching services/ui/Dockerfile's own existing account of the same name.
# Only the `retention` compose service actually runs as this user (via
# retention-entrypoint.sh's root-to-lancache privilege drop); the plain
# `watchdog` service still runs as root, unchanged.
RUN addgroup -g 10001 lancache && \
    adduser -D -H -u 10001 -G lancache -s /sbin/nologin lancache && \
    mkdir -p /var/lib/lancache-retention-state && \
    chown lancache:lancache /var/lib/lancache-retention-state

# What: default ENTRYPOINT is now the compiled Rust binary, not the bash
# `watchdog.sh` script.
# Why: the 2026-08-07 maintainer decision authorized the ENTRYPOINT swap
# once the existing full-setup-deep-validate suite passes with this binary
# in place. `watchdog.sh` itself is removed from this image (no longer
# `COPY`'d in) but deliberately kept in the repository, unused, as a
# rollback-safety reference -- it has no remaining image caller:
# `deploy/*/docker-compose.yml`'s `watchdog` service `command:` overrides
# for prod/quickstart now `exec` this binary instead (see those files' own
# comments), and `deploy/full-setup` has no override at all, so it picks up
# this new default directly. The `retention` compose service continues to
# override this with `entrypoint: ["/retention-entrypoint.sh"]` (see
# deploy/*/docker-compose.yml's own `retention:` service block) -- both
# executables still ship in this one image so a single build serves either
# role, chosen entirely by which compose service invokes it.
# From: Issue #842
ENTRYPOINT ["/usr/local/bin/lancache-watchdog"]
