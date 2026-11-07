# LanCache-NG Architecture

LanCache-NG runs as exactly five containers. Every value comes from the
single source of truth `.github/yaml/build-manifest.yml` (SOT). Code,
Dockerfiles and compose files name keys, never values.

## Containers

| Container | Programs | Started by |
| --- | --- | --- |
| `services` | lancache-watchdog, lancache-cachehamster, syslog-ng, chronyd, snmpd | OpenRC |
| `proxy` | nginx | nginx is the main process (tini as PID 1) |
| `dns` | PowerDNS auth, recursor `dns-http`, recursor `dns-https` | OpenRC |
| `dhcp` | Kea (dhcp4, ctrl-agent, ddns) or dnsmasq | OpenRC, runlevel = `DHCP_MODE` |
| `ui` | lancache-ui | lancache-ui is the main process |

The program list of each image is the SOT field `processes`. Each row is
`[runlevel:]name=command,arg,...`. The Dockerfile turns every row into an
OpenRC script with `supervise-daemon`, so a crashed program restarts by
itself. `@KEY@` in a row is replaced by the SOT value at build time.

The `dhcp` container starts `openrc-init` with the runlevel named in
`DHCP_MODE_FILE`, which the ui writes from
`DHCP_MODE` (`off`, `kea`, `dnsmasq-proxy`, `dnsmasq-relay`). Each mode
starts only its own programs; `off` starts none.

## Who decides what

One owner per decision. No component undoes the work of another.

| Who | Does | Does not |
| --- | --- | --- |
| `shared.rs` | Building blocks: render configs, Docker calls, file tidy-up | Decide anything |
| ui | Saves settings, renders and writes every config, wakes the owner container, records user start/stop in `SERVICES_STOPPED` | Run check loops or cleanup |
| Watchdog | Decides *when*: health checks, restarts sick containers, daily cleanup, writes the alarm file | Write configs |
| OpenRC (inside a container) | Keeps the programs of its container alive | Touch other containers |
| Docker healthcheck | Tells Docker whether the programs really answer | Restart anything |

A container the user stopped in the ui is listed in `SERVICES_STOPPED`.
The watchdog never restarts a container on that list. This prevents the
loop "user stops, watchdog starts, user stops again".

## Failure handling

| Failure | Noticed by | Action |
| --- | --- | --- |
| A program inside a running container crashes | OpenRC `supervise-daemon` | Restart of that program |
| A program hangs or stops answering | Docker healthcheck turns `unhealthy` | Watchdog restarts the container after `RESTART_AFTER` failed checks |
| A container exits | Docker (`restart` policy) and the watchdog | Docker or the watchdog starts it again |
| Restarts keep failing | Watchdog | After `WATCHDOG_RESTART_LIMIT` restarts in `WATCHDOG_RESTART_WINDOW` only a critical alarm; the host is never rebooted |
| Zombie processes | `openrc-init` as PID 1 | Reaped |

Healthchecks:

| Container | Check |
| --- | --- |
| `services` | `lancache-watchdog healthcheck`: the alarm file is newer than `CHECK_INTERVAL × RESTART_AFTER` |
| `proxy` | HTTP request to `PROXY_HEALTH_PATH` |
| `dns` | DNS query for `SETUP_DNS_PROBE_NAME`; any reply counts, so a dead upstream does not restart DNS |
| `dhcp` | No crashed OpenRC service |
| `ui` | `lancache-ui healthcheck` |

## Configuration flow

1. The user saves a setting in the ui. The ui stores only the changed
   keys in `UI_SETTINGS_FILE` (`lancache-ui-settings.env` in the `ui-data`
   volume). Precedence per key: this file, then the container env, then the
   SOT default in `build-manifest.yml`.
2. The ui renders every config from the SOT and the saved settings
   (`render::all` in `shared.rs`) and writes changed files into the
   `lancache-config` volume under `CONFIG_DIR`.
3. The ui wakes only the owners with changes, with the strongest needed
   action (reload or restart, `apply::plan`).
4. The owner containers mount `lancache-config` read-only and start their
   programs with the SOT config paths.

The ui also renders once at start, because the volume starts empty.
nginx templates come from `services/ui/nginx` in the checkout (mounted into
the ui at `NGINX_TEMPLATE_DIR`); the rendered files go to `NGINX_CONF_DIR`.
Exception: `kea-dhcp4.conf` lives in `KEA_DATA_DIR`, which dhcp mounts
writable, because Kea `config-write` (ui edits, `setup.sh` rollback) saves it
in place.

## Watchdog duties

Each round (`CHECK_INTERVAL`) the watchdog:

- reads the health of every container and restarts sick ones (see above);
- checks free disk space of the cache (`DISK_WARN_PCT`, `DISK_ALARM_PCT`);
- checks certificate expiry;
- once a day purges old cache files, prunes and packs logs (xz);
- checks that syslog-ng still writes;
- writes `WATCHDOG_ALARM_FILE` for the ui dashboard.

## syslog-ng

Every container logs through Docker's `syslog` driver to syslog-ng in
`services` (`LANCACHE_LOG_PORT` on the loopback address). Files land in
`SYSLOG_NG_LOG_DIR/<program>/`. The ui reads them read-only. Logging can
be switched per service in the ui; the ui re-renders the syslog-ng config.

**Logging matrix** (one row per Compose service in `deploy/prod/docker-compose.yml`; `ci.sh check logging-matrix` enforces it):

| Service | Logging path | Store directory under `SYSLOG_NG_LOG_DIR` |
| --- | --- | --- |
| `services` | Docker `syslog` driver (`x-logging`) → syslog-ng in `services` | `LanCache-NG-services/` |
| `proxy` | Docker `syslog` driver (`x-logging`) → syslog-ng in `services` | `LanCache-NG-proxy/` |
| `dns` | Docker `syslog` driver (`x-logging`) → syslog-ng in `services` | `LanCache-NG-dns/` |
| `dhcp` | Docker `syslog` driver (`x-logging`) → syslog-ng in `services` | `LanCache-NG-dhcp/` |
| `ui` | Docker `syslog` driver (`x-logging`) → syslog-ng in `services` | `LanCache-NG-ui/` |

## Pre-caching

`lancache-cachehamster` runs in `services`. It logs in to Steam by QR
code, keeps a job queue (now, later, at a time) and downloads through the
proxy so the cache fills. The ui starts jobs through it.

## Howto audit this file

The audit procedure of this file is `docs/policy/howto-audit-documentation.md`.
