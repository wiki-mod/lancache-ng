#!/bin/sh
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Admin UI container entrypoint: fixes up ownership on shared/bind-mounted
# data paths when started as root, then drops privileges to the unprivileged
# `lancache` user before exec-ing the real command.
set -eu

# Bind mounts and shared volumes are often created as root-owned paths at
# container start, after image-time chown has run. When the entrypoint starts as
# root, normalize the writable paths before dropping privileges so Admin UI
# writes -- including init_tracing()'s ui.log file under /var/log/lancache-ui
# (#633 central logging pipeline) -- keep working. If an operator overrides
# the container user, do not try to chown or call setpriv from an
# unprivileged account.
if [ "$(id -u)" = "0" ]; then
    for path in /data /etc/nats /var/lib/powerdns-state /var/log/lancache-ui; do
        if [ -e "$path" ]; then
            chown -R lancache:lancache "$path"
        fi
    done

    exec setpriv --reuid=lancache --regid=lancache --init-groups "$@"
fi

exec "$@"
