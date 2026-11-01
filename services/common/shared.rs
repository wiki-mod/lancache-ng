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
