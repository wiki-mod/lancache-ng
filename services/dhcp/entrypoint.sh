#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Kea DHCP entrypoint. Validates required secrets, renders Kea config
# templates from env vars on first boot, migrates existing runtime configs
# (DDNS, lease lifetimes, NTP options) on upgrade, restricts the Control
# Agent API to Docker-internal networks via iptables, and starts the Kea
# DHCPv4, control-agent, and DHCP-DDNS processes.

set -e

# ── Shared-secret bootstrap (issue #858) ─────────────────────────────────────
# Embedded byte-identical copy of scripts/lib/shared-secret-bootstrap.sh's
# function definitions (guarded by tests/bats/shared_secret_bootstrap_sync.bats):
# this image builds from services/dhcp/ alone with no shared-file build context.
# BEGIN shared-secret-bootstrap library (scripts/lib/shared-secret-bootstrap.sh)
# lancache_shared_secret_dir
# Directory holding the cross-container shared secrets, mounted from the
# `shared-secrets` named volume into every container that must agree on a
# generated value. Overridable for tests via LANCACHE_SHARED_SECRET_DIR.
lancache_shared_secret_dir() {
    printf '%s' "${LANCACHE_SHARED_SECRET_DIR:-/var/lib/lancache-secrets}"
}

# lancache_shared_secret_gid
# The Admin UI process runs as this gid (services/ui/Dockerfile pins uid/gid
# 10001); dns/dhcp/nats run as root. Shared secret files are created group-owned
# by this gid and mode 0640 so the unprivileged UI can read a root-created file
# without the secret becoming world-readable -- the same cross-uid model the
# nats.conf bootstrap already uses. Overridable for tests.
lancache_shared_secret_gid() {
    printf '%s' "${LANCACHE_SHARED_SECRET_GID:-10001}"
}

# lancache_gen_hex32
# 64 hex characters from 32 random bytes. Uses od + /dev/urandom rather than
# `openssl rand -hex 32` because this runs unchanged in the Debian dns/dhcp/ui
# images AND the BusyBox nats:2-alpine image, and nats:2-alpine ships no openssl.
lancache_gen_hex32() {
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
}

# lancache_gen_base64_32
# base64 of 32 random bytes, for the DDNS TSIG key (PowerDNS/Kea expect a
# base64-encoded HMAC key, matching setup.sh's `openssl rand -base64 32`).
lancache_gen_base64_32() {
    head -c 32 /dev/urandom | base64 | tr -d '\n'
}

# secret_is_placeholder <value>
# True (returns 0) when the value is empty or one of the universal checked-in
# placeholders that must never run live (CHANGE_ME*, changeme*, YOUR_*, *_HERE).
# The split-brain invariant requires every consumer of a given secret to decide
# placeholder-or-real identically; the NATS_*_PASSWORD values are read by three
# separate services (the nats bootstrap, the dns entrypoint, the ui entrypoint),
# so routing their placeholder decision through this one definition keeps them in
# lockstep. Callers that also have secret-specific placeholders (e.g. the dhcp
# dev tokens) match those in addition to this.
#
# Matching is case-insensitive and treats "-"/"_" as equivalent (issue #967:
# e.g. "change-me", "CHANGE_ME", and "Change-Me" are all recognized) --
# normalize first, then match against lowercase/underscore patterns. This is a
# deliberate fail-safe widening: it can only make MORE values match as a
# placeholder, never fewer, so a real randomly-generated hex/base64 secret is
# not realistically affected.
#
# This is one of three independently-maintained placeholder detectors in this
# repo (the others: setup.sh's secret_value_is_placeholder, and
# services/ui/src/main.rs's secondary_registration_token_is_placeholder), kept
# deliberately separate per the maintainer decision recorded in issue #967
# (Option B: cross-validate, don't unify). Divergences from the other two,
# confirmed via tests/fixtures/placeholder-detection-cases.txt and
# tests/bats/placeholder_detection_parity.bats:
#   - This function does NOT recognize the legacy "lancache-*-secret"
#     template-default shape. This omission IS deliberate:
#     deploy/dev/docker-compose.yml and deploy/dev/.env ship real, working dev
#     secrets in exactly that shape (e.g. lancache-nats-ui-dev-secret) that
#     this read path must accept as configured, not regenerate.
#   - This function does NOT recognize a bare "change-me"/"change_me" infix
#     without a CHANGE_ME/changeme prefix, unlike setup.sh/Rust. Pre-existing,
#     not reconciled here (#967 Option B keeps the three pattern sets
#     separate rather than unifying them); no known rationale beyond that.
#   - This function DOES recognize a bare YOUR_* prefix without a trailing
#     _HERE suffix, and a generic *_HERE suffix on any value (not just
#     YOUR_*_HERE) -- both wider than setup.sh/Rust. Also pre-existing and not
#     reconciled here; no shipped placeholder in this repo actually needs
#     either bare form, so the gap has not mattered in practice, but it is a
#     real, confirmed divergence, not an intentional design choice.
secret_is_placeholder() {
    _sip_norm=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
    case "$_sip_norm" in
        "" | change_me* | changeme* | your_* | *_here) return 0 ;;
    esac
    return 1
}

