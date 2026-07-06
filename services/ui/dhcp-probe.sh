#!/bin/sh
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# DHCP probe helper: performs both the broadcast conflict check (nmap) and a
# real client dry-run (dhclient) so the UI can distinguish "no foreign server
# seen" from "client path actually works".
set -eu

tmpdir="$(mktemp -d)"
cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

detect_iface() {
    while read -r iface destination _rest; do
        [ "$iface" = "Iface" ] && continue
        if [ "$destination" = "00000000" ] && [ "$iface" != "lo" ]; then
            printf '%s\n' "$iface"
            return 0
        fi
    done < /proc/net/route

    return 1
}

last_non_empty_line() {
    sed -n '/./p' "$1" | sed -n '$p'
}

echo "__LANCACHE_DHCP_PROBE_START__ $(date +%s%N)"

echo "__LANCACHE_DHCP_CONFLICT_START__"
nmap_out="$tmpdir/nmap.out"
if ! nmap --script broadcast-dhcp-discover --script-args broadcast-dhcp-discover.timeout=5 >"$nmap_out" 2>&1; then
    :
fi
cat "$nmap_out"
conflict_ip="$(sed -n 's/^[|_[:space:]]*Server Identifier:[[:space:]]*//p' "$nmap_out" | sed -n '1p')"
if [ -n "$conflict_ip" ]; then
    printf '__LANCACHE_DHCP_CONFLICT_RESULT__ found %s\n' "$conflict_ip"
elif [ -s "$nmap_out" ]; then
    printf '__LANCACHE_DHCP_CONFLICT_RESULT__ not_found\n'
else
    printf '__LANCACHE_DHCP_CONFLICT_RESULT__ unavailable no-nmap-output\n'
fi

echo "__LANCACHE_DHCP_CLIENT_START__"
dhcp_iface="$(detect_iface || true)"
if [ -z "$dhcp_iface" ]; then
    printf '__LANCACHE_DHCP_CLIENT_RESULT__ unavailable no-default-interface\n'
    exit 0
fi

dhclient_out="$tmpdir/dhclient.out"
if dhclient -4 -1 -v -d -sf /bin/true -pf "$tmpdir/dhclient.pid" -lf "$tmpdir/dhclient.leases" "$dhcp_iface" >"$dhclient_out" 2>&1; then
    client_detail="dhclient succeeded on $dhcp_iface"
    cat "$dhclient_out"
    printf '__LANCACHE_DHCP_CLIENT_RESULT__ passed %s\n' "$client_detail"
else
    client_detail="$(last_non_empty_line "$dhclient_out")"
    if [ -z "$client_detail" ]; then
        client_detail="dhclient failed on $dhcp_iface"
    fi
    cat "$dhclient_out"
    printf '__LANCACHE_DHCP_CLIENT_RESULT__ failed %s\n' "$client_detail"
fi
