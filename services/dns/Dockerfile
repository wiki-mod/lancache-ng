
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# DNS service: PowerDNS (recursor + authoritative), nats-subscriber binary, Lua RPZ scripts.

# What: Base image pin, consumed from the version SOT.
# Why: build-manifest.yml is the sole owner of the pin.
# From: Issue #1683
ARG ALPINE_IMAGE

# What: builder image, supplied by ci.sh from the SOT.
# Why: no mutable default; CI resolves the immutable ref.
# From: Issue #1683
ARG BUILD_TOOLS_IMAGE
FROM ${BUILD_TOOLS_IMAGE} AS subscriber-builder

# What: musl cross-target, supplied by ci.sh per platform.
# Why: ci.sh owns arch mapping; no uname -m in the image.
# From: Issue #1683
ARG MUSL_TARGET

# What: cargo tuning args, consumed by ci.sh rust-build.
# Why: PROJECT_CARGO_*/CARGO_BUILD_JOBS own these (AG-CI-006).
# From: Issue #1683
ARG CARGO_BUILD_JOBS=
ARG PROJECT_CARGO_LTO=
ARG PROJECT_CARGO_CODEGENUNIT=
# What: redeclare BUILD_TOOLS_IMAGE for the RUN stage.
# Why: ci.sh rust-build folds it into the ccache key.
# From: Issue #1683
ARG BUILD_TOOLS_IMAGE

WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY services/dns/nats-subscriber/Cargo.toml services/dns/nats-subscriber/Cargo.toml
COPY services/ui/Cargo.toml services/ui/Cargo.toml
COPY services/cachehamster/Cargo.toml services/cachehamster/Cargo.toml
COPY services/watchdog/Cargo.toml services/watchdog/Cargo.toml
COPY tools/pxe-client-probe/Cargo.toml tools/pxe-client-probe/Cargo.toml
# What: stub targets for workspace members not built here.
# Why: cargo loads every member manifest to resolve deps.
# From: Issue #1095
RUN mkdir -p services/ui/src services/cachehamster/src \
      services/watchdog/src tools/pxe-client-probe/src \
    && printf 'fn main() {}\n' > services/ui/src/main.rs \
    && : > services/ui/src/lib.rs \
    && printf 'fn main() {}\n' > services/cachehamster/src/main.rs \
    && : > services/cachehamster/src/lib.rs \
    && printf 'fn main() {}\n' > services/watchdog/src/main.rs \
    && : > services/watchdog/src/lib.rs \
    && printf 'fn main() {}\n' > tools/pxe-client-probe/src/main.rs
COPY services/dns/nats-subscriber/src services/dns/nats-subscriber/src
# What: ci.sh owns the rust build accel policy (one owner).
# Why: AG-CI-005/022/023; bind-mounted, never baked in.
# From: Issue #1683
RUN --mount=type=bind,source=.github/scripts/ci.sh,target=/usr/local/bin/ci.sh \
    --mount=type=secret,id=sccache_redis_url \
    --mount=type=secret,id=sccache_dist_config \
    --mount=type=secret,id=distcc_potential_hosts \
    --mount=type=secret,id=ccache_redis_url \
    --mount=type=secret,id=project_selfhosted_proxy_ca \
    bash /usr/local/bin/ci.sh rust-build dns nats-subscriber

FROM ${ALPINE_IMAGE}

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
# work above). Same ALPINE_IMAGE build-arg already used by services/dhcp,
# services/dhcp-proxy, and services/watchdog (issues #815/#1234/#1346), now
# sourced from build-manifest.yml's single SOT pin (issue #1683), so every
# Alpine-based service in this project tracks one shared, intentional
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
# What: shared version-banner script, not a per-service copy.
# Why: named build context avoids duplicating it per service.
# From: Issue #1781 | PR #1783
COPY --from=shared-scripts verify-version-banner.sh /usr/local/bin/verify-version-banner.sh

