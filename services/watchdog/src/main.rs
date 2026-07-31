//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Binary entry point for the Rust rewrite of watchdog.sh's health-check/
//! restart loop (issue #842). See `lib.rs`'s module doc comment for the
//! current scope (health checks + restart + status.json + the
//! docker-socket-proxy alert probe; NOT yet the three filesystem-retention
//! passes) and why `services/watchdog/Dockerfile`'s `ENTRYPOINT` still
//! points at the bash script rather than this binary.

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Duration;

use lancache_watchdog::config::{self, ContainerNames, MonitoredService};
use lancache_watchdog::docker_client::DockerProxyClient;
use lancache_watchdog::health::{Action, AlertAction, AlertCounter, FailureCounter, HealthReading};
use lancache_watchdog::status::{self, DiskInfo, ServiceHealth, WatchdogStatus};

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
    curl_max_time: Duration,
    curl_max_time_restart: Duration,
    disk_warn_pct: u32,
    disk_alarm_pct: u32,
    status_file: PathBuf,
    cache_dir: PathBuf,
    container_names: ContainerNames,
}

fn load_settings() -> Settings {
    let env = |name: &str| std::env::var(name).ok();

    let docker_proxy_url =
        env("DOCKER_PROXY_URL").unwrap_or_else(|| "http://docker-socket-proxy:2375".to_string());

    let (check_interval, warnings) = config::parse_check_interval(env("CHECK_INTERVAL").as_deref());
    for w in warnings {
        log(&w);
    }

    let (restart_after, warning) =
        config::parse_u64_with_default(env("RESTART_AFTER").as_deref(), "RESTART_AFTER", 3);
    if let Some(w) = warning {
        log(&w);
    }

    let (curl_max_time, warning) =
        config::parse_u64_with_default(env("CURL_MAX_TIME").as_deref(), "CURL_MAX_TIME", 5);
    if let Some(w) = warning {
        log(&w);
    }
    let (curl_max_time_restart, warning) = config::parse_u64_with_default(
        env("CURL_MAX_TIME_RESTART").as_deref(),
        "CURL_MAX_TIME_RESTART",
        30,
    );
    if let Some(w) = warning {
        log(&w);
    }

    let (disk_warn_pct, warning) =
        config::parse_u64_with_default(env("DISK_WARN_PCT").as_deref(), "DISK_WARN_PCT", 85);
    if let Some(w) = warning {
        log(&w);
    }
    let (disk_alarm_pct, warning) =
        config::parse_u64_with_default(env("DISK_ALARM_PCT").as_deref(), "DISK_ALARM_PCT", 95);
    if let Some(w) = warning {
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
    let cache_dir = env("CACHE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/var/cache/lancache"));

    Settings {
        docker_proxy_url,
        check_interval,
        restart_after: restart_after as u32,
        curl_max_time: Duration::from_secs(curl_max_time),
        curl_max_time_restart: Duration::from_secs(curl_max_time_restart),
        disk_warn_pct: disk_warn_pct as u32,
        disk_alarm_pct: disk_alarm_pct as u32,
        status_file,
        cache_dir,
        container_names,
    }
}

#[tokio::main]
async fn main() {
    let settings = load_settings();
    let client = DockerProxyClient::new(settings.docker_proxy_url.clone())
        .expect("building the reqwest client must not fail (no invalid static config)");

    // The data-driven service table issue #842's maintainer follow-up
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

    log(&format!(
        "Watchdog started. Monitoring: {} (SSL_ENABLED={}); alert-only probe: {}",
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

        // Alert-only docker-socket-proxy probe (issue #1170 Part 1):
        // deliberately never restarted -- see docker_client::ping's and
        // health::AlertCounter's own doc comments for why.
        let reachable = client.ping(settings.curl_max_time).await;
        let docker_proxy_name = settings.container_names.docker_socket_proxy;
        match docker_proxy_alert_counter.record(reachable) {
            AlertAction::None => {}
            AlertAction::Recovered => log(&format!("RECOVERED {docker_proxy_name}")),
            AlertAction::Unreachable { count } => log(&format!(
                "UNHEALTHY {docker_proxy_name} ({count} consecutive failures) -- alert only, watchdog cannot restart its own Docker API channel (see issue #1170)"
            )),
        }
        let docker_proxy_reading = if reachable {
            HealthReading::Healthy
        } else {
            HealthReading::Unreachable
        };
        services_status.insert(
            docker_proxy_name.to_string(),
            ServiceHealth::from_reading(&docker_proxy_reading, docker_proxy_alert_counter.0),
        );

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
        if let Err(e) = status::write_status(&settings.status_file, &watchdog_status) {
            log_err(&format!(
                "ERROR: failed to write {}: {e}",
                settings.status_file.display()
            ));
        }

        // Deliberately NOT called here yet: maybe_purge()/
        // maybe_prune_syslog()/maybe_rotate_fluent_bit_selflog() -- see
        // lib.rs's module doc comment for the open scope question these
        // depend on.

        tokio::time::sleep(settings.check_interval).await;
    }
}
