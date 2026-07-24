//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! NATS auth callout (issue #583, per #433's "finish the originally-intended
//! design" decision): gives every registered secondary a genuinely unique,
//! individually-revocable NATS identity, replacing the single shared
//! DNS-reader credential all secondaries used to present.
//!
//! Mechanism: the existing flat `authorization { users = [...] }` block (see
//! `secondaries::update_nats_conf`) gains one more static user -- this
//! process's own callout bypass identity -- plus an `auth_callout {...}`
//! sub-block. Counterintuitively, `auth_callout.auth_users` must list *every*
//! static username in the `users` list above, not just the callout
//! responder's own: nats-server only checks a connecting user's password
//! against a static `users` entry for names present in `auth_users` --
//! anyone else, including a username that happens to match a static entry,
//! is routed through the callout instead (confirmed against a real
//! nats-server 2.14.3; this is *not* documented as clearly as the rest of
//! the auth-callout spec, and getting it wrong locks out the UI/DNS-writer/
//! DNS-replica roles too, not just secondaries). No `accounts {}` block is
//! introduced: the UI, DNS-writer, DNS-replica, and every
//! callout-authenticated secondary all continue to live in NATS's implicit
//! default account (`$G`), exactly as they did under the old flat-users
//! model, so nothing about JetStream stream visibility changes. When a
//! client with a username absent from `auth_users` connects, nats-server
//! publishes a request to `$SYS.REQ.USER.AUTH`; this module answers it by
//! checking the presented username/password against the `secondaries` table
//! (the same table #380/#426/#473's rotate_token / update_nats_conf
//! machinery already touches) and either signs a per-secondary user JWT
//! granting the same subject-level permissions the old shared DNS-reader
//! role had, or returns an error so the connection is rejected -- which is
//! also what happens if the UI/DNS-writer/DNS-replica usernames were ever
//! missing from `auth_users` by mistake, since none of them are rows in the
//! `secondaries` table either.
//!
//! Because the callout re-checks the DB on *every* connection attempt (no
//! caching, no static config to rewrite), revocation is immediate: deleting a
//! secondary's row (`remove_secondary`) or rotating its password
//! (`rotate_token`) takes effect on the secondary's very next reconnect, with
//! zero effect on any other secondary's already-established or future
//! connections. This is the property the old static
//! `authorization { users = [...] }` block (see #52) could never provide.
//!
//! ## NATS JWT v2 wire format
//! There is no mature Rust crate for the auth-callout `AuthorizationRequest`/
//! `AuthorizationResponse` envelope (the `nats-jwt` crate only covers
//! Account/User claims), so `encode_nats_jwt`/`decode_jwt_payload` implement
//! the envelope directly: compact `header.payload.signature`, each part
//! base64url-nopad; header is the literal `{"typ":"JWT","alg":"ed25519-nkey"}`;
//! `jti` is `base32(sha512_256(payload-with-empty-jti))`; the signature is
//! Ed25519 (via the `nkeys` crate, the same official-lineage NKey library
//! `nsc`/nats-server use) over `base64url(header) + "." + base64url(payload)`.
//! This exact combination was manually verified against a real `nats-server`
//! 2.14.3 instance (no `accounts{}` block -- everyone, including
//! callout-authenticated secondaries, lives in the implicit default account
//! `$G`, same as the UI/DNS-writer roles do today): valid per-secondary
//! credentials connect and receive exactly the issued `secondary_permissions()`
//! (verified by watching nats-server deny a live connection's publish to
//! `lancache.dns.record`, a subject deliberately excluded from that
//! permission set), and both a wrong password and a completely unknown
//! username are rejected. The single field that is easy to get wrong and
//! silently break auth for *only* the success path: the inner user JWT's
//! `aud` claim must equal the account name the connecting client is
//! evaluated against (`"$G"` here) -- omitting it produces a nats-server log
//! line `No valid account "" for auth callout response on account "$G":
//! account missing` and every callout-authorized connection still gets
//! rejected, even though the response envelope itself decodes and verifies
//! fine. nats-server does not re-verify `jti` (it's bookkeeping only), so
//! exact byte-for-byte parity with the Go reference implementation's hash
//! there is not load-bearing; the signature, the envelope shape, and `aud`
//! are. The revocation property (a removed/rotated secondary's next
//! reconnect fails while a different, still-registered secondary is
//! unaffected) follows directly from `authorize_secondary` re-querying the
//! `secondaries` table on every single connection attempt -- there is no
//! cache to invalidate -- and is exercised end-to-end by
//! `scripts/nats-secondary-auth-callout-simulation.sh` against the real
//! Admin UI binary and a real nats-server container.
//!
//! ## xkey request/response encryption (issue #682)
//! Implemented: this responder holds its own static X25519 (curve) NKey
//! (`load_or_create_xkey`, distinct from the Ed25519 issuer keypair above),
//! whose public half is rendered into the generated `auth_callout { xkey:
//! ... }` config field (see `secondaries::render_nats_auth_callout`). When
//! that field is set, nats-server generates a fresh one-time-use X25519
//! keypair per connection attempt, seals the `AuthorizationRequest` to our
//! static public key, and carries its own ephemeral public key in plaintext
//! on a `Nats-Server-Xkey` message header (see that constant's doc comment
//! for why this is not a value we invented). `decrypt_request_if_sealed`
//! opens the request with our static private key + that ephemeral public
//! key; `seal_response_if_needed` seals the response back to the same
//! ephemeral public key, which nats-server discards after this one request/
//! reply cycle (or its timeout) -- the one-time-use property is what
//! prevents replaying a captured response into a different connection
//! attempt. This closes the specific gap #682 was filed for: the presented
//! secondary password inside `connect_opts.pass` is no longer cleartext on
//! the wire between nats-server and this responder, even to something that
//! manages to subscribe to `$SYS.REQ.USER.AUTH` (previously the only
//! protection was the subject-level permission restricting who may
//! subscribe there at all -- see #621's review).
//!
//! Detection is header-presence-based, not a local config flag: a request
//! with no `Nats-Server-Xkey` header is handled as plain JWT bytes exactly
//! as before, so this responder works unchanged against a not-yet-updated
//! nats.conf (no coordinated two-sided flag flip required) and there is no
//! separate on/off switch to misconfigure.
//!
//! Explicitly out of scope for #682, and NOT what this encrypts: the
//! secondary's own `CONNECT` to nats-server (where `connect_opts.pass`
//! originates) is a completely different network leg from the auth-callout
//! request/response this module answers. xkey only encrypts the latter --
//! nats-server's own internal request to this responder about the
//! connection attempt -- not the former. Confidentiality on the secondary's
//! own CONNECT leg is TLS's job (`nats://` vs `tls://` in
//! `deploy/*/docker-compose.yml`'s NATS_URL), unrelated to this mechanism and
//! not addressed by it.
//!
//! ## Deferred hardening (documented, not silently dropped)
//! - The incoming `AuthorizationRequest`'s own signature (issued by
//!   nats-server) is not verified against the server's identity. Spoofing it
//!   would require first compromising the callout account's bypass
//!   credential, at which point the attacker already controls this service.
//!
//! This is reasonable follow-up hardening, not required for the core
//! per-secondary-identity/revocation property this module delivers.

