#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: retention entrypoint; drop root to uid 10001.
# Why: cap_add never reaches a non-root CapEff directly.
# From: Issue #842
set -euo pipefail

mkdir -p /var/log/lancache-watchdog

# What: chown only the two paths this container writes.
# Why: fresh volumes start root-owned; other mounts stay.
# From: Issue #842
for path in /var/lib/lancache-retention-state /var/log/lancache-watchdog; do
    if [ -e "$path" ]; then
        chown -R lancache:lancache "$path"
    fi
done
chgrp 10001 /var/log/lancache-watchdog
# What: set mode as owner 10001, not as capped root.
# Why: no CAP_FOWNER/FSETID here; root chmod is EPERM.
# From: Issue #1683 | PR #1858
setpriv --reuid=10001 --regid=10001 --clear-groups \
    chmod 2750 /var/log/lancache-watchdog
setpriv --reuid=10001 --regid=10001 --clear-groups \
    find /var/log/lancache-watchdog -maxdepth 1 -type f -exec chmod g+r {} +

# What: run as 10001 keeping only ambient dac_override.
# Why: it deletes foreign files; nothing else survives.
# From: Issue #842
exec setpriv \
    --reuid=10001 --regid=10001 --clear-groups \
    --inh-caps=+dac_override --ambient-caps=+dac_override \
    --bounding-set=-all,+dac_override \
    /bin/bash -c 'umask 0027; exec /retention.sh > >(tee -a /var/log/lancache-watchdog/retention.log) 2>&1'
