//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: cachehamster: prefill queue and Steam QR login.
//! Why: warm the proxy cache now, later or on a schedule.
//! From: Issue #871 | PR #1858

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use base64::Engine as _;
use futures_util::{StreamExt, stream};
use lancache_ng::config::{Settings, process_env};
use lancache_ng::fs::{Owner, Place, write};
use lancache_ng::{clock, http, secret};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::Mutex;

// What: env var naming the saved settings file.
// Why: same lookup as ui and watchdog.
// From: Issue #1683 | PR #1858
const SETTINGS_FILE_ENV: &str = "LANCACHE_SETTINGS_FILE";

// What: file names below CACHEHAMSTER_DATA_DIR.
// Why: the daemon owns jobs; commands drop inbox files.
// From: Issue #871 | PR #1858
const KEY_FILE: &str = "session.key";
const TOKEN_FILE: &str = "session.sealed";
const PENDING_FILE: &str = "login.pending";
const JOBS_FILE: &str = "jobs.json";
const INBOX_DIR: &str = "inbox";

// What: file mode of every file written here.
// Why: the session token and jobs are owner-only.
// From: Issue #871 | PR #1858
const MODE: u32 = 0o600;

// What: when a job may run.
// Why: DoMe: download now, later or scheduled.
// From: Issue #871 | PR #1858
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case", tag = "kind", content = "at")]
enum When {
    Now,
    Later,
    At(u64),
}

// What: what a job fetches.
// Why: plain URLs or a Steam app of the owned library.
// From: Issue #871 | PR #1858
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "kind", content = "value")]
enum Target {
    Urls(Vec<String>),
    SteamApp(u32),
}

// What: lifecycle state of one job.
// Why: the UI shows it; Blocked names a missing part.
// From: Issue #871 | PR #1858
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case", tag = "state", content = "reason")]
enum State {
    Waiting,
    Running,
    Done,
    Failed(String),
    Blocked(String),
    Cancelled,
}

// What: one prefill job as kept in jobs.json.
// Why: survives restarts; the daemon is its only writer.
// From: Issue #871 | PR #1858
#[derive(Clone, Debug, Serialize, Deserialize)]
struct Job {
    id: String,
    name: String,
    target: Target,
    when: When,
    state: State,
    bytes: u64,
    done: u64,
    failed: u64,
    total: u64,
}

// What: an inbox entry written by a command.
// Why: one writer for jobs.json; no lock across processes.
// From: Issue #871 | PR #1858
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "op")]
enum Order {
    Add {
        name: String,
        target: Target,
        when: When,
    },
    Start {
        id: String,
    },
    Cancel {
        id: String,
    },
    Remove {
        id: String,
    },
}

// What: a login started by login-begin, not yet done.
// Why: login-poll needs both ids across processes.
// From: Issue #871 | PR #1858
#[derive(Serialize, Deserialize)]
struct Pending {
    client_id: String,
    request_id: String,
    interval: u64,
}

// What: the sealed Steam session kept on disk.
// Why: DoMe ACK: only an encrypted session token is kept.
// From: Issue #871 | PR #1858
#[derive(Serialize, Deserialize)]
struct Session {
    account: String,
    steam_id: String,
    refresh_token: String,
}

// What: paths and settings for one invocation.
// Why: every command reads the same SOT keys.
// From: Issue #871 | PR #1858
struct Ctx {
    s: Settings,
    dir: PathBuf,
    api: String,
}

impl Ctx {
    fn load() -> Result<Self, String> {
        let saved = process_env(SETTINGS_FILE_ENV).map(PathBuf::from);
        let s = Settings::load(&process_env, saved.as_deref())?;
        let dir = PathBuf::from(s.text("CACHEHAMSTER_DATA_DIR")?);
        let api = s.text("STEAM_API_URL")?.trim_end_matches('/').to_string();
        Ok(Self { s, dir, api })
    }

    fn path(&self, name: &str) -> PathBuf {
        self.dir.join(name)
    }

    fn save(&self, name: &str, body: &[u8]) -> Result<(), String> {
        write(&self.path(name), body, MODE, Place::Replace, Owner::default())
            .map_err(|e| format!("{name}: {e}"))
    }
}