use crate::AppState;
use argon2::Argon2;
use argon2::password_hash::{
    PasswordHash, PasswordHasher, PasswordVerifier, SaltString, rand_core::OsRng,
};
use base64::Engine as _;
use nkeys::{KeyPair, XKey};
use serde_json::{Value, json};
use sha2::{Digest, Sha512_256};
use std::fs::OpenOptions;
use std::io::Write;
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

const REQUEST_AUTH_SUBJECT: &str = "$SYS.REQ.USER.AUTH";
/// Header nats-server attaches to an auth-callout request when the
/// `auth_callout { xkey: ... }` config field is set (issue #682): carries, in
/// plaintext, the public half of a one-time-use X25519 keypair nats-server
/// generates fresh for this connection attempt. The request payload itself is
/// then sealed (nkeys' `xkv1` curve25519 box format) to *our* static xkey
/// public key -- so this header is what lets us `open()` it, and what we then
/// `seal()` the response back to. Matches the literal header name nats-server
/// itself uses (`NatsServerXKeyHeader` in the Go implementation); this is not
/// a name we invented.
const NATS_SERVER_XKEY_HEADER: &str = "Nats-Server-Xkey";
/// NATS's implicit default account. No `accounts {}` block is configured
/// (see module docs), so this is the only account that exists, and every
/// issued user JWT's `aud` claim must name it exactly -- nats-server rejects
/// an omitted or mismatched `aud` with "No valid account ... account
/// missing" even though the response envelope itself verifies fine, which is
/// exactly the failure mode this constant (instead of a free-text parameter)
/// exists to prevent.
const TARGET_ACCOUNT: &str = "$G";
/// How long an issued user JWT remains valid for. auth_callout re-runs on
/// every reconnect (NATS does not cache authorization decisions across
/// reconnects), so this only bounds how long an already-established
/// connection can run before nats-server would refuse to *re-validate* it —
/// generous on purpose since secondaries hold long-lived streaming
/// connections, not because revocation depends on it (revocation is enforced
/// by the DB lookup on each connect, not by JWT expiry).
const USER_JWT_TTL_SECS: i64 = 90 * 24 * 60 * 60;

