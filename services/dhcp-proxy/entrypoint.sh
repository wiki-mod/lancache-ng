#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# dnsmasq DHCP proxy entrypoint. Validates required env vars, renders
# dnsmasq.conf.template via envsubst, validates the result and keeps a
# known-good configuration snapshot history (#415, see
# docs/known-good-config-snapshots.md), then starts dnsmasq in proxy mode.

set -e

# Central logging pipeline (#633): dnsmasq's own `log-facility=` directive
# (see dnsmasq.conf.template) points at a file under here; dnsmasq creates
# the file itself but not a missing parent directory, so this must exist
# before dnsmasq starts.
mkdir -p /var/log/lancache-dhcp-proxy

if [ -f /data/lancache-ui-settings.env ]; then
    # shellcheck disable=SC1091
    . /data/lancache-ui-settings.env
fi

# DHCP_SUBNET_START/DHCP_DNS_PRIMARY/UPSTREAM_DHCP_IP are required for a
# *working* dnsmasq proxy config, but must NOT hard-exit here (":?" aborts
# the script immediately, before the known-good snapshot rollback path
# below ever runs) -- a previously-validated snapshot may still exist and
# should be tried first. Left unset/blank, envsubst below renders an empty
# value into the template, which `dnsmasq --test` reliably rejects
# ("bad dhcp-range"/"bad dhcp-proxy address", confirmed live), so the
# existing validate-then-rollback flow already handles this correctly once
# it's actually allowed to run.
if [ -z "${DHCP_SUBNET_START:-}" ]; then
    echo "WARNING: DHCP_SUBNET_START is not set; the generated dnsmasq config will fail validation and this will attempt rollback to a known-good snapshot instead." >&2
fi
if [ -z "${DHCP_DNS_PRIMARY:-}" ]; then
    echo "WARNING: DHCP_DNS_PRIMARY is not set; the generated dnsmasq config will fail validation and this will attempt rollback to a known-good snapshot instead." >&2
fi
: "${DHCP_DNS_SECONDARY:=$DHCP_DNS_PRIMARY}"
if [ -z "${UPSTREAM_DHCP_IP:-}" ]; then
    echo "WARNING: UPSTREAM_DHCP_IP is not set; the generated dnsmasq config will fail validation and this will attempt rollback to a known-good snapshot instead." >&2
fi
: "${KEEP_KNOWN_GOOD_CONFIGS:=3}"
: "${DHCP_PROXY_CONFIG_SNAPSHOT_DIR:=/var/lib/lancache-dhcp-proxy/config-snapshots}"

# Issue #450: additional *optional* dnsmasq relay/proxy options. Every one of
# these defaults to empty/unset -- ProxyDHCP mode keeps working with only the
# four required vars above, exactly as before this issue. None of these are
# templated into dnsmasq.conf.template via envsubst: an unset value must
# produce *no line at all* (an empty `dhcp-option-pxe=3,` would itself be an
# invalid config), so they are appended conditionally below instead.
: "${DHCP_PROXY_INTERFACE:=}"
: "${DHCP_PROXY_ROUTER:=}"
: "${DHCP_NTP_SERVERS:=}"
: "${DHCP_PROXY_DOMAIN:=}"
: "${DHCP_PROXY_BOOT_FILENAME:=}"
: "${DHCP_PROXY_BOOT_SERVER:=}"
: "${DHCP_PROXY_CUSTOM_OPTIONS:=}"

