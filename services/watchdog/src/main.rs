
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//!
//! Binary entry point for the Rust rewrite of watchdog.sh's health-check/
//! restart loop. See `lib.rs`'s module doc comment for the current scope
//! (health checks + restart + status.json + the docker-socket-proxy alert
//! probe; NOT yet the three filesystem-retention passes) and why
//! `services/watchdog/Dockerfile`'s `ENTRYPOINT` still points at the bash
//! script rather than this binary.

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Duration;

use lancache_watchdog::config::{self, ContainerNames, MonitoredService};
use lancache_watchdog::docker_client::DockerProxyClient;
use lancache_watchdog::health::{Action, AlertAction, AlertCounter, FailureCounter, HealthReading};
use lancache_watchdog::status::{self, DiskInfo, ServiceHealth, WatchdogStatus};

/// Issue #842's alert-only monitored services (never restarted -- see
/// `lib.rs`'s module doc comment and [`HealthReading::is_alert_ok`]'s own
/// doc comment for why), plus `ntp` (issue #1296, see this function's own
/// `ntp_enabled` handling below). Built once at startup from [`Settings`]
/// rather than re-derived every loop iteration, since `DHCP_MODE`/
/// `SYSLOG_ENABLED`/`NTP_ENABLED` never change for the lifetime of this
/// process.
///
/// UPDATED (syslog+fluent-bit consolidation PR, 2026-08, merged concurrently
/// with issue #842/#849 introducing this function): `syslog` (fluent-bit)
/// and `syslog-ng` used to be two separate containers, both alert-only
/// monitored under their own fixed names (`CONTAINER_SYSLOG`,
/// `CONTAINER_SYSLOG_NG`). They are now ONE combined container
/// (`services/syslog/`) under the single container name `CONTAINER_SYSLOG`
/// -- `CONTAINER_SYSLOG_NG` ("lancache-syslog-ng") no longer names any real
/// container this stack ever starts, so pushing it here would make every
/// health check against it fail closed permanently (container not found),
/// a false alert for a container that was never supposed to exist by
/// design, not a real outage. Only `CONTAINER_SYSLOG` is pushed now; the
/// combined container's own dual-process healthcheck
/// (`services/syslog/healthcheck.sh`) is what actually proves fluent-bit
/// AND syslog-ng are both alive inside it, one level below what this
/// per-container Docker-API check can see.
fn resolve_alert_only_targets(
    dhcp_mode: &str,
    syslog_enabled: bool,
    ntp_enabled: bool,
) -> Vec<&'static str> {
    // ui/netdata are never profile-gated in any deploy/*/docker-compose.yml
    // profile (unlike dhcp/dhcp-proxy/syslog/ntp below), so both are
    // always monitored, matching how proxy/dns-standard/nats are always
    // monitored among the four restart-capable services above.
    let mut targets = vec![config::CONTAINER_UI, config::CONTAINER_NETDATA];
    if let Some(dhcp_container) = config::dhcp_alert_container(dhcp_mode) {
        targets.push(dhcp_container);
    }
    if syslog_enabled {
        targets.push(config::CONTAINER_SYSLOG);
    }
    // Issue #1296: closes this project's own pre-existing gap (issue #842:
    // "watchdog only monitors proxy/dns-standard/dns-ssl") for `ntp`
    // specifically, and is the only caller that ever makes
    // `HealthReading::Degraded` (this same module's amber dashboard state
    // for a CAP_SYS_TIME-denied `ntp` container) actually reachable --
    // without `ntp` being monitored at all, get_health() would never be
    // called for it, and the degraded-mode detection plumbing in
    // docker_client.rs would never run against a real container.
    if ntp_enabled {
        targets.push(config::CONTAINER_NTP);
    }
    targets
}

