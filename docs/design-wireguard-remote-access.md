# WireGuard Remote LAN Access — Design Plan

**Status: design proposal only, not committed, not scheduled.** Nothing in
this document is approved for implementation. This is the written design
plan issue [#818](https://github.com/wiki-mod/lancache-ng/issues/818) asked
for: an optional WireGuard container giving an operator secure remote
access into the LAN their lancache-ng deployment lives on, reviewed before
any code lands, given how much this touches network security assumptions.

## Motivation (from the issue)

The maintainer was away from home with no way to reach the LAN hosting
their lancache-ng deployment (and its associated runner/build infra) except
by physically being on that network. A built-in, optional WireGuard
container would let an operator reach their own lancache-ng-hosted LAN
remotely and securely, without separate always-on VPN infrastructure.

## The three modes are one interface, not three container variants

WireGuard doesn't have a native concept of "road-warrior" vs "site-to-site"
— an interface is just a set of peers, each with its own `AllowedIPs` and
routing behavior. That means this project's "three modes" are really one
container with a config-driven peer set, not three different builds:

- **Road-warrior peer**: a remote client (laptop, phone) holds a single
  peer entry whose `AllowedIPs` is just that client's own tunnel address.
  It dials the container directly.
- **Site-to-site peer**: the rendezvous VM (see below) holds a peer entry
  whose `AllowedIPs` covers the home LAN's subnet, so traffic the VM
  forwards toward that subnet routes through this tunnel.
- Both peer types can be present on the same interface simultaneously —
  that's the "combined mode" the issue describes, and it should be the
  default *capability* of the container (which peers exist is what
  differs, not the container's code path).

### Mode 1 — Road-warrior, standalone (no rendezvous VM)

**This must remain fully first-class, not implicitly superseded by mode
2/3.** An operator whose home connection has a stable/DDNS-reachable
address and can port-forward WireGuard's UDP port needs to be able to run
exactly this, with nothing else. The lancache-ng WireGuard container
listens on a UDP port, road-warrior clients hold peer configs pointing at
the operator's DDNS hostname, done. This is the simple case and should stay
simple — no rendezvous VM machinery should be a prerequisite for it.

### Mode 2 — Site-to-site via a rendezvous VM (the interesting case)

Most home connections have a dynamic IP and no reliable inbound
port-forwarding (CGNAT, ISP-blocked ports). Mode 2 solves this the way the
issue frames it: the operator has a separate, small, cheap VPS in a
datacenter with a known, permanent address — **entirely outside this
project's scope to provide**, the project only needs to support
*connecting out to* one. The lancache-ng WireGuard container **initiates
and maintains an outbound tunnel to that VM** (WireGuard peers are
symmetric at the protocol level, but only the home side needs to be the
one dialing out, since it's the side without a stable address or open
inbound port).

**"Rendezvous VM" in this issue's own framing is specifically a WireGuard
hub, not a bare tunnel endpoint.** The VM's job is not just "terminate one
tunnel back to the home LAN" — it holds:

1. **One peer**: the site-to-site tunnel back into the home LAN (via the
   lancache-ng WireGuard container).
2. **N peers**: individual road-warrior client configs.

A remote client (road-warrior) then dials the *rendezvous VM's* stable,
memorable address — never the home network's own (changing) address at
all — and the VM routes that client's traffic through the already-live
site-to-site tunnel into the home LAN. One fixed endpoint serves both
purposes; this is the shape the issue calls out as "likely the actual right
default," and this design treats it as the primary mode 2/3 topology
rather than a stretch case bolted on afterward.

```
 [road-warrior client] --WG--> [rendezvous VM, stable IP]
                                   |  (WG hub: site-to-site peer +
                                   |   N road-warrior peer configs)
                                   +--WG (outbound from home)--> [lancache-ng WG container] --> home LAN
```

Consequence for the rendezvous-VM-side config surface (the issue flags
this as worth deciding early): **the VM-side config must be built from the
start as a small multi-peer hub**, not a single-peer tunnel endpoint that
would need re-architecting later to add road-warrior peers. Concretely,
the VM's `wg0.conf` peer list and its `AllowedIPs`/forwarding rules
(`iptables`/`nftables` FORWARD + MASQUERADE or route-only, decided per
whether the VM itself needs LAN-bound traffic to look like it's sourced
from the VM or the original client) need to support N road-warrior peers
routing through the single site-to-site peer, from day one.

### Mode 3 — Combined (direct + site-to-site simultaneously)

If the home network *also* happens to have a reachable address (DDNS +
port-forwarding), the lancache-ng container can accept direct road-warrior
peers on top of maintaining the outbound site-to-site tunnel — both paths
active at once, operator's choice, no conflict between them since they're
just different peers on the same interface.

## Interaction with the dual-IP/dual-mode (standard/SSL) DNS architecture

Largely orthogonal, by design, but worth stating explicitly since a WireGuard
tunnel changes what a client can reach at L3:

- WireGuard operates at L3 (routing) — it gets a remote client's packets
  into the home LAN. It has no opinion about which of `IP_STANDARD` /
  `IP_SSL` the client's DNS resolver points at; that's a client-side
  network config choice exactly like it is for a LAN-local client today.
- A remote client tunneled in via WireGuard should be able to point its
  DNS at either `IP_STANDARD` or `IP_SSL` (whichever mode it wants) and get
  the same cached-download experience a LAN-local client gets — nothing in
  the standard/SSL split assumes L2-LAN-only clients, it assumes clients
  that can reach the proxy's IP at all, which a routed WireGuard tunnel
  satisfies.
- **One real interaction worth flagging**: this project's existing
  `NGINX_UPSTREAM_RESOLVER` / DNS-spoofing design (Key Design Decision
  AG-KD-001) depends on the *proxy's own* upstream DNS resolution never
  looping back through the LAN's PowerDNS. A remote WireGuard client's own
  DNS queries still need to go to `dns-standard`/`dns-ssl` over the tunnel
  (or the client needs to be configured to use them) for the DNS-spoofing
  half of the caching mechanism to apply to it at all — a client that
  keeps using its own home/mobile-carrier DNS while only routing HTTP(S)
  traffic through the tunnel would reach real CDNs directly and get no
  caching benefit, same as any device not pointed at this project's DNS
  today. This is existing behavior the WireGuard feature doesn't change,
  but it should be called out in operator-facing docs once this ships:
  "point your WireGuard client's DNS at the LAN's standard/SSL DNS IP over
  the tunnel," not assumed automatic.
- No changes to the DNS services themselves are anticipated by this
  design. `dns-standard`/`dns-ssl` and their IP bindings are unaffected;
  WireGuard adds a new path *into* the LAN, not a new DNS mode.

## Key management / rotation

- **Local side (lancache-ng deployment)**: `setup.sh`'s WireGuard flow
  generates the container's own keypair on first setup (private key never
  leaves the host; only the public key is shared with peers), following
  this project's existing convention (Rule-Ref: AG-SEC-002/AG-OP-008 —
  missing required values are generated when safe) rather than requiring
  the operator to run `wg genkey` by hand.
