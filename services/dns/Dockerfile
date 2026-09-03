
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# DNS service: PowerDNS (recursor + authoritative), nats-subscriber binary, Lua RPZ scripts.

# Intentional ARG default (overridable at build time via --build-arg).
# Actual digest pinning for release builds is tracked in issue #508.
ARG BUILD_TOOLS_IMAGE=ghcr.io/wiki-mod/lancache-ng/build-tools:latest
# What: declared pre-FROM for use in later FROM lines.
# Why: same override contract as BUILD_TOOLS_IMAGE (AG-KD-010).
# From: Issue #1095
ARG UTILITIES_IMAGE=ghcr.io/wiki-mod/lancache-ng/utilities:latest
FROM ${BUILD_TOOLS_IMAGE} AS subscriber-builder

# The shared build-tools image already carries the Rust toolchain, sccache,
# distcc, distcc-pump, and the supporting Debian packages. Keep this stage
# lean and fail closed if the contract is not met.
#
# What: detects host arch for musl cross-compile target.
# Why: `uname -m` needs no extra package, unlike dpkg.
# From: Issue #1095
RUN set -eu; \
    for tool in cargo rustc rustup rustfmt clippy-driver sccache distcc distcc-pump python3 pkg-config; do \
      command -v "$tool" >/dev/null; \
    done; \
    command -v musl-gcc >/dev/null; \
    command -v ccache >/dev/null; \
    case "$(uname -m)" in \
      x86_64) echo "x86_64-unknown-linux-musl" > /tmp/musl-target; ;; \
      aarch64) echo "aarch64-unknown-linux-musl" > /tmp/musl-target; ;; \
      *) echo "Unsupported architecture for musl cross-compilation target: $(uname -m)" >&2; exit 1; ;; \
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
# What: redeclares BUILD_TOOLS_IMAGE for RUN stage visibility.
# Why: configure_ccache() folds it into the cache key.
# From: Issue #887
ARG BUILD_TOOLS_IMAGE

