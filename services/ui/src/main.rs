// LanCache-NG (https://github.com/wiki-mod/lancache-ng)
// SPDX-License-Identifier: AGPL-3.0-or-later

// What: admin ui: settings, configs, pages, actions.
// Why: owns the settings; renders and applies configs.
// From: Issue #1683 | PR #1858

use argon2::{Argon2, PasswordHash, PasswordHasher, PasswordVerifier};
use axum::extract::{Form, Request, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::middleware::Next;
use axum::response::{Html, IntoResponse, Redirect, Response};
use axum::routing::{get, post};
use axum::Router;
use base64::Engine as _;
use lancache_ng::config::{self, process_env, Settings};
use lancache_ng::{access, apply, clock, docker, fs, human, render, secret};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, RwLock};
use std::time::Duration;
use tera::{Context, Tera};

// What: env name of the saved settings file path.
// Why: settings load needs the path before settings exist.
// From: Issue #1683 | PR #1858
const SETTINGS_FILE_ENV: &str = "LANCACHE_SETTINGS_FILE";

// What: templates compiled into the binary.
// Why: no template dir to mount or lose; one image.
// From: Issue #1683 | PR #1858
const TEMPLATES: [(&str, &str); 8] = [
    ("base.html", include_str!("templates/base.html")),
    ("dashboard.html", include_str!("templates/dashboard.html")),
    ("setup.html", include_str!("templates/setup.html")),
    ("dhcp.html", include_str!("templates/dhcp.html")),
    ("domains.html", include_str!("templates/domains.html")),
    ("stats.html", include_str!("templates/stats.html")),
    ("logs.html", include_str!("templates/logs.html")),
    (
        "cachehamster.html",
        include_str!("templates/cachehamster.html"),
    ),
];

// What: static files compiled into the binary.
// Why: served with fixed types; nothing read at runtime.
// From: Issue #1683 | PR #1858
const ADMIN_CSS: &str = include_str!("static/admin.css");
const FAVICON: &[u8] = include_bytes!("static/favicon.ico");
const LOGO: &[u8] = include_bytes!("static/logo-icon.png");

// What: name of the session cookie.
// Why: one place; the CSRF token derives from it.
// From: Issue #1683 | PR #1858
const COOKIE: &str = "lancache_session";

// What: shared state of all handlers.
// Why: settings swap atomically after a save.
// From: Issue #1683 | PR #1858
struct App {
    settings: RwLock<Settings>,
    saved: Option<PathBuf>,
    tera: Tera,
    docker: docker::Api,
    session_key: [u8; 32],
}

type Shared = State<Arc<App>>;

impl App {
    // What: current settings snapshot.
    // Why: a handler must never see half an update.
    // From: Issue #1683 | PR #1858
    fn settings(&self) -> Settings {
        self.settings.read().map(|s| s.clone()).unwrap_or_default()
    }

    // What: Docker timeout and stop grace from the SOT.
    // Why: no hard-coded wait anywhere in the ui.
    // From: Issue #1683 | PR #1858
    fn limits(&self, s: &Settings) -> Result<(u32, Duration), String> {
        let grace = u32::try_from(s.uint("WATCHDOG_STOP_GRACE")?).map_err(|e| e.to_string())?;
        Ok((grace, Duration::from_secs(s.uint("DOCKER_TIMEOUT")?)))
    }

    // What: render one page with the common context.
    // Why: every page gets csrf, menu and alarms the same way.
    // From: Issue #1683 | PR #1858
    fn page(&self, name: &str, mut ctx: Context, csrf: &str) -> Response {
        ctx.insert("csrf_token", csrf);
        ctx.insert("page", name.trim_end_matches(".html"));
        let s = self.settings();
        ctx.insert("active_page", name.trim_end_matches(".html"));
        let v: BTreeMap<String, String> = s
            .specs()
            .filter(|sp| !matches!(sp.kind, config::Kind::Secret))
            .filter_map(|sp| s.text(&sp.key).ok().map(|t| (sp.key.clone(), t)))
            .collect();
        ctx.insert("v", &v);
        ctx.insert(
            "login_enabled",
            &!s.text("UI_PASSWORD_HASH").unwrap_or_default().is_empty(),
        );
        ctx.insert("pages", &PAGES.iter().copied().collect::<BTreeMap<_, _>>());
        ctx.insert(
            "routes",
            &ROUTES.iter().copied().collect::<BTreeMap<_, _>>(),
        );
        ctx.insert("repo_url", &s.text("REPO_URL").unwrap_or_default());
        ctx.insert("desired_services", &s.list("UI_CONTROLLABLE_SERVICES"));
        ctx.insert(
            "watchdog_refresh_seconds",
            &s.uint("UI_STATUS_REFRESH").unwrap_or(1),
        );
        match self.tera.render(name, &ctx) {
            Ok(html) => Html(html).into_response(),
            Err(e) => {
                eprintln!("ui: template {name}: {e}");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "template error, see the log",
                )
                    .into_response()
            }
        }
    }
}

// What: CSRF token bound to the session cookie.
// Why: a foreign site cannot read the cookie value.
// From: Issue #1683 | PR #1858
fn csrf_of(key: &[u8; 32], session: &str) -> String {
    let mut h = Sha256::new();
    h.update(key);
    h.update(session.as_bytes());
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

// What: session cookie value from the request.
// Why: CSRF and login state read it.
// From: Issue #1683 | PR #1858
fn cookie(headers: &HeaderMap) -> Option<String> {
    headers
        .get_all(header::COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(';'))
        .filter_map(|p| p.trim().split_once('='))
        .find(|(k, _)| *k == COOKIE)
        .map(|(_, v)| v.to_string())
}

// What: Basic auth when a password hash is set.
// Why: test stack runs without; production sets one.
// From: Issue #1683 | PR #1858
async fn auth(State(app): Shared, mut req: Request, next: Next) -> Response {
    let s = app.settings();
    let hash = s.text("UI_PASSWORD_HASH").unwrap_or_default();
    if !hash.is_empty() {
        let user = s.text("UI_USER").unwrap_or_default();
        let given = req
            .headers()
            .get(header::AUTHORIZATION)
            .and_then(|h| h.to_str().ok())
            .and_then(|h| h.strip_prefix("Basic "))
            .and_then(|e| base64::engine::general_purpose::STANDARD.decode(e).ok())
            .and_then(|d| String::from_utf8(d).ok());
        let ok = match given.as_deref().and_then(|c| c.split_once(':')) {
            Some((u, p)) => {
                let (p, hash) = (p.to_string(), hash.clone());
                let pass = tokio::task::spawn_blocking(move || verify(&hash, &p))
                    .await
                    .unwrap_or(false);
                pass & secret::equal(u.as_bytes(), user.as_bytes())
            }
            None => false,
        };
        if !ok {
            return (
                StatusCode::UNAUTHORIZED,
                [(header::WWW_AUTHENTICATE, "Basic realm=\"LanCache Admin\"")],
                "Unauthorized",
            )
                .into_response();
        }
    }
    let (session, fresh) = match cookie(req.headers()) {
        Some(c) => (c, false),
        None => (secret::random_hex(32), true),
    };
    req.extensions_mut()
        .insert(Csrf(csrf_of(&app.session_key, &session)));
    let mut res = next.run(req).await;
    if fresh {
        let v = format!("{COOKIE}={session}; HttpOnly; SameSite=Strict; Path=/");
        if let Ok(v) = v.parse() {
            res.headers_mut().append(header::SET_COOKIE, v);
        }
    }
    res
}

// What: CSRF token of this request.
// Why: handlers read it from the request extensions.
// From: Issue #1683 | PR #1858
#[derive(Clone)]
struct Csrf(String);

// What: form check: CSRF token must match.
// Why: every POST changes state; no token, no change.
// From: Issue #1683 | PR #1858
fn csrf_ok(form: &BTreeMap<String, String>, csrf: &Csrf) -> bool {
    form.get("csrf_token")
        .is_some_and(|t| secret::equal(t.as_bytes(), csrf.0.as_bytes()))
}

// What: dashboard: alarms and container states.
// Why: first page; shows what needs attention.
// From: Issue #1683 | PR #1858
async fn dashboard(State(app): Shared, axum::Extension(csrf): axum::Extension<Csrf>) -> Response {
    let s = app.settings();
    let mut ctx = Context::new();
    let alarms = s
        .text("WATCHDOG_ALARM_FILE")
        .ok()
        .and_then(|p| std::fs::read(p).ok())
        .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok())
        .unwrap_or_default();
    ctx.insert("alarms", &alarms);
    let containers = match (app.limits(&s), s.text("COMPOSE_PROJECT")) {
        (Ok((_, limit)), Ok(project)) => app
            .docker
            .project(&project, limit)
            .await
            .unwrap_or_default(),
        _ => Vec::new(),
    };
    ctx.insert("containers", &containers);
    let logs = PathBuf::from(s.text("SYSLOG_LOG_ROOT").unwrap_or_default())
        .join(s.text("PROXY_LOG_PROGRAM").unwrap_or_default());
    let (limit, chunk) = (
        s.uint("UI_RECENT_REQUESTS").unwrap_or(0),
        s.uint("UI_LOG_TAIL_CHUNK").unwrap_or(0),
    );
    let (stats, recent) = tokio::task::spawn_blocking(move || {
        let n = usize::try_from(limit).unwrap_or(0);
        (access::stats(&logs), access::tail(&logs, n, chunk))
    })
    .await
    .unwrap_or_default();
    let mut st = serde_json::to_value(&stats).unwrap_or_default();
    st["total_bytes_human"] = human::bytes(stats.total_bytes).into();
    ctx.insert("log_stats", &st);
    let recent: Vec<serde_json::Value> = recent
        .iter()
        .rev()
        .map(|e| {
            let mut v = serde_json::to_value(e).unwrap_or_default();
            v["bytes_human"] = human::bytes(e.bytes).into();
            v
        })
        .collect();
    ctx.insert("recent_logs", &recent);
    if let Ok(space) = s
        .text("NGINX_CACHE_DIR")
        .and_then(|d| fs::space(std::path::Path::new(&d)).map_err(|e| e.to_string()))
    {
        let used = space.total.saturating_sub(space.free);
        ctx.insert("cache_used_human", &human::bytes(used));
        ctx.insert(
            "cache_pct",
            &(used.saturating_mul(100) / space.total.max(1)),
        );
    }
    ctx.insert("warnings", &s.warnings);
    app.page("dashboard.html", ctx, &csrf.0)
}

