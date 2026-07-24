#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Host-local, per-slot locking for the full-setup-validate validation
# Docker subnet (issue #703; slot/`/27` redesign issue #832). Pure functions
# plus small side-effecting helpers, no top-level executable code, so this
# can be sourced directly both by .github/workflows/full-setup-validate.yml's
# own "Reserve a validation subnet and start the stack" step and by
# tests/bats/reserve_validation_subnet.bats (fast, Docker-free unit coverage
# of the derivation and lock-contention logic).
#
# Background: .github/actions/derive-validation-network (#623) derives a
# subnet from a hash of the run id/attempt, which makes same-subnet
# collisions between two different, genuinely concurrent workflow runs on
# the same self-hosted host RARE but not impossible -- pure hashing has no
# coordination between runs at all. #703's own linked run confirmed this for
# real: two concurrent runs derived the same octet, both passed the old
# `docker network ls`-based pre-flight check (which only catches a leftover
# Docker network from a previous run, not another run mid-way through its
# own check-then-create window), and only one of them won the kernel race to
# actually create the bridge.
#
# This closes that gap with the same host-local `flock` idiom already used
# elsewhere in this project for a shared-per-host resource
# (build-tools.yml/build-push.yml's own Buildx cache lock): before a run is
# allowed to touch Docker at all, it must hold an exclusive, non-blocking
# flock on a well-known per-slot path. flock's lock is tied to an open file
# descriptor, not to a marker file's mere existence, so a crashed or
# cancelled run can never leave a stale lock behind -- the kernel releases
# it the instant the holding process dies, whatever kills it (an explicit
# release, or the runner tearing down the whole job's process tree on
# cancellation).
#
# #832 REDESIGN (2026-07-16): the pool used to be exactly one `/24` per
# third octet of 172.30.0.0/16 (252 usable slots, ~9 addresses of each `/24`
# of 256 actually used) -- a small pool that was the direct, root cause of
# the birthday-paradox collision frequency issue #820/#821's flock+retry
# mechanism exists to route around. Each reservation now claims a `/27`
# (30 usable hosts, comfortably more than the ~9-10 the validation stack
# actually assigns, with headroom for the stack growing a few more services)
# and the pool is widened from "one `/24` slot per octet" to "eight `/27`
# slots per octet" within the SAME already-owned 172.30.0.0/16 -- ~2,000
# slots instead of 252, an ~8x increase, with NO change to the /16 this
# project draws from. Deliberately NOT widened to the full private
# 172.16.0.0/12 block (the issue's own "Option B"): that whole range,
# 172.17.0.0/16-172.31.0.0/16, is ALSO exactly Docker's own default
# address-pool range for any OTHER, unrelated bridge network created on the
# same runner host without an explicit subnet -- this project already hit a
# real bug from relying on that exact range once (CHANGELOG's #654 entry,
# PowerDNS's `webserver-allow-from` only covering Docker's default pools).
# Widening into it would trade a self-inflicted small pool for a new,
# harder-to-diagnose collision surface shared with tooling this project
# does not control. Staying inside 172.30.0.0/16 avoids that risk entirely
# while still solving the actual root cause (pool size), since 2,000 slots
# already leaves enormous headroom over any realistic number of concurrent
# runs on one host.
#
# The externally-visible reservation unit is now called a "slot" rather
# than an "octet": it is `real_octet * 8 + subblock` (0..7 selecting which
# of the 8 possible `/27` blocks within that octet's `/24`), so it is no
# longer a valid single IP octet by itself (values run up to ~2031) --
# validation_subnet_export_env is the one place that decomposes it back
# into real IP octets.

