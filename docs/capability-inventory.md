# LanCache-NG Capability Inventory (reviewed 2026-11-07 against `current_dev` `3005b2b4`)

This document is the consolidated capability inventory for LanCache-NG.

It replaces the former component-specific files under
`docs/capability-inventory/SoT-*.md`.

The inventory describes the capabilities that exist in the `current_dev`
implementation at the commit named above. It is a function-level companion to
`docs/architecture-ng.md`, not a replacement for the higher-level architecture
documentation. LanCache-NG runs as exactly five containers (`services`,
`proxy`, `dns`, `dhcp`, `ui`); the programs of each container are listed in
`docs/architecture-ng.md`. Security findings that this review made are tracked
in `docs/threat-model.md` ("Gaps statically indicated") and are only referenced here.

Historical audit notes, already-resolved findings, temporary investigation
state, and old implementation snapshots are intentionally not retained here.
Git history and the corresponding issues and pull requests remain the source
for that historical context.

If this document conflicts with the current implementation, the implementation
is authoritative and this document should be corrected.

## Component overview

| Component          | Primary purpose                                                   | Runtime (container)               | State                    |
| ------------------ | ----------------------------------------------------------------- | --------------------------------- | ------------------------ |
| Proxy              | HTTP caching, (SNI passthrough, TLS interception - Optional)      | nginx (`proxy`)                   | Production               |
| DNS                | Cache DNS, authoritative LAN DNS, RPZ, replication                | PowerDNS (`dns`)                  | Production               |
| DHCP               | Native DHCPv4 server and DDNS                                     | Kea (`dhcp`)                      | Optional production mode |
| DHCP Proxy / Relay | ProxyDHCP, PXE and DHCP relay                                     | dnsmasq (`dhcp`)                  | Optional production mode |
| Admin UI           | Web control plane, config rendering and configuration management  | Rust (`ui`)                       | Production               |
| Watchdog           | Container health, restarts, disk and certificate checks, cleanup  | Rust (`services`)                 | Production               |
| Central Logging    | Log collection, normalization and retention                       | syslog-ng (`services`)            | Production               |
| NTP                | LAN time service and optional host clock discipline               | chrony (`services`)              | Optional production mode |
| SNMP statistics    | Host and container figures for the Admin UI graphs                | snmpd (`services`, `dns`)         | Production               |
| CacheHamster       | Steam cache-prefill engine                                        | Rust (`services`)                 | In code and wired; see section |
| setup.sh           | Installation and lifecycle orchestration                          | Bash (host)                       | Production               |

## Proxy

### Purpose

`services/proxy` provides the caching data plane.

A single nginx-based image supports both normal passthrough operation and
TLS-interception operation. The active behavior is selected at runtime rather
than being implemented as separate proxy images.

### Current capabilities

The proxy provides:

* HTTP content caching.
* HTTP-mode HTTPS forwarding through nginx stream and SNI inspection.
* HTTPS-mode TLS interception using the LanCache-NG local certificate authority.
* Automatic certificate generation for configured cache domains.
* Cache-domain matching based on `services/dns/cdn-domains.txt`.
* Public-suffix-aware certificate and domain handling.
* Cache hit and miss logging.
* Cache storage on a persistent volume.
* Persistent CA and generated certificate storage.
* nginx configuration rendered from templates; a bad value stops the render with an error (`nginx_conf::template`).
* Health endpoints consumed by Docker, the UI and watchdog.
* Access restrictions for proxy clients and management endpoints.
* Integration with central logging.
* Admin UI visibility for cache status, requests and cache utilization.

The current image uses Alpine and nginx.org's mainline nginx package. The
stream and SSL preread modules required by HTTP mode are compiled directly
into that nginx build.

### HTTP mode

HTTP mode does not terminate the client TLS connection.

nginx inspects the requested SNI name and forwards the encrypted connection to
the requested upstream host. No locally generated certificate is presented to
the client.

This mode avoids installing the LanCache-NG CA on clients but can only cache
traffic that is available through non-intercepted HTTP paths or other supported
cache flows.

