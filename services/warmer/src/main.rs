//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! lancache-warmer entry point: wires the credential-store and
//! stream-fetch primitives (see lib.rs) together into a runnable binary. This is a scaffold, not the finished Cache Warmer: it does not
//! yet log into Steam, resolve an app ID to depots, or parse a manifest.
//! What it does prove end-to-end: an operator-supplied credential can be
//! encrypted at rest (or held only in memory, operator's choice) and
//! never leaves the process in plaintext; and a list of URLs can be
//! streamed through and discarded with live throughput logging, the same
//! mechanism the eventual real depot-chunk fetch will reuse unchanged.
//!
//! Deliberately NOT implemented in this PR (see this crate's own tracking
//! issue for the full scope note): the steam-vent login flow, steamroom depot/
//! manifest parsing, and therefore any real Steam CDN URL resolution --
//! integrating those needs a real Steam account to test safely against,
//! which this session could not do. `WARMER_URLS` below is this
//! scaffold's stand-in for "the list of chunk URLs a real depot-manifest
//! resolution step would produce."

use std::sync::Arc;
use std::time::Duration;

use lancache_warmer::credential_store::{
    self, CredentialPersistence, load_or_create_master_secret,
};
use lancache_warmer::stream_fetch::{ByteCounter, fetch_many_and_discard, spawn_throughput_logger};

/// What: default location for this service's own persisted secrets.
/// Why: matches the `/data` volume convention services/ui/src/main.rs's
///   load_or_create_session_secret already uses for the same purpose.
/// From: Issue #871
const DEFAULT_DATA_DIR: &str = "/data";

/// Recognizes the project-wide placeholder shapes issue #967 established
/// (CHANGE_ME_*, YOUR_*_HERE, a bare <...> token, lancache_*_secret) so a
/// checked-in example value is rejected rather than silently used as a
/// real Steam credential (AG-SEC-002). Mirrors
/// services/ui/src/main.rs's secondary_registration_token_is_placeholder
/// byte-for-byte -- duplicated rather than shared because no crate
/// boundary currently exists between services/ui and services/warmer;
/// worth extracting to a shared crate if a third consumer ever needs the
/// same check.
fn credential_is_placeholder(value: &str) -> bool {
    if value.is_empty() {
        return true;
    }
    let normalized = value.to_lowercase().replace('-', "_");
    normalized.starts_with("change_me_")
        || (normalized.starts_with("your_") && normalized.ends_with("_here"))
        || normalized.starts_with("changeme")
        || normalized.contains("change_me")
        || (normalized.starts_with("lancache_") && normalized.ends_with("_secret"))
        || (value.starts_with('<') && value.ends_with('>'))
}

/// Resolves the operator's chosen credential-persistence mode from
/// `WARMER_CREDENTIAL_PERSISTENCE`. Fails closed on an unrecognized value
/// rather than silently defaulting either way -- persistence is the
/// operator's own decision (maintainer directive), not something this
/// binary should guess.
fn resolve_credential_persistence() -> anyhow::Result<CredentialPersistence> {
    match std::env::var("WARMER_CREDENTIAL_PERSISTENCE").as_deref() {
        Ok("none") | Err(_) => Ok(CredentialPersistence::None),
        Ok("persistent") => Ok(CredentialPersistence::Persistent),
        Ok(other) => anyhow::bail!(
            "WARMER_CREDENTIAL_PERSISTENCE must be \"none\" or \"persistent\" (or unset, defaulting \
             to \"none\"); got {other:?}"
        ),
    }
}

/// Resolves the Steam credential to hold for this run, honoring the
/// operator's persistence choice:
/// - `None`: the plaintext from `WARMER_STEAM_CREDENTIAL` (if any) is
///   used for this process only and never touches disk.
/// - `Persistent`: an env-supplied credential is encrypted and saved on
///   first use; on a later run with no env value set, the previously
///   saved one is decrypted and reused instead.
///
/// Returns `Ok(None)` when no credential is configured at all (the
/// scaffold's URL-list mode below does not require one).
fn resolve_steam_credential(
    persistence: CredentialPersistence,
    data_dir: &str,
) -> anyhow::Result<Option<String>> {
    let env_value = std::env::var("WARMER_STEAM_CREDENTIAL").ok();
    let env_value = env_value.filter(|value| !credential_is_placeholder(value));

    match persistence {
        CredentialPersistence::None => Ok(env_value),
        CredentialPersistence::Persistent => {
            let master_secret_path = format!("{data_dir}/lancache-warmer-master.secret");
            let credential_path = format!("{data_dir}/lancache-warmer-credential.json");
            let master_secret = load_or_create_master_secret(&master_secret_path)?;

            if let Some(plaintext) = env_value {
                // What: a fresh env-supplied credential overwrites any
                //   previously persisted one.
                // Why: an operator-supplied real value always wins, same
                //   convention services/ui/src/main.rs's own
                //   load_or_create_secondary_registration_token documents.
                // From: Issue #871
                let encrypted = credential_store::encrypt(&master_secret, plaintext.as_bytes())?;
                credential_store::save_encrypted_credential(&credential_path, &encrypted)?;
                return Ok(Some(plaintext));
            }

            match credential_store::load_encrypted_credential(&credential_path)? {
                Some(encrypted) => {
                    let decrypted = credential_store::decrypt(&master_secret, &encrypted)?;
                    let plaintext = String::from_utf8(decrypted)
                        .map_err(|_| anyhow::anyhow!("persisted credential is not valid UTF-8"))?;
                    Ok(Some(plaintext))
                }
                None => Ok(None),
            }
        }
    }
}

/// Parses `WARMER_URLS` (comma-separated) into the fetch list. Stand-in
/// for a real depot-manifest resolution step -- see this file's own
/// module doc comment.
fn resolve_urls() -> Vec<String> {
    std::env::var("WARMER_URLS")
        .unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|url| !url.is_empty())
        .map(str::to_string)
        .collect()
}

/// Parses `WARMER_CONCURRENCY`, defaulting to 4 in-flight fetches when
/// unset or invalid rather than failing closed -- unlike the credential
/// checks above, an out-of-range concurrency value has no security
/// consequence, only a performance one.
fn resolve_concurrency() -> usize {
    std::env::var("WARMER_CONCURRENCY")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(4)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    tracing::warn!(
        "lancache-warmer is a scaffold (issue #871): it does not yet resolve a Steam app ID to \
         real depot chunk URLs. See docs/design-steam-prefill.md for the current implementation \
         plan and open decisions."
    );

    let data_dir =
        std::env::var("WARMER_DATA_DIR").unwrap_or_else(|_| DEFAULT_DATA_DIR.to_string());
    let persistence = resolve_credential_persistence()?;
    let credential = resolve_steam_credential(persistence, &data_dir)?;

    tracing::info!(
        credential_persistence = ?persistence,
        credential_configured = credential.is_some(),
        "credential resolution complete (plaintext value itself is never logged)"
    );

    let urls = resolve_urls();
    if urls.is_empty() {
        tracing::warn!(
            "WARMER_URLS is empty; nothing to fetch. This scaffold has no real depot-manifest \
             resolution yet, so it can only warm a directly-configured URL list."
        );
        return Ok(());
    }

    let concurrency = resolve_concurrency();
    let counter = ByteCounter::new();
    spawn_throughput_logger(Arc::clone(&counter), Duration::from_secs(10));

    let client = reqwest::Client::new();
    let results = fetch_many_and_discard(client, urls, concurrency, Arc::clone(&counter)).await;

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
