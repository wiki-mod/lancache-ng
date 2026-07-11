# DHCP Modes: Kea vs. dnsmasq-proxy

LanCache NG only helps if clients actually resolve game/CDN hostnames through
its DNS servers. The most reliable way to hand those DNS servers to every
client is DHCP. LanCache NG supports three DHCP modes, selected once during
`setup.sh` and stored as `DHCP_MODE` in your `.env`:

| Mode | What it does | DHCP lease owner |
|---|---|---|
| `disabled` | LanCache NG does not manage or proxy DHCP. You point clients at its DNS yourself (router DHCP option, static config). | Your existing router/DHCP server |
| `kea` | LanCache NG runs a full Kea DHCP server and hands out addresses, gateway, and DNS. | LanCache NG (Kea) |
| `dnsmasq-proxy` | LanCache NG runs dnsmasq in proxy-DHCP mode next to an existing DHCP server. | Your existing router/DHCP server |

The three modes are mutually exclusive. `setup.sh` writes exactly one runtime
Compose profile (`dhcp-kea` **or** `dhcp-proxy`, never both), and the Admin UI
stops the other DHCP service whenever you switch modes. Kea and dnsmasq both
bind UDP port 67, so only one can be active at a time.

## When to use Kea mode

Choose `kea` when you are comfortable making this change to your network and
have access to your router's settings — Kea mode replaces your router as the
network's DHCP server entirely, and only one DHCP server may be active on a
LAN at a time.

**Before switching**, set `DHCP_MODE=kea` and configure it here first, then
disable your router's built-in DHCP server — not the other way around.
Disabling your router's DHCP first, before LanCache NG's Kea server is
actually running, leaves clients (especially over Wi-Fi, where a router
reboot commonly forces a reconnect) with no DHCP server to get an address
from at all, and no obvious reason why.

Kea mode is the full-featured mode:

- Hands out IP address, gateway, and DNS servers to every client.
- Sets the LanCache NG DNS servers as the DNS option for all leases, so all
  clients route CDN traffic through the cache.
- Supports static reservations, lease listing, and richer DHCP options through
  the Admin UI, backed by the Kea control-agent API.

Only run Kea mode if you know that no other normal DHCP server is active on the
same LAN. Two competing DHCP servers on one network cause unpredictable client
configuration. If your router already provides DHCP, either keep using the
router (and set DNS another way) or switch DHCP fully to LanCache NG.

### Kea activation preflight (safety gate before Kea ever serves clients)

Selecting `kea` in `setup.sh` prepares Kea's configuration, secrets, and
volumes, but `setup.sh` does not let Kea become an active DHCP server without
one more safety step. Immediately before the stack starts — after images are
pulled, right before `docker compose up` — `setup.sh` runs a non-invasive
DHCP discovery probe (`nmap --script broadcast-dhcp-discover`) using the Kea
image itself. This only runs `nmap` inside that image and exits; it does not
start Kea and does not touch the network beyond the broadcast probe.

- If no other DHCP server answers, setup proceeds automatically and Kea
  starts as normal.
- If another DHCP server answers (Server Identifier detected), `setup.sh`
  prints the responding server and requires an explicit `y`/`yes`
  confirmation before continuing. Answering no cancels activation entirely —
  Kea is never started.
- If the probe itself could not run for any other reason (e.g. Docker/network
  issues), `setup.sh` fails closed the same way: it requires an explicit
  confirmation rather than silently proceeding as if no conflict exists.

This closes the gap that existed before: previously, selecting `kea` started
Kea immediately, and the only way to learn about a conflicting DHCP server was
to open the Admin UI's DHCP page *after* Kea might already have been
answering DHCP requests on the LAN.

**This preflight is a one-time activation gate, not the same thing as the
Admin UI's DHCP check.** The Admin UI's DHCP page (see "Verifying" below) runs
the same kind of non-invasive discovery, but on demand, after the stack is
already running — it is a diagnostic you can re-check at any time, and by
itself it does not prevent Kea from serving. The `setup.sh` preflight
documented here is what actually blocks Kea's first activation when a
conflict is detected or the check could not run.