// What: General page: channel, updates, NTP, login.
// Why: design page; fields are SOT keys (v.KEY).
// From: Issue #1683 | PR #1858
async fn setup(State(app): Shared, axum::Extension(csrf): axum::Extension<Csrf>) -> Response {
    let s = app.settings();
    let mut ctx = Context::new();
    let on = s.flag("NTP_ENABLED").unwrap_or(false);
    let answers = match (
        on,
        s.text("IP_HTTP"),
        s.uint("NTP_PORT"),
        s.uint("NTP_PROBE_WAIT_MS"),
    ) {
        (true, Ok(ip), Ok(port), Ok(ms)) => tokio::task::spawn_blocking(move || {
            lancache_ng::ntp::answers(&ip, port, Duration::from_millis(ms))
        })
        .await
        .unwrap_or(false),
        _ => false,
    };
    ctx.insert("ntp_answers", &answers);
    app.page("setup.html", ctx, &csrf.0)
}

// What: change the ui password (Argon2id hash).
// Why: only the hash is stored; current one must match.
// From: Issue #1683 | PR #1858
async fn password(
    State(app): Shared,
    axum::Extension(csrf): axum::Extension<Csrf>,
    Form(form): Form<BTreeMap<String, String>>,
) -> Response {
    if !csrf_ok(&form, &csrf) {
        return (StatusCode::FORBIDDEN, "CSRF token mismatch").into_response();
    }
    let field = |k: &str| form.get(k).cloned().unwrap_or_default();
    let (cur, new, again) = (
        field("current_password"),
        field("new_password"),
        field("confirm_password"),
    );
    if new != again {
        return (StatusCode::BAD_REQUEST, "the two new passwords differ").into_response();
    }
    let s = app.settings();
    let min = s.uint("UI_PASSWORD_MIN_LENGTH").unwrap_or(u64::MAX);
    if u64::try_from(new.chars().count()).unwrap_or(0) < min {
        return (
            StatusCode::BAD_REQUEST,
            format!("the password needs at least {min} characters"),
        )
            .into_response();
    }
    let old = s.text("UI_PASSWORD_HASH").unwrap_or_default();
    let hashed = tokio::task::spawn_blocking(move || {
        if !old.is_empty() && !verify(&old, &cur) {
            return Err("the current password is wrong".to_string());
        }
        phc(&new)
    })
    .await
    .unwrap_or_else(|e| Err(e.to_string()));
    let hash = match hashed {
        Ok(h) => h,
        Err(e) => return (StatusCode::BAD_REQUEST, e).into_response(),
    };
    let update = BTreeMap::from([("UI_PASSWORD_HASH".to_string(), hash)]);
    done(commit(&app, update).await, "/setup")
}

// What: save, reload, render, write and apply.
// Why: one path for every setting change in the ui.
// From: Issue #1683 | PR #1858
async fn commit(app: &App, form: BTreeMap<String, String>) -> Result<(), String> {
    let path = app
        .saved
        .clone()
        .ok_or_else(|| format!("{SETTINGS_FILE_ENV} is not set"))?;
    let old = app.settings();
    let updates: BTreeMap<String, String> = form
        .into_iter()
        .filter(|(k, v)| {
            old.spec(k).is_some_and(|sp| {
                let secret = matches!(sp.kind, config::Kind::Secret);
                !(secret && v.is_empty()) && old.text(k).ok().as_deref() != Some(v.as_str())
            })
        })
        .collect();
    if updates.is_empty() {
        return Ok(());
    }
    config::store(&path, &old, &updates)?;
    let new = Settings::load(&process_env, Some(&path))?;
    let report = apply_all(app, &old, &new).await?;
    if let Ok(mut s) = app.settings.write() {
        *s = new;
    }
    for line in &report {
        eprintln!("ui: apply: {line}");
    }
    Ok(())
}

// What: answer a commit with a redirect or the error.
// Why: every form handler ends the same way.
// From: Issue #1683 | PR #1858
fn done(result: Result<(), String>, back: &str) -> Response {
    match result {
        Ok(()) => Redirect::to(back).into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, e).into_response(),
    }
}

// What: General page form: save changed SOT keys.
// Why: field names are the keys themselves.
// From: Issue #1683 | PR #1858
async fn save(
    State(app): Shared,
    axum::Extension(csrf): axum::Extension<Csrf>,
    Form(form): Form<BTreeMap<String, String>>,
) -> Response {
    if !csrf_ok(&form, &csrf) {
        return (StatusCode::FORBIDDEN, "CSRF token mismatch").into_response();
    }
    done(commit(&app, form).await, "/setup")
}

// What: logs page: newest lines of every program.
// Why: reads the syslog-ng store, one folder per program.
// From: Issue #1683 | PR #1858
async fn logs(State(app): Shared, axum::Extension(csrf): axum::Extension<Csrf>) -> Response {
    let s = app.settings();
    let root = PathBuf::from(s.text("SYSLOG_LOG_ROOT").unwrap_or_default());
    let max = usize::try_from(s.uint("UI_LOG_LINES").unwrap_or(0)).unwrap_or(0);
    let chunk = s.uint("UI_LOG_TAIL_CHUNK").unwrap_or(0);
    let programs = s.list("SYSLOG_PROGRAMS");
    let muted = s.list("SYSLOG_MUTED");
    let progs = programs.clone();
    let lines = tokio::task::spawn_blocking(move || {
        let mut all: Vec<(String, String)> = Vec::new();
        for p in &progs {
            for l in access::tail_lines(&root.join(p), max, chunk) {
                all.push((p.clone(), l));
            }
        }
        all.sort_by(|a, b| b.1.cmp(&a.1));
        all.truncate(max);
        all
    })
    .await
    .unwrap_or_default();
    let entries: Vec<serde_json::Value> = lines
        .iter()
        .map(|(p, l)| {
            let (ts, msg) = l.split_once(' ').unwrap_or(("", l));
            serde_json::json!({"host": p, "timestamp": ts, "message": msg})
        })
        .collect();
    let switches: Vec<serde_json::Value> = programs
        .iter()
        .map(|p| serde_json::json!({"program": p, "on": !muted.contains(p)}))
        .collect();
    let mut ctx = Context::new();
    ctx.insert("syslog_logs", &entries);
    ctx.insert("syslog_hosts", &programs);
    ctx.insert("log_switches", &switches);
    ctx.insert("logs_max_entries", &max);
    app.page("logs.html", ctx, &csrf.0)
}

