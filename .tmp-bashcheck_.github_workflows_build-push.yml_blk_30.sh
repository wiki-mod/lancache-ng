set -euo pipefail

: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}"

if ! command -v flock >/dev/null 2>&1; then
  echo "::error::flock is required for safe validation-subnet locking."
  exit 1
fi

# shellcheck source=scripts/lib/reserve-validation-subnet.sh
source "$GITHUB_WORKSPACE/scripts/lib/reserve-validation-subnet.sh"
# shellcheck source=scripts/lib/ghcr-retry.sh
source "$GITHUB_WORKSPACE/scripts/lib/ghcr-retry.sh"

lock_root="/tmp/lancache-validation-locks"
max_attempts=10

# Defense-in-depth check carried over from the pre-#703 "Check for
# a validation subnet collision" step: Docker-managed networks only
# cover Docker's own view. A route or interface address already on
# the host (another NIC, a VPN, a leftover bridge from something
# outside Docker entirely) doesn't show up in `docker network ls`
# at all, but the kernel still refuses to create an overlapping
# bridge for it -- confirmed for real in #703's linked run: this
# exact check found zero Docker-network conflicts while
# `docker compose up` still failed with "Address already in use".
subnet_conflicts() {
  local target_subnet="$1"
  python3 - "$target_subnet" <<'PYEOF'
import ipaddress, os, subprocess, sys
target = ipaddress.ip_network(sys.argv[1])
# A leftover network from our own project (e.g. an aborted prior run
# that never reached the teardown step) is not a real collision --
# docker compose reuses/recreates it by name. Only flag networks
# that aren't ours.
own_prefix = os.environ.get("COMPOSE_PROJECT_NAME", "lancache-ng-validation")

ids = subprocess.run(["docker", "network", "ls", "-q"], capture_output=True, text=True, check=True).stdout.split()
for network_id in ids:
    fmt = "{{.Name}}|{{range .IPAM.Config}}{{.Subnet}} {{end}}"
    line = subprocess.run(["docker", "network", "inspect", network_id, "--format", fmt], capture_output=True, text=True, check=True).stdout.strip()
    name, _, subnets_str = line.partition("|")
    if name.startswith(own_prefix):
        continue
    for subnet_str in subnets_str.split():
        try:
            existing = ipaddress.ip_network(subnet_str)
        except ValueError:
            continue
        if target.overlaps(existing):
            print(f"docker network {name} ({subnet_str})")

route_output = subprocess.run(["ip", "-4", "-o", "addr", "show"], capture_output=True, text=True, check=True).stdout
for line in route_output.splitlines():
    parts = line.split()
    try:
        inet_index = parts.index("inet")
        iface = parts[1]
        cidr = parts[inet_index + 1]
    except (ValueError, IndexError):
        continue
    try:
        existing = ipaddress.ip_interface(cidr).network
    except ValueError:
        continue
    if target.overlaps(existing):
        print(f"host interface {iface} ({cidr})")
PYEOF
}

ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- docker compose pull --quiet

reserved_octet=""
holder_pid=""
next_attempt=1

