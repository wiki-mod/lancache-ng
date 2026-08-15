
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# ghcr.io/wiki-mod/lancache-ng/utilities: a shared image for common,
# non-compiler CLI tools (curl, nano, lsof, ripgrep, findutils, coreutils,
# gettext-envsubst, jq, ca-certificates, zstd), meant to let other
# first-party images consume these binaries via
# `COPY --from=ghcr.io/wiki-mod/lancache-ng/utilities:<ref> ...` instead of
# each one independently installing/building its own copy from its own
# package repository. Compiler/build-toolchain content (gcc-equivalent:
# build-essential, clang, cmake, make, pkg-config, ccache, lld, distcc,
# bats, shellcheck) stays in tools/build-tools -- this image is deliberately
# scoped to network/shell utility binaries only. `bash` is a deliberate
# maintainer decision NOT to include here: it is lean enough already in
# each service's own image that the indirection is not worth it. From:
# Issue #1556
#
# SCOPE OF THIS PASS: this PR builds and publishes the image itself. It does
# NOT migrate any consuming service's Dockerfile from its own `apk add`/
# `apt-get install` to `COPY --from=utilities` -- that is deliberately a
# separate, second step (per-service justification, e.g. "why does
# services/dhcp really need ripgrep", is its own review, not this one).
#
# WHY curl alone is a fully static, from-source build while every other tool
# here is an ordinary `apk add` package: curl already went through a
# dedicated feature-reduction evaluation on this issue (see the issue's own
# comment history) that starts from this project's real, grep-confirmed curl
# usage (tools/build-tools's build-time downloads; the `-K -` stdin-config
# GitHub-API pattern in scripts/lib/staging-ancestor-fallback.sh; every
# full-setup-deep-validate simulation script using the build-tools image as
# an HTTP(S) test client) and compiles out FTP/SFTP/SCP/TELNET/TFTP/LDAP/
# DICT/GOPHER/MQTT/POP3/IMAP/SMTP/proxy support this project never uses --
# eliminating 2 of the 4 currently-tracked curl CVEs by physically removing
# the vulnerable code (confirmed by the binary's own runtime refusal of the
# now-unsupported protocol), not merely hiding them. Going fully static
# (`--disable-shared --enable-static`, confirmed via `file` reporting
# "statically linked", zero shared-library dependencies) is what makes this
# ONE binary portable into any consumer regardless of glibc/musl -- the
# concrete property a future `tools/build-tools` (Debian/glibc) consumer
# would need, per the issue's own architecture question. None of the other 9
# tools has an equivalent reason to leave its own distro packaging: they
# have no comparable feature-reduction/CVE story, and Alpine's own package
# builds already give real, Trivy-visible package-manager registration for
# free (see the Trivy-visibility section below) -- reproducing curl's
# from-source/static treatment for all 9 would recreate the exact
# invisibility problem this file's own Trivy-visibility section solves for
# them, for no compensating security benefit.
#
# CROSS-LIBC PORTABILITY, per tool (relevant to a future `tools/build-tools`
# consumer specifically, since every other first-party image is already
# Alpine like this one -- issue #815):
#   - curl: base-independent (static, see above). Runs unmodified on glibc
#     or musl.
#   - nano/lsof/ripgrep/findutils/coreutils/gettext-envsubst/jq/zstd: ALL
#     ordinary Alpine (musl) dynamic binaries -- each links against musl
#     libc and its own package-specific shared libraries (e.g. ripgrep
#     against pcre2, zstd against zstd-libs). None of these binaries alone
#     is portable to a glibc host via a bare `COPY --from=`; doing that
#     would need the same shared-library-closure treatment
#     services/syslog's Dockerfile already uses for fluent-bit (a
#     pre-built third-party binary this project does not compile itself),
#     or a from-source static rebuild analogous to curl's. Not attempted
#     here: no live glibc consumer exists yet for any of these 8 (deferred,
#     per this file's own Scope note above, to the future per-tool
#     migration pass that would actually need it).
#   - ca-certificates: not a binary, a data file
#     (/etc/ssl/certs/ca-certificates.crt) -- inherently base-independent
#     content, no linkage concerns at all.
#
# TRIVY-VISIBILITY (issue #1556 point 7, and this project's own established
# fact from issue #1304): a self-built, package-manager-unregistered binary
# is invisible to Trivy's os-pkg scanner -- a clean scan produced this way is
# not evidence of reduced risk, it can be the opposite, a false "fixed"
# signal. Concretely solved for 9 of these 10 tools, not merely asserted:
# nano/lsof/ripgrep/findutils/coreutils/gettext-envsubst/jq/zstd/
# ca-certificates are installed via ordinary `apk add` directly into this
# final image stage (not copied from a throwaway builder stage), so this
# image's own apk package database genuinely lists each one with its real
# Alpine package name and version -- exactly what Trivy's `os-pkgs` analyzer
# reads. Verified empirically on a real runner before this Dockerfile was
# written: an `apk add`-built probe image showed a real `os-pkgs`/`alpine`
# scan target with all installed packages tracked (Trivy's own
# `pkg_num=<n>` log line), not an empty/absent scan target -- the visibility
# mechanism itself is confirmed working, independent of whether today's
# specific package versions happen to carry a currently-tracked HIGH/
# CRITICAL/MEDIUM/LOW finding or not (0 findings from a *registered*
# package is a legitimate "nothing currently tracked", not the invisible-
# binary false-clean case this section exists to distinguish from).
#
# curl remains the one tool NOT solved by this mechanism: it is a
# fully static, from-source, non-apk-managed binary by deliberate design
# (see above), so it carries no apk database entry and is therefore
# Trivy-invisible in this image too, exactly as issue #1556's own
# evaluation already found and documented for the standalone binary. A real
# local-package build (Alpine's `abuild`) was evaluated as a way to close
# this specific gap by registering the static curl binary under a real apk
# package entry -- confirmed technically possible on a real runner (abuild
# successfully produces an installable local .apk once its package
# contents are placed under a path Alpine's own packaging postcheck
# accepts, e.g. /usr/bin rather than /usr/local). Not adopted here: Trivy
# matches vulnerabilities by package NAME against its own vulnerability
# database, so a locally-built package would either need a name that does
# not match Alpine's real `curl` package (in which case it matches nothing,
# reproducing the same invisibility this section exists to fix) or a name
# that DOES match (in which case it would need Alpine's own package
# versioning scheme, not upstream's raw version string, to produce correct
# matches instead of spurious ones) -- getting this right is a real,
# separate packaging exercise this pass does not attempt, and forcing it
# through now risked shipping a match that looks resolved but is actually
# wrong (a worse outcome than a disclosed gap). curl's Trivy-invisibility is
# therefore recorded here as a deliberate, documented exception rather than
# silently left unaddressed -- see this issue's own comment history for the
# full option evaluation (register under the real upstream name+version,
# then track the 2 genuinely-eliminated CVE IDs as OpenVEX
# `not_affected`/`vulnerable_code_not_present` via this repo's existing
# `scripts/generate-vex.sh`/`.trivyignore.yaml` machinery) as the concrete
# follow-up path, scoped to a future pass that actually adopts this binary
# inside a real consumer, not fabricated here against an image with no live
# consumer yet.
#
# COREUTILS/FINDUTILS, real usage inventory (kept for the future per-service
# COPY --from= migration this issue deliberately defers to a separate Step
# 2, see below): `findutils`'s own real usage across every current consumer
# needs exactly `find`/`xargs` (confirmed: `apk info -a findutils` lists
# only these two commands -- the package is already minimal, nothing to
# narrow). `coreutils`'s real, grep-confirmed usage across this project's
# own service Dockerfiles is `basename`, `cp`, `date`, `dirname`, `install`,
# `mktemp`, `mv`, `rm`, `sort`, `realpath` (services/dhcp-proxy,
# services/dns, services/proxy, services/watchdog Dockerfiles' own coreutils
# rationale comments), plus `base64`/`od` (services/ui/Dockerfile's own
# coreutils rationale comment).
#
# This Dockerfile does NOT narrow the installed `coreutils` package down to
# only that list, despite an earlier version of this file attempting
# exactly that. Reversed after a real functional regression was found by
# this Dockerfile's own pre-completion verification, not assumed: Alpine's
# `coreutils-9.11-r0` package is not ~100 separate binaries but a single
# ~773 KiB multi-call binary (`/bin/coreutils`, 1125 KiB installed total per
# `apk info coreutils -s`, the remainder being symlink/directory metadata)
# with every command name a symlink to it -- the same design BusyBox itself
# uses. Deleting the unwanted symlinks therefore saves an amount of space
# indistinguishable from zero, while actively breaking the image: installing
# `coreutils` overwrites several of the base `alpine:3.24` image's own
# pre-existing BusyBox symlinks (`cat`, `cp`, `date`, `echo`, `ls`, `sleep`,
# `stat`, `touch`, `true`, `uname`, `head`, `tail`, `cut`, `tr`, `wc`,
# `sha256sum`, among others) with symlinks to `/bin/coreutils` instead, and
# deleting those (because they were outside the narrow keep list above)
# left NEITHER the coreutils symlink NOR the original BusyBox symlink at
# those paths -- commands the base image could serve before `coreutils` was
# ever installed, silently gone. See the RUN step below for the full,
# corrected rationale and the real command that first exposed this
# (`docker run --rm <image> true` failing with "executable file not
# found"). Trivy visibility (this section's whole point) is unaffected
# either way: apk registration happens at install time regardless of what
# happens to individual files afterward.
FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS curl-builder

