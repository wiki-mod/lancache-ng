# LanCache-NG Capability Inventory (stated 16.09.2026, WIP)

This document is the consolidated capability inventory for LanCache-NG.

It replaces the former component-specific files under
`docs/capability-inventory/SoT-*.md`.

The inventory describes the capabilities that exist in the current
`current_dev` implementation after the v0.3.0 development cycle. It is a
function-level companion to `docs/architecture-ng.md`, not a replacement for
the higher-level architecture documentation.

Historical audit notes, already-resolved findings, temporary investigation
state, and old v0.2.0 implementation snapshots are intentionally not retained
here. Git history and the corresponding issues and pull requests remain the
source for that historical context.

If this document conflicts with the current implementation, the implementation
is authoritative and this document should be corrected.

## Component overview

| Component          | Primary purpose                                                   | Runtime                   | State                    |
| ------------------ | ----------------------------------------------------------------- | ------------------------- | ------------------------ |
| Proxy              | HTTP caching, (SNI passthrough, TLS interception - Optional)      | nginx                     | Production               |
| DNS                | Cache DNS, authoritative LAN DNS, RPZ, replication                | PowerDNS, Rust subscriber | Production               |
| DHCP               | Native DHCPv4 server and DDNS                                     | Kea                       | Optional production mode |
| DHCP Proxy / Relay | ProxyDHCP, PXE and DHCP relay                                     | dnsmasq                   | Optional production mode |
| NATS               | Internal event bus, authentication and remote-secondary messaging | NATS Server               | Production               |
| Admin UI           | Web control plane and configuration management                    | Rust                      | Production               |
| Watchdog           | Service health monitoring and recovery                            | Rust                      | Production               |
| Netdata            | Runtime metrics and system observability                          | Netdata                   | Production               |
| Central Logging    | Log collection, normalization and retention                       | syslog-ng, Fluent Bit     | Production               |
| NTP                | LAN time service and optional host clock discipline               | chrony                    | Optional production mode |
| CacheHamster       | Future Steam cache-prefill engine                                 | Rust                      | Scaffold only            |
| setup.sh           | Installation and lifecycle orchestration                          | Bash                      | Production               |

## Proxy

### Purpose

`services/proxy` provides the caching data plane.

A single nginx-based image supports both normal passthrough operation and
TLS-interception operation. The active behavior is selected at runtime rather
than being implemented as separate proxy images.

### Current capabilities

The proxy provides:

* HTTP content caching.
* Standard-mode HTTPS forwarding through nginx stream and SNI inspection.
* SSL-mode TLS interception using the LanCache-NG local certificate authority.
* Automatic certificate generation for configured cache domains.
* Cache-domain matching based on `services/dns/cdn-domains.txt`.
* Public-suffix-aware certificate and domain handling.
* Cache hit and miss logging.
* Cache storage on a persistent volume.
* Persistent CA and generated certificate storage.
* Config validation before nginx starts.
* Known-good configuration snapshots and rollback support.
* Health endpoints consumed by Docker, the UI and watchdog.
* Access restrictions for proxy clients and management endpoints.
* Integration with central logging and Netdata.
* Admin UI visibility for cache status, requests and cache utilization.

The current image uses Alpine and nginx.org's mainline nginx package. The
stream and SSL preread modules required by standard mode are compiled directly
into that nginx build.

### Standard mode

Standard mode does not terminate the client TLS connection.

nginx inspects the requested SNI name and forwards the encrypted connection to
the requested upstream host. No locally generated certificate is presented to
the client.

This mode avoids installing the LanCache-NG CA on clients but can only cache
traffic that is available through non-intercepted HTTP paths or other supported
cache flows.

### SSL mode

SSL mode terminates client TLS using certificates generated from the local
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
* A Rust NATS subscriber.
* RPZ generation and processing.
* LAN and reverse-zone management.
* Native PowerDNS primary/secondary replication.

### DNS instances

The normal deployment contains two logical DNS instances:

* `dns-standard`
* `dns-ssl`

`dns-standard` is the writable authoritative primary.

`dns-ssl` operates as a PowerDNS secondary for replicated authoritative data.

This replaces the older model where both instances independently received and
applied the same record mutations.

### Native replication

Authoritative data is replicated using PowerDNS native primary/secondary
operation.

The implementation includes:

