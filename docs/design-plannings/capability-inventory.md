# LanCache-NG Capability Inventory

Reviewed against `cld/monolith` (PR #2020) at `3faea81591571740ed4430c4e5505a9917c7c1a2`.

This document lists what LanCache-NG can do. Every capability names the code
that provides it (file, function, SOT key or route). The statements come from
reading that code; no running stack was used. A capability that no check
covers is described from the code only (see "Validation").

Component facts that are not capabilities (container layout, ownership of
decisions, failure handling) are in `docs/architecture-ng.md`. Security
properties are in `docs/threat-model.md`.

## Components

| Component | Provides | Program (container) |
| --- | --- | --- |
| Proxy | HTTP cache, HTTPS-mode TLS termination, SNI passthrough | nginx (`proxy`) |
| DNS | Cache routing (RPZ), authoritative LAN zones, upstream forwarding, replication | PowerDNS auth and two recursors (`dns`) |
| DHCP | DHCPv4 server with DDNS, ProxyDHCP and PXE, DHCP relay | Kea or dnsmasq, by `DHCP_MODE` (`dhcp`) |
| Admin UI | Settings, config rendering, container actions, status and statistics | `lancache-ng ui` (`ui`) |
| Watchdog | Container health and restart, disk, certificate and log duties | `lancache-ng watchdog` (`services`) |
| Logging | Central log store and forwarding | syslog-ng (`services`) |
| NTP | LAN time server | chronyd (`services`) |
| SNMP | Host and container figures | snmpd (`services`, `dns`) |
| CacheHamster | Steam cache prefill | `lancache-ng cachehamster` (`services`) |
| setup.sh | Install, update, backup, restore, secondary setup | Bash (host) |

The program list of each container is the SOT field `processes` in
`.github/yaml/build-manifest.yml`. All own programs are the one binary
`lancache-ng` built from `services/lancache-ng/src/lancache-ng.rs`; the first
argument (or the program name `lancache-<role>`) picks the role (`ui`,
`watchdog`, `dns`, `cachehamster`) or a command group (`dhcp`, `config`,
`system`, `proxy`, `ntp`, `secret`, `cache`, `cdn`, `stats`, `logs`).
`lancache-ng help` lists them, `lancache-ng <name> help` the commands of one.

## Proxy

Provided by `services/ui/nginx/*` templates and the generator `nginx_conf` in
`services/lancache-ng/src/lancache-ng.rs` (`mod shared`).

- **HTTP cache.** `conf.d/http.conf` listens on `PROXY_HTTP_PORT` and sends
  requests through `proxy-params.conf`: cache `lancache`, key
  `$host$uri$slice_range`, slice size `CACHE_SLICE_SIZE`, `proxy_cache_lock on`,
  hit and other validity from `CACHE_VALID_HIT` and `CACHE_VALID_ANY`, stale
  answers on error, timeout and HTTP 500, 502, 503 and 504.
- **Upstream.** `proxy_pass $scheme://$host$request_uri` takes the destination
  from the client request; HTTPS origins use `proxy_ssl_verify on` with the
  system CA bundle; names resolve through `NGINX_UPSTREAM_RESOLVER`.
- **HTTPS mode.** With `HTTPS_ENABLED`, `conf.d/https.conf` terminates TLS with
  one generated certificate per host (`$https_cert_name`), using
  `NGINX_SSL_PROTOCOLS`, `NGINX_SSL_CIPHERS` and the session settings from the
  SOT. The stream block dispatches by SNI to the relays that
  `nginx_conf::files` generates (`stream_backend`, `https_dispatch_backend`).
- **SNI passthrough.** Names that are not terminated are forwarded by
  `ssl_preread` without a local certificate.
- **Domain list.** `cdn::effective` merges the shipped list
  (`services/dns/cdn-domains.txt`) with the rows the Admin UI enables or
  disables. A leading dot means the whole subtree (`dns::cdn_entry`). Registrable
  roots come from the Public Suffix List (`nginx_conf::Psl`).
- **Request policy.** `PROXY_SECURITY_MODE` selects `lazy` or `strict`
  (`$cdn_host_allowed`); `PROXY_ALLOWED_CLIENT_CIDRS` limits clients
  (`$lancache_client_allowed`, and `allow` / `deny all` in the stream block).
- **Certificates.** `cert::create_ca` creates the CA (`CA_KEY_TYPE`, `CA_DAYS`,
  `CA_KEY_MODE`); `cert::create_leaf` signs one leaf per host;
  `render::issue_certs` issues the planned set; `cert::expiry` reads the
  end once and `cert::state` reports the days left and whether to renew.
- **Endpoints.** `PROXY_HEALTH_PATH` serves the health file and
  `PROXY_STATUS_PATH` serves `stub_status`, both only to loopback and the Docker
  network; a request with an IP literal as host is redirected to the Admin UI.
- **Access log.** `log_format cache` writes to stdout; `access::parse` and
  `access::stats` read the stored files for the Admin UI.

## DNS

Provided by `pdns_conf`, `recursor_conf`, `pdns`, `dns` and `snapshot` in
`services/lancache-ng/src/lancache-ng.rs` (`mod shared`).

- **Cache routing.** `recursor_conf::rpz` builds the RPZ zone that answers every
  cache domain; `recursor_conf::lua` loads it and sets no-DNSSEC-check entries
  for local and listed private zones.
- **LAN domains.** `dns::lan_domains` owns the list: `DHCP_DOMAIN` first, then
  `DNS_EXTRA_LAN_DOMAINS`; `dns::managed_zones` makes one zone per LAN domain.
  The Admin UI adds, removes and promotes domains (routes
  `/domains/lan-domain-*`) and edits the records of each.
- **Recursors.** `dns-http` and `dns-https` run with the configs
  `recursor_conf::yaml` renders; LAN zones go to the authoritative server.
  With `ROOT_ZONE_MIRROR` on and no upstream for `.`, the recursors keep a
  copy of the root zone from `ROOT_ZONE_MIRROR_URL` (refresh and retry from
  `ROOT_ZONE_MIRROR_REFRESH`, `ROOT_ZONE_MIRROR_RETRY`).
- **Upstream forwarding.** `DNS_UPSTREAM_SERVERS`, `DNS_UPSTREAM_ZONES` and
  `DNS_UPSTREAM_UNSIGNED_ZONES` render forward entries; a local zone never goes
  out and the stack's own address is refused (`recursor_conf`).
- **AAAA filter.** `recursor_conf::AAAA_FILTER_LUA` returns empty AAAA answers
  when the filter is on (route `/domains/aaaa-filter`).
- **Query log.** The Admin UI switches the recursor query log
  (route `/domains/query-log`).
- **Authoritative server.** `pdns_conf::auth` renders `pdns.conf`: primary or
  secondary role (`DNS_REPLICATION_ROLE`), NOTIFY to registered secondaries
  (`pdns_conf::secondary_ips`), AXFR by TSIG, dynamic updates on the primary,
  and the API settings.
- **Zone management.** `pdns::Api` patches and replaces rrsets, creates primary
  and secondary zones, creates TSIG keys, sets zone metadata, exports a zone as
  BIND text, sends NOTIFY, retrieves a secondary zone and drops cached answers.
  The Admin UI routes cover cache domains, LAN A records and PTR records
  (`/domains/*`).
- **Replication state.** `peer::zone_state` compares serials with
  `dns::serial_cmp` (RFC 1982); the watchdog (`watchdog::dns_sync`) and the Admin UI
  (`dns::secondary_health`) report it.
- **Snapshots.** `snapshot::Store` keeps numbered known-good copies per zone;
  `dns::rollback`, route `/domains/zone-rollback` and the CLI `zone-snapshots` and
  `zone-rollback` restore one.
- **Secondaries.** The Admin UI registers, removes, rotates the token of,
  checks and re-addresses secondaries (`ui::register`, `ui::secondary_action`) and
  rotates the TSIG key (`dns::rotate_tsig`).
- **Secondary domain sync.** The primary's Admin UI makes each registered
  secondary hold exactly its zones (`peer::match_zones` via `dns::peer_follows`): right
  after its own zones change and in every secondary check, over the secondary's
  pdns API, creating zones with TSIG and deleting the ones it no longer serves.
  On the secondary the process `lancache-dns` (`lancache-ng dns`, `mod dns`)
  writes the dns configs from the zones its pdns holds, adds the TSIG key and
  the setup zones once without deleting, reloads both recursors and flushes a
  zone whose serial moved. It also takes the primary's own and switched-off
  cache domains from the zone metadata `X-LANCACHE-CDN` the primary sets.

## DHCP

Provided by `dhcp`, `kea_conf`, `kea`, `dhcp_probe` and `dnsmasq_conf` in
`services/lancache-ng/src/lancache-ng.rs` (`mod shared`). The Admin UI writes the mode (`off`, `kea`,
`dnsmasq-proxy`, `dnsmasq-relay`) and OpenRC starts only that mode's programs.

### Kea mode

- **Server.** `kea_conf::dhcp4` renders `kea-dhcp4.conf`; Kea keeps operator
  subnets and reservations that exist in the running config.
- **Control Agent.** `kea_conf::ctrl_agent` renders the agent config;
  `kea::Api` sends `config-get`, `config-set`, `config-write`, `lease4-get-all`
  and `lease4-del`.
- **DDNS.** `kea_conf::ddns` renders forward and reverse updates to the local
  PowerDNS, signed with TSIG (`DDNS_TSIG_KEY`, `DDNS_TSIG_ALGORITHM`); one
  forward domain per LAN domain. `kea_conf::subnet_ddns_suffix` gives a subnet
  whose domain is an extra LAN domain its own `ddns-qualifying-suffix`.
- **Admin UI.** Subnets (add, update, remove), options (add, remove, custom
  `CODE:VALUE` lines through `dhcp::custom_options`), static reservations,
  lease list and release, DDNS switch, NTP option (`dhcp::ntp_addrs`) and lease
  limits (`dhcp::lease_limits`), routes `/dhcp/*`.
- **Snapshots.** `kea_store` keeps known-good Kea configs; route
  `/dhcp/kea-rollback` restores one.
- **Probe.** `dhcp_probe::run` sends DISCOVER, REQUEST and RELEASE and reports
  the answering servers and their options (route `/dhcp/check`).

### dnsmasq modes

- **ProxyDHCP and relay.** `dnsmasq_conf::render` renders `dnsmasq.conf` for
  `dnsmasq-proxy` and `dnsmasq-relay` (routes `/dhcp/proxy`, `/dhcp/relay`).
  An empty `DHCP_SUBNET_START` makes the proxy range use `IP_HTTP`
  (`proxy_range`); an empty `DHCP_RELAY_LOCAL_ADDR` makes the relay use this
  host's first non-loopback address (`recursor_conf::own_ips`).
- **Options.** Router (3), DNS (6), domain (15), NTP (42) and custom options
  are sent as `dhcp-option-pxe`.
- **PXE.** `dnsmasq_conf::pxe` renders `pxe-service` and `dhcp-boot` for BIOS
  and UEFI clients when `DHCP_PROXY_PXE_BOOT_SERVER` and at least one boot file
  (`DHCP_PROXY_PXE_BOOT_FILENAME_BIOS`, `_UEFI`) are set.

## Admin UI

Provided by `mod ui` in `services/lancache-ng/src/lancache-ng.rs` and `services/ui/src/templates/`.

- **Pages.** `/` dashboard, `/setup`, `/logs`, `/stats`, `/domains`, `/dhcp`,
  `/cachehamster`; texts in German and English (`services/ui/src/lang/`). Every
  page and route path is a SOT key (`UI_PAGE_*`, `UI_ROUTE_*`); `router` reads
  them.
- **Settings.** `/setup/save`, REST `POST /api/settings` and CLI
  `lancache-ng config set` write changed keys into the stack `.env`
  (`STACK_ENV_FILE`) through `config::save_edits`, one change at a time
  (`stack::commit_with`); precedence per key is that file, the container
  environment, the SOT default (`config::Settings::load`). The schema reads
  each value by its kind (`ip`, `net`, `nets`, `addrs`, `hosts` read and
  normalize addresses); keys of effect `container` (host paths) and `fixed`
  (commands, internal paths, URLs, service names) are never stored by the ui
  and a value for them in the `.env` is ignored.
- **Stack state.** `stack::state_save` keeps the whole changeable state
  (settings, Kea config, own zones) after every change; REST
  `/api/stack/snapshots[/save|/restore]` and CLI `lancache-ng system snapshot
  list|save|restore <id>` list, keep and give back one state, with a backup
  of the current state first. `setup.sh reset-to-last-known-good-config
  stack` runs the same CLI in the ui container.
- **Config rendering.** `render::all` renders every config from the SOT and the
  settings into the `lancache-config` volume; `apply::owner_effects` and `apply::run` reload
  or restart only the owners with changes, through `docker::Api`. A reload runs
  the commands of `RELOAD_EXEC` in the owner container (`reload_exec`); an owner
  without a command, or a failed reload, is restarted.
- **Container actions.** `/api/container/{service}` sets a desired state,
  `/api/restart-ui` restarts the UI,
  `/api/service/{container}/{program}/{action}` (`service_action`) restarts or
  reloads one program through `rc-service` in its container; only programs
  listed in `UI_SERVICES` and only a running program; `docker::Api` also reads container state
  and statistics.
- **Access control.** HTTP Basic with an Argon2id hash when `UI_AUTH_PASSWORD_HASH`
  is set (`login_ok`), CSRF tokens bound to the session (`Csrf`), password
  change on `/setup/password` (`UI_PASSWORD_MIN_LENGTH`).
- **Status and statistics.** `/api/status` returns container states read from
  Docker, the dashboard shows the watchdog alarm file (`WATCHDOG_ALARM_FILE`);
  `/healthz` is the UI health route; `/stats` and
  `/stats/graph/{name}` draw RRD graphs fed from SNMP, Docker and program
  figures (`rrd`, `ui::sample_round`; a failing source is reported);
  `access::stats` shows proxy requests, hits and bytes and reads only the
  lines added since the last call. `/api/system/time` and `lancache-ng system
  time` show the services clock in the host time zone (`clock`).
- **Logs.** `/logs` shows the stored logs and `/logs/save` switches logging per
  service.
- **REST and CLI.** Every route is a row of `ui::table` (`lancache-ng ui
  routes` lists path, method and access). The CLI writes through the running
  ui over the socket `UI_CLI_SOCKET` (mode 0600) on the same routes and
  functions as the pages. Role commands: `lancache-ng ui healthcheck`,
  `zone-snapshots`, `zone-rollback`, `dhcp-probe`, `lang`, `routes`,
  `templates`, `password`.

## Watchdog

`lancache-ng watchdog` runs `round` every `CHECK_INTERVAL` and writes the
alarm file the Admin UI reads (`publish`, `WATCHDOG_ALARM_FILE`); each own
alarm carries a language key, so the dashboard shows it in the page language.
`lancache-ng watchdog check` runs the checks once, `alarms` prints the last
file, and `purge-cache`, `prune-logs`, `pack-logs [--dry-run]` run one step
(REST `/api/watchdog/check`, `/api/watchdog/{step}`):

- `containers`: reads the health of every container and restarts sick ones
  within a restart limit; containers the user stopped (`SERVICES_STOPPED`) are
  marked `stopped_by_user`.
- `cache_light`: cache free space against `DISK_WARN_PCT` and `DISK_ALARM_PCT`;
  `disks`: free space of each other watched path.
- `certs`: certificate expiry.
- `purge_cache`, `prune_logs`, `pack_logs`: daily removal of old cache files,
  log pruning and log packing.
- `log_writing`: checks that syslog-ng still writes.
- `dns_sync`: compares primary and secondary zone serials.
- `conntrack`: host conntrack entries against `CONNTRACK_MAX_FILE`; warns at
  `WATCHDOG_CONNTRACK_WARN_PCT` percent. It reads `nf_conntrack` under
  `HOST_NET_STAT_DIR` and does nothing when that file is absent.

## Services container programs

- **Logging.** `log::render` renders `syslog-ng.conf`: one store per program
  under `SYSLOG_LOG_ROOT`, optional forward targets, input on
  `LANCACHE_LOG_PORT`; containers log through the Docker `syslog` driver.
- **NTP.** `chrony::render` renders `chrony.conf` from the upstream servers,
  `NTP_ALLOWED_CLIENT_CIDRS`, `NTP_MAKESTEP` and `NTP_PORT`; `ntp::own_answers`
  sends one SNTP query to the own server (`lancache-ng ntp check`).
- **SNMP.** `snmp::render` renders `snmpd.conf` with extend commands and log
  matches for the graphs.

## CacheHamster

`mod cachehamster` in `services/lancache-ng/src/lancache-ng.rs` runs as a daemon in `services` and is controlled by
JSON commands that the Admin UI executes in that container (`ui::hamster`).

- **Steam login.** QR login (`cachehamster::login_begin`, `cachehamster::login_poll`); the session is stored
  sealed (`secret::seal`); `logout` removes it.
- **Library.** `library` lists the games of the logged-in account.
- **Jobs.** `add` queues a job for a Steam app (`Target::SteamApp`) or for URLs
  (`Target::Urls`); `start`, `cancel` and `remove` change it. A job runs now, later or in a time window
  (`When`, `window`) at a paced rate (`Pace`); every state change is kept in
  `jobs.json`.
- **Resolution.** `app_info` and `depots_of` resolve depots through the Steam
  connection manager, `request_code` and `chunks_of` read the manifest, and
  `app_urls` builds the chunk URLs and the total size. A depot whose request
  code or manifest Steam refuses is skipped and recorded in the job (`skipped`);
  the Admin UI shows the count (`hamster_skipped`).
- **Prefill.** `run_urls` fetches the URLs from the proxy, counts the bytes and
  discards the payload. It reaches the proxy by the container name
  `CONTAINER_NAME_PROXY` on `PROXY_HTTP_PORT` and falls back to the configured
  proxy address.

## setup.sh

Commands of the dispatcher: `install`, `install-requirements` (aliases
`install-requirements-primary`, `install-requirements-secondary`; `install`
and `secondary` run it on their own), `list-prompts`, `update`,
`auto-update`, `update-ip`, `configure-upstream-dns`, `debug`, `compose`,
`create-logs-for-issue`, `secondary`, `backup`, `restore`,
`reset-to-last-known-good-config` and `reset-sign-in`. Internal commands,
not in the usage text: `converge-reconcile` and `openrc-loop`.

- `install` runs the wizard and writes the environment file for `deploy/prod`;
  `secondary` takes the registration token of a primary (`--token`), builds the
  registration request and reads `deploy/secondary/docker-compose.yml`.
- `update` and `auto-update` resolve the image channel and tag and pin each
  image to its channel digest (`docs/combined-release-and-checklist.md`);
  `auto-update` and `converge-reconcile` run from host units for `systemd` or OpenRC.
- `install` and `update` call `ensure_docker_userland_proxy`: it sets
  `userland-proxy` in `docker_daemon_json` to `docker_userland_proxy` (SOT) and
  restarts Docker once after a confirmation; without a terminal it leaves Docker
  unchanged.
- `reset-sign-in` asks first (`--yes` skips the question), empties
  `UI_AUTH_PASSWORD_HASH`, sets `ALLOW_INSECURE_UI=true` in `.env` and
  restarts the `ui` container.
- `backup` and `restore` cover the persistent state; `reset-to-last-known-good-config
  <service>` restores a DNS zone snapshot (`ui zone-rollback`) or a Kea
  snapshot.

## Validation

- `.github/scripts/ci.sh check all` runs the named checks (for example
  `line-endings`, `comments`, `governance-guards`, `cargo-audit`,
  `shellcheck`, `actionlint`).
- `ci.sh validate` validates the accepted stack candidate end to end.
- `.github/scripts/ci.bats` holds the tests; each starts with its
  `<name>_is_enabled` switch (`ci.sh check ci-bats enable-<name>`).
- The repository has no `tests/` directory and no Rust test function under
  `services/`.

## Howto audit this file

The audit procedure of this file is `docs/policy/howto-audit-documentation.md`.
