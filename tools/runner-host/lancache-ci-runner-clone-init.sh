#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# CI runner host bootstrap: prepare a freshly provisioned (or disk-cloned)
# self-hosted runner host for GitHub Actions registration, WITHOUT ever
# performing the registration itself.
#
# Background (issue #1622): new runner host VMs in this fleet (e.g. the
# .81/.82/.84 light/heavy hosts added 2026-08) are provisioned as disk
# clones of an existing, already-registered runner host (lancache-240).
# Confirmed by direct SSH inspection, 2026-08-21: a freshly cloned host's
# /opt/actions-runner-N directories are NOT empty -- they carry the SOURCE
# host's own .runner/.credentials/.credentials_rsaparams files (private key
# material a runner uses to authenticate to GitHub as one specific,
# already-registered identity), plus multi-GB leftover backup archives
# (runner*.tgz) from whatever imaging process produced the clone. A runner
# identity belonging to one host must never be left sitting on a different
# host (maintainer decision, issue #1622: not treated as an active
# credential-compromise incident since nothing on the clone side ever
# started the runner service or communicated with GitHub using it, but it
# must be detected and removed before the CLONE is put into service).
#
# This script only prepares a host up to the point of running the real
# actions-runner `config.sh` -- registration itself needs a short-lived
# GitHub registration token (`gh api -X POST
# repos/<org>/<repo>/actions/runners/registration-token`) and remains a
# separate, deliberate, human-run step, same as actually starting/enabling
# the resulting systemd service. Neither this script nor any subcommand of
# it ever calls config.sh, installs a systemd unit for a runner instance, or
# starts a runner process -- it stops at "ready to register".
#
# Modes (see --help):
#   check         Read-only. Reports clone-artifact findings, docker/sudoers/
#                 group state, and disk usage. Writes nothing.
#   clean         Removes ONLY the clone artifacts `check` already flagged as
#                 foreign to this host (re-verified immediately before each
#                 removal). Requires CONFIRM_CLEAN=yes. Refuses to remove
#                 anything not independently re-confirmed as foreign, so it
#                 can never wipe a host's own real, already-registered runner
#                 state even if run there by mistake.
#   host-prep     Idempotent, non-disruptive: sudoers NOPASSWD drop-in for
#                 the runner user, adds that user to the docker group,
#                 installs the /opt/lancache-ci-hooks/{pre,post}-job-
#                 cleanup.sh pair (host-local, not repo-tracked -- same as
#                 they already are on every existing runner host) and this
#                 repo's own lancache-ci-cleanup timer/service (installed
#                 from the sibling files in this same directory).
#   runner-fetch  Downloads, checksum-verifies (against the GitHub Releases
#                 API asset digest), and extracts a specific actions-runner
#                 release directly into a target instance directory --
#                 deliberately NOT via an intermediate "extract then `cp -a`
#                 to every instance" template step, which is what stalled
#                 for several minutes on a resource-constrained clone host
#                 during this issue's own investigation. Writes that
#                 instance's `.env` hook wiring (ACTIONS_RUNNER_HOOK_JOB_*)
#                 but does not run config.sh or touch systemd.
#
# Usage (see README.md in this directory for the full per-host rollout
# procedure): invoke with an explicit interpreter (`bash
# lancache-ci-runner-clone-init.sh ...`), not
# `./lancache-ci-runner-clone-init.sh` -- like this directory's other two
# scripts, this repo's executable bit is unverifiable from a Windows
# authoring host with `core.filemode=false` (AG-VAL-024), so this script
# must not depend on it being set.
set -euo pipefail

RUNNER_OPT_ROOT="${RUNNER_OPT_ROOT:-/opt}"
RUNNER_HOOKS_DIR="${RUNNER_HOOKS_DIR:-/opt/lancache-ci-hooks}"
RUNNER_USER="${RUNNER_USER:-codex}"
# Minimum size before a stray /opt/*.tgz|*.tar.gz is flagged as a leftover
# clone-imaging backup rather than something intentionally placed there --
# the two confirmed real examples (issue #1622) were 6.7 GB and 14.3 GB.
STRAY_ARCHIVE_MIN_BYTES="${STRAY_ARCHIVE_MIN_BYTES:-1073741824}" # 1 GiB

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Derives a short "this host" token from `hostname` to compare against the
# host-number segment embedded in this fleet's actual runner-name convention
# (a-lancache-runner-240-1, b-lancache-runner-229-2, d-lancache-runner-241-1,
# gh-lancache-light-31-81, gh-lancache-heavy-30-84, ...): the LAST run of
# digits in the hostname. Confirmed against every runner name seen on the
# real fleet (2026-08-21 `gh api .../actions/runners` inspection) -- each
# one's trailing numeric segment is exactly the host's own last IP octet or
# equivalent host number, never shared between two different hosts.
own_host_token() {
    # `|| true`: if `hostname` ever contains no digits at all, `grep -oE`
    # finds nothing and exits non-zero; under `set -o pipefail` that would
    # propagate through a caller's `my_token="$(own_host_token)"`
    # assignment and trip `set -e`, same failure class fixed in
    # own_primary_ipv4 above (confirmed real there on host .80 -- applied
    # here too as a preventive fix, not yet observed to fail in practice
    # since every real hostname in this fleet does contain digits).
    hostname | grep -oE '[0-9]+' | tail -n1 || true
}

# Returns this host's primary IPv4 address (the one carrying its default
# route), or empty if it cannot be determined.
#
# Bug fixed 2026-08-21 (confirmed real on host .88): the previous
# implementation took the first "scope global" address `ip addr` happened to
# list, which is interface-enumeration-order-dependent and NOT guaranteed to
# be the host's real LAN address -- Docker's own `docker0` bridge
# (172.17.0.1/16) is also "scope global", and on .88 it was listed before
# the real `vmbr0` interface, so this function returned 172.17.0.1 and
# hostname_mismatch_report below raised a false "MISMATCH" (comparing the
# hostname's trailing digit token against docker0's own fixed last octet,
# 1, instead of this host's actual last IP octet). Fixed to instead read
# the source address of the default route.
#
# Second bug fixed 2026-08-21, same day (confirmed real on host .80): that
# first fix used `ip route show default`'s own `src` field -- but a `src`
# field is only PRINTED there when the kernel's route table entry carries
# an explicit one; a plain `onlink` default route (confirmed real: "default
# via 192.168.1.2 dev vmbr0 proto kernel onlink", no `src` at all) omits it
# entirely, and every host in this fleet uses exactly that route shape. The
# `grep -oE 'src ...'` pipeline then matched nothing, exited non-zero, and
# -- because it fed a variable assignment (`my_ip="$(own_primary_ipv4)"` in
# hostname_mismatch_report/ensure_hosts_self_reference) -- `set -e` treated
# that as a fatal error and killed the ENTIRE full-reset-clean run silently
# partway through, with no error message and no indication anything had
# stopped early. (This is why the .85-.88 batch's full-reset-clean output
# each appeared to end abruptly right after this check's own section
# header -- it wasn't a display artifact, those runs genuinely stopped
# there without applying host-prep or the hostid/machine-id dedup added
# later that same session; see README.md's own note on re-running
# full-reset-clean on those hosts if this fix landed after they were
# processed.) Fixed to use `ip route get <probe>` instead, which always
# computes and prints a real `src` address for a reachable route regardless
# of whether the route table's own display would show one, and wrapped so
# a route lookup failure (e.g. no default route at all) returns empty
# rather than propagating a non-zero exit through the command substitution.
own_primary_ipv4() {
    # `|| true` at the very end matters just as much as the one on `ip
    # route get` itself: under `set -o pipefail`, if `grep` finds no match
    # (a legitimate, expected outcome this function's callers already
    # handle via an empty-string check) it exits non-zero, and pipefail
    # would propagate that as the whole pipeline's exit status -- which,
    # fed into a caller's `my_ip="$(own_primary_ipv4)"` assignment, is
    # exactly the failure mode `set -e` killed this script over on host
    # .80 (see the long comment above). This function must always exit 0;
    # "could not determine the IP" is communicated via an empty stdout, not
    # a non-zero exit code.
    { ip -4 route get 1.1.1.1 2>/dev/null || true; } | grep -oE 'src [0-9.]+' | head -n1 | awk '{print $2}' || true
}

