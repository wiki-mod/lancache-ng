#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Repeat-run idempotence coverage for the `nats` container's inline entrypoint
# static-nats.conf generator (the `command:` block in deploy/{dev,prod,quickstart}
# /docker-compose.yml), the NATS equivalent of dns_config_snapshot_idempotence.bats
# for PowerDNS and setup_update_idempotence.bats for setup.sh.
#
# Why this suite exists: since issue #811 the entrypoint OWNS the static
# nats.conf and regenerates it on every container start, while the Admin UI owns
# a separate auth_callout.conf fragment. The whole #811 fix rests on the
# entrypoint regenerating its own file idempotently AND never overwriting the
# UI's fragment on restart. Every sibling config-writer in this repo has a real
# repeat-run test proving convergence (enforced by
# scripts/check-idempotence-test-coverage.sh); the entrypoint's #811-critical
# never-overwrite branch shipped without one because the logic is inline in
# docker-compose.yml rather than a standalone services/nats/entrypoint.sh the
# existing suites could source. This file closes that gap by driving the REAL
# extracted command block twice (see helpers/nats-entrypoint-helpers.sh for the
# extraction and its faithful-reproduction rationale).
#
# `nats-server` and `chown` are stubbed as no-ops (the only two I/O boundaries:
# the final `exec nats-server` and the ownership handoff to UID 10001); the
# config-generation logic runs unmodified.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # shellcheck source=tests/bats/helpers/nats-entrypoint-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/nats-entrypoint-helpers.sh"

    stub_bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$stub_bin"
    printf '#!/bin/sh\nexit 0\n' > "$stub_bin/nats-server"
    printf '#!/bin/sh\nexit 0\n' > "$stub_bin/chown"
    chmod +x "$stub_bin/nats-server" "$stub_bin/chown"

    # The static role credentials the generator interpolates. Values are
    # arbitrary but fixed, so "same env in -> byte-identical nats.conf out" is
    # the property under test.
    export NATS_UI_USER=lancache-ui NATS_UI_PASSWORD=ui-secret \
        NATS_DNS_WRITER_USER=lancache-dns-writer NATS_DNS_WRITER_PASSWORD=writer-secret \
        NATS_DNS_REPLICA_USER=lancache-dns-replica NATS_DNS_REPLICA_PASSWORD=replica-secret \
        NATS_CALLOUT_USER=lancache-nats-callout NATS_CALLOUT_PASSWORD=callout-secret
}

# make_sandbox <label>
# Fresh, isolated sandbox root for one simulated container filesystem. Echoes
# the root path so callers can capture it.
make_sandbox() {
    local root="$BATS_TEST_TMPDIR/sb-$1"
    rm -rf "$root"
    mkdir -p "$root"
    printf '%s' "$root"
}

# generate <compose_file> <sandbox_root>
# Extract the compose file's nats entrypoint and run it once against the given
# sandbox root, asserting a clean (exit 0) generation. Leaves the generated
# nats.conf and auth_callout.conf under <sandbox_root>/etc/nats.
generate() {
    local compose="$1" root="$2" script="$2/entrypoint.sh"
    extract_nats_entrypoint_command "$compose" "$root" "$script"
    run run_nats_entrypoint "$script" "$root" "$stub_bin"
    [ "$status" -eq 0 ] || {
        printf 'entrypoint generation failed (exit %s):\n%s\n' "$status" "$output" >&2
        return 1
    }
}

# tmp_leftovers <sandbox_root>
# Count leftover atomic-write temp files (the generator writes nats.conf via a
# mktemp'd `.nats.conf.XXXXXX` + mv); a converged run must leave none behind.
tmp_leftovers() {
    find "$1/etc/nats" -maxdepth 1 -name '.nats.conf.*' 2>/dev/null | wc -l
}

# nats_conf_content <sandbox_root>
# Print the generated nats.conf with the test-only sandbox root prefix
# normalized out. The extraction relocates the container's absolute write
# targets under a per-sandbox root, and one of them (/var/log/lancache-nats)
# appears in nats.conf's `log_file` directive -- so two fresh boots on DIFFERENT
# sandbox roots differ there, and ONLY there. In the real container the path is
# fixed, so normalizing the root back out is what lets an across-sandbox
# comparison assert the real "same env -> byte-identical nats.conf" property
# rather than tripping on the relocation artifact. (Same-root comparisons, e.g.
# the restart test, need no normalization and keep the raw byte check.)
nats_conf_content() {
    sed "s#$1#__SANDBOX__#g" "$1/etc/nats/nats.conf"
}

