#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# Dedicated entrypoint for the standalone `retention` sidecar container
# (#842 Teil 2, 2026-08-01). Was previously a generic wrapper that launched
# retention.sh as a background process inside the SAME container as
# watchdog.sh (see git history / PR #1360 for that earlier shape); now that
# retention.sh runs in its own compose service with its own cap_drop/
# read_only/non-root lockdown, this file's only job is the privilege-drop
# sequence below, then a plain `exec` into retention.sh -- no more
# backgrounding/supervision needed here, because a genuinely separate
# container already gets crash-restart for free from Compose's own
# `restart: always` on this service, which is simpler and more standard
# than this image re-implementing process supervision inside itself.
#
# --- Why this starts as root and drops privilege internally, rather than
# the compose service just setting `user: "10001:10001"` directly ---
#
# The maintainer's Teil 2 instruction named a plain non-root user
# (`lancache`, uid/gid 10001, matching services/ui/Dockerfile's existing
# convention) as what to run this container as. A bare compose `user:`
# directive cannot deliver that AND retention.sh's actual job at the same
# time, and this is not a corner that got cut quietly -- see this PR's own
# body for the full empirical evidence, summarized here:
#
# retention.sh must delete files it does not own, across three volumes this
# service does not control the permissions of: nginx's proxy-cache entries
# (confirmed live: nginx creates these `nginx:nginx` on services/proxy's
# current Alpine base -- re-confirmed 2026-08-06, issue #815; the owning
# username changed from Debian's `www-data` when that migration landed, but
# the mode stays 0700/0600, no group or "other" bits at all, hardcoded by
# nginx itself, not configurable), syslog-ng's output tree (root-owned, `dir-perm(0750)` --
# already `chgrp`'d to this same gid 10001 for the Admin UI's READ-ONLY
# access, but group has no WRITE bit, so that sharing does not extend to
# deletion), and fluent-bit's own self-log (root-owned by that pinned
# image's own default `Config.User: "0"`, no ownership scheme we control at
# all, since we don't own that Dockerfile). Plain Unix permission bits, at
# any UID/GID retention.sh could plausibly run as, do not clear a path
# through all three. What does is CAP_DAC_OVERRIDE -- and per Docker/Linux's
# own capability model, confirmed empirically on a real runner
# (`grep Cap /proc/self/status` before/after): a capability added via
# compose `cap_add` only lands in a container's BOUNDING set for a non-root
# `user:`, not its EFFECTIVE set (CapEff read back as all-zero in that
# configuration) -- the capability exists but the kernel does not let a
# non-root UID actually use it unless it was raised into the AMBIENT set by
# a privileged parent before the UID switch. That is exactly what `setpriv`
# below does: start as root (so the container's `cap_add: [DAC_OVERRIDE,
# SETUID, SETGID, SETPCAP, CHOWN]` capabilities are actually available to
# use), chown the paths this container itself must own (see below), raise
# ONLY DAC_OVERRIDE into the inheritable/ambient sets, narrow the bounding
# set down to just that one capability (dropping SETUID/SETGID/SETPCAP/CHOWN
# themselves back out -- they were only ever needed transiently, for this
# exact reuid/regid/bounding-set sequence and the chown step below,
# confirmed by re-reading /proc/self/status after the switch: CapInh/CapPrm/
# CapEff/CapBnd/CapAmb all show only DAC_OVERRIDE, nothing else survives),
# then switch to uid/gid 10001 and exec retention.sh. The resulting process
# is genuinely running as `lancache`/10001, with exactly one non-default
# capability, not root, not "cap_drop: ALL with a user: line that quietly
# doesn't do what it looks like it does." CHOWN itself was found the hard
# way, not assumed up front: the first real end-to-end container run of this
# script failed at the chown step below with "Operation not permitted" --
# `cap_drop: ALL` removes CHOWN from root itself, not merely from the
# eventual non-root user, so root needs it added back too, transiently, the
# same as SETUID/SETGID/SETPCAP above.
#
# Read this alongside the compose service's own comment on why the REAL
# containment boundary here is the mount set (which volumes are even
# present in this container) plus `read_only: true` (genuinely not defeated
# by DAC_OVERRIDE, since that capability only bypasses permission CHECKS on
# paths the kernel already lets this mount namespace see) -- CAP_DAC_OVERRIDE
# itself is a real, broad bypass of file permission checks on every mounted
# path, not a small residual detail, and this file does not pretend
# otherwise.
set -euo pipefail

mkdir -p /var/log/lancache-watchdog

# Bind mounts and named volumes are often root-owned the first time a
# container ever starts against them (a fresh named volume, or a bind-mount
# host directory Docker auto-created) -- same reasoning as
# services/ui/docker-entrypoint.sh's identical chown-before-privilege-drop
# step. Both paths below are ones THIS container writes to directly
# (retention-state holds retention.sh's own PURGE_STAMP/SYSLOG_PRUNE_STAMP,
# deliberately on its own dedicated volume separate from watchdog's
# unrelated status.json -- see #842 Teil 2's architecture decision; the
# shared watchdog-logs volume is where this script's own tee below writes
# retention.log, alongside watchdog.sh's unrelated watchdog.log in the same
# volume). Every OTHER volume this container mounts (proxy-cache,
# syslog-ng's log tree, fluent-bit's self-log) is owned by a different
# service entirely and deliberately NOT chowned here -- only DAC_OVERRIDE
# below (not ownership) is what lets retention.sh act on those.
for path in /var/lib/lancache-retention-state /var/log/lancache-watchdog; do
    if [ -e "$path" ]; then
        chown -R lancache:lancache "$path"
    fi
done
chgrp 10001 /var/log/lancache-watchdog
chmod 2750 /var/log/lancache-watchdog
find /var/log/lancache-watchdog -maxdepth 1 -type f -exec chmod g+r {} +

# --reuid/--regid: switch to the fixed lancache uid/gid (10001) the
# maintainer named, matching services/ui/Dockerfile's existing account.
# --clear-groups: this container has no legitimate use for any
# supplementary group -- DAC_OVERRIDE below is what grants file access, not
# group membership, so carrying over root's own supplementary groups would
# be pure unused residual privilege.
# --inh-caps / --ambient-caps: raise ONLY dac_override into the sets a
# non-root process actually needs it in to keep using it post-switch (a
# capability that stays merely "permitted" without also being "ambient"
# is dropped from a non-root process's effective set the moment it execs
# anything -- confirmed empirically, see header comment above).
# --bounding-set=-all,+dac_override: narrow what capabilities could ever be
# (re-)acquired going forward to just this one, dropping setuid/setgid/
# setpcap themselves out of the final process entirely, not just leaving
# them unused -- requires CAP_SETPCAP to actually take effect (confirmed:
# omitting SETPCAP from cap_add left CapBnd showing setuid/setgid still
# present even though this option was passed; adding it back is what
# actually empties them out, verified via /proc/self/status both ways).
exec setpriv \
    --reuid=10001 --regid=10001 --clear-groups \
    --inh-caps=+dac_override --ambient-caps=+dac_override \
    --bounding-set=-all,+dac_override \
    /bin/bash -c 'umask 0027; exec /retention.sh > >(tee -a /var/log/lancache-watchdog/retention.log) 2>&1'
