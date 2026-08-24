# syntax=docker/dockerfile:1
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Multi-stage build for the Admin UI service. The builder stage compiles the
# Rust binary against the shared build-tools image, opportunistically
# accelerating the build with sccache and/or distcc when the corresponding
# BuildKit secrets are present (falling back to a plain local build
# otherwise). The runtime stage is a minimal Alpine image (issue #815) that
# only carries the compiled binary, its Tera templates, and the entrypoint
# script.

# Intentional ARG default (overridable at build time via --build-arg).
# Actual digest pinning for release builds is tracked in issue #508.
ARG BUILD_TOOLS_IMAGE=ghcr.io/wiki-mod/lancache-ng/build-tools:latest
FROM ${BUILD_TOOLS_IMAGE} AS builder

# The shared build-tools image already carries the Rust toolchain, sccache,
# distcc, distcc-pump, and the supporting Debian packages. Keep this stage
# lean and fail closed if the contract is not met.
#
# musl cross-compilation target (issue #815): the runtime stage below now
# runs on an Alpine (musl) base, so this binary must be musl-linked, not the
# glibc-linked binary a plain build-tools-image build would produce.
# tools/build-tools/Dockerfile (#815, PR #1374) already added musl-tools/
# musl-dev and a rustup target matching this image's own host architecture
# (x86_64-unknown-linux-musl on amd64, aarch64-unknown-linux-musl on arm64)
# -- the native-arch target only, no separate cross-linker needed. Resolving
# the target via `dpkg --print-architecture` into a file mirrors the exact
# pattern services/dns/Dockerfile's nats-subscriber builder already
# established for the identical problem, rather than inventing a new one --
# see that file's own comments for the full empirical verification history.
# Written to /tmp/musl-target (not a shell variable) because Docker RUN
# layers do not share shell state; every later RUN in this stage re-reads it.
#
# Everything below builds a custom distcc wrapper. It exists because
# distcc-pump preprocesses every `#include` locally before sending the job to
# a remote host, and the `aws-lc-sys` crate (a transitive TLS dependency)
# writes generated C headers into its own Cargo build/target directory at
# build time. distcc-pump's header discovery cannot see files that don't
# exist until the build is already underway, so pump-mode compilation of
# those specific translation units fails. The wrapper below detects an
# aws-lc-sys generated-header include path in the compiler arguments and, for
# just that case, routes the job to a non-pump distcc host (or the local
# compiler if none is configured) instead of letting it go through pump mode
# and fail.
#
# What: the wrapper also understands ccache's CCACHE_PREFIX convention
#   (invoked as `distcc <real-compiler-path> <args>`), alongside $0-basename.
# Why: without this, $0=="distcc" fell through to a hardcoded "cc" default
#   and re-passed $1 as a stray positional argument, corrupting the compile.
# From: Issue #1533 | Refs #887
RUN set -eu; \
    for tool in cargo rustc rustup rustfmt clippy-driver sccache distcc distcc-pump python3 pkg-config; do \
      command -v "$tool" >/dev/null; \
    done; \
    command -v musl-gcc >/dev/null; \
    case "$(dpkg --print-architecture)" in \
      amd64) echo "x86_64-unknown-linux-musl" > /tmp/musl-target; ;; \
      arm64) echo "aarch64-unknown-linux-musl" > /tmp/musl-target; ;; \
      *) echo "Unsupported architecture for musl cross-compilation target: $(dpkg --print-architecture)" >&2; exit 1; ;; \
    esac; \
    # Captured into a variable first, then grepped via a here-string
    # (AG-VAL-032): a live `rustup target list --installed | grep -qx`
    # pipe is the exact SIGPIPE-under-pipefail shape confirmed in a real CI
    # failure for tools/build-tools/Dockerfile's identical check. This RUN
    # block's own `set -eu` doesn't mention pipefail, but this stage is
    # `FROM ${BUILD_TOOLS_IMAGE}` (see the top of this file), which sets
    # `SHELL ["/bin/bash", "-o", "pipefail", "-c"]` -- Docker persists a
    # base image's SHELL as that image's `Config.Shell`, and a child
    # Dockerfile with no `SHELL` instruction of its own inherits that
    # config as its default (confirmed empirically: a plain `FROM` with no
    # override reports the parent's `Config.Shell`, not Docker's hardcoded
    # `/bin/sh -c`). This RUN block was therefore already exploitable, not
    # merely at risk of becoming exploitable later.
    installed_musl_targets="$(rustup target list --installed)"; \
    grep -qx "$(cat /tmp/musl-target)" <<<"${installed_musl_targets}"; \
    distcc_bin="$(command -v distcc)"; \
    distcc_real_bin="/usr/local/bin/distcc-real"; \
    cp "$distcc_bin" "$distcc_real_bin"; \
    printf '%s\n' \
      '#!/bin/sh' \
      'set -eu' \
      'distcc_real="/usr/local/bin/distcc-real"' \
      'wrapper_self="/usr/local/bin/lancache-distcc-wrapper"' \
      'wrapper_dir="/usr/local/lib/distcc"' \
      'compiler_name="$(basename "$0")"' \
      'case "$compiler_name" in' \
      '  cc|gcc|c++|g++)' \
      '    real_compiler="$compiler_name"' \
      '    local_compiler="/usr/bin/$real_compiler"' \
      '    ;;' \
      '  *)' \
      '    if [ "$#" -ge 1 ] && [ -x "${1:-}" ]; then' \
      '      resolved_arg1="$(readlink -f "$1" 2>/dev/null || printf "%s" "$1")"' \
      '      case "$resolved_arg1" in' \
      '        "$wrapper_self"|"$wrapper_dir"/*)' \
      '          echo "[ERROR] lancache-distcc-wrapper: refusing to dispatch $1 back to itself (real-compiler resolution must happen before the distcc masquerade PATH is active)." >&2' \
      '          exit 1' \
      '          ;;' \
      '      esac' \
      '      real_compiler="$1"' \
      '      local_compiler="$1"' \
      '      shift' \
      '    else' \
      '      echo "[INFO] lancache-distcc-wrapper: unrecognized invocation (argv0=$0); defaulting to cc." >&2' \
      '      real_compiler="cc"' \
      '      local_compiler="/usr/bin/cc"' \
      '    fi' \
      '    ;;' \
      'esac' \
      'normalize_argument() {' \
      '  arg="$1"' \
      '  case "$arg" in' \
      '    -I*|-isystem*)' \
      '      case "$arg" in' \
      '        -I*) echo "${arg#-I}" ;;' \
      '        -isystem*) echo "${arg#-isystem}" ;;' \
      '      esac' \
      '      return' \
      '      ;;' \
      '  esac' \
      '  printf "%s\n" "$arg"' \
      '}' \
      'matches_aws_lc_generated_path() {' \
      '  arg="$1"' \
      '  case "$arg" in' \
      '    *aws-lc-sys*|*aws_lc_sys*)' \
      '      case "$arg" in' \
      '        *generated*|*out*|*target*/*/build/*) return 0;;' \
      '      esac' \
      '      ;;' \
      '  esac' \
      '  return 1' \
      '}' \
      'for arg in "$@"; do' \
      '  normalized_arg="$(normalize_argument "$arg")"' \
      '  if matches_aws_lc_generated_path "$normalized_arg"; then' \
      '    matched_arg="$normalized_arg"' \
      '    break' \
      '  fi' \
      'done' \
      'if [ -n "${matched_arg:-}" ]; then' \
      '  echo "[INFO] bypassing distcc-pump for generated-header input: $matched_arg" >&2' \
      '  if [ -n "${DISTCC_HOSTS_NO_PUMP:-}" ]; then' \
      '    env -u INCLUDE_SERVER_PORT -u INCLUDE_SERVER_PID DISTCC_HOSTS="$DISTCC_HOSTS_NO_PUMP" "$distcc_real" "$real_compiler" "$@"' \
      '    exit $?' \
      '  fi' \
      '  echo "[INFO] no non-pump hosts configured; compiling through local compiler path." >&2' \
      '  env -u DISTCC_HOSTS -u INCLUDE_SERVER_PORT -u INCLUDE_SERVER_PID -u DISTCC_FALLBACK "$local_compiler" "$@"' \
      '  exit $?' \
      'fi' \
      'exec "$distcc_real" "$real_compiler" "$@"' \
      > /usr/local/bin/lancache-distcc-wrapper; \
    chmod +x /usr/local/bin/lancache-distcc-wrapper; \
    mkdir -p /usr/local/lib/distcc; \
    for wrapper in cc gcc c++ g++; do ln -sf /usr/local/bin/lancache-distcc-wrapper "/usr/local/lib/distcc/$wrapper"; done; \
    ln -sf /usr/local/bin/lancache-distcc-wrapper "$distcc_bin"; \
    printf '%s\n' \
      '#!/bin/sh' \
      'case "${1:-}" in' \
      '  distcc|*/distcc) exec "$@" ;;' \
      '  *) exec /usr/local/bin/sccache "$@" ;;' \
      'esac' \
      > /usr/local/bin/lancache-rustc-wrapper; \
    chmod +x /usr/local/bin/lancache-rustc-wrapper