WORKDIR /build
COPY nats-subscriber/ .
# The shell functions defined inside this RUN (in call order):
#   configure_sccache      - opt-in cache wrapper, only if a sccache secret was mounted.
#   configure_distcc       - opt-in distributed compile, only if a distcc hosts secret was
#                            mounted; probes the pump daemon with a trivial compile first.
#   disable_distcc         - rollback path used by configure_distcc/run_cargo_build on failure;
#                            shuts down distcc-pump and restores the pre-distcc PATH/env.
#   resolve_distcc_wrapper_dir - locates the cc/gcc/c++/g++ -> distcc wrapper symlinks.
#   extract_remote_toolchain_id - reads back whichever real farm host answered
#                            configure_distcc's own probe compile, recording that host's
#                            actual compiler identity for configure_ccache to hash.
#   configure_ccache/disable_ccache - opt-in cache layer in front of distcc, only once
#                            distcc is already enabled and a ccache Redis secret was
#                            mounted; probes with a trivial compile first, same as
#                            configure_distcc.
#     What: sets CC/CCACHE_PREFIX/REMOTE_STORAGE/COMPILERCHECK vars.
#     Why: sccache can't wrap distcc; content avoids stale Redis hits.
#     From: Issue #887
#   `$real_cc`/`$real_gcc`/`$real_cxx`/`$real_gxx` are resolved from `$original_path`
#     before configure_distcc mutates PATH.
#     Why: `CC="ccache cc"` after configure_distcc would resolve "cc" through the
#     masquerade dir onto distcc itself, wrapping distcc around distcc instead of the
#     real compiler.
#   Redis endpoint reuses the same `SCCACHE_REDIS_URL`-sourced secret already used for
#     sccache (see build-push.yml), not a second GitHub secret, normalizing it onto a
#     `redis://` scheme if it doesn't already carry one.
#     Why: ccache's own fixed `ccache:` key namespace never collides with sccache's
#     distinct `SCCACHE_REDIS_KEY_PREFIX`-based one on the same Redis instance, and
#     ccache's manual requires an explicit scheme -- an unscoped `host:port` value
#     fails with "Cannot parse URL ... Scheme ... is invalid".
#   `CCACHE_EXTRAFILES="/tmp/ccache-toolchain-id:/tmp/ccache-remote-toolchain-id"`
#     (colon-separated, per ccache's own manual) and `CCACHE_BASEDIR="$ccache_probe_dir"`
#     plus a `cd`+relative-path probe compile.
#     Why: `CCACHE_COMPILERCHECK=content` only hashes the local `cc` binary, never the
#     `192.168.1.229`/`192.168.1.240` farm host's own (hand-provisioned, no repo-owned
#     upgrade lockstep), so a farm host upgrade alone could otherwise let a stale remote
#     toolchain's object serve as a "hit". `extract_remote_toolchain_id()` closes that gap by
#     reading the `.comment` ELF identity GCC/Clang embed in every object back out of
#     `configure_distcc()`'s own real probe compile -- a verified sample of whichever farm
#     host actually answered, not an assumption -- and `configure_ccache()` fails closed to
#     plain distcc if that identity file ends up empty. This samples one probe's host as a
#     proxy for the farm's current toolchain generation: it catches a farm upgraded between
#     builds, not one that is heterogeneous within a single build (see
#     docs/local-runner-docker-performance.md's known-limitation note). BASEDIR+relative-path keeps the
#     probe's own key stable across builds despite `$ccache_probe_dir` being a fresh mktemp
#     path every time; without it, every build would leak a new, never-reused Redis entry.
#     Consequently the probe's own success check accepts either a remote write OR a remote
#     hit as proof of a healthy round trip -- a second build against the same generation
#     legitimately hits instead of writing; without this, the probe misclassifies a genuine
#     cache hit as a write failure and disables ccache for the whole build.
#     From: Issue #887
#   resolve_cargo_jobs     - CARGO_BUILD_JOBS if set, else nproc-2 floored at 4; now also
#                            echoes the resolved value and its source (explicit vs.
#                            auto-detected) to the build log.
#   run_cargo_build        - builds with ccache+distcc if both enabled, retrying with
#                            plain distcc first on failure, then a normal local compiler
#                            if that also fails (three fallback tiers total).
#   What: echoes "[INFO] ... disabled (reason)" on each skip path.
#   Why: build log couldn't tell intentional skip from misconfig.
#   From: Issue #1095 | PR #1640
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
        export CCACHE_DIR=/tmp/ccache-dns; \
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
    # What: dumps ccache-s, checks for mid-build Redis errors.
    # Why: Redis outage doesn't fail build; no warnings on success.
    # From: Issue #887
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
    cp "target/${musl_target}/release/nats-subscriber" /build/nats-subscriber-out

# What: source stage for tools copied into the final image below.
# Why: uses mutable `:latest` tag; see AG-KD-010 for rationale.
# From: Issue #1095
FROM ${UTILITIES_IMAGE} AS utilities-tools

FROM mirror.gcr.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

LABEL org.opencontainers.image.description="PowerDNS recursor, authoritative DNS, and NATS subscriber service for lancache-ng cache routing."

# What: explicit proxy build-args, no default value set
# Why: routes self-hosted downloads via the LAN proxy
# From: Issue #1781 | PR #1783
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