# Checks whether /etc/hosts lets this host resolve its OWN current hostname
# (issue #1622 follow-up, 2026-08-21). Confirmed real on hosts .80 and .84:
# each had a self-reference line whose TEXT was stale clone residue -- .80's
# pointed at a completely different IP/hostname (the template's own
# pre-clone identity), .84's had the right IP but the wrong tier name
# ("gh-lancache-light-30-84" in /etc/hosts while `hostname` correctly says
# "gh-lancache-heavy-30-84", i.e. /etc/hosts was never updated when this
# host's tier was assigned/changed). Either way `sudo` (and anything else
# resolving its own hostname) fails with "unable to resolve host" on every
# invocation. Unlike hostname_mismatch_report below, this IS safe to
# auto-fix: it never guesses what the hostname SHOULD be, only makes
# /etc/hosts consistent with whatever `hostname` ALREADY, currently says --
# no judgment call involved. Prints what it found/fixed; `$2` controls mode
# ("check" = report only, "fix" = also write).
ensure_hosts_self_reference() {
    local mode="${1:-check}"
    local my_hostname my_ip
    my_hostname="$(hostname)"
    my_ip="$(own_primary_ipv4)"
    if sudo -n grep -qE "\\b${my_hostname}\\b" /etc/hosts 2>/dev/null; then
        echo "  OK: /etc/hosts already resolves current hostname '${my_hostname}'."
        return 0
    fi
    echo "  STALE: /etc/hosts has no line resolving current hostname '${my_hostname}'."
    if [[ "$mode" != "fix" ]]; then
        echo "    -> will be corrected by full-reset-clean."
        return 0
    fi
    if [[ -n "$my_ip" ]] && sudo -n grep -qE "^${my_ip//./\\.}[[:space:]]" /etc/hosts 2>/dev/null; then
        sudo -n sed -i "s/^${my_ip//./\\.}[[:space:]].*/127.0.1.1\\t${my_hostname}/" /etc/hosts
        echo "    Fixed: replaced the stale self-reference line for this host's own IP ($my_ip)."
    else
        printf '127.0.1.1\t%s\n' "$my_hostname" | sudo -n tee -a /etc/hosts >/dev/null
        echo "    Fixed: appended a new 127.0.1.1 entry (no existing line for this host's own IP found)."
    fi
}

# Regenerates /etc/hostid and /etc/machine-id unconditionally (issue #1622
# follow-up, 2026-08-21). Unlike the checks above, this script CANNOT
# reliably detect "is my current hostid/machine-id a duplicate of some
# other host's" from inside a single host -- that requires cross-host
# knowledge this script doesn't have. Confirmed real duplicates found this
# way across the fleet: hostid `dba8962a` shared by every unreset clone
# (the template's own baked-in value); machine-id `50007d2d59f14fc3bce7d23c0b542c13`
# shared by two DIFFERENT hosts (.87 and .88) at the same time, each
# unaware of the other. Regenerating both is cheap and safe to run on every
# full-reset-clean invocation, including on a host that already has a
# unique value -- the new value is still unique, nothing depends on the
# old one persisting across this operation this early in a host's setup
# (before any runner registration or service that might reference it).
#
# IMPORTANT (confirmed real on host .85, 2026-08-21): `systemd-machine-id-
# setup`'s own fallback chain includes deriving the ID from the SMBIOS/DMI
# UUID when no D-Bus machine-id is present -- but .85 (a Proxmox clone of
# .80) was NOT given a fresh SMBIOS UUID by the clone operation, so that
# fallback deterministically reproduced .80's OWN machine-id verbatim
# (confirmed: `sudo rm -f /etc/machine-id; sudo systemd-machine-id-setup`
# yielded the byte-for-byte identical value on .85 as on .80). This
# function therefore does NOT rely on systemd-machine-id-setup's own
# fallback logic at all -- it writes a value read directly from
# /dev/urandom, which cannot collide with another host's SMBIOS UUID
# regardless of whether Proxmox gave the clone a fresh one. This masks the
# symptom at the OS level; a duplicated SMBIOS/DMI UUID is itself a
# hypervisor-level clone configuration issue (worth flagging to whoever
# manages the Proxmox clone process, since it can affect other things that
# key off that UUID) that this script cannot fix from inside the guest.
dedupe_host_identity() {
    echo "  hostid: $(hostid) -> "
    sudo -n rm -f /etc/hostid
    sudo -n /usr/sbin/zgenhostid -f >/dev/null 2>&1 || true
    echo "    $(hostid)"
    local old_machine_id new_machine_id
    old_machine_id="$(cat /etc/machine-id 2>/dev/null || echo '?')"
    new_machine_id="$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf '%s\n' "$new_machine_id" | sudo -n tee /etc/machine-id >/dev/null
    sudo -n rm -f /var/lib/dbus/machine-id
    sudo -n ln -s /etc/machine-id /var/lib/dbus/machine-id
    sudo -n systemctl restart systemd-journald 2>/dev/null || true
    echo "  machine-id: ${old_machine_id} -> ${new_machine_id}"
}

# Detects a leftover CLONE hostname (issue #1622 follow-up, 2026-08-21):
# confirmed real on host .80, which reports itself as "gh-lancache-heavy-
# 30-85" via `hostname` while its actual IP is 192.168.1.80 -- the OS
# hostname is itself clone residue from the template/a different host,
# never updated after imaging. Detected by comparing the host's own primary
# IPv4 address's last octet against `own_host_token` (the trailing digit run
# in `hostname`) -- for every real host in this fleet seen so far, those two
# are supposed to be identical. Deliberately report-only, same reasoning as
# authorized_keys: this script has no way to independently know the
# CORRECT hostname (that mapping only exists in the maintainer's own
# inventory, not derivable from the host itself), so guessing a "fix" here
# risks replacing one wrong hostname with a different wrong one. Use the
# separate `set-hostname` mode to apply an explicit, maintainer-provided
# correction.
hostname_mismatch_report() {
    local ip last_octet my_token
    ip="$(own_primary_ipv4)"
    my_token="$(own_host_token)"
    if [[ -z "$ip" ]]; then
        echo "  (could not determine primary IPv4 address -- skipping hostname-vs-IP check)"
        return 0
    fi
    last_octet="${ip##*.}"
    if [[ -z "$my_token" ]]; then
        echo "  (could not derive a numeric token from 'hostname' -- skipping hostname-vs-IP check)"
        return 0
    fi
    if [[ "$last_octet" != "$my_token" ]]; then
        echo "  MISMATCH: hostname is '$(hostname)' (trailing token: $my_token) but primary IPv4 is $ip (last octet: $last_octet)"
        echo "    -> likely leftover clone hostname; NOT auto-fixed. Confirm the correct hostname with the maintainer, then run:"
        echo "       sudo bash $0 set-hostname <correct-hostname>"
    else
        echo "  OK: hostname '$(hostname)' trailing token ($my_token) matches primary IPv4 $ip's last octet."
    fi
}

# True (exit 0) if a runner instance directory's recorded .runner identity
# belongs to a DIFFERENT host than this one -- i.e. is a clone leftover, not
# this host's own (possibly already-registered) identity. A directory with
# no .runner file at all is not "foreign" (it's simply unregistered yet) and
# is intentionally never flagged by this function.
is_foreign_runner_dir() {
    local dir="$1"
    local runner_json="$dir/.runner"
    [[ -f "$runner_json" ]] || return 1
    local agent_name
    agent_name="$(jq -r '.agentName // empty' "$runner_json" 2>/dev/null || true)"
    [[ -n "$agent_name" ]] || return 1
    local my_token
    my_token="$(own_host_token)"
    if [[ -z "$my_token" ]]; then
        echo "WARNING: could not derive a host token from 'hostname' output -- cannot safely classify $dir, treating as NOT foreign (fail closed, never auto-remove when unsure)." >&2
        return 1
    fi
    # agentName segments are hyphen-delimited (a-lancache-runner-240-1) --
    # match the host token as its own segment, not a substring, so host 1
    # can never accidentally match host 41's directory.
    if grep -qE "(^|-)${my_token}(-|$)" <<<"$agent_name"; then
        return 1 # belongs to this host
    fi
    return 0 # foreign
}

find_runner_dirs() {
    find "$RUNNER_OPT_ROOT" -maxdepth 1 -type d -name 'actions-runner*' 2>/dev/null | sort
}