### HTTPS mode

HTTPS mode terminates client TLS using certificates generated from the local
LanCache-NG CA.

The client must trust that CA.

For configured cache domains, nginx can then process and cache the HTTP content
inside the TLS connection.

### Domain handling

The proxy and DNS services consume the same cache-domain source.

Entries may represent exact hosts or wildcard-style domain coverage. The proxy
derives the certificate and routing information required for those entries.

### Known limitation

Static X.509 wildcard certificates only cover one additional DNS label.

A leading-dot domain entry can match DNS names at arbitrary depth, while a
single pre-generated wildcard certificate cannot cover arbitrary TLS hostname
depth. Deeper names therefore require an explicitly covered level unless the
architecture is eventually changed to dynamic certificate issuance.

## DNS

### Purpose

`services/dns` provides both recursive cache-routing DNS and authoritative DNS
for LanCache-NG-managed zones.

The service combines:

* PowerDNS Recursor.
* PowerDNS Authoritative Server.
* RPZ generation and processing.
* LAN and reverse-zone management.
* Native PowerDNS primary/secondary replication.

### DNS instances

The normal deployment contains one DNS container:

* `dns`

`dns` is the writable authoritative primary. It serves the http and the https
side from the same container.

Remote secondary nodes (`setup.sh secondary`) operate as PowerDNS secondaries
for the replicated authoritative data.

This replaces the older model where both instances independently received and
applied the same record mutations.

### Native replication

Authoritative data is replicated using PowerDNS native primary/secondary
operation.

The implementation includes:

* TSIG-protected AXFR and NOTIFY.
* `dns` as the single writable primary.
* Remote `dns` nodes as secondaries.
* Kea DDNS writes directed to the primary.
* Secondaries never write records; they only pull zones (single writer).
* Replication information supplied to registered remote secondaries.
* SOA-based refresh behavior so replication does not depend exclusively on a
  NOTIFY packet being delivered.

### Cache-domain routing

`cdn-domains.txt` defines the domains that LanCache-NG redirects toward the
cache path.

The DNS service generates the corresponding RPZ state and supports the
project's exact-domain and wildcard-domain semantics.

### LAN DNS

The authoritative service manages the LAN zone and private reverse zones.

Supported functionality includes:

* A records.
* PTR records.
* DHCP-generated forward records.
* DHCP-generated reverse records.
* Admin UI-managed LAN records.
* Manual PTR management.
* Record removal.
* Zone snapshots.
* Zone rollback.
* TSIG-authenticated DDNS from Kea.

### AAAA filtering

The recursor contains configurable AAAA filtering for environments where
selected cache traffic should remain IPv4-only.

This is separate from DHCP, which is currently an IPv4-only subsystem.

### Runtime hardening status

The DNS image uses Alpine. OpenRC starts `pdns`, the two recursors (`dns-http`,
`dns-https`) and `snmpd`; the program list is the SOT field `processes`. The
`dns` container does not run the watchdog.

The PowerDNS processes currently do not use a Dockerfile-level `USER`
directive. Further non-root execution remains a hardening area because the DNS
daemons also need to bind and operate on privileged DNS ports.

## DHCP

### Purpose

`services/dhcp` provides the native LanCache-NG DHCP server using Kea DHCPv4.

It is one selectable DHCP mode and is mutually exclusive with the dnsmasq
ProxyDHCP and relay modes.

### Runtime components

The service runs:

* Kea DHCPv4.
* Kea Control Agent.
* Kea DHCP-DDNS.

OpenRC in the `dhcp` container starts the programs of the selected mode.
The `ui` renders their configuration (`kea_conf` in `services/common/shared.rs`) and writes it to the `lancache-config` volume.

### Admin UI capabilities

The Admin UI provides management for:

* DHCP subnets.
* Address pools.
* Default gateways.
* DNS server options.
* NTP server options.
* Domain options.
* Lease lifetime settings.
* Static MAC-to-IP reservations.
* Custom DHCP options.
* Active lease listing.
* Active lease release.
* DHCP mode switching.
* Configuration snapshots.
* Snapshot rollback.