# What: writes shared cargo-accel helper functions once, to a file both
#   build RUN blocks below source (each RUN starts a fresh shell).
# Why: keeps the pre-cache and real-source builds byte-for-byte identical
#   instead of two copies that could silently drift.
# From: Issue #1533 | Refs #887
RUN <<'LANCACHE_UI_BUILD_ACCEL_EOF'
set -eu
cat > /usr/local/lib/lancache-ui-build-accel.sh <<'LANCACHE_UI_HELPERS_EOF'
    configure_sccache() { \
      if [ -s /run/secrets/sccache_redis_url ] || [ -s /run/secrets/sccache_dist_config ]; then \
        unset CARGO_MAKEFLAGS MAKEFLAGS; \
        export RUSTC_WRAPPER=/usr/local/bin/lancache-rustc-wrapper SCCACHE_REDIS_KEY_PREFIX=lancache-ui; \
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
      distcc_enabled=0; \
      trap - EXIT; \
      unset DISTCC_POTENTIAL_HOSTS DISTCC_HOSTS DISTCC_HOSTS_NO_PUMP DISTCC_FALLBACK CC GCC CXX GXX INCLUDE_SERVER_PORT INCLUDE_SERVER_PID; \
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
        distcc_hosts=""; \
        distcc_hosts_with_pump=""; \
        distcc_hosts_without_pump=""; \
        for distcc_host_spec in $DISTCC_POTENTIAL_HOSTS; do \
          distcc_host_base="${distcc_host_spec%%,*}"; \
          if [ -n "$distcc_host_base" ]; then \
            distcc_hosts="${distcc_hosts:+$distcc_hosts }$distcc_host_base"; \
          fi; \
          case "$distcc_host_spec" in \
            *,cpp*) distcc_hosts_with_pump="${distcc_hosts_with_pump:+$distcc_hosts_with_pump }$distcc_host_base" ;; \
            *) distcc_hosts_without_pump="${distcc_hosts_without_pump:+$distcc_hosts_without_pump }$distcc_host_spec" ;; \
          esac; \
        done; \
        if [ -z "$distcc_hosts" ]; then \
          rm -rf "$distcc_probe_dir"; \
          echo "DISTCC_POTENTIAL_HOSTS does not contain usable distcc hosts" >&2; \
          exit 1; \
        fi; \
        distcc_pump_hosts="${distcc_hosts_with_pump:-}"; \
        distcc_hosts_without_pump="${distcc_hosts_without_pump:-$distcc_hosts}"; \
        echo "[INFO] trying distcc path." >&2; \
        distcc_wrapper_dir="$(resolve_distcc_wrapper_dir)"; \
        export DISTCC_HOSTS_NO_PUMP="$distcc_hosts_without_pump"; \
        export PATH="$distcc_wrapper_dir:$PATH" CC=cc GCC=gcc CXX=c++ GXX=g++ DISTCC_FALLBACK=0; \
        distcc_enabled=1; \
        if [ -n "$distcc_pump_hosts" ]; then \
          export DISTCC_POTENTIAL_HOSTS="$distcc_pump_hosts"; \
          unset DISTCC_HOSTS; \
          if ! distcc_pump_env="$(distcc-pump --startup 2>"$distcc_probe_dir/distcc-pump.log")"; then \
            disable_distcc; \
            rm -rf "$distcc_probe_dir"; \
            echo "[INFO] distcc pump unavailable; continuing with normal local C compiler." >&2; \
            return 0; \
          fi; \
          eval "$distcc_pump_env"; \
          distcc_pump_real_hosts=""; \
          for distcc_host_token in ${DISTCC_HOSTS:-}; do case "$distcc_host_token" in --*) ;; *) distcc_pump_real_hosts=1 ;; esac; done; \
          if [ -z "$distcc_pump_real_hosts" ]; then unset DISTCC_HOSTS; fi; \
          PATH="$distcc_wrapper_dir:$PATH"; \
          export PATH DISTCC_HOSTS_NO_PUMP CC=cc GCC=gcc CXX=c++ GXX=g++; \
          trap 'distcc-pump --shutdown' EXIT; \
        else \
          export DISTCC_HOSTS="$distcc_hosts"; \
        fi; \
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
    # What: the cache key below only reflects whichever single farm host
    #   answered this build's own probe, not every DISTCC_POTENTIAL_HOSTS entry.
    # Why: a heterogeneous farm could mix cache entries across compilers;
    #   verified 2026-08-21 (real SSH, 6 old+new fleet hosts) all run
    #   identical Debian trixie/GCC 14.2.0-19, so this gap is not live today.
    # From: Codex review on PR #1612
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
        export CCACHE_DIR=/tmp/ccache-ui; \
        export CCACHE_PREFIX=distcc; \
        export CCACHE_COMPILERCHECK=content; \
        printf '%s' "$BUILD_TOOLS_IMAGE" > /tmp/ccache-toolchain-id; \
        export CCACHE_EXTRAFILES="/tmp/ccache-toolchain-id:/tmp/ccache-remote-toolchain-id"; \
        export CCACHE_BASEDIR="$ccache_probe_dir"; \
        export CC="ccache $real_cc" GCC="ccache $real_gcc" CXX="ccache $real_cxx" GXX="ccache $real_gxx"; \
        ccache_enabled=1; \
        printf '%s\n' 'int main(void) { return 0; }' > "$ccache_probe_dir/ccache-probe.c"; \
        # What: probes into a fresh, throwaway CCACHE_DIR under
        #   $ccache_probe_dir, not the real (shared, cross-RUN-persistent)
        #   /tmp/ccache-ui.
        # Why: the real-source RUN's probe would otherwise inherit stats/
        #   content from the pre-cache RUN's own build, so a stale write/hit
        #   could pass this check without this probe reaching Redis at all.
        # From: Codex review on PR #1612
        ccache_probe_cache_dir="$ccache_probe_dir/probe-cache"; \
        mkdir -p "$ccache_probe_cache_dir"; \
        if ! (cd "$ccache_probe_dir" && CCACHE_DIR="$ccache_probe_cache_dir" $CC -c ccache-probe.c -o ccache-probe.o) >"$ccache_probe_dir/ccache-probe.log" 2>&1; then \
          cat "$ccache_probe_dir/ccache-probe.log" >&2; \
          disable_ccache; \
          rm -rf "$ccache_probe_dir"; \
          echo "[INFO] ccache probe unavailable; continuing with plain distcc (no cache layer)." >&2; \
          return 0; \
        fi; \
        ccache_probe_stats="$ccache_probe_dir/ccache-probe-stats.log"; \
        CCACHE_DIR="$ccache_probe_cache_dir" ccache --print-stats > "$ccache_probe_stats"; \
        if grep -qE '^remote_storage_error[[:space:]]+[1-9]' "$ccache_probe_stats" \
          || ! grep -qE '^remote_storage_(write|hit)[[:space:]]+[1-9]' "$ccache_probe_stats"; then \
          cat "$ccache_probe_stats" >&2; \
          disable_ccache; \
          rm -rf "$ccache_probe_dir"; \
          echo "[INFO] ccache probe's Redis remote-storage round trip failed (neither a write nor a hit was recorded); continuing with plain distcc (no cache layer)." >&2; \
          return 0; \
        fi; \
        rm -rf "$ccache_probe_dir"; \
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
        # The `{ set +e; ...; echo "$?" >file; set -e; } | tee log` shape
        # above (not `set -o pipefail`, which dash under `sh -c` doesn't
        # support) is how the real cargo build exit code survives being
        # piped through `tee`: `$?` right after a piped command would
        # otherwise reflect `tee`'s own exit status, not cargo's.
        # Two independent failure paths are handled here: if distcc is
        # enabled, ANY build failure is assumed distcc-related and retried
        # with distcc disabled first (below). If distcc isn't enabled (or
        # its retry also failed), the log is grep'd for sccache-specific
        # error signatures before giving up, since a build can fail purely
        # because the remote sccache server was unreachable/misbehaving
        # while the local compiler would have worked fine.
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
LANCACHE_UI_HELPERS_EOF
LANCACHE_UI_BUILD_ACCEL_EOF