find_stray_archives() {
    find "$RUNNER_OPT_ROOT" -maxdepth 1 -type f \( -name '*.tgz' -o -name '*.tar.gz' \) -size "+${STRAY_ARCHIVE_MIN_BYTES}c" 2>/dev/null | sort
}

cmd_check() {
    echo "Host: $(hostname)   own_host_token=$(own_host_token)"
    echo
    echo "--- Runner instance directories under $RUNNER_OPT_ROOT ---"
    local dir found=0
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        found=1
        if is_foreign_runner_dir "$dir"; then
            local agent_name
            agent_name="$(jq -r '.agentName // "?"' "$dir/.runner" 2>/dev/null || echo '?')"
            echo "  FOREIGN CLONE ARTIFACT: $dir  (belongs to: $agent_name)"
            [[ -f "$dir/.credentials" ]] && echo "    -> carries .credentials (private key material for that identity)"
        elif [[ -f "$dir/.runner" ]]; then
            local agent_name
            agent_name="$(jq -r '.agentName // "?"' "$dir/.runner" 2>/dev/null || echo '?')"
            echo "  own/registered: $dir  (agentName: $agent_name)"
        else
            echo "  unregistered (no .runner yet): $dir"
        fi
    done < <(find_runner_dirs)
    [[ "$found" -eq 1 ]] || echo "  (none found)"
    echo
    echo "--- Stray large archives under $RUNNER_OPT_ROOT (>= ${STRAY_ARCHIVE_MIN_BYTES} bytes) ---"
    local archive found_archive=0
    while IFS= read -r archive; do
        [[ -n "$archive" ]] || continue
        found_archive=1
        echo "  $archive  ($(du -h "$archive" 2>/dev/null | cut -f1))"
    done < <(find_stray_archives)
    [[ "$found_archive" -eq 1 ]] || echo "  (none found)"
    echo
    echo "--- Sudoers / docker group for $RUNNER_USER ---"
    if sudo -n test -f "/etc/sudoers.d/${RUNNER_USER}-nopasswd" 2>/dev/null; then
        echo "  /etc/sudoers.d/${RUNNER_USER}-nopasswd: present"
    else
        echo "  /etc/sudoers.d/${RUNNER_USER}-nopasswd: MISSING"
    fi
    if id -nG "$RUNNER_USER" 2>/dev/null | grep -qw docker; then
        echo "  $RUNNER_USER in docker group: yes"
    else
        echo "  $RUNNER_USER in docker group: MISSING"
    fi
    echo
    echo "--- lancache-ci-hooks ---"
    for f in pre-job-cleanup.sh post-job-cleanup.sh; do
        if [[ -f "$RUNNER_HOOKS_DIR/$f" ]]; then
            echo "  $RUNNER_HOOKS_DIR/$f: present"
        else
            echo "  $RUNNER_HOOKS_DIR/$f: MISSING"
        fi
    done
    echo
    echo "--- lancache-ci-cleanup timer ---"
    if systemctl is-enabled lancache-ci-cleanup.timer >/dev/null 2>&1; then
        echo "  lancache-ci-cleanup.timer: $(systemctl is-enabled lancache-ci-cleanup.timer 2>/dev/null)/$(systemctl is-active lancache-ci-cleanup.timer 2>/dev/null)"
    else
        echo "  lancache-ci-cleanup.timer: not installed"
    fi
    echo
    echo "--- Disk usage ($RUNNER_OPT_ROOT's filesystem) ---"
    df -h "$RUNNER_OPT_ROOT"
    echo
    echo "No files were changed (check mode)."
}

cmd_clean() {
    if [[ "${CONFIRM_CLEAN:-}" != "yes" ]]; then
        echo "ERROR: refusing to remove anything without CONFIRM_CLEAN=yes." >&2
        echo "Run 'check' first and review its findings." >&2
        return 1
    fi
    local removed_any=0
    local dir
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        # Re-verify immediately before removal (not just trusting an earlier
        # check's output) -- defense in depth against this dir's contents
        # having changed between an operator's 'check' run and this 'clean'
        # run.
        if is_foreign_runner_dir "$dir"; then
            echo "Removing foreign clone artifact: $dir"
            sudo rm -rf -- "$dir"
            removed_any=1
        fi
    done < <(find_runner_dirs)
    local archive
    while IFS= read -r archive; do
        [[ -n "$archive" ]] || continue
        echo "Removing stray archive: $archive"
        sudo rm -f -- "$archive"
        removed_any=1
    done < <(find_stray_archives)
    if [[ "$removed_any" -eq 0 ]]; then
        echo "Nothing to remove -- no foreign runner directories or stray archives found."
    else
        echo "Clean complete. Re-run 'check' to confirm."
    fi
}

# --- full-reset: broader de-clone sweep (maintainer request, issue #1622) --
#
# `check`/`clean` above only cover the ONE clone-artifact class that
# motivated this script (runner identities + their backup archives).
# `full-reset-check`/`full-reset-clean` cover everything else a real,
# freshly-and-manually-installed Debian host would never have, so a cloned
# host becomes indistinguishable from one after this runs. Deliberately
# split into its own check/clean pair, same safety shape as `check`/`clean`:
# read-only survey first, explicit CONFIRM_FULL_RESET=yes gate to act, and
# only auto-removes items with NO plausible legitimate reason to exist on
# this host -- anything requiring a judgment call about intent is reported,
# never auto-removed. Concretely, `full-reset-clean` will:
#   - truncate root's and RUNNER_USER's shell history (.bash_history) and
#     .lesshst -- pure local usage history, no access-control meaning;
#   - clear root's and RUNNER_USER's SSH known_hosts -- a cache of who this
#     host has connected to before, not an access grant; safe to empty;
#   - vacuum any /var/log/journal/<machine-id>/ directory that does NOT
#     match this host's current /etc/machine-id (a real fresh install only
#     ever has journal data under its own current machine-id; a leftover
#     directory under the template's pre-reset machine-id is pure clone
#     residue, confirmed real on host .81, 2026-08-21);
#   - remove any /home/<user> directory with no corresponding entry in
#     /etc/passwd (an orphaned home directory cannot belong to this host --
#     confirmed real on host .81: /home/tom with no "tom" account at all);
#   - remove known one-off template-authoring scripts such as
#     prepare-proxmox-template.sh from /root -- tooling for turning a VM
#     INTO a template, actively dangerous if ever run again against an
#     already-provisioned clone, so it does not belong on the clone itself.
# What this deliberately does NOT auto-remove, and only reports instead:
#   - authorized_keys entries -- removing the wrong one can lock out real
#     access. Only entries whose trailing comment names a DIFFERENT fleet
#     host by this project's own "<name>-<number>" convention (see
#     own_host_token) are even flagged, and even those require a human to
#     confirm and remove by hand;
#   - apt/dpkg history log content mentioning other hosts -- this is a
#     genuine historical system audit trail (when packages were actually
#     installed on the source disk); rewriting or deleting it to make the
#     host merely LOOK freshly installed would falsify that record rather
#     than fix anything, so this script only reports it exists;
#   - the OS hostname itself -- confirmed real on host .80 (2026-08-21): it
#     reported itself as "gh-lancache-heavy-30-85" via `hostname` while its
#     actual IP is 192.168.1.80, i.e. the hostname is clone residue never
#     updated after imaging. Flagged by comparing the trailing digit run in
#     `hostname` against this host's own primary IPv4 address's last octet
#     (see hostname_mismatch_report), but never auto-corrected -- this
#     script has no independent way to know the CORRECT name (that mapping
#     lives only in the maintainer's own inventory), so guessing could swap
#     one wrong hostname for a different wrong one. Use the separate
#     `set-hostname <name>` mode once the correct value is known.
is_foreign_authorized_keys_line() {
    local line="$1"
    local my_token
    my_token="$(own_host_token)"
    [[ -n "$my_token" ]] || return 1
    # Look for this fleet's own "gh-lancache-<tier>-<group>-<hostnum>" or
    # "<letter>-lancache-runner-<hostnum>" host-identity naming scheme in the
    # comment field, and flag it only if the TRAILING digit run differs from
    # this host's own token. The middle "group" segment is deliberately
    # matched loosely ([A-Za-z0-9]+, not [0-9]+) -- confirmed real on host
    # .81 (2026-08-21): the template's own leftover root authorized_keys
    # comment was "root@gh-lancache-light-A-80", where "A" is a letter, not
    # a number, so an earlier digits-only version of this pattern silently
    # failed to match it. Deliberately anchored to these specific fleet
    # naming prefixes (not "any trailing digits in any comment") so an
    # unrelated key comment containing a date or other number (e.g.
    # "discord-bridge-teamspeak-2026-04-01") is never misflagged.
    if [[ "$line" =~ (gh-lancache-[a-z]+-[A-Za-z0-9]+-([0-9]+)|[a-z]-lancache-runner-([0-9]+)) ]]; then
        local found="${BASH_REMATCH[2]:-${BASH_REMATCH[3]}}"
        [[ -n "$found" && "$found" != "$my_token" ]] && return 0
    fi
    return 1
}