Kea configuration changes are applied with `config-set` and persisted with `config-write` (`kea::Api::set_config`).

A known-good snapshot of the Kea configuration can be restored from the Admin UI (`kea-rollback`).

### Kea Control Agent

The Admin UI uses the Control Agent for live configuration operations such as:

* `config-get`
* `config-set`
* `config-write`
* `lease4-get-all`
* `lease4-del`

The Control Agent is meant as an internal management interface. In the current
code it is bound to `KEA_CTRL_ADDRESS` (SOT default `0.0.0.0`) on the host
network, its configuration has no `authentication` block, and the UI client
sends no credentials; see gap G2 in `docs/threat-model.md`.

### DDNS

Kea D2 provides forward and reverse DNS updates.

Updates are TSIG authenticated and are directed at the writable PowerDNS
primary. Native PowerDNS replication distributes the resulting authoritative
state to DNS secondaries.

### Configuration persistence

Kea's main DHCP configuration is migrated rather than blindly regenerated on
every container start so operator-created subnets and reservations survive
updates.

Configuration changes can create known-good snapshots that are shared by the
Admin UI rollback flow and operator recovery tooling.

### DHCP probe

The old external `dhclient` and `nmap` based probe has been replaced by native
Rust DHCP probing.

The probe can test for responding DHCP servers and exercise the real DHCP
client path without configuring the host interface with the obtained lease.

### Scope limitation

LanCache-NG DHCP currently implements DHCPv4.

DHCPv6, Kea HA pairs and Kea client-class management are not part of the
current exposed product surface.

## DHCP Proxy and DHCP Relay

### Purpose

The `dhcp` image (`services/dhcp`) also runs dnsmasq for two distinct modes:

* ProxyDHCP and PXE assistance alongside an existing DHCP server.
* Real DHCP relay operation toward an upstream DHCP server.

These are separate runtime modes of the same service.

### ProxyDHCP mode

ProxyDHCP mode leaves lease ownership with the existing DHCP server.

LanCache-NG can provide supplemental PXE-related information including:

* DNS server options.
* Router option.
* NTP server option.
* Domain option.
* Custom DHCP options.
* Boot server.
* Boot filename.
* Architecture-specific PXE boot information.

PXE support includes BIOS, UEFI x86-64 and UEFI ARM64 paths.

### DHCP relay mode

Relay mode forwards DHCP traffic to the configured upstream DHCP server.

The relay uses the configured local relay address and upstream target instead
of acting as the lease-owning DHCP server itself.

### Configuration safety

A value that cannot be rendered stops the render with an error
(`dnsmasq_conf::render`); it is not written to the config volume.

Configuration values passed from the Admin UI are parsed as data rather than
executed as shell input.

The snapshot store (`snapshot::Store`) is used for DNS zones and for Kea
(`zone_store`, `kea_store`); no dnsmasq snapshot is kept.

### Test coverage

`current_dev` holds no PXE or packet-level tests: there is no `tests/`
directory and no Rust test function under `services/`. The PXE and ProxyDHCP
behavior described here is verified by reading `dnsmasq_conf::pxe` and
`dnsmasq_conf::render`, not by a simulation.

### UI scope

Normal DHCP mode selection and dnsmasq configuration are exposed through the
Admin UI.

Some advanced PXE-specific settings remain more naturally operator and setup
configuration than full first-class UI controls.

## Admin UI

### Purpose

`services/ui` is the LanCache-NG control plane.

It is a Rust web application that combines operator-facing configuration,
service state, metrics, logs and controlled interactions with the runtime
stack.

### Major capability areas

The UI provides:

* Authentication (HTTP Basic with an Argon2id hash; the fail-closed start check is missing, see gap G1 in `docs/threat-model.md`).
* CSRF protection.
* Dashboard and service state.
* Proxy status and cache visibility.
* DNS domain management.
* LAN DNS record management.
* PTR record management.
* DNS snapshot and rollback operations.
* DHCP mode selection.
* Kea subnet management.
* DHCP reservations.
* DHCP options.
* DHCP lease visibility and release.
* Secondary registration management.
* Per-secondary credential rotation and revocation.
* Secondary address management and probing.
* Runtime log views.
* Watchdog-collected statistics.
* Setup and configuration visibility.
* Update and image-channel information.
* Controlled container lifecycle operations.

