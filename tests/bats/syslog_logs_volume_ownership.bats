#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Guards the startup migration that makes an existing logs volume writable by
# the combined syslog container's fixed non-root identity after an upgrade.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export CACHE_DIR="$BATS_TEST_TMPDIR/cache"
    export NATS_CALLOUT_USER="test-callout"
    export NATS_DNS_REPLICA_USER="test-dns-replica"
    export NATS_DNS_WRITER_USER="test-dns-writer"
    export NATS_SYS_USER="test-system"
    export NATS_UI_USER="test-ui"
}

@test "production and quickstart repair the logs volume before syslog starts" {
    # Both operator-facing stacks must repair old volumes rather than relying
    # on Docker's fresh-volume image ownership inheritance.
    local compose rendered
    for compose in deploy/prod/docker-compose.yml deploy/quickstart/docker-compose.yml; do
        rendered="$BATS_TEST_TMPDIR/$(basename "$(dirname "$compose")")-compose.json"
        docker compose --profile logging --env-file /dev/null \
            -f "$repo_root/$compose" config --format json > "$rendered"
        python3 - "$compose" "$rendered" <<'PY'
import json
import sys

compose, rendered = sys.argv[1:]
with open(rendered, encoding="utf-8") as handle:
    services = json.load(handle)["services"]
initializer = services["syslog-logs-permissions"]
syslog = services["syslog"]

assert initializer["user"] == "0:0", compose
assert initializer["entrypoint"] == ["/bin/chown"], compose
assert initializer["command"] == ["-R", "10001:10001", "/var/log/lancache"], compose
assert initializer["network_mode"] == "none", compose
assert initializer["cap_drop"] == ["ALL"], compose
assert initializer["cap_add"] == ["CHOWN"], compose
assert initializer["read_only"] is True, compose
assert initializer["restart"] == "no", compose
assert syslog["depends_on"]["syslog-logs-permissions"]["condition"] == "service_completed_successfully", compose
PY
    done
}

@test "production and quickstart keep the combined syslog container capability-free" {
    local compose rendered
    for compose in deploy/prod/docker-compose.yml deploy/quickstart/docker-compose.yml; do
        rendered="$BATS_TEST_TMPDIR/$(basename "$(dirname "$compose")")-syslog-capless.json"
        docker compose --profile logging --env-file /dev/null \
            -f "$repo_root/$compose" config --format json > "$rendered"
        python3 - "$compose" "$rendered" <<'PY'
import json
import sys

compose, rendered = sys.argv[1:]
with open(rendered, encoding="utf-8") as handle:
    services = json.load(handle)["services"]
syslog = services["syslog"]

assert syslog["cap_drop"] == ["ALL"], compose
assert "cap_add" not in syslog, compose
PY
    done
}
