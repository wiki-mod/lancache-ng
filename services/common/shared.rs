//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: the common owners that service binaries call.
//! Why: one owner per shared rule; services call it.
//! From: Issue #1683 | PR #1858

pub mod config;

use anyhow::Context as _;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use subtle::{Choice, ConstantTimeEq};

// What: health of one service in watchdog's status.json.
// Why: watchdog writes it and the ui reads it; one schema.
// From: Issue #870
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServiceHealth {
    // What: color: green, yellow, amber or red.
    // Why: the ui passes it through, never re-derives it.
    // From: PR #1858
    pub status: String,
    // What: raw health string of the container.
    // Why: the color alone does not say what is wrong.
    // From: Issue #1683 | PR #1858
    pub health: String,
    pub failures: u32,
}

// What: cache disk use in percent and its color.
// Why: the ui renders the color watchdog decided.
// From: PR #1858
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiskHealth {
    pub pct: u32,
    pub status: String,
}

// What: disk section of status.json; the cache volume.
// Why: one named field per volume keeps the schema stable.
// From: Issue #1683 | PR #1912
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiskInfo {
    pub cache: DiskHealth,
}

// What: the whole status.json document.
// Why: a map; its keys show whether HTTPS mode is off.
// From: Issue #870
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WatchdogStatus {
    pub updated: String,
    pub services: HashMap<String, ServiceHealth>,
    pub disk: DiskInfo,
    // What: the watchdog's check interval in seconds.
    // Why: the ui derives staleness; old files lack it.
    // From: Issue #1683 | PR #1858
    #[serde(default)]
    pub interval_secs: u64,
}

impl WatchdogStatus {
    // What: age beyond which the document counts as stale.
    // Why: cycles missed in a row; no interval is stale.
    // From: Issue #1683 | PR #1912
    pub fn stale_after(&self, cycles: u32) -> Duration {
        Duration::from_secs(self.interval_secs).saturating_mul(cycles)
    }
}

// What: operator-requested run state of a service.
// Why: the ui dock writes it, watchdog acts on it.
// From: Issue #1437
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DesiredRunState {
    Running,
    Stopped,
}

// What: desired-state.json; an absent key is no opinion.
// Why: a stale target must not fight a DHCP mode switch.
// From: Issue #1437
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DesiredState {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dhcp: Option<DesiredRunState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ntp: Option<DesiredRunState>,
}

impl DesiredState {
    // What: read the file; any failure means no opinion.
    // Why: a read glitch must never stop a caller's loop.
    // From: Issue #1683 | PR #1858
    pub fn read(path: &Path) -> Self {
        fs::read_to_string(path)
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default()
    }
}

// What: space figures of the filesystem holding a path.
// Why: watchdog reads use%, the ui resize check free KiB.
// From: Issue #1683 | PR #1858
pub struct Df {
    pub avail_kib: u64,
    pub used_pct: u32,
}

// What: figures from statvfs; None on any failure.
// Why: std has no statvfs; used percent rounds up.
// From: Issue #1683 | PR #1912
pub fn df(path: &Path) -> Option<Df> {
    let stat = rustix::fs::statvfs(path).ok()?;
    // What: used = blocks - free; total = used + avail.
    // Why: df counts reserved blocks as used, not as total.
    // From: Issue #1683 | PR #1912
    let used = stat.f_blocks.checked_sub(stat.f_bfree)?;
    let total = used.checked_add(stat.f_bavail)?;
    // What: no figures for a filesystem without blocks.
    // Why: a division by zero must not read as 0 percent.
    // From: Issue #1683 | PR #1912
    if total == 0 {
        return None;
    }
    Some(Df {
        avail_kib: stat.f_bavail.checked_mul(stat.f_frsize)? / 1024,
        used_pct: u32::try_from(used.checked_mul(100)?.div_ceil(total)).ok()?,
    })
}

// What: read one pipe to its end on its own thread.
// Why: a full pipe would block the program while we wait.
// From: Issue #1683 | PR #1912
fn drain<R: Read + Send + 'static>(
    pipe: Option<R>,
) -> std::sync::mpsc::Receiver<io::Result<Vec<u8>>> {
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let read = match pipe {
            Some(mut pipe) => pipe.read_to_end(&mut bytes).map(|_| bytes),
            None => Err(io::Error::other("pipe missing")),
        };
        // What: a closed channel means the caller gave up.
        // Why: the timeout path drops the receiver.
        // From: Issue #1683 | PR #1912
        match sender.send(read) {
            Ok(()) | Err(_) => {}
        }
    });
    receiver
}

// What: run a program; its stdout then stderr, or an error.
// Why: one program runner; a limit ends a hanging program.
// From: Issue #1683 | PR #1912
pub fn run_program(
    program: &str,
    args: &[&str],
    limit: Option<Duration>,
) -> Result<String, String> {
    let failed = |what: &str, e: &dyn std::fmt::Display| format!("{program}: {what}: {e}");
    // What: start it with no stdin and piped outputs.
    // Why: it must not wait for input; we capture both.
    // From: Issue #1683 | PR #1912
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("cannot run {program}: {e}"))?;
    // What: read both outputs on their own threads.
    // Why: one full pipe would block the program.
    // From: Issue #1683 | PR #1912
    let out = drain(child.stdout.take());
    let err = drain(child.stderr.take());
    // What: the deadline and limit of the program.
    // Why: the wait and the readers share one deadline.
    // From: Issue #1683 | PR #1912
    let deadline = limit.map(|limit| (std::time::Instant::now() + limit, limit));
    let status = match deadline {
        None => child.wait().map_err(|e| failed("cannot wait", &e))?,
        Some((deadline, limit)) => loop {
            if let Some(status) = child.try_wait().map_err(|e| failed("cannot wait", &e))? {
                break status;
            }
            if std::time::Instant::now() >= deadline {
                // What: readers end on their own.
                // Why: a grandchild may hold pipes.
                // From: Issue #1683 | PR #1912
                let killed = child.kill().map_err(|e| failed("cannot kill", &e));
                child.wait().map_err(|e| failed("cannot wait", &e))?;
                killed?;
                return Err(format!(
                    "{program} {}: timed out after {limit:?}, killed",
                    args.join(" ")
                ));
            }
            // What: poll the exit every 20 ms.
            // Why: std has no wait with a timeout.
            // From: Issue #1683 | PR #1912
            std::thread::sleep(Duration::from_millis(20));
        },
    };
    let mut text = String::new();
    for reader in [out, err] {
        // What: with a limit the pipes get the rest of it.
        // Why: a grandchild may hold a pipe after exit.
        // From: Issue #1683 | PR #1912
        let received = match deadline {
            None => reader
                .recv()
                .map_err(|_| failed("output reader", &"panicked")),
            Some((deadline, limit)) => reader
                .recv_timeout(deadline.saturating_duration_since(std::time::Instant::now()))
                .map_err(|e| match e {
                    std::sync::mpsc::RecvTimeoutError::Timeout => format!(
                        "{program} {}: output still open after exit, limit {limit:?} used up",
                        args.join(" ")
                    ),
                    std::sync::mpsc::RecvTimeoutError::Disconnected => {
                        failed("output reader", &"panicked")
                    }
                }),
        };
        let bytes = received?.map_err(|e| failed("cannot read output", &e))?;
        // What: append the output, stdout first.
        // Why: callers read the result stdout then stderr.
        // From: Issue #1683 | PR #1912
        text.push_str(&String::from_utf8_lossy(&bytes));
    }
    if status.success() {
        Ok(text)
    } else {
        Err(format!("{program} {}: {}", args.join(" "), text.trim()))
    }
}

// What: the --config-dir argument of a pdns program.
// Why: watchdog and subscriber name the config alike.
// From: Issue #1683 | PR #1912
pub fn pdns_config_dir_arg(dir: &str) -> String {
    format!("--config-dir={dir}")
}

// What: run pdnsutil on a pdns config dir; text or error.
// Why: both programs call pdnsutil through one function.
// From: Issue #1683 | PR #1912
pub fn pdnsutil(dir: &str, args: &[&str], limit: Option<Duration>) -> Result<String, String> {
    let config_dir = pdns_config_dir_arg(dir);
    let mut argv = vec![config_dir.as_str()];
    argv.extend_from_slice(args);
    run_program("pdnsutil", &argv, limit)
}

// What: send SIGTERM to one process.
// Why: std kills with SIGKILL; a daemon needs TERM.
// From: Issue #1683 | PR #1912
pub fn terminate(pid: u32) -> io::Result<()> {
    let pid = i32::try_from(pid)
        .ok()
        .and_then(rustix::process::Pid::from_raw)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid process id"))?;
    rustix::process::kill_process(pid, rustix::process::Signal::TERM).map_err(io::Error::from)
}