ARG CARGO_BUILD_JOBS=
# What: redeclares BUILD_TOOLS_IMAGE (already set pre-FROM above) so it is visible as a
# shell variable inside this stage's RUN blocks, not just usable in the FROM line itself.
# Why: configure_ccache() below folds this value into the ccache remote-storage cache key
# (Docker ARG scoping requires a bare post-FROM redeclaration for that).
# From: Issue #1533 | Refs #887
ARG BUILD_TOOLS_IMAGE

WORKDIR /build
COPY Cargo.toml Cargo.lock ./
# Pre-cache dependencies. Acceleration is opt-in through BuildKit secrets.
# The shell functions sourced from /usr/local/lib/lancache-ui-build-accel.sh
# (written by the RUN block above; call order):
#   configure_sccache      - opt-in cache wrapper, only if a sccache secret was mounted.
#   configure_distcc       - opt-in distributed compile, only if a distcc hosts secret was
#                            mounted; probes the pump daemon with a trivial compile first.
#   lancache-distcc-wrapper (installed earlier in this stage) - distcc-pump preprocesses
#     #includes locally before dispatching, but aws-lc-sys (a transitive TLS dependency)
#     writes generated C headers into its own build directory during the build, so pump
#     can't see them yet. The wrapper detects those translation units and falls back to
#     non-pump distcc / the local compiler for just those compiles; it also understands
#     ccache's CCACHE_PREFIX dispatch shape now, used by configure_ccache below.
#   disable_distcc         - rollback path used by configure_distcc/run_cargo_build on failure;
#                            shuts down distcc-pump and restores the pre-distcc PATH/env.
#   resolve_distcc_wrapper_dir - locates the cc/gcc/c++/g++ -> distcc wrapper symlinks.
#   extract_remote_toolchain_id - reads back whichever real farm host answered
#                            configure_distcc's own probe compile, recording that host's
#                            actual compiler identity for configure_ccache to hash.
#   configure_ccache/disable_ccache - opt-in cache layer in front of distcc, only once
#                            distcc is already enabled and a ccache Redis secret is
#                            mounted; mirrors services/dns/Dockerfile's AG-CI-022 layer.
#   resolve_cargo_jobs     - CARGO_BUILD_JOBS if set, else nproc-2 floored at 4.
#   run_cargo_build        - builds with ccache+distcc if both enabled, retrying with
#                            plain distcc first on failure, then a normal local compiler
#                            if that also fails (three fallback tiers total).
# NOTE: comments cannot be embedded inside this block itself. Docker's line-continuation
# strips the backslash-newline entirely (no newline is inserted), so a "#" comment ending
# in "\" would swallow every following continuation line as commented-out text instead of
# executable shell, silently dropping the rest of the build. Verified empirically.
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
    . /usr/local/lib/lancache-ui-build-accel.sh; \
    configure_sccache; \
    configure_distcc; \
    configure_ccache; \
    cargo_jobs="$(resolve_cargo_jobs)"; \
    mkdir -p src && echo 'fn main() {}' > src/main.rs && echo '' > src/lib.rs \
    && run_cargo_build \
    && if [ "${ccache_enabled:-0}" = "1" ]; then \
         ccache -s; \
         ccache_final_stats="$(mktemp)"; \
         ccache --print-stats > "$ccache_final_stats"; \
         if grep -qE '^remote_storage_error[[:space:]]+[1-9]' "$ccache_final_stats"; then \
           echo "[INFO] ccache recorded a Redis remote-storage error during the real Cargo build; this build's binary is already correct and unaffected, but the optional Redis cache layer degraded mid-build -- later builds may miss cache reuse until Redis recovers." >&2; \
           cat "$ccache_final_stats" >&2; \
         fi; \
         rm -f "$ccache_final_stats"; \
       fi \
    && rm -rf src

