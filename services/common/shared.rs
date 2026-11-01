//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: shared owners every service binary calls.
//! Why: one owner per capability; sections per topic.
//! From: Issue #1683 | PR #1858

pub mod config;

// What: clock helpers used by every section.
// Why: one source for Unix time; no local copies.
// From: Issue #1683 | PR #1858
pub mod clock {
    use std::time::{SystemTime, UNIX_EPOCH};

    // What: nanoseconds since the Unix epoch.
    // Why: a clock before 1970 counts as 0, never panics.
    // From: Issue #1683 | PR #1858
    pub fn unix_nanos() -> u128 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    }

    // What: whole seconds since the Unix epoch.
    // Why: status files and snapshots store seconds.
    // From: Issue #1683 | PR #1858
    pub fn unix_secs() -> u64 {
        (unix_nanos() / 1_000_000_000) as u64
    }
}

// What: file writes, ownership, listing and free space.
// Why: every service writes state through one path.
// From: Issue #1683 | PR #1858
pub mod fs {
    use std::fs::{self, File, OpenOptions};
    use std::io::{self, Write};
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    use std::path::{Path, PathBuf};

    // What: what to do when the target already exists.
    // Why: secrets are made once; settings are replaced.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub enum Place {
        Replace,
        Exclusive,
    }

    // What: uid and gid to set; None keeps that field.
    // Why: root-started programs hand files to a runtime id.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
    pub struct Owner {
        pub uid: Option<u32>,
        pub gid: Option<u32>,
    }

    // What: chown an open file, then set its mode.
    // Why: an open handle cannot be swapped by name.
    // From: Issue #1683 | PR #1858
    fn own_open(file: &File, owner: Owner, mode: Option<u32>) -> io::Result<()> {
        if owner.uid.is_some() || owner.gid.is_some() {
            std::os::unix::fs::fchown(file, owner.uid, owner.gid)?;
        }
        if let Some(mode) = mode {
            file.set_permissions(fs::Permissions::from_mode(mode))?;
        }
        Ok(())
    }

    // What: set owner and mode of a path.
    // Why: existing files converge to the wanted rights.
    // From: Issue #1683 | PR #1858
    pub fn own(path: &Path, owner: Owner, mode: Option<u32>) -> io::Result<()> {
        own_open(&File::open(path)?, owner, mode)
    }

    // What: write a whole file; readers see all or nothing.
    // Why: one write path for secrets, settings and status.
    // From: Issue #1683 | PR #1858
    pub fn write(
        path: &Path,
        contents: &[u8],
        mode: u32,
        place: Place,
        owner: Owner,
    ) -> io::Result<()> {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            fs::create_dir_all(parent)?;
        }
        let name = path
            .file_name()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no file name"))?;
        // What: a unique temp name beside the target.
        // Why: link and rename need the same filesystem.
        // From: Issue #1683 | PR #1858
        let tmp = path.with_file_name(format!(
            ".{}.tmp-{}-{}",
            name.to_string_lossy(),
            std::process::id(),
            super::clock::unix_nanos()
        ));
        let result = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(mode)
            .open(&tmp)
            .and_then(|mut file| {
                file.write_all(contents)?;
                own_open(&file, owner, None)?;
                // What: flush before the name points at it.
                // Why: a crash must not leave an empty target.
                // From: Issue #1683 | PR #1858
                file.sync_all()
            })
            .and_then(|()| match place {
                // What: link fails if the name exists.
                // Why: first writer wins without a gap.
                // From: Issue #1683 | PR #1858
                Place::Exclusive => fs::hard_link(&tmp, path),
                // What: a busy bind-mounted file is overwritten.
                // Why: a file bind mount refuses a rename.
                // From: Issue #1683 | PR #1858
                Place::Replace => match fs::rename(&tmp, path) {
                    Err(e) if e.kind() == io::ErrorKind::ResourceBusy => {
                        let mut file = OpenOptions::new().write(true).truncate(true).open(path)?;
                        file.write_all(contents)?;
                        file.sync_all()
                    }
                    other => other,
                },
            });
        match fs::remove_file(&tmp) {
            Err(e) if e.kind() != io::ErrorKind::NotFound => {
                eprintln!("[fs] WARNING: {} not removed: {e}", tmp.display());
            }
            _ => {}
        }
        result
    }

    // What: replace a file only when its bytes differ.
    // Why: reruns write nothing; rights still converge.
    // From: Issue #1683 | PR #1858
    pub fn write_if_changed(
        path: &Path,
        contents: &[u8],
        mode: u32,
        owner: Owner,
    ) -> io::Result<bool> {
        let changed = match fs::read(path) {
            Ok(old) => old != contents,
            Err(e) if e.kind() == io::ErrorKind::NotFound => true,
            Err(e) => return Err(e),
        };
        if changed {
            write(path, contents, mode, Place::Replace, owner)?;
        } else {
            own(path, owner, Some(mode))?;
        }
        Ok(changed)
    }

    // What: metadata, or None when the path is absent.
    // Why: absent is a state; other errors stay errors.
    // From: Issue #1683 | PR #1858
    pub fn metadata_if_present(path: &Path) -> io::Result<Option<fs::Metadata>> {
        match fs::symlink_metadata(path) {
            Ok(m) => Ok(Some(m)),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e),
        }
    }

    // What: all regular files below a root, no symlinks.
    // Why: retention must never follow a link outside.
    // From: Issue #1683 | PR #1858
    pub fn files_under(root: &Path) -> io::Result<Vec<(PathBuf, fs::Metadata)>> {
        let mut found = Vec::new();
        let mut todo = vec![root.to_path_buf()];
        while let Some(dir) = todo.pop() {
            let entries = match fs::read_dir(&dir) {
                Ok(entries) => entries,
                Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
                Err(e) => return Err(e),
            };
            for entry in entries {
                let entry = entry?;
                let meta = fs::symlink_metadata(entry.path())?;
                if meta.is_dir() {
                    todo.push(entry.path());
                } else if meta.is_file() {
                    found.push((entry.path(), meta));
                }
            }
        }
        Ok(found)
    }

    // What: size and free bytes of a filesystem.
    // Why: disk alarms and retention read one source.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub struct Space {
        pub total: u64,
        pub free: u64,
    }

    // What: statvfs of the filesystem holding a path.
    // Why: std has no free-space call.
    // From: Issue #1683 | PR #1858
    pub fn space(path: &Path) -> io::Result<Space> {
        let st = rustix::fs::statvfs(path).map_err(io::Error::from)?;
        Ok(Space {
            total: st.f_blocks.saturating_mul(st.f_frsize),
            free: st.f_bavail.saturating_mul(st.f_frsize),
        })
    }
}

// What: secrets: read or create once, placeholders, seal.
// Why: restarts must never rotate a stored secret.
// From: Issue #1683 | PR #1858
pub mod secret {
    use super::fs::{self, Owner, Place};
    use chacha20poly1305::aead::{Aead, KeyInit};
    use chacha20poly1305::ChaCha20Poly1305;
    use std::io;
    use std::path::{Path, PathBuf};
    use subtle::ConstantTimeEq;

    // What: file mode of every stored secret.
    // Why: only the owner may read a secret.
    // From: Issue #1683 | PR #1858
    const MODE: u32 = 0o600;

    // What: nonce length of ChaCha20-Poly1305.
    // Why: fixed by RFC 8439; not a project value.
    // From: Issue #1683 | PR #1858
    const NONCE_LEN: usize = 12;

    // What: true for empty or a checked-in placeholder.
    // Why: CHANGE_ME and friends must never be live values.
    // From: Issue #1683 | PR #1858
    pub fn is_placeholder(value: &str) -> bool {
        let n = value.to_lowercase().replace('-', "_");
        n.is_empty()
            || n.contains("change_me")
            || n.starts_with("changeme")
            || n.starts_with("your_")
            || n.ends_with("_here")
            || (value.starts_with('<') && value.ends_with('>'))
    }

    // What: N random bytes as lowercase hex.
    // Why: one generator for every created secret.
    // From: Issue #1683 | PR #1858
    pub fn random_hex(bytes: usize) -> String {
        let mut buf = vec![0u8; bytes];
        rand::fill(&mut buf[..]);
        hex::encode(buf)
    }

    // What: equal without timing that leaks the prefix.
    // Why: passwords and tokens are compared this way only.
    // From: Issue #1683 | PR #1858
    pub fn equal(presented: &str, expected: &str) -> bool {
        bool::from(presented.as_bytes().ct_eq(expected.as_bytes()))
    }

    // What: file of a variable in a secret dir (A_B -> a-b).
    // Why: every secret file name derives from its key.
    // From: Issue #1683 | PR #1858
    pub fn file_of(dir: &Path, key: &str) -> PathBuf {
        dir.join(key.to_ascii_lowercase().replace('_', "-"))
    }

