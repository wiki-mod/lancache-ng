#!/bin/sh
set -eu

# Bind mounts and shared volumes are often created as root-owned paths at
# container start, after image-time chown has run. When the entrypoint starts as
# root, normalize the writable paths before dropping privileges so Admin UI
# writes keep working. If an operator overrides the container user, do not try
# to chown or call setpriv from an unprivileged account.
if [ "$(id -u)" = "0" ]; then
    for path in /data /etc/nats; do
        if [ -e "$path" ]; then
            chown -R lancache:lancache "$path"
        fi
    done

    exec setpriv --reuid=lancache --regid=lancache --init-groups "$@"
fi

exec "$@"
