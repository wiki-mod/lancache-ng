//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: cachehamster Steam prefill, scaffold, URL list.
//! Why: no Steam login yet; URLs come from the env.
//! From: Issue #871

use std::fs::{self, OpenOptions};
use std::io::Write;
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use argon2::Argon2;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use futures_util::StreamExt;
use lancache_common::config::env_opt;
use lancache_common::{is_placeholder, load_or_create_hex_secret};
use tokio::sync::Semaphore;
use tokio::task::JoinSet;

// What: default location of this service's own secrets.
// Why: the /data volume convention the other services use.
// From: Issue #871
const DEFAULT_DATA_DIR: &str = "/data";
// What: byte length of the persisted master secret.
// Why: 32 bytes, like the ui session secret.
// From: Issue #871
const MASTER_SECRET_LEN: usize = 32;
// What: byte length of the per-credential Argon2id salt.
// Why: 16 bytes is Argon2's documented minimum salt size.
// From: Issue #871
const SALT_LEN: usize = 16;
// What: byte length of the XChaCha20-Poly1305 nonce.
// Why: 192-bit random nonces stay unique on rotation.
// From: Issue #871
const NONCE_LEN: usize = 24;
// What: byte length of the derived symmetric key.
// Why: the key size XChaCha20-Poly1305 requires.
// From: Issue #871
const KEY_LEN: usize = 32;

// What: encrypted-at-rest Steam credential, no Debug.
// Why: only decrypt may recover the plaintext bytes.
// From: Issue #871
#[derive(Clone, serde::Serialize, serde::Deserialize)]
struct EncryptedCredential {
    salt: Vec<u8>,
    nonce: Vec<u8>,
    ciphertext: Vec<u8>,
}

// What: the operator's credential persistence choice.
// Why: None keeps the credential in memory only.
// From: Issue #871
#[derive(Debug, Clone, Copy)]
enum CredentialPersistence {
    None,
    Persistent,
}

// What: persistence mode from an already-read value.
// Why: an unknown value fails closed; tests need no env.
// From: Issue #871 | PR #1858
fn parse_credential_persistence(value: Option<&str>) -> anyhow::Result<CredentialPersistence> {
    match value {
        Some("none") | None => Ok(CredentialPersistence::None),
        Some("persistent") => Ok(CredentialPersistence::Persistent),
        Some(other) => anyhow::bail!(
            "CACHEHAMSTER_CREDENTIAL_PERSISTENCE must be \"none\" or \"persistent\" (or unset, \
             defaulting to \"none\"); got {other:?}"
        ),
    }
}

// What: a set placeholder credential is an error.
// Why: a checked-in example must fail closed (AG-SEC-002).
// From: Issue #967
fn reject_placeholder_credential(value: Option<String>) -> anyhow::Result<Option<String>> {
    if let Some(inner) = value.as_deref()
        && is_placeholder(inner)
    {
        anyhow::bail!(
            "CACHEHAMSTER_STEAM_CREDENTIAL is set to a default placeholder value -- refusing to \
             start. Set it to a real Steam credential, or unset it entirely to run without one."
        );
    }
    Ok(value)
}

// What: Argon2id as a raw KDF over master secret and salt.
// Why: the one-way PHC form cannot yield a usable key.
// From: Issue #871
fn derive_key(
    master_secret: &[u8; MASTER_SECRET_LEN],
    salt: &[u8],
) -> anyhow::Result<[u8; KEY_LEN]> {
    let mut key = [0u8; KEY_LEN];
    Argon2::default()
        .hash_password_into(master_secret, salt, &mut key)
        .map_err(|e| anyhow::anyhow!("Argon2id key derivation failed: {e}"))?;
    Ok(key)
}