    // What: read a secret file, or create it once.
    // Why: the first writer wins; a bad file is an error.
    // From: Issue #1683 | PR #1858
    pub fn load_or_create(
        path: &Path,
        create: impl FnOnce() -> String,
        owner: Owner,
    ) -> io::Result<String> {
        let read = |p: &Path| std::fs::read_to_string(p).map(|t| t.trim().to_string());
        let checked = |text: String| {
            if is_placeholder(&text) {
                Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("{} holds a placeholder", path.display()),
                ))
            } else {
                Ok(text)
            }
        };
        match read(path) {
            Ok(text) => checked(text),
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                let text = create();
                match fs::write(path, text.as_bytes(), MODE, Place::Exclusive, owner) {
                    Ok(()) => Ok(text),
                    Err(e) if e.kind() == io::ErrorKind::AlreadyExists => checked(read(path)?),
                    Err(e) => Err(e),
                }
            }
            Err(e) => Err(e),
        }
    }

    // What: a set env value, else the secret file.
    // Why: an operator value wins; else the stored one.
    // From: Issue #1683 | PR #1858
    pub fn resolve(
        env_value: Option<&str>,
        dir: &Path,
        key: &str,
        owner: Owner,
    ) -> io::Result<String> {
        match env_value.filter(|v| !v.is_empty()) {
            Some(v) if is_placeholder(v) => Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("{key} holds a placeholder"),
            )),
            Some(v) => Ok(v.to_string()),
            None => load_or_create(&file_of(dir, key), || random_hex(32), owner),
        }
    }

    // What: the 32-byte key from a hex secret.
    // Why: seal and open take raw key bytes.
    // From: Issue #1683 | PR #1858
    pub fn key_bytes(hex_key: &str) -> Result<[u8; 32], String> {
        let raw = hex::decode(hex_key).map_err(|e| format!("key is not hex: {e}"))?;
        raw.try_into()
            .map_err(|_| "key must be 32 bytes".to_string())
    }

    // What: seal data with ChaCha20-Poly1305; nonce first.
    // Why: stored login tokens are never plain text.
    // From: Issue #1683 | PR #1858
    pub fn seal(key: &[u8; 32], plain: &[u8]) -> Result<Vec<u8>, String> {
        let mut nonce = [0u8; NONCE_LEN];
        rand::fill(&mut nonce[..]);
        let body = ChaCha20Poly1305::new(key.into())
            .encrypt(&nonce.into(), plain)
            .map_err(|_| "seal failed".to_string())?;
        Ok([nonce.as_slice(), body.as_slice()].concat())
    }

    // What: open sealed data; tampering is an error.
    // Why: a changed file must never yield a token.
    // From: Issue #1683 | PR #1858
    pub fn open(key: &[u8; 32], sealed: &[u8]) -> Result<Vec<u8>, String> {
        if sealed.len() < NONCE_LEN {
            return Err("sealed data too short".into());
        }
        let (nonce, body) = sealed.split_at(NONCE_LEN);
        let nonce: [u8; NONCE_LEN] = nonce.try_into().map_err(|_| "bad nonce".to_string())?;
        ChaCha20Poly1305::new(key.into())
            .decrypt(&nonce.into(), body)
            .map_err(|_| "sealed data is damaged or the key is wrong".to_string())
    }
}

// What: local process manager of one container.
// Why: each container starts its own programs; no god.
// From: Issue #1683 | PR #1858
pub mod proc {
    use std::collections::BTreeMap;
    use std::process::{Child, Command, Stdio};
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    // What: how a program takes a new config without restart.
    // Why: only programs with a native reload get one.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Debug, Eq, PartialEq)]
    pub enum Reload {
        None,
        Hup,
        Command(Vec<String>),
    }

    // What: one program of a container and its start rule.
    // Why: the caller builds it from SOT settings only.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Debug)]
    pub struct Program {
        pub name: String,
        pub argv: Vec<String>,
        pub env: Vec<(String, String)>,
        pub after: Vec<String>,
        pub reload: Reload,
        pub max_restarts: u32,
        pub backoff_start: Duration,
        pub backoff_max: Duration,
    }

    // What: what the admin or the manager wants per program.
    // Why: a manual stop must not be undone by recovery.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
    pub enum Want {
        Run,
        Stop,
    }

    // What: observed state of one program.
    // Why: the ui and the watchdog read this, not guesses.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
    pub enum State {
        Waiting,
        Running { pid: u32 },
        Stopped,
        Backoff { attempt: u32 },
        Failed { reason: String },
    }

    // What: one row of the status a container reports.
    // Why: one schema for ui, watchdog and logs.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
    pub struct Status {
        pub name: String,
        pub want: Want,
        pub state: State,
        pub restarts: u32,
        pub last_exit: Option<String>,
    }

    // What: runtime slot of one program.
    // Why: keeps the child, counters and the next try.
    // From: Issue #1683 | PR #1858
    struct Slot {
        program: Program,
        want: Want,
        child: Option<Child>,
        state: State,
        restarts: u32,
        retry_at: Option<Instant>,
        delay: Duration,
        last_exit: Option<String>,
    }

    // What: the manager; cheap to clone, one shared state.
    // Why: the control socket and the loop share it.
    // From: Issue #1683 | PR #1858
    #[derive(Clone)]
    pub struct Manager {
        slots: Arc<Mutex<BTreeMap<String, Slot>>>,
    }

