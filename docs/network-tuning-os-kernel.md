# OS / Kernel Network Tuning

This document covers OS- and kernel-level network tuning for LanCache-NG's
cache-proxy workload: Docker networking behavior (TSO/GSO/GRO,
`userland-proxy`), NIC/network-path tuning (kTLS, NIC queues/RSS, RPS/XPS,
macvlan/ipvlan vs. host networking), conntrack table monitoring, and the
`rps_cpus`/RFS tuning commands. It answers issue #849's items 12-15 (folded
in from #1068). **Item 11 (nginx `proxy_cache_path`/cache-key tuning) is
explicitly out of scope for this document** -- it lives at the application
layer, not the OS/kernel layer, and is tracked separately.

## Scope and how this was investigated

Every number and configuration state below was captured live via SSH against
this project's real self-hosted CI runner fleet, not assumed or copied from
generic tuning guides:

- `192.168.1.229`, `192.168.1.241`, `192.168.1.243` -- reachable, inspected
  2026-08-05 (~19:15-19:35 UTC).
- `192.168.1.240` -- unreachable (`ssh` connection timed out on repeated
  attempts at the time of writing); not inspected. Re-verify separately
  before assuming any of this document's per-host numbers also hold there.

**Important caveat, load-bearing for how to read every measurement below:**
these three hosts are this project's **CI runner fleet**, not a deployed
LanCache-NG production stack. At the time of inspection they were running
only transient `full-setup` validation containers (each torn down within
minutes of starting) plus CI build/validation infrastructure (`buildx`
builders, `lancache-ng-validation-*` shim containers) -- no long-lived,
real-traffic LanCache-NG deployment exists on any of them today. Numbers
like conntrack table utilization are therefore facts about an **idle CI
runner**, not evidence about production cache-proxy conntrack pressure under
real concurrent-client load. Every diagnostic command below is written so a
maintainer can re-run it, unchanged, against a real deployment host (a
customer's LanCache-NG server, or a future persistent staging deployment) to
get the number that actually matters for that host.

All three reachable hosts are **Proxmox LXC containers** (ZFS
`rpool/data/subvol-*` root filesystem, kernel `7.0.12-1-pve` -- LXC
containers share the host's kernel, unlike a VM), not bare metal and not
full VMs. This matters for several findings below: their network interface
is a virtual `veth` pair, not a real NIC, and some kernel-level tuning knobs
that are freely writable as root on a bare-metal or VM deployment host are
**not** writable from inside these containers even as root, because the
relevant capability check happens against the *host's* initial network
namespace, which an unprivileged LXC container does not have. Each section
below states explicitly which facts are CI-runner-specific artifacts of
this and which are directly applicable to a real deployment host.

## Item 12: Docker / network tuning (TSO/GSO/GRO, `userland-proxy`)

### Measured `daemon.json` / `docker info` (all three hosts, 2026-08-05)

| Host | `userland-proxy` key | `ipv6` key | Storage driver |
|---|---|---|---|
| `.229` | not set (Docker default: `true`) | not set | `overlay2` |
| `.241` | not set (Docker default: `true`) | not set | `overlay2` |
| `.243` | not set (Docker default: `true`) | not set | `overlayfs` |

None of the three hosts' `/etc/docker/daemon.json` sets `userland-proxy` at
all, so Docker's compiled-in default (`true`) is in effect everywhere. None
set `"ipv6": true` either, consistent with this project's current no-IPv6
state (Rule-Ref: AG-IPV6-001 documents the requirement for a real
deployment; these CI runners are not a deployment).

Check on any host: `sudo cat /etc/docker/daemon.json` (root-owned, `sudo`
required even to read it) and `docker info | grep -iE 'storage driver'`.

### Why `userland-proxy: true` matters for this workload specifically

This is not purely a throughput question. This project's own earlier proxy
audit already recorded a real,
previously-noted finding: Docker's userland proxy (`docker-proxy`, the
process that exists when `userland-proxy: true`) can present the proxy
container with a rewritten source IP (the bridge gateway address) instead
of the real client's address in some configurations, which would make any
source-IP-based access control (this project's `PROXY_ALLOWED_CLIENT_CIDRS`
stream-mode allowlist) effectively all-or-nothing rather than a real
per-client filter. That prior finding explicitly says this "does not
currently misfire" in the specific case checked (a dev-environment gateway
subnet happened to already fall inside the dev allowlist) -- it was noted,
not filed, and was not re-derived or re-verified here. This document does
not repeat or re-derive the underlying docker-proxy source-IP mechanism
itself (that would require a live packet-level test this pass did not
run); it cites the existing finding as the concrete reason `userland-proxy`
is worth testing for this project specifically, beyond generic "less
overhead" advice.

