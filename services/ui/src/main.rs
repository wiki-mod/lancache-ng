//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later

// What: admin ui: settings, pages and actions.
// Why: owns settings; renders and applies configs.
// From: Issue #1683 | PR #1858

use argon2::{Argon2, PasswordHash, PasswordHasher, PasswordVerifier};
use axum::extract::{Form, Request, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::middleware::Next;
use axum::response::{Html, IntoResponse, Redirect, Response};
use axum::routing::{get, post};
use axum::{Extension, Router};
use base64::Engine as _;
use lancache_ng::config::{self, Settings, process_env};
use lancache_ng::{access, apply, clock, docker, fs, http, human, render, secret};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};
use std::time::Duration;
use tera::{Context, Tera};

// What: env name of the saved settings file.
// Why: needed before any setting can be read.
// From: Issue #1683 | PR #1858
const SETTINGS_FILE_ENV: &str = "LANCACHE_SETTINGS_FILE";

// What: page templates built into the binary.
// Why: nothing to mount or lose; one image.
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

// What: static files built into the binary.
// Why: fixed content types; no runtime reads.
// From: Issue #1683 | PR #1858
const ADMIN_CSS: &str = include_str!("static/admin.css");
const FAVICON: &[u8] = include_bytes!("static/favicon.ico");
const LOGO: &[u8] = include_bytes!("static/logo-icon.png");

// What: session cookie name.
// Why: the CSRF token is derived from it.
// From: Issue #1683 | PR #1858
const COOKIE: &str = "lancache_session";

// What: form field that carries the CSRF token.
// Why: templates and handlers share one name.
// From: Issue #1683 | PR #1858
const CSRF_FIELD: &str = "csrf_token";

type Fields = BTreeMap<String, String>;

// What: error page text with an HTTP status.
// Why: handlers return Result and use the ? sign.
// From: Issue #1683 | PR #1858
struct Fail(StatusCode, String);

impl IntoResponse for Fail {
    fn into_response(self) -> Response {
        (self.0, self.1).into_response()
    }
}

impl From<String> for Fail {
    fn from(e: String) -> Self {
        Fail(StatusCode::INTERNAL_SERVER_ERROR, e)
    }
}

fn bad_request(text: impl Into<String>) -> Fail {
    Fail(StatusCode::BAD_REQUEST, text.into())
}

type Page = Result<Response, Fail>;

// What: state shared by all handlers.
// Why: settings swap whole after each save.
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
    // What: copy of the current settings.
    // Why: a handler never sees half an update.
    // From: Issue #1683 | PR #1858
    fn settings(&self) -> Settings {
        match self.settings.read() {
            Ok(s) => s.clone(),
            Err(poisoned) => poisoned.into_inner().clone(),
        }
    }

    // What: Docker stop grace and call limit.
    // Why: every wait comes from the SOT.
    // From: Issue #1683 | PR #1858
    fn limits(&self, s: &Settings) -> Result<(u32, Duration), String> {
        let grace = s.uint("UI_STOP_GRACE")?;
        let grace = u32::try_from(grace).map_err(|e| e.to_string())?;
        Ok((grace, Duration::from_secs(s.uint("DOCKER_TIMEOUT")?)))
    }

    // What: render a page with the shared context.
    // Why: menu, csrf and values on every page.
    // From: Issue #1683 | PR #1858
    fn page(&self, name: &str, mut ctx: Context, csrf: &Csrf) -> Page {
        let s = self.settings();
        let page = name.trim_end_matches(".html");
        let values: BTreeMap<String, String> = s
            .specs()
            .filter(|sp| !matches!(sp.kind, config::Kind::Secret))
            .filter_map(|sp| s.text(&sp.key).ok().map(|v| (sp.key.clone(), v)))
            .collect();
        let login = !s.text("UI_PASSWORD_HASH").unwrap_or_default().is_empty();
        let pages: BTreeMap<&str, &str> = PAGES.iter().copied().collect();
        let routes: BTreeMap<&str, &str> = ROUTES.iter().copied().collect();
        ctx.insert(CSRF_FIELD, &csrf.0);
        ctx.insert("page", page);
        ctx.insert("active_page", page);
        ctx.insert("v", &values);
        ctx.insert("login_enabled", &login);
        ctx.insert("pages", &pages);
        ctx.insert("routes", &routes);
        ctx.insert("repo_url", &s.text("REPO_URL")?);
        ctx.insert("desired_services", &s.list("UI_CONTROLLABLE_SERVICES"));
        ctx.insert("programs", &s.list("UI_SERVICES"));
        ctx.insert("watchdog_refresh_seconds", &s.uint("UI_STATUS_REFRESH")?);
        ctx.insert("warnings", &s.warnings);
        let html = self.tera.render(name, &ctx).map_err(|e| {
            eprintln!("ui: template {name}: {e:?}");
            format!("template {name} failed, see the log")
        })?;
        Ok(Html(html).into_response())
    }
}

// What: CSRF token bound to the session.
// Why: a foreign site cannot read the cookie.
// From: Issue #1683 | PR #1858
#[derive(Clone)]
struct Csrf(String);

impl Csrf {
    fn from_session(key: &[u8; 32], session: &str) -> Self {
        let mut h = Sha256::new();
        h.update(key);
        h.update(session.as_bytes());
        Csrf(h.finalize().iter().map(|b| format!("{b:02x}")).collect())
    }

    fn matches(&self, given: &str) -> bool {
        secret::equal(given, &self.0)
    }

    // What: form check; refuse without a match.
    // Why: each POST changes state.
    // From: Issue #1683 | PR #1858
    fn check(&self, form: &Fields) -> Result<(), Fail> {
        match form.get(CSRF_FIELD) {
            Some(t) if self.matches(t) => Ok(()),
            _ => Err(Fail(StatusCode::FORBIDDEN, "CSRF token mismatch".into())),
        }
    }

    // What: header check for script calls.
    // Why: JSON calls send the token as a header.
    // From: Issue #1683 | PR #1858
    fn check_header(&self, headers: &HeaderMap) -> Result<(), Fail> {
        let given = headers.get("x-csrf-token").and_then(|v| v.to_str().ok());
        match given {
            Some(t) if self.matches(t) => Ok(()),
            _ => Err(Fail(StatusCode::FORBIDDEN, "CSRF token mismatch".into())),
        }
    }
}

// What: session id from the Cookie header.
// Why: browsers may send several Cookie headers.
fn session_cookie(headers: &HeaderMap) -> Option<String> {
    for value in headers.get_all(header::COOKIE) {
        let Ok(text) = value.to_str() else { continue };
        for part in text.split(';') {
            if let Some((COOKIE, v)) = part.trim().split_once('=') {
                return Some(v.to_string());
            }
        }
    }
    None
}

// What: user and password from HTTP Basic auth.
// Why: scripts log in without a session cookie.
fn basic_credentials(headers: &HeaderMap) -> Option<(String, String)> {
    let raw = headers.get(header::AUTHORIZATION)?.to_str().ok()?;
    let encoded = raw.strip_prefix("Basic ")?;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .ok()?;
    let text = String::from_utf8(bytes).ok()?;
    let (user, pass) = text.split_once(':')?;
    Some((user.to_string(), pass.to_string()))
}

// What: Basic auth only when a hash is set.
// Why: the test stack runs without a password.
// From: Issue #1683 | PR #1858
async fn login_ok(s: &Settings, headers: &HeaderMap) -> bool {
    let hash = s.text("UI_PASSWORD_HASH").unwrap_or_default();
    if hash.is_empty() {
        return true;
    }
    let Some((user, pass)) = basic_credentials(headers) else {
        return false;
    };
    let want = s.text("UI_USER").unwrap_or_default();
    let pass_ok = tokio::task::spawn_blocking(move || verify(&hash, &pass))
        .await
        .unwrap_or(false);
    pass_ok & secret::equal(&user, &want)
}

// What: login, session cookie and CSRF token.
// Why: runs before every protected handler.
// From: Issue #1683 | PR #1858
async fn auth(State(app): Shared, mut req: Request, next: Next) -> Response {
    let s = app.settings();
    if !login_ok(&s, req.headers()).await {
        let realm = [(header::WWW_AUTHENTICATE, "Basic realm=\"LanCache Admin\"")];
        return (StatusCode::UNAUTHORIZED, realm, "Unauthorized").into_response();
    }
    let known = session_cookie(req.headers());
    let session = known.clone().unwrap_or_else(|| secret::random_hex(32));
    req.extensions_mut()
        .insert(Csrf::from_session(&app.session_key, &session));
    let mut res = next.run(req).await;
    if known.is_none() {
        let v = format!("{COOKIE}={session}; HttpOnly; SameSite=Strict; Path=/");
        if let Ok(v) = v.parse() {
            res.headers_mut().append(header::SET_COOKIE, v);
        }
    }
    res
}

// What: JSON file, or null when missing or bad.
// Why: pages render even before the file exists.
fn read_json(path: &str) -> Value {
    std::fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or(Value::Null)
}

// What: adds a human-readable byte size field.
// Why: pages show sizes like 40 GiB, not raw bytes.
fn with_human(v: &impl serde::Serialize, field: &str, n: u64) -> Value {
    let mut out = serde_json::to_value(v).unwrap_or(Value::Null);
    out[field] = human::bytes(n).into();
    out
}

// What: proxy request totals and recent rows.
// Why: dashboard; read off the async threads.
// From: Issue #1683 | PR #1858
async fn proxy_log(s: &Settings) -> Result<(Value, Vec<Value>), String> {
    let dir = Path::new(&s.text("SYSLOG_LOG_ROOT")?).join(s.text("PROXY_LOG_PROGRAM")?);
    let limit = usize::try_from(s.uint("UI_RECENT_REQUESTS")?).map_err(|e| e.to_string())?;
    let chunk = s.uint("UI_LOG_TAIL_CHUNK")?;
    let (stats, recent) = tokio::task::spawn_blocking(move || {
        (access::stats(&dir), access::tail(&dir, limit, chunk))
    })
    .await
    .map_err(|e| e.to_string())?;
    let totals = with_human(&stats, "total_bytes_human", stats.total_bytes);
    let rows = recent
        .iter()
        .rev()
        .map(|e| with_human(e, "bytes_human", e.bytes))
        .collect();
    Ok((totals, rows))
}

// What: active, requests, waiting from stub_status.
// Why: live counters next to the log figures.
// From: Issue #1683 | PR #1858
async fn fetch_proxy_live(s: &Settings) -> Option<serde_json::Value> {
    let url = s.text("PROXY_STATUS_URL").ok()?;
    let resp = http::client(s).ok()?.get(&url).send().await.ok()?;
    let body = resp.error_for_status().ok()?.text().await.ok()?;
    parse_stub_status(&body)
}

// What: read the stub_status text into numbers.
// Why: nginx gives plain text, the page needs fields.
// From: Issue #1683 | PR #1858
fn parse_stub_status(body: &str) -> Option<serde_json::Value> {
    let nums: Vec<u64> = body
        .split_whitespace()
        .filter_map(|w| w.parse().ok())
        .collect();
    let [active, _, _, requests, _, _, waiting] = nums.as_slice() else {
        return None;
    };
    Some(serde_json::json!({
        "active": active, "requests": requests, "waiting": waiting
    }))
}