// What: a JSON file, or None when it does not exist.
// Why: a missing file is a normal first state.
// From: Issue #871 | PR #1858
fn read_json<T: for<'a> Deserialize<'a>>(path: &Path) -> Result<Option<T>, String> {
    match std::fs::read(path) {
        Ok(raw) => serde_json::from_slice(&raw)
            .map(Some)
            .map_err(|e| format!("{}: {e}", path.display())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(format!("{}: {e}", path.display())),
    }
}

// What: remove a file; a missing file is fine.
// Why: logout and login cleanup must not hide IO errors.
// From: Issue #871 | PR #1858
fn remove(path: &Path) -> Result<(), String> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(format!("{}: {e}", path.display())),
    }
}

// What: the 32-byte key that seals the session token.
// Why: created once in the data dir, mode 0600.
// From: Issue #871 | PR #1858
fn session_key(c: &Ctx) -> Result<[u8; 32], String> {
    let hex = secret::load_or_create(&c.path(KEY_FILE), || secret::random_hex(32), Owner::default())
        .map_err(|e| format!("{KEY_FILE}: {e}"))?;
    secret::key_bytes(&hex)
}

// What: the stored session, opened in memory only.
// Why: the plaintext token never touches the disk.
// From: Issue #871 | PR #1858
fn load_session(c: &Ctx) -> Result<Option<Session>, String> {
    let sealed = match std::fs::read(c.path(TOKEN_FILE)) {
        Ok(raw) => raw,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("{TOKEN_FILE}: {e}")),
    };
    let plain = secret::open(&session_key(c)?, &sealed)?;
    serde_json::from_slice(&plain)
        .map(Some)
        .map_err(|e| format!("{TOKEN_FILE}: {e}"))
}

// What: seal and store a session.
// Why: single writer of the token file.
// From: Issue #871 | PR #1858
fn store_session(c: &Ctx, session: &Session) -> Result<(), String> {
    let plain = serde_json::to_vec(session).map_err(|e| e.to_string())?;
    c.save(TOKEN_FILE, &secret::seal(&session_key(c)?, &plain)?)
}

// What: POST a form to a Steam Web API method.
// Why: one owner for URL, error text and the response key.
// From: Issue #871 | PR #1858
async fn steam_post(
    client: &reqwest::Client,
    c: &Ctx,
    method: &str,
    form: &[(&str, &str)],
) -> Result<Value, String> {
    let url = format!("{}/{method}/v1/", c.api);
    let resp = client
        .post(&url)
        .form(form)
        .send()
        .await
        .map_err(|e| format!("{method}: {}", http::error_chain(&e)))?;
    let status = resp.status();
    let eresult = resp
        .headers()
        .get("x-eresult")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("?")
        .to_string();
    if !status.is_success() {
        return Err(format!("{method}: HTTP {status}, eresult {eresult}"));
    }
    let body: Value = resp.json().await.map_err(|e| format!("{method}: {e}"))?;
    Ok(body.get("response").cloned().unwrap_or(Value::Null))
}

// What: GET a Steam Web API method with query values.
// Why: read-only service calls use GET.
// From: Issue #871 | PR #1858
async fn steam_get(
    client: &reqwest::Client,
    c: &Ctx,
    method: &str,
    query: &[(&str, &str)],
) -> Result<Value, String> {
    let url = format!("{}/{method}/v1/", c.api);
    let resp = client
        .get(&url)
        .query(query)
        .send()
        .await
        .map_err(|e| format!("{method}: {}", http::error_chain(&e)))?;
    let status = resp.status();
    if !status.is_success() {
        return Err(format!("{method}: HTTP {status}"));
    }
    let body: Value = resp.json().await.map_err(|e| format!("{method}: {e}"))?;
    Ok(body.get("response").cloned().unwrap_or(Value::Null))
}

