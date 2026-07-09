# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# DNS service: PowerDNS (recursor + authoritative), nats-subscriber binary, Lua RPZ scripts.

# Intentional ARG default (overridable at build time via --build-arg).
# Actual digest pinning for release builds is tracked in issue #508.
ARG BUILD_TOOLS_IMAGE=ghcr.io/wiki-mod/lancache-ng/build-tools:latest
FROM ${BUILD_TOOLS_IMAGE} AS subscriber-builder

# The shared build-tools image already carries the Rust toolchain, sccache,
# distcc, distcc-pump, and the supporting Debian packages. Keep this stage
# lean and fail closed if the contract is not met.
RUN set -eu; \
    for tool in cargo rustc rustup rustfmt clippy-driver sccache distcc distcc-pump python3 pkg-config; do \
      command -v "$tool" >/dev/null; \
    done; \
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

WORKDIR /build
COPY nats-subscriber/ .
# The shell functions defined inside this RUN (in call order):
#   configure_sccache      - opt-in cache wrapper, only if a sccache secret was mounted.
#   configure_distcc       - opt-in distributed compile, only if a distcc hosts secret was
#                            mounted; probes the pump daemon with a trivial compile first.
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
        export RUSTC_WRAPPER=/usr/local/bin/lancache-rustc-wrapper SCCACHE_REDIS_KEY_PREFIX=lancache-dns; \
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
      if [ "${distcc_enabled:-0}" != "1" ]; then cargo build -j "$cargo_jobs" --release --locked; return; fi; \
      cargo_log="$(mktemp)"; \
      if cargo build -j "$cargo_jobs" --release --locked >"$cargo_log" 2>&1; then \
        rm -f "$cargo_log"; \
        return 0; \
      fi; \
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
    }; \
    configure_sccache; \
    configure_distcc; \
    cargo_jobs="$(resolve_cargo_jobs)"; \
    run_cargo_build

FROM mirror.gcr.io/library/debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2

LABEL org.opencontainers.image.description="PowerDNS recursor, authoritative DNS, and NATS subscriber service for lancache-ng cache routing."

# Debian package triggers try to start services during image builds; the entrypoint starts PDNS instead.
RUN set -eu; \
    export DEBIAN_FRONTEND=noninteractive; \
    cleanup_invoke_rc_d() { \
        rm -f /usr/sbin/invoke-rc.d; \
        if [ -x /usr/sbin/invoke-rc.d.real ]; then mv /usr/sbin/invoke-rc.d.real /usr/sbin/invoke-rc.d; fi; \
    }; \
    trap cleanup_invoke_rc_d EXIT; \
    if [ -x /usr/sbin/invoke-rc.d ]; then mv /usr/sbin/invoke-rc.d /usr/sbin/invoke-rc.d.real; fi; \
    printf '%s\n' '#!/bin/sh' 'exit 0' > /usr/sbin/invoke-rc.d; \
    chmod +x /usr/sbin/invoke-rc.d; \
    apt-get update && apt-get install -y --no-install-recommends \
    pdns-recursor \
    pdns-server \
    pdns-backend-sqlite3 \
    dnsutils \
    sqlite3 \
    gettext-base \
    iproute2 \
    locales \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

RUN mkdir -p /etc/pdns/auth /var/lib/powerdns /var/run/pdns \
    && chown -R pdns:pdns /var/lib/powerdns /var/run/pdns

COPY --from=subscriber-builder /build/target/release/nats-subscriber /usr/local/bin/nats-subscriber

COPY recursor.conf.template /etc/pdns/recursor.conf.template
COPY pdns.conf.template /etc/pdns/auth/pdns.conf.template
COPY recursor.lua /etc/pdns/recursor.lua
COPY filter-aaaa.lua /etc/pdns/filter-aaaa.lua
COPY cdn-domains.txt /etc/pdns/cdn-domains.txt
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 53/udp 53/tcp 8081 8082

ENTRYPOINT ["/entrypoint.sh"]