# resolve_shared_secret <name> <current_value_or_empty> <gen_func>
# Resolves a shared secret and prints it on stdout with no trailing newline.
#   - If <current_value_or_empty> is non-empty, prints it and returns 0: an
#     operator/setup.sh-supplied real value always wins and is never persisted
#     to the shared volume (all containers share one .env, so they all already
#     agree on it). The CALLER is responsible for passing empty here when the
#     configured value is a known placeholder for that specific secret.
#   - Otherwise reads $dir/<name> if it already exists (some container generated
#     it first), else atomically creates it with a freshly generated value.
# Atomicity/race: the value is written to a temp file on the shared volume FIRST,
# then the final name is claimed with `ln` (a hardlink, atomic and failing if the
# target already exists). Because the temp already holds the full value before
# the link, a concurrent reader in another container never observes a partial or
# empty file, and a container that loses the create race falls back to reading
# the winner's value instead of erroring. Returns non-zero (and prints nothing)
# only if the shared volume is unwritable, so the caller can fail closed rather
# than silently diverge.
resolve_shared_secret() {
    _rss_name="$1"
    _rss_cur="$2"
    _rss_gen="$3"

    if [ -n "$_rss_cur" ]; then
        printf '%s' "$_rss_cur"
        return 0
    fi

    _rss_dir="$(lancache_shared_secret_dir)"
    _rss_file="${_rss_dir}/${_rss_name}"

    if [ -s "$_rss_file" ]; then
        tr -d '\n' < "$_rss_file"
        return 0
    fi

    mkdir -p "$_rss_dir" 2>/dev/null || true

    _rss_val="$($_rss_gen)"
    if [ -z "$_rss_val" ]; then
        return 1
    fi

    _rss_tmp="$(mktemp "${_rss_dir}/.secret.XXXXXX" 2>/dev/null)" || return 1
    printf '%s' "$_rss_val" > "$_rss_tmp"
    chmod 0640 "$_rss_tmp" 2>/dev/null || true
    chgrp "$(lancache_shared_secret_gid)" "$_rss_tmp" 2>/dev/null || true

    if ln "$_rss_tmp" "$_rss_file" 2>/dev/null; then
        rm -f "$_rss_tmp"
        printf '%s' "$_rss_val"
        return 0
    fi

    rm -f "$_rss_tmp"
    if [ -s "$_rss_file" ]; then
        tr -d '\n' < "$_rss_file"
        return 0
    fi
    return 1
}
# END shared-secret-bootstrap library

install -d -m 750 /run/kea
mkdir -p /var/lib/kea
# Central logging pipeline (#633): Kea's loggers write to this file in
# addition to stdout (see kea-dhcp4.conf.template's "output-options" and
# migrate_dhcp4_config()'s logger patch below) so fluent-bit can tail it, the
# same "file on shared volume" pattern proxy/nginx already uses -- Kea itself
# never creates a missing parent directory for a logger's file output, it
# just fails to start, so this must exist before either daemon runs.
# MUST be exactly /var/log/kea (issue #773): Kea 2.6.3's packaged binaries
# hard-restrict file-logger `output` paths to that one directory as a
# security hardening against arbitrary file writes via a malicious
# config-set -- any other path (the project's usual /var/log/lancache-dhcp
# convention included) fails config load with "invalid path in `output`",
# refusing to start at all, not just losing the file log.
mkdir -p /var/log/kea

case "${1:-}" in
    nmap|/usr/bin/nmap|/bin/nmap)
        exec "$@"
        ;;
esac

# Known-good Kea config snapshots (#614, follow-up to #415) are written by
# the Admin UI's own process (services/ui/src/kea_snapshots.rs), not by this
# entrypoint or the Kea daemons themselves -- Kea never reads or writes this
# directory. The UI container runs as a fixed non-root UID/GID (10001, see
# services/ui/Dockerfile), while this container runs as root and owns
# everything else under /var/lib/kea (kea-dhcp4.conf, kea-leases4.csv, ...).
# Since /var/lib/kea itself is root-owned (mode 0755, not writable by the UI
# user), the UI process cannot even create its own subdirectory here without
# this. Re-asserted on every start, the same pattern the `nats` service uses
# to keep its shared /etc/nats/nats.conf writable by the Admin UI user after
# a NATS restart (see deploy/*/docker-compose.yml).
mkdir -p /var/lib/kea/config-snapshots
chown -R 10001:10001 /var/lib/kea/config-snapshots

# Defaults
: "${DHCP_SUBNET:=10.0.0.0/24}"
: "${DHCP_RANGE_START:=10.0.0.128}"
: "${DHCP_RANGE_END:=10.0.0.254}"
: "${DHCP_GATEWAY:=10.0.0.1}"
: "${DHCP_DOMAIN:=lan}"
: "${DHCP_LEASE_TIME:=86400}"
if [ -z "${DHCP_NTP_SERVERS+x}" ]; then
    DHCP_NTP_SERVERS="debian.pool.ntp.org time.nist.gov"
fi
: "${DHCP_DNS_PRIMARY:=127.0.0.1}"
: "${DHCP_DNS_SECONDARY:=127.0.0.1}"
# Resolve the shared KEA_CTRL_TOKEN and DDNS_TSIG_KEY (issue #858). KEA_CTRL_TOKEN
# is used by both Kea's control-agent here and the Admin UI's DHCP API client;
# DDNS_TSIG_KEY by both this daemon (signing DDNS updates) and PowerDNS (verifying
# them). A real configured value wins; an empty/placeholder value is replaced by a
# first-writer-wins value shared via the shared-secrets volume so both sides agree,
# instead of crash-looping. If the shared volume is unwritable, resolution returns
# empty and the fail-closed placeholder checks below still exit 1.
_kea_ctrl_token_cfg="${KEA_CTRL_TOKEN:-}"
if secret_is_placeholder "$_kea_ctrl_token_cfg"; then
    _kea_ctrl_token_cfg=""
else
    case "$_kea_ctrl_token_cfg" in
        lancache-dhcp-secret|lancache-dhcp-dev-secret|lancache-dhcp-prod-secret) _kea_ctrl_token_cfg="" ;;
    esac
