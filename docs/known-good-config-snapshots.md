# Known-Good Configuration Snapshots

Every rendered service config that a program can check before it starts is
kept as a known-good snapshot once the check passes. A later render that fails
its check runs from the newest snapshot that still passes, so one bad setting
does not take a service down. Kea's DHCP config and the PowerDNS zone data are
snapshotted the same way; rolling those back is chosen by the operator.

This mechanism is separate from the install backup in
[backup-restore.md](backup-restore.md). It keeps a few recent configs per
service, not the whole install.

## Contract

1. **One store.** `SnapshotStore` in `services/common/shared.rs` owns the
   format for every service:
   - A snapshot is a directory named by a 20-digit id (nanoseconds since the
     Unix epoch), so name order is time order. It holds one JSON payload file.
   - `create` writes into a `.staging.<id>` directory and renames it; a crash
     never leaves a half-written snapshot. `ids` lists only numeric directories
     that hold the payload file.
   - `read` accepts only numeric ids; the id joins onto a path, so nothing
     else passes.
   - `prune` keeps the newest `KEEP_KNOWN_GOOD_CONFIGS` snapshots and refuses
     0, which would delete every snapshot.
   - `adopt_legacy` converts snapshots in the old shell format (directory name
     `YYYYmmddTHHMMSS.N`, one file per config) into the new format, so an
     update keeps its rollback targets.
2. **Retention.** `KEEP_KNOWN_GOOD_CONFIGS` (SOT
   `.github/yaml/build-manifest.yml`, read by
   `config::keep_known_good`, at least 1) applies to every store.
3. **Places.** All paths are SOT values:

   | Service | Program | Store (`DIR`/`FILE` keys) | Compose volume |
   |---|---|---|---|
   | `proxy` | nginx | `PROXY_CONFIG_SNAPSHOT_DIR`, `PROXY_CONFIG_SNAPSHOT_FILE` | `proxy-config-snapshots` |
   | `dhcp` | dnsmasq | `DHCP_CONFIG_SNAPSHOT_DIR`, `DHCP_CONFIG_SNAPSHOT_FILE` | `dhcp-config-snapshots` |
   | `dhcp` and `ui` | Kea | `KEA_CONFIG_SNAPSHOT_DIR`, `KEA_CONFIG_SNAPSHOT_FILE` | the `KEA_DATA_DIR` bind mount |
   | `dns` | pdns (authoritative) | `DNS_CONFIG_SNAPSHOT_DIR`/`auth`, `DNS_AUTH_CONFIG_SNAPSHOT_FILE` | `dns-config-snapshots` |
   | `dns` | dns-http, dns-https (recursors) | `DNS_CONFIG_SNAPSHOT_DIR`/`<recursor>`, `DNS_RECURSOR_CONFIG_SNAPSHOT_FILE` | `dns-config-snapshots` |
   | `dns` | nats-subscriber (zone data) | `DNS_CONFIG_SNAPSHOT_DIR`/`zones`/`<zone>`, `DNS_ZONE_SNAPSHOT_FILE` | `dns-config-snapshots` |

   A secondary DNS node (`deploy/secondary/docker-compose.yml`) has its own
   `dns-config-snapshots` volume.
4. **Log lines.** The store logs
   `[known-good-snapshot][<service>][<LEVEL>] <message>` on stderr, with the
   levels `CREATE`, `PRUNE`, `ADOPT`, `SELECT`, `REJECT`, `WARNING` and
   `FATAL`. `<service>` is `proxy`, `dhcp-proxy`, `kea`, `dns-auth`,
   `dns-recursor` or `dns`.

## Startup adapters (nginx, dnsmasq, PowerDNS, Kea)

The supervisor (`lancache-watchdog supervise`, `services/watchdog/src/main.rs`)
renders each program's config right before it starts it. `checked_files` and
`first_good` decide which config the program gets:

1. The new render is written and checked. If it passes, it is saved as a new
   snapshot and the program starts on it.
2. If it fails, each stored snapshot is written and checked, newest first. The
   first one that passes is used, and the log shows
   `WARNING: <files> runs from known-good snapshot <id>, not the new render`.
   Values that belong to this start (the PowerDNS `local-address=` and
   `api-key=` lines, the recursor `api_key:` line) are written into the
   restored file by `restamp_lines`.
3. If none passes, the program does not start. The supervisor logs
   `ERROR: <program>: <files> fails its check and no known-good snapshot passes; next start in <n>s`
   and retries with a growing delay. The program shows as down in
   `supervise.json`, so the container healthcheck fails.