// What: set owner ids if given, then the mode.
// Why: the one owner change; lchown never follows a link.
// From: Issue #1683 | PR #1912
pub fn own(path: &Path, uid: Option<u32>, gid: Option<u32>, mode: Option<u32>) -> io::Result<()> {
    own_with(
        path,
        (uid, gid),
        mode,
        |(uid, gid)| std::os::unix::fs::lchown(path, uid, gid),
        |mode| fs::set_permissions(path, std::os::unix::fs::PermissionsExt::from_mode(mode)),
    )
}

// What: own on an open file; the name is only for messages.
// Why: the name could be swapped between open and chown.
// From: Issue #1683 | PR #1912
pub fn own_file(file: &fs::File, name: &Path, owner: Owner, mode: Option<u32>) -> io::Result<()> {
    own_with(
        name,
        owner,
        mode,
        |(uid, gid)| std::os::unix::fs::fchown(file, uid, gid),
        |mode| file.set_permissions(std::os::unix::fs::PermissionsExt::from_mode(mode)),
    )
}

// What: the one owner and mode logic for a path or a file.
// Why: own and own_file differ only in how they reach it.
// From: Issue #1683 | PR #1912
fn own_with(
    name: &Path,
    owner: Owner,
    mode: Option<u32>,
    chown: impl FnOnce(Owner) -> io::Result<()>,
    chmod: impl FnOnce(u32) -> io::Result<()>,
) -> io::Result<()> {
    let context = |e: io::Error| {
        io::Error::new(
            e.kind(),
            format!("cannot set owner or mode of {}: {e}", name.display()),
        )
    };
    // What: set the owner ids only when one is given.
    // Why: no id leaves the file's owner as it is.
    // From: Issue #1683 | PR #1912
    if owner.0.is_some() || owner.1.is_some() {
        chown(owner).map_err(context)?;
    }
    // What: set the mode only when one is given.
    // Why: no mode leaves the rights as they are.
    // From: Issue #1683 | PR #1912
    match mode {
        Some(mode) => chmod(mode).map_err(context),
        None => Ok(()),
    }
}

// What: regular files under root, never across mounts.
// Why: the one tree walk; no symlink is followed.
// From: Issue #1683 | PR #1912
pub fn files_under(root: &Path) -> io::Result<Vec<(PathBuf, fs::Metadata)>> {
    use std::os::unix::fs::MetadataExt as _;
    // What: remember the device id of the root.
    // Why: a mount below the root is not part of the scan.
    // From: Issue #1683 | PR #1912
    let dev = fs::symlink_metadata(root)?.dev();
    let (mut files, mut dirs) = (Vec::new(), vec![root.to_path_buf()]);
    while let Some(dir) = dirs.pop() {
        // What: skip a directory gone since listing.
        // Why: cache and logs change during a scan.
        // From: Issue #1683 | PR #1912
        let entries = match fs::read_dir(&dir) {
            Err(e) if e.kind() == io::ErrorKind::NotFound && dir != root => continue,
            other => other?,
        };
        for entry in entries {
            let path = entry?.path();
            // What: an entry gone since listing is skipped
            // Why: cache and logs change during a scan
            // From: Issue #1683 | PR #1912
            let meta = match fs::symlink_metadata(&path) {
                Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
                other => other?,
            };
            // What: skip an entry on another device.
            // Why: the scan must not cross into a mount.
            // From: Issue #1683 | PR #1912
            if meta.dev() != dev {
                continue;
            }
            // What: walk dirs, collect regular files.
            // Why: a link or device node is no cache file.
            // From: Issue #1683 | PR #1912
            if meta.is_dir() {
                dirs.push(path);
            } else if meta.is_file() {
                files.push((path, meta));
            }
        }
    }
    Ok(files)
}

// What: key type, subject and days of one certificate.
// Why: CA and leaf share the openssl request flags.
// From: Issue #1683 | PR #1912
pub struct CertSpec<'a> {
    pub key_type: &'a str,
    pub subject: &'a str,
    pub days: &'a str,
}

// What: create a self-signed CA key and certificate.
// Why: one place owns the openssl CA request flags.
// From: Issue #1683 | PR #1912
pub fn openssl_ca(key: &Path, crt: &Path, spec: &CertSpec) -> Result<(), String> {
    let (key, crt) = (key.display().to_string(), crt.display().to_string());
    run_program(
        "openssl",
        &[
            "req",
            "-new",
            "-newkey",
            spec.key_type,
            "-days",
            spec.days,
            "-nodes",
            "-x509",
            "-subj",
            spec.subject,
            "-keyout",
            &key,
            "-out",
            &crt,
        ],
        None,
    )
    .map(|_| ())
}

// What: the CA files that sign a leaf.
// Why: openssl needs certificate, key and serial file.
// From: Issue #1683 | PR #1912
pub struct CaFiles<'a> {
    pub crt: &'a Path,
    pub key: &'a Path,
    pub serial: &'a Path,
}

// What: sign one leaf; csr and ext are scratch files.
// Why: the one openssl leaf signing; the caller cleans up.
// From: Issue #1683 | PR #1912
pub fn openssl_leaf(
    ca: &CaFiles,
    (key, crt): (&Path, &Path),
    (csr, ext): (&Path, &Path),
    san: &str,
    spec: &CertSpec,
) -> Result<(), String> {
    write_file(
        ext,
        format!("subjectAltName={san}\n").as_bytes(),
        0o600,
        Place::Replace,
    )
    .map_err(|e| format!("cannot write {}: {e}", ext.display()))?;
    let path = |p: &Path| p.display().to_string();
    let (key, crt, csr, ext) = (path(key), path(crt), path(csr), path(ext));
    run_program(
        "openssl",
        &[
            "req",
            "-new",
            "-newkey",
            spec.key_type,
            "-nodes",
            "-subj",
            spec.subject,
            "-keyout",
            &key,
            "-out",
            &csr,
        ],
        None,
    )?;
    run_program(
        "openssl",
        &[
            "x509",
            "-req",
            "-days",
            spec.days,
            "-in",
            &csr,
            "-CA",
            &path(ca.crt),
            "-CAkey",
            &path(ca.key),
            "-CAserial",
            &path(ca.serial),
            "-extfile",
            &ext,
            "-out",
            &crt,
        ],
        None,
    )
    .map(|_| ())
}

// What: openssl x509 -noout output for one certificate.
// Why: the one certificate read; the CA print and SAN read.
// From: Issue #1683 | PR #1912
pub fn openssl_x509(crt: &Path, args: &[&str]) -> Result<String, String> {
    let crt = crt.display().to_string();
    run_program(
        "openssl",
        &[&["x509", "-noout"], args, &["-in", &crt]].concat(),
        None,
    )
}

// What: constant-time equality of two secrets.
// Why: no hash; the loop runs over the expected length.
// From: Issue #1683 | PR #1912
pub fn ct_eq(presented: &str, expected: &str) -> bool {
    let (presented, expected) = (presented.as_bytes(), expected.as_bytes());
    // What: compare every expected byte, never stop early.
    // Why: the run time must not reveal the first mismatch.
    // From: Issue #1683 | PR #1912
    let mut same = Choice::from(1);
    for (i, want) in expected.iter().enumerate() {
        same &= presented.get(i).copied().unwrap_or(!want).ct_eq(want);
    }
    // What: also require equal length.
    // Why: a longer input with the same prefix must fail.
    // From: Issue #1683 | PR #1912
    bool::from(same & (presented.len() as u64).ct_eq(&(expected.len() as u64)))
}

// What: nanoseconds since the epoch; 0 for a broken clock.
// Why: ids and temp names need unique, ordered stamps.
// From: Issue #1683 | PR #1858
pub fn unix_nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}

// What: seconds since the epoch; 0 for a broken clock.
// Why: callers refuse to issue anything from 1970.
// From: Issue #1683 | PR #1858
pub fn unix_secs() -> u64 {
    (unix_nanos() / 1_000_000_000) as u64
}

// What: a new empty directory under the temp dir.
// Why: tests of several crates need one scratch path.
// From: Issue #1683 | PR #1858
pub fn unique_temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "lancache-ng-test-{tag}-{}-{}",
        std::process::id(),
        unix_nanos()
    ));
    fs::create_dir_all(&dir).expect("scratch directory");
    dir
}

// What: HTTP client times for tests, 7 s each.
// Why: tests of several crates build an http_client.
// From: Issue #1683 | PR #1912
pub fn test_http_env(key: &str) -> Option<String> {
    [
        "HTTP_CLIENT_TIMEOUT",
        "HTTP_POOL_IDLE_TIMEOUT",
        "HTTP_TCP_KEEPALIVE",
    ]
    .contains(&key)
    .then(|| "7".to_string())
}

