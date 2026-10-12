#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: Prepares a cloned runner host; never registers.
# Why: Clones carry the source host's runner credentials.
# From: Issue #1622 | PR #1624
set -euo pipefail

RUNNER_OPT_ROOT="${RUNNER_OPT_ROOT:-/opt}"
RUNNER_HOOKS_DIR="${RUNNER_HOOKS_DIR:-/opt/lancache-ci-hooks}"
RUNNER_USER="${RUNNER_USER:-codex}"
# What: Default 1 GiB; smaller /opt archives are ignored.
# Why: Confirmed leftovers were 6.7 GB and 14.3 GB.
# From: Issue #1622
STRAY_ARCHIVE_MIN_BYTES="${STRAY_ARCHIVE_MIN_BYTES:-1073741824}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# What: Prints RUNNER_USER's primary group, else its name.
# Why: A RUNNER_USER override may not share its group name.
runner_group() {
    id -gn "$RUNNER_USER" 2>/dev/null || echo "$RUNNER_USER"
}

# What: Prints the hostname's last digit run, or nothing.
# Why: Clones keep the old hostname; the IP octet does not.
own_host_token() {
    # What: No digits in hostname: empty output, exit 0.
    # Why: Stops pipefail aborting a caller's assignment.
    hostname | grep -oE '[0-9]+' | tail -n1 || true
}

# What: Prints the IP that routes to 1.1.1.1; empty if none.
# Why: Callers' set -e must not see a failure on no route.
own_primary_ipv4() {
    # What: Always exits 0; no match yields empty stdout.
    # Why: pipefail would abort the caller's assignment.
    local route_output matches first_match
    route_output="$(ip -4 route get 1.1.1.1 2>/dev/null || true)"
    matches="$(grep -oE 'src [0-9.]+' <<<"$route_output" || true)"
    first_match="${matches%%$'\n'*}"
    printf '%s\n' "${first_match#src }"
}

# What: Prints the last IP octet of this host, or nothing.
# Why: A clone copies the hostname but not the live IP.
# From: PR #1624
own_ip_token() {
    local ip
    ip="$(own_primary_ipv4)"
    [[ -n "$ip" ]] || return 0
    echo "${ip##*.}"
}

# What: Prints a runner's fleet host number, or nothing.
# Why: A loose match can pick the instance suffix instead.
# From: PR #1624
extract_fleet_host_number() {
    local name="$1"
    if [[ "$name" =~ (gh-lancache-[a-z]+-[A-Za-z0-9]+-([0-9]+)|[a-z]-lancache-runner-([0-9]+)) ]]; then
        echo "${BASH_REMATCH[2]:-${BASH_REMATCH[3]}}"
    fi
}

# What: Checks /etc/hosts; fix mode appends a missing line.
# Why: Without it, sudo fails: unable to resolve host.
# From: Issue #1622
ensure_hosts_self_reference() {
    local mode="${1:-check}"
    local my_hostname my_ip
    my_hostname="$(hostname)"
    my_ip="$(own_primary_ipv4)"
    # What: Skips commented /etc/hosts lines when matching.
    # Why: A commented-out line must not count as resolved.
    # From: PR #1624
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
    # What: Appends a 127.0.1.1 line for the hostname.
    # Why: Editing an address line would drop its aliases.
    # From: PR #1624
    printf '127.0.1.1\t%s\n' "$my_hostname" | sudo -n tee -a /etc/hosts >/dev/null
    echo "    Fixed: appended a 127.0.1.1 entry without changing aliases on ${my_ip:-other addresses}."
}

