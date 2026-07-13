#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Real DHCP behavior test for our own Kea service (issue #448) -- distinct
# from services/ui/dhcp-probe.sh's existing #377 conflict-discovery check.
# dhcp-probe.sh answers "does any DHCP server answer on the LAN segment,
# and does a host-interface dry-run also succeed" and is intentionally left
# unchanged by this script. This script answers a different question: does
# OUR Kea service, when driven by a completely real DHCP client, actually
# complete Discover/Offer/Request/Ack and hand out the address range,
# router, DNS, NTP, and lease-time options the operator configured?
#
# Safety model (see the issue's acceptance criteria: "must not modify the
# host's active network configuration" by default):
#   - Both the Kea server and the DHCP client run as ordinary Docker
#     containers on a throwaway bridge network created and destroyed by
#     this script. Every container already gets its own network namespace
#     from Docker, and this network is never bridged to any host interface
#     or attached to the runner's real LAN -- it is exactly the "isolated
#     network namespace ... or veth pair" approach the issue asks for, not
#     a stretch reading of it.
#   - The client's own veth/eth0 is left exactly as Docker's IPAM
#     configured it: dhclient runs with `-sf /bin/true` (a no-op "apply
#     the lease" script), the same technique services/ui/dhcp-probe.sh
#     already relies on -- a real lease is negotiated over the wire, but
#     nothing ever calls `ip addr add`/`ip route` to actually apply it.
#   - Docker's own container-address allocation is confined to a small
#     sub-range (see --ip-range below) that never overlaps the Kea pool,
#     so there is no possibility of the test's own plumbing colliding with
#     the addresses under test.
#   - This script has no invasive/host-interface mode at all -- there was
#     nothing to gate behind an opt-in flag. It only ever runs via
#     workflow_dispatch (full-setup-validate.yml), never on every PR.
#
# Static host reservations (issue #707): after the base Discover/Offer/
# Request/Ack scenario above, this script also configures a real static
# reservation directly through Kea's own Control Agent API -- the same
# config-get (strip "hash") -> config-test -> config-set -> config-write
# sequence services/ui/src/routes/dhcp.rs's kea_config_modify() drives for
# the Admin UI's /dhcp/static/add route, just called here without going
# through the Admin UI HTTP layer -- and then runs a SECOND and THIRD real
# dhclient client (assert_static_reservation_honored below) to prove Kea's
# own runtime actually honors it: the reserved MAC receives the reserved,
# out-of-pool address, and a second, unrelated MAC still receives a normal
# pool address rather than leaking the reservation. This is a different
# layer than issue #634's Kea Control Agent mutation test (which proves the
# Admin UI's own Rust code path applies a reservation correctly against a
# real Kea, through a full Admin UI + compose stack): this script proves Kea
# itself, given that exact API surface, honors the reservation for the right
# client and only the right client, using the lightweight single-container
# setup already established above.
#
# What this script does NOT verify (documented per the issue's "must
# document what is verified and what is not verified" criterion):
#   - Reverse (PTR) DDNS updates. Confirmed BROKEN in production, discovered
#     incidentally while empirically verifying forward DDNS below: Kea's D2
#     sends the reverse update's on-wire zone as the literal string
#     "in-addr.arpa." (services/dhcp/kea-dhcp-ddns.conf's reverse-ddns
#     "name"), but services/dns/entrypoint.sh never creates a zone with that
#     exact name -- only narrower private-range subzones (e.g.
#     "31.172.in-addr.arpa.") -- so PowerDNS rejects every PTR update with
#     "Can't determine backend for domain 'in-addr.arpa'" (RCODE 9,
#     NOTAUTH), for any octet, unconditionally. Refs #768 (tracks the fix;
#     out of scope here since it needs its own design, not a #706 sub-item).
#   - The dnsmasq-proxy DHCP mode (services/dhcp-proxy) -- entirely
#     different code path, out of scope for this script.
#
# Forward (A-record) DHCP-DDNS lease-event follow-through (issue #706, the
# DDNS half of #557's scenario 2) IS verified below: after the lease above
# is confirmed, this script also starts a real PowerDNS container built
# from THIS checkout's services/dns, set as the Kea container's
# DHCP_DNS_SERVER_IP -- the exact same variable
# services/dhcp/kea-dhcp-ddns.conf's forward-ddns section targets for real
# Kea DDNS updates in production -- and sharing the same DDNS_TSIG_KEY
# secret both containers' entrypoints already validate independently in
# production (services/dhcp/entrypoint.sh's DDNS_TSIG_KEY check,
# services/dns/entrypoint.sh's configure_ddns_tsig). It then queries the
# PowerDNS authoritative server directly -- dig against 127.0.0.1:5300
# inside that container, the exact loopback address/port
# services/dns/pdns.conf.template binds pdns_server to -- for the A record
# Kea's kea-dhcp-ddns daemon should have created via a TSIG-signed nsupdate,
# and asserts it matches the leased address. One piece of this setup is a
# test-only shim, not production wiring: this script deliberately uses a
# distinctive, run-unique DHCP_DOMAIN (see $dhcp_test_domain below, kept
# for an unrelated pre-existing assertion) rather than production's fixed
# "lan", so it also creates and TSIG-authorizes that one extra zone via
# pdnsutil before Kea starts -- a step production never needs, because
# production's real DHCP_DOMAIN ("lan") already matches the "lan." zone
# services/dns/entrypoint.sh creates unconditionally on every start. The
# DDNS transport/config path this exercises (TSIG key, port, bind address,
# allow-list) is the real one; only that one zone's existence is bootstrapped
# by this script instead of by the production entrypoint.
#
# This script also does not exercise the full production network topology
# for DHCP-DDNS: in prod, the `dhcp` container runs with network_mode: host
# and reaches PowerDNS through a published host port (see
# deploy/prod/docker-compose.yml's dns-standard/dns-ssl "5300:5300/udp"
# entries and config/prod/dns-*.env's DDNS_ALLOW_FROM comment), not a
# shared Docker bridge network the way this script's throwaway Kea and
# PowerDNS containers are. That specific host-network-mode ->
# published-port path (and which source IP PowerDNS actually observes
# there) was verified separately, by hand, on a real host -- not by this
# script, which instead proves the DDNS transport/config itself is correct
# on an isolated bridge network.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# shellcheck source=scripts/lib/dhcp-lease-parse.sh
source "$repo_root/scripts/lib/dhcp-lease-parse.sh"

