//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: cachehamster prefill scaffold, URL list only.
//! Why: no Steam login yet; URLs come from the env.
//! From: Issue #871

use std::fs;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use argon2::Argon2;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use futures_util::{StreamExt, stream};
use lancache_ng::config::{env_opt, need, process_env, uint};
use lancache_ng::{Place, is_placeholder, load_or_create_hex, write_file};
use serde::{Deserialize, Serialize};

// What: sizes of master secret, salt and nonce in bytes.
// Why: 192-bit random nonces; Argon2 wants a 16-byte salt.
const MASTER_LEN: usize = 32;
const SALT_LEN: usize = 16;
const NONCE_LEN: usize = 24;

// What: file names below the data dir, master and sealed.
// Why: persisted files must be found again after a restart.
const MASTER_FILE: &str = "lancache-cachehamster-master.secret";
const CREDENTIAL_FILE: &str = "lancache-cachehamster-credential.json";

// What: throughput log period, 10 s; a justified literal.
// Why: no config owner exists; it only paces a readout.
const THROUGHPUT_EVERY: Duration = Duration::from_secs(10);

// What: a credential as stored: salt, nonce, ciphertext.
// Why: the plaintext must never reach the disk.
#[derive(Serialize, Deserialize)]
struct Sealed {
    salt: Vec<u8>,
    nonce: Vec<u8>,
    ciphertext: Vec<u8>,
}

// What: the AEAD cipher keyed by Argon2id(master, salt).
// Why: the credential is recovered, so no one-way hash.
fn cipher_for(master: &[u8; MASTER_LEN], salt: &[u8]) -> Result<XChaCha20Poly1305> {
    let mut key = [0u8; 32];
    Argon2::default()
        .hash_password_into(master, salt, &mut key)
        .map_err(|e| anyhow::anyhow!("Argon2id key derivation failed: {e}"))?;
    Ok(XChaCha20Poly1305::new((&key).into()))
}

// What: seal plaintext under a fresh salt and nonce.
// Why: equal credentials must not give equal files.
fn seal(master: &[u8; MASTER_LEN], plaintext: &[u8]) -> Result<Sealed> {
    let salt: [u8; SALT_LEN] = rand::random();
    let nonce: [u8; NONCE_LEN] = rand::random();
    let ciphertext = cipher_for(master, &salt)?
        .encrypt(&XNonce::from(nonce), plaintext)
        .map_err(|e| anyhow::anyhow!("credential encryption failed: {e}"))?;
    Ok(Sealed {
        salt: salt.to_vec(),
        nonce: nonce.to_vec(),
        ciphertext,
    })
}

// What: open a sealed credential; it stays in memory.
// Why: the AEAD tag rejects a wrong secret or tampering.
fn open(master: &[u8; MASTER_LEN], sealed: &Sealed) -> Result<Vec<u8>> {
    let nonce = XNonce::try_from(sealed.nonce.as_slice())
        .map_err(|_| anyhow::anyhow!("persisted credential has a malformed nonce"))?;
    cipher_for(master, &sealed.salt)?
        .decrypt(&nonce, sealed.ciphertext.as_ref())
        .map_err(|e| {
            anyhow::anyhow!(
                "credential decryption failed (wrong master secret, or data corrupted): {e}"
            )
        })
}

// What: the stored credential, or none when never sealed.
// Why: only the sealed file holds it; no env value exists.
fn stored_credential(dir: &Path) -> Result<Option<String>> {
    match fs::read(dir.join(CREDENTIAL_FILE)) {
        Ok(json) => {
            let master = load_or_create_hex::<MASTER_LEN>(&dir.join(MASTER_FILE))?;
            let plain = open(&master, &serde_json::from_slice(&json)?)?;
            Ok(Some(
                String::from_utf8(plain).context("stored credential is not valid UTF-8")?,
            ))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.into()),
    }
}

// What: seal one credential into the data dir, mode 0600.
// Why: a stored credential never rests in plaintext.
// From: Issue #871 | PR #1912
fn store_credential(dir: &Path, plain: &str) -> Result<()> {
    if plain.is_empty() {
        bail!("the credential is empty");
    }
    if is_placeholder(plain) {
        bail!("the credential is a default placeholder value (AG-SEC-002)");
    }
    let master = load_or_create_hex::<MASTER_LEN>(&dir.join(MASTER_FILE))?;
    let json = serde_json::to_vec(&seal(&master, plain.as_bytes())?)?;
    write_file(&dir.join(CREDENTIAL_FILE), &json, 0o600, Place::Replace)?;
    Ok(())
}

