//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later

// What: code all five images share.
// Why: one owner per behaviour; crates stay thin.
// From: Issue #1683 | PR #1858

pub mod config;

// What: wall-clock time since the Unix epoch.
// Why: file names, ids and logs need a plain number.
// From: Issue #1683 | PR #1858
pub mod clock {
    use std::time::{SystemTime, UNIX_EPOCH};

    // What: nanoseconds since 1970; 0 if the clock is off.
    // Why: a clock before 1970 must not panic.
    // From: Issue #1683 | PR #1858
    pub fn unix_nanos() -> u128 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos())
    }

    // What: whole seconds since 1970.
    // Why: retention and schedules count seconds.
    // From: Issue #1683 | PR #1858
    pub fn unix_secs() -> u64 {
        u64::try_from(unix_nanos() / 1_000_000_000).unwrap_or(u64::MAX)
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

    // What: replace a file, or create it only if new.
    // Why: secrets are first-writer-wins; configs replace.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub enum Place {
        Replace,
        Exclusive,
    }

    // What: optional uid and gid for a written file.
    // Why: root writes files a service user must read.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
    pub struct Owner {
        pub uid: Option<u32>,
        pub gid: Option<u32>,
    }

    // What: apply owner and mode on an open file.
    // Why: fchown on the handle avoids a path race.
    // From: Issue #1683 | PR #1858
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

    // What: temp file beside target, synced, then moved.
    // Why: readers see the old or the new file, never half.
    // From: Issue #1683 | PR #1858
    pub fn write(
        path: &Path,
        contents: &[u8],
        mode: u32,
        place: Place,
        owner: Owner,
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
        let result = file
            .write_all(contents)
            .and_then(|()| set_owner(&file, owner, None))
            .and_then(|()| file.sync_all())
            .and_then(|()| match place {
                Place::Exclusive => fs::hard_link(&tmp, path),
                Place::Replace => fs::rename(&tmp, path).or_else(|e| {
                    // What: busy bind mount: write in place
                    // Why: rename onto a mount is EBUSY.
                    // From: Issue #1683 | PR #1858
                    if e.kind() != io::ErrorKind::ResourceBusy {
                        return Err(e);
                    }
                    let mut target = OpenOptions::new().write(true).truncate(true).open(path)?;
                    target.write_all(contents)?;
                    target.sync_all()
                }),
            });
        drop(file);
        if let Err(e) = fs::remove_file(&tmp)
            && e.kind() != io::ErrorKind::NotFound
        {
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
        let same = match fs::read(path) {
            Ok(old) => old == contents,
            Err(e) if e.kind() == io::ErrorKind::NotFound => false,
            Err(e) => return Err(e),
        };
        if same {
            set_path_owner(path, owner, Some(mode))?;
        } else {
            write(path, contents, mode, Place::Replace, owner)?;
        }
        Ok(!same)
    }

    // What: metadata, or None if the path is absent.
    // Why: absent is a normal state, not an error.
    // From: Issue #1683 | PR #1858
    pub fn metadata_if_present(path: &Path) -> io::Result<Option<fs::Metadata>> {
        match fs::symlink_metadata(path) {
            Ok(m) => Ok(Some(m)),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e),
        }
    }

    // What: every regular file below root.
    // Why: retention sums and prunes by size and age.
    // From: Issue #1683 | PR #1858
    pub fn files_under(root: &Path) -> io::Result<Vec<(PathBuf, fs::Metadata)>> {
        let mut out = Vec::new();
        let mut dirs = vec![root.to_path_buf()];
        while let Some(dir) = dirs.pop() {
            let entries = match fs::read_dir(&dir) {
                Ok(e) => e,
                Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
                Err(e) => return Err(e),
            };
            for entry in entries {
                let path = entry?.path();
                let meta = fs::symlink_metadata(&path)?;
                if meta.is_dir() {
                    dirs.push(path);
                } else if meta.is_file() {
                    out.push((path, meta));
                }
            }
        }
        Ok(out)
    }

    // What: total and free bytes of a filesystem.
    // Why: cache size checks need the real free space.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub struct Space {
        pub total: u64,
        pub free: u64,
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

    // What: file mode of every secret file.
    // Why: only the owning user may read a secret.
    // From: Issue #1683 | PR #1858
    const MODE: u32 = 0o600;

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

    // What: secret file of a key: A_B becomes a-b.
    // Why: one naming rule for every secret file.
    // From: Issue #1683 | PR #1858
    pub fn file_of(dir: &Path, key: &str) -> PathBuf {
        dir.join(key.to_ascii_lowercase().replace('_', "-"))
    }

    // What: read the file, or create it once.
    // Why: first writer wins; peers then read the same.
    // From: Issue #1683 | PR #1858
    pub fn load_or_create(
        path: &Path,
        create: impl FnOnce() -> String,
        owner: Owner,
    ) -> io::Result<String> {
        let read = || std::fs::read_to_string(path).map(|t| t.trim().to_string());
        let usable = |text: String| {
            if is_placeholder(&text) {
                let msg = format!("{} holds a placeholder", path.display());
                Err(io::Error::new(io::ErrorKind::InvalidData, msg))
            } else {
                Ok(text)
            }
        };
        match read() {
            Ok(text) => usable(text),
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                let text = create();
                match fs::write(path, text.as_bytes(), MODE, Place::Exclusive, owner) {
                    Ok(()) => Ok(text),
                    Err(e) if e.kind() == io::ErrorKind::AlreadyExists => usable(read()?),
                    Err(e) => Err(e),
                }
            }
            Err(e) => Err(e),
        }
    }

    // What: env value, else the shared secret file.
    // Why: the operator may set it; else it is generated.
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
    // From: Issue #1683 | PR #1858
    pub fn open(key: &[u8; 32], sealed: &[u8]) -> Result<Vec<u8>, String> {
        let Some((nonce, body)) = sealed.split_at_checked(NONCE_LEN) else {
            return Err("sealed data too short".into());
        };
        let nonce: [u8; NONCE_LEN] = nonce.try_into().map_err(|_| "bad nonce".to_string())?;
        ChaCha20Poly1305::new(key.into())
            .decrypt(&nonce.into(), body)
            .map_err(|_| "sealed data is damaged or the key is wrong".to_string())
    }
}

// What: HTTP client, probe and drain.
// Why: every crate uses the same timeouts from the SOT.
// From: Issue #1683 | PR #1858
pub mod http {
    use crate::config::Settings;
    use futures_util::StreamExt as _;
    use std::time::Duration;

    // What: shared client with SOT timeouts.
    // Why: no request may hang without a limit.
    // From: Issue #1683 | PR #1858
    pub fn client(s: &Settings) -> Result<reqwest::Client, String> {
        let secs = |key: &str| s.uint(key).map(Duration::from_secs);
        reqwest::Client::builder()
            .timeout(secs("HTTP_CLIENT_TIMEOUT")?)
            .pool_idle_timeout(secs("HTTP_POOL_IDLE_TIMEOUT")?)
            .tcp_keepalive(secs("HTTP_TCP_KEEPALIVE")?)
            .build()
            .map_err(|e| format!("HTTP client: {e}"))
    }