client_tool_image="${DHCP_LEASE_FLOW_CLIENT_IMAGE:?DHCP_LEASE_FLOW_CLIENT_IMAGE is required (an image providing dhclient, e.g. the build-tools image)}"

work_dir="$repo_root/.dhcp-kea-lease-flow-simulation-tmp"
rm -rf "$work_dir"
mkdir -p "$work_dir/client-state"

# ISC dhclient (4.4.x, the Debian isc-dhcp-client package) binds the raw DHCP
# socket as root, then permanently drops privileges to an unprivileged,
# package-hardcoded system account before opening this script's own -pf/-lf
# paths or exec'ing the -sf lease-apply script below. dhclient.out keeps
# being written fine regardless (its fd was already open, inherited from
# this script's own shell redirect, before that privilege drop happens --
# writing through an already-open fd needs no further permission check), but
# any *new* file dhclient itself tries to create afterward in
# client-state/ gets EACCES from that unprivileged identity. Confirmed
# directly (issue #712): a real run showed "can't create
# .../dhclient.leases: Permission denied" and "Can't create
# .../dhclient.pid: Permission denied" interleaved with a fully successful
# DHCPACK/bound-to exchange -- the lease negotiation itself was never the
# problem, dhclient just couldn't persist it to disk. Making this directory
# world-writable is safe here: it is a throwaway, per-run temp directory
# scoped to this one script invocation, not a shared or security-sensitive
# path, and this is what lets dhclient's post-privilege-drop identity
# actually write the lease file the rest of this script depends on.
chmod 0777 "$work_dir/client-state"

