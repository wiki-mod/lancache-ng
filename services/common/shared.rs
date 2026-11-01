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

        // What: all RRsets of one zone.
        // Why: the ui lists records straight from PowerDNS.
        // From: Issue #1683 | PR #1858
        pub async fn rrsets(&self, zone: &str) -> Result<Vec<Value>, String> {
            let path = format!("/zones/{}", zone_id(zone));
            let text = self.call(reqwest::Method::GET, &path, None).await?;
            let v: Value = serde_json::from_str(&text).map_err(|e| format!("zone {zone}: {e}"))?;
            Ok(v["rrsets"].as_array().cloned().unwrap_or_default())
        }

        // What: set a zone back to saved RRsets.
        // Why: rollback; SOA stays, serial rises via soa-edit-api.
        // From: Issue #1683 | PR #1858
        pub async fn restore(&self, zone: &str, saved: &[Value]) -> Result<(), String> {
            let key = |r: &Value| (r["name"].to_string(), r["type"].to_string());
            let keep: std::collections::BTreeSet<_> = saved.iter().map(key).collect();
            let mut rrsets: Vec<Value> = Vec::new();
            for r in self.rrsets(zone).await? {
                if r["type"] != "SOA" && !keep.contains(&key(&r)) {
                    rrsets.push(
                        json!({"name": r["name"], "type": r["type"], "changetype": "DELETE"}),
                    );
                }
            }
            for r in saved.iter().filter(|r| r["type"] != "SOA") {
                rrsets.push(
                    json!({"name": r["name"], "type": r["type"], "ttl": r["ttl"],
                                   "changetype": "REPLACE", "records": r["records"]}),
                );
            }
            let path = format!("/zones/{}", zone_id(zone));
            self.call(
                reqwest::Method::PATCH,
                &path,
                Some(json!({"rrsets": rrsets})),
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
        Reload,
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
                Action::Reload => "kill?signal=HUP".to_string(),
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

// What: pdns.conf of the authoritative server.
// Why: one owner; values from the SOT, key from secret.
// From: Issue #1683 | PR #1858
pub mod pdns_conf {
    use crate::config::Settings;

    // What: values must not open a new config line.
    // Why: a setting must never add a pdns directive.
    // From: Issue #1683 | PR #1858
    fn line_safe(key: &str, v: &str) -> Result<(), String> {
        if v.contains(['\n', '\r']) {
            return Err(format!("{key} contains a line break"));
        }
        Ok(())
    }

    // What: render pdns.conf for this node's role.
    // Why: primary sends NOTIFY; secondary pulls by AXFR.
    // From: Issue #1683 | PR #1858
    pub fn auth(s: &Settings, api_key: &str) -> Result<String, String> {
        let role = s.text("DNS_REPLICATION_ROLE")?;
        let primary = match role.as_str() {
            "primary" => true,
            "secondary" => false,
            other => return Err(format!("DNS_REPLICATION_ROLE={other} is unknown")),
        };
        let yes = |on: bool| if on { "yes" } else { "no" };
        let notify_from = if primary {
            String::new()
        } else {
            s.text("DNS_XFR_PRIMARY")?
        };
        let pairs = [
            ("local-address", s.list("PDNS_LISTEN").join(",")),
            ("local-port", s.uint("PDNS_AUTH_PORT")?.to_string()),
            ("launch", "gsqlite3".to_string()),
            ("gsqlite3-database", s.text("PDNS_DATABASE")?),
            ("primary", yes(primary).to_string()),
            ("secondary", yes(!primary).to_string()),
            (
                "also-notify",
                if primary {
                    s.list("DNS_NOTIFY_TARGETS").join(",")
                } else {
                    String::new()
                },
            ),
            ("allow-notify-from", notify_from),
            ("allow-axfr-ips", s.list("PDNS_AXFR_FROM").join(",")),
            ("xfr-cycle-interval", s.uint("PDNS_XFR_CYCLE")?.to_string()),
            ("dnsupdate", yes(primary).to_string()),
            (
                "allow-dnsupdate-from",
                s.list("PDNS_DNSUPDATE_FROM").join(","),
            ),
            ("default-soa-content", s.text("PDNS_DEFAULT_SOA")?),
            ("webserver", "yes".to_string()),
            ("webserver-address", s.text("PDNS_API_LISTEN")?),
            ("webserver-port", s.uint("PDNS_AUTH_API_PORT")?.to_string()),
            (
                "webserver-allow-from",
                s.list("PDNS_API_ALLOW_FROM").join(","),
            ),
            ("api", "yes".to_string()),
            ("api-key", api_key.to_string()),
            ("loglevel", s.uint("PDNS_AUTH_LOGLEVEL")?.to_string()),
            ("guardian", "no".to_string()),
            ("daemon", "no".to_string()),
        ];
        let mut out = String::new();
        for (k, v) in pairs {
            line_safe(k, &v)?;
            if !v.is_empty() {
                out.push_str(&format!("{k}={v}\n"));
            }
        }
        Ok(out)
    }
}

// What: recursor.yml, lua and RPZ for http and https.
// Why: both recursors differ only in keys; one owner.
// From: Issue #1683 | PR #1858
pub mod recursor_conf {
    use crate::config::Settings;

    // What: which recursor: HTTP or HTTPS.
    // Why: names the key suffix, e.g. RECURSOR_HTTP_PORT.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub enum Which {
        Http,
        Https,
    }

    impl Which {
        // What: key part of this recursor.
        // Why: one schema row per recursor and setting.
        // From: Issue #1683 | PR #1858
        pub fn key(self, name: &str) -> String {
            let part = match self {
                Self::Http => "HTTP",
                Self::Https => "HTTPS",
            };
            format!("RECURSOR_{part}_{name}")
        }
    }

    // What: YAML list rows, quoted.
    // Why: quoting keeps a value from breaking the YAML.
    // From: Issue #1683 | PR #1858
    fn rows(items: &[String], indent: &str) -> Result<String, String> {
        let mut out = String::new();
        for i in items {
            if i.contains(['"', '\\', '\n', '\r']) {
                return Err(format!("value {i:?} has quote or line break"));
            }
            out.push_str(&format!("{indent}- \"{i}\"\n"));
        }
        Ok(out)
    }

    // What: RPZ zone that answers cache domains locally.
    // Why: native recursor policy; no own DNS answers.
    // From: Issue #1683 | PR #1858
    pub fn rpz(domains: &[String], answer: &str, serial: u32) -> Result<String, String> {
        if answer.parse::<std::net::IpAddr>().is_err() {
            return Err(format!("RPZ answer {answer:?} is no IP address"));
        }
        let kind = if answer.contains(':') { "AAAA" } else { "A" };
        let mut out = format!(
            "$TTL 60\n@ SOA localhost. hostmaster.localhost. {serial} 3600 600 86400 60\n@ NS localhost.\n"
        );
        for d in domains {
            let d = d.trim_end_matches('.');
            if !crate::dns::is_dns_name(d) {
                return Err(format!("cache domain {d:?} is no DNS name"));
            }
            out.push_str(&format!("{d} {kind} {answer}\n*.{d} {kind} {answer}\n"));
        }
        Ok(out)
    }

    // What: lua config: load the RPZ file.
    // Why: rpzFile is the native recursor RPZ loader.
    // From: Issue #1683 | PR #1858
    pub fn lua(rpz_file: &str) -> Result<String, String> {
        if rpz_file.contains(['"', '\\', '\n']) {
            return Err(format!("RPZ path {rpz_file:?} is not plain"));
        }
        Ok(format!(
            "rpzFile(\"{rpz_file}\", {{ policyName=\"lancache-rpz\" }})\n"
        ))
    }

    // What: lua dns script answering AAAA with no data.
    // Why: clients then use IPv4 and reach the cache.
    // From: Issue #1683 | PR #1858
    pub const AAAA_FILTER_LUA: &str = "function preresolve(dq)\n  if dq.qtype == pdns.AAAA then\n    dq.rcode = pdns.NOERROR\n    return true\n  end\n  return false\nend\n";

    // What: recursor.yml for one recursor.
    // Why: local zones go to the auth server, rest upstream.
    // From: Issue #1683 | PR #1858
    pub fn yaml(
        s: &Settings,
        which: Which,
        api_key: &str,
        lua_file: &str,
    ) -> Result<String, String> {
        let auth = format!(
            "{}:{}",
            s.text("PDNS_AUTH_ADDRESS")?,
            s.uint("PDNS_AUTH_PORT")?
        );
        let mut fwd = String::new();
        for z in crate::dns::managed_zones(&s.text("DNS_LAN_ZONE")?, s.flag("DNS_SERVE_RFC1918")?) {
            fwd.push_str(&format!(
                "    - zone: \"{}\"\n      forwarders: [\"{auth}\"]\n",
                z.trim_end_matches('.')
            ));
        }
        let upstream = s.list("DNS_UPSTREAM_SERVERS");
        let mut recurse = String::new();
        if !upstream.is_empty() {
            let list = upstream
                .iter()
                .map(|u| format!("\"{u}\""))
                .collect::<Vec<_>>()
                .join(", ");
            recurse = format!(
                "  forward_zones_recurse:\n    - zone: \".\"\n      forwarders: [{list}]\n"
            );
        }
        let snmp = if s.flag("SNMP_AGENTX")? {
            format!(
                "snmp:\n  agent: true\n  daemon_socket: \"{}\"\n",
                s.text("SNMP_AGENTX_SOCKET")?
            )
        } else {
            String::new()
        };
        let u = |k: &str| s.uint(k).map(|v| v.to_string());
        Ok(format!(
            "incoming:\n  listen:\n{listen}  port: {port}\n  allow_from:\n{allow}\
             recursor:\n  serve_rfc1918: {rfc}\n  forward_zones:\n{fwd}{recurse}\
             \x20 lua_config_file: \"{lua_file}\"\n{dns_script}  minimum_ttl_override: {minttl}\n\
             recordcache:\n  max_entries: {rcmax}\n  refresh_on_ttl_perc: {perc}\n\
             \x20 serve_stale_extensions: {stale}\n  max_negative_ttl: {negttl}\n\
             packetcache:\n  max_entries: {pcmax}\n  ttl: {pcttl}\n  negative_ttl: {negttl}\n\
             \x20 servfail_ttl: {sfttl}\n\
             webservice:\n  webserver: true\n  address: \"{apiaddr}\"\n  port: {apiport}\n\
             \x20 allow_from:\n{apiallow}  api_key: \"{api_key}\"\n\
             logging:\n  loglevel: {loglevel}\n{snmp}",
            dns_script = if s.flag("DNS_FILTER_AAAA")? {
                format!(
                    "  lua_dns_script: \"{}\"\n",
                    s.text("RECURSOR_AAAA_LUA_FILE")?
                )
            } else {
                String::new()
            },
            listen = rows(&s.list(&which.key("LISTEN")), "    ")?,
            port = u(&which.key("PORT"))?,
            allow = rows(&s.list("DNS_QUERY_ALLOW_FROM"), "    ")?,
            rfc = s.flag("DNS_SERVE_RFC1918")?,
            minttl = u("RECURSOR_MINIMUM_TTL_OVERRIDE")?,
            rcmax = u("RECURSOR_RECORDCACHE_MAX")?,
            perc = u("RECURSOR_REFRESH_ON_TTL_PERC")?,
            stale = u("RECURSOR_SERVE_STALE_EXTENSIONS")?,
            negttl = u("RECURSOR_NEGATIVE_TTL")?,
            pcmax = u("RECURSOR_PACKETCACHE_MAX")?,
            pcttl = u("RECURSOR_PACKETCACHE_TTL")?,
            sfttl = u("RECURSOR_SERVFAIL_TTL")?,
            apiaddr = s.text("PDNS_API_LISTEN")?,
            apiport = u(&which.key("API_PORT"))?,
            apiallow = rows(&s.list("PDNS_API_ALLOW_FROM"), "    ")?,
            loglevel = u("RECURSOR_LOGLEVEL")?,
        ))
    }
}

// What: Kea configs: dhcp4, ctrl-agent, dhcp-ddns.
// Why: one owner; Kea reads them; values from the SOT.
// From: Issue #1683 | PR #1858
pub mod kea_conf {
    use crate::config::Settings;
    use crate::dhcp;
    use serde_json::{json, Value};

    // What: Kea logger rows to stdout.
    // Why: Docker syslog driver carries stdout to syslog-ng.
    // From: Issue #1683 | PR #1858
    fn loggers(s: &Settings, names: &[&str]) -> Result<Value, String> {
        let severity = s.text("KEA_LOG_SEVERITY")?;
        let debug = s.uint("KEA_LOG_DEBUGLEVEL")?;
        Ok(names
            .iter()
            .map(|n| {
                json!({"name": n, "output-options": [{"output": "stdout"}],
                       "severity": severity, "debuglevel": debug})
            })
            .collect())
    }

    // What: kea-dhcp4.conf.
    // Why: managed options first, user options after.
    // From: Issue #1683 | PR #1858
    pub fn dhcp4(s: &Settings) -> Result<Value, String> {
        let lease = s.uint("DHCP_LEASE_TIME")?;
        let (valid, max) = dhcp::lease_limits(s, lease)?;
        let domain = crate::dns::canonical_zone(&s.text("DNS_LAN_ZONE")?);
        let domain = domain.trim_end_matches('.').to_string();
        let mut options = vec![
            json!({"name": "routers", "data": s.text("DHCP_GATEWAY")?}),
            json!({"name": "domain-name-servers", "data": s.list("DHCP_DNS_SERVERS").join(", ")}),
            json!({"name": "domain-name", "data": domain}),
            json!({"name": "domain-search", "data": domain}),
        ];
        let ntp = s.list("DHCP_NTP_SERVERS");
        if !ntp.is_empty() {
            options.push(json!({"name": "ntp-servers", "data": ntp.join(", ")}));
        }
        for (code, data) in
            dhcp::custom_options(s, &s.text("DHCP_CUSTOM_OPTIONS").unwrap_or_default())?
        {
            options.push(json!({"code": code, "data": data}));
        }
        let ddns = s.flag("DHCP_DDNS")?;
        Ok(json!({"Dhcp4": {
            "interfaces-config": {"interfaces": s.list("DHCP_INTERFACES"), "re-detect": false},
            "lease-database": {"type": "memfile", "persist": true, "name": s.text("KEA_LEASE_FILE")?},
            "control-socket": {"socket-type": "unix", "socket-name": s.text("KEA_DHCP4_SOCKET")?},
            "hooks-libraries": [{"library": s.text("KEA_LEASE_CMDS_HOOK")?}],
            "subnet4": [{
                "id": 1,
                "subnet": s.text("DHCP_SUBNET")?,
                "pools": [{"pool": format!("{} - {}", s.text("DHCP_RANGE_START")?, s.text("DHCP_RANGE_END")?)}],
                "option-data": options,
                "valid-lifetime": valid,
                "max-valid-lifetime": max
            }],
            "dhcp-ddns": {
                "enable-updates": ddns,
                "server-ip": s.text("KEA_DDNS_ADDRESS")?,
                "server-port": s.uint("KEA_DDNS_PORT")?,
                "max-queue-size": s.uint("KEA_NCR_MAX_QUEUE")?,
                "ncr-protocol": "UDP",
                "ncr-format": "JSON"
            },
            "ddns-send-updates": ddns,
            "ddns-override-no-update": true,
            "ddns-override-client-update": true,
            "ddns-replace-client-name": s.text("KEA_DDNS_REPLACE_CLIENT_NAME")?,
            "ddns-generated-prefix": s.text("KEA_DDNS_GENERATED_PREFIX")?,
            "ddns-qualifying-suffix": format!("{domain}."),
            "loggers": loggers(s, &["kea-dhcp4", "kea-dhcp4.packets"])?
        }}))
    }

    // What: kea-ctrl-agent.conf.
    // Why: the ui reads leases through its REST port.
    // From: Issue #1683 | PR #1858
    pub fn ctrl_agent(s: &Settings) -> Result<Value, String> {
        Ok(json!({"Control-agent": {
            "http-host": s.text("KEA_CTRL_ADDRESS")?,
            "http-port": s.uint("KEA_CTRL_PORT")?,
            "control-sockets": {"dhcp4": {"socket-type": "unix", "socket-name": s.text("KEA_DHCP4_SOCKET")?}},
            "loggers": loggers(s, &["kea-ctrl-agent"])?
        }}))
    }

    // What: kea-dhcp-ddns.conf: forward and reverse.
    // Why: DDNS goes to the local pdns with TSIG.
    // From: Issue #1683 | PR #1858
    pub fn ddns(s: &Settings, tsig_name: &str, tsig_secret: &str) -> Result<Value, String> {
        let server = json!([{"ip-address": s.text("PDNS_AUTH_ADDRESS")?, "port": s.uint("PDNS_AUTH_PORT")?}]);
        let zone = crate::dns::canonical_zone(&s.text("DNS_LAN_ZONE")?);
        let fwd = json!([{"name": zone, "key-name": tsig_name, "dns-servers": server}]);
        let rev: Vec<Value> = crate::dns::private_reverse_zones()
            .iter()
            .map(|z| json!({"name": z, "key-name": tsig_name, "dns-servers": server}))
            .collect();
        Ok(json!({"DhcpDdns": {
            "ip-address": s.text("KEA_DDNS_ADDRESS")?,
            "port": s.uint("KEA_DDNS_PORT")?,
            "tsig-keys": [{"name": tsig_name, "algorithm": "HMAC-SHA256", "secret": tsig_secret}],
            "forward-ddns": {"ddns-domains": fwd},
            "reverse-ddns": {"ddns-domains": rev},
            "loggers": loggers(s, &["kea-dhcp-ddns"])?
        }}))
    }
}

// What: dnsmasq.conf for proxy-DHCP or relay mode.
// Why: one owner; errors stop the render, never skip.
// From: Issue #1683 | PR #1858
pub mod dnsmasq_conf {
    use crate::config::Settings;
    use crate::dhcp::{self, Mode};

    // What: append one line; refuse line breaks.
    // Why: a value must never add a dnsmasq directive.
    // From: Issue #1683 | PR #1858
    fn line(out: &mut String, l: String) -> Result<(), String> {
        if l.contains(['\n', '\r']) {
            return Err(format!("dnsmasq line {l:?} holds a line break"));
        }
        out.push_str(&l);
        out.push('\n');
        Ok(())
    }

    // What: render dnsmasq.conf for the mode.
    // Why: Off and Kea run no dnsmasq; caller asks first.
    // From: Issue #1683 | PR #1858
    pub fn conf(s: &Settings, mode: Mode) -> Result<String, String> {
        let mut out = String::from("port=0\nno-resolv\nno-poll\nlog-facility=-\n");
        if s.flag("DHCP_LOG_PACKETS")? {
            out.push_str("log-dhcp\n");
        }
        match mode {
            Mode::DnsmasqRelay => {
                let l = format!(
                    "dhcp-relay={},{}",
                    s.text("DHCP_RELAY_LOCAL_ADDR")?,
                    s.text("UPSTREAM_DHCP_IP")?
                );
                line(&mut out, l)?;
                return Ok(out);
            }
            Mode::DnsmasqProxy => {}
            Mode::Off | Mode::Kea => return Err(format!("dnsmasq does not run in mode {mode:?}")),
        }
        line(
            &mut out,
            format!("dhcp-range={},proxy", s.text("DHCP_SUBNET_START")?),
        )?;
        line(
            &mut out,
            format!("dhcp-option-pxe=6,{}", s.list("DHCP_DNS_SERVERS").join(",")),
        )?;
        let opt = |k: &str| s.text(k).unwrap_or_default();
        for (key, prefix) in [
            ("DHCP_PROXY_INTERFACE", "interface="),
            ("DHCP_PROXY_ROUTER", "dhcp-option-pxe=3,"),
            ("DHCP_PROXY_DOMAIN", "dhcp-option-pxe=15,"),
        ] {
            let v = opt(key);
            if !v.is_empty() {
                line(&mut out, format!("{prefix}{v}"))?;
            }
        }
        let ntp = s.list("DHCP_NTP_SERVERS");
        if !ntp.is_empty() {
            line(&mut out, format!("dhcp-option-pxe=42,{}", ntp.join(",")))?;
        }
        let (file, server) = (
            opt("DHCP_PROXY_BOOT_FILENAME"),
            opt("DHCP_PROXY_BOOT_SERVER"),
        );
        if !file.is_empty() {
            line(&mut out, format!("dhcp-boot={file},,{server}"))?;
        }
        for (code, data) in dhcp::custom_options(s, &opt("DHCP_CUSTOM_OPTIONS"))? {
            line(&mut out, format!("dhcp-option-pxe={code},{data}"))?;
        }
        let pxe = opt("DHCP_PROXY_PXE_BOOT_SERVER");
        let bios = opt("DHCP_PROXY_PXE_BOOT_FILENAME_BIOS");
        let uefi = opt("DHCP_PROXY_PXE_BOOT_FILENAME_UEFI");
        if pxe.is_empty() || (bios.is_empty() && uefi.is_empty()) {
            return Ok(out);
        }
        if !bios.is_empty() {
            line(
                &mut out,
                format!("pxe-service=x86PC,\"lancache-ng PXE boot (BIOS)\",{bios},{pxe}"),
            )?;
            line(
                &mut out,
                "dhcp-match=set:lancache-pxe-bios,option:client-arch,0".into(),
            )?;
            line(
                &mut out,
                format!("dhcp-boot=tag:lancache-pxe-bios,{bios},,{pxe}"),
            )?;
        }
        if !uefi.is_empty() {
            line(
                &mut out,
                "dhcp-match=set:lancache-pxe-uefi,option:client-arch,7".into(),
            )?;
            line(
                &mut out,
                "dhcp-match=set:lancache-pxe-uefi,option:client-arch,11".into(),
            )?;
            line(
                &mut out,
                format!("dhcp-boot=tag:lancache-pxe-uefi,{uefi},,{pxe}"),
            )?;
        }
        if bios.is_empty() {
            line(
                &mut out,
                "pxe-service=IA64_EFI,\"lancache-ng PXE proxy active\",0".into(),
            )?;
        }
        Ok(out)
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

    // What: discard port answering refused names.
    // Why: RFC 863 discard; nothing listens, TLS fails fast.
    // From: Issue #1683 | PR #1858
    const DISCARD_PORT: u16 = 9;

    // What: Public Suffix List rules.
    // Why: finds the registrable root of a CDN name.
    // From: Issue #1683 | PR #1858
    pub struct Psl {
        rules: BTreeSet<String>,
        wild: BTreeSet<String>,
        except: BTreeSet<String>,
    }

    impl Psl {
        // What: parse the PSL text format.
        // Why: publicsuffix.org format: rule, *.rule, !rule.
        // From: Issue #1683 | PR #1858
        pub fn parse(text: &str) -> Self {
            let mut p = Self {
                rules: BTreeSet::new(),
                wild: BTreeSet::new(),
                except: BTreeSet::new(),
            };
            for l in text.lines().map(str::trim) {
                let Some(rule) = l.split_whitespace().next() else {
                    continue;
                };
                if rule.starts_with("//") {
                    continue;
                }
                let rule = rule.to_ascii_lowercase();
                if let Some(r) = rule.strip_prefix('!') {
                    p.except.insert(r.to_string());
                } else if let Some(r) = rule.strip_prefix("*.") {
                    p.wild.insert(r.to_string());
                } else {
                    p.rules.insert(rule);
                }
            }
            p
        }

        // What: registrable root (suffix plus one label).
        // Why: PSL algorithm; unlisted TLD counts as suffix.
        // From: Issue #1683 | PR #1858
        pub fn root(&self, name: &str) -> Option<String> {
            let labels: Vec<&str> = name.split('.').collect();
            let mut suffix_len = 1;
            for i in 0..labels.len() {
                let cand = labels[i..].join(".");
                if self.except.contains(&cand) {
                    suffix_len = labels.len() - i - 1;
                    break;
                }
                let parent = labels[i + 1..].join(".");
                if self.rules.contains(&cand)
                    || (i + 1 < labels.len() && self.wild.contains(&parent))
                {
                    suffix_len = suffix_len.max(labels.len() - i);
                }
            }
            (labels.len() > suffix_len).then(|| labels[labels.len() - suffix_len - 1..].join("."))
        }
    }

    // What: CDN names sorted by how nginx must treat them.
    // Why: roots get one cert; bases and exact names own.
    // From: Issue #1683 | PR #1858
    #[derive(Default)]
    pub struct Hosts {
        pub roots: Vec<String>,
        pub bases: Vec<String>,
        pub exact: Vec<String>,
        pub root_wild: BTreeSet<String>,
    }

    // What: sort the cache domain list into Hosts.
    // Why: invalid or rootless rows are errors, not skips.
    // From: Issue #1683 | PR #1858
    pub fn hosts(domains: &str, psl: &Psl) -> Result<Hosts, String> {
        let mut h = Hosts::default();
        let push = |l: &mut Vec<String>, n: &str| {
            if !l.iter().any(|k| k == n) {
                l.push(n.to_string());
            }
        };
        for row in domains
            .lines()
            .map(str::trim)
            .filter(|r| !r.is_empty() && !r.starts_with('#'))
        {
            let (name, wild) = crate::dns::cdn_entry(row)
                .ok_or_else(|| format!("invalid domain entry {row:?}"))?;
            let root = psl
                .root(&name)
                .ok_or_else(|| format!("no registrable root for {name}"))?;
            push(&mut h.roots, &root);
            if wild && name == root {
                h.root_wild.insert(root);
            } else if wild {
                push(&mut h.bases, &name);
            } else if name != root && name.split_once('.').map(|(_, r)| r) != Some(root.as_str()) {
                push(&mut h.exact, &name);
            }
        }
        Ok(h)
    }

    // What: stable cert file name of one host.
    // Why: file names never carry raw host text.
    // From: Issue #1683 | PR #1858
    fn cert_name(host: &str, kind: &str) -> String {
        let d = Sha256::digest(format!("{kind}:{host}").as_bytes());
        d.iter().take(16).map(|b| format!("{b:02x}")).collect()
    }

    impl Hosts {
        // What: (server name key, cert name) pairs.
        // Why: drives the cert map and the strict allow map.
        // From: Issue #1683 | PR #1858
        pub fn keys(&self) -> Vec<(String, String)> {
            let mut k = Vec::new();
            for r in &self.roots {
                k.push((format!("*.{r}"), r.clone()));
                k.push((r.clone(), r.clone()));
            }
            for b in &self.bases {
                k.push((format!("*.{b}"), cert_name(b, "wildcard")));
            }
            for e in &self.exact {
                k.push((e.clone(), cert_name(e, "exact")));
            }
            k
        }

        // What: certs to issue: name and SANs.
        // Why: cert::make_leaf issues exactly these.
        // From: Issue #1683 | PR #1858
        pub fn certs(&self) -> Vec<(String, Vec<String>)> {
            let mut c: Vec<(String, Vec<String>)> = self
                .roots
                .iter()
                .map(|r| (r.clone(), vec![r.clone(), format!("*.{r}")]))
                .collect();
            c.extend(
                self.bases
                    .iter()
                    .map(|b| (cert_name(b, "wildcard"), vec![format!("*.{b}")])),
            );
            c.extend(
                self.exact
                    .iter()
                    .map(|e| (cert_name(e, "exact"), vec![e.clone()])),
            );
            c
        }
    }

    // What: one map row, aligned.
    // Why: readable generated files.
    // From: Issue #1683 | PR #1858
    fn row(key: &str, value: &str) -> String {
        format!("    {key:<45} {value};\n")
    }

    // What: fill ${KEY} in a shipped nginx template.
    // Why: settings live in the ui, not in the env.
    // From: Issue #1683 | PR #1858
    pub fn template(text: &str, s: &Settings) -> Result<String, String> {
        let mut out = String::with_capacity(text.len());
        let mut rest = text;
        while let Some(i) = rest.find("${") {
            out.push_str(&rest[..i]);
            let tail = &rest[i + 2..];
            let end = tail.find('}').ok_or("unclosed ${ in nginx template")?;
            let key = &tail[..end];
            let v = s.text(key).map_err(|e| format!("nginx template: {e}"))?;
            if v.contains(['\n', '\r', ';', '{', '}']) {
                return Err(format!("{key} holds a character nginx treats as syntax"));
            }
            out.push_str(&v);
            rest = &tail[end + 1..];
        }
        out.push_str(rest);
        Ok(out)
    }

    // What: all generated files: (relative path, body).
    // Why: the ui writes them; nginx includes the paths.
    // From: Issue #1683 | PR #1858
    pub fn files(s: &Settings, h: &Hosts, https: bool) -> Result<Vec<(String, String)>, String> {
        let strict = match s.text("PROXY_SECURITY_MODE")?.as_str() {
            "strict" => true,
            "lazy" => false,
            o => {
                return Err(format!(
                    "PROXY_SECURITY_MODE={o} is neither lazy nor strict"
                ))
            }
        };
        let cidrs = s.list("PROXY_ALLOWED_CLIENT_CIDRS");
        let lo = s.text("LOOPBACK_BIND_IP")?;
        let p = |k: &str| s.uint(k);
        let (mitm, mitm_relay, pass_relay) = (
            p("NGINX_MITM_PORT")?,
            p("NGINX_MITM_RELAY_PORT")?,
            p("NGINX_PASSTHROUGH_RELAY_PORT")?,
        );
        let (passthrough, https_port, origin_port, health) = (
            p("NGINX_PASSTHROUGH_PORT")?,
            p("PROXY_HTTPS_PORT")?,
            p("NGINX_ORIGIN_HTTPS_PORT")?,
            p("NGINX_HEALTH_TLS_PORT")?,
        );
        let timeouts = format!(
            "    proxy_connect_timeout {}s;\n    proxy_timeout        {}s;\n",
            p("NGINX_UPSTREAM_CONNECT_TIMEOUT")?,
            p("NGINX_UPSTREAM_IDLE_TIMEOUT")?
        );
        let refuse = format!("{lo}:{DISCARD_PORT}");
        let origin = format!("$ssl_preread_server_name:{origin_port}");
        let acl_path = s.text("NGINX_CLIENT_ACL_FILE")?;
        let keys = h.keys();
        let mut out = Vec::new();

        let mut acl = HEAD.to_string();
        if !cidrs.is_empty() {
            for c in &cidrs {
                acl.push_str(&format!("allow {c};\n"));
            }
            acl.push_str("deny all;\n");
        }
        out.push((acl_path.clone(), acl));

        let mut st = format!(
            "{HEAD}map $ssl_preread_server_name $stream_backend {{\n    hostnames;\n{}",
            row("\"\"", &refuse)
        );
        if strict {
            st.push_str(&format!("    default {refuse};\n"));
            for (k, _) in &keys {
                st.push_str(&row(k, &origin));
            }
        } else {
            st.push_str(&format!("    default {origin};\n"));
        }
        st.push_str(&format!(
            "}}\n\nserver {{\n    listen {passthrough};\n    listen [::]:{passthrough};\n    include {acl_path};\n    ssl_preread on;\n    proxy_pass $stream_backend;\n{timeouts}}}\n"
        ));
        out.push(("stream.d/00-stream-targets.conf".into(), st));

        if !https {
            return Ok(out);
        }
        let default_cert = s.text("NGINX_DEFAULT_CERT")?;
        let mut map = format!("{HEAD}map $ssl_server_name $https_cert_name {{\n    hostnames;\n");
        for (k, c) in &keys {
            map.push_str(&row(k, c));
        }
        map.push_str(&format!(
            "    default {default_cert};\n}}\n\nmap $host $cdn_host_allowed {{\n    hostnames;\n"
        ));
        if strict {
            map.push_str("    default 0;\n");
            for (k, _) in &keys {
                map.push_str(&row(k, "1"));
            }
        } else {
            map.push_str("    default 1;\n");
        }
        map.push_str("}\n\ngeo $lancache_client_allowed {\n");
        map.push_str(if cidrs.is_empty() {
            "    default 1;\n"
        } else {
            "    default 0;\n"
        });
        for c in &cidrs {
            map.push_str(&row(c, "1"));
        }
        map.push_str("}\n");
        out.push(("conf.d/00-https-map.conf".into(), map));

        out.push((
            s.text("NGINX_HTTPS_LISTEN_FILE")?,
            format!("{HEAD}listen {lo}:{mitm} ssl proxy_protocol default_server;\nlisten {lo}:{health} ssl;\n"),
        ));

        let to_mitm = format!("{lo}:{mitm_relay}");
        let to_pass = format!("{lo}:{pass_relay}");
        let esc = |n: &str| n.replace('.', "\\.");
        let one = |n: &str| format!("\"~^[^.]+\\.{}$\"", esc(n));
        let mut bases: Vec<&String> = h
            .bases
            .iter()
            .chain(h.roots.iter().filter(|r| h.root_wild.contains(*r)))
            .collect();
        bases.sort_by(|a, b| b.len().cmp(&a.len()).then(b.cmp(a)));
        let mut d = format!(
            "{HEAD}map $ssl_preread_server_name $https_dispatch_backend {{\n{}",
            row("\"\"", &refuse)
        );
        for r in &h.roots {
            d.push_str(&row(r, &to_mitm));
            if !h.root_wild.contains(r) {
                d.push_str(&row(&one(r), &to_mitm));
            }
        }
        for e in &h.exact {
            d.push_str(&row(e, &to_mitm));
        }
        for b in bases {
            d.push_str(&row(&one(b), &to_mitm));
            d.push_str(&row(&format!("\"~^.+\\.{}$\"", esc(b)), &to_pass));
        }
        let default = if strict { &refuse } else { &to_pass };
        d.push_str(&format!(
            "    default {default};\n}}\n\n\
             server {{\n    listen {https_port};\n    listen [::]:{https_port};\n    include {acl_path};\n    \
             ssl_preread on;\n    proxy_pass $https_dispatch_backend;\n    proxy_protocol on;\n{timeouts}}}\n\n\
             server {{\n    listen {to_mitm} proxy_protocol;\n    set_real_ip_from {lo};\n    \
             proxy_protocol on;\n    proxy_pass {lo}:{mitm};\n{timeouts}}}\n\n\
             server {{\n    listen {to_pass} proxy_protocol;\n    set_real_ip_from {lo};\n    \
             ssl_preread on;\n    proxy_pass {origin};\n{timeouts}}}\n"
        ));
        out.push(("stream.d/01-https-dispatch.conf".into(), d));
        Ok(out)
    }
}

// What: apply saved setting changes to the containers.
// Why: each owner gets only the strongest needed action.
// From: Issue #1683 | PR #1858
pub mod apply {
    use crate::config::{Change, Effect};
    use crate::docker::{Action, Api, Error};
    use std::collections::BTreeMap;
    use std::time::Duration;

    // What: strongest effect per owning container.
    // Why: one restart covers a reload of the same owner.
    // From: Issue #1683 | PR #1858
    pub fn plan(changes: &[Change]) -> BTreeMap<String, Effect> {
        let mut out: BTreeMap<String, Effect> = BTreeMap::new();
        for c in changes {
            let e = out.entry(c.owner.clone()).or_insert(c.effect);
            *e = (*e).max(c.effect);
        }
        out
    }

    // What: result of one owner's action.
    // Why: Recreate needs compose; the ui shows it.
    // From: Issue #1683 | PR #1858
    #[derive(Debug)]
    pub enum Outcome {
        Live,
        Done(Action),
        NeedsRecreate,
        Failed(Error),
    }

    // What: run the plan: HUP, restart or report.
    // Why: Live needs nothing; programs reread on their own.
    // From: Issue #1683 | PR #1858
    pub async fn run(
        api: &Api,
        plan: &BTreeMap<String, Effect>,
        container_of: &dyn Fn(&str) -> String,
        grace: u32,
        limit: Duration,
    ) -> Vec<(String, Outcome)> {
        let mut out = Vec::new();
        for (owner, effect) in plan {
            let action = match effect {
                Effect::Live => {
                    out.push((owner.clone(), Outcome::Live));
                    continue;
                }
                Effect::Recreate => {
                    out.push((owner.clone(), Outcome::NeedsRecreate));
                    continue;
                }
                Effect::Reload => Action::Reload,
                Effect::Restart | Effect::Container => Action::Restart,
            };
            let res = api.act(&container_of(owner), action, grace, limit).await;
            out.push((
                owner.clone(),
                res.map_or_else(Outcome::Failed, |()| Outcome::Done(action)),
            ));
        }
        out
    }
}

// What: every config file of the stack from settings.
// Why: the ui calls one function; paths from the SOT.
// From: Issue #1683 | PR #1858
pub mod render {
    use crate::config::Settings;
    use crate::recursor_conf::Which;
    use crate::{chrony, dhcp, dnsmasq_conf, kea_conf, log, nginx_conf, pdns_conf, recursor_conf};
    use std::path::PathBuf;

    // What: secrets the configs embed.
    // Why: read by the caller from the secret store.
    // From: Issue #1683 | PR #1858
    pub struct Secrets {
        pub pdns_api_key: String,
        pub recursor_api_key: String,
        pub tsig_name: String,
        pub tsig_secret: String,
    }

    // What: one file to write and its owning container.
    // Why: apply::plan needs the owner of each change.
    // From: Issue #1683 | PR #1858
    pub struct File {
        pub owner: &'static str,
        pub path: PathBuf,
        pub body: String,
    }

    // What: render all files; collect every error.
    // Why: one bad value names itself; nothing half-written.
    // From: Issue #1683 | PR #1858
    pub fn all(s: &Settings, sec: &Secrets, serial: u32) -> Result<Vec<File>, Vec<String>> {
        let mut out = Vec::new();
        let mut errs = Vec::new();
        let mut jobs: Vec<(&'static str, String, Result<String, String>)> = Vec::new();
        let mut add = |owner: &'static str, key: &str, body: Result<String, String>| {
            jobs.push((owner, key.to_string(), body));
        };
        let json = |v: Result<serde_json::Value, String>| {
            v.and_then(|v| serde_json::to_string_pretty(&v).map_err(|e| e.to_string()))
        };
        add("dns", "CHRONY_CONF_FILE", chrony::conf(s));
        add("dns", "SYSLOG_CONF_FILE", log::conf(s));
        add(
            "dns",
            "PDNS_CONF_FILE",
            pdns_conf::auth(s, &sec.pdns_api_key),
        );
        let domains = crate::cdn::effective(s);
        let list: Vec<String> = domains
            .as_deref()
            .unwrap_or_default()
            .lines()
            .filter_map(crate::dns::cdn_entry)
            .map(|(n, _)| n)
            .collect();
        for (which, ip_key) in [(Which::Http, "IP_HTTP"), (Which::Https, "IP_HTTPS")] {
            let Ok(ip) = s.text(ip_key) else { continue };
            let rpz_path = s.text(&which.key("RPZ_FILE"));
            let lua_path = s.text(&which.key("LUA_FILE"));
            add(
                "dns",
                &which.key("RPZ_FILE"),
                recursor_conf::rpz(&list, &ip, serial),
            );
            add(
                "dns",
                &which.key("LUA_FILE"),
                rpz_path.clone().and_then(|p| recursor_conf::lua(&p)),
            );
            add(
                "dns",
                &which.key("CONF_FILE"),
                lua_path.and_then(|l| recursor_conf::yaml(s, which, &sec.recursor_api_key, &l)),
            );
        }
        if s.flag("DNS_FILTER_AAAA").unwrap_or(false) {
            add(
                "dns",
                "RECURSOR_AAAA_LUA_FILE",
                Ok(recursor_conf::AAAA_FILTER_LUA.to_string()),
            );
        }
        match dhcp::Mode::from_settings(s) {
            Ok(dhcp::Mode::Kea) => {
                add("dhcp", "KEA_DHCP4_CONF_FILE", json(kea_conf::dhcp4(s)));
                add("dhcp", "KEA_CTRL_CONF_FILE", json(kea_conf::ctrl_agent(s)));
                add(
                    "dhcp",
                    "KEA_DDNS_CONF_FILE",
                    json(kea_conf::ddns(s, &sec.tsig_name, &sec.tsig_secret)),
                );
            }
            Ok(m @ (dhcp::Mode::DnsmasqProxy | dhcp::Mode::DnsmasqRelay)) => {
                add("dhcp", "DNSMASQ_CONF_FILE", dnsmasq_conf::conf(s, m));
            }
            Ok(dhcp::Mode::Off) => {}
            Err(e) => add("dhcp", "DHCP_MODE", Err(e)),
        }
        drop(add);
        for (owner, key, body) in jobs {
            match (s.text(&key), body) {
                (Ok(p), Ok(b)) => out.push(File {
                    owner,
                    path: PathBuf::from(p),
                    body: b,
                }),
                (Err(e), _) | (_, Err(e)) => errs.push(e),
            }
        }
        match nginx_files(s, domains.as_deref().unwrap_or_default()) {
            Ok(files) => out.extend(files),
            Err(e) => errs.push(e),
        }
        if let Err(e) = domains {
            errs.push(e);
        }
        if errs.is_empty() {
            Ok(out)
        } else {
            Err(errs)
        }
    }

    // What: nginx templates plus generated includes.
    // Why: templates ship in the ui image; dir from SOT.
    // From: Issue #1683 | PR #1858
    fn nginx_files(s: &Settings, domains: &str) -> Result<Vec<File>, String> {
        let src = PathBuf::from(s.text("NGINX_TEMPLATE_DIR")?);
        let dst = PathBuf::from(s.text("NGINX_DIR")?);
        let psl_path = src.join(s.text("NGINX_PSL_FILE")?);
        let psl = std::fs::read_to_string(&psl_path)
            .map_err(|e| format!("{}: {e}", psl_path.display()))?;
        let hosts = nginx_conf::hosts(domains, &nginx_conf::Psl::parse(&psl))?;
        let https = s.flag("HTTPS_ENABLED")?;
        let mut out = Vec::new();
        for name in s.list("NGINX_TEMPLATES") {
            if !https && name.ends_with("https.conf") {
                continue;
            }
            let p = src.join(&name);
            let text = std::fs::read_to_string(&p).map_err(|e| format!("{}: {e}", p.display()))?;
            out.push(File {
                owner: "proxy",
                path: dst.join(&name),
                body: nginx_conf::template(&text, s)?,
            });
        }
        for (rel, body) in nginx_conf::files(s, &hosts, https)? {
            out.push(File {
                owner: "proxy",
                path: dst.join(rel),
                body,
            });
        }
        Ok(out)
    }
}

// What: one SNTP query (RFC 4330) to a time server.
// Why: the ui shows whether chrony really answers.
// From: Issue #1683 | PR #1858
pub mod ntp {
    use std::net::UdpSocket;
    use std::time::Duration;

    // What: true when a valid server reply arrives.
    // Why: mode 4 (server) and stratum 1..15 mean usable.
    // From: Issue #1683 | PR #1858
    pub fn answers(host: &str, port: u64, wait: Duration) -> bool {
        let Ok(sock) = UdpSocket::bind("0.0.0.0:0") else {
            return false;
        };
        if sock.set_read_timeout(Some(wait)).is_err() {
            return false;
        }
        let mut req = [0u8; 48];
        req[0] = 0b0010_0011; // LI 0, version 4, mode 3 (client)
        if sock.send_to(&req, format!("{host}:{port}")).is_err() {
            return false;
        }
        let mut buf = [0u8; 48];
        match sock.recv(&mut buf) {
            Ok(n) if n >= 48 => buf[0] & 0b111 == 4 && (1..=15).contains(&buf[1]),
            _ => false,
        }
    }
}

// What: proxy access log: last requests and hit stats.
// Why: dashboard and logs page read one parser.
// From: Issue #1683 | PR #1858
pub mod access {
    use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
    use std::path::{Path, PathBuf};

    // What: one parsed request of nginx log_format cache.
    // Why: the ui shows host, path, status, size, cache.
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

    // What: parse one line; None if it is no cache line.
    // Why: syslog prefix before the address is ignored.
    // From: Issue #1683 | PR #1858
    pub fn parse(line: &str) -> Option<Entry> {
        let (head, rest) = line.split_once(" - [")?;
        let ip = head.rsplit(' ').next()?.to_string();
        let (time, rest) = rest.split_once("] \"")?;
        let (request, rest) = rest.split_once("\" ")?;
        let mut req = request.split(' ');
        let (method, path) = (
            req.next()?.to_string(),
            req.next().unwrap_or_default().to_string(),
        );
        let mut f = rest.splitn(3, ' ');
        let status = f.next()?.parse().ok()?;
        let bytes = f.next()?.parse().ok()?;
        let mut q = f.next()?.split('"').filter(|p| !p.trim().is_empty());
        let cache_status = q.next()?.to_string();
        let host = q.next().unwrap_or_default().to_string();
        Some(Entry {
            ip,
            time: time.to_string(),
            method,
            path,
            status,
            bytes,
            cache_status,
            host,
        })
    }

    // What: log files of the proxy, oldest first.
    // Why: syslog-ng writes one file per day (YYYYMMDD.log).
    // From: Issue #1683 | PR #1858
    pub fn files(dir: &Path) -> Vec<PathBuf> {
        let mut out: Vec<PathBuf> = std::fs::read_dir(dir)
            .map(|rd| rd.filter_map(|e| e.ok().map(|e| e.path())).collect())
            .unwrap_or_default();
        out.retain(|p| p.extension().is_some_and(|e| e == "log"));
        out.sort();
        out
    }

    // What: last `limit` lines of the newest log file.
    // Why: reads from the end; big logs stay cheap.
    // From: Issue #1683 | PR #1858
    pub fn tail_lines(dir: &Path, limit: usize, chunk: u64) -> Vec<String> {
        let Some(path) = files(dir).pop() else {
            return Vec::new();
        };
        let Ok(mut file) = std::fs::File::open(&path) else {
            return Vec::new();
        };
        let Ok(mut pos) = file.seek(SeekFrom::End(0)) else {
            return Vec::new();
        };
        let mut buf: Vec<u8> = Vec::new();
        while pos > 0 && buf.iter().filter(|b| **b == b'\n').count() <= limit {
            let len = chunk.max(1).min(pos);
            pos -= len;
            let mut part = vec![0u8; usize::try_from(len).unwrap_or(0)];
            if file.seek(SeekFrom::Start(pos)).is_err() || file.read_exact(&mut part).is_err() {
                break;
            }
            part.extend_from_slice(&buf);
            buf = part;
        }
        let text = String::from_utf8_lossy(&buf);
        let mut lines: Vec<String> = text
            .lines()
            .skip(usize::from(pos > 0))
            .map(str::to_string)
            .collect();
        let from = lines.len().saturating_sub(limit);
        lines.split_off(from)
    }

    // What: last `limit` cache requests.
    // Why: dashboard list; non-cache lines are skipped.
    // From: Issue #1683 | PR #1858
    pub fn tail(dir: &Path, limit: usize, chunk: u64) -> Vec<Entry> {
        let mut found: Vec<Entry> = tail_lines(dir, limit.saturating_mul(4), chunk)
            .iter()
            .filter_map(|l| parse(l))
            .collect();
        let from = found.len().saturating_sub(limit);
        found.split_off(from)
    }

    // What: totals over all proxy log files.
    // Why: hit rate and traffic for the dashboard.
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

    // What: count requests, hits and bytes.
    // Why: HIT counts as hit; MISS, EXPIRED as miss.
    // From: Issue #1683 | PR #1858
    pub fn stats(dir: &Path) -> Stats {
        let mut s = Stats::default();
        for path in files(dir) {
            let Ok(file) = std::fs::File::open(&path) else {
                continue;
            };
            for line in BufReader::new(file).lines().map_while(Result::ok) {
                let Some(e) = parse(&line) else { continue };
                s.total_requests += 1;
                s.total_bytes += e.bytes;
                match e.cache_status.as_str() {
                    "HIT" => s.hits += 1,
                    "MISS" | "EXPIRED" => s.misses += 1,
                    _ => s.other += 1,
                }
            }
        }
        let base = s.hits + s.misses;
        if base > 0 {
            let pct = s.hits as f64 * 100.0 / base as f64;
            s.hit_pct = pct;
        }
        s
    }
}

// What: byte count as text with binary units.
// Why: ui pages show sizes the same way everywhere.
// From: Issue #1683 | PR #1858
pub mod human {
    // What: 1536 -> "1.5 KiB".
    // Why: integer maths; one decimal is enough.
    // From: Issue #1683 | PR #1858
    pub fn bytes(n: u64) -> String {
        const UNITS: [&str; 6] = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];
        let mut unit = 0;
        let mut whole = n;
        let mut tenth = 0;
        while whole >= 1024 && unit + 1 < UNITS.len() {
            tenth = (whole % 1024) * 10 / 1024;
            whole /= 1024;
            unit += 1;
        }
        if unit == 0 {
            format!("{n} B")
        } else {
            format!("{whole}.{tenth} {}", UNITS[unit])
        }
    }
}

// What: effective cache domain list.
// Why: shipped list minus disabled plus custom entries.
// From: Issue #1683 | PR #1858
pub mod cdn {
    use crate::config::Settings;

    // What: one row of the domain table.
    // Why: the ui shows default and custom rows apart.
    // From: Issue #1683 | PR #1858
    #[derive(Clone, Debug, serde::Serialize)]
    pub struct Row {
        pub display: String,
        pub is_default: bool,
        pub enabled: bool,
        pub is_valid: bool,
    }

    // What: shipped default rows from the image file.
    // Why: the file ships; comments and blanks are skipped.
    // From: Issue #1683 | PR #1858
    pub fn defaults(s: &Settings) -> Result<Vec<String>, String> {
        let path = s.text("CDN_DEFAULT_DOMAINS_FILE")?;
        let text = std::fs::read_to_string(&path).map_err(|e| format!("{path}: {e}"))?;
        Ok(text
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
            .map(str::to_ascii_lowercase)
            .collect())
    }

    // What: all rows for the ui.
    // Why: default rows carry their on/off state.
    // From: Issue #1683 | PR #1858
    pub fn rows(s: &Settings) -> Result<Vec<Row>, String> {
        let off = s.list("CDN_DISABLED_DOMAINS");
        let mut out: Vec<Row> = defaults(s)?
            .into_iter()
            .map(|d| Row {
                is_valid: crate::dns::cdn_entry(&d).is_some(),
                enabled: !off.contains(&d),
                display: d,
                is_default: true,
            })
            .collect();
        out.extend(s.list("CDN_CUSTOM_DOMAINS").into_iter().map(|d| Row {
            is_valid: crate::dns::cdn_entry(&d).is_some(),
            enabled: true,
            display: d,
            is_default: false,
        }));
        Ok(out)
    }

    // What: effective list as text, one entry per line.
    // Why: input of RPZ and nginx host maps.
    // From: Issue #1683 | PR #1858
    pub fn effective(s: &Settings) -> Result<String, String> {
        Ok(rows(s)?
            .into_iter()
            .filter(|r| r.enabled)
            .map(|r| r.display + "\n")
            .collect())
    }
}
