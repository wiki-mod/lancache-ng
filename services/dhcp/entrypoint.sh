#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Kea DHCP entrypoint. Validates required secrets, renders Kea config
# templates from env vars on first boot, migrates existing runtime configs
# (DDNS, lease lifetimes, NTP options) on upgrade, restricts the Control
# Agent API to Docker-internal networks via iptables, and starts the Kea
# DHCPv4, control-agent, and DHCP-DDNS processes.

set -e

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
: "${KEA_CTRL_TOKEN:=}"
: "${DDNS_TSIG_KEY:=}"
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

# Verify KEA_CTRL_TOKEN is set to a non-default secret.
case "$KEA_CTRL_TOKEN" in
    ""|"CHANGE_ME_KEA_CTRL_TOKEN"|"lancache-dhcp-secret"|"lancache-dhcp-dev-secret"|"lancache-dhcp-prod-secret")
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

case "$DDNS_TSIG_KEY" in
    ""|CHANGE_ME*|changeme*)
        echo "ERROR: DDNS_TSIG_KEY must be set to the shared secret used by the PowerDNS containers."
        printf '%s\n' "Generate one with: openssl rand -base64 32 | tr -d '\\n'"
        exit 1
        ;;
esac

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
export DHCP_SUBNET DHCP_RANGE_START DHCP_RANGE_END DHCP_GATEWAY DHCP_DOMAIN DHCP_LEASE_TIME DHCP_NTP_SERVERS DHCP_DNS_PRIMARY DHCP_DNS_SECONDARY KEA_CTRL_TOKEN DHCP_MAX_LEASE_TIME DHCP_DNS_SERVER_IP DHCP_DNS_SERVER_IP_SSL DHCP_DDNS_PORT KEA_CTRL_HOST KEA_LEASE_CMDS_HOOK_PATH

# shellcheck disable=SC2016
ENVSUBST_VARS='${DHCP_SUBNET}${DHCP_RANGE_START}${DHCP_RANGE_END}${DHCP_GATEWAY}${DHCP_DOMAIN}${DHCP_LEASE_TIME}${DHCP_NTP_OPTION}${DHCP_DNS_PRIMARY}${DHCP_DNS_SECONDARY}${KEA_CTRL_TOKEN}${DHCP_MAX_LEASE_TIME}${DDNS_TSIG_KEY}${DHCP_DNS_SERVER_IP}${DHCP_DNS_SERVER_IP_SSL}${DHCP_DDNS_PORT}${KEA_CTRL_HOST}${KEA_LEASE_CMDS_HOOK_PATH}'

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
    if ! jq \
        --arg domain "$DHCP_DOMAIN" \
        --argjson lease_time "$DHCP_LEASE_TIME" \
        --argjson max_lease_time "$DHCP_MAX_LEASE_TIME" \
        --argjson ntp_migration_map "$ntp_migration_map" \
        --arg lease_cmds_hook_path "$KEA_LEASE_CMDS_HOOK_PATH" \
        --arg kea_log_file "/var/log/kea/kea-dhcp4.log" \
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
        .Dhcp4["multi-threading"] = ({"enable-multi-threading": false} + (.Dhcp4["multi-threading"] // {}))
        | .Dhcp4["dhcp-ddns"] = ({
            "enable-updates": true,
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
# (issue #706) carry a literal trailing dot ("${DHCP_DOMAIN}.",
# "in-addr.arpa.") that can't be documented inline in that file itself: it
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

echo "Starting Kea DHCPv4 server (Subnet: $DHCP_SUBNET, Pool: $DHCP_RANGE_START - $DHCP_RANGE_END)..."
kea-dhcp4 -c /var/lib/kea/kea-dhcp4.conf &
DHCP_PID=$!

echo "Starting Kea Control Agent on $KEA_CTRL_HOST:8000..."
kea-ctrl-agent -c /var/lib/kea/kea-ctrl-agent.conf &
AGENT_PID=$!

if command -v kea-dhcp-ddns &> /dev/null; then
    echo "Starting Kea DHCP DDNS server..."
    kea-dhcp-ddns -c /var/lib/kea/kea-dhcp-ddns.conf &
    DDNS_PID=$!
fi

trap '
    # Kill all background processes
    kill $DHCP_PID $AGENT_PID ${DDNS_PID:-} 2>/dev/null || true

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