    // What: lock the slots; a poisoned lock is recovered.
    // Why: one panicking caller must not stop all programs.
    // From: Issue #1683 | PR #1858
    fn lock(
        m: &Mutex<BTreeMap<String, Slot>>,
    ) -> std::sync::MutexGuard<'_, BTreeMap<String, Slot>> {
        m.lock().unwrap_or_else(|e| e.into_inner())
    }

    // What: send a signal to a pid.
    // Why: std only kills with SIGKILL.
    // From: Issue #1683 | PR #1858
    fn signal(pid: u32, sig: rustix::process::Signal) -> Result<(), String> {
        let pid =
            rustix::process::Pid::from_raw(pid as i32).ok_or_else(|| format!("bad pid {pid}"))?;
        rustix::process::kill_process(pid, sig).map_err(|e| e.to_string())
    }

    impl Manager {
        // What: a manager for the given programs, all wanted.
        // Why: an unknown dependency is a config error.
        // From: Issue #1683 | PR #1858
        pub fn new(programs: Vec<Program>) -> Result<Self, String> {
            let names: Vec<String> = programs.iter().map(|p| p.name.clone()).collect();
            for p in &programs {
                if let Some(dep) = p.after.iter().find(|d| !names.contains(d)) {
                    return Err(format!("{} waits for unknown program {dep}", p.name));
                }
            }
            let slots = programs
                .into_iter()
                .map(|p| {
                    let delay = p.backoff_start;
                    let slot = Slot {
                        program: p,
                        want: Want::Run,
                        child: None,
                        state: State::Waiting,
                        restarts: 0,
                        retry_at: None,
                        delay,
                        last_exit: None,
                    };
                    (slot.program.name.clone(), slot)
                })
                .collect();
            Ok(Self {
                slots: Arc::new(Mutex::new(slots)),
            })
        }

        // What: set what the admin wants for one program.
        // Why: Stop ends it and blocks automatic restarts.
        // From: Issue #1683 | PR #1858
        pub fn set_want(&self, name: &str, want: Want) -> Result<(), String> {
            let mut slots = lock(&self.slots);
            let slot = slots
                .get_mut(name)
                .ok_or_else(|| format!("unknown program {name}"))?;
            slot.want = want;
            if want == Want::Run {
                slot.restarts = 0;
                slot.retry_at = None;
                slot.delay = slot.program.backoff_start;
                if matches!(slot.state, State::Failed { .. } | State::Stopped) {
                    slot.state = State::Waiting;
                }
            } else if let Some(child) = &slot.child {
                signal(child.id(), rustix::process::Signal::TERM)?;
            }
            Ok(())
        }

        // What: reload one program by its native way.
        // Why: a config change must not restart neighbours.
        // From: Issue #1683 | PR #1858
        pub fn reload(&self, name: &str) -> Result<(), String> {
            let slots = lock(&self.slots);
            let slot = slots
                .get(name)
                .ok_or_else(|| format!("unknown program {name}"))?;
            let pid = slot
                .child
                .as_ref()
                .map(Child::id)
                .ok_or_else(|| format!("{name} is not running"))?;
            match &slot.program.reload {
                Reload::Hup => signal(pid, rustix::process::Signal::HUP),
                Reload::Command(argv) => {
                    let (cmd, args) = argv
                        .split_first()
                        .ok_or_else(|| format!("{name}: empty reload command"))?;
                    let out = Command::new(cmd)
                        .args(args)
                        .output()
                        .map_err(|e| format!("{name} reload: {e}"))?;
                    if out.status.success() {
                        Ok(())
                    } else {
                        Err(format!(
                            "{name} reload failed: {}",
                            String::from_utf8_lossy(&out.stderr).trim()
                        ))
                    }
                }
                Reload::None => Err(format!("{name} has no reload; restart it")),
            }
        }

        // What: restart one program now, counters kept.
        // Why: an admin restart is one action, not a crash.
        // From: Issue #1683 | PR #1858
        pub fn restart(&self, name: &str) -> Result<(), String> {
            let mut slots = lock(&self.slots);
            let slot = slots
                .get_mut(name)
                .ok_or_else(|| format!("unknown program {name}"))?;
            slot.want = Want::Run;
            slot.retry_at = Some(Instant::now());
            match &slot.child {
                Some(child) => signal(child.id(), rustix::process::Signal::TERM),
                None => {
                    slot.state = State::Waiting;
                    Ok(())
                }
            }
        }

        // What: the status of every program.
        // Why: the container reports it; nothing is guessed.
        // From: Issue #1683 | PR #1858
        pub fn status(&self) -> Vec<Status> {
            lock(&self.slots)
                .values()
                .map(|s| Status {
                    name: s.program.name.clone(),
                    want: s.want,
                    state: s.state.clone(),
                    restarts: s.restarts,
                    last_exit: s.last_exit.clone(),
                })
                .collect()
        }

        // What: one pass: reap exits, start what may start.
        // Why: the caller runs it on a timer from the SOT.
        // From: Issue #1683 | PR #1858
        pub fn tick(&self) {
            let mut slots = lock(&self.slots);
            let now = Instant::now();
            // What: reap exited children first.
            // Why: an exit decides restart, backoff or failed.
            // From: Issue #1683 | PR #1858
            for slot in slots.values_mut() {
                let Some(child) = slot.child.as_mut() else {
                    continue;
                };
                let exit = match child.try_wait() {
                    Ok(Some(status)) => status.to_string(),
                    Ok(None) => continue,
                    Err(e) => format!("wait failed: {e}"),
                };
                eprintln!("[proc] {} exited: {exit}", slot.program.name);
                slot.child = None;
                slot.last_exit = Some(exit.clone());
                if slot.want == Want::Stop {
                    slot.state = State::Stopped;
                } else if slot.retry_at.is_some_and(|t| t <= now) {
                    slot.state = State::Waiting;
                } else if slot.restarts >= slot.program.max_restarts {
                    slot.state = State::Failed {
                        reason: format!("{} restarts used; last exit {exit}", slot.restarts),
                    };
                } else {
                    slot.restarts += 1;
                    slot.retry_at = Some(now + slot.delay);
                    slot.state = State::Backoff {
                        attempt: slot.restarts,
                    };
                    slot.delay = (slot.delay * 2).min(slot.program.backoff_max);
                }
            }
            // What: start wanted programs whose deps are running.
            // Why: start order follows the SOT 'after' list.
            // From: Issue #1683 | PR #1858
            let running: Vec<String> = slots
                .values()
                .filter(|s| matches!(s.state, State::Running { .. }))
                .map(|s| s.program.name.clone())
                .collect();
            for slot in slots.values_mut() {
                let due = matches!(slot.state, State::Waiting)
                    || (matches!(slot.state, State::Backoff { .. })
                        && slot.retry_at.is_some_and(|t| t <= now));
                if slot.want != Want::Run || slot.child.is_some() || !due {
                    continue;
                }
                if !slot.program.after.iter().all(|d| running.contains(d)) {
                    continue;
                }
                slot.retry_at = None;
                let p = &slot.program;
                let Some((cmd, args)) = p.argv.split_first() else {
                    slot.state = State::Failed {
                        reason: "empty command".into(),
                    };
                    continue;
                };
                match Command::new(cmd)
                    .args(args)
                    .envs(p.env.iter().map(|(k, v)| (k, v)))
                    .stdin(Stdio::null())
                    .spawn()
                {
                    Ok(child) => {
                        slot.state = State::Running { pid: child.id() };
                        slot.child = Some(child);
                    }
                    Err(e) => {
                        slot.last_exit = Some(format!("start failed: {e}"));
                        slot.state = State::Failed {
                            reason: format!("start failed: {e}"),
                        };
                    }
                }
            }
        }

        // What: TERM all children, wait, then KILL the rest.
        // Why: a container stop must leave no orphans.
        // From: Issue #1683 | PR #1858
        pub fn shutdown(&self, grace: Duration) {
            let mut slots = lock(&self.slots);
            for slot in slots.values_mut() {
                slot.want = Want::Stop;
                if let Some(child) = &slot.child {
                    if let Err(e) = signal(child.id(), rustix::process::Signal::TERM) {
                        eprintln!("[proc] TERM {} failed: {e}", slot.program.name);
                    }
                }
            }
            let end = Instant::now() + grace;
            for slot in slots.values_mut() {
                let Some(child) = slot.child.as_mut() else {
                    continue;
                };
                while Instant::now() < end {
                    if let Ok(Some(_)) = child.try_wait() {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(50));
                }
                if let Ok(None) = child.try_wait() {
                    eprintln!("[proc] {} ignored TERM; killing", slot.program.name);
                    if let Err(e) = child.kill() {
                        eprintln!("[proc] KILL {} failed: {e}", slot.program.name);
                    }
                    let _ = child.wait();
                }
                slot.child = None;
                slot.state = State::Stopped;
            }
        }
    }
}

// What: one HTTP client rule, health probes, body drain.
// Why: every service talks HTTP through one owner.
// From: Issue #1683 | PR #1858
pub mod http {
    use crate::config::Settings;
    use futures_util::StreamExt as _;
    use std::time::Duration;

    // What: the general client; timeouts from the SOT.
    // Why: no service keeps its own timeout literals.
    // From: Issue #1683 | PR #1858
    pub fn client(s: &Settings) -> Result<reqwest::Client, String> {
        reqwest::Client::builder()
            .timeout(Duration::from_secs(s.uint("HTTP_CLIENT_TIMEOUT")?))
            .pool_idle_timeout(Duration::from_secs(s.uint("HTTP_POOL_IDLE_TIMEOUT")?))
            .tcp_keepalive(Duration::from_secs(s.uint("HTTP_TCP_KEEPALIVE")?))
            .build()
            .map_err(|e| format!("HTTP client: {e}"))
    }

    // What: an error and all causes on one line.
    // Why: reqwest hides the TLS or socket cause in source().
    // From: Issue #1683 | PR #1858
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

    // What: Ok when a GET answers 2xx.
    // Why: http and https probes judge the same way.
    // From: Issue #1683 | PR #1858
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

    // What: health probe of a plain or TLS URL.
    // Why: TLS trusts only the stack CA; no curl, no shell.
    // From: Issue #1683 | PR #1858
    pub async fn probe(url: &str, ca_pem: Option<&[u8]>, timeout: Duration) -> Result<(), String> {
        let mut builder = reqwest::Client::builder().timeout(timeout).no_proxy();
        if url.starts_with("https://") {
            let pem = ca_pem.ok_or_else(|| format!("{url}: https probe needs the stack CA"))?;
            let ca = reqwest::Certificate::from_pem(pem).map_err(|e| format!("CA: {e}"))?;
            builder = builder.tls_certs_only([ca]);
        }
        let client = builder.build().map_err(|e| format!("probe client: {e}"))?;
        expect_success(&client, url).await
    }

    // What: send a GET, read the body, keep only the count.
    // Why: pre-caching fills the proxy; no disk IO here.
    // From: Issue #1683 | PR #1858
    pub async fn drain(client: &reqwest::Client, url: &str) -> Result<(u16, u64), String> {
        let resp = client
            .get(url)
            .send()
            .await
            .map_err(|e| format!("{url}: {}", error_chain(&e)))?;
        let status = resp.status().as_u16();
        let mut bytes = 0u64;
        let mut body = resp.bytes_stream();
        while let Some(chunk) = body.next().await {
            bytes += chunk
                .map_err(|e| format!("{url}: {}", error_chain(&e)))?
                .len() as u64;
        }
        Ok((status, bytes))
    }
}

// What: PowerDNS authoritative and recursor API client.
// Why: native API replaces NATS; one owner for both.
// From: Issue #1683 | PR #1858
pub mod pdns {
    use serde_json::{json, Value};

    // What: header that carries the PowerDNS API key.
    // Why: fixed by the PowerDNS HTTP API.
    // From: Issue #1683 | PR #1858
    const KEY_HEADER: &str = "X-API-Key";

