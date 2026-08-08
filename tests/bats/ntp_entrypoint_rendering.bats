#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for services/ntp/entrypoint.sh's config-rendering
# functions (`is_ip_literal`, `render_ntp_config`, `validate_ntp_config`).
# Loads the real functions (not a reimplementation) and asserts on the
# rendered chrony.conf content, independent of a real chronyd (there is no
# offline "config test" mode for chrony -- see validate_ntp_config's own
# comment in entrypoint.sh for why this project's structural check is what
# it is, and manual verification against a real chronyd build is what
# actually validates full syntax correctness).

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/ntp-entrypoint-helpers.sh"

    # shellcheck source=tests/bats/helpers/ntp-entrypoint-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/ntp-entrypoint-helpers.sh"
    load_ntp_entrypoint_helpers "$repo_root" "$helper_file"

    template="$BATS_TEST_TMPDIR/chrony.conf.template"
    printf 'driftfile /var/lib/chrony/chrony.drift\n' > "$template"
    target="$BATS_TEST_TMPDIR/chrony.conf"
}

@test "is_ip_literal accepts IPv4 and IPv6 literals, rejects hostnames" {
    run is_ip_literal "192.0.2.1"
    [ "$status" -eq 0 ]

    run is_ip_literal "2606:4700:f1::1"
    [ "$status" -eq 0 ]

    run is_ip_literal "0.debian.pool.ntp.org"
    [ "$status" -eq 1 ]

    run is_ip_literal "time.cloudflare.com"
    [ "$status" -eq 1 ]
}

@test "render_ntp_config renders a pool line for a hostname entry" {
    # shellcheck disable=SC2034 # NTP_UPSTREAM_SERVERS/NTP_ALLOWED_CLIENT_CIDRS
    # are read as globals inside render_ntp_config(), which this test loads
    # from services/ntp/entrypoint.sh at runtime via load_ntp_entrypoint_helpers
    # (see setup() above) -- shellcheck analyzes this .bats file in isolation
    # and cannot see that dynamically-sourced function body, so it cannot trace
    # the read and reports these assignments as unused.
    NTP_UPSTREAM_SERVERS="0.debian.pool.ntp.org"
    # shellcheck disable=SC2034 # see NTP_UPSTREAM_SERVERS comment above
    NTP_ALLOWED_CLIENT_CIDRS=""

    render_ntp_config "$target" "$template"

    run cat "$target"
    [[ "$output" == *"pool 0.debian.pool.ntp.org iburst"* ]]
    [[ "$output" != *"server 0.debian.pool.ntp.org"* ]]
}

@test "render_ntp_config renders a server line for an IPv4/IPv6 literal entry" {
    # shellcheck disable=SC2034 # see the "renders a pool line" test above
    NTP_UPSTREAM_SERVERS="192.0.2.1 2606:4700:f1::1"
    # shellcheck disable=SC2034 # see the "renders a pool line" test above
    NTP_ALLOWED_CLIENT_CIDRS=""

    render_ntp_config "$target" "$template"

    run cat "$target"
    [[ "$output" == *"server 192.0.2.1 iburst"* ]]
    [[ "$output" == *"server 2606:4700:f1::1 iburst"* ]]
}

# Matches services/proxy's PROXY_ALLOWED_CLIENT_CIDRS convention: empty
# means allow any client that can reach the bound port, not deny everyone --
# chrony denies all NTP clients by default without at least one explicit
# `allow`, which would silently defeat requirement 3 (LAN exposure) for any
# operator who never touches this setting.
@test "render_ntp_config defaults to allow-all when NTP_ALLOWED_CLIENT_CIDRS is empty" {
    # shellcheck disable=SC2034 # see the "renders a pool line" test above
    NTP_UPSTREAM_SERVERS="192.0.2.1"
    # shellcheck disable=SC2034 # see the "renders a pool line" test above
    NTP_ALLOWED_CLIENT_CIDRS=""

    render_ntp_config "$target" "$template"

    run cat "$target"
    [[ "$output" == *"allow 0.0.0.0/0"* ]]
    [[ "$output" == *"allow ::/0"* ]]
}

