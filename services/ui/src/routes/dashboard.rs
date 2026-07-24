//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//! Main dashboard route displaying cache statistics and connection metrics.

use crate::{AppState, config::DhcpMode, nginx_client, syslog_client, watchdog_status};
use axum::extract::State;
use axum::response::{Html, Json};
use serde_json::json;
use std::sync::Arc;
use tera::Context;

// Renders a watchdog_status::read_status() result into the plain JSON shape
// both the initial dashboard() render and the polling watchdog_status_api()
// endpoint share, so the two can never drift into different field names or
// state-classification logic (Fresh/Stale/Unavailable) the way standard_status/
// ssl_status briefly could have before being unified through one helper.
// `state`/`age_seconds`/`stale_after_seconds` let dashboard.html render three
// distinct visual states (see that template's own comment) instead of
// collapsing "never wired up" and "was working, now stopped" into one
// generic "unknown."
fn watchdog_status_json(result: watchdog_status::WatchdogStatusReadResult) -> serde_json::Value {
    match result {
        watchdog_status::WatchdogStatusReadResult::Fresh(status) => json!({
            "state": "fresh",
            "updated": status.updated,
            "services": watchdog_status::sorted_service_views(&status),
            "disk": status.disk,
        }),
        watchdog_status::WatchdogStatusReadResult::Stale(status, age) => json!({
            "state": "stale",
            "updated": status.updated,
            "age_seconds": age.as_secs(),
            "services": watchdog_status::sorted_service_views(&status),
            "disk": status.disk,
        }),
        watchdog_status::WatchdogStatusReadResult::Unavailable => json!({
            "state": "unavailable",
        }),
    }
}