# Issue #705: PXE boot-pointer support (`pxe-service`), separate from the
# #450 vars above. ALL of the above #450 options -- and the base
# dhcp-option-pxe=6 DNS injection this service has offered since before
# #450 -- ride the same ProxyDHCP/PXE reply dnsmasq sends to a client. That
# reply was confirmed (issue #705 investigation, real packets on a live
# runner) to NEVER be sent at all: dnsmasq's ProxyDHCP mode only replies to
# a DHCPDISCOVER when at least one `pxe-service` directive is configured --
# `dhcp-option-pxe`/`dhcp-boot` alone only decorate a reply that was never
# being sent in the first place. So every one of the vars above has been
# silently inert since #450 shipped, and stays inert unless the PXE vars
# below are also set. This is intentional, not a bug re-introduced here:
# `pxe-service` also being the first directive that makes dnsmasq answer
# ProxyDHCP requests at all is a real behavior change (an installation that
# previously saw dnsmasq never reply now sees it start replying, to every
# PXE-tagged client on the segment) that must stay opt-in rather than
# firing by default for every existing install that never asked for PXE
# support. See docs/dhcp-modes.md for the full explanation.
#
# DHCP_PROXY_PXE_BOOT_SERVER is the single external, operator-owned
# TFTP/boot server address shared by every architecture below (per the
# maintainer's #705 decision: lancache-ng only points at existing PXE/TFTP
# infrastructure, it does not host or serve boot files itself for v0.2.0).
# DHCP_PROXY_PXE_BOOT_FILENAME_BIOS covers legacy BIOS clients (dnsmasq
# architecture tag x86PC, client-system-architecture 0 -- still the most
# common real-world PXE client). DHCP_PROXY_PXE_BOOT_FILENAME_UEFI covers
# the modern 64-bit UEFI client set: x86-64_EFI (client-system-architecture
# 7, the dominant UEFI PXE client on both desktops and servers) and
# ARM64_EFI (architecture 11, UEFI ARM boards/servers -- an increasingly
# common second case, e.g. Raspberry Pi 4/5 UEFI firmware). One shared
# filename is deliberately used for both UEFI architecture codes rather
# than a filename per code: this assumes the operator's own external boot
# server serves a single self-selecting artifact for that filename (e.g.
# an iPXE or GRUB2 EFI binary capable of choosing its own next stage),
# which is the common real-world pattern for "point at existing
# infrastructure" setups. An operator whose UEFI boot artifacts genuinely
# differ per CPU architecture is not served by this single field and needs
# DHCP_PROXY_CUSTOM_OPTIONS (or a future dedicated field) instead --
# documented as a known limitation in docs/dhcp-modes.md. The remaining
# dnsmasq-documented architecture tags (PC98, IA64_EFI, Xscale_EFI, BC_EFI,
# ARM32_EFI) are legacy/niche enough in 2026 (NEC PC-98, Itanium, XScale,
# and 32-bit ARM UEFI are all effectively extinct or rare network-boot
# targets) that they are intentionally left uncovered here rather than
# growing the option surface for hardware this project's users are
# exceedingly unlikely to actually PXE-boot.
#
# IMPORTANT wire-level finding (verified directly: built this exact image,
# ran it on an isolated Docker bridge network, and sent real crafted
# DHCPDISCOVER packets carrying option 60=PXEClient and option 93=<client
# architecture> for architectures 0/7/11, capturing dnsmasq's actual
# DHCPOFFER with tcpdump). Two things had to be confirmed by observation
# rather than documentation, because they are not accurately described by
# any dnsmasq/PXE reference this investigation could find:
#
# 1. `pxe-service` alone never delivers a *correct external* server
#    address, for ANY architecture including x86PC: dnsmasq always
#    substitutes its OWN address into the option-43 boot-server-list
#    sub-option it builds from a pxe-service line, ignoring the server
#    address configured there. For non-x86PC architectures (x86-64_EFI,
#    ARM64_EFI tested) pxe-service is even less useful -- it renders no
#    boot-file information at all, only that same self-referencing
#    next-server field.
# 2. `dhcp-boot`, tag-scoped via `dhcp-match` on DHCP option 93
#    (client-system-architecture), is what actually delivers the
#    *correct*, externally configured server address and filename --
#    confirmed working end-to-end for architectures 0, 7, and 11, with the
#    exact configured filename and server address (not dnsmasq's own
#    address) showing up correctly in the captured reply's classic BOOTP
#    `file`/`siaddr` fields.
#
# Consequently every architecture below is rendered as a dhcp-match +
# tag-scoped dhcp-boot pair, which is the only directive combination
# confirmed to hand a real client the operator's actual external boot
# server. `pxe-service` is still rendered for x86PC (best-effort
# legacy-PXE-ROM-menu compatibility some older BIOS ROMs read, accepting
# its known self-referencing-address quirk) and is REQUIRED regardless
# for at least one architecture, because dhcp-match/dhcp-boot alone do
# NOT make dnsmasq reply to a DHCPDISCOVER at all -- confirmed directly:
# with only dhcp-match/dhcp-boot and no pxe-service directive anywhere in
# the config, dnsmasq recognized the PXE-tagged request in its own debug
# log but never sent a DHCPOFFER. This is the literal root-cause bug this
# issue fixes, so it is exercised by every code path below, not just the
# x86PC one.
#
# Correction (PR #765 review): an earlier version of this comment claimed
# that rendering a pxe-service entry for the SAME architecture as an
# active dhcp-match/dhcp-boot rule actively suppresses that architecture's
# dhcp-boot delivery, and that pxe-service must therefore never share an
# architecture with a dhcp-match/dhcp-boot rule. That claim is false as
# stated -- it directly contradicts the code below, which deliberately
# renders BOTH a pxe-service=x86PC line and a dhcp-match/dhcp-boot pair
# for the SAME architecture (0), and scripts/dhcp-proxy-pxe-simulation.sh
# (run against this exact code in CI) confirms the BIOS case correctly
# delivers the operator-configured external siaddr/filename, not
# dnsmasq's own address or an empty one. UEFI (architectures 7/11) gets
# no pxe-service entry of its own not because doing so would suppress
# dhcp-boot, but simply because it would add nothing: finding 1 above
# already established pxe-service renders no boot-file information at
# all for non-x86PC architectures, and x86PC's own pxe-service line
# already satisfies the "at least one pxe-service directive must exist"
# requirement for the whole config, so a redundant UEFI entry has no
# purpose.
: "${DHCP_PROXY_PXE_BOOT_SERVER:=}"
: "${DHCP_PROXY_PXE_BOOT_FILENAME_BIOS:=}"
: "${DHCP_PROXY_PXE_BOOT_FILENAME_UEFI:=}"