# Pinned upstream curl release + a checksum this build verifies against
# before extracting anything, matching this project's established pattern
# for other checksum-verified third-party downloads (see
# tools/build-tools/Dockerfile's cargo-audit/cargo-tarpaulin/shellspec
# fetches, AG-KD-003). Trust model: HTTPS download from curl.se's own
# domain + a pinned SHA-256, the same trust model this project's existing
# tool downloads already use -- not a new, weaker one.
ARG CURL_VERSION=8.21.0
ARG CURL_SHA256=aa1b66a70eace83dc624508745646c08ae561de512ab403adffb93ac87fc72e6

RUN set -euo pipefail; \
    apk add --no-cache --virtual .fetch-deps curl ca-certificates; \
    curl -fsSL "https://curl.se/download/curl-${CURL_VERSION}.tar.xz" -o /tmp/curl.tar.xz; \
    printf '%s  %s\n' "${CURL_SHA256}" /tmp/curl.tar.xz | sha256sum -c -; \
    tar -xJf /tmp/curl.tar.xz -C /tmp; \
    apk del .fetch-deps

# libpsl (Public Suffix List, stricter cross-domain cookie scoping) is
# deliberately left out (--without-libpsl below): Alpine's libpsl-static
# package does not link cleanly against a fully static curl build (its
# pkg-config .pc file has no static Libs.private closure), and this
# project's own curl usage only ever talks to a small, fixed, already-
# trusted host set (github.com/api.github.com, this project's own
# Compose-network services) -- not the arbitrary-third-party-domain
# threat model libpsl protects against.
RUN apk add --no-cache \
      build-base \
      file \
      perl \
      openssl-dev \
      openssl-libs-static \
      zlib-dev \
      zlib-static \
      ca-certificates

