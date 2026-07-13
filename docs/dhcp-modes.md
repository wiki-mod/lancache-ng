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
- No lease-time control: dnsmasq never issues a lease of its own in this
  mode, so there is nothing for a lease-time value to apply to.
- No guarantee that ordinary clients accept *any* option offered here —
  router, DNS, NTP, domain, and custom options are all delivered only
  through the supplemental ProxyDHCP/PXE exchange (RFC 4388), which
  PXE/network-boot-aware clients query in addition to their normal DHCP
  transaction. An ordinary client's router/DNS/NTP/domain settings come
  entirely from its real DHCP lease from the upstream server, never from
  dnsmasq, regardless of what is configured below.

The Admin UI reflects this: when `dnsmasq-proxy` is active it shows the live
proxy values and hides the Kea-only subnet/reservation/lease editors, with a
note that those features require Kea mode. Kea's capabilities are not removed —
they are simply inactive while proxy mode is selected.

If you need LanCache NG to reliably control the DNS, router, NTP, or domain
settings that ordinary clients receive, use `kea` mode (or set them on the
router/clients directly). `dnsmasq-proxy` is an experimental helper for the
constrained case above — supplementing PXE/network-boot info alongside an
upstream DHCP server that cannot be replaced — not a full replacement for
router DHCP.

## Configuring dnsmasq-proxy mode

`setup.sh` prompts for these values when you pick `dnsmasq-proxy`, validates
them, and writes them to `.env`. They can also be edited later from the Admin UI
DHCP page.

### Required

| Key | Meaning | Example |
|---|---|---|
| `UPSTREAM_DHCP_IP` | IP of the existing DHCP server (usually your router/gateway) that keeps owning leases. **Documentation only** — see the note below; ProxyDHCP mode does not need to contact this server to function. | `10.0.0.1` |
| `DHCP_SUBNET_START` | Network base address of the LAN dnsmasq serves. Must end in `.0`. | `10.0.0.0` |
| `DHCP_DNS_PRIMARY` | Primary DNS server offered to proxy/PXE clients — normally the LanCache NG standard DNS IP. | `10.0.0.10` |
| `DHCP_DNS_SECONDARY` | Secondary DNS server. Leave empty to reuse `DHCP_DNS_PRIMARY`. | `10.0.0.11` |