// What: a string field of a Steam response.
// Why: Steam sends 64-bit ids as strings.
// From: Issue #871 | PR #1858
fn field(v: &Value, key: &str) -> Option<String> {
    match v.get(key)? {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

// What: the SteamID from the refresh token (JWT sub).
// Why: GetOwnedGames and token refresh need it.
// From: Issue #871 | PR #1858
fn steam_id_of(token: &str) -> Result<String, String> {
    let payload = token.split('.').nth(1).ok_or("refresh token is not a JWT")?;
    let raw = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload.trim_end_matches('='))
        .map_err(|e| format!("refresh token payload: {e}"))?;
    let claims: Value = serde_json::from_slice(&raw).map_err(|e| e.to_string())?;
    field(&claims, "sub").ok_or_else(|| "refresh token has no sub".into())
}

// What: the QR code of a challenge URL as inline SVG.
// Why: the UI embeds it; no image file, no CDN.
// From: Issue #871 | PR #1858
fn qr_svg(url: &str) -> Result<String, String> {
    let code = qrcode::QrCode::new(url.as_bytes()).map_err(|e| format!("QR: {e}"))?;
    Ok(code
        .render::<qrcode::render::svg::Color<'_>>()
        .min_dimensions(220, 220)
        .build())
}

// What: start a QR login; answers the QR as SVG.
// Why: DoMe ACK: QR login is the primary login path.
// From: Issue #871 | PR #1858
async fn login_begin(c: &Ctx, client: &reqwest::Client) -> Result<Value, String> {
    let device = c.s.text("STEAM_DEVICE_NAME")?;
    let r = steam_post(
        client,
        c,
        "IAuthenticationService/BeginAuthSessionViaQR",
        &[("device_friendly_name", &device)],
    )
    .await?;
    let pending = Pending {
        client_id: field(&r, "client_id").ok_or("no client_id")?,
        request_id: field(&r, "request_id").ok_or("no request_id")?,
        interval: r.get("interval").and_then(Value::as_u64).unwrap_or(5),
    };
    let url = field(&r, "challenge_url").ok_or("no challenge_url")?;
    c.save(
        PENDING_FILE,
        &serde_json::to_vec(&pending).map_err(|e| e.to_string())?,
    )?;
    Ok(json!({"state": "waiting", "svg": qr_svg(&url)?, "interval": pending.interval}))
}

// What: one poll of a pending QR login.
// Why: on approval the refresh token is sealed at once.
// From: Issue #871 | PR #1858
async fn login_poll(c: &Ctx, client: &reqwest::Client) -> Result<Value, String> {
    let Some(mut p) = read_json::<Pending>(&c.path(PENDING_FILE))? else {
        return Ok(json!({"state": "idle"}));
    };
    let r = steam_post(
        client,
        c,
        "IAuthenticationService/PollAuthSessionStatus",
        &[("client_id", &p.client_id), ("request_id", &p.request_id)],
    )
    .await?;
    if let Some(token) = field(&r, "refresh_token") {
        let session = Session {
            account: field(&r, "account_name").unwrap_or_default(),
            steam_id: steam_id_of(&token)?,
            refresh_token: token,
        };
        store_session(c, &session)?;
        remove(&c.path(PENDING_FILE))?;
        return Ok(json!({"state": "done", "account": session.account}));
    }
    // What: Steam rotates the QR after a while.
    // Why: the UI must show the new code, not a dead one.
    if let Some(new_id) = field(&r, "new_client_id") {
        p.client_id = new_id;
        c.save(PENDING_FILE, &serde_json::to_vec(&p).map_err(|e| e.to_string())?)?;
        if let Some(url) = field(&r, "new_challenge_url") {
            return Ok(json!({"state": "waiting", "svg": qr_svg(&url)?, "interval": p.interval}));
        }
    }
    let scanned = r
        .get("had_remote_interaction")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    Ok(json!({"state": if scanned { "scanned" } else { "waiting" }, "interval": p.interval}))
}

// What: a short-lived access token from the session.
// Why: Web API calls need it; it is never stored.
// From: Issue #871 | PR #1858
async fn access_token(c: &Ctx, client: &reqwest::Client, s: &Session) -> Result<String, String> {
    let r = steam_post(
        client,
        c,
        "IAuthenticationService/GenerateAccessTokenForApp",
        &[("refresh_token", &s.refresh_token), ("steamid", &s.steam_id)],
    )
    .await?;
    field(&r, "access_token").ok_or_else(|| "Steam returned no access token".into())
}

// What: the owned games of the logged-in account.
// Why: the library tab picks apps from this list.
// From: Issue #871 | PR #1858
async fn library(c: &Ctx, client: &reqwest::Client) -> Result<Value, String> {
    let s = load_session(c)?.ok_or("not logged in")?;
    let token = access_token(c, client, &s).await?;
    let r = steam_get(
        client,
        c,
        "IPlayerService/GetOwnedGames",
        &[
            ("access_token", &token),
            ("steamid", &s.steam_id),
            ("include_appinfo", "1"),
            ("include_played_free_games", "1"),
        ],
    )
    .await?;
    let games: Vec<Value> = r
        .get("games")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .map(|g| json!({"appid": g.get("appid"), "name": g.get("name")}))
                .collect()
        })
        .unwrap_or_default();
    Ok(json!({"account": s.account, "games": games}))
}