cmd_full_reset_check() {
    local my_token
    my_token="$(own_host_token)"
    echo "Host: $(hostname)   own_host_token=$my_token"
    echo
    echo "--- Shell history (informational size only; content not printed) ---"
    for f in /root/.bash_history "/home/${RUNNER_USER}/.bash_history" "/opt/${RUNNER_USER}/.bash_history" /root/.lesshst; do
        if sudo -n test -s "$f" 2>/dev/null; then
            echo "  $f: $(sudo -n wc -l "$f" 2>/dev/null | awk '{print $1}' || echo '?') lines -- will be truncated by full-reset-clean"
        fi
    done
    echo
    echo "--- SSH known_hosts ---"
    for f in /root/.ssh/known_hosts "/home/${RUNNER_USER}/.ssh/known_hosts" "/opt/${RUNNER_USER}/.ssh/known_hosts"; do
        if sudo -n test -s "$f" 2>/dev/null; then
            echo "  $f: $(sudo -n wc -l "$f" 2>/dev/null | awk '{print $1}' || echo '?') entries -- will be cleared by full-reset-clean"
        fi
    done
    echo
    echo "--- root authorized_keys: entries naming a DIFFERENT fleet host (report only, never auto-removed) ---"
    local ak_found=0
    if sudo -n test -f /root/.ssh/authorized_keys 2>/dev/null; then
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            if is_foreign_authorized_keys_line "$line"; then
                ak_found=1
                echo "  FOREIGN: $line"
            fi
        done < <(sudo -n cat /root/.ssh/authorized_keys 2>/dev/null)
    fi
    [[ "$ak_found" -eq 1 ]] || echo "  (none found)"
    echo
    echo "--- Stale journal machine-id directories (current: $(cat /etc/machine-id 2>/dev/null)) ---"
    local jd found_jd=0
    while IFS= read -r jd; do
        [[ -n "$jd" ]] || continue
        found_jd=1
        echo "  STALE: $jd -- will be removed by full-reset-clean"
    done < <(sudo -n find /var/log/journal -mindepth 1 -maxdepth 1 -type d ! -name "$(cat /etc/machine-id 2>/dev/null)" 2>/dev/null)
    [[ "$found_jd" -eq 1 ]] || echo "  (none found)"
    echo
    echo "--- Orphaned /home directories (no matching /etc/passwd entry) ---"
    local hd found_hd=0
    while IFS= read -r hd; do
        [[ -n "$hd" ]] || continue
        local uname
        uname="$(basename "$hd")"
        if ! getent passwd "$uname" >/dev/null 2>&1; then
            found_hd=1
            echo "  ORPHANED: $hd (no /etc/passwd entry for '$uname') -- will be removed by full-reset-clean"
        fi
    done < <(sudo -n find /home -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    [[ "$found_hd" -eq 1 ]] || echo "  (none found)"
    echo
    echo "--- Template-authoring scripts under /root ---"
    local ts found_ts=0
    while IFS= read -r ts; do
        [[ -n "$ts" ]] || continue
        found_ts=1
        echo "  $ts -- will be removed by full-reset-clean"
    done < <(sudo -n find /root -maxdepth 1 -type f -iname '*prepare*template*' 2>/dev/null)
    [[ "$found_ts" -eq 1 ]] || echo "  (none found)"
    echo
    echo "--- apt/dpkg history mentioning other fleet hosts (report only -- a real audit trail, never rewritten) ---"
    local al found_al=0
    while IFS= read -r al; do
        [[ -n "$al" ]] || continue
        found_al=1
        echo "  $al"
    done < <(sudo -n grep -lE '(lancache-(240|241|229|243)|192\.168\.1\.(240|241|229|243))' /var/log/apt/history.log* /var/log/dpkg.log* 2>/dev/null)
    [[ "$found_al" -eq 1 ]] || echo "  (none found)"
    echo
    echo "--- Hostname vs. primary IPv4 (report only -- see 'set-hostname' mode to fix) ---"
    hostname_mismatch_report
    echo
    echo "--- /etc/hosts self-reference for current hostname ---"
    ensure_hosts_self_reference check
    echo
    echo "--- hostid / machine-id (cannot detect duplicates locally -- see script header) ---"
    echo "  hostid: $(hostid)"
    echo "  machine-id: $(cat /etc/machine-id 2>/dev/null || echo '?')"
    echo "  -> full-reset-clean unconditionally regenerates both (cheap, safe, always unique)."
    echo
    echo "No files were changed (full-reset-check mode)."
}

# Applies an explicit, maintainer-provided hostname correction (issue #1622
# follow-up: confirmed real leftover-clone-hostname case on host .80).
# Deliberately takes the target hostname as a required argument rather than
# guessing one -- see hostname_mismatch_report's own comment for why this
# script cannot safely derive the "correct" value itself. Updates
# /etc/hostname, live `hostname`, and /etc/hosts' 127.0.1.1 entry (the
# Debian convention this fleet's hosts already follow), then reports what
# changed so the operator can confirm it against their own inventory.
cmd_set_hostname() {
    local new_hostname="${1:?Usage: set-hostname <new-hostname>}"
    local old_hostname
    old_hostname="$(hostname)"
    if [[ "$new_hostname" == "$old_hostname" ]]; then
        echo "Hostname is already '$old_hostname' -- nothing to do."
        return 0
    fi
    echo "Renaming host: '$old_hostname' -> '$new_hostname'"
    sudo hostnamectl set-hostname "$new_hostname"
    if sudo test -f /etc/hosts && sudo grep -q "127.0.1.1" /etc/hosts 2>/dev/null; then
        sudo sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t${new_hostname}/" /etc/hosts
        echo "Updated /etc/hosts' 127.0.1.1 entry."
    else
        # No Debian-standard 127.0.1.1 self-reference exists yet. Confirmed
        # real on host .80 (2026-08-21): instead of one, /etc/hosts carried
        # a stale, wrong-IP self-reference pointing at the TEMPLATE's own
        # identity ("192.168.1.85 gh-lancache-heavy-A-85 ..." on a host whose
        # real IP is 192.168.1.80) -- more clone residue this mode hadn't
        # covered yet. Replace any such self-reference line (old hostname,
        # or old hostname's own "-A-<num>" template form, on any IP) with a
        # correct 127.0.1.1 entry; if no matching line exists at all, append
        # one. Without this, sudo (and anything else resolving its own
        # hostname) fails with "unable to resolve host" on every invocation.
        if sudo grep -qE "^[0-9.]+[[:space:]].*\\b${old_hostname}\\b" /etc/hosts 2>/dev/null; then
            sudo sed -i "s/^[0-9.]\\+[[:space:]].*\\b${old_hostname}\\b.*/127.0.1.1\\t${new_hostname}/" /etc/hosts
            echo "Replaced stale self-reference line (was pointing at old hostname '${old_hostname}') with a 127.0.1.1 entry."
        else
            printf '127.0.1.1\t%s\n' "$new_hostname" | sudo tee -a /etc/hosts >/dev/null
            echo "No existing self-reference line found -- appended a new 127.0.1.1 entry."
        fi
    fi
    echo
    echo "Done. Current hostname: $(hostname)"
    echo "This does NOT reboot or restart any service -- some already-running"
    echo "processes (this shell's own prompt, an already-connected runner"
    echo "service) may keep showing the old name until they restart."
}

cmd_full_reset_clean() {
    if [[ "${CONFIRM_FULL_RESET:-}" != "yes" ]]; then
        echo "ERROR: refusing to act without CONFIRM_FULL_RESET=yes." >&2
        echo "Run 'full-reset-check' first and review its findings." >&2
        return 1
    fi

    for f in /root/.bash_history "/home/${RUNNER_USER}/.bash_history" "/opt/${RUNNER_USER}/.bash_history" /root/.lesshst; do
        if sudo -n test -f "$f" 2>/dev/null; then
            sudo -n truncate -s0 "$f"
            echo "Truncated $f"
        fi
    done

    for f in /root/.ssh/known_hosts "/home/${RUNNER_USER}/.ssh/known_hosts" "/opt/${RUNNER_USER}/.ssh/known_hosts"; do
        if sudo -n test -f "$f" 2>/dev/null; then
            sudo -n truncate -s0 "$f"
            echo "Cleared $f"
        fi
    done

    local jd
    while IFS= read -r jd; do
        [[ -n "$jd" ]] || continue
        echo "Removing stale journal dir: $jd"
        sudo -n rm -rf -- "$jd"
    done < <(sudo -n find /var/log/journal -mindepth 1 -maxdepth 1 -type d ! -name "$(cat /etc/machine-id 2>/dev/null)" 2>/dev/null)

    local hd
    while IFS= read -r hd; do
        [[ -n "$hd" ]] || continue
        local uname
        uname="$(basename "$hd")"
        if ! getent passwd "$uname" >/dev/null 2>&1; then
            echo "Removing orphaned home directory: $hd"
            sudo -n rm -rf -- "$hd"
        fi
    done < <(sudo -n find /home -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

    local ts
    while IFS= read -r ts; do
        [[ -n "$ts" ]] || continue
        echo "Removing template-authoring script: $ts"
        sudo -n rm -f -- "$ts"
    done < <(sudo -n find /root -maxdepth 1 -type f -iname '*prepare*template*' 2>/dev/null)

    echo "--- /etc/hosts self-reference for current hostname ---"
    ensure_hosts_self_reference fix

    echo "--- hostid / machine-id ---"
    dedupe_host_identity

    echo
    echo "full-reset-clean complete. NOT touched (report-only, see full-reset-check):"
    echo "  - /root/.ssh/authorized_keys (review any FOREIGN entries by hand)"
    echo "  - apt/dpkg history log content (a real audit trail, never rewritten)"
    echo "Re-run 'full-reset-check' to confirm."
}

# --- purge-pve: remove an accidentally-included nested Proxmox VE stack ----
#
# Confirmed real, issue #1622 follow-up (2026-08-21): every host in this
# fleet's template carries a COMPLETE, running Proxmox VE 9.2 management
# stack inside the guest itself (pveproxy, pvedaemon, pve-cluster/pmxcfs,
# pve-ha-crm/lrm + its watchdog-mux, pvestatd, pvescheduler, pve-firewall,
# proxmox-firewall, corosync, spiceproxy, qmeventd, pve-lxc-syscalld,
# pve-qemu-kvm, ...) -- almost certainly because the template disk was
# cloned from an actual Proxmox host rather than a lean Debian image. This
# is pure, unwanted overhead for a CI runner guest: measured on host .81,
# these processes alone held ~1.8-1.9 GB RSS permanently resident, a
# significant fraction of a light host's 3.8 GB nominal RAM, and a
# concrete contributor to that host's own OOM-kill of a real CI job the
# same day (see PR #1624 history / issue #1622 for the incident details).
#
# CRITICAL: `proxmox-kernel-*`/`proxmox-default-kernel`/`pve-firmware`/
# `pve-edk2-firmware*` are DELIBERATELY EXCLUDED and must stay excluded --
# confirmed real on host .81: these VMs have NO regular Debian
# `linux-image-*` kernel installed at all, only the Proxmox-branded kernel
# packages. Purging those would leave the host with zero bootable kernel.
# purge_pve_package_list() is the single source of truth both modes below
# use, so `check`'s simulation and `clean`'s real run can never drift apart.
purge_pve_package_list() {
    echo "corosync libcorosync-common4 libproxmox-acme-perl libproxmox-acme-plugins libproxmox-backup-qemu0 libproxmox-rs-perl libpve-access-control libpve-apiclient-perl libpve-cluster-api-perl libpve-cluster-perl libpve-common-perl libpve-guest-common-perl libpve-http-server-perl libpve-network-api-perl libpve-network-perl libpve-notify-perl libpve-rs-perl libpve-storage-perl proxmox-backup-client proxmox-backup-file-restore proxmox-backup-restore-image proxmox-firewall proxmox-mail-forward proxmox-mini-journalreader proxmox-offline-mirror-docs proxmox-offline-mirror-helper proxmox-termproxy proxmox-ve proxmox-websocket-tunnel proxmox-widget-toolkit pve-cluster pve-container pve-docs pve-esxi-import-tools pve-firewall pve-ha-manager pve-i18n pve-lxc-syscalld pve-manager pve-nvidia-vgpu-helper pve-qemu-kvm pve-xtermjs pve-yew-mobile-gui pve-yew-mobile-i18n proxmox-enterprise-support-keyring"
}

# Names of the actively-running services this package set owns, stopped
# before the purge so dpkg's own prerm scripts aren't racing an
# auto-restarted daemon (confirmed real on .81: pve-cluster and
# proxmox-firewall came back "active" on their own between two individual
# `systemctl stop` calls -- apt's removal itself is what reliably wins).
purge_pve_service_list() {
    echo "pveproxy pvedaemon pvestatd pvescheduler spiceproxy pve-ha-crm pve-ha-lrm pve-firewall proxmox-firewall pve-lxc-syscalld qmeventd pve-cluster corosync pvefw-logger proxmox-firewall.timer watchdog-mux"
}

cmd_purge_pve_check() {
    echo "--- Installed pve-*/proxmox-*/corosync/pmxcfs packages ---"
    dpkg -l 2>/dev/null | grep -iE '^ii.*(pve-|proxmox-|pmxcfs|corosync)' || echo "  (none found -- already clean)"
    echo
    echo "--- KEPT regardless (kernel/firmware -- never purged, see header) ---"
    dpkg -l 2>/dev/null | grep -iE '^ii.*(proxmox-kernel|proxmox-default-kernel|proxmox-kernel-helper|pve-firmware|pve-edk2-firmware)' || echo "  (none installed)"
    echo
    echo "--- Active pve/proxmox/corosync services right now ---"
    systemctl list-units --all --type=service,timer --no-pager 2>/dev/null | grep -iE 'pve|corosync|proxmox|pmxcfs' | grep -i active || echo "  (none active)"
    echo
    echo "--- /etc/pve (pmxcfs FUSE mount) dependents ---"
    mount 2>/dev/null | grep -i pve || echo "  not currently mounted"
    local dep_found=0
    if sudo -n grep -qi pve /etc/fstab 2>/dev/null; then
        echo "  FOUND: /etc/fstab references pve -- review before purging"
        dep_found=1
    fi
    if sudo -n lsof +D /etc/pve >/dev/null 2>&1; then
        echo "  FOUND: open file handles under /etc/pve -- review before purging"
        dep_found=1
    fi
    if sudo -n grep -rli pve /etc/cron.d /etc/cron.daily /etc/cron.hourly 2>/dev/null | grep -q .; then
        echo "  FOUND: a cron.d/daily/hourly entry references pve -- review before purging"
        dep_found=1
    fi
    [[ "$dep_found" -eq 1 ]] || echo "  (no fstab/lsof/cron dependents found)"
    echo
    echo "--- Current RSS held by pve-related processes ---"
    local rss_mb
    # `ps aux` (not pgrep) is needed here for its RSS column ($6); pgrep
    # alone cannot report memory usage.
    # shellcheck disable=SC2009
    rss_mb="$(ps aux 2>/dev/null | grep -E 'pve|pmxcfs|corosync|spiceproxy|qmeventd' | grep -v grep | awk '{sum+=$6} END {if (sum) print sum/1024; else print 0}')"
    echo "  ${rss_mb:-0} MB"
    echo
    echo "--- Simulated purge (no kernel/firmware package must appear below) ---"
    # shellcheck disable=SC2046
    sudo -n apt-get purge --simulate $(purge_pve_package_list) 2>&1 | tail -20
    echo
    echo "No files were changed (purge-pve-check mode)."
}

cmd_purge_pve() {
    if [[ "${CONFIRM_PURGE_PVE:-}" != "yes" ]]; then
        echo "ERROR: refusing to act without CONFIRM_PURGE_PVE=yes." >&2
        echo "Run 'purge-pve-check' first and review its findings -- this removes a" >&2
        echo "real, currently-running management stack (pveproxy/pve-cluster/" >&2
        echo "pve-ha-manager/corosync/...). Test on one host before fleet-wide rollout" >&2
        echo "(issue #1622: verified end-to-end, including a real reboot, on host .81" >&2
        echo "before this mode existed)." >&2
        return 1
    fi
    # Fail-closed pre-flight: re-simulate right before acting and refuse if a
    # kernel/firmware package would be touched -- never trust that the
    # package list stayed accurate as this fleet's images change over time.
    local sim
    # shellcheck disable=SC2046
    sim="$(sudo -n apt-get purge --simulate $(purge_pve_package_list) 2>&1)"
    if grep -qiE 'proxmox-kernel|proxmox-default-kernel|proxmox-kernel-helper|pve-firmware|pve-edk2-firmware' <<<"$sim"; then
        echo "ERROR: the simulated purge would touch a kernel/firmware package -- refusing." >&2
        echo "This host's package set has likely changed since this script was written." >&2
        echo "$sim" >&2
        return 1
    fi

    echo "Stopping pve/proxmox/corosync services..."
    # shellcheck disable=SC2046
    sudo -n systemctl stop $(purge_pve_service_list) 2>&1 || true

    echo "Overriding pve-apt-hook's proxmox-ve removal guard (deliberate, confirmed"
    echo "real on .81 -- apt otherwise refuses to remove the proxmox-ve meta-package)."
    sudo -n touch /please-remove-proxmox-ve

    echo "Purging..."
    # shellcheck disable=SC2046
    sudo -n DEBIAN_FRONTEND=noninteractive apt-get purge -y $(purge_pve_package_list) 2>&1

    echo "Running apt autoremove (kernel/firmware packages are still manually"
    echo "installed / depended-on and will not be swept by this)..."
    sudo -n DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>&1

    echo
    echo "--- Verification ---"
    echo "Remaining pve-*/proxmox-*/corosync/pmxcfs packages (should be kernel/firmware only):"
    dpkg -l 2>/dev/null | grep -iE '^ii.*(pve-|proxmox-|pmxcfs|corosync)' || echo "  (none)"
    echo "Remaining pve-related processes (should be none):"
    # Listing full command lines for a human to read is the point here, not
    # just matching PIDs (pgrep -l truncates).
    # shellcheck disable=SC2009
    ps aux 2>/dev/null | grep -E 'pve|pmxcfs|corosync|spiceproxy|qmeventd' | grep -v grep || echo "  (none)"
    echo
    echo "purge-pve complete. Recommended next steps, not automated by this mode:"
    echo "  - verify docker/network/the runner service still work"
    echo "  - a real reboot test (issue #1622: done manually on .81, kernel"
    echo "    packages were untouched and it came back up cleanly with the same"
    echo "    'uname -r' as before) before trusting this on a fleet-wide rollout"
}

# Content copied verbatim from the live /opt/lancache-ci-hooks/pre-job-
# cleanup.sh and post-job-cleanup.sh on lancache-240 (2026-08-21) -- these
# hooks are host-local by design, same as they already are on every
# existing runner host (not repo-tracked, unlike lancache-ci-cleanup.sh).
install_ci_hooks() {
    sudo mkdir -p "$RUNNER_HOOKS_DIR"
    sudo tee "$RUNNER_HOOKS_DIR/pre-job-cleanup.sh" >/dev/null <<'HOOKEOF'
#!/bin/bash
# lancache-ng self-hosted runner pre-job hook (ACTIONS_RUNNER_HOOK_JOB_STARTED)
#
# What: resets $GITHUB_WORKSPACE ownership to this runner's own user before
#   checkout runs, mirroring post-job-cleanup.sh's own reset logic.
# Why: post-job-cleanup.sh only resets ownership as best-effort at the END
#   of the PREVIOUS job -- if that job was killed/crashed before its own
#   hook ran, foreign-UID files (e.g. a container test writing as a non-
#   host UID) can still block the NEXT job's `actions/checkout` cleanup
#   step with EACCES. Running the same reset again at job START makes this
#   independent of whether the previous job's own cleanup actually ran.
#   Confirmed real incident: PR #1532, 2026-08-15, actions-runner-1 on
#   lancache-241 -- .setup-cli-simulation-tmp left a file `checkout`
#   could not unlink even though the post-job hook had reported success.
set -euo pipefail

if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -d "$GITHUB_WORKSPACE" ]; then
    if sudo -n chown -R "$(id -u):$(id -g)" "$GITHUB_WORKSPACE" 2>/dev/null; then
        echo "[pre-job-hook] reset ownership of $GITHUB_WORKSPACE to $(id -un):$(id -gn)"
    else
        echo "[pre-job-hook] WARNING: could not reset ownership of $GITHUB_WORKSPACE (sudo unavailable or failed) -- checkout may hit EACCES if the workspace carries foreign-UID files"
    fi
fi
HOOKEOF
    sudo tee "$RUNNER_HOOKS_DIR/post-job-cleanup.sh" >/dev/null <<'HOOKEOF'
#!/bin/bash
# lancache-ng self-hosted runner post-job cleanup hook (ACTIONS_RUNNER_HOOK_JOB_COMPLETED)
#
# full-setup-validate.yml's own steps run `docker compose down --volumes
# --remove-orphans` as part of a normal, successful job -- this hook exists
# only as a safety net for the crash/cancel case, where a job is killed
# before its own teardown step can run, leaving a Docker bridge network
# (and its subnet) allocated on the host indefinitely. That leftover state
# is exactly what caused repeated "validation subnet overlaps existing
# network state" collisions this project has hit.
#
# Only removes lancache-ng-validation_* networks that currently have ZERO
# attached containers. A network with active containers is left alone
# unconditionally -- this host runs multiple runner processes sharing one
# Docker daemon, so a network could belong to a job still in progress on a
# sibling runner process right now, and this hook must never touch that.
set -euo pipefail

for net in $(docker network ls --filter name=lancache-ng-validation --format '{{.Name}}'); do
    containers=$(docker network inspect "$net" --format '{{len .Containers}}' 2>/dev/null || echo "0")
    if [ "$containers" -eq 0 ]; then
        echo "[cleanup-hook] removing orphaned validation network: $net (0 attached containers)"
        docker network rm "$net" || echo "[cleanup-hook] WARNING: failed to remove $net, leaving in place"
    else
        echo "[cleanup-hook] leaving $net alone, $containers active container(s) attached"
    fi
done

# Reset ownership of THIS job's own workspace back to the runner's own user.
# A test that bind-mounts a directory into a container writing as a non-host
# UID (e.g. a Kea/PDNS process UID) can leave files this runner's own user
# cannot remove. The NEXT job scheduled onto this same runner process then
# fails at its own `actions/checkout` cleanup step with `EACCES: permission
# denied, rmdir ...` trying to clear the old workspace -- confirmed live
# (2026-07-13, PR #794's Kea config-snapshot simulation left files owned by
# UID 10001 under .setup-reset-kea-config-simulation-tmp/, blocking every
# subsequent job on this runner slot until manually chowned via SSH).
#
# Scoped to exactly $GITHUB_WORKSPACE (this job's own checkout directory),
# never anything broader -- multiple runner processes share this host, and a
# recursive chown outside this one job's own workspace could touch another
# job's in-progress files. Best-effort: sudo may not be configured on every
# host/user combination, and this hook must never fail the job it's cleaning
# up after over a cosmetic ownership reset.
if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -d "$GITHUB_WORKSPACE" ]; then
    if sudo -n chown -R "$(id -u):$(id -g)" "$GITHUB_WORKSPACE" 2>/dev/null; then
        echo "[cleanup-hook] reset ownership of $GITHUB_WORKSPACE to $(id -un):$(id -gn)"
    else
        echo "[cleanup-hook] WARNING: could not reset ownership of $GITHUB_WORKSPACE (sudo unavailable or failed) -- a future checkout on this slot may hit EACCES if a job left foreign-UID files behind"
    fi
fi
HOOKEOF
    sudo chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOOKS_DIR/pre-job-cleanup.sh" "$RUNNER_HOOKS_DIR/post-job-cleanup.sh"
    sudo chmod 0755 "$RUNNER_HOOKS_DIR/pre-job-cleanup.sh" "$RUNNER_HOOKS_DIR/post-job-cleanup.sh"
    echo "Installed $RUNNER_HOOKS_DIR/{pre,post}-job-cleanup.sh"
}

