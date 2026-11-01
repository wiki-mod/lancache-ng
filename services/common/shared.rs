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
        let pid = rustix::process::Pid::from_raw(pid as i32)
            .ok_or_else(|| format!("bad pid {pid}"))?;
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
                let Some(child) = slot.child.as_mut() else { continue };
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
                let Some(child) = slot.child.as_mut() else { continue };
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
            bytes += chunk.map_err(|e| format!("{url}: {}", error_chain(&e)))?.len() as u64;
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
            let mut req = self.client.request(method, &url).header(KEY_HEADER, &self.key);
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
            self.call(reqwest::Method::PATCH, &path, Some(json!({"rrsets": [rrset]})))
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
                .filter_map(|r| Some((r["name"].as_str()?.to_string(), r["value"].as_str()?.to_string())))
                .collect())
        }

        // What: flush a name (and subtree) from a recursor.
        // Why: changed records must not wait for their TTL.
        // From: Issue #1683 | PR #1858
        pub async fn flush(&self, name: &str, subtree: bool) -> Result<(), String> {
            let path = format!(
                "/cache/flush?domain={}&subtree={subtree}",
                zone_id(name)
            );
            self.call(reqwest::Method::PUT, &path, None).await.map(drop)
        }
    }
}