// What: save forward targets and muted programs.
// Why: switches arrive as on_<program>; rest is muted.
// From: Issue #1683 | PR #1858
async fn logs_save(
    State(app): Shared,
    axum::Extension(csrf): axum::Extension<Csrf>,
    Form(form): Form<BTreeMap<String, String>>,
) -> Response {
    if !csrf_ok(&form, &csrf) {
        return (StatusCode::FORBIDDEN, "CSRF token mismatch").into_response();
    }
    let s = app.settings();
    let muted: Vec<String> = s
        .list("SYSLOG_PROGRAMS")
        .into_iter()
        .filter(|p| form.get(&format!("on_{p}")).map(String::as_str) != Some("true"))
        .collect();
    let mut updates = BTreeMap::new();
    updates.insert("SYSLOG_MUTED".to_string(), muted.join(" "));
    updates.insert(
        "SYSLOG_FORWARD".to_string(),
        form.get("SYSLOG_FORWARD")
            .cloned()
            .unwrap_or_default()
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" "),
    );
    done(commit(&app, updates).await, "/logs#syslog")
}

// What: PowerDNS API client of this node.
// Why: records go to PowerDNS directly; no own store.
// From: Issue #1683 | PR #1858
fn pdns_api(s: &Settings) -> Result<lancache_ng::pdns::Api, String> {
    let key = secrets(s)?.pdns_api_key;
    let client = lancache_ng::http::client(s)?;
    Ok(lancache_ng::pdns::Api::new(
        client,
        &s.text("PDNS_PRIMARY_API_URL")?,
        &key,
    ))
}

// What: reverse name of an IPv4 or IPv6 address.
// Why: PTR records live under in-addr.arpa / ip6.arpa.
// From: Issue #1683 | PR #1858
fn reverse_name(ip: &str) -> Result<String, String> {
    match ip
        .parse::<std::net::IpAddr>()
        .map_err(|_| format!("{ip:?} is no IP address"))?
    {
        std::net::IpAddr::V4(v4) => {
            let o = v4.octets();
            Ok(format!("{}.{}.{}.{}.in-addr.arpa.", o[3], o[2], o[1], o[0]))
        }
        std::net::IpAddr::V6(v6) => {
            let hex: String = v6.octets().iter().map(|b| format!("{b:02x}")).collect();
            let nibbles: Vec<String> = hex.chars().rev().map(String::from).collect();
            Ok(format!("{}.ip6.arpa.", nibbles.join(".")))
        }
    }
}

// What: reverse zone that holds a reverse name.
// Why: PowerDNS needs the zone for the PATCH.
// From: Issue #1683 | PR #1858
fn reverse_zone(name: &str) -> Option<String> {
    lancache_ng::dns::private_reverse_zones()
        .into_iter()
        .filter(|z| name.ends_with(z.as_str()))
        .max_by_key(String::len)
}

// What: DNS page: domains, LAN records, PTR, switches.
// Why: records are read live from PowerDNS.
// From: Issue #1683 | PR #1858
async fn domains(State(app): Shared, axum::Extension(csrf): axum::Extension<Csrf>) -> Response {
    let s = app.settings();
    let mut ctx = Context::new();
    ctx.insert(
        "dns_domains",
        &lancache_ng::cdn::rows(&s).unwrap_or_default(),
    );
    let lan = lancache_ng::dns::canonical_zone(&s.text("DNS_LAN_ZONE").unwrap_or_default());
    ctx.insert("lan_zone", lan.trim_end_matches('.'));
    let (mut lan_records, mut ptr) = (Vec::new(), Vec::new());
    match pdns_api(&s) {
        Ok(api) => {
            lan_records = api.rrsets(&lan).await.unwrap_or_default();
            for z in lancache_ng::dns::private_reverse_zones() {
                for r in api.rrsets(&z).await.unwrap_or_default() {
                    if r["type"] == "PTR" {
                        ptr.push(serde_json::json!({
                            "ip": r["name"], "ttl": r["ttl"],
                            "hostname": r["records"][0]["content"],
                        }));
                    }
                }
            }
        }
        Err(e) => ctx.insert("domain_error_message", &e),
    }
    ctx.insert("lan_records", &lan_records);
    let groups: Vec<serde_json::Value> = snapshot_zones(&s)
        .iter()
        .filter_map(|z| {
            let ids = zone_store(&s, z).ok()?.list().ok()?;
            (!ids.is_empty()).then(|| {
                let snaps: Vec<serde_json::Value> = ids
                    .iter()
                    .map(|id| {
                        let secs = id.parse::<u128>().unwrap_or(0) / 1_000_000_000;
                        serde_json::json!({"id": id, "created_unix": secs.to_string()})
                    })
                    .collect();
                serde_json::json!({"zone": z, "snapshots": snaps})
            })
        })
        .collect();
    ctx.insert("zone_snapshot_groups", &groups);
    ctx.insert("rollback_zones", &snapshot_zones(&s));
    let list: Vec<serde_json::Value> = secondaries(&s)
        .iter()
        .map(|(n, a)| serde_json::json!({"name": n, "address": a}))
        .collect();
    ctx.insert("secondaries", &list);
    ctx.insert(
        "registration_token",
        &registration_token(&s).unwrap_or_default(),
    );
    ctx.insert(
        "setup_script_url",
        &s.text("SETUP_SCRIPT_URL").unwrap_or_default(),
    );
    ctx.insert("primary_ip", &s.text("IP_HTTP").unwrap_or_default());
    ctx.insert("primary_url", &s.text("UI_PUBLIC_URL").unwrap_or_default());
    ctx.insert(
        "zone_snapshot_retention",
        &s.uint("DNS_SNAPSHOT_KEEP").unwrap_or(0),
    );
    ctx.insert("ptr_records", &ptr);
    ctx.insert("lan_record_types", &s.list("DNS_LAN_RECORD_TYPES"));
    ctx.insert("record_ttl_default", &s.uint("DNS_RECORD_TTL").unwrap_or(0));
    ctx.insert("ttl_max", &s.uint("DNS_RECORD_TTL_MAX").unwrap_or(0));
    ctx.insert(
        "aaaa_filter_enabled",
        &s.flag("DNS_FILTER_AAAA").unwrap_or(false),
    );
    ctx.insert(
        "ddns_unsigned_updates_allowed",
        &s.flag("DDNS_ALLOW_UNSIGNED").unwrap_or(false),
    );
    ctx.insert("ddns_tsig_key_configured", &secrets(&s).is_ok());
    app.page("domains.html", ctx, &csrf.0)
}

// What: one DNS page form action.
// Why: every DNS form posts here with "op".
// From: Issue #1683 | PR #1858
async fn dns_action(
    State(app): Shared,
    axum::Extension(csrf): axum::Extension<Csrf>,
    axum::extract::Path(op): axum::extract::Path<String>,
    Form(f): Form<BTreeMap<String, String>>,
) -> Response {
    if !csrf_ok(&f, &csrf) {
        return (StatusCode::FORBIDDEN, "CSRF token mismatch").into_response();
    }
    let s = app.settings();
    let get = |k: &str| f.get(k).map(|v| v.trim().to_string()).unwrap_or_default();
    let on = get("enabled") == "1" || get("enabled") == "true";
    let list_with = |key: &str, item: &str, add: bool| {
        let mut l = s.list(key);
        l.retain(|x| x != item);
        if add {
            l.push(item.to_string());
        }
        BTreeMap::from([(key.to_string(), l.join(" "))])
    };
    let result = match op.as_str() {
        "domain-add" => {
            let d = get("domain").to_ascii_lowercase();
            if lancache_ng::dns::cdn_entry(&d).is_none() {
                Err(format!("{d:?} is no valid domain entry"))
            } else {
                commit(&app, list_with("CDN_CUSTOM_DOMAINS", &d, true)).await
            }
        }
        "domain-remove" => {
            commit(&app, list_with("CDN_CUSTOM_DOMAINS", &get("domain"), false)).await
        }
        "domain-toggle" => {
            commit(&app, list_with("CDN_DISABLED_DOMAINS", &get("domain"), !on)).await
        }
        "aaaa-filter" => {
            commit(
                &app,
                BTreeMap::from([("DNS_FILTER_AAAA".into(), on.to_string())]),
            )
            .await
        }
        "ddns-unsigned" => {
            commit(
                &app,
                BTreeMap::from([("DDNS_ALLOW_UNSIGNED".into(), on.to_string())]),
            )
            .await
        }
        "record-add" | "record-remove" => record(&s, &op, &get).await,
        "ptr-add" | "ptr-remove" => ptr(&s, &op, &get).await,
        "zone-rollback" => rollback(&s, &get).await,
        _ => Err(format!("unknown DNS action {op}")),
    };
    done(result, "/domains")
}