// What: seal plaintext with a fresh salt and nonce.
// Why: the credential must never rest on disk in clear.
// From: Issue #871
fn encrypt(
    master_secret: &[u8; MASTER_SECRET_LEN],
    plaintext: &[u8],
) -> anyhow::Result<EncryptedCredential> {
    let salt: [u8; SALT_LEN] = rand::random();
    let key = derive_key(master_secret, &salt)?;
    let cipher = XChaCha20Poly1305::new((&key).into());
    let nonce_bytes: [u8; NONCE_LEN] = rand::random();
    let ciphertext = cipher
        .encrypt(XNonce::from_slice(&nonce_bytes), plaintext)
        .map_err(|e| anyhow::anyhow!("credential encryption failed: {e}"))?;
    Ok(EncryptedCredential {
        salt: salt.to_vec(),
        nonce: nonce_bytes.to_vec(),
        ciphertext,
    })
}

// What: open a sealed credential, in memory only.
// Why: AEAD fails on a wrong secret or tampered data.
// From: Issue #871
fn decrypt(
    master_secret: &[u8; MASTER_SECRET_LEN],
    stored: &EncryptedCredential,
) -> anyhow::Result<Vec<u8>> {
    let key = derive_key(master_secret, &stored.salt)?;
    let cipher = XChaCha20Poly1305::new((&key).into());
    cipher
        .decrypt(
            XNonce::from_slice(&stored.nonce),
            stored.ciphertext.as_ref(),
        )
        .map_err(|e| {
            anyhow::anyhow!(
                "credential decryption failed (wrong master secret, or data corrupted): {e}"
            )
        })
}

// What: write the sealed credential, replacing any old one.
// Why: rotation overwrites, so no create_new; 0600.
// From: Issue #871
fn save_encrypted_credential(path: &str, credential: &EncryptedCredential) -> anyhow::Result<()> {
    let json = serde_json::to_string(credential)?;
    let mut open_options = OpenOptions::new();
    open_options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    open_options.mode(0o600);
    let mut file = open_options.open(path)?;
    file.write_all(json.as_bytes())?;
    file.sync_all()?;
    Ok(())
}

// What: read the sealed credential; a missing file is None.
// Why: no stored credential is the normal first-run state.
// From: Issue #871
fn load_encrypted_credential(path: &str) -> anyhow::Result<Option<EncryptedCredential>> {
    match fs::read_to_string(path) {
        Ok(contents) => Ok(Some(serde_json::from_str(&contents)?)),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(err.into()),
    }
}

// What: the credential held for this run, per persistence.
// Why: None never uses disk; Persistent seals, reuses.
// From: Issue #871
fn resolve_steam_credential(
    persistence: CredentialPersistence,
    data_dir: &str,
) -> anyhow::Result<Option<String>> {
    let env_credential = reject_placeholder_credential(env_opt("CACHEHAMSTER_STEAM_CREDENTIAL"))?;

    match persistence {
        CredentialPersistence::None => Ok(env_credential),
        CredentialPersistence::Persistent => {
            let master_secret_path = format!("{data_dir}/lancache-cachehamster-master.secret");
            let credential_path = format!("{data_dir}/lancache-cachehamster-credential.json");
            let master_secret =
                load_or_create_hex_secret::<MASTER_SECRET_LEN>(&master_secret_path)?;

            // What: an env credential replaces the stored one.
            // Why: an operator-set real value wins.
            // From: Issue #871
            if let Some(plaintext) = env_credential {
                let encrypted = encrypt(&master_secret, plaintext.as_bytes())?;
                save_encrypted_credential(&credential_path, &encrypted)?;
                return Ok(Some(plaintext));
            }

            match load_encrypted_credential(&credential_path)? {
                Some(encrypted) => {
                    let decrypted = decrypt(&master_secret, &encrypted)?;
                    let plaintext = String::from_utf8(decrypted)
                        .map_err(|_| anyhow::anyhow!("persisted credential is not valid UTF-8"))?;
                    Ok(Some(plaintext))
                }
                None => Ok(None),
            }
        }
    }
}

// What: fetch list from comma-separated CACHEHAMSTER_URLS.
// Why: stand-in until depot manifests are resolved.
// From: Issue #871
fn resolve_urls() -> Vec<String> {
    std::env::var("CACHEHAMSTER_URLS")
        .unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|url| !url.is_empty())
        .map(str::to_string)
        .collect()
}

// What: in-flight fetch cap, default 4 when unset/invalid.
// Why: a bad value costs speed only, so it does not fail.
// From: Issue #871
fn resolve_concurrency() -> usize {
    std::env::var("CACHEHAMSTER_CONCURRENCY")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(4)
}