export DHCP_SUBNET_START DHCP_DNS_PRIMARY DHCP_DNS_SECONDARY UPSTREAM_DHCP_IP
export DHCP_PROXY_INTERFACE DHCP_PROXY_ROUTER DHCP_NTP_SERVERS DHCP_PROXY_DOMAIN
export DHCP_PROXY_BOOT_FILENAME DHCP_PROXY_BOOT_SERVER DHCP_PROXY_CUSTOM_OPTIONS
export DHCP_PROXY_PXE_BOOT_SERVER DHCP_PROXY_PXE_BOOT_FILENAME_BIOS DHCP_PROXY_PXE_BOOT_FILENAME_UEFI

# ────────────────────────────────────────────────────────────────────────────
# Known-good configuration snapshot library (#415)
#
# See docs/known-good-config-snapshots.md for the full contract. This block
# is a byte-identical copy of scripts/lib/known-good-snapshots.sh's function
# definitions (verified by tests/bats/known_good_snapshots_sync.bats) rather
# than a sourced file, because this Dockerfile builds from
# services/dhcp-proxy/ alone with no shared-file build context wired up.
# ────────────────────────────────────────────────────────────────────────────
# BEGIN known-good-snapshot library (scripts/lib/known-good-snapshots.sh)
# kgs_log <level> <label> <message...>
# Emits one explicit, greppable log line for every snapshot lifecycle event
# (create, prune, rollback-select, reject) per the issue's acceptance
# criteria. level is a short tag: CREATE/PRUNE/SELECT/REJECT/FATAL.
kgs_log() {
    local level="$1" label="$2"
    shift 2
    echo "[known-good-snapshot][${label}][${level}] $*" >&2
}

# kgs_new_snapshot_id
# Prints a new, sortable, practically collision-free snapshot id.
kgs_new_snapshot_id() {
    date -u +%Y%m%dT%H%M%S.%N
}

# kgs_list_snapshots <snapshot_root>
# Prints existing snapshot ids, oldest first, one per line. Empty output
# (no error) when <snapshot_root> does not exist yet or holds no snapshots.
# Excludes .staging.* entries: kgs_snapshot_create assembles a new snapshot
# in such a directory before the final atomic `mv` into its real <id> name,
# so a container killed mid-copy can leave one behind. Without this
# exclusion, a leftover .staging.* directory would be listed and treated as
# a real (but only partially-written) snapshot by callers of this function.
kgs_list_snapshots() {
    local snapshot_root="$1"
    [ -d "$snapshot_root" ] || return 0
    find "$snapshot_root" -mindepth 1 -maxdepth 1 -type d -not -name '.staging.*' -printf '%f\n' 2>/dev/null | sort
}

# kgs_snapshot_create <snapshot_root> <keep_n> <label> <file...>
# Copies <file...> into a new snapshot directory, then prunes anything
# beyond the newest <keep_n>. Creation is atomic-enough: files are
# assembled in a temporary sibling directory on the same filesystem and only
# `mv`-ed into their final <id> name once complete, so a crash mid-copy
# never leaves a partially-written snapshot directory visible to
# kgs_list_snapshots/kgs_snapshot_apply.
kgs_snapshot_create() {
    local snapshot_root="$1" keep_n="$2" label="$3"
    shift 3
    local -a files=("$@")
    local id staging f base

    mkdir -p "$snapshot_root" || {
        kgs_log FATAL "$label" "cannot create snapshot root $snapshot_root"
        return 1
    }

    id="$(kgs_new_snapshot_id)"
    staging="$(mktemp -d "${snapshot_root}/.staging.XXXXXX")" || {
        kgs_log FATAL "$label" "cannot create staging directory under $snapshot_root"
        return 1
    }

    for f in "${files[@]}"; do
        if [ ! -f "$f" ]; then
            kgs_log FATAL "$label" "candidate file missing, refusing snapshot: $f"
            rm -rf "$staging"
            return 1
        fi
        base="$(basename "$f")"
        if ! cp -p "$f" "$staging/$base"; then
            kgs_log FATAL "$label" "failed to copy $f into snapshot staging"
            rm -rf "$staging"
            return 1
        fi
    done

    if ! mv "$staging" "${snapshot_root}/${id}"; then
        kgs_log FATAL "$label" "failed to finalize snapshot $id"
        rm -rf "$staging"
        return 1
    fi

    kgs_log CREATE "$label" "created known-good snapshot $id (${files[*]})"
    kgs_snapshot_prune "$snapshot_root" "$keep_n" "$label"
}

