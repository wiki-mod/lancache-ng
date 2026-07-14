set -euo pipefail

docker run --rm -i \
  --user "$(id -u):$(id -g)" \
  -v "$PWD:/work:ro" \
  -w /work \
  "${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}" \
  bash -s <<'VALIDATE_PREBUILT'
set -euo pipefail

if grep -RInE '^[[:space:]]+build:' deploy/prod deploy/quickstart; then
  echo "::error::Production and quickstart compose files must use prebuilt images only."
  exit 1
fi

if grep -RIn -- '--build' README.md deploy/prod deploy/quickstart setup.sh; then
  echo "::error::User-facing production install paths must not instruct users to build images locally."
  exit 1
fi

if grep -RIn -- '/srv/lancache' README.md CLAUDE.md deploy/prod deploy/quickstart services/ui/src; then
  echo "::error::Runtime defaults and user-facing install paths must use /opt/lancache-ng, not legacy /srv/lancache."
  exit 1
fi

# State-root migration contract:
# - manual prod keeps one normal root knob (LANCACHE_STATE_DIR)
# - optional per-service keys are preserved only for real legacy/custom paths
# - setup.sh must not treat a bare /srv/lancache directory as active state
#
# CACHE_DIR_STANDARD/CACHE_DIR_SSL are deliberately NOT in this loop.
# Every other key here is a legitimate, permanent advanced override
# an operator may still want (see set_optional_env_path_override_if_needed's
# own "preserve intentionally templated/custom values" behavior). The two
# cache keys are different: they are being fully retired in favor of one
# shared CACHE_DIR, so setup.sh update collapses them into CACHE_DIR and
# unconditionally removes them (remove_env_key) instead of preserving them
# as an optional override -- keeping them "preservable" would recreate the
# exact split-brain (two possible cache locations) this migration exists
# to eliminate.
for key in PDNS_STANDARD_DIR PDNS_SSL_DIR PDNS_FILTER_STATE_DIR NATS_DATA_DIR NATS_CONF_DIR; do
  grep -F "set_optional_env_path_override_if_needed ${key}" setup.sh >/dev/null \
    || { echo "::error::setup.sh update must preserve ${key} only when legacy/custom state would otherwise move away from the one-root contract."; exit 1; }
  grep -F "${key}" deploy/prod/.env >/dev/null \
    || { echo "::error::deploy/prod/.env must document ${key} for manual production upgrades."; exit 1; }
  grep -F "${key}" docs/backup-restore.md >/dev/null \
    || { echo "::error::backup docs must mention ${key}."; exit 1; }
done

grep -F 'LANCACHE_STATE_DIR=/opt/lancache-ng' deploy/prod/.env >/dev/null \
  || { echo "::error::deploy/prod/.env must expose one production state root for manual upgrade paths."; exit 1; }
grep -F 'set_env_key_if_empty_or_missing LANCACHE_STATE_DIR' setup.sh >/dev/null \
  || { echo "::error::setup.sh update must write LANCACHE_STATE_DIR before per-service state keys."; exit 1; }
grep -F 'production_state_root_default()' setup.sh >/dev/null \
  || { echo "::error::setup.sh must keep a state-root default helper for setup installs and manual deploy/prod updates."; exit 1; }
grep -F 'legacy_state_root_or_default()' setup.sh >/dev/null \
  || { echo "::error::setup.sh must only select legacy /srv/lancache when known child state still exists."; exit 1; }
grep -F 'basename "$(dirname "$install_dir")")" = "deploy"' setup.sh >/dev/null \
  || { echo "::error::setup.sh deploy/prod updates must default runtime state to /opt/lancache-ng, not the checkout."; exit 1; }
grep -F 'install_dir=$(realpath -m "$install_dir")' setup.sh >/dev/null \
  || { echo "::error::setup.sh update must normalize install_dir before cd so deploy/prod backups are path-stable."; exit 1; }
# Manual deploy/prod rollback snapshot:
# capture every repo-root input reached via ../../ and remap that
# snapshot to a different checkout path during restore.
grep -F 'deploy_prod_repo_input_paths()' setup.sh >/dev/null \
  || { echo "::error::deploy/prod backups must snapshot repo-root runtime inputs reached via ../../ paths."; exit 1; }