    // What: one zone row of the zone list.
    // Why: serial fields drive the sync check (RFC 1982).
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Debug, serde::Deserialize)]
    pub struct Zone {
        pub id: String,
        pub name: String,
        pub kind: String,
        #[serde(default)]
        pub serial: u32,
        #[serde(default)]
        pub notified_serial: u32,
        #[serde(default)]
        pub last_check: u64,
        #[serde(default)]
        pub masters: Vec<String>,
    }

    // What: client of one PowerDNS API base URL.
    // Why: auth and recursor share key and error handling.
    // From: Issue #1683 | PR #1858
    #[derive(Clone)]
    pub struct Api {
        client: reqwest::Client,
        base: String,
        key: String,
    }

    // What: a zone name in API path form.
    // Why: the API wants the dotted name with a final dot.
    // From: Issue #1683 | PR #1858
    pub fn zone_id(zone: &str) -> String {
        format!("{}.", zone.trim_end_matches('.'))
    }

    impl Api {
        // What: a client; base is .../api/v1/servers/<id>.
        // Why: the server id comes from the SOT URL.
        // From: Issue #1683 | PR #1858
        pub fn new(client: reqwest::Client, base: &str, key: &str) -> Self {
            Self {
                client,
                base: base.trim_end_matches('/').to_string(),
                key: key.to_string(),
            }
        }

        // What: one call; non-2xx is an error with the body.
        // Why: PowerDNS explains refusals in its JSON.
        // From: Issue #1683 | PR #1858
        async fn call(
            &self,
            method: reqwest::Method,
            path: &str,
            body: Option<Value>,
        ) -> Result<String, String> {
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
            let text = resp.text().await.map_err(|e| format!("{url}: {e}"))?;
            if status.is_success() {
                Ok(text)
            } else {
                Err(format!("{url}: HTTP {status}: {text}"))
            }
        }

        // What: replace or delete one rrset of a zone.
        // Why: soa_edit_api raises the serial on change.
        // From: Issue #1683 | PR #1858
        pub async fn set_rrset(
            &self,
            zone: &str,
            name: &str,
            kind: &str,
            ttl: u32,
            contents: &[String],
        ) -> Result<(), String> {
            let rrset = if contents.is_empty() {
                json!({"name": zone_id(name), "type": kind, "changetype": "DELETE"})
            } else {
                let records: Vec<Value> = contents
                    .iter()
                    .map(|c| json!({"content": c, "disabled": false}))
                    .collect();
                json!({"name": zone_id(name), "type": kind, "ttl": ttl,
                       "changetype": "REPLACE", "records": records})
            };
            let path = format!("/zones/{}", zone_id(zone));
            self.call(
                reqwest::Method::PATCH,
                &path,
                Some(json!({"rrsets": [rrset]})),
            )
            .await
            .map(drop)
        }

        // What: all zones with serial and check times.
        // Why: the sync check reads these fields only.
        // From: Issue #1683 | PR #1858
        pub async fn zones(&self) -> Result<Vec<Zone>, String> {
            let text = self.call(reqwest::Method::GET, "/zones", None).await?;
            serde_json::from_str(&text).map_err(|e| format!("zone list: {e}"))
        }

        // What: the zone in AXFR text form.
        // Why: snapshots store what PowerDNS itself exports.
        // From: Issue #1683 | PR #1858
        pub async fn export(&self, zone: &str) -> Result<String, String> {
            let path = format!("/zones/{}/export", zone_id(zone));
            self.call(reqwest::Method::GET, &path, None).await
        }

        // What: send NOTIFY for a zone to its secondaries.
        // Why: secondaries pull at once, not at refresh.
        // From: Issue #1683 | PR #1858
        pub async fn notify(&self, zone: &str) -> Result<(), String> {
            let path = format!("/zones/{}/notify", zone_id(zone));
            self.call(reqwest::Method::PUT, &path, None).await.map(drop)
        }

        // What: pull a secondary zone from its primary now.
        // Why: a stale secondary resyncs without restart.
        // From: Issue #1683 | PR #1858
        pub async fn axfr_retrieve(&self, zone: &str) -> Result<(), String> {
            let path = format!("/zones/{}/axfr-retrieve", zone_id(zone));
            self.call(reqwest::Method::PUT, &path, None).await.map(drop)
        }

        // What: the server statistics as name -> value.
        // Why: snmpd extend and the ui read these counters.
        // From: Issue #1683 | PR #1858
        pub async fn statistics(&self) -> Result<Vec<(String, String)>, String> {
            let text = self.call(reqwest::Method::GET, "/statistics", None).await?;
            let rows: Vec<Value> =
                serde_json::from_str(&text).map_err(|e| format!("statistics: {e}"))?;
            Ok(rows
                .iter()
                .filter_map(|r| {
                    Some((
                        r["name"].as_str()?.to_string(),
                        r["value"].as_str()?.to_string(),
                    ))
                })
                .collect())
        }

        // What: flush a name (and subtree) from a recursor.
        // Why: changed records must not wait for their TTL.
        // From: Issue #1683 | PR #1858
        pub async fn flush(&self, name: &str, subtree: bool) -> Result<(), String> {
            let path = format!("/cache/flush?domain={}&subtree={subtree}", zone_id(name));
            self.call(reqwest::Method::PUT, &path, None).await.map(drop)
        }
    }
}

// What: DNS name and zone rules, serial arithmetic.
// Why: ui, dns, proxy and dhcp share one rule set.
// From: Issue #1683 | PR #1858
pub mod dns {
    use std::cmp::Ordering;

    // What: zone name in dotted form (trailing dot).
    // Why: callers spell zones with and without the dot.
    // From: Issue #1683 | PR #1858
    pub fn canonical_zone(zone: &str) -> String {
        format!("{}.", zone.trim_end_matches('.').to_ascii_lowercase())
    }

    // What: DNS name syntax (RFC 1035 labels).
    // Why: one rule for CDN, DHCP, LAN names and zones.
    // From: Issue #1683 | PR #1858
    pub fn is_dns_name(name: &str, underscore: bool, wildcard: bool) -> bool {
        let name = name.trim_end_matches('.');
        !name.is_empty()
            && name.len() <= 253
            && name.split('.').enumerate().all(|(i, label)| {
                (wildcard && i == 0 && label == "*")
                    || (!label.is_empty()
                        && label.len() <= 63
                        && !label.starts_with('-')
                        && !label.ends_with('-')
                        && label.bytes().all(|b| {
                            b.is_ascii_alphanumeric() || b == b'-' || (underscore && b == b'_')
                        }))
            })
    }

    // What: a cdn-domains entry as (name, subdomains only).
    // Why: a leading dot keeps its wildcard scope.
    // From: Issue #1683 | PR #1858
    pub fn cdn_entry(text: &str) -> Option<(String, bool)> {
        let lower = text.trim().to_ascii_lowercase();
        let (wild, name) = match lower.strip_prefix('.') {
            Some(rest) => (true, rest.to_string()),
            None => (false, lower.clone()),
        };
        (name.contains('.') && is_dns_name(&name, false, false)).then_some((name, wild))
    }

    // What: IPv4 private reverse zones (RFC 1918).
    // Why: fixed by the RFC; PTR for LAN hosts live there.
    // From: Issue #1683 | PR #1858
    pub fn private_reverse_zones() -> Vec<String> {
        let fixed = ["10.in-addr.arpa.", "168.192.in-addr.arpa."].map(str::to_string);
        let mid = (16..=31).map(|n| format!("{n}.172.in-addr.arpa."));
        let ula = ["c.f.ip6.arpa.", "d.f.ip6.arpa."].map(str::to_string);
        fixed.into_iter().chain(mid).chain(ula).collect()
    }

    // What: zones that get snapshots and rollback.
    // Why: rpz and foreign zones are never rolled back.
    // From: Issue #1683 | PR #1858
    pub fn managed_zones(lan_zone: &str, reverse: bool) -> Vec<String> {
        let lan = canonical_zone(lan_zone);
        let mut zones = vec![lan.clone(), format!("local.{lan}")];
        if reverse {
            zones.extend(private_reverse_zones());
        }
        zones
    }

    // What: compare two SOA serials (RFC 1982, 32 bit).
    // Why: serials wrap; plain < is wrong after wrap.
    // From: Issue #1683 | PR #1858
    pub fn serial_cmp(a: u32, b: u32) -> Option<Ordering> {
        if a == b {
            return Some(Ordering::Equal);
        }
        let d = b.wrapping_sub(a);
        // What: exactly half the space apart is undefined.
        // Why: RFC 1982 leaves 2^31 apart without an order.
        // From: Issue #1683 | PR #1858
        match d {
            0x8000_0000 => None,
            d if d < 0x8000_0000 => Some(Ordering::Less),
            _ => Some(Ordering::Greater),
        }
    }

    // What: sync state of a secondary against the primary.
    // Why: the watchdog alarms on Behind for too long.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
    pub enum Sync {
        InSync,
        Behind,
        Ahead,
        Unknown,
    }

    // What: sync state from the two serials.
    // Why: Ahead means a primary rollback or a bad bump.
    // From: Issue #1683 | PR #1858
    pub fn sync_state(primary: u32, secondary: u32) -> Sync {
        match serial_cmp(secondary, primary) {
            Some(Ordering::Equal) => Sync::InSync,
            Some(Ordering::Less) => Sync::Behind,
            Some(Ordering::Greater) => Sync::Ahead,
            None => Sync::Unknown,
        }
    }
}

// What: DHCP modes, managed options and option checks.
// Why: ui, Kea and dnsmasq start share one rule set.
// From: Issue #1683 | PR #1858
pub mod dhcp {
    use crate::config::Settings;