# kgs_snapshot_prune <snapshot_root> <keep_n> <label>
# Deletes the oldest snapshots beyond <keep_n>. A missing/non-numeric/
# non-positive keep_n is clamped to the documented default of 3 rather than
# trusted as-is, so a misconfigured KEEP_KNOWN_GOOD_CONFIGS (e.g. "0" or
# empty) can never silently disable retention or prune away every snapshot,
# including the one just created by kgs_snapshot_create.
kgs_snapshot_prune() {
    local snapshot_root="$1" keep_n="$2" label="$3"
    case "$keep_n" in
        '' | *[!0-9]*) keep_n=3 ;;
    esac
    [ "$keep_n" -ge 1 ] || keep_n=3

    local -a ids=()
    while IFS= read -r id; do
        [ -n "$id" ] && ids+=("$id")
    done < <(kgs_list_snapshots "$snapshot_root")

    local total=${#ids[@]}
    local excess=$((total - keep_n))
    [ "$excess" -gt 0 ] || return 0

    local i id
    for ((i = 0; i < excess; i++)); do
        id="${ids[$i]}"
        if rm -rf "${snapshot_root:?}/${id}"; then
            kgs_log PRUNE "$label" "pruned known-good snapshot $id (retention=${keep_n})"
        else
            kgs_log FATAL "$label" "failed to prune snapshot $id"
        fi
    done
}

