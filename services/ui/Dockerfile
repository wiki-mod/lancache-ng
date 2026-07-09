# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Multi-stage build for the Admin UI service. The builder stage compiles the
# Rust binary against the shared build-tools image, opportunistically
# accelerating the build with sccache and/or distcc when the corresponding
# BuildKit secrets are present (falling back to a plain local build
# otherwise). The runtime stage is a minimal Debian image that only carries
# the compiled binary, its Tera templates, and the entrypoint script.

# Intentional ARG default (overridable at build time via --build-arg).
# Actual digest pinning for release builds is tracked in issue #508.
ARG BUILD_TOOLS_IMAGE=ghcr.io/wiki-mod/lancache-ng/build-tools:latest
FROM ${BUILD_TOOLS_IMAGE} AS builder

# The shared build-tools image already carries the Rust toolchain, sccache,
# distcc, distcc-pump, and the supporting Debian packages. Keep this stage
# lean and fail closed if the contract is not met.
RUN set -eu; \
    for tool in cargo rustc rustup rustfmt clippy-driver sccache distcc distcc-pump python3 pkg-config; do \
      command -v "$tool" >/dev/null; \
    done; \
    distcc_bin="$(command -v distcc)"; \
    distcc_real_bin="/usr/local/bin/distcc-real"; \
    cp "$distcc_bin" "$distcc_real_bin"; \
    printf '%s\n' \
      '#!/bin/sh' \
      'set -eu' \
      'distcc_real="/usr/local/bin/distcc-real"' \
      'compiler_name="$(basename "$0")"' \
      'case "$compiler_name" in cc|gcc|c++|g++) real_compiler="$compiler_name" ;; *) real_compiler="cc" ;; esac' \
      'case "$real_compiler" in cc|gcc|c++|g++) local_compiler="/usr/bin/$real_compiler" ;; *) local_compiler="/usr/bin/cc" ;; esac' \
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

ARG CARGO_BUILD_JOBS=