// What: a local HTTP server that answers canned replies.
// Why: client code is tested without a network or Docker.
// From: Issue #1683 | PR #1858
pub fn serve_canned(
    replies: Vec<(u16, Vec<u8>)>,
) -> (String, std::thread::JoinHandle<Vec<String>>) {
    use std::io::Read;
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a free local port");
    listener.set_nonblocking(true).expect("non-blocking accept");
    let base = format!("http://{}", listener.local_addr().expect("local address"));
    let handle = std::thread::spawn(move || {
        let mut seen = Vec::new();
        for (status, body) in replies {
            // What: give up when no client comes.
            // Why: a skipped call fails the test; no hang.
            // From: Issue #1683 | PR #1858
            let deadline = std::time::Instant::now() + Duration::from_secs(3);
            let mut stream = loop {
                match listener.accept() {
                    Ok((stream, _)) => break stream,
                    Err(_) if std::time::Instant::now() < deadline => {
                        std::thread::sleep(Duration::from_millis(5));
                    }
                    Err(_) => return seen,
                }
            };
            stream.set_nonblocking(false).expect("blocking stream");
            let mut request = Vec::new();
            let mut byte = [0u8; 1];
            while !request.ends_with(b"\r\n\r\n") {
                if stream.read(&mut byte).unwrap_or(0) == 0 {
                    break;
                }
                request.push(byte[0]);
            }
            let head = String::from_utf8_lossy(&request).to_lowercase();
            let length = head
                .lines()
                .find_map(|line| line.strip_prefix("content-length: "))
                .and_then(|n| n.trim().parse::<usize>().ok())
                .unwrap_or(0);
            let mut payload = vec![0u8; length];
            let _ = stream.read_exact(&mut payload);
            request.extend_from_slice(&payload);
            seen.push(String::from_utf8_lossy(&request).into_owned());
            let reply = format!(
                "HTTP/1.1 {status} Canned\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            let _ = stream.write_all(reply.as_bytes());
            let _ = stream.write_all(&body);
        }
        seen
    });
    (base, handle)
}

// What: print a FATAL start error with its tag, exit 1.
// Why: every service fails closed at start the same way.
// From: Issue #1683 | PR #1858
pub fn die(tag: &str, message: &str) -> ! {
    eprintln!("[{tag}] FATAL: {message}");
    std::process::exit(1);
}

// What: whole seconds above 0 of one key from a reader.
// Why: a zero wait would end every call at once.
// From: Issue #1683 | PR #1912
pub fn need_secs(
    get: &dyn Fn(&str) -> Option<String>,
    key: &'static str,
) -> Result<Duration, String> {
    config::uint(get, key, 1, u64::MAX).map(Duration::from_secs)
}

// What: whole milliseconds above 0 of one _MS key.
// Why: sub-second waits take the same Uint rule.
// From: Issue #1683 | PR #1912
pub fn need_millis(
    get: &dyn Fn(&str) -> Option<String>,
    key: &'static str,
) -> Result<Duration, String> {
    config::uint(get, key, 1, u64::MAX).map(Duration::from_millis)
}

// What: retry delays: start, then doubled up to max.
// Why: ui, nats-subscriber and watchdog back off alike.
// From: Issue #1683 | PR #1912
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Backoff {
    pub start: Duration,
    pub max: Duration,
}

impl Backoff {
    // What: RETRY_BACKOFF_START and _MAX from a reader.
    // Why: the SOT owns both; a start above max fails.
    // From: Issue #1683 | PR #1912
    pub fn load(get: &dyn Fn(&str) -> Option<String>) -> Result<Self, String> {
        let start = need_secs(get, "RETRY_BACKOFF_START")?;
        let max = need_secs(get, "RETRY_BACKOFF_MAX")?;
        if start > max {
            return Err(format!(
                "RETRY_BACKOFF_START {start:?} is above RETRY_BACKOFF_MAX {max:?}"
            ));
        }
        Ok(Self { start, max })
    }

    // What: the delay after this one: doubled, at most max.
    // Why: a failing call must not spin nor wait forever.
    // From: Issue #1683 | PR #1912
    pub fn next(&self, delay: Duration) -> Duration {
        delay.saturating_mul(2).min(self.max)
    }
}

// What: the general HTTP client of several services.
// Why: one timeout and pool setting, from the SOT.
// From: Issue #1683 | PR #1912
pub fn http_client(get: &dyn Fn(&str) -> Option<String>) -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(need_secs(get, "HTTP_CLIENT_TIMEOUT")?)
        .pool_idle_timeout(need_secs(get, "HTTP_POOL_IDLE_TIMEOUT")?)
        .tcp_keepalive(need_secs(get, "HTTP_TCP_KEEPALIVE")?)
        .build()
        .map_err(|e| format!("HTTP client: {e}"))
}

// What: an error and every cause below it, one line.
// Why: reqwest hides the TLS or socket cause in source().
// From: Issue #1683 | PR #1912
pub fn error_chain(error: &dyn std::error::Error) -> String {
    let mut text = error.to_string();
    let mut cause = error.source();
    while let Some(inner) = cause {
        text.push_str(": ");
        text.push_str(&inner.to_string());
        cause = inner.source();
    }
    text
}