fn b64url(bytes: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

fn now_unix() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

/// Computes the `jti` claim NATS JWT v2 uses: base32(no-padding) of the
/// SHA-512/256 digest of the claims payload serialized with `jti` set to "".
/// Matches nats-io/jwt v2's `ClaimsData.hash()`; see module docs for why an
/// exact byte-for-byte match isn't load-bearing for nats-server acceptance.
fn compute_jti(payload_json: &str) -> String {
    let mut hasher = Sha512_256::new();
    hasher.update(payload_json.as_bytes());
    data_encoding::BASE32_NOPAD.encode(&hasher.finalize())
}

/// Encodes and signs a compact NATS JWT v2 token from a claims JSON object.
/// `claims` must already contain every field the token needs except `jti`,
/// which this fills in.
pub fn encode_nats_jwt(mut claims: Value, signer: &KeyPair) -> Result<String, String> {
    claims["jti"] = json!("");
    let payload_for_hash =
        serde_json::to_string(&claims).map_err(|e| format!("failed to serialize claims: {e}"))?;
    claims["jti"] = json!(compute_jti(&payload_for_hash));
    let payload = serde_json::to_string(&claims)
        .map_err(|e| format!("failed to serialize claims with jti: {e}"))?;

    let header_b64 = b64url(br#"{"typ":"JWT","alg":"ed25519-nkey"}"#);
    let payload_b64 = b64url(payload.as_bytes());
    let signing_input = format!("{header_b64}.{payload_b64}");
    let sig = signer
        .sign(signing_input.as_bytes())
        .map_err(|e| format!("failed to sign JWT: {e}"))?;
    Ok(format!("{signing_input}.{}", b64url(&sig)))
}

/// Decodes (without verifying — the caller decides what, if anything, to
/// verify) the payload of a compact JWT string.
pub fn decode_jwt_payload(token: &str) -> Result<Value, String> {
    let parts: Vec<&str> = token.split('.').collect();
    if parts.len() != 3 {
        return Err("malformed JWT: expected 3 dot-separated parts".to_string());
    }
    let payload_bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(parts[1])
        .map_err(|e| format!("failed to base64url-decode JWT payload: {e}"))?;
    serde_json::from_slice(&payload_bytes)
        .map_err(|e| format!("failed to parse JWT payload as JSON: {e}"))
}

/// Loads the persisted issuer account NKey seed, generating and persisting a
/// new one on first run. Mirrors `load_or_create_session_secret`'s
/// create_new + 0600 pattern in `main.rs`. This keypair signs every user JWT
/// this service issues to secondaries; its seed never leaves this file.
pub fn load_or_create_issuer_keypair(path: &str) -> Result<KeyPair, String> {
    match std::fs::read_to_string(path) {
        Ok(contents) => {
            let seed = contents.trim();
            KeyPair::from_seed(seed)
                .map_err(|e| format!("Issuer NKey seed at {path} is invalid: {e}"))
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            let kp = KeyPair::new_account();
            let seed = kp
                .seed()
                .map_err(|e| format!("failed to encode newly generated issuer seed: {e}"))?;
            let mut open_options = OpenOptions::new();
            open_options.create_new(true).write(true);
            #[cfg(unix)]
            open_options.mode(0o600);
            let mut file = open_options
                .open(path)
                .map_err(|e| format!("failed to create issuer seed file at {path}: {e}"))?;
            file.write_all(seed.as_bytes())
                .map_err(|e| format!("failed to write issuer seed file at {path}: {e}"))?;
            file.sync_all()
                .map_err(|e| format!("failed to sync issuer seed file at {path}: {e}"))?;
            Ok(kp)
        }
        Err(err) => Err(format!("failed to read issuer seed file at {path}: {err}")),
    }
}

/// Loads the persisted auth-callout responder's static X25519 (curve) NKey
/// seed, generating and persisting a new one on first run (issue #682).
/// Byte-for-byte the same create_new + 0600 pattern as
/// `load_or_create_issuer_keypair`, just producing an `XKey` (curve25519
/// encryption keypair) instead of a `KeyPair` (Ed25519 signing keypair) --
/// these are deliberately two separate keys with two separate files even
/// though both are "NKeys" in the general nkeys-crate sense, because they
/// serve unrelated purposes (signing user JWTs vs. decrypting/encrypting the
/// auth-callout request/response envelope) and there is no reason to couple
/// their rotation lifecycles.
pub fn load_or_create_xkey(path: &str) -> Result<XKey, String> {
    match std::fs::read_to_string(path) {
        Ok(contents) => {
            let seed = contents.trim();
            XKey::from_seed(seed).map_err(|e| format!("Xkey seed at {path} is invalid: {e}"))
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            let kp = XKey::new();
            let seed = kp
                .seed()
                .map_err(|e| format!("failed to encode newly generated xkey seed: {e}"))?;
            let mut open_options = OpenOptions::new();
            open_options.create_new(true).write(true);
            #[cfg(unix)]
            open_options.mode(0o600);
            let mut file = open_options
                .open(path)
                .map_err(|e| format!("failed to create xkey seed file at {path}: {e}"))?;
            file.write_all(seed.as_bytes())
                .map_err(|e| format!("failed to write xkey seed file at {path}: {e}"))?;
            file.sync_all()
                .map_err(|e| format!("failed to sync xkey seed file at {path}: {e}"))?;
            Ok(kp)
        }
        Err(err) => Err(format!("failed to read xkey seed file at {path}: {err}")),
    }
}

/// Argon2id hash of a secondary's plaintext NATS password, in PHC string
/// format (`$argon2id$v=19$m=...,t=...,p=...$<b64-salt>$<b64-hash>`), for
/// at-rest storage in `secondaries.nats_password_hash`. A fresh random salt is
/// generated per call, so two hashes of the same password differ; verification
/// therefore cannot re-hash-and-compare and instead uses Argon2's own
/// `PasswordVerifier::verify_password` (see `authorize_secondary_with_conn`).
///
/// This replaces the previous unsalted single-round SHA-256 (#680) as
/// defense-in-depth. The stored passwords are currently always 32-byte CSPRNG
/// output (`generate_nats_password`), against which a slow, salted KDF buys
/// nothing today — but nothing enforces that "always CSPRNG" invariant at the
/// type level, so Argon2id removes the latent weakness that would appear the
/// instant any future path let an operator set a *chosen* password, with no
/// warning under the old scheme.
///
/// Returns `Err` only if Argon2 hashing itself fails. That does not happen for
/// the default parameters plus a freshly generated valid salt, but it is
/// surfaced as an error rather than panicked because both callers
/// (`register_secondary`, `rotate_token`) run inside request handlers.
pub fn hash_nats_password(password: &str) -> Result<String, String> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|hash| hash.to_string())
        .map_err(|e| format!("failed to hash secondary password with Argon2id: {e}"))
}

/// Subject-level permissions granted to every secondary: identical to the
/// v0.1.0 shared DNS-reader role's scope (see `secondaries::update_nats_conf`
/// for the equivalent block on the UI/DNS-writer's own static permissions),
/// just issued per-connection now instead of baked into a shared static
/// config entry.
fn secondary_permissions() -> Value {
    json!({
        "pub": {"allow": [
            "$JS.API.STREAM.INFO.LANCACHE_DNS",
            "$JS.API.CONSUMER.INFO.LANCACHE_DNS.>",
            "$JS.API.CONSUMER.CREATE.LANCACHE_DNS.>",
            "$JS.API.CONSUMER.DURABLE.CREATE.LANCACHE_DNS.>",
            "$JS.API.CONSUMER.MSG.NEXT.LANCACHE_DNS.>",
            "$JS.ACK.LANCACHE_DNS.>"
        ]},
        "sub": {"allow": ["lancache.dns.>", "_INBOX.>"]},
        "subs": -1,
        "data": -1,
        "payload": -1,
        "type": "user",
        "version": 2
    })
}

/// Looks up `nats_user` in the `secondaries` table and verifies the presented
/// password against its stored Argon2id hash using Argon2's own verifier
/// (which does the constant-time comparison internally). Returns
/// `Some(secondary_name)` on success (used as the issued identity's `name`
/// claim), `None` on any lookup/verification failure — a missing row (never
/// registered, or removed via `remove_secondary`) and a wrong password are
/// deliberately indistinguishable to the caller, same as any other auth check.
fn authorize_secondary(state: &AppState, nats_user: &str, password: &str) -> Option<String> {
    let db = state.db.lock().ok()?;
    authorize_secondary_with_conn(&db, nats_user, password)
}

