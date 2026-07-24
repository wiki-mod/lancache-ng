#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Shared helper: turns a services/dns/cdn-domains.txt entry into a DNS-legal
# probe name for scripts/full-setup-client-simulation.sh's live `dig` checks
# (issue #1140). Per AG-OP-015 (AGENTS.md's "Domain scope semantics" rule), a
# leading-dot entry such as ".steamcontent.com" is an explicit wildcard-only
# scope: it matches *.steamcontent.com (see services/dns/entrypoint.sh's RPZ
# zone generation, which emits a "*.<domain>" record and deliberately no
# bare-root record for such an entry), not the bare apex "steamcontent.com"
# itself. `dig` rejects the literal leading-dot string outright as an
# illegal empty-label name ("is not a legal name (empty label)"), so
# querying it verbatim fails every run regardless of whether the DNS spoof
# itself is correct. Substituting a real "full-setup-test." subdomain label
# keeps the probe a name the wildcard scope actually answers for, while
# leaving a bare (non-dot) entry -- an exact-match, non-wildcard scope per
# the same rule -- unchanged, since only its own literal name is ever
# answered for that kind of entry.
#
# Pure function, no top-level executable code: sourced directly by
# scripts/full-setup-client-simulation.sh and by
# tests/bats/full_setup_client_simulation_domain.bats, mirroring
# scripts/lib/ghcr-retry.sh's sourcing convention.

resolve_full_setup_probe_domain() {
    local domain="$1"
    if [[ "$domain" == .* ]]; then
        printf '%s' "full-setup-test${domain}"
    else
        printf '%s' "$domain"
    fi
}