// What: dashboard: alarms, containers, cache.
// Why: first page; shows what needs a look.
// From: Issue #1683 | PR #1858
async fn dashboard(State(app): Shared, Extension(csrf): Extension<Csrf>) -> Page {
    let s = app.settings();
    let mut ctx = Context::new();
    ctx.insert("alarms", &read_json(&s.text("WATCHDOG_ALARM_FILE")?));
    let (_, limit) = app.limits(&s)?;
    let project = s.text("COMPOSE_PROJECT")?;
    let containers = app
        .docker
        .project(&project, limit)
        .await
        .unwrap_or_default();
    ctx.insert("containers", &containers);
    let (totals, recent) = proxy_log(&s).await?;
    ctx.insert("log_stats", &totals);
    ctx.insert("recent_logs", &recent);
    if let Some(live) = fetch_proxy_live(&s).await {
        ctx.insert("proxy_live", &live);
    }
    if let Ok(sp) = fs::space(Path::new(&s.text("NGINX_CACHE_DIR")?)) {
        let used = sp.total.saturating_sub(sp.free);
        ctx.insert("cache_used_human", &human::bytes(used));
        ctx.insert("cache_pct", &(used.saturating_mul(100) / sp.total.max(1)));
    }
    app.page("dashboard.html", ctx, &csrf)
}

// What: does our NTP server answer.
// Why: General page shows the live state.
// From: Issue #1683 | PR #1858
async fn ntp_answers(s: &Settings) -> Result<bool, String> {
    if !s.flag("NTP_ENABLED")? {
        return Ok(false);
    }
    let ip = s.text("IP_HTTP")?;
    let port = s.uint("NTP_PORT")?;
    let wait = Duration::from_millis(s.uint("NTP_PROBE_WAIT_MS")?);
    let probe = move || lancache_ng::ntp::answers(&ip, port, wait);
    tokio::task::spawn_blocking(probe)
        .await
        .map_err(|e| e.to_string())
}

// What: General page.
// Why: channel, updates, NTP and login.
// From: Issue #1683 | PR #1858
async fn setup(State(app): Shared, Extension(csrf): Extension<Csrf>) -> Page {
    let s = app.settings();
    let mut ctx = Context::new();
    ctx.insert("ntp_answers", &ntp_answers(&s).await?);
    app.page("setup.html", ctx, &csrf)
}

// What: set a new ui password (Argon2id).
// Why: only the hash is kept; old one must match.
// From: Issue #1683 | PR #1858
async fn password(
    State(app): Shared,
    Extension(csrf): Extension<Csrf>,
    Form(form): Form<Fields>,
) -> Page {
    csrf.check(&form)?;
    let get = |k: &str| form.get(k).cloned().unwrap_or_default();
    let (current, new) = (get("current_password"), get("new_password"));
    if new != get("confirm_password") {
        return Err(bad_request("the two new passwords differ"));
    }
    let s = app.settings();
    let min = s.uint("UI_PASSWORD_MIN_LENGTH")?;
    if (new.chars().count() as u64) < min {
        return Err(bad_request(format!(
            "the password needs at least {min} characters"
        )));
    }
    let old = s.text("UI_PASSWORD_HASH").unwrap_or_default();
    let hashed = tokio::task::spawn_blocking(move || {
        if !old.is_empty() && !verify(&old, &current) {
            return Err("the current password is wrong".to_string());
        }
        phc(&new)
    })
    .await
    .map_err(|e| e.to_string())?
    .map_err(bad_request)?;
    let change = Fields::from([("UI_PASSWORD_HASH".to_string(), hashed)]);
    finish(commit(&app, change).await, "/setup")
}

// What: keep only real changes of known keys.
// Why: an empty secret field means keep it.
// From: Issue #1683 | PR #1858
fn changes(old: &Settings, form: Fields) -> Fields {
    let mut out = Fields::new();
    for (key, value) in form {
        let Some(spec) = old.spec(&key) else { continue };
        let secret = matches!(spec.kind, config::Kind::Secret);
        if secret && value.is_empty() {
            continue;
        }
        if old.text(&key).ok().as_deref() != Some(value.as_str()) {
            out.insert(key, value);
        }
    }
    out
}

// What: save, reload, render, write, apply.
// Why: one path for every setting change.
// From: Issue #1683 | PR #1858
async fn commit(app: &App, form: Fields) -> Result<(), String> {
    let Some(path) = app.saved.clone() else {
        return Err(format!("{SETTINGS_FILE_ENV} is not set"));
    };
    let old = app.settings();
    let updates = changes(&old, form);
    if updates.is_empty() {
        return Ok(());
    }
    config::store(&path, &old, &updates)?;
    let new = Settings::load(&process_env, Some(&path))?;
    for line in apply_all(app, &old, &new).await? {
        eprintln!("ui: apply: {line}");
    }
    match app.settings.write() {
        Ok(mut s) => *s = new,
        Err(poisoned) => *poisoned.into_inner() = new,
    }
    Ok(())
}

// What: end a form: redirect back or show error.
// Why: every form handler ends the same way.
// From: Issue #1683 | PR #1858
fn finish(result: Result<(), String>, back: &str) -> Page {
    result.map_err(bad_request)?;
    Ok(Redirect::to(back).into_response())
}

// What: General page form.
// Why: field names are the SOT keys.
// From: Issue #1683 | PR #1858
async fn save(
    State(app): Shared,
    Extension(csrf): Extension<Csrf>,
    Form(form): Form<Fields>,
) -> Page {
    csrf.check(&form)?;
    cache_room(&app.settings(), &form)?;
    finish(commit(&app, form).await, "/setup")
}

// What: newest lines of all programs, merged.
// Why: syslog-ng keeps one folder per program.
// From: Issue #1683 | PR #1858
fn newest_lines(root: &Path, programs: &[String], max: usize, chunk: u64) -> Vec<Value> {
    let mut all = Vec::new();
    for p in programs {
        for line in access::tail_lines(&root.join(p), max, chunk) {
            all.push((p.clone(), line));
        }
    }
    all.sort_by(|a, b| b.1.cmp(&a.1));
    all.truncate(max);
    all.into_iter()
        .map(|(p, l)| {
            let (stamp, text) = l.split_once(' ').unwrap_or(("", l.as_str()));
            json!({"host": p, "timestamp": stamp, "message": text})
        })
        .collect()
}

// What: logs page.
// Why: newest lines plus on/off per program.
// From: Issue #1683 | PR #1858
async fn logs(State(app): Shared, Extension(csrf): Extension<Csrf>) -> Page {
    let s = app.settings();
    let root = PathBuf::from(s.text("SYSLOG_LOG_ROOT")?);
    let max = usize::try_from(s.uint("UI_LOG_LINES")?).map_err(|e| e.to_string())?;
    let chunk = s.uint("UI_LOG_TAIL_CHUNK")?;
    let programs = s.list("SYSLOG_PROGRAMS");
    let muted = s.list("SYSLOG_MUTED");
    let names = programs.clone();
    let lines = tokio::task::spawn_blocking(move || newest_lines(&root, &names, max, chunk))
        .await
        .map_err(|e| e.to_string())?;
    let switches: Vec<Value> = programs
        .iter()
        .map(|p| json!({"program": p, "on": !muted.contains(p)}))
        .collect();
    let mut ctx = Context::new();
    ctx.insert("syslog_logs", &lines);
    ctx.insert("syslog_hosts", &programs);
    ctx.insert("log_switches", &switches);
    ctx.insert("logs_max_entries", &max);
    app.page("logs.html", ctx, &csrf)
}

// What: save forward targets and muted programs.
// Why: switch on_<program>; missing means muted.
// From: Issue #1683 | PR #1858
async fn logs_save(
    State(app): Shared,
    Extension(csrf): Extension<Csrf>,
    Form(form): Form<Fields>,
) -> Page {
    csrf.check(&form)?;
    let s = app.settings();
    let is_on = |p: &String| form.get(&format!("on_{p}")).is_some_and(|v| v == "true");
    let muted: Vec<String> = s
        .list("SYSLOG_PROGRAMS")
        .into_iter()
        .filter(|p| !is_on(p))
        .collect();
    let targets = form.get("SYSLOG_FORWARD").cloned().unwrap_or_default();
    let targets: Vec<&str> = targets.split_whitespace().collect();
    let mut change = Fields::new();
    change.insert("SYSLOG_MUTED".into(), muted.join(" "));
    change.insert("SYSLOG_FORWARD".into(), targets.join(" "));
    finish(commit(&app, change).await, "/logs#syslog")
}

// What: PowerDNS API of this node.
// Why: records live only in PowerDNS.
// From: Issue #1683 | PR #1858
fn pdns_api(s: &Settings) -> Result<lancache_ng::pdns::Api, String> {
    let key = secrets(s)?.pdns_api_key;
    let url = s.text("PDNS_PRIMARY_API_URL")?;
    Ok(lancache_ng::pdns::Api::new(http::client(s)?, &url, &key))
}

// What: reverse DNS name of an address.
// Why: PTR rows live in in-addr.arpa or ip6.arpa.
// From: Issue #1683 | PR #1858
fn reverse_name(ip: &str) -> Result<String, String> {
    use std::net::IpAddr;
    let addr: IpAddr = ip.parse().map_err(|_| format!("{ip:?} is no IP address"))?;
    Ok(match addr {
        IpAddr::V4(v4) => {
            let mut o = v4.octets();
            o.reverse();
            format!("{}.{}.{}.{}.in-addr.arpa.", o[0], o[1], o[2], o[3])
        }
        IpAddr::V6(v6) => {
            let mut nibbles = Vec::with_capacity(32);
            for b in v6.octets().iter().rev() {
                nibbles.push(format!("{:x}", b & 0x0f));
                nibbles.push(format!("{:x}", b >> 4));
            }
            format!("{}.ip6.arpa.", nibbles.join("."))
        }
    })
}

// What: private reverse zone holding a name.
// Why: the PowerDNS PATCH needs the zone.
// From: Issue #1683 | PR #1858
fn reverse_zone(s: &Settings, name: &str) -> Option<String> {
    let zones = lancache_ng::dns::private_reverse_zones(s);
    zones
        .into_iter()
        .filter(|z| name.ends_with(z.as_str()))
        .max_by_key(String::len)
}

// What: LAN zone name in canonical form.
// Why: PowerDNS compares names with trailing dot.
fn lan_zone(s: &Settings) -> Result<String, String> {
    Ok(lancache_ng::dns::canonical_zone(&s.text("DNS_LAN_ZONE")?))
}

// What: zones that keep snapshots.
// Why: LAN zone plus the private reverse zones.
// From: Issue #1683 | PR #1858
fn snapshot_zones(s: &Settings) -> Result<Vec<String>, String> {
    let mut zones = vec![lan_zone(s)?];
    zones.extend(lancache_ng::dns::private_reverse_zones(s));
    Ok(zones)
}

