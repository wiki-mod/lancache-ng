//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! At-rest storage for the operator-supplied Steam credential. Composes
//! two mechanisms already established elsewhere in this project rather
//! than inventing new ones (AG-CODE-011):
//!
//! - Argon2id, already a project dependency and used for one-way password
//!   verification in services/ui/src/nats_auth_callout.rs (issue #680),
//!   used here instead as a raw KDF (`hash_password_into`, not the
//!   PHC-string `hash_password` API) to derive a fixed-size symmetric
//!   key. The existing one-way use is not reusable as-is: a Steam
//!   credential (or a Steam-issued refresh token) must be recoverable in
//!   plaintext to actually authenticate to Steam, which a one-way hash
//!   structurally cannot provide.
//! - The create_new+0600 local-secret-file pattern from
//!   services/ui/src/main.rs's load_or_create_session_secret /
//!   load_or_create_secondary_registration_token, used here to persist
//!   this module's own master secret. That pattern alone stores plaintext
//!   on disk (protected only by file permissions), which the operator's
//!   Steam credential itself must never be.
//!
//! Neither existing mechanism alone covers this case; this module
//! combines them: the master secret (persisted via the 0600 pattern) is
//! never the credential itself -- it is fed through Argon2id, together
//! with a fresh random salt per credential, to derive a per-credential
//! encryption key. The credential is then sealed with that key via
//! XChaCha20-Poly1305 (an AEAD cipher, so tampering with the ciphertext
//! is detected, not just its confidentiality protected). At rest, only
//! salt + nonce + ciphertext are ever stored -- there is no code path
//! that writes the plaintext credential to disk, logs it, or returns it
//! from any function this crate exposes publicly except decrypt, whose
//! return value callers must treat as internal-use-only (see that
//! function's own doc comment).
//!
//! Persistence itself is optional and operator-controlled
//! (CredentialPersistence), never a project default: an operator who
//! does not want their Steam credential to survive a container restart
//! at all can choose None, in which case save_encrypted_credential /
//! load_encrypted_credential are simply never called.

use std::fs;
use std::fs::OpenOptions;
use std::io::Write;
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;

use argon2::Argon2;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};

/// What: byte length of the persisted master secret.
/// Why: matches load_or_create_session_secret's own 32-byte convention.
/// From: Issue #871
const MASTER_SECRET_LEN: usize = 32;
/// What: byte length of the per-credential Argon2id salt.
/// Why: 16 bytes is Argon2's own documented minimum recommended salt size.
/// From: Issue #871
const SALT_LEN: usize = 16;
/// What: byte length of the XChaCha20-Poly1305 nonce.
/// Why: the extended (192-bit) nonce, not the 96-bit variant -- this
///   nonce is randomly generated per encryption, not counter-based, and a
///   192-bit random nonce keeps collision probability negligible even
///   across many repeated re-encryptions (e.g. credential rotation),
///   which a 96-bit random nonce could not guarantee at the same scale
///   (maintainer decision).
const NONCE_LEN: usize = 24;
/// What: byte length of the derived symmetric key.
/// Why: fixed key size (X)ChaCha20-Poly1305 requires.
/// From: Issue #871
const KEY_LEN: usize = 32;

/// An encrypted-at-rest Steam credential. Deliberately has no method that
/// returns anything resembling the plaintext, and deliberately does not
/// derive Debug -- the only way to recover the original bytes is
/// decrypt below, called with the correct master secret.
#[derive(Clone, serde::Serialize, serde::Deserialize)]
pub struct EncryptedCredential {
    salt: Vec<u8>,
    nonce: Vec<u8>,
    ciphertext: Vec<u8>,
}

/// How the operator wants their Steam credential handled. This is the
/// end-user's own choice (per lancache-ng instance), never a fixed
/// project default -- see this module's own doc comment.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CredentialPersistence {
    /// Never written to disk; held in memory only for the current
    /// process's lifetime. The operator re-enters the credential on every
    /// restart.
    None,
    /// Encrypted at rest via encrypt/save_encrypted_credential below,
    /// surviving container restarts.
    Persistent,
}