**Confirmed live** (`deploy/prod/docker-compose.yml`): the `proxy` service
publishes ports via `ports: ["${IP_STANDARD}:80:80", ...]` on Docker's
default bridge network -- it does **not** use `network_mode: host` and
does not use macvlan/ipvlan. Every published port on that service goes
through whichever port-publishing path `userland-proxy` selects.

### Recommendation

Test `"userland-proxy": false` in `/etc/docker/daemon.json` on a
**LanCache-NG deployment host** (not a shared, actively-CI-busy runner --
changing this setting requires a full Docker daemon restart, which would
kill every in-flight build/validation container on a runner; this was
deliberately **not** applied to any of `.229`/`.241`/`.243` during this
investigation since all three had live CI containers running at inspection
time). Verification recipe for whoever runs this test:

```sh
# Before: capture a real client request's $remote_addr as nginx sees it.
curl -s http://<lancache-host>/some/cached/path -o /dev/null
docker exec lancache-proxy tail -5 /var/log/nginx/access.log   # note $remote_addr

# Apply the change (requires a Docker daemon restart -- disruptive):
sudo vi /etc/docker/daemon.json     # add "userland-proxy": false
sudo systemctl restart docker
docker compose -f deploy/prod/docker-compose.yml up -d

# After: repeat the same request from the same real client and compare.
curl -s http://<lancache-host>/some/cached/path -o /dev/null
docker exec lancache-proxy tail -5 /var/log/nginx/access.log   # compare $remote_addr
```

