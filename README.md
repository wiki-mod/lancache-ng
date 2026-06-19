# lancache-ng

A LAN cache for game and software downloads — intercepts CDN traffic at the DNS level and serves cached files locally. Built as a modern alternative to [lancachenet](https://github.com/lancachenet) with two additions: **SSL interception** and **IPv6 support**.

## How it works

Clients point their DNS to this server. The DNS server returns the proxy's IP for known CDN hostnames. The proxy fetches and caches the content on first request; every subsequent client on the LAN gets it from the local cache at full network speed.

## Two modes

| Mode | DNS IP | HTTP | HTTPS | CA cert required? |
|------|--------|------|-------|-------------------|
| **Standard** | `192.168.234.10` | cached | passthrough to CDN | **No** |
| **SSL** | `192.168.234.11` | cached | cached (TLS intercepted) | Yes |

**Standard mode** is the default and works on every device including consoles — no certificate needed. HTTP downloads are cached; HTTPS connections are forwarded transparently.

**SSL mode** additionally caches HTTPS downloads by intercepting TLS. Clients must install a CA certificate once. Delivers higher cache hit rates for games that use HTTPS CDNs (Epic, EA, Blizzard, …). This mode is **optional** — you can run Standard mode only with a single IP.

> **Why no Xbox/PlayStation?** Consoles cannot install custom CA certificates. They are intentionally omitted from DNS so they reach real CDNs directly — uncached but fully functional. Xbox *PC* (Game Pass for PC) works and can be added to the domain list.

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
| Ubuntu / Debian / Fedora / Arch … | ✓ | ✓ |
| SteamOS | ✓ | ✓ |
| Xbox / PlayStation | — | — |

---

## Setup: Native / VM

### Requirements

- Linux host (Debian 13 recommended)
- Docker with Compose plugin
- **Standard mode only:** one LAN IP
- **Both modes:** two LAN IPs on the same interface

### 1. Configure two LAN IPs

Add a second IP address to your network interface. The method depends on your OS:

**Debian/Ubuntu (netplan):**
```yaml
# /etc/netplan/01-netcfg.yaml
network:
  ethernets:
    eth0:
      addresses:
        - 192.168.234.10/24
        - 192.168.234.11/24
```
```bash
sudo netplan apply
```

**Debian (interfaces):**
```
# /etc/network/interfaces
auto eth0
iface eth0 inet static
    address 192.168.234.10/24

auto eth0:1
iface eth0:1 inet static
    address 192.168.234.11/24
```

> If you only want **Standard mode**, skip the second IP and ignore all `IP_SSL` references below.

### 2. Clone and configure

```bash
cd /opt
git clone https://github.com/wiki-mod/lancache-ng.git
cd lancache-ng
```

Edit `deploy/prod/.env`:
```env
IP_STANDARD=192.168.234.10
IP_SSL=192.168.234.11
```

Edit `config/prod/dns-standard.env` and `config/prod/dns-ssl.env` — set `PROXY_IP` to the matching IP in each file.

Edit `config/prod/proxy.env` — set `CACHE_MAX_SIZE` to match your available disk space.

### 3. Create cache directories

```bash
mkdir -p /opt/lancache-ng/cache/standard /opt/lancache-ng/cache/ssl
```

Update `deploy/prod/.env` if you changed the paths:
```env
CACHE_DIR_STANDARD=/opt/lancache-ng/cache/standard
CACHE_DIR_SSL=/opt/lancache-ng/cache/ssl
```

### 4. Start

```bash
docker compose -f deploy/prod/docker-compose.yml up -d --build
```

### 5. SSL mode: install the CA certificate on clients

> Skip this step if you only use Standard mode.

On first start, `proxy-ssl` generates a CA certificate automatically. Retrieve it:

```bash
docker compose -f deploy/prod/docker-compose.yml cp proxy-ssl:/etc/nginx/ssl/ca/ca.crt ./certs/ca.crt
```

Then install it on each client that should use SSL mode:

| Platform | Script |
|----------|--------|
| **Windows** | `scripts\install-ca-cert.ps1` (run as Administrator) |
| **Linux** | `scripts/install-ca-cert.sh` |
| **Manual** | See [`docs/install-ca-cert.md`](docs/install-ca-cert.md) |

### 6. Point clients to the cache

Set DNS on each client (or via DHCP option 6):

- **Standard mode (no cert needed):** DNS → `192.168.234.10`
- **SSL mode (cert required):** DNS → `192.168.234.11`

---

## Setup: Proxmox LXC

Running lancache-ng inside a Proxmox LXC container works well. Two variants:

---

### Unprivileged container (recommended)

Unprivileged containers are more secure — processes inside cannot gain host root even if compromised.

#### 1. Create the container

In the Proxmox web UI, create a new LXC container:
- Template: Debian 13
- Disk: at least your intended cache size + 10 GB for the OS
- **Network: add two network interfaces** — one per mode (or one if Standard only)
  - `eth0`: IP `192.168.234.10/24`, gateway
  - `eth1`: IP `192.168.234.11/24` (no gateway needed)

#### 2. Enable Docker support

Add to `/etc/pve/lxc/<id>.conf` on the **Proxmox host**:

```
features: nesting=1,keyctl=1
lxc.apparmor.profile: unconfined
```

Restart the container after editing.

#### 3. Fix ownership of cache directories (Proxmox host)

In unprivileged containers, the root user inside maps to UID 100000 on the host. Create the cache directories and fix ownership **on the Proxmox host**:

```bash
mkdir -p /opt/lancache-ng/cache/standard /opt/lancache-ng/cache/ssl
chown -R 100000:100000 /opt/lancache-ng/cache/
```

Then bind-mount them into the container by adding to `/etc/pve/lxc/<id>.conf`:
```
mp0: /opt/lancache-ng/cache,mp=/opt/lancache-ng/cache
```

#### 4. Fix port 53 (Proxmox host)

Unprivileged containers cannot bind to ports below 1024 by default. On the **Proxmox host**:

```bash
echo 'net.ipv4.ip_unprivileged_port_start=53' >> /etc/sysctl.conf
sysctl -p
```

#### 5. Install Docker inside the container

```bash
curl -fsSL https://get.docker.com | sh
```

#### 6. Continue with Native setup

From step 2 of the Native setup onwards — clone to `/opt/lancache-ng`, configure IPs, start.

---

### Privileged container

> ⚠️ **Warning:** Privileged containers share the host kernel namespace. A container escape could give an attacker host root access. Only use this on trusted, isolated networks.

Privileged containers are simpler — Docker works without extra configuration.

#### 1. Create the container

Same as above, but leave **Unprivileged container** unchecked in the Proxmox UI.

Add two network interfaces as above (eth0 + eth1, one IP each).

#### 2. Install Docker inside the container

```bash
curl -fsSL https://get.docker.com | sh
```

#### 3. Continue with Native setup

From step 2 of the Native setup onwards.

---

## Quick start — without cloning the repo

No git required. Download the two config files and run:

```bash
curl -fsSL -o .env https://raw.githubusercontent.com/wiki-mod/lancache-ng/master/deploy/quickstart/.env
curl -fsSL -o docker-compose.yml https://raw.githubusercontent.com/wiki-mod/lancache-ng/master/deploy/quickstart/docker-compose.yml

# Edit .env: set your LAN IPs and cache paths, then:
mkdir -p /opt/lancache-ng/cache/standard /opt/lancache-ng/cache/ssl
docker compose pull && docker compose up -d
```

---

## Development setup

```bash
git clone https://github.com/wiki-mod/lancache-ng.git
cd lancache-ng
docker compose -f deploy/dev/docker-compose.yml up --build -d
```

DNS ports are offset to avoid conflicts with the Windows DNS client:

| Service | Dev port |
|---------|----------|
| Standard DNS | `127.0.0.1:5300` |
| SSL DNS | `127.0.0.1:5353` |
| Standard proxy | `127.0.0.1:8080` |
| SSL proxy | `127.0.0.1:80/443` |
| Admin UI | `127.0.0.1:9090` |

### Smoke test (copy-paste, works in Git Bash and PowerShell)

```bash
# 1. All containers healthy?
docker compose -f deploy/dev/docker-compose.yml ps

# 2. DNS resolves CDN hostnames to the proxy?
docker exec lancache-dns-standard dig @127.0.0.1 steamcontent.com A +short
#    → should print 127.0.0.1

# 3. Proxy reachable and serving?
curl -sf http://127.0.0.1:8080/healthz
#    → ok

# 4. Proxy caches a real CDN request (first: MISS, second: HIT)
curl -sf -o /dev/null -w "%{http_code} %{size_download}B in %{time_total}s\n" \
  --resolve "steamcontent.com:8080:127.0.0.1" \
  "http://steamcontent.com/"
#    → 200 (or 301/302 — CDN redirect is normal on bare /)

# 5. Watchdog status (services green, disk %, purge timer)
docker compose -f deploy/dev/docker-compose.yml exec watchdog \
  cat /var/run/watchdog/status.json

# 6. Watchdog logs (shows check results, any restarts)
docker compose -f deploy/dev/docker-compose.yml logs watchdog --tail=20
```

---

## Adding CDN domains

1. **DNS** — add the hostname to [`services/dns/cdn-domains.txt`](services/dns/cdn-domains.txt)
2. **SSL certs** — add the root domain to [`services/proxy/cdn-ssl-domains.txt`](services/proxy/cdn-ssl-domains.txt)
3. Rebuild: `docker compose ... up --build`

Or use the domain editor in the Admin UI — no rebuild needed.

---

## Admin UI

Available at `http://<server-ip>:8080`.

- Cache fill level and hit/miss statistics
- Live access log
- Domain list editor
- Netdata system metrics (CPU, RAM, network throughput, disk I/O)
- Setup guide with copy-paste commands

---

## Watchdog

The watchdog container monitors all services and keeps the stack running automatically.

| Feature | Detail |
|---------|--------|
| **Health monitoring** | Polls each container's Docker health status every 30 s |
| **Auto-restart** | Restarts a container after 3 consecutive failed health checks |
| **Purge cron** | Daily: deletes cache files older than `CACHE_VALID_DAYS` (default 365 d) |
| **Disk monitoring** | Checks real filesystem usage; warns at 85%, alarms at 95% |
| **Status file** | Writes `/var/run/watchdog/status.json` — read by the Admin UI |

The watchdog uses a [Docker socket proxy](https://github.com/Tecnativa/docker-socket-proxy) (`CONTAINERS + POST` only) instead of the raw Docker socket — exec and image operations are blocked at the proxy level.

Tune thresholds in `config/prod/watchdog.env` (or `config/dev/watchdog.env` for dev):

```env
CHECK_INTERVAL=30      # seconds between checks
RESTART_AFTER=3        # failures before restart
DISK_WARN_PCT=85       # yellow in Admin UI
DISK_ALARM_PCT=95      # red in Admin UI
CACHE_VALID_DAYS=365   # purge files older than this
```

---

## Architecture

```
services/proxy/           nginx — HTTP + HTTPS caching (SSL mode)
services/proxy-standard/  nginx — HTTP caching + HTTPS passthrough (standard mode)
services/dns/             BIND9 DNS server with RPZ (shared by both modes)
services/watchdog/        health monitor, auto-restart, purge cron
services/ui/              Rust/Axum admin UI
config/dev/               development settings
config/prod/              production settings
certs/                    CA certificate (auto-generated on first start)
deploy/dev/               docker-compose for development
deploy/prod/              docker-compose for production
deploy/quickstart/        docker-compose for pull-only deployment
docs/                     end-user guides
scripts/                  CA certificate install scripts
```

---

## License

MIT