# kgs_snapshot_apply <snapshot_root> <label> <validator_cmd> <dest...>
# Attempts to roll the live config at <dest...> back to the newest snapshot
# that passes <validator_cmd> (a command string evaluated with no arguments
# after the snapshot's files have been copied onto <dest...>; it must exit 0
# for a valid config, e.g. "nginx -t" or "dnsmasq --test -C /etc/dnsmasq.conf").
# Tries snapshots newest-to-oldest, logging a REJECT line for each one that
# fails validation, and never applies one that doesn't pass. Prints the
# selected snapshot id and returns 0 on success. If no snapshot validates (or
# none exist), <dest...> is restored to exactly what was live before this
# function was called, so a failed rollback attempt never leaves <dest...>
# in a half-applied state, and returns 1.
kgs_snapshot_apply() {
    local snapshot_root="$1" label="$2" validator_cmd="$3"
    shift 3
    local -a dest=("$@")
    local -a ids=()
    while IFS= read -r id; do
        [ -n "$id" ] && ids+=("$id")
    done < <(kgs_list_snapshots "$snapshot_root")

    if [ "${#ids[@]}" -eq 0 ]; then
        kgs_log FATAL "$label" "no known-good snapshots available to roll back to"
        return 1
    fi

    local backup_dir
    backup_dir="$(mktemp -d)" || {
        kgs_log FATAL "$label" "cannot create rollback backup directory"
        return 1
    }
    local d base
    for d in "${dest[@]}"; do
        base="$(basename "$d")"
        [ -f "$d" ] && cp -p "$d" "$backup_dir/$base"
    done

    local i id snap_dir
    for ((i = ${#ids[@]} - 1; i >= 0; i--)); do
        id="${ids[$i]}"
        snap_dir="${snapshot_root}/${id}"

        # Require every requested basename to be present in this snapshot
        # before touching any live file. A finalized-but-incomplete
        # snapshot (e.g. taken before a new generated file was added to the
        # candidate list) would otherwise leave that one dest untouched --
        # silently validating a mix of this snapshot's files and whatever
        # happened to already be live, a combination that was never itself
        # actually validated together.
        local snapshot_complete=1
        for d in "${dest[@]}"; do
            base="$(basename "$d")"
            if [ ! -f "${snap_dir}/${base}" ]; then
                snapshot_complete=0
                break
            fi
        done
        if [ "$snapshot_complete" -ne 1 ]; then
            kgs_log REJECT "$label" "rejected known-good snapshot $id: incomplete (missing at least one candidate file)"
            continue
        fi

        for d in "${dest[@]}"; do
            base="$(basename "$d")"
            cp -p "${snap_dir}/${base}" "$d"
        done

        # Redirect the validator's own stdout to stderr: this function's
        # stdout is the caller's return channel (the selected snapshot id
        # via command substitution), and a validator like "nginx -t" or
        # "dnsmasq --test" may print its own diagnostic text to stdout,
        # which would otherwise silently corrupt that return value.
        if eval "$validator_cmd" 1>&2; then
            kgs_log SELECT "$label" "selected known-good snapshot $id for rollback"
            rm -rf "$backup_dir"
            printf '%s\n' "$id"
            return 0
        fi
        kgs_log REJECT "$label" "rejected known-good snapshot $id: failed validation"
    done

    # Nothing validated: restore exactly what was live before this call so a
    # failed rollback attempt never leaves dest in a half-applied state.
    for d in "${dest[@]}"; do
        base="$(basename "$d")"
        if [ -f "$backup_dir/$base" ]; then
            cp -p "$backup_dir/$base" "$d"
        else
            rm -f "$d"
        fi
    done
    rm -rf "$backup_dir"
    kgs_log FATAL "$label" "no known-good snapshot passed validation; refusing rollback"
    return 1
}
# END known-good-snapshot library

envsubst < /etc/dnsmasq.conf.template > /etc/dnsmasq.conf

# _dhcp_proxy_render_optional_directives <dest_conf>
#
# Appends the issue #450 optional dnsmasq relay/proxy directives to
# <dest_conf>, one `echo >>` per configured value, so an unset/empty
# variable produces no line at all instead of an empty or malformed one.
#
# All of these ride the same supplemental ProxyDHCP/PXE exchange as the
# existing DNS option (dhcp-option-pxe=6,...): they are visible to
# PXE/network-boot-aware clients, not to ordinary DHCP clients, whose lease
# and options remain entirely owned by UPSTREAM_DHCP_IP. See
# docs/dhcp-modes.md for the full explanation of what is and is not
# delivered in this mode. Lease-time is intentionally not configurable here:
# ProxyDHCP mode never issues a lease of its own, so a lease-time value would
# have no effect (dnsmasq --test does not reject one, it is just silently
# ignored at runtime, which is worse than not offering the field at all).
#
# Deliberately light validation: this function only rejects input shapes
# that would either be silently ignored (making the operator think a value
# is active when it is not, e.g. an out-of-range custom option code) or that
# would corrupt the file (embedded newlines). Everything else is left to
# `dnsmasq --test` immediately after this runs, which is the authoritative
# fail-closed gate shared with every other value in this file -- a failure
# there still goes through the existing known-good-snapshot rollback path
# below, it does not abort the container outright.
_dhcp_proxy_render_optional_directives() {
    local dest_conf="$1"

    if [ -n "$DHCP_PROXY_INTERFACE" ]; then
        printf 'interface=%s\n' "$DHCP_PROXY_INTERFACE" >> "$dest_conf"
    fi

    if [ -n "$DHCP_PROXY_ROUTER" ]; then
        printf 'dhcp-option-pxe=3,%s\n' "$DHCP_PROXY_ROUTER" >> "$dest_conf"
    fi

    if [ -n "$DHCP_NTP_SERVERS" ]; then
        # Option 42 (NTP servers). DHCP_NTP_SERVERS is a comma-separated IPv4
        # list, matching the Kea-mode field of the same name and the Admin
        # UI's shared validation for it.
        printf 'dhcp-option-pxe=42,%s\n' "$DHCP_NTP_SERVERS" >> "$dest_conf"
    fi

    if [ -n "$DHCP_PROXY_DOMAIN" ]; then
        # Option 15 (domain name).
        printf 'dhcp-option-pxe=15,%s\n' "$DHCP_PROXY_DOMAIN" >> "$dest_conf"
    fi

    if [ -n "$DHCP_PROXY_BOOT_FILENAME" ]; then
        # dnsmasq's dedicated boot-info directive (BOOTP/PXE filename,
        # server-name, server-address) rather than raw options 66/67: this is
        # the directive the dnsmasq man page documents as working together
        # with ProxyDHCP mode ("it is possible, and useful, to configure
        # dnsmasq as both a PXE proxy-DHCP server and a DHCP relay"), and it
        # is what the existing services/dhcp-probe.sh-adjacent PXE tooling
        # expects. Server-name is left empty; only filename and (optionally)
        # server-address are operator-configurable here.
        printf 'dhcp-boot=%s,,%s\n' "$DHCP_PROXY_BOOT_FILENAME" "$DHCP_PROXY_BOOT_SERVER" >> "$dest_conf"
    elif [ -n "$DHCP_PROXY_BOOT_SERVER" ]; then
        echo "WARNING: DHCP_PROXY_BOOT_SERVER is set without DHCP_PROXY_BOOT_FILENAME; a boot server address alone is not meaningful to PXE clients, so no dhcp-boot line was rendered." >&2
    fi

    if [ -n "$DHCP_PROXY_CUSTOM_OPTIONS" ]; then
        _dhcp_proxy_render_custom_options "$dest_conf" "$DHCP_PROXY_CUSTOM_OPTIONS"
    fi
}

# _dhcp_proxy_render_custom_options <dest_conf> <spec>
#
# <spec> is a `;`-separated list of `<code>:<value>` pairs (matching what the
# Admin UI persists). Each entry is rendered as its own
# `dhcp-option-pxe=<code>,<value>` line. An entry that isn't structurally
# `<code>:<value>` (no colon, or an empty code/value) is skipped with an
# actionable WARNING rather than written verbatim, since a malformed entry
# here is operator input error, not something `dnsmasq --test` can attribute
# back to a specific setting. The DHCP option code range (1-254) is checked
# here too: an out-of-range numeric code passes `dnsmasq --test` but is
# silently never sent (confirmed live), which would otherwise look like a
# working config that quietly does nothing.
_dhcp_proxy_render_custom_options() {
    local dest_conf="$1" spec="$2"
    local -a entries=()
    local entry code value

    IFS=';' read -r -a entries <<< "$spec"

    for entry in "${entries[@]}"; do
        # Trim leading/trailing whitespace only (not `xargs`, which would
        # also collapse repeated internal whitespace inside the option
        # value, silently altering values that intentionally contain it).
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [ -n "$entry" ] || continue

        case "$entry" in
            *:*)
                code="${entry%%:*}"
                value="${entry#*:}"
                ;;
            *)
                echo "WARNING: ignoring malformed DHCP_PROXY_CUSTOM_OPTIONS entry '${entry}' (expected CODE:VALUE)." >&2
                continue
                ;;
        esac

        if [ -z "$code" ] || [ -z "$value" ]; then
            echo "WARNING: ignoring malformed DHCP_PROXY_CUSTOM_OPTIONS entry '${entry}' (expected CODE:VALUE, both non-empty)." >&2
            continue
        fi

        case "$code" in
            '' | *[!0-9]*)
                echo "WARNING: ignoring DHCP_PROXY_CUSTOM_OPTIONS entry '${entry}': option code must be numeric." >&2
                continue
                ;;
        esac
        if [ "$code" -lt 1 ] || [ "$code" -gt 254 ]; then
            echo "WARNING: ignoring DHCP_PROXY_CUSTOM_OPTIONS entry '${entry}': option code ${code} is outside the valid DHCP option range (1-254) and would be silently dropped by dnsmasq." >&2
            continue
        fi

        printf 'dhcp-option-pxe=%s,%s\n' "$code" "$value" >> "$dest_conf"
    done
}