# Alpine base (issue #815, services/dns Alpine migration -- the last of the
# three original Part A services, done after dhcp/dhcp-proxy per #815's own
# recommended staging order, because of the nats-subscriber musl builder-stage
# work above). Same pinned digest already used by services/dhcp,
# services/dhcp-proxy, and services/watchdog (issues #815/#1234/#1346), so
# every Alpine-based service in this project tracks one shared, intentional
# version bump rather than drifting independently.
#
# This is a real major-version jump for the authoritative server, not just a
# base-image swap: pdns-server goes from Debian trixie's 4.9.16 to the 5.0.x
# line (pdns-recursor's own jump, 5.2.11 -> 5.4.x, is a minor bump by
# comparison). At migration time this was pinned to edge's 5.1.3 rather than
# v3.24 stable's then-current 5.0.5, because of a real CVE finding -- see the
# dedicated comment on the `apk add` step below for the full reasoning and
# its since-resolved outcome (issue #1483): v3.24 stable has since caught up
# past the CVE fix version, so this now installs the plain stable-channel
# package again. Initial breaking-change verification below was performed
# against stable's 5.0.5, then re-confirmed against edge's 5.1.3 while that
# pin was active. Reviewed PowerDNS's own upgrade documentation for
# breaking changes across that authoritative-server jump and verified each
# concretely, not just from doc prose (2026-08-05, runner 192.168.1.229, real
# `alpine:3.24` containers):
#   - Removed/renamed legacy replication settings (allow-unsigned-supermaster,
#     master/slave-*, superslave) -- this project's pdns.conf.template never
#     used any of them (single-server sqlite3 setup, no primary/secondary
#     replication), confirmed by reading the template.
#   - REST API: 5.0 rejects any API write containing a `priority` field, and
#     normalizes record content on write. Checked nats-subscriber's actual
#     rrset JSON shape (main.rs/lib.rs/zone_snapshots.rs): it only ever sends
#     `name`/`type`/`ttl`/`records[].content`/`records[].disabled`/
#     `changetype` -- no `priority` field anywhere, so the rejection doesn't
#     apply. Record-content normalization is a real, if unlikely, risk for
#     the read-back comparison zone_snapshots.rs's `matches_latest_snapshot`
#     does, but only for record types PowerDNS reformats on write (e.g.
#     trailing-dot targets, MX-style priority-in-content) -- this project
#     only ever writes A/AAAA records (RPZ CDN-domain spoofing) and whatever
#     the Admin UI/LAN-zone flow sends, verified functionally end-to-end
#     below rather than assumed safe from the code review alone.
#   - `pdnsutil create-zone`/`import-tsig-key`/`set-meta`'s flat-command
#     syntax (as entrypoint.sh already calls them) still works unchanged --
#     verified by actually running each one against a real Alpine
#     pdns-server (5.0.5 initially, re-confirmed on the actually-shipped
#     5.1.3), not inferred from a doc summary that suggested a possible
#     hierarchical (`pdnsutil zone create ...`) shift.
#   - `pdns_server --config=check --config-dir=...` (entrypoint.sh's own
#     config validator) still works unchanged, verified against the real
#     unmodified pdns.conf.template.
#   - Recursor: `webservice:` YAML section still accepts this project's
#     existing `address:`/`port:` keys on 5.4.4, verified by running
#     `pdns_recursor --config=check` against the real, unmodified
#     recursor.conf.template -- exits 0, no `listen:`-key migration needed
#     despite upstream docs describing `listen:` as the newer/preferred form.
#   - No LUA-record usage anywhere in this project's zone data (grepped),
#     so 5.0's now-disabled-by-default `enable-lua-record-updates` is moot.
#   - gsqlite3 schema: Alpine's pdns-backend-sqlite3 package ships no
#     schema.sqlite3.sql file at all, on either the 5.0.5-r0 (v3.24 stable,
#     at the time) or 5.1.3-r0 (edge, actually installed at the time) build
#     (confirmed via `apk info -L` against both, unlike Debian's package) --
#     see schema.sqlite3.sql (vendored in this directory, fetched from
#     PowerDNS's own upstream repo at tag auth-5.0.5) and entrypoint.sh's
#     updated schema-lookup fallback below. Upstream's own migration-file
#     chain confirms this base schema is unchanged since PowerDNS 4.7.0 --
#     re-diffed byte-for-byte against the auth-5.1.3 tag's own copy too
#     (identical) -- i.e. identical to what Debian trixie's 4.9.16 already
#     used and to what the 5.1.3 package needed. Now that the `apk add` step
#     below installs plain stable's 5.0.7-r0 instead (issue #1483), this
#     stays valid: a real CI build (2026-08-07, PR resolving issue #1483)
#     ran this project's full-setup "DNS zone/record rollback simulation"
#     and "UI/NATS/DNS integration simulation" against the actually-shipped
#     5.0.7-r0 package -- both passed, which requires entrypoint.sh's
#     vendored-schema fallback to have engaged correctly and PowerDNS to
#     have read/written real zone data through it (a piped `apk info -L`
#     grep alone was tried first but is not reliable evidence one way or the
#     other: an Alpine `edge`-repo-index warning on stderr during that same
#     command made an empty match result ambiguous between "no schema file"
#     and "the listing itself produced no output").
#
# Package translations from the prior apt-get list (all confirmed live
# against a real `alpine:3.24` container, not assumed from the apk package
# index alone):
#   - pdns-recursor -> pdns-recursor-luajit, NOT plain pdns-recursor: Alpine's
#     default `pdns-recursor` package links against plain PUC Lua 5.4
#     (`liblua-5.4.so.0`, confirmed via `ldd`), not LuaJIT -- exactly the
#     "Lua-less-relative-to-Debian" build #815 said to check for before
#     relying on it for filter-aaaa.lua/recursor.lua. The separate
#     `pdns-recursor-luajit` package (same version as plain pdns-recursor on
#     whichever channel is active -- 5.4.4-r0 at this 2026-08-05 migration,
#     5.4.5-r0 as of the 2026-08-07 pdns-stable-pin fix, issue #1483) links
#     `libluajit-5.1.so.2` instead, matching Debian's own LuaJIT-based build
#     and this project's stated acceptance criterion.
#   - dnsutils -> bind-tools.
#   - gettext-base -> gettext-envsubst (Alpine splits envsubst out of the
#     base gettext package; confirmed this exact sub-package, not plain
#     gettext, is what #815's own proxy/dhcp-proxy research already named).
#   - sqlite3 -> sqlite (Alpine's CLI package name).
#   - locales/locale-gen/LANG=en_US.UTF-8 dropped entirely, not replaced:
#     grepped recursor.lua, filter-aaaa.lua, and this file's own
#     entrypoint.sh for any LANG/LC_ALL/locale/collation dependency -- none
#     found. musl has no glibc-style locale-data system, and nothing in this
#     service's actual behavior (pdns/recursor log output, Lua scripting)
#     depends on real glibc locale data, so this block is purely cosmetic
#     and safely droppable, per #815's own explicit instruction to check
#     before assuming a substitute is needed.
#   - findutils added: entrypoint.sh's kgs_list_snapshots() calls
#     `find ... -printf '%f\n'`, a GNU-find-only flag BusyBox's own `find`
#     applet does not support -- the same BusyBox gap already hit and fixed
#     for services/watchdog (#1346) and services/dhcp/dhcp-proxy (#1347).
#     Confirmed live: BusyBox find silently has no -printf support at all;
#     installing findutils (GNU find) fixes it with zero script changes.
#   - grep added: the RPZ-serial-preservation logic
#     (`grep -oP '...\K\d+'` in entrypoint.sh, section 7) needs PCRE support
#     BusyBox's own grep applet does not have at all (`grep: unrecognized
#     option: P`, confirmed live). Alpine's real `grep` package is GNU grep
#     built with PCRE2 support and resolves this with zero script changes
#     (`apk info -e grep` pulls in `pcre2` automatically as a dependency).
#   - coreutils added: BusyBox's own `date` applet silently produces an
#     EMPTY nanosecond field for `date +%N` (confirmed live: real output was
#     `20260805T193653.` -- a trailing dot with nothing after it, not even a
#     literal "N") instead of erroring, which would make every
#     kgs_new_snapshot_id() snapshot-id collision-prone within the same
#     second. Installing coreutils (GNU date) fixes this with zero script
#     changes; also makes basename/dirname/mktemp consistently GNU-flavored
#     (BusyBox's own versions of those three already behaved correctly in
#     this project's actual usage, verified live, so this is precautionary
#     consistency rather than a second confirmed bug).
#   - bash added: entrypoint.sh's own `#!/bin/bash` shebang plus its use of
#     `local`, indexed arrays, `[[ ... ]]`, and `${var,,}` lowercasing all
#     require real bash -- Alpine's base image has no bash by default,
#     unlike Debian's.
#   - iproute2 added: detect_pdns_local_address()'s `ip route get`/
#     `ip -4 addr show` calls; same package name on Alpine, confirmed live.
#
# No invoke-rc.d service-trigger stub is needed here (unlike the prior
# Debian stage): Alpine's apk has no equivalent init-script-trigger
# mechanism that tries to start a daemon during package installation, so
# there is nothing for that workaround to guard against on this base.
#
# `pdns`/`pdns-backend-sqlite3` CVE-2026-42005 pin history -- RESOLVED
# 2026-08-07 (issue #1483), kept here rather than deleted so both the
# original reasoning and the reasoning for dropping it again stay visible,
# mirroring how this project treats `trixie-backports` as a currency
# mechanism to drop once the base channel catches up, not a permanent
# fixture that gets its history erased once it goes away.
#
# Original problem (2026-08-05): live-verified that pdns-server 5.0.5 --
# the version v3.24 stable shipped at the time -- is directly named as an
# affected version of CVE-2026-42005 (PowerDNS Security Advisory 2026-07:
# "insufficient input validation of internal web server" /
# unbounded-memory-allocation DoS), fixed upstream in 5.0.6/5.1.2. The
# advisory calls this "minimal relevance" only for a deployment with the
# internal webserver disabled -- this project's pdns.conf.template
# explicitly sets `webserver=yes` (the REST API on port 8081
# nats-subscriber and the Admin UI both depend on), so that carve-out did
# not apply here; this was a real, LAN-reachable regression risk, not a
# theoretical one, and a genuine regression introduced specifically by this
# migration (the advisory's own "Fixed Versions" list includes 4.9.16, the
# exact pdns-server version the prior Debian trixie-based stage already
# ran, so the Debian image was never vulnerable to this CVE in the first
# place). Since v3.24 stable had not yet picked up a point release with the
# fix, this file pinned `pdns`/`pdns-backend-sqlite3` to an EXACT version on
# Alpine's `edge` branch (`pdns@edge=5.1.3-r0`, not a bare `pdns@edge`),
# which already carried 5.1.3 (past the named fix version 5.1.2):
# deliberately exact-version rather than a bare `@edge` pin, so a rebuild
# could not silently resolve a different, potentially ABI-mismatched edge
# build against this image's other stable-channel-sourced libraries (e.g.
# boost/sqlite-libs/luajit). Pinning only these two packages -- not the
# whole base image, and not pdns-recursor-luajit, which resolves to the
# identical version on both channels and was never named in this advisory
# at all -- kept edge-channel exposure to the minimum needed.
#
# Resolution (2026-08-07, issue #1483): Alpine's `edge` repo rebuilt
# `pdns`/`pdns-backend-sqlite3` to 5.1.4-r0 on 2026-08-06, superseding the
# pinned 5.1.3-r0 build outright -- `edge` is a rolling repo that does not
# keep old builds around, so the exact pin started failing `apk add` loudly
# (`exit code: 2`), which is exactly this pin's own documented
# fail-loud-not-silent-drift behavior (Rule-Ref: AG-VAL-026) firing as
# designed, not a new or separate defect. Checked live against Alpine's
# real package index (pkgs.alpinelinux.org, 2026-08-07): v3.24 stable now
# ships `pdns`/`pdns-backend-sqlite3` at 5.0.7-r0, past the CVE-2026-42005
# fix version (5.0.6) named above -- exactly the reevaluation trigger this
# comment named from the start ("once v3.24 stable itself picks up 5.0.6 or
# later ... the plain package should be preferred again"). The `@edge`
# repository lines and the `@edge=...` pins are therefore dropped entirely
# below: `pdns`/`pdns-backend-sqlite3` now resolve to the plain
# stable-channel 5.0.7-r0 packages, closing the CVE without the rolling-repo
# fragility that just broke every push/PR building this service.
# `pdns-recursor-luajit` was re-confirmed live (2026-08-07) to resolve to
# the identical version on both channels, so removing the edge repository
# lines does not change which build of it gets installed. Re-evaluate again
# (reintroduce an `@edge` pin, this time for a NEW CVE) only if a future
# advisory affects a version still shipping in v3.24 stable at that time --
# do not treat this resolution as a promise that `pdns`/`pdns-backend-sqlite3`
# will never need pinning again.
# What: findutils/envsubst/lsof/ripgrep from utilities image
# Why: same alpine:3.24 digest as services/proxy/Dockerfile
# From: Issue #1556

