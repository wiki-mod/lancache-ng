#!/bin/sh
set -eu

# Bind mounts and shared volumes are often created as root-owned paths at
# container start, after image-time chown has run. Normalize the writable
# paths before dropping privileges so Admin UI writes keep working.
for path in /data /etc/nats; do
    if [ -e "$path" ]; then
        chown -R lancache:lancache "$path"
    fi
done

exec setpriv --reuid=lancache --regid=lancache --init-groups "$@"