A render that skipped input rows (the nginx render with skipped CDN domain
rows) still starts but is not saved:
`WARNING: <files> has skipped input rows; not saved as known-good`.

| Program | Function | Check |
|---|---|---|
| nginx | `nginx` | `nginx -t -c <conf>` |
| dnsmasq | `dnsmasq` | `dnsmasq --test -C <run dir>/dnsmasq.conf` |
| pdns | `pdns_auth` | `pdns_check("pdns_server", ...)` |
| dns-http, dns-https | `recursor` | `pdns_check("pdns_recursor", ...)` |
| kea-dhcp4 | `kea_dhcp4` | `kea-dhcp4 -t <KEA_DATA_DIR>/kea-dhcp4.conf` |

For nginx, a snapshot from before PR #1912 lacks the files that render added
later; `legacy_backfill` fills them from the current render and renames the old
map file `00-ssl-map.conf`.

For Kea the start candidate is the `kea-dhcp4.conf` on disk, which the Admin UI
writes, not a new render. If it fails its check, kea-dhcp4 starts from the
newest snapshot that passes and logs
`WARNING: kea-dhcp4 runs from known-good snapshot <id>, not its last config`.
The supervisor does not save Kea snapshots; the Admin UI does (next section).

## Kea: operator rollback

The Admin UI changes Kea through `kea_apply` in `services/ui/src/main.rs`:
`config-get`, edit, `config-test`, `config-set`, `config-write`, all under one
lock. After `config-write` succeeds, the applied config is saved as a Kea
snapshot. If `config-write` fails, the old config is set again and the change
is refused. A failed snapshot write is logged as a warning and does not undo
the change.

The DHCP page lists the Kea snapshots newest first.
`POST /dhcp/snapshot/rollback` (`rollback_kea_snapshot`) accepts only an id
that is in the store's list, reads it, and applies it through the same
`kea_apply` chain. The result is logged as `SELECT` or `REJECT`.

## Zones, records, and TSIG/DDNS metadata

`nats-subscriber` (`services/dns/nats-subscriber/src/main.rs`) snapshots the
record data of the zones `config::rollback_zones` names: the lan zone
(`DHCP_DOMAIN`), its `local.` zone, the private IPv4 reverse zones and
`c.f.ip6.arpa.`/`d.f.ip6.arpa.`. Other zones, such as the RPZ, are never
snapshotted or rolled back. TSIG keys and zone metadata are not part of a
snapshot.

**When a snapshot is taken.** `snapshot_zone` runs after every record write
that PowerDNS accepted and notified, and `snapshot_watcher` runs it for every
managed zone every `DNS_SYNC_TICK` seconds on every node. The watcher also
catches DDNS writes from Kea, which do not pass through NATS. SOA and NS
rrsets are left out (`data_rrsets`). A snapshot is only written when the zone
differs from the newest one (`matches_latest`, which compares sorted rrsets and
sorted records), so periodic republishes do not push out real history. A
failed export or write is logged as `FATAL` and never stops the record write
that triggered it.

**Rollback listener.** `serve_rollback` listens on `DNS_ROLLBACK_LISTEN_ADDR`
(port `DNS_ROLLBACK_PORT`, SOT). It binds all addresses because the Admin UI
runs in another container; the port is not published to the host. Every
request needs the `X-API-Key` header equal to `PDNS_API_KEY` (constant-time
compare) before the body is read.

| Route | Answer |
|---|---|
| `GET /snapshots` | `{"zones": {<zone>: [{"id", "created_unix"}, ...]}}`, newest first; a store that cannot be listed fails the request |
| `POST /rollback` with `{"zone", "snapshot_id"}` | the result fields below |

**What a rollback does** (`rollback`):

1. Refuses a zone outside `rollback_zones` and an id that is not in the list.
2. Takes the zone lock, reads the current rrsets and builds a PATCH with
   `REPLACE` for every snapshot rrset that differs and `DELETE` for every
   current rrset the snapshot lacks (`rollback_patch`).
3. Sends the PATCH to PowerDNS. A refusal is logged as `REJECT` and returned.
4. Runs `pdnsutil check-zone` within `PDNS_ZONE_CHECK_TIMEOUT`. A failure is
   logged; the applied PATCH is not reverted.
5. For the lan zone, republishes every changed rrset on `lancache.dns.record`
   with a fresh id `rollback-<time>-<name>-<type>`, so secondaries converge
   now and the duplicate window cannot drop it (`publish_patch`).
6. Publishes one `lancache.dns.flush` per changed name, all at once, each
   within `DNS_FLUSH_TIMEOUT`, so every recursor drops its cached answer.
