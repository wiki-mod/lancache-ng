#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Fast, Docker-free unit coverage for scripts/lib/reserve-validation-subnet.sh
# (issue #703). The real race this closes -- two genuinely concurrent
# workflow runs on the same self-hosted host -- cannot be exercised directly
# in a bats run (there is no second, truly concurrent GitHub Actions run to
# provoke here). Instead this: (1) proves the derivation stays deterministic
# and backward-compatible with .github/actions/derive-validation-network's
# own pre-#703 formula for the common, uncontested attempt-1 case, so a
# single, uncontested run still derives the exact octet it always did; (2)
# proves the actual mechanism this issue adds -- pre-holding an octet's lock
# and confirming a second, independent attempt to claim the SAME octet is
# correctly refused while it's held, and correctly succeeds again once
# released -- using two real flock-backed processes against a throwaway
# $BATS_TEST_TMPDIR lock root, which is the same mechanism a genuinely
# concurrent second workflow run would hit on the real, shared /tmp lock
# root.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # shellcheck source=scripts/lib/reserve-validation-subnet.sh
    source "$repo_root/scripts/lib/reserve-validation-subnet.sh"

    lock_root="$BATS_TEST_TMPDIR/validation-locks"
}

teardown() {
    # Belt-and-suspenders: kill any holder processes a test forgot to
    # release, so a leaked background process can never outlive its test
    # (each test gets a fresh $BATS_TEST_TMPDIR, but a leaked process is not
    # scoped to that directory and would otherwise just keep running).
    [[ -n "${holder_pid:-}" ]] && kill "$holder_pid" 2>/dev/null
    [[ -n "${holder_pid_2:-}" ]] && kill "$holder_pid_2" 2>/dev/null
    true
}

@test "attempt 1's seed matches derive-validation-network's own pre-#703 formula exactly" {
    seed="$(validation_subnet_seed_for_attempt 123456 1 1)"
    [ "$seed" = "123456-1" ]
}

@test "retry attempts salt the seed so they never re-derive attempt 1's seed" {
    seed1="$(validation_subnet_seed_for_attempt 123456 1 1)"
    seed2="$(validation_subnet_seed_for_attempt 123456 1 2)"
    [ "$seed1" != "$seed2" ]
}

@test "octet derivation is deterministic for the same seed" {
    octet_a="$(validation_subnet_derive_octet "123456-1")"
    octet_b="$(validation_subnet_derive_octet "123456-1")"
    [ "$octet_a" = "$octet_b" ]
}

@test "derived octet always falls in the reserved pool, excluding 0, 1, 28, and 99" {
    for seed in "run-1" "run-2" "run-3" "run-4" "run-5" "another-seed" "yet-another"; do
        octet="$(validation_subnet_derive_octet "$seed")"
        [ "$octet" -ge 2 ]
        [ "$octet" -le 253 ]
        [ "$octet" -ne 28 ]
        [ "$octet" -ne 99 ]
    done
}

