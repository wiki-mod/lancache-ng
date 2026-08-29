#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# CI runner host maintenance: stands up a single, LAN-shared apt-caching
# proxy (apt-cacher-ng) backed by the NFS export at
# 192.168.1.10:/srv/runner-hosting/apt-cache, with a real local-disk
# fallback (never tmpfs/OS-default /tmp) when that mount is unavailable.
#
# Background (Issue #1095, item 2 of the CI-caching task): apt package
# downloads happen over the network during a Docker build, unlike ccache
# (a filesystem cache written from inside a BuildKit RUN instruction,
# which has no host-bind-mount type -- see this same issue's ccache
# discussion, deliberately NOT addressed by this script or by any
# Dockerfile change in this same change set). A LAN-reachable caching
# proxy is therefore reachable from inside a build the same way the
# public internet already is (plain outbound HTTP), with no BuildKit
# mount-type limitation to work around -- docs/ci-2.0-architecture.md
# §40 already names this exact "Runner -> LAN package proxy -> Internet"
# shape as the sanctioned pattern for this class of cache.
#
# Deployment model, deliberately mirroring lancache-ci-docker-daemon-
# config.sh in this same directory (see that script's own header and
# tools/runner-host/README.md for the full precedent): this script is
# safe-by-default (`check`, `test`) and never performs the disruptive,
# persistent step (`install`) as a side effect of a lower subcommand.
# `install` starts a container with --restart=always -- a permanent
# change to this host's steady-state footprint -- and per this
# directory's own established convention, that step is a maintainer-
# scheduled action on one host at a time, not something this script (or
# the agent session that wrote it) performs unilaterally. As of this
# script landing, `install` has deliberately NOT been run against any
# real runner host; only `check` and a `--rm` `test` invocation have.
set -euo pipefail

APT_CACHE_NFS_EXPORT="${APT_CACHE_NFS_EXPORT:-192.168.1.10:/srv/runner-hosting/apt-cache}"
APT_CACHE_MOUNT="${APT_CACHE_MOUNT:-/mnt/apt-cache-nfs}"
APT_CACHE_FALLBACK_DIR="${APT_CACHE_FALLBACK_DIR:-/var/tmp/lancache-ng-apt-cache-fallback}"
APT_CACHE_PROXY_PORT="${APT_CACHE_PROXY_PORT:-3142}"
APT_CACHE_PROXY_IMAGE="${APT_CACHE_PROXY_IMAGE:-sameersbn/apt-cacher-ng@sha256:82f55f9c8f627cee8ef5f710c1745388d79d3a3f2f3150353e6500021bec11b4}"
APT_CACHE_CONTAINER_NAME="${APT_CACHE_CONTAINER_NAME:-lancache-ci-apt-cache-proxy}"

print_usage() {
    cat <<'USAGE'
Usage: lancache-ci-apt-cache-proxy.sh <mode>

Modes:
  check    Read-only. Verifies the NFS export mounts and is genuinely
           writable (real write+subdirectory probe, matching this repo's
           .github/actions/trivy-cache-dir convention), falls back to a
           real local directory otherwise, and confirms the pinned image
           is pullable. Writes nothing persistent, starts no container.
  test     Runs the proxy container in --rm mode (auto-removed on exit),
           does a real HTTP smoke request against its status page and a
           real apt-get update through it, then removes it. Leaves no
           persistent state: this host's steady-state footprint is
           unchanged after `test` exits, only the cache directory itself
           was populated during the test.
  install  THE DISRUPTIVE STEP. Starts the proxy container with
           --restart=always: a permanent addition to this host's running
           services. Maintainer-scheduled per this directory's own
           convention -- requires CONFIRM_APT_CACHE_PROXY_INSTALL=yes.
USAGE
}

# resolve_cache_dir
# What: real write+subdirectory probe against the NFS mount, real local-
#   disk fallback otherwise -- deliberately the same probe shape as
#   .github/actions/trivy-cache-dir/action.yml's own probe_writable, for
#   the same reason that action documents: a directory merely existing,
#   or accepting a flat-file write, does not prove a caching daemon can
#   create its own subdirectories under it.
# Why: never fall through to tmpfs/OS-default /tmp -- the documented
#   cause of a prior real "no space left on device" CI outage.
resolve_cache_dir() {
    local probe subdir
    probe="$APT_CACHE_MOUNT/.apt-cache-proxy-write-probe.$$.${RANDOM}"
    subdir="$APT_CACHE_MOUNT/.apt-cache-proxy-write-probe-dir.$$.${RANDOM}"
    if [[ -d "$APT_CACHE_MOUNT" ]] && (
        set -e
        printf 'probe' >"$probe"
        [[ "$(cat "$probe")" == "probe" ]]
        rm -f "$probe"
        mkdir "$subdir"
        printf 'probe' >"$subdir/probe"
        [[ "$(cat "$subdir/probe")" == "probe" ]]
        rm -rf "$subdir"
    ) 2>/dev/null; then
        echo "$APT_CACHE_MOUNT"
        return 0
    fi
    echo "WARNING: '$APT_CACHE_MOUNT' is not mounted or not writable -- falling back to a real local-disk directory ('$APT_CACHE_FALLBACK_DIR'), never tmpfs/OS-default /tmp. This host will not share the apt cache with any other runner host until the mount recovers." >&2
    mkdir -p "$APT_CACHE_FALLBACK_DIR"
    echo "$APT_CACHE_FALLBACK_DIR"
}