// What: Ok when a client's GET of a URL answers 2xx.
// Why: http and https health probes judge the same way.
// From: Issue #1683 | PR #1912
async fn expect_success(client: &reqwest::Client, url: &str) -> Result<(), String> {
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

// What: Ok when a plain-http health URL answers 2xx.
// Why: healthchecks run in the binary; no curl, no shell.
// From: Issue #1683 | PR #1912
pub async fn probe_health(url: &str, timeout: Duration) -> Result<(), String> {
    if url.starts_with("https://") {
        return Err(format!("{url}: an https health URL needs probe_health_tls"));
    }
    let client = reqwest::Client::builder()
        .timeout(timeout)
        .no_proxy()
        .build()
        .map_err(|e| format!("health client: {e}"))?;
    expect_success(&client, url).await
}

// What: Ok when an https health URL answers 2xx.
// Why: the stack CA is the only trust anchor.
// From: Issue #1683 | PR #1912
pub async fn probe_health_tls(
    url: &str,
    ca_pem: &[u8],
    name: &str,
    timeout: Duration,
) -> Result<(), String> {
    let parsed = reqwest::Url::parse(url).map_err(|e| format!("{url}: {e}"))?;
    let ip: std::net::IpAddr = parsed
        .host_str()
        .ok_or_else(|| format!("{url}: no host"))?
        .parse()
        .map_err(|e| format!("{url}: the host is no IP address: {e}"))?;
    let port = parsed
        .port_or_known_default()
        .ok_or_else(|| format!("{url}: no port"))?;
    let ca = reqwest::Certificate::from_pem(ca_pem).map_err(|e| format!("CA certificate: {e}"))?;
    let client = reqwest::Client::builder()
        .timeout(timeout)
        .no_proxy()
        .tls_certs_only([ca])
        .resolve(name, std::net::SocketAddr::new(ip, port))
        .build()
        .map_err(|e| format!("health client: {e}"))?;
    expect_success(&client, &format!("https://{name}:{port}{}", parsed.path())).await
}

// What: one lancache.dns.record message on NATS.
// Why: ui and subscriber publish it; subscriber reads it.
// From: Issue #1683 | PR #1858
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DnsRecord {
    pub action: String,
    pub zone: String,
    pub name: String,
    #[serde(rename = "type")]
    pub record_type: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ttl: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub records: Option<Vec<HashMap<String, Value>>>,
}

// What: one lancache.dns.flush message on NATS.
// Why: only domain is required; the rest asks to confirm.
// From: Issue #1095
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FlushRequest {
    pub domain: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub zone: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub record_type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_content: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_ttl: Option<i32>,
}

// What: known-good snapshots of one JSON document type.
// Why: Kea config and DNS zones share one store and format.
// From: Issue #628
pub struct SnapshotStore {
    pub root: PathBuf,
    file: String,
    service: &'static str,
}

// What: marker prefix of a snapshot still being written.
// Why: listing must never show a half-written snapshot.
// From: Issue #1683 | PR #1858
const STAGING: &str = ".staging.";

// What: true for a purely numeric snapshot id.
// Why: old shell ids carry T and a dot; none is readable.
// From: Issue #1683 | PR #1912
fn is_snapshot_id(name: &str) -> bool {
    !name.is_empty() && name.bytes().all(|b| b.is_ascii_digit())
}

// What: remove a failed staging dir; its error joins e.
// Why: AG-INT-002: a left staging dir is named, not hidden.
// From: Issue #1683 | PR #1912
fn drop_staging(staging: &Path, e: anyhow::Error) -> anyhow::Error {
    match fs::remove_dir_all(staging) {
        Err(c) if c.kind() != std::io::ErrorKind::NotFound => {
            e.context(format!("staging {} not removed: {c}", staging.display()))
        }
        _ => e,
    }
}

impl SnapshotStore {
    // What: a store of `file` payloads under `root`.
    // Why: `service` names the log line vocabulary.
    // From: Issue #1683 | PR #1858
    pub fn new(root: PathBuf, file: impl Into<String>, service: &'static str) -> Self {
        Self {
            root,
            file: file.into(),
            service,
        }
    }

    // What: one greppable lifecycle line on stderr.
    // Why: operators search the logs for this vocabulary.
    // From: Issue #1683 | PR #1858
    pub fn log(&self, level: &str, message: &str) {
        eprintln!("[known-good-snapshot][{}][{level}] {message}", self.service);
    }

    // What: snapshot ids, oldest first; none without root.
    // Why: fixed-width ids make name order chronological.
    // From: Issue #1683 | PR #1858
    pub fn ids(&self) -> io::Result<Vec<String>> {
        if !self.root.is_dir() {
            return Ok(Vec::new());
        }
        let mut ids = Vec::new();
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            // What: count dirs with a numeric id, payload.
            // Why: staging or empty dirs are no target.
            // From: Issue #1683 | PR #1912
            let complete = entry.file_type()?.is_dir()
                && is_snapshot_id(&name)
                && entry.path().join(&self.file).is_file();
            if complete {
                ids.push(name);
            }
        }
        ids.sort();
        Ok(ids)
    }

    // What: payload of snapshot `id`; only digit ids pass.
    // Why: the id joins onto a path, so it must be safe.
    // From: Issue #1683 | PR #1858
    pub fn read(&self, id: &str) -> anyhow::Result<Value> {
        anyhow::ensure!(
            is_snapshot_id(id),
            "rejected known-good snapshot id {id:?}: must be a purely numeric snapshot id"
        );
        let raw = fs::read_to_string(self.root.join(id).join(&self.file))
            .with_context(|| format!("cannot read known-good snapshot {id}"))?;
        serde_json::from_str(&raw)
            .with_context(|| format!("known-good snapshot {id} is not valid JSON"))
    }

    // What: write `data` as a new snapshot, then prune.
    // Why: staging plus rename; a crash leaves no partial.
    // From: Issue #1683 | PR #1858
    pub fn create(&self, data: &Value, keep_n: u32) -> anyhow::Result<String> {
        let id = format!("{:020}", unix_nanos());
        // What: write into a staging dir under the root.
        // Why: only the rename makes a snapshot visible.
        // From: Issue #1683 | PR #1912
        let staging = self.root.join(format!("{STAGING}{id}"));
        fs::create_dir_all(&staging)
            .with_context(|| format!("cannot create staging directory {}", staging.display()))?;
        let finish = || -> anyhow::Result<()> {
            fs::write(staging.join(&self.file), serde_json::to_vec_pretty(data)?)?;
            Ok(fs::rename(&staging, self.root.join(&id))?)
        };
        if let Err(e) = finish() {
            let e = e.context(format!("failed to write known-good snapshot {id}"));
            return Err(drop_staging(&staging, e));
        }
        self.log("CREATE", &format!("created known-good snapshot {id}"));
        // What: a failed prune is logged only.
        // Why: the snapshot is written; prune is upkeep.
        // From: Issue #1683 | PR #1912
        if let Err(e) = self.prune(keep_n) {
            self.log(
                "FATAL",
                &format!("prune after creating snapshot {id} failed: {e}"),
            );
        }
        Ok(id)
    }

    // What: delete the oldest snapshots beyond keep_n.
    // Why: a failed removal is logged, not a write failure.
    // From: Issue #1683 | PR #1858
    pub fn prune(&self, keep_n: u32) -> io::Result<()> {
        // What: refuse a retention of zero.
        // Why: zero would delete every known-good snapshot.
        // From: Issue #1683 | PR #1912
        if keep_n == 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "keep_n must be at least 1; the SOT owns the default",
            ));
        }
        let ids = self.ids()?;
        let excess = ids.len().saturating_sub(keep_n as usize);
        for id in ids.into_iter().take(excess) {
            match fs::remove_dir_all(self.root.join(&id)) {
                Ok(()) => self.log(
                    "PRUNE",
                    &format!("pruned known-good snapshot {id} (retention={keep_n})"),
                ),
                Err(e) => self.log("FATAL", &format!("failed to prune snapshot {id}: {e}")),
            }
        }
        // What: convert old shell snapshots after prune.
        // Why: an update keeps its rollback targets.
        // From: Issue #1683 | PR #1912
        self.adopt_legacy();
        Ok(())
    }

    // What: turn old shell-format snapshots into new ones.
    // Why: an update keeps rollback targets (AG-OP-007).
    // From: Issue #1683 | PR #1912
    pub fn adopt_legacy(&self) {
        let Ok(entries) = fs::read_dir(&self.root) else {
            return;
        };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            // What: old = a dir with a non-numeric, non-staging name.
            // Why: staging dirs and new snapshots stay untouched.
            // From: Issue #1683 | PR #1912
            let old = entry.file_type().is_ok_and(|t| t.is_dir())
                && !name.starts_with(STAGING)
                && !is_snapshot_id(&name);
            if !old {
                continue;
            }
            match self.adopt_one(&entry.path(), &name) {
                Ok(id) => self.log("ADOPT", &format!("old snapshot {name} is now {id}")),
                Err(e) => self.log("FATAL", &format!("cannot adopt old snapshot {name}: {e:#}")),
            }
        }
    }

    // What: one old snapshot dir as a new snapshot.
    // Why: its files become the {name: text} payload.
    // From: Issue #1683 | PR #1912
    fn adopt_one(&self, dir: &Path, name: &str) -> anyhow::Result<String> {
        let nanos = legacy_id_nanos(name)
            .with_context(|| format!("{name} is no old snapshot id (YYYYmmddTHHMMSS.N)"))?;
        let id = format!("{nanos:020}");
        // What: refuse an id that already exists.
        // Why: the rename must not replace a snapshot.
        // From: Issue #1683 | PR #1912
        anyhow::ensure!(
            !self.root.join(&id).exists(),
            "a snapshot {id} exists already"
        );
        let mut set = serde_json::Map::new();
        for file in fs::read_dir(dir)? {
            let file = file?;
            if file.file_type()?.is_file() {
                let text = fs::read_to_string(file.path())
                    .with_context(|| format!("cannot read {}", file.path().display()))?;
                set.insert(
                    file.file_name().to_string_lossy().into_owned(),
                    Value::String(text),
                );
            }
        }
        // What: refuse an old snapshot without files.
        // Why: an empty payload hides a broken rollback.
        // From: Issue #1683 | PR #1912
        anyhow::ensure!(!set.is_empty(), "{name} holds no file");
        let staging = self.root.join(format!("{STAGING}{id}"));
        fs::create_dir_all(&staging)?;
        let finish = || -> anyhow::Result<()> {
            fs::write(
                staging.join(&self.file),
                serde_json::to_vec_pretty(&Value::Object(set))?,
            )?;
            fs::rename(&staging, self.root.join(&id))?;
            // What: remove the old dir after the new one.
            // Why: a crash in between keeps the old copy.
            // From: Issue #1683 | PR #1912
            Ok(fs::remove_dir_all(dir)?)
        };
        finish().map_err(|e| drop_staging(&staging, e))?;
        Ok(id)
    }
}

// What: epoch nanoseconds of an old id (UTC).
// Why: old ids are date +%Y%m%dT%H%M%S.%N output.
// From: Issue #1683 | PR #1912
fn legacy_id_nanos(name: &str) -> Option<u128> {
    let (date, rest) = name.split_once('T')?;
    let (time, frac) = rest.split_once('.')?;
    let digits =
        |t: &str, n: usize| (t.len() == n && is_snapshot_id(t)).then(|| t.parse::<i64>().ok())?;
    let (y, m, d) = (
        digits(&date[..4.min(date.len())], 4)?,
        digits(date.get(4..6)?, 2)?,
        digits(date.get(6..)?, 2)?,
    );
    let (hh, mm, ss) = (
        digits(time.get(..2)?, 2)?,
        digits(time.get(2..4)?, 2)?,
        digits(time.get(4..)?, 2)?,
    );
    // What: refuse a malformed date, time or fraction.
    // Why: a wrong id must not turn into a wrong time.
    // From: Issue #1683 | PR #1912
    if date.len() != 8 || frac.is_empty() || frac.len() > 9 || !is_snapshot_id(frac) {
        return None;
    }
    // What: refuse month, day or clock fields out of range.
    // Why: days-from-civil gives no error for them.
    // From: Issue #1683 | PR #1912
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) || hh > 23 || mm > 59 || ss > 60 {
        return None;
    }
    // What: days since the epoch for a civil date.
    // Why: Hinnant's days-from-civil, proleptic Gregorian.
    // From: Issue #1683 | PR #1912
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    let secs = u128::try_from(days * 86_400 + hh * 3600 + mm * 60 + ss).ok()?;
    let nanos: u128 = format!("{frac:0<9}").parse().ok()?;
    Some(secs * 1_000_000_000 + nanos)
}