// What: running total of streamed bytes, lock-free.
// Why: fetch tasks add while the logger reads; no lock.
// From: Issue #871
#[derive(Default)]
struct ByteCounter {
    total: AtomicU64,
}

impl ByteCounter {
    fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    fn add(&self, n: u64) {
        self.total.fetch_add(n, Ordering::Relaxed);
    }

    fn total(&self) -> u64 {
        self.total.load(Ordering::Relaxed)
    }
}

// What: stream a body and drop each chunk as it arrives.
// Why: the proxy caches the bytes; nothing is kept here.
// From: Issue #816
async fn fetch_and_discard(
    client: &reqwest::Client,
    url: &str,
    counter: &ByteCounter,
) -> anyhow::Result<u64> {
    let response = client.get(url).send().await?.error_for_status()?;
    let mut stream = response.bytes_stream();
    let mut fetched: u64 = 0;
    while let Some(chunk) = stream.next().await {
        let chunk_len = chunk?.len() as u64;
        fetched += chunk_len;
        counter.add(chunk_len);
    }
    Ok(fetched)
}

// What: fetch all URLs, at most `concurrency` in flight.
// Why: unbounded spawning opens one connection per URL.
// From: Issue #871
async fn fetch_many_and_discard(
    client: reqwest::Client,
    urls: Vec<String>,
    concurrency: usize,
    counter: Arc<ByteCounter>,
) -> Vec<anyhow::Result<u64>> {
    let semaphore = Arc::new(Semaphore::new(concurrency.max(1)));
    let mut tasks = JoinSet::new();

    for url in urls {
        let client = client.clone();
        let counter = Arc::clone(&counter);
        let semaphore = Arc::clone(&semaphore);
        tasks.spawn(async move {
            let _permit = semaphore
                .acquire()
                .await
                .expect("semaphore is never closed while tasks are running");
            fetch_and_discard(&client, &url, &counter).await
        });
    }

    let mut results = Vec::new();
    while let Some(joined) = tasks.join_next().await {
        match joined {
            Ok(result) => results.push(result),
            Err(join_error) => results.push(Err(anyhow::anyhow!(
                "fetch task panicked or was cancelled: {join_error}"
            ))),
        }
    }
    results
}

