//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later

// BINDING MAINTAINER DECISION [AG-WF-029]
//
// This is the single Rust source file of lancache-ng.
// Every capability MUST live in exactly one module, its
// owner. A module MUST NOT implement the responsibility of
// another module. Shared functionality MUST live in mod
// shared, which MUST NOT collect unrelated domain logic.
//
// This notice is mandatory and MUST be retained verbatim.
//
// Any modification, rewording, shortening, relocation, or removal
// of this notice is explicitly DISACK.

// What: the one lancache-ng program: roles and commands.
// Why: one file and one binary hold every role.
// From: Issue #1683 | PR #2020

// What: cachehamster: prefill queue, Steam QR and depots.
// Why: warm the proxy cache now, later or on a schedule.
// From: Issue #871 | PR #1980
mod cachehamster {
    use std::collections::BTreeMap;
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::Duration;

    use crate::config::Settings;
    use crate::shared::fs::{Owner, PRIVATE_MODE, Place, read_json, write};
    use crate::shared::{clock, http, human, secret};
    use base64::Engine as _;
    use futures_util::{StreamExt, stream};
    use serde::{Deserialize, Serialize};
    use serde_json::{Value, json};
    use tokio::sync::Mutex;

    // What: file names below CACHEHAMSTER_DATA_DIR.
    // Why: the daemon owns jobs; commands drop inbox files.
    // From: Issue #871 | PR #1980
    const KEY_FILE: &str = "session.key";
    // What: name of the sealed session token file.
    // Why: the token is never stored as plain text.
    // From: Issue #1683 | PR #2020
    const TOKEN_FILE: &str = "session.sealed";
    // What: name of the machine binding file.
    // Why: it holds the features the key was frozen on.
    // From: Issue #1683 | PR #2020
    const BIND_FILE: &str = "session.bind";
    // What: name of the pending QR login file.
    // Why: login-poll reads it across processes.
    // From: Issue #1683 | PR #2020
    const PENDING_FILE: &str = "login.pending";
    // What: name of the job list file.
    // Why: the daemon is its only writer.
    // From: Issue #1683 | PR #2020
    const JOBS_FILE: &str = "jobs.json";
    // What: name of the folder of queued orders.
    // Why: commands drop files here, the daemon takes them.
    // From: Issue #1683 | PR #2020
    const INBOX_DIR: &str = "inbox";
    // What: name of the folder of saved depot lists.
    // Why: the library shows cache use without a login.
    // From: Issue #1683 | PR #2020
    const DEPOTS_DIR: &str = "depots";

    // What: path part of every Steam depot URL.
    // Why: the URL builders and key_depot name one path.
    // From: Issue #871 | PR #1991
    const DEPOT_PATH: &str = "/depot/";

    // What: text nginx writes before a cache file key.
    // Why: file head is a header, "\nKEY: ", the key, "\n".
    // From: Issue #871 | PR #1991
    const CACHE_KEY_MARKER: &[u8] = b"\nKEY: ";

    // What: bytes of a cache file head key_depot reads.
    // Why: nginx keeps header and key in its first block.
    // From: Issue #871 | PR #1991
    const CACHE_HEAD_BYTES: usize = 4096;

    // What: when a job may run.
    // Why: a download runs now, later or on a schedule.
    // From: Issue #871 | PR #1980
    #[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
    #[serde(rename_all = "snake_case", tag = "kind", content = "at")]
    enum When {
        Now,
        Later,
        At(u64),
    }

    // What: methods of the start time When.
    // Why: one place maps a start time to its word.
    // From: Issue #1683 | PR #2020
    impl When {
        // What: the command word of a start time.
        // Why: add takes now, later or at:UNIX.
        // From: Issue #871 | PR #2020
        fn word(&self) -> String {
            match self {
                When::Now => "now".to_string(),
                When::Later => "later".to_string(),
                When::At(t) => format!("at:{t}"),
            }
        }

        // What: a start time of its command word.
        // Why: the add command reads what word wrote.
        // From: Issue #871 | PR #2020
        fn from_word(word: &str) -> Result<Self, String> {
            match word {
                "now" => Ok(When::Now),
                "later" => Ok(When::Later),
                other => other
                    .strip_prefix("at:")
                    .and_then(|t| t.parse().ok())
                    .map(When::At)
                    .ok_or_else(|| "when must be now, later or at:UNIX".to_string()),
            }
        }
    }

    // What: the command word of a page's start time choice.
    // Why: the page sends now, later or at plus a time.
    // From: Issue #871 | PR #2020
    pub(crate) fn when_word(choice: &str, at: &str) -> Result<String, String> {
        let when = match choice {
            "at" => When::At(at.parse().map_err(|_| format!("{at:?} is no time"))?),
            "later" => When::Later,
            _ => When::Now,
        };
        Ok(when.word())
    }

    // What: what a job fetches.
    // Why: plain URLs or a Steam app of the owned library.
    // From: Issue #871 | PR #1980
    #[derive(Clone, Debug, Serialize, Deserialize)]
    #[serde(rename_all = "snake_case", tag = "kind", content = "value")]
    enum Target {
        Urls(Vec<String>),
        SteamApp(u32),
    }

    // What: lifecycle state of one job.
    // Why: the UI shows it; Blocked names a missing part.
    // From: Issue #871 | PR #1980
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
    // Why: survives restarts; daemon is its only writer.
    // From: Issue #871 | PR #1980
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
        // What: bytes to fetch, from the depot manifests.
        // Why: the preload size is shown up front.
        // From: Issue #871 | PR #1985
        #[serde(default)]
        size: u64,
        // What: depots Steam refused, with the reason.
        // Why: a refused depot must not vanish unseen.
        // From: Issue #871 | PR #1985
        #[serde(default)]
        skipped: Vec<String>,
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

    // What: methods of a prefill Job.
    // Why: state and history change in one place.
    // From: Issue #1683 | PR #2020
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
    // Why: one writer for jobs.json; no cross-process lock.
    // From: Issue #871 | PR #1980
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
    // From: Issue #871 | PR #1980
    #[derive(Serialize, Deserialize)]
    struct Pending {
        client_id: String,
        request_id: String,
        interval: u64,
    }

    // What: the sealed Steam session kept on disk.
    // Why: only an encrypted session token is kept.
    // From: Issue #871 | PR #1980
    #[derive(Serialize, Deserialize)]
    struct Session {
        account: String,
        steam_id: String,
        refresh_token: String,
        // What: the access token of QR poll, sealed too.
        // Why: client tokens may not renew by Web API.
        // From: Issue #871 | PR #1980
        #[serde(default)]
        access_token: String,
    }

    // What: paths and settings for one invocation.
    // Why: every command reads the same SOT keys.
    // From: Issue #871 | PR #1980
    struct Ctx {
        s: Settings,
        dir: PathBuf,
        api: String,
        bind: Vec<String>,
    }

    // What: methods of the command context Ctx.
    // Why: every command loads settings and paths alike.
    // From: Issue #1683 | PR #2020
    impl Ctx {
        // What: settings, data folder, API base, bind list.
        // Why: every part of the service reads them once.
        // From: Issue #871 | PR #1980
        fn load() -> Result<Self, String> {
            let s = Settings::from_process()?;
            let dir = PathBuf::from(s.text("CACHEHAMSTER_DATA_DIR")?);
            let api = s.text("STEAM_API_URL")?.trim_end_matches('/').to_string();
            let bind = s.list("CACHEHAMSTER_BIND_FILES")?;
            Ok(Self { s, dir, api, bind })
        }

        // What: a file name inside the data folder.
        // Why: all state files live in one folder.
        // From: Issue #871 | PR #1980
        fn path(&self, name: &str) -> PathBuf {
            self.dir.join(name)
        }

        // What: writes a state file by replacing it.
        // Why: a reader never sees a half file.
        // From: Issue #871 | PR #1980
        fn save(&self, name: &str, body: &[u8]) -> Result<(), String> {
            replace_private(&self.path(name), body).map_err(|e| format!("{name}: {e}"))
        }
    }

    // What: a value as JSON bytes; the error as text.
    // Why: every state file and order is JSON.
    // From: Issue #871 | PR #2020
    fn json_bytes<T: Serialize + ?Sized>(v: &T) -> Result<Vec<u8>, String> {
        serde_json::to_vec_pretty(v).map_err(|e| e.to_string())
    }

    // What: replace a file by a private copy of body.
    // Why: all state files share one mode and one write.
    // From: Issue #871 | PR #2020
    fn replace_private(path: &Path, body: &[u8]) -> std::io::Result<()> {
        write(path, body, PRIVATE_MODE, Place::Replace, Owner::default())
    }

    // What: remove a file; a missing file is fine.
    // Why: logout and login cleanup must not hide IO errors
    // From: Issue #871 | PR #1980
    fn delete_file(path: &Path) -> Result<(), String> {
        crate::shared::fs::delete_if_present(path).map_err(|e| format!("{}: {e}", path.display()))
    }

    // What: the 32-byte key that seals the session token.
    // Why: created once in the data dir, mode 0600.
    // From: Issue #871 | PR #1980
    fn session_key(dir: &Path) -> Result<[u8; 32], String> {
        let hex = secret::load_or_create(
            &dir.join(KEY_FILE),
            || secret::random_hex(32),
            Owner::default(),
        )
        .map_err(|e| format!("{KEY_FILE}: {e}"))?;
        secret::key_bytes(&hex)
    }

    // What: one machine feature, trimmed; None if unusable.
    // Why: use what the machine offers, skip the rest.
    // From: Issue #871 | PR #1997
    fn feature(path: &str) -> Option<Vec<u8>> {
        let raw = crate::shared::fs::read_bytes(Path::new(path)).ok()?;
        let text = String::from_utf8_lossy(&raw).trim().to_string();
        (!text.is_empty()).then(|| text.into_bytes())
    }

    // What: seal key: session.key plus machine features.
    // Why: a copied data dir must not open the login.
    // From: Issue #871 | PR #2020
    fn bound_key(dir: &Path, bind: &[String], fresh: bool) -> Result<[u8; 32], String> {
        let salt = session_key(dir)?;
        let path = dir.join(BIND_FILE);
        // What: a QR login freezes the features found now.
        // Why: a feature seen later must not change key.
        // From: Issue #871 | PR #1997
        let names: Vec<String> = if fresh {
            let names: Vec<String> = bind
                .iter()
                .filter(|p| feature(p).is_some())
                .cloned()
                .collect();
            let body = json_bytes(&names)?;
            replace_private(&path, &body).map_err(|e| format!("{BIND_FILE}: {e}"))?;
            names
        } else {
            // What: no bind file means a login from before.
            // Why: only new QR login may freeze features.
            // From: Issue #871 | PR #1997
            read_json(&path)?
                .ok_or("Steam login predates the machine binding; log in again by QR")?
        };
        let mut parts = Vec::with_capacity(names.len());
        for name in names {
            let value = feature(&name)
                .ok_or_else(|| format!("machine feature {name} changed; log in again by QR"))?;
            parts.push((name, value));
        }
        Ok(secret::bind_key(&salt, &parts))
    }

    // What: the stored session, opened in memory only.
    // Why: the plaintext token never touches the disk.
    // From: Issue #871 | PR #1858
    fn load_session(dir: &Path, bind: &[String]) -> Result<Option<Session>, String> {
        let read = crate::shared::fs::read_if_present(&dir.join(TOKEN_FILE));
        let Some(sealed) = read.map_err(|e| format!("{TOKEN_FILE}: {e}"))? else {
            return Ok(None);
        };
        // What: an old or moved login opens no more.
        // Why: the operator must know to scan the QR again.
        // From: Issue #871 | PR #1997
        let plain = secret::open(&bound_key(dir, bind, false)?, &sealed).map_err(|_| {
            "Steam login belongs to other machine features; log in again by QR".to_string()
        })?;
        serde_json::from_slice(&plain)
            .map(Some)
            .map_err(|e| format!("{TOKEN_FILE}: {e}"))
    }

    // What: seal and store a session.
    // Why: single writer of the token file.
    // From: Issue #871 | PR #1980
    fn save_session(c: &Ctx, session: &Session) -> Result<(), String> {
        let plain = json_bytes(session)?;
        c.save(
            TOKEN_FILE,
            &secret::seal(&bound_key(&c.dir, &c.bind, true)?, &plain)?,
        )
    }

    // What: how a Steam Web API call sends its values.
    // Why: write calls post a form, read calls use GET.
    // From: Issue #871 | PR #1980
    enum Req<'a> {
        Get(&'a [(&'a str, &'a str)]),
        Post(&'a [(&'a str, &'a str)]),
    }

    // What: one Steam Web API call; its "response" part.
    // Why: one owner for URL, error text and response key.
    // From: Issue #871 | PR #1980
    async fn steam_api(
        client: &reqwest::Client,
        max: u64,
        api: &str,
        method: &str,
        req: Req<'_>,
    ) -> Result<Value, String> {
        let url = format!("{api}/{method}/v1/");
        let call = match req {
            Req::Get(query) => client.get(&url).query(query),
            Req::Post(form) => client.post(&url).form(form),
        };
        let resp = call
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
        let body: Value = http::read_json(resp, max, method).await?;
        Ok(body.get("response").cloned().unwrap_or(Value::Null))
    }

    // What: a string field of a Steam response.
    // Why: Steam sends 64-bit ids as strings.
    // From: Issue #871 | PR #1980
    fn field(v: &Value, key: &str) -> Option<String> {
        match v.get(key)? {
            Value::String(s) => Some(s.clone()),
            Value::Number(n) => Some(n.to_string()),
            _ => None,
        }
    }

    // What: the SteamID from the refresh token (JWT sub).
    // Why: GetOwnedGames and token refresh need it.
    // From: Issue #871 | PR #1980
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
    // From: Issue #871 | PR #1980
    fn qr_svg(url: &str, size: u32) -> Result<String, String> {
        let code = qrcode::QrCode::new(url.as_bytes()).map_err(|e| format!("QR: {e}"))?;
        Ok(code
            .render::<qrcode::render::svg::Color<'_>>()
            .min_dimensions(size, size)
            .build())
    }

    // What: QR edge length in pixels, from the SOT.
    // Why: no size literal in code.
    // From: Issue #871 | PR #1980
    fn qr_size(c: &Ctx) -> Result<u32, String> {
        c.s.num::<u32>("STEAM_QR_SIZE")
    }

    // What: start a QR login; answers the QR as SVG.
    // Why: QR login is the primary login path.
    // From: Issue #871 | PR #1980
    async fn login_begin(c: &Ctx, client: &reqwest::Client) -> Result<Value, String> {
        let device = c.s.text("STEAM_DEVICE_NAME")?;

        // What: login as the Steam client platform (SOT).
        // Why: the CM refuses tokens of a mobile login.
        // From: Issue #871 | PR #1980
        let platform = c.s.uint("STEAM_AUTH_PLATFORM_TYPE")?.to_string();
        let r = steam_api(
            client,
            http::max_body(&c.s)?,
            &c.api,
            "IAuthenticationService/BeginAuthSessionViaQR",
            Req::Post(&[
                ("device_friendly_name", &device),
                ("platform_type", &platform),
            ]),
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
        c.save(PENDING_FILE, &json_bytes(&pending)?)?;
        Ok(
            json!({"state": "waiting", "svg": qr_svg(&url, qr_size(c)?)?, "interval": pending.interval}),
        )
    }

    // What: one poll of a pending QR login.
    // Why: on approval the refresh token is sealed at once.
    // From: Issue #871 | PR #1980
    async fn login_poll(c: &Ctx, client: &reqwest::Client) -> Result<Value, String> {
        let Some(mut p) = read_json::<Pending>(&c.path(PENDING_FILE))? else {
            return Ok(json!({"state": "idle"}));
        };
        let r = steam_api(
            client,
            http::max_body(&c.s)?,
            &c.api,
            "IAuthenticationService/PollAuthSessionStatus",
            Req::Post(&[("client_id", &p.client_id), ("request_id", &p.request_id)]),
        )
        .await?;
        if let Some(token) = field(&r, "refresh_token") {
            let session = Session {
                account: field(&r, "account_name").unwrap_or_default(),
                steam_id: steam_id_of(&token)?,
                refresh_token: token,
                access_token: field(&r, "access_token").unwrap_or_default(),
            };
            save_session(c, &session)?;
            delete_file(&c.path(PENDING_FILE))?;
            return Ok(json!({"state": "done", "account": session.account}));
        }
        // What: Steam rotates the QR after a while.
        // Why: the UI must show new code, not a dead one.
        // From: Issue #871 | PR #1980
        if let Some(new_id) = field(&r, "new_client_id") {
            p.client_id = new_id;
            c.save(PENDING_FILE, &json_bytes(&p)?)?;
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
    // Why: Web API calls need it; renewed one is not kept.
    // From: Issue #871 | PR #1980
    async fn access_token(
        c: &Ctx,
        client: &reqwest::Client,
        s: &Session,
    ) -> Result<String, String> {
        // What: sealed token while it lives long enough.
        // Why: CM login needs client token; see login_begin
        // From: Issue #871 | PR #1980
        let margin = c.s.uint("STEAM_TOKEN_MARGIN_SECONDS")?;
        let live = jwt_claims(&s.access_token)
            .ok()
            .and_then(|j| j.get("exp").and_then(Value::as_u64))
            .is_some_and(|exp| exp > clock::unix_secs().saturating_add(margin));
        if live {
            return Ok(s.access_token.clone());
        }
        let r = steam_api(
            client,
            http::max_body(&c.s)?,
            &c.api,
            "IAuthenticationService/GenerateAccessTokenForApp",
            Req::Post(&[
                ("refresh_token", &s.refresh_token),
                ("steamid", &s.steam_id),
            ]),
        )
        .await?;
        field(&r, "access_token")
            .ok_or_else(|| "Steam returned no access token; log out and scan the code again".into())
    }

    // What: the owned games of the logged-in account.
    // Why: the library tab picks apps from this list.
    // From: Issue #871 | PR #1980
    async fn library(c: &Ctx, client: &reqwest::Client) -> Result<Value, String> {
        let s = load_session(&c.dir, &c.bind)?.ok_or("not logged in")?;
        let token = access_token(c, client, &s).await?;
        let r = steam_api(
            client,
            http::max_body(&c.s)?,
            &c.api,
            "IPlayerService/GetOwnedGames",
            Req::Get(&[
                ("access_token", &token),
                ("steamid", &s.steam_id),
                ("include_appinfo", "1"),
                ("include_played_free_games", "1"),
            ]),
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
    // From: Issue #871 | PR #1980
    fn submit(c: &Ctx, order: &Order) -> Result<Value, String> {
        let name = format!("{}-{}.json", clock::unix_nanos(), secret::random_hex(4));
        let body = json_bytes(order)?;
        c.save(&format!("{INBOX_DIR}/{name}"), &body)?;
        Ok(json!({"queued": name}))
    }

    // What: parse the add command arguments.
    // Why: add <name> <now|later|at:UNIX> <app:ID|url,url>.
    // From: Issue #871 | PR #1980
    fn parse_add(args: &[String]) -> Result<Order, String> {
        let [name, when, what] = args else {
            return Err(crate::shared::cli::usage(&COMMANDS, |c| c.op == Op::Add));
        };
        let when = When::from_word(when)?;
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
        // Why: a typo must not queue and fail silently.
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

    // What: the daemon writes jobs.json every round.
    // Why: a stale file means the daemon is down.
    // From: Issue #871 | PR #1980
    fn daemon_alive(c: &Ctx) -> Result<bool, String> {
        let tick = c.s.uint("CACHEHAMSTER_POLL_INTERVAL")?;
        let rounds = c.s.uint("CACHEHAMSTER_ALIVE_ROUNDS")?;
        let limit = tick
            .checked_mul(rounds)
            .ok_or("CACHEHAMSTER_POLL_INTERVAL times CACHEHAMSTER_ALIVE_ROUNDS is too big")?;
        Ok(std::fs::metadata(c.path(JOBS_FILE))
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.elapsed().ok())
            .is_some_and(|age| age.as_secs() <= limit))
    }

    // What: the status for the UI: login and jobs.
    // Why: one JSON answer per page refresh.
    // From: Issue #871 | PR #1980
    fn status(c: &Ctx) -> Result<Value, String> {
        // What: an unusable login shows as logged out.
        // Why: the page then offers the QR login again.
        // From: Issue #871 | PR #1997
        let (session, login_error) = match load_session(&c.dir, &c.bind) {
            Ok(s) => (s, None),
            Err(e) => (None, Some(e)),
        };
        let mut jobs = read_json::<Vec<Job>>(&c.path(JOBS_FILE))?.unwrap_or_default();
        // What: orders daemon has not taken yet, shown too.
        // Why: a new job must show before the next round.
        // From: Issue #871 | PR #1980
        let known = jobs.len();
        take_inbox(c, &mut jobs, false)?;
        // What: a queued order has no id yet.
        // Why: its buttons would act on a random id.
        // From: Issue #871 | PR #1980
        for j in jobs.iter_mut().skip(known) {
            j.id.clear();
        }
        Ok(json!({
            "daemon_running": daemon_alive(c)?,
            "logged_in": session.is_some(),
            "login_error": login_error,
            "account": session.map(|s| s.account),
            "login_pending": c.path(PENDING_FILE).exists(),
            "jobs": jobs,
            "limits": limits(c)?,
        }))
    }

    // What: time window and speed cap as JSON.
    // Why: status shows why a job waits or is slow.
    // From: Issue #871 | PR #2020
    fn limits(c: &Ctx) -> Result<Value, String> {
        let text = c.s.text("CACHEHAMSTER_WINDOW")?;
        let zone = c.s.text("LOCALTIME_FILE")?;
        Ok(json!({
            "window": text,
            "in_window": in_window(window(&text)?, Path::new(&zone))?,
            "max_mbit": c.s.uint("CACHEHAMSTER_MAX_MBIT")?,
            "queues": c.s.uint("CACHEHAMSTER_QUEUES")?,
            "connections": c.s.uint("CACHEHAMSTER_CONCURRENCY")?,
        }))
    }

    // What: apply inbox orders to the job list.
    // Why: the daemon is the single writer of jobs.json.
    // From: Issue #871 | PR #1980
    fn take_inbox(c: &Ctx, jobs: &mut Vec<Job>, consume: bool) -> Result<(), String> {
        let dir = c.path(INBOX_DIR);
        let mut names = crate::shared::fs::entries_if_present(&dir)
            .map_err(|e| format!("{}: {e}", dir.display()))?;
        names.sort();
        for path in names {
            match read_json::<Order>(&path) {
                Ok(order) => order.into_iter().for_each(|o| apply_order(jobs, o)),
                Err(e) => eprintln!("cachehamster: dropped bad order: {e}"),
            }
            if consume {
                delete_file(&path)?;
            }
        }
        Ok(())
    }

    // What: one order applied to the list.
    // Why: start lifts later job; cancel stops running one.
    // From: Issue #871 | PR #1980
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
                    size: 0,
                    skipped: Vec::new(),
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
                    // Why: a rerun must not read "2 of 1".
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
    // Why: the jobs must not use the whole line.
    // From: Issue #871 | PR #1980
    static PACE: std::sync::OnceLock<Pace> = std::sync::OnceLock::new();

    // What: the next free time and the byte rate.
    // Why: PACE books each file against these two.
    // From: Issue #871 | PR #1980
    struct Pace {
        next: std::sync::Mutex<tokio::time::Instant>,
        bytes_per_sec: u64,
    }

    // What: methods of the bandwidth limiter Pace.
    // Why: each file books its time through wait.
    // From: Issue #1683 | PR #2020
    impl Pace {
        // What: each file books its time after last one.
        // Why: idle time must not build up credit.
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

    // What: minutes after midnight of HH:MM; 24:00 too.
    // Why: the window and the clock are read the same way.
    // From: Issue #871 | PR #1980
    fn minutes(t: &str) -> Option<u32> {
        let (h, m) = t.trim().split_once(':')?;
        let (h, m): (u32, u32) = (h.parse().ok()?, m.parse().ok()?);
        (h <= 24 && m < 60 && h * 60 + m <= 1440).then_some(h * 60 + m)
    }

    // What: daily window HH:MM-HH:MM; may cross midnight.
    // Why: downloads run from one time until another.
    // From: Issue #871 | PR #1980
    fn window(text: &str) -> Result<(u32, u32), String> {
        text.split_once('-')
            .and_then(|(a, b)| Some((minutes(a)?, minutes(b)?)))
            .ok_or_else(|| format!("CACHEHAMSTER_WINDOW={text}: use HH:MM-HH:MM"))
    }

    // What: is the local time inside the window.
    // Why: the window is local time of the host zone.
    // From: Issue #871 | PR #1980
    fn in_window((from, to): (u32, u32), zone_file: &Path) -> Result<bool, String> {
        if to.abs_diff(from) == 1440 || from == to {
            return Ok(true);
        }
        let n = clock::local_minutes(zone_file)?;
        Ok(if from < to {
            (from..to).contains(&n)
        } else {
            n >= from || n < to
        })
    }

    // What: true when a waiting job may start now.
    // Why: later waits for Start; At waits for its time.
    // From: Issue #871 | PR #1980
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
    // From: Issue #871 | PR #1980
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

    // What: every download host resolves to the proxy.
    // Why: the proxy caches; the host DNS is never asked.
    // From: Issue #871 | PR #2017
    struct ToProxy(String);

    // What: name resolution of the download client.
    // Why: reqwest asks this trait for every host.
    // From: Issue #1683 | PR #2020
    impl reqwest::dns::Resolve for ToProxy {
        // What: answers every name with the proxy.
        // Why: reqwest asks this, not the system DNS.
        // From: Issue #871 | PR #2017
        fn resolve(&self, _: reqwest::dns::Name) -> reqwest::dns::Resolving {
            let proxy = self.0.clone();
            Box::pin(async move {
                let addrs: Vec<std::net::SocketAddr> = tokio::net::lookup_host((proxy.as_str(), 0))
                    .await?
                    .collect();
                if addrs.is_empty() {
                    return Err(format!("{proxy}: no address").into());
                }
                Ok(Box::new(addrs.into_iter()) as reqwest::dns::Addrs)
            })
        }
    }

    // What: the one way every download takes to the cache.
    // Why: AG-CODE-011: Steam, URL jobs and later stores.
    // From: Issue #871 | PR #2017
    #[derive(Clone)]
    struct Dl {
        client: reqwest::Client,
        http: u16,
        https: u16,
    }

    // What: methods of the download path Dl.
    // Why: client and URL rules sit with the type.
    // From: Issue #1683 | PR #2020
    impl Dl {
        // What: client to proxy container; trusts our CA.
        // Why: a direct client saves the docker-proxy load.
        // From: Issue #871 | PR #2017
        fn load(s: &Settings, connections: usize) -> Result<Self, String> {
            let port = |k: &str| s.num::<u16>(k);
            // What: no total timeout; public roots stay.
            // Why: body may stream for hours; others pass.
            // From: Issue #871 | PR #2017
            let mut builder = crate::shared::http::Build::new()
                .resolver(Arc::new(ToProxy(s.text("CONTAINER_NAME_PROXY")?)))
                .per_host(connections);
            let ca = crate::shared::render::ca_cert(s)?;
            match crate::shared::fs::read_if_present(&ca)
                .map_err(|e| format!("{}: {e}", ca.display()))?
            {
                Some(pem) => {
                    builder = builder
                        .trust_also(&pem)
                        .map_err(|e| format!("{}: {e}", ca.display()))?;
                }
                // What: no CA yet: logged; https then fails
                // Why: the ui issues it only in HTTPS mode.
                // From: Issue #871 | PR #2017
                None => {
                    eprintln!("cachehamster: no stack CA {}; https fails", ca.display());
                }
            }
            let client = builder.build("download client")?;
            Ok(Self {
                client,
                http: port("PROXY_HTTP_PORT")?,
                https: port("PROXY_HTTPS_PORT")?,
            })
        }

        // What: the URL on the proxy port of its scheme.
        // Why: SOT ports; a foreign port never reaches it.
        // From: Issue #871 | PR #2017
        fn url(&self, raw: &str) -> Result<reqwest::Url, String> {
            let mut u = reqwest::Url::parse(raw).map_err(|e| format!("{raw}: {e}"))?;
            let port = match u.scheme() {
                "http" => self.http,
                "https" => self.https,
                other => return Err(format!("{raw}: scheme {other} is not http or https")),
            };
            if u.port().is_some() {
                return Err(format!(
                    "{raw}: own port; only standard ports reach the cache"
                ));
            }
            u.set_port(Some(port))
                .map_err(|()| format!("{raw}: no port possible"))?;
            Ok(u)
        }
    }

    // What: one ranged GET through the proxy.
    // Why: shows proxy reach, TLS trust, cache state.
    // From: Issue #871 | PR #2020
    async fn fetch_check(c: &Ctx, args: &[String]) -> Result<Value, String> {
        let raw = match args {
            [u] => u,
            _ => {
                return Err(crate::shared::cli::usage(&COMMANDS, |c| {
                    c.op == Op::FetchCheck
                }));
            }
        };
        let dl = Dl::load(&c.s, 1)?;
        let url = dl.url(raw)?;
        let started = std::time::Instant::now();
        let resp = dl
            .client
            .get(url.clone())
            .header(reqwest::header::RANGE, "bytes=0-0")
            .timeout(http::timeout(&c.s)?)
            .send()
            .await
            .map_err(|e| format!("{url}: {}", http::error_chain(&e)))?;
        let head = |k: &str| {
            resp.headers()
                .get(k)
                .and_then(|v| v.to_str().ok())
                .map(str::to_string)
        };
        Ok(json!({
            "url": raw,
            "via": url.as_str(),
            "status": resp.status().as_u16(),
            "cache_status": head("x-cache-status"),
            "served_by": head("x-served-by"),
            "ms": started.elapsed().as_millis() as u64,
        }))
    }

    // What: session, Web API, CM and CDN, each checked.
    // Why: shows which step blocks Steam jobs.
    // From: Issue #871 | PR #2020
    async fn steam_check(c: &Ctx) -> Result<Value, String> {
        let cfg = SteamCfg::load(c)?;
        let part = |r: Result<Value, String>| match r {
            Ok(v) => json!({"ok": true, "detail": v}),
            Err(e) => json!({"ok": false, "error": e}),
        };
        let session = part(load_session(&cfg.dir, &cfg.bind).and_then(|s| {
            s.map(|s| json!(s.account))
                .ok_or("Steam login missing".into())
        }));
        let api = part(
            cm_list(&cfg, &cfg.web)
                .await
                .map(|l| json!({"cm_servers": l.len()})),
        );
        let cm = part(match session["ok"].as_bool() {
            Some(true) => Cm::login(&cfg, &cfg.web)
                .await
                .map(|cm| json!({"steam_id": cm.steam_id})),
            _ => Err("skipped: no Steam login".into()),
        });
        let cdn = part(fetch_check(c, &[format!("http://{}/", cfg.cdn_host)]).await);
        let all = [&session, &api, &cm, &cdn]
            .iter()
            .all(|p| p["ok"].as_bool() == Some(true));
        Ok(json!({"ok": all, "session": session, "web_api": api, "cm": cm, "cdn": cdn}))
    }

    // What: run one URL job with many connections.
    // Why: bytes are read and dropped (RAM sink, no disk).
    // From: Issue #871 | PR #1980
    async fn run_urls(
        dl: Dl,
        urls: Vec<String>,
        connections: usize,
        jobs: Arc<Mutex<Vec<Job>>>,
        id: String,
        rate: Arc<AtomicU64>,
    ) -> State {
        let mut fetches = stream::iter(urls)
            .map(|url| {
                let dl = dl.clone();
                tokio::spawn(async move { http::drain(&dl.client, dl.url(&url)?.as_str()).await })
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
    // From: Issue #871 | PR #1980
    #[derive(Clone)]
    struct SteamCfg {
        dir: PathBuf,
        bind: Vec<String>,
        api: String,
        limit: Duration,
        manifest_api: u64,
        cell: String,
        heartbeat: Duration,
        // What: logon values: protocol, package, OS, chat.
        // Why: the logon message reads them by index.
        // From: Issue #871 | PR #1980
        logon: [u64; 4],
        cdn_host: String,
        max_body: u64,
        branch: String,
        os: String,
        // What: the shared client with the SOT timeouts.
        // Why: no Steam request may hang without a limit.
        // From: Issue #871 | PR #2020
        web: reqwest::Client,
    }

    // What: methods of the Steam settings SteamCfg.
    // Why: the SOT values are read in one load.
    // From: Issue #1683 | PR #2020
    impl SteamCfg {
        // What: the Steam values of the SOT, read once.
        // Why: a missing key fails before any login.
        // From: Issue #871 | PR #1980
        fn load(c: &Ctx) -> Result<Self, String> {
            Ok(Self {
                dir: c.dir.clone(),
                bind: c.bind.clone(),
                api: c.api.clone(),
                limit: http::timeout(&c.s)?,
                heartbeat: Duration::from_secs(c.s.uint("STEAM_HEARTBEAT_DEFAULT")?),
                manifest_api: c.s.uint("STEAM_MANIFEST_API_VERSION")?,
                cell: c.s.uint("STEAM_CELL_ID")?.to_string(),
                logon: [
                    c.s.uint("STEAM_PROTOCOL_VERSION")?,
                    c.s.uint("STEAM_CLIENT_PACKAGE_VERSION")?,
                    c.s.uint("STEAM_CLIENT_OS_TYPE")?,
                    c.s.uint("STEAM_CHAT_MODE")?,
                ],
                cdn_host: crate::shared::dns::parse_name(&c.s.text("STEAM_CDN_HOST")?)?,
                max_body: http::max_body(&c.s)?,
                branch: c.s.text("STEAM_BRANCH")?,
                os: c.s.text("STEAM_OS")?,
                web: http::client(&c.s)?,
            })
        }
    }

    // What: a minimal text KeyValues (VDF) tree.
    // Why: PICS app info arrives as text KeyValues.
    // From: Issue #871 | PR #1980
    #[derive(Debug, Default)]
    struct Kv(Vec<(String, KvValue)>);

    // What: a value in a KeyValues tree: text or node.
    // Why: Kv holds both kinds under one key list.
    // From: Issue #871 | PR #1980
    #[derive(Debug)]
    enum KvValue {
        Text(String),
        Node(Kv),
    }

    // What: methods of the KeyValues tree Kv.
    // Why: callers walk the tree without a match.
    // From: Issue #1683 | PR #2020
    impl Kv {
        // What: the value of a key, case ignored.
        // Why: Steam writes key names in mixed case.
        // From: Issue #871 | PR #1980
        fn get(&self, key: &str) -> Option<&KvValue> {
            self.0
                .iter()
                .find(|(k, _)| k.eq_ignore_ascii_case(key))
                .map(|(_, v)| v)
        }

        // What: the sub-node of a key, if it is one.
        // Why: callers walk the tree without a match.
        // From: Issue #871 | PR #1980
        fn node(&self, key: &str) -> Option<&Kv> {
            match self.get(key)? {
                KvValue::Node(n) => Some(n),
                KvValue::Text(_) => None,
            }
        }

        // What: the text of a key, if it is one.
        // Why: callers read a leaf without a match.
        // From: Issue #871 | PR #1980
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
    // From: Issue #871 | PR #1980
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

    // What: public manifest id of one depot node.
    // Why: only depots for STEAM_OS (or any OS) are warmed.
    // From: Issue #871 | PR #1858
    fn depot_gid(d: &Kv, cfg: &SteamCfg) -> Option<u64> {
        let os_ok = d
            .node("config")
            .and_then(|c| c.text("oslist"))
            .is_none_or(|l| l.is_empty() || l.split(',').any(|o| o == cfg.os));
        let gid = match d.node("manifests")?.get(&cfg.branch)? {
            KvValue::Text(t) => t.parse().ok()?,
            KvValue::Node(n) => n.text("gid")?.parse().ok()?,
        };
        os_ok.then_some(gid)
    }

    // What: own depots (id, gid), borrowed (app, id).
    // Why: clippy type_complexity; one name for both.
    // From: Issue #871 | PR #1985
    type Depots = (Vec<(u32, u64)>, Vec<(u32, u32)>);

    // What: the depot nodes of an app with their ids.
    // Why: keys like "branches" in "depots" are no depot.
    // From: Issue #871 | PR #1985
    fn depot_nodes(app: &Kv) -> Vec<(u32, &Kv)> {
        let Some(depots) = app.node("appinfo").unwrap_or(app).node("depots") else {
            return Vec::new();
        };
        depots
            .0
            .iter()
            .filter_map(|(id, v)| match (v, id.parse::<u32>()) {
                (KvValue::Node(d), Ok(id)) => Some((id, d)),
                _ => None,
            })
            .collect()
    }

    // What: split the depots of one app.
    // Why: shared depots of a base app must not be skipped.
    // From: Issue #871 | PR #1985
    fn depots_of(app: &Kv, cfg: &SteamCfg) -> Depots {
        let (mut own, mut borrowed) = (Vec::new(), Vec::new());
        for (id, d) in depot_nodes(app) {
            if let Some(gid) = depot_gid(d, cfg) {
                own.push((id, gid));
            } else if let Some(from) = d.text("depotfromapp").and_then(|t| t.parse().ok()) {
                borrowed.push((from, id));
            }
        }
        (own, borrowed)
    }

    // What: a decoded protobuf field value.
    // Why: few Steam messages; coded by hand, no generator.
    // From: Issue #871 | PR #1980
    #[derive(Clone, Debug)]
    enum Pb {
        Int(u64),
        Bytes(Vec<u8>),
    }

    // What: protobuf writer for the fields Steam needs.
    // Why: varint, fixed32, fixed64 and length-delimited.
    // From: Issue #871 | PR #1980
    #[derive(Default)]
    struct PbOut(Vec<u8>);

    // What: methods of the protobuf writer PbOut.
    // Why: each field type has its own encoder.
    // From: Issue #1683 | PR #2020
    impl PbOut {
        // What: appends a base-128 varint.
        // Why: tags and integers use this encoding.
        // From: Issue #871 | PR #1980
        fn varint(&mut self, mut v: u64) {
            while v >= 0x80 {
                self.0.push((v as u8) | 0x80);
                v >>= 7;
            }
            self.0.push(v as u8);
        }
        // What: appends a varint field (wire type 0).
        // Why: the tag carries field number and type.
        // From: Issue #871 | PR #1980
        fn int(mut self, field: u32, v: u64) -> Self {
            self.varint(u64::from(field) << 3);
            self.varint(v);
            self
        }
        // What: appends an 8-byte field (wire type 1).
        // Why: the tag carries field number and type.
        // From: Issue #871 | PR #1980
        fn fixed64(mut self, field: u32, v: u64) -> Self {
            self.varint((u64::from(field) << 3) | 1);
            self.0.extend_from_slice(&v.to_le_bytes());
            self
        }
        // What: appends a 4-byte field (wire type 5).
        // Why: the tag carries field number and type.
        // From: Issue #871 | PR #1980
        fn fixed32(mut self, field: u32, v: u32) -> Self {
            self.varint((u64::from(field) << 3) | 5);
            self.0.extend_from_slice(&v.to_le_bytes());
            self
        }
        // What: appends a field with length (wire type 2).
        // Why: texts and nested messages use it.
        // From: Issue #871 | PR #1980
        fn bytes(mut self, field: u32, v: &[u8]) -> Self {
            self.varint((u64::from(field) << 3) | 2);
            self.varint(v.len() as u64);
            self.0.extend_from_slice(v);
            self
        }
    }

    // What: decode one protobuf message into field pairs.
    // Why: readers pick fields by number.
    // From: Issue #871 | PR #1980
    fn pb_read(mut b: &[u8]) -> Result<Vec<(u32, Pb)>, String> {
        // What: reads one varint and moves the slice on.
        // Why: more than ten bytes is a broken message.
        // From: Issue #871 | PR #1980
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
    // From: Issue #871 | PR #1980
    fn pb_int(f: &[(u32, Pb)], n: u32) -> Option<u64> {
        f.iter().rev().find_map(|(k, v)| match v {
            Pb::Int(i) if *k == n => Some(*i),
            _ => None,
        })
    }

    // What: all byte values of a protobuf field.
    // Why: repeated fields appear more than once.
    // From: Issue #871 | PR #1980
    fn pb_all(f: &[(u32, Pb)], n: u32) -> impl Iterator<Item = &[u8]> {
        f.iter().filter_map(move |(k, v)| match v {
            Pb::Bytes(b) if *k == n => Some(b.as_slice()),
            _ => None,
        })
    }

    // What: Steam message numbers (EMsg) used here.
    // Why: values from Steam's enums_clientserver.proto.
    // From: Issue #871 | PR #1980
    const EMSG_MULTI: u32 = 1;
    // What: EMsg of a service method answer.
    // Why: the CM sends it for a job reply.
    // From: Issue #1683 | PR #2020
    const EMSG_SERVICE_RESPONSE: u32 = 147;
    // What: EMsg of a service method call.
    // Why: the CM runs it for a named job.
    // From: Issue #1683 | PR #2020
    const EMSG_SERVICE_CALL: u32 = 151;
    // What: EMsg of the heartbeat.
    // Why: the CM drops a silent session.
    // From: Issue #1683 | PR #2020
    const EMSG_HEARTBEAT: u32 = 703;
    // What: EMsg of the logon answer.
    // Why: its eresult says if the login holds.
    // From: Issue #1683 | PR #2020
    const EMSG_LOGON_RESPONSE: u32 = 751;
    // What: EMsg of a logoff notice.
    // Why: it names why Steam ended the session.
    // From: Issue #1683 | PR #2020
    const EMSG_LOGGED_OFF: u32 = 757;
    // What: EMsg of the logon request.
    // Why: it opens the session with the token.
    // From: Issue #1683 | PR #2020
    const EMSG_LOGON: u32 = 5514;
    // What: EMsg of the PICS info request.
    // Why: it asks for the app KeyValues.
    // From: Issue #1683 | PR #2020
    const EMSG_PICS_INFO_REQUEST: u32 = 8903;
    // What: EMsg of the PICS info answer.
    // Why: it carries the app KeyValues.
    // From: Issue #1683 | PR #2020
    const EMSG_PICS_INFO_RESPONSE: u32 = 8904;
    // What: EMsg of the PICS token request.
    // Why: owned apps need an access token.
    // From: Issue #1683 | PR #2020
    const EMSG_PICS_TOKEN_REQUEST: u32 = 8905;
    // What: EMsg of the PICS token answer.
    // Why: it carries the token of an app.
    // From: Issue #1683 | PR #2020
    const EMSG_PICS_TOKEN_RESPONSE: u32 = 8906;
    // What: protobuf flag of the message number.
    // Why: every CM message sent here is protobuf.
    // From: Issue #871 | PR #1980
    const PROTO_MASK: u32 = 0x8000_0000;
    // What: Steam result code OK (EResult 1).
    // Why: fixed by the protocol, like an RFC constant.
    // From: Issue #871 | PR #1980
    const ERESULT_OK: u64 = 1;

    // What: the websocket stream of one CM session.
    // Why: one name for the long tokio-tungstenite type.
    // From: Issue #871 | PR #1980
    type Ws = tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >;

    // What: one CM frame: message number, header, body.
    // Why: header fields route job answers.
    // From: Issue #871 | PR #1980
    struct Frame {
        emsg: u32,
        header: Vec<(u32, Pb)>,
        body: Vec<u8>,
    }

    // What: websocket CM servers of our Steam cell.
    // Why: login and steam-check ask Steam one way.
    // From: Issue #871 | PR #2020
    async fn cm_list(cfg: &SteamCfg, client: &reqwest::Client) -> Result<Vec<String>, String> {
        let list = steam_api(
            client,
            cfg.max_body,
            &cfg.api,
            "ISteamDirectory/GetCMList",
            Req::Get(&[("cellid", cfg.cell.as_str())]),
        )
        .await?;
        Ok(list["serverlist_websockets"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default())
    }

    // What: our own CM session over a websocket.
    // Why: no third-party Steam library is used.
    // From: Issue #871 | PR #1980
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

    // What: methods of the CM session Cm.
    // Why: login, send and wait share one socket.
    // From: Issue #1683 | PR #2020
    impl Cm {
        // What: log in with the sealed QR session token.
        // Why: Steam takes refresh token as access_token.
        // From: Issue #871 | PR #1980
        async fn login(cfg: &SteamCfg, client: &reqwest::Client) -> Result<Self, String> {
            let s = load_session(&cfg.dir, &cfg.bind)?.ok_or("Steam login missing")?;
            let steam_id: u64 = steam_id_of(&s.refresh_token)?
                .parse()
                .map_err(|e| format!("steam id: {e}"))?;
            let host = cm_list(cfg, client)
                .await?
                .into_iter()
                .next()
                .ok_or("CM list: no websocket server")?;
            // What: connect within the SOT request limit.
            // Why: a silent CM must not hang a lookup.
            // From: Issue #871 | PR #2020
            let url = format!("wss://{host}/cmsocket/");
            let (ws, _) = tokio::time::timeout(cfg.limit, tokio_tungstenite::connect_async(url))
                .await
                .map_err(|_| format!("CM {host}: connect timed out"))?
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
            // What: own login id per CM connection.
            // Why: jobs logged each other off (eresult 34)
            // From: Issue #871 | PR #1985
            let nanos = u32::try_from(clock::unix_nanos() % 1_000_000_000).unwrap_or(0);
            let ip = PbOut::default().fixed32(1, nanos | 1);
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
        // Why: frame = emsg|flag, header len, header, body.
        // From: Issue #871 | PR #1980
        async fn send(&mut self, emsg: u32, header: PbOut, body: &[u8]) -> Result<(), String> {
            use futures_util::SinkExt as _;
            let header = header.fixed64(1, self.steam_id).int(2, self.session);
            let mut frame = Vec::with_capacity(8 + header.0.len() + body.len());
            frame.extend_from_slice(&(emsg | PROTO_MASK).to_le_bytes());
            frame.extend_from_slice(&(header.0.len() as u32).to_le_bytes());
            frame.extend_from_slice(&header.0);
            frame.extend_from_slice(body);
            let msg = tokio_tungstenite::tungstenite::Message::Binary(frame.into());
            // What: send within the SOT request limit.
            // Why: a full socket must not hang the job.
            // From: Issue #871 | PR #2020
            tokio::time::timeout(self.limit, self.ws.send(msg))
                .await
                .map_err(|_| "CM send timed out".to_string())?
                .map_err(|e| format!("CM send: {e}"))
        }

        // What: a heartbeat when the interval has passed.
        // Why: the CM drops a silent session.
        // From: Issue #871 | PR #1980
        async fn beat(&mut self) -> Result<(), String> {
            if self.last_beat.elapsed() >= self.heartbeat {
                self.last_beat = std::time::Instant::now();
                self.send(EMSG_HEARTBEAT, PbOut::default(), &[]).await?;
            }
            Ok(())
        }

        // What: unpack one websocket message into frames.
        // Why: Multi frames bundle many, maybe gzipped.
        // From: Issue #871 | PR #1980
        fn unpack(&mut self, raw: &[u8]) -> Result<(), String> {
            let word = |b: &[u8], at: usize| le32(b, at, "CM frame");
            let raw_emsg = word(raw, 0)?;
            // What: skip frames without the protobuf flag.
            // Why: frame without it is no protobuf message.
            // From: Issue #871 | PR #1985
            if raw_emsg & PROTO_MASK == 0 {
                return Ok(());
            }
            let emsg = raw_emsg & !PROTO_MASK;
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

        // What: the next frame that matches, within limit.
        // Why: other frames (notices) are skipped.
        // From: Issue #871 | PR #1980
        async fn wait(&mut self, want: impl Fn(&Frame) -> bool) -> Result<Frame, String> {
            use futures_util::StreamExt as _;
            let deadline = tokio::time::Instant::now() + self.limit;
            loop {
                if let Some(pos) = self.queue.iter().position(&want) {
                    return self.queue.remove(pos).ok_or_else(|| "CM queue".to_string());
                }
                // What: name why Steam ended the session.
                // Why: "CM closed" alone names no reason.
                // From: Issue #871 | PR #1985
                if let Some(off) = self.queue.iter().find(|f| f.emsg == EMSG_LOGGED_OFF) {
                    let r = pb_read(&off.body).ok().and_then(|b| pb_int(&b, 1));
                    return Err(format!("Steam logged the session off, eresult {r:?}"));
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
        // Why: reply carries our job id as jobid_target.
        // From: Issue #871 | PR #1980
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
    // From: Issue #871 | PR #1980
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
    // From: Issue #871 | PR #1980
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
    // Why: chunk SHA-1 names CDN URL; data stays unread.
    // From: Issue #871 | PR #1858
    fn chunks_of(zipped: &[u8]) -> Result<Vec<(String, u64)>, String> {
        use std::io::Read as _;
        // What: magic number of a manifest payload.
        // Why: a manifest without it is no manifest.
        // From: Issue #1683 | PR #2020
        const PAYLOAD_MAGIC: u32 = 0x71F6_17D0;
        let mut zip = zip::ZipArchive::new(std::io::Cursor::new(zipped))
            .map_err(|e| format!("manifest zip: {e}"))?;
        let mut raw = Vec::new();
        zip.by_index(0)
            .map_err(|e| format!("manifest zip: {e}"))?
            .read_to_end(&mut raw)
            .map_err(|e| format!("manifest zip: {e}"))?;
        let word = |at: usize| le32(&raw, at, "manifest");
        if word(0)? != PAYLOAD_MAGIC {
            return Err("manifest payload magic missing".into());
        }
        let len = usize::try_from(word(4)?).map_err(|e| e.to_string())?;
        let payload = pb_read(raw.get(8..8 + len).ok_or("manifest payload cut short")?)?;
        let mut ids = Vec::new();
        for mapping in pb_all(&payload, 1) {
            for chunk in pb_all(&pb_read(mapping)?, 6) {
                let c = pb_read(chunk)?;
                if let Some(sha) = pb_all(&c, 1).next() {
                    // What: packed size, else plain size.
                    // Why: the CDN sends chunks compressed.
                    // From: Issue #871 | PR #1985
                    let n = pb_int(&c, 5).or_else(|| pb_int(&c, 4)).unwrap_or(0);
                    ids.push((hex::encode(sha), n));
                }
            }
        }
        ids.sort();
        ids.dedup_by(|a, b| a.0 == b.0);
        Ok(ids)
    }

    // What: every chunk URL of an app's depots.
    // Why: the URL job warms them through the proxy.
    // From: Issue #871 | PR #1858
    async fn app_urls(
        cfg: &SteamCfg,
        dl: &Dl,
        app: u32,
    ) -> Result<(Vec<String>, u64, Vec<String>), String> {
        let mut cm = Cm::login(cfg, &cfg.web).await?;
        let info = app_info(&mut cm, app).await?;
        // What: keep the depots for the library cache view.
        // Why: a preloaded game shows its size at once.
        // From: Issue #871 | PR #1991
        if let Err(e) = save_depots(&cfg.dir, app, &depot_ids(&info)) {
            eprintln!("cachehamster: app {app}: {e}");
        }
        let (own, borrowed) = depots_of(&info, cfg);
        let mut list: Vec<(u32, u32, u64)> = own.into_iter().map(|(d, g)| (app, d, g)).collect();
        // What: a borrowed depot takes its owner app gid.
        // Why: GoldSrc mods share Half-Life base depots.
        // From: Issue #871 | PR #1985
        for (from, depot) in borrowed {
            let owner = match app_info(&mut cm, from).await {
                Ok(i) => i,
                Err(e) => {
                    eprintln!("cachehamster: app {app}: depot {depot} via app {from}: {e}");
                    continue;
                }
            };
            if let Some(gid) = depots_of(&owner, cfg)
                .0
                .into_iter()
                .find(|(d, _)| *d == depot)
                .map(|(_, g)| g)
            {
                list.push((from, depot, gid));
            }
        }
        let (mut urls, mut size, mut skipped) = (Vec::new(), 0, Vec::new());
        for (owner, depot, gid) in list {
            let code = match request_code(&mut cm, owner, depot, gid, &cfg.branch).await {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("cachehamster: app {app}: {e}");
                    skipped.push(e);
                    continue;
                }
            };
            let url = format!(
                "http://{}{DEPOT_PATH}{depot}/manifest/{gid}/{}/{code}",
                cfg.cdn_host, cfg.manifest_api
            );
            let resp = dl
                .client
                .get(dl.url(&url)?)
                .send()
                .await
                .map_err(|e| format!("{url}: {}", http::error_chain(&e)))?;
            if !resp.status().is_success() {
                eprintln!("cachehamster: {url}: HTTP {}", resp.status());
                skipped.push(format!("depot {depot}: HTTP {}", resp.status()));
                continue;
            }
            let body = http::read_body(resp, cfg.max_body, &url).await?;
            for (sha, n) in chunks_of(&body)? {
                urls.push(format!(
                    "http://{}{DEPOT_PATH}{depot}/chunk/{sha}",
                    cfg.cdn_host
                ));
                size += n;
            }
        }
        if urls.is_empty() {
            return Err(format!("app {app}: no depot of this account and OS"));
        }
        Ok((urls, size, skipped))
    }

    // What: depot ids an app owns, any OS, no borrowed.
    // Why: evict must not drop the shared base of mods.
    // From: Issue #871 | PR #1991
    fn depot_ids(app: &Kv) -> Vec<u32> {
        depot_nodes(app)
            .into_iter()
            .filter(|(_, d)| d.text("depotfromapp").is_none())
            .map(|(id, _)| id)
            .collect()
    }

    // What: remember the depots of an app.
    // Why: the library shows cache use without a login.
    // From: Issue #871 | PR #1991
    fn save_depots(dir: &Path, app: u32, ids: &[u32]) -> Result<(), String> {
        let body = json_bytes(ids)?;
        let path = dir.join(DEPOTS_DIR).join(format!("{app}.json"));
        replace_private(&path, &body).map_err(|e| format!("{}: {e}", path.display()))
    }

    // What: every saved app and its depots.
    // Why: one map for the whole library list.
    // From: Issue #871 | PR #1991
    fn known_depots(dir: &Path) -> Result<BTreeMap<u32, Vec<u32>>, String> {
        let dir = dir.join(DEPOTS_DIR);
        let paths = crate::shared::fs::entries_if_present(&dir)
            .map_err(|e| format!("{}: {e}", dir.display()))?;
        let mut out = BTreeMap::new();
        for path in paths {
            let Some(app) = path
                .file_stem()
                .and_then(|s| s.to_str())
                .and_then(|s| s.parse().ok())
            else {
                continue;
            };
            if let Some(ids) = read_json::<Vec<u32>>(&path)? {
                out.insert(app, ids);
            }
        }
        Ok(out)
    }

    // What: the Steam depot named in a cache file KEY.
    // Why: nginx writes the cache key into each file head.
    // From: Issue #871 | PR #1991
    fn key_depot(path: &Path) -> Option<u32> {
        use std::io::Read as _;
        let mut head = vec![0; CACHE_HEAD_BYTES];
        let n = std::fs::File::open(path).ok()?.read(&mut head).ok()?;
        let head = &head[..n];
        let at = head
            .windows(CACHE_KEY_MARKER.len())
            .position(|w| w == CACHE_KEY_MARKER)?
            + CACHE_KEY_MARKER.len();
        let end = head[at..].iter().position(|b| *b == b'\n')? + at;
        let key = std::str::from_utf8(&head[at..end]).ok()?;
        let rest = key.split_once(DEPOT_PATH)?.1;
        let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
        digits.parse().ok()
    }

    // What: walk the cache; sum or delete per depot.
    // Why: free one game without a full wipe.
    // From: Issue #871 | PR #1991
    fn walk_cache(
        dir: &Path,
        drop: &dyn Fn(u32) -> bool,
        sizes: &mut BTreeMap<u32, u64>,
        freed: &mut (u64, u64),
    ) -> Vec<String> {
        let (found, mut errs) = crate::shared::fs::files_under(dir);
        let mut gone = Vec::new();
        for (path, meta) in found {
            let Some(depot) = key_depot(&path) else {
                continue;
            };
            if drop(depot) {
                gone.push(crate::shared::tidy::Item {
                    path,
                    size: meta.len(),
                    mtime: 0,
                });
            } else {
                *sizes.entry(depot).or_default() += meta.len();
            }
        }
        let (bytes, failed) = crate::shared::tidy::delete(&gone);
        freed.0 += bytes;
        freed.1 += (gone.len() - failed.len()) as u64;
        errs.extend(failed);
        errs
    }

    // What: cache bytes of every known app.
    // Why: the library shows "in cache: x GiB" per game.
    // From: Issue #871 | PR #1991
    fn cached(c: &Ctx) -> Result<Value, String> {
        let mut sizes = BTreeMap::new();
        let dir = crate::shared::tidy::cache_root(&c.s)?;
        let errors = walk_cache(&dir, &|_| false, &mut sizes, &mut (0, 0));
        let apps: BTreeMap<String, u64> = known_depots(&c.dir)?
            .into_iter()
            .map(|(app, ids)| {
                let n = ids.iter().filter_map(|d| sizes.get(d)).sum();
                (app.to_string(), n)
            })
            .collect();
        let human: BTreeMap<&String, String> =
            apps.iter().map(|(a, n)| (a, human::bytes(*n))).collect();
        Ok(json!({"apps": apps, "apps_human": human, "ok": errors.is_empty(), "errors": errors}))
    }

    // What: empty the whole cache of every service.
    // Why: a full wipe stands next to the per-game evict.
    // From: Issue #871 | PR #1991
    fn wipe(c: &Ctx) -> Result<Value, String> {
        use crate::shared::tidy;
        let (all, mut errors) = tidy::files(&tidy::cache_root(&c.s)?);
        let (freed, failed) = tidy::delete(&all);
        let files = all.len() - failed.len();
        errors.extend(failed);
        Ok(json!({
            "freed": freed,
            "freed_human": human::bytes(freed),
            "files": files,
            "ok": errors.is_empty(),
            "errors": errors,
        }))
    }

    // What: depots of one app from PICS, then saved.
    // Why: games never preloaded have no saved depots.
    // From: Issue #871 | PR #1991
    async fn lookup(c: &Ctx, app: u32) -> Result<Vec<u32>, String> {
        let cfg = SteamCfg::load(c)?;
        let mut cm = Cm::login(&cfg, &cfg.web).await?;
        let ids = depot_ids(&app_info(&mut cm, app).await?);
        save_depots(&c.dir, app, &ids)?;
        Ok(ids)
    }

    // What: check or evict one app in the cache.
    // Why: one game can be emptied without the rest.
    // From: Issue #871 | PR #1991
    async fn app_cache(c: &Ctx, args: &[String], evict: bool) -> Result<Value, String> {
        let app: u32 = args
            .first()
            .and_then(|a| a.parse().ok())
            .ok_or("app id must be a number")?;
        let ids = lookup(c, app).await?;
        let (mut sizes, mut freed) = (BTreeMap::new(), (0, 0));
        let dir = crate::shared::tidy::cache_root(&c.s)?;
        let hit = |d: u32| evict && ids.contains(&d);
        let errors = walk_cache(&dir, &hit, &mut sizes, &mut freed);
        let bytes: u64 = ids.iter().filter_map(|d| sizes.get(d)).sum();
        Ok(json!({
            "app": app,
            "bytes": bytes,
            "bytes_human": human::bytes(bytes),
            "freed": freed.0,
            "freed_human": human::bytes(freed.0),
            "files": freed.1,
            "ok": errors.is_empty(),
            "errors": errors,
        }))
    }

    // What: run a Steam app job: resolve, then warm.
    // Why: same queue, connections and RAM sink as URLs.
    // From: Issue #871 | PR #1980
    async fn run_app(
        cfg: SteamCfg,
        dl: Dl,
        app: u32,
        connections: usize,
        jobs: Arc<Mutex<Vec<Job>>>,
        id: String,
        rate: Arc<AtomicU64>,
    ) -> State {
        let (urls, size, skipped) = match app_urls(&cfg, &dl, app).await {
            Ok(u) => u,
            Err(e) => return State::Failed(e),
        };
        if let Some(j) = jobs.lock().await.iter_mut().find(|j| j.id == id) {
            j.total = urls.len() as u64;
            j.size = size;
            j.skipped = skipped;
        }
        run_urls(dl, urls, connections, jobs, id, rate).await
    }

    // What: one daemon round: orders in, due jobs out.
    // Why: up to CACHEHAMSTER_QUEUES jobs run at once.
    // From: Issue #871 | PR #1980
    struct Runner {
        dl: Dl,
        steam: SteamCfg,
        queues: usize,
        connections: usize,
        jobs: Arc<Mutex<Vec<Job>>>,
        rate: Arc<AtomicU64>,
        running: BTreeMap<String, tokio::task::JoinHandle<State>>,
        window: (u32, u32),
        zone: PathBuf,
    }

    // What: methods of the daemon round Runner.
    // Why: one pass moves the job list on.
    // From: Issue #1683 | PR #2020
    impl Runner {
        // What: one pass: inbox, finished, window, due jobs
        // Why: the job file is saved after every pass.
        // From: Issue #871 | PR #1980
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
            // What: a clock error keeps the window shut.
            // Why: never download outside the set hours.
            // From: Issue #871 | PR #2020
            let open = in_window(self.window, &self.zone).unwrap_or_else(|e| {
                eprintln!("cachehamster: clock: {e}; window stays shut");
                false
            });
            // What: outside window jobs pause as waiting.
            // Why: they start again when the window opens.
            // From: Issue #871 | PR #1980
            if !open {
                for (id, h) in std::mem::take(&mut self.running) {
                    h.abort();
                    if let Some(j) = list.iter_mut().find(|j| j.id == id) {
                        j.set(State::Waiting);
                    }
                }
                return save_jobs(c, &list);
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
                let (jobs, id, rate) =
                    (Arc::clone(&self.jobs), j.id.clone(), Arc::clone(&self.rate));
                let task = match &j.target {
                    Target::Urls(urls) => tokio::spawn(run_urls(
                        self.dl.clone(),
                        urls.clone(),
                        self.connections,
                        jobs,
                        id,
                        rate,
                    )),
                    Target::SteamApp(app) => tokio::spawn(run_app(
                        self.steam.clone(),
                        self.dl.clone(),
                        *app,
                        self.connections,
                        jobs,
                        id,
                        rate,
                    )),
                };
                self.running.insert(j.id.clone(), task);
            }
            save_jobs(c, &list)
        }
    }

    // What: write the job list to jobs.json.
    // Why: the daemon is the one writer; one format.
    // From: Issue #871 | PR #1980
    fn save_jobs(c: &Ctx, list: &[Job]) -> Result<(), String> {
        c.save(JOBS_FILE, &json_bytes(list)?)
    }

    // What: u32, little endian, at a byte offset.
    // Why: CM frames and manifests both carry such words.
    // From: Issue #871 | PR #1980
    fn le32(b: &[u8], at: usize, what: &str) -> Result<u32, String> {
        b.get(at..at + 4)
            .and_then(|w| w.try_into().ok())
            .map(u32::from_le_bytes)
            .ok_or_else(|| format!("{what} too short"))
    }

    // What: the daemon loop.
    // Why: a broken round logs and retries, never exits.
    // From: Issue #871 | PR #1980
    async fn daemon(c: Ctx) -> Result<(), String> {
        let queues = c.s.num::<usize>("CACHEHAMSTER_QUEUES")?;
        let connections = c.s.num::<usize>("CACHEHAMSTER_CONCURRENCY")?;
        let tick = Duration::from_secs(c.s.uint("CACHEHAMSTER_POLL_INTERVAL")?);
        let report = c.s.uint("CACHEHAMSTER_THROUGHPUT_INTERVAL")?;
        let dl = Dl::load(&c.s, connections)?;
        let mbit = c.s.uint("CACHEHAMSTER_MAX_MBIT")?;
        if mbit > 0 {
            let _ = PACE.set(Pace {
                next: std::sync::Mutex::new(tokio::time::Instant::now()),
                bytes_per_sec: mbit * 1_000_000 / 8,
            });
        }
        let window = window(&c.s.text("CACHEHAMSTER_WINDOW")?)?;
        // What: the values this start runs with.
        // Why: the values in use must be visible in log.
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
        // From: Issue #871 | PR #1980
        for j in list.iter_mut().filter(|j| j.state == State::Running) {
            j.set(State::Waiting);
        }
        let mut runner = Runner {
            dl,
            steam: SteamCfg::load(&c)?,
            queues,
            connections,
            jobs: Arc::new(Mutex::new(list)),
            rate: Arc::new(AtomicU64::new(0)),
            running: BTreeMap::new(),
            window,
            zone: PathBuf::from(c.s.text("LOCALTIME_FILE")?),
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
                // What: log while jobs run or state changed
                // Why: an idle line per round floods log.
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

    // What: what one cachehamster command does.
    // Why: command() matches these, the table names them.
    // From: Issue #871 | PR #2020
    #[derive(Clone, Copy, PartialEq)]
    enum Op {
        Daemon,
        Status,
        Healthcheck,
        LoginBegin,
        LoginPoll,
        LoginCancel,
        Logout,
        Library,
        Cached,
        Wipe,
        FetchCheck,
        SteamCheck,
        Lookup,
        Evict,
        Add,
        Start,
        Cancel,
        Remove,
    }

    // What: how REST may call a command.
    // Why: the ui reads it here, not from a second list.
    // From: Issue #871 | PR #2020
    #[derive(Clone, Copy, PartialEq)]
    pub(crate) enum Rest {
        No,
        Plain,
        AppId,
        Url,
    }

    // What: a command row: the action and its REST use.
    // Why: one place says what a word does and allows.
    // From: Issue #871 | PR #2020
    #[derive(Clone, Copy)]
    struct Cmd {
        op: Op,
        rest: Rest,
    }

    // What: every command cachehamster takes.
    // Why: help, errors, choice and REST read this table.
    // From: Issue #871 | PR #2020
    const COMMANDS: [(&str, crate::shared::cli::Entry<Cmd>); 18] = [
        (
            "daemon",
            crate::shared::cli::row(
                Cmd {
                    op: Op::Daemon,
                    rest: Rest::No,
                },
                "daemon",
            ),
        ),
        (
            "status",
            crate::shared::cli::row(
                Cmd {
                    op: Op::Status,
                    rest: Rest::Plain,
                },
                "status",
            ),
        ),
        (
            "healthcheck",
            crate::shared::cli::row(
                Cmd {
                    op: Op::Healthcheck,
                    rest: Rest::No,
                },
                "healthcheck",
            ),
        ),
        (
            "login-begin",
            crate::shared::cli::row(
                Cmd {
                    op: Op::LoginBegin,
                    rest: Rest::Plain,
                },
                "login-begin",
            ),
        ),
        (
            "login-poll",
            crate::shared::cli::row(
                Cmd {
                    op: Op::LoginPoll,
                    rest: Rest::Plain,
                },
                "login-poll",
            ),
        ),
        (
            "login-cancel",
            crate::shared::cli::row(
                Cmd {
                    op: Op::LoginCancel,
                    rest: Rest::Plain,
                },
                "login-cancel",
            ),
        ),
        (
            "logout",
            crate::shared::cli::row(
                Cmd {
                    op: Op::Logout,
                    rest: Rest::No,
                },
                "logout",
            ),
        ),
        (
            "library",
            crate::shared::cli::row(
                Cmd {
                    op: Op::Library,
                    rest: Rest::Plain,
                },
                "library",
            ),
        ),
        (
            "cached",
            crate::shared::cli::row(
                Cmd {
                    op: Op::Cached,
                    rest: Rest::Plain,
                },
                "cached",
            ),
        ),
        (
            "wipe",
            crate::shared::cli::row(
                Cmd {
                    op: Op::Wipe,
                    rest: Rest::Plain,
                },
                "wipe",
            ),
        ),
        (
            "fetch-check",
            crate::shared::cli::row(
                Cmd {
                    op: Op::FetchCheck,
                    rest: Rest::Url,
                },
                "fetch-check <url>",
            ),
        ),
        (
            "steam-check",
            crate::shared::cli::row(
                Cmd {
                    op: Op::SteamCheck,
                    rest: Rest::Plain,
                },
                "steam-check",
            ),
        ),
        (
            "lookup",
            crate::shared::cli::row(
                Cmd {
                    op: Op::Lookup,
                    rest: Rest::AppId,
                },
                "lookup <app-id>",
            ),
        ),
        (
            "evict",
            crate::shared::cli::row(
                Cmd {
                    op: Op::Evict,
                    rest: Rest::AppId,
                },
                "evict <app-id>",
            ),
        ),
        (
            "add",
            crate::shared::cli::row(
                Cmd {
                    op: Op::Add,
                    rest: Rest::No,
                },
                "add <name> <now|later|at:UNIX> <app:ID|URL,URL>",
            ),
        ),
        (
            "start",
            crate::shared::cli::row(
                Cmd {
                    op: Op::Start,
                    rest: Rest::No,
                },
                "start <id>",
            ),
        ),
        (
            "cancel",
            crate::shared::cli::row(
                Cmd {
                    op: Op::Cancel,
                    rest: Rest::No,
                },
                "cancel <id>",
            ),
        ),
        (
            "remove",
            crate::shared::cli::row(
                Cmd {
                    op: Op::Remove,
                    rest: Rest::No,
                },
                "remove <id>",
            ),
        ),
    ];

    // What: how REST may call a command word.
    // Why: the ui builds the arguments from the kind.
    // From: Issue #871 | PR #2020
    pub(crate) fn rest_of(word: &str) -> Rest {
        crate::shared::cli::pick(&COMMANDS, word).map_or(Rest::No, |c| c.op.rest)
    }

    // What: run one command and answer as JSON.
    // Why: the UI calls these through docker exec.
    // From: Issue #871 | PR #1980
    async fn command(c: Ctx, args: &[String]) -> Result<Value, String> {
        use crate::shared::cli;
        let op = match args.first().map(String::as_str) {
            None => Op::Daemon,
            Some(word) => cli::pick(&COMMANDS, word)
                .map(|row| row.op.op)
                .ok_or_else(|| cli::help(&COMMANDS))?,
        };
        // What: the HTTP client, built when one is needed.
        // Why: the daemon and local commands need none.
        // From: Issue #871 | PR #2020
        let client = || http::client(&c.s);
        match op {
            Op::Daemon => daemon(c).await.map(|()| Value::Null),
            Op::Status => status(&c),
            // What: probe: the daemon wrote jobs lately.
            // Why: the same rule as daemon_running.
            // From: Issue #871 | PR #2020
            Op::Healthcheck => match daemon_alive(&c)? {
                true => Ok(json!({"daemon_running": true})),
                false => Err("cachehamster daemon is not running".into()),
            },
            Op::LoginBegin => login_begin(&c, &client()?).await,
            Op::LoginPoll => login_poll(&c, &client()?).await,
            Op::LoginCancel => {
                delete_file(&c.path(PENDING_FILE)).map(|()| json!({"state": "idle"}))
            }
            Op::Logout => delete_file(&c.path(TOKEN_FILE)).map(|()| json!({"logged_in": false})),
            Op::Library => library(&c, &client()?).await,
            Op::Cached => cached(&c),
            Op::FetchCheck => fetch_check(&c, &args[1..]).await,
            Op::SteamCheck => steam_check(&c).await,
            Op::Wipe => wipe(&c),
            Op::Lookup => app_cache(&c, &args[1..], false).await,
            Op::Evict => app_cache(&c, &args[1..], true).await,
            Op::Add => submit(&c, &parse_add(&args[1..])?),
            Op::Start | Op::Cancel | Op::Remove => {
                let id = args.get(1).ok_or("job id missing")?.clone();
                let order = match op {
                    Op::Start => Order::Start { id },
                    Op::Cancel => Order::Cancel { id },
                    _ => Order::Remove { id },
                };
                submit(&c, &order)
            }
        }
    }

    // What: entry point; no argument runs the daemon.
    // Why: one binary for the daemon and UI commands.
    // From: Issue #871 | PR #1980
    pub async fn run(args: &[String]) -> std::process::ExitCode {
        let args: Vec<String> = args.to_vec();
        // What: help lists the commands, as the others.
        // Why: no settings are needed to name them.
        // From: Issue #1683 | PR #2020
        if args.first().is_some_and(|a| a == "help") {
            println!("{}", crate::shared::cli::help(&COMMANDS));
            return std::process::ExitCode::SUCCESS;
        }
        let result = match Ctx::load() {
            Err(e) => Err(e),
            Ok(c) => command(c, &args).await,
        };
        match result {
            // What: a check with "ok": false exits 1.
            // Why: the answer keeps its parts as JSON.
            // From: Issue #871 | PR #2020
            Ok(v) if v.get("ok") == Some(&Value::Bool(false)) => {
                println!("{v}");
                std::process::ExitCode::FAILURE
            }
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
}

// What: settings from SOT schema, defaults, file, env.
// Why: every role reads values through one checked set.
// From: Issue #1683 | PR #2020
mod config {
    use std::collections::{BTreeMap, BTreeSet};
    use std::fmt;
    use std::path::{Path, PathBuf};

    // What: env key of the baked default rows.
    // Why: the SOT bakes defaults into each image.
    // From: Issue #1683 | PR #1980
    const DEFAULTS_KEY: &str = "LANCACHE_RUNTIME_DEFAULTS";

    // What: env key of the baked schema rows.
    // Why: kind, range, effect and owner per key.
    // From: Issue #1683 | PR #1980
    const SCHEMA_KEY: &str = "LANCACHE_RUNTIME_SCHEMA";

    // What: env name of the saved settings file.
    // Why: needed before any setting can be read.
    // From: Issue #1683 | PR #2019
    pub const SETTINGS_FILE_ENV: &str = "LANCACHE_SETTINGS_FILE";

    // What: separator of baked rows.
    // Why: the SOT joins rows with a pipe.
    // From: Issue #1683 | PR #1980
    const ROW_SEP: char = '|';

    // What: type of a value.
    // Why: the schema kind decides parsing and ui field.
    // From: Issue #1683 | PR #1980
    #[derive(Clone, Debug, Eq, PartialEq)]
    pub enum Kind {
        Text,
        Bool,
        Uint { min: u64, max: u64, clamp: bool },
        List,
        Path,
        Secret,
        Choice(Vec<String>),
        Ip,
        Net,
        Nets,
        Hosts,
        Addrs,
    }

    // What: methods of the setting kind Kind.
    // Why: the schema word and the kind agree.
    // From: Issue #1683 | PR #2020
    impl Kind {
        // What: schema word of kind text.
        // Why: the schema row and the schema output agree.
        // From: Issue #1683 | PR #2020
        const TEXT: &str = "text";

        // What: schema word of kind bool.
        // Why: the schema row and the schema output agree.
        // From: Issue #1683 | PR #2020
        const BOOL: &str = "bool";

        // What: schema word of kind uint.
        // Why: the schema row and the schema output agree.
        // From: Issue #1683 | PR #2020
        const UINT: &str = "uint";

        // What: schema word of kind uint~.
        // Why: the schema row and the schema output agree.
        // From: Issue #1683 | PR #2020
        const UINT_CLAMP: &str = "uint~";

        // What: schema word of kind list.
        // Why: the schema row and the schema output agree.
        // From: Issue #1683 | PR #2020
        const LIST: &str = "list";

        // What: schema word of kind path.
        // Why: the schema row and the schema output agree.
        // From: Issue #1683 | PR #2020
        const PATH: &str = "path";

        // What: schema word of kind secret.
        // Why: the schema row and the schema output agree.
        // From: Issue #1683 | PR #2020
        const SECRET: &str = "secret";

        // What: schema word of kind choice.
        // Why: the schema row and the schema output agree.
        // From: Issue #1683 | PR #2020
        const CHOICE: &str = "choice";

        // What: schema word of kind ip: one IP address.
        // Why: the schema row and the schema output agree.
        // From: Issue #1683 | PR #2020
        const IP: &str = "ip";

        // What: schema word of kind net: one addr/len.
        // Why: the schema row and the schema output agree.
        // From: Issue #1683 | PR #2020
        const NET: &str = "net";

        // What: schema word of kind nets: IPs or networks.
        // Why: the schema row and the schema output agree.
        // From: Issue #1683 | PR #2020
        const NETS: &str = "nets";

        // What: schema word of kind hosts: host[:port].
        // Why: the schema row and the schema output agree.
        // From: Issue #1683 | PR #2020
        const HOSTS: &str = "hosts";

        // What: schema word of kind addrs: addr[:port].
        // Why: the schema row and the schema output agree.
        // From: Issue #1683 | PR #2020
        const ADDRS: &str = "addrs";

        // What: the schema word of a kind; uint is one.
        // Why: describe prints the word parse reads.
        // From: Issue #1683 | PR #2020
        pub fn word(&self) -> &'static str {
            match self {
                Kind::Text => Self::TEXT,
                Kind::Bool => Self::BOOL,
                Kind::Uint { .. } => Self::UINT,
                Kind::List => Self::LIST,
                Kind::Path => Self::PATH,
                Kind::Secret => Self::SECRET,
                Kind::Choice(_) => Self::CHOICE,
                Kind::Ip => Self::IP,
                Kind::Net => Self::NET,
                Kind::Nets => Self::NETS,
                Kind::Hosts => Self::HOSTS,
                Kind::Addrs => Self::ADDRS,
            }
        }
    }

    // What: what a change needs before it is live.
    // Why: only affected programs act on a change.
    // From: Issue #1683 | PR #1980
    #[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
    pub enum Effect {
        Live,
        // What: only the SOT sets it; no save changes it.
        // Why: commands, URLs and fences are no input.
        // From: Issue #1683 | PR #2020
        Fixed,
        Reload,
        Restart,
        Container,
        Recreate,
    }

    // What: one schema row.
    // Why: the ui builds fields and runner plans from it.
    // From: Issue #1683 | PR #1980
    #[derive(Clone, Debug, Eq, PartialEq)]
    pub struct Spec {
        pub key: String,
        pub kind: Kind,
        pub required: bool,
        pub effect: Effect,
        pub owner: String,
    }

    // What: a checked value.
    // Why: callers never parse raw text again.
    // From: Issue #1683 | PR #1980
    #[derive(Clone, Debug, Eq, PartialEq)]
    pub enum Value {
        Text(String),
        Bool(bool),
        Uint(u64),
        List(Vec<String>),
    }

    // What: text form of a checked Value.
    // Why: revision and diff compare this text.
    // From: Issue #1683 | PR #2020
    impl fmt::Display for Value {
        // What: canonical text of a value.
        // Why: revision and diff compare this text.
        // From: Issue #1683 | PR #1980
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            match self {
                Self::Text(v) => f.write_str(v),
                Self::Bool(v) => write!(f, "{v}"),
                Self::Uint(v) => write!(f, "{v}"),
                Self::List(v) => f.write_str(&join_items(v)),
            }
        }
    }

    // What: items of a list value.
    // Why: the SOT allows comma and blank as separators.
    // From: Issue #1683 | PR #1980
    pub fn list_items(raw: &str) -> impl Iterator<Item = &str> {
        raw.split(|c: char| c == ',' || c.is_whitespace())
            .filter(|item| !item.is_empty())
    }

    // What: list items as one setting text, blank apart.
    // Why: the writer that matches list_items, the reader.
    // From: Issue #1683 | PR #2020
    pub fn join_items<S: AsRef<str>>(items: &[S]) -> String {
        let parts: Vec<&str> = items.iter().map(AsRef::as_ref).collect();
        parts.join(" ")
    }

    // What: the rows of a text without blanks and # rows.
    // Why: list files hold comments and empty lines.
    // From: Issue #1683 | PR #2017
    pub fn data_rows(text: &str) -> impl Iterator<Item = &str> {
        text.lines()
            .map(str::trim)
            .filter(|row| !row.is_empty() && !row.starts_with('#'))
    }

    // What: order of texts: longer first, then descending.
    // Why: a longer number is newer, longer suffix closer.
    // From: Issue #1683 | PR #2017
    pub fn longest_first(a: &str, b: &str) -> std::cmp::Ordering {
        b.len().cmp(&a.len()).then_with(|| b.cmp(a))
    }

    // What: adds an item unless the list has it.
    // Why: lists keep first-seen order without doubles.
    // From: Issue #1683 | PR #1980
    pub fn add_once(list: &mut Vec<String>, item: &str) {
        if !list.iter().any(|n| n == item) {
            list.push(item.to_string());
        }
    }

    // What: the syntax a setting value is written into.
    // Why: each syntax bars its own characters.
    // From: Issue #1683 | PR #2019
    #[derive(Clone, Copy)]
    pub enum Syntax {
        Line,
        Quoted,
        Template,
        Env,
        Nginx,
        Path,
        Semi,
        Name(&'static str),
    }

    // What: methods of the syntax Syntax.
    // Why: each syntax names what it cannot carry.
    // From: Issue #1683 | PR #2020
    impl Syntax {
        // What: how a check failure names its syntax.
        // Why: the error says what the value cannot carry.
        // From: Issue #1683 | PR #2019
        fn limit(self) -> &'static str {
            match self {
                Self::Line => "a line break",
                Self::Quoted => "a quote, backslash or line break",
                Self::Template => "a quote, line break, $( call or stray backslash",
                Self::Env => "a character of the stack .env syntax",
                Self::Nginx => "a line break, ';', '{' or '}'",
                Self::Path => "a quote, '$' or line break, or is not absolute",
                Self::Semi => "a line break or ';'",
                Self::Name(_) => "a character outside letters, digits and its extras",
            }
        }
    }

    // What: true if a value can go into the syntax as is.
    // Why: one owner of "no second statement".
    // From: Issue #1683 | PR #2019
    pub fn safe(syntax: Syntax, v: &str) -> bool {
        match syntax {
            Syntax::Line => !v.contains(['\n', '\r']),
            Syntax::Quoted => !v.contains(['"', '\\', '\n', '\r']),
            Syntax::Template => template_ok(v),
            Syntax::Env => !v.contains(['\n', '\r', '$', '`', '"', '\'', '\\', '#']),
            Syntax::Nginx => !v.contains(['\n', '\r', ';', '{', '}']),
            Syntax::Path => v.starts_with('/') && !v.contains(['"', '\n', '\r', '$']),
            Syntax::Semi => !v.contains(['\n', '\r', ';']),
            Syntax::Name(extra) => {
                !v.is_empty()
                    && v.chars()
                        .all(|c| c.is_ascii_alphanumeric() || extra.contains(c))
            }
        }
    }

    // What: syslog-ng template: text, macros, \n \t \\.
    // Why: $(env X) reads secrets; a last \ eats the quote.
    // From: Issue #1683 | PR #2020
    fn template_ok(v: &str) -> bool {
        let mut chars = v.chars().peekable();
        while let Some(c) = chars.next() {
            match c {
                '"' | '\n' | '\r' => return false,
                '\\' => match chars.next() {
                    Some('n' | 't' | '\\') => {}
                    _ => return false,
                },
                '$' => match chars.peek() {
                    Some('{') => {
                        chars.next();
                        let ok = |c: char| c.is_ascii_alphanumeric() || c == '_' || c == '.';
                        let mut name = 0;
                        loop {
                            match chars.next() {
                                Some('}') if name > 0 => break,
                                Some(c) if ok(c) => name += 1,
                                _ => return false,
                            }
                        }
                    }
                    Some(c) if c.is_ascii_alphanumeric() || *c == '_' => {}
                    _ => return false,
                },
                _ => {}
            }
        }
        true
    }

    // What: the value, or an error naming its limit.
    // Why: a renderer stops on a value that breaks a file.
    // From: Issue #1683 | PR #2019
    pub fn checked(syntax: Syntax, v: &str) -> Result<&str, String> {
        match safe(syntax, v) {
            true => Ok(v),
            false => Err(format!("value {v:?} holds {}", syntax.limit())),
        }
    }

    // What: a bool from its usual words.
    // Why: env, forms send true/false, 1/0, yes/no, on/off.
    // From: Issue #1683 | PR #1858
    pub fn parse_bool(raw: &str) -> Option<bool> {
        let word = raw.trim().to_ascii_lowercase();
        parse_true_false(&word).or(match word.as_str() {
            "1" | "yes" | "on" => Some(true),
            "0" | "no" | "off" => Some(false),
            _ => None,
        })
    }

    // What: a bool from exactly true or false.
    // Why: one reader of those two words, strict or not.
    // From: Issue #1683 | PR #2020
    pub fn parse_true_false(raw: &str) -> Option<bool> {
        match raw {
            "true" => Some(true),
            "false" => Some(false),
            _ => None,
        }
    }

    // What: a plain decimal number, digits only.
    // Why: "+5" or " 5" in a setting is a typo.
    // From: Issue #1683 | PR #1980
    pub fn parse_uint(raw: &str) -> Option<u64> {
        if raw.is_empty() || !raw.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        raw.parse().ok()
    }

    // What: methods of the effect Effect.
    // Why: the SOT word and the effect agree.
    // From: Issue #1683 | PR #2020
    impl Effect {
        // What: every effect with its SOT word.
        // Why: parse and word read one table.
        // From: Issue #1683 | PR #2020
        const WORDS: [(&'static str, Self); 6] = [
            ("live", Self::Live),
            ("fixed", Self::Fixed),
            ("reload", Self::Reload),
            ("restart", Self::Restart),
            ("container", Self::Container),
            ("recreate", Self::Recreate),
        ];

        // What: effect from its SOT word.
        // Why: an unknown word is an error, never Live.
        // From: Issue #1683 | PR #1980
        fn parse(word: &str) -> Result<Self, String> {
            Self::WORDS
                .iter()
                .find_map(|(w, effect)| (*w == word).then_some(*effect))
                .ok_or_else(|| format!("unknown effect {word:?}"))
        }

        // What: true if the ui may store a value for it.
        // Why: container keys are host paths, fixed SOT.
        // From: Issue #1683 | PR #2020
        pub fn writable(self) -> bool {
            !matches!(self, Self::Container | Self::Fixed)
        }

        // What: the SOT word of an effect.
        // Why: REST and CLI show the word the SOT uses.
        // From: Issue #1683 | PR #2020
        pub fn word(self) -> &'static str {
            Self::WORDS
                .iter()
                .find_map(|(w, effect)| (*effect == self).then_some(*w))
                .unwrap_or_default()
        }
    }

    // What: methods of the schema row Spec.
    // Why: parse and check sit with the row.
    // From: Issue #1683 | PR #2020
    impl Spec {
        // What: true for a row of kind secret.
        // Why: one owner of test; pages hide such values.
        // From: Issue #1683 | PR #2017
        pub fn is_secret(&self) -> bool {
            matches!(self.kind, Kind::Secret)
        }

        // What: parse KEY=kind;min;max;effect;owner.
        // Why: SOT row; a choice keeps its words in min.
        // From: Issue #1683 | PR #1980
        fn parse(row: &str) -> Result<Self, String> {
            let (key, rest) = row
                .split_once('=')
                .ok_or_else(|| format!("schema row {row:?} has no ="))?;
            let fields: Vec<&str> = rest.split(';').collect();
            let [kind, min, max, effect, owner] = fields[..] else {
                return Err(format!("schema row {row:?} needs 5 fields"));
            };
            let (kind, required) = match kind.strip_suffix('?') {
                Some(k) => (k, false),
                None => (kind, true),
            };
            let bound = |word: &str, fallback: u64| -> Result<u64, String> {
                if word.is_empty() {
                    return Ok(fallback);
                }
                parse_uint(word).ok_or_else(|| format!("{key}: bound {word:?} is no number"))
            };
            let kind = match kind {
                Kind::TEXT => Kind::Text,
                Kind::BOOL => Kind::Bool,
                Kind::UINT | Kind::UINT_CLAMP => Kind::Uint {
                    min: bound(min, 0)?,
                    max: bound(max, u64::MAX)?,
                    clamp: kind == Kind::UINT_CLAMP,
                },
                Kind::LIST => Kind::List,
                Kind::PATH => Kind::Path,
                Kind::SECRET => Kind::Secret,
                Kind::CHOICE => Kind::Choice(min.split(',').map(str::to_string).collect()),
                Kind::IP => Kind::Ip,
                Kind::NET => Kind::Net,
                Kind::NETS => Kind::Nets,
                Kind::HOSTS => Kind::Hosts,
                Kind::ADDRS => Kind::Addrs,
                other => return Err(format!("{key}: unknown kind {other:?}")),
            };
            Ok(Self {
                key: key.to_string(),
                kind,
                required,
                effect: Effect::parse(effect).map_err(|e| format!("{key}: {e}"))?,
                owner: owner.to_string(),
            })
        }

        // What: check raw text against this spec.
        // Why: one check for env, file, defaults and forms.
        // From: Issue #1683 | PR #1980
        fn check(&self, raw: &str) -> Result<(Value, Option<String>), String> {
            let key = &self.key;
            match &self.kind {
                Kind::Text | Kind::Secret => Ok((Value::Text(raw.to_string()), None)),
                Kind::Path => checked(Syntax::Path, raw)
                    .map(|v| (Value::Text(v.to_string()), None))
                    .map_err(|e| format!("{key}: {e}")),
                Kind::Bool => parse_bool(raw)
                    .map(|b| (Value::Bool(b), None))
                    .ok_or_else(|| format!("{key}: {raw:?} is no bool")),
                Kind::List => Ok((
                    Value::List(list_items(raw).map(str::to_string).collect()),
                    None,
                )),
                Kind::Choice(words) => {
                    if words.iter().any(|w| w == raw) {
                        Ok((Value::Text(raw.to_string()), None))
                    } else {
                        Err(format!("{key}: {raw:?} is not one of {}", words.join(", ")))
                    }
                }
                // What: IPs and nets are read, not scanned.
                // Why: what is no IP or net never passes.
                // From: Issue #1683 | PR #2020
                Kind::Ip | Kind::Net | Kind::Nets => {
                    use crate::shared::dns::{canonical_ip, canonical_net};
                    let one = |item: &str| match self.kind {
                        Kind::Ip => canonical_ip(item),
                        Kind::Net => canonical_net(item),
                        _ if item.contains('/') => canonical_net(item),
                        _ => canonical_ip(item),
                    };
                    let items: Vec<String> = list_items(raw)
                        .map(|item| one(item).map_err(|e| format!("{key}: {e}")))
                        .collect::<Result<_, _>>()?;
                    let value = match self.kind {
                        Kind::Nets => Value::List(items),
                        _ if items.len() <= 1 => Value::Text(items.concat()),
                        _ => return Err(format!("{key}: {raw:?} must be one value")),
                    };
                    let note = read_note(key, raw, &value.to_string());
                    Ok((value, note))
                }
                // What: hosts, addrs: read, not scanned.
                // Why: a name or address, a port, no more.
                // From: Issue #1683 | PR #2020
                Kind::Hosts | Kind::Addrs => {
                    let names = self.kind == Kind::Hosts;
                    let items: Vec<String> = list_items(raw)
                        .map(|item| {
                            crate::shared::dns::canonical_endpoint(item, names)
                                .map_err(|e| format!("{key}: {e}"))
                        })
                        .collect::<Result<_, _>>()?;
                    let note = read_note(key, raw, &items.join(" "));
                    Ok((Value::List(items), note))
                }
                Kind::Uint { min, max, clamp } => {
                    let n =
                        parse_uint(raw).ok_or_else(|| format!("{key}: {raw:?} is no number"))?;
                    if (*min..=*max).contains(&n) {
                        return Ok((Value::Uint(n), None));
                    }
                    if !clamp {
                        return Err(format!("{key}: {n} is outside {min}..={max}"));
                    }
                    let fixed = n.clamp(*min, *max);
                    Ok((
                        Value::Uint(fixed),
                        Some(format!("{key}: {n} clamped to {fixed}")),
                    ))
                }
            }
        }
    }

    // What: the note when a value is read as another.
    // Why: one text for lists read in canonical form.
    // From: Issue #1683 | PR #2020
    fn read_note(key: &str, raw: &str, shown: &str) -> Option<String> {
        let same = shown == list_items(raw).collect::<Vec<_>>().join(" ");
        (!same).then(|| format!("{key}: {raw:?} read as {shown}"))
    }

    // What: non-empty rows of a baked list.
    // Why: an empty row is no entry.
    // From: Issue #1683 | PR #1980
    fn baked_rows(baked: &str) -> impl Iterator<Item = &str> {
        baked
            .split(ROW_SEP)
            .map(str::trim)
            .filter(|r| !r.is_empty())
    }

    // What: the env value of a key; empty counts as unset.
    // Why: Compose passes KEY= for a key nobody set.
    // From: Issue #1683 | PR #2017
    pub fn env_set(env: &dyn Fn(&str) -> Option<String>, key: &str) -> Option<String> {
        env(key).filter(|v| !v.is_empty())
    }

    // What: where a setting's value came from.
    // Why: CLI and REST show why a value is set.
    // From: Issue #1683 | PR #2020
    #[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize)]
    #[serde(rename_all = "lowercase")]
    pub enum Origin {
        File,
        Env,
        Default,
    }

    // What: file, else env, else default; fills @KEY@.
    // Why: KEY= in file means default; env is a stale copy.
    // From: Issue #1683 | PR #2017
    fn effective(
        key: &str,
        file: &BTreeMap<String, String>,
        env: &dyn Fn(&str) -> Option<String>,
        defaults: &BTreeMap<&str, &str>,
        depth: u8,
    ) -> Result<Option<(String, Origin)>, String> {
        match file.get(key) {
            Some(v) if !v.is_empty() => return Ok(Some((v.clone(), Origin::File))),
            Some(_) => {}
            None => {
                if let Some(v) = env_set(env, key) {
                    return Ok(Some((v, Origin::Env)));
                }
            }
        }
        match defaults.get(key).filter(|v| !v.is_empty()) {
            Some(v) => {
                expand_default(v, file, env, defaults, depth).map(|v| Some((v, Origin::Default)))
            }
            None => Ok(None),
        }
    }

    // What: each @KEY@ of a default replaced by its value.
    // Why: the SOT names other keys; image bakes them raw.
    // From: Issue #1683 | PR #2017
    fn expand_default(
        value: &str,
        file: &BTreeMap<String, String>,
        env: &dyn Fn(&str) -> Option<String>,
        defaults: &BTreeMap<&str, &str>,
        depth: u8,
    ) -> Result<String, String> {
        if depth > 16 {
            return Err(format!("default {value:?}: @KEY@ refers to itself"));
        }
        let mut out = String::new();
        let mut rest = value;
        while let Some((at, name)) = next_at_key(rest) {
            out.push_str(&rest[..at]);
            let (got, _) = effective(name, file, env, defaults, depth + 1)?
                .ok_or_else(|| format!("default {value:?} names @{name}@, which has no value"))?;
            out.push_str(&got);
            rest = &rest[at + name.len() + 2..];
        }
        out.push_str(rest);
        Ok(out)
    }

    // What: first @KEY@ of a text: its offset and KEY.
    // Why: one reader of the @KEY@ form for fill and check.
    // From: Issue #1683 | PR #2020
    fn next_at_key(text: &str) -> Option<(usize, &str)> {
        let key_char = |b: &u8| b.is_ascii_uppercase() || b.is_ascii_digit() || *b == b'_';
        let mut from = 0;
        while let Some(i) = text[from..].find('@') {
            let at = from + i;
            let after = &text[at + 1..];
            let len = after.bytes().take_while(key_char).count();
            if len > 0 && after[len..].starts_with('@') {
                return Some((at, &after[..len]));
            }
            from = at + 1;
        }
        None
    }

    // What: every KEY a text names as @KEY@.
    // Why: a fixed value must not take a stored one.
    // From: Issue #1683 | PR #2020
    fn at_keys(text: &str) -> Vec<&str> {
        let mut out = Vec::new();
        let mut rest = text;
        while let Some((at, name)) = next_at_key(rest) {
            out.push(name);
            rest = &rest[at + name.len() + 2..];
        }
        out
    }

    // What: key and value of a KEY=VALUE line; else None.
    // Why: stack .env holds What/Why/From comment lines.
    // From: Issue #1683 | PR #2017
    fn line_entry(line: &str) -> Option<(&str, &str)> {
        let (key, value) = line.split_once('=')?;
        let key = key.trim();
        (!key.is_empty() && !key.starts_with('#')).then_some((key, value.trim()))
    }

    // What: the raw KEY=VALUE lines of the stack .env.
    // Why: a missing file means no values yet.
    // From: Issue #1683 | PR #2017
    pub fn read_raw(path: &Path) -> Result<BTreeMap<String, String>, String> {
        Ok(crate::shared::fs::read_text_if_present(path)?
            .unwrap_or_default()
            .lines()
            .filter_map(line_entry)
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect())
    }

    // What: the values of stack .env; "$" values left out.
    // Why: setup.sh keeps ${VAR} that only Compose expands.
    // From: Issue #1683 | PR #2017
    fn read_file(path: &Path) -> Result<BTreeMap<String, String>, String> {
        let mut all = read_raw(path)?;
        // What: a key of <file>.local replaces file's one.
        // Why: Compose reads it as the second env file.
        // From: Issue #1683 | PR #2017
        all.extend(read_raw(&override_path(path))?);
        all.retain(|_, v| !v.contains('$'));
        Ok(all)
    }

    // What: override file of the stack .env: <file>.local.
    // Why: it wins for single keys, as fail2ban's .local.
    // From: Issue #1683 | PR #2017
    fn override_path(path: &Path) -> PathBuf {
        crate::shared::fs::with_suffix(path, ".local")
    }

    // What: lock file of the stack .env: <file>.lock.
    // Why: setup.sh flocks the same name before it writes.
    // From: Issue #1683 | PR #2017
    fn lock_path(path: &Path) -> PathBuf {
        crate::shared::fs::with_suffix(path, ".lock")
    }

    // What: rejects what Compose would read differently.
    // Why: same rule as validate_env_value of setup.sh.
    // From: Issue #1683 | PR #2017
    fn env_safe(key: &str, raw: &str) -> Result<(), String> {
        match raw
            .chars()
            .find(|c| !safe(Syntax::Env, c.encode_utf8(&mut [0; 4])))
        {
            Some(c) => Err(format!("{key}: {c:?} is not allowed in the stack .env")),
            None => Ok(()),
        }
    }

    // What: checked sets and drops into the stack .env.
    // Why: a save and a restore write through one path.
    // From: Issue #1683 | PR #2020
    pub fn save_edits(
        path: &Path,
        current: &Settings,
        edits: &BTreeMap<String, Option<String>>,
    ) -> Result<(), String> {
        let set: BTreeMap<String, String> = edits
            .iter()
            .filter_map(|(k, v)| v.clone().map(|v| (k.clone(), v)))
            .collect();
        check_updates(path, current, &set)?;
        edit_lines(path, edits)
    }

    // What: the store checks without a write.
    // Why: store and the trial run share them.
    // From: Issue #1683 | PR #2020
    fn check_updates(
        path: &Path,
        current: &Settings,
        updates: &BTreeMap<String, String>,
    ) -> Result<(), String> {
        let over = override_path(path);
        let overridden = read_raw(&over)?;
        for (key, raw) in updates {
            env_safe(key, raw)?;
            // What: a key of <file>.local is refused here.
            // Why: its value wins; a save changes nothing.
            // From: Issue #1683 | PR #2017
            if overridden.contains_key(key) {
                return Err(format!(
                    "{key}: set in {}, which wins; remove it there first",
                    over.display()
                ));
            }
            // What: a container setting is refused here.
            // Why: in .env the name is a Compose host path.
            // From: Issue #1683 | PR #2017
            if current
                .spec(key)
                .is_some_and(|s| s.effect == Effect::Container)
            {
                return Err(format!("{key}: a container setting; setup.sh sets it"));
            }
            // What: a fixed setting is refused here.
            // Why: no save sets a command or a fence.
            // From: Issue #1683 | PR #2020
            if current.spec(key).is_some_and(|s| s.effect == Effect::Fixed) {
                return Err(format!("{key}: fixed by the SOT; no setting changes it"));
            }
            if !raw.is_empty() {
                current.validate(key, raw)?;
            }
        }
        Ok(())
    }

    // What: settings as they would be after a store.
    // Why: a dry run loads a copy; the file stays.
    // From: Issue #1683 | PR #2020
    pub fn trial(
        path: &Path,
        current: &Settings,
        updates: &BTreeMap<String, String>,
    ) -> Result<Settings, String> {
        check_updates(path, current, updates)?;
        let copy = crate::shared::fs::with_suffix(path, ".trial");
        let files = [
            (path.to_path_buf(), copy.clone()),
            (override_path(path), override_path(&copy)),
        ];
        let made = files.iter().try_for_each(|(from, to)| {
            let body = crate::shared::fs::read_if_present(from)
                .map_err(|e| format!("{}: {e}", from.display()))?
                .unwrap_or_default();
            let mode = crate::shared::fs::PRIVATE_MODE;
            let place = crate::shared::fs::Place::Replace;
            let owner = crate::shared::fs::Owner::default();
            crate::shared::fs::write(to, &body, mode, place, owner)
                .map_err(|e| format!("{}: {e}", to.display()))
        });
        let new = made
            .and_then(|()| write_lines(&copy, updates))
            .and_then(|()| Settings::load(&process_env, Some(&copy)));
        for f in [copy.clone(), override_path(&copy), lock_path(&copy)] {
            if let Err(e) = crate::shared::fs::delete_if_present(&f) {
                eprintln!("config: {} left behind: {e}", f.display());
            }
        }
        new
    }

    // What: sets KEY=VALUE lines in place under the lock.
    // Why: one file; comments, order and other keys stay.
    // From: Issue #1683 | PR #2017
    pub fn write_lines(path: &Path, updates: &BTreeMap<String, String>) -> Result<(), String> {
        let edits = updates
            .iter()
            .map(|(k, v)| (k.clone(), Some(v.clone())))
            .collect();
        edit_lines(path, &edits)
    }

    // What: set KEY=VALUE lines, or drop a key's line.
    // Why: no line means the default; KEY= is empty.
    // From: Issue #1683 | PR #2020
    pub fn edit_lines(
        path: &Path,
        updates: &BTreeMap<String, Option<String>>,
    ) -> Result<(), String> {
        let lock = lock_path(path);
        let held = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(&lock)
            .map_err(|e| format!("{}: {e}", lock.display()))?;
        held.lock()
            .map_err(|e| format!("{}: {e}", lock.display()))?;
        let old = crate::shared::fs::read_text_if_present(path)?.unwrap_or_default();
        let mut done = BTreeSet::new();
        let mut body = String::new();
        for line in old.lines() {
            let key = line_entry(line).map(|(key, _)| key);
            match key.filter(|k| updates.contains_key(*k)) {
                Some(key) => {
                    // What: a second line of it is dropped.
                    // Why: Compose, setup.sh read one value
                    // From: Issue #1683 | PR #2017
                    if done.insert(key.to_string())
                        && let Some(value) = &updates[key]
                    {
                        body.push_str(&format!("{key}={value}\n"));
                    }
                }
                None => {
                    body.push_str(line);
                    body.push('\n');
                }
            }
        }
        for (key, raw) in updates.iter().filter(|(k, _)| !done.contains(*k)) {
            if let Some(raw) = raw {
                body.push_str(&format!("{key}={raw}\n"));
            }
        }
        if body == old {
            return Ok(());
        }
        crate::shared::fs::write(
            path,
            body.as_bytes(),
            crate::shared::fs::PRIVATE_MODE,
            crate::shared::fs::Place::Replace,
            crate::shared::fs::Owner::default(),
        )
        .map_err(|e| format!("{}: {e}", path.display()))
    }

    // What: the checked settings of one process.
    // Why: one load at start; reload builds a new set.
    // From: Issue #1683 | PR #1980
    #[derive(Clone, Debug, Default)]
    pub struct Settings {
        specs: BTreeMap<String, Spec>,
        values: BTreeMap<String, Value>,
        origins: BTreeMap<String, Origin>,
        pub warnings: Vec<String>,
    }

    // What: methods of the checked Settings.
    // Why: every typed read goes through them.
    // From: Issue #1683 | PR #2020
    impl Settings {
        // What: settings of this process and its saved file
        // Why: ui, watchdog and cachehamster start alike.
        // From: Issue #1683 | PR #2019
        pub fn from_process() -> Result<Self, String> {
            Self::load(&process_env, saved_file().as_deref())
        }

        // What: load schema, then file > env > default.
        // Why: the file is live .env; env is from start.
        // From: Issue #1683 | PR #2017
        pub fn load(
            env: &dyn Fn(&str) -> Option<String>,
            saved_file: Option<&Path>,
        ) -> Result<Self, String> {
            let schema = env(SCHEMA_KEY).ok_or_else(|| format!("{SCHEMA_KEY} is not set"))?;
            let baked = env(DEFAULTS_KEY).unwrap_or_default();
            let defaults: BTreeMap<&str, &str> = baked_rows(&baked)
                .filter_map(|r| r.split_once('='))
                .collect();
            let mut set = Self::default();
            let mut errors = Vec::new();
            let mut specs = Vec::new();
            for row in baked_rows(&schema) {
                match Spec::parse(row) {
                    Ok(spec) => specs.push(spec),
                    Err(e) => errors.push(e),
                }
            }
            let mut file = match saved_file {
                Some(path) => read_file(path)?,
                None => BTreeMap::new(),
            };
            // What: file sets only keys the ui may store.
            // Why: host paths and fixed SOT values stay.
            // From: Issue #1683 | PR #2017
            let ui_keys: BTreeSet<&str> = specs
                .iter()
                .filter(|s| s.effect.writable())
                .map(|s| s.key.as_str())
                .collect();
            file.retain(|k, _| ui_keys.contains(k.as_str()));
            let stored: BTreeSet<String> = ui_keys.iter().map(|k| k.to_string()).collect();
            for spec in specs {
                // What: fixed values hold only fixed parts.
                // Why: a stored @KEY@ part undoes the fix.
                // From: Issue #1683 | PR #2020
                if spec.effect == Effect::Fixed {
                    let raw = defaults.get(spec.key.as_str()).copied().unwrap_or_default();
                    let names: BTreeSet<&str> = at_keys(raw).into_iter().collect();
                    for name in names.into_iter().filter(|k| stored.contains(*k)) {
                        errors.push(format!(
                            "{}: fixed, but its default names @{name}@, which a save can change",
                            spec.key
                        ));
                    }
                }
                let raw = match effective(&spec.key, &file, env, &defaults, 0) {
                    Ok(raw) => raw,
                    Err(e) => {
                        errors.push(e);
                        continue;
                    }
                };
                match raw {
                    Some((raw, origin)) => match spec.check(&raw) {
                        Ok((value, note)) => {
                            set.warnings.extend(note);
                            set.values.insert(spec.key.clone(), value);
                            set.origins.insert(spec.key.clone(), origin);
                        }
                        Err(e) => errors.push(e),
                    },
                    None if spec.required => errors.push(format!("{} is not set", spec.key)),
                    None => {}
                }
                set.specs.insert(spec.key.clone(), spec);
            }
            // What: SOT defaults, no schema row, as text.
            // Why: templates read fixed keys; env overrides
            // From: Issue #1683 | PR #1980
            for (key, value) in &defaults {
                if set.specs.contains_key(*key) {
                    continue;
                }
                let (raw, origin) = match env_set(env, key) {
                    Some(raw) => (raw, Origin::Env),
                    None => match expand_default(value, &file, env, &defaults, 0) {
                        Ok(raw) => (raw, Origin::Default),
                        Err(e) => {
                            errors.push(e);
                            continue;
                        }
                    },
                };
                if !raw.is_empty() {
                    set.values.insert(key.to_string(), Value::Text(raw));
                    set.origins.insert(key.to_string(), origin);
                }
            }
            if errors.is_empty() {
                Ok(set)
            } else {
                Err(errors.join("; "))
            }
        }

        // What: the schema row of one key.
        // Why: the ui needs kind and effect per field.
        // From: Issue #1683 | PR #1980
        pub fn spec(&self, key: &str) -> Option<&Spec> {
            self.specs.get(key)
        }

        // What: all schema rows in key order.
        // Why: the setup page lists every setting.
        // From: Issue #1683 | PR #1980
        fn specs(&self) -> impl Iterator<Item = &Spec> {
            self.specs.values()
        }

        // What: the checked value of one key.
        // Why: optional keys may have none.
        // From: Issue #1683 | PR #1980
        pub fn get(&self, key: &str) -> Option<&Value> {
            self.values.get(key)
        }

        // What: all loaded values, secrets left out.
        // Why: templates show fixed SOT values as well.
        // From: Issue #1683 | PR #1980
        pub fn texts(&self) -> impl Iterator<Item = (&String, String)> {
            self.values
                .iter()
                .filter(|(k, _)| !self.specs.get(*k).is_some_and(Spec::is_secret))
                .map(|(k, v)| (k, v.to_string()))
        }

        // What: every value as text, unset spec keys empty.
        // Why: pages, REST and CLI show one masked view.
        // From: Issue #1683 | PR #2020
        pub fn view(&self) -> BTreeMap<String, String> {
            let mut values: BTreeMap<String, String> = self
                .specs()
                .filter(|sp| !sp.is_secret())
                .map(|sp| (sp.key.clone(), String::new()))
                .collect();
            values.extend(self.texts().map(|(k, v)| (k.clone(), v)));
            values
        }

        // What: {"values":{..},"warnings":[..]} as JSON.
        // Why: REST and CLI show one shape.
        // From: Issue #1683 | PR #2020
        pub fn view_json(&self) -> serde_json::Value {
            serde_json::json!({"values": self.view(), "warnings": self.warnings})
        }

        // What: values of every secret-kind setting.
        // Why: masks in previews know what to hide.
        // From: Issue #1683 | PR #2020
        pub fn secret_values(&self) -> Vec<String> {
            self.values
                .iter()
                .filter(|(k, _)| self.specs.get(*k).is_some_and(Spec::is_secret))
                .map(|(_, v)| v.to_string())
                .filter(|v| !v.is_empty())
                .collect()
        }

        // What: schema row, masked value, origin per key.
        // Why: REST and CLI show what a setting is and why.
        // From: Issue #1683 | PR #2020
        pub fn describe(&self, only: Option<&str>) -> Result<serde_json::Value, String> {
            let view = self.view();
            let mut out = serde_json::Map::new();
            for sp in self.specs().filter(|sp| only.is_none_or(|k| k == sp.key)) {
                let kind = sp.kind.word();
                let extra = match &sp.kind {
                    Kind::Uint { min, max, clamp } => {
                        serde_json::json!({"min": min, "max": max, "clamp": clamp})
                    }
                    Kind::Choice(c) => serde_json::json!({"choices": c}),
                    _ => serde_json::Value::Null,
                };
                out.insert(
                    sp.key.clone(),
                    serde_json::json!({
                        "kind": kind,
                        "limits": extra,
                        "required": sp.required,
                        "effect": sp.effect.word(),
                        "owner": sp.owner,
                        "secret": sp.is_secret(),
                        "value": view.get(&sp.key),
                        "origin": self.origins.get(&sp.key),
                    }),
                );
            }
            match only {
                Some(k) if out.is_empty() => Err(format!("{k}: no such setting")),
                _ => Ok(serde_json::Value::Object(out)),
            }
        }

        // What: value as text; missing is an error.
        // Why: the error names the key.
        // From: Issue #1683 | PR #1980
        pub fn text(&self, key: &str) -> Result<String, String> {
            // What: a compose-only key falls back to env.
            // Why: operator keys like IP_HTTPS: no SOT row.
            // From: Issue #1683 | PR #1980
            self.get(key)
                .map(Value::to_string)
                .or_else(|| env_set(&process_env, key))
                .ok_or_else(|| format!("{key} is not set"))
        }

        // What: value as text; empty when it is missing.
        // Why: pages, optional features read it unguarded.
        // From: Issue #1683 | PR #2017
        pub fn text_or_empty(&self, key: &str) -> String {
            self.text(key).unwrap_or_default()
        }

        // What: value as number.
        // Why: only uint keys answer; others are errors.
        // From: Issue #1683 | PR #1980
        pub fn uint(&self, key: &str) -> Result<u64, String> {
            let raw = match self.get(key) {
                Some(Value::Uint(n)) => return Ok(*n),
                // What: fixed SOT default is text; parse it
                // Why: keys without schema row load as text
                // From: Issue #1683 | PR #1980
                Some(Value::Text(t)) => t.clone(),
                Some(_) => return Err(format!("{key} is no number")),
                // What: a compose-only key reads the env.
                // Why: same rule as text; one rule per key.
                // From: Issue #1683 | PR #2020
                None => env_set(&process_env, key).ok_or_else(|| format!("{key} is not set"))?,
            };
            parse_uint(&raw).ok_or_else(|| format!("{key} is no number"))
        }

        // What: value as bool.
        // Why: only bool keys answer; others are errors.
        // From: Issue #1683 | PR #1980
        pub fn flag(&self, key: &str) -> Result<bool, String> {
            let raw = match self.get(key) {
                Some(Value::Bool(b)) => return Ok(*b),
                // What: text answers only as true or false.
                // Why: AG-SEC-001: ALLOW_INSECURE_UI=true.
                // From: Issue #1683 | PR #2017
                Some(Value::Text(t)) => t.clone(),
                Some(_) => return Err(format!("{key} is no bool")),
                // What: a compose-only key reads the env.
                // Why: same rule as text; one rule per key.
                // From: Issue #1683 | PR #2020
                None => env_set(&process_env, key).ok_or_else(|| format!("{key} is not set"))?,
            };
            parse_true_false(&raw).ok_or_else(|| format!("{key} is no bool"))
        }

        // What: value as a narrower number type.
        // Why: callers need usize, u32 or u16, not u64.
        // From: Issue #1683 | PR #2017
        pub fn num<T: TryFrom<u64>>(&self, key: &str) -> Result<T, String> {
            T::try_from(self.uint(key)?).map_err(|_| format!("{key} is out of range"))
        }

        // What: value as file mode, read as octal text.
        // Why: the SOT owns every file mode, like 0640.
        // From: Issue #1683 | PR #2017
        pub fn mode(&self, key: &str) -> Result<u32, String> {
            u32::from_str_radix(&self.text(key)?, 8).map_err(|e| format!("{key}: {e}"))
        }

        // What: value as items; a known key may be empty.
        // Why: an unknown key is an error, as in text.
        // From: Issue #1683 | PR #1980
        pub fn list(&self, key: &str) -> Result<Vec<String>, String> {
            let raw = match self.get(key) {
                Some(Value::List(items)) => return Ok(items.clone()),
                Some(other) => other.to_string(),
                // What: a compose-only key reads the env.
                // Why: same rule as text; one rule per key.
                // From: Issue #1683 | PR #2020
                None => match env_set(&process_env, key) {
                    Some(t) => t,
                    None if self.spec(key).is_some() => String::new(),
                    None => return Err(format!("{key} is not set")),
                },
            };
            Ok(list_items(&raw).map(str::to_string).collect())
        }

        // What: check one raw value for a key.
        // Why: forms are checked before they are stored.
        // From: Issue #1683 | PR #1980
        pub fn validate(&self, key: &str, raw: &str) -> Result<Value, String> {
            self.spec(key)
                .ok_or_else(|| format!("{key} is not a known setting"))?
                .check(raw)
                .map(|(value, _)| value)
        }

        // What: a copy with one checked value replaced.
        // Why: the dns helper renders the live zone list.
        // From: Issue #1683 | PR #2020
        pub fn with(&self, key: &str, raw: &str) -> Result<Self, String> {
            let value = self.validate(key, raw)?;
            let mut copy = self.clone();
            copy.values.insert(key.to_string(), value);
            Ok(copy)
        }

        // What: keys whose value differs in newer.
        // Why: the runner acts per owner and effect.
        // From: Issue #1683 | PR #1980
        pub fn diff(&self, newer: &Self) -> Vec<Change> {
            let keys: BTreeSet<&String> = self.values.keys().chain(newer.values.keys()).collect();
            keys.into_iter()
                .filter(|k| self.values.get(*k) != newer.values.get(*k))
                .filter_map(|k| newer.specs.get(k).or_else(|| self.specs.get(k)))
                .map(|spec| Change {
                    key: spec.key.clone(),
                    owner: spec.owner.clone(),
                    effect: spec.effect,
                })
                .collect()
        }
    }

    // What: one changed key.
    // Why: owner and effect drive reload or restart.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Debug, Eq, PartialEq)]
    pub struct Change {
        pub key: String,
        pub owner: String,
        pub effect: Effect,
    }

    // What: path of the saved settings file, if one is set.
    // Why: the ui also writes this file on a save.
    // From: Issue #1683 | PR #2019
    pub fn saved_file() -> Option<PathBuf> {
        process_env(SETTINGS_FILE_ENV).map(PathBuf::from)
    }

    // What: reader for the process environment.
    // Why: Settings::load takes any reader.
    // From: Issue #1683 | PR #1980
    pub fn process_env(name: &str) -> Option<String> {
        std::env::var(name).ok()
    }

    // What: image coordinates this install runs on.
    // Why: footer, peer kit and setup link read one place.
    // From: Issue #1683 | PR #2020
    pub struct Image {
        pub registry: String,
        pub prefix: String,
        pub channel: String,
        pub tag: String,
    }

    // What: the image coordinates from the process env.
    // Why: compose sets them; an unset one is empty.
    // From: Issue #1683 | PR #2020
    pub fn image() -> Image {
        Image {
            registry: process_env("LANCACHE_IMAGE_REGISTRY").unwrap_or_default(),
            prefix: process_env("LANCACHE_IMAGE_PREFIX").unwrap_or_default(),
            channel: process_env("LANCACHE_IMAGE_CHANNEL").unwrap_or_default(),
            tag: process_env("LANCACHE_IMAGE_TAG").unwrap_or_default(),
        }
    }

    // What: what one config command does.
    // Why: run() matches these, the table names them.
    // From: Issue #1683 | PR #2020
    #[derive(Clone, Copy, PartialEq)]
    enum Op {
        Show,
        Schema,
        Set,
        Validate,
    }

    // What: every command of the config group.
    // Why: help, errors and the choice read this table.
    // From: Issue #1683 | PR #2020
    const COMMANDS: [(&str, crate::shared::cli::Entry<Op>); 4] = [
        ("show", crate::shared::cli::row(Op::Show, "show [KEY]")),
        (
            "schema",
            crate::shared::cli::row(Op::Schema, "schema [KEY]"),
        ),
        ("set", crate::shared::cli::row(Op::Set, "set KEY=VALUE ...")),
        (
            "validate",
            crate::shared::cli::row(Op::Validate, "validate KEY=VALUE ..."),
        ),
    ];

    // What: lancache-ng config: show, schema, set, validate
    // Why: settings reads have their CLI with their owner.
    // From: Issue #1683 | PR #2020
    pub async fn run(args: &[String]) -> Result<(), String> {
        let s = Settings::from_process()?;
        let op = crate::shared::cli::op_of(&COMMANDS, args.first());
        match (op, args.get(1..).unwrap_or_default()) {
            (Some(Op::Show), []) => println!("{}", s.view_json()),
            // What: schema row and origin of every setting.
            // Why: type, limits and why a value is set.
            // From: Issue #1683 | PR #2020
            (Some(Op::Schema), []) => println!("{}", s.describe(None)?),
            (Some(Op::Schema), [key]) => println!("{}", s.describe(Some(key))?),
            (Some(Op::Show), [key]) => match s.view().get(key) {
                Some(v) => println!("{v}"),
                None => return Err(format!("{key}: no such setting or a secret")),
            },
            // What: KEY=VALUE pairs go to the running ui.
            // Why: it saves, renders and applies at once.
            // From: Issue #1683 | PR #2020
            (Some(op @ (Op::Set | Op::Validate)), pairs) if !pairs.is_empty() => {
                let mut body = serde_json::Map::new();
                for pair in pairs {
                    let (k, v) = crate::shared::cli::pair(pair, "KEY=VALUE")?;
                    body.insert(k.to_string(), v.into());
                }
                // What: validate posts as a dry run.
                // Why: one save path checks both.
                // From: Issue #1683 | PR #2020
                let mut route = s.text("UI_ROUTE_SETTINGS")?;
                if op == Op::Validate {
                    route.push_str("?dry_run=1");
                }
                let body = crate::shared::http::Body::Json(body.into());
                let v = crate::shared::http::ui_socket(&s, &route, body).await?;
                println!("{v}");
            }
            _ => return Err(crate::shared::cli::help(&COMMANDS)),
        }
        Ok(())
    }
}

// What: DHCP page logic: Kea subnets, options, probe.
// Why: one home for the DHCP actions of the ui.
// From: Issue #1683 | PR #2020
mod dhcp {
    use crate::config::{self, Settings};
    use crate::dns::{chosen_lan_zone, main_domain_fields};
    use crate::shared::Fault;
    use crate::shared::dhcp::{Mode as DhcpMode, ipv4_of, off_service, option_data};
    use crate::shared::{docker, fs, http, kea, kea_conf, secret, snapshot};
    use crate::stack::{Fields, Stack, commit};
    use serde_json::{Value, json};
    use std::collections::BTreeMap;
    use std::path::PathBuf;

    // What: Kea subnets per LAN zone, by domain-name.
    // Why: the DNS page shows which subnet uses a domain.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn domain_subnets(s: &Settings) -> BTreeMap<String, Vec<String>> {
        let mut out: BTreeMap<String, Vec<String>> = BTreeMap::new();
        // What: no Kea answer leaves the column empty.
        // Why: DNS page must not fail when dhcp is down.
        // From: Issue #1683 | PR #2020
        let Ok(Some(cfg)) = kea_config(s).await else {
            return out;
        };
        for row in kea_subnets(&cfg).0 {
            let domain = row["domain"].as_str().unwrap_or_default();
            if domain.is_empty() {
                continue;
            }
            let zone = crate::shared::dns::canonical_zone(domain);
            let net = row["subnet"].as_str().unwrap_or_default().to_string();
            out.entry(zone).or_default().push(net);
        }
        out
    }

    // What: Kea control agent of this stack.
    // Why: host from env; basic auth with the stack token.
    // From: Issue #1683 | PR #1980
    pub(crate) fn kea_api(s: &Settings) -> Result<kea::Api, String> {
        let url = format!(
            "http://{}:{}/",
            s.text("DHCP_API_HOST")?,
            s.uint("KEA_CTRL_PORT")?
        );
        let token = secret::get(s, "KEA_CTRL_TOKEN")?;
        Ok(kea::Api::new(
            http::client(s)?,
            http::max_body(s)?,
            &url,
            &s.text("KEA_CTRL_USER")?,
            &token,
        ))
    }

    // What: one Kea subnet as flat page fields.
    // Why: the page shows fields; Kea has option-data.
    // From: Issue #1683 | PR #1980
    pub(crate) fn subnet_row(sn: &Value) -> Value {
        use crate::shared::dhcp::{DNS_SERVERS, DOMAIN_NAME, NTP_SERVERS, ROUTERS};
        let dns_text = option_data(sn, DNS_SERVERS.name);
        let dns: Vec<String> = config::list_items(&dns_text).map(str::to_string).collect();
        let pool = sn["pools"][0]["pool"].as_str().unwrap_or_default();
        let (start, end) = kea_conf::pool_parts(pool);
        let custom: Vec<Value> = kea_conf::coded_options(sn)
            .into_iter()
            .filter(|o| o.get("code").is_some())
            .collect();
        json!({
            "id": sn["id"].as_u64(),
            "subnet": sn["subnet"],
            "gateway": option_data(sn, ROUTERS.name),
            "dns_primary": dns.first().cloned().unwrap_or_default(),
            "dns_secondary": dns.get(1).cloned().unwrap_or_default(),
            "ntp_servers": option_data(sn, NTP_SERVERS.name),
            "domain": option_data(sn, DOMAIN_NAME.name),
            "pool_start": start,
            "pool_end": end,
            "lease_time": sn["valid-lifetime"],
            "custom_options": custom,
        })
    }

    // What: the live Kea config; none if mode is not Kea.
    // Why: one Kea read for subnets and the stack state.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn kea_config(s: &Settings) -> Result<Option<Value>, String> {
        let Some(api) = kea_api_in_kea_mode(s)? else {
            return Ok(None);
        };
        Ok(Some(live_config(&api).await?))
    }

    // What: set a whole Kea config and keep it.
    // Why: a stack restore puts Kea back as it ran.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn kea_set(s: &Settings, cfg: Value) -> Result<(), String> {
        let api = kea_api_in_kea_mode(s)?.ok_or("DHCP_MODE is not kea now")?;
        apply_kea(&api, &kea_store(s)?, &cfg).await
    }

    // What: apply a Kea config and keep it as newest.
    // Why: set, restore and edit end the same way.
    // From: Issue #1683 | PR #2020
    async fn apply_kea(api: &kea::Api, store: &snapshot::Store, cfg: &Value) -> Result<(), String> {
        api.set_config(cfg.clone()).await?;
        save_kea(store, cfg)
    }

    // What: the Kea API; none if the mode is not Kea.
    // Why: each Kea read stops alike in other modes.
    // From: Issue #1683 | PR #2020
    fn kea_api_in_kea_mode(s: &Settings) -> Result<Option<kea::Api>, String> {
        if DhcpMode::from_settings(s)? != DhcpMode::Kea {
            return Ok(None);
        }
        kea_api(s).map(Some)
    }

    // What: subnet rows and reservations of a Kea config.
    // Why: the page, REST, CLI and DNS page share them.
    // From: Issue #1683 | PR #1980
    fn kea_subnets(cfg: &Value) -> (Vec<Value>, Vec<Value>) {
        let (mut subnets, mut reservations) = (Vec::new(), Vec::new());
        for sn in kea_conf::subnets(cfg) {
            for r in sn["reservations"].as_array().into_iter().flatten() {
                reservations.push(json!({
                    "subnet_id": sn["id"].as_u64(), "mac": r["hw-address"],
                    "ip": r["ip-address"], "hostname": r["hostname"],
                }));
            }
            subnets.push(subnet_row(sn));
        }
        (subnets, reservations)
    }

    // What: subnets, reservations, leases from Kea.
    // Why: one reader for the page, REST and CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn kea_state(s: &Settings) -> Result<Option<Value>, String> {
        let Some(api) = kea_api_in_kea_mode(s)? else {
            return Ok(None);
        };
        let (subnets, reservations) = kea_subnets(&live_config(&api).await?);
        let mut leases = Vec::new();
        for l in api.leases().await? {
            let ends = l["cltt"].as_u64().unwrap_or(0) + l["valid-lft"].as_u64().unwrap_or(0);
            leases.push(json!({
                "ip": l["ip-address"], "mac": l["hw-address"], "hostname": l["hostname"],
                "subnet_id": l["subnet-id"].as_u64(), "expires": ends.to_string(),
            }));
        }
        Ok(Some(json!({
            "subnets": subnets,
            "reservations": reservations,
            "leases": leases,
        })))
    }

    // What: snapshot store of the Kea config.
    // Why: each subnet change can be undone.
    // From: Issue #1683 | PR #1980
    pub(crate) fn kea_store(s: &Settings) -> Result<snapshot::Store, String> {
        let dir = PathBuf::from(s.text("KEA_CONFIG_SNAPSHOT_DIR")?);
        let keep = s.num::<usize>("KEA_SNAPSHOT_KEEP")?;
        Ok(snapshot::Store {
            dir,
            keep,
            owner: fs::Owner::default(),
            file: Some(s.text("KEA_CONFIG_SNAPSHOT_FILE")?),
        })
    }

    // What: the fields of one Kea subnet.
    // Why: typed input; no form or route names here.
    // From: Issue #1683 | PR #2020
    pub(crate) struct SubnetInput {
        pub subnet: String,
        pub gateway: String,
        pub dns: Vec<String>,
        pub domain: String,
        pub ntp_servers: String,
        pub pool_start: String,
        pub pool_end: String,
        pub lease_time: String,
        // What: valid and max lease time, once read.
        // Why: read_subnet fills it from lease_time.
        // From: Issue #1683 | PR #2020
        pub lease: Option<(u64, u64)>,
    }

    // What: a subnet form read into its one written form.
    // Why: a bad address fails with its field, before Kea.
    // From: Issue #1683 | PR #2020
    fn read_subnet(s: &Settings, input: &SubnetInput) -> Result<SubnetInput, Fault> {
        use crate::shared::dns::{canonical_ip, canonical_net, net_holds};
        let field = |name: &str, r: Result<String, String>| {
            r.map_err(|e| Fault::Plain(format!("{name}: {e}")))
        };
        let subnet = field("subnet", canonical_net(&input.subnet))?;
        let gateway = match input.gateway.is_empty() {
            true => String::new(),
            false => field("gateway", canonical_ip(&input.gateway))?,
        };
        let mut pool = Vec::new();
        for (name, raw) in [
            ("pool_start", &input.pool_start),
            ("pool_end", &input.pool_end),
        ] {
            let ip = field(name, canonical_ip(raw))?;
            if !net_holds(&subnet, &ip) {
                return Err(Fault::Plain(format!("{name}: {ip} is outside {subnet}")));
            }
            pool.push(ip);
        }
        let dns = input.dns.iter().map(|d| field("dns", canonical_ip(d)));
        // What: empty lease time keeps Kea's default.
        // Why: a set one obeys the SOT lease bounds.
        // From: Issue #1683 | PR #2020
        let lease = match input.lease_time.trim() {
            "" => None,
            raw => {
                let n = config::parse_uint(raw)
                    .ok_or_else(|| Fault::Plain(format!("lease_time: {raw:?} is no number")))?;
                let limits = crate::shared::dhcp::lease_limits(s, n);
                Some(limits.map_err(|e| Fault::Plain(format!("lease_time: {e}")))?)
            }
        };
        Ok(SubnetInput {
            subnet,
            gateway,
            dns: dns.collect::<Result<_, _>>()?,
            domain: input.domain.clone(),
            ntp_servers: input.ntp_servers.clone(),
            pool_end: pool.pop().unwrap_or_default(),
            pool_start: pool.pop().unwrap_or_default(),
            lease_time: input.lease_time.clone(),
            lease,
        })
    }

    // What: a MAC address in its one written form.
    // Why: Kea matches hw-address as text; lower case.
    // From: Issue #1683 | PR #2020
    fn canonical_mac(text: &str) -> Result<String, Fault> {
        let parts: Vec<&str> = text.split([':', '-']).collect();
        let hex = |p: &&str| p.len() == 2 && p.bytes().all(|b| b.is_ascii_hexdigit());
        if parts.len() != 6 || !parts.iter().all(hex) {
            return Err(Fault::Plain(format!("mac: {text:?} is no MAC address")));
        }
        Ok(parts.join(":").to_ascii_lowercase())
    }

    // What: one change of the Kea configuration.
    // Why: page, REST and CLI name it by type.
    // From: Issue #1683 | PR #2020
    pub(crate) enum KeaEdit {
        SubnetAdd(SubnetInput),
        SubnetUpdate(u64, SubnetInput),
        SubnetRemove(u64),
        Option {
            subnet: u64,
            code: u8,
            data: Option<String>,
        },
        Static {
            subnet: u64,
            mac: String,
            ip: String,
            host: String,
            add: bool,
        },
        LeaseRelease(String),
        Rollback(String),
    }

    // What: a Kea change; the main subnet keeps settings.
    // Why: it cannot go; its edit sets DHCP_SUBNET...
    // From: Issue #1683 | PR #2020
    pub(crate) async fn kea_change(app: &Stack, s: &Settings, edit: &KeaEdit) -> Result<(), Fault> {
        let main = s.uint("DHCP_SUBNET_ID")?;
        if matches!(edit, KeaEdit::SubnetRemove(id) if *id == main) {
            return Err(Fault::key("err_main_subnet_remove", []));
        }
        kea_action(s, edit).await?;
        match edit {
            KeaEdit::SubnetUpdate(id, input) if *id == main => {
                Ok(commit(app, main_subnet_settings(s, input)?).await?)
            }
            _ => Ok(()),
        }
    }

    // What: SOT keys the main subnet is kept in.
    // Why: the settings are the only source of it.
    // From: Issue #1683 | PR #2020
    pub(crate) fn main_subnet_settings(
        s: &Settings,
        input: &SubnetInput,
    ) -> Result<Fields, String> {
        let mut f = Fields::new();
        for (key, value) in [
            ("DHCP_SUBNET", &input.subnet),
            ("DHCP_RANGE_START", &input.pool_start),
            ("DHCP_RANGE_END", &input.pool_end),
            ("DHCP_GATEWAY", &input.gateway),
            ("DHCP_NTP_SERVERS", &input.ntp_servers),
        ] {
            f.insert(key.into(), value.clone());
        }
        // What: main subnet domain sets main LAN domain.
        // Why: picking an extra swaps it with the old main.
        // From: Issue #1683 | PR #2020
        if !input.domain.is_empty() {
            f.extend(main_domain_fields(s, &input.domain)?);
        }
        if !input.lease_time.trim().is_empty() {
            f.insert(
                "DHCP_LEASE_TIME".into(),
                input.lease_time.trim().to_string(),
            );
        }
        f.insert("DHCP_DNS_SERVERS".into(), config::join_items(&input.dns));
        Ok(f)
    }

    // What: Kea counters, newest value per name.
    // Why: one reader for graphs, REST and CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn kea_stats(s: &Settings) -> Result<Option<BTreeMap<String, f64>>, String> {
        let Some(api) = kea_api_in_kea_mode(s)? else {
            return Ok(None);
        };
        let all = api.command("statistic-get-all", None).await?;
        let map = all.as_object().ok_or("kea statistic-get-all: no object")?;
        Ok(Some(
            map.iter()
                .filter_map(|(k, v)| v[0][0].as_f64().map(|n| (k.clone(), n)))
                .collect(),
        ))
    }

    // What: the text when the DHCP mode is not Kea.
    // Why: REST and CLI say the same.
    // From: Issue #1683 | PR #2020
    pub(crate) const NOT_KEA: &str = "DHCP mode is not kea";

    // What: what one dhcp command does.
    // Why: run() matches these, the table names them.
    // From: Issue #1683 | PR #2020
    #[derive(Clone, Copy, PartialEq)]
    enum Op {
        State,
        KeaSnapshots,
        Stats,
        KeaRollback,
        Probe,
        Do,
    }

    // What: every command of the dhcp group.
    // Why: help, errors and the choice read this table.
    // From: Issue #1683 | PR #2020
    const COMMANDS: [(&str, crate::shared::cli::Entry<Op>); 6] = [
        ("state", crate::shared::cli::row(Op::State, "state")),
        (
            "kea-snapshots",
            crate::shared::cli::row(Op::KeaSnapshots, "kea-snapshots"),
        ),
        ("stats", crate::shared::cli::row(Op::Stats, "stats")),
        (
            "kea-rollback",
            crate::shared::cli::row(Op::KeaRollback, "kea-rollback <snapshot-id>"),
        ),
        ("probe", crate::shared::cli::row(Op::Probe, "probe")),
        (
            "do",
            crate::shared::cli::row(Op::Do, "do <action> field=value ..."),
        ),
    ];

    // What: lancache-ng dhcp <command>: JSON on stdout.
    // Why: DHCP reads have their CLI with their owner.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn run(args: &[String]) -> Result<(), String> {
        use crate::shared::cli;
        let s = Settings::from_process()?;
        let v = match cli::op_of(&COMMANDS, args.first()).ok_or_else(|| cli::help(&COMMANDS))? {
            Op::State => kea_state(&s).await?.ok_or(NOT_KEA)?,
            Op::KeaSnapshots => kea_snapshots(&s)?,
            Op::Stats => json!(kea_stats(&s).await?.ok_or(NOT_KEA)?),
            // What: rollback calls Kea itself, not the ui.
            // Why: a repair must work while the ui is down.
            // From: Issue #1683 | PR #2020
            Op::KeaRollback => match &args[1..] {
                [id] => {
                    kea_rollback(&s, id).await?;
                    json!({"restored": "kea", "snapshot": id})
                }
                _ => return Err(cli::usage(&COMMANDS, |o| *o == Op::KeaRollback)),
            },
            // What: the LAN DHCP probe via the ui socket.
            // Why: the ui starts it on the host network.
            // From: Issue #1683 | PR #2020
            Op::Probe => {
                let route = s.text("UI_ROUTE_DHCP_CHECK")?;
                let body = http::Body::Form(vec![]);
                http::ui_socket(&s, &route, body).await?
            }
            // What: a DHCP page action via the ui socket.
            // Why: the ui checks, saves and applies it.
            // From: Issue #1683 | PR #2020
            Op::Do => {
                use crate::ui::DhcpOp;
                // What: rollback has its own word.
                // Why: one CLI way per job.
                // From: Issue #1683 | PR #2020
                let keys: Vec<&str> = DhcpOp::ALL
                    .iter()
                    .filter(|o| !matches!(o, DhcpOp::KeaRollback))
                    .map(|o| o.key())
                    .collect();
                http::page_do(&s, &keys, &args[1..]).await?
            }
        };
        println!("{v}");
        Ok(())
    }

    // What: {"snapshots":[{id,created_unix}]} of Kea.
    // Why: one reader for the page, REST and CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) fn kea_snapshots(s: &Settings) -> Result<Value, String> {
        Ok(json!({"snapshots": kea_store(s)?.rows()?}))
    }

    // What: put the Kea config back to a snapshot.
    // Why: page and CLI repair Kea the same way.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn kea_rollback(s: &Settings, id: &str) -> Result<(), String> {
        let api = kea_api_in_kea_mode(s)?.ok_or(NOT_KEA)?;
        let store = kea_store(s)?;
        let cfg: Value = store.read(id)?;
        // What: the state before is kept as a snapshot.
        // Why: a rollback can itself be rolled back.
        // From: Issue #1683 | PR #2020
        save_kea(&store, &live_config(&api).await?)?;
        apply_kea(&api, &store, &cfg).await
    }

    // What: the running Kea config without its hash.
    // Why: snapshots and edits hold what config-set takes.
    // From: Issue #1683 | PR #2020
    async fn live_config(api: &kea::Api) -> Result<Value, String> {
        let mut cfg = api.config().await?;
        if let Some(top) = cfg.as_object_mut() {
            top.remove("hash");
        }
        Ok(cfg)
    }

    // What: store one Kea config as a snapshot.
    // Why: edits and rollbacks write snapshots alike.
    // From: Issue #1683 | PR #2020
    fn save_kea(store: &snapshot::Store, cfg: &Value) -> Result<(), String> {
        store
            .save(&serde_json::to_vec(cfg).map_err(|e| e.to_string())?)
            .map(drop)
    }

    // What: change Kea subnets with a closure.
    // Why: get, edit, set, write, snapshot; one path.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn kea_edit(
        s: &Settings,
        edit: impl FnOnce(&mut Vec<Value>) -> Result<(), Fault>,
    ) -> Result<(), Fault> {
        let api = kea_api_in_kea_mode(s)?.ok_or(NOT_KEA)?;
        let mut cfg = live_config(&api).await?;
        let mut subnets = kea_conf::subnets(&cfg).to_vec();
        edit(&mut subnets)?;
        kea_conf::set_subnets(&mut cfg, subnets);
        Ok(apply_kea(&api, &kea_store(s)?, &cfg).await?)
    }

    // What: Kea subnet from typed subnet input.
    // Why: named options; code options and hosts kept.
    // From: Issue #1683 | PR #1980
    pub(crate) fn subnet_from(input: &SubnetInput, id: u64, old: Option<&Value>) -> Value {
        let hosts: Vec<String> = config::list_items(&input.ntp_servers)
            .map(str::to_string)
            .collect();
        let ntp = ipv4_of(&hosts, "ntp_servers");
        let mut opts = kea_conf::named_rows(&input.gateway, &input.dns, &input.domain, &ntp);
        if let Some(old) = old {
            opts.extend(kea_conf::coded_options(old));
        }
        let pool = kea_conf::pool_text(&input.pool_start, &input.pool_end);
        let mut sn = json!({"id": id, "subnet": input.subnet, "pools": [{"pool": pool}],
                        "option-data": opts});
        if let Some((valid, max)) = input.lease {
            sn["valid-lifetime"] = valid.into();
            sn["max-valid-lifetime"] = max.into();
        }
        if let Some(hosts) = old.and_then(|o| o.get("reservations")) {
            sn["reservations"] = hosts.clone();
        }
        sn
    }

    // What: Kea subnet with the given id.
    // Why: edits target a subnet by id, not position.
    // From: Issue #1683 | PR #1980
    pub(crate) fn subnet_mut(list: &mut [Value], id: u64) -> Result<&mut Value, Fault> {
        let found = list.iter_mut().find(|x| x["id"].as_u64() == Some(id));
        found.ok_or_else(|| Fault::key("err_no_subnet", [("id", id.to_string())]))
    }

    // What: Kea subnet, option and host edits.
    // Why: all go through kea_edit.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn kea_action(s: &Settings, edit: &KeaEdit) -> Result<(), Fault> {
        // What: a subnet domain must be a LAN domain.
        // Why: DDNS and DNS answer only for those zones.
        // From: Issue #1683 | PR #2020
        if let KeaEdit::SubnetAdd(input) | KeaEdit::SubnetUpdate(_, input) = edit
            && !input.domain.is_empty()
        {
            chosen_lan_zone(s, &input.domain)?;
        }
        match edit {
            KeaEdit::SubnetAdd(input) => {
                let input = &read_subnet(s, input)?;
                kea_edit(s, |l| {
                    let next = l.iter().filter_map(|x| x["id"].as_u64()).max().unwrap_or(0) + 1;
                    let mut sn = subnet_from(input, next, None);
                    kea_conf::subnet_ddns_suffix(s, &mut sn)?;
                    l.push(sn);
                    Ok(())
                })
                .await
            }
            KeaEdit::SubnetUpdate(id, input) => {
                let input = &read_subnet(s, input)?;
                kea_edit(s, |l| {
                    let sn = subnet_mut(l, *id)?;
                    *sn = subnet_from(input, *id, Some(&sn.clone()));
                    Ok(kea_conf::subnet_ddns_suffix(s, sn)?)
                })
                .await
            }
            KeaEdit::SubnetRemove(id) => {
                kea_edit(s, |l| {
                    l.retain(|x| x["id"].as_u64() != Some(*id));
                    Ok(())
                })
                .await
            }
            KeaEdit::Option { subnet, code, data } => {
                kea_edit(s, |l| {
                    let sn = subnet_mut(l, *subnet)?;
                    let mut opts = sn["option-data"].as_array().cloned().unwrap_or_default();
                    let same = |o: &Value| kea_conf::row_code(o) == Some(u64::from(*code));
                    opts.retain(|o| !same(o) || !kea_conf::is_coded(o));
                    if let Some(data) = data {
                        opts.push(kea_conf::coded_row(*code, data));
                    }
                    sn["option-data"] = opts.into();
                    Ok(())
                })
                .await
            }
            KeaEdit::Static {
                subnet,
                mac,
                ip,
                host,
                add,
            } => {
                let mac = canonical_mac(mac)?;
                let ip = match add {
                    true => crate::shared::dns::canonical_ip(ip)
                        .map_err(|e| Fault::Plain(format!("ip: {e}")))?,
                    false => ip.clone(),
                };
                kea_edit(s, |l| {
                    let sn = subnet_mut(l, *subnet)?;
                    let mut hosts = sn["reservations"].as_array().cloned().unwrap_or_default();
                    let same = |r: &Value| {
                        r["hw-address"]
                            .as_str()
                            .and_then(|m| canonical_mac(m).ok())
                            .as_ref()
                            == Some(&mac)
                    };
                    hosts.retain(|r| !same(r));
                    if *add {
                        hosts.push(json!({"hw-address": mac, "ip-address": ip, "hostname": host}));
                    }
                    sn["reservations"] = hosts.into();
                    Ok(())
                })
                .await
            }
            KeaEdit::LeaseRelease(ip) => {
                let ip = crate::shared::dns::canonical_ip(ip)
                    .map_err(|e| Fault::Plain(format!("ip: {e}")))?;
                let api = kea_api_in_kea_mode(s)?.ok_or(NOT_KEA)?;
                Ok(api.release(&ip).await?)
            }
            KeaEdit::Rollback(id) => Ok(kea_rollback(s, id).await?),
        }
    }

    // What: in mode off a running dhcp is stopped again.
    // Why: compose up may start it after the ui.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn stays_off(app: &Stack, s: &Settings) -> Result<Option<String>, String> {
        let Some(service) = off_service(s)? else {
            return Ok(None);
        };
        let (grace, limit) = app.limits(s)?;
        let list = app.docker.stack(s).await?;
        let running = docker::rows_of(&list, &service).find(|c| docker::is_running(c));
        let Some(name) = running.and_then(docker::name_of) else {
            return Ok(None);
        };
        let r = app
            .docker
            .act(name, docker::Action::Stop, grace, limit)
            .await;
        Ok(Some(format!("mode off, stop {name} {r:?}")))
    }

    // What: one DHCP probe; the report as JSON.
    // Why: runs on the host network, apart from the ui.
    // From: Issue #1683 | PR #1985
    pub(crate) fn probe_cli(s: &Settings) -> Result<(), String> {
        let report = crate::shared::dhcp_probe::run(s);
        println!(
            "{}",
            serde_json::to_string(&report).map_err(|e| e.to_string())?
        );
        Ok(())
    }
}

// What: DNS zones, records, secondaries and dns helper.
// Why: one home for DNS logic of ui and the dns role.
// From: Issue #1683 | PR #2020
mod dns {
    use crate::config::{self, Settings};
    use crate::shared::Fault;
    use crate::shared::dns::Role;
    use crate::shared::peer::{self, PeerZone, ZoneState};
    use crate::shared::task::or_stop;
    use crate::shared::tool;
    use crate::shared::{apply, fs, pdns, recursor_conf, render, secret};
    use crate::stack::{Fields, Stack, apply_all, commit, commit_with, list_change, single_field};
    use serde_json::{Value, json};
    use std::collections::BTreeMap;
    use std::net::{IpAddr, SocketAddr};
    use std::path::Path;
    use std::time::{Duration, Instant};

    // What: the zones the own pdns pulls, with serials.
    // Why: the primary sets them; the recursors follow.
    // From: Issue #1683 | PR #2020
    async fn own_zones(s: &Settings) -> Result<BTreeMap<String, u32>, String> {
        let api = peer::own_api(s)?;
        Ok(serial_map(
            api.zones().await?.into_iter().filter(|z| z.kind == "Slave"),
        ))
    }

    // What: serial of each zone in a zone list, by name.
    // Why: the follow and flush rounds compare by name.
    // From: Issue #1683 | PR #2020
    fn serial_map(zones: impl IntoIterator<Item = pdns::Zone>) -> BTreeMap<String, u32> {
        zones.into_iter().map(|z| (z.name, z.serial)).collect()
    }

    // What: dns configs for these zones; true if changed.
    // Why: one renderer with the render one-shot.
    // From: Issue #1683 | PR #2020
    fn write_for(s: &Settings, zones: &[String]) -> Result<bool, String> {
        let s = s.with("DNS_SECONDARY_ZONES", &crate::config::join_items(zones))?;
        let sec = render::secrets(&s)?;
        let files = render::dns_only(&s, &sec).map_err(|e| e.join("; "))?;
        Ok(!render::write_files(&s, &files)?.is_empty())
    }

    // What: the dns reload commands of the SOT, run here.
    // Why: the recursors then read the new forward zones.
    // From: Issue #1683 | PR #2020
    fn reload(s: &Settings) -> Result<(), String> {
        let owner = s.text("DNS_SERVICE")?;
        for cmd in apply::exec_cmds(&s.list("RELOAD_EXEC")?, &owner) {
            let (program, args) = cmd.split_first().ok_or("empty reload command")?;
            tool::run(std::process::Command::new(program).args(args))?;
        }
        Ok(())
    }

    // What: what is in place so far.
    // Why: a step is noted only after it worked.
    // From: Issue #1683 | PR #2020
    #[derive(Default)]
    struct Done {
        // What: TSIG key, setup zones and key binding done.
        // Why: once per start; then primary keeps zones.
        // From: Issue #1683 | PR #2020
        seeded: bool,
        // What: a written config not yet reloaded.
        // Why: a failed reload must be retried.
        // From: Issue #1683 | PR #2020
        reload_due: bool,
        // What: the serial each zone was last flushed at.
        // Why: a failed flush is retried next round.
        // From: Issue #1683 | PR #2020
        flushed: peer::Flushed,
        // What: own and off cache domains, last read.
        // Why: a primary that is down leaves the RPZ.
        // From: Issue #1683 | PR #2020
        cdn: Option<(Vec<String>, Vec<String>)>,
    }

    // What: TSIG key, setup zones without removal, binding.
    // Why: the secondary pulls with its key from the start.
    // From: Issue #1683 | PR #2020
    async fn seed(s: &Settings) -> Result<(), String> {
        let key = peer::ensure_tsigkey(s).await?;
        peer::ensure_secondary_zones(s, &key).await?;
        peer::ensure_tsig(s, &key).await
    }

    // What: own and off cache domains it published.
    // Why: its lists decide the RPZ of a secondary too.
    // From: Issue #1683 | PR #2020
    async fn primary_cdn(
        s: &Settings,
        zones: &[String],
    ) -> Result<Option<(Vec<String>, Vec<String>)>, String> {
        let setup = s.list("DNS_SECONDARY_ZONES")?;
        let Some(zone) = zones.first().or(setup.first()) else {
            return Ok(None);
        };
        let api = peer::api_at(s, &s.text("DNS_XFR_PRIMARY")?)?;
        let values = api.metadata(zone, peer::CDN_META).await?;
        Ok(peer::cdn_from_meta(&values))
    }

    // What: one round towards the wanted state.
    // Why: same input changes nothing; a failure retries.
    // From: Issue #1683 | PR #2020
    async fn round(s: &Settings, done: &mut Done) -> Result<(), String> {
        // What: before pdns answers, the setup zone list.
        // Why: pdns and recursors start on the first write.
        // From: Issue #1683 | PR #2020
        let live = own_zones(s).await;
        let names: Vec<String> = match &live {
            Ok(zones) => zones.keys().cloned().collect(),
            Err(_) => s.list("DNS_SECONDARY_ZONES")?,
        };
        // What: no answer keeps the last lists read.
        // Why: a primary that is down keeps the RPZ whole.
        // From: Issue #1683 | PR #2020
        let mut kept = false;
        match primary_cdn(s, &names).await {
            Ok(Some(lists)) => done.cdn = Some(lists),
            Ok(None) => {}
            Err(e) => {
                eprintln!("lancache-dns: cache domains of the primary: {e}");
                // What: after a restart the files stay.
                // Why: own lists would undo the primary's.
                // From: Issue #1683 | PR #2020
                let rpz = s.text(&recursor_conf::Which::Http.key("RPZ_FILE"))?;
                kept = done.cdn.is_none() && Path::new(&rpz).exists();
            }
        }
        let view = match &done.cdn {
            Some((custom, off)) => s
                .with("CDN_CUSTOM_DOMAINS", &config::join_items(custom))?
                .with("CDN_DISABLED_DOMAINS", &config::join_items(off))?,
            None => s.clone(),
        };
        let s = &view;
        if !kept && write_for(s, &names)? {
            done.reload_due = true;
        }
        let zones = live?;
        if !done.seeded {
            seed(s).await?;
            done.seeded = true;
            eprintln!("lancache-dns: TSIG key and setup zones in place");
        }
        if done.reload_due {
            reload(s)?;
            done.reload_due = false;
            eprintln!("lancache-dns: recursors forward {} zones", names.len());
        }
        for (zone, serial) in done.flushed.due(&zones) {
            match peer::flush_zone(s, &zone).await {
                Ok(()) => done.flushed.done(&zone, serial),
                Err(e) => eprintln!("lancache-dns: flush {zone}: {e}"),
            }
        }
        Ok(())
    }

    // What: dns role entry: the loop or one command.
    // Why: image rows call it bare; the CLI checks a round.
    // From: Issue #1683 | PR #2020
    pub async fn run(args: &[String]) -> Result<(), String> {
        use crate::shared::cli;
        let op = match args.first().map(String::as_str) {
            None => Op::Daemon,
            Some(word) => cli::pick(&COMMANDS, word)
                .map(|row| row.op)
                .ok_or_else(|| cli::help(&COMMANDS))?,
        };
        match op {
            Op::Daemon => follow().await,
            // What: one follow round, then exit with it.
            // Why: the CLI check runs the daemon loop code.
            // From: Issue #1683 | PR #2020
            Op::FollowOnce => {
                let s = Settings::from_process()?;
                if Role::from_settings(&s)? != Role::Secondary {
                    return Err("follow-once: this host is no secondary".into());
                }
                round(&s, &mut Done::default()).await?;
                println!("{}", json!({"round": "ok"}));
                Ok(())
            }
            // What: zone serials and states as JSON.
            // Why: same reader as the DNS page and REST.
            // From: Issue #1683 | PR #2020
            Op::SyncCheck => {
                let v = zone_overview(&Settings::from_process()?).await?;
                println!("{v}");
                match out_of_sync(&v) {
                    0 => Ok(()),
                    n => Err(format!("sync-check: {n} zone or server not in sync")),
                }
            }
            // What: a DNS page action via the ui socket.
            // Why: the ui checks, saves and applies it.
            // From: Issue #1683 | PR #2020
            Op::Do => {
                use crate::ui::DnsOp;
                // What: rollback and CDN rows: own words.
                // Why: one CLI way per job.
                // From: Issue #1683 | PR #2020
                let keys: Vec<&str> = DnsOp::ALL
                    .iter()
                    .filter(|o| {
                        !matches!(
                            o,
                            DnsOp::ZoneRollback
                                | DnsOp::DnsAdd
                                | DnsOp::DnsRemove
                                | DnsOp::DnsToggle
                        )
                    })
                    .map(|o| o.key())
                    .collect();
                let s = Settings::from_process()?;
                let v = crate::shared::http::page_do(&s, &keys, &args[1..]).await?;
                println!("{v}");
                Ok(())
            }
            Op::Secondary => secondary_do(&args[1..]).await,
            // What: zones: overview; zones ensure: via ui.
            // Why: ensure renders and reloads in the ui.
            // From: Issue #1683 | PR #2020
            Op::Zones => {
                let s = Settings::from_process()?;
                match args.get(1).map(String::as_str) {
                    None => println!("{}", zone_overview(&s).await?),
                    Some("ensure") => {
                        let route = s.text("UI_ROUTE_DNS_ZONES_ENSURE")?;
                        let body = crate::shared::http::Body::Form(vec![]);
                        let v = crate::shared::http::ui_socket(&s, &route, body).await?;
                        println!("{v}");
                    }
                    Some(_) => return Err(cli::usage(&COMMANDS, |o| *o == Op::Zones)),
                }
                Ok(())
            }
            // What: LAN domains, records, PTRs as JSON.
            // Why: a read; it needs no running ui.
            // From: Issue #1683 | PR #2020
            Op::Records => {
                let v = lan_view(&Settings::from_process()?).await?;
                println!("{v}");
                match v["error"].as_str() {
                    Some(e) => Err(format!("records: {e}")),
                    None => Ok(()),
                }
            }
            // What: TSIG key state without its value.
            // Why: a read; rc 1 if file and pdns differ.
            // From: Issue #1683 | PR #2020
            Op::Tsig => {
                let v = tsig_state(&Settings::from_process()?).await?;
                println!("{v}");
                match v["ok"].as_bool() {
                    Some(true) => Ok(()),
                    _ => Err("tsig: key missing or different".into()),
                }
            }
            // What: container probe: any reply counts.
            // Why: a dead upstream must not restart dns.
            // From: Issue #1683 | PR #2020
            Op::Healthcheck => healthcheck(&Settings::from_process()?).await,
            // What: soa-probe ZONE [http/https/auth/ip]
            // Why: the serial one server holds; no ui.
            // From: Issue #1683 | PR #2020
            Op::SoaProbe => match &args[1..] {
                [zone] | [zone, _] => {
                    let target = args.get(2).map_or("auth", String::as_str);
                    let v = soa_probe(&Settings::from_process()?, zone, target).await?;
                    println!("{v}");
                    match v["serves_zone"].as_bool() {
                        Some(true) => Ok(()),
                        _ => Err(format!("soa-probe: {} does not serve {zone}", v["server"])),
                    }
                }
                _ => Err(cli::usage(&COMMANDS, |o| *o == Op::SoaProbe)),
            },
            // What: query NAME TYPE [http/https/auth/ip]
            // Why: a real DNS answer; needs no running ui.
            // From: Issue #1683 | PR #2020
            Op::Query => match &args[1..] {
                [n, ty] | [n, ty, _] => {
                    let target = args.get(3).map_or("http", String::as_str);
                    let s = Settings::from_process()?;
                    println!("{}", query(&s, n, ty, target).await?);
                    Ok(())
                }
                _ => Err(cli::usage(&COMMANDS, |o| *o == Op::Query)),
            },
            // What: DNSSEC anchors, proven zones, NTAs.
            // Why: a read; it needs no running ui.
            // From: Issue #1683 | PR #2020
            Op::Dnssec => {
                println!("{}", dnssec_status(&Settings::from_process()?).await?);
                Ok(())
            }
            // What: PowerDNS APIs reachable; stats counts.
            // Why: reads; they need no running ui.
            // From: Issue #1683 | PR #2020
            Op::ApiCheck | Op::Stats => {
                let cmd = cli::word(&COMMANDS, op);
                let v = peer::api_report(&Settings::from_process()?, op == Op::Stats).await?;
                println!("{v}");
                match v["ok"].as_bool() {
                    Some(true) => Ok(()),
                    _ => Err(format!("{cmd}: a PowerDNS API did not answer")),
                }
            }
            // What: empty recursor caches; no zone = all.
            // Why: a repair must work while the ui is down.
            // From: Issue #1683 | PR #2020
            Op::Flush => {
                let zone = match &args[1..] {
                    [] => ".".to_string(),
                    [z] => z.clone(),
                    _ => return Err(cli::usage(&COMMANDS, |o| *o == Op::Flush)),
                };
                peer::flush_zone(&Settings::from_process()?, &zone).await?;
                println!("{}", json!({"flushed": zone}));
                Ok(())
            }
        }
    }

    // What: "secondary <name> <action> [address]".
    // Why: the DNS page buttons per secondary.
    // From: Issue #1683 | PR #2020
    async fn secondary_do(args: &[String]) -> Result<(), String> {
        use crate::shared::http::Body;
        use crate::ui::SecondaryOp;
        let s = Settings::from_process()?;
        // What: the word is the last part of the route.
        // Why: the key of remove carries no action word.
        // From: Issue #1683 | PR #2020
        let mut ops = Vec::new();
        for op in SecondaryOp::ALL {
            let route = s.text(op.key())?;
            let word = route.rsplit('/').next().unwrap_or_default().to_string();
            ops.push((*op, route, word));
        }
        let words: Vec<&str> = ops.iter().map(|o| o.2.as_str()).collect();
        let usage = format!(
            "{}; actions {}",
            crate::shared::cli::usage(&COMMANDS, |o| *o == Op::Secondary),
            words.join("|")
        );
        let (name, word, rest) = match args {
            [n, w, rest @ ..] => (n, w, rest),
            _ => return Err(usage),
        };
        let (op, route, _) = ops.iter().find(|o| o.2 == *word).ok_or(usage.clone())?;
        let body = match (op, rest) {
            (SecondaryOp::Address, [ip]) => Body::Json(json!({"address": ip})),
            (SecondaryOp::Address, _) => return Err(usage),
            (_, []) => Body::Form(vec![]),
            _ => return Err(usage),
        };
        let route = route.replace("{name}", name);
        let v = crate::shared::http::ui_socket(&s, &route, body).await?;
        println!("{}", json!({"done": route, "answer": v}));
        Ok(())
    }

    // What: what one dns command does.
    // Why: run() matches these, the table names them.
    // From: Issue #1683 | PR #2020
    #[derive(Clone, Copy, PartialEq)]
    enum Op {
        Daemon,
        SoaProbe,
        FollowOnce,
        Healthcheck,
        Records,
        Tsig,
        SyncCheck,
        Do,
        Secondary,
        Flush,
        Dnssec,
        ApiCheck,
        Stats,
        Query,
        Zones,
    }

    // What: every command of the dns role.
    // Why: help, errors and the choice read this table.
    // From: Issue #1683 | PR #2020
    const COMMANDS: [(&str, crate::shared::cli::Entry<Op>); 15] = [
        ("daemon", crate::shared::cli::row(Op::Daemon, "daemon")),
        (
            "soa-probe",
            crate::shared::cli::row(Op::SoaProbe, "soa-probe <zone> [http|https|auth|ip[:port]]"),
        ),
        (
            "follow-once",
            crate::shared::cli::row(Op::FollowOnce, "follow-once"),
        ),
        (
            "healthcheck",
            crate::shared::cli::row(Op::Healthcheck, "healthcheck"),
        ),
        ("records", crate::shared::cli::row(Op::Records, "records")),
        ("tsig", crate::shared::cli::row(Op::Tsig, "tsig")),
        (
            "sync-check",
            crate::shared::cli::row(Op::SyncCheck, "sync-check"),
        ),
        (
            "do",
            crate::shared::cli::row(Op::Do, "do <action> field=value ..."),
        ),
        (
            "secondary",
            crate::shared::cli::row(Op::Secondary, "secondary <name> <action> [address]"),
        ),
        ("flush", crate::shared::cli::row(Op::Flush, "flush [zone]")),
        ("dnssec", crate::shared::cli::row(Op::Dnssec, "dnssec")),
        (
            "api-check",
            crate::shared::cli::row(Op::ApiCheck, "api-check"),
        ),
        ("stats", crate::shared::cli::row(Op::Stats, "stats")),
        (
            "query",
            crate::shared::cli::row(Op::Query, "query <name> <type> [http|https|auth|ip[:port]]"),
        ),
        (
            "zones",
            crate::shared::cli::row(Op::Zones, "zones [ensure]"),
        ),
    ];

    // What: serials of managed zones on all servers.
    // Why: one overview for the DNS page, REST and CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn zone_overview(s: &Settings) -> Result<Value, String> {
        let ours = peer::own_api(s)?.zones().await?;
        let mut columns = vec![json!({"name": "primary", "error": Value::Null})];
        let mut pairs: Vec<Option<Vec<PeerZone>>> = Vec::new();
        for (name, address) in crate::shared::pdns_conf::secondaries(s)? {
            match peer::zones_at(s, &address).await {
                Ok(theirs) => {
                    columns.push(json!({"name": name, "error": Value::Null}));
                    pairs.push(Some(peer::peer_zones(s, &ours, &theirs)?));
                }
                Err(e) => {
                    columns.push(json!({"name": name, "error": e}));
                    pairs.push(None);
                }
            }
        }
        // What: primary serials; no secondary list given.
        // Why: peer_zones pairs the managed zones once.
        // From: Issue #1683 | PR #2020
        let base = peer::peer_zones(s, &ours, &[])?;
        let rows: Vec<Value> = base
            .iter()
            .enumerate()
            .map(|(i, z)| {
                let mut serials = vec![z.primary];
                let mut states: Vec<Option<&str>> = Vec::new();
                for pair in &pairs {
                    let cell = pair.as_ref().map(|p| &p[i]);
                    serials.push(cell.and_then(|c| c.secondary));
                    states.push(cell.map(|c| peer::zone_state(c).word()));
                }
                json!({"zone": z.zone, "serials": serials, "states": states})
            })
            .collect();
        // What: zones in pdns that nothing here manages.
        // Why: a left-over zone answers for no LAN domain.
        // From: Issue #1683 | PR #2020
        let mut known = crate::shared::dns::managed_zones(s)?;
        known.extend(own_tops(s)?);
        let extra: Vec<&str> = ours
            .iter()
            .map(|z| z.name.as_str())
            .filter(|n| !known.iter().any(|k| k == n))
            .collect();
        Ok(json!({"columns": columns, "rows": rows, "extra": extra}))
    }

    // What: cells not in sync plus servers that failed.
    // Why: the CLI check exits 1 on any of them.
    // From: Issue #1683 | PR #2020
    fn out_of_sync(v: &Value) -> usize {
        let cols = v["columns"].as_array().into_iter().flatten();
        let down = cols.filter(|c| !c["error"].is_null()).count();
        let rows = v["rows"].as_array().into_iter().flatten();
        let cells = rows.flat_map(|r| r["states"].as_array().into_iter().flatten());
        let off = cells
            .filter(|c| c.as_str().is_some_and(|w| w != ZoneState::InSync.word()))
            .count();
        down + off
    }

    // What: idle on a primary, else rounds forever.
    // Why: OpenRC keeps process; the primary's ui renders.
    // From: Issue #1683 | PR #2020
    async fn follow() -> Result<(), String> {
        let mut done = Done::default();
        loop {
            let s = Settings::from_process()?;
            let wait = Duration::from_secs(s.uint("DNS_FOLLOW_SECONDS")?);
            if Role::from_settings(&s)? == Role::Secondary
                && let Err(e) = round(&s, &mut done).await
            {
                eprintln!("lancache-dns: {e}");
            }
            tokio::time::sleep(wait).await;
        }
    }

    // What: save a change, then drop zones it left behind.
    // Why: LAN domain edits and settings saves end alike.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn commit_and_prune(
        app: &Stack,
        form: Fields,
        before: &[String],
    ) -> Result<(), String> {
        commit(app, form).await?;
        delete_old_zones(&app.settings(), before).await;
        Ok(())
    }

    // What: remove zones a new LAN domain left behind.
    // Why: an old zone would keep answering its names.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn delete_old_zones(s: &Settings, before: &[String]) {
        let read = (hosted_now(s), Role::from_settings(s), peer::own_api(s));
        let (now, role, api) = match read {
            (Ok(now), Ok(role), Ok(api)) => (now, role, api),
            (Err(e), _, _) | (_, Err(e), _) | (_, _, Err(e)) => {
                eprintln!("ui: old zones kept: {e}");
                return;
            }
        };
        if role == Role::Secondary {
            return;
        }
        for zone in before.iter().filter(|z| !now.contains(z)) {
            // What: only zones without own records go.
            // Why: a record the user added is never lost.
            // From: Issue #1683 | PR #1980
            let own = match api.rrsets(zone).await {
                Ok(sets) => !own_rrsets(&sets).is_empty(),
                Err(e) => {
                    eprintln!("ui: zone {zone} kept: rrsets not read: {e}");
                    continue;
                }
            };
            let done = if own {
                Err(Fault::key("err_zone_has_records", []))
            } else {
                api.delete_zone(zone).await.map_err(Fault::from)
            };
            match done {
                Ok(()) => eprintln!("ui: zone {zone} removed"),
                Err(e) => eprintln!("ui: zone {zone} kept: {e}"),
            }
        }
        peers_follow(s);
    }

    // What: reverse DNS name of an address.
    // Why: PTR rows live in in-addr.arpa or ip6.arpa.
    // From: Issue #1683 | PR #1980
    pub(crate) fn reverse_name(ip: &str) -> Result<String, String> {
        let addr = crate::shared::dns::parse_ip(ip)?;
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
    // From: Issue #1683 | PR #1980
    pub(crate) fn reverse_zone(s: &Settings, name: &str) -> Result<Option<String>, String> {
        let zones = crate::shared::dns::private_reverse_zones(s)?;
        Ok(crate::shared::dns::zone_of(name, &zones))
    }

    // What: reverse name of an address and its zone.
    // Why: every PTR change needs both; None: no such zone.
    // From: Issue #1683 | PR #2017
    pub(crate) fn reverse_place(
        s: &Settings,
        ip: &str,
    ) -> Result<Option<(String, String)>, String> {
        let rev = reverse_name(ip)?;
        Ok(reverse_zone(s, &rev)?.map(|zone| (rev, zone)))
    }

    // What: the same, only for a zone this stack serves.
    // Why: a PTR of a secondary goes into own zones only.
    // From: Issue #1683 | PR #2017
    pub(crate) fn served_reverse_place(
        s: &Settings,
        ip: &str,
    ) -> Result<Option<(String, String)>, String> {
        let Some((rev, zone)) = reverse_place(s, ip)? else {
            return Ok(None);
        };
        let served = crate::shared::dns::managed_zones(s)?.contains(&zone);
        Ok(served.then_some((rev, zone)))
    }

    // What: the LAN zone a form names; empty = main.
    // Why: records go only into a configured LAN domain.
    // From: Issue #1683 | PR #2020
    pub(crate) fn chosen_lan_zone(s: &Settings, raw: &str) -> Result<String, Fault> {
        if raw.trim().is_empty() {
            return Ok(crate::shared::dns::lan_zone(s)?);
        }
        let zone = crate::shared::dns::canonical_zone(raw.trim());
        in_lan_domains(&crate::shared::dns::lan_domains(s)?, &zone, raw.trim())?;
        Ok(zone)
    }

    // What: a zone must be one of the LAN domains.
    // Why: one check and one text for LAN domain input.
    // From: Issue #1683 | PR #2020
    fn in_lan_domains(lans: &[String], zone: &str, shown: &str) -> Result<(), Fault> {
        match lans.iter().any(|l| l == zone) {
            true => Ok(()),
            false => Err(Fault::key("err_not_lan_domain", [("x", shown.to_string())])),
        }
    }

    // What: settings that make one domain the main one.
    // Why: a former extra leaves the list; swap keeps both.
    // From: Issue #1683 | PR #2020
    pub(crate) fn main_domain_fields(s: &Settings, main: &str) -> Result<Fields, String> {
        let lans = crate::shared::dns::lan_domains(s)?;
        let want = crate::shared::dns::canonical_zone(main.trim());
        let plain = |z: &String| crate::shared::dns::bare_zone(z).to_string();
        let old = lans.first().cloned().unwrap_or_default();
        let mut extra: Vec<String> = lans
            .iter()
            .skip(1)
            .filter(|z| **z != want)
            .map(plain)
            .collect();
        // What: old main stays as extra only on a swap.
        // Why: a non-extra name renames the main one.
        // From: Issue #1683 | PR #2020
        if want != old && lans.iter().skip(1).any(|z| *z == want) {
            extra.push(plain(&old));
        }
        // What: the new set passes the LAN domain rule.
        // Why: one rule; else lan_domains fails everywhere.
        // From: Issue #1683 | PR #2020
        crate::shared::dns::validate_lan_domains(&plain(&want), &extra)?;
        Ok(Fields::from([
            ("DHCP_DOMAIN".to_string(), plain(&want)),
            (
                "DNS_EXTRA_LAN_DOMAINS".to_string(),
                config::join_items(&extra),
            ),
        ]))
    }

    // What: rrsets of a zone besides SOA, NS and DS.
    // Why: only these are records a person added.
    // From: Issue #1683 | PR #2020
    pub(crate) fn own_rrsets(rows: &[Value]) -> Vec<Value> {
        rows.iter()
            .filter(|r| !matches!(r["type"].as_str(), Some("SOA" | "NS" | "DS")))
            .cloned()
            .collect()
    }

    // What: zones that keep snapshots.
    // Why: LAN zones plus the private reverse zones.
    // From: Issue #1683 | PR #1980
    pub(crate) fn snapshot_zones(s: &Settings) -> Result<Vec<String>, String> {
        let mut zones = crate::shared::dns::lan_domains(s)?;
        zones.extend(crate::shared::dns::private_reverse_zones(s)?);
        Ok(zones)
    }

    // What: snapshot store of one zone.
    // Why: undo a bad change; count from the SOT.
    // From: Issue #1683 | PR #1980
    pub(crate) fn zone_store(
        s: &Settings,
        zone: &str,
    ) -> Result<crate::shared::snapshot::Store, String> {
        let dir = Path::new(&s.text("DNS_SNAPSHOT_DIR")?).join(crate::shared::dns::bare_zone(zone));
        let keep = s.num::<usize>("DNS_SNAPSHOT_KEEP")?;
        let owner = fs::Owner::default();
        Ok(crate::shared::snapshot::Store {
            dir,
            keep,
            owner,
            file: None,
        })
    }

    // What: keep the zone's records after a change.
    // Why: each change can be undone later.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn snapshot(s: &Settings, api: &pdns::Api, zone: &str) -> Result<(), String> {
        let rows = api.rrsets(zone).await?;
        let body = serde_json::to_vec(&rows).map_err(|e| e.to_string())?;
        let store = zone_store(s, zone)?;
        store.save(&body)?;
        Ok(())
    }

    // What: snapshots of all zones, newest first.
    // Why: DNS page and setup.sh show the same list.
    // From: Issue #1683 | PR #1980
    pub(crate) fn snapshot_list(s: &Settings) -> Result<Vec<(String, Vec<Value>)>, String> {
        let mut out = Vec::new();
        for zone in snapshot_zones(s)? {
            let store = zone_store(s, &zone)?;
            out.push((zone, store.rows()?));
        }
        Ok(out)
    }

    // What: {"zones":{zone:[{id,created_unix}]}}.
    // Why: setup.sh reset-config reads this shape.
    // From: Issue #1683 | PR #1980
    pub(crate) fn zone_snapshots(s: &Settings) -> Result<Value, String> {
        let zones: serde_json::Map<String, Value> = snapshot_list(s)?
            .into_iter()
            .map(|(z, rows)| (z, Value::Array(rows)))
            .collect();
        Ok(json!({"zones": zones}))
    }

    // What: put one zone back to a snapshot.
    // Why: PATCH restores; a new snapshot records it.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn rollback(s: &Settings, zone: &str, id: &str) -> Result<(), Fault> {
        if !snapshot_zones(s)?.iter().any(|z| z == zone) {
            return Err(Fault::key(
                "err_zone_no_snapshots",
                [("zone", zone.to_string())],
            ));
        }
        let rows: Vec<Value> = zone_store(s, zone)?.read(id)?;
        Ok(restore_zone(s, zone, &rows).await?)
    }

    // What: write saved rows into a zone, keep, flush.
    // Why: zone and stack rollback restore one way.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn restore_zone(
        s: &Settings,
        zone: &str,
        rows: &[Value],
    ) -> Result<(), String> {
        let api = peer::own_api(s)?;
        api.restore(zone, rows).await?;
        snapshot(s, &api, zone).await?;
        peer::flush_zone(s, zone).await
    }

    // What: TSIG key state; the value never leaves.
    // Why: file and PowerDNS must hold the same key.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn tsig_state(s: &Settings) -> Result<Value, String> {
        let name = s.text("DDNS_TSIG_NAME")?;
        let file = secret::states(s)?["secrets"]
            .as_array()
            .and_then(|rows| rows.iter().find(|r| r["key"] == "DDNS_TSIG_KEY").cloned())
            .unwrap_or(Value::Null);
        let want = secret::tsig_secret(s);
        let pdns = match peer::own_api(s)?.tsigkey(&name).await {
            Ok(Some(k)) => {
                let have = k["key"].as_str().unwrap_or_default();
                let same = want.as_ref().is_ok_and(|w| secret::equal(have, w));
                json!({"present": true, "algorithm": k["algorithm"], "matches": same})
            }
            Ok(None) => json!({"present": false, "matches": false}),
            Err(e) => json!({"error": e}),
        };
        let ok = !file.is_null() && pdns["matches"] == true;
        Ok(
            json!({"name": name, "algorithm": s.text("DDNS_TSIG_ALGORITHM")?,
            "file": file, "pdns": pdns, "ok": ok}),
        )
    }

    // What: LAN domains with records, subnets, PTRs.
    // Why: page, REST and CLI read one listing.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn lan_view(s: &Settings) -> Result<Value, String> {
        let lans = crate::shared::dns::lan_domains(s)?;
        let lan = crate::shared::dns::lan_zone(s)?;
        let mut records: BTreeMap<String, Vec<Value>> = BTreeMap::new();
        let (mut ptr, mut error) = (Vec::new(), None);
        match peer::own_api(s) {
            // What: other zones only if main one answers.
            // Why: unreachable API would time out 20 times.
            // From: Issue #1683 | PR #1980
            Ok(api) => match api.rrsets(&lan).await {
                Ok(rows) => {
                    records.insert(lan.clone(), own_rrsets(&rows));
                    for zone in lans.iter().skip(1) {
                        match api.rrsets(zone).await {
                            Ok(rows) => {
                                records.insert(zone.clone(), own_rrsets(&rows));
                            }
                            Err(e) => error = Some(e),
                        }
                    }
                    match ptr_rows(s, &api).await {
                        Ok(rows) => ptr = rows,
                        Err(e) => error = Some(e),
                    }
                }
                Err(e) => error = Some(e),
            },
            Err(e) => error = Some(e),
        }
        let missing = missing_ptrs(s, &mut records, &ptr);
        let subnets = crate::dhcp::domain_subnets(s).await;
        // What: a domain under a real Internet ending.
        // Why: in the LAN it hides its own Internet names.
        // From: Issue #1683 | PR #2019
        let psl = match render::psl(s) {
            Ok(p) => Some(p),
            Err(e) => {
                error.get_or_insert(e);
                None
            }
        };
        let rows: Vec<Value> = lans
            .iter()
            .enumerate()
            .map(|(i, zone)| {
                let own = records.get(zone).cloned().unwrap_or_default();
                let public = psl
                    .as_ref()
                    .is_some_and(|p| p.is_tld(crate::shared::dns::ending(zone)));
                json!({
                    "name": crate::shared::dns::bare_zone(zone),
                    "main": i == 0,
                    "records": own,
                    "subnets": subnets.get(zone).cloned().unwrap_or_default(),
                    "public": public,
                })
            })
            .collect();
        Ok(json!({"domains": rows, "ptr_zones": ptr, "missing_ptrs": missing, "error": error}))
    }

    // What: PTR rows of each private reverse zone.
    // Why: the DNS page lists them per zone with the host.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn ptr_rows(s: &Settings, api: &pdns::Api) -> Result<Vec<Value>, String> {
        let mut out = Vec::new();
        for zone in crate::shared::dns::private_reverse_zones(s)? {
            let mut rows = Vec::new();
            for r in api.rrsets(&zone).await? {
                if r["type"] != "PTR" {
                    continue;
                }
                let host = r["records"][0]["content"].clone();
                rows.push(json!({"ip": r["name"], "ttl": r["ttl"], "hostname": host}));
            }
            out.push(json!({"zone": zone, "records": rows}));
        }
        Ok(out)
    }

    // What: A and AAAA addresses whose PTR is missing.
    // Why: a host without PTR is not found by address.
    // From: Issue #1683 | PR #2019
    pub(crate) fn missing_ptrs(
        s: &Settings,
        records: &mut BTreeMap<String, Vec<Value>>,
        ptr: &[Value],
    ) -> Vec<Value> {
        let have: Vec<&str> = ptr
            .iter()
            .filter_map(|g| g["records"].as_array())
            .flatten()
            .filter_map(|r| r["ip"].as_str())
            .collect();
        let mut all = Vec::new();
        for rows in records.values_mut() {
            for r in rows.iter_mut() {
                if !matches!(r["type"].as_str(), Some("A" | "AAAA")) {
                    continue;
                }
                let ips: Vec<String> = r["records"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|c| c["content"].as_str())
                    .filter(|ip| {
                        matches!(served_reverse_place(s, ip), Ok(Some((rev, _)))
                        if !have.contains(&rev.as_str()))
                    })
                    .map(str::to_string)
                    .collect();
                for ip in &ips {
                    all.push(json!({"ip": ip, "hostname": r["name"], "ttl": r["ttl"]}));
                }
                r["missing_ptr"] = json!(ips);
            }
        }
        all
    }

    // What: what to do with one LAN domain.
    // Why: typed; no route name decides the change.
    // From: Issue #1683 | PR #2020
    #[derive(Clone, Copy, PartialEq)]
    pub(crate) enum LanDomainEdit {
        Add,
        Remove,
        Main,
    }

    // What: one LAN record set as typed input.
    // Why: no form field names in the dns owner.
    // From: Issue #1683 | PR #2020
    pub(crate) struct RecordInput {
        pub zone: String,
        pub kind: String,
        pub name: String,
        pub contents: Vec<String>,
        pub ttl: u32,
        pub ptr: bool,
    }

    // What: one PTR record as typed input.
    // Why: no form field names in the dns owner.
    // From: Issue #1683 | PR #2020
    pub(crate) struct PtrInput {
        pub ip: String,
        pub hostname: String,
        pub ttl: u32,
    }

    // What: add, remove or promote one LAN domain.
    // Why: each LAN domain is one zone in PowerDNS.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn lan_domain_action(
        app: &Stack,
        s: &Settings,
        edit: LanDomainEdit,
        raw: &str,
    ) -> Result<(), Fault> {
        let zone = crate::shared::dns::canonical_zone(raw.trim());
        let name = crate::shared::dns::bare_zone(&zone).to_string();
        let lans = crate::shared::dns::lan_domains(s)?;
        let before = hosted_now(s)?;
        let change = match edit {
            LanDomainEdit::Add => {
                let mut extra: Vec<String> = lans.iter().skip(1).cloned().collect();
                extra.push(name.clone());
                let main = lans.first().cloned().unwrap_or_default();
                crate::shared::dns::validate_lan_domains(&main, &extra)?;
                list_change(s, "DNS_EXTRA_LAN_DOMAINS", &name, true)?
            }
            LanDomainEdit::Remove => {
                if lans.first() == Some(&zone) {
                    return Err(Fault::key("err_main_domain_remove", [("x", name)]));
                }
                in_lan_domains(&lans, &zone, &name)?;
                // What: a domain with own records stays.
                // Why: removing it drops names from DNS.
                // From: Issue #1683 | PR #2020
                let own = own_rrsets(&peer::own_api(s)?.rrsets(&zone).await?).len();
                if own > 0 {
                    return Err(Fault::key(
                        "err_domain_has_records",
                        [("x", name), ("n", own.to_string())],
                    ));
                }
                list_change(s, "DNS_EXTRA_LAN_DOMAINS", &name, false)?
            }
            LanDomainEdit::Main => {
                in_lan_domains(&lans, &zone, &name)?;
                main_domain_fields(s, &name)?
            }
        };
        Ok(commit_and_prune(app, change, &before).await?)
    }

    // What: full name inside the LAN zone.
    // Why: a short name gets the zone appended.
    // From: Issue #1683 | PR #1980
    pub(crate) fn in_zone(name: &str, zone: &str) -> String {
        // What: only a whole-label suffix counts as inside.
        // Why: "xhome.lan" is not in zone "home.lan".
        // From: Issue #1683 | PR #2020
        let bare = crate::shared::dns::bare_zone(zone);
        let inside = crate::shared::dns::is_within(name, bare);
        if name.ends_with('.') || inside {
            name.to_string()
        } else {
            format!("{name}.{zone}")
        }
    }

    // What: content in the form PowerDNS stores.
    // Why: TXT needs quotes; target names end in a dot.
    // From: Issue #1683 | PR #1980
    pub(crate) fn canonical(kind: &str, c: &str) -> String {
        let dot = pdns::zone_id;
        match kind {
            "TXT" if !c.starts_with('"') => format!("\"{}\"", c.replace('"', "\\\"")),
            "CNAME" => dot(c),
            "MX" | "SRV" => match c.rsplit_once(' ') {
                Some((head, target)) => format!("{head} {}", dot(target)),
                None => c.to_string(),
            },
            // What: a DS digest in small hex letters.
            // Why: pdns and its key list may differ in case
            // From: Issue #1683 | PR #2019
            "DS" => c.to_ascii_lowercase(),
            _ => c.to_string(),
        }
    }

    // What: add or remove one LAN record set.
    // Why: PATCH sets or deletes; NOTIFY follows.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn record(s: &Settings, add: bool, input: &RecordInput) -> Result<(), Fault> {
        let zone = chosen_lan_zone(s, &input.zone)?;
        let kind = input.kind.clone();
        if !s.list("DNS_LAN_RECORD_TYPES")?.contains(&kind) {
            return Err(Fault::key("err_record_type", [("kind", kind)]));
        }
        let name = in_zone(&input.name, &zone);
        let mut contents = Vec::new();
        let mut ttl = 0;
        if add {
            contents = input
                .contents
                .iter()
                .map(|c| c.trim())
                .filter(|c| !c.is_empty())
                .map(|c| canonical(&kind, c))
                .collect();
            ttl = check_ttl(s, input.ttl)?;
        }
        let api = peer::own_api(s)?;
        let host = pdns::zone_id(&name);
        // What: place of each wanted PTR, checked first.
        // Why: no A is saved when its PTR cannot follow.
        // From: Issue #1683 | PR #2019
        let mut places = Vec::new();
        if add && kind == "A" && input.ptr {
            for ip in &contents {
                let Some((rev, rz)) = served_reverse_place(s, ip)? else {
                    return Err(Fault::key("err_ptr_no_zone", [("ip", ip.to_string())]));
                };
                let have = rrset_contents(&api, &rz, &rev, "PTR").await?;
                if let Some(other) = have.iter().find(|h| **h != host) {
                    return Err(Fault::key(
                        "err_ptr_taken",
                        [
                            ("ip", ip.to_string()),
                            ("name", crate::shared::dns::bare_zone(other).to_string()),
                        ],
                    ));
                }
                places.push((rev, rz));
            }
        }
        // What: the addresses name loses with this change.
        // Why: their PTR to this name must not stay behind.
        // From: Issue #1683 | PR #2019
        let mut gone = Vec::new();
        if kind == "A" {
            gone = rrset_contents(&api, &zone, &name, "A").await?;
            gone.retain(|ip| !contents.contains(ip));
        }
        write_rrset(s, &api, &zone, (&name, &kind), ttl, &contents).await?;
        for (rev, rz) in &places {
            let one = std::slice::from_ref(&host);
            write_rrset(s, &api, rz, (rev, "PTR"), ttl, one).await?;
        }
        for ip in &gone {
            let Some((rev, rz)) = served_reverse_place(s, ip)? else {
                continue;
            };
            // What: drop PTR only when it names this host.
            // Why: a PTR to another name: not ours to drop
            // From: Issue #1683 | PR #2019
            if rrset_contents(&api, &rz, &rev, "PTR").await? == [host.clone()] {
                write_rrset(s, &api, &rz, (&rev, "PTR"), 0, &[]).await?;
            }
        }
        Ok(())
    }

    // What: write an rrset, snapshot it, flush caches.
    // Why: every LAN record change ends with these steps.
    // From: Issue #1683 | PR #2020
    async fn write_rrset(
        s: &Settings,
        api: &pdns::Api,
        zone: &str,
        (name, kind): (&str, &str),
        ttl: u32,
        contents: &[String],
    ) -> Result<(), String> {
        api.set_rrset(zone, name, kind, ttl, contents).await?;
        snapshot(s, api, zone).await?;
        peer::flush_zone(s, zone).await
    }

    // What: the contents of one record set; none: empty.
    // Why: PTR checks ask what a name holds right now.
    // From: Issue #1683 | PR #2019
    pub(crate) async fn rrset_contents(
        api: &pdns::Api,
        zone: &str,
        name: &str,
        kind: &str,
    ) -> Result<Vec<String>, String> {
        let rows = api.rrsets(zone).await?;
        Ok(pdns::find_rrset(&rows, name, kind).map_or_else(Vec::new, pdns::record_texts))
    }

    // What: a record TTL within DNS_RECORD_TTL_MAX.
    // Why: LAN and PTR records share the rule.
    // From: Issue #1683 | PR #2019
    pub(crate) fn check_ttl(s: &Settings, ttl: u32) -> Result<u32, Fault> {
        let max = s.uint("DNS_RECORD_TTL_MAX")?;
        if ttl == 0 || u64::from(ttl) > max {
            return Err(Fault::key("err_ttl_range", [("max", max.to_string())]));
        }
        Ok(ttl)
    }

    // What: add or remove one PTR record.
    // Why: name from the IP; zone from the list.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn ptr(s: &Settings, add: bool, input: &PtrInput) -> Result<(), Fault> {
        let ip = input.ip.clone();
        let name = if crate::shared::dns::is_reverse_name(&ip) {
            ip
        } else {
            reverse_name(&ip)?
        };
        let Some(zone) = reverse_zone(s, &name)? else {
            return Err(Fault::key("err_ptr_no_reverse_zone", [("name", name)]));
        };
        let mut ttl = 0;
        let mut contents = Vec::new();
        if add {
            ttl = check_ttl(s, input.ttl)?;
            contents.push(pdns::zone_id(&input.hostname));
        }
        let api = peer::own_api(s)?;
        Ok(write_rrset(s, &api, &zone, (&name, "PTR"), ttl, &contents).await?)
    }

    // What: saves secondaries as name@address rows.
    // Why: one SOT key holds the whole list.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn save_secondaries(
        app: &Stack,
        list: &[(String, String)],
    ) -> Result<(), String> {
        let rows = crate::shared::pdns_conf::secondary_rows(list);
        commit(app, single_field("DNS_SECONDARIES", rows)).await
    }

    // What: checks a secondary name: one label, SOT length.
    // Why: the name becomes a DNS label and file name.
    // From: Issue #1683 | PR #2017
    pub(crate) fn valid_peer_name(s: &Settings, name: &str) -> Result<bool, String> {
        let max = s.num::<usize>("DNS_SECONDARY_NAME_MAX")?;
        let label = !name.contains('.') && crate::shared::dns::is_dns_name(name, false, false);
        Ok(name.len() <= max && label)
    }

    // What: everything a new secondary needs.
    // Why: setup.sh secondary writes it to its env.
    // From: Issue #1683 | PR #1980
    pub(crate) fn peer_kit(s: &Settings) -> Result<Value, String> {
        let primary = s.text("IP_HTTP")?;
        let image = config::image();
        Ok(json!({
            "primary": primary,
            // What: the zones the primary serves.
            // Why: the secondary pulls each one by AXFR.
            // From: Issue #1683 | PR #2020
            "zones": crate::shared::dns::managed_zones(s)?,
            "pdns_api_key": secret::get(s, "PDNS_API_KEY")?,
            "tsig_name": s.text("DDNS_TSIG_NAME")?,
            "tsig_secret": secret::tsig_secret(s)?,
            "syslog_primary": crate::shared::dns::host_port(&primary, s.uint("LANCACHE_LOG_PORT")?),
            "dns_local_reverse_zones": s.text_or_empty("DNS_LOCAL_REVERSE_ZONES"),
            "image_registry": image.registry,
            "image_prefix": image.prefix,
            "image_channel": image.channel,
            "image_tag": image.tag,
        }))
    }

    // What: NS lists with a name in, out or in neither.
    // Why: Some(true) enters, Some(false) takes it out.
    // From: Issue #1683 | PR #2017
    pub(crate) fn ns_change(
        s: &Settings,
        name: &str,
        entered: Option<bool>,
    ) -> Result<Fields, String> {
        let mut form = list_change(s, "DNS_SECONDARY_NS", name, entered == Some(true))?;
        form.extend(list_change(
            s,
            "DNS_SECONDARY_NS_OFF",
            name,
            entered == Some(false),
        )?);
        Ok(form)
    }

    // What: serial of each managed zone on both peers.
    // Why: shows lost NOTIFY or AXFR in any zone (RFC 1982)
    // From: Issue #1683 | PR #1858
    pub(crate) async fn peer_serials(s: &Settings, address: &str) -> Result<Vec<PeerZone>, String> {
        let ours = peer::own_api(s)?.zones().await?;
        let theirs = peer::zones_at(s, address).await?;
        peer::peer_zones(s, &ours, &theirs)
    }

    // What: failed checks of one secondary in a row.
    // Why: NS removal needs time and count both.
    // From: Issue #1683 | PR #2017
    pub(crate) struct Failing {
        since: Instant,
        count: u64,
    }

    // What: check every secondary; again after a wait.
    // Why: the SOT sets a shorter wait while one fails.
    // From: Issue #1683 | PR #2017
    pub(crate) async fn secondary_watch(app: &Stack) {
        let mut failing: BTreeMap<String, Failing> = BTreeMap::new();
        loop {
            let s = app.settings();
            let key = match watch_round(app, &s, &mut failing).await {
                Ok(()) if failing.is_empty() => "DNS_SECONDARY_CHECK_SECONDS",
                Ok(()) => "DNS_SECONDARY_RECHECK_SECONDS",
                // What: own pdns down: no secondary blamed.
                // Why: at ui start the dns may not run yet.
                // From: Issue #1683 | PR #2020
                Err(e) => {
                    eprintln!("ui: secondary check skipped: {e}");
                    "PDNS_SOA_COLD_RETRY"
                }
            };
            let Some(wait) = or_stop("secondary check", s.uint(key)) else {
                return;
            };
            tokio::time::sleep(Duration::from_secs(wait)).await;
        }
    }

    // What: one round over all secondaries.
    // Why: resync a lag, enter or take out NS names.
    // From: Issue #1683 | PR #2017
    pub(crate) async fn watch_round(
        app: &Stack,
        s: &Settings,
        failing: &mut BTreeMap<String, Failing>,
    ) -> Result<(), String> {
        let ours = peer::own_api(s)?.zones().await?;
        let peers = crate::shared::pdns_conf::secondaries(s)?;
        failing.retain(|n, _| peers.iter().any(|(p, _)| p == n));
        let enabled = s.flag("DNS_SECONDARY_NS_ENABLED")?;
        let auto = s.flag("DNS_SECONDARY_NS_AUTO_REMOVE")?;
        let after = Duration::from_secs(s.uint("DNS_SECONDARY_NS_REMOVE_AFTER_SECONDS")?);
        let fails = s.uint("DNS_SECONDARY_NS_REMOVE_FAILS")?;
        let (ns, off) = (s.list("DNS_SECONDARY_NS")?, s.list("DNS_SECONDARY_NS_OFF")?);
        let (mut enter, mut take_out) = (Vec::new(), Vec::new());
        for (name, address) in &peers {
            // What: no aa counts as failure only for an NS.
            // Why: an older secondary syncs but is never NS
            // From: Issue #1683 | PR #2017
            let outcome = match check_peer(s, &ours, address).await {
                Ok(Err(e)) if !ns.contains(name) => {
                    if enabled {
                        eprintln!("ui: secondary {name}: no NS: {e}");
                    }
                    Ok(false)
                }
                Ok(aa) => aa.map(|()| true),
                Err(e) => Err(e),
            };
            match outcome {
                Ok(aa) => {
                    failing.remove(name);
                    // What: first entry; not after take out
                    // Why: re-entry only by hand.
                    // From: Issue #1683 | PR #2020
                    if aa && enabled && !ns.contains(name) && !off.contains(name) {
                        eprintln!("ui: secondary {name}: entered as NS");
                        enter.push(name.clone());
                    }
                }
                Err(e) => {
                    let f = failing.entry(name.clone()).or_insert(Failing {
                        since: Instant::now(),
                        count: 0,
                    });
                    f.count += 1;
                    eprintln!("ui: secondary {name}: check {} failed: {e}", f.count);
                    let due = f.count >= fails && f.since.elapsed() > after;
                    if enabled && auto && due && ns.contains(name) {
                        eprintln!("ui: secondary {name}: NS taken out");
                        take_out.push(name.clone());
                    }
                }
            }
        }
        if enter.is_empty() && take_out.is_empty() {
            return Ok(());
        }
        // What: the round's steps meet the lists of now.
        // Why: a hand change during the round must stay.
        // From: Issue #1683 | PR #2020
        commit_with(app, |now| {
            let (was_ns, was_off) = (
                now.list("DNS_SECONDARY_NS")?,
                now.list("DNS_SECONDARY_NS_OFF")?,
            );
            let (mut ns, mut off) = (was_ns.clone(), was_off.clone());
            for name in &enter {
                if !ns.contains(name) && !off.contains(name) {
                    ns.push(name.clone());
                }
            }
            for name in &take_out {
                if ns.contains(name) {
                    ns.retain(|n| n != name);
                    off.push(name.clone());
                }
            }
            let mut form = Fields::new();
            for (key, was, now) in [
                ("DNS_SECONDARY_NS", was_ns, ns),
                ("DNS_SECONDARY_NS_OFF", was_off, off),
            ] {
                if now != was {
                    form.insert(key.into(), crate::config::join_items(&now));
                }
            }
            Ok::<_, String>(form)
        })
        .await
    }

    // What: one secondary gets our zone list.
    // Why: added or removed domains reach it alone.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn peer_follows(
        s: &Settings,
        api: &pdns::Api,
        address: &str,
    ) -> Result<(), String> {
        let masters = vec![crate::shared::dns::host_port(
            &s.text("IP_HTTP")?,
            s.uint("PDNS_AUTH_PORT")?,
        )];
        let who = format!("ui: secondary {address}");
        let key = s.text("DDNS_TSIG_NAME")?;
        peer::match_zones(api, &hosted_now(s)?, &masters, &key, true, &who).await
    }

    // What: every secondary follows, in the background.
    // Why: a zone change must not wait for the slow check.
    // From: Issue #1683 | PR #2020
    pub(crate) fn peers_follow(s: &Settings) {
        let s = s.clone();
        tokio::spawn(async move {
            let peers = match crate::shared::pdns_conf::secondaries(&s) {
                Ok(list) => list,
                Err(e) => {
                    eprintln!("ui: secondaries unknown: {e}");
                    return;
                }
            };
            for (name, address) in peers {
                let done = match peer::api_at(&s, &address) {
                    Ok(api) => peer_follows(&s, &api, &address).await,
                    Err(e) => Err(e),
                };
                if let Err(e) = done {
                    eprintln!("ui: secondary {name}: zones not matched: {e}");
                }
            }
        });
    }

    // What: serials via pdns-API, lag pulled; aa result.
    // Why: an NS must answer aa; AXFR fixes a lost NOTIFY.
    // From: Issue #1683 | PR #2017
    pub(crate) async fn check_peer(
        s: &Settings,
        ours: &[pdns::Zone],
        address: &str,
    ) -> Result<Result<(), String>, String> {
        let aa = answers_aa(s, address, &crate::shared::dns::lan_zone(s)?).await;
        let api = peer::api_at(s, address)?;
        peer_follows(s, &api, address).await?;
        let theirs = api.zones().await?;
        for z in peer::peer_zones(s, ours, &theirs)? {
            let state = peer::zone_state(&z);
            let word = state.word();
            // What: ahead: our serial passes theirs first.
            // Why: restore sets ours back; AXFR skips lower
            // From: Issue #1683 | PR #2017
            if let (ZoneState::Ahead, Some(theirs)) = (state, z.secondary)
                && let Err(e) = raise_serial(s, &z.zone, theirs).await
            {
                eprintln!("ui: secondary {address}: {} ahead, raise: {e}", z.zone);
                continue;
            }
            // What: pull ahead/unknown/behind; skip missing
            // Why: a missing zone has no copy to refresh.
            // From: Issue #1683 | PR #2020
            if matches!(
                state,
                ZoneState::Ahead | ZoneState::Unknown | ZoneState::Behind
            ) {
                match api.axfr_retrieve(&z.zone).await {
                    Ok(()) => eprintln!("ui: secondary {address}: {} {word}, AXFR asked", z.zone),
                    Err(e) => eprintln!("ui: secondary {address}: {} {word}, AXFR: {e}", z.zone),
                }
            }
        }
        Ok(aa)
    }

    // What: worst state over all zones, each in detail
    // Why: in sync only when every managed zone matches.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn secondary_health(s: &Settings, address: &str) -> Value {
        let zones = match peer_serials(s, address).await {
            Ok(z) => z,
            Err(e) => return json!({"status": "unreachable", "detail": e}),
        };
        let worst = peer::worst_state(&zones);
        let mut lines = Vec::new();
        for z in &zones {
            let state = peer::zone_state(z).word();
            let show = |v: Option<u32>| v.map_or_else(|| "-".to_string(), |n| n.to_string());
            lines.push(format!(
                "{}: {} (primary {}, secondary {})",
                z.zone,
                state,
                show(z.primary),
                show(z.secondary)
            ));
        }
        json!({"status": worst.word(), "zones": zones.len(), "detail": lines.join("\n")})
    }

    // What: flush recursor caches when a serial moves.
    // Why: UI, DDNS, AXFR and rollback all bump it.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn flush_on_transfer(app: &Stack) {
        let mut seen = peer::Flushed::default();
        // What: an error only after the grace time.
        // Why: a planned dns restart must log nothing.
        // From: Issue #1683 | PR #1980
        let mut down: Option<Instant> = None;
        let mut logged = false;
        loop {
            let s = app.settings();
            let Some(wait) = or_stop("cache flush", s.uint("UI_FLUSH_CHECK_SECONDS")) else {
                return;
            };
            let Some(grace) = or_stop("cache flush", s.uint("UI_FLUSH_GRACE_SECONDS")) else {
                return;
            };
            match flush_round(&s, &mut seen).await {
                Err(e) => {
                    let since = *down.get_or_insert_with(Instant::now);
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

    // What: clears recursor cache for changed zones.
    // Why: recursors would serve old answers until TTL.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn flush_round(s: &Settings, seen: &mut peer::Flushed) -> Result<(), String> {
        let api = peer::own_api(s)?;
        let peers = !crate::shared::pdns_conf::secondaries(s)?.is_empty();
        let zones = serial_map(api.zones().await?);
        for (zone, serial) in seen.due(&zones) {
            peer::flush_zone(s, &zone).await?;
            // What: NOTIFY to the secondaries right away.
            // Why: pdns alone notifies after up to 60 s.
            // From: Issue #1683 | PR #2019
            if peers {
                api.notify(&zone).await?;
            }
            seen.done(&zone, serial);
        }
        Ok(())
    }

    // What: the live chain; on error NTA everywhere.
    // Why: no proof must never mean SERVFAIL.
    // From: Issue #1683 | PR #2019
    pub(crate) async fn dnssec_chain(s: &Settings) -> recursor_conf::Chain {
        match fetch_chain(s).await {
            Ok(c) => c,
            Err(e) => {
                eprintln!("ui: DNSSEC anchors off: {e}");
                recursor_conf::Chain::default()
            }
        }
    }

    // What: SETUP_DNS_PROBE_NAME A on the loopback.
    // Why: the probe uses the stack's own DNS client.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn healthcheck(s: &Settings) -> Result<(), String> {
        let target = format!("{}#{}", s.text("LOOPBACK_BIND_IP")?, s.uint("DNS_PORT")?);
        let name = s.text("SETUP_DNS_PROBE_NAME")?;
        query(s, &name, "A", &target).await.map(drop)
    }

    // What: one DNS question to a stack server.
    // Why: shows what auth, recursor or dnsdist say.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn query(
        s: &Settings,
        name: &str,
        rtype: &str,
        target: &str,
    ) -> Result<Value, String> {
        let qtype = crate::shared::dns::qtype(rtype)?;
        let (addr, rd, wait) = target_addr(s, target)?;
        let (n, ty) = (name.to_string(), qtype);
        let r =
            tokio::task::spawn_blocking(move || crate::shared::dns::ask(addr, &n, ty, rd, wait))
                .await
                .map_err(|e| e.to_string())??;
        Ok(json!({"server": addr.to_string(), "name": name, "type": rtype, "rd": rd, "reply": r}))
    }

    // What: one SOA question without RD to a target.
    // Why: shows the serial one server holds for a zone.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn soa_probe(s: &Settings, zone: &str, target: &str) -> Result<Value, String> {
        let (addr, _, wait) = target_addr(s, target)?;
        let soa = crate::shared::dns::soa_at(addr, zone, wait).await?;
        Ok(json!({"server": addr.to_string(), "zone": zone, "soa": soa,
            "serves_zone": soa.serves_zone()}))
    }

    // What: address, RD flag and wait of a target word.
    // Why: query and soa-probe name servers one way.
    // From: Issue #1683 | PR #2020
    fn target_addr(s: &Settings, target: &str) -> Result<(SocketAddr, bool, Duration), String> {
        let port = s.num::<u16>("DNS_PORT")?;
        // What: http, https, auth or ip[:port], [v6]:port.
        // Why: the SOT names each server; auth gets no RD.
        // From: Issue #1683 | PR #2020
        let (host, port, rd) = match target {
            "http" => (s.text("IP_HTTP")?, port, true),
            "https" => {
                let ip = crate::shared::dns::https_ip(s)?;
                (ip.ok_or("HTTPS has no IP of its own")?, port, true)
            }
            "auth" => (
                s.text("PDNS_AUTH_ADDRESS")?,
                s.num::<u16>("PDNS_AUTH_PORT")?,
                false,
            ),
            other => {
                let (ip, p) = crate::shared::dns::parse_endpoint(other, false)?;
                (ip, p.unwrap_or(port), true)
            }
        };
        let addr = SocketAddr::new(crate::shared::dns::parse_ip(&host)?, port);
        let wait = Duration::from_secs(s.uint("DNS_QUERY_WAIT_SECONDS")?);
        Ok((addr, rd, wait))
    }

    // What: anchors, proven zones and NTAs as JSON.
    // Why: shows why a zone is or is not validated.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn dnssec_status(s: &Settings) -> Result<Value, String> {
        let chain = fetch_chain(s).await?;
        let nta = recursor_conf::nta_zones(s, &chain)?;
        let anchors: Vec<Value> = chain
            .anchors
            .iter()
            .map(|(zone, ds)| json!({"zone": zone, "ds": ds}))
            .collect();
        Ok(json!({"anchors": anchors, "secured": chain.secured, "nta": nta}))
    }

    // What: anchors of top zones; zones chained to them.
    // Why: a zone loses its NTA only on a proven chain.
    // From: Issue #1683 | PR #2019
    pub(crate) async fn fetch_chain(s: &Settings) -> Result<recursor_conf::Chain, String> {
        let mut chain = recursor_conf::Chain::default();
        if Role::from_settings(s)? != Role::Primary {
            return Ok(chain);
        }
        let tops = own_tops(s)?;
        if tops.is_empty() {
            return Ok(chain);
        }
        let api = peer::own_api(s)?;
        for top in &tops {
            let ds = ds_or_none(&api, top).await;
            if !ds.is_empty() {
                chain.secured.push(top.clone());
            }
            chain.anchors.push((top.clone(), ds));
        }
        let norm = |rows: Vec<String>| {
            let mut v: Vec<String> = rows.iter().map(|r| canonical("DS", r)).collect();
            v.sort();
            v
        };
        for (zone, parent) in own_links(s, &tops)? {
            let Some(parent) = parent else {
                continue;
            };
            if !chain.secured.contains(&parent) {
                continue;
            }
            let want = norm(ds_or_none(&api, &zone).await);
            let have = norm(rrset_contents(&api, &parent, &zone, "DS").await?);
            if !want.is_empty() && want == have {
                chain.secured.push(zone);
            }
        }
        Ok(chain)
    }

    // What: Ok when the address answers zone with aa.
    // Why: only an authoritative secondary may be an NS.
    // From: Issue #1683 | PR #2017
    pub(crate) async fn answers_aa(s: &Settings, address: &str, zone: &str) -> Result<(), String> {
        let soa = peer::soa_on_dns_port(s, address, zone).await?;
        if soa.serves_zone() {
            return Ok(());
        }
        Err(format!(
            "{address} answers {zone} with rcode {} and aa {}",
            soa.rcode, soa.authoritative
        ))
    }

    // What: create missing primary zones; set DDNS meta.
    // Why: no other step creates the zones in pdns.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn ensure_primary_zones(s: &Settings, key: &str) -> Result<(), String> {
        let api = peer::own_api(s)?;
        let have = zone_names(&api).await?;
        let edit = vec![s.text("PDNS_SOA_EDIT")?];
        let signed = if s.flag("DDNS_ALLOW_UNSIGNED")? {
            Vec::new()
        } else {
            vec![s.text("DDNS_TSIG_NAME")?]
        };
        let tops = own_tops(s)?;
        let hosted = hosted_zones(s, &tops)?;
        // What: cache domain edits, for the secondaries.
        // Why: each follow round of a secondary reads them.
        // From: Issue #1683 | PR #2020
        let cdn = peer::cdn_meta(
            &s.list("CDN_CUSTOM_DOMAINS")?,
            &s.list("CDN_DISABLED_DOMAINS")?,
        );
        for zone in &hosted {
            let id = pdns::zone_id(zone);
            if !have.contains(&id) {
                api.create_primary(&id, &edit[0], key).await?;
            }
            api.set_metadata(&id, "SOA-EDIT-DNSUPDATE", &edit).await?;
            api.set_metadata(&id, "NOTIFY-DNSUPDATE", &["1".to_string()])
                .await?;
            api.set_metadata(&id, "TSIG-ALLOW-DNSUPDATE", &signed)
                .await?;
            api.set_metadata(&id, peer::CDN_META, &cdn).await?;
        }
        for lan in crate::shared::dns::lan_domains(s)? {
            merge_legacy_zone(s, &api, &have, &lan).await?;
        }
        ensure_own_endings(s, &api, &tops).await?;
        ensure_soa_nameserver(s, &api, &hosted).await
    }

    // What: top zones of own endings; no PSL, none.
    // Why: an ending we cannot check may be public.
    // From: Issue #1683 | PR #2019
    pub(crate) fn own_tops(s: &Settings) -> Result<Vec<String>, String> {
        match render::psl(s) {
            Ok(psl) => crate::shared::dns::top_zones(s, &psl),
            Err(e) => {
                eprintln!("ui: no own top zones: {e}");
                Ok(Vec::new())
            }
        }
    }

    // What: the hosted zones with the tops read now.
    // Why: delete_old_zones compares before and after.
    // From: Issue #1683 | PR #2019
    pub(crate) fn hosted_now(s: &Settings) -> Result<Vec<String>, String> {
        hosted_zones(s, &own_tops(s)?)
    }

    // What: zones the primary keeps: managed plus tops.
    // Why: one list creates zones, NS and SOA names.
    // From: Issue #1683 | PR #2019
    pub(crate) fn hosted_zones(s: &Settings, tops: &[String]) -> Result<Vec<String>, String> {
        let mut zones = crate::shared::dns::managed_zones(s)?;
        for top in tops {
            config::add_once(&mut zones, top);
        }
        Ok(zones)
    }

    // What: the DS rows of a zone; none if unreadable.
    // Why: no DS: unchecked; wrong DS: SERVFAIL; logged.
    // From: Issue #1683 | PR #2019
    async fn ds_or_none(api: &pdns::Api, zone: &str) -> Vec<String> {
        api.ds(zone).await.unwrap_or_else(|e| {
            eprintln!("ui: no DS for {zone}: {e}");
            Vec::new()
        })
    }

    // What: LAN zones of own endings and their parent.
    // Why: signing and the resolver chain walk one list.
    // From: Issue #1683 | PR #2019
    pub(crate) fn own_links(
        s: &Settings,
        tops: &[String],
    ) -> Result<Vec<(String, Option<String>)>, String> {
        use crate::shared::dns::{is_within, parent_zone};
        let mut signed: Vec<String> = crate::shared::dns::lan_domains(s)?
            .into_iter()
            .filter(|z| tops.iter().any(|t| is_within(z, t)))
            .collect();
        // What: parents before their children.
        // Why: a chain holds only if all links above hold.
        // From: Issue #1683 | PR #2019
        signed.sort_by_key(|z| z.matches('.').count());
        let mut parents = tops.to_vec();
        parents.extend(signed.iter().cloned());
        Ok(signed
            .into_iter()
            .map(|z| {
                let p = parent_zone(&z, &parents);
                (z, p)
            })
            .collect())
    }

    // What: sign own endings; parents hold NS and DS.
    // Why: .lan and .local validate only along a chain.
    // From: Issue #1683 | PR #2019
    pub(crate) async fn ensure_own_endings(
        s: &Settings,
        api: &pdns::Api,
        tops: &[String],
    ) -> Result<(), String> {
        let ns = ns_names(s, &soa_names(s)?.0)?;
        let ttl = s.num::<u32>("DNS_RECORD_TTL")?;
        for top in tops {
            api.secure(top).await?;
        }
        let mut wanted: Vec<(String, String)> = Vec::new();
        for (zone, parent) in own_links(s, tops)? {
            let zone = &zone;
            api.secure(zone).await?;
            let Some(parent) = parent else {
                continue;
            };
            ensure_rrset(api, &parent, zone, "NS", ttl, &ns).await?;
            let ds = ds_or_none(api, zone).await;
            ensure_rrset(api, &parent, zone, "DS", ttl, &ds).await?;
            wanted.push((parent, zone.clone()));
        }
        // What: drop delegations of gone zones in top zones
        // Why: a top zone is ours; LAN zone keeps all rows.
        // From: Issue #1683 | PR #2019
        for top in tops {
            for r in api.rrsets(top).await? {
                let (Some(name), Some(kind)) = (r["name"].as_str(), r["type"].as_str()) else {
                    continue;
                };
                let child = (top.clone(), name.to_string());
                if name != top && matches!(kind, "NS" | "DS") && !wanted.contains(&child) {
                    api.set_rrset(top, name, kind, ttl, &[]).await?;
                }
            }
        }
        Ok(())
    }

    // What: moves local.<domain> records into <domain>.
    // Why: an old install still holds this extra zone.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn merge_legacy_zone(
        s: &Settings,
        api: &pdns::Api,
        have: &[String],
        lan: &str,
    ) -> Result<(), String> {
        let legacy = crate::shared::dns::legacy_local_zone(lan);
        let id = pdns::zone_id(&legacy);
        // What: a LAN domain named local.<x> is kept.
        // Why: then it is a configured zone, not legacy.
        // From: Issue #1683 | PR #2020
        if !have.contains(&id) || crate::shared::dns::lan_domains(s)?.contains(&legacy) {
            return Ok(());
        }
        let moved = own_rrsets(&api.rrsets(&legacy).await?);
        let key = |r: &Value| (r["name"].to_string(), r["type"].to_string());
        let parent = own_rrsets(&api.rrsets(lan).await?);
        // What: a clash keeps both zones and logs it.
        // Why: a record must never be overwritten silently.
        // From: Issue #1683 | PR #2020
        if let Some(r) = moved
            .iter()
            .find(|r| parent.iter().any(|p| key(p) == key(r)))
        {
            eprintln!(
                "ui: zone {legacy} kept: {} {} also in {lan}",
                r["name"], r["type"]
            );
            return Ok(());
        }
        if !moved.is_empty() {
            snapshot(s, api, &legacy).await?;
            snapshot(s, api, lan).await?;
            let mut saved = api.rrsets(lan).await?;
            saved.extend(moved.iter().cloned());
            api.restore(lan, &saved).await?;
            snapshot(s, api, lan).await?;
        }
        api.delete_zone(&legacy).await?;
        peer::flush_zone(s, lan).await?;
        eprintln!(
            "ui: zone {legacy} merged into {lan} ({} rrsets)",
            moved.len()
        );
        Ok(())
    }

    // What: NS and A record for the SOA's nameserver.
    // Why: the SOA nameserver needs a record of its name.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn ensure_soa_nameserver(
        s: &Settings,
        api: &pdns::Api,
        hosted: &[String],
    ) -> Result<(), String> {
        let names = soa_names(s)?;
        let mname = names.0.clone();
        let lan = crate::shared::dns::lan_zone(s)?;
        let ttl = s.num::<u32>("DNS_RECORD_TTL")?;
        let ns = ns_names(s, &mname)?;
        for zone in hosted {
            ensure_rrset(api, zone, zone, "NS", ttl, &ns).await?;
            ensure_soa_names(api, zone, &names).await?;
        }
        // What: A or AAAA and PTR of each secondary.
        // Why: an NS name needs address; logs show names.
        // From: Issue #1683 | PR #2017
        for (name, address) in crate::shared::pdns_conf::secondaries(s)? {
            let host = peer_host(s, &name)?;
            let kind = crate::shared::dns::address_kind(&address);
            ensure_rrset(api, &lan, &host, kind, ttl, std::slice::from_ref(&address)).await?;
            ensure_ptr(s, api, &address, &host, ttl).await?;
        }
        // What: A and PTR only when ns1 is in the LAN zone.
        // Why: a foreign name has no home in managed zone.
        // From: Issue #1683 | PR #2017
        if crate::shared::dns::is_below(&mname, &lan) {
            let ip = s.text("IP_HTTP")?;
            ensure_rrset(api, &lan, &mname, "A", ttl, std::slice::from_ref(&ip)).await?;
            ensure_ptr(s, api, &ip, &mname, ttl).await?;
        }
        // What: ns2 for the HTTPS IP: A and PTR, never NS.
        // Why: HTTPS is optional; another resolver answers.
        // From: Issue #1683 | PR #2017
        let https = crate::shared::dns::https_ip(s)?.unwrap_or_default();
        let ns2 = crate::shared::dns::canonical_zone(&s.text("DNS_NS_HTTPS_NAME")?);
        if !https.is_empty() && crate::shared::dns::is_below(&ns2, &lan) {
            ensure_rrset(api, &lan, &ns2, "A", ttl, std::slice::from_ref(&https)).await?;
            ensure_ptr(s, api, &https, &ns2, ttl).await?;
        }
        Ok(())
    }

    // What: NS names: ns1, then entered secondaries.
    // Why: a secondary is NS only with the switch on.
    // From: Issue #1683 | PR #2017
    pub(crate) fn ns_names(s: &Settings, mname: &str) -> Result<Vec<String>, String> {
        let mut ns = vec![mname.to_string()];
        if !s.flag("DNS_SECONDARY_NS_ENABLED")? {
            return Ok(ns);
        }
        let entered = s.list("DNS_SECONDARY_NS")?;
        for (name, _) in crate::shared::pdns_conf::secondaries(s)? {
            if entered.contains(&name) {
                ns.push(peer_host(s, &name)?);
            }
        }
        Ok(ns)
    }

    // What: LAN name of a secondary, with trailing dot.
    // Why: A, PTR and NS records use the same name.
    // From: Issue #1683 | PR #2017
    pub(crate) fn peer_host(s: &Settings, name: &str) -> Result<String, String> {
        Ok(format!("{name}.{}", crate::shared::dns::lan_zone(s)?))
    }

    // What: drop address and PTR records of a secondary.
    // Why: a removed or moved secondary leaves no record.
    // From: Issue #1683 | PR #2017
    pub(crate) async fn delete_peer_records(
        s: &Settings,
        name: &str,
        address: &str,
    ) -> Result<(), String> {
        let api = peer::own_api(s)?;
        let host = peer_host(s, name)?;
        let kind = crate::shared::dns::address_kind(address);
        api.set_rrset(&crate::shared::dns::lan_zone(s)?, &host, kind, 0, &[])
            .await?;
        let Some((rev, zone)) = served_reverse_place(s, address)? else {
            return Ok(());
        };
        // What: delete PTR only when it names this host.
        // Why: an own PTR of the admin must stay.
        // From: Issue #1683 | PR #2020
        let ours = rrset_contents(&api, &zone, &rev, "PTR")
            .await?
            .contains(&host);
        if ours {
            api.set_rrset(&zone, &rev, "PTR", 0, &[]).await?;
        }
        Ok(())
    }

    // What: PTR of an address in its managed reverse zone.
    // Why: a reverse zone the stack does not serve is left.
    // From: Issue #1683 | PR #2017
    pub(crate) async fn ensure_ptr(
        s: &Settings,
        api: &pdns::Api,
        ip: &str,
        host: &str,
        ttl: u32,
    ) -> Result<(), String> {
        let Some((rev, zone)) = served_reverse_place(s, ip)? else {
            return Ok(());
        };
        ensure_rrset(api, &zone, &rev, "PTR", ttl, &[host.to_string()]).await
    }

    // What: writes the fields of a SOA back to its zone.
    // Why: every SOA edit ends with the same record write.
    // From: Issue #1683 | PR #2017
    pub(crate) async fn write_soa(
        api: &pdns::Api,
        zone: &str,
        ttl: u32,
        fields: &[String],
    ) -> Result<(), String> {
        api.set_rrset(zone, zone, "SOA", ttl, &[fields.join(" ")])
            .await
    }

    // What: the names of the zones a server holds.
    // Why: both zone setups skip a zone that exists.
    // From: Issue #1683 | PR #2017
    pub(crate) async fn zone_names(api: &pdns::Api) -> Result<Vec<String>, String> {
        Ok(api.zones().await?.into_iter().map(|z| z.name).collect())
    }

    // What: mname and rname of PDNS_DEFAULT_SOA.
    // Why: NS rows and SOA fields read one parse.
    // From: Issue #1683 | PR #2019
    pub(crate) fn soa_names(s: &Settings) -> Result<(String, String), String> {
        let soa = s.text("PDNS_DEFAULT_SOA")?;
        let mut names = soa
            .split_whitespace()
            .map(crate::shared::dns::canonical_zone);
        let (Some(mname), Some(rname)) = (names.next(), names.next()) else {
            return Err(format!("PDNS_DEFAULT_SOA {soa:?} names no mname and rname"));
        };
        Ok((mname, rname))
    }

    // What: SOA mname and rname from PDNS_DEFAULT_SOA.
    // Why: an existing zone keeps the ns1 it was made with.
    // From: Issue #1683 | PR #2017
    pub(crate) async fn ensure_soa_names(
        api: &pdns::Api,
        zone: &str,
        names: &(String, String),
    ) -> Result<(), String> {
        let (mname, rname) = names;
        let Some((ttl, mut f)) = soa_fields(api, zone).await? else {
            return Ok(());
        };
        if &f[0] == mname && &f[1] == rname {
            return Ok(());
        }
        f[0] = mname.clone();
        f[1] = rname.clone();
        write_soa(api, zone, ttl, &f).await
    }

    // What: our SOA serial set past a secondary's.
    // Why: a restore sets it back; AXFR wants a higher one.
    // From: Issue #1683 | PR #2017
    pub(crate) async fn raise_serial(s: &Settings, zone: &str, past: u32) -> Result<(), String> {
        let api = peer::own_api(s)?;
        let Some((ttl, mut f)) = soa_fields(&api, zone).await? else {
            return Err(format!("{zone} has no SOA"));
        };
        f[2] = past.wrapping_add(1).to_string();
        write_soa(&api, zone, ttl, &f).await
    }

    // What: ttl and the seven fields of a zone's SOA.
    // Why: name sync and serial lift edit one record.
    // From: Issue #1683 | PR #2017
    pub(crate) async fn soa_fields(
        api: &pdns::Api,
        zone: &str,
    ) -> Result<Option<(u32, Vec<String>)>, String> {
        let rrsets = api.rrsets(zone).await?;
        let Some(r) = pdns::find_rrset(&rrsets, zone, "SOA") else {
            return Ok(None);
        };
        let have = r["records"][0]["content"].as_str().unwrap_or_default();
        let f: Vec<String> = have.split_whitespace().map(str::to_string).collect();
        if f.len() != 7 {
            return Err(format!("SOA of {zone} is not 7 fields: {have:?}"));
        }
        let ttl = r["ttl"]
            .as_u64()
            .and_then(|t| u32::try_from(t).ok())
            .ok_or_else(|| format!("SOA of {zone} has no ttl"))?;
        Ok(Some((ttl, f)))
    }

    // What: writes one rrset only when it differs.
    // Why: an equal PATCH would still raise the serial.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn ensure_rrset(
        api: &pdns::Api,
        zone: &str,
        name: &str,
        kind: &str,
        ttl: u32,
        want: &[String],
    ) -> Result<(), String> {
        let rows = api.rrsets(zone).await?;
        let same = match pdns::find_rrset(&rows, name, kind) {
            // What: an absent rrset that should be absent.
            // Why: a DELETE of nothing still raises serial.
            // From: Issue #1683 | PR #2019
            None => want.is_empty(),
            Some(r) => {
                let have = pdns::record_texts(r);
                r["ttl"] == ttl && have.len() == want.len() && want.iter().all(|w| have.contains(w))
            }
        };
        if same {
            return Ok(());
        }
        api.set_rrset(zone, name, kind, ttl, want).await
    }

    // What: TSIG key, zones, then binding; one error line.
    // Why: the key is known, so no zone exists without it.
    // From: Issue #1683 | PR #2017
    pub(crate) async fn ensure_zones(s: &Settings) -> Result<(), String> {
        let key = peer::ensure_tsigkey(s)
            .await
            .map_err(|e| format!("tsig: {e}"))?;
        if Role::from_settings(s)? == Role::Secondary {
            peer::ensure_secondary_zones(s, &key)
                .await
                .map_err(|e| format!("secondary zones: {e}"))?;
        } else {
            ensure_primary_zones(s, &key)
                .await
                .map_err(|e| format!("primary zones: {e}"))?;
            peers_follow(s);
        }
        peer::ensure_tsig(s, &key)
            .await
            .map_err(|e| format!("tsig: {e}"))
    }

    // What: replace the TSIG secret and apply.
    // Why: shuts out a removed or leaked secondary.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn rotate_tsig(app: &Stack) -> Result<(), String> {
        let s = app.settings();
        let file = secret::tsig_file(&s)?;
        fs::delete_if_present(&file).map_err(|e| format!("{}: {e}", file.display()))?;
        secret::load_or_create(&file, secret::new_tsig, fs::Owner::default())
            .map_err(|e| format!("DDNS_TSIG_KEY: {e}"))?;
        for line in apply_all(app, &s, &s, true).await? {
            eprintln!("ui: tsig rotate: {line}");
        }
        Ok(())
    }
}

// What: building blocks the lancache-ng roles share.
// Why: one owner per behaviour for every role.
// From: Issue #1683 | PR #2020
mod shared {
    // What: code of the built-in, fallback language.
    // Why: the ui fills gaps with it; the CLI asks it.
    // From: Issue #1683 | PR #2020
    pub const FALLBACK_LANG: &str = "en";

    // What: an error as a text key and values, no language.
    // Why: the ui picks the language at its border.
    // From: Issue #1683 | PR #2020
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub(crate) enum Fault {
        Plain(String),
        Key(&'static str, Vec<(&'static str, String)>),
        Lead(String, Box<Fault>),
    }

    // What: {name} places of a text filled with values.
    // Why: one filler for errors and alarm texts.
    // From: Issue #1683 | PR #2020
    pub(crate) fn fill<K: AsRef<str>>(text: String, vals: &[(K, String)]) -> String {
        vals.iter().fold(text, |text, (name, value)| {
            text.replace(&format!("{{{}}}", name.as_ref()), value)
        })
    }

    // What: methods of the failure Fault.
    // Why: a key and values build one failure.
    // From: Issue #1683 | PR #2020
    impl Fault {
        // What: a failure with a language text and values.
        // Why: the text has {name} places the values fill.
        // From: Issue #1683 | PR #2020
        pub(crate) fn key(
            key: &'static str,
            vals: impl IntoIterator<Item = (&'static str, String)>,
        ) -> Self {
            Self::Key(key, vals.into_iter().collect())
        }

        // What: a failure behind a line start.
        // Why: report lines name the owner, then the cause.
        // From: Issue #1683 | PR #2020
        pub(crate) fn lead(lead: String, cause: Fault) -> Self {
            Self::Lead(lead, Box::new(cause))
        }
    }

    // What: a text error becomes a plain failure.
    // Why: ? keeps working on the String errors.
    // From: Issue #1683 | PR #2020
    impl From<String> for Fault {
        // What: a String as a plain Fault.
        // Why: ? works on the text errors.
        // From: Issue #1683 | PR #2020
        fn from(text: String) -> Self {
            Self::Plain(text)
        }
    }

    // What: a text slice becomes a plain failure.
    // Why: ok_or("text")? works in these functions.
    // From: Issue #1683 | PR #2020
    impl From<&str> for Fault {
        // What: a str as a plain Fault.
        // Why: ok_or("text")? works in these functions.
        // From: Issue #1683 | PR #2020
        fn from(text: &str) -> Self {
            Self::Plain(text.to_string())
        }
    }

    // What: logs and tests show the key and the values.
    // Why: only the ui knows the language texts.
    // From: Issue #1683 | PR #2020
    impl std::fmt::Display for Fault {
        // What: the text of a Fault.
        // Why: logs show the key and the values.
        // From: Issue #1683 | PR #2020
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            match self {
                Self::Plain(text) => f.write_str(text),
                Self::Key(key, vals) => {
                    f.write_str(key)?;
                    vals.iter().try_for_each(|(k, v)| write!(f, " {k}={v}"))
                }
                Self::Lead(lead, cause) => write!(f, "{lead}{cause}"),
            }
        }
    }

    // What: command tables: one row per command word.
    // Why: help, errors and the choice read one table.
    // From: Issue #1683 | PR #2020
    pub mod cli {
        // What: name and value of a NAME=VALUE argument.
        // Why: the CLI forms read their pairs one way.
        // From: Issue #1683 | PR #2020
        pub fn pair<'a>(arg: &'a str, shape: &str) -> Result<(&'a str, &'a str), String> {
            arg.split_once('=')
                .ok_or_else(|| format!("{arg}: needs {shape}"))
        }

        // What: the words of a table with a separator.
        // Why: the help names what the table can run.
        // From: Issue #1683 | PR #2020
        pub fn joined<T>(table: &[(&'static str, T)], sep: &str) -> String {
            let words: Vec<&str> = table.iter().map(|(word, _)| *word).collect();
            words.join(sep)
        }

        // What: the words of a table, blank separated.
        // Why: the help and the errors name one set.
        // From: Issue #1683 | PR #2020
        pub fn names<T>(table: &[(&'static str, T)]) -> String {
            joined(table, " ")
        }

        // What: the row of a word.
        // Why: the match runs the row, not a second word.
        // From: Issue #1683 | PR #2020
        pub fn pick<T: Copy>(table: &[(&'static str, T)], word: &str) -> Option<T> {
            table.iter().find(|(w, _)| *w == word).map(|(_, row)| *row)
        }

        // What: the word of an action.
        // Why: a message names the command the table ran.
        // From: Issue #1683 | PR #2020
        pub fn word<T: PartialEq>(table: &[(&'static str, Entry<T>)], op: T) -> &'static str {
            table
                .iter()
                .find(|(_, r)| r.op == op)
                .map_or("", |(w, _)| *w)
        }

        // What: a command row: action and help form.
        // Why: help shows arguments; match runs the action.
        // From: Issue #1683 | PR #2020
        #[derive(Clone, Copy)]
        pub struct Entry<T> {
            pub op: T,
            pub form: &'static str,
        }

        // What: a command row from its action and its form.
        // Why: tables read one row per line.
        // From: Issue #1683 | PR #2020
        pub const fn row<T>(op: T, form: &'static str) -> Entry<T> {
            Entry { op, form }
        }

        // What: the action of the first word of a command.
        // Why: the match runs the row; none = unknown.
        // From: Issue #1683 | PR #2020
        pub fn op_of<T: Copy>(
            table: &[(&'static str, Entry<T>)],
            word: Option<&String>,
        ) -> Option<T> {
            pick(table, word?).map(|row| row.op)
        }

        // What: the forms of a table with a separator.
        // Why: help shows each command with its arguments.
        // From: Issue #1683 | PR #2020
        pub fn forms<T>(table: &[(&'static str, Entry<T>)], sep: &str) -> String {
            let shown: Vec<&str> = table
                .iter()
                .map(|(_, row)| row.form)
                .filter(|form| !form.is_empty())
                .collect();
            shown.join(sep)
        }

        // What: the help line: every form of a table.
        // Why: help and unknown words say it one way.
        // From: Issue #1683 | PR #2020
        pub fn help<T>(table: &[(&'static str, Entry<T>)]) -> String {
            format!("commands: {}", forms(table, " | "))
        }

        // What: the usage line of one command.
        // Why: wrong arguments show the table form.
        // From: Issue #1683 | PR #2020
        pub fn usage<T>(table: &[(&'static str, Entry<T>)], is: impl Fn(&T) -> bool) -> String {
            let form = table
                .iter()
                .find(|(_, r)| is(&r.op))
                .map_or("", |(_, r)| r.form);
            format!("usage: {form}")
        }
    }

    // What: wall-clock time since the Unix epoch.
    // Why: file names, ids and logs need a plain number.
    // From: Issue #1683 | PR #1980
    pub mod clock {
        use std::time::{SystemTime, UNIX_EPOCH};

        // What: nanoseconds since 1970; 0 if clock is off.
        // Why: a clock before 1970 must not panic.
        // From: Issue #1683 | PR #1980
        pub fn unix_nanos() -> u128 {
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_or(0, |d| d.as_nanos())
        }

        // What: seconds since 1970 of a time, if after.
        // Why: now and file times become seconds one way.
        // From: Issue #1683 | PR #2020
        pub fn secs_of(t: SystemTime) -> Option<u64> {
            t.duration_since(UNIX_EPOCH).ok().map(|d| d.as_secs())
        }

        // What: whole seconds since 1970.
        // Why: retention and schedules count seconds.
        // From: Issue #1683 | PR #1980
        pub fn unix_secs() -> u64 {
            secs_of(SystemTime::now()).unwrap_or(0)
        }

        // What: the time now in the zone of a TZif file.
        // Why: the host zone is mounted; std has no zones.
        // From: Issue #871 | PR #2020
        pub fn local(zone_file: &std::path::Path) -> Result<jiff::ZonedDateTime, String> {
            let fail = |e: &dyn std::fmt::Display| format!("{}: {e}", zone_file.display());
            let tz = match crate::shared::fs::read_if_present(zone_file) {
                Ok(Some(data)) => {
                    jiff::tz::TimeZone::tzif("localtime", &data).map_err(|e| fail(&e))?
                }
                // What: no zone file means UTC.
                // Why: a container without it runs UTC.
                // From: Issue #871 | PR #2020
                Ok(None) => jiff::tz::TimeZone::UTC,
                Err(e) => return Err(fail(&e)),
            };
            Ok(jiff::Timestamp::now().to_zoned_datetime(tz))
        }

        // What: local minutes since midnight.
        // Why: daily windows compare HH:MM.
        // From: Issue #871 | PR #2020
        pub fn local_minutes(zone_file: &std::path::Path) -> Result<u32, String> {
            let z = local(zone_file)?;
            let m = i32::from(z.hour()) * 60 + i32::from(z.minute());
            u32::try_from(m).map_err(|e| e.to_string())
        }

        // What: the clock as JSON: unix, local, offset.
        // Why: CLI and REST show the time services use.
        // From: Issue #871 | PR #2020
        pub fn report(s: &crate::config::Settings) -> Result<serde_json::Value, String> {
            let file = s.text("LOCALTIME_FILE")?;
            let z = local(std::path::Path::new(&file))?;
            Ok(serde_json::json!({
                "unix": z.timestamp().as_second(),
                "local": z.to_string(),
                "offset_seconds": z.offset().seconds(),
                "zone_file": file,
                "zone_file_present": std::path::Path::new(&file).is_file(),
            }))
        }
    }

    // What: safe file writes, ownership and disk space.
    // Why: a crash or full disk never leaves half a file.
    // From: Issue #1683 | PR #1858
    pub mod fs {
        use std::fs::{self, File, OpenOptions};
        use std::io::{self, Write};
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        use std::path::{Path, PathBuf};

        // What: file mode of file only its owner may read.
        // Why: secrets, tokens, snapshots share one mode.
        // From: Issue #1683 | PR #2017
        pub const PRIVATE_MODE: u32 = 0o600;

        // What: replace a file, or create it only if new.
        // Why: secrets: first writer wins; configs replace.
        // From: Issue #1683 | PR #1980
        #[derive(Clone, Copy, Debug, Eq, PartialEq)]
        pub enum Place {
            Replace,
            Exclusive,
        }

        // What: optional uid and gid for a written file.
        // Why: root writes files a service user must read.
        // From: Issue #1683 | PR #1980
        #[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
        pub struct Owner {
            pub uid: Option<u32>,
            pub gid: Option<u32>,
        }

        // What: the path with suffix appended to its name.
        // Why: one owner of sibling names like .local, .xz.
        // From: Issue #1683 | PR #2017
        pub fn with_suffix(path: &Path, suffix: &str) -> PathBuf {
            let mut name = path.as_os_str().to_owned();
            name.push(suffix);
            PathBuf::from(name)
        }

        // What: apply owner and mode on an open file.
        // Why: fchown on the handle avoids a path race.
        // From: Issue #1683 | PR #1980
        fn set_owner(file: &File, owner: Owner, mode: Option<u32>) -> io::Result<()> {
            if owner.uid.is_some() || owner.gid.is_some() {
                std::os::unix::fs::fchown(file, owner.uid, owner.gid)?;
            }
            match mode {
                Some(m) => file.set_permissions(fs::Permissions::from_mode(m)),
                None => Ok(()),
            }
        }

        // What: set owner and mode of an existing path.
        // Why: unchanged files still get the right owner.
        // From: Issue #1683 | PR #1858
        pub fn set_path_owner(path: &Path, owner: Owner, mode: Option<u32>) -> io::Result<()> {
            set_owner(&File::open(path)?, owner, mode)
        }

        // What: temp file beside target, synced, then moved
        // Why: readers see old or the new file, never half.
        // From: Issue #1683 | PR #1858
        pub fn write(
            path: &Path,
            contents: &[u8],
            mode: u32,
            place: Place,
            owner: Owner,
        ) -> io::Result<()> {
            write_with(path, mode, place, owner, |file| file.write_all(contents))
        }

        // What: write; fill streams bytes into the temp.
        // Why: big files need no copy in memory.
        // From: Issue #1683 | PR #2020
        pub fn write_with(
            path: &Path,
            mode: u32,
            place: Place,
            owner: Owner,
            fill: impl FnOnce(&mut File) -> io::Result<()>,
        ) -> io::Result<()> {
            if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
                fs::create_dir_all(dir)?;
            }
            let name = path
                .file_name()
                .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "no file name"))?
                .to_string_lossy();
            let tmp = path.with_file_name(format!(
                ".{name}.{}.{}",
                std::process::id(),
                super::clock::unix_nanos()
            ));
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(mode)
                .open(&tmp)?;
            let result = fill(&mut file)
                .and_then(|()| set_owner(&file, owner, None))
                .and_then(|()| file.sync_all())
                .and_then(|()| match place {
                    Place::Exclusive => fs::hard_link(&tmp, path),
                    Place::Replace => fs::rename(&tmp, path).or_else(|e| {
                        // What: busy mount: write in place
                        // Why: rename onto mount is EBUSY.
                        // From: Issue #1683 | PR #1980
                        if e.kind() != io::ErrorKind::ResourceBusy {
                            return Err(e);
                        }
                        let mut target =
                            OpenOptions::new().write(true).truncate(true).open(path)?;
                        io::copy(&mut File::open(&tmp)?, &mut target)?;
                        target.sync_all()
                    }),
                });
            drop(file);
            if let Err(e) = delete_if_present(&tmp) {
                eprintln!("fs: {} left behind: {e}", tmp.display());
            }
            result
        }

        // What: write only when content differs.
        // Why: true tells the caller to reload the program.
        // From: Issue #1683 | PR #1858
        pub fn write_if_changed(
            path: &Path,
            contents: &[u8],
            mode: u32,
            owner: Owner,
        ) -> io::Result<bool> {
            let same = same_content(path, contents)?;
            if same {
                set_path_owner(path, owner, Some(mode))?;
            } else {
                write(path, contents, mode, Place::Replace, owner)?;
            }
            Ok(!same)
        }

        // What: true when the file holds these bytes.
        // Why: write and plan judge a change the same way.
        // From: Issue #1683 | PR #2020
        pub fn same_content(path: &Path, contents: &[u8]) -> io::Result<bool> {
            Ok(read_if_present(path)?.is_some_and(|old| old == contents))
        }

        // What: removes a file; a missing one is fine.
        // Why: absent is the state the caller wants.
        // From: Issue #1683 | PR #2017
        pub fn delete_if_present(path: &Path) -> io::Result<()> {
            match fs::remove_file(path) {
                Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
                _ => Ok(()),
            }
        }

        // What: removes a folder tree; missing is fine.
        // Why: absent is the state the caller wants.
        // From: Issue #1683 | PR #2020
        pub fn delete_tree_if_present(path: &Path) -> io::Result<()> {
            match fs::remove_dir_all(path) {
                Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
                _ => Ok(()),
            }
        }

        // What: file bytes, or None if the file is absent.
        // Why: a missing file is a normal first state.
        // From: Issue #1683 | PR #2020
        pub fn read_if_present(path: &Path) -> io::Result<Option<Vec<u8>>> {
            match fs::read(path) {
                Ok(b) => Ok(Some(b)),
                Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
                Err(e) => Err(e),
            }
        }

        // What: a file as text; the error names the path.
        // Why: one reader of a file that must be there.
        // From: Issue #1683 | PR #2020
        pub fn read_text(path: &Path) -> Result<String, String> {
            fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))
        }

        // What: a file as text, or None if it is absent.
        // Why: one reader of a file that may be missing.
        // From: Issue #1683 | PR #2020
        pub fn read_text_if_present(path: &Path) -> Result<Option<String>, String> {
            let raw = read_if_present(path).map_err(|e| format!("{}: {e}", path.display()))?;
            raw.map(String::from_utf8)
                .transpose()
                .map_err(|e| format!("{}: {e}", path.display()))
        }

        // What: a file as bytes; the error names the path.
        // Why: one reader of a file that must be there.
        // From: Issue #1683 | PR #2020
        pub fn read_bytes(path: &Path) -> Result<Vec<u8>, String> {
            fs::read(path).map_err(|e| format!("{}: {e}", path.display()))
        }

        // What: a JSON file as T, or None if it is absent.
        // Why: one reader; bad JSON is an error, not empty.
        // From: Issue #1683 | PR #2020
        pub fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Result<Option<T>, String> {
            let raw = read_if_present(path).map_err(|e| format!("{}: {e}", path.display()))?;
            raw.map(|b| serde_json::from_slice(&b))
                .transpose()
                .map_err(|e| format!("{}: {e}", path.display()))
        }

        // What: paths in a folder; an absent one is empty.
        // Why: a folder made on first write may not exist.
        // From: Issue #1683 | PR #2020
        pub fn entries_if_present(dir: &Path) -> io::Result<Vec<PathBuf>> {
            match fs::read_dir(dir) {
                Ok(rd) => rd.map(|e| e.map(|e| e.path())).collect(),
                Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(Vec::new()),
                Err(e) => Err(e),
            }
        }

        // What: change time in unix seconds, else 0.
        // Why: ages and snapshot times are plain seconds.
        // From: Issue #1683 | PR #1980
        pub fn modified_secs(meta: &fs::Metadata) -> u64 {
            meta.modified()
                .ok()
                .and_then(super::clock::secs_of)
                .unwrap_or(0)
        }

        // What: every entry below root, root too; errors.
        // Why: one walk for file lists and owner fixes.
        // From: Issue #1683 | PR #1980
        pub fn entries_under(root: &Path) -> (Vec<(PathBuf, fs::Metadata)>, Vec<String>) {
            let (mut out, mut errs) = (Vec::new(), Vec::new());
            // What: a vanished entry is no error.
            // Why: nginx evicts while the walk runs.
            // From: Issue #1683 | PR #2020
            let mut note = |path: &Path, e: io::Error| {
                if e.kind() != io::ErrorKind::NotFound {
                    errs.push(format!("{}: {e}", path.display()));
                }
            };
            let mut todo = vec![root.to_path_buf()];
            while let Some(path) = todo.pop() {
                let meta = match fs::symlink_metadata(&path) {
                    Ok(meta) => meta,
                    Err(e) => {
                        note(&path, e);
                        continue;
                    }
                };
                if meta.is_dir() {
                    match fs::read_dir(&path) {
                        Ok(rd) => {
                            for entry in rd {
                                match entry {
                                    Ok(entry) => todo.push(entry.path()),
                                    Err(e) => note(&path, e),
                                }
                            }
                        }
                        Err(e) => note(&path, e),
                    }
                }
                out.push((path, meta));
            }
            (out, errs)
        }

        // What: every regular file below root, and errors.
        // Why: a skipped folder must not look like done.
        // From: Issue #1683 | PR #1980
        pub fn files_under(root: &Path) -> (Vec<(PathBuf, fs::Metadata)>, Vec<String>) {
            let (all, errs) = entries_under(root);
            (all.into_iter().filter(|(_, m)| m.is_file()).collect(), errs)
        }

        // What: give every entry below root one owner.
        // Why: a wrong owner blocks the writer and cleanup.
        // From: Issue #1683 | PR #2020
        pub fn chown_tree(root: &Path, uid: u32, gid: u32, apply: bool) -> (u64, Vec<String>) {
            use std::os::unix::fs::MetadataExt;
            let (all, mut errs) = entries_under(root);
            let mut fixed = 0u64;
            for (path, meta) in all {
                if (meta.uid(), meta.gid()) == (uid, gid) {
                    continue;
                }
                // What: a dry run only counts.
                // Why: it shows what the run would fix.
                // From: Issue #1683 | PR #2020
                let done = match apply {
                    true => std::os::unix::fs::lchown(&path, Some(uid), Some(gid)),
                    false => Ok(()),
                };
                match done {
                    Ok(()) => fixed += 1,
                    Err(e) => errs.push(format!("{}: {e}", path.display())),
                }
            }
            (fixed, errs)
        }

        // What: total and free bytes of a filesystem.
        // Why: cache size checks need the real free space.
        // From: Issue #1683 | PR #1980
        #[derive(Clone, Copy, Debug, Eq, PartialEq)]
        pub struct Space {
            pub total: u64,
            pub free: u64,
        }

        // What: methods of the disk space Space.
        // Why: every use figure of a disk is one rule.
        // From: Issue #1683 | PR #2020
        impl Space {
            // What: bytes in use: total minus free.
            // Why: one rule for every use figure of a disk.
            // From: Issue #1683 | PR #2020
            pub fn used(&self) -> u64 {
                self.total.saturating_sub(self.free)
            }

            // What: percent of the disk in use.
            // Why: one rule for watchdog light and readers.
            // From: Issue #1683 | PR #2020
            pub fn pct(&self) -> u64 {
                crate::shared::human::pct(self.used(), self.total)
            }

            // What: percent of the disk still free.
            // Why: the watchdog disk check reads it here.
            // From: Issue #1683 | PR #2020
            pub fn free_pct(&self) -> u64 {
                crate::shared::human::pct(self.free, self.total)
            }
        }

        // What: statvfs of the filesystem holding path.
        // Why: free counts blocks a non-root user may use.
        // From: Issue #1683 | PR #1858
        pub fn space(path: &Path) -> io::Result<Space> {
            let st = rustix::fs::statvfs(path).map_err(io::Error::from)?;
            Ok(Space {
                total: st.f_blocks.saturating_mul(st.f_frsize),
                free: st.f_bavail.saturating_mul(st.f_frsize),
            })
        }
    }

    // What: generated secrets and sealed tokens.
    // Why: no secret is hardcoded or stored in plain text.
    // From: Issue #1683 | PR #1858
    pub mod secret {
        use super::fs::{self, Owner, Place};
        use chacha20poly1305::ChaCha20Poly1305;
        use chacha20poly1305::aead::{Aead, KeyInit};
        use std::io;
        use std::path::{Path, PathBuf};
        use subtle::ConstantTimeEq;

        // What: nonce length of ChaCha20-Poly1305.
        // Why: fixed by the cipher (RFC 8439).
        // From: Issue #1683 | PR #1858
        const NONCE_LEN: usize = 12;

        // What: true for empty or template-like values.
        // Why: a copied example value must never go live.
        // From: Issue #1683 | PR #1858
        pub fn is_placeholder(value: &str) -> bool {
            let v = value.trim().to_ascii_lowercase().replace('-', "_");
            v.is_empty()
                || v.contains("change_me")
                || v.starts_with("changeme")
                || v.starts_with("your_")
                || v.ends_with("_here")
                || (v.starts_with('<') && v.ends_with('>'))
        }

        // What: n random bytes as lowercase hex.
        // Why: tokens and keys come from the OS generator.
        // From: Issue #1683 | PR #1858
        pub fn random_hex(bytes: usize) -> String {
            let mut buf = vec![0u8; bytes];
            rand::fill(&mut buf[..]);
            hex::encode(buf)
        }

        // What: compare two secrets in constant time.
        // Why: timing must not leak how much matched.
        // From: Issue #1683 | PR #1858
        pub fn equal(presented: &str, expected: &str) -> bool {
            presented.as_bytes().ct_eq(expected.as_bytes()).into()
        }

        // What: the directory of the secret files.
        // Why: one owner of the SECRETS_DIR setting.
        // From: Issue #1683 | PR #2017
        pub fn dir(s: &crate::config::Settings) -> Result<PathBuf, String> {
            Ok(PathBuf::from(s.text("SECRETS_DIR")?))
        }

        // What: secret file of a key: A_B becomes a-b.
        // Why: one naming rule for every secret file.
        // From: Issue #1683 | PR #1858
        pub fn file_of(dir: &Path, key: &str) -> PathBuf {
            dir.join(key.to_ascii_lowercase().replace('_', "-"))
        }

        // What: the key of a secret file: a-b becomes A_B.
        // Why: the reverse of file_of; one naming rule.
        // From: Issue #1683 | PR #2020
        fn key_of(name: &str) -> String {
            name.to_ascii_uppercase().replace('-', "_")
        }

        // What: read the file, or create it once.
        // Why: first writer wins; peers then read the same.
        // From: Issue #1683 | PR #1858
        pub fn load_or_create(
            path: &Path,
            create: impl FnOnce() -> String,
            owner: Owner,
        ) -> io::Result<String> {
            let usable = |text: String| {
                if is_placeholder(&text) {
                    let msg = format!("{} holds a placeholder", path.display());
                    Err(io::Error::new(io::ErrorKind::InvalidData, msg))
                } else {
                    Ok(text)
                }
            };
            let read = || {
                fs::read_text_if_present(path)
                    .map(|t| t.map(|t| t.trim().to_string()))
                    .map_err(io::Error::other)
            };
            match read()? {
                Some(text) => usable(text),
                None => {
                    let text = create();
                    let mode = fs::PRIVATE_MODE;
                    match fs::write(path, text.as_bytes(), mode, Place::Exclusive, owner) {
                        Ok(()) => Ok(text),
                        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                            usable(read()?.unwrap_or_default())
                        }
                        Err(e) => Err(e),
                    }
                }
            }
        }

        // What: a secret file's text without outer blanks.
        // Why: every reader of a secret file trims alike.
        // From: Issue #1683 | PR #2020
        fn read_text(path: &Path) -> Result<String, String> {
            fs::read_text(path).map(|t| t.trim().to_string())
        }

        // What: the files in the secret directory.
        // Why: states and all_values walk the same list.
        // From: Issue #1683 | PR #2020
        fn files_in(dir: &Path) -> Result<Vec<PathBuf>, String> {
            let paths =
                fs::entries_if_present(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
            Ok(paths.into_iter().filter(|p| p.is_file()).collect())
        }

        // What: env value, else the shared secret file.
        // Why: operator may set it; else it is generated.
        // From: Issue #1683 | PR #1858
        pub fn resolve(
            env: &dyn Fn(&str) -> Option<String>,
            dir: &Path,
            key: &str,
            owner: Owner,
        ) -> io::Result<String> {
            match crate::config::env_set(env, key) {
                Some(v) if is_placeholder(&v) => Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("{key} holds a placeholder"),
                )),
                Some(v) => Ok(v),
                None => load_or_create(&file_of(dir, key), || random_hex(32), owner),
            }
        }

        // What: one secret by its key: env, else the file.
        // Why: every program gets same key the same way.
        // From: Issue #1683 | PR #2020
        pub fn get(s: &crate::config::Settings, key: &str) -> Result<String, String> {
            resolve(&crate::config::process_env, &dir(s)?, key, Owner::default())
                .map_err(|e| format!("{key}: {e}"))
        }

        // What: state of each secret file, never a value.
        // Why: one reader for REST and the CLI check.
        // From: Issue #1683 | PR #2020
        pub fn states(s: &crate::config::Settings) -> Result<serde_json::Value, String> {
            use std::os::unix::fs::PermissionsExt;
            let d = dir(s)?;
            let mut rows = Vec::new();
            for path in files_in(&d)? {
                let name = path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or_default();
                let key = key_of(name);
                let meta =
                    std::fs::metadata(&path).map_err(|e| format!("{}: {e}", path.display()))?;
                let text = read_text(&path)?;
                let text = text.as_str();
                let mode = meta.permissions().mode() & 0o777;
                rows.push(serde_json::json!({
                    "key": key, "file": name, "mode": format!("{mode:o}"),
                    "private": mode == fs::PRIVATE_MODE, "empty": text.is_empty(),
                    "placeholder": is_placeholder(text),
                    "env_overrides": crate::config::env_set(&crate::config::process_env, &key).is_some()
                }));
            }
            Ok(serde_json::json!({"dir": d.display().to_string(), "secrets": rows}))
        }

        // What: every secret value this process knows.
        // Why: previews mask them; files and settings both.
        // From: Issue #1683 | PR #2020
        pub fn all_values(s: &crate::config::Settings) -> Result<Vec<String>, String> {
            let d = dir(s)?;
            let mut out = s.secret_values();
            for path in files_in(&d)? {
                out.push(read_text(&path)?);
            }
            out.push(tsig_secret(s)?);
            out.retain(|v| v.len() >= 4);
            out.sort_by_key(|v| std::cmp::Reverse(v.len()));
            out.dedup();
            Ok(out)
        }

        // What: what the secret command does.
        // Why: run() matches it, the table names it.
        // From: Issue #1683 | PR #2020
        #[derive(Clone, Copy, PartialEq)]
        enum Op {
            List,
        }

        // What: every command of the secret group.
        // Why: help, errors and the choice read this table.
        // From: Issue #1683 | PR #2020
        const COMMANDS: [(&str, crate::shared::cli::Entry<Op>); 1] =
            [("list", crate::shared::cli::row(Op::List, "list"))];

        // What: lancache-ng secret list: states as JSON.
        // Why: the CLI of secret reads sits with them.
        // From: Issue #1683 | PR #2020
        pub fn run(args: &[String]) -> Result<(), String> {
            use crate::shared::cli;
            if cli::op_of(&COMMANDS, args.first()) != Some(Op::List) {
                return Err(crate::shared::cli::help(&COMMANDS));
            }
            let v = states(&crate::config::Settings::from_process()?)?;
            println!("{v}");
            let rows = v["secrets"].as_array().into_iter().flatten();
            let bad = rows
                .filter(|r| r["empty"] == true || r["placeholder"] == true || r["private"] == false)
                .count();
            match bad {
                0 => Ok(()),
                n => Err(format!(
                    "secret list: {n} file empty, placeholder or not private"
                )),
            }
        }

        // What: path of the DDNS TSIG secret file.
        // Why: Kea DDNS and PowerDNS share this key.
        // From: Issue #1683 | PR #1980
        pub fn tsig_file(s: &crate::config::Settings) -> Result<PathBuf, String> {
            Ok(file_of(&dir(s)?, "DDNS_TSIG_KEY"))
        }

        // What: fresh 32-byte TSIG secret, base64.
        // Why: PowerDNS and Kea both read base64.
        // From: Issue #1683 | PR #1980
        pub fn new_tsig() -> String {
            use base64::Engine as _;
            let mut key = [0u8; 32];
            rand::fill(&mut key[..]);
            base64::engine::general_purpose::STANDARD.encode(key)
        }

        // What: TSIG secret; a rotated file wins.
        // Why: a ui rotation beats the setup.sh value.
        // From: Issue #1683 | PR #1980
        pub fn tsig_secret(s: &crate::config::Settings) -> Result<String, String> {
            let file = tsig_file(s)?;
            if !file.exists()
                && let Some(v) =
                    crate::config::env_set(&crate::config::process_env, "DDNS_TSIG_KEY")
            {
                return Ok(v);
            }
            load_or_create(&file, new_tsig, Owner::default())
                .map_err(|e| format!("DDNS_TSIG_KEY: {e}"))
        }

        // What: 32 raw key bytes from 64 hex digits.
        // Why: the cipher takes raw bytes.
        // From: Issue #1683 | PR #1858
        pub fn key_bytes(hex_key: &str) -> Result<[u8; 32], String> {
            hex::decode(hex_key)
                .map_err(|e| format!("key is not hex: {e}"))?
                .try_into()
                .map_err(|_| "key must be 32 bytes".to_string())
        }

        // What: encrypt; output is nonce then ciphertext.
        // Why: stored login tokens are never plain text.
        // From: Issue #1683 | PR #1858
        pub fn seal(key: &[u8; 32], plain: &[u8]) -> Result<Vec<u8>, String> {
            let mut nonce = [0u8; NONCE_LEN];
            rand::fill(&mut nonce[..]);
            let mut out = nonce.to_vec();
            out.extend(
                ChaCha20Poly1305::new(key.into())
                    .encrypt(&nonce.into(), plain)
                    .map_err(|_| "seal failed".to_string())?,
            );
            Ok(out)
        }

        // What: decrypt what seal wrote.
        // Why: a wrong key or damage is a clear error.
        // From: Issue #1683 | PR #1980
        pub fn open(key: &[u8; 32], sealed: &[u8]) -> Result<Vec<u8>, String> {
            let Some((nonce, body)) = sealed.split_at_checked(NONCE_LEN) else {
                return Err("sealed data too short".into());
            };
            let nonce: [u8; NONCE_LEN] = nonce.try_into().map_err(|_| "bad nonce".to_string())?;
            ChaCha20Poly1305::new(key.into())
                .decrypt(&nonce.into(), body)
                .map_err(|_| "sealed data is damaged or the key is wrong".to_string())
        }

        // What: 32 key bytes from salt, machine features.
        // Why: the key needs the data dir and this machine.
        // From: Issue #871 | PR #2020
        pub fn bind_key(salt: &[u8; 32], parts: &[(String, Vec<u8>)]) -> [u8; 32] {
            use sha2::{Digest, Sha256};
            let mut h = Sha256::new();
            h.update(b"lancache-ng bind v1\0");
            h.update(salt);
            // What: each part with its length in front.
            // Why: "ab"+"c" must differ from "a"+"bc".
            // From: Issue #871 | PR #1997
            for (name, value) in parts {
                for chunk in [name.as_bytes(), value.as_slice()] {
                    h.update((chunk.len() as u64).to_be_bytes());
                    h.update(chunk);
                }
            }
            let mut key = [0u8; 32];
            key.copy_from_slice(&h.finalize());
            key
        }
    }

    // What: HTTP client, probe, drain and ui socket.
    // Why: every role uses the same timeouts from the SOT.
    // From: Issue #1683 | PR #1980
    pub mod http {
        use crate::config::Settings;
        use futures_util::StreamExt as _;
        use std::time::Duration;

        // What: what a CLI call sends: JSON, form, none.
        // Why: REST takes JSON, forms; None is a GET read.
        // From: Issue #1683 | PR #2020
        pub enum Body {
            Json(serde_json::Value),
            Form(Vec<(String, String)>),
            None,
        }

        // What: POST to the ui over its CLI socket.
        // Why: CLI writes run in the ui, one state owner.
        // From: Issue #1683 | PR #2020
        pub async fn ui_socket(
            s: &Settings,
            route: &str,
            body: Body,
        ) -> Result<serde_json::Value, String> {
            let path = s.text("UI_CLI_SOCKET")?;
            // What: a redirect is read, never followed.
            // Why: a page form answers 303 when it is done.
            // From: Issue #1683 | PR #2020
            let client = Build::new()
                .socket(&path)
                .no_redirect()
                .timeout(Duration::from_secs(s.uint("UI_CLI_WRITE_TIMEOUT_SECONDS")?))
                .build(&path)?;
            let url = format!("http://ui{route}");
            let req = match &body {
                Body::Json(v) => client.post(url).json(v),
                Body::Form(f) => client.post(url).form(f),
                Body::None => client.get(url),
            };
            // What: the CLI asks for the built-in language.
            // Why: the CLI is English; pages pick theirs.
            // From: Issue #1683 | PR #2020
            let req = req.header(reqwest::header::ACCEPT_LANGUAGE, super::FALLBACK_LANG);
            let resp = req
                .send()
                .await
                .map_err(|e| format!("{path}: is the ui running? {}", error_chain(&e)))?;
            let status = resp.status();
            let text = read_text(resp, max_body(s)?, &path).await?;
            if !status.is_success() && !status.is_redirection() {
                return Err(format!("ui {}: {text}", status.as_u16()));
            }
            // What: an empty answer (204, 303) is null.
            // Why: start, stop and forms send no body.
            // From: Issue #1683 | PR #2020
            if text.trim().is_empty() {
                return Ok(serde_json::Value::Null);
            }
            serde_json::from_str(&text).map_err(|e| format!("ui answer: {e}"))
        }

        // What: "do <action> field=value" for page forms.
        // Why: DHCP and DNS CLI post forms the same way.
        // From: Issue #1683 | PR #2020
        pub async fn page_do(
            s: &Settings,
            keys: &[&str],
            args: &[String],
        ) -> Result<serde_json::Value, String> {
            // What: the word is the key without UI_ROUTE_.
            // Why: router and CLI read one key list.
            // From: Issue #1683 | PR #2020
            let word = |k: &str| {
                k.trim_start_matches("UI_ROUTE_")
                    .to_lowercase()
                    .replace('_', "-")
            };
            let words: Vec<String> = keys.iter().map(|k| word(k)).collect();
            let usage = || format!("do: actions {}", words.join("|"));
            let (name, pairs) = args.split_first().ok_or_else(usage)?;
            let key = keys.iter().find(|k| word(k) == *name).ok_or_else(usage)?;
            let mut form = Vec::new();
            for pair in pairs {
                let (k, v) = crate::shared::cli::pair(pair, "field=value")?;
                form.push((k.to_string(), v.to_string()));
            }
            let v = ui_socket(s, &s.text(key)?, Body::Form(form)).await?;
            Ok(serde_json::json!({"done": name, "answer": v}))
        }

        // What: the request limit of the shared client.
        // Why: every HTTP call waits the same SOT time.
        // From: Issue #1683 | PR #2020
        pub fn timeout(s: &Settings) -> Result<Duration, String> {
            s.uint("HTTP_CLIENT_TIMEOUT").map(Duration::from_secs)
        }

        // What: the most bytes one read answer may have.
        // Why: a far end must not fill the memory.
        // From: Issue #1683 | PR #2020
        pub fn max_body(s: &Settings) -> Result<u64, String> {
            s.uint("HTTP_RESPONSE_MAX_BYTES")
        }

        // What: a whole answer body, at most max bytes.
        // Why: one reader; streams are counted, not read.
        // From: Issue #1683 | PR #2020
        pub async fn read_body(
            resp: reqwest::Response,
            max: u64,
            what: &str,
        ) -> Result<Vec<u8>, String> {
            let over = |n: u64| format!("{what}: answer of {n} bytes or more, limit {max}");
            if let Some(n) = resp.content_length().filter(|n| *n > max) {
                return Err(over(n));
            }
            let mut out = Vec::new();
            let mut body = resp.bytes_stream();
            while let Some(chunk) = body.next().await {
                let chunk = chunk.map_err(|e| format!("{what}: {}", error_chain(&e)))?;
                let n = (out.len() + chunk.len()) as u64;
                if n > max {
                    return Err(over(n));
                }
                out.extend_from_slice(&chunk);
            }
            Ok(out)
        }

        // What: a whole answer as UTF-8 text.
        // Why: one reader with the size limit.
        // From: Issue #1683 | PR #2020
        pub async fn read_text(
            resp: reqwest::Response,
            max: u64,
            what: &str,
        ) -> Result<String, String> {
            String::from_utf8(read_body(resp, max, what).await?)
                .map_err(|_| format!("{what}: answer is no UTF-8 text"))
        }

        // What: a whole answer as JSON of type T.
        // Why: one reader with the size limit.
        // From: Issue #1683 | PR #2020
        pub async fn read_json<T: serde::de::DeserializeOwned>(
            resp: reqwest::Response,
            max: u64,
            what: &str,
        ) -> Result<T, String> {
            serde_json::from_slice(&read_body(resp, max, what).await?)
                .map_err(|e| format!("{what}: {e}"))
        }

        // What: the one maker of HTTP clients.
        // Why: socket, CA, redirect, limit in one place.
        // From: Issue #1683 | PR #2020
        pub struct Build(reqwest::ClientBuilder);

        // What: methods of the client maker Build.
        // Why: each option is one chained call.
        // From: Issue #1683 | PR #2020
        impl Build {
            // What: a maker with the reqwest defaults.
            // Why: each caller adds only what it needs.
            // From: Issue #1683 | PR #2020
            pub fn new() -> Self {
                Self(reqwest::Client::builder())
            }

            // What: talk over a unix socket, not TCP.
            // Why: Docker and the ui CLI listen on sockets.
            // From: Issue #1683 | PR #2020
            pub fn socket(self, path: &str) -> Self {
                Self(self.0.unix_socket(std::path::PathBuf::from(path)))
            }

            // What: a redirect is an answer; not followed.
            // Why: engine and ui forms answer 303.
            // From: Issue #1683 | PR #2020
            pub fn no_redirect(self) -> Self {
                Self(self.0.redirect(reqwest::redirect::Policy::none()))
            }

            // What: total time limit of one request.
            // Why: a call without limit may hang for ever.
            // From: Issue #1683 | PR #2020
            pub fn timeout(self, limit: Duration) -> Self {
                Self(self.0.timeout(limit))
            }

            // What: the environment proxy is not used.
            // Why: health probes go straight to the target.
            // From: Issue #1683 | PR #2020
            pub fn no_proxy(self) -> Self {
                Self(self.0.no_proxy())
            }

            // What: idle pool time and TCP keepalive.
            // Why: both come from the SOT.
            // From: Issue #1683 | PR #2020
            pub fn keep(self, idle: Duration, alive: Duration) -> Self {
                Self(self.0.pool_idle_timeout(idle).tcp_keepalive(alive))
            }

            // What: idle connections kept per host.
            // Why: a download pool is as wide as its jobs.
            // From: Issue #1683 | PR #2020
            pub fn per_host(self, n: usize) -> Self {
                Self(self.0.pool_max_idle_per_host(n))
            }

            // What: names resolve through this resolver.
            // Why: the CDN names go to the proxy container.
            // From: Issue #1683 | PR #2020
            pub fn resolver<R: reqwest::dns::Resolve + 'static>(
                self,
                r: std::sync::Arc<R>,
            ) -> Self {
                Self(self.0.dns_resolver(r))
            }

            // What: trust this CA besides the public roots.
            // Why: the stack CA signs the cache certs.
            // From: Issue #1683 | PR #2020
            pub fn trust_also(self, pem: &[u8]) -> Result<Self, String> {
                let ca = reqwest::Certificate::from_pem(pem).map_err(|e| format!("CA: {e}"))?;
                Ok(Self(self.0.tls_certs_merge([ca])))
            }

            // What: trust this CA and nothing else.
            // Why: a probe must not accept other CAs.
            // From: Issue #1683 | PR #2020
            pub fn trust_only(self, pem: &[u8]) -> Result<Self, String> {
                let ca = reqwest::Certificate::from_pem(pem).map_err(|e| format!("CA: {e}"))?;
                Ok(Self(self.0.tls_certs_only([ca])))
            }

            // What: the client; an error names its purpose.
            // Why: one text shape for every failed build.
            // From: Issue #1683 | PR #2020
            pub fn build(self, what: &str) -> Result<reqwest::Client, String> {
                self.0.build().map_err(|e| format!("{what}: {e}"))
            }
        }

        // What: shared client with SOT timeouts.
        // Why: no request may hang without a limit.
        // From: Issue #1683 | PR #1980
        pub fn client(s: &Settings) -> Result<reqwest::Client, String> {
            let secs = |key: &str| s.uint(key).map(Duration::from_secs);
            Build::new()
                .timeout(timeout(s)?)
                .keep(secs("HTTP_POOL_IDLE_TIMEOUT")?, secs("HTTP_TCP_KEEPALIVE")?)
                .build("HTTP client")
        }

        // What: error text with every source cause.
        // Why: reqwest hides the cause in source().
        // From: Issue #1683 | PR #1980
        pub fn error_chain(error: &dyn std::error::Error) -> String {
            let mut parts = vec![error.to_string()];
            let mut next = error.source();
            while let Some(cause) = next {
                parts.push(cause.to_string());
                next = cause.source();
            }
            parts.join(": ")
        }

        // What: GET url; ok only on 2xx.
        // Why: health probes of the proxy and the ui.
        // From: Issue #1683 | PR #1980
        pub async fn probe(
            url: &str,
            ca_pem: Option<&[u8]>,
            timeout: Duration,
        ) -> Result<(), String> {
            let mut builder = Build::new().timeout(timeout).no_proxy();
            if url.starts_with("https://") {
                let pem = ca_pem.ok_or_else(|| format!("{url}: https probe needs the stack CA"))?;
                builder = builder.trust_only(pem)?;
            }
            let client = builder.build("probe client")?;
            let status = client
                .get(url)
                .send()
                .await
                .map_err(|e| format!("{url}: {}", error_chain(&e)))?
                .status();
            if status.is_success() {
                Ok(())
            } else {
                Err(format!("{url}: HTTP {status}"))
            }
        }

        // What: GET url, count and drop the body.
        // Why: prefill warms the cache; nothing is stored.
        // From: Issue #1683 | PR #1980
        pub async fn drain(client: &reqwest::Client, url: &str) -> Result<(u16, u64), String> {
            let resp = client
                .get(url)
                .send()
                .await
                .map_err(|e| format!("{url}: {}", error_chain(&e)))?;
            let status = resp.status().as_u16();
            let mut total = 0u64;
            let mut body = resp.bytes_stream();
            while let Some(chunk) = body.next().await {
                let chunk = chunk.map_err(|e| format!("{url}: {}", error_chain(&e)))?;
                total += chunk.len() as u64;
            }
            Ok((status, total))
        }
    }

    // What: client of the PowerDNS HTTP API.
    // Why: ui writes records; no message bus between.
    // From: Issue #1683 | PR #1980
    pub mod pdns {
        use reqwest::{Method, StatusCode};
        use serde_json::{Value, json};
        use std::collections::BTreeSet;

        // What: auth header name of the PowerDNS API.
        // Why: fixed by PowerDNS.
        // From: Issue #1683 | PR #1980
        const KEY_HEADER: &str = "X-API-Key";

        // What: the zone fields the sync check reads.
        // Why: serial against notified serial shows lag.
        // From: Issue #1683 | PR #1980
        #[derive(Clone, Debug, serde::Deserialize)]
        pub struct Zone {
            pub name: String,
            pub kind: String,
            #[serde(default)]
            pub serial: u32,
            #[serde(default)]
            pub masters: Vec<String>,
        }

        // What: one API endpoint with its key.
        // Why: base is .../api/v1/servers/<id> from SOT.
        // From: Issue #1683 | PR #1980
        #[derive(Clone)]
        pub struct Api {
            client: reqwest::Client,
            base: String,
            key: String,
            max_body: u64,
        }

        // What: the first methods of the pdns Api.
        // Why: one client holds base, key and limit.
        // From: Issue #1683 | PR #2020
        impl Api {
            // What: the API base URL, never the key.
            // Why: reports name the server they asked.
            // From: Issue #1683 | PR #2020
            pub fn base(&self) -> &str {
                &self.base
            }
        }

        // What: name with exactly one final dot.
        // Why: the API wants canonical names.
        // From: Issue #1683 | PR #1980
        pub fn zone_id(zone: &str) -> String {
            format!("{}.", super::dns::bare_zone(zone))
        }

        // What: the rrset of a name and type in a list.
        // Why: the rrset row form belongs to the client.
        // From: Issue #1683 | PR #2020
        pub fn find_rrset<'a>(rows: &'a [Value], name: &str, kind: &str) -> Option<&'a Value> {
            let id = zone_id(name);
            rows.iter()
                .find(|r| r["name"] == id.as_str() && r["type"] == kind)
        }

        // What: the record contents of one rrset row.
        // Why: the rrset row form belongs to the client.
        // From: Issue #1683 | PR #2020
        pub fn record_texts(r: &Value) -> Vec<String> {
            r["records"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|c| c["content"].as_str().map(str::to_string))
                .collect()
        }

        // What: the API path of one zone.
        // Why: every zone call starts with this path.
        // From: Issue #1683 | PR #2017
        fn zone_path(zone: &str) -> String {
            format!("/zones/{}", zone_id(zone))
        }

        // What: the API path below one zone, like notify.
        // Why: every zone action extends the zone path.
        // From: Issue #1683 | PR #2020
        fn zone_sub(zone: &str, tail: &str) -> String {
            format!("{}/{tail}", zone_path(zone))
        }

        // What: the body of a 2xx answer; else an error.
        // Why: PowerDNS explains refusals in the body.
        // From: Issue #1683 | PR #1980
        fn checked((url, status, text): (String, StatusCode, String)) -> Result<String, String> {
            if status.is_success() {
                Ok(text)
            } else {
                Err(format!("{url}: HTTP {status}: {text}"))
            }
        }

        // What: the request methods of the pdns Api.
        // Why: each PowerDNS call goes through request.
        // From: Issue #1683 | PR #2020
        impl Api {
            // What: a client for one server base URL.
            // Why: auth and recursor share this code.
            // From: Issue #1683 | PR #1980
            pub fn new(client: reqwest::Client, max_body: u64, base: &str, key: &str) -> Self {
                Self {
                    client,
                    base: base.trim_end_matches('/').to_string(),
                    key: key.to_string(),
                    max_body,
                }
            }

            // What: one request; status and body text.
            // Why: a caller may read the status, not text.
            // From: Issue #1683 | PR #2020
            async fn request(
                &self,
                method: Method,
                path: &str,
                body: Option<Value>,
            ) -> Result<(String, StatusCode, String), String> {
                let url = format!("{}{path}", self.base);
                let mut req = self
                    .client
                    .request(method, &url)
                    .header(KEY_HEADER, &self.key);
                if let Some(body) = body {
                    req = req.json(&body);
                }
                let resp = req
                    .send()
                    .await
                    .map_err(|e| format!("{url}: {}", super::http::error_chain(&e)))?;
                let status = resp.status();
                let text = super::http::read_text(resp, self.max_body, &url).await?;
                Ok((url, status, text))
            }

            // What: one request; non-2xx is an error.
            // Why: most callers need only the body text.
            // From: Issue #1683 | PR #1980
            async fn call(
                &self,
                method: Method,
                path: &str,
                body: Option<Value>,
            ) -> Result<String, String> {
                checked(self.request(method, path, body).await?)
            }

            // What: a request whose answer text is dropped.
            // Why: writes only need the status checked.
            // From: Issue #1683 | PR #2020
            async fn send(
                &self,
                method: Method,
                path: &str,
                body: Option<Value>,
            ) -> Result<(), String> {
                self.call(method, path, body).await.map(drop)
            }

            // What: GET a path and read its answer as JSON.
            // Why: each read names what it parsed on error.
            // From: Issue #1683 | PR #2020
            async fn fetch_json<T: serde::de::DeserializeOwned>(
                &self,
                path: &str,
                what: &str,
            ) -> Result<T, String> {
                let text = self.call(Method::GET, path, None).await?;
                serde_json::from_str(&text).map_err(|e| format!("{what}: {e}"))
            }

            // What: the JSON document of one zone.
            // Why: rrsets and the signing check share it.
            // From: Issue #1683 | PR #2020
            async fn zone_doc(&self, zone: &str) -> Result<Value, String> {
                self.fetch_json(&zone_path(zone), &format!("zone {zone}"))
                    .await
            }

            // What: PATCH a list of rrset changes.
            // Why: soa-edit-api raises the serial once.
            // From: Issue #1683 | PR #1980
            async fn patch(&self, zone: &str, rrsets: Vec<Value>) -> Result<(), String> {
                let path = zone_path(zone);
                self.send(Method::PATCH, &path, Some(json!({ "rrsets": rrsets })))
                    .await
            }

            // What: replace one rrset; empty deletes it.
            // Why: a record edit is one PATCH.
            // From: Issue #1683 | PR #1980
            pub async fn set_rrset(
                &self,
                zone: &str,
                name: &str,
                kind: &str,
                ttl: u32,
                contents: &[String],
            ) -> Result<(), String> {
                let change = if contents.is_empty() {
                    json!({"name": zone_id(name), "type": kind, "changetype": "DELETE"})
                } else {
                    let records: Vec<Value> = contents
                        .iter()
                        .map(|c| json!({"content": c, "disabled": false}))
                        .collect();
                    json!({"name": zone_id(name), "type": kind, "ttl": ttl,
                       "changetype": "REPLACE", "records": records})
                };
                self.patch(zone, vec![change]).await
            }

            // What: all rrsets of a zone.
            // Why: snapshots and lists read them.
            // From: Issue #1683 | PR #1980
            pub async fn rrsets(&self, zone: &str) -> Result<Vec<Value>, String> {
                let v = self.zone_doc(zone).await?;
                Ok(v["rrsets"].as_array().cloned().unwrap_or_default())
            }

            // What: make the zone equal to saved rrsets.
            // Why: rollback; SOA stays so the serial rises.
            // From: Issue #1683 | PR #1980
            pub async fn restore(&self, zone: &str, saved: &[Value]) -> Result<(), String> {
                let id = |r: &Value| (r["name"].to_string(), r["type"].to_string());
                let wanted: BTreeSet<_> = saved.iter().map(id).collect();
                let mut changes: Vec<Value> = self
                    .rrsets(zone)
                    .await?
                    .into_iter()
                    .filter(|r| r["type"] != "SOA" && !wanted.contains(&id(r)))
                    .map(|r| json!({"name": r["name"], "type": r["type"], "changetype": "DELETE"}))
                    .collect();
                changes.extend(saved.iter().filter(|r| r["type"] != "SOA").map(|r| {
                    json!({"name": r["name"], "type": r["type"], "ttl": r["ttl"],
                       "changetype": "REPLACE", "records": r["records"]})
                }));
                self.patch(zone, changes).await
            }

            // What: add a zone that pulls, with its key.
            // Why: no zone may exist without its TSIG key.
            // From: Issue #1683 | PR #2017
            pub async fn create_secondary(
                &self,
                zone: &str,
                masters: &[String],
                key: &str,
            ) -> Result<(), String> {
                let body = json!({
                    "name": zone_id(zone),
                    "kind": "Slave",
                    "masters": masters,
                    "slave_tsig_key_ids": [zone_id(key)],
                });
                self.send(Method::POST, "/zones", Some(body)).await
            }

            // What: remove one zone.
            // Why: changed LAN domain leaves its old zones.
            // From: Issue #1683 | PR #1980
            pub async fn delete_zone(&self, zone: &str) -> Result<(), String> {
                let path = zone_path(zone);
                self.send(Method::DELETE, &path, None).await
            }

            // What: add primary zone; SOA from default-soa.
            // Why: API writes and DDNS need zone to exist.
            // From: Issue #1683 | PR #1980
            pub async fn create_primary(
                &self,
                zone: &str,
                soa_edit: &str,
                key: &str,
            ) -> Result<(), String> {
                // What: TSIG-ALLOW-AXFR set on create.
                // Why: no zone may exist without its key.
                // From: Issue #1683 | PR #2017
                let body = json!({
                    "name": zone_id(zone),
                    "kind": "Master",
                    "nameservers": [],
                    "soa_edit_api": soa_edit,
                    "master_tsig_key_ids": [zone_id(key)],
                });
                self.send(Method::POST, "/zones", Some(body)).await
            }

            // What: one TSIG key; None if pdns has none.
            // Why: the state check compares, never shows.
            // From: Issue #1683 | PR #2020
            pub async fn tsigkey(&self, name: &str) -> Result<Option<Value>, String> {
                let path = format!("/tsigkeys/{}", zone_id(name));
                let answer = self.request(Method::GET, &path, None).await?;
                // What: 404 means the key is not there.
                // Why: the status says so; no text match.
                // From: Issue #1683 | PR #2020
                if answer.1 == StatusCode::NOT_FOUND {
                    return Ok(None);
                }
                serde_json::from_str(&checked(answer)?)
                    .map(Some)
                    .map_err(|e| e.to_string())
            }

            // What: create or replace one TSIG key.
            // Why: rotation keeps name; PUT needs a key.
            // From: Issue #1683 | PR #1980
            pub async fn set_tsigkey(
                &self,
                name: &str,
                algorithm: &str,
                secret: &str,
            ) -> Result<(), String> {
                let body = json!({"name": name, "algorithm": algorithm, "key": secret});
                let path = format!("/tsigkeys/{}", zone_id(name));
                let put = match self.call(Method::PUT, &path, Some(body.clone())).await {
                    Ok(_) => return Ok(()),
                    Err(e) => e,
                };
                self.send(Method::POST, "/tsigkeys", Some(body))
                    .await
                    .map_err(|e| format!("PUT: {put}; POST: {e}"))
            }

            // What: set one metadata kind of a zone.
            // Why: per-zone metadata binds the TSIG key.
            // From: Issue #1683 | PR #1980
            pub async fn set_metadata(
                &self,
                zone: &str,
                kind: &str,
                values: &[String],
            ) -> Result<(), String> {
                let path = zone_sub(zone, &format!("metadata/{kind}"));
                let body = json!({"kind": kind, "metadata": values});
                self.send(Method::PUT, &path, Some(body)).await
            }

            // What: values of a metadata kind of a zone.
            // Why: a secondary reads what the primary sets.
            // From: Issue #1683 | PR #2020
            pub async fn metadata(&self, zone: &str, kind: &str) -> Result<Vec<String>, String> {
                let path = zone_sub(zone, &format!("metadata/{kind}"));
                let v: Value = self.fetch_json(&path, &format!("metadata {kind}")).await?;
                Ok(v["metadata"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|x| x.as_str().map(str::to_string))
                    .collect())
            }

            // What: primary address of one secondary zone.
            // Why: a rerun fixes the masters of old zones.
            // From: Issue #1683 | PR #2020
            pub async fn set_masters(&self, zone: &str, masters: &[String]) -> Result<(), String> {
                let path = zone_path(zone);
                let body = json!({"masters": masters});
                self.send(Method::PUT, &path, Some(body)).await
            }

            // What: TSIG key a secondary uses for AXFR.
            // Why: the API refuses meta AXFR-MASTER-TSIG.
            // From: Issue #1683 | PR #2020
            pub async fn set_secondary_tsig(&self, zone: &str, key: &str) -> Result<(), String> {
                let path = zone_path(zone);
                let body = json!({"slave_tsig_key_ids": [zone_id(key)]});
                self.send(Method::PUT, &path, Some(body)).await
            }

            // What: all zones with serial and checks.
            // Why: sync state compares primary, secondary.
            // From: Issue #1683 | PR #1980
            pub async fn zones(&self) -> Result<Vec<Zone>, String> {
                self.fetch_json("/zones", "zone list").await
            }

            // What: send NOTIFY to all secondaries now.
            // Why: a lagging secondary is pushed at once.
            // From: Issue #1683 | PR #1980
            pub async fn notify(&self, zone: &str) -> Result<(), String> {
                self.send(Method::PUT, &zone_sub(zone, "notify"), None)
                    .await
            }

            // What: pull a secondary zone now.
            // Why: stale secondary resyncs without restart.
            // From: Issue #1683 | PR #1980
            pub async fn axfr_retrieve(&self, zone: &str) -> Result<(), String> {
                let path = zone_sub(zone, "axfr-retrieve");
                self.send(Method::PUT, &path, None).await
            }

            // What: numbers of a statistics list, summed.
            // Why: values come as text; prefix: the server.
            // From: Issue #1683 | PR #1980
            pub fn add_stats(
                out: &mut std::collections::BTreeMap<String, String>,
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

            // What: name and value of each server counter.
            // Why: the dashboard shows query counts.
            // From: Issue #1683 | PR #1980
            pub async fn statistics(&self) -> Result<Vec<(String, String)>, String> {
                let rows: Vec<Value> = self.fetch_json("/statistics", "statistics").await?;
                Ok(rows
                    .iter()
                    .filter_map(|r| Some((r["name"].as_str()?.into(), r["value"].as_str()?.into())))
                    .collect())
            }

            // What: drop cached answers for a name.
            // Why: a changed record answers at once.
            // From: Issue #1683 | PR #1980
            pub async fn flush(&self, name: &str, subtree: bool) -> Result<(), String> {
                let path = format!("/cache/flush?domain={}&subtree={subtree}", zone_id(name));
                self.send(Method::PUT, &path, None).await
            }

            // What: give a zone a signing key once.
            // Why: a new key each apply breaks every anchor
            // From: Issue #1683 | PR #2019
            pub async fn secure(&self, zone: &str) -> Result<(), String> {
                let v = self.zone_doc(zone).await?;
                if v["dnssec"].as_bool() == Some(true) {
                    return Ok(());
                }
                let keys = zone_sub(zone, "cryptokeys");
                let body = json!({"keytype": "csk", "active": true, "published": true});
                self.call(Method::POST, &keys, Some(body)).await?;
                let rectify = zone_sub(zone, "rectify");
                self.send(Method::PUT, &rectify, None).await
            }

            // What: SHA-256 DS rows of the active keys.
            // Why: the parent zone and anchors need them.
            // From: Issue #1683 | PR #2019
            pub async fn ds(&self, zone: &str) -> Result<Vec<String>, String> {
                let path = zone_sub(zone, "cryptokeys");
                let keys: Vec<Value> = self.fetch_json(&path, &format!("keys of {zone}")).await?;
                Ok(keys
                    .iter()
                    .filter(|k| k["active"].as_bool() == Some(true))
                    .flat_map(|k| k["ds"].as_array().cloned().unwrap_or_default())
                    .filter_map(|d| d.as_str().map(str::to_string))
                    .filter(|d| d.split_whitespace().nth(2) == Some("2"))
                    .collect())
            }
        }
    }

    // What: DNS name rules, zones and serial math.
    // Why: ui, watchdog, renderers agree on one rule set.
    // From: Issue #1683 | PR #1980
    pub mod dns {
        use crate::config::Settings;
        use std::cmp::Ordering;

        // What: lowercase zone name with one final dot.
        // Why: zone names compare equal in one form.
        // From: Issue #1683 | PR #1980
        pub fn canonical_zone(zone: &str) -> String {
            crate::shared::pdns::zone_id(&zone.to_ascii_lowercase())
        }

        // What: a zone or name without its final dots.
        // Why: one rule for the dotless form of a name.
        // From: Issue #1683 | PR #2020
        pub fn bare_zone(zone: &str) -> &str {
            zone.trim_end_matches('.')
        }

        // What: RFC 1035 host name check.
        // Why: SRV needs "_", RPZ wildcards need "*".
        // From: Issue #1683 | PR #1980
        pub fn is_dns_name(name: &str, underscore: bool, wildcard: bool) -> bool {
            let name = bare_zone(name);
            let label_ok = |label: &str| {
                (1..=63).contains(&label.len())
                    && !label.starts_with('-')
                    && !label.ends_with('-')
                    && label.bytes().all(|b| {
                        b.is_ascii_alphanumeric() || b == b'-' || (underscore && b == b'_')
                    })
            };
            !name.is_empty()
                && name.len() <= 253
                && name
                    .split('.')
                    .enumerate()
                    .all(|(i, l)| (wildcard && i == 0 && l == "*") || label_ok(l))
        }

        // What: CDN list row: ".name" is the whole subtree.
        // Why: cdn-domains.txt uses this leading-dot form.
        // From: Issue #1683 | PR #1980
        pub fn cdn_entry(text: &str) -> Option<(String, bool)> {
            let row = text.trim().to_ascii_lowercase();
            let (subtree, name) = match row.strip_prefix('.') {
                Some(rest) => (true, rest.to_string()),
                None => (false, row),
            };
            (name.contains('.') && is_dns_name(&name, false, false)).then_some((name, subtree))
        }

        // What: the entries of a cache domain list.
        // Why: nginx and dns share a rule; bad row fails.
        // From: Issue #1683 | PR #2020
        pub fn cdn_list(text: &str) -> Result<Vec<(String, bool)>, String> {
            let mut out = Vec::new();
            for (n, line) in text.lines().enumerate() {
                let row = line.trim();
                if row.is_empty() || row.starts_with('#') {
                    continue;
                }
                let entry = cdn_entry(row)
                    .ok_or_else(|| format!("line {}: invalid domain entry {row:?}", n + 1))?;
                out.push(entry);
            }
            Ok(out)
        }

        // What: private reverse zones from the SOT.
        // Why: RFC 1918 and ULA ranges; no list in code.
        // From: Issue #1683 | PR #1980
        pub fn private_reverse_zones(s: &Settings) -> Result<Vec<String>, String> {
            let zones = s.list("DNS_PRIVATE_REVERSE_ZONES")?;
            Ok(zones.iter().map(|z| canonical_zone(z)).collect())
        }

        // What: the two replication roles of SOT choice.
        // Why: one owner of role words; callers compare.
        // From: Issue #1683 | PR #2017
        #[derive(Clone, Copy, Debug, Eq, PartialEq)]
        pub enum Role {
            Primary,
            Secondary,
        }

        // What: methods of the replication Role.
        // Why: one reader of the role setting.
        // From: Issue #1683 | PR #2020
        impl Role {
            // What: role from DNS_REPLICATION_ROLE.
            // Why: an unknown word is an error.
            // From: Issue #1683 | PR #2017
            pub fn from_settings(s: &Settings) -> Result<Self, String> {
                match s.text("DNS_REPLICATION_ROLE")?.as_str() {
                    "primary" => Ok(Self::Primary),
                    "secondary" => Ok(Self::Secondary),
                    other => Err(format!("DNS_REPLICATION_ROLE={other} is unknown")),
                }
            }
        }

        // What: true for an IPv4 or IPv6 address.
        // Why: one owner of the test of an address text.
        // From: Issue #1683 | PR #2017
        pub fn is_ip(text: &str) -> bool {
            parse_ip(text).is_ok()
        }

        // What: the address a text holds, or an error text.
        // Why: one reader; the error names the bad text.
        // From: Issue #1683 | PR #2017
        pub fn parse_ip(text: &str) -> Result<std::net::IpAddr, String> {
            text.parse()
                .map_err(|_| format!("{text:?} is no IP address"))
        }

        // What: an address in its one written form.
        // Why: one reader; "::0:1" and "::1" are the same.
        // From: Issue #1683 | PR #2020
        pub fn canonical_ip(text: &str) -> Result<String, String> {
            parse_ip(text).map(|ip| ip.to_string())
        }

        // What: network and prefix length of "addr/len".
        // Why: one reader; host bits are cleared.
        // From: Issue #1683 | PR #2020
        pub fn parse_net(text: &str) -> Result<(std::net::IpAddr, u8), String> {
            use std::net::IpAddr;
            let bad = || format!("{text:?} is no network (address/length)");
            let (addr, len) = text.split_once('/').ok_or_else(bad)?;
            let ip = parse_ip(addr).map_err(|_| bad())?;
            let max: u8 = if ip.is_ipv4() { 32 } else { 128 };
            let len: u8 = len
                .parse()
                .ok()
                .filter(|n| *n <= max && !len.starts_with('+'))
                .ok_or_else(bad)?;
            let net = match ip {
                IpAddr::V4(v) => {
                    let mask = u32::MAX.checked_shl(32 - u32::from(len)).unwrap_or(0);
                    IpAddr::V4((u32::from(v) & mask).into())
                }
                IpAddr::V6(v) => {
                    let mask = u128::MAX.checked_shl(128 - u32::from(len)).unwrap_or(0);
                    IpAddr::V6((u128::from(v) & mask).into())
                }
            };
            Ok((net, len))
        }

        // What: "addr/len" in its one written form.
        // Why: 192.0.2.1/24 and 192.0.2.0/24 are one net.
        // From: Issue #1683 | PR #2020
        pub fn canonical_net(text: &str) -> Result<String, String> {
            parse_net(text).map(|(net, len)| format!("{net}/{len}"))
        }

        // What: true when an address lies in a network.
        // Why: one test for Kea reservations and others.
        // From: Issue #1683 | PR #2020
        pub fn net_holds(net: &str, ip: &str) -> bool {
            let (Ok((net, len)), Ok(ip)) = (parse_net(net), parse_ip(ip)) else {
                return false;
            };
            parse_net(&format!("{ip}/{len}")).is_ok_and(|(n, _)| n == net)
        }

        // What: true for a loopback address, IPv4 or IPv6.
        // Why: such an address is never a LAN address.
        // From: Issue #1683 | PR #2017
        pub fn is_loopback(text: &str) -> bool {
            parse_ip(text).is_ok_and(|ip| ip.is_loopback())
        }

        // What: HTTPS IP when HTTPS has its own LAN IP.
        // Why: dnsdist, ns2 and the DNS page share a rule.
        // From: Issue #1683 | PR #1980
        pub fn https_ip(s: &Settings) -> Result<Option<String>, String> {
            let https = s.text_or_empty("IP_HTTPS");
            let own = !https.is_empty() && https != s.text("IP_HTTP")? && !is_loopback(&https);
            // What: no HTTPS part while HTTPS is off.
            // Why: IP_HTTPS must not wake HTTPS when off.
            // From: Issue #1683 | PR #1980
            Ok((own && s.flag("HTTPS_ENABLED")?).then_some(https))
        }

        // What: true for a name below a zone, not the zone.
        // Why: only such a name gets records in that zone.
        // From: Issue #1683 | PR #2017
        pub fn is_below(name: &str, zone: &str) -> bool {
            name.ends_with(&format!(".{zone}"))
        }

        // What: true for zone itself or a name below it.
        // Why: one rule for "this name lies in that zone".
        // From: Issue #1683 | PR #2019
        pub fn is_within(name: &str, zone: &str) -> bool {
            name == zone || is_below(name, zone)
        }

        // What: longest zone of a list that holds a name.
        // Why: a record or DS goes into exactly that zone.
        // From: Issue #1683 | PR #2019
        pub fn zone_of(name: &str, zones: &[String]) -> Option<String> {
            zones
                .iter()
                .filter(|z| is_within(name, z))
                .max_by_key(|z| z.len())
                .cloned()
        }

        // What: true for a name in the reverse DNS tree.
        // Why: the reverse DNS tree is under arpa.
        // From: Issue #1683 | PR #2017
        pub fn is_reverse_name(name: &str) -> bool {
            is_below(name, "arpa.")
        }

        // What: A for an IPv4 address, AAAA for IPv6.
        // Why: one owner of the record type of an address.
        // From: Issue #1683 | PR #2017
        pub fn address_kind(address: &str) -> &'static str {
            if is_ipv6_text(address) { "AAAA" } else { "A" }
        }

        // What: true if a host text has an IPv6 form.
        // Why: one owner of the v6 test; names lack colons.
        // From: Issue #1683 | PR #2020
        pub fn is_ipv6_text(host: &str) -> bool {
            host.contains(':')
        }

        // What: host and port of host, host:port, [v6]:port
        // Why: one reader; a bare v6 address has no port.
        // From: Issue #1683 | PR #2020
        pub fn split_host_port(raw: &str) -> Result<(&str, Option<u16>), String> {
            let bad = || format!("{raw:?} is no host or host:port");
            let (host, port) = match raw.strip_prefix('[') {
                Some(rest) => {
                    let (h, tail) = rest.split_once(']').ok_or_else(bad)?;
                    match tail {
                        "" => (h, None),
                        t => (h, Some(t.strip_prefix(':').ok_or_else(bad)?)),
                    }
                }
                None if raw.matches(':').count() == 1 => raw
                    .split_once(':')
                    .map(|(h, p)| (h, Some(p)))
                    .ok_or_else(bad)?,
                None => (raw, None),
            };
            if host.is_empty() {
                return Err(bad());
            }
            let port = port.map(|p| p.parse::<u16>().ok().filter(|n| *n > 0).ok_or_else(bad));
            Ok((host, port.transpose()?))
        }

        // What: a host name; all-digit text is no name.
        // Why: is_dns_name is the one label reader.
        // From: Issue #1683 | PR #2020
        pub fn parse_name(text: &str) -> Result<String, String> {
            let numeric = bare_zone(text)
                .chars()
                .all(|c| c.is_ascii_digit() || c == '.');
            match is_dns_name(text, false, false) && !numeric {
                true => Ok(text.to_string()),
                false => Err(format!("{text:?} is no host name")),
            }
        }

        // What: host and port of "host[:port]", read.
        // Why: one reader; an address is made canonical.
        // From: Issue #1683 | PR #2020
        pub fn parse_endpoint(text: &str, names: bool) -> Result<(String, Option<u16>), String> {
            let (host, port) = split_host_port(text)?;
            let host = match parse_ip(host) {
                Ok(ip) => ip.to_string(),
                Err(_) if names => parse_name(host)?,
                Err(_) => return Err(format!("{text:?} is no IP address")),
            };
            Ok((host, port))
        }

        // What: "host[:port]" in its one written form.
        // Why: one text for one endpoint; v6 has brackets.
        // From: Issue #1683 | PR #2020
        pub fn canonical_endpoint(text: &str, names: bool) -> Result<String, String> {
            Ok(match parse_endpoint(text, names)? {
                (host, Some(port)) => host_port(&host, port),
                (host, None) => host,
            })
        }

        // What: host:port; an IPv6 address gets brackets.
        // Why: bare, nobody sees where its port starts.
        // From: Issue #1683 | PR #2017
        pub fn host_port(host: &str, port: impl std::fmt::Display) -> String {
            if is_ipv6_text(host) {
                format!("[{host}]:{port}")
            } else {
                format!("{host}:{port}")
            }
        }

        // What: the last label of a name, without dots.
        // Why: endings decide top zones and refused names.
        // From: Issue #1683 | PR #2019
        pub fn ending(name: &str) -> &str {
            let bare = bare_zone(name);
            bare.rsplit('.').next().unwrap_or(bare)
        }

        // What: checked LAN domains, main domain first.
        // Why: one rule for zones, DDNS, records and ui.
        // From: Issue #1683 | PR #2020
        pub fn validate_lan_domains(main: &str, extra: &[String]) -> Result<Vec<String>, String> {
            let mut out: Vec<String> = Vec::new();
            for raw in std::iter::once(main).chain(extra.iter().map(String::as_str)) {
                let zone = canonical_zone(raw);
                let name = bare_zone(&zone);
                // What: one label like "lan" is allowed.
                // Why: setup.sh offers it; NTA covers it.
                // From: Issue #1683 | PR #2020
                if !is_dns_name(name, false, false) {
                    return Err(format!("LAN domain {raw:?} is no domain name"));
                }
                // What: reverse, RFC 6761 endings refused
                // Why: localhost, invalid stay local
                // From: Issue #1683 | PR #2019
                match ending(name) {
                    "arpa" => return Err(format!("LAN domain {raw:?} is a reverse zone")),
                    e @ ("localhost" | "invalid") => {
                        return Err(format!("LAN domain {raw:?} ends in the special name {e}"));
                    }
                    _ => {}
                }
                if out.contains(&zone) {
                    return Err(format!("LAN domain {name} is listed twice"));
                }
                out.push(zone);
            }
            Ok(out)
        }

        // What: DHCP_DOMAIN, then DNS_EXTRA_LAN_DOMAINS.
        // Why: DHCP and the NS names use the main domain.
        // From: Issue #1683 | PR #2020
        pub fn lan_domains(s: &Settings) -> Result<Vec<String>, String> {
            let main = lan_zone(s)?;
            let main = bare_zone(&main);
            validate_lan_domains(main, &s.list("DNS_EXTRA_LAN_DOMAINS")?)
        }

        // What: LAN zone, DHCP_DOMAIN in canonical form.
        // Why: PowerDNS compares names with a trailing dot.
        // From: Issue #1683 | PR #2017
        pub fn lan_zone(s: &Settings) -> Result<String, String> {
            Ok(canonical_zone(&s.text("DHCP_DOMAIN")?))
        }

        // What: zones the stack serves itself.
        // Why: one zone per LAN domain, optional reverse.
        // From: Issue #1683 | PR #1980
        pub fn managed_zones(s: &Settings) -> Result<Vec<String>, String> {
            // What: a secondary serves the primary's zones.
            // Why: its DHCP_DOMAIN is only the SOT default.
            // From: Issue #1683 | PR #2017
            if Role::from_settings(s)? == Role::Secondary {
                return Ok(s
                    .list("DNS_SECONDARY_ZONES")?
                    .iter()
                    .map(|z| canonical_zone(z))
                    .collect());
            }
            let mut zones = lan_domains(s)?;
            if s.flag("DNS_LOCAL_REVERSE_ZONES")? {
                zones.extend(private_reverse_zones(s)?);
            }
            Ok(zones)
        }

        // What: top zones of endings the Internet lacks.
        // Why: a signed .lan needs its own top zone.
        // From: Issue #1683 | PR #2019
        pub fn top_zones(
            s: &Settings,
            psl: &crate::shared::nginx_conf::Psl,
        ) -> Result<Vec<String>, String> {
            let mut out: Vec<String> = Vec::new();
            for zone in lan_domains(s)? {
                let last = ending(&zone);
                if !psl.is_tld(last) {
                    crate::config::add_once(&mut out, &canonical_zone(last));
                }
            }
            Ok(out)
        }

        // What: the listed zone that holds a zone's parent.
        // Why: the DS of a zone belongs in that parent.
        // From: Issue #1683 | PR #2019
        pub fn parent_zone(zone: &str, zones: &[String]) -> Option<String> {
            let (_, up) = zone.split_once('.')?;
            zone_of(up, zones)
        }

        // What: the old extra zone local.<domain>.
        // Why: an old install holds it; its records merge.
        // From: Issue #1683 | PR #2020
        pub fn legacy_local_zone(lan: &str) -> String {
            canonical_zone(&format!("local.{}", bare_zone(lan)))
        }

        // What: compare serials by RFC 1982.
        // Why: serials wrap; half space apart is unknown.
        // From: Issue #1683 | PR #1980
        pub fn serial_cmp(a: u32, b: u32) -> Option<Ordering> {
            match b.wrapping_sub(a) {
                0 => Some(Ordering::Equal),
                0x8000_0000 => None,
                d if d < 0x8000_0000 => Some(Ordering::Less),
                _ => Some(Ordering::Greater),
            }
        }

        // What: SOA answer of one DNS server.
        // Why: aa marks pdns data; serial shows the state.
        // From: Issue #1683 | PR #2017
        #[derive(Clone, Debug, Eq, PartialEq, serde::Serialize)]
        pub struct Soa {
            pub authoritative: bool,
            pub rcode: u8,
            pub serial: Option<u32>,
        }

        // What: methods of the SOA answer Soa.
        // Why: aa and rcode say if a server holds a zone.
        // From: Issue #1683 | PR #2020
        impl Soa {
            // What: true for an aa answer without an error.
            // Why: only such server holds the zone itself.
            // From: Issue #1683 | PR #2017
            pub fn serves_zone(&self) -> bool {
                self.authoritative && self.rcode == 0
            }
        }

        // What: bytes of a DNS message header.
        // Why: RFC 1035 4.1.1; replies shorter are cut.
        // From: Issue #1683 | PR #2020
        const HEADER_LEN: usize = 12;

        // What: record type number of A.
        // Why: RFC 1035 code; parser and table share it.
        // From: Issue #1683 | PR #2020
        const TYPE_A: u16 = 1;

        // What: record type number of NS.
        // Why: RFC 1035 code; parser and table share it.
        // From: Issue #1683 | PR #2020
        const TYPE_NS: u16 = 2;

        // What: record type number of CNAME.
        // Why: RFC 1035 code; parser and table share it.
        // From: Issue #1683 | PR #2020
        const TYPE_CNAME: u16 = 5;

        // What: record type number of SOA.
        // Why: RFC 1035 code; parser and table share it.
        // From: Issue #1683 | PR #2020
        const TYPE_SOA: u16 = 6;

        // What: record type number of PTR.
        // Why: RFC 1035 code; parser and table share it.
        // From: Issue #1683 | PR #2020
        const TYPE_PTR: u16 = 12;

        // What: record type number of MX.
        // Why: RFC 1035 code; parser and table share it.
        // From: Issue #1683 | PR #2020
        const TYPE_MX: u16 = 15;

        // What: record type number of TXT.
        // Why: RFC 1035 code; parser and table share it.
        // From: Issue #1683 | PR #2020
        const TYPE_TXT: u16 = 16;

        // What: record type number of AAAA.
        // Why: RFC 3596 code; parser and table share it.
        // From: Issue #1683 | PR #2020
        const TYPE_AAAA: u16 = 28;

        // What: record type number of SRV.
        // Why: RFC 2782 code; parser and table share it.
        // From: Issue #1683 | PR #2020
        const TYPE_SRV: u16 = 33;

        // What: record type number of DS.
        // Why: RFC 4034 code; parser and table share it.
        // From: Issue #1683 | PR #2020
        const TYPE_DS: u16 = 43;

        // What: record type number of DNSKEY.
        // Why: RFC 4034 code; parser and table share it.
        // From: Issue #1683 | PR #2020
        const TYPE_DNSKEY: u16 = 48;

        // What: record type number of HTTPS.
        // Why: RFC 9460 code; parser and table share it.
        // From: Issue #1683 | PR #2020
        const TYPE_HTTPS: u16 = 65;

        // What: record type number of CAA.
        // Why: RFC 8659 code; parser and table share it.
        // From: Issue #1683 | PR #2020
        const TYPE_CAA: u16 = 257;

        // What: a DNS question, class IN, RD on or off.
        // Why: one wire builder for SOA probes and queries.
        // From: Issue #1683 | PR #2020
        pub fn query(id: u16, name: &str, qtype: u16, rd: bool) -> Result<Vec<u8>, String> {
            let mut q = id.to_be_bytes().to_vec();
            q.extend_from_slice(&[u8::from(rd), 0, 0, 1, 0, 0, 0, 0, 0, 0]);
            for label in bare_zone(name).split('.') {
                if label.is_empty() || label.len() > 63 {
                    return Err(format!("zone {name:?} is no DNS name"));
                }
                q.push(label.len() as u8);
                q.extend_from_slice(label.as_bytes());
            }
            q.push(0);
            q.extend_from_slice(&qtype.to_be_bytes());
            q.extend_from_slice(&[0, 1]);
            Ok(q)
        }

        // What: SOA query for one zone, RD bit off.
        // Why: without RD a recursor sends no aa answer.
        // From: Issue #1683 | PR #2017
        pub fn soa_query(id: u16, zone: &str) -> Result<Vec<u8>, String> {
            query(id, zone, TYPE_SOA, false)
        }

        // What: type number of a record type name.
        // Why: the CLI takes A, AAAA, SOA ... as words.
        // From: Issue #1683 | PR #2020
        pub fn qtype(word: &str) -> Result<u16, String> {
            // What: record type names and numbers.
            // Why: the CLI takes names, the wire numbers.
            // From: Issue #1683 | PR #2020
            const TYPES: [(&str, u16); 13] = [
                ("A", TYPE_A),
                ("NS", TYPE_NS),
                ("CNAME", TYPE_CNAME),
                ("SOA", TYPE_SOA),
                ("PTR", TYPE_PTR),
                ("MX", TYPE_MX),
                ("TXT", TYPE_TXT),
                ("AAAA", TYPE_AAAA),
                ("SRV", TYPE_SRV),
                ("DS", TYPE_DS),
                ("DNSKEY", TYPE_DNSKEY),
                ("HTTPS", TYPE_HTTPS),
                ("CAA", TYPE_CAA),
            ];
            let up = word.to_ascii_uppercase();
            TYPES
                .iter()
                .find(|(n, _)| *n == up)
                .map(|(_, v)| *v)
                .or_else(|| up.strip_prefix("TYPE").and_then(|n| n.parse().ok()))
                .ok_or_else(|| format!("{word}: unknown record type"))
        }

        // What: end of a DNS name at offset at.
        // Why: answers use labels and compression pointers.
        // From: Issue #1683 | PR #2017
        fn name_end(msg: &[u8], mut at: usize) -> Result<usize, String> {
            loop {
                let len = *msg.get(at).ok_or("DNS name is cut off")?;
                match len & 0xc0 {
                    0 if len == 0 => return Ok(at + 1),
                    0 => at += 1 + usize::from(len),
                    0xc0 if at + 1 < msg.len() => return Ok(at + 2),
                    _ => return Err("DNS name is cut off or bad".into()),
                }
            }
        }

        // What: a dotted DNS name at offset at.
        // Why: answers hold names with compression.
        // From: Issue #1683 | PR #2020
        fn name_text(msg: &[u8], mut at: usize) -> Result<String, String> {
            let mut out = Vec::new();
            for _ in 0..128 {
                let len = *msg.get(at).ok_or("DNS name is cut off")?;
                match len & 0xc0 {
                    0 if len == 0 => return Ok(format!("{}.", out.join("."))),
                    0 => {
                        let l = msg
                            .get(at + 1..at + 1 + usize::from(len))
                            .ok_or("DNS name is cut off")?;
                        out.push(String::from_utf8_lossy(l).into_owned());
                        at += 1 + usize::from(len);
                    }
                    0xc0 => {
                        let lo = *msg.get(at + 1).ok_or("DNS name is cut off")?;
                        at = (usize::from(len & 0x3f) << 8) | usize::from(lo);
                    }
                    _ => return Err("DNS name is bad".into()),
                }
            }
            Err("DNS name loops".into())
        }

        // What: one answer record: name, type, ttl, data.
        // Why: the query check shows what the server said.
        // From: Issue #1683 | PR #2020
        #[derive(Clone, Debug, serde::Serialize)]
        pub struct Record {
            pub name: String,
            pub rtype: u16,
            pub ttl: u32,
            pub data: String,
        }

        // What: flags and answer records of one reply.
        // Why: SOA probes and queries read one parser.
        // From: Issue #1683 | PR #2020
        #[derive(Clone, Debug, serde::Serialize)]
        pub struct Reply {
            pub authoritative: bool,
            pub truncated: bool,
            pub rcode: u8,
            pub answers: Vec<Record>,
        }

        // What: aa, tc, rcode and answers of a reply.
        // Why: the id must match the query sent.
        // From: Issue #1683 | PR #2020
        pub fn reply(id: u16, msg: &[u8]) -> Result<Reply, String> {
            let cut = || "DNS reply is cut off".to_string();
            let word = |at: usize| {
                msg.get(at..at + 2)
                    .map(|b| u16::from_be_bytes([b[0], b[1]]))
                    .ok_or_else(cut)
            };
            // What: a reply shorter than the header is cut.
            // Why: the flag bytes are read before counts.
            // From: Issue #1683 | PR #2020
            if msg.len() < HEADER_LEN {
                return Err(cut());
            }
            if word(0)? != id || msg[2] & 0x80 == 0 {
                return Err("DNS reply does not match the query".into());
            }
            let mut at = HEADER_LEN;
            for _ in 0..word(4)? {
                at = name_end(msg, at)? + 4;
            }
            let mut answers = Vec::new();
            for _ in 0..word(6)? {
                let name = name_text(msg, at)?;
                at = name_end(msg, at)?;
                let rtype = word(at)?;
                let ttl = (u32::from(word(at + 4)?) << 16) | u32::from(word(at + 6)?);
                let start = at + 10;
                let end = start + usize::from(word(at + 8)?);
                let rd = msg.get(start..end).ok_or_else(cut)?;
                let data = match (rtype, rd.len()) {
                    (TYPE_A, 4) => std::net::Ipv4Addr::new(rd[0], rd[1], rd[2], rd[3]).to_string(),
                    (TYPE_AAAA, 16) => {
                        let mut b = [0u8; 16];
                        b.copy_from_slice(rd);
                        std::net::Ipv6Addr::from(b).to_string()
                    }
                    (TYPE_NS | TYPE_CNAME | TYPE_PTR, _) => name_text(msg, start)?,
                    (TYPE_SOA, _) => {
                        let p = name_end(msg, name_end(msg, start)?)?;
                        let b = msg.get(p..p + 4).filter(|_| p + 4 <= end).ok_or_else(cut)?;
                        let serial = u32::from_be_bytes([b[0], b[1], b[2], b[3]]);
                        format!("{} serial {serial}", name_text(msg, start)?)
                    }
                    _ => rd.iter().map(|b| format!("{b:02x}")).collect(),
                };
                answers.push(Record {
                    name,
                    rtype,
                    ttl,
                    data,
                });
                at = end;
            }
            Ok(Reply {
                authoritative: msg[2] & 0x04 != 0,
                truncated: msg[2] & 0x02 != 0,
                rcode: msg[3] & 0x0f,
                answers,
            })
        }

        // What: aa bit, rcode and serial of a reply.
        // Why: the id must match the query sent.
        // From: Issue #1683 | PR #2017
        pub fn soa_reply(id: u16, msg: &[u8]) -> Result<Soa, String> {
            let r = reply(id, msg)?;
            let serial = r
                .answers
                .iter()
                .find(|a| a.rtype == TYPE_SOA)
                .and_then(|a| a.data.rsplit(' ').next()?.parse().ok());
            Ok(Soa {
                authoritative: r.authoritative,
                rcode: r.rcode,
                serial,
            })
        }

        // What: an unbound UDP socket of one address family
        // Why: an IPv4 socket cannot send to IPv6 address.
        // From: Issue #1683 | PR #2017
        pub fn udp_for(v6: bool) -> std::io::Result<std::net::UdpSocket> {
            std::net::UdpSocket::bind(if v6 { "[::]:0" } else { "0.0.0.0:0" })
        }

        // What: one SOA query over UDP, no RD.
        // Why: no dig in the ui image; std and rand only.
        // From: Issue #1683 | PR #2017
        fn soa_blocking(
            addr: std::net::SocketAddr,
            zone: &str,
            wait: std::time::Duration,
        ) -> Result<Soa, String> {
            let (id, buf) = exchange(addr, &|id| soa_query(id, zone), wait)?;
            soa_reply(id, &buf)
        }

        // What: the SOA of a zone from one address, no RD.
        // Why: callers pass the wait of their own SOT key.
        // From: Issue #1683 | PR #2020
        pub async fn soa_at(
            addr: std::net::SocketAddr,
            zone: &str,
            wait: std::time::Duration,
        ) -> Result<Soa, String> {
            let zone = zone.to_string();
            tokio::task::spawn_blocking(move || soa_blocking(addr, &zone, wait))
                .await
                .map_err(|e| e.to_string())?
        }

        // What: send one question over UDP, get reply.
        // Why: SOA probe and query check share the socket.
        // From: Issue #1683 | PR #2020
        fn exchange(
            addr: std::net::SocketAddr,
            build: &dyn Fn(u16) -> Result<Vec<u8>, String>,
            wait: std::time::Duration,
        ) -> Result<(u16, Vec<u8>), String> {
            let id: u16 = rand::random();
            let question = build(id)?;
            let err = |e: std::io::Error| format!("{addr}: {e}");
            let sock = udp_for(addr.is_ipv6()).map_err(err)?;
            sock.connect(addr).map_err(err)?;
            sock.set_read_timeout(Some(wait)).map_err(err)?;
            sock.send(&question).map_err(err)?;
            let mut buf = [0u8; 4096];
            let n = sock.recv(&mut buf).map_err(err)?;
            Ok((id, buf[..n].to_vec()))
        }

        // What: one question over UDP; RD as asked.
        // Why: the query check reads the full reply.
        // From: Issue #1683 | PR #2020
        pub fn ask(
            addr: std::net::SocketAddr,
            name: &str,
            qtype: u16,
            rd: bool,
            wait: std::time::Duration,
        ) -> Result<Reply, String> {
            let (id, buf) = exchange(addr, &|id| query(id, name, qtype, rd), wait)?;
            reply(id, &buf)
        }
    }

    // What: DHCP mode and option rules.
    // Why: Kea and dnsmasq get the same checked input.
    // From: Issue #1683 | PR #1980
    pub mod dhcp {
        use crate::config::Settings;

        // What: DNS servers handed to DHCP clients.
        // Why: setup.sh: empty means the stack, IP_HTTP.
        // From: Issue #1683 | PR #2020
        pub fn dns_addrs(s: &Settings) -> Result<Vec<String>, String> {
            let mut dns = s.list("DHCP_DNS_SERVERS")?;
            if dns.is_empty() {
                dns = ["DHCP_DNS_PRIMARY", "DHCP_DNS_SECONDARY"]
                    .iter()
                    .filter_map(|k| s.text(k).ok())
                    .collect();
            }
            if dns.is_empty() {
                dns.extend(s.text("IP_HTTP").ok());
            }
            Ok(ipv4_of(&dns, "DHCP_DNS_SERVERS"))
        }

        // What: own NTP for DHCP: NTP and NTP_AUTO_DHCP on.
        // Why: one rule for the render and the DHCP page.
        // From: Issue #1683 | PR #2020
        pub fn own_ntp(s: &Settings) -> Result<bool, String> {
            Ok(s.flag("NTP_ENABLED")? && s.flag("NTP_AUTO_DHCP")?)
        }

        // What: DHCP_NTP_SERVERS: IPv4 text; names resolve
        // Why: option 42 holds IPs; dead names are skipped.
        // From: Issue #1683 | PR #1980
        pub fn ntp_addrs(s: &Settings) -> Result<Vec<String>, String> {
            // What: IP_HTTP while own NTP is handed out.
            // Why: LanCache-NG-NTP answers on the HTTP IP.
            // From: Issue #1683 | PR #2017
            if own_ntp(s)? {
                return Ok(vec![s.text("IP_HTTP")?]);
            }
            Ok(ipv4_of(&s.list("DHCP_NTP_SERVERS")?, "DHCP_NTP_SERVERS"))
        }

        // What: IPv4 text of each host; names resolve.
        // Why: option 42 holds IPs; a dead name is a note.
        // From: Issue #1683 | PR #2020
        pub fn ipv4_of(hosts: &[String], key: &str) -> Vec<String> {
            use std::net::ToSocketAddrs as _;
            let mut addrs = Vec::new();
            for host in hosts {
                if let Ok(std::net::IpAddr::V4(ip)) = crate::shared::dns::parse_ip(host) {
                    addrs.push(ip.to_string());
                    continue;
                }
                let found = (host.as_str(), 0)
                    .to_socket_addrs()
                    .map_err(|e| format!("cannot resolve {host}: {e}"))
                    .and_then(|mut all| {
                        all.find_map(|a| match a {
                            std::net::SocketAddr::V4(v4) => Some(v4.ip().to_string()),
                            std::net::SocketAddr::V6(_) => None,
                        })
                        .ok_or_else(|| format!("{host} has no IPv4 address"))
                    });
                // What: a dead name drops one address.
                // Why: no DNS yet must not stop every file.
                // From: Issue #1683 | PR #2020
                match found {
                    Ok(ip) => addrs.push(ip),
                    Err(e) => crate::shared::render::note(format!("{key}: {e}; left out")),
                }
            }
            if addrs.is_empty() && !hosts.is_empty() {
                crate::shared::render::note(format!("{key}: no address left; option off"));
            }
            addrs
        }

        // What: the four DHCP modes of the SOT choice.
        // Why: exactly one program serves DHCP.
        // From: Issue #1683 | PR #1980
        #[derive(Clone, Copy, Debug, Eq, PartialEq)]
        pub enum Mode {
            Off,
            Kea,
            DnsmasqProxy,
            DnsmasqRelay,
        }

        // What: methods of the DHCP Mode.
        // Why: a word and a mode map both ways.
        // From: Issue #1683 | PR #2020
        impl Mode {
            // What: mode from DHCP_MODE.
            // Why: an unknown word is an error.
            // From: Issue #1683 | PR #1980
            pub fn from_settings(s: &Settings) -> Result<Self, String> {
                Self::from_word(&s.text("DHCP_MODE")?)
            }

            // What: mode from its SOT word.
            // Why: a form sends same word as the setting.
            // From: Issue #1683 | PR #2017
            pub fn from_word(word: &str) -> Result<Self, String> {
                match word {
                    "off" => Ok(Self::Off),
                    "kea" => Ok(Self::Kea),
                    "dnsmasq-proxy" => Ok(Self::DnsmasqProxy),
                    "dnsmasq-relay" => Ok(Self::DnsmasqRelay),
                    other => Err(format!("DHCP_MODE {other:?} has no handler")),
                }
            }

            // What: true for the two dnsmasq modes.
            // Why: proxy, relay share one dnsmasq daemon.
            // From: Issue #1683 | PR #2017
            pub fn is_dnsmasq(self) -> bool {
                matches!(self, Self::DnsmasqProxy | Self::DnsmasqRelay)
            }
        }

        // What: the dhcp service name while mode is off.
        // Why: pages hide it; apply and watch keep it off.
        // From: Issue #1683 | PR #2017
        pub fn off_service(s: &Settings) -> Result<Option<String>, String> {
            if Mode::from_settings(s)? != Mode::Off {
                return Ok(None);
            }
            s.text("DHCP_SERVICE").map(Some)
        }

        // What: an option the ui sets by its own field.
        // Why: custom rows must not override these.
        // From: Issue #1683 | PR #1980
        #[derive(Clone, Copy, Debug, Eq, PartialEq)]
        pub struct Managed {
            pub name: &'static str,
            pub code: u8,
        }

        // What: options with own fields (RFC 2132, 3397).
        // Why: names and codes are fixed by the RFCs.
        // From: Issue #1683 | PR #1980
        pub const MANAGED: [Managed; 5] = [
            ROUTERS,
            DNS_SERVERS,
            DOMAIN_NAME,
            NTP_SERVERS,
            DOMAIN_SEARCH,
        ];

        // What: each managed option by its own name.
        // Why: render and ui name option, never its text.
        // From: Issue #1683 | PR #2017
        pub const ROUTERS: Managed = Managed {
            name: "routers",
            code: 3,
        };
        // What: option 6, DNS servers.
        // Why: one named option for render and ui.
        // From: Issue #1683 | PR #2020
        pub const DNS_SERVERS: Managed = Managed {
            name: "domain-name-servers",
            code: 6,
        };
        // What: option 15, domain name.
        // Why: one named option for render and ui.
        // From: Issue #1683 | PR #2020
        pub const DOMAIN_NAME: Managed = Managed {
            name: "domain-name",
            code: 15,
        };
        // What: option 42, NTP servers.
        // Why: one named option for render and ui.
        // From: Issue #1683 | PR #2020
        pub const NTP_SERVERS: Managed = Managed {
            name: "ntp-servers",
            code: 42,
        };
        // What: option 119, domain search.
        // Why: one named option for render and ui.
        // From: Issue #1683 | PR #2020
        pub const DOMAIN_SEARCH: Managed = Managed {
            name: "domain-search",
            code: 119,
        };

        // What: value of one Kea option in a subnet.
        // Why: forms show options by name, Kea stores list.
        // From: Issue #1683 | PR #1980
        pub fn option_data(subnet: &serde_json::Value, name: &str) -> String {
            let rows = subnet["option-data"].as_array().into_iter().flatten();
            let hit = rows.into_iter().find(|o| o["name"] == name);
            hit.and_then(|o| o["data"].as_str())
                .unwrap_or_default()
                .to_string()
        }

        // What: check a custom option code.
        // Why: 0 and 255 are pad/end; managed have fields.
        // From: Issue #1683 | PR #1980
        pub fn option_code(raw: &str) -> Result<u8, String> {
            let code: u8 = raw
                .trim()
                .parse()
                .map_err(|_| format!("option code {raw:?} must be 1..=254"))?;
            if code == 0 || code == u8::MAX {
                return Err(format!("option code {code} is reserved"));
            }
            if MANAGED.iter().any(|m| m.code == code) {
                return Err(format!("option code {code} has its own field"));
            }
            Ok(code)
        }

        // What: parse CODE:VALUE lines.
        // Why: one checked list for Kea and dnsmasq.
        // From: Issue #1683 | PR #1980
        pub fn custom_options(s: &Settings, raw: &str) -> Result<Vec<(u8, String)>, String> {
            let max = s.num::<usize>("DHCP_OPTION_DATA_MAX")?;
            let mut out = Vec::new();
            for (n, line) in raw.lines().map(str::trim).enumerate() {
                if line.is_empty() {
                    continue;
                }
                let at = |m: String| format!("line {}: {m}", n + 1);
                let (code, data) = line
                    .split_once(':')
                    .ok_or_else(|| at("expected CODE:VALUE".into()))?;
                let data = data.trim();
                if data.is_empty()
                    || data.len() > max
                    || !crate::config::safe(crate::config::Syntax::Semi, data)
                {
                    return Err(at(format!(
                        "value must be 1..={max} bytes, one line, no ';'"
                    )));
                }
                out.push((option_code(code).map_err(at)?, data.to_string()));
            }
            Ok(out)
        }

        // What: valid and max lifetime of a lease.
        // Why: SOT bounds; max is a factor of valid.
        // From: Issue #1683 | PR #1980
        pub fn lease_limits(s: &Settings, lease: u64) -> Result<(u64, u64), String> {
            let min = s.uint("DHCP_LEASE_TIME_MIN")?;
            let max = s.uint("DHCP_LEASE_TIME_MAX")?;
            if !(min..=max).contains(&lease) {
                return Err(format!("lease {lease} outside {min}..={max}"));
            }
            let longest = lease
                .saturating_mul(s.uint("DHCP_MAX_LEASE_FACTOR")?)
                .min(max);
            Ok((lease, longest))
        }
    }

    // What: minimal Docker Engine API client.
    // Why: ui and watchdog list, inspect, start and exec.
    // From: Issue #1683 | PR #1980
    pub mod docker {
        use reqwest::Method;
        use serde_json::{Value, json};
        use std::time::Duration;

        // What: compose label of the project name.
        // Why: fixed by Docker Compose.
        // From: Issue #1683 | PR #1980
        pub const PROJECT_LABEL: &str = "com.docker.compose.project";

        // What: compose label of the service name.
        // Why: fixed by Docker Compose.
        // From: Issue #1683 | PR #1980
        pub const SERVICE_LABEL: &str = "com.docker.compose.service";

        // What: the Docker state word of a live container.
        // Why: inspect, list rows and wishes share it.
        // From: Issue #1683 | PR #2020
        const RUNNING: &str = "running";

        // What: what a user wants of a container.
        // Why: the beambar, REST and CLI send it as a word.
        // From: Issue #1683 | PR #2020
        #[derive(Clone, Copy, Debug, Eq, PartialEq)]
        pub enum Wish {
            Run,
            Stop,
        }

        // What: methods of the container Wish.
        // Why: a word and a wish map both ways.
        // From: Issue #1683 | PR #2020
        impl Wish {
            // What: the wish of a boolean: true runs.
            // Why: set_wanted and the CLI pass run or not.
            // From: Issue #1683 | PR #2020
            pub fn of(run: bool) -> Self {
                if run { Self::Run } else { Self::Stop }
            }

            // What: true when the wish is to run.
            // Why: callers hand a boolean to set_wanted.
            // From: Issue #1683 | PR #2020
            pub fn runs(self) -> bool {
                self == Self::Run
            }

            // What: the wire word: running or stopped.
            // Why: JSON bodies carry it, never a number.
            // From: Issue #1683 | PR #2020
            pub fn word(self) -> &'static str {
                match self {
                    Self::Run => RUNNING,
                    Self::Stop => "stopped",
                }
            }

            // What: the wish of a wire word, or none.
            // Why: an unknown word is refused, not guessed.
            // From: Issue #1683 | PR #2020
            pub fn from_word(word: &str) -> Option<Self> {
                [Self::Run, Self::Stop]
                    .into_iter()
                    .find(|w| w.word() == word)
            }
        }

        // What: Docker health of one container.
        // Why: degraded and starting are not failures.
        // From: Issue #1683 | PR #1980
        #[derive(Debug, PartialEq)]
        pub enum Health {
            Healthy,
            Degraded,
            Starting,
            Unhealthy,
            Stopped(String),
            Unknown(String),
        }

        // What: methods of the container Health.
        // Why: state, word and colour have one rule.
        // From: Issue #1683 | PR #2020
        impl Health {
            // What: read docker inspect State.
            // Why: newest check output DEGRADED: refines ok
            // From: Issue #1296 | PR #1983
            pub fn from_inspect(inspect: &Value) -> Self {
                let state = inspect.pointer("/State/Status").and_then(Value::as_str);
                if state != Some(RUNNING) {
                    return Health::Stopped(state.unwrap_or("unknown").into());
                }
                let status = inspect
                    .pointer("/State/Health/Status")
                    .and_then(Value::as_str);
                let degraded = last_check(inspect)
                    .lines()
                    .any(|l| l.starts_with("DEGRADED: "));
                match status.unwrap_or("none") {
                    "healthy" if degraded => Health::Degraded,
                    "healthy" | "none" => Health::Healthy,
                    "starting" => Health::Starting,
                    "unhealthy" => Health::Unhealthy,
                    other => Health::Unknown(other.into()),
                }
            }

            // What: the state word for logs and alarm file.
            // Why: a stopped one names its Docker state.
            // From: Issue #1683 | PR #1980
            pub fn word(&self) -> String {
                match self {
                    Health::Healthy => "healthy".into(),
                    Health::Degraded => "degraded".into(),
                    Health::Starting => "starting".into(),
                    Health::Unhealthy => "unhealthy".into(),
                    Health::Stopped(s) | Health::Unknown(s) => s.clone(),
                }
            }

            // What: the one colour rule of bar and watchdog
            // Why: a stop user wanted is gray, else red.
            // From: Issue #1683 | PR #2020
            pub fn colour(&self, wanted: bool) -> &'static str {
                match self {
                    Health::Healthy => "green",
                    Health::Degraded => "amber",
                    Health::Starting | Health::Unknown(_) => "yellow",
                    Health::Unhealthy => "red",
                    Health::Stopped(_) if wanted => "red",
                    Health::Stopped(_) => "gray",
                }
            }

            // What: true for unhealthy or stopped.
            // Why: only these count toward a restart.
            // From: Issue #1683 | PR #1980
            pub fn failing(&self) -> bool {
                matches!(self, Health::Unhealthy | Health::Stopped(_))
            }
        }

        // What: output of the newest health check.
        // Why: it names the reason of a bad state.
        // From: Issue #1683 | PR #1980
        pub fn last_check(inspect: &Value) -> &str {
            inspect
                .pointer("/State/Health/Log")
                .and_then(Value::as_array)
                .and_then(|log| log.last())
                .and_then(|e| e["Output"].as_str())
                .unwrap_or_default()
        }

        // What: compose service of a container row, if any.
        // Why: one reader of the service label of a row.
        // From: Issue #1683 | PR #2017
        pub fn service_of(row: &serde_json::Value) -> Option<&str> {
            row["Labels"][SERVICE_LABEL].as_str()
        }

        // What: name of a container row, without the slash.
        // Why: Docker lists names as "/name".
        // From: Issue #1683 | PR #2017
        pub fn name_of(row: &serde_json::Value) -> Option<&str> {
            row["Names"][0].as_str().map(|n| n.trim_start_matches('/'))
        }

        // What: the rows of one compose service in a list.
        // Why: each lookup by service reads the label so.
        // From: Issue #1683 | PR #2020
        pub fn rows_of<'a>(
            list: &'a [serde_json::Value],
            service: &'a str,
        ) -> impl Iterator<Item = &'a serde_json::Value> {
            list.iter().filter(move |r| service_of(r) == Some(service))
        }

        // What: true if a list row says the container runs.
        // Why: list rows carry State; inspect has its own.
        // From: Issue #1683 | PR #2020
        pub fn is_running(row: &serde_json::Value) -> bool {
            row["State"].as_str() == Some(RUNNING)
        }

        // What: one stack container with its full state.
        // Why: the bar and the watchdog read one list.
        // From: Issue #1683 | PR #2020
        pub struct Member {
            pub service: String,
            pub name: String,
            pub status: Value,
            pub inspect: Result<Value, String>,
            pub stopped_by_user: bool,
            pub mode_off: bool,
        }

        // What: methods of the stack Member.
        // Why: user and mode decide if it is wanted.
        // From: Issue #1683 | PR #2020
        impl Member {
            // What: false if user or DHCP off stopped it.
            // Why: one wanted rule for bar and watchdog.
            // From: Issue #1683 | PR #2020
            pub fn wanted(&self) -> bool {
                !(self.stopped_by_user || self.mode_off)
            }
        }

        // What: the Docker call limit from DOCKER_TIMEOUT.
        // Why: every Docker call waits the same SOT time.
        // From: Issue #1683 | PR #2020
        pub fn timeout(s: &crate::config::Settings) -> Result<Duration, String> {
            Ok(Duration::from_secs(s.uint("DOCKER_TIMEOUT")?))
        }

        // What: the Docker client at DOCKER_ENDPOINT.
        // Why: ui, CLI and watchdog reach one engine.
        // From: Issue #1683 | PR #2020
        pub fn client(s: &crate::config::Settings) -> Result<Api, String> {
            Api::new(
                &s.text("DOCKER_ENDPOINT")?,
                crate::shared::http::max_body(s)?,
            )
        }

        // What: every service container with its inspect.
        // Why: one stack reader; callers decide on errors.
        // From: Issue #1683 | PR #2020
        pub async fn members(
            api: &Api,
            s: &crate::config::Settings,
        ) -> Result<Vec<Member>, String> {
            let limit = timeout(s)?;
            let stopped = s.list("SERVICES_STOPPED")?;
            let off = crate::shared::dhcp::off_service(s)?;
            let mut out = Vec::new();
            for row in api.stack(s).await? {
                let Some(service) = service_of(&row) else {
                    continue;
                };
                let name = name_of(&row).unwrap_or(service).to_string();
                let inspect = api.inspect(&name, limit).await.map_err(|e| e.to_string());
                out.push(Member {
                    service: service.to_string(),
                    name,
                    status: row["Status"].clone(),
                    inspect,
                    stopped_by_user: stopped.iter().any(|x| x == service),
                    mode_off: off.as_deref() == Some(service),
                });
            }
            Ok(out)
        }

        // What: {"state","services":[..]} of the stack.
        // Why: the beambar, REST and CLI read one shape.
        // From: Issue #1683 | PR #2020
        pub async fn status_json(api: &Api, s: &crate::config::Settings) -> Value {
            let list = match members(api, s).await {
                Ok(list) => list,
                Err(e) => return json!({"state": "unavailable", "error": e}),
            };
            let mut rows: Vec<Value> = Vec::new();
            for m in list {
                // What: an inspect error reads as no state.
                // Why: the bar still shows the others.
                // From: Issue #1683 | PR #2020
                let inspect = m.inspect.clone().unwrap_or_default();
                let health = Health::from_inspect(&inspect);
                let colour = health.colour(m.wanted());
                // What: last health output when not green.
                // Why: a fail count names no reason.
                // From: Issue #1683 | PR #1980
                let reason = match colour {
                    "red" | "yellow" | "amber" => last_check(&inspect).trim().to_string(),
                    _ => String::new(),
                };
                rows.push(
                    json!({"name": m.service, "status": colour, "health": m.status,
                    "reason": reason, "mode_off": m.mode_off,
                    "stopped_by_user": m.stopped_by_user}),
                );
            }
            json!({"state": "ok", "services": rows})
        }

        // What: engine reachable, versions, stack size.
        // Why: one check for REST and the CLI.
        // From: Issue #1683 | PR #2020
        pub async fn engine_check(api: &Api, s: &crate::config::Settings) -> Result<Value, String> {
            let endpoint = s.text("DOCKER_ENDPOINT")?;
            let limit = timeout(s)?;
            let project = s.text("COMPOSE_PROJECT")?;
            let mut v = json!({"endpoint": endpoint, "project": project});
            match api.version(limit).await {
                Ok(ver) => {
                    v["version"] = ver["Version"].clone();
                    v["api_version"] = ver["ApiVersion"].clone();
                }
                Err(e) => {
                    v["ok"] = json!(false);
                    v["error"] = json!(e.to_string());
                    return Ok(v);
                }
            }
            match api.stack(s).await {
                Ok(rows) => {
                    v["ok"] = json!(true);
                    v["containers"] = json!(rows.len());
                }
                Err(e) => {
                    v["ok"] = json!(false);
                    v["error"] = json!(e);
                }
            }
            Ok(v)
        }

        // What: what one system command does.
        // Why: the match runs these; the table names them.
        // From: Issue #1683 | PR #2020
        #[derive(Clone, Copy, PartialEq)]
        enum Op {
            Status,
            Docker,
            Plan,
            Apply,
            Render,
            Container,
            Ui,
            Service,
            Time,
            Snapshot,
        }

        // What: every command of the system group.
        // Why: help, errors and the choice read this table.
        // From: Issue #1683 | PR #2020
        const COMMANDS: [(&str, crate::shared::cli::Entry<Op>); 10] = [
            ("status", crate::shared::cli::row(Op::Status, "status")),
            ("docker", crate::shared::cli::row(Op::Docker, "docker")),
            ("plan", crate::shared::cli::row(Op::Plan, "plan")),
            ("apply", crate::shared::cli::row(Op::Apply, "apply")),
            (
                "render",
                crate::shared::cli::row(Op::Render, "render [owner|path]"),
            ),
            (
                "container",
                crate::shared::cli::row(Op::Container, "container <service> start|stop"),
            ),
            ("ui", crate::shared::cli::row(Op::Ui, "ui restart")),
            (
                "service",
                crate::shared::cli::row(
                    Op::Service,
                    "service <container> <program> restart|reload",
                ),
            ),
            ("time", crate::shared::cli::row(Op::Time, "time")),
            (
                "snapshot",
                crate::shared::cli::row(Op::Snapshot, "snapshot list|save|restore <id>"),
            ),
        ];

        // What: lancache-ng system status: stack as JSON.
        // Why: stack reads have their CLI with their owner.
        // From: Issue #1683 | PR #2020
        pub async fn run(args: &[String]) -> Result<(), String> {
            let s = crate::config::Settings::from_process()?;
            use crate::shared::cli;
            use crate::shared::http::Body;
            let words: Vec<&str> = args.iter().map(String::as_str).collect();
            let op = cli::op_of(&COMMANDS, args.first());
            let rest = words.get(1..).unwrap_or_default();
            // What: start/stop/restart/reload go to the ui.
            // Why: the ui keeps SERVICES_STOPPED.
            // From: Issue #1683 | PR #2020
            let (route, body) = match (op, rest) {
                (Some(Op::Status), []) => {
                    let v = status_json(&client(&s)?, &s).await;
                    println!("{v}");
                    return match v["state"].as_str() {
                        Some("ok") => Ok(()),
                        _ => Err(v["error"].as_str().unwrap_or("unavailable").to_string()),
                    };
                }
                (Some(Op::Container), [svc, word @ ("start" | "stop")]) => {
                    let state = Wish::of(*word == "start").word();
                    let r = s.text("UI_ROUTE_DESIRED_STATE")?.replace("{service}", svc);
                    (r, Body::Json(json!({"state": state})))
                }
                (Some(Op::Ui), ["restart"]) => (s.text("UI_ROUTE_RESTART_UI")?, Body::Form(vec![])),
                // What: dry run: render, compare, no write.
                // Why: a read; it needs no running ui.
                // From: Issue #1683 | PR #2020
                (Some(Op::Plan), []) => {
                    let v = crate::stack::render_plan(&s).await?;
                    println!("{v}");
                    return match v["errors"].as_array().map(Vec::len) {
                        Some(0) => Ok(()),
                        _ => Err("plan: the render has errors".into()),
                    };
                }
                (Some(Op::Apply), []) => (s.text("UI_ROUTE_APPLY")?, Body::Form(vec![])),
                // What: whole-stack states through the ui.
                // Why: the ui owns settings, Kea and zones.
                // From: Issue #1683 | PR #2020
                (Some(Op::Snapshot), ["list"]) => (s.text("UI_ROUTE_STACK_SNAPSHOTS")?, Body::None),
                (Some(Op::Snapshot), ["save"]) => {
                    (s.text("UI_ROUTE_STACK_SNAPSHOT_SAVE")?, Body::Form(vec![]))
                }
                (Some(Op::Snapshot), ["restore", id]) => (
                    s.text("UI_ROUTE_STACK_SNAPSHOT_RESTORE")?,
                    Body::Form(vec![("id".into(), id.to_string())]),
                ),
                // What: the clock: unix, local, zone file.
                // Why: a read; it needs no running ui.
                // From: Issue #871 | PR #2020
                (Some(Op::Time), []) => {
                    println!("{}", crate::shared::clock::report(&s)?);
                    return Ok(());
                }
                // What: Docker engine check; rc 1 on fail.
                // Why: a read; it needs no running ui.
                // From: Issue #1683 | PR #2020
                (Some(Op::Docker), []) => {
                    let v = engine_check(&client(&s)?, &s).await?;
                    println!("{v}");
                    return match v["ok"].as_bool() {
                        Some(true) => Ok(()),
                        _ => Err("docker: the engine did not answer".into()),
                    };
                }
                // What: render bodies of an owner or path.
                // Why: a read; secrets show as <secret>.
                // From: Issue #1683 | PR #2020
                (Some(Op::Render), rest) if rest.len() <= 1 => {
                    let v = crate::ui::render_preview(&s, rest.first().copied()).await?;
                    println!("{v}");
                    return match v["errors"].as_array().map(Vec::len) {
                        Some(0) => Ok(()),
                        _ => Err("render: the render has errors".into()),
                    };
                }
                (Some(Op::Service), [c, p, a @ ("restart" | "reload")]) => {
                    let r = s
                        .text("UI_ROUTE_SERVICE_ACTION")?
                        .replace("{container}", c)
                        .replace("{program}", p)
                        .replace("{action}", a);
                    (r, Body::Form(vec![]))
                }
                _ => return Err(crate::shared::cli::help(&COMMANDS)),
            };
            let v = crate::shared::http::ui_socket(&s, &route, body).await?;
            println!("{}", json!({"done": route, "answer": v}));
            Ok(())
        }

        // What: compose label of a "compose run" container.
        // Why: fixed by Docker Compose; "True" on run only.
        // From: Issue #1683 | PR #1997
        pub const ONEOFF_LABEL: &str = "com.docker.compose.oneoff";

        // What: URL host used over the unix socket.
        // Why: HTTP needs a host; the socket ignores it.
        // From: Issue #1683 | PR #1980
        const SOCKET_HOST: &str = "http://docker";

        // What: failure classes of an API call.
        // Why: callers treat timeouts apart from refusals.
        // From: Issue #1683 | PR #1980
        #[derive(Debug)]
        pub enum Error {
            Timeout,
            Status(u16),
            Transport(String),
            Decode(String),
        }

        // What: text of a Docker API Error.
        // Why: logs and the ui show one text.
        // From: Issue #1683 | PR #2020
        impl std::fmt::Display for Error {
            // What: readable text of an API error.
            // Why: shown in logs and the ui.
            // From: Issue #1683 | PR #1980
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                match self {
                    Self::Timeout => f.write_str("Docker API timed out"),
                    Self::Status(code) => write!(f, "Docker API answered HTTP {code}"),
                    Self::Transport(e) => write!(f, "Docker API: {e}"),
                    Self::Decode(e) => write!(f, "Docker API answer: {e}"),
                }
            }
        }

        // What: container actions.
        // Why: Reload sends SIGHUP to PID 1.
        // From: Issue #1683 | PR #1980
        #[derive(Clone, Copy, Debug, Eq, PartialEq)]
        pub enum Action {
            Start,
            Stop,
            Restart,
            Reload,
        }

        // What: one Docker endpoint.
        // Why: unix:// socket or tcp URL from the SOT.
        // From: Issue #1683 | PR #1980
        pub struct Api {
            client: reqwest::Client,
            base: String,
            max_body: u64,
        }

        // What: the Id of an answer; what names the call.
        // Why: exec and create both go on with this Id.
        // From: Issue #1683 | PR #2017
        fn id_of(answer: &[u8], what: &str) -> Result<String, Error> {
            decode::<Value>(answer)?["Id"]
                .as_str()
                .map(str::to_string)
                .ok_or_else(|| Error::Decode(format!("{what} without Id")))
        }

        // What: JSON body of an answer, as the type asked.
        // Why: one decode error type.
        // From: Issue #1683 | PR #1980
        fn decode<T: serde::de::DeserializeOwned>(bytes: &[u8]) -> Result<T, Error> {
            serde_json::from_slice(bytes).map_err(|e| Error::Decode(e.to_string()))
        }

        // What: the request methods of the Docker Api.
        // Why: every engine call goes through call.
        // From: Issue #1683 | PR #2020
        impl Api {
            // What: client for a socket path or URL.
            // Why: no redirects; engine never sends one.
            // From: Issue #1683 | PR #1980
            pub fn new(endpoint: &str, max_body: u64) -> Result<Self, String> {
                let endpoint = endpoint.trim();
                let builder = crate::shared::http::Build::new().no_redirect();
                let (builder, base) = match endpoint.strip_prefix("unix://") {
                    Some(sock) => (builder.socket(sock), SOCKET_HOST.to_string()),
                    None => (builder, endpoint.trim_end_matches('/').to_string()),
                };
                let client = builder.build("Docker client")?;
                Ok(Self {
                    client,
                    base,
                    max_body,
                })
            }

            // What: one request; 2xx and 304 count as ok.
            // Why: 304 means already started or stopped.
            // From: Issue #1683 | PR #1980
            async fn call(
                &self,
                method: Method,
                path: &str,
                body: Option<Value>,
                limit: Duration,
            ) -> Result<Vec<u8>, Error> {
                let fail = |e: reqwest::Error| {
                    if e.is_timeout() {
                        Error::Timeout
                    } else {
                        Error::Transport(crate::shared::http::error_chain(&e))
                    }
                };
                let mut req = self
                    .client
                    .request(method, format!("{}{path}", self.base))
                    .timeout(limit);
                if let Some(body) = body {
                    req = req.json(&body);
                }
                let resp = req.send().await.map_err(fail)?;
                let status = resp.status();
                if !status.is_success() && status != reqwest::StatusCode::NOT_MODIFIED {
                    return Err(Error::Status(status.as_u16()));
                }
                crate::shared::http::read_body(resp, self.max_body, path)
                    .await
                    .map_err(Error::Transport)
            }

            // What: GET a path; the answer as JSON.
            // Why: inspect, version, stats, exec read so.
            // From: Issue #1683 | PR #2020
            async fn get(&self, path: &str, limit: Duration) -> Result<Value, Error> {
                decode(&self.call(Method::GET, path, None, limit).await?)
            }

            // What: run a command in a container.
            // Why: OpenRC rc-service and ui CLIs run so.
            // From: Issue #1683 | PR #1980
            pub async fn exec(
                &self,
                name: &str,
                cmd: &[&str],
                limit: Duration,
            ) -> Result<(i64, String), Error> {
                let made = self
                    .call(
                        Method::POST,
                        &format!("/containers/{name}/exec"),
                        Some(json!({"Cmd": cmd, "AttachStdout": true, "AttachStderr": true})),
                        limit,
                    )
                    .await?;
                let id = id_of(&made, "exec")?;
                let out = self
                    .call(
                        Method::POST,
                        &format!("/exec/{id}/start"),
                        Some(json!({"Detach": false, "Tty": true})),
                        limit,
                    )
                    .await?;
                let info = self.get(&format!("/exec/{id}/json"), limit).await?;
                Ok((
                    info["ExitCode"].as_i64().unwrap_or(-1),
                    String::from_utf8_lossy(&out).trim().to_string(),
                ))
            }

            // What: all containers of a compose project.
            // Why: ui and watchdog see stopped ones too.
            // From: Issue #1683 | PR #1980
            pub async fn project(
                &self,
                project: &str,
                limit: Duration,
            ) -> Result<Vec<Value>, Error> {
                let filter = json!({"label": [format!("{PROJECT_LABEL}={project}")]}).to_string();
                let url = reqwest::Url::parse_with_params(
                    &format!("{SOCKET_HOST}/containers/json"),
                    [("all", "1"), ("filters", filter.as_str())],
                )
                .map_err(|e| Error::Transport(e.to_string()))?;
                let path = format!("{}?{}", url.path(), url.query().unwrap_or_default());
                let body = self.call(Method::GET, &path, None, limit).await?;
                decode(&body)
            }

            // What: the service containers of this stack.
            // Why: a "compose run" one is no service.
            // From: Issue #1683 | PR #2020
            pub async fn stack(&self, s: &crate::config::Settings) -> Result<Vec<Value>, String> {
                let limit = timeout(s)?;
                let project = s.text("COMPOSE_PROJECT")?;
                let mut rows = self
                    .project(&project, limit)
                    .await
                    .map_err(|e| e.to_string())?;
                rows.retain(|r| r["Labels"][ONEOFF_LABEL].as_str() != Some("True"));
                Ok(rows)
            }

            // What: full state of one container.
            // Why: health, restarts, state come from here.
            // From: Issue #1683 | PR #1980
            pub async fn inspect(&self, name: &str, limit: Duration) -> Result<Value, Error> {
                self.get(&format!("/containers/{name}/json"), limit).await
            }

            // What: engine version and API version.
            // Why: docker check shows the engine answers.
            // From: Issue #1683 | PR #2020
            pub async fn version(&self, limit: Duration) -> Result<Value, Error> {
                self.get("/version", limit).await
            }

            // What: one stats sample of a container.
            // Why: CPU, memory, network, disk per container
            // From: Issue #1683 | PR #1980
            pub async fn stats(&self, name: &str, limit: Duration) -> Result<Value, Error> {
                let path = format!("/containers/{name}/stats?stream=false&one-shot=true");
                self.get(&path, limit).await
            }

            // What: start, stop, restart or HUP container.
            // Why: grace is the stop timeout in seconds.
            // From: Issue #1683 | PR #1980
            pub async fn act(
                &self,
                name: &str,
                action: Action,
                grace: u32,
                limit: Duration,
            ) -> Result<(), Error> {
                let verb = match action {
                    Action::Start => "start".to_string(),
                    Action::Stop => format!("stop?t={grace}"),
                    Action::Restart => format!("restart?t={grace}"),
                    Action::Reload => "kill?signal=HUP".to_string(),
                };
                let path = format!("/containers/{name}/{verb}");
                // What: 304 is ok here; call() says so
                // Why: stopping a stopped one is no error.
                // From: Issue #1683 | PR #1980
                self.call(Method::POST, &path, None, limit).await.map(drop)
            }

            // What: run a one-shot container to its end.
            // Why: the DHCP probe needs the host network.
            // From: Issue #1683 | PR #1985
            pub async fn run_once(
                &self,
                spec: Value,
                limit: Duration,
                wait: Duration,
            ) -> Result<(i64, String), Error> {
                let made = self
                    .call(Method::POST, "/containers/create", Some(spec), limit)
                    .await?;
                let id = id_of(&made, "create")?;
                let run = async {
                    let start = format!("/containers/{id}/start");
                    self.call(Method::POST, &start, None, limit).await?;
                    let path = format!("/containers/{id}/wait");
                    let done: Value = decode(&self.call(Method::POST, &path, None, wait).await?)?;
                    let path = format!("/containers/{id}/logs?stdout=1");
                    let raw = self.call(Method::GET, &path, None, limit).await?;
                    let code = done["StatusCode"].as_i64().unwrap_or(-1);
                    Ok((code, stdout_of(&raw)))
                }
                .await;
                let gone = format!("/containers/{id}?force=1");
                if let Err(e) = self.call(Method::DELETE, &gone, None, limit).await {
                    eprintln!("docker: remove {id}: {e}");
                }
                run
            }
        }

        // What: stdout frames of a log stream.
        // Why: without a TTY Docker adds 8-byte headers.
        // From: Issue #1683 | PR #1985
        fn stdout_of(raw: &[u8]) -> String {
            let mut out = Vec::new();
            let mut rest = raw;
            while let [kind, _, _, _, a, b, c, d, tail @ ..] = rest {
                let size = u32::from_be_bytes([*a, *b, *c, *d]) as usize;
                let (frame, next) = tail.split_at(size.min(tail.len()));
                if *kind == 1 {
                    out.extend_from_slice(frame);
                }
                rest = next;
            }
            String::from_utf8_lossy(&out).trim().to_string()
        }
    }

    // What: stack CA and leaf certificates via openssl.
    // Why: native tool; no crypto crate for X.509.
    // From: Issue #1683 | PR #1980
    pub mod cert {
        use std::path::Path;
        use std::process::Command;

        // What: run openssl; stderr becomes the error.
        // Why: a failed step names its subcommand.
        // From: Issue #1683 | PR #1980
        fn openssl(args: &[&str]) -> Result<String, String> {
            let out = crate::shared::tool::run(Command::new("openssl").args(args))?;
            Ok(String::from_utf8_lossy(&out).into_owned())
        }

        // What: path as an argument string.
        // Why: openssl takes text arguments.
        // From: Issue #1683 | PR #1980
        fn arg(p: &Path) -> String {
            p.display().to_string()
        }

        // What: self-signed CA key and certificate.
        // Why: HTTPS mode signs leaves with this CA.
        // From: Issue #1683 | PR #1980
        pub fn create_ca(
            key: &Path,
            crt: &Path,
            subject: &str,
            days: u64,
            key_type: &str,
        ) -> Result<(), String> {
            openssl(&[
                "req",
                "-x509",
                "-nodes",
                "-newkey",
                key_type,
                "-keyout",
                &arg(key),
                "-out",
                &arg(crt),
                "-days",
                &days.to_string(),
                "-subj",
                subject,
                "-addext",
                "basicConstraints=critical,CA:TRUE",
                "-addext",
                "keyUsage=critical,keyCertSign,cRLSign",
            ])
            .map(drop)
        }

        // What: the files of the CA that signs leaves.
        // Why: create_leaf takes them as one value.
        // From: Issue #1683 | PR #2020
        pub struct Ca<'a> {
            pub key: &'a Path,
            pub crt: &'a Path,
            pub serial: &'a Path,
        }

        // What: leaf key and certificate signed by the CA.
        // Why: one leaf per CDN name set in HTTPS mode.
        // From: Issue #1683 | PR #1980
        pub fn create_leaf(
            ca: &Ca,
            key: &Path,
            crt: &Path,
            subject: &str,
            sans: &[String],
            days: u64,
            key_type: &str,
        ) -> Result<(), String> {
            let csr = crate::shared::fs::with_suffix(crt, ".csr");
            let ext = crate::shared::fs::with_suffix(crt, ".ext");
            let san: Vec<String> = sans
                .iter()
                .map(|n| match crate::shared::dns::is_ip(n) {
                    true => format!("IP:{n}"),
                    false => format!("DNS:{n}"),
                })
                .collect();
            let mut body = String::from("extendedKeyUsage=serverAuth\n");
            if !san.is_empty() {
                body.push_str(&format!("subjectAltName={}\n", san.join(",")));
            }
            let mode = crate::shared::fs::PRIVATE_MODE;
            let place = crate::shared::fs::Place::Replace;
            let owner = crate::shared::fs::Owner::default();
            crate::shared::fs::write(&ext, body.as_bytes(), mode, place, owner)
                .map_err(|e| format!("{}: {e}", ext.display()))?;
            let request = openssl(&[
                "req",
                "-new",
                "-nodes",
                "-newkey",
                key_type,
                "-keyout",
                &arg(key),
                "-out",
                &arg(&csr),
                "-subj",
                subject,
            ]);
            let signed = request.and_then(|_| {
                openssl(&[
                    "x509",
                    "-req",
                    "-sha256",
                    "-CAcreateserial",
                    "-in",
                    &arg(&csr),
                    "-CA",
                    &arg(ca.crt),
                    "-CAkey",
                    &arg(ca.key),
                    "-CAserial",
                    &arg(ca.serial),
                    "-out",
                    &arg(crt),
                    "-days",
                    &days.to_string(),
                    "-extfile",
                    &arg(&ext),
                ])
            });
            // What: a failed sign leaves no half key pair.
            // Why: a lone key would stop the next attempt.
            // From: Issue #1683 | PR #1980
            let mut gone = vec![csr.as_path(), ext.as_path()];
            if signed.is_err() {
                gone.extend([key, crt]);
            }
            for f in gone {
                if let Err(e) = crate::shared::fs::delete_if_present(f) {
                    eprintln!("cert: {} left behind: {e}", f.display());
                }
            }
            signed.map(drop)
        }

        // What: SHA-256 fingerprint line of a certificate.
        // Why: a changed CA must drop its old leaves.
        // From: Issue #1683 | PR #1980
        pub fn fingerprint(crt: &Path) -> Result<String, String> {
            openssl(&[
                "x509",
                "-noout",
                "-fingerprint",
                "-sha256",
                "-in",
                &arg(crt),
            ])
        }

        // What: one certificate: end, days, renew flag.
        // Why: watchdog, CLI and REST read one rule.
        // From: Issue #1683 | PR #2020
        pub fn state(crt: &Path, within: u64) -> serde_json::Value {
            let file = crt.display().to_string();
            match expiry(crt) {
                Err(_) if !crt.is_file() => serde_json::json!({
                    "file": file, "present": false, "renew": true,
                    "error": format!("{file}: file missing")}),
                // What: an unreadable end asks renewal.
                // Why: an unknown state must not pass.
                // From: Issue #1683 | PR #2020
                Err(e) => serde_json::json!({
                    "file": file, "present": true, "renew": true,
                    "error": format!("{file}: {e}")}),
                Ok(end) => serde_json::json!({
                    "file": file, "present": true, "until": end.day,
                    "days_left": end.days_left,
                    "renew": end.secs_left <= i64::try_from(within).unwrap_or(i64::MAX)}),
            }
        }

        // What: end of a certificate, read once.
        // Why: the day for texts, seconds for renewal.
        // From: Issue #1683 | PR #2020
        pub struct End {
            pub day: String,
            pub days_left: i64,
            pub secs_left: i64,
        }

        // What: end of crt: ISO day, days and seconds left.
        // Why: one openssl read answers day and renewal.
        // From: Issue #1683 | PR #1980
        pub fn expiry(crt: &Path) -> Result<End, String> {
            let a = arg(crt);
            let out = openssl(&[
                "x509", "-noout", "-enddate", "-dateopt", "iso_8601", "-in", &a,
            ])?;
            // What: "notAfter=YYYY-MM-DD HH:MM:SSZ" read.
            // Why: openssl -dateopt iso_8601 writes it so.
            // From: Issue #1683 | PR #2020
            let text = out.trim().trim_start_matches("notAfter=");
            let bad = || format!("openssl date: {text}");
            let (date, time) = text.trim_end_matches('Z').split_once(' ').ok_or_else(bad)?;
            let n: Vec<i64> = date
                .split('-')
                .map(str::parse)
                .collect::<Result<_, _>>()
                .map_err(|_| bad())?;
            let c: Vec<i64> = time
                .split(':')
                .map(str::parse)
                .collect::<Result<_, _>>()
                .map_err(|_| bad())?;
            let (&[y, m, d], &[hh, mm, ss]) = (&n[..], &c[..]) else {
                return Err(bad());
            };
            // What: the end as unix seconds (UTC) and days.
            // Why: jiff owns calendar math; no own days.
            // From: Issue #1683 | PR #2020
            let part = |v: i64| i8::try_from(v).map_err(|_| bad());
            let stamp = i16::try_from(y)
                .map_err(|_| bad())
                .and_then(|y| {
                    jiff::civil::DateTime::new(
                        y,
                        part(m)?,
                        part(d)?,
                        part(hh)?,
                        part(mm)?,
                        part(ss)?,
                        0,
                    )
                    .map_err(|_| bad())
                })
                .and_then(|dt| jiff::tz::TimeZone::UTC.to_timestamp(dt).map_err(|_| bad()))?;
            let end = stamp.as_second();
            let days = end.div_euclid(86_400);
            let now =
                i64::try_from(crate::shared::clock::unix_secs()).map_err(|e| e.to_string())?;
            let day_secs = i64::try_from(crate::shared::tidy::DAY).map_err(|e| e.to_string())?;
            Ok(End {
                day: date.to_string(),
                days_left: days - now / day_secs,
                secs_left: end - now,
            })
        }
    }

    // What: syslog-ng config: store per program, forward.
    // Why: every container logs here; one place to read.
    // From: Issue #1683 | PR #1980
    pub mod log {
        use crate::config::{Settings, Syntax};

        // What: names of groups and muted programs.
        // Why: they go into syslog-ng text as bare words.
        // From: Issue #1683 | PR #1980
        const NAME: Syntax = Syntax::Name("_-");

        // What: one forward target host:port.
        // Why: a secondary also forwards to its primary.
        // From: Issue #1683 | PR #1980
        #[derive(Clone, Debug, Eq, PartialEq)]
        pub struct Target {
            pub host: String,
            pub port: u16,
        }

        // What: primary first, then extra targets.
        // Why: SYSLOG_PRIMARY is set only on a secondary.
        // From: Issue #1683 | PR #1980
        pub fn targets(s: &Settings) -> Result<Vec<Target>, String> {
            let primary = s.text("SYSLOG_PRIMARY").ok();
            primary
                .into_iter()
                .chain(s.list("SYSLOG_FORWARD")?)
                .map(|t| {
                    let need = || format!("syslog target {t:?} needs host:port");
                    let (host, port) = crate::shared::dns::parse_endpoint(&t, true)
                        .map_err(|e| format!("syslog target: {e}"))?;
                    let port = port.ok_or_else(need)?;
                    Ok(Target { host, port })
                })
                .collect()
        }

        // What: one destination and log path per target.
        // Why: a disk buffer keeps lines while it is down.
        // From: Issue #1683 | PR #1980
        pub fn forward_block(
            s: &Settings,
            targets: &[Target],
            source: &str,
        ) -> Result<String, String> {
            let buffer = s.text("SYSLOG_BUFFER_DIR")?;
            let bytes = s.uint("SYSLOG_BUFFER_BYTES")?;
            let transport = s.text("SYSLOG_FWD_TRANSPORT")?;
            // What: values inside quotes of a destination.
            // Why: a quote would end the string.
            // From: Issue #1683 | PR #2020
            for v in [buffer.as_str(), transport.as_str()] {
                crate::config::checked(Syntax::Quoted, v)?;
            }
            for t in targets {
                crate::config::checked(Syntax::Quoted, &t.host)?;
            }
            Ok(targets
            .iter()
            .enumerate()
            .map(|(i, t)| {
                // What: ip-protocol(6) for an IPv6 address.
                // Why: syslog-ng defaults to IPv4 only.
                // From: Issue #1683 | PR #2020
                let proto = if crate::shared::dns::is_ipv6_text(&t.host) {
                    " ip-protocol(6)"
                } else {
                    ""
                };
                let dest = format!(
                    "destination d_fwd{i} {{ network(\"{}\" port({}) transport(\"{transport}\") \
                     disk-buffer(reliable(yes) capacity-bytes({bytes}) dir(\"{buffer}\")){proto} ); }};\n",
                    t.host, t.port
                );
                let n = i.to_string();
                [
                    dest.as_str(),
                    "log { source(",
                    source,
                    "); destination(d_fwd",
                    &n,
                    "); };\n",
                ]
                .concat()
            })
            .collect())
        }

        // What: name of the local store destination.
        // Why: muted programs skip it; logs page reads it.
        // From: Issue #1683 | PR #1980
        pub const STORE: &str = "d_store";

        // What: full syslog-ng.conf.
        // Why: the watchdog image runs syslog-ng.
        // From: Issue #1683 | PR #1980
        pub fn render(s: &Settings) -> Result<String, String> {
            let root = s.text("SYSLOG_LOG_ROOT")?;
            let buffer = s.text("SYSLOG_BUFFER_DIR")?;
            let template = s.text("SYSLOG_LINE_TEMPLATE")?;
            let group = s.text("LOG_READER_GROUP")?;
            let muted = s.list("SYSLOG_MUTED")?;
            let safe_path = |p: &str| crate::config::safe(Syntax::Path, p);
            if !safe_path(&root) || !safe_path(&buffer) {
                return Err(
                    "SYSLOG_LOG_ROOT and SYSLOG_BUFFER_DIR must be plain absolute paths".into(),
                );
            }
            crate::config::checked(Syntax::Template, &template)
                .map_err(|e| format!("SYSLOG_LINE_TEMPLATE: {e}"))?;
            if !crate::config::safe(NAME, &group) {
                return Err(format!("LOG_READER_GROUP={group} is no group name"));
            }
            if let Some(bad) = muted.iter().find(|m| !crate::config::safe(NAME, m)) {
                return Err(format!("SYSLOG_MUTED entry {bad:?} is no plain name"));
            }
            // What: a setting that must be one bare word.
            // Why: perm and transport stand unquoted.
            // From: Issue #1683 | PR #2020
            let word = |key: &str| -> Result<String, String> {
                let v = s.text(key)?;
                crate::config::checked(Syntax::Name(""), &v)
                    .map(str::to_string)
                    .map_err(|e| format!("{key}: {e}"))
            };
            let skip = if muted.is_empty() {
                String::new()
            } else {
                format!(r#" and not program("^({})$" type(pcre))"#, muted.join("|"))
            };
            let mut out = format!(
                r#"@version: current
options {{ create-dirs(yes); keep-hostname(yes); group("{group}"); dir-group("{group}"); perm({fperm}); dir-perm({dperm}); time-reap({reap}); }};
source s_docker {{ network(transport("{inp}") port({port}) flags(syslog-protocol)); }};
filter f_named {{ program("^[A-Za-z0-9_-]+$" type(pcre)){skip}; }};
destination {STORE} {{ file("{root}/${{PROGRAM}}/${{YEAR}}${{MONTH}}${{DAY}}.log" template("{template}")); }};
log {{ source(s_docker); filter(f_named); destination({STORE}); }};
"#,
                fperm = word("SYSLOG_FILE_PERM")?,
                dperm = word("SYSLOG_DIR_PERM")?,
                reap = s.uint("SYSLOG_TIME_REAP")?,
                inp = word("SYSLOG_IN_TRANSPORT")?,
                port = s.uint("LANCACHE_LOG_PORT")?,
            );
            out.push_str(&forward_block(s, &targets(s)?, "s_docker")?);
            Ok(out)
        }
    }

    // What: net-snmp snmpd.conf.
    // Why: statistics and alarms read SNMP values.
    // From: Issue #1683 | PR #1980
    pub mod snmp {
        use crate::config::{Settings, Syntax};

        // What: one extend command (custom OID).
        // Why: stack counters beside the stock MIBs.
        // From: Issue #1683 | PR #1980
        #[derive(Clone, Debug)]
        pub struct Extend {
            pub name: String,
            pub command: String,
        }

        // What: one logmatch watch on a log file.
        // Why: counts error lines per program.
        // From: Issue #1683 | PR #1980
        #[derive(Clone, Debug)]
        pub struct LogMatch {
            pub name: String,
            pub file: String,
            pub regex: String,
        }

        // What: full snmpd.conf from the SOT.
        // Why: community, listen and limits are settings.
        // From: Issue #1683 | PR #1980
        pub fn render(
            s: &Settings,
            extends: &[Extend],
            matches: &[LogMatch],
        ) -> Result<String, String> {
            // What: a value that stays on its snmpd line.
            // Why: a line break would start a directive.
            // From: Issue #1683 | PR #1980
            let text = |key: &str| -> Result<String, String> {
                let v = s.text(key).map_err(|e| e.to_string())?;
                crate::config::checked(Syntax::Line, &v)
                    .map(str::to_string)
                    .map_err(|e| format!("{key}: {e}"))
            };
            let line = |v: &str| crate::config::checked(Syntax::Line, v).map(str::to_string);
            let community = text("SNMP_COMMUNITY")?;
            let mut out = format!(
                "agentAddress {}\nrocommunity {community} {}\nincludeAllDisks {}%\nload {} {} {}\n",
                text("SNMP_LISTEN")?,
                text("SNMP_ALLOW_FROM")?,
                s.uint("SNMP_DISK_MIN_FREE_PERCENT")?,
                s.uint("SNMP_LOAD_1")?,
                s.uint("SNMP_LOAD_5")?,
                s.uint("SNMP_LOAD_15")?,
            );
            if s.flag("SNMP_AGENTX")? {
                out += &format!(
                    "master agentx\nagentXSocket {}\n",
                    text("SNMP_AGENTX_SOCKET")?
                );
            }
            for e in extends {
                out += &format!("extend {} {}\n", line(&e.name)?, line(&e.command)?);
            }
            let every = s.uint("SNMP_LOGMATCH_INTERVAL")?;
            for m in matches {
                let (name, file, regex) = (line(&m.name)?, line(&m.file)?, line(&m.regex)?);
                out += &format!("logmatch {name} {file} {every} {regex}\n");
            }
            if s.flag("SNMP_TRAPS")? {
                out += &format!(
                    "trap2sink {} {community}\ndefaultMonitors yes\nlinkUpDownNotifications yes\n",
                    text("SNMP_TRAP_SINK")?
                );
            }
            Ok(out)
        }

        // What: host and port of an SNMP target text.
        // Why: the endpoint reader checks the host name.
        // From: Issue #1683 | PR #2020
        fn target_of(target: &str) -> Result<(String, u16), String> {
            let rest = target.strip_prefix("udp:").unwrap_or(target);
            let (host, port) = crate::shared::dns::parse_endpoint(rest, true)?;
            Ok((host, port.unwrap_or(DEFAULT_PORT)))
        }

        // What: UDP port of an SNMP agent.
        // Why: fixed by RFC 3411; a target may omit it.
        // From: Issue #1683 | PR #2020
        const DEFAULT_PORT: u16 = 161;

        // What: text of one varbind, as snmpget wrote it.
        // Why: the reader takes the first word as a number.
        // From: Issue #1683 | PR #2020
        fn value_text(v: &snmp2::Value<'_>) -> String {
            use snmp2::Value;
            match v {
                Value::Integer(n) => n.to_string(),
                Value::Counter32(n) | Value::Unsigned32(n) | Value::Timeticks(n) => n.to_string(),
                Value::Counter64(n) => n.to_string(),
                Value::OctetString(b) => String::from_utf8_lossy(b).trim().to_string(),
                Value::IpAddress([a, b, c, d]) => format!("{a}.{b}.{c}.{d}"),
                _ => String::new(),
            }
        }

        // What: SNMP v2c GET of many OIDs in one request.
        // Why: no snmpget: the community stays out of ps.
        // From: Issue #1683 | PR #2020
        pub fn get(s: &Settings, target: &str, oids: &[String]) -> Result<Vec<String>, String> {
            let (host, port) = target_of(target)?;
            let community = s.text("SNMP_COMMUNITY")?;
            let wait = std::time::Duration::from_secs(s.uint("STATS_SNMP_TIMEOUT")?);
            let ids: Vec<snmp2::Oid<'static>> = oids
                .iter()
                .map(|text| {
                    let parts: Result<Vec<u64>, _> = text
                        .split('.')
                        .filter(|p| !p.is_empty())
                        .map(str::parse)
                        .collect();
                    parts
                        .ok()
                        .and_then(|p| snmp2::Oid::from(&p).ok())
                        .ok_or_else(|| format!("{text:?} is no OID"))
                })
                .collect::<Result<_, _>>()?;
            let refs: Vec<&snmp2::Oid<'_>> = ids.iter().collect();
            let mut session = snmp2::SyncSession::new_v2c(
                (host.as_str(), port),
                community.as_bytes(),
                Some(wait),
                rand::random::<i32>() & i32::MAX,
            )
            .map_err(|e| format!("SNMP target {target}: {e}"))?;
            let reply = session.get_many(&refs).map_err(|e| {
                format!("SNMP target {target}: {e} (no answer in {wait:?}: wrong target, port or community?)")
            })?;
            if reply.error_status != 0 {
                return Err(format!(
                    "SNMP target {target}: agent error {} at OID {}",
                    reply.error_status, reply.error_index
                ));
            }
            let out: Vec<String> = reply.varbinds.map(|(_, v)| value_text(&v)).collect();
            if out.len() != oids.len() {
                return Err(format!(
                    "SNMP target {target}: {} values for {} OIDs",
                    out.len(),
                    oids.len()
                ));
            }
            Ok(out)
        }
    }

    // What: numbered known-good snapshots in one dir.
    // Why: zone and Kea rollbacks pick one by id.
    // From: Issue #1683 | PR #1980
    pub mod snapshot {
        use crate::shared::fs::{self, Owner, Place};
        use std::path::PathBuf;

        // What: snapshot dir, keep count, owner, file name.
        // Why: files: <dir>/<id>/<file>, as setup.sh reads
        // From: Issue #1683 | PR #1980
        pub struct Store {
            pub dir: PathBuf,
            pub keep: usize,
            pub owner: Owner,
            pub file: Option<String>,
        }

        // What: an id is a non-empty digit string.
        // Why: ids name files; no path can sneak in.
        // From: Issue #1683 | PR #1980
        fn is_id(name: &str) -> bool {
            !name.is_empty() && name.bytes().all(|b| b.is_ascii_digit())
        }

        // What: methods of the snapshot Store.
        // Why: a store saves, lists, reads, prunes.
        // From: Issue #1683 | PR #2020
        impl Store {
            // What: the file that holds snapshot id.
            // Why: flat file, or one dir per id with name.
            // From: Issue #1683 | PR #1980
            pub fn path(&self, id: &str) -> PathBuf {
                match &self.file {
                    Some(name) => self.dir.join(id).join(name),
                    None => self.dir.join(id),
                }
            }

            // What: save body under a new time id.
            // Why: exclusive create; then prune old ones.
            // From: Issue #1683 | PR #1980
            pub fn save(&self, body: &[u8]) -> Result<String, String> {
                let id = crate::shared::clock::unix_nanos().to_string();
                let mode = fs::PRIVATE_MODE;
                fs::write(&self.path(&id), body, mode, Place::Exclusive, self.owner)
                    .map_err(|e| format!("snapshot {id}: {e}"))?;
                self.prune()?;
                Ok(id)
            }

            // What: ids, newest first.
            // Why: longer digit string is newer, then text.
            // From: Issue #1683 | PR #1980
            pub fn list(&self) -> Result<Vec<String>, String> {
                let entries = crate::shared::fs::entries_if_present(&self.dir)
                    .map_err(|e| format!("{}: {e}", self.dir.display()))?;
                let mut ids: Vec<String> = entries
                    .iter()
                    .filter_map(|p| p.file_name()?.to_str().map(String::from))
                    .filter(|n| is_id(n) && self.path(n).is_file())
                    .collect();
                ids.sort_by(|a, b| crate::config::longest_first(a, b));
                Ok(ids)
            }

            // What: the snapshots as id and time rows.
            // Why: pages, REST and CLI show one shape.
            // From: Issue #1683 | PR #2017
            pub fn rows(&self) -> Result<Vec<serde_json::Value>, String> {
                let mut rows = Vec::new();
                for id in self.list()? {
                    let path = self.path(&id);
                    let meta =
                        std::fs::metadata(&path).map_err(|e| format!("{}: {e}", path.display()))?;
                    let created = crate::shared::fs::modified_secs(&meta);
                    rows.push(serde_json::json!({"id": id, "created_unix": created}));
                }
                Ok(rows)
            }

            // What: one snapshot, parsed as JSON.
            // Why: rollback restores exactly this.
            // From: Issue #1683 | PR #2020
            pub fn read<T: serde::de::DeserializeOwned>(&self, id: &str) -> Result<T, String> {
                if !is_id(id) {
                    return Err(format!("bad snapshot id {id:?}"));
                }
                fs::read_json(&self.path(id))?.ok_or_else(|| format!("snapshot {id}: not found"))
            }

            // What: drop all but the newest keep.
            // Why: at least one stays to roll back to.
            // From: Issue #1683 | PR #1980
            fn prune(&self) -> Result<(), String> {
                for id in self.list()?.into_iter().skip(self.keep.max(1)) {
                    let path = self.dir.join(&id);
                    let gone = match self.file {
                        Some(_) => fs::delete_tree_if_present(&path),
                        None => fs::delete_if_present(&path),
                    };
                    gone.map_err(|e| format!("{}: {e}", path.display()))?;
                }
                Ok(())
            }
        }
    }

    // What: on-demand DHCP probe: DISCOVER/REQUEST/RELEASE
    // Why: shows every DHCP server on LAN and a real lease.
    // From: Issue #1683 | PR #1980
    pub mod dhcp_probe {
        use crate::config::Settings;
        use dhcproto::Decodable;
        use dhcproto::v4::{
            Decoder, DhcpOption, Encodable, Encoder, Flags, Message, MessageType, OptionCode,
        };
        use std::io::ErrorKind;
        use std::net::{Ipv4Addr, SocketAddrV4, UdpSocket};
        use std::time::{Duration, Instant};

        // What: DHCP client and server ports.
        // Why: fixed by RFC 2131.
        // From: Issue #1683 | PR #1980
        const CLIENT_PORT: u16 = 68;
        // What: DHCP server port.
        // Why: fixed by RFC 2131.
        // From: Issue #1683 | PR #2020
        const SERVER_PORT: u16 = 67;

        // What: largest UDP payload.
        // Why: a receive buffer never truncates a reply.
        // From: Issue #1683 | PR #1980
        const UDP_MAX: usize = 65_535;

        // What: one labelled value of an answer.
        // Why: the ui prints a table per server.
        // From: Issue #1683 | PR #1980
        #[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
        pub struct Detail {
            pub label: String,
            pub value: String,
        }

        // What: one answering server.
        // Why: competing servers must be visible.
        // From: Issue #1683 | PR #1980
        #[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
        pub struct Server {
            pub server: Option<Ipv4Addr>,
            pub address: Option<Ipv4Addr>,
            pub details: Vec<Detail>,
        }

        // What: probe result for the ui.
        // Why: offers, lease result and hard errors apart.
        // From: Issue #1683 | PR #1980
        #[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
        pub struct Report {
            pub servers: Vec<Server>,
            pub lease_ok: bool,
            pub lease_text: String,
            pub error: Option<String>,
        }

        // What: constructors of the probe Report.
        // Why: most exits differ only in two fields.
        // From: Issue #1683 | PR #2020
        impl Report {
            // What: a report with offers and a lease text.
            // Why: most exits differ only in these.
            // From: Issue #1683 | PR #1980
            fn lease(servers: Vec<Server>, ok: bool, text: impl Into<String>) -> Self {
                Self {
                    servers,
                    lease_ok: ok,
                    lease_text: text.into(),
                    error: None,
                }
            }

            // What: a report for a hard error.
            // Why: socket or send failures.
            // From: Issue #1683 | PR #1980
            fn error(servers: Vec<Server>, e: String) -> Self {
                Self {
                    servers,
                    lease_ok: false,
                    lease_text: String::new(),
                    error: Some(e),
                }
            }
        }

        // What: the options shown, with labels.
        // Why: option codes are fixed by RFC 2132.
        // From: Issue #1683 | PR #1980
        const FIELDS: [(&str, OptionCode); 8] = [
            ("Server", OptionCode::ServerIdentifier),
            ("Subnet mask", OptionCode::SubnetMask),
            ("Router", OptionCode::Router),
            ("DNS", OptionCode::DomainNameServer),
            ("Domain", OptionCode::DomainName),
            ("Lease time", OptionCode::AddressLeaseTime),
            ("Renewal", OptionCode::Renewal),
            ("Broadcast", OptionCode::BroadcastAddr),
        ];

        // What: text of one option, if shown.
        // Why: lists join with a comma.
        // From: Issue #1683 | PR #1980
        fn option_text(opt: &DhcpOption) -> Option<String> {
            Some(match opt {
                DhcpOption::ServerIdentifier(a)
                | DhcpOption::SubnetMask(a)
                | DhcpOption::BroadcastAddr(a) => a.to_string(),
                DhcpOption::AddressLeaseTime(n) | DhcpOption::Renewal(n) => n.to_string(),
                DhcpOption::Router(l) | DhcpOption::DomainNameServer(l) => l
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join(", "),
                DhcpOption::DomainName(n) => n.clone(),
                _ => return None,
            })
        }

        // What: server, address and details of a reply.
        // Why: one reader for OFFER and ACK.
        // From: Issue #1683 | PR #1980
        fn read(msg: &Message) -> Server {
            let address = Some(msg.yiaddr()).filter(|a| !a.is_unspecified());
            let mut details: Vec<Detail> = address
                .map(|a| Detail {
                    label: "Address".into(),
                    value: a.to_string(),
                })
                .into_iter()
                .collect();
            for (label, code) in FIELDS {
                if let Some(value) = msg.opts().get(code).and_then(option_text) {
                    details.push(Detail {
                        label: label.into(),
                        value,
                    });
                }
            }
            let server = match msg.opts().get(OptionCode::ServerIdentifier) {
                Some(DhcpOption::ServerIdentifier(a)) => Some(*a),
                _ => None,
            };
            Server {
                server,
                address,
                details,
            }
        }

        // What: true if msg is of this DHCP type.
        // Why: replies are filtered by type.
        // From: Issue #1683 | PR #1980
        fn is(msg: &Message, kind: MessageType) -> bool {
            matches!(msg.opts().get(OptionCode::MessageType), Some(DhcpOption::MessageType(t)) if *t == kind)
        }

        // What: build one client message.
        // Why: broadcast flag except for RELEASE.
        // From: Issue #1683 | PR #1980
        fn message(
            xid: u32,
            mac: &[u8; 6],
            ci: Ipv4Addr,
            kind: MessageType,
            extra: Vec<DhcpOption>,
        ) -> Message {
            let zero = Ipv4Addr::UNSPECIFIED;
            let mut msg = Message::new_with_id(xid, ci, zero, zero, zero, mac);
            if kind != MessageType::Release {
                msg.set_flags(Flags::default().set_broadcast());
            }
            let opts = msg.opts_mut();
            opts.insert(DhcpOption::MessageType(kind));
            opts.insert(DhcpOption::ParameterRequestList(
                FIELDS
                    .iter()
                    .map(|(_, c)| *c)
                    .filter(|c| *c != OptionCode::ServerIdentifier)
                    .collect(),
            ));
            for o in extra {
                opts.insert(o);
            }
            msg
        }

        // What: encode and send one message.
        // Why: errors become text for the report.
        // From: Issue #1683 | PR #1980
        fn send(sock: &UdpSocket, msg: &Message, to: SocketAddrV4) -> Result<(), String> {
            let mut buf = Vec::new();
            msg.encode(&mut Encoder::new(&mut buf))
                .map_err(|e| e.to_string())?;
            sock.send_to(&buf, to).map(drop).map_err(|e| e.to_string())
        }

        // What: read replies of xid until done or deadline.
        // Why: f returns true when the wanted reply came.
        // From: Issue #1683 | PR #1980
        fn listen(
            sock: &UdpSocket,
            xid: u32,
            until: Instant,
            mut f: impl FnMut(&Message) -> bool,
        ) -> Result<(), String> {
            let mut buf = vec![0u8; UDP_MAX];
            loop {
                let left = until.saturating_duration_since(Instant::now());
                if left.is_zero() {
                    return Ok(());
                }
                sock.set_read_timeout(Some(left))
                    .map_err(|e| e.to_string())?;
                match sock.recv_from(&mut buf) {
                    Ok((n, _)) => {
                        let done = Message::decode(&mut Decoder::new(&buf[..n]))
                            .is_ok_and(|m| m.xid() == xid && f(&m));
                        if done {
                            return Ok(());
                        }
                    }
                    Err(e) if e.kind() == ErrorKind::Interrupted => {}
                    Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
                        return Ok(());
                    }
                    Err(e) => return Err(e.to_string()),
                }
            }
        }

        // What: run the probe with SOT timings.
        // Why: random xid and local MAC; lease is released.
        // From: Issue #1683 | PR #1980
        pub fn run(s: &Settings) -> Report {
            let timing = || -> Result<(Duration, Duration, u32), String> {
                Ok((
                    Duration::from_millis(s.uint("DHCP_PROBE_WINDOW_MS")?),
                    Duration::from_millis(s.uint("DHCP_PROBE_ACK_WAIT_MS")?),
                    s.num::<u32>("DHCP_PROBE_SENDS")?,
                ))
            };
            let (window, wait, sends) = match timing() {
                Ok(t) => t,
                Err(e) => return Report::error(Vec::new(), e),
            };
            let sock = match UdpSocket::bind((Ipv4Addr::UNSPECIFIED, CLIENT_PORT))
                .and_then(|sock| sock.set_broadcast(true).map(|()| sock))
            {
                Ok(sock) => sock,
                Err(e) => return Report::error(Vec::new(), format!("DHCP socket: {e}")),
            };
            let bcast = SocketAddrV4::new(Ipv4Addr::BROADCAST, SERVER_PORT);
            let xid: u32 = rand::random();
            let mut mac: [u8; 6] = rand::random();
            // What: locally administered unicast MAC.
            // Why: never collides with real NIC (IEEE 802).
            // From: Issue #1683 | PR #1980
            mac[0] = (mac[0] | 0x02) & !0x01;
            let discover = message(
                xid,
                &mac,
                Ipv4Addr::UNSPECIFIED,
                MessageType::Discover,
                vec![],
            );
            let end = Instant::now() + window;
            let mut servers: Vec<Server> = Vec::new();
            for round in 1..=sends {
                if let Err(e) = send(&sock, &discover, bcast) {
                    return Report::error(servers, format!("DHCPDISCOVER: {e}"));
                }
                let until = if round == sends {
                    end
                } else {
                    (Instant::now() + window / sends).min(end)
                };
                let got = listen(&sock, xid, until, |m| {
                    if is(m, MessageType::Offer) {
                        let offer = read(m);
                        if offer.server.is_some()
                            && !servers.iter().any(|x| x.server == offer.server)
                        {
                            servers.push(offer);
                        }
                    }
                    false
                });
                if let Err(e) = got {
                    eprintln!("dhcp_probe: read {round}: {e}");
                }
            }
            let Some(first) = servers.first() else {
                return Report::lease(
                    servers,
                    false,
                    format!("no offer within {} ms", window.as_millis()),
                );
            };
            let (Some(addr), Some(server)) = (first.address, first.server) else {
                return Report::lease(servers, false, "offer without address or server id");
            };
            let request = message(
                xid,
                &mac,
                Ipv4Addr::UNSPECIFIED,
                MessageType::Request,
                vec![
                    DhcpOption::RequestedIpAddress(addr),
                    DhcpOption::ServerIdentifier(server),
                ],
            );
            if let Err(e) = send(&sock, &request, bcast) {
                return Report::error(servers, format!("DHCPREQUEST: {e}"));
            }
            let mut verdict: Result<Server, String> = Err("no ACK before timeout".into());
            let heard = listen(&sock, xid, Instant::now() + wait, |m| {
                if is(m, MessageType::Nak) {
                    verdict = Err("server sent DHCPNAK".into());
                    return true;
                }
                let ack = is(m, MessageType::Ack)
                    .then(|| read(m))
                    .filter(|a| a.server == Some(server));
                match ack {
                    Some(a) => {
                        verdict = Ok(a);
                        true
                    }
                    None => false,
                }
            });
            if let Err(e) = heard {
                return Report::error(servers, e);
            }
            let ack = match verdict {
                Ok(ack) => ack,
                Err(text) => return Report::lease(servers, false, text),
            };
            let Some(ip) = ack.address else {
                return Report::lease(servers, true, "lease granted");
            };
            let release = message(
                rand::random(),
                &mac,
                ip,
                MessageType::Release,
                vec![DhcpOption::ServerIdentifier(server)],
            );
            if let Err(e) = send(&sock, &release, SocketAddrV4::new(server, SERVER_PORT)) {
                eprintln!("dhcp_probe: release to {server}: {e}");
            }
            Report::lease(servers, true, format!("lease {ip} granted by {server}"))
        }
    }

    // What: chrony.conf for the stack NTP server.
    // Why: LAN clients get time from the appliance.
    // From: Issue #1683 | PR #1980
    pub mod chrony {
        use crate::config::{Settings, Syntax};

        // What: path characters of the drift file.
        // Why: the path goes into a config file.
        // From: Issue #1683 | PR #1980
        const HOSTISH: Syntax = Syntax::Name(".:/-_");

        // What: full chrony.conf.
        // Why: upstream needed; only SOT CIDRs may ask.
        // From: Issue #1683 | PR #1980
        pub fn render(s: &Settings) -> Result<String, String> {
            // What: each upstream is read: a name or an IP.
            // Why: chrony takes no port; nothing else.
            // From: Issue #1683 | PR #2020
            let upstream: Vec<String> = s
                .list("NTP_UPSTREAM_SERVERS")?
                .iter()
                .map(|v| match crate::shared::dns::parse_endpoint(v, true)? {
                    (host, None) => Ok(host),
                    (_, Some(_)) => Err(format!("NTP_UPSTREAM_SERVERS: {v:?} takes no port")),
                })
                .collect::<Result<_, String>>()?;
            if upstream.is_empty() {
                return Err("NTP_UPSTREAM_SERVERS is empty; NTP never runs alone".into());
            }
            let allowed = s.list("NTP_ALLOWED_CLIENT_CIDRS")?;
            let drift = s.text("NTP_DRIFT_FILE")?;
            let makestep = s.text("NTP_MAKESTEP")?;
            if !drift.starts_with('/') || !crate::config::safe(HOSTISH, &drift) {
                return Err(format!("NTP_DRIFT_FILE={drift} is no plain absolute path"));
            }
            if !crate::config::safe(Syntax::Line, &makestep) {
                return Err("NTP_MAKESTEP holds a line break".into());
            }
            let mut out = format!(
                "driftfile {drift}\nport {}\nmakestep {makestep}\nrtcsync\n",
                s.uint("NTP_PORT")?
            );
            for host in &upstream {
                let kind = if crate::shared::dns::is_ip(host) {
                    "server"
                } else {
                    "pool"
                };
                out += &format!("{kind} {host} iburst\n");
            }
            for cidr in &allowed {
                out += &format!("allow {cidr}\n");
            }
            Ok(out)
        }
    }

    // What: pdns.conf of the authoritative server.
    // Why: primary notifies; secondary pulls with TSIG.
    // From: Issue #1683 | PR #1980
    pub mod pdns_conf {
        use crate::config::{Settings, Syntax};

        // What: registered secondaries as (name, address).
        // Why: the SOT list holds one name@address per row.
        // From: Issue #1683 | PR #2017
        pub fn secondaries(s: &Settings) -> Result<Vec<(String, String)>, String> {
            s.list("DNS_SECONDARIES")?
                .iter()
                .map(|row| {
                    let (name, addr) = row
                        .split_once('@')
                        .ok_or_else(|| format!("DNS_SECONDARIES: {row:?} is no name@address"))?;
                    Ok((name.to_string(), addr.to_string()))
                })
                .collect()
        }

        // What: the SOT text of a list of secondaries.
        // Why: read and write share the name@address form.
        // From: Issue #1683 | PR #2017
        pub fn secondary_rows(list: &[(String, String)]) -> String {
            let rows: Vec<String> = list.iter().map(|(n, a)| format!("{n}@{a}")).collect();
            crate::config::join_items(&rows)
        }

        // What: addresses of registered secondaries.
        // Why: NOTIFY goes to every registered secondary.
        // From: Issue #1683 | PR #1980
        pub fn secondary_ips(s: &Settings) -> Result<Vec<String>, String> {
            secondaries(s)?
                .into_iter()
                .map(|(name, ip)| match crate::shared::dns::is_ip(&ip) {
                    true => Ok(ip),
                    false => Err(format!("DNS_SECONDARIES: {name}@{ip} has no IP address")),
                })
                .collect()
        }

        // What: address and port of the own pdns.
        // Why: recursor and dnsdist send to the same place.
        // From: Issue #1683 | PR #2017
        pub fn auth_endpoint(s: &Settings) -> Result<String, String> {
            Ok(crate::shared::dns::host_port(
                &s.text("PDNS_AUTH_ADDRESS")?,
                s.uint("PDNS_AUTH_PORT")?,
            ))
        }

        // What: full pdns.conf for this node's role.
        // Why: API on; AXFR by TSIG, not by IP list.
        // From: Issue #1683 | PR #1980
        pub fn auth(s: &Settings, api_key: &str) -> Result<String, String> {
            let primary =
                crate::shared::dns::Role::from_settings(s)? == crate::shared::dns::Role::Primary;
            let yes = |on: bool| if on { "yes" } else { "no" }.to_string();
            let joined = |key: &str| s.list(key).map(|l| l.join(","));
            let rows = [
                ("launch", s.text("PDNS_LAUNCH")?),
                ("gsqlite3-database", s.text("PDNS_DATABASE")?),
                // What: the backend keeps DNSSEC keys.
                // Why: own endings are signed and anchored.
                // From: Issue #1683 | PR #2019
                ("gsqlite3-dnssec", yes(true)),
                ("local-address", joined("PDNS_LISTEN")?),
                ("local-port", s.uint("PDNS_AUTH_PORT")?.to_string()),
                ("primary", yes(primary)),
                ("secondary", yes(!primary)),
                (
                    "also-notify",
                    if primary {
                        // What: NOTIFY to secondary pdns.
                        // Why: port 53 there is recursor.
                        // From: Issue #1683 | PR #2020
                        let port = s.uint("PDNS_AUTH_PORT")?;
                        let to: Vec<String> = secondary_ips(s)?
                            .iter()
                            .map(|ip| crate::shared::dns::host_port(ip, port))
                            .collect();
                        to.join(",")
                    } else {
                        // What: NOTIFY to own recursors.
                        // Why: AXFR ends old cached answers
                        // From: Issue #1683 | PR #2017
                        let mut to = Vec::new();
                        for (which, _) in crate::shared::recursor_conf::running(s) {
                            let port = s.uint(&which.key("PORT"))?;
                            to.extend(
                                s.list(&which.key("LISTEN"))?
                                    .iter()
                                    .map(|ip| crate::shared::dns::host_port(ip, port)),
                            );
                        }
                        to.join(",")
                    },
                ),
                ("secondary-do-renotify", yes(!primary)),
                (
                    "allow-notify-from",
                    if primary {
                        String::new()
                    } else {
                        s.text("DNS_XFR_PRIMARY")?
                    },
                ),
                ("allow-axfr-ips", joined("PDNS_AXFR_FROM")?),
                // What: dnsdist passes client IP by header.
                // Why: ACLs and logs need real client IP.
                // From: Issue #1683 | PR #2020
                (
                    "proxy-protocol-from",
                    crate::shared::dnsdist_conf::source_of(s)?,
                ),
                ("xfr-cycle-interval", s.uint("PDNS_XFR_CYCLE")?.to_string()),
                ("dnsupdate", yes(primary)),
                ("allow-dnsupdate-from", joined("PDNS_DNSUPDATE_FROM")?),
                ("default-soa-content", s.text("PDNS_DEFAULT_SOA")?),
                ("api", yes(true)),
                ("api-key", api_key.to_string()),
                ("webserver", yes(true)),
                ("webserver-address", s.text("PDNS_API_LISTEN")?),
                ("webserver-port", s.uint("PDNS_AUTH_API_PORT")?.to_string()),
                ("webserver-allow-from", joined("PDNS_API_ALLOW_FROM")?),
                // What: the web password is the API key.
                // Why: unset, / and /metrics are open.
                // From: Issue #1683 | PR #2020
                ("webserver-password", api_key.to_string()),
                ("loglevel", s.uint("PDNS_AUTH_LOGLEVEL")?.to_string()),
                ("guardian", yes(false)),
                ("daemon", yes(false)),
            ];
            let mut out = String::new();
            for (key, value) in rows {
                if !crate::config::safe(Syntax::Line, &value) {
                    return Err(format!("{key} contains a line break"));
                }
                if !value.is_empty() {
                    out += &format!("{key}={value}\n");
                }
            }
            // What: NOTIFY only to also-notify, not to NS.
            // Why: port 53 of an NS host is a recursor.
            // From: Issue #1683 | PR #2017
            out += "only-notify=\n";
            Ok(out)
        }
    }

    // What: PowerDNS peers: API clients, zone sync, flush.
    // Why: ui, dns helper and watchdog share one owner.
    // From: Issue #1683 | PR #2019
    pub mod peer {
        use crate::config::Settings;
        use std::collections::BTreeMap;

        // What: both serials of one managed zone.
        // Why: the health check reports every zone.
        // From: Issue #1683 | PR #1980
        pub struct PeerZone {
            pub zone: String,
            pub primary: Option<u32>,
            pub secondary: Option<u32>,
        }

        // What: state of a zone on a secondary, mild to bad
        // Why: the order picks worst; callers name a state.
        // From: Issue #1683 | PR #2017
        #[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
        pub enum ZoneState {
            InSync,
            Ahead,
            Unknown,
            Behind,
            Missing,
            Error,
        }

        // What: the word of a ZoneState.
        // Why: pages map the word to label and colour.
        // From: Issue #1683 | PR #2020
        impl ZoneState {
            // What: the word of state in answers and logs.
            // Why: page maps this word to label, colour.
            // From: Issue #1683 | PR #2017
            pub fn word(self) -> &'static str {
                match self {
                    ZoneState::InSync => "in_sync",
                    ZoneState::Ahead => "ahead",
                    ZoneState::Unknown => "unknown",
                    ZoneState::Behind => "behind",
                    ZoneState::Missing => "missing",
                    ZoneState::Error => "error",
                }
            }
        }

        // What: SOA serial of one zone in a zone list.
        // Why: serials show whether a secondary is in sync.
        // From: Issue #1683 | PR #1980
        pub fn serial_of(zones: &[crate::shared::pdns::Zone], zone: &str) -> Option<u32> {
            zones.iter().find(|z| z.name == zone).map(|z| z.serial)
        }

        // What: both serials of every managed zone.
        // Why: table and check compare the same rows.
        // From: Issue #1683 | PR #2017
        pub fn peer_zones(
            s: &Settings,
            ours: &[crate::shared::pdns::Zone],
            theirs: &[crate::shared::pdns::Zone],
        ) -> Result<Vec<PeerZone>, String> {
            Ok(crate::shared::dns::managed_zones(s)?
                .into_iter()
                .map(|zone| PeerZone {
                    primary: serial_of(ours, &zone),
                    secondary: serial_of(theirs, &zone),
                    zone,
                })
                .collect())
        }

        // What: state of one zone from its two serials.
        // Why: the peer status is the worst zone state.
        // From: Issue #1683 | PR #2017
        pub fn zone_state(z: &PeerZone) -> ZoneState {
            use std::cmp::Ordering;
            // What: no primary serial is the state Error.
            // Why: no primary serial gives no sync state.
            // From: Issue #1683 | PR #2020
            let Some(p) = z.primary else {
                return ZoneState::Error;
            };
            let Some(r) = z.secondary else {
                return ZoneState::Missing;
            };
            match crate::shared::dns::serial_cmp(r, p) {
                Some(Ordering::Equal) => ZoneState::InSync,
                Some(Ordering::Less) => ZoneState::Behind,
                Some(Ordering::Greater) => ZoneState::Ahead,
                None => ZoneState::Unknown,
            }
        }

        // What: the worst state of zones; none: in sync.
        // Why: one lagging zone decides the peer status.
        // From: Issue #1683 | PR #2017
        pub fn worst_state(zones: &[PeerZone]) -> ZoneState {
            zones
                .iter()
                .map(zone_state)
                .max()
                .unwrap_or(ZoneState::InSync)
        }

        // What: TSIG key in PowerDNS; returns its name.
        // Why: zones are made with the key; it comes first.
        // From: Issue #1683 | PR #2017
        pub async fn ensure_tsigkey(s: &Settings) -> Result<String, String> {
            let name = s.text("DDNS_TSIG_NAME")?;
            let algorithm = s.text("DDNS_TSIG_ALGORITHM")?;
            own_api(s)?
                .set_tsigkey(&name, &algorithm, &crate::shared::secret::tsig_secret(s)?)
                .await?;
            Ok(name)
        }

        // What: bind the TSIG key to every existing zone.
        // Why: an existing zone may lack the key binding.
        // From: Issue #1683 | PR #1858
        pub async fn ensure_tsig(s: &Settings, key: &str) -> Result<(), String> {
            let api = own_api(s)?;
            let secondary =
                crate::shared::dns::Role::from_settings(s)? == crate::shared::dns::Role::Secondary;
            let key = vec![key.to_string()];
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
        pub async fn ensure_secondary_zones(s: &Settings, key: &str) -> Result<(), String> {
            let zones = s.list("DNS_SECONDARY_ZONES")?;
            let port = primary_xfr_port(s, zones.first()).await?;
            let masters = vec![crate::shared::dns::host_port(
                &s.text("DNS_XFR_PRIMARY")?,
                port,
            )];
            // What: no removal; the primary's check prunes.
            // Why: this list is from setup, maybe stale.
            // From: Issue #1683 | PR #2020
            match_zones(&own_api(s)?, &zones, &masters, key, false, "secondary").await
        }

        // What: a secondary holds exactly the wanted zones.
        // Why: one rule at setup and in primary's check.
        // From: Issue #1683 | PR #2020
        pub async fn match_zones(
            api: &crate::shared::pdns::Api,
            zones: &[String],
            masters: &[String],
            key: &str,
            prune: bool,
            who: &str,
        ) -> Result<(), String> {
            let have = api.zones().await?;
            let wanted: Vec<String> = zones
                .iter()
                .map(|z| crate::shared::pdns::zone_id(z))
                .collect();
            for id in &wanted {
                if let Some(z) = have.iter().find(|z| z.name == *id) {
                    if z.masters != masters {
                        api.set_masters(id, masters).await?;
                    }
                } else {
                    api.create_secondary(id, masters, key).await?;
                    // What: pull the new zone now.
                    // Why: else pdns waits a xfr cycle.
                    // From: Issue #1683 | PR #2020
                    api.axfr_retrieve(id).await?;
                    eprintln!("{who}: secondary zone {id} added");
                }
            }
            // What: drop copies primary no longer serves.
            // Why: a removed LAN domain must stop answering
            // From: Issue #1683 | PR #2020
            for z in have
                .iter()
                .filter(|z| prune && z.kind == "Slave" && !wanted.contains(&z.name))
            {
                api.delete_zone(&z.name).await?;
                eprintln!("{who}: secondary zone {} removed", z.name);
            }
            Ok(())
        }

        // What: port 53 if the primary answers aa there.
        // Why: an old primary has the recursor on port 53.
        // From: Issue #1683 | PR #2017
        pub async fn primary_xfr_port(s: &Settings, zone: Option<&String>) -> Result<u64, String> {
            let fallback = s.uint("PDNS_AUTH_PORT")?;
            let Some(zone) = zone else {
                return Ok(fallback);
            };
            let primary = s.text("DNS_XFR_PRIMARY")?;
            let probe = soa_on_dns_port(s, &primary, zone).await;
            // What: no aa, no answer: keep PDNS_AUTH_PORT.
            // Why: a failed probe must not stop zones step.
            // From: Issue #1683 | PR #2020
            let chosen = match &probe {
                Ok(soa) if soa.serves_zone() => s.uint("DNS_PORT")?,
                _ => fallback,
            };
            eprintln!("primary {primary}: {probe:?}; XFR port {chosen}");
            Ok(chosen)
        }

        // What: non-RD SOA query to DNS_PORT of one address
        // Why: XFR port choice and NS check ask the same.
        // From: Issue #1683 | PR #2020
        pub async fn soa_on_dns_port(
            s: &Settings,
            address: &str,
            zone: &str,
        ) -> Result<crate::shared::dns::Soa, String> {
            let ip = crate::shared::dns::parse_ip(address)?;
            let port = s.num::<u16>("DNS_PORT")?;
            let addr = std::net::SocketAddr::new(ip, port);
            let wait = std::time::Duration::from_secs(s.uint("SECONDARY_PROBE_TIMEOUT")?);
            crate::shared::dns::soa_at(addr, zone, wait).await
        }

        // What: the zone list of one secondary by address.
        // Why: the watchdog and the ui read the same list.
        // From: Issue #1683 | PR #2020
        pub async fn zones_at(
            s: &Settings,
            address: &str,
        ) -> Result<Vec<crate::shared::pdns::Zone>, String> {
            api_at(s, address)?.zones().await
        }

        // What: one API client per recursor.
        // Why: flush and statistics reach every recursor.
        // From: Issue #1683 | PR #2017
        pub fn recursor_apis(s: &Settings) -> Result<Vec<crate::shared::pdns::Api>, String> {
            let key = crate::shared::secret::get(s, "RECURSOR_API_KEY")?;
            let client = crate::shared::http::client(s)?;
            let max = crate::shared::http::max_body(s)?;
            Ok(s.list("RECURSOR_API_URLS")?
                .iter()
                .map(|url| crate::shared::pdns::Api::new(client.clone(), max, url, &key))
                .collect())
        }

        // What: metadata kind of the cache domain edits.
        // Why: the primary publishes, secondaries read it.
        // From: Issue #1683 | PR #2020
        pub const CDN_META: &str = "X-LANCACHE-CDN";

        // What: first value of the CDN_META list.
        // Why: an empty answer then means: never published.
        // From: Issue #1683 | PR #2020
        const CDN_META_HEAD: &str = "v1";

        // What: own and off cache domains as values.
        // Why: one pdns metadata list holds both lists.
        // From: Issue #1683 | PR #2020
        pub fn cdn_meta(custom: &[String], off: &[String]) -> Vec<String> {
            let rows = |tag: &str, list: &[String]| -> Vec<String> {
                list.iter().map(|d| format!("{tag} {d}")).collect()
            };
            let mut out = vec![CDN_META_HEAD.to_string()];
            out.extend(rows("custom", custom));
            out.extend(rows("off", off));
            out
        }

        // What: both lists of CDN_META; none: unpublished.
        // Why: reverses cdn_meta; an old primary has none.
        // From: Issue #1683 | PR #2020
        pub fn cdn_from_meta(values: &[String]) -> Option<(Vec<String>, Vec<String>)> {
            if values.first().map(String::as_str) != Some(CDN_META_HEAD) {
                return None;
            }
            let pick = |tag: &str| -> Vec<String> {
                values
                    .iter()
                    .filter_map(|v| v.strip_prefix(tag)?.strip_prefix(' '))
                    .map(str::to_string)
                    .collect()
            };
            Some((pick("custom"), pick("off")))
        }

        // What: serial each zone was last flushed at.
        // Why: one rule for the ui and the dns helper.
        // From: Issue #1683 | PR #2020
        #[derive(Default)]
        pub struct Flushed(Option<BTreeMap<String, u32>>);

        // What: methods of the zone memory Flushed.
        // Why: one rule for the ui and the dns helper.
        // From: Issue #1683 | PR #2020
        impl Flushed {
            // What: zones whose serial moved since flush.
            // Why: at start pdns NOTIFY already wiped them.
            // From: Issue #1683 | PR #2020
            pub fn due(&mut self, zones: &BTreeMap<String, u32>) -> Vec<(String, u32)> {
                let seen = self.0.get_or_insert_with(|| zones.clone());
                seen.retain(|zone, _| zones.contains_key(zone));
                zones
                    .iter()
                    .filter(|(zone, serial)| seen.get(*zone) != Some(*serial))
                    .map(|(zone, serial)| (zone.clone(), *serial))
                    .collect()
            }

            // What: note a flush that worked.
            // Why: a failed one stays due for next round.
            // From: Issue #1683 | PR #2020
            pub fn done(&mut self, zone: &str, serial: u32) {
                self.0
                    .get_or_insert_with(BTreeMap::new)
                    .insert(zone.to_string(), serial);
            }
        }

        // What: clears one zone in every recursor cache.
        // Why: an edit shows at once, not after the poll.
        // From: Issue #1683 | PR #1980
        pub async fn flush_zone(s: &Settings, zone: &str) -> Result<(), String> {
            for r in recursor_apis(s)? {
                r.flush(zone, true).await?;
            }
            Ok(())
        }

        // What: each PowerDNS API: reachable, counters.
        // Why: shows a wrong key or a down server at once.
        // From: Issue #1683 | PR #2020
        pub async fn api_report(
            s: &Settings,
            with_stats: bool,
        ) -> Result<serde_json::Value, String> {
            use serde_json::json;
            let mut apis = vec![("auth", own_api(s)?)];
            apis.extend(recursor_apis(s)?.into_iter().map(|a| ("recursor", a)));
            let mut out = Vec::new();
            for (server, api) in apis {
                let mut row = json!({"server": server, "url": api.base()});
                // What: the recursor key proven by a write.
                // Why: its GET answers without the key.
                // From: Issue #1683 | PR #2020
                let key = match server {
                    "recursor" => api.flush("key-check.invalid", false).await,
                    _ => Ok(()),
                };
                match key.and(api.statistics().await) {
                    Ok(rows) => {
                        row["ok"] = json!(true);
                        row["counters"] = json!(rows.len());
                        if with_stats {
                            let mut map = BTreeMap::new();
                            crate::shared::pdns::Api::add_stats(&mut map, server, rows);
                            row["statistics"] = json!(map);
                        }
                    }
                    Err(e) => {
                        row["ok"] = json!(false);
                        row["error"] = json!(e);
                    }
                }
                out.push(row);
            }
            let ok = out.iter().all(|r| r["ok"] == json!(true));
            Ok(json!({"ok": ok, "apis": out}))
        }

        // What: pdns API of this node, primary or secondary
        // Why: records and zones live only in PowerDNS.
        // From: Issue #1683 | PR #2019
        pub fn own_api(s: &Settings) -> Result<crate::shared::pdns::Api, String> {
            pdns_api(s, &s.text("PDNS_PRIMARY_API_URL")?)
        }

        // What: an auth pdns API client for one base URL.
        // Why: all auth nodes share the key and client.
        // From: Issue #1683 | PR #2020
        fn pdns_api(s: &Settings, url: &str) -> Result<crate::shared::pdns::Api, String> {
            let key = crate::shared::secret::get(s, "PDNS_API_KEY")?;
            Ok(crate::shared::pdns::Api::new(
                crate::shared::http::client(s)?,
                crate::shared::http::max_body(s)?,
                url,
                &key,
            ))
        }

        // What: pdns API of one peer by its address.
        // Why: zone list, AXFR request and sync use it.
        // From: Issue #1683 | PR #2019
        pub fn api_at(s: &Settings, address: &str) -> Result<crate::shared::pdns::Api, String> {
            let host = crate::shared::dns::host_port(address, s.uint("PDNS_AUTH_API_PORT")?);
            let url = format!("http://{host}{}", s.text("PDNS_API_PATH")?);
            pdns_api(s, &url)
        }
    }

    // What: recursor.yml, RPZ zone and Lua files.
    // Why: two recursors: HTTP mode and HTTPS mode.
    // From: Issue #1683 | PR #1980
    pub mod recursor_conf {
        use crate::config::{Settings, Syntax};

        // What: live DNSSEC state of the own zones.
        // Why: render stays pure; pdns holds the keys.
        // From: Issue #1683 | PR #2019
        #[derive(Clone, Debug, Default, Eq, PartialEq)]
        pub struct Chain {
            // What: top zone and its DS rows; none = NTA.
            // Why: missing DS must never leave it unchecked
            // From: Issue #1683 | PR #2019
            pub anchors: Vec<(String, Vec<String>)>,
            // What: zones whose chain from an anchor holds.
            // Why: only those may lose their NTA.
            // From: Issue #1683 | PR #2019
            pub secured: Vec<String>,
        }

        // What: which of the two recursors.
        // Why: keys differ only by HTTP or HTTPS.
        // From: Issue #1683 | PR #1980
        #[derive(Clone, Copy, Debug, Eq, PartialEq)]
        pub enum Which {
            Http,
            Https,
        }

        // What: methods of the recursor Which.
        // Why: a key name is built from the mode.
        // From: Issue #1683 | PR #2020
        impl Which {
            // What: SOT key RECURSOR_<MODE>_<name>, in full
            // Why: ci.sh bakes only keys the source names.
            // From: Issue #1683 | PR #1980
            pub fn key(self, name: &str) -> String {
                match (self, name) {
                    (Self::Http, "API_PORT") => "RECURSOR_HTTP_API_PORT",
                    (Self::Https, "API_PORT") => "RECURSOR_HTTPS_API_PORT",
                    (Self::Http, "CONF_FILE") => "RECURSOR_HTTP_CONF_FILE",
                    (Self::Https, "CONF_FILE") => "RECURSOR_HTTPS_CONF_FILE",
                    (Self::Http, "LISTEN") => "RECURSOR_HTTP_LISTEN",
                    (Self::Https, "LISTEN") => "RECURSOR_HTTPS_LISTEN",
                    (Self::Http, "LUA_FILE") => "RECURSOR_HTTP_LUA_FILE",
                    (Self::Https, "LUA_FILE") => "RECURSOR_HTTPS_LUA_FILE",
                    (Self::Http, "PORT") => "RECURSOR_HTTP_PORT",
                    (Self::Https, "PORT") => "RECURSOR_HTTPS_PORT",
                    (Self::Http, "RPZ_FILE") => "RECURSOR_HTTP_RPZ_FILE",
                    (Self::Https, "RPZ_FILE") => "RECURSOR_HTTPS_RPZ_FILE",
                    _ => "",
                }
                .to_string()
            }
        }

        // What: the recursors that run, with their IP.
        // Why: dns-https idles without IP_HTTPS.
        // From: Issue #1683 | PR #1980
        pub fn running(s: &Settings) -> Vec<(Which, String)> {
            [(Which::Http, "IP_HTTP"), (Which::Https, "IP_HTTPS")]
                .into_iter()
                .filter_map(|(which, key)| Some((which, s.text(key).ok()?)))
                .collect()
        }

        // What: YAML list rows of quoted items.
        // Why: quotes or breaks would break the YAML.
        // From: Issue #1683 | PR #1980
        fn yaml_list(items: &[String], indent: &str) -> Result<String, String> {
            items
                .iter()
                .map(|i| {
                    crate::config::checked(crate::config::Syntax::Quoted, i)?;
                    Ok([indent, "- \"", i.as_str(), "\"\n"].concat())
                })
                .collect()
        }

        // What: RPZ zone: every cache domain to answer.
        // Why: clients reach the proxy by DNS only.
        // From: Issue #1683 | PR #1980
        pub fn rpz(
            s: &Settings,
            domains: &[(String, bool)],
            answer: &str,
            serial: u32,
        ) -> Result<String, String> {
            if !crate::shared::dns::is_ip(answer) {
                return Err(format!("RPZ answer {answer:?} is no IP address"));
            }
            let kind = crate::shared::dns::address_kind(answer);
            let mname = s.text("RPZ_SOA_MNAME")?;
            let mut out = format!(
                "$TTL {}\n@ SOA {mname} {} {serial} {} {} {} {}\n@ NS {mname}\n",
                s.uint("RPZ_TTL")?,
                s.text("RPZ_SOA_RNAME")?,
                s.uint("RPZ_SOA_REFRESH")?,
                s.uint("RPZ_SOA_RETRY")?,
                s.uint("RPZ_SOA_EXPIRE")?,
                s.uint("RPZ_SOA_MINIMUM")?,
            );
            // What: ".name" = subdomains, "name" = itself.
            // Why: apex of a subdomain row must not match.
            // From: Issue #1072 | PR #2020
            for (d, subtree) in domains {
                let d = crate::shared::dns::bare_zone(d);
                if !crate::shared::dns::is_dns_name(d, false, true) {
                    return Err(format!("cache domain {d:?} is no DNS name"));
                }
                let owner = if *subtree {
                    format!("*.{d}")
                } else {
                    d.to_string()
                };
                out += &format!("{owner} {kind} {answer}\n");
            }
            Ok(out)
        }

        // What: zones the recursor must not check.
        // Why: no chain, no proof; render and status agree.
        // From: Issue #1683 | PR #2020
        pub fn nta_zones(s: &Settings, chain: &Chain) -> Result<Vec<String>, String> {
            let mut out = Vec::new();
            // What: no DNSSEC check for an unchained zone.
            // Why: the root denies it; no chain, no proof.
            // From: Issue #1683 | PR #1980
            for z in crate::shared::dns::managed_zones(s)? {
                if !chain.secured.contains(&z) {
                    out.push(crate::shared::dns::bare_zone(&z).to_string());
                }
            }
            // What: a top zone without DS stays an NTA.
            // Why: an anchor without DS proves nothing.
            // From: Issue #1683 | PR #2019
            for (zone, ds) in &chain.anchors {
                if ds.is_empty() {
                    out.push(crate::shared::dns::bare_zone(zone).to_string());
                }
            }
            // What: no DNSSEC check for private domains.
            // Why: router domains (fritz.box) are unsigned
            // From: Issue #1683 | PR #1980
            for z in zone_names(s, "DNS_UPSTREAM_UNSIGNED_ZONES")? {
                if z != "." {
                    out.push(z);
                }
            }
            Ok(out)
        }

        // What: Lua config that loads the RPZ file.
        // Why: the recursor reads RPZ only via Lua.
        // From: Issue #1683 | PR #1980
        pub fn lua(s: &Settings, rpz_file: &str, chain: &Chain) -> Result<String, String> {
            let policy = s.text("RPZ_POLICY_NAME")?;
            crate::config::checked(crate::config::Syntax::Quoted, rpz_file)?;
            crate::config::checked(crate::config::Syntax::Quoted, &policy)?;
            let mut lua = format!("rpzFile(\"{rpz_file}\", {{ policyName=\"{policy}\" }})\n");
            for z in nta_zones(s, chain)? {
                crate::config::checked(crate::config::Syntax::Quoted, &z)?;
                lua += &format!("addNTA(\"{z}\")\n");
            }
            // What: a top zone is anchored by its own DS.
            // Why: .lan and .local then validate.
            // From: Issue #1683 | PR #2019
            for (zone, ds) in &chain.anchors {
                let name = crate::shared::dns::bare_zone(zone);
                crate::config::checked(crate::config::Syntax::Quoted, name)?;
                for row in ds {
                    crate::config::checked(crate::config::Syntax::Quoted, row)?;
                    lua += &format!("addTA(\"{name}\", \"{row}\")\n");
                }
            }
            lua += &root_copy(s)?;
            Ok(lua)
        }

        // What: Lua line that keeps root zone copy cached.
        // Why: fewer root queries; none if "." is forwarded
        // From: Issue #1683 | PR #2019
        fn root_copy(s: &Settings) -> Result<String, String> {
            let all_upstream =
                !upstream_servers(s)?.is_empty() && upstream_zones(s)?.iter().any(|z| z == ".");
            if all_upstream || !s.flag("ROOT_ZONE_MIRROR")? {
                return Ok(String::new());
            }
            let url = s.text("ROOT_ZONE_MIRROR_URL")?;
            crate::config::checked(crate::config::Syntax::Quoted, &url)?;
            // What: the recursor checks ZONEMD and DNSSEC.
            // Why: both are defaults of zoneToCache.
            // From: Issue #1683 | PR #2019
            Ok(format!(
                "zoneToCache(\".\", \"url\", \"{url}\", {{ refreshPeriod={}, retryOnErrorPeriod={} }})\n",
                s.uint("ROOT_ZONE_MIRROR_REFRESH")?,
                s.uint("ROOT_ZONE_MIRROR_RETRY")?
            ))
        }

        // What: the checked domain names of one list key.
        // Why: "." means all names; bad chars stop.
        // From: Issue #1683 | PR #1980
        fn zone_names(s: &Settings, key: &str) -> Result<Vec<String>, String> {
            let mut out = Vec::new();
            for raw in s.list(key)? {
                let z = crate::shared::dns::bare_zone(&raw).to_ascii_lowercase();
                // What: name with "_" allowed; empty is "."
                // Why: a..b, -bad- are no names to forward
                // From: Issue #1918 | PR #2020
                if !z.is_empty() && !crate::shared::dns::is_dns_name(&z, true, false) {
                    return Err(format!("{key}: bad domain {raw}"));
                }
                out.push(if z.is_empty() { ".".to_string() } else { z });
            }
            Ok(out)
        }

        // What: the zones that go to the upstream servers.
        // Why: none listed means all; local ones stay.
        // From: Issue #1683 | PR #1980
        fn upstream_zones(s: &Settings) -> Result<Vec<String>, String> {
            let key = "DNS_UPSTREAM_ZONES";
            let mut out = zone_names(s, key)?;
            if out.is_empty() {
                out.push(".".to_string());
            }
            // What: local zone or its subzone never leaves.
            // Why: local names sent out return NXDOMAIN.
            // From: Issue #1683 | PR #1980
            for m in crate::shared::dns::managed_zones(s)? {
                let m = crate::shared::dns::bare_zone(&m).to_ascii_lowercase();
                if let Some(z) = out.iter().find(|z| crate::shared::dns::is_within(z, &m)) {
                    return Err(format!(
                        "{key}: {z} is the local zone {m}; it is answered here"
                    ));
                }
            }
            Ok(out)
        }

        // What: upstream servers; our own address refused.
        // Why: our own address as upstream loops queries.
        // From: Issue #1683 | PR #1980
        fn upstream_servers(s: &Settings) -> Result<Vec<String>, String> {
            let list = s.list("DNS_UPSTREAM_SERVERS")?;
            check_upstream(s, "DNS_UPSTREAM_SERVERS", &list)?;
            Ok(list)
        }

        // What: the addresses this LanCache-NG answers on.
        // Why: one list for every upstream loop check.
        // From: Issue #1683 | PR #1985
        pub fn own_ips(s: &Settings) -> Vec<String> {
            ["IP_HTTP", "IP_HTTPS", "LISTEN_IP", "LISTEN_IP_HTTPS"]
                .iter()
                .filter_map(|k| s.text(k).ok())
                .collect()
        }

        // What: every entry of an upstream list is checked.
        // Why: save, render and recursor share the rule.
        // From: Issue #1683 | PR #2020
        pub fn check_upstream<S: AsRef<str>>(
            s: &Settings,
            key: &str,
            items: &[S],
        ) -> Result<(), String> {
            let own = own_ips(s);
            items
                .iter()
                .try_for_each(|raw| upstream_entry(key, raw.as_ref(), &own))
        }

        // What: one upstream: IP, [IPv6]:port or IPv4:port.
        // Why: a half bracket form must not be saved.
        // From: Issue #1683 | PR #1985
        fn upstream_entry(key: &str, raw: &str, own: &[String]) -> Result<(), String> {
            let bad = || format!("{key}: {raw} is no IP address");
            let (host, _) = crate::shared::dns::parse_endpoint(raw, false).map_err(|_| bad())?;
            let ip = crate::shared::dns::parse_ip(&host).map_err(|_| bad())?;
            if ip.is_loopback() || ip.is_unspecified() || own.contains(&host) {
                return Err(format!(
                    "{key}: {raw} is this LanCache-NG itself; that would loop"
                ));
            }
            Ok(())
        }

        // What: Lua hook: empty AAAA, not cached, counted.
        // Why: IPv4 to the cache; one log line per round.
        // From: Issue #1683 | PR #2020
        pub const AAAA_FILTER_LUA: &str = r#"suppressed = 0

function preresolve(dq)
  if dq.qtype == pdns.AAAA then
    dq.rcode = pdns.NOERROR
    dq.variable = true
    suppressed = suppressed + 1
    return true
  end
  return false
end

function maintenance()
  if suppressed > 0 then
    pdnslog("[lancache-dns][filter-aaaa] suppressed " .. suppressed .. " AAAA response(s) since last report", pdns.loglevels.Error)
    suppressed = 0
  end
end
"#;

        // What: full recursor.yml (YAML settings).
        // Why: local zones go to auth; rest upstream.
        // From: Issue #1683 | PR #1980
        pub fn yaml(
            s: &Settings,
            which: Which,
            api_key: &str,
            lua_file: &str,
            chain: &Chain,
        ) -> Result<String, String> {
            let u = |k: &str| s.uint(k).map(|v| v.to_string());
            // What: a value inside double quotes.
            // Why: a quote or line break ends the string.
            // From: Issue #1683 | PR #2020
            let q = |v: String| -> Result<String, String> {
                crate::config::checked(Syntax::Quoted, &v).map(str::to_string)
            };
            let auth = q(crate::shared::pdns_conf::auth_endpoint(s)?)?;
            let (api_key, lua_file) = (q(api_key.to_string())?, q(lua_file.to_string())?);
            let mut zones = crate::shared::dns::managed_zones(s)?;
            // What: the top zones go to pdns too.
            // Why: else the root copy denies them.
            // From: Issue #1683 | PR #2019
            for (zone, _) in &chain.anchors {
                crate::config::add_once(&mut zones, zone);
            }
            let local: String = zones
                .iter()
                .map(|z| {
                    format!(
                        "    - zone: \"{}\"\n      forwarders: [\"{auth}\"]\n",
                        crate::shared::dns::bare_zone(z)
                    )
                })
                .collect();
            let upstream = upstream_servers(s)?;
            let recurse = if upstream.is_empty() {
                String::new()
            } else {
                let list: Vec<String> = upstream.iter().map(|u| format!("\"{u}\"")).collect();
                let fwd = list.join(", ");

                // What: one forward entry per chosen domain
                // Why: "domains" mode forwards only those.
                // From: Issue #1683 | PR #1980
                let entries: String = upstream_zones(s)?
                    .iter()
                    .map(|z| format!("    - zone: \"{z}\"\n      forwarders: [{fwd}]\n"))
                    .collect();
                format!("  forward_zones_recurse:\n{entries}")
            };
            let aaaa = if s.flag("DNS_FILTER_AAAA")? {
                format!(
                    "  lua_dns_script: \"{}\"\n",
                    q(s.text("RECURSOR_AAAA_LUA_FILE")?)?
                )
            } else {
                String::new()
            };
            let snmp = if s.flag("SNMP_AGENTX")? {
                format!(
                    "snmp:\n  agent: true\n  daemon_socket: \"{}\"\n",
                    q(s.text("SNMP_AGENTX_SOCKET")?)?
                )
            } else {
                String::new()
            };
            let negttl = u("RECURSOR_MAX_NEGATIVE_TTL")?;
            let mut y = String::new();
            y += "incoming:\n  listen:\n";
            y += &yaml_list(&s.list(&which.key("LISTEN"))?, "    ")?;
            y += &format!("  port: {}\n  allow_from:\n", u(&which.key("PORT"))?);
            y += &yaml_list(&s.list("DNS_QUERY_ALLOW_FROM")?, "    ")?;
            // What: dnsdist passes the client IP by header.
            // Why: allow_from and logs see the real client.
            // From: Issue #1683 | PR #2017
            let proxy = crate::shared::dnsdist_conf::source_of(s)?;
            y += &format!("  proxy_protocol_from:\n{}", yaml_list(&[proxy], "    ")?);
            // What: NOTIFY from the own pdns wipes a zone.
            // Why: secondary has no ui to flush after AXFR
            // From: Issue #1683 | PR #2017
            if crate::shared::dns::Role::from_settings(s)? == crate::shared::dns::Role::Secondary {
                let names: Vec<String> = zones
                    .iter()
                    .map(|z| crate::shared::dns::bare_zone(z).to_string())
                    .collect();
                y += &format!("  allow_notify_for:\n{}", yaml_list(&names, "    ")?);
                let from = [s.text("LOOPBACK_BIND_IP")?];
                y += &format!("  allow_notify_from:\n{}", yaml_list(&from, "    ")?);
            }
            y += &format!(
                "recursor:\n  serve_rfc1918: {}\n",
                s.flag("DNS_LOCAL_REVERSE_ZONES")?
            );
            y += &format!("  socket_dir: \"{}\"\n", q(s.text("RECURSOR_RUN_DIR")?)?);
            y += &format!("  forward_zones:\n{local}{recurse}");
            y += &format!("  lua_config_file: \"{lua_file}\"\n{aaaa}");
            y += &format!(
                "  minimum_ttl_override: {}\n",
                u("RECURSOR_MINIMUM_TTL_OVERRIDE")?
            );
            y += &format!(
                "recordcache:\n  max_entries: {}\n",
                u("RECURSOR_RECORDCACHE_MAX_ENTRIES")?
            );
            y += &format!(
                "  refresh_on_ttl_perc: {}\n",
                u("RECURSOR_REFRESH_ON_TTL_PERC")?
            );
            y += &format!(
                "  serve_stale_extensions: {}\n",
                u("RECURSOR_SERVE_STALE_EXTENSIONS")?
            );
            y += &format!("  max_negative_ttl: {negttl}\n");
            y += &format!(
                "packetcache:\n  max_entries: {}\n",
                u("RECURSOR_PACKETCACHE_MAX_ENTRIES")?
            );
            y += &format!(
                "  ttl: {}\n  negative_ttl: {negttl}\n",
                u("RECURSOR_PACKETCACHE_TTL")?
            );
            y += &format!("  servfail_ttl: {}\n", u("RECURSOR_SERVFAIL_TTL")?);
            y += &format!(
                "webservice:\n  webserver: true\n  address: \"{}\"\n",
                q(s.text("PDNS_API_LISTEN")?)?
            );
            y += &format!("  port: {}\n  allow_from:\n", u(&which.key("API_PORT"))?);
            y += &yaml_list(&s.list("PDNS_API_ALLOW_FROM")?, "    ")?;
            y += &format!("  api_key: \"{api_key}\"\n");
            // What: the web password is the API key too.
            // Why: unset, stats and flush answer keyless.
            // From: Issue #1683 | PR #2020
            y += &format!("  password: \"{api_key}\"\n");
            // What: query log raises level and drops quiet.
            // Why: the admin follows DNS queries in log.
            // From: Issue #1683 | PR #1980
            let (level, quiet) = if s.flag("DNS_QUERY_LOG")? {
                (u("RECURSOR_LOGLEVEL_QUERIES")?, "  quiet: false\n")
            } else {
                (u("RECURSOR_LOGLEVEL")?, "")
            };
            y += &format!("logging:\n  loglevel: {level}\n{quiet}{snmp}");
            Ok(y)
        }
    }

    // What: dnsdist.conf in front of pdns and recursors.
    // Why: queries, NOTIFY and AXFR share port 53.
    // From: Issue #1683 | PR #2017
    pub mod dnsdist_conf {
        use crate::config::Settings;

        // What: the sender address from settings, checked.
        // Why: pdns, recursor and dnsdist name same one.
        // From: Issue #1683 | PR #2017
        pub fn source_of(s: &Settings) -> Result<String, String> {
            source(
                &s.text("DNSDIST_SOURCE_ADDRESS")?,
                &s.text("LOOPBACK_BIND_IP")?,
            )
        }

        // What: sender address of dnsdist to its backends.
        // Why: only this address sends proxy protocol.
        // From: Issue #1683 | PR #2017
        pub fn source(raw: &str, loopback: &str) -> Result<String, String> {
            let no_v4 = || format!("DNSDIST_SOURCE_ADDRESS={raw} is no IPv4 address");
            let ip = match crate::shared::dns::parse_ip(raw) {
                Ok(std::net::IpAddr::V4(ip)) => ip,
                _ => return Err(no_v4()),
            };
            if !ip.is_loopback() {
                return Err(format!(
                    "DNSDIST_SOURCE_ADDRESS={raw} is not in 127.0.0.0/8"
                ));
            }
            // What: must differ from LOOPBACK_BIND_IP.
            // Why: recursor to pdns runs from it, no header
            // From: Issue #1683 | PR #2017
            if raw == loopback {
                return Err(format!(
                    "DNSDIST_SOURCE_ADDRESS={raw} equals LOOPBACK_BIND_IP"
                ));
            }
            Ok(raw.to_string())
        }

        // What: one dnsdist port and its recursor.
        // Why: HTTP and HTTPS mode keep their own caches.
        // From: Issue #1683 | PR #2017
        pub struct Listener {
            pub port: u64,
            pub pool: &'static str,
            pub backend: String,
        }

        // What: dnsdist Lua config from plain values.
        // Why: no Settings needed; the tests call it.
        // From: Issue #1683 | PR #2017
        pub fn body(
            listen: &[String],
            acl: &[String],
            source: &str,
            auth: &str,
            listeners: &[Listener],
        ) -> Result<String, String> {
            let first = listeners.first().ok_or("dnsdist needs a listener")?;
            let mut out = String::from("setACL({})\n");
            for net in acl {
                out += &format!(
                    "addACL(\"{}\")\n",
                    crate::config::checked(crate::config::Syntax::Quoted, net)?
                );
            }
            let mut call = "setLocal";
            for l in listeners {
                for addr in listen {
                    let addr = crate::config::checked(crate::config::Syntax::Quoted, addr)?;
                    // What: the listener port is its own.
                    // Why: "addr:port" doubles the port.
                    // From: Issue #1683 | PR #2020
                    if crate::shared::dns::split_host_port(addr)?.1.is_some() {
                        return Err(format!("DNSDIST_LISTEN: {addr} has a port"));
                    }
                    let local = crate::shared::dns::host_port(addr, l.port);
                    out += &format!("{call}(\"{local}\")\n");
                    call = "addLocal";
                }
            }
            let source = crate::config::checked(crate::config::Syntax::Quoted, source)?;
            let mut server = |pool: &str, address: &str| -> Result<(), String> {
                out += &format!(
                    "newServer({{address=\"{}\", pool=\"{pool}\", name=\"{pool}\", source=\"{source}\", useProxyProtocol=true, healthCheckMode=\"up\"}})\n",
                    crate::config::checked(crate::config::Syntax::Quoted, address)?
                );
                Ok(())
            };
            server("auth", auth)?;
            for l in listeners {
                server(l.pool, &l.backend)?;
            }
            // What: NOTIFY, XFR and non-RD queries to pdns.
            // Why: a secondary asks SOA and AXFR without RD
            // From: Issue #1683 | PR #2017
            out += &format!(
                "addAction(AndRule({{DSTPortRule({}), OrRule({{OpcodeRule(DNSOpcode.Notify), QTypeRule(DNSQType.AXFR), QTypeRule(DNSQType.IXFR), NotRule(RDRule())}})}}), PoolAction(\"auth\"))\n",
                first.port
            );
            for l in listeners {
                out += &format!(
                    "addAction(DSTPortRule({}), PoolAction(\"{}\"))\n",
                    l.port, l.pool
                );
            }
            Ok(out)
        }

        // What: full dnsdist.conf for this node.
        // Why: the ACL adds the replication peers.
        // From: Issue #1683 | PR #2017
        pub fn render(s: &Settings) -> Result<String, String> {
            let lo = s.text("LOOPBACK_BIND_IP")?;
            let source = source_of(s)?;
            // What: peers pass the ACL besides the clients.
            // Why: NOTIFY and AXFR reach port 53 too.
            // From: Issue #1683 | PR #2017
            let peers = match crate::shared::dns::Role::from_settings(s)? {
                crate::shared::dns::Role::Primary => crate::shared::pdns_conf::secondary_ips(s)?,
                crate::shared::dns::Role::Secondary => vec![s.text("DNS_XFR_PRIMARY")?],
            };
            let mut acl: Vec<String> = Vec::new();
            for net in s.list("DNS_QUERY_ALLOW_FROM")?.into_iter().chain(peers) {
                crate::config::add_once(&mut acl, &net);
            }
            let auth = crate::shared::pdns_conf::auth_endpoint(s)?;
            let mut listeners = vec![Listener {
                port: s.uint("DNS_PORT")?,
                pool: "http",
                backend: crate::shared::dns::host_port(&lo, s.uint("RECURSOR_HTTP_PORT")?),
            }];
            // What: HTTPS port only when HTTPS has own IP.
            // Why: IP_HTTPS must not wake HTTPS when off.
            // From: Issue #1683 | PR #2017
            if crate::shared::dns::https_ip(s)?.is_some() {
                listeners.push(Listener {
                    port: s.uint("DNS_HTTPS_PORT")?,
                    pool: "https",
                    backend: crate::shared::dns::host_port(&lo, s.uint("RECURSOR_HTTPS_PORT")?),
                });
            }
            body(&s.list("DNSDIST_LISTEN")?, &acl, &source, &auth, &listeners)
        }
    }

    // What: Kea config files built from the settings.
    // Why: one place turns SOT values into Kea JSON.
    // From: Issue #1683 | PR #1980
    pub mod kea_conf {
        use crate::config::Settings;
        use serde_json::{Value, json};

        // What: fixed Kea protocol words.
        // Why: Kea accepts only these; not tunable.
        // From: Issue #1683 | PR #1980
        const SOCKET_KIND: &str = "unix";
        // What: Kea lease database type.
        // Why: Kea accepts only this value here.
        // From: Issue #1683 | PR #2020
        const LEASE_BACKEND: &str = "memfile";
        // What: Kea NCR protocol.
        // Why: Kea D2 takes only UDP here.
        // From: Issue #1683 | PR #2020
        const NCR_PROTOCOL: &str = "UDP";
        // What: Kea NCR format.
        // Why: Kea D2 takes only JSON here.
        // From: Issue #1683 | PR #2020
        const NCR_FORMAT: &str = "JSON";
        // What: Kea log output.
        // Why: all Kea loggers write to stdout.
        // From: Issue #1683 | PR #2020
        const LOG_OUTPUT: &str = "stdout";

        // What: one Kea logger row per given name.
        // Why: all Kea loggers share level and output.
        // From: Issue #1683 | PR #1980
        fn log_rows(s: &Settings, names: &[&str]) -> Result<Value, String> {
            let level = s.text("KEA_LOG_SEVERITY")?;
            let depth = s.uint("KEA_LOG_DEBUGLEVEL")?;
            let rows: Vec<Value> = names
                .iter()
                .map(|n| {
                    json!({"name": n, "severity": level, "debuglevel": depth,
                       "output-options": [{"output": LOG_OUTPUT}]})
                })
                .collect();
            Ok(Value::Array(rows))
        }

        // What: the LAN zone without its final dot.
        // Why: DHCP options carry the name without the dot.
        // From: Issue #1683 | PR #1980
        fn lan_domain(s: &Settings) -> Result<String, String> {
            let zone = crate::shared::dns::lan_zone(s)?;
            Ok(crate::shared::dns::bare_zone(&zone).to_string())
        }

        // What: the control socket entry of Kea DHCPv4.
        // Why: commands reach Kea through this socket.
        // From: Issue #1683 | PR #1980
        fn socket(s: &Settings) -> Result<Value, String> {
            Ok(json!({"socket-type": SOCKET_KIND,
                  "socket-name": s.text("KEA_DHCP4_SOCKET")?}))
        }

        // What: domain-name, domain-search of kept subnets.
        // Why: kept subnets follow a changed LAN domain.
        // From: Issue #1683 | PR #1980
        fn follow_domain(mut subnets: Value, before: Option<&str>, domain: &str) -> Value {
            let Some(before) = before.filter(|b| *b != domain) else {
                return subnets;
            };
            let opts = subnets.as_array_mut().into_iter().flatten();
            let rows = opts
                .filter_map(|sn| sn["option-data"].as_array_mut())
                .flatten();
            for row in rows {
                let name = row["name"].as_str().unwrap_or_default();
                let follows = [
                    crate::shared::dhcp::DOMAIN_NAME,
                    crate::shared::dhcp::DOMAIN_SEARCH,
                ];
                let hit =
                    follows.iter().any(|m| m.name == name) && row["data"].as_str() == Some(before);
                if hit {
                    row["data"] = Value::from(domain);
                }
            }
            subnets
        }

        // What: ntp-servers of kept subnets follow own NTP.
        // Why: while on, toggle owns option 42 everywhere.
        // From: Issue #1683 | PR #2017
        pub(crate) fn follow_ntp(mut subnets: Value, auto: bool, own: &str, back: &str) -> Value {
            for sn in subnets.as_array_mut().into_iter().flatten() {
                if auto && sn.get("option-data").is_none() {
                    sn["option-data"] = json!([]);
                }
                let Some(rows) = sn["option-data"].as_array_mut() else {
                    continue;
                };
                let ntp = crate::shared::dhcp::NTP_SERVERS.name;
                let at = rows.iter().position(|r| r["name"] == ntp);
                match at {
                    Some(i) if auto => rows[i]["data"] = Value::from(own),
                    None if auto => rows.push(json!({"name": ntp, "data": own})),
                    // What: off returns own IP to default.
                    // Why: no NTP answers there when off.
                    // From: Issue #1683 | PR #2017
                    Some(i) if rows[i]["data"] == own && back.is_empty() => {
                        rows.remove(i);
                    }
                    Some(i) if rows[i]["data"] == own => rows[i]["data"] = Value::from(back),
                    _ => {}
                }
            }
            subnets
        }

        // What: subnet DDNS suffix from its domain-name.
        // Why: Kea D2 picks the zone by the FQDN suffix.
        // From: Issue #1683 | PR #2020
        pub fn subnet_ddns_suffix(s: &Settings, subnet: &mut Value) -> Result<(), String> {
            let lans = crate::shared::dns::lan_domains(s)?;
            let domain =
                crate::shared::dhcp::option_data(subnet, crate::shared::dhcp::DOMAIN_NAME.name);
            let zone = Some(domain)
                .filter(|d| !d.is_empty())
                .map(|d| crate::shared::dns::canonical_zone(&d));
            let Some(obj) = subnet.as_object_mut() else {
                return Err("subnet is no JSON object".into());
            };
            // What: the main domain uses the global suffix.
            // Why: a foreign domain-name has no zone here.
            // From: Issue #1683 | PR #2020
            match zone.filter(|z| lans.iter().skip(1).any(|l| l == z)) {
                Some(z) => obj.insert("ddns-qualifying-suffix".into(), Value::from(z)),
                None => obj.remove("ddns-qualifying-suffix"),
            };
            Ok(())
        }

        // What: the option rows of the SOT subnet.
        // Why: router, DNS, domain and NTP come from SOT.
        // From: Issue #1683 | PR #1980
        fn option_rows(s: &Settings, domain: &str) -> Result<Vec<Value>, String> {
            let dns = crate::shared::dhcp::dns_addrs(s)?;
            let ntp = crate::shared::dhcp::ntp_addrs(s)?;
            let mut rows = named_rows(&s.text("DHCP_GATEWAY")?, &dns, domain, &ntp);
            let raw = s.text_or_empty("DHCP_CUSTOM_OPTIONS");
            for (code, data) in crate::shared::dhcp::custom_options(s, &raw)? {
                rows.push(coded_row(code, &data));
            }
            Ok(rows)
        }

        // What: the named options of one Kea subnet.
        // Why: settings and subnet form give the same rows.
        // From: Issue #1683 | PR #2020
        pub fn named_rows(
            gateway: &str,
            dns: &[String],
            domain: &str,
            ntp: &[String],
        ) -> Vec<Value> {
            use crate::shared::dhcp::{
                DNS_SERVERS, DOMAIN_NAME, DOMAIN_SEARCH, NTP_SERVERS, ROUTERS,
            };
            let mut rows = vec![
                json!({"name": ROUTERS.name, "data": gateway}),
                json!({"name": DNS_SERVERS.name, "data": dns.join(", ")}),
            ];
            if !domain.is_empty() {
                rows.push(json!({"name": DOMAIN_NAME.name, "data": domain}));
                rows.push(json!({"name": DOMAIN_SEARCH.name, "data": domain}));
            }
            if !ntp.is_empty() {
                rows.push(json!({"name": NTP_SERVERS.name, "data": ntp.join(", ")}));
            }
            rows
        }

        // What: the pool of a subnet as Kea writes it.
        // Why: settings and the subnet form use one form.
        // From: Issue #1683 | PR #2017
        pub fn pool_text(start: &str, end: &str) -> String {
            format!("{start} - {end}")
        }

        // What: subnet list of a Kea config; none: empty.
        // Why: one reader of where Kea keeps its subnets.
        // From: Issue #1683 | PR #2020
        pub fn subnets(cfg: &Value) -> &[Value] {
            cfg["Dhcp4"]["subnet4"]
                .as_array()
                .map_or(&[][..], Vec::as_slice)
        }

        // What: put a subnet list into a Kea config.
        // Why: the writer of the place subnets reads.
        // From: Issue #1683 | PR #2020
        pub fn set_subnets(cfg: &mut Value, subnets: Vec<Value>) {
            cfg["Dhcp4"]["subnet4"] = Value::Array(subnets);
        }

        // What: start and end of a pool text.
        // Why: one place knows the pool form for both ways.
        // From: Issue #1683 | PR #2020
        pub fn pool_parts(pool: &str) -> (&str, &str) {
            let (start, end) = pool.split_once('-').unwrap_or(("", ""));
            (start.trim(), end.trim())
        }

        // What: an option row given by code, not name.
        // Why: settings and the subnet edit write one form.
        // From: Issue #1683 | PR #2020
        pub fn coded_row(code: u8, data: &str) -> Value {
            json!({"code": code, "data": data})
        }

        // What: the option code of a row, if a number.
        // Why: edits find a row by the code coded_row set.
        // From: Issue #1683 | PR #2020
        pub fn row_code(option: &Value) -> Option<u64> {
            option["code"].as_u64()
        }

        // What: true for an option given by code, not name.
        // Why: such rows are the user's own options.
        // From: Issue #1683 | PR #2017
        pub fn is_coded(option: &Value) -> bool {
            option.get("name").is_none()
        }

        // What: the coded options of a subnet.
        // Why: they survive every rewrite of the subnet.
        // From: Issue #1683 | PR #2017
        pub fn coded_options(subnet: &Value) -> Vec<Value> {
            let rows = subnet["option-data"].as_array().into_iter().flatten();
            rows.filter(|o| is_coded(o)).cloned().collect()
        }

        // What: kea-dhcp4.conf; main subnet from settings.
        // Why: the settings are the only source of it.
        // From: Issue #1683 | PR #2020
        pub fn dhcp4(s: &Settings, existing: Option<&Value>) -> Result<Value, String> {
            let domain = lan_domain(s)?;
            let (valid, max) = crate::shared::dhcp::lease_limits(s, s.uint("DHCP_LEASE_TIME")?)?;
            let pool = pool_text(&s.text("DHCP_RANGE_START")?, &s.text("DHCP_RANGE_END")?);
            // What: last main domain, if no LAN domain now.
            // Why: kept subnets follow only dropped domain.
            // From: Issue #1683 | PR #2020
            let lans = crate::shared::dns::lan_domains(s)?;
            let before = existing
                .and_then(|e| e.pointer("/Dhcp4/ddns-qualifying-suffix"))
                .and_then(Value::as_str)
                .filter(|d| !lans.contains(&crate::shared::dns::canonical_zone(d)))
                .map(|d| crate::shared::dns::bare_zone(d).to_string());
            let id = s.uint("DHCP_SUBNET_ID")?;
            let net = s.text("DHCP_SUBNET")?;
            let kept = Value::Array(existing.map_or(&[][..], subnets).to_vec());
            let kept = follow_domain(kept, before.as_deref(), &domain);
            let back = crate::shared::dhcp::ntp_addrs(s)?.join(", ");
            let own = s.text("IP_HTTP")?;
            let kept = follow_ntp(kept, crate::shared::dhcp::own_ntp(s)?, &own, &back);
            let old = kept.as_array().into_iter().flatten();
            let old_main = old.clone().find(|x| x["id"].as_u64() == Some(id));
            let mut main = json!({
                "id": id,
                "subnet": net,
                "pools": [{"pool": pool}],
                "option-data": option_rows(s, &domain)?,
                "valid-lifetime": valid,
                "max-valid-lifetime": max
            });
            // What: old main hosts in subnet, coded options
            // Why: ui-made; Kea refuses hosts off-subnet.
            // From: Issue #1683 | PR #2017
            if let Some(o) = old_main {
                if let Some(hosts) = o.get("reservations").and_then(Value::as_array) {
                    let fit: Vec<Value> = hosts
                        .iter()
                        .filter(|h| {
                            let ok = h["ip-address"]
                                .as_str()
                                .is_none_or(|ip| crate::shared::dns::net_holds(&net, ip));
                            if !ok {
                                eprintln!("kea: reservation {h} is outside {net}; dropped");
                            }
                            ok
                        })
                        .cloned()
                        .collect();
                    main["reservations"] = fit.into();
                }
                let coded = coded_options(o);
                if let Some(rows) = main["option-data"].as_array_mut() {
                    rows.extend(coded);
                }
            }
            let mut subnets = vec![main];
            for mut sn in old.filter(|x| x["id"].as_u64() != Some(id)).cloned() {
                subnet_ddns_suffix(s, &mut sn)?;
                subnets.push(sn);
            }
            let updates = s.flag("DHCP_DDNS")?;
            let mut cfg = json!({"Dhcp4": {
                "interfaces-config": {
                    "interfaces": s.list("DHCP_PROXY_INTERFACE")?,
                    "re-detect": false
                },
                "lease-database": {
                    "type": LEASE_BACKEND,
                    "persist": true,
                    "name": s.text("KEA_LEASE_FILE")?
                },
                "control-socket": socket(s)?,
                "hooks-libraries": [{"library": s.text("KEA_LEASE_CMDS_HOOK")?}],
                "dhcp-ddns": {
                    "enable-updates": updates,
                    "server-ip": s.text("KEA_DDNS_ADDRESS")?,
                    "server-port": s.uint("KEA_DDNS_PORT")?,
                    "max-queue-size": s.uint("KEA_NCR_MAX_QUEUE")?,
                    "ncr-protocol": NCR_PROTOCOL,
                    "ncr-format": NCR_FORMAT
                },
                "ddns-send-updates": updates,
                "ddns-override-no-update": true,
                "ddns-override-client-update": true,
                "ddns-replace-client-name": s.text("KEA_DDNS_REPLACE_CLIENT_NAME")?,
                "ddns-generated-prefix": s.text("KEA_DDNS_GENERATED_PREFIX")?,
                "ddns-qualifying-suffix": crate::shared::pdns::zone_id(&domain),
                "loggers": log_rows(s, &["kea-dhcp4", "kea-dhcp4.packets"])?
            }});
            set_subnets(&mut cfg, subnets);
            Ok(cfg)
        }

        // What: kea-ctrl-agent.conf with basic-auth login.
        // Why: threat model G2: the LAN port needs a login.
        // From: Issue #1683 | PR #1985
        pub fn ctrl_agent(s: &Settings, token: &str) -> Result<Value, String> {
            Ok(json!({"Control-agent": {
                "http-host": s.text("KEA_CTRL_ADDRESS")?,
                "http-port": s.uint("KEA_CTRL_PORT")?,
                "authentication": {
                    "type": "basic",
                    "realm": "lancache",
                    "clients": [{"user": s.text("KEA_CTRL_USER")?, "password": token}]
                },
                "control-sockets": {"dhcp4": socket(s)?},
                "loggers": log_rows(s, &["kea-ctrl-agent"])?
            }}))
        }

        // What: kea-dhcp-ddns.conf, forward and reverse.
        // Why: name updates go to local pdns with TSIG.
        // From: Issue #1683 | PR #1980
        pub fn ddns(s: &Settings, key: &str, secret: &str) -> Result<Value, String> {
            let target = json!([{
                "ip-address": s.text("PDNS_AUTH_ADDRESS")?,
                "port": s.uint("PDNS_AUTH_PORT")?
            }]);
            let entry = |zone: &str| json!({"name": zone, "key-name": key, "dns-servers": target});
            // What: one forward entry per LAN domain.
            // Why: D2 rejects name outside all listed zones
            // From: Issue #1683 | PR #2020
            let forward: Vec<Value> = crate::shared::dns::lan_domains(s)?
                .iter()
                .map(|z| entry(z))
                .collect();
            let reverse: Vec<Value> = crate::shared::dns::private_reverse_zones(s)?
                .iter()
                .map(|z| entry(z))
                .collect();
            Ok(json!({"DhcpDdns": {
                "ip-address": s.text("KEA_DDNS_ADDRESS")?,
                "port": s.uint("KEA_DDNS_PORT")?,
                "tsig-keys": [{
                    "name": key,
                    "algorithm": s.text("DDNS_TSIG_ALGORITHM")?,
                    "secret": secret
                }],
                "forward-ddns": {"ddns-domains": forward},
                "reverse-ddns": {"ddns-domains": reverse},
                "loggers": log_rows(s, &["kea-dhcp-ddns"])?
            }}))
        }
    }

    // What: dnsmasq.conf for proxy-DHCP or relay.
    // Why: one owner; a bad value stops the render.
    // From: Issue #1683 | PR #1980
    pub mod dnsmasq_conf {
        use crate::config::{Settings, Syntax};
        use crate::shared::dhcp::Mode;

        // What: the text of one dnsmasq.conf in progress.
        // Why: rows go in only through the checked methods.
        // From: Issue #1683 | PR #1980
        struct Conf(String);

        // What: methods of the dnsmasq Conf.
        // Why: rows go in only through checked methods.
        // From: Issue #1683 | PR #2020
        impl Conf {
            // What: appends one row; refuses a line break.
            // Why: a line break would start a new row.
            // From: Issue #1683 | PR #1980
            fn add(&mut self, row: &str) -> Result<(), String> {
                if !crate::config::safe(Syntax::Line, row) {
                    return Err(format!("dnsmasq row {row:?} has a line break"));
                }
                self.0.push_str(row);
                self.0.push('\n');
                Ok(())
            }
            // What: appends prefix plus value unless empty.
            // Why: an empty value gives a broken row.
            // From: Issue #1683 | PR #1980
            fn add_if(&mut self, prefix: &str, value: &str) -> Result<(), String> {
                if value.is_empty() {
                    return Ok(());
                }
                self.add(&format!("{prefix}{value}"))
            }
        }

        // What: the rows every dnsmasq mode starts with.
        // Why: port=0: dnsmasq serves DHCP only, no DNS.
        // From: Issue #1683 | PR #1980
        fn base(s: &Settings) -> Result<Conf, String> {
            let mut c = Conf(String::new());
            for row in ["port=0", "no-resolv", "no-poll", "log-facility=-"] {
                c.add(row)?;
            }
            if s.flag("DHCP_LOG_PACKETS")? {
                c.add("log-dhcp")?;
            }
            Ok(c)
        }

        // What: pxe-service rows for BIOS and UEFI clients.
        // Why: no server or no file: nothing to offer.
        // From: Issue #1683 | PR #1980
        fn pxe(s: &Settings, c: &mut Conf) -> Result<(), String> {
            let get = |k: &str| s.text_or_empty(k);
            let server = get("DHCP_PROXY_PXE_BOOT_SERVER");
            let bios = get("DHCP_PROXY_PXE_BOOT_FILENAME_BIOS");
            let uefi = get("DHCP_PROXY_PXE_BOOT_FILENAME_UEFI");
            if server.is_empty() || (bios.is_empty() && uefi.is_empty()) {
                return Ok(());
            }
            if bios.is_empty() {
                c.add("pxe-service=IA64_EFI,\"lancache-ng PXE proxy active\",0")?;
            } else {
                let label = "\"lancache-ng PXE boot (BIOS)\"";
                c.add(&format!("pxe-service=x86PC,{label},{bios},{server}"))?;
                c.add("dhcp-match=set:pxe-bios,option:client-arch,0")?;
                c.add(&format!("dhcp-boot=tag:pxe-bios,{bios},,{server}"))?;
            }
            if !uefi.is_empty() {
                for arch in [7, 11] {
                    c.add(&format!(
                        "dhcp-match=set:pxe-uefi,option:client-arch,{arch}"
                    ))?;
                }
                c.add(&format!("dhcp-boot=tag:pxe-uefi,{uefi},,{server}"))?;
            }
            Ok(())
        }

        // What: proxy range; empty start = own LAN IP.
        // Why: a fixed range start may miss the real LAN.
        // From: Issue #1683 | PR #1991
        fn proxy_range(s: &Settings) -> Result<String, String> {
            let start = s.text_or_empty("DHCP_SUBNET_START");
            if !start.is_empty() {
                return Ok(format!("{start},proxy"));
            }
            // What: dnsmasq takes the mask from the NIC.
            // Why: the dhcp container runs on the host net.
            // From: Issue #1683 | PR #1991
            Ok(format!("{},proxy", s.text("IP_HTTP")?))
        }

        // What: render dnsmasq.conf for one mode.
        // Why: Off and Kea start no dnsmasq at all.
        // From: Issue #1683 | PR #1980
        pub fn render(s: &Settings, mode: Mode) -> Result<String, String> {
            let mut c = base(s)?;
            if mode == Mode::DnsmasqRelay {
                // What: empty relay address = this host IP.
                // Why: mode switch needs no further input.
                // From: Issue #1683 | PR #1985
                let local = s
                    .text("DHCP_RELAY_LOCAL_ADDR")
                    .ok()
                    .or_else(|| {
                        crate::shared::recursor_conf::own_ips(s)
                            .into_iter()
                            .find(|ip| !crate::shared::dns::is_loopback(ip))
                    })
                    .ok_or("DHCP-Relay: DHCP_RELAY_LOCAL_ADDR is not set")?;
                let upstream = s.text("UPSTREAM_DHCP_IP").map_err(|_| {
                    "DHCP-Relay needs the real DHCP server: UPSTREAM_DHCP_IP".to_string()
                })?;
                c.add(&format!("dhcp-relay={local},{upstream}"))?;
                return Ok(c.0);
            }
            if mode != Mode::DnsmasqProxy {
                return Err(format!("no dnsmasq in DHCP mode {mode:?}"));
            }
            let get = |k: &str| s.text_or_empty(k);
            c.add(&format!("dhcp-range={}", proxy_range(s)?))?;
            c.add_if("interface=", &s.list("DHCP_PROXY_INTERFACE")?.join(","))?;
            use crate::shared::dhcp::{DNS_SERVERS, DOMAIN_NAME, NTP_SERVERS, ROUTERS};
            let by_code = |m: crate::shared::dhcp::Managed| format!("dhcp-option-pxe={},", m.code);
            c.add_if(&by_code(ROUTERS), &get("DHCP_PROXY_ROUTER"))?;
            c.add_if(
                &by_code(DNS_SERVERS),
                &crate::shared::dhcp::dns_addrs(s)?.join(","),
            )?;
            c.add_if(&by_code(DOMAIN_NAME), &get("DHCP_PROXY_DOMAIN"))?;
            c.add_if(
                &by_code(NTP_SERVERS),
                &crate::shared::dhcp::ntp_addrs(s)?.join(","),
            )?;
            let file = get("DHCP_PROXY_BOOT_FILENAME");
            if !file.is_empty() {
                let server = get("DHCP_PROXY_BOOT_SERVER");
                c.add(&format!("dhcp-boot={file},,{server}"))?;
            }
            let raw = get("DHCP_CUSTOM_OPTIONS");
            for (code, data) in crate::shared::dhcp::custom_options(s, &raw)? {
                c.add(&format!("dhcp-option-pxe={code},{data}"))?;
            }
            pxe(s, &mut c)?;
            Ok(c.0)
        }
    }

    // What: generated nginx include files and cert plan.
    // Why: one owner of CDN host maps, ACL and dispatch.
    // From: Issue #1683 | PR #1980
    pub mod nginx_conf {
        use crate::config::{Settings, Syntax};
        use sha2::{Digest, Sha256};
        use std::collections::BTreeSet;

        // What: all seven numbers of nginx stub_status.
        // Why: one reader for dashboard, graphs, REST, CLI.
        // From: Issue #1683 | PR #2020
        pub async fn live(s: &Settings) -> Result<serde_json::Value, String> {
            let url = s.text("PROXY_STATUS_URL")?;
            let resp = crate::shared::http::client(s)?
                .get(&url)
                .send()
                .await
                .map_err(|e| format!("{url}: {}", crate::shared::http::error_chain(&e)))?;
            let resp = resp.error_for_status().map_err(|e| format!("{url}: {e}"))?;
            let max = crate::shared::http::max_body(s)?;
            let body = crate::shared::http::read_text(resp, max, &url).await?;
            stub_status(&body).ok_or_else(|| format!("{url}: no stub_status text"))
        }

        // What: the stub_status text as named numbers.
        // Why: nginx gives plain text; readers need fields.
        // From: Issue #1683 | PR #1980
        pub fn stub_status(body: &str) -> Option<serde_json::Value> {
            let nums: Vec<u64> = body
                .split_whitespace()
                .filter_map(|w| w.parse().ok())
                .collect();
            let [
                active,
                accepts,
                handled,
                requests,
                reading,
                writing,
                waiting,
            ] = nums.as_slice()
            else {
                return None;
            };
            Some(serde_json::json!({
                "active": active, "accepts": accepts, "handled": handled,
                "requests": requests, "reading": reading, "writing": writing,
                "waiting": waiting
            }))
        }

        // What: what one proxy command does.
        // Why: the match runs these; the table names them.
        // From: Issue #1683 | PR #2020
        #[derive(Clone, Copy, PartialEq)]
        enum Op {
            Status,
            Log,
            Psl,
            Certs,
        }

        // What: every command of the proxy group.
        // Why: help, errors and the choice read this table.
        // From: Issue #1683 | PR #2020
        const COMMANDS: [(&str, crate::shared::cli::Entry<Op>); 4] = [
            ("status", crate::shared::cli::row(Op::Status, "status")),
            ("log", crate::shared::cli::row(Op::Log, "log")),
            ("psl", crate::shared::cli::row(Op::Psl, "psl <host>")),
            (
                "certs",
                crate::shared::cli::row(Op::Certs, "certs [check|renew]"),
            ),
        ];

        // What: lancache-ng proxy status|log as JSON.
        // Why: proxy reads have their CLI with their owner.
        // From: Issue #1683 | PR #2020
        pub async fn run(args: &[String]) -> Result<(), String> {
            let s = crate::config::Settings::from_process()?;
            use crate::shared::cli;
            let v = match cli::op_of(&COMMANDS, args.first()) {
                Some(Op::Status) => live(&s).await?,
                Some(Op::Log) => crate::shared::access::summary(&s).await?,
                // What: how the proxy maps one host name.
                // Why: root, cache match and cert per host.
                // From: Issue #1683 | PR #2020
                Some(Op::Psl) => match args.get(1) {
                    Some(host) => crate::shared::render::psl_lookup(&s, host)?,
                    None => return Err(cli::usage(&COMMANDS, |o| *o == Op::Psl)),
                },
                // What: certs list; check: rc 1; renew: ui.
                // Why: renew reloads the proxy like apply.
                // From: Issue #1683 | PR #2020
                Some(Op::Certs) => match args.get(1).map(String::as_str) {
                    None | Some("check") => crate::shared::render::cert_list(&s)?,
                    Some("renew") => {
                        let route = s.text("UI_ROUTE_PROXY_CERTS_RENEW")?;
                        let body = crate::shared::http::Body::Form(vec![]);
                        crate::shared::http::ui_socket(&s, &route, body).await?
                    }
                    Some(x) => {
                        return Err(format!(
                            "{x}: {}",
                            cli::usage(&COMMANDS, |o| *o == Op::Certs)
                        ));
                    }
                },
                None => return Err(crate::shared::cli::help(&COMMANDS)),
            };
            println!("{v}");
            let check = args.get(1).is_some_and(|a| a == "check");
            if check && v["ok"] == false {
                return Err("certs: one needs a renewal or is missing".into());
            }
            Ok(())
        }

        // What: first line of every generated file.
        // Why: tells a reader not to edit it by hand.
        // From: Issue #1683 | PR #1980
        const HEAD: &str = "# Generated by LanCache-NG; do not edit\n";

        // What: Public Suffix List rules.
        // Why: finds the registrable root of a CDN name.
        // From: Issue #1683 | PR #1980
        #[derive(Default)]
        pub struct Psl {
            plain: BTreeSet<String>,
            wild: BTreeSet<String>,
            except: BTreeSet<String>,
        }

        // What: methods of the suffix list Psl.
        // Why: parse, root and TLD test share the rules.
        // From: Issue #1683 | PR #2020
        impl Psl {
            // What: read the PSL text format.
            // Why: publicsuffix.org rows: x, *.x, !x.
            // From: Issue #1683 | PR #1980
            pub fn parse(text: &str) -> Self {
                let mut p = Psl::default();
                for row in text.lines() {
                    let Some(rule) = row.split_whitespace().next() else {
                        continue;
                    };
                    if rule.starts_with("//") {
                        continue;
                    }
                    let rule = rule.to_ascii_lowercase();
                    if let Some(r) = rule.strip_prefix('!') {
                        p.except.insert(r.into());
                    } else if let Some(r) = rule.strip_prefix("*.") {
                        p.wild.insert(r.into());
                    } else {
                        p.plain.insert(rule);
                    }
                }
                p
            }

            // What: label count of the public suffix.
            // Why: exception and wildcard rules change it.
            // From: Issue #1683 | PR #1980
            fn suffix_labels(&self, labels: &[&str]) -> usize {
                let n = labels.len();
                let mut best = 1;
                for i in 0..n {
                    let tail = labels[i..].join(".");
                    if self.except.contains(&tail) {
                        return n - i - 1;
                    }
                    let wild_hit = i + 1 < n && self.wild.contains(&labels[i + 1..].join("."));
                    if self.plain.contains(&tail) || wild_hit {
                        best = best.max(n - i);
                    }
                }
                best
            }

            // What: registrable root: suffix plus one label
            // Why: PSL rule; unknown TLD counts as suffix.
            // From: Issue #1683 | PR #1980
            pub fn root(&self, name: &str) -> Option<String> {
                let labels: Vec<&str> = name.split('.').collect();
                let keep = self.suffix_labels(&labels) + 1;
                (labels.len() >= keep).then(|| labels[labels.len() - keep..].join("."))
            }

            // What: does the Internet know this one label?
            // Why: an unknown ending gets its own top zone.
            // From: Issue #1683 | PR #2019
            pub fn is_tld(&self, label: &str) -> bool {
                let l = label.to_ascii_lowercase();
                self.plain.contains(&l) || self.wild.contains(&l)
            }
        }

        // What: CDN names grouped by nginx handling.
        // Why: roots share a cert; bases and exact own one.
        // From: Issue #1683 | PR #1980
        #[derive(Default)]
        pub struct Hosts {
            pub roots: Vec<String>,
            pub bases: Vec<String>,
            pub exact: Vec<String>,
            pub root_wild: BTreeSet<String>,
        }

        // What: group the cache domain list into Hosts.
        // Why: a bad or rootless row is an error, no skip.
        // From: Issue #1683 | PR #1980
        pub fn hosts(domains: &str, psl: &Psl) -> Result<Hosts, String> {
            let mut h = Hosts::default();
            for (name, wild) in crate::shared::dns::cdn_list(domains)? {
                let root = psl
                    .root(&name)
                    .ok_or_else(|| format!("no registrable root for {name}"))?;
                crate::config::add_once(&mut h.roots, &root);
                let parent = name.split_once('.').map(|(_, p)| p);
                if name == root {
                    if wild {
                        h.root_wild.insert(root);
                    }
                } else if wild {
                    crate::config::add_once(&mut h.bases, &name);
                } else if parent != Some(root.as_str()) {
                    crate::config::add_once(&mut h.exact, &name);
                }
            }
            Ok(h)
        }

        // What: stable cert file name for one host.
        // Why: file names never carry raw host text.
        // From: Issue #1683 | PR #1980
        fn cert_id(host: &str, kind: &str) -> String {
            let sum = Sha256::digest(format!("{kind}:{host}").as_bytes());
            hex::encode(&sum[..16])
        }

        // What: methods of the cache hosts Hosts.
        // Why: keys and certs come from one grouping.
        // From: Issue #1683 | PR #2020
        impl Hosts {
            // What: (server name key, cert name) pairs.
            // Why: feeds the cert map and the allow map.
            // From: Issue #1683 | PR #1980
            pub fn keys(&self) -> Vec<(String, String)> {
                let mut out = Vec::new();
                for r in &self.roots {
                    out.push((format!("*.{r}"), r.clone()));
                    out.push((r.clone(), r.clone()));
                }
                for b in &self.bases {
                    out.push((format!("*.{b}"), cert_id(b, "wildcard")));
                }
                for e in &self.exact {
                    out.push((e.clone(), cert_id(e, "exact")));
                }
                out
            }

            // What: certs to issue: file name and SANs.
            // Why: cert::create_leaf issues exactly these.
            // From: Issue #1683 | PR #1980
            pub fn certs(&self) -> Vec<(String, Vec<String>)> {
                let mut out = Vec::new();
                for r in &self.roots {
                    out.push((r.clone(), vec![r.clone(), format!("*.{r}")]));
                }
                for b in &self.bases {
                    out.push((cert_id(b, "wildcard"), vec![format!("*.{b}")]));
                }
                for e in &self.exact {
                    out.push((cert_id(e, "exact"), vec![e.clone()]));
                }
                out
            }
        }

        // What: fill ${KEY} in a shipped nginx template.
        // Why: values come from settings, not the env.
        // From: Issue #1683 | PR #1980
        pub fn template(text: &str, s: &Settings) -> Result<String, String> {
            let mut out = String::with_capacity(text.len());
            let mut rest = text;
            while let Some(at) = rest.find("${") {
                out.push_str(&rest[..at]);
                let after = &rest[at + 2..];
                let close = after.find('}').ok_or("unclosed ${ in nginx template")?;
                let key = &after[..close];
                let value = s.text(key).map_err(|e| format!("nginx template: {e}"))?;
                if !crate::config::safe(Syntax::Nginx, &value) {
                    return Err(format!("{key} holds nginx syntax characters"));
                }
                out.push_str(&value);
                rest = &after[close + 1..];
            }
            out.push_str(rest);
            Ok(out)
        }

        // What: one aligned key and value row of a map.
        // Why: all nginx map rows share one format.
        // From: Issue #1683 | PR #1980
        fn map_row(out: &mut String, key: &str, value: &str) {
            out.push_str(&format!("    {key:<45} {value};\n"));
        }

        // What: nginx regex for names below a base.
        // Why: one_label limits it to one more label.
        // From: Issue #1683 | PR #1980
        fn ends_with_re(base: &str, one_label: bool) -> String {
            let label = if one_label { "[^.]+" } else { ".+" };
            format!("\"~^{label}\\.{}$\"", base.replace('.', "\\."))
        }

        // What: all settings the files need, read once.
        // Why: one read; a missing key stops the render.
        // From: Issue #1683 | PR #1980
        struct Plan {
            strict: bool,
            cidrs: Vec<String>,
            lo: String,
            refuse: String,
            refuse_relay: String,
            origin: String,
            acl: String,
            timeouts: String,
            passthrough: u64,
            https: u64,
            mitm: u64,
            mitm_relay: String,
            pass_relay: String,
            health: u64,
        }

        // What: reads the settings into a Plan.
        // Why: an unknown security mode stops the render.
        // From: Issue #1683 | PR #1980
        fn load_plan(s: &Settings) -> Result<Plan, String> {
            let strict = match s.text("PROXY_SECURITY_MODE")?.as_str() {
                "strict" => true,
                "lazy" => false,
                other => return Err(format!("PROXY_SECURITY_MODE {other} is not lazy/strict")),
            };
            let lo = s.text("LOOPBACK_BIND_IP")?;
            // What: values that stand in nginx statements.
            // Why: ; braces or line break end a statement.
            // From: Issue #1683 | PR #2020
            let cidrs = s.list("PROXY_ALLOWED_CLIENT_CIDRS")?;
            let acl = s.text("NGINX_CLIENT_ACL_FILE")?;
            for v in cidrs
                .iter()
                .map(String::as_str)
                .chain([lo.as_str(), acl.as_str()])
            {
                crate::config::checked(Syntax::Nginx, v)?;
            }
            let at = |k: &str| -> Result<String, String> {
                Ok(crate::shared::dns::host_port(&lo, s.uint(k)?))
            };
            Ok(Plan {
                strict,
                cidrs,
                refuse: at("NGINX_DISCARD_PORT")?,
                refuse_relay: at("NGINX_REFUSE_RELAY_PORT")?,
                origin: format!(
                    "$ssl_preread_server_name:{}",
                    s.uint("NGINX_ORIGIN_HTTPS_PORT")?
                ),
                acl,
                timeouts: format!(
                    "    proxy_connect_timeout {}s;\n    proxy_timeout {}s;\n",
                    s.uint("NGINX_UPSTREAM_CONNECT_TIMEOUT")?,
                    s.uint("NGINX_UPSTREAM_IDLE_TIMEOUT")?
                ),
                passthrough: s.uint("NGINX_PASSTHROUGH_PORT")?,
                https: s.uint("PROXY_HTTPS_PORT")?,
                mitm: s.uint("NGINX_MITM_PORT")?,
                mitm_relay: at("NGINX_MITM_RELAY_PORT")?,
                pass_relay: at("NGINX_PASSTHROUGH_RELAY_PORT")?,
                health: s.uint("NGINX_HEALTH_HTTPS_PORT")?,
                lo,
            })
        }

        // What: allow rows per client range, then deny.
        // Why: no range set means no restriction.
        // From: Issue #1683 | PR #1980
        fn acl_file(p: &Plan) -> String {
            let mut out = HEAD.to_string();
            for c in &p.cidrs {
                out.push_str(&format!("allow {c};\n"));
            }
            if !p.cidrs.is_empty() {
                out.push_str("deny all;\n");
            }
            out
        }

        // What: listen on both families, ACL, SNI preread.
        // Why: both stream servers open with these lines.
        // From: Issue #1683 | PR #2020
        fn preread_listen(port: u64, acl: &str) -> String {
            format!(
                "    listen {port};\n    listen [::]:{port};\n    include {acl};\n    ssl_preread on;\n"
            )
        }

        // What: the SNI map and the passthrough server.
        // Why: strict passes only known hosts on.
        // From: Issue #1683 | PR #1980
        fn stream_file(p: &Plan, keys: &[(String, String)]) -> String {
            let mut out = format!("{HEAD}map $ssl_preread_server_name $stream_backend {{\n");
            out.push_str("    hostnames;\n");
            map_row(&mut out, "\"\"", &p.refuse);
            if p.strict {
                out.push_str(&format!("    default {};\n", p.refuse));
                for (k, _) in keys {
                    map_row(&mut out, k, &p.origin);
                }
            } else {
                out.push_str(&format!("    default {};\n", p.origin));
            }
            out.push_str("}\n\nserver {\n");
            out.push_str(&preread_listen(p.passthrough, &p.acl));
            out.push_str("    proxy_pass $stream_backend;\n");
            out.push_str(&p.timeouts);
            out.push_str("}\n");
            // What: the refuse target sends a TLS alert.
            // Why: a closed port would log error per try.
            // From: Issue #1683 | PR #1980
            out.push_str(&format!(
                "\nserver {{\n    listen {} ssl;\n    ssl_reject_handshake on;\n}}\n",
                p.refuse
            ));
            out
        }

        // What: maps for certificate, host and client.
        // Why: strict allows listed hosts only.
        // From: Issue #1683 | PR #1980
        fn https_map(p: &Plan, keys: &[(String, String)], fallback: &str) -> String {
            let mut out = format!("{HEAD}map $ssl_server_name $https_cert_name {{\n");
            out.push_str("    hostnames;\n");
            for (k, c) in keys {
                map_row(&mut out, k, c);
            }
            out.push_str(&format!("    default {fallback};\n}}\n\n"));
            out.push_str("map $host $cdn_host_allowed {\n    hostnames;\n");
            out.push_str(if p.strict {
                "    default 0;\n"
            } else {
                "    default 1;\n"
            });
            if p.strict {
                for (k, _) in keys {
                    map_row(&mut out, k, "1");
                }
            }
            out.push_str("}\n\ngeo $lancache_client_allowed {\n");
            let open = if p.cidrs.is_empty() { "1" } else { "0" };
            out.push_str(&format!("    default {open};\n"));
            for c in &p.cidrs {
                map_row(&mut out, c, "1");
            }
            out.push_str("}\n");
            out
        }

        // What: a server block behind the PROXY protocol.
        // Why: the client address comes from the stream.
        // From: Issue #1683 | PR #1980
        fn relay_server(p: &Plan, listen: &str, body: &str) -> String {
            format!(
                "server {{\n    listen {listen} proxy_protocol;\n    set_real_ip_from {};\n{body}{}}}\n",
                p.lo, p.timeouts
            )
        }

        // What: the map from SNI to intercept or pass.
        // Why: longer bases win; strict refuses the rest.
        // From: Issue #1683 | PR #1980
        fn dispatch_file(p: &Plan, h: &Hosts) -> String {
            let mut out =
                format!("{HEAD}map $ssl_preread_server_name $https_dispatch_backend {{\n");
            map_row(&mut out, "\"\"", &p.refuse_relay);
            for r in &h.roots {
                map_row(&mut out, r, &p.mitm_relay);
                if !h.root_wild.contains(r) {
                    map_row(&mut out, &ends_with_re(r, true), &p.mitm_relay);
                }
            }
            for e in &h.exact {
                map_row(&mut out, e, &p.mitm_relay);
            }
            let wild_roots = h.roots.iter().filter(|r| h.root_wild.contains(*r));
            let mut bases: Vec<&String> = h.bases.iter().chain(wild_roots).collect();
            bases.sort_by(|a, b| crate::config::longest_first(a, b));
            for b in bases {
                map_row(&mut out, &ends_with_re(b, true), &p.mitm_relay);
                map_row(&mut out, &ends_with_re(b, false), &p.pass_relay);
            }
            let fallback = if p.strict {
                &p.refuse_relay
            } else {
                &p.pass_relay
            };
            out.push_str(&format!("    default {fallback};\n}}\n\nserver {{\n"));
            out.push_str(&preread_listen(p.https, &p.acl));
            out.push_str("    proxy_pass $https_dispatch_backend;\n    proxy_protocol on;\n");
            out.push_str(&p.timeouts);
            out.push_str("}\n\n");
            let to_mitm = format!(
                "    proxy_protocol on;\n    proxy_pass {}:{};\n",
                p.lo, p.mitm
            );
            out.push_str(&relay_server(p, &p.mitm_relay, &to_mitm));
            out.push('\n');
            let to_origin = format!("    ssl_preread on;\n    proxy_pass {};\n", p.origin);
            out.push_str(&relay_server(p, &p.pass_relay, &to_origin));
            // What: refuse target of dispatch, with PROXY.
            // Why: a TLS alert, not a reset and [error].
            // From: Issue #1683 | PR #1980
            out.push_str(&format!(
            "\nserver {{\n    listen {} ssl proxy_protocol;\n    ssl_reject_handshake on;\n}}\n",
            p.refuse_relay
        ));
            out
        }

        // What: all generated files: (path, body).
        // Why: the ui writes them; nginx includes them.
        // From: Issue #1683 | PR #1980
        pub fn files(
            s: &Settings,
            h: &Hosts,
            https: bool,
        ) -> Result<Vec<(String, String)>, String> {
            let p = load_plan(s)?;
            let keys = h.keys();
            let fallback = s.text("NGINX_DEFAULT_CERT")?;
            // What: client, cdn, cert maps, HTTPS off too.
            // Why: proxy-params.conf reads the first two.
            // From: Issue #1683 | PR #2019
            let mut out = vec![
                (p.acl.clone(), acl_file(&p)),
                (s.text("NGINX_STREAM_TARGETS_FILE")?, stream_file(&p, &keys)),
                (
                    s.text("NGINX_HTTPS_MAP_FILE")?,
                    https_map(&p, &keys, &fallback),
                ),
            ];
            if !https {
                return Ok(out);
            }
            let listen = format!(
                "{HEAD}listen {0}:{1} ssl proxy_protocol default_server;\nlisten {0}:{2} ssl;\n",
                p.lo, p.mitm, p.health
            );
            out.push((s.text("NGINX_HTTPS_LISTEN_FILE")?, listen));
            out.push((s.text("NGINX_HTTPS_DISPATCH_FILE")?, dispatch_file(&p, h)));
            Ok(out)
        }
    }

    // What: apply saved setting changes to containers.
    // Why: each owner gets only the strongest action.
    // From: Issue #1683 | PR #1980
    pub mod apply {
        use crate::config::{Change, Effect};
        use crate::shared::docker::{Action, Api, Error};
        use std::collections::BTreeMap;
        use std::time::Duration;

        // What: strongest effect per owning container.
        // Why: one restart already covers a reload.
        // From: Issue #1683 | PR #1980
        pub fn owner_effects(changes: &[Change]) -> BTreeMap<String, Effect> {
            let mut out = BTreeMap::new();
            for c in changes {
                let e = out.entry(c.owner.clone()).or_insert(c.effect);
                if c.effect > *e {
                    *e = c.effect;
                }
            }
            out
        }

        // What: result for one owner.
        // Why: the ui shows it; Recreate needs compose.
        // From: Issue #1683 | PR #1980
        #[derive(Debug)]
        pub enum Outcome {
            Live,
            Done(Action),
            NeedsRecreate,
            Failed(Error),
        }

        // What: the container action a change needs.
        // Why: live and recreate need none here.
        // From: Issue #1683 | PR #1980
        fn action_of(effect: Effect) -> Option<Action> {
            match effect {
                Effect::Live | Effect::Fixed | Effect::Recreate => None,
                Effect::Reload => Some(Action::Reload),
                Effect::Restart | Effect::Container => Some(Action::Restart),
            }
        }

        // What: owner and words of each "owner:cmd+arg" row
        // Why: one reader of the exec rows of the SOT.
        // From: Issue #1683 | PR #2017
        pub fn exec_rows(exec: &[String]) -> impl Iterator<Item = (&str, Vec<&str>)> {
            exec.iter().filter_map(|e| {
                let (owner, cmd) = e.split_once(':')?;
                Some((owner, cmd.split('+').collect()))
            })
        }

        // What: an owner's reload commands, "owner:cmd+arg"
        // Why: RELOAD_EXEC in the SOT; no list in code.
        // From: Issue #1683 | PR #2020
        pub fn exec_cmds<'a>(
            exec: &'a [String],
            owner: &'a str,
        ) -> impl Iterator<Item = Vec<&'a str>> {
            exec_rows(exec).filter_map(move |(o, cmd)| (o == owner).then_some(cmd))
        }

        // What: run every reload command; stop at first.
        // Why: a failed reload is shown, never hidden.
        // From: Issue #1683 | PR #2020
        pub async fn reload_exec(
            api: &Api,
            name: &str,
            exec: &[String],
            owner: &str,
            limit: Duration,
        ) -> Outcome {
            for cmd in exec_cmds(exec, owner) {
                match api.exec(name, &cmd, limit).await {
                    Ok((0, _)) => {}
                    Ok((code, out)) => {
                        let text = format!("{} exit {code}: {}", cmd.join(" "), out.trim());
                        return Outcome::Failed(Error::Transport(text));
                    }
                    Err(e) => return Outcome::Failed(e),
                }
            }
            Outcome::Done(Action::Reload)
        }

        // What: one Docker action, reported as an outcome.
        // Why: run reports every action the same way.
        // From: Issue #1683 | PR #2017
        async fn acted(
            api: &Api,
            name: &str,
            action: Action,
            grace: u32,
            limit: Duration,
        ) -> Outcome {
            match api.act(name, action, grace, limit).await {
                Ok(()) => Outcome::Done(action),
                Err(e) => Outcome::Failed(e),
            }
        }

        // What: carry out the plan: exec or restart.
        // Why: openrc-init drops HUP; reload runs commands.
        // From: Issue #1683 | PR #1980
        pub async fn run(
            api: &Api,
            plan: &BTreeMap<String, Effect>,
            exec: &[String],
            container_of: &(dyn Fn(&str) -> String + Sync),
            grace: u32,
            limit: Duration,
        ) -> Vec<(String, Outcome)> {
            let mut out = Vec::with_capacity(plan.len());
            for (owner, &effect) in plan {
                let outcome = match action_of(effect) {
                    None if effect == Effect::Recreate => Outcome::NeedsRecreate,
                    None => Outcome::Live,
                    // What: owner reload commands via exec.
                    // Why: a reload must not restart it.
                    // From: Issue #1683 | PR #1985
                    Some(Action::Reload) if exec_cmds(exec, owner).next().is_some() => {
                        let name = container_of(owner);
                        match reload_exec(api, &name, exec, owner, limit).await {
                            // What: failed reload: restart.
                            // Why: else old file runs on.
                            // From: Issue #1683 | PR #1985
                            Outcome::Failed(e) => {
                                eprintln!("apply: {owner}: reload failed ({e}); restart");
                                acted(api, &name, Action::Restart, grace, limit).await
                            }
                            done => done,
                        }
                    }
                    Some(Action::Reload) => {
                        acted(api, &container_of(owner), Action::Restart, grace, limit).await
                    }
                    Some(a) => acted(api, &container_of(owner), a, grace, limit).await,
                };
                out.push((owner.clone(), outcome));
            }
            out
        }
    }

    // What: every config file of the stack.
    // Why: the ui calls one function; paths from SOT.
    // From: Issue #1683 | PR #1980
    pub mod render {
        use crate::config::Settings;
        use crate::shared::recursor_conf::{self, Chain};
        use crate::shared::{chrony, dhcp, dnsmasq_conf, kea_conf, log, nginx_conf, pdns_conf};
        use std::path::{Path, PathBuf};

        // What: warnings of the render in progress.
        // Why: a dead name leaves an option out.
        // From: Issue #1683 | PR #2020
        static NOTES: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

        // What: remember and log one warning of the render.
        // Why: plan and the ui log show what was left out.
        // From: Issue #1683 | PR #2020
        pub fn note(text: String) {
            eprintln!("render: warning: {text}");
            let mut list = NOTES
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if !list.contains(&text) {
                list.push(text);
            }
        }

        // What: the warnings since the last take.
        // Why: each render starts with an empty list.
        // From: Issue #1683 | PR #2020
        pub fn take_notes() -> Vec<String> {
            let mut list = NOTES
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            std::mem::take(&mut *list)
        }

        // What: secrets the config files embed.
        // Why: the caller reads them from the store.
        // From: Issue #1683 | PR #1980
        pub struct Secrets {
            pub pdns_api_key: String,
            pub recursor_api_key: String,
            pub tsig_name: String,
            pub tsig_secret: String,
            pub kea_ctrl_token: String,
        }

        // What: one file and its owning container.
        // Why: apply::plan needs the owner per change.
        // From: Issue #1683 | PR #1980
        pub struct File {
            pub owner: String,
            pub path: PathBuf,
            pub body: String,
        }

        // What: collector of files and errors.
        // Why: every bad value is named; nothing half done.
        // From: Issue #1683 | PR #1980
        struct Out<'a> {
            s: &'a Settings,
            files: Vec<File>,
            errs: Vec<String>,
        }

        // What: methods of the render collector Out.
        // Why: every bad value is named, nothing half done.
        // From: Issue #1683 | PR #2020
        impl<'a> Out<'a> {
            // What: an empty collector for one render run.
            // Why: all and dns_only start the same way.
            // From: Issue #1683 | PR #2017
            fn new(s: &'a Settings) -> Self {
                Self {
                    s,
                    files: Vec::new(),
                    errs: Vec::new(),
                }
            }

            // What: the files, or errors, each text once.
            // Why: no list leaves with a target outside.
            // From: Issue #1683 | PR #1991
            fn finish(mut self) -> Result<Vec<File>, Vec<String>> {
                if self.errs.is_empty()
                    && let Err(e) = confine(self.s, &self.files)
                {
                    self.errs.push(e);
                }
                let mut seen = std::collections::HashSet::new();
                self.errs.retain(|e| seen.insert(e.clone()));
                if self.errs.is_empty() {
                    Ok(self.files)
                } else {
                    Err(self.errs)
                }
            }

            // What: adds file of service a SOT key names.
            // Why: a render reports all errors at once.
            // From: Issue #1683 | PR #1980
            fn add_file(
                &mut self,
                service_key: &str,
                path_key: &str,
                body: Result<String, String>,
            ) {
                let owner = self.s.text(service_key);
                match (owner, self.s.text(path_key), body) {
                    (Ok(owner), Ok(p), Ok(body)) => self.files.push(File {
                        owner,
                        path: PathBuf::from(p),
                        body,
                    }),
                    (Err(e), _, _) | (_, Err(e), _) | (_, _, Err(e)) => self.errs.push(e),
                }
            }
            // What: adds a file of known owner and path.
            // Why: nginx files have no SOT key per file.
            // From: Issue #1683 | PR #2020
            fn add_path(&mut self, owner: &str, path: PathBuf, body: String) {
                self.files.push(File {
                    owner: owner.to_string(),
                    path,
                    body,
                });
            }

            // What: adds a JSON value as a pretty file.
            // Why: a JSON error is recorded like any other.
            // From: Issue #1683 | PR #1980
            fn put_json(
                &mut self,
                service_key: &str,
                key: &str,
                v: Result<serde_json::Value, String>,
            ) {
                let body =
                    v.and_then(|v| serde_json::to_string_pretty(&v).map_err(|e| e.to_string()));
                self.add_file(service_key, key, body);
            }
        }

        // What: FNV-1a of a body as a non-zero zone serial.
        // Why: same content, same serial, no rewrite.
        // From: Issue #1683 | PR #1980
        fn content_serial(body: &str) -> u32 {
            let mut h: u32 = 0x811c_9dc5;
            for b in body.bytes() {
                h = (h ^ u32::from(b)).wrapping_mul(0x0100_0193);
            }
            h.max(1)
        }

        // What: the files of the services container.
        // Why: chronyd, syslog-ng and snmpd run there.
        // From: Issue #1683 | PR #2020
        fn services_files(o: &mut Out) {
            let s = o.s;
            o.add_file("SERVICES_SERVICE", "CHRONY_CONF_FILE", chrony::render(s));
            o.add_file("SERVICES_SERVICE", "SYSLOG_CONF_FILE", log::render(s));
            snmpd_file(o);
        }

        // What: the snmpd.conf snmpd of each image reads.
        // Why: a secondary needs it; snmpd waits for it.
        // From: Issue #1683 | PR #2020
        fn snmpd_file(o: &mut Out) {
            let body = crate::shared::snmp::render(o.s, &[], &[]);
            o.add_file("SERVICES_SERVICE", "SNMPD_CONF_FILE", body);
        }

        // What: the files of the dns container.
        // Why: the full and the secondary render share it.
        // From: Issue #1683 | PR #2004
        fn dns_files(o: &mut Out, sec: &Secrets, names: &[(String, bool)], chain: &Chain) {
            let s = o.s;
            o.add_file(
                "DNS_SERVICE",
                "PDNS_CONF_FILE",
                pdns_conf::auth(s, &sec.pdns_api_key),
            );
            o.add_file(
                "DNS_SERVICE",
                "DNSDIST_CONF_FILE",
                crate::shared::dnsdist_conf::render(s),
            );
            // What: files for each recursor with an IP.
            // Why: dns-https waits for it (IP_HTTPS set).
            // From: Issue #1683 | PR #1980
            for (which, answer) in recursor_conf::running(s) {
                let rpz_key = which.key("RPZ_FILE");
                let lua_key = which.key("LUA_FILE");
                // What: serial from the zone body itself.
                // Why: clock serial restarts dns each save.
                // From: Issue #1683 | PR #1980
                let serial = recursor_conf::rpz(s, names, &answer, 0)
                    .map(|b| content_serial(&b))
                    .unwrap_or(1);
                o.add_file(
                    "DNS_SERVICE",
                    &rpz_key,
                    recursor_conf::rpz(s, names, &answer, serial),
                );
                let lua = s
                    .text(&rpz_key)
                    .and_then(|p| recursor_conf::lua(s, &p, chain));
                o.add_file("DNS_SERVICE", &lua_key, lua);
                let yaml = s
                    .text(&lua_key)
                    .and_then(|l| recursor_conf::yaml(s, which, &sec.recursor_api_key, &l, chain));
                o.add_file("DNS_SERVICE", &which.key("CONF_FILE"), yaml);
            }
            match s.flag("DNS_FILTER_AAAA") {
                Ok(true) => {
                    let body = Ok(recursor_conf::AAAA_FILTER_LUA.to_string());
                    o.add_file("DNS_SERVICE", "RECURSOR_AAAA_LUA_FILE", body);
                }
                Ok(false) => {}
                Err(e) => o.errs.push(e),
            }
        }

        // What: the files of dhcp for the active mode.
        // Why: an unused mode gets no files.
        // From: Issue #1683 | PR #1980
        fn dhcp_files(o: &mut Out, sec: &Secrets) {
            let s = o.s;
            // What: the mode file names the dhcp runlevel.
            // Why: the dhcp entry reads it at every start.
            // From: Issue #1683 | PR #1980
            let mode = s.text("DHCP_MODE").map(|m| format!("{m}\n"));
            o.add_file("DHCP_SERVICE", "DHCP_MODE_FILE", mode);
            match dhcp::Mode::from_settings(s) {
                Ok(dhcp::Mode::Off) => {}
                Ok(dhcp::Mode::Kea) => {
                    // What: a bad Kea file stops this file.
                    // Why: a new file drops kept subnets.
                    // From: Issue #1683 | PR #2020
                    let kept = s
                        .text("KEA_DHCP4_CONF_FILE")
                        .and_then(|p| crate::shared::fs::read_json(Path::new(&p)));
                    match kept {
                        Ok(kept) => o.put_json(
                            "DHCP_SERVICE",
                            "KEA_DHCP4_CONF_FILE",
                            kea_conf::dhcp4(s, kept.as_ref()),
                        ),
                        Err(e) => o.errs.push(e),
                    }
                    o.put_json(
                        "DHCP_SERVICE",
                        "KEA_CTRL_CONF_FILE",
                        kea_conf::ctrl_agent(s, &sec.kea_ctrl_token),
                    );
                    let ddns = kea_conf::ddns(s, &sec.tsig_name, &sec.tsig_secret);
                    o.put_json("DHCP_SERVICE", "KEA_DDNS_CONF_FILE", ddns);
                }
                Ok(mode) => o.add_file(
                    "DHCP_SERVICE",
                    "DNSMASQ_CONF_FILE",
                    dnsmasq_conf::render(s, mode),
                ),
                Err(e) => o.errs.push(e),
            }
        }

        // What: the hosts of a cache domain list.
        // Why: nginx files and certificates need same set.
        // From: Issue #1683 | PR #2017
        fn cache_hosts(s: &Settings, domains: &str) -> Result<nginx_conf::Hosts, String> {
            nginx_conf::hosts(domains, &psl(s)?)
        }

        // What: root, ending, cache entry, cert of a host.
        // Why: the same PSL and host map nginx gets.
        // From: Issue #1683 | PR #2020
        pub fn psl_lookup(s: &Settings, host: &str) -> Result<serde_json::Value, String> {
            let host = crate::shared::dns::bare_zone(host).to_ascii_lowercase();
            let list = psl(s)?;
            let hosts = cache_hosts(s, &crate::shared::cdn::effective(s)?)?;
            // What: exact name first, then longest *. key.
            // Why: nginx map hostnames picks the same way.
            // From: Issue #1683 | PR #2020
            let keys = hosts.keys();
            let hit = keys.iter().find(|(k, _)| *k == host).or_else(|| {
                keys.iter()
                    .filter(|(k, _)| {
                        k.strip_prefix("*.")
                            .is_some_and(|b| host.ends_with(&format!(".{b}")))
                    })
                    .max_by_key(|(k, _)| k.len())
            });
            Ok(serde_json::json!({
                "host": host,
                "root": list.root(&host),
                "public_ending": list.is_tld(crate::shared::dns::ending(&host)),
                "cached": hit.is_some(),
                "server_key": hit.map(|(k, _)| k),
                "cert": hit.map(|(_, c)| c),
            }))
        }

        // What: the Public Suffix List next to templates.
        // Why: cache names and own endings read one list.
        // From: Issue #1683 | PR #2019
        pub fn psl(s: &Settings) -> Result<nginx_conf::Psl, String> {
            let dir = PathBuf::from(s.text("NGINX_TEMPLATE_DIR")?);
            let text = crate::shared::fs::read_text(&dir.join(s.text("NGINX_PSL_FILE")?))?;
            Ok(nginx_conf::Psl::parse(&text))
        }

        // What: the nginx files of the proxy.
        // Why: they follow the cache domain list.
        // From: Issue #1683 | PR #1980
        fn nginx_files(o: &mut Out, domains: &str) -> Result<(), String> {
            let s = o.s;
            let src = PathBuf::from(s.text("NGINX_TEMPLATE_DIR")?);
            let dst = PathBuf::from(s.text("NGINX_CONF_DIR")?);
            // What: nginx resolvers must not be this host.
            // Why: threat model G3: own DNS sends CDNs here
            // From: Issue #1683 | PR #1985
            let resolvers = s.list("NGINX_UPSTREAM_RESOLVER")?;
            crate::shared::recursor_conf::check_upstream(s, "NGINX_UPSTREAM_RESOLVER", &resolvers)?;
            let hosts = cache_hosts(s, domains)?;
            let https = s.flag("HTTPS_ENABLED")?;
            let proxy = s.text("PROXY_SERVICE")?;
            for name in s.list("NGINX_TEMPLATES")? {
                if !https && name.ends_with("https.conf") {
                    continue;
                }
                let body =
                    nginx_conf::template(&crate::shared::fs::read_text(&below(&src, &name)?)?, s)?;
                o.add_path(&proxy, below(&dst, &name)?, body);
            }
            for (rel, body) in nginx_conf::files(s, &hosts, https)? {
                o.add_path(&proxy, below(&dst, &rel)?, body);
            }
            // What: the static health body nginx serves.
            // Why: proxy-params.conf aliases; ui owns files
            // From: Issue #1683 | PR #1980
            let health = format!("{}\n", s.text("NGINX_HEALTHZ_BODY")?);
            o.add_path(&proxy, below(&dst, &s.text("NGINX_HEALTHZ_FILE")?)?, health);
            Ok(())
        }

        // What: drop every leaf when the CA changed.
        // Why: leaves of an old CA fail on every client.
        // From: Issue #1683 | PR #1980
        fn delete_stale_leaves(ca_crt: &Path, dir: &Path, stamp: &Path) -> Result<(), String> {
            let print = crate::shared::cert::fingerprint(ca_crt)?;
            let old = crate::shared::fs::read_if_present(stamp)
                .map_err(|e| format!("{}: {e}", stamp.display()))?;
            if old.as_deref() == Some(print.as_bytes()) {
                return Ok(());
            }
            let list = crate::shared::fs::entries_if_present(dir)
                .map_err(|e| format!("{}: {e}", dir.display()))?;
            for file in list {
                if matches!(
                    file.extension().and_then(|x| x.to_str()),
                    Some("crt" | "key")
                ) {
                    crate::shared::fs::delete_if_present(&file)
                        .map_err(|e| format!("{}: {e}", file.display()))?;
                }
            }
            crate::shared::fs::write(
                stamp,
                print.as_bytes(),
                crate::shared::fs::PRIVATE_MODE,
                crate::shared::fs::Place::Replace,
                crate::shared::fs::Owner::default(),
            )
            .map_err(|e| format!("{}: {e}", stamp.display()))
        }

        // What: folder of the stack CA from SOT keys.
        // Why: the ui issues CA; cachehamster trusts it.
        // From: Issue #871 | PR #2017
        pub fn ca_dir(s: &Settings) -> Result<PathBuf, String> {
            Ok(PathBuf::from(s.text("NGINX_DIR")?).join(s.text("NGINX_SUBDIR_CA")?))
        }

        // What: folder of the leaf certificates and keys.
        // Why: the issuer and every reader use this folder.
        // From: Issue #1683 | PR #2020
        fn certs_dir(s: &Settings) -> Result<PathBuf, String> {
            Ok(PathBuf::from(s.text("NGINX_DIR")?).join(s.text("NGINX_SUBDIR_CERTS")?))
        }

        // What: the stack CA certificate file.
        // Why: one path for the issuer and every reader.
        // From: Issue #871 | PR #2017
        pub fn ca_cert(s: &Settings) -> Result<PathBuf, String> {
            Ok(ca_dir(s)?.join(s.text("CA_CERT_FILE")?))
        }

        // What: make the CA and every missing leaf cert.
        // Why: HTTPS mode needs one cert per map name.
        // From: Issue #1683 | PR #1980
        pub fn issue_certs(s: &Settings) -> Result<usize, String> {
            if !s.flag("HTTPS_ENABLED")? {
                return Ok(0);
            }
            let ca = ca_dir(s)?;
            let dir = certs_dir(s)?;
            let (ca_key, ca_crt) = (ca.join(s.text("CA_KEY_FILE")?), ca_cert(s)?);
            let serial = ca.join(s.text("CA_SERIAL_FILE")?);
            let gid = Some(s.num::<u32>("LANCACHE_RUNTIME_GID")?);
            for d in [&ca, &dir] {
                std::fs::create_dir_all(d).map_err(|e| format!("{}: {e}", d.display()))?;
            }
            // What: group and mode of one cert path.
            // Why: nginx workers read keys by shared gid.
            // From: Issue #1683 | PR #2020
            let grant = |p: &Path, gid: Option<u32>, mode: u32| {
                let owner = crate::shared::fs::Owner { uid: None, gid };
                crate::shared::fs::set_path_owner(p, owner, Some(mode))
                    .map_err(|e| format!("{}: {e}", p.display()))
            };
            grant(&dir, gid, s.mode("CERT_DIR_MODE")?)?;
            if !(ca_crt.exists() && ca_key.exists()) {
                crate::shared::cert::create_ca(
                    &ca_key,
                    &ca_crt,
                    &s.text("CA_SUBJECT")?,
                    s.uint("CA_DAYS")?,
                    &s.text("CA_KEY_TYPE")?,
                )?;
                eprintln!(
                    "cert: ACTION REQUIRED: new CA {}; every HTTPS client must install it",
                    ca_crt.display()
                );
            }
            grant(&ca_key, None, s.mode("CA_KEY_MODE")?)?;
            delete_stale_leaves(&ca_crt, &dir, &dir.join(s.text("CA_STAMP_FILE")?))?;
            let (key_mode, crt_mode) = (s.mode("CERT_KEY_MODE")?, s.mode("CERT_FILE_MODE")?);
            let mut made = 0;
            for (name, sans) in wanted_leaves(s)? {
                let (key, crt) = leaf_files(s, &name)?;
                if !(crt.exists() && key.exists()) {
                    let ca = crate::shared::cert::Ca {
                        key: &ca_key,
                        crt: &ca_crt,
                        serial: &serial,
                    };
                    crate::shared::cert::create_leaf(
                        &ca,
                        &key,
                        &crt,
                        &s.text("LEAF_SUBJECT")?,
                        &sans,
                        s.uint("LEAF_DAYS")?,
                        &s.text("LEAF_KEY_TYPE")?,
                    )?;
                    made += 1;
                }
                grant(&key, gid, key_mode)?;
                grant(&crt, gid, crt_mode)?;
            }
            Ok(made)
        }

        // What: the leaves the proxy needs: name, SANs.
        // Why: issuer, list and renewal read one set.
        // From: Issue #1683 | PR #2020
        fn wanted_leaves(s: &Settings) -> Result<Vec<(String, Vec<String>)>, String> {
            let hosts = cache_hosts(s, &crate::shared::cdn::effective(s)?)?;
            let mut want = hosts.certs();
            // What: default cert: DNS name, HTTPS own IP.
            // Why: no-SNI or by-IP clients get this cert
            // From: Issue #1683 | PR #1980
            let mut names = vec![s.text("DEFAULT_CERT_DNS")?];
            names.extend(crate::shared::dns::https_ip(s)?);
            want.push((s.text("NGINX_DEFAULT_CERT")?, names));
            Ok(want)
        }

        // What: key and certificate file of one leaf.
        // Why: one naming rule for every reader.
        // From: Issue #1683 | PR #2020
        fn leaf_files(s: &Settings, name: &str) -> Result<(PathBuf, PathBuf), String> {
            let dir = certs_dir(s)?;
            Ok((
                dir.join(format!("{name}.key")),
                dir.join(format!("{name}.crt")),
            ))
        }

        // What: the stack CA and every needed leaf.
        // Why: CLI and REST see what HTTPS serves.
        // From: Issue #1683 | PR #2020
        pub fn cert_list(s: &Settings) -> Result<serde_json::Value, String> {
            if !s.flag("HTTPS_ENABLED")? {
                return Ok(
                    serde_json::json!({"https": false, "ok": true, "ca": null, "leaves": []}),
                );
            }
            let within = s.uint("WATCHDOG_CERT_WARN_SECS")?;
            let mut leaves = Vec::new();
            for (name, sans) in wanted_leaves(s)? {
                let mut row = crate::shared::cert::state(&leaf_files(s, &name)?.1, within);
                row["name"] = name.into();
                row["names"] = sans.into();
                leaves.push(row);
            }
            let ca = crate::shared::cert::state(&ca_cert(s)?, within);
            let ok = std::iter::once(&ca)
                .chain(&leaves)
                .all(|r| r["renew"] == false);
            Ok(serde_json::json!({"https": true, "ok": ok, "ca": ca, "leaves": leaves}))
        }

        // What: drop leaves that end within the warn time.
        // Why: issue_certs then makes them anew.
        // From: Issue #1683 | PR #2020
        pub fn delete_expiring(s: &Settings) -> Result<Vec<String>, String> {
            let within = s.uint("WATCHDOG_CERT_WARN_SECS")?;
            let mut gone = Vec::new();
            for (name, _) in wanted_leaves(s)? {
                let (key, crt) = leaf_files(s, &name)?;
                if crt.is_file() && crate::shared::cert::state(&crt, within)["renew"] == true {
                    for f in [&key, &crt] {
                        crate::shared::fs::delete_if_present(f)
                            .map_err(|e| format!("{}: {e}", f.display()))?;
                    }
                    gone.push(name);
                }
            }
            Ok(gone)
        }

        // What: secrets the configs embed.
        // Why: made once; restarts never change them.
        // From: Issue #1683 | PR #1858
        pub fn secrets(s: &Settings) -> Result<Secrets, String> {
            use crate::shared::secret;
            Ok(Secrets {
                pdns_api_key: secret::get(s, "PDNS_API_KEY")?,
                recursor_api_key: secret::get(s, "RECURSOR_API_KEY")?,
                tsig_name: s.text("DDNS_TSIG_NAME")?,
                tsig_secret: secret::tsig_secret(s)?,
                kea_ctrl_token: secret::get(s, "KEA_CTRL_TOKEN")?,
            })
        }

        // What: every target lies in a render folder.
        // Why: a bad path key must not write elsewhere.
        // From: Issue #1683 | PR #2020
        fn confine(s: &Settings, files: &[File]) -> Result<(), String> {
            let roots = [s.text("CONFIG_DIR")?, s.text("KEA_DATA_DIR")?];
            for f in files {
                let raw = f.path.to_string_lossy();
                let ok = roots
                    .iter()
                    .any(|r| crate::shared::tidy::inside(&raw, r).is_ok());
                if !ok {
                    return Err(format!("{raw}: outside {}", roots.join(", ")));
                }
            }
            Ok(())
        }

        // What: a name or full path inside its folder.
        // Why: a name may be a full path; it must stay in.
        // From: Issue #1683 | PR #2020
        fn below(dir: &Path, name: &str) -> Result<PathBuf, String> {
            let p = dir.join(name);
            let up = Path::new(name)
                .components()
                .any(|c| matches!(c, std::path::Component::ParentDir));
            if name.is_empty() || up {
                return Err(format!("{name}: not a name below {}", dir.display()));
            }
            crate::shared::tidy::inside(&p.to_string_lossy(), &dir.to_string_lossy())
                .map_err(|e| format!("{name}: {e}"))?;
            Ok(p)
        }

        // What: write rendered files; list the changed.
        // Why: an unchanged file never wakes its owner.
        // From: Issue #1683 | PR #1980
        pub fn write_files(
            s: &Settings,
            files: &[File],
        ) -> Result<Vec<crate::config::Change>, String> {
            confine(s, files)?;
            let mode = s.mode("UI_CONFIG_FILE_MODE")?;
            let mut out = Vec::new();
            for f in files {
                // What: a first write wakes no owner.
                // Why: owners read it at start; HUP kills.
                // From: Issue #1683 | PR #1980
                let wake = f.path.exists();
                let owner = crate::shared::fs::Owner::default();
                let changed =
                    crate::shared::fs::write_if_changed(&f.path, f.body.as_bytes(), mode, owner);
                if changed.map_err(|e| format!("{}: {e}", f.path.display()))? && wake {
                    out.push(change_of(f));
                }
            }
            Ok(out)
        }

        // What: the change a rewritten file causes.
        // Why: write and plan wake the owner the same way.
        // From: Issue #1683 | PR #2020
        pub fn change_of(f: &File) -> crate::config::Change {
            crate::config::Change {
                key: f.path.display().to_string(),
                owner: f.owner.clone(),
                effect: crate::config::Effect::Reload,
            }
        }

        // What: what an apply would do with one file.
        // Why: stack and ui compare it; REST shows it.
        // From: Issue #1683 | PR #2020
        #[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize)]
        #[serde(rename_all = "lowercase")]
        pub enum FileState {
            New,
            Same,
            Changed,
        }

        // What: per file: path, owner and new/changed/same.
        // Why: a dry run shows what an apply would touch.
        // From: Issue #1683 | PR #2020
        pub fn file_states(files: &[File]) -> Result<Vec<(&File, FileState)>, String> {
            let mut out = Vec::with_capacity(files.len());
            for f in files {
                let state = if !f.path.exists() {
                    FileState::New
                } else if crate::shared::fs::same_content(&f.path, f.body.as_bytes())
                    .map_err(|e| format!("{}: {e}", f.path.display()))?
                {
                    FileState::Same
                } else {
                    FileState::Changed
                };
                out.push((f, state));
            }
            Ok(out)
        }

        // What: render all files; report every error.
        // Why: one call for the ui; nothing half written.
        // From: Issue #1683 | PR #1980
        pub fn all(s: &Settings, sec: &Secrets, chain: &Chain) -> Result<Vec<File>, Vec<String>> {
            take_notes();
            let mut o = Out::new(s);
            let domains = match crate::shared::cdn::effective(s) {
                Ok(d) => d,
                Err(e) => {
                    o.errs.push(e);
                    String::new()
                }
            };
            services_files(&mut o);
            let names = crate::shared::dns::cdn_list(&domains);
            dns_files(&mut o, sec, names.as_deref().unwrap_or_default(), chain);
            dhcp_files(&mut o, sec);
            if let Err(e) = nginx_files(&mut o, &domains) {
                o.errs.push(e);
            }
            // What: a bad list row is told once.
            // Why: the nginx files name the same row.
            // From: Issue #1683 | PR #2020
            if let Err(e) = names
                && !o.errs.contains(&e)
            {
                o.errs.push(e);
            }
            o.finish()
        }

        // What: dns files and snmpd.conf, for a secondary.
        // Why: a secondary runs only the dns container.
        // From: Issue #1683 | PR #1980
        pub fn dns_only(s: &Settings, sec: &Secrets) -> Result<Vec<File>, Vec<String>> {
            take_notes();
            let mut o = Out::new(s);
            let domains = crate::shared::cdn::effective(s).map_err(|e| vec![e])?;
            // What: a secondary renders without anchors.
            // Why: it keeps the NTA until the zone list.
            // From: Issue #1683 | PR #2019
            let names = crate::shared::dns::cdn_list(&domains).map_err(|e| vec![e])?;
            dns_files(&mut o, sec, &names, &Chain::default());
            snmpd_file(&mut o);
            o.finish()
        }
    }

    // What: one SNTP query (RFC 4330).
    // Why: the ui shows whether chrony answers.
    // From: Issue #1683 | PR #1980
    pub mod ntp {
        use std::time::Duration;

        // What: client request: version 4, mode 3.
        // Why: RFC 4330 first byte; rest stays zero.
        // From: Issue #1683 | PR #1980
        const REQUEST_HEAD: u8 = 0x23;
        // What: size of an NTP packet.
        // Why: RFC 4330: 48 bytes.
        // From: Issue #1683 | PR #2020
        const PACKET: usize = 48;
        // What: NTP server mode.
        // Why: RFC 4330: a server answers in mode 4.
        // From: Issue #1683 | PR #2020
        const MODE_SERVER: u8 = 4;

        // What: sends one NTP request, returns the reply.
        // Why: the probe reads the raw reply packet.
        // From: Issue #1683 | PR #1980
        fn ask(host: &str, port: u64, wait: Duration) -> std::io::Result<[u8; PACKET]> {
            let sock = crate::shared::dns::udp_for(crate::shared::dns::is_ipv6_text(host))?;
            sock.set_read_timeout(Some(wait))?;
            let mut req = [0u8; PACKET];
            req[0] = REQUEST_HEAD;
            sock.send_to(&req, crate::shared::dns::host_port(host, port))?;
            let mut reply = [0u8; PACKET];
            let n = sock.recv(&mut reply)?;
            if n < PACKET {
                return Err(std::io::ErrorKind::UnexpectedEof.into());
            }
            Ok(reply)
        }

        // What: stratum of a usable server reply.
        // Why: mode 4 and stratum 1..15 mean synced.
        // From: Issue #1683 | PR #1980
        fn stratum(host: &str, port: u64, wait: Duration) -> Option<u8> {
            ask(host, port, wait)
                .ok()
                .filter(|r| r[0] & 0x07 == MODE_SERVER && (1..=15).contains(&r[1]))
                .map(|r| r[1])
        }

        // What: own NTP: on, address, answer, stratum.
        // Why: one check for pages, REST and CLI.
        // From: Issue #1683 | PR #2020
        pub async fn status(s: &crate::config::Settings) -> Result<serde_json::Value, String> {
            let on = s.flag("NTP_ENABLED")?;
            let ip = s.text("IP_HTTP")?;
            let port = s.uint("NTP_PORT")?;
            let wait = Duration::from_millis(s.uint("NTP_PROBE_WAIT_MS")?);
            let host = ip.clone();
            let st = match on {
                true => tokio::task::spawn_blocking(move || stratum(&host, port, wait))
                    .await
                    .map_err(|e| e.to_string())?,
                false => None,
            };
            Ok(serde_json::json!({
                "enabled": on, "address": ip, "port": port,
                "answers": st.is_some(), "stratum": st
            }))
        }

        // What: does the stack's own NTP server answer.
        // Why: pages and DHCP need the yes or no only.
        // From: Issue #1683 | PR #2020
        pub async fn own_answers(s: &crate::config::Settings) -> Result<bool, String> {
            Ok(status(s).await?["answers"].as_bool().unwrap_or(false))
        }

        // What: names of the chronyc -c tracking fields.
        // Why: the CSV row has no header; order is fixed.
        // From: Issue #1683 | PR #2020
        const TRACKING: [&str; 14] = [
            "ref_id",
            "ref_name",
            "stratum",
            "ref_time",
            "system_time",
            "last_offset",
            "rms_offset",
            "frequency_ppm",
            "residual_freq_ppm",
            "skew_ppm",
            "root_delay",
            "root_dispersion",
            "update_interval",
            "leap_status",
        ];

        // What: one chronyc -c tracking row as JSON.
        // Why: sampler, REST and CLI read one parser.
        // From: Issue #1683 | PR #2020
        pub fn tracking(text: &str) -> Result<serde_json::Value, String> {
            let f: Vec<&str> = text.trim().split(',').collect();
            if f.len() < TRACKING.len() {
                return Err(format!("chronyc tracking: {} fields: {text}", f.len()));
            }
            let mut out = serde_json::Map::new();
            for (name, raw) in TRACKING.iter().zip(&f) {
                let num = !name.starts_with("ref_");
                let v = match (raw.parse::<i64>(), raw.parse::<f64>()) {
                    (Ok(n), _) if num => serde_json::json!(n),
                    (_, Ok(n)) if num => serde_json::json!(n),
                    _ => serde_json::json!(raw),
                };
                out.insert(name.to_string(), v);
            }
            Ok(out.into())
        }

        // What: what one ntp command does.
        // Why: the match runs these; the table names them.
        // From: Issue #1683 | PR #2020
        #[derive(Clone, Copy, PartialEq)]
        enum Op {
            Check,
            Tracking,
        }

        // What: every command of the ntp group.
        // Why: help, errors and the choice read this table.
        // From: Issue #1683 | PR #2020
        const COMMANDS: [(&str, crate::shared::cli::Entry<Op>); 2] = [
            ("check", crate::shared::cli::row(Op::Check, "check")),
            (
                "tracking",
                crate::shared::cli::row(Op::Tracking, "tracking"),
            ),
        ];

        // What: lancache-ng ntp check | tracking.
        // Why: NTP reads have their CLI with their owner.
        // From: Issue #1683 | PR #2020
        pub async fn run(args: &[String]) -> Result<(), String> {
            let s = crate::config::Settings::from_process()?;
            use crate::shared::cli;
            match cli::op_of(&COMMANDS, args.first()) {
                Some(Op::Check) => {}
                // What: tracking through the ui.
                // Why: chronyc runs in services via docker.
                // From: Issue #1683 | PR #2020
                Some(Op::Tracking) => {
                    let route = s.text("UI_ROUTE_NTP_TRACKING")?;
                    let body = crate::shared::http::Body::None;
                    println!(
                        "{}",
                        crate::shared::http::ui_socket(&s, &route, body).await?
                    );
                    return Ok(());
                }
                None => return Err(crate::shared::cli::help(&COMMANDS)),
            }
            let v = status(&s).await?;
            println!("{v}");
            match (v["enabled"].as_bool(), v["answers"].as_bool()) {
                (Some(true), Some(false)) => Err("ntp check: own NTP does not answer".into()),
                _ => Ok(()),
            }
        }
    }

    // What: proxy access log: recent requests, totals.
    // Why: dashboard and logs page share one parser.
    // From: Issue #1683 | PR #1980
    pub mod access {
        use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
        use std::path::{Path, PathBuf};

        // What: one request in nginx log_format cache.
        // Why: the ui lists host, path, status, size.
        // From: Issue #1683 | PR #1980
        #[derive(Clone, Debug, Default, serde::Serialize)]
        pub struct Entry {
            pub ip: String,
            pub time: String,
            pub method: String,
            pub path: String,
            pub status: u16,
            pub bytes: u64,
            pub cache_status: String,
            pub host: String,
        }

        // What: read one line; None when no cache row.
        // Why: a syslog prefix before the IP is allowed.
        // From: Issue #1683 | PR #1980
        pub fn parse(line: &str) -> Option<Entry> {
            let (before, after) = line.split_once(" - [")?;
            let (time, after) = after.split_once("] \"")?;
            let (request, after) = after.split_once("\" ")?;
            let (method, path) = request.split_once(' ').unwrap_or((request, ""));
            let path = path.split(' ').next().unwrap_or_default();
            let mut nums = after.splitn(3, ' ');
            let status = nums.next()?.parse().ok()?;
            let bytes = nums.next()?.parse().ok()?;
            let mut quoted = nums.next()?.split('"').filter(|p| !p.trim().is_empty());
            Some(Entry {
                ip: before.rsplit(' ').next()?.into(),
                time: time.into(),
                method: method.into(),
                path: path.into(),
                status,
                bytes,
                cache_status: quoted.next()?.into(),
                host: quoted.next().unwrap_or_default().into(),
            })
        }

        // What: proxy log files, oldest first.
        // Why: syslog-ng writes one file per day.
        // From: Issue #1683 | PR #1980
        pub fn files(dir: &Path) -> Result<Vec<PathBuf>, String> {
            let all = crate::shared::fs::entries_if_present(dir)
                .map_err(|e| format!("{}: {e}", dir.display()))?;
            let mut out: Vec<PathBuf> = all
                .into_iter()
                .filter(|p| p.extension().is_some_and(|x| x == "log"))
                .collect();
            out.sort();
            Ok(out)
        }

        // What: reads a file from its end, in chunks.
        // Why: a log tail must not load the whole file.
        // From: Issue #1683 | PR #1980
        fn read_back(path: &Path, want: usize, chunk: u64) -> std::io::Result<(Vec<u8>, bool)> {
            let mut f = std::fs::File::open(path)?;
            let mut pos = f.seek(SeekFrom::End(0))?;
            let step = chunk.max(1);
            let mut buf = Vec::new();
            while pos > 0 && buf.iter().filter(|&&b| b == b'\n').count() <= want {
                let len = step.min(pos);
                pos -= len;
                let mut part = vec![0u8; usize::try_from(len).unwrap_or(0)];
                f.seek(SeekFrom::Start(pos))?;
                f.read_exact(&mut part)?;
                part.append(&mut buf);
                buf = part;
            }
            Ok((buf, pos > 0))
        }

        // What: newest lines of the programs, merged.
        // Why: syslog-ng keeps one folder per program.
        // From: Issue #1683 | PR #1980
        fn newest_lines(
            root: &Path,
            programs: &[String],
            max: usize,
            chunk: u64,
        ) -> Result<Vec<serde_json::Value>, String> {
            let mut all = Vec::new();
            for p in programs {
                for line in tail_lines(&root.join(p), max, chunk)? {
                    all.push((p.clone(), line));
                }
            }
            all.sort_by(|a, b| b.1.cmp(&a.1));
            all.truncate(max);
            Ok(all
                .into_iter()
                .map(|(p, l)| {
                    let (stamp, text) = l.split_once(' ').unwrap_or(("", l.as_str()));
                    // What: drop "host program: " ahead.
                    // Why: the program has its own column.
                    // From: Issue #1683 | PR #1980
                    let lead = format!(" {p}: ");
                    let text = text.split_once(lead.as_str()).map_or(text, |(_, m)| m);
                    serde_json::json!({"host": p, "timestamp": stamp, "message": text})
                })
                .collect())
        }

        // What: programs, on/off switches, newest lines.
        // Why: page, REST and CLI read one log view.
        // From: Issue #1683 | PR #2020
        pub fn program_logs(
            s: &crate::config::Settings,
            only: Option<&str>,
            n: Option<usize>,
        ) -> Result<serde_json::Value, String> {
            let root = std::path::PathBuf::from(s.text("SYSLOG_LOG_ROOT")?);
            let max = n.unwrap_or(s.num::<usize>("UI_LOG_LINES")?);
            let chunk = s.uint("UI_LOG_TAIL_CHUNK")?;
            let programs = s.list("SYSLOG_PROGRAMS")?;
            let muted = s.list("SYSLOG_MUTED")?;
            // What: every folder in store, plus the list.
            // Why: the store may hold folders not listed.
            // From: Issue #1683 | PR #1980
            let mut names = programs.clone();
            let dirs = crate::shared::fs::entries_if_present(&root)
                .map_err(|e| format!("{}: {e}", root.display()))?;
            for d in dirs.iter().filter(|d| d.is_dir()) {
                if let Some(n) = d.file_name() {
                    crate::config::add_once(&mut names, &n.to_string_lossy());
                }
            }
            let read: Vec<String> = match only {
                Some(p) if names.iter().any(|x| x == p) => vec![p.to_string()],
                Some(p) => return Err(format!("{p}: no such log program")),
                None => names.clone(),
            };
            let switches: Vec<serde_json::Value> = programs
                .iter()
                .map(|p| serde_json::json!({"program": p, "on": !muted.contains(p)}))
                .collect();
            Ok(serde_json::json!({
                "hosts": names,
                "switches": switches,
                "lines": newest_lines(&root, &read, max, chunk)?,
            }))
        }

        // What: lancache-ng logs [program] [n] as JSON.
        // Why: a read; it needs no running ui.
        // From: Issue #1683 | PR #2020
        pub fn run(args: &[String]) -> Result<(), String> {
            let s = crate::config::Settings::from_process()?;
            let usage = "usage: logs [program] [n]";
            let (program, n) = match args {
                [] => (None, None),
                [h] if h == "help" => return Err(usage.into()),
                [p] if p.parse::<usize>().is_ok() => (None, p.parse().ok()),
                [p] => (Some(p.as_str()), None),
                [p, n] => (
                    Some(p.as_str()),
                    Some(n.parse().map_err(|_| format!("{n}: no number"))?),
                ),
                _ => return Err(usage.into()),
            };
            println!("{}", program_logs(&s, program, n)?);
            Ok(())
        }

        // What: last `limit` lines of the newest file.
        // Why: reads from the end; big logs stay cheap.
        // From: Issue #1683 | PR #1980
        pub fn tail_lines(dir: &Path, limit: usize, chunk: u64) -> Result<Vec<String>, String> {
            let Some(path) = files(dir)?.pop() else {
                return Ok(Vec::new());
            };
            let (buf, cut) =
                read_back(&path, limit, chunk).map_err(|e| format!("{}: {e}", path.display()))?;
            let text = String::from_utf8_lossy(&buf);
            let lines: Vec<String> = text
                .lines()
                .skip(usize::from(cut))
                .map(String::from)
                .collect();
            let from = lines.len().saturating_sub(limit);
            Ok(lines[from..].to_vec())
        }

        // What: last `limit` cache requests.
        // Why: dashboard list; other lines are skipped.
        // From: Issue #1683 | PR #1980
        pub fn tail(dir: &Path, limit: usize, chunk: u64) -> Result<Vec<Entry>, String> {
            let lines = tail_lines(dir, limit.saturating_mul(4), chunk)?;
            let found: Vec<Entry> = lines.iter().filter_map(|l| parse(l)).collect();
            let from = found.len().saturating_sub(limit);
            Ok(found[from..].to_vec())
        }

        // What: totals over all proxy log files.
        // Why: hit rate and traffic on the dashboard.
        // From: Issue #1683 | PR #1980
        #[derive(Clone, Debug, Default, serde::Serialize)]
        pub struct Stats {
            pub hits: u64,
            pub misses: u64,
            pub other: u64,
            pub total_requests: u64,
            pub total_bytes: u64,
            pub hit_pct: f64,
        }

        // What: methods of the log Stats.
        // Why: each entry counts into the totals.
        // From: Issue #1683 | PR #2020
        impl Stats {
            // What: adds the counts of another Stats.
            // Why: the totals sum up the log files.
            // From: Issue #1683 | PR #2020
            fn add(&mut self, o: &Stats) {
                self.hits += o.hits;
                self.misses += o.misses;
                self.other += o.other;
                self.total_requests += o.total_requests;
                self.total_bytes += o.total_bytes;
            }

            // What: adds one log entry to the totals.
            // Why: EXPIRED is fetched anew, so a miss.
            // From: Issue #1683 | PR #1980
            fn count(&mut self, e: &Entry) {
                self.total_requests += 1;
                self.total_bytes += e.bytes;
                match e.cache_status.as_str() {
                    "HIT" => self.hits += 1,
                    "MISS" | "EXPIRED" => self.misses += 1,
                    _ => self.other += 1,
                }
            }
        }

        // What: totals and newest requests, human sizes.
        // Why: one reader for dashboard, REST and CLI.
        // From: Issue #1683 | PR #2020
        pub async fn summary(s: &crate::config::Settings) -> Result<serde_json::Value, String> {
            let dir = Path::new(&s.text("SYSLOG_LOG_ROOT")?).join(s.text("PROXY_LOG_PROGRAM")?);
            let limit = s.num::<usize>("UI_RECENT_REQUESTS")?;
            let chunk = s.uint("UI_LOG_TAIL_CHUNK")?;
            let (stats, recent) = tokio::task::spawn_blocking(move || {
                Ok::<_, String>((stats(&dir)?, tail(&dir, limit, chunk)?))
            })
            .await
            .map_err(|e| e.to_string())??;
            let totals = with_human(&stats, "total_bytes_human", stats.total_bytes);
            let rows: Vec<serde_json::Value> = recent
                .iter()
                .rev()
                .map(|e| with_human(e, "bytes_human", e.bytes))
                .collect();
            Ok(serde_json::json!({"totals": totals, "recent": rows}))
        }

        // What: the summary of no log lines.
        // Why: a page that cannot read the log shows zeros.
        // From: Issue #1683 | PR #2020
        pub fn none() -> serde_json::Value {
            let stats = Stats::default();
            let totals = with_human(&stats, "total_bytes_human", 0);
            serde_json::json!({"totals": totals, "recent": []})
        }

        // What: adds a human-readable byte size field.
        // Why: readers show 40 GiB, not raw bytes.
        // From: Issue #1683 | PR #1980
        fn with_human(v: &impl serde::Serialize, field: &str, n: u64) -> serde_json::Value {
            let mut out = serde_json::to_value(v).unwrap_or(serde_json::Value::Null);
            out[field] = crate::shared::human::bytes(n).into();
            out
        }

        // What: what was counted of one log file so far.
        // Why: a day file only grows; old lines count once.
        // From: Issue #1683 | PR #2020
        #[derive(Clone, Default)]
        struct Seen {
            inode: u64,
            offset: u64,
            stats: Stats,
        }

        // What: the counts of each log file, by path.
        // Why: each call reads only what was appended.
        // From: Issue #1683 | PR #2020
        static SEEN: std::sync::Mutex<std::collections::BTreeMap<PathBuf, Seen>> =
            std::sync::Mutex::new(std::collections::BTreeMap::new());

        // What: file counts; reads only new whole lines.
        // Why: a shorter or other file starts from zero.
        // From: Issue #1683 | PR #2020
        fn file_stats(path: &Path, f: &std::fs::File) -> std::io::Result<Stats> {
            use std::os::unix::fs::MetadataExt;
            let meta = f.metadata()?;
            let mut seen = SEEN
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .get(path)
                .filter(|s| s.inode == meta.ino() && s.offset <= meta.len())
                .cloned()
                .unwrap_or_default();
            seen.inode = meta.ino();
            let mut reader = BufReader::new(f);
            reader.seek(SeekFrom::Start(seen.offset))?;
            let mut line = Vec::new();
            loop {
                line.clear();
                let n = reader.read_until(b'\n', &mut line)?;
                // What: a line without its end waits.
                // Why: the writer may still add to it.
                // From: Issue #1683 | PR #2020
                if n == 0 || line.last() != Some(&b'\n') {
                    break;
                }
                seen.offset += n as u64;
                if let Some(e) = parse(&String::from_utf8_lossy(&line)) {
                    seen.stats.count(&e);
                }
            }
            let done = seen.stats.clone();
            SEEN.lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .insert(path.to_path_buf(), seen);
            Ok(done)
        }

        // What: count requests, hits and bytes.
        // Why: HIT is a hit; MISS and EXPIRED a miss.
        // From: Issue #1683 | PR #1980
        pub fn stats(dir: &Path) -> Result<Stats, String> {
            let mut st = Stats::default();
            let err = |path: &Path, e: std::io::Error| format!("{}: {e}", path.display());
            let list = files(dir)?;
            // What: files that are gone leave the memory.
            // Why: a packed or removed file counts no more.
            // From: Issue #1683 | PR #2020
            SEEN.lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .retain(|p, _| p.parent() != Some(dir) || list.contains(p));
            for path in list {
                let f = match std::fs::File::open(&path) {
                    Ok(f) => f,
                    // What: a vanished file is skipped.
                    // Why: syslog-ng may move a day file.
                    // From: Issue #1683 | PR #2020
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
                    Err(e) => return Err(err(&path, e)),
                };
                let part = file_stats(&path, &f).map_err(|e| err(&path, e))?;
                st.add(&part);
            }
            let judged = st.hits + st.misses;
            if judged > 0 {
                st.hit_pct = st.hits as f64 * 100.0 / judged as f64;
            }
            Ok(st)
        }
    }

    // What: byte count as text in binary units.
    // Why: all ui pages show sizes the same way.
    // From: Issue #1683 | PR #1980
    pub mod human {
        // What: binary size units, smallest first.
        // Why: bytes() steps through them by 1024.
        // From: Issue #1683 | PR #1980
        const UNITS: [&str; 6] = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];

        // What: bytes of n GiB; None when it overflows.
        // Why: cache and log sizes are set in whole GiB.
        // From: Issue #1683 | PR #2020
        pub fn gib_bytes(n: u64) -> Option<u64> {
            n.checked_mul(1 << 30)
        }

        // What: part as a whole percent of whole.
        // Why: disk, cache and conntrack use one rule.
        // From: Issue #1683 | PR #2020
        pub fn pct(part: u64, whole: u64) -> u64 {
            part.saturating_mul(100) / whole.max(1)
        }

        // What: 1536 becomes "1.5 KiB".
        // Why: whole numbers only; one decimal is enough.
        // From: Issue #1683 | PR #1980
        pub fn bytes(n: u64) -> String {
            let (mut whole, mut tenth, mut unit) = (n, 0, 0);
            while whole >= 1024 && unit < UNITS.len() - 1 {
                tenth = (whole % 1024) * 10 / 1024;
                whole /= 1024;
                unit += 1;
            }
            match unit {
                0 => format!("{n} B"),
                _ => format!("{whole}.{tenth} {}", UNITS[unit]),
            }
        }
    }

    // What: effective cache domain list.
    // Why: shipped rows minus disabled plus custom.
    // From: Issue #1683 | PR #1980
    pub mod cdn {
        use crate::config::Settings;

        // What: one row of the domain table.
        // Why: the ui shows shipped and own rows apart.
        // From: Issue #1683 | PR #1980
        #[derive(Clone, Debug, serde::Serialize)]
        pub struct Row {
            pub display: String,
            pub is_default: bool,
            pub enabled: bool,
            pub is_valid: bool,
        }

        // What: a row; is_valid says if the name parses.
        // Why: a bad name stays visible, marked.
        // From: Issue #1683 | PR #1980
        fn new_row(name: String, is_default: bool, enabled: bool) -> Row {
            Row {
                is_valid: crate::shared::dns::cdn_entry(&name).is_some(),
                display: name,
                is_default,
                enabled,
            }
        }

        // What: shipped rows from the image file.
        // Why: blanks and # comments are not domains.
        // From: Issue #1683 | PR #1980
        pub fn defaults(s: &Settings) -> Result<Vec<String>, String> {
            let path = s.text("CDN_DEFAULT_DOMAINS_FILE")?;
            let text = crate::shared::fs::read_text(std::path::Path::new(&path))?;
            Ok(crate::config::data_rows(&text)
                .map(str::to_ascii_lowercase)
                .collect())
        }

        // What: all rows for the ui.
        // Why: shipped rows carry their on/off state.
        // From: Issue #1683 | PR #1980
        pub fn parse_rows(s: &Settings) -> Result<Vec<Row>, String> {
            let off = s.list("CDN_DISABLED_DOMAINS")?;
            let mut out = Vec::new();
            for d in defaults(s)? {
                let on = !off.contains(&d);
                out.push(new_row(d, true, on));
            }
            for d in s.list("CDN_CUSTOM_DOMAINS")? {
                out.push(new_row(d, false, true));
            }
            Ok(out)
        }

        // What: names of the switched-on rows.
        // Why: render and listing count the same rows.
        // From: Issue #1683 | PR #2020
        fn enabled(rows: &[Row]) -> Vec<&str> {
            rows.iter()
                .filter(|r| r.enabled)
                .map(|r| r.display.as_str())
                .collect()
        }

        // What: rows and effective list as JSON.
        // Why: page, REST and CLI read one listing.
        // From: Issue #1683 | PR #2020
        pub fn listing(s: &Settings) -> Result<serde_json::Value, String> {
            let rows = parse_rows(s)?;
            let effective = enabled(&rows);
            Ok(serde_json::json!({"rows": rows, "effective": effective}))
        }

        // What: what one cdn command does.
        // Why: the match runs these; the table names them.
        // From: Issue #1683 | PR #2020
        #[derive(Clone, Copy, PartialEq)]
        enum Op {
            List,
            Add,
            Remove,
            On,
            Off,
        }

        // What: every command of the cdn group.
        // Why: help, errors and the choice read this table.
        // From: Issue #1683 | PR #2020
        const COMMANDS: [(&str, crate::shared::cli::Entry<Op>); 5] = [
            ("list", crate::shared::cli::row(Op::List, "list")),
            ("add", crate::shared::cli::row(Op::Add, "add <domain>")),
            (
                "remove",
                crate::shared::cli::row(Op::Remove, "remove <domain>"),
            ),
            ("on", crate::shared::cli::row(Op::On, "on <domain>")),
            ("off", crate::shared::cli::row(Op::Off, "off <domain>")),
        ];

        // What: lancache-ng cdn list|add|remove|on|off.
        // Why: list reads here; changes go to the ui.
        // From: Issue #1683 | PR #2020
        pub async fn run(args: &[String]) -> Result<(), String> {
            use crate::shared::http::{Body, ui_socket};
            let s = Settings::from_process()?;
            use crate::shared::cli;
            let words: Vec<&str> = args.iter().map(String::as_str).collect();
            let op = cli::op_of(&COMMANDS, args.first());
            let rest = words.get(1..).unwrap_or_default();
            let pair = |k: &str, v: &str| (k.to_string(), v.to_string());
            let (key, form) = match (op, rest) {
                (Some(Op::List), []) => {
                    println!("{}", listing(&s)?);
                    return Ok(());
                }
                (Some(Op::Add), [d]) => ("UI_ROUTE_DNS_ADD", vec![pair("domain", d)]),
                (Some(Op::Remove), [d]) => ("UI_ROUTE_DNS_REMOVE", vec![pair("domain", d)]),
                (Some(Op::On), [d]) => (
                    "UI_ROUTE_DNS_TOGGLE",
                    vec![pair("domain", d), pair("enabled", "true")],
                ),
                (Some(Op::Off), [d]) => (
                    "UI_ROUTE_DNS_TOGGLE",
                    vec![pair("domain", d), pair("enabled", "false")],
                ),
                _ => return Err(crate::shared::cli::help(&COMMANDS)),
            };
            ui_socket(&s, &s.text(key)?, Body::Form(form)).await?;
            println!("{}", listing(&Settings::from_process()?)?);
            Ok(())
        }

        // What: enabled rows, one per line.
        // Why: input of the RPZ and nginx host maps.
        // From: Issue #1683 | PR #1980
        pub fn effective(s: &Settings) -> Result<String, String> {
            let mut out = String::new();
            for name in enabled(&parse_rows(s)?) {
                out.push_str(name);
                out.push('\n');
            }
            Ok(out)
        }
    }

    // What: Kea Control Agent client (REST, JSON).
    // Why: leases and subnets go through Kea itself.
    // From: Issue #1683 | PR #1980
    pub mod kea {
        use serde_json::{Value, json};

        // What: Kea result codes.
        // Why: Kea docs: 0 success, 3 empty answer.
        // From: Issue #1683 | PR #1980
        const RESULT_OK: i64 = 0;
        // What: Kea result code of an empty answer.
        // Why: Kea docs: 3 means nothing found.
        // From: Issue #1683 | PR #2020
        const RESULT_EMPTY: i64 = 3;

        // What: one control agent address.
        // Why: commands reach dhcp4 behind it.
        // From: Issue #1683 | PR #1980
        pub struct Api {
            client: reqwest::Client,
            url: String,
            user: String,
            token: String,
            max_body: u64,
        }

        // What: methods of the Kea Api.
        // Why: each Kea command goes through command.
        // From: Issue #1683 | PR #2020
        impl Api {
            // What: client for one agent URL and its login.
            // Why: the agent asks for basic auth (G2).
            // From: Issue #1683 | PR #1985
            pub fn new(
                client: reqwest::Client,
                max_body: u64,
                url: &str,
                user: &str,
                token: &str,
            ) -> Self {
                Api {
                    client,
                    url: url.into(),
                    user: user.into(),
                    token: token.into(),
                    max_body,
                }
            }

            // What: send one command; return arguments.
            // Why: 0 is ok, 3 is empty, rest is an error.
            // From: Issue #1683 | PR #1980
            pub async fn command(
                &self,
                command: &str,
                args: Option<Value>,
            ) -> Result<Value, String> {
                let fail = |e: String| format!("kea {command}: {e}");
                let mut body = json!({"command": command, "service": ["dhcp4"]});
                if let Some(a) = args {
                    body["arguments"] = a;
                }
                let reply = self
                    .client
                    .post(&self.url)
                    .basic_auth(&self.user, Some(&self.token))
                    .json(&body)
                    .send()
                    .await
                    .map_err(|e| fail(crate::shared::http::error_chain(&e)))?;
                let all: Value = crate::shared::http::read_json(reply, self.max_body, &self.url)
                    .await
                    .map_err(fail)?;
                let answer = match all.get(0) {
                    Some(first) => first.clone(),
                    None => all,
                };
                match answer["result"].as_i64() {
                    Some(RESULT_OK) => Ok(answer["arguments"].clone()),
                    Some(RESULT_EMPTY) => Ok(Value::Null),
                    _ => Err(fail(answer["text"].as_str().unwrap_or("no result").into())),
                }
            }

            // What: running kea-dhcp4 config.
            // Why: subnets and reservations live there.
            // From: Issue #1683 | PR #1980
            pub async fn config(&self) -> Result<Value, String> {
                self.command("config-get", None).await
            }

            // What: apply and save a new config.
            // Why: config-set applies; config-write saves.
            // From: Issue #1683 | PR #1980
            pub async fn set_config(&self, config: Value) -> Result<(), String> {
                self.command("config-set", Some(config)).await?;
                self.command("config-write", Some(json!({}))).await?;
                Ok(())
            }

            // What: all IPv4 leases.
            // Why: lease_cmds hook; the ui lists them.
            // From: Issue #1683 | PR #1980
            pub async fn leases(&self) -> Result<Vec<Value>, String> {
                let args = self.command("lease4-get-all", None).await?;
                Ok(args["leases"].as_array().cloned().unwrap_or_default())
            }

            // What: delete one lease by address.
            // Why: frees the address for the next client.
            // From: Issue #1683 | PR #1980
            pub async fn release(&self, ip: &str) -> Result<(), String> {
                let args = json!({"ip-address": ip});
                self.command("lease4-del", Some(args)).await?;
                Ok(())
            }
        }
    }

    // What: helpers of background tasks that loop.
    // Why: ui and dns tasks end alike on a missing value.
    // From: Issue #1683 | PR #2020
    pub mod task {
        // What: a setting a task cannot run without.
        // Why: the task ends with a log line, no guess.
        // From: Issue #1683 | PR #2017
        pub fn or_stop<T>(task: &str, value: Result<T, String>) -> Option<T> {
            value
                .inspect_err(|e| eprintln!("ui: {task} stop: {e}"))
                .ok()
        }
    }

    // What: start of helper programs.
    // Why: every caller reads the exit status the same way.
    // From: Issue #1683 | PR #2017
    pub mod tool {
        use std::process::Command;

        // What: runs a tool; errors name the tool only.
        // Why: arguments may hold secret, as snmpget's do.
        // From: Issue #1683 | PR #2017
        pub fn run(cmd: &mut Command) -> Result<Vec<u8>, String> {
            let tool = cmd.get_program().to_string_lossy().into_owned();
            let out = cmd.output().map_err(|e| format!("{tool}: {e}"))?;
            if !out.status.success() {
                let why = String::from_utf8_lossy(&out.stderr);
                return Err(format!("{tool}: {}", why.trim()));
            }
            Ok(out.stdout)
        }
    }

    // What: statistics: SNMP samples into RRD files.
    // Why: rrdtool keeps the graphs; no extra daemon.
    // From: Issue #1683 | PR #1980
    pub mod rrd {
        use crate::config::{Settings, Syntax};
        use std::path::{Path, PathBuf};
        use std::process::Command;

        // What: RRD data source types we accept.
        // Why: rrdtool create: GAUGE, COUNTER, DERIVE.
        // From: Issue #1683 | PR #1980
        const KINDS: [&str; 3] = ["GAUGE", "COUNTER", "DERIVE"];

        // What: one data source of a graph.
        // Why: name, SNMP OID and RRD type.
        // From: Issue #1683 | PR #1980
        #[derive(Clone, Debug)]
        pub struct Source {
            pub ds: String,
            pub oid: String,
            pub kind: String,
            pub scale: Option<f64>,
        }

        // What: one graph, stored in one RRD file.
        // Why: SOT row name:ds=oid=TYPE+ds=oid=TYPE.
        // From: Issue #1683 | PR #1980
        #[derive(Clone, Debug)]
        pub struct Graph {
            pub name: String,
            pub title: String,
            pub tab: String,
            pub sources: Vec<Source>,
        }

        // What: tab of the SNMP graphs.
        // Why: whole-box values, not one container.
        // From: Issue #1683 | PR #1980
        pub const MACHINE: &str = "machine";

        // What: the sample value rrdtool reads as unknown.
        // Why: a missing sample leaves a gap, not a zero.
        // From: Issue #1683 | PR #2017
        pub const UNKNOWN: &str = "U";

        // What: Docker stats fields container graph reads.
        // Why: names of the per-container values.
        // From: Issue #1683 | PR #1980
        pub const FIELDS: [&str; 6] = [
            "cpu_ns",
            "mem_bytes",
            "net_rx",
            "net_tx",
            "blk_read",
            "blk_write",
        ];

        // What: plain characters or an underscore.
        // Why: the names become file names and arguments.
        // From: Issue #1683 | PR #1980
        const WORD: Syntax = Syntax::Name("_");

        // What: parses ds=oid=kind[=scale] of a graph.
        // Why: a bad part is an error, never a default.
        // From: Issue #1683 | PR #1980
        fn source(text: &str) -> Result<Source, String> {
            let parts: Vec<&str> = text.split('=').collect();
            let (ds, oid, kind, scale) = match parts[..] {
                [ds, oid, kind] => (ds, oid, kind, None),
                [ds, oid, kind, f] => (ds, oid, kind, f.parse::<f64>().ok()),
                _ => ("", "", "", None),
            };
            let bad_scale = parts.len() == 4 && scale.is_none();
            if !crate::config::safe(WORD, ds) || !KINDS.contains(&kind) || bad_scale {
                return Err(format!(
                    "source {text:?} needs ds=oid=GAUGE|COUNTER|DERIVE[=factor]"
                ));
            }
            Ok(Source {
                ds: ds.into(),
                oid: oid.into(),
                kind: kind.into(),
                scale,
            })
        }

        // What: parses name:source+source of a row.
        // Why: the name becomes a file name.
        // From: Issue #1683 | PR #1980
        fn graph(row: &str, tab: &str) -> Result<Graph, String> {
            let (name, list) = row
                .split_once(':')
                .ok_or_else(|| format!("stats row {row:?} needs name:sources"))?;
            if !crate::config::safe(WORD, name) || !crate::config::safe(WORD, tab) {
                return Err(format!("graph name {name:?} is not plain"));
            }
            let sources = list.split('+').map(source).collect::<Result<Vec<_>, _>>()?;
            let full = match tab {
                MACHINE => name.to_string(),
                _ => format!("{tab}_{name}"),
            };
            Ok(Graph {
                name: full,
                title: name.replace('_', " "),
                tab: tab.into(),
                sources,
            })
        }

        // What: graphs from STATS_GRAPHS.
        // Why: a bad row is an error, never skipped.
        // From: Issue #1683 | PR #1980
        pub fn graphs(s: &Settings) -> Result<Vec<Graph>, String> {
            s.list("STATS_GRAPHS")?
                .iter()
                .map(|r| graph(r, MACHINE))
                .collect()
        }

        // What: one graph set per container.
        // Why: each container gets its own graphs.
        // From: Issue #1683 | PR #1980
        pub fn container_graphs(s: &Settings) -> Result<Vec<Graph>, String> {
            let mut out = Vec::new();
            for tab in s.list("STATS_CONTAINERS")? {
                for row in s.list("STATS_CONTAINER_GRAPHS")? {
                    let g = graph(&row, &tab)?;
                    if let Some(x) = g.sources.iter().find(|x| !FIELDS.contains(&x.oid.as_str())) {
                        return Err(format!("{}: unknown field {}", g.name, x.oid));
                    }
                    out.push(g);
                }
            }
            Ok(out)
        }

        // What: machine and container graphs.
        // Why: the page and the image route use both.
        // From: Issue #1683 | PR #1980
        pub fn all(s: &Settings) -> Result<Vec<Graph>, String> {
            let mut out = graphs(s)?;
            out.extend(container_graphs(s)?);
            out.extend(service_graphs(s)?);
            Ok(out)
        }

        // What: graphs with sources, RRD file, last write.
        // Why: REST and CLI show what is recorded.
        // From: Issue #1683 | PR #2020
        pub fn listing(s: &Settings) -> Result<serde_json::Value, String> {
            let mut rows = Vec::new();
            for g in all(s)? {
                let path = file(s, &g)?;
                let updated = std::fs::metadata(&path)
                    .ok()
                    .map(|m| crate::shared::fs::modified_secs(&m))
                    .filter(|t| *t > 0);
                let sources: Vec<serde_json::Value> = g
                    .sources
                    .iter()
                    .map(|x| serde_json::json!({"ds": x.ds, "from": x.oid, "kind": x.kind}))
                    .collect();
                rows.push(serde_json::json!({
                    "name": g.name, "tab": g.tab, "title": g.title,
                    "file": path, "updated_unix": updated, "sources": sources,
                }));
            }
            Ok(serde_json::json!({"graphs": rows}))
        }

        // What: what one stats command does.
        // Why: the match runs these; the table names them.
        // From: Issue #1683 | PR #2020
        #[derive(Clone, Copy, PartialEq)]
        enum Op {
            List,
            Graph,
            Sample,
            SnmpCheck,
        }

        // What: every command of the stats group.
        // Why: help, errors and the choice read this table.
        // From: Issue #1683 | PR #2020
        const COMMANDS: [(&str, crate::shared::cli::Entry<Op>); 4] = [
            ("list", crate::shared::cli::row(Op::List, "list")),
            (
                "graph",
                crate::shared::cli::row(Op::Graph, "graph <name> <range> <file.png>"),
            ),
            ("sample", crate::shared::cli::row(Op::Sample, "sample")),
            (
                "snmp-check",
                crate::shared::cli::row(Op::SnmpCheck, "snmp-check"),
            ),
        ];

        // What: lancache-ng stats list|graph|sample.
        // Why: reads here; a sample round runs in the ui.
        // From: Issue #1683 | PR #2020
        pub async fn run(args: &[String]) -> Result<(), String> {
            let s = Settings::from_process()?;
            use crate::shared::cli;
            let words: Vec<&str> = args.iter().map(String::as_str).collect();
            let op = cli::op_of(&COMMANDS, args.first());
            match (op, words.get(1..).unwrap_or_default()) {
                (Some(Op::List), []) => println!("{}", listing(&s)?),
                (Some(Op::Graph), [name, range, out]) => {
                    let g = all(&s)?
                        .into_iter()
                        .find(|g| g.name == *name)
                        .ok_or_else(|| format!("{name}: no such graph"))?;
                    let png = png(&s, &g, range, false)?;
                    std::fs::write(out, &png).map_err(|e| format!("{out}: {e}"))?;
                    println!(
                        "{}",
                        serde_json::json!({"graph": name, "file": out, "bytes": png.len()})
                    );
                }
                (Some(Op::Sample), []) => {
                    let route = s.text("UI_ROUTE_STATS_SAMPLE")?;
                    let body = crate::shared::http::Body::Form(vec![]);
                    let v = crate::shared::http::ui_socket(&s, &route, body).await?;
                    println!("{v}");
                    if v["errors"].as_array().is_some_and(|e| !e.is_empty()) {
                        return Err("sample: a graph could not be recorded".into());
                    }
                }
                // What: one SNMP query of the SOT target.
                // Why: REST runs the same function.
                // From: Issue #1683 | PR #2020
                (Some(Op::SnmpCheck), []) => {
                    let v = snmp_check(&s)?;
                    println!("{v}");
                    if v["ok"] != true {
                        return Err("snmp-check: the target did not answer".into());
                    }
                }
                _ => return Err(crate::shared::cli::help(&COMMANDS)),
            }
            Ok(())
        }

        // What: one SNMP query of the machine graphs' OIDs.
        // Why: CLI and REST show if the target answers.
        // From: Issue #1683 | PR #2020
        pub fn snmp_check(s: &Settings) -> Result<serde_json::Value, String> {
            let target = s.text("STATS_SNMP_TARGET")?;
            let rows: Vec<(String, String, String)> = graphs(s)?
                .into_iter()
                .flat_map(|g| {
                    g.sources
                        .into_iter()
                        .map(move |x| (g.name.clone(), x.ds, x.oid))
                })
                .collect();
            let oids: Vec<String> = rows.iter().map(|r| r.2.clone()).collect();
            Ok(match crate::shared::snmp::get(s, &target, &oids) {
                Ok(values) => {
                    let list: Vec<serde_json::Value> = rows
                        .iter()
                        .zip(values)
                        .map(|((g, ds, oid), v)| {
                            serde_json::json!({"graph": g, "ds": ds, "oid": oid, "value": v})
                        })
                        .collect();
                    serde_json::json!({"ok": true, "target": target, "values": list})
                }
                Err(e) => serde_json::json!({"ok": false, "target": target, "error": e}),
            })
        }

        // What: program values, row tab.name:sources.
        // Why: PowerDNS, nginx, Kea and chrony give values.
        // From: Issue #1683 | PR #1980
        pub fn service_graphs(s: &Settings) -> Result<Vec<Graph>, String> {
            let tabs = s.list("STATS_CONTAINERS")?;
            let mut out = Vec::new();
            for row in s.list("STATS_SERVICE_GRAPHS")? {
                let (head, rest) = row
                    .split_once(':')
                    .ok_or_else(|| format!("stats row {row:?} needs tab.name:sources"))?;
                let (tab, name) = head
                    .split_once('.')
                    .ok_or_else(|| format!("stats row {row:?} needs tab.name"))?;
                if tab != MACHINE && !tabs.iter().any(|t| t == tab) {
                    return Err(format!(
                        "stats row {row:?}: tab {tab} not in STATS_CONTAINERS"
                    ));
                }
                out.push(graph(&format!("{name}:{rest}"), tab)?);
            }
            Ok(out)
        }

        // What: one value of a Docker stats answer.
        // Why: sums all networks and block devices.
        // From: Issue #1683 | PR #1980
        pub fn docker_value(v: &serde_json::Value, field: &str) -> String {
            let sum = |list: Vec<&serde_json::Value>, key: &str| -> Option<u64> {
                list.iter().map(|x| x[key].as_u64()).sum()
            };
            let nets: Vec<&serde_json::Value> = match v["networks"].as_object() {
                Some(m) => m.values().collect(),
                None => Vec::new(),
            };
            let blk = |op: &str| -> Option<u64> {
                let rows = v["blkio_stats"]["io_service_bytes_recursive"].as_array()?;
                let hit = rows
                    .iter()
                    .filter(|r| r["op"].as_str().is_some_and(|o| o.eq_ignore_ascii_case(op)));
                hit.map(|r| r["value"].as_u64()).sum()
            };
            let mem = || -> Option<u64> {
                let used = v["memory_stats"]["usage"].as_u64()?;
                let cache = v["memory_stats"]["stats"]["inactive_file"].as_u64();
                Some(used.saturating_sub(cache.unwrap_or(0)))
            };
            let got = match field {
                "cpu_ns" => v["cpu_stats"]["cpu_usage"]["total_usage"].as_u64(),
                "mem_bytes" => mem(),
                "net_rx" if !nets.is_empty() => sum(nets, "rx_bytes"),
                "net_tx" if !nets.is_empty() => sum(nets, "tx_bytes"),
                "blk_read" => blk("read"),
                "blk_write" => blk("write"),
                _ => None,
            };
            got.map_or_else(|| UNKNOWN.into(), |n| n.to_string())
        }

        // What: rx and tx bytes of /proc/net/dev text.
        // Why: the host graph sums the interfaces kept.
        // From: Issue #1683 | PR #2020
        pub fn host_net(text: &str, skip: &[String]) -> (u64, u64) {
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
            (rx, tx)
        }

        // What: RRD file of one graph.
        // Why: one file per graph under STATS_DIR.
        // From: Issue #1683 | PR #1980
        pub fn file(s: &Settings, g: &Graph) -> Result<PathBuf, String> {
            let dir = s.text("STATS_DIR")?;
            Ok(Path::new(&dir).join(format!("{}.rrd", g.name)))
        }

        // What: create the RRD when it is missing.
        // Why: step, heartbeat and archives from SOT.
        // From: Issue #1683 | PR #1980
        pub fn ensure(s: &Settings, g: &Graph) -> Result<(), String> {
            let path = file(s, g)?;
            if path.exists() {
                return Ok(());
            }
            // What: create stats dir before rrdtool runs.
            // Why: an existing ui volume may lack folder.
            // From: Issue #1683 | PR #1980
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
            }
            let step = s.uint("STATS_STEP")?;
            let beat = step.saturating_mul(s.uint("STATS_HEARTBEAT_STEPS")?);
            let mut cmd = Command::new("rrdtool");
            cmd.arg("create")
                .arg("--step")
                .arg(step.to_string())
                .arg("--")
                .arg(&path);
            for src in &g.sources {
                // What: a gauge may go below zero.
                // Why: time offsets are negative half time.
                // From: Issue #1683 | PR #1980
                let min = if src.kind == "GAUGE" { "U" } else { "0" };
                cmd.arg(format!("DS:{}:{}:{beat}:{min}:U", src.ds, src.kind));
            }
            for rra in s.list("STATS_RRAS")? {
                cmd.arg(format!("RRA:{rra}"));
            }
            crate::shared::tool::run(&mut cmd)?;
            Ok(())
        }

        // What: the first word if a number, else unknown.
        // Why: a failed read must not store a text.
        // From: Issue #1683 | PR #1980
        fn number_or_unknown(line: &str) -> String {
            match line.split_whitespace().next() {
                Some(v) if v.parse::<f64>().is_ok() => v.into(),
                _ => UNKNOWN.into(),
            }
        }

        // What: read all sources once, then store.
        // Why: one SNMP request holds every value.
        // From: Issue #1683 | PR #1980
        pub fn sample(s: &Settings, g: &Graph) -> Result<(), String> {
            let oids: Vec<String> = g.sources.iter().map(|x| x.oid.clone()).collect();
            let got = crate::shared::snmp::get(s, &s.text("STATS_SNMP_TARGET")?, &oids)?;
            let values: Vec<String> = got.iter().map(|l| number_or_unknown(l)).collect();
            save_row(s, g, &values)
        }

        // What: write one sample row into the RRD.
        // Why: SNMP and Docker stats share the files.
        // From: Issue #1683 | PR #1980
        pub fn save_row(s: &Settings, g: &Graph, values: &[String]) -> Result<(), String> {
            ensure(s, g)?;
            if values.len() != g.sources.len() {
                let (got, want) = (values.len(), g.sources.len());
                return Err(format!("{}: {got} values for {want} sources", g.name));
            }
            let mut put = Command::new("rrdtool");
            put.arg("update")
                .arg("--")
                .arg(file(s, g)?)
                .arg(format!("N:{}", values.join(":")));
            crate::shared::tool::run(&mut put)?;
            Ok(())
        }

        // What: PNG of one graph over a time range.
        // Why: rrdtool draws; the page shows the image.
        // From: Issue #1683 | PR #1980
        pub fn png(s: &Settings, g: &Graph, range: &str, dark: bool) -> Result<Vec<u8>, String> {
            if !s.list("STATS_RANGES")?.iter().any(|r| r == range) {
                return Err(format!("range {range} is not offered"));
            }
            let path = file(s, g)?;
            let mut cmd = Command::new("rrdtool");
            cmd.args(["graph", "-", "--imgformat", "PNG"]);
            cmd.arg("--start").arg(format!("-{range}"));
            cmd.arg("--title").arg(&g.title);
            cmd.arg("--width").arg(s.text("STATS_WIDTH")?);
            cmd.arg("--height").arg(s.text("STATS_HEIGHT")?);
            // What: width and height are the whole image.
            // Why: every tab draws the same image size.
            // From: Issue #1683 | PR #1980
            cmd.arg("--full-size-mode");
            // What: plain numbers when each factor shrinks.
            // Why: "233.5m" illegible; kB x1024 keeps units
            // From: Issue #1683 | PR #1980
            let plain = g.sources.iter().all(|x| x.scale.is_some_and(|k| k < 1.0));
            let unit = if plain { "" } else { "%s" };
            if plain {
                cmd.arg("--units-exponent").arg("0");
            }

            // What: larger fonts for axis, title, legend.
            // Why: values stay readable without zoom.
            // From: Issue #1683 | PR #1980
            for f in s.list("STATS_FONTS")? {
                cmd.arg("--font").arg(f);
            }
            if dark {
                for c in s.list("STATS_DARK_COLOURS")? {
                    cmd.arg("--color").arg(c);
                }
            }
            let colours = s.list("STATS_LINE_COLOURS")?;
            for (i, src) in g.sources.iter().enumerate() {
                let colour = match colours.len() {
                    0 => String::new(),
                    n => colours[i % n].clone(),
                };
                cmd.arg(format!(
                    "DEF:{0}_raw={1}:{0}:AVERAGE",
                    src.ds,
                    path.display()
                ));

                // What: factor per source, e.g. ns to %
                // Why: Docker counts CPU time in ns.
                // From: Issue #1683 | PR #1980
                let factor = src.scale.unwrap_or(1.0);
                cmd.arg(format!("CDEF:{0}={0}_raw,{factor},*", src.ds));
                cmd.arg(format!("LINE2:{0}{colour}:{0:<8}", src.ds));

                // What: now, average, max as text per line.
                // Why: exact values without reading axis.
                // From: Issue #1683 | PR #1980
                cmd.arg(format!("GPRINT:{}:LAST:now %8.2lf{unit}", src.ds));
                cmd.arg(format!("GPRINT:{}:AVERAGE:avg %8.2lf{unit}", src.ds));
                cmd.arg(format!("GPRINT:{}:MAX:max %8.2lf{unit}\\l", src.ds));
            }
            crate::shared::tool::run(&mut cmd)
        }
    }

    // What: file tidying: safe paths, age, size, xz.
    // Why: the watchdog decides when; this does how.
    // From: Issue #1683 | PR #1980
    pub mod tidy {
        use std::path::{Component, Path, PathBuf};

        // What: seconds of one day.
        // Why: ages and daily stamps count in days.
        // From: Issue #1683 | PR #1980
        pub const DAY: u64 = 86_400;

        // What: the first second of the day a time lies in.
        // Why: files of today are still written and stay.
        // From: Issue #1683 | PR #2017
        fn day_start(now: u64) -> u64 {
            now - now % DAY
        }

        // What: the path with links and ".." resolved.
        // Why: a part that does not exist yet stays.
        // From: Issue #1683 | PR #1980
        fn resolved(path: &Path) -> std::io::Result<PathBuf> {
            let mut out = PathBuf::from("/");
            for part in path.components() {
                match part {
                    Component::ParentDir => {
                        out.pop();
                    }
                    Component::Normal(name) => {
                        let next = out.join(name);
                        out = match std::fs::canonicalize(&next) {
                            Ok(real) => real,
                            Err(e) if e.kind() == std::io::ErrorKind::NotFound => next,
                            Err(e) => return Err(e),
                        };
                    }
                    _ => {}
                }
            }
            Ok(out)
        }

        // What: real folder strictly inside prefix.
        // Why: a bad setting must never clean elsewhere.
        // From: Issue #1683 | PR #1980
        pub fn inside(raw: &str, prefix: &str) -> Result<PathBuf, String> {
            if !raw.starts_with('/') {
                return Err(format!("{raw} is not an absolute path"));
            }
            let real = resolved(Path::new(raw)).map_err(|e| format!("{raw}: {e}"))?;
            let prefix = Path::new(prefix);
            if real == prefix || !real.starts_with(prefix) {
                return Err(format!(
                    "{} is not inside {}",
                    real.display(),
                    prefix.display()
                ));
            }
            Ok(real)
        }

        // What: the cache dir, checked against its prefix.
        // Why: every delete in cache uses this one gate.
        // From: Issue #1683 | PR #2020
        pub fn cache_root(s: &crate::config::Settings) -> Result<PathBuf, String> {
            inside(&s.text("CACHE_DIR")?, &s.text("CACHE_DIR_ALLOWED_PREFIX")?)
        }

        // What: size and free bytes of the cache volume.
        // Why: the light and size check read one figure.
        // From: Issue #1683 | PR #2020
        pub fn cache_space(
            s: &crate::config::Settings,
        ) -> Result<crate::shared::fs::Space, String> {
            let dir = s.text("CACHE_DIR")?;
            crate::shared::fs::space(Path::new(&dir)).map_err(|e| format!("{dir}: {e}"))
        }

        // What: bytes the cache files hold on the disk.
        // Why: the disk holds files of the system too.
        // From: Issue #1683 | PR #1980
        pub fn cache_bytes(root: &Path) -> (u64, Vec<String>) {
            use std::os::unix::fs::MetadataExt;
            let (found, errs) = crate::shared::fs::files_under(root);
            let used = found.into_iter().fold(0u64, |total, (_, meta)| {
                total.saturating_add(meta.blocks().saturating_mul(512))
            });
            (used, errs)
        }

        // What: largest cache size the disk allows.
        // Why: the form shows it; saving enforces it.
        // From: Issue #1069 | PR #1991
        pub fn reachable(
            s: &crate::config::Settings,
            old: u64,
            cached: u64,
        ) -> Result<u64, String> {
            let sp = cache_space(s)?;
            // What: measured cache bytes, else disk use.
            // Why: the disk holds files of the system too.
            // From: Issue #1069 | PR #1991
            let held = if cached == u64::MAX {
                sp.used().min(old)
            } else {
                cached
            };
            Ok(sp.free.saturating_add(held))
        }

        // What: cache use against set size and disk.
        // Why: one reader for dashboard, REST and CLI.
        // From: Issue #1683 | PR #2020
        pub fn usage(
            s: &crate::config::Settings,
            used: Option<u64>,
        ) -> Result<serde_json::Value, String> {
            let max = crate::shared::human::gib_bytes(s.uint("CACHE_MAX_GB")?)
                .ok_or("CACHE_MAX_GB is too big")?;
            let sp = cache_space(s)?;
            let pct = used.map(|u| crate::shared::human::pct(u, max).min(100));
            Ok(serde_json::json!({
                "used_bytes": used, "max_bytes": max, "pct_of_max": pct,
                "reachable_bytes": reachable(s, max, used.unwrap_or(u64::MAX))?,
                "disk": {"total": sp.total, "free": sp.free, "used": sp.used(), "pct": sp.pct()}
            }))
        }

        // What: what one cache command does.
        // Why: the match runs these; the table names them.
        // From: Issue #1683 | PR #2020
        #[derive(Clone, Copy, PartialEq)]
        enum Op {
            Usage,
            Wipe,
        }

        // What: every command of the cache group.
        // Why: help, errors and the choice read this table.
        // From: Issue #1683 | PR #2020
        const COMMANDS: [(&str, crate::shared::cli::Entry<Op>); 2] = [
            ("usage", crate::shared::cli::row(Op::Usage, "usage")),
            ("wipe", crate::shared::cli::row(Op::Wipe, "wipe")),
        ];

        // What: lancache-ng cache usage: counts, then JSON.
        // Why: cache reads have their CLI with their owner.
        // From: Issue #1683 | PR #2020
        pub async fn run(args: &[String]) -> Result<(), String> {
            let s = crate::config::Settings::from_process()?;
            use crate::shared::cli;
            match cli::op_of(&COMMANDS, args.first()) {
                Some(Op::Usage) => {
                    let (used, errs) = cache_bytes(&cache_root(&s)?);
                    println!("{}", usage(&s, Some(used))?);
                    match errs.is_empty() {
                        true => Ok(()),
                        false => Err(format!("cache usage: not read: {}", errs.join("; "))),
                    }
                }
                // What: wipe goes to the ui, as the button.
                // Why: the ui lowers the shown sum at once.
                // From: Issue #1683 | PR #2020
                Some(Op::Wipe) => {
                    let r = s.text("UI_ROUTE_HAMSTER_API")?.replace("{op}", "wipe");
                    let body = crate::shared::http::Body::Form(vec![]);
                    let v = crate::shared::http::ui_socket(&s, &r, body).await?;
                    println!("{v}");
                    Ok(())
                }
                None => Err(crate::shared::cli::help(&COMMANDS)),
            }
        }

        // What: one regular file with its facts.
        // Why: links are never followed or removed.
        // From: Issue #1683 | PR #1980
        pub struct Item {
            pub path: PathBuf,
            pub size: u64,
            pub mtime: u64,
        }

        // What: all regular files below a folder.
        // Why: base for age, size and pack runs.
        // From: Issue #1683 | PR #1980
        pub fn files(dir: &Path) -> (Vec<Item>, Vec<String>) {
            let (found, errs) = crate::shared::fs::files_under(dir);
            let items = found
                .into_iter()
                .map(|(path, meta)| Item {
                    path,
                    size: meta.len(),
                    mtime: crate::shared::fs::modified_secs(&meta),
                })
                .collect();
            (items, errs)
        }

        // What: split files into older than days, rest.
        // Why: one age rule for the run and the dry run.
        // From: Issue #1683 | PR #2020
        pub fn older(all: Vec<Item>, days: u64, now: u64) -> (Vec<Item>, Vec<Item>) {
            all.into_iter()
                .partition(|f| now.saturating_sub(f.mtime) / DAY > days)
        }

        // What: oldest files to drop to fit the budget.
        // Why: files written today stay; gives the size.
        // From: Issue #1683 | PR #2020
        pub fn over_budget(mut all: Vec<Item>, budget: u64, now: u64) -> (Vec<Item>, u64) {
            let mut size: u64 = all.iter().map(|f| f.size).sum();
            all.sort_by_key(|f| f.mtime);
            let today = day_start(now);
            let mut pick = Vec::new();
            for f in all {
                if size <= budget {
                    break;
                }
                if f.mtime < today {
                    size = size.saturating_sub(f.size);
                    pick.push(f);
                }
            }
            (pick, size)
        }

        // What: remove the picked files.
        // Why: gives freed bytes; a gone file is no error.
        // From: Issue #1683 | PR #2020
        pub fn delete(pick: &[Item]) -> (u64, Vec<String>) {
            let (mut freed, mut errs) = (0u64, Vec::new());
            for f in pick {
                match super::fs::delete_if_present(&f.path) {
                    Err(e) => errs.push(format!("{}: {e}", f.path.display())),
                    Ok(()) => freed = freed.saturating_add(f.size),
                }
            }
            (freed, errs)
        }

        // What: files closed before today, not yet xz.
        // Why: past days are never written again.
        // From: Issue #1683 | PR #2020
        pub fn closed(dir: &Path, now: u64) -> (Vec<Item>, Vec<String>) {
            let today = day_start(now);
            let (all, errs) = files(dir);
            let pick = all
                .into_iter()
                .filter(|f| f.mtime < today && f.path.extension().is_none_or(|e| e != "xz"))
                .collect();
            (pick, errs)
        }

        // What: xz every picked file.
        // Why: saves log disk; returns the errors.
        // From: Issue #1683 | PR #1980
        pub fn pack(pick: &[Item], preset: u64) -> Vec<String> {
            let mut errs = Vec::new();
            for f in pick {
                // What: late lines join existing .xz file.
                // Why: a second stream; xz reads one file.
                // From: Issue #1683 | PR #1985
                let packed = super::fs::with_suffix(&f.path, ".xz");
                if let Err(e) = pack_one(&f.path, &packed, preset) {
                    errs.push(e);
                }
            }
            errs
        }

        // What: xz one file into dst, then remove the file.
        // Why: the source goes only after dst is complete.
        // From: Issue #1683 | PR #2020
        fn pack_one(src: &Path, dst: &Path, preset: u64) -> Result<(), String> {
            use super::fs::{Owner, Place};
            use std::io::{BufWriter, Write};
            use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
            let err = |p: &Path, e: std::io::Error| format!("{}: {e}", p.display());
            let level = u32::try_from(preset)
                .ok()
                .filter(|p| *p <= 9)
                .ok_or_else(|| format!("xz preset {preset} is not 0 to 9"))?;
            let meta = std::fs::metadata(src).map_err(|e| err(src, e))?;
            // What: the .xz file keeps owner and mode.
            // Why: log folder readers can read it.
            // From: Issue #1683 | PR #2020
            let (uid, gid) = (rustix::process::geteuid(), rustix::process::getegid());
            let owner = Owner {
                uid: (meta.uid() != uid.as_raw()).then_some(meta.uid()),
                gid: (meta.gid() != gid.as_raw()).then_some(meta.gid()),
            };
            let mode = meta.permissions().mode() & 0o7777;
            let encode = |file: &mut std::fs::File| -> std::io::Result<()> {
                let mut input = std::fs::File::open(src)?;
                let options = lzma_rust2::XzOptions::with_preset(level);
                let mut xz = lzma_rust2::XzWriter::new(BufWriter::new(file), options)?;
                std::io::copy(&mut input, &mut xz)?;
                xz.finish()?.flush()
            };
            if dst.exists() {
                // What: append the stream to the .xz.
                // Why: xz will not overwrite a file.
                // From: Issue #1683 | PR #1985
                let part = super::fs::with_suffix(dst, ".part");
                let joined = super::fs::write_with(&part, mode, Place::Replace, owner, encode)
                    .map_err(|e| err(&part, e))
                    .and_then(|()| {
                        let mut from = std::fs::File::open(&part).map_err(|e| err(&part, e))?;
                        let mut to = std::fs::OpenOptions::new()
                            .append(true)
                            .open(dst)
                            .map_err(|e| err(dst, e))?;
                        std::io::copy(&mut from, &mut to).map_err(|e| err(dst, e))?;
                        to.sync_all().map_err(|e| err(dst, e))
                    });
                let left = super::fs::delete_if_present(&part).map_err(|e| err(&part, e));
                joined.and(left)?;
            } else {
                super::fs::write_with(dst, mode, Place::Replace, owner, encode)
                    .map_err(|e| err(dst, e))?;
                // What: the .xz file keeps the log's time.
                // Why: age rules read the .xz time.
                // From: Issue #1683 | PR #2020
                let when = meta.modified().map_err(|e| err(src, e))?;
                std::fs::File::options()
                    .write(true)
                    .open(dst)
                    .and_then(|f| f.set_modified(when))
                    .map_err(|e| err(dst, e))?;
            }
            super::fs::delete_if_present(src).map_err(|e| err(src, e))
        }

        // What: is a daily job due by its stamp.
        // Why: a missing or future stamp means due.
        // From: Issue #1683 | PR #1980
        pub fn is_due(stamp: &Path, now: u64) -> bool {
            let last = crate::shared::fs::read_text(stamp)
                .ok()
                .and_then(|t| t.trim().parse::<u64>().ok())
                .filter(|t| *t <= now)
                .unwrap_or(0);
            now - last >= DAY
        }

        // What: write a stamp time.
        // Why: next run waits a day from it.
        // From: Issue #1683 | PR #1980
        pub fn save_stamp(stamp: &Path, at: u64) -> Result<(), String> {
            let body = at.to_string() + "\n";
            crate::shared::fs::write(
                stamp,
                body.as_bytes(),
                crate::shared::fs::PRIVATE_MODE,
                crate::shared::fs::Place::Replace,
                crate::shared::fs::Owner::default(),
            )
            .map_err(|e| format!("{}: {e}", stamp.display()))
        }

        // What: newest change time below a folder.
        // Why: shows whether logs are still written.
        // From: Issue #1683 | PR #1980
        pub fn newest(dir: &Path) -> (u64, Vec<String>) {
            let (all, errs) = files(dir);
            (all.iter().map(|f| f.mtime).max().unwrap_or(0), errs)
        }

        // What: STATS CSV answer of the syslog-ng socket.
        // Why: the socket answers it, no syslog-ng-ctl.
        // From: Issue #1683 | PR #2020
        fn syslog_stats(s: &crate::config::Settings) -> Result<String, String> {
            use std::io::{BufRead, BufReader, Write};
            let path = s.text("SYSLOG_CTL_SOCKET")?;
            let wait = std::time::Duration::from_secs(s.uint("SYSLOG_CTL_TIMEOUT")?);
            let err = |e: std::io::Error| format!("{path}: {e}");
            let sock = std::os::unix::net::UnixStream::connect(&path).map_err(err)?;
            sock.set_read_timeout(Some(wait)).map_err(err)?;
            sock.set_write_timeout(Some(wait)).map_err(err)?;
            (&sock).write_all(b"STATS CSV\n").map_err(err)?;
            // What: the answer ends with a line of one dot.
            // Why: the syslog-ng control protocol says so.
            // From: Issue #1683 | PR #2020
            let mut text = String::new();
            for line in BufReader::new(&sock).lines() {
                let line = line.map_err(err)?;
                if line == "." {
                    return Ok(text);
                }
                text.push_str(&line);
                text.push('\n');
            }
            Err(format!("{path}: the answer has no end"))
        }

        // What: processed count of syslog-ng file outputs.
        // Why: the control socket lists the store rows.
        // From: Issue #1683 | PR #1980
        pub fn syslog_processed(s: &crate::config::Settings) -> Result<u64, String> {
            let text = syslog_stats(s)?;
            let mut total = 0;
            for row in text.lines() {
                let cols: Vec<&str> = row.split(';').collect();
                // What: old dst.file rows or d_store row.
                // Why: syslog-ng 4 shows only d_store row.
                // From: Issue #1683 | PR #2020
                let store = match cols.first() {
                    Some(&"dst.file") => true,
                    Some(&"destination") => cols.get(1) == Some(&super::log::STORE),
                    _ => false,
                };
                if store && cols.get(4) == Some(&"processed") {
                    total += cols.get(5).and_then(|v| v.parse::<u64>().ok()).unwrap_or(0);
                }
            }
            Ok(total)
        }
    }
}

// What: change settings and apply them to the stack.
// Why: ui, dns and dhcp save one way; no web state.
// From: Issue #1683 | PR #2020
mod stack {
    use crate::config::{self, Settings, process_env};
    use crate::dhcp::stays_off;
    use crate::dns::{dnssec_chain, ensure_zones};
    use crate::shared::Fault;
    use crate::shared::dhcp::Mode as DhcpMode;
    use crate::shared::{apply, docker, render};
    use serde_json::{Value, json};
    use std::collections::{BTreeMap, BTreeSet};
    use std::path::{Path, PathBuf};
    use std::sync::RwLock;
    use std::sync::atomic::AtomicBool;
    use std::sync::atomic::Ordering;
    use std::time::{Duration, Instant};

    // What: parts a stack state leaves out, and why.
    // Why: nothing is missing without a word.
    // From: Issue #1683 | PR #2020
    const STATE_LEAVES_OUT: [&str; 7] = [
        "cache volume: the cached files, not settings",
        "Kea leases: runtime data of the clients",
        "secrets: an old key would cut secondaries, Kea, pdns",
        "container settings: setup.sh owns them",
        "settings of <file>.local: they win over the file",
        "cachehamster jobs and statistics: runtime data",
        "sessions: logins of the moment",
    ];

    // What: store of whole-stack states.
    // Why: one file per state; count from the SOT.
    // From: Issue #1683 | PR #2020
    pub(crate) fn state_store(s: &Settings) -> Result<crate::shared::snapshot::Store, String> {
        Ok(crate::shared::snapshot::Store {
            dir: PathBuf::from(s.text("STACK_SNAPSHOT_DIR")?),
            keep: s.num::<usize>("STACK_SNAPSHOT_KEEP")?,
            owner: crate::shared::fs::Owner::default(),
            file: Some(s.text("STACK_SNAPSHOT_FILE")?),
        })
    }

    // What: the state of the stack now as one value.
    // Why: settings, Kea and zones of one moment.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn state_capture(s: &Settings) -> Result<Value, String> {
        let file = config::saved_file().ok_or("no settings file is set")?;
        let settings: BTreeMap<String, String> = config::read_raw(&file)?
            .into_iter()
            .filter(|(k, _)| state_key(s, k))
            .collect();
        let role = crate::shared::dns::Role::from_settings(s)?;
        let mut zones = BTreeMap::new();
        if role == crate::shared::dns::Role::Primary {
            let api = crate::shared::peer::own_api(s)?;
            let have = crate::dns::zone_names(&api).await?;
            for zone in crate::dns::snapshot_zones(s)? {
                let id = crate::shared::pdns::zone_id(&zone);
                if have.contains(&id) {
                    let rows = api.rrsets(&zone).await?;
                    zones.insert(zone, rows);
                }
            }
        }
        Ok(json!({
            "version": 1,
            "created_unix": crate::shared::clock::unix_secs(),
            "role": format!("{role:?}"),
            "dhcp_mode": s.text("DHCP_MODE")?,
            "settings": settings,
            "kea": crate::dhcp::kea_config(s).await?,
            "zones": zones,
            "left_out": STATE_LEAVES_OUT,
        }))
    }

    // What: a settings key a state holds and restores.
    // Why: secrets and keys the ui never stores stay.
    // From: Issue #1683 | PR #2020
    fn state_key(s: &Settings, key: &str) -> bool {
        s.spec(key)
            .is_some_and(|sp| !sp.is_secret() && sp.effect.writable())
    }

    // What: put the stack back to one saved state.
    // Why: exactly that state, never a mix; backup first.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn state_restore(app: &Stack, id: &str) -> Result<(bool, Vec<Fault>), String> {
        let _held = app.change.lock().await;
        let state: Value = state_store(&app.settings())?.read(id)?;
        let mut report = vec![Fault::Plain(format!(
            "backup: {}",
            state_save(&app.settings()).await?
        ))];
        let old = app.settings();
        let path = saved_path(app)?;
        let want: BTreeMap<String, String> =
            serde_json::from_value(state["settings"].clone()).map_err(|e| e.to_string())?;
        let now = config::read_raw(&path)?;
        let mut edits: BTreeMap<String, Option<String>> = want
            .iter()
            .filter(|(k, v)| now.get(*k) != Some(*v))
            .map(|(k, v)| (k.clone(), Some(v.clone())))
            .collect();
        for key in now
            .keys()
            .filter(|k| state_key(&old, k) && !want.contains_key(*k))
        {
            edits.insert(key.clone(), None);
        }
        report.push(Fault::Plain(format!("settings: {} changed", edits.len())));
        let zones_before = crate::dns::snapshot_zones(&old)?;
        edit_and_adopt(app, old, edits).await?;
        let s = app.settings();
        crate::dns::delete_old_zones(&s, &zones_before).await;
        let mut ok = true;
        // What: the parts after the settings each report.
        // Why: one failed part stops none; a rerun ends it.
        // From: Issue #1683 | PR #2020
        if let Some(cfg) = state.get("kea").filter(|v| !v.is_null()) {
            match crate::dhcp::kea_set(&s, cfg.clone()).await {
                Ok(()) => report.push(Fault::Plain("kea: restored".into())),
                Err(e) => {
                    ok = false;
                    report.push(Fault::Plain(format!("kea: {e}")));
                }
            }
        }
        for (zone, rows) in state["zones"].as_object().into_iter().flatten() {
            let rows = rows.as_array().cloned().unwrap_or_default();
            match crate::dns::restore_zone(&s, zone, &rows).await {
                Ok(()) => report.push(Fault::Plain(format!("zone {zone}: restored"))),
                Err(e) => {
                    ok = false;
                    report.push(Fault::Plain(format!("zone {zone}: {e}")));
                }
            }
        }
        report.push(Fault::Plain(format!(
            "now: {}",
            state_save(&app.settings()).await?
        )));
        Ok((ok, report))
    }

    // What: keep the state of now as a snapshot.
    // Why: REST, CLI and changes save it one way.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn state_save(s: &Settings) -> Result<String, String> {
        let state = state_capture(s).await?;
        let body = serde_json::to_vec(&state).map_err(|e| e.to_string())?;
        state_store(s)?.save(&body)
    }

    // What: after a change, keep the new state.
    // Why: any earlier state can be given back later.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn state_after(s: &Settings) {
        if let Err(e) = state_save(s).await {
            eprintln!("ui: state after the change not kept: {e}");
        }
    }

    // What: run one owner's exec rows in its container.
    // Why: daemon reloads and dnsmasq run them one way.
    // From: Issue #1683 | PR #2020
    async fn reload_owner(
        app: &Stack,
        s: &Settings,
        owner: &str,
        ex: &[String],
        tag: &str,
        limit: Duration,
    ) -> (Option<apply::Outcome>, Fault) {
        match container_of(app, s, owner).await {
            Ok(name) => {
                let r = apply::reload_exec(&app.docker, &name, ex, owner, limit).await;
                let line = format!("{owner} {tag}: {r:?}").into();
                (Some(r), line)
            }
            Err(e) => (None, Fault::lead(format!("{owner} {tag}: skipped, "), e)),
        }
    }

    // What: SOT keys and values of one change.
    // Why: forms, REST and CLI change settings so.
    // From: Issue #1683 | PR #1980
    pub(crate) type Fields = BTreeMap<String, String>;

    // What: list setting with one item in or out.
    // Why: domain add, remove and toggle share it.
    // From: Issue #1683 | PR #1980
    pub(crate) fn list_change(
        s: &Settings,
        key: &str,
        item: &str,
        present: bool,
    ) -> Result<Fields, String> {
        let mut items: Vec<String> = s.list(key)?.into_iter().filter(|x| x != item).collect();
        if present {
            items.push(item.to_string());
        }
        Ok(Fields::from([(
            key.to_string(),
            crate::config::join_items(&items),
        )]))
    }

    // What: a form with exactly one field.
    // Why: commit takes Fields; a switch saves one key.
    // From: Issue #1683 | PR #1980
    pub(crate) fn single_field(key: &str, value: impl ToString) -> Fields {
        Fields::from([(key.to_string(), value.to_string())])
    }

    // What: all files with secrets and the live chain.
    // Why: write, plan and preview render one way.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn render_now(
        s: &Settings,
    ) -> Result<Result<Vec<render::File>, Vec<String>>, String> {
        let sec = render::secrets(s)?;
        let chain = dnssec_chain(s).await;
        Ok(render::all(s, &sec, &chain))
    }

    // What: state of a settings change and apply.
    // Why: dns and dhcp need no web state to save.
    // From: Issue #1683 | PR #2020
    pub(crate) struct Stack {
        pub(crate) settings: RwLock<Settings>,
        pub(crate) saved: Option<PathBuf>,
        pub(crate) docker: docker::Api,
        // What: true once every config was rendered.
        // Why: dns and proxy wait for these files.
        // From: Issue #1683 | PR #1858
        pub(crate) rendered: AtomicBool,
        // What: one settings change or apply at a time.
        // Why: two saves at once mix their read and write.
        // From: Issue #1683 | PR #2020
        pub(crate) change: tokio::sync::Mutex<()>,
    }

    impl Stack {
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
            Ok((grace, crate::shared::docker::timeout(s)?))
        }
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

    // What: the settings file, or an error when unset.
    // Why: commit and check_change fail the same way.
    // From: Issue #1683 | PR #2020
    fn saved_path(app: &Stack) -> Result<PathBuf, String> {
        app.saved
            .clone()
            .ok_or_else(|| format!("{} is not set", config::SETTINGS_FILE_ENV))
    }

    // What: save, reload, render, write, apply.
    // Why: one path for every setting change.
    // From: Issue #1683 | PR #1858
    pub(crate) async fn commit(app: &Stack, form: Fields) -> Result<(), String> {
        commit_with(app, |_| Ok::<_, String>(form)).await
    }

    // What: a change built from the settings it replaces.
    // Why: read, change, write under one lock; no loss.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn commit_with<E: From<String>>(
        app: &Stack,
        build: impl FnOnce(&Settings) -> Result<Fields, E>,
    ) -> Result<(), E> {
        let _held = app.change.lock().await;
        let old = app.settings();
        let form = build(&old)?;
        save_and_adopt(app, old, form).await?;
        state_after(&app.settings()).await;
        Ok(())
    }

    // What: write a change and apply it; lock is held.
    // Why: commit_with is the one caller that locks.
    // From: Issue #1683 | PR #1858
    async fn save_and_adopt(app: &Stack, old: Settings, form: Fields) -> Result<(), String> {
        let edits = changes(&old, form)
            .into_iter()
            .map(|(k, v)| (k, Some(v)))
            .collect();
        edit_and_adopt(app, old, edits).await
    }

    // What: write sets and drops, check, then apply.
    // Why: a save and a restore end the same way.
    // From: Issue #1683 | PR #2020
    async fn edit_and_adopt(
        app: &Stack,
        old: Settings,
        updates: BTreeMap<String, Option<String>>,
    ) -> Result<(), String> {
        let path = saved_path(app)?;
        if updates.is_empty() {
            return Ok(());
        }
        let before = config::read_raw(&path)?;
        config::save_edits(&path, &old, &updates)?;
        let new = Settings::load(&process_env, Some(&path))?;
        if let Err(e) = render_check(&new) {
            // What: refused save is logged, not only shown.
            // Why: the error must leave trace in the logs.
            // From: Issue #1683 | PR #1991
            eprintln!("ui: save refused: {e}");
            // What: only changed keys get their old values.
            // Why: a whole-file write undoes setup.sh edits
            // From: Issue #1683 | PR #2017
            let back = updates
                .keys()
                .map(|k| (k.clone(), before.get(k).cloned()))
                .collect();
            config::edit_lines(&path, &back)
                .map_err(|w| format!("{e}; old values not restored: {w}"))?;
            return Err(e);
        }
        for line in adopt(app, &old, new).await? {
            eprintln!("ui: apply: {line}");
        }
        Ok(())
    }

    // What: a value that cannot render is not kept.
    // Why: a bad value must not reach the files.
    // From: Issue #1683 | PR #1980
    pub(crate) fn render_check(new: &Settings) -> Result<(), String> {
        let none = crate::shared::recursor_conf::Chain::default();
        let sec = render::secrets(new)?;
        render::all(new, &sec, &none).map_err(|e| e.join("; "))?;
        Ok(())
    }

    // What: apply new settings, then make them current.
    // Why: save and apply-now end the same way.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn adopt(
        app: &Stack,
        old: &Settings,
        new: Settings,
    ) -> Result<Vec<Fault>, String> {
        let lines = apply_all(app, old, &new, true).await?;
        match app.settings.write() {
            Ok(mut s) => *s = new,
            Err(poisoned) => *poisoned.into_inner() = new,
        }
        Ok(lines)
    }

    // What: read the settings file again and apply it.
    // Why: a hand edit or a lost file takes effect.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn apply_now(app: &Stack) -> Result<Vec<Fault>, String> {
        let _held = app.change.lock().await;
        let old = app.settings();
        let new = match app.saved.clone() {
            Some(path) => Settings::load(&process_env, Some(&path))?,
            None => old.clone(),
        };
        render_check(&new)?;
        adopt(app, &old, new).await
    }

    // What: keys a change would set, if it renders.
    // Why: config validate and ?dry_run=1 save nothing.
    // From: Issue #1683 | PR #2020
    pub(crate) fn check_change(app: &Stack, form: Fields) -> Result<Vec<String>, String> {
        let path = saved_path(app)?;
        let old = app.settings();
        let updates = changes(&old, form);
        if !updates.is_empty() {
            render_check(&config::trial(&path, &old, &updates)?)?;
        }
        Ok(updates.into_keys().collect())
    }

    // What: container name of a compose service.
    // Why: Docker calls need the real name.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn container_of(
        app: &Stack,
        s: &Settings,
        service: &str,
    ) -> Result<String, Fault> {
        let list = app.docker.stack(s).await?;
        let hit = docker::rows_of(&list, service).next();
        hit.and_then(docker::name_of)
            .map(str::to_string)
            .ok_or_else(|| Fault::key("err_no_container", [("service", service.to_string())]))
    }

    // What: run a command in a service container.
    // Why: rc-service and cachehamster go this way.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn exec_in(
        app: &Stack,
        s: &Settings,
        service: &str,
        cmd: &[&str],
    ) -> Result<(i64, String), Fault> {
        let name = container_of(app, s, service).await?;
        let (_, limit) = app.limits(s)?;
        Ok(app
            .docker
            .exec(&name, cmd, limit)
            .await
            .map_err(|e| e.to_string())?)
    }

    // What: run the first service:command row of a key.
    // Why: chrony and the clock run their SOT row so.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn exec_row(
        app: &Stack,
        s: &Settings,
        key: &str,
    ) -> Result<(Vec<String>, i64, String), String> {
        let rows = s.list(key)?;
        let (svc, cmd) = apply::exec_rows(&rows)
            .next()
            .ok_or_else(|| format!("{key} has no service:command row"))?;
        let (code, text) = exec_in(app, s, svc, &cmd)
            .await
            .map_err(|e| crate::ui::say(&e))?;
        Ok((cmd.iter().map(|c| c.to_string()).collect(), code, text))
    }

    // What: run a command; read its last JSON line.
    // Why: cachehamster and watchdog answer in JSON.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn exec_json(
        app: &Stack,
        s: &Settings,
        service: &str,
        cmd: &[&str],
    ) -> Result<(i64, Value), Fault> {
        let (code, out) = exec_in(app, s, service, cmd).await?;
        let v = last_json(&out).map_err(|e| format!("{}: {e}", cmd.join(" ")))?;
        Ok((code, v))
    }

    // What: the last JSON line of a command output.
    // Why: one reader for exec_json and exec_row users.
    // From: Issue #1683 | PR #2020
    pub(crate) fn last_json(out: &str) -> Result<Value, String> {
        let line = out
            .lines()
            .rev()
            .find(|l| l.starts_with('{'))
            .unwrap_or_default();
        serde_json::from_str(line).map_err(|e| format!("{e}: {out}"))
    }

    // What: drop proxy render files no longer written.
    // Why: an old https.conf keeps the SSL server alive.
    // From: Issue #1683 | PR #2019
    pub(crate) fn prune_rendered(
        s: &Settings,
        files: &[render::File],
    ) -> Result<Vec<PathBuf>, String> {
        let stale = stale_rendered(s, files)?;
        for path in &stale {
            crate::shared::fs::delete_if_present(path)
                .map_err(|e| format!("{}: {e}", path.display()))?;
        }
        Ok(stale)
    }

    // What: a proxy reload, tagged with its reason.
    // Why: prune, plan and new certs ask the same.
    // From: Issue #1683 | PR #2020
    pub(crate) fn proxy_reload(s: &Settings, why: &str) -> Result<config::Change, String> {
        Ok(config::Change {
            key: why.into(),
            owner: s.text("PROXY_SERVICE")?,
            effect: config::Effect::Reload,
        })
    }

    // What: removed proxy files ask for a proxy reload.
    // Why: apply and its dry run share the rule.
    // From: Issue #1683 | PR #2019
    pub(crate) fn prune_change(
        s: &Settings,
        stale: &[PathBuf],
    ) -> Result<Option<config::Change>, String> {
        if stale.is_empty() {
            return Ok(None);
        }
        proxy_reload(s, "proxy-prune").map(Some)
    }

    // What: what an apply would write and whom it wakes.
    // Why: page, REST and CLI show one dry run.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn render_plan(s: &Settings) -> Result<Value, String> {
        let files = match render_now(s).await? {
            Ok(f) => f,
            Err(errors) => return Ok(json!({"errors": errors})),
        };
        let warnings = render::take_notes();
        let rows = render::file_states(&files)?;
        let mut changes = Vec::new();
        let mut list = Vec::new();
        for (f, state) in &rows {
            // What: a new file wakes nobody, as in write.
            // Why: owners read it at their start.
            // From: Issue #1683 | PR #2020
            if *state == render::FileState::Changed {
                changes.push(render::change_of(f));
            }
            list.push(json!({"path": f.path, "owner": f.owner, "state": state}));
        }
        let stale = stale_rendered(s, &files)?;
        changes.extend(prune_change(s, &stale)?);
        let owners: BTreeMap<String, String> = apply::owner_effects(&changes)
            .into_iter()
            .map(|(o, e)| (o, e.word().to_string()))
            .collect();
        Ok(
            json!({"files": list, "stale": stale, "owners": owners, "errors": [],
            "warnings": warnings}),
        )
    }

    // What: proxy render files this render no longer has.
    // Why: prune removes them; the plan lists them.
    // From: Issue #1683 | PR #2020
    pub(crate) fn stale_rendered(
        s: &Settings,
        files: &[render::File],
    ) -> Result<Vec<PathBuf>, String> {
        let conf = PathBuf::from(s.text("NGINX_CONF_DIR")?);
        let mut stale = Vec::new();
        // What: no parts is an error, not "nothing stale".
        // Why: a missing key must not skip the prune.
        // From: Issue #1683 | PR #2020
        let parts = s.list("NGINX_LINK_PARTS")?;
        if parts.is_empty() {
            return Err("NGINX_LINK_PARTS is empty".into());
        }
        for part in parts {
            let dir = conf.join(part);
            let kept: BTreeSet<&Path> = files
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
                    stale.push(path);
                }
            }
        }
        Ok(stale)
    }

    // What: container name per plan owner; others drop out.
    // Why: an owner without a container has nothing to do.
    // From: Issue #1683 | PR #2017
    pub(crate) async fn plan_containers<V>(
        app: &Stack,
        s: &Settings,
        plan: &mut BTreeMap<String, V>,
    ) -> (BTreeMap<String, String>, Vec<Fault>) {
        let (mut names, mut skipped) = (BTreeMap::new(), Vec::new());
        for owner in plan.keys() {
            match container_of(app, s, owner).await {
                Ok(name) => {
                    names.insert(owner.clone(), name);
                }
                Err(e) => skipped.push(Fault::lead(format!("{owner}: skipped, "), e)),
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
        let files = render_now(s).await?.map_err(|e| e.join("; "))?;
        let written = render::write_files(s, &files)?;
        Ok((files, written))
    }

    // What: render, write and wake the owners.
    // Why: only owners with changes are touched.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn apply_all(
        app: &Stack,
        old: &Settings,
        new: &Settings,
        zones: bool,
    ) -> Result<Vec<Fault>, String> {
        let (files, written) = render_and_write(new).await?;
        // What: what the render left out, in the report.
        // Why: a dropped address must show, not only log.
        // From: Issue #1683 | PR #2020
        let mut report: Vec<Fault> = render::take_notes()
            .into_iter()
            .map(|w| format!("render: {w}").into())
            .collect();
        let mut changes = old.diff(new);
        app.rendered.store(true, Ordering::Relaxed);
        changes.extend(written.iter().cloned());
        // What: drop proxy render files no longer written.
        // Why: a left-over https.conf keeps SSL server up.
        // From: Issue #1683 | PR #2019
        let removed = prune_rendered(new, &files)?;
        for path in &removed {
            eprintln!("ui: removed stale {}", path.display());
        }
        changes.extend(prune_change(new, &removed)?);
        // What: what each apply step did, for the caller.
        // Why: a failed step shows; the next still runs.
        // From: Issue #1683 | PR #1980
        let (grace, limit) = app.limits(new)?;
        // What: a new file runs the commands of its daemon.
        // Why: the daemons do not watch their file.
        // From: Issue #1683 | PR #2002
        for (file, exec, tag) in [
            ("SNMPD_CONF_FILE", "SNMPD_RELOAD_EXEC", "snmpd"),
            ("PDNS_CONF_FILE", "PDNS_RESTART_EXEC", "pdns"),
            ("DNSDIST_CONF_FILE", "DNSDIST_RESTART_EXEC", "dnsdist"),
        ] {
            let path = new.text(file)?;
            if !written.iter().any(|c| c.key == path) {
                continue;
            }
            let ex = new.list(exec)?;
            let owners: BTreeSet<&str> = apply::exec_rows(&ex).map(|(owner, _)| owner).collect();
            for owner in owners {
                report.push(reload_owner(app, new, owner, &ex, tag, limit).await.1);
            }
        }
        // What: at start zones_at_start owns this step.
        // Why: dns may not be up yet at that moment.
        // From: Issue #1683 | PR #1980
        if zones && let Err(e) = ensure_zones(new).await {
            report.push(e.into());
        }
        // What: render again once the zones stand.
        // Why: a new zone has its DS only after ensure.
        // From: Issue #1683 | PR #2019
        if zones {
            match render_and_write(new).await {
                Ok((_, again)) => changes.extend(again),
                Err(e) => report.push(e.into()),
            }
        }
        let mut plan = apply::owner_effects(&changes);
        // What: mode off stops dhcp; a missing one is fine.
        // Why: compose up may have started it again.
        // From: Issue #1683 | PR #1980
        let dhcp = new.text("DHCP_SERVICE")?;
        if crate::shared::dhcp::off_service(new)?.is_some() {
            plan.remove(&dhcp);
            match stays_off(app, new).await {
                Ok(Some(done)) => report.push(format!("{dhcp}: {done}").into()),
                Ok(None) => {}
                Err(e) => report.push(format!("{dhcp}: mode off, {e}").into()),
            }
        }
        // What: proxy and relay share one dnsmasq daemon.
        // Why: a mode change keeps the container running.
        // From: Issue #1683 | PR #2002
        let (was, now) = (DhcpMode::from_settings(old)?, DhcpMode::from_settings(new)?);
        let ex = new.list("DNSMASQ_RESTART_EXEC")?;
        if was.is_dnsmasq() && now.is_dnsmasq() && plan.contains_key(&dhcp) && !ex.is_empty() {
            let (r, line) = reload_owner(app, new, &dhcp, &ex, "dnsmasq", limit).await;
            if r.is_some_and(|r| !matches!(r, apply::Outcome::Failed(_))) {
                plan.remove(&dhcp);
            }
            report.push(line);
        }
        // What: skip an owner that has no container yet.
        // Why: at stack start it reads new files anyway.
        // From: Issue #1683 | PR #1980
        let (names, skipped) = plan_containers(app, new, &mut plan).await;
        report.extend(skipped);
        let lookup = |owner: &str| names.get(owner).cloned().unwrap_or_default();
        let rx = new.list("RELOAD_EXEC")?;
        let mut restarted = Vec::new();
        let mut results = apply::run(&app.docker, &plan, &rx, &lookup, grace, limit).await;
        // What: one more try for owners that got a 409.
        // Why: compose may recreate a container meanwhile.
        // From: Issue #1683 | PR #1980
        let conflict =
            |r: &apply::Outcome| matches!(r, apply::Outcome::Failed(docker::Error::Status(409)));
        if results.iter().any(|(_, r)| conflict(r)) {
            tokio::time::sleep(limit).await;
            let again: BTreeMap<_, _> = plan
                .iter()
                .filter(|(o, _)| results.iter().any(|(x, r)| x == *o && conflict(r)))
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
            report.push(format!("{owner}: {result:?}").into());
        }
        for (name, cause) in wait_healthy(app, new, &restarted, limit).await? {
            match cause {
                Some(e) => report.push(format!("{name}: not healthy in time, inspect: {e}").into()),
                None => report.push(format!("{name}: not healthy in time").into()),
            }
        }

        // What: after a dns restart wait for the pdns API.
        // Why: a page must not load before pdns runs.
        // From: Issue #1683 | PR #1980
        if names
            .get(&new.text("DNS_SERVICE")?)
            .is_some_and(|n| restarted.contains(n))
        {
            let until = Instant::now() + limit;
            let poll = Duration::from_secs(new.uint("APPLY_HEALTH_POLL_SECONDS")?);
            while let Err(e) = ensure_zones(new).await {
                if Instant::now() >= until {
                    report.push(format!("dns api: {e}").into());
                    break;
                }
                tokio::time::sleep(poll).await;
            }
        }
        // What: issue missing certs after the restarts.
        // Why: many leaves take time; dns must not wait.
        // From: Issue #1683 | PR #1980
        report.extend(issue_and_reload(app, new).await?);
        Ok(report)
    }

    // What: issue missing certs; reload the proxy.
    // Why: apply and cert renewal share the step.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn issue_and_reload(
        app: &Stack,
        new: &Settings,
    ) -> Result<Vec<Fault>, String> {
        let mut report = Vec::new();
        let s = new.clone();
        let issued = tokio::task::spawn_blocking(move || render::issue_certs(&s))
            .await
            .map_err(|e| e.to_string())?;
        match issued {
            Ok(0) => {}
            Ok(n) => {
                report.push(format!("certs: {n} issued").into());
                let (grace, limit) = app.limits(new)?;
                let rx = new.list("RELOAD_EXEC")?;
                let mut plan = apply::owner_effects(&[proxy_reload(new, "certs")?]);
                let (names, _) = plan_containers(app, new, &mut plan).await;
                let lookup = |owner: &str| names.get(owner).cloned().unwrap_or_default();
                for (owner, result) in
                    apply::run(&app.docker, &plan, &rx, &lookup, grace, limit).await
                {
                    report.push(format!("{owner}: {result:?}").into());
                }
            }
            Err(e) => report.push(format!("certs: {e}").into()),
        }
        Ok(report)
    }

    // What: wait until restarted containers are healthy.
    // Why: "done" must mean the service answers again.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn wait_healthy(
        app: &Stack,
        s: &Settings,
        names: &[String],
        limit: Duration,
    ) -> Result<Vec<(String, Option<String>)>, String> {
        let wait = Duration::from_secs(s.uint("APPLY_HEALTH_WAIT_SECONDS")?);
        let poll = Duration::from_secs(s.uint("APPLY_HEALTH_POLL_SECONDS")?);
        let end = Instant::now() + wait;
        let mut late = Vec::new();
        for name in names {
            loop {
                let (health, cause) = match app.docker.inspect(name, limit).await {
                    Ok(state) => (Some(docker::Health::from_inspect(&state)), None),
                    Err(e) => (None, Some(e.to_string())),
                };
                if matches!(
                    health,
                    Some(docker::Health::Healthy | docker::Health::Degraded)
                ) {
                    break;
                }
                if Instant::now() >= end {
                    late.push((name.clone(), cause));
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
    pub(crate) async fn set_wanted(app: &Stack, service: &str, run: bool) -> Result<(), Fault> {
        let s = app.settings();
        if !s
            .list("UI_CONTROLLABLE_SERVICES")?
            .iter()
            .any(|x| x == service)
        {
            return Err(Fault::key(
                "err_service_not_switchable",
                [("service", service.to_string())],
            ));
        }
        commit_with(app, |s| list_change(s, "SERVICES_STOPPED", service, !run)).await?;
        let (grace, limit) = app.limits(&s)?;
        let name = container_of(app, &s, service).await?;
        let action = if run {
            docker::Action::Start
        } else {
            docker::Action::Stop
        };
        Ok(app
            .docker
            .act(&name, action, grace, limit)
            .await
            .map_err(|e| e.to_string())?)
    }
}

// What: admin ui: settings, pages and actions.
// Why: owns settings; renders and applies configs.
// From: Issue #1683 | PR #1858
mod ui {
    use crate::cachehamster::{Rest, rest_of};
    use crate::config::{self, Settings};
    use crate::dhcp::{kea_change, kea_snapshots, kea_state, kea_store, probe_cli, stays_off};
    use crate::dns::{
        LanDomainEdit, answers_aa, commit_and_prune, delete_peer_records, ensure_zones,
        flush_on_transfer, hosted_now, lan_domain_action, main_domain_fields, ns_change, peer_kit,
        ptr, record, rollback, rotate_tsig, save_secondaries, secondary_health, secondary_watch,
        snapshot_list, snapshot_zones, valid_peer_name, zone_snapshots,
    };
    use crate::shared::dhcp::Mode as DhcpMode;
    use crate::shared::peer;
    use crate::shared::task::or_stop;
    use crate::shared::{FALLBACK_LANG, Fault};
    use crate::shared::{access, docker, fs, http, human, render, secret};
    use crate::stack::Stack;
    use crate::stack::{
        Fields, apply_all, apply_now, check_change, commit, commit_with, container_of, exec_in,
        exec_json, issue_and_reload, list_change, render_now, render_plan, set_wanted,
        single_field,
    };
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
    use std::path::Path;
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use std::sync::{Arc, RwLock};
    use std::time::Duration;
    use tera::{Context, Tera};

    // What: CLI word of the one-shot DHCP probe.
    // Why: the ui and setup.sh start the same command.
    // From: Issue #1683 | PR #1985
    pub(crate) const DHCP_PROBE_CMD: &str = "dhcp-probe";

    // What: read the files of one mounted folder.
    // Why: page edits need no image build.
    // From: Issue #1683 | PR #1991
    pub(crate) fn folder(dir: &str, ext: &str) -> Result<Vec<(String, String)>, String> {
        let entries = fs::entries_if_present(Path::new(dir)).map_err(|e| format!("{dir}: {e}"))?;
        let mut out = Vec::new();
        for path in entries {
            if path.extension().and_then(|e| e.to_str()) != Some(ext) {
                continue;
            }
            let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
                continue;
            };
            let body = fs::read_text(&path)?;
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
        let body = fs::read_bytes(&path)?;
        Ok(Box::leak(body.into_boxed_slice()))
    }

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

    // What: the built-in English texts, parsed once.
    // Why: the CLI never reads the language files.
    // From: Issue #1683 | PR #2020
    fn built_in() -> &'static BTreeMap<String, String> {
        static EN: std::sync::OnceLock<BTreeMap<String, String>> = std::sync::OnceLock::new();
        EN.get_or_init(|| parse_built_in().unwrap_or_default())
    }

    // What: parse the built-in English file.
    // Why: start and the CLI read the same embedded text.
    // From: Issue #1683 | PR #2020
    fn parse_built_in() -> Result<BTreeMap<String, String>, String> {
        serde_json::from_str(BUILT_IN_EN).map_err(|e| format!("built-in en: {e}"))
    }

    // What: one text in the request language.
    // Why: form errors speak the language of the page.
    // From: Issue #1683 | PR #1980
    fn tr(key: &str) -> String {
        let code = LANG.try_with(Clone::clone).unwrap_or_default();
        let all = all_texts();
        all.get(&code)
            .or_else(|| all.get(FALLBACK_LANG))
            .unwrap_or_else(|| built_in())
            .get(key)
            .cloned()
            .unwrap_or_else(|| key.to_string())
    }

    // What: the words of a failure in the request language.
    // Why: ui, REST and CLI translate at their border.
    // From: Issue #1683 | PR #2020
    pub(crate) fn say(fail: &Fault) -> String {
        match fail {
            Fault::Plain(text) => text.clone(),
            Fault::Key(key, vals) => crate::shared::fill(tr(key), vals),
            Fault::Lead(lead, cause) => format!("{lead}{}", say(cause)),
        }
    }

    // What: report lines as texts in the request language.
    // Why: REST answers a list of texts.
    // From: Issue #1683 | PR #2020
    pub(crate) fn say_all(lines: &[Fault]) -> Vec<String> {
        lines.iter().map(say).collect()
    }

    tokio::task_local! {
        // What: language of the request being served.
        // Why: page() has no headers; the layer sets it.
        // From: Issue #1683 | PR #1980
        static LANG: String;
    }

    // What: form field that carries the CSRF token.
    // Why: templates and handlers share one name.
    // From: Issue #1683 | PR #1980
    pub(crate) const CSRF_FIELD: &str = "csrf_token";

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

    impl From<Fault> for Fail {
        // What: a failure becomes status 500 with text.
        // Why: handlers pass domain errors on with ?.
        // From: Issue #1683 | PR #2020
        fn from(e: Fault) -> Self {
            Fail(StatusCode::INTERNAL_SERVER_ERROR, say(&e))
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

    // What: what a handler returns: response or Fail.
    // Why: handlers use ? on both kinds of error.
    // From: Issue #1683 | PR #1980
    pub(crate) type Page = Result<Response, Fail>;

    // What: state shared by all handlers.
    // Why: settings swap whole after each save.
    // From: Issue #1683 | PR #1858
    pub(crate) struct App {
        pub(crate) stack: Stack,
        pub(crate) tera: Tera,
        pub(crate) session_key: [u8; 32],
        pub(crate) cache_used: AtomicU64,
    }

    // What: App reads like its stack state.
    // Why: handlers keep app.settings() and app.docker.
    // From: Issue #1683 | PR #2020
    impl std::ops::Deref for App {
        type Target = Stack;
        fn deref(&self) -> &Stack {
            &self.stack
        }
    }

    // What: the axum state of every handler.
    // Why: one name for the shared App in signatures.
    // From: Issue #1683 | PR #1980
    pub(crate) type Shared = State<Arc<App>>;

    impl App {
        // What: render a page with the shared context.
        // Why: menu, csrf and values on every page.
        // From: Issue #1683 | PR #1858
        pub(crate) fn page(&self, name: &str, mut ctx: Context, csrf: &Csrf) -> Page {
            let s = self.settings();
            let page = name.trim_end_matches(".html");
            // What: every spec key, unset as empty text
            // Why: templates read optional keys unguarded.
            // From: Issue #1683 | PR #1980
            let values = s.view();
            let login = !password_hash(&s).is_empty();
            // What: page and route paths by short name.
            // Why: templates name SOT key without prefix.
            // From: Issue #1683 | PR #1985
            let paths = |prefix: &str| -> BTreeMap<String, String> {
                s.texts()
                    .filter_map(|(k, v)| {
                        k.strip_prefix(prefix).map(|n| (n.to_ascii_lowercase(), v))
                    })
                    .collect()
            };
            let (pages, routes) = (paths("UI_PAGE_"), paths("UI_ROUTE_"));
            ctx.insert(CSRF_FIELD, &csrf.0);
            ctx.insert("csrf_name", CSRF_FIELD);
            ctx.insert("page", page);
            ctx.insert("active_page", page);
            ctx.insert("v", &values);
            ctx.insert("login_enabled", &login);
            ctx.insert("pages", &pages);
            ctx.insert("routes", &routes);
            ctx.insert("repo_url", &s.text("REPO_URL")?);
            ctx.insert("desired_services", &s.list("UI_CONTROLLABLE_SERVICES")?);
            ctx.insert("programs", &s.list("UI_SERVICES")?);
            ctx.insert("ui_service", &s.text_or_empty("UI_SERVICE"));
            ctx.insert("status_refresh_seconds", &s.uint("UI_STATUS_REFRESH")?);
            ctx.insert("warnings", &s.warnings);
            // What: texts of the request language.
            // Why: templates hold keys; scripts get same.
            // From: Issue #1683 | PR #1980
            let code = LANG
                .try_with(Clone::clone)
                .unwrap_or_else(|_| s.text_or_empty("UI_LANG_DEFAULT"));
            let empty = BTreeMap::new();
            let t = all_texts()
                .get(&code)
                .or_else(|| all_texts().get(FALLBACK_LANG))
                .unwrap_or(&empty);
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
    pub(crate) struct Csrf(String, bool, String);

    impl Csrf {
        // What: token: SHA-256 of key and session.
        // Why: each session has its own form token.
        // From: Issue #1683 | PR #1980
        fn from_session(key: &[u8; 32], session: &str, header: &str) -> Self {
            let mut h = Sha256::new();
            h.update(key);
            h.update(session.as_bytes());
            Csrf(hex::encode(h.finalize()), false, header.to_string())
        }

        // What: the CLI socket: every check passes.
        // Why: no browser reaches it; file mode guards it.
        // From: Issue #1683 | PR #2020
        fn local(header: &str) -> Self {
            Csrf(String::new(), true, header.to_string())
        }

        // What: compares a given token in constant time.
        // Why: a plain compare leaks it by timing.
        // From: Issue #1683 | PR #1980
        fn matches(&self, given: &str) -> bool {
            self.1 || secret::equal(given, &self.0)
        }

        // What: form check; refuse without a match.
        // Why: each POST changes state.
        // From: Issue #1683 | PR #1980
        fn check(&self, form: &Fields) -> Result<(), Fail> {
            match form
                .get(CSRF_FIELD)
                .map(String::as_str)
                .or(self.1.then_some(""))
            {
                Some(t) if self.matches(t) => Ok(()),
                _ => Err(Fail(StatusCode::FORBIDDEN, tr("err_csrf"))),
            }
        }

        // What: header check for script calls.
        // Why: JSON calls send the token as a header.
        // From: Issue #1683 | PR #1980
        fn check_header(&self, headers: &HeaderMap) -> Result<(), Fail> {
            let given = headers.get(self.2.as_str()).and_then(|v| v.to_str().ok());
            match given.or(self.1.then_some("")) {
                Some(t) if self.matches(t) => Ok(()),
                _ => Err(Fail(StatusCode::FORBIDDEN, tr("err_csrf"))),
            }
        }
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

    // What: Basic auth; no hash needs ALLOW_INSECURE_UI.
    // Why: AG-SEC-001 holds at each login, not at start.
    // From: Issue #1683 | PR #1858
    pub(crate) async fn login_ok(s: &Settings, headers: &HeaderMap) -> bool {
        let hash = password_hash(s);
        if hash.is_empty() {
            return s.flag("ALLOW_INSECURE_UI").unwrap_or(false);
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
        let (Ok(name), Ok(header)) = (s.text("UI_SESSION_COOKIE"), s.text("UI_CSRF_HEADER")) else {
            return (StatusCode::INTERNAL_SERVER_ERROR, "session names missing").into_response();
        };
        let known = cookie(req.headers(), &name);
        let session = known.clone().unwrap_or_else(|| secret::random_hex(32));
        req.extensions_mut()
            .insert(Csrf::from_session(&app.session_key, &session, &header));
        let mut res = next.run(req).await;
        if known.is_none() {
            // What: cookie lives UI_SESSION_TTL_SECONDS.
            // Why: setup.sh asks it; capped by the MAX key.
            // From: Issue #1683 | PR #2020
            let ttl = s
                .uint("UI_SESSION_TTL_SECONDS")
                .and_then(|t| s.uint("UI_SESSION_TTL_MAX_SECONDS").map(|m| t.min(m)));
            let age = ttl.map(|t| format!("; Max-Age={t}")).unwrap_or_default();
            let v = format!("{name}={session}; HttpOnly; SameSite=Strict; Path=/{age}");
            if let Ok(v) = v.parse() {
                res.headers_mut().append(header::SET_COOKIE, v);
            }
        }
        res
    }

    // What: dashboard: alarms, containers, cache.
    // Why: first page; shows what needs a look.
    // From: Issue #1683 | PR #1858
    pub(crate) async fn dashboard(State(app): Shared, Extension(csrf): Extension<Csrf>) -> Page {
        let s = app.settings();
        let mut ctx = Context::new();
        // What: a bad alarm file is logged, the page stays.
        // Why: the dashboard must render without the file.
        // From: Issue #1683 | PR #2020
        let mut alarms = crate::watchdog::report(&s)
            .inspect_err(|e| eprintln!("ui: alarms: {e}"))
            .ok()
            .flatten();
        // What: alarm texts in the page language.
        // Why: the file has key and values beside English.
        // From: Issue #1683 | PR #2020
        for a in alarms
            .as_mut()
            .and_then(|v| v["alarms"].as_array_mut())
            .into_iter()
            .flatten()
        {
            if let Some(key) = a["key"].as_str() {
                let vals: Vec<(String, String)> =
                    serde_json::from_value(a["vals"].clone()).unwrap_or_default();
                a["text"] = crate::shared::fill(tr(key), &vals).into();
            }
        }
        // What: age of the report in seconds.
        // Why: an old report means a stopped watchdog.
        // From: Issue #1683 | PR #2020
        let age = alarms
            .as_ref()
            .and_then(|v| v["written"].as_u64())
            .map(|w| {
                crate::shared::clock::unix_secs()
                    .saturating_sub(w)
                    .to_string()
            });
        ctx.insert("alarms", &alarms);
        ctx.insert("alarms_age", &age);
        // What: no Docker answer: empty list, error logged.
        // Why: the page must render while Docker is down.
        // From: Issue #1683 | PR #2020
        let containers = app.docker.stack(&s).await;
        let containers = containers
            .inspect_err(|e| eprintln!("ui: containers: {e}"))
            .unwrap_or_default();
        ctx.insert("containers", &containers);
        // What: an unreadable proxy log shows as empty.
        // Why: the dashboard must render without the log.
        // From: Issue #1683 | PR #2020
        let log = crate::shared::access::summary(&s)
            .await
            .inspect_err(|e| eprintln!("ui: proxy log: {e}"))
            .unwrap_or_else(|_| crate::shared::access::none());
        ctx.insert("log_stats", &log["totals"]);
        ctx.insert("recent_logs", &log["recent"]);
        // What: no nginx answer: no live box, error logged.
        // Why: the dashboard renders while nginx is down.
        // From: Issue #1683 | PR #2020
        let live = crate::shared::nginx_conf::live(&s).await;
        if let Ok(live) = live.inspect_err(|e| eprintln!("ui: proxy live: {e}")) {
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
        let used = app.cache_used.load(Ordering::Relaxed);
        let usage = crate::shared::tidy::usage(&s, (used != u64::MAX).then_some(used));
        let usage = usage.inspect_err(|e| eprintln!("ui: cache usage: {e}"));
        if let Ok(u) = usage {
            if let Some(used) = u["used_bytes"].as_u64() {
                ctx.insert("cache_used_human", &human::bytes(used));
                ctx.insert("cache_pct", &u["pct_of_max"]);
            }
            // What: the form label names the largest size.
            // Why: the form must show the room left.
            // From: Issue #1069 | PR #1991
            if let Some(room) = u["reachable_bytes"].as_u64() {
                ctx.insert("cache_max_gib", &(room >> 30).to_string());
            }
        }
        app.page("dashboard.html", ctx, &csrf)
    }

    // What: General page.
    // Why: channel, updates, NTP and login.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn setup(State(app): Shared, Extension(csrf): Extension<Csrf>) -> Page {
        let s = app.settings();
        let mut ctx = Context::new();
        ctx.insert("ntp_answers", &crate::shared::ntp::own_answers(&s).await?);
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

    // What: GET query ?name=&type=&server= as JSON.
    // Why: REST on the query check of the CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn dns_query_api(
        State(app): Shared,
        axum::extract::Query(q): axum::extract::Query<Fields>,
    ) -> Response {
        let server = match field(&q, "server") {
            v if v.is_empty() => "http".to_string(),
            v => v,
        };
        let (s, name, rtype) = (app.settings(), field(&q, "name"), field(&q, "type"));
        json_reply(
            crate::dns::query(&s, &name, &rtype, &server)
                .await
                .map(Some),
            "",
        )
    }

    // What: GET PowerDNS API check without counters.
    // Why: REST read on the report of the CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn dns_api_check(State(app): Shared) -> Response {
        json_reply(
            crate::shared::peer::api_report(&app.settings(), false)
                .await
                .map(Some),
            "",
        )
    }

    // What: GET PowerDNS API check with all counters.
    // Why: REST read on the report of the CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn dns_stats_api(State(app): Shared) -> Response {
        json_reply(
            crate::shared::peer::api_report(&app.settings(), true)
                .await
                .map(Some),
            "",
        )
    }

    // What: GET DNSSEC anchors, proven zones and NTAs.
    // Why: REST read on the reader of the CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn dnssec_api(State(app): Shared) -> Response {
        json_reply(
            crate::dns::dnssec_status(&app.settings()).await.map(Some),
            "",
        )
    }

    // What: POST flush ?zone=; no zone flushes all.
    // Why: REST on the flush the CLI and pages use.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn dns_flush_api(
        State(app): Shared,
        Extension(csrf): Extension<Csrf>,
        axum::extract::Query(query): axum::extract::Query<Fields>,
        headers: HeaderMap,
    ) -> Page {
        csrf.check_header(&headers)?;
        let zone = match field(&query, "zone") {
            z if z.is_empty() => ".".to_string(),
            z => z,
        };
        crate::shared::peer::flush_zone(&app.settings(), &zone)
            .await
            .map_err(|e| Fail(StatusCode::BAD_GATEWAY, e))?;
        Ok(axum::Json(json!({"flushed": zone})).into_response())
    }

    // What: GET schema rows, masked values and origins.
    // Why: REST read on the describer of the CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn settings_schema_api(State(app): Shared) -> Response {
        json_reply(app.settings().describe(None).map(Some), "")
    }

    // What: GET the cache domain rows and the list.
    // Why: REST read on the reader of page and CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn cdn_api(State(app): Shared) -> Response {
        json_reply(crate::shared::cdn::listing(&app.settings()).map(Some), "")
    }

    // What: GET the apply plan: files, owners, errors.
    // Why: REST dry run on the reader of the CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn apply_plan_api(State(app): Shared) -> Response {
        json_reply(render_plan(&app.settings()).await.map(Some), "")
    }

    // What: GET Docker engine check as JSON.
    // Why: REST read on the check of the CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn docker_api(State(app): Shared) -> Response {
        json_reply(
            docker::engine_check(&app.docker, &app.settings())
                .await
                .map(Some),
            "",
        )
    }

    // What: GET psl ?host=: how the proxy maps it.
    // Why: REST read on the lookup of the CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn proxy_psl_api(
        State(app): Shared,
        axum::extract::Query(q): axum::extract::Query<Fields>,
    ) -> Response {
        let host = field(&q, "host");
        json_reply(
            crate::shared::render::psl_lookup(&app.settings(), &host).map(Some),
            "",
        )
    }

    // What: GET preview ?pick=owner-or-path, masked.
    // Why: REST read on the preview of the CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn apply_preview_api(
        State(app): Shared,
        axum::extract::Query(q): axum::extract::Query<Fields>,
    ) -> Response {
        let pick = field(&q, "pick");
        let pick = (!pick.is_empty()).then_some(pick.as_str());
        json_reply(render_preview(&app.settings(), pick).await.map(Some), "")
    }

    // What: POST apply now; answers the apply report.
    // Why: CLI and REST apply without a restart.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn apply_api(
        State(app): Shared,
        Extension(csrf): Extension<Csrf>,
        headers: HeaderMap,
    ) -> Page {
        csrf.check_header(&headers)?;
        let lines = apply_now(&app).await.map_err(bad_request)?;
        Ok(axum::Json(json!({"report": say_all(&lines)})).into_response())
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
        // What: back to the sending page; a local path.
        // Why: browsers read "\\" as "/": "/\\x" is a host.
        // From: Issue #1683 | PR #2020
        let back = form
            .get("back")
            .filter(|b| b.starts_with('/') && !b.starts_with("//") && !b.contains('\\'))
            .cloned()
            .map_or_else(|| app.settings().text("UI_PAGE_SETUP"), Ok)?;
        save_settings(&app, form, false).await?;
        Ok(Redirect::to(&back).into_response())
    }

    // What: check, derive and save a settings change.
    // Why: page form and REST save the same way.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn save_settings(
        app: &App,
        form: Fields,
        dry: bool,
    ) -> Result<Vec<String>, Fail> {
        // What: the hash only through the password form.
        // Why: it checks the old password and length.
        // From: Issue #1683 | PR #2020
        if form.contains_key("UI_AUTH_PASSWORD_HASH") {
            return Err(bad_request(tr("err_password_form")));
        }
        cache_room(
            &app.settings(),
            &form,
            app.cache_used.load(Ordering::Relaxed),
        )?;
        // What: a new main domain also updates the extras.
        // Why: an extra made main must leave extra list.
        // From: Issue #1683 | PR #2020
        let mut form = form;
        if let Some(d) = form.get("DHCP_DOMAIN").cloned() {
            form.extend(main_domain_fields(&app.settings(), &d).map_err(bad_request)?);
        }
        // What: each upstream entry is checked before save.
        // Why: threat model G3: no loop to this host.
        // From: Issue #1683 | PR #1985
        for key in ["DNS_UPSTREAM_SERVERS", "NGINX_UPSTREAM_RESOLVER"] {
            let items: Vec<&str> = form
                .get(key)
                .map(|v| config::list_items(v).collect())
                .unwrap_or_default();
            crate::shared::recursor_conf::check_upstream(&app.settings(), key, &items)
                .map_err(bad_request)?;
        }
        // What: the zones before save; none if unreadable.
        // Why: a save may repair the settings; it must run.
        // From: Issue #1683 | PR #2017
        let before = hosted_now(&app.settings())
            .inspect_err(|e| eprintln!("ui: zones before the save unknown: {e}"))
            .unwrap_or_default();
        // What: a dry run checks the change, saves none.
        // Why: the same checks; nothing is applied.
        // From: Issue #1683 | PR #2020
        if dry {
            return check_change(app, form).map_err(bad_request);
        }
        commit_and_prune(app, form, &before)
            .await
            .map_err(bad_request)?;
        Ok(Vec::new())
    }

    // What: logs page.
    // Why: newest lines plus on/off per program.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn logs(State(app): Shared, Extension(csrf): Extension<Csrf>) -> Page {
        let s = app.settings();
        let max = s.num::<usize>("UI_LOG_LINES")?;
        let c = s.clone();
        let v = tokio::task::spawn_blocking(move || access::program_logs(&c, None, None))
            .await
            .map_err(|e| e.to_string())??;
        let mut ctx = Context::new();
        ctx.insert("syslog_logs", &v["lines"]);
        ctx.insert("syslog_hosts", &v["hosts"]);
        ctx.insert("log_switches", &v["switches"]);
        ctx.insert("logs_max_entries", &max);
        app.page("logs.html", ctx, &csrf)
    }

    // What: GET logs ?program=&n= as JSON.
    // Why: REST read on the reader of page and CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn logs_api(
        State(app): Shared,
        axum::extract::Query(q): axum::extract::Query<Fields>,
    ) -> Response {
        let s = app.settings();
        let program = Some(field(&q, "program")).filter(|p| !p.is_empty());
        let n = field(&q, "n").parse::<usize>().ok();
        let r =
            tokio::task::spawn_blocking(move || access::program_logs(&s, program.as_deref(), n))
                .await
                .map_err(|e| e.to_string())
                .and_then(|r| r);
        json_reply(r.map(Some), "")
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
            .list("SYSLOG_PROGRAMS")?
            .into_iter()
            .filter(|p| !is_on(p))
            .collect();
        let targets = form.get("SYSLOG_FORWARD").cloned().unwrap_or_default();
        let targets: Vec<&str> = config::list_items(&targets).collect();
        let mut change = Fields::new();
        change.insert("SYSLOG_MUTED".into(), crate::config::join_items(&muted));
        change.insert("SYSLOG_FORWARD".into(), crate::config::join_items(&targets));
        let back = format!("{}#syslog", app.settings().text("UI_PAGE_LOGS")?);
        finish(commit(&app, change).await, &back)
    }

    // What: DNS page.
    // Why: records are read live from PowerDNS.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn domains(State(app): Shared, Extension(csrf): Extension<Csrf>) -> Page {
        let s = app.settings();
        let lan = crate::shared::dns::lan_zone(&s)?;
        let mut ctx = Context::new();
        ctx.insert("dns_domains", &crate::shared::cdn::parse_rows(&s)?);
        ctx.insert("lan_zone", crate::shared::dns::bare_zone(&lan));
        let view = crate::dns::lan_view(&s).await?;
        if let Some(e) = view["error"].as_str() {
            ctx.insert("domain_error_message", e);
        }
        ctx.insert("missing_ptrs", &view["missing_ptrs"]);
        ctx.insert("lan_domains", &view["domains"]);
        ctx.insert("ptr_zones", &view["ptr_zones"]);
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
        // Why: the row shows it and offers matching button.
        // From: Issue #1683 | PR #2017
        let (ns, off) = (s.list("DNS_SECONDARY_NS")?, s.list("DNS_SECONDARY_NS_OFF")?);
        let peers: Vec<Value> = crate::shared::pdns_conf::secondaries(&s)?
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
        let nightly = config::image().channel == s.text("SETUP_CHANNEL_NIGHTLY")?;
        let (url_key, ref_key) = if nightly {
            ("SETUP_SCRIPT_URL_NIGHTLY", "SETUP_GIT_REF_NIGHTLY")
        } else {
            ("SETUP_SCRIPT_URL", "SETUP_GIT_REF")
        };
        ctx.insert("setup_script_url", &s.text(url_key)?);
        ctx.insert("setup_git_ref", &s.text(ref_key)?);
        ctx.insert("primary_ip", &s.text("IP_HTTP")?);
        // What: HTTPS proxy IP when it is a second LAN IP.
        // Why: the copied command then sets HTTPS DNS bind.
        // From: Issue #1683 | PR #1980
        ctx.insert(
            "primary_ip_https",
            &crate::shared::dns::https_ip(&s)?.unwrap_or_default(),
        );

        // What: UI address on the LAN when none is set.
        // Why: the install command needs an address.
        // From: Issue #1683 | PR #1980
        let mut url = s.text_or_empty("UI_PUBLIC_URL");
        if url.is_empty() {
            url = format!("http://{}:{}", s.text("IP_HTTP")?, s.uint("UI_PORT")?);
        }
        ctx.insert("primary_url", &url);
        ctx.insert("lan_record_types", &s.list("DNS_LAN_RECORD_TYPES")?);
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

    // What: one DNS page form, chosen by its SOT key.
    // Why: all DNS forms share one handler.
    // From: Issue #1683 | PR #1985
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
            DnsOp::DnsAdd => {
                commit_with(&app, |s| {
                    list_change(s, "CDN_CUSTOM_DOMAINS", &domain, true)
                })
                .await
            }
            DnsOp::DnsRemove => {
                commit_with(&app, |s| {
                    list_change(s, "CDN_CUSTOM_DOMAINS", &domain, false)
                })
                .await
            }
            DnsOp::DnsToggle => {
                commit_with(&app, |s| {
                    list_change(s, "CDN_DISABLED_DOMAINS", &domain, !on)
                })
                .await
            }
            DnsOp::AaaaFilter => commit(&app, single_field("DNS_FILTER_AAAA", on)).await,
            DnsOp::QueryLog => commit(&app, single_field("DNS_QUERY_LOG", on)).await,
            DnsOp::DdnsUnsigned => commit(&app, single_field("DDNS_ALLOW_UNSIGNED", on)).await,
            DnsOp::NsSwitch => commit(&app, single_field("DNS_SECONDARY_NS_ENABLED", on)).await,
            DnsOp::NsAuto => commit(&app, single_field("DNS_SECONDARY_NS_AUTO_REMOVE", on)).await,
            DnsOp::LanAdd | DnsOp::LanRemove => {
                record(&s, matches!(op, DnsOp::LanAdd), &record_input(&get))
                    .await
                    .map_err(|e| say(&e))
            }
            DnsOp::LanDomainAdd => lan_domain_action(&app, &s, LanDomainEdit::Add, &domain)
                .await
                .map_err(|e| say(&e)),
            DnsOp::LanDomainRemove => lan_domain_action(&app, &s, LanDomainEdit::Remove, &domain)
                .await
                .map_err(|e| say(&e)),
            DnsOp::LanDomainMain => lan_domain_action(&app, &s, LanDomainEdit::Main, &domain)
                .await
                .map_err(|e| say(&e)),
            DnsOp::PtrAdd | DnsOp::PtrRemove => {
                let input = crate::dns::PtrInput {
                    ip: get("ip"),
                    hostname: get("hostname"),
                    ttl: get("ttl").parse().unwrap_or(0),
                };
                ptr(&s, matches!(op, DnsOp::PtrAdd), &input)
                    .await
                    .map_err(|e| say(&e))
            }
            DnsOp::ZoneRollback => rollback(&s, &get("zone"), &get("snapshot_id"))
                .await
                .map_err(|e| say(&e)),
            DnsOp::TsigRotate => rotate_tsig(&app).await,
        };
        // What: record and zone changes keep the state.
        // Why: settings changes keep it in commit_with.
        // From: Issue #1683 | PR #2020
        let zone_change = matches!(
            op,
            DnsOp::LanAdd
                | DnsOp::LanRemove
                | DnsOp::PtrAdd
                | DnsOp::PtrRemove
                | DnsOp::ZoneRollback
        );
        if result.is_ok() && zone_change {
            crate::stack::state_after(&app.settings()).await;
        }
        finish(result, &s.text("UI_PAGE_DOMAINS")?)
    }

    // What: the LAN record form as typed input.
    // Why: form field names stay in the ui.
    // From: Issue #1683 | PR #2020
    fn record_input(get: &dyn Fn(&str) -> String) -> crate::dns::RecordInput {
        crate::dns::RecordInput {
            zone: get("zone"),
            kind: get("record_type"),
            name: get("name"),
            contents: get("content").split(';').map(str::to_string).collect(),
            ttl: get("ttl").parse().unwrap_or(0),
            ptr: get("ptr") == "1",
        }
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
        let mut list = crate::shared::pdns_conf::secondaries(&s)?;
        // What: sent address, else stored, else peer IP.
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
        save_secondaries(&app, &list).await?;
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
        fs::delete_if_present(&file).map_err(|e| format!("{}: {e}", file.display()))?;
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
        let mut list = crate::shared::pdns_conf::secondaries(&s)?;
        let Some(at) = list.iter().position(|(n, _)| *n == name) else {
            return Err(Fail(StatusCode::NOT_FOUND, tr("err_no_secondary")));
        };
        match op {
            SecondaryOp::Remove => {
                let (_, address) = list.remove(at);
                // What: the name leaves both NS lists too.
                // Why: new same-name secondary starts new.
                // From: Issue #1683 | PR #2017
                let mut form = ns_change(&s, &name, None)?;
                let rows = crate::shared::pdns_conf::secondary_rows(&list);
                form.insert("DNS_SECONDARIES".into(), rows);
                commit(&app, form).await?;
                delete_peer_records(&app.settings(), &name, &address).await?;
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
                commit_with(&app, |s| ns_change(s, &name, Some(true)))
                    .await
                    .map_err(bad_request)?;
                Ok(StatusCode::NO_CONTENT.into_response())
            }
            SecondaryOp::NsRemove => {
                commit_with(&app, |s| ns_change(s, &name, Some(false)))
                    .await
                    .map_err(bad_request)?;
                Ok(StatusCode::NO_CONTENT.into_response())
            }
            SecondaryOp::Rotate => {
                Ok(axum::Json(json!({"token": renew_token(&s)?})).into_response())
            }
            SecondaryOp::Address => {
                let axum::Json(a) = axum::Json::<Address>::from_bytes(&body)
                    .map_err(|_| bad_request(tr("err_address_body")))?;
                if !crate::shared::dns::is_ip(&a.address) {
                    return Err(bad_request(tr("err_no_ip")));
                }
                // What: a new address drops old records.
                // Why: same address: no save/ensure runs.
                // From: Issue #1683 | PR #2020
                if list[at].1 != a.address {
                    delete_peer_records(&s, &name, &list[at].1)
                        .await
                        .map_err(bad_request)?;
                }
                list[at].1 = a.address;
                save_secondaries(&app, &list).await.map_err(bad_request)?;
                Ok(StatusCode::NO_CONTENT.into_response())
            }
            SecondaryOp::Health => {
                Ok(axum::Json(secondary_health(&s, &list[at].1).await).into_response())
            }
        }
    }

    // What: zone serial overview with the page label.
    // Why: the page shows a translated primary column.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn zone_overview(State(app): Shared) -> Page {
        let mut v = crate::dns::zone_overview(&app.settings()).await?;
        v["columns"][0]["name"] = json!(tr("zone_col_primary"));
        Ok(axum::Json(v).into_response())
    }

    // What: DHCP page.
    // Why: mode, proxy, relay and live Kea data.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn dhcp(State(app): Shared, Extension(csrf): Extension<Csrf>) -> Page {
        let s = app.settings();
        let mode = s.text("DHCP_MODE")?;
        let mut ctx = Context::new();
        ctx.insert("dhcp_mode", &mode);
        ctx.insert("dhcp_modes", &s.list("DHCP_MODES")?);
        let kind = DhcpMode::from_word(&mode)?;
        ctx.insert("dhcp_has_kea", &(kind == DhcpMode::Kea));
        ctx.insert("dhcp_is_dnsmasq", &kind.is_dnsmasq());
        ctx.insert("dhcp_is_relay", &(kind == DhcpMode::DnsmasqRelay));
        ctx.insert("dhcp_ddns_enabled", &s.flag("DHCP_DDNS")?);
        // What: form values the dhcp page shows.
        // Why: Tera stops on any missing variable.
        // From: Issue #1683 | PR #1980
        let opt = |k: &str| s.text_or_empty(k);
        let dns = s.list("DHCP_DNS_SERVERS")?;
        ctx.insert("dhcp_dns_primary", dns.first().map_or("", String::as_str));
        ctx.insert("dhcp_dns_secondary", dns.get(1).map_or("", String::as_str));
        ctx.insert("default_lease_time", &opt("DHCP_LEASE_TIME"));
        ctx.insert("dhcp_domain", &opt("DHCP_DOMAIN"));
        // What: LAN domains for the subnet domain dropdown.
        // Why: a subnet may only use a domain DNS serves.
        // From: Issue #1683 | PR #2020
        let lan_names: Vec<String> = crate::shared::dns::lan_domains(&s)?
            .iter()
            .map(|z| crate::shared::dns::bare_zone(z).to_string())
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
        // What: hint shows only when own NTP is handed out
        // Why: one rule with the Kea and dnsmasq render.
        // From: Issue #1683 | PR #2020
        ctx.insert("ntp_auto_dhcp_active", &crate::shared::dhcp::own_ntp(&s)?);
        let codes: Vec<u8> = crate::shared::dhcp::MANAGED
            .iter()
            .map(|m| m.code)
            .collect();
        ctx.insert("kea_managed_codes", &codes);
        ctx.insert("dnsmasq_managed_codes", &codes);
        ctx.insert("option_code_min", &1);
        ctx.insert("option_code_max", &(u8::MAX - 1));
        // What: a Kea error is logged and kept as hint.
        // Why: empty lists alone would hide a dead Kea.
        // From: Issue #1683 | PR #2020
        let state = match kea_state(&s).await {
            Ok(v) => v.unwrap_or_else(|| json!({})),
            Err(e) => {
                eprintln!("ui: dhcp page: {e}");
                ctx.insert("kea_error", &e);
                json!({})
            }
        };
        for key in ["subnets", "reservations", "leases"] {
            let rows = state[key].as_array().cloned().unwrap_or_default();
            ctx.insert(key, &rows);
        }
        ctx.insert("kea_snapshots", &kea_store(&s)?.rows()?);
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
        // From: Issue #1683 | PR #2020
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
            other => match kea_edit_of(other, &get) {
                Ok(edit) => kea_change(&app, &s, &edit).await.map_err(|e| say(&e)),
                Err(e) => Err(e),
            },
        };
        // What: Kea changes keep the state.
        // Why: settings changes keep it in commit_with.
        // From: Issue #1683 | PR #2020
        let kea = !matches!(
            op,
            DhcpOp::Mode | DhcpOp::Ddns | DhcpOp::Proxy | DhcpOp::Relay
        );
        if result.is_ok() && kea {
            crate::stack::state_after(&app.settings()).await;
        }
        finish(result, &s.text("UI_PAGE_DHCP")?)
    }

    // What: subnet fields of a DHCP page form.
    // Why: form field names stay in the ui.
    // From: Issue #1683 | PR #2020
    fn subnet_input(get: &dyn Fn(&str) -> String) -> crate::dhcp::SubnetInput {
        crate::dhcp::SubnetInput {
            subnet: get("subnet"),
            gateway: get("gateway"),
            dns: dns_pair(get("dns_primary"), get("dns_secondary")),
            domain: get("domain"),
            ntp_servers: get("ntp_servers"),
            pool_start: get("pool_start"),
            pool_end: get("pool_end"),
            lease_time: get("lease_time"),
            lease: None,
        }
    }

    // What: the Kea change one DHCP form asks for.
    // Why: page, REST and CLI post the same fields.
    // From: Issue #1683 | PR #2020
    fn kea_edit_of(
        op: DhcpOp,
        get: &dyn Fn(&str) -> String,
    ) -> Result<crate::dhcp::KeaEdit, String> {
        use crate::dhcp::KeaEdit;
        let num = |k: &str| {
            get(k)
                .parse::<u64>()
                .map_err(|_| format!("{k} must be a number"))
        };
        let code = || crate::shared::dhcp::option_code(&get("code"));
        let host = |add: bool| -> Result<KeaEdit, String> {
            Ok(KeaEdit::Static {
                subnet: num("subnet_id")?,
                mac: get("mac"),
                ip: get("ip"),
                host: get("hostname"),
                add,
            })
        };
        Ok(match op {
            DhcpOp::SubnetAdd => KeaEdit::SubnetAdd(subnet_input(get)),
            DhcpOp::SubnetUpdate => KeaEdit::SubnetUpdate(num("id")?, subnet_input(get)),
            DhcpOp::SubnetRemove => KeaEdit::SubnetRemove(num("id")?),
            DhcpOp::SubnetOptionAdd => KeaEdit::Option {
                subnet: num("subnet_id")?,
                code: code()?,
                data: Some(get("data")),
            },
            DhcpOp::SubnetOptionRemove => KeaEdit::Option {
                subnet: num("subnet_id")?,
                code: code()?,
                data: None,
            },
            DhcpOp::StaticAdd => host(true)?,
            DhcpOp::StaticRemove => host(false)?,
            DhcpOp::LeaseRelease => KeaEdit::LeaseRelease(get("ip")),
            DhcpOp::KeaRollback => KeaEdit::Rollback(get("snapshot_id")),
            other => return Err(tr("err_unknown_dhcp_action").replace("{op}", other.key())),
        })
    }

    // What: SOT keys of the proxy and relay forms.
    // Why: field dhcp_x maps to key DHCP_X.
    // From: Issue #1683 | PR #1980
    pub(crate) fn dnsmasq_fields(form: &Fields, proxy: bool) -> Fields {
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
            let get = |k: &str| field(form, k);
            let dns = dns_pair(get("dhcp_dns_primary"), get("dhcp_dns_secondary"));
            out.insert("DHCP_DNS_SERVERS".into(), crate::config::join_items(&dns));
        }
        out
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
        // From: Issue #1683 | PR #2020
        let off = crate::shared::dhcp::off_service(&s)?.unwrap_or_default();
        for c in s.list("STATS_CONTAINERS")? {
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
        ctx.insert("ranges", &s.list("STATS_RANGES")?);
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
    pub(crate) async fn save_row(
        s: &Settings,
        graph: crate::shared::rrd::Graph,
        row: Vec<String>,
    ) -> Result<(), String> {
        let s = s.clone();
        let put = move || crate::shared::rrd::save_row(&s, &graph, &row);
        tokio::task::spawn_blocking(put)
            .await
            .map_err(|e| e.to_string())?
    }

    // What: Docker stats of each container into RRD.
    // Why: values per container, not only the box.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn sample_containers(app: &Stack, s: &Settings) -> Vec<String> {
        let all = match crate::shared::rrd::container_graphs(s) {
            Ok(v) => v,
            Err(e) => return vec![e],
        };
        let limit = match app.limits(s) {
            Ok((_, l)) => l,
            Err(e) => return vec![e],
        };
        let tabs = match s.list("STATS_CONTAINERS") {
            Ok(t) => t,
            Err(e) => return vec![e],
        };
        let mut errs = Vec::new();
        for tab in tabs {
            let got = match container_of(app, s, &tab).await {
                Ok(name) => app
                    .docker
                    .stats(&name, limit)
                    .await
                    .map_err(|e| e.to_string()),
                Err(e) => Err(say(&e)),
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
                errs.extend(save_row(s, g.clone(), vals).await.err());
            }
        }
        errs
    }

    // What: program values one sample round reads.
    // Why: a source that fails is unknown and reported.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn service_values(
        app: &Stack,
        s: &Settings,
        want: &[String],
    ) -> (BTreeMap<String, String>, Vec<String>) {
        let mut out = BTreeMap::new();
        let mut errs = Vec::new();
        let has = |p: &str| want.iter().any(|w| w.split(':').next() == Some(p));
        let mut note = |src: &str, e: String| errs.push(format!("{src}: {e}"));
        if has("nginx") {
            match crate::shared::nginx_conf::live(s).await {
                Ok(v) => {
                    for k in ["active", "requests", "waiting"] {
                        out.insert(format!("nginx:{k}"), v[k].to_string());
                    }
                }
                Err(e) => note("nginx", e),
            }
        }
        if has("recursor") {
            match peer::recursor_apis(s) {
                Ok(apis) => {
                    for r in apis {
                        match r.statistics().await {
                            Ok(rows) => {
                                crate::shared::pdns::Api::add_stats(&mut out, "recursor", rows)
                            }
                            Err(e) => note("recursor", e),
                        }
                    }
                }
                Err(e) => note("recursor", e),
            }
        }
        if has("auth") {
            let rows = match peer::own_api(s) {
                Ok(api) => api.statistics().await,
                Err(e) => Err(e),
            };
            match rows {
                Ok(rows) => crate::shared::pdns::Api::add_stats(&mut out, "auth", rows),
                Err(e) => note("auth", e),
            }
        }
        // What: no Kea in another DHCP mode is no error.
        // Why: kea_stats answers None outside Kea mode.
        // From: Issue #1683 | PR #2020
        if has("kea") {
            match crate::dhcp::kea_stats(s).await {
                Ok(Some(map)) => {
                    for (k, n) in map {
                        out.insert(format!("kea:{k}"), n.to_string());
                    }
                }
                Ok(None) => {}
                Err(e) => note("kea", e),
            }
        }

        // What: host network bytes from the host's net/dev.
        // Why: in mode off no dhcp container gives it.
        // From: Issue #1683 | PR #1980
        if has("host") {
            let read = s.text("HOST_NET_DEV_FILE").and_then(|file| {
                let text = fs::read_text(Path::new(&file))?;
                Ok((text, s.list("STATS_HOST_IF_SKIP")?))
            });
            match read {
                Ok((text, skip)) => {
                    let (rx, tx) = crate::shared::rrd::host_net(&text, &skip);
                    out.insert("host:rx".into(), rx.to_string());
                    out.insert("host:tx".into(), tx.to_string());
                }
                Err(e) => note("host", e),
            }
        }

        // What: stratum and offset of the time source.
        // Why: the graph reads the tracking reader.
        // From: Issue #1683 | PR #1980
        if has("chrony") {
            match chrony_tracking(app, s).await {
                Ok(v) => {
                    out.insert("chrony:stratum".into(), v["stratum"].to_string());
                    out.insert("chrony:offset".into(), v["system_time"].to_string());
                }
                Err(e) => note("chrony", e),
            }
        }
        (out, errs)
    }

    // What: chrony tracking from its container.
    // Why: sampler and REST run one command, one parser.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn chrony_tracking(app: &Stack, s: &Settings) -> Result<Value, String> {
        let (cmd, code, text) = crate::stack::exec_row(app, s, "CHRONY_TRACKING_EXEC").await?;
        if code != 0 {
            return Err(format!("{} exit {code}: {}", cmd.join(" "), text.trim()));
        }
        crate::shared::ntp::tracking(&text)
    }

    // What: GET UI_ROUTE_DNS_SOA_PROBE?zone=&target=
    // Why: REST reads what the CLI reads.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn dns_soa_api(
        State(app): Shared,
        axum::extract::Query(q): axum::extract::Query<Fields>,
    ) -> Page {
        let target = q.get("target").map_or("auth", String::as_str);
        let zone = field(&q, "zone");
        let v = crate::dns::soa_probe(&app.settings(), &zone, target)
            .await
            .map_err(bad_request)?;
        Ok(axum::Json(v).into_response())
    }

    // What: GET UI_ROUTE_DNS_TSIG: key state.
    // Why: REST reads what the CLI reads.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn dns_tsig_api(State(app): Shared) -> Page {
        Ok(axum::Json(crate::dns::tsig_state(&app.settings()).await?).into_response())
    }

    // What: GET UI_ROUTE_DNS_RECORDS: LAN records.
    // Why: REST reads what page and CLI read.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn dns_records_api(State(app): Shared) -> Page {
        Ok(axum::Json(crate::dns::lan_view(&app.settings()).await?).into_response())
    }

    // What: GET UI_ROUTE_NTP_TRACKING: chrony state.
    // Why: REST and CLI read the tracking reader.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn ntp_tracking_api(State(app): Shared) -> Response {
        let r = chrony_tracking(&app, &app.settings()).await;
        json_reply(r.map(Some), "")
    }

    // What: GET UI_ROUTE_SYSTEM_TIME: the services clock.
    // Why: the window runs there; REST runs its CLI.
    // From: Issue #871 | PR #2020
    pub(crate) async fn system_time_api(State(app): Shared) -> Response {
        let s = app.settings();
        let r = async {
            let (cmd, code, text) = crate::stack::exec_row(&app, &s, "SYSTEM_TIME_EXEC").await?;
            let v =
                crate::stack::last_json(&text).map_err(|e| format!("{}: {e}", cmd.join(" ")))?;
            match code {
                0 => Ok(v),
                code => Err(format!("{} exit {code}: {v}", cmd.join(" "))),
            }
        };
        json_reply(r.await.map(Some), "")
    }

    // What: program values into RRD each step.
    // Why: PowerDNS, nginx, Kea and chrony give values.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn sample_services(app: &Stack, s: &Settings) -> Vec<String> {
        let all = match crate::shared::rrd::service_graphs(s) {
            Ok(v) => v,
            Err(e) => return vec![e],
        };
        let want: Vec<String> = all
            .iter()
            .flat_map(|g| g.sources.iter().map(|x| x.oid.clone()))
            .collect();
        let (vals, mut errs) = service_values(app, s, &want).await;
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
            errs.extend(save_row(s, g, row).await.err());
        }
        errs
    }

    // What: one sample round: SNMP, containers, programs.
    // Why: the loop and a sample on demand run it alike.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn sample_round(app: &Stack, s: &Settings) -> Vec<String> {
        let c = s.clone();
        let mut errs = match tokio::task::spawn_blocking(move || sample_all(&c)).await {
            Ok(list) => list,
            Err(e) => vec![e.to_string()],
        };
        errs.extend(sample_containers(app, s).await);
        errs.extend(sample_services(app, s).await);
        errs
    }

    // What: POST one sample round; answers its errors.
    // Why: CLI and REST record now, not at the next step.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn stats_sample_api(
        State(app): Shared,
        Extension(csrf): Extension<Csrf>,
        headers: HeaderMap,
    ) -> Page {
        csrf.check_header(&headers)?;
        let errs = sample_round(&app, &app.settings()).await;
        Ok(axum::Json(json!({"errors": errs})).into_response())
    }

    // What: GET UI_ROUTE_STATS_SNMP_CHECK: one SNMP query.
    // Why: REST asks what the CLI snmp-check asks.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn stats_snmp_check_api(State(app): Shared) -> Response {
        let s = app.settings();
        let asked = tokio::task::spawn_blocking(move || crate::shared::rrd::snmp_check(&s))
            .await
            .map_err(|e| e.to_string())
            .and_then(|r| r);
        json_reply(asked.map(Some), "")
    }

    // What: GET graph list with sources and files.
    // Why: REST read on the listing of the CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn stats_list_api(State(app): Shared) -> Response {
        json_reply(crate::shared::rrd::listing(&app.settings()).map(Some), "")
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
            for e in sample_round(&app, &s).await {
                eprintln!("ui: stats: {e}");
            }
            match stays_off(&app, &s).await {
                Ok(Some(done)) => eprintln!("ui: dhcp: {done}"),
                Ok(None) => {}
                Err(e) => eprintln!("ui: dhcp: {e}"),
            }
            tokio::time::sleep(Duration::from_secs(step)).await;
        }
    }

    // What: count the cache folder now and then.
    // Why: a walk is slow; dashboard reads the last sum.
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
            match tokio::task::spawn_blocking(move || {
                crate::shared::tidy::cache_bytes(Path::new(&dir))
            })
            .await
            {
                Ok((bytes, errs)) => {
                    for e in errs {
                        eprintln!("ui: cache count: not read: {e}");
                    }
                    app.cache_used.store(bytes, Ordering::Relaxed);
                }
                Err(e) => eprintln!("ui: cache count: {e}"),
            }
            tokio::time::sleep(Duration::from_secs(step)).await;
        }
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
        // What: the program is one bare name, never a path.
        // Why: the list is live; rc-service runs a path.
        // From: Issue #1683 | PR #2020
        let bare = crate::config::safe(crate::config::Syntax::Name("_-"), &program)
            && !program.starts_with('-');
        if !bare
            || !s
                .list("UI_SERVICES")?
                .contains(&format!("{container}:{program}"))
        {
            return Err(Fail(StatusCode::NOT_FOUND, tr("err_program_not_offered")));
        }
        // What: only a running program is touched.
        // Why: a restart must not start kea in dnsmasq mode
        // From: Issue #1683 | PR #1985
        let control = s.text("SERVICE_CONTROL_PROGRAM")?;
        let status = [control.as_str(), program.as_str(), "status"];
        let (code, _) = exec_in(&app, &s, &container, &status)
            .await
            .map_err(|e| Fail(StatusCode::BAD_GATEWAY, say(&e)))?;
        if code != 0 {
            return Err(Fail(StatusCode::CONFLICT, tr("err_program_not_running")));
        }
        let cmd = [control.as_str(), program.as_str(), action.as_str()];
        let (code, out) = exec_in(&app, &s, &container, &cmd)
            .await
            .map_err(|e| Fail(StatusCode::BAD_GATEWAY, say(&e)))?;
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
    pub(crate) async fn hamster(app: &Stack, args: &[&str]) -> Result<Value, String> {
        let s = app.settings();
        let program = s.text("CACHEHAMSTER_PROGRAM")?;
        let mut cmd = vec![program.as_str(), "cachehamster"];
        cmd.extend_from_slice(args);
        let (code, v) = exec_json(app, &s, &s.text("CACHEHAMSTER_SERVICE")?, &cmd)
            .await
            .map_err(|e| say(&e))?;
        if let Some(e) = v.get("error").and_then(Value::as_str) {
            // What: service text behind a translated lead.
            // Why: Steam details stay as the service wrote.
            // From: Issue #871 | PR #1980
            return Err(format!("{} {e}", tr("hamster_says")));
        }
        // What: a failed check still answers its JSON.
        // Why: REST shows which part failed.
        // From: Issue #871 | PR #2020
        if code != 0 && v.get("ok") != Some(&Value::Bool(false)) {
            return Err(tr("hamster_exit").replace("{x}", &code.to_string()));
        }
        Ok(v)
    }

    // What: GET UI_ROUTE_WATCHDOG_CHECK: checks now.
    // Why: REST runs the watchdog check in services.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn watchdog_check(State(app): Shared) -> Page {
        let s = app.settings();
        let program = s.text("SERVICES_PROGRAM")?;
        let cmd = [program.as_str(), "watchdog", "check"];
        let (_, v) = exec_json(&app, &s, &s.text("SERVICES_SERVICE")?, &cmd)
            .await
            .map_err(|e| Fail(StatusCode::BAD_GATEWAY, say(&e)))?;
        Ok(axum::Json(v).into_response())
    }

    // What: GET UI_ROUTE_WATCHDOG_PROCESSED: syslog count.
    // Why: REST asks services what the CLI asks there.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn watchdog_processed(State(app): Shared) -> Page {
        let s = app.settings();
        let program = s.text("SERVICES_PROGRAM")?;
        let cmd = [program.as_str(), "watchdog", "processed"];
        let (code, v) = exec_json(&app, &s, &s.text("SERVICES_SERVICE")?, &cmd)
            .await
            .map_err(|e| Fail(StatusCode::BAD_GATEWAY, say(&e)))?;
        if code != 0 {
            let why = v["error"].as_str().unwrap_or("syslog-ng did not answer");
            return Err(Fail(StatusCode::BAD_GATEWAY, why.to_string()));
        }
        Ok(axum::Json(v).into_response())
    }

    // What: POST UI_ROUTE_WATCHDOG_TIDY, ?dry_run=1.
    // Why: REST runs the watchdog step in services.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn watchdog_tidy(
        State(app): Shared,
        Extension(csrf): Extension<Csrf>,
        axum::extract::Path(op): axum::extract::Path<String>,
        axum::extract::Query(query): axum::extract::Query<Fields>,
        headers: HeaderMap,
    ) -> Page {
        csrf.check_header(&headers)?;
        if !crate::watchdog::TIDY_STEPS.contains(&op.as_str()) {
            return Err(Fail(StatusCode::NOT_FOUND, "no such step".into()));
        }
        let s = app.settings();
        let program = s.text("SERVICES_PROGRAM")?;
        let mut cmd = vec![program.as_str(), "watchdog", op.as_str()];
        if field(&query, "dry_run") == "1" {
            cmd.push("--dry-run");
        }
        let service = s.text("SERVICES_SERVICE")?;
        let (_, v) = exec_json(&app, &s, &service, &cmd)
            .await
            .map_err(|e| Fail(StatusCode::BAD_GATEWAY, say(&e)))?;
        Ok(axum::Json(v).into_response())
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
        crate::cachehamster::when_word(when, at).map_err(|_| bad_request(tr("err_time")))
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
        // Why: daemon protocol names commands, not paths.
        // From: Issue #871 | PR #1985
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
        axum::extract::Query(query): axum::extract::Query<Fields>,
        headers: HeaderMap,
    ) -> Page {
        csrf.check_header(&headers)?;
        let url = field(&query, "url");
        // What: lookup-ID and evict-ID carry one app id.
        // Why: the library row checks or frees one game.
        // From: Issue #871 | PR #1991
        let args: Vec<&str> = match op.split_once('-') {
            Some((cmd, id)) if rest_of(cmd) == Rest::AppId && id.parse::<u32>().is_ok() => {
                vec![cmd, id]
            }
            // What: fetch-check?url= probes one address.
            // Why: REST runs the CLI check of the owner.
            // From: Issue #871 | PR #2020
            _ if rest_of(&op) == Rest::Url && !url.is_empty() => vec![op.as_str(), &url],
            _ if rest_of(&op) == Rest::Plain => vec![op.as_str()],
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

    // What: rendered bodies of an owner or one path.
    // Why: shows a config before it is written.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn render_preview(s: &Settings, pick: Option<&str>) -> Result<Value, String> {
        let files = match render_now(s).await? {
            Ok(f) => f,
            Err(errors) => return Ok(json!({"errors": errors})),
        };
        let hide = crate::shared::secret::all_values(s)?;
        let mut list = Vec::new();
        for (f, state) in render::file_states(&files)? {
            let path = f.path.display().to_string();
            if pick.is_some_and(|p| p != f.owner && p != path) {
                continue;
            }
            // What: every secret value becomes <secret>.
            // Why: rendered files embed keys and tokens.
            // From: Issue #1683 | PR #2020
            let mut body = f.body.clone();
            for v in &hide {
                body = body.replace(v.as_str(), "<secret>");
            }
            list.push(json!({"path": path, "owner": f.owner, "state": state, "body": body}));
        }
        match pick {
            Some(p) if list.is_empty() => Err(format!("{p}: no rendered owner or file")),
            _ => Ok(json!({"files": list, "errors": []})),
        }
    }

    // What: GET UI_ROUTE_PROXY_CERTS: CA and leaves.
    // Why: REST reads what the CLI reads.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn certs_api(State(app): Shared) -> Page {
        Ok(axum::Json(render::cert_list(&app.settings())?).into_response())
    }

    // What: POST UI_ROUTE_PROXY_CERTS_RENEW.
    // Why: drop leaves near their end, issue, reload.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn certs_renew_api(
        State(app): Shared,
        Extension(csrf): Extension<Csrf>,
        headers: HeaderMap,
    ) -> Page {
        csrf.check_header(&headers)?;
        let s = app.settings();
        let dropped = render::delete_expiring(&s).map_err(bad_request)?;
        let report = say_all(&issue_and_reload(&app, &s).await?);
        let v = json!({"renewed": dropped, "report": report, "certs": render::cert_list(&s)?});
        Ok(axum::Json(v).into_response())
    }

    // What: GET UI_ROUTE_STACK_SNAPSHOTS: saved states.
    // Why: a restore picks one of them by id.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn stack_snapshots_api(State(app): Shared) -> Response {
        let rows = crate::stack::state_store(&app.settings()).and_then(|st| st.rows());
        json_reply(rows.map(|r| Some(json!({"snapshots": r}))), "")
    }

    // What: POST UI_ROUTE_STACK_SNAPSHOT_RESTORE id=...
    // Why: give back the whole state of one snapshot.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn stack_snapshot_restore_api(
        State(app): Shared,
        Extension(csrf): Extension<Csrf>,
        Form(form): Form<Fields>,
    ) -> Page {
        csrf.check(&form)?;
        let (ok, report) = crate::stack::state_restore(&app, &field(&form, "id"))
            .await
            .map_err(bad_request)?;
        Ok(axum::Json(json!({"ok": ok, "report": say_all(&report)})).into_response())
    }

    // What: POST UI_ROUTE_STACK_SNAPSHOT_SAVE.
    // Why: keep the state of now before a big change.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn stack_snapshot_save_api(
        State(app): Shared,
        Extension(csrf): Extension<Csrf>,
        headers: HeaderMap,
    ) -> Page {
        csrf.check_header(&headers)?;
        let id = crate::stack::state_save(&app.settings()).await?;
        Ok(axum::Json(json!({"id": id})).into_response())
    }

    // What: seconds as "4 h", "90 min" or "45 s".
    // Why: the page shows the SOT check times readably.
    // From: Issue #1683 | PR #2017
    pub(crate) fn duration_text(secs: u64) -> String {
        match secs {
            s if s >= 3600 && s % 3600 == 0 => format!("{} h", s / 3600),
            s if s >= 60 && s % 60 == 0 => format!("{} min", s / 60),
            s => format!("{s} s"),
        }
    }

    // What: POST zones ensure: the apply with zones.
    // Why: the same way a save makes its zones ready.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn zones_ensure_api(
        State(app): Shared,
        Extension(csrf): Extension<Csrf>,
        headers: HeaderMap,
    ) -> Page {
        csrf.check_header(&headers)?;
        let s = app.settings();
        let lines = apply_all(&app, &s, &s, true)
            .await
            .map_err(|e| Fail(StatusCode::BAD_GATEWAY, e))?;
        Ok(axum::Json(json!({"report": say_all(&lines)})).into_response())
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
                    match apply_all(&app, &s, &s, false).await {
                        Ok(lines) => say_all(&lines)
                            .iter()
                            .for_each(|l| eprintln!("ui: start: {l}")),
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

    // What: bytes of a whole GiB number.
    // Why: cache sizes are whole GiB only.
    // From: Issue #1683 | PR #1980
    pub(crate) fn gib_bytes(text: &str) -> Result<u64, String> {
        let n: u64 = text
            .trim()
            .parse()
            .map_err(|_| tr("err_no_gib").replace("{x}", text))?;
        crate::shared::human::gib_bytes(n).ok_or_else(|| format!("{text:?} is too big"))
    }

    // What: refuse a bigger cache without room.
    // Why: growth must fit the free disk space.
    // From: Issue #1069 | PR #1983
    pub(crate) fn cache_room(s: &Settings, form: &Fields, cached: u64) -> Result<(), Fail> {
        let Some(wanted) = form.get("CACHE_MAX_GB") else {
            return Ok(());
        };
        let new = gib_bytes(wanted).map_err(bad_request)?;
        let old = gib_bytes(&s.text("CACHE_MAX_GB")?)?;
        if new <= old {
            return Ok(());
        }
        let reachable = crate::shared::tidy::reachable(s, old, cached)?;
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

    // What: the watchdog alarm report as JSON.
    // Why: REST diagnosis on the reader of ui and CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn alarms(State(app): Shared) -> Response {
        let report = crate::watchdog::report(&app.settings());
        json_reply(report, "no alarm report written yet")
    }

    // What: Kea subnets, reservations and leases as JSON.
    // Why: REST diagnosis on the reader of page and CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn dhcp_state(State(app): Shared) -> Response {
        json_reply(kea_state(&app.settings()).await, crate::dhcp::NOT_KEA)
    }

    // What: zone snapshots as JSON, as setup.sh reads them.
    // Why: REST diagnosis on the reader of page and CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn zone_snapshots_api(State(app): Shared) -> Response {
        json_reply(zone_snapshots(&app.settings()).map(Some), "")
    }

    // What: cache use as JSON; counted by the scanner.
    // Why: REST diagnosis on the reader of page and CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn cache_api(State(app): Shared) -> Response {
        let used = app.cache_used.load(Ordering::Relaxed);
        let r = crate::shared::tidy::usage(&app.settings(), (used != u64::MAX).then_some(used));
        json_reply(r.map(Some), "")
    }

    // What: secret file states as JSON, no values.
    // Why: REST diagnosis on the reader of the CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn secrets_api(State(app): Shared) -> Response {
        json_reply(secret::states(&app.settings()).map(Some), "")
    }

    // What: own NTP status as JSON.
    // Why: REST diagnosis on the reader of pages and CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn ntp_api(State(app): Shared) -> Response {
        let r = crate::shared::ntp::status(&app.settings()).await;
        json_reply(r.map(Some), "")
    }

    // What: proxy log totals and newest requests, JSON.
    // Why: REST diagnosis on the reader of page and CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn proxy_log_api(State(app): Shared) -> Response {
        let r = crate::shared::access::summary(&app.settings()).await;
        json_reply(r.map(Some), "")
    }

    // What: nginx stub_status numbers as JSON.
    // Why: REST diagnosis on the reader of page and CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn proxy_status_api(State(app): Shared) -> Response {
        let r = crate::shared::nginx_conf::live(&app.settings()).await;
        json_reply(r.map(Some), "")
    }

    // What: Kea counters as JSON.
    // Why: REST diagnosis on the reader of graphs and CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn dhcp_stats_api(State(app): Shared) -> Response {
        let r = crate::dhcp::kea_stats(&app.settings()).await;
        json_reply(r.map(|o| o.map(|m| json!(m))), crate::dhcp::NOT_KEA)
    }

    // What: Kea config snapshots as JSON.
    // Why: REST diagnosis on the reader of page and CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn kea_snapshots_api(State(app): Shared) -> Response {
        json_reply(kea_snapshots(&app.settings()).map(Some), "")
    }

    // What: the masked settings view and load warnings.
    // Why: REST diagnosis on the reader of pages and CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn settings_api(State(app): Shared) -> Response {
        json_reply(Ok(Some(app.settings().view_json())), "")
    }

    // What: 200 value, 503 not available, 500 error.
    // Why: every REST reader answers the same way.
    // From: Issue #1683 | PR #2020
    fn json_reply(r: Result<Option<Value>, String>, none: &str) -> Response {
        match r {
            Ok(Some(v)) => axum::Json(v).into_response(),
            Ok(None) => (
                StatusCode::SERVICE_UNAVAILABLE,
                axum::Json(json!({"error": none})),
            )
                .into_response(),
            Err(e) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                axum::Json(json!({"error": e})),
            )
                .into_response(),
        }
    }

    // What: container states for the beambar.
    // Why: Docker is the source; no status files.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn status(State(app): Shared) -> Response {
        axum::Json(docker::status_json(&app.docker, &app.settings()).await).into_response()
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
        let Some(wish) = docker::Wish::from_word(&want.state) else {
            return Err(bad_request(tr("err_state_running_stopped")));
        };
        set_wanted(&app, &service, wish.runs())
            .await
            .map_err(|e| Fail(StatusCode::BAD_GATEWAY, say(&e)))?;
        Ok(StatusCode::NO_CONTENT.into_response())
    }

    // What: restart the ui container itself.
    // Why: Docker restarts it; the page reloads.
    // From: Issue #1683 | PR #1980
    pub(crate) async fn restart_ui(
        State(app): Shared,
        Extension(csrf): Extension<Csrf>,
        headers: HeaderMap,
    ) -> Page {
        csrf.check_header(&headers)?;
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
    // Why: a failed start render must show as unhealthy.
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
    // From: Issue #1683 | PR #2020
    pub(crate) fn env_form(phc: &str) -> String {
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(phc)
    }

    // What: one line from stdin without its line end.
    // Why: both setup.sh commands read their input so.
    // From: Issue #1683 | PR #2020
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
    // From: Issue #1683 | PR #2020
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
        let image = config::image();
        for (func, value) in [
            ("lancache_image_registry", image.registry),
            ("lancache_image_prefix", image.prefix),
            ("lancache_image_tag", image.tag),
            ("lancache_image_channel", image.channel),
        ] {
            t.register_function(func, move |_: tera::Kwargs, _: &tera::State| value.clone());
        }
    }

    // What: compile every mounted template.
    // Why: start and check read one loader.
    // From: Issue #1683 | PR #2020
    pub(crate) fn compile(dir: &str) -> Result<(Tera, Vec<String>, Vec<String>), String> {
        let mut t = Tera::default();
        t.autoescape_on(vec!["html"]);
        register_image_functions(&mut t);
        // What: Tera 1 filter cachehamster.html uses.
        // Why: Tera 2 lacks filesizeformat; one byte format
        // From: Issue #1683 | PR #1980
        t.register_filter(
            "filesizeformat",
            |v: u64, _: tera::Kwargs, _: &tera::State| human::bytes(v),
        );
        let (mut names, mut errors) = (Vec::new(), Vec::new());
        for (name, body) in folder(dir, "html")? {
            if let Err(e) = t.add_raw_template(&name, &body) {
                errors.push(format!("template {name}: {e}"));
            }
            names.push(name);
        }
        Ok((t, names, errors))
    }

    // What: compile the mounted templates at start.
    // Why: a broken template stops the start.
    // From: Issue #1683 | PR #1991
    pub(crate) fn templates(dir: &str) -> Result<Tera, String> {
        let (t, _, errors) = compile(dir)?;
        match errors.is_empty() {
            true => Ok(t),
            false => Err(errors.join("; ")),
        }
    }

    // What: short names after routes. or pages.
    // Why: a name without SOT key fails on render.
    // From: Issue #1683 | PR #2020
    fn short_names<'a>(body: &'a str, prefix: &str) -> Vec<&'a str> {
        let word = |c: char| c.is_ascii_alphanumeric() || c == '_';
        let mut out = Vec::new();
        for (at, _) in body.match_indices(prefix) {
            if body[..at].chars().next_back().is_some_and(word) {
                continue;
            }
            let rest = &body[at + prefix.len()..];
            let end = rest.find(|c: char| !word(c)).unwrap_or(rest.len());
            if end > 0 {
                out.push(&rest[..end]);
            }
        }
        out
    }

    // What: template check: parse and SOT names.
    // Why: CLI and REST see what breaks a page.
    // From: Issue #1683 | PR #2020
    pub(crate) fn template_report(s: &Settings) -> Result<Value, String> {
        let dir = s.text("TEMPLATE_DIR")?;
        let (_, names, errors) = compile(&dir)?;
        let keys: std::collections::BTreeSet<&String> = s.texts().map(|(k, _)| k).collect();
        let mut unknown = std::collections::BTreeSet::new();
        for (name, body) in folder(&dir, "html")? {
            for (prefix, sot) in [("routes.", "UI_ROUTE_"), ("pages.", "UI_PAGE_")] {
                for n in short_names(&body, prefix) {
                    let key = format!("{sot}{}", n.to_ascii_uppercase());
                    if !keys.contains(&key) {
                        unknown.insert(format!("{name}: {prefix}{n} ({key})"));
                    }
                }
            }
        }
        let ok = errors.is_empty() && unknown.is_empty();
        Ok(json!({"dir": dir, "templates": names, "errors": errors,
            "unknown_names": unknown, "ok": ok}))
    }

    // What: the English texts built into the binary.
    // Why: English is the fallback; the ui always starts.
    // From: Issue #1683 | PR #2020
    const BUILT_IN_EN: &str = include_str!("../../ui/src/lang/en.json");

    // What: texts at start; English fills every gap.
    // Why: a missing folder or key must not stop the ui.
    // From: Issue #1683 | PR #2020
    pub(crate) fn texts(dir: &str) -> Result<Texts, String> {
        let mut base = parse_built_in()?;
        let mut all = match lang_files(dir) {
            Ok(files) => files,
            Err(e) => {
                eprintln!("ui: lang: {e}; using the built-in English texts");
                Texts::new()
            }
        };
        let report = lang_report(&all);
        if report["equal"] != json!(true) {
            eprintln!(
                "ui: lang: English fills missing keys: {}",
                report["missing"]
            );
        }
        if let Some(en) = all.get(FALLBACK_LANG) {
            base.extend(en.clone());
        }
        for map in all.values_mut() {
            for (k, v) in &base {
                map.entry(k.clone()).or_insert_with(|| v.clone());
            }
        }
        all.insert(FALLBACK_LANG.to_string(), base);
        Ok(all)
    }

    // What: key check of the language files on disk.
    // Why: CLI and REST report what English fills.
    // From: Issue #1683 | PR #2020
    pub(crate) fn lang_check(s: &Settings) -> Result<Value, String> {
        let mut v = lang_report(&lang_files(&s.text("LANG_DIR")?)?);
        v["fallback"] = json!(FALLBACK_LANG);
        Ok(v)
    }

    // What: every language file, parsed.
    // Why: start and the lang check read the same files.
    // From: Issue #1683 | PR #2020
    pub(crate) fn lang_files(dir: &str) -> Result<Texts, String> {
        let mut all = Texts::new();
        for (name, body) in folder(dir, "json")? {
            let code = name.trim_end_matches(".json").to_string();
            let map: BTreeMap<String, String> =
                serde_json::from_str(&body).map_err(|e| format!("lang {code}: {e}"))?;
            all.insert(code, map);
        }
        Ok(all)
    }

    // What: languages, key counts, missing keys each.
    // Why: names the key a page would show raw.
    // From: Issue #1683 | PR #2020
    pub(crate) fn lang_report(all: &Texts) -> Value {
        let union: std::collections::BTreeSet<&String> =
            all.values().flat_map(|m| m.keys()).collect();
        let mut missing = serde_json::Map::new();
        let mut langs = Vec::new();
        for (code, map) in all {
            let gone: Vec<&&String> = union.iter().filter(|k| !map.contains_key(**k)).collect();
            if !gone.is_empty() {
                missing.insert(code.clone(), json!(gone));
            }
            langs.push(json!({"lang": code, "keys": map.len()}));
        }
        json!({"languages": langs, "keys": union.len(), "equal": missing.is_empty(), "missing": missing})
    }

    // What: GET language report of the loaded files.
    // Why: REST read on the check of the CLI.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn lang_api(State(app): Shared) -> Response {
        json_reply(lang_check(&app.settings()).map(Some), "")
    }

    // What: language of one request.
    // Why: cookie first, then the browser, then the SOT.
    // From: Issue #1683 | PR #1980
    pub(crate) fn pick_lang(app: &Stack, headers: &HeaderMap) -> String {
        let known = |c: &str| all_texts().contains_key(c);
        let picked = app.settings().text("UI_LANG_COOKIE").ok();
        if let Some(c) = picked
            .and_then(|name| cookie(headers, &name))
            .filter(|c| known(c))
        {
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
        // What: the SOT default if loaded, else English.
        // Why: a page in an unloaded language has no texts.
        // From: Issue #1683 | PR #2020
        Some(app.settings().text_or_empty("UI_LANG_DEFAULT"))
            .filter(|c| known(c))
            .unwrap_or_else(|| FALLBACK_LANG.to_string())
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

    // What: makes an enum of route keys with ALL and key().
    // Why: router and handlers read one list per enum.
    // From: Issue #1683 | PR #2019
    macro_rules! route_ops {
    ($name:ident { $($var:ident => $key:literal),+ $(,)? }) => {
        #[derive(Clone, Copy)]
        pub(crate) enum $name { $($var),+ }
        impl $name {
            pub(crate) const ALL: &'static [$name] = &[$($name::$var),+];
            pub(crate) fn key(self) -> &'static str {
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
    pub(crate) async fn command(
        s: &Settings,
        set: Option<Set>,
        args: &[String],
    ) -> Option<Result<(), String>> {
        match set {
            Some(Set::ZoneSnapshots) => Some(zone_snapshots(s).map(|v| println!("{v}"))),
            // What: registration token as ui resolves it.
            // Why: CI reads token the register API checks.
            // From: Issue #1683 | PR #2020
            Some(Set::RegistrationToken) => Some(registration_token(s).map(|t| println!("{t}"))),
            // What: language files on disk, key check.
            // Why: a missing key would show raw on a page.
            // From: Issue #1683 | PR #2020
            Some(Set::Lang) => Some(lang_check(s).and_then(|v| {
                println!("{v}");
                match v["equal"].as_bool() {
                    Some(true) => Ok(()),
                    _ => Err("lang: the files differ; English fills the gaps".into()),
                }
            })),
            // What: route list and template check.
            // Why: the router's table, the start's loader.
            // From: Issue #1683 | PR #2020
            Some(Set::Routes) => Some(route_list(s).map(|v| println!("{v}"))),
            // What: change the password through the ui.
            // Why: stdin keeps it out of the process list.
            // From: Issue #1683 | PR #2020
            Some(Set::Password) => Some(password_cli(s, args.get(1)).await),
            Some(Set::Templates) => Some(template_report(s).and_then(|v| {
                println!("{v}");
                match v["ok"].as_bool() {
                    Some(true) => Ok(()),
                    _ => Err("templates: errors or unknown names".into()),
                }
            })),
            Some(Set::ZoneRollback) => Some(match &args[1..] {
                [zone, id] => rollback(s, zone, id).await.map_err(|e| say(&e)).map(|()| {
                    println!("{}", json!({"restored": zone, "snapshot": id}));
                }),
                _ => Err(crate::shared::cli::usage(&COMMANDS, |c| {
                    *c == Cmd::Set(Set::ZoneRollback)
                })),
            }),
            Some(Set::Healthcheck) => Some(healthcheck(s).await),
            // What: one DHCP probe as JSON on stdout.
            // Why: setup.sh and the DHCP page run it.
            // From: Issue #1683 | PR #1985
            Some(Set::DhcpProbe) => Some(probe_cli(s)),
            None => None,
        }
    }

    // What: what a command without settings does.
    // Why: they run before any settings are read.
    // From: Issue #1683 | PR #2020
    #[derive(Clone, Copy, PartialEq)]
    enum Cmd {
        HashPassword,
        EncodePasswordHash,
        Set(Set),
    }

    // What: what a command with settings does.
    // Why: command() matches these, the table names them.
    // From: Issue #1683 | PR #2020
    #[derive(Clone, Copy, PartialEq)]
    pub(crate) enum Set {
        ZoneSnapshots,
        RegistrationToken,
        Lang,
        Routes,
        Templates,
        Password,
        ZoneRollback,
        Healthcheck,
        DhcpProbe,
    }

    // What: every command of ui role; none = the server.
    // Why: help, errors and the choice read this table.
    // From: Issue #1683 | PR #2020
    const COMMANDS: [(&str, crate::shared::cli::Entry<Cmd>); 11] = [
        (
            "hash-password",
            crate::shared::cli::row(Cmd::HashPassword, "hash-password"),
        ),
        (
            "encode-password-hash",
            crate::shared::cli::row(Cmd::EncodePasswordHash, "encode-password-hash"),
        ),
        (
            "zone-snapshots",
            crate::shared::cli::row(Cmd::Set(Set::ZoneSnapshots), "zone-snapshots"),
        ),
        (
            "registration-token",
            crate::shared::cli::row(Cmd::Set(Set::RegistrationToken), "registration-token"),
        ),
        ("lang", crate::shared::cli::row(Cmd::Set(Set::Lang), "lang")),
        (
            "routes",
            crate::shared::cli::row(Cmd::Set(Set::Routes), "routes"),
        ),
        (
            "templates",
            crate::shared::cli::row(Cmd::Set(Set::Templates), "templates"),
        ),
        (
            "password",
            crate::shared::cli::row(Cmd::Set(Set::Password), "password [user]"),
        ),
        (
            "zone-rollback",
            crate::shared::cli::row(
                Cmd::Set(Set::ZoneRollback),
                "zone-rollback <zone> <snapshot-id>",
            ),
        ),
        (
            "healthcheck",
            crate::shared::cli::row(Cmd::Set(Set::Healthcheck), "healthcheck"),
        ),
        (
            DHCP_PROBE_CMD,
            crate::shared::cli::row(Cmd::Set(Set::DhcpProbe), DHCP_PROBE_CMD),
        ),
    ];

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
        let limit = http::timeout(s)?;
        http::probe(&url, None, limit).await
    }

    // What: who may reach a ui route.
    // Why: router, socket and route list read it.
    // From: Issue #1683 | PR #2020
    #[derive(Clone, Copy, PartialEq)]
    pub(crate) enum Access {
        Open,
        Page,
        Api,
    }

    // What: the method of a ui route.
    // Why: one value for the router and the list.
    // From: Issue #1683 | PR #2020
    #[derive(Clone, Copy)]
    pub(crate) enum Verb {
        Get,
        Post,
    }

    // What: one ui route: SOT key, method, access.
    // Why: the router and the route list read one table.
    // From: Issue #1683 | PR #2020
    pub(crate) struct Route {
        key: String,
        verb: Verb,
        access: Access,
        handler: axum::routing::MethodRouter<Arc<App>>,
    }

    // What: a table row for a plain handler.
    // Why: the verb picks the method filter.
    // From: Issue #1683 | PR #2020
    fn route<H, T>(key: &str, verb: Verb, access: Access, h: H) -> Route
    where
        H: axum::handler::Handler<T, Arc<App>>,
        T: 'static,
    {
        let handler = match verb {
            Verb::Get => get(h),
            Verb::Post => post(h),
        };
        let key = key.to_string();
        Route {
            key,
            verb,
            access,
            handler,
        }
    }

    // What: a POST row of one action enum value.
    // Why: page, REST and CLI post the same form.
    // From: Issue #1683 | PR #2020
    fn op_route<H, T, O>(key: &str, h: H, op: O) -> Route
    where
        H: axum::handler::Handler<T, Arc<App>>,
        T: 'static,
        O: Clone + Send + Sync + 'static,
    {
        let mut r = route(key, Verb::Post, Access::Api, h);
        r.handler = r.handler.layer(Extension(Op(op)));
        r
    }

    // What: every ui route with key, verb and access.
    // Why: paths come from the SOT; one place maps them.
    // From: Issue #1683 | PR #2020
    pub(crate) fn table(s: &Settings) -> Result<Vec<Route>, String> {
        use Access::{Api, Open, Page};
        use Verb::{Get, Post};
        let dir = s.text("STATIC_DIR")?;
        let css = static_file(&dir, "admin.css")?;
        let icon = static_file(&dir, "favicon.ico")?;
        let logo = static_file(&dir, "logo-icon.png")?;
        let mut t = vec![
            route("UI_ROUTE_HEALTH", Get, Open, health),
            route("UI_ROUTE_SECONDARY_REGISTER", Post, Open, register),
            route("UI_ROUTE_ADMIN_CSS", Get, Open, move || async move {
                asset("text/css", css)
            }),
            route("UI_ROUTE_FAVICON", Get, Open, move || async move {
                asset("image/x-icon", icon)
            }),
            route("UI_ROUTE_LOGO_ICON", Get, Open, move || async move {
                asset("image/png", logo)
            }),
            route("UI_PAGE_DASHBOARD", Get, Page, dashboard),
            route("UI_PAGE_SETUP", Get, Page, setup),
            route("UI_ROUTE_SETUP_SAVE", Post, Page, save),
            route("UI_ROUTE_PASSWORD", Post, Api, password),
            route("UI_PAGE_LOGS", Get, Page, logs),
            route("UI_PAGE_CACHEHAMSTER", Get, Page, cachehamster),
            route("UI_PAGE_DOMAINS", Get, Page, domains),
            route("UI_PAGE_DHCP", Get, Page, dhcp),
            route("UI_ROUTE_DHCP_CHECK", Post, Api, dhcp_check),
            route("UI_PAGE_STATS", Get, Page, stats),
        ];
        t.extend(
            DhcpOp::ALL
                .iter()
                .map(|&o| op_route(o.key(), dhcp_action, o)),
        );
        t.extend(DnsOp::ALL.iter().map(|&o| op_route(o.key(), dns_action, o)));
        t.extend(
            SecondaryOp::ALL
                .iter()
                .map(|&o| op_route(o.key(), secondary_action, o)),
        );
        t.extend(
            HamsterOp::ALL
                .iter()
                .map(|&o| op_route(o.key(), hamster_action, o)),
        );
        t.extend([
            route("UI_ROUTE_CONTAINER_STATUS", Get, Api, status),
            route("UI_ROUTE_ALARMS", Get, Api, alarms),
            route("UI_ROUTE_DHCP_STATE", Get, Api, dhcp_state),
            route("UI_ROUTE_SETTINGS", Get, Api, settings_api),
            route("UI_ROUTE_SETTINGS", Post, Api, settings_set),
            route("UI_ROUTE_ZONE_SNAPSHOTS", Get, Api, zone_snapshots_api),
            route("UI_ROUTE_KEA_SNAPSHOTS", Get, Api, kea_snapshots_api),
            route("UI_ROUTE_DHCP_STATS", Get, Api, dhcp_stats_api),
            route("UI_ROUTE_PROXY_STATUS", Get, Api, proxy_status_api),
            route("UI_ROUTE_NTP", Get, Api, ntp_api),
            route("UI_ROUTE_NTP_TRACKING", Get, Api, ntp_tracking_api),
            route("UI_ROUTE_SYSTEM_TIME", Get, Api, system_time_api),
            route("UI_ROUTE_PROXY_LOG", Get, Api, proxy_log_api),
            route("UI_ROUTE_SECRETS", Get, Api, secrets_api),
            route("UI_ROUTE_CACHE", Get, Api, cache_api),
            route("UI_ROUTE_CDN", Get, Api, cdn_api),
            route("UI_ROUTE_SETTINGS_SCHEMA", Get, Api, settings_schema_api),
            route("UI_ROUTE_DNS_FLUSH", Post, Api, dns_flush_api),
            route("UI_ROUTE_DNSSEC", Get, Api, dnssec_api),
            route("UI_ROUTE_DNS_RECORDS", Get, Api, dns_records_api),
            route("UI_ROUTE_DNS_TSIG", Get, Api, dns_tsig_api),
            route("UI_ROUTE_DNS_SOA_PROBE", Get, Api, dns_soa_api),
            route("UI_ROUTE_DNS_API_CHECK", Get, Api, dns_api_check),
            route("UI_ROUTE_DNS_STATS", Get, Api, dns_stats_api),
            route("UI_ROUTE_DNS_QUERY", Get, Api, dns_query_api),
            route("UI_ROUTE_DNS_ZONES_ENSURE", Post, Api, zones_ensure_api),
            route("UI_ROUTE_APPLY_PLAN", Get, Api, apply_plan_api),
            route("UI_ROUTE_APPLY", Post, Api, apply_api),
            route("UI_ROUTE_APPLY_PREVIEW", Get, Api, apply_preview_api),
            route("UI_ROUTE_PROXY_PSL", Get, Api, proxy_psl_api),
            route("UI_ROUTE_PROXY_CERTS", Get, Api, certs_api),
            route("UI_ROUTE_STACK_SNAPSHOTS", Get, Api, stack_snapshots_api),
            route(
                "UI_ROUTE_STACK_SNAPSHOT_SAVE",
                Post,
                Api,
                stack_snapshot_save_api,
            ),
            route(
                "UI_ROUTE_STACK_SNAPSHOT_RESTORE",
                Post,
                Api,
                stack_snapshot_restore_api,
            ),
            route("UI_ROUTE_PROXY_CERTS_RENEW", Post, Api, certs_renew_api),
            route("UI_ROUTE_DOCKER", Get, Api, docker_api),
            route("UI_ROUTE_STATS_GRAPH", Get, Api, graph),
            route("UI_ROUTE_STATS_LIST", Get, Api, stats_list_api),
            route("UI_ROUTE_STATS_SAMPLE", Post, Api, stats_sample_api),
            route("UI_ROUTE_STATS_SNMP_CHECK", Get, Api, stats_snmp_check_api),
            route("UI_ROUTE_LOGS_SAVE", Post, Api, logs_save),
            route("UI_ROUTE_LOGS", Get, Api, logs_api),
            route("UI_ROUTE_LANG", Get, Api, lang_api),
            route("UI_ROUTE_CSRF", Get, Api, csrf_api),
            route("UI_ROUTE_UI_ROUTES", Get, Api, routes_api),
            route("UI_ROUTE_UI_TEMPLATES", Get, Api, templates_api),
            route("UI_ROUTE_WATCHDOG_TIDY", Post, Api, watchdog_tidy),
            route("UI_ROUTE_WATCHDOG_CHECK", Get, Api, watchdog_check),
            route("UI_ROUTE_WATCHDOG_PROCESSED", Get, Api, watchdog_processed),
            route("UI_ROUTE_ZONE_OVERVIEW", Get, Api, zone_overview),
            route("UI_ROUTE_DESIRED_STATE", Post, Api, container_state),
            route("UI_ROUTE_RESTART_UI", Post, Api, restart_ui),
            route("UI_ROUTE_SERVICE_ACTION", Post, Api, service_action),
            route("UI_ROUTE_HAMSTER_API", Post, Api, hamster_api),
        ]);
        Ok(t)
    }

    // What: a router of the rows one access allows.
    // Why: TCP and socket take rows of one table.
    // From: Issue #1683 | PR #2020
    fn routes_of(
        s: &Settings,
        rows: &mut Vec<Route>,
        keep: &[Access],
    ) -> Result<Router<Arc<App>>, String> {
        let mut r = Router::new();
        for row in rows.extract_if(.., |x| keep.contains(&x.access)) {
            r = r.route(&s.text(&row.key)?, row.handler);
        }
        Ok(r)
    }

    // What: the route list: path, method, access.
    // Why: CLI and REST read the router's table.
    // From: Issue #1683 | PR #2020
    pub(crate) fn route_list(s: &Settings) -> Result<Value, String> {
        let mut out = Vec::new();
        for r in table(s)? {
            let verb = match r.verb {
                Verb::Get => "GET",
                Verb::Post => "POST",
            };
            let access = match r.access {
                Access::Open => "open",
                Access::Page => "login",
                Access::Api => "login or socket",
            };
            out.push(json!({"key": r.key, "path": s.text(&r.key)?,
                "method": verb, "access": access}));
        }
        Ok(Value::Array(out))
    }

    // What: GET UI_ROUTE_CSRF: token of this session.
    // Why: a script posts it like the page forms do.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn csrf_api(Extension(csrf): Extension<Csrf>) -> Response {
        let v = json!({"token": csrf.0, "header": csrf.2, "field": CSRF_FIELD});
        axum::Json(v).into_response()
    }

    // What: ui password [user]: two stdin lines.
    // Why: the page form's handler checks and saves.
    // From: Issue #1683 | PR #2020
    async fn password_cli(s: &Settings, user: Option<&String>) -> Result<(), String> {
        let (current, new) = (stdin_line()?, stdin_line()?);
        let mut form = vec![
            ("current_password".to_string(), current),
            ("new_password".to_string(), new.clone()),
            ("confirm_password".to_string(), new),
        ];
        if let Some(u) = user {
            form.push(("user".to_string(), u.clone()));
        }
        let route = s.text("UI_ROUTE_PASSWORD")?;
        let v = http::ui_socket(s, &route, http::Body::Form(form)).await?;
        println!("{v}");
        Ok(())
    }

    // What: GET UI_ROUTE_UI_ROUTES: the route list.
    // Why: REST reads what the CLI reads.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn routes_api(State(app): Shared) -> Page {
        Ok(axum::Json(route_list(&app.settings())?).into_response())
    }

    // What: GET UI_ROUTE_UI_TEMPLATES: the check.
    // Why: REST reads what the CLI reads.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn templates_api(State(app): Shared) -> Page {
        Ok(axum::Json(template_report(&app.settings())?).into_response())
    }

    // What: all ui routes plus auth and headers.
    // Why: rows of the one table, by access.
    // From: Issue #1683 | PR #2020
    pub(crate) fn router(app: Arc<App>) -> Result<Router, String> {
        let s = app.settings();
        let mut rows = table(&s)?;
        let pages = routes_of(&s, &mut rows, &[Access::Page, Access::Api])?
            .layer(axum::middleware::from_fn_with_state(app.clone(), auth));
        Ok(routes_of(&s, &mut rows, &[Access::Open])?
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

    // What: the REST routes on the CLI socket.
    // Why: no login there; the socket mode guards it.
    // From: Issue #1683 | PR #2020
    fn socket_router(app: Arc<App>) -> Result<Router, String> {
        let s = app.settings();
        let header = s.text("UI_CSRF_HEADER")?;
        Ok(routes_of(&s, &mut table(&s)?, &[Access::Api])?
            .layer(Extension(Csrf::local(&header)))
            .layer(axum::extract::DefaultBodyLimit::max(
                s.num::<usize>("UI_REQUEST_BODY_MAX_BYTES")?,
            ))
            .layer(axum::middleware::from_fn_with_state(app.clone(), lang))
            .with_state(app))
    }

    // What: serve the REST routes on the CLI socket.
    // Why: CLI writes go through the running ui.
    // From: Issue #1683 | PR #2020
    async fn serve_socket(app: Arc<App>, path: String) -> Result<(), String> {
        use std::os::unix::fs::PermissionsExt;
        // What: a socket file of an earlier run goes.
        // Why: bind fails on an existing path.
        // From: Issue #1683 | PR #2020
        fs::delete_if_present(Path::new(&path)).map_err(|e| format!("{path}: {e}"))?;
        // What: bind on a side name, close it, then move.
        // Why: the socket is never open with a wide mode.
        // From: Issue #1683 | PR #2020
        let side = fs::with_suffix(Path::new(&path), ".new");
        fs::delete_if_present(&side).map_err(|e| format!("{}: {e}", side.display()))?;
        let sock = tokio::net::UnixListener::bind(&side).map_err(|e| format!("{path}: {e}"))?;
        std::fs::set_permissions(&side, std::fs::Permissions::from_mode(fs::PRIVATE_MODE))
            .map_err(|e| format!("{path}: {e}"))?;
        std::fs::rename(&side, &path).map_err(|e| format!("{path}: {e}"))?;
        axum::serve(sock, socket_router(app)?)
            .await
            .map_err(|e| format!("{path}: {e}"))
    }

    // What: save settings from a JSON object.
    // Why: CLI and scripts write through commit.
    // From: Issue #1683 | PR #2020
    pub(crate) async fn settings_set(
        State(app): Shared,
        Extension(csrf): Extension<Csrf>,
        axum::extract::Query(query): axum::extract::Query<Fields>,
        headers: HeaderMap,
        axum::Json(values): axum::Json<Fields>,
    ) -> Page {
        csrf.check_header(&headers)?;
        // What: ?dry_run=1 checks and names the keys.
        // Why: config validate saves nothing.
        // From: Issue #1683 | PR #2020
        if field(&query, "dry_run") == "1" {
            let keys = save_settings(&app, values, true).await?;
            return Ok(axum::Json(json!({"valid": true, "changes": keys})).into_response());
        }
        save_settings(&app, values, false).await?;
        Ok(axum::Json(app.settings().view_json()).into_response())
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
        use crate::shared::cli;
        let args: Vec<String> = args.to_vec();
        // What: an unknown word fails with the list.
        // Why: it must not start a second web server.
        // From: Issue #1683 | PR #2020
        let cmd = match args.first().map(String::as_str) {
            None => None,
            Some(word) => Some(
                cli::op_of(&COMMANDS, Some(&word.to_string()))
                    .ok_or_else(|| format!("{} (none: web server)", cli::help(&COMMANDS)))?,
            ),
        };
        let set = match cmd {
            Some(Cmd::HashPassword) => return hash_password(),
            Some(Cmd::EncodePasswordHash) => return encode_password_hash(),
            Some(Cmd::Set(set)) => Some(set),
            None => None,
        };
        let saved = config::saved_file();
        let s = Settings::from_process()?;
        if let Some(done) = command(&s, set, &args).await {
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
            stack: Stack {
                docker: docker::client(&s)?,
                settings: RwLock::new(s.clone()),
                saved,
                rendered: AtomicBool::new(false),
                change: tokio::sync::Mutex::new(()),
            },
            tera: templates(&s.text("TEMPLATE_DIR")?)?,
            session_key: secret::key_bytes(&key)?,
            cache_used: AtomicU64::new(u64::MAX),
        });
        // What: render every config once at start.
        // Why: owners read config volume; it starts empty.
        // From: Issue #1683 | PR #1980
        match apply_all(&app, &s, &s, false).await {
            Ok(lines) => say_all(&lines)
                .iter()
                .for_each(|l| eprintln!("ui: start: {l}")),
            Err(e) => eprintln!("ui: start render: {e}"),
        }
        tokio::spawn(sampler(app.clone()));
        tokio::spawn(cache_scanner(app.clone()));
        let a = app.clone();
        tokio::spawn(async move { flush_on_transfer(&a).await });
        tokio::spawn(zones_at_start(app.clone()));
        let a = app.clone();
        tokio::spawn(async move { secondary_watch(&a).await });
        let listen = crate::shared::dns::host_port(&s.text("UI_LISTEN")?, s.uint("UI_PORT")?);
        let sock = tokio::net::TcpListener::bind(&listen)
            .await
            .map_err(|e| format!("{listen}: {e}"))?;
        let socket = serve_socket(app.clone(), s.text("UI_CLI_SOCKET")?);
        let tcp = async {
            axum::serve(
                sock,
                router(app)?.into_make_service_with_connect_info::<std::net::SocketAddr>(),
            )
            .await
            .map_err(|e| e.to_string())
        };
        tokio::try_join!(tcp, socket).map(|_| ())
    }
}

// What: watchdog: decides when to check and tidy.
// Why: the shared modules hold the how; no config here.
// From: Issue #1683 | PR #2020
mod watchdog {
    use crate::config::Settings;
    use crate::shared::docker::Health;
    use crate::shared::{Fault, cert, clock, docker, fs, tidy};
    use serde::Serialize;
    use serde_json::Value;
    use std::collections::{BTreeMap, VecDeque};
    use std::path::{Path, PathBuf};
    use std::time::Duration;

    // What: weight of one finding.
    // Why: the ui sorts and colours by it.
    // From: Issue #1683 | PR #1980
    #[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize)]
    enum Level {
        Warn,
        Crit,
    }

    // What: one finding.
    // Why: same row in the alarm file and the log.
    // From: Issue #1683 | PR #1858
    #[derive(Debug, Serialize)]
    struct Alarm {
        level: Level,
        source: String,
        text: String,
        // What: language key and values of the text.
        // Why: the ui shows the alarm in the page language.
        // From: Issue #1683 | PR #2020
        #[serde(skip_serializing_if = "Option::is_none")]
        key: Option<&'static str>,
        #[serde(skip_serializing_if = "Vec::is_empty")]
        vals: Vec<(&'static str, String)>,
    }

    // What: findings and facts of one round.
    // Why: a check adds rows and never stops others.
    // From: Issue #1683 | PR #1980
    #[derive(Default)]
    struct Findings {
        alarms: Vec<Alarm>,
        containers: Vec<Value>,
        cache: Value,
        heal: Value,
    }

    impl Findings {
        // What: records one alarm with level and source.
        // Why: a check reports here and keeps running.
        // From: Issue #1683 | PR #1980
        fn add(&mut self, level: Level, source: &str, what: impl Into<Fault>) {
            let what = what.into();
            let text = crate::ui::say(&what);
            let (key, vals) = match what {
                Fault::Key(key, vals) => (Some(key), vals),
                _ => (None, Vec::new()),
            };
            self.alarms.push(Alarm {
                level,
                source: source.to_string(),
                text,
                key,
                vals,
            });
        }
        // What: records a warning.
        // Why: most callers need only source and text.
        // From: Issue #1683 | PR #1980
        fn warn(&mut self, source: &str, text: impl Into<Fault>) {
            self.add(Level::Warn, source, text);
        }
        // What: records a critical alarm.
        // Why: most callers need only source and text.
        // From: Issue #1683 | PR #1980
        fn crit(&mut self, source: &str, text: impl Into<Fault>) {
            self.add(Level::Crit, source, text);
        }
    }

    // What: body of the alarm file.
    // Why: the ui shows it; the stamp proves life.
    // From: Issue #1683 | PR #1980
    #[derive(Serialize)]
    struct Report<'a> {
        written: u64,
        alarms: &'a [Alarm],
        containers: &'a [Value],
        cache: &'a Value,
        heal: &'a Value,
    }

    // What: failure streaks and restart times.
    // Why: restart after RESTART_AFTER misses, capped.
    // From: Issue #1683 | PR #1980
    #[derive(Default)]
    struct Memory {
        streak: BTreeMap<String, u64>,
        restarts: BTreeMap<String, VecDeque<u64>>,
        log_counter: Option<(u64, u64)>,
    }

    impl Memory {
        // What: drop restarts older than the window.
        // Why: limit check and report count one way.
        // From: Issue #1683 | PR #2020
        fn recent(&mut self, s: &Settings, name: &str) -> Result<usize, String> {
            let window = s.uint("WATCHDOG_RESTART_WINDOW")?;
            let now = clock::unix_secs();
            let times = self.restarts.entry(name.to_string()).or_default();
            times.retain(|t| now.saturating_sub(*t) <= window);
            Ok(times.len())
        }

        // What: may this container restart now.
        // Why: at most LIMIT restarts per WINDOW.
        // From: Issue #1683 | PR #1980
        fn restart_allowed(&mut self, s: &Settings, name: &str) -> Result<bool, String> {
            let max = s.uint("WATCHDOG_RESTART_LIMIT")?;
            if self.recent(s, name)? as u64 >= max {
                return Ok(false);
            }
            let now = clock::unix_secs();
            self.restarts
                .entry(name.to_string())
                .or_default()
                .push_back(now);
            Ok(true)
        }
    }

    // What: check every container; heal on a streak.
    // Why: one miss is noise; RESTART_AFTER is a fault.
    // From: Issue #1683 | PR #1980
    async fn containers(
        s: &Settings,
        f: &mut Findings,
        m: &mut Memory,
        heal: bool,
    ) -> Result<(), String> {
        let api = docker::client(s)?;
        let limit = docker::timeout(s)?;
        let grace = s.num::<u32>("WATCHDOG_STOP_GRACE")?;
        let after = s.uint("RESTART_AFTER")?;
        for member in docker::members(&api, s).await? {
            // What: an inspect error stops this round.
            // Why: no restart on a state that was not read.
            // From: Issue #1683 | PR #2020
            let inspect = member.inspect.clone()?;
            let (service, name) = (member.service.as_str(), member.name.as_str());
            let health = Health::from_inspect(&inspect);
            let by_user = member.stopped_by_user;
            let wanted = member.wanted();
            let (word, colour) = (health.word(), health.colour(wanted));
            f.containers.push(serde_json::json!({
                "service": service, "name": name, "health": word,
                "colour": colour, "stopped_by_user": by_user,
            }));
            if health == Health::Degraded {
                f.warn(service, Fault::key("alarm_degraded", []));
            }
            if !wanted || !health.failing() {
                m.streak.remove(name);
                continue;
            }
            // What: a check on demand never restarts.
            // Why: the streak lives only in the loop.
            // From: Issue #1683 | PR #2020
            if !heal {
                f.warn(service, word);
                continue;
            }
            let count = m.streak.entry(name.to_string()).or_default();
            *count += 1;
            if *count < after {
                f.warn(
                    service,
                    Fault::key(
                        "alarm_check_streak",
                        [
                            ("state", word.to_string()),
                            ("count", count.to_string()),
                            ("after", after.to_string()),
                        ],
                    ),
                );
                continue;
            }
            *count = 0;
            if !m.restart_allowed(s, name)? {
                f.crit(
                    service,
                    Fault::key("alarm_restart_limit", [("state", word.to_string())]),
                );
                continue;
            }
            match api.act(name, docker::Action::Restart, grace, limit).await {
                Ok(()) => f.warn(
                    service,
                    Fault::key("alarm_restarted", [("state", word.to_string())]),
                ),
                Err(e) => f.crit(
                    service,
                    Fault::key(
                        "alarm_restart_failed",
                        [("state", word.to_string()), ("error", e.to_string())],
                    ),
                ),
            }
        }
        heal_state(s, f, m)
    }

    // What: miss streak and recent restarts per row.
    // Why: the state lives only in this loop.
    // From: Issue #1683 | PR #2020
    fn heal_state(s: &Settings, f: &mut Findings, m: &mut Memory) -> Result<(), String> {
        let (max, window) = (
            s.uint("WATCHDOG_RESTART_LIMIT")?,
            s.uint("WATCHDOG_RESTART_WINDOW")?,
        );
        for row in &mut f.containers {
            let name = row["name"].as_str().unwrap_or_default().to_string();
            row["failed_checks"] = m.streak.get(&name).copied().unwrap_or(0).into();
            row["restarts"] = m.recent(s, &name)?.into();
        }
        f.heal = serde_json::json!({
            "restart_after": s.uint("RESTART_AFTER")?,
            "restart_limit": max, "restart_window": window,
        });
        Ok(())
    }

    // What: how a tidy step runs.
    // Why: the round waits for its stamp; CLI does not.
    // From: Issue #1683 | PR #2020
    #[derive(Clone, Copy, PartialEq)]
    enum When {
        Due,
        Now,
        Dry,
    }

    // What: the tidy steps the CLI and REST offer.
    // Why: one list for the command and the route.
    // From: Issue #1683 | PR #2020
    pub(crate) const TIDY_STEPS: [&str; 3] = [PURGE, PRUNE, PACK];

    // What: CLI names of the three tidy steps.
    // Why: list, dispatch and answers read these.
    // From: Issue #1683 | PR #2020
    const PURGE: &str = "purge-cache";
    const PRUNE: &str = "prune-logs";
    const PACK: &str = "pack-logs";

    // What: what one tidy step picked and did.
    // Why: round, CLI and REST read one answer.
    // From: Issue #1683 | PR #2020
    #[derive(Default, Serialize)]
    struct Tidied {
        step: &'static str,
        dry_run: bool,
        ok: bool,
        count: usize,
        bytes: u64,
        files: Vec<String>,
        errors: Vec<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        size: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        budget: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        owner_fixed: Option<u64>,
    }

    // What: the answer for the picked files.
    // Why: lists at most WATCHDOG_TIDY_LIST_MAX names.
    // From: Issue #1683 | PR #2020
    fn picked(
        s: &Settings,
        step: &'static str,
        when: When,
        pick: &[tidy::Item],
    ) -> Result<Tidied, String> {
        let max = s.num::<usize>("WATCHDOG_TIDY_LIST_MAX")?;
        let names = pick.iter().take(max).map(|f| f.path.display().to_string());
        Ok(Tidied {
            step,
            dry_run: when == When::Dry,
            count: pick.len(),
            bytes: pick.iter().map(|f| f.size).sum(),
            files: names.collect(),
            ..Tidied::default()
        })
    }

    // What: daily: drop cache files past their days.
    // Why: CACHE_VALID_DAYS keeps the disk usable.
    // From: Issue #1683 | PR #1980
    fn purge_cache(s: &Settings, now: u64, when: When) -> Result<Option<Tidied>, String> {
        let stamp = PathBuf::from(s.text("PURGE_STAMP")?);
        if when == When::Due && !tidy::is_due(&stamp, now) {
            return Ok(None);
        }
        let root = tidy::cache_root(s)?;
        // What: the cache gets the nginx owner back first.
        // Why: nginx writes and the purge deletes it all.
        // From: Issue #1683 | PR #2020
        let owner = (s.num::<u32>("NGINX_UID")?, s.num::<u32>("NGINX_GID")?);
        let apply = when != When::Dry;
        let (fixed, owner_errs) = crate::shared::fs::chown_tree(&root, owner.0, owner.1, apply);
        if apply && fixed > 0 {
            eprintln!("watchdog: cache owner set on {fixed} entries");
        }
        let (all, unread) = tidy::files(&root);
        let (pick, _) = tidy::older(all, s.uint("CACHE_VALID_DAYS")?, now);
        let mut t = picked(s, PURGE, when, &pick)?;
        t.owner_fixed = Some(fixed);
        t.errors = owner_errs;
        t.errors.extend(unread);
        if when != When::Dry {
            let failed = tidy::delete(&pick).1;
            let removed = t.count - failed.len();
            eprintln!("watchdog: cache purge removed {removed} files");
            t.errors.extend(failed);
            tidy::save_stamp(&stamp, now)?;
        }
        Ok(Some(t))
    }

    // What: log root, only inside the allowed prefix.
    // Why: cleanup must never delete outside the logs.
    // From: Issue #1683 | PR #1980
    fn log_root(s: &Settings) -> Result<PathBuf, String> {
        tidy::inside(
            &s.text("SYSLOG_LOG_ROOT")?,
            &s.text("SYSLOG_LOG_ROOT_ALLOWED_PREFIX")?,
        )
    }

    // What: daily: log age limit, then size budget.
    // Why: over budget retries after the cooldown.
    // From: Issue #1683 | PR #1980
    fn prune_logs(s: &Settings, now: u64, when: When) -> Result<Option<Tidied>, String> {
        let stamp = PathBuf::from(s.text("SYSLOG_PRUNE_STAMP")?);
        if when == When::Due && !tidy::is_due(&stamp, now) {
            return Ok(None);
        }
        let root = log_root(s)?;
        let budget = crate::shared::human::gib_bytes(s.uint("SYSLOG_MAX_GB")?)
            .ok_or("SYSLOG_MAX_GB is too big")?;
        let days = s.uint("SYSLOG_RETENTION_DAYS")?;
        let (all, unread) = tidy::files(&root);
        let (mut pick, rest) = tidy::older(all, days, now);
        let (more, mut size) = tidy::over_budget(rest, budget, now);
        pick.extend(more);
        let mut t = picked(s, PRUNE, when, &pick)?;
        t.errors = unread;
        if when != When::Dry {
            let (freed, errs) = tidy::delete(&pick);
            // What: bytes of failed removals stay counted.
            // Why: the budget check sees the real size.
            // From: Issue #1683 | PR #2020
            size = size.saturating_add(t.bytes.saturating_sub(freed));
            t.errors.extend(errs);
            let wait = s.uint("SYSLOG_PRUNE_RETRY_COOLDOWN")?;
            let at = if size <= budget {
                now
            } else {
                (now + wait).saturating_sub(tidy::DAY)
            };
            tidy::save_stamp(&stamp, at)?;
        }
        (t.size, t.budget) = (Some(size), Some(budget));
        Ok(Some(t))
    }

    // What: pack closed log files with xz.
    // Why: saves log disk; open files stay plain.
    // From: Issue #1683 | PR #1980
    fn pack_logs(s: &Settings, now: u64, when: When) -> Result<Option<Tidied>, String> {
        let (pick, unread) = tidy::closed(&log_root(s)?, now);
        let mut t = picked(s, PACK, when, &pick)?;
        t.errors = unread;
        if when != When::Dry {
            t.errors
                .extend(tidy::pack(&pick, s.uint("SYSLOG_XZ_PRESET")?));
        }
        Ok(Some(t))
    }

    // What: one tidy step by its CLI name.
    // Why: CLI and REST run the round's functions.
    // From: Issue #1683 | PR #2020
    fn tidy_now(s: &Settings, step: &str, dry: bool) -> Result<Tidied, String> {
        let (now, when) = (clock::unix_secs(), if dry { When::Dry } else { When::Now });
        let done = match step {
            PURGE => purge_cache(s, now, when)?,
            PRUNE => prune_logs(s, now, when)?,
            PACK => pack_logs(s, now, when)?,
            _ => return Err(format!("{step}: steps: {}", TIDY_STEPS.join(" "))),
        };
        let mut t = done.ok_or("step did not run")?;
        let fits = t.size.zip(t.budget).is_none_or(|(n, b)| n <= b);
        t.ok = t.errors.is_empty() && fits;
        Ok(t)
    }

    // What: alarm rows of one tidy step in the round.
    // Why: a step error and an over budget size warn.
    // From: Issue #1683 | PR #2020
    fn tidy_alarms(f: &mut Findings, name: &str, t: Tidied) {
        for e in t.errors {
            f.warn(name, e);
        }
        if let (Some(size), Some(budget)) = (t.size, t.budget)
            && size > budget
        {
            f.warn(
                "logs",
                Fault::key("alarm_log_budget", [("size", size.to_string())]),
            );
        }
    }

    // What: logs arrive but nothing is written.
    // Why: a full or read-only log disk hides itself.
    // From: Issue #1683 | PR #1980
    fn log_writing(s: &Settings, f: &mut Findings, m: &mut Memory) -> Result<(), String> {
        let (newest, unread) = tidy::newest(Path::new(&s.text("SYSLOG_LOG_ROOT")?));
        if !unread.is_empty() {
            f.warn(
                "logs",
                Fault::key("alarm_logs_unread", [("files", unread.join("; "))]),
            );
        }
        let count = tidy::syslog_processed(s)?;
        if let Some((was_count, was_newest)) = m.log_counter
            && count > was_count
            && newest == was_newest
        {
            f.crit("logs", Fault::key("alarm_logs_stuck", []));
        }
        m.log_counter = Some((count, newest));
        Ok(())
    }

    // What: cache disk use as a traffic light.
    // Why: the ui shows green, yellow or red.
    // From: Issue #1683 | PR #1980
    fn cache_light(s: &Settings, f: &mut Findings) -> Result<(), String> {
        let dir = s.text("CACHE_DIR")?;
        let sp = tidy::cache_space(s)?;
        let (used, pct) = (sp.used(), sp.pct());
        let (warn, alarm) = (s.uint("DISK_WARN_PCT")?, s.uint("DISK_ALARM_PCT")?);
        let colour = if pct >= alarm {
            f.crit(
                &dir,
                Fault::key("alarm_cache_full", [("pct", pct.to_string())]),
            );
            "red"
        } else if pct >= warn {
            f.warn(
                &dir,
                Fault::key("alarm_cache_full", [("pct", pct.to_string())]),
            );
            "yellow"
        } else {
            "green"
        };
        f.cache = serde_json::json!({"pct": pct, "used_bytes": used, "status": colour});
        Ok(())
    }

    // What: free space of each other watched path.
    // Why: a full log disk stops the logs.
    // From: Issue #1683 | PR #1980
    fn disks(s: &Settings, f: &mut Findings) -> Result<(), String> {
        let min = s.uint("WATCHDOG_DISK_MIN_FREE_PERCENT")?;
        for path in s.list("WATCHDOG_DISK_PATHS")? {
            match fs::space(Path::new(&path)) {
                Err(e) => f.crit(&path, e.to_string()),
                Ok(sp) if sp.total == 0 => f.warn(&path, Fault::key("alarm_size_zero", [])),
                Ok(sp) => {
                    let free = sp.free_pct();
                    if free < min {
                        f.crit(
                            &path,
                            Fault::key(
                                "alarm_disk_free",
                                [("free", free.to_string()), ("min", min.to_string())],
                            ),
                        );
                    }
                }
            }
        }
        Ok(())
    }

    // What: host conntrack use against its maximum.
    // Why: a full table drops new connections.
    // From: Issue #1683 | PR #1985
    fn conntrack(s: &Settings, f: &mut Findings) -> Result<(), String> {
        let path = Path::new(&s.text("HOST_NET_STAT_DIR")?).join(s.text("CONNTRACK_STAT_FILE")?);
        // What: no stat file means no conntrack table.
        // Why: a host without the module has no table.
        // From: Issue #1683 | PR #1985
        let Some(raw) =
            fs::read_if_present(&path).map_err(|e| format!("{}: {e}", path.display()))?
        else {
            return Ok(());
        };
        let stat = String::from_utf8_lossy(&raw);
        let used = stat
            .lines()
            .nth(1)
            .and_then(|l| l.split_whitespace().next())
            .and_then(|h| u64::from_str_radix(h, 16).ok())
            .ok_or_else(|| format!("{}: no entries column", path.display()))?;
        let max_file = s.text("CONNTRACK_MAX_FILE")?;
        let max: u64 = fs::read_text(Path::new(&max_file))?
            .trim()
            .parse()
            .map_err(|e| format!("{max_file}: {e}"))?;
        let pct = crate::shared::human::pct(used, max);
        let warn = s.uint("WATCHDOG_CONNTRACK_WARN_PCT")?;
        if pct >= warn {
            f.warn(
                "conntrack",
                Fault::key(
                    "alarm_conntrack",
                    [
                        ("pct", pct.to_string()),
                        ("used", used.to_string()),
                        ("max", max.to_string()),
                    ],
                ),
            );
        }
        Ok(())
    }

    // What: expiry of each watched certificate.
    // Why: warn before clients reject proxy or ui.
    // From: Issue #1683 | PR #1980
    fn certs(s: &Settings, f: &mut Findings) -> Result<(), String> {
        let within = s.uint("WATCHDOG_CERT_WARN_SECS")?;
        for path in s.list("WATCHDOG_CERT_FILES")? {
            let v = cert::state(Path::new(&path), within);
            match (v["error"].as_str(), v["renew"] == true) {
                (Some(e), _) => f.crit(&path, e),
                (None, true) => f.warn(
                    &path,
                    Fault::key(
                        "alarm_cert_expires",
                        [
                            ("days", v["days_left"].to_string()),
                            ("until", v["until"].as_str().unwrap_or_default().to_string()),
                        ],
                    ),
                ),
                (None, false) => {}
            }
        }
        Ok(())
    }

    // What: zone serials, primary against secondary.
    // Why: shows a lost NOTIFY or a broken AXFR.
    // From: Issue #1683 | PR #1980
    async fn dns_sync(s: &Settings, f: &mut Findings) -> Result<(), String> {
        use crate::shared::peer;
        // What: the registered secondaries, not a lone URL.
        // Why: one list owns the peers; each gets a check.
        // From: Issue #1683 | PR #2019
        let peers = crate::shared::pdns_conf::secondaries(s)?;
        if peers.is_empty() {
            return Ok(());
        }
        let ours = peer::own_api(s)?
            .zones()
            .await
            .map_err(|e| format!("primary: {e}"))?;
        for (name, address) in peers {
            let theirs = match peer::zones_at(s, &address).await {
                Ok(z) => z,
                Err(e) => {
                    f.crit(&name, Fault::key("alarm_secondary_down", [("error", e)]));
                    continue;
                }
            };
            for z in peer::peer_zones(s, &ours, &theirs)? {
                let state = peer::zone_state(&z);
                if state != peer::ZoneState::InSync {
                    f.warn(
                        &name,
                        Fault::key(
                            "alarm_zone_state",
                            [
                                ("zone", z.zone.clone()),
                                ("state", state.word().to_string()),
                                ("primary", format!("{:?}", z.primary)),
                                ("secondary", format!("{:?}", z.secondary)),
                            ],
                        ),
                    );
                }
            }
            // What: a zone the primary no longer serves.
            // Why: a stale slave keeps answering old names.
            // From: Issue #1683 | PR #2019
            for z in &theirs {
                if z.kind == "Slave" && peer::serial_of(&ours, &z.name).is_none() {
                    f.warn(
                        &name,
                        Fault::key("alarm_extra_zone", [("zone", z.name.clone())]),
                    );
                }
            }
        }
        Ok(())
    }

    // What: the checks of a round, no tidy step.
    // Why: the loop and "watchdog check" share them.
    // From: Issue #1683 | PR #2020
    async fn checks(s: &Settings, m: &mut Memory, heal: bool) -> Findings {
        let mut f = Findings::default();
        if let Err(e) = containers(s, &mut f, m, heal).await {
            f.crit("docker", e);
        }
        let steps: [(&str, Result<(), String>); 4] = [
            ("cache", cache_light(s, &mut f)),
            ("disks", disks(s, &mut f)),
            ("conntrack", conntrack(s, &mut f)),
            ("certs", certs(s, &mut f)),
        ];
        for (name, result) in steps {
            if let Err(e) = result {
                f.crit(name, e);
            }
        }
        if let Err(e) = dns_sync(s, &mut f).await {
            f.crit("dns", e);
        }
        f
    }

    // What: run every duty of one round.
    // Why: a broken duty is itself an alarm.
    // From: Issue #1683 | PR #1858
    async fn round(s: &Settings, m: &mut Memory) -> Findings {
        let mut f = checks(s, m, true).await;
        let now = clock::unix_secs();
        let tidy_steps = [
            ("cache purge", purge_cache(s, now, When::Due)),
            ("log prune", prune_logs(s, now, When::Due)),
            ("log pack", pack_logs(s, now, When::Due)),
        ];
        for (name, result) in tidy_steps {
            match result {
                Err(e) => f.crit(name, e),
                Ok(Some(t)) => tidy_alarms(&mut f, name, t),
                Ok(None) => {}
            }
        }
        if let Err(e) = log_writing(s, &mut f, m) {
            f.crit("logs", e);
        }
        sort_alarms(&mut f);
        f
    }

    // What: critical first, then by source.
    // Why: the loop and the check print one order.
    // From: Issue #1683 | PR #2020
    fn sort_alarms(f: &mut Findings) {
        f.alarms
            .sort_by(|a, b| b.level.cmp(&a.level).then_with(|| a.source.cmp(&b.source)));
    }

    // What: the report body of a set of findings.
    // Why: alarm file and "watchdog check" share it.
    // From: Issue #1683 | PR #2020
    fn report_of(f: &Findings) -> Report<'_> {
        Report {
            written: clock::unix_secs(),
            alarms: &f.alarms,
            containers: &f.containers,
            cache: &f.cache,
            heal: &f.heal,
        }
    }

    // What: write the alarm file for the ui.
    // Why: whole-file replace; no half reads.
    // From: Issue #1683 | PR #1858
    fn publish(s: &Settings, f: &Findings) -> Result<(), String> {
        let path = PathBuf::from(s.text("WATCHDOG_ALARM_FILE")?);
        let mode = s.mode("WATCHDOG_ALARM_FILE_MODE")?;
        let body = serde_json::to_vec_pretty(&report_of(f)).map_err(|e| e.to_string())?;
        fs::write(&path, &body, mode, fs::Place::Replace, fs::Owner::default())
            .map_err(|e| format!("{}: {e}", path.display()))
    }

    // What: the last alarm report the watchdog wrote.
    // Why: ui, REST, CLI and healthcheck read one way.
    // From: Issue #1683 | PR #2020
    pub(crate) fn report(s: &Settings) -> Result<Option<Value>, String> {
        fs::read_json(&PathBuf::from(s.text("WATCHDOG_ALARM_FILE")?))
    }

    // What: healthcheck mode for the container probe.
    // Why: fresh alarm file means the watch loop runs.
    // From: Issue #1683 | PR #1980
    fn healthcheck() -> Result<(), String> {
        let s = Settings::from_process()?;
        let (interval, after) = (s.uint("CHECK_INTERVAL")?, s.uint("RESTART_AFTER")?);
        let limit = interval
            .checked_mul(after.max(1))
            .ok_or("CHECK_INTERVAL times RESTART_AFTER is too big")?;
        let v = report(&s)?
            .ok_or_else(|| format!("{}: missing", s.text_or_empty("WATCHDOG_ALARM_FILE")))?;
        let written = v["written"].as_u64().ok_or("written missing")?;
        let age = clock::unix_secs().saturating_sub(written);
        if age > limit {
            return Err(format!("alarm file {age}s old, limit {limit}s"));
        }
        Ok(())
    }

    // What: what one watchdog command does.
    // Why: run() matches these; tidy steps are TIDY_STEPS.
    // From: Issue #1683 | PR #2020
    #[derive(Clone, Copy, PartialEq)]
    enum Op {
        Healthcheck,
        Alarms,
        Check,
        Processed,
    }

    // What: every watchdog command but the tidy steps.
    // Why: help, errors and the choice read this table.
    // From: Issue #1683 | PR #2020
    const COMMANDS: [(&str, crate::shared::cli::Entry<Op>); 4] = [
        (
            "healthcheck",
            crate::shared::cli::row(Op::Healthcheck, "healthcheck"),
        ),
        ("alarms", crate::shared::cli::row(Op::Alarms, "alarms")),
        ("check", crate::shared::cli::row(Op::Check, "check")),
        (
            "processed",
            crate::shared::cli::row(Op::Processed, "processed"),
        ),
    ];

    // What: healthcheck command, else the check loop.
    // Why: settings are reread; a bad round never exits.
    // From: Issue #1683 | PR #1858
    pub async fn run(args: &[String]) -> Result<(), String> {
        use crate::shared::cli;
        let first = args.first().map(String::as_str);
        match (first, cli::op_of(&COMMANDS, args.first())) {
            (None, _) => {}
            (_, Some(Op::Healthcheck)) => {
                if let Err(e) = healthcheck() {
                    eprintln!("watchdog healthcheck: {e}");
                    std::process::exit(1);
                }
                return Ok(());
            }
            // What: last alarm report as JSON on stdout.
            // Why: the CLI reads what the ui and REST show.
            // From: Issue #1683 | PR #2020
            (_, Some(Op::Alarms)) => {
                let s = Settings::from_process()?;
                let v = report(&s)?.ok_or("no alarm report written yet")?;
                println!("{v}");
                return Ok(());
            }
            // What: the checks once, no heal, no tidy.
            // Why: see a fix now, not after CHECK_INTERVAL.
            // From: Issue #1683 | PR #2020
            (_, Some(Op::Check)) => {
                let s = Settings::from_process()?;
                let mut f = checks(&s, &mut Memory::default(), false).await;
                sort_alarms(&mut f);
                let body = serde_json::to_string(&report_of(&f)).map_err(|e| e.to_string())?;
                println!("{body}");
                if f.alarms.iter().any(|a| a.level == Level::Crit) {
                    std::process::exit(1);
                }
                return Ok(());
            }
            // What: lines syslog-ng wrote to the log store.
            // Why: its input; the socket is in services.
            // From: Issue #1683 | PR #2020
            (_, Some(Op::Processed)) => {
                let s = Settings::from_process()?;
                match tidy::syslog_processed(&s) {
                    Ok(n) => println!("{}", serde_json::json!({"processed": n})),
                    Err(e) => {
                        println!("{}", serde_json::json!({"error": e}));
                        std::process::exit(1);
                    }
                }
                return Ok(());
            }
            // What: one tidy step now, or --dry-run.
            // Why: the same functions as the round.
            // From: Issue #1683 | PR #2020
            (Some(step), None) if TIDY_STEPS.contains(&step) => {
                let dry = match args.get(1).map(String::as_str) {
                    None => false,
                    Some("--dry-run") => true,
                    Some(x) => return Err(format!("{x}: only --dry-run")),
                };
                let t = tidy_now(&Settings::from_process()?, step, dry)?;
                println!("{}", serde_json::to_string(&t).map_err(|e| e.to_string())?);
                if !t.ok {
                    std::process::exit(1);
                }
                return Ok(());
            }
            // What: an unknown word fails with the list.
            // Why: it must not start a second check loop.
            // From: Issue #1683 | PR #2020
            (Some(_), None) => {
                let steps = TIDY_STEPS.join(" | ");
                let own = cli::forms(&COMMANDS, " | ");
                return Err(format!(
                    "commands: {own} | {steps} [--dry-run] (none: check loop)"
                ));
            }
        }
        use tokio::signal::unix::{SignalKind, signal};
        let mut settings = Settings::from_process()?;
        let mut pause = Duration::from_secs(settings.uint("CHECK_INTERVAL")?);
        let mut term = signal(SignalKind::terminate()).map_err(|e| e.to_string())?;
        let mut memory = Memory::default();
        loop {
            match Settings::from_process() {
                Ok(s) => settings = s,
                Err(e) => eprintln!("watchdog: settings kept: {e}"),
            }
            match settings.uint("CHECK_INTERVAL") {
                Ok(v) => pause = Duration::from_secs(v),
                Err(e) => eprintln!("watchdog: interval kept: {e}"),
            }
            let found = round(&settings, &mut memory).await;
            for a in &found.alarms {
                eprintln!("watchdog: {:?} {}: {}", a.level, a.source, a.text);
            }
            if let Err(e) = publish(&settings, &found) {
                eprintln!("watchdog: alarm file: {e}");
            }
            tokio::select! {
                () = tokio::time::sleep(pause) => {}
                _ = term.recv() => return Ok(()),
            }
        }
    }
}

// What: lancache-<role> as program name picks the role.
// Why: old callers run lancache-ui/-dns/... unchanged.
// From: Issue #1683 | PR #2020
#[tokio::main]
async fn main() -> std::process::ExitCode {
    let exe = std::env::args().next().unwrap_or_default();
    let exe = std::path::Path::new(&exe)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("");
    let mut argv: Vec<String> = std::env::args().skip(1).collect();
    let role: String = match exe.strip_prefix("lancache-") {
        Some(r) if r != "ng" => r.into(),
        _ if !argv.is_empty() => argv.remove(0),
        _ => String::new(),
    };
    // What: "<name> help" prints that name's commands.
    // Why: each owner's own list; exit 0 on stdout.
    // From: Issue #1683 | PR #2020
    let help = argv.first().is_some_and(|a| a == "help");
    let code = |r: Result<(), String>| match r {
        Err(e) if help && (e.starts_with("commands:") || e.starts_with("usage:")) => {
            println!("{e}");
            std::process::ExitCode::SUCCESS
        }
        other => code(other),
    };
    match role.as_str() {
        // What: the overview of roles and groups.
        // Why: the first step to every command list.
        // From: Issue #1683 | PR #2020
        "help" => {
            println!("roles: {}", shared::cli::names(&ROLES));
            println!("groups: {}", shared::cli::names(&GROUPS));
            println!("lancache-ng <role|group> help lists its commands");
            std::process::ExitCode::SUCCESS
        }
        other => {
            let pick = |table: &[(&'static str, Target)]| shared::cli::pick(table, other);
            match pick(&ROLES).or_else(|| pick(&GROUPS)) {
                // What: command groups; each at its owner.
                // Why: a CLI command lives with its owner.
                // From: Issue #1683 | PR #2020
                Some(Target::Ui) => code(ui::run(&argv).await),
                Some(Target::Watchdog) => code(watchdog::run(&argv).await),
                Some(Target::Dns) => code(dns::run(&argv).await),
                Some(Target::Cachehamster) => cachehamster::run(&argv).await,
                Some(Target::Dhcp) => code(dhcp::run(&argv).await),
                Some(Target::Config) => code(config::run(&argv).await),
                Some(Target::System) => code(shared::docker::run(&argv).await),
                Some(Target::Proxy) => code(shared::nginx_conf::run(&argv).await),
                Some(Target::Ntp) => code(shared::ntp::run(&argv).await),
                Some(Target::Secret) => code(shared::secret::run(&argv)),
                Some(Target::Cache) => code(shared::tidy::run(&argv).await),
                Some(Target::Cdn) => code(shared::cdn::run(&argv).await),
                Some(Target::Stats) => code(shared::rrd::run(&argv).await),
                Some(Target::Logs) => code(shared::access::run(&argv)),
                None => {
                    eprintln!(
                        "lancache-ng: unknown role {other:?}; use {} or {}",
                        shared::cli::joined(&ROLES, "|"),
                        shared::cli::joined(&GROUPS, "|")
                    );
                    std::process::ExitCode::from(2)
                }
            }
        }
    }
}

// What: what a role or group starts.
// Why: main matches these, the tables name them.
// From: Issue #1683 | PR #2020
#[derive(Clone, Copy)]
enum Target {
    Ui,
    Watchdog,
    Dns,
    Cachehamster,
    Dhcp,
    Config,
    System,
    Proxy,
    Ntp,
    Secret,
    Cache,
    Cdn,
    Stats,
    Logs,
}

// What: the roles; argv0 lancache-<role> picks one too.
// Why: help, errors and the choice read this table.
// From: Issue #1683 | PR #2020
const ROLES: [(&str, Target); 4] = [
    ("ui", Target::Ui),
    ("watchdog", Target::Watchdog),
    ("dns", Target::Dns),
    ("cachehamster", Target::Cachehamster),
];

// What: the command groups that are no daemon role.
// Why: help, errors and the choice read this table.
// From: Issue #1683 | PR #2020
const GROUPS: [(&str, Target); 10] = [
    ("dhcp", Target::Dhcp),
    ("config", Target::Config),
    ("system", Target::System),
    ("proxy", Target::Proxy),
    ("ntp", Target::Ntp),
    ("secret", Target::Secret),
    ("cache", Target::Cache),
    ("cdn", Target::Cdn),
    ("stats", Target::Stats),
    ("logs", Target::Logs),
];

// What: turn a role Result into a process exit code.
// Why: roles return Result; cachehamster its own code.
// From: Issue #1683 | PR #2020
fn code(r: Result<(), String>) -> std::process::ExitCode {
    match r {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            std::process::ExitCode::FAILURE
        }
    }
}