// What: snapshot store of one zone.
// Why: undo a bad change; count from the SOT.
// From: Issue #1683 | PR #1858
fn zone_store(s: &Settings, zone: &str) -> Result<lancache_ng::snapshot::Store, String> {
    let dir = Path::new(&s.text("DNS_SNAPSHOT_DIR")?).join(zone.trim_end_matches('.'));
    let keep = usize::try_from(s.uint("DNS_SNAPSHOT_KEEP")?).map_err(|e| e.to_string())?;
    let owner = fs::Owner {
        uid: None,
        gid: None,
    };
    Ok(lancache_ng::snapshot::Store { dir, keep, owner })
}

// What: keep the zone's records after a change.
// Why: each change can be undone later.
// From: Issue #1683 | PR #1858
async fn snapshot(s: &Settings, api: &lancache_ng::pdns::Api, zone: &str) -> Result<(), String> {
    let rows = api.rrsets(zone).await?;
    let body = serde_json::to_vec(&rows).map_err(|e| e.to_string())?;
    let store = zone_store(s, zone)?;
    std::fs::create_dir_all(&store.dir).map_err(|e| format!("{}: {e}", store.dir.display()))?;
    store.save(&body)?;
    Ok(())
}

// What: file change time as unix seconds.
// Why: snapshot age needs a plain number.
fn created_unix(path: &Path) -> Result<u64, String> {
    let when = std::fs::metadata(path).and_then(|m| m.modified());
    let when = when.map_err(|e| format!("{}: {e}", path.display()))?;
    let age = when
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| e.to_string())?;
    Ok(age.as_secs())
}

// What: snapshots of all zones, newest first.
// Why: DNS page and setup.sh show the same list.
// From: Issue #1683 | PR #1858
fn snapshot_list(s: &Settings) -> Result<Vec<(String, Vec<Value>)>, String> {
    let mut out = Vec::new();
    for zone in snapshot_zones(s)? {
        let store = zone_store(s, &zone)?;
        let mut rows = Vec::new();
        for id in store.list().unwrap_or_default() {
            let created = created_unix(&store.dir.join(&id))?;
            rows.push(json!({"id": id, "created_unix": created}));
        }
        out.push((zone, rows));
    }
    Ok(out)
}

// What: print {"zones":{zone:[{id,created_unix}]}}.
// Why: setup.sh reset-config reads this shape.
// From: Issue #1683 | PR #1858
fn zone_snapshots_cli(s: &Settings) -> Result<(), String> {
    let zones: serde_json::Map<String, Value> = snapshot_list(s)?
        .into_iter()
        .map(|(z, rows)| (z, Value::Array(rows)))
        .collect();
    println!("{}", json!({"zones": zones}));
    Ok(())
}

// What: put one zone back to a snapshot.
// Why: PATCH restores; PowerDNS sends NOTIFY.
// From: Issue #1683 | PR #1858
async fn rollback(s: &Settings, zone: &str, id: &str) -> Result<(), String> {
    if !snapshot_zones(s)?.iter().any(|z| z == zone) {
        return Err(format!("zone {zone} keeps no snapshots"));
    }
    let body = zone_store(s, zone)?.read(id)?;
    let rows: Vec<Value> = serde_json::from_slice(&body).map_err(|e| e.to_string())?;
    pdns_api(s)?.restore(zone, &rows).await
}

// What: PTR rows of all private reverse zones.
// Why: the DNS page lists them with the host.
// From: Issue #1683 | PR #1858
async fn ptr_rows(s: &Settings, api: &lancache_ng::pdns::Api) -> Vec<Value> {
    let mut out = Vec::new();
    for zone in lancache_ng::dns::private_reverse_zones(s) {
        for r in api.rrsets(&zone).await.unwrap_or_default() {
            if r["type"] != "PTR" {
                continue;
            }
            let host = r["records"][0]["content"].clone();
            out.push(json!({"ip": r["name"], "ttl": r["ttl"], "hostname": host}));
        }
    }
    out
}

// What: DNS page.
// Why: records are read live from PowerDNS.
// From: Issue #1683 | PR #1858
async fn domains(State(app): Shared, Extension(csrf): Extension<Csrf>) -> Page {
    let s = app.settings();
    let lan = lan_zone(&s)?;
    let mut ctx = Context::new();
    ctx.insert("dns_domains", &lancache_ng::cdn::parse_rows(&s)?);
    ctx.insert("lan_zone", lan.trim_end_matches('.'));
    let (mut lan_rows, mut ptr) = (Vec::new(), Vec::new());
    match pdns_api(&s) {
        Ok(api) => {
            lan_rows = api.rrsets(&lan).await.unwrap_or_default();
            ptr = ptr_rows(&s, &api).await;
        }
        Err(e) => ctx.insert("domain_error_message", &e),
    }
    ctx.insert("lan_records", &lan_rows);
    ctx.insert("ptr_records", &ptr);
    let groups: Vec<Value> = snapshot_list(&s)?
        .into_iter()
        .filter(|(_, rows)| !rows.is_empty())
        .map(|(zone, rows)| json!({"zone": zone, "snapshots": rows}))
        .collect();
    ctx.insert("zone_snapshot_groups", &groups);
    ctx.insert("rollback_zones", &snapshot_zones(&s)?);
    ctx.insert("zone_snapshot_retention", &s.uint("DNS_SNAPSHOT_KEEP")?);
    // What: values the domains page also reads.
    // Why: Tera stops on any missing variable.
    // From: Issue #1683 | PR #1980
    ctx.insert("dhcp_mode", &s.text("DHCP_MODE")?);
    ctx.insert("txt_max_bytes", &s.uint("DNS_TXT_MAX_BYTES")?);
    let reverse: Vec<String> = lancache_ng::dns::managed_zones(&s)?
        .into_iter()
        .filter(|z| z.ends_with(".arpa.") || z.ends_with(".arpa"))
        .collect();
    ctx.insert("reverse_zones", &reverse);
    let peers: Vec<Value> = secondaries(&s)
        .into_iter()
        .map(|(name, address)| json!({"name": name, "address": address}))
        .collect();
    ctx.insert("secondaries", &peers);
    ctx.insert("registration_token", &registration_token(&s)?);
    ctx.insert("setup_script_url", &s.text("SETUP_SCRIPT_URL")?);
    ctx.insert("primary_ip", &s.text("IP_HTTP")?);
    ctx.insert("primary_url", &s.text("UI_PUBLIC_URL").unwrap_or_default());
    ctx.insert("lan_record_types", &s.list("DNS_LAN_RECORD_TYPES"));
    ctx.insert("record_ttl_default", &s.uint("DNS_RECORD_TTL")?);
    ctx.insert("ttl_max", &s.uint("DNS_RECORD_TTL_MAX")?);
    ctx.insert("aaaa_filter_enabled", &s.flag("DNS_FILTER_AAAA")?);
    ctx.insert(
        "ddns_unsigned_updates_allowed",
        &s.flag("DDNS_ALLOW_UNSIGNED")?,
    );
    ctx.insert("ddns_tsig_key_configured", &tsig_secret(&s).is_ok());
    app.page("domains.html", ctx, &csrf)
}

// What: list setting with one item in or out.
// Why: domain add, remove and toggle share it.
// From: Issue #1683 | PR #1858
fn list_change(s: &Settings, key: &str, item: &str, present: bool) -> Fields {
    let mut items: Vec<String> = s.list(key).into_iter().filter(|x| x != item).collect();
    if present {
        items.push(item.to_string());
    }
    Fields::from([(key.to_string(), items.join(" "))])
}

fn single_field(key: &str, value: impl ToString) -> Fields {
    Fields::from([(key.to_string(), value.to_string())])
}

// What: one DNS page form, chosen by op.
// Why: all DNS forms post to /domains/{op}.
// From: Issue #1683 | PR #1858
async fn dns_action(
    State(app): Shared,
    Extension(csrf): Extension<Csrf>,
    axum::extract::Path(op): axum::extract::Path<String>,
    Form(form): Form<Fields>,
) -> Page {
    csrf.check(&form)?;
    let s = app.settings();
    let get = |k: &str| {
        form.get(k)
            .map(|v| v.trim().to_string())
            .unwrap_or_default()
    };
    let on = matches!(get("enabled").as_str(), "1" | "true");
    let domain = get("domain").to_ascii_lowercase();
    let result = match op.as_str() {
        "domain-add" if lancache_ng::dns::cdn_entry(&domain).is_none() => {
            Err(format!("{domain:?} is no valid domain entry"))
        }
        "domain-add" => commit(&app, list_change(&s, "CDN_CUSTOM_DOMAINS", &domain, true)).await,
        "domain-remove" => {
            commit(&app, list_change(&s, "CDN_CUSTOM_DOMAINS", &domain, false)).await
        }
        "domain-toggle" => {
            commit(&app, list_change(&s, "CDN_DISABLED_DOMAINS", &domain, !on)).await
        }
        "aaaa-filter" => commit(&app, single_field("DNS_FILTER_AAAA", on)).await,
        "ddns-unsigned" => commit(&app, single_field("DDNS_ALLOW_UNSIGNED", on)).await,
        "record-add" | "record-remove" => record(&s, op == "record-add", &get).await,
        "ptr-add" | "ptr-remove" => ptr(&s, op == "ptr-add", &get).await,
        "zone-rollback" => rollback(&s, &get("zone"), &get("snapshot_id")).await,
        "tsig-rotate" => rotate_tsig(&app).await,
        _ => Err(format!("unknown DNS action {op}")),
    };
    finish(result, "/domains")
}

// What: full name inside the LAN zone.
// Why: a short name gets the zone appended.
// From: Issue #1683 | PR #1858
fn in_zone(name: &str, zone: &str) -> String {
    if name.ends_with('.') || name.ends_with(zone.trim_end_matches('.')) {
        name.to_string()
    } else {
        format!("{name}.{zone}")
    }
}

// What: add or remove one LAN record set.
// Why: PATCH sets or deletes; NOTIFY follows.
// From: Issue #1683 | PR #1858
async fn record(
    s: &Settings,
    add: bool,
    get: &(dyn Fn(&str) -> String + Sync),
) -> Result<(), String> {
    let zone = lan_zone(s)?;
    let kind = get("record_type");
    if !s.list("DNS_LAN_RECORD_TYPES").contains(&kind) {
        return Err(format!("record type {kind} is not allowed"));
    }
    let name = in_zone(&get("name"), &zone);
    let mut contents = Vec::new();
    let mut ttl = 0;
    if add {
        let raw = get("content");
        contents = raw
            .split(';')
            .map(str::trim)
            .filter(|c| !c.is_empty())
            .map(String::from)
            .collect();
        let max = s.uint("DNS_RECORD_TTL_MAX")?;
        ttl = get("ttl").parse::<u32>().unwrap_or(0);
        if ttl == 0 || u64::from(ttl) > max {
            return Err(format!("TTL must be 1 to {max}"));
        }
    }
    let api = pdns_api(s)?;
    api.set_rrset(&zone, &name, &kind, ttl, &contents).await?;
    snapshot(s, &api, &zone).await
}