@test "render_ntp_config scopes allow to each configured CIDR when set" {
    # shellcheck disable=SC2034 # see the "renders a pool line" test above
    NTP_UPSTREAM_SERVERS="192.0.2.1"
    # shellcheck disable=SC2034 # see the "renders a pool line" test above
    NTP_ALLOWED_CLIENT_CIDRS="192.168.0.0/16 10.0.0.0/8"

    render_ntp_config "$target" "$template"

    run cat "$target"
    [[ "$output" == *"allow 192.168.0.0/16"* ]]
    [[ "$output" == *"allow 10.0.0.0/8"* ]]
    [[ "$output" != *"allow 0.0.0.0/0"* ]]
}

@test "validate_ntp_config rejects a config with no pool/server directive" {
    printf 'allow 0.0.0.0/0\n' > "$target"

    run validate_ntp_config "$target"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no pool/server directive"* ]]
}

@test "validate_ntp_config rejects a config with no allow directive" {
    printf 'server 192.0.2.1 iburst\n' > "$target"

    run validate_ntp_config "$target"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no allow directive"* ]]
}

@test "validate_ntp_config accepts a fully rendered config" {
    # shellcheck disable=SC2034 # see the "renders a pool line" test above
    NTP_UPSTREAM_SERVERS="192.0.2.1"
    # shellcheck disable=SC2034 # see the "renders a pool line" test above
    NTP_ALLOWED_CLIENT_CIDRS=""
    render_ntp_config "$target" "$template"

    run validate_ntp_config "$target"
    [ "$status" -eq 0 ]
}

# Issue #1318: a stale pidfile left behind by a previously crashed chronyd
# instance (in the SAME container -- restart: always re-execs this
# entrypoint against the same writable filesystem, /run included) must not
# survive into the next start attempt, or chronyd fails a second time with
# a misleading "Another chronyd may already be running" error instead of
# retrying cleanly. Real-repeat-crash-style proof: simulates exactly that
# sequence -- a pidfile written by a "previous" crashed instance, present
# on disk before this function ever runs -- and asserts it's gone
# afterward, the same convergence property issue #456's checklist expects
# of any stateful write path this entrypoint touches. Calls the
# parameterized _core function directly (not the zero-arg
# cleanup_stale_ntp_pidfile production entry point -- see that function's
# own comment for why the two are split, same reasoning as
# _fix_chrony_dir_ownership_core/fix_chrony_dir_ownership above) so this
# test exercises the real removal logic against a fixture path.
@test "_cleanup_stale_ntp_pidfile_core removes a pidfile left behind by a previously crashed instance" {
    stale_pidfile="$BATS_TEST_TMPDIR/chronyd.pid"
    echo "1" > "$stale_pidfile"
    [ -f "$stale_pidfile" ]

    _cleanup_stale_ntp_pidfile_core "$stale_pidfile"

    [ ! -f "$stale_pidfile" ]
}

# Repeating the cleanup (mirroring a second, third, ... crash-then-restart
# cycle) must stay a no-op rather than erroring -- `rm -f` already gives
# this for free, but this test makes the idempotence property an explicit,
# checked assertion rather than an implicit side effect of the flag choice.
@test "_cleanup_stale_ntp_pidfile_core is idempotent across repeated calls with no pidfile present" {
    missing_pidfile="$BATS_TEST_TMPDIR/does-not-exist/chronyd.pid"
    [ ! -f "$missing_pidfile" ]

    run _cleanup_stale_ntp_pidfile_core "$missing_pidfile"
    [ "$status" -eq 0 ]
    run _cleanup_stale_ntp_pidfile_core "$missing_pidfile"
    [ "$status" -eq 0 ]
}

# cleanup_stale_ntp_pidfile itself (the zero-parameter production entry
# point, not the _core function the two cases above exercise directly):
# confirms it really does forward to chrony's real, confirmed-live default
# pidfile path with no parameters of its own to pass. Reads the loaded
# function's own body (via `type`) rather than calling it against the real
# /run/chrony/chronyd.pid path, which would require root/real filesystem
# access this test sandbox doesn't need -- the same technique
# fix_chrony_dir_ownership's own forwarding test above uses.
@test "cleanup_stale_ntp_pidfile forwards to chrony's real pidfile path with no parameters" {
    run type cleanup_stale_ntp_pidfile
    [ "$status" -eq 0 ]
    [[ "$output" == *"_cleanup_stale_ntp_pidfile_core /run/chrony/chronyd.pid"* ]]
}