### Container control

The Admin UI mounts the Docker socket read-write; there is no socket proxy
(`deploy/prod/docker-compose.yml`). Through `docker::Api` it lists the compose
project, reads container state and stats, starts, stops, restarts or reloads
(HUP) containers and runs commands in them (for example the CacheHamster
commands). The `services` container mounts the socket too, for the watchdog.
The security consequences are described in `docs/threat-model.md` (T6).

### Configuration ownership

The Admin UI saves only the changed settings in its data volume
(`UI_SETTINGS_FILE`); precedence per key is that file, then the container
environment, then the SOT default. It renders every config from the SOT and the
saved settings (`render::all`), writes the changed files into the
`lancache-config` volume and wakes only the owner containers with the strongest
action they need (reload or restart, `apply::plan`). The owner containers mount
that volume read-only.

Configuration that can be safely applied live is not treated the same as
configuration that requires a container lifecycle operation.

### DNS integration

The UI can manage authoritative LAN records and publishes the required
control-plane updates through the DNS integration path.

DNS secondaries are not independent write targets. Native PowerDNS replication
owns replicated authoritative state.

### Secondary management

For each secondary the UI tracks:

* Name.
* Registration time.
* Last-seen state where available.
* Reachable private DNS address.
* Credential state.

Registration responses include the information required by a secondary
installation, including:

* Primary address and the list of replicated zones.
* PowerDNS API key.
* TSIG key name and secret for transfers and DDNS.
* Syslog target on the primary.
* The local reverse-zone setting.
* Image registry, prefix, channel and tag.

### Remaining registration limitation

The initial registration endpoint still authenticates using the shared
secondary registration token.

Removing a secondary does not affect the others, but the bootstrap
authorization itself is not yet a one-time token bound to one pre-authorized
secondary identity.

## Watchdog

### Purpose

`services/watchdog` provides stack health monitoring and controlled recovery.

The watchdog is implemented in Rust.

### Current capabilities

The watchdog:

* Reads service health through the Docker control path.
* Tracks health state over time.
* Applies restart policy only where automatic recovery is intended.
* Reports service state for UI consumption.
* Distinguishes restart-managed services from alert-only services.
* Covers the core proxy and DNS path.
* Covers the Docker control dependency.
* Includes UI visibility.
* Includes profile-dependent DHCP, DHCP proxy and central logging visibility.

### Recovery behavior

A service becoming unhealthy does not automatically imply that every service
is restartable.

The watchdog keeps service observation separate from the decision to perform a
restart. This allows infrastructure that should only be surfaced to the
operator to remain alert-only.

### Cleanup

Once a day the watchdog purges old cache files (`purge_cache`) and prunes and
packs logs (`prune_logs`). There is no separate retention process: the
`services` container runs the watchdog, CacheHamster, syslog-ng, chronyd and
snmpd.

## Central Logging

### Purpose

syslog-ng inside the `services` container provides centralized collection of
logs from LanCache-NG services. The Admin UI renders its configuration (`log::render`) and
OpenRC supervises it.

### Current capabilities

The logging path provides:

* Central service log collection.
* Normalized log files.
* Proxy request log processing.
* Inputs used by the Admin UI log viewer.
* Logging switches per service in the Admin UI.
* Log retention (age and size budget).

Service logs remain useful through their normal container output as well. The
central logging path is an additional consolidated operator view rather than a
reason for individual services to become silent.

## NTP

### Purpose

chronyd inside the `services` container provides a LAN NTP server.

It can synchronize against configured upstream time sources and serve time to
LAN clients on UDP port 123.

### Current implementation

The `services` image installs Alpine's `chrony-nts` package.

Installing the NTS-capable package preserves cryptographic NTS capability for
future use even though the current LanCache-NG chrony configuration does not
enable NTS.