// What: add or remove one PTR record.
// Why: name from the IP; zone from the list.
// From: Issue #1683 | PR #1858
async fn ptr(s: &Settings, add: bool, get: &(dyn Fn(&str) -> String + Sync)) -> Result<(), String> {
    let ip = get("ip");
    let name = if ip.ends_with(".arpa.") {
        ip
    } else {
        reverse_name(&ip)?
    };
    let Some(zone) = reverse_zone(s, &name) else {
        return Err(format!("{name} is in no private reverse zone"));
    };
    let ttl = u32::try_from(s.uint("DNS_RECORD_TTL")?).map_err(|e| e.to_string())?;
    let mut contents = Vec::new();
    if add {
        let host = get("hostname");
        contents.push(if host.ends_with('.') {
            host
        } else {
            format!("{host}.")
        });
    }
    let api = pdns_api(s)?;
    api.set_rrset(&zone, &name, "PTR", ttl, &contents).await?;
    snapshot(s, &api, &zone).await
}

// What: owner that leaves uid and gid unchanged.
// Why: files keep the owner their reader expects.
fn owner_keep() -> fs::Owner {
    fs::Owner {
        uid: None,
        gid: None,
    }
}

// What: token secondaries register with.
// Why: kept like any secret; rotate renews it.
// From: Issue #1683 | PR #1858
fn registration_token(s: &Settings) -> Result<String, String> {
    let dir = PathBuf::from(s.text("SECRETS_DIR")?);
    let name = "SECONDARY_REGISTRATION_TOKEN";
    secret::resolve(None, &dir, name, owner_keep()).map_err(|e| e.to_string())
}

// What: secondaries as (name, address).
// Why: SOT list "name@ip" drives pdns and ui.
// From: Issue #1683 | PR #1858
fn secondaries(s: &Settings) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for row in s.list("DNS_SECONDARIES") {
        if let Some((name, addr)) = row.split_once('@') {
            out.push((name.to_string(), addr.to_string()));
        }
    }
    out
}

// What: saves secondaries as name@address rows.
// Why: one SOT key holds the whole list.
async fn store_secondaries(app: &App, list: &[(String, String)]) -> Result<(), String> {
    let rows: Vec<String> = list.iter().map(|(n, a)| format!("{n}@{a}")).collect();
    commit(app, single_field("DNS_SECONDARIES", rows.join(" "))).await
}

fn is_ip(text: &str) -> bool {
    text.parse::<std::net::IpAddr>().is_ok()
}

// What: body of a secondary registration.
// Why: the token proves the admin gave the command.
// From: Issue #1683 | PR #1858
#[derive(serde::Deserialize)]
struct Register {
    token: String,
    name: String,
    address: String,
}

// What: checks a secondary name: length, a-z0-9-.
// Why: the name becomes a DNS label and file name.
fn valid_peer_name(s: &Settings, name: &str) -> Result<bool, String> {
    let max = usize::try_from(s.uint("DNS_SECONDARY_NAME_MAX")?).map_err(|e| e.to_string())?;
    let chars_ok = name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-');
    Ok(!name.is_empty() && name.len() <= max && chars_ok)
}

// What: everything a new secondary needs.
// Why: setup.sh secondary writes it to its env.
// From: Issue #1683 | PR #1858
fn peer_kit(s: &Settings) -> Result<Value, String> {
    let sec = secrets(s)?;
    let primary = s.text("IP_HTTP")?;
    Ok(json!({
        "primary": primary,
        "zones": snapshot_zones(s)?,
        "pdns_api_key": sec.pdns_api_key,
        "tsig_name": sec.tsig_name,
        "tsig_secret": sec.tsig_secret,
        "syslog_primary": format!("{primary}:{}", s.uint("LANCACHE_LOG_PORT")?),
        "dns_local_reverse_zones": s.text("DNS_LOCAL_REVERSE_ZONES").unwrap_or_default(),
        "image_registry": process_env("LANCACHE_IMAGE_REGISTRY").unwrap_or_default(),
        "image_prefix": process_env("LANCACHE_IMAGE_PREFIX").unwrap_or_default(),
        "image_channel": process_env("LANCACHE_IMAGE_CHANNEL").unwrap_or_default(),
        "image_tag": process_env("LANCACHE_IMAGE_TAG").unwrap_or_default(),
    }))
}

// What: register a secondary (public route).
// Why: token checked; reply has the whole kit.
// From: Issue #1683 | PR #1858
async fn register(State(app): Shared, axum::Json(r): axum::Json<Register>) -> Page {
    let s = app.settings();
    let token = registration_token(&s).map_err(|e| Fail(StatusCode::SERVICE_UNAVAILABLE, e))?;
    if !secret::equal(&r.token, &token) {
        return Err(Fail(StatusCode::UNAUTHORIZED, "wrong token".into()));
    }
    if !valid_peer_name(&s, &r.name)? || !is_ip(&r.address) {
        return Err(bad_request("name or address is not valid"));
    }
    let mut list = secondaries(&s);
    list.retain(|(n, _)| *n != r.name);
    list.push((r.name.clone(), r.address.clone()));
    store_secondaries(&app, &list).await?;
    Ok(axum::Json(peer_kit(&app.settings())?).into_response())
}

// What: body with a new peer address.
// Why: the edit dialog posts {"address": ...}.
// From: Issue #1683 | PR #1858
#[derive(serde::Deserialize)]
struct Address {
    address: String,
}

// What: new registration token.
// Why: drop the file; resolve makes a fresh one.
// From: Issue #1683 | PR #1858
fn renew_token(s: &Settings) -> Result<String, String> {
    let dir = PathBuf::from(s.text("SECRETS_DIR")?);
    let file = secret::file_of(&dir, "SECONDARY_REGISTRATION_TOKEN");
    match std::fs::remove_file(&file) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
            return Err(format!("{}: {e}", file.display()));
        }
        _ => {}
    }
    registration_token(s)
}

