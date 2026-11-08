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
use lancache_ng::{access, apply, docker, fs, http, human, render, secret};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, RwLock};
use std::time::Duration;
use tera::{Context, Tera};

// What: env name of the saved settings file.
// Why: needed before any setting can be read.
// From: Issue #1683 | PR #1858
const SETTINGS_FILE_ENV: &str = "LANCACHE_SETTINGS_FILE";

// What: CLI word of the one-shot DHCP probe.
// Why: the ui and setup.sh start the same command.
// From: Issue #1683 | PR #1985
const DHCP_PROBE_CMD: &str = "dhcp-probe";

// What: page keys read from env, not from specs.
// Why: compose sets them; no schema row exists.
// From: Issue #1683 | PR #1980
const ENV_ONLY_KEYS: [&str; 2] = ["IP_HTTP", "LANCACHE_IMAGE_CHANNEL"];

// What: read the files of one mounted folder.
// Why: DoMe 07.11.: page edits need no image build.
// From: Issue #1683 | PR #1991
fn folder(dir: &str, ext: &str) -> Result<Vec<(String, String)>, String> {
    let err = |e: std::io::Error| format!("{dir}: {e}");
    let mut out = Vec::new();
    for entry in std::fs::read_dir(dir).map_err(err)? {
        let path = entry.map_err(err)?.path();
        if path.extension().and_then(|e| e.to_str()) != Some(ext) {
            continue;
        }
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        let body = std::fs::read_to_string(&path).map_err(err)?;
        out.push((name.to_string(), body));
    }
    if out.is_empty() {
        return Err(format!("{dir}: no .{ext} files"));
    }
    out.sort();
    Ok(out)
}

// What: one static file of the mounted folder.
// Why: css and icons change without an image build.
// From: Issue #1683 | PR #1991
fn static_file(dir: &str, name: &str) -> Result<&'static [u8], String> {
    let path = std::path::Path::new(dir).join(name);
    let body = std::fs::read(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(Box::leak(body.into_boxed_slice()))
}

// What: cookie of the language the user picked.
// Why: the selector sets it; the ui reads it.
// From: Issue #1683 | PR #1980
const LANG_COOKIE: &str = "lc_lang";

// What: texts per language: code, key, text.
// Why: page() picks one map per request.
// From: Issue #1683 | PR #1980
type Texts = BTreeMap<String, BTreeMap<String, String>>;

// What: the language files, read once at start.
// Why: form errors outside page() need them too.
// From: Issue #1683 | PR #1980
static TEXTS: std::sync::OnceLock<Texts> = std::sync::OnceLock::new();

// What: all languages; empty before the start read.
// Why: one access path for page(), tr() and the layer.
// From: Issue #1683 | PR #1980
fn all_texts() -> &'static Texts {
    static EMPTY: Texts = Texts::new();
    TEXTS.get().unwrap_or(&EMPTY)
}

// What: one text in the request language.
// Why: form errors speak the language of the page.
// From: Issue #1683 | PR #1980
fn tr(key: &str) -> String {
    let code = LANG.try_with(Clone::clone).unwrap_or_default();
    let all = all_texts();
    all.get(&code)
        .or_else(|| all.values().next())
        .and_then(|m| m.get(key))
        .cloned()
        .unwrap_or_else(|| key.to_string())
}

tokio::task_local! {
    // What: language of the request being served.
    // Why: page() has no headers; the layer sets it.
    // From: Issue #1683 | PR #1980
    static LANG: String;
}

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
    cache_used: AtomicU64,
    // What: true once every config was rendered.
    // Why: dns and proxy wait for these files.
    // From: Issue #1683 | PR #1858
    rendered: AtomicBool,
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
        // What: every spec key, unset ones as empty text.
        // Why: templates read optional keys unguarded.
        // From: Issue #1683 | PR #1980
        let mut values: BTreeMap<String, String> = s
            .specs()
            .filter(|sp| !matches!(sp.kind, config::Kind::Secret))
            .map(|sp| (sp.key.clone(), String::new()))
            .collect();
        values.extend(s.texts().map(|(k, v)| (k.clone(), v)));
        // What: env-only keys the pages show.
        // Why: they live in env, not in the spec list.
        // From: Issue #1683 | PR #1980
        for key in ENV_ONLY_KEYS {
            let val = s.text(key).unwrap_or_default();
            values.entry(key.into()).or_insert(val);
        }
        let login = !s.text("UI_PASSWORD_HASH").unwrap_or_default().is_empty();
        // What: page and route paths by short name.
        // Why: templates name the SOT key without prefix.
        // From: Issue #1683
        let paths = |prefix: &str| -> BTreeMap<String, String> {
            s.texts()
                .filter_map(|(k, v)| k.strip_prefix(prefix).map(|n| (n.to_ascii_lowercase(), v)))
                .collect()
        };
        let (pages, routes) = (paths("UI_PAGE_"), paths("UI_ROUTE_"));
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
        ctx.insert("ui_service", &s.text("UI_SERVICE").unwrap_or_default());
        ctx.insert("watchdog_refresh_seconds", &s.uint("UI_STATUS_REFRESH")?);
        ctx.insert("warnings", &s.warnings);
        // What: texts of the request language.
        // Why: templates hold keys; scripts get the same.
        // From: Issue #1683 | PR #1980
        let code = LANG
            .try_with(Clone::clone)
            .unwrap_or_else(|_| s.text("UI_LANG_DEFAULT").unwrap_or_default());
        let empty = BTreeMap::new();
        let t = all_texts().get(&code).unwrap_or(&empty);
        let langs: Vec<(&str, &str)> = all_texts()
            .iter()
            .map(|(c, m)| (c.as_str(), m.get("lang_name").map_or(c.as_str(), |n| n)))
            .collect();
        let json = serde_json::to_string(t).map_err(|e| e.to_string())?;
        ctx.insert("t", t);
        ctx.insert("t_json", &json.replace("</", "<\\/"));
        ctx.insert("lang", &code);
        ctx.insert("langs", &langs);
        let html = self.tera.render(name, &ctx).map_err(|e| {
            eprintln!("ui: template {name}: {e:?}");
            tr("err_template").replace("{name}", name)
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
            _ => Err(Fail(StatusCode::FORBIDDEN, tr("err_csrf"))),
        }
    }

    // What: header check for script calls.
    // Why: JSON calls send the token as a header.
    // From: Issue #1683 | PR #1858
    fn check_header(&self, headers: &HeaderMap) -> Result<(), Fail> {
        let given = headers.get("x-csrf-token").and_then(|v| v.to_str().ok());
        match given {
            Some(t) if self.matches(t) => Ok(()),
            _ => Err(Fail(StatusCode::FORBIDDEN, tr("err_csrf"))),
        }
    }
}

// What: session id from the Cookie header.
// Why: browsers may send several Cookie headers.
fn session_cookie(headers: &HeaderMap) -> Option<String> {
    cookie(headers, COOKIE)
}

