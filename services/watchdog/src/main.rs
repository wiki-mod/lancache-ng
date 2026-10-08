//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//!
//! What: watchdog health loop, restarts and status.json.
//! Why: one daemon keeps core services up, reports health.

use std::collections::HashMap;
use std::io::Write as _;
use std::os::unix::fs::OpenOptionsExt as _;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use lancache_watchdog::config::{self, ContainerNames, MonitoredService};
use lancache_watchdog::docker_client::DockerProxyClient;
use lancache_watchdog::health::{Action, AlertAction, AlertCounter, FailureCounter, HealthReading};
use lancache_watchdog::status::{self, DiskInfo, ServiceHealth, WatchdogStatus};

// What: containers watchdog only alerts on, never restarts.
// Why: dhcp/ntp restarts could race their config rollback.
// From: Issue #842
fn resolve_alert_only_targets(
    dhcp_mode: &str,
    logging_enabled: bool,
    ntp_enabled: bool,
) -> Vec<String> {
    // ui is never profile-gated in any deploy/*/docker-compose.yml profile,
    // unlike dhcp/dhcp-proxy/syslog/ntp, so it is always monitored here.
    let mut targets = vec![config::CONTAINER_UI.to_string()];
    if let Some(dhcp_container) = config::dhcp_alert_container(dhcp_mode) {
        targets.push(dhcp_container.to_string());
    }
    if logging_enabled {
        targets.push(config::CONTAINER_SYSLOG.to_string());
    }
    // NTP is profile-gated. Monitoring it when disabled would create a
    // permanent false alert for a container that intentionally does not exist.
    if ntp_enabled {
        targets.push(config::CONTAINER_NTP.to_string());
    }
    targets
}

// What: dhcp/ntp targets reconcile_desired_state acts on
// Why: shared shape for loop call site and tests
// From: Issue #1437
fn desired_state_targets(dhcp_mode: &str, ntp_enabled: bool) -> Vec<(&'static str, String)> {
    let mut targets = Vec::new();
    if let Some(dhcp_container) = config::dhcp_alert_container(dhcp_mode) {
        targets.push(("dhcp", dhcp_container.to_string()));
    }
    if ntp_enabled {
        targets.push(("ntp", config::CONTAINER_NTP.to_string()));
    }
    targets
}

// What: starts/stops one service to match its desired state
// Why: acts on diff; absent entry = no opinion
// From: Issue #1437
async fn reconcile_one(
    client: &DockerProxyClient,
    label: &str,
    container_name: &str,
    desired: Option<status::DesiredRunState>,
    timeout: Option<Duration>,
    action_timeout: Option<Duration>,
) {
    // No entry in desired-state.json is not "should run": that would make
    // watchdog start a container settings-reconcile just stopped on purpose
    // (dhcp_mode/ntp_enabled are resolved once at watchdog startup, so a
    // mode switch can leave a stale target here for several minutes). Only
    // an explicit dock action justifies watchdog taking either action.
    let Some(desired) = desired else {
        return;
    };
    let should_run = desired.should_run();
    let Some(running) = client.is_running(container_name, timeout).await else {
        return;
    };
    if should_run && !running {
        log(&format!(
            "STARTING {container_name} ({label}: desired state is running)"
        ));
        if !client.start(container_name, action_timeout).await {
            log_err(&format!("WARNING: start call failed for {container_name}"));
        }
    } else if !should_run && running {
        log(&format!(
            "STOPPING {container_name} ({label}: desired state is stopped)"
        ));
        if !client.stop(container_name, action_timeout).await {
            log_err(&format!("WARNING: stop call failed for {container_name}"));
        }
    }
}

// What: reconcile DHCP/NTP to desired state
// Why: watchdog is now the sole actor for these two services
// From: Issue #1437
async fn reconcile_desired_state(client: &DockerProxyClient, settings: &Settings) {
    let desired = status::read_desired_state(&settings.desired_state_file);
    for (label, container_name) in desired_state_targets(&settings.dhcp_mode, settings.ntp_enabled)
    {
        let desired_state = match label {
            "dhcp" => desired.dhcp,
            "ntp" => desired.ntp,
            _ => None,
        };
        reconcile_one(
            client,
            label,
            &container_name,
            desired_state,
            settings.curl_max_time,
            settings.curl_max_time_restart,
        )
        .await;
    }
}