// What: secondary actions from the DNS page.
// Why: remove, rotate, address and health.
// From: Issue #1683 | PR #1858
async fn secondary_action(
    State(app): Shared,
    Extension(csrf): Extension<Csrf>,
    axum::extract::Path((name, op)): axum::extract::Path<(String, String)>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Page {
    csrf.check_header(&headers)?;
    let s = app.settings();
    let mut list = secondaries(&s);
    let Some(at) = list.iter().position(|(n, _)| *n == name) else {
        return Err(Fail(StatusCode::NOT_FOUND, "no such secondary".into()));
    };
    match op.as_str() {
        "remove" => {
            list.remove(at);
            store_secondaries(&app, &list).await?;
            rotate_tsig(&app).await?;
            Ok(Redirect::to("/domains").into_response())
        }
        "rotate" => Ok(axum::Json(json!({"token": renew_token(&s)?})).into_response()),
        "address" => {
            let a: Address = serde_json::from_slice(&body)
                .map_err(|_| bad_request("body must be {\"address\": ...}"))?;
            if !is_ip(&a.address) {
                return Err(bad_request("no IP address"));
            }
            list[at].1 = a.address;
            store_secondaries(&app, &list).await.map_err(bad_request)?;
            Ok(StatusCode::NO_CONTENT.into_response())
        }
        "health" => Ok(axum::Json(secondary_health(&s, &list[at].1).await).into_response()),
        _ => Err(Fail(StatusCode::NOT_FOUND, "unknown action".into())),
    }
}

// What: SOA serial of one zone in a zone list.
// Why: serials show whether a secondary is in sync.
fn serial_of(zones: Vec<lancache_ng::pdns::Zone>, zone: &str) -> Option<u32> {
    zones.into_iter().find(|z| z.name == zone).map(|z| z.serial)
}

// What: LAN zone serial, primary vs secondary.
// Why: shows a lost NOTIFY or AXFR (RFC 1982).
// From: Issue #1683 | PR #1858
async fn peer_serials(s: &Settings, address: &str) -> Result<(Option<u32>, Option<u32>), String> {
    let zone = lan_zone(s)?;
    let port = s.uint("PDNS_AUTH_API_PORT")?;
    let url = format!("http://{address}:{port}/api/v1/servers/localhost");
    let key = secrets(s)?.pdns_api_key;
    let remote = lancache_ng::pdns::Api::new(http::client(s)?, &url, &key);
    let ours = pdns_api(s)?.zones().await?;
    let theirs = remote.zones().await?;
    Ok((serial_of(ours, &zone), serial_of(theirs, &zone)))
}

// What: sync state and serial of one secondary.
// Why: the secondaries page shows a status per peer.
async fn secondary_health(s: &Settings, address: &str) -> Value {
    match peer_serials(s, address).await {
        Ok((Some(p), Some(r))) => {
            let state = lancache_ng::dns::sync_state(p, r);
            json!({"status": format!("{state:?}"), "serial": r})
        }
        Ok((_, None)) => json!({"status": "missing", "detail": "zone not on secondary"}),
        Ok((None, _)) => json!({"status": "error", "detail": "zone not on primary"}),
        Err(e) => json!({"status": "unreachable", "detail": e}),
    }
}

// What: on a secondary, flush caches on change.
// Why: after AXFR old answers must go at once.
// From: Issue #1683 | PR #1858
async fn flush_on_transfer(app: Arc<App>) {
    let mut seen: BTreeMap<String, u32> = BTreeMap::new();
    loop {
        let s = app.settings();
        let wait = s.uint("UI_FLUSH_CHECK_SECONDS").unwrap_or(1).max(1);
        if s.text("DNS_REPLICATION_ROLE").as_deref() == Ok("secondary")
            && let Err(e) = flush_round(&s, &mut seen).await
        {
            eprintln!("ui: cache flush: {e}");
        }
        tokio::time::sleep(Duration::from_secs(wait)).await;
    }
}

// What: clears recursor cache for changed zones.
// Why: recursors would serve old answers until TTL.
async fn flush_round(s: &Settings, seen: &mut BTreeMap<String, u32>) -> Result<(), String> {
    let key = secrets(s)?.pdns_api_key;
    let client = http::client(s)?;
    for zone in pdns_api(s)?.zones().await? {
        let before = seen.insert(zone.name.clone(), zone.serial);
        if before.is_none_or(|b| b == zone.serial) {
            continue;
        }
        for url in s.list("RECURSOR_API_URLS") {
            let r = lancache_ng::pdns::Api::new(client.clone(), &url, &key);
            r.flush(&zone.name, true).await?;
        }
    }
    Ok(())
}

// What: Kea control agent of this stack.
// Why: subnets, reservations, leases live in Kea.
// From: Issue #1683 | PR #1858
fn kea_api(s: &Settings) -> Result<lancache_ng::kea::Api, String> {
    Ok(lancache_ng::kea::Api::new(
        http::client(s)?,
        &s.text("KEA_CTRL_URL")?,
    ))
}

// What: value of one Kea option in a subnet.
// Why: forms show options by name, Kea stores a list.
fn option_data(sn: &Value, name: &str) -> String {
    let rows = sn["option-data"].as_array().cloned().unwrap_or_default();
    let hit = rows.iter().find(|o| o["name"] == name);
    hit.and_then(|o| o["data"].as_str())
        .unwrap_or_default()
        .to_string()
}

// What: one Kea subnet as flat page fields.
// Why: the page shows fields; Kea has option-data.
// From: Issue #1683 | PR #1858
fn subnet_row(sn: &Value) -> Value {
    let dns: Vec<String> = option_data(sn, "domain-name-servers")
        .split(',')
        .map(|x| x.trim().to_string())
        .collect();
    let pool = sn["pools"][0]["pool"].as_str().unwrap_or_default();
    let (start, end) = pool.split_once('-').unwrap_or(("", ""));
    let custom: Vec<Value> = sn["option-data"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|o| o.get("code").is_some() && o.get("name").is_none())
        .cloned()
        .collect();
    json!({
        "id": sn["id"],
        "subnet": sn["subnet"],
        "gateway": option_data(sn, "routers"),
        "dns_primary": dns.first().cloned().unwrap_or_default(),
        "dns_secondary": dns.get(1).cloned().unwrap_or_default(),
        "ntp_servers": option_data(sn, "ntp-servers"),
        "pool_start": start.trim(),
        "pool_end": end.trim(),
        "lease_time": sn["valid-lifetime"],
        "custom_options": custom,
    })
}

// What: subnets, reservations, leases from Kea.
// Why: read live; nothing is kept in the ui.
// From: Issue #1683 | PR #1858
async fn kea_view(api: &lancache_ng::kea::Api) -> (Vec<Value>, Vec<Value>, Vec<Value>) {
    let (mut subnets, mut reservations, mut leases) = (Vec::new(), Vec::new(), Vec::new());
    if let Ok(cfg) = api.config().await {
        for sn in cfg["Dhcp4"]["subnet4"].as_array().into_iter().flatten() {
            for r in sn["reservations"].as_array().into_iter().flatten() {
                reservations.push(json!({
                    "subnet_id": sn["id"], "mac": r["hw-address"],
                    "ip": r["ip-address"], "hostname": r["hostname"],
                }));
            }
            subnets.push(subnet_row(sn));
        }
    }
    for l in api.leases().await.unwrap_or_default() {
        let ends = l["cltt"].as_u64().unwrap_or(0) + l["valid-lft"].as_u64().unwrap_or(0);
        leases.push(json!({
            "ip": l["ip-address"], "mac": l["hw-address"], "hostname": l["hostname"],
            "subnet_id": l["subnet-id"], "expires": ends.to_string(),
        }));
    }
    (subnets, reservations, leases)
}

// What: snapshot store of the Kea config.
// Why: each subnet change can be undone.
// From: Issue #1683 | PR #1858
fn kea_store(s: &Settings) -> Result<lancache_ng::snapshot::Store, String> {
    let dir = PathBuf::from(s.text("KEA_SNAPSHOT_DIR")?);
    let keep = usize::try_from(s.uint("KEA_SNAPSHOT_KEEP")?).map_err(|e| e.to_string())?;
    Ok(lancache_ng::snapshot::Store {
        dir,
        keep,
        owner: owner_keep(),
    })
}

// What: DHCP page.
// Why: mode, proxy, relay and live Kea data.
// From: Issue #1683 | PR #1858
async fn dhcp(State(app): Shared, Extension(csrf): Extension<Csrf>) -> Page {
    let s = app.settings();
    let mode = s.text("DHCP_MODE")?;
    let mut ctx = Context::new();
    ctx.insert("dhcp_mode", &mode);
    ctx.insert("dhcp_modes", &s.list("DHCP_MODES"));
    ctx.insert("dhcp_has_kea", &(mode == "kea"));
    ctx.insert("dhcp_is_dnsmasq", &mode.starts_with("dnsmasq"));
    ctx.insert("dhcp_is_relay", &(mode == "dnsmasq-relay"));
    ctx.insert("dhcp_ddns_enabled", &s.flag("DHCP_DDNS")?);
    // What: form values the dhcp page shows.
    // Why: Tera stops on any missing variable.
    // From: Issue #1683 | PR #1980
    let opt = |k: &str| s.text(k).unwrap_or_default();
    let dns = s.list("DHCP_DNS_SERVERS");
    ctx.insert("dhcp_dns_primary", dns.first().map_or("", String::as_str));
    ctx.insert("dhcp_dns_secondary", dns.get(1).map_or("", String::as_str));
    ctx.insert("default_lease_time", &opt("DHCP_LEASE_TIME"));
    ctx.insert("dhcp_domain", &opt("DHCP_DOMAIN"));
    ctx.insert("dhcp_ntp_servers", &opt("DHCP_NTP_SERVERS"));
    ctx.insert("dhcp_relay_local_addr", &opt("DHCP_RELAY_LOCAL_ADDR"));
    ctx.insert("dhcp_proxy_subnet_start", &opt("DHCP_SUBNET_START"));
    ctx.insert(
        "dhcp_proxy_custom_options_form",
        &opt("DHCP_CUSTOM_OPTIONS"),
    );
    for k in [
        "BOOT_FILENAME",
        "BOOT_SERVER",
        "DOMAIN",
        "INTERFACE",
        "ROUTER",
    ] {
        let name = format!("dhcp_proxy_{}", k.to_ascii_lowercase());
        ctx.insert(name, &opt(&format!("DHCP_PROXY_{k}")));
    }
    ctx.insert("dhcp_upstream_dhcp_ip", &opt("DHCP_UPSTREAM_DHCP_IP"));
    ctx.insert("kea_snapshot_retention", &opt("KEA_SNAPSHOT_KEEP"));
    ctx.insert(
        "ntp_auto_dhcp_active",
        &s.flag("NTP_AUTO_DHCP").unwrap_or(false),
    );
    let codes: Vec<u8> = lancache_ng::dhcp::MANAGED.iter().map(|m| m.code).collect();
    ctx.insert("kea_managed_codes", &codes);
    ctx.insert("dnsmasq_managed_codes", &codes);
    ctx.insert("option_code_min", &1);
    ctx.insert("option_code_max", &(u8::MAX - 1));
    let (mut subnets, mut reservations, mut leases) = (Vec::new(), Vec::new(), Vec::new());
    if mode == "kea" {
        match kea_api(&s) {
            Ok(api) => (subnets, reservations, leases) = kea_view(&api).await,
            Err(e) => ctx.insert("hint", &e),
        }
    }
    ctx.insert("subnets", &subnets);
    ctx.insert("reservations", &reservations);
    ctx.insert("leases", &leases);
    let store = kea_store(&s)?;
    let mut snaps = Vec::new();
    for id in store.list().unwrap_or_default() {
        let created = created_unix(&store.dir.join(&id))?;
        snaps.push(json!({"id": id, "created_unix": created}));
    }
    ctx.insert("kea_snapshots", &snaps);
    app.page("dhcp.html", ctx, &csrf)
}

// What: change Kea subnets with a closure.
// Why: get, edit, set, write, snapshot; one path.
// From: Issue #1683 | PR #1858
async fn kea_edit(
    s: &Settings,
    edit: impl FnOnce(&mut Vec<Value>) -> Result<(), String>,
) -> Result<(), String> {
    let api = kea_api(s)?;
    let mut cfg = api.config().await?;
    if let Some(top) = cfg.as_object_mut() {
        top.remove("hash");
    }
    let mut subnets = cfg["Dhcp4"]["subnet4"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    edit(&mut subnets)?;
    cfg["Dhcp4"]["subnet4"] = Value::Array(subnets);
    api.set_config(cfg.clone()).await?;
    let store = kea_store(s)?;
    std::fs::create_dir_all(&store.dir).map_err(|e| format!("{}: {e}", store.dir.display()))?;
    store.save(&serde_json::to_vec(&cfg).map_err(|e| e.to_string())?)?;
    Ok(())
}

// What: Kea subnet from the subnet form.
// Why: named options; code options and hosts kept.
// From: Issue #1683 | PR #1858
fn subnet_from(get: &(dyn Fn(&str) -> String + Sync), id: u64, old: Option<&Value>) -> Value {
    let dns: Vec<String> = [get("dns_primary"), get("dns_secondary")]
        .into_iter()
        .filter(|d| !d.is_empty())
        .collect();
    let mut opts = vec![
        json!({"name": "routers", "data": get("gateway")}),
        json!({"name": "domain-name-servers", "data": dns.join(", ")}),
    ];
    for (name, field) in [("domain-name", "domain"), ("ntp-servers", "ntp_servers")] {
        let value = get(field);
        if !value.is_empty() {
            opts.push(json!({"name": name, "data": value}));
        }
    }
    if let Some(old) = old {
        let coded = old["option-data"].as_array().into_iter().flatten();
        opts.extend(coded.filter(|o| o.get("name").is_none()).cloned());
    }
    let pool = format!("{} - {}", get("pool_start"), get("pool_end"));
    let mut sn = json!({"id": id, "subnet": get("subnet"), "pools": [{"pool": pool}],
                        "option-data": opts});
    if let Ok(life) = get("lease_time").parse::<u64>() {
        sn["valid-lifetime"] = life.into();
    }
    if let Some(hosts) = old.and_then(|o| o.get("reservations")) {
        sn["reservations"] = hosts.clone();
    }
    sn
}

// What: Kea subnet with the given id.
// Why: edits target a subnet by id, not position.
fn subnet_mut(list: &mut [Value], id: u64) -> Result<&mut Value, String> {
    let found = list.iter_mut().find(|x| x["id"].as_u64() == Some(id));
    found.ok_or_else(|| format!("no subnet {id}"))
}

// What: SOT keys of the proxy and relay forms.
// Why: field dhcp_x maps to key DHCP_X.
// From: Issue #1683 | PR #1858
fn dnsmasq_fields(form: &Fields, proxy: bool) -> Fields {
    let mut out = Fields::new();
    for (k, v) in form {
        let ours = k.starts_with("dhcp_") || k.starts_with("upstream_");
        if !ours || k.starts_with("dhcp_dns_") {
            continue;
        }
        let key = k
            .to_ascii_uppercase()
            .replace("DHCP_PROXY_CUSTOM_OPTIONS", "DHCP_CUSTOM_OPTIONS");
        out.insert(key, v.trim().to_string());
    }
    if proxy {
        let get = |k: &str| {
            form.get(k)
                .map(|v| v.trim().to_string())
                .unwrap_or_default()
        };
        let dns: Vec<String> = [get("dhcp_dns_primary"), get("dhcp_dns_secondary")]
            .into_iter()
            .filter(|d| !d.is_empty())
            .collect();
        out.insert("DHCP_DNS_SERVERS".into(), dns.join(" "));
    }
    out
}

// What: Kea subnet, option and host edits.
// Why: all go through kea_edit.
// From: Issue #1683 | PR #1858
async fn kea_action(
    s: &Settings,
    op: &str,
    get: &(dyn Fn(&str) -> String + Sync),
) -> Result<(), String> {
    let num = |k: &str| {
        get(k)
            .parse::<u64>()
            .map_err(|_| format!("{k} must be a number"))
    };
    match op {
        "subnet-add" => {
            kea_edit(s, |l| {
                let next = l.iter().filter_map(|x| x["id"].as_u64()).max().unwrap_or(0) + 1;
                l.push(subnet_from(get, next, None));
                Ok(())
            })
            .await
        }
        "subnet-update" => {
            let id = num("id")?;
            kea_edit(s, |l| {
                let sn = subnet_mut(l, id)?;
                *sn = subnet_from(get, id, Some(&sn.clone()));
                Ok(())
            })
            .await
        }
        "subnet-remove" => {
            let id = num("id")?;
            kea_edit(s, |l| {
                l.retain(|x| x["id"].as_u64() != Some(id));
                Ok(())
            })
            .await
        }
        "option-add" | "option-remove" => {
            let (id, code) = (
                num("subnet_id")?,
                lancache_ng::dhcp::option_code(&get("code"))?,
            );
            let data = get("data");
            kea_edit(s, |l| {
                let sn = subnet_mut(l, id)?;
                let mut opts = sn["option-data"].as_array().cloned().unwrap_or_default();
                let same = |o: &Value| o["code"].as_u64() == Some(u64::from(code));
                opts.retain(|o| !same(o) || o.get("name").is_some());
                if op == "option-add" {
                    opts.push(json!({"code": code, "data": data}));
                }
                sn["option-data"] = opts.into();
                Ok(())
            })
            .await
        }
        "static-add" | "static-remove" => {
            let id = num("subnet_id")?;
            let (mac, ip, host) = (get("mac"), get("ip"), get("hostname"));
            kea_edit(s, |l| {
                let sn = subnet_mut(l, id)?;
                let mut hosts = sn["reservations"].as_array().cloned().unwrap_or_default();
                hosts.retain(|r| r["hw-address"].as_str() != Some(mac.as_str()));
                if op == "static-add" {
                    hosts.push(json!({"hw-address": mac, "ip-address": ip, "hostname": host}));
                }
                sn["reservations"] = hosts.into();
                Ok(())
            })
            .await
        }
        "lease-release" => kea_api(s)?.release(&get("ip")).await,
        "kea-rollback" => {
            let body = kea_store(s)?.read(&get("snapshot_id"))?;
            let cfg: Value = serde_json::from_slice(&body).map_err(|e| e.to_string())?;
            kea_api(s)?.set_config(cfg).await
        }
        _ => Err(format!("unknown DHCP action {op}")),
    }
}

// What: one DHCP page form, chosen by op.
// Why: SOT keys via commit; Kea via kea_action.
// From: Issue #1683 | PR #1858
async fn dhcp_action(
    State(app): Shared,
    Extension(csrf): Extension<Csrf>,
    axum::extract::Path(op): axum::extract::Path<String>,
    Form(form): Form<Fields>,
) -> Page {
    csrf.check(&form)?;
    let s = app.settings();
    let get = |k: &str| {
        form.get(k)
            .map(|v| v.trim().to_string())
            .unwrap_or_default()
    };
    let on = matches!(get("enabled").as_str(), "1" | "true");
    let result = match op.as_str() {
        "mode" => commit(&app, single_field("DHCP_MODE", get("dhcp_mode"))).await,
        "ddns" => commit(&app, single_field("DHCP_DDNS", on)).await,
        "proxy" | "relay" => commit(&app, dnsmasq_fields(&form, op == "proxy")).await,
        _ => kea_action(&s, &op, &get).await,
    };
    finish(result, "/dhcp")
}

// What: DHCP precheck on demand.
// Why: finds foreign servers; tests one lease.
// From: Issue #1683 | PR #1858
async fn dhcp_check(
    State(app): Shared,
    Extension(csrf): Extension<Csrf>,
    headers: HeaderMap,
) -> Page {
    csrf.check_header(&headers)?;
    let s = app.settings();
    let probe = move || lancache_ng::dhcp_probe::run(&s);
    let report = tokio::task::spawn_blocking(probe)
        .await
        .map_err(|e| e.to_string())?;
    Ok(axum::Json(report).into_response())
}

// What: statistics page, one tab per range.
// Why: rrdtool draws; the page shows PNGs.
// From: Issue #1683 | PR #1858
async fn stats(State(app): Shared, Extension(csrf): Extension<Csrf>) -> Page {
    let s = app.settings();
    let mut ctx = Context::new();
    match lancache_ng::rrd::graphs(&s) {
        Ok(list) => {
            let rows: Vec<Value> = list
                .iter()
                .map(|g| json!({"name": g.name, "title": g.title}))
                .collect();
            ctx.insert("graphs", &rows);
        }
        Err(e) => ctx.insert("stats_error", &e),
    }
    ctx.insert("ranges", &s.list("STATS_RANGES"));
    app.page("stats.html", ctx, &csrf)
}

// What: query of one graph image.
// Why: dark=1 uses the dark colour set.
// From: Issue #1683 | PR #1858
#[derive(serde::Deserialize)]
struct GraphQuery {
    range: String,
    #[serde(default)]
    dark: u8,
}

// What: one graph as PNG.
// Why: drawn on request; RRD files stay small.
// From: Issue #1683 | PR #1858
async fn graph(
    State(app): Shared,
    axum::extract::Path(name): axum::extract::Path<String>,
    axum::extract::Query(q): axum::extract::Query<GraphQuery>,
) -> Page {
    let s = app.settings();
    let all = lancache_ng::rrd::graphs(&s)?;
    let Some(g) = all.into_iter().find(|g| g.name == name) else {
        return Err(Fail(StatusCode::NOT_FOUND, "no such graph".into()));
    };
    let draw = move || lancache_ng::rrd::png(&s, &g, &q.range, q.dark == 1);
    let png = tokio::task::spawn_blocking(draw)
        .await
        .map_err(|e| e.to_string())?
        .map_err(bad_request)?;
    Ok(([(header::CONTENT_TYPE, "image/png")], png).into_response())
}

// What: SNMP samples into RRD each step.
// Why: the ui owns the statistics files.
// From: Issue #1683 | PR #1858
fn sample_all(s: &Settings) -> Vec<String> {
    match lancache_ng::rrd::graphs(s) {
        Err(e) => vec![e],
        Ok(list) => list
            .iter()
            .filter_map(|g| lancache_ng::rrd::sample(s, g).err())
            .collect(),
    }
}

// What: records stats every STATS_STEP seconds.
// Why: the dashboard graphs need a time series.
async fn sampler(app: Arc<App>) {
    loop {
        let s = app.settings();
        let step = match s.uint("STATS_STEP") {
            Ok(v) => v,
            Err(e) => {
                eprintln!("ui: stats stop: {e}");
                return;
            }
        };
        let errs = tokio::task::spawn_blocking(move || sample_all(&s)).await;
        match errs {
            Ok(list) => list.iter().for_each(|e| eprintln!("ui: stats: {e}")),
            Err(e) => eprintln!("ui: stats: {e}"),
        }
        tokio::time::sleep(Duration::from_secs(step)).await;
    }
}

// What: container name of a compose service.
// Why: Docker calls need the real name.
// From: Issue #1683 | PR #1858
async fn container_of(app: &App, s: &Settings, service: &str) -> Result<String, String> {
    let (_, limit) = app.limits(s)?;
    let list = app.docker.project(&s.text("COMPOSE_PROJECT")?, limit).await;
    let list = list.map_err(|e| e.to_string())?;
    let hit = list
        .iter()
        .find(|c| c["Labels"][docker::SERVICE_LABEL].as_str() == Some(service));
    let name = hit.and_then(|c| c["Names"][0].as_str());
    name.map(|n| n.trim_start_matches('/').to_string())
        .ok_or_else(|| format!("no container for {service}"))
}

// What: run a command in a service container.
// Why: rc-service and cachehamster go this way.
// From: Issue #1683 | PR #1858
async fn exec_in(
    app: &App,
    s: &Settings,
    service: &str,
    cmd: &[&str],
) -> Result<(i64, String), String> {
    let name = container_of(app, s, service).await?;
    let (_, limit) = app.limits(s)?;
    app.docker
        .exec(&name, cmd, limit)
        .await
        .map_err(|e| e.to_string())
}

// What: restart or reload one program.
// Why: only through OpenRC; only listed ones.
// From: Issue #1683 | PR #1858
async fn service_action(
    State(app): Shared,
    Extension(csrf): Extension<Csrf>,
    axum::extract::Path((container, program, action)): axum::extract::Path<(
        String,
        String,
        String,
    )>,
    headers: HeaderMap,
) -> Page {
    csrf.check_header(&headers)?;
    if action != "restart" && action != "reload" {
        return Err(bad_request("action must be restart or reload"));
    }
    let s = app.settings();
    if !s
        .list("UI_SERVICES")
        .contains(&format!("{container}:{program}"))
    {
        return Err(Fail(StatusCode::NOT_FOUND, "program not offered".into()));
    }
    let cmd = ["rc-service", program.as_str(), action.as_str()];
    let (code, out) = exec_in(&app, &s, &container, &cmd)
        .await
        .map_err(|e| Fail(StatusCode::BAD_GATEWAY, e))?;
    if code != 0 {
        return Err(Fail(
            StatusCode::BAD_GATEWAY,
            format!("rc-service exit {code}: {out}"),
        ));
    }
    Ok(StatusCode::NO_CONTENT.into_response())
}

// What: one cachehamster command; JSON answer.
// Why: it runs in the services container.
// From: Issue #871 | PR #1858
async fn hamster(app: &App, args: &[&str]) -> Result<Value, String> {
    let s = app.settings();
    let program = s.text("CACHEHAMSTER_PROGRAM")?;
    let mut cmd = vec![program.as_str()];
    cmd.extend_from_slice(args);
    let (code, out) = exec_in(app, &s, &s.text("CACHEHAMSTER_SERVICE")?, &cmd).await?;
    let line = out
        .lines()
        .rev()
        .find(|l| l.starts_with('{'))
        .unwrap_or_default();
    let v: Value = serde_json::from_str(line).map_err(|e| format!("cachehamster: {e}: {out}"))?;
    if let Some(e) = v.get("error").and_then(Value::as_str) {
        return Err(e.to_string());
    }
    if code != 0 {
        return Err(format!("cachehamster exit {code}"));
    }
    Ok(v)
}

// What: cachehamster page.
// Why: prefill is driven from the ui only.
// From: Issue #871 | PR #1858
async fn cachehamster(State(app): Shared, Extension(csrf): Extension<Csrf>) -> Page {
    let mut ctx = Context::new();
    match hamster(&app, &["status"]).await {
        Ok(v) => ctx.insert("hamster", &v),
        Err(e) => ctx.insert("hamster_error", &e),
    }
    app.page("cachehamster.html", ctx, &csrf)
}

// What: when a job runs, as a command word.
// Why: the page sends unix seconds for "at".
// From: Issue #871 | PR #1858
fn job_time(when: &str, at: &str) -> Result<String, Fail> {
    match when {
        "at" => at
            .parse::<u64>()
            .map(|t| format!("at:{t}"))
            .map_err(|_| bad_request("time not understood")),
        "later" => Ok("later".into()),
        _ => Ok("now".into()),
    }
}

// What: add, start, cancel, remove, logout.
// Why: each maps to one cachehamster command.
// From: Issue #871 | PR #1858
async fn hamster_action(
    State(app): Shared,
    Extension(csrf): Extension<Csrf>,
    axum::extract::Path(op): axum::extract::Path<String>,
    Form(form): Form<Fields>,
) -> Page {
    csrf.check(&form)?;
    let get = |k: &str| {
        form.get(k)
            .map(|v| v.trim().to_string())
            .unwrap_or_default()
    };
    let when = job_time(&get("when"), &get("at"))?;
    let what = match get("app").as_str() {
        "" => get("urls"),
        id => format!("app:{id}"),
    };
    let (name, id) = (get("name"), get("id"));
    let args: Vec<&str> = match op.as_str() {
        "add" => vec!["add", &name, &when, &what],
        "start" | "cancel" | "remove" => vec![op.as_str(), &id],
        "logout" => vec!["logout"],
        _ => return Err(Fail(StatusCode::NOT_FOUND, "no such action".into())),
    };
    finish(hamster(&app, &args).await.map(drop), "/cachehamster")
}

// What: JSON calls: QR login and library.
// Why: the page polls without a reload.
// From: Issue #871 | PR #1858
async fn hamster_api(
    State(app): Shared,
    Extension(csrf): Extension<Csrf>,
    axum::extract::Path(op): axum::extract::Path<String>,
    headers: HeaderMap,
) -> Page {
    csrf.check_header(&headers)?;
    let allowed = [
        "login-begin",
        "login-poll",
        "login-cancel",
        "library",
        "status",
    ];
    if !allowed.contains(&op.as_str()) {
        return Err(Fail(StatusCode::NOT_FOUND, "no such call".into()));
    }
    let v = hamster(&app, &[op.as_str()])
        .await
        .map_err(|e| Fail(StatusCode::BAD_GATEWAY, e))?;
    Ok(axum::Json(v).into_response())
}

// What: config file mode from octal SOT text.
// Why: modes are written as octal like 0640.
fn file_mode(s: &Settings) -> Result<u32, String> {
    let raw = s.text("UI_CONFIG_FILE_MODE")?;
    u32::from_str_radix(&raw, 8).map_err(|e| format!("UI_CONFIG_FILE_MODE: {e}"))
}

// What: write rendered files; list the changed.
// Why: an unchanged file never wakes its owner.
// From: Issue #1683 | PR #1858
fn write_files(s: &Settings, files: &[render::File]) -> Result<Vec<config::Change>, String> {
    let mode = file_mode(s)?;
    let mut out = Vec::new();
    for f in files {
        let changed = fs::write_if_changed(&f.path, f.body.as_bytes(), mode, owner_keep());
        if changed.map_err(|e| format!("{}: {e}", f.path.display()))? {
            out.push(config::Change {
                key: f.path.display().to_string(),
                owner: f.owner.to_string(),
                effect: config::Effect::Reload,
            });
        }
    }
    Ok(out)
}

// What: render, write and wake the owners.
// Why: only owners with changes are touched.
// From: Issue #1683 | PR #1858
async fn apply_all(app: &App, old: &Settings, new: &Settings) -> Result<Vec<String>, String> {
    let sec = secrets(new)?;
    let serial = u32::try_from(clock::unix_secs() % u64::from(u32::MAX)).unwrap_or(1);
    let files = render::all(new, &sec, serial).map_err(|e| e.join("; "))?;
    let mut changes = old.diff(new);
    changes.extend(write_files(new, &files)?);
    if new.text("DNS_REPLICATION_ROLE")? == "secondary" {
        ensure_secondary_zones(new).await?;
    }
    ensure_tsig(new).await?;
    let mut plan = apply::plan(&changes);
    let (grace, limit) = app.limits(new)?;
    let mut names = BTreeMap::new();
    for owner in plan.keys() {
        names.insert(owner.clone(), container_of(app, new, owner).await?);
    }
    let mut report = Vec::new();
    let dhcp = new.text("DHCP_SERVICE")?;
    if new.text("DHCP_MODE")? == "off" && plan.remove(&dhcp).is_some() {
        let name = container_of(app, new, &dhcp).await?;
        let r = app
            .docker
            .act(&name, docker::Action::Stop, grace, limit)
            .await;
        report.push(format!("{dhcp}: mode off, stop {r:?}"));
    }
    let lookup = |owner: &str| names.get(owner).cloned().unwrap_or_default();
    let hup = new.list("HUP_OWNERS");
    for (owner, result) in apply::run(&app.docker, &plan, &hup, &lookup, grace, limit).await {
        report.push(format!("{owner}: {result:?}"));
    }
    Ok(report)
}

// What: start or stop a container for the user.
// Why: SERVICES_STOPPED is the wish the watchdog obeys.
// From: Issue #1683 | PR #1858
async fn set_wanted(app: &App, service: &str, run: bool) -> Result<(), String> {
    let s = app.settings();
    if !s
        .list("UI_CONTROLLABLE_SERVICES")
        .iter()
        .any(|x| x == service)
    {
        return Err(format!("{service} cannot be switched here"));
    }
    commit(app, list_change(&s, "SERVICES_STOPPED", service, !run)).await?;
    let (grace, limit) = app.limits(&s)?;
    let name = container_of(app, &s, service).await?;
    let action = if run {
        docker::Action::Start
    } else {
        docker::Action::Stop
    };
    app.docker
        .act(&name, action, grace, limit)
        .await
        .map_err(|e| e.to_string())
}

// What: TSIG key in PowerDNS, bound to zones.
// Why: AXFR needs the key, not only an address.
// From: Issue #1683 | PR #1858
async fn ensure_tsig(s: &Settings) -> Result<(), String> {
    let sec = secrets(s)?;
    let api = pdns_api(s)?;
    let algorithm = s.text("DDNS_TSIG_ALGORITHM")?;
    api.set_tsigkey(&sec.tsig_name, &algorithm, &sec.tsig_secret)
        .await?;
    let kind = match s.text("DNS_REPLICATION_ROLE")?.as_str() {
        "secondary" => "AXFR-MASTER-TSIG",
        _ => "TSIG-ALLOW-AXFR",
    };
    let key = vec![sec.tsig_name];
    for z in api.zones().await? {
        api.set_metadata(&z.name, kind, &key).await?;
    }
    Ok(())
}

// What: create missing zones on a secondary.
// Why: the zone list comes from registration.
// From: Issue #1683 | PR #1858
async fn ensure_secondary_zones(s: &Settings) -> Result<(), String> {
    let api = pdns_api(s)?;
    let have: Vec<String> = api.zones().await?.into_iter().map(|z| z.name).collect();
    let masters = vec![s.text("DNS_XFR_PRIMARY")?];
    for zone in s.list("DNS_SECONDARY_ZONES") {
        let id = lancache_ng::pdns::zone_id(&zone);
        if !have.contains(&id) {
            api.create_secondary(&id, &masters).await?;
        }
    }
    Ok(())
}

// What: path of the DDNS TSIG secret file.
// Why: Kea DDNS and PowerDNS share this key.
fn tsig_file(s: &Settings) -> Result<PathBuf, String> {
    Ok(secret::file_of(
        Path::new(&s.text("SECRETS_DIR")?),
        "DDNS_TSIG_KEY",
    ))
}

// What: fresh 32-byte TSIG secret, base64.
// Why: PowerDNS and Kea both read base64.
// From: Issue #1683 | PR #1858
fn new_tsig() -> String {
    let hex = secret::random_hex(32);
    let bytes: Vec<u8> = hex
        .as_bytes()
        .chunks(2)
        .filter_map(|p| std::str::from_utf8(p).ok())
        .filter_map(|p| u8::from_str_radix(p, 16).ok())
        .collect();
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

// What: TSIG secret; a rotated file wins.
// Why: a ui rotation beats the setup.sh value.
// From: Issue #1683 | PR #1858
fn tsig_secret(s: &Settings) -> Result<String, String> {
    let file = tsig_file(s)?;
    if !file.exists()
        && let Some(v) = process_env("DDNS_TSIG_KEY").filter(|v| !v.is_empty())
    {
        return Ok(v);
    }
    secret::load_or_create(&file, new_tsig, owner_keep()).map_err(|e| format!("DDNS_TSIG_KEY: {e}"))
}

// What: replace the TSIG secret and apply.
// Why: shuts out a removed or leaked secondary.
// From: Issue #1683 | PR #1858
async fn rotate_tsig(app: &App) -> Result<(), String> {
    let s = app.settings();
    let file = tsig_file(&s)?;
    match std::fs::remove_file(&file) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
            return Err(format!("{}: {e}", file.display()));
        }
        _ => {}
    }
    secret::load_or_create(&file, new_tsig, owner_keep())
        .map_err(|e| format!("DDNS_TSIG_KEY: {e}"))?;
    for line in apply_all(app, &s, &s).await? {
        eprintln!("ui: tsig rotate: {line}");
    }
    Ok(())
}

// What: secrets the configs embed.
// Why: made once; restarts never change them.
// From: Issue #1683 | PR #1858
fn secrets(s: &Settings) -> Result<render::Secrets, String> {
    let dir = PathBuf::from(s.text("SECRETS_DIR")?);
    let get = |k: &str| {
        secret::resolve(process_env(k).as_deref(), &dir, k, owner_keep())
            .map_err(|e| format!("{k}: {e}"))
    };
    Ok(render::Secrets {
        pdns_api_key: get("PDNS_API_KEY")?,
        recursor_api_key: get("RECURSOR_API_KEY")?,
        tsig_name: s.text("DDNS_TSIG_NAME")?,
        tsig_secret: tsig_secret(s)?,
    })
}

// What: bytes of an nginx size like 50g.
// Why: CACHE_MAX_SIZE uses nginx size units.
// From: Issue #1069
fn nginx_bytes(text: &str) -> Result<u64, String> {
    let t = text.trim().to_ascii_lowercase();
    let (num, shift) = match t.chars().last() {
        Some('k') => (&t[..t.len() - 1], 10),
        Some('m') => (&t[..t.len() - 1], 20),
        Some('g') => (&t[..t.len() - 1], 30),
        Some('t') => (&t[..t.len() - 1], 40),
        _ => (t.as_str(), 0),
    };
    let n: u64 = num.parse().map_err(|_| format!("{text:?} is no size"))?;
    n.checked_shl(shift)
        .ok_or_else(|| format!("{text:?} is too big"))
}

// What: refuse a bigger cache without room.
// Why: growth must fit the free disk space.
// From: Issue #1069
fn cache_room(s: &Settings, form: &Fields) -> Result<(), Fail> {
    let Some(wanted) = form.get("CACHE_MAX_SIZE") else {
        return Ok(());
    };
    let new = nginx_bytes(wanted).map_err(bad_request)?;
    let old = nginx_bytes(&s.text("CACHE_MAX_SIZE")?)?;
    if new <= old {
        return Ok(());
    }
    let dir = s.text("NGINX_CACHE_DIR")?;
    let sp = fs::space(Path::new(&dir)).map_err(|e| format!("{dir}: {e}"))?;
    let used = sp.total.saturating_sub(sp.free);
    let reachable = sp.free.saturating_add(used.min(old));
    if new > reachable {
        let room = human::bytes(reachable);
        return Err(bad_request(format!(
            "cache size {wanted} does not fit; at most {room}"
        )));
    }
    Ok(())
}

// What: traffic-light colour of a container.
// Why: the beambar shows green, yellow, red, gray.
// From: Issue #1683 | PR #1858
fn colour(c: &Value) -> &'static str {
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
// Why: Docker is the source; no status files.
// From: Issue #1683 | PR #1858
async fn status(State(app): Shared) -> Response {
    let s = app.settings();
    let stopped = s.list("SERVICES_STOPPED");
    let list = match (app.limits(&s), s.text("COMPOSE_PROJECT")) {
        (Ok((_, limit)), Ok(project)) => app.docker.project(&project, limit).await.ok(),
        _ => None,
    };
    let Some(list) = list else {
        return axum::Json(json!({"state": "unavailable"})).into_response();
    };
    let rows: Vec<Value> = list
        .iter()
        .map(|c| {
            let name = c["Labels"][docker::SERVICE_LABEL]
                .as_str()
                .unwrap_or_default();
            json!({"name": name, "status": colour(c), "health": c["Status"],
                   "stopped_by_user": stopped.iter().any(|x| x == name)})
        })
        .collect();
    axum::Json(json!({"state": "ok", "services": rows})).into_response()
}

// What: wish from the beambar button.
// Why: body {"state": "running" or "stopped"}.
// From: Issue #1683 | PR #1858
#[derive(serde::Deserialize)]
struct Want {
    state: String,
}

// What: start or stop one container.
// Why: the wish is saved first; see set_wanted.
// From: Issue #1683 | PR #1858
async fn container_state(
    State(app): Shared,
    Extension(csrf): Extension<Csrf>,
    axum::extract::Path(service): axum::extract::Path<String>,
    headers: HeaderMap,
    axum::Json(want): axum::Json<Want>,
) -> Page {
    csrf.check_header(&headers)?;
    let run = match want.state.as_str() {
        "running" => true,
        "stopped" => false,
        _ => return Err(bad_request("state must be running or stopped")),
    };
    set_wanted(&app, &service, run)
        .await
        .map_err(|e| Fail(StatusCode::BAD_GATEWAY, e))?;
    Ok(StatusCode::NO_CONTENT.into_response())
}

// What: restart the ui container itself.
// Why: Docker restarts it; the page reloads.
// From: Issue #1683 | PR #1858
async fn restart_ui(
    State(app): Shared,
    Extension(csrf): Extension<Csrf>,
    Form(form): Form<Fields>,
) -> Page {
    csrf.check(&form)?;
    let s = app.settings();
    let (grace, limit) = app.limits(&s)?;
    let name = container_of(&app, &s, &s.text("UI_SERVICE")?).await?;
    app.docker
        .act(&name, docker::Action::Restart, grace, limit)
        .await
        .map_err(|e| Fail(StatusCode::BAD_GATEWAY, e.to_string()))?;
    Ok(StatusCode::NO_CONTENT.into_response())
}

// What: liveness answer for the healthcheck.
// Why: no login; says only that the ui answers.
// From: Issue #1683 | PR #1858
async fn health() -> &'static str {
    "ok"
}