// What: snapshot store of one zone.
// Why: rollback after a bad change; size from the SOT.
// From: Issue #1683 | PR #1858
fn zone_store(s: &Settings, zone: &str) -> Result<lancache_ng::snapshot::Store, String> {
    Ok(lancache_ng::snapshot::Store {
        dir: PathBuf::from(s.text("DNS_SNAPSHOT_DIR")?).join(zone.trim_end_matches('.')),
        keep: usize::try_from(s.uint("DNS_SNAPSHOT_KEEP")?).map_err(|e| e.to_string())?,
        owner: fs::Owner {
            uid: None,
            gid: None,
        },
    })
}

// What: save the zone's RRsets after a change.
// Why: every change can be rolled back later.
// From: Issue #1683 | PR #1858
async fn snapshot(s: &Settings, api: &lancache_ng::pdns::Api, zone: &str) -> Result<(), String> {
    let body = serde_json::to_vec(&api.rrsets(zone).await?).map_err(|e| e.to_string())?;
    let store = zone_store(s, zone)?;
    std::fs::create_dir_all(&store.dir).map_err(|e| format!("{}: {e}", store.dir.display()))?;
    store.save(&body).map(drop)
}

// What: roll a zone back to one snapshot.
// Why: PATCH restores RRsets; PowerDNS sends NOTIFY.
// From: Issue #1683 | PR #1858
async fn rollback(s: &Settings, get: &dyn Fn(&str) -> String) -> Result<(), String> {
    let zone = get("zone");
    if !snapshot_zones(s).contains(&zone) {
        return Err(format!("zone {zone} has no snapshots"));
    }
    let body = zone_store(s, &zone)?.read(&get("snapshot_id"))?;
    let saved: Vec<serde_json::Value> = serde_json::from_slice(&body).map_err(|e| e.to_string())?;
    pdns_api(s)?.restore(&zone, &saved).await
}

// What: zones that keep snapshots.
// Why: LAN zone and the private reverse zones.
// From: Issue #1683 | PR #1858
fn snapshot_zones(s: &Settings) -> Vec<String> {
    let mut z = vec![lancache_ng::dns::canonical_zone(
        &s.text("DNS_LAN_ZONE").unwrap_or_default(),
    )];
    z.extend(lancache_ng::dns::private_reverse_zones());
    z
}

// What: add or remove one LAN record set.
// Why: PATCH replaces or deletes; PowerDNS sends NOTIFY.
// From: Issue #1683 | PR #1858
async fn record(s: &Settings, op: &str, get: &dyn Fn(&str) -> String) -> Result<(), String> {
    let api = pdns_api(s)?;
    let zone = lancache_ng::dns::canonical_zone(&s.text("DNS_LAN_ZONE")?);
    let (name, kind) = (get("name"), get("record_type"));
    if !s.list("DNS_LAN_RECORD_TYPES").contains(&kind) {
        return Err(format!("record type {kind} is not allowed"));
    }
    let fqdn = if name.ends_with('.') || name.ends_with(zone.trim_end_matches('.')) {
        name
    } else {
        format!("{name}.{zone}")
    };
    let contents: Vec<String> = if op == "record-add" {
        get("content")
            .split(';')
            .map(str::trim)
            .filter(|c| !c.is_empty())
            .map(String::from)
            .collect()
    } else {
        Vec::new()
    };
    let ttl: u32 = get("ttl").parse().unwrap_or(0);
    let max = s.uint("DNS_RECORD_TTL_MAX")?;
    if op == "record-add" && (ttl == 0 || u64::from(ttl) > max) {
        return Err(format!("TTL must be 1..={max}"));
    }
    api.set_rrset(&zone, &fqdn, &kind, ttl, &contents).await?;
    snapshot(s, &api, &zone).await
}

// What: add or remove one PTR record.
// Why: name from the IP; zone from the private list.
// From: Issue #1683 | PR #1858
async fn ptr(s: &Settings, op: &str, get: &dyn Fn(&str) -> String) -> Result<(), String> {
    let api = pdns_api(s)?;
    let ip = get("ip");
    let name = if ip.ends_with(".arpa.") {
        ip
    } else {
        reverse_name(&ip)?
    };
    let zone =
        reverse_zone(&name).ok_or_else(|| format!("{name} is in no private reverse zone"))?;
    let ttl = u32::try_from(s.uint("DNS_RECORD_TTL")?).map_err(|e| e.to_string())?;
    let contents = if op == "ptr-add" {
        let host = get("hostname");
        vec![if host.ends_with('.') {
            host
        } else {
            format!("{host}.")
        }]
    } else {
        Vec::new()
    };
    api.set_rrset(&zone, &name, "PTR", ttl, &contents).await?;
    snapshot(s, &api, &zone).await
}

// What: registration token for secondaries.
// Why: stored like every secret; rotate replaces it.
// From: Issue #1683 | PR #1858
fn registration_token(s: &Settings) -> Result<String, String> {
    let dir = PathBuf::from(s.text("SECRETS_DIR")?);
    let keep = fs::Owner {
        uid: None,
        gid: None,
    };
    secret::resolve(None, &dir, "SECONDARY_REGISTRATION_TOKEN", keep).map_err(|e| e.to_string())
}

// What: secondaries as (name, address) pairs.
// Why: one SOT list "name@ip" drives pdns and the ui.
// From: Issue #1683 | PR #1858
fn secondaries(s: &Settings) -> Vec<(String, String)> {
    s.list("DNS_SECONDARIES")
        .iter()
        .filter_map(|e| {
            e.split_once('@')
                .map(|(n, a)| (n.to_string(), a.to_string()))
        })
        .collect()
}

// What: store the list after a change.
// Why: pdns.conf and NOTIFY follow on the next apply.
// From: Issue #1683 | PR #1858
async fn store_secondaries(app: &App, list: &[(String, String)]) -> Result<(), String> {
    let v: Vec<String> = list.iter().map(|(n, a)| format!("{n}@{a}")).collect();
    commit(
        app,
        BTreeMap::from([("DNS_SECONDARIES".to_string(), v.join(" "))]),
    )
    .await
}

// What: request body of a secondary registration.
// Why: token proves the admin handed out the command.
// From: Issue #1683 | PR #1858
#[derive(serde::Deserialize)]
struct Register {
    token: String,
    name: String,
    address: String,
}

// What: register a secondary (public, token checked).
// Why: answer carries all a secondary needs to follow.
// From: Issue #1683 | PR #1858
async fn register(State(app): Shared, axum::Json(r): axum::Json<Register>) -> Response {
    let s = app.settings();
    let Ok(token) = registration_token(&s) else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    if !secret::equal(r.token.as_bytes(), token.as_bytes()) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let name_ok = !r.name.is_empty()
        && r.name.len() <= 32
        && r.name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-');
    if !name_ok || r.address.parse::<std::net::IpAddr>().is_err() {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let mut list = secondaries(&s);
    list.retain(|(n, _)| n != &r.name);
    list.push((r.name.clone(), r.address.clone()));
    if let Err(e) = store_secondaries(&app, &list).await {
        eprintln!("ui: register {}: {e}", r.name);
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }
    let sec = match secrets(&s) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("ui: register {}: {e}", r.name);
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    };
    let zones = snapshot_zones(&s);
    axum::Json(serde_json::json!({
        "primary": s.text("IP_HTTP").unwrap_or_default(),
        "zones": zones,
        "pdns_api_key": sec.pdns_api_key,
        "tsig_name": sec.tsig_name,
        "tsig_secret": sec.tsig_secret,
        "syslog_primary": format!("{}:{}", s.text("IP_HTTP").unwrap_or_default(), s.uint("LANCACHE_LOG_PORT").unwrap_or(0)),
    }))
    .into_response()
}