### Host clock discipline

Containers share the host kernel clock.

When LanCache-NG is allowed to discipline time, the NTP service therefore
changes the host clock rather than an isolated container-local clock.

The deployment uses explicit capabilities for this instead of assuming the
container can modify system time by default.

### Operational scope

NTP is optional and independent of the caching data path.

Disabling NTP does not disable proxying, DNS or the Admin UI.

## CacheHamster

### Status

`services/cachehamster` is the Steam pre-cache daemon. `lancache-cachehamster`
runs in the `services` container (`daemon` mode, started by OpenRC) and the
Admin UI has a CacheHamster page. The UI runs the daemon's commands in the
`services` container through the Docker API (`hamster`, `exec_in`).

This review read the code; it did not run a prefill. No test exists for it on
`current_dev`, so end-to-end prefill behavior is not verified here.

### Design

CacheHamster is stream-and-discard:

1. Resolve game or depot content.
2. Fetch that content through the LanCache-NG cache path.
3. Read the response stream completely.
4. Discard the received payload locally.
5. Let the proxy cache the transferred content.

The prefill service itself must not create a second persistent copy of the
downloaded game data.

### Implemented capabilities (in code)

* Steam login by QR code (`login_begin`, `login_poll`) with the session stored
  sealed on disk (`secret::seal`).
* Library listing of the logged-in account (`library`).
* App and depot resolution through the Steam connection manager (`app_info`,
  `depots_of`), manifest request codes (`request_code`) and chunk lists from the
  zipped binary manifest (`chunks_of`, `app_urls`).
* A job queue with orders now, later or at a time, a time window and pacing
  (`When`, `Job`, `window`, `Pace`).
* Streaming URL fetches with byte counting and a throughput rate that discard
  the payload (`run_urls`, `count`).
* Direct URL jobs.
* A JSON command interface (`status`, orders) used by the Admin UI.

## setup.sh

### Purpose

`setup.sh` is the primary operator lifecycle and deployment orchestrator.

It owns the transition from a repository or release checkout to a validated,
persistent LanCache-NG installation.

### Main responsibilities

The script handles:

* Host requirement checks (`install-requirements-primary`,
  `install-requirements-secondary`).
* Initial installation.
* Runtime configuration generation.
* Image-channel and image-tag resolution.
* Updates and scheduled updates (`update`, `auto-update`, host units for
  `systemd` or OpenRC).
* IP changes (`update-ip`).
* Configuration migration.
* Backup and restore.
* Secondary installation (`secondary`).
* Upstream DNS configuration (`configure-upstream-dns`).
* DHCP mode configuration.
* Runtime convergence (`converge`).
* Recovery operations, including `reset-to-last-known-good-config`.
* Log bundles for issue reports (`create-logs-for-issue`).

### Deployment layouts

The current repository uses the production (`deploy/prod`) and secondary
(`deploy/secondary`) deployment layouts. The former `deploy/dev` and
`deploy/full-setup` layouts are gone; development no longer depends on
maintaining a second parallel copy of the complete runtime stack.

### Idempotence and convergence

Repeated setup and update operations are expected to converge toward the same
desired configuration rather than continually creating new state.

Existing operator configuration is preserved where a component explicitly owns
mutable state.

Generated state is regenerated where it is fully derived from current inputs.

These two classes must not be confused during updates.

### Backup and restore

Backup and restore cover persistent LanCache-NG state rather than merely
copying the checked-out repository.

Restore performs ownership and deployment checks to avoid silently attaching a
new installation to state still owned by another active Compose installation.

### Secondary installation

The secondary setup flow registers with the primary and receives the values
needed to construct its local deployment.

This includes runtime credentials, DNS replication information and release
image coordinates.

The secondary flow no longer assumes that a user manually understands and
assembles the internal DNS configuration from scratch.

## Cross-component data flows

### Client cache request

```text
Client
  -> DNS
  -> Proxy
  -> Upstream CDN
  -> Proxy cache
  -> Client
```

