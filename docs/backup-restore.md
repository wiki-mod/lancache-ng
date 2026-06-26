# Backup, Restore, and Rollback

LanCache NG stores mutable state outside container images. Back up that state before upgrades, after configuration changes, and before enabling automatic updates.

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

The `update` command automatically creates this config backup before pulling repository changes or images. This protects users from failed automatic/manual updates without forcing them to archive hundreds of GiB or TiB of cache data.

### `--full` backup

Use this when moving to new hardware or when losing cached objects would be expensive. It includes everything from `--config` and additionally includes cache directories from `.env` plus `/srv/lancache/cache` when present. This can be huge, so it is opt-in.

## What the automated backup includes

The automated manifest includes these paths when they exist:

- install configuration: `.env`, `docker-compose.yml`, `certs/`, and an install-local `deploy/` directory
- PowerDNS state under `/srv/lancache/pdns-standard` and `/srv/lancache/pdns-ssl`
- Kea data from `KEA_DATA_DIR` and `/srv/lancache/kea`
- NATS state and generated config under `/srv/lancache/nats` and `/srv/lancache/nats-conf`
- in `--full` mode only, cache directories from `CACHE_DIR_STANDARD`, `CACHE_DIR_SSL`, and `/srv/lancache/cache`

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

If Watchtower caused the update, remove `watchtower` from `COMPOSE_PROFILES` in `.env` before starting again so the same image is not pulled immediately.

## Restore testing

Test restores periodically on a spare host or VM:

1. Restore the backup.
2. Start the stack.
3. Confirm DNS replies on port 53.
4. Confirm Admin UI access on port 8080.
5. Confirm HTTP cache traffic on port 80.
6. If SSL mode is enabled, confirm clients still trust the restored `ca.crt`.
7. If DHCP is enabled, confirm Kea leases/config are restored before enabling DHCP on a production network.

## Secret and CA handling

Backups contain secrets such as `.env`, `DDNS_TSIG_KEY`, `PDNS_API_KEY`, `NATS_LOCAL_TOKEN`, `SECONDARY_REGISTRATION_TOKEN`, optional Admin UI credentials, and possibly `certs/ca.key`. Store backups off-host and encrypt them when they leave the server.

Treat `certs/ca.key` as highly sensitive. Anyone with that private key can issue certificates trusted by SSL-mode clients. Distribute `ca.crt` to clients, but never distribute `ca.key`. If the CA key is exposed, generate a new CA, remove the old CA from clients, install the new `ca.crt`, and restart the proxy stack.

## Future improvements to consider

The current implementation uses timestamped tar archives because they are predictable, easy to inspect, and do not require a long-running backup service. Future PRs could add an optional text-file history layer similar to `etckeeper` for `.env`, compose files, and generated service config, but that should stay separate from cache backups so repository history never grows with cache payloads or secrets accidentally committed to a remote.
