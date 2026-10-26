# dnsmasq relay/proxy DHCP Admin UI — Feature Scope

This is the written decision issue #647 asked for: one place that says what the
Admin UI lets an operator configure for the two **dnsmasq DHCP modes**, so that
code which looks unused or half-finished is not misread as dead or removable.
It is the sibling of [`dns-admin-ui-scope.md`](dns-admin-ui-scope.md) (issue
#645) and [`kea-dhcp-admin-ui-scope.md`](kea-dhcp-admin-ui-scope.md) (issue
#646).

This is a **scoping document, not an implementation plan**. Where it says
"planned but unbuilt," treat the referenced code (or its absence) as
intentional, not as something to clean up.

## 0. The open question this issue existed to resolve — resolved and built

The `dnsmasq-proxy` mode renders `dhcp-range=<subnet>,proxy`, which puts
dnsmasq into RFC 4388 ProxyDHCP/PXE mode: it answers *supplementary* PXE and
boot options next to an existing DHCP server and issues no addresses of its
own. #450 removed an inert `dhcp-proxy=${UPSTREAM_DHCP_IP}` line, which did
nothing without a relay.

**Maintainer decision (2026-07-20):** real DHCP packet relay was **intended
work, not dead code.** It is now built as the `dnsmasq-relay` mode (#844): the
supervisor renders `dhcp-relay=<DHCP_RELAY_LOCAL_ADDR>,<UPSTREAM_DHCP_IP>`
(`dnsmasq_conf` in `services/watchdog/src/main.rs`), which forwards
DISCOVER/OFFER/REQUEST/ACK to a DHCP server on another subnet or VLAN.
DHCP-Relay is a *third* mode next to DHCP-Server (Kea) and DHCP-Proxy, not a
rename of either.

## 1. What the Admin UI configures

Both modes are selected through the one DHCP mode switch (`POST /dhcp/mode`,
`update_dhcp_mode` in `services/ui/src/main.rs`, values `dnsmasq-proxy` and
`dnsmasq-relay`). The settings are saved into the UI settings file; the
supervisor in the `dhcp` container renders `dnsmasq.conf` from them
(`dnsmasq_conf`) and restarts dnsmasq when the file changes.

**dnsmasq-proxy** (`POST /dhcp/proxy`, `update_dhcp_proxy`, all checked server
side):

| Field | Setting | Check |
|---|---|---|
| Proxy subnet | `DHCP_SUBNET_START` | required, IPv4 |
| Upstream DHCP IP | `UPSTREAM_DHCP_IP` | required, IPv4; the proxy render uses no line from it |
| Primary DNS (optional) | `DHCP_DNS_PRIMARY` | IPv4 if set |
| Secondary DNS (optional) | `DHCP_DNS_SECONDARY` | IPv4 if set |
| Listen interface (optional, #450) | `DHCP_PROXY_INTERFACE` | interface name if set |
| Router/gateway option (optional, #450) | `DHCP_PROXY_ROUTER` | IPv4 if set |
| NTP servers (optional, #450) | `DHCP_NTP_SERVERS` | comma-separated IPv4 list if set |
| Domain option (optional, #450) | `DHCP_PROXY_DOMAIN` | domain name if set |
| PXE boot filename (optional, #450) | `DHCP_PROXY_BOOT_FILENAME` | boot filename if set |
| PXE boot server (optional, #450) | `DHCP_PROXY_BOOT_SERVER` | IPv4 if set; **cross-field**: a boot server needs a boot filename |
| Custom options (optional) | `DHCP_PROXY_CUSTOM_OPTIONS` | `parse_custom_options`; codes the render owns are refused |

The BIOS/UEFI PXE boot pointer (`DHCP_PROXY_PXE_BOOT_SERVER`,
`DHCP_PROXY_PXE_BOOT_FILENAME_BIOS`, `DHCP_PROXY_PXE_BOOT_FILENAME_UEFI`) is set
through `setup.sh` and the compose environment, not through the Admin UI.

**dnsmasq-relay** (`POST /dhcp/relay`, `update_dhcp_relay`):

| Field | Setting | Check |
|---|---|---|
| Relay local address | `DHCP_RELAY_LOCAL_ADDR` | required, IPv4 (this relay's own IP on the client network, sent as `giaddr`) |
| Upstream DHCP IP | `UPSTREAM_DHCP_IP` | required, IPv4 |

## 2. Planned but unbuilt

- **Plain-language mode presentation** (#1068): the field test found the raw
  "KEA"/"dnsmasq-proxy" names confusing. Presenting the three modes in operator
  language, as the mockup's comparison table does, is in scope and not built.

## 3. Intentionally out of scope (not planned)

- A general dnsmasq admin panel (arbitrary `dnsmasq.conf` directives through
  the UI). The curated fields above, PXE and the relay are the intended
  surface.

## 4. Relationship to Kea full-DHCP mode — where the line is

Three mutually exclusive modes, selected by the one DHCP mode switch:

| Mode | Issues addresses? | Works next to another DHCP server? | Relays to another subnet? | Backend |
|---|---|---|---|---|
| **DHCP-Server** (`kea`) | Yes | No (conflicts by design) | No | Kea — see [`kea-dhcp-admin-ui-scope.md`](kea-dhcp-admin-ui-scope.md) |
| **DHCP-Proxy** (`dnsmasq-proxy`) | No (supplemental PXE/options only) | Yes | No | dnsmasq ProxyDHCP |
| **DHCP-Relay** (`dnsmasq-relay`) | No (forwards to a remote server) | Yes | Yes | dnsmasq `dhcp-relay=` |

## 5. Summary table

| Area | State | Where |
|---|---|---|
| dnsmasq mode select | Admin UI, implemented | `services/ui/src/main.rs` `update_dhcp_mode` |
| Proxy subnet / DNS / interface / router / NTP / domain / custom options | Admin UI, implemented | `services/ui/src/main.rs` `update_dhcp_proxy`, #450 |
| PXE boot filename/server (proxy) | Admin UI, implemented | `services/ui/src/main.rs` `update_dhcp_proxy`, #450 |
| BIOS/UEFI PXE boot pointer | `setup.sh` and compose, implemented | `dnsmasq_conf` |
| Real DHCP packet relay (`dhcp-relay=`) | Admin UI and supervisor, implemented | `update_dhcp_relay`, `dnsmasq_conf`, #844 |
| Plain-language mode presentation | Not built | Planned, #1068 |
| General dnsmasq config editor | Not planned | Deliberately out of scope |

## How to use this document

Before you remove or flag as dead any dnsmasq-proxy, dnsmasq-relay or
`UPSTREAM_DHCP_IP` code that looks incomplete, check this document first. If a
gap you found is not listed here, that is this document's own gap: update it
rather than guessing.