# Real, root-cause regression test for the log/driftfile permission bug this
# validation pass found (present identically on the pre-migration Debian
# image, not something the Alpine base-image swap introduced): a directory
# owned by someone other than the user chronyd eventually drops privileges
# to must get its ownership corrected at every container start, not just on
# first install, so an already-existing production volume self-heals too.
# Calls the parameterized _core function directly (not the zero-arg
# fix_chrony_dir_ownership production entry point -- see that function's
# own comment for why the two are split) so this test exercises the real
# chown logic against fixture paths without needing root or touching the
# real system directories. Chowns to this test process's OWN uid:gid
# (always succeeds even unprivileged, unlike chowning to an arbitrary named
# user) to prove the real chown mechanism works end-to-end against a
# genuinely wrong-owned fixture directory.
@test "_fix_chrony_dir_ownership_core corrects ownership of a wrong-owned fixture directory" {
    log_dir="$BATS_TEST_TMPDIR/log-chrony"
    lib_dir="$BATS_TEST_TMPDIR/lib-chrony"
    mkdir -p "$log_dir" "$lib_dir"
    self_owner="$(id -u):$(id -g)"

    run _fix_chrony_dir_ownership_core "$self_owner" "$log_dir" "$lib_dir"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WARNING"* ]]

    run stat -c '%u:%g' "$log_dir"
    [ "$output" = "$(id -u):$(id -g)" ]
    run stat -c '%u:%g' "$lib_dir"
    [ "$output" = "$(id -u):$(id -g)" ]
}

# A previously-existing production volume must self-heal on every restart,
# not only the first time it's ever corrected -- repeating the same chown
# against an already-correctly-owned directory must stay a no-op success,
# matching this project's convergence/idempotence expectations (issue #456)
# the same way cleanup_stale_ntp_pidfile's own idempotence test above does.
@test "_fix_chrony_dir_ownership_core is idempotent when called twice against an already-correct owner" {
    log_dir="$BATS_TEST_TMPDIR/log-chrony"
    lib_dir="$BATS_TEST_TMPDIR/lib-chrony"
    mkdir -p "$log_dir" "$lib_dir"
    self_owner="$(id -u):$(id -g)"

    run _fix_chrony_dir_ownership_core "$self_owner" "$log_dir" "$lib_dir"
    [ "$status" -eq 0 ]
    run _fix_chrony_dir_ownership_core "$self_owner" "$log_dir" "$lib_dir"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WARNING"* ]]
}

# The warning path (AG-VAL-024's "a set -e fail-closed branch needs a real
# failing-input run, not manual reasoning" applied to this function's own
# non-fatal-failure branch): a chown that genuinely cannot succeed (an
# invalid/unrelated owner spec, guaranteed to fail for an unprivileged test
# process) must print a WARNING and still return 0, so a bare call at the
# real entrypoint's top level can never trip `set -e` and abort the whole
# service over a non-essential logging/driftfile permission failure.
@test "_fix_chrony_dir_ownership_core warns but returns non-fatally when chown genuinely fails" {
    log_dir="$BATS_TEST_TMPDIR/log-chrony-unwritable"
    lib_dir="$BATS_TEST_TMPDIR/lib-chrony-unwritable"
    mkdir -p "$log_dir" "$lib_dir"

    run _fix_chrony_dir_ownership_core "root:root" "$log_dir" "$lib_dir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING"* ]]
    [[ "$output" == *"$log_dir"* ]]
}

# fix_chrony_dir_ownership itself (the zero-parameter production entry
# point, not the _core function the three cases above exercise directly):
# confirms it really does forward to the real system paths and the real
# chrony:chrony owner with no parameters of its own to pass -- reads the
# loaded function's own body (via `type`), the same technique
# cleanup_stale_ntp_pidfile's own default-path test above uses, rather than
# actually chowning the real /var/log/chrony and /var/lib/chrony (which
# would require root and would mutate real system paths this test sandbox
# must not touch).
@test "fix_chrony_dir_ownership forwards to the real chrony user and system paths with no parameters" {
    run type fix_chrony_dir_ownership
    [ "$status" -eq 0 ]
    [[ "$output" == *"_fix_chrony_dir_ownership_core chrony:chrony /var/log/chrony /var/lib/chrony"* ]]
}