# This first build only had a throwaway `fn main() {}`/empty `lib.rs`, so it
# compiled every dependency crate (and a stub `liblancache_ui.rlib`) but
# nothing real from `src/`. Because only Cargo.toml/Cargo.lock were COPYed
# before that RUN, Docker's layer cache can reuse the compiled dependency
# artifacts here even when application source changes on every commit — only
# this second, real build (after copying the actual `src/`) reruns when the
# app code changes. The sccache/distcc setup, wrapper checks, and fallback
# logic in the RUN block below are otherwise identical to the one above for
# the same acceleration to apply to both builds.
COPY src ./src
# Sources the same /usr/local/lib/lancache-ui-build-accel.sh helper functions as the
# pre-cache RUN above (configure_sccache, configure_distcc, disable_distcc,
# resolve_distcc_wrapper_dir, extract_remote_toolchain_id, configure_ccache, disable_ccache,
# resolve_cargo_jobs, run_cargo_build), this time building the real sources instead of the
# throwaway `fn main() {}` stub.
#
# `cargo clean -p lancache-ui --release --target "$musl_target"` (issue: `lancache_ui::kea_response_parse`/
# `lancache_ui::netdata_url` unresolved-import failures on every build): COPY
# preserves each file's original mtime from the build context (the runner's
# git checkout), not "now". Those checkout mtimes are consistently OLDER than
# the `liblancache_ui.rlib` the pre-cache RUN above just compiled from the
# throwaway empty `lib.rs` a few Dockerfile instructions ago -- confirmed by
# directly comparing `stat` timestamps inside the builder stage: every real
# `src/*.rs` file (including `lib.rs`, `kea_response_parse.rs`, `netdata_url.rs`)
# was ~4-5 minutes older than that cached rlib. Cargo's unit-freshness check
# for the `[lib]` target is mtime-based: source mtime <= cached-artifact mtime
# reads as "unchanged", so cargo reused the stale, empty-stub rlib instead of
# recompiling `src/lib.rs`. Two prior fix attempts relied on bumping mtimes
# instead of removing the stale artifact outright: `touch src/main.rs` alone
# (forces a `[[bin]]` rebuild, but the bin then links against the still-stale
# lib rlib -- exactly the `E0432` failure this fixes), and
# `find src -type f -exec touch {} +` (works, but relies on Cargo's mtime
# comparison remaining the deciding factor, which is an implementation detail
# rather than a documented contract). `cargo clean -p lancache-ui --release
# --target "$musl_target"` instead removes this package's own previously-built
# lib/bin artifacts unconditionally -- Cargo then has no stale rlib to fall
# back to regardless of mtimes, so it must recompile `lib.rs` and its modules
# for real. The explicit `--target` here matters for the same reason it
# matters on every `cargo build` call in this stage (issue #815): without it,
# `cargo clean` would only touch `target/release/` (the host-triple default),
# never `target/${musl_target}/release/` where this musl-targeted build's
# real artifacts actually live, silently defeating the whole point of this
# workaround for the cross-compiled target. `-p` scopes
# the clean to this package only, leaving every dependency's cached rlib in
# `target/${musl_target}/release/deps/` untouched, so the pre-cache stage's
# whole point (skip recompiling third-party crates) is preserved.
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
    . /usr/local/lib/lancache-ui-build-accel.sh; \
    configure_sccache; \
    configure_distcc; \
    configure_ccache; \
    cargo_jobs="$(resolve_cargo_jobs)"; \
    cargo clean -p lancache-ui --release --target "$musl_target" \
    && run_cargo_build \
    && if [ "${ccache_enabled:-0}" = "1" ]; then \
         ccache -s; \
         ccache_final_stats="$(mktemp)"; \
         ccache --print-stats > "$ccache_final_stats"; \
         if grep -qE '^remote_storage_error[[:space:]]+[1-9]' "$ccache_final_stats"; then \
           echo "[INFO] ccache recorded a Redis remote-storage error during the real Cargo build; this build's binary is already correct and unaffected, but the optional Redis cache layer degraded mid-build -- later builds may miss cache reuse until Redis recovers." >&2; \
           cat "$ccache_final_stats" >&2; \
         fi; \
         rm -f "$ccache_final_stats"; \
       fi \
    && cp "target/${musl_target}/release/lancache-ui" /build/lancache-ui-out