cmd_host_prep() {
    local sudoers_file="/etc/sudoers.d/${RUNNER_USER}-nopasswd"
    if sudo -n test -f "$sudoers_file" 2>/dev/null; then
        echo "$sudoers_file already present, leaving as-is."
    else
        echo "${RUNNER_USER} ALL=(ALL) NOPASSWD:ALL" | sudo tee "$sudoers_file" >/dev/null
        sudo chmod 0440 "$sudoers_file"
        sudo visudo -cf "$sudoers_file" || { echo "ERROR: visudo rejected $sudoers_file -- removing it." >&2; sudo rm -f "$sudoers_file"; return 1; }
        echo "Installed $sudoers_file"
    fi

    if id -nG "$RUNNER_USER" 2>/dev/null | grep -qw docker; then
        echo "$RUNNER_USER already in docker group, leaving as-is."
    else
        sudo usermod -aG docker "$RUNNER_USER"
        echo "Added $RUNNER_USER to docker group (takes effect on next login/SSH session)."
    fi

    install_ci_hooks

    if [[ -f "$SCRIPT_DIR/lancache-ci-cleanup.sh" ]]; then
        sudo install -m 0755 "$SCRIPT_DIR/lancache-ci-cleanup.sh" /usr/local/sbin/lancache-ci-cleanup.sh
        sudo install -m 0644 "$SCRIPT_DIR/lancache-ci-cleanup.service" /etc/systemd/system/lancache-ci-cleanup.service
        sudo install -m 0644 "$SCRIPT_DIR/lancache-ci-cleanup.timer" /etc/systemd/system/lancache-ci-cleanup.timer
        sudo systemctl daemon-reload
        sudo systemctl enable --now lancache-ci-cleanup.timer
        echo "Installed and enabled lancache-ci-cleanup.timer (see README.md in this directory)."
    else
        echo "WARNING: lancache-ci-cleanup.sh/.service/.timer not found next to this script ($SCRIPT_DIR) -- skipping. Copy the whole tools/runner-host/ directory to the host, not just this one file." >&2
    fi

    echo
    echo "host-prep complete. This does NOT touch /etc/docker/daemon.json (storage"
    echo "driver and other pre-existing host tuning are left exactly as they are);"
    echo "add a 'proxies' block manually per README.md if this host needs the LAN"
    echo "proxy other hosts use, and it does NOT run config.sh, install a runner"
    echo "systemd unit, or start any runner service."

    # Heavy-tier reminder (issue #1619/#1622, 2026-08-21): trusted Rust CI
    # jobs on lancache-heavy fail outright without the sccache client
    # tooling -- host-prep cannot install this itself (see sccache-fetch's
    # own header for why: it's a host-to-host file copy, not a build or
    # download this script can do unattended), so it only reminds here
    # rather than silently leaving a heavy host half-prepped with no signal.
    if [[ "$(hostname)" == *heavy* ]]; then
        echo
        echo "This looks like a HEAVY-tier host. Run 'sccache-check' next -- if it"
        echo "reports missing tooling, stage sccache/sccache-dist/config/client.conf"
        echo "from a known-working heavy host (e.g. lancache-240) via scp, then run"
        echo "'sccache-fetch <staged-dir>'. See README.md and this script's own"
        echo "sccache-check/-fetch header comments for the full background."
    fi
}