// What: log throughput every interval until `stop` fires.
// Why: a stop signal can be awaited; an Arc count cannot.
// From: Issue #871
fn spawn_throughput_logger(
    counter: Arc<ByteCounter>,
    interval: Duration,
    mut stop: tokio::sync::oneshot::Receiver<()>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut last_total = counter.total();
        let mut ticker = tokio::time::interval(interval);
        loop {
            tokio::select! {
                _ = ticker.tick() => {
                    let current_total = counter.total();
                    let delta = current_total.saturating_sub(last_total);
                    let mbit_per_sec = (delta as f64 * 8.0) / interval.as_secs_f64() / 1_000_000.0;
                    tracing::info!(
                        bytes_total = current_total,
                        bytes_since_last = delta,
                        mbit_per_sec = format!("{mbit_per_sec:.1}"),
                        "prefill throughput"
                    );
                    last_total = current_total;
                }
                _ = &mut stop => break,
            }
        }
    })
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    tracing::warn!(
        "lancache-cachehamster is a scaffold (issue #871): it does not yet resolve a Steam app ID to \
         real depot chunk URLs. See docs/design-steam-prefill.md for the current implementation \
         plan and open decisions."
    );

    let data_dir =
        std::env::var("CACHEHAMSTER_DATA_DIR").unwrap_or_else(|_| DEFAULT_DATA_DIR.to_string());
    let persistence =
        parse_credential_persistence(env_opt("CACHEHAMSTER_CREDENTIAL_PERSISTENCE").as_deref())?;
    let credential = resolve_steam_credential(persistence, &data_dir)?;

    tracing::info!(
        credential_persistence = ?persistence,
        credential_configured = credential.is_some(),
        "credential resolution complete (plaintext value itself is never logged)"
    );

    let urls = resolve_urls();
    if urls.is_empty() {
        tracing::warn!(
            "CACHEHAMSTER_URLS is empty; nothing to fetch. This scaffold has no real depot-manifest \
             resolution yet, so it can only warm a directly-configured URL list."
        );
        return Ok(());
    }

    let concurrency = resolve_concurrency();
    let counter = ByteCounter::new();
    let (stop_logger_tx, stop_logger_rx) = tokio::sync::oneshot::channel();
    let logger_handle = spawn_throughput_logger(
        Arc::clone(&counter),
        Duration::from_secs(10),
        stop_logger_rx,
    );

    let client = reqwest::Client::new();
    let results = fetch_many_and_discard(client, urls, concurrency, Arc::clone(&counter)).await;

    // What: stop and await the logger before the total.
    // Why: the logger must not log again after this point.
    // From: Issue #871
    let _ = stop_logger_tx.send(());
    let _ = logger_handle.await;

    let (ok_count, err_count) = results.iter().fold((0usize, 0usize), |(ok, err), result| {
        if result.is_ok() {
            (ok + 1, err)
        } else {
            (ok, err + 1)
        }
    });
    for result in &results {
        if let Err(error) = result {
            tracing::error!(%error, "one fetch failed");
        }
    }
    tracing::info!(
        fetched_ok = ok_count,
        fetched_err = err_count,
        total_bytes = counter.total(),
        "prefill run complete"
    );

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // What: persistence values parse; unknown fails closed.
    // Why: persistence is the operator's call, not guessed.
    // From: Issue #871 | PR #1858
    #[test]
    fn credential_persistence_parses_and_fails_closed() {
        assert!(matches!(
            parse_credential_persistence(None),
            Ok(CredentialPersistence::None)
        ));
        assert!(matches!(
            parse_credential_persistence(Some("persistent")),
            Ok(CredentialPersistence::Persistent)
        ));
        assert!(parse_credential_persistence(Some("bogus")).is_err());
    }

    // What: an unset credential passes through as None.
    // Why: nothing configured is not an error.
    // From: Issue #871
    #[test]
    fn reject_placeholder_credential_passes_through_none() {
        assert_eq!(reject_placeholder_credential(None).unwrap(), None);
    }

    // What: a real credential passes through unchanged.
    // Why: only placeholder values are rejected.
    // From: Issue #871
    #[test]
    fn reject_placeholder_credential_passes_through_real_value() {
        let real = Some("a-real-looking-secret-value".to_string());
        assert_eq!(reject_placeholder_credential(real.clone()).unwrap(), real);
    }

    // What: a set placeholder credential is rejected.
    // Why: dropping it would hide the operator's mistake.
    // From: Issue #871
    #[test]
    fn reject_placeholder_credential_fails_closed_on_placeholder() {
        let result = reject_placeholder_credential(Some("CHANGE_ME_now".to_string()));
        assert!(
            result.is_err(),
            "a placeholder value must be rejected, not silently dropped"
        );
    }

    // What: encrypt then decrypt returns the plaintext.
    // Why: the credential must be usable for Steam login.
    // From: Issue #871
    #[test]
    fn encrypt_then_decrypt_round_trips() {
        let master_secret: [u8; MASTER_SECRET_LEN] = rand::random();
        let plaintext = b"a-steam-password-or-refresh-token";
        let encrypted = encrypt(&master_secret, plaintext).expect("encryption should succeed");
        let decrypted = decrypt(&master_secret, &encrypted).expect("decryption should succeed");
        assert_eq!(decrypted, plaintext);
    }

    // What: a wrong master secret fails to decrypt.
    // Why: the AEAD tag must reject, never return garbage.
    // From: Issue #871
    #[test]
    fn decrypt_fails_with_wrong_master_secret() {
        let master_secret: [u8; MASTER_SECRET_LEN] = rand::random();
        let wrong_secret: [u8; MASTER_SECRET_LEN] = rand::random();
        let encrypted =
            encrypt(&master_secret, b"another-secret").expect("encryption should succeed");
        assert!(
            decrypt(&wrong_secret, &encrypted).is_err(),
            "decryption with the wrong master secret must fail, not silently succeed"
        );
    }

    // What: equal plaintexts seal to different bytes.
    // Why: stored credentials must not reveal equality.
    // From: Issue #871
    #[test]
    fn two_encryptions_of_the_same_plaintext_produce_different_ciphertext() {
        let master_secret: [u8; MASTER_SECRET_LEN] = rand::random();
        let plaintext = b"same-password-both-times";
        let first = encrypt(&master_secret, plaintext).expect("first encryption should succeed");
        let second = encrypt(&master_secret, plaintext).expect("second encryption should succeed");
        assert_ne!(first.ciphertext, second.ciphertext);
        assert_ne!(first.nonce, second.nonce);
        assert_ne!(first.salt, second.salt);
    }

    // What: save, reload and decrypt returns the plaintext.
    // Why: the on-disk persistence path must round-trip.
    // From: Issue #871
    #[test]
    fn save_and_load_encrypted_credential_round_trips() {
        let dir = std::env::temp_dir().join(format!(
            "lancache-cachehamster-credential-test-{}",
            std::process::id()
        ));
        fs::create_dir_all(&dir).expect("temp dir should be creatable");
        let path = dir.join("credential.json");
        let path_str = path.to_str().expect("temp path should be valid UTF-8");

        let master_secret: [u8; MASTER_SECRET_LEN] = rand::random();
        let encrypted =
            encrypt(&master_secret, b"round-trip-me").expect("encryption should succeed");
        save_encrypted_credential(path_str, &encrypted).expect("save should succeed");
        let loaded = load_encrypted_credential(path_str)
            .expect("load should succeed")
            .expect("credential should exist after saving");
        let decrypted = decrypt(&master_secret, &loaded)
            .expect("decryption of the reloaded credential should succeed");
        assert_eq!(decrypted, b"round-trip-me");

        fs::remove_dir_all(&dir).ok();
    }

    // What: a missing credential file loads as None.
    // Why: normal state before the operator sets one.
    // From: Issue #871
    #[test]
    fn load_encrypted_credential_returns_none_when_absent() {
        let path = std::env::temp_dir().join(format!(
            "lancache-cachehamster-absent-credential-{}.json",
            std::process::id()
        ));
        let result =
            load_encrypted_credential(path.to_str().expect("temp path should be valid UTF-8"))
                .expect("a missing file is not an error");
        assert!(result.is_none());
    }

    // What: the byte counter starts at 0 and accumulates.
    // Why: the fetch loop relies on correct accumulation.
    // From: Issue #871
    #[test]
    fn byte_counter_starts_at_zero_and_accumulates() {
        let counter = ByteCounter::new();
        assert_eq!(counter.total(), 0);
        counter.add(100);
        counter.add(250);
        assert_eq!(counter.total(), 350);
    }

    // What: 1,250,000 bytes per second is 10.0 Mbit/s.
    // Why: the logger's rate arithmetic must be exact.
    // From: Issue #871
    #[test]
    fn throughput_rate_arithmetic_matches_expected_megabits_per_second() {
        let delta_bytes: u64 = 1_250_000;
        let interval = Duration::from_secs(1);
        let mbit_per_sec = (delta_bytes as f64 * 8.0) / interval.as_secs_f64() / 1_000_000.0;
        assert!(
            (mbit_per_sec - 10.0).abs() < 0.001,
            "1,250,000 bytes/sec should be exactly 10.0 Mbit/s, got {mbit_per_sec}"
        );
    }

    // What: the logger task ends promptly on `stop`.
    // Why: it must not run until process exit.
    // From: Issue #871
    #[tokio::test]
    async fn spawn_throughput_logger_stops_promptly_when_signaled() {
        let counter = ByteCounter::new();
        let (stop_tx, stop_rx) = tokio::sync::oneshot::channel();
        let handle =
            spawn_throughput_logger(Arc::clone(&counter), Duration::from_secs(3600), stop_rx);

        stop_tx
            .send(())
            .expect("logger task must still be listening");
        tokio::time::timeout(Duration::from_secs(5), handle)
            .await
            .expect("logger task should stop promptly after `stop` fires")
            .expect("logger task should not panic");
    }
}