- **Per-road-warrior-client keys**: each client generates its own keypair
  and shares only the public key back to whichever side (local container
  in mode 1, rendezvous VM in modes 2/3) will hold its peer entry — the
  private key never needs to leave the client. `setup.sh` (or a companion
  subcommand) should be able to emit a ready-to-import client config
  (QR code and/or `.conf` file) the way most WireGuard management tools
  do, rather than making the operator hand-assemble one.
- **Rotation**: WireGuard has no built-in key-expiry mechanism — rotation
  is "generate a new keypair, push the new public key to the peer's config,
  remove the old peer entry." This project's setup/update idempotence
  conventions (`AGENTS.md`'s Convergence/Idempotence Checklist) apply
  directly: re-running the WireGuard setup flow with a rotated key must not
  silently orphan the old peer entry, and revoking a client should be a
  single explicit operation (remove its peer block, `wg syncconf` or
  container restart to apply) rather than requiring manual `.conf` surgery.
- **Rendezvous VM keys**: the VM's own keypair, and its peer list (site-to-
  site peer's public key + each road-warrior peer's public key), need the
  same "no manual file-editing required" treatment via the remote-SSH
  provisioning path below — this is exactly the two-machine coordination
  problem the issue calls out.

## Setup / installation flow

Two distinct sides, both need a real guided path, matching this project's
existing `setup.sh` UX (interactive prompts with sane defaults, not "read
the docs and edit files").

### Local side

`setup.sh` prompts for WireGuard mode (off / road-warrior / site-to-site /
combined), generates the local keypair, and wires up the new container —
same pattern as other optional features (e.g. WireGuard as an additional
compose profile/service, following this project's existing
profile-gating conventions rather than always running).

### Remote side (rendezvous VM, modes 2/3)

This is the harder, less-standard part the issue explicitly asks for: the
remote VM's WireGuard config **should not require a second, manually-run
setup session**. Proposed shape: `setup.sh` (or a purpose-built companion
subcommand, e.g. `setup.sh wireguard remote-configure`) takes the
operator's SSH target for their own VM and:

1. Connects out over SSH (the operator's own credentials/key — this
   project never stores or transmits VM SSH credentials beyond the single
   interactive session).
2. Installs WireGuard on the VM if not already present (distribution
   package, not a source build — Rule-Ref: AG-REL-001/AG-GOV-003 project
   language rules don't apply to a VM the project doesn't own or ship code
   to; this is orchestration, not new project source).
3. Writes/updates the VM's `wg0.conf` peer list: the site-to-site peer
   (this deployment's public key + the home LAN subnet in `AllowedIPs`)
   and, when road-warrior clients are added, new peer entries.
4. Exchanges public keys both ways over the same SSH session so neither
   side requires manual copy-paste.

**Open design question, not resolved here**: whether this lives as a new
`setup.sh` subcommand or a separate companion script. Leaning toward a
subcommand for discoverability (matches the existing single
command-surface convention), but this needs to be decided alongside the
actual `setup.sh` structure at implementation time, not assumed here.

## Build vs. adopt

The issue flags evaluating an existing, well-maintained WireGuard
management project (e.g. something in the `wg-easy` space) against a
custom-built minimal container, and separately flags two private,
unfinished side projects the maintainer already has in this exact space:
[`djdomi/WireguardEasyManagement`](https://github.com/djdomi/WireguardEasyManagement)
(bare-metal, Bash CLI + dialog wizard) and
[`djdomi/WireguardEasyManagement-Docker`](https://github.com/djdomi/WireguardEasyManagement-Docker)
(Docker-native, config-driven `wgmd` CLI supporting Compose and Swarm).

**This document could not evaluate either private repo's actual content**
— they are private and were not accessible during this design pass. That
evaluation is maintainer input this design can't substitute for: the
maintainer is the only one who can currently read those repos and judge
how close either is to this issue's shape (multi-mode, rendezvous-VM-hub,
SSH-driven remote provisioning). Flagging this as an explicit gap rather
than silently skipping the question or guessing at their contents.

Both are shell-based, which fits this project's Rust-and-shell language
convention (Rule-Ref: AG-REL-004/AG-GOV-003) if either is close enough to
adapt. A third-party tool like `wg-easy` (Node.js-based) would trigger the
new-language-approval rule (Rule-Ref: AG-REL-001/AG-GOV-003) if its code
were vendored into this repo, though running its prebuilt container image
as an optional dependency (rather than compiling its source into this
project) would be a materially different, lower-friction question — worth
distinguishing explicitly if this path is pursued, the same way this
project's own build-tools policy (Rule-Ref: AG-KD-003) distinguishes
"install/run a third-party tool" from "write new source in another
language."

**Recommendation for the maintainer's decision, not a conclusion**: review
the two private repos first, since they were built with this exact
scenario in mind and may already solve most of the "no manual file-editing"
UX goal; only evaluate third-party tools like `wg-easy` if neither private
repo is close enough to finish. This ordering is a suggestion, not a
decision made here.

## Security posture

This feature opens a routed path into the operator's LAN from the internet
(via the rendezvous VM in modes 2/3, or via a directly-reachable port in
mode 1). Matching this project's existing security-conscious conventions
(`AGENTS.md`'s `AG-SEC-*` rules) rather than defaulting to a wide-open
route:

- **Default-deny AllowedIPs**: each peer's `AllowedIPs` should be scoped to
  exactly what that peer needs — a road-warrior client gets its own
  `/32` (or `/128` for IPv6) tunnel address, not a blanket route to the
  whole LAN, unless the operator explicitly wants full-LAN access for that
  client. The rendezvous VM's peer entry for the site-to-site tunnel is the
  one peer that legitimately needs the full home-LAN subnet in
  `AllowedIPs`, since it's the one relaying road-warrior traffic onward.
- **No LAN IPs or VM addresses hardcoded** (Rule-Ref: AG-SEC-007) — the
  rendezvous VM's address and the local deployment's LAN subnet are
  operator-supplied config, generated/validated by `setup.sh`, never
  baked into the container image or committed source.
- **Firewall/NAT scope**: the container needs `NET_ADMIN` (and, depending
  on kernel-module availability inside the container's host, possibly
  `SYS_MODULE` if the `wireguard` kernel module isn't already loaded on the
  host) — this is a real, narrow capability grant that should be documented
  as such, not silently added to a shared capability set other services
  use.
- **Credential/key storage**: private keys for the local container and any
  client configs `setup.sh` generates must never be committed or logged
  (Rule-Ref: AG-SEC-003), and should live alongside this project's existing
  secrets-handling convention (e.g. the `shared-secrets` volume pattern
  already used for `PDNS_API_KEY`/`KEA_CTRL_TOKEN`, or an equivalent
  dedicated volume) rather than a new ad-hoc location.
- **Rendezvous VM compromise blast radius**: since the VM in modes 2/3 sits
  between the internet and the home LAN, a compromised VM could relay
  traffic into the LAN. This is inherent to the rendezvous-hub topology the
  issue asks for (there's no way to get a stable front door for a
  CGNAT'd home network without *some* internet-facing relay), but it
  should be called out explicitly in operator-facing docs as the real
  tradeoff of choosing mode 2/3 over mode 1, not left implicit.

## Known hard parts (flagged, not resolved here)

- Real site-to-site routing: NAT/route table management on both ends,
  deciding what subnet(s) get advertised/routed through the tunnel,
  avoiding route conflicts with the operator's existing LAN addressing.
- Whether mode 2/3 needs any control-plane coordination with this
  project's own Admin UI (connected-peer list, tunnel status) or is meant
  to be operated purely via WireGuard's own tooling/config files, out of
  the Admin UI's scope entirely. Leaning toward "eventually yes, for
  parity with how this project treats other optional services as a
  Bringschuld once backend support exists," per `AGENTS.md`'s Feature
  Completeness section — but not designed here.

## Open decisions for the maintainer

1. **Custom-build vs. adopt** (including reviewing the two private repos
   first — see "Build vs. adopt" above).
2. **`setup.sh` subcommand vs. separate companion script** for the
   remote-SSH rendezvous-VM provisioning flow.
3. **Admin UI integration scope** for tunnel/peer status, if any, for
   v0.3.0 vs. a later follow-up.
4. Whether IPv6 is in scope for the WireGuard tunnel itself (this project
   is IPv6 dual-stack elsewhere; not addressed in the issue text and not
   assumed here).

## Scope recap

This issue is for design/research first, not implementation. No container,
no `setup.sh` changes, and no compose wiring exist yet as a result of this
document — it exists to give the maintainer a concrete plan and a
named set of decisions to make before any of that code is written.