// What: queue an order for the daemon.
// Why: unique names; the daemon reads them in order.
// From: Issue #871 | PR #1858
fn submit(c: &Ctx, order: &Order) -> Result<Value, String> {
    let name = format!("{}-{}.json", clock::unix_nanos(), secret::random_hex(4));
    let body = serde_json::to_vec(order).map_err(|e| e.to_string())?;
    c.save(&format!("{INBOX_DIR}/{name}"), &body)?;
    Ok(json!({"queued": name}))
}

// What: parse the add command arguments.
// Why: add <name> <now|later|at:UNIX> <app:ID|url,url>.
// From: Issue #871 | PR #1858
fn parse_add(args: &[String]) -> Result<Order, String> {
    let [name, when, what] = args else {
        return Err("usage: add <name> <now|later|at:UNIX> <app:ID|URL,URL>".into());
    };
    let when = match when.as_str() {
        "now" => When::Now,
        "later" => When::Later,
        other => When::At(
            other
                .strip_prefix("at:")
                .and_then(|t| t.parse().ok())
                .ok_or("when must be now, later or at:UNIX")?,
        ),
    };
    let target = match what.strip_prefix("app:") {
        Some(id) => Target::SteamApp(id.parse().map_err(|_| "app id must be a number")?),
        None => Target::Urls(
            what.split([',', '\n'])
                .map(str::trim)
                .filter(|u| !u.is_empty())
                .map(str::to_string)
                .collect(),
        ),
    };
    if matches!(&target, Target::Urls(u) if u.is_empty()) {
        return Err("no URL given".into());
    }
    Ok(Order::Add {
        name: name.clone(),
        target,
        when,
    })
}

// What: the status for the UI: login and jobs.
// Why: one JSON answer per page refresh.
// From: Issue #871 | PR #1858
fn status(c: &Ctx) -> Result<Value, String> {
    let session = load_session(c)?;
    let jobs = read_json::<Vec<Job>>(&c.path(JOBS_FILE))?.unwrap_or_default();
    Ok(json!({
        "logged_in": session.is_some(),
        "account": session.map(|s| s.account),
        "login_pending": c.path(PENDING_FILE).exists(),
        "jobs": jobs,
    }))
}

// What: apply inbox orders to the job list.
// Why: the daemon is the single writer of jobs.json.
// From: Issue #871 | PR #1858
fn take_inbox(c: &Ctx, jobs: &mut Vec<Job>) -> Result<(), String> {
    let dir = c.path(INBOX_DIR);
    let mut names: Vec<PathBuf> = match std::fs::read_dir(&dir) {
        Ok(rd) => rd
            .map(|e| e.map(|e| e.path()))
            .collect::<Result<_, _>>()
            .map_err(|e| format!("{}: {e}", dir.display()))?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(format!("{}: {e}", dir.display())),
    };
    names.sort();
    for path in names {
        match read_json::<Order>(&path) {
            Ok(Some(order)) => apply_order(jobs, order),
            Ok(None) => {}
            Err(e) => eprintln!("cachehamster: dropped bad order: {e}"),
        }
        remove(&path)?;
    }
    Ok(())
}

// What: one order applied to the list.
// Why: start lifts a later job; cancel stops a running one.
// From: Issue #871 | PR #1858
fn apply_order(jobs: &mut Vec<Job>, order: Order) {
    match order {
        Order::Add { name, target, when } => {
            let total = match &target {
                Target::Urls(u) => u.len() as u64,
                Target::SteamApp(_) => 0,
            };
            jobs.push(Job {
                id: secret::random_hex(6),
                name,
                target,
                when,
                state: State::Waiting,
                bytes: 0,
                done: 0,
                failed: 0,
                total,
            });
        }
        Order::Start { id } => {
            for j in jobs.iter_mut().filter(|j| j.id == id) {
                j.when = When::Now;
                if j.state != State::Running {
                    j.state = State::Waiting;
                }
            }
        }
        Order::Cancel { id } => {
            for j in jobs.iter_mut().filter(|j| j.id == id) {
                j.state = State::Cancelled;
            }
        }
        Order::Remove { id } => jobs.retain(|j| j.id != id || j.state == State::Running),
    }
}

