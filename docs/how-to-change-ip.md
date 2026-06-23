# Change Server IP Address

The LAN cache requires one or two IP addresses depending on your setup:

- **Standard mode** (HTTP cache + HTTPS passthrough): `IP_STANDARD`
- **SSL mode** (full HTTPS interception with CA certificate): `IP_SSL`

You may need to change these IPs if:
- Migrating the cache server to a different host
- Adding a new network interface
- Switching from dynamic DHCP to static IP addresses

---

## Prerequisites

Before changing IPs, ensure:
1. No active downloads are in progress (connections will be interrupted)
2. You have physical/SSH access to the server
3. You know the new IP addresses you want to assign
4. The new IPs are in the same subnet or routable from your LAN

---

## Step 1: Add the New IP Address to the Host (if using a second IP)

If deploying **both** standard and SSL modes, the server needs two IP addresses on the same interface.

```bash
# Add the second IP (if it doesn't exist yet)
ip addr add 192.168.1.11/24 dev eth0

# Verify both IPs are present
ip -4 addr show
```

To make the IP change permanent (survives reboot), edit your network configuration:

**Netplan** (Ubuntu 20.04+):
```bash
sudo nano /etc/netplan/01-netcfg.yaml
```

**Legacy `/etc/network/interfaces`**:
```bash
sudo nano /etc/network/interfaces
```

**Example configuration** (netplan):
```yaml
network:
  version: 2
  ethernets:
    eth0:
      addresses:
        - 192.168.1.10/24
        - 192.168.1.11/24
      gateway4: 192.168.1.1
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
```

Then apply: `sudo netplan apply`

---

## Step 2: Update `.env` File

Edit `deploy/prod/.env` (or `deploy/quickstart/.env` if using quickstart):

```bash
nano deploy/prod/.env
```

Update the IP variables:

```env
# Old values:
# IP_STANDARD=192.168.1.10
# IP_SSL=192.168.1.11

# New values:
IP_STANDARD=192.168.2.10
IP_SSL=192.168.2.11
```

---

## Step 3: Update DNS Configuration

Edit **both** DNS config files:

### Standard Mode DNS

```bash
nano config/prod/dns-standard.env
```

Update the `PROXY_IP` variable to match the new `IP_STANDARD`:

```env
# Old: PROXY_IP=192.168.1.10
# New:
PROXY_IP=192.168.2.10
```

### SSL Mode DNS

```bash
nano config/prod/dns-ssl.env
```

Update the `PROXY_IP` variable to match the new `IP_SSL`:

```env
# Old: PROXY_IP=192.168.1.11
# New:
PROXY_IP=192.168.2.11
```

---

## Step 4: Restart the Services

```bash
# Navigate to the deploy directory
cd deploy/prod

# Stop all running containers
docker compose down

# Restart with the new IPs
docker compose up -d --build
```

Wait for all services to be healthy:

```bash
docker compose ps
```

You should see:
- `lancache-proxy-standard` — healthy
- `lancache-proxy-ssl` — healthy
- `lancache-dns-standard` — healthy
- `lancache-dns-ssl` — healthy

---

## Step 5: Update Client DNS Settings

Clients on your LAN must point to the new DNS IPs:

| Mode | Protocol | New IP | Port |
|---|---|---|---|
| Standard | DNS | `192.168.2.10` | 53 |
| SSL | DNS | `192.168.2.11` | 53 |

### Configure via DHCP (recommended)

If you run a DHCP server, update it to send the new DNS IPs to clients:

- **Primary DNS**: `192.168.2.10` (standard mode)
- **Secondary DNS**: `192.168.2.11` (SSL mode, if enabled)

Clients will pick up the new DNS on their next DHCP lease renewal (or immediately if you restart them).

### Manual Configuration

Alternatively, configure DNS manually on each device (see your OS documentation for details).

---

## Single-IP Setups (Standard Mode Only)

If you only use standard mode and do not need SSL interception:

1. Edit `.env` and set only `IP_STANDARD` (omit `IP_SSL` or comment it out)
2. Edit `config/prod/dns-standard.env` only
3. Skip the SSL DNS configuration
4. Clients point to `IP_STANDARD` for DNS

You do not need to add a second LAN IP or configure SSL DNS.

---

## Troubleshooting

**DNS not responding from new IP:**
- Verify the IP was added to the host: `ip -4 addr show`
- Check firewall rules allow port 53 UDP/TCP to the new IP
- Restart DNS containers: `docker compose restart lancache-dns-standard lancache-dns-ssl`

**Containers fail to start:**
- Check logs: `docker compose logs -f`
- Verify the new IP is not in use by another service: `netstat -tlnp | grep <new-ip>`

**Clients can't reach the cache:**
- Ensure clients can ping the new IP: `ping 192.168.2.10`
- Confirm clients are using the new DNS IP (check their network settings)
- Wait up to 5 minutes for DHCP leases to renew and pick up the new DNS

---

## Verify the Change

Query the new DNS IP directly:

```bash
dig @192.168.2.10 steamcontent.com A +short
dig @192.168.2.11 steamcontent.com A +short
```

Both should return the respective new IP addresses (not `127.0.0.1`).
