//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: cachehamster: prefill queue, Steam QR and depots.
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
    // What: every state change with its time.
    // Why: shows what happened and if a rerun is due.
    // From: Issue #871 | PR #1980
    #[serde(default)]
    history: Vec<Event>,
}

// What: one history line: unix time and the new state.
// Why: the page lists them per job.
// From: Issue #871 | PR #1980
#[derive(Clone, Debug, Serialize, Deserialize)]
struct Event {
    at: u64,
    #[serde(flatten)]
    state: State,
}

impl Job {
    // What: set the state; log it if it changed.
    // Why: one place keeps state and history in step.
    // From: Issue #871 | PR #1980
    fn set(&mut self, state: State) {
        if self.state != state || self.history.is_empty() {
            self.history.push(Event {
                at: clock::unix_secs(),
                state: state.clone(),
            });
        }
        self.state = state;
    }
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
    // What: the access token of the QR poll, sealed too.
    // Why: client tokens may not renew by Web API.
    // From: Issue #871 | PR #1980
    #[serde(default)]
    access_token: String,
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
        write(
            &self.path(name),
            body,
            MODE,
            Place::Replace,
            Owner::default(),
        )
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
fn session_key(dir: &Path) -> Result<[u8; 32], String> {
    let hex = secret::load_or_create(
        &dir.join(KEY_FILE),
        || secret::random_hex(32),
        Owner::default(),
    )
    .map_err(|e| format!("{KEY_FILE}: {e}"))?;
    secret::key_bytes(&hex)
}

// What: the stored session, opened in memory only.
// Why: the plaintext token never touches the disk.
// From: Issue #871 | PR #1858
fn load_session(dir: &Path) -> Result<Option<Session>, String> {
    let sealed = match std::fs::read(dir.join(TOKEN_FILE)) {
        Ok(raw) => raw,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("{TOKEN_FILE}: {e}")),
    };
    let plain = secret::open(&session_key(dir)?, &sealed)?;
    serde_json::from_slice(&plain)
        .map(Some)
        .map_err(|e| format!("{TOKEN_FILE}: {e}"))
}

// What: seal and store a session.
// Why: single writer of the token file.
// From: Issue #871 | PR #1858
fn store_session(c: &Ctx, session: &Session) -> Result<(), String> {
    let plain = serde_json::to_vec(session).map_err(|e| e.to_string())?;
    c.save(TOKEN_FILE, &secret::seal(&session_key(&c.dir)?, &plain)?)
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
    field(&jwt_claims(token)?, "sub").ok_or_else(|| "refresh token has no sub".into())
}

// What: the claims of a Steam JWT, unchecked.
// Why: sub and exp are read; Steam checks the rest.
// From: Issue #871 | PR #1980
fn jwt_claims(token: &str) -> Result<Value, String> {
    let payload = token
        .split('.')
        .nth(1)
        .ok_or("refresh token is not a JWT")?;
    let raw = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload.trim_end_matches('='))
        .map_err(|e| format!("refresh token payload: {e}"))?;
    serde_json::from_slice(&raw).map_err(|e| e.to_string())
}

// What: the QR code of a challenge URL as inline SVG.
// Why: the UI embeds it; no image file, no CDN.
// From: Issue #871 | PR #1858
fn qr_svg(url: &str, size: u32) -> Result<String, String> {
    let code = qrcode::QrCode::new(url.as_bytes()).map_err(|e| format!("QR: {e}"))?;
    Ok(code
        .render::<qrcode::render::svg::Color<'_>>()
        .min_dimensions(size, size)
        .build())
}

// What: QR edge length in pixels, from the SOT.
// Why: no size literal in code.
// From: Issue #871 | PR #1858
fn qr_size(c: &Ctx) -> Result<u32, String> {
    u32::try_from(c.s.uint("STEAM_QR_SIZE")?).map_err(|e| e.to_string())
}

// What: start a QR login; answers the QR as SVG.
// Why: DoMe ACK: QR login is the primary login path.
// From: Issue #871 | PR #1858
async fn login_begin(c: &Ctx, client: &reqwest::Client) -> Result<Value, String> {
    let device = c.s.text("STEAM_DEVICE_NAME")?;

    // What: login as the Steam client platform (SOT).
    // Why: the Steam CM refuses mobile tokens.
    // From: Issue #871 | PR #1980
    let platform = c.s.uint("STEAM_AUTH_PLATFORM_TYPE")?.to_string();
    let r = steam_post(
        client,
        c,
        "IAuthenticationService/BeginAuthSessionViaQR",
        &[
            ("device_friendly_name", &device),
            ("platform_type", &platform),
        ],
    )
    .await?;
    let pending = Pending {
        client_id: field(&r, "client_id").ok_or("no client_id")?,
        request_id: field(&r, "request_id").ok_or("no request_id")?,
        interval: r
            .get("interval")
            .and_then(Value::as_u64)
            .ok_or("no interval")?,
    };
    let url = field(&r, "challenge_url").ok_or("no challenge_url")?;
    c.save(
        PENDING_FILE,
        &serde_json::to_vec(&pending).map_err(|e| e.to_string())?,
    )?;
    Ok(json!({"state": "waiting", "svg": qr_svg(&url, qr_size(c)?)?, "interval": pending.interval}))
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
            access_token: field(&r, "access_token").unwrap_or_default(),
        };
        store_session(c, &session)?;
        remove(&c.path(PENDING_FILE))?;
        return Ok(json!({"state": "done", "account": session.account}));
    }
    // What: Steam rotates the QR after a while.
    // Why: the UI must show the new code, not a dead one.
    if let Some(new_id) = field(&r, "new_client_id") {
        p.client_id = new_id;
        c.save(
            PENDING_FILE,
            &serde_json::to_vec(&p).map_err(|e| e.to_string())?,
        )?;
        if let Some(url) = field(&r, "new_challenge_url") {
            return Ok(
                json!({"state": "waiting", "svg": qr_svg(&url, qr_size(c)?)?, "interval": p.interval}),
            );
        }
    }
    let scanned = r
        .get("had_remote_interaction")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    Ok(json!({"state": if scanned { "scanned" } else { "waiting" }, "interval": p.interval}))
}