// What: true when a waiting job may start now.
// Why: later waits for Start; At waits for its time.
// From: Issue #871 | PR #1858
fn due(job: &Job, now: u64) -> bool {
    job.state == State::Waiting
        && match job.when {
            When::Now => true,
            When::Later => false,
            When::At(t) => t <= now,
        }
}

// What: count one finished fetch into its job.
// Why: false stops the job after a cancel.
// From: Issue #871 | PR #1858
async fn count(jobs: &Mutex<Vec<Job>>, id: &str, rate: &AtomicU64, got: Option<u64>) -> bool {
    let mut list = jobs.lock().await;
    let Some(j) = list.iter_mut().find(|j| j.id == id) else {
        return false;
    };
    match got {
        Some(b) => {
            j.done += 1;
            j.bytes += b;
            rate.fetch_add(b, Ordering::Relaxed);
        }
        None => j.failed += 1,
    }
    j.state != State::Cancelled
}

// What: run one URL job with many connections.
// Why: bytes are read and dropped (RAM sink, no disk).
// From: Issue #871 | PR #1858
async fn run_urls(
    client: reqwest::Client,
    urls: Vec<String>,
    connections: usize,
    jobs: Arc<Mutex<Vec<Job>>>,
    id: String,
    rate: Arc<AtomicU64>,
) -> State {
    let mut fetches = stream::iter(urls)
        .map(|url| {
            let client = client.clone();
            tokio::spawn(async move { http::drain(&client, &url).await })
        })
        .buffer_unordered(connections);
    while let Some(joined) = fetches.next().await {
        let got = match joined {
            Ok(Ok((status, bytes))) if (200..300).contains(&status) => Some(bytes),
            Ok(Ok((status, _))) => {
                eprintln!("cachehamster: job {id}: HTTP {status}");
                None
            }
            Ok(Err(e)) => {
                eprintln!("cachehamster: job {id}: {e}");
                None
            }
            Err(e) => {
                eprintln!("cachehamster: job {id}: task: {e}");
                None
            }
        };
        if !count(&jobs, &id, &rate, got).await {
            return State::Cancelled;
        }
    }
    let list = jobs.lock().await;
    match list.iter().find(|j| j.id == id) {
        Some(j) if j.failed > 0 => State::Failed(format!("{} of {} failed", j.failed, j.total)),
        _ => State::Done,
    }
}

// What: the Steam depot step of an app job.
// Why: manifest request codes need a CM connection; the
//      Web API has no such method (HTTP 404, 01.11.).
// From: Issue #871 | PR #1858
fn steam_app_state(logged_in: bool) -> State {
    if logged_in {
        State::Blocked("Steam depot download needs the CM connection; not built yet".into())
    } else {
        State::Blocked("Steam login missing; scan the QR code first".into())
    }
}

// What: one daemon round: orders in, due jobs out.
// Why: up to CACHEHAMSTER_QUEUES jobs run at once.
// From: Issue #871 | PR #1858
struct Runner {
    client: reqwest::Client,
    queues: usize,
    connections: usize,
    jobs: Arc<Mutex<Vec<Job>>>,
    rate: Arc<AtomicU64>,
    running: BTreeMap<String, tokio::task::JoinHandle<State>>,
}

impl Runner {
    async fn round(&mut self, c: &Ctx) -> Result<(), String> {
        let mut list = self.jobs.lock().await;
        take_inbox(c, &mut list)?;
        let finished: Vec<String> = self
            .running
            .iter()
            .filter(|(_, h)| h.is_finished())
            .map(|(id, _)| id.clone())
            .collect();
        for id in finished {
            if let Some(h) = self.running.remove(&id) {
                let state = h
                    .await
                    .unwrap_or_else(|e| State::Failed(format!("task: {e}")));
                if let Some(j) = list.iter_mut().find(|j| j.id == id) {
                    j.state = state;
                }
            }
        }
        let now = clock::unix_secs();
        let logged_in = c.path(TOKEN_FILE).exists();
        for j in list.iter_mut().filter(|j| due(j, now)) {
            let urls = match &j.target {
                Target::SteamApp(_) => {
                    j.state = steam_app_state(logged_in);
                    continue;
                }
                Target::Urls(urls) => urls.clone(),
            };
            if self.running.len() >= self.queues {
                break;
            }
            j.state = State::Running;
            (j.done, j.failed, j.bytes) = (0, 0, 0);
            let task = run_urls(
                self.client.clone(),
                urls,
                self.connections,
                Arc::clone(&self.jobs),
                j.id.clone(),
                Arc::clone(&self.rate),
            );
            self.running.insert(j.id.clone(), tokio::spawn(task));
        }
        let body = serde_json::to_vec_pretty(&*list).map_err(|e| e.to_string())?;
        c.save(JOBS_FILE, &body)
    }
}

