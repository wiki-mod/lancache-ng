# LanCache-NG Capability Inventory

Reviewed against `current_dev` `5f32f9f1`.

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
| Admin UI | Settings, config rendering, container actions, status and statistics | `lancache-ui` (`ui`) |
| Watchdog | Container health and restart, disk, certificate and log duties | `lancache-watchdog` (`services`) |
| Logging | Central log store and forwarding | syslog-ng (`services`) |
| NTP | LAN time server | chronyd (`services`) |
| SNMP | Host and container figures | snmpd (`services`, `dns`) |
| CacheHamster | Steam cache prefill | `lancache-cachehamster` (`services`) |
| setup.sh | Install, update, backup, restore, secondary setup | Bash (host) |

The program list of each container is the SOT field `processes` in
`.github/yaml/build-manifest.yml`.

## Proxy

Provided by `services/ui/nginx/*` templates and the generator `nginx_conf` in
`services/common/shared.rs`.

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
- **Certificates.** `cert::make_ca` creates the CA (`CA_KEY_TYPE`, `CA_DAYS`,
  `CA_KEY_MODE`); `cert::make_leaf` signs one leaf per host;
  `render::issue_certs` issues the planned set; `cert::valid_for` and
  `cert::expiry` report remaining validity.
- **Endpoints.** `PROXY_HEALTH_PATH` serves the health file and
  `PROXY_STATUS_PATH` serves `stub_status`, both only to loopback and the Docker
  network; a request with an IP literal as host is redirected to the Admin UI.
- **Access log.** `log_format cache` writes to stdout; `access::parse` and
  `access::stats` read the stored files for the Admin UI.

## DNS

Provided by `pdns_conf`, `recursor_conf`, `pdns`, `dns` and `snapshot` in
`services/common/shared.rs`.

- **Cache routing.** `recursor_conf::rpz` builds the RPZ zone that answers every
  cache domain; `recursor_conf::lua` loads it and sets no-DNSSEC-check entries
  for local and listed private zones.
- **Recursors.** `dns-http` and `dns-https` run with the configs
  `recursor_conf::yaml` renders; LAN zones go to the authoritative server;
  `ROOT_ZONE_MIRROR` keeps a root zone copy.
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
- **Replication state.** `dns::sync_state` compares serials (`dns::serial_cmp`,
  RFC 1982); the watchdog (`dns_sync`) and the Admin UI (`secondary_health`)
  report it.
- **Snapshots.** `snapshot::Store` keeps numbered known-good copies per zone;
  `rollback`, route `/domains/zone-rollback` and the CLI `zone-snapshots` and
  `zone-rollback` restore one.
- **Secondaries.** The Admin UI registers, removes, rotates the token of,
  checks and re-addresses secondaries (`register`, `secondary_action`) and
  rotates the TSIG key (`rotate_tsig`).

## DHCP

Provided by `dhcp`, `kea_conf`, `kea`, `dhcp_probe` and `dnsmasq_conf` in
`services/common/shared.rs`. The Admin UI writes the mode (`off`, `kea`,
`dnsmasq-proxy`, `dnsmasq-relay`) and OpenRC starts only that mode's programs.

### Kea mode

- **Server.** `kea_conf::dhcp4` renders `kea-dhcp4.conf`; Kea keeps operator
  subnets and reservations that exist in the running config.
- **Control Agent.** `kea_conf::ctrl_agent` renders the agent config;
  `kea::Api` sends `config-get`, `config-set`, `config-write`, `lease4-get-all`
  and `lease4-del`.
- **DDNS.** `kea_conf::ddns` renders forward and reverse updates to the local
  PowerDNS, signed with TSIG (`DDNS_TSIG_KEY`, `DDNS_TSIG_ALGORITHM`).
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
- **Options.** Router (3), DNS (6), domain (15), NTP (42) and custom options
  are sent as `dhcp-option-pxe`.
- **PXE.** `dnsmasq_conf::pxe` renders `pxe-service` and `dhcp-boot` for BIOS
  and UEFI clients when `DHCP_PROXY_PXE_BOOT_SERVER` and at least one boot file
  (`DHCP_PROXY_PXE_BOOT_FILENAME_BIOS`, `_UEFI`) are set.

## Admin UI

Provided by `services/ui/src/main.rs` and `services/ui/src/templates/`.

- **Pages.** `/` dashboard, `/setup`, `/logs`, `/stats`, `/domains`, `/dhcp`,
  `/cachehamster`; texts in German and English (`services/ui/src/lang/`).
- **Settings.** `/setup/save` stores changed keys in `UI_SETTINGS_FILE`;
  precedence per key is that file, the container environment, the SOT default
  (`config::Settings::load`).
