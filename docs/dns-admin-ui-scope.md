# DNS / PowerDNS Admin UI — Feature Scope

This document says what the Admin UI lets an operator configure and manage
for DNS (PowerDNS authoritative server and recursor). Code that looks unused
or half-finished in this area is not dead code; check this list first.

Since the 2.0 rewrite (PR #1858) there is no NATS and no `nats-subscriber`.
The Admin UI talks to the native PowerDNS HTTP API. Secondaries get zones by
NOTIFY and AXFR.

Related: [known-good-config-snapshots.md](known-good-config-snapshots.md)
("Zones, records, and TSIG/DDNS metadata").

## Code owners

| Owner | File |
|---|---|
| Admin UI pages and forms (`dns_action`, `record`, `rollback`, secondary routes) | `services/ui/src/main.rs` |
| PowerDNS API client (`pdns::Api`: rrsets, PATCH, restore, create_secondary, flush) | `services/common/shared.rs` |
| PowerDNS and recursor config render (`pdns_conf`, `recursor_conf`) | `services/common/shared.rs` |
| Settings and SOT keys | `services/common/config.rs`, `.github/yaml/build-manifest.yml` |
| Serial check primary and secondary, recursor flush on a secondary | `services/watchdog/src/main.rs` |

## 1. What the operator changes in the Admin UI

| Change | Route | Effect |
|---|---|---|
| Add, remove or switch a CDN domain | `POST /domains/domain-add`, `/domain-remove`, `/domain-toggle` | Writes `CDN_CUSTOM_DOMAINS` / `CDN_DISABLED_DOMAINS`; the RPZ is rendered again |
| LAN records (types from `DNS_LAN_RECORD_TYPES`) | `POST /domains/record-add`, `/record-remove` | PATCH on the LAN zone; PowerDNS raises the serial and sends NOTIFY |
| PTR records | `POST /domains/ptr-add`, `/ptr-remove` | PATCH on the private reverse zone |
| AAAA filter | `POST /domains/aaaa-filter` | Switches `DNS_FILTER_AAAA`; the recursor Lua script answers AAAA with no data |
| Unsigned DDNS | `POST /domains/ddns-unsigned` | Switches `DDNS_ALLOW_UNSIGNED` (`dnsupdate-require-tsig`) |
| Zone rollback | `POST /domains/zone-rollback` | Restores a stored snapshot through the PowerDNS API |

Keys, the TSIG key and the API key are created once by the stack and are not
edited in the Admin UI.

## 2. Secondaries

| Step | Where | Native PowerDNS way |
|---|---|---|
| Register | `POST /api/secondary/register` (token) | The answer holds the primary address, zones, PowerDNS API key, TSIG name and secret and the syslog target |
| Change address, check health, rotate, remove | `POST /api/secondary/{name}/address`, `/health`, `/rotate`, `/remove` | `DNS_SECONDARIES` ("name@ip") feeds `also-notify` and `allow-axfr-ips` |
| Zone transfer | PowerDNS | NOTIFY from the primary, AXFR by the secondary (zone kind Slave) |
| Cache on the secondary | watchdog | A raised serial triggers a recursor cache flush (`RECURSOR_API_URLS`) |
| Logs | syslog-ng | A secondary forwards its logs to the primary (`SYSLOG_PRIMARY`) |

## 3. Read-only status

The domains page shows the CDN list, LAN records, snapshots per zone and per
secondary the serial compare. The watchdog raises an alarm when a
secondary's serial stays behind.

## 4. Not in the Admin UI

| Topic | Why |
|---|---|
| Zones other than the LAN zone and the private reverse zones | The RPZ is rendered from the CDN list, not edited |
| TSIG key and API key rotation | Generated secrets; rotation per secondary only |
| Recursor upstreams and root mirror | SOT keys, changed by `setup.sh` |