DNS determines whether a configured domain is directed toward LanCache-NG.

The proxy then either serves cached data or retrieves the object from the
upstream source and stores eligible content.

### DHCP to DNS

```text
Client
  -> Kea DHCPv4
  -> Kea DDNS
  -> dns
  -> PowerDNS native replication
  -> remote secondary DNS nodes
```

The writable DNS primary is the single authority for replicated zone changes.

### Admin UI DNS change

```text
Operator
  -> Admin UI
  -> DNS control plane
  -> dns
  -> PowerDNS replication
  -> DNS secondaries
```

### Remote secondary registration

```text
Secondary setup
  -> Primary Admin UI
  -> registration bootstrap
  -> TSIG key and primary address
  -> DNS replication parameters
  -> secondary deployment
```

### Observability

```text
Service logs
  -> Central logging
  -> normalized log data
  -> Admin UI

Service health
  -> Docker health state
  -> Watchdog
  -> status and controlled recovery
```

### Prefill

```text
Operator
  -> CacheHamster
  -> Steam content resolution
  -> cache-routed HTTP fetch
  -> Proxy
  -> cached object

CacheHamster receives and discards the response body.
```

The Steam content-resolution portion of this flow exists in the code
(`app_info`, `request_code`, `chunks_of`, `app_urls`); it was not run in the
2026-11-07 review.

## Capability boundaries

The following boundaries are intentional or currently unresolved:

1. DHCP is IPv4-only. DHCPv6 is not part of the current product surface.

2. The proxy uses pre-generated certificates. Arbitrary-depth wildcard TLS
   matching cannot be completely represented by a finite set of ordinary
   wildcard certificates.

3. DNS processes currently start without a Dockerfile-level non-root user.
   Further least-privilege work must preserve binding and PowerDNS behavior.

4. Secondary bootstrap still uses a shared registration token even though
   each secondary can be removed on its own.

5. NTP installs an NTS-capable chrony build, but the current runtime
   configuration does not yet use NTS.

6. Some advanced PXE-specific configuration is not exposed with the same UI
   depth as the normal DHCP mode and Kea configuration.

7. CacheHamster is implemented in code and wired into the `services` container, but
   it has no test on `current_dev`; treat prefill as unverified until it has been run.

8. Admin UI login enforcement and Kea Control Agent protection are not
   fail-closed in the current code; see gaps G1 and G2 in
   `docs/threat-model.md`.

## Validation coverage

On `current_dev` validation is done by `.github/scripts/ci.sh`; there is no
`tests/` directory and no Rust test function under `services/`.

* `ci.sh check all` runs 42 named checks, among them `line-endings`,
  `comments`, `governance-guards`, `compose-config`, `compose-healthchecks`,
  `proxy-nginx-policy`, `prod-state-wiring`, `setup-update-safety`,
  `logging-matrix`, `vex-drift`, `cargo-audit`, `shellcheck` and `actionlint`.
* `.github/scripts/ci.bats` holds 4 tests.
* `ci.sh validate` validates the assembled stack.

A capability should not be considered fully validated merely because its
configuration renders successfully. Where behavior depends on real network
traffic, service interaction or persistence, validation should exercise that
behavior directly. Capabilities in this document that no check covers (for
example DHCP, PXE, replication and CacheHamster) are described from the code,
not from a test result.

## Maintenance model

This file should remain the single function-level capability inventory.

New services or substantial new subsystem capabilities should be added here
instead of creating another permanent `SoT-<component>.md` document.

Component-specific design documents are still appropriate when they describe a
real architecture decision, protocol, migration plan or implementation design
that cannot be expressed clearly in this inventory.

Temporary audits, issue investigations and implementation notes should remain
in their issue or pull request history rather than becoming new permanent
top-level documentation files.

The intended documentation split is therefore:

* `docs/architecture-ng.md`: system architecture and high-level relationships.
* `docs/capability-inventory.md`: current implemented capability surface.
* Dedicated design documents: only for substantial designs that need their own
  lifecycle.
* GitHub issues and pull requests: investigation history, findings and
  implementation chronology.