# What: Replaces /etc/hostid and a urandom machine-id.
# Why: Clones share both IDs; a host cannot detect that.
# From: Issue #1622
dedupe_host_identity() {
    echo "  hostid: $(hostid) -> "
    # What: Regenerates /etc/hostid, then verifies it.
    # Why: rm runs first; a failure would leave no hostid.
    # From: PR #1624
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

# What: Regenerates SSH host keys and restarts sshd.
# Why: A disk clone copies the source's SSH server identity.
# From: PR #1624
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

# What: Reports a hostname/IP host-number mismatch; no fix.
# Why: Only the maintainer's inventory knows the right name.
# From: Issue #1622
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

# What: 0 foreign/unknown, 1 own/unregistered, 2 ambiguous.
# Why: Status 2 must never be reported as own or removed.
# From: PR #1624
is_foreign_runner_dir() {
    local dir="$1"
    local runner_json="$dir/.runner"
    if [[ ! -f "$runner_json" ]]; then
        if [[ -f "$dir/.credentials" || -f "$dir/.credentials_rsaparams" ]]; then
            echo "WARNING: $dir carries credential material (.credentials/.credentials_rsaparams) but no .runner file -- an incomplete clone artifact whose identity cannot be confirmed. Treating as foreign (fail closed) so 'clean' does not leave private key material behind." >&2
            return 0
        fi
        # What: Returns 1: no .runner, no credential files.
        # Why: Not a clone leftover, so nothing to remove.
        return 1
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
            # What: Returns 2: host identity is ambiguous.
            # Why: Reporting it as own hides an open risk.
            return 2
        fi
        # What: Returns 0: matches neither own token.
        # Why: Unprovable ownership is treated as foreign.
        return 0
    fi
    local my_token="${ip_token:-$hostname_token}"
    if [[ "$found" == "$my_token" ]]; then
        # What: Returns 1: agentName is this host's own.
        # Why: Own runner dir; never removed by clean.
        return 1
    fi
    # What: Returns 0: no own-token match, so foreign.
    # Why: The directory is not provably this host's.
    return 0
}

find_runner_dirs() {
    find "$RUNNER_OPT_ROOT" -maxdepth 1 -type d -name 'actions-runner*' 2>/dev/null | sort
}

# What: Lists actions.runner units that run from the dir.
# Why: A disk clone copies the source's enabled unit.
# From: PR #1624
find_runner_services_for_dir() {
    local dir="$1"
    [[ -d /etc/systemd/system ]] || return 0
    local unit_file
    for unit_file in /etc/systemd/system/actions.runner.*.service; do
        # What: Skips an unmatched glob (literal path).
        # Why: Unmatched globs stay literal (no nullglob).
        [[ -e "$unit_file" ]] || continue
        if grep -qE "^(WorkingDirectory|ExecStart)=${dir}(/|\$)" "$unit_file" 2>/dev/null; then
            basename "$unit_file"
        fi
    done
    return 0
}

# What: Stops and disables a unit; fails if still active.
# Why: A live process must not outlive its directory.
# From: PR #1624
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
        # What: Keeps 0/1/2 status of is_foreign_runner_dir.
        # Why: An if-test would merge status 2 into 'own'.
        # From: PR #1624
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
    # What: Matches "docker" as an exact group-name field.
    # Why: grep -w would also match a "docker-build" group.
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
        # What: Re-checks identity right before removal.
        # Why: A dir can change between 'check' and 'clean'.
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
    # What: Lists stray archives only; never deletes them.
    # Why: Extension and size cannot prove clone origin.
    # From: PR #1624
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

# What: Deletes only named paths that the finder matches.
# Why: Size and extension cannot prove clone origin.
# From: PR #1624
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

# What: full-reset-clean removes only clear clone residue.
# Why: Lockout and audit-trail items are report-only.
# From: Issue #1622 | PR #1624
is_foreign_authorized_keys_line() {
    local line="$1"
    local my_token
    my_token="$(own_host_token)"
    [[ -n "$my_token" ]] || return 1
    # What: Flags key comments naming another fleet host.
    # Why: Fleet-prefix anchor avoids false hits on dates.
    # From: PR #1624
    local found
    found="$(extract_fleet_host_number "$line")"
    [[ -n "$found" && "$found" != "$my_token" ]] && return 0
    return 1
}

cmd_full_reset_check() {
    # What: Fails early without non-interactive sudo.
    # Why: Denied reads must not look like no artifacts.
    # From: PR #1624
    if ! sudo -n true 2>/dev/null; then
        echo "ERROR: full-reset-check requires non-interactive sudo access to inspect protected paths." >&2
        return 1
    fi
    local my_token
    my_token="$(own_host_token)"
    if [[ -z "$my_token" ]]; then
        # What: Reports an empty own_host_token explicitly.
        # Why: A silent empty token skews host comparisons.
        # From: PR #1624
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
    # What: Reports private SSH client keys, removes none.
    # Why: Cloned keys authenticate as the source host.
    # From: PR #1624
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
    # What: Reports authorized_keys of other fleet hosts.
    # Why: Wrong removal can lock out access; report only.
    # From: PR #1624
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
    # What: Empty machine-id skips the journal stale check.
    # Why: An empty pattern would match every journal dir.
    # From: PR #1624
    local current_machine_id
    current_machine_id="$(cat /etc/machine-id 2>/dev/null || true)"
    echo "--- Stale journal machine-id directories (current: ${current_machine_id:-UNKNOWN}) ---"
    if [[ -z "$current_machine_id" ]]; then
        echo "  ERROR: could not read a valid /etc/machine-id -- skipping this check rather than risk reporting every journal directory (including this host's own current one) as stale." >&2
    else
        # What: Stores find output+status before the loop.
        # Why: Errors must not read as '(none found)'.
        # From: PR #1624
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
            # What: Skips mountpoints without passwd entry.
            # Why: A mount is data, not an orphaned home.
            # From: PR #1624
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
    # What: Greps apt/dpkg logs incl. .gz for fleet hosts.
    # Why: grep misses .gz rotations; zgrep reads them.
    # From: PR #1624
    echo "--- apt/dpkg history mentioning other fleet hosts (report only -- a real audit trail, never rewritten) ---"
    local al_output al_status=0
    al_output="$(sudo -n zgrep -EHo '(gh-lancache-[a-z]+-[A-Za-z0-9]+-[0-9]+|[a-z]-lancache-runner-[0-9]+)' /var/log/apt/history.log* /var/log/dpkg.log* 2>&1)" || al_status=$?
    # What: Warns on zgrep status >1, not on no-match.
    # Why: zgrep exits 1 for no match, >1 for a real error.
    # From: PR #1624
    if [[ "$al_status" -gt 1 ]]; then
        echo "  WARNING: apt/dpkg history search exited with status $al_status: $al_output" >&2
    fi
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

# What: Sets /etc/hosts' 127.0.1.1 entry to $new_hostname.
# Why: Shared by both rename paths so a retry can finish.
# From: PR #1624
repair_hosts_self_reference_for_rename() {
    local old_hostname="$1" new_hostname="$2"
    if sudo test -f /etc/hosts && sudo grep -q "127.0.1.1" /etc/hosts 2>/dev/null; then
        sudo sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t${new_hostname}/" /etc/hosts
        echo "Updated /etc/hosts' 127.0.1.1 entry."
    else
        # What: Replaces an old-host line, else appends one.
        # Why: Keeps sudo able to resolve its own hostname.
        # From: PR #1624
        if sudo grep -qE "^[0-9.]+[[:space:]].*\\b${old_hostname}\\b" /etc/hosts 2>/dev/null; then
            sudo sed -i "s/^[0-9.]\\+[[:space:]].*\\b${old_hostname}\\b.*/127.0.1.1\\t${new_hostname}/" /etc/hosts
            echo "Replaced stale self-reference line (was pointing at old hostname '${old_hostname}') with a 127.0.1.1 entry."
        else
            printf '127.0.1.1\t%s\n' "$new_hostname" | sudo tee -a /etc/hosts >/dev/null
            echo "No existing self-reference line found -- appended a new 127.0.1.1 entry."
        fi
    fi
}

# What: Renames via hostnamectl, then repairs /etc/hosts.
# Why: The target name is required input, never derived.
# From: PR #1624
cmd_set_hostname() {
    local new_hostname="${1:?Usage: set-hostname <new-hostname>}"
    local old_hostname
    old_hostname="$(hostname)"
    if [[ "$new_hostname" == "$old_hostname" ]]; then
        # What: Repairs /etc/hosts; skips only hostnamectl.
        # Why: Retries must finish a partly applied rename.
        # From: PR #1624
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
    # What: Aborts unless sudo -n true succeeds.
    # Why: Denied sudo -n calls would otherwise no-op.
    # From: PR #1624
    if ! sudo -n true 2>/dev/null; then
        echo "ERROR: full-reset-clean requires non-interactive sudo access to act on protected paths." >&2
        return 1
    fi

    # What: Truncates history files; warns on live shells.
    # Why: A child process cannot clear the parent shell.
    # From: PR #1624
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

    # What: Regenerates hostid/machine-id before the sweep.
    # Why: Sweep excludes only the id regenerated here.
    # From: PR #1624
    echo "--- hostid / machine-id ---"
    dedupe_host_identity

    echo
    echo "--- SSH host keys (server identity) ---"
    regenerate_ssh_host_keys

    local current_machine_id
    current_machine_id="$(cat /etc/machine-id 2>/dev/null || true)"
    # What: Skips the journal sweep if machine-id is empty.
    # Why: An empty -name value selects every directory.
    # From: PR #1624
    if [[ -z "$current_machine_id" ]]; then
        echo "ERROR: /etc/machine-id is empty or unreadable immediately after regeneration -- skipping the journal-directory sweep rather than risk deleting this host's own current journal data." >&2
    else
        # What: Captures search output and status first.
        # Why: A failing search must not read as empty.
        # From: PR #1624
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

    # What: Reports unowned /home dirs; never removes them.
    # Why: An unowned dir may be a kept backup or mount.
    # From: PR #1624
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

    # What: Removes only allowlisted template scripts.
    # Why: A glob would also delete unrelated scripts.
    # From: PR #1624
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

# What: Prints Proxmox packages purged by check and clean.
# Why: Purging the only kernel leaves the host unbootable.
# From: PR #1624
purge_pve_package_list() {
    printf '%s\n' corosync libcorosync-common4 libproxmox-acme-perl libproxmox-acme-plugins libproxmox-backup-qemu0 libproxmox-rs-perl libpve-access-control libpve-apiclient-perl libpve-cluster-api-perl libpve-cluster-perl libpve-common-perl libpve-guest-common-perl libpve-http-server-perl libpve-network-api-perl libpve-network-perl libpve-notify-perl libpve-rs-perl libpve-storage-perl proxmox-backup-client proxmox-backup-file-restore proxmox-backup-restore-image proxmox-firewall proxmox-mail-forward proxmox-mini-journalreader proxmox-offline-mirror-docs proxmox-offline-mirror-helper proxmox-termproxy proxmox-ve proxmox-websocket-tunnel proxmox-widget-toolkit pve-cluster pve-container pve-docs pve-esxi-import-tools pve-firewall pve-ha-manager pve-i18n pve-lxc-syscalld pve-manager pve-nvidia-vgpu-helper pve-qemu-kvm pve-xtermjs pve-yew-mobile-gui pve-yew-mobile-i18n proxmox-enterprise-support-keyring
}

# What: Prints the units cmd_purge_pve stops before purging.
# Why: Stop first, so dpkg prerm does not race daemons.
# From: PR #1624
purge_pve_service_list() {
    printf '%s\n' pveproxy pvedaemon pvestatd pvescheduler spiceproxy pve-ha-crm pve-ha-lrm pve-firewall proxmox-firewall pve-lxc-syscalld qmeventd pve-cluster corosync pvefw-logger proxmox-firewall.timer watchdog-mux
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
    local cron_pve_hits
    cron_pve_hits="$(sudo -n grep -rli pve /etc/cron.d /etc/cron.daily /etc/cron.hourly 2>/dev/null || true)"
    if [[ -n "$cron_pve_hits" ]]; then
        echo "  FOUND: a cron.d/daily/hourly entry references pve -- review before purging"
        dep_found=1
    fi
    [[ "$dep_found" -eq 1 ]] || echo "  (no fstab/lsof/cron dependents found)"
    echo
    echo "--- Current RSS held by pve-related processes ---"
    local rss_mb
    # What: Sums RSS (MB) of pve processes; 0 if none.
    # Why: pgrep lacks RSS; a grep pipe fails on no match.
    # From: PR #1624
    rss_mb="$(ps aux 2>/dev/null | awk '$0 !~ /awk/ && /pve|pmxcfs|corosync|spiceproxy|qmeventd/ {sum+=$6} END {if (sum) print sum/1024; else print 0}')"
    echo "  ${rss_mb:-0} MB"
    echo
    echo "--- Simulated purge (no kernel/firmware package must appear below) ---"
    local -a pkg_list
    mapfile -t pkg_list < <(purge_pve_package_list)
    sudo -n apt-get purge --simulate "${pkg_list[@]}" 2>&1 | tail -20
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
    # What: Re-simulates; refuses if kernel/firmware is hit.
    # Why: Package list can drift as fleet images change.
    # From: PR #1624
    local sim
    local -a pkg_list
    mapfile -t pkg_list < <(purge_pve_package_list)
    sim="$(sudo -n apt-get purge --simulate "${pkg_list[@]}" 2>&1)"
    if grep -qiE 'proxmox-kernel|proxmox-default-kernel|proxmox-kernel-helper|pve-firmware|pve-edk2-firmware' <<<"$sim"; then
        echo "ERROR: the simulated purge would touch a kernel/firmware package -- refusing." >&2
        echo "This host's package set has likely changed since this script was written." >&2
        echo "$sim" >&2
        return 1
    fi

    echo "Stopping pve/proxmox/corosync services..."
    local -a svc_list
    mapfile -t svc_list < <(purge_pve_service_list)
    sudo -n systemctl stop "${svc_list[@]}" 2>&1 || true

    echo "Overriding pve-apt-hook's proxmox-ve removal guard (deliberate, confirmed"
    echo "real on .81 -- apt otherwise refuses to remove the proxmox-ve meta-package)."
    sudo -n touch /please-remove-proxmox-ve
    # What: EXIT trap removes the pve-apt-hook override.
    # Why: Else the guard stays disabled after an abort.
    # From: PR #1624
    trap 'sudo -n rm -f /please-remove-proxmox-ve' EXIT

    echo "Purging..."
    local -a pkg_list
    mapfile -t pkg_list < <(purge_pve_package_list)
    sudo -n DEBIAN_FRONTEND=noninteractive apt-get purge -y "${pkg_list[@]}" 2>&1

    # What: Refuses non-PVE or kernel/firmware autoremove.
    # Why: The name guard only labels; it never limits.
    # From: PR #1624
    echo "Validating apt autoremove's target list before running it for real..."
    local autoremove_sim
    autoremove_sim="$(sudo -n DEBIAN_FRONTEND=noninteractive apt-get autoremove --simulate 2>&1)"
    local autoremove_unexpected
    autoremove_unexpected="$(grep -E '^Remv ' <<<"$autoremove_sim" | grep -viE 'pve-|proxmox-|libpve-|libproxmox-|pmxcfs|corosync|spice' || true)"
    if [[ -n "$autoremove_unexpected" ]] || grep -qiE 'proxmox-kernel|proxmox-default-kernel|proxmox-kernel-helper|pve-firmware|pve-edk2-firmware' <<<"$autoremove_sim"; then # pipefail-safe: here-string input is already fully materialized before grep starts, not a live producer
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
    # What: Excludes this script's own PID from the match.
    # Why: Own argv holds 'purge-pve', matching 'pve'.
    # From: PR #1624
    local remaining_procs
    # shellcheck disable=SC2009
    remaining_procs="$(ps aux 2>/dev/null | grep -E 'pve|pmxcfs|corosync|spiceproxy|qmeventd' | grep -v grep | awk -v self="$$" '$2 != self' || true)"
    echo "${remaining_procs:-  (none)}"

    # What: Fails on leftover non-kernel PVE pkgs or procs.
    # Why: Callers see only the exit status; 0 = clean.
    # From: PR #1624
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

# What: Installs pre/post-job hooks from heredoc content.
# Why: Hooks are host-local by design, not repo-tracked.
# From: PR #1624
install_ci_hooks() {
    sudo mkdir -p "$RUNNER_HOOKS_DIR"
    sudo tee "$RUNNER_HOOKS_DIR/pre-job-cleanup.sh" >/dev/null <<'HOOKEOF'
#!/bin/bash
# What: resets $GITHUB_WORKSPACE owner at job start
# Why: a killed prior job leaves files checkout can't delete
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

# What: Writes trixie-backports files, then upgrades.
# Why: Pin must use a=stable-backports, not the codename.
# From: PR #1624
enable_backports() {
    # What: Fails unless VERSION_CODENAME is trixie.
    # Why: A wrong suite mixes distribution archives.
    # From: PR #1624
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
    # What: Refreshes package indices before upgrading.
    # Why: Upgrades use the indices; failed update aborts.
    # From: PR #1624
    sudo -n apt-get update 2>&1 | tail -10
    sudo -n env DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y 2>&1 | tail -15
    sudo -n env DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y 2>&1 | tail -10
}

# What: Purges apt-listchanges if it is installed.
# Why: Its prompts or mail can hang unattended upgrades.
# From: PR #1624
purge_apt_listchanges() {
    local dpkg_status
    dpkg_status="$(dpkg -l apt-listchanges 2>/dev/null || true)"
    if grep -q '^ii' <<<"$dpkg_status"; then
        sudo -n env DEBIAN_FRONTEND=noninteractive apt-get purge -y apt-listchanges 2>&1 | tail -10
        echo "Purged apt-listchanges."
    else
        echo "apt-listchanges not installed, nothing to do."
    fi
}

cmd_host_prep() {
    # What: Checks runner user and cleanup assets first.
    # Why: Failure must not leave a partial install.
    # From: PR #1624
    getent passwd "$RUNNER_USER" >/dev/null || { echo "ERROR: runner user '$RUNNER_USER' does not exist." >&2; return 1; }
    for asset in lancache-ci-cleanup.sh lancache-ci-cleanup.service lancache-ci-cleanup.timer; do
        [[ -f "$SCRIPT_DIR/$asset" ]] || { echo "ERROR: required cleanup asset missing: $SCRIPT_DIR/$asset" >&2; return 1; }
    done
    # What: Validates an existing drop-in's exact content.
    # Why: Hooks need this exact NOPASSWD grant.
    # From: PR #1624
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

    # What: Matches the docker group as an exact field.
    # Why: grep -w matches docker-build; usermod skipped.
    # From: PR #1624
    local runner_groups
    runner_groups=" $(id -nG "$RUNNER_USER" 2>/dev/null) "
    if [[ "$runner_groups" == *" docker "* ]]; then
        echo "$RUNNER_USER already in docker group, leaving as-is."
    else
        sudo usermod -aG docker "$RUNNER_USER"
        echo "Added $RUNNER_USER to docker group (takes effect on next login/SSH session)."
    fi

    # What: Chowns /opt recursively to runner user:group.
    # Why: Base state for /opt; setgid inherits the group.
    # From: Issue #1622 | PR #1624
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

    # What: Installs cleanup assets; no per-file check.
    # Why: The asset loop above has verified existence.
    # From: PR #1624
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

    # What: Prints sccache next steps on heavy hosts.
    # Why: Host-prep cannot copy sccache binaries itself.
    # From: Issue #1622 | PR #1624
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

# What: Retries a command; failed tries do not trip set -e.
# Why: scripts/lib/ghcr-retry.sh is absent on runner hosts.
# From: PR #1624
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

    # What: Under RUNNER_OPT_ROOT; must be new or empty.
    # Why: A typo such as /opt must not reach chown -R.
    # From: PR #1624
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
    # What: Deletes the temp tarball on any script exit.
    # Why: A set -e abort would skip later cleanup lines.
    # From: PR #1624
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

    # What: Writes both hook lines into the instance .env.
    # Why: env.sh (run by config.sh) truncates .env.
    # From: PR #1624
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
    echo "the go-ahead to accept real jobs is confirmed. Once installed, run"
    echo "'runner-restart-policy' (no args) so a crashed/OOM-killed runner comes"
    echo "back on its own instead of staying dead until someone notices -- the"
    echo "installer's own generated unit sets no restart policy at all."
}

# What: Rewrites .env hook lines only when values differ.
# Why: config.sh truncates .env, so this must run after it.
# From: PR #1624
cmd_runner_hook_env() {
    local instance_dir="${1:?Usage: runner-hook-env <instance-dir>}"
    [[ -d "$instance_dir" ]] || { echo "ERROR: '$instance_dir' is not a directory." >&2; return 1; }
    [[ -f "$instance_dir/.env" ]] || { echo "ERROR: '$instance_dir/.env' does not exist yet -- run this AFTER config.sh, not before." >&2; return 1; }
    # What: Expected hook lines; matched by value, not name.
    # Why: A name-only check accepts a stale wrong path.
    # From: PR #1624
    local expected_started="ACTIONS_RUNNER_HOOK_JOB_STARTED=${RUNNER_HOOKS_DIR}/pre-job-cleanup.sh"
    local expected_completed="ACTIONS_RUNNER_HOOK_JOB_COMPLETED=${RUNNER_HOOKS_DIR}/post-job-cleanup.sh"
    local current_started current_completed
    current_started="$(grep '^ACTIONS_RUNNER_HOOK_JOB_STARTED=' "$instance_dir/.env" 2>/dev/null || true)"
    current_completed="$(grep '^ACTIONS_RUNNER_HOOK_JOB_COMPLETED=' "$instance_dir/.env" 2>/dev/null || true)"
    if [[ "$current_started" == "$expected_started" && "$current_completed" == "$expected_completed" ]]; then
        echo "$instance_dir/.env already has correct hook wiring, leaving as-is."
        return 0
    fi
    # What: Deletes old hook lines, then appends the pair.
    # Why: Stale copies must not coexist with the new pair.
    # From: PR #1624
    if [[ -n "$current_started" || -n "$current_completed" ]]; then
        sudo sed -i '/^ACTIONS_RUNNER_HOOK_JOB_STARTED=/d; /^ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/d' "$instance_dir/.env"
        echo "Removed stale hook wiring from $instance_dir/.env (was: ${current_started:-<absent>} / ${current_completed:-<absent>})."
    fi
    {
        echo "$expected_started"
        echo "$expected_completed"
    } | sudo tee -a "$instance_dir/.env" >/dev/null
    echo "Appended correct hook wiring to $instance_dir/.env."
}

# What: Drop-in Restart=on-failure, RestartSec=10 per unit.
# Why: Installer unit has Restart=no; crashes stay down.
# From: Issue #1738
cmd_runner_restart_policy() {
    [[ -d /etc/systemd/system ]] || { echo "ERROR: /etc/systemd/system not found." >&2; return 1; }

    local unit_file unit dropin_dir dropin
    local found=0 changed=0
    for unit_file in /etc/systemd/system/actions.runner.*.service; do
        # What: Skips when the glob matched no unit file.
        # Why: No nullglob: unmatched glob stays literal.
        # From: Issue #1738
        [[ -e "$unit_file" ]] || continue
        found=1
        unit="$(basename "$unit_file")"
        dropin_dir="/etc/systemd/system/${unit}.d"
        dropin="${dropin_dir}/override.conf"
        if [[ -f "$dropin" ]] && grep -qx 'Restart=on-failure' "$dropin" && grep -qx 'RestartSec=10' "$dropin"; then
            echo "  $unit: $dropin already has Restart=on-failure/RestartSec=10, leaving as-is."
            continue
        fi
        echo "  $unit: writing $dropin (Restart=on-failure, RestartSec=10)"
        sudo mkdir -p "$dropin_dir"
        printf '[Service]\nRestart=on-failure\nRestartSec=10\n' | sudo tee "$dropin" >/dev/null
        changed=1
    done

    if [[ "$found" -eq 0 ]]; then
        echo "No actions.runner.*.service units found on this host -- nothing to do. Run this AFTER 'svc.sh install', not before."
        return 0
    fi
    [[ "$changed" -eq 1 ]] && sudo systemctl daemon-reload

    echo
    echo "--- Verification ---"
    for unit_file in /etc/systemd/system/actions.runner.*.service; do
        [[ -e "$unit_file" ]] || continue
        unit="$(basename "$unit_file")"
        echo "  $unit: Restart=$(systemctl show "$unit" -p Restart --value 2>/dev/null), RestartUSec=$(systemctl show "$unit" -p RestartUSec --value 2>/dev/null)"
    done
}

# What: Checks sccache client tooling; changes no files.
# Why: Rust CI on heavy hosts fails without this client.
# From: PR #1624
cmd_sccache_check() {
    # What: Returns 1 if a check is missing or fails.
    # Why: Exit status is a readiness gate for callers.
    # From: PR #1624
    local missing=0
    echo "--- sccache client binaries ---"
    for f in /usr/local/bin/sccache /usr/local/bin/sccache-dist; do
        if [[ -x "$f" ]]; then
            echo "  $f: present ($(sha256sum "$f" | awk '{print $1}'))"
        else
            echo "  $f: MISSING"
            missing=1
        fi
    done
    echo
    echo "--- sccache runtime config ---"
    echo "  supplied per job through SCCACHE_CONF; no scheduler token is stored on the host"
    # What: Reports stale credential files without content.
    # Why: The old host-copy flow left these files behind.
    # From: PR #1624
    for stale in "/opt/${RUNNER_USER}/.config/sccache/config" "/opt/${RUNNER_USER}/sccache-dist/client.conf"; do
        if sudo -n test -f "$stale" 2>/dev/null; then
            echo "  STALE: $stale still present ($(sudo -n stat -c '%a %U:%G' "$stale" 2>/dev/null)) -- re-run sccache-fetch to remove it."
        fi
    done
    if sudo -n test -d /opt/sccache/dist-client 2>/dev/null; then
        echo "  /opt/sccache/dist-client: present"
    else
        echo "  /opt/sccache/dist-client: MISSING"
        missing=1
    fi
    echo
    echo "--- Live check (requires the config above; reaches the real scheduler) ---"
    if [[ -x /usr/local/bin/sccache ]]; then
        sudo -u "$RUNNER_USER" HOME="/opt/${RUNNER_USER}" /usr/local/bin/sccache --version 2>&1 || missing=1
    else
        echo "  (skipped -- sccache binary missing)"
    fi
    echo
    if [[ "$missing" -eq 1 ]]; then
        echo "sccache-check: one or more prerequisites are MISSING (see above). No files were changed."
        return 1
    fi
    echo "No files were changed (sccache-check mode)."
}

# What: Installs staged sccache and sccache-dist binaries.
# Why: Builds happen on a heavy host; secrets are per-job.
# From: PR #1624
cmd_sccache_fetch() {
    local src_dir="${1:?Usage: sccache-fetch <source-dir-with-staged-files>}"
    for f in sccache sccache-dist; do
        if [[ ! -f "$src_dir/$f" ]]; then
            echo "ERROR: $src_dir/$f not found -- stage it first (scp from a known-working heavy host)." >&2
            return 1
        fi
    done
    # What: Runs the staged binaries before any install.
    # Why: Bad or foreign-arch files must not replace tools.
    # From: PR #1626
    sudo -u "$RUNNER_USER" HOME="/opt/${RUNNER_USER}" "$src_dir/sccache" --version >/dev/null
    "$src_dir/sccache-dist" --help >/dev/null
    # What: Installs both binaries root-owned, mode 0755.
    # Why: Runner user must not overwrite it; mv is atomic.
    # From: PR #1624
    local group; group="$(runner_group)"
    sudo install -o root -g "$group" -m 0755 "$src_dir/sccache" /usr/local/bin/.sccache.new
    sudo mv -f /usr/local/bin/.sccache.new /usr/local/bin/sccache
    sudo install -o root -g "$group" -m 0755 "$src_dir/sccache-dist" /usr/local/bin/.sccache-dist.new
    sudo mv -f /usr/local/bin/.sccache-dist.new /usr/local/bin/sccache-dist
    sudo mkdir -p /opt/sccache/dist-client
    sudo chown "$RUNNER_USER:$(runner_group)" /opt/sccache /opt/sccache/dist-client
    sudo chmod 2775 /opt/sccache /opt/sccache/dist-client
    # What: Removes stale host-copied sccache credentials.
    # Why: Leftover world-readable copies have no reader.
    # From: PR #1624
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
  runner-restart-policy         Backfills Restart=on-failure/RestartSec=10
                                 (via a '.service.d/override.conf' drop-in,
                                 never editing the installer-generated unit
                                 itself) onto every actions-runner systemd
                                 unit already installed on this host. Run
                                 this AFTER 'svc.sh install'. Idempotent --
                                 safe to re-run, no-ops on a unit already at
                                 this policy.
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
        runner-restart-policy) cmd_runner_restart_policy ;;
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

# What: Runs main only when executed, not when sourced.
# Why: Sourcing otherwise runs main with the caller's args.
# From: PR #1624
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