* TSIG-protected AXFR and NOTIFY.
* `dns-standard` as the single writable primary.
* `dns-ssl` as a secondary.
* Kea DDNS writes directed to the primary.
* Secondary-side NATS record writes disabled to maintain the single-writer
  model.
* Replication information supplied to registered remote secondaries.
* SOA-based refresh behavior so replication does not depend exclusively on a
  NOTIFY packet being delivered.

NATS remains part of the DNS control plane, but it is no longer intended to
create a second independent writer on a replicated PowerDNS secondary.

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

### NATS subscriber

The Rust subscriber handles control-plane DNS record events and other
NATS-driven DNS integration.

Record writes can be disabled for nodes that are native PowerDNS secondaries,
preventing the same zone from having multiple independent writers.

### Runtime hardening status

The DNS image uses Alpine and builds the Rust subscriber for musl.

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

The entrypoint owns configuration rendering, migrations, secret handling and
process supervision.

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

Kea configuration modifications follow a validate, apply and persist flow.

A failed persistent write does not simply leave the in-memory service state as
the accepted configuration. The modification layer contains rollback and
ambiguous-failure handling.

### Kea Control Agent

The Admin UI uses the Control Agent for live configuration operations such as:

* `config-get`
* `config-test`
* `config-set`
* `config-write`
* `lease4-get-all`
* `lease4-del`

The Control Agent is an internal management interface and is not intended as a
general LAN-facing API.

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

`services/dhcp-proxy` uses dnsmasq for two distinct modes:

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

The service validates generated dnsmasq configuration before accepting it.

It also supports known-good configuration snapshots and rollback.

Configuration values passed from the Admin UI are parsed as data rather than
executed as shell input.

### Test coverage

The project includes function-level coverage for configuration generation and
real packet-oriented PXE simulations.

A dedicated UEFI-only packet-level scenario remains less thoroughly exercised
than the normal combined BIOS and UEFI path.

### UI scope

Normal DHCP mode selection and dnsmasq configuration are exposed through the
Admin UI.

Some advanced PXE-specific settings remain more naturally operator and setup
configuration than full first-class UI controls.

## NATS

### Purpose

`services/nats` is the internal messaging and authentication backbone used by
multiple LanCache-NG components.

It is not an operator-facing message broker for arbitrary application traffic.

### Current uses

NATS is used for:

* DNS control-plane events.
* Remote secondary communication.
* Authentication callout.
* Per-secondary credentials.
* Secondary connection lifecycle.
* Internal event publication.
* Selected service coordination.

### Authentication callout

The Admin UI acts as the authentication decision point for remote secondary
NATS identities.

Each registered secondary receives its own NATS username and generated
password.

Only the password hash is persisted by the primary. The plaintext password is
returned to the secondary during registration and is not stored for later
display.

Removing or rotating one secondary does not require replacing the credentials
of every other secondary.

The primary can actively disconnect a removed secondary so an already-open
connection does not remain usable until its next natural reconnect.

### Secondary bootstrap

Secondary registration still begins with a primary-wide registration token.

After successful registration the secondary receives its own runtime identity
and the connection information required for NATS, DNS replication and image
selection.

The bootstrap token is therefore distinct from the per-secondary NATS
credential.

### Generated NATS configuration

The UI generates the static NATS configuration required for the server,
including the authentication callout and internal roles.

Normal secondary registration, rotation and removal no longer require
regenerating the entire NATS configuration for each credential change.

## Admin UI

### Purpose

`services/ui` is the LanCache-NG control plane.

It is a Rust web application that combines operator-facing configuration,
service state, metrics, logs and controlled interactions with the runtime
stack.

### Major capability areas

The UI provides:

* Authentication.
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
* Netdata-backed statistics.
* Setup and configuration visibility.
* Update and image-channel information.
* Controlled container lifecycle operations.

### Container control

The UI does not receive unrestricted Docker socket access.

Runtime operations are routed through the project's narrowed Docker socket
proxy and are limited to the operations that the UI actually needs.

### Configuration ownership

The UI writes persistent operator settings into its data volume and coordinates
service-specific configuration changes through the corresponding service APIs
or controlled restart/reload paths.

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
* NATS identity.
* Registration time.
* Last-seen state where available.
* Reachable private DNS address.
* Credential state.

Registration responses include the information required by a secondary
installation, including:

* Reachable NATS endpoint.
* Per-secondary NATS credential.
* Proxy IP.
* PowerDNS API key where required.
* Shared DDNS and transfer TSIG key.
* DNS transfer primary.
* Image registry and image-channel information.

### Remaining registration limitation

The initial registration endpoint still authenticates using the shared
secondary registration token.

Per-secondary NATS credentials are unique, but the bootstrap authorization
itself is not yet a one-time token bound to one pre-authorized secondary
identity.

## Watchdog

### Purpose

`services/watchdog` provides stack health monitoring and controlled recovery.

The production watchdog is implemented in Rust. The older Bash watchdog is
historical implementation material and is not the current production control
loop.

### Current capabilities

The watchdog:

* Reads service health through the Docker control path.
* Tracks health state over time.
* Applies restart policy only where automatic recovery is intended.
* Reports service state for UI consumption.
* Distinguishes restart-managed services from alert-only services.
* Covers the core proxy and DNS path.
* Covers NATS and the Docker control dependency.
* Includes UI and Netdata visibility.
* Includes profile-dependent DHCP, DHCP proxy and central logging visibility.

### Recovery behavior

A service becoming unhealthy does not automatically imply that every service
is restartable.

The watchdog keeps service observation separate from the decision to perform a
restart. This allows infrastructure that should only be surfaced to the
operator to remain alert-only.

### Retention separation

Destructive retention and pruning work is separated from the Rust health loop.

The retention path has its own narrowly-scoped runtime environment instead of
giving the main watchdog broad file-system mutation access.

### Legacy Bash implementation

`services/watchdog/watchdog.sh` remains in the repository for historical and
supporting context, but the compiled Rust implementation is the production
watchdog entrypoint.

## Netdata

### Purpose

`services/netdata` provides system and service metrics used by the Admin UI and
for direct operational diagnostics.

### Current capabilities

The Netdata integration provides visibility into areas such as:

* Container and host resource use.
* Proxy traffic.
* nginx request data.
* Cache-related activity.
* Service-level resource behavior.

The nginx `web_log` collector consumes the normalized proxy log path produced
by the central logging stack.

Netdata access is isolated through dedicated stack networking rather than being
treated as a general public API.

## Central Logging

### Purpose

`services/syslog` provides centralized collection and processing of logs from
LanCache-NG services.

The service combines syslog-ng and Fluent Bit related functionality with
health and data-loss detection.

### Current capabilities

The logging path provides:

* Central service log collection.
* Normalized log files.
* Proxy request log processing.
* Inputs used by the Admin UI log viewer.
* Input for Netdata's nginx `web_log` collector.
* Health checking.
* Detection of logging-path data loss.
* Log retention and compression support.

Service logs remain useful through their normal container output as well. The
central logging path is an additional consolidated operator view rather than a
reason for individual services to become silent.

## NTP

### Purpose

`services/ntp` provides a LAN NTP server using chrony.

It can synchronize against configured upstream time sources and serve time to
LAN clients on UDP port 123.

### Current implementation

The image uses Alpine and the `chrony-nts` package.

Installing the NTS-capable package preserves cryptographic NTS capability for
future use even though the current LanCache-NG chrony configuration does not
enable NTS.

### Host clock discipline

Containers share the host kernel clock.

When LanCache-NG is allowed to discipline time, the NTP service therefore
changes the host clock rather than an isolated container-local clock.

The deployment uses explicit capabilities for this instead of assuming the
container can modify system time by default.

chronyd drops privileges to its packaged service user after the privileged
startup operations are complete.

### Operational scope

NTP is optional and independent of the caching data path.

Disabling NTP does not disable proxying, DNS or the Admin UI.

## CacheHamster

### Status

`services/cachehamster` exists in `current_dev`, but it is not yet a finished
or deployed product capability.

It should be treated as a scaffold.

### Intended purpose

CacheHamster is the planned active prefill engine.

Its intended design is stream-and-discard:

1. Resolve game or depot content.
2. Fetch that content through the LanCache-NG cache path.
3. Read the response stream completely.
4. Discard the received payload locally.
5. Let the proxy cache the transferred content.

The prefill service itself must not create a second persistent copy of the
downloaded game data.

### Implemented scaffold capabilities

The current Rust scaffold already provides:

* Streaming URL fetches.
* Bounded concurrent fetches.
* Byte counting.
* Periodic throughput logging.
* Stream-and-discard handling.
* Optional in-memory-only Steam credential use.
* Optional encrypted credential persistence.
* Placeholder-secret rejection.
* A dedicated container image.