// What: one cookie value by name.
// Why: session and language cookie share the parse.
// From: Issue #1683 | PR #1980
fn cookie(headers: &HeaderMap, name: &str) -> Option<String> {
    for value in headers.get_all(header::COOKIE) {
        let Ok(text) = value.to_str() else { continue };
        for part in text.split(';') {
            match part.trim().split_once('=') {
                Some((k, v)) if k == name => return Some(v.to_string()),
                _ => {}
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
    // What: zero fill when the cache dir is unreadable.
    // Why: the template always reads cache_pct.
    // From: Issue #1683 | PR #1980
    ctx.insert("cache_pct", &0u64);
    ctx.insert("cache_used_human", &human::bytes(0));

    // What: bar against the set size, not the disk.
    // Why: live test 05.11.: the bar showed disk use.
    // From: Issue #1683 | PR #1980
    let max = gib_bytes(&s.text("CACHE_MAX_GB")?)?;
    let used = app.cache_used.load(Ordering::Relaxed);
    if used != u64::MAX {
        let pct = (used.saturating_mul(100) / max.max(1)).min(100);
        ctx.insert("cache_used_human", &human::bytes(used));
        ctx.insert("cache_pct", &pct);
    }
    // What: the form label names the largest size.
    // Why: DoMe 07.11.: free space was not visible.
    // From: Issue #1069 | PR #1991
    if let Ok(room) = cache_reachable(&s, max, used) {
        ctx.insert("cache_max_gib", &(room >> 30).to_string());
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
        return Err(bad_request(tr("err_passwords_differ")));
    }
    let s = app.settings();
    let min = s.uint("UI_PASSWORD_MIN_LENGTH")?;
    if (new.chars().count() as u64) < min {
        return Err(bad_request(
            tr("err_password_min").replace("{x}", &min.to_string()),
        ));
    }
    let wrong = tr("err_password_wrong");
    let old = s.text("UI_PASSWORD_HASH").unwrap_or_default();
    let hashed = tokio::task::spawn_blocking(move || {
        if !old.is_empty() && !verify(&old, &current) {
            return Err(wrong);
        }
        phc(&new)
    })
    .await
    .map_err(|e| e.to_string())?
    .map_err(bad_request)?;
    let mut change = Fields::from([("UI_PASSWORD_HASH".to_string(), hashed)]);
    // What: the user name is set in the same form.
    // Why: DoMe 07.11.: any name, not only the default.
    // From: Issue #1683 | PR #1985
    let user = get("user").trim().to_string();
    if !user.is_empty() {
        change.insert("UI_USER".to_string(), user);
    }
    let back = app.settings().text("UI_PAGE_SETUP")?;
    finish(commit(&app, change).await, &back)
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
    let before = std::fs::read(&path).ok();
    config::store(&path, &old, &updates)?;
    let new = Settings::load(&process_env, Some(&path))?;
    // What: a value that cannot render is not kept.
    // Why: live 05.11.: a looping upstream was saved.
    // From: Issue #1683 | PR #1980
    let check = secrets(&new).and_then(|sec| render::all(&new, &sec).map_err(|e| e.join("; ")));
    if let Err(e) = check {
        // What: a refused save is logged, not only shown.
        // Why: DoMe 07.11.: an error left no trace in logs.
        // From: Issue #1683 | PR #1991
        eprintln!("ui: save refused: {e}");
        if let Some(b) = before {
            std::fs::write(&path, b).map_err(|w| format!("{e}; old file not restored: {w}"))?;
        }
        return Err(e);
    }
    for line in apply_all(app, &old, &new, true).await? {
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
    cache_room(
        &app.settings(),
        &form,
        app.cache_used.load(Ordering::Relaxed),
    )?;
    if let Some(d) = form.get("DHCP_DOMAIN")
        && !lancache_ng::dns::is_dns_name(d, false, false)
    {
        return Err(bad_request(tr("err_no_domain").replace("{x}", d)));
    }
    // What: each upstream entry is checked before save.
    // Why: live 06.11. + threat model G3: no self loop.
    // From: Issue #1683 | PR #1985
    let own = lancache_ng::recursor_conf::own_ips(&app.settings());
    for key in ["DNS_UPSTREAM_SERVERS", "NGINX_UPSTREAM_RESOLVER"] {
        for raw in form
            .get(key)
            .map(|v| config::list_items(v))
            .into_iter()
            .flatten()
        {
            lancache_ng::recursor_conf::upstream_entry(key, raw, &own).map_err(bad_request)?;
        }
    }

    // What: back to the page that sent the form.
    // Why: live test: dashboard forms ended on /setup.
    // From: Issue #1683 | PR #1980
    let back = form
        .get("back")
        .filter(|b| b.starts_with('/') && !b.starts_with("//"))
        .cloned()
        .map_or_else(|| app.settings().text("UI_PAGE_SETUP"), Ok)?;
    let before = lancache_ng::dns::managed_zones(&app.settings()).unwrap_or_default();
    let result = commit(&app, form).await;
    if result.is_ok() {
        drop_old_zones(&app.settings(), &before).await;
    }
    finish(result, &back)
}

// What: remove zones a new LAN domain left behind.
// Why: live test 05.11.: home.lan stayed after going back.
// From: Issue #1683 | PR #1980
async fn drop_old_zones(s: &Settings, before: &[String]) {
    let Ok(now) = lancache_ng::dns::managed_zones(s) else {
        return;
    };
    if s.text("DNS_REPLICATION_ROLE").unwrap_or_default() == "secondary" {
        return;
    }
    let Ok(api) = pdns_api(s) else { return };
    for zone in before.iter().filter(|z| !now.contains(z)) {
        // What: only zones without own records go.
        // Why: a record the user added is never lost.
        // From: Issue #1683 | PR #1980
        let own = match api.rrsets(zone).await {
            Ok(sets) => sets
                .iter()
                .any(|r| !matches!(r["type"].as_str(), Some("SOA" | "NS"))),
            Err(_) => continue,
        };
        let done = if own {
            Err(tr("err_zone_has_records"))
        } else {
            api.delete_zone(zone).await
        };
        match done {
            Ok(()) => eprintln!("ui: zone {zone} removed"),
            Err(e) => eprintln!("ui: zone {zone} kept: {e}"),
        }
    }
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
            // What: drop "host program: " ahead.
            // Why: the program has its own column.
            // From: Issue #1683 | PR #1980
            let lead = format!(" {p}: ");
            let text = text.split_once(lead.as_str()).map_or(text, |(_, m)| m);
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
    // What: every folder the store holds, plus the list.
    // Why: DoMe 05.11.: page empty; the store names differ.
    // From: Issue #1683 | PR #1980
    let mut names = programs.clone();
    if let Ok(dirs) = std::fs::read_dir(&root) {
        for d in dirs.flatten().filter(|d| d.path().is_dir()) {
            let n = d.file_name().to_string_lossy().into_owned();
            if !names.contains(&n) {
                names.push(n);
            }
        }
    }
    let hosts = names.clone();
    let lines = tokio::task::spawn_blocking(move || newest_lines(&root, &names, max, chunk))
        .await
        .map_err(|e| e.to_string())?;
    let switches: Vec<Value> = programs
        .iter()
        .map(|p| json!({"program": p, "on": !muted.contains(p)}))
        .collect();
    let mut ctx = Context::new();
    ctx.insert("syslog_logs", &lines);
    ctx.insert("syslog_hosts", &hosts);
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
    let back = format!("{}#syslog", app.settings().text("UI_PAGE_LOGS")?);
    finish(commit(&app, change).await, &back)
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
    Ok(lancache_ng::dns::canonical_zone(&s.text("DHCP_DOMAIN")?))
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
    Ok(lancache_ng::snapshot::Store {
        dir,
        keep,
        owner,
        file: None,
    })
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
            let created = created_unix(&store.path(&id))?;
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
// Why: PATCH restores; a new snapshot records it.
// From: Issue #1683 | PR #1980
async fn rollback(s: &Settings, zone: &str, id: &str) -> Result<(), String> {
    if !snapshot_zones(s)?.iter().any(|z| z == zone) {
        return Err(tr("err_zone_no_snapshots").replace("{zone}", zone));
    }
    let body = zone_store(s, zone)?.read(id)?;
    let rows: Vec<Value> = serde_json::from_slice(&body).map_err(|e| e.to_string())?;
    let api = pdns_api(s)?;
    api.restore(zone, &rows).await?;
    snapshot(s, &api, zone).await?;
    flush_zone(s, zone).await
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
        // What: PTR rows only when the LAN zone answers.
        // Why: an unreachable API would time out 20 times.
        // From: Issue #1683 | PR #1980
        Ok(api) => match api.rrsets(&lan).await {
            Ok(rows) => {
                lan_rows = rows;
                ptr = ptr_rows(&s, &api).await;
            }
            Err(e) => ctx.insert("domain_error_message", &e),
        },
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
    // What: setup.sh from the branch of this channel.
    // Why: a nightly primary must not hand out master.
    // From: Issue #1683 | PR #1980
    let nightly = process_env("LANCACHE_IMAGE_CHANNEL").as_deref() == Some("nightly");
    let (url_key, ref_key) = if nightly {
        ("SETUP_SCRIPT_URL_NIGHTLY", "SETUP_GIT_REF_NIGHTLY")
    } else {
        ("SETUP_SCRIPT_URL", "SETUP_GIT_REF")
    };
    ctx.insert("setup_script_url", &s.text(url_key)?);
    ctx.insert("setup_git_ref", &s.text(ref_key)?);
    ctx.insert("primary_ip", &s.text("IP_HTTP")?);
    // What: HTTPS proxy IP when it is a second LAN IP.
    // Why: the copied command then sets the HTTPS DNS bind.
    // From: Issue #1683 | PR #1980
    let https = s.text("IP_HTTPS").unwrap_or_default();
    let own = !https.is_empty() && https != s.text("IP_HTTP")? && !https.starts_with("127.");
    // What: no HTTPS part while HTTPS is off.
    // Why: the field woke HTTPS that was off.
    // From: Issue #1683 | PR #1980
    let own = own && s.flag("HTTPS_ENABLED").unwrap_or(false);
    ctx.insert("primary_ip_https", if own { https.as_str() } else { "" });

    // What: UI address on the LAN when none is set.
    // Why: live test: an empty --primary broke the command.
    // From: Issue #1683 | PR #1980
    let mut url = s.text("UI_PUBLIC_URL").unwrap_or_default();
    if url.is_empty() {
        url = format!("http://{}:{}", s.text("IP_HTTP")?, s.uint("UI_PORT")?);
    }
    ctx.insert("primary_url", &url);
    ctx.insert("lan_record_types", &s.list("DNS_LAN_RECORD_TYPES"));
    ctx.insert("record_ttl_default", &s.uint("DNS_RECORD_TTL")?);
    ctx.insert("ttl_max", &s.uint("DNS_RECORD_TTL_MAX")?);
    ctx.insert("aaaa_filter_enabled", &s.flag("DNS_FILTER_AAAA")?);
    ctx.insert("query_log_enabled", &s.flag("DNS_QUERY_LOG")?);
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

// What: one DNS page form, chosen by its SOT key.
// Why: all DNS forms share one handler.
// From: Issue #1683
async fn dns_action(
    State(app): Shared,
    Extension(csrf): Extension<Csrf>,
    Extension(Op(op)): Extension<Op>,
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
    let result = match op {
        "UI_ROUTE_DNS_ADD" if lancache_ng::dns::cdn_entry(&domain).is_none() => {
            Err(format!("{domain:?} is no valid domain entry"))
        }
        "UI_ROUTE_DNS_ADD" => {
            commit(&app, list_change(&s, "CDN_CUSTOM_DOMAINS", &domain, true)).await
        }
        "UI_ROUTE_DNS_REMOVE" => {
            commit(&app, list_change(&s, "CDN_CUSTOM_DOMAINS", &domain, false)).await
        }
        "UI_ROUTE_DNS_TOGGLE" => {
            commit(&app, list_change(&s, "CDN_DISABLED_DOMAINS", &domain, !on)).await
        }
        "UI_ROUTE_AAAA_FILTER" => commit(&app, single_field("DNS_FILTER_AAAA", on)).await,
        "UI_ROUTE_QUERY_LOG" => commit(&app, single_field("DNS_QUERY_LOG", on)).await,
        "UI_ROUTE_DDNS_UNSIGNED" => commit(&app, single_field("DDNS_ALLOW_UNSIGNED", on)).await,
        "UI_ROUTE_LAN_ADD" | "UI_ROUTE_LAN_REMOVE" => {
            record(&s, op == "UI_ROUTE_LAN_ADD", &get).await
        }
        "UI_ROUTE_PTR_ADD" | "UI_ROUTE_PTR_REMOVE" => ptr(&s, op == "UI_ROUTE_PTR_ADD", &get).await,
        "UI_ROUTE_ZONE_ROLLBACK" => rollback(&s, &get("zone"), &get("snapshot_id")).await,
        "UI_ROUTE_TSIG_ROTATE" => rotate_tsig(&app).await,
        _ => Err(tr("err_unknown_dns_action").replace("{op}", op)),
    };
    finish(result, &s.text("UI_PAGE_DOMAINS")?)
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

// What: content in the form PowerDNS stores.
// Why: TXT needs quotes; target names end in a dot.
// From: Issue #1683 | PR #1980
fn canonical(kind: &str, c: &str) -> String {
    let dot = |n: &str| {
        if n.ends_with('.') {
            n.to_string()
        } else {
            format!("{n}.")
        }
    };
    match kind {
        "TXT" if !c.starts_with('"') => format!("\"{}\"", c.replace('"', "\\\"")),
        "CNAME" => dot(c),
        "MX" | "SRV" => match c.rsplit_once(' ') {
            Some((head, target)) => format!("{head} {}", dot(target)),
            None => c.to_string(),
        },
        _ => c.to_string(),
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
        return Err(tr("err_record_type").replace("{kind}", &kind));
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
            .map(|c| canonical(&kind, c))
            .collect();
        let max = s.uint("DNS_RECORD_TTL_MAX")?;
        ttl = get("ttl").parse::<u32>().unwrap_or(0);
        if ttl == 0 || u64::from(ttl) > max {
            return Err(tr("err_ttl_range").replace("{max}", &max.to_string()));
        }
    }
    let api = pdns_api(s)?;
    api.set_rrset(&zone, &name, &kind, ttl, &contents).await?;
    snapshot(s, &api, &zone).await?;
    flush_zone(s, &zone).await?;
    // What: PTR for each A address when ticked.
    // Why: DoMe 31.10.: PTR from the LAN entries.
    // From: Issue #1683 | PR #1980
    if add && kind == "A" && get("ptr") == "1" {
        let host = vec![format!("{}.", name.trim_end_matches('.'))];
        for ip in &contents {
            let Ok(rev) = reverse_name(ip) else { continue };
            let Some(rz) = reverse_zone(s, &rev) else {
                continue;
            };
            api.set_rrset(&rz, &rev, "PTR", ttl, &host).await?;
            snapshot(s, &api, &rz).await?;
            flush_zone(s, &rz).await?;
        }
    }
    Ok(())
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
    snapshot(s, &api, &zone).await?;
    flush_zone(s, &zone).await
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
    secret::resolve(process_env(name).as_deref(), &dir, name, owner_keep())
        .map_err(|e| e.to_string())
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
    #[serde(default)]
    address: Option<String>,
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
        // What: the zones the primary serves.
        // Why: the secondary pulls each one by AXFR.
        // From: Issue #1683
        "zones": lancache_ng::dns::managed_zones(s)?,
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
async fn register(
    State(app): Shared,
    axum::extract::ConnectInfo(peer): axum::extract::ConnectInfo<std::net::SocketAddr>,
    axum::Json(r): axum::Json<Register>,
) -> Page {
    let s = app.settings();
    let token = registration_token(&s).map_err(|e| Fail(StatusCode::SERVICE_UNAVAILABLE, e))?;
    if !secret::equal(&r.token, &token) {
        return Err(Fail(StatusCode::UNAUTHORIZED, "wrong token".into()));
    }
    let mut list = secondaries(&s);
    // What: sent address, else stored, else the peer IP.
    // Why: re-registration keeps a manual override.
    // From: Issue #1683 | PR #1858
    let stored = list
        .iter()
        .find(|(n, _)| *n == r.name)
        .map(|(_, a)| a.clone());
    let address = r
        .address
        .or(stored)
        .unwrap_or_else(|| peer.ip().to_string());
    if !valid_peer_name(&s, &r.name)? || !is_ip(&address) {
        return Err(bad_request("name or address is not valid"));
    }
    list.retain(|(n, _)| *n != r.name);
    list.push((r.name.clone(), address));
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
    axum::extract::Path(name): axum::extract::Path<String>,
    Extension(Op(op)): Extension<Op>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Page {
    csrf.check_header(&headers)?;
    let s = app.settings();
    let mut list = secondaries(&s);
    let Some(at) = list.iter().position(|(n, _)| *n == name) else {
        return Err(Fail(StatusCode::NOT_FOUND, "no such secondary".into()));
    };
    match op {
        "UI_ROUTE_SECONDARY" => {
            list.remove(at);
            store_secondaries(&app, &list).await?;
            rotate_tsig(&app).await?;
            Ok(Redirect::to(&s.text("UI_PAGE_DOMAINS")?).into_response())
        }
        "UI_ROUTE_SECONDARY_ROTATE" => {
            Ok(axum::Json(json!({"token": renew_token(&s)?})).into_response())
        }
        "UI_ROUTE_SECONDARY_ADDRESS" => {
            let a: Address = serde_json::from_slice(&body)
                .map_err(|_| bad_request("body must be {\"address\": ...}"))?;
            if !is_ip(&a.address) {
                return Err(bad_request("no IP address"));
            }
            list[at].1 = a.address;
            store_secondaries(&app, &list).await.map_err(bad_request)?;
            Ok(StatusCode::NO_CONTENT.into_response())
        }
        "UI_ROUTE_SECONDARY_HEALTH" => {
            Ok(axum::Json(secondary_health(&s, &list[at].1).await).into_response())
        }
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
        Ok((_, r)) if r.is_none() => {
            json!({"status": "missing", "detail": "zone not on secondary"})
        }
        Ok(_) => json!({"status": "error", "detail": "zone not on primary"}),
        Err(e) => json!({"status": "unreachable", "detail": e}),
    }
}

// What: flush recursor caches when a serial moves.
// Why: UI, DDNS, AXFR and rollback all bump it.
// From: Issue #1683 | PR #1980
async fn flush_on_transfer(app: Arc<App>) {
    let mut seen: BTreeMap<String, u32> = BTreeMap::new();
    // What: an error only after the grace time.
    // Why: DoMe 05.11.: a planned dns restart logged one.
    // From: Issue #1683 | PR #1980
    let mut down: Option<std::time::Instant> = None;
    let mut logged = false;
    loop {
        let s = app.settings();
        let wait = s.uint("UI_FLUSH_CHECK_SECONDS").unwrap_or(1).max(1);
        let grace = s.uint("UI_FLUSH_GRACE_SECONDS").unwrap_or(0);
        match flush_round(&s, &mut seen).await {
            Err(e) => {
                let since = *down.get_or_insert_with(std::time::Instant::now);
                if !logged && since.elapsed().as_secs() >= grace {
                    eprintln!("ui: cache flush fails for {grace} s: {e}");
                    logged = true;
                }
            }
            Ok(()) => {
                if logged {
                    eprintln!("ui: cache flush works again");
                }
                (down, logged) = (None, false);
            }
        }
        tokio::time::sleep(Duration::from_secs(wait)).await;
    }
}

// What: clears one zone in every recursor cache.
// Why: an edit shows at once, not after the poll.
// From: Issue #1683 | PR #1980
async fn flush_zone(s: &Settings, zone: &str) -> Result<(), String> {
    let key = secrets(s)?.recursor_api_key;
    let client = http::client(s)?;
    for url in s.list("RECURSOR_API_URLS") {
        let r = lancache_ng::pdns::Api::new(client.clone(), &url, &key);
        r.flush(zone, true).await?;
    }
    Ok(())
}

// What: clears recursor cache for changed zones.
// Why: recursors would serve old answers until TTL.
async fn flush_round(s: &Settings, seen: &mut BTreeMap<String, u32>) -> Result<(), String> {
    for zone in pdns_api(s)?.zones().await? {
        // What: note a serial only after its flush worked.
        // Why: a flush during a dns restart must retry.
        // From: Issue #1683 | PR #1980
        let before = seen.get(&zone.name).copied();
        if before.is_some_and(|b| b != zone.serial) {
            flush_zone(s, &zone.name).await?;
        }
        seen.insert(zone.name.clone(), zone.serial);
    }
    Ok(())
}

// What: Kea control agent of this stack.
// Why: host from env; basic auth with the stack token.
// From: Issue #1683 | PR #1980
fn kea_api(s: &Settings) -> Result<lancache_ng::kea::Api, String> {
    let url = format!(
        "http://{}:{}/",
        s.text("DHCP_API_HOST")?,
        s.uint("KEA_CTRL_PORT")?
    );
    let token = secrets(s)?.kea_ctrl_token;
    Ok(lancache_ng::kea::Api::new(
        http::client(s)?,
        &url,
        &s.text("KEA_CTRL_USER")?,
        &token,
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
        "domain": option_data(sn, "domain-name"),
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
    let dir = PathBuf::from(s.text("KEA_CONFIG_SNAPSHOT_DIR")?);
    let keep = usize::try_from(s.uint("KEA_SNAPSHOT_KEEP")?).map_err(|e| e.to_string())?;
    Ok(lancache_ng::snapshot::Store {
        dir,
        keep,
        owner: owner_keep(),
        file: Some(s.text("KEA_CONFIG_SNAPSHOT_FILE")?),
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
    ctx.insert("dhcp_upstream_dhcp_ip", &opt("UPSTREAM_DHCP_IP"));
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
        let created = created_unix(&store.path(&id))?;
        snaps.push(json!({"id": id, "created_unix": created}));
    }
    ctx.insert("kea_snapshots", &snaps);
    app.page("dhcp.html", ctx, &csrf)
}

// What: the main subnet form also saves settings.
// Why: DoMe 08.11.: settings are the only source.
// From: Issue #1683
async fn main_subnet(
    app: &App,
    s: &Settings,
    op: &str,
    get: &(dyn Fn(&str) -> String + Sync),
) -> Result<(), String> {
    let main = s.uint("DHCP_SUBNET_ID")?.to_string();
    let hit = get("id") == main;
    if hit && op == "UI_ROUTE_SUBNET_REMOVE" {
        return Err(tr("err_main_subnet_remove"));
    }
    kea_action(s, op, get).await?;
    if !(hit && op == "UI_ROUTE_SUBNET_UPDATE") {
        return Ok(());
    }
    let dns: Vec<String> = [get("dns_primary"), get("dns_secondary")]
        .into_iter()
        .filter(|d| !d.is_empty())
        .collect();
    let mut f = Fields::new();
    for (key, field) in [
        ("DHCP_SUBNET", "subnet"),
        ("DHCP_RANGE_START", "pool_start"),
        ("DHCP_RANGE_END", "pool_end"),
        ("DHCP_GATEWAY", "gateway"),
        ("DHCP_DOMAIN", "domain"),
        ("DHCP_NTP_SERVERS", "ntp_servers"),
    ] {
        f.insert(key.into(), get(field));
    }
    if !get("lease_time").is_empty() {
        f.insert("DHCP_LEASE_TIME".into(), get("lease_time"));
    }
    f.insert("DHCP_DNS_SERVERS".into(), dns.join(" "));
    commit(app, f).await
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
    found.ok_or_else(|| tr("err_no_subnet").replace("{id}", &id.to_string()))
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
        "UI_ROUTE_SUBNET_ADD" => {
            kea_edit(s, |l| {
                let next = l.iter().filter_map(|x| x["id"].as_u64()).max().unwrap_or(0) + 1;
                l.push(subnet_from(get, next, None));
                Ok(())
            })
            .await
        }
        "UI_ROUTE_SUBNET_UPDATE" => {
            let id = num("id")?;
            kea_edit(s, |l| {
                let sn = subnet_mut(l, id)?;
                *sn = subnet_from(get, id, Some(&sn.clone()));
                Ok(())
            })
            .await
        }
        "UI_ROUTE_SUBNET_REMOVE" => {
            let id = num("id")?;
            kea_edit(s, |l| {
                l.retain(|x| x["id"].as_u64() != Some(id));
                Ok(())
            })
            .await
        }
        "UI_ROUTE_SUBNET_OPTION_ADD" | "UI_ROUTE_SUBNET_OPTION_REMOVE" => {
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
                if op == "UI_ROUTE_SUBNET_OPTION_ADD" {
                    opts.push(json!({"code": code, "data": data}));
                }
                sn["option-data"] = opts.into();
                Ok(())
            })
            .await
        }
        "UI_ROUTE_STATIC_ADD" | "UI_ROUTE_STATIC_REMOVE" => {
            let id = num("subnet_id")?;
            let (mac, ip, host) = (get("mac"), get("ip"), get("hostname"));
            kea_edit(s, |l| {
                let sn = subnet_mut(l, id)?;
                let mut hosts = sn["reservations"].as_array().cloned().unwrap_or_default();
                hosts.retain(|r| r["hw-address"].as_str() != Some(mac.as_str()));
                if op == "UI_ROUTE_STATIC_ADD" {
                    hosts.push(json!({"hw-address": mac, "ip-address": ip, "hostname": host}));
                }
                sn["reservations"] = hosts.into();
                Ok(())
            })
            .await
        }
        "UI_ROUTE_LEASE_RELEASE" => kea_api(s)?.release(&get("ip")).await,
        "UI_ROUTE_KEA_ROLLBACK" => {
            let body = kea_store(s)?.read(&get("snapshot_id"))?;
            let cfg: Value = serde_json::from_slice(&body).map_err(|e| e.to_string())?;
            kea_api(s)?.set_config(cfg).await
        }
        _ => Err(tr("err_unknown_dhcp_action").replace("{op}", op)),
    }
}

// What: one DHCP page form, chosen by op.
// Why: SOT keys via commit; Kea via kea_action.
// From: Issue #1683 | PR #1858
async fn dhcp_action(
    State(app): Shared,
    Extension(csrf): Extension<Csrf>,
    Extension(Op(op)): Extension<Op>,
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
    // What: relay without the real server: plain hint.
    // Why: DoMe 07.11.: a newbie got a bare key name.
    // From: Issue #1683 | PR #1991
    let relay = op == "UI_ROUTE_DHCP_MODE" && get("dhcp_mode") == "dnsmasq-relay";
    if relay && s.text("UPSTREAM_DHCP_IP").unwrap_or_default().is_empty() {
        return Err(bad_request(tr("err_relay_needs_upstream")));
    }
    // What: the Kea server needs a network card.
    // Why: live 229: no card, Kea answered nobody.
    // From: Issue #1683
    let cards = get("dhcp_proxy_interface");
    if op == "UI_ROUTE_DHCP_MODE" && get("dhcp_mode") == "kea" && cards.is_empty() {
        return Err(bad_request(tr("err_kea_needs_interface")));
    }
    let result = match op {
        "UI_ROUTE_DHCP_MODE" => {
            let mut f = single_field("DHCP_MODE", get("dhcp_mode"));
            f.insert("DHCP_PROXY_INTERFACE".into(), cards);
            commit(&app, f).await
        }
        "UI_ROUTE_DHCP_DDNS" => commit(&app, single_field("DHCP_DDNS", on)).await,
        "UI_ROUTE_DHCP_PROXY" | "UI_ROUTE_DHCP_RELAY" => {
            commit(&app, dnsmasq_fields(&form, op == "UI_ROUTE_DHCP_PROXY")).await
        }
        _ => main_subnet(&app, &s, op, &get).await,
    };
    finish(result, &s.text("UI_PAGE_DHCP")?)
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
    let (_, limit) = app.limits(&s)?;
    let wait = Duration::from_secs(s.uint("DHCP_PROBE_WAIT_TIMEOUT")?);
    let me = container_of(&app, &s, &s.text("UI_SERVICE")?).await?;
    let bad = |e: docker::Error| Fail(StatusCode::BAD_GATEWAY, e.to_string());
    let own = app.docker.inspect(&me, limit).await.map_err(bad)?;
    // What: the same image, env and volumes as the ui.
    // Why: a bridge never carries LAN broadcasts.
    // From: Issue #1683 | PR #1985
    let spec = json!({
        "Image": own["Config"]["Image"],
        "Env": own["Config"]["Env"],
        "Entrypoint": own["Config"]["Entrypoint"],
        "Cmd": [DHCP_PROBE_CMD],
        "HostConfig": {"NetworkMode": "host", "VolumesFrom": [me]},
    });
    let (code, out) = app.docker.run_once(spec, limit, wait).await.map_err(bad)?;
    let report: Value = serde_json::from_str(&out)
        .map_err(|e| Fail(StatusCode::BAD_GATEWAY, format!("probe exit {code}: {e}")))?;
    Ok(axum::Json(report).into_response())
}

// What: statistics page, one tab per range.
// Why: rrdtool draws; the page shows PNGs.
// From: Issue #1683 | PR #1858
async fn stats(State(app): Shared, Extension(csrf): Extension<Csrf>) -> Page {
    let s = app.settings();
    let mut ctx = Context::new();
    match lancache_ng::rrd::all(&s) {
        Ok(list) => {
            let rows: Vec<Value> = list
                .iter()
                .map(|g| json!({"name": g.name, "title": graph_title(&g.title), "tab": g.tab}))
                .collect();
            ctx.insert("graphs", &rows);
        }
        Err(e) => ctx.insert("stats_error", &e),
    }

    // What: one tab per source, with its origin.
    // Why: DoMe 05.11.: no guessing where values come from.
    // From: Issue #1683 | PR #1980
    let step = s.uint("STATS_STEP").unwrap_or_default();
    ctx.insert("stats_step", &step);
    let snmp = s.text("STATS_SNMP_TARGET").unwrap_or_default();
    let mut tabs = vec![json!({
        "id": lancache_ng::rrd::MACHINE,
        "label": tr("stats_machine"),
        "source": tr("stats_machine_source")
            .replace("{x}", &snmp)
            .replace("{y}", &step.to_string()),
    })];
    // What: no dhcp tab while DHCP_MODE is off.
    // Why: live 249: the tab showed a stopped dhcp.
    // From: Issue #1683
    let off = match (s.text("DHCP_SERVICE"), s.text("DHCP_MODE")) {
        (Ok(svc), Ok(mode)) if mode == "off" => svc,
        _ => String::new(),
    };
    for c in s.list("STATS_CONTAINERS") {
        if c == off {
            continue;
        }
        tabs.push(json!({
            "id": c,
            "label": c,
            "source": tr("stats_container_source")
                .replace("{x}", &c)
                .replace("{y}", &step.to_string()),
        }));
    }
    ctx.insert("tabs", &tabs);
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

// What: graph title in the page language.
// Why: SOT names are English words; key graph_<name>.
// From: Issue #1683 | PR #1980
fn graph_title(title: &str) -> String {
    let key = format!("graph_{}", title.replace(' ', "_"));
    let text = tr(&key);
    if text == key { title.to_string() } else { text }
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
    let all = lancache_ng::rrd::all(&s)?;
    let Some(mut g) = all.into_iter().find(|g| g.name == name) else {
        return Err(Fail(StatusCode::NOT_FOUND, tr("err_no_graph")));
    };
    g.title = graph_title(&g.title);
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

// What: Docker stats of each container into RRD.
// Why: values per container, not only the box.
// From: Issue #1683 | PR #1980
async fn sample_containers(app: &App, s: &Settings) -> Vec<String> {
    let all = match lancache_ng::rrd::container_graphs(s) {
        Ok(v) => v,
        Err(e) => return vec![e],
    };
    let limit = match app.limits(s) {
        Ok((_, l)) => l,
        Err(e) => return vec![e],
    };
    let mut errs = Vec::new();
    for tab in s.list("STATS_CONTAINERS") {
        let got = match container_of(app, s, &tab).await {
            Ok(name) => app
                .docker
                .stats(&name, limit)
                .await
                .map_err(|e| e.to_string()),
            Err(e) => Err(e),
        };
        let v = match got {
            Ok(v) => v,
            Err(e) => {
                errs.push(format!("{tab}: {e}"));
                continue;
            }
        };
        for g in all.iter().filter(|g| g.tab == tab) {
            let vals: Vec<String> = g
                .sources
                .iter()
                .map(|x| lancache_ng::rrd::docker_value(&v, &x.oid))
                .collect();
            let (s2, g2) = (s.clone(), g.clone());
            let put = move || lancache_ng::rrd::store(&s2, &g2, &vals);
            match tokio::task::spawn_blocking(put).await {
                Ok(Ok(())) => {}
                Ok(Err(e)) => errs.push(e),
                Err(e) => errs.push(e.to_string()),
            }
        }
    }
    errs
}

// What: numbers of a PowerDNS statistics list.
// Why: values come as text; prefix names the server.
// From: Issue #1683 | PR #1980
fn add_stats(out: &mut BTreeMap<String, String>, prefix: &str, rows: Vec<(String, String)>) {
    for (name, value) in rows {
        let Ok(n) = value.parse::<u64>() else {
            continue;
        };
        let key = format!("{prefix}:{name}");
        let old = out.get(&key).and_then(|v| v.parse::<u64>().ok());
        out.insert(key, old.unwrap_or(0).saturating_add(n).to_string());
    }
}

// What: program values one sample round reads.
// Why: a program that is off leaves its values unknown.
// From: Issue #1683 | PR #1980
async fn service_values(app: &App, s: &Settings, want: &[String]) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    let has = |p: &str| want.iter().any(|w| w.split(':').next() == Some(p));
    if has("nginx")
        && let Some(v) = fetch_proxy_live(s).await
    {
        for k in ["active", "requests", "waiting"] {
            out.insert(format!("nginx:{k}"), v[k].to_string());
        }
    }
    if has("recursor")
        && let (Ok(sec), Ok(client)) = (secrets(s), http::client(s))
    {
        for url in s.list("RECURSOR_API_URLS") {
            let r = lancache_ng::pdns::Api::new(client.clone(), &url, &sec.recursor_api_key);
            if let Ok(rows) = r.statistics().await {
                add_stats(&mut out, "recursor", rows);
            }
        }
    }
    if has("auth")
        && let Ok(api) = pdns_api(s)
        && let Ok(rows) = api.statistics().await
    {
        add_stats(&mut out, "auth", rows);
    }
    if has("kea")
        && let Ok(api) = kea_api(s)
        && let Ok(all) = api.command("statistic-get-all", None).await
        && let Some(map) = all.as_object()
    {
        for (k, v) in map {
            if let Some(n) = v[0][0].as_f64() {
                out.insert(format!("kea:{k}"), n.to_string());
            }
        }
    }

    // What: host network bytes from the host's net/dev.
    // Why: live test 05.11.: empty via dhcp in mode off.
    // From: Issue #1683 | PR #1980
    if has("host")
        && let Ok(file) = s.text("HOST_NET_DEV_FILE")
        && let Ok(text) = std::fs::read_to_string(&file)
    {
        let skip = s.list("STATS_HOST_IF_SKIP");
        let (mut rx, mut tx) = (0u64, 0u64);
        for line in text.lines() {
            let Some((name, rest)) = line.split_once(':') else {
                continue;
            };
            if skip.iter().any(|p| name.trim().starts_with(p.as_str())) {
                continue;
            }
            let n: Vec<u64> = rest
                .split_whitespace()
                .filter_map(|w| w.parse().ok())
                .collect();
            rx = rx.saturating_add(n.first().copied().unwrap_or(0));
            tx = tx.saturating_add(n.get(8).copied().unwrap_or(0));
        }
        out.insert("host:rx".into(), rx.to_string());
        out.insert("host:tx".into(), tx.to_string());
    }

    // What: chronyc -c tracking: CSV, field 5 = offset.
    // Why: stratum and offset show the time source.
    // From: Issue #1683 | PR #1980
    if has("chrony")
        && let Ok(svc) = s.text("CACHEHAMSTER_SERVICE")
        && let Ok((0, text)) = exec_in(app, s, &svc, &["chronyc", "-c", "tracking"]).await
    {
        let f: Vec<&str> = text.trim().split(',').collect();
        if let (Some(st), Some(off)) = (f.get(2), f.get(4)) {
            out.insert("chrony:stratum".into(), st.to_string());
            out.insert("chrony:offset".into(), off.to_string());
        }
    }
    out
}

// What: program values into RRD each step.
// Why: DoMe 01.11.: PowerDNS, nginx, Kea, chrony.
// From: Issue #1683 | PR #1980
async fn sample_services(app: &App, s: &Settings) -> Vec<String> {
    let all = match lancache_ng::rrd::service_graphs(s) {
        Ok(v) => v,
        Err(e) => return vec![e],
    };
    let want: Vec<String> = all
        .iter()
        .flat_map(|g| g.sources.iter().map(|x| x.oid.clone()))
        .collect();
    let vals = service_values(app, s, &want).await;
    let mut errs = Vec::new();
    for g in all {
        let row: Vec<String> = g
            .sources
            .iter()
            .map(|x| vals.get(&x.oid).cloned().unwrap_or_else(|| "U".into()))
            .collect();
        let s2 = s.clone();
        let put = move || lancache_ng::rrd::store(&s2, &g, &row);
        match tokio::task::spawn_blocking(put).await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => errs.push(e),
            Err(e) => errs.push(e.to_string()),
        }
    }
    errs
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
        let c = s.clone();
        let errs = tokio::task::spawn_blocking(move || sample_all(&c)).await;
        match errs {
            Ok(list) => list.iter().for_each(|e| eprintln!("ui: stats: {e}")),
            Err(e) => eprintln!("ui: stats: {e}"),
        }
        for e in sample_containers(&app, &s).await {
            eprintln!("ui: stats: {e}");
        }
        for e in sample_services(&app, &s).await {
            eprintln!("ui: stats: {e}");
        }
        if let Err(e) = dhcp_stays_off(&app, &s).await {
            eprintln!("ui: dhcp: {e}");
        }
        tokio::time::sleep(Duration::from_secs(step)).await;
    }
}

// What: in mode off a running dhcp is stopped again.
// Why: live 05.11.: compose up started it after the ui.
// From: Issue #1683 | PR #1980
async fn dhcp_stays_off(app: &App, s: &Settings) -> Result<(), String> {
    if s.text("DHCP_MODE")? != "off" {
        return Ok(());
    }
    let service = s.text("DHCP_SERVICE")?;
    let (grace, limit) = app.limits(s)?;
    let list = app.docker.project(&s.text("COMPOSE_PROJECT")?, limit).await;
    let list = list.map_err(|e| e.to_string())?;
    // What: only the stack dhcp, not a "compose run" one.
    // Why: CI kea_rollback runs own Kea; it was stopped.
    // From: Issue #1683
    let running = list.iter().find(|c| {
        c["Labels"][docker::SERVICE_LABEL].as_str() == Some(service.as_str())
            && c["Labels"][docker::ONEOFF_LABEL].as_str() != Some("True")
            && c["State"].as_str() == Some("running")
    });
    let Some(name) = running.and_then(|c| c["Names"][0].as_str()) else {
        return Ok(());
    };
    let name = name.trim_start_matches('/');
    let r = app
        .docker
        .act(name, docker::Action::Stop, grace, limit)
        .await;
    eprintln!("ui: dhcp: mode off, stop {name} {r:?}");
    Ok(())
}

// What: bytes the cache folder holds on disk.
// Why: disk use counts other files on a shared disk.
// From: Issue #1683 | PR #1980
fn dir_bytes(root: &Path) -> u64 {
    use std::os::unix::fs::MetadataExt;
    let mut total = 0u64;
    let mut todo = vec![root.to_path_buf()];
    while let Some(dir) = todo.pop() {
        let Ok(list) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in list.flatten() {
            let Ok(meta) = entry.metadata() else {
                continue;
            };
            if meta.is_dir() {
                todo.push(entry.path());
            } else {
                total = total.saturating_add(meta.blocks().saturating_mul(512));
            }
        }
    }
    total
}

// What: count the cache folder now and then.
// Why: a walk is slow; the dashboard reads the last sum.
// From: Issue #1683 | PR #1980
async fn cache_scanner(app: Arc<App>) {
    loop {
        let s = app.settings();
        let (step, dir) = match (s.uint("CACHE_USAGE_SCAN_SECONDS"), s.text("CACHE_DIR")) {
            (Ok(step), Ok(dir)) => (step, dir),
            (Err(e), _) | (_, Err(e)) => {
                eprintln!("ui: cache count stop: {e}");
                return;
            }
        };
        match tokio::task::spawn_blocking(move || dir_bytes(Path::new(&dir))).await {
            Ok(bytes) => app.cache_used.store(bytes, Ordering::Relaxed),
            Err(e) => eprintln!("ui: cache count: {e}"),
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
        .ok_or_else(|| tr("err_no_container").replace("{service}", service))
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
        return Err(bad_request(tr("err_action_restart_reload")));
    }
    let s = app.settings();
    if !s
        .list("UI_SERVICES")
        .contains(&format!("{container}:{program}"))
    {
        return Err(Fail(StatusCode::NOT_FOUND, tr("err_program_not_offered")));
    }
    // What: only a running program is touched.
    // Why: a restart must not start kea in dnsmasq mode.
    // From: Issue #1683
    let status = ["rc-service", program.as_str(), "status"];
    let (code, _) = exec_in(&app, &s, &container, &status)
        .await
        .map_err(|e| Fail(StatusCode::BAD_GATEWAY, e))?;
    if code != 0 {
        return Err(Fail(StatusCode::CONFLICT, tr("err_program_not_running")));
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
        // What: the service text behind a translated lead.
        // Why: Steam details stay as the service wrote.
        // From: Issue #871 | PR #1980
        return Err(format!("{} {e}", tr("hamster_says")));
    }
    if code != 0 {
        return Err(tr("hamster_exit").replace("{x}", &code.to_string()));
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
            .map_err(|_| bad_request(tr("err_time"))),
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
    Extension(Op(op)): Extension<Op>,
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
    // What: a job needs addresses or an app ID.
    // Why: the text in the page language.
    // From: Issue #871 | PR #1980
    if op == "UI_ROUTE_HAMSTER_ADD" && what.trim().is_empty() {
        return Err(bad_request(tr("err_hamster_empty")));
    }
    // What: the cachehamster command of each action.
    // Why: the daemon protocol names commands, not paths.
    // From: Issue #871
    let args: Vec<&str> = match op {
        "UI_ROUTE_HAMSTER_ADD" => vec!["add", &name, &when, &what],
        "UI_ROUTE_HAMSTER_START" => vec!["start", &id],
        "UI_ROUTE_HAMSTER_CANCEL" => vec!["cancel", &id],
        "UI_ROUTE_HAMSTER_REMOVE" => vec!["remove", &id],
        "UI_ROUTE_HAMSTER_LOGOUT" => vec!["logout"],
        _ => return Err(Fail(StatusCode::NOT_FOUND, "no such action".into())),
    };
    let back = app.settings().text("UI_PAGE_CACHEHAMSTER")?;
    finish(hamster(&app, &args).await.map(drop), &back)
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
        "cached",
        "wipe",
    ];
    // What: lookup-ID and evict-ID carry one app id.
    // Why: the library row checks or frees one game.
    // From: Issue #871 | PR #1991
    let args: Vec<&str> = match op.split_once('-') {
        Some((cmd @ ("lookup" | "evict"), id)) if id.parse::<u32>().is_ok() => vec![cmd, id],
        _ if allowed.contains(&op.as_str()) => vec![op.as_str()],
        _ => return Err(Fail(StatusCode::NOT_FOUND, "no such call".into())),
    };
    let v = hamster(&app, &args)
        .await
        .map_err(|e| Fail(StatusCode::BAD_GATEWAY, e))?;
    // What: freed bytes leave the shown sum at once.
    // Why: DoMe 07.11.: used kept 10.8 GiB after a wipe.
    // From: Issue #871 | PR #1991
    if let Some(freed) = v.get("freed").and_then(Value::as_u64) {
        let _ = app
            .cache_used
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |n| {
                (n != u64::MAX).then(|| n.saturating_sub(freed))
            });
    }
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
        // What: a first write wakes no owner.
        // Why: owners read it at start; a HUP then kills.
        // From: Issue #1683 | PR #1980
        let wake = f.path.exists();
        let changed = fs::write_if_changed(&f.path, f.body.as_bytes(), mode, owner_keep());
        if changed.map_err(|e| format!("{}: {e}", f.path.display()))? && wake {
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
async fn apply_all(
    app: &App,
    old: &Settings,
    new: &Settings,
    zones: bool,
) -> Result<Vec<String>, String> {
    let sec = secrets(new)?;
    let files = render::all(new, &sec).map_err(|e| e.join("; "))?;
    let mut changes = old.diff(new);
    let written = write_files(new, &files)?;
    app.rendered.store(true, Ordering::Relaxed);
    let snmpd_conf = new.text("SNMPD_CONF_FILE")?;
    let snmpd_new = written.iter().any(|c| c.key == snmpd_conf);
    changes.extend(written);
    // What: PowerDNS steps report, not abort.
    // Why: pdns starts only after the restart below.
    // From: Issue #1683 | PR #1980
    let mut report = Vec::new();
    // What: a new snmpd.conf reloads every snmpd.
    // Why: dns, proxy and ui run snmpd on the same file.
    // From: Issue #1683
    if snmpd_new {
        let (_, limit) = app.limits(new)?;
        let ex = new.list("SNMPD_RELOAD_EXEC");
        let owners: std::collections::BTreeSet<&str> = ex
            .iter()
            .filter_map(|e| e.split_once(':'))
            .map(|p| p.0)
            .collect();
        for owner in owners {
            match container_of(app, new, owner).await {
                Ok(name) => {
                    let r = apply::reload_exec(&app.docker, &name, &ex, owner, limit).await;
                    report.push(format!("{owner} snmpd: {r:?}"));
                }
                Err(e) => report.push(format!("{owner} snmpd: skipped, {e}")),
            }
        }
    }
    // What: at start zones_at_start owns this step.
    // Why: live: dns not up yet gave an error line.
    // From: Issue #1683 | PR #1980
    if zones && let Err(e) = ensure_zones(new).await {
        report.push(e);
    }
    let mut plan = apply::plan(&changes);
    let (grace, limit) = app.limits(new)?;
    // What: mode off stops dhcp; a missing one is fine.
    // Why: live: compose up started it again at start.
    // From: Issue #1683 | PR #1980
    let dhcp = new.text("DHCP_SERVICE")?;
    if new.text("DHCP_MODE")? == "off" {
        plan.remove(&dhcp);
        match container_of(app, new, &dhcp).await {
            Ok(name) => {
                let r = app
                    .docker
                    .act(&name, docker::Action::Stop, grace, limit)
                    .await;
                report.push(format!("{dhcp}: mode off, stop {r:?}"));
            }
            Err(e) => report.push(format!("{dhcp}: mode off, {e}")),
        }
    }
    // What: skip an owner that has no container yet.
    // Why: at stack start it reads the new files anyway.
    // From: Issue #1683 | PR #1980
    let mut names = BTreeMap::new();
    for owner in plan.keys() {
        match container_of(app, new, owner).await {
            Ok(name) => {
                names.insert(owner.clone(), name);
            }
            Err(e) => report.push(format!("{owner}: skipped, {e}")),
        }
    }
    plan.retain(|owner, _| names.contains_key(owner));
    let lookup = |owner: &str| names.get(owner).cloned().unwrap_or_default();
    let rx = new.list("RELOAD_EXEC");
    let mut restarted = Vec::new();
    let mut results = apply::run(&app.docker, &plan, &rx, &lookup, grace, limit).await;
    // What: one more try for owners that got a 409.
    // Why: live: restart while compose recreated proxy.
    // From: Issue #1683 | PR #1980
    if results
        .iter()
        .any(|(_, r)| matches!(r, apply::Outcome::Failed(docker::Error::Status(409))))
    {
        tokio::time::sleep(limit).await;
        let again: BTreeMap<_, _> = plan
            .iter()
            .filter(|(o, _)| {
                results.iter().any(|(x, r)| {
                    x == *o && matches!(r, apply::Outcome::Failed(docker::Error::Status(409)))
                })
            })
            .map(|(o, e)| (o.clone(), *e))
            .collect();
        let retried = apply::run(&app.docker, &again, &rx, &lookup, grace, limit).await;
        for (owner, r) in retried {
            if let Some(slot) = results.iter_mut().find(|(x, _)| *x == owner) {
                slot.1 = r;
            }
        }
    }
    for (owner, result) in results {
        if matches!(result, apply::Outcome::Done(docker::Action::Restart)) {
            restarted.push(lookup(&owner));
        }
        report.push(format!("{owner}: {result:?}"));
    }
    for name in wait_healthy(app, new, &restarted, limit).await {
        report.push(format!("{name}: not healthy in time"));
    }

    // What: after a dns restart wait for the pdns API.
    // Why: live test: the page loaded before pdns ran.
    // From: Issue #1683 | PR #1980
    if names
        .get(&new.text("DNS_SERVICE")?)
        .is_some_and(|n| restarted.contains(n))
    {
        let until = std::time::Instant::now() + limit;
        while let Err(e) = ensure_zones(new).await {
            if std::time::Instant::now() >= until {
                report.push(format!("dns api: {e}"));
                break;
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    }
    // What: issue missing certs after the restarts.
    // Why: many leaves take time; dns must not wait.
    // From: Issue #1683 | PR #1980
    let s = new.clone();
    let issued = tokio::task::spawn_blocking(move || render::issue_certs(&s))
        .await
        .map_err(|e| e.to_string())?;
    match issued {
        Ok(0) => {}
        Ok(n) => {
            report.push(format!("certs: {n} issued"));
            let mut plan = apply::plan(&[config::Change {
                key: "certs".into(),
                owner: "proxy".into(),
                effect: config::Effect::Reload,
            }]);
            let mut names = BTreeMap::new();
            for owner in plan.keys() {
                if let Ok(name) = container_of(app, new, owner).await {
                    names.insert(owner.clone(), name);
                }
            }
            plan.retain(|owner, _| names.contains_key(owner));
            let lookup = |owner: &str| names.get(owner).cloned().unwrap_or_default();
            for (owner, result) in apply::run(&app.docker, &plan, &rx, &lookup, grace, limit).await
            {
                report.push(format!("{owner}: {result:?}"));
            }
        }
        Err(e) => report.push(format!("certs: {e}")),
    }
    Ok(report)
}

// What: wait until restarted containers are healthy.
// Why: "done" must mean the service answers again.
// From: Issue #1683 | PR #1980
async fn wait_healthy(app: &App, s: &Settings, names: &[String], limit: Duration) -> Vec<String> {
    let wait = Duration::from_secs(s.uint("APPLY_HEALTH_WAIT_SECONDS").unwrap_or(0));
    let poll = Duration::from_secs(s.uint("APPLY_HEALTH_POLL_SECONDS").unwrap_or(1).max(1));
    let end = std::time::Instant::now() + wait;
    let mut late = Vec::new();
    for name in names {
        loop {
            let state = app.docker.inspect(name, limit).await.ok();
            let field = |p: &str| state.as_ref().and_then(|v| v.pointer(p)).cloned();
            let running = field("/State/Running").and_then(|v| v.as_bool());
            let health = field("/State/Health/Status");
            let health = health.as_ref().and_then(Value::as_str);
            if running == Some(true) && health.is_none_or(|h| h == "healthy") {
                break;
            }
            if std::time::Instant::now() >= end {
                late.push(name.clone());
                break;
            }
            tokio::time::sleep(poll).await;
        }
    }
    late
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
    let secondary = s.text("DNS_REPLICATION_ROLE")? == "secondary";
    let key = vec![sec.tsig_name];
    for z in api.zones().await? {
        if secondary {
            api.set_secondary_tsig(&z.name, &key[0]).await?;
        } else {
            api.set_metadata(&z.name, "TSIG-ALLOW-AXFR", &key).await?;
        }
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

// What: create missing primary zones; set DDNS meta.
// Why: 4220b1c3 dropped pdnsutil create-zone, no owner.
// From: Issue #1683 | PR #1980
async fn ensure_primary_zones(s: &Settings) -> Result<(), String> {
    let api = pdns_api(s)?;
    let have: Vec<String> = api.zones().await?.into_iter().map(|z| z.name).collect();
    let edit = vec![s.text("PDNS_SOA_EDIT")?];
    let signed = if s.flag("DDNS_ALLOW_UNSIGNED")? {
        Vec::new()
    } else {
        vec![secrets(s)?.tsig_name]
    };
    for zone in lancache_ng::dns::managed_zones(s)? {
        let id = lancache_ng::pdns::zone_id(&zone);
        if !have.contains(&id) {
            api.create_primary(&id, &edit[0]).await?;
        }
        api.set_metadata(&id, "SOA-EDIT-DNSUPDATE", &edit).await?;
        api.set_metadata(&id, "NOTIFY-DNSUPDATE", &["1".to_string()])
            .await?;
        api.set_metadata(&id, "TSIG-ALLOW-DNSUPDATE", &signed)
            .await?;
    }
    Ok(())
}

// What: zones, then TSIG; one report line on error.
// Why: TSIG binds to the zones that exist.
// From: Issue #1683 | PR #1980
async fn ensure_zones(s: &Settings) -> Result<(), String> {
    if s.text("DNS_REPLICATION_ROLE")? == "secondary" {
        ensure_secondary_zones(s)
            .await
            .map_err(|e| format!("secondary zones: {e}"))?;
    } else {
        ensure_primary_zones(s)
            .await
            .map_err(|e| format!("primary zones: {e}"))?;
    }
    ensure_tsig(s).await.map_err(|e| format!("tsig: {e}"))
}

// What: retry zones and TSIG until pdns answers.
// Why: at ui start the dns container may not run yet.
// From: Issue #1683 | PR #1980
async fn zones_at_start(app: Arc<App>) {
    let began = std::time::Instant::now();
    loop {
        let s = app.settings();
        let wait = s.uint("PDNS_SOA_COLD_RETRY").unwrap_or(1).max(1);
        let grace = s.uint("UI_FLUSH_GRACE_SECONDS").unwrap_or(0);
        match ensure_zones(&s).await {
            Ok(()) => {
                eprintln!("ui: start: zones ready");
                return;
            }
            // What: log only after the grace time.
            // Why: live: dns starts with the ui.
            // From: Issue #1683 | PR #1980
            Err(e) if began.elapsed().as_secs() >= grace => {
                eprintln!("ui: start: zones wait for dns {grace} s: {e}");
            }
            Err(_) => {}
        }
        tokio::time::sleep(Duration::from_secs(wait)).await;
    }
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
    for line in apply_all(app, &s, &s, true).await? {
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
        kea_ctrl_token: get("KEA_CTRL_TOKEN")?,
    })
}

// What: bytes of a whole GiB number.
// Why: DoMe 05.11.: cache sizes are whole GiB only.
// From: Issue #1683 | PR #1980
fn gib_bytes(text: &str) -> Result<u64, String> {
    let n: u64 = text
        .trim()
        .parse()
        .map_err(|_| tr("err_no_gib").replace("{x}", text))?;
    n.checked_shl(30)
        .ok_or_else(|| format!("{text:?} is too big"))
}

// What: largest cache size the disk allows, in bytes.
// Why: the form shows it; the save check enforces it.
// From: Issue #1069 | PR #1991
fn cache_reachable(s: &Settings, old: u64, cached: u64) -> Result<u64, String> {
    // What: the cache volume as the ui mounts it.
    // Why: live test 05.11.: NGINX_CACHE_DIR is proxy-only.
    // From: Issue #1069 | PR #1980
    let dir = s.text("CACHE_DIR")?;
    let sp = fs::space(Path::new(&dir)).map_err(|e| format!("{dir}: {e}"))?;
    // What: measured cache bytes; disk use as fallback.
    // Why: 249 showed 60 GiB; the disk holds OS files too.
    // From: Issue #1069 | PR #1991
    let used = sp.total.saturating_sub(sp.free);
    let held = if cached == u64::MAX {
        used.min(old)
    } else {
        cached
    };
    Ok(sp.free.saturating_add(held))
}

// What: refuse a bigger cache without room.
// Why: growth must fit the free disk space.
// From: Issue #1069
fn cache_room(s: &Settings, form: &Fields, cached: u64) -> Result<(), Fail> {
    let Some(wanted) = form.get("CACHE_MAX_GB") else {
        return Ok(());
    };
    let new = gib_bytes(wanted).map_err(bad_request)?;
    let old = gib_bytes(&s.text("CACHE_MAX_GB")?)?;
    if new <= old {
        return Ok(());
    }
    let reachable = cache_reachable(s, old, cached)?;
    if new > reachable {
        let room = human::bytes(reachable);
        return Err(bad_request(
            tr("err_cache_fit")
                .replace("{x}", wanted)
                .replace("{y}", &room),
        ));
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
    // What: the dhcp container while DHCP_MODE is off.
    // Why: live test: bar offered Start for it.
    // From: Issue #1683 | PR #1980
    let off = match (s.text("DHCP_SERVICE"), s.text("DHCP_MODE")) {
        (Ok(svc), Ok(mode)) if mode == "off" => svc,
        _ => String::new(),
    };
    let limit = app.limits(&s).map(|(_, l)| l).ok();
    let mut rows: Vec<Value> = Vec::new();
    for c in &list {
        let name = c["Labels"][docker::SERVICE_LABEL]
            .as_str()
            .unwrap_or_default();
        let colour = colour(c);
        // What: last health check output when not green.
        // Why: live test: "3 failures" showed no reason.
        // From: Issue #1683 | PR #1980
        let mut reason = String::new();
        if let (Some(l), "red" | "yellow", Some(id)) = (limit, colour, c["Id"].as_str())
            && let Ok(v) = app.docker.inspect(id, l).await
        {
            reason = v["State"]["Health"]["Log"]
                .as_array()
                .and_then(|a| a.last())
                .and_then(|e| e["Output"].as_str())
                .unwrap_or_default()
                .trim()
                .to_string();
        }
        rows.push(
            json!({"name": name, "status": colour, "health": c["Status"],
               "reason": reason, "mode_off": !off.is_empty() && name == off,
               "stopped_by_user": stopped.iter().any(|x| x == name)}),
        );
    }
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
        _ => return Err(bad_request(tr("err_state_running_stopped"))),
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

// What: unhealthy until the configs are rendered.
// Why: a failed start render hid behind a healthy ui.
// From: Issue #1683 | PR #1858
async fn health(State(app): Shared) -> Response {
    if app.rendered.load(Ordering::Relaxed) {
        "ok".into_response()
    } else {
        (StatusCode::SERVICE_UNAVAILABLE, "configs not rendered").into_response()
    }
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

// What: compile the mounted templates at start.
// Why: a broken template stops the start.
// From: Issue #1683 | PR #1991
fn templates(dir: &str) -> Result<Tera, String> {
    let mut t = Tera::default();
    t.autoescape_on(vec!["html"]);
    register_image_functions(&mut t);
    // What: Tera 1 filter cachehamster.html uses.
    // Why: Tera 2 has no filesizeformat; one byte format.
    // From: Issue #1683 | PR #1980
    t.register_filter(
        "filesizeformat",
        |v: u64, _: tera::Kwargs, _: &tera::State| human::bytes(v),
    );
    for (name, body) in folder(dir, "html")? {
        t.add_raw_template(&name, &body)
            .map_err(|e| format!("template {name}: {e}"))?;
    }
    Ok(t)
}

// What: read the language files at start.
// Why: a broken file or a missing key stops the start.
// From: Issue #1683 | PR #1980
fn texts(dir: &str) -> Result<Texts, String> {
    let mut all = Texts::new();
    for (name, body) in folder(dir, "json")? {
        let code = name.trim_end_matches(".json").to_string();
        let map: BTreeMap<String, String> =
            serde_json::from_str(&body).map_err(|e| format!("lang {code}: {e}"))?;
        all.insert(code, map);
    }
    let keys: Vec<Vec<&String>> = all.values().map(|m| m.keys().collect()).collect();
    if keys.windows(2).any(|w| w[0] != w[1]) {
        return Err("lang: the files differ in their keys".into());
    }
    Ok(all)
}

// What: language of one request.
// Why: cookie first, then the browser, then the SOT.
// From: Issue #1683 | PR #1980
fn pick_lang(app: &App, headers: &HeaderMap) -> String {
    let known = |c: &str| all_texts().contains_key(c);
    if let Some(c) = cookie(headers, LANG_COOKIE).filter(|c| known(c)) {
        return c;
    }
    let accept = headers
        .get(header::ACCEPT_LANGUAGE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default();
    for part in accept.split(',') {
        let c = part.split([';', '-']).next().unwrap_or_default();
        let c = c.trim().to_ascii_lowercase();
        if known(&c) {
            return c;
        }
    }
    app.settings().text("UI_LANG_DEFAULT").unwrap_or_default()
}

// What: run the request in its language.
// Why: page() reads it; no handler passes it on.
// From: Issue #1683 | PR #1980
async fn lang(State(app): Shared, req: Request, next: Next) -> Response {
    let code = pick_lang(&app, req.headers());
    LANG.scope(code, next.run(req)).await
}

// What: SOT keys of the actions each handler serves.
// Why: the handler matches the key; the SOT owns the path.
// From: Issue #1683
const DNS_OPS: [&str; 12] = [
    "UI_ROUTE_DNS_ADD",
    "UI_ROUTE_DNS_REMOVE",
    "UI_ROUTE_DNS_TOGGLE",
    "UI_ROUTE_AAAA_FILTER",
    "UI_ROUTE_QUERY_LOG",
    "UI_ROUTE_DDNS_UNSIGNED",
    "UI_ROUTE_LAN_ADD",
    "UI_ROUTE_LAN_REMOVE",
    "UI_ROUTE_PTR_ADD",
    "UI_ROUTE_PTR_REMOVE",
    "UI_ROUTE_ZONE_ROLLBACK",
    "UI_ROUTE_TSIG_ROTATE",
];
const DHCP_OPS: [&str; 13] = [
    "UI_ROUTE_DHCP_MODE",
    "UI_ROUTE_DHCP_DDNS",
    "UI_ROUTE_DHCP_PROXY",
    "UI_ROUTE_DHCP_RELAY",
    "UI_ROUTE_SUBNET_ADD",
    "UI_ROUTE_SUBNET_UPDATE",
    "UI_ROUTE_SUBNET_REMOVE",
    "UI_ROUTE_SUBNET_OPTION_ADD",
    "UI_ROUTE_SUBNET_OPTION_REMOVE",
    "UI_ROUTE_STATIC_ADD",
    "UI_ROUTE_STATIC_REMOVE",
    "UI_ROUTE_LEASE_RELEASE",
    "UI_ROUTE_KEA_ROLLBACK",
];
const HAMSTER_OPS: [&str; 5] = [
    "UI_ROUTE_HAMSTER_ADD",
    "UI_ROUTE_HAMSTER_START",
    "UI_ROUTE_HAMSTER_CANCEL",
    "UI_ROUTE_HAMSTER_REMOVE",
    "UI_ROUTE_HAMSTER_LOGOUT",
];
const SECONDARY_OPS: [&str; 4] = [
    "UI_ROUTE_SECONDARY",
    "UI_ROUTE_SECONDARY_ROTATE",
    "UI_ROUTE_SECONDARY_HEALTH",
    "UI_ROUTE_SECONDARY_ADDRESS",
];

// What: SOT key of the action a route serves.
// Why: one handler serves several SOT paths.
// From: Issue #1683
#[derive(Clone, Copy)]
struct Op(&'static str);

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
        // What: secondary zones and TSIG via the pdns API.
        // Why: a secondary has no ui server to do it.
        // From: Issue #1683
        Some("secondary-zones") => Some(ensure_zones(s).await),
        Some(DHCP_PROBE_CMD) => Some(dhcp_probe_cli(s)),
        Some("reset-sign-in") => Some(reset_sign_in()),
        _ => None,
    }
}

// What: drop the saved password hash; sign-in is off.
// Why: DoMe 07.11.: a locked-out user needs a way back.
// From: Issue #1683 | PR #1985
fn reset_sign_in() -> Result<(), String> {
    let path = process_env(SETTINGS_FILE_ENV).ok_or("no settings file set")?;
    let old = std::fs::read_to_string(&path).map_err(|e| format!("{path}: {e}"))?;
    let kept: String = old
        .lines()
        .filter(|l| !l.starts_with("UI_PASSWORD_HASH="))
        .map(|l| format!("{l}\n"))
        .collect();
    std::fs::write(&path, kept).map_err(|e| format!("{path}: {e}"))?;
    println!("{}", json!({"sign_in": "off"}));
    Ok(())
}

// What: one DHCP probe; the report as JSON.
// Why: runs on the host network, apart from the ui.
// From: Issue #1683 | PR #1985
fn dhcp_probe_cli(s: &Settings) -> Result<(), String> {
    let report = lancache_ng::dhcp_probe::run(s);
    println!(
        "{}",
        serde_json::to_string(&report).map_err(|e| e.to_string())?
    );
    Ok(())
}

// What: write the dns configs once, then exit.
// Why: a secondary has no ui server to render them.
// From: Issue #1683 | PR #1980
fn render_dns(s: &Settings) -> Result<(), String> {
    let sec = secrets(s)?;
    let files = render::dns_only(s, &sec).map_err(|e| e.join("; "))?;
    let changed = write_files(s, &files)?;
    println!(
        "{}",
        json!({"written": files.len(), "changed": changed.len()})
    );
    Ok(())
}

async fn healthcheck(s: &Settings) -> Result<(), String> {
    let url = format!(
        "http://{}:{}{}",
        s.text("LOOPBACK_BIND_IP")?,
        s.uint("UI_PORT")?,
        s.text("UI_ROUTE_HEALTH")?
    );
    let limit = Duration::from_secs(s.uint("HTTP_CLIENT_TIMEOUT")?);
    http::probe(&url, None, limit).await
}

// What: all ui routes plus auth and headers.
// Why: paths come from the SOT; one place maps them.
// From: Issue #1683
fn router(app: Arc<App>) -> Result<Router, String> {
    let s = app.settings();
    let p = |key: &str| s.text(key);
    let dir = s.text("STATIC_DIR")?;
    let css = static_file(&dir, "admin.css")?;
    let icon = static_file(&dir, "favicon.ico")?;
    let logo = static_file(&dir, "logo-icon.png")?;
    let mut pages = Router::new()
        .route(&p("UI_PAGE_DASHBOARD")?, get(dashboard))
        .route(&p("UI_PAGE_SETUP")?, get(setup))
        .route(&p("UI_ROUTE_SETUP_SAVE")?, post(save))
        .route(&p("UI_ROUTE_PASSWORD")?, post(password))
        .route(&p("UI_PAGE_LOGS")?, get(logs))
        .route(&p("UI_ROUTE_LOGS_SAVE")?, post(logs_save))
        .route(&p("UI_PAGE_CACHEHAMSTER")?, get(cachehamster))
        .route(&p("UI_ROUTE_HAMSTER_API")?, post(hamster_api))
        .route(&p("UI_PAGE_DOMAINS")?, get(domains))
        .route(&p("UI_PAGE_DHCP")?, get(dhcp))
        .route(&p("UI_ROUTE_DHCP_CHECK")?, post(dhcp_check))
        .route(&p("UI_PAGE_STATS")?, get(stats))
        .route(&p("UI_ROUTE_STATS_GRAPH")?, get(graph))
        .route(&p("UI_ROUTE_WATCHDOG_STATUS")?, get(status))
        .route(&p("UI_ROUTE_DESIRED_STATE")?, post(container_state))
        .route(&p("UI_ROUTE_RESTART_UI")?, post(restart_ui))
        .route(&p("UI_ROUTE_SERVICE_ACTION")?, post(service_action));
    // What: one route per action, tagged with its SOT key.
    // Why: handlers match the key, never a path text.
    // From: Issue #1683
    for key in DNS_OPS {
        pages = pages.route(&p(key)?, post(dns_action).layer(Extension(Op(key))));
    }
    for key in DHCP_OPS {
        pages = pages.route(&p(key)?, post(dhcp_action).layer(Extension(Op(key))));
    }
    for key in HAMSTER_OPS {
        pages = pages.route(&p(key)?, post(hamster_action).layer(Extension(Op(key))));
    }
    for key in SECONDARY_OPS {
        pages = pages.route(&p(key)?, post(secondary_action).layer(Extension(Op(key))));
    }
    let pages = pages.layer(axum::middleware::from_fn_with_state(app.clone(), auth));
    Ok(Router::new()
        .route(&p("UI_ROUTE_HEALTH")?, get(health))
        .route(&p("UI_ROUTE_SECONDARY_REGISTER")?, post(register))
        .route(
            &p("UI_ROUTE_ADMIN_CSS")?,
            get(move || async move { asset("text/css", css) }),
        )
        .route(
            &p("UI_ROUTE_FAVICON")?,
            get(move || async move { asset("image/x-icon", icon) }),
        )
        .route(
            &p("UI_ROUTE_LOGO_ICON")?,
            get(move || async move { asset("image/png", logo) }),
        )
        .merge(pages)
        .layer(axum::middleware::from_fn_with_state(app.clone(), secure))
        .layer(axum::middleware::from_fn_with_state(app.clone(), lang))
        .with_state(app))
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
    // What: no login and no opt-out stops the ui.
    // Why: AG-SEC-001: fail closed unless opted out.
    // From: Issue #1683 | PR #1985
    let hash = s.text("UI_PASSWORD_HASH").unwrap_or_default();
    if hash.is_empty() && !s.flag("ALLOW_INSECURE_UI").unwrap_or(false) {
        return Err("Admin-UI authentication is required".into());
    }
    let dir = PathBuf::from(s.text("SECRETS_DIR")?);
    let key =
        secret::resolve(None, &dir, "UI_SESSION_KEY", owner_keep()).map_err(|e| e.to_string())?;
    TEXTS
        .set(texts(&s.text("LANG_DIR")?)?)
        .map_err(|_| "lang: files read twice".to_string())?;
    let app = Arc::new(App {
        docker: docker::Api::new(&s.text("DOCKER_ENDPOINT")?)?,
        tera: templates(&s.text("TEMPLATE_DIR")?)?,
        settings: RwLock::new(s.clone()),
        saved,
        session_key: secret::key_bytes(&key)?,
        cache_used: AtomicU64::new(u64::MAX),
        rendered: AtomicBool::new(false),
    });
    // What: render every config once at start.
    // Why: owners read the config volume; it starts empty.
    // From: Issue #1683 | PR #1980
    match apply_all(&app, &s, &s, false).await {
        Ok(lines) => lines.iter().for_each(|l| eprintln!("ui: start: {l}")),
        Err(e) => eprintln!("ui: start render: {e}"),
    }
    tokio::spawn(sampler(app.clone()));
    tokio::spawn(cache_scanner(app.clone()));
    tokio::spawn(flush_on_transfer(app.clone()));
    tokio::spawn(zones_at_start(app.clone()));
    let listen = format!("{}:{}", s.text("UI_LISTEN")?, s.uint("UI_PORT")?);
    let sock = tokio::net::TcpListener::bind(&listen)
        .await
        .map_err(|e| format!("{listen}: {e}"))?;
    axum::serve(
        sock,
        router(app)?.into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
    .await
    .map_err(|e| e.to_string())
}
