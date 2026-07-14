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
  bash -s <<'VALIDATE_COMPOSE'
set -euo pipefail

validate_compose() {
  local output

  if ! output="$(docker compose "$@" config --quiet 2>&1)"; then
    printf '%s\n' "$output"
    return 1
  fi

  if printf '%s\n' "$output" | grep -Eqi '(^|[[:space:]])(warn|warning|level=warning)'; then
    printf 'docker compose emitted warnings; treating warnings as errors:\n%s\n' "$output"
    return 1
  fi

  if [ -n "$output" ]; then
    printf '%s\n' "$output"
  fi
}

validate_compose -f deploy/quickstart/docker-compose.yml --profile ssl
validate_compose -f deploy/dev/docker-compose.yml
validate_compose -f deploy/prod/docker-compose.yml
validate_compose -f deploy/secondary/docker-compose.yml
validate_compose --env-file deploy/quickstart/.env -f deploy/quickstart/docker-compose.yml --profile ssl

# The default (profile-less) renders above skip the dhcp/dhcp-proxy
# service blocks entirely, because Compose omits services behind an
# inactive profile. Both DHCP modes (issue #343) therefore need
# explicit profile activation so their service definitions are
# actually parsed and validated, not silently excluded.
for compose_file in \
  deploy/dev/docker-compose.yml \
  deploy/prod/docker-compose.yml \
  deploy/quickstart/docker-compose.yml; do
  validate_compose -f "$compose_file" --profile dhcp-kea
  validate_compose -f "$compose_file" --profile dhcp-proxy
  # Same reasoning as above, for the syslog-ng/fluent-bit logging
  # profile (#453): it must be activated explicitly or its service
  # blocks are silently skipped by this validation.
  validate_compose -f "$compose_file" --profile logging
done

validate_nats_config_ownership() {
  local path

  for path in \
    deploy/dev/docker-compose.yml \
    deploy/prod/docker-compose.yml \
    deploy/quickstart/docker-compose.yml
  do
    grep -Fq 'tmp_nats_conf="$(mktemp /etc/nats/.nats.conf.XXXXXX)"' "$path" \
      || {
        printf '::error file=%s::NATS must stage the shared config in a temp file inside /etc/nats.\n' "$path"
        return 1
      }
    grep -Fq 'chown 10001:10001 "$$tmp_nats_conf"' "$path" \
      || {
        printf '::error file=%s::NATS must restore shared config ownership to UID/GID 10001 after writing.\n' "$path"
        return 1
      }
    grep -Fq 'mv "$$tmp_nats_conf" /etc/nats/nats.conf' "$path" \
      || {
        printf '::error file=%s::NATS must atomically replace the shared nats.conf after fixing ownership.\n' "$path"
        return 1
      }
  done
}

validate_nats_config_ownership
grep -Fq 'fn write_nats_conf_atomically(' services/ui/src/routes/secondaries.rs \
  || { echo "::error::Admin UI must keep an atomic nats.conf write helper for the v0.1.0 shared-token path."; exit 1; }
grep -Fq 'fs::rename(&tmp_path, target)' services/ui/src/routes/secondaries.rs \
  || { echo "::error::Admin UI nats.conf writes must use temp-file plus rename, not direct overwrite."; exit 1; }

grep -Fq 'render_template_atomic' services/dns/entrypoint.sh \
  || { echo "::error::DNS entrypoint must render generated configs through the atomic helper."; exit 1; }
grep -Fq 'mktemp "${target_dir}/.${target_name}.tmp.XXXXXX"' services/dns/entrypoint.sh \
  || { echo "::error::DNS entrypoint generated configs must stage temp files in the target directory."; exit 1; }
if grep -Fq '> /tmp/recursor.conf' services/dns/entrypoint.sh \
  || grep -Fq '> /tmp/pdns.conf' services/dns/entrypoint.sh; then
  echo "::error::DNS entrypoint must not render PDNS configs through /tmp before replacing target configs."
  exit 1
fi
if grep -Fq "sed -i 's/^  loglevel: 3$/  loglevel: 6/' /etc/pdns/recursor.conf" services/dns/entrypoint.sh; then
  echo "::error::DNS query logging must be applied to the staged recursor.conf before replacement."
  exit 1
fi
grep -Fq 'write_generated_runtime_file "${secondary_dir}/docker-compose.yml"' setup.sh \
  || { echo "::error::Secondary setup must atomically write generated docker-compose.yml."; exit 1; }
grep -Fq 'write_env_file "${secondary_dir}/.env"' setup.sh \
  || { echo "::error::Secondary setup must use the safe env writer for generated .env files."; exit 1; }

if grep -F 'EXEC: "1"' deploy/dev/docker-compose.yml deploy/prod/docker-compose.yml deploy/quickstart/docker-compose.yml >/dev/null; then
  echo "::error::Docker exec is banned from the Admin UI/watchdog proxy for security reasons; use predeclared container actions instead."
  exit 1
fi
if grep -E '^[[:space:]]*(CONTAINERS|POST): "1"' deploy/dev/docker-compose.yml deploy/prod/docker-compose.yml deploy/quickstart/docker-compose.yml >/dev/null; then
  echo "::error::Broad CONTAINERS=1/POST=1 exposes generic Docker container APIs; use the explicit HAProxy allowlist instead."
  exit 1
fi
# The HAProxy allowlist itself lives in exactly one place,
# scripts/docker-socket-proxy.sh (see docs/naming-conventions.md's
# "Docker socket proxy allowlist" section) -- it used to also be
# duplicated into an unreferenced x-docker-socket-proxy-command
# anchor in each of the three Compose files, which this check used
# to validate instead of the real script. Those anchors were dead
# (never aliased) and have been removed; validate the one real
# copy directly instead of three unreachable shadow copies.
socket_proxy_script="scripts/docker-socket-proxy.sh"
grep -Fq 'acl safe_service_restart' "$socket_proxy_script" \
  && grep -Fq 'acl safe_dhcp_action' "$socket_proxy_script" \
  && grep -Fq 'acl safe_probe_action' "$socket_proxy_script" \
  && grep -Fq 'acl lancache_container' "$socket_proxy_script" \
  && grep -Fq 'lancache-dns-standard|lancache-dns-ssl' "$socket_proxy_script" \
  && grep -Fq 'lancache-proxy|lancache-dns-standard|lancache-dns-ssl|lancache-nats)/restart' "$socket_proxy_script" \
  && grep -Fq 'lancache-dhcp|lancache-dhcp-proxy)/(start|stop)' "$socket_proxy_script" \
  && grep -Fq 'lancache-dhcp-probe/(start|stop|wait)' "$socket_proxy_script" \
  && ! grep -Fq 'lancache-proxy|lancache-dns-standard|lancache-dns-ssl|lancache-dhcp|lancache-dhcp-proxy|lancache-dhcp-probe|lancache-nats)/(start|stop|restart|wait)' "$socket_proxy_script" \
  && grep -Fq 'http-request deny if docker_container_path !lancache_container' "$socket_proxy_script" \
  && grep -Fq 'http-request deny' "$socket_proxy_script" \
  && ! grep -Fq '/containers/create' "$socket_proxy_script" \
  && ! grep -Fq '/containers/json' "$socket_proxy_script" \
  && ! grep -Fq '[A-Za-z0-9_.-]+/(start|stop|restart|attach)' "$socket_proxy_script" \
  || {
    echo "::error file=${socket_proxy_script}::Docker socket proxy must deny generic container listing/creation and only allow explicit project container actions; stop/start/wait are restricted to the DHCP probe."
    exit 1
  }

for compose_file in deploy/dev/docker-compose.yml deploy/prod/docker-compose.yml deploy/quickstart/docker-compose.yml; do
  grep -Fq 'docker-socket-proxy.sh:/usr/local/bin/lancache-docker-socket-proxy.sh:ro' "$compose_file" \
    || {
      echo "::error file=${compose_file}::docker-socket-proxy service must mount the one real scripts/docker-socket-proxy.sh, not an inline or divergent copy."
      exit 1
    }
  # Match only the real top-level YAML key/anchor syntax here, not
  # any occurrence of the string -- the explanatory comment above
  # (and in docs/naming-conventions.md) legitimately mentions
  # "x-docker-socket-proxy-command" as prose describing what was
  # removed, and a substring match would flag that prose as a
  # reintroduction on every run.
  grep -Eq '^x-docker-socket-proxy-command:' "$compose_file" \
    && {
      echo "::error file=${compose_file}::The dead x-docker-socket-proxy-command anchor must not be reintroduced; it duplicated scripts/docker-socket-proxy.sh without ever being referenced."
      exit 1
    }
  true
done