// Matches watchdog.sh's log()/log_err(): "[watchdog] HH:MM:SS msg". Kept as
// this exact shape (rather than switching to a structured `tracing`
// format) so operators grepping existing `docker logs lancache-watchdog`
// output/dashboards built around this line shape see no discontinuity the
// day this binary eventually replaces the bash entrypoint.
fn timestamp_hms() -> String {
    const FORMAT: &[time::format_description::FormatItem] =
        time::macros::format_description!("[hour]:[minute]:[second]");
    time::OffsetDateTime::now_utc()
        .format(FORMAT)
        .expect("fixed UTC format description must always succeed")
}

fn log(msg: &str) {
    println!("[watchdog] {} {msg}", timestamp_hms());
}

fn log_err(msg: &str) {
    eprintln!("[watchdog] {} {msg}", timestamp_hms());
}

// Startup env parsing, mirrored from watchdog.sh's top-of-file section.
// Kept in main.rs (not lib.rs) because it reads real process environment
// variables -- everything it calls into (config::*) is itself pure and
// unit-tested independently.
struct Settings {
    docker_proxy_url: String,
    check_interval: Duration,
    restart_after: u32,
    // `None` means "no timeout", matching curl's own `--max-time 0`
    // semantics for CURL_MAX_TIME/CURL_MAX_TIME_RESTART -- see
    // config::parse_curl_timeout's doc comment. Never represented as
    // `Duration::ZERO`: docker_client's bounded()/apply_timeout() treat
    // that as "essentially instant", the opposite of "unbounded".
    curl_max_time: Option<Duration>,
    curl_max_time_restart: Option<Duration>,
    disk_warn_pct: u32,
    disk_alarm_pct: u32,
    status_file: PathBuf,
    cache_dir: PathBuf,
    container_names: ContainerNames,
    // Issue #842 (dhcp_mode/syslog_enabled) + #1296 (ntp_enabled): gates
    // which of the alert-only services (see resolve_alert_only_targets())
    // are actually deployed. Read once here (not re-read per loop
    // iteration) since none of these three knobs can change for the
    // lifetime of this process -- an operator changing DHCP_MODE/
    // SYSLOG_ENABLED/NTP_ENABLED requires a `setup.sh update` + container
    // recreate, which restarts this process anyway.
    dhcp_mode: String,
    syslog_enabled: bool,
    ntp_enabled: bool,
}