fi
KEA_CTRL_TOKEN="$(resolve_shared_secret kea-ctrl-token "$_kea_ctrl_token_cfg" lancache_gen_hex32)" || KEA_CTRL_TOKEN=""
_ddns_tsig_key_cfg="${DDNS_TSIG_KEY:-}"
if secret_is_placeholder "$_ddns_tsig_key_cfg"; then _ddns_tsig_key_cfg=""; fi
DDNS_TSIG_KEY="$(resolve_shared_secret ddns-tsig-key "$_ddns_tsig_key_cfg" lancache_gen_base64_32)" || DDNS_TSIG_KEY=""
: "${DHCP_DNS_SERVER_IP:=127.0.0.1}"
: "${DHCP_DNS_SERVER_IP_SSL:=127.0.0.1}"
# 5300, not 53 (issue #706): 5300 is pdns_server's (the authoritative
# daemon, the only PowerDNS process with dnsupdate=yes) actual DNS-protocol
# port, per services/dns/pdns.conf.template's local-port=5300. Port 53 is
# pdns_recursor's port -- it does not relay the DNS UPDATE opcode to the
# authoritative backend, so DDNS updates sent there simply time out
# (confirmed empirically) with no error on either side.
: "${DHCP_DDNS_PORT:=5300}"
: "${KEA_CTRL_HOST:=0.0.0.0}"

# DDNS master switch (issue #1076). DHCP_DDNS_ENABLED gates Kea's
# dhcp-ddns.enable-updates -- the documented connectivity switch that must be
# true for the DHCPv4 server to send any DDNS NameChangeRequest to D2 (Kea's
# own default for it is false). This is deliberately independent of DHCP_MODE:
# an operator can run Kea DHCP without also having it write DNS records on
# every lease. Normalize any truthy/falsy spelling to a bare JSON boolean
# literal, because envsubst splices this value UNQUOTED into kea-dhcp4.conf's
# "enable-updates" field, where anything other than true/false is invalid JSON.
# Default off for a fresh install (conservative/opt-in, matching Kea's own
# default); an existing install keeps whatever its persisted kea-dhcp4.conf
# already has via migrate_dhcp4_config's existing-wins merge below, so this
# never silently disables DDNS for anyone already relying on it.
case "$(printf '%s' "${DHCP_DDNS_ENABLED:-}" | tr '[:upper:]' '[:lower:]')" in
    1 | true | yes | on) DHCP_DDNS_ENABLED="true" ;;
    *) DHCP_DDNS_ENABLED="false" ;;
esac

# Verify KEA_CTRL_TOKEN is set to a non-default secret. secret_is_placeholder's
# universal CHANGE_ME*/changeme*/YOUR_*/*_HERE conventions (this project also
# uses YOUR_*_HERE elsewhere, e.g. SECONDARY_REGISTRATION_TOKEN) plus this
# service's own legacy shipped defaults below.
if secret_is_placeholder "$KEA_CTRL_TOKEN"; then
    echo "ERROR: KEA_CTRL_TOKEN must be set to a strong generated secret."
    echo "Generate one with: openssl rand -hex 32"
    exit 1
fi
case "$KEA_CTRL_TOKEN" in
    "lancache-dhcp-secret"|"lancache-dhcp-dev-secret"|"lancache-dhcp-prod-secret")
        echo "ERROR: KEA_CTRL_TOKEN must be set to a strong generated secret."
        echo "Generate one with: openssl rand -hex 32"
        exit 1
        ;;
esac

is_ipv4() {
    local ip="$1" octet a b c d extra

    IFS=. read -r a b c d extra <<< "$ip"
    [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] && [ -z "$extra" ] || return 1
    for octet in "$a" "$b" "$c" "$d"; do
        case "$octet" in
            ""|*[!0-9]*) return 1 ;;
        esac
        [ "$octet" -le 255 ] || return 1
    done
}

resolve_ntp_server() {
    local host="$1" resolved

    [ -n "$host" ] || return 1
    if is_ipv4 "$host"; then
        printf '%s' "$host"
        return 0
    fi

    if ! command -v getent >/dev/null 2>&1; then
        >&2 echo "ERROR: getent is required to resolve DHCP NTP hostnames, but it is not available."
        >&2 echo "Set DHCP_NTP_SERVERS to IPv4 addresses when getent is unavailable."
        return 1
    fi

    resolved=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')
    if ! is_ipv4 "$resolved"; then
        resolved=$(getent hosts "$host" 2>/dev/null | awk '$1 ~ /^[0-9]+\./ {print $1; exit}')
    fi
    if is_ipv4 "$resolved"; then
        printf '%s' "$resolved"
        return 0
    fi

    >&2 echo "ERROR: DHCP_NTP_SERVERS contains an entry that is not IPv4 and cannot be resolved: $host"
    return 1
}