If `$remote_addr` already shows the real client IP with `userland-proxy:
true` (i.e. the docker-proxy path is not actually the one handling this
project's specific port-publish configuration), disabling it is a
lower-risk, low-overhead win with no behavior change. If it changes
`$remote_addr` behavior in either direction, that is itself the answer to
whether that earlier proxy audit's existing "noted, not filed" nuance is
real for a production deployment, and should be filed as its own issue at
that point. This is recorded here as a **maintainer-owned follow-up test**,
not applied in this pass.

### TSO/GSO/GRO -- measured, not assumed

`ethtool` is not installed on any of these runner images by default; it was
installed temporarily on `.243` for this one diagnostic pass and purged
again immediately afterward (confirmed via `which ethtool` returning
nothing after cleanup -- no lasting footprint left on the runner).

```
$ sudo ethtool -i eth0
driver: veth
[...]
$ sudo ethtool -k eth0 | grep -E 'tcp-segmentation|generic-segmentation|generic-receive|large-receive'
tcp-segmentation-offload: on
generic-segmentation-offload: on
generic-receive-offload: off
large-receive-offload: off [fixed]
```

TSO (tcp-segmentation-offload) and GSO (generic-segmentation-offload) are
already **on**. GRO (generic-receive-offload) is **off** and, unlike LRO,
is not `[fixed]` -- it is a real, live, changeable setting on this
interface. GRO coalesces incoming packets before they reach the IP stack,
which reduces per-packet CPU overhead specifically for high-throughput
bulk receive traffic -- directly relevant to this project's core workload
(serving large cached game/software downloads to many parallel LAN
clients). Recommended test on a real deployment host's outward-facing
interface:

```sh
sudo ethtool -K <iface> gro on
# Verify it actually took (some interfaces silently refuse):
sudo ethtool -k <iface> | grep generic-receive-offload
```

This is a low-risk, easily-reversible single-command change (`ethtool -K
<iface> gro off` reverts it), but was not applied to any of the three CI
runner hosts here because their `eth0` is a shared CI-runner-internal
`veth`, not the actual outward-facing interface of a LanCache-NG
deployment, and all three were mid-CI-job at inspection time. Re-check the
same command on the real deployment's actual LAN-facing interface before
applying.

## Item 13: NIC / network-path tuning

### The honest headline finding: there is no real NIC on this CI fleet

`sudo ethtool -i eth0` on `.243` reports `driver: veth` -- this interface
is a virtual veth pair (one end in the LXC container, one end on the
Proxmox host's bridge), not a physical network card. `readlink -f
/sys/class/net/eth0/device` resolves to `/sys/devices/virtual/net/eth0` --
confirmed virtual, no PCI device backing it. This is expected and correct
for a containerized CI runner, but it means several of item 13's original
questions (real NIC hardware/driver, hardware RSS queue count) **do not
apply at this level** -- they would need to be answered against the
Proxmox hypervisor host's own physical NIC, which is outside this
investigation's SSH access (SSH here lands inside the LXC container, not
the hypervisor). For an actual bare-metal or VM-with-passthrough LanCache-NG
deployment, `sudo ethtool -i <iface>` and `sudo ethtool -l <iface>` (queue
count) against the real interface are exactly the right commands -- they
were simply not answerable *for this specific fleet* at the level this
investigation could reach.

### NIC queues and RSS -- single queue everywhere, confirmed

```
$ ls /sys/class/net/eth0/queues/
rx-0  tx-0
```

Every host checked (`.229`, `.241`, `.243`) has exactly one RX queue and
one TX queue on `eth0`. RSS (Receive Side Scaling, spreading interrupt
processing across multiple hardware queues/CPUs) requires multiple queues
to have anything to distribute across -- with a single queue, RSS is not
applicable on this fleet today. A real deployment on hardware with a
multi-queue NIC should check `sudo ethtool -l <iface>` and, if multiple
queues are available, confirm IRQ affinity is spread across CPUs (`cat
/proc/interrupts | grep <iface>`, then `/proc/irq/<n>/smp_affinity`) rather
than defaulting to all interrupts landing on CPU0.

### kTLS -- concretely available today, not applied, needs a live test

This item turned out to be answerable with real evidence rather than left
as "needs testing in the abstract":

- **Kernel support**: `/sys/module/tls` and `/proc/modules` both show the
  `tls` kernel module loaded on `.243` (`tls 147456 1 bonding, Live`) --
  visible from inside the container because LXC containers share the
  host's kernel and loaded-module list. kTLS is available at the kernel
  level on this fleet.
- **OpenSSL support**: the actual published `proxy` image
  (`ghcr.io/wiki-mod/lancache-ng/proxy:latest`) links OpenSSL 3.5.6.
  `grep -a` against the shipped `libssl.so.3` for printable strings found
  `KTLS`, `KTLSTxZerocopySendfile`, `ktls_sendfile failure`,
  `../ssl/record/methods/ktls_meth.c`, `ktls_read_n`,
  `ktls_validate_record_header` -- this build of OpenSSL was compiled with
  kTLS support.
- **nginx support**: `docker run --rm --entrypoint nginx
  ghcr.io/wiki-mod/lancache-ng/proxy:latest -V` reports `nginx/1.31.3`,
  `--with-http_ssl_module`, `--with-stream_ssl_module` -- nginx has
  supported `ssl_conf_command Options KTLS;` since 1.21.4, well before this
  version.
- **`sendfile`**: `services/proxy/nginx.conf` has `sendfile on;` -- kTLS
  only changes anything on the sendfile path (it lets the kernel handle
  TLS record framing for data served via `sendfile()`, avoiding a
  userspace copy/encrypt step for every cached-file response), so this
  project's actual configuration is exactly the shape that would benefit.
- **Not currently enabled**: `services/proxy/conf.d/https.conf` has no
  `ssl_conf_command Options KTLS;` directive today.

All four preconditions are met; the only missing piece is the one-line
directive plus a real verification that it actually engages at runtime
(directive presence is not proof of engagement). Recommended verification
recipe for a follow-up PR (not applied here -- this is an nginx
`conf.d`-level change, adjacent to the parallel nginx-tuning work this
project is also doing under issue #849 item 11, so it is flagged as a
distinct, dedicated follow-up rather than bundled into this docs-only
pass):

```sh
# Add to services/proxy/conf.d/https.conf, inside the https server block:
ssl_conf_command Options KTLS;

# After deploying, verify it actually engaged (directive presence alone is not proof):
cat /proc/net/tls_stat        # non-zero TlsCurrTxSw/TlsCurrRxSw counters if the kernel path is exercised
# or, more directly, during a real HTTPS cache-hit download:
strace -f -e trace=setsockopt -p <nginx-worker-pid> 2>&1 | grep -i tls
```

### RSS/RPS/XPS and macvlan/ipvlan vs. host networking

RPS is covered in detail under item 15 below (it is the one part of item
13 that is actually actionable on a single-queue virtual interface). XPS
(Transmit Packet Steering) distributes *outgoing* traffic across multiple
TX queues -- since every host checked has exactly one TX queue (`tx-0`
only), **XPS has no effect here today**; this is a genuine negative
finding, not a gap, and applies to any single-TX-queue interface,
container or bare metal.

On macvlan/ipvlan vs. the current default bridge networking: the `proxy`
service's current bridge-mode setup (published ports bound to
`IP_STANDARD`/`IP_SSL`) matches this project's documented architecture
rationale (Rule-Ref: AG-KD-004 -- nginx reads `Host`/SNI directly rather
than needing a DNAT-preserved original destination, which is exactly what
macvlan/ipvlan would otherwise be useful for in a Squid-style
transparent-proxy design this project deliberately does not use). Moving
to macvlan/ipvlan or `network_mode: host` for the proxy service would be a
non-trivial architecture change (different IP/MAC exposure on the LAN,
different interaction with the existing two-IP `IP_STANDARD`/`IP_SSL`
design, broadcast/multicast handling differences) with real security and
operational tradeoffs that were not evaluated in depth here -- this is
flagged as an open question for the maintainer rather than a recommendation
either way; the current bridge-mode setup is not identified as a defect.

## Item 14: Conntrack table utilization + Netdata monitoring

### Measured utilization (2026-08-05, idle CI runners -- see caveat above)

| Host | `nf_conntrack_count` | `nf_conntrack_max` | Utilization |
|---|---|---|---|
| `.229` | 175 | 262144 | 0.07% |
| `.241` | 126 | 262144 | 0.05% |
| `.243` | 313 | 262144 | 0.12% |

Command used (works identically on a real deployment host, run it there
for the number that actually matters):

```sh
cat /proc/sys/net/netfilter/nf_conntrack_count
cat /proc/sys/net/netfilter/nf_conntrack_max
```

As stated in the Scope section above, these hosts run only transient CI
validation containers, not a real LanCache-NG deployment under concurrent
client load -- these percentages are evidence the *measurement mechanism*
works, not evidence that conntrack pressure is a non-issue in production.
`/proc/net/stat/nf_conntrack` (a more detailed breakdown: searched, found,
new, invalid, ignore, delete counters) does **not** exist inside any of
these containers' network namespaces -- confirmed by direct `cat`, not
assumed.

### Does any monitoring/alerting for this already exist? Yes, by default -- with one real gap

Per Rule-Ref: AG-VAL-023 (check upstream docs/source before assuming
behavior), this was verified against netdata's actual upstream source
rather than guessed:

- Netdata's `proc.plugin` conntrack collector
  (`proc_net_stat_conntrack.c`) is **enabled by default**
  (`inicfg_get_boolean(..., CONFIG_BOOLEAN_YES)`), and this project's
  `services/netdata/entrypoint.sh` does not disable or override it (it
  only overrides the `[logs]` section).
- The collector **gracefully degrades**: if `/proc/net/stat/nf_conntrack`
  fails to open (exactly the case measured above -- it does not exist in
  these containers), the collector does not disable itself; it falls back
  to reading `/proc/sys/net/netfilter/nf_conntrack_count` and
  `nf_conntrack_max` directly (the same two values in the table above) and
  still produces a `netfilter.conntrack_sockets` utilization chart from
  them.
- Netdata ships a **default health alarm**, `netfilter_conntrack_full`
  (`health.d/netfilter.conf`), attached to that exact chart: warning at
  90% utilization, critical at 95%, re-evaluated every 10 seconds, routed
  to the `sysadmin` notification role by default.

So the collector and the alarm both already exist, are already enabled,
and already tolerate this containerized environment's missing detailed
stat file -- **no new collector code is needed for the basic utilization
chart and alarm to exist.**

**Network namespace check -- verified, not assumed, and the result is good
news:** the initial working hypothesis for this section was that
`netdata`'s conntrack collector would be observing its own isolated
container network namespace rather than the host's, since the `netdata`
service in `deploy/prod/docker-compose.yml` sets `pid: host` but not
`network_mode: host`. Reading the rest of that service's actual `volumes:`
block (not just the part read on the first pass) disproves that
hypothesis: it mounts `- /proc:/host/proc:ro` and `- /sys:/host/sys:ro`.
Netdata's own official Docker entrypoint (`packaging/docker/run.sh`,
checked directly against its upstream source) execs the daemon with a
**hardcoded** `-s /host` host-prefix flag unconditionally (it does not
conditionally detect the mount and does not need to -- the flag is always
passed). With `-s /host` and a real `/proc:/host/proc:ro` bind mount in
place, netdata's `/proc/sys/net/netfilter/nf_conntrack_count`/`_max` reads
resolve through that bind-mounted procfs instance -- i.e. the **real host
network namespace's** conntrack counters (in this fleet, the LXC
container's own root netns, the exact same one this investigation queried
directly via SSH above), not netdata's own container-local, isolated
bridge-network namespace. Network namespace isolation between containers
does not change this, because a bind-mounted `/proc` reflects whichever
namespace it was mounted *from*, independent of which namespace the
*reading* process itself lives in. **So the conntrack chart and its alarm
already observe the right, host-level, aggregate numbers today, with no
`network_mode: host` needed and no code change required** -- the opposite
of this section's original working hypothesis, corrected here before
publication rather than shipped as a wrong claim.

Separately, still a real and unresolved gap: `grep`-ing this repository
for any netdata alerting/notification wiring (`health_alarm_notify.conf`,
`SEND_EMAIL`, webhook config, etc.) found nothing -- the default
`netfilter_conntrack_full` alarm, confirmed above to observe the right
namespace, still has no configured notification channel today. It would be
visible on netdata's own dashboard (port 19999) to someone actively
looking, but would not proactively alert anyone.

### Structured decision for the maintainer

- [ ] **Netdata alarm notifications**: should this project wire up a
      notification channel (`health_alarm_notify.conf`) for netdata's
      existing default alarms (including `netfilter_conntrack_full`,
      confirmed above to already observe the correct host-level
      namespace), or is dashboard-only visibility (port 19999) considered
      sufficient for now?
- [ ] **Watchdog's own conntrack visibility**: separately from netdata,
      should the Rust watchdog (issue #842, still not stack-wide) surface
      conntrack pressure itself, or is relying on netdata's existing
      collector/alarm (already confirmed correctly scoped, see above)
      sufficient, avoiding duplicate monitoring logic?

No code change is included in this pass for item 14: the collector and
its alarm are already correctly configured and already observe the right
namespace by virtue of the existing `/proc:/host/proc:ro` mount -- the
only open question is notification wiring, which is a maintainer policy
decision (does this project want proactive alerting at all, and through
which channel), not a technical gap in the monitoring itself.

## Item 15: RPS tuning -- the actual commands, computed, not copied

The original audit note explicitly warned not to blindly copy example
`rps_cpus` values -- this section gives the real commands to compute the
correct value for whatever host and interface is actually being tuned,
plus what was found when those commands were actually run against this
project's own runner fleet.

### Step 1: find the real online-CPU set (do not assume 0..nproc-1 is contiguous)

```sh
cat /sys/devices/system/cpu/online
```

On `.243` this returned `0-7` (8 online CPUs, contiguous from 0 -- but
`lscpu` on the same host reports 16 total CPUs with 8-15 offline, so the
*total* CPU count is not always the same as the *online range*; always
parse `/sys/devices/system/cpu/online` rather than assuming
`0..nproc-1`). On `.229`, `nproc` reports 8; on `.241`, `nproc` reports 7 --
per-host CPU allocation genuinely differs across this fleet, another
reason not to copy one host's bitmask onto another.

### Step 2: find the real queue count for the interface being tuned

```sh
IFACE=eth0
ls /sys/class/net/"$IFACE"/queues/ | grep -c '^rx-'
```

Every host checked here returns `1` (single RX queue). RPS exists
precisely for this case: it lets a single hardware/virtual queue's
software (softirq) protocol-processing work be spread across multiple
CPUs even though there is only one queue to receive on.

### Step 3: compute the bitmask (pure bash, no extra tooling needed)

```sh
IFACE=eth0
# Read the real online range, e.g. "0-7" or "0-3,8-11" -- do not assume contiguous-from-0.
online="$(cat /sys/devices/system/cpu/online)"
mask=0
IFS=',' read -ra ranges <<< "$online"
for r in "${ranges[@]}"; do
  if [[ "$r" == *-* ]]; then lo="${r%-*}"; hi="${r#*-}"; else lo="$r"; hi="$r"; fi
  for ((cpu=lo; cpu<=hi; cpu++)); do mask=$(( mask | (1 << cpu) )); done
done
printf 'Computed rps_cpus mask: %x\n' "$mask"
```

On excluding CPU0 ("the convention"): the common recommendation to exclude
the CPU currently handling the interface's hardware interrupt from its own
RPS mask comes from avoiding that CPU doing both top-half (hardware IRQ)
and bottom-half (RPS-steered softirq) work for the same queue. That
convention does **not mechanically apply here**: `grep -iE 'eth0|veth'
/proc/interrupts` on `.243` returned nothing at all -- this virtual `veth`
interface has no hardware interrupt line to exclude a CPU from. Inventing
a `0xfe`-style "skip CPU0" mask anyway, with no IRQ evidence to justify it,
would be exactly the "blindly copy the example value" failure this item
warns against. On a real deployment host with an actual multi-queue NIC,
check `/proc/interrupts` for that NIC's real IRQ-to-CPU mapping first, and
exclude that CPU from the mask *if and only if* the interrupt evidence
supports it.

### Step 4: apply and read back (a write with bits for offline CPUs is silently masked -- read-back is the only proof)

```sh
IFACE=eth0
for q in /sys/class/net/"$IFACE"/queues/rx-*; do
  echo "$mask" | sudo tee "$q/rps_cpus" >/dev/null
  echo "$q -> $(cat "$q/rps_cpus")"   # read back; compare to what was written
done
```

### What actually happened when this was run against `.243`

- `rps_cpus` for `rx-0` read as `0000` (RPS currently disabled) before any
  change.
- The write itself **failed**: `tee: /sys/class/net/eth0/queues/rx-0/rps_cpus:
  Operation not permitted`, confirmed both for a test value and for
  restoring the original value -- even as `sudo` inside the container.
  This is expected for an unprivileged LXC container: the veth's "real"
  end lives in the Proxmox host's own initial network namespace, and RPS
  configuration for it is gated by a capability check against that
  namespace, which the container's own root does not have. **This command
  set is correct and will work as root on a real bare-metal or
  privileged-VM LanCache-NG deployment host** -- it simply cannot be
  applied *from inside this specific CI runner fleet*, which is further
  confirmation that these three hosts are not a stand-in for a real
  deployment host for this particular tuning question.
- `/proc/sys/net/core/rps_sock_flow_entries` (the global setting the
  original item's `rps_flow_cnt` question depends on -- Receive Flow
  Steering, RFS) **does not exist** in this container's namespace either.
  Without it, per-queue `rps_flow_cnt` (documented upstream as
  `rps_sock_flow_entries / number_of_rx_queues`, which for this fleet's
  single-queue case would simply equal `rps_sock_flow_entries` itself) has
  nothing to divide -- RFS is not configurable from inside these
  containers at all, another concrete, verified negative finding rather
  than an assumption.

### XPS

Already covered under item 13 above: with a single TX queue (`tx-0`
only, confirmed on every host checked), XPS has no queues to distribute
transmit traffic across, so tuning it is a no-op on this fleet today. This
is stated as an explicit negative finding, not an omission.

## Why this has no new automated CI check (AG-VAL-029)

Every finding in this document describes the current state of CI-runner
infrastructure configuration (Docker daemon defaults, virtual-NIC
capabilities, per-host CPU allocation, LXC-container capability
restrictions) or documents a set of commands intended for a future real
deployment host -- none of it is a defect in this project's own shipped
product code, and none of it is currently regression-testable in this
project's own CI (there is no persistent, real-traffic LanCache-NG
deployment in CI to assert conntrack/RPS/kTLS behavior against). Per
Rule-Ref: AG-VAL-029's own carve-out for genuinely-impractical-to-automate
cases: this is recorded here, in this document, as the reasoned exception,
rather than silently omitted.