# A fixed subnet would collide across concurrent runs sharing one of this
# project's self-hosted runner hosts, exactly like the full-setup validation
# network did before #623's per-run derivation. Mirror that fix here: derive
# the third octet of a dedicated 172.31.0.0/16 range (unused by
# deploy/dev's 172.28.0.0/16 and full-setup-validate's 172.30.0.0/16) from
# this run's own identity, with a random fallback so an operator can still
# run this script directly (not just via GitHub Actions).
run_identity="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-$$}-${RANDOM:-0}"
digest="$(printf '%s' "$run_identity" | sha256sum | cut -c1-8)"
octet=$(( (16#$digest % 252) + 2 )) # 2..253
subnet="172.31.${octet}.0/24"
gateway="172.31.${octet}.1"
kea_ip="172.31.${octet}.2"
# pdns_ip (issue #706): the real PowerDNS container the DDNS verification
# section further below stands up. Reserved here, alongside the other fixed
# addresses in this /24, so it stays visibly outside both the DHCP pool
# ($pool_start-$pool_end) and $kea_ip.
pdns_ip="172.31.${octet}.3"
# dhcp_test_domain: a distinctive, run-unique DHCP_DOMAIN value (not the
# production default "lan") so the domain-name-option assertion further
# below can tell a correctly-applied DHCP_DOMAIN config apart from Kea
# silently falling back to some internal default -- a fixed value like
# "lan" could pass that assertion even if Kea ignored the configured
# option entirely. Named once here (both the Kea container's DHCP_DOMAIN
# env var and the PowerDNS test zone created for it, further below, must
# use exactly the same value).
dhcp_test_domain="lancache-dhcp448-test.lan"
pool_start="172.31.${octet}.128"
pool_end="172.31.${octet}.200"

# $work_dir above needs no per-run uniqueness of its own: $repo_root is
# already GitHub Actions' own per-run workspace checkout (or, run locally,
# just this one operator's own checkout), so a fixed subdirectory name under
# it can never collide with another run. Docker objects are different: the
# daemon on a shared self-hosted runner host is one process serving every
# concurrent workflow run and every operator's local invocation, so object
# *names* need their own collision avoidance independent of the subnet. The
# octet alone is not enough for that (only 252 buckets, so two concurrent
# runs can still land on the same octet); appending this shell's own PID
# ($$) is what actually guarantees the docker network/container/image names
# themselves never collide, even when the subnet-derived octet does.
network_name="lancache-ng-dhcp448-${octet}-$$"
kea_container="lancache-ng-dhcp448-kea-${octet}-$$"
image_tag="lancache-ng-dhcp448-kea:${octet}-$$"
# dns_container/dns_image_tag (issue #706): the real PowerDNS container the
# DDNS verification section further below builds and queries. Named
# alongside the Kea names above for the same collision-avoidance reason.
dns_container="lancache-ng-dhcp448-dns-${octet}-$$"
dns_image_tag="lancache-ng-dhcp448-dns:${octet}-$$"

# services/dhcp/entrypoint.sh refuses to start Kea at all if KEA_CTRL_TOKEN
# or DDNS_TSIG_KEY is empty or one of its known placeholder defaults (it
# exists to catch a real deployment left on a default secret). This is a
# disposable, per-run test instance torn down at the end of this script, so
# there is no need to persist these values anywhere -- generating a fresh
# random one each run only has to satisfy that startup check and match what
# this script itself sends back to the Control Agent API below. ddns_tsig_key
# is shared, unmodified, with the PowerDNS container started further below
# (issue #706) -- the same shared secret both containers' entrypoints
# already validate independently in production, not a test-only shortcut.
# pdns_api_key is this run's disposable equivalent for the PowerDNS
# container's own required secret (services/dns/entrypoint.sh's
# PDNS_API_KEY check); nothing in this script's own DDNS verification uses
# the PowerDNS HTTP API, but the entrypoint refuses to start without it.
kea_ctrl_token="$(openssl rand -hex 32)"
ddns_tsig_key="$(openssl rand -base64 32 | tr -d '\n')"
pdns_api_key="$(openssl rand -hex 32)"

# `local status=$?` captures the script's real exit code before any cleanup
# command below can overwrite $? with its own (success or failure), so
# `exit "$status"` at the end still reports the original pass/fail result to
# the caller (e.g. GitHub Actions) instead of whatever the last cleanup
# command happened to return. The three docker teardown commands are also
# ordered deliberately, not just alphabetically: the network can't be
# removed while $kea_container is still attached to it, and the image can't
# be removed while $kea_container still exists and references it -- doing
# it in the reverse order would leave a dangling network or image behind on
# every run. Each is still `|| true` regardless, so a problem tearing down
# one of them never masks the script's real result or skips the others.
cleanup() {
    local status=$?
    docker rm -f "$kea_container" >/dev/null 2>&1 || true
    # dns_container/dns_image_tag (issue #706, the PowerDNS side of the DDNS
    # verification below) are torn down here too, for the same reason: the
    # network can't be removed while either container is still attached to
    # it, and dns_image_tag can't be removed while dns_container still
    # references it. Referencing these two variables is still safe even if
    # the script exits before they are assigned below (e.g. a failure while
    # building the Kea image) -- `docker rm -f ""`/`docker rmi ""` just fail
    # harmlessly and get swallowed by `|| true`, same as every other
    # teardown command here.
    docker rm -f "${dns_container:-}" >/dev/null 2>&1 || true
    docker network rm "$network_name" >/dev/null 2>&1 || true
    docker rmi "$image_tag" >/dev/null 2>&1 || true
    docker rmi "${dns_image_tag:-}" >/dev/null 2>&1 || true
    rm -rf "$work_dir"
    exit "$status"
}
trap cleanup EXIT

echo "== Building the Kea DHCP image from this checkout's services/dhcp =="
docker build -q -t "$image_tag" services/dhcp >/dev/null

echo "== Creating isolated bridge network $network_name ($subnet, no host interface involved) =="
# --ip-range confines Docker's OWN container-address bookkeeping to the
# first half of the subnet, so it can never overlap the Kea pool
# ($pool_start-$pool_end) that this script is actually testing.
docker network create \
    --driver bridge \
    --subnet "$subnet" \
    --gateway "$gateway" \
    --ip-range "172.31.${octet}.0/25" \
    "$network_name" >/dev/null

echo "== Building the PowerDNS image from this checkout's services/dns (issue #706) =="
docker build -q -t "$dns_image_tag" services/dns >/dev/null

echo "== Starting a real PowerDNS container on the isolated network (issue #706) =="
# No extra --cap-add here: unlike the Kea container below, services/dns/
# entrypoint.sh never touches iptables.
#
# DDNS_ALLOW_FROM=$kea_ip: kea-dhcp-ddns (started inside $kea_container
# below) sends its TSIG-signed nsupdate from that container's own network
# identity -- there is no separate D2 container in this project's
# architecture, matching production (services/dhcp runs kea-dhcp4,
# kea-ctrl-agent, and kea-dhcp-ddns as sibling processes in one container).
# PowerDNS's own allow-dnsupdate-from (services/dns/pdns.conf.template) must
# therefore allow exactly that source address, the same relationship
# config/*/dns-*.env's DDNS_ALLOW_FROM has to config/*/dhcp.env's container
# IP in every real deployment.
#
# DDNS_TSIG_KEY/(unset DDNS_TSIG_NAME/DDNS_TSIG_ALGORITHM, left at their
# services/dns/entrypoint.sh defaults of "lancache-ddns-key"/"hmac-sha256"):
# deliberately the exact same values services/dhcp/kea-dhcp-ddns.conf
# hardcodes for its own TSIG key name/algorithm, so this is the real
# production key exchange, not a test-only substitute.
#
# PROXY_IP is a required variable this entrypoint uses only to populate the
# unrelated CDN RPZ zone (see services/dns/entrypoint.sh's step 7); an
# RFC 5737 documentation address is used here since no real proxy exists in
# this throwaway network and nothing in the DDNS path below depends on it.
docker run -d --name "$dns_container" \
    --network "$network_name" --ip "$pdns_ip" \
    -e PROXY_IP="203.0.113.1" \
    -e PDNS_API_KEY="$pdns_api_key" \
    -e DDNS_ALLOW_FROM="$kea_ip" \
    -e DDNS_TSIG_KEY="$ddns_tsig_key" \
    "$dns_image_tag" >/dev/null

echo "== Waiting for PowerDNS to finish TSIG/zone setup and start serving (issue #706) =="
# Two conditions, not one: the log line confirms configure_ddns_tsig actually
# ran (TSIG key imported, TSIG-ALLOW-DNSUPDATE set on the LAN zones), and the
# dig probe confirms pdns_server itself is actually up and answering on its
# real listening address (127.0.0.1:5300 per services/dns/pdns.conf.template)
# -- the log line alone would not catch a case where TSIG setup succeeded but
# the authoritative server then failed to start (e.g. config validation
# rollback, see services/dns/entrypoint.sh's _dns_auth_validate_snapshot_or_rollback).
dns_ready_deadline=$((SECONDS + 60))
dns_ready=0
while (( SECONDS < dns_ready_deadline )); do
    if docker logs "$dns_container" 2>&1 | grep -q "Configured TSIG-authenticated DDNS updates for LAN zones." \
        && docker exec "$dns_container" dig +short +time=2 +tries=1 @127.0.0.1 -p 5300 lan. SOA >/dev/null 2>&1; then
        dns_ready=1
        break
    fi
    sleep 2
done
if [[ "$dns_ready" -ne 1 ]]; then
    echo "::error::PowerDNS container never finished TSIG/zone setup and became ready." >&2
    docker logs "$dns_container" >&2 || true
    exit 1
fi
echo "PowerDNS authoritative is up and TSIG-authenticated DDNS updates are configured for zone lan. (source: $kea_ip)."

echo "== Creating this run's forward test zone in PowerDNS (issue #706) =="
# services/dns/entrypoint.sh only ever creates its own fixed LAN_ZONES (lan.,
# local.lan.) -- every shipped config (config/{dev,prod}/dhcp.env) always
# sets DHCP_DOMAIN=lan, exactly matching the "lan." zone, so this gap never
# surfaces in a real deployment. This script deliberately uses a
# distinctive, run-unique $dhcp_test_domain instead of "lan" (see its
# definition above for why), which does NOT correspond to any zone
# PowerDNS actually serves -- a DDNS update's on-wire "zone" field is
# whatever kea-dhcp-ddns.conf's forward-ddns "name" is configured to
# (literally $dhcp_test_domain here), and PowerDNS rejects updates
# targeting a zone it has no SOA for ("Can't determine backend for
# domain"), confirmed empirically. This grants exactly what
# configure_ddns_tsig() already grants the real LAN zones -- create-zone,
# then the same TSIG-ALLOW-DNSUPDATE metadata key -- for this one
# additional test-only zone, so the DDNS verification below exercises a
# real accept path instead of a zone-name mismatch this script introduced
# for itself.
docker exec "$dns_container" pdnsutil --config-dir=/etc/pdns/auth create-zone "${dhcp_test_domain}." >/dev/null
docker exec "$dns_container" pdnsutil --config-dir=/etc/pdns/auth set-meta "${dhcp_test_domain}." TSIG-ALLOW-DNSUPDATE lancache-ddns-key >/dev/null
# pdns_control rediscover (confirmed empirically, issue #706): pdnsutil
# creates this zone through its own short-lived DB connection, separate
# from the already-running pdns_server process -- without this, the first
# query against the new zone (the DDNS verification polling loop below,
# whose first attempt normally lands *before* kea-dhcp-ddns's async update
# completes and is expected to see NXDOMAIN at that point) gets answered
# using the still-stale "lan." zone instead of the new one, and that wrong
# NXDOMAIN then sits in PowerDNS's own packet cache for its full negative-
# TTL (the "lan." zone's SOA minimum, 3600s) -- long enough to make every
# later poll in this same run see the same stale wrong answer even after
# the real record exists. Forcing pdns_server to pick up the new zone here,
# before anything ever queries it, avoids the race entirely.
docker exec "$dns_container" pdns_control rediscover >/dev/null

echo "== Starting a real Kea container on the isolated network =="
# --cap-add NET_ADMIN: services/dhcp/entrypoint.sh runs iptables on every
# start to restrict the Control Agent API to Docker-internal networks (see
# that file's own comment). Without NET_ADMIN those iptables calls fail and
# the entrypoint would not behave the same way it does in a real deployment.
docker run -d --name "$kea_container" \
    --network "$network_name" --ip "$kea_ip" \
    --cap-add NET_ADMIN \
    -e DHCP_SUBNET="$subnet" \
    -e DHCP_RANGE_START="$pool_start" \
    -e DHCP_RANGE_END="$pool_end" \
    -e DHCP_GATEWAY="$gateway" \
    -e DHCP_DOMAIN="$dhcp_test_domain" \
    -e DHCP_LEASE_TIME=3600 \
    -e DHCP_NTP_SERVERS="8.8.8.8 1.1.1.1" \
    -e DHCP_DNS_PRIMARY="$kea_ip" \
    -e DHCP_DNS_SECONDARY="$kea_ip" \
    -e KEA_CTRL_TOKEN="$kea_ctrl_token" \
    -e DDNS_TSIG_KEY="$ddns_tsig_key" \
    -e DHCP_DNS_SERVER_IP="$pdns_ip" \
    "$image_tag" >/dev/null

echo "== Waiting for the Kea Control Agent API to answer =="
# config-get is used purely as the readiness probe because it is a
# read-only Kea command: it cannot change anything Kea already loaded from
# its own config file, so polling it repeatedly here has no side effects on
# the DHCPv4 configuration this script later relies on being untouched.
deadline=$((SECONDS + 60))
kea_ready=0
while (( SECONDS < deadline )); do
    if docker exec "$kea_container" sh -c '
        curl -sf -u "admin:$1" -H "Content-Type: application/json" \
            -d "{\"command\":\"config-get\",\"service\":[\"dhcp4\"]}" \
            "http://127.0.0.1:8000/" | jq -e ".[0].result == 0" >/dev/null
    ' -- "$kea_ctrl_token" 2>/dev/null; then
        kea_ready=1
        break
    fi
    sleep 2
done
if [[ "$kea_ready" -ne 1 ]]; then
    echo "::error::Kea Control Agent API never became ready." >&2
    docker logs "$kea_container" >&2 || true
    exit 1
fi
echo "Kea DHCPv4 server is up (Subnet: $subnet, Pool: $pool_start - $pool_end)."

echo "== Running a real DHCP client (dhclient) against Kea: Discover/Offer/Request/Ack =="
# -sf /bin/true: negotiate a real lease over the wire but never apply it to
# this container's own interface (see the safety-model comment above).
# dhclient does not reliably exit on its own after -1 on every distro build
# once bound (confirmed directly during development of this script) so this
# polls for the lease file instead of trusting dhclient's own exit code, and
# force-kills it once a lease has actually been written.
client_container="lancache-ng-dhcp448-client-${octet}-$$"

# No custom -cf/dhclient.conf here (issue #706) -- deliberately, after an
# earlier version of this section that added one regressed the pre-existing
# NTP-servers assertion below (a custom -cf file entirely replaces
# dhclient's system default /etc/dhcp/dhclient.conf, including its
# `request ... ntp-servers;` line, so a minimal custom file that only
# `send`s a hostname silently stops requesting NTP servers at all) without
# even achieving its own goal: Debian's default dhclient.conf already sends
# `host-name = gethostname()` (the container's own Docker-assigned
# hostname) on every run, with or without a custom -cf, and Kea's own
# ddns-replace-client-name default, "when-present" (services/dhcp/
# entrypoint.sh's migrate_dhcp4_config), does NOT mean "use the client's
# name when present" -- verified empirically against a real Kea 2.6.3 D2
# instance -- it means the opposite: Kea REPLACES whatever hostname the
# client sent with its own ddns-generated-prefix-based name (confirmed:
# Kea's own DHCPOFFER/DHCPACK echo back Option 12 as
# "dhcp-<dashed-ip>.<domain>", not the client-sent value) precisely because
# a name WAS present to trigger the replacement. So the DDNS record Kea
# will actually create is deterministic from the offered address alone,
# with no client-side cooperation needed at all -- see
# assert_ddns_record_matches_lease's caller below.
#
# NET_RAW: before a lease is granted this container has no IP of its own,
# so dhclient must send/receive DHCP over a raw broadcast socket rather than
# a normal bound UDP socket -- that needs CAP_NET_RAW regardless of -sf's
# no-op lease-apply step. NET_ADMIN is added alongside it because dhclient
# also touches interface-level state (e.g. ARP) while negotiating, before
# it ever gets to the point of calling -sf.
docker run -d --name "$client_container" \
    --network "$network_name" \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    -v "$work_dir/client-state:/dhcp-test" \
    "$client_tool_image" \
    bash -c 'dhclient -4 -1 -v -d -sf /bin/true -pf /dhcp-test/dhclient.pid -lf /dhcp-test/dhclient.leases eth0 >/dhcp-test/dhclient.out 2>&1; echo DONE >> /dhcp-test/dhclient.out' \
    >/dev/null

# lease_timeout_seconds is kept separate from lease_deadline (an absolute
# SECONDS-based cutoff) so the error message below can report the actual
# wait duration instead of a shifting absolute value -- $lease_deadline
# itself is meaningless to a reader, since $SECONDS keeps advancing for the
# rest of the script's own runtime.
lease_timeout_seconds=30
lease_deadline=$((SECONDS + lease_timeout_seconds))
lease_obtained=0
while (( SECONDS < lease_deadline )); do
    # `-s` alone is not enough: the lease file appears the moment dhclient
    # starts writing it, well before the record is complete. The trailing
    # `^}` (a closing brace at column 0) is what ISC dhclient writes only
    # once a lease record is fully committed to the file, so checking for it
    # is what actually distinguishes "lease negotiation still in progress,
    # file exists but is partially written" from "lease obtained and safe to
    # parse" -- reading the file one poll iteration too early would hand
    # dhcp_lease_parse_latest below a truncated record.
    if [[ -s "$work_dir/client-state/dhclient.leases" ]] && grep -q '^}' "$work_dir/client-state/dhclient.leases" 2>/dev/null; then
        lease_obtained=1
        break
    fi
    sleep 1
done

docker rm -f "$client_container" >/dev/null 2>&1 || true

echo "::group::Raw dhclient output"
cat "$work_dir/client-state/dhclient.out" 2>/dev/null || echo "(no client output captured)"
echo "::endgroup::"

if [[ "$lease_obtained" -ne 1 ]]; then
    echo "::error::dhclient never obtained a lease from the Kea container within ${lease_timeout_seconds}s." >&2
    docker logs "$kea_container" >&2 || true
    exit 1
fi

parsed="$(dhcp_lease_parse_latest "$work_dir/client-state/dhclient.leases")" || {
    echo "::error::A lease file was written but could not be parsed." >&2
    exit 1
}

offered_address="$(dhcp_lease_field "$parsed" address || true)"
server_identifier="$(dhcp_lease_field "$parsed" server_identifier || true)"
router="$(dhcp_lease_field "$parsed" router || true)"
dns_servers="$(dhcp_lease_field "$parsed" dns_servers || true)"
ntp_servers="$(dhcp_lease_field "$parsed" ntp_servers || true)"
lease_time="$(dhcp_lease_field "$parsed" lease_time || true)"
domain_name="$(dhcp_lease_field "$parsed" domain_name || true)"

echo "== Verifying the granted lease matches the configured Kea subnet =="

# Address-in-pool check done in Python (not bash arithmetic) for the same
# reason build-push.yml's own subnet-collision check uses it: correct,
# readable IPv4 range comparison without hand-rolled octet math.
address_in_pool="$(python3 - "$offered_address" "$pool_start" "$pool_end" <<'PYEOF'
import ipaddress, sys
addr, start, end = (ipaddress.ip_address(a) for a in sys.argv[1:4])
print("yes" if start <= addr <= end else "no")
PYEOF
)"

fail=0
if [[ "$address_in_pool" != "yes" ]]; then
    echo "::error::Offered address $offered_address is outside the configured pool ($pool_start - $pool_end)." >&2
    fail=1
fi
if [[ "$server_identifier" != "$kea_ip" ]]; then
    echo "::error::Server identifier '$server_identifier' does not match the Kea container's own IP ($kea_ip)." >&2
    fail=1
fi
if [[ "$router" != "$gateway" ]]; then
    echo "::error::Router option '$router' does not match the configured gateway ($gateway)." >&2
    fail=1
fi
if [[ "$dns_servers" != "$kea_ip,$kea_ip" ]]; then
    echo "::error::DNS servers option '$dns_servers' does not match the configured DHCP_DNS_PRIMARY/SECONDARY ($kea_ip,$kea_ip)." >&2
    fail=1
fi
if [[ "$ntp_servers" != "8.8.8.8,1.1.1.1" ]]; then
    echo "::error::NTP servers option '$ntp_servers' does not match the configured DHCP_NTP_SERVERS (8.8.8.8,1.1.1.1)." >&2
    fail=1
fi
if [[ "$lease_time" != "3600" ]]; then
    echo "::error::Lease time option '$lease_time' does not match the configured DHCP_LEASE_TIME (3600)." >&2
    fail=1
fi
if [[ "$domain_name" != "$dhcp_test_domain" ]]; then
    echo "::error::Domain name option '$domain_name' does not match the configured DHCP_DOMAIN ($dhcp_test_domain)." >&2
    fail=1
fi

echo "== Verifying Kea's DDNS update produced a matching PowerDNS A record (issue #706) =="

# assert_ddns_record_matches_lease <fqdn> <expected_ip>
# Queries the real PowerDNS authoritative server ($dns_container, started
# above) directly on its actual listening address (127.0.0.1:5300 inside
# that container, per services/dns/pdns.conf.template) for <fqdn>'s A
# record, and checks it equals <expected_ip>. Kea's kea-dhcp-ddns daemon
# (running inside $kea_container, driven by the real lease dhclient just
# obtained above) is the only thing that can have created this record: DDNS
# is asynchronous (kea-dhcp-ddns processes its NCR queue and sends the
# TSIG-signed nsupdate after the DHCPACK has already gone out to the
# client), so the record is not guaranteed to exist the instant dhclient's
# lease file appeared -- this polls rather than checking once.
assert_ddns_record_matches_lease() {
    local fqdn="$1" expected_ip="$2" resolved_ip=""
    local ddns_deadline=$((SECONDS + 30))
    while (( SECONDS < ddns_deadline )); do
        resolved_ip="$(docker exec "$dns_container" dig +short +time=2 +tries=1 @127.0.0.1 -p 5300 "$fqdn" A 2>/dev/null | tail -n1)"
        if [[ "$resolved_ip" == "$expected_ip" ]]; then
            echo "DDNS verification passed: PowerDNS authoritative has an A record for $fqdn -> $resolved_ip, matching the lease Kea just granted."
            return 0
        fi
        sleep 2
    done
    echo "::error::PowerDNS authoritative never produced an A record for '$fqdn' matching the leased address ($expected_ip); last resolved value: '${resolved_ip:-<none>}'." >&2
    echo "::group::kea-dhcp-ddns / PowerDNS container logs" >&2
    docker logs "$kea_container" >&2 2>&1 || true
    docker logs "$dns_container" >&2 2>&1 || true
    echo "::endgroup::" >&2
    return 1
}

# ddns_expected_fqdn is NOT the client's own hostname (see the dhclient
# invocation's comment above for why): it is Kea's own auto-generated name
# for this lease, "<ddns-generated-prefix>-<dashed-ip>.<ddns-qualifying-
# suffix>." -- ddns-generated-prefix is hardcoded "dhcp" (services/dhcp/
# entrypoint.sh's migrate_dhcp4_config), confirmed live against a real Kea
# 2.6.3 instance to be exactly what it substitutes whenever
# ddns-replace-client-name is "when-present" (the project default) and the
# client sent any hostname at all -- which every dhclient does by default
# (send host-name = gethostname()). $domain_name is not hardcoded a second
# time here -- it is the exact domain-name option value already parsed from
# the granted lease above (confirmed by the assertion just before this
# section), which is the same value Kea's ddns-qualifying-suffix was
# configured to (DHCP_DOMAIN).
ddns_expected_fqdn="dhcp-${offered_address//./-}.${domain_name}."
ddns_status="FAILED (see ::error above)"
if assert_ddns_record_matches_lease "$ddns_expected_fqdn" "$offered_address"; then
    ddns_status="verified: ${ddns_expected_fqdn} -> ${offered_address} (TSIG-signed nsupdate from kea-dhcp-ddns)"
else
    fail=1
fi

# ─── Static host reservation scenario (issue #707) ───
#
# Appended as its own self-contained step rather than interleaved into the
# base scenario above, on purpose: issue #706 (DHCP-DDNS follow-through) is
# being added to this same script independently and in parallel, and keeping
# each new scenario as an isolated block minimizes merge conflicts between
# the two.
#
# Two fixed, locally-administered (0x02 high nibble, never a real vendor
# OUI) test MACs -- one that gets the reservation, one that deliberately does
# not. Both incorporate this shell's own PID so concurrent local runs of
# this script never collide on the same MAC, mirroring the run-identity
# uniqueness already used for $network_name/$kea_container above. Their
# fourth/fifth octets are fixed and distinct from each other so the two MACs
# themselves can never collide even if $$ happens to match across runs.
reserved_mac="$(printf '02:07:07:aa:bb:%02x' "$(( $$ % 256 ))")"
other_mac="$(printf '02:07:07:cc:dd:%02x' "$(( $$ % 256 ))")"
# Deliberately outside both the dynamic pool ($pool_start-$pool_end, the
# second half of the /24) and Docker's own --ip-range for this network
# (172.31.${octet}.0/25, the first half) -- the whole point of a static
# reservation is that Kea must hand out this exact address even though
# ordinary dynamic allocation never would, and it must never collide with
# Docker's own container-address bookkeeping either.
reserved_ip="172.31.${octet}.210"

# kea_ctrl_command <json_command_body>
# POSTs a raw, already-valid Kea Control Agent JSON command body (read from
# stdin, via -d @-, rather than interpolated into a shell string) to the real
# Control Agent inside $kea_container, printing its raw JSON response on
# stdout. Kept as a single thin transport primitive -- reading/writing the
# JSON itself is done with python3 on the host below (already a dependency
# of this script, see the address-in-pool check above), not jq inside the
# container, specifically to avoid nesting a jq filter's own double-quoted
# JSON keys inside this function's already single-quoted `sh -c` string,
# which is exactly the unreadable, error-prone quoting-inside-quoting this
# function exists to sidestep.
kea_ctrl_command() {
    docker exec -i "$kea_container" sh -c '
        curl -sf -u "admin:$1" -H "Content-Type: application/json" -d @- "http://127.0.0.1:8000/"
    ' -- "$kea_ctrl_token" <<<"$1"
}

# kea_ctrl_result_ok <response_json>
# True (exit 0) if a Kea Control Agent response's top-level result code is 0
# (success). Kea's own convention, matching kea_result() in
# services/ui/src/routes/dhcp.rs.
kea_ctrl_result_ok() {
    python3 -c '
import json, sys
d = json.loads(sys.argv[1])
sys.exit(0 if d and d[0].get("result") == 0 else 1)
' "$1"
}

# kea_ctrl_add_reservation <mac> <ip>
# Adds a real static host reservation for <mac> -> <ip> directly through
# Kea's own Control Agent API, driving the exact config-get (strip "hash")
# -> config-test -> config-set -> config-write sequence
# services/ui/src/routes/dhcp.rs's kea_config_modify() uses for the Admin
# UI's /dhcp/static/add route (see that file's own comment on why "hash"
# must be stripped: Kea 2.6.3's config-get response embeds a server-computed
# digest that config-test/config-set reject outright if fed straight back) --
# just called here directly against the Control Agent instead of through the
# Admin UI HTTP layer. Kea's compiled-in global host-reservation-identifiers
# default already includes "hw-address" (services/dhcp/kea-dhcp4.conf sets no
# override, and issue #693 removed the subnet-scope write that used to break
# this), so no extra identifiers config is needed here for the reservation to
# actually match on subsequent lease requests.
kea_ctrl_add_reservation() {
    local mac="$1" ip="$2" get_resp modified_args resp

    get_resp="$(kea_ctrl_command '{"command":"config-get","service":["dhcp4"]}')"
    if ! kea_ctrl_result_ok "$get_resp"; then
        echo "config-get failed: $get_resp" >&2
        return 1
    fi

    modified_args="$(GET_RESP="$get_resp" python3 - "$mac" "$ip" <<'PYEOF'
import json, os, sys
mac, ip = sys.argv[1], sys.argv[2]
resp = json.loads(os.environ["GET_RESP"])
args = resp[0]["arguments"]
args.pop("hash", None)  # see kea_ctrl_add_reservation's own comment above
for subnet in args["Dhcp4"]["subnet4"]:
    if subnet.get("id") == 1:
        subnet.setdefault("reservations", []).append({"hw-address": mac, "ip-address": ip})
print(json.dumps(args))
PYEOF
    )"

    for cmd in config-test config-set; do
        resp="$(kea_ctrl_command "{\"command\":\"$cmd\",\"service\":[\"dhcp4\"],\"arguments\":${modified_args}}")"
        if ! kea_ctrl_result_ok "$resp"; then
            echo "$cmd failed: $resp" >&2
            return 1
        fi
    done

    resp="$(kea_ctrl_command '{"command":"config-write","service":["dhcp4"]}')"
    if ! kea_ctrl_result_ok "$resp"; then
        echo "config-write failed: $resp" >&2
        return 1
    fi
}

# kea_ctrl_reservation_present <mac> <ip>
# Prints "yes"/"no": whether Kea's OWN config-get (not this script's local
# copy of the config it sent) currently shows a reservation matching <mac>
# and <ip> -- the same "ideally reflected in a follow-up config-get"
# assertion issue #634's Control Agent mutation test makes for the Admin-UI
# route, done here directly against the Control Agent instead.
kea_ctrl_reservation_present() {
    local mac="$1" ip="$2" get_resp
    get_resp="$(kea_ctrl_command '{"command":"config-get","service":["dhcp4"]}')"
    MAC="$mac" IP="$ip" python3 -c '
import json, os, sys
resp = json.loads(sys.argv[1])
mac, ip = os.environ["MAC"].lower(), os.environ["IP"]
subnets = resp[0]["arguments"]["Dhcp4"]["subnet4"]
found = any(
    r.get("hw-address", "").lower() == mac and r.get("ip-address") == ip
    for s in subnets
    for r in s.get("reservations", [])
)
print("yes" if found else "no")
' "$get_resp"
}

# assert_static_reservation_honored <label> <mac> <state_subdir>
# Runs one fresh, one-shot dhclient container for <mac> (a distinct
# --mac-address per call, unlike the base scenario's client above which
# relies on Docker's own auto-assigned MAC) and prints the offered IPv4
# address, using the identical -sf /bin/true no-op-lease-apply / poll-for-
# "^}" / force-kill technique as the base scenario above -- see that
# section's own comments for why each of those choices is safe and
# necessary. Kept as its own function (not inlined) so it can be called once
# for the reserved MAC and once for the unrelated MAC below without
# duplicating this logic.
assert_static_reservation_honored() {
    local label="$1" mac="$2" state_subdir="$3" client_container
    client_container="lancache-ng-dhcp448-client-${state_subdir}-${octet}-$$"
    mkdir -p "$work_dir/$state_subdir"
    chmod 0777 "$work_dir/$state_subdir"

    docker run -d --name "$client_container" \
        --network "$network_name" --mac-address "$mac" \
        --cap-add NET_ADMIN --cap-add NET_RAW \
        -v "$work_dir/$state_subdir:/dhcp-test" \
        "$client_tool_image" \
        bash -c 'dhclient -4 -1 -v -d -sf /bin/true -pf /dhcp-test/dhclient.pid -lf /dhcp-test/dhclient.leases eth0 >/dhcp-test/dhclient.out 2>&1; echo DONE >> /dhcp-test/dhclient.out' \
        >/dev/null

    local deadline=$((SECONDS + 30)) obtained=0
    while (( SECONDS < deadline )); do
        if [[ -s "$work_dir/$state_subdir/dhclient.leases" ]] && grep -q '^}' "$work_dir/$state_subdir/dhclient.leases" 2>/dev/null; then
            obtained=1
            break
        fi
        sleep 1
    done
    docker rm -f "$client_container" >/dev/null 2>&1 || true

    # Diagnostics go to stderr, not stdout: this function's stdout is
    # captured via command substitution by every caller below (the offered
    # address is the only thing that must appear there).
    {
        echo "::group::$label: raw dhclient output"
        cat "$work_dir/$state_subdir/dhclient.out" 2>/dev/null || echo "(no client output captured)"
        echo "::endgroup::"
    } >&2

    if [[ "$obtained" -ne 1 ]]; then
        echo "::error::$label: dhclient never obtained a lease for $mac within 30s." >&2
        return 1
    fi

    local parsed
    parsed="$(dhcp_lease_parse_latest "$work_dir/$state_subdir/dhclient.leases")" || {
        echo "::error::$label: a lease file was written but could not be parsed." >&2
        return 1
    }
    dhcp_lease_field "$parsed" address || true
}

echo "== Adding a real static host reservation ($reserved_mac -> $reserved_ip) via Kea's Control Agent API =="
if ! kea_ctrl_add_reservation "$reserved_mac" "$reserved_ip"; then
    echo "::error::Failed to add the static reservation directly through Kea's Control Agent API." >&2
    docker logs "$kea_container" >&2 || true
    exit 1
fi

reservation_present="$(kea_ctrl_reservation_present "$reserved_mac" "$reserved_ip")"
if [[ "$reservation_present" != "yes" ]]; then
    echo "::error::Kea's own config-get does not show the reservation that was just added ($reserved_mac -> $reserved_ip)." >&2
    exit 1
fi
echo "Kea's live config-get confirms the reservation ($reserved_mac -> $reserved_ip) is present."

echo "== Positive case: requesting a lease for the reserved MAC -- must receive the reserved address =="
reserved_offered="$(assert_static_reservation_honored "reserved-mac" "$reserved_mac" "client-state-reserved")" || {
    docker logs "$kea_container" >&2 || true
    exit 1
}
reservation_honored=0
if [[ "$reserved_offered" == "$reserved_ip" ]]; then
    reservation_honored=1
    echo "Confirmed: a real DHCP request for the reserved MAC $reserved_mac received the reserved address $reserved_ip."
else
    echo "::error::Reserved MAC $reserved_mac received '${reserved_offered:-<none>}', expected the reserved address $reserved_ip." >&2
    fail=1
fi

echo "== Negative case: requesting a lease for an unrelated MAC -- must NOT receive the reserved address =="
other_offered="$(assert_static_reservation_honored "other-mac" "$other_mac" "client-state-other")" || {
    docker logs "$kea_container" >&2 || true
    exit 1
}
other_in_pool="$(python3 - "$other_offered" "$pool_start" "$pool_end" <<'PYEOF'
import ipaddress, sys
addr, start, end = (ipaddress.ip_address(a) for a in sys.argv[1:4])
print("yes" if start <= addr <= end else "no")
PYEOF
)"
reservation_isolated=0
if [[ "$other_offered" != "$reserved_ip" && "$other_in_pool" == "yes" ]]; then
    reservation_isolated=1
    echo "Confirmed: a real DHCP request for the unrelated MAC $other_mac received an ordinary dynamic-pool address ($other_offered), not the reservation."