# ── Runtime image ──────────────────────────────────────────────────────────────
# Alpine base (issue #815): replaces the prior debian:trixie-slim final
# stage. Same pinned alpine:3.24 digest already used by services/dhcp,
# services/dhcp-proxy, services/watchdog, services/ntp, and services/dns.

# What: source stage for tools copied into the final image below.
# Why: pinned by digest (not a mutable tag) for a reproducible build -- see
#   services/proxy/Dockerfile's identical stage comment for the full
#   digest-resolution rationale.
# From: Issue #1556
FROM ghcr.io/wiki-mod/lancache-ng/utilities@sha256:718af4cf8f1352cee341e851cecb9821033de9a5c7804c64e1c6217b62c79186 AS utilities-tools

FROM mirror.gcr.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

LABEL org.opencontainers.image.description="lancache-ng Admin UI and control-plane service for cache, DNS, DHCP, and secondary management."

# Package translations from the prior debian:trixie-slim stage (verified live
# against a real alpine:3.24 container, per issue #815's own instruction to
# check rather than assume a substitute is needed):
#   - locales/locale-gen/LANG=en_US.UTF-8 dropped entirely, not replaced:
#     grepped services/ui/src (the whole crate) and docker-entrypoint.sh for
#     any LANG/LC_ALL/locale/setlocale dependency -- none found. musl has no
#     glibc-style locale-data system, and nothing in this service's actual
#     behavior (Tera template rendering, JSON/log output) depends on real
#     glibc locale data, matching the identical conclusion services/dns's own
#     migration already reached for the same block.
#   - coreutils and util-linux are both kept (not translated -- Alpine ships
#     both under the same package names). coreutils provides base64/od/mktemp
#     for docker-entrypoint.sh's shared-secret bootstrap; util-linux provides
#     `setpriv`, which that same script uses for its root-to-lancache
#     privilege drop (`setpriv --reuid=lancache --regid=lancache
#     --init-groups`) -- confirmed live that Alpine's util-linux package ships
#     setpriv with identical --init-groups behavior to Debian's.
#   - ca-certificates, coreutils: unchanged package names, confirmed present
#     on Alpine, kept apk-installed (excluded from the utilities migration --
#     see services/proxy/Dockerfile's comment for ca-certificates' reason).
RUN apk add --no-cache \
    ca-certificates \
    coreutils \
    util-linux \
    nano