# Least-privilege hardening (issue #1358), leg 1: the real, committed
# chrony.conf.template must carry the explicit `user chrony` directive, not
# rely on chronyd's own compiled-in PRIVDROP default target user staying an
# unwritten assumption forever (AG-VAL-023: don't build/document around a
# third-party tool's unverified default). A plain static content check on
# the real template file, not a rendering/functional test -- the actual
# runtime effect (chronyd really ending up as the `chrony` user, both with
# and without this line, on this project's shipped chrony-nts build) was
# verified live on a real runner instead; see the PR implementing this
# issue for the full session.
@test "the real chrony.conf.template carries an explicit user chrony directive" {
    run grep -E '^user chrony$' "$repo_root/services/ntp/chrony.conf"
    [ "$status" -eq 0 ]
}

# Least-privilege hardening (issue #1358), leg 3 -- REVISED (issue #1296):
# the original test here asserted a hardcoded `-F 1` (chrony's strict
# seccomp allow-list level). Real verification on a genuine non-LXC VM
# found `-F 1` deterministically crashes chronyd there (a real kernel-
# version-dependent ptrace/seccomp interaction on the pidfile-open
# syscall, unrelated to and masquerading as the CAP_SYS_TIME issue below --
# see entrypoint.sh's own comment on this exact line for the full
# incident). Downgraded to `-F 2` (chrony's own documented looser level)
# and re-verified for real: 5/5 clean starts, 0 restarts, genuine
# `Stratum`/`Leap status: Normal` sync. `NTP_CHRONYD_FLAGS` is now an array
# built up across two code paths (the unconditional base flag here, plus a
# conditional `-x` appended by the CAP_SYS_TIME-degradation branch below),
# so this checks the array's initial value rather than a single fixed exec
# line.
@test "the chronyd flags array starts with -F 2 (seccomp looser named-block level)" {
    run grep -E '^NTP_CHRONYD_FLAGS=\(-F 2\)$' "$repo_root/services/ntp/entrypoint.sh"
    [ "$status" -eq 0 ]
}

# CAP_SYS_TIME graceful degradation (issue #1296): real, executed unit
# tests for clock_control_available() in isolation, using a fake `adjtimex`
# on PATH instead of touching the real kernel time variables (this test
# suite must not actually call adjtimex() -- that would be both
# environment-dependent, since bats itself might run somewhere this write
# is denied for unrelated reasons, and a real, if tiny, side effect on
# whatever host runs bats). Fakes both the read (no args) and write (-t)
# invocations, matching the function's real two-step usage -- an earlier
# version of this function/test pair used `date -s`, which this project's
# own live verification found probes the WRONG syscall (see
# clock_control_available's own comment in entrypoint.sh for the real
# incident: `date -s` succeeds on a host where chronyd's actual `adjtimex`
# call still fails).
@test "clock_control_available succeeds when adjtimex -t succeeds (real CAP_SYS_TIME)" {
    fake_bin="$BATS_TEST_TMPDIR/fake-bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/adjtimex" <<'EOF'
#!/bin/sh
# Checks all args (not just "$1") for "-t" -- the production call is
# `adjtimex -q -t <tick>`, so "-t" is "$2", not "$1".
case " $* " in
    *" -t "*) exit 0 ;;
    *)        echo "    -t  tick:         10000 us" ;;
esac
EOF
    chmod +x "$fake_bin/adjtimex"

    PATH="$fake_bin:$PATH" run clock_control_available
    [ "$status" -eq 0 ]
}

@test "clock_control_available fails when adjtimex -t is denied (nested/LXC host, issue #1296)" {
    fake_bin="$BATS_TEST_TMPDIR/fake-bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/adjtimex" <<'EOF'
#!/bin/sh
# Reproduces this project's own real, live-confirmed failure mode: a
# genuine no-op `adjtimex -t <current tick>` write is denied with a
# non-zero exit when CAP_SYS_TIME is requested but not actually honored by
# a nested container host -- the read (no args) still succeeds, since mode
# 0 needs no capability on any kernel. Checks all args (not just "$1") for
# "-t", matching real busybox adjtimex's own order-independent flag
# parsing -- the production call is `adjtimex -q -t <tick>`, so "-t" is
# "$2", not "$1".
case " $* " in
    *" -t "*) echo "adjtimex: : Operation not permitted" >&2; exit 1 ;;
    *)        echo "    -t  tick:         10000 us" ;;
