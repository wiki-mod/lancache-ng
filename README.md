# lancache-ng

You have multiple PCs or consoles on your home network and everyone keeps downloading the same games. lancache-ng fixes that — it caches game and software downloads locally so every PC after the first gets it at full LAN speed instead of waiting for the internet.

Once it's running, your clients just point their DNS at the cache. Everything else is automatic.

## Two modes

**Standard mode** — no setup needed on clients. HTTP downloads are cached. HTTPS connections are passed through directly to the CDN. Works on every device including consoles.

**SSL mode** — HTTP and HTTPS downloads are both cached. Clients install a small CA certificate once (takes 30 seconds). Gives better cache hit rates for games that use HTTPS CDNs like Epic, EA, and Blizzard.

Both modes run at the same time on two separate IPs. Clients choose which one to use by setting their DNS server.

## What gets cached

Steam, Epic Games, GOG, EA/Origin, Blizzard, Ubisoft, Riot, Rockstar, Warframe, Path of Exile, Guild Wars 2, Windows Update, Microsoft Office, NVIDIA and AMD drivers, most Linux package mirrors, and more.

Xbox and PlayStation consoles are intentionally not cached — they can't install custom CA certificates, so HTTPS caching would break them. They continue working normally by going directly to their CDNs.

---

## Requirements

- A Linux machine that stays on (a small PC, a Raspberry Pi 5, a Proxmox VM, whatever)
- Docker with the Compose plugin
- Enough disk space for your cache (500 GB is a good starting point for a few gamers)
- For SSL mode: a second IP address on the same network interface

---

## Quick start

The fastest way to get running — no git clone needed:

```bash
curl -fsSL https://raw.githubusercontent.com/wiki-mod/lancache-ng/master/setup.sh | bash
```

The setup script asks a few questions (IPs, cache size, where to store files) and starts everything automatically.

---

## Manual setup

If you prefer to do it yourself:

```bash
cd /opt
git clone https://github.com/wiki-mod/lancache-ng.git
cd lancache-ng
```

**1. Set your IPs** — edit `deploy/prod/.env`:
```env
IP_STANDARD=192.168.1.10
IP_SSL=192.168.1.11
```
If you only want standard mode, set both to the same IP and skip the second IP setup.

**2. Create cache directories:**
```bash
mkdir -p /opt/lancache-ng/cache/standard /opt/lancache-ng/cache/ssl
```

**3. Start:**
```bash
docker compose -f deploy/prod/docker-compose.yml up -d --build
```

**4. SSL mode only — get the CA certificate:**

After the first start, copy the generated certificate to your clients:
```bash
docker compose -f deploy/prod/docker-compose.yml cp proxy-ssl:/etc/nginx/ssl/ca/ca.crt ./certs/ca.crt
```

Then install it on each client using SSL mode:
| | |
|---|---|
| Windows | `scripts\install-ca-cert.ps1` (run as Administrator) |
| Linux | `scripts/install-ca-cert.sh` |
| Manual | [docs/install-ca-cert.md](docs/install-ca-cert.md) |

---

## Point your clients at the cache

Change the DNS server on each device (or push it via DHCP):

- **No certificate:** DNS → `192.168.1.10`
- **SSL mode (certificate installed):** DNS → `192.168.1.11`

That's it. The first download of anything goes to the internet as normal. Every download after that comes from the cache.

---

## Does it work?

On any PC that's pointing at the cache DNS:

```
nslookup steamcontent.com
```

If the answer is the cache server's IP instead of a real CDN IP, DNS is working.

Then download something twice. The second time should be noticeably faster — that's the cache serving it.

---

## Proxmox

Running in an LXC container works well. Use an unprivileged container if possible.

In `/etc/pve/lxc/<id>.conf` on the Proxmox host:
```
features: nesting=1,keyctl=1
lxc.apparmor.profile: unconfined
```

For port 53 in unprivileged containers:
```bash
echo 'net.ipv4.ip_unprivileged_port_start=53' >> /etc/sysctl.conf && sysctl -p
```

Give the container two network interfaces (eth0 + eth1, one IP each) and follow the normal setup from there.

---

## Adding more games

Edit `services/dns/cdn-domains.txt` to add CDN hostnames for DNS. Edit `services/proxy/cdn-ssl-domains.txt` for SSL certificate coverage. Then rebuild:

```bash
docker compose -f deploy/prod/docker-compose.yml up --build -d
```

Or use the domain editor in the Admin UI — no rebuild needed.

---

## Admin UI

Opens at `http://<server-ip>:8080`. Shows cache fill level, hit/miss rates, active downloads, and lets you manage domains and settings without touching config files.

---

## License

MIT