- **Config rendering.** `render::all` renders every config from the SOT and the
  settings into the `lancache-config` volume; `apply::plan` and `apply::run` reload
  (HUP) or restart only the owners with changes, through `docker::Api`.
- **Container actions.** `/api/container/{service}` sets a desired state,
  `/api/restart-ui` restarts the UI; `docker::Api` also reads container state
  and statistics.
- **Access control.** HTTP Basic with an Argon2id hash when `UI_PASSWORD_HASH`
  is set (`login_ok`), CSRF tokens bound to the session (`Csrf`), password
  change on `/setup/password` (`UI_PASSWORD_MIN_LENGTH`).
- **Status and statistics.** `/api/status` returns container states read from
  Docker, the dashboard shows the watchdog alarm file (`WATCHDOG_ALARM_FILE`);
  `/healthz` is the UI health route; `/stats` and
  `/stats/graph/{name}` draw RRD graphs fed from SNMP and Docker figures (`rrd`);
  `access::stats` shows proxy requests, hits and bytes.
- **Logs.** `/logs` shows the stored logs and `/logs/save` switches logging per
  service.
- **CLI.** `lancache-ui healthcheck`, `render-dns`, `zone-snapshots` and
  `zone-rollback`.

## Watchdog

`lancache-watchdog` runs `round` every `CHECK_INTERVAL` and writes the alarm
file the Admin UI reads (`publish`, `WATCHDOG_ALARM_FILE`):

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

## Services container programs

- **Logging.** `log::render` renders `syslog-ng.conf`: one store per program
  under `SYSLOG_NG_LOG_DIR`, optional forward targets, input on
  `LANCACHE_LOG_PORT`; containers log through the Docker `syslog` driver.
- **NTP.** `chrony::render` renders `chrony.conf` from the upstream servers,
  `NTP_ALLOWED_CLIENT_CIDRS`, `NTP_MAKESTEP` and `NTP_PORT`; `ntp::answers`
  sends one SNTP query to test a server.
- **SNMP.** `snmp::render` renders `snmpd.conf` with extend commands and log
  matches for the graphs.

## CacheHamster

`services/cachehamster` runs as a daemon in `services` and is controlled by
JSON commands that the Admin UI executes in that container (`hamster`).

- **Steam login.** QR login (`login_begin`, `login_poll`); the session is stored
  sealed (`secret::seal`); `logout` removes it.
- **Library.** `library` lists the games of the logged-in account.
- **Jobs.** `add` queues a job for a Steam app (`Target::SteamApp`) or for URLs
  (`Target::Urls`); `start`, `cancel` and `remove` change it. A job runs now, later or in a time window
  (`When`, `window`) at a paced rate (`Pace`); every state change is kept in
  `jobs.json`.
- **Resolution.** `app_info` and `depots_of` resolve depots through the Steam
  connection manager, `request_code` and `chunks_of` read the manifest, and
  `app_urls` builds the chunk URLs.
- **Prefill.** `run_urls` fetches the URLs through the proxy, counts the bytes
  and discards the payload.

## setup.sh

Commands of the dispatcher: `install`, `install-requirements-primary`,
`install-requirements-secondary`, `update`, `auto-update`, `update-ip`,
`configure-upstream-dns`, `create-logs-for-issue`, `secondary`, `backup`,
`restore`, `reset-to-last-known-good-config`, `converge` and `compose`.

- `install` runs the wizard and writes the environment file for `deploy/prod`;
  `secondary` takes the registration token of a primary (`--token`), builds the
  registration request and reads `deploy/secondary/docker-compose.yml`.
- `update` and `auto-update` resolve the image channel and tag and pin each
  image to its channel digest (`docs/combined-release-and-checklist.md`);
  `auto-update` and `converge` run from host units for `systemd` or OpenRC.
- `backup` and `restore` cover the persistent state; `reset-to-last-known-good-config`
  restores the Kea snapshot.

## Validation

- `.github/scripts/ci.sh check all` runs 42 named checks (for example
  `line-endings`, `comments`, `governance-guards`, `compose-config`,
  `compose-healthchecks`, `proxy-nginx-policy`, `prod-state-wiring`,
  `setup-update-safety`, `logging-matrix`, `vex-drift`, `cargo-audit`,
  `shellcheck`, `actionlint`).
- `ci.sh validate` validates the accepted stack candidate end to end.
- `.github/scripts/ci.bats` holds 4 tests.
- The repository has no `tests/` directory and no Rust test function under
  `services/`.

## Howto audit this file

The audit procedure of this file is `docs/policy/howto-audit-documentation.md`.