@test "try_lock succeeds on a free octet and the same octet is refused while held" {
    holder_pid="$(validation_subnet_try_lock "$lock_root" 42)"
    [ -n "$holder_pid" ]
    kill -0 "$holder_pid"

    run validation_subnet_try_lock "$lock_root" 42
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "releasing a lock lets a later attempt claim the same octet again" {
    holder_pid="$(validation_subnet_try_lock "$lock_root" 77)"
    [ -n "$holder_pid" ]

    validation_subnet_release "$holder_pid"
    run kill -0 "$holder_pid"
    [ "$status" -ne 0 ]

    holder_pid_2="$(validation_subnet_try_lock "$lock_root" 77)"
    [ -n "$holder_pid_2" ]
    kill -0 "$holder_pid_2"
}

@test "release is a silent no-op for an empty/unset holder pid" {
    run validation_subnet_release ""
    [ "$status" -eq 0 ]

    run validation_subnet_release
    [ "$status" -eq 0 ]
}

@test "reserve skips an already-locked candidate and lands on a different, unlocked octet" {
    # Pin the FIRST candidate validation_subnet_reserve would try (attempt 1
    # for this run_id/run_attempt) and pre-lock it directly, simulating a
    # second, genuinely concurrent workflow run that got there first -- this
    # is #703's exact scenario, reproduced with two real flock-backed
    # processes instead of two real GitHub Actions runs.
    run_id="run-abc"
    run_attempt="1"
    first_seed="$(validation_subnet_seed_for_attempt "$run_id" "$run_attempt" 1)"
    first_octet="$(validation_subnet_derive_octet "$first_seed")"

    holder_pid="$(validation_subnet_try_lock "$lock_root" "$first_octet")"
    [ -n "$holder_pid" ]

    result="$(validation_subnet_reserve "$lock_root" "$run_id" "$run_attempt" 1 20)"
    [ -n "$result" ]

    won_octet="$(printf '%s\n' "$result" | sed -n 's/^octet=//p')"
    holder_pid_2="$(printf '%s\n' "$result" | sed -n 's/^holder_pid=//p')"

    [ "$won_octet" != "$first_octet" ]
    [ -n "$holder_pid_2" ]
    kill -0 "$holder_pid_2"
}

@test "reserve returns failure once every attempt in range is already locked" {
    run_id="run-xyz"
    run_attempt="1"

    # Lock the only two attempt numbers this call is allowed to try (1 and
    # 2), so the range is fully exhausted and reserve must fail cleanly
    # rather than loop forever or silently reuse a locked octet.
    seed1="$(validation_subnet_seed_for_attempt "$run_id" "$run_attempt" 1)"
    octet1="$(validation_subnet_derive_octet "$seed1")"
    seed2="$(validation_subnet_seed_for_attempt "$run_id" "$run_attempt" 2)"
    octet2="$(validation_subnet_derive_octet "$seed2")"

    holder_pid="$(validation_subnet_try_lock "$lock_root" "$octet1")"
    [ -n "$holder_pid" ]

    # Extremely unlikely (~1/252) but possible: both attempt seeds hash to
    # the same octet. Locking it once already covers that case, so only
    # lock octet2 separately when it's actually different.
    if [ "$octet2" != "$octet1" ]; then
        holder_pid_2="$(validation_subnet_try_lock "$lock_root" "$octet2")"
        [ -n "$holder_pid_2" ]
    fi

    run validation_subnet_reserve "$lock_root" "$run_id" "$run_attempt" 1 2
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "export_env sets the complete VALIDATION_* set for the octet, incl. the shim IP" {
    # The wrapper's whole correctness rests on exporting the FULL address set
    # for a reserved octet, not just the subnet: a missing var silently falls
    # back to the fixed .99 default and lands a service OUTSIDE the reserved
    # /24. Assert every var the derive action emits is present and octet-scoped.
    validation_subnet_export_env 42

    [ "$VALIDATION_SUBNET" = "172.30.42.0/24" ]
    [ "$VALIDATION_GATEWAY" = "172.30.42.1" ]
    [ "$VALIDATION_PROXY_IP" = "172.30.42.2" ]
    [ "$VALIDATION_DNS_STANDARD_IP" = "172.30.42.3" ]
    [ "$VALIDATION_PROXY_SSL_IP" = "172.30.42.4" ]
    [ "$VALIDATION_DNS_SSL_IP" = "172.30.42.5" ]
    [ "$VALIDATION_WATCHDOG_IP" = "172.30.42.6" ]
    [ "$VALIDATION_NETDATA_IP" = "172.30.42.7" ]
    [ "$VALIDATION_NATS_IP" = "172.30.42.8" ]
    [ "$VALIDATION_UI_IP" = "172.30.42.9" ]
    # .10 (#668): compose reads this to place standard-passthrough-shim; it is
    # the var most easily forgotten because most sim scripts never read it
    # directly, yet omitting it strands the shim on the .99 default subnet.
    [ "$VALIDATION_STANDARD_SHIM_IP" = "172.30.42.10" ]
    [ "$COMPOSE_PROJECT_NAME" = "lancache-ng-validation-42" ]
    [ "$VALIDATION_UI_PORT" = "9042" ]
}

@test "export_env's project name/UI port match derive-validation-network's own formula" {
    # The uncontested attempt-1 case must reproduce EXACTLY what the derive
    # action computed up front (project name = lancache-ng-validation-<octet>,
    # UI port = 9000+octet), so a run that never hits contention keeps the
    # identical wiring rather than a subtly different one.
    validation_subnet_export_env 7
    [ "$COMPOSE_PROJECT_NAME" = "lancache-ng-validation-7" ]
    [ "$VALIDATION_UI_PORT" = "9007" ]
}

@test "output_is_collision matches Docker's real subnet/address contention signatures" {
    # These three strings are the ONLY failures the wrapper retries on a new
    # octet; everything else must fail fast. Pin the exact daemon phrasings so
    # a future Docker wording change that breaks the classifier is caught here
    # rather than silently turning every collision into a hard failure.
    run validation_subnet_output_is_collision "Error response from daemon: invalid pool request: Pool overlaps with other one on this address space"
    [ "$status" -eq 0 ]

    run validation_subnet_output_is_collision "driver failed programming external connectivity: Bind for 0.0.0.0:9042 failed: port is already in use"
    [ "$status" -eq 0 ]

    run validation_subnet_output_is_collision "listen tcp 0.0.0.0:9042: bind: Address already in use"
    [ "$status" -eq 0 ]
}

@test "output_is_collision does NOT match unrelated, non-retryable failures" {
    # A real test assertion or a bad image fails identically on every octet;
    # misclassifying it as a collision would waste the whole retry budget and
    # bury the true error. Assert a representative non-collision failure is
    # correctly rejected.
    run validation_subnet_output_is_collision "Error: manifest for ghcr.io/wiki-mod/lancache-ng/proxy:edge not found"
    [ "$status" -eq 1 ]

    run validation_subnet_output_is_collision "assertion failed: expected cache HIT but got MISS"
    [ "$status" -eq 1 ]
}

# fake_docker_and_ip <networks> <ip_addr_output>
# Installs PATH-shimmed `docker`/`ip` executables (real ones are not assumed
# present/safe to actually invoke in a unit test) that answer
# validation_subnet_conflicts's own two subprocess calls from fixed,
# test-supplied data instead of real daemon/host state: `docker network
# ls -q` prints one ID per line parsed from <networks> (each line
# "id|name|subnet"); `docker network inspect <id> --format ...` prints
# "name|subnet " for that ID (matching the real go-template's shape:
# name, a literal pipe, then space-separated subnets with a trailing
# space); `ip -4 -o addr show` prints <ip_addr_output> verbatim. Prepends a
# fresh $BATS_TEST_TMPDIR/bin to PATH so these shadow any real `docker`/`ip`
# on the test runner without needing either to actually exist.
fake_docker_and_ip() {
    local networks="$1" ip_addr_output="$2" fake_bin="$BATS_TEST_TMPDIR/fakebin"
    mkdir -p "$fake_bin"

    cat > "$fake_bin/docker" <<STUB
#!/usr/bin/env bash
networks='$networks'
if [[ "\$1" == "network" && "\$2" == "ls" ]]; then
    printf '%s\n' "\$networks" | cut -d'|' -f1
elif [[ "\$1" == "network" && "\$2" == "inspect" ]]; then
    printf '%s\n' "\$networks" | awk -F'|' -v id="\$3" '\$1==id {printf "%s|%s \n", \$2, \$3}'
fi
STUB
    chmod +x "$fake_bin/docker"

    cat > "$fake_bin/ip" <<STUB
#!/usr/bin/env bash
printf '%s\n' '$ip_addr_output'
STUB
    chmod +x "$fake_bin/ip"

    PATH="$fake_bin:$PATH"
}

@test "conflicts: empty docker/ip state reports no conflict" {
    fake_docker_and_ip "" ""
    run validation_subnet_conflicts "172.30.42.0/24"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "conflicts: a foreign docker network with an overlapping subnet is reported" {
    fake_docker_and_ip "net1|other-project_validation|172.30.42.0/24" ""
    run validation_subnet_conflicts "172.30.42.0/24"
    [ "$status" -eq 0 ]
    [[ "$output" == *"docker network other-project_validation (172.30.42.0/24)"* ]]
}

@test "conflicts: own_prefix exact match and delimited child are excluded, not just startswith" {
    # Both "lancache-ng-validation-22" (exact) and
    # "lancache-ng-validation-22_validation" (delimited child) are OUR
    # project's own leftovers and must be excluded when own_prefix is given.
    fake_docker_and_ip "net1|lancache-ng-validation-22|172.30.22.0/24
net2|lancache-ng-validation-22_validation|172.30.22.0/24" ""
    run validation_subnet_conflicts "172.30.22.0/24" "lancache-ng-validation-22"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "conflicts: a different numbered project is NOT excluded by a bare startswith footgun" {
    # The exact regression this delimited-child match guards against:
    # own_prefix "lancache-ng-validation-22" must NOT swallow
    # "lancache-ng-validation-220..." (a different, unrelated octet's
    # project) as if it were "ours" -- a bare startswith() would.
    fake_docker_and_ip "net1|lancache-ng-validation-220-foo_validation|172.30.99.0/24" ""
    run validation_subnet_conflicts "172.30.99.0/24" "lancache-ng-validation-22"
    [ "$status" -eq 0 ]
    [[ "$output" == *"docker network lancache-ng-validation-220-foo_validation (172.30.99.0/24)"* ]]
}

@test "conflicts: an overlapping host interface (not a docker network) is reported" {
    # This is the exact real-world case a Docker-only check would miss: a
    # bridge interface the kernel already owns, invisible to
    # \`docker network ls\` (an orphan from a killed container, another NIC,
    # a VPN) still makes a create fail -- confirmed for real in issue #820's
    # own evidence (host interface br-55b74025b723 blocking octet 242).
    fake_docker_and_ip "" "3: br-55b74025b723    inet 172.30.242.1/24 brd 172.30.242.255 scope global br-55b74025b723"
    run validation_subnet_conflicts "172.30.242.0/24"
    [ "$status" -eq 0 ]
    [[ "$output" == *"host interface br-55b74025b723 (172.30.242.1/24)"* ]]
}