// What: creation time (Unix seconds) encoded in an id.
// Why: the ui shows it; ids are epoch nanoseconds.
// From: Issue #1683 | PR #1858
pub fn snapshot_created_unix(id: &str) -> Option<u64> {
    Some((id.parse::<u128>().ok()? / 1_000_000_000) as u64)
}

// What: true for empty or a checked-in secret placeholder.
// Why: one rule for all secrets; any shape counts.
// From: Issue #967
pub fn is_placeholder(value: &str) -> bool {
    // What: lowercase; turn dashes to underscores.
    // Why: CHANGE-ME and change_me are one placeholder.
    // From: Issue #1683 | PR #1912
    let normalized = value.to_lowercase().replace('-', "_");
    normalized.is_empty()
        || normalized.contains("change_me")
        || normalized.starts_with("changeme")
        || normalized.starts_with("your_")
        || normalized.ends_with("_here")
        || (normalized.starts_with("lancache_") && normalized.ends_with("_secret"))
        || (value.starts_with('<') && value.ends_with('>'))
}

// What: how write_file treats a file that already exists.
// Why: secrets are created once; settings are replaced.
// From: PR #1858
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Place {
    Replace,
    Exclusive,
}

// What: new owner of a written file; None leaves a field.
// Why: root-started services hand files to a runtime user.
// From: Issue #1683 | PR #1858
pub type Owner = (Option<u32>, Option<u32>);

// What: write a whole file; readers see all of it or none.
// Why: one write path for secrets, settings and status.
// From: PR #1858
pub fn write_file(path: &Path, contents: &[u8], mode: u32, place: Place) -> io::Result<()> {
    write_file_as(path, contents, mode, place, None)
}

// What: write_file that also sets the owner before placing.
// Why: the file must never be visible with the wrong owner.
// From: Issue #1683 | PR #1858
pub fn write_file_as(
    path: &Path,
    contents: &[u8],
    mode: u32,
    place: Place,
    owner: Option<Owner>,
) -> io::Result<()> {
    // What: create the missing parent directories.
    // Why: a first start finds no state directory yet.
    // From: Issue #1683 | PR #1858
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        fs::create_dir_all(parent)?;
    }
    // What: take the file name of the target.
    // Why: the temp name derives from it; no name, no file.
    // From: Issue #1683 | PR #1912
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no file name"))?;
    let stamp = unix_nanos();
    // What: a unique temp name beside the target.
    // Why: link and rename need the same filesystem.
    // From: Issue #1683 | PR #1912
    let tmp = path.with_file_name(format!(
        ".{}.tmp-{}-{stamp}",
        name.to_string_lossy(),
        std::process::id()
    ));
    // What: create the temp file with its final mode.
    // Why: the content is never visible with wider rights.
    // From: Issue #1683 | PR #1912
    let placed = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .open(&tmp)
        .and_then(|mut file| {
            file.write_all(contents)?;
            // What: set the owner on the open file.
            // Why: the name could be swapped before chown.
            // From: Issue #1683 | PR #1912
            if let Some(owner) = owner {
                own_file(&file, &tmp, owner, None)?;
            }
            // What: flush the content before placing.
            // Why: a crash must not leave an empty target.
            // From: Issue #1683 | PR #1912
            file.sync_all()
        })
        .and_then(|()| match place {
            // What: link the temp file to the final name.
            // Why: a link fails if the name exists; no gap.
            // From: Issue #1683 | PR #1858
            Place::Exclusive => fs::hard_link(&tmp, path),
            // What: a busy target is rewritten in place.
            // Why: a file bind mount refuses a rename.
            // From: PR #1858
            Place::Replace => match fs::rename(&tmp, path) {
                Err(e) if e.kind() == io::ErrorKind::ResourceBusy => {
                    let mut file = OpenOptions::new().write(true).truncate(true).open(path)?;
                    file.write_all(contents)?;
                    file.sync_all()
                }
                other => other,
            },
        });
    // What: drop the temp name; absent after a rename.
    // Why: the write result stays the outcome.
    // From: PR #1858
    let _ = fs::remove_file(&tmp);
    placed
}

// What: replace a file only when its bytes differ.
// Why: reruns write nothing; mode and owner still converge.
// From: Issue #1683 | PR #1858
pub fn write_if_changed(
    path: &Path,
    contents: &[u8],
    mode: u32,
    owner: Option<Owner>,
) -> io::Result<bool> {
    // What: compare bytes; unreadable = changed.
    // Why: a missing or broken file must be written again.
    // From: Issue #1683 | PR #1912
    let changed = fs::read(path).ok().as_deref() != Some(contents);
    if changed {
        write_file_as(path, contents, mode, Place::Replace, owner)?;
    }
    // What: converge mode and owner on unchanged files too.
    // Why: an old install may carry other rights.
    // From: Issue #1683 | PR #1858
    let (uid, gid) = owner.unwrap_or((None, None));
    own(path, uid, gid, Some(mode))?;
    Ok(changed)
}

// What: read a persisted secret, else create it once.
// Why: restarts must not rotate it; a bad file fails.
// From: Issue #871
pub fn load_or_create<T>(
    path: &Path,
    create: impl FnOnce() -> (String, T),
    parse: impl Fn(&str) -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    match fs::read_to_string(path) {
        // What: parse the stored text, trimmed.
        // Why: the trailing newline is no part of a secret.
        // From: Issue #1683 | PR #1912
        Ok(contents) => parse(contents.trim()),
        Err(err) if err.kind() == io::ErrorKind::NotFound => {
            let (text, value) = create();
            match write_file(path, text.as_bytes(), 0o600, Place::Exclusive) {
                Ok(()) => Ok(value),
                // What: another start created it first.
                // Why: the first writer's secret wins.
                // From: PR #1858
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                    parse(fs::read_to_string(path)?.trim())
                }
                Err(e) => Err(e.into()),
            }
        }
        // What: every other read error fails the call.
        // Why: an unreadable file must not rotate it.
        // From: Issue #1683 | PR #1912
        Err(err) => Err(err.into()),
    }
}

// What: shared-secret file name of a variable (A_B -> a-b).
// Why: every secret name derives from its variable name.
// From: Issue #858
pub fn shared_secret_file_name(var: &str) -> String {
    var.to_ascii_lowercase().replace('_', "-")
}

