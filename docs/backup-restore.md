# Backup, Restore, and Rollback

LanCache NG stores mutable state outside container images. Back up that state before upgrades, after configuration changes, and before enabling optional Watchtower helper updates.

## Setup script commands

The setup script includes three backup-related flows:

```bash
sudo /opt/lancache-ng/setup.sh update [install-dir]
sudo /opt/lancache-ng/setup.sh backup [--config|--full] [install-dir] [--dest /backup/path]
sudo /opt/lancache-ng/setup.sh restore <backup.tar.gz> [install-dir]
```

The script verifies that required archive tools are present before running backup or restore. If `tar` or `rsync` is missing on an `apt-get` based system, the script installs the missing tool before it touches backup data.

## Why there are two backup modes

### `--config` backup, the default

Use this before updates and for rollback. It is intentionally small and includes configuration, certificates, secrets, and service runtime databases where present. It does **not** include cache payload directories because cache content can be very large and can usually be rebuilt by clients downloading content again.

The `update` command automatically creates this config backup before pulling repository changes or images. The backup records the currently running image revisions before `docker compose pull` so operators have the information needed to roll back an image regression. This protects users from failed automatic/manual updates without forcing them to archive hundreds of GiB or TiB of cache data.

### `--full` backup

Use this when moving to new hardware or when losing cached objects would be expensive. It includes everything from `--config` and additionally includes cache directories from `.env`. Older installs that still have legacy `/srv/lancache` directories are included when present, but new installs should not create `/srv/lancache`. This can be huge, so it is opt-in.

## What the automated backup includes

The automated manifest includes these paths when they exist:

- install configuration: `.env`, `docker-compose.yml`, and `certs/`; manual
  `deploy/prod` backups also include the repository-root `certs/` directory
  because production compose mounts that CA directory via `../../certs`
- quickstart Docker named volumes discovered from the compose project, including stopped containers so PowerDNS and NATS volumes are included
- an `image-revisions.txt` file with the image revisions present before an update pulls new tags
- PowerDNS state from Docker named volumes, the production state root `LANCACHE_STATE_DIR`, `PDNS_STANDARD_DIR`, `PDNS_SSL_DIR`, `PDNS_FILTER_STATE_DIR`, and, for legacy installs only, `/srv/lancache/pdns-standard`, `/srv/lancache/pdns-ssl`, and `/srv/lancache/pdns-filter-state` when present
- Kea data from the production state root `LANCACHE_STATE_DIR`, `KEA_DATA_DIR`, and, for legacy installs only, `/srv/lancache/kea` when present
- NATS state and generated config from Docker named volumes, the production state root `LANCACHE_STATE_DIR`, `NATS_DATA_DIR`, `NATS_CONF_DIR`, and, for legacy installs only, `/srv/lancache/nats` and `/srv/lancache/nats-conf` when present
- in `--full` mode only, cache directories from the production state root `LANCACHE_STATE_DIR`, `CACHE_DIR_STANDARD`, `CACHE_DIR_SSL`, and legacy `/srv/lancache/cache` when present

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

If Watchtower changed an optional helper image, remove `watchtower` from `COMPOSE_PROFILES` in `.env` before starting again so the same helper image is not pulled immediately. If the failure was caused by a bad first-party image, inspect the restored backup's `image-revisions.txt` and pin `LANCACHE_IMAGE_TAG` to the previous `sha-*`, release candidate, or stable release tag before restarting the affected service.

## Restore testing

Test restores periodically on a spare host or VM:

1. Restore the backup to the target install directory. Install files from the archived install path are remapped to the `[install-dir]` argument instead of always being written back to the original path, and matching absolute install-path references in the restored `.env` are rewritten for migrations. If the backup contains Docker named volumes, Docker and the compose project must be available during restore so those volumes can be loaded instead of silently skipped.
2. Start the stack.
3. Confirm DNS replies on port 53.
4. Confirm Admin UI access on port 8080.
5. Confirm HTTP cache traffic on port 80.
6. If SSL mode is enabled, confirm clients still trust the restored `ca.crt`.
7. If DHCP is enabled, confirm Kea leases/config are restored before enabling DHCP on a production network.

## Secret and CA handling

Backups contain secrets such as `.env`, `DDNS_TSIG_KEY`, `PDNS_API_KEY`, `NATS_UI_PASSWORD`, `NATS_DNS_WRITER_PASSWORD`, `NATS_DNS_READER_PASSWORD`, `SECONDARY_REGISTRATION_TOKEN`, optional Admin UI credentials, and possibly `certs/ca.key`. Store backups off-host and encrypt them when they leave the server.

Treat `certs/ca.key` as highly sensitive. Anyone with that private key can issue certificates trusted by SSL-mode clients. Distribute `ca.crt` to clients, but never distribute `ca.key`. If the CA key is exposed, generate a new CA, remove the old CA from clients, install the new `ca.crt`, and restart the proxy stack.

## Future improvements to consider

The current implementation uses timestamped tar archives because they are predictable, easy to inspect, and do not require a long-running backup service. Future PRs could add an optional text-file history layer similar to `etckeeper` for `.env`, compose files, and generated service config, but that should stay separate from cache backups so repository history never grows with cache payloads or secrets accidentally committed to a remote.