grep -F 'config/prod' setup.sh >/dev/null \
  && grep -F 'services/dns/cdn-domains.txt' setup.sh >/dev/null \
  || { echo "::error::deploy/prod backups must include repo-root config/prod env files and the domain list."; exit 1; }
grep -F 'scripts/docker-socket-proxy.sh' setup.sh >/dev/null \
  || { echo "::error::deploy/prod backups must include the repo-root scripts/docker-socket-proxy.sh bind-mount input (see docs/naming-conventions.md)."; exit 1; }
grep -F 'deploy_prod_repo_root "$archived_install"' setup.sh >/dev/null \
  && grep -F 'deploy_prod_repo_root "$install_dir"' setup.sh >/dev/null \
  || { echo "::error::deploy/prod restore must remap repo-root snapshot entries to the new checkout path."; exit 1; }
grep -F 'sudo ./setup.sh update "$(pwd)/deploy/prod"' README.md >/dev/null \
  || { echo "::error::README manual production updates must pass deploy/prod explicitly to setup.sh update."; exit 1; }
grep -F 'deploy/prod/.env.local' .gitignore >/dev/null \
  || { echo "::error::Manual deploy/prod runtime env must be ignored as deploy/prod/.env.local."; exit 1; }
grep -F 'runtime_env_file_for_install_dir()' setup.sh >/dev/null \
  && grep -F 'is_deploy_prod_install_dir "$install_dir"' setup.sh >/dev/null \
  && grep -F '$install_dir/.env.local' setup.sh >/dev/null \
  || { echo "::error::setup.sh must prefer deploy/prod/.env.local as the active manual prod runtime env when present."; exit 1; }
grep -F 'cp deploy/prod/.env deploy/prod/.env.local' README.md >/dev/null \
  && grep -F 'docker compose --env-file deploy/prod/.env.local -f deploy/prod/docker-compose.yml' README.md >/dev/null \
  || { echo "::error::README manual production flow must keep deploy/prod/.env as a clean template and run compose with deploy/prod/.env.local."; exit 1; }
if awk '
  /sudo \.\/setup\.sh backup --config "\$\(pwd\)\/deploy\/prod"/ { backup_seen=1 }
  /git pull --ff-only/ && !backup_seen { print FILENAME ":" FNR ":" $0; found=1 }
  END { exit found ? 0 : 1 }
' README.md; then
  echo "::error::README manual production updates must create a config backup before git pull changes tracked files."
  exit 1
fi
grep -F '${LANCACHE_STATE_DIR:-/opt/lancache-ng}/pdns-standard' deploy/prod/docker-compose.yml >/dev/null \
  || { echo "::error::prod compose must derive PowerDNS state from LANCACHE_STATE_DIR when no per-service override is set."; exit 1; }
grep -F '${LANCACHE_STATE_DIR:-/opt/lancache-ng}/nats-conf' deploy/prod/docker-compose.yml >/dev/null \
  || { echo "::error::prod compose must derive NATS config state from LANCACHE_STATE_DIR when no per-service override is set."; exit 1; }
grep -F 'LANCACHE_STATE_DIR' docs/backup-restore.md >/dev/null \
  || { echo "::error::backup docs must describe LANCACHE_STATE_DIR coverage."; exit 1; }
grep -F 'legacy_dir_or_default "$(legacy_state_path cache)"' setup.sh >/dev/null \
  || { echo "::error::setup.sh update must preserve an existing legacy /srv/lancache/cache before changing cache defaults."; exit 1; }
grep -F 'pdns_filter_state_dir=$(get_env_var PDNS_FILTER_STATE_DIR "$env_file")' setup.sh >/dev/null \
  || { echo "::error::backup_manifest must read PDNS_FILTER_STATE_DIR."; exit 1; }
grep -F 'nats_conf_dir=$(get_env_var NATS_CONF_DIR "$env_file")' setup.sh >/dev/null \
  || { echo "::error::backup_manifest must read NATS_CONF_DIR."; exit 1; }
VALIDATE_PREBUILT