// What: JSON body with a new address.
// Why: the edit dialog posts {"address": "..."}.
// From: Issue #1683 | PR #1858
#[derive(serde::Deserialize)]
struct Address {
    address: String,
}

// What: secondary actions from the DNS page.
// Why: rotate, remove, address and health in one place.
// From: Issue #1683 | PR #1858
async fn secondary_action(
    State(app): Shared,
    axum::Extension(csrf): axum::Extension<Csrf>,
    axum::extract::Path((name, op)): axum::extract::Path<(String, String)>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Response {
    if !header_csrf_ok(&headers, &csrf) {
        return (StatusCode::FORBIDDEN, "CSRF token mismatch").into_response();
    }
    let s = app.settings();
    let mut list = secondaries(&s);
    let Some(pos) = list.iter().position(|(n, _)| *n == name) else {
        return (StatusCode::NOT_FOUND, "no such secondary").into_response();
    };
    match op.as_str() {
        "remove" => {
            list.remove(pos);
            done(store_secondaries(&app, &list).await, "/domains")
        }
        "rotate" => {
            let dir = PathBuf::from(s.text("SECRETS_DIR").unwrap_or_default());
            let file = secret::file_of(&dir, "SECONDARY_REGISTRATION_TOKEN");
            match std::fs::remove_file(&file) {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
                    return (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        format!("{}: {e}", file.display()),
                    )
                        .into_response();
                }
                _ => {}
            }
            match registration_token(&s) {
                Ok(t) => axum::Json(serde_json::json!({"token": t})).into_response(),
                Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e).into_response(),
            }
        }
        "address" => {
            let Ok(a) = serde_json::from_slice::<Address>(&body) else {
                return (StatusCode::BAD_REQUEST, "body must be {\"address\": ...}")
                    .into_response();
            };
            if a.address.parse::<std::net::IpAddr>().is_err() {
                return (StatusCode::BAD_REQUEST, "no IP address").into_response();
            }
            list[pos].1 = a.address;
            match store_secondaries(&app, &list).await {
                Ok(()) => StatusCode::NO_CONTENT.into_response(),
                Err(e) => (StatusCode::BAD_REQUEST, e).into_response(),
            }
        }
        "health" => axum::Json(secondary_health(&s, &list[pos].1).await).into_response(),
        _ => (StatusCode::NOT_FOUND, "unknown action").into_response(),
    }
}

// What: compare LAN zone serial primary vs secondary.
// Why: shows a lost NOTIFY or broken AXFR (RFC 1982).
// From: Issue #1683 | PR #1858
async fn secondary_health(s: &Settings, address: &str) -> serde_json::Value {
    let zone = lancache_ng::dns::canonical_zone(&s.text("DNS_LAN_ZONE").unwrap_or_default());
    let (Ok(primary), Ok(sec), Ok(port), Ok(client)) = (
        pdns_api(s),
        secrets(s),
        s.uint("PDNS_AUTH_API_PORT"),
        lancache_ng::http::client(s),
    ) else {
        return serde_json::json!({"status": "error", "detail": "settings incomplete"});
    };
    let remote = lancache_ng::pdns::Api::new(
        client,
        &format!("http://{address}:{port}/api/v1/servers/localhost"),
        &sec.pdns_api_key,
    );
    let serial = |zs: Vec<lancache_ng::pdns::Zone>| {
        zs.into_iter().find(|z| z.name == zone).map(|z| z.serial)
    };
    match (
        primary.zones().await.map(serial),
        remote.zones().await.map(serial),
    ) {
        (Ok(Some(p)), Ok(Some(r))) => {
            let state = lancache_ng::dns::sync_state(p, r);
            serde_json::json!({"status": format!("{state:?}"), "serial": r})
        }
        (Ok(_), Ok(None)) => {
            serde_json::json!({"status": "missing", "detail": "zone not on secondary"})
        }
        (Err(e), _) | (_, Err(e)) => serde_json::json!({"status": "unreachable", "detail": e}),
        _ => serde_json::json!({"status": "error"}),
    }
}

// What: Kea control agent client of this stack.
// Why: subnets, reservations and leases live in Kea.
// From: Issue #1683 | PR #1858
fn kea_api(s: &Settings) -> Result<lancache_ng::kea::Api, String> {
    Ok(lancache_ng::kea::Api::new(
        lancache_ng::http::client(s)?,
        &s.text("KEA_CTRL_URL")?,
    ))
}

// What: one Kea subnet as template row.
// Why: the page shows flat fields, Kea keeps option-data.
// From: Issue #1683 | PR #1858
fn subnet_row(sn: &serde_json::Value) -> serde_json::Value {
    let opt = |name: &str| {
        sn["option-data"]
            .as_array()
            .and_then(|a| a.iter().find(|o| o["name"] == name))
            .and_then(|o| o["data"].as_str())
            .unwrap_or_default()
            .to_string()
    };
    let dns: Vec<String> = opt("domain-name-servers")
        .split(',')
        .map(|x| x.trim().to_string())
        .collect();
    let pool = sn["pools"][0]["pool"].as_str().unwrap_or_default();
    let (start, end) = pool
        .split_once('-')
        .map(|(a, b)| (a.trim(), b.trim()))
        .unwrap_or(("", ""));
    let custom: Vec<serde_json::Value> = sn["option-data"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter(|o| o.get("code").is_some() && o.get("name").is_none())
                .cloned()
                .collect()
        })
        .unwrap_or_default();
    serde_json::json!({
        "id": sn["id"], "subnet": sn["subnet"], "gateway": opt("routers"),
        "dns_primary": dns.first().cloned().unwrap_or_default(),
        "dns_secondary": dns.get(1).cloned().unwrap_or_default(),
        "ntp_servers": opt("ntp-servers"), "pool_start": start, "pool_end": end,
        "lease_time": sn["valid-lifetime"], "custom_options": custom,
    })
}

// What: DHCP page: mode, proxy/relay, Kea data.
// Why: Kea data is read live; nothing is cached.
// From: Issue #1683 | PR #1858
async fn dhcp(State(app): Shared, axum::Extension(csrf): axum::Extension<Csrf>) -> Response {
    let s = app.settings();
    let mut ctx = Context::new();
    let mode = s.text("DHCP_MODE").unwrap_or_default();
    ctx.insert("dhcp_mode", &mode);
    ctx.insert(
        "dhcp_modes",
        &["off", "kea", "dnsmasq-proxy", "dnsmasq-relay"],
    );
    ctx.insert("dhcp_has_kea", &(mode == "kea"));
    ctx.insert("dhcp_is_dnsmasq", &mode.starts_with("dnsmasq"));
    ctx.insert("dhcp_is_relay", &(mode == "dnsmasq-relay"));
    ctx.insert("dhcp_ddns_enabled", &s.flag("DHCP_DDNS").unwrap_or(false));
    let (mut subnets, mut reservations, mut leases) = (Vec::new(), Vec::new(), Vec::new());
    if mode == "kea" {
        match kea_api(&s) {
            Ok(api) => {
                if let Ok(cfg) = api.config().await {
                    for sn in cfg["Dhcp4"]["subnet4"]
                        .as_array()
                        .cloned()
                        .unwrap_or_default()
                    {
                        for r in sn["reservations"].as_array().cloned().unwrap_or_default() {
                            reservations.push(serde_json::json!({
                                "subnet_id": sn["id"], "mac": r["hw-address"],
                                "ip": r["ip-address"], "hostname": r["hostname"],
                            }));
                        }
                        subnets.push(subnet_row(&sn));
                    }
                }
                for l in api.leases().await.unwrap_or_default() {
                    let end =
                        l["cltt"].as_u64().unwrap_or(0) + l["valid-lft"].as_u64().unwrap_or(0);
                    leases.push(serde_json::json!({
                        "ip": l["ip-address"], "mac": l["hw-address"], "hostname": l["hostname"],
                        "subnet_id": l["subnet-id"], "expires": end.to_string(),
                    }));
                }
            }
            Err(e) => ctx.insert("hint", &e),
        }
    }
    ctx.insert("subnets", &subnets);
    ctx.insert("reservations", &reservations);
    ctx.insert("leases", &leases);
    let snaps: Vec<serde_json::Value> = kea_store(&s)
        .and_then(|st| st.list())
        .unwrap_or_default()
        .iter()
        .map(|id| {
            let secs = id.parse::<u128>().unwrap_or(0) / 1_000_000_000;
            serde_json::json!({"id": id, "created_unix": secs.to_string()})
        })
        .collect();
    ctx.insert("kea_snapshots", &snaps);
    app.page("dhcp.html", ctx, &csrf.0)
}

