//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later

use crate::dhcp::*;
use crate::dns::*;

// What: admin ui: settings, pages and actions.
// Why: owns settings; renders and applies configs.
// From: Issue #1683 | PR #1858

use crate::config::{self, Settings, process_env};
use crate::shared::dhcp::Mode as DhcpMode;
use crate::shared::peer::{self, PeerZone};
use crate::shared::{access, apply, docker, fs, http, human, render, secret};
use argon2::{Argon2, PasswordHash, PasswordHasher, PasswordVerifier};
use axum::extract::{Form, Request, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::middleware::Next;
use axum::response::{Html, IntoResponse, Redirect, Response};
use axum::routing::{get, post};
use axum::{Extension, Router};
use base64::Engine as _;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, RwLock};
use std::time::Duration;
use tera::{Context, Tera};

// What: CLI word of the one-shot DHCP probe.
// Why: the ui and setup.sh start the same command.
// From: Issue #1683 | PR #1985
pub(crate) const DHCP_PROBE_CMD: &str = "dhcp-probe";

// What: page keys read from env, not from specs.
// Why: compose sets them; no schema row exists.
// From: Issue #1683 | PR #1980
pub(crate) const ENV_ONLY_KEYS: [&str; 2] = ["IP_HTTP", "LANCACHE_IMAGE_CHANNEL"];

// What: read the files of one mounted folder.
// Why: page edits need no image build.
// From: Issue #1683 | PR #1991
pub(crate) fn folder(dir: &str, ext: &str) -> Result<Vec<(String, String)>, String> {
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
pub(crate) fn static_file(dir: &str, name: &str) -> Result<&'static [u8], String> {
    let path = std::path::Path::new(dir).join(name);
    let body = std::fs::read(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(Box::leak(body.into_boxed_slice()))
}

// What: cookie of the language the user picked.
// Why: the selector sets it; the ui reads it.
// From: Issue #1683 | PR #1980
pub(crate) const LANG_COOKIE: &str = "lc_lang";

// What: texts per language: code, key, text.
// Why: page() picks one map per request.
// From: Issue #1683 | PR #1980
pub(crate) type Texts = BTreeMap<String, BTreeMap<String, String>>;

// What: the language files, read once at start.
// Why: form errors outside page() need them too.
// From: Issue #1683 | PR #1980
pub(crate) static TEXTS: std::sync::OnceLock<Texts> = std::sync::OnceLock::new();

// What: all languages; empty before the start read.
// Why: one access path for page(), tr() and the layer.
// From: Issue #1683 | PR #1980
pub(crate) fn all_texts() -> &'static Texts {
    static EMPTY: Texts = Texts::new();
    TEXTS.get().unwrap_or(&EMPTY)
}

