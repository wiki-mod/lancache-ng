#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Enforces the parts of docs/naming-conventions.md that are mechanically
# checkable: that the Docker socket proxy allowlist (scripts/untracked/docker-socket-proxy.sh),
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
# These are subset relations, not equalities -- watchdog/docker-socket-proxy
# deliberately have a container_name but must NOT appear in the allowlist (a
# service never needs Docker-API access to itself), so this script never
# asserts the reverse direction (every container_name in the allowlist).
# ui/netdata/syslog/syslog-ng USED to be in that same "container_name but not
# in the allowlist" set too, but issue #842/#849 added all four to the
# allowlist's safe_container_inspect/lancache_container acls (inspect-only,
# no restart grant) so watchdog's Rust rewrite can alert-only-monitor them --
# see scripts/untracked/docker-socket-proxy.sh's own comment on that addition. This
# comment is corrected here rather than left stale, per this project's own
# documentation-drift rule (AG-DOC-001).
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
cd "$repo_root"

COMPOSE_FILES=(deploy/prod/docker-compose.yml deploy/quickstart/docker-compose.yml)
SOCKET_PROXY_SCRIPT=scripts/untracked/docker-socket-proxy.sh
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
  # Here-string feeds grep, and grep's own (single-match-by-construction,
  # since there is only one such acl alternation group in the line) output
  # is captured into a variable before `head -n1` ever sees it -- neither
  # stage is a live pipe an early-exiting consumer could race (issue #1377).
  allowlist_group="$(grep -oE '\(lancache-[a-z0-9-]+(\|lancache-[a-z0-9-]+)*\)' <<<"$allowlist_line")"
  allowlist_names=$(head -n1 <<<"$allowlist_group" \
    | tr -d '()' \
    | tr '|' '\n' \
    | sort -u)
fi

if [ -z "$allowlist_names" ]; then
  fail "Could not parse any lancache-* container names out of $SOCKET_PROXY_SCRIPT's allowlist."
fi

name_in_allowlist() {
  local name="$1"
  # Here-string, not a live pipe into grep -q (issue #1377).
  grep -qxF "$name" <<<"$allowlist_names"
}

# --- Every allowlist name is a real container_name in every Compose file --
# Every container the socket proxy can act on by name must actually exist
# under that exact name in each deployment mode's Compose file -- an
# allowlist entry with no matching container_name would be a name only the
# security config knows about, not a real target.
#
# Issue #1415: deploy/quickstart/docker-compose.yml's container_name values
# now end in the literal, fixed text `${LANCACHE_CONTAINER_SUFFIX:-}` (never
# a different suffix expression, and never omitted -- see that file's own
# top-of-file comment) so CI can give concurrent runs distinct real
# container names while every real single-host install still gets the
# byte-identical bare name (LANCACHE_CONTAINER_SUFFIX unset). This is
# intentionally a fixed literal-text check, not a general "anything may
# follow the name" wildcard: a real drift (e.g. a typo'd or unrelated
# suffix expression) must still fail this check exactly like a missing
# container_name would. deploy/prod/docker-compose.yml carries no such
# mechanism and keeps the original exact-match requirement.
for compose_file in "${COMPOSE_FILES[@]}"; do
  case "$compose_file" in
    deploy/quickstart/docker-compose.yml)
      name_suffix='\$\{LANCACHE_CONTAINER_SUFFIX:-\}'
      ;;
    *)
      name_suffix=''
      ;;
  esac
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! grep -Eq "^[[:space:]]+container_name: ${name}${name_suffix}\$" "$compose_file"; then
      fail "$compose_file has no 'container_name: ${name}${name_suffix}', but $SOCKET_PROXY_SCRIPT's allowlist grants Docker API actions on it."
    fi
  done <<EOF_ALLOWLIST_PER_FILE
$allowlist_names
EOF_ALLOWLIST_PER_FILE
done <<EOF_ALLOWLIST
$allowlist_names
EOF_ALLOWLIST

# --- UI's Docker-API container-name literals are a subset of the allowlist -
# services/ui/src/docker_client.rs's container_name_for_service() is the
# Admin UI's own mirror of which container names it believes it may act on.
# Every name it can resolve to must actually be allowed by the proxy, or the
# UI would send a request the proxy silently denies (fails closed, but is
# still a drift bug worth catching before it ships).
#
# What: matches a match-arm base literal (`=> "lancache-x"`), not a whole
# `Ok("lancache-x")` return.
# Why: container_name_for_service was changed to append a runtime suffix
# (`Ok(format!("{base}{suffix}"))` once, outside the match), so no arm
# returns a bare `Ok(...)` anymore -- only the base-name literal itself.
# From: Issue #1592
docker_client_names=$(grep -oE '=> "lancache-[a-z0-9-]+"' "$DOCKER_CLIENT_RS" \
  | grep -oE 'lancache-[a-z0-9-]+' \
  | sort -u)

if [ -z "$docker_client_names" ]; then
  fail "Could not find any '=> \"lancache-*\"' base-name resolutions in $DOCKER_CLIENT_RS."
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
# URLs, and as input to docker_client::container_name_for_service, which
# accepts either the bare service name or the lancache-* container name), not
# a raw container_name. Checking them against the allowlist above would be
# wrong on purpose.
declare -A service_env_defaults=(
  [DNS_STANDARD_SERVICE]=dns-standard
  [DNS_SSL_SERVICE]=dns-ssl
  [PROXY_SERVICE]=proxy
  [NATS_SERVICE]=nats
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

# PROXY_SSL_SERVICE is deliberately not in the table above: its own default
# is not an independent string literal, it inherits proxy_service's already-
# validated value (`env_or("PROXY_SSL_SERVICE", proxy_service.clone())`), by
# design -- SSL mode reuses the same unified proxy service as standard mode.
# Assert that inheritance relationship stays literally in place instead of
# re-deriving "proxy" a second time, so a future edit that gives
# PROXY_SSL_SERVICE its own independent literal default doesn't silently
# stop tracking PROXY_SERVICE's value.
if ! grep -Fq 'env_or("PROXY_SSL_SERVICE", proxy_service.clone())' "$UI_CONFIG_RS"; then
  fail "$UI_CONFIG_RS must default \$PROXY_SSL_SERVICE from proxy_service.clone() (inheriting \$PROXY_SERVICE's own default), not an independent literal -- see services/ui/src/routes/domains.rs's restart_service(proxy_ssl_service) call."
fi

if [ "$failures" -gt 0 ]; then
  printf '::error::check-naming-consistency: %d naming-contract violation(s) found (see docs/naming-conventions.md).\n' "$failures" >&2
  exit 1
fi

printf 'check-naming-consistency: OK (allowlist, container_name, watchdog defaults, and UI service-name defaults all agree).\n'