    // What: error text with every source cause.
    // Why: reqwest hides the cause in source().
    // From: Issue #1683 | PR #1858
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
    // From: Issue #1683 | PR #1858
    pub async fn probe(url: &str, ca_pem: Option<&[u8]>, timeout: Duration) -> Result<(), String> {
        let mut builder = reqwest::Client::builder().timeout(timeout).no_proxy();
        if url.starts_with("https://") {
            let pem = ca_pem.ok_or_else(|| format!("{url}: https probe needs the stack CA"))?;
            let ca = reqwest::Certificate::from_pem(pem).map_err(|e| format!("CA: {e}"))?;
            builder = builder.tls_certs_only([ca]);
        }
        let client = builder.build().map_err(|e| format!("probe client: {e}"))?;
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
    // From: Issue #1683 | PR #1858
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
// Why: the ui writes records; no message bus in between.
// From: Issue #1683 | PR #1858
pub mod pdns {
    use reqwest::Method;
    use serde_json::{Value, json};
    use std::collections::BTreeSet;

    // What: auth header name of the PowerDNS API.
    // Why: fixed by PowerDNS.
    // From: Issue #1683 | PR #1858
    const KEY_HEADER: &str = "X-API-Key";

    // What: the zone fields the sync check reads.
    // Why: serial against notified serial shows lag.
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

    // What: one API endpoint with its key.
    // Why: base is .../api/v1/servers/<id> from the SOT.
    // From: Issue #1683 | PR #1858
    #[derive(Clone)]
    pub struct Api {
        client: reqwest::Client,
        base: String,
        key: String,
    }

    // What: name with exactly one final dot.
    // Why: the API wants canonical names.
    // From: Issue #1683 | PR #1858
    pub fn zone_id(zone: &str) -> String {
        format!("{}.", zone.trim_end_matches('.'))
    }

    impl Api {
        // What: a client for one server base URL.
        // Why: auth and recursor share this code.
        // From: Issue #1683 | PR #1858
        pub fn new(client: reqwest::Client, base: &str, key: &str) -> Self {
            Self {
                client,
                base: base.trim_end_matches('/').to_string(),
                key: key.to_string(),
            }
        }

        // What: one request; non-2xx is an error.
        // Why: PowerDNS explains refusals in the body.
        // From: Issue #1683 | PR #1858
        async fn call(
            &self,
            method: Method,
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

        // What: PATCH a list of rrset changes.
        // Why: soa-edit-api raises the serial once.
        // From: Issue #1683 | PR #1858
        async fn patch(&self, zone: &str, rrsets: Vec<Value>) -> Result<(), String> {
            let path = format!("/zones/{}", zone_id(zone));
            self.call(Method::PATCH, &path, Some(json!({ "rrsets": rrsets })))
                .await
                .map(drop)
        }

        // What: replace one rrset; empty deletes it.
        // Why: a record edit is one PATCH.
        // From: Issue #1683 | PR #1858
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
        // From: Issue #1683 | PR #1858
        pub async fn rrsets(&self, zone: &str) -> Result<Vec<Value>, String> {
            let text = self
                .call(Method::GET, &format!("/zones/{}", zone_id(zone)), None)
                .await?;
            let v: Value = serde_json::from_str(&text).map_err(|e| format!("zone {zone}: {e}"))?;
            Ok(v["rrsets"].as_array().cloned().unwrap_or_default())
        }

        // What: make the zone equal to saved rrsets.
        // Why: rollback; SOA stays so the serial rises.
        // From: Issue #1683 | PR #1858
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

        // What: add a zone that pulls from masters.
        // Why: a secondary copies zones by AXFR.
        // From: Issue #1683 | PR #1858
        pub async fn create_secondary(&self, zone: &str, masters: &[String]) -> Result<(), String> {
            let body = json!({"name": zone_id(zone), "kind": "Slave", "masters": masters});
            self.call(Method::POST, "/zones", Some(body))
                .await
                .map(drop)
        }

        // What: remove one zone.
        // Why: a changed LAN domain leaves its old zones.
        // From: Issue #1683 | PR #1980
        pub async fn delete_zone(&self, zone: &str) -> Result<(), String> {
            let path = format!("/zones/{}", zone_id(zone));
            self.call(Method::DELETE, &path, None).await.map(drop)
        }

        // What: add a primary zone; SOA from default-soa.
        // Why: API writes and DDNS need the zone to exist.
        // From: Issue #1683 | PR #1980
        pub async fn create_primary(&self, zone: &str, soa_edit: &str) -> Result<(), String> {
            let body = json!({
                "name": zone_id(zone),
                "kind": "Master",
                "nameservers": [],
                "soa_edit_api": soa_edit,
            });
            self.call(Method::POST, "/zones", Some(body))
                .await
                .map(drop)
        }

        // What: create or replace one TSIG key.
        // Why: rotation keeps the name; PUT needs a key.
        // From: Issue #1683 | PR #1858
        pub async fn set_tsigkey(
            &self,
            name: &str,
            algorithm: &str,
            secret: &str,
        ) -> Result<(), String> {
            let body = json!({"name": name, "algorithm": algorithm, "key": secret});
            let path = format!("/tsigkeys/{}", zone_id(name));
            if self
                .call(Method::PUT, &path, Some(body.clone()))
                .await
                .is_ok()
            {
                return Ok(());
            }
            self.call(Method::POST, "/tsigkeys", Some(body))
                .await
                .map(drop)
        }

        // What: set one metadata kind of a zone.
        // Why: per-zone metadata binds the TSIG key.
        // From: Issue #1683 | PR #1858
        pub async fn set_metadata(
            &self,
            zone: &str,
            kind: &str,
            values: &[String],
        ) -> Result<(), String> {
            let path = format!("/zones/{}/metadata/{kind}", zone_id(zone));
            let body = json!({"kind": kind, "metadata": values});
            self.call(Method::PUT, &path, Some(body)).await.map(drop)
        }

        // What: all zones with serial and checks.
        // Why: sync state compares primary and secondary.
        // From: Issue #1683 | PR #1858
        pub async fn zones(&self) -> Result<Vec<Zone>, String> {
            let text = self.call(Method::GET, "/zones", None).await?;
            serde_json::from_str(&text).map_err(|e| format!("zone list: {e}"))
        }

        // What: the zone as BIND zone-file text.
        // Why: snapshots store what PowerDNS exports.
        // From: Issue #1683 | PR #1858
        pub async fn export(&self, zone: &str) -> Result<String, String> {
            self.call(
                Method::GET,
                &format!("/zones/{}/export", zone_id(zone)),
                None,
            )
            .await
        }

        // What: send NOTIFY to all secondaries now.
        // Why: a lagging secondary is pushed at once.
        // From: Issue #1683 | PR #1858
        pub async fn notify(&self, zone: &str) -> Result<(), String> {
            self.call(
                Method::PUT,
                &format!("/zones/{}/notify", zone_id(zone)),
                None,
            )
            .await
            .map(drop)
        }

        // What: pull a secondary zone now.
        // Why: a stale secondary resyncs without restart.
        // From: Issue #1683 | PR #1858
        pub async fn axfr_retrieve(&self, zone: &str) -> Result<(), String> {
            let path = format!("/zones/{}/axfr-retrieve", zone_id(zone));
            self.call(Method::PUT, &path, None).await.map(drop)
        }

        // What: name and value of each server counter.
        // Why: the dashboard shows query counts.
        // From: Issue #1683 | PR #1858
        pub async fn statistics(&self) -> Result<Vec<(String, String)>, String> {
            let text = self.call(Method::GET, "/statistics", None).await?;
            let rows: Vec<Value> =
                serde_json::from_str(&text).map_err(|e| format!("statistics: {e}"))?;
            Ok(rows
                .iter()
                .filter_map(|r| Some((r["name"].as_str()?.into(), r["value"].as_str()?.into())))
                .collect())
        }

        // What: drop cached answers for a name.
        // Why: a changed record answers at once.
        // From: Issue #1683 | PR #1858
        pub async fn flush(&self, name: &str, subtree: bool) -> Result<(), String> {
            let path = format!("/cache/flush?domain={}&subtree={subtree}", zone_id(name));
            self.call(Method::PUT, &path, None).await.map(drop)
        }
    }
}

// What: DNS name rules, zones and serial math.
// Why: ui, watchdog and renderers agree on one rule set.
// From: Issue #1683 | PR #1858
pub mod dns {
    use crate::config::Settings;
    use std::cmp::Ordering;

    // What: lowercase zone name with one final dot.
    // Why: zone names compare equal in one form.
    // From: Issue #1683 | PR #1858
    pub fn canonical_zone(zone: &str) -> String {
        format!("{}.", zone.trim_end_matches('.').to_ascii_lowercase())
    }

    // What: RFC 1035 host name check.
    // Why: SRV needs "_", RPZ wildcards need "*".
    // From: Issue #1683 | PR #1858
    pub fn is_dns_name(name: &str, underscore: bool, wildcard: bool) -> bool {
        let name = name.trim_end_matches('.');
        let label_ok = |label: &str| {
            (1..=63).contains(&label.len())
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-' || (underscore && b == b'_'))
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
    // From: Issue #1683 | PR #1858
    pub fn cdn_entry(text: &str) -> Option<(String, bool)> {
        let row = text.trim().to_ascii_lowercase();
        let (subtree, name) = match row.strip_prefix('.') {
            Some(rest) => (true, rest.to_string()),
            None => (false, row),
        };
        (name.contains('.') && is_dns_name(&name, false, false)).then_some((name, subtree))
    }

    // What: private reverse zones from the SOT.
    // Why: RFC 1918 and ULA ranges; no list in code.
    // From: Issue #1683 | PR #1858
    pub fn private_reverse_zones(s: &Settings) -> Vec<String> {
        s.list("DNS_PRIVATE_REVERSE_ZONES")
            .iter()
            .map(|z| canonical_zone(z))
            .collect()
    }

    // What: zones the stack serves itself.
    // Why: LAN, local.LAN and optional reverse zones.
    // From: Issue #1683 | PR #1858
    pub fn managed_zones(s: &Settings) -> Result<Vec<String>, String> {
        let lan = canonical_zone(&s.text("DHCP_DOMAIN")?);
        let mut zones = vec![format!("local.{lan}"), lan];
        if s.flag("DNS_SERVE_RFC1918")? {
            zones.extend(private_reverse_zones(s));
        }
        Ok(zones)
    }

    // What: compare serials by RFC 1982.
    // Why: serials wrap; half the space apart is unknown.
    // From: Issue #1683 | PR #1858
    pub fn serial_cmp(a: u32, b: u32) -> Option<Ordering> {
        match b.wrapping_sub(a) {
            0 => Some(Ordering::Equal),
            0x8000_0000 => None,
            d if d < 0x8000_0000 => Some(Ordering::Less),
            _ => Some(Ordering::Greater),
        }
    }

    // What: replication state of a secondary zone.
    // Why: the dashboard shows lost NOTIFY or AXFR.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
    pub enum Sync {
        InSync,
        Behind,
        Ahead,
        Unknown,
    }

    // What: state from the two serials.
    // Why: one rule for watchdog and ui.
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

// What: DHCP mode and option rules.
// Why: Kea and dnsmasq get the same checked input.
// From: Issue #1683 | PR #1858
pub mod dhcp {
    use crate::config::Settings;

    // What: DHCP_NTP_SERVERS as IPv4 text; names resolve.
    // Why: option 42 holds IPs; dead names are skipped.
    // From: Issue #1683 | PR #1980
    pub fn ntp_addrs(s: &Settings) -> Result<Vec<String>, String> {
        use std::net::ToSocketAddrs as _;
        s.list("DHCP_NTP_SERVERS")
            .iter()
            .map(|host| {
                if let Ok(ip) = host.parse::<std::net::Ipv4Addr>() {
                    return Ok(ip.to_string());
                }
                (host.as_str(), 0)
                    .to_socket_addrs()
                    .map_err(|e| format!("DHCP_NTP_SERVERS: cannot resolve {host}: {e}"))?
                    .find_map(|a| match a {
                        std::net::SocketAddr::V4(v4) => Some(v4.ip().to_string()),
                        std::net::SocketAddr::V6(_) => None,
                    })
                    .ok_or_else(|| format!("DHCP_NTP_SERVERS: {host} has no IPv4 address"))
            })
            .filter_map(|r: Result<String, String>| r.map_err(|e| eprintln!("{e}; skipped")).ok())
            .map(Ok)
            .collect()
    }

    // What: the four DHCP modes of the SOT choice.
    // Why: exactly one program serves DHCP.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub enum Mode {
        Off,
        Kea,
        DnsmasqProxy,
        DnsmasqRelay,
    }

    impl Mode {
        // What: mode from DHCP_MODE.
        // Why: an unknown word is an error.
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
    }

    // What: an option the ui sets by its own field.
    // Why: custom rows must not override these.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub struct Managed {
        pub name: &'static str,
        pub code: u8,
    }

    // What: options with own fields (RFC 2132, 3397).
    // Why: names and codes are fixed by the RFCs.
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

    // What: check a custom option code.
    // Why: 0 and 255 are pad/end; managed have fields.
    // From: Issue #1683 | PR #1858
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
    // From: Issue #1683 | PR #1858
    pub fn custom_options(s: &Settings, raw: &str) -> Result<Vec<(u8, String)>, String> {
        let max = usize::try_from(s.uint("DHCP_OPTION_DATA_MAX")?).unwrap_or(usize::MAX);
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
            if data.is_empty() || data.len() > max || data.contains(['\n', '\r', ';']) {
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
    // From: Issue #1683 | PR #1858
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
// From: Issue #1683 | PR #1858
pub mod docker {
    use reqwest::Method;
    use serde_json::{Value, json};
    use std::path::PathBuf;
    use std::time::Duration;

    // What: compose label of the project name.
    // Why: fixed by Docker Compose.
    // From: Issue #1683 | PR #1858
    pub const PROJECT_LABEL: &str = "com.docker.compose.project";

    // What: compose label of the service name.
    // Why: fixed by Docker Compose.
    // From: Issue #1683 | PR #1858
    pub const SERVICE_LABEL: &str = "com.docker.compose.service";

    // What: URL host used over the unix socket.
    // Why: HTTP needs a host; the socket ignores it.
    // From: Issue #1683 | PR #1858
    const SOCKET_HOST: &str = "http://docker";

    // What: failure classes of an API call.
    // Why: callers treat timeouts apart from refusals.
    // From: Issue #1683 | PR #1858
    #[derive(Debug)]
    pub enum Error {
        Timeout,
        Status(u16),
        Transport(String),
        Decode(String),
    }

    impl std::fmt::Display for Error {
        // What: readable text of an API error.
        // Why: shown in logs and the ui.
        // From: Issue #1683 | PR #1858
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
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub enum Action {
        Start,
        Stop,
        Restart,
        Reload,
    }

    // What: one Docker endpoint.
    // Why: unix:// socket or tcp URL from the SOT.
    // From: Issue #1683 | PR #1858
    pub struct Api {
        client: reqwest::Client,
        base: String,
    }

    // What: JSON body of an answer.
    // Why: one decode error type.
    // From: Issue #1683 | PR #1858
    fn decode(bytes: &[u8]) -> Result<Value, Error> {
        serde_json::from_slice(bytes).map_err(|e| Error::Decode(e.to_string()))
    }

    impl Api {
        // What: client for a socket path or URL.
        // Why: no redirects; the engine never sends one.
        // From: Issue #1683 | PR #1858
        pub fn new(endpoint: &str) -> Result<Self, String> {
            let endpoint = endpoint.trim();
            let builder = reqwest::Client::builder().redirect(reqwest::redirect::Policy::none());
            let (builder, base) = match endpoint.strip_prefix("unix://") {
                Some(sock) => (
                    builder.unix_socket(PathBuf::from(sock)),
                    SOCKET_HOST.to_string(),
                ),
                None => (builder, endpoint.trim_end_matches('/').to_string()),
            };
            let client = builder.build().map_err(|e| format!("Docker client: {e}"))?;
            Ok(Self { client, base })
        }

        // What: one request; 2xx and 304 count as ok.
        // Why: 304 means already started or stopped.
        // From: Issue #1683 | PR #1858
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
                    Error::Transport(e.to_string())
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
            resp.bytes().await.map(|b| b.to_vec()).map_err(fail)
        }

        // What: run a command in a container.
        // Why: OpenRC rc-service and ui CLIs run this way.
        // From: Issue #1683 | PR #1858
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
            let id = decode(&made)?["Id"]
                .as_str()
                .ok_or_else(|| Error::Decode("exec without Id".into()))?
                .to_string();
            let out = self
                .call(
                    Method::POST,
                    &format!("/exec/{id}/start"),
                    Some(json!({"Detach": false, "Tty": true})),
                    limit,
                )
                .await?;
            let info = decode(
                &self
                    .call(Method::GET, &format!("/exec/{id}/json"), None, limit)
                    .await?,
            )?;
            Ok((
                info["ExitCode"].as_i64().unwrap_or(-1),
                String::from_utf8_lossy(&out).trim().to_string(),
            ))
        }

        // What: all containers of a compose project.
        // Why: the ui and watchdog see stopped ones too.
        // From: Issue #1683 | PR #1858
        pub async fn project(&self, project: &str, limit: Duration) -> Result<Vec<Value>, Error> {
            let filter = json!({"label": [format!("{PROJECT_LABEL}={project}")]}).to_string();
            let url = reqwest::Url::parse_with_params(
                &format!("{SOCKET_HOST}/containers/json"),
                [("all", "1"), ("filters", filter.as_str())],
            )
            .map_err(|e| Error::Transport(e.to_string()))?;
            let path = format!("{}?{}", url.path(), url.query().unwrap_or_default());
            let body = self.call(Method::GET, &path, None, limit).await?;
            serde_json::from_slice(&body).map_err(|e| Error::Decode(e.to_string()))
        }

        // What: full state of one container.
        // Why: health, restarts and state come from here.
        // From: Issue #1683 | PR #1858
        pub async fn inspect(&self, name: &str, limit: Duration) -> Result<Value, Error> {
            decode(
                &self
                    .call(
                        Method::GET,
                        &format!("/containers/{name}/json"),
                        None,
                        limit,
                    )
                    .await?,
            )
        }

        // What: one stats sample of a container.
        // Why: CPU, memory, network, disk per container.
        // From: Issue #1683 | PR #1980
        pub async fn stats(&self, name: &str, limit: Duration) -> Result<Value, Error> {
            let path = format!("/containers/{name}/stats?stream=false&one-shot=true");
            decode(&self.call(Method::GET, &path, None, limit).await?)
        }

        // What: start, stop, restart or HUP a container.
        // Why: grace is the stop timeout in seconds.
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
                Action::Reload => "kill?signal=HUP".to_string(),
            };
            let path = format!("/containers/{name}/{verb}");
            match self.call(Method::POST, &path, None, limit).await {
                // What: 304: it is already in that state.
                // Why: mode off stops dhcp on every apply.
                // From: Issue #1683 | PR #1980
                Err(Error::Status(304)) => Ok(()),
                r => r.map(drop),
            }
        }
    }
}

// What: stack CA and leaf certificates via openssl.
// Why: native tool; no crypto crate for X.509.
// From: Issue #1683 | PR #1858
pub mod cert {
    use std::path::Path;
    use std::process::Command;

    // What: run openssl; stderr becomes the error.
    // Why: a failed step names its subcommand.
    // From: Issue #1683 | PR #1858
    fn openssl(args: &[&str]) -> Result<String, String> {
        let out = Command::new("openssl")
            .args(args)
            .output()
            .map_err(|e| format!("openssl: {e}"))?;
        if out.status.success() {
            return Ok(String::from_utf8_lossy(&out.stdout).into_owned());
        }
        Err(format!(
            "openssl {}: {}",
            args.first().copied().unwrap_or_default(),
            String::from_utf8_lossy(&out.stderr).trim()
        ))
    }

    // What: path as an argument string.
    // Why: openssl takes text arguments.
    // From: Issue #1683 | PR #1858
    fn arg(p: &Path) -> String {
        p.display().to_string()
    }

    // What: self-signed CA key and certificate.
    // Why: HTTPS mode signs leaves with this CA.
    // From: Issue #1683 | PR #1858
    pub fn make_ca(
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

    // What: leaf key and certificate signed by the CA.
    // Why: one leaf per CDN name set in HTTPS mode.
    // From: Issue #1683 | PR #1858
    #[allow(clippy::too_many_arguments)]
    pub fn make_leaf(
        ca_key: &Path,
        ca_crt: &Path,
        ca_serial: &Path,
        key: &Path,
        crt: &Path,
        subject: &str,
        sans: &[String],
        days: u64,
        key_type: &str,
    ) -> Result<(), String> {
        let csr = crt.with_extension("csr");
        let ext = crt.with_extension("ext");
        let san: Vec<String> = sans
            .iter()
            .map(|n| match n.parse::<std::net::IpAddr>() {
                Ok(_) => format!("IP:{n}"),
                Err(_) => format!("DNS:{n}"),
            })
            .collect();
        let mut body = String::from("extendedKeyUsage=serverAuth\n");
        if !san.is_empty() {
            body.push_str(&format!("subjectAltName={}\n", san.join(",")));
        }
        std::fs::write(&ext, body).map_err(|e| format!("{}: {e}", ext.display()))?;
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
                &arg(ca_crt),
                "-CAkey",
                &arg(ca_key),
                "-CAserial",
                &arg(ca_serial),
                "-out",
                &arg(crt),
                "-days",
                &days.to_string(),
                "-extfile",
                &arg(&ext),
            ])
        });
        for tmp in [&csr, &ext] {
            match std::fs::remove_file(tmp) {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
                    eprintln!("cert: {} left behind: {e}", tmp.display());
                }
                _ => {}
            }
        }
        // What: a failed sign leaves no half key pair.
        // Why: a lone key would stop the next attempt.
        // From: Issue #1683 | PR #1980
        if signed.is_err() {
            for f in [key, crt] {
                let _ = std::fs::remove_file(f);
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

    // What: true if crt stays valid for within seconds.
    // Why: renew before expiry, not after.
    // From: Issue #1683 | PR #1858
    pub fn valid_for(crt: &Path, within: u64) -> Result<bool, String> {
        if !crt.is_file() {
            return Err("file missing".into());
        }
        Command::new("openssl")
            .args(["x509", "-noout", "-checkend", &within.to_string(), "-in"])
            .arg(crt)
            .output()
            .map(|o| o.status.success())
            .map_err(|e| format!("openssl: {e}"))
    }

    // What: end of crt: ISO day and whole days left.
    // Why: a warning names the day, not a second count.
    // From: Issue #1683 | PR #1980
    pub fn expiry(crt: &Path) -> Result<(String, i64), String> {
        let a = arg(crt);
        let out = openssl(&[
            "x509", "-noout", "-enddate", "-dateopt", "iso_8601", "-in", &a,
        ])?;
        let day: String = out
            .trim()
            .trim_start_matches("notAfter=")
            .chars()
            .take(10)
            .collect();
        let n: Vec<i64> = day.split('-').filter_map(|p| p.parse().ok()).collect();
        let [y, m, d] = n[..] else {
            return Err(format!("openssl date: {day}"));
        };
        // What: days since 1970-01-01 (civil calendar).
        // Why: no date crate; Hinnant's days_from_civil.
        // From: Issue #1683 | PR #1980
        let y = if m <= 2 { y - 1 } else { y };
        let era = y.div_euclid(400);
        let yoe = y - era * 400;
        let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
        let end = era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_secs() as i64
            / 86_400;
        Ok((day, end - now))
    }
}

// What: syslog-ng config: store per program, forward.
// Why: every container logs here; one place to read.
// From: Issue #1683 | PR #1858
pub mod log {
    use crate::config::Settings;

    // What: one forward target host:port.
    // Why: a secondary also forwards to its primary.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Debug, Eq, PartialEq)]
    pub struct Target {
        pub host: String,
        pub port: u16,
    }

    // What: primary first, then extra targets.
    // Why: SYSLOG_PRIMARY is set only on a secondary.
    // From: Issue #1683 | PR #1858
    pub fn targets(s: &Settings) -> Result<Vec<Target>, String> {
        let primary = s.text("SYSLOG_PRIMARY").ok();
        primary
            .into_iter()
            .chain(s.list("SYSLOG_FORWARD"))
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

    // What: one destination and log path per target.
    // Why: a disk buffer keeps lines while it is down.
    // From: Issue #1683 | PR #1858
    pub fn forward_block(s: &Settings, targets: &[Target], source: &str) -> Result<String, String> {
        let buffer = s.text("SYSLOG_BUFFER_DIR")?;
        let transport = s.text("SYSLOG_FWD_TRANSPORT")?;
        Ok(targets
            .iter()
            .enumerate()
            .map(|(i, t)| {
                let dest = format!(
                    "destination d_fwd{i} {{ network(\"{}\" port({}) transport(\"{transport}\") \
                     disk-buffer(reliable(yes) dir(\"{buffer}\")) ); }};\n",
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
    // From: Issue #1683 | PR #1858
    pub const STORE: &str = "d_store";

    // What: plain name: letters, digits, _ and -.
    // Why: values go into syslog-ng config text.
    // From: Issue #1683 | PR #1858
    fn is_plain(v: &str) -> bool {
        !v.is_empty()
            && v.chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    }

    // What: full syslog-ng.conf.
    // Why: the watchdog image runs syslog-ng.
    // From: Issue #1683 | PR #1858
    pub fn render(s: &Settings) -> Result<String, String> {
        let root = s.text("SYSLOG_LOG_ROOT")?;
        let buffer = s.text("SYSLOG_BUFFER_DIR")?;
        let template = s.text("SYSLOG_LINE_TEMPLATE")?;
        let group = s.text("LOG_READER_GROUP")?;
        let muted = s.list("SYSLOG_MUTED");
        let safe_path = |p: &str| p.starts_with('/') && !p.contains(['"', '\n', '\r', '$']);
        if !safe_path(&root) || !safe_path(&buffer) {
            return Err(
                "SYSLOG_LOG_ROOT and SYSLOG_BUFFER_DIR must be plain absolute paths".into(),
            );
        }
        if template.contains(['"', '\n', '\r']) {
            return Err("SYSLOG_LINE_TEMPLATE holds a quote or line break".into());
        }
        if !is_plain(&group) {
            return Err(format!("LOG_READER_GROUP={group} is no group name"));
        }
        if let Some(bad) = muted.iter().find(|m| !is_plain(m)) {
            return Err(format!("SYSLOG_MUTED entry {bad:?} is no plain name"));
        }
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
            fperm = s.text("SYSLOG_FILE_PERM")?,
            dperm = s.text("SYSLOG_DIR_PERM")?,
            reap = s.uint("SYSLOG_TIME_REAP")?,
            inp = s.text("SYSLOG_IN_TRANSPORT")?,
            port = s.uint("LANCACHE_LOG_PORT")?,
        );
        out.push_str(&forward_block(s, &targets(s)?, "s_docker")?);
        Ok(out)
    }
}

// What: net-snmp snmpd.conf.
// Why: statistics and alarms come from SNMP, not Netdata.
// From: Issue #1683 | PR #1858
pub mod snmp {
    use crate::config::Settings;

    // What: one extend command (custom OID).
    // Why: stack counters beside the stock MIBs.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Debug)]
    pub struct Extend {
        pub name: String,
        pub command: String,
    }

    // What: one logmatch watch on a log file.
    // Why: counts error lines per program.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Debug)]
    pub struct LogMatch {
        pub name: String,
        pub file: String,
        pub regex: String,
    }

    // What: full snmpd.conf from the SOT.
    // Why: community, listen and limits are settings.
    // From: Issue #1683 | PR #1858
    pub fn render(
        s: &Settings,
        extends: &[Extend],
        matches: &[LogMatch],
    ) -> Result<String, String> {
        let community = s.text("SNMP_COMMUNITY")?;
        let mut out = format!(
            "agentAddress {}\nrocommunity {community} {}\nincludeAllDisks {}%\nload {} {} {}\n",
            s.text("SNMP_LISTEN")?,
            s.text("SNMP_ALLOW_FROM")?,
            s.uint("SNMP_DISK_MIN_FREE_PERCENT")?,
            s.uint("SNMP_LOAD_1")?,
            s.uint("SNMP_LOAD_5")?,
            s.uint("SNMP_LOAD_15")?,
        );
        if s.flag("SNMP_AGENTX")? {
            out += &format!(
                "master agentx\nagentXSocket {}\n",
                s.text("SNMP_AGENTX_SOCKET")?
            );
        }
        for e in extends {
            out += &format!("extend {} {}\n", e.name, e.command);
        }
        let every = s.uint("SNMP_LOGMATCH_INTERVAL")?;
        for m in matches {
            out += &format!("logmatch {} {} {every} {}\n", m.name, m.file, m.regex);
        }
        if s.flag("SNMP_TRAPS")? {
            out += &format!(
                "trap2sink {} {community}\ndefaultMonitors yes\nlinkUpDownNotifications yes\n",
                s.text("SNMP_TRAP_SINK")?
            );
        }
        Ok(out)
    }
}

// What: numbered known-good snapshots in one dir.
// Why: zone and Kea rollbacks pick one by id.
// From: Issue #1683 | PR #1858
pub mod snapshot {
    use crate::fs::{self, Owner, Place};
    use std::path::PathBuf;

    // What: snapshot dir, keep count, owner, file name.
    // Why: file set: <dir>/<id>/<file>, as setup.sh reads.
    // From: Issue #1683 | PR #1980
    pub struct Store {
        pub dir: PathBuf,
        pub keep: usize,
        pub owner: Owner,
        pub file: Option<String>,
    }

    // What: an id is a non-empty digit string.
    // Why: ids name files; no path can sneak in.
    // From: Issue #1683 | PR #1858
    fn is_id(name: &str) -> bool {
        !name.is_empty() && name.bytes().all(|b| b.is_ascii_digit())
    }

    impl Store {
        // What: the file that holds snapshot id.
        // Why: flat file, or one dir per id with a name.
        // From: Issue #1683 | PR #1980
        pub fn path(&self, id: &str) -> PathBuf {
            match &self.file {
                Some(name) => self.dir.join(id).join(name),
                None => self.dir.join(id),
            }
        }

        // What: save body under a new time id.
        // Why: exclusive create; then prune old ones.
        // From: Issue #1683 | PR #1858
        pub fn save(&self, body: &[u8]) -> Result<String, String> {
            let id = crate::clock::unix_nanos().to_string();
            if self.file.is_some() {
                std::fs::create_dir_all(self.dir.join(&id))
                    .map_err(|e| format!("snapshot {id}: {e}"))?;
            }
            fs::write(&self.path(&id), body, 0o600, Place::Exclusive, self.owner)
                .map_err(|e| format!("snapshot {id}: {e}"))?;
            self.prune()?;
            Ok(id)
        }

        // What: ids, newest first.
        // Why: longer digit string is newer, then text.
        // From: Issue #1683 | PR #1858
        pub fn list(&self) -> Result<Vec<String>, String> {
            let entries = match std::fs::read_dir(&self.dir) {
                Ok(rd) => rd,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
                Err(e) => return Err(format!("{}: {e}", self.dir.display())),
            };
            let mut ids: Vec<String> = entries
                .filter_map(Result::ok)
                .filter_map(|e| e.file_name().into_string().ok())
                .filter(|n| is_id(n) && self.path(n).is_file())
                .collect();
            ids.sort_by(|a, b| b.len().cmp(&a.len()).then_with(|| b.cmp(a)));
            Ok(ids)
        }

        // What: body of one snapshot.
        // Why: rollback restores exactly this.
        // From: Issue #1683 | PR #1858
        pub fn read(&self, id: &str) -> Result<Vec<u8>, String> {
            if !is_id(id) {
                return Err(format!("bad snapshot id {id:?}"));
            }
            std::fs::read(self.path(id)).map_err(|e| format!("snapshot {id}: {e}"))
        }

        // What: drop all but the newest keep.
        // Why: at least one stays to roll back to.
        // From: Issue #1683 | PR #1858
        fn prune(&self) -> Result<(), String> {
            for id in self.list()?.into_iter().skip(self.keep.max(1)) {
                let path = self.dir.join(&id);
                let gone = match self.file {
                    Some(_) => std::fs::remove_dir_all(&path),
                    None => std::fs::remove_file(&path),
                };
                gone.map_err(|e| format!("{}: {e}", path.display()))?;
            }
            Ok(())
        }
    }
}

// What: on-demand DHCP probe: DISCOVER, REQUEST, RELEASE.
// Why: shows every DHCP server on the LAN and a real lease.
// From: Issue #1683 | PR #1858
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
    // From: Issue #1683 | PR #1858
    const CLIENT_PORT: u16 = 68;
    const SERVER_PORT: u16 = 67;

    // What: largest UDP payload.
    // Why: a receive buffer never truncates a reply.
    // From: Issue #1683 | PR #1858
    const UDP_MAX: usize = 65_535;

    // What: one labelled value of an answer.
    // Why: the ui prints a table per server.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
    pub struct Detail {
        pub label: String,
        pub value: String,
    }

    // What: one answering server.
    // Why: competing servers must be visible.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
    pub struct Server {
        pub server: Option<Ipv4Addr>,
        pub address: Option<Ipv4Addr>,
        pub details: Vec<Detail>,
    }

    // What: probe result for the ui.
    // Why: offers, lease result and hard errors apart.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
    pub struct Report {
        pub servers: Vec<Server>,
        pub lease_ok: bool,
        pub lease_text: String,
        pub error: Option<String>,
    }

    impl Report {
        // What: a report with offers and a lease text.
        // Why: most exits differ only in these.
        // From: Issue #1683 | PR #1858
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
        // From: Issue #1683 | PR #1858
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

    // What: text of one option, if shown.
    // Why: lists join with a comma.
    // From: Issue #1683 | PR #1858
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
    // From: Issue #1683 | PR #1858
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
    // From: Issue #1683 | PR #1858
    fn is(msg: &Message, kind: MessageType) -> bool {
        matches!(msg.opts().get(OptionCode::MessageType), Some(DhcpOption::MessageType(t)) if *t == kind)
    }

    // What: build one client message.
    // Why: broadcast flag except for RELEASE.
    // From: Issue #1683 | PR #1858
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
    // From: Issue #1683 | PR #1858
    fn send(sock: &UdpSocket, msg: &Message, to: SocketAddrV4) -> Result<(), String> {
        let mut buf = Vec::new();
        msg.encode(&mut Encoder::new(&mut buf))
            .map_err(|e| e.to_string())?;
        sock.send_to(&buf, to).map(drop).map_err(|e| e.to_string())
    }

    // What: read replies of xid until done or deadline.
    // Why: f returns true when the wanted reply came.
    // From: Issue #1683 | PR #1858
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
    // From: Issue #1683 | PR #1858
    pub fn run(s: &Settings) -> Report {
        let timing = || -> Result<(Duration, Duration, u32), String> {
            Ok((
                Duration::from_millis(s.uint("DHCP_PROBE_WINDOW_MS")?),
                Duration::from_millis(s.uint("DHCP_PROBE_ACK_WAIT_MS")?),
                u32::try_from(s.uint("DHCP_PROBE_SENDS")?.max(1)).unwrap_or(u32::MAX),
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
        // Why: never collides with a real NIC (IEEE 802).
        // From: Issue #1683 | PR #1858
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
                    if offer.server.is_some() && !servers.iter().any(|x| x.server == offer.server) {
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
// From: Issue #1683 | PR #1858
pub mod chrony {
    use crate::config::Settings;

    // What: host, IP, CIDR or path characters only.
    // Why: values go into a config file.
    // From: Issue #1683 | PR #1858
    fn is_plain(v: &str) -> bool {
        !v.is_empty()
            && v.chars()
                .all(|c| c.is_ascii_alphanumeric() || ".:/-_".contains(c))
    }

    // What: full chrony.conf.
    // Why: upstream needed; only SOT CIDRs may ask.
    // From: Issue #1683 | PR #1858
    pub fn render(s: &Settings) -> Result<String, String> {
        let upstream = s.list("NTP_UPSTREAM_SERVERS");
        if upstream.is_empty() {
            return Err("NTP_UPSTREAM_SERVERS is empty; NTP never runs alone".into());
        }
        let allowed = s.list("NTP_ALLOWED_CLIENT_CIDRS");
        let drift = s.text("NTP_DRIFT_FILE")?;
        let makestep = s.text("NTP_MAKESTEP")?;
        if let Some(bad) = upstream.iter().chain(&allowed).find(|v| !is_plain(v)) {
            return Err(format!("NTP value {bad:?} has unsafe characters"));
        }
        if !drift.starts_with('/') || !is_plain(&drift) {
            return Err(format!("NTP_DRIFT_FILE={drift} is no plain absolute path"));
        }
        if makestep.contains(['\n', '\r']) {
            return Err("NTP_MAKESTEP holds a line break".into());
        }
        let mut out = format!(
            "driftfile {drift}\nport {}\nmakestep {makestep}\nrtcsync\n",
            s.uint("NTP_PORT")?
        );
        for host in &upstream {
            let kind = if host.parse::<std::net::IpAddr>().is_ok() {
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
// From: Issue #1683 | PR #1858
pub mod pdns_conf {
    use crate::config::Settings;

    // What: addresses of registered secondaries.
    // Why: NOTIFY goes to every registered secondary.
    // From: Issue #1683 | PR #1858
    pub fn secondary_ips(s: &Settings) -> Vec<String> {
        s.list("DNS_SECONDARIES")
            .iter()
            .filter_map(|e| e.split_once('@').map(|(_, ip)| ip.to_string()))
            .filter(|ip| ip.parse::<std::net::IpAddr>().is_ok())
            .collect()
    }

    // What: full pdns.conf for this node's role.
    // Why: API on; AXFR by TSIG, not by IP list.
    // From: Issue #1683 | PR #1858
    pub fn auth(s: &Settings, api_key: &str) -> Result<String, String> {
        let primary = match s.text("DNS_REPLICATION_ROLE")?.as_str() {
            "primary" => true,
            "secondary" => false,
            other => return Err(format!("DNS_REPLICATION_ROLE={other} is unknown")),
        };
        let yes = |on: bool| if on { "yes" } else { "no" }.to_string();
        let joined = |key: &str| s.list(key).join(",");
        let rows = [
            ("launch", s.text("PDNS_LAUNCH")?),
            ("gsqlite3-database", s.text("PDNS_DATABASE")?),
            ("local-address", joined("PDNS_LISTEN")),
            ("local-port", s.uint("PDNS_AUTH_PORT")?.to_string()),
            ("primary", yes(primary)),
            ("secondary", yes(!primary)),
            (
                "also-notify",
                if primary {
                    secondary_ips(s).join(",")
                } else {
                    String::new()
                },
            ),
            (
                "allow-notify-from",
                if primary {
                    String::new()
                } else {
                    s.text("DNS_XFR_PRIMARY")?
                },
            ),
            ("allow-axfr-ips", joined("PDNS_AXFR_FROM")),
            ("xfr-cycle-interval", s.uint("PDNS_XFR_CYCLE")?.to_string()),
            ("dnsupdate", yes(primary)),
            ("allow-dnsupdate-from", joined("PDNS_DNSUPDATE_FROM")),
            ("default-soa-content", s.text("PDNS_DEFAULT_SOA")?),
            ("api", yes(true)),
            ("api-key", api_key.to_string()),
            ("webserver", yes(true)),
            ("webserver-address", s.text("PDNS_API_LISTEN")?),
            ("webserver-port", s.uint("PDNS_AUTH_API_PORT")?.to_string()),
            ("webserver-allow-from", joined("PDNS_API_ALLOW_FROM")),
            ("loglevel", s.uint("PDNS_AUTH_LOGLEVEL")?.to_string()),
            ("guardian", yes(false)),
            ("daemon", yes(false)),
        ];
        let mut out = String::new();
        for (key, value) in rows {
            if value.contains(['\n', '\r']) {
                return Err(format!("{key} contains a line break"));
            }
            if !value.is_empty() {
                out += &format!("{key}={value}\n");
            }
        }
        Ok(out)
    }
}

// What: recursor.yml, RPZ zone and Lua files.
// Why: two recursors: HTTP mode and HTTPS mode.
// From: Issue #1683 | PR #1858
pub mod recursor_conf {
    use crate::config::Settings;

    // What: which of the two recursors.
    // Why: keys differ only by HTTP or HTTPS.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub enum Which {
        Http,
        Https,
    }

    impl Which {
        // What: SOT key RECURSOR_<MODE>_<name>, in full.
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

    // What: YAML list rows of quoted items.
    // Why: quotes or breaks would break the YAML.
    // From: Issue #1683 | PR #1858
    fn yaml_list(items: &[String], indent: &str) -> Result<String, String> {
        items
            .iter()
            .map(|i| {
                if i.contains(['"', '\\', '\n', '\r']) {
                    Err(format!("value {i:?} has quote or line break"))
                } else {
                    Ok([indent, "- \"", i.as_str(), "\"\n"].concat())
                }
            })
            .collect()
    }

    // What: RPZ zone: every cache domain to answer.
    // Why: clients reach the proxy by DNS only.
    // From: Issue #1683 | PR #1858
    pub fn rpz(
        s: &Settings,
        domains: &[String],
        answer: &str,
        serial: u32,
    ) -> Result<String, String> {
        if answer.parse::<std::net::IpAddr>().is_err() {
            return Err(format!("RPZ answer {answer:?} is no IP address"));
        }
        let kind = if answer.contains(':') { "AAAA" } else { "A" };
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
        for d in domains {
            let d = d.trim_end_matches('.');
            if !crate::dns::is_dns_name(d, false, true) {
                return Err(format!("cache domain {d:?} is no DNS name"));
            }
            out += &format!("{d} {kind} {answer}\n*.{d} {kind} {answer}\n");
        }
        Ok(out)
    }

    // What: Lua config that loads the RPZ file.
    // Why: the recursor reads RPZ only via Lua.
    // From: Issue #1683 | PR #1858
    pub fn lua(s: &Settings, rpz_file: &str) -> Result<String, String> {
        let policy = s.text("RPZ_POLICY_NAME")?;
        if [rpz_file, policy.as_str()]
            .iter()
            .any(|v| v.contains(['"', '\\', '\n']))
        {
            return Err("RPZ path or policy name is not plain".into());
        }
        let mut lua = format!("rpzFile(\"{rpz_file}\", {{ policyName=\"{policy}\" }})\n");
        // What: no DNSSEC check for the local zones.
        // Why: they are unsigned; the root denies them.
        // From: Issue #1683 | PR #1980
        for z in crate::dns::managed_zones(s)? {
            lua += &format!("addNTA(\"{}\")\n", z.trim_end_matches('.'));
        }

        // What: no DNSSEC check for private domains.
        // Why: router domains like fritz.box are unsigned.
        // From: Issue #1683 | PR #1980
        for z in upstream_zones(s, "DNS_UPSTREAM_UNSIGNED_ZONES")? {
            if z != "." {
                lua += &format!("addNTA(\"{z}\")\n");
            }
        }
        Ok(lua)
    }

    // What: domain list for upstream forwarding.
    // Why: empty or "." means all names; bad chars stop.
    // From: Issue #1683 | PR #1980
    fn upstream_zones(s: &Settings, key: &str) -> Result<Vec<String>, String> {
        let ok = |c: char| c.is_ascii_alphanumeric() || "-._".contains(c);
        let mut out = Vec::new();
        for raw in s.list(key) {
            let z = raw.trim_end_matches('.').to_ascii_lowercase();
            if !z.chars().all(ok) {
                return Err(format!("{key}: bad domain {raw}"));
            }
            out.push(if z.is_empty() { ".".to_string() } else { z });
        }
        if out.is_empty() && key == "DNS_UPSTREAM_ZONES" {
            out.push(".".to_string());
        }
        // What: a local zone or its subzone never goes out.
        // Why: live 05.11. (U1): home.lan gave NXDOMAIN.
        // From: Issue #1683 | PR #1980
        if key == "DNS_UPSTREAM_ZONES" {
            for m in crate::dns::managed_zones(s)? {
                let m = m.trim_end_matches('.').to_ascii_lowercase();
                if let Some(z) = out
                    .iter()
                    .find(|z| **z == m || z.ends_with(&format!(".{m}")))
                {
                    return Err(format!(
                        "{key}: {z} is the local zone {m}; it is answered here"
                    ));
                }
            }
        }
        Ok(out)
    }

    // What: upstream servers; our own address is refused.
    // Why: live 05.11. (U4): own IP made a query loop.
    // From: Issue #1683 | PR #1980
    fn upstream_servers(s: &Settings) -> Result<Vec<String>, String> {
        let own: Vec<String> = ["IP_HTTP", "IP_HTTPS"]
            .iter()
            .filter_map(|k| s.text(k).ok())
            .filter(|v| !v.is_empty())
            .collect();
        let list = s.list("DNS_UPSTREAM_SERVERS");
        for raw in &list {
            upstream_entry(raw, &own)?;
        }
        Ok(list)
    }

    // What: one upstream: IP, [IPv6]:port or IPv4:port.
    // Why: live 06.11.: "[fd00::1" was saved unchecked.
    // From: Issue #1683
    pub fn upstream_entry(raw: &str, own: &[String]) -> Result<(), String> {
        let bad = || format!("DNS_UPSTREAM_SERVERS: {raw} is no IP address");
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
        if let Some(p) = port {
            p.parse::<u16>().ok().filter(|n| *n > 0).ok_or_else(bad)?;
        }
        let ip: std::net::IpAddr = host.parse().map_err(|_| bad())?;
        if ip.is_loopback() || ip.is_unspecified() || own.iter().any(|o| *o == host) {
            return Err(format!(
                "DNS_UPSTREAM_SERVERS: {raw} is this LanCache-NG itself; that would loop"
            ));
        }
        Ok(())
    }

    // What: Lua hook: AAAA answers become empty.
    // Why: keeps cache traffic on IPv4 when wanted.
    // From: Issue #1683 | PR #1858
    pub const AAAA_FILTER_LUA: &str = "function preresolve(dq)\n  if dq.qtype == pdns.AAAA then\n    dq.rcode = pdns.NOERROR\n    return true\n  end\n  return false\nend\n";

    // What: full recursor.yml (YAML settings).
    // Why: local zones go to auth; rest upstream.
    // From: Issue #1683 | PR #1858
    pub fn yaml(
        s: &Settings,
        which: Which,
        api_key: &str,
        lua_file: &str,
    ) -> Result<String, String> {
        let u = |k: &str| s.uint(k).map(|v| v.to_string());
        let auth = format!(
            "{}:{}",
            s.text("PDNS_AUTH_ADDRESS")?,
            s.uint("PDNS_AUTH_PORT")?
        );
        let local: String = crate::dns::managed_zones(s)?
            .iter()
            .map(|z| {
                format!(
                    "    - zone: \"{}\"\n      forwarders: [\"{auth}\"]\n",
                    z.trim_end_matches('.')
                )
            })
            .collect();
        let upstream = upstream_servers(s)?;
        let recurse = if upstream.is_empty() {
            String::new()
        } else {
            let list: Vec<String> = upstream.iter().map(|u| format!("\"{u}\"")).collect();
            let fwd = list.join(", ");

            // What: one forward entry per chosen domain.
            // Why: "domains" mode forwards only those.
            // From: Issue #1683 | PR #1980
            let entries: String = upstream_zones(s, "DNS_UPSTREAM_ZONES")?
                .iter()
                .map(|z| format!("    - zone: \"{z}\"\n      forwarders: [{fwd}]\n"))
                .collect();
            format!("  forward_zones_recurse:\n{entries}")
        };
        let aaaa = if s.flag("DNS_FILTER_AAAA")? {
            format!(
                "  lua_dns_script: \"{}\"\n",
                s.text("RECURSOR_AAAA_LUA_FILE")?
            )
        } else {
            String::new()
        };
        let snmp = if s.flag("SNMP_AGENTX")? {
            format!(
                "snmp:\n  agent: true\n  daemon_socket: \"{}\"\n",
                s.text("SNMP_AGENTX_SOCKET")?
            )
        } else {
            String::new()
        };
        let negttl = u("RECURSOR_MAX_NEGATIVE_TTL")?;
        let mut y = String::new();
        y += "incoming:\n  listen:\n";
        y += &yaml_list(&s.list(&which.key("LISTEN")), "    ")?;
        y += &format!("  port: {}\n  allow_from:\n", u(&which.key("PORT"))?);
        y += &yaml_list(&s.list("DNS_QUERY_ALLOW_FROM"), "    ")?;
        y += &format!(
            "recursor:\n  serve_rfc1918: {}\n",
            s.flag("DNS_SERVE_RFC1918")?
        );
        y += &format!("  socket_dir: \"{}\"\n", s.text("RECURSOR_RUN_DIR")?);
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
            s.text("PDNS_API_LISTEN")?
        );
        y += &format!("  port: {}\n  allow_from:\n", u(&which.key("API_PORT"))?);
        y += &yaml_list(&s.list("PDNS_API_ALLOW_FROM"), "    ")?;
        y += &format!("  api_key: \"{api_key}\"\n");
        // What: query log raises the level and drops quiet.
        // Why: DoMe 31.10.: see DNS queries live.
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

// What: Kea config files built from the settings.
// Why: one place turns SOT values into Kea JSON.
// From: Issue #1683 | PR #1858
pub mod kea_conf {
    use crate::config::Settings;
    use serde_json::{Value, json};

    // What: fixed Kea protocol words.
    // Why: Kea accepts only these; not tunable.
    // From: Issue #1683 | PR #1858
    const SOCKET_KIND: &str = "unix";
    const LEASE_BACKEND: &str = "memfile";
    const NCR_PROTOCOL: &str = "UDP";
    const NCR_FORMAT: &str = "JSON";
    const LOG_OUTPUT: &str = "stdout";

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

    fn lan_domain(s: &Settings) -> Result<String, String> {
        let zone = crate::dns::canonical_zone(&s.text("DHCP_DOMAIN")?);
        Ok(zone.trim_end_matches('.').to_string())
    }

    fn socket(s: &Settings) -> Result<Value, String> {
        Ok(json!({"socket-type": SOCKET_KIND,
                  "socket-name": s.text("KEA_DHCP4_SOCKET")?}))
    }

    // What: domain-name and domain-search of kept subnets.
    // Why: live 05.11.: subnets kept the old LAN domain.
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
            let hit = matches!(name, "domain-name" | "domain-search")
                && row["data"].as_str() == Some(before);
            if hit {
                row["data"] = Value::from(domain);
            }
        }
        subnets
    }

    fn option_rows(s: &Settings, domain: &str) -> Result<Vec<Value>, String> {
        let mut rows = Vec::new();
        rows.push(json!({"name": "routers", "data": s.text("DHCP_GATEWAY")?}));
        let dns = s.list("DHCP_DNS_SERVERS").join(", ");
        rows.push(json!({"name": "domain-name-servers", "data": dns}));
        rows.push(json!({"name": "domain-name", "data": domain}));
        rows.push(json!({"name": "domain-search", "data": domain}));
        let ntp = crate::dhcp::ntp_addrs(s)?;
        if !ntp.is_empty() {
            rows.push(json!({"name": "ntp-servers", "data": ntp.join(", ")}));
        }
        let raw = s.text("DHCP_CUSTOM_OPTIONS").unwrap_or_default();
        for (code, data) in crate::dhcp::custom_options(s, &raw)? {
            rows.push(json!({"code": code, "data": data}));
        }
        Ok(rows)
    }

    // What: kea-dhcp4.conf.
    // Why: subnets edited in the ui survive a render.
    // From: Issue #1683 | PR #1858
    pub fn dhcp4(s: &Settings, existing: Option<&Value>) -> Result<Value, String> {
        let domain = lan_domain(s)?;
        let (valid, max) = crate::dhcp::lease_limits(s, s.uint("DHCP_LEASE_TIME")?)?;
        let pool = format!(
            "{} - {}",
            s.text("DHCP_RANGE_START")?,
            s.text("DHCP_RANGE_END")?
        );
        // What: the LAN domain of the last render.
        // Why: kept subnets follow a changed DHCP_DOMAIN.
        // From: Issue #1683 | PR #1980
        let before = existing
            .and_then(|e| e.pointer("/Dhcp4/ddns-qualifying-suffix"))
            .and_then(Value::as_str)
            .map(|d| d.trim_end_matches('.').to_string());
        let subnets = match existing.and_then(|e| e.pointer("/Dhcp4/subnet4")) {
            Some(kept) => follow_domain(kept.clone(), before.as_deref(), &domain),
            None => json!([{
                "id": s.uint("DHCP_SUBNET_ID")?,
                "subnet": s.text("DHCP_SUBNET")?,
                "pools": [{"pool": pool}],
                "option-data": option_rows(s, &domain)?,
                "valid-lifetime": valid,
                "max-valid-lifetime": max
            }]),
        };
        let updates = s.flag("DHCP_DDNS")?;
        Ok(json!({"Dhcp4": {
            "interfaces-config": {
                "interfaces": s.list("DHCP_INTERFACES"),
                "re-detect": false
            },
            "lease-database": {
                "type": LEASE_BACKEND,
                "persist": true,
                "name": s.text("KEA_LEASE_FILE")?
            },
            "control-socket": socket(s)?,
            "hooks-libraries": [{"library": s.text("KEA_LEASE_CMDS_HOOK")?}],
            "subnet4": subnets,
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
            "ddns-qualifying-suffix": format!("{domain}."),
            "loggers": log_rows(s, &["kea-dhcp4", "kea-dhcp4.packets"])?
        }}))
    }

    // What: kea-ctrl-agent.conf.
    // Why: the ui reads leases over its REST port.
    // From: Issue #1683 | PR #1858
    pub fn ctrl_agent(s: &Settings) -> Result<Value, String> {
        Ok(json!({"Control-agent": {
            "http-host": s.text("KEA_CTRL_ADDRESS")?,
            "http-port": s.uint("KEA_CTRL_PORT")?,
            "control-sockets": {"dhcp4": socket(s)?},
            "loggers": log_rows(s, &["kea-ctrl-agent"])?
        }}))
    }

    // What: kea-dhcp-ddns.conf, forward and reverse.
    // Why: name updates go to local pdns with TSIG.
    // From: Issue #1683 | PR #1858
    pub fn ddns(s: &Settings, key: &str, secret: &str) -> Result<Value, String> {
        let target = json!([{
            "ip-address": s.text("PDNS_AUTH_ADDRESS")?,
            "port": s.uint("PDNS_AUTH_PORT")?
        }]);
        let entry = |zone: &str| json!({"name": zone, "key-name": key, "dns-servers": target});
        let lan = crate::dns::canonical_zone(&s.text("DHCP_DOMAIN")?);
        let reverse: Vec<Value> = crate::dns::private_reverse_zones(s)
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
            "forward-ddns": {"ddns-domains": [entry(&lan)]},
            "reverse-ddns": {"ddns-domains": reverse},
            "loggers": log_rows(s, &["kea-dhcp-ddns"])?
        }}))
    }
}

// What: dnsmasq.conf for proxy-DHCP or relay.
// Why: one owner; a bad value stops the render.
// From: Issue #1683 | PR #1858
pub mod dnsmasq_conf {
    use crate::config::Settings;
    use crate::dhcp::Mode;

    struct Conf(String);

    impl Conf {
        fn add(&mut self, row: &str) -> Result<(), String> {
            if row.contains(['\n', '\r']) {
                return Err(format!("dnsmasq row {row:?} has a line break"));
            }
            self.0.push_str(row);
            self.0.push('\n');
            Ok(())
        }
        fn add_if(&mut self, prefix: &str, value: &str) -> Result<(), String> {
            if value.is_empty() {
                return Ok(());
            }
            self.add(&format!("{prefix}{value}"))
        }
    }

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

    fn pxe(s: &Settings, c: &mut Conf) -> Result<(), String> {
        let get = |k: &str| s.text(k).unwrap_or_default();
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

    // What: render dnsmasq.conf for one mode.
    // Why: Off and Kea start no dnsmasq at all.
    // From: Issue #1683 | PR #1858
    pub fn render(s: &Settings, mode: Mode) -> Result<String, String> {
        let mut c = base(s)?;
        if mode == Mode::DnsmasqRelay {
            let local = s.text("DHCP_RELAY_LOCAL_ADDR")?;
            let upstream = s.text("UPSTREAM_DHCP_IP")?;
            c.add(&format!("dhcp-relay={local},{upstream}"))?;
            return Ok(c.0);
        }
        if mode != Mode::DnsmasqProxy {
            return Err(format!("no dnsmasq in DHCP mode {mode:?}"));
        }
        let get = |k: &str| s.text(k).unwrap_or_default();
        c.add(&format!(
            "dhcp-range={},proxy",
            s.text("DHCP_SUBNET_START")?
        ))?;
        c.add_if("interface=", &get("DHCP_PROXY_INTERFACE"))?;
        c.add_if("dhcp-option-pxe=3,", &get("DHCP_PROXY_ROUTER"))?;
        c.add_if("dhcp-option-pxe=6,", &s.list("DHCP_DNS_SERVERS").join(","))?;
        c.add_if("dhcp-option-pxe=15,", &get("DHCP_PROXY_DOMAIN"))?;
        c.add_if("dhcp-option-pxe=42,", &crate::dhcp::ntp_addrs(s)?.join(","))?;
        let file = get("DHCP_PROXY_BOOT_FILENAME");
        if !file.is_empty() {
            let server = get("DHCP_PROXY_BOOT_SERVER");
            c.add(&format!("dhcp-boot={file},,{server}"))?;
        }
        let raw = get("DHCP_CUSTOM_OPTIONS");
        for (code, data) in crate::dhcp::custom_options(s, &raw)? {
            c.add(&format!("dhcp-option-pxe={code},{data}"))?;
        }
        pxe(s, &mut c)?;
        Ok(c.0)
    }
}

// What: generated nginx include files and cert plan.
// Why: one owner of CDN host maps, ACL and dispatch.
// From: Issue #1683 | PR #1858
pub mod nginx_conf {
    use crate::config::Settings;
    use sha2::{Digest, Sha256};
    use std::collections::BTreeSet;

    // What: first line of every generated file.
    // Why: tells a reader not to edit it by hand.
    // From: Issue #1683 | PR #1858
    const HEAD: &str = "# Generated by LanCache-NG; do not edit\n";

    // What: Public Suffix List rules.
    // Why: finds the registrable root of a CDN name.
    // From: Issue #1683 | PR #1858
    #[derive(Default)]
    pub struct Psl {
        plain: BTreeSet<String>,
        wild: BTreeSet<String>,
        except: BTreeSet<String>,
    }

    impl Psl {
        // What: read the PSL text format.
        // Why: publicsuffix.org rows: x, *.x, !x.
        // From: Issue #1683 | PR #1858
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

        // What: registrable root: suffix plus one label.
        // Why: PSL rule; an unknown TLD counts as suffix.
        // From: Issue #1683 | PR #1858
        pub fn root(&self, name: &str) -> Option<String> {
            let labels: Vec<&str> = name.split('.').collect();
            let keep = self.suffix_labels(&labels) + 1;
            (labels.len() >= keep).then(|| labels[labels.len() - keep..].join("."))
        }
    }

    // What: CDN names grouped by nginx handling.
    // Why: roots share a cert; bases and exact own one.
    // From: Issue #1683 | PR #1858
    #[derive(Default)]
    pub struct Hosts {
        pub roots: Vec<String>,
        pub bases: Vec<String>,
        pub exact: Vec<String>,
        pub root_wild: BTreeSet<String>,
    }

    fn add_once(list: &mut Vec<String>, name: &str) {
        if !list.iter().any(|n| n == name) {
            list.push(name.to_string());
        }
    }

    // What: group the cache domain list into Hosts.
    // Why: a bad or rootless row is an error, no skip.
    // From: Issue #1683 | PR #1858
    pub fn hosts(domains: &str, psl: &Psl) -> Result<Hosts, String> {
        let mut h = Hosts::default();
        let rows = domains.lines().map(str::trim);
        for row in rows.filter(|r| !r.is_empty() && !r.starts_with('#')) {
            let (name, wild) = crate::dns::cdn_entry(row)
                .ok_or_else(|| format!("invalid domain entry {row:?}"))?;
            let root = psl
                .root(&name)
                .ok_or_else(|| format!("no registrable root for {name}"))?;
            add_once(&mut h.roots, &root);
            let parent = name.split_once('.').map(|(_, p)| p);
            if name == root {
                if wild {
                    h.root_wild.insert(root);
                }
            } else if wild {
                add_once(&mut h.bases, &name);
            } else if parent != Some(root.as_str()) {
                add_once(&mut h.exact, &name);
            }
        }
        Ok(h)
    }

    // What: stable cert file name for one host.
    // Why: file names never carry raw host text.
    // From: Issue #1683 | PR #1858
    fn cert_id(host: &str, kind: &str) -> String {
        let sum = Sha256::digest(format!("{kind}:{host}").as_bytes());
        sum[..16].iter().map(|b| format!("{b:02x}")).collect()
    }

    impl Hosts {
        // What: (server name key, cert name) pairs.
        // Why: feeds the cert map and the allow map.
        // From: Issue #1683 | PR #1858
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
        // Why: cert::make_leaf issues exactly these.
        // From: Issue #1683 | PR #1858
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
    // From: Issue #1683 | PR #1858
    pub fn template(text: &str, s: &Settings) -> Result<String, String> {
        let mut out = String::with_capacity(text.len());
        let mut rest = text;
        while let Some(at) = rest.find("${") {
            out.push_str(&rest[..at]);
            let after = &rest[at + 2..];
            let close = after.find('}').ok_or("unclosed ${ in nginx template")?;
            let key = &after[..close];
            let value = s.text(key).map_err(|e| format!("nginx template: {e}"))?;
            if value.contains(['\n', '\r', ';', '{', '}']) {
                return Err(format!("{key} holds nginx syntax characters"));
            }
            out.push_str(&value);
            rest = &after[close + 1..];
        }
        out.push_str(rest);
        Ok(out)
    }

    fn map_row(out: &mut String, key: &str, value: &str) {
        out.push_str(&format!("    {key:<45} {value};\n"));
    }

    fn ends_with_re(base: &str, one_label: bool) -> String {
        let label = if one_label { "[^.]+" } else { ".+" };
        format!("\"~^{label}\\.{}$\"", base.replace('.', "\\."))
    }

    // What: all settings the files need, read once.
    // Why: one read; a missing key stops the render.
    // From: Issue #1683 | PR #1858
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

    fn plan(s: &Settings) -> Result<Plan, String> {
        let strict = match s.text("PROXY_SECURITY_MODE")?.as_str() {
            "strict" => true,
            "lazy" => false,
            other => return Err(format!("PROXY_SECURITY_MODE {other} is not lazy/strict")),
        };
        let lo = s.text("LOOPBACK_BIND_IP")?;
        let at = |k: &str| -> Result<String, String> { Ok(format!("{lo}:{}", s.uint(k)?)) };
        Ok(Plan {
            strict,
            cidrs: s.list("PROXY_ALLOWED_CLIENT_CIDRS"),
            refuse: at("NGINX_DISCARD_PORT")?,
            refuse_relay: at("NGINX_REFUSE_RELAY_PORT")?,
            origin: format!(
                "$ssl_preread_server_name:{}",
                s.uint("NGINX_ORIGIN_HTTPS_PORT")?
            ),
            acl: s.text("NGINX_CLIENT_ACL_FILE")?,
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
        out.push_str(&format!(
            "    listen {0};\n    listen [::]:{0};\n",
            p.passthrough
        ));
        out.push_str(&format!("    include {};\n    ssl_preread on;\n", p.acl));
        out.push_str("    proxy_pass $stream_backend;\n");
        out.push_str(&p.timeouts);
        out.push_str("}\n");
        // What: the refuse target sends a TLS alert.
        // Why: live: a closed port logged [error].
        // From: Issue #1683 | PR #1980
        out.push_str(&format!(
            "\nserver {{\n    listen {} ssl;\n    ssl_reject_handshake on;\n}}\n",
            p.refuse
        ));
        out
    }

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

    fn relay_server(p: &Plan, listen: &str, body: &str) -> String {
        format!(
            "server {{\n    listen {listen} proxy_protocol;\n    set_real_ip_from {};\n{body}{}}}\n",
            p.lo, p.timeouts
        )
    }

    fn dispatch_file(p: &Plan, h: &Hosts) -> String {
        let mut out = format!("{HEAD}map $ssl_preread_server_name $https_dispatch_backend {{\n");
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
        bases.sort_by(|a, b| b.len().cmp(&a.len()).then_with(|| b.cmp(a)));
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
        out.push_str(&format!("    listen {0};\n    listen [::]:{0};\n", p.https));
        out.push_str(&format!("    include {};\n    ssl_preread on;\n", p.acl));
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
        // What: refuse target of the dispatch, with PROXY.
        // Why: a TLS alert instead of a reset and [error].
        // From: Issue #1683 | PR #1980
        out.push_str(&format!(
            "\nserver {{\n    listen {} ssl proxy_protocol;\n    ssl_reject_handshake on;\n}}\n",
            p.refuse_relay
        ));
        out
    }

    // What: all generated files: (path, body).
    // Why: the ui writes them; nginx includes them.
    // From: Issue #1683 | PR #1858
    pub fn files(s: &Settings, h: &Hosts, https: bool) -> Result<Vec<(String, String)>, String> {
        let p = plan(s)?;
        let keys = h.keys();
        let mut out = vec![
            (p.acl.clone(), acl_file(&p)),
            (s.text("NGINX_STREAM_TARGETS_FILE")?, stream_file(&p, &keys)),
        ];
        if !https {
            return Ok(out);
        }
        let fallback = s.text("NGINX_DEFAULT_CERT")?;
        out.push((
            s.text("NGINX_HTTPS_MAP_FILE")?,
            https_map(&p, &keys, &fallback),
        ));
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
// From: Issue #1683 | PR #1858
pub mod apply {
    use crate::config::{Change, Effect};
    use crate::docker::{Action, Api, Error};
    use std::collections::BTreeMap;
    use std::time::Duration;

    // What: strongest effect per owning container.
    // Why: one restart already covers a reload.
    // From: Issue #1683 | PR #1858
    pub fn plan(changes: &[Change]) -> BTreeMap<String, Effect> {
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
    // From: Issue #1683 | PR #1858
    #[derive(Debug)]
    pub enum Outcome {
        Live,
        Done(Action),
        NeedsRecreate,
        Failed(Error),
    }

    fn action_of(effect: Effect) -> Option<Action> {
        match effect {
            Effect::Live | Effect::Recreate => None,
            Effect::Reload => Some(Action::Reload),
            Effect::Restart | Effect::Container => Some(Action::Restart),
        }
    }

    // What: an owner's reload commands, "owner:cmd+arg".
    // Why: RELOAD_EXEC in the SOT; no list in code.
    // From: Issue #1683
    fn exec_cmds<'a>(exec: &'a [String], owner: &'a str) -> impl Iterator<Item = Vec<&'a str>> {
        exec.iter().filter_map(move |e| {
            let (o, cmd) = e.split_once(':')?;
            (o == owner).then(|| cmd.split('+').collect())
        })
    }

    // What: run every reload command; stop at the first.
    // Why: a failed reload is shown, never hidden.
    // From: Issue #1683
    async fn reload_exec(
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

    // What: carry out the plan: HUP, exec or restart.
    // Why: openrc-init drops HUP; only hup owners get it.
    // From: Issue #1683 | PR #1980
    #[allow(clippy::too_many_arguments)]
    pub async fn run(
        api: &Api,
        plan: &BTreeMap<String, Effect>,
        hup: &[String],
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
                // Why: DoMe 06.11.: a toggle restarted dns.
                // From: Issue #1683
                Some(Action::Reload) if exec_cmds(exec, owner).next().is_some() => {
                    reload_exec(api, &container_of(owner), exec, owner, limit).await
                }
                Some(Action::Reload) if !hup.contains(owner) => {
                    let a = Action::Restart;
                    match api.act(&container_of(owner), a, grace, limit).await {
                        Ok(()) => Outcome::Done(a),
                        Err(e) => Outcome::Failed(e),
                    }
                }
                Some(a) => match api.act(&container_of(owner), a, grace, limit).await {
                    Ok(()) => Outcome::Done(a),
                    Err(e) => Outcome::Failed(e),
                },
            };
            out.push((owner.clone(), outcome));
        }
        out
    }
}

// What: every config file of the stack.
// Why: the ui calls one function; paths from SOT.
// From: Issue #1683 | PR #1858
pub mod render {
    use crate::config::Settings;
    use crate::recursor_conf::{self, Which};
    use crate::{chrony, dhcp, dnsmasq_conf, kea_conf, log, nginx_conf, pdns_conf};
    use std::path::{Path, PathBuf};

    // What: secrets the config files embed.
    // Why: the caller reads them from the store.
    // From: Issue #1683 | PR #1858
    pub struct Secrets {
        pub pdns_api_key: String,
        pub recursor_api_key: String,
        pub tsig_name: String,
        pub tsig_secret: String,
    }

    // What: one file and its owning container.
    // Why: apply::plan needs the owner per change.
    // From: Issue #1683 | PR #1858
    pub struct File {
        pub owner: &'static str,
        pub path: PathBuf,
        pub body: String,
    }

    // What: collector of files and errors.
    // Why: every bad value is named; nothing half done.
    // From: Issue #1683 | PR #1858
    struct Out<'a> {
        s: &'a Settings,
        files: Vec<File>,
        errs: Vec<String>,
    }

    impl Out<'_> {
        fn add_file(&mut self, owner: &'static str, path_key: &str, body: Result<String, String>) {
            match (self.s.text(path_key), body) {
                (Ok(p), Ok(body)) => self.files.push(File {
                    owner,
                    path: PathBuf::from(p),
                    body,
                }),
                (Err(e), _) | (_, Err(e)) => self.errs.push(e),
            }
        }
        fn put_json(
            &mut self,
            owner: &'static str,
            key: &str,
            v: Result<serde_json::Value, String>,
        ) {
            let body = v.and_then(|v| serde_json::to_string_pretty(&v).map_err(|e| e.to_string()));
            self.add_file(owner, key, body);
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

    fn dns_files(o: &mut Out, sec: &Secrets, names: &[String]) {
        let s = o.s;
        o.add_file("services", "CHRONY_CONF_FILE", chrony::render(s));
        o.add_file("services", "SYSLOG_CONF_FILE", log::render(s));
        o.add_file(
            "services",
            "SNMPD_CONF_FILE",
            crate::snmp::render(s, &[], &[]),
        );
        o.add_file(
            "dns",
            "PDNS_CONF_FILE",
            pdns_conf::auth(s, &sec.pdns_api_key),
        );
        for (which, ip_key) in [(Which::Http, "IP_HTTP"), (Which::Https, "IP_HTTPS")] {
            let Ok(answer) = s.text(ip_key) else { continue };
            let rpz_key = which.key("RPZ_FILE");
            let lua_key = which.key("LUA_FILE");
            // What: serial from the zone body itself.
            // Why: a clock serial restarts dns each save.
            // From: Issue #1683 | PR #1980
            let serial = recursor_conf::rpz(s, names, &answer, 0)
                .map(|b| content_serial(&b))
                .unwrap_or(1);
            o.add_file(
                "dns",
                &rpz_key,
                recursor_conf::rpz(s, names, &answer, serial),
            );
            let lua = s.text(&rpz_key).and_then(|p| recursor_conf::lua(s, &p));
            o.add_file("dns", &lua_key, lua);
            let yaml = s
                .text(&lua_key)
                .and_then(|l| recursor_conf::yaml(s, which, &sec.recursor_api_key, &l));
            o.add_file("dns", &which.key("CONF_FILE"), yaml);
        }
        if s.flag("DNS_FILTER_AAAA").unwrap_or(false) {
            let body = Ok(recursor_conf::AAAA_FILTER_LUA.to_string());
            o.add_file("dns", "RECURSOR_AAAA_LUA_FILE", body);
        }
    }

    fn dhcp_files(o: &mut Out, sec: &Secrets) {
        let s = o.s;
        // What: the mode file names the dhcp runlevel.
        // Why: the dhcp entry reads it at every start.
        // From: Issue #1683 | PR #1980
        let mode = s.text("DHCP_MODE").map(|m| format!("{m}\n"));
        o.add_file("dhcp", "DHCP_MODE_FILE", mode);
        match dhcp::Mode::from_settings(s) {
            Ok(dhcp::Mode::Off) => {}
            Ok(dhcp::Mode::Kea) => {
                let kept = s
                    .text("KEA_DHCP4_CONF_FILE")
                    .ok()
                    .and_then(|p| std::fs::read(p).ok())
                    .and_then(|b| serde_json::from_slice(&b).ok());
                o.put_json(
                    "dhcp",
                    "KEA_DHCP4_CONF_FILE",
                    kea_conf::dhcp4(s, kept.as_ref()),
                );
                o.put_json("dhcp", "KEA_CTRL_CONF_FILE", kea_conf::ctrl_agent(s));
                let ddns = kea_conf::ddns(s, &sec.tsig_name, &sec.tsig_secret);
                o.put_json("dhcp", "KEA_DDNS_CONF_FILE", ddns);
            }
            Ok(mode) => o.add_file("dhcp", "DNSMASQ_CONF_FILE", dnsmasq_conf::render(s, mode)),
            Err(e) => o.errs.push(e),
        }
    }

    fn read(path: &PathBuf) -> Result<String, String> {
        std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))
    }

    fn nginx_files(o: &mut Out, domains: &str) -> Result<(), String> {
        let s = o.s;
        let src = PathBuf::from(s.text("NGINX_TEMPLATE_DIR")?);
        let dst = PathBuf::from(s.text("NGINX_CONF_DIR")?);
        let psl = nginx_conf::Psl::parse(&read(&src.join(s.text("NGINX_PSL_FILE")?))?);
        let hosts = nginx_conf::hosts(domains, &psl)?;
        let https = s.flag("HTTPS_ENABLED")?;
        for name in s.list("NGINX_TEMPLATES") {
            if !https && name.ends_with("https.conf") {
                continue;
            }
            let body = nginx_conf::template(&read(&src.join(&name))?, s)?;
            o.files.push(File {
                owner: "proxy",
                path: dst.join(&name),
                body,
            });
        }
        for (rel, body) in nginx_conf::files(s, &hosts, https)? {
            o.files.push(File {
                owner: "proxy",
                path: dst.join(rel),
                body,
            });
        }
        // What: the static health body nginx serves.
        // Why: proxy-params.conf aliases it; ui owns files.
        // From: Issue #1683 | PR #1980
        o.files.push(File {
            owner: "proxy",
            path: dst.join(s.text("NGINX_HEALTHZ_FILE")?),
            body: format!("{}\n", s.text("NGINX_HEALTHZ_BODY")?),
        });
        Ok(())
    }

    // What: octal mode from a SOT key.
    // Why: the SOT owns every file mode.
    // From: Issue #1683 | PR #1980
    fn mode_of(s: &Settings, key: &str) -> Result<u32, String> {
        u32::from_str_radix(&s.text(key)?, 8).map_err(|e| format!("{key}: {e}"))
    }

    // What: set group and mode of one path.
    // Why: nginx workers read keys by the shared gid.
    // From: Issue #1683 | PR #1980
    fn grant(p: &Path, gid: Option<u32>, mode: u32) -> Result<(), String> {
        use std::os::unix::fs::PermissionsExt;
        let err = |e: std::io::Error| format!("{}: {e}", p.display());
        std::os::unix::fs::chown(p, None, gid).map_err(err)?;
        std::fs::set_permissions(p, std::fs::Permissions::from_mode(mode)).map_err(err)
    }

    // What: drop every leaf when the CA changed.
    // Why: leaves of an old CA fail on every client.
    // From: Issue #1683 | PR #1980
    fn drop_stale_leaves(ca_crt: &Path, dir: &Path, stamp: &Path) -> Result<(), String> {
        let print = crate::cert::fingerprint(ca_crt)?;
        if std::fs::read_to_string(stamp).ok().as_deref() == Some(print.as_str()) {
            return Ok(());
        }
        let list = std::fs::read_dir(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        for entry in list {
            let file = entry.map_err(|e| e.to_string())?.path();
            if matches!(
                file.extension().and_then(|x| x.to_str()),
                Some("crt" | "key")
            ) {
                std::fs::remove_file(&file).map_err(|e| format!("{}: {e}", file.display()))?;
            }
        }
        std::fs::write(stamp, print).map_err(|e| format!("{}: {e}", stamp.display()))
    }

    // What: make the CA and every missing leaf cert.
    // Why: HTTPS mode needs one cert per map name.
    // From: Issue #1683 | PR #1980
    pub fn issue_certs(s: &Settings) -> Result<usize, String> {
        if !s.flag("HTTPS_ENABLED")? {
            return Ok(0);
        }
        let root = PathBuf::from(s.text("NGINX_DIR")?);
        let ca = root.join(s.text("NGINX_SUBDIR_CA")?);
        let dir = root.join(s.text("NGINX_SUBDIR_CERTS")?);
        let (ca_key, ca_crt) = (
            ca.join(s.text("CA_KEY_FILE")?),
            ca.join(s.text("CA_CERT_FILE")?),
        );
        let serial = ca.join(s.text("CA_SERIAL_FILE")?);
        let gid = s.text("LANCACHE_RUNTIME_GID")?;
        let gid = Some(gid.parse::<u32>().map_err(|e| format!("gid {gid}: {e}"))?);
        for d in [&ca, &dir] {
            std::fs::create_dir_all(d).map_err(|e| format!("{}: {e}", d.display()))?;
        }
        grant(&dir, gid, mode_of(s, "CERT_DIR_MODE")?)?;
        if !(ca_crt.exists() && ca_key.exists()) {
            crate::cert::make_ca(
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
        grant(&ca_key, None, mode_of(s, "CA_KEY_MODE")?)?;
        drop_stale_leaves(&ca_crt, &dir, &dir.join(s.text("CA_STAMP_FILE")?))?;
        let tpl = PathBuf::from(s.text("NGINX_TEMPLATE_DIR")?);
        let psl = nginx_conf::Psl::parse(&read(&tpl.join(s.text("NGINX_PSL_FILE")?))?);
        let hosts = nginx_conf::hosts(&crate::cdn::effective(s)?, &psl)?;
        let mut want = hosts.certs();
        // What: default cert: DNS name and IP_HTTPS.
        // Why: clients without SNI or by IP get this cert.
        // From: Issue #1683 | PR #1980
        let mut names = vec![s.text("DEFAULT_CERT_DNS")?];
        names.extend(s.text("IP_HTTPS").ok());
        want.push((s.text("NGINX_DEFAULT_CERT")?, names));
        let (key_mode, crt_mode) = (mode_of(s, "CERT_KEY_MODE")?, mode_of(s, "CERT_FILE_MODE")?);
        let mut made = 0;
        for (name, sans) in want {
            let (key, crt) = (
                dir.join(format!("{name}.key")),
                dir.join(format!("{name}.crt")),
            );
            if !(crt.exists() && key.exists()) {
                crate::cert::make_leaf(
                    &ca_key,
                    &ca_crt,
                    &serial,
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

    // What: render all files; report every error.
    // Why: one call for the ui; nothing half written.
    // From: Issue #1683 | PR #1858
    pub fn all(s: &Settings, sec: &Secrets) -> Result<Vec<File>, Vec<String>> {
        let mut o = Out {
            s,
            files: Vec::new(),
            errs: Vec::new(),
        };
        let domains = match crate::cdn::effective(s) {
            Ok(d) => d,
            Err(e) => {
                o.errs.push(e);
                String::new()
            }
        };
        let names: Vec<String> = domains
            .lines()
            .filter_map(crate::dns::cdn_entry)
            .map(|(n, _)| n)
            .collect();
        dns_files(&mut o, sec, &names);
        dhcp_files(&mut o, sec);
        if let Err(e) = nginx_files(&mut o, &domains) {
            o.errs.push(e);
        }
        if o.errs.is_empty() {
            Ok(o.files)
        } else {
            Err(o.errs)
        }
    }

    // What: only the dns files, for a secondary.
    // Why: a secondary runs only the dns container.
    // From: Issue #1683 | PR #1980
    pub fn dns_only(s: &Settings, sec: &Secrets) -> Result<Vec<File>, Vec<String>> {
        let mut o = Out {
            s,
            files: Vec::new(),
            errs: Vec::new(),
        };
        let domains = crate::cdn::effective(s).map_err(|e| vec![e])?;
        let names: Vec<String> = domains
            .lines()
            .filter_map(crate::dns::cdn_entry)
            .map(|(n, _)| n)
            .collect();
        dns_files(&mut o, sec, &names);
        o.files.retain(|f| f.owner == "dns");
        if o.errs.is_empty() {
            Ok(o.files)
        } else {
            Err(o.errs)
        }
    }
}

// What: one SNTP query (RFC 4330).
// Why: the ui shows whether chrony answers.
// From: Issue #1683 | PR #1858
pub mod ntp {
    use std::net::UdpSocket;
    use std::time::Duration;

    // What: client request: version 4, mode 3.
    // Why: RFC 4330 first byte; rest stays zero.
    // From: Issue #1683 | PR #1858
    const REQUEST_HEAD: u8 = 0x23;
    const PACKET: usize = 48;
    const MODE_SERVER: u8 = 4;

    fn ask(host: &str, port: u64, wait: Duration) -> std::io::Result<[u8; PACKET]> {
        let sock = UdpSocket::bind("0.0.0.0:0")?;
        sock.set_read_timeout(Some(wait))?;
        let mut req = [0u8; PACKET];
        req[0] = REQUEST_HEAD;
        sock.send_to(&req, format!("{host}:{port}"))?;
        let mut reply = [0u8; PACKET];
        let n = sock.recv(&mut reply)?;
        if n < PACKET {
            return Err(std::io::ErrorKind::UnexpectedEof.into());
        }
        Ok(reply)
    }

    // What: true on a usable server reply.
    // Why: mode 4 and stratum 1..15 mean synced.
    // From: Issue #1683 | PR #1858
    pub fn answers(host: &str, port: u64, wait: Duration) -> bool {
        ask(host, port, wait)
            .map(|r| r[0] & 0x07 == MODE_SERVER && (1..=15).contains(&r[1]))
            .unwrap_or(false)
    }
}

// What: proxy access log: recent requests, totals.
// Why: dashboard and logs page share one parser.
// From: Issue #1683 | PR #1858
pub mod access {
    use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
    use std::path::{Path, PathBuf};

    // What: one request in nginx log_format cache.
    // Why: the ui lists host, path, status, size.
    // From: Issue #1683 | PR #1858
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
    // From: Issue #1683 | PR #1858
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
    // From: Issue #1683 | PR #1858
    pub fn files(dir: &Path) -> Vec<PathBuf> {
        let Ok(rd) = std::fs::read_dir(dir) else {
            return Vec::new();
        };
        let mut out: Vec<PathBuf> = rd
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|x| x == "log"))
            .collect();
        out.sort();
        out
    }

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

    // What: last `limit` lines of the newest file.
    // Why: reads from the end; big logs stay cheap.
    // From: Issue #1683 | PR #1858
    pub fn tail_lines(dir: &Path, limit: usize, chunk: u64) -> Vec<String> {
        let Some(path) = files(dir).pop() else {
            return Vec::new();
        };
        let Ok((buf, cut)) = read_back(&path, limit, chunk) else {
            return Vec::new();
        };
        let text = String::from_utf8_lossy(&buf);
        let lines: Vec<String> = text
            .lines()
            .skip(usize::from(cut))
            .map(String::from)
            .collect();
        let from = lines.len().saturating_sub(limit);
        lines[from..].to_vec()
    }

    // What: last `limit` cache requests.
    // Why: dashboard list; other lines are skipped.
    // From: Issue #1683 | PR #1858
    pub fn tail(dir: &Path, limit: usize, chunk: u64) -> Vec<Entry> {
        let lines = tail_lines(dir, limit.saturating_mul(4), chunk);
        let found: Vec<Entry> = lines.iter().filter_map(|l| parse(l)).collect();
        let from = found.len().saturating_sub(limit);
        found[from..].to_vec()
    }

    // What: totals over all proxy log files.
    // Why: hit rate and traffic on the dashboard.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Debug, Default, serde::Serialize)]
    pub struct Stats {
        pub hits: u64,
        pub misses: u64,
        pub other: u64,
        pub total_requests: u64,
        pub total_bytes: u64,
        pub hit_pct: f64,
    }

    impl Stats {
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

    // What: count requests, hits and bytes.
    // Why: HIT is a hit; MISS and EXPIRED a miss.
    // From: Issue #1683 | PR #1858
    pub fn stats(dir: &Path) -> Stats {
        let mut st = Stats::default();
        for path in files(dir) {
            let Ok(f) = std::fs::File::open(&path) else {
                continue;
            };
            for line in BufReader::new(f).lines().map_while(Result::ok) {
                if let Some(e) = parse(&line) {
                    st.count(&e);
                }
            }
        }
        let judged = st.hits + st.misses;
        if judged > 0 {
            st.hit_pct = st.hits as f64 * 100.0 / judged as f64;
        }
        st
    }
}

// What: byte count as text in binary units.
// Why: all ui pages show sizes the same way.
// From: Issue #1683 | PR #1858
pub mod human {
    const UNITS: [&str; 6] = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];

    // What: 1536 becomes "1.5 KiB".
    // Why: whole numbers only; one decimal is enough.
    // From: Issue #1683 | PR #1858
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
// From: Issue #1683 | PR #1858
pub mod cdn {
    use crate::config::Settings;

    // What: one row of the domain table.
    // Why: the ui shows shipped and own rows apart.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Debug, serde::Serialize)]
    pub struct Row {
        pub display: String,
        pub is_default: bool,
        pub enabled: bool,
        pub is_valid: bool,
    }

    fn new_row(name: String, is_default: bool, enabled: bool) -> Row {
        Row {
            is_valid: crate::dns::cdn_entry(&name).is_some(),
            display: name,
            is_default,
            enabled,
        }
    }

    // What: shipped rows from the image file.
    // Why: blanks and # comments are not domains.
    // From: Issue #1683 | PR #1858
    pub fn defaults(s: &Settings) -> Result<Vec<String>, String> {
        let path = s.text("CDN_DEFAULT_DOMAINS_FILE")?;
        let text = std::fs::read_to_string(&path).map_err(|e| format!("{path}: {e}"))?;
        let keep = |l: &&str| !l.is_empty() && !l.starts_with('#');
        Ok(text
            .lines()
            .map(str::trim)
            .filter(keep)
            .map(str::to_ascii_lowercase)
            .collect())
    }

    // What: all rows for the ui.
    // Why: shipped rows carry their on/off state.
    // From: Issue #1683 | PR #1858
    pub fn parse_rows(s: &Settings) -> Result<Vec<Row>, String> {
        let off = s.list("CDN_DISABLED_DOMAINS");
        let mut out = Vec::new();
        for d in defaults(s)? {
            let on = !off.contains(&d);
            out.push(new_row(d, true, on));
        }
        for d in s.list("CDN_CUSTOM_DOMAINS") {
            out.push(new_row(d, false, true));
        }
        Ok(out)
    }

    // What: enabled rows, one per line.
    // Why: input of the RPZ and nginx host maps.
    // From: Issue #1683 | PR #1858
    pub fn effective(s: &Settings) -> Result<String, String> {
        let mut out = String::new();
        for r in parse_rows(s)?.into_iter().filter(|r| r.enabled) {
            out.push_str(&r.display);
            out.push('\n');
        }
        Ok(out)
    }
}

// What: Kea Control Agent client (REST, JSON).
// Why: leases and subnets go through Kea itself.
// From: Issue #1683 | PR #1858
pub mod kea {
    use serde_json::{Value, json};

    // What: Kea result codes.
    // Why: Kea docs: 0 success, 3 empty answer.
    // From: Issue #1683 | PR #1858
    const RESULT_OK: i64 = 0;
    const RESULT_EMPTY: i64 = 3;

    // What: one control agent address.
    // Why: commands reach dhcp4 behind it.
    // From: Issue #1683 | PR #1858
    pub struct Api {
        client: reqwest::Client,
        url: String,
    }

    impl Api {
        // What: client for one agent URL.
        // Why: the caller owns the shared client.
        // From: Issue #1683 | PR #1858
        pub fn new(client: reqwest::Client, url: &str) -> Self {
            Api {
                client,
                url: url.into(),
            }
        }

        // What: send one command; return arguments.
        // Why: 0 is ok, 3 is empty, rest is an error.
        // From: Issue #1683 | PR #1858
        pub async fn command(&self, command: &str, args: Option<Value>) -> Result<Value, String> {
            let fail = |e: String| format!("kea {command}: {e}");
            let mut body = json!({"command": command, "service": ["dhcp4"]});
            if let Some(a) = args {
                body["arguments"] = a;
            }
            let reply = self
                .client
                .post(&self.url)
                .json(&body)
                .send()
                .await
                .map_err(|e| fail(crate::http::error_chain(&e)))?;
            let all: Value = reply.json().await.map_err(|e| fail(e.to_string()))?;
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
        // From: Issue #1683 | PR #1858
        pub async fn config(&self) -> Result<Value, String> {
            self.command("config-get", None).await
        }

        // What: apply and save a new config.
        // Why: config-set applies; config-write saves.
        // From: Issue #1683 | PR #1858
        pub async fn set_config(&self, config: Value) -> Result<(), String> {
            self.command("config-set", Some(config)).await?;
            self.command("config-write", Some(json!({}))).await?;
            Ok(())
        }

        // What: all IPv4 leases.
        // Why: lease_cmds hook; the ui lists them.
        // From: Issue #1683 | PR #1858
        pub async fn leases(&self) -> Result<Vec<Value>, String> {
            let args = self.command("lease4-get-all", None).await?;
            Ok(args["leases"].as_array().cloned().unwrap_or_default())
        }

        // What: delete one lease by address.
        // Why: frees the address for the next client.
        // From: Issue #1683 | PR #1858
        pub async fn release(&self, ip: &str) -> Result<(), String> {
            let args = json!({"ip-address": ip});
            self.command("lease4-del", Some(args)).await?;
            Ok(())
        }
    }
}

// What: statistics: SNMP samples into RRD files.
// Why: replaces Netdata with native rrdtool.
// From: Issue #1683 | PR #1858
pub mod rrd {
    use crate::config::Settings;
    use std::path::{Path, PathBuf};
    use std::process::Command;

    // What: RRD data source types we accept.
    // Why: rrdtool create: GAUGE, COUNTER, DERIVE.
    // From: Issue #1683 | PR #1858
    const KINDS: [&str; 3] = ["GAUGE", "COUNTER", "DERIVE"];

    // What: one data source of a graph.
    // Why: name, SNMP OID and RRD type.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Debug)]
    pub struct Source {
        pub ds: String,
        pub oid: String,
        pub kind: String,
        pub scale: Option<f64>,
    }

    // What: one graph, stored in one RRD file.
    // Why: SOT row name:ds=oid=TYPE+ds=oid=TYPE.
    // From: Issue #1683 | PR #1858
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

    // What: Docker stats fields a container graph reads.
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

    fn is_plain(word: &str) -> bool {
        !word.is_empty() && word.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
    }

    fn source(text: &str) -> Result<Source, String> {
        let parts: Vec<&str> = text.split('=').collect();
        let (ds, oid, kind, scale) = match parts[..] {
            [ds, oid, kind] => (ds, oid, kind, None),
            [ds, oid, kind, f] => (ds, oid, kind, f.parse::<f64>().ok()),
            _ => ("", "", "", None),
        };
        let bad_scale = parts.len() == 4 && scale.is_none();
        if !is_plain(ds) || !KINDS.contains(&kind) || bad_scale {
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

    fn graph(row: &str, tab: &str) -> Result<Graph, String> {
        let (name, list) = row
            .split_once(':')
            .ok_or_else(|| format!("stats row {row:?} needs name:sources"))?;
        if !is_plain(name) || !is_plain(tab) {
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
    // From: Issue #1683 | PR #1858
    pub fn graphs(s: &Settings) -> Result<Vec<Graph>, String> {
        s.list("STATS_GRAPHS")
            .iter()
            .map(|r| graph(r, MACHINE))
            .collect()
    }

    // What: one graph set per container.
    // Why: DoMe 05.11.: no choice of container.
    // From: Issue #1683 | PR #1980
    pub fn container_graphs(s: &Settings) -> Result<Vec<Graph>, String> {
        let mut out = Vec::new();
        for tab in s.list("STATS_CONTAINERS") {
            for row in s.list("STATS_CONTAINER_GRAPHS") {
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

    // What: program values, row tab.name:sources.
    // Why: 01.11.: PowerDNS, nginx, Kea, chrony values.
    // From: Issue #1683 | PR #1980
    pub fn service_graphs(s: &Settings) -> Result<Vec<Graph>, String> {
        let tabs = s.list("STATS_CONTAINERS");
        let mut out = Vec::new();
        for row in s.list("STATS_SERVICE_GRAPHS") {
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
        got.map_or_else(|| "U".into(), |n| n.to_string())
    }

    // What: RRD file of one graph.
    // Why: one file per graph under STATS_DIR.
    // From: Issue #1683 | PR #1858
    pub fn file(s: &Settings, g: &Graph) -> Result<PathBuf, String> {
        let dir = s.text("STATS_DIR")?;
        Ok(Path::new(&dir).join(format!("{}.rrd", g.name)))
    }

    fn run(cmd: &mut Command) -> Result<Vec<u8>, String> {
        let out = cmd.output().map_err(|e| format!("{cmd:?}: {e}"))?;
        if !out.status.success() {
            let why = String::from_utf8_lossy(&out.stderr);
            return Err(format!("{cmd:?}: {}", why.trim()));
        }
        Ok(out.stdout)
    }

    // What: create the RRD when it is missing.
    // Why: step, heartbeat and archives from SOT.
    // From: Issue #1683 | PR #1858
    pub fn ensure(s: &Settings, g: &Graph) -> Result<(), String> {
        let path = file(s, g)?;
        if path.exists() {
            return Ok(());
        }
        // What: create the stats dir before rrdtool runs.
        // Why: an existing ui volume may lack the folder.
        // From: Issue #1683 | PR #1980
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        }
        let step = s.uint("STATS_STEP")?;
        let beat = step.saturating_mul(s.uint("STATS_HEARTBEAT_STEPS")?);
        let mut cmd = Command::new("rrdtool");
        cmd.arg("create")
            .arg(&path)
            .arg("--step")
            .arg(step.to_string());
        for src in &g.sources {
            // What: a gauge may go below zero.
            // Why: time offsets are negative half the time.
            // From: Issue #1683 | PR #1980
            let min = if src.kind == "GAUGE" { "U" } else { "0" };
            cmd.arg(format!("DS:{}:{}:{beat}:{min}:U", src.ds, src.kind));
        }
        for rra in s.list("STATS_RRAS") {
            cmd.arg(format!("RRA:{rra}"));
        }
        run(&mut cmd)?;
        Ok(())
    }

    fn number_or_unknown(line: &str) -> String {
        match line.split_whitespace().next() {
            Some(v) if v.parse::<f64>().is_ok() => v.into(),
            _ => "U".into(),
        }
    }

    // What: read all sources once, then store.
    // Why: snmpget -Oqv prints one value per line.
    // From: Issue #1683 | PR #1858
    pub fn sample(s: &Settings, g: &Graph) -> Result<(), String> {
        let mut get = Command::new("snmpget");
        get.args(["-v2c", "-Oqv", "-c"]);
        get.arg(s.text("SNMP_COMMUNITY")?)
            .arg(s.text("STATS_SNMP_TARGET")?);
        get.args(g.sources.iter().map(|x| &x.oid));
        let text = String::from_utf8_lossy(&run(&mut get)?).into_owned();
        let values: Vec<String> = text.lines().map(number_or_unknown).collect();
        store(s, g, &values)
    }

    // What: write one sample row into the RRD.
    // Why: SNMP and Docker stats share the files.
    // From: Issue #1683 | PR #1980
    pub fn store(s: &Settings, g: &Graph, values: &[String]) -> Result<(), String> {
        ensure(s, g)?;
        if values.len() != g.sources.len() {
            let (got, want) = (values.len(), g.sources.len());
            return Err(format!("{}: {got} values for {want} sources", g.name));
        }
        let mut put = Command::new("rrdtool");
        put.arg("update")
            .arg(file(s, g)?)
            .arg(format!("N:{}", values.join(":")));
        run(&mut put)?;
        Ok(())
    }

    // What: PNG of one graph over a time range.
    // Why: rrdtool draws; the page shows the image.
    // From: Issue #1683 | PR #1858
    pub fn png(s: &Settings, g: &Graph, range: &str, dark: bool) -> Result<Vec<u8>, String> {
        if !s.list("STATS_RANGES").iter().any(|r| r == range) {
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
        // Why: DoMe 05.11.: sizes differed per tab.
        // From: Issue #1683 | PR #1980
        cmd.arg("--full-size-mode");
        // What: plain numbers when each factor shrinks.
        // Why: "233.5m" unreadable; kB x1024 keeps units.
        // From: Issue #1683 | PR #1980
        let plain = g.sources.iter().all(|x| x.scale.is_some_and(|k| k < 1.0));
        let unit = if plain { "" } else { "%s" };
        if plain {
            cmd.arg("--units-exponent").arg("0");
        }

        // What: larger fonts for axis, title and legend.
        // Why: DoMe 05.11.: values needed a magnifier.
        // From: Issue #1683 | PR #1980
        for f in s.list("STATS_FONTS") {
            cmd.arg("--font").arg(f);
        }
        if dark {
            for c in s.list("STATS_DARK_COLOURS") {
                cmd.arg("--color").arg(c);
            }
        }
        let colours = s.list("STATS_LINE_COLOURS");
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

            // What: factor per source, e.g. ns to percent.
            // Why: Docker counts CPU time in nanoseconds.
            // From: Issue #1683 | PR #1980
            let factor = src.scale.unwrap_or(1.0);
            cmd.arg(format!("CDEF:{0}={0}_raw,{factor},*", src.ds));
            cmd.arg(format!("LINE2:{0}{colour}:{0:<8}", src.ds));

            // What: now, average and max as text per line.
            // Why: exact values without reading the axis.
            // From: Issue #1683 | PR #1980
            cmd.arg(format!("GPRINT:{}:LAST:now %8.2lf{unit}", src.ds));
            cmd.arg(format!("GPRINT:{}:AVERAGE:avg %8.2lf{unit}", src.ds));
            cmd.arg(format!("GPRINT:{}:MAX:max %8.2lf{unit}\\l", src.ds));
        }
        run(&mut cmd)
    }
}

// What: file tidying: safe paths, age, size, xz.
// Why: the watchdog decides when; this does how.
// From: Issue #1683 | PR #1858
pub mod tidy {
    use std::path::{Component, Path, PathBuf};
    use std::process::Command;

    // What: seconds of one day.
    // Why: ages and daily stamps count in days.
    // From: Issue #1683 | PR #1858
    pub const DAY: u64 = 86_400;

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
    // From: Issue #1683 | PR #1858
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

    // What: one regular file with its facts.
    // Why: links are never followed or removed.
    // From: Issue #1683 | PR #1858
    pub struct Item {
        pub path: PathBuf,
        pub size: u64,
        pub mtime: u64,
    }

    fn mtime(meta: &std::fs::Metadata) -> u64 {
        meta.modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map_or(0, |d| d.as_secs())
    }

    // What: all regular files below a folder.
    // Why: base for age, size and pack runs.
    // From: Issue #1683 | PR #1858
    pub fn files(dir: &Path) -> Vec<Item> {
        let mut out = Vec::new();
        let mut todo = vec![dir.to_path_buf()];
        while let Some(d) = todo.pop() {
            let Ok(rd) = std::fs::read_dir(&d) else {
                continue;
            };
            for e in rd.flatten() {
                let Ok(meta) = std::fs::symlink_metadata(e.path()) else {
                    continue;
                };
                if meta.is_dir() {
                    todo.push(e.path());
                } else if meta.is_file() {
                    out.push(Item {
                        path: e.path(),
                        size: meta.len(),
                        mtime: mtime(&meta),
                    });
                }
            }
        }
        out
    }

    // What: remove files older than days.
    // Why: returns count removed and the errors.
    // From: Issue #1683 | PR #1858
    pub fn drop_older(dir: &Path, days: u64, now: u64) -> (usize, Vec<String>) {
        let (mut gone, mut errs) = (0, Vec::new());
        for f in files(dir) {
            if now.saturating_sub(f.mtime) / DAY <= days {
                continue;
            }
            match std::fs::remove_file(&f.path) {
                Ok(()) => gone += 1,
                Err(e) => errs.push(format!("{}: {e}", f.path.display())),
            }
        }
        (gone, errs)
    }

    // What: remove oldest until under budget.
    // Why: files written today stay; returns size.
    // From: Issue #1683 | PR #1858
    pub fn fit_budget(dir: &Path, budget: u64, now: u64) -> (u64, Vec<String>) {
        let mut all = files(dir);
        let mut size: u64 = all.iter().map(|f| f.size).sum();
        all.sort_by_key(|f| f.mtime);
        let today = now - now % DAY;
        let mut errs = Vec::new();
        for f in &all {
            if size <= budget {
                break;
            }
            if f.mtime >= today {
                continue;
            }
            match std::fs::remove_file(&f.path) {
                Ok(()) => size = size.saturating_sub(f.size),
                Err(e) => errs.push(format!("{}: {e}", f.path.display())),
            }
        }
        (size, errs)
    }

    // What: xz every file closed before today.
    // Why: past days are never written again.
    // From: Issue #1683 | PR #1858
    pub fn pack_closed(dir: &Path, preset: u64, now: u64) -> Vec<String> {
        let today = now - now % DAY;
        let mut errs = Vec::new();
        for f in files(dir) {
            if f.mtime >= today || f.path.extension().is_some_and(|e| e == "xz") {
                continue;
            }
            let run = Command::new("xz")
                .arg(format!("-{preset}"))
                .arg("--")
                .arg(&f.path)
                .output();
            match run {
                Ok(o) if o.status.success() => {}
                Ok(o) => errs.push(String::from_utf8_lossy(&o.stderr).trim().to_string()),
                Err(e) => errs.push(format!("xz: {e}")),
            }
        }
        errs
    }

    // What: is a daily job due by its stamp.
    // Why: a missing or future stamp means due.
    // From: Issue #1683 | PR #1858
    pub fn is_due(stamp: &Path, now: u64) -> bool {
        let last = std::fs::read_to_string(stamp)
            .ok()
            .and_then(|t| t.trim().parse::<u64>().ok())
            .filter(|t| *t <= now)
            .unwrap_or(0);
        now - last >= DAY
    }

    // What: write a stamp time.
    // Why: next run waits a day from it.
    // From: Issue #1683 | PR #1858
    pub fn save_stamp(stamp: &Path, at: u64) -> Result<(), String> {
        let made = stamp.parent().map_or(Ok(()), std::fs::create_dir_all);
        let wrote = made.and_then(|()| std::fs::write(stamp, at.to_string() + "\n"));
        wrote.map_err(|e| format!("{}: {e}", stamp.display()))
    }

    // What: newest change time below a folder.
    // Why: shows whether logs are still written.
    // From: Issue #1683 | PR #1858
    pub fn newest(dir: &Path) -> u64 {
        files(dir).iter().map(|f| f.mtime).max().unwrap_or(0)
    }

    // What: processed count of syslog-ng file outputs.
    // Why: syslog-ng-ctl stats lists dst.file rows.
    // From: Issue #1683 | PR #1858
    pub fn syslog_processed() -> Result<u64, String> {
        let out = Command::new("syslog-ng-ctl").arg("stats").output();
        let out = out.map_err(|e| format!("syslog-ng-ctl: {e}"))?;
        let text = String::from_utf8_lossy(&out.stdout);
        let mut total = 0;
        for row in text.lines().filter(|l| l.starts_with("dst.file;")) {
            let cols: Vec<&str> = row.split(';').collect();
            if cols.get(4) == Some(&"processed") {
                total += cols.get(5).and_then(|v| v.parse::<u64>().ok()).unwrap_or(0);
            }
        }
        Ok(total)
    }
}