fn asset(kind: &'static str, body: &'static [u8]) -> Response {
    ([(header::CONTENT_TYPE, kind)], body).into_response()
}

// What: password against a PHC hash.
// Why: one owner for login and change.
// From: Issue #1683 | PR #1858
fn verify(hash: &str, pw: &str) -> bool {
    let Ok(parsed) = PasswordHash::new(hash) else {
        return false;
    };
    Argon2::default()
        .verify_password(pw.as_bytes(), &parsed)
        .is_ok()
}

// What: Argon2id PHC string of a password.
// Why: setup.sh and the page share it.
// From: Issue #1683 | PR #1858
fn phc(pw: &str) -> Result<String, String> {
    let hash: Result<PasswordHash, _> = Argon2::default().hash_password(pw.as_bytes());
    hash.map(|h| h.to_string()).map_err(|e| e.to_string())
}

// What: hash a password read from stdin.
// Why: setup.sh keeps only the hash.
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

// What: image identity functions for the page footer.
// Why: Tera checks calls when a template is added.
// From: Issue #1683 | PR #1980
fn register_image_functions(t: &mut Tera) {
    for (func, key) in [
        ("lancache_image_registry", "LANCACHE_IMAGE_REGISTRY"),
        ("lancache_image_prefix", "LANCACHE_IMAGE_PREFIX"),
        ("lancache_image_tag", "LANCACHE_IMAGE_TAG"),
        ("lancache_image_channel", "LANCACHE_IMAGE_CHANNEL"),
    ] {
        t.register_function(func, move |_: tera::Kwargs, _: &tera::State| {
            process_env(key).unwrap_or_default()
        });
    }
}

