FROM debian:13-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY watchdog.sh /watchdog.sh
RUN chmod +x /watchdog.sh
VOLUME ["/var/run/watchdog"]
ENTRYPOINT ["/watchdog.sh"]
