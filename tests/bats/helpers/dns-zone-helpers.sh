#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that generates RPZ zones from domain lists, extracted from
# services/dns/entrypoint.sh. Used to test zone generation logic without
# running a full PowerDNS daemon.
#
# This function's body must be kept in sync by hand with the real RPZ
# generation loop in services/dns/entrypoint.sh's section 7 (this is a
# hand-extracted test copy, not a sourced file) -- including the
# _is_valid_domain/_normalize_domain validation call added for the #822
# pattern audit (a malformed or overly-broad cdn-domains.txt entry must not
# silently become an overly-broad RPZ wildcard rule). Requires
# scripts/lib/domain-validation.sh to already be sourced by the caller (see
# tests/bats/dns_zone_generation.bats's setup()).

generate_rpz_zone() {
    local domains_file="$1" output_file="$2" proxy_ip="$3" proxy_ipv6="${4:-}"
    local serial

    # Generate serial from current timestamp (last 10 digits)
    serial=$(date +%s | tail -c 11)

    # Preserve monotonic RPZ SOA serials: ensure serial doesn't go backwards
    if [ -f "$output_file" ]; then
        local old_serial
        old_serial=$(grep -oP '^\s*@\s+SOA\s+[^\s]+\s+[^\s]+\s+\K\d+' "$output_file" 2>/dev/null || echo 0)
        if [ "$serial" -le "$old_serial" ]; then
            serial=$(( old_serial + 1 ))
        fi
    fi

    # Generate the zone file with header and records
    {
        echo "\$ORIGIN rpz."
        echo "\$TTL 60"
        echo "@ SOA localhost. admin.rpz. $serial 3600 900 604800 60"
        echo "@ NS localhost."
        echo ""
        # For each domain, emit RPZ A (and AAAA if proxy_ipv6 is set) records for both the base
        # domain and its *.domain wildcard subdomain. Domains with a leading dot in the input
        # (wildcard-only marker) only emit wildcard records, not base-domain records.
        while IFS= read -r domain || [ -n "$domain" ]; do
            # Strip leading and trailing whitespace
            domain="${domain#"${domain%%[![:space:]]*}"}"
            domain="${domain%"${domain##*[![:space:]]}"}"
            # Skip empty lines and comments
            [[ -z "$domain" || "$domain" == \#* ]] && continue
            # Check if domain starts with . (wildcard-only flag)
            local is_wildcard_only=0
            if [[ "$domain" == .* ]]; then
                is_wildcard_only=1
                domain="${domain#.}"
            fi
            [[ -z "$domain" ]] && continue
            # Reject a malformed or overly-broad entry (bare TLD, single
            # label like "localhost", "*", control/special characters)
            # before it ever becomes an RPZ rule -- see
            # services/dns/entrypoint.sh's own comment on this same check.
            if ! _is_valid_domain "$domain"; then
                echo "[lancache-dns] WARNING: skipping invalid domain entry in RPZ zone: $domain" >&2
                continue
            fi
            domain="$(_normalize_domain "$domain")"
            [[ -z "$domain" ]] && continue
            # Emit records: base domain + wildcard (if not wildcard-only)
            if [ "$is_wildcard_only" -eq 0 ]; then
                printf "%s 60 IN A %s\n" "${domain}" "${proxy_ip}"
            fi
            printf "*.%s 60 IN A %s\n" "${domain}" "${proxy_ip}"
            if [ -n "$proxy_ipv6" ]; then
                if [ "$is_wildcard_only" -eq 0 ]; then
                    printf "%s 60 IN AAAA %s\n" "${domain}" "${proxy_ipv6}"
                fi
                printf "*.%s 60 IN AAAA %s\n" "${domain}" "${proxy_ipv6}"
            fi
        done < "$domains_file"
    } > "$output_file"
}
