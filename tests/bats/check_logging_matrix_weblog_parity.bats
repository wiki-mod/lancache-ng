#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Coverage for #849 bug-hunt finding observability.md#16 and the new
# web_log-job-config parity section it added to
# scripts/untracked/check-logging-matrix.sh: deploy/quickstart/docker-compose.yml
# generates its own inline copy of netdata's web_log collector job config
# (services/syslog/netdata-web_log.conf is bind-mounted directly in
# deploy/prod, but quickstart's install_dir has no services/ directory to
# bind-mount from) -- that heredoc's own comment already promised to keep
# the content byte-identical, but nothing enforced it, and it had already
# drifted for real (the heredoc still carried a `log_type: nginx` field
# services/syslog/netdata-web_log.conf's own header explains was removed
# 2026-07-31 for breaking the go.d parser).
#
# scripts/untracked/check-logging-matrix.sh's earlier matrix-row section needs a real
# `docker compose config` invocation (see that script's own header for why),
# so this file does not attempt to run the whole script end-to-end -- it
# instead exercises the exact extraction-and-comparison awk/sed pipeline the
# script's new section uses, duplicated here the same way
# tests/bats/netdata_network_isolation.bats and
# tests/bats/watchdog_docker_socket_proxy_depends_on_healthy.bats already
# duplicate scripts/untracked/check-compose-healthchecks.sh's own service-block
# extraction rather than requiring Docker just to prove a text-comparison is
# correct. Both the real-files case (proving no regression today) and a
# synthetic drift case (proving the comparison actually catches a mismatch,
# not just trivially passing because nothing was ever wrong) are covered.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

# extract_real_jobs <netdata-web_log.conf path>
extract_real_jobs() {
    awk '/^jobs:/{flag=1} flag{print}' "$1"
}

# extract_quickstart_jobs <docker-compose.yml path>
extract_quickstart_jobs() {
    awk '
        /cat > \/etc\/netdata\/go\.d\/web_log\.conf <<.CONF./ { capture = 1; next }
        capture && /^        CONF$/ { capture = 0 }
        capture { print }
    ' "$1" | sed 's/^        //'
}

@test "the real repo's quickstart inline web_log job config matches services/syslog/netdata-web_log.conf today" {
    real_jobs="$(extract_real_jobs "$repo_root/services/syslog/netdata-web_log.conf")"
    quickstart_jobs="$(extract_quickstart_jobs "$repo_root/deploy/quickstart/docker-compose.yml")"

    [ -n "$real_jobs" ]
    [ -n "$quickstart_jobs" ]
    [ "$real_jobs" = "$quickstart_jobs" ]
}

# Regression-proof for the exact incident this check exists for: a stale
# `log_type: nginx` field surviving in quickstart's copy after the real file
# dropped it must be detected as a mismatch, not silently ignored.
@test "the comparison pipeline detects a real-world drift (stale log_type field) in a synthetic fixture" {
    real_conf="$BATS_TEST_TMPDIR/netdata-web_log.conf"
    quickstart_compose="$BATS_TEST_TMPDIR/docker-compose.yml"

    cat > "$real_conf" <<'EOF'
# header comment, intentionally excluded from the comparison
jobs:
  - name: nginx_proxy
    path: /var/log/lancache/nginx-proxy.log
EOF

    cat > "$quickstart_compose" <<'EOF'
  netdata:
    command:
      - |
        set -e
        cat > /etc/netdata/go.d/web_log.conf <<'CONF'
        jobs:
          - name: nginx_proxy
            path: /var/log/lancache/nginx-proxy.log
            log_type: nginx
        CONF
        exec /usr/sbin/run.sh
EOF

    real_jobs="$(extract_real_jobs "$real_conf")"
    quickstart_jobs="$(extract_quickstart_jobs "$quickstart_compose")"

    [ -n "$real_jobs" ]
    [ -n "$quickstart_jobs" ]
    [ "$real_jobs" != "$quickstart_jobs" ]
}

# Complements the drift test above: once the synthetic fixture's stale field
# is removed (mirroring the real fix), the comparison must report a match --
# proving the pipeline isn't simply always-mismatch on any two-file input.
@test "the comparison pipeline reports a match once a synthetic drift is fixed" {
    real_conf="$BATS_TEST_TMPDIR/netdata-web_log-fixed.conf"
    quickstart_compose="$BATS_TEST_TMPDIR/docker-compose-fixed.yml"

    cat > "$real_conf" <<'EOF'
jobs:
  - name: nginx_proxy
    path: /var/log/lancache/nginx-proxy.log
EOF

    cat > "$quickstart_compose" <<'EOF'
  netdata:
    command:
      - |
        cat > /etc/netdata/go.d/web_log.conf <<'CONF'
        jobs:
          - name: nginx_proxy
            path: /var/log/lancache/nginx-proxy.log
        CONF
EOF

    real_jobs="$(extract_real_jobs "$real_conf")"
    quickstart_jobs="$(extract_quickstart_jobs "$quickstart_compose")"

    [ "$real_jobs" = "$quickstart_jobs" ]
}