while [[ -z "$reserved_octet" && "$next_attempt" -le "$max_attempts" ]]; do
  reservation="$(validation_subnet_reserve "$lock_root" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "$next_attempt" "$max_attempts")" || {
    echo "::error::Could not lock a free validation subnet octet after $max_attempts attempts."
    exit 1
  }
  attempt="$(printf '%s\n' "$reservation" | sed -n 's/^attempt=//p')"
  octet="$(printf '%s\n' "$reservation" | sed -n 's/^octet=//p')"
  candidate_pid="$(printf '%s\n' "$reservation" | sed -n 's/^holder_pid=//p')"

  # Rederive COMPOSE_PROJECT_NAME/VALIDATION_UI_PORT from THIS
  # attempt's own candidate octet -- see full-setup-validate.yml's
  # own "Reserve a validation subnet and start the stack" step for
  # why this matters both for subnet_conflicts()'s own_prefix check
  # right below and for avoiding a compose-project/UI-port
  # collision between two concurrent runs that started from the
  # same initial octet but diverged on a retry.
  export COMPOSE_PROJECT_NAME="lancache-ng-validation-${octet}"
  export VALIDATION_UI_PORT=$((9000 + octet))

  target_subnet="172.30.${octet}.0/24"
  conflict="$(subnet_conflicts "$target_subnet")"
  if [[ -n "$conflict" ]]; then
    echo "Octet $octet's subnet $target_subnet overlaps existing host/Docker state ($conflict); releasing and trying the next candidate."
    validation_subnet_release "$candidate_pid"
    next_attempt=$((attempt + 1))
    continue
  fi

  export VALIDATION_SUBNET="$target_subnet"
  export VALIDATION_GATEWAY="172.30.${octet}.1"
  export VALIDATION_PROXY_IP="172.30.${octet}.2"
  export VALIDATION_DNS_STANDARD_IP="172.30.${octet}.3"
  export VALIDATION_PROXY_SSL_IP="172.30.${octet}.4"
  export VALIDATION_DNS_SSL_IP="172.30.${octet}.5"
  export VALIDATION_WATCHDOG_IP="172.30.${octet}.6"
  export VALIDATION_NETDATA_IP="172.30.${octet}.7"
  export VALIDATION_NATS_IP="172.30.${octet}.8"
  export VALIDATION_UI_IP="172.30.${octet}.9"

  echo "Attempting to start the validation stack on locked, pre-checked subnet $target_subnet (attempt $attempt)."
  if up_output="$(docker compose up -d 2>&1)"; then
    echo "$up_output"
    reserved_octet="$octet"
    holder_pid="$candidate_pid"
    break
  fi

  echo "$up_output"
  validation_subnet_release "$candidate_pid"

  if [[ "$up_output" != *"Pool overlaps"* && "$up_output" != *"already in use"* && "$up_output" != *"Address already in use"* ]]; then
    echo "::error::docker compose up failed for a reason unrelated to a subnet collision; not retrying."
    exit 1
  fi

  echo "docker compose up failed with a network-overlap error on attempt $attempt, retrying with a different subnet."
  next_attempt=$((attempt + 1))
done

if [[ -z "$reserved_octet" ]]; then
  echo "::error::Could not reserve a free validation subnet and start the stack after $max_attempts attempts."
  exit 1
fi

echo "Validation stack is up on subnet 172.30.${reserved_octet}.0/24 (lock held by PID $holder_pid)."

# Persist the SAME rederived project name/UI port the winning
# attempt above already exported for its own `docker compose up`,
# so every later step in this job (the health-check step, the
# client-simulation step, and the teardown step's own
# `docker compose down`) keeps targeting the actually-running stack
# instead of falling back to whatever a stale job-level env would
# have held on a retry.
reserved_project_name="lancache-ng-validation-${reserved_octet}"
reserved_ui_port=$((9000 + reserved_octet))

{
  echo "COMPOSE_PROJECT_NAME=$reserved_project_name"
  echo "VALIDATION_UI_PORT=$reserved_ui_port"
  echo "VALIDATION_LOCK_HOLDER_PID=$holder_pid"
  echo "VALIDATION_SUBNET=172.30.${reserved_octet}.0/24"
  echo "VALIDATION_GATEWAY=172.30.${reserved_octet}.1"
  echo "VALIDATION_PROXY_IP=172.30.${reserved_octet}.2"
  echo "VALIDATION_DNS_STANDARD_IP=172.30.${reserved_octet}.3"
  echo "VALIDATION_PROXY_SSL_IP=172.30.${reserved_octet}.4"
  echo "VALIDATION_DNS_SSL_IP=172.30.${reserved_octet}.5"
  echo "VALIDATION_WATCHDOG_IP=172.30.${reserved_octet}.6"
  echo "VALIDATION_NETDATA_IP=172.30.${reserved_octet}.7"
  echo "VALIDATION_NATS_IP=172.30.${reserved_octet}.8"
  echo "VALIDATION_UI_IP=172.30.${reserved_octet}.9"
} >> "$GITHUB_ENV"

