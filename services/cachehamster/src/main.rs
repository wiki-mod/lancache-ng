//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: cachehamster prefill scaffold, URL list only.
//! Why: no Steam login yet; URLs come from the env.
//! From: Issue #871

use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use argon2::Argon2;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use futures_util::{StreamExt, stream};
use lancache_common::config::{OutOfRange, Uint, env_opt};
use lancache_common::{Place, is_placeholder, load_or_create_hex, write_file};
use serde::{Deserialize, Serialize};

// What: sizes of master secret, salt and nonce in bytes.
// Why: 192-bit random nonces; Argon2 wants a 16-byte salt.
const MASTER_LEN: usize = 32;
const SALT_LEN: usize = 16;
const NONCE_LEN: usize = 24;

// What: throughput log period, 10 s; a justified literal.
// Why: no config owner exists; it only paces a readout.
const THROUGHPUT_EVERY: Duration = Duration::from_secs(10);

// What: in-flight fetches; 4 when unset or invalid.
// Why: a bad value costs speed only, so it does not fail.
const CONCURRENCY: Uint = Uint {
    name: "CACHEHAMSTER_CONCURRENCY",
    default: 4,
    min: 1,
    max: u32::MAX as u64,
    below: OutOfRange::Default,
    above: OutOfRange::Default,
};

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
        .encrypt(XNonce::from_slice(&nonce), plaintext)
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
    if sealed.nonce.len() != NONCE_LEN {
        bail!("persisted credential has a malformed nonce");
    }
    cipher_for(master, &sealed.salt)?
        .decrypt(
            XNonce::from_slice(&sealed.nonce),
            sealed.ciphertext.as_ref(),
        )
        .map_err(|e| {
            anyhow::anyhow!(
                "credential decryption failed (wrong master secret, or data corrupted): {e}"
            )
        })
}

// What: whether the credential may rest on disk.
// Why: the operator decides; an unknown value fails closed.
fn persistence_from(value: Option<&str>) -> Result<bool> {
    match value {
        None | Some("none") => Ok(false),
        Some("persistent") => Ok(true),
        Some(other) => bail!(
            "CACHEHAMSTER_CREDENTIAL_PERSISTENCE must be \"none\" or \"persistent\" (or unset, defaulting to \"none\"); got {other:?}"
        ),
    }
}

// What: a set placeholder credential is an error.
// Why: a checked-in example must fail closed (AG-SEC-002).
// From: Issue #967
fn real_credential(value: Option<String>) -> Result<Option<String>> {
    match value {
        Some(v) if is_placeholder(&v) => bail!(
            "CACHEHAMSTER_STEAM_CREDENTIAL is set to a default placeholder value -- refusing to start. Set it to a real Steam credential, or unset it entirely to run without one."
        ),
        other => Ok(other),
    }
}

