# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# Runtime health-check and recovery service for lancache-ng containers.

FROM mirror.gcr.io/library/debian:13-slim@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd

LABEL org.opencontainers.image.description="lancache-ng watchdog helper for runtime health checks and recovery hooks."

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY watchdog.sh /watchdog.sh
COPY healthcheck.sh /healthcheck.sh
RUN chmod +x /watchdog.sh /healthcheck.sh
VOLUME ["/var/run/watchdog"]
ENTRYPOINT ["/watchdog.sh"]