// What: compile all templates at start.
// Why: a broken template stops the start.
// From: Issue #1683 | PR #1858
fn templates() -> Result<Tera, String> {
    let mut t = Tera::default();
    t.autoescape_on(vec!["html"]);
    register_image_functions(&mut t);
    for (name, body) in TEMPLATES {
        t.add_raw_template(name, body)
            .map_err(|e| format!("template {name}: {e}"))?;
    }
    Ok(t)
}

// What: menu pages and form paths.
// Why: templates never spell a path.
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

const ROUTES: [(&str, &str); 45] = [
    ("hamster_add", "/cachehamster/add"),
    ("hamster_start", "/cachehamster/start"),
    ("hamster_cancel", "/cachehamster/cancel"),
    ("hamster_remove", "/cachehamster/remove"),
    ("hamster_logout", "/cachehamster/logout"),
    ("hamster_api", "/api/cachehamster/{op}"),
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
    ("tsig_rotate", "/domains/tsig-rotate"),
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
    (
        "service_action",
        "/api/service/{container}/{program}/{action}",
    ),
];

// What: command line uses besides the server.
// Why: setup.sh and the healthcheck need them.
// From: Issue #1683 | PR #1858
async fn command(s: &Settings, args: &[String]) -> Option<Result<(), String>> {
    match args.first().map(String::as_str) {
        Some("zone-snapshots") => Some(zone_snapshots_cli(s)),
        Some("zone-rollback") => Some(match &args[1..] {
            [zone, id] => rollback(s, zone, id).await.map(|()| {
                println!("{}", json!({"restored": zone, "snapshot": id}));
            }),
            _ => Err("usage: zone-rollback <zone> <snapshot-id>".into()),
        }),
        Some("healthcheck") => Some(healthcheck(s).await),
        Some("render-dns") => Some(render_dns(s)),
        _ => None,
    }
}