// What: a real env value, else its shared-secret file.
// Why: backends write the file; the ui only reads it.
// From: Issue #858
pub fn shared_secret(
    dir: &str,
    var: &str,
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<String, String> {
    // What: a real env value wins over the file.
    // Why: an operator's explicit value is intended.
    // From: Issue #1683 | PR #1912
    let configured = env(var).unwrap_or_default();
    if !is_placeholder(&configured) {
        return Ok(configured);
    }
    let path = Path::new(dir).join(shared_secret_file_name(var));
    match fs::read_to_string(&path) {
        // What: drop newlines from the file text.
        // Why: the file ends in a newline; secret has none.
        // From: Issue #1683 | PR #1912
        Ok(value) => Ok(value.replace('\n', "")),
        // What: a missing file gives an empty secret.
        // Why: the backend writes it later.
        // From: Issue #1683 | PR #1912
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(String::new()),
        Err(e) => Err(format!("cannot read {var} from {}: {e}", path.display())),
    }
}

// What: 32 random bytes as hex; the usual secret form.
// Why: tokens, keys and passwords share one generator.
// From: Issue #858
pub fn hex32() -> String {
    hex::encode(rand::random::<[u8; 32]>())
}

// What: lowercase hex SHA-256 of a text.
// Why: bounded, stable file names from long host names.
// From: Issue #1683
pub fn sha256_hex(text: &str) -> String {
    hex::encode(Sha256::digest(text.as_bytes()))
}

// What: header and path of the netdata alarm webhook.
// Why: the sender and the ui must spell both the same way.
// From: Issue #858
pub const ALARM_TOKEN_HEADER: &str = "X-Netdata-Alarm-Token";
pub const ALARM_INGEST_PATH: &str = "/api/netdata-alarms";

// What: one alarm; the names are custom_sender's variables.
// Why: the sender script is rendered from these fields.
// From: Issue #849
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct NetdataAlarm {
    pub unique_id: i64,
    pub alarm_id: i64,
    pub event_id: i64,
    pub when: i64,
    pub name: String,
    pub chart: String,
    pub host: String,
    pub status: String,
    pub old_status: String,
    pub value_string: String,
    pub units: String,
    pub info: String,
    pub duration: i64,
}

// What: first-writer-wins read-or-create of a secret file.
// Why: independent starters must not split-brain a secret.
// From: Issue #858
pub fn resolve_shared_secret(
    dir: &Path,
    name: &str,
    current: &str,
    gid: u32,
    make: fn() -> String,
) -> Result<String, String> {
    let file = dir.join(name);
    // What: the file text without newlines; empty is none.
    // Why: an empty file counts as no secret yet.
    // From: Issue #1683 | PR #1912
    let on_disk = || {
        fs::read_to_string(&file)
            .ok()
            .map(|v| v.replace('\n', ""))
            .filter(|v| !v.is_empty())
    };
    // What: reuse the file when it fits the current value.
    // Why: the first writer's secret must stay.
    // From: Issue #1683 | PR #1912
    if let Some(existing) = on_disk()
        && (current.is_empty() || existing == current)
    {
        return Ok(existing);
    }
    // What: a configured value survives a failed write.
    // Why: only a disagreeing file makes it unsafe to use.
    // From: PR #1775
    let keep_current = || {
        let conflict = match on_disk() {
            Some(v) => v != current,
            None => file.exists(),
        };
        !current.is_empty() && !conflict
    };
    // What: generate a value only when none is configured.
    // Why: a configured value is the operator's choice.
    // From: Issue #1683 | PR #1912
    let value = if current.is_empty() {
        make()
    } else {
        current.to_string()
    };
    // What: create exclusively for a new value.
    // Why: two starters must not both create a new secret.
    // From: Issue #1683 | PR #1912
    let place = if current.is_empty() {
        Place::Exclusive
    } else {
        Place::Replace
    };
    // What: try with the reader group, then without it.
    // Why: some volumes refuse chgrp; 0640 stays anyway.
    // From: Issue #1683 | PR #1912
    let written = write_file_as(
        &file,
        value.as_bytes(),
        0o640,
        place,
        Some((None, Some(gid))),
    )
    .or_else(|_| write_file_as(&file, value.as_bytes(), 0o640, place, None));
    if written.is_ok() {
        return Ok(value);
    }
    // What: after a lost race, take the winner's file.
    // Why: only one secret may exist for all starters.
    // From: Issue #1683 | PR #1912
    if current.is_empty()
        && let Some(existing) = on_disk()
    {
        return Ok(existing);
    }
    // What: fall back to the configured value if safe.
    // Why: a failed write must not stop a valid setup.
    // From: Issue #1683 | PR #1912
    if keep_current() {
        return Ok(current.to_string());
    }
    Err(format!("cannot place {}", file.display()))
}

// What: N-byte hex secret, persisted with load_or_create.
// Why: master and session secrets share this one form.
// From: PR #1858
pub fn load_or_create_hex<const N: usize>(path: &Path) -> anyhow::Result<[u8; N]> {
    load_or_create(
        path,
        || {
            let secret: [u8; N] = rand::random();
            (hex::encode(secret), secret)
        },
        |text| {
            hex::decode(text)?.try_into().map_err(|_| {
                anyhow::anyhow!(
                    "secret at {} must be exactly {N} bytes encoded as hex",
                    path.display()
                )
            })
        },
    )
}

// What: why a Docker call failed.
// Why: callers act on 404 and timeouts, not message text.
// From: Issue #1683 | PR #1858
#[derive(Debug)]
pub enum DockerError {
    Status(u16),
    Timeout,
    Transport(String),
}

impl std::fmt::Display for DockerError {
    // What: render a DockerError as one line.
    // Why: logs and watchdog output show a short reason.
    // From: Issue #1683 | PR #1858
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Status(code) => write!(f, "Docker answered HTTP {code}"),
            Self::Timeout => write!(f, "Docker call timed out"),
            Self::Transport(message) => write!(f, "Docker call failed: {message}"),
        }
    }
}

impl std::error::Error for DockerError {}

// What: Docker log stream text without frame headers.
// Why: a container without a tty multiplexes its streams.
// From: Issue #1683 | PR #1858
fn log_text(mut bytes: &[u8]) -> String {
    let mut text = String::new();
    // What: cut frames of 8 byte header, payload.
    // Why: the header holds stream id and size.
    // From: Issue #1683 | PR #1912
    while bytes.len() >= 8 {
        let size = u32::from_be_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]) as usize;
        let end = bytes.len().min(8usize.saturating_add(size));
        // What: keep stdout (1) and stderr (2) frames only.
        // Why: other stream ids carry no log text.
        // From: Issue #1683 | PR #1912
        if matches!(bytes[0], 1 | 2) {
            text.push_str(&String::from_utf8_lossy(&bytes[8..end]));
        }
        bytes = &bytes[end..];
    }
    text
}

// What: client of PowerDNS's HTTP API with the API key.
// Why: ui, watchdog and nats-subscriber share it.
// From: Issue #1683 | PR #1912
pub struct PowerDns {
    http: reqwest::Client,
    api_key: String,
}

impl PowerDns {
    // What: a client over an HTTP client and the API key.
    // Why: the key is read once by the service's owner.
    // From: Issue #1683 | PR #1858
    pub fn new(http: reqwest::Client, api_key: String) -> Self {
        Self { http, api_key }
    }

    // What: the API key, for the callers that check it.
    // Why: the same key guards the rollback listener.
    // From: Issue #1683 | PR #1858
    pub fn api_key(&self) -> &str {
        &self.api_key
    }

    // What: one API call carrying the key and a JSON body.
    // Why: every call site shares auth and JSON headers.
    // From: Issue #1683 | PR #1858
    pub async fn call(
        &self,
        method: reqwest::Method,
        url: &str,
        body: Option<String>,
    ) -> Result<reqwest::Response, String> {
        // What: send the API key in every request.
        // Why: PowerDNS refuses a call without the key.
        // From: Issue #1683 | PR #1912
        let mut request = self
            .http
            .request(method, url)
            .header("X-API-Key", &self.api_key);
        // What: add a JSON content type only with a body.
        // Why: a bodiless GET claims no content type.
        // From: Issue #1683 | PR #1912
        if let Some(body) = body {
            request = request
                .header("Content-Type", "application/json")
                .body(body);
        }
        request.send().await.map_err(|e| e.to_string())
    }

    // What: the rrsets of one zone, or why there are none.
    // Why: an error body must not read as an empty zone.
    // From: Issue #1683 | PR #1858
    pub async fn zone_rrsets(&self, api_root: &str, zone: &str) -> Result<Vec<Value>, String> {
        let url = config::zone_url(api_root, zone);
        let response = self.call(reqwest::Method::GET, &url, None).await?;
        // What: refuse a non-2xx answer.
        // Why: an error body has no rrsets and looks empty.
        // From: Issue #1683 | PR #1912
        if !response.status().is_success() {
            return Err(format!("PowerDNS returned {}", response.status()));
        }
        let body: Value = response
            .json()
            .await
            .map_err(|e| format!("cannot decode the zone export: {e}"))?;
        // What: a 2xx answer without rrsets is empty.
        // Why: a new zone exports no rrsets key yet.
        // From: Issue #1683 | PR #1912
        Ok(body
            .get("rrsets")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default())
    }
}

// What: the label compose sets to the project name.
// Why: the watchdog finds its stack by this label.
// From: Issue #1683
pub const COMPOSE_PROJECT_LABEL: &str = "com.docker.compose.project";

// What: the label compose sets to the service name.
// Why: status.json names each container by its service.
// From: Issue #1683
pub const COMPOSE_SERVICE_LABEL: &str = "com.docker.compose.service";

// What: the endpoint prefix of a local Docker socket.
// Why: unix:///path talks HTTP over that socket file.
// From: Issue #1683
pub const DOCKER_UNIX_PREFIX: &str = "unix://";

// What: client of the Docker Engine API.
// Why: only the watchdog drives containers; one owner.
// From: Issue #1683
pub struct DockerApi {
    client: reqwest::Client,
    base_url: String,
}

impl DockerApi {
    // What: a client for unix:///socket or an http:// URL.
    // Why: redirects are refused; timeouts apply per call.
    // From: Issue #1683 | PR #1912
    pub fn new(endpoint: &str) -> Self {
        let endpoint = endpoint.trim();
        // What: never follow a redirect.
        // Why: a 3xx could reach an unexpected path.
        // From: Issue #1683 | PR #1912
        let builder = reqwest::Client::builder().redirect(reqwest::redirect::Policy::none());
        // What: a unix socket gets a fixed dummy host name.
        // Why: HTTP over a socket needs a host name.
        // From: Issue #1683 | PR #1912
        let (builder, base_url) = match endpoint.strip_prefix(DOCKER_UNIX_PREFIX) {
            Some(socket) => (
                builder.unix_socket(PathBuf::from(socket)),
                "http://docker".to_string(),
            ),
            None => (builder, endpoint.trim_end_matches('/').to_string()),
        };
        // What: build the client; a failure is a bug.
        // Why: no custom TLS is set; the build works.
        // From: Issue #1683 | PR #1912
        let client = builder
            .build()
            .expect("a client without custom TLS settings always builds");
        Self { client, base_url }
    }