fn load_settings() -> Settings {
    // Filters an explicitly-empty env value (e.g. `DOCKER_PROXY_URL=` set
    // but blank) down to `None` here, at the single point every setting in
    // this function reads from -- see config::non_empty's own doc comment
    // for why bash's `${VAR:-default}` treats empty and unset identically.
    // This also makes the equivalent filtering inside config::resolve_bool/
    // parse_u64_with_default/resolve_container_names redundant for THESE
    // call sites specifically, which is fine: those functions still need
    // their own guard so they stay correct for any other caller, not just
    // this one.
    let env = |name: &str| {
        let value = std::env::var(name).ok();
        config::non_empty(value.as_deref()).map(str::to_string)
    };

    let docker_proxy_url =
        env("DOCKER_PROXY_URL").unwrap_or_else(|| "http://docker-socket-proxy:2375".to_string());

    let (check_interval, warnings) = config::parse_check_interval(env("CHECK_INTERVAL").as_deref());
    for w in warnings {
        log(&w);
    }

    let (restart_after, warnings) = config::parse_restart_after(env("RESTART_AFTER").as_deref());
    for w in warnings {
        log(&w);
    }

    let (curl_max_time, warnings) =
        config::parse_curl_timeout(env("CURL_MAX_TIME").as_deref(), "CURL_MAX_TIME", 5);
    for w in warnings {
        log(&w);
    }
    let (curl_max_time_restart, warnings) = config::parse_curl_timeout(
        env("CURL_MAX_TIME_RESTART").as_deref(),
        "CURL_MAX_TIME_RESTART",
        30,
    );
    for w in warnings {
        log(&w);
    }

    let (disk_warn_pct, warnings) =
        config::parse_u32_with_default(env("DISK_WARN_PCT").as_deref(), "DISK_WARN_PCT", 85);
    for w in warnings {
        log(&w);
    }
    let (disk_alarm_pct, warnings) =
        config::parse_u32_with_default(env("DISK_ALARM_PCT").as_deref(), "DISK_ALARM_PCT", 95);
    for w in warnings {
        log(&w);
    }

    // SSL_ENABLED defaults truthy, matching watchdog.sh's `is_truthy
    // "${SSL_ENABLED:-1}"`.
    let ssl_enabled = config::resolve_bool(env("SSL_ENABLED").as_deref(), true);

    let container_names = match config::resolve_container_names(
        env("CONTAINER_PROXY").as_deref(),
        env("CONTAINER_DNS_STANDARD").as_deref(),
        env("CONTAINER_DNS_SSL").as_deref(),
        env("CONTAINER_NATS").as_deref(),
        ssl_enabled,
        // Issue #1415: see resolve_container_names()'s own doc comment --
        // empty/unset for every real install, only ever non-empty for a
        // CI-coordinated quickstart-compose run.
        env("LANCACHE_CONTAINER_SUFFIX").as_deref(),
    ) {
        Ok(names) => names,
        Err(msg) => {
            log_err(&msg);
            std::process::exit(1);
        }
    };

    let status_file = env("STATUS_FILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/var/run/watchdog/status.json"));

    // Mirrors watchdog.sh's resolve_cache_dir(): CACHE_DIR wins outright,
    // but an older installation may still only have the pre-CACHE_DIR
    // split CACHE_DIR_STANDARD/CACHE_DIR_SSL pair set -- reading only
    // CACHE_DIR here would silently fall back to the default and report
    // disk usage for the wrong filesystem on such an install. Conflicting
    // legacy values with no CACHE_DIR to arbitrate is fatal, matching the
    // bash's own exit 1, via the same log_err-then-exit(1) pattern
    // resolve_container_names's fail-closed mismatch uses above.
    let cache_dir = match config::resolve_cache_dir(
        env("CACHE_DIR").as_deref(),
        env("CACHE_DIR_STANDARD").as_deref(),
        env("CACHE_DIR_SSL").as_deref(),
    ) {
        Ok(dir) => PathBuf::from(dir),
        Err(msg) => {
            log_err(&msg);
            std::process::exit(1);
        }
    };

    // DHCP_MODE (issue #842): defaults to "disabled", matching setup.sh's
    // own `append_env_key_if_missing DHCP_MODE "disabled"` -- an install
    // that never set this at all (or a value setup.sh itself would already
    // have rejected) must not accidentally start alert-only-monitoring a
    // DHCP container that was never provisioned. See
    // config::dhcp_alert_container()'s own doc comment for why an
    // unrecognized value also falls back to "monitor neither", not a guess.
    let dhcp_mode = env("DHCP_MODE").unwrap_or_else(|| "disabled".to_string());

    // SYSLOG_ENABLED (issue #842): same env var and same default (false)
    // retention.sh already uses for its own syslog-ng retention gate --
    // reusing it here rather than inventing a second toggle keeps one
    // enable/disable knob for the whole central-logging feature rather than
    // two that could drift (the exact class of bug #877 already fixed once
    // for SYSLOG_ENABLED's truthy-parsing between the Admin UI and
    // watchdog.sh).
    let syslog_enabled = config::resolve_bool(env("SYSLOG_ENABLED").as_deref(), false);

    // NTP_ENABLED (issue #1296): same `setup.sh`-provisioned env var and
    // same default (false/"0", via `append_env_key_if_missing NTP_ENABLED
    // "0"`) that gates the `ntp` Compose profile itself -- reusing it here
    // rather than inventing a second toggle, same reasoning as
    // SYSLOG_ENABLED above. Alert-only monitoring for `ntp` only makes
    // sense once this project's own install actually started that
    // container in the first place; an install with NTP_ENABLED=0 has no
    // `lancache-ntp` container at all, and would otherwise show a false
    // permanent alert for a container that was never supposed to exist.
    let ntp_enabled = config::resolve_bool(env("NTP_ENABLED").as_deref(), false);

    Settings {
        docker_proxy_url,
        check_interval,
        restart_after,
        curl_max_time,
        curl_max_time_restart,
        disk_warn_pct,
        disk_alarm_pct,
        status_file,
        cache_dir,
        container_names,
        dhcp_mode,
        syslog_enabled,
        ntp_enabled,
    }
}