// What: write the dns configs once, then exit.
// Why: a secondary has no ui server to render them.
// From: Issue #1683 | PR #1980
fn render_dns(s: &Settings) -> Result<(), String> {
    let sec = secrets(s)?;
    let serial = u32::try_from(clock::unix_secs() % u64::from(u32::MAX)).unwrap_or(1);
    let files = render::dns_only(s, &sec, serial).map_err(|e| e.join("; "))?;
    let changed = write_files(s, &files)?;
    println!(
        "{}",
        json!({"written": files.len(), "changed": changed.len()})
    );
    Ok(())
}

async fn healthcheck(s: &Settings) -> Result<(), String> {
    let url = format!(
        "http://{}:{}/healthz",
        s.text("LOOPBACK_BIND_IP")?,
        s.uint("UI_PORT")?
    );
    let limit = Duration::from_secs(s.uint("HTTP_CLIENT_TIMEOUT")?);
    http::probe(&url, None, limit).await
}

// What: all ui routes plus auth and headers.
// Why: one place lists every page and action.
fn router(app: Arc<App>) -> Router {
    let pages = Router::new()
        .route("/", get(dashboard))
        .route("/setup", get(setup))
        .route("/setup/save", post(save))
        .route("/setup/password", post(password))
        .route("/logs", get(logs))
        .route("/logs/save", post(logs_save))
        .route("/cachehamster", get(cachehamster))
        .route("/cachehamster/{op}", post(hamster_action))
        .route("/api/cachehamster/{op}", post(hamster_api))
        .route("/domains", get(domains))
        .route("/domains/{op}", post(dns_action))
        .route("/dhcp", get(dhcp))
        .route("/dhcp/check", post(dhcp_check))
        .route("/dhcp/{op}", post(dhcp_action))
        .route("/stats", get(stats))
        .route("/stats/graph/{name}", get(graph))
        .route("/api/secondary/{name}/{op}", post(secondary_action))
        .route("/api/status", get(status))
        .route("/api/container/{service}", post(container_state))
        .route("/api/restart-ui", post(restart_ui))
        .route(
            "/api/service/{container}/{program}/{action}",
            post(service_action),
        )
        .layer(axum::middleware::from_fn_with_state(app.clone(), auth));
    Router::new()
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
        .layer(axum::middleware::from_fn_with_state(app.clone(), secure))
        .with_state(app)
}

// What: security headers on every answer, from SOT.
// Why: no framing, no sniffing, no foreign scripts.
// From: Issue #1683 | PR #1980
async fn secure(State(app): Shared, req: Request, next: Next) -> Response {
    let s = app.settings();
    let https = req
        .headers()
        .get("x-forwarded-proto")
        .is_some_and(|v| v.as_bytes().eq_ignore_ascii_case(b"https"));
    let mut res = next.run(req).await;
    for (name, key) in [
        (header::CONTENT_SECURITY_POLICY, "UI_CSP"),
        (header::X_FRAME_OPTIONS, "UI_FRAME_OPTIONS"),
        (header::REFERRER_POLICY, "UI_REFERRER_POLICY"),
        (header::X_CONTENT_TYPE_OPTIONS, "UI_CONTENT_TYPE_OPTIONS"),
        (header::STRICT_TRANSPORT_SECURITY, "UI_HSTS"),
    ] {
        if name == header::STRICT_TRANSPORT_SECURITY && !https {
            continue;
        }
        match s.text(key).map(|v| header::HeaderValue::from_str(&v)) {
            Ok(Ok(v)) => {
                res.headers_mut().insert(name, v);
            }
            Ok(Err(e)) => eprintln!("ui: {key}: {e}"),
            Err(e) => eprintln!("ui: {e}"),
        }
    }
    res
}

// What: entry: a command or the web server.
// Why: one binary for ui, setup.sh, healthcheck.
// From: Issue #1683 | PR #1858
#[tokio::main]
async fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("hash-password") {
        return hash_password();
    }
    let saved = process_env(SETTINGS_FILE_ENV).map(PathBuf::from);
    let s = Settings::load(&process_env, saved.as_deref())?;
    if let Some(done) = command(&s, &args).await {
        return done;
    }
    let dir = PathBuf::from(s.text("SECRETS_DIR")?);
    let key =
        secret::resolve(None, &dir, "UI_SESSION_KEY", owner_keep()).map_err(|e| e.to_string())?;
    let app = Arc::new(App {
        docker: docker::Api::new(&s.text("DOCKER_ENDPOINT")?)?,
        tera: templates()?,
        settings: RwLock::new(s.clone()),
        saved,
        session_key: secret::key_bytes(&key)?,
    });
    // What: render every config once at start.
    // Why: owners read the config volume; it starts empty.
    // From: Issue #1683 | PR #1980
    match apply_all(&app, &s, &s).await {
        Ok(lines) => lines.iter().for_each(|l| eprintln!("ui: start: {l}")),
        Err(e) => eprintln!("ui: start render: {e}"),
    }
    tokio::spawn(sampler(app.clone()));
    tokio::spawn(flush_on_transfer(app.clone()));
    let listen = format!("{}:{}", s.text("UI_LISTEN")?, s.uint("UI_PORT")?);
    let sock = tokio::net::TcpListener::bind(&listen)
        .await
        .map_err(|e| format!("{listen}: {e}"))?;
    axum::serve(sock, router(app))
        .await
        .map_err(|e| e.to_string())
}