    // What: the DHCP mode; names come from the SOT choice.
    // Why: logic branches by mode; the words live in SOT.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub enum Mode {
        Off,
        Kea,
        DnsmasqProxy,
        DnsmasqRelay,
    }

    impl Mode {
        // What: the mode from DHCP_MODE.
        // Why: the SOT choice already rejected unknown words.
        // From: Issue #1683 | PR #1858
        pub fn from_settings(s: &Settings) -> Result<Self, String> {
            match s.text("DHCP_MODE")?.as_str() {
                "off" => Ok(Self::Off),
                "kea" => Ok(Self::Kea),
                "dnsmasq-proxy" => Ok(Self::DnsmasqProxy),
                "dnsmasq-relay" => Ok(Self::DnsmasqRelay),
                other => Err(format!("DHCP_MODE {other:?} has no handler")),
            }
        }

        // What: programs a mode needs in the dhcp container.
        // Why: Off runs nothing; no idle program uses CPU.
        // From: Issue #1683 | PR #1858
        pub fn programs(self) -> &'static [&'static str] {
            match self {
                Self::Off => &[],
                Self::Kea => &["kea-dhcp4", "kea-ctrl-agent", "kea-dhcp-ddns"],
                Self::DnsmasqProxy | Self::DnsmasqRelay => &["dnsmasq"],
            }
        }
    }

    // What: one DHCPv4 option with a dedicated form field.
    // Why: Kea names it; dnsmasq uses the code (RFC 2132).
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub struct Managed {
        pub name: &'static str,
        pub code: u8,
    }

    // What: managed options; codes fixed by RFC 2132/3397.
    // Why: protocol numbers, not project settings.
    // From: Issue #1683 | PR #1858
    pub const MANAGED: [Managed; 5] = [
        Managed {
            name: "routers",
            code: 3,
        },
        Managed {
            name: "domain-name-servers",
            code: 6,
        },
        Managed {
            name: "domain-name",
            code: 15,
        },
        Managed {
            name: "ntp-servers",
            code: 42,
        },
        Managed {
            name: "domain-search",
            code: 119,
        },
    ];

    // What: one custom option code 1..=254.
    // Why: 0 is padding and 255 the end (RFC 2132).
    // From: Issue #1683 | PR #1858
    pub fn option_code(raw: &str) -> Result<u8, String> {
        let code: u8 = raw
            .trim()
            .parse()
            .map_err(|_| format!("option code {raw:?} must be 1..=254"))?;
        if code == 0 || code == 255 {
            return Err(format!("option code {code} is reserved"));
        }
        if MANAGED.iter().any(|m| m.code == code) {
            return Err(format!("option code {code} has its own field"));
        }
        Ok(code)
    }

    // What: custom "CODE:VALUE" lines, checked.
    // Why: length limit from the SOT; one line per option.
    // From: Issue #1683 | PR #1858
    pub fn custom_options(s: &Settings, raw: &str) -> Result<Vec<(u8, String)>, String> {
        let max = s.uint("DHCP_OPTION_DATA_MAX")? as usize;
        let mut out = Vec::new();
        for (i, line) in raw.lines().map(str::trim).enumerate() {
            if line.is_empty() {
                continue;
            }
            let at = |m: String| format!("line {}: {m}", i + 1);
            let (code, data) = line
                .split_once(':')
                .ok_or_else(|| at("expected CODE:VALUE".into()))?;
            let data = data.trim();
            if data.is_empty() || data.len() > max || data.contains(['\n', '\r', ';']) {
                return Err(at(format!(
                    "value must be 1..={max} bytes, one line, no ';'"
                )));
            }
            out.push((option_code(code).map_err(at)?, data.to_string()));
        }
        Ok(out)
    }

    // What: lease time inside the SOT limits.
    // Why: Kea max-valid-lifetime = lease * factor, capped.
    // From: Issue #1683 | PR #1858
    pub fn lease_limits(s: &Settings, lease: u64) -> Result<(u64, u64), String> {
        let (min, max) = (
            s.uint("DHCP_LEASE_TIME_MIN")?,
            s.uint("DHCP_LEASE_TIME_MAX")?,
        );
        if !(min..=max).contains(&lease) {
            return Err(format!("lease {lease} outside {min}..={max}"));
        }
        let factor = s.uint("DHCP_MAX_LEASE_FACTOR")?;
        Ok((lease, lease.saturating_mul(factor).min(max)))
    }
}

// What: narrow Docker Engine API client.
// Why: list, inspect, start, stop, restart only (AG-SEC).
// From: Issue #1683 | PR #1858
pub mod docker {
    use serde_json::Value;
    use std::path::PathBuf;
    use std::time::Duration;

    // What: label compose sets to the project name.
    // Why: fixed by Docker Compose; finds our containers.
    // From: Issue #1683 | PR #1858
    pub const PROJECT_LABEL: &str = "com.docker.compose.project";

    // What: label compose sets to the service name.
    // Why: fixed by Docker Compose; names a container.
    // From: Issue #1683 | PR #1858
    pub const SERVICE_LABEL: &str = "com.docker.compose.service";

    // What: host name used over a unix socket.
    // Why: HTTP needs a host; the socket ignores it.
    // From: Issue #1683 | PR #1858
    const SOCKET_HOST: &str = "http://docker";

    // What: why a Docker call failed.
    // Why: timeouts and refusals lead to other actions.
    // From: Issue #1683 | PR #1858
    #[derive(Debug)]
    pub enum Error {
        Timeout,
        Status(u16),
        Transport(String),
        Decode(String),
    }

    impl std::fmt::Display for Error {
        // What: one-line text of the error.
        // Why: logs and the ui show it as is.
        // From: Issue #1683 | PR #1858
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            match self {
                Self::Timeout => f.write_str("Docker API timed out"),
                Self::Status(c) => write!(f, "Docker API answered HTTP {c}"),
                Self::Transport(e) => write!(f, "Docker API: {e}"),
                Self::Decode(e) => write!(f, "Docker API answer: {e}"),
            }
        }
    }

    // What: the actions a caller may run on a container.
    // Why: no generic call; nothing else is reachable.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub enum Action {
        Start,
        Stop,
        Restart,
    }

    // What: client of one Docker endpoint.
    // Why: unix:// sockets and tcp endpoints both work.
    // From: Issue #1683 | PR #1858
    pub struct Api {
        client: reqwest::Client,
        base: String,
    }

    impl Api {
        // What: a client for unix:///path or http://host.
        // Why: the endpoint comes from the SOT.
        // From: Issue #1683 | PR #1858
        pub fn new(endpoint: &str) -> Result<Self, String> {
            let builder = reqwest::Client::builder().redirect(reqwest::redirect::Policy::none());
            let (builder, base) = match endpoint.trim().strip_prefix("unix://") {
                Some(sock) => (
                    builder.unix_socket(PathBuf::from(sock)),
                    SOCKET_HOST.to_string(),
                ),
                None => (builder, endpoint.trim().trim_end_matches('/').to_string()),
            };
            let client = builder.build().map_err(|e| format!("Docker client: {e}"))?;
            Ok(Self { client, base })
        }

        // What: one call with a limit; body as bytes.
        // Why: every call shares error mapping.
        // From: Issue #1683 | PR #1858
        async fn call(
            &self,
            method: reqwest::Method,
            path: &str,
            limit: Duration,
        ) -> Result<Vec<u8>, Error> {
            let map = |e: reqwest::Error| {
                if e.is_timeout() {
                    Error::Timeout
                } else {
                    Error::Transport(e.to_string())
                }
            };
            let resp = self
                .client
                .request(method, format!("{}{path}", self.base))
                .timeout(limit)
                .send()
                .await
                .map_err(map)?;
            let status = resp.status();
            // What: 304 means already in the wanted state.
            // Why: starting a running container is no error.
            // From: Issue #1683 | PR #1858
            if !status.is_success() && status != reqwest::StatusCode::NOT_MODIFIED {
                return Err(Error::Status(status.as_u16()));
            }
            resp.bytes().await.map(|b| b.to_vec()).map_err(map)
        }

        // What: all containers of one compose project.
        // Why: the watchdog sees only its own stack.
        // From: Issue #1683 | PR #1858
        pub async fn project(&self, project: &str, limit: Duration) -> Result<Vec<Value>, Error> {
            let filter = serde_json::json!({"label": [format!("{PROJECT_LABEL}={project}")]});
            let url = reqwest::Url::parse_with_params(
                &format!("{SOCKET_HOST}/containers/json"),
                [("all", "1"), ("filters", filter.to_string().as_str())],
            )
            .map_err(|e| Error::Transport(e.to_string()))?;
            let path = format!("{}?{}", url.path(), url.query().unwrap_or_default());
            let body = self.call(reqwest::Method::GET, &path, limit).await?;
            serde_json::from_slice(&body).map_err(|e| Error::Decode(e.to_string()))
        }

        // What: inspect one container.
        // Why: health, restart count and state come from here.
        // From: Issue #1683 | PR #1858
        pub async fn inspect(&self, name: &str, limit: Duration) -> Result<Value, Error> {
            let body = self
                .call(
                    reqwest::Method::GET,
                    &format!("/containers/{name}/json"),
                    limit,
                )
                .await?;
            serde_json::from_slice(&body).map_err(|e| Error::Decode(e.to_string()))
        }

        // What: run one allowed action on a container.
        // Why: grace seconds come from the SOT.
        // From: Issue #1683 | PR #1858
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
            };
            self.call(
                reqwest::Method::POST,
                &format!("/containers/{name}/{verb}"),
                limit,
            )
            .await
            .map(drop)
        }
    }
}

