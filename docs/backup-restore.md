# Backup, Restore, and Rollback

LanCache NG stores mutable state outside container images. Back up that state before upgrades, after configuration changes, and before enabling optional Watchtower helper updates.

For manual production checkouts, keep `deploy/prod/.env` as the checked-in
template and put real runtime settings in `deploy/prod/.env.local`. `setup.sh`
prefers that untracked file automatically for backup, update, restore, and
`update-ip` when it exists.

## Setup script commands

The setup script includes three backup-related flows:

```bash
sudo /opt/lancache-ng/setup.sh update [install-dir]
sudo /opt/lancache-ng/setup.sh backup [--config|--full] [install-dir] [--dest /backup/path]
sudo /opt/lancache-ng/setup.sh restore <backup.tar.gz> [install-dir]
```

The script verifies that required archive tools are present before running backup or restore. If `tar` or `rsync` is missing on an `apt-get` based system, the script installs the missing tool before it touches backup data. `restore` additionally requires `openssl`, since converging a legacy or incomplete `.env` (see "Restore also re-converges `.env`" below) can generate missing service secrets, which shells out to `openssl rand`.

## Why there are two backup modes

### `--config` backup, the default

Use this before updates and for rollback. It is intentionally small and includes configuration, certificates, secrets, and service runtime databases where present. It does **not** include cache payload directories because cache content can be very large and can usually be rebuilt by clients downloading content again.

The `update` command automatically creates this config backup before pulling repository changes or images. The backup records the currently running image revisions before `docker compose pull` so operators have the information needed to roll back an image regression. This protects users from failed automatic/manual updates without forcing them to archive hundreds of GiB or TiB of cache data.

### `--full` backup

Use this when moving to new hardware or when losing cached objects would be expensive. It includes everything from `--config` and additionally includes the cache directory from `CACHE_DIR` (or the production state root `LANCACHE_STATE_DIR`), plus any legacy split cache directories and `/srv/lancache/cache` still present on older installs. This can be huge, so it is opt-in.

## What the automated backup includes

The automated manifest includes these paths when they exist:

- install configuration: the active runtime env file (`.env` or `deploy/prod/.env.local`), `docker-compose.yml`, and `certs/`; manual `deploy/prod` backups also include the repository-root runtime inputs reached via `../../` (`certs/`, `config/prod/`, `services/dns/cdn-domains.txt`, and `scripts/docker-socket-proxy.sh`) because production compose mounts or reads those tracked files outside `deploy/prod/`
- quickstart Docker named volumes discovered from the compose project, including stopped containers so PowerDNS and NATS volumes are included
- an `image-revisions.txt` file with the image revisions present before an update pulls new tags
- PowerDNS state from Docker named volumes, the production state root `LANCACHE_STATE_DIR`, optional `PDNS_STANDARD_DIR`, `PDNS_SSL_DIR`, `PDNS_FILTER_STATE_DIR`, and legacy `/srv/lancache/pdns-standard`, `/srv/lancache/pdns-ssl`, `/srv/lancache/pdns-filter-state` when present
- Kea data from the production state root `LANCACHE_STATE_DIR`, optional `KEA_DATA_DIR`, and legacy `/srv/lancache/kea` when present
- NATS state and generated config from Docker named volumes, the production state root `LANCACHE_STATE_DIR`, optional `NATS_DATA_DIR`, `NATS_CONF_DIR`, and legacy `/srv/lancache/nats`, `/srv/lancache/nats-conf` when present
- in `--full` mode only, the cache directory from `CACHE_DIR` (or the production state root `LANCACHE_STATE_DIR`), plus legacy split cache directories (`CACHE_DIR_STANDARD`, `CACHE_DIR_SSL`) and `/srv/lancache/cache` when present