// What: a short-lived access token from the session.
// Why: Web API calls need it; a renewed one is not kept.
// From: Issue #871 | PR #1858
async fn access_token(c: &Ctx, client: &reqwest::Client, s: &Session) -> Result<String, String> {
    // What: the sealed token while it lives a minute more.
    // Why: CM login needs a client token; see login_begin.
    // From: Issue #871 | PR #1980
    let live = jwt_claims(&s.access_token)
        .ok()
        .and_then(|j| j.get("exp").and_then(Value::as_u64))
        .is_some_and(|exp| exp > clock::unix_secs() + 60);
    if live {
        return Ok(s.access_token.clone());
    }
    let r = steam_post(
        client,
        c,
        "IAuthenticationService/GenerateAccessTokenForApp",
        &[
            ("refresh_token", &s.refresh_token),
            ("steamid", &s.steam_id),
        ],
    )
    .await?;
    field(&r, "access_token")
        .ok_or_else(|| "Steam returned no access token; log out and scan the code again".into())
}

// What: the owned games of the logged-in account.
// Why: the library tab picks apps from this list.
// From: Issue #871 | PR #1858
async fn library(c: &Ctx, client: &reqwest::Client) -> Result<Value, String> {
    let s = load_session(&c.dir)?.ok_or("not logged in")?;
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
        return Err("enter addresses or a Steam app ID".into());
    }
    // What: every address must be an http(s) URL.
    // Why: a typo was queued and failed without a word.
    // From: Issue #871 | PR #1980
    if let Target::Urls(u) = &target
        && let Some(bad) = u.iter().find(|u| {
            reqwest::Url::parse(u).map_or(true, |p| !matches!(p.scheme(), "http" | "https"))
        })
    {
        return Err(format!("not an http(s) address: {bad}"));
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
    let session = load_session(&c.dir)?;
    let mut jobs = read_json::<Vec<Job>>(&c.path(JOBS_FILE))?.unwrap_or_default();
    // What: orders the daemon has not taken yet, shown too.
    // Why: a new job was missing until the next round.
    // From: Issue #871 | PR #1980
    let known = jobs.len();
    take_inbox(c, &mut jobs, false)?;
    // What: a queued order has no id yet.
    // Why: its buttons would act on a random id.
    // From: Issue #871 | PR #1980
    for j in jobs.iter_mut().skip(known) {
        j.id.clear();
    }
    // What: the daemon writes jobs.json every round.
    // Why: a stale file means the daemon is down.
    // From: Issue #871 | PR #1980
    let tick = c.s.uint("CACHEHAMSTER_POLL_INTERVAL")?;
    let alive = std::fs::metadata(c.path(JOBS_FILE))
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.elapsed().ok())
        .is_some_and(|age| age.as_secs() <= tick * 3);
    Ok(json!({
        "daemon_running": alive,
        "logged_in": session.is_some(),
        "account": session.map(|s| s.account),
        "login_pending": c.path(PENDING_FILE).exists(),
        "jobs": jobs,
    }))
}

// What: apply inbox orders to the job list.
// Why: the daemon is the single writer of jobs.json.
// From: Issue #871 | PR #1858
fn take_inbox(c: &Ctx, jobs: &mut Vec<Job>, consume: bool) -> Result<(), String> {
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
            Ok(order) => order.into_iter().for_each(|o| apply_order(jobs, o)),
            Err(e) => eprintln!("cachehamster: dropped bad order: {e}"),
        }
        if consume {
            remove(&path)?;
        }
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
                history: vec![Event {
                    at: clock::unix_secs(),
                    state: State::Waiting,
                }],
            });
        }
        Order::Start { id } => {
            for j in jobs.iter_mut().filter(|j| j.id == id) {
                j.when = When::Now;
                // What: a new run counts from zero.
                // Why: else a rerun showed "2 of 1 done".
                // From: Issue #871 | PR #1980
                if j.state != State::Running {
                    (j.done, j.failed, j.bytes) = (0, 0, 0);
                    j.set(State::Waiting);
                }
            }
        }
        Order::Cancel { id } => {
            for j in jobs.iter_mut().filter(|j| j.id == id) {
                j.set(State::Cancelled);
            }
        }
        Order::Remove { id } => jobs.retain(|j| j.id != id || j.state == State::Running),
    }
}

// What: the shared bandwidth limit of all jobs.
// Why: all jobs share one uplink limit.
// From: Issue #871 | PR #1980
static PACE: std::sync::OnceLock<Pace> = std::sync::OnceLock::new();

struct Pace {
    next: std::sync::Mutex<tokio::time::Instant>,
    bytes_per_sec: u64,
}

