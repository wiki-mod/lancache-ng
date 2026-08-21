#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# CI runner host bootstrap: prepare a freshly provisioned (or disk-cloned)
# self-hosted runner host for GitHub Actions registration, WITHOUT ever
# performing the registration itself.
#
# Background: new runner host VMs in this fleet are provisioned as disk
# clones of an existing, already-registered runner host. Confirmed by direct
# SSH inspection: a freshly cloned host's /opt/actions-runner-N directories
# are NOT empty -- they carry the SOURCE host's own
# .runner/.credentials/.credentials_rsaparams files (private key material a
# runner uses to authenticate to GitHub as one specific, already-registered
# identity), plus multi-GB leftover backup archives (runner*.tgz) from
# whatever imaging process produced the clone. A runner identity belonging
# to one host must never be left sitting on a different host (maintainer
# decision: not treated as an active credential-compromise incident since
# nothing on the clone side ever started the runner service or communicated
# with GitHub using it, but it must be detected and removed before the
# CLONE is put into service). See issue #1622 for the full incident history.
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
#   host-prep     Idempotent, but NOT non-disruptive: sudoers NOPASSWD
#                 drop-in for the runner user, adds that user to the docker
#                 group, installs the /opt/lancache-ci-hooks/{pre,post}-job-
#                 cleanup.sh pair (host-local, not repo-tracked -- same as
#                 they already are on every existing runner host) and this
#                 repo's own lancache-ci-cleanup timer/service (installed
#                 from the sibling files in this same directory). ALSO runs
#                 a full `apt-get dist-upgrade`/`full-upgrade` on every
#                 invocation (see enable_backports below) -- this can remove
#                 or replace packages and restart running services via their
#                 maintainer scripts; run only during a maintenance window,
#                 not as a routine no-op re-check.
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
# authoring host with `core.filemode=false` (Rule-Ref: AG-VAL-024), so this
# script must not depend on it being set.
set -euo pipefail

RUNNER_OPT_ROOT="${RUNNER_OPT_ROOT:-/opt}"
RUNNER_HOOKS_DIR="${RUNNER_HOOKS_DIR:-/opt/lancache-ci-hooks}"
RUNNER_USER="${RUNNER_USER:-codex}"
# Minimum size before a stray /opt/*.tgz|*.tar.gz is flagged as a leftover
# clone-imaging backup rather than something intentionally placed there --
# the two confirmed real examples (issue #1622) were 6.7 GB and 14.3 GB.
STRAY_ARCHIVE_MIN_BYTES="${STRAY_ARCHIVE_MIN_BYTES:-1073741824}" # 1 GiB

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolves RUNNER_USER's actual primary group, never assuming a group of the
# same name exists purely by convention (a `RUNNER_USER` override such as
# `github-runner` with primary group `ci-runners` would otherwise make every
# `chown "$RUNNER_USER:$RUNNER_USER"` call below fail after this script has
# already written files as that user). Confirmed on the real fleet
# (2026-08-21, host .81, `id codex` -> `uid=1000(codex) gid=1000(codex)`)
# that the default RUNNER_USER's primary group is in fact named the same as
# the user, so this resolves to the literal string "codex" in the common
# case while staying correct for any override. Falls back to "$RUNNER_USER"
# itself only if the lookup fails outright (should not happen for any caller
# reached after `cmd_host_prep`'s own upfront `getent passwd` check).
runner_group() {
    id -gn "$RUNNER_USER" 2>/dev/null || echo "$RUNNER_USER"
}

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

# What: Return the last octet of own_primary_ipv4 as a second, independent
#   fleet host-number token.
# Why: own_host_token is derived from the OS `hostname`, which a real disk
#   clone can carry over verbatim from its source host (confirmed real on
#   host .80 via hostname_mismatch_report); the primary IPv4 address is live
#   network configuration a clone cannot copy, so it is authoritative where
#   the hostname is not. is_foreign_runner_dir cross-checks both instead of
#   trusting the hostname-derived token alone. Empty-safe under `set -e`
#   the same way own_host_token/own_primary_ipv4 are: no IP determined means
#   empty output, never a non-zero exit.
# From: #1624 (PRRT_kwDOS--bIM6bDjcN)
own_ip_token() {
    local ip
    ip="$(own_primary_ipv4)"
    [[ -n "$ip" ]] || return 0
    echo "${ip##*.}"
}