# `LDFLAGS="-static"` alone does NOT force a genuinely static binary here --
# confirmed empirically (real build, real `ldd`): curl's build uses libtool
# for its final link step, and libtool's own bare-`-static` handling only
# affects its OWN managed libraries (libcurl.la); it does not forward
# `-static` to the underlying `-lssl -lcrypto -lz` link flags for
# externally-provided (non-libtool) libraries, so the linker kept resolving
# those against Alpine's normal `.so` files even with `--disable-shared`
# and the already-installed `openssl-libs-static`/`zlib-static` `.a` files
# in place. The reliable fix: remove the unversioned `.so` linker symlinks
# (`-lssl`/`-lcrypto`/`-lz` resolve to these exact names, never the
# versioned runtime `.so.N` files) so only the `.a` static archives remain
# resolvable -- this builder stage is thrown away, so this has no effect
# outside this one image build.
RUN rm -f /usr/lib/libssl.so /usr/lib/libcrypto.so /usr/lib/libz.so

WORKDIR /tmp/curl-${CURL_VERSION}

# Configure flags map directly to this project's real, grep-confirmed curl
# usage (build-time HTTPS downloads; the `-K -` stdin-config Bearer-header
# GitHub API pattern; `-u` HTTP Basic auth against Kea's Control Agent;
# cookie jars for CSRF-session simulations; `--resolve`; `--cacert`/`-k` for
# this project's own MITM CA; `-w`/`-D`/`-d @-`/`-X` method overrides) --
# needs plain HTTP/HTTPS, TLS verification, DNS overrides, Basic auth,
# cookies, and config-from-stdin; never uses FTP/SFTP/SCP/TELNET/TFTP/LDAP/
# DICT/GOPHER/MQTT/POP3/IMAP/SMTP, a proxy, IPFS, WebSockets, RTMP,
# internationalized domains, Brotli/Zstd compression, or HTTP/2/3 anywhere
# (repo-wide grep, not assumed).
#   CFLAGS="-fno-PIE" LDFLAGS="-no-pie": Alpine's gcc defaults to
#     `--enable-default-pie`, so a bare `LDFLAGS="-static"` silently loses
#     to the toolchain default and produces an ordinary dynamically-linked
#     PIE binary instead of erroring (confirmed empirically: a first
#     attempt without `-no-pie` showed real `ldd` dependencies on
#     `libssl.so.3`/`libcrypto.so.3`/`libz.so.1`/musl's own libc despite
#     `--disable-shared`/`--enable-static` and the static archives both
#     being in place). A true static binary and PIE are mutually exclusive
#     without static-PIE toolchain support this project does not need.
RUN set -euo pipefail; \
    ./configure \
      --disable-shared --enable-static \
      --disable-ftp --disable-file --disable-ldap --disable-ldaps \
      --disable-rtsp --disable-dict --disable-telnet --disable-tftp \
      --disable-pop3 --disable-imap --disable-smtp --disable-smb \
      --disable-gopher --disable-mqtt \
      --disable-scp --disable-sftp --without-libssh2 --without-libssh \
      --disable-proxy \
      --disable-ntlm --disable-kerberos-auth --disable-negotiate-auth \
      --disable-aws \
      --disable-manual --disable-libcurl-option \
      --disable-ipfs --disable-websockets \
      --without-librtmp --without-libidn2 --without-brotli --without-zstd \
      --without-nghttp2 --without-nghttp3 --without-ngtcp2 --without-libpsl \
      --with-openssl \
      --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
      --enable-http --enable-cookies --enable-ipv6 \
      CFLAGS="-fno-PIE" LDFLAGS="-no-pie" PKG_CONFIG="pkg-config --static"; \
    make -j"$(nproc)" LDFLAGS="-all-static -no-pie"; \
    mkdir -p /out/usr/local/bin /out/etc/ssl/certs; \
    install -m 0755 src/curl /out/usr/local/bin/curl; \
    /out/usr/local/bin/curl --version; \
    curl_file_type="$(file /out/usr/local/bin/curl)"; \
    case "$curl_file_type" in \
      *"statically linked"*) ;; \
      *) echo "ERROR: curl build is not fully static: $curl_file_type" >&2; exit 1 ;; \
    esac