esac
EOF
    chmod +x "$fake_bin/adjtimex"

    PATH="$fake_bin:$PATH" run clock_control_available
    [ "$status" -ne 0 ]
}

@test "clock_control_available fails closed if adjtimex's read output has no parseable tick line" {
    fake_bin="$BATS_TEST_TMPDIR/fake-bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/adjtimex" <<'EOF'
#!/bin/sh
# A read that returns nothing usable (e.g. a future busybox reformats its
# output) must not be silently treated as "capability available" -- that
# would be the unsafe direction to guess wrong in (a real crash-loop is
# recoverable/visible; a false "available" that then hits the real
# adjtimex crash is exactly the bug this function exists to prevent).
exit 0
EOF
    chmod +x "$fake_bin/adjtimex"

    PATH="$fake_bin:$PATH" run clock_control_available
    [ "$status" -ne 0 ]
    # This must be distinguishable in logs from the expected/documented
    # nested-LXC case (the other two clock_control_available tests above) --
    # a loud, distinct ERROR, not folded into the same message, since an
    # unparseable probe output means something unexpected broke, not that
    # this project's already-known restriction applies.
    [[ "$output" == *"ERROR:"* ]]
    [[ "$output" == *"NOT the expected nested/LXC restriction"* ]]
}

@test "clock_control_available fails closed and logs loudly if adjtimex is entirely missing" {
    # An empty PATH (no fake adjtimex provided at all) simulates a future
    # base-image change that drops the busybox applet this probe depends on
    # -- the `command -v` guard must catch this before ever invoking a
    # nonexistent command, with its own distinct loud error.
    fake_bin="$BATS_TEST_TMPDIR/empty-bin"
    mkdir -p "$fake_bin"

    PATH="$fake_bin" run clock_control_available
    [ "$status" -ne 0 ]
    [[ "$output" == *"ERROR:"* ]]
    [[ "$output" == *"missing from this image"* ]]
    [[ "$output" == *"NOT the expected nested/LXC restriction"* ]]
}

# Structural check (top-level branch logic, not a function this file's
# extraction mechanism can load in isolation -- same rationale as the
# pidfile-directory test below): the degraded-mode branch must actually
# append `-x` to the real flags array chronyd is exec'd with, not just log
# a warning and otherwise proceed identically. A silent no-op fallback
# would still crash-loop exactly as before, defeating the entire point of
# detecting the restriction in the first place.
@test "the CAP_SYS_TIME-degraded branch appends -x to NTP_CHRONYD_FLAGS" {
    run grep -E '^\s*NTP_CHRONYD_FLAGS\+=\(-x\)$' "$repo_root/services/ntp/entrypoint.sh"
    [ "$status" -eq 0 ]
}

@test "the final chronyd exec uses the NTP_CHRONYD_FLAGS array, not a fixed flag list" {
    run grep -E '^exec chronyd -n -f "\$NTP_RUNTIME_CONF" "\$\{NTP_CHRONYD_FLAGS\[@\]\}"$' "$repo_root/services/ntp/entrypoint.sh"
    [ "$status" -eq 0 ]
}

# Real bug fix (found while validating issue #1358, unrelated to and
# pre-existing before that hardening -- see entrypoint.sh's own comment on
# this line for the full incident): nothing in this project ever created
# /run/chrony, chronyd's own pidfile directory, and chronyd does not create
# it itself. This project's self-hosted CI runner fleet never surfaced it
# because every host there dies earlier at an unrelated CAP_SYS_TIME/
# adjtimex restriction (issue #1296) before ever reaching the pidfile-open
# step this bug lives in -- confirmed live on a real runner by deliberately
# bypassing that earlier failure with chronyd's own `-x` flag as a
# diagnostic probe. A real deployment where CAP_SYS_TIME actually works
# would hit this unconditionally today. Static content check (like the
# `user chrony` test above) since this is a plain top-level `mkdir -p`, not
# a function this file's existing helper-extraction mechanism can load in
# isolation; the real fix was proven functionally on a real runner (see PR
# #1358's validation notes), not just here.
@test "entrypoint.sh creates chronyd's own pidfile directory before starting chronyd" {
    run grep -E '^mkdir -p /run/chrony$' "$repo_root/services/ntp/entrypoint.sh"
    [ "$status" -eq 0 ]
}
