#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for #849 bug-hunt finding observability.md#19: dashboard.html's
# "Recent requests (proxy)" tile always reads nginx's own direct access log
# (routes/dashboard.rs's recent_logs_task), even once syslog mode is enabled
# and /logs switches to the aggregated central syslog-ng store instead --
# the two views can then show data through different pipelines on the same
# install with no indication to the operator. Not a data-loss bug (nginx
# keeps writing its own access log regardless), so the fix labels the source
# explicitly instead of merging two structurally incompatible log formats.
# Structural grep-based guard on the Tera template (no template-render test
# harness exists in this project to assert against, see routes/dashboard.rs's
# own lack of one).

bats_require_minimum_version 1.5.0

DASHBOARD_HTML="services/ui/src/templates/dashboard.html"

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    cd "$repo_root"
}

@test "dashboard.html labels the Recent requests tile's source only when syslog_enabled" {
    # The label must be gated behind its own {% if syslog_enabled %} block --
    # an always-visible label would be noise for the (default) non-syslog
    # install where there is nothing to disambiguate.
    block=$(awk '/Recent requests \(proxy\)<\/h2>/{flag=1} flag{print} /\{% if recent_logs %\}/{exit}' "$DASHBOARD_HTML")
    [[ "$block" == *"{% if syslog_enabled %}"* ]]
    [[ "$block" == *"direct nginx log"* ]]
    [[ "$block" == *"/logs"* ]]
}