// What: the credential for this run, or none configured.
// Why: an env value wins and is sealed when persisting.
fn credential(persist: bool, dir: &Path) -> Result<Option<String>> {
    let from_env = real_credential(env_opt("CACHEHAMSTER_STEAM_CREDENTIAL"))?;
    if !persist {
        return Ok(from_env);
    }
    let master =
        load_or_create_hex::<MASTER_LEN>(&dir.join("lancache-cachehamster-master.secret"))?;
    let path = dir.join("lancache-cachehamster-credential.json");
    if let Some(plain) = from_env {
        let json = serde_json::to_vec(&seal(&master, plain.as_bytes())?)?;
        write_file(&path, &json, 0o600, Place::Replace)?;
        return Ok(Some(plain));
    }
    match std::fs::read(&path) {
        Ok(json) => {
            let plain = open(&master, &serde_json::from_slice(&json)?)?;
            Ok(Some(
                String::from_utf8(plain).context("persisted credential is not valid UTF-8")?,
            ))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.into()),
    }
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

// What: resolve the credential, then drain every URL.
// Why: the proxy caches the bytes; none are kept.
#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();
    tracing::warn!(
        "lancache-cachehamster is a scaffold (issue #871): it does not yet resolve a Steam app ID to real depot chunk URLs. See docs/design-steam-prefill.md for the current implementation plan and open decisions."
    );

    let data_dir = env_opt("CACHEHAMSTER_DATA_DIR")
        .context("CACHEHAMSTER_DATA_DIR is not set; the image sets it, a manual run must")?;
    let persist = persistence_from(env_opt("CACHEHAMSTER_CREDENTIAL_PERSISTENCE").as_deref())?;
    let configured = credential(persist, Path::new(&data_dir))?.is_some();
    tracing::info!(
        credential_persistent = persist,
        credential_configured = configured,
        "credential resolution complete (plaintext value itself is never logged)"
    );

    let urls: Vec<String> = env_opt("CACHEHAMSTER_URLS")
        .unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|u| !u.is_empty())
        .map(str::to_string)
        .collect();
    if urls.is_empty() {
        tracing::warn!(
            "CACHEHAMSTER_URLS is empty; nothing to fetch. This scaffold has no real depot-manifest resolution yet, so it can only warm a directly-configured URL list."
        );
        return Ok(());
    }

    let (limit, warning) = CONCURRENCY.parse(env_opt("CACHEHAMSTER_CONCURRENCY").as_deref());
    if let Some(warning) = warning {
        tracing::warn!("{warning}");
    }
    let total = AtomicU64::new(0);
    let client = reqwest::Client::new();
    // What: bounded fetch fan-out with a throughput tick.
    // Why: one task owns both, so no stop signal is needed.
    // From: Issue #871
    let fetch = stream::iter(&urls)
        .map(|url| drain(&client, url, &total))
        .buffer_unordered(usize::try_from(limit)?)
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
                tracing::info!(bytes_total = now, mbit_per_sec = format!("{mbit:.1}"), "prefill throughput");
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

#[cfg(test)]
mod tests {
    use super::*;

    // What: persistence values parse; unknown fails closed.
    // Why: persistence is the operator's call, not guessed.
    // From: Issue #871
    #[test]
    fn persistence_parses_and_fails_closed() {
        assert!(!persistence_from(None).unwrap());
        assert!(!persistence_from(Some("none")).unwrap());
        assert!(persistence_from(Some("persistent")).unwrap());
        assert!(persistence_from(Some("bogus")).is_err());
    }

    // What: only a set placeholder credential is rejected.
    // Why: dropping it quietly would hide the mistake.
    // From: Issue #967
    #[test]
    fn placeholder_credentials_are_rejected_others_pass() {
        assert_eq!(real_credential(None).unwrap(), None);
        let real = Some("a-real-looking-secret-value".to_string());
        assert_eq!(real_credential(real.clone()).unwrap(), real);
        assert!(real_credential(Some("CHANGE_ME_now".into())).is_err());
    }

    // What: seal then open gives the plaintext.
    // Why: recoverable, yet equal inputs stay unlinkable.
    // From: Issue #871
    #[test]
    fn seal_round_trips_and_never_repeats() {
        let master: [u8; MASTER_LEN] = rand::random();
        let plain = b"a-steam-password-or-refresh-token";
        let first = seal(&master, plain).unwrap();
        let second = seal(&master, plain).unwrap();
        assert_eq!(open(&master, &first).unwrap(), plain);
        assert_ne!(first.ciphertext, second.ciphertext);
        assert_ne!(first.nonce, second.nonce);
        assert_ne!(first.salt, second.salt);
    }

    // What: a wrong master secret fails to open.
    // Why: the AEAD tag must reject, never return garbage.
    // From: Issue #871
    #[test]
    fn open_fails_with_a_wrong_master_secret() {
        let master: [u8; MASTER_LEN] = rand::random();
        let other: [u8; MASTER_LEN] = rand::random();
        let sealed = seal(&master, b"another-secret").unwrap();
        assert!(open(&other, &sealed).is_err());
    }
}
