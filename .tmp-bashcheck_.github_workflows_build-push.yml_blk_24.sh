set -euo pipefail

docker run --rm -i \
  --user "$(id -u):$(id -g)" \
  -v "$PWD:/work:ro" \
  -w /work \
  --env HOME=/tmp \
  --env DOCKER_CONFIG=/tmp/.docker \
  --env CACHE_INACTIVE \
  --env CACHE_MAX_SIZE \
  --env CACHE_MEM_MB \
  --env CACHE_SLICE_SIZE \
  --env CACHE_VALID_ANY \
  --env CACHE_VALID_HIT \
  --env DDNS_TSIG_KEY \
  --env IP_SSL \
  --env IP_STANDARD \
  --env LISTEN_IP \
  --env ALLOW_INSECURE_UI \
  --env KEA_CTRL_TOKEN \
  --env NATS_CONSUMER \
  --env NATS_DNS_REPLICA_PASSWORD \
  --env NATS_DNS_REPLICA_USER \
  --env NATS_DNS_WRITER_PASSWORD \
  --env NATS_DNS_WRITER_USER \
  --env NATS_CALLOUT_PASSWORD \
  --env NATS_CALLOUT_USER \
  --env NATS_PASSWORD \
  --env NATS_UI_PASSWORD \
  --env NATS_UI_USER \
  --env NATS_USER \
  --env NATS_TOKEN \
  --env NATS_URL \
  --env NGINX_UPSTREAM_RESOLVER \
  --env PDNS_API_KEY \
  --env PROXY_IP \
  --env SECONDARY_REGISTRATION_TOKEN \
  --env SSL_CACHE_MAX_GB \
  --env STANDARD_CACHE_MAX_GB \
  "${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}" \
  bash scripts/check-logging-matrix.sh