/// Loads the persisted master secret, generating and persisting a new one
/// on first run. Byte-for-byte the same create_new+0600 pattern as
/// services/ui/src/main.rs's load_or_create_session_secret (see that
/// function's own comment for why create_new and 0o600 matter: atomic
/// exclusive creation avoids a lost-update race between two processes
/// starting concurrently, and 0o600 keeps the raw key readable only by
/// this container's own user).
pub fn load_or_create_master_secret(path: &str) -> anyhow::Result<[u8; MASTER_SECRET_LEN]> {
    match fs::read_to_string(path) {
        Ok(contents) => {
            let secret = hex::decode(contents.trim())?;
            if secret.len() != MASTER_SECRET_LEN {
                anyhow::bail!(
                    "Master secret at {path} must contain exactly {MASTER_SECRET_LEN} bytes encoded as hex"
                );
            }
            let mut bytes = [0u8; MASTER_SECRET_LEN];
            bytes.copy_from_slice(&secret);
            Ok(bytes)
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            let secret: [u8; MASTER_SECRET_LEN] = rand::random();
            let encoded = hex::encode(secret);
            let mut open_options = OpenOptions::new();
            open_options.create_new(true).write(true);
            #[cfg(unix)]
            open_options.mode(0o600);
            let mut file = open_options.open(path)?;
            file.write_all(encoded.as_bytes())?;
            file.sync_all()?;
            Ok(secret)
        }
        Err(err) => Err(err.into()),
    }
}

/// What: derives a symmetric key from the master secret plus a salt.
/// Why: Argon2id used as a raw KDF, not its one-way PHC-string form.
/// From: Issue #871
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

/// Encrypts plaintext (the operator-supplied Steam credential) so it is
/// never stored or transmitted in cleartext. A fresh random salt (for the
/// KDF) and a fresh random nonce are generated per call -- see this
/// module's NONCE_LEN doc comment for why the nonce is the extended
/// (192-bit) variant.
pub fn encrypt(
    master_secret: &[u8; MASTER_SECRET_LEN],
    plaintext: &[u8],
) -> anyhow::Result<EncryptedCredential> {
    let salt: [u8; SALT_LEN] = rand::random();
    let key = derive_key(master_secret, &salt)?;
    let cipher = XChaCha20Poly1305::new((&key).into());
    let nonce_bytes: [u8; NONCE_LEN] = rand::random();
    let nonce = XNonce::from_slice(&nonce_bytes);
    let ciphertext = cipher
        .encrypt(nonce, plaintext)
        .map_err(|e| anyhow::anyhow!("credential encryption failed: {e}"))?;
    Ok(EncryptedCredential {
        salt: salt.to_vec(),
        nonce: nonce_bytes.to_vec(),
        ciphertext,
    })
}

/// Decrypts a previously-encrypted credential. Returns the plaintext
/// only in memory, for immediate internal use (e.g. handing it to the
/// eventual Steam login flow) -- callers must never log, display, return
/// via any Admin-UI/API response, or otherwise let this value leave the
/// process. This mirrors how UI_AUTH_PASSWORD is compared but never
/// echoed back (services/ui/src/main.rs) -- the same write-only-from-an-
/// external-viewer's-perspective property, achieved here via encryption
/// rather than a one-way comparison because this value must be recovered,
/// not merely verified.
pub fn decrypt(
    master_secret: &[u8; MASTER_SECRET_LEN],
    stored: &EncryptedCredential,
) -> anyhow::Result<Vec<u8>> {
    let key = derive_key(master_secret, &stored.salt)?;
    let cipher = XChaCha20Poly1305::new((&key).into());
    let nonce = XNonce::from_slice(&stored.nonce);
    cipher
        .decrypt(nonce, stored.ciphertext.as_ref())
        .map_err(|e| {
            anyhow::anyhow!(
                "credential decryption failed (wrong master secret, or data corrupted): {e}"
            )
        })
}

