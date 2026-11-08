# lancache-ng Operator Guide

This guide covers operating an installed lancache-ng stack: changing the
server IP address, installing the CA certificate on clients, choosing a DHCP
mode, rolling back known-good configurations, backing up and restoring, and
tuning the host network.

Valid for `current_dev` at `e223782d`. Section 9 lists what is not verified.

## Contents

1. [Documentation index](#1-documentation-index)
2. [Settings and commands](#2-settings-and-commands)
3. [Change the server IP address](#3-change-the-server-ip-address)
4. [Install the CA certificate](#4-install-the-ca-certificate)
5. [DHCP modes](#5-dhcp-modes)
6. [Known-good snapshots and rollback](#6-known-good-snapshots-and-rollback)
7. [Backup, restore and rollback](#7-backup-restore-and-rollback)
8. [OS and kernel network tuning](#8-os-and-kernel-network-tuning)
9. [Open verification](#9-open-verification)

---

## 1. Documentation index

| Document | Content |
| --- | --- |
| `README.md` (repository root) | Overview, installation, configuration reference |
| `docs/README.md` | This operator guide |
| `docs/architecture-ng.md` | Service architecture |
| `docs/threat-model.md` | Threat model |
| `docs/design-plannings/capability-inventory.md` | Capability inventory |
| `docs/policy/naming-conventions-policy.md` | Naming contract (AG-CODE-014) |
| `docs/combined-release-and-checklist.md` | Release channels, external images, provenance, release validation and checklist |
| `docs/ci-2.0-architecture.md` | CI 2.0 architecture |
| `docs/policy/` | Policies (`ci-image-pinning-policy.md`, `howto-audit-documentation.md`, `naming-conventions-policy.md`) |
| `docs/design-plannings/` | Design plans (`capability-inventory.md`, `design-wireguard-remote-access.md`) |
| `AGENTS.md`, `SECURITY.md`, `CONTRIBUTING.md`, `GOVERNANCE.md` | Governance, security policy, contribution rules |

---

## 2. Settings and commands

- The runtime settings of a production installation are in
  `deploy/prod/.env.local`. No `.env` is tracked. `setup.sh` prefers this file
  for backup, update, restore and `update-ip` when it exists.
- The state root is `LANCACHE_STATE_DIR` (default `/opt/lancache-ng`). The
  code of each channel lives in its own directory below it; `current` links
  the one in use.
- `setup.sh` is the single entry point. The commands used in this guide:

  | Command | Purpose |
  | --- | --- |
  | `setup.sh install` | guided first-time installation; without a command `setup.sh` only prints its usage |
  | `setup.sh update [install-dir]` | update the stack with health gates and rollback |
  | `setup.sh update-ip [install-dir]` | change the HTTP and HTTPS listener IP addresses |
  | `setup.sh backup [--config\|--full] [install-dir] [--dest <path>]` | create a backup archive |
  | `setup.sh restore <archive> [install-dir]` | restore a backup archive |
  | `setup.sh compose <install-dir> <compose arguments>` | internal; runs Docker Compose with the stack's file list (used by units and recovery hints) |
  | `setup.sh configure-upstream-dns` | set the upstream DNS servers |
  | `setup.sh reset-to-last-known-good-config <service> ...` | roll back a Kea configuration or a DNS zone (section 6) |

  `setup.sh --help` prints the usage with every command.

---

## 3. Change the server IP address

The cache binds to one or two addresses of the server:

| Variable | Mode | Purpose |
| --- | --- | --- |
| `IP_HTTP` | HTTP | HTTP cache and HTTPS passthrough; clients use it as their DNS server |
| `IP_HTTPS` | HTTPS | HTTPS interception; clients use it as their DNS server and need the CA certificate (section 4) |

If only HTTP mode runs, only `IP_HTTP` changes. Active downloads are
interrupted by the change; pick a quiet moment.

### 3.1 With `setup.sh` (recommended)

```bash
sudo /opt/lancache-ng/current/setup.sh update-ip
```

`setup.sh --reconfigure` runs the same command. The command asks for the new
addresses and restarts the stack through the same health-gated steps as
`update`. If the stack does not become healthy, the previous addresses are
restored.

### 3.2 Manual method

Use this only when `setup.sh` is not available.

1. If a second address is added, assign it to the same interface of the host.
   A temporary assignment for testing:

   ```bash
   ip addr add 192.168.2.11/24 dev eth0
   ip -4 addr show eth0
   ```

   To make it permanent, add it to the host's network configuration. A
   Netplan example:

   ```yaml
   # /etc/netplan/01-netcfg.yaml
   network:
     version: 2
     ethernets:
       eth0:
         addresses:
           - 192.168.2.10/24
           - 192.168.2.11/24
         routes:
           - to: default
             via: 192.168.2.1
   ```

   ```bash
   sudo netplan apply
   ```

2. Set the new addresses in `deploy/prod/.env.local`:

   ```env
   IP_HTTP=192.168.2.10
   IP_HTTPS=192.168.2.11
   ```

   The `dns` container takes its addresses from `IP_HTTP` and `IP_HTTPS`;
   there is no separate DNS configuration to edit.

3. Recreate the stack and check it:

   ```bash
   cd deploy/prod
   docker compose --env-file .env.local up -d
   docker compose --env-file .env.local ps
   ```

4. Point the clients at the new addresses: `IP_HTTP` for HTTP mode, `IP_HTTPS`
   for HTTPS mode. Change the DNS option on the DHCP server (clients pick it up
   at the next lease renewal) or the DNS setting of each device.

### 3.3 Verify

```bash
dig @192.168.2.10 steamcontent.com A +short   # expected: 192.168.2.10
dig @192.168.2.11 steamcontent.com A +short   # expected: 192.168.2.11
```

Both answers have to name the address that was queried.

### 3.4 Troubleshooting

| Symptom | Check |
| --- | --- |
| DNS does not answer on the new address | `ip -4 addr show`; `docker compose --env-file .env.local ps`; port 53 open on the new address in the host firewall |
| Containers do not start | `docker compose --env-file .env.local logs -f` in `deploy/prod` |
| Clients cannot reach the cache | ping the new address; check whether the client still uses the old DNS address; renew the DHCP lease (`ipconfig /renew` on Windows, `dhclient` on Linux) |

---

## 4. Install the CA certificate

In HTTPS mode the proxy intercepts HTTPS connections to cache them. The CA
certificate has to be installed once on every client device that uses the
`IP_HTTPS` DNS address. HTTP mode needs no CA certificate.

`ca.crt` is in the CA state directory after the first start: `CA_DIR`, by
default the `STATE_SUBDIR_CA` folder (`ca`) below `LANCACHE_STATE_DIR`.
`setup.sh` prints the full path.

### 4.1 Per platform

| Platform | Steps |
| --- | --- |
| Windows | Double-click `ca.crt`, choose "Install certificate", "Local machine", then place it in "Trusted root certification authorities". In an elevated PowerShell: `Import-Certificate -FilePath .\ca.crt -CertStoreLocation Cert:\LocalMachine\Root` |
| Linux (Ubuntu, Debian) | `sudo cp ca.crt /usr/local/share/ca-certificates/lancache.crt` and `sudo update-ca-certificates` |
| macOS | Double-click `ca.crt`, place it under **System** (not "Login"), open it in Keychain Access and set "Always trust" |
| Firefox (all platforms) | Firefox ignores the system store: Settings, Privacy & Security, Certificates, View certificates, "Authorities", Import, trust the CA to identify websites |
| Steam Deck (desktop mode) | `sudo trust anchor --store ca.crt` |

### 4.2 Consoles

PS5, Xbox and Nintendo Switch cannot install a custom CA certificate, so
HTTPS-mode interception cannot work for them. A console must not use the
`IP_HTTPS` DNS address.

`services/dns/cdn-domains.txt` lists no PlayStation or Nintendo CDN hosts and
states that consoles cannot use the CA. It does list nine Xbox and Game Pass
hosts (`assets1.xboxlive.com`, `assets2.xboxlive.com`, `d1.xboxlive.com`,
`d2.xboxlive.com`, `dlassets.xboxlive.com`, `dlassets2.xboxlive.com`,
`xbox-mbr.xboxlive.com`, `xvcf1.xboxlive.com`, `xvcf2.xboxlive.com`). A host
that is on the list resolves to the proxy; a host that is not on the list
resolves to the real CDN and is not cached.

Hosts can be added to the list in `services/dns/cdn-domains.txt` or in the
Admin UI CDN domain list. Do not add the hosts of a console to a LAN that
contains that console and uses the HTTPS-mode DNS address.

Hosts that may be added by hand on a LAN without the matching console:

| Service | Hosts |
| --- | --- |
| Nintendo Switch | `.hac.lp1.d4c.nintendo.net`, `.hac.lp1.eshop.nintendo.net`, `.wup.eshop.nintendo.net`, `.wup.shop.nintendo.net`, `ccs.cdn.wup.shop.nintendo.net.edgesuite.net`, `ecs-lp1.hac.shop.nintendo.net`, `geisha-wup.cdn.nintendo.net`, `geisha-wup.cdn.nintendo.net.edgekey.net`, `idbe-wup.cdn.nintendo.net`, `idbe-wup.cdn.nintendo.net.edgekey.net`, `receive-lp1.dg.srv.nintendo.net` |

### 4.3 Distribute `ca.crt` to clients

`ca.crt` is a public certificate. Only `ca.key` is secret; it never leaves the
server. Never serve the CA state directory itself: it contains `ca.key`.

Serve a copy of `ca.crt` from a throwaway directory and stop the server when
every client has fetched the file:

```bash
( serve_dir="$(mktemp -d)" && trap 'rm -rf "$serve_dir"' EXIT \
  && cp "$CA_DIR/ca.crt" "$serve_dir/" && cd "$serve_dir" \
  && python3 -m http.server 8000 )
```

Clients then fetch `http://<lancache-lan-ip>:8000/ca.crt`. Alternatively copy
the file with `scp "user@<lancache-lan-ip>:$CA_DIR/ca.crt" .`.

- `mktemp -d` creates a directory that did not exist before, so the command
  cannot follow a pre-existing directory or symlink.
- The `trap` removes the directory when the subshell exits. If the shell is
  killed outright, a copy of the public `ca.crt` stays under `/tmp`; that is a
  tidiness gap, not a security one.
- While the server runs, any LAN device can fetch `ca.crt` without
  authentication. That is acceptable for a public certificate; stop it after
  use.

A documented procedure for issuing a new CA after a compromise is not part of
this guide. The generic steps are in section 7.5.

---

## 5. DHCP modes

Clients use the cache only if they resolve CDN hostnames through its DNS
servers. DHCP is the most reliable way to hand those DNS servers to every
client. The `dhcp` container runs one mode at a time on the host network;
`DHCP_MODE` selects it.

### 5.1 The modes

| `DHCP_MODE` | What it does | Lease owner |
| --- | --- | --- |
| `off` (default) | LanCache NG manages no DHCP. Point clients at its DNS yourself (router DHCP option, static configuration). | the existing DHCP server |
| `kea` | Kea runs as the full DHCP server and hands out addresses, gateway and DNS. | Kea in LanCache NG |
| `dnsmasq-proxy` | dnsmasq runs in ProxyDHCP mode next to an existing DHCP server and answers the supplementary PXE exchange only. | the existing DHCP server |
| `dnsmasq-relay` | dnsmasq forwards every client request to an upstream DHCP server on another segment and relays the reply. | the upstream DHCP server |

The modes are mutually exclusive: Kea and dnsmasq both bind UDP port 67. The
`dhcp` container renders `dnsmasq.conf` only for the two dnsmasq modes.
`off` and `kea` start no dnsmasq. The mode is saved in the Admin UI settings
(`POST /dhcp/mode`).

| Question | `kea` | `dnsmasq-proxy` | `dnsmasq-relay` |
| --- | --- | --- | --- |
| Issues addresses | yes | no (supplementary PXE and options only) | no (forwards to a remote server) |
| Works next to another DHCP server | no | yes | yes |
| Relays to another subnet | no | no | yes |

### 5.2 `kea`

Choose `kea` when you can change the router's DHCP settings. Kea replaces the
router as the DHCP server; only one DHCP server may be active on a LAN.

- Set `DHCP_MODE=kea` and bring Kea up first, then disable the router's DHCP
  server. Disabling the router first leaves clients, especially on Wi-Fi after
  a router reboot, without any DHCP server.
- Kea hands out address, gateway and the LanCache NG DNS servers. The Admin UI
  edits subnets, options, static reservations and leases through the Kea
  control agent.

**Activation preflight.** Before the stack starts, `setup.sh`
(`run_kea_dhcp_activation_preflight`) runs one DHCP probe from the `ui` image on
the host network (`docker run --rm --network host ... <ui image> dhcp-probe`).
It does not start Kea.

| Probe result | `setup.sh` |
| --- | --- |
| no other DHCP server answers (`servers` is empty) | continues; Kea starts |
| another server answers | prints the first responding server and asks `Continue with Kea activation anyway? [y/N]` (default No); No cancels the activation |
| the probe did not complete (no answer or `error` set) | prints a warning and asks the same question (fails closed) |

The probe sends a broadcast DISCOVER and a client dry-run (REQUEST for the
first offer, then RELEASE). It does not validate Kea's own configuration and
does not test the leases or options Kea hands out.

### 5.3 `dnsmasq-proxy`

Choose it when an existing DHCP server cannot be turned off (for example an ISP
router). The existing server keeps assigning addresses; dnsmasq answers the
ProxyDHCP and PXE part of the exchange (RFC 4388).

Limits of this mode:

- no static reservations, no lease listing, no lease-time control;
- router, DNS, NTP, domain and custom options reach only PXE and
  network-boot-aware clients through the supplementary exchange. The router,
  DNS, NTP and domain settings of an ordinary client come from its real lease
  at the upstream server;
- use `kea`, or set DNS on the router or the clients, when LanCache NG has to
  control what ordinary clients receive.

The Admin UI shows the live proxy values and hides the Kea-only subnet,
reservation and lease editors while this mode is active.

Settings of the `dnsmasq-proxy` render (`dnsmasq_conf`,
`services/common/shared.rs`):

| Setting | Rendered as | Note |
| --- | --- | --- |
| `DHCP_SUBNET_START` | `dhcp-range=<value>,proxy` | required; the network base address of the served LAN |
| `UPSTREAM_DHCP_IP` | nothing | the proxy render uses no line from it |
| `DHCP_DNS_SERVERS` | `dhcp-option-pxe=6,<list>` | the Admin UI form joins primary and secondary DNS into this list |
| `DHCP_PROXY_INTERFACE` | `interface=<value>` | optional |
| `DHCP_PROXY_ROUTER` | `dhcp-option-pxe=3,<value>` | optional |
| `DHCP_PROXY_DOMAIN` | `dhcp-option-pxe=15,<value>` | optional |
| `DHCP_NTP_SERVERS` | `dhcp-option-pxe=42,<addresses>` | optional; host names are resolved to IPv4 addresses |
| `DHCP_PROXY_BOOT_FILENAME` | `dhcp-boot=<file>,,<server>` | optional |
| `DHCP_PROXY_BOOT_SERVER` | server part of `dhcp-boot` | optional |
| `DHCP_CUSTOM_OPTIONS` | one `dhcp-option-pxe=<code>,<data>` per line | optional; the compose key `DHCP_PROXY_CUSTOM_OPTIONS` feeds it |

An empty optional value renders no line. A value with a line break stops the
render with an error.

**Custom options** are lines of the form `CODE:VALUE`. A code has to be 1 to
254 and not one of the codes the dedicated fields own (router, DNS, domain,
NTP). The data has to be one non-empty line without `;` and at most
`DHCP_OPTION_DATA_MAX` bytes (SOT, default 255).

**PXE boot pointer.** dnsmasq's ProxyDHCP replies only when a `pxe-service`
directive exists. The render adds it only when
`DHCP_PROXY_PXE_BOOT_SERVER` and at least one of the filename settings are
set; otherwise the options above stay inert. The project never hosts boot
files; the server is operator-owned.

| Setting | Meaning |
| --- | --- |
| `DHCP_PROXY_PXE_BOOT_SERVER` | address of the operator's PXE or TFTP server; required for the pointer |
| `DHCP_PROXY_PXE_BOOT_FILENAME_BIOS` | boot file for legacy BIOS clients (client architecture 0) |
| `DHCP_PROXY_PXE_BOOT_FILENAME_UEFI` | one boot file for UEFI architectures 7 (`x86-64_EFI`) and 11 (`ARM64_EFI`) |

The UEFI setting is one file for both architectures. If the two boot artifacts
differ, use `DHCP_CUSTOM_OPTIONS` for a finer override. The pointer settings
are set through `setup.sh` and the compose environment, not through the Admin
UI. The boot files are delivered through `dhcp-boot` tagged by DHCP option 93;
one `pxe-service` row (BIOS, or an inert placeholder) exists only so that
ProxyDHCP replies happen.

### 5.4 `dnsmasq-relay`

Choose it when the clients and the real DHCP server are on different segments
and the clients' broadcasts cannot reach the server. dnsmasq listens for
client broadcasts, forwards each request to the upstream server and relays the
reply (RFC 1542).

| Setting | Meaning |
| --- | --- |
| `DHCP_RELAY_LOCAL_ADDR` | required; this relay's own IPv4 address on the client network, sent as `giaddr` so the upstream server picks the pool of the client's subnet |
| `UPSTREAM_DHCP_IP` | required; the upstream DHCP server |

The render is one row, `dhcp-relay=<DHCP_RELAY_LOCAL_ADDR>,<UPSTREAM_DHCP_IP>`,
with no `dhcp-range` and no option injection. The upstream server owns the
lease and every option. Relay mode does not hand LanCache NG's DNS servers to
clients; configure them on the upstream server, or use `kea`. The relay needs
a route to `UPSTREAM_DHCP_IP`, and the upstream server needs a route back to
the client subnet via the relay.

Both dnsmasq modes are set through the Admin UI DHCP page (`POST /dhcp/proxy`
and `POST /dhcp/relay`). A general dnsmasq editor is not provided; the fields
above, PXE and the relay are the intended surface.

### 5.5 Verify that clients receive the DNS servers

1. On a client, renew the lease and read its DNS servers (`ipconfig /all` on
   Windows; `resolvectl status` or `cat /etc/resolv.conf` on Linux and macOS).
   They have to be the LanCache NG DNS addresses.
2. Resolve a cached CDN name from the client, for example
   `nslookup lancache.steamcontent.com`. The answer has to be the proxy
   address, not the real CDN.
3. Run the DHCP check on the Admin UI DHCP page (`POST /dhcp/check`). It probes
   for other DHCP servers and reports whether a client dry-run received the
   expected options. In `dnsmasq-proxy` mode it shows an upstream DNS option
   that overrides the proxy's. The check is a diagnostic on demand and does not
   gate Kea.

If a client does not take the LanCache NG DNS servers in `dnsmasq-proxy` mode,
that is the limit described in 5.3.

---

## 6. Known-good snapshots and rollback

A snapshot is a stored copy of a configuration that was applied successfully.
Snapshots are separate from the install backup (section 7): they keep a few
recent configurations of one subject, not the whole install.

### 6.1 Snapshot store

One store (`snapshot::Store`, `services/common/shared.rs`) owns the format:

- A snapshot id is a digit string, the nanoseconds since the Unix epoch; a
  longer or larger id is newer. A snapshot is one file named by the id, or a
  directory named by the id that holds one named file (`<dir>/<id>/<file>`).
- Saving creates the file exclusively (never overwrites) and then prunes old
  snapshots. Pruning keeps at least one snapshot, so a rollback target always
  exists.
- Reading accepts only numeric ids.

The Admin UI is the only user of the store:

| Subject | Store | Retention | Rollback |
| --- | --- | --- | --- |
| Kea DHCP configuration | `KEA_CONFIG_SNAPSHOT_DIR` (`KEA_CONFIG_SNAPSHOT_FILE`) | `KEA_SNAPSHOT_KEEP` (SOT 20) | Admin UI DHCP page (`POST /dhcp/kea-rollback`); `setup.sh reset-to-last-known-good-config kea` |
| Records of the lan zone (`DHCP_DOMAIN`) and the private reverse zones | `DNS_SNAPSHOT_DIR/<zone>` | `DNS_SNAPSHOT_KEEP` (SOT 20) | Admin UI domains page (`POST /domains/zone-rollback`); `setup.sh reset-to-last-known-good-config dns` |

Other zones, such as the RPZ, are not snapshotted. TSIG keys and zone metadata
are not part of a zone snapshot.

### 6.2 Kea

The Admin UI changes Kea through one path: read the running configuration
(`config-get`), edit, `config-test`, `config-set`, `config-write`, then save the
applied configuration as a snapshot. A rollback applies a stored snapshot
through the same path. DHCP changes from the Admin UI can therefore be undone
from the DHCP page.

### 6.3 Zones

A snapshot of the zone's record sets (as JSON) is taken after every record
change the Admin UI makes. DDNS writes from Kea go straight to PowerDNS and
create no snapshot.

A rollback sends one PATCH to PowerDNS: `REPLACE` for every snapshot record
set, `DELETE` for every current record set the snapshot lacks. PowerDNS raises
the serial and sends NOTIFY; the secondaries pull the zone by AXFR. A zone
rollback is never automatic: an older zone can undo leases and host names
created since.

### 6.4 Command line

`setup.sh reset-to-last-known-good-config` is the fallback when the Admin UI is
not reachable:

```bash
./setup.sh reset-to-last-known-good-config kea [install-dir] [snapshot-id] [--yes]
./setup.sh reset-to-last-known-good-config dns [install-dir] <zone> [snapshot-id] [--yes]
```

- `dhcp` is an alias of `kea`, `pdns` of `dns`.
- Without a snapshot id the newest is offered after a confirmation; `--yes`
  skips the prompt.
- `kea` lists the snapshots in `KEA_CONFIG_SNAPSHOT_DIR` on the host and
  applies the chosen one through the Kea control agent (`config-test`,
  `config-set`, `config-write`).
- `dns` runs the rollback through `lancache-ui` in the `ui` container.
  PowerDNS keeps snapshots per zone, so `<zone>` is required; without it the
  command lists the zones that have snapshots.

### 6.5 Settings without a consumer

The SOT and `deploy/prod/docker-compose.yml` define the snapshot directories
`PROXY_CONFIG_SNAPSHOT_DIR`, `DHCP_CONFIG_SNAPSHOT_DIR` and
`DNS_CONFIG_SNAPSHOT_DIR` with their volumes (`proxy-config-snapshots`,
`dhcp-config-snapshots`, `dns-config-snapshots`), and `setup.sh` writes
`KEEP_KNOWN_GOOD_CONFIGS` (default 3). No code in `services/` reads these
values: no automatic fall-back of nginx, dnsmasq or PowerDNS to an older
configuration exists in this tree.

---

## 7. Backup, restore and rollback

Mutable state lives outside the container images. Back it up before updates,
after configuration changes and before enabling scheduled automatic updates.

### 7.1 Commands

```bash
sudo /opt/lancache-ng/current/setup.sh update [install-dir]
sudo /opt/lancache-ng/current/setup.sh backup [--config|--full] [install-dir] [--dest /backup/path]
sudo /opt/lancache-ng/current/setup.sh restore <backup archive> [install-dir]
```

- Archives go to `/var/backups/lancache-ng` unless `--dest` is given. Set
  `LANCACHE_BACKUP_ROOT` to move the default for every command, including the
  automatic pre-update backup that `update` and `auto-update` roll back from.
- `update` takes the pre-update backup first, then updates the checkout when it
  sits on its channel's branch with no changed tracked files, and continues with
  the pulled `setup.sh`. A failed update returns the checkout to its previous
  revision together with the restored configuration. A checkout on another
  branch, or with changed tracked files, is left where it is.
- Each channel has its own code directory below the state root:
  `/opt/lancache-ng/latest` (from `master`) and `/opt/lancache-ng/nightly`
  (from `current_dev`). `/opt/lancache-ng/current` points to the one in use.
  When the channel changes, `update` moves the stack to the other directory and
  copies `deploy/prod/.env.local` and a compose override along. A failed move
  points `current` back, restores the pre-update backup and removes the copied
  files from the new directory.
- `backup` and `restore` check that the required archive tools exist. On an
  `apt-get` system a missing `tar` or `rsync` is installed first. `restore`
  also needs `openssl`, because converging an incomplete `.env` can generate
  missing service secrets.

### 7.2 Backup modes

| Mode | Content | Use |
| --- | --- | --- |
| `--config` (default) | configuration, certificates, secrets and service runtime databases; not the cache payload | before updates, rollback |
| `--full` | everything from `--config` plus the cache directory (`CACHE_DIR`, or `LANCACHE_STATE_DIR`), legacy split cache directories, `/srv/lancache/cache` and the volume `<project>_proxy-cache` | new hardware, or when losing cached objects is expensive; can be very large |

The `update` command creates the config backup before it pulls anything and
records the running image revisions in it (`image-revisions.txt`) before
`docker compose pull`.

### 7.3 What a backup contains

The manifest includes these paths when they exist:

- the active runtime env file (`.env` or `deploy/prod/.env.local`) and
  `docker-compose.yml`; backups of `deploy/prod` also include the repository
  runtime inputs the compose file reaches through `../../` (today
  `services/dns/cdn-domains.txt`);
- Docker named volumes of the compose project, including those of stopped
  containers. The cache volume is only archived in `--full` mode;
- `image-revisions.txt`;
- PowerDNS state (named volumes, `LANCACHE_STATE_DIR`, optional `PDNS_DIR` and
  `PDNS_FILTER_STATE_DIR`, legacy directories below `/srv/lancache`);
- Kea data (`LANCACHE_STATE_DIR`, optional `KEA_DATA_DIR`, legacy
  `/srv/lancache/kea`);
- the HTTPS CA (`ca.crt`, `ca.key`) from `LANCACHE_STATE_DIR` or `CA_DIR`;
- chrony and CacheHamster data (`LANCACHE_STATE_DIR`, optional `NTP_DATA_DIR`
  and `CACHEHAMSTER_DATA_DIR`, legacy `/srv/lancache/ntp` and
  `/srv/lancache/cachehamster`).

Not part of the manifest: the central log directory (`SYSLOG_NG_LOG_DIR`, or
`LANCACHE_STATE_DIR/syslog-ng`), because it is rotated application output, and
the snapshot volumes of section 6. Back up the logs manually when they have to
survive a host migration.

`backup` stops the compose stack before it copies mutable databases and
restarts it afterwards. Staging directories get restrictive permissions and are
removed when a copy fails. A destination inside a path being backed up is
rejected.

### 7.4 Restore

`restore` restores what the archive captured, including the shape `.env` had at
backup time. After restoring files and volumes it:

1. migrates an archived quickstart install into `deploy/prod` (the migration
   `update` performs);
2. converges `.env` through the path `update` uses (`migrate_env_for_update`,
   then `validate_compose_config`);
3. starts the stack.

Further behavior:

- An already converged backup is a no-op for the convergence; existing matching
  values are not rewritten.
- An already valid `LANCACHE_IMAGE_TAG` (`sha-*` or `vX.Y.Z`) is kept as
  restored and not re-resolved against `LANCACHE_IMAGE_CHANNEL`. A restore after
  a bad channel image therefore starts the previous tag. `update` does
  re-resolve the channel, because that is how a channel install picks up new
  images.
- If the archive has no `.env.local`, an existing `.env.local` at the target is
  renamed to `.env.local.pre-restore-<UTC-timestamp>` so the restored `.env`
  takes effect. The renamed file is never deleted.
- Without Docker or Compose for the target, a config-only restore still works;
  the compose validation and the stack start are skipped with a warning. Docker
  is required when the archive contains volume payloads.
- If convergence or validation fails, `restore` fails closed: it keeps the
  restored files and volumes as restored and leaves the stack **stopped**. Fix
  `.env`, then run `setup.sh update [install-dir]`.
- `restore` refuses when another install directory still has containers for the
  same fixed Compose project and volumes, even stopped ones. It also refuses a
  restore into a different install path while Docker still has volumes labeled
  for the archived project. Same-directory and cross-host restores are
  allowed; remove the old project's volumes first if they are no longer needed.
- Install paths of the archive are remapped to the `[install-dir]` argument,
  and matching absolute paths in the restored runtime env file are rewritten.

### 7.5 Roll back after a failed update

1. Find the automatic pre-update backup:

   ```bash
   sudo find /var/backups/lancache-ng -maxdepth 1 -name 'lancache-ng-config-*.tar.*' -print
   ```

2. Restore it:

   ```bash
   sudo /opt/lancache-ng/current/setup.sh restore /var/backups/lancache-ng/lancache-ng-config-YYYYMMDDTHHMMSSZ.tar.zst /opt/lancache-ng
   ```

3. Check the stack:

   ```bash
   sudo /opt/lancache-ng/current/setup.sh compose /opt/lancache-ng ps
   ```

If a scheduled automatic update caused the failure, disable it first
(`AUTO_UPDATE_ENABLED=0` in the runtime env, or answer "N" at the prompt of
`setup.sh install`), so the same update is not retried while you investigate.

To roll back to a different revision than the one in the backup, read
`image-revisions.txt` inside the archive, set `LANCACHE_IMAGE_TAG` to the wanted
`sha-<full-sha>`, release candidate or `vX.Y.Z` tag, and run
`setup.sh update [install-dir]`.

### 7.6 Test restores

Restore periodically on a spare host or VM, then check:

1. the stack is running (`restore` starts it after a successful convergence);
2. DNS answers on port 53;
3. the Admin UI answers on port 8080 (`UI_LISTEN_PORT`);
4. HTTP cache traffic works on port 80;
5. in HTTPS mode, clients still trust the restored `ca.crt`;
6. with DHCP enabled, the Kea configuration and leases are restored before DHCP
   is enabled on a production network.

### 7.7 Secrets and the CA

Backups contain secrets: the runtime env file, `DDNS_TSIG_KEY`, `PDNS_API_KEY`,
`SECONDARY_REGISTRATION_TOKEN`, the CacheHamster session key and sealed Steam
session token, optional Admin UI credentials and possibly `ca.key`. Store
backups off the host and encrypt them when they leave the server.

`ca.key` is highly sensitive: anyone holding it can issue certificates that
HTTPS-mode clients trust. Distribute `ca.crt` only. If `ca.key` is exposed,
generate a new CA, remove the old CA from the clients, install the new
`ca.crt` and restart the proxy.

---

## 8. OS and kernel network tuning

These are host-level options for the cache-proxy workload. They are
recommendations to test on the deployment host; none is applied by the stack.
The `proxy` service publishes its ports on Docker's default bridge network
(`${IP_HTTP}` and `${IP_HTTPS}` with the SOT ports); it uses neither
`network_mode: host` nor macvlan or ipvlan.

### 8.1 Docker `userland-proxy`

The SOT sets `docker_userland_proxy: false`. `setup.sh install` and `setup.sh
update` apply it to `docker_daemon_json` (`ensure_docker_userland_proxy`) after
a confirmation and restart Docker once; without a terminal they leave Docker
unchanged. With `userland-proxy: true` (Docker's default) published ports go
through `docker-proxy`. Unverified: `docker-proxy` may
present the container with a rewritten source address, which would turn the
source-address allowlist `PROXY_ALLOWED_CLIENT_CIDRS` into an all-or-nothing
filter instead of a per-client filter. The test below decides it.

Test on a deployment host, not on a busy shared runner: the change needs a
Docker daemon restart that stops every running container.

```bash
# before: note the client address nginx logs
curl -s http://<lancache-host>/some/cached/path -o /dev/null
tail -5 "${SYSLOG_NG_LOG_DIR}/LanCache-NG-proxy/$(date +%Y%m%d).log"

# apply: set "userland-proxy" in /etc/docker/daemon.json (setup.sh does this), then
sudo systemctl restart docker
docker compose -f deploy/prod/docker-compose.yml up -d

# after: repeat from the same client and compare the logged address
curl -s http://<lancache-host>/some/cached/path -o /dev/null
tail -5 "${SYSLOG_NG_LOG_DIR}/LanCache-NG-proxy/$(date +%Y%m%d).log"
```

nginx logs to stdout; Docker's `syslog` driver hands the log to syslog-ng in
`services`, which stores it under `SYSLOG_NG_LOG_DIR` in the directory named
after the proxy container. This needs `LOGGING_PROXY_ENABLED` on. If the
logged address is the real client address already, disabling the userland
proxy changes no behavior. If the address differs, record that as a separate
finding.

### 8.2 GRO, queues, RSS and XPS

Read the real values on the LAN-facing interface of the host:

```bash
sudo ethtool -i <iface>
sudo ethtool -k <iface> | grep -E 'tcp-segmentation|generic-segmentation|generic-receive|large-receive'
sudo ethtool -l <iface>
ls /sys/class/net/<iface>/queues/
```

- Generic receive offload coalesces incoming packets before the IP stack and
  lowers the CPU cost of bulk receive traffic. Enable it with
  `sudo ethtool -K <iface> gro on`, read it back with
  `sudo ethtool -k <iface> | grep generic-receive-offload`, and revert with
  `gro off`. Some interfaces refuse silently, so always read it back.
- RSS needs several hardware queues. With more than one, check that the
  interrupts are spread across CPUs (`cat /proc/interrupts | grep <iface>`, then
  `/proc/irq/<n>/smp_affinity`).
- XPS spreads outgoing traffic over several TX queues and has no effect on an
  interface with a single TX queue (`tx-0` only).

### 8.3 kTLS

kTLS lets the kernel handle TLS record framing for data served through
`sendfile()`. `services/ui/nginx/nginx.conf` sets `sendfile on;`.
`services/ui/nginx/conf.d/https.conf` has no `ssl_conf_command Options KTLS;`
directive, so kTLS is not enabled.

Preconditions to check on the host: the `tls` kernel module is loaded
(`grep tls /proc/modules`), the `proxy` image's OpenSSL was built with kTLS and
the nginx binary supports `ssl_conf_command` (`docker run --rm --entrypoint
nginx <proxy image> -V`). Enabling kTLS is a change to `https.conf` plus a
runtime check; the directive alone does not prove that it engages:

```bash
cat /proc/net/tls_stat    # TlsCurrTxSw and TlsCurrRxSw rise during HTTPS cache hits
```

### 8.4 RPS

RPS spreads the protocol processing of a single receive queue across CPUs.
Compute the mask from the host's real online CPUs; do not copy a mask from
another host.

```bash
IFACE=eth0
# the online range, for example "0-7" or "0-3,8-11"
online="$(cat /sys/devices/system/cpu/online)"
mask=0
IFS=',' read -ra ranges <<< "$online"
for r in "${ranges[@]}"; do
  if [[ "$r" == *-* ]]; then lo="${r%-*}"; hi="${r#*-}"; else lo="$r"; hi="$r"; fi
  for ((cpu=lo; cpu<=hi; cpu++)); do mask=$(( mask | (1 << cpu) )); done
done
printf 'Computed rps_cpus mask: %x\n' "$mask"

for q in /sys/class/net/"$IFACE"/queues/rx-*; do
  echo "$mask" | sudo tee "$q/rps_cpus" >/dev/null
  echo "$q -> $(cat "$q/rps_cpus")"   # read back
done
```

- Read the value back after every write. A mask with bits for offline CPUs is
  masked silently.
- Exclude the CPU that handles the NIC's hardware interrupt from its own mask
  only if `/proc/interrupts` shows that mapping for the NIC.
- RFS needs `/proc/sys/net/core/rps_sock_flow_entries`; the per-queue
  `rps_flow_cnt` is `rps_sock_flow_entries` divided by the number of RX queues.
- An unprivileged container cannot write these knobs; run the commands on the
  host.

### 8.5 Connection tracking

The fill level of the connection-tracking table is not monitored: the stack
has no alarm for it.

```bash
cat /proc/sys/net/netfilter/nf_conntrack_count
cat /proc/sys/net/netfilter/nf_conntrack_max
```

Run both commands on the deployment host under real client load; the ratio is
the utilization.

### 8.6 macvlan, ipvlan and host networking

nginx reads the destination from `Host` or the SNI (AG-KD-004), so the stack
does not need a preserved original destination address, which is what macvlan
or ipvlan would provide. Moving the `proxy` service to macvlan, ipvlan or
`network_mode: host` changes the address and MAC exposure on the LAN and the
two-address `IP_HTTP` and `IP_HTTPS` design; the bridge setup is the supported
one.

---

## 9. Open verification

Not verified against the code or a running stack:

- the backup manifest paths of section 7.3 (`/srv/lancache/*`, the legacy
  directories) and the restore guard conditions of section 7.4;
- the channel directory move of `update` (section 7.1) beyond the `current`
  link handling;
- the tuning options of section 8 (kTLS preconditions, RPS, RFS, GRO), which are
  host and kernel facts;
- the Admin UI's field validation messages for the dnsmasq modes;
- the `setup.sh` prompts of the Kea preflight and the log wording of the `dhcp`
  container;
- the behavior of the tuning commands in section 8 on a given host and NIC.

## Howto audit this file

The audit procedure of this file is `docs/policy/howto-audit-documentation.md`.