// What: the daemon loop.
// Why: a broken round logs and retries, never exits.
// From: Issue #871 | PR #1858
async fn daemon(c: Ctx) -> Result<(), String> {
    let queues = usize::try_from(c.s.uint("CACHEHAMSTER_QUEUES")?).map_err(|e| e.to_string())?;
    let connections =
        usize::try_from(c.s.uint("CACHEHAMSTER_CONCURRENCY")?).map_err(|e| e.to_string())?;
    let tick = Duration::from_secs(c.s.uint("CACHEHAMSTER_POLL_INTERVAL")?);
    let report = c.s.uint("CACHEHAMSTER_THROUGHPUT_INTERVAL")?;
    // What: a client without the general total timeout.
    // Why: one large body may stream for hours.
    let client = reqwest::Client::builder()
        .pool_max_idle_per_host(connections)
        .build()
        .map_err(|e| format!("HTTP client: {e}"))?;
    let mut list = read_json::<Vec<Job>>(&c.path(JOBS_FILE))?.unwrap_or_default();
    // What: a restart leaves no job in Running.
    // Why: the task that ran it is gone.
    for j in list.iter_mut().filter(|j| j.state == State::Running) {
        j.state = State::Waiting;
    }
    let mut runner = Runner {
        client,
        queues,
        connections,
        jobs: Arc::new(Mutex::new(list)),
        rate: Arc::new(AtomicU64::new(0)),
        running: BTreeMap::new(),
    };
    let mut last = clock::unix_secs();
    loop {
        if let Err(e) = runner.round(&c).await {
            eprintln!("cachehamster: round failed: {e}");
        }
        let now = clock::unix_secs();
        if now >= last + report {
            let bytes = runner.rate.swap(0, Ordering::Relaxed);
            eprintln!(
                "cachehamster: {} jobs running, {} Mbit/s",
                runner.running.len(),
                bytes * 8 / (now - last).max(1) / 1_000_000
            );
            last = now;
        }
        tokio::time::sleep(tick).await;
    }
}

// What: run one command and answer as JSON.
// Why: the UI calls these through docker exec.
// From: Issue #871 | PR #1858
async fn command(c: Ctx, args: &[String]) -> Result<Value, String> {
    let client = http::client(&c.s)?;
    match args.first().map(String::as_str) {
        Some("status") => status(&c),
        Some("login-begin") => login_begin(&c, &client).await,
        Some("login-poll") => login_poll(&c, &client).await,
        Some("login-cancel") => remove(&c.path(PENDING_FILE)).map(|()| json!({"state": "idle"})),
        Some("logout") => remove(&c.path(TOKEN_FILE)).map(|()| json!({"logged_in": false})),
        Some("library") => library(&c, &client).await,
        Some("add") => submit(&c, &parse_add(&args[1..])?),
        Some(op @ ("start" | "cancel" | "remove")) => {
            let id = args.get(1).ok_or("job id missing")?.clone();
            let order = match op {
                "start" => Order::Start { id },
                "cancel" => Order::Cancel { id },
                _ => Order::Remove { id },
            };
            submit(&c, &order)
        }
        _ => Err("commands: daemon status login-begin login-poll login-cancel \
                  logout library add start cancel remove"
            .into()),
    }
}

// What: entry point; no argument runs the daemon.
// Why: one binary for the daemon and UI commands.
// From: Issue #871 | PR #1858
#[tokio::main]
async fn main() -> std::process::ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match Ctx::load() {
        Err(e) => Err(e),
        Ok(c) if args.first().is_none_or(|a| a == "daemon") => {
            daemon(c).await.map(|()| Value::Null)
        }
        Ok(c) => command(c, &args).await,
    };
    match result {
        Ok(v) => {
            println!("{v}");
            std::process::ExitCode::SUCCESS
        }
        Err(e) => {
            println!("{}", json!({"error": e}));
            eprintln!("cachehamster: {e}");
            std::process::ExitCode::FAILURE
        }
    }
}