impl Pace {
    // What: each file books its time after the last one.
    // Why: idle time builds no burst credit.
    // From: Issue #871 | PR #1980
    async fn wait(&self, got: u64) {
        let cost = Duration::from_secs_f64(got as f64 / self.bytes_per_sec as f64);
        let until = {
            let mut next = self
                .next
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            *next = (*next).max(tokio::time::Instant::now()) + cost;
            *next
        };
        tokio::time::sleep_until(until).await;
    }
}

// What: daily window HH:MM-HH:MM; may cross midnight.
// Why: prefill runs only in the set hours.
// From: Issue #871 | PR #1980
fn window(text: &str) -> Result<(u32, u32), String> {
    let mins = |t: &str| -> Option<u32> {
        let (h, m) = t.trim().split_once(':')?;
        let (h, m): (u32, u32) = (h.parse().ok()?, m.parse().ok()?);
        (h <= 24 && m < 60 && h * 60 + m <= 1440).then_some(h * 60 + m)
    };
    text.split_once('-')
        .and_then(|(a, b)| Some((mins(a)?, mins(b)?)))
        .ok_or_else(|| format!("CACHEHAMSTER_WINDOW={text}: use HH:MM-HH:MM"))
}

// What: is the local time inside the window.
// Why: the container clock follows TZ; date reads it.
// From: Issue #871 | PR #1980
fn in_window((from, to): (u32, u32)) -> bool {
    if to.abs_diff(from) == 1440 || from == to {
        return true;
    }
    let now = std::process::Command::new("date")
        .arg("+%H %M")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|t| {
            let (h, m) = t.trim().split_once(' ')?;
            Some(h.parse::<u32>().ok()? * 60 + m.parse::<u32>().ok()?)
        });
    match now {
        Some(n) if from < to => (from..to).contains(&n),
        Some(n) => n >= from || n < to,
        None => true,
    }
}

// What: true when a waiting job may start now.
// Why: later waits for Start; At waits for its time.
// From: Issue #871 | PR #1858
fn is_due(job: &Job, now: u64) -> bool {
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
        if let (Some(b), Some(p)) = (got, PACE.get()) {
            p.wait(b).await;
        }
    }
    let list = jobs.lock().await;
    match list.iter().find(|j| j.id == id) {
        Some(j) if j.failed > 0 => State::Failed(format!("{} of {} failed", j.failed, j.total)),
        _ => State::Done,
    }
}

// What: what the Steam step needs, cloned per job.
// Why: a job task outlives the daemon round.
// From: Issue #871 | PR #1858
#[derive(Clone)]
struct SteamCfg {
    dir: PathBuf,
    api: String,
    limit: Duration,
    manifest_api: u64,
    cell: String,
    heartbeat: Duration,
    // protocol version, package version, OS type, chat mode
    logon: [u64; 4],
    cdn_host: String,
    proxy: std::net::SocketAddr,
    branch: String,
    os: String,
}

impl SteamCfg {
    fn load(c: &Ctx) -> Result<Self, String> {
        let addr = format!("{}:{}", c.s.text("IP_HTTP")?, c.s.uint("PROXY_HTTP_PORT")?);
        Ok(Self {
            dir: c.dir.clone(),
            api: c.api.clone(),
            limit: Duration::from_secs(c.s.uint("HTTP_CLIENT_TIMEOUT")?),
            heartbeat: Duration::from_secs(c.s.uint("STEAM_HEARTBEAT_DEFAULT")?),
            manifest_api: c.s.uint("STEAM_MANIFEST_API_VERSION")?,
            cell: c.s.uint("STEAM_CELL_ID")?.to_string(),
            logon: [
                c.s.uint("STEAM_PROTOCOL_VERSION")?,
                c.s.uint("STEAM_CLIENT_PACKAGE_VERSION")?,
                c.s.uint("STEAM_CLIENT_OS_TYPE")?,
                c.s.uint("STEAM_CHAT_MODE")?,
            ],
            cdn_host: c.s.text("STEAM_CDN_HOST")?,
            proxy: addr.parse().map_err(|e| format!("{addr}: {e}"))?,
            branch: c.s.text("STEAM_BRANCH")?,
            os: c.s.text("STEAM_OS")?,
        })
    }

    // What: a client that sends the CDN host to the proxy.
    // Why: the proxy caches by Host; DNS is not needed.
    fn client(&self) -> Result<reqwest::Client, String> {
        reqwest::Client::builder()
            .resolve(&self.cdn_host, self.proxy)
            .build()
            .map_err(|e| format!("CDN client: {e}"))
    }
}

// What: a minimal text KeyValues (VDF) tree.
// Why: PICS app info arrives as text KeyValues.
// From: Issue #871 | PR #1858
#[derive(Debug, Default)]
struct Kv(Vec<(String, KvValue)>);

#[derive(Debug)]
enum KvValue {
    Text(String),
    Node(Kv),
}

impl Kv {
    fn get(&self, key: &str) -> Option<&KvValue> {
        self.0
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(key))
            .map(|(_, v)| v)
    }

    fn node(&self, key: &str) -> Option<&Kv> {
        match self.get(key)? {
            KvValue::Node(n) => Some(n),
            KvValue::Text(_) => None,
        }
    }

    fn text(&self, key: &str) -> Option<&str> {
        match self.get(key)? {
            KvValue::Text(t) => Some(t),
            KvValue::Node(_) => None,
        }
    }
}