pub async fn dashboard(State(state): State<Arc<AppState>>) -> Html<String> {
    let cfg = &state.config;

    // PROXY_STANDARD_URL and PROXY_SSL_URL default to the same value and
    // only diverge when an operator explicitly runs standard-mode and
    // ssl-mode as two separate proxy services with different stub_status
    // endpoints (see CLAUDE.md's "Two-Mode / Two-IP Architecture"). When
    // they're equal, the second HTTP call would just re-fetch identical
    // stats from the same nginx, so it's skipped and the first result is
    // reused instead.
    let standard_status_future =
        nginx_client::get_stub_status(&state.http_client, &cfg.proxy_standard_url);
    let ssl_status_future = async {
        if cfg.ssl_enabled && cfg.proxy_standard_url != cfg.proxy_ssl_url {
            nginx_client::get_stub_status(&state.http_client, &cfg.proxy_ssl_url).await
        } else {
            None
        }
    };

    // Each of these three stats sources does blocking I/O (`du`, reading
    // full log files) — run in spawn_blocking so a slow disk doesn't stall
    // the async runtime's worker threads for other in-flight requests. Start
    // every independent collector before awaiting so dashboard latency is the
    // slowest collector, not the sum of all collectors.
    let cache_used_task = tokio::task::spawn_blocking({
        let d = cfg.cache_dir.clone();
        move || nginx_client::get_cache_size_gb(&d)
    });
    let log_stats_task = tokio::task::spawn_blocking({
        let sl = cfg.standard_log.clone();
        let xl = cfg.ssl_log.clone();
        move || nginx_client::get_log_stats(&sl, &xl)
    });

    let recent_logs_task = tokio::task::spawn_blocking({
        let path = if cfg.standard_log == cfg.ssl_log {
            cfg.standard_log.clone()
        } else {
            cfg.ssl_log.clone()
        };
        move || nginx_client::parse_log_tail(&path, 10)
    });

    // Syslog store size/stats (#633 PR4): same spawn_blocking-wrapped shape
    // as the three collectors above (get_syslog_size_gb shells out to `du`,
    // get_syslog_stats does a full-tree scan, both block). Gated on
    // syslog_enabled the same way ssl_status_future is gated on ssl_enabled
    // above -- when the `logging` profile was never opted into,
    // SYSLOG_LOG_ROOT may not even exist, so these must stay pure no-ops
    // rather than run `du`/walk a directory that isn't there.
    let syslog_size_task = tokio::task::spawn_blocking({
        let enabled = cfg.syslog_enabled;
        let root = cfg.syslog_log_root.clone();
        move || {
            if enabled {
                syslog_client::get_syslog_size_gb(&root)
            } else {
                0.0
            }
        }
    });
    let syslog_stats_task = tokio::task::spawn_blocking({
        let enabled = cfg.syslog_enabled;
        let root = cfg.syslog_log_root.clone();
        move || {
            if enabled {
                syslog_client::get_syslog_stats(&root)
            } else {
                syslog_client::SyslogStats::default()
            }
        }
    });

    // Issue #870: per-service health/disk-usage "traffic light" data,
    // read from watchdog.sh's status.json. Same spawn_blocking shape as the
    // collectors above -- fs::metadata/fs::read_to_string are blocking calls.
    // Unconditional (no syslog_enabled-style gate): unlike the syslog store,
    // the watchdog-status volume mount is always present in
    // deploy/*/docker-compose.yml, and a missing/stale file is itself a
    // meaningful, always-worth-showing state (see watchdog_status.rs), not
    // an opt-in feature with its own disabled-by-default toggle.
    let watchdog_status_task = tokio::task::spawn_blocking({
        let path = cfg.watchdog_status_file.clone();
        move || watchdog_status::read_status(&path)
    });

    let (
        standard_status,
        distinct_ssl_status,
        cache_used_result,
        log_stats_result,
        recent_logs_result,
        syslog_size_result,
        syslog_stats_result,
        watchdog_status_result,
    ) = tokio::join!(
        standard_status_future,
        ssl_status_future,
        cache_used_task,
        log_stats_task,
        recent_logs_task,
        syslog_size_task,
        syslog_stats_task,
        watchdog_status_task,
    );
    let ssl_status = if !cfg.ssl_enabled {
        None
    } else if cfg.proxy_standard_url == cfg.proxy_ssl_url {
        standard_status.clone()
    } else {
        distinct_ssl_status
    };
    let cache_used_gb = cache_used_result.unwrap_or(0.0);
    let log_stats = log_stats_result.unwrap_or_default();
    let recent_logs = recent_logs_result.unwrap_or_default();
    let syslog_size_gb = syslog_size_result.unwrap_or(0.0);
    let syslog_stats = syslog_stats_result.unwrap_or_default();
    // A JoinError here (the blocking task panicked) is treated the same as a
    // missing/unreadable status.json -- Unavailable -- rather than failing
    // the whole dashboard render over one optional health widget.
    let watchdog_status =
        watchdog_status_result.unwrap_or(watchdog_status::WatchdogStatusReadResult::Unavailable);

    let cache_pct = cache_usage_pct(cache_used_gb, cfg.cache_max_gb);

    let mut ctx = Context::new();
    ctx.insert("ssl_enabled", &cfg.ssl_enabled);
    let dhcp_mode = cfg.effective_dhcp_mode();
    let has_kea = matches!(dhcp_mode, DhcpMode::Kea);
    ctx.insert("dhcp_mode", &dhcp_mode.as_str());
    ctx.insert("dhcp_mode_has_kea", &has_kea);
    ctx.insert("standard_status", &standard_status);
    ctx.insert("ssl_status", &ssl_status);
    ctx.insert("cache_dir", &cfg.cache_dir);
    ctx.insert("cache_used_gb", &format!("{:.1}", cache_used_gb));
    ctx.insert("cache_max_gb", &cfg.cache_max_gb);
    ctx.insert("cache_pct", &cache_pct);
    ctx.insert("log_stats", &log_stats);
    ctx.insert("recent_logs", &recent_logs);
    ctx.insert("syslog_enabled", &cfg.syslog_enabled);
    ctx.insert("syslog_size_gb", &format!("{:.1}", syslog_size_gb));
    ctx.insert("syslog_max_gb", &cfg.syslog_max_gb);
    ctx.insert("syslog_stats", &syslog_stats);
    ctx.insert("watchdog_status", &watchdog_status_json(watchdog_status));
    ctx.insert("active_page", "dashboard");

    crate::routes::render(
        &state.templates,
        "dashboard.html",
        &ctx,
        state.config.dev_mode,
    )
}