7. Saves the restored state as a new snapshot if it differs from the newest.

The answer holds `applied`, `changed_names`, `zone_check_passed`,
`republished_to_nats`, `flush_ok` and `flush_failed_names`. The Admin UI's
domains page lists the snapshots per zone (`fetch_zone_groups`) and forwards a
choice through `POST /domains/zones/rollback` (`rollback_zone_snapshot`); it
logs an error when `flush_ok` or `zone_check_passed` is false.

**NATS permission dependency (#906, #867).** The republish and the flush only
work if the dns writer identity may publish `lancache.dns.record` and
`lancache.dns.flush`. `config.rs` generates that allow-list
(`writer_publish`, from `NATS_SUBJECT_RECORD` and `NATS_SUBJECT_FLUSH`). A
missing permission shows as a missing JetStream ack: `republished_to_nats`
false or names in `flush_failed_names`.

**Replication limits.** Only the lan zone is replicated through NATS. The
`local.` zone and the reverse zones exist only on the primary, so a rollback
there changes only the primary.

A zone rollback is never automatic: an older zone can undo leases and host
names created since, and no check can judge that.

## Incident Runbooks

All commands run from the install directory (default `/opt/lancache-ng`),
where `docker compose` finds the stack.

### A rendered config fails its check

**Signs:** a `WARNING: ... runs from known-good snapshot ...` line, or an
`ERROR: <program>: ... fails its check and no known-good snapshot passes`
line, and the container shows `unhealthy`.

1. Read the cause:
   `docker compose logs <service> | grep -e 'known-good' -e 'ERROR' -e 'WARNING'`.
   Each failed check logs `ERROR: config check failed: <output>` with the
   check program's own message.
2. Fix the setting in the Admin UI or in `.env.local`, then restart the
   container: `docker compose restart <service>`.
3. A start that passes logs `[known-good-snapshot][<service>][CREATE]`.

While the service runs from a snapshot, it runs on the older settings. A
later render that passes replaces that state.

### Kea runs on a wrong config

1. In the Admin UI DHCP page, pick an older snapshot and roll back.
2. If the Admin UI is not reachable:
   `./setup.sh reset-to-last-known-good-config kea [install-dir] [snapshot-id] [--yes]`.

### A zone holds wrong records

1. In the Admin UI domains page, pick the zone's snapshot and roll back.
2. If the Admin UI is not reachable but the `dns` container runs:
   `./setup.sh reset-to-last-known-good-config dns [install-dir] <zone> [snapshot-id] [--yes]`.
   Without `<zone>` it lists the zones that have snapshots.

## Manual recovery and exhaustion

`./setup.sh reset-to-last-known-good-config` is the CLI fallback when the
Admin UI is not reachable. `dhcp` is an alias of `kea`, `pdns` an alias of
`dns`. Without a snapshot id it offers the newest after a confirmation;
`--yes` skips the prompt.

- **kea:** lists the snapshots under `KEA_CONFIG_SNAPSHOT_DIR` on the host and
  applies the chosen one through the Kea Control Agent (`config-test`,
  `config-set`, `config-write`), the same sequence the Admin UI uses.
- **dns:** runs `curl` inside the `dns` container against the rollback
  listener (`GET /snapshots`, `POST /rollback`), because its port is not
  published to the host.

**Exhaustion.** When no snapshot passes (fresh install, or a program upgrade
that rejects every stored config), the program stays down and the supervisor
retries. Fix the setting that breaks the render; the next start that passes
saves a new snapshot. The stores are plain files and can be listed without a
running program:

```bash
docker compose run --rm --no-deps --entrypoint sh proxy -c 'ls -la "$(lancache-watchdog get PROXY_CONFIG_SNAPSHOT_DIR)"'
docker compose run --rm --no-deps --entrypoint sh dhcp -c 'ls -la "$(lancache-watchdog get DHCP_CONFIG_SNAPSHOT_DIR)"'
docker compose run --rm --no-deps --entrypoint sh dns -c 'ls -laR "$(lancache-watchdog get DNS_CONFIG_SNAPSHOT_DIR)"'
docker compose run --rm --no-deps --entrypoint sh dhcp -c 'ls -la "$(lancache-watchdog get KEA_CONFIG_SNAPSHOT_DIR)"'
```

`lancache-watchdog get <KEY>` prints the SOT value inside the container.

Kea has no exhaustion state of its own: a failed rollback leaves
`kea-dhcp4.conf` untouched, and a failed check at start falls back as above.