// What: snapshot store of the Kea config.
// Why: every subnet change can be rolled back.
// From: Issue #1683 | PR #1858
fn kea_store(s: &Settings) -> Result<lancache_ng::snapshot::Store, String> {
    Ok(lancache_ng::snapshot::Store {
        dir: PathBuf::from(s.text("KEA_SNAPSHOT_DIR")?),
        keep: usize::try_from(s.uint("KEA_SNAPSHOT_KEEP")?).map_err(|e| e.to_string())?,
        owner: fs::Owner {
            uid: None,
            gid: None,
        },
    })
}

// What: change the Kea config with a function.
// Why: get, edit, set, write, snapshot; one path.
// From: Issue #1683 | PR #1858
async fn kea_edit(
    s: &Settings,
    edit: impl FnOnce(&mut Vec<serde_json::Value>) -> Result<(), String>,
) -> Result<(), String> {
    let api = kea_api(s)?;
    let mut cfg = api.config().await?;
    cfg.as_object_mut().map(|o| o.remove("hash"));
    let mut subnets = cfg["Dhcp4"]["subnet4"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    edit(&mut subnets)?;
    cfg["Dhcp4"]["subnet4"] = serde_json::Value::Array(subnets);
    api.set_config(cfg.clone()).await?;
    let store = kea_store(s)?;
    std::fs::create_dir_all(&store.dir).map_err(|e| format!("{}: {e}", store.dir.display()))?;
    store
        .save(&serde_json::to_vec(&cfg).map_err(|e| e.to_string())?)
        .map(drop)
}

// What: Kea subnet from the subnet form.
// Why: managed options by name, as Kea expects.
// From: Issue #1683 | PR #1858
fn subnet_from(
    get: &dyn Fn(&str) -> String,
    id: u64,
    keep: Option<&serde_json::Value>,
) -> serde_json::Value {
    let dns = [get("dns_primary"), get("dns_secondary")]
        .into_iter()
        .filter(|d| !d.is_empty())
        .collect::<Vec<_>>()
        .join(", ");
    let mut opts = vec![
        serde_json::json!({"name": "routers", "data": get("gateway")}),
        serde_json::json!({"name": "domain-name-servers", "data": dns}),
    ];
    for (name, key) in [("domain-name", "domain"), ("ntp-servers", "ntp_servers")] {
        if !get(key).is_empty() {
            opts.push(serde_json::json!({"name": name, "data": get(key)}));
        }
    }
    if let Some(k) = keep {
        opts.extend(
            k["option-data"]
                .as_array()
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .filter(|o| o.get("name").is_none()),
        );
    }
    let mut sn = serde_json::json!({
        "id": id, "subnet": get("subnet"),
        "pools": [{"pool": format!("{} - {}", get("pool_start"), get("pool_end"))}],
        "option-data": opts,
    });
    if let Ok(lt) = get("lease_time").parse::<u64>() {
        sn["valid-lifetime"] = lt.into();
    }
    if let Some(r) = keep.and_then(|k| k.get("reservations")) {
        sn["reservations"] = r.clone();
    }
    sn
}

// What: one DHCP page form action.
// Why: SOT keys via commit; Kea data via kea_edit.
// From: Issue #1683 | PR #1858
async fn dhcp_action(
    State(app): Shared,
    axum::Extension(csrf): axum::Extension<Csrf>,
    axum::extract::Path(op): axum::extract::Path<String>,
    Form(f): Form<BTreeMap<String, String>>,
) -> Response {
    if !csrf_ok(&f, &csrf) {
        return (StatusCode::FORBIDDEN, "CSRF token mismatch").into_response();
    }
    let s = app.settings();
    let get = |k: &str| f.get(k).map(|v| v.trim().to_string()).unwrap_or_default();
    let id_of = |k: &str| {
        get(k)
            .parse::<u64>()
            .map_err(|_| format!("{k} must be a number"))
    };
    let result = match op.as_str() {
        "mode" => {
            commit(
                &app,
                BTreeMap::from([("DHCP_MODE".into(), get("dhcp_mode"))]),
            )
            .await
        }
        "ddns" => {
            commit(
                &app,
                BTreeMap::from([(
                    "DHCP_DDNS".into(),
                    (get("enabled") == "1" || get("enabled") == "true").to_string(),
                )]),
            )
            .await
        }
        "proxy" | "relay" => {
            let mut up: BTreeMap<String, String> = f
                .iter()
                .filter(|(k, _)| k.starts_with("dhcp_") || k.starts_with("upstream_"))
                .filter(|(k, _)| !k.starts_with("dhcp_dns_"))
                .map(|(k, v)| {
                    (
                        k.to_ascii_uppercase()
                            .replace("DHCP_PROXY_CUSTOM_OPTIONS", "DHCP_CUSTOM_OPTIONS"),
                        v.trim().to_string(),
                    )
                })
                .collect();
            if op == "proxy" {
                let dns = [get("dhcp_dns_primary"), get("dhcp_dns_secondary")]
                    .into_iter()
                    .filter(|d| !d.is_empty())
                    .collect::<Vec<_>>();
                up.insert("DHCP_DNS_SERVERS".into(), dns.join(" "));
            }
            commit(&app, up).await
        }
        "subnet-add" => {
            kea_edit(&s, |l| {
                let id = l.iter().filter_map(|x| x["id"].as_u64()).max().unwrap_or(0) + 1;
                l.push(subnet_from(&get, id, None));
                Ok(())
            })
            .await
        }
        "subnet-update" => match id_of("id") {
            Ok(id) => {
                kea_edit(&s, |l| {
                    let p = l
                        .iter()
                        .position(|x| x["id"].as_u64() == Some(id))
                        .ok_or("no such subnet")?;
                    l[p] = subnet_from(&get, id, Some(&l[p].clone()));
                    Ok(())
                })
                .await
            }
            Err(e) => Err(e),
        },
        "subnet-remove" => match id_of("id") {
            Ok(id) => {
                kea_edit(&s, |l| {
                    l.retain(|x| x["id"].as_u64() != Some(id));
                    Ok(())
                })
                .await
            }
            Err(e) => Err(e),
        },
        "option-add" | "option-remove" => match (
            id_of("subnet_id"),
            lancache_ng::dhcp::option_code(&get("code")),
        ) {
            (Ok(id), Ok(code)) => {
                let data = get("data");
                let add = op == "option-add";
                kea_edit(&s, |l| {
                    let sn = l
                        .iter_mut()
                        .find(|x| x["id"].as_u64() == Some(id))
                        .ok_or("no such subnet")?;
                    let mut opts = sn["option-data"].as_array().cloned().unwrap_or_default();
                    opts.retain(|o| {
                        o["code"].as_u64() != Some(u64::from(code)) || o.get("name").is_some()
                    });
                    if add {
                        opts.push(serde_json::json!({"code": code, "data": data}));
                    }
                    sn["option-data"] = opts.into();
                    Ok(())
                })
                .await
            }
            (Err(e), _) | (_, Err(e)) => Err(e),
        },
        "static-add" | "static-remove" => match id_of("subnet_id") {
            Ok(id) => {
                let (mac, ip, host, add) =
                    (get("mac"), get("ip"), get("hostname"), op == "static-add");
                kea_edit(&s, |l| {
                    let sn = l.iter_mut().find(|x| x["id"].as_u64() == Some(id)).ok_or("no such subnet")?;
                    let mut res = sn["reservations"].as_array().cloned().unwrap_or_default();
                    res.retain(|r| r["hw-address"].as_str() != Some(mac.as_str()));
                    if add {
                        res.push(serde_json::json!({"hw-address": mac, "ip-address": ip, "hostname": host}));
                    }
                    sn["reservations"] = res.into();
                    Ok(())
                })
                .await
            }
            Err(e) => Err(e),
        },
        "lease-release" => match kea_api(&s) {
            Ok(api) => api.release(&get("ip")).await,
            Err(e) => Err(e),
        },
        "kea-rollback" => match kea_store(&s).and_then(|st| st.read(&get("snapshot_id"))) {
            Ok(body) => match (
                serde_json::from_slice::<serde_json::Value>(&body),
                kea_api(&s),
            ) {
                (Ok(cfg), Ok(api)) => api.set_config(cfg).await,
                (Err(e), _) => Err(e.to_string()),
                (_, Err(e)) => Err(e),
            },
            Err(e) => Err(e),
        },
        _ => Err(format!("unknown DHCP action {op}")),
    };
    done(result, "/dhcp")
}

// What: on-demand DHCP precheck in any mode.
// Why: finds foreign servers and tests a lease; no polling.
// From: Issue #1683 | PR #1858
async fn dhcp_check(
    State(app): Shared,
    axum::Extension(csrf): axum::Extension<Csrf>,
    headers: HeaderMap,
) -> Response {
    if !header_csrf_ok(&headers, &csrf) {
        return (StatusCode::FORBIDDEN, "CSRF token mismatch").into_response();
    }
    let s = app.settings();
    let report = tokio::task::spawn_blocking(move || lancache_ng::dhcp_probe::run(&s)).await;
    match report {
        Ok(r) => axum::Json(r).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

// What: render all configs, write changed files, act.
// Why: only owners with changed keys or files are touched.
// From: Issue #1683 | PR #1858
async fn apply_all(app: &App, old: &Settings, new: &Settings) -> Result<Vec<String>, String> {
    let sec = secrets(new)?;
    let serial = u32::try_from(clock::unix_secs() % u64::from(u32::MAX)).unwrap_or(1);
    let files = render::all(new, &sec, serial).map_err(|e| e.join("; "))?;
    let keep = fs::Owner {
        uid: None,
        gid: None,
    };
    let mut changes = old.diff(new);
    for f in &files {
        let changed = fs::write_if_changed(&f.path, f.body.as_bytes(), 0o644, keep)
            .map_err(|e| format!("{}: {e}", f.path.display()))?;
        if changed {
            changes.push(config::Change {
                key: f.path.display().to_string(),
                owner: f.owner.to_string(),
                effect: config::Effect::Reload,
            });
        }
    }
    if new.text("DNS_REPLICATION_ROLE").as_deref() == Ok("secondary") {
        ensure_secondary_zones(new).await?;
    }
    let plan = apply::plan(&changes);
    let (grace, limit) = app.limits(new)?;
    let project = new.text("COMPOSE_PROJECT")?;
    let name_of = |owner: &str| format!("{project}-{owner}-1");
    let done = apply::run(&app.docker, &plan, &name_of, grace, limit).await;
    Ok(done
        .into_iter()
        .map(|(o, r)| format!("{o}: {r:?}"))
        .collect())
}

// What: create missing secondary zones on this node.
// Why: zones come from the primary's registration answer.
// From: Issue #1683 | PR #1858
async fn ensure_secondary_zones(s: &Settings) -> Result<(), String> {
    let api = pdns_api(s)?;
    let have: Vec<String> = api.zones().await?.into_iter().map(|z| z.name).collect();
    let masters = vec![s.text("DNS_XFR_PRIMARY")?];
    for z in s.list("DNS_SECONDARY_ZONES") {
        let id = lancache_ng::pdns::zone_id(&z);
        if !have.contains(&id) {
            api.create_secondary(&id, &masters).await?;
        }
    }
    Ok(())
}

// What: secrets the configs embed, read or created once.
// Why: restarts never rotate a stored secret.
// From: Issue #1683 | PR #1858
fn secrets(s: &Settings) -> Result<render::Secrets, String> {
    let dir = PathBuf::from(s.text("SECRETS_DIR")?);
    let keep = fs::Owner {
        uid: None,
        gid: None,
    };
    let get = |k: &str| {
        secret::resolve(process_env(k).as_deref(), &dir, k, keep).map_err(|e| format!("{k}: {e}"))
    };
    Ok(render::Secrets {
        pdns_api_key: get("PDNS_API_KEY")?,
        recursor_api_key: get("RECURSOR_API_KEY")?,
        tsig_name: s.text("DDNS_TSIG_NAME")?,
        tsig_secret: base64::engine::general_purpose::STANDARD.encode(get("DDNS_TSIG_SECRET")?),
    })
}

// What: menu and API paths every page uses.
// Why: one table; templates never spell a path.
// From: Issue #1683 | PR #1858
const PAGES: [(&str, &str); 7] = [
    ("dashboard", "/"),
    ("logs", "/logs"),
    ("stats", "/stats"),
    ("cachehamster", "/cachehamster"),
    ("domains", "/domains"),
    ("dhcp", "/dhcp"),
    ("setup", "/setup"),
];
const ROUTES: [(&str, &str); 37] = [
    ("admin_css", "/static/admin.css"),
    ("favicon", "/favicon.ico"),
    ("logo_icon", "/static/logo-icon.png"),
    ("watchdog_status", "/api/status"),
    ("desired_state", "/api/container/{service}"),
    ("restart_ui", "/api/restart-ui"),
    ("setup_save", "/setup/save"),
    ("password", "/setup/password"),
    ("logs_save", "/logs/save"),
    ("dns_add", "/domains/domain-add"),
    ("dns_remove", "/domains/domain-remove"),
    ("dns_toggle", "/domains/domain-toggle"),
    ("lan_add", "/domains/record-add"),
    ("lan_remove", "/domains/record-remove"),
    ("ptr_add", "/domains/ptr-add"),
    ("ptr_remove", "/domains/ptr-remove"),
    ("aaaa_filter", "/domains/aaaa-filter"),
    ("ddns_unsigned", "/domains/ddns-unsigned"),
    ("zone_rollback", "/domains/zone-rollback"),
    ("secondary", "/api/secondary/{name}/remove"),
    ("secondary_rotate", "/api/secondary/{name}/rotate"),
    ("secondary_health", "/api/secondary/{name}/health"),
    ("secondary_address", "/api/secondary/{name}/address"),
    ("dhcp_mode", "/dhcp/mode"),
    ("dhcp_ddns", "/dhcp/ddns"),
    ("dhcp_proxy", "/dhcp/proxy"),
    ("dhcp_relay", "/dhcp/relay"),
    ("subnet_add", "/dhcp/subnet-add"),
    ("subnet_update", "/dhcp/subnet-update"),
    ("subnet_remove", "/dhcp/subnet-remove"),
    ("subnet_option_add", "/dhcp/option-add"),
    ("subnet_option_remove", "/dhcp/option-remove"),
    ("static_add", "/dhcp/static-add"),
    ("static_remove", "/dhcp/static-remove"),
    ("lease_release", "/dhcp/lease-release"),
    ("kea_rollback", "/dhcp/kea-rollback"),
    ("dhcp_check", "/dhcp/check"),
];

// What: traffic-light colour of one container.
// Why: beambar dots read green, yellow, red, gray.
// From: Issue #1683 | PR #1858
fn colour(c: &serde_json::Value) -> &'static str {
    let status = c["Status"].as_str().unwrap_or_default();
    match c["State"].as_str().unwrap_or_default() {
        "running" if status.contains("(unhealthy)") => "red",
        "running" if status.contains("(health: starting)") => "yellow",
        "running" => "green",
        "exited" | "created" => "gray",
        _ => "red",
    }
}

// What: container states for the beambar.
// Why: Docker is the one source; no status files.
// From: Issue #1683 | PR #1858
async fn status(State(app): Shared) -> Response {
    let s = app.settings();
    let (Ok((_, limit)), Ok(project)) = (app.limits(&s), s.text("COMPOSE_PROJECT")) else {
        return axum::Json(serde_json::json!({"state": "unavailable"})).into_response();
    };
    match app.docker.project(&project, limit).await {
        Ok(list) => {
            let services: Vec<serde_json::Value> = list
                .iter()
                .map(|c| {
                    serde_json::json!({
                        "name": c["Labels"][docker::SERVICE_LABEL],
                        "status": colour(c),
                        "health": c["Status"],
                    })
                })
                .collect();
            axum::Json(serde_json::json!({"state": "ok", "services": services})).into_response()
        }
        Err(e) => {
            eprintln!("ui: status: {e}");
            axum::Json(serde_json::json!({"state": "unavailable"})).into_response()
        }
    }
}

// What: wanted state from the beambar button.
// Why: body {"state": "running"|"stopped"}.
// From: Issue #1683 | PR #1858
#[derive(serde::Deserialize)]
struct Want {
    state: String,
}

// What: start or stop one container of the stack.
// Why: user action from the ui; the watchdog only watches.
// From: Issue #1683 | PR #1858
async fn container_state(
    State(app): Shared,
    axum::Extension(csrf): axum::Extension<Csrf>,
    axum::extract::Path(service): axum::extract::Path<String>,
    headers: HeaderMap,
    axum::Json(want): axum::Json<Want>,
) -> Response {
    if !header_csrf_ok(&headers, &csrf) {
        return (StatusCode::FORBIDDEN, "CSRF token mismatch").into_response();
    }
    let action = match want.state.as_str() {
        "running" => docker::Action::Start,
        "stopped" => docker::Action::Stop,
        _ => return (StatusCode::BAD_REQUEST, "state must be running or stopped").into_response(),
    };
    act(&app, &service, action).await
}

// What: restart the ui container itself.
// Why: Docker restarts it; the page reloads after.
// From: Issue #1683 | PR #1858
async fn restart_ui(
    State(app): Shared,
    axum::Extension(csrf): axum::Extension<Csrf>,
    Form(form): Form<BTreeMap<String, String>>,
) -> Response {
    if !csrf_ok(&form, &csrf) {
        return (StatusCode::FORBIDDEN, "CSRF token mismatch").into_response();
    }
    act(&app, "ui", docker::Action::Restart).await
}

// What: run one Docker action on a stack service.
// Why: only names of this compose project are reachable.
// From: Issue #1683 | PR #1858
async fn act(app: &App, service: &str, action: docker::Action) -> Response {
    let s = app.settings();
    let (grace, limit) = match app.limits(&s) {
        Ok(v) => v,
        Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, e).into_response(),
    };
    let Ok(project) = s.text("COMPOSE_PROJECT") else {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            "COMPOSE_PROJECT is not set",
        )
            .into_response();
    };
    let list = app
        .docker
        .project(&project, limit)
        .await
        .unwrap_or_default();
    let Some(name) = list
        .iter()
        .find(|c| c["Labels"][docker::SERVICE_LABEL].as_str() == Some(service))
        .and_then(|c| c["Names"][0].as_str())
        .map(|n| n.trim_start_matches('/').to_string())
    else {
        return (StatusCode::NOT_FOUND, "no such service in this stack").into_response();
    };
    match app.docker.act(&name, action, grace, limit).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => (StatusCode::BAD_GATEWAY, e.to_string()).into_response(),
    }
}