# What: removes BusyBox symlinks before real binaries land.
# Why: see services/proxy/Dockerfile's identical comment.
# From: Issue #1556
RUN rm -f /usr/bin/find /usr/bin/xargs /usr/bin/lsof

COPY --from=utilities-tools /usr/bin/curl /usr/bin/curl
COPY --from=utilities-tools /usr/lib/libcurl.so.4 /usr/lib/libcurl.so.4
COPY --from=utilities-tools /usr/lib/libz.so.1 /usr/lib/libz.so.1
COPY --from=utilities-tools /usr/lib/libcares.so.2 /usr/lib/libcares.so.2
COPY --from=utilities-tools /usr/lib/libnghttp2.so.14 /usr/lib/libnghttp2.so.14
COPY --from=utilities-tools /usr/lib/libidn2.so.0 /usr/lib/libidn2.so.0
COPY --from=utilities-tools /usr/lib/libpsl.so.5 /usr/lib/libpsl.so.5
COPY --from=utilities-tools /usr/lib/libssl.so.3 /usr/lib/libssl.so.3
COPY --from=utilities-tools /usr/lib/libcrypto.so.3 /usr/lib/libcrypto.so.3
COPY --from=utilities-tools /usr/lib/libzstd.so.1 /usr/lib/libzstd.so.1
COPY --from=utilities-tools /usr/lib/libbrotlidec.so.1 /usr/lib/libbrotlidec.so.1
COPY --from=utilities-tools /usr/lib/libunistring.so.5 /usr/lib/libunistring.so.5
COPY --from=utilities-tools /usr/lib/libbrotlicommon.so.1 /usr/lib/libbrotlicommon.so.1
COPY --from=utilities-tools /usr/bin/find /usr/bin/find
COPY --from=utilities-tools /usr/bin/xargs /usr/bin/xargs
COPY --from=utilities-tools /usr/bin/envsubst /usr/bin/envsubst
COPY --from=utilities-tools /usr/lib/libintl.so.8 /usr/lib/libintl.so.8
COPY --from=utilities-tools /usr/bin/lsof /usr/bin/lsof
COPY --from=utilities-tools /usr/bin/rg /usr/bin/rg
COPY --from=utilities-tools /usr/lib/libgcc_s.so.1 /usr/lib/libgcc_s.so.1
COPY --from=utilities-tools /usr/lib/libpcre2-8.so.0* /usr/lib/
COPY --from=utilities-tools /usr/local/bin/verify-version-banner.sh /usr/local/bin/verify-version-banner.sh