// What: HH:MM:SS of the "[watchdog] HH:MM:SS msg" lines.
// Why: operators grep the docker logs for this exact shape.
fn timestamp_hms() -> String {
    const FORMAT: &[time::format_description::FormatItem] =
        time::macros::format_description!("[hour]:[minute]:[second]");
    time::OffsetDateTime::now_utc()
        .format(FORMAT)
        .expect("fixed UTC format description must always succeed")
}

// What: WATCHDOG_LOG_FILE opened once for append, or none.
// Why: fluent-bit tails the file; compose runs no tee.
// From: Issue #1683 | PR #1858
fn log_file() -> Option<&'static Mutex<std::fs::File>> {
    static FILE: OnceLock<Option<Mutex<std::fs::File>>> = OnceLock::new();
    FILE.get_or_init(|| {
        let path = std::env::var("WATCHDOG_LOG_FILE")
            .ok()
            .filter(|p| !p.is_empty())?;
        let opened = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o640)
            .open(&path);
        match opened {
            Ok(file) => Some(Mutex::new(file)),
            Err(e) => {
                eprintln!(
                    "[watchdog] {} WARNING: cannot open {path}: {e}",
                    timestamp_hms()
                );
                None
            }
        }
    })
    .as_ref()
}

// What: a line to its stream and to the log file, if any.
// Why: a failed file write is shown once, never silent.
// From: Issue #1683 | PR #1858
fn emit(line: &str, to_stderr: bool) {
    static WARNED: AtomicBool = AtomicBool::new(false);
    if to_stderr {
        eprintln!("{line}");
    } else {
        println!("{line}");
    }
    let Some(file) = log_file() else {
        return;
    };
    let written = match file.lock() {
        Ok(mut f) => writeln!(f, "{line}").map_err(|e| e.to_string()),
        Err(e) => Err(e.to_string()),
    };
    if let Err(e) = written
        && !WARNED.swap(true, Ordering::Relaxed)
    {
        eprintln!(
            "[watchdog] {} WARNING: cannot write the log file: {e}",
            timestamp_hms()
        );
    }
}

fn log(msg: &str) {
    emit(&format!("[watchdog] {} {msg}", timestamp_hms()), false);
}

fn log_err(msg: &str) {
    emit(&format!("[watchdog] {} {msg}", timestamp_hms()), true);
}