missing_required=0
while IFS= read -r key; do
  if ! grep -Eq "^${key}=[^[:space:]]+" deploy/quickstart/.env; then
    echo "::error::deploy/quickstart/.env must define non-empty ${key} because quickstart compose marks it required."
    missing_required=1
  fi
done < <(
  grep -oE '\$\{[A-Za-z0-9_]+:\?[^}]+\}' deploy/quickstart/docker-compose.yml \
    | sed -E 's/^\$\{([^:]+):.*/\1/' \
    | sort -u
)
if [[ "$missing_required" = "1" ]]; then
  exit 1
fi

validate_dhcp_proxy_env_file_contract() {
  local compose_file="$1"
  local expected_env_file="$2"

  awk -v compose_file="$compose_file" -v expected_env_file="$expected_env_file" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function content_indent(value, prefix) {
      match(value, /^[[:space:]]*/)
      prefix = substr(value, 1, RLENGTH)
      return length(prefix)
    }
    function strip_inline_comment(value) {
      sub(/[[:space:]]+#.*/, "", value)
      return value
    }
    /^  dhcp-proxy:/ {
      in_service=1
      saw_service=1
      in_env_file_block=0
      next
    }
    in_service && /^  [[:alnum:]_-]+:/ {
      in_service=0
      in_env_file_block=0
    }
    in_service {
      line=strip_inline_comment($0)
      stripped=trim(line)

      if (in_env_file_block && stripped != "" && content_indent(line) <= env_file_indent) {
        in_env_file_block=0
      }
      if (in_env_file_block && stripped ~ /^-/ && index(stripped, expected_env_file) > 0) {
        saw_env_file=1
      }

      if (line ~ /^[[:space:]]*env_file:[[:space:]]*$/) {
        in_env_file_block=1
        env_file_indent=content_indent(line)
      } else if (line ~ /^[[:space:]]*env_file:[[:space:]]*/ && index(line, expected_env_file) > 0) {
        saw_env_file=1
      }

      if (line ~ /^[[:space:]]*environment:[[:space:]]*/) {
        saw_environment=1
      }
      if (stripped ~ /^-[[:space:]]*(DHCP_SUBNET_START|DHCP_DNS_PRIMARY|DHCP_DNS_SECONDARY|UPSTREAM_DHCP_IP)=\$\{/ || stripped ~ /[{,][[:space:]]*(DHCP_SUBNET_START|DHCP_DNS_PRIMARY|DHCP_DNS_SECONDARY|UPSTREAM_DHCP_IP):[[:space:]]*"\$\{/) {
        saw_interpolated_dhcp_key=1
      }
    }
    END {
      if (!saw_service) {
        printf "::error file=%s::dhcp-proxy service is missing.\n", compose_file
        exit 1
      }
      if (!saw_env_file) {
        printf "::error file=%s::dhcp-proxy must keep using env_file %s so setup-managed dnsmasq-proxy values are not lost.\n", compose_file, expected_env_file
        exit 1
      }
      if (saw_environment || saw_interpolated_dhcp_key) {
        printf "::error file=%s::dhcp-proxy must not reintroduce Compose environment interpolation for dnsmasq-proxy values; env_file is the contract for dev/prod.\n", compose_file
        exit 1
      }
    }
  ' "$compose_file"
}

# Dev/prod dhcp-proxy values are written by setup into env files.
# Compose interpolation does not read env_file values, so explicit
# environment entries here would silently erase the configured proxy
# DHCP settings. Quickstart is intentionally separate because setup
# writes its single .env file directly.
validate_dhcp_proxy_env_file_contract deploy/dev/docker-compose.yml ../../config/dev/dhcp-proxy.env
validate_dhcp_proxy_env_file_contract deploy/prod/docker-compose.yml ../../config/prod/dhcp-proxy.env

# Issue #450: dnsmasq relay/proxy optional-option surface. Guards
# against silently dropping the new keys from any layer of the
# env-file -> entrypoint -> template pipeline.
dhcp_proxy_optional_keys=(
  DHCP_PROXY_INTERFACE
  DHCP_PROXY_ROUTER
  DHCP_NTP_SERVERS
  DHCP_PROXY_DOMAIN
  DHCP_PROXY_BOOT_FILENAME
  DHCP_PROXY_BOOT_SERVER
  DHCP_PROXY_CUSTOM_OPTIONS
)
for env_file in config/dev/dhcp-proxy.env config/prod/dhcp-proxy.env deploy/quickstart/.env; do
  for key in "${dhcp_proxy_optional_keys[@]}"; do
    grep -Eq "^${key}=" "$env_file" \
      || { echo "::error file=${env_file}::${env_file} must define ${key} (empty by default) for the dnsmasq relay/proxy optional-option surface added by issue #450."; exit 1; }
  done
done
grep -F 'DHCP_PROXY_INTERFACE=${DHCP_PROXY_INTERFACE:-}' deploy/quickstart/docker-compose.yml >/dev/null \
  || { echo "::error::deploy/quickstart/docker-compose.yml's dhcp-proxy service must pass through DHCP_PROXY_INTERFACE like the other optional dnsmasq relay/proxy keys."; exit 1; }
grep -F 'DHCP_PROXY_CUSTOM_OPTIONS=${DHCP_PROXY_CUSTOM_OPTIONS:-}' deploy/quickstart/docker-compose.yml >/dev/null \
  || { echo "::error::deploy/quickstart/docker-compose.yml's dhcp-proxy service must pass through DHCP_PROXY_CUSTOM_OPTIONS like the other optional dnsmasq relay/proxy keys."; exit 1; }

# Issue #705: PXE boot-pointer opt-in surface. Same guard shape as
# #450 above -- a PR review (#765) found the quickstart Compose
# environment allowlist silently stopped before these three keys,
# leaving the opt-in feature unreachable there even when set in
# .env; this also checks explicit compose passthrough (not just
# env-file presence) so that specific class of regression is
# caught here instead of only by manual review next time.
dhcp_proxy_pxe_keys=(
  DHCP_PROXY_PXE_BOOT_SERVER
  DHCP_PROXY_PXE_BOOT_FILENAME_BIOS
  DHCP_PROXY_PXE_BOOT_FILENAME_UEFI
)
for env_file in config/dev/dhcp-proxy.env config/prod/dhcp-proxy.env deploy/quickstart/.env; do
  for key in "${dhcp_proxy_pxe_keys[@]}"; do
    grep -Eq "^${key}=" "$env_file" \
      || { echo "::error file=${env_file}::${env_file} must define ${key} (empty by default) for the PXE boot-pointer opt-in surface added by issue #705."; exit 1; }
  done
done
for key in "${dhcp_proxy_pxe_keys[@]}"; do
  grep -F "${key}=\${${key}:-}" deploy/quickstart/docker-compose.yml >/dev/null \
    || { echo "::error::deploy/quickstart/docker-compose.yml's dhcp-proxy service must pass through ${key} like the other optional dnsmasq relay/proxy keys."; exit 1; }
done

grep -F '_dhcp_proxy_render_optional_directives()' services/dhcp-proxy/entrypoint.sh >/dev/null \
  || { echo "::error::services/dhcp-proxy/entrypoint.sh must render the issue #450 optional dnsmasq relay/proxy directives."; exit 1; }
grep -F '_dhcp_proxy_render_optional_directives /etc/dnsmasq.conf' services/dhcp-proxy/entrypoint.sh >/dev/null \
  || { echo "::error::services/dhcp-proxy/entrypoint.sh must call _dhcp_proxy_render_optional_directives before validating dnsmasq.conf."; exit 1; }
if grep -F 'dhcp-proxy=${UPSTREAM_DHCP_IP}' services/dhcp-proxy/dnsmasq.conf.template >/dev/null; then
  echo "::error::services/dhcp-proxy/dnsmasq.conf.template must not reintroduce 'dhcp-proxy=\${UPSTREAM_DHCP_IP}': that flag means \"treat these DHCP-relay agents as full proxies\" (RFC 5107), it does nothing without --dhcp-relay=, and this service never configures one. Confirmed against a live dnsmasq --help/--test; see docs/dhcp-modes.md."
  exit 1
fi

if grep -RInE '^(NATS_LOCAL_TOKEN|NATS_TOKEN)=' deploy/quickstart/.env deploy/prod/.env 2>/dev/null; then
  echo "::error::Quickstart/prod env templates must not use deprecated NATS token keys; use role credentials instead."
  exit 1
fi

setup_required_keys=(
  DDNS_TSIG_KEY
  KEA_CTRL_TOKEN
  LANCACHE_IMAGE_TAG
  NATS_DNS_REPLICA_PASSWORD
  NATS_DNS_REPLICA_USER
  NATS_DNS_WRITER_PASSWORD
  NATS_DNS_WRITER_USER
  NATS_CALLOUT_PASSWORD
  NATS_CALLOUT_USER
  NATS_UI_PASSWORD
  NATS_UI_USER
  PDNS_API_KEY
  SECONDARY_REGISTRATION_TOKEN
)
for key in "${setup_required_keys[@]}"; do
  grep -F "$key" setup.sh >/dev/null \
    || { echo "::error::setup.sh must generate or migrate required runtime key ${key}."; exit 1; }
done

grep -F 'run_kea_dhcp_activation_preflight()' setup.sh >/dev/null \
  || { echo "::error::setup.sh must define a DHCP discovery preflight before Kea activation."; exit 1; }
grep -F 'run_kea_dhcp_activation_preflight "$INSTALL_DIR/.env"' setup.sh >/dev/null \
  || { echo "::error::setup.sh must call the Kea discovery preflight before starting the stack."; exit 1; }
grep -F 'nmap --script broadcast-dhcp-discover --script-args broadcast-dhcp-discover.timeout=5' setup.sh >/dev/null \
  || { echo "::error::setup.sh must probe DHCP discovery with the Kea image before activation."; exit 1; }
if grep -F 'nmap --script broadcast-dhcp-discover -e any' setup.sh >/dev/null; then
  echo "::error::setup.sh must not pass -e any to nmap; that is not a valid nmap interface and makes the preflight fail its own execution on every run."
  exit 1
fi
grep -F 'nmap' services/dhcp/Dockerfile >/dev/null \
  || { echo "::error::services/dhcp/Dockerfile must install nmap for the Kea discovery preflight."; exit 1; }
grep -F 'nmap|/usr/bin/nmap|/bin/nmap)' services/dhcp/entrypoint.sh >/dev/null \
  || { echo "::error::services/dhcp/entrypoint.sh must pass through the nmap preflight command without starting Kea."; exit 1; }

setup_update_required_repairs=(
  CACHE_INACTIVE
  CACHE_MAX_GB
  CACHE_MAX_SIZE
  CACHE_MEM_MB
  CACHE_SLICE_SIZE
  CACHE_VALID_ANY
  CACHE_VALID_HIT
  DDNS_TSIG_KEY
  KEA_CTRL_TOKEN
  LANCACHE_IMAGE_CHANNEL
  LANCACHE_IMAGE_PREFIX
  LANCACHE_IMAGE_REGISTRY
  LANCACHE_IMAGE_TAG
  NATS_DNS_REPLICA_PASSWORD
  NATS_DNS_REPLICA_USER
  NATS_DNS_WRITER_PASSWORD
  NATS_DNS_WRITER_USER
  NATS_CALLOUT_PASSWORD
  NATS_CALLOUT_USER
  NATS_UI_PASSWORD
  NATS_UI_USER
  NGINX_UPSTREAM_RESOLVER
  PDNS_API_KEY
  PROXY_SECURITY_MODE
  SSL_ENABLED
  SECONDARY_REGISTRATION_TOKEN
)
for key in "${setup_update_required_repairs[@]}"; do
  if awk -v key="$key" '
    /^migrate_env_for_update\(\)/ { in_func=1; next }
    in_func && /^}/ { in_func=0 }
    in_func && $0 ~ "append_env_key_if_missing[[:space:]]+" key "([[:space:]]|$)" { found=1 }
    END { exit found ? 0 : 1 }
  ' setup.sh; then
    echo "::error::setup.sh update must not preserve empty required ${key} values with append_env_key_if_missing."
    exit 1
  fi
  awk -v key="$key" '
    /^migrate_env_for_update\(\)/ { in_func=1; next }
    in_func && /^}/ { in_func=0 }
    in_func && $0 ~ "(set_env_key_if_empty_or_missing|set_env_key|ensure_secret_env_key|append_required_env_migrated_assignment_if_empty_or_missing)[[:space:]]+" key "([[:space:]]|$)" { found=1 }
    END { exit found ? 0 : 1 }
  ' setup.sh \
    || { echo "::error::setup.sh update must repair empty or missing required ${key} values."; exit 1; }
done
grep -F 'get_env_var_nonempty()' setup.sh >/dev/null \
  || { echo "::error::setup.sh must provide a helper that finds non-empty duplicate env values before repairing required keys."; exit 1; }
grep -F 'get_env_assignment_value_raw_nonempty()' setup.sh >/dev/null \
  || { echo "::error::setup.sh must provide a helper that preserves the raw assignment for a non-empty duplicate env value."; exit 1; }
grep -F 'existing_assignment=$(get_env_assignment_value_raw_nonempty "$key" "$env_file")' setup.sh >/dev/null \
  || { echo "::error::Required-key repair must preserve the raw non-empty assignment before writing a fallback."; exit 1; }
grep -F 'source_assignment=$(get_env_assignment_value_raw_nonempty "$source_key" "$env_file")' setup.sh >/dev/null \
  || { echo "::error::Migrated assignments must preserve raw non-empty source values before writing a fallback."; exit 1; }
grep -F 'cache_max_gb=$(get_env_var_nonempty CACHE_MAX_GB "$env_file")' setup.sh >/dev/null \
  || { echo "::error::CACHE_MAX_SIZE repair must derive from existing CACHE_MAX_GB before falling back to the default."; exit 1; }
if ! awk '
  /^set_env_key\(\) \{/ { in_func=1; seen_next=0; next }
  in_func && /^}/ { exit seen_next ? 0 : 1 }
  in_func && /\$1 == key \{/ { in_key=1 }
  in_func && in_key && /if \(!seen\)/ { seen_next=1 }
' setup.sh; then
  echo "::error::set_env_key must collapse duplicate assignments instead of rewriting every duplicate key."
  exit 1
fi
grep -F 'validate_ui_session_ttl_seconds()' setup.sh >/dev/null \
  || { echo "::error::setup.sh must validate UI_SESSION_TTL_SECONDS before writing or reusing it."; exit 1; }
grep -F 'validate_ui_session_ttl_seconds "$ui_session_ttl" "$env_file"' setup.sh >/dev/null \
  || { echo "::error::setup.sh update must validate preserved UI_SESSION_TTL_SECONDS before mutating or restarting the stack."; exit 1; }
grep -F 'validate_ui_session_ttl_seconds "$UI_SESSION_TTL_SECONDS" "$env_file"' setup.sh >/dev/null \
  || { echo "::error::setup.sh install must validate UI_SESSION_TTL_SECONDS before writing the runtime .env."; exit 1; }

if awk '
  /^  release:/ { in_release=1; next }
  in_release && /^  [[:alnum:]_-]+:/ { in_release=0 }
  in_release && /build-tools:latest/ { print FILENAME ":" FNR ":" $0; found=1 }
  END { exit found ? 0 : 1 }
' .github/workflows/build-push.yml; then
  echo "::error::Release jobs with write permissions must use the tag-scoped build-tools image, not mutable latest."
  exit 1
fi
forbidden_latest_default_branch='type=raw,value=latest,enable={{is_default'
forbidden_latest_default_branch="${forbidden_latest_default_branch}_branch}}"
if grep -Fq "$forbidden_latest_default_branch" .github/workflows/build-push.yml; then
  echo "::error::Default branch builds must not publish latest; latest is stable-release only."
  exit 1
fi
grep -F 'channel_tags+=(edge)' .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::Master promotion must publish the edge channel."; exit 1; }
grep -F 'channel_tags+=(latest)' .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::Stable release promotion must publish the latest channel."; exit 1; }
grep -F 'elif [[ "$GITHUB_REF_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then' .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::Stable release promotion must only move latest for exact vX.Y.Z tags."; exit 1; }
grep -F 'if [[ "$GITHUB_REF_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$ ]]; then' .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::Release candidate promotion must only accept exact vX.Y.Z-rc.N tags."; exit 1; }
grep -F 'docker buildx imagetools inspect "$source_image"' .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::Promotion must verify every source sha-* image before moving channel tags."; exit 1; }
grep -F 'needs: promote' .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::Release notes must run after channel promotion."; exit 1; }

if awk '
  /if \[ "\$status" = "200" \]/ { in_patch=1 }
  /elif \[ "\$status" = "404" \]/ { in_patch=0 }
  in_patch && /(draft[[:space:]]*:[[:space:]]*false|prerelease[[:space:]]*:[[:space:]]*false)/ { print FILENAME ":" FNR ":" $0; found=1 }
  END { exit found ? 0 : 1 }
' .github/workflows/build-push.yml; then
  echo "::error::Existing release PATCH must preserve draft/prerelease state."
  exit 1
fi

if awk '
  /This script must be run as root/ { after_root=1 }
  after_root && /assert_prebuilt_image_platform_supported/ { guard_seen=1 }
  after_root && !guard_seen && /(install_docker|systemctl enable --now docker)/ { print FILENAME ":" FNR ":" $0; found=1 }
  END { exit found ? 0 : 1 }
' setup.sh; then
  echo "::error::Prebuilt platform guard must run before Docker install or daemon startup."
  exit 1
fi

if awk '
  /^cmd_update\(\) \{/ { in_update=1; pause_seen=0; next }
  /^# .*debug subcommand/ { in_update=0 }
  in_update && /pause_lancache_convergence_for_update/ { pause_seen=1 }
  in_update && !pause_seen && /(cmd_backup|git -C|cp "\$install_dir\/deploy\/quickstart\/docker-compose\.yml"|migrate_env_for_update|validate_compose_config|docker[[:space:]]+compose([[:space:]]+--env-file[[:space:]]+[^[:space:]]+)?[[:space:]]+(pull|up))/ { print FILENAME ":" FNR ":" $0; found=1 }
  END { exit found ? 0 : 1 }
' setup.sh; then
  echo "::error::setup.sh update must pause the convergence timer before mutating local install state."
  exit 1
fi
grep -F 'systemctl stop lancache-converge.service' setup.sh >/dev/null \
  || { echo "::error::setup.sh update must stop any active convergence service before mutating local install state."; exit 1; }
if ! awk '
  /if ! \( cmd_backup --config "\$install_dir" \); then/ { in_backup_failure=1; next }
  in_backup_failure && /resume_lancache_convergence_after_update true/ { resume_seen=1 }
  in_backup_failure && /die "Pre-update rollback backup failed/ { die_seen=1; in_backup_failure=0 }
  END { exit resume_seen && die_seen ? 0 : 1 }
' setup.sh; then
  echo "::error::setup.sh update must restore the convergence timer when the rollback backup fails before update mutations."
  exit 1
fi
if awk '
  /^cmd_update_ip\(\) \{/ { in_update_ip=1; guard_seen=0; next }
  /^# .*backup subcommand/ { in_update_ip=0 }
  in_update_ip && /assert_prebuilt_image_platform_supported/ { guard_seen=1 }
  in_update_ip && !guard_seen && /(sed -i|docker compose -f)/ { print FILENAME ":" FNR ":" $0; found=1 }
  END { exit found ? 0 : 1 }
' setup.sh; then
  echo "::error::setup.sh update-ip must check prebuilt platform support before mutating local configuration."
  exit 1
fi
if awk '
  /^  shellcheck:/ { in_shellcheck=1; next }
  /^  [[:alnum:]_-]+:/ { in_shellcheck=0 }
  in_shellcheck && /^[[:space:]]+container:/ { print FILENAME ":" FNR ":" $0; found=1 }
  END { exit found ? 0 : 1 }
' .github/workflows/build-push.yml; then
  echo "::error::shellcheck job must not checkout inside a root-running job container."
  exit 1
fi
grep -F -- "--user \"\$(id -u):\$(id -g)\"" .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::shellcheck container must run with the runner UID/GID."; exit 1; }
grep -F -- "-v \"\$PWD:/work:ro\"" .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::shellcheck container must mount the workspace read-only."; exit 1; }
grep -F 'lancache-ng-build-tools-validation:${GITHUB_SHA:-local}-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}' scripts/select-build-tools-image.sh >/dev/null \
  || { echo "::error::Compose validation fallback image tag must be scoped to the workflow run and attempt."; exit 1; }
grep -F -- "--env DOCKER_CONFIG=/tmp/.docker" .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::Compose validation must set a writable Docker config directory inside the build-tools container."; exit 1; }
grep -F -- "--env HOME=/tmp" .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::Compose validation must set a writable HOME inside the build-tools container."; exit 1; }
# Acceleration-infrastructure policy checks start here.
# They validate the sccache/distcc contract, not product correctness.
if grep -RIn 'RUSTC_WRAPPER:[[:space:]]*""' .github/workflows; then
  echo "::error::Acceleration infrastructure checks must not disable RUSTC_WRAPPER directly; use cargo-with-sccache-fallback for controlled fallback."
  exit 1
fi
grep -F 'rpm_legacy_docker_package_list()' setup.sh >/dev/null \
  || { echo "::error::setup.sh must keep a shared legacy Docker RPM conflict list."; exit 1; }
grep -F 'docker-selinux' setup.sh >/dev/null \
  && grep -F 'docker-engine-selinux' setup.sh >/dev/null \
  || { echo "::error::Fedora/RHEL Docker RPM conflict guard must include legacy Docker selinux packages."; exit 1; }
grep -F 'docker-ce|docker-ce-cli|containerd.io|docker-buildx-plugin|docker-compose-plugin)' setup.sh >/dev/null \
  || { echo "::error::Installing only docker-compose-plugin on RPM hosts must still run the Docker/Podman conflict guard."; exit 1; }
if awk '
  /\[\[ "\$os_id" = fedora \]\]/ { in_fedora=1; next }
  /^    else$/ { in_fedora=0 }
  in_fedora && /( podman([[:space:]\\]|$)| runc([[:space:]\\]|$))/ { print FILENAME ":" FNR ":" $0; found=1 }
  END { exit found ? 0 : 1 }
' setup.sh; then
  echo "::error::Fedora Docker conflict guard must not block stock podman or runc."
  exit 1
fi
if grep -RIn -- 'timeout --foreground' .github/actions/cargo-with-sccache-fallback/action.yml; then
  echo "::error::cargo-with-sccache-fallback must not use timeout --foreground because it can leave Cargo child processes alive and bypass the fallback."
  exit 1
fi
for workflow in .github/workflows/build-push.yml .github/workflows/codeql.yml; do
  grep -F 'dist-scheduler-url:' "$workflow" >/dev/null \
    && grep -F 'SCCACHE_DIST_SCHEDULER_URL' "$workflow" >/dev/null \
    || { echo "::error::$workflow must wire SCCACHE_DIST_SCHEDULER_URL into configure-rust-sccache."; exit 1; }
  grep -F 'dist-auth-token:' "$workflow" >/dev/null \
    && grep -F 'SCCACHE_DIST_AUTH_TOKEN' "$workflow" >/dev/null \
    || { echo "::error::$workflow must wire SCCACHE_DIST_AUTH_TOKEN into configure-rust-sccache."; exit 1; }
done
grep -F 'sccache_dist_config=' .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::Docker Rust builds must pass sccache-dist config through a BuildKit secret."; exit 1; }
grep -F 'distcc_potential_hosts=' .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::Docker Rust builds must pass distcc hosts through a BuildKit secret."; exit 1; }
if awk '
  /^      - name: Prepare Rust acceleration secret files$/ { in_block=1; saw_pr_gate=0; next }
  in_block && /^      - name: / {
    if (!saw_pr_gate) {
      print FILENAME ":" FNR ":" "missing pull_request gate in Rust BuildKit secret preparation."
      bad=1
    }
    in_block=0
    next
  }
  in_block && /github.event_name != '\''pull_request'\''/ { saw_pr_gate=1 }
  in_block && /github.event.pull_request.head.repo.full_name == github.repository/ { print FILENAME ":" FNR ":" $0; bad=1 }
  END {
    if (in_block && !saw_pr_gate) bad=1
    exit bad ? 0 : 1
  }
' .github/workflows/build-push.yml; then
  echo "::error::Rust Docker builds must not prepare BuildKit secret-files on pull_request runs."
  exit 1
fi
grep -F 'uses: ./.github/actions/rust-acceleration-preflight' .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::Rust acceleration infrastructure checks must run an external preflight outside BuildKit cache."; exit 1; }
if grep -E '^[[:space:]]+RUST_ACCELERATION_NETWORK:[[:space:]]+host[[:space:]]*$' .github/workflows/build-push.yml >/dev/null; then
  echo "::error::Acceleration infrastructure network must not be globally pinned to host; trusted secret-backed builds select host per job."
  exit 1
fi
grep -E '^[[:space:]]+RUST_ACCELERATION_NETWORK:[[:space:]]+bridge[[:space:]]*$' .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::Acceleration infrastructure network must default to bridge for untrusted and non-accelerated builds."; exit 1; }
grep -F 'rust_network=bridge' .github/workflows/build-push.yml >/dev/null \
  && grep -F 'buildx_network=default' .github/workflows/build-push.yml >/dev/null \
  && grep -F 'rust_network=host' .github/workflows/build-push.yml >/dev/null \
  && grep -F 'buildx_network=host' .github/workflows/build-push.yml >/dev/null \
  && grep -F 'printf '\''RUST_ACCELERATION_NETWORK=%s\n'\'' "$rust_network" >> "$GITHUB_ENV"' .github/workflows/build-push.yml >/dev/null \
  && grep -F 'printf '\''RUST_BUILDX_NETWORK=%s\n'\'' "$buildx_network" >> "$GITHUB_ENV"' .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::Acceleration infrastructure network must be selected per job from generated secret files."; exit 1; }
grep -E '^[[:space:]]+redis-file:[[:space:]]+\$\{\{[[:space:]]*steps\.sccache-secret\.outputs\.redis-file[[:space:]]*\}\}[[:space:]]*$' .github/workflows/build-push.yml >/dev/null \
  && grep -E '^[[:space:]]+dist-config-file:[[:space:]]+\$\{\{[[:space:]]*steps\.sccache-secret\.outputs\.dist-config-file[[:space:]]*\}\}[[:space:]]*$' .github/workflows/build-push.yml >/dev/null \
  && grep -E '^[[:space:]]+distcc-hosts-file:[[:space:]]+\$\{\{[[:space:]]*steps\.sccache-secret\.outputs\.distcc-hosts-file[[:space:]]*\}\}[[:space:]]*$' .github/workflows/build-push.yml >/dev/null \
  && grep -E '^[[:space:]]+build-tools-image:[[:space:]]+\$\{\{[[:space:]]*env\.BUILD_TOOLS_IMAGE[[:space:]]*\}\}[[:space:]]*$' .github/workflows/build-push.yml >/dev/null \
  && grep -E '^[[:space:]]+build-network:[[:space:]]+\$\{\{[[:space:]]*env\.RUST_ACCELERATION_NETWORK[[:space:]]*\}\}[[:space:]]*$' .github/workflows/build-push.yml >/dev/null \
  && grep -E '^[[:space:]]+platform:[[:space:]]+linux/amd64[[:space:]]*$' .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::Acceleration preflight must receive all generated secret file paths."; exit 1; }
grep -F 'sccache rustc' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  && grep -F 'sccache --dist-status' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  && grep -F 'run_logged()' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  && grep -F 'require_sccache_dist_connected' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  && grep -F 'require_sccache_activity' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  && grep -F '.stats.cache_hits' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  && grep -F '.stats.cache_read_errors' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  && grep -F '.stats.cache_write_errors' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  && grep -F '.stats.cache_timeouts' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  && grep -F '.stats.cache_errors' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  && grep -F 'require_sccache_dist_activity' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  && grep -F 'distcc-pump --startup' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  && grep -F 'DISTCC_FALLBACK=0' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  && grep -F 'PATH="$wrapper_dir:$PATH"' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  && grep -F 'DISTCC_POTENTIAL_HOSTS="$distcc_pump_hosts"' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  && grep -F 'unset DISTCC_HOSTS' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  && grep -F 'distcc_hosts_without_pump="${distcc_hosts_without_pump:-$distcc_hosts}"' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  && grep -F 'distcc_pump_filtered_hosts="${DISTCC_HOSTS:-}"' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  && grep -F 'final_distcc_hosts="$distcc_hosts_without_pump"' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  && grep -F 'SCCACHE_REDIS_KEY_PREFIX="lancache-${LANCACHE_SERVICE}"' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  || { echo "::error::Acceleration preflight must validate sccache read/write, sccache-dist, and distcc paths."; exit 1; }
grep -F 'docker pull --platform "$BUILD_PLATFORM" "$BUILD_TOOLS_IMAGE"' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  && grep -F 'docker run --rm -i --platform "$BUILD_PLATFORM" --network "$BUILD_NETWORK"' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  || { echo "::error::Acceleration preflight must use the same platform as the real Docker builds."; exit 1; }
grep -F 'SCCACHE_SERVER_UDS="$preflight_dir/sccache.sock"' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  || { echo "::error::Acceleration preflight must isolate its sccache server from runner-global daemons."; exit 1; }
grep -F -- '--network "$RUST_ACCELERATION_NETWORK"' .github/workflows/build-push.yml >/dev/null \
  && grep -E '^[[:space:]]+network:[[:space:]]+' .github/workflows/build-push.yml | grep -F 'env.RUST_BUILDX_NETWORK' >/dev/null \
  && grep -E '^[[:space:]]+allow:[[:space:]]+' .github/workflows/build-push.yml | grep -F 'network.host' >/dev/null \
  || { echo "::error::Acceleration infrastructure must use the same network mode as the preflight."; exit 1; }
grep -F 'allow_args+=(--allow network.host)' .github/workflows/build-push.yml >/dev/null \
  && grep -F '"${allow_args[@]}" \' .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::Local docker build scan must pass --allow network.host when host networking is selected."; exit 1; }
grep -F 'name: Set up Docker Buildx for scan build' .github/workflows/build-push.yml >/dev/null \
  && grep -F 'docker buildx build \' .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::Local scan build must use an explicit docker-container Buildx builder (docker buildx build), not the plain docker driver -- network.host entitlement is only granted by default on container-driver builders."; exit 1; }
grep -F -- '--crate-type lib' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  && grep -F -- '--emit=link,dep-info' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  && grep -F -- '--out-dir' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
  || { echo "::error::Acceleration preflight must use a cacheable rustc library probe."; exit 1; }
if grep -F -- '--crate-type bin' .github/actions/rust-acceleration-preflight/action.yml \
  || grep -E 'sccache rustc .* -o ' .github/actions/rust-acceleration-preflight/action.yml; then
  echo "::error::Acceleration preflight must not use non-cacheable binary rustc probes."
  exit 1
fi
grep -F 'steps.docker-build-jobs.outputs.jobs' .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::Docker Rust builds must pass computed CARGO_BUILD_JOBS as a build argument."; exit 1; }
grep -F 'build_tools_image:' .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::Docker Rust builds must expose the selected build-tools image as a job output."; exit 1; }
grep -F "printf 'build_tools_image=ghcr.io/%s/build-tools:latest\\n' \"\$GITHUB_REPOSITORY\" >> \"\$GITHUB_OUTPUT\"" .github/workflows/build-push.yml >/dev/null \
  && { echo "::error::The exported build-tools job output must not be hardcoded without validating that exact pullable image."; exit 1; }
grep -F 'BUILD_TOOLS_REQUIRE_PUBLISHED=true bash scripts/select-build-tools-image.sh' .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::Downstream build-tools job output must validate the exact pullable GHCR image before exporting it."; exit 1; }
# Positive check (not a "must NOT contain the old pattern" negative
# check): the old negative form quoted the forbidden pattern as its
# own grep -F argument using single quotes, so the check's own
# source line was a byte-for-byte match of the thing it was
# supposed to detect as absent -- it would have failed
# unconditionally, forever, regardless of the real code below.
grep -F 'validation_build_tools_image="$downstream_build_tools_image"' .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::validate-compose runs on the light tier and must reuse the already-resolved downstream_build_tools_image instead of building a local fallback."; exit 1; }
grep -F 'published_image_reference()' scripts/select-build-tools-image.sh >/dev/null \
  && grep -F 'docker buildx imagetools inspect "$image"' scripts/select-build-tools-image.sh >/dev/null \
  && grep -F 'published_image_reference "$published_image"' scripts/select-build-tools-image.sh >/dev/null \
  || { echo "::error::Build-tools selector must export the smoke-validated published image by multi-arch manifest digest."; exit 1; }
if awk '
  index($0, "downstream_build_tools_image=\"$(BUILD_TOOLS_REQUIRE_PUBLISHED=true bash scripts/select-build-tools-image.sh)\"") { in_resolve = 1 }
  in_resolve && index($0, "printf '\''build_tools_image=%s\\n'\'' \"$downstream_build_tools_image\"") { exit found ? 0 : 1 }
  in_resolve && index($0, "docker pull \"$downstream_build_tools_image\"") { found = 1 }
  END { exit found ? 0 : 1 }
' .github/workflows/build-push.yml; then
  echo "::error::validate-compose must not re-pull mutable build-tools tags after selector smoke validation."
  exit 1
fi
grep -F 'BUILD_TOOLS_IMAGE:' .github/workflows/build-push.yml >/dev/null \
  && grep -F "needs['validate-compose'].outputs.build_tools_image" .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::Docker Rust builds must thread the selected build-tools image into service builds."; exit 1; }
awk '
  /name: Merge coverage reports and check threshold/ { in_merge = 1; has_docker = 0; has_build_tools = 0; next }
  in_merge && /^[[:space:]]+- name: / { exit (has_docker && has_build_tools) ? 0 : 1 }
  in_merge && /docker run --rm/ { has_docker = 1 }
  in_merge && /BUILD_TOOLS_IMAGE/ { has_build_tools = 1 }
  END { if (in_merge) exit (has_docker && has_build_tools) ? 0 : 1; exit 1 }
' .github/workflows/build-push.yml \
  || { echo "::error::Coverage merge must use the selected build-tools image instead of bare host jq/bc."; exit 1; }
grep -F 'needs: validate-compose' .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::Shellcheck must depend on validate-compose so it uses the validated build-tools image."; exit 1; }
grep -F 'runs-on: [self-hosted, linux, lancache, lancache-heavy]' .github/workflows/build-tools.yml >/dev/null \
  || { echo "::error::The build-tools workflow's amd64 leg must run on the heavy runner tier."; exit 1; }
# arm64 builds natively on a GitHub-hosted runner (same rationale as
# build-push.yml's build-arm64, #592) instead of QEMU on the
# self-hosted pool -- confirmed on #606 that emulating the
# docker-compose source build added for CVE-2026-39822 fails
# reproducibly under QEMU with a Go compiler "bufio: buffer full"
# error. This must not regress back to an emulated arm64 leg.
grep -F 'runs-on: ubuntu-24.04-arm' .github/workflows/build-tools.yml >/dev/null \
  || { echo "::error::The build-tools workflow's arm64 leg must run natively on ubuntu-24.04-arm, not QEMU."; exit 1; }
grep -F 'setup-qemu-action' .github/workflows/build-tools.yml >/dev/null \
  && { echo "::error::The build-tools workflow must not reintroduce QEMU emulation for its arm64 leg."; exit 1; }
awk '
  /name: Build and push amd64 build-tools image/ { in_publish = 1; found = 0; next }
  in_publish && /name: / { exit found ? 0 : 1 }
  in_publish && /pull: true/ { found = 1 }
  END { if (in_publish) exit found ? 0 : 1; exit 1 }
' .github/workflows/build-tools.yml \
  || { echo "::error::The build-tools amd64 publish step must pull fresh mutable bases before publishing."; exit 1; }
awk '
  /name: Build and push arm64 build-tools image/ { in_publish = 1; found = 0; next }
  in_publish && /name: / { exit found ? 0 : 1 }
  in_publish && /pull: true/ { found = 1 }
  END { if (in_publish) exit found ? 0 : 1; exit 1 }
' .github/workflows/build-tools.yml \
  || { echo "::error::The build-tools arm64 publish step must pull fresh mutable bases before publishing."; exit 1; }
grep -F 'image-ref:' .github/workflows/build-tools.yml | grep -F 'BUILD_TOOLS_IMAGE' | grep -F 'steps.build.outputs.digest' >/dev/null \
  && grep -F 'image-ref:' .github/workflows/build-push.yml | grep -F 'github.repository' | grep -F 'matrix.service' | grep -F 'steps.build.outputs.digest' >/dev/null \
  || { echo "::error::Build-tools publish paths must scan the exact pushed digest before attestation/promotion."; exit 1; }
# build/build-arm64's "Build and push" step (#822) now runs through
# .github/actions/ghcr-build-push-retry instead of a bare
# docker/build-push-action + inline "retry-build" sibling step, so
# steps.build.outputs.digest above already resolves to whichever
# internal attempt succeeded -- there is no separate retry-build
# step id left to reference. Guard that the retry wrapper itself
# stays wired in, instead of the now-removed digest-fallback text.
grep -F 'uses: ./.github/actions/ghcr-build-push-retry' .github/workflows/build-push.yml >/dev/null \
  || { echo "::error::build/build-arm64 must publish through the shared ghcr-build-push-retry composite action so GHCR pushes retry on transient 401s (#822)."; exit 1; }
grep -F 'Note arm64 scan coverage deferral' .github/workflows/build-tools.yml >/dev/null \
  && { echo "::error::The build-tools workflow must not keep the stale arm64 scan deferral notice."; exit 1; }
grep -F 'Build local arm64 scan image' .github/workflows/build-tools.yml >/dev/null \
  && grep -F 'BUILD_TOOLS_SCAN_IMAGE_ARM64' .github/workflows/build-tools.yml >/dev/null \
  && grep -F 'docker run --rm --platform linux/arm64 "${BUILD_TOOLS_SCAN_IMAGE_ARM64:?BUILD_TOOLS_SCAN_IMAGE_ARM64 is required}"' .github/workflows/build-tools.yml >/dev/null \
  && grep -F 'Scan local build-tools arm64 image with Trivy' .github/workflows/build-tools.yml >/dev/null \
  || { echo "::error::The build-tools workflow must build, smoke-test, and Trivy-scan the local arm64 scan image before publishing."; exit 1; }
grep -F 'merge-build-tools-manifests' .github/workflows/build-tools.yml >/dev/null \
  && grep -F 'imagetools create' .github/workflows/build-tools.yml >/dev/null \
  || { echo "::error::The build-tools workflow must merge its amd64/arm64 tags into the real sha-<commit> manifest before promoting mutable tags."; exit 1; }
# build-tools.yml's "Promote mutable tags" step writes a
# branch-name-derived mutable tag, and this repo has a branch
# literally named "v0.2.0" -- without the "-tc" ("test candidate")
# suffix, a push to that branch would publish build-tools:v0.2.0,
# the exact tag build-push.yml's own promote job below writes as
# the real, immutable vX.Y.Z stable-release tag for the same GHCR
# package once that version is actually tagged. A pin check alone
# (grepping for the literal "branch_tag=\"${sanitized_ref}-tc\""
# text) would pass even if a future edit kept that literal string
# in place but then overwrote branch_tag again afterward for a
# release-shaped ref, so the grep alone cannot catch that. Instead
# of retyping the derivation logic here (which could quietly drift
# from the real thing), extract build-tools.yml's actual "Promote
# mutable tags" run script -- everything from its tag derivation
# up to (not including) the docker buildx call that consumes it --
# and execute those exact lines under a representative set of real
# and adversarial ref names, including "v0.2.0" itself and other
# vX.Y.Z-shaped branch names, failing if any of them come out
# shaped like a real release tag. Because this runs the real
# script text, a bypass added anywhere in that extracted range
# (not just a changed literal) is caught too.
grep -F 'branch_tag="${sanitized_ref}-tc"' .github/workflows/build-tools.yml >/dev/null \
  || { echo "::error::build-tools.yml's branch-tag promotion must suffix every derived tag with '-tc' so a branch named like a release tag (e.g. v0.2.0) can never collide with a real vX.Y.Z stable-release tag on the same GHCR package."; exit 1; }
# Anchored on the plain substring "sanitized_ref=" (no regex
# metacharacters) rather than a fuller literal match: this awk
# script must behave identically on CI's mawk and on gawk used
# for local testing, and mid-pattern "$" escaping is exactly where
# those implementations are known to diverge in ERE mode.
promote_tags_script="$(awk '
  /name: Promote mutable tags/ { in_step = 1 }
  in_step && /sanitized_ref=/ { capture = 1 }
  in_step && capture && /docker buildx imagetools create/ { exit }
  in_step && capture { print }
' .github/workflows/build-tools.yml)"
if [ -z "$promote_tags_script" ]; then
  echo "::error::Could not extract build-tools.yml's \"Promote mutable tags\" derivation logic -- its step name or tag-derivation lines may have moved; update the extraction markers in build-push.yml's guard alongside them."
  exit 1
fi
# Write the extracted lines to a real script file rather than a
# bash -c string: the extracted text already contains its own
# quotes and a multi-line comment, and re-quoting that safely as a
# single -c argument would need error-prone escaping. A file
# avoids that entirely and lets bash run the exact extracted text
# unmodified, with a trailing line that prints the result.
guard_script="$(mktemp)"
trap 'rm -f "$guard_script"' EXIT
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' "$promote_tags_script"
  printf '%s\n' 'printf '\''%s'\'' "$branch_tag"'
} > "$guard_script"
for candidate_ref in v0.2.0 v1.2.3 v10.20.30 master feature/x; do
  derived_tag="$(
    REF_NAME="$candidate_ref" \
    BUILD_TOOLS_IMAGE=ghcr.io/example/build-tools \
    MERGED_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000 \
    bash "$guard_script"
  )"
  if printf '%s' "$derived_tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "::error::build-tools.yml's branch-tag derivation must never be able to emit a release-shaped tag; ref '$candidate_ref' produced '$derived_tag'."
    exit 1
  fi
done
for workflow in .github/workflows/build-push.yml .github/workflows/codeql.yml; do
  grep -F 'CARGO_BUILD_JOBS:' "$workflow" >/dev/null \
    && grep -F 'vars.CARGO_BUILD_JOBS' "$workflow" >/dev/null \
    || { echo "::error::$workflow must expose the CARGO_BUILD_JOBS repository variable to Cargo jobs."; exit 1; }
done
if grep -RInE '^(ARG SCCACHE_DIST_SCHEDULER_URL|ENV CARGO_BUILD_JOBS=)' services/*/Dockerfile; then
  echo "::error::Rust service Dockerfiles must not use scheduler-only args or hardcoded CARGO_BUILD_JOBS values."
  exit 1
fi
if grep -RInE 'cargo install sccache .*--locked|cargo install .*--locked .*sccache' services/*/Dockerfile tools/build-tools/Dockerfile scripts/*.sh; then
  echo "::error::sccache source installs must stay version-pinned but not use --locked while the pinned upstream lockfile emits yanked-crate warnings."
  exit 1
fi
if grep -RIn 'cargo install sccache' services/*/Dockerfile tools/build-tools/Dockerfile scripts/*.sh | grep -v -- '--no-default-features --features redis,dist-client'; then
  echo "::error::sccache source installs must use the minimal Redis plus dist-client feature set."
  exit 1
fi
if grep -RIn '[c]argo install cargo-audit' .github/workflows scripts services/*/Dockerfile; then
  echo "::error::CI and service builds must use prebuilt cargo-audit from the build-tools image instead of compiling it per job."
  exit 1
fi
for dockerfile in services/dns/Dockerfile services/ui/Dockerfile; do
  grep -F 'ARG BUILD_TOOLS_IMAGE=ghcr.io/wiki-mod/lancache-ng/build-tools:latest' "$dockerfile" >/dev/null \
    || { echo "::error::$dockerfile must declare the shared build-tools image as a build argument."; exit 1; }
  grep -F 'FROM ${BUILD_TOOLS_IMAGE}' "$dockerfile" >/dev/null \
    || { echo "::error::$dockerfile must use the shared build-tools image in the Rust builder stage."; exit 1; }
  if grep -F 'cargo install sccache' "$dockerfile" >/dev/null || grep -F 'apt-get download "distcc-pump=' "$dockerfile" >/dev/null; then
    echo "::error::$dockerfile must not bootstrap Rust builder tools locally anymore."
    exit 1
  fi
  grep -F 'for tool in cargo rustc rustup rustfmt clippy-driver sccache distcc distcc-pump python3 pkg-config; do' "$dockerfile" >/dev/null \
    && grep -F 'command -v "$tool" >/dev/null' "$dockerfile" >/dev/null \
    || { echo "::error::$dockerfile must fail closed if the shared build-tools image is missing a required tool."; exit 1; }
  grep -F 'lancache-rustc-wrapper' "$dockerfile" >/dev/null \
    || { echo "::error::$dockerfile must keep the sccache wrapper in place for Rust compiler invocations."; exit 1; }
  grep -F -- "--mount=type=secret,id=sccache_dist_config" "$dockerfile" >/dev/null \
    || { echo "::error::$dockerfile must consume sccache-dist config through a BuildKit secret."; exit 1; }
  grep -F -- "--mount=type=secret,id=distcc_potential_hosts" "$dockerfile" >/dev/null \
    || { echo "::error::$dockerfile must consume distcc hosts through a BuildKit secret."; exit 1; }
  grep -F 'sccache --dist-status' "$dockerfile" >/dev/null \
    || { echo "::error::$dockerfile must smoke-check sccache-dist when configured."; exit 1; }
  grep -F 'resolve_distcc_wrapper_dir()' "$dockerfile" >/dev/null \
    && grep -F 'for wrapper in cc gcc c++ g++; do' "$dockerfile" >/dev/null \
    && grep -F '"/usr/local/lib/distcc/$wrapper"' "$dockerfile" >/dev/null \
    && grep -F '/usr/local/lib/distcc /usr/lib/distcc' "$dockerfile" >/dev/null \
    && grep -F 'PATH="$distcc_wrapper_dir:$PATH" CC=cc GCC=gcc CXX=c++ GXX=g++' "$dockerfile" >/dev/null \
    || { echo "::error::$dockerfile must discover the distcc wrapper directory and route cc/gcc/c++/g++ through it."; exit 1; }
  grep -F 'original_path="$PATH"' "$dockerfile" >/dev/null \
    || { echo "::error::$dockerfile must save the original PATH before enabling distcc."; exit 1; }
  grep -F 'PATH="$original_path"' "$dockerfile" >/dev/null \
    || { echo "::error::$dockerfile must restore the original PATH before local compiler fallback."; exit 1; }
  grep -F 'PATH="$distcc_wrapper_dir:$PATH";' "$dockerfile" >/dev/null \
    || { echo "::error::$dockerfile must re-prepend the wrapper directory after distcc-pump startup."; exit 1; }
  grep -F 'lancache-rustc-wrapper' "$dockerfile" >/dev/null \
    && grep -F 'distcc|*/distcc) exec "$@" ;;' "$dockerfile" >/dev/null \
    || { echo "::error::$dockerfile must keep distcc out of the sccache Rust wrapper path."; exit 1; }
  grep -F 'lancache-distcc-wrapper' "$dockerfile" >/dev/null \
    && grep -F 'DISTCC_HOSTS_NO_PUMP' "$dockerfile" >/dev/null \
    || {
      if [ "$dockerfile" = "services/dns/Dockerfile" ]; then
        :;
      else
        echo "::error::$dockerfile must define a non-pump distcc host list for generated-header bypass."; exit 1;
      fi
    }
  if [ "$dockerfile" = "services/ui/Dockerfile" ]; then
    grep -F 'distcc_hosts_without_pump="${distcc_hosts_without_pump:-$distcc_hosts}"' "$dockerfile" >/dev/null \
      || { echo "::error::$dockerfile must fall back to stripped distcc hosts when no plain hosts are configured."; exit 1; }
    if grep -F 'DISTCC_HOSTS_NO_PUMP="${DISTCC_HOSTS:-$DISTCC_HOSTS_NO_PUMP}";' "$dockerfile" >/dev/null; then
      echo "::error::$dockerfile must not reassign DISTCC_HOSTS_NO_PUMP from the pump-published host list -- that list's ,cpp/,lzo suffix is only meaningful to a running include server, and lancache-distcc-wrapper's whole reason for using DISTCC_HOSTS_NO_PUMP is compiling WITHOUT one (confirmed live: this exact reassignment leaked the pump suffix into non-pump compiles, see #613)."
      exit 1
    fi
    grep -F 'export DISTCC_POTENTIAL_HOSTS="$distcc_pump_hosts";' "$dockerfile" >/dev/null \
      && grep -F 'distcc-pump --startup' "$dockerfile" >/dev/null \
      || { echo "::error::$dockerfile must start distcc-pump with pump-capable hosts only."; exit 1; }
    grep -F 'distcc-pump --startup' "$dockerfile" >/dev/null \
      || { echo "::error::$dockerfile must use distcc-pump for compatible generated-header bypass cases."; exit 1; }
    grep -F 'matches_aws_lc_generated_path' "$dockerfile" >/dev/null \
      || { echo "::error::$dockerfile must document aws-lc-sys generated-header bypass patterns in wrapper logic."; exit 1; }
  else
    grep -F 'DISTCC_POTENTIAL_HOSTS="$(cat /run/secrets/distcc_potential_hosts)"' "$dockerfile" >/dev/null \
      || { echo "::error::$dockerfile must keep distcc-pump host discovery local to the builder."; exit 1; }
    grep -F 'distcc-pump --startup' "$dockerfile" >/dev/null \
      || { echo "::error::$dockerfile must use distcc-pump unless the builder is documented as incompatible with generated C headers."; exit 1; }
  fi
  grep -F 'echo "[INFO] trying distcc path."' "$dockerfile" >/dev/null \
    || { echo "::error::$dockerfile must log when the distcc path is actually attempted."; exit 1; }
  grep -F 'DISTCC_FALLBACK=0' "$dockerfile" >/dev/null \
    || { echo "::error::$dockerfile must disable distcc internal local fallback so project fallback logic can decide explicitly."; exit 1; }
  grep -F 'run_cargo_build()' "$dockerfile" >/dev/null \
    || { echo "::error::$dockerfile must retry once with the normal local compiler when the distcc path is unavailable."; exit 1; }
  if grep -F 'python3 -Werror::SyntaxWarning -m py_compile "$distcc_pump_parser"' "$dockerfile" >/dev/null; then
    echo "::error::$dockerfile must not patch distcc-pump locally now that the shared build-tools image provides it."
    exit 1
  fi
  grep -F 'cargo build -j "$cargo_jobs"' "$dockerfile" >/dev/null \
    || { echo "::error::$dockerfile must use the resolved cargo job count."; exit 1; }
done

if awk '
  /^# .*Installing systemd watchdog/ { in_install=1; pull_seen=0 }
  /^# .*Post-start info/ { in_install=0 }
  in_install && /docker[[:space:]]+compose([[:space:]]+--env-file[[:space:]]+[^[:space:]]+)?[[:space:]]+pull/ { pull_seen=1 }
  in_install && /^[[:space:]]*(systemctl[[:space:]]+(enable|start)[[:space:]]+(lancache\.service|lancache-converge\.timer)|docker[[:space:]]+compose([[:space:]]+--env-file[[:space:]]+[^[:space:]]+)?[[:space:]]+up[[:space:]]+-d)/ && !pull_seen { print FILENAME ":" FNR ":" $0; found=1 }
  END { exit found ? 0 : 1 }
' setup.sh; then
  echo "::error::setup.sh must not start or enable lancache services before image pull succeeds."
  exit 1
fi

grep -F 'lancache_image_registry=$(resolve_lancache_image_registry "$env_file")' setup.sh >/dev/null \
  || { echo "::error::Update migration must resolve LANCACHE_IMAGE_REGISTRY from existing config instead of hard-coding it."; exit 1; }
grep -F 'lancache_image_prefix=$(resolve_lancache_image_prefix "$env_file")' setup.sh >/dev/null \
  || { echo "::error::Update migration must resolve LANCACHE_IMAGE_PREFIX from existing config instead of hard-coding it."; exit 1; }
grep -F 'lancache_image_channel=$(resolve_lancache_image_channel "$env_file")' setup.sh >/dev/null \
  || { echo "::error::Update migration must resolve LANCACHE_IMAGE_CHANNEL from existing config instead of hard-coding it."; exit 1; }
grep -F 'lancache_image_tag=$(resolve_lancache_image_tag "$env_file")' setup.sh >/dev/null \
  || { echo "::error::Update migration must refresh LANCACHE_IMAGE_TAG with resolve_lancache_image_tag."; exit 1; }
grep -F 'LANCACHE_IMAGE_CHANNEL=pinned requires LANCACHE_IMAGE_TAG to be set to an immutable sha-* or vX.Y.Z tag.' setup.sh >/dev/null \
  || { echo "::error::Pinned image channel must fail closed when LANCACHE_IMAGE_TAG is missing."; exit 1; }
grep -F 'resolve_lancache_stack_channel_tag()' setup.sh >/dev/null \
  || { echo "::error::setup.sh must resolve mutable image channels through the stack pointer image."; exit 1; }
grep -F 'docker cp "${container_id}:/stack.env" -' setup.sh >/dev/null \
  || { echo "::error::setup.sh must read stack.env from the stack pointer image."; exit 1; }
grep -F 'pub image_tag: String' services/ui/src/routes/secondaries.rs >/dev/null \
  || { echo "::error::Secondary registration response must expose image_tag."; exit 1; }
grep -F 'pub image_registry: String' services/ui/src/routes/secondaries.rs >/dev/null \
  || { echo "::error::Secondary registration response must expose image_registry."; exit 1; }
grep -F 'pub image_prefix: String' services/ui/src/routes/secondaries.rs >/dev/null \
  || { echo "::error::Secondary registration response must expose image_prefix."; exit 1; }
grep -F 'pub image_channel: String' services/ui/src/routes/secondaries.rs >/dev/null \
  || { echo "::error::Secondary registration response must expose image_channel."; exit 1; }
grep -F 'image_tag: state.config.lancache_image_tag.clone()' services/ui/src/routes/secondaries.rs >/dev/null \
  || { echo "::error::Secondary registration response must use the primary LANCACHE_IMAGE_TAG."; exit 1; }
grep -F 'image_registry: state.config.lancache_image_registry.clone()' services/ui/src/routes/secondaries.rs >/dev/null \
  || { echo "::error::Secondary registration response must use the primary LANCACHE_IMAGE_REGISTRY."; exit 1; }
grep -F 'image_prefix: state.config.lancache_image_prefix.clone()' services/ui/src/routes/secondaries.rs >/dev/null \
  || { echo "::error::Secondary registration response must use the primary LANCACHE_IMAGE_PREFIX."; exit 1; }
grep -F 'image_channel: state.config.lancache_image_channel.clone()' services/ui/src/routes/secondaries.rs >/dev/null \
  || { echo "::error::Secondary registration response must use the primary LANCACHE_IMAGE_CHANNEL."; exit 1; }
grep -F "LANCACHE_IMAGE_REGISTRY=\${LANCACHE_IMAGE_REGISTRY:-ghcr.io}" deploy/quickstart/docker-compose.yml >/dev/null \
  && grep -F "LANCACHE_IMAGE_REGISTRY=\${LANCACHE_IMAGE_REGISTRY:-ghcr.io}" deploy/prod/docker-compose.yml >/dev/null \
  || { echo "::error::UI must receive LANCACHE_IMAGE_REGISTRY."; exit 1; }
grep -F "LANCACHE_IMAGE_PREFIX=\${LANCACHE_IMAGE_PREFIX:-wiki-mod/lancache-ng}" deploy/quickstart/docker-compose.yml >/dev/null \
  && grep -F "LANCACHE_IMAGE_PREFIX=\${LANCACHE_IMAGE_PREFIX:-wiki-mod/lancache-ng}" deploy/prod/docker-compose.yml >/dev/null \
  || { echo "::error::UI must receive LANCACHE_IMAGE_PREFIX."; exit 1; }
grep -F "LANCACHE_IMAGE_CHANNEL=\${LANCACHE_IMAGE_CHANNEL:-}" deploy/quickstart/docker-compose.yml >/dev/null \
  && grep -F "LANCACHE_IMAGE_CHANNEL=\${LANCACHE_IMAGE_CHANNEL:-}" deploy/prod/docker-compose.yml >/dev/null \
  || { echo "::error::UI must receive LANCACHE_IMAGE_CHANNEL."; exit 1; }
grep -F "response_image_tag=\$(echo \"\$response\"" setup.sh >/dev/null \
  || { echo "::error::setup.sh secondary must parse the primary image_tag."; exit 1; }
grep -F "response_image_registry=\$(echo \"\$response\"" setup.sh >/dev/null \
  || { echo "::error::setup.sh secondary must parse the primary image_registry."; exit 1; }
grep -F "response_image_prefix=\$(echo \"\$response\"" setup.sh >/dev/null \
  || { echo "::error::setup.sh secondary must parse the primary image_prefix."; exit 1; }
grep -F "response_image_channel=\$(echo \"\$response\"" setup.sh >/dev/null \
  || { echo "::error::setup.sh secondary must parse the primary image_channel."; exit 1; }
grep -F "LANCACHE_IMAGE_TAG=\${LANCACHE_IMAGE_TAG:-latest}" deploy/quickstart/docker-compose.yml >/dev/null \
  || { echo "::error::Quickstart UI must receive LANCACHE_IMAGE_TAG."; exit 1; }
grep -F "LANCACHE_IMAGE_TAG=\${LANCACHE_IMAGE_TAG:-latest}" deploy/prod/docker-compose.yml >/dev/null \
  || { echo "::error::Prod UI must receive LANCACHE_IMAGE_TAG."; exit 1; }
grep -F 'LANCACHE_IMAGE_REGISTRY=${LANCACHE_IMAGE_REGISTRY}' setup.sh >/dev/null \
  || { echo "::error::setup.sh must write LANCACHE_IMAGE_REGISTRY."; exit 1; }
grep -F 'LANCACHE_IMAGE_PREFIX=${LANCACHE_IMAGE_PREFIX}' setup.sh >/dev/null \
  || { echo "::error::setup.sh must write LANCACHE_IMAGE_PREFIX."; exit 1; }
grep -F 'LANCACHE_IMAGE_CHANNEL=${lancache_image_channel}' setup.sh >/dev/null \
  || { echo "::error::setup.sh secondary must write LANCACHE_IMAGE_CHANNEL."; exit 1; }
grep -F 'derive_release_archive_image_tag()' setup.sh >/dev/null \
  || { echo "::error::setup.sh must preserve release archive image tags before defaulting to latest."; exit 1; }
grep -F 'channel="${channel:-latest}"' setup.sh >/dev/null \
  || { echo "::error::setup.sh must keep latest as the normal stable default; edge must be explicit."; exit 1; }
grep -F 'LANCACHE_IMAGE_CHANNEL=latest' README.md >/dev/null \
  || { echo "::error::README must document latest as the normal install default."; exit 1; }
grep -F 'edge installs must explicitly set `LANCACHE_IMAGE_CHANNEL=edge`' docs/release-versioning.md >/dev/null \
  || { echo "::error::Release docs must keep edge opt-in, not default."; exit 1; }
grep -F 'docker build --pull -t "$fallback_image" "$build_tools_context" >&2' scripts/select-build-tools-image.sh >/dev/null \
  || { echo "::error::build-tools selector must keep Docker build output out of stdout."; exit 1; }
bash scripts/validate-stack-images.sh
VALIDATE_COMPOSE