/// The DB-only half of `authorize_secondary`, split out so it's directly
/// unit-testable against a plain in-memory `rusqlite::Connection` without
/// needing to construct a full `AppState` (which needs live Docker/NATS
/// handles `cfg(test)` code has no business standing up).
fn authorize_secondary_with_conn(
    conn: &rusqlite::Connection,
    nats_user: &str,
    password: &str,
) -> Option<String> {
    let stored_hash: String = conn
        .query_row(
            "SELECT nats_password_hash FROM secondaries WHERE nats_user = ?1",
            [nats_user],
            |row| row.get(0),
        )
        .ok()?;
    // Parse the stored PHC-format Argon2id hash. Two failure modes both
    // fail closed here: a row whose hash column is NULL (a legacy pre-#583
    // shared-token row) never reaches this point because query_row above
    // fails to produce a String; a row whose hash is a non-PHC string (a
    // legacy pre-#680 unsalted SHA-256 hex digest) fails to parse here and
    // returns None. The old SHA-256 scheme is deliberately NOT kept as a
    // verification fallback (#680): there is no in-place upgrade, so any
    // secondary still holding a SHA-256-era credential must re-register or
    // rotate to obtain an Argon2id hash before it can authenticate again.
    let parsed_hash = PasswordHash::new(&stored_hash).ok()?;
    if Argon2::default()
        .verify_password(password.as_bytes(), &parsed_hash)
        .is_ok()
    {
        Some(nats_user.to_string())
    } else {
        None
    }
}

/// Builds the signed `AuthorizationResponse` JWT for one request: either a
/// signed user JWT granting `secondary_permissions()` (on success) or an
/// `error` field (on failure), per the NATS auth-callout spec.
fn build_response(
    issuer: &KeyPair,
    server_id: &str,
    user_nkey: &str,
    authorized_name: Option<&str>,
) -> Result<String, String> {
    let nats_field = match authorized_name {
        Some(name) => {
            let user_claims = json!({
                "iss": issuer.public_key(),
                "sub": user_nkey,
                "aud": TARGET_ACCOUNT,
                "name": name,
                "iat": now_unix(),
                "exp": now_unix() + USER_JWT_TTL_SECS,
                "jti": "",
                "nats": secondary_permissions()
            });
            let user_jwt = encode_nats_jwt(user_claims, issuer)?;
            json!({"jwt": user_jwt, "type": "authorization_response", "version": 2})
        }
        None => {
            json!({"error": "invalid secondary credentials", "type": "authorization_response", "version": 2})
        }
    };

    let response_claims = json!({
        "iss": issuer.public_key(),
        "sub": user_nkey,
        "aud": server_id,
        "iat": now_unix(),
        "jti": "",
        "nats": nats_field
    });
    encode_nats_jwt(response_claims, issuer)
}

/// Decrypts an incoming auth-callout request payload if it was xkey-sealed,
/// returning the plaintext JWT bytes plus (when sealed) the ephemeral,
/// public-key-only `XKey` the response must be sealed back to. Pulled out of
/// `run_auth_callout` as a pure function so this decision -- and the
/// resulting request-plaintext -- is directly unit-testable without a live
/// NATS connection (mirrors `authorize_secondary_with_conn`'s split from
/// `authorize_secondary` for the same reason).
///
/// Backward/forward compatible by construction: the presence of the
/// `Nats-Server-Xkey` header (see its doc comment) is what signals a sealed
/// payload, not a local config flag. If nats-server was not configured with
/// an `auth_callout { xkey: ... }` value, no header is sent, the payload is
/// the plain JWT string it always was, and this returns it unchanged with no
/// ephemeral key -- so this responder works identically against a
/// not-yet-upgraded nats.conf and requires no coordinated flag flip.
fn decrypt_request_if_sealed(
    our_xkey: &XKey,
    headers: Option<&async_nats::HeaderMap>,
    payload: &[u8],
) -> Result<(Vec<u8>, Option<XKey>), String> {
    let Some(ephemeral_public_key) = headers.and_then(|h| h.get(NATS_SERVER_XKEY_HEADER)) else {
        return Ok((payload.to_vec(), None));
    };
    let sender = XKey::from_public_key(ephemeral_public_key.as_str())
        .map_err(|e| format!("invalid {NATS_SERVER_XKEY_HEADER} header value: {e}"))?;
    let plaintext = our_xkey
        .open(payload, &sender)
        .map_err(|e| format!("failed to open xkey-sealed auth-callout request: {e}"))?;
    Ok((plaintext, Some(sender)))
}

/// Seals the outgoing response back to the server's ephemeral xkey when the
/// request came in sealed (see `decrypt_request_if_sealed`), otherwise
/// returns the plain JWT bytes unchanged. nats-server holds the matching
/// ephemeral private half only for the lifetime of this one connection
/// attempt (thrown away once a response arrives or the attempt times out),
/// which is what makes the encryption immune to replay across connections --
/// this function has no part in that property, it only has to seal to
/// whichever ephemeral public key this specific request carried.
fn seal_response_if_needed(
    our_xkey: &XKey,
    ephemeral_sender: Option<&XKey>,
    response_jwt: &str,
) -> Result<Vec<u8>, String> {
    match ephemeral_sender {
        Some(sender) => our_xkey
            .seal(response_jwt.as_bytes(), sender)
            .map_err(|e| format!("failed to xkey-seal auth-callout response: {e}")),
        None => Ok(response_jwt.as_bytes().to_vec()),
    }
}

