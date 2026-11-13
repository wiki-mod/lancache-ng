<p align="center">
  <img src="gfx/logo-readme.png" alt="LanCache-NG logo" width="220">
</p>

# lancache-ng

[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/13763/badge)](https://www.bestpractices.dev/projects/13763)
[![OpenSSF Baseline](https://www.bestpractices.dev/projects/13763/baseline)](https://www.bestpractices.dev/projects/13763)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](LICENSE)

LanCache NG is a local download cache for your home network, LAN party, lab, school, office or gaming room.

It stores game and software downloads inside your local network.  
The first download still comes from the internet.  
The next download can come from your local cache at LAN speed.

This is useful when multiple PCs download the same games, updates or drivers.  
It can reduce internet traffic, save bandwidth and make repeated downloads much faster.

## Project status

LanCache NG is still actively changing.

The current setup already provides the main stack, guided installation, Admin UI, DNS based cache routing, optional HTTPS caching, optional DHCP, optional LanCache-NG-NTP server, optional scheduled automatic updates, and secondary DNS support.

Some internal paths, root elements and service details may still change while the project grows.

## What this project does

LanCache NG combines several services into one Docker based stack:

- DNS service
  - for redirecting known CDN domains to your local cache
- Nginx cache proxy for plain HTTP caching
  - optional HTTPS cache proxy for HTTPS capable clients
- Admin UI for cache status, domains, DNS records, DHCP leases and settings
  - optional Kea DHCP server
  - optional DHCP-Dnsmasq-based proxy helper
  - LanCache-NG-NTP server (chrony), disciplined against public NTP servers, serving LAN clients on UDP/123; asked at install (default: on)
  - optional scheduled automatic updates (ordered, health-gated, Admin UI last)
  - watchdog and convergence checks
  - optional secondary DNS nodes synced by NOTIFY and AXFR

The goal is simple:

Your clients use LanCache NG as DNS server.  
Known download domains are answered with the cache IP.  
The cache proxy downloads and stores the requested files.  
Later clients can receive the same files from your LAN.

## Quick start

Run this on a Linux machine inside your network:

```bash
curl -fsSL https://raw.githubusercontent.com/wiki-mod/lancache-ng/master/setup.sh | sudo bash -s -- install
```

The setup script guides you through the installation. If required tools are missing, it installs them, such as Docker, curl and git, through the host package manager (apt, dnf, yum, pacman or apk) without a question and prints one "Installing requirements" line with the package names.
It is a pull-only installer: it resolves and pulls prebuilt first-party images,
so Redis-backed sccache, distcc and other build accelerators do not affect
normal setup or update paths.

It can:

- check the required tools
- install missing dependencies such as Docker, curl or git without a question
- ask for the release channel first (`latest` or `nightly`)
- clone the code of that channel to `/opt/lancache-ng/latest` or
  `/opt/lancache-ng/nightly`
- ask for the cache server IP
- ask for a second LAN IP (always required) and HTTPS caching (default: on)
- ask for cache directory and cache size
- optionally enable scheduled automatic updates (a host systemd timer)
- create pre-update rollback backups
- create config-only or full backups
- restore setup-script backups
- optionally enable DHCP
- optionally protect the Admin UI with a password
- write `deploy/prod/.env.local` in the channel's code directory
- create required directories
- start the Docker stack
- install systemd startup and convergence checks

Default installation path:

```text
/opt/lancache-ng            data (cache, DNS, DHCP, CA, ...)
/opt/lancache-ng/latest     code of the latest channel (master)
/opt/lancache-ng/nightly    code of the nightly channel (current_dev)
/opt/lancache-ng/current    link to the channel that runs
```

One stack runs at a time: both channels use the same ports and data.
`nightly` is experimental: untested daily builds that may break the stack;
it is not for production use.

After setup, open the Admin UI:

```text
http://<server-ip>:8080
```

Example:

```text
http://192.0.2.10:8080
```

## The two operating modes

LanCache NG can run in two modes.

### HTTP mode

HTTP mode is the safest and easiest mode.

It does not need a certificate on the clients.

Use this mode if you want maximum compatibility.

HTTP mode:

- caches HTTP downloads
- passes HTTPS traffic through normally
- works without client certificate setup
- works well for PCs, consoles and general devices
- is the recommended first test mode

Example DNS target:

```text
192.0.2.10
```

### HTTPS mode

HTTPS mode is optional.

It can cache HTTP and HTTPS downloads, but it needs a locally generated Root CA certificate on every client that should use HTTPS caching.

Use this mode only for devices you own and trust.

HTTPS mode:

- needs a second LAN IP
- needs the generated CA certificate installed on each client
- can improve cache hit rates for launchers and CDNs using HTTPS
- is useful for Windows gaming PCs
- is not suitable for most consoles

Example DNS target:

```text
192.0.2.11
```

### Running both modes together

Both modes can run at the same time.

Example:

| Mode | Client setup | DNS server |
|---|---|---|
| HTTP mode | no certificate needed | `192.0.2.10` |
| HTTPS mode | CA certificate installed | `192.0.2.11` |

This lets you decide per client.

A console can use HTTP mode.  
A gaming PC with the certificate installed can use HTTPS mode.

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
Some downloads use HTTPS in a way that only works with HTTPS mode.  
Some clients may bypass the cache completely.

The first download is normally a cache miss.  
The second identical download is where the cache should help.

### Cache policy

LanCache NG is not a generic forward proxy. It is designed to force caching for known game,
software and update CDN downloads that you intentionally route through the cache.

The nginx cache key intentionally uses the host and path, not the full request URI with the
query string. Many CDN download URLs include per-request signatures or expiry tokens in the
query string. Including those values in the cache key would make each signed URL look like a
different object and would greatly reduce cache hits. On a cache miss (or once the cached entry has expired), the full request URI including the query string is forwarded to the upstream CDN for validation. Cache hits within the configured validity window are served directly from the local cache without contacting upstream.

For the same reason, LanCache NG intentionally ignores selected upstream cache headers such as
`Cache-Control`, `Expires`, `Vary` and `Set-Cookie` for cached download responses. Do not use
LanCache NG as a general-purpose proxy, and only add CDN domains that you understand and want
to cache.

## Console support

Xbox, PlayStation and similar consoles should usually use HTTP mode.

They normally cannot install a custom Root CA certificate in a useful way.  
Because of that, HTTPS caching is not recommended for consoles.

Consoles should continue to work normally through HTTP mode.  
HTTPS traffic that cannot be cached is passed through to the original CDN.


## Requirements

You need:

- a Linux machine that stays online
- Docker with the Docker Compose plugin
- a static LAN IP for the cache server
- enough disk space for the cache
- port `53` free for DNS
- port `80` free for HTTP cache traffic
- port `443` free on both LAN IPs
- port `5300` free on the HTTP IP (zone transfer to secondary DNS nodes of older versions)
- port `8080` for the Admin UI
- a second LAN IP (always required; HTTPS mode answers on it)
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
curl -fsSL https://raw.githubusercontent.com/wiki-mod/lancache-ng/master/setup.sh | sudo bash -s -- install
```

During setup you will be asked for the important values. If required tools are missing, setup installs them without a question and prints one "Installing requirements" line with the package names.

Example values:

| Setting | Example |
|---|---|
| HTTP mode IP | `192.0.2.10` |
| HTTPS mode IP | `192.0.2.11` |
| data directory | `/opt/lancache-ng` |
| code directory | `/opt/lancache-ng/current` |
| cache directory (shared) | `/opt/lancache-ng/cache` |
| cache size | `500` GiB |
| Admin UI port | `8080` |

After setup, check the containers:

```bash
sudo /opt/lancache-ng/current/setup.sh compose /opt/lancache-ng ps
```

Open the Admin UI:

```text
http://<http-ip>:8080
```

## Updating

If you installed with the setup script, update with:

```bash
sudo /opt/lancache-ng/current/setup.sh update
```

The update command can:

- create a config-only rollback backup before changing the stack
- pull the current repository state
- update the compose file
- pull newer images
- restart every service except the Admin UI first, verify the whole non-UI
  set is actually healthy, then restart the Admin UI last
- automatically roll back to the pre-update backup if that health check fails
- move the stack to the other code directory when the channel changed
  (Admin UI General page, `LANCACHE_IMAGE_CHANNEL` in
  `/opt/lancache-ng/current/deploy/prod/.env.local`, or
  `sudo LANCACHE_IMAGE_CHANNEL=nightly /opt/lancache-ng/current/setup.sh update`);
  the moved `.env.local` keeps the new channel, and a failed move points
  `/opt/lancache-ng/current` back. `nightly` is experimental and not for
  production; `setup.sh` warns when it is selected
- move an old install cloned straight into `/opt/lancache-ng` to
  `/opt/lancache-ng/latest` or `/opt/lancache-ng/nightly`; only its unchanged
  code files are removed afterwards, its data stays. If that old checkout
  still has an older `setup.sh`, run `sudo git -C /opt/lancache-ng pull` once
  first, then `sudo /opt/lancache-ng/setup.sh update`

Setup and update always consume prebuilt runtime images. They do not build the
production stack locally, so host-side build acceleration is never a runtime
or install dependency.

### Scheduled automatic updates

Instead of running `setup.sh update` manually, a host `systemd` timer
(`lancache-auto-update.timer`) can run the same ordered, health-gated update
on a schedule. Enable it at install time (the "Scheduled automatic updates"
prompt, default: disabled), later by setting `AUTO_UPDATE_ENABLED=1` in
`/opt/lancache-ng/current/deploy/prod/.env.local`, or on the Admin UI's General
page (release channel and scheduled-update toggle). The host's convergence
timer (every 5 minutes) applies either change. An update pulls and restarts
only when the selected channel moved to a new image set; an unchanged channel
is a no-op. Manual trigger:

```bash
sudo /opt/lancache-ng/current/setup.sh auto-update
```

**Update validation:** The update command validates your configuration during the process. If required config values are missing or invalid, the update will abort immediately rather than continuing with a partial or degraded configuration. If this happens, check that `/opt/lancache-ng/current/deploy/prod/.env.local` exists and contains all required keys. See `docs/README.md` (section 7) for rollback options.

Create a manual backup with:

```bash
sudo /opt/lancache-ng/current/setup.sh backup --config
sudo /opt/lancache-ng/current/setup.sh backup --full
```

Use `--config` for small update rollback backups. Use `--full` only when you also need cache objects, because full backups can be very large. Restore a backup with:

```bash
sudo /opt/lancache-ng/current/setup.sh restore /var/backups/lancache-ng/lancache-ng-config-YYYYMMDDTHHMMSSZ.tar.zst /opt/lancache-ng
```

See `docs/README.md` (section 7) for backup scope, restore testing, secret handling, CA lifecycle notes, and rollback details.

## Image Versioning and Release Channels

`LANCACHE_IMAGE_CHANNEL` selects the first-party image channel. `setup.sh`
resolves mutable channels to the immutable `LANCACHE_IMAGE_TAG` used by Docker
Compose. The interactive installer asks which channel to use, defaulting to
`latest`.

- `latest` (default) is the channel from `master`, promoted after the full
  release validation gate; release tags `vX.Y.Z` move it.
- `nightly` is built from `current_dev`'s tip once a day plus on-demand
  (formerly `edge`). It is experimental, may break the stack and is not for
  production; `setup.sh` warns on install and on every update.
- `pinned` with `LANCACHE_IMAGE_TAG` set to a release tag (`vX.Y.Z`,
  `vX.Y.Z-rc.N`) or `sha-<40-hex commit SHA>` pins all stack services to one
  immutable tag. Other tag values are rejected.

Recommended for production:

- Use `latest` for normal deployments.
- Use `pinned` with a release tag (for example `v1.2.3`) for pinned deployments.
- Use `nightly` or `sha-*` tags only for temporary test environments.

### Pinning the standalone installer's git ref

The installer clones the code of the chosen channel into its directory:
`latest` from `master` into `/opt/lancache-ng/latest`, `nightly` from
`current_dev` into `/opt/lancache-ng/nightly`. Set `LANCACHE_SETUP_GIT_REF`
to a branch or tag to clone that ref into the channel's directory instead,
for example to validate a pre-release branch:

```bash
curl -fsSL https://raw.githubusercontent.com/wiki-mod/lancache-ng/master/setup.sh | sudo LANCACHE_SETUP_GIT_REF=vX.Y.Z bash -s -- install
```

A checkout on a branch that is no channel branch installs from where it is,
with a warning.

## Debug information

If something does not work, run:

```bash
sudo /opt/lancache-ng/current/setup.sh debug
```

The debug command prints:

- container status
- recent logs
- cache usage
- detected LAN IPs
- health check results

You can also view live logs manually:

```bash
sudo /opt/lancache-ng/current/setup.sh compose /opt/lancache-ng logs -f
```

### Reporting a bug

If you need to open a GitHub issue for something that isn't working, run:

```bash
sudo /opt/lancache-ng/current/setup.sh create-logs-for-issue
```

This bundles everything a maintainer needs to triage the report into one
compressed, timestamped archive and prints its path:

- `docker compose logs`/`ps`/`config` output
- a copy of `.env`/`.env.local` with every credential-shaped value (API keys,
  TSIG keys, passwords, tokens) redacted
- host facts (Docker/Compose versions, kernel, disk space)
- known-good-snapshot directory listings (file names only, no content) --
  see `docs/README.md` (section 6)

Review the archive yourself before attaching it to an issue -- this command
never uploads or attaches anything automatically.

## Point your clients to the cache

LanCache NG works by DNS.

A client must use the LanCache NG DNS IP.  
You can set that manually per client or distribute it through DHCP.

Example:

| Client type | DNS server |
|---|---|
| normal client without certificate | `192.0.2.10` |
| HTTPS client with certificate installed | `192.0.2.11` |

On many routers you can set the DNS server handed out by DHCP.  
Set it to the LanCache NG HTTP IP if you want all clients to use HTTP mode.

For HTTPS mode, only point clients to the HTTPS IP after the CA certificate was installed.

## Optional DHCP

LanCache NG only caches traffic for clients that resolve CDN hostnames through
its DNS servers. DHCP is the most reliable way to hand those DNS servers to
clients. `setup.sh` lets you pick one of four DHCP modes (stored as
`DHCP_MODE` in `.env.local`):

- `off` (default) — LanCache NG does not manage or proxy DHCP. You point clients at
  its DNS yourself (router DHCP option or static client config). This is the
  right starting point for most users.
- `kea` — LanCache NG runs a full Kea DHCP server that hands out IP address,
  gateway, and the correct cache DNS servers, and supports reservations and
  lease management in the Admin UI. Use this only when you are ready to make
  LanCache NG the network's DHCP server — configure and confirm Kea is running
  here first, then disable your router's built-in DHCP server, not the other
  way around (see [docs/README.md](docs/README.md#5-dhcp-modes) for why the order
  matters).
- `dnsmasq-proxy` — LanCache NG runs dnsmasq in proxy-DHCP mode next to an
  existing DHCP server for networks where the router or ISP gateway keeps DHCP
  enabled and cannot be disabled. It does not own leases and is limited to
  proxy/PXE clients; it does not reliably replace the DNS option handed out by
  a normal router DHCP server.
- `dnsmasq-relay` — LanCache NG runs dnsmasq as a real DHCP relay, forwarding
  each client's DHCP request to an upstream DHCP server on **another network
  segment** and relaying the reply back. Use this when clients and their DHCP
  server are on different subnets/VLANs and the client broadcasts can't reach
  the server directly. It injects nothing of its own — the upstream server owns
  the whole lease.

The four modes are mutually exclusive — Kea and dnsmasq both bind DHCP port
`67/udp`, so setup activates exactly one, and switching modes in the Admin UI
stops the other service. The two dnsmasq modes (`dnsmasq-proxy` and
`dnsmasq-relay`) share one container and are also mutually exclusive.

Important: do not run two normal DHCP servers in the same network unless you
planned it carefully. If your router already provides DHCP, either keep using
the router (and set DNS another way) or switch DHCP fully to LanCache NG.

See [docs/README.md](docs/README.md#5-dhcp-modes) for when to use each mode, what is
not available in `dnsmasq-proxy` mode, how to set the upstream DHCP IP, and how
to verify clients actually receive the LanCache NG DNS servers.

## Optional NTP

LanCache-NG-NTP is a small NTP server (chrony). `setup.sh install` asks for it
(default: on); the Admin UI's General page switches it later. It disciplines
its clock against a list of public NTP servers and serves time to LAN clients
on `123/udp`. The upstream server list is edited on the same page.

The General page also has a toggle "Hand this time server to DHCP clients"
(`NTP_AUTO_DHCP`). While it and LanCache-NG-NTP are on, every DHCP subnet
hands out the HTTP IP as NTP server (option 42) instead of
`DHCP_NTP_SERVERS`. When one of them is turned off, subnets that held the
HTTP IP get `DHCP_NTP_SERVERS` back.

## Admin UI

The Admin UI is available after setup:

```text
http://<server-ip>:8080
```

The Admin UI can be used for:

- Dashboard: cache overview, fill level, active downloads, container status
- Logs
- Statistics: hit and miss statistics
- Steam: CacheHamster prefill
- DNS: cached domains, LAN DNS records, secondary DNS management
- DHCP: mode and leases
- General: settings, release channel, scheduled updates, NTP

If the setup asks whether the Admin UI should be password protected, using a password is recommended.

Do not expose the Admin UI to the internet.

Settings changed in the Admin UI are saved in `lancache-ui-settings.env` in the UI data folder (`UI_SETTINGS_FILE` and `UI_DATA_DIR` in `.github/yaml/build-manifest.yml`). They win over the built-in defaults and survive an update. The nginx templates of the proxy are kept in `services/ui/nginx/` and are rendered into the proxy config folder (`NGINX_CONF_DIR`).

## HTTPS mode certificate

HTTPS mode generates a local CA certificate.

Clients using HTTPS mode must trust this certificate.

After the first start, the certificate is in the CA state directory
(`CA_DIR`, by default below `LANCACHE_STATE_DIR`). `setup.sh` prints its path.

### Install on clients

Follow the per-platform steps (Windows, Linux, macOS, Firefox, Steam Deck,
consoles) and keep the CA backed up:

```text
docs/README.md   (section 4: CA certificate, section 7: backup and restore)
```

### Firefox note

Firefox can use its own certificate store.  
If HTTPS caching does not work in Firefox, import the certificate into Firefox too.

### Steam Deck note

Steam Deck can require extra handling because the system is more locked down than a normal Linux desktop.  
See the certificate documentation before using HTTPS mode on it.

## Testing DNS

On a client using LanCache NG as DNS server, run:

```bash
nslookup lancache.steamcontent.com
```

or specify the DNS server directly:

```bash
nslookup lancache.steamcontent.com 192.0.2.10
```

`steamcontent.com` itself is not redirected; only its subdomains are.

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

Manual domain file:

```text
services/dns/cdn-domains.txt
```

One list drives DNS cache routing and the HTTPS mode certificates. The Admin
UI derives each entry's registrable root domain and generates a wildcard
certificate for it; there is no separate HTTPS domain file.

After a manual file change, restart `ui`. It renders the DNS and proxy
configuration and then restarts `dns` and `proxy`:

```bash
sudo /opt/lancache-ng/current/setup.sh compose /opt/lancache-ng restart ui
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

Secondary DNS nodes pull the zones from the primary by AXFR. The primary
sends NOTIFY on every change. A secondary sends its logs to the primary by
syslog.

Setup example:

Run it as root, in a terminal (`bash <(curl …)` keeps the terminal for the
questions; `curl … | bash` would not):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wiki-mod/lancache-ng/master/setup.sh) secondary
```

The registration token is generated during primary setup and stored in the primary's `.env.local`;
the Admin UI shows it under DNS, Secondary DNS.

The order is: check, ask, then act.

1. Check: install missing requirements (curl, jq, git, Docker, Docker Compose
   v2), check the name, and check whether this host already runs a lancache
   dns container. A secondary needs its own host: if the primary (or another
   secondary) runs here, setup stops before it changes anything.
2. Ask: name, primary URL, token, whether the primary runs the latest channel,
   the DNS IP of this secondary, whether the primary has HTTPS enabled and, if
   so, whether this secondary supports it (then the primary's HTTPS IP and a
   second DNS IP of this secondary). Each answer is checked at once.
3. Act: add a missing bind IP (`ip addr add`, default yes, not persistent),
   clone the code of the channel as the primary install does, register at the
   primary, write the files and start the container.

The cache IP (`IP_HTTP`) comes from the primary. Without a terminal, pass the
values as arguments: `--primary`, `--token`, `--name`, `--listen-ip`, and for
HTTPS `--ip-https <primary https ip> --listen-ip-https <second dns ip>`;
`LANCACHE_IMAGE_CHANNEL` sets the channel.

You can also view a ready command inside the Admin UI under the secondary DNS section.

To renew the secondary's keys, rerun the same command with `--rotate`
in that secondary's install directory. This rewrites the local secondary `.env` from the primary registration API
without changing the secondary name. In a terminal, `--rotate` offers the stored
values (primary URL, bind IPs); only the token is asked again.

After setup, point additional clients to the secondary DNS IP.

### Secondaries as name servers

Each registered secondary gets an A (or AAAA) and a PTR record
`<name>.<lan domain>` on the primary. The Admin UI tab DNS, Secondary DNS
has two switches, both off by default:

| Switch | SOT key | Effect |
| --- | --- | --- |
| Enter secondaries as name servers (NS) | `DNS_SECONDARY_NS_ENABLED` | A secondary that answers the LAN zone authoritatively (`aa`) on port 53 is added to the NS records of every managed zone. |
| Take dead secondaries out as NS | `DNS_SECONDARY_NS_AUTO_REMOVE` | An entered secondary is taken out after it failed for longer than `DNS_SECONDARY_NS_REMOVE_AFTER_SECONDS` (8 h) and at least `DNS_SECONDARY_NS_REMOVE_FAILS` (3) checks in a row. |

The primary checks every secondary every `DNS_SECONDARY_CHECK_SECONDS`
(4 h), and every `DNS_SECONDARY_RECHECK_SECONDS` (1 h) while one fails. A
check compares the zone serials through the secondary's pdns-API and asks
it for an AXFR of a zone that lags. A secondary of an older version answers
port 53 with its recursor, not `aa`; it keeps syncing but is never entered.

A secondary that was taken out, by hand or by the second switch, comes back
only through "Enter NS" in its row; that button checks `aa` first.
"Remove NS" takes it out by hand. Disconnecting a secondary removes its
records and its NS entry and renews the TSIG key, as "Renew key" does: every
other secondary stops syncing until it runs `setup.sh secondary --rotate`.
A new address replaces its A and PTR record.

## Manual setup

The setup script is recommended.

Manual setup is useful if you want to inspect and control every file yourself.

Clone the repository:

```bash
git clone https://github.com/wiki-mod/lancache-ng.git /opt/lancache-ng/latest
cd /opt/lancache-ng/latest
```

`/opt/lancache-ng` is the data directory; a clone directly into it is moved to
`/opt/lancache-ng/latest` by the next `setup.sh update`.

No `.env` file is tracked. `setup.sh install` writes the untracked runtime env
file `deploy/prod/.env.local` with the values of your installation. Every
default value lives in `.github/yaml/build-manifest.yml` (`runtime.defaults`)
and is baked into the images, so `.env.local` never repeats a default. To set
the installation values by hand, create `deploy/prod/.env.local` and set at
least:

```env
IP_HTTP=192.0.2.10
IP_HTTPS=192.0.2.11

HTTPS_ENABLED=1

LANCACHE_STATE_DIR=/opt/lancache-ng

# Optional cache directory override. Leave unset unless you intentionally place
# the cache on a separate disk; setup.sh derives it from LANCACHE_STATE_DIR.
# CACHE_DIR=/opt/lancache-ng/cache

CACHE_MEM_MB=512
PROXY_SECURITY_MODE=lazy
PROXY_ALLOWED_CLIENT_CIDRS=

CACHE_MAX_GB=50

# First-party service image selector.
# latest is the channel from master, promoted after the full release
# validation gate. nightly (formerly called edge) is experimental, may break
# the stack and is not for production.
# setup.sh resolves a mutable channel to one sha256 digest per image before pull.
# Do not change LANCACHE_IMAGE_TAG by hand unless LANCACHE_IMAGE_CHANNEL=pinned.
LANCACHE_IMAGE_REGISTRY=ghcr.io
LANCACHE_IMAGE_PREFIX=wiki-mod/lancache-ng
LANCACHE_IMAGE_CHANNEL=latest
LANCACHE_IMAGE_TAG=<set-by-setup>
```

`NGINX_UPSTREAM_RESOLVER` is what nginx uses to resolve the *real* CDN hostnames it proxies to. Its default lives in `runtime.defaults` of `.github/yaml/build-manifest.yml`; put your own value in `deploy/prod/.env.local` (an empty value keeps the default), which `deploy/prod/docker-compose.yml` passes to the `ui` service (it renders `nginx.conf`), then recreate both from the repository root (`sudo ./setup.sh compose deploy/prod up -d ui proxy`). The default — `8.8.8.8 8.8.4.4` (Google Public DNS, IPv4 only; an IPv6 entry you add must be bracketed, as nginx's `resolver` directive requires) — is a convenience default, not a requirement. Set it to whatever real upstream DNS servers you prefer: your ISP's resolvers, a corporate DNS server, 1.1.1.1, or anything else. The actual requirement is that the chosen resolver returns the CDN's *real* origin address for these hostnames — not merely that its own server IP differs from the LanCache DNS/proxy IP. The Admin UI renderer rejects the obvious cases (a loopback address, `IP_HTTP` or `IP_HTTPS`), but it cannot detect an indirect loop: for example, a split-DNS or conditional-forwarding resolver that itself forwards the CDN's zone back to the LanCache DNS server would still hand nginx the LanCache proxy IP, at which point nginx loops even though the configured resolver's own IP isn't the cache's. If you use split-DNS or conditional forwarding upstream of this resolver, make sure CDN zones aren't among the forwarded ones.

`DNS_UPSTREAM_SERVERS` is what the DNS recursor uses for every name outside the LAN zones, for example private host names that only your router or firewall knows. Empty (the default) keeps the previous behavior: the recursor resolves those names itself from the root servers, and a private name is answered with `NXDOMAIN`. The easiest way to set it is `sudo ./setup.sh configure-upstream-dns`, which asks for the servers, the forwarded zones, the zones without DNSSEC and the local PTR zones. By hand, put one or more resolver IPs in `deploy/prod/.env.local` (`192.0.2.1`, `192.0.2.1:5353`, `[fd00::53]:53`; space or comma separated, no host names) and recreate the DNS and UI containers (`sudo ./setup.sh compose deploy/prod up -d ui dns`; the `ui` renders the recursor files). `DNS_UPSTREAM_ZONES` limits the forwarding to the named zones (default `.`, every name; the CDN domains stay answered by LanCache either way). `DNS_UPSTREAM_UNSIGNED_ZONES` names private zones inside them that carry no DNSSEC, so their answers are not rejected; DNSSEC validation stays on for everything else that is forwarded. A resolver that is a loopback or unspecified address, `IP_HTTP`, `IP_HTTPS` or another address of LanCache itself is refused because the query would loop back; a zone served by the local authoritative server is refused too. A refused value stops the render of the Admin UI: no configuration file is written, and the `ui` log names the entry (`ui: start render: …: <value> is this LanCache-NG itself; that would loop`). The names `NGINX_UPSTREAM_DNS` and `UPSTREAM_DNS` do not exist and are ignored.

`PROXY_SECURITY_MODE` controls how defensive the proxy is at request time:

- `lazy` is the default and keeps the traditional LanCache-style behavior: if a client reaches the cache, nginx proxies the requested host upstream. This is the deliberate cache-first choice so new CDN hostnames keep working out of the box.
- `strict` NOT RECOMMENDED! Only proxies hosts whose root domain is derived from `services/dns/cdn-domains.txt`; unknown hosts receive `403 Forbidden`. This reduces accidental or abusive proxying, but it can AND will break downloads until the missing CDN hostname is added to `cdn-domains.txt` — there is no separate file to maintain, but you still need to add every CDN hostname you want to cache by hand.

`PROXY_ALLOWED_CLIENT_CIDRS` restricts who may use the proxy, for example `192.0.2.0/24 172.16.0.0/12`. An empty value keeps the default from `runtime.defaults` in `.github/yaml/build-manifest.yml` (the private networks and `fc00::/7`); it does not open the proxy to every client (`Settings::load` in `services/common/config.rs` treats an empty file or environment value as unset). Firewalling and Docker port bindings still define the outer boundary for the normal LAN-only deployment model.

The Admin UI keeps snapshots of the Kea DHCP configuration (`KEA_SNAPSHOT_KEEP`, default `20`) and of the lan and private reverse zone records (`DNS_SNAPSHOT_KEEP`, default `20`) for operator-selected rollback; see [docs/README.md](docs/README.md#6-known-good-snapshots-and-rollback). `setup.sh secondary` also writes `KEEP_KNOWN_GOOD_CONFIGS` to the secondary's `.env`, but no service reads it.

`LANCACHE_IMAGE_CHANNEL` controls the mutable stack channel. `latest` (from
`master`) is the install default (SOT `release.install_channel`). On update, a
former channel name in `.env.local` is rewritten to its current channel; a
retired name stops the update with its reason. `nightly` (formerly `edge`) is
built daily from `current_dev`; it is experimental, may break the stack and is not for
production, and `setup.sh` warns on install and on every update with it.
`setup.sh` resolves a mutable channel by reading every first-party image's
channel digest twice while no promotion runs, and writes each image as
`LANCACHE_IMAGE_REF_<NAME>=<image>@<digest>`, which Docker Compose pulls
(see [docs/combined-release-and-checklist.md](docs/combined-release-and-checklist.md)). If you install from a tagged release archive or a
checked-out `vX.Y.Z` / `vX.Y.Z-rc.N` tag, set `LANCACHE_IMAGE_CHANNEL=pinned`
and `LANCACHE_IMAGE_TAG` to that same release tag so the running containers
match the source tree.

`LANCACHE_IMAGE_REGISTRY` and `LANCACHE_IMAGE_PREFIX` select where first-party images are pulled from. Keep the defaults for GHCR, or point both values at a private mirror that provides the complete stack package set.
The resulting install/update path still stays pull-only and does not depend on
local compiler caches or remote compiler services.

Prebuilt first-party images are published for `linux/amd64` and `linux/arm64`; arm64 is built natively on GitHub-hosted arm64 runners (`docs/ci-2.0-architecture.md`).

Release channels, package rules and external image handling are documented in `docs/combined-release-and-checklist.md`.

Manual production changes belong in `deploy/prod/.env.local`, which is ignored by git and preferred by
`setup.sh update`, `setup.sh auto-update`, `setup.sh backup`, `setup.sh restore`,
`setup.sh update-ip`, and `setup.sh create-logs-for-issue` when present.

If you use secondary DNS or DHCP DDNS, set a real secret value too:

```env
DDNS_TSIG_KEY=<generate-a-secret>
```

`SECONDARY_REGISTRATION_TOKEN`: `setup.sh install` generates it. Without a
value in `.env.local`, the Admin UI creates a random token once and keeps it in
the shared-secrets volume (`SECRETS_DIR`). The token is read on each
registration request. A placeholder value, in `.env.local` or in that file, is
an error; registration then fails. To set the token yourself:

```env
SECONDARY_REGISTRATION_TOKEN=<generate-a-secret>
```

### Secret generation and persistence

Secrets in `.env.local` follow a simple rule: they are generated once on first install (or first update), and never rotated by later updates as long as a real value already exists. The `setup.sh` script provides a `get_or_generate_secret` helper that checks each secret key:

- If the value is a placeholder (empty, containing `change_me`, starting with `changeme` or `your_`, ending in `_here`, or in angle brackets such as `<generate-a-secret>`), a new secret is generated.
- If a real value is already present, it is preserved unchanged — even across multiple updates.

Secret formats vary by key, not by naming suffix — despite the `*_KEY`/`*_PASSWORD` names, generation kind is assigned per key in `setup.sh`, and the two families are not generated the same way as each other:

- 64 hex characters (`openssl rand -hex 32`): `KEA_CTRL_TOKEN`, `PDNS_API_KEY`, `SNMP_COMMUNITY`, `SECONDARY_REGISTRATION_TOKEN`
- 44 base64 characters (`openssl rand -base64 32`): `DDNS_TSIG_KEY`
- 20 alphanumeric characters: the Admin UI password. It is shown once; only its Argon2id hash is stored as `UI_AUTH_PASSWORD_HASH`.
  The General page of the Admin UI can change it (old password required, at least 12 characters). The new Argon2id hash is saved as `UI_PASSWORD_HASH` in the UI settings file (`lancache-ui-settings.env` in the `ui-data` volume), which takes precedence over the `.env.local` value; to reset a lost password, run `sudo ./setup.sh reset-sign-in`, which turns the sign-in off until a new password is set on the General page.

Store your actual secret values securely if you need to rotate them manually. The setup script will not regenerate them unless you explicitly delete or clear the `.env.local` entry.

Create directories:

```bash
mkdir -p /opt/lancache-ng/{cache,ca,kea,ntp,pdns,pdns-filter-state,cachehamster,syslog-ng}
chown 10001:10001 /opt/lancache-ng/syslog-ng
```

Start the stack. Plain `docker compose` fails: the compose file needs the SOT
values and image references that only `setup.sh compose` supplies.

```bash
sudo ./setup.sh compose deploy/prod pull
sudo ./setup.sh compose deploy/prod up -d
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
sudo ./setup.sh compose deploy/prod ps
```

## Proxmox LXC notes

LanCache NG can run inside a Proxmox LXC container.

Recommended:

- use a Debian based unprivileged container
- use enough disk space
- enable nesting
- keep the container inside your LAN
- give the container a static IP and a second static IP (always required)

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

The second LAN IP carries HTTPS mode: HTTPS downloads of the listed domains are
cached there, for clients with the CA certificate installed.

## Ports

| Port | Protocol | Used for |
|---|---|---|
| `53` | TCP and UDP | DNS (both LAN IPs); dnsdist also passes zone transfer and NOTIFY to the authoritative server |
| `80` | TCP | HTTP cache (both LAN IPs) |
| `443` | TCP | TLS passthrough on the HTTP IP, HTTPS mode cache on the HTTPS IP |
| `5300` | TCP and UDP | zone transfer to secondary DNS nodes of older versions (HTTP IP); a new secondary uses `53` |
| `8080` | TCP | Admin UI |
| `67` | UDP | optional DHCP server |
| `8000` | TCP | optional Kea control agent |
| `123` | UDP | LanCache-NG-NTP server (HTTP IP) |

A secondary DNS node uses `53` (and `53` on its second IP for HTTPS clients),
`5300` and `8081` (PowerDNS API, read by the primary's health check).

Keep these ports inside your LAN.  
Do not expose them directly to the internet.

## Repository layout

Important paths:

```text
deploy/prod/             Production compose used by setup.sh
deploy/secondary/        Secondary DNS compose file
docs/                    Documentation
services/watchdog/       services image: watchdog, cachehamster, syslog-ng, chrony, snmpd
services/proxy/          Unified proxy for HTTP mode and HTTPS mode
services/dns/            DNS image: dnsdist, PowerDNS auth and recursor
services/dhcp/           DHCP image: Kea or dnsmasq proxy/relay
services/ui/             Admin UI
services/common/         Shared Rust crate
services/cachehamster/   CacheHamster prefill daemon (Steam), built into services
```

## Common problems

### DNS does not answer

Check that the container is running:

```bash
sudo /opt/lancache-ng/current/setup.sh compose /opt/lancache-ng ps
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
- if HTTPS mode is needed, is the client using the HTTPS DNS IP
- if HTTPS mode is needed, is the CA certificate installed

### HTTPS mode does not work

Check:

- the client uses the HTTPS mode DNS IP
- the second IP is really assigned to the server
- the CA certificate is installed
- Firefox has the certificate if Firefox is used
- the domain exists in `services/dns/cdn-domains.txt`
- the proxy container is running

### Admin UI does not open

Check:

```bash
sudo /opt/lancache-ng/current/setup.sh compose /opt/lancache-ng ps
sudo /opt/lancache-ng/current/setup.sh compose /opt/lancache-ng logs --tail=100 ui
```

Common causes:

- wrong IP
- blocked port `8080`
- UI container not running
- firewall blocks access
- `UI_BIND_IP` binds the UI to another address than `IP_HTTP`

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
- do not use HTTPS mode for unknown or guest devices
- review the setup script before running it on important systems

A local Root CA can inspect traffic for configured domains.  
That is required for HTTPS caching, but it also means the CA must be handled carefully.

## When to use which mode

Use HTTP mode when:

- you want the easiest setup
- you use consoles
- you do not want to install certificates
- you only want safe basic caching
- you are testing the project for the first time

Use HTTPS mode when:

- you control the client device
- you can install the CA certificate
- you want better cache coverage
- you understand that HTTPS caching needs trust in the local CA
- you are using supported game launchers on PCs

## License

AGPL-3.0-or-later, see [LICENSE](LICENSE). Anyone running a modified version
of lancache-ng as a network service must make the modified source available to
the users of that service.