// What: CSRF check for JSON calls via header.
// Why: fetch() sends X-CSRF-Token, not a form field.
// From: Issue #1683 | PR #1858
fn header_csrf_ok(headers: &HeaderMap, csrf: &Csrf) -> bool {
    headers
        .get("x-csrf-token")
        .and_then(|v| v.to_str().ok())
        .is_some_and(|t| secret::equal(t.as_bytes(), csrf.0.as_bytes()))
}

// What: liveness answer for Docker HEALTHCHECK.
// Why: no auth; tells only that the ui answers.
// From: Issue #1683 | PR #1858
async fn health() -> &'static str {
    "ok"
}

// What: static file with fixed content type.
// Why: the browser must not sniff types.
// From: Issue #1683 | PR #1858
fn asset(kind: &'static str, body: &'static [u8]) -> Response {
    ([(header::CONTENT_TYPE, kind)], body).into_response()
}

// What: check a password against a PHC hash.
// Why: one owner for login and password change.
// From: Issue #1683 | PR #1858
fn verify(hash: &str, pw: &str) -> bool {
    PasswordHash::new(hash)
        .is_ok_and(|h| Argon2::default().verify_password(pw.as_bytes(), &h).is_ok())
}

// What: Argon2id PHC string of a password.
// Why: one owner for setup.sh and the password page.
// From: Issue #1683 | PR #1858
fn phc(pw: &str) -> Result<String, String> {
    let salt =
        argon2::password_hash::SaltString::generate(&mut argon2::password_hash::rand_core::OsRng);
    Argon2::default()
        .hash_password(pw.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|e| e.to_string())
}

