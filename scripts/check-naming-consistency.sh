#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Enforces the parts of docs/naming-conventions.md that are mechanically
# checkable: that the Docker socket proxy allowlist (scripts/docker-socket-proxy.sh),
# every Compose file's container_name values, the watchdog's CONTAINER_*
# defaults, the Admin UI's Docker-API container-name literals
# (services/ui/src/docker_client.rs), and the Admin UI's *_SERVICE Compose
# service-name defaults (services/ui/src/config.rs) never drift apart. This
# grew out of issue #454/#377: the socket proxy denies any Docker API call
# for a container name it doesn't recognize, so every layer that constructs
# such a call must agree on the same literal strings, and every layer that
# builds an internal HTTP URL must agree on the Compose *service* name
# instead (a different, non-interchangeable namespace -- see
# docs/naming-conventions.md's "Two separate name namespaces" section).
#
# These are subset relations, not equalities -- ui/watchdog/docker-socket-proxy/
# netdata/syslog/watchtower deliberately have a container_name but must NOT
# appear in the allowlist, so this script never asserts the reverse
# direction (every container_name in the allowlist).
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
cd "$repo_root"

COMPOSE_FILES=(deploy/dev/docker-compose.yml deploy/prod/docker-compose.yml deploy/quickstart/docker-compose.yml)
SOCKET_PROXY_SCRIPT=scripts/docker-socket-proxy.sh
DOCKER_CLIENT_RS=services/ui/src/docker_client.rs
WATCHDOG_SH=services/watchdog/watchdog.sh
UI_CONFIG_RS=services/ui/src/config.rs

failures=0

fail() {
  printf '::error::%s\n' "$1" >&2
  failures=$((failures + 1))
}

# --- Compose project name -------------------------------------------------
# dev/prod/quickstart are real, human-run deployment modes and must share
# one fixed Compose project name (see docs/naming-conventions.md's "Compose
# project name" section). deploy/full-setup (a CI-only harness) and
# deploy/secondary (generated per remote host, not part of this trust
# boundary) are documented exceptions and intentionally excluded here.
for compose_file in "${COMPOSE_FILES[@]}"; do
  if ! grep -Eq '^name: lancache-ng$' "$compose_file"; then
    fail "$compose_file must declare 'name: lancache-ng' (see docs/naming-conventions.md)."
  fi
done

# --- Canonical allowlist container-name set -------------------------------
# Extracted from the single acl lancache_container line in the real script.
allowlist_line=$(grep -F 'acl lancache_container' "$SOCKET_PROXY_SCRIPT" || true)
if [ -z "$allowlist_line" ]; then
  fail "$SOCKET_PROXY_SCRIPT is missing its 'acl lancache_container' allowlist line; cannot verify naming consistency."
  allowlist_names=""
else
  # The line looks like: ...containers/(lancache-a|lancache-b|...)(/|\$)
  allowlist_names=$(printf '%s\n' "$allowlist_line" \
    | grep -oE '\(lancache-[a-z0-9-]+(\|lancache-[a-z0-9-]+)*\)' \
    | head -n1 \
    | tr -d '()' \
    | tr '|' '\n' \
    | sort -u)
fi

if [ -z "$allowlist_names" ]; then
  fail "Could not parse any lancache-* container names out of $SOCKET_PROXY_SCRIPT's allowlist."
fi

name_in_allowlist() {
  local name="$1"
  printf '%s\n' "$allowlist_names" | grep -qxF "$name"
}

# --- Every allowlist name is a real container_name in every Compose file --
# Every container the socket proxy can act on by name must actually exist
# under that exact name in each deployment mode's Compose file -- an
# allowlist entry with no matching container_name would be a name only the
# security config knows about, not a real target.
while IFS= read -r name; do
  [ -n "$name" ] || continue
  for compose_file in "${COMPOSE_FILES[@]}"; do
    if ! grep -Eq "^[[:space:]]+container_name: ${name}\$" "$compose_file"; then
      fail "$compose_file has no 'container_name: $name', but $SOCKET_PROXY_SCRIPT's allowlist grants Docker API actions on it."
    fi
  done
