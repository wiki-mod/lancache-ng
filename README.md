# lancache-ng

A LAN cache for game and software downloads — intercepts CDN traffic at the DNS level and serves cached files locally. Built as a modern alternative to [lancachenet](https://github.com/lancachenet) with two additions: **SSL interception** and **IPv6 support**.

## How it works

Clients point their DNS to this server. The DNS server returns the proxy's IP for known CDN hostnames. The proxy fetches and caches the content on first request; every subsequent client on the LAN gets it from the local cache at full network speed.

## Two modes, two IPs

Clients choose a mode by which DNS server IP they configure:

| Mode | DNS IP | HTTP | HTTPS | CA cert required? |
|------|--------|------|-------|-------------------|
| **Standard** | `192.168.234.10` | cached | passthrough to CDN | No |
| **SSL** | `192.168.234.11` | cached | cached (TLS intercepted) | Yes |

- **Standard mode** — identical to lancachenet. HTTP downloads are cached; HTTPS connections are forwarded blind via SNI passthrough. No certificate to install. Works on all devices including consoles.
- **SSL mode** — both HTTP and HTTPS are cached. The proxy terminates TLS using a per-domain wildcard certificate signed by a local CA. Clients must install the CA certificate once. Delivers higher cache hit rates for games that use HTTPS CDNs (Epic, EA, Blizzard, etc.).

## Supported platforms

| Platform | Standard | SSL |
|----------|----------|-----|
| Steam | ✓ | ✓ |
| Epic Games | ✓ | ✓ |
| Blizzard / Battle.net | ✓ | ✓ |
| EA / Origin | ✓ | ✓ |
| GOG | ✓ | ✓ |
| Bethesda | ✓ | ✓ |
| Riot Games (LoL, Valorant) | ✓ | ✓ |
| Ubisoft | ✓ | ✓ |
| Rockstar | ✓ | ✓ |
| Warframe | ✓ | ✓ |
| Path of Exile | ✓ | ✓ |
| Guild Wars 2 | ✓ | ✓ |
| Windows Update / Microsoft | ✓ | ✓ |
| Microsoft Office / 365 | ✓ | ✓ |
| NVIDIA drivers | ✓ | ✓ |
| AMD drivers | ✓ | ✓ |
| Ubuntu | ✓ | ✓ |
| Debian | ✓ | ✓ |
| Fedora | ✓ | ✓ |
| Rocky Linux | ✓ | ✓ |
| AlmaLinux | ✓ | ✓ |
| openSUSE | ✓ | ✓ |
| Linux Mint | ✓ | ✓ |
| Arch Linux | ✓ | ✓ |
| CachyOS | ✓ | ✓ |
| Garuda Linux | ✓ | ✓ |
| Manjaro | ✓ | ✓ |
| EndeavourOS | ✓ | ✓ |
| Pop!_OS | ✓ | ✓ |
| Nobara | ✓ | ✓ |
| SteamOS | ✓ | ✓ |
| Xbox / PlayStation | — | — |

> **Why no Xbox/PlayStation?** Consoles cannot install custom CA certificates. Redirecting their CDN domains would break TLS with no fallback — the console keeps retrying our proxy IP and never reaches the real CDN. They are intentionally omitted from DNS so consoles work normally (uncached but unbroken). Xbox *PC* (Game Pass for PC) can be added manually; see [`services/dns/cdn-domains.txt`](services/dns/cdn-domains.txt).

## Requirements

- Docker with Compose
- **Production**: a Linux host with two LAN IP addresses (one per mode); IPv6 optional

## Quick start — without cloning the repo

No git required. Download the two config files and run:

```bash
# Download config files
curl -O https://raw.githubusercontent.com/wiki-mod/lancache-ng/master/deploy/quickstart/.env
curl -O https://raw.githubusercontent.com/wiki-mod/lancache-ng/master/deploy/quickstart/docker-compose.yml

# Edit .env: set your LAN IPs and cache paths
# Then create cache directories
mkdir -p /srv/lancache/standard /srv/lancache/ssl

# Pull images and start
docker compose pull && docker compose up -d

# Retrieve the CA certificate for SSL mode
docker compose cp proxy-ssl:/etc/nginx/ssl/ca/ca.crt ./ca.crt
```

Install `ca.crt` on clients that should use SSL mode — see [`docs/install-ca-cert.md`](docs/install-ca-cert.md).

> **Domain lists** are baked into the images. To permanently add your own CDN domains, clone the repo and use `deploy/prod/` instead.

## Quick start — development (from source)

```bash
git clone https://github.com/wiki-mod/lancache-ng.git
cd lancache-ng
docker compose -f deploy/dev/docker-compose.yml up --build
```

On first start the CA certificate is generated automatically. Copy `certs/ca.crt` to your client and install it (required only for SSL mode).

DNS ports in dev are offset to avoid conflicts with the Windows DNS client:

| Service | Port |
|---------|------|
| Standard DNS | `127.0.0.1:5300` |
| SSL DNS | `127.0.0.1:5353` |
| Standard proxy HTTP | `127.0.0.1:8080` |
| SSL proxy HTTP/HTTPS | `127.0.0.1:80/443` |
| Admin UI | `127.0.0.1:9090` |

## Production setup (from source)

### 1. Two LAN IPs

The server needs two IPs on the LAN — one per mode. Add the second:

```bash
ip addr add 192.168.234.11/24 dev eth0
# Make permanent: add to /etc/network/interfaces or netplan
```

### 2. Configure IPs

Edit `deploy/prod/.env`:

```
IP_STANDARD=192.168.234.10
IP_SSL=192.168.234.11
```

Edit `config/prod/dns-standard.env` and `config/prod/dns-ssl.env` with the matching IPs.

### 3. Cache directories

```bash
mkdir -p /srv/lancache/standard /srv/lancache/ssl
```

Cache sizes are configured in `config/prod/proxy.env` (default: 500 GB each).

### 4. Start

```bash
docker compose -f deploy/prod/docker-compose.yml up -d --build
```

On the very first start, the `proxy-ssl` container generates a CA certificate automatically and prints clear instructions in the log:

```bash
docker compose -f deploy/prod/docker-compose.yml logs proxy-ssl
```

### 5. Install the CA certificate on clients (SSL mode only)

After the first start, `certs/ca.crt` exists in the lancache-ng directory on the server. Copy it to each client and install it — see [`docs/install-ca-cert.md`](docs/install-ca-cert.md) for step-by-step instructions per OS.

This step is only required for clients using the SSL mode (`192.168.234.11`). Clients using the standard mode (`192.168.234.10`) need no certificate.

### 6. Point clients to the cache

Configure DNS on each client (or via DHCP option 6) to point to `192.168.234.10` (standard) or `192.168.234.11` (SSL).

## Admin UI

A web interface is available at `http://<server>:8080` (dev: port 9090). It provides:

- Cache fill level and hit statistics for both modes
- nginx connection metrics via Netdata
- Live access log view
- Domain list editor (add/remove CDN domains without rebuilding)
- Setup guide for transparent proxy and client configuration

The setup guide at `/setup` includes copy-paste commands for iptables/nftables transparent proxy, apt/pacman/dnf package manager proxy config, and CA certificate installation steps.

## Adding more CDN domains

1. **DNS** — add the hostname to [`services/dns/cdn-domains.txt`](services/dns/cdn-domains.txt)
2. **SSL certs** — add the root domain to [`services/proxy/cdn-ssl-domains.txt`](services/proxy/cdn-ssl-domains.txt) (subdomains are covered automatically by the wildcard cert)
3. Rebuild: `docker compose ... up --build`

Or use the domain list editor in the admin UI — no rebuild needed, changes apply after a container restart.

## Architecture

```
services/proxy/           nginx — HTTP + HTTPS caching (SSL mode)
services/proxy-standard/  nginx — HTTP caching + HTTPS passthrough (standard mode)
services/dns/             dnsmasq — shared DNS server image, used by both modes
services/ui/              Rust/Axum admin UI (port 8080)
config/dev/               development settings (small cache, query logging on)
config/prod/              production settings (large cache, query logging off)
certs/                    CA certificate (auto-generated on first start)
deploy/dev/               docker-compose for local development
deploy/prod/              docker-compose for production (with build context)
deploy/quickstart/        docker-compose for pull-only deployment (no repo clone)
docs/                     end-user guides
```

## License

MIT