cmd_runner_fetch() {
    local instance_dir="${1:?Usage: runner-fetch <instance-dir> [version]}"
    local version="${2:-2.336.0}"
    local tarball="actions-runner-linux-x64-${version}.tar.gz"
    local url="https://github.com/actions/runner/releases/download/v${version}/${tarball}"
    local tmp_tarball
    tmp_tarball="$(mktemp -t "${tarball}.XXXXXX")"

    echo "Fetching expected checksum for v${version} from the GitHub Releases API..."
    local expected_digest
    expected_digest="$(curl -fsSL "https://api.github.com/repos/actions/runner/releases/tags/v${version}" \
        | jq -r --arg name "$tarball" '.assets[] | select(.name == $name) | .digest' 2>/dev/null || true)"
    expected_digest="${expected_digest#sha256:}"
    if [[ -z "$expected_digest" ]]; then
        echo "ERROR: could not fetch an expected sha256 digest for $tarball from the GitHub API -- refusing to install unverified. Check the version string or network access." >&2
        rm -f "$tmp_tarball"
        return 1
    fi

    echo "Downloading $url ..."
    curl -fsSL -o "$tmp_tarball" "$url"
    local actual_digest
    actual_digest="$(sha256sum "$tmp_tarball" | awk '{print $1}')"
    if [[ "$actual_digest" != "$expected_digest" ]]; then
        echo "ERROR: checksum mismatch for $tarball -- expected $expected_digest, got $actual_digest. Refusing to extract." >&2
        rm -f "$tmp_tarball"
        return 1
    fi
    echo "Checksum verified: $actual_digest"

    sudo mkdir -p "$instance_dir"
    sudo tar xzf "$tmp_tarball" -C "$instance_dir"
    sudo chown -R "$RUNNER_USER:$RUNNER_USER" "$instance_dir"
    rm -f "$tmp_tarball"

    # Hook wiring -- must exist before the runner service is ever started,
    # or the pre/post-job-cleanup hooks are silently absent on the very
    # first job this instance picks up.
    cat <<ENVEOF | sudo tee "$instance_dir/.env" >/dev/null