#[tokio::main]
async fn main() {
    let settings = load_settings();
    let client = DockerProxyClient::new(settings.docker_proxy_url.clone())
        .expect("building the reqwest client must not fail (no invalid static config)");

    // The data-driven service table the maintainer's own rewrite brief
    // asked for, replacing watchdog.sh's four individually-named
    // C_PROXY/C_DNS_STD/C_DNS_SSL/C_NATS variables. Built fresh from
    // ContainerNames rather than stored on Settings: this is the shape the
    // main loop iterates, while ContainerNames is the validated
    // env-resolution result the rest of the program (status.json's
    // dns-ssl-key omission) also needs directly.
    let mut monitored: Vec<MonitoredService> = vec![
        MonitoredService {
            container_name: settings.container_names.proxy.clone(),
            restart_after: settings.restart_after,
            grace_period: None,
        },
        MonitoredService {
            container_name: settings.container_names.dns_standard.clone(),
            restart_after: settings.restart_after,
            grace_period: None,
        },
    ];
    if let Some(dns_ssl) = &settings.container_names.dns_ssl {
        monitored.push(MonitoredService {
            container_name: dns_ssl.clone(),
            restart_after: settings.restart_after,
            grace_period: None,
        });
    }
    monitored.push(MonitoredService {
        container_name: settings.container_names.nats.clone(),
        restart_after: settings.restart_after,
        grace_period: None,
    });

    let mut failure_counters: HashMap<String, FailureCounter> = monitored
        .iter()
        .map(|s| (s.container_name.clone(), FailureCounter::default()))
        .collect();
    let mut docker_proxy_alert_counter = AlertCounter::default();

    // Issue #842: ui/dhcp/dhcp-proxy/netdata/syslog (the last one combining
    // fluent-bit+syslog-ng since the consolidation PR, 2026-08), plus ntp
    // (issue #1296), all alert-only (never restarted -- see
    // resolve_alert_only_targets()'s own doc comment and lib.rs's module
    // doc comment for why). A separate
    // AlertCounter per container, keyed the same way failure_counters is
    // above, so a persistently-down alert-only service keeps climbing
    // (never resets on some arbitrary threshold the way a restart-capable
    // FailureCounter would) -- see HealthReading::is_alert_ok's own doc
    // comment for the reasoning behind reusing AlertCounter's semantics
    // here instead of FailureCounter's.
    let alert_only_targets = resolve_alert_only_targets(
        &settings.dhcp_mode,
        settings.syslog_enabled,
        settings.ntp_enabled,
    );
    let mut alert_only_counters: HashMap<&'static str, AlertCounter> = alert_only_targets
        .iter()
        .map(|name| (*name, AlertCounter::default()))
        .collect();

    log(&format!(
        "Watchdog started. Monitoring: {} (SSL_ENABLED={}); alert-only probe: {}; alert-only monitored: {}",
        monitored
            .iter()
            .map(|s| s.container_name.as_str())
            .collect::<Vec<_>>()
            .join(" "),
        if settings.container_names.dns_ssl.is_some() {
            1
        } else {
            0
        },
        settings.container_names.docker_socket_proxy,
        if alert_only_targets.is_empty() {
            "none".to_string()
        } else {
            alert_only_targets.join(" ")
        },
    ));
    log(&format!(
        "Cache directory: {}",
        settings.cache_dir.display()
    ));
    log(&format!(
        "Interval: {}s | Restart after: {} | Disk warn: {}% alarm: {}%",
        settings.check_interval.as_secs(),
        settings.restart_after,
        settings.disk_warn_pct,
        settings.disk_alarm_pct,
    ));

    loop {
        let mut services_status: HashMap<String, ServiceHealth> = HashMap::new();

        for service in &monitored {
            let reading = client
                .get_health(&service.container_name, settings.curl_max_time)
                .await;
            let counter = failure_counters
                .get_mut(&service.container_name)
                .expect("every monitored service has a counter");
            let name = &service.container_name;

            match counter.record(&reading, service.restart_after) {
                Action::None => {}
                Action::Unhealthy { count, threshold } => {
                    log(&format!("UNHEALTHY {name} ({count}/{threshold})"));
                }
                Action::Restart { threshold } => {
                    log(&format!("UNHEALTHY {name} ({threshold}/{threshold})"));
                    log(&format!("RESTARTING {name}"));
                    if !client.restart(name, settings.curl_max_time_restart).await {
                        log(&format!("WARNING: restart call failed for {name}"));
                    }
                }
                Action::Recovered => {
                    log(&format!("RECOVERED {name}"));
                }
            }

            services_status.insert(
                name.clone(),
                ServiceHealth::from_reading(&reading, counter.0),
            );
        }

        // Alert-only docker-socket-proxy probe: deliberately never
        // restarted -- see docker_client::ping's and health::AlertCounter's
        // own doc comments for why.
        let reachable = client.ping(settings.curl_max_time).await;
        let docker_proxy_name = settings.container_names.docker_socket_proxy;
        match docker_proxy_alert_counter.record(reachable) {
            AlertAction::None => {}
            AlertAction::Recovered => log(&format!("RECOVERED {docker_proxy_name}")),
            AlertAction::Unreachable { count } => log(&format!(
                "UNHEALTHY {docker_proxy_name} ({count} consecutive failures) -- alert only, watchdog cannot restart its own Docker API channel (see issue #1170)"
            )),
        }
        // watchdog.sh's probe_docker_socket_proxy() stores the literal
        // string "healthy"/"unhealthy" into H_DOCKER_PROXY (never
        // "unreachable" -- that string is reserved for get_health()'s
        // per-container Docker-API failures). Using HealthReading::Unhealthy
        // here (not ::Unreachable) matches that exactly: health_color()
        // renders it red, the correct alarm-level color for "the management
        // plane's own Docker API gateway is down," not the yellow
        // indeterminate-warning color ::Unreachable maps to. This is purely
        // a status.json/dashboard representation choice -- it does not run
        // through FailureCounter/restart logic at all, so it carries none of
        // ::Unhealthy's restart-triggering meaning for the four monitored
        // containers above; only AlertCounter (which never restarts
        // anything) drives this probe's actual behavior.
        let docker_proxy_reading = if reachable {
            HealthReading::Healthy
        } else {
            HealthReading::Unhealthy
        };
        services_status.insert(
            docker_proxy_name.to_string(),
            ServiceHealth::from_reading(&docker_proxy_reading, docker_proxy_alert_counter.0),
        );

        // Issue #842: the five alert-only services resolved at startup (see
        // resolve_alert_only_targets()). Same per-container Docker-API
        // inspect as the restart-capable services above (get_health()), but
        // driven through AlertCounter/is_alert_ok() instead of
        // FailureCounter/Action -- never restarted, matching the
        // docker-socket-proxy probe's own alert-only shape immediately
        // above, generalized from one hardcoded container to a list.
        for name in &alert_only_targets {
            let reading = client.get_health(name, settings.curl_max_time).await;
            let counter = alert_only_counters
                .get_mut(name)
                .expect("every alert-only target has a counter");
            match counter.record(reading.is_alert_ok()) {
                AlertAction::None => {}
                AlertAction::Recovered => log(&format!("RECOVERED {name}")),
                AlertAction::Unreachable { count } => log(&format!(
                    "UNHEALTHY {name} ({count} consecutive failures) -- alert only, watchdog does not restart this service (issue #842)"
                )),
            }
            services_status.insert(
                name.to_string(),
                ServiceHealth::from_reading(&reading, counter.0),
            );
        }

        let disk_cache = status::disk_info(
            &settings.cache_dir,
            settings.disk_warn_pct,
            settings.disk_alarm_pct,
        );
        let watchdog_status = WatchdogStatus {
            updated: status::format_updated_timestamp(time::OffsetDateTime::now_utc()),
            services: services_status,
            disk: DiskInfo { cache: disk_cache },
        };
        // A failed status write is treated as fatal, matching the bash
        // implementation's behavior under `set -e`: a failing `mkdir`/
        // tmp-file write/`mv` there exits the whole script. That distinction
        // matters operationally, not just for parity's own sake -- the
        // Compose `watchdog` service (deploy/*/docker-compose.yml) sets
        // `restart: always`, so an exited process actually gets the
        // orchestrator to restart it. `healthcheck.sh`'s own mtime-freshness
        // check (see this loop's own comment further below) would correctly
        // start reporting the container `unhealthy` once status.json goes
        // stale even without this exit -- but `restart: always` alone only
        // restarts a container whose process actually exits, not one that is
        // merely reported unhealthy while still running; without this exit,
        // the process would keep running, correctly flagged unhealthy, with
        // no automatic recovery path unless something else (external to this
        // Compose file) acts on that health status.
        if let Err(e) = status::write_status(&settings.status_file, &watchdog_status) {
            log_err(&format!(
                "ERROR: failed to write {}: {e}",
                settings.status_file.display()
            ));
            std::process::exit(1);
        }

        // maybe_purge()/maybe_prune_syslog()/maybe_rotate_fluent_bit_selflog()
        // are intentionally never called here: those filesystem-retention
        // passes run as their own dedicated `retention` Compose service (see
        // lib.rs's module doc comment) -- not a scope question still open
        // for this daemon to eventually absorb.

        tokio::time::sleep(settings.check_interval).await;
    }
}