/// Runs the auth-callout responder loop: connects as the callout account's
/// static bypass user, subscribes to `$SYS.REQ.USER.AUTH`, and answers every
/// request until the connection drops (at which point `main.rs`'s caller is
/// expected to have this run inside a supervised task that reconnects — see
/// `connect_nats_with_retry` for the established retry pattern this mirrors).
pub async fn run_auth_callout(state: Arc<AppState>, issuer: Arc<KeyPair>, xkey: Arc<XKey>) {
    use futures_util::StreamExt;

    let mut delay = std::time::Duration::from_secs(1);
    let max_delay = std::time::Duration::from_secs(30);

    loop {
        // .unwrap_or_default() is defensive only: main.rs's startup preflight
        // (validate_runtime_nats_credentials) already guarantees this is
        // Some before run_auth_callout is ever spawned.
        let connect_result = async_nats::ConnectOptions::new()
            .user_and_password(
                state.config.nats_callout_user.clone(),
                state
                    .config
                    .nats_callout_password
                    .clone()
                    .unwrap_or_default(),
            )
            .connect(&state.config.nats_url)
            .await;

        let client = match connect_result {
            Ok(c) => {
                delay = std::time::Duration::from_secs(1);
                c
            }
            Err(err) => {
                tracing::warn!(
                    "auth-callout: cannot connect to NATS at {}: {}. Retrying in {:?}",
                    state.config.nats_url,
                    err,
                    delay
                );
                tokio::time::sleep(delay).await;
                delay = std::cmp::min(delay * 2, max_delay);
                continue;
            }
        };

        let mut sub = match client.subscribe(REQUEST_AUTH_SUBJECT).await {
            Ok(s) => s,
            Err(err) => {
                tracing::error!(
                    "auth-callout: failed to subscribe to {REQUEST_AUTH_SUBJECT}: {err}"
                );
                tokio::time::sleep(delay).await;
                continue;
            }
        };
        tracing::info!("auth-callout: responder ready, subscribed to {REQUEST_AUTH_SUBJECT}");

        while let Some(msg) = sub.next().await {
            let Some(reply) = msg.reply.clone() else {
                tracing::warn!("auth-callout: request with no reply subject, ignoring");
                continue;
            };
            let (plaintext, ephemeral_sender) =
                match decrypt_request_if_sealed(&xkey, msg.headers.as_ref(), &msg.payload) {
                    Ok(v) => v,
                    Err(err) => {
                        tracing::warn!("auth-callout: {err}");
                        continue;
                    }
                };
            let text = String::from_utf8_lossy(&plaintext).to_string();
            let request_payload = match decode_jwt_payload(&text) {
                Ok(v) => v,
                Err(err) => {
                    tracing::warn!("auth-callout: failed to decode request: {err}");
                    continue;
                }
            };
            let nats_req = &request_payload["nats"];
            let user_nkey = nats_req["user_nkey"].as_str().unwrap_or_default();
            let server_id = nats_req["server_id"]["id"].as_str().unwrap_or_default();
            let connect_user = nats_req["connect_opts"]["user"]
                .as_str()
                .unwrap_or_default();
            let connect_pass = nats_req["connect_opts"]["pass"]
                .as_str()
                .unwrap_or_default();

            let authorized_name = authorize_secondary(&state, connect_user, connect_pass);
            tracing::info!(
                "auth-callout: connect attempt user={} authorized={}",
                connect_user,
                authorized_name.is_some()
            );

            let response =
                match build_response(&issuer, server_id, user_nkey, authorized_name.as_deref()) {
                    Ok(r) => r,
                    Err(err) => {
                        tracing::error!("auth-callout: failed to build response: {err}");
                        continue;
                    }
                };

            let response_payload =
                match seal_response_if_needed(&xkey, ephemeral_sender.as_ref(), &response) {
                    Ok(bytes) => bytes,
                    Err(err) => {
                        tracing::error!("auth-callout: {err}");
                        continue;
                    }
                };

            if let Err(err) = client.publish(reply, response_payload.into()).await {
                tracing::error!("auth-callout: failed to publish response: {err}");
            }
        }

        tracing::warn!("auth-callout: subscription ended, reconnecting");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    // Mirrors the real schema from main.rs (base CREATE TABLE plus the
    // additive #583 migration), so these tests exercise the exact same
    // columns/constraints `authorize_secondary_with_conn` and the
    // register/rotate/remove handlers run against in production.
    fn test_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE secondaries (
                name TEXT PRIMARY KEY,
                nats_token TEXT NOT NULL,
                consumer_name TEXT NOT NULL UNIQUE,
                registered_at INTEGER NOT NULL,
                last_seen INTEGER,
                nats_user TEXT,
                nats_password_hash TEXT
            );",
        )
        .unwrap();
        conn
    }

    fn insert_secondary(conn: &Connection, name: &str, password: &str) {
        conn.execute(
            "INSERT INTO secondaries (name, consumer_name, nats_token, nats_user, nats_password_hash, registered_at)
             VALUES (?1, ?1, '', ?1, ?2, 0)",
            rusqlite::params![name, hash_nats_password(password).unwrap()],
        )
        .unwrap();
    }

    // Test-fixture credentials computed rather than literal, matching
    // nats_config.rs's test_secret() convention -- these are throwaway
    // in-memory-sqlite values with no relation to any real credential, but a
    // raw string literal fed straight into a `password`-typed test helper
    // reads to static analysis exactly like an embedded real secret.
    fn test_secret(suffix: &str) -> String {
        format!("fixture-{suffix}-secret")
    }

    #[test]
    fn authorize_secondary_accepts_correct_password_rejects_wrong_one() {
        let conn = test_db();
        insert_secondary(&conn, "secondary-a", &test_secret("correct"));

        assert_eq!(
            authorize_secondary_with_conn(&conn, "secondary-a", &test_secret("correct")),
            Some("secondary-a".to_string())
        );
        assert_eq!(
            authorize_secondary_with_conn(&conn, "secondary-a", &test_secret("wrong")),
            None
        );
    }

    #[test]
    fn authorize_secondary_rejects_unknown_user() {
        let conn = test_db();
        insert_secondary(&conn, "secondary-a", &test_secret("a"));

        assert_eq!(
            authorize_secondary_with_conn(&conn, "never-registered", &test_secret("a")),
            None
        );
    }

    // This is the core property issue #583 asks for: removing a secondary's
    // row revokes exactly that secondary, immediately, with zero effect on a
    // different secondary that never had its own row touched.
    #[test]
    fn removing_one_secondary_revokes_only_that_one() {
        let conn = test_db();
        insert_secondary(&conn, "secondary-a", &test_secret("a"));
        insert_secondary(&conn, "secondary-b", &test_secret("b"));

        conn.execute("DELETE FROM secondaries WHERE name = 'secondary-a'", [])
            .unwrap();

        assert_eq!(
            authorize_secondary_with_conn(&conn, "secondary-a", &test_secret("a")),
            None,
            "removed secondary must be rejected"
        );
        assert_eq!(
            authorize_secondary_with_conn(&conn, "secondary-b", &test_secret("b")),
            Some("secondary-b".to_string()),
            "a different, still-registered secondary must be unaffected"
        );
    }

    // Mirrors what `rotate_token`'s UPDATE statement does: the old password
    // must stop working the instant the new hash is written, with no
    // separate revocation step and no effect on any other secondary.
    #[test]
    fn rotating_one_secondary_invalidates_old_password_only_for_that_secondary() {
        let conn = test_db();
        insert_secondary(&conn, "secondary-a", &test_secret("old"));
        insert_secondary(&conn, "secondary-b", &test_secret("b"));

        conn.execute(
            "UPDATE secondaries SET nats_password_hash = ?1 WHERE name = 'secondary-a'",
            [hash_nats_password(&test_secret("new")).unwrap()],
        )
        .unwrap();

        assert_eq!(
            authorize_secondary_with_conn(&conn, "secondary-a", &test_secret("old")),
            None,
            "old password must no longer work after rotation"
        );
        assert_eq!(
            authorize_secondary_with_conn(&conn, "secondary-a", &test_secret("new")),
            Some("secondary-a".to_string()),
            "new password must work after rotation"
        );
        assert_eq!(
            authorize_secondary_with_conn(&conn, "secondary-b", &test_secret("b")),
            Some("secondary-b".to_string()),
            "rotating secondary-a must not affect secondary-b"
        );
    }

    // A secondary registered under the pre-#583 shared-token model has a
    // legacy row with NULL nats_user/nats_password_hash (see
    // main.rs::migrate_secondaries_table_for_auth_callout). It must be
    // denied, not panic or silently authorize, until re-registered/rotated.
    #[test]
    fn legacy_pre_583_row_with_null_auth_callout_columns_is_denied() {
        let conn = test_db();
        conn.execute(
            "INSERT INTO secondaries (name, consumer_name, nats_token, registered_at)
             VALUES ('legacy-secondary', 'legacy-secondary', 'old-shared-token', 0)",
            [],
        )
        .unwrap();

        assert_eq!(
            authorize_secondary_with_conn(&conn, "legacy-secondary", "anything"),
            None
        );
    }

    #[test]
    fn jwt_round_trips_header_payload_signature() {
        let kp = KeyPair::new_account();
        let claims = json!({"iss": kp.public_key(), "sub": "test", "iat": 1, "jti": ""});
        let token = encode_nats_jwt(claims, &kp).expect("encode succeeds");
        let parts: Vec<&str> = token.split('.').collect();
        assert_eq!(
            parts.len(),
            3,
            "compact JWT must have 3 dot-separated parts"
        );

        let decoded = decode_jwt_payload(&token).expect("decode succeeds");
        assert_eq!(decoded["sub"], "test");
        assert_eq!(decoded["iss"], kp.public_key());
        assert!(
            !decoded["jti"].as_str().unwrap().is_empty(),
            "jti must be filled in"
        );
    }

    #[test]
    fn jwt_header_is_exact_nats_v2_shape() {
        let kp = KeyPair::new_account();
        let token = encode_nats_jwt(json!({"iss": kp.public_key()}), &kp).unwrap();
        let header_b64 = token.split('.').next().unwrap();
        let header_bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(header_b64)
            .unwrap();
        let header: Value = serde_json::from_slice(&header_bytes).unwrap();
        assert_eq!(header["typ"], "JWT");
        assert_eq!(header["alg"], "ed25519-nkey");
    }

    #[test]
    fn jwt_signature_verifies_with_issuer_public_key() {
        let kp = KeyPair::new_account();
        let token = encode_nats_jwt(json!({"iss": kp.public_key(), "sub": "x"}), &kp).unwrap();
        let parts: Vec<&str> = token.split('.').collect();
        let signing_input = format!("{}.{}", parts[0], parts[1]);
        let sig = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(parts[2])
            .unwrap();
        let verifier = KeyPair::from_public_key(&kp.public_key()).unwrap();
        assert!(verifier.verify(signing_input.as_bytes(), &sig).is_ok());
    }

    #[test]
    fn jwt_signature_rejects_tampered_payload() {
        let kp = KeyPair::new_account();
        let token = encode_nats_jwt(json!({"iss": kp.public_key(), "sub": "x"}), &kp).unwrap();
        let parts: Vec<&str> = token.split('.').collect();
        // Flip the payload to a different (still validly-decodable) value
        // without re-signing, simulating a tampered/forged response.
        let tampered_payload =
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(br#"{"sub":"someone-else"}"#);
        let signing_input = format!("{}.{}", parts[0], tampered_payload);
        let sig = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(parts[2])
            .unwrap();
        let verifier = KeyPair::from_public_key(&kp.public_key()).unwrap();
        assert!(verifier.verify(signing_input.as_bytes(), &sig).is_err());
    }

    #[test]
    fn decode_jwt_payload_rejects_malformed_tokens() {
        assert!(decode_jwt_payload("not-a-jwt").is_err());
        assert!(decode_jwt_payload("only.two").is_err());
        assert!(decode_jwt_payload("").is_err());
    }

    // #680: Argon2id is deliberately NOT deterministic -- a fresh random salt
    // per call means two hashes of the same password differ, which is the
    // whole point (it defeats precomputation). This replaces the old
    // SHA-256-era "deterministic and distinct" test, which asserted the exact
    // opposite (same input -> byte-identical hash). Assert the properties that
    // matter under the new scheme: two hashes of one password differ (the salt
    // is applied) yet BOTH still verify against that password, and a wrong
    // password fails to verify.
    #[test]
    fn hash_nats_password_salts_and_verifies() {
        let secret = test_secret("one");
        let a = hash_nats_password(&secret).expect("hashing succeeds");
        let b = hash_nats_password(&secret).expect("hashing succeeds");
        assert_ne!(
            a, b,
            "a fresh per-call salt must make the two hashes differ"
        );

        let parsed_a = PasswordHash::new(&a).expect("hash a is a valid PHC string");
        let parsed_b = PasswordHash::new(&b).expect("hash b is a valid PHC string");
        assert!(
            Argon2::default()
                .verify_password(secret.as_bytes(), &parsed_a)
                .is_ok(),
            "the correct password must verify against hash a"
        );
        assert!(
            Argon2::default()
                .verify_password(secret.as_bytes(), &parsed_b)
                .is_ok(),
            "the correct password must verify against hash b despite a different salt"
        );
        assert!(
            Argon2::default()
                .verify_password(test_secret("two").as_bytes(), &parsed_a)
                .is_err(),
            "a wrong password must not verify"
        );
    }

    // #680 migration behavior: a secondary row still holding a legacy pre-#680
    // unsalted SHA-256 hex digest (not a PHC-format Argon2id string) must fail
    // closed -- authorize returns None rather than panicking or authorizing --
    // so the operator must re-register/rotate to obtain an Argon2id credential.
    // Guards against silently keeping the old weak scheme alive as a
    // verification fallback.
    #[test]
    fn legacy_sha256_hex_hash_is_denied() {
        let conn = test_db();
        // A 64-char all-hex string shaped exactly like the old SHA-256 output;
        // it is not a valid Argon2 PHC string, so PasswordHash::new rejects it.
        let legacy_hex = "a".repeat(64);
        conn.execute(
            "INSERT INTO secondaries (name, consumer_name, nats_token, nats_user, nats_password_hash, registered_at)
             VALUES ('legacy-hash', 'legacy-hash', '', 'legacy-hash', ?1, 0)",
            [legacy_hex],
        )
        .unwrap();
        assert_eq!(
            authorize_secondary_with_conn(&conn, "legacy-hash", "anything"),
            None
        );
    }

    #[test]
    fn secondary_permissions_scope_matches_dns_reader_role() {
        let perms = secondary_permissions();
        let sub_allow = perms["sub"]["allow"].as_array().unwrap();
        assert!(sub_allow.iter().any(|v| v == "lancache.dns.>"));
        assert!(sub_allow.iter().any(|v| v == "_INBOX.>"));
        let pub_allow = perms["pub"]["allow"].as_array().unwrap();
        assert!(pub_allow.iter().any(|v| v == "$JS.ACK.LANCACHE_DNS.>"));
        // Secondaries must never get raw publish access to the DNS record
        // subject itself -- only the trusted, primary-side static roles
        // (DNS-writer, and DNS-replica for its narrow rollback-republish
        // case) publish records; auth-callout-issued secondaries never do.
        assert!(!pub_allow.iter().any(|v| v == "lancache.dns.record"));
    }

    #[test]
    fn build_response_success_contains_signed_user_jwt() {
        let issuer = KeyPair::new_account();
        let response = build_response(&issuer, "server-1", "U123", Some("secondary-a"))
            .expect("build_response succeeds");
        let payload = decode_jwt_payload(&response).expect("outer envelope decodes");
        assert_eq!(payload["nats"]["type"], "authorization_response");
        let inner_jwt = payload["nats"]["jwt"].as_str().expect("jwt field present");
        let inner_payload = decode_jwt_payload(inner_jwt).expect("inner user JWT decodes");
        assert_eq!(inner_payload["name"], "secondary-a");
        // nats-server rejects an authorization_response whose inner user JWT
        // omits/mismatches `aud` with "No valid account ... account missing"
        // even though the envelope itself verifies fine -- confirmed against
        // a real nats-server 2.14.3 (see module docs). This assertion is the
        // regression guard for that exact failure mode.
        assert_eq!(inner_payload["aud"], TARGET_ACCOUNT);
        assert_eq!(inner_payload["nats"]["type"], "user");
    }

    #[test]
    fn build_response_failure_contains_error_no_jwt() {
        let issuer = KeyPair::new_account();
        let response = build_response(&issuer, "server-1", "U123", None)
            .expect("build_response succeeds even on denial");
        let payload = decode_jwt_payload(&response).expect("outer envelope decodes");
        assert_eq!(payload["nats"]["error"], "invalid secondary credentials");
        assert!(payload["nats"].get("jwt").is_none());
    }

    #[test]
    fn load_or_create_issuer_keypair_persists_and_reloads_same_identity() {
        let dir = std::env::temp_dir().join(format!(
            "lancache-ng-issuer-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("issuer.seed");
        let path_str = path.to_str().unwrap();

        let first = load_or_create_issuer_keypair(path_str).expect("first load creates a keypair");
        let second = load_or_create_issuer_keypair(path_str).expect("second load reuses the file");
        assert_eq!(first.public_key(), second.public_key());

        std::fs::remove_dir_all(dir).unwrap();
    }

    // Mirrors load_or_create_issuer_keypair_persists_and_reloads_same_identity
    // above for the separate xkey seed file (#682) -- same persistence
    // contract, different key type (X25519 curve key, not Ed25519).
    #[test]
    fn load_or_create_xkey_persists_and_reloads_same_identity() {
        let dir = std::env::temp_dir().join(format!(
            "lancache-ng-xkey-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("xkey.seed");
        let path_str = path.to_str().unwrap();

        let first = load_or_create_xkey(path_str).expect("first load creates an xkey");
        let second = load_or_create_xkey(path_str).expect("second load reuses the file");
        assert_eq!(first.public_key(), second.public_key());

        std::fs::remove_dir_all(dir).unwrap();
    }

    // A request with no Nats-Server-Xkey header (nats-server has no `xkey:`
    // configured, or this is an older/plain deployment) must be handled
    // exactly as before xkey support existed: passed through as plaintext
    // with no ephemeral sender key, so the responder never hard-requires
    // encryption -- this is what makes the feature safe to enable
    // unilaterally on the Admin UI side without a coordinated nats.conf flip.
    #[test]
    fn decrypt_request_if_sealed_passes_through_plaintext_when_no_xkey_header() {
        let our_xkey = XKey::new();
        let payload = b"not-encrypted-jwt-bytes";

        let (plaintext, sender) =
            decrypt_request_if_sealed(&our_xkey, None, payload).expect("no header is not an error");

        assert_eq!(plaintext, payload);
        assert!(
            sender.is_none(),
            "no ephemeral sender key means the response must not be sealed either"
        );
    }

    // Full round trip simulating nats-server's real xkey behavior end to end
    // without a live server: a "server" ephemeral keypair seals a request to
    // our static public key and advertises its own public half via the exact
    // header name/mechanism nats-server uses; decrypt_request_if_sealed must
    // recover the original plaintext and hand back a sender key usable for
    // the reply. This is the property a live nats-server 2.14.3 additionally
    // proves by actually accepting our sealed response (see
    // scripts/nats-secondary-auth-callout-simulation.sh) -- this unit test
    // only proves our own seal/open pairing is internally consistent, not
    // real-server interop.
    #[test]
    fn decrypt_request_if_sealed_opens_a_real_sealed_request_via_the_header() {
        let our_xkey = XKey::new();
        let server_ephemeral = XKey::new();
        let plaintext_request = b"{\"nats\":{\"user_nkey\":\"U123\"}}";

        let our_public_only = XKey::from_public_key(&our_xkey.public_key()).unwrap();
        let sealed = server_ephemeral
            .seal(plaintext_request, &our_public_only)
            .expect("server-side seal succeeds");

        let mut headers = async_nats::HeaderMap::new();
        headers.insert(
            NATS_SERVER_XKEY_HEADER,
            server_ephemeral.public_key().as_str(),
        );

        let (opened, sender) = decrypt_request_if_sealed(&our_xkey, Some(&headers), &sealed)
            .expect("a validly sealed request with the header must open");

        assert_eq!(opened, plaintext_request);
        assert_eq!(
            sender
                .expect("a sealed request must yield an ephemeral sender key")
                .public_key(),
            server_ephemeral.public_key(),
            "the recovered sender key must match the server's advertised ephemeral public key"
        );
    }

    // A tampered/garbage payload under a present xkey header must fail
    // closed (an Err, not a panic or a silently-wrong plaintext) -- open()
    // authenticates the ciphertext (nacl box / Poly1305), so corruption is
    // detected, not silently accepted.
    #[test]
    fn decrypt_request_if_sealed_rejects_a_tampered_payload() {
        let our_xkey = XKey::new();
        let server_ephemeral = XKey::new();
        let our_public_only = XKey::from_public_key(&our_xkey.public_key()).unwrap();
        let mut sealed = server_ephemeral
            .seal(b"original request", &our_public_only)
            .unwrap();
        // Flip a byte inside the ciphertext (past the "xkv1" version prefix +
        // 24-byte nonce), simulating an on-the-wire tamper attempt.
        let tamper_index = sealed.len() - 1;
        sealed[tamper_index] ^= 0xFF;

        let mut headers = async_nats::HeaderMap::new();
        headers.insert(
            NATS_SERVER_XKEY_HEADER,
            server_ephemeral.public_key().as_str(),
        );

        assert!(
            decrypt_request_if_sealed(&our_xkey, Some(&headers), &sealed).is_err(),
            "a tampered ciphertext must fail to open, not silently decrypt to garbage"
        );
    }

    // seal_response_if_needed's two branches: plaintext passthrough when the
    // request wasn't sealed (mirrors decrypt_request_if_sealed's own
    // passthrough), and a real seal/open round trip when it was -- proving
    // the response encryption direction independently of the request
    // decryption direction tested above.
    #[test]
    fn seal_response_if_needed_passes_through_plaintext_without_ephemeral_sender() {
        let our_xkey = XKey::new();
        let sealed = seal_response_if_needed(&our_xkey, None, "plain-response-jwt").unwrap();
        assert_eq!(sealed, b"plain-response-jwt");
    }

    #[test]
    fn seal_response_if_needed_seals_to_the_ephemeral_sender_and_server_can_open_it() {
        let our_xkey = XKey::new();
        let server_ephemeral = XKey::new();
        // Only the public half is available to us in the real flow (it comes
        // from a message header, see decrypt_request_if_sealed), so mirror
        // that here rather than passing the full server_ephemeral keypair in.
        let server_public_only = XKey::from_public_key(&server_ephemeral.public_key()).unwrap();

        let sealed =
            seal_response_if_needed(&our_xkey, Some(&server_public_only), "response-jwt-payload")
                .expect("sealing to a known-good public key must succeed");

        let our_public_only = XKey::from_public_key(&our_xkey.public_key()).unwrap();
        let opened = server_ephemeral
            .open(&sealed, &our_public_only)
            .expect("the real nats-server side must be able to open what we sealed");
        assert_eq!(opened, b"response-jwt-payload");
    }
}