# _dhcp_proxy_render_pxe_service_directives <dest_conf>
#
# Appends issue #705's opt-in `pxe-service` directives to <dest_conf>. This
# is the directive that actually makes dnsmasq's ProxyDHCP mode reply to a
# DHCPDISCOVER at all (see the header comment above the DHCP_PROXY_PXE_*
# vars for the full investigation summary) -- everything else in this file,
# including the #450 vars this service already offered, only takes effect
# once at least one `pxe-service` line is present.
#
# Gate: DHCP_PROXY_PXE_BOOT_SERVER must be set for ANY pxe-service line to
# be rendered at all -- this is the opt-in switch. A filename var set
# without the server (or a server set with neither filename var) is
# operator input that cannot produce a meaningful directive, so it is
# skipped with an explicit WARNING rather than silently doing nothing or
# rendering a directive dnsmasq would reject.
_dhcp_proxy_render_pxe_service_directives() {
    local dest_conf="$1"

    if [ -z "$DHCP_PROXY_PXE_BOOT_SERVER" ]; then
        if [ -n "$DHCP_PROXY_PXE_BOOT_FILENAME_BIOS" ] || [ -n "$DHCP_PROXY_PXE_BOOT_FILENAME_UEFI" ]; then
            echo "WARNING: DHCP_PROXY_PXE_BOOT_FILENAME_BIOS/_UEFI is set without DHCP_PROXY_PXE_BOOT_SERVER; a boot filename alone cannot produce a pxe-service directive, so no PXE boot-pointer was rendered. PXE support remains disabled." >&2
        fi
        return 0
    fi

    if [ -z "$DHCP_PROXY_PXE_BOOT_FILENAME_BIOS" ] && [ -z "$DHCP_PROXY_PXE_BOOT_FILENAME_UEFI" ]; then
        echo "WARNING: DHCP_PROXY_PXE_BOOT_SERVER is set without either DHCP_PROXY_PXE_BOOT_FILENAME_BIOS or DHCP_PROXY_PXE_BOOT_FILENAME_UEFI; a boot server alone cannot produce a pxe-service directive, so no PXE boot-pointer was rendered. PXE support remains disabled." >&2
        return 0
    fi

    # Lightweight validation matching _dhcp_proxy_render_custom_options'
    # own rationale: reject only what would corrupt the rendered file
    # (embedded newlines), everything else is left to `dnsmasq --test`.
    case "$DHCP_PROXY_PXE_BOOT_SERVER$DHCP_PROXY_PXE_BOOT_FILENAME_BIOS$DHCP_PROXY_PXE_BOOT_FILENAME_UEFI" in
        *$'\n'*)
            echo "WARNING: one of DHCP_PROXY_PXE_BOOT_SERVER/DHCP_PROXY_PXE_BOOT_FILENAME_BIOS/DHCP_PROXY_PXE_BOOT_FILENAME_UEFI contains an embedded newline; no PXE boot-pointer was rendered." >&2
            return 0
            ;;
    esac

    local have_bios=0 have_uefi=0
    [ -n "$DHCP_PROXY_PXE_BOOT_FILENAME_BIOS" ] && have_bios=1
    [ -n "$DHCP_PROXY_PXE_BOOT_FILENAME_UEFI" ] && have_uefi=1

    if [ "$have_bios" -eq 1 ]; then
        # x86PC = dnsmasq's architecture tag for client-system-architecture
        # 0 (legacy BIOS PXE ROMs), per the dnsmasq man page's pxe-service
        # section and confirmed against the running binary's own compiled-in
        # architecture-name table. The quoted menu text is required syntax
        # even though this project deliberately implements no menu logic
        # (decision #2 on issue #705): dnsmasq only shows a menu when more
        # than one service matches the same architecture, which never
        # happens here since exactly one BIOS entry is ever rendered.
        #
        # This pxe-service line alone is NOT enough to point a BIOS client
        # at the configured *external* server, despite taking a server
        # address argument: confirmed by real packet capture that dnsmasq
        # always substitutes its OWN address into the DHCPOFFER's option 43
        # boot-server-list sub-option, ignoring the address configured
        # here. Its purposes are instead (a) the legacy-PXE-ROM-compatible
        # option 43 menu structure some older BIOS PXE ROMs read, using
        # dnsmasq's own address there as an unavoidable quirk of this
        # dnsmasq build, and (b) unlocking ProxyDHCP replies at all --
        # see the "have_bios -eq 0" branch below for what stands in for
        # this when only UEFI is configured. The dhcp-match/dhcp-boot pair
        # right below is what actually delivers the *correct*, externally
        # configured server address to a real client, via the classic
        # BOOTP file/siaddr fields instead of option 43 -- also confirmed
        # directly by packet capture.
        printf 'pxe-service=x86PC,"lancache-ng PXE boot (BIOS)",%s,%s\n' \
            "$DHCP_PROXY_PXE_BOOT_FILENAME_BIOS" "$DHCP_PROXY_PXE_BOOT_SERVER" >> "$dest_conf"
        printf 'dhcp-match=set:lancache-pxe-bios,option:client-arch,0\n' >> "$dest_conf"
        printf 'dhcp-boot=tag:lancache-pxe-bios,%s,,%s\n' \
            "$DHCP_PROXY_PXE_BOOT_FILENAME_BIOS" "$DHCP_PROXY_PXE_BOOT_SERVER" >> "$dest_conf"
    fi

    if [ "$have_uefi" -eq 1 ]; then
        # Deliberately rendered as dhcp-match/dhcp-boot only, with NO
        # matching pxe-service entry for these architectures: the header
        # comment above documents the confirmed-by-packet-capture finding
        # that pxe-service does not deliver a usable boot filename for any
        # architecture other than x86PC on this dnsmasq build (it only sets
        # the reply's next-server field, never the filename). A UEFI
        # pxe-service entry would therefore add nothing even if rendered --
        # not because it would suppress dhcp-boot (PR #765 review corrected
        # an earlier version of this comment that claimed exactly that; see
        # the header comment above's "Correction" paragraph and
        # scripts/dhcp-proxy-pxe-simulation.sh, which asserts the BIOS case
        # combining both directives for the SAME architecture in CI). It is
        # simply redundant: the x86PC pxe-service line rendered above
        # already satisfies the "at least one pxe-service directive must
        # exist" requirement for the whole config, so dhcp-boot (tag-scoped
        # to the matching architectures via dhcp-match on DHCP option 93)
        # is the only directive UEFI needs. One dhcp-match line per covered
        # architecture code sets the same tag; dhcp-boot then applies to
        # any of them via that shared tag.
        printf 'dhcp-match=set:lancache-pxe-uefi,option:client-arch,7\n' >> "$dest_conf"
        printf 'dhcp-match=set:lancache-pxe-uefi,option:client-arch,11\n' >> "$dest_conf"
        printf 'dhcp-boot=tag:lancache-pxe-uefi,%s,,%s\n' \
            "$DHCP_PROXY_PXE_BOOT_FILENAME_UEFI" "$DHCP_PROXY_PXE_BOOT_SERVER" >> "$dest_conf"
    fi

    if [ "$have_bios" -eq 0 ]; then
        # dhcp-boot/dhcp-match alone do NOT make dnsmasq reply to a
        # DHCPDISCOVER at all -- confirmed directly (issue #705): with only
        # the two lines above and no pxe-service directive anywhere in the
        # config, dnsmasq logged "vendor class: PXEClient" but never sent a
        # DHCPOFFER. At least one pxe-service directive must exist in the
        # config for ProxyDHCP replies to happen at all (this is the
        # original root-cause bug this issue fixes). When BIOS is
        # configured, its own pxe-service line above already satisfies
        # this. When it is not (UEFI-only setup), this IA64_EFI entry
        # exists purely to satisfy that requirement: IA64_EFI (Itanium,
        # architecture code 2) is not one of the covered architectures
        # above and not realistically sent by any 2026-era PXE client, and
        # boot service type "0" is dnsmasq's documented "abort netboot,
        # continue from local media" value -- so even the extremely
        # unlikely real Itanium client hitting this rule falls back to
        # local boot rather than receiving a misleading boot pointer.
        printf 'pxe-service=IA64_EFI,"lancache-ng PXE proxy active",0\n' >> "$dest_conf"
    fi
}