# ── #811 regression: restart never clobbers the UI's auth_callout fragment ────

@test "prod nats entrypoint: repeated restarts regenerate a byte-identical nats.conf and never overwrite the UI's auth_callout.conf fragment (idempotent)" {
    local compose="$repo_root/deploy/prod/docker-compose.yml"
    local root
    root="$(make_sandbox prod-restart)"

    # First boot on a fresh volume: generates nats.conf and creates an EMPTY
    # auth_callout.conf placeholder (an empty include is valid; a missing one is
    # a fatal nats-server boot error).
    generate "$compose" "$root"
    [ -f "$root/etc/nats/nats.conf" ]
    [ -f "$root/etc/nats/auth_callout.conf" ]
    [ ! -s "$root/etc/nats/auth_callout.conf" ]
    local first_conf
    first_conf="$(cat "$root/etc/nats/nats.conf")"

    # The Admin UI now writes the real callout fragment (routes/secondaries.rs).
    local ui_fragment='auth_callout {
  issuer: "issuer-public-key-abc123"
  auth_users: [ lancache-nats-callout ]
}'
    printf '%s\n' "$ui_fragment" > "$root/etc/nats/auth_callout.conf"

    # Second boot (the restart the UI triggers to apply the callout, and every
    # subsequent restart): re-runs the entrypoint. It MUST regenerate a
    # byte-identical nats.conf and leave the UI's fragment untouched -- the exact
    # clobber that broke the callout before issue #811.
    generate "$compose" "$root"
    [ "$(cat "$root/etc/nats/nats.conf")" = "$first_conf" ]
    [ "$(cat "$root/etc/nats/auth_callout.conf")" = "$ui_fragment" ]

    [ "$(tmp_leftovers "$root")" -eq 0 ]
}

# ── fresh-volume generation is a stable fixed point across repeated boots ──────

@test "prod nats entrypoint: two fresh boots with the same env converge to byte-identical nats.conf and an empty placeholder each time" {
    local compose="$repo_root/deploy/prod/docker-compose.yml"
    local root_a root_b
    root_a="$(make_sandbox prod-fresh-a)"
    root_b="$(make_sandbox prod-fresh-b)"

    generate "$compose" "$root_a"
    generate "$compose" "$root_b"

    # Byte-identical generated config, and the placeholder is empty on both fresh
    # volumes (never a stale or non-empty file the UI's first write must clean up).
    [ "$(nats_conf_content "$root_a")" = "$(nats_conf_content "$root_b")" ]
    [ ! -s "$root_a/etc/nats/auth_callout.conf" ]
    [ ! -s "$root_b/etc/nats/auth_callout.conf" ]

    # Sanity: the comparison is not trivially true on empty/broken output -- the
    # generator actually interpolated the static roles and wired the include.
    grep -q 'user: "lancache-ui"' "$root_a/etc/nats/nats.conf"
    grep -q 'user: "lancache-nats-callout"' "$root_a/etc/nats/nats.conf"
    grep -q 'include "auth_callout.conf"' "$root_a/etc/nats/nats.conf"
}

# ── the three generating compose files must not drift apart ───────────────────

@test "dev/prod/quickstart nats entrypoints generate byte-identical nats.conf for identical env (no cross-compose drift)" {
    local root_dev root_prod root_quick
    root_dev="$(make_sandbox dev-drift)"
    root_prod="$(make_sandbox prod-drift)"
    root_quick="$(make_sandbox quick-drift)"

    generate "$repo_root/deploy/dev/docker-compose.yml" "$root_dev"
    generate "$repo_root/deploy/prod/docker-compose.yml" "$root_prod"
    generate "$repo_root/deploy/quickstart/docker-compose.yml" "$root_quick"

    # The sandbox root is rewritten identically into each, so the only remaining
    # difference would be a real divergence in the entrypoint logic between the
    # three deployments -- which must never happen silently.
    [ "$(nats_conf_content "$root_dev")" = "$(nats_conf_content "$root_prod")" ]
    [ "$(nats_conf_content "$root_prod")" = "$(nats_conf_content "$root_quick")" ]
}

# ── extraction fails loudly when the anchor is gone (guard the guard) ──────────

@test "extraction fails loudly when a compose file has no nats entrypoint command block" {
    local root bogus
    root="$(make_sandbox bogus)"
    bogus="$BATS_TEST_TMPDIR/no-nats-compose.yml"
    printf 'services:\n  ui:\n    image: example\n' > "$bogus"

    run extract_nats_entrypoint_command "$bogus" "$root" "$root/entrypoint.sh"
    [ "$status" -ne 0 ]
}