### Not yet implemented

The current scaffold does not yet provide:

* Steam login flow.
* Steam app-ID resolution.
* Depot discovery.
* Depot manifest parsing.
* Real Steam CDN chunk resolution.
* Compose deployment wiring.
* Admin UI controls.
* End-to-end game prefill verification.

`CACHEHAMSTER_URLS` is currently a scaffold input for directly supplied URLs,
not the final operator-facing prefill workflow.

CacheHamster therefore must not be described as a shipped Cache Warmer yet.

## setup.sh

### Purpose

`setup.sh` is the primary operator lifecycle and deployment orchestrator.

It owns the transition from a repository or release checkout to a validated,
persistent LanCache-NG installation.

### Main responsibilities

The script handles:

* Host requirement checks.
* Installation prerequisites.
* Initial installation.
* Runtime configuration generation.
* Deployment profile selection.
* Image-channel and image-tag resolution.
* Updates.
* Configuration migration.
* Backup.
* Restore.
* Secondary installation.
* Primary and secondary requirements.
* DHCP mode configuration.
* Runtime convergence.
* Recovery operations.
* Known-good configuration rollback helpers.
* Full-setup and validation-oriented deployment paths.

### Deployment layouts

The current repository uses the production, quickstart, full-setup and
secondary deployment layouts where appropriate.

The former permanent `deploy/dev` environment has been retired. Development no
longer depends on maintaining a second parallel copy of the complete runtime
stack.

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
assembles the internal NATS and DNS configuration from scratch.

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
  -> dns-standard
  -> PowerDNS native replication
  -> dns-ssl / secondary DNS nodes
```

The writable DNS primary is the single authority for replicated zone changes.

### Admin UI DNS change

```text
Operator
  -> Admin UI
  -> DNS control plane
  -> dns-standard
  -> PowerDNS replication
  -> DNS secondaries
```

### Remote secondary registration

```text
Secondary setup
  -> Primary Admin UI
  -> registration bootstrap
  -> per-secondary NATS identity
  -> DNS replication parameters
  -> secondary deployment
```

### Observability

```text
Service logs
  -> Central logging
  -> normalized log data
  -> Admin UI / Netdata

Service health
  -> Docker health state
  -> Watchdog
  -> status and controlled recovery
```

### Future prefill

```text
Operator
  -> CacheHamster
  -> Steam content resolution
  -> cache-routed HTTP fetch
  -> Proxy
  -> cached object

CacheHamster receives and discards the response body.
```

The Steam content-resolution portion of this flow is not implemented yet.

## Capability boundaries

The following boundaries are intentional or currently unresolved:

1. DHCP is IPv4-only. DHCPv6 is not part of the current product surface.

2. The proxy uses pre-generated certificates. Arbitrary-depth wildcard TLS
   matching cannot be completely represented by a finite set of ordinary
   wildcard certificates.

3. DNS processes currently start without a Dockerfile-level non-root user.
   Further least-privilege work must preserve binding and PowerDNS behavior.

4. Secondary bootstrap still uses a shared registration token even though
   runtime NATS credentials are unique per secondary.

5. NTP installs an NTS-capable chrony build, but the current runtime
   configuration does not yet use NTS.

6. Some advanced PXE-specific configuration is not exposed with the same UI
   depth as the normal DHCP mode and Kea configuration.

7. CacheHamster is a development scaffold and has no production deployment or
   Admin UI integration yet.

## Validation coverage

LanCache-NG uses multiple validation layers because configuration generation
alone is not sufficient evidence that a network service works.

Representative validation includes:

* Rust unit and integration tests.
* Bats tests for shell and configuration behavior.
* Compose configuration validation.
* Real nginx configuration validation.
* Real HTTP cache simulations.
* TLS-interception simulations.
* DHCP DORA tests.
* Native DHCP probing.
* PXE packet simulations.
* Kea Control Agent mutation tests.
* DNS and DDNS tests.
* PowerDNS replication configuration tests.
* Setup CLI simulations.
* Backup and restore tests.
* Known-good snapshot rollback tests.
* Watchdog health and recovery tests.
* Logging and observability checks.

A capability should not be considered fully validated merely because its
configuration renders successfully. Where behavior depends on real network
traffic, service interaction or persistence, validation should exercise that
behavior directly.

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