// What: one KeyValues token: a word or a brace.
// Why: a brace is no word; no sentinel string needed.
// From: Issue #871 | PR #1980
enum Tok {
    Word(String),
    Open,
    Close,
}

// What: parse quoted tokens and braces into a Kv tree.
// Why: only the subset Steam sends; escapes are kept.
// From: Issue #871 | PR #1858
fn parse_kv(text: &str) -> Result<Kv, String> {
    let mut tokens: Vec<Tok> = Vec::new();
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' => {
                let mut s = String::new();
                while let Some(c) = chars.next() {
                    match c {
                        '\\' => s.extend(chars.next()),
                        '"' => break,
                        _ => s.push(c),
                    }
                }
                tokens.push(Tok::Word(s));
            }
            '{' => tokens.push(Tok::Open),
            '}' => tokens.push(Tok::Close),
            _ => {}
        }
    }
    let mut stack: Vec<(String, Kv)> = vec![(String::new(), Kv::default())];
    let mut key: Option<String> = None;
    for t in tokens {
        match t {
            Tok::Open => {
                let k = key.take().ok_or("KeyValues: { without key")?;
                stack.push((k, Kv::default()));
            }
            Tok::Close => {
                if key.is_some() {
                    return Err("KeyValues: key without value".into());
                }
                let (k, node) = stack.pop().ok_or("KeyValues: stray }")?;
                let parent = stack.last_mut().ok_or("KeyValues: stray }")?;
                parent.1.0.push((k, KvValue::Node(node)));
            }
            Tok::Word(w) => match key.take() {
                Some(k) => {
                    let top = stack.last_mut().ok_or("KeyValues: empty")?;
                    top.1.0.push((k, KvValue::Text(w)));
                }
                None => key = Some(w),
            },
        }
    }
    let (_, root) = stack.pop().ok_or("KeyValues: empty")?;
    Ok(root)
}

// What: depot id and public manifest id per depot.
// Why: only depots for STEAM_OS (or any OS) are warmed.
// From: Issue #871 | PR #1858
fn depots_of(app: &Kv, cfg: &SteamCfg) -> Vec<(u32, u64)> {
    let Some(depots) = app.node("appinfo").unwrap_or(app).node("depots") else {
        return Vec::new();
    };
    depots
        .0
        .iter()
        .filter_map(|(id, v)| {
            let KvValue::Node(d) = v else { return None };
            let id: u32 = id.parse().ok()?;
            let os_ok = d
                .node("config")
                .and_then(|c| c.text("oslist"))
                .is_none_or(|l| l.is_empty() || l.split(',').any(|o| o == cfg.os));
            let m = d.node("manifests")?;
            let gid = match m.get(&cfg.branch)? {
                KvValue::Text(t) => t.parse().ok()?,
                KvValue::Node(n) => n.text("gid")?.parse().ok()?,
            };
            os_ok.then_some((id, gid))
        })
        .collect()
}

// What: a decoded protobuf field value.
// Why: few Steam messages; coded by hand, no generator.
// From: Issue #871 | PR #1858
#[derive(Clone, Debug)]
enum Pb {
    Int(u64),
    Bytes(Vec<u8>),
}

// What: protobuf writer for the fields Steam needs.
// Why: varint, fixed32, fixed64 and length-delimited.
// From: Issue #871 | PR #1858
#[derive(Default)]
struct PbOut(Vec<u8>);