# What: verifies copied binaries actually run, not just exist.
# Why: missing shared-lib dep fails at exec time, not at COPY.
# From: Issue #1613
RUN set -euo pipefail; \
    find . -maxdepth 0 -printf '%f\n' >/dev/null; \
    printf '%s' '$FOO' | FOO=bar envsubst >/dev/null; \
    rg --version >/dev/null; \
    curl --version >/dev/null; \
    sh /usr/local/bin/verify-version-banner.sh "lsof version information" lsof -v

# What: switches apk's own repositories to plain http.
# Why: Squid caches http; signed indices keep integrity.
# From: Issue #1095
RUN sed -i 's|^https://|http://|' /etc/apk/repositories

# What: declares APT_CACHE_BUST right before the RUN it busts.
# Why: BuildKit cache has no wall-clock expiry without this ARG.
# From: Issue #1095
ARG APT_CACHE_BUST=""
# What: trusts the proxy's CA for this RUN, never in a layer.
# Why: a secret mount never persists; bundle restored below.
# From: Issue #1781 | PR #1783
RUN --mount=type=secret,id=proxy_ca \
    if [ -s /run/secrets/proxy_ca ]; then \
      cp /etc/ssl/certs/ca-certificates.crt /tmp/ca-bundle.orig && \
      cat /run/secrets/proxy_ca >> /etc/ssl/certs/ca-certificates.crt; \
    fi && \
    : "apt-cache-bust=${APT_CACHE_BUST}" && \
    apk upgrade --no-cache && \
    apk add --no-cache \
    pdns \
    pdns-backend-sqlite3 \
    pdns-recursor-luajit \
    bind-tools \
    sqlite \
    iproute2 \
    grep \
    coreutils \
    bash \
    nano && \
    if [ -s /run/secrets/proxy_ca ]; then mv /tmp/ca-bundle.orig /etc/ssl/certs/ca-certificates.crt; fi