// What: hash a password from stdin (PHC string).
// Why: setup.sh stores only the hash, never the password.
// From: Issue #1683 | PR #1858
fn hash_password() -> Result<(), String> {
    let mut line = String::new();
    std::io::stdin()
        .read_line(&mut line)
        .map_err(|e| e.to_string())?;
    let pw = line.trim_end_matches(['\r', '\n']);
    if pw.is_empty() {
        return Err("the password on stdin is empty".into());
    }
    println!("{}", phc(pw)?);
    Ok(())
}

// What: build the template set.
// Why: a broken template stops the start, not a page.
// From: Issue #1683 | PR #1858
fn templates() -> Result<Tera, String> {
    let mut t = Tera::default();
    t.autoescape_on(vec!["html"]);
    for (name, body) in TEMPLATES {
        t.add_raw_template(name, body)
            .map_err(|e| format!("template {name}: {e}"))?;
    }
    Ok(t)
}

// What: entry: subcommand or server.
// Why: setup.sh uses hash-password; Docker runs the server.
// From: Issue #1683 | PR #1858
#[tokio::main]
async fn main() -> Result<(), String> {
    if std::env::args().nth(1).as_deref() == Some("hash-password") {
        return hash_password();
    }
    let saved = process_env(SETTINGS_FILE_ENV).map(PathBuf::from);
    let s = Settings::load(&process_env, saved.as_deref())?;
    let dir = PathBuf::from(s.text("SECRETS_DIR")?);
    let keep = fs::Owner {
        uid: None,
        gid: None,
    };
    let key = secret::resolve(None, &dir, "UI_SESSION_KEY", keep).map_err(|e| e.to_string())?;
    let session_key = secret::key_bytes(&key)?;
    let app = Arc::new(App {
        docker: docker::Api::new(&s.text("DOCKER_ENDPOINT")?)?,
        tera: templates()?,
        settings: RwLock::new(s.clone()),
        saved,
        session_key,
    });
    let pages = Router::new()
        .route("/", get(dashboard))
        .route("/setup", get(setup))
        .route("/setup/save", post(save))
        .route("/setup/password", post(password))
        .route("/logs", get(logs))
        .route("/domains", get(domains))
        .route("/domains/{op}", post(dns_action))
        .route("/dhcp", get(dhcp))
        .route("/dhcp/check", post(dhcp_check))
        .route("/dhcp/{op}", post(dhcp_action))
        .route("/api/secondary/{name}/{op}", post(secondary_action))
        .route("/logs/save", post(logs_save))
        .route("/api/status", get(status))
        .route("/api/container/{service}", post(container_state))
        .route("/api/restart-ui", post(restart_ui))
        .layer(axum::middleware::from_fn_with_state(app.clone(), auth));
    let router = Router::new()
        .route("/healthz", get(health))
        .route("/api/secondary/register", post(register))
        .route(
            "/static/admin.css",
            get(|| async { asset("text/css", ADMIN_CSS.as_bytes()) }),
        )
        .route(
            "/favicon.ico",
            get(|| async { asset("image/x-icon", FAVICON) }),
        )
        .route(
            "/static/logo-icon.png",
            get(|| async { asset("image/png", LOGO) }),
        )
        .merge(pages)
        .with_state(app);
    let listen = format!("{}:{}", s.text("UI_LISTEN")?, s.uint("UI_PORT")?);
    let sock = tokio::net::TcpListener::bind(&listen)
        .await
        .map_err(|e| format!("{listen}: {e}"))?;
    axum::serve(sock, router).await.map_err(|e| e.to_string())
}