# What: copies the domain-validation library in.
# Why: entrypoint.sh no longer embeds a byte-identical copy.
# From: Issue #1683
COPY --from=shared-scripts domain-validation.sh /usr/local/lib/domain-validation.sh

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
RUN --mount=type=secret,id=project_selfhosted_proxy_ca \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then \
      cp /etc/ssl/certs/ca-certificates.crt /var/tmp/ca-bundle.orig && \
      cat /run/secrets/project_selfhosted_proxy_ca >> /etc/ssl/certs/ca-certificates.crt; \
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
    nano \
    curl \
    findutils \
    gettext-envsubst \
    lsof \
    ripgrep && \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then mv /var/tmp/ca-bundle.orig /etc/ssl/certs/ca-certificates.crt; fi

# nano: in-container troubleshooting tool -- see services/proxy/Dockerfile's
# identical comment for the full rationale; lsof/ripgrep are apk-installed
# above but serve the same troubleshooting purpose. curl: unlike Kea's Control
# Agent (reachable from the host directly via network_mode: host),
# nats-subscriber's zone-rollback listener (port 8083, see
# rollback_listener.rs) is only `expose`d to the Compose network, never
# published to the host -- so `setup.sh reset-to-last-known-good-config
# dns`/`pdns` reaches it via `docker compose exec` into THIS container
# rather than calling it directly from the host. dhcp/proxy/ui/watchdog
# already carry curl for comparable internal/operational HTTP calls; this
# is the same justification, not a new pattern.

# What: verifies apk-installed binaries execute, not just exist.
# Why: missing library dependencies fail at runtime, not apk add.
# From: Issue #1613 | Issue #1781 | PR #1783
RUN set -euo pipefail; \
    find . -maxdepth 0 -printf '%f\n' >/dev/null; \
    printf '%s' '$FOO' | FOO=bar envsubst >/dev/null; \
    rg --version >/dev/null; \
    curl --version >/dev/null; \
    sh /usr/local/bin/verify-version-banner.sh "lsof version information" lsof -v

ENV EDITOR=nano
ENV VISUAL=$EDITOR

# The `pdns` user/group (uid 100/gid 101) is created by the pdns package's
# own pre-install script on Alpine (confirmed live via `getent passwd pdns`),
# same as Debian's package -- no separate useradd step needed on either base.
RUN mkdir -p /etc/pdns/auth /var/lib/powerdns /var/run/pdns \
    && chown -R pdns:pdns /var/lib/powerdns /var/run/pdns

COPY --from=subscriber-builder /build/nats-subscriber-out /usr/local/bin/nats-subscriber

COPY services/dns/recursor.conf.template /etc/pdns/recursor.conf.template
COPY services/dns/pdns.conf.template /etc/pdns/auth/pdns.conf.template
COPY services/dns/recursor.lua /etc/pdns/recursor.lua
COPY services/dns/filter-aaaa.lua /etc/pdns/filter-aaaa.lua
COPY services/dns/cdn-domains.txt /etc/pdns/cdn-domains.txt
# Vendored gsqlite3 schema (see this file's own header comment for why
# Alpine's pdns-backend-sqlite3 package needs it where Debian's didn't).
COPY services/dns/schema.sqlite3.sql /usr/share/lancache-ng/schema.sqlite3.sql
COPY services/dns/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# What: fail build if CI proxy CA leaked into image
# Why: CA must never persist in a published service image
# From: Issue #1781 | PR #1783
RUN if [ -e /usr/local/share/ca-certificates/lancache-ci-proxy-ca.crt ]; then \
      echo "SECURITY: CI proxy CA persisted in final image" >&2; exit 1; \
    fi

# What: final apk upgrade pass, no packages added.
# Why: patches CVEs fixed after this file's package installs.
# From: Issue #1781 | PR #1783
RUN apk upgrade --no-cache

EXPOSE 53/udp 53/tcp 8081 8082 8083

ENTRYPOINT ["/entrypoint.sh"]