WORKDIR /build
COPY Cargo.toml Cargo.lock ./
# Pre-cache dependencies. Acceleration is opt-in through BuildKit secrets.
# The shell functions defined inside this RUN (in call order):
#   configure_sccache      - opt-in cache wrapper, only if a sccache secret was mounted.
#   configure_distcc       - opt-in distributed compile, only if a distcc hosts secret was
#                            mounted; probes the pump daemon with a trivial compile first.
#   lancache-distcc-wrapper (installed earlier in this stage) - distcc-pump preprocesses
#     #includes locally before dispatching, but aws-lc-sys (a transitive TLS dependency)
#     writes generated C headers into its own build directory during the build, so pump
#     can't see them yet. The wrapper detects those translation units and falls back to
#     non-pump distcc / the local compiler for just those compiles.
#   disable_distcc         - rollback path used by configure_distcc/run_cargo_build on failure;
#                            shuts down distcc-pump and restores the pre-distcc PATH/env.
#   resolve_distcc_wrapper_dir - locates the cc/gcc/c++/g++ -> distcc wrapper symlinks.
#   resolve_cargo_jobs     - CARGO_BUILD_JOBS if set, else nproc-2 floored at 4.
#   run_cargo_build        - builds with distcc if enabled, retrying once locally on failure.
# NOTE: comments cannot be embedded inside this block itself. Docker's line-continuation
# strips the backslash-newline entirely (no newline is inserted), so a "#" comment ending
# in "\" would swallow every following continuation line as commented-out text instead of
# executable shell, silently dropping the rest of the build. Verified empirically.
RUN --mount=type=secret,id=sccache_redis_url \
    --mount=type=secret,id=sccache_dist_config \
    --mount=type=secret,id=distcc_potential_hosts \
    set -eu; \
    distcc_enabled=0; \
    original_path="$PATH"; \
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
            *,cpp*) distcc_hosts_with_pump="${distcc_hosts_with_pump:+$distcc_hosts_with_pump }$distcc_host_spec" ;; \
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
          DISTCC_HOSTS_NO_PUMP="${DISTCC_HOSTS:-$DISTCC_HOSTS_NO_PUMP}"; \
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
        rm -rf "$distcc_probe_dir"; \
      fi; \
    }; \
    resolve_cargo_jobs() { \
      jobs="${CARGO_BUILD_JOBS:-}"; \
      if [ -z "$jobs" ]; then \
        cores="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 2)"; \
        jobs=$((cores - 2)); \
        if [ "$jobs" -lt 4 ]; then jobs=4; fi; \
      fi; \
      case "$jobs" in ''|*[!0-9]*) echo "CARGO_BUILD_JOBS must be a positive integer" >&2; exit 1;; esac; \
      if [ "$jobs" -le 0 ]; then echo "CARGO_BUILD_JOBS must be greater than zero" >&2; exit 1; fi; \
      printf '%s\n' "$jobs"; \
    }; \
    run_cargo_build() { \
      cargo_log="$(mktemp)"; \
      cargo_status_file="$(mktemp)"; \
      { set +e; cargo build -j "$cargo_jobs" --release --locked 2>&1; echo "$?" >"$cargo_status_file"; set -e; } | tee "$cargo_log"; \
      cargo_status="$(cat "$cargo_status_file")"; \
      rm -f "$cargo_status_file"; \
      if [ "$cargo_status" = "0" ]; then rm -f "$cargo_log"; return 0; fi; \
      if [ "${distcc_enabled:-0}" = "1" ]; then \
        disable_distcc; \
        unset RUSTC_WRAPPER SCCACHE_REDIS SCCACHE_CONF SCCACHE_REDIS_KEY_PREFIX; \
        echo "[INFO] distcc build path unavailable; retrying with normal local C compiler." >&2; \
        if cargo build -j "$cargo_jobs" --release --locked; then \
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
        if cargo build -j "$cargo_jobs" --release --locked; then \
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
    cargo_jobs="$(resolve_cargo_jobs)"; \
    mkdir -p src && echo 'fn main() {}' > src/main.rs \
    && run_cargo_build \
    && rm -rf src

COPY src ./src
# Same helper functions as the pre-cache RUN above (configure_sccache, configure_distcc,
# disable_distcc, resolve_distcc_wrapper_dir, resolve_cargo_jobs, run_cargo_build), this
# time building the real sources instead of the throwaway `fn main() {}` stub.
RUN --mount=type=secret,id=sccache_redis_url \
    --mount=type=secret,id=sccache_dist_config \
    --mount=type=secret,id=distcc_potential_hosts \
    set -eu; \
    distcc_enabled=0; \
    original_path="$PATH"; \
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
            *,cpp*) distcc_hosts_with_pump="${distcc_hosts_with_pump:+$distcc_hosts_with_pump }$distcc_host_spec" ;; \
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
          DISTCC_HOSTS_NO_PUMP="${DISTCC_HOSTS:-$DISTCC_HOSTS_NO_PUMP}"; \
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
        rm -rf "$distcc_probe_dir"; \
      fi; \
    }; \
    resolve_cargo_jobs() { \
      jobs="${CARGO_BUILD_JOBS:-}"; \
      if [ -z "$jobs" ]; then \
        cores="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 2)"; \
        jobs=$((cores - 2)); \
        if [ "$jobs" -lt 4 ]; then jobs=4; fi; \
      fi; \
      case "$jobs" in ''|*[!0-9]*) echo "CARGO_BUILD_JOBS must be a positive integer" >&2; exit 1;; esac; \
      if [ "$jobs" -le 0 ]; then echo "CARGO_BUILD_JOBS must be greater than zero" >&2; exit 1; fi; \
      printf '%s\n' "$jobs"; \
    }; \
    run_cargo_build() { \
      cargo_log="$(mktemp)"; \
      cargo_status_file="$(mktemp)"; \
      { set +e; cargo build -j "$cargo_jobs" --release --locked 2>&1; echo "$?" >"$cargo_status_file"; set -e; } | tee "$cargo_log"; \
      cargo_status="$(cat "$cargo_status_file")"; \
      rm -f "$cargo_status_file"; \
      if [ "$cargo_status" = "0" ]; then rm -f "$cargo_log"; return 0; fi; \
      if [ "${distcc_enabled:-0}" = "1" ]; then \
        disable_distcc; \
        unset RUSTC_WRAPPER SCCACHE_REDIS SCCACHE_CONF SCCACHE_REDIS_KEY_PREFIX; \
        echo "[INFO] distcc build path unavailable; retrying with normal local C compiler." >&2; \
        if cargo build -j "$cargo_jobs" --release --locked; then \
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
        if cargo build -j "$cargo_jobs" --release --locked; then \
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
    cargo_jobs="$(resolve_cargo_jobs)"; \
    touch src/main.rs \
    && run_cargo_build

# ── Runtime image ──────────────────────────────────────────────────────────────
FROM mirror.gcr.io/library/debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2

LABEL org.opencontainers.image.description="lancache-ng Admin UI and control-plane service for cache, DNS, DHCP, and secondary management."

RUN set -eu; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    coreutils \
    curl \
    isc-dhcp-client \
    locales \
    nmap \
    util-linux \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

COPY --from=builder /build/target/release/lancache-ui /usr/local/bin/lancache-ui
COPY src/templates /templates
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY dhcp-probe.sh /usr/local/bin/dhcp-probe.sh

RUN groupadd --system --gid 10001 lancache \
    && useradd --uid 10001 --gid lancache --home-dir /nonexistent --shell /usr/sbin/nologin lancache \
    && mkdir -p /data /etc/nats \
    && chown -R lancache:lancache /data /etc/nats \
    && chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/dhcp-probe.sh


EXPOSE 8080

ENV TEMPLATE_DIR=/templates \
    CDN_DOMAINS_FILE=/data/cdn-domains.txt \
    STANDARD_LOG=/var/log/nginx/access.log \
    SSL_LOG=/var/log/nginx/access.log \
    STANDARD_CACHE_DIR=/var/cache/proxy \
    SSL_CACHE_DIR=/var/cache/proxy \
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