# What: Extract the fleet host-number segment from a runner agentName or an
#   authorized_keys comment, using this project's two known naming schemes.
# Why: A generic "does the token appear as some hyphen-delimited segment"
#   match (the shape is_foreign_runner_dir used to use) can match the WRONG
#   segment -- confirmed real: on host 1, "a-lancache-runner-240-1" matched
#   host token "1" against the trailing runner-INSTANCE suffix instead of
#   the host-number segment "240", misclassifying host 240's directory as
#   this host's own. Anchoring to the two actual naming schemes (shared with
#   is_foreign_authorized_keys_line, which already used this structured
#   match) makes both call sites extract the same, correct segment.
# From: #1624 (PRRT_kwDOS--bIM6bCrpC)
extract_fleet_host_number() {
    local name="$1"
    if [[ "$name" =~ (gh-lancache-[a-z]+-[A-Za-z0-9]+-([0-9]+)|[a-z]-lancache-runner-([0-9]+)) ]]; then
        echo "${BASH_REMATCH[2]:-${BASH_REMATCH[3]}}"
    fi
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
    # What: Only count an active (non-commented) /etc/hosts line as a real match.
    # Why: A commented-out stale line must not be read as "already resolves";
    # capture-then-here-string avoids piping into an early-exiting grep -q
    # under this script's pipefail (Rule-Ref: AG-VAL-032).
    # From: #1624
    local active_hosts_lines
    active_hosts_lines="$(sudo -n grep -vE '^[[:space:]]*#' /etc/hosts 2>/dev/null || true)"
    if grep -qE "\\b${my_hostname}\\b" <<<"$active_hosts_lines"; then
        echo "  OK: /etc/hosts already resolves current hostname '${my_hostname}'."
        return 0
    fi
    echo "  STALE: /etc/hosts has no line resolving current hostname '${my_hostname}'."
    if [[ "$mode" != "fix" ]]; then
        echo "    -> will be corrected by full-reset-clean."
        return 0
    fi
    # What: Add a dedicated self-reference instead of rewriting an address line.
    # Why: Address lines can carry unrelated local aliases that must survive provisioning.
    # From: #1624
    printf '127.0.1.1\t%s\n' "$my_hostname" | sudo -n tee -a /etc/hosts >/dev/null
    echo "    Fixed: appended a 127.0.1.1 entry without changing aliases on ${my_ip:-other addresses}."
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
    # What: Regenerate /etc/hostid and verify the write actually happened.
    # Why: The previous `|| true` swallowed a missing/failing zgenhostid,
    # leaving /etc/hostid deleted with no replacement while still reporting
    # success -- a real hostid regression, not just a masked error.
    # From: #1624
    if ! command -v /usr/sbin/zgenhostid >/dev/null 2>&1; then
        echo "ERROR: /usr/sbin/zgenhostid not found -- cannot regenerate /etc/hostid." >&2
        return 1
    fi
    sudo -n rm -f /etc/hostid
    sudo -n /usr/sbin/zgenhostid -f >/dev/null
    sudo -n test -s /etc/hostid || { echo "ERROR: zgenhostid ran but /etc/hostid is still missing or empty." >&2; return 1; }
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

# What: Regenerate this host's own SSH host keys (server identity) and
#   restart sshd so it serves the new keys immediately.
# Why: A full disk clone (see the full-reset section's own header) also
#   copies /etc/ssh/ssh_host_* -- the SOURCE host's private server
#   identity. Two hosts presenting the same host key are cryptographically
#   indistinguishable to any SSH client, and compromise of one key
#   compromises both. Safe to always regenerate unconditionally, same
#   "cheap, safe, no judgment call" reasoning dedupe_host_identity already
#   documents for hostid/machine-id -- nothing on a freshly-provisioned
#   clone depends on the OLD host key persisting.
# From: #1624 (PRRT_kwDOS--bIM6bC3vO, PRRT_kwDOS--bIM6bGRml)
regenerate_ssh_host_keys() {
    echo "  Removing existing SSH host keys and regenerating..."
    sudo -n rm -f /etc/ssh/ssh_host_*
    if ! sudo -n ssh-keygen -A >/dev/null 2>&1; then
        echo "  WARNING: 'ssh-keygen -A' failed to regenerate host keys -- sshd may refuse to start until this is fixed by hand." >&2
        return 1
    fi
    sudo -n systemctl restart ssh 2>/dev/null || sudo -n systemctl restart sshd 2>/dev/null ||
        echo "  WARNING: could not restart the SSH daemon (tried both 'ssh' and 'sshd' unit names) -- it may still be serving the OLD host keys from memory until restarted by hand." >&2
    echo "  New host key fingerprints:"
    local pub
    for pub in /etc/ssh/ssh_host_*.pub; do
        [[ -e "$pub" ]] || continue
        sudo -n ssh-keygen -lf "$pub" 2>/dev/null | sed 's/^/    /'
    done
    return 0
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

# Exit-status meaning for is_foreign_runner_dir (three states, not two --
# callers must capture $? explicitly rather than relying on a plain
# if/else, since bash's `if function; then` collapses any non-zero status
# to the same "false" branch):
#   0 = confirmed foreign clone leftover -- safe to remove.
#   1 = confirmed this host's own identity, OR genuinely unregistered (no
#       .runner file, no credential files either) -- never remove.
#   2 = identity could not be safely confirmed either way -- never remove,
#       but must NOT be reported as "own/registered" either (that would
#       hide a real, still-unresolved risk from the operator).
#
# What: Detect a foreign (cloned-from-another-host) runner instance
#   directory, failing closed (status 0 or 2, never silently 1) whenever
#   this host cannot actually prove the directory is its own.
# Why: Each of the following was a real fail-open gap found by review:
#   - a directory with .credentials/.credentials_rsaparams but no .runner
#     file (an incomplete clone) used to return 1 ("not foreign") purely
#     because the .runner check came first, leaving private key material
#     unflagged by `check` and unremoved by `clean`;
#   - a missing/failing `jq`, or malformed/incomplete .runner JSON, was
#     swallowed by `|| true` and treated as "not foreign" instead of "we
#     don't know";
#   - the hostname-derived token alone is not trustworthy: a real disk
#     clone can carry the SOURCE host's own OS hostname verbatim (confirmed
#     real on host .80 -- see hostname_mismatch_report), so an agentName
#     that matches the hostname token could actually belong to the clone's
#     source, not this host. The IP-derived token (own_ip_token) is live
#     network configuration a clone cannot copy, so when the two tokens
#     disagree, this host's OWN identity is itself ambiguous and neither
#     token may be used to conclude "own" -- only status 2.
# From: #1624 (PRRT_kwDOS--bIM6bDjcQ, Cro5, FGd7, DjcN)
is_foreign_runner_dir() {
    local dir="$1"
    local runner_json="$dir/.runner"
    if [[ ! -f "$runner_json" ]]; then
        if [[ -f "$dir/.credentials" || -f "$dir/.credentials_rsaparams" ]]; then
            echo "WARNING: $dir carries credential material (.credentials/.credentials_rsaparams) but no .runner file -- an incomplete clone artifact whose identity cannot be confirmed. Treating as foreign (fail closed) so 'clean' does not leave private key material behind." >&2
            return 0
        fi
        return 1 # genuinely unregistered, not a clone leftover
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "WARNING: 'jq' is not available on this host -- cannot parse $runner_json to confirm $dir's identity. Treating as foreign (fail closed) rather than assuming it belongs to this host." >&2
        return 0
    fi
    local agent_name
    if ! agent_name="$(jq -r '.agentName // empty' "$runner_json" 2>/dev/null)" || [[ -z "$agent_name" ]]; then
        echo "WARNING: could not read a valid agentName from $runner_json (missing, unreadable, or malformed JSON) -- cannot confirm $dir's identity. Treating as foreign (fail closed)." >&2
        return 0
    fi
    local found
    found="$(extract_fleet_host_number "$agent_name")"
    if [[ -z "$found" ]]; then
        echo "WARNING: agentName '$agent_name' in $runner_json does not match a known fleet naming scheme -- cannot confirm $dir's identity. Treating as foreign (fail closed)." >&2
        return 0
    fi
    local hostname_token ip_token
    hostname_token="$(own_host_token)"
    ip_token="$(own_ip_token)"
    if [[ -z "$hostname_token" && -z "$ip_token" ]]; then
        echo "WARNING: could not derive this host's own identity from either 'hostname' or its primary IPv4 address -- cannot confirm whether $dir belongs to this host. Treating as foreign (fail closed)." >&2
        return 0
    fi
    if [[ -n "$hostname_token" && -n "$ip_token" && "$hostname_token" != "$ip_token" ]]; then
        if [[ "$found" == "$hostname_token" || "$found" == "$ip_token" ]]; then
            echo "WARNING: this host's own identity is ambiguous (hostname token '$hostname_token' vs. primary-IPv4 token '$ip_token' disagree -- see hostname_mismatch_report) and $dir's agentName token '$found' matches one of them. Cannot safely confirm whether $dir belongs to this host or to the host it was cloned from; NOT auto-classified either way. Resolve the hostname-vs-IP mismatch (see 'set-hostname') before trusting this directory's status." >&2
            return 2 # unresolved -- never auto-remove, never report as own
        fi
        return 0 # matches neither of this host's own (disagreeing) tokens -- foreign
    fi
    local my_token="${ip_token:-$hostname_token}"
    if [[ "$found" == "$my_token" ]]; then
        return 1 # belongs to this host
    fi
    return 0 # foreign
}

find_runner_dirs() {
    find "$RUNNER_OPT_ROOT" -maxdepth 1 -type d -name 'actions-runner*' 2>/dev/null | sort
}

# What: List installed systemd unit names under /etc/systemd/system whose
#   WorkingDirectory or ExecStart references the given runner instance
#   directory.
# Why: A real disk clone of an ALREADY-provisioned host also copies that
#   host's own installed, possibly-enabled `actions.runner.*.service` unit
#   (the actions-runner's `svc.sh install` writes one per instance dir).
#   Removing the directory without first stopping/disabling that unit
#   leaves an already-running process holding the copied credentials open
#   (able to keep accepting jobs under the source identity), or, if
#   inactive but still enabled, a unit that starts again on the next boot
#   pointing at a directory this script just deleted. A repo-wide search
#   found no other place in this script (or the runner-host tooling
#   generally) that inspects or manages these units.
# From: #1624 (PRRT_kwDOS--bIM6bC3vo, PRRT_kwDOS--bIM6bGRmi)
find_runner_services_for_dir() {
    local dir="$1"
    [[ -d /etc/systemd/system ]] || return 0
    local unit_file
    for unit_file in /etc/systemd/system/actions.runner.*.service; do
        [[ -e "$unit_file" ]] || continue # no nullglob: literal pattern when no match
        if grep -qE "^(WorkingDirectory|ExecStart)=${dir}(/|\$)" "$unit_file" 2>/dev/null; then
            basename "$unit_file"
        fi
    done
    return 0
}

# What: Stop and disable a systemd unit inherited from a disk-cloned source
#   host before its runner instance directory is removed; refuse to
#   proceed if it is still active afterward.
# Why: See find_runner_services_for_dir's own comment for the full clone
#   scenario this protects against -- a live process must never be left
#   running against a directory this script is about to delete.
# From: #1624 (PRRT_kwDOS--bIM6bC3vo, PRRT_kwDOS--bIM6bGRmi)
stop_inherited_runner_service() {
    local unit="$1"
    echo "  Stopping and disabling inherited runner service: $unit"
    sudo systemctl stop "$unit" 2>&1 || true
    sudo systemctl disable "$unit" 2>&1 || true
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        echo "  WARNING: $unit is still active after 'systemctl stop' -- refusing to remove its directory until it is confirmed stopped." >&2
        return 1
    fi
    return 0
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
        # What: Capture is_foreign_runner_dir's real exit status (0/1/2).
        # Why: `if function; then` collapses status 1 and 2 into the same
        #   "false" branch, which would silently report an unresolved
        #   identity (status 2) as "own/registered" -- exactly the fail-open
        #   this tri-state return exists to prevent.
        # From: #1624 (PRRT_kwDOS--bIM6bDjcN)
        local status=0
        is_foreign_runner_dir "$dir" || status=$?
        if [[ "$status" -eq 0 ]]; then
            local agent_name
            agent_name="$(jq -r '.agentName // "?"' "$dir/.runner" 2>/dev/null || echo '?')"
            echo "  FOREIGN CLONE ARTIFACT: $dir  (belongs to: $agent_name)"
            [[ -f "$dir/.credentials" || -f "$dir/.credentials_rsaparams" ]] && echo "    -> carries credential material (private key for that identity)"
            local svc
            while IFS= read -r svc; do
                [[ -n "$svc" ]] || continue
                echo "    -> inherited systemd unit still installed: $svc (will be stopped/disabled by 'clean' before the directory is removed)"
            done < <(find_runner_services_for_dir "$dir")
        elif [[ "$status" -eq 2 ]]; then
            local agent_name
            agent_name="$(jq -r '.agentName // "?"' "$dir/.runner" 2>/dev/null || echo '?')"
            echo "  UNRESOLVED IDENTITY: $dir  (agentName: $agent_name) -- this host's own hostname/IP identity is ambiguous; see hostname_mismatch_report above and 'set-hostname'. NOT auto-classified; 'clean' will not touch this directory."
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
    # Same exact-field match as cmd_host_prep's own docker-group check
    # (Codex review, PR #1624) -- `grep -w docker` also matches an
    # unrelated group like `docker-build` since a hyphen satisfies its
    # word-boundary requirement on both sides.
    local check_runner_groups
    check_runner_groups=" $(id -nG "$RUNNER_USER" 2>/dev/null) "
    if [[ "$check_runner_groups" == *" docker "* ]]; then
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
        # run. Capture the real 0/1/2 status explicitly (see
        # is_foreign_runner_dir's own header) -- only status 0 (confirmed
        # foreign) is ever removed; status 2 (unresolved identity) must
        # never be silently treated as removable.
        local status=0
        is_foreign_runner_dir "$dir" || status=$?
        if [[ "$status" -eq 0 ]]; then
            local svc all_stopped=1
            while IFS= read -r svc; do
                [[ -n "$svc" ]] || continue
                stop_inherited_runner_service "$svc" || all_stopped=0
            done < <(find_runner_services_for_dir "$dir")
            if [[ "$all_stopped" -eq 0 ]]; then
                echo "SKIPPING $dir: an inherited runner service could not be confirmed stopped -- not safe to remove its directory while a process may still be using it." >&2
                continue
            fi
            echo "Removing foreign clone artifact: $dir"
            sudo rm -rf -- "$dir"
            removed_any=1
        elif [[ "$status" -eq 2 ]]; then
            echo "SKIPPING $dir: identity unresolved (hostname-vs-IP mismatch on this host itself) -- not safe to auto-classify. Resolve via 'set-hostname' first, then re-run 'check'." >&2
        fi
    done < <(find_runner_dirs)
    # What: Report stray archives instead of auto-deleting them.
    # Why: find_stray_archives selects purely by extension+size, which
    #   cannot distinguish a real leftover clone-imaging archive from a
    #   legitimate large backup an operator intentionally placed under
    #   RUNNER_OPT_ROOT -- confirmed as a real irreversible-deletion risk by
    #   review. This mirrors the script's own established pattern for a
    #   judgment call it cannot safely automate (see 'set-hostname'):
    #   report only here, act solely via the separate 'clean-archive' mode
    #   that takes the exact target path(s) as an explicit argument.
    # From: #1624 (PRRT_kwDOS--bIM6bETkU, PRRT_kwDOS--bIM6bCrpE, PRRT_kwDOS--bIM6bITvt)
    local archive found_archive=0
    while IFS= read -r archive; do
        [[ -n "$archive" ]] || continue
        found_archive=1
        echo "NOT removed (judgment call -- see 'clean-archive' below): $archive  ($(du -h "$archive" 2>/dev/null | cut -f1))"
    done < <(find_stray_archives)
    if [[ "$found_archive" -eq 1 ]]; then
        echo "Stray archives are not auto-removed by 'clean': extension+size alone cannot prove clone origin (a legitimate large backup would match too)."
        echo "Review the path(s) above, then run: sudo bash $0 clean-archive <exact-path> [<exact-path> ...]"
    fi
    if [[ "$removed_any" -eq 0 ]]; then
        echo "Nothing removed by 'clean' -- see above for any archives requiring 'clean-archive' confirmation."
    else
        echo "Clean complete. Re-run 'check' to confirm."
    fi
}

# What: Remove one or more operator-confirmed stray archive paths.
# Why: find_stray_archives can only select by extension+size (see cmd_clean's
#   own comment on that limitation); this mode requires the operator to name
#   the exact path(s) to remove, and re-verifies each one against
#   find_stray_archives immediately before deleting it -- the same
#   re-verify-before-removal discipline cmd_clean already applies to runner
#   directories -- rather than trusting a stale earlier listing.
# From: #1624 (PRRT_kwDOS--bIM6bETkU, PRRT_kwDOS--bIM6bCrpE, PRRT_kwDOS--bIM6bITvt)
cmd_clean_archive() {
    if [[ "$#" -eq 0 ]]; then
        echo "Usage: clean-archive <exact-path> [<exact-path> ...]" >&2
        echo "Run 'check' or 'clean' first to see candidate archive paths." >&2
        return 1
    fi
    local candidates
    candidates="$(find_stray_archives)"
    local path removed_any=0
    for path in "$@"; do
        if grep -qxF "$path" <<<"$candidates"; then
            echo "Removing confirmed stray archive: $path"
            sudo rm -f -- "$path"
            removed_any=1
        else
            echo "SKIPPING $path: does not currently match find_stray_archives (wrong path, already removed, or below the size/extension threshold) -- refusing to remove an unconfirmed path." >&2
        fi
    done
    if [[ "$removed_any" -eq 1 ]]; then
        echo "clean-archive complete."
    else
        echo "Nothing removed."
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
    # this host's own token. Uses the same structured extraction as
    # is_foreign_runner_dir (extract_fleet_host_number) rather than a
    # separate copy of the regex, so both call sites always agree on which
    # segment is the actual host number. The middle "group" segment is
    # deliberately matched loosely ([A-Za-z0-9]+, not [0-9]+) -- confirmed
    # real on host .81 (2026-08-21): the template's own leftover root
    # authorized_keys comment was "root@gh-lancache-light-A-80", where "A"
    # is a letter, not a number, so an earlier digits-only version of this
    # pattern silently failed to match it. Deliberately anchored to these
    # specific fleet naming prefixes (not "any trailing digits in any
    # comment") so an unrelated key comment containing a date or other
    # number (e.g. "discord-bridge-teamspeak-2026-04-01") is never
    # misflagged.
    local found
    found="$(extract_fleet_host_number "$line")"
    [[ -n "$found" && "$found" != "$my_token" ]] && return 0
    return 1
}

cmd_full_reset_check() {
    # What: Prove non-interactive root access before the privileged survey.
    # Why: A denied read must not be reported as an absent clone artifact.
    # From: #1624
    if ! sudo -n true 2>/dev/null; then
        echo "ERROR: full-reset-check requires non-interactive sudo access to inspect protected paths." >&2
        return 1
    fi
    local my_token
    my_token="$(own_host_token)"
    if [[ -z "$my_token" ]]; then
        # What: Explicit diagnostic when own_host_token is empty.
        # Why: own_host_token's own `|| true` (see its header) stops this
        #   from aborting the script under set -e, but a bare
        #   "own_host_token=" with no explanation left the operator to
        #   guess why every host-identity comparison below may be
        #   unreliable. This is the same finding as the credentials/jq
        #   fail-closed hardening in is_foreign_runner_dir: an unusable
        #   token must be surfaced, never silently treated as a non-event.
        # From: #1624 (PRRT_kwDOS--bIM6bC3vc)
        echo "Host: $(hostname)   own_host_token=<none> (could not derive a numeric token from 'hostname' -- host-identity comparisons below may be unreliable)"
    else
        echo "Host: $(hostname)   own_host_token=$my_token"
    fi
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
    # What: Report private SSH client key files under root's and
    #   RUNNER_USER's candidate home directories.
    # Why: A full disk clone also copies any outbound SSH client identity
    #   the source host ever used (e.g. /root/.ssh/id_ed25519) -- a real
    #   credential that authenticates AS the source host to other systems.
    #   This section previously only examined known_hosts (a cache of who
    #   this host has connected to, not an access grant); a repo-wide
    #   search found no other private-client-key handling anywhere in this
    #   script. Report-only, same reasoning as authorized_keys below: this
    #   script cannot know whether a given key is clone residue or an
    #   intentionally-provisioned credential meant to be shared, so
    #   rotating/removing it is a human decision.
    # From: #1624 (PRRT_kwDOS--bIM6bDOtu)
    echo "--- Private SSH client keys (report only -- rotate/remove by hand) ---"
    local ck_found=0
    local ck_dir
    for ck_dir in /root/.ssh "/home/${RUNNER_USER}/.ssh" "/opt/${RUNNER_USER}/.ssh"; do
        sudo -n test -d "$ck_dir" 2>/dev/null || continue
        local ck_output ck_status=0
        ck_output="$(sudo -n find "$ck_dir" -maxdepth 1 -type f -name 'id_*' ! -name '*.pub' 2>&1)" || ck_status=$?
        if [[ "$ck_status" -ne 0 && -n "$ck_output" ]]; then
            echo "  WARNING: search of $ck_dir exited with status $ck_status: $ck_output" >&2
        fi
        local ck
        while IFS= read -r ck; do
            [[ -n "$ck" ]] || continue
            ck_found=1
            echo "  $ck -- private client key copied by the disk clone; authenticates as the SOURCE host to other systems."
        done <<<"$ck_output"
    done
    [[ "$ck_found" -eq 1 ]] || echo "  (none found)"
    echo
    # What: Report entries in BOTH root's and RUNNER_USER's authorized_keys
    #   naming a different fleet host, and check both candidate RUNNER_USER
    #   home paths this script already uses elsewhere (history/known_hosts
    #   above already cover both /home/ and /opt/).
    # Why: The source host may grant inbound SSH directly to RUNNER_USER,
    #   not only root; this section previously only ever read
    #   /root/.ssh/authorized_keys, so a foreign key reachable via
    #   RUNNER_USER's own account went completely unreported. A repo-wide
    #   search for "authorized_keys" found no other checker.
    # From: #1624 (PRRT_kwDOS--bIM6bC3vQ, PRRT_kwDOS--bIM6bFGd_)
    echo "--- authorized_keys: entries naming a DIFFERENT fleet host (report only, never auto-removed) ---"
    local ak_found=0
    local ak_path
    for ak_path in /root/.ssh/authorized_keys "/home/${RUNNER_USER}/.ssh/authorized_keys" "/opt/${RUNNER_USER}/.ssh/authorized_keys"; do
        sudo -n test -f "$ak_path" 2>/dev/null || continue
        local ak_output ak_status=0
        ak_output="$(sudo -n cat "$ak_path" 2>&1)" || ak_status=$?
        if [[ "$ak_status" -ne 0 ]]; then
            echo "  WARNING: could not read $ak_path (status $ak_status) -- authorized_keys check for this path is incomplete, not confirmed clean." >&2
            continue
        fi
        local line
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            if is_foreign_authorized_keys_line "$line"; then
                ak_found=1
                echo "  FOREIGN ($ak_path): $line"
            fi
        done <<<"$ak_output"
    done
    [[ "$ak_found" -eq 1 ]] || echo "  (none found)"
    echo
    # What: Validate /etc/machine-id before using it to exclude "current"
    #   journal directories from the stale-directory report.
    # Why: An empty or unreadable machine-id would make the exclusion
    #   pattern `! -name ""`, which matches EVERY directory under
    #   /var/log/journal, including this host's own current one --
    #   confirmed as a real risk by review. Report-only side of the same
    #   validation full-reset-clean now applies before it ever deletes
    #   anything (see cmd_full_reset_clean).
    # From: #1624 (PRRT_kwDOS--bIM6bC3v0)
    local current_machine_id
    current_machine_id="$(cat /etc/machine-id 2>/dev/null || true)"
    echo "--- Stale journal machine-id directories (current: ${current_machine_id:-UNKNOWN}) ---"
    if [[ -z "$current_machine_id" ]]; then
        echo "  ERROR: could not read a valid /etc/machine-id -- skipping this check rather than risk reporting every journal directory (including this host's own current one) as stale." >&2
    else
        # What: Capture the search's full output and exit status into a
        #   variable BEFORE looping over it, per this repo's own documented
        #   AG-VAL-032 pattern, instead of piping a live producer straight
        #   into the loop via process substitution.
        # Why: The previous `< <(sudo -n find ... 2>/dev/null)` shape
        #   discarded the search's own exit status entirely -- if `sudo -n`
        #   itself failed (a sudoers rule not covering this exact path) or
        #   `find` hit a real I/O error, the loop still ran to completion
        #   over empty output and reported "(none found)", identical to a
        #   genuinely clean host. This affected every search in this
        #   function (authorized_keys, journal, home, template-scripts,
        #   apt/dpkg history) -- fixed uniformly here.
        # From: #1624 (PRRT_kwDOS--bIM6bC3vX)
        local jd_output jd_status=0
        jd_output="$(sudo -n find /var/log/journal -mindepth 1 -maxdepth 1 -type d ! -name "$current_machine_id" 2>&1)" || jd_status=$?
        if [[ "$jd_status" -ne 0 && -n "$jd_output" ]]; then
            echo "  WARNING: journal directory search exited with status $jd_status: $jd_output" >&2
        fi
        local jd found_jd=0
        while IFS= read -r jd; do
            [[ -n "$jd" ]] || continue
            found_jd=1
            echo "  STALE: $jd -- will be removed by full-reset-clean"
        done <<<"$jd_output"
        [[ "$found_jd" -eq 1 ]] || echo "  (none found)"
    fi
    echo
    echo "--- Orphaned /home directories (no matching /etc/passwd entry) ---"
    local hd_output hd_status=0
    hd_output="$(sudo -n find /home -mindepth 1 -maxdepth 1 -type d 2>&1)" || hd_status=$?
    if [[ "$hd_status" -ne 0 && -n "$hd_output" ]]; then
        echo "  WARNING: /home search exited with status $hd_status: $hd_output" >&2
    fi
    local hd found_hd=0
    while IFS= read -r hd; do
        [[ -n "$hd" ]] || continue
        local uname
        uname="$(basename "$hd")"
        if ! getent passwd "$uname" >/dev/null 2>&1; then
            # What: Skip a mountpoint even when it has no matching passwd entry.
            # Why: A mounted local/remote filesystem under /home with no NSS
            #   user of the same name is not an orphaned clone home -- it is
            #   someone else's mounted data. full-reset-clean's own removal
            #   loop shares this same check (see PRRT_kwDOS--bIM6bC3vS).
            # From: #1624 (PRRT_kwDOS--bIM6bC3vS)
            if mountpoint -q "$hd" 2>/dev/null; then
                found_hd=1
                echo "  MOUNTPOINT (skipped, not a clone artifact): $hd -- has no /etc/passwd entry for '$uname' but is a separate mounted filesystem; full-reset-clean will not remove it."
            else
                found_hd=1
                echo "  ORPHANED: $hd (no /etc/passwd entry for '$uname') -- will be removed by full-reset-clean"
            fi
        fi
    done <<<"$hd_output"
    [[ "$found_hd" -eq 1 ]] || echo "  (none found)"
    echo
    echo "--- Template-authoring scripts under /root ---"
    local ts_output ts_status=0
    ts_output="$(sudo -n find /root -maxdepth 1 -type f -iname '*prepare*template*' 2>&1)" || ts_status=$?
    if [[ "$ts_status" -ne 0 && -n "$ts_output" ]]; then
        echo "  WARNING: /root template-script search exited with status $ts_status: $ts_output" >&2
    fi
    local ts found_ts=0
    while IFS= read -r ts; do
        [[ -n "$ts" ]] || continue
        found_ts=1
        echo "  $ts -- will be removed by full-reset-clean"
    done <<<"$ts_output"
    [[ "$found_ts" -eq 1 ]] || echo "  (none found)"
    echo
    # What: Search apt/dpkg history (including rotated .gz files) for this
    #   fleet's own naming schemes, generically, then filter to entries
    #   whose extracted host-number differs from this host's own.
    # Why: The previous pattern hardcoded four specific LAN host
    #   numbers/IPs (240/241/229/243) directly into this repository
    #   (AG-SEC-007) and stopped detecting a clone from any OTHER source
    #   host; plain `grep` also cannot see into rotated
    #   `history.log.N.gz`/`dpkg.log.N.gz` files (confirmed: `zgrep` finds
    #   a match `grep` misses against an identical gzip-compressed file),
    #   so clone evidence surviving only in an older rotation was silently
    #   missed. Uses extract_fleet_host_number (shared with
    #   is_foreign_runner_dir/is_foreign_authorized_keys_line) so all three
    #   call sites recognize the same naming schemes the same way, and
    #   never hardcodes a specific host number or IP.
    # From: #1624 (PRRT_kwDOS--bIM6bC3v4, PRRT_kwDOS--bIM6bC3v_)
    echo "--- apt/dpkg history mentioning other fleet hosts (report only -- a real audit trail, never rewritten) ---"
    local al_output al_status=0
    al_output="$(sudo -n zgrep -EHo '(gh-lancache-[a-z]+-[A-Za-z0-9]+-[0-9]+|[a-z]-lancache-runner-[0-9]+)' /var/log/apt/history.log* /var/log/dpkg.log* 2>&1)" || al_status=$?
    local al found_al=0
    while IFS= read -r al; do
        [[ -n "$al" ]] || continue
        local al_number
        al_number="$(extract_fleet_host_number "$al")"
        if [[ -n "$al_number" && "$al_number" != "$my_token" ]]; then
            found_al=1
            echo "  $al"
        fi
    done <<<"$al_output"
    [[ "$found_al" -eq 1 ]] || echo "  (none found)"
    echo
    echo "--- Hostname vs. primary IPv4 (report only -- see 'set-hostname' mode to fix) ---"
    hostname_mismatch_report
    echo
    echo "--- /etc/hosts self-reference for current hostname ---"
    ensure_hosts_self_reference check
    echo
    echo "--- SSH host keys (server identity) ---"
    echo "  full-reset-clean unconditionally regenerates /etc/ssh/ssh_host_* and restarts sshd -- a real disk clone also copies the source host's private server identity, and two hosts sharing one host key are cryptographically indistinguishable to any SSH client."
    echo
    echo "--- hostid / machine-id (cannot detect duplicates locally -- see script header) ---"
    echo "  hostid: $(hostid)"
    echo "  machine-id: ${current_machine_id:-?}"
    echo "  -> full-reset-clean unconditionally regenerates both (cheap, safe, always unique) BEFORE the journal-directory sweep above, so the just-superseded machine-id's own journal directory is cleaned up too, not left behind indefinitely."
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
# What: Ensure /etc/hosts carries a correct 127.0.1.1 self-reference for
#   $new_hostname, replacing any stale line that referenced $old_hostname.
# Why: Factored out of cmd_set_hostname so both the normal rename path and
#   the "name already matches" retry path (see cmd_set_hostname below) run
#   the identical repair -- a real retry with the same target name must be
#   able to finish this step even when a PRIOR invocation's hostnamectl
#   already succeeded but this part failed (full/read-only filesystem,
#   etc.), which the previous code could never reach a second time.
# From: #1624 (PRRT_kwDOS--bIM6bDOtp, PRRT_kwDOS--bIM6bH8qB)
repair_hosts_self_reference_for_rename() {
    local old_hostname="$1" new_hostname="$2"
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
}

cmd_set_hostname() {
    local new_hostname="${1:?Usage: set-hostname <new-hostname>}"
    local old_hostname
    old_hostname="$(hostname)"
    if [[ "$new_hostname" == "$old_hostname" ]]; then
        # What: Still repair /etc/hosts even when hostnamectl has nothing
        #   left to do.
        # Why: A natural retry with the same target name (e.g. after a
        #   prior invocation's hostnamectl succeeded but the /etc/hosts
        #   edit failed -- a full or read-only filesystem, for example)
        #   used to return here immediately, before ever inspecting or
        #   repairing /etc/hosts, so the run could never converge a
        #   partially-applied rename. Only the hostnamectl step is
        #   skippable when the name already matches; the hosts-file repair
        #   must still run every time.
        # From: #1624 (PRRT_kwDOS--bIM6bDOtp, PRRT_kwDOS--bIM6bH8qB)
        echo "Hostname is already '$old_hostname' -- 'hostnamectl set-hostname' has nothing to do, but still checking/repairing /etc/hosts in case an earlier attempt applied the name without finishing this step."
        repair_hosts_self_reference_for_rename "$old_hostname" "$new_hostname"
        echo
        echo "Done. Current hostname: $(hostname)"
        return 0
    fi
    echo "Renaming host: '$old_hostname' -> '$new_hostname'"
    sudo hostnamectl set-hostname "$new_hostname"
    repair_hosts_self_reference_for_rename "$old_hostname" "$new_hostname"
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
    # What: Prove non-interactive root access before acting, same guard
    #   cmd_full_reset_check already has.
    # Why: This function's own truncate/rm/regenerate calls below are just
    #   as capable of silently no-op'ing on a denied `sudo -n` as
    #   full-reset-check's read-only survey was before that guard was
    #   added -- the same fail-open shape, on the destructive side.
    # From: #1624 (PRRT_kwDOS--bIM6bHO9C -- extended from full-reset-check
    #   to full-reset-clean, same failure class)
    if ! sudo -n true 2>/dev/null; then
        echo "ERROR: full-reset-clean requires non-interactive sudo access to act on protected paths." >&2
        return 1
    fi

    # What: Truncate each history file on disk, and warn about a shell
    #   session's own in-memory history surviving the truncation.
    # Why: If this command is run from an interactive root shell, THIS
    #   process (a child of that shell) can only truncate the FILE --
    #   the parent interactive shell's own already-loaded in-memory
    #   history is untouched and, depending on `histappend`/`shopt -s
    #   histappend` and how that shell eventually exits, can be written
    #   back to the same file on logout, making the clone's command
    #   history reappear after having appeared removed. This cannot be
    #   fixed from a child process -- a child cannot clear a parent
    #   shell's memory -- so the correct fix is telling the operator, not
    #   silently claiming the history is gone.
    # From: #1624 (PRRT_kwDOS--bIM6bC3vf)
    for f in /root/.bash_history "/home/${RUNNER_USER}/.bash_history" "/opt/${RUNNER_USER}/.bash_history" /root/.lesshst; do
        if sudo -n test -f "$f" 2>/dev/null; then
            sudo -n truncate -s0 "$f"
            echo "Truncated $f"
        fi
    done
    echo "NOTE: if this command was run from an interactive login shell (yours or root's), that shell's own in-memory history was NOT cleared by the truncation above and may be written back to the same file(s) on logout. Run 'history -c' in every such open shell, or reconnect via a fresh non-interactive invocation (e.g. 'ssh host sudo bash lancache-ci-runner-clone-init.sh full-reset-clean'), before relying on the history file(s) staying empty."

    for f in /root/.ssh/known_hosts "/home/${RUNNER_USER}/.ssh/known_hosts" "/opt/${RUNNER_USER}/.ssh/known_hosts"; do
        if sudo -n test -f "$f" 2>/dev/null; then
            sudo -n truncate -s0 "$f"
            echo "Cleared $f"
        fi
    done

    # What: Regenerate hostid/machine-id BEFORE the journal-directory sweep
    #   below, and validate the resulting machine-id before using it.
    # Why: The previous order excluded the CURRENT (still-cloned)
    #   machine-id's journal directory from removal, then only regenerated
    #   the id afterward in dedupe_host_identity -- so the excluded
    #   directory was already stale again the instant this function
    #   returned, and never actually cleaned up on any later run either
    #   (each run would newly exclude whatever the previous run's id had
    #   become). Regenerating FIRST means the sweep below always excludes
    #   only the id this host is about to actually use, and removes every
    #   OTHER directory -- including the one just superseded -- so the
    #   host converges to a single current journal directory. An empty
    #   post-regeneration machine-id (dedupe_host_identity failing
    #   silently, e.g. sudo -n rejected for one of its own sub-commands)
    #   must not fall through to the `! -name ""`-matches-everything trap
    #   that would otherwise delete this host's own just-created journal
    #   directory too (see PRRT_kwDOS--bIM6bC3v0). Independently confirmed
    #   by the parallel batch-3 review pass as the same root cause
    #   (non-convergence across repeat runs) -- one merged fix here.
    # From: #1624 (PRRT_kwDOS--bIM6bC3v0, PRRT_kwDOS--bIM6bDjcU, PRRT_kwDOS--bIM6bD2UI)
    echo "--- hostid / machine-id ---"
    dedupe_host_identity

    echo
    echo "--- SSH host keys (server identity) ---"
    regenerate_ssh_host_keys

    local current_machine_id
    current_machine_id="$(cat /etc/machine-id 2>/dev/null || true)"
    if [[ -z "$current_machine_id" ]]; then
        echo "ERROR: /etc/machine-id is empty or unreadable immediately after regeneration -- skipping the journal-directory sweep rather than risk deleting this host's own current journal data." >&2
    else
        # What: Capture the search's full output and exit status into a
        #   variable BEFORE looping over it, per this repo's own documented
        #   AG-VAL-032 pattern (same fix applied to every search/deletion
        #   loop in this function and in full-reset-check).
        # Why: See full-reset-check's own comment on this same pattern --
        #   a process-substitution loop over a live producer discards the
        #   producer's own exit status, letting a real search failure
        #   (permission denied, I/O error) present as "nothing to remove"
        #   instead of a surfaced error.
        # From: #1624 (PRRT_kwDOS--bIM6bC3vX)
        local jd_output jd_status=0
        jd_output="$(sudo -n find /var/log/journal -mindepth 1 -maxdepth 1 -type d ! -name "$current_machine_id" 2>&1)" || jd_status=$?
        if [[ "$jd_status" -ne 0 && -n "$jd_output" ]]; then
            echo "WARNING: journal directory search exited with status $jd_status: $jd_output" >&2
        fi
        local jd
        while IFS= read -r jd; do
            [[ -n "$jd" ]] || continue
            echo "Removing stale journal dir: $jd"
            sudo -n rm -rf -- "$jd"
        done <<<"$jd_output"
    fi

    # hd: an unowned /home dir only proves no CURRENT passwd entry has that
    # name -- it does NOT prove the directory is clone residue rather than,
    # e.g., a deliberately kept backup of a since-deleted account, or a
    # mounted data volume with no matching passwd entry at all. Report-only
    # (batch-3 finding), same reasoning already applied below to
    # authorized_keys and apt/dpkg history: this script must never guess
    # "no current owner" means "safe to delete" for something as broad as
    # an entire home directory tree. Also captures the search's own exit
    # status first (AG-VAL-032) and separately distinguishes a mounted
    # filesystem (someone else's mounted data, not clone residue) from a
    # genuinely orphaned directory in the report.
    # From: #1624 (PRRT_kwDOS--bIM6bC3vX, PRRT_kwDOS--bIM6bC3vS)
    local hd_output hd_status=0
    hd_output="$(sudo -n find /home -mindepth 1 -maxdepth 1 -type d 2>&1)" || hd_status=$?
    if [[ "$hd_status" -ne 0 && -n "$hd_output" ]]; then
        echo "WARNING: /home search exited with status $hd_status: $hd_output" >&2
    fi
    local hd
    while IFS= read -r hd; do
        [[ -n "$hd" ]] || continue
        local uname
        uname="$(basename "$hd")"
        if ! getent passwd "$uname" >/dev/null 2>&1; then
            if mountpoint -q "$hd" 2>/dev/null; then
                echo "REPORT ONLY, not removed: $hd is a separate mounted filesystem with no /etc/passwd entry named '$uname' -- not clone residue, leave it mounted."
            else
                echo "REPORT ONLY, not removed: orphaned home directory $hd (no current passwd entry named '$uname' -- review by hand before deleting; could be a kept backup, not necessarily clone residue)"
            fi
        fi
    done <<<"$hd_output"

    # Exact allowlist of confirmed one-off template-authoring artifacts
    # (see this mode's own header/full-reset-check's report section above),
    # not the broad `-iname '*prepare*template*'` glob full-reset-check uses
    # for detection: a legitimate regular file that happens to
    # case-insensitively match that pattern (e.g. a maintainer's own
    # `prepare-template-backup.sh`) would otherwise be deleted here despite
    # having no established clone provenance. (batch-3 finding)
    local -a known_template_scripts=(prepare-proxmox-template.sh)
    local ts
    for ts in "${known_template_scripts[@]}"; do
        if sudo -n test -f "/root/$ts" 2>/dev/null; then
            echo "Removing template-authoring script: /root/$ts"
            sudo -n rm -f -- "/root/$ts"
        fi
    done

    echo "--- /etc/hosts self-reference for current hostname ---"
    ensure_hosts_self_reference fix

    echo
    echo "full-reset-clean complete. NOT touched (report-only, see full-reset-check):"
    echo "  - orphaned /home directories (review by hand -- could be a kept backup, not necessarily clone residue)"
    echo "  - /root/.ssh/authorized_keys and RUNNER_USER's own authorized_keys (review any FOREIGN entries by hand)"
    echo "  - private SSH client keys (id_*) under root's/RUNNER_USER's .ssh (rotate/remove by hand)"
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
# same day.
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
    # alone cannot report memory usage. Filtering happens entirely inside
    # this one awk (not a `grep -E ... | grep -v grep` pipeline feeding it):
    # under `set -euo pipefail`, a host with currently zero matching
    # processes made the first grep exit 1, which pipefail propagated as
    # this whole assignment's exit status even though awk's own END block
    # still correctly printed 0 -- silently killing purge-pve-check via
    # `set -e` on exactly the "already clean" host state this mode exists
    # to report on.
    rss_mb="$(ps aux 2>/dev/null | awk '$0 !~ /awk/ && /pve|pmxcfs|corosync|spiceproxy|qmeventd/ {sum+=$6} END {if (sum) print sum/1024; else print 0}')"
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
    # Cleanup trap, not a one-off removal at the end of this function: if
    # `apt-get purge`/`autoremove` below aborts under `set -e` (a dpkg
    # error, a full filesystem, ...), execution never reaches an
    # end-of-function removal line, and this marker -- which overrides
    # pve-apt-hook's own removal guard -- would stay in place permanently,
    # silently disabling that guard's protection for any LATER, unrelated
    # package operation on this host too. An EXIT trap fires on every path
    # out of this function, including one `set -e` triggers.
    trap 'sudo -n rm -f /please-remove-proxmox-ve' EXIT

    echo "Purging..."
    # shellcheck disable=SC2046
    sudo -n DEBIAN_FRONTEND=noninteractive apt-get purge -y $(purge_pve_package_list) 2>&1

    # Validate the autoremove target list before running it for real: the
    # earlier five-name kernel/firmware guard only labels an already-decided
    # match, it never limits what THIS transaction can actually remove -- a
    # package that is merely mismarked "automatically installed" (e.g. a
    # runner tool this host still needs) could otherwise be swept away
    # silently. Simulate first and refuse if anything outside the expected
    # PVE-dependency namespace, or any kernel/firmware package, would be
    # removed.
    echo "Validating apt autoremove's target list before running it for real..."
    local autoremove_sim
    autoremove_sim="$(sudo -n DEBIAN_FRONTEND=noninteractive apt-get autoremove --simulate 2>&1)"
    local autoremove_unexpected
    autoremove_unexpected="$(grep -E '^Remv ' <<<"$autoremove_sim" | grep -viE 'pve-|proxmox-|libpve-|libproxmox-|pmxcfs|corosync|spice' || true)"
    if [[ -n "$autoremove_unexpected" ]] || grep -qiE 'proxmox-kernel|proxmox-default-kernel|proxmox-kernel-helper|pve-firmware|pve-edk2-firmware' <<<"$autoremove_sim"; then
        echo "ERROR: apt autoremove's simulated target list includes package(s) outside the expected PVE-dependency set (or a kernel/firmware package) -- refusing to run it automatically. Review and run 'apt-get autoremove' by hand if these removals are genuinely intended:" >&2
        echo "$autoremove_sim" >&2
        return 1
    fi
    echo "Running apt autoremove (validated above as PVE-only; kernel/firmware packages"
    echo "are still manually installed / depended-on and will not be swept by this)..."
    sudo -n DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>&1

    echo
    echo "--- Verification ---"
    echo "Remaining pve-*/proxmox-*/corosync/pmxcfs packages (should be kernel/firmware only):"
    local remaining_pkgs
    remaining_pkgs="$(dpkg -l 2>/dev/null | grep -iE '^ii.*(pve-|proxmox-|pmxcfs|corosync)' || true)"
    echo "${remaining_pkgs:-  (none)}"
    local remaining_unexpected_pkgs
    remaining_unexpected_pkgs="$(grep -viE 'proxmox-kernel|proxmox-default-kernel|proxmox-kernel-helper|pve-firmware|pve-edk2-firmware' <<<"$remaining_pkgs" || true)"

    echo "Remaining pve-related processes (should be none):"
    # Listing full command lines for a human to read is the point here, not
    # just matching PIDs (pgrep -l truncates).
    local remaining_procs
    # shellcheck disable=SC2009
    remaining_procs="$(ps aux 2>/dev/null | grep -E 'pve|pmxcfs|corosync|spiceproxy|qmeventd' | grep -v grep || true)"
    echo "${remaining_procs:-  (none)}"

    # Fail hard on any real remnant instead of only echoing it: a caller
    # (human or automation) reading only this mode's exit status must not
    # see 0 when the announced cleanup did not actually finish.
    if [[ -n "$remaining_unexpected_pkgs" ]] || [[ -n "$remaining_procs" ]]; then
        echo "ERROR: purge-pve did not fully remove the PVE stack -- a non-kernel/firmware package and/or process still remains (see above). This is NOT a clean purge." >&2
        return 1
    fi

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
# attached containers AND are older than a grace window. A network with
# active containers is left alone unconditionally -- this host runs
# multiple runner processes sharing one Docker daemon, so a network could
# belong to a job still in progress on a sibling runner process right now,
# and this hook must never touch that. The age check exists because "zero
# attached containers" alone does not prove a network is orphaned: a
# sibling job's `docker compose up` can create its network moments before
# attaching its first container, and this hook running in exactly that
# window would otherwise see 0 containers on an active job's own network
# and delete it out from under it. A network old enough to clear the grace
# window and still show 0 containers has had ample time for its own job's
# first container to attach, so it is genuinely orphaned.
set -euo pipefail

VALIDATION_NETWORK_MIN_AGE_SECONDS="${VALIDATION_NETWORK_MIN_AGE_SECONDS:-120}"

for net in $(docker network ls --filter name=lancache-ng-validation --format '{{.Name}}'); do
    containers=$(docker network inspect "$net" --format '{{len .Containers}}' 2>/dev/null || echo "0")
    if [ "$containers" -ne 0 ]; then
        echo "[cleanup-hook] leaving $net alone, $containers active container(s) attached"
        continue
    fi
    created=$(docker network inspect "$net" --format '{{.Created}}' 2>/dev/null || echo "")
    created_epoch=$(date -d "$created" +%s 2>/dev/null || echo "0")
    now_epoch=$(date +%s)
    age=$(( now_epoch - created_epoch ))
    if [ "$created_epoch" -eq 0 ] || [ "$age" -lt "$VALIDATION_NETWORK_MIN_AGE_SECONDS" ]; then
        echo "[cleanup-hook] leaving $net alone, 0 attached containers but created only ${age}s ago (younger than the ${VALIDATION_NETWORK_MIN_AGE_SECONDS}s grace window) -- may belong to a sibling job that has not attached its first container yet"
        continue
    fi
    echo "[cleanup-hook] removing orphaned validation network: $net (0 attached containers, created ${age}s ago)"
    docker network rm "$net" || echo "[cleanup-hook] WARNING: failed to remove $net, leaving in place"
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
    sudo chown "$RUNNER_USER:$(runner_group)" "$RUNNER_HOOKS_DIR/pre-job-cleanup.sh" "$RUNNER_HOOKS_DIR/post-job-cleanup.sh"
    sudo chmod 0755 "$RUNNER_HOOKS_DIR/pre-job-cleanup.sh" "$RUNNER_HOOKS_DIR/post-job-cleanup.sh"
    echo "Installed $RUNNER_HOOKS_DIR/{pre,post}-job-cleanup.sh"
}

# Enables Debian trixie-backports project-wide, matching the exact pattern
# already established and verified in tools/build-tools/Dockerfile
# (maintainer decision, 2026-07-30, see that file's own long comment for
# the full history): `Package: *` at Pin-Priority 500 (tied with the
# regular trixie archive), so ordinary version-comparison rules pick
# whichever archive has the newer version for ANY package, not a
# hand-picked subset. THE PIN SELECTOR MUST BE `a=stable-backports`, NOT
# `a=trixie-backports` -- trixie-backports' own Release file declares
# `Suite: stable-backports`; a first version of this exact pin in
# services/proxy/Dockerfile used the codename instead and silently matched
# nothing (confirmed real regression, caught only by building and checking
# an installed package version, not by trusting the file's presence). This
# was previously container-image-only; confirmed real on lancache-240
# (2026-08-21, an existing working reference host) that no host in this
# fleet actually has it at the OS level yet -- this is a new host-level
# hardening rollout, not a replication of existing host state.
#
# Idempotent: skips writing the source/pin files if already present (so a
# second host-prep run doesn't re-fetch/re-upgrade every time), but still
# runs `apt-get update` unconditionally so a freshly-added pin takes effect
# even on a re-run.
enable_backports() {
    # What: Refuse to write a trixie-specific backports pin on a non-Trixie host.
    # Why: A wrong suite silently mixes archives across distributions on cross-grade.
    # From: #1624
    local codename
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    if [[ "$codename" != "trixie" ]]; then
        echo "ERROR: enable_backports only supports Debian trixie (detected VERSION_CODENAME='${codename:-unknown}') -- refusing to write a trixie-backports pin on a different suite." >&2
        return 1
    fi
    local list_file="/etc/apt/sources.list.d/backports.list"
    local pref_file="/etc/apt/preferences.d/backports"
    local expected_list="deb http://deb.debian.org/debian trixie-backports main"
    local expected_pref=$'Package: *\nPin: release a=stable-backports\nPin-Priority: 500'
    if [[ "$(sudo -n cat "$list_file" 2>/dev/null || :)" != "$expected_list" ]]; then
        printf '%s\n' "$expected_list" | sudo -n tee "$list_file" >/dev/null
    fi
    if [[ "$(sudo -n cat "$pref_file" 2>/dev/null || :)" != "$expected_pref" ]]; then
        printf '%s\n' "$expected_pref" | sudo -n tee "$pref_file" >/dev/null
    fi
    echo "Validated $list_file and $pref_file (Pin-Priority 500, a=stable-backports)."
    # What: Require every configured package index to refresh before upgrading.
    # Why: Upgrading from stale required indices cannot establish the promised host state.
    # From: #1624
    sudo -n apt-get update 2>&1 | tail -10
    sudo -n env DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y 2>&1 | tail -15
    sudo -n env DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y 2>&1 | tail -10
}

# apt-listchanges prompts interactively (or mails a changelog diff) on
# every apt upgrade by default -- exactly the kind of thing that can hang
# an unattended `apt-get upgrade`/`dist-upgrade` waiting for input on a CI
# runner host. Confirmed real on every host in this fleet including the
# existing reference host lancache-240 (2026-08-21): none had it purged
# yet, so -- like enable_backports above -- this is a new rollout, not a
# replication of existing host state.
purge_apt_listchanges() {
    if dpkg -l apt-listchanges 2>/dev/null | grep -q '^ii'; then
        sudo -n env DEBIAN_FRONTEND=noninteractive apt-get purge -y apt-listchanges 2>&1 | tail -10
        echo "Purged apt-listchanges."
    else
        echo "apt-listchanges not installed, nothing to do."
    fi
}

cmd_host_prep() {
    # What: Validate all identities and source assets before the first host mutation.
    # Why: A failed prerequisite must not leave a partial sudoers or service installation.
    # From: #1624
    getent passwd "$RUNNER_USER" >/dev/null || { echo "ERROR: runner user '$RUNNER_USER' does not exist." >&2; return 1; }
    for asset in lancache-ci-cleanup.sh lancache-ci-cleanup.service lancache-ci-cleanup.timer; do
        [[ -f "$SCRIPT_DIR/$asset" ]] || { echo "ERROR: required cleanup asset missing: $SCRIPT_DIR/$asset" >&2; return 1; }
    done
    # What: Re-validate an already-present sudoers drop-in's exact content, not just its existence.
    # Why: A stale/foreign rule under the same filename must not be mistaken for the one this
    #      script installs -- the pre/post-job hooks depend on this exact NOPASSWD grant.
    # From: #1624
    local sudoers_file="/etc/sudoers.d/${RUNNER_USER}-nopasswd"
    local expected_sudoers_rule="${RUNNER_USER} ALL=(ALL) NOPASSWD:ALL"
    if sudo -n test -f "$sudoers_file" 2>/dev/null; then
        if [[ "$(sudo -n cat "$sudoers_file" 2>/dev/null)" == "$expected_sudoers_rule" ]] && sudo -n visudo -cf "$sudoers_file" >/dev/null 2>&1; then
            echo "$sudoers_file already present with the expected rule, leaving as-is."
        else
            echo "ERROR: $sudoers_file exists but does not contain exactly the expected rule ('$expected_sudoers_rule') or fails visudo validation -- refusing to report success. Review/remove it by hand before re-running host-prep." >&2
            return 1
        fi
    else
        echo "${RUNNER_USER} ALL=(ALL) NOPASSWD:ALL" | sudo tee "$sudoers_file" >/dev/null
        sudo chmod 0440 "$sudoers_file"
        sudo visudo -cf "$sudoers_file" || { echo "ERROR: visudo rejected $sudoers_file -- removing it." >&2; sudo rm -f "$sudoers_file"; return 1; }
        echo "Installed $sudoers_file"
    fi

    # Exact-field match, not `grep -w`: a hyphen is a non-word character, so
    # `grep -qw docker` also matches a DIFFERENT group like `docker-build`
    # (word-boundary-satisfying substring), which would report false
    # membership and skip the real `usermod -aG docker` this runner needs.
    local runner_groups
    runner_groups=" $(id -nG "$RUNNER_USER" 2>/dev/null) "
    if [[ "$runner_groups" == *" docker "* ]]; then
        echo "$RUNNER_USER already in docker group, leaving as-is."
    else
        sudo usermod -aG docker "$RUNNER_USER"
        echo "Added $RUNNER_USER to docker group (takes effect on next login/SSH session)."
    fi

    # What: Converge /opt (recursively) to runner-user-owned with setgid set.
    # Why: Maintainer decision (issue #1622, 2026-08-21): the base state for
    # everything under /opt is <RUNNER_USER>:<runner-group> so ownership
    # stays consistent as hosts get cloned; setgid makes future files/dirs
    # inherit the group automatically. Known root-owned exceptions (e.g.
    # /usr/local/bin/sccache-dist, installed by sccache-fetch) live outside
    # /opt entirely and are unaffected by this recursive step.
    # From: #1624
    local runner_group
    runner_group="$(id -gn "$RUNNER_USER" 2>/dev/null || true)"
    if [[ -z "$runner_group" ]]; then
        echo "WARNING: could not resolve a primary group for '$RUNNER_USER' -- skipping /opt ownership convergence." >&2
    else
        sudo chown -R "$RUNNER_USER:$runner_group" /opt
        sudo chmod g+s /opt
        echo "Converged /opt (recursively) to ${RUNNER_USER}:${runner_group} with setgid set on /opt itself."
    fi

    install_ci_hooks
    purge_apt_listchanges
    enable_backports

    # No `-f`/else guard here: the upfront asset-existence loop at the top
    # of this function already returned 1 if any of these three files were
    # missing, so by this point they are guaranteed present -- a redundant
    # check here would be dead code that can never take its "missing" branch.
    sudo install -m 0755 "$SCRIPT_DIR/lancache-ci-cleanup.sh" /usr/local/sbin/lancache-ci-cleanup.sh
    sudo install -m 0644 "$SCRIPT_DIR/lancache-ci-cleanup.service" /etc/systemd/system/lancache-ci-cleanup.service
    sudo install -m 0644 "$SCRIPT_DIR/lancache-ci-cleanup.timer" /etc/systemd/system/lancache-ci-cleanup.timer
    sudo systemctl daemon-reload
    sudo systemctl enable --now lancache-ci-cleanup.timer
    echo "Installed and enabled lancache-ci-cleanup.timer (see README.md in this directory)."

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
        echo "reports missing tooling, stage only the sccache/sccache-dist binaries"
        echo "(never client config -- that comes from per-job GitHub Secrets, not a"
        echo "host file) from a known-working heavy host (e.g. lancache-240) via scp,"
        echo "then run 'sccache-fetch <staged-dir>'. See README.md and this script's"
        echo "own sccache-check/-fetch header comments for the full background."
    fi
}

# Minimal local retry+backoff wrapper for cmd_runner_fetch's two network
# calls (GitHub Releases API + tarball download). AG-CI-013 requires flaky
# network downloads to use the project's documented retry-wrapper pattern
# (scripts/lib/ghcr-retry.sh) rather than a bespoke ad hoc retry -- this
# script cannot source that file directly: only tools/runner-host/ itself
# is ever copied to a runner host (see this file's own host-prep warning),
# so scripts/lib/ is never present there. This mirrors ghcr_retry()'s own
# policy shape instead -- same attempt-count/backoff defaults, output
# passed through untouched, and the command tested in `if` condition
# position so a failing attempt does not itself trip the caller's
# `set -e` -- just without the docker-login-specific relogin step a plain
# curl GET has no use for.
RUNNER_FETCH_RETRY_MAX_ATTEMPTS="${RUNNER_FETCH_RETRY_MAX_ATTEMPTS:-4}"
RUNNER_FETCH_RETRY_BACKOFF_SECONDS="${RUNNER_FETCH_RETRY_BACKOFF_SECONDS:-30}"
runner_fetch_retry() {
    local attempt=1
    local status=0
    while (( attempt <= RUNNER_FETCH_RETRY_MAX_ATTEMPTS )); do
        if "$@"; then
            return 0
        else
            status=$?
        fi
        if (( attempt >= RUNNER_FETCH_RETRY_MAX_ATTEMPTS )); then
            echo "ERROR: '$*' failed after ${RUNNER_FETCH_RETRY_MAX_ATTEMPTS} attempts (exit ${status})." >&2
            return "$status"
        fi
        echo "WARNING: '$*' failed (attempt ${attempt}/${RUNNER_FETCH_RETRY_MAX_ATTEMPTS}, exit ${status}); retrying in ${RUNNER_FETCH_RETRY_BACKOFF_SECONDS}s..." >&2
        sleep "$RUNNER_FETCH_RETRY_BACKOFF_SECONDS"
        attempt=$((attempt + 1))
    done
    return "$status"
}

cmd_runner_fetch() {
    local instance_dir="${1:?Usage: runner-fetch <instance-dir> [version]}"
    local version="${2:-2.336.0}"
    local tarball="actions-runner-linux-x64-${version}.tar.gz"
    local url="https://github.com/actions/runner/releases/download/v${version}/${tarball}"

    # Validate the target directory BEFORE any network call or mutation:
    # `mkdir -p`/`tar -C` accept an unrestricted path, and the final
    # `chown -R` walks and re-owns everything already under it. A typo'd
    # <dir> such as `/opt` or `/` (or an already-registered runner
    # instance) would otherwise let this mode extract into and recursively
    # re-own an unrelated, possibly host-critical directory tree. Requires
    # the canonical target to live directly under RUNNER_OPT_ROOT and to be
    # either new or already-empty.
    local canon_dir parent_dir
    canon_dir="$(readlink -f -- "$instance_dir" 2>/dev/null || true)"
    if [[ -z "$canon_dir" ]]; then
        parent_dir="$(readlink -f -- "$(dirname -- "$instance_dir")" 2>/dev/null || true)"
        if [[ -z "$parent_dir" ]]; then
            echo "ERROR: cannot resolve a canonical path for '$instance_dir' (its parent directory does not exist)." >&2
            return 1
        fi
        canon_dir="$parent_dir/$(basename -- "$instance_dir")"
    fi
    case "$canon_dir" in
        "$RUNNER_OPT_ROOT"/*) ;;
        *)
            echo "ERROR: refusing to install into '$canon_dir' -- runner-fetch only accepts a new instance directory directly under RUNNER_OPT_ROOT ($RUNNER_OPT_ROOT), to prevent a typo (e.g. '/opt' or '/') from triggering extraction and a recursive chown over unrelated host state." >&2
            return 1
            ;;
    esac
    if [[ -e "$canon_dir" ]] && { [[ ! -d "$canon_dir" ]] || [[ -n "$(find "$canon_dir" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; }; then
        echo "ERROR: '$canon_dir' already exists and is not an empty directory -- refusing to extract over an existing (and possibly already-registered) runner instance." >&2
        return 1
    fi
    instance_dir="$canon_dir"

    local tmp_tarball
    tmp_tarball="$(mktemp -t "${tarball}.XXXXXX")"
    # EXIT trap, not only the explicit `rm -f` calls below: if any command
    # after this point aborts under `set -e` (checksum mismatch aside,
    # which already cleans up explicitly, but also sha256sum/tar/chown
    # failing), execution never reaches an explicit cleanup line and this
    # uniquely-named temp file is left under /tmp forever -- every retried
    # provisioning attempt would then leave one more behind.
    trap 'rm -f "$tmp_tarball"' EXIT

    echo "Fetching expected checksum for v${version} from the GitHub Releases API..."
    local expected_digest
    expected_digest="$(runner_fetch_retry curl -fsSL "https://api.github.com/repos/actions/runner/releases/tags/v${version}" \
        | jq -r --arg name "$tarball" '.assets[] | select(.name == $name) | .digest' 2>/dev/null || true)"
    expected_digest="${expected_digest#sha256:}"
    if [[ -z "$expected_digest" ]]; then
        echo "ERROR: could not fetch an expected sha256 digest for $tarball from the GitHub API -- refusing to install unverified. Check the version string or network access." >&2
        return 1
    fi

    echo "Downloading $url ..."
    runner_fetch_retry curl -fsSL -o "$tmp_tarball" "$url"
    local actual_digest
    actual_digest="$(sha256sum "$tmp_tarball" | awk '{print $1}')"
    if [[ "$actual_digest" != "$expected_digest" ]]; then
        echo "ERROR: checksum mismatch for $tarball -- expected $expected_digest, got $actual_digest. Refusing to extract." >&2
        return 1
    fi
    echo "Checksum verified: $actual_digest"

    sudo mkdir -p "$instance_dir"
    sudo tar xzf "$tmp_tarball" -C "$instance_dir"
    sudo chown -R "$RUNNER_USER:$(runner_group)" "$instance_dir"

    # Hook wiring -- written here so it is already present the first time
    # `config.sh` is run, but NOT the only place it is written: `config.sh`
    # itself loads the Actions Runner's own env.sh, which truncates .env
    # (`echo >.env`) before writing config.sh's own variable list, wiping
    # out anything written here. See the `runner-hook-env` mode below,
    # which must be run AFTER config.sh to make the wiring actually stick.
    cat <<ENVEOF | sudo tee "$instance_dir/.env" >/dev/null
LANG=C
ACTIONS_RUNNER_HOOK_JOB_STARTED=${RUNNER_HOOKS_DIR}/pre-job-cleanup.sh
ACTIONS_RUNNER_HOOK_JOB_COMPLETED=${RUNNER_HOOKS_DIR}/post-job-cleanup.sh
ENVEOF
    sudo chown "$RUNNER_USER:$(runner_group)" "$instance_dir/.env"

    echo
    echo "Extracted actions-runner v${version} into $instance_dir and wrote its .env"
    echo "hook wiring. NOT registered yet -- run config.sh there by hand with a fresh"
    echo "registration token (never pass it as a literal argv string over ssh; pipe"
    echo "it over stdin instead). Maintainer decision (issue #1622, 2026-08-21):"
    echo "for this fleet (.80-.91 and on), pass --name \$(hostname) EXACTLY -- e.g."
    echo "'$(hostname)' on this host -- NOT the old fleet's letter-prefix scheme"
    echo "(a-lancache-runner-240-1 etc., which only applies to the pre-existing"
    echo "229/240/241/243 hosts and must never be copied onto a new host)."
    echo "IMPORTANT: config.sh's own env.sh truncates .env before writing its own"
    echo "variables, which wipes the hook wiring just written above -- run"
    echo "'runner-hook-env $instance_dir' AFTER config.sh (and before starting the"
    echo "service) to restore it."
    echo "Then 'sudo ./svc.sh install' and hold off on 'sudo ./svc.sh start' until"
    echo "the go-ahead to accept real jobs is confirmed."
}

# Writes/re-verifies an already-registered runner instance's
# ACTIONS_RUNNER_HOOK_JOB_* .env wiring. A standalone mode, not only logic
# inside runner-fetch, because the Actions Runner's own config.sh loads
# env.sh, which truncates .env (`echo >.env`) before writing config.sh's
# own variable list -- so hook wiring written by runner-fetch BEFORE
# config.sh runs is silently wiped the moment registration happens. Must
# be run AFTER config.sh. Idempotent: safe to run again on an
# already-wired instance.
cmd_runner_hook_env() {
    local instance_dir="${1:?Usage: runner-hook-env <instance-dir>}"
    [[ -d "$instance_dir" ]] || { echo "ERROR: '$instance_dir' is not a directory." >&2; return 1; }
    [[ -f "$instance_dir/.env" ]] || { echo "ERROR: '$instance_dir/.env' does not exist yet -- run this AFTER config.sh, not before." >&2; return 1; }
    if grep -q '^ACTIONS_RUNNER_HOOK_JOB_STARTED=' "$instance_dir/.env" 2>/dev/null \
        && grep -q '^ACTIONS_RUNNER_HOOK_JOB_COMPLETED=' "$instance_dir/.env" 2>/dev/null; then
        echo "$instance_dir/.env already has hook wiring, leaving as-is (re-run after a fresh config.sh if the hooks changed)."
        return 0
    fi
    {
        echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=${RUNNER_HOOKS_DIR}/pre-job-cleanup.sh"
        echo "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=${RUNNER_HOOKS_DIR}/post-job-cleanup.sh"
    } | sudo tee -a "$instance_dir/.env" >/dev/null
    echo "Appended hook wiring to $instance_dir/.env."
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
    echo "--- sccache runtime config ---"
    echo "  supplied per job through SCCACHE_CONF; no scheduler token is stored on the host"
    # What: Flag a stale, pre-fix credential file if one is still present.
    # Why: A host not yet re-fetched can still carry the old world-readable
    # config; surface it (mode only, never content) rather than ignore it.
    # From: #1624
    for stale in "/opt/${RUNNER_USER}/.config/sccache/config" "/opt/${RUNNER_USER}/sccache-dist/client.conf"; do
        if sudo -n test -f "$stale" 2>/dev/null; then
            echo "  STALE: $stale still present ($(sudo -n stat -c '%a %U:%G' "$stale" 2>/dev/null)) -- re-run sccache-fetch to remove it."
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
        sudo -u "$RUNNER_USER" HOME="/opt/${RUNNER_USER}" /usr/local/bin/sccache --version 2>&1
    else
        echo "  (skipped -- sccache binary missing)"
    fi
    echo
    echo "No files were changed (sccache-check mode)."
}

# Installs the sccache client tooling from files already staged on THIS
# host at the given source directory (see the script header above for why
# this is a copy, not a build). The orchestrating machine is expected to
# have already staged only sccache and sccache-dist from a known-working
# heavy host into that directory; secret-backed runtime configuration is
# created by the configure-rust-sccache action for each individual job --
# this mode only does the LOCAL install step (permissions, ownership,
# directory layout), matching the exact paths confirmed on lancache-240.
cmd_sccache_fetch() {
    local src_dir="${1:?Usage: sccache-fetch <source-dir-with-staged-files>}"
    for f in sccache sccache-dist; do
        if [[ ! -f "$src_dir/$f" ]]; then
            echo "ERROR: $src_dir/$f not found -- stage it first (scp from a known-working heavy host)." >&2
            return 1
        fi
    done
    # What: Execute staged clients before replacing known-good host binaries.
    # Why: Corrupt or wrong-architecture artifacts must leave installed tools untouched.
    # From: #1624
    sudo -u "$RUNNER_USER" HOME="/opt/${RUNNER_USER}" "$src_dir/sccache" --version >/dev/null
    "$src_dir/sccache-dist" --help >/dev/null
    # Both binaries root-owned, group $(runner_group) for consistency with
    # every other /opt-adjacent path this script manages (maintainer
    # decision, 2026-08-21) -- mode 0755 gives owner-only write, so a CI job
    # running as RUNNER_USER cannot overwrite this persistent PATH binary
    # and inject code into every later job on this host, the way owning it
    # as RUNNER_USER itself would have allowed.
    # What: Stage each binary in the target directory, then atomically rename it into place.
    # Why: `install` writing the destination path directly is not atomic;
    # a concurrent CI job could exec a partially-written binary mid-replace.
    # From: #1624
    local group; group="$(runner_group)"
    sudo install -o root -g "$group" -m 0755 "$src_dir/sccache" /usr/local/bin/.sccache.new
    sudo mv -f /usr/local/bin/.sccache.new /usr/local/bin/sccache
    sudo install -o root -g "$group" -m 0755 "$src_dir/sccache-dist" /usr/local/bin/.sccache-dist.new
    sudo mv -f /usr/local/bin/.sccache-dist.new /usr/local/bin/sccache-dist
    sudo mkdir -p /opt/sccache/dist-client
    sudo chown "$RUNNER_USER:$(runner_group)" /opt/sccache /opt/sccache/dist-client
    sudo chmod 2775 /opt/sccache /opt/sccache/dist-client
    # What: Remove any stale, world-readable host-copied credential files.
    # Why: The previous sccache-fetch installed a Redis/dist-auth config
    # here at mode 0644; runtime config now comes only from per-job
    # SCCACHE_CONF, so a leftover file is dead, world-readable state with
    # no further reader (see sccache-check's stale-file report below).
    # From: #1624
    sudo rm -f "/opt/${RUNNER_USER}/.config/sccache/config" "/opt/${RUNNER_USER}/sccache-dist/client.conf"
    sudo rmdir --ignore-fail-on-non-empty "/opt/${RUNNER_USER}/.config/sccache" "/opt/${RUNNER_USER}/sccache-dist" 2>/dev/null || true
    echo "Installed sccache client tooling. Verifying:"
    HOME="/opt/${RUNNER_USER}" sudo -u "$RUNNER_USER" /usr/local/bin/sccache --version
    echo "Run 'sccache-check' to confirm the full picture."
}

print_usage() {
    cat <<'EOF'
Usage: bash lancache-ci-runner-clone-init.sh <mode> [args...]

Modes:
  check                        (default) Read-only report. Writes nothing.
  clean                        Removes clone artifacts 'check' flagged as
                                foreign. Requires CONFIRM_CLEAN=yes. Stray
                                archives are report-only here -- see
                                'clean-archive'.
  clean-archive <path...>      Removes the exact stray-archive path(s)
                                named, after re-verifying each still matches
                                find_stray_archives. Extension+size alone
                                cannot prove clone origin, so 'clean' no
                                longer auto-deletes archives -- this mode
                                requires an explicit, individually-confirmed
                                target, same judgment-call pattern as
                                'set-hostname'.
  host-prep                    Idempotent sudoers/docker-group/ci-hooks/
                                cleanup-timer setup. Never touches
                                daemon.json or runner registration.
  runner-fetch <dir> [version] Download+verify+extract a runner release
                                directly into <dir> (default version 2.336.0)
                                and write its .env hook wiring. <dir> must be
                                a new or empty directory directly under
                                RUNNER_OPT_ROOT. Does not register or start
                                anything.
  runner-hook-env <dir>         Re-writes the ACTIONS_RUNNER_HOOK_JOB_* .env
                                 wiring for an already-registered instance.
                                 Run this AFTER config.sh -- config.sh's own
                                 env.sh truncates .env, wiping out whatever
                                 runner-fetch wrote before registration.
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
                                 script header) is installed and executable
                                 as the configured runner account. Writes
                                 nothing and uses no scheduler credential.
  sccache-fetch <dir>            Validates and installs sccache/sccache-dist
                                 binaries already staged at <dir> (copy from a
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
        clean-archive) cmd_clean_archive "$@" ;;
        host-prep) cmd_host_prep ;;
        runner-fetch) cmd_runner_fetch "$@" ;;
        runner-hook-env) cmd_runner_hook_env "$@" ;;
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