fn cache_usage_pct(used_gb: f64, max_gb: f64) -> u64 {
    if max_gb <= 0.0 {
        0
    } else {
        ((used_gb / max_gb) * 100.0).min(100.0) as u64
    }
}

// JSON counterpart to `dashboard()`'s stub_status section only (registered
// at GET /api/metrics in main.rs). Deliberately omits the cache-size and
// log-parsing work above, which is the expensive part of `dashboard()` --
// intended for cheap polling of just the connection metrics. `dashboard.html`'s
// own inline script polls this endpoint every 10s to refresh the live
// connection-count numbers without re-running the heavier work above.
pub async fn metrics_api(State(state): State<Arc<AppState>>) -> Json<serde_json::Value> {
    let cfg = &state.config;
    let standard_status =
        nginx_client::get_stub_status(&state.http_client, &cfg.proxy_standard_url).await;
    let ssl_status = if !cfg.ssl_enabled {
        None
    } else if cfg.proxy_standard_url == cfg.proxy_ssl_url {
        standard_status.clone()
    } else {
        nginx_client::get_stub_status(&state.http_client, &cfg.proxy_ssl_url).await
    };
    Json(json!({
        "standard": standard_status,
        "ssl_enabled": cfg.ssl_enabled,
        "ssl": ssl_status,
    }))
}

// Issue #870: cheap polling counterpart to the watchdog_status section of
// dashboard()'s initial render, registered at GET /api/watchdog-status.
// dashboard.html's own script polls this every 10s to keep the per-service
// health indicators and disk-usage color live without a full page reload --
// same pattern as metrics_api above, and reads the same small JSON file
// rather than re-running dashboard()'s much heavier cache-size/log-parsing
// collectors.
pub async fn watchdog_status_api(State(state): State<Arc<AppState>>) -> Json<serde_json::Value> {
    let path = state.config.watchdog_status_file.clone();
    let result = tokio::task::spawn_blocking(move || watchdog_status::read_status(&path))
        .await
        .unwrap_or(watchdog_status::WatchdogStatusReadResult::Unavailable);
    Json(watchdog_status_json(result))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::time::Duration;

    fn sample_status() -> watchdog_status::WatchdogStatus {
        let mut services = HashMap::new();
        services.insert(
            "lancache-proxy".to_string(),
            watchdog_status::ServiceHealth {
                status: "green".to_string(),
                health: "healthy".to_string(),
                failures: 0,
            },
        );
        watchdog_status::WatchdogStatus {
            updated: "2026-07-22T00:00:00Z".to_string(),
            services,
            disk: watchdog_status::DiskInfo {
                cache: watchdog_status::DiskHealth {
                    pct: 10,
                    status: "green".to_string(),
                },
            },
        }
    }

    // The dashboard template and the polling JS (dashboard.html) both branch
    // on the literal "state" string -- if this ever silently changed (e.g. a
    // typo introduced in a refactor), both would fall through to their
    // default/unknown rendering without any test failing to explain why.
    #[test]
    fn watchdog_status_json_marks_fresh_state_and_includes_services() {
        let value = watchdog_status_json(watchdog_status::WatchdogStatusReadResult::Fresh(
            sample_status(),
        ));
        assert_eq!(value["state"], "fresh");
        assert_eq!(value["services"][0]["name"], "lancache-proxy");
        assert_eq!(value["disk"]["cache"]["pct"], 10);
    }

    #[test]
    fn watchdog_status_json_marks_stale_state_and_includes_age() {
        let value = watchdog_status_json(watchdog_status::WatchdogStatusReadResult::Stale(
            sample_status(),
            Duration::from_secs(120),
        ));
        assert_eq!(value["state"], "stale");
        assert_eq!(value["age_seconds"], 120);
    }

    // Unavailable must carry no stale/misleading services/disk data at all --
    // a caller checking only `state` (as dashboard.html's JS does) must never
    // find leftover fields it could accidentally render.
    #[test]
    fn watchdog_status_json_unavailable_carries_no_service_data() {
        let value = watchdog_status_json(watchdog_status::WatchdogStatusReadResult::Unavailable);
        assert_eq!(value["state"], "unavailable");
        assert!(value.get("services").is_none());
        assert!(value.get("disk").is_none());
    }
}