impl PbOut {
    fn varint(&mut self, mut v: u64) {
        while v >= 0x80 {
            self.0.push((v as u8) | 0x80);
            v >>= 7;
        }
        self.0.push(v as u8);
    }
    fn int(mut self, field: u32, v: u64) -> Self {
        self.varint(u64::from(field) << 3);
        self.varint(v);
        self
    }
    fn fixed64(mut self, field: u32, v: u64) -> Self {
        self.varint((u64::from(field) << 3) | 1);
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    fn fixed32(mut self, field: u32, v: u32) -> Self {
        self.varint((u64::from(field) << 3) | 5);
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    fn bytes(mut self, field: u32, v: &[u8]) -> Self {
        self.varint((u64::from(field) << 3) | 2);
        self.varint(v.len() as u64);
        self.0.extend_from_slice(v);
        self
    }
}

// What: decode one protobuf message into field pairs.
// Why: readers pick fields by number.
// From: Issue #871 | PR #1858
fn pb_read(mut b: &[u8]) -> Result<Vec<(u32, Pb)>, String> {
    fn varint(b: &mut &[u8]) -> Result<u64, String> {
        let mut v = 0u64;
        for shift in (0..64).step_by(7) {
            let (&byte, rest) = b.split_first().ok_or("protobuf: cut varint")?;
            *b = rest;
            v |= u64::from(byte & 0x7f) << shift;
            if byte < 0x80 {
                return Ok(v);
            }
        }
        Err("protobuf: long varint".into())
    }
    let take = |b: &mut &[u8], n: usize| -> Result<Vec<u8>, String> {
        let (head, rest) = b.split_at_checked(n).ok_or("protobuf: cut field")?;
        *b = rest;
        Ok(head.to_vec())
    };
    let mut out = Vec::new();
    while !b.is_empty() {
        let key = varint(&mut b)?;
        let field = u32::try_from(key >> 3).map_err(|e| e.to_string())?;
        let value = match key & 7 {
            0 => Pb::Int(varint(&mut b)?),
            1 => Pb::Int(u64::from_le_bytes(
                take(&mut b, 8)?.try_into().map_err(|_| "fixed64")?,
            )),
            2 => {
                let n = usize::try_from(varint(&mut b)?).map_err(|e| e.to_string())?;
                Pb::Bytes(take(&mut b, n)?)
            }
            5 => Pb::Int(u64::from(u32::from_le_bytes(
                take(&mut b, 4)?.try_into().map_err(|_| "fixed32")?,
            ))),
            w => return Err(format!("protobuf: wire type {w}")),
        };
        out.push((field, value));
    }
    Ok(out)
}

// What: last integer of a protobuf field number.
// Why: protobuf lets a later value override.
fn pb_int(f: &[(u32, Pb)], n: u32) -> Option<u64> {
    f.iter().rev().find_map(|(k, v)| match v {
        Pb::Int(i) if *k == n => Some(*i),
        _ => None,
    })
}

// What: all byte values of a protobuf field.
// Why: repeated fields appear more than once.
fn pb_all(f: &[(u32, Pb)], n: u32) -> impl Iterator<Item = &[u8]> {
    f.iter().filter_map(move |(k, v)| match v {
        Pb::Bytes(b) if *k == n => Some(b.as_slice()),
        _ => None,
    })
}

// What: Steam message numbers (EMsg) used here.
// Why: values from Steam's enums_clientserver.proto.
// From: Issue #871 | PR #1858
const EMSG_MULTI: u32 = 1;
const EMSG_SERVICE_RESPONSE: u32 = 147;
const EMSG_SERVICE_CALL: u32 = 151;
const EMSG_HEARTBEAT: u32 = 703;
const EMSG_LOGON_RESPONSE: u32 = 751;
const EMSG_LOGON: u32 = 5514;
const EMSG_PICS_INFO_REQUEST: u32 = 8903;
const EMSG_PICS_INFO_RESPONSE: u32 = 8904;
const EMSG_PICS_TOKEN_REQUEST: u32 = 8905;
const EMSG_PICS_TOKEN_RESPONSE: u32 = 8906;
// What: protobuf flag of the message number.
// Why: every CM message sent here is protobuf.
const PROTO_MASK: u32 = 0x8000_0000;
// What: Steam result code OK (EResult 1).
// Why: fixed by the protocol, like an RFC constant.
const ERESULT_OK: u64 = 1;

type Ws =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

// What: one CM frame: message number, header, body.
// Why: header fields route job answers.
// From: Issue #871 | PR #1858
struct Frame {
    emsg: u32,
    header: Vec<(u32, Pb)>,
    body: Vec<u8>,
}

// What: our own CM session over a websocket.
// Why: no third-party Steam library.
// From: Issue #871 | PR #1858
struct Cm {
    ws: Ws,
    steam_id: u64,
    session: u64,
    next_job: u64,
    heartbeat: Duration,
    last_beat: std::time::Instant,
    queue: std::collections::VecDeque<Frame>,
    limit: Duration,
}

impl Cm {
    // What: log in with the sealed QR session token.
    // Why: Steam takes the refresh token as access_token.
    async fn login(cfg: &SteamCfg, client: &reqwest::Client) -> Result<Self, String> {
        let s = load_session(&cfg.dir)?.ok_or("Steam login missing")?;
        let steam_id: u64 = steam_id_of(&s.refresh_token)?
            .parse()
            .map_err(|e| format!("steam id: {e}"))?;
        let list: Value = client
            .get(format!("{}/ISteamDirectory/GetCMList/v1/", cfg.api))
            .query(&[("cellid", cfg.cell.as_str())])
            .send()
            .await
            .map_err(|e| format!("CM list: {}", http::error_chain(&e)))?
            .json()
            .await
            .map_err(|e| format!("CM list: {e}"))?;
        let host = list["response"]["serverlist_websockets"][0]
            .as_str()
            .ok_or("CM list: no websocket server")?
            .to_string();
        let (ws, _) = tokio_tungstenite::connect_async(format!("wss://{host}/cmsocket/"))
            .await
            .map_err(|e| format!("CM {host}: {e}"))?;
        let mut cm = Self {
            ws,
            steam_id,
            session: 0,
            next_job: 1,
            heartbeat: cfg.heartbeat,
            last_beat: std::time::Instant::now(),
            queue: Default::default(),
            limit: cfg.limit,
        };
        let ip = PbOut::default().fixed32(1, 0);
        let logon = PbOut::default()
            .int(1, cfg.logon[0])
            .int(5, cfg.logon[1])
            .bytes(6, b"")
            .int(7, cfg.logon[2])
            .bytes(11, &ip.0)
            .int(33, cfg.logon[3])
            .bytes(50, s.account.as_bytes())
            .int(95, 0)
            .bytes(96, b"")
            .int(102, 0)
            .bytes(108, s.refresh_token.as_bytes());
        cm.send(EMSG_LOGON, PbOut::default(), &logon.0).await?;
        let f = cm.wait(|f| f.emsg == EMSG_LOGON_RESPONSE).await?;
        let body = pb_read(&f.body)?;
        match pb_int(&body, 1) {
            Some(ERESULT_OK) => {}
            r => return Err(format!("CM login refused, eresult {r:?}")),
        }
        cm.steam_id = pb_int(&f.header, 1).unwrap_or(steam_id);
        cm.session = pb_int(&f.header, 2).unwrap_or(0);
        if let Some(secs) = pb_int(&body, 3)
            .or_else(|| pb_int(&body, 2))
            .filter(|s| *s > 0)
        {
            cm.heartbeat = Duration::from_secs(secs);
        }
        Ok(cm)
    }

    // What: send one protobuf frame with our session.
    // Why: frame = emsg|flag, header length, header, body.
    async fn send(&mut self, emsg: u32, header: PbOut, body: &[u8]) -> Result<(), String> {
        use futures_util::SinkExt as _;
        let header = header.fixed64(1, self.steam_id).int(2, self.session);
        let mut frame = Vec::with_capacity(8 + header.0.len() + body.len());
        frame.extend_from_slice(&(emsg | PROTO_MASK).to_le_bytes());
        frame.extend_from_slice(&(header.0.len() as u32).to_le_bytes());
        frame.extend_from_slice(&header.0);
        frame.extend_from_slice(body);
        self.ws
            .send(tokio_tungstenite::tungstenite::Message::Binary(
                frame.into(),
            ))
            .await
            .map_err(|e| format!("CM send: {e}"))
    }

    // What: a heartbeat when the interval has passed.
    // Why: the CM drops a silent session.
    async fn beat(&mut self) -> Result<(), String> {
        if self.last_beat.elapsed() >= self.heartbeat {
            self.last_beat = std::time::Instant::now();
            self.send(EMSG_HEARTBEAT, PbOut::default(), &[]).await?;
        }
        Ok(())
    }

    // What: unpack one websocket message into frames.
    // Why: Multi frames bundle many, maybe gzipped.
    fn unpack(&mut self, raw: &[u8]) -> Result<(), String> {
        let word = |b: &[u8], at: usize| -> Result<u32, String> {
            b.get(at..at + 4)
                .and_then(|w| w.try_into().ok())
                .map(u32::from_le_bytes)
                .ok_or_else(|| "CM frame too short".to_string())
        };
        let emsg = word(raw, 0)? & !PROTO_MASK;
        let hlen = usize::try_from(word(raw, 4)?).map_err(|e| e.to_string())?;
        let header = pb_read(raw.get(8..8 + hlen).ok_or("CM header cut")?)?;
        let body = raw.get(8 + hlen..).ok_or("CM body cut")?.to_vec();
        if emsg != EMSG_MULTI {
            self.queue.push_back(Frame { emsg, header, body });
            return Ok(());
        }
        let multi = pb_read(&body)?;
        let packed = pb_all(&multi, 2)
            .next()
            .ok_or("Multi without body")?
            .to_vec();
        let data = if pb_int(&multi, 1).unwrap_or(0) > 0 {
            use std::io::Read as _;
            let mut out = Vec::new();
            flate2::read::GzDecoder::new(packed.as_slice())
                .read_to_end(&mut out)
                .map_err(|e| format!("Multi gzip: {e}"))?;
            out
        } else {
            packed
        };
        let mut at = 0;
        while at < data.len() {
            let n = usize::try_from(word(&data, at)?).map_err(|e| e.to_string())?;
            let inner = data
                .get(at + 4..at + 4 + n)
                .ok_or("Multi part cut")?
                .to_vec();
            self.unpack(&inner)?;
            at += 4 + n;
        }
        Ok(())
    }

    // What: the next frame that matches, within the limit.
    // Why: other frames (notices) are skipped.
    async fn wait(&mut self, want: impl Fn(&Frame) -> bool) -> Result<Frame, String> {
        use futures_util::StreamExt as _;
        let deadline = tokio::time::Instant::now() + self.limit;
        loop {
            if let Some(pos) = self.queue.iter().position(&want) {
                return self.queue.remove(pos).ok_or_else(|| "CM queue".to_string());
            }
            self.queue.clear();
            self.beat().await?;
            let msg = tokio::time::timeout_at(deadline, self.ws.next())
                .await
                .map_err(|_| "CM answer timed out".to_string())?
                .ok_or("CM closed the connection")?
                .map_err(|e| format!("CM read: {e}"))?;
            if let tokio_tungstenite::tungstenite::Message::Binary(raw) = msg {
                self.unpack(&raw)?;
            }
        }
    }

    // What: send a job and wait for its answer frames.
    // Why: the answer carries our job id as jobid_target.
    async fn job(
        &mut self,
        emsg: u32,
        name: Option<&str>,
        body: &[u8],
        answer: u32,
    ) -> Result<Frame, String> {
        let id = self.next_job;
        self.next_job += 1;
        let mut header = PbOut::default().fixed64(10, id);
        if let Some(n) = name {
            header = header.bytes(12, n.as_bytes());
        }
        self.send(emsg, header, body).await?;
        self.wait(|f| f.emsg == answer && pb_int(&f.header, 11) == Some(id))
            .await
    }
}

// What: the app's KeyValues from PICS, with its token.
// Why: owned apps need the PICS access token.
// From: Issue #871 | PR #1858
async fn app_info(cm: &mut Cm, app: u32) -> Result<Kv, String> {
    let req = PbOut::default().int(2, u64::from(app));
    let f = cm
        .job(
            EMSG_PICS_TOKEN_REQUEST,
            None,
            &req.0,
            EMSG_PICS_TOKEN_RESPONSE,
        )
        .await?;
    let tokens = pb_read(&f.body)?;
    let token = pb_all(&tokens, 3)
        .filter_map(|t| pb_read(t).ok())
        .find(|t| pb_int(t, 1) == Some(u64::from(app)))
        .and_then(|t| pb_int(&t, 2))
        .unwrap_or(0);
    let entry = PbOut::default().int(1, u64::from(app)).int(2, token);
    let req = PbOut::default().bytes(2, &entry.0).int(7, 1);
    let mut f = cm
        .job(
            EMSG_PICS_INFO_REQUEST,
            None,
            &req.0,
            EMSG_PICS_INFO_RESPONSE,
        )
        .await?;
    loop {
        let body = pb_read(&f.body)?;
        for a in pb_all(&body, 1) {
            let a = pb_read(a)?;
            if pb_int(&a, 1) == Some(u64::from(app)) {
                let buf = pb_all(&a, 5).next().ok_or("PICS app without buffer")?;
                let text = String::from_utf8_lossy(buf);
                return parse_kv(text.trim_end_matches('\0'));
            }
        }
        if pb_int(&body, 6) != Some(1) {
            return Err(format!("app {app}: no PICS info"));
        }
        f = cm.wait(|f| f.emsg == EMSG_PICS_INFO_RESPONSE).await?;
    }
}

// What: the manifest request code of one depot.
// Why: Steam CDN serves manifests only with this code.
// From: Issue #871 | PR #1858
async fn request_code(
    cm: &mut Cm,
    app: u32,
    depot: u32,
    gid: u64,
    branch: &str,
) -> Result<u64, String> {
    let req = PbOut::default()
        .int(1, u64::from(app))
        .int(2, u64::from(depot))
        .int(3, gid)
        .bytes(4, branch.as_bytes());
    let f = cm
        .job(
            EMSG_SERVICE_CALL,
            Some("ContentServerDirectory.GetManifestRequestCode#1"),
            &req.0,
            EMSG_SERVICE_RESPONSE,
        )
        .await?;
    if let Some(r) = pb_int(&f.header, 13).filter(|r| *r != ERESULT_OK) {
        return Err(format!("depot {depot}: manifest code eresult {r}"));
    }
    pb_int(&pb_read(&f.body)?, 1)
        .filter(|code| *code != 0)
        .ok_or_else(|| format!("depot {depot}: no manifest code (not owned?)"))
}

// What: chunk ids from a zipped binary manifest.
// Why: chunk SHA-1 names the CDN URL; data stays unread.
// From: Issue #871 | PR #1858
fn chunks_of(zipped: &[u8]) -> Result<Vec<String>, String> {
    use std::io::Read as _;
    const PAYLOAD_MAGIC: u32 = 0x71F6_17D0;
    let mut zip = zip::ZipArchive::new(std::io::Cursor::new(zipped))
        .map_err(|e| format!("manifest zip: {e}"))?;
    let mut raw = Vec::new();
    zip.by_index(0)
        .map_err(|e| format!("manifest zip: {e}"))?
        .read_to_end(&mut raw)
        .map_err(|e| format!("manifest zip: {e}"))?;
    let word = |at: usize| -> Result<u32, String> {
        raw.get(at..at + 4)
            .and_then(|b| b.try_into().ok())
            .map(u32::from_le_bytes)
            .ok_or_else(|| "manifest too short".to_string())
    };
    if word(0)? != PAYLOAD_MAGIC {
        return Err("manifest payload magic missing".into());
    }
    let len = usize::try_from(word(4)?).map_err(|e| e.to_string())?;
    let payload = pb_read(raw.get(8..8 + len).ok_or("manifest payload cut short")?)?;
    let mut ids = Vec::new();
    for mapping in pb_all(&payload, 1) {
        for chunk in pb_all(&pb_read(mapping)?, 6) {
            if let Some(sha) = pb_all(&pb_read(chunk)?, 1).next() {
                ids.push(hex::encode(sha));
            }
        }
    }
    ids.sort();
    ids.dedup();
    Ok(ids)
}

// What: every chunk URL of an app's depots.
// Why: the URL job warms them through the proxy.
// From: Issue #871 | PR #1858
async fn app_urls(cfg: &SteamCfg, app: u32) -> Result<Vec<String>, String> {
    let client = cfg.client()?;
    let web = reqwest::Client::new();
    let mut cm = Cm::login(cfg, &web).await?;
    let info = app_info(&mut cm, app).await?;
    let mut urls = Vec::new();
    for (depot, gid) in depots_of(&info, cfg) {
        let code = match request_code(&mut cm, app, depot, gid, &cfg.branch).await {
            Ok(c) => c,
            Err(e) => {
                eprintln!("cachehamster: app {app}: {e}");
                continue;
            }
        };
        let url = format!(
            "http://{}/depot/{depot}/manifest/{gid}/{}/{code}",
            cfg.cdn_host, cfg.manifest_api
        );
        let resp = client
            .get(&url)
            .send()
            .await
            .map_err(|e| format!("{url}: {}", http::error_chain(&e)))?;
        if !resp.status().is_success() {
            eprintln!("cachehamster: {url}: HTTP {}", resp.status());
            continue;
        }
        let body = resp.bytes().await.map_err(|e| format!("{url}: {e}"))?;
        for sha in chunks_of(&body)? {
            urls.push(format!("http://{}/depot/{depot}/chunk/{sha}", cfg.cdn_host));
        }
    }
    if urls.is_empty() {
        return Err(format!("app {app}: no depot of this account and OS"));
    }
    Ok(urls)
}

// What: run a Steam app job: resolve, then warm.
// Why: same queue, connections and RAM sink as URLs.
// From: Issue #871 | PR #1858
async fn run_app(
    cfg: SteamCfg,
    app: u32,
    connections: usize,
    jobs: Arc<Mutex<Vec<Job>>>,
    id: String,
    rate: Arc<AtomicU64>,
) -> State {
    let urls = match app_urls(&cfg, app).await {
        Ok(u) => u,
        Err(e) => return State::Failed(e),
    };
    if let Some(j) = jobs.lock().await.iter_mut().find(|j| j.id == id) {
        j.total = urls.len() as u64;
    }
    let client = match cfg.client() {
        Ok(c) => c,
        Err(e) => return State::Failed(e),
    };
    run_urls(client, urls, connections, jobs, id, rate).await
}

// What: one daemon round: orders in, due jobs out.
// Why: up to CACHEHAMSTER_QUEUES jobs run at once.
// From: Issue #871 | PR #1858
struct Runner {
    client: reqwest::Client,
    steam: SteamCfg,
    queues: usize,
    connections: usize,
    jobs: Arc<Mutex<Vec<Job>>>,
    rate: Arc<AtomicU64>,
    running: BTreeMap<String, tokio::task::JoinHandle<State>>,
    window: (u32, u32),
}

impl Runner {
    async fn round(&mut self, c: &Ctx) -> Result<(), String> {
        let mut list = self.jobs.lock().await;
        take_inbox(c, &mut list, true)?;
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
                    j.set(state);
                }
            }
        }
        // What: outside the window jobs pause as waiting.
        // Why: they start again when the window opens.
        // From: Issue #871 | PR #1980
        if !in_window(self.window) {
            for (id, h) in std::mem::take(&mut self.running) {
                h.abort();
                if let Some(j) = list.iter_mut().find(|j| j.id == id) {
                    j.set(State::Waiting);
                }
            }
            let body = serde_json::to_vec_pretty(&*list).map_err(|e| e.to_string())?;
            return c.save(JOBS_FILE, &body);
        }
        let now = clock::unix_secs();
        let logged_in = c.path(TOKEN_FILE).exists();
        for j in list.iter_mut().filter(|j| is_due(j, now)) {
            if matches!(j.target, Target::SteamApp(_)) && !logged_in {
                j.set(State::Blocked(
                    "Steam login missing; scan the QR code first".into(),
                ));
                continue;
            }
            if self.running.len() >= self.queues {
                break;
            }
            j.set(State::Running);
            (j.done, j.failed, j.bytes) = (0, 0, 0);
            let (jobs, id, rate) = (Arc::clone(&self.jobs), j.id.clone(), Arc::clone(&self.rate));
            let task = match &j.target {
                Target::Urls(urls) => tokio::spawn(run_urls(
                    self.client.clone(),
                    urls.clone(),
                    self.connections,
                    jobs,
                    id,
                    rate,
                )),
                Target::SteamApp(app) => tokio::spawn(run_app(
                    self.steam.clone(),
                    *app,
                    self.connections,
                    jobs,
                    id,
                    rate,
                )),
            };
            self.running.insert(j.id.clone(), task);
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
    let mbit = c.s.uint("CACHEHAMSTER_MAX_MBIT")?;
    if mbit > 0 {
        let _ = PACE.set(Pace {
            next: std::sync::Mutex::new(tokio::time::Instant::now()),
            bytes_per_sec: mbit * 1_000_000 / 8,
        });
    }
    let window = window(&c.s.text("CACHEHAMSTER_WINDOW")?)?;
    // What: the values this start runs with.
    // Why: the log shows the limits in effect.
    // From: Issue #871 | PR #1980
    eprintln!(
        "cachehamster: start: {queues} jobs, {connections} downloads each, {mbit} Mbit/s (0 = off), window {:02}:{:02}-{:02}:{:02}",
        window.0 / 60,
        window.0 % 60,
        window.1 / 60,
        window.1 % 60
    );
    let mut list = read_json::<Vec<Job>>(&c.path(JOBS_FILE))?.unwrap_or_default();
    // What: a restart leaves no job in Running.
    // Why: the task that ran it is gone.
    for j in list.iter_mut().filter(|j| j.state == State::Running) {
        j.set(State::Waiting);
    }
    let mut runner = Runner {
        client,
        steam: SteamCfg::load(&c)?,
        queues,
        connections,
        jobs: Arc::new(Mutex::new(list)),
        rate: Arc::new(AtomicU64::new(0)),
        running: BTreeMap::new(),
        window,
    };
    let mut last = clock::unix_secs();
    let mut shown = (0usize, 0u64);
    loop {
        if let Err(e) = runner.round(&c).await {
            eprintln!("cachehamster: round failed: {e}");
        }
        let now = clock::unix_secs();
        if now >= last + report {
            let bytes = runner.rate.swap(0, Ordering::Relaxed);
            let state = (
                runner.running.len(),
                bytes * 8 / (now - last).max(1) / 1_000_000,
            );
            // What: log while jobs run or the state changed.
            // Why: an idle "0 jobs" line every 10 s is spam.
            // From: Issue #871 | PR #1984
            if state.0 > 0 || state != shown {
                eprintln!("cachehamster: {} jobs running, {} Mbit/s", state.0, state.1);
                shown = state;
            }
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
        _ => Err(
            "commands: daemon status login-begin login-poll login-cancel \
                  logout library add start cancel remove"
                .into(),
        ),
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