LANG=C
ACTIONS_RUNNER_HOOK_JOB_STARTED=${RUNNER_HOOKS_DIR}/pre-job-cleanup.sh
ACTIONS_RUNNER_HOOK_JOB_COMPLETED=${RUNNER_HOOKS_DIR}/post-job-cleanup.sh
ENVEOF
    sudo chown "$RUNNER_USER:$RUNNER_USER" "$instance_dir/.env"

    echo
    echo "Extracted actions-runner v${version} into $instance_dir and wrote its .env"
    echo "hook wiring. NOT registered yet -- run config.sh there by hand with a fresh"
    echo "registration token (never pass it as a literal argv string over ssh; pipe"
    echo "it over stdin instead). Maintainer decision (issue #1622, 2026-08-21):"
    echo "for this fleet (.80-.91 and on), pass --name \$(hostname) EXACTLY -- e.g."
    echo "'$(hostname)' on this host -- NOT the old fleet's letter-prefix scheme"
    echo "(a-lancache-runner-240-1 etc., which only applies to the pre-existing"
    echo "229/240/241/243 hosts and must never be copied onto a new host)."
    echo "Then 'sudo ./svc.sh install' and hold off on 'sudo ./svc.sh start' until"
    echo "the go-ahead to accept real jobs is confirmed."
}

