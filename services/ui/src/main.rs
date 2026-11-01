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
use lancache_ng::{apply, clock, docker, fs, render, secret};
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
                let pass = tokio::task::spawn_blocking(move || {
                    PasswordHash::new(&hash)
                        .is_ok_and(|h| Argon2::default().verify_password(p.as_bytes(), &h).is_ok())
                })
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
    ctx.insert("warnings", &s.warnings);
    app.page("dashboard.html", ctx, &csrf.0)
}

// What: one setup row for the template.
// Why: the form is built from the SOT schema, not by hand.
// From: Issue #1683 | PR #1858
#[derive(serde::Serialize)]
struct Row {
    key: String,
    value: String,
    kind: String,
    owner: String,
    effect: String,
    secret: bool,
}

// What: setup page: every schema key as a form row.
// Why: new SOT keys appear without ui code changes.
// From: Issue #1683 | PR #1858
async fn setup(State(app): Shared, axum::Extension(csrf): axum::Extension<Csrf>) -> Response {
    let s = app.settings();
    let rows: Vec<Row> = s
        .specs()
        .map(|sp| {
            let secret = matches!(sp.kind, config::Kind::Secret);
            Row {
                key: sp.key.clone(),
                value: if secret {
                    String::new()
                } else {
                    s.text(&sp.key).unwrap_or_default()
                },
                kind: format!("{:?}", sp.kind),
                owner: sp.owner.clone(),
                effect: format!("{:?}", sp.effect),
                secret,
            }
        })
        .collect();
    let mut ctx = Context::new();
    ctx.insert("rows", &rows);
    app.page("setup.html", ctx, &csrf.0)
}

// What: save changed settings, render, write, apply.
// Why: one path for every setting change in the ui.
// From: Issue #1683 | PR #1858
async fn save(
    State(app): Shared,
    axum::Extension(csrf): axum::Extension<Csrf>,
    Form(form): Form<BTreeMap<String, String>>,
) -> Response {
    if !csrf_ok(&form, &csrf) {
        return (StatusCode::FORBIDDEN, "CSRF token mismatch").into_response();
    }
    let Some(path) = app.saved.clone() else {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("{SETTINGS_FILE_ENV} is not set"),
        )
            .into_response();
    };
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
    if let Err(e) = config::store(&path, &old, &updates) {
        return (StatusCode::BAD_REQUEST, e).into_response();
    }
    let new = match Settings::load(&process_env, Some(&path)) {
        Ok(s) => s,
        Err(e) => return (StatusCode::BAD_REQUEST, e).into_response(),
    };
    let report = match apply_all(&app, &old, &new).await {
        Ok(r) => r,
        Err(e) => return (StatusCode::BAD_REQUEST, e).into_response(),
    };
    if let Ok(mut s) = app.settings.write() {
        *s = new;
    }
    for line in &report {
        eprintln!("ui: apply: {line}");
    }
    Redirect::to("/setup").into_response()
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
const ROUTES: [(&str, &str); 6] = [
    ("admin_css", "/static/admin.css"),
    ("favicon", "/favicon.ico"),
    ("logo_icon", "/static/logo-icon.png"),
    ("watchdog_status", "/api/status"),
    ("desired_state", "/api/container/{service}"),
    ("restart_ui", "/api/restart-ui"),
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
    let salt =
        argon2::password_hash::SaltString::generate(&mut argon2::password_hash::rand_core::OsRng);
    let phc = Argon2::default()
        .hash_password(pw.as_bytes(), &salt)
        .map_err(|e| e.to_string())?;
    println!("{phc}");
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
        .route("/api/status", get(status))
        .route("/api/container/{service}", post(container_state))
        .route("/api/restart-ui", post(restart_ui))
        .layer(axum::middleware::from_fn_with_state(app.clone(), auth));
    let router = Router::new()
        .route("/healthz", get(health))
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
