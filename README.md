# lancache-ng

[![Build & Push](https://github.com/wiki-mod/lancache-ng/actions/workflows/build-push.yml/badge.svg)](https://github.com/wiki-mod/lancache-ng/actions/workflows/build-push.yml)

LanCache NG is a local download cache for your home network, LAN party, lab, school, office or gaming room.

It stores game and software downloads inside your local network.  
The first download still comes from the internet.  
The next download can come from your local cache at LAN speed.

This is useful when multiple PCs download the same games, updates or drivers.  
It can reduce internet traffic, save bandwidth and make repeated downloads much faster.

## Project status

LanCache NG is still actively changing.

The current setup already provides the main stack, guided installation, Admin UI, DNS based cache routing, optional SSL caching, optional DHCP, optional Watchtower helper updates and secondary DNS support.

Some internal paths, root elements and service details may still change while the project grows.

### Test coverage

The build badge above reflects the status of the primary CI pipeline, which includes Rust test coverage validation. On every push, the `rust_coverage` job runs `cargo tarpaulin` against the `services/dns/nats-subscriber` and `services/ui` crates and enforces a per-crate threshold: `services/ui` must stay at or above 35% (real measured coverage is ~38.6% as of this writing), and `services/dns/nats-subscriber` currently has a 0% threshold because its existing tests only cover its data model, not its subscribe/forward logic (tracked in #504). Each crate's threshold is raised independently as that crate gains real coverage.

## What this project does

LanCache NG combines several services into one Docker based stack:

- DNS service
  - for redirecting known CDN domains to your local cache
- Nginx cache proxy for standard HTTP caching
  - optional SSL cache proxy for HTTPS capable clients
- Admin UI for cache status, domains, DNS records, DHCP leases and settings
  - optional Kea DHCP server
  - optional DHCP-Dnsmasq-based proxy helper
  - optional Watchtower helper updates
  - optional watchdog and convergence checks
  - optional secondary DNS nodes synced through NATS

The goal is simple:

Your clients use LanCache NG as DNS server.  
Known download domains are answered with the cache IP.  
The cache proxy downloads and stores the requested files.  
Later clients can receive the same files from your LAN.

## Quick start

Run this on a Linux machine inside your network:

```bash
curl -fsSL https://raw.githubusercontent.com/wiki-mod/lancache-ng/master/setup.sh | sudo bash
```

The setup script guides you through the installation. If required tools are missing, it asks before installing packages, installs missing requirements such as Docker, curl and git through the host package manager, and prints the package names to install manually if you abort.
It is a pull-only installer: it resolves and pulls prebuilt first-party images,
so Redis-backed sccache, distcc and other build accelerators do not affect
normal setup or update paths.

It can:

- check the required tools
- ask before installing missing dependencies such as Docker, curl or git
- clone the repository to `/opt/lancache-ng`
- ask for the cache server IP
- optionally enable SSL caching with a second IP
- ask for cache directory and cache size
- optionally enable Watchtower helper updates
- create pre-update rollback backups
- create config-only or full backups
- restore setup-script backups
- optionally enable DHCP
- optionally protect the Admin UI with a password
- write the `.env` file
- create required directories
- start the Docker stack
- install systemd startup and convergence checks

Default installation path:

```text
/opt/lancache-ng
```

After setup, open the Admin UI:

```text
http://<server-ip>:8080
```

Example:

```text
http://192.168.1.10:8080
```

## The two operating modes

LanCache NG can run in two modes.

### Standard mode

Standard mode is the safest and easiest mode.

It does not need a certificate on the clients.

Use this mode if you want maximum compatibility.

Standard mode:

- caches HTTP downloads
- passes HTTPS traffic through normally
- works without client certificate setup
- works well for PCs, consoles and general devices
- is the recommended first test mode

Example DNS target:

```text
192.168.1.10
```

### SSL mode

SSL mode is optional.

It can cache HTTP and HTTPS downloads, but it needs a locally generated Root CA certificate on every client that should use SSL caching.

Use this mode only for devices you own and trust.

SSL mode:

- needs a second LAN IP
- needs the generated CA certificate installed on each client
- can improve cache hit rates for launchers and CDNs using HTTPS
- is useful for Windows gaming PCs
- is not suitable for most consoles

Example DNS target:

```text
192.168.1.11
```

### Running both modes together

Both modes can run at the same time.

Example:

| Mode | Client setup | DNS server |
|---|---|---|
| Standard mode | no certificate needed | `192.168.1.10` |
| SSL mode | CA certificate installed | `192.168.1.11` |

This lets you decide per client.

A console can use standard mode.  
A gaming PC with the certificate installed can use SSL mode.

## What can be cached

LanCache NG can cache many game, software and update downloads when the required domains are known.

Examples:

- Steam
- Epic Games
- GOG
- EA and Origin
- Blizzard and Battle.net
- Ubisoft
- Riot Games
- Rockstar Games
- Warframe
- Path of Exile
- Guild Wars 2
- Windows Update
- Microsoft Office
- NVIDIA drivers
- AMD drivers
- Linux package mirrors

Important:

Not every platform behaves the same.  
Some services change their CDN domains.  
Some downloads use HTTPS in a way that only works with SSL mode.  
Some clients may bypass the cache completely.

The first download is normally a cache miss.  
The second identical download is where the cache should help.

### Cache policy

LanCache NG is not a generic forward proxy. It is designed to force caching for known game,
software and update CDN downloads that you intentionally route through the cache.

The nginx cache key intentionally uses the host and path, not the full request URI with the
query string. Many CDN download URLs include per-request signatures or expiry tokens in the
query string. Including those values in the cache key would make each signed URL look like a
different object and would greatly reduce cache hits. The full request URI is still forwarded
to the upstream CDN for validation; only the local cache key ignores the query string.

For the same reason, LanCache NG intentionally ignores selected upstream cache headers such as
`Cache-Control`, `Expires`, `Vary` and `Set-Cookie` for cached download responses. Do not use
LanCache NG as a general-purpose proxy, and only add CDN domains that you understand and want
to cache.

## Console support

Xbox, PlayStation and similar consoles should usually use standard mode.

They normally cannot install a custom Root CA certificate in a useful way.  
Because of that, SSL caching is not recommended for consoles.

Consoles should continue to work normally through standard mode.  
HTTPS traffic that cannot be cached is passed through to the original CDN.


## Requirements

You need:

- a Linux machine that stays online
- Docker with the Docker Compose plugin
- a static LAN IP for the cache server
- enough disk space for the cache
- port `53` free for DNS
- port `80` free for HTTP cache traffic
- port `443` free if SSL mode is enabled
- port `8080` for the Admin UI
- optional second LAN IP for SSL mode
- optional port `67/udp` if using the built in DHCP server

Recommended storage:

| Environment | Suggested cache size |
|---|---|
| small test setup | 50 GB |
| few gaming PCs | 100 GB |
| LAN party or shared network | 500 GB or more |

A fast SSD is nice, but a large HDD can also work.  
The best choice depends on your network, internet speed and number of clients.

## Installation with setup script

Recommended installation:

```bash
curl -fsSL https://raw.githubusercontent.com/wiki-mod/lancache-ng/master/setup.sh | sudo bash
```

During setup you will be asked for the important values. If required tools are missing, setup asks before installing packages and prints the package names to install manually if you abort.

Example values:

| Setting | Example |
|---|---|
| Standard mode IP | `192.168.1.10` |
| SSL mode IP | `192.168.1.11` |
| install directory | `/opt/lancache-ng` |
| cache directory (shared) | `/opt/lancache-ng/cache` |
| cache size | `500` GiB |
| Admin UI port | `8080` |

After setup, check the containers:

```bash
cd /opt/lancache-ng
docker compose ps
```

Open the Admin UI:

```text
http://<standard-ip>:8080
```

## Updating

If you installed with the setup script, update with:

```bash
sudo /opt/lancache-ng/setup.sh update
```

The update command can:

- create a config-only rollback backup before changing the stack
- pull the current repository state
- update the compose file
- pull newer images
- restart the stack

Setup and update always consume prebuilt runtime images. They do not build the
production stack locally, so host-side build acceleration is never a runtime
or install dependency.

Create a manual backup with:

```bash
sudo /opt/lancache-ng/setup.sh backup --config
sudo /opt/lancache-ng/setup.sh backup --full
```

Use `--config` for small update rollback backups. Use `--full` only when you also need cache objects, because full backups can be very large. Restore a backup with:

```bash
sudo /opt/lancache-ng/setup.sh restore /var/backups/lancache-ng/lancache-ng-config-YYYYMMDDTHHMMSSZ.tar.gz /opt/lancache-ng
```

See `docs/backup-restore.md` for backup scope, restore testing, secret handling, CA lifecycle notes, and rollback details.

## Image Versioning and Release Channels

`LANCACHE_IMAGE_CHANNEL` selects the first-party image channel. `setup.sh`
resolves mutable channels to the immutable `LANCACHE_IMAGE_TAG` used by Docker
Compose.

- `latest` is the default stable release channel.
- `edge` is the tested pre-stable channel promoted from `master`.
- `vX.Y.Z` pins all stack services to an immutable stable release tag.
- Branch and commit images are optional for development and testing.
  If CI has published them, valid examples are branch names (for branch pushes)
  and short `sha-<short>` tags.

Recommended for production:

- Use `latest` for normal stable deployments.
- Use a tagged release value (for example `v1.2.3`) for pinned deployments.
- Use `edge`, branch tags, or `sha-*` tags only for temporary test environments
  where intentional drift is acceptable.

The release workflow publishes service images with branch, tag, and SHA tags and keeps release source notes in GitHub releases.

## Debug information

If something does not work, run:

```bash
sudo /opt/lancache-ng/setup.sh debug
```

The debug command prints:

- container status
- recent logs
- cache usage
- detected LAN IPs
- health check results

You can also view live logs manually:

```bash
cd /opt/lancache-ng
docker compose logs -f
```

## Point your clients to the cache

LanCache NG works by DNS.

A client must use the LanCache NG DNS IP.  
You can set that manually per client or distribute it through DHCP.

Example:

| Client type | DNS server |
|---|---|
| normal client without certificate | `192.168.1.10` |
| SSL client with certificate installed | `192.168.1.11` |

On many routers you can set the DNS server handed out by DHCP.  
Set it to the LanCache NG standard IP if you want all clients to use standard mode.

For SSL mode, only point clients to the SSL IP after the CA certificate was installed.

## Optional DHCP

LanCache NG only caches traffic for clients that resolve CDN hostnames through
its DNS servers. DHCP is the most reliable way to hand those DNS servers to
clients. `setup.sh` lets you pick one of three DHCP modes (stored as
`DHCP_MODE` in `.env`):

- `disabled` — LanCache NG does not manage or proxy DHCP. You point clients at
  its DNS yourself (router DHCP option or static client config). This is the
  right starting point for most users.
- `kea` — LanCache NG runs a full Kea DHCP server that hands out IP address,
  gateway, and the correct cache DNS servers, and supports reservations and
  lease management in the Admin UI. Use this only when LanCache NG is allowed
  to be the network's DHCP server (your router's DHCP is turned off).
- `dnsmasq-proxy` — LanCache NG runs dnsmasq in proxy-DHCP mode next to an
  existing DHCP server for networks where the router or ISP gateway keeps DHCP
  enabled and cannot be disabled. It does not own leases and is limited to
  proxy/PXE clients; it does not reliably replace the DNS option handed out by
  a normal router DHCP server.

The three modes are mutually exclusive — Kea and dnsmasq both bind DHCP port
`67/udp`, so setup activates exactly one, and switching modes in the Admin UI
stops the other service.

Important: do not run two normal DHCP servers in the same network unless you
planned it carefully. If your router already provides DHCP, either keep using
the router (and set DNS another way) or switch DHCP fully to LanCache NG.

See [docs/dhcp-modes.md](docs/dhcp-modes.md) for when to use each mode, what is
not available in `dnsmasq-proxy` mode, how to set the upstream DHCP IP, and how
to verify clients actually receive the LanCache NG DNS servers.

## Admin UI

The Admin UI is available after setup:

```text
http://<server-ip>:8080
```

The Admin UI can be used for:

- cache overview
- cache fill level
- hit and miss statistics
- active downloads
- domain management
- LAN DNS records
- DHCP leases
- settings
- secondary DNS management

If the setup asks whether the Admin UI should be password protected, using a password is recommended.

Do not expose the Admin UI to the internet.

## SSL mode certificate

SSL mode generates a local CA certificate.

Clients using SSL mode must trust this certificate.

After the first start, the certificate is available here:

```text
/opt/lancache-ng/certs/ca.crt
```

Depending on your installation path, the file may be inside your selected install directory.

### Install on Windows

Use PowerShell as Administrator:

```powershell
scripts\install-ca-cert.ps1
```

### Install on Linux

Use:

```bash
sudo scripts/install-ca-cert.sh
```

### Manual instructions

See:

```text
docs/install-ca-cert.md
docs/backup-restore.md
```

### Firefox note

Firefox can use its own certificate store.  
If HTTPS caching does not work in Firefox, import the certificate into Firefox too.

### Steam Deck note

Steam Deck can require extra handling because the system is more locked down than a normal Linux desktop.  
See the certificate documentation before using SSL mode on it.

## Testing DNS

On a client using LanCache NG as DNS server, run:

```bash
nslookup steamcontent.com
```

or specify the DNS server directly:

```bash
nslookup steamcontent.com 192.168.1.10
```

If DNS routing works, known CDN domains should resolve to your cache IP instead of a public CDN IP.

## Testing the cache

A simple test:

1. Point a client to the LanCache NG DNS server.
2. Download a supported game or update.
3. Delete it or try the same download from another client.
4. Download it again.
5. Check whether the second download is faster.
6. Check the Admin UI for cache activity.

The first download normally goes to the internet.  
The second download is the important test.

## Adding or changing cached domains

You can manage domains in the Admin UI.

This is the easiest option and usually does not require a rebuild.

Manual domain files:

```text
services/dns/cdn-domains.txt
services/proxy/cdn-ssl-domains.txt
```

Use `cdn-domains.txt` for DNS based cache routing.  
Use `cdn-ssl-domains.txt` for SSL mode certificate coverage.

After manual file changes in a repository-based setup, restart the affected
services so they reload the mounted files:

```bash
cd /opt/lancache-ng
docker compose restart dns-standard dns-ssl proxy
```

Only add domains you understand.  
Wrong domains can break downloads or route traffic that should not be cached.

## Secondary DNS

LanCache NG can run additional DNS nodes on other machines.

This is useful if:

- you have more than one network area
- you want DNS redundancy
- you want another host to answer DNS requests
- you want DNS closer to some clients

Secondary DNS nodes sync with the primary through NATS.

Setup example:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wiki-mod/lancache-ng/master/setup.sh) secondary \
  --primary http://192.168.1.10:8080 \
  --token <SECONDARY_REGISTRATION_TOKEN> \
  --name my-secondary \
  --proxy-ip 192.168.1.10
```

The registration token is generated during primary setup and stored in `.env`.

You can also view a ready command inside the Admin UI under the secondary DNS section.

If a secondary was created before scoped NATS user/password credentials existed,
rerun the same command with `--rotate` in that secondary's install directory.
This rewrites the local secondary `.env` from the primary registration API
without changing the secondary name.

After setup, point additional clients to the secondary DNS IP.

## Manual setup

The setup script is recommended.

Manual setup is useful if you want to inspect and control every file yourself.

Clone the repository:

```bash
cd /opt
git clone https://github.com/wiki-mod/lancache-ng.git
cd lancache-ng
```

Copy the checked-in production template to an untracked runtime env file and
edit that file:

```bash
cp deploy/prod/.env deploy/prod/.env.local
nano deploy/prod/.env.local
```

Set at least:

```env
IP_STANDARD=192.168.1.10
IP_SSL=192.168.1.11

SSL_ENABLED=1

LANCACHE_STATE_DIR=/opt/lancache-ng

# Optional per-service overrides. Leave unset unless you intentionally split
# state across multiple disks; compose derives normal state paths from
# LANCACHE_STATE_DIR.
# CACHE_DIR_STANDARD=/opt/lancache-ng/cache
# CACHE_DIR_SSL=/opt/lancache-ng/cache

CACHE_MAX_SIZE=50g
CACHE_MEM_MB=512
NGINX_UPSTREAM_RESOLVER=8.8.8.8 8.8.4.4
PROXY_SECURITY_MODE=lazy
PROXY_ALLOWED_CLIENT_CIDRS=

CACHE_MAX_GB=50

# First-party service image selector.
# latest is the latest stable release channel.
# Use edge only when you explicitly want the tested pre-stable channel.
# setup.sh resolves mutable channels to an immutable sha-* image tag before pull.
# Do not change LANCACHE_IMAGE_TAG by hand unless LANCACHE_IMAGE_CHANNEL=pinned.
LANCACHE_IMAGE_REGISTRY=ghcr.io
LANCACHE_IMAGE_PREFIX=wiki-mod/lancache-ng
LANCACHE_IMAGE_CHANNEL=latest
LANCACHE_IMAGE_TAG=sha-<resolved-by-setup>
```

Set `NGINX_UPSTREAM_RESOLVER` to real upstream DNS servers only (for example public, ISP, or corporate resolvers). Do not set it to the LanCache DNS/proxy IP, or nginx will resolve CDN hostnames back to the cache and loop.

`PROXY_SECURITY_MODE` controls how defensive the proxy is at request time:

- `lazy` is the default and keeps the traditional LanCache-style behavior: if a client reaches the cache, nginx proxies the requested host upstream. This is the deliberate cache-first choice so new CDN hostnames keep working out of the box.
- `strict` NOT RECOMMENDED! Only proxies hosts matching `services/proxy/cdn-ssl-domains.txt`; unknown hosts receive `403 Forbidden`. This reduces accidental or abusive proxying, but it can AND will break downloads until missing CDN root domains are added. That means, you need to add manually all domains by hand!

`PROXY_ALLOWED_CLIENT_CIDRS` can optionally restrict who may use the proxy, for example `192.168.1.0/24 172.16.0.0/12`. Leave it empty to allow any client that can reach the bound LAN/Docker ports; `setup.sh` writes the empty value by default for the normal LAN-only deployment model where firewalling and Docker port bindings already define the boundary.

`LANCACHE_IMAGE_CHANNEL` controls the mutable stack channel. `latest` means the
latest stable release. Use `edge` only when you explicitly want the tested
pre-stable channel. `setup.sh` resolves mutable channels through the `stack`
pointer image and writes the immutable `LANCACHE_IMAGE_TAG` that Docker Compose
pulls. If you install from a tagged release archive or a checked-out `vX.Y.Z` /
`vX.Y.Z-rc.N` tag, set `LANCACHE_IMAGE_CHANNEL=pinned` and
`LANCACHE_IMAGE_TAG` to that same release tag so the running containers match
the source tree.

`LANCACHE_IMAGE_REGISTRY` and `LANCACHE_IMAGE_PREFIX` select where first-party images are pulled from. Keep the defaults for GHCR, or point both values at a private mirror that provides the complete stack package set.
The resulting install/update path still stays pull-only and does not depend on
local compiler caches or remote compiler services.

Current prebuilt first-party images are published for `linux/amd64`. Multi-architecture images are tracked separately; non-amd64 production installs should not assume the prebuilt pull-only path is available yet.

Release channels and package rules are documented in `docs/release-versioning.md`. External image handling is documented in `docs/release-external-images.md`.

Keep `deploy/prod/.env` as the checked-in template. Manual production changes
belong in `deploy/prod/.env.local`, which is ignored by git and preferred by
`setup.sh update`, `setup.sh backup`, `setup.sh restore`, and `setup.sh update-ip`
when present.

If you use NATS, secondary DNS or DHCP DDNS, set real secret values too:

```env
DDNS_TSIG_KEY=<generate-a-secret>
NATS_UI_PASSWORD=<generate-a-secret>
NATS_DNS_WRITER_PASSWORD=<generate-a-secret>
NATS_DNS_READER_PASSWORD=<generate-a-secret>
SECONDARY_REGISTRATION_TOKEN=<generate-a-secret>
```

Create directories:

```bash
mkdir -p /opt/lancache-ng/cache
mkdir -p /opt/lancache-ng/kea
mkdir -p /opt/lancache-ng/pdns-standard
mkdir -p /opt/lancache-ng/pdns-ssl
mkdir -p /opt/lancache-ng/pdns-filter-state
mkdir -p /opt/lancache-ng/nats
mkdir -p /opt/lancache-ng/nats-conf
```

Start the stack:

```bash
docker compose --env-file deploy/prod/.env.local -f deploy/prod/docker-compose.yml pull
docker compose --env-file deploy/prod/.env.local -f deploy/prod/docker-compose.yml up -d
```

For later upgrades from this manual checkout, keep local changes in
`deploy/prod/.env.local`, create a rollback backup before pulling new repository
files, then update the production stack directory explicitly instead of using a
raw compose pull/up:

```bash
sudo ./setup.sh backup --config "$(pwd)/deploy/prod"
git pull --ff-only
sudo ./setup.sh update "$(pwd)/deploy/prod"
```

The explicit pre-pull backup preserves the currently working compose,
`.env.local`, certificates and runtime config before tracked files change. The
update command creates another rollback backup after the pull, applies
state-path migrations and validates compose before restarting the stack.

Check status:

```bash
docker compose --env-file deploy/prod/.env.local -f deploy/prod/docker-compose.yml ps
```

## Proxmox LXC notes

LanCache NG can run inside a Proxmox LXC container.

Recommended:

- use a Debian based unpriviledged container
- use enough disk space
- enable nesting
- keep the container inside your LAN
- give the container a static IP
- use a second IP if SSL mode is enabled

Example LXC config on the Proxmox host:

```text
features: nesting=1,keyctl=1
lxc.apparmor.profile: unconfined
```

For unprivileged containers and port `53`, this can be needed on the host:

```bash
echo 'net.ipv4.ip_unprivileged_port_start=53' >> /etc/sysctl.conf
sysctl -p
```

If SSL mode is enabled, the container requires a second usable LAN IPs.
- The reason is, that you then be able to cache also SSL Downloads from the configured domain list.
  - But you will need to install the CA-Certificate to let this happen.

## Ports

| Port | Protocol | Used for |
|---|---|---|
| `53` | TCP and UDP | DNS |
| `80` | TCP | HTTP cache |
| `443` | TCP | SSL mode cache |
| `8080` | TCP | Admin UI |
| `67` | UDP | optional DHCP server |
| `8000` | TCP | optional Kea control agent |

Keep these ports inside your LAN.  
Do not expose them directly to the internet.

## Repository layout

Important paths:

```text
deploy/quickstart/       Quickstart compose used by setup.sh
deploy/prod/             Production compose files
deploy/secondary/        Secondary DNS compose files
docs/                    Documentation
scripts/                 Helper scripts
services/dns/            DNS service
services/proxy/          Unified proxy for HTTP mode and SSL mode
services/ui/             Admin UI
services/watchdog/       Watchdog service
services/dhcp/           Kea DHCP service
services/dhcp-proxy/     DHCP proxy service
services/nats/           NATS sync service
certs/                   Generated or mounted certificates
```

## Common problems

### DNS does not answer

Check that the container is running:

```bash
cd /opt/lancache-ng
docker compose ps
```

Check whether port `53` is already used by another service:

```bash
ss -tulpen | grep ':53'
```

Common causes:

- another DNS server is already using port `53`
- systemd resolved is listening on port `53`
- the client is not using the LanCache NG DNS IP
- firewall rules block DNS
- Docker is not running

### Client still downloads from the internet

This can be normal for the first download.

Check:

- is the client using the correct DNS server
- is the domain part of the cache domain list
- is the download using HTTPS
- if SSL mode is needed, is the client using the SSL DNS IP
- if SSL mode is needed, is the CA certificate installed

### SSL mode does not work

Check:

- the client uses the SSL mode DNS IP
- the second IP is really assigned to the server
- the CA certificate is installed
- Firefox has the certificate if Firefox is used
- the domain exists in the SSL domain list
- the SSL proxy container is running

### Admin UI does not open

Check:

```bash
cd /opt/lancache-ng
docker compose ps
docker compose logs --tail=100 ui
```

Common causes:

- wrong IP
- blocked port `8080`
- UI container not running
- firewall blocks access
- manual production setup binds UI differently than quickstart setup

### Cache hit rate is low

A low hit rate can happen when:

- everything is downloaded for the first time
- every client downloads different files
- the platform changed CDN domains
- the download uses unsupported HTTPS behavior
- the domain is missing from the domain list
- the cache size is too small and old files are removed

## Security notes

LanCache NG is intended for trusted local networks.

Recommended:

- do not expose DNS, proxy or Admin UI to the internet
- protect the Admin UI with a password
- keep generated tokens private
- keep the CA private
- install the CA certificate only on clients you own and trust
- do not use SSL mode for unknown or guest devices
- review the setup script before running it on important systems

A local Root CA can inspect traffic for configured domains.  
That is required for SSL caching, but it also means the CA must be handled carefully.

## When to use which mode

Use standard mode when:

- you want the easiest setup
- you use consoles
- you do not want to install certificates
- you only want safe basic caching
- you are testing the project for the first time

Use SSL mode when:

- you control the client device
- you can install the CA certificate
- you want better cache coverage
- you understand that HTTPS caching needs trust in the local CA
- you are using supported game launchers on PCs

## License

MIT