# --- sccache-check: verify the sccache client tooling heavy hosts need ----
#
# Confirmed real (issue #1619/#1622 follow-up, 2026-08-21): `configure-rust-
# sccache` (`.github/actions/configure-rust-sccache/action.yml`), used by
# every trusted Rust CI job routed to `lancache-heavy` (build-push.yml,
# codeql.yml -- never lancache-light, confirmed by grepping every
# `runs-on:` line preceding a `configure-rust-sccache` use in both files),
# fails a real job outright with "sccache is required on the runner when
# Redis-backed sccache or sccache-dist is configured" the moment `command -v
# sccache` doesn't resolve. New heavy hosts (.80/.84/.85/.86 confirmed
# missing it) never got this installed as part of their host-prep.
#
# MAINTAINER DECISION, NOT `apt install sccache` and NOT rebuilt from source
# on each new host: this project's sccache needs `--features redis,dist-
# client` (see `tools/build-tools/Dockerfile`'s own `cargo install sccache
# --no-default-features --features redis,dist-client` for the container-
# image copy) -- Debian's packaged sccache lacks Redis support entirely, and
# rebuilding via `cargo install` requires a full rustup+cargo toolchain this
# fleet's runner hosts don't otherwise need. Confirmed on lancache-240 (an
# existing working heavy host, 2026-08-21): its whole client-side sccache
# tooling was itself originally copied host-to-host at identical paths for
# exactly this reason -- rebuilding from source was never how any of these
# hosts actually got their sccache binary. This mode therefore only
# VERIFIES what `sccache-fetch` (below) installs; it does not build or
# download anything itself.
#
# Deliberately CLIENT-role only. `sccache-dist-server.service` (accepting
# distributed builds FROM other clients) is a separate, additional
# capacity-expansion decision -- its config (`server.conf`) embeds a
# per-host `public_addr` and a JWT token whose payload names that exact
# server_id, so it is NOT safely copyable between hosts the way the client
# config is; standing up a new dist-server needs a fresh token issued by
# whoever administers the scheduler at the dist-scheduler-url, not a file
# copy. Out of scope here.
cmd_sccache_check() {
    echo "--- sccache client binaries ---"
    for f in /usr/local/bin/sccache /usr/local/bin/sccache-dist; do
        if [[ -x "$f" ]]; then
            echo "  $f: present ($(sha256sum "$f" | awk '{print $1}'))"
        else
            echo "  $f: MISSING"
        fi
    done
    echo
    echo "--- sccache client config ---"
    for f in /opt/codex/.config/sccache/config /opt/codex/sccache-dist/client.conf; do
        if sudo -n test -f "$f" 2>/dev/null; then
            echo "  $f: present"
        else
            echo "  $f: MISSING"
        fi
    done
    if sudo -n test -d /opt/sccache/dist-client 2>/dev/null; then
        echo "  /opt/sccache/dist-client: present"
    else
        echo "  /opt/sccache/dist-client: MISSING"
    fi
    echo
    echo "--- Live check (requires the config above; reaches the real scheduler) ---"
    if [[ -x /usr/local/bin/sccache ]]; then
        HOME="/opt/${RUNNER_USER}" /usr/local/bin/sccache --version 2>&1
        HOME="/opt/${RUNNER_USER}" /usr/local/bin/sccache --dist-status 2>&1
    else
        echo "  (skipped -- sccache binary missing)"
    fi
    echo
    echo "No files were changed (sccache-check mode)."
}

# Installs the sccache client tooling from files already staged on THIS
# host at the given source directory (see the script header above for why
# this is a copy, not a build). The orchestrating machine is expected to
# have already `scp`'d sccache, sccache-dist, config, and client.conf from
# a known-working heavy host (e.g. lancache-240) into that directory --
# this mode only does the LOCAL install step (permissions, ownership,
# directory layout), matching the exact paths confirmed on lancache-240.
cmd_sccache_fetch() {
    local src_dir="${1:?Usage: sccache-fetch <source-dir-with-staged-files>}"
    for f in sccache sccache-dist config client.conf; do
        if [[ ! -f "$src_dir/$f" ]]; then
            echo "ERROR: $src_dir/$f not found -- stage it first (scp from a known-working heavy host)." >&2
            return 1
        fi
    done
    sudo install -o "$RUNNER_USER" -g "$RUNNER_USER" -m 0755 "$src_dir/sccache" /usr/local/bin/sccache
    sudo install -o root -g root -m 0755 "$src_dir/sccache-dist" /usr/local/bin/sccache-dist
    mkdir -p "/opt/${RUNNER_USER}/.config/sccache"
    install -m 0644 "$src_dir/config" "/opt/${RUNNER_USER}/.config/sccache/config"
    sudo mkdir -p "/opt/${RUNNER_USER}/sccache-dist"
    sudo install -o "$RUNNER_USER" -g "$RUNNER_USER" -m 0640 "$src_dir/client.conf" "/opt/${RUNNER_USER}/sccache-dist/client.conf"
    sudo mkdir -p /opt/sccache/dist-client
    sudo chown "$RUNNER_USER:$RUNNER_USER" /opt/sccache /opt/sccache/dist-client
    sudo chmod 2775 /opt/sccache /opt/sccache/dist-client
    echo "Installed sccache client tooling. Verifying:"
    HOME="/opt/${RUNNER_USER}" sudo -u "$RUNNER_USER" /usr/local/bin/sccache --version
    HOME="/opt/${RUNNER_USER}" sudo -u "$RUNNER_USER" /usr/local/bin/sccache --dist-status
    echo "Run 'sccache-check' to confirm the full picture."
}

print_usage() {
    cat <<'EOF'
Usage: bash lancache-ci-runner-clone-init.sh <mode> [args...]

Modes:
  check                        (default) Read-only report. Writes nothing.
  clean                        Removes clone artifacts 'check' flagged as
                                foreign. Requires CONFIRM_CLEAN=yes.
  host-prep                    Idempotent sudoers/docker-group/ci-hooks/
                                cleanup-timer setup. Never touches
                                daemon.json or runner registration.
  runner-fetch <dir> [version] Download+verify+extract a runner release
                                directly into <dir> (default version 2.336.0)
                                and write its .env hook wiring. Does not
                                register or start anything.
  full-reset-check             Read-only broader de-clone survey (shell
                                history, known_hosts, foreign authorized_keys
                                entries, stale journal machine-id dirs,
                                orphaned /home dirs, template-authoring
                                scripts, apt/dpkg history mentions). Writes
                                nothing.
  full-reset-clean             Acts on what 'full-reset-check' flagged as
                                safe to auto-remove. Requires
                                CONFIRM_FULL_RESET=yes. Never touches
                                authorized_keys, apt/dpkg history, or the
                                hostname -- those stay report-only/manual,
                                see the script's own header.
  set-hostname <name>          Applies an explicit, maintainer-provided
                                hostname correction (hostnamectl + /etc/hosts
                                127.0.1.1). full-reset-check flags a likely
                                leftover clone hostname (mismatched against
                                this host's own primary IPv4) but never
                                guesses a replacement -- use this mode once
                                you know the correct name.
  purge-pve-check              Read-only inventory of the accidentally-
                                included nested Proxmox VE stack (see the
                                script's own header): installed packages,
                                active services, /etc/pve dependents,
                                current RSS held, and a simulated purge
                                preview. Writes nothing.
  purge-pve                    Stops the pve/proxmox/corosync services and
                                purges the management-stack packages.
                                Requires CONFIRM_PURGE_PVE=yes. NEVER
                                touches proxmox-kernel-*/pve-firmware/
                                pve-edk2-firmware* (this fleet has no
                                regular Debian kernel -- purging those would
                                leave the host unbootable). Before running
                                on a host with the runner service live,
                                check GitHub's busy status first and stop
                                the runner service; a real reboot test
                                afterward is strongly recommended (verified
                                end-to-end on host .81, issue #1622).
  sccache-check                 Read-only: reports whether the sccache
                                 client tooling (heavy hosts only -- see
                                 script header) is installed, and if so
                                 live-verifies it against the real
                                 scheduler via --dist-status. Writes
                                 nothing.
  sccache-fetch <dir>            Installs sccache/sccache-dist and their
                                 client configs from files already staged
                                 at <dir> on this host (scp them from a
                                 known-working heavy host such as
                                 lancache-240 first -- this mode does not
                                 build or download anything itself, see
                                 the script header for why). Heavy hosts
                                 only; light hosts never need this.

Env overrides: RUNNER_OPT_ROOT (default /opt), RUNNER_HOOKS_DIR
(default /opt/lancache-ci-hooks), RUNNER_USER (default codex),
STRAY_ARCHIVE_MIN_BYTES (default 1 GiB).
EOF
}

main() {
    local mode="${1:-check}"
    shift || true
    case "$mode" in
        check) cmd_check ;;
        clean) cmd_clean ;;
        host-prep) cmd_host_prep ;;
        runner-fetch) cmd_runner_fetch "$@" ;;
        full-reset-check) cmd_full_reset_check ;;
        full-reset-clean) cmd_full_reset_clean ;;
        set-hostname) cmd_set_hostname "$@" ;;
        purge-pve-check) cmd_purge_pve_check ;;
        purge-pve) cmd_purge_pve ;;
        sccache-check) cmd_sccache_check ;;
        sccache-fetch) cmd_sccache_fetch "$@" ;;
        -h|--help) print_usage ;;
        *)
            echo "ERROR: unknown mode '$mode'" >&2
            print_usage >&2
            return 1
            ;;
    esac
}

# Guard direct-execution-only behavior so a bats fixture can `source` this
# file (to call own_host_token/is_foreign_runner_dir directly against a
# fixture) without also triggering a real run of main() against this
# process's actual argv/environment.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