    // What: containers of one compose project; None on failure.
    // Why: the stack is whatever compose started; no list.
    // From: Issue #1683
    pub async fn project_containers(
        &self,
        project: &str,
        timeout: Option<Duration>,
    ) -> Option<Vec<Value>> {
        let filter = serde_json::json!({ "label": [format!("{COMPOSE_PROJECT_LABEL}={project}")] });
        let url = reqwest::Url::parse_with_params(
            "http://docker/containers/json",
            [("all", "1"), ("filters", filter.to_string().as_str())],
        )
        .ok()?;
        let path = format!("{}?{}", url.path(), url.query()?);
        let body = self.call(reqwest::Method::GET, &path, timeout).await.ok()?;
        serde_json::from_slice(&body).ok()
    }

    // What: send one signal to a container's main process.
    // Why: nginx reopens its access log on USR1.
    // From: Issue #1683
    pub async fn signal(
        &self,
        name: &str,
        signal: &str,
        timeout: Option<Duration>,
    ) -> Result<(), DockerError> {
        self.act(name, &format!("kill?signal={signal}"), timeout)
            .await
    }

    // What: one call; the body of a 2xx or 304 answer.
    // Why: 304 means the container already has that state.
    // From: Issue #1683 | PR #1858
    async fn call(
        &self,
        method: reqwest::Method,
        path: &str,
        timeout: Option<Duration>,
    ) -> Result<Vec<u8>, DockerError> {
        // What: map a reqwest error to Timeout/Transport.
        // Why: callers treat a timeout apart.
        // From: Issue #1683 | PR #1912
        let failed = |e: reqwest::Error| match e.is_timeout() {
            true => DockerError::Timeout,
            false => DockerError::Transport(e.to_string()),
        };
        let mut request = self
            .client
            .request(method, format!("{}{path}", self.base_url));
        // What: bound connect, headers and body together.
        // Why: a stalled body must not hang the caller.
        // From: Issue #1683 | PR #1858
        if let Some(limit) = timeout {
            request = request.timeout(limit);
        }
        let response = request.send().await.map_err(failed)?;
        let status = response.status();
        // What: accept 2xx and 304, refuse everything else.
        // Why: 304 means the state is set already.
        // From: Issue #1683 | PR #1912
        if !status.is_success() && status != reqwest::StatusCode::NOT_MODIFIED {
            return Err(DockerError::Status(status.as_u16()));
        }
        response.bytes().await.map(|b| b.to_vec()).map_err(failed)
    }

    // What: container inspect JSON, None on any failure.
    // Why: one read feeds health and running state.
    // From: Issue #1683 | PR #1858
    pub async fn inspect(&self, name: &str, timeout: Option<Duration>) -> Option<Value> {
        let path = format!("/containers/{name}/json");
        let body = self.call(reqwest::Method::GET, &path, timeout).await.ok()?;
        serde_json::from_slice(&body).ok()
    }

    // What: POST one container action like start or stop.
    // Why: one call shape for every state change.
    // From: Issue #1683 | PR #1858
    pub async fn act(
        &self,
        name: &str,
        action: &str,
        timeout: Option<Duration>,
    ) -> Result<(), DockerError> {
        let path = format!("/containers/{name}/{action}");
        self.call(reqwest::Method::POST, &path, timeout)
            .await
            .map(|_| ())
    }

    // What: restart a container after a stop grace period.
    // Why: callers differ in grace; the path is shared.
    // From: Issue #1683 | PR #1858
    pub async fn restart(
        &self,
        name: &str,
        grace_secs: u32,
        timeout: Option<Duration>,
    ) -> Result<(), DockerError> {
        self.act(name, &format!("restart?t={grace_secs}"), timeout)
            .await
    }

    // What: GET /_ping; true only for the body "OK".
    // Why: a 200 stalling before the body must fail.
    // From: Issue #1683 | PR #1858
    pub async fn ping(&self, timeout: Option<Duration>) -> bool {
        matches!(
            self.call(reqwest::Method::GET, "/_ping", timeout).await,
            Ok(body) if body.trim_ascii() == b"OK"
        )
    }

    // What: block until the container stops; its exit code.
    // Why: the DHCP probe is a one-shot container.
    // From: Issue #1683 | PR #1858
    pub async fn wait(&self, name: &str, timeout: Option<Duration>) -> Result<i64, DockerError> {
        let path = format!("/containers/{name}/wait?condition=not-running");
        let body = self.call(reqwest::Method::POST, &path, timeout).await?;
        serde_json::from_slice::<Value>(&body)
            .ok()
            .and_then(|answer| answer.get("StatusCode")?.as_i64())
            .ok_or_else(|| DockerError::Transport("the wait answer has no StatusCode".into()))
    }

    // What: container output since unix time, both streams.
    // Why: the probe result is a line in its output.
    // From: Issue #1683 | PR #1858
    pub async fn logs(
        &self,
        name: &str,
        since: u64,
        timeout: Option<Duration>,
    ) -> Result<String, DockerError> {
        let path = format!("/containers/{name}/logs?stdout=1&stderr=1&since={since}");
        let body = self.call(reqwest::Method::GET, &path, timeout).await?;
        Ok(log_text(&body))
    }
}

// What: one label and value row of an offer or ACK.
// Why: servers differ in fields; the page lists what exists
// From: Issue #1683 | PR #1912
#[derive(Clone, Deserialize, Serialize)]
pub struct Detail {
    pub label: String,
    pub value: String,
}

// What: result of the rogue DHCP server check.
// Why: the status tag is the shape the page script reads.
// From: Issue #1683 | PR #1912
#[derive(Deserialize, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum ConflictCheck {
    Found {
        output: String,
        details: Vec<Detail>,
    },
    NotFound,
    Unavailable {
        reason: String,
    },
}

// What: result of the client dry run.
// Why: a failed run has no lease data, so no details.
// From: Issue #1683 | PR #1912
#[derive(Deserialize, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum ClientCheck {
    Passed {
        output: String,
        details: Vec<Detail>,
    },
    Failed {
        output: String,
    },
    Unavailable {
        reason: String,
    },
}

// What: both checks of one probe run.
// Why: the probe prints it as JSON, the ui reads it back.
// From: Issue #1683 | PR #1912
#[derive(Deserialize, Serialize)]
pub struct ProbeReport {
    pub conflict: ConflictCheck,
    pub client: ClientCheck,
}

impl ProbeReport {
    // What: a report where neither check could run.
    // Why: both checks share the reason they did not run.
    // From: Issue #1683 | PR #1912
    pub fn unavailable(reason: String) -> Self {
        Self {
            conflict: ConflictCheck::Unavailable {
                reason: reason.clone(),
            },
            client: ClientCheck::Unavailable { reason },
        }
    }

    // What: one status word for the whole report.
    // Why: severity order; a found server beats everything.
    // From: Issue #1683 | PR #1912
    pub fn overall(&self) -> &'static str {
        match (&self.conflict, &self.client) {
            (ConflictCheck::Found { .. }, _) => "conflict_found",
            (ConflictCheck::Unavailable { .. }, _) | (_, ClientCheck::Unavailable { .. }) => {
                "unavailable"
            }
            (_, ClientCheck::Failed { .. }) => "client_failed",
            (_, ClientCheck::Passed { .. }) => "verified",
        }
    }

    // What: each status word the dhcp page compares.
    // Why: overall() and serde own them; no page copy.
    // From: Issue #1683 | PR #1912
    pub fn status_words() -> Value {
        let found = || ConflictCheck::Found {
            output: String::new(),
            details: Vec::new(),
        };
        let passed = || ClientCheck::Passed {
            output: String::new(),
            details: Vec::new(),
        };
        let failed = || ClientCheck::Failed {
            output: String::new(),
        };
        let overall = |conflict, client| Self { conflict, client }.overall();
        let tag = |check: Value| check["status"].clone();
        serde_json::json!({
            "overall": {
                "verified": overall(ConflictCheck::NotFound, passed()),
                "conflict_found": overall(found(), passed()),
                "client_failed": overall(ConflictCheck::NotFound, failed()),
            },
            "conflict": {
                "found": tag(serde_json::json!(found())),
                "not_found": tag(serde_json::json!(ConflictCheck::NotFound)),
            },
            "client": {
                "passed": tag(serde_json::json!(passed())),
                "failed": tag(serde_json::json!(failed())),
            },
        })
    }

    // What: the page's JSON: one status plus both checks.
    // Why: the dhcp page script reads exactly this shape.
    // From: Issue #1683 | PR #1912
    pub fn page(&self) -> Value {
        serde_json::json!({
            "status": self.overall(),
            "conflict": self.conflict,
            "client": self.client,
        })
    }
}