is_ipv4_csv() {
    local csv="$1" entry seen=0

    [ -n "$csv" ] || return 1
    for entry in ${csv//,/ }; do
        [ -n "$entry" ] || continue
        is_ipv4 "$entry" || return 1
        seen=1
    done
    [ "$seen" = "1" ]
}

resolve_ntp_csv() {
    local ntp_servers="$1" ntp_server ntp_server_ip ntp_servers_csv=""

    if [ -z "$ntp_servers" ]; then
        printf '%s' ""
        return 0
    fi

    for ntp_server in ${ntp_servers//,/ }; do
        ntp_server_ip="$(resolve_ntp_server "$ntp_server")" || return 1
        if [ -z "$ntp_servers_csv" ]; then
            ntp_servers_csv="$ntp_server_ip"
        else
            ntp_servers_csv="$ntp_servers_csv,$ntp_server_ip"
        fi
    done

    printf '%s' "$ntp_servers_csv"
}

build_ntp_option() {
    local ntp_servers_csv

    ntp_servers_csv="$(resolve_ntp_csv "$DHCP_NTP_SERVERS")" || return 1
    if [ -z "$ntp_servers_csv" ]; then
        printf '%s' ""
        return 0
    fi

    # shellcheck disable=SC2089,SC2016 # JSON fragment is consumed by envsubst.
    printf ',\n          {\n            "name": "ntp-servers",\n            "data": "%s"\n          }' "$ntp_servers_csv"
}

# Kea always requires a real DDNS_TSIG_KEY (unlike PowerDNS, which falls back
# to a loopback-only, TSIG-off safe state) -- see docs/threat-model.md T12.
if secret_is_placeholder "$DDNS_TSIG_KEY"; then
    echo "ERROR: DDNS_TSIG_KEY must be set to the shared secret used by the PowerDNS containers."
    printf '%s\n' "Generate one with: openssl rand -base64 32 | tr -d '\\n'"
    exit 1
fi

# Kea's lease_cmds hook (needed for lease4-del, used by the Admin UI's
# release-lease route and by this container's own upgrade migration below)
# ships under Debian's arch-specific multiarch lib directory, e.g.
# /usr/lib/x86_64-linux-gnu on amd64 vs /usr/lib/aarch64-linux-gnu on arm64
# (this service is built for both, see RELEASE_PLATFORMS). Resolve the actual
# installed path at startup instead of hardcoding either one, so the same
# template/migration works unmodified on every built architecture.
KEA_LEASE_CMDS_HOOK_PATH="$(find /usr/lib -maxdepth 5 -name libdhcp_lease_cmds.so 2>/dev/null | head -n1)"
if [ -z "$KEA_LEASE_CMDS_HOOK_PATH" ]; then
    echo "ERROR: libdhcp_lease_cmds.so not found under /usr/lib. Kea's lease_cmds hook is required for lease4-del (used by the Admin UI's release-lease route)."
    exit 1
fi

export DHCP_MAX_LEASE_TIME=$((DHCP_LEASE_TIME * 2))
export DHCP_SUBNET DHCP_RANGE_START DHCP_RANGE_END DHCP_GATEWAY DHCP_DOMAIN DHCP_LEASE_TIME DHCP_NTP_SERVERS DHCP_DNS_PRIMARY DHCP_DNS_SECONDARY KEA_CTRL_TOKEN DHCP_MAX_LEASE_TIME DHCP_DNS_SERVER_IP DHCP_DNS_SERVER_IP_SSL DHCP_DDNS_PORT KEA_CTRL_HOST KEA_LEASE_CMDS_HOOK_PATH DHCP_DDNS_ENABLED

# shellcheck disable=SC2016
ENVSUBST_VARS='${DHCP_SUBNET}${DHCP_RANGE_START}${DHCP_RANGE_END}${DHCP_GATEWAY}${DHCP_DOMAIN}${DHCP_LEASE_TIME}${DHCP_NTP_OPTION}${DHCP_DNS_PRIMARY}${DHCP_DNS_SECONDARY}${KEA_CTRL_TOKEN}${DHCP_MAX_LEASE_TIME}${DDNS_TSIG_KEY}${DHCP_DNS_SERVER_IP}${DHCP_DNS_SERVER_IP_SSL}${DHCP_DDNS_PORT}${KEA_CTRL_HOST}${KEA_LEASE_CMDS_HOOK_PATH}${DHCP_DDNS_ENABLED}'

render_kea_config() {
    local template=$1 target=$2

    envsubst "$ENVSUBST_VARS" < "$template" > "$target"
}

render_kea_dhcp4_config() {
    local template=$1 target=$2 dhcp_ntp_option

    dhcp_ntp_option="$(build_ntp_option)" || return 1
    DHCP_NTP_OPTION="$dhcp_ntp_option" envsubst "$ENVSUBST_VARS" < "$template" > "$target"
}

# Generate runtime configs from templates on first boot only.
# Once generated, the files live on the mounted volume and survive restarts.
# Changes via UI (config-set + config-write) update /var/lib/kea/kea-dhcp4.conf directly.
for name in kea-dhcp4 kea-ctrl-agent kea-dhcp-ddns; do
    TEMPLATE="/etc/kea/${name}.conf.template"
    RUNTIME="/var/lib/kea/${name}.conf"
    if [ ! -f "$RUNTIME" ]; then
        if [ "$name" = "kea-dhcp4" ]; then
            render_kea_dhcp4_config "$TEMPLATE" "$RUNTIME"
        else
            render_kea_config "$TEMPLATE" "$RUNTIME"
        fi
        echo "First boot: generated $RUNTIME"
    fi
done

build_ntp_migration_map() {
    local runtime="$1" data resolved map_file map_next

    map_file="$(mktemp)"
    printf '{}\n' > "$map_file"

    while IFS= read -r data; do
        [ -n "$data" ] || continue
        is_ipv4_csv "$data" && continue

        resolved="$(resolve_ntp_csv "$data")" || {
            rm -f "$map_file"
            return 1
        }

        map_next="$(mktemp)"
        if ! jq --arg key "$data" --arg value "$resolved" '. + {($key): $value}' "$map_file" > "$map_next"; then
            rm -f "$map_file" "$map_next"
            return 1
        fi
        mv "$map_next" "$map_file"
    done < <(
        jq -r '
          ..
          | objects
          | select(.name == "ntp-servers")
          | select((if has("csv-format") then .["csv-format"] else true end) == true)
          | .data // empty
        ' "$runtime" | sort -u
    )

    cat "$map_file"
    rm -f "$map_file"
}

migrate_dhcp4_config() {
    local runtime="$1" next ntp_migration_map

    if ! ntp_migration_map="$(build_ntp_migration_map "$runtime")"; then
        echo "ERROR: failed to resolve legacy NTP server values in $runtime."
        exit 1
    fi
    next="$(mktemp)"
    # kea_log_file: central logging pipeline (#633). Existing installs'
    # persisted kea-dhcp4.conf (on the /var/lib/kea volume, so it survives
    # upgrades untouched otherwise) only has the "stdout" output-option this
    # migration originally wrote -- the jq filter below adds the file output
    # alongside it (not in place of it) for both the "kea-dhcp4" and
    # "kea-dhcp4.dhcp4" loggers, same dual-output shape as a first-boot
    # render of the template. Comments cannot live in kea-dhcp4.conf.template
    # itself (or the runtime JSON this migration writes) because both must
    # stay parseable by `jq` -- see migrate_dhcp4_config's own callers and
    # tests/bats/*kea* for the parseability contract this relies on.
    #
    # ddns_enabled (issue #1076): the dhcp-ddns block is merged as
    # `{defaults incl. enable-updates: $ddns_enabled} + (existing // {})`, so
    # the RHS (an install's persisted dhcp-ddns, including any value the Admin
    # UI's DDNS toggle wrote) always WINS over this default. The $ddns_enabled
    # default therefore only decides the value for a config that has no
    # dhcp-ddns.enable-updates at all (effectively a fresh render); it never
    # overrides an existing install's persisted choice. This is what keeps the
    # UI toggle durable across restarts and keeps DHCP_DDNS_ENABLED a
    # first-boot/default-only control.
    if ! jq \
        --arg domain "$DHCP_DOMAIN" \
        --argjson lease_time "$DHCP_LEASE_TIME" \
        --argjson max_lease_time "$DHCP_MAX_LEASE_TIME" \
        --argjson ntp_migration_map "$ntp_migration_map" \
        --arg lease_cmds_hook_path "$KEA_LEASE_CMDS_HOOK_PATH" \
        --arg kea_log_file "/var/log/kea/kea-dhcp4.log" \
        --argjson ddns_enabled "$DHCP_DDNS_ENABLED" \
        '
        def is_ipv4:
          type == "string"
          and test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$")
          and (
            split(".")
            | length == 4
            and all(.[]; test("^[0-9]+$") and (tonumber <= 255))
          );

        def is_ipv4_csv:
          type == "string"
          and length > 0
          and (split(",") | all(.[]; (gsub("^\\s+|\\s+$"; "") | is_ipv4)));

        def migrate_ntp_option:
          if type == "object"
              and .name == "ntp-servers"
              and ((if has("csv-format") then .["csv-format"] else true end) == true)
              and ((.data // "") | is_ipv4_csv | not) then
            .data = ($ntp_migration_map[.data] // .data)
          else
            .
          end;

        def walk(f):
          . as $in
          | if type == "object" then
              reduce keys_unsorted[] as $key
                ({}; . + {($key): ($in[$key] | walk(f))})
              | f
            elif type == "array" then
              map(walk(f)) | f
            else
              f
            end;

        .Dhcp4["control-socket"]["socket-name"] = "/run/kea/kea4.sock"
        |
        .Dhcp4["hooks-libraries"] = ((.Dhcp4["hooks-libraries"] // []) | if any(.[]; .library == $lease_cmds_hook_path) then . else . + [{"library": $lease_cmds_hook_path}] end)
        |
        # Deliberately disabled default, not an oversight -- see the Kea DHCP
        # section of docs/architecture-ng.md for the full reasoning.
        # Kea has shipped multi-threaded packet processing enabled by default
        # since 2.4.0 for high-throughput ISP-scale deployments, which this
        # single LAN/lab-scale subnet has no need for, while adding real
        # concurrency surface against the lease_cmds hook and the DDNS-
        # forwarding path just below. The `// {}` merge still lets an operator
        # who explicitly sets "multi-threading" in their own config override
        # this default.
        .Dhcp4["multi-threading"] = ({"enable-multi-threading": false} + (.Dhcp4["multi-threading"] // {}))
        | .Dhcp4["dhcp-ddns"] = ({
            "enable-updates": $ddns_enabled,
            "server-ip": "127.0.0.1",
            "server-port": 53001,
            "sender-ip": "127.0.0.1",
            "max-queue-size": 1024,
            "ncr-protocol": "UDP",
            "ncr-format": "JSON"
          } + (.Dhcp4["dhcp-ddns"] // {}))
        | .Dhcp4["ddns-send-updates"] = (.Dhcp4["ddns-send-updates"] // true)
        | .Dhcp4["ddns-override-no-update"] = (.Dhcp4["ddns-override-no-update"] // true)
        | .Dhcp4["ddns-override-client-update"] = (.Dhcp4["ddns-override-client-update"] // true)
        | .Dhcp4["ddns-replace-client-name"] = (.Dhcp4["ddns-replace-client-name"] // "when-present")
        | .Dhcp4["ddns-generated-prefix"] = (.Dhcp4["ddns-generated-prefix"] // "dhcp")
        | .Dhcp4["ddns-qualifying-suffix"] = (.Dhcp4["ddns-qualifying-suffix"] // $domain)
        | .Dhcp4.subnet4 = ((.Dhcp4.subnet4 // []) | map(
            .["valid-lifetime"] = (.["valid-lifetime"] // .["default-lease-time"] // $lease_time)
            | .["max-valid-lifetime"] = (.["max-valid-lifetime"] // .["max-lease-time"] // $max_lease_time)
            | del(.["default-lease-time"], .["max-lease-time"])
          ))
        | walk(migrate_ntp_option)
        | .Dhcp4.loggers = ((.Dhcp4.loggers // []) as $loggers
          | (if any($loggers[]; .name == "kea-dhcp4.dhcp4") then
              $loggers | map(if .name == "kea-dhcp4.dhcp4" then .severity = "ERROR" else . end)
            else
              $loggers + [{
                "name": "kea-dhcp4.dhcp4",
                "output-options": [{"output": "stdout"}],
                "severity": "ERROR",
                "debuglevel": 0
              }]
            end)
          | map(
              if (.name == "kea-dhcp4" or .name == "kea-dhcp4.dhcp4") then
                .["output-options"] = ((.["output-options"] // [{"output": "stdout"}]) as $opts
                  | if any($opts[]; .output == $kea_log_file) then $opts
                    else $opts + [{"output": $kea_log_file}]
                    end)
              else . end
            ))
        ' \
        "$runtime" > "$next"; then
        rm -f "$next"
        echo "ERROR: failed to migrate $runtime for Kea DDNS, lease lifetime, or NTP settings."
        exit 1
    fi

    if ! cmp -s "$next" "$runtime"; then
        mv "$next" "$runtime"
        echo "Updated $runtime with Kea DDNS, lease lifetime, and NTP settings"
    else
        rm -f "$next"
    fi
}

migrate_dhcp4_config /var/lib/kea/kea-dhcp4.conf

# The Control Agent config is not modified by the UI, but it is persisted on
# the Kea data volume. Regenerate it when KEA_CTRL_TOKEN or KEA_CTRL_HOST
# changes so upgrades do not leave the API using stale credentials.
#
# This is a full-file `cmp`, not a field-level merge, by design: unlike
# kea-dhcp4.conf above (which the Admin UI mutates live, so
# migrate_dhcp4_config() merges narrowly to preserve that live state), this
# file has no UI-mutated state to protect, and full regeneration is what lets
# a future template change (new auth default, logger, socket path) reach
# already-deployed installs on upgrade -- the same reason kea-dhcp-ddns.conf
# below is fully regenerated rather than merged. The tradeoff: any manual
# edit made directly to the persisted /var/lib/kea/kea-ctrl-agent.conf (e.g.
# added TLS settings or an extra authenticated client) is silently discarded
# on the next container start. Do not hand-edit this file; per #651, it is
# treated as fully generated, like every other file this entrypoint renders.
CTRL_AGENT_TEMPLATE="/etc/kea/kea-ctrl-agent.conf.template"
CTRL_AGENT_RUNTIME="/var/lib/kea/kea-ctrl-agent.conf"
CTRL_AGENT_NEXT="$(mktemp)"
render_kea_config "$CTRL_AGENT_TEMPLATE" "$CTRL_AGENT_NEXT"
if ! cmp -s "$CTRL_AGENT_NEXT" "$CTRL_AGENT_RUNTIME"; then
    mv "$CTRL_AGENT_NEXT" "$CTRL_AGENT_RUNTIME"
    echo "Updated $CTRL_AGENT_RUNTIME from current Kea Control Agent settings"
else
    rm -f "$CTRL_AGENT_NEXT"
fi

# The DHCP-DDNS daemon config is not edited by the UI. Regenerate it on start
# so upgrades can fix D2 schema or target changes without touching DHCP subnets.
#
# services/dhcp/kea-dhcp-ddns.conf's forward-ddns/reverse-ddns "name" fields
# (issue #706) carry a literal trailing dot ("${DHCP_DOMAIN}.", each reverse
# zone name below) that can't be documented inline in that file itself: it
# is validated as plain JSON elsewhere (tests/bats/dhcp_kea_config_generation.bats
# runs `jq empty` on the rendered output), and Kea's own config format,
# while it does tolerate `//`/`/* */` comments as an extension, would break
# that strict-JSON check. Kea's D2 daemon matches an outgoing update's
# target FQDN against each ddns-domains "name" by treating it as a DNS-name
# suffix, not a substring -- without the trailing dot, "name" is parsed as a
# bare, non-fully-qualified label and D2 never finds a match for any real
# (dotted, fully-qualified) FQDN it tries to update, silently discarding
# every forward/reverse change with a "no match" error instead of sending
# it (confirmed empirically against a real Kea 2.6.3 D2 instance -- issue
# #706's DDNS-follow-through test is what first exercised this path
# end-to-end). Kea's own config parser does not add the trailing dot
# itself, so it must be literal in the template.
#
# reverse-ddns.ddns-domains (issue #768): this used to be a single entry
# named the literal catch-all "in-addr.arpa." -- but Kea D2 requires "name"
# to match one real, existing zone (it cannot express "any of these
# dynamically-selected per-octet zones" in one entry), and PowerDNS never
# creates a zone with that exact literal name; it only ever creates the
# narrower private-range subzones services/dns/entrypoint.sh's
# PRIVATE_REVERSE_ZONES list creates (e.g. "31.172.in-addr.arpa."). Every
# reverse/PTR DDNS update was therefore rejected by PowerDNS with "Can't
# determine backend for domain 'in-addr.arpa'" (RCODE 9, NOTAUTH),
# unconditionally, for any octet -- confirmed against a real Kea 2.6.3 +
# PowerDNS 5.2.11 stack. The fix mirrors PRIVATE_REVERSE_ZONES exactly: one
# ddns-domains entry per IPv4 private-range subzone PowerDNS actually hosts
# (the same 18 zones, verbatim), each targeting the same dns-servers as
# forward-ddns above, so Kea's D2 can match a lease's reverse FQDN (e.g.
# "50.1.168.192.in-addr.arpa.") against the correct, real zone by suffix.
# IPv6 reverse zones (c.f.ip6.arpa./d.f.ip6.arpa.) are deliberately excluded
# here -- this project's Kea config is Dhcp4-only, no DHCPv6, so D2 never
# generates an IPv6 PTR update in the first place. If
# services/dns/entrypoint.sh's PRIVATE_REVERSE_ZONES list ever changes, this
# list must be updated to match (tests/bats/dhcp_kea_config_generation.bats
# guards the two staying in sync).
DDNS_TEMPLATE="/etc/kea/kea-dhcp-ddns.conf.template"
DDNS_RUNTIME="/var/lib/kea/kea-dhcp-ddns.conf"
DDNS_NEXT="$(mktemp)"
envsubst "$ENVSUBST_VARS" < "$DDNS_TEMPLATE" > "$DDNS_NEXT"
if ! cmp -s "$DDNS_NEXT" "$DDNS_RUNTIME"; then
    mv "$DDNS_NEXT" "$DDNS_RUNTIME"
    echo "Updated $DDNS_RUNTIME from current Kea DHCP-DDNS settings"
else
    rm -f "$DDNS_NEXT"
fi

# Restrict Kea Control Agent API (port 8000) to Docker-internal networks.
# Without this, network_mode:host exposes the API on all LAN interfaces.
if command -v iptables >/dev/null 2>&1; then
    KEA_CTRL_CHAIN="LANCACHE_KEA_CTRL"

    # Create or reset the managed chain. Keeping the chain stable avoids
    # failures when duplicate jump rules from previous starts still reference it.
    iptables -N "$KEA_CTRL_CHAIN" 2>/dev/null || true
    iptables -F "$KEA_CTRL_CHAIN"

    # Remove every managed jump and every legacy inline rule from old
    # implementations, so hosts with pre-existing duplicates self-heal.
    while iptables -D INPUT -p tcp --dport 8000 -j "$KEA_CTRL_CHAIN" 2>/dev/null; do
        :
    done
    while iptables -D INPUT -j "$KEA_CTRL_CHAIN" 2>/dev/null; do
        :
    done
    while iptables -D INPUT -p tcp --dport 8000 -s 172.16.0.0/12 -j ACCEPT 2>/dev/null; do
        :
    done
    while iptables -D INPUT -p tcp --dport 8000 -s 127.0.0.0/8 -j ACCEPT 2>/dev/null; do
        :
    done
    while iptables -D INPUT -p tcp --dport 8000 -j DROP 2>/dev/null; do
        :
    done

    # Insert one scoped jump near the top of INPUT before broader accept rules.
    iptables -I INPUT 1 -p tcp --dport 8000 -j "$KEA_CTRL_CHAIN"

    # Rebuild intended policy in the managed chain (order matters: ACCEPT before DROP).
    iptables -A "$KEA_CTRL_CHAIN" -s 172.16.0.0/12 -j ACCEPT
    iptables -A "$KEA_CTRL_CHAIN" -s 127.0.0.0/8 -j ACCEPT
    iptables -A "$KEA_CTRL_CHAIN" -j DROP

    echo "Kea Control Agent API restricted to Docker-internal access (using managed chain)"
fi

# ── Validate Kea DHCP4 Config and Attempt Rollback (#763) ──────────────────
# Before starting kea-dhcp4, validate the generated config with `kea-dhcp4 -t`.
# If validation fails, look for known-good snapshots under
# /var/lib/kea/config-snapshots/<id>/dhcp4.json (sorted newest-first),
# test each one, and use the first that validates. If no snapshot validates
# (or none exist), enter Kea rescue mode: skip starting kea-dhcp4 but do
# still start kea-ctrl-agent and kea-dhcp-ddns so the container remains
# reachable and the healthcheck (which checks for kea-dhcp4 running) correctly
# reports unhealthy.

# list_kea_snapshot_ids <snapshot_root>
# Lists snapshot ids under snapshot_root, oldest first, one per line.
# Empty output when the directory doesn't exist yet. Excludes .staging.* entries.
list_kea_snapshot_ids() {
    local snapshot_root="$1"
    [ -d "$snapshot_root" ] || return 0
    find "$snapshot_root" -mindepth 1 -maxdepth 1 -type d -not -name '.staging.*' -printf '%f\n' 2>/dev/null | sort
}

# _kea_validate_dhcp4_config <config_file>
# Tests kea-dhcp4.conf syntax via `kea-dhcp4 -t <config_file>`.
# Returns 0 if the config is valid, 1 if invalid.
_kea_validate_dhcp4_config() {
    local config_file="$1"
    if kea-dhcp4 -t "$config_file" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Attempt to validate the current/generated kea-dhcp4.conf
KEAD_CONF_FILE="/var/lib/kea/kea-dhcp4.conf"
# SNAPSHOT_FOUND=1 means "kea-dhcp4.conf is known-good, proceed normally" --
# defaulted here (not just inside the failure branch below) so the
# rescue-mode check after this block never reads an unset/empty
# $SNAPSHOT_FOUND (`[ "" -eq 0 ]` is a bash syntax error, not a false
# result, and would otherwise print a spurious error on every healthy start).
SNAPSHOT_FOUND=1
if _kea_validate_dhcp4_config "$KEAD_CONF_FILE"; then
    echo "Kea DHCP4 config is valid; proceeding with normal startup."
else
    echo "ERROR: generated kea-dhcp4.conf failed validation (kea-dhcp4 -t)." >&2
    echo "ERROR: attempting rollback to the newest known-good snapshot instead of starting with an invalid config." >&2

    # Back up the invalid candidate before trying any snapshot, mirroring this
    # file's own generic known-good-snapshot contract (kgs_snapshot_apply's
    # documented guarantee, above): if every snapshot also fails, the live
    # file must be restored to exactly what was live before this rollback
    # attempt (the actual rejected candidate an operator needs to see to
    # diagnose the root cause), never left holding some other, unrelated
    # rejected snapshot's leftover content.
    KEAD_CONF_BACKUP="$(mktemp)"
    cp "$KEAD_CONF_FILE" "$KEAD_CONF_BACKUP" 2>/dev/null || true

    # Look for known-good snapshots, newest-first. mapfile (not unquoted
    # command substitution) matches setup.sh's own list_kea_snapshot_ids
    # caller and avoids shellcheck SC2207's word-splitting warning.
    SNAPSHOT_ROOT="/var/lib/kea/config-snapshots"
    SNAPSHOT_IDS=()
    while IFS= read -r _id; do
        [ -n "$_id" ] && SNAPSHOT_IDS+=("$_id")
    done < <(list_kea_snapshot_ids "$SNAPSHOT_ROOT" | sort -r)

    SNAPSHOT_FOUND=0
    for id in "${SNAPSHOT_IDS[@]}"; do
        SNAPSHOT_FILE="${SNAPSHOT_ROOT}/${id}/dhcp4.json"
        if [ ! -f "$SNAPSHOT_FILE" ]; then
            echo "WARNING: known-good snapshot $id is missing its dhcp4.json; skipping." >&2
            continue
        fi

        # Copy the snapshot onto the live config file
        if ! cp "$SNAPSHOT_FILE" "$KEAD_CONF_FILE"; then
            echo "WARNING: failed to copy snapshot $id onto live config; skipping." >&2
            continue
        fi

        # Validate the restored config
        if _kea_validate_dhcp4_config "$KEAD_CONF_FILE"; then
            echo "[known-good-snapshot][kea][SELECT] selected known-good snapshot $id for rollback" >&2
            echo "WARNING: Kea DHCP4 is starting from known-good snapshot ${id}, NOT the newly generated config." >&2
            echo "WARNING: check DHCP_SUBNET/DHCP_RANGE_*/DHCP_GATEWAY and restart to pick up the intended change." >&2
            SNAPSHOT_FOUND=1
            break
        else
            echo "[known-good-snapshot][kea][REJECT] rejected known-good snapshot $id: failed validation" >&2
        fi
    done

    if [ "$SNAPSHOT_FOUND" -eq 0 ]; then
        # Restore the original rejected candidate (not a stale rejected
        # snapshot from the loop above) so an operator inspecting
        # kea-dhcp4.conf during rescue mode sees the actual thing that
        # failed, not an unrelated historical snapshot.
        cp "$KEAD_CONF_BACKUP" "$KEAD_CONF_FILE" 2>/dev/null || true
        echo "[lancache-dhcp][rescue-mode] No known-good kea-dhcp4.conf snapshot available; refusing to start kea-dhcp4. Container will stay running for 'docker exec' access -- fix the underlying cause (DHCP_SUBNET / env var / template) and restart. See docs/known-good-config-snapshots.md." >&2
    fi
    rm -f "$KEAD_CONF_BACKUP"
fi

echo "Starting Kea DHCPv4 server (Subnet: $DHCP_SUBNET, Pool: $DHCP_RANGE_START - $DHCP_RANGE_END)..."
if [ "$SNAPSHOT_FOUND" -eq 0 ] && ! _kea_validate_dhcp4_config "$KEAD_CONF_FILE"; then
    echo "[lancache-dhcp][rescue-mode] Skipping kea-dhcp4 startup due to config validation failure (rescue mode active)."
    # DHCP_PID is intentionally not set so the trap below doesn't try to kill it
    # and the final `wait` at the bottom keeps the container alive
else
    kea-dhcp4 -c /var/lib/kea/kea-dhcp4.conf &
    DHCP_PID=$!
fi

echo "Starting Kea Control Agent on $KEA_CTRL_HOST:8000..."
kea-ctrl-agent -c /var/lib/kea/kea-ctrl-agent.conf &
AGENT_PID=$!

if command -v kea-dhcp-ddns &> /dev/null; then
    echo "Starting Kea DHCP DDNS server..."
    kea-dhcp-ddns -c /var/lib/kea/kea-dhcp-ddns.conf &
    DDNS_PID=$!
fi

trap '
    # Kill all background processes (DHCP_PID may not be set in rescue mode)
    kill ${DHCP_PID:-} $AGENT_PID ${DDNS_PID:-} 2>/dev/null || true

    # Clean up iptables chain if it exists
    if command -v iptables >/dev/null 2>&1; then
        # Remove all managed jump rules from INPUT. Include the old unscoped
        # form for compatibility with previous entrypoint versions.
        while iptables -D INPUT -p tcp --dport 8000 -j LANCACHE_KEA_CTRL 2>/dev/null; do
            :
        done
        while iptables -D INPUT -j LANCACHE_KEA_CTRL 2>/dev/null; do
            :
        done

        # Flush and delete the managed chain
        iptables -F LANCACHE_KEA_CTRL 2>/dev/null || true
        iptables -X LANCACHE_KEA_CTRL 2>/dev/null || true
    fi
' EXIT TERM
wait
