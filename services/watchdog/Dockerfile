# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# Runtime health-check and recovery service for lancache-ng containers.

FROM mirror.gcr.io/library/debian:13-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2

LABEL org.opencontainers.image.description="lancache-ng watchdog helper for runtime health checks and recovery hooks."

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq ca-certificates nano lsof ripgrep zstd \
    && rm -rf /var/lib/apt/lists/*
# nano/lsof/ripgrep: in-container troubleshooting tools -- see
# services/proxy/Dockerfile's identical comment for the full rationale.
# zstd (#1236): maybe_rotate_fluent_bit_selflog() compresses rotated
# fluent-bit self-log backups with it, matching the compression tool the
# syslog-ng service already uses for its own rotation loop (see
# deploy/*/docker-compose.yml). Installed at build time here rather than
# syslog-ng's runtime `apt-get install` pattern: that pattern exists there
# because syslog-ng's official image can't be given a custom Dockerfile,
# while this project owns this Dockerfile directly, so a guaranteed
# build-time install is simpler and doesn't depend on network egress at
# container start.
ENV EDITOR=nano
ENV VISUAL=$EDITOR
COPY watchdog.sh /watchdog.sh
COPY healthcheck.sh /healthcheck.sh
RUN chmod +x /watchdog.sh /healthcheck.sh
VOLUME ["/var/run/watchdog"]
ENTRYPOINT ["/watchdog.sh"]