# What: curl/lsof/ripgrep come from the shared utilities image.
# Why: same alpine:3.24 digest as utilities -- see services/proxy/Dockerfile's
#   identical comment for the full rationale.
# From: Issue #1556

# What: removes the BusyBox symlink at this path before the real binary lands.
# Why: see services/proxy/Dockerfile's identical comment for the reason.
# From: Issue #1556
RUN rm -f /usr/bin/lsof

COPY --from=utilities-tools /usr/local/bin/curl /usr/local/bin/curl
COPY --from=utilities-tools /usr/bin/lsof /usr/bin/lsof
COPY --from=utilities-tools /usr/bin/rg /usr/bin/rg
COPY --from=utilities-tools /usr/lib/libgcc_s.so.1 /usr/lib/libgcc_s.so.1
COPY --from=utilities-tools /usr/lib/libpcre2-8.so.0* /usr/lib/
COPY --from=utilities-tools /usr/local/bin/verify-version-banner.sh /usr/local/bin/verify-version-banner.sh

# What: verifies the copied binaries actually run.
# Why: a missing shared-library dependency fails at exec time, not at COPY
#   time; the lsof check is delegated to a shared script (see that file).
# From: Issue #1613
RUN set -euo pipefail; \
    rg --version >/dev/null; \
    curl --version >/dev/null; \
    sh /usr/local/bin/verify-version-banner.sh "lsof version information" lsof -v