# `-all-static` (not bare `-static`) on the `make` invocation, separately
# from `./configure`'s own flags: libtool treats a bare `-static` as its own
# internal directive (prefer libtool-managed libraries in static form,
# already true for libcurl.la) and deliberately does not forward it
# verbatim to the compiler driver for non-libtool system libraries;
# `-all-static` is the documented libtool-recognized flag for that, but it
# is unknown to a raw `gcc` invocation, so it must apply only to `make`
# (which routes through libtool), not to `./configure`'s own compiler
# sanity check (which invokes `gcc` directly and would fail with
# "C compiler cannot create executables" if given it) -- confirmed
# empirically both ways here.
#
# `install(1)` directly on the already-confirmed-static `src/curl`, not
# `make install`: confirmed empirically (3 separate reproductions) that
# automake's generated `install-exec` recipe re-invokes libtool's own link
# step internally with a different LDFLAGS resolution than the one just
# used to build `src/curl` cleanly, silently producing a DYNAMIC binary
# again every time. Sidestepping libtool's install path for this one file
# avoids the problem outright.
#
# `file`, not `ldd`, is the portable static-linkage check: musl's `ldd`
# wrapper reports a genuinely static binary differently than glibc's does,
# not a stable string across the two libc families; `file`'s "statically
# linked" wording is identical across glibc and musl `file` builds
# (confirmed here). The producer's full output is captured into
# `curl_file_type` first and matched via `case`, not piped live into
# `grep -q` (Rule-Ref: AG-VAL-032): this `RUN` runs under
# `set -o pipefail`, and `grep -q` is exactly the early-exiting consumer
# class that rule requires avoiding a live pipe for.

# Final stage: this IS the `ghcr.io/wiki-mod/lancache-ng/utilities` image
# itself. Alpine here is only this stage's OWN runtime base -- irrelevant to
# curl's own portability (static, see above); the other 9 tools are
# ordinary Alpine (musl) dynamic binaries, see the cross-libc-portability
# note above.
FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

