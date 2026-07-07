# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# Full-setup validation image: provides deterministic, offline-capable
# validation harness for testing the complete stack composition workflow.
# Used only for validation, not production deployment.

FROM busybox:stable-musl@sha256:3c6ae8008e2c2eedd141725c30b20d9c36b026eb796688f88205845ef17aa213

LABEL org.opencontainers.image.source="https://github.com/wiki-mod/lancache-ng" \
      org.opencontainers.image.description="Full-setup validation harness for lancache-ng" \
      org.opencontainers.image.vendor="lancache-ng"

# Copy compose validation file and supporting configuration
COPY docker-compose.yml /compositions/full-setup/docker-compose.yml

# Provide a basic validation entrypoint that outputs stack configuration
ENTRYPOINT ["cat"]
CMD ["/compositions/full-setup/docker-compose.yml"]