done <<EOF_ALLOWLIST
$allowlist_names
EOF_ALLOWLIST

# --- UI's Docker-API container-name literals are a subset of the allowlist -
# services/ui/src/docker_client.rs's container_name_for_service() is the
# Admin UI's own mirror of which container names it believes it may act on.
# Every name it can resolve to must actually be allowed by the proxy, or the
# UI would send a request the proxy silently denies (fails closed, but is
# still a drift bug worth catching before it ships).
docker_client_names=$(grep -oE '=> Ok\("lancache-[a-z0-9-]+"\)' "$DOCKER_CLIENT_RS" \
  | grep -oE 'lancache-[a-z0-9-]+' \
  | sort -u)

if [ -z "$docker_client_names" ]; then
  fail "Could not find any 'Ok(\"lancache-*\")' resolutions in $DOCKER_CLIENT_RS."
fi

while IFS= read -r name; do
  [ -n "$name" ] || continue
  if ! name_in_allowlist "$name"; then
    fail "$DOCKER_CLIENT_RS resolves '$name', which is not in $SOCKET_PROXY_SCRIPT's allowlist."
  fi
done <<EOF_DOCKER_CLIENT
$docker_client_names
EOF_DOCKER_CLIENT

# --- Watchdog's CONTAINER_* defaults are a subset of the allowlist --------
watchdog_names=$(grep -oE '\$\{CONTAINER_[A-Z_]+:-lancache-[a-z0-9-]+\}' "$WATCHDOG_SH" \
  | grep -oE 'lancache-[a-z0-9-]+' \
  | sort -u)

if [ -z "$watchdog_names" ]; then
  fail "Could not find any CONTAINER_*:-lancache-* defaults in $WATCHDOG_SH."
fi

while IFS= read -r name; do
  [ -n "$name" ] || continue
  if ! name_in_allowlist "$name"; then
    fail "$WATCHDOG_SH defaults to container name '$name', which is not in $SOCKET_PROXY_SCRIPT's allowlist."
  fi
done <<EOF_WATCHDOG
$watchdog_names
EOF_WATCHDOG

# --- UI's *_SERVICE defaults match a real Compose *service* name ----------
# This is the other namespace (see docs/naming-conventions.md): these
# defaults must equal a Compose *service* key (used for Docker DNS / HTTP
# URLs), not a container_name. Checking them against the allowlist above
# would be wrong on purpose.
declare -A service_env_defaults=(
  [DNS_STANDARD_SERVICE]=dns-standard
  [DNS_SSL_SERVICE]=dns-ssl
  [PROXY_SERVICE]=proxy
)

for var in "${!service_env_defaults[@]}"; do
  expected="${service_env_defaults[$var]}"
  actual=$(grep -oE "env_str\(\"${var}\", \"[a-z0-9-]+\"\)|env_or\(\"${var}\", \"[a-z0-9-]+\"" "$UI_CONFIG_RS" \
    | grep -oE '"[a-z0-9-]+"' | tail -n1 | tr -d '"')
  if [ -z "$actual" ]; then
    fail "$UI_CONFIG_RS has no discoverable default for \$${var}; expected it to default to Compose service '$expected'."
    continue
  fi
  if [ "$actual" != "$expected" ]; then
    fail "$UI_CONFIG_RS defaults \$${var} to '$actual', but the Compose service is named '$expected'."
  fi
  for compose_file in "${COMPOSE_FILES[@]}"; do
    if ! grep -Eq "^  ${expected}:\$" "$compose_file"; then
      fail "$compose_file has no '$expected:' service, but $UI_CONFIG_RS's \$${var} default assumes it exists."
    fi
  done
done

if [ "$failures" -gt 0 ]; then
  printf '::error::check-naming-consistency: %d naming-contract violation(s) found (see docs/naming-conventions.md).\n' "$failures" >&2
  exit 1
fi

printf 'check-naming-consistency: OK (allowlist, container_name, watchdog defaults, and UI service-name defaults all agree).\n'