/// Persists an already-encrypted credential to disk (0600, matching
/// load_or_create_master_secret's own permission choice). Only called
/// when the operator selected CredentialPersistence::Persistent --
/// None mode never calls this at all, so nothing about the credential
/// ever touches disk in that mode.
pub fn save_encrypted_credential(
    path: &str,
    credential: &EncryptedCredential,
) -> anyhow::Result<()> {
    let json = serde_json::to_string(credential)?;
    // create_new is deliberately NOT used here (unlike the master-secret
    // file above): a credential can legitimately be replaced/rotated by
    // the operator, so an existing file must be overwritable rather than
    // treated as an already-finalized value.
    let mut open_options = OpenOptions::new();
    open_options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    open_options.mode(0o600);
    let mut file = open_options.open(path)?;
    file.write_all(json.as_bytes())?;
    file.sync_all()?;
    Ok(())
}

/// Loads a previously-persisted encrypted credential, if any. Returns
/// Ok(None) (not an error) when the operator has not persisted a
/// credential -- the normal state for CredentialPersistence::None or a
/// fresh install.
pub fn load_encrypted_credential(path: &str) -> anyhow::Result<Option<EncryptedCredential>> {
    match fs::read_to_string(path) {
        Ok(contents) => Ok(Some(serde_json::from_str(&contents)?)),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(err.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Verifies the core round trip: encrypting then decrypting with the
    // same master secret returns the original plaintext unchanged.
    #[test]
    fn encrypt_then_decrypt_round_trips() {
        let master_secret: [u8; MASTER_SECRET_LEN] = rand::random();
        let plaintext = b"a-steam-password-or-refresh-token";
        let encrypted = encrypt(&master_secret, plaintext).expect("encryption should succeed");
        let decrypted = decrypt(&master_secret, &encrypted).expect("decryption should succeed");
        assert_eq!(decrypted, plaintext);
    }

    // A wrong master secret must fail to decrypt, never silently return
    // garbage or, worse, a plausible-looking wrong plaintext -- AEAD's
    // authentication tag is what this test actually exercises.
    #[test]
    fn decrypt_fails_with_wrong_master_secret() {
        let master_secret: [u8; MASTER_SECRET_LEN] = rand::random();
        let wrong_secret: [u8; MASTER_SECRET_LEN] = rand::random();
        let plaintext = b"another-secret";
        let encrypted = encrypt(&master_secret, plaintext).expect("encryption should succeed");
        let result = decrypt(&wrong_secret, &encrypted);
        assert!(
            result.is_err(),
            "decryption with the wrong master secret must fail, not silently succeed"
        );
    }

    // Two encryptions of the identical plaintext must produce different
    // ciphertext/nonce/salt -- otherwise an observer could tell two
    // stored credentials are identical without ever decrypting either.
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

    // Mirrors services/ui/src/main.rs's own load_or_create_session_secret
    // test: first call creates a new secret, second call reloads the
    // identical value rather than generating a fresh one.
    #[test]
    fn load_or_create_master_secret_persists_and_reloads_same_value() {
        let dir = std::env::temp_dir().join(format!(
            "lancache-warmer-master-secret-test-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).expect("temp dir should be creatable");
        let path = dir.join("master.secret");
        let path_str = path.to_str().expect("temp path should be valid UTF-8");

        let first =
            load_or_create_master_secret(path_str).expect("first call should create a new secret");
        let second = load_or_create_master_secret(path_str)
            .expect("second call should reload the same secret");
        assert_eq!(first, second);

        std::fs::remove_dir_all(&dir).ok();
    }

    // Verifies the on-disk persistence path end-to-end: save, reload from
    // a fresh read, then decrypt the reloaded value successfully.
    #[test]
    fn save_and_load_encrypted_credential_round_trips() {
        let dir = std::env::temp_dir().join(format!(
            "lancache-warmer-credential-test-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).expect("temp dir should be creatable");
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

        std::fs::remove_dir_all(&dir).ok();
    }

    // A missing credential file is the normal "operator hasn't set one
    // yet" state, not an error -- this test guards against that being
    // accidentally tightened into a hard failure later.
    #[test]
    fn load_encrypted_credential_returns_none_when_absent() {
        let path = std::env::temp_dir().join(format!(
            "lancache-warmer-absent-credential-{}.json",
            std::process::id()
        ));
        let result =
            load_encrypted_credential(path.to_str().expect("temp path should be valid UTF-8"))
                .expect("a missing file is not an error");
        assert!(result.is_none());
    }
}