# `apk upgrade --no-cache` before installing anything else upgrades packages
# already baked into the alpine:3.24 base layer itself (musl, busybox,
# apk-tools) -- matching every other first-party Alpine service's own
# established pattern (see e.g. services/dhcp-proxy/Dockerfile's identical
# block and rationale).
#
# Every package below is installed as an ordinary apk package (not copied
# from a throwaway builder stage) so this image's own apk database
# genuinely registers each one -- see the Trivy-visibility section above.
RUN apk upgrade --no-cache && \
    apk add --no-cache \
      nano \
      lsof \
      ripgrep \
      findutils \
      coreutils \
      gettext-envsubst \
      jq \
      zstd \
      ca-certificates

# `coreutils` is installed WITHOUT narrowing its shipped binary set, despite
# the original plan (see the COREUTILS/FINDUTILS NARROWING section above)
# to delete every file outside the real, grep-confirmed keep list. That plan
# was reversed after a real, empirically-confirmed finding contradicted its
# own premise, caught by this Dockerfile's own functional verification
# (`docker run --rm <image> true` failing with "executable file not found")
# during a pre-completion review, not assumed or reasoned around:
#   1. This Alpine coreutils build (9.11-r0) is NOT ~100 separate binaries --
#      it is one real multi-call binary, `/bin/coreutils` (773 KiB;
#      `apk info coreutils -s` reports 1125 KiB installed total, the
#      difference being ~350 KiB of directory/symlink metadata), with every
#      individual command name a symlink to it -- the identical design
#      BusyBox itself uses (confirmed live: `ls -la /usr/bin/basename` shows
#      `-> ../../bin/coreutils`). Deleting the unwanted symlinks therefore
#      saves nothing close to "not shipping ~90 unneeded programs worth of
#      bytes" -- the actual, measured saving is effectively zero (a few
#      dozen bytes of symlink inodes), because the code they all point to
#      stays in the image regardless of which names may call it.
#   2. Alpine's `alpine:3.24` base image pre-populates `/bin/cat`, `/bin/cp`,
#      `/bin/date`, `/bin/echo`, `/bin/ls`, `/bin/sleep`, `/bin/stat`,
#      `/bin/touch`, `/bin/true`, `/bin/uname`, `/usr/bin/head`,
#      `/usr/bin/tail`, `/usr/bin/cut`, `/usr/bin/tr`, `/usr/bin/wc`,
#      `/usr/bin/sha256sum` (among others) as symlinks to BusyBox. Installing
#      the `coreutils` apk package OVERWRITES those same paths with symlinks
#      to `/bin/coreutils` instead (apk package installation replaces
#      conflicting paths, it does not coexist alongside them) -- so an
#      earlier version of this Dockerfile that then deleted every coreutils-
#      owned file outside its ~12-name keep list left NEITHER the coreutils
#      symlink NOR the original BusyBox symlink at dozens of paths the base
#      image itself could serve before `coreutils` was ever installed. That
#      is a real functional regression (this image would ship without
#      working `cat`/`ls`/`head`/`tail`/`cut`/`tr`/`wc`/`stat`/`chmod`/
#      `touch`/`sha256sum`/`true`, none of which this Dockerfile's own
#      original functional test suite happened to exercise, since it only
#      checked tools ADDED, never tools potentially REMOVED from the base
#      image's own prior capability), not a size optimization worth that
#      cost -- confirmed by measuring, not assumed.
# Trivy visibility for this package is unaffected either way (apk
# registration happens at install time regardless of what happens
# afterward) -- narrowing was never actually necessary for that goal, only
# for the separately-stated "don't ship ~100 unneeded programs" concern,
# which point 1 above shows does not actually apply to this specific
# package's real on-disk shape. The real, grep-confirmed set of coreutils/
# findutils commands this project's own consumers actually call --
# `basename`, `cp`, `date`, `dirname`, `install`, `mktemp`, `mv`, `rm`,
# `sort`, `realpath`, `base64`, `od` (coreutils) and `find`/`xargs`
# (findutils, already minimal, see above) -- remains valuable as the input
# to a future per-service `COPY --from=` migration (issue #1556's own
# deliberately separate Step 2), which is why it stays documented above
# even though this Dockerfile itself no longer acts on it by deleting
# anything.
RUN set -euo pipefail; \
    for expected in basename cp date dirname install mktemp mv rm sort realpath base64 od find xargs; do \
      command -v "$expected" >/dev/null 2>&1 || { echo "ERROR: expected coreutils/findutils binary missing: $expected" >&2; exit 1; }; \
    done

COPY --from=curl-builder /out/usr/local/bin/curl /usr/local/bin/curl
