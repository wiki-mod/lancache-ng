#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Parser for ISC dhclient .leases files (issue #448). Pure functions, no
# top-level executable code, so this can be sourced directly both by
# scripts/dhcp-kea-lease-flow-simulation.sh (the real, opt-in Kea
# lease-flow test) and by tests/bats/dhcp_lease_flow_parsing.bats (fast,
# Docker-free unit coverage of the parsing logic against canned fixtures).
#
# dhclient.leases is a sequence of `lease { ... }` blocks, oldest first, one
# appended per renewal/rebind. Only the LAST block reflects the current,
# active lease -- earlier blocks are historical and must be ignored.
#
# This intentionally parses dhclient's own lease file rather than scraping
# `dhclient -v -d` stdout: the leases file is dhclient's own structured,
# stable-format record of exactly which options the server returned,
# independent of verbose-logging wording that could change between ISC
# dhcp-client versions.

# dhcp_lease_extract_last_block <leases_file>
# Prints just the text of the last `lease { ... }` block in <leases_file>,
# or nothing (exit 1) if the file has no complete lease block at all.
dhcp_lease_extract_last_block() {
    local leases_file="$1"

    [ -f "$leases_file" ] || return 1

    # awk keeps overwriting `block` with each new lease{...} it finds, so
    # after the full file is read it holds only the last (most recent) one.
    awk '
        /^lease[[:space:]]*\{/ { in_block = 1; block = "" }
        in_block { block = block $0 "\n" }
        /^\}/ { if (in_block) { last_block = block }; in_block = 0 }
        END { printf "%s", last_block }
    ' "$leases_file"
}

# dhcp_lease_parse_latest <leases_file>
# Parses the last lease block and prints one shell-safe `KEY=value` line per
# recognized field to stdout (consumed via `eval "$(...)"` or a `while read`
# loop by callers). Unrecognized/unset fields are simply absent from the
# output -- callers must not assume every key is always present (e.g. a
# subnet with no NTP option configured has no ntp_servers line at all).
# Returns 1 if the file has no lease block to parse.
dhcp_lease_parse_latest() {
    local leases_file="$1" block

    block="$(dhcp_lease_extract_last_block "$leases_file")" || return 1
    [ -n "$block" ] || return 1

    printf '%s\n' "$block" | awk '
        function emit(key, value) {
            # DHCP option values (addresses, CSV lists, hostnames) never
            # contain a single quote, so no escaping is needed beyond
            # wrapping in one.
            printf "%s=\047%s\047\n", key, value
        }
        # value_after(line, prefix_regex_string): strips a leading keyword
        # prefix (e.g. "  option routers " or "  fixed-address ") and the
        # trailing semicolon, returning exactly the value in between --
        # including embedded spaces, so multi-token values (domain-search
        # lists, quoted hostnames) are not truncated the way field-index
        # splitting would truncate them.
        #
        # prefix_regex_string MUST be passed as a plain string (built with
        # sprintf/concatenation), never as a /.../ regex literal: awk passes
        # literal regex constants to a user function as the boolean result
        # of matching them against $0, not as the pattern text itself --
        # confirmed directly, and it silently corrupted digits in the
        # replacement (sub() then used the literal "0"/"1" as a regex).
        function value_after(line, prefix_regex_string,    v) {
            v = line
            sub(prefix_regex_string, "", v)
            sub(/;[[:space:]]*$/, "", v)
            return v
        }
        function strip_quotes(s) {
            gsub(/"/, "", s)
            return s
        }
        /^[[:space:]]*fixed-address[[:space:]]/ {
            emit("address", value_after($0, "^[[:space:]]*fixed-address[[:space:]]+"))
        }
        /^[[:space:]]*option routers[[:space:]]/ {
            emit("router", value_after($0, "^[[:space:]]*option[[:space:]]+routers[[:space:]]+"))
        }
        /^[[:space:]]*option dhcp-server-identifier[[:space:]]/ {
            emit("server_identifier", value_after($0, "^[[:space:]]*option[[:space:]]+dhcp-server-identifier[[:space:]]+"))
        }
        /^[[:space:]]*option domain-name-servers[[:space:]]/ {
            emit("dns_servers", value_after($0, "^[[:space:]]*option[[:space:]]+domain-name-servers[[:space:]]+"))
        }
        /^[[:space:]]*option ntp-servers[[:space:]]/ {
            emit("ntp_servers", value_after($0, "^[[:space:]]*option[[:space:]]+ntp-servers[[:space:]]+"))
        }
        /^[[:space:]]*option dhcp-lease-time[[:space:]]/ {
            emit("lease_time", value_after($0, "^[[:space:]]*option[[:space:]]+dhcp-lease-time[[:space:]]+"))
        }
        /^[[:space:]]*option domain-name[[:space:]]/ {
            emit("domain_name", strip_quotes(value_after($0, "^[[:space:]]*option[[:space:]]+domain-name[[:space:]]+")))
        }
        /^[[:space:]]*option domain-search[[:space:]]/ {
            emit("domain_search", strip_quotes(value_after($0, "^[[:space:]]*option[[:space:]]+domain-search[[:space:]]+")))
        }
        /^[[:space:]]*option subnet-mask[[:space:]]/ {
            emit("subnet_mask", value_after($0, "^[[:space:]]*option[[:space:]]+subnet-mask[[:space:]]+"))
        }
        /^[[:space:]]*option host-name[[:space:]]/ {
            emit("host_name", strip_quotes(value_after($0, "^[[:space:]]*option[[:space:]]+host-name[[:space:]]+")))
        }
    '
}

# dhcp_lease_field <parsed_output> <key>
# Convenience accessor: given the multi-line KEY='value' output of
# dhcp_lease_parse_latest, prints the value for <key> (empty if absent).
dhcp_lease_field() {
    local parsed="$1" key="$2" line

    while IFS= read -r line; do
        case "$line" in
            "${key}="*)
                line="${line#"${key}"=}"
                line="${line#\'}"
                line="${line%\'}"
                printf '%s' "$line"
                return 0
                ;;
        esac
    done <<<"$parsed"

    return 1
}
