# 🌐 Changing the Server IP Address

The LAN cache binds to one or two IP addresses on your server. You may need to change these when:

- Migrating the cache server to a new machine
- Switching from DHCP to a static IP
- Reorganising your LAN subnet

> ⚠️ **Before you start:** Active downloads will be interrupted. Pick a quiet moment (e.g. late at night) or warn users first.

---

## Quickest way: use setup.sh (recommended)

If you installed using the setup script, use this to reconfigure the IP addresses:

```bash
sudo /opt/lancache-ng/setup.sh update-ip
```

Or equivalently:

```bash
sudo /opt/lancache-ng/setup.sh --reconfigure
```

The setup script will ask you for the new IP(s), update all necessary config files automatically, restart the services, and verify the change worked.

---

## Manual method (if not using setup.sh)

If you installed manually or need direct control over the config, follow the steps below. This is a fallback for edge cases; `setup.sh update-ip` is the recommended path for most setups.

---

## Which IPs does lancache use?

| Mode | Variable | Purpose |
|---|---|---|
| Standard | `IP_STANDARD` | HTTP cache + HTTPS passthrough — clients use this as DNS |
| SSL | `IP_SSL` | Full HTTPS interception — clients use this as DNS (CA cert required) |

If you only run **standard mode**, you only have one IP to change.

---

## Step 1 — Add the new IP to the host *(only if adding a second IP)*

If you run both modes, the server needs two IPs on the same interface.

```bash
# Temporary (lost on reboot — good for testing first)
ip addr add 192.168.2.11/24 dev eth0

# Verify
ip -4 addr show eth0
```

To make it **permanent**, edit your network config:

**Netplan** (Ubuntu 20.04+, Debian 12+):
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

**Legacy `/etc/network/interfaces`** (older Debian/Ubuntu):
```
# /etc/network/interfaces
auto eth0
iface eth0 inet static
    address 192.168.2.10
    netmask 255.255.255.0
    gateway 192.168.2.1

auto eth0:1
iface eth0:1 inet static
    address 192.168.2.11
    netmask 255.255.255.0
```
```bash
sudo systemctl restart networking
```

> 💡 **Tip:** Unsure which system you have? Run `ls /etc/netplan/` — if files exist, you're on Netplan.

---

## Step 2 — Update `.env`

```bash
nano deploy/prod/.env.local
# or for quickstart:
nano deploy/quickstart/.env
```

Change the IP lines:

```env
IP_STANDARD=192.168.2.10
IP_SSL=192.168.2.11
```

---

## Step 3 — Update DNS config

Edit both DNS env files to match the new IPs:

```bash
nano config/prod/dns-standard.env
```
```env
PROXY_IP=192.168.2.10
```

```bash
nano config/prod/dns-ssl.env
```
```env
PROXY_IP=192.168.2.11
```

---

## Step 4 — Restart the services

```bash
cd deploy/prod
docker compose --env-file .env.local up -d
```

Wait a few seconds, then check everything is healthy:

```bash
docker compose --env-file .env.local ps
```

You should see `healthy` next to the proxy and DNS containers (`proxy`, `dns-standard`, and `dns-ssl` when SSL mode is enabled).

---

## Step 5 — Update your clients

Clients need to point their DNS to the new IP(s):

| Mode | DNS Server |
|---|---|
| Standard | `192.168.2.10` |
| SSL | `192.168.2.11` |

**Via your DHCP server (recommended):** Update the DNS option there — clients pick it up on the next lease renewal (or reboot).

**Manually per device:** Change the DNS server in the network settings of each device.

---

## Single-IP setup (standard mode only)

Only using standard mode and no SSL interception? You only need to change `IP_STANDARD` and `config/prod/dns-standard.env`. Skip everything referencing `IP_SSL`.

---

## Verify it works

Query the new DNS IP directly from any machine on your LAN:

```bash
dig @192.168.2.10 steamcontent.com A +short
# Should return: 192.168.2.10

dig @192.168.2.11 steamcontent.com A +short
# Should return: 192.168.2.11
```

If both return the correct IPs, the change was successful. 🎉

---

## Troubleshooting

**DNS not responding from the new IP:**
```bash
# Is the IP actually assigned?
ip -4 addr show

# Are the containers running?
cd deploy/prod
docker compose --env-file .env.local ps

# Check firewall — port 53 must be open on the new IP
# iptables:   iptables -C INPUT -p udp --dport 53 -j ACCEPT
# nftables:   nft list ruleset | grep 53
# ufw:        ufw status
```

**Containers fail to start:**
```bash
cd deploy/prod
docker compose --env-file .env.local logs -f
```

**Clients can't reach the cache after the change:**
- Ping the new IP: `ping 192.168.2.10`
- Check the client's DNS settings — still pointing to the old IP?
- DHCP clients: reboot the device or run `ipconfig /renew` (Windows) / `dhclient` (Linux)