// What: one probe answer, keyed by the request it answers.
// Why: the ui waits for its own id, never an older run.
// From: Issue #947 | PR #1912
#[derive(Deserialize, Serialize)]
pub struct ProbeAnswer {
    pub id: String,
    pub page: Value,
}

#[cfg(test)]
mod tests {
    use super::*;

    // What: error_chain joins an error with each cause.
    // Why: a builder error alone hides its serde cause.
    // From: Issue #1683 | PR #1912
    #[test]
    fn error_chain_lists_every_cause() {
        #[derive(Debug)]
        struct Outer(std::io::Error);
        impl std::fmt::Display for Outer {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("builder error")
            }
        }
        impl std::error::Error for Outer {
            fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
                Some(&self.0)
            }
        }
        let error = Outer(std::io::Error::other("key must be a string"));
        assert_eq!(error_chain(&error), "builder error: key must be a string");
    }

    // What: a failed secret write keeps a configured value.
    // Why: only a disagreeing file makes it unsafe to use.
    // From: PR #1775
    #[test]
    fn failed_secret_writes_keep_or_refuse() {
        let dir = unique_temp_dir("secret-fail");
        fs::write(dir.join("not-a-dir"), "x").unwrap();
        let gone = dir.join("not-a-dir");
        assert_eq!(
            resolve_shared_secret(&gone, "a", "cfg", 0, hex32),
            Ok("cfg".to_string())
        );
        assert!(resolve_shared_secret(&gone, "a", "", 0, hex32).is_err());
        fs::create_dir(dir.join("blocked")).unwrap();
        assert!(resolve_shared_secret(&dir, "blocked", "cfg", 0, hex32).is_err());
        fs::remove_dir_all(&dir).expect("remove scratch dir");
    }

    // What: equal secrets match, any difference does not.
    // Why: callers trust this for API keys and tokens.
    // From: Issue #1683 | PR #1858
    #[test]
    fn ct_eq_matches_only_equal_strings() {
        assert!(ct_eq("secret-key", "secret-key") && ct_eq("", ""));
        assert!(!ct_eq("secret-key", "different-key"));
        assert!(!ct_eq("short", "muchlongerkey") && !ct_eq("", "x"));
        // What: longer or shorter values never match.
        // Why: a secret prefix must not authenticate.
        // From: Issue #1683 | PR #1912
        assert!(!ct_eq("secret-keyX", "secret-key") && !ct_eq("secret-ke", "secret-key"));
        assert!(!ct_eq("x", ""));
    }

    // What: record and flush messages keep the wire shape.
    // Why: publishers omit unset fields; consumers default.
    // From: Issue #1095
    #[test]
    fn dns_messages_round_trip_the_wire_shape() {
        let delete: DnsRecord =
            serde_json::from_str(r#"{"action":"delete","zone":"lan","name":"h.lan.","type":"A"}"#)
                .unwrap();
        assert_eq!((delete.ttl, delete.records.is_none()), (None, true));
        let wire = serde_json::to_value(&delete).unwrap();
        assert_eq!(wire.get("type").and_then(Value::as_str), Some("A"));
        assert!(wire.get("ttl").is_none() && wire.get("records").is_none());
        let old: FlushRequest = serde_json::from_str(r#"{"domain":"host.lan."}"#).unwrap();
        assert_eq!((old.zone, old.expected_content), (None, None));
        let full = r#"{"domain":"h.lan.","zone":"lan","record_type":"A","expected_content":["192.0.2.5"],"expected_ttl":60}"#;
        let req: FlushRequest = serde_json::from_str(full).unwrap();
        assert_eq!(req.expected_ttl, Some(60));
        assert_eq!(req.expected_content, Some(vec!["192.0.2.5".to_string()]));
    }

    // What: stale limit is cycles times the interval.
    // Why: a wrong limit shows live data as stale.
    // From: Issue #1683 | PR #1912
    #[test]
    fn stale_limit_follows_the_interval() {
        let status = |interval_secs| WatchdogStatus {
            updated: String::new(),
            services: HashMap::new(),
            disk: DiskInfo {
                cache: DiskHealth {
                    pct: 0,
                    status: "unknown".into(),
                },
            },
            interval_secs,
        };
        assert_eq!(status(30).stale_after(3), Duration::from_secs(90));
        assert_eq!(status(10).stale_after(4), Duration::from_secs(40));
        assert_eq!(status(0).stale_after(3), Duration::ZERO);
        let old: WatchdogStatus = serde_json::from_str(
            r#"{"updated":"x","services":{},"disk":{"cache":{"pct":1,"status":"green"}}}"#,
        )
        .unwrap();
        assert_eq!(old.interval_secs, 0);
    }

    // What: desired state reads, or no opinion on failure.
    // Why: a read glitch must never stop a caller's loop.
    // From: Issue #1437
    #[test]
    fn desired_state_reads_or_gives_no_opinion() {
        let root = unique_temp_dir("desired");
        let file = root.join("desired.json");
        assert_eq!(DesiredState::read(&file), DesiredState::default());
        fs::write(&file, "not json").unwrap();
        assert_eq!(DesiredState::read(&file), DesiredState::default());
        fs::write(&file, r#"{"ntp":"stopped"}"#).unwrap();
        let read = DesiredState::read(&file);
        assert_eq!(
            (read.dhcp, read.ntp),
            (None, Some(DesiredRunState::Stopped))
        );
        fs::remove_dir_all(&root).expect("remove scratch dir");
    }

    // What: both endpoint forms build; URLs are trimmed.
    // Why: new() unwraps the builder; this shows it builds.
    // From: Issue #1683 | PR #1912
    #[test]
    fn docker_api_builds_for_a_socket_and_a_url() {
        let tcp = DockerApi::new(" http://engine:2375/ ");
        assert_eq!(tcp.base_url, "http://engine:2375");
        let unix = DockerApi::new(" unix:///var/run/docker.sock ");
        assert_eq!(unix.base_url, "http://docker");
    }

    // What: an id yields its second; non-numbers none.
    // Why: the ui lists snapshots by this time.
    // From: Issue #1683 | PR #1858
    #[test]
    fn snapshot_ids_decode_to_unix_seconds() {
        assert_eq!(
            snapshot_created_unix("00000000001700000000000000"),
            Some(1_700_000)
        );
        assert_eq!(snapshot_created_unix("../etc"), None);
    }

    // What: unix_secs follows the system clock.
    // Why: callers refuse to issue anything from 1970.
    // From: Issue #1683 | PR #1858
    #[test]
    fn unix_secs_follows_the_system_clock() {
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
        assert!(unix_secs().abs_diff(now.as_secs()) <= 2);
    }

    // What: DockerError renders one short line per kind.
    // Why: logs and watchdog output show this text.
    // From: Issue #1683 | PR #1858
    #[test]
    fn docker_errors_render_one_line_each() {
        assert_eq!(
            DockerError::Status(500).to_string(),
            "Docker answered HTTP 500"
        );
        assert_eq!(DockerError::Timeout.to_string(), "Docker call timed out");
        assert_eq!(
            DockerError::Transport("boom".into()).to_string(),
            "Docker call failed: boom"
        );
    }

    // What: the probe report has one overall word.
    // Why: severity order; a found server beats everything.
    // From: Issue #1683 | PR #1912
    #[test]
    fn probe_reports_rank_their_checks() {
        let found = || ConflictCheck::Found {
            output: "10.0.0.1".into(),
            details: vec![],
        };
        let passed = || ClientCheck::Passed {
            output: String::new(),
            details: vec![],
        };
        let failed = || ClientCheck::Failed {
            output: String::new(),
        };
        let gone = || ClientCheck::Unavailable {
            reason: String::new(),
        };
        let no_conflict = || ConflictCheck::Unavailable {
            reason: String::new(),
        };
        let overall = |conflict, client| ProbeReport { conflict, client }.overall();
        assert_eq!(overall(found(), gone()), "conflict_found");
        assert_eq!(overall(found(), passed()), "conflict_found");
        assert_eq!(overall(no_conflict(), passed()), "unavailable");
        assert_eq!(overall(ConflictCheck::NotFound, gone()), "unavailable");
        assert_eq!(overall(ConflictCheck::NotFound, failed()), "client_failed");
        assert_eq!(overall(ConflictCheck::NotFound, passed()), "verified");
        let report = ProbeReport::unavailable("why".to_string());
        assert_eq!(
            serde_json::to_value(&report).unwrap(),
            serde_json::json!({
            "conflict": {"status": "unavailable", "reason": "why"},
            "client": {"status": "unavailable", "reason": "why"}})
        );
        assert_eq!(report.overall(), "unavailable");
        assert_eq!(report.page()["status"], "unavailable");
        assert_eq!(report.page()["client"]["reason"], "why");
    }
}