// What: one text in the request language.
// Why: form errors speak the language of the page.
// From: Issue #1683 | PR #1980
pub(crate) fn tr(key: &str) -> String {
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
// From: Issue #1683 | PR #1980
pub(crate) const COOKIE: &str = "lancache_session";

// What: form field that carries the CSRF token.
// Why: templates and handlers share one name.
// From: Issue #1683 | PR #1980
pub(crate) const CSRF_FIELD: &str = "csrf_token";

pub(crate) type Fields = BTreeMap<String, String>;

// What: a form field without blanks; empty if missing.
// Why: one reader for every form handler.
// From: Issue #1683 | PR #2017
pub(crate) fn field(form: &Fields, key: &str) -> String {
    form.get(key)
        .map(|v| v.trim().to_string())
        .unwrap_or_default()
}

// What: first and second DNS server as a list.
// Why: an empty field is no server.
// From: Issue #1683 | PR #2017
pub(crate) fn dns_pair(first: String, second: String) -> Vec<String> {
    [first, second]
        .into_iter()
        .filter(|d| !d.is_empty())
        .collect()
}

// What: error page text with an HTTP status.
// Why: handlers return Result and use the ? sign.
// From: Issue #1683 | PR #1980
pub(crate) struct Fail(StatusCode, String);

impl IntoResponse for Fail {
    // What: status code plus text as the response.
    // Why: axum sends a handler error through it.
    // From: Issue #1683 | PR #1980
    fn into_response(self) -> Response {
        (self.0, self.1).into_response()
    }
}

impl From<String> for Fail {
    // What: an error text becomes status 500.
    // Why: handlers pass internal errors on with ?.
    // From: Issue #1683 | PR #1980
    fn from(e: String) -> Self {
        Fail(StatusCode::INTERNAL_SERVER_ERROR, e)
    }
}

// What: a Fail with status 400 and the text.
// Why: wrong input is not a server error.
// From: Issue #1683 | PR #1980
pub(crate) fn bad_request(text: impl Into<String>) -> Fail {
    Fail(StatusCode::BAD_REQUEST, text.into())
}

pub(crate) type Page = Result<Response, Fail>;

// What: state shared by all handlers.
// Why: settings swap whole after each save.
// From: Issue #1683 | PR #1858
pub(crate) struct App {
    pub(crate) settings: RwLock<Settings>,
    pub(crate) saved: Option<PathBuf>,
    pub(crate) tera: Tera,
    pub(crate) docker: docker::Api,
    pub(crate) session_key: [u8; 32],
    pub(crate) cache_used: AtomicU64,
    // What: true once every config was rendered.
    // Why: dns and proxy wait for these files.
    // From: Issue #1683 | PR #1858
    pub(crate) rendered: AtomicBool,
}

pub(crate) type Shared = State<Arc<App>>;

impl App {
    // What: copy of the current settings.
    // Why: a handler never sees half an update.
    // From: Issue #1683 | PR #1858
    pub(crate) fn settings(&self) -> Settings {
        match self.settings.read() {
            Ok(s) => s.clone(),
            Err(poisoned) => poisoned.into_inner().clone(),
        }
    }

    // What: Docker stop grace and call limit.
    // Why: every wait comes from the SOT.
    // From: Issue #1683 | PR #1858
    pub(crate) fn limits(&self, s: &Settings) -> Result<(u32, Duration), String> {
        let grace = s.num::<u32>("UI_STOP_GRACE")?;
        Ok((grace, Duration::from_secs(s.uint("DOCKER_TIMEOUT")?)))
    }

    // What: render a page with the shared context.
    // Why: menu, csrf and values on every page.
    // From: Issue #1683 | PR #1858
    pub(crate) fn page(&self, name: &str, mut ctx: Context, csrf: &Csrf) -> Page {
        let s = self.settings();
        let page = name.trim_end_matches(".html");
        // What: every spec key, unset ones as empty text.
        // Why: templates read optional keys unguarded.
        // From: Issue #1683 | PR #1980
        let mut values: BTreeMap<String, String> = s
            .specs()
            .filter(|sp| !sp.is_secret())
            .map(|sp| (sp.key.clone(), String::new()))
            .collect();
        values.extend(s.texts().map(|(k, v)| (k.clone(), v)));
        // What: env-only keys the pages show.
        // Why: they live in env, not in the spec list.
        // From: Issue #1683 | PR #1980
        for key in ENV_ONLY_KEYS {
            let val = s.text_or_empty(key);
            values.entry(key.into()).or_insert(val);
        }
        let login = !password_hash(&s).is_empty();
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
        ctx.insert("ui_service", &s.text_or_empty("UI_SERVICE"));
        ctx.insert("watchdog_refresh_seconds", &s.uint("UI_STATUS_REFRESH")?);
        ctx.insert("warnings", &s.warnings);
        // What: texts of the request language.
        // Why: templates hold keys; scripts get the same.
        // From: Issue #1683 | PR #1980
        let code = LANG
            .try_with(Clone::clone)
            .unwrap_or_else(|_| s.text_or_empty("UI_LANG_DEFAULT"));
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
// From: Issue #1683 | PR #1980
#[derive(Clone)]
pub(crate) struct Csrf(String);

impl Csrf {
    // What: token: SHA-256 of key and session.
    // Why: each session has its own form token.
    // From: Issue #1683 | PR #1980
    fn from_session(key: &[u8; 32], session: &str) -> Self {
        let mut h = Sha256::new();
        h.update(key);
        h.update(session.as_bytes());
        Csrf(hex::encode(h.finalize()))
    }

    // What: compares a given token in constant time.
    // Why: a plain compare leaks it by timing.
    // From: Issue #1683 | PR #1980
    fn matches(&self, given: &str) -> bool {
        secret::equal(given, &self.0)
    }

    // What: form check; refuse without a match.
    // Why: each POST changes state.
    // From: Issue #1683 | PR #1980
    fn check(&self, form: &Fields) -> Result<(), Fail> {
        match form.get(CSRF_FIELD) {
            Some(t) if self.matches(t) => Ok(()),
            _ => Err(Fail(StatusCode::FORBIDDEN, tr("err_csrf"))),
        }
    }

    // What: header check for script calls.
    // Why: JSON calls send the token as a header.
    // From: Issue #1683 | PR #1980
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
// From: Issue #1683 | PR #1980
pub(crate) fn session_cookie(headers: &HeaderMap) -> Option<String> {
    cookie(headers, COOKIE)
}

// What: one cookie value by name.
// Why: session and language cookie share the parse.
// From: Issue #1683 | PR #1980
pub(crate) fn cookie(headers: &HeaderMap, name: &str) -> Option<String> {
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
// From: Issue #1683 | PR #1980
pub(crate) fn basic_credentials(headers: &HeaderMap) -> Option<(String, String)> {
    let raw = headers.get(header::AUTHORIZATION)?.to_str().ok()?;
    let encoded = raw.strip_prefix("Basic ")?;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .ok()?;
    let text = String::from_utf8(bytes).ok()?;
    let (user, pass) = text.split_once(':')?;
    Some((user.to_string(), pass.to_string()))
}

// What: the stored login hash; empty when none is set.
// Why: an empty hash means the ui runs without a login.
// From: Issue #1683 | PR #2017
pub(crate) fn password_hash(s: &Settings) -> String {
    s.text_or_empty("UI_AUTH_PASSWORD_HASH")
}

// What: Basic auth only when a hash is set.
// Why: the test stack runs without a password.
// From: Issue #1683 | PR #1858
pub(crate) async fn login_ok(s: &Settings, headers: &HeaderMap) -> bool {
    let hash = password_hash(s);
    if hash.is_empty() {
        return true;
    }
    let Some((user, pass)) = basic_credentials(headers) else {
        return false;
    };
    let want = s.text_or_empty("UI_AUTH_USER");
    let pass_ok = tokio::task::spawn_blocking(move || verify(&hash, &pass))
        .await
        .unwrap_or(false);
    pass_ok & secret::equal(&user, &want)
}

// What: login, session cookie and CSRF token.
// Why: runs before every protected handler.
// From: Issue #1683 | PR #1980
pub(crate) async fn auth(State(app): Shared, mut req: Request, next: Next) -> Response {
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
// From: Issue #1683 | PR #1980
pub(crate) fn read_json(path: &str) -> Value {
    std::fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or(Value::Null)
}

// What: adds a human-readable byte size field.
// Why: pages show sizes like 40 GiB, not raw bytes.
// From: Issue #1683 | PR #1980
pub(crate) fn with_human(v: &impl serde::Serialize, field: &str, n: u64) -> Value {
    let mut out = serde_json::to_value(v).unwrap_or(Value::Null);
    out[field] = human::bytes(n).into();
    out
}

// What: proxy request totals and recent rows.
// Why: dashboard; read off the async threads.
// From: Issue #1683 | PR #1858
pub(crate) async fn proxy_log(s: &Settings) -> Result<(Value, Vec<Value>), String> {
    let dir = Path::new(&s.text("SYSLOG_LOG_ROOT")?).join(s.text("PROXY_LOG_PROGRAM")?);
    let limit = s.num::<usize>("UI_RECENT_REQUESTS")?;
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
// From: Issue #1683 | PR #1980
pub(crate) async fn fetch_proxy_live(s: &Settings) -> Option<serde_json::Value> {
    let url = s.text("PROXY_STATUS_URL").ok()?;
    let resp = http::client(s).ok()?.get(&url).send().await.ok()?;
    let body = resp.error_for_status().ok()?.text().await.ok()?;
    parse_stub_status(&body)
}

// What: read the stub_status text into numbers.
// Why: nginx gives plain text, the page needs fields.
// From: Issue #1683 | PR #1980
pub(crate) fn parse_stub_status(body: &str) -> Option<serde_json::Value> {
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
pub(crate) async fn dashboard(State(app): Shared, Extension(csrf): Extension<Csrf>) -> Page {
    let s = app.settings();
    let mut ctx = Context::new();
    ctx.insert("alarms", &read_json(&s.text("WATCHDOG_ALARM_FILE")?));
    let containers = project_containers(&app, &s).await.unwrap_or_default();
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
    // Why: the disk holds more than the cache.
    // From: Issue #1683 | PR #1980
    let max = gib_bytes(&s.text("CACHE_MAX_GB")?)?;
    let used = app.cache_used.load(Ordering::Relaxed);
    if used != u64::MAX {
        let pct = (used.saturating_mul(100) / max.max(1)).min(100);
        ctx.insert("cache_used_human", &human::bytes(used));
        ctx.insert("cache_pct", &pct);
    }
    // What: the form label names the largest size.
    // Why: the form must show how much room is left.
    // From: Issue #1069 | PR #1991
    if let Ok(room) = cache_reachable(&s, max, used) {
        ctx.insert("cache_max_gib", &(room >> 30).to_string());
    }
    app.page("dashboard.html", ctx, &csrf)
}

// What: General page.
// Why: channel, updates, NTP and login.
// From: Issue #1683 | PR #1980
pub(crate) async fn setup(State(app): Shared, Extension(csrf): Extension<Csrf>) -> Page {
    let s = app.settings();
    let mut ctx = Context::new();
    ctx.insert("ntp_answers", &ntp_answers(&s).await?);
    app.page("setup.html", ctx, &csrf)
}

// What: set a new ui password (Argon2id).
// Why: only the hash is kept; old one must match.
// From: Issue #1683 | PR #1980
pub(crate) async fn password(
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
    let old = password_hash(&s);
    let hashed = tokio::task::spawn_blocking(move || {
        if !old.is_empty() && !verify(&old, &current) {
            return Err(wrong);
        }
        env_hash(&new)
    })
    .await
    .map_err(|e| e.to_string())?
    .map_err(bad_request)?;
    let mut change = Fields::from([("UI_AUTH_PASSWORD_HASH".to_string(), hashed)]);
    // What: the user name is set in the same form.
    // Why: the login name is free to choose.
    // From: Issue #1683 | PR #1985
    let user = get("user").trim().to_string();
    if !user.is_empty() {
        change.insert("UI_AUTH_USER".to_string(), user);
    }
    let back = app.settings().text("UI_PAGE_SETUP")?;
    finish(commit(&app, change).await, &back)
}

// What: keep only real changes of known keys.
// Why: an empty secret field means keep it.
// From: Issue #1683 | PR #1980
pub(crate) fn changes(old: &Settings, form: Fields) -> Fields {
    let mut out = Fields::new();
    for (key, value) in form {
        let Some(spec) = old.spec(&key) else { continue };
        let secret = spec.is_secret();
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
pub(crate) async fn commit(app: &App, form: Fields) -> Result<(), String> {
    let Some(path) = app.saved.clone() else {
        return Err(format!("{} is not set", config::SETTINGS_FILE_ENV));
    };
    let old = app.settings();
    let updates = changes(&old, form);
    if updates.is_empty() {
        return Ok(());
    }
    let before = config::read_raw(&path)?;
    config::store(&path, &old, &updates)?;
    let new = Settings::load(&process_env, Some(&path))?;
    // What: a value that cannot render is not kept.
    // Why: a bad value must not reach the files.
    // From: Issue #1683 | PR #1980
    let none = crate::shared::recursor_conf::Chain::default();
    let check = render::secrets(&new)
        .and_then(|sec| render::all(&new, &sec, &none).map_err(|e| e.join("; ")));
    if let Err(e) = check {
        // What: a refused save is logged, not only shown.
        // Why: the error must leave a trace in the logs.
        // From: Issue #1683 | PR #1991
        eprintln!("ui: save refused: {e}");
        // What: only the changed keys get their old values.
        // Why: a whole-file write undoes setup.sh edits.
        // From: Issue #1683 | PR #2017
        let back: Fields = updates
            .keys()
            .map(|k| (k.clone(), before.get(k).cloned().unwrap_or_default()))
            .collect();
        config::restore(&path, &back).map_err(|w| format!("{e}; old values not restored: {w}"))?;
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
// From: Issue #1683 | PR #1980
pub(crate) fn finish(result: Result<(), String>, back: &str) -> Page {
    result.map_err(bad_request)?;
    Ok(Redirect::to(back).into_response())
}

// What: General page form.
// Why: field names are the SOT keys.
// From: Issue #1683 | PR #1980
pub(crate) async fn save(
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
    // What: a new main domain also updates the extras.
    // Why: an extra made main must leave the extra list.
    // From: Issue #1683
    let mut form = form;
    if let Some(d) = form.get("DHCP_DOMAIN").cloned() {
        form.extend(main_domain_fields(&app.settings(), &d).map_err(bad_request)?);
    }
    // What: each upstream entry is checked before save.
    // Why: threat model G3: no loop to this host.
    // From: Issue #1683 | PR #1985
    let own = crate::shared::recursor_conf::own_ips(&app.settings());
    for key in ["DNS_UPSTREAM_SERVERS", "NGINX_UPSTREAM_RESOLVER"] {
        for raw in form
            .get(key)
            .map(|v| config::list_items(v))
            .into_iter()
            .flatten()
        {
            crate::shared::recursor_conf::upstream_entry(key, raw, &own).map_err(bad_request)?;
        }
    }

    // What: back to the page that sent the form.
    // Why: a form of the dashboard returns there.
    // From: Issue #1683 | PR #1980
    let back = form
        .get("back")
        .filter(|b| b.starts_with('/') && !b.starts_with("//"))
        .cloned()
        .map_or_else(|| app.settings().text("UI_PAGE_SETUP"), Ok)?;
    // What: the zones before the save; none if unreadable.
    // Why: a save may repair the settings; it must run.
    // From: Issue #1683 | PR #2017
    let before = hosted_now(&app.settings())
        .inspect_err(|e| eprintln!("ui: zones before the save unknown: {e}"))
        .unwrap_or_default();
    let result = commit(&app, form).await;
    if result.is_ok() {
        drop_old_zones(&app.settings(), &before).await;
    }
    finish(result, &back)
}

// What: newest lines of all programs, merged.
// Why: syslog-ng keeps one folder per program.
// From: Issue #1683 | PR #1980
pub(crate) fn newest_lines(root: &Path, programs: &[String], max: usize, chunk: u64) -> Vec<Value> {
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
// From: Issue #1683 | PR #1980
pub(crate) async fn logs(State(app): Shared, Extension(csrf): Extension<Csrf>) -> Page {
    let s = app.settings();
    let root = PathBuf::from(s.text("SYSLOG_LOG_ROOT")?);
    let max = s.num::<usize>("UI_LOG_LINES")?;
    let chunk = s.uint("UI_LOG_TAIL_CHUNK")?;
    let programs = s.list("SYSLOG_PROGRAMS");
    let muted = s.list("SYSLOG_MUTED");
    // What: every folder the store holds, plus the list.
    // Why: the store may name folders the list lacks.
    // From: Issue #1683 | PR #1980
    let mut names = programs.clone();
    let dirs = crate::shared::fs::entries_if_present(&root)
        .map_err(|e| format!("{}: {e}", root.display()))?;
    for d in dirs.iter().filter(|d| d.is_dir()) {
        if let Some(n) = d.file_name() {
            config::add_once(&mut names, &n.to_string_lossy());
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
// From: Issue #1683 | PR #1980
pub(crate) async fn logs_save(
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

// What: file change time as unix seconds.
// Why: snapshot age needs a plain number.
// From: Issue #1683 | PR #1980
pub(crate) fn created_unix(path: &Path) -> Result<u64, String> {
    let meta = std::fs::metadata(path).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(crate::shared::fs::modified_secs(&meta))
}

// What: the snapshots of a store as id and time rows.
// Why: the DNS and the DHCP page show the same shape.
// From: Issue #1683 | PR #2017
pub(crate) fn snapshot_rows(store: &crate::shared::snapshot::Store) -> Result<Vec<Value>, String> {
    let mut rows = Vec::new();
    for id in store.list().unwrap_or_default() {
        let created = created_unix(&store.path(&id))?;
        rows.push(json!({"id": id, "created_unix": created}));
    }
    Ok(rows)
}

// What: DNS page.
// Why: records are read live from PowerDNS.
// From: Issue #1683 | PR #1980
pub(crate) async fn domains(State(app): Shared, Extension(csrf): Extension<Csrf>) -> Page {
    let s = app.settings();
    let lans = crate::shared::dns::lan_domains(&s)?;
    let lan = crate::shared::dns::lan_zone(&s)?;
    let mut ctx = Context::new();
    ctx.insert("dns_domains", &crate::shared::cdn::parse_rows(&s)?);
    ctx.insert("lan_zone", lan.trim_end_matches('.'));
    let mut records: BTreeMap<String, Vec<Value>> = BTreeMap::new();
    let mut ptr = Vec::new();
    match pdns_api(&s) {
        // What: other zones only if the main one answers.
        // Why: an unreachable API would time out 20 times.
        // From: Issue #1683 | PR #1980
        Ok(api) => match api.rrsets(&lan).await {
            Ok(rows) => {
                records.insert(lan.clone(), own_rrsets(&rows));
                for zone in lans.iter().skip(1) {
                    match api.rrsets(zone).await {
                        Ok(rows) => {
                            records.insert(zone.clone(), own_rrsets(&rows));
                        }
                        Err(e) => ctx.insert("domain_error_message", &e),
                    }
                }
                ptr = ptr_rows(&s, &api).await;
            }
            Err(e) => ctx.insert("domain_error_message", &e),
        },
        Err(e) => ctx.insert("domain_error_message", &e),
    }
    let missing = missing_ptrs(&s, &mut records, &ptr);
    ctx.insert("missing_ptrs", &missing);
    let subnets = domain_subnets(&s).await;
    // What: a domain under a real Internet ending.
    // Why: in the LAN it hides its own Internet names.
    // From: Issue #1683 | PR #2019
    let psl = render::psl(&s).ok();
    let rows: Vec<Value> = lans
        .iter()
        .enumerate()
        .map(|(i, zone)| {
            let own = records.get(zone).cloned().unwrap_or_default();
            let public = psl
                .as_ref()
                .is_some_and(|p| p.is_tld(crate::shared::dns::ending(zone)));
            json!({
                "name": zone.trim_end_matches('.'),
                "main": i == 0,
                "records": own,
                "subnets": subnets.get(zone).cloned().unwrap_or_default(),
                "public": public,
            })
        })
        .collect();
    ctx.insert("lan_domains", &rows);
    ctx.insert("ptr_zones", &ptr);
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
    // What: NS state of each secondary: in, off or new.
    // Why: the row shows it and offers the matching button.
    // From: Issue #1683
    let (ns, off) = (s.list("DNS_SECONDARY_NS"), s.list("DNS_SECONDARY_NS_OFF"));
    let peers: Vec<Value> = crate::shared::pdns_conf::secondaries(&s)
        .into_iter()
        .map(|(name, address)| {
            let state = if ns.contains(&name) {
                "in"
            } else if off.contains(&name) {
                "off"
            } else {
                "new"
            };
            json!({"name": name, "address": address, "ns": state})
        })
        .collect();
    ctx.insert("secondaries", &peers);
    ctx.insert("secondary_ns_enabled", &s.flag("DNS_SECONDARY_NS_ENABLED")?);
    ctx.insert(
        "secondary_ns_auto",
        &s.flag("DNS_SECONDARY_NS_AUTO_REMOVE")?,
    );
    let span = |key: &str| -> Result<String, String> { Ok(duration_text(s.uint(key)?)) };
    ctx.insert(
        "secondary_check_every",
        &span("DNS_SECONDARY_CHECK_SECONDS")?,
    );
    ctx.insert(
        "secondary_recheck_every",
        &span("DNS_SECONDARY_RECHECK_SECONDS")?,
    );
    ctx.insert(
        "secondary_ns_after",
        &span("DNS_SECONDARY_NS_REMOVE_AFTER_SECONDS")?,
    );
    ctx.insert(
        "secondary_ns_fails",
        &s.uint("DNS_SECONDARY_NS_REMOVE_FAILS")?,
    );
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
    ctx.insert("primary_ip_https", &primary_https_ip(&s)?);

    // What: UI address on the LAN when none is set.
    // Why: the install command needs an address.
    // From: Issue #1683 | PR #1980
    let mut url = s.text_or_empty("UI_PUBLIC_URL");
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
    ctx.insert("ddns_tsig_key_configured", &secret::tsig_secret(&s).is_ok());
    app.page("domains.html", ctx, &csrf)
}

// What: list setting with one item in or out.
// Why: domain add, remove and toggle share it.
// From: Issue #1683 | PR #1980
pub(crate) fn list_change(s: &Settings, key: &str, item: &str, present: bool) -> Fields {
    let mut items: Vec<String> = s.list(key).into_iter().filter(|x| x != item).collect();
    if present {
        items.push(item.to_string());
    }
    Fields::from([(key.to_string(), items.join(" "))])
}

// What: a form with exactly one field.
// Why: commit takes Fields; a switch saves one key.
// From: Issue #1683 | PR #1980
pub(crate) fn single_field(key: &str, value: impl ToString) -> Fields {
    Fields::from([(key.to_string(), value.to_string())])
}

// What: one DNS page form, chosen by its SOT key.
// Why: all DNS forms share one handler.
// From: Issue #1683
pub(crate) async fn dns_action(
    State(app): Shared,
    Extension(csrf): Extension<Csrf>,
    Extension(Op(op)): Extension<Op<DnsOp>>,
    Form(form): Form<Fields>,
) -> Page {
    csrf.check(&form)?;
    let s = app.settings();
    let get = |k: &str| field(&form, k);
    let on = config::parse_bool(&get("enabled")).unwrap_or(false);
    let domain = get("domain").to_ascii_lowercase();
    let result = match op {
        DnsOp::DnsAdd if crate::shared::dns::cdn_entry(&domain).is_none() => {
            Err(format!("{domain:?} is no valid domain entry"))
        }
        DnsOp::DnsAdd => commit(&app, list_change(&s, "CDN_CUSTOM_DOMAINS", &domain, true)).await,
        DnsOp::DnsRemove => {
            commit(&app, list_change(&s, "CDN_CUSTOM_DOMAINS", &domain, false)).await
        }
        DnsOp::DnsToggle => {
            commit(&app, list_change(&s, "CDN_DISABLED_DOMAINS", &domain, !on)).await
        }
        DnsOp::AaaaFilter => commit(&app, single_field("DNS_FILTER_AAAA", on)).await,
        DnsOp::QueryLog => commit(&app, single_field("DNS_QUERY_LOG", on)).await,
        DnsOp::DdnsUnsigned => commit(&app, single_field("DDNS_ALLOW_UNSIGNED", on)).await,
        DnsOp::NsSwitch => commit(&app, single_field("DNS_SECONDARY_NS_ENABLED", on)).await,
        DnsOp::NsAuto => commit(&app, single_field("DNS_SECONDARY_NS_AUTO_REMOVE", on)).await,
        DnsOp::LanAdd | DnsOp::LanRemove => record(&s, matches!(op, DnsOp::LanAdd), &get).await,
        DnsOp::LanDomainAdd | DnsOp::LanDomainRemove | DnsOp::LanDomainMain => {
            lan_domain_action(&app, &s, op.key(), &domain).await
        }
        DnsOp::PtrAdd | DnsOp::PtrRemove => ptr(&s, matches!(op, DnsOp::PtrAdd), &get).await,
        DnsOp::ZoneRollback => rollback(&s, &get("zone"), &get("snapshot_id")).await,
        DnsOp::TsigRotate => rotate_tsig(&app).await,
    };
    finish(result, &s.text("UI_PAGE_DOMAINS")?)
}

// What: token secondaries register with.
// Why: kept like any secret; rotate renews it.
// From: Issue #1683 | PR #1980
pub(crate) fn registration_token(s: &Settings) -> Result<String, String> {
    secret::get(s, "SECONDARY_REGISTRATION_TOKEN")
}

// What: body of a secondary registration.
// Why: the token proves the admin gave the command.
// From: Issue #1683 | PR #1980
#[derive(serde::Deserialize)]
pub(crate) struct Register {
    pub(crate) token: String,
    pub(crate) name: String,
    #[serde(default)]
    pub(crate) address: Option<String>,
}

// What: register a secondary (public route).
// Why: token checked; reply has the whole kit.
// From: Issue #1683 | PR #1980
pub(crate) async fn register(
    State(app): Shared,
    axum::extract::ConnectInfo(peer): axum::extract::ConnectInfo<std::net::SocketAddr>,
    axum::Json(r): axum::Json<Register>,
) -> Page {
    let s = app.settings();
    let token = registration_token(&s).map_err(|e| Fail(StatusCode::SERVICE_UNAVAILABLE, e))?;
    if !secret::equal(&r.token, &token) {
        return Err(Fail(StatusCode::UNAUTHORIZED, "wrong token".into()));
    }
    let mut list = crate::shared::pdns_conf::secondaries(&s);
    // What: sent address, else stored, else the peer IP.
    // Why: re-registration keeps a manual override.
    // From: Issue #1683 | PR #1980
    let stored = list
        .iter()
        .find(|(n, _)| *n == r.name)
        .map(|(_, a)| a.clone());
    let address = r
        .address
        .or(stored)
        .unwrap_or_else(|| peer.ip().to_string());
    if !valid_peer_name(&s, &r.name)? || !crate::shared::dns::is_ip(&address) {
        return Err(bad_request("name or address is not valid"));
    }
    list.retain(|(n, _)| *n != r.name);
    list.push((r.name.clone(), address));
    store_secondaries(&app, &list).await?;
    Ok(axum::Json(peer_kit(&app.settings())?).into_response())
}

// What: body with a new peer address.
// Why: the edit dialog posts {"address": ...}.
// From: Issue #1683 | PR #1980
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Address {
    pub(crate) address: String,
}

// What: new registration token.
// Why: drop the file; resolve makes a fresh one.
// From: Issue #1683 | PR #1980
pub(crate) fn renew_token(s: &Settings) -> Result<String, String> {
    let dir = secret::dir(s)?;
    let file = secret::file_of(&dir, "SECONDARY_REGISTRATION_TOKEN");
    fs::remove_if_present(&file).map_err(|e| format!("{}: {e}", file.display()))?;
    registration_token(s)
}

// What: secondary actions from the DNS page.
// Why: remove, rotate, address and health.
// From: Issue #1683 | PR #1980
pub(crate) async fn secondary_action(
    State(app): Shared,
    Extension(csrf): Extension<Csrf>,
    axum::extract::Path(name): axum::extract::Path<String>,
    Extension(Op(op)): Extension<Op<SecondaryOp>>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Page {
    csrf.check_header(&headers)?;
    let s = app.settings();
    let mut list = crate::shared::pdns_conf::secondaries(&s);
    let Some(at) = list.iter().position(|(n, _)| *n == name) else {
        return Err(Fail(StatusCode::NOT_FOUND, tr("err_no_secondary")));
    };
    match op {
        SecondaryOp::Remove => {
            let (_, address) = list.remove(at);
            // What: the name leaves both NS lists too.
            // Why: a new secondary of that name starts new.
            // From: Issue #1683
            let mut form = ns_change(&s, &name, None);
            let rows = crate::shared::pdns_conf::secondary_rows(&list);
            form.insert("DNS_SECONDARIES".into(), rows);
            commit(&app, form).await?;
            drop_peer_records(&app.settings(), &name, &address).await?;
            rotate_tsig(&app).await?;
            Ok(Redirect::to(&s.text("UI_PAGE_DOMAINS")?).into_response())
        }
        SecondaryOp::NsAdd => {
            if !s.flag("DNS_SECONDARY_NS_ENABLED")? {
                return Err(bad_request(tr("err_secondary_ns_off")));
            }
            answers_aa(&s, &list[at].1, &crate::shared::dns::lan_zone(&s)?)
                .await
                .map_err(bad_request)?;
            commit(&app, ns_change(&s, &name, Some(true)))
                .await
                .map_err(bad_request)?;
            Ok(StatusCode::NO_CONTENT.into_response())
        }
        SecondaryOp::NsRemove => {
            commit(&app, ns_change(&s, &name, Some(false)))
                .await
                .map_err(bad_request)?;
            Ok(StatusCode::NO_CONTENT.into_response())
        }
        SecondaryOp::Rotate => Ok(axum::Json(json!({"token": renew_token(&s)?})).into_response()),
        SecondaryOp::Address => {
            let axum::Json(a) = axum::Json::<Address>::from_bytes(&body)
                .map_err(|_| bad_request(tr("err_address_body")))?;
            if !crate::shared::dns::is_ip(&a.address) {
                return Err(bad_request(tr("err_no_ip")));
            }
            // What: a new address drops the old records.
            // Why: same address: no save, no ensure runs.
            // From: Issue #1683
            if list[at].1 != a.address {
                drop_peer_records(&s, &name, &list[at].1)
                    .await
                    .map_err(bad_request)?;
            }
            list[at].1 = a.address;
            store_secondaries(&app, &list).await.map_err(bad_request)?;
            Ok(StatusCode::NO_CONTENT.into_response())
        }
        SecondaryOp::Health => {
            Ok(axum::Json(secondary_health(&s, &list[at].1).await).into_response())
        }
    }
}

// What: failed checks of one secondary in a row.
// Why: NS removal needs time and count both.
// From: Issue #1683
pub(crate) struct Failing {
    pub(crate) since: std::time::Instant,
    pub(crate) count: u64,
}

// What: serial table: managed zones, primary, secondaries.
// Why: one overview of the loaded serial on each server.
// From: Issue #1683
pub(crate) async fn zone_overview(State(app): Shared) -> Page {
    let s = app.settings();
    let mut columns = vec![json!({"name": tr("zone_col_primary"), "error": Value::Null})];
    let mut lists = vec![pdns_api(&s)?.zones().await?];
    for (name, address) in crate::shared::pdns_conf::secondaries(&s) {
        match peer::zones_at(&s, &address).await {
            Ok(z) => {
                columns.push(json!({"name": name, "error": Value::Null}));
                lists.push(z);
            }
            Err(e) => {
                columns.push(json!({"name": name, "error": e}));
                lists.push(Vec::new());
            }
        }
    }
    let rows: Vec<Value> = crate::shared::dns::managed_zones(&s)?
        .into_iter()
        .map(|zone| {
            let serials: Vec<Option<u32>> =
                lists.iter().map(|l| peer::serial_of(l, &zone)).collect();
            // What: state word of each secondary's cell.
            // Why: table and status line share zone_state.
            // From: Issue #1683 | PR #2019
            let states: Vec<Option<&str>> = serials
                .iter()
                .zip(&columns)
                .skip(1)
                .map(|(theirs, column)| {
                    column["error"].is_null().then(|| {
                        let row = PeerZone {
                            zone: zone.clone(),
                            primary: serials[0],
                            secondary: *theirs,
                        };
                        peer::zone_state(&row).word()
                    })
                })
                .collect();
            json!({"zone": zone, "serials": serials, "states": states})
        })
        .collect();
    Ok(axum::Json(json!({"columns": columns, "rows": rows})).into_response())
}

// What: DHCP page.
// Why: mode, proxy, relay and live Kea data.
// From: Issue #1683 | PR #1980
pub(crate) async fn dhcp(State(app): Shared, Extension(csrf): Extension<Csrf>) -> Page {
    let s = app.settings();
    let mode = s.text("DHCP_MODE")?;
    let mut ctx = Context::new();
    ctx.insert("dhcp_mode", &mode);
    ctx.insert("dhcp_modes", &s.list("DHCP_MODES"));
    let kind = DhcpMode::from_word(&mode)?;
    ctx.insert("dhcp_has_kea", &(kind == DhcpMode::Kea));
    ctx.insert("dhcp_is_dnsmasq", &kind.is_dnsmasq());
    ctx.insert("dhcp_is_relay", &(kind == DhcpMode::DnsmasqRelay));
    ctx.insert("dhcp_ddns_enabled", &s.flag("DHCP_DDNS")?);
    // What: form values the dhcp page shows.
    // Why: Tera stops on any missing variable.
    // From: Issue #1683 | PR #1980
    let opt = |k: &str| s.text_or_empty(k);
    let dns = s.list("DHCP_DNS_SERVERS");
    ctx.insert("dhcp_dns_primary", dns.first().map_or("", String::as_str));
    ctx.insert("dhcp_dns_secondary", dns.get(1).map_or("", String::as_str));
    ctx.insert("default_lease_time", &opt("DHCP_LEASE_TIME"));
    ctx.insert("dhcp_domain", &opt("DHCP_DOMAIN"));
    // What: LAN domains for the subnet domain dropdown.
    // Why: a subnet may only use a domain DNS serves.
    // From: Issue #1683
    let lan_names: Vec<String> = crate::shared::dns::lan_domains(&s)?
        .iter()
        .map(|z| z.trim_end_matches('.').to_string())
        .collect();
    ctx.insert("lan_domain_names", &lan_names);
    ctx.insert("main_subnet_id", &s.uint("DHCP_SUBNET_ID")?);
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
    // What: the hint shows only when own NTP is handed out.
    // Why: one rule with the Kea and dnsmasq render.
    // From: Issue #1683
    ctx.insert("ntp_auto_dhcp_active", &crate::shared::dhcp::own_ntp(&s)?);
    let codes: Vec<u8> = crate::shared::dhcp::MANAGED
        .iter()
        .map(|m| m.code)
        .collect();
    ctx.insert("kea_managed_codes", &codes);
    ctx.insert("dnsmasq_managed_codes", &codes);
    ctx.insert("option_code_min", &1);
    ctx.insert("option_code_max", &(u8::MAX - 1));
    let (mut subnets, mut reservations, mut leases) = (Vec::new(), Vec::new(), Vec::new());
    if kind == DhcpMode::Kea {
        match kea_api(&s) {
            Ok(api) => (subnets, reservations, leases) = kea_view(&api).await,
            Err(e) => ctx.insert("hint", &e),
        }
    }
    ctx.insert("subnets", &subnets);
    ctx.insert("reservations", &reservations);
    ctx.insert("leases", &leases);
    let store = kea_store(&s)?;
    ctx.insert("kea_snapshots", &snapshot_rows(&store)?);
    app.page("dhcp.html", ctx, &csrf)
}

// What: one DHCP page form, chosen by op.
// Why: SOT keys via commit; Kea via kea_action.
// From: Issue #1683 | PR #1980
pub(crate) async fn dhcp_action(
    State(app): Shared,
    Extension(csrf): Extension<Csrf>,
    Extension(Op(op)): Extension<Op<DhcpOp>>,
    Form(form): Form<Fields>,
) -> Page {
    csrf.check(&form)?;
    let s = app.settings();
    let get = |k: &str| field(&form, k);
    let on = config::parse_bool(&get("enabled")).unwrap_or(false);
    // What: relay without the real server: plain hint.
    // Why: a bare key name tells the user nothing.
    // From: Issue #1683 | PR #1991
    let asked = DhcpMode::from_word(&get("dhcp_mode")).ok();
    let relay = matches!(op, DhcpOp::Mode) && asked == Some(DhcpMode::DnsmasqRelay);
    if relay && s.text_or_empty("UPSTREAM_DHCP_IP").is_empty() {
        return Err(bad_request(tr("err_relay_needs_upstream")));
    }
    // What: the Kea server needs a network card.
    // Why: without a card Kea answers nobody.
    // From: Issue #1683
    let cards = get("dhcp_proxy_interface");
    if matches!(op, DhcpOp::Mode) && asked == Some(DhcpMode::Kea) && cards.is_empty() {
        return Err(bad_request(tr("err_kea_needs_interface")));
    }
    let result = match op {
        DhcpOp::Mode => {
            let mut f = single_field("DHCP_MODE", get("dhcp_mode"));
            f.insert("DHCP_PROXY_INTERFACE".into(), cards);
            commit(&app, f).await
        }
        DhcpOp::Ddns => commit(&app, single_field("DHCP_DDNS", on)).await,
        DhcpOp::Proxy | DhcpOp::Relay => {
            commit(&app, dnsmasq_fields(&form, matches!(op, DhcpOp::Proxy))).await
        }
        other => main_subnet(&app, &s, other.key(), &get).await,
    };
    finish(result, &s.text("UI_PAGE_DHCP")?)
}

// What: DHCP precheck on demand.
// Why: finds foreign servers; tests one lease.
// From: Issue #1683 | PR #1980
pub(crate) async fn dhcp_check(
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
// From: Issue #1683 | PR #1980
pub(crate) async fn stats(State(app): Shared, Extension(csrf): Extension<Csrf>) -> Page {
    let s = app.settings();
    let mut ctx = Context::new();
    match crate::shared::rrd::all(&s) {
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
    // Why: each value shows where it comes from.
    // From: Issue #1683 | PR #1980
    let step = s.uint("STATS_STEP")?;
    ctx.insert("stats_step", &step);
    let snmp = s.text_or_empty("STATS_SNMP_TARGET");
    let mut tabs = vec![json!({
        "id": crate::shared::rrd::MACHINE,
        "label": tr("stats_machine"),
        "source": tr("stats_machine_source")
            .replace("{x}", &snmp)
            .replace("{y}", &step.to_string()),
    })];
    // What: no dhcp tab while DHCP_MODE is off.
    // Why: the tab would show a stopped container.
    // From: Issue #1683
    let off = crate::shared::dhcp::off_service(&s)?.unwrap_or_default();
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
// From: Issue #1683 | PR #1980
#[derive(serde::Deserialize)]
pub(crate) struct GraphQuery {
    pub(crate) range: String,
    #[serde(default)]
    pub(crate) dark: u8,
}

// What: graph title in the page language.
// Why: SOT names are English words; key graph_<name>.
// From: Issue #1683 | PR #1980
pub(crate) fn graph_title(title: &str) -> String {
    let key = format!("graph_{}", title.replace(' ', "_"));
    let text = tr(&key);
    if text == key { title.to_string() } else { text }
}

// What: one graph as PNG.
// Why: drawn on request; RRD files stay small.
// From: Issue #1683 | PR #1980
pub(crate) async fn graph(
    State(app): Shared,
    axum::extract::Path(name): axum::extract::Path<String>,
    axum::extract::Query(q): axum::extract::Query<GraphQuery>,
) -> Page {
    let s = app.settings();
    let all = crate::shared::rrd::all(&s)?;
    let Some(mut g) = all.into_iter().find(|g| g.name == name) else {
        return Err(Fail(StatusCode::NOT_FOUND, tr("err_no_graph")));
    };
    g.title = graph_title(&g.title);
    let draw = move || crate::shared::rrd::png(&s, &g, &q.range, q.dark == 1);
    let png = tokio::task::spawn_blocking(draw)
        .await
        .map_err(|e| e.to_string())?
        .map_err(bad_request)?;
    Ok(([(header::CONTENT_TYPE, "image/png")], png).into_response())
}

// What: SNMP samples into RRD each step.
// Why: the ui owns the statistics files.
// From: Issue #1683 | PR #1980
pub(crate) fn sample_all(s: &Settings) -> Vec<String> {
    match crate::shared::rrd::graphs(s) {
        Err(e) => vec![e],
        Ok(list) => list
            .iter()
            .filter_map(|g| crate::shared::rrd::sample(s, g).err())
            .collect(),
    }
}

// What: stores one RRD row off the async threads.
// Why: rrdtool blocks; an error joins the list.
// From: Issue #1683 | PR #2017
pub(crate) async fn store_row(
    s: &Settings,
    graph: crate::shared::rrd::Graph,
    row: Vec<String>,
) -> Result<(), String> {
    let s = s.clone();
    let put = move || crate::shared::rrd::store(&s, &graph, &row);
    tokio::task::spawn_blocking(put)
        .await
        .map_err(|e| e.to_string())?
}

// What: Docker stats of each container into RRD.
// Why: values per container, not only the box.
// From: Issue #1683 | PR #1980
pub(crate) async fn sample_containers(app: &App, s: &Settings) -> Vec<String> {
    let all = match crate::shared::rrd::container_graphs(s) {
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
                .map(|x| crate::shared::rrd::docker_value(&v, &x.oid))
                .collect();
            errs.extend(store_row(s, g.clone(), vals).await.err());
        }
    }
    errs
}

// What: numbers of a PowerDNS statistics list.
// Why: values come as text; prefix names the server.
// From: Issue #1683 | PR #1980
pub(crate) fn add_stats(
    out: &mut BTreeMap<String, String>,
    prefix: &str,
    rows: Vec<(String, String)>,
) {
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
pub(crate) async fn service_values(
    app: &App,
    s: &Settings,
    want: &[String],
) -> BTreeMap<String, String> {
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
        && let Ok(apis) = peer::recursor_apis(s)
    {
        for r in apis {
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
    // Why: in mode off no dhcp container gives it.
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

    // What: the tracking row: CSV, field 5 = offset.
    // Why: stratum and offset show the time source.
    // From: Issue #1683 | PR #1980
    let tracking = s.list("CHRONY_TRACKING_EXEC");
    if has("chrony")
        && let Some((svc, cmd)) = apply::exec_rows(&tracking).next()
        && let Ok((0, text)) = exec_in(app, s, svc, &cmd).await
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
// Why: PowerDNS, nginx, Kea and chrony give values.
// From: Issue #1683 | PR #1980
pub(crate) async fn sample_services(app: &App, s: &Settings) -> Vec<String> {
    let all = match crate::shared::rrd::service_graphs(s) {
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
            .map(|x| {
                vals.get(&x.oid)
                    .cloned()
                    .unwrap_or_else(|| crate::shared::rrd::UNKNOWN.into())
            })
            .collect();
        errs.extend(store_row(s, g, row).await.err());
    }
    errs
}

// What: a setting a background task cannot run without.
// Why: the task ends with a log line, no made-up value.
// From: Issue #1683 | PR #2017
pub(crate) fn or_stop<T>(task: &str, value: Result<T, String>) -> Option<T> {
    value
        .inspect_err(|e| eprintln!("ui: {task} stop: {e}"))
        .ok()
}

// What: records stats every STATS_STEP seconds.
// Why: the dashboard graphs need a time series.
// From: Issue #1683 | PR #1980
pub(crate) async fn sampler(app: Arc<App>) {
    loop {
        let s = app.settings();
        let Some(step) = or_stop("stats", s.uint("STATS_STEP")) else {
            return;
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
        match dhcp_stays_off(&app, &s).await {
            Ok(Some(done)) => eprintln!("ui: dhcp: {done}"),
            Ok(None) => {}
            Err(e) => eprintln!("ui: dhcp: {e}"),
        }
        tokio::time::sleep(Duration::from_secs(step)).await;
    }
}

// What: bytes the cache folder holds on disk.
// Why: disk use counts other files on a shared disk.
// From: Issue #1683 | PR #1980
pub(crate) fn dir_bytes(root: &Path) -> u64 {
    use std::os::unix::fs::MetadataExt;
    crate::shared::fs::files_under(root)
        .into_iter()
        .fold(0u64, |total, (_, meta)| {
            total.saturating_add(meta.blocks().saturating_mul(512))
        })
}

// What: count the cache folder now and then.
// Why: a walk is slow; the dashboard reads the last sum.
// From: Issue #1683 | PR #1980
pub(crate) async fn cache_scanner(app: Arc<App>) {
    loop {
        let s = app.settings();
        let Some(step) = or_stop("cache count", s.uint("CACHE_USAGE_SCAN_SECONDS")) else {
            return;
        };
        let Some(dir) = or_stop("cache count", s.text("CACHE_DIR")) else {
            return;
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
// From: Issue #1683 | PR #1980
pub(crate) async fn container_of(app: &App, s: &Settings, service: &str) -> Result<String, String> {
    let list = project_containers(app, s).await?;
    let hit = list.iter().find(|c| docker::service_of(c) == Some(service));
    hit.and_then(docker::name_of)
        .map(str::to_string)
        .ok_or_else(|| tr("err_no_container").replace("{service}", service))
}

// What: the containers of this compose project.
// Why: every lookup of a service starts from this list.
// From: Issue #1683 | PR #2017
pub(crate) async fn project_containers(app: &App, s: &Settings) -> Result<Vec<Value>, String> {
    app.docker.stack(s).await
}

// What: run a command in a service container.
// Why: rc-service and cachehamster go this way.
// From: Issue #1683 | PR #1980
pub(crate) async fn exec_in(
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
// From: Issue #1683 | PR #1980
pub(crate) async fn service_action(
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
    let control = s.text("SERVICE_CONTROL_PROGRAM")?;
    let status = [control.as_str(), program.as_str(), "status"];
    let (code, _) = exec_in(&app, &s, &container, &status)
        .await
        .map_err(|e| Fail(StatusCode::BAD_GATEWAY, e))?;
    if code != 0 {
        return Err(Fail(StatusCode::CONFLICT, tr("err_program_not_running")));
    }
    let cmd = [control.as_str(), program.as_str(), action.as_str()];
    let (code, out) = exec_in(&app, &s, &container, &cmd)
        .await
        .map_err(|e| Fail(StatusCode::BAD_GATEWAY, e))?;
    if code != 0 {
        return Err(Fail(
            StatusCode::BAD_GATEWAY,
            format!("{control} exit {code}: {out}"),
        ));
    }
    Ok(StatusCode::NO_CONTENT.into_response())
}

// What: one cachehamster command; JSON answer.
// Why: it runs in the services container.
// From: Issue #871 | PR #1980
pub(crate) async fn hamster(app: &App, args: &[&str]) -> Result<Value, String> {
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
// From: Issue #871 | PR #1980
pub(crate) async fn cachehamster(State(app): Shared, Extension(csrf): Extension<Csrf>) -> Page {
    let mut ctx = Context::new();
    match hamster(&app, &["status"]).await {
        Ok(v) => ctx.insert("hamster", &v),
        Err(e) => ctx.insert("hamster_error", &e),
    }
    app.page("cachehamster.html", ctx, &csrf)
}

// What: when a job runs, as a command word.
// Why: the page sends unix seconds for "at".
// From: Issue #871 | PR #1980
pub(crate) fn job_time(when: &str, at: &str) -> Result<String, Fail> {
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
// From: Issue #871 | PR #1980
pub(crate) async fn hamster_action(
    State(app): Shared,
    Extension(csrf): Extension<Csrf>,
    Extension(Op(op)): Extension<Op<HamsterOp>>,
    Form(form): Form<Fields>,
) -> Page {
    csrf.check(&form)?;
    let get = |k: &str| field(&form, k);
    let when = job_time(&get("when"), &get("at"))?;
    let what = match get("app").as_str() {
        "" => get("urls"),
        id => format!("app:{id}"),
    };
    let (name, id) = (get("name"), get("id"));
    // What: a job needs addresses or an app ID.
    // Why: the text in the page language.
    // From: Issue #871 | PR #1980
    if matches!(op, HamsterOp::Add) && what.trim().is_empty() {
        return Err(bad_request(tr("err_hamster_empty")));
    }
    // What: the cachehamster command of each action.
    // Why: the daemon protocol names commands, not paths.
    // From: Issue #871
    let args: Vec<&str> = match op {
        HamsterOp::Add => vec!["add", &name, &when, &what],
        HamsterOp::Start => vec!["start", &id],
        HamsterOp::Cancel => vec!["cancel", &id],
        HamsterOp::Remove => vec!["remove", &id],
        HamsterOp::Logout => vec!["logout"],
    };
    let back = app.settings().text("UI_PAGE_CACHEHAMSTER")?;
    finish(hamster(&app, &args).await.map(drop), &back)
}

// What: JSON calls: QR login and library.
// Why: the page polls without a reload.
// From: Issue #871 | PR #1980
pub(crate) async fn hamster_api(
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
    // Why: the sum must not lag behind a wipe.
    // From: Issue #871 | PR #1991
    if let Some(freed) = v.get("freed").and_then(Value::as_u64) {
        let _ = app
            .cache_used
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |n| {
                (n != u64::MAX).then(|| n.saturating_sub(freed))
            });
    }
    Ok(axum::Json(v).into_response())
}

// What: drop proxy render files no longer written.
// Why: an old https.conf keeps the SSL server alive.
// From: Issue #1683 | PR #2019
pub(crate) fn prune_rendered(s: &Settings, files: &[render::File]) -> Result<Vec<PathBuf>, String> {
    let conf = PathBuf::from(s.text("NGINX_CONF_DIR")?);
    let mut removed = Vec::new();
    for sub in ["conf.d", "stream.d"] {
        let dir = conf.join(sub);
        let kept: std::collections::BTreeSet<&std::path::Path> = files
            .iter()
            .map(|f| f.path.as_path())
            .filter(|p| p.parent() == Some(dir.as_path()))
            .collect();
        // What: skip a dir this render did not fill.
        // Why: an empty set must not wipe the dir.
        // From: Issue #1683 | PR #2019
        if kept.is_empty() {
            continue;
        }
        let entries = crate::shared::fs::entries_if_present(&dir)
            .map_err(|e| format!("{}: {e}", dir.display()))?;
        for path in entries {
            if path.is_file() && !kept.contains(path.as_path()) {
                std::fs::remove_file(&path).map_err(|e| format!("{}: {e}", path.display()))?;
                removed.push(path);
            }
        }
    }
    Ok(removed)
}

// What: container name per plan owner; others drop out.
// Why: an owner without a container has nothing to do.
// From: Issue #1683 | PR #2017
pub(crate) async fn plan_containers<V>(
    app: &App,
    s: &Settings,
    plan: &mut BTreeMap<String, V>,
) -> (BTreeMap<String, String>, Vec<String>) {
    let (mut names, mut skipped) = (BTreeMap::new(), Vec::new());
    for owner in plan.keys() {
        match container_of(app, s, owner).await {
            Ok(name) => {
                names.insert(owner.clone(), name);
            }
            Err(e) => skipped.push(format!("{owner}: skipped, {e}")),
        }
    }
    plan.retain(|owner, _| names.contains_key(owner));
    (names, skipped)
}

// What: render with the live chain, then write.
// Why: apply and start share one way to the files.
// From: Issue #1683 | PR #2019
pub(crate) async fn render_and_write(
    s: &Settings,
) -> Result<(Vec<render::File>, Vec<config::Change>), String> {
    let sec = render::secrets(s)?;
    let chain = dnssec_chain(s).await;
    let files = render::all(s, &sec, &chain).map_err(|e| e.join("; "))?;
    let written = render::write_files(s, &files)?;
    Ok((files, written))
}

// What: render, write and wake the owners.
// Why: only owners with changes are touched.
// From: Issue #1683 | PR #1980
pub(crate) async fn apply_all(
    app: &App,
    old: &Settings,
    new: &Settings,
    zones: bool,
) -> Result<Vec<String>, String> {
    let (files, written) = render_and_write(new).await?;
    let mut changes = old.diff(new);
    app.rendered.store(true, Ordering::Relaxed);
    changes.extend(written.iter().cloned());
    // What: drop proxy render files no longer written.
    // Why: a left-over https.conf keeps the SSL server up.
    // From: Issue #1683 | PR #2019
    let removed = prune_rendered(new, &files)?;
    if !removed.is_empty() {
        for path in &removed {
            eprintln!("ui: removed stale {}", path.display());
        }
        changes.push(config::Change {
            key: "proxy-prune".into(),
            owner: new.text("PROXY_SERVICE")?,
            effect: config::Effect::Reload,
        });
    }
    // What: PowerDNS steps report, not abort.
    // Why: pdns starts only after the restart below.
    // From: Issue #1683 | PR #1980
    let mut report = Vec::new();
    // What: a new file runs the commands of its daemon.
    // Why: snmpd and pdns read their file only at start.
    // From: Issue #1683
    let (_, limit) = app.limits(new)?;
    for (file, exec, tag) in [
        ("SNMPD_CONF_FILE", "SNMPD_RELOAD_EXEC", "snmpd"),
        ("PDNS_CONF_FILE", "PDNS_RESTART_EXEC", "pdns"),
        ("DNSDIST_CONF_FILE", "DNSDIST_RESTART_EXEC", "dnsdist"),
    ] {
        let path = new.text(file)?;
        if !written.iter().any(|c| c.key == path) {
            continue;
        }
        let ex = new.list(exec);
        let owners: std::collections::BTreeSet<&str> = ex
            .iter()
            .filter_map(|e| e.split_once(':'))
            .map(|p| p.0)
            .collect();
        for owner in owners {
            match container_of(app, new, owner).await {
                Ok(name) => {
                    let r = apply::reload_exec(&app.docker, &name, &ex, owner, limit).await;
                    report.push(format!("{owner} {tag}: {r:?}"));
                }
                Err(e) => report.push(format!("{owner} {tag}: skipped, {e}")),
            }
        }
    }
    // What: at start zones_at_start owns this step.
    // Why: dns may not be up yet at that moment.
    // From: Issue #1683 | PR #1980
    if zones && let Err(e) = ensure_zones(new).await {
        report.push(e);
    }
    // What: render again once the zones stand.
    // Why: a new zone has its DS only after ensure.
    // From: Issue #1683 | PR #2019
    if zones {
        match render_and_write(new).await {
            Ok((_, again)) => changes.extend(again),
            Err(e) => report.push(e),
        }
    }
    let mut plan = apply::plan(&changes);
    let (grace, limit) = app.limits(new)?;
    // What: mode off stops dhcp; a missing one is fine.
    // Why: compose up may have started it again.
    // From: Issue #1683 | PR #1980
    let dhcp = new.text("DHCP_SERVICE")?;
    if crate::shared::dhcp::off_service(new)?.is_some() {
        plan.remove(&dhcp);
        match dhcp_stays_off(app, new).await {
            Ok(Some(done)) => report.push(format!("{dhcp}: {done}")),
            Ok(None) => {}
            Err(e) => report.push(format!("{dhcp}: mode off, {e}")),
        }
    }
    // What: proxy and relay share one dnsmasq daemon.
    // Why: a mode change keeps the container running.
    // From: Issue #1683
    let (was, now) = (DhcpMode::from_settings(old)?, DhcpMode::from_settings(new)?);
    if was.is_dnsmasq() && now.is_dnsmasq() && plan.contains_key(&dhcp) {
        let ex = new.list("DNSMASQ_RESTART_EXEC");
        match container_of(app, new, &dhcp).await {
            Ok(name) if !ex.is_empty() => {
                let r = apply::reload_exec(&app.docker, &name, &ex, &dhcp, limit).await;
                if !matches!(r, apply::Outcome::Failed(_)) {
                    plan.remove(&dhcp);
                }
                report.push(format!("{dhcp} dnsmasq: {r:?}"));
            }
            Ok(_) => {}
            Err(e) => report.push(format!("{dhcp} dnsmasq: skipped, {e}")),
        }
    }
    // What: skip an owner that has no container yet.
    // Why: at stack start it reads the new files anyway.
    // From: Issue #1683 | PR #1980
    let (names, skipped) = plan_containers(app, new, &mut plan).await;
    report.extend(skipped);
    let lookup = |owner: &str| names.get(owner).cloned().unwrap_or_default();
    let rx = new.list("RELOAD_EXEC");
    let mut restarted = Vec::new();
    let mut results = apply::run(&app.docker, &plan, &rx, &lookup, grace, limit).await;
    // What: one more try for owners that got a 409.
    // Why: compose may recreate a container meanwhile.
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
    for name in wait_healthy(app, new, &restarted, limit).await? {
        report.push(format!("{name}: not healthy in time"));
    }

    // What: after a dns restart wait for the pdns API.
    // Why: a page must not load before pdns runs.
    // From: Issue #1683 | PR #1980
    if names
        .get(&new.text("DNS_SERVICE")?)
        .is_some_and(|n| restarted.contains(n))
    {
        let until = std::time::Instant::now() + limit;
        let poll = Duration::from_secs(new.uint("APPLY_HEALTH_POLL_SECONDS")?);
        while let Err(e) = ensure_zones(new).await {
            if std::time::Instant::now() >= until {
                report.push(format!("dns api: {e}"));
                break;
            }
            tokio::time::sleep(poll).await;
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
                owner: new.text("PROXY_SERVICE")?,
                effect: config::Effect::Reload,
            }]);
            let (names, _) = plan_containers(app, new, &mut plan).await;
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
pub(crate) async fn wait_healthy(
    app: &App,
    s: &Settings,
    names: &[String],
    limit: Duration,
) -> Result<Vec<String>, String> {
    let wait = Duration::from_secs(s.uint("APPLY_HEALTH_WAIT_SECONDS")?);
    let poll = Duration::from_secs(s.uint("APPLY_HEALTH_POLL_SECONDS")?);
    let end = std::time::Instant::now() + wait;
    let mut late = Vec::new();
    for name in names {
        loop {
            let state = app.docker.inspect(name, limit).await.ok();
            let health = state.as_ref().map(docker::Health::from_inspect);
            if matches!(
                health,
                Some(docker::Health::Healthy | docker::Health::Degraded)
            ) {
                break;
            }
            if std::time::Instant::now() >= end {
                late.push(name.clone());
                break;
            }
            tokio::time::sleep(poll).await;
        }
    }
    Ok(late)
}

// What: start or stop a container for the user.
// Why: SERVICES_STOPPED is the wish the watchdog obeys.
// From: Issue #1683 | PR #1980
pub(crate) async fn set_wanted(app: &App, service: &str, run: bool) -> Result<(), String> {
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

// What: HTTPS IP when HTTPS runs on its own LAN IP.
// Why: one rule for the DNS page and the ns2 record.
// From: Issue #1683 | PR #1980
pub(crate) fn primary_https_ip(s: &Settings) -> Result<String, String> {
    let https = s.text_or_empty("IP_HTTPS");
    let own = !https.is_empty()
        && https != s.text("IP_HTTP")?
        && !crate::shared::dns::is_loopback(&https);
    // What: no HTTPS part while HTTPS is off.
    // Why: the field woke HTTPS that was off.
    // From: Issue #1683 | PR #1980
    let own = own && s.flag("HTTPS_ENABLED")?;
    Ok(if own { https } else { String::new() })
}

// What: seconds as "4 h", "90 min" or "45 s".
// Why: the page shows the SOT check times readably.
// From: Issue #1683
pub(crate) fn duration_text(secs: u64) -> String {
    match secs {
        s if s >= 3600 && s % 3600 == 0 => format!("{} h", s / 3600),
        s if s >= 60 && s % 60 == 0 => format!("{} min", s / 60),
        s => format!("{s} s"),
    }
}

// What: retry zones and TSIG until pdns answers.
// Why: at ui start the dns container may not run yet.
// From: Issue #1683 | PR #1980
pub(crate) async fn zones_at_start(app: Arc<App>) {
    let began = std::time::Instant::now();
    loop {
        let s = app.settings();
        let Some(wait) = or_stop("start zones", s.uint("PDNS_SOA_COLD_RETRY")) else {
            return;
        };
        let Some(grace) = or_stop("start zones", s.uint("UI_FLUSH_GRACE_SECONDS")) else {
            return;
        };
        match ensure_zones(&s).await {
            Ok(()) => {
                eprintln!("ui: start: zones ready");
                // What: the anchors once pdns answers.
                // Why: the start render ran before dns.
                // From: Issue #1683 | PR #2019
                match render_and_write(&s).await {
                    Ok((_, written)) => {
                        for line in reload_changed(&app, &s, &written).await {
                            eprintln!("ui: start: {line}");
                        }
                    }
                    Err(e) => eprintln!("ui: start: anchors: {e}"),
                }
                return;
            }
            // What: log only after the grace time.
            // Why: dns starts together with the ui.
            // From: Issue #1683 | PR #1980
            Err(e) if began.elapsed().as_secs() >= grace => {
                eprintln!("ui: start: zones wait for dns {grace} s: {e}");
            }
            Err(_) => {}
        }
        tokio::time::sleep(Duration::from_secs(wait)).await;
    }
}

// What: reload the dns recursors when a config changed.
// Why: a reload picks up a new zone without a restart.
// From: Issue #1683
pub(crate) async fn reload_changed(
    app: &App,
    s: &Settings,
    changed: &[config::Change],
) -> Vec<String> {
    let mut report = Vec::new();
    let mut plan = apply::plan(changed);
    if plan.is_empty() {
        return report;
    }
    let Ok((grace, limit)) = app.limits(s) else {
        return vec!["limits unreadable".into()];
    };
    let (names, skipped) = plan_containers(app, s, &mut plan).await;
    report.extend(skipped);
    let lookup = |owner: &str| names.get(owner).cloned().unwrap_or_default();
    let rx = s.list("RELOAD_EXEC");
    for (owner, r) in apply::run(&app.docker, &plan, &rx, &lookup, grace, limit).await {
        report.push(format!("{owner}: {r:?}"));
    }
    report
}

// What: bytes of a whole GiB number.
// Why: cache sizes are whole GiB only.
// From: Issue #1683 | PR #1980
pub(crate) fn gib_bytes(text: &str) -> Result<u64, String> {
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
pub(crate) fn cache_reachable(s: &Settings, old: u64, cached: u64) -> Result<u64, String> {
    // What: the cache volume as the ui mounts it.
    // Why: NGINX_CACHE_DIR exists in the proxy only.
    // From: Issue #1069 | PR #1980
    let dir = s.text("CACHE_DIR")?;
    let sp = fs::space(Path::new(&dir)).map_err(|e| format!("{dir}: {e}"))?;
    // What: measured cache bytes; disk use as fallback.
    // Why: the disk holds files of the system too.
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
pub(crate) fn cache_room(s: &Settings, form: &Fields, cached: u64) -> Result<(), Fail> {
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

// What: container states for the beambar.
// Why: Docker is the source; no status files.
// From: Issue #1683 | PR #1980
pub(crate) async fn status(State(app): Shared) -> Response {
    let s = app.settings();
    let stopped = s.list("SERVICES_STOPPED");
    // What: the dhcp container while DHCP_MODE is off.
    // Why: the bar must not offer Start for it.
    // From: Issue #1683 | PR #1980
    let read = (app.limits(&s), crate::shared::dhcp::off_service(&s));
    let list = project_containers(&app, &s).await.ok();
    let (Some(list), (Ok((_, limit)), Ok(off))) = (list, read) else {
        return axum::Json(json!({"state": "unavailable"})).into_response();
    };
    let off = off.unwrap_or_default();
    let mut rows: Vec<Value> = Vec::new();
    for c in &list {
        let name = docker::service_of(c).unwrap_or_default();
        let by_user = stopped.iter().any(|x| x == name);
        let mode_off = !off.is_empty() && name == off;
        // What: colour and reason from the full state.
        // Why: one rule with the watchdog (work item 30).
        // From: Issue #1683
        let inspect = match c["Id"].as_str() {
            Some(id) => app.docker.inspect(id, limit).await.unwrap_or_default(),
            None => Value::Null,
        };
        let health = docker::Health::from_inspect(&inspect);
        let colour = health.colour(!by_user && !mode_off);
        // What: last health check output when not green.
        // Why: a failure count alone names no reason.
        // From: Issue #1683 | PR #1980
        let reason = match colour {
            "red" | "yellow" | "amber" => docker::last_check(&inspect).trim().to_string(),
            _ => String::new(),
        };
        rows.push(
            json!({"name": name, "status": colour, "health": c["Status"],
               "reason": reason, "mode_off": mode_off,
               "stopped_by_user": by_user}),
        );
    }
    axum::Json(json!({"state": "ok", "services": rows})).into_response()
}

// What: wish from the beambar button.
// Why: body {"state": "running" or "stopped"}.
// From: Issue #1683 | PR #1980
#[derive(serde::Deserialize)]
pub(crate) struct Want {
    pub(crate) state: String,
}

// What: start or stop one container.
// Why: the wish is saved first; see set_wanted.
// From: Issue #1683 | PR #1980
pub(crate) async fn container_state(
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
// From: Issue #1683 | PR #1980
pub(crate) async fn restart_ui(
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
pub(crate) async fn health(State(app): Shared) -> Response {
    if app.rendered.load(Ordering::Relaxed) {
        "ok".into_response()
    } else {
        (StatusCode::SERVICE_UNAVAILABLE, "configs not rendered").into_response()
    }
}

// What: a built-in file with its content type.
// Why: css, icon and logo are read once at start.
// From: Issue #1683 | PR #1980
pub(crate) fn asset(kind: &'static str, body: &'static [u8]) -> Response {
    ([(header::CONTENT_TYPE, kind)], body).into_response()
}

// What: password against a stored PHC hash.
// Why: one owner for login and change.
// From: Issue #1683 | PR #1980
pub(crate) fn verify(hash: &str, pw: &str) -> bool {
    let phc = stored_phc(hash);
    let Ok(parsed) = PasswordHash::new(&phc) else {
        return false;
    };
    Argon2::default()
        .verify_password(pw.as_bytes(), &parsed)
        .is_ok()
}

// What: PHC string of a stored base64url hash.
// Why: the stack .env bars "$", which every PHC has.
// From: Issue #1683 | PR #2017
pub(crate) fn stored_phc(value: &str) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(value)
        .ok()
        .and_then(|bytes| String::from_utf8(bytes).ok())
        .unwrap_or_default()
}

// What: Argon2id PHC hash of a password, base64url.
// Why: one form in the .env for setup.sh and the page.
// From: Issue #1683 | PR #2017
pub(crate) fn env_hash(pw: &str) -> Result<String, String> {
    let hash: Result<PasswordHash, _> = Argon2::default().hash_password(pw.as_bytes());
    hash.map(|h| env_form(&h.to_string()))
        .map_err(|e| e.to_string())
}

// What: a PHC string in its .env form, base64url.
// Why: the stack .env bars "$", which every PHC has.
// From: Issue #1683
pub(crate) fn env_form(phc: &str) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(phc)
}

// What: one line from stdin without its line end.
// Why: both setup.sh commands read their input so.
// From: Issue #1683
pub(crate) fn stdin_line() -> Result<String, String> {
    let mut line = String::new();
    std::io::stdin()
        .read_line(&mut line)
        .map_err(|e| e.to_string())?;
    Ok(line.trim_end_matches(['\r', '\n']).to_string())
}

// What: base64url PHC hash of a password from stdin.
// Why: setup.sh writes it into the stack .env.
// From: Issue #1683 | PR #2017
pub(crate) fn hash_password() -> Result<(), String> {
    let pw = stdin_line()?;
    if pw.is_empty() {
        return Err("the password on stdin is empty".into());
    }
    println!("{}", env_hash(&pw)?);
    Ok(())
}

// What: .env form of a PHC hash from stdin.
// Why: setup.sh moves an old hash without openssl.
// From: Issue #1683
pub(crate) fn encode_password_hash() -> Result<(), String> {
    let phc = stdin_line()?;
    PasswordHash::new(&phc).map_err(|e| format!("no PHC hash on stdin: {e}"))?;
    println!("{}", env_form(&phc));
    Ok(())
}

// What: image identity functions for the page footer.
// Why: Tera checks calls when a template is added.
// From: Issue #1683 | PR #1980
pub(crate) fn register_image_functions(t: &mut Tera) {
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
pub(crate) fn templates(dir: &str) -> Result<Tera, String> {
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
pub(crate) fn texts(dir: &str) -> Result<Texts, String> {
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
pub(crate) fn pick_lang(app: &App, headers: &HeaderMap) -> String {
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
    app.settings().text_or_empty("UI_LANG_DEFAULT")
}

// What: run the request in its language.
// Why: page() reads it; no handler passes it on.
// From: Issue #1683 | PR #1980
pub(crate) async fn lang(State(app): Shared, req: Request, next: Next) -> Response {
    let code = pick_lang(&app, req.headers());
    LANG.scope(code, next.run(req)).await
}

// What: the SOT route key an action enum carries.
// Why: router and handler read one list; no drift.
// From: Issue #1683 | PR #2019
#[derive(Clone, Copy)]
pub(crate) struct Op<T>(T);

macro_rules! route_ops {
    ($name:ident { $($var:ident => $key:literal),+ $(,)? }) => {
        #[derive(Clone, Copy)]
        pub(crate) enum $name { $($var),+ }
        impl $name {
            const ALL: &'static [$name] = &[$($name::$var),+];
            fn key(self) -> &'static str {
                match self { $($name::$var => $key),+ }
            }
        }
    };
}

route_ops!(DnsOp {
    DnsAdd => "UI_ROUTE_DNS_ADD",
    DnsRemove => "UI_ROUTE_DNS_REMOVE",
    DnsToggle => "UI_ROUTE_DNS_TOGGLE",
    AaaaFilter => "UI_ROUTE_AAAA_FILTER",
    QueryLog => "UI_ROUTE_QUERY_LOG",
    DdnsUnsigned => "UI_ROUTE_DDNS_UNSIGNED",
    NsSwitch => "UI_ROUTE_SECONDARY_NS_SWITCH",
    NsAuto => "UI_ROUTE_SECONDARY_NS_AUTO",
    LanAdd => "UI_ROUTE_LAN_ADD",
    LanRemove => "UI_ROUTE_LAN_REMOVE",
    LanDomainAdd => "UI_ROUTE_LAN_DOMAIN_ADD",
    LanDomainRemove => "UI_ROUTE_LAN_DOMAIN_REMOVE",
    LanDomainMain => "UI_ROUTE_LAN_DOMAIN_MAIN",
    PtrAdd => "UI_ROUTE_PTR_ADD",
    PtrRemove => "UI_ROUTE_PTR_REMOVE",
    ZoneRollback => "UI_ROUTE_ZONE_ROLLBACK",
    TsigRotate => "UI_ROUTE_TSIG_ROTATE",
});

route_ops!(DhcpOp {
    Mode => "UI_ROUTE_DHCP_MODE",
    Ddns => "UI_ROUTE_DHCP_DDNS",
    Proxy => "UI_ROUTE_DHCP_PROXY",
    Relay => "UI_ROUTE_DHCP_RELAY",
    SubnetAdd => "UI_ROUTE_SUBNET_ADD",
    SubnetUpdate => "UI_ROUTE_SUBNET_UPDATE",
    SubnetRemove => "UI_ROUTE_SUBNET_REMOVE",
    SubnetOptionAdd => "UI_ROUTE_SUBNET_OPTION_ADD",
    SubnetOptionRemove => "UI_ROUTE_SUBNET_OPTION_REMOVE",
    StaticAdd => "UI_ROUTE_STATIC_ADD",
    StaticRemove => "UI_ROUTE_STATIC_REMOVE",
    LeaseRelease => "UI_ROUTE_LEASE_RELEASE",
    KeaRollback => "UI_ROUTE_KEA_ROLLBACK",
});

route_ops!(HamsterOp {
    Add => "UI_ROUTE_HAMSTER_ADD",
    Start => "UI_ROUTE_HAMSTER_START",
    Cancel => "UI_ROUTE_HAMSTER_CANCEL",
    Remove => "UI_ROUTE_HAMSTER_REMOVE",
    Logout => "UI_ROUTE_HAMSTER_LOGOUT",
});

route_ops!(SecondaryOp {
    Remove => "UI_ROUTE_SECONDARY",
    Rotate => "UI_ROUTE_SECONDARY_ROTATE",
    Health => "UI_ROUTE_SECONDARY_HEALTH",
    Address => "UI_ROUTE_SECONDARY_ADDRESS",
    NsAdd => "UI_ROUTE_SECONDARY_NS_ADD",
    NsRemove => "UI_ROUTE_SECONDARY_NS_REMOVE",
});

// What: command line uses besides the server.
// Why: setup.sh and the healthcheck need them.
// From: Issue #1683 | PR #1980
pub(crate) async fn command(s: &Settings, args: &[String]) -> Option<Result<(), String>> {
    match args.first().map(String::as_str) {
        Some("zone-snapshots") => Some(zone_snapshots_cli(s)),
        Some("zone-rollback") => Some(match &args[1..] {
            [zone, id] => rollback(s, zone, id).await.map(|()| {
                println!("{}", json!({"restored": zone, "snapshot": id}));
            }),
            _ => Err("usage: zone-rollback <zone> <snapshot-id>".into()),
        }),
        Some("healthcheck") => Some(healthcheck(s).await),
        // What: secondary zones and TSIG via the pdns API.
        // Why: a secondary has no ui server to do it.
        // From: Issue #1683
        Some(DHCP_PROBE_CMD) => Some(dhcp_probe_cli(s)),
        _ => None,
    }
}

// What: asks the own health route on loopback.
// Why: the container health check runs this.
// From: Issue #1683 | PR #1980
pub(crate) async fn healthcheck(s: &Settings) -> Result<(), String> {
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
pub(crate) fn router(app: Arc<App>) -> Result<Router, String> {
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
        .route(&p("UI_ROUTE_ZONE_OVERVIEW")?, get(zone_overview))
        .route(&p("UI_ROUTE_DESIRED_STATE")?, post(container_state))
        .route(&p("UI_ROUTE_RESTART_UI")?, post(restart_ui))
        .route(&p("UI_ROUTE_SERVICE_ACTION")?, post(service_action));
    // What: one route per action, tagged with its SOT key.
    // Why: handlers match the key, never a path text.
    // From: Issue #1683
    for &op in DnsOp::ALL {
        pages = pages.route(&p(op.key())?, post(dns_action).layer(Extension(Op(op))));
    }
    for &op in DhcpOp::ALL {
        pages = pages.route(&p(op.key())?, post(dhcp_action).layer(Extension(Op(op))));
    }
    for &op in HamsterOp::ALL {
        pages = pages.route(&p(op.key())?, post(hamster_action).layer(Extension(Op(op))));
    }
    for &op in SecondaryOp::ALL {
        pages = pages.route(
            &p(op.key())?,
            post(secondary_action).layer(Extension(Op(op))),
        );
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
        // What: one size limit for every request body.
        // Why: the SOT owns it, not a library default.
        // From: Issue #1683 | PR #2017
        .layer(axum::extract::DefaultBodyLimit::max(
            s.num::<usize>("UI_REQUEST_BODY_MAX_BYTES")?,
        ))
        .layer(axum::middleware::from_fn_with_state(app.clone(), secure))
        .layer(axum::middleware::from_fn_with_state(app.clone(), lang))
        .with_state(app))
}

// What: security headers on every answer, from SOT.
// Why: no framing, no sniffing, no foreign scripts.
// From: Issue #1683 | PR #1980
pub(crate) async fn secure(State(app): Shared, req: Request, next: Next) -> Response {
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
// From: Issue #1683 | PR #1980
pub async fn run(args: &[String]) -> Result<(), String> {
    let args: Vec<String> = args.to_vec();
    match args.first().map(String::as_str) {
        Some("hash-password") => return hash_password(),
        Some("encode-password-hash") => return encode_password_hash(),
        _ => {}
    }
    let saved = config::saved_file();
    let s = Settings::from_process()?;
    if let Some(done) = command(&s, &args).await {
        return done;
    }
    // What: no login and no opt-out stops the ui.
    // Why: AG-SEC-001: fail closed unless opted out.
    // From: Issue #1683 | PR #1985
    let hash = password_hash(&s);
    if hash.is_empty() && !s.flag("ALLOW_INSECURE_UI")? {
        return Err("Admin-UI authentication is required".into());
    }
    let dir = secret::dir(&s)?;
    let key = secret::resolve(&|_| None, &dir, "UI_SESSION_KEY", fs::Owner::default())
        .map_err(|e| e.to_string())?;
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
    tokio::spawn(secondary_watch(app.clone()));
    let listen = crate::shared::dns::host_port(&s.text("UI_LISTEN")?, s.uint("UI_PORT")?);
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

// What: state of one zone and the worst-of rule.
// Why: in sync only when every managed zone matches.
// From: Issue #1683
#[cfg(test)]
mod tests {
    use super::duration_text;

    // What: check times as h, min or s.
    // Why: the page shows the SOT seconds readably.
    // From: Issue #1683
    #[test]
    fn duration_text_picks_the_largest_whole_unit() {
        assert_eq!(duration_text(14400), "4 h");
        assert_eq!(duration_text(5400), "90 min");
        assert_eq!(duration_text(45), "45 s");
        assert_eq!(duration_text(3601), "3601 s");
    }
}