elif [[ "$other_offered" == "$reserved_ip" ]]; then
    echo "::error::Unrelated MAC $other_mac was also handed the reserved address $reserved_ip -- the reservation leaked to a client it does not belong to." >&2
    fail=1
else
    echo "::error::Unrelated MAC $other_mac received '${other_offered:-<none>}', which is outside the dynamic pool ($pool_start - $pool_end)." >&2
    fail=1
fi

report=$(cat <<REPORT
== DHCP Kea lease-flow result (issue #448) ==
Offered address:      ${offered_address:-<none>}
Server identifier:    ${server_identifier:-<none>}
Router:               ${router:-<none>}
DNS servers:          ${dns_servers:-<none>}
NTP servers:          ${ntp_servers:-<none>}
Lease time (s):       ${lease_time:-<none>}
Domain name:          ${domain_name:-<none>}
DDNS A record:        ${ddns_status}

== Static host reservation result (issue #707) ==
Reserved MAC:          ${reserved_mac} -> ${reserved_ip}
Reserved-MAC lease:    ${reserved_offered:-<none>} $( [[ "$reservation_honored" -eq 1 ]] && echo "(reserved address received -- honored)" || echo "(MISMATCH)" )
Unrelated MAC:         ${other_mac}
Unrelated-MAC lease:   ${other_offered:-<none>} $( [[ "$reservation_isolated" -eq 1 ]] && echo "(ordinary pool address -- reservation did not leak)" || echo "(MISMATCH)" )

Verified: a real Discover/Offer/Request/Ack flow completed against our own
Kea service on an isolated Docker bridge network, and the address/server-
identifier/router/DNS/NTP/lease-time/domain-name options above matched what
this run configured Kea with. Also verified: a static host reservation added
directly through Kea's own Control Agent API (the same config-get/
config-test/config-set/config-write sequence the Admin UI's
kea_config_modify() drives) was honored by a real, subsequent DHCP lease
request for the reserved MAC, and a second, unrelated MAC still received an
ordinary dynamic-pool address rather than the reservation. Also verified:
the granted lease produced a matching PowerDNS A record via a real
TSIG-authenticated DDNS update from kea-dhcp-ddns to a real PowerDNS
authoritative server, using this project's real DDNS transport/config
wiring (see the header comment above for the one test-only zone-bootstrap
shim this run needed and why).

NOT verified by this script (see header comment / docs/dhcp-modes.md):
reverse (PTR) DDNS updates (confirmed BROKEN in production -- see the header
comment and issue #768), and the dnsmasq-proxy DHCP mode (out of scope here).
REPORT
)
echo "$report"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo '```text'
        echo "$report"
        echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
fi

if [[ "$fail" -ne 0 ]]; then
    echo "::error::dhcp-kea-lease-flow-simulation FAILED: one or more offered options or the static reservation scenario did not match expectations." >&2
    exit 1
fi

echo "dhcp-kea-lease-flow-simulation passed: real lease flow, static reservation (positive case), and reservation isolation (negative case) all completed and matched expectations."
