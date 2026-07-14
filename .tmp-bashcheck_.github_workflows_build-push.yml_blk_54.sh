set -euo pipefail

mode="${SCCACHE_REDIS_MODE:-required}"
secret_files=()

toml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

case "$mode" in
  required|optional|off)
    ;;
  *)
    echo "::error::SCCACHE_REDIS_MODE must be one of: required, optional, off."
    exit 1
    ;;
esac

sccache_enabled=1
redis_enabled=1
if [ "$mode" = "off" ]; then
  sccache_enabled=0
  redis_enabled=0
  echo "Redis-backed sccache is disabled by SCCACHE_REDIS_MODE=off."
fi

if [ "$sccache_enabled" = "1" ] && [ -n "$SCCACHE_DIST_SCHEDULER_URL" ] && [ -z "$SCCACHE_DIST_AUTH_TOKEN" ]; then
  echo "::error::SCCACHE_DIST_AUTH_TOKEN is required when SCCACHE_DIST_SCHEDULER_URL is set."
  exit 1
fi

if [ "$sccache_enabled" = "1" ] && [ -z "$SCCACHE_DIST_SCHEDULER_URL" ] && [ -n "$SCCACHE_DIST_AUTH_TOKEN" ]; then
  echo "::error::SCCACHE_DIST_SCHEDULER_URL is required when SCCACHE_DIST_AUTH_TOKEN is set."
  exit 1
fi

if [ "$sccache_enabled" = "1" ] && [ -z "$SCCACHE_REDIS_URL" ]; then
  if [ "$mode" = "optional" ]; then
    echo "Skipping Redis-backed sccache because SCCACHE_REDIS_URL is empty and SCCACHE_REDIS_MODE=optional."
    redis_enabled=0
  else
    echo "::error::SCCACHE_REDIS_URL repository secret is required for trusted Rust image scans so sccache can use Redis."
    exit 1
  fi
fi

umask 077
if [ "$redis_enabled" = "1" ]; then
  redis_file="${{ runner.temp }}/sccache-redis-url"
  printf '%s' "$SCCACHE_REDIS_URL" > "$redis_file"
  secret_files+=("sccache_redis_url=$redis_file")
  echo "redis-file=$redis_file" >> "$GITHUB_OUTPUT"
fi

if [ "$sccache_enabled" = "1" ] && [ -n "$SCCACHE_DIST_SCHEDULER_URL" ]; then
  dist_config_file="${{ runner.temp }}/sccache-dist-config"
  {
    printf '[dist]\n'
    printf 'scheduler_url = "%s"\n' "$(toml_escape "$SCCACHE_DIST_SCHEDULER_URL")"
    printf 'toolchains = []\n'
    printf 'toolchain_cache_size = 5368709120\n'
    printf '\n[dist.auth]\n'
    printf 'type = "token"\n'
    printf 'token = "%s"\n' "$(toml_escape "$SCCACHE_DIST_AUTH_TOKEN")"
  } > "$dist_config_file"
  secret_files+=("sccache_dist_config=$dist_config_file")
  echo "dist-config-file=$dist_config_file" >> "$GITHUB_OUTPUT"
fi

if [ -n "$DISTCC_POTENTIAL_HOSTS" ]; then
  if ! printf '%s\n' "$DISTCC_POTENTIAL_HOSTS" | grep -q ',cpp'; then
    echo "::error::DISTCC_POTENTIAL_HOSTS must include at least one pump-capable host with the ',cpp' option."
    exit 1
  fi

  distcc_hosts_file="${{ runner.temp }}/distcc-potential-hosts"
  printf '%s' "$DISTCC_POTENTIAL_HOSTS" > "$distcc_hosts_file"
  secret_files+=("distcc_potential_hosts=$distcc_hosts_file")
  echo "distcc-hosts-file=$distcc_hosts_file" >> "$GITHUB_OUTPUT"
fi

{
  echo "secret-files<<SECRET_FILES"
  printf '%s\n' "${secret_files[@]}"
  echo "SECRET_FILES"
} >> "$GITHUB_OUTPUT"

