# lancache-ng

LanCache NG is a local download cache for your home network, LAN party, lab, school, office or gaming room.

It stores game and software downloads inside your local network.  
The first download still comes from the internet.  
The next download can come from your local cache at LAN speed.

This is useful when multiple PCs download the same games, updates or drivers.  
It can reduce internet traffic, save bandwidth and make repeated downloads much faster.

## Project status

LanCache NG is still actively changing.

The current setup already provides the main stack, guided installation, Admin UI, DNS based cache routing, optional SSL caching, optional DHCP, optional automatic updates and secondary DNS support.

Some internal paths, root elements and service details may still change while the project grows.

## What this project does

LanCache NG combines several services into one Docker based stack:

- DNS service for redirecting known CDN domains to your local cache
- Nginx cache proxy for standard HTTP caching
- optional SSL cache proxy for HTTPS capable clients
- Admin UI for cache status, domains, DNS records, DHCP leases and settings
- optional Kea DHCP server
- optional DHCP proxy helper
- optional Watchtower updates
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

It can:

- check the required tools
- ask before installing missing dependencies such as Docker, curl or git
- clone the repository to `/opt/lancache-ng`
- ask for the cache server IP
- optionally enable SSL caching with a second IP
- ask for cache directory and cache size
- optionally enable automatic updates
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


## Docker build performance on local runners

If you build LanCache NG on a self-hosted runner or want to speed up repeated local builds, see the local runner Docker performance guide for practical options such as Docker layer caching, registry mirrors, multi-stage builds, `.dockerignore` files and runner parallelism tuning.

[docs/local-runner-docker-performance.md](docs/local-runner-docker-performance.md)

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
| standard cache directory | `/opt/lancache-ng/cache/standard` |
| SSL cache directory | `/opt/lancache-ng/cache/ssl` |
| cache size per mode | `500` GiB |
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

## Optional DHCP server

LanCache NG can optionally run a Kea DHCP server.

This can automatically give clients:

- an IP address
- gateway
- DNS server
- the correct cache DNS IP

Use this only if you know which DHCP server should be active in your network.

Important:

Do not run two normal DHCP servers in the same network unless you planned it carefully.  
If your router already provides DHCP, either keep using the router or switch DHCP fully to LanCache NG.

## Optional DHCP proxy

The repository also contains a DHCP proxy service.

This is useful for advanced setups where another DHCP server still exists, but LanCache NG should help provide specific network options.

Most users should start without this.  
Use normal DNS configuration first.

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

After manual file changes, rebuild and restart:

```bash
cd /opt/lancache-ng
docker compose up --build -d
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

Edit the production environment file:

```bash
nano deploy/prod/.env
```

Set at least:

```env
IP_STANDARD=192.168.1.10
IP_SSL=192.168.1.11

SSL_ENABLED=1

CACHE_DIR_STANDARD=/srv/lancache/cache
CACHE_DIR_SSL=/srv/lancache/cache

CACHE_MAX_SIZE=50g
CACHE_MEM_MB=512
NGINX_UPSTREAM_RESOLVER=8.8.8.8 8.8.4.4
PROXY_SECURITY_MODE=lazy
PROXY_ALLOWED_CLIENT_CIDRS=

CACHE_MAX_GB=50
```

Set `NGINX_UPSTREAM_RESOLVER` to real upstream DNS servers only (for example public, ISP, or corporate resolvers). Do not set it to the LanCache DNS/proxy IP, or nginx will resolve CDN hostnames back to the cache and loop.

`PROXY_SECURITY_MODE` controls how defensive the proxy is at request time:

- `lazy` is the default and keeps the traditional LanCache-style behavior: if a client reaches the cache, nginx proxies the requested host upstream. This is the deliberate cache-first choice so new CDN hostnames keep working out of the box.
- `strict` NOT RECOMMENDED! Only proxies hosts matching `services/proxy/cdn-ssl-domains.txt`; unknown hosts receive `403 Forbidden`. This reduces accidental or abusive proxying, but it can AND will break downloads until missing CDN root domains are added. That means, you need to add manually all domains by hand!

`PROXY_ALLOWED_CLIENT_CIDRS` can optionally restrict who may use the proxy, for example `192.168.1.0/24 172.16.0.0/12`. You have to change it, we set by default the LAN-IP ranges for the normal LAN-only deployment model where firewalling and Docker port bindings already define the boundary.

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
mkdir -p /srv/lancache/cache
mkdir -p /srv/lancache/kea
```

Start the stack:

```bash
docker compose -f deploy/prod/docker-compose.yml up -d --build
```

Check status:

```bash
docker compose -f deploy/prod/docker-compose.yml ps
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