# validation_subnet_derive_octet <raw_seed>
# Prints the third octet (2..253, excluding 28 and 99) of a
# 172.30.<octet>.0/24-shaped candidate, deterministically derived from
# <raw_seed>. Hashing rather than using the seed mod N directly: nothing
# guarantees the seed's low-order digits are evenly distributed, and
# back-to-back runs (the common case: consecutive pushes/PRs) hashing on raw
# low bits could cluster near each other instead of spreading across the
# available range.
#
# UNCHANGED by the #832 `/27` redesign, deliberately: this function (and
# validation_subnet_reserve/validation_subnet_try_lock/
# validation_subnet_release, which it's built on) is also reused, as a
# generic "reserve one free integer with host-local flock" primitive, by two
# entirely independent consumers on their OWN separate /16 ranges --
# scripts/dhcp-kea-lease-flow-simulation.sh (172.31.0.0/16) and
# scripts/dhcp-proxy-pxe-simulation.sh (172.29.0.0/16) -- neither of which
# has (or wants) a `/27` subdivision; both still want a single, whole `/24`
# per octet, exactly as before. A first version of this redesign renamed
# this function's output to "slot" and changed what it locked/derived,
# which silently broke both of those unrelated consumers (they kept parsing
# `sed -n 's/^octet=//p'` on validation_subnet_reserve's output, which no
# longer existed) -- confirmed for real via a genuine CI run: both scripts'
# `candidate_octet` came back empty, producing the literal, invalid
# subnet string "172.31..0/24"/"172.29..0/24". Fixed by keeping THIS
# function and validation_subnet_reserve exactly as they always were, and
# adding SEPARATE validation_subnet_derive_slot/validation_subnet_reserve_slot
# functions (below) for the NEW `/27`-per-slot callers instead of repurposing
# the existing octet-only ones.
validation_subnet_derive_octet() {
    local raw_seed="$1"
    local digest decimal octet

    digest="$(printf '%s' "$raw_seed" | sha256sum | cut -c1-8)"
    decimal=$((16#$digest))

    # Reserve the third octet of 172.30.0.0/16 as the per-run pool. 0 and 1
    # are excluded outright; 28 was `deploy/dev`'s docker-compose subnet
    # (172.28.0.0/16) before that environment was retired in v0.3.0 (#766) --
    # kept excluded as a harmless residual precaution against a leftover
    # Docker network from an older checkout still using that third octet;
    # 99 was the old fixed value, kept excluded so a derived pool stays
    # visibly distinct from the previous hardcoded default.
    octet=$(( (decimal % 252) + 2 )) # 2..253
    case "$octet" in
        28|99) octet=$(( octet + 100 )) ;;
    esac

    printf '%s\n' "$octet"
}

# validation_subnet_derive_subblock <raw_seed>
# Prints a value 0..7, deterministically derived from <raw_seed>, selecting
# which of 8 possible `/27` blocks within an octet's `/24` a NEW-style
# (#832) reservation gets. Uses a DIFFERENT slice of the same seed's digest
# than validation_subnet_derive_octet (not the same bits reused, and not an
# independent hash) so the two dimensions don't correlate with each other
# while both stay reproducible from one seed.
validation_subnet_derive_subblock() {
    local raw_seed="$1"
    local digest2 decimal2

    digest2="$(printf '%s' "$raw_seed" | sha256sum | cut -c9-16)"
    decimal2=$((16#$digest2))

    printf '%s\n' "$(( decimal2 % 8 ))"
}

# validation_subnet_derive_slot <raw_seed>
# Prints a combined slot index for the #832 `/27` pool: `slot = octet * 8 +
# subblock` (octet from validation_subnet_derive_octet, subblock from
# validation_subnet_derive_subblock), identifying one `/27` candidate
# subnet within 172.30.0.0/16 (172.30.<octet>.<subblock*32>/27). Used ONLY
# by validation_subnet_reserve_slot and its callers (the general
# 172.30.0.0/16 validation-stack pool) -- NOT by validation_subnet_reserve
# or the two DHCP simulation scripts, which still want a plain octet (see
# validation_subnet_derive_octet's own comment for why).
validation_subnet_derive_slot() {
    local raw_seed="$1"
    local octet subblock

    octet="$(validation_subnet_derive_octet "$raw_seed")"
    subblock="$(validation_subnet_derive_subblock "$raw_seed")"

    printf '%s\n' "$(( octet * 8 + subblock ))"
}

# validation_subnet_seed_for_attempt <run_id> <run_attempt> <attempt_number>
# Prints the hash seed for the given retry attempt. attempt_number 1 uses
# the exact same seed .github/actions/derive-validation-network's own
# formula does (<run_id>-<run_attempt>, no extra suffix), so the common,
# uncontested case -- the overwhelming majority of runs, which never hit a
# lock or a real Docker collision -- derives the IDENTICAL slot that action
# already independently computes for the compose-project-name/UI-port
# outputs it exposes to this workflow's other jobs. Only a genuine retry
# (attempt_number > 1) salts the seed, so it can never re-derive the very
# candidate that was just found to be locked or in use.
validation_subnet_seed_for_attempt() {
    local run_id="$1" run_attempt="$2" attempt_number="$3"

    if [[ "$attempt_number" -eq 1 ]]; then
        printf '%s-%s\n' "$run_id" "$run_attempt"
    else
        printf '%s-%s-retry%s\n' "$run_id" "$run_attempt" "$attempt_number"
    fi
}

# validation_subnet_try_lock <lock_root> <id>
# Attempts to atomically claim <id> by holding a non-blocking exclusive
# flock on "<lock_root>/<id>.lock" for as long as the returned holder
# process stays alive. On success, prints the holder PID on stdout and
# returns 0; on failure (another process already holds this id's lock),
# prints nothing and returns 1. <id> is an opaque integer -- a plain octet
# for validation_subnet_reserve's callers, or a combined `/27` slot for
# validation_subnet_reserve_slot's -- this function does not care which.
#
# The lock is acquired directly on an fd owned by the very process that
# stays alive to hold it (`exec 9>...; flock -n 9; exec sleep infinity`, the
# same fd-based pattern build-tools.yml's Buildx cache lock uses for its own
# synchronous, single-step flock), not by a wrapper process that forks a
# separate child to sleep -- a fork there would let the lock survive
# `kill`ing the wrapper alone, since the child would inherit a duplicate of
# the same locked open file description. Using `exec` twice in the same
# backgrounded subshell means the PID this function returns is the literal
# process holding the lock: killing exactly that PID always releases it
# immediately, with no orphaned child left holding it behind.
validation_subnet_try_lock() {
    local lock_root="$1" id="$2"
    local lock_file="$lock_root/${id}.lock"
    local holder_pid

    mkdir -p "$lock_root"

    (
        # Redirect this subshell's stdout/stderr away FIRST, before doing
        # anything else. Every caller of this function invokes it inside a
        # `$(...)` command substitution (validation_subnet_reserve, and the
        # workflow step further up the call chain), which only returns once
        # it sees EOF on its read end of that pipe -- i.e. once every
        # process holding the write end open has closed it. Without this
        # redirect, the backgrounded `exec sleep infinity` below inherits
        # fd 1/2 from the command substitution and keeps holding them open
        # for as long as it lives (which is deliberately "until explicitly
        # killed" -- see validation_subnet_release), so the very first
        # successful reservation would hang its own caller (and therefore
        # the Bats tests and the workflow step) forever, never reaching the
        # `printf` of the holder PID below. Confirmed directly with a
        # minimal repro of this exact backgrounded-subshell-in-command-
        # substitution pattern.
        exec >/dev/null 2>&1
        exec 9>"$lock_file"
        flock -n 9 || exit 1
        exec sleep infinity
    ) &
    holder_pid=$!

    # Give the backgrounded subshell time to either acquire the lock and
    # reach `exec sleep infinity`, or fail `flock -n` and exit -- both
    # settle well within this margin in practice. This is the same
    # probe-after-a-brief-sleep technique this project's other CI scripts
    # already use to confirm a backgrounded process is genuinely still
    # running (e.g. health-check polling loops), applied here to a
    # near-instant flock attempt instead of a slow-starting service.
    sleep 0.3

    if kill -0 "$holder_pid" 2>/dev/null; then
        printf '%s\n' "$holder_pid"
        return 0
    fi

    wait "$holder_pid" 2>/dev/null || true
    return 1
}

# validation_subnet_release <holder_pid>
# Releases a lock previously acquired by validation_subnet_try_lock by
# killing its holder process. Safe to call with an empty/unset argument (no
# lock was ever held) or a PID that's already gone (e.g. the runner already
# tore down this job's process tree on cancellation) -- both are silent
# no-ops.
validation_subnet_release() {
    local holder_pid="${1:-}"
    [[ -n "$holder_pid" ]] || return 0
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
}

# validation_subnet_reserve <lock_root> <run_id> <run_attempt> <start_attempt> <max_attempts>
# Tries attempt numbers from <start_attempt> up to <max_attempts> (inclusive),
# deriving each one's candidate octet via validation_subnet_seed_for_attempt
# + validation_subnet_derive_octet and attempting to lock it via
# validation_subnet_try_lock. On the first attempt number whose octet locks
# successfully, prints three lines -- "attempt=<n>", "octet=<n>",
# "holder_pid=<n>" -- and returns 0. If every attempt number in the range is
# already locked by another concurrent run, prints nothing and returns 1.
#
# For the general 172.30.0.0/16 validation-stack pool ONLY -- see
# validation_subnet_reserve_slot (below) for the `/27`-per-slot equivalent.
# scripts/dhcp-kea-lease-flow-simulation.sh and
# scripts/dhcp-proxy-pxe-simulation.sh call THIS function (on their own,
# separate 172.31.0.0/16 / 172.29.0.0/16 lock_root/range), expecting a plain
# octet, unchanged by the #832 redesign.
#
# This function only arbitrates HOST-LOCAL LOCK contention -- it has no
# Docker dependency at all, deliberately, so it can be unit tested without a
# Docker daemon. A caller that also needs to validate the candidate against
# Docker's own network state or an actual `docker compose up`/`docker
# network create` failure should call validation_subnet_release on a
# reservation that fails its own check, then call this function again with
# start_attempt set one past the attempt number that just failed -- so a
# subsequent call never re-tries (and re-fails identically on) the same
# already-rejected candidate.
validation_subnet_reserve() {
    local lock_root="$1" run_id="$2" run_attempt="$3" start_attempt="$4" max_attempts="$5"
    local attempt seed octet holder_pid

    for (( attempt = start_attempt; attempt <= max_attempts; attempt++ )); do
        seed="$(validation_subnet_seed_for_attempt "$run_id" "$run_attempt" "$attempt")"
        octet="$(validation_subnet_derive_octet "$seed")"

        if holder_pid="$(validation_subnet_try_lock "$lock_root" "$octet")"; then
            printf 'attempt=%s\noctet=%s\nholder_pid=%s\n' "$attempt" "$octet" "$holder_pid"
            return 0
        fi
    done

    return 1
}

# validation_subnet_reserve_slot <lock_root> <run_id> <run_attempt> <start_attempt> <max_attempts>
# The `/27`-per-slot (#832) equivalent of validation_subnet_reserve: same
# attempt-range/retry shape, but derives each candidate via
# validation_subnet_derive_slot (octet AND subblock, combined) and locks on
# the COMBINED slot value -- not just the octet -- so two concurrent runs
# that land on the SAME octet but a DIFFERENT `/27` block within it are
# correctly treated as non-conflicting (this is the entire point of the
# `/27` redesign: locking at slot granularity is what actually multiplies
# the usable pool from ~250 to ~2,000; locking at octet granularity while
# allocating at slot granularity would silently re-serialize concurrent
# runs down to the old, smaller effective pool). Prints "attempt=<n>",
# "slot=<n>", "holder_pid=<n>". Used by the general 172.30.0.0/16
# validation-stack pool ONLY (full-setup-validate.yml,
# full-setup-deep-validate.yml, build-push.yml,
# scripts/lib/run-in-validation-subnet.sh) -- NOT by the two DHCP
# simulation scripts, which call validation_subnet_reserve (above) instead.
validation_subnet_reserve_slot() {
    local lock_root="$1" run_id="$2" run_attempt="$3" start_attempt="$4" max_attempts="$5"
    local attempt seed slot holder_pid

    for (( attempt = start_attempt; attempt <= max_attempts; attempt++ )); do
        seed="$(validation_subnet_seed_for_attempt "$run_id" "$run_attempt" "$attempt")"
        slot="$(validation_subnet_derive_slot "$seed")"

        if holder_pid="$(validation_subnet_try_lock "$lock_root" "$slot")"; then
            printf 'attempt=%s\nslot=%s\nholder_pid=%s\n' "$attempt" "$slot" "$holder_pid"
            return 0
        fi
    done

    return 1
}

# validation_subnet_conflicts <target_subnet> [own_prefix]
# Prints a human-readable description of every EXISTING Docker network or
# host interface whose subnet overlaps <target_subnet>; empty output means
# the candidate looks free. This is defense-in-depth ahead of whatever
# actually claims the subnet (`docker compose up`, `docker network create`,
# ...): a leftover bridge interface Docker's own bookkeeping no longer
# tracks (another NIC, a VPN, an orphan from a killed container) still makes
# the kernel refuse an overlapping bridge, so checking the live `ip addr`
# view here lets a caller's retry loop skip that slot cleanly instead of
# discovering it only via a failed create.
#
# <own_prefix>, when given and non-empty, marks a network as this caller's
# OWN reusable-by-name resource (e.g. a Compose project docker recreates by
# name) rather than a real collision -- matched by exact name or a
# well-delimited child ("<own_prefix>-"/"<own_prefix>_"), NOT a bare
# `startswith`, so e.g. slot 22's project ("lancache-ng-validation-22...")
# is never misread as slot 220's ("lancache-ng-validation-220..."). Callers
# with no reusable-by-name resource at all (a script that always creates a
# brand-new, PID-unique network with no intent to reuse it) should omit
# <own_prefix> entirely, so every existing network is a real candidate
# collision.
#
# Single, shared definition used by full-setup-deep-validate.yml's own
# reserve-and-start step, scripts/lib/run-in-validation-subnet.sh, and the
# DHCP simulation scripts (issue #820) -- previously copy-pasted per caller,
# which is exactly the kind of divergence risk this consolidation removes.
# python3 is an inline stdlib CIDR-overlap calculator only (AG-REL-001
# local-one-off allowance); nothing from it enters the committed runtime.
validation_subnet_conflicts() {
    local target_subnet="$1" own_prefix="${2:-}"
    OWN_PREFIX="$own_prefix" python3 - "$target_subnet" <<'PYEOF'
import ipaddress, os, subprocess, sys

target = ipaddress.ip_network(sys.argv[1])
own_prefix = os.environ.get("OWN_PREFIX", "")

def is_ours(name: str) -> bool:
    if not own_prefix:
        return False
    return name == own_prefix or name.startswith(own_prefix + "-") or name.startswith(own_prefix + "_")

ids = subprocess.run(["docker", "network", "ls", "-q"], capture_output=True, text=True, check=True).stdout.split()
for network_id in ids:
    fmt = "{{.Name}}|{{range .IPAM.Config}}{{.Subnet}} {{end}}"
    line = subprocess.run(["docker", "network", "inspect", network_id, "--format", fmt], capture_output=True, text=True, check=True).stdout.strip()
    name, _, subnets_str = line.partition("|")
    if is_ours(name):
        continue
    for subnet_str in subnets_str.split():
        try:
            existing = ipaddress.ip_network(subnet_str)
        except ValueError:
            continue
        if target.overlaps(existing):
            print(f"docker network {name} ({subnet_str})")

route_output = subprocess.run(["ip", "-4", "-o", "addr", "show"], capture_output=True, text=True, check=True).stdout
for line in route_output.splitlines():
    parts = line.split()
    try:
        inet_index = parts.index("inet")
        iface = parts[1]
        cidr = parts[inet_index + 1]
    except (ValueError, IndexError):
        continue
    try:
        existing = ipaddress.ip_interface(cidr).network
    except ValueError:
        continue
    if target.overlaps(existing):
        print(f"host interface {iface} ({cidr})")
PYEOF
}

# validation_subnet_export_env <slot>
# Exports the COMPLETE per-run validation environment for a reserved slot:
# the 172.30.<real_octet>.<base>/27 subnet (base = subblock*32), its
# gateway, every fixed service IP, the per-run Compose project name, and the
# per-run Admin UI host port. This is the ONE place a <slot> integer (as
# produced by validation_subnet_derive_slot/validation_subnet_reserve) is
# decomposed back into real IP octets -- every other function and every
# caller treats <slot> as an opaque reservation unit. The address layout
# deliberately mirrors .github/actions/derive-validation-network's own
# output block byte-for-byte (same slot -> same subnet, gateway, and
# base+2..base+10 service IPs, same lancache-ng-validation-<slot> project
# name, same 9000+slot UI port), so a driver that reserves a freshly-locked
# slot at claim-time produces the identical wiring that action would have
# produced up front -- just with a slot proven free on THIS host right now
# instead of a statically-derived guess.
#
# VALIDATION_STANDARD_SHIM_IP (base+10, issue #668) is exported even though
# most callers never read it directly: deploy/full-setup/docker-compose.yml
# consumes it as the standard-passthrough-shim service's Compose IP, so
# omitting it would leave that container pinned to the fixed .99.10 default
# and therefore OUTSIDE a reserved /27 -- the exact cross-subnet placement
# bug the per-run derivation exists to avoid. Every other VALIDATION_* value
# that any full-setup service or simulation script reads is exported here
# for the same reason: the reserved slot must own the whole address set,
# not just the subnet CIDR.
#
# #832: only 10 of the /27's 30 usable host addresses (base+1..base+10) are
# claimed here; base+11..base+30 stay free for a couple of consumer scripts
# that need a few MORE addresses within the SAME reserved subnet
# (scripts/dhcp-kea-ctrl-agent-mutation-simulation.sh,
# scripts/setup-reset-kea-config-simulation.sh -- each derives its own
# extra addresses directly from $VALIDATION_SUBNET's actual base, see those
# scripts' own comments) and for genuine future growth of the validation
# stack itself.
validation_subnet_export_env() {
    local slot="$1"
    local octet=$(( slot / 8 ))
    local subblock=$(( slot % 8 ))
    local base=$(( subblock * 32 ))

    export VALIDATION_SUBNET="172.30.${octet}.${base}/27"
    export VALIDATION_GATEWAY="172.30.${octet}.$((base + 1))"
    export VALIDATION_PROXY_IP="172.30.${octet}.$((base + 2))"
    export VALIDATION_DNS_STANDARD_IP="172.30.${octet}.$((base + 3))"
    export VALIDATION_PROXY_SSL_IP="172.30.${octet}.$((base + 4))"
    export VALIDATION_DNS_SSL_IP="172.30.${octet}.$((base + 5))"
    export VALIDATION_WATCHDOG_IP="172.30.${octet}.$((base + 6))"
    export VALIDATION_NETDATA_IP="172.30.${octet}.$((base + 7))"
    export VALIDATION_NATS_IP="172.30.${octet}.$((base + 8))"
    export VALIDATION_UI_IP="172.30.${octet}.$((base + 9))"
    export VALIDATION_STANDARD_SHIM_IP="172.30.${octet}.$((base + 10))"
    export COMPOSE_PROJECT_NAME="lancache-ng-validation-${slot}"
    export VALIDATION_UI_PORT=$((9000 + slot))
}

# validation_subnet_output_is_collision <output>
# Returns 0 (true) when <output> carries one of Docker's own subnet/address
# contention signatures, 1 otherwise. This is the single, shared definition
# of "this failure is a subnet collision worth retrying on a different
# slot" -- as opposed to a real, deterministic failure (a bad image, a
# missing env var, a genuine test assertion) that would fail identically on
# every slot and so must be surfaced immediately instead of burning through
# the whole retry budget. "Pool overlaps" is the daemon's error when a new
# bridge's subnet overlaps an existing one; the "already in use" / "Address
# already in use" variants cover a host port or address a concurrent run
# grabbed first. Kept here, beside the reservation logic these strings drive
# the retry decision for, so both the full-setup-validate compose-up path
# and the run-in-validation-subnet.sh simulation wrapper classify a failure
# by exactly the same rule.
validation_subnet_output_is_collision() {
    local output="$1"
    [[ "$output" == *"Pool overlaps"* \
        || "$output" == *"already in use"* \
        || "$output" == *"Address already in use"* ]]
}

# validation_network_await_detached <network_name> [timeout_seconds]
# Polls `docker network inspect <network_name>` until Docker itself reports
# zero attached containers (or the network is already gone), instead of a
# blind fixed sleep. Prints nothing; returns 0 once confirmed clear/gone, 1
# (with an ::error:: naming the still-attached containers) if
# <timeout_seconds> (default 30) elapses first.
#
# WHY THIS EXISTS: every one of this project's compose-stack simulation
# scripts tears its stack down with `docker compose down ... || true`, on
# the assumption that once that command returns, every container AND its
# network endpoint are fully gone. Confirmed false in real CI (run
# 29346408005's attempt 1, jobs "Watchtower update simulation" and "DNS
# zone/record rollback simulation", both landing on octet 69): the Docker
# daemon's own container-removal API call can report success before the
# matching network endpoint is actually unwired internally -- worse under
# host load with many concurrent validation networks (18 other stale octets
# were live on the runner at that exact moment, per the post-job cleanup
# hook's own log). Since every job in one full-setup-deep-validate.yml run
# derives and reuses the SAME octet/project name (compute-validation-network
# runs once per run, not once per job), a job whose own `down` lost this
# race silently leaves one container attached (its swallowed `|| true`
# never surfaces this), and the NEXT job to reserve that same octet inherits
# a network Docker still considers non-empty. That job's own `docker compose
# up` then hits Compose's recreate-stale-network path, which fails with
# "has active endpoints" -- a real, uncontrolled command failure (not
# wrapped in `|| true`), which is what actually surfaced in CI. Confirmed
# directly on a real self-hosted runner host: a two-container/stop-one/
# rm-immediately repro reproduces "has active endpoints" once enough
# concurrent networks are active on the host to slow the daemon's own
# endpoint-detach queue, and waiting for `docker network inspect`'s
# container count to reach 0 before removing eliminates it.
validation_network_await_detached() {
    local network_name="$1" timeout="${2:-30}"
    local deadline=$((SECONDS + timeout))
    local remaining

    while (( SECONDS < deadline )); do
        remaining="$(docker network inspect "$network_name" --format '{{len .Containers}}' 2>/dev/null)" || return 0
        [[ "$remaining" == "0" ]] && return 0
        sleep 1
    done

    echo "::error::Docker network $network_name still reports attached containers after ${timeout}s -- a container's endpoint never fully detached (teardown race)." >&2
    # Redirect order matters (see watchtower-update-simulation.sh's own
    # identical-reasoning comment): `>&2` first duplicates the CURRENT
    # stdout target onto fd2, then `2>/dev/null` replaces fd2 with
    # /dev/null for THIS command's own stderr only -- doing it in the
    # reverse order would send the container names themselves to
    # /dev/null too, since fd1 would then be duplicated from an
    # already-redirected fd2.
    docker network inspect "$network_name" --format '{{range $id, $c := .Containers}}{{$c.Name}} {{end}}' >&2 2>/dev/null || true
    return 1
}

# validation_network_teardown <network_name> [timeout_seconds]
# Removes <network_name>, waiting for every attached container to actually
# detach first (validation_network_await_detached) rather than racing
# Docker's own async endpoint-detach against an immediate `docker network
# rm` -- the exact race described above. If the wait times out, force-
# disconnects every still-attached container's endpoint (a container stuck
# past the timeout did not shut down cleanly on its own; waiting longer
# would not help) before retrying the removal, and reports a clear,
# actionable error if the network still cannot be removed afterward --
# instead of silently leaving a poisoned network behind for whichever job
# or run reuses this project name next (the actual failure mode this
# function replaces). Safe to call when the network is already gone.
#
# Callers use this instead of trusting `docker compose down`'s own network
# removal to have actually finished: it is meant to run right after `down`
# in every script's cleanup trap, so the slot/project-name lock this
# project's callers hold (scripts/lib/run-in-validation-subnet.sh,
# full-setup-validate.yml's own teardown step) can truthfully be released
# once this returns, instead of merely once `down`'s own CLI call returned.
validation_network_teardown() {
    local network_name="$1" timeout="${2:-30}"

    if ! docker network inspect "$network_name" >/dev/null 2>&1; then
        return 0
    fi

    if ! validation_network_await_detached "$network_name" "$timeout"; then
        echo "::warning::Force-disconnecting remaining containers from $network_name after the ${timeout}s wait; they did not shut down cleanly on their own." >&2
        local containers cid
        containers="$(docker network inspect "$network_name" --format '{{range $id, $c := .Containers}}{{$id}} {{end}}' 2>/dev/null)"
        for cid in $containers; do
            docker network disconnect -f "$network_name" "$cid" >/dev/null 2>&1 || true
        done
    fi

    if docker network rm "$network_name" >/dev/null 2>&1; then
        return 0
    fi

    if docker network inspect "$network_name" >/dev/null 2>&1; then
        echo "::error::Docker network $network_name could not be removed even after waiting ${timeout}s and force-disconnecting its containers -- a later job/run reusing this project name will hit the same 'has active endpoints' race." >&2
        return 1
    fi
    return 0
}

# validation_project_networks_teardown <compose_project_name> [timeout_seconds]
# Tears down EVERY Docker network Compose created for <compose_project_name>
# (discovered via the `com.docker.compose.project` label Compose itself
# attaches, e.g. deploy/full-setup/docker-compose.yml declares both
# "validation" and "validation-api" -- a single hardcoded "_validation"
# suffix would silently skip the second one), via validation_network_teardown
# for each. Callers should prefer this over calling
# validation_network_teardown on one guessed network name directly: it stays
# correct if a compose file's network list changes, with no per-caller
# hardcoded suffix to fall out of sync.
validation_project_networks_teardown() {
    local compose_project="$1" timeout="${2:-30}"
    local network_id failed=0

    while IFS= read -r network_id; do
        [[ -n "$network_id" ]] || continue
        local network_name
        network_name="$(docker network inspect "$network_id" --format '{{.Name}}' 2>/dev/null)" || continue
        validation_network_teardown "$network_name" "$timeout" || failed=1
    done < <(docker network ls --filter "label=com.docker.compose.project=$compose_project" -q 2>/dev/null)

    return "$failed"
}