> **A note on `UPSTREAM_DHCP_IP` (issue #450):** an earlier revision of
> `services/dhcp-proxy/dnsmasq.conf.template` fed this value into dnsmasq's
> `dhcp-proxy=<ip>` directive. Per `dnsmasq --help`, that flag means "use
> these DHCP relays as full proxies" (an RFC 5107 serverid-override) — it
> only does anything when paired with dnsmasq's separate `--dhcp-relay=`
> feature, which this service never configures. It was a no-op, confirmed
> against a live `dnsmasq --help`/`--test`, not a functioning link to the
> upstream server. It has been removed; `UPSTREAM_DHCP_IP` is kept purely so
> you and the Admin UI's DHCP conflict check agree on which server is
> expected to answer.

### Optional (issue #450)

Every option below is only delivered to PXE/network-boot-aware clients via
the supplemental ProxyDHCP/PXE exchange (the same mechanism the DNS option
above already uses) — never to ordinary DHCP clients. Leave any of these
empty to skip it; entrypoint.sh omits the corresponding line entirely rather
than rendering an empty or invalid one.

> **Issue #705 finding, affecting every option in this section:** dnsmasq's
> ProxyDHCP mode does not reply to *any* DHCPDISCOVER at all — PXE-tagged or
> not — unless at least one `pxe-service` directive is present in its
> config. Before issue #705, nothing in this service ever rendered one, so
> every option below (and the base DNS-option-6 injection above it) was
> silently inert since the day #450 shipped: configured, accepted by
> `dnsmasq --test`, and never actually delivered to a single client. Fixing
> that (see "PXE boot-pointer" below) is deliberately opt-in rather than
> unconditional: making dnsmasq start replying at all is a real behavior
> change for the segment it's deployed on, so it stays off by default and
> only turns on once you configure `DHCP_PROXY_PXE_BOOT_SERVER` and at
> least one `DHCP_PROXY_PXE_BOOT_FILENAME_*` variable below. Until you do,
> the options in this table (and the base DNS option) remain in the same
> inert state they have always been in.

| Key | Meaning | Example |
|---|---|---|
| `DHCP_PROXY_INTERFACE` | Bind dnsmasq to one host network interface instead of all of them. | `eth0` |
| `DHCP_PROXY_ROUTER` | Router/gateway option (DHCP option 3), PXE-scoped. | `10.0.0.1` |
| `DHCP_NTP_SERVERS` | NTP servers option (DHCP option 42), PXE-scoped. Comma-separated IPv4 list. | `10.0.0.20,10.0.0.21` |
| `DHCP_PROXY_DOMAIN` | Domain name option (DHCP option 15), PXE-scoped. | `lan.local` |
| `DHCP_PROXY_BOOT_FILENAME` | PXE boot filename, via dnsmasq's `dhcp-boot` directive — the directive the dnsmasq man page documents as intended for this exact "ProxyDHCP server alongside a real DHCP server" case. | `pxelinux.0` |
| `DHCP_PROXY_BOOT_SERVER` | Boot server address for `dhcp-boot`. Requires `DHCP_PROXY_BOOT_FILENAME`; defaults to dnsmasq's own address if left empty while a filename is set. | `10.0.0.5` |
| `DHCP_PROXY_CUSTOM_OPTIONS` | Additional safe custom options as `CODE:VALUE`, one per line in the Admin UI (stored as `;`-separated `CODE:VALUE` pairs). Codes already covered by the dedicated fields above (3, 6, 15, 42) are rejected here to avoid two conflicting ways to set the same option. | `60:PXEClient` |

`setup.sh update` and the container entrypoint both fail closed for the
*required* values: if any is missing or invalid, setup refuses to continue
and the container refuses to start, rather than silently running with
broken DHCP configuration. The optional values above are validated only when
non-empty (empty is the supported "not using this option" state); a
structurally invalid optional value (e.g. an out-of-range custom option
code) is skipped with an explicit warning in the container logs rather than
silently accepted or crash the container. Existing non-empty values in your
local `.env` are preserved and never overwritten on update.

### PXE boot-pointer (issue #705)

`dnsmasq-proxy` mode can point a real PXE client at an **operator-owned,
already-existing** PXE/TFTP boot server — this project never hosts or
serves boot files itself, in v0.2.0 or planned beyond it as of this
writing. Setting these variables is also, unavoidably, what activates
ProxyDHCP replies for this service at all (see the finding boxed above),
so it is entirely opt-in: leave both variables below empty and nothing in
this section or the "Optional (issue #450)" one above changes.

| Key | Meaning | Example |
|---|---|---|
| `DHCP_PROXY_PXE_BOOT_SERVER` | Address of your own external PXE/TFTP boot server. Required for any PXE boot-pointer to activate at all. | `10.0.0.5` |
| `DHCP_PROXY_PXE_BOOT_FILENAME_BIOS` | Boot filename served to legacy BIOS PXE clients (dnsmasq architecture tag `x86PC`, client-system-architecture 0 — still the most common real-world PXE client). | `pxelinux.0` |
| `DHCP_PROXY_PXE_BOOT_FILENAME_UEFI` | Boot filename served to 64-bit UEFI PXE clients: architecture 7 (`x86-64_EFI`, the dominant UEFI PXE client on both desktops and servers) and architecture 11 (`ARM64_EFI`, UEFI ARM boards/servers, e.g. Raspberry Pi 4/5 UEFI firmware). One shared filename covers both codes — see the limitation note below. | `bootx64.efi` |

Set `DHCP_PROXY_PXE_BOOT_SERVER` plus at least one of the two filename
variables to activate PXE support. Both a BIOS-only and a UEFI-only
configuration are supported (set only the filename variable for the
architecture family you need); setting neither filename variable leaves
PXE support off even if the server address is set, with an explicit
warning in the container logs. The remaining dnsmasq-documented PXE
architecture tags (`PC98`, `IA64_EFI`, `Xscale_EFI`, `BC_EFI`, `ARM32_EFI`)
are not covered — NEC PC-98, Itanium, XScale, and 32-bit ARM UEFI are all
effectively extinct or rare network-boot targets in 2026.

**Known limitation:** `DHCP_PROXY_PXE_BOOT_FILENAME_UEFI` is one field
shared by both UEFI architecture codes above, on the assumption that your
external boot server serves a single self-selecting artifact at that
filename (e.g. an iPXE or GRUB2 EFI binary that picks its own next stage) —
the common real-world pattern for "point at existing infrastructure"
setups. If your x86-64 and ARM64 UEFI boot artifacts are genuinely
different files, this single field cannot express that; use
`DHCP_PROXY_CUSTOM_OPTIONS` for a finer-grained override, or track this as
a future dedicated-field request.

**Wire-level detail, for anyone extending this further:** every
architecture above is delivered via dnsmasq's `dhcp-boot` directive
(tag-matched by DHCP option 93, client-system-architecture), not
`pxe-service`. This was confirmed necessary by direct packet capture during
this issue's investigation: `pxe-service`'s own basename/server-address
fields never reflect the configured *external* server (dnsmasq
substitutes its own address instead, for every architecture including
BIOS), and for any architecture other than BIOS it renders no boot
filename at all. `pxe-service` is still rendered once (for BIOS if
configured, or a dedicated inert placeholder architecture otherwise)
purely because at least one such directive must exist for ProxyDHCP
replies to happen at all — see `services/dhcp-proxy/entrypoint.sh` for the
full account.

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

## Automated DHCP behavior testing (CI)

This project has four separate, non-overlapping automated DHCP checks.
None run on the host's real network interface by default:

| Check | What it answers | Where it runs | Invasive? |
|---|---|---|---|
| **Conflict discovery** (`services/ui/dhcp-probe.sh`) | Does *any* DHCP server answer on this LAN segment (broadcast discover via `nmap`), and does a client dry-run on the host's own detected default interface also succeed? | Admin UI DHCP page, on demand | The client dry-run leg uses `dhclient -sf /bin/true` so it never applies the negotiated lease to the host interface, but it does run against the host's real detected interface. |
| **Kea lease-flow simulation** (`scripts/dhcp-kea-lease-flow-simulation.sh`) | Does *our own* Kea service complete a real Discover/Offer/Request/Ack and return the address range, router, DNS, NTP, lease-time, and domain-name options actually configured? Also: does a static host reservation, added directly through Kea's Control Agent API, actually get honored by a subsequent real lease request for the reserved MAC, and does it stay isolated to that MAC (a different, unrelated MAC still gets an ordinary pool address)? And does a granted lease produce a matching PowerDNS **forward (A record)** DDNS update? | `dhcp-kea-lease-flow-simulation` job in the `Full-Setup Validate` GitHub Actions workflow (`workflow_dispatch` only, never on every PR) | No -- it builds a throwaway Kea container, a throwaway PowerDNS container, and throwaway client containers, all on a dedicated Docker bridge network the script creates and destroys itself. No container's interface, nor any host interface, is ever configured with the negotiated lease. |
| **Kea Control Agent mutation round-trip** (`scripts/dhcp-kea-ctrl-agent-mutation-simulation.sh`) | Does a real static host reservation added/removed through the actual Admin UI HTTP route (`kea_config_modify()`'s config-get/config-test/config-set/config-write sequence) against a real Kea Control Agent actually change what a *subsequent* real DHCP lease request receives -- not just that the API call returned success? | `dhcp-kea-ctrl-agent-mutation-simulation` job in the `Full-Setup Validate` GitHub Actions workflow (`workflow_dispatch` only, never on every PR) | No -- real Kea and Admin UI containers on the throwaway compose project's own bridge network; DHCP clients again use `dhclient -sf /bin/true`, never applying the negotiated lease to any interface. |
| **dnsmasq-proxy PXE simulation** (`scripts/dhcp-proxy-pxe-simulation.sh`) | Does *our own* dnsmasq-proxy ProxyDHCP mode reply to a real, synthetically-crafted PXE-tagged DHCPDISCOVER with the correct external boot server address, architecture-appropriate boot filename, and LanCache NG DNS servers -- for both legacy BIOS and UEFI clients -- while still ignoring an ordinary, non-PXE-tagged DISCOVER? | `dhcp-proxy-pxe-simulation` job in the `Full-Setup Validate` GitHub Actions workflow (`workflow_dispatch` only, never on every PR) | No -- it builds a throwaway dnsmasq-proxy container and a throwaway synthetic-PXE-client container (scapy), both on a dedicated Docker bridge network the script creates and destroys itself. No host interface is ever involved, and the external PXE boot server it asserts against is never a real listening service -- just a configured address, per issue #705's scope of pointing at operator infrastructure this project does not itself run. |

The second, third, and fourth checks exist because the first only tells you
a DHCP server answered -- it does not prove ours behaves correctly, and it
does not report individual option values. `scripts/dhcp-kea-lease-flow-simulation.sh`
is the authoritative check for "did Kea hand out what I configured, and does
it honor a static reservation the way an operator using the Admin UI's DHCP
page would expect" -- its output (printed to the job log and, in CI,
`$GITHUB_STEP_SUMMARY`) lists every offered value and both reservation
outcomes explicitly so a wrong result is easy to spot.

This is a different layer than issue #634's Kea Control Agent mutation test:
that one drives a reservation add/remove through the Admin UI's own real
HTTP routes on a full stack, proving the Rust `kea_config_modify()` code
path is correct end to end. `dhcp-kea-lease-flow-simulation.sh` instead
drives the same underlying Kea Control Agent commands directly, on its own
lightweight single-Kea-container setup, to prove Kea's own runtime honors a
reservation for the right client and only the right client -- complementary
coverage, not a duplicate.

`scripts/dhcp-proxy-pxe-simulation.sh` is the authoritative check for the
`dnsmasq-proxy` DHCP mode's entirely separate code path
(`services/dhcp-proxy`), covering ProxyDHCP PXE-tagged behavior that none of
the Kea-focused checks above exercise at all. Like the others, it prints
every asserted value explicitly (to the job log and, in CI,
`$GITHUB_STEP_SUMMARY`) so a wrong result is easy to spot.

**What the Kea lease-flow simulation does NOT verify** (documented here per
its own design -- see the script's header comment for the full rationale):

- Reverse (PTR) DDNS updates. Confirmed **broken in production** (issue
  #768, discovered while verifying forward DDNS for issue #706): Kea's D2
  daemon sends every reverse update's on-wire zone as the literal
  `in-addr.arpa.`, but no PowerDNS zone with that exact name exists (only
  narrower private-range subzones), so PowerDNS rejects every PTR update
  regardless of octet.
- The `dnsmasq-proxy` DHCP mode -- entirely different code path
  (`services/dhcp-proxy`), covered instead by the PXE simulation below.

**What the dnsmasq-proxy PXE simulation does NOT verify** (documented here
per its own design -- see `scripts/dhcp-proxy-pxe-simulation.sh`'s own
header comment for the full rationale):

- PXE boot menu behavior -- this project deliberately implements none;
  dnsmasq's role here is only to point a PXE client at an external boot
  server, never to serve a menu or boot files itself.
- An actual TFTP/HTTP boot-file transfer against the configured external
  boot server -- out of scope by design, and that server is never a real
  listening service in this simulation, just a configured address the
  DHCPOFFER is asserted to point at.

Neither check has an invasive/host-interface mode: every server and client
container involved always runs inside its own throwaway, isolated Docker
network, so there was nothing that needed gating behind an explicit opt-in
flag beyond each job itself only running on manual dispatch.

`scripts/dhcp-kea-ctrl-agent-mutation-simulation.sh` (issue #634) closes the
static-reservation gap left open above: it drives a real static host
reservation add/remove through the Admin UI's actual `/dhcp/static/add` and
`/dhcp/static/remove` HTTP routes -- the same `kea_config_modify()` Rust code
path a real operator's browser would hit -- against a real Kea Control Agent,
and confirms both a follow-up `config-get` and a subsequent real DHCP lease
request for the same MAC address reflect each change. This is what would have
caught #630 (Kea 2.6.3's `config-get` response including a `hash` field that
`config-test`/`config-set` reject) automatically instead of needing a human
to hit it in production: every existing `cargo test` for that function mocks
Kea's response and none of those mocks omitted the fix once written, so they
prove the fix works, not that the assumed response shape is still accurate.
**What it does NOT verify**: subnet/custom-option mutation routes beyond
reservations (same underlying `kea_config_modify()` code path, so this is
representative coverage of that function, not route-by-route exhaustive),
DHCP-DDNS lease-event follow-through (issue #557), and the `dnsmasq-proxy`
mode (entirely different code path, no Kea/Admin-UI Control Agent interaction
at all). Also has no invasive/host-interface mode, for the same reason as the
lease-flow simulation above.
