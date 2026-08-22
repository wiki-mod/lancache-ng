//!
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

/// Alert-only services are never restarted. Their container list is built once
/// at startup because deployment gates and the coordinated container suffix do
/// not change during the lifetime of this process.
///
/// `netdata` is deliberately NOT in this set (issue #842's 2026-08-07
/// restart-capability decision): it is real restart-capable now, wired
/// directly into `monitored`/`failure_counters` in `main()` below, with its
/// own dedicated `safe_netdata_restart` docker-socket-proxy allowlist grant.
/// `ui`/`dhcp`/`dhcp-proxy`/`syslog`/`ntp` stay alert-only here -- `ui` is
/// tracked separately (PR #1610, Refs #1486), `dhcp`/`dhcp-proxy`/`ntp`
/// deliberately keep their own start/stop-only Admin-UI-driven lifecycle
/// (Kea/dnsmasq known-good-config rollback semantics a blind watchdog
/// restart could race), and `syslog`/`watchdog` itself must never be
/// user-disableable (#1486's cross-reference on #842) -- see this crate's
/// own PR body for the full per-service reasoning.
///
/// Central logging runs fluent-bit and syslog-ng in one `services/syslog/`
/// container named by `CONTAINER_SYSLOG`. Its own dual-process healthcheck
/// proves both processes are alive, while this layer consumes the resulting
/// per-container Docker health state.
fn resolve_alert_only_targets(
    dhcp_mode: &str,
    logging_enabled: bool,
    ntp_enabled: bool,
    container_suffix: &str,
) -> Vec<String> {
    // ui is never profile-gated in any deploy/*/docker-compose.yml profile,
    // unlike dhcp/dhcp-proxy/syslog/ntp, so it is always monitored here.
    //
    // Every deployment container_name uses the same coordinated suffix in
    // isolated CI stacks. Alert-only names must therefore apply that suffix
    // too; otherwise get_health() would query a container name that was never
    // started and report a permanent false "unreachable" state.
    let mut targets = vec![format!("{}{container_suffix}", config::CONTAINER_UI)];
    if let Some(dhcp_container) = config::dhcp_alert_container(dhcp_mode) {
        targets.push(format!("{dhcp_container}{container_suffix}"));
    }
    if logging_enabled {
        targets.push(format!("{}{container_suffix}", config::CONTAINER_SYSLOG));
    }
    // NTP is profile-gated. Monitoring it when disabled would create a
    // permanent false alert for a container that intentionally does not exist.
    if ntp_enabled {
        targets.push(format!("{}{container_suffix}", config::CONTAINER_NTP));
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
    // resolve_alert_only_targets() builds names from the plain
    // config::CONTAINER_* constants rather than ContainerNames, so it needs
    // the same coordinated suffix separately.
    container_suffix: String,
    // These gates describe whether optional alert-only containers are part of
    // the running stack. A deployment change recreates this container, so the
    // values are intentionally resolved once at startup.
    dhcp_mode: String,
    logging_enabled: bool,
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

    // Keep the suffix as its own setting because both ContainerNames and the
    // independently-built alert-only target list must use the same value.
    let container_suffix = env("LANCACHE_CONTAINER_SUFFIX").unwrap_or_default();

    let container_names = match config::resolve_container_names(
        env("CONTAINER_PROXY").as_deref(),
        env("CONTAINER_DNS_STANDARD").as_deref(),
        env("CONTAINER_DNS_SSL").as_deref(),
        env("CONTAINER_NATS").as_deref(),
        ssl_enabled,
        // Empty or unset is the normal deployment shape. A non-empty suffix
        // is used only by coordinated isolated validation stacks.
        Some(container_suffix.as_str()),
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

    // An absent or invalid DHCP mode must not create an alert for a DHCP
    // container that was never provisioned. The classifier itself owns the
    // accepted mode mapping and falls back to monitoring neither service.
    let dhcp_mode = env("DHCP_MODE").unwrap_or_else(|| "disabled".to_string());

    // LOGGING_ENABLED represents whether the combined syslog container is
    // part of the stack. SYSLOG_ENABLED is deliberately narrower and controls
    // only the storage-budget retention/pruning engine, so using it here would
    // leave the normal logging-enabled, retention-disabled deployment
    // unmonitored.
    let logging_enabled = config::resolve_bool(env("LOGGING_ENABLED").as_deref(), false);

    // NTP monitoring follows the same gate that controls whether the optional
    // NTP container exists, avoiding a false alert when the profile is off.
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
        container_suffix,
        dhcp_mode,
        logging_enabled,
        ntp_enabled,
    }
}

#[tokio::main]
async fn main() {
    let settings = load_settings();
    let client = DockerProxyClient::new(settings.docker_proxy_url.clone())
        .expect("building the reqwest client must not fail (no invalid static config)");

    // The data-driven service table replaces individually-named loop state.
    // ContainerNames remains separate because status generation also needs
    // the validated SSL-mode omission directly.
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
    // netdata (issue #842, 2026-08-07 restart-capability decision): real
    // restart-capable, not alert-only -- unlike ui/dhcp/dhcp-proxy/syslog/
    // ntp (see resolve_alert_only_targets()'s own doc comment for why those
    // stay alert-only). No conflicting rollback-safety concern exists for
    // netdata anywhere in issue #842's history, unlike dhcp/dhcp-proxy.
    // netdata is never profile-gated, so it is unconditionally monitored
    // here, matching resolve_alert_only_targets()'s own ui handling.
    monitored.push(MonitoredService {
        container_name: format!("{}{}", config::CONTAINER_NETDATA, settings.container_suffix),
        restart_after: settings.restart_after,
        grace_period: None,
    });

    let mut failure_counters: HashMap<String, FailureCounter> = monitored
        .iter()
        .map(|s| (s.container_name.clone(), FailureCounter::default()))
        .collect();
    let mut docker_proxy_alert_counter = AlertCounter::default();

    // Alert-only services use independent counters because an outage must
    // remain visible without ever crossing into restart behavior.
    let alert_only_targets = resolve_alert_only_targets(
        &settings.dhcp_mode,
        settings.logging_enabled,
        settings.ntp_enabled,
        &settings.container_suffix,
    );
    let mut alert_only_counters: HashMap<String, AlertCounter> = alert_only_targets
        .iter()
        .map(|name| (name.clone(), AlertCounter::default()))
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

        // The Docker proxy is alert-only because watchdog cannot safely
        // restart its own management channel.
        let reachable = client.ping(settings.curl_max_time).await;
        let docker_proxy_name = settings.container_names.docker_socket_proxy;
        match docker_proxy_alert_counter.record(reachable) {
            AlertAction::None => {}
            AlertAction::Recovered => log(&format!("RECOVERED {docker_proxy_name}")),
            AlertAction::Unreachable { count } => log(&format!(
                "UNHEALTHY {docker_proxy_name} ({count} consecutive failures) -- alert only, watchdog cannot restart its own Docker API channel"
            )),
        }
        // watchdog.sh's probe_docker_socket_proxy() stores the literal
        // string "healthy"/"unhealthy" into H_DOCKER_PROXY. Using
        // HealthReading::Unhealthy here renders a red management-plane alarm
        // without passing through restart-capable FailureCounter logic.
        let docker_proxy_reading = if reachable {
            HealthReading::Healthy
        } else {
            HealthReading::Unhealthy
        };
        services_status.insert(
            docker_proxy_name.to_string(),
            ServiceHealth::from_reading(&docker_proxy_reading, docker_proxy_alert_counter.0),
        );

        // Alert-only targets use the same Docker health read as restart-capable
        // services but route the result through AlertCounter, so they can
        // recover and accumulate failures without ever issuing a restart.
        for name in &alert_only_targets {
            let reading = client.get_health(name, settings.curl_max_time).await;
            let counter = alert_only_counters
                .get_mut(name)
                .expect("every alert-only target has a counter");
            match counter.record(reading.is_alert_ok()) {
                AlertAction::None => {}
                AlertAction::Recovered => log(&format!("RECOVERED {name}")),
                AlertAction::Unreachable { count } => log(&format!(
                    "UNHEALTHY {name} ({count} consecutive failures) -- alert only, watchdog does not restart this service"
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
        // check would correctly start reporting the container `unhealthy`
        // once status.json goes stale even without this exit, but Docker does
        // not restart a still-running process merely because health is red.
        if let Err(e) = status::write_status(&settings.status_file, &watchdog_status) {
            log_err(&format!(
                "ERROR: failed to write {}: {e}",
                settings.status_file.display()
            ));
            std::process::exit(1);
        }

        // Filesystem-retention passes run as their own dedicated `retention`
        // Compose service, so this daemon intentionally never invokes them.
        tokio::time::sleep(settings.check_interval).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    // With every optional profile disabled, only the one always-on
    // alert-only service (ui) belongs in this set -- netdata moved to the
    // restart-capable `monitored` list in main() (issue #842, 2026-08-07
    // decision) and is no longer resolved here at all.
    fn no_optional_services_enabled_monitors_only_ui() {
        let targets = resolve_alert_only_targets("disabled", false, false, "");
        assert_eq!(targets, vec!["lancache-ui".to_string()]);
    }

    #[test]
    // NTP_ENABLED must add the real NTP container independently of the DHCP
    // and central-logging gates so degraded NTP health can become observable.
    fn ntp_enabled_adds_the_ntp_container() {
        let targets = resolve_alert_only_targets("disabled", false, true, "");
        assert!(targets.contains(&"lancache-ntp".to_string()));
    }

    #[test]
    // A disabled NTP profile has no NTP container, even when the other
    // optional services are active, so monitoring it would be a false alert.
    fn ntp_disabled_never_adds_the_ntp_container_even_with_others_enabled() {
        let targets = resolve_alert_only_targets("kea", true, false, "");
        assert!(!targets.contains(&"lancache-ntp".to_string()));
    }

    #[test]
    // Independent optional gates must compose without suppressing one another.
    fn all_optional_services_enabled_together() {
        let targets = resolve_alert_only_targets("kea", true, true, "");
        assert!(targets.contains(&"lancache-ui".to_string()));
        assert!(targets.contains(&"lancache-dhcp".to_string()));
        assert!(targets.contains(&"lancache-syslog".to_string()));
        assert!(targets.contains(&"lancache-ntp".to_string()));
        // netdata is restart-capable now (main()'s own `monitored` list),
        // never resolved by this alert-only function -- see this file's own
        // resolve_alert_only_targets_never_includes_netdata() below for a
        // dedicated negative assertion.
    }

    #[test]
    // netdata must never reappear in the alert-only set -- it is
    // restart-capable now (issue #842, 2026-08-07 decision), wired directly
    // into main()'s own `monitored`/`failure_counters`, not through this
    // function at all. A regression here would double-monitor netdata
    // (once via AlertCounter, once via FailureCounter) with two independent,
    // disagreeing counters writing the same status.json key.
    fn resolve_alert_only_targets_never_includes_netdata() {
        let targets = resolve_alert_only_targets("kea", true, true, "");
        assert!(!targets.iter().any(|t| t.starts_with("lancache-netdata")));
    }

    #[test]
    // A coordinated container suffix must reach every alert-only target, not
    // only the restart-capable ContainerNames fields.
    fn resolve_alert_only_targets_applies_the_coordinated_suffix() {
        let targets = resolve_alert_only_targets("kea", true, true, "-ci1");
        assert_eq!(
            targets,
            vec![
                "lancache-ui-ci1".to_string(),
                "lancache-dhcp-ci1".to_string(),
                "lancache-syslog-ci1".to_string(),
                "lancache-ntp-ci1".to_string(),
            ]
        );
    }

    #[test]
    // An empty coordinated suffix is deliberately a no-op for every target.
    fn resolve_alert_only_targets_is_unchanged_with_no_suffix() {
        let targets = resolve_alert_only_targets("disabled", false, false, "");
        assert_eq!(targets, vec!["lancache-ui".to_string()]);
    }
}