# nano: in-container troubleshooting tool -- see services/proxy/Dockerfile's
# identical comment for the full rationale; lsof/ripgrep are COPY'd above
# but serve the same troubleshooting purpose.
ENV EDITOR=nano
ENV VISUAL=$EDITOR

COPY --from=builder /build/lancache-ui-out /usr/local/bin/lancache-ui
COPY src/templates /templates
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
# The former dhcp-probe.sh (nmap + isc-dhcp-client) is retired by issue
# #1288 -- the dhcp-probe container now runs this same lancache-ui binary
# with `--dhcp-probe` (see deploy/*/docker-compose.yml's dhcp-probe
# service `entrypoint:`), so no separate script needs to be copied in.

# What: keeps the UI's fixed runtime gid at 10001.
# Why: issue #1427 moves nginx's log files onto this same shared reader gid,
#   so the log viewer no longer needs an `adm`-specific compatibility path.
# From: Issue #1427
RUN addgroup -g 10001 lancache \
    && adduser -D -H -u 10001 -G lancache -s /sbin/nologin lancache \
    && mkdir -p /data /etc/nats \
    && chown -R lancache:lancache /data /etc/nats \
    && chmod +x /usr/local/bin/docker-entrypoint.sh


EXPOSE 8080

# Runtime defaults mirror the compose files: one shared cache path is mounted
# read-only for dashboard reporting, while writes remain owned by proxy/watchdog.
ENV TEMPLATE_DIR=/templates \
    CDN_DOMAINS_FILE=/data/cdn-domains.txt \
    STANDARD_LOG=/var/log/nginx/access.log \
    SSL_LOG=/var/log/nginx/access.log \
    CACHE_DIR=/var/cache/proxy \
    PROXY_SERVICE=proxy \
    SSL_ENABLED=1 \
    PROXY_STANDARD_URL=http://proxy \
    PROXY_SSL_URL=http://proxy \
    NETDATA_URL=http://netdata:19999 \
    DNS_STANDARD_SERVICE=dns-standard \
    DNS_SSL_SERVICE=dns-ssl \
    PROXY_SSL_SERVICE=proxy \
    CACHE_MAX_GB=50

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["lancache-ui"]