#[cfg(test)]
mod resolve_alert_only_targets_tests {
    use super::*;

    #[test]
    // Baseline: DHCP disabled, syslog disabled, ntp disabled -- only the
    // two always-on services (ui/netdata) are monitored.
    fn no_optional_services_enabled_monitors_only_ui_and_netdata() {
        let targets = resolve_alert_only_targets("disabled", false, false);
        assert_eq!(
            targets,
            vec![config::CONTAINER_UI, config::CONTAINER_NETDATA]
        );
    }

    #[test]
    // Issue #1296: NTP_ENABLED=true adds lancache-ntp to the alert-only
    // set, independent of DHCP_MODE/SYSLOG_ENABLED -- this is the only
    // code path that makes get_health()'s new Degraded detection for `ntp`
    // reachable at all against a real container.
    fn ntp_enabled_adds_the_ntp_container() {
        let targets = resolve_alert_only_targets("disabled", false, true);
        assert!(targets.contains(&config::CONTAINER_NTP));
    }

    #[test]
    // ntp_enabled=false must NOT add the ntp container, even when every
    // other optional service is on -- an install without NTP_ENABLED=1 has
    // no `lancache-ntp` container, and monitoring it anyway would produce
    // a permanent false "unreachable" alert for a container that was
    // never supposed to exist.
    fn ntp_disabled_never_adds_the_ntp_container_even_with_others_enabled() {
        let targets = resolve_alert_only_targets("kea", true, false);
        assert!(!targets.contains(&config::CONTAINER_NTP));
    }

    #[test]
    // All three optional gates together: dhcp/syslog/ntp all present
    // alongside the two always-on services, with no interference between
    // the three independent gates.
    fn all_optional_services_enabled_together() {
        let targets = resolve_alert_only_targets("kea", true, true);
        assert!(targets.contains(&config::CONTAINER_UI));
        assert!(targets.contains(&config::CONTAINER_NETDATA));
        assert!(targets.contains(&config::CONTAINER_DHCP));
        assert!(targets.contains(&config::CONTAINER_SYSLOG));
        assert!(targets.contains(&config::CONTAINER_NTP));
    }
}