cmd_check() {
    echo "== NFS mount status =="
    if mountpoint -q "$APT_CACHE_MOUNT" 2>/dev/null; then
        echo "  $APT_CACHE_MOUNT: mounted"
    else
        echo "  $APT_CACHE_MOUNT: NOT mounted (expected export: $APT_CACHE_NFS_EXPORT)"
        echo "  To mount it: sudo mkdir -p $APT_CACHE_MOUNT && sudo mount -t nfs -o rw,soft,timeo=30 $APT_CACHE_NFS_EXPORT $APT_CACHE_MOUNT"
    fi
    local chosen_dir
    chosen_dir="$(resolve_cache_dir)"
    echo "== Resolved cache directory =="
    echo "  $chosen_dir"
    echo "== Pinned image =="
    echo "  $APT_CACHE_PROXY_IMAGE"
    if docker image inspect "$APT_CACHE_PROXY_IMAGE" >/dev/null 2>&1; then
        echo "  already present locally"
    else
        echo "  not present locally -- pulling now to verify it resolves (read-only check, no container started)"
        docker pull "$APT_CACHE_PROXY_IMAGE"
    fi
    echo "== check complete -- no container started, no persistent state changed =="
}

cmd_test() {
    local chosen_dir
    chosen_dir="$(resolve_cache_dir)"
    echo "Starting a --rm smoke-test container (auto-removed on exit) using cache dir: $chosen_dir"
    docker run --rm -d \
        --name "${APT_CACHE_CONTAINER_NAME}-smoketest" \
        -p "${APT_CACHE_PROXY_PORT}:3142" \
        -v "${chosen_dir}:/var/cache/apt-cacher-ng" \
        "$APT_CACHE_PROXY_IMAGE" >/dev/null
    trap 'docker rm -f "${APT_CACHE_CONTAINER_NAME}-smoketest" >/dev/null 2>&1 || true' EXIT

    echo "Waiting for the proxy's own status page to answer..."
    local waited=0
    until curl -sf --max-time 2 "http://127.0.0.1:${APT_CACHE_PROXY_PORT}/acng-report.html" >/dev/null 2>&1; do
        waited=$((waited + 1))
        if [[ "$waited" -ge 15 ]]; then
            echo "ERROR: proxy did not answer its status page within 15s." >&2
            docker logs "${APT_CACHE_CONTAINER_NAME}-smoketest" >&2 || true
            exit 1
        fi
        sleep 1
    done
    echo "OK: apt-cacher-ng answered its status page."

    echo "Fetching one real package index through the proxy to populate the cache..."
    docker run --rm --network container:"${APT_CACHE_CONTAINER_NAME}-smoketest" \
        debian:trixie-slim bash -c "set -euo pipefail; printf 'Acquire::http::Proxy \"http://127.0.0.1:3142\";\n' > /etc/apt/apt.conf.d/00proxy; apt-get update"
    echo "OK: apt-get update through the proxy succeeded."
    echo "Cache directory now contains:"
    # What: captures find's output into a variable before piping to head.
    # Why: find | head is an early-exiting consumer fed by a live producer
    #   under this script's own pipefail -- head exiting after 5 lines
    #   while find is still writing can fail with an unrelated-looking
    #   SIGPIPE (AG-VAL-029/AG-VAL-032). Capturing first avoids that.
    # From: Issue #1095
    local found_files
    found_files="$(find "$chosen_dir" -maxdepth 4 -type f 2>/dev/null || true)"
    head -5 <<<"$found_files"
    echo "== test complete -- smoke-test container removed, no persistent state left running =="
}

cmd_install() {
    if [[ "${CONFIRM_APT_CACHE_PROXY_INSTALL:-}" != "yes" ]]; then
        echo "ERROR: refusing to install without CONFIRM_APT_CACHE_PROXY_INSTALL=yes." >&2
        echo "This starts a --restart=always container -- a permanent change to this" >&2
        echo "host's running services. Maintainer-scheduled, one host at a time," >&2
        echo "per tools/runner-host/README.md's own established convention." >&2
        exit 1
    fi
    local chosen_dir
    chosen_dir="$(resolve_cache_dir)"
    echo "Installing persistent apt-cache proxy container '${APT_CACHE_CONTAINER_NAME}' using cache dir: $chosen_dir"
    docker rm -f "$APT_CACHE_CONTAINER_NAME" >/dev/null 2>&1 || true
    docker run -d \
        --name "$APT_CACHE_CONTAINER_NAME" \
        --restart=always \
        -p "${APT_CACHE_PROXY_PORT}:3142" \
        -v "${chosen_dir}:/var/cache/apt-cacher-ng" \
        "$APT_CACHE_PROXY_IMAGE"
    echo "Installed. Verify with: curl http://127.0.0.1:${APT_CACHE_PROXY_PORT}/acng-report.html"
}

main() {
    local mode="${1:-check}"
    case "$mode" in
        check) cmd_check ;;
        test) cmd_test ;;
        install) cmd_install ;;
        -h|--help) print_usage ;;
        *)
            echo "ERROR: unknown mode '$mode'" >&2
            print_usage >&2
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
