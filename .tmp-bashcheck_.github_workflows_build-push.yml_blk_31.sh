set -euo pipefail

# Services with an explicit healthcheck report a real "healthy"
# status; docker-socket-proxy has none, so it's only checked for
# "running" plus a restart-count ceiling (catches a crash loop
# without needing a healthcheck definition for every service).
services_with_healthcheck="proxy dns-standard dns-ssl watchdog nats ui netdata"
all_services="docker-socket-proxy $services_with_healthcheck"

deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
  all_ready=1
  for service in $services_with_healthcheck; do
    cid="$(docker compose ps -q "$service")"
    status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown")"
    if [[ "$status" != "healthy" ]]; then
      all_ready=0
    fi
  done
  if [[ "$all_ready" -eq 1 ]]; then
    break
  fi
  sleep 5
done

echo "::group::Final container status"
docker compose ps
echo "::endgroup::"

failed=0
for service in $all_services; do
  cid="$(docker compose ps -q "$service")"
  if [[ -z "$cid" ]]; then
    echo "::error::$service has no running container"
    failed=1
    continue
  fi

  restart_count="$(docker inspect --format '{{.RestartCount}}' "$cid")"
  container_status="$(docker inspect --format '{{.State.Status}}' "$cid")"

  if [[ "$container_status" != "running" ]]; then
    echo "::error::$service is not running (state: $container_status)"
    failed=1
  elif (( restart_count > 1 )); then
    echo "::error::$service has restarted $restart_count times (crash-loop suspected)"
    failed=1
  fi

  if [[ " $services_with_healthcheck " == *" $service "* ]]; then
    health="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown")"
    if [[ "$health" != "healthy" ]]; then
      echo "::error::$service did not become healthy (status: $health)"
      failed=1
    fi
  fi
done

if [[ "$failed" -eq 1 ]]; then
  echo "::group::Logs from all services (failure diagnostics)"
  docker compose logs --no-color
  echo "::endgroup::"
  exit 1
fi

echo "Full-setup stack is stable: all services running and healthy."