The optional central logging path (`SYSLOG_NG_LOG_DIR`, or the production state root `LANCACHE_STATE_DIR/syslog-ng`; see #453) is **not** part of the automated backup manifest yet. Like cache content, it is rotated/compressed application output rather than configuration or operational state, so losing it does not affect the running stack. Back it up manually if you need log retention across a host migration.

The backup command stops the compose stack before copying mutable databases and restarts it afterward. Staging directories are created with restrictive permissions and cleaned up automatically if a copy or archive operation fails. The command rejects backup destinations that sit inside a path being backed up, which prevents recursive copies when using cache disks as backup storage.

## Example rollback after a failed update

1. Find the automatic pre-update backup:

   ```bash
   sudo find /var/backups/lancache-ng -maxdepth 1 -name 'lancache-ng-config-*.tar.gz' -print
   ```

2. Restore the selected backup:

   ```bash
   sudo /opt/lancache-ng/setup.sh restore /var/backups/lancache-ng/lancache-ng-config-YYYYMMDDTHHMMSSZ.tar.gz /opt/lancache-ng
   ```

3. Check the stack:

   ```bash
   cd /opt/lancache-ng
   sudo docker compose ps
   ```

If Watchtower changed an optional helper image, remove `watchtower` from `COMPOSE_PROFILES` in `.env` before starting again so the same helper image is not pulled immediately. If the failure was caused by a bad first-party image, `restore`'s `.env` convergence step (see "Restore also re-converges `.env`" below) already keeps the backup's own `LANCACHE_IMAGE_TAG` instead of re-resolving it, so restoring the automatic pre-update backup restarts the stack on the previous known-good tag automatically. To roll back to a *different* revision than the one in that backup, inspect `image-revisions.txt` inside the restored archive and set `LANCACHE_IMAGE_TAG` in `.env` to the desired `sha-*`, release candidate, or stable release tag, then run `setup.sh update [install-dir]` to apply it.

## Restore also re-converges `.env`

`restore` restores exactly what a backup archive captured, including whatever
shape `.env` had at backup time. A backup taken from an older install can
therefore carry legacy keys (split `CACHE_DIR_STANDARD`/`CACHE_DIR_SSL`, a
stale `PROXY_SECURITY_MODE=strict` with no allowlist), a placeholder secret,
or keys a later release added that the archived install never had. After
restoring files and Docker volumes, `restore` refreshes the quickstart
compose/scripts bundle (the same refresh `update` performs, so a legacy
archived compose file that still references removed keys like
`CACHE_DIR_STANDARD` never gets validated against a `.env` that no longer has
them; skipped for a `deploy/prod` Git checkout target, whose compose file is
managed by the checkout itself) and then runs the same `.env` convergence
path `update` uses (`migrate_env_for_update`, then `validate_compose_config`)
before starting the stack, so a legacy or incomplete backup converges to the
current expected `.env` shape automatically. Restoring a backup that is
already fully converged is a no-op: convergence never rewrites values that
already match the current expected shape, so it does not require and no
longer relies on running `setup.sh update` by hand afterward.

Unlike `update`, this convergence pass keeps an already-valid
`LANCACHE_IMAGE_TAG` (an immutable `sha-*` or `vX.Y.Z` value) exactly as
restored instead of re-resolving it against the current
`LANCACHE_IMAGE_CHANNEL` pointer. Restoring a backup is commonly a rollback
after a bad channel-tracked (`edge`/`latest`) image; re-resolving the channel
during that restore would silently pull whatever the channel currently
points to, which right after a bad release is often still the same bad tag.
`update` does not have this exception because re-resolving the channel on
every update is how a channel-tracking install picks up new images at all.

If the backup contains Docker volume payloads, Docker must be available to
restore them (see "What the automated backup includes" above). Compose
validation and the stack start step are skipped, with a warning, when
Docker/compose is not available for the target install directory -- this
keeps the config-only restore path usable on a minimal host with no Docker,
matching how `backup` and `restore_compose_volumes` already treat Docker as
optional for a config-only archive. `.env` is still fully converged in that
case; only the Docker-dependent validate-and-start step is skipped.

If convergence or validation fails after a restore (for example, an
unresolvable legacy value, or a compose configuration that fails to validate),
`restore` fails closed: it reports the error, leaves the restored files and
Docker volumes on disk exactly as restored, and leaves the stack **stopped**
instead of starting it against an unconverged or invalid configuration. Fix
the reported problem in `.env`, then run `setup.sh update [install-dir]` to
finish converging and start the stack.

## Restore testing

Test restores periodically on a spare host or VM:

1. Restore the backup to the target install directory. Install files from the archived install path are remapped to the `[install-dir]` argument instead of always being written back to the original path, and matching absolute install-path references in the restored active runtime env file are rewritten for migrations. Backups created from `deploy/prod` also remap the archived repository-root runtime inputs to the new checkout root instead of restoring them to stale absolute paths. If the backup contains Docker named volumes, Docker and the compose project must be available during restore so those volumes can be loaded instead of silently skipped. `restore` then converges `.env` and validates the compose configuration itself (see "Restore also re-converges `.env`" above) and starts the stack as its last step, so no separate manual update pass is required.
2. Confirm the stack is running (`restore` starts it automatically after a successful convergence; if it reports a convergence/validation failure, the stack is intentionally left stopped -- fix `.env`, then run `setup.sh update [install-dir]`).
3. Confirm DNS replies on port 53.
4. Confirm Admin UI access on port 8080.
5. Confirm HTTP cache traffic on port 80.
6. If SSL mode is enabled, confirm clients still trust the restored `ca.crt`.
7. If DHCP is enabled, confirm Kea leases/config are restored before enabling DHCP on a production network.

## Secret and CA handling

Backups contain secrets such as `.env`, `DDNS_TSIG_KEY`, `PDNS_API_KEY`, `NATS_UI_PASSWORD`, `NATS_DNS_WRITER_PASSWORD`, `NATS_DNS_REPLICA_PASSWORD`, `NATS_CALLOUT_PASSWORD`, the auth-callout issuer NKey seed file (`NATS_ISSUER_SEED_PATH`, default `/data/lancache-nats-issuer.seed` inside the Admin UI's data volume), `SECONDARY_REGISTRATION_TOKEN`, optional Admin UI credentials, and possibly `certs/ca.key`. Store backups off-host and encrypt them when they leave the server. Losing the issuer seed is self-healing, not a durability risk: the Admin UI generates a fresh one on next start and rewrites `nats.conf`'s `auth_callout.issuer` to match before accepting any connections, so already-registered secondaries keep working unchanged (their credential is verified against the `secondaries` table, not tied to any particular issuer key).

Treat `certs/ca.key` as highly sensitive. Anyone with that private key can issue certificates trusted by SSL-mode clients. Distribute `ca.crt` to clients, but never distribute `ca.key`. If the CA key is exposed, generate a new CA, remove the old CA from clients, install the new `ca.crt`, and restart the proxy stack.

## Future improvements to consider

The current implementation uses timestamped tar archives because they are predictable, easy to inspect, and do not require a long-running backup service. Future PRs could add an optional text-file history layer similar to `etckeeper` for `.env`, compose files, and generated service config, but that should stay separate from cache backups so repository history never grows with cache payloads or secrets accidentally committed to a remote.

Since this document was written, a small piece of that idea landed for individual services: see [known-good-config-snapshots.md](known-good-config-snapshots.md) for the automatic, per-service known-good configuration snapshot mechanism (nginx, dnsmasq, Kea DHCP, and PowerDNS's static `pdns.conf`/`recursor.conf` today; Kea's is operator-selected from the Admin UI rather than automatic, since it has no container-startup moment to trigger from). It is deliberately separate from this backup/restore contract — it is not a replacement, does not cover the whole install, and its snapshot volumes are not part of the automated backup manifest above. PowerDNS's zone/record database (`pdns.sqlite3`) *is* included in the automated backup above (it lives under the PowerDNS state paths listed in "What the automated backup includes"), but the known-good-config-snapshot mechanism itself only snapshots the static `pdns.conf`/`recursor.conf` files, never the live SQLite database; see known-good-config-snapshots.md's "Zones, records, and TSIG/DDNS metadata" section for the scoped design of a lightweight per-zone snapshot/rollback mechanism (issue #628) and why a blind file-level snapshot of that database would be unsafe in the meantime.