// What: the seal command; first stdin line is sealed.
// Why: the secret never enters an env file or argv.
// From: Issue #871 | PR #1912
fn seal_from_stdin() -> Result<()> {
    let data_dir = need(&process_env, "CACHEHAMSTER_DATA_DIR").map_err(anyhow::Error::msg)?;
    let mut line = String::new();
    std::io::stdin()
        .read_line(&mut line)
        .context("cannot read the credential from stdin")?;
    store_credential(Path::new(&data_dir), line.trim_end_matches(['\r', '\n']))
}

// What: stream one body and drop each chunk on arrival.
// Why: the proxy caches the bytes; none are kept here.
// From: Issue #816
async fn drain(client: &reqwest::Client, url: &str, total: &AtomicU64) -> Result<u64> {
    let mut body = client
        .get(url)
        .send()
        .await?
        .error_for_status()?
        .bytes_stream();
    let mut bytes = 0u64;
    while let Some(chunk) = body.next().await {
        let len = chunk?.len() as u64;
        bytes += len;
        total.fetch_add(len, Ordering::Relaxed);
    }
    Ok(bytes)
}

// What: check the stored credential, then drain every URL.
// Why: the proxy caches the bytes; none are kept.
#[tokio::main]
async fn main() -> Result<()> {
    if std::env::args().nth(1).as_deref() == Some("seal") {
        return seal_from_stdin();
    }
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();
    tracing::warn!("no Steam app ID resolution; only CACHEHAMSTER_URLS is fetched");

    let data_dir = need(&process_env, "CACHEHAMSTER_DATA_DIR").map_err(anyhow::Error::msg)?;
    let configured = stored_credential(Path::new(&data_dir))?.is_some();
    tracing::info!(credential_configured = configured, "credential resolved");

    let urls: Vec<String> = env_opt("CACHEHAMSTER_URLS")
        .unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|u| !u.is_empty())
        .map(str::to_string)
        .collect();
    if urls.is_empty() {
        tracing::warn!("CACHEHAMSTER_URLS is empty; nothing to fetch");
        return Ok(());
    }

    // What: the in-flight fetch count, 1 to u32::MAX.
    // Why: the SOT owns the number; Rust owns limits.
    // From: Issue #1683 | PR #1912
    let limit = uint(&process_env, "CACHEHAMSTER_CONCURRENCY", 1, u32::MAX.into())
        .map_err(anyhow::Error::msg)?;
    let total = Arc::new(AtomicU64::new(0));
    // What: a client without a total request timeout.
    // Why: a large body streams longer than a 10 s limit.
    let client = reqwest::Client::new();
    // What: run the capped fetches; log throughput.
    // Why: spawned tasks spread over all worker threads.
    // From: Issue #871
    let fetch = stream::iter(urls)
        .map(|url| {
            let (client, total) = (client.clone(), Arc::clone(&total));
            tokio::spawn(async move { drain(&client, &url, &total).await })
        })
        .buffer_unordered(usize::try_from(limit)?)
        .map(|joined| {
            joined
                .map_err(anyhow::Error::from)
                .and_then(|result| result)
        })
        .collect::<Vec<_>>();
    tokio::pin!(fetch);
    let mut ticker = tokio::time::interval(THROUGHPUT_EVERY);
    ticker.tick().await;
    let mut last = 0u64;
    let results = loop {
        tokio::select! {
            results = &mut fetch => break results,
            _ = ticker.tick() => {
                let now = total.load(Ordering::Relaxed);
                let mbit = (now - last) as f64 * 8.0 / THROUGHPUT_EVERY.as_secs_f64() / 1_000_000.0;
                tracing::info!(
                    bytes_total = now,
                    bytes_since_last = now - last,
                    mbit_per_sec = format!("{mbit:.1}"),
                    "prefill throughput"
                );
                last = now;
            }
        }
    };

    let failed = results.iter().filter(|r| r.is_err()).count();
    for error in results.iter().filter_map(|r| r.as_ref().err()) {
        tracing::error!(%error, "one fetch failed");
    }
    tracing::info!(
        fetched_ok = results.len() - failed,
        fetched_err = failed,
        total_bytes = total.load(Ordering::Relaxed),
        "prefill run complete"
    );
    Ok(())
}