// What: startup settings, read once from the environment.
// Why: env reads stay here; config::* stays pure, tested.
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
    // What: read fresh every loop iteration, not once
    // Why: an operator's dock action must apply without a restart
    // From: Issue #1437
    desired_state_file: PathBuf,
    cache_dir: PathBuf,
    container_names: ContainerNames,
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
    let env = lancache_common::config::env_opt;

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

    // What: SSL_ENABLED defaults to true.
    // Why: same default as the ui's SSL_ENABLED.
    let ssl_enabled = config::resolve_bool(env("SSL_ENABLED").as_deref(), true);

    let container_names = match config::resolve_container_names(
        env("CONTAINER_PROXY").as_deref(),
        env("CONTAINER_DNS_STANDARD").as_deref(),
        env("CONTAINER_DNS_SSL").as_deref(),
        env("CONTAINER_NATS").as_deref(),
        ssl_enabled,
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

    // What: default path matches ui's own /data mount point
    // Why: no compose env override needed (like STATUS_FILE)
    // From: Issue #1437
    let desired_state_file = env("DESIRED_STATE_FILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/data/desired-state.json"));

    // What: CACHE_DIR, else the legacy split pair.
    // Why: old installs may set only the CACHE_DIR_* pair.
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
        desired_state_file,
        cache_dir,
        container_names,
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
        container_name: config::CONTAINER_NETDATA.to_string(),
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
        // What: acts on the operator's dhcp/ntp overrides this tick
        // Why: must run before health reporting reflects the result
        // From: Issue #1437
        reconcile_desired_state(&client, &settings).await;

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
        // What: proxy reachability as a health reading.
        // Why: red status without the restart counter.
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
        // What: a failed status write exits the process.
        // Why: compose restarts on exit, not on red health.
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
    use tokio::net::TcpListener;
    use tokio::time::timeout;

    #[test]
    // With every optional profile disabled, only the one always-on
    // alert-only service (ui) belongs in this set -- netdata moved to the
    // restart-capable `monitored` list in main() (issue #842, 2026-08-07
    // decision) and is no longer resolved here at all.
    fn no_optional_services_enabled_monitors_only_ui() {
        let targets = resolve_alert_only_targets("disabled", false, false);
        assert_eq!(targets, vec!["lancache-ui".to_string()]);
    }

    #[test]
    // NTP_ENABLED must add the real NTP container independently of the DHCP
    // and central-logging gates so degraded NTP health can become observable.
    fn ntp_enabled_adds_the_ntp_container() {
        let targets = resolve_alert_only_targets("disabled", false, true);
        assert!(targets.contains(&"lancache-ntp".to_string()));
    }

    #[test]
    // A disabled NTP profile has no NTP container, even when the other
    // optional services are active, so monitoring it would be a false alert.
    fn ntp_disabled_never_adds_the_ntp_container_even_with_others_enabled() {
        let targets = resolve_alert_only_targets("kea", true, false);
        assert!(!targets.contains(&"lancache-ntp".to_string()));
    }

    #[test]
    // Independent optional gates must compose without suppressing one another.
    fn all_optional_services_enabled_together() {
        let targets = resolve_alert_only_targets("kea", true, true);
        assert_eq!(
            targets,
            vec![
                "lancache-ui".to_string(),
                "lancache-dhcp".to_string(),
                "lancache-syslog".to_string(),
                "lancache-ntp".to_string(),
            ]
        );
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
        let targets = resolve_alert_only_targets("kea", true, true);
        assert!(!targets.iter().any(|t| t.starts_with("lancache-netdata")));
    }

    // What: only provisioned services are reconcile candidates
    // Why: proves disabled DHCP/NTP produce zero reconcile targets
    // From: Issue #1437
    #[test]
    fn desired_state_targets_is_empty_when_neither_service_is_provisioned() {
        let targets = desired_state_targets("disabled", false);
        assert!(targets.is_empty());
    }

    #[test]
    // Both the Kea and dnsmasq DHCP_MODE values must resolve to the "dhcp"
    // label -- an operator's start/stop control must not care which
    // container is actually behind it, only that "dhcp" is provisioned.
    fn desired_state_targets_resolves_dhcp_for_either_provisioned_mode() {
        let kea = desired_state_targets("kea", false);
        assert_eq!(kea, vec![("dhcp", "lancache-dhcp".to_string())]);

        let dnsmasq = desired_state_targets("dnsmasq-proxy", false);
        assert_eq!(dnsmasq, vec![("dhcp", "lancache-dhcp-proxy".to_string())]);
    }

    #[test]
    // What: dhcp and ntp provisioned yield both targets.
    // Why: a dropped target leaves its dock action unapplied.
    // From: Issue #1437 | PR #1858
    fn desired_state_targets_lists_both_provisioned_services() {
        let targets = desired_state_targets("kea", true);
        assert_eq!(
            targets,
            vec![
                ("dhcp", "lancache-dhcp".to_string()),
                ("ntp", "lancache-ntp".to_string()),
            ]
        );
    }

    // What: absent entry prevents proxy contact
    // Why: prevent watchdog-sync conflict
    // From: Issue #1437
    #[tokio::test]
    async fn reconcile_one_takes_no_action_when_desired_state_is_absent() {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind an ephemeral local port");
        let addr = listener
            .local_addr()
            .expect("listener must have a local address");
        let client = DockerProxyClient::new(format!("http://{addr}"))
            .expect("valid base url for an ephemeral loopback port");

        reconcile_one(&client, "dhcp", "lancache-dhcp", None, None, None).await;

        // No entry means "no opinion" (see status::DesiredState's doc
        // comment): reconcile_one must return before ever calling
        // is_running/start/stop, so no connection to the proxy is ever
        // attempted. A short timeout on accept() proves that absence.
        let accept_result = timeout(Duration::from_millis(200), listener.accept()).await;
        assert!(
            accept_result.is_err(),
            "reconcile_one must not contact the docker proxy when desired state is absent"
        );
    }
}