_dhcp_proxy_render_optional_directives /etc/dnsmasq.conf
_dhcp_proxy_render_pxe_service_directives /etc/dnsmasq.conf

# _dhcp_proxy_validate_snapshot_or_rollback <file...>
# Factored into its own function (rather than inline top-level script code)
# so tests/bats/dhcp_proxy_known_good_snapshot.bats can drive the full
# dnsmasq adapter flow against a stub `dnsmasq` binary without needing to
# run the rest of this entrypoint.
_dhcp_proxy_validate_snapshot_or_rollback() {
    local -a candidate_files=("$@")
    # dnsmasq's -C flag can point at an arbitrary path (unlike nginx -t,
    # which always validates the fixed in-container config due to absolute
    # conf.d/stream.d includes), so the config path is taken from the
    # caller's candidate list instead of being hardcoded here. This also
    # lets tests point it at a throwaway path instead of the real
    # /etc/dnsmasq.conf.
    local dnsmasq_conf="${candidate_files[0]}"

    echo "Validating dnsmasq config..."
    if dnsmasq --test -C "$dnsmasq_conf"; then
        kgs_snapshot_create "$DHCP_PROXY_CONFIG_SNAPSHOT_DIR" "$KEEP_KNOWN_GOOD_CONFIGS" "dhcp-proxy" "${candidate_files[@]}"
        return 0
    fi

    echo "ERROR: generated dnsmasq config failed validation (dnsmasq --test)." >&2
    echo "ERROR: attempting rollback to the newest known-good snapshot instead of starting with an invalid config." >&2
    local selected_id
    if selected_id="$(kgs_snapshot_apply "$DHCP_PROXY_CONFIG_SNAPSHOT_DIR" "dhcp-proxy" "dnsmasq --test -C '${dnsmasq_conf}'" "${candidate_files[@]}")"; then
        echo "WARNING: dnsmasq is starting from known-good snapshot ${selected_id}, NOT the newly generated config." >&2
        echo "WARNING: check DHCP_SUBNET_START/DHCP_DNS_PRIMARY/DHCP_DNS_SECONDARY/UPSTREAM_DHCP_IP and restart to pick up the intended change." >&2
        return 0
    fi

    echo "FATAL: no known-good dnsmasq config snapshot is available; refusing to start with an invalid config." >&2
    return 1
}

DHCP_PROXY_CANDIDATE_FILES=(/etc/dnsmasq.conf)
_dhcp_proxy_validate_snapshot_or_rollback "${DHCP_PROXY_CANDIDATE_FILES[@]}" || exit 1

echo "Starting dnsmasq DHCP proxy (subnet: $DHCP_SUBNET_START, DNS: $DHCP_DNS_PRIMARY, $DHCP_DNS_SECONDARY)..."
exec dnsmasq -k -C /etc/dnsmasq.conf
