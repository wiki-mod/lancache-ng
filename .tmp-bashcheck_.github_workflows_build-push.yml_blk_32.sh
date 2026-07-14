set -euo pipefail
echo "::group::Logs from all services"
docker compose logs --no-color || true
echo "::endgroup::"