# nano: in-container troubleshooting tool -- see services/proxy/Dockerfile's
# identical comment for the full rationale; lsof/ripgrep are COPY'd above
# but serve the same troubleshooting purpose. curl: unlike Kea's Control
# Agent (reachable from the host directly via network_mode: host),
# nats-subscriber's zone-rollback listener (port 8083, see
# rollback_listener.rs) is only `expose`d to the Compose network, never
# published to the host -- so `setup.sh reset-to-last-known-good-config
# dns`/`pdns` reaches it via `docker compose exec` into THIS container
# rather than calling it directly from the host. dhcp/proxy/ui/watchdog
# already carry curl for comparable internal/operational HTTP calls; this
# is the same justification, not a new pattern.
ENV EDITOR=nano
ENV VISUAL=$EDITOR

# The `pdns` user/group (uid 100/gid 101) is created by the pdns package's
# own pre-install script on Alpine (confirmed live via `getent passwd pdns`),
# same as Debian's package -- no separate useradd step needed on either base.
RUN mkdir -p /etc/pdns/auth /var/lib/powerdns /var/run/pdns \
    && chown -R pdns:pdns /var/lib/powerdns /var/run/pdns

COPY --from=subscriber-builder /build/nats-subscriber-out /usr/local/bin/nats-subscriber

COPY recursor.conf.template /etc/pdns/recursor.conf.template
COPY pdns.conf.template /etc/pdns/auth/pdns.conf.template
COPY recursor.lua /etc/pdns/recursor.lua
COPY filter-aaaa.lua /etc/pdns/filter-aaaa.lua
COPY cdn-domains.txt /etc/pdns/cdn-domains.txt
# Vendored gsqlite3 schema (see this file's own header comment for why
# Alpine's pdns-backend-sqlite3 package needs it where Debian's didn't).
COPY schema.sqlite3.sql /usr/share/lancache-ng/schema.sqlite3.sql
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 53/udp 53/tcp 8081 8082 8083

ENTRYPOINT ["/entrypoint.sh"]