Neither check validates Kea's own configuration or replays a real DHCP lease
negotiation (`DHCPDISCOVER`/`DHCPOFFER`/`DHCPREQUEST`/`DHCPACK`) end to end —
both are discovery-only broadcast probes for a second DHCP server on the
segment. A behavioral test of Kea's actual lease/option responses is tracked
separately (Refs #448).

## When to use dnsmasq-proxy mode

Choose `dnsmasq-proxy` when the network already has a DHCP server you cannot
turn off — most commonly an ISP-supplied router or gateway that keeps its own
DHCP server enabled and gives you no option to disable it.

In this mode LanCache NG does **not** take over lease ownership. The existing
DHCP server keeps assigning addresses; dnsmasq runs alongside it in proxy-DHCP
mode and answers the proxy/PXE portion of the DHCP exchange, supplying the
LanCache NG DNS servers as an extra option.

### Why this mode exists

Some routers and ISP gateways cannot disable their built-in DHCP server. Kea
mode is impossible there, because two full DHCP servers would fight over the
same clients. Proxy-DHCP was designed exactly for the "second helper next to an
existing DHCP server" case, so `dnsmasq-proxy` gives those networks a way to
still push LanCache NG DNS options without owning leases.

### What is NOT available in dnsmasq-proxy mode

Because the upstream DHCP server remains the lease owner, this mode is
deliberately limited. It is **proxy-DHCP / PXE only**:

- No static reservations.
- No lease listing or lease ownership (the upstream server owns leases).
- No richer per-subnet DHCP options, gateway management, or NTP options.
- No guarantee that ordinary clients accept the DNS option — proxy-DHCP DNS
  options are primarily honored by PXE/proxy-DHCP-aware clients, and a normal
  client's DNS setting from its regular DHCP lease may win instead.

The Admin UI reflects this: when `dnsmasq-proxy` is active it shows the live
proxy values and hides the Kea-only subnet/reservation/lease editors, with a
note that those features require Kea mode. Kea's capabilities are not removed —
they are simply inactive while proxy mode is selected.

If you need LanCache NG to reliably control the DNS servers that ordinary
clients receive, use `kea` mode (or set the DNS server on the router/clients
directly). `dnsmasq-proxy` is an experimental helper for the constrained case
above, not a full replacement for router DHCP.

## Configuring dnsmasq-proxy mode

`setup.sh` prompts for these values when you pick `dnsmasq-proxy`, validates
them, and writes them to `.env`. They can also be edited later from the Admin UI
DHCP page.

| Key | Meaning | Example |
|---|---|---|
| `UPSTREAM_DHCP_IP` | IP of the existing DHCP server (usually your router/gateway) that keeps owning leases. dnsmasq proxies alongside it. | `10.0.0.1` |
| `DHCP_SUBNET_START` | Network base address of the LAN dnsmasq serves. Must end in `.0`. | `10.0.0.0` |
| `DHCP_DNS_PRIMARY` | Primary DNS server offered to proxy/PXE clients — normally the LanCache NG standard DNS IP. | `10.0.0.10` |
| `DHCP_DNS_SECONDARY` | Secondary DNS server. Leave empty to reuse `DHCP_DNS_PRIMARY`. | `10.0.0.11` |

`setup.sh update` and the container entrypoint both fail closed: if any
required value is missing or invalid, setup refuses to continue and the
container refuses to start, rather than silently running with broken DHCP
configuration. Existing non-empty values in your local `.env` are preserved and
never overwritten on update.

## Verifying that clients receive LanCache NG DNS

After enabling a DHCP mode, confirm that clients actually get the LanCache NG
DNS servers:

1. **On a client**, release and renew its DHCP lease (reconnect the network
   interface, or `ipconfig /renew` on Windows / `dhclient -r && dhclient` on
   Linux), then check its DNS servers:
   - Windows: `ipconfig /all` — look at "DNS Servers".
   - Linux/macOS: `resolvectl status` or `cat /etc/resolv.conf`.
   The listed DNS server(s) should be your LanCache NG DNS IP(s).

2. **Confirm DNS is being spoofed to the cache.** From the client, resolve a
   cached CDN hostname and check that it points at the LanCache NG proxy IP, not
   the real CDN:
   ```
   nslookup lancache.steamcontent.com
   ```
   The answer should be your LanCache NG proxy IP.

3. **Use the Admin UI DHCP page** to run the built-in DHCP check. It probes for
   other DHCP servers on the LAN and reports whether a client dry-run received
   the expected options. In `dnsmasq-proxy` mode this is especially useful for
   spotting an upstream DHCP server whose own DNS option overrides the proxy
   one. This check is a **diagnostic** you can re-run at any time after the
   stack is already up — it does not by itself gate whether Kea is currently
   serving DHCP. The one-time safety gate that runs before Kea's first
   activation is the `setup.sh` preflight described under "Kea activation
   preflight" above.

If a client does not pick up the LanCache NG DNS servers in `dnsmasq-proxy`
mode, that is the expected limitation described above: the upstream DHCP
server's DNS option can take precedence. Switch to `kea` mode, or set DNS on the
router/clients directly, to guarantee cache routing.