// What: stack CA and leaf certificates via openssl.
// Why: one owner; CA serial persists beside the CA.
// From: Issue #1683 | PR #1858
pub mod cert {
    use std::path::Path;
    use std::process::Command;

    // What: run openssl; non-zero exit is an error.
    // Why: stderr explains every openssl refusal.
    // From: Issue #1683 | PR #1858
    fn openssl(args: &[&str]) -> Result<String, String> {
        let out = Command::new("openssl")
            .args(args)
            .output()
            .map_err(|e| format!("openssl: {e}"))?;
        if out.status.success() {
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        } else {
            Err(format!(
                "openssl {}: {}",
                args.first().unwrap_or(&""),
                String::from_utf8_lossy(&out.stderr).trim()
            ))
        }
    }

    // What: a self-signed CA key and certificate.
    // Why: days, bits and subject come from the SOT.
    // From: Issue #1683 | PR #1858
    pub fn make_ca(
        key: &Path,
        crt: &Path,
        subject: &str,
        days: u64,
        bits: u64,
    ) -> Result<(), String> {
        let (k, c) = (key.display().to_string(), crt.display().to_string());
        openssl(&[
            "req",
            "-x509",
            "-newkey",
            &format!("rsa:{bits}"),
            "-nodes",
            "-keyout",
            &k,
            "-out",
            &c,
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

    // What: a CA-signed leaf for the given SAN names.
    // Why: CN is fixed; identity lives in SAN (AG-KD-005).
    // From: Issue #1683 | PR #1858
    #[allow(clippy::too_many_arguments)]
    pub fn make_leaf(
        ca_key: &Path,
        ca_crt: &Path,
        ca_serial: &Path,
        key: &Path,
        crt: &Path,
        cn: &str,
        sans: &[String],
        days: u64,
        bits: u64,
    ) -> Result<(), String> {
        let csr = crt.with_extension("csr");
        let ext = crt.with_extension("ext");
        let san = sans
            .iter()
            .map(|n| format!("DNS:{n}"))
            .collect::<Vec<_>>()
            .join(",");
        std::fs::write(
            &ext,
            format!("subjectAltName={san}\nextendedKeyUsage=serverAuth\n"),
        )
        .map_err(|e| format!("{}: {e}", ext.display()))?;
        let d = |p: &Path| p.display().to_string();
        let result = openssl(&[
            "req",
            "-new",
            "-newkey",
            &format!("rsa:{bits}"),
            "-nodes",
            "-keyout",
            &d(key),
            "-out",
            &d(&csr),
            "-subj",
            &format!("/CN={cn}"),
        ])
        .and_then(|_| {
            // What: -CAserial keeps the serial file stable.
            // Why: AG-KD-002 needs it persistent beside the CA.
            // From: Issue #1683 | PR #1858
            openssl(&[
                "x509",
                "-req",
                "-in",
                &d(&csr),
                "-CA",
                &d(ca_crt),
                "-CAkey",
                &d(ca_key),
                "-CAserial",
                &d(ca_serial),
                "-CAcreateserial",
                "-out",
                &d(crt),
                "-days",
                &days.to_string(),
                "-sha256",
                "-extfile",
                &d(&ext),
            ])
        });
        for tmp in [&csr, &ext] {
            if let Err(e) = std::fs::remove_file(tmp) {
                eprintln!("[cert] WARNING: {} not removed: {e}", tmp.display());
            }
        }
        result.map(drop)
    }

    // What: seconds until a certificate expires.
    // Why: the watchdog alarms before expiry.
    // From: Issue #1683 | PR #1858
    pub fn valid_for(crt: &Path, within: u64) -> Result<bool, String> {
        let out = Command::new("openssl")
            .args(["x509", "-noout", "-checkend", &within.to_string(), "-in"])
            .arg(crt)
            .output()
            .map_err(|e| format!("openssl: {e}"))?;
        Ok(out.status.success())
    }
}

// What: status every container publishes for ui/watchdog.
// Why: one schema; the watchdog reads, never guesses.
// From: Issue #1683 | PR #1858
pub mod state {
    use crate::fs::{self, Owner};
    use crate::proc::Status;
    use std::path::Path;

    // What: status of one container and its programs.
    // Why: revision shows which config is live.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
    pub struct Container {
        pub name: String,
        pub written: u64,
        pub revision: String,
        pub programs: Vec<Status>,
    }

    // What: write the status file atomically.
    // Why: readers must never see half a file.
    // From: Issue #1683 | PR #1858
    pub fn publish(path: &Path, c: &Container, owner: Owner) -> Result<(), String> {
        let body = serde_json::to_vec_pretty(c).map_err(|e| e.to_string())?;
        fs::write(path, &body, 0o644, fs::Place::Replace, owner)
            .map_err(|e| format!("{}: {e}", path.display()))
    }

    // What: read a status file; age decides staleness.
    // Why: an old file means a hung or dead container.
    // From: Issue #1683 | PR #1858
    pub fn read(path: &Path) -> Result<Container, String> {
        let text = std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
        serde_json::from_slice(&text).map_err(|e| format!("{}: {e}", path.display()))
    }
}

// What: syslog-ng config from settings, incl. forwarding.
// Why: the ui setting drives destinations; one owner.
// From: Issue #1683 | PR #1858
pub mod log {
    use crate::config::Settings;

    // What: one forward target host:port over TCP.
    // Why: TCP with disk buffer; nothing is lost silently.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Debug, Eq, PartialEq)]
    pub struct Target {
        pub host: String,
        pub port: u16,
    }

    // What: forward targets from SYSLOG_FORWARD (list).
    // Why: a secondary always adds its primary (DoMe).
    // From: Issue #1683 | PR #1858
    pub fn targets(s: &Settings) -> Result<Vec<Target>, String> {
        let mut list = s.list("SYSLOG_FORWARD");
        if let Ok(primary) = s.text("SYSLOG_PRIMARY") {
            list.insert(0, primary);
        }
        list.iter()
            .map(|t| {
                let (host, port) = t
                    .rsplit_once(':')
                    .ok_or_else(|| format!("syslog target {t:?} needs host:port"))?;
                let port = port
                    .parse::<u16>()
                    .ok()
                    .filter(|p| *p > 0)
                    .ok_or_else(|| format!("syslog target {t:?}: bad port"))?;
                Ok(Target {
                    host: host.to_string(),
                    port,
                })
            })
            .collect()
    }

    // What: syslog-ng destination and log blocks.
    // Why: appended to the base config the services write.
    // From: Issue #1683 | PR #1858
    pub fn forward_block(targets: &[Target], source: &str, buffer_dir: &str) -> String {
        let mut out = String::new();
        for (i, t) in targets.iter().enumerate() {
            out.push_str(&format!(
                "destination d_fwd{i} {{ network(\"{}\" port({}) transport(\"tcp\") \
                 disk-buffer(reliable(yes) dir(\"{buffer_dir}\")) ); }};\n\
                 log {{ source({source}); destination(d_fwd{i}); }};\n",
                t.host, t.port
            ));
        }
        out
    }

    // What: name of the local file destination.
    // Why: syslog-ng stats report its processed count.
    // From: Issue #1683 | PR #1858
    pub const STORE: &str = "d_store";

    // What: full syslog-ng.conf: store plus forwarding.
    // Why: muted programs skip the store, never the forward.
    // From: Issue #1683 | PR #1858
    pub fn conf(s: &Settings) -> Result<String, String> {
        let root = s.text("SYSLOG_LOG_ROOT")?;
        let group = s.text("LOG_READER_GROUP")?;
        let buffer = s.text("SYSLOG_BUFFER_DIR")?;
        let template = s.text("SYSLOG_LINE_TEMPLATE")?;
        let port = s.uint("LANCACHE_LOG_PORT")?;
        let reap = s.uint("SYSLOG_TIME_REAP")?;
        let muted = s.list("SYSLOG_MUTED");
        let path_ok = |p: &str| p.starts_with('/') && !p.contains(['"', '\n', '\r', '$']);
        if !path_ok(&root) || !path_ok(&buffer) {
            return Err("SYSLOG_LOG_ROOT/SYSLOG_BUFFER_DIR must be plain absolute paths".into());
        }
        if template.contains(['"', '\n', '\r']) {
            return Err("SYSLOG_LINE_TEMPLATE has quote or newline".into());
        }
        let name = |v: &str| {
            !v.is_empty()
                && v.chars()
                    .all(|c| c.is_ascii_alphanumeric() || "_-".contains(c))
        };
        if !name(&group) {
            return Err(format!("LOG_READER_GROUP={group} is no group name"));
        }
        if let Some(bad) = muted.iter().find(|m| !name(m)) {
            return Err(format!("SYSLOG_MUTED entry {bad:?} is no plain name"));
        }
        let skip = if muted.is_empty() {
            String::new()
        } else {
            format!(r#" and not program("^({})$" type(pcre))"#, muted.join("|"))
        };
        let mut out = format!(
            r#"@version: current
options {{ create-dirs(yes); dir-group("{group}"); dir-perm(0750); group("{group}"); perm(0640); keep-hostname(yes); time-reap({reap}); }};
source s_docker {{ network(transport("udp") port({port}) flags(syslog-protocol)); }};
filter f_named {{ program("^[A-Za-z0-9_-]+$" type(pcre)){skip}; }};
destination {STORE} {{ file("{root}/${{PROGRAM}}/${{YEAR}}${{MONTH}}${{DAY}}.log" template("{template}")); }};
log {{ source(s_docker); filter(f_named); destination({STORE}); }};
"#
        );
        out.push_str(&forward_block(&targets(s)?, "s_docker", &buffer));
        Ok(out)
    }
}

// What: snmpd.conf from settings: views, extends, alarms.
// Why: replaces Netdata; thresholds come from the ui.
// From: Issue #1683 | PR #1858
pub mod snmp {
    use crate::config::Settings;

    // What: one extend line: name and command.
    // Why: service counters (pdns, nginx, kea) via extend.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Debug)]
    pub struct Extend {
        pub name: String,
        pub command: String,
    }

    // What: one log pattern counted by logmatch.
    // Why: error rates from logs without own code.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Debug)]
    pub struct LogMatch {
        pub name: String,
        pub file: String,
        pub regex: String,
    }

    // What: the full snmpd.conf text of one container.
    // Why: read-only community, listen and limits from SOT.
    // From: Issue #1683 | PR #1858
    pub fn conf(s: &Settings, extends: &[Extend], matches: &[LogMatch]) -> Result<String, String> {
        let listen = s.text("SNMP_LISTEN")?;
        let community = s.text("SNMP_COMMUNITY")?;
        let client = s.text("SNMP_ALLOW_FROM")?;
        let interval = s.uint("SNMP_LOGMATCH_INTERVAL")?;
        let mut out = format!(
            "agentAddress {listen}\nrocommunity {community} {client}\n\
             includeAllDisks {}%\nload {} {} {}\n",
            s.uint("SNMP_DISK_MIN_FREE_PERCENT")?,
            s.uint("SNMP_LOAD_1")?,
            s.uint("SNMP_LOAD_5")?,
            s.uint("SNMP_LOAD_15")?,
        );
        if s.flag("SNMP_AGENTX")? {
            out.push_str(&format!(
                "master agentx\nagentXSocket {}\n",
                s.text("SNMP_AGENTX_SOCKET")?
            ));
        }
        for e in extends {
            out.push_str(&format!("extend {} {}\n", e.name, e.command));
        }
        for m in matches {
            out.push_str(&format!(
                "logmatch {} {} {interval} {}\n",
                m.name, m.file, m.regex
            ));
        }
        // What: traps only when the ui switched them on.
        // Why: SNMP warnings are optional, in addition to ui.
        // From: Issue #1683 | PR #1858
        if s.flag("SNMP_TRAPS")? {
            out.push_str(&format!(
                "trap2sink {} {community}\ndefaultMonitors yes\nlinkUpDownNotifications yes\n",
                s.text("SNMP_TRAP_SINK")?
            ));
        }
        Ok(out)
    }
}

// What: known-good snapshots with rollback.
// Why: DNS zones and Kea config return to a good state.
// From: Issue #1683 | PR #1858
pub mod snapshot {
    use crate::fs::{self, Owner};
    use std::path::{Path, PathBuf};

    // What: store of one document kind in one directory.
    // Why: keep count comes from the SOT, at least 1.
    // From: Issue #1683 | PR #1858
    pub struct Store {
        pub dir: PathBuf,
        pub keep: usize,
        pub owner: Owner,
    }

    impl Store {
        // What: save a snapshot; id is creation time in ns.
        // Why: ids sort by age; oldest beyond keep are pruned.
        // From: Issue #1683 | PR #1858
        pub fn save(&self, body: &[u8]) -> Result<String, String> {
            let id = crate::clock::unix_nanos().to_string();
            fs::write(
                &self.dir.join(&id),
                body,
                0o600,
                fs::Place::Exclusive,
                self.owner,
            )
            .map_err(|e| format!("snapshot {id}: {e}"))?;
            self.prune()?;
            Ok(id)
        }

        // What: snapshot ids, newest first.
        // Why: rollback takes the newest good one.
        // From: Issue #1683 | PR #1858
        pub fn list(&self) -> Result<Vec<String>, String> {
            let mut ids: Vec<String> = match std::fs::read_dir(&self.dir) {
                Ok(rd) => rd
                    .filter_map(Result::ok)
                    .filter_map(|e| e.file_name().into_string().ok())
                    .filter(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
                    .collect(),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
                Err(e) => return Err(format!("{}: {e}", self.dir.display())),
            };
            ids.sort_by(|a, b| b.len().cmp(&a.len()).then(b.cmp(a)));
            Ok(ids)
        }

        // What: body of one snapshot.
        // Why: rollback restores exactly these bytes.
        // From: Issue #1683 | PR #1858
        pub fn read(&self, id: &str) -> Result<Vec<u8>, String> {
            if id.is_empty() || !id.bytes().all(|b| b.is_ascii_digit()) {
                return Err(format!("bad snapshot id {id:?}"));
            }
            std::fs::read(self.dir.join(id)).map_err(|e| format!("snapshot {id}: {e}"))
        }

        // What: drop snapshots beyond the keep count.
        // Why: the disk must not grow without bound.
        // From: Issue #1683 | PR #1858
        fn prune(&self) -> Result<(), String> {
            for id in self.list()?.into_iter().skip(self.keep.max(1)) {
                let path: &Path = &self.dir.join(&id);
                std::fs::remove_file(path).map_err(|e| format!("{}: {e}", path.display()))?;
            }
            Ok(())
        }
    }
}

// What: DHCP precheck: find servers, try a full lease.
// Why: runs on demand in any mode; no idle polling.
// From: Issue #1683 | PR #1858
pub mod dhcp_probe {
    use crate::config::Settings;
    use dhcproto::v4::{
        Decoder, DhcpOption, Encodable, Encoder, Flags, Message, MessageType, OptionCode,
    };
    use dhcproto::Decodable;
    use std::net::{Ipv4Addr, SocketAddrV4, UdpSocket};
    use std::time::{Duration, Instant};

    // What: DHCP client and server ports (RFC 2131).
    // Why: protocol numbers, not project settings.
    // From: Issue #1683 | PR #1858
    const CLIENT_PORT: u16 = 68;
    const SERVER_PORT: u16 = 67;

    // What: one label/value row shown in the ui.
    // Why: the ui renders offers as a table.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
    pub struct Detail {
        pub label: String,
        pub value: String,
    }

    // What: one DHCP server that answered.
    // Why: several servers on one LAN is the main finding.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
    pub struct Server {
        pub server: Option<Ipv4Addr>,
        pub address: Option<Ipv4Addr>,
        pub details: Vec<Detail>,
    }

    // What: result of one precheck run.
    // Why: the ui shows servers and the lease try.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
    pub struct Report {
        pub servers: Vec<Server>,
        pub lease_ok: bool,
        pub lease_text: String,
        pub error: Option<String>,
    }

    // What: options shown per offer, label and code.
    // Why: codes fixed by RFC 2132; labels for the ui.
    // From: Issue #1683 | PR #1858
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

    // What: read address, server id and rows of a reply.
    // Why: offers and ACKs carry the same fields.
    // From: Issue #1683 | PR #1858
    fn read(msg: &Message) -> Server {
        let opts = msg.opts();
        let text = |code: OptionCode| -> Option<String> {
            Some(match opts.get(code)? {
                DhcpOption::ServerIdentifier(a)
                | DhcpOption::SubnetMask(a)
                | DhcpOption::BroadcastAddr(a) => a.to_string(),
                DhcpOption::AddressLeaseTime(s) | DhcpOption::Renewal(s) => s.to_string(),
                DhcpOption::Router(l) | DhcpOption::DomainNameServer(l) => l
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join(", "),
                DhcpOption::DomainName(n) => n.clone(),
                _ => return None,
            })
        };
        let address = Some(msg.yiaddr()).filter(|a| !a.is_unspecified());
        let mut details: Vec<Detail> = address
            .map(|a| Detail {
                label: "Address".into(),
                value: a.to_string(),
            })
            .into_iter()
            .collect();
        details.extend(FIELDS.iter().filter_map(|(label, code)| {
            text(*code).map(|value| Detail {
                label: (*label).into(),
                value,
            })
        }));
        let server = match opts.get(OptionCode::ServerIdentifier) {
            Some(DhcpOption::ServerIdentifier(a)) => Some(*a),
            _ => None,
        };
        Server {
            server,
            address,
            details,
        }
    }

    // What: true when a reply has the given message type.
    // Why: offers, ACKs and NAKs share one socket.
    // From: Issue #1683 | PR #1858
    fn is(msg: &Message, kind: MessageType) -> bool {
        matches!(msg.opts().get(OptionCode::MessageType),
            Some(DhcpOption::MessageType(t)) if *t == kind)
    }

    // What: build one client message.
    // Why: broadcast flag except for RELEASE (RFC 2131).
    // From: Issue #1683 | PR #1858
    fn message(
        xid: u32,
        mac: &[u8; 6],
        ci: Ipv4Addr,
        kind: MessageType,
        opts: Vec<DhcpOption>,
    ) -> Message {
        let none = Ipv4Addr::UNSPECIFIED;
        let mut msg = Message::new_with_id(xid, ci, none, none, none, mac);
        if kind != MessageType::Release {
            msg.set_flags(Flags::default().set_broadcast());
        }
        msg.opts_mut().insert(DhcpOption::MessageType(kind));
        let wanted = FIELDS
            .iter()
            .map(|(_, c)| *c)
            .filter(|c| *c != OptionCode::ServerIdentifier);
        msg.opts_mut()
            .insert(DhcpOption::ParameterRequestList(wanted.collect()));
        for o in opts {
            msg.opts_mut().insert(o);
        }
        msg
    }

    // What: encode and send one message.
    // Why: one send path for every step.
    // From: Issue #1683 | PR #1858
    fn send(sock: &UdpSocket, msg: &Message, to: SocketAddrV4) -> Result<(), String> {
        let mut buf = Vec::new();
        msg.encode(&mut Encoder::new(&mut buf))
            .map_err(|e| e.to_string())?;
        sock.send_to(&buf, to).map(drop).map_err(|e| e.to_string())
    }

    // What: read replies for xid until done or deadline.
    // Why: the handler returns true to stop early.
    // From: Issue #1683 | PR #1858
    fn listen(
        sock: &UdpSocket,
        xid: u32,
        until: Instant,
        mut f: impl FnMut(&Message) -> bool,
    ) -> Result<(), String> {
        let mut buf = [0u8; 1500];
        loop {
            let left = until.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Ok(());
            }
            sock.set_read_timeout(Some(left))
                .map_err(|e| e.to_string())?;
            match sock.recv_from(&mut buf) {
                Ok((n, _)) => {
                    if let Ok(msg) = Message::decode(&mut Decoder::new(&buf[..n])) {
                        if msg.xid() == xid && f(&msg) {
                            return Ok(());
                        }
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    return Ok(());
                }
                Err(e) => return Err(e.to_string()),
            }
        }
    }

    // What: DISCOVER, collect offers, REQUEST, RELEASE.
    // Why: shows every server and proves a lease works.
    // From: Issue #1683 | PR #1858
    pub fn run(s: &Settings) -> Report {
        let fail = |e: String| Report {
            servers: Vec::new(),
            lease_ok: false,
            lease_text: String::new(),
            error: Some(e),
        };
        let (window, wait, sends) = match (
            s.uint("DHCP_PROBE_WINDOW_MS"),
            s.uint("DHCP_PROBE_ACK_WAIT_MS"),
            s.uint("DHCP_PROBE_SENDS"),
        ) {
            (Ok(a), Ok(b), Ok(c)) => (
                Duration::from_millis(a),
                Duration::from_millis(b),
                c.max(1) as u32,
            ),
            (a, b, c) => {
                return fail(
                    [a.err(), b.err(), c.err()]
                        .into_iter()
                        .flatten()
                        .collect::<Vec<_>>()
                        .join("; "),
                )
            }
        };
        let sock = match UdpSocket::bind((Ipv4Addr::UNSPECIFIED, CLIENT_PORT))
            .and_then(|s| s.set_broadcast(true).map(|()| s))
        {
            Ok(s) => s,
            Err(e) => return fail(format!("DHCP socket: {e}")),
        };
        let bcast = SocketAddrV4::new(Ipv4Addr::BROADCAST, SERVER_PORT);
        let xid: u32 = rand::random();
        // What: random locally administered unicast MAC.
        // Why: the probe must not take a real host's lease.
        // From: Issue #1683 | PR #1858
        let mut mac: [u8; 6] = rand::random();
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
        for i in 1..=sends {
            if let Err(e) = send(&sock, &discover, bcast) {
                return fail(format!("DHCPDISCOVER: {e}"));
            }
            let until = if i == sends {
                end
            } else {
                (Instant::now() + window / sends).min(end)
            };
            if let Err(e) = listen(&sock, xid, until, |m| {
                if is(m, MessageType::Offer) {
                    let o = read(m);
                    if !servers
                        .iter()
                        .any(|x| x.server.is_some() && x.server == o.server)
                    {
                        servers.push(o);
                    }
                }
                false
            }) {
                eprintln!("[dhcp_probe] read {i} failed: {e}");
            }
        }
        let Some(first) = servers.first().cloned() else {
            return Report {
                servers,
                lease_ok: false,
                lease_text: format!("no offer within {} ms", window.as_millis()),
                error: None,
            };
        };
        let (Some(addr), Some(server)) = (first.address, first.server) else {
            return Report {
                servers,
                lease_ok: false,
                lease_text: "offer without address or server id".into(),
                error: None,
            };
        };
        let req = message(
            xid,
            &mac,
            Ipv4Addr::UNSPECIFIED,
            MessageType::Request,
            vec![
                DhcpOption::RequestedIpAddress(addr),
                DhcpOption::ServerIdentifier(server),
            ],
        );
        if let Err(e) = send(&sock, &req, bcast) {
            return Report {
                servers,
                lease_ok: false,
                lease_text: String::new(),
                error: Some(format!("DHCPREQUEST: {e}")),
            };
        }
        let mut verdict: Result<Server, String> = Err("no ACK before timeout".into());
        if let Err(e) = listen(&sock, xid, Instant::now() + wait, |m| {
            if is(m, MessageType::Ack) {
                let a = read(m);
                if a.server == Some(server) {
                    verdict = Ok(a);
                    return true;
                }
            } else if is(m, MessageType::Nak) {
                verdict = Err("server sent DHCPNAK".into());
                return true;
            }
            false
        }) {
            return Report {
                servers,
                lease_ok: false,
                lease_text: String::new(),
                error: Some(e),
            };
        }
        match verdict {
            Ok(ack) => {
                // What: give the test lease back at once.
                // Why: the probe must not keep a pool address.
                // From: Issue #1683 | PR #1858
                if let Some(ip) = ack.address {
                    let rel = message(
                        rand::random(),
                        &mac,
                        ip,
                        MessageType::Release,
                        vec![DhcpOption::ServerIdentifier(server)],
                    );
                    if let Err(e) = send(&sock, &rel, SocketAddrV4::new(server, SERVER_PORT)) {
                        eprintln!("[dhcp_probe] release to {server} failed: {e}");
                    }
                }
                let text = ack.address.map_or("lease granted".into(), |ip| {
                    format!("lease {ip} granted by {server}")
                });
                Report {
                    servers,
                    lease_ok: true,
                    lease_text: text,
                    error: None,
                }
            }
            Err(t) => Report {
                servers,
                lease_ok: false,
                lease_text: t,
                error: None,
            },
        }
    }
}

// What: chrony.conf from settings.
// Why: one owner; the dns container start renders it.
// From: Issue #1683 | PR #1858
pub mod chrony {
    use crate::config::Settings;

    // What: only plain host, CIDR and path characters.
    // Why: a value must never add a chrony directive.
    // From: Issue #1683 | PR #1858
    fn plain(v: &str) -> bool {
        !v.is_empty()
            && v.chars()
                .all(|c| c.is_ascii_alphanumeric() || ".:/-_".contains(c))
    }

    // What: render chrony.conf.
    // Why: IP = server, name = pool; empty CIDRs allow all.
    // From: Issue #1683 | PR #1858
    pub fn conf(s: &Settings) -> Result<String, String> {
        let servers = s.list("NTP_UPSTREAM_SERVERS");
        if servers.is_empty() {
            return Err("NTP_UPSTREAM_SERVERS is empty; NTP never runs alone".into());
        }
        let allowed = s.list("NTP_ALLOWED_CLIENT_CIDRS");
        let drift = s.text("NTP_DRIFT_FILE")?;
        let port = s.uint("NTP_PORT")?;
        if let Some(bad) = servers.iter().chain(&allowed).find(|v| !plain(v)) {
            return Err(format!("NTP value {bad:?} has unsafe characters"));
        }
        if !drift.starts_with('/') || !plain(&drift) {
            return Err(format!("NTP_DRIFT_FILE={drift} is no plain absolute path"));
        }
        let mut out = format!("driftfile {drift}\nport {port}\nmakestep 1.0 3\nrtcsync\n");
        for host in &servers {
            let kind = if host.parse::<std::net::IpAddr>().is_ok() {
                "server"
            } else {
                "pool"
            };
            out.push_str(&format!("{kind} {host} iburst\n"));
        }
        if allowed.is_empty() {
            out.push_str("allow 0.0.0.0/0\nallow ::/0\n");
        }
        for cidr in &allowed {
            out.push_str(&format!("allow {cidr}\n"));
        }
        Ok(out)
    }
}
