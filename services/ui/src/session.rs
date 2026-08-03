//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Per-session CSRF token issuance and validation for the Admin UI. Sessions
//! are opaque, HMAC-signed cookies (`v1.{expires_at}.{csrf_token}.{signature}`)
//! that carry a unique CSRF token. They are never used for authentication,
//! only for binding a CSRF token to one browser session. See `main.rs`'s
//! `basic_auth` middleware for how this is wired into the request pipeline.

use axum::http::{HeaderMap, HeaderName, HeaderValue, header};
use rand::random;
use sha2::{Digest, Sha256};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use subtle::ConstantTimeEq;

pub const SESSION_COOKIE_NAME: &str = "lancache_ui_session";
pub const INTERNAL_CSRF_HEADER_NAME: &str = "x-lancache-ui-csrf-token";
const SESSION_COOKIE_VERSION: &str = "v1";
const COOKIE_SEPARATOR: char = '.';

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionToken {
    pub csrf_token: String,
    pub cookie_value: String,
    pub expires_at: SystemTime,
}

pub fn issue_session(secret: &[u8; 32], ttl: Duration) -> SessionToken {
    issue_session_at(SystemTime::now(), secret, ttl)
}

pub fn issue_session_at(now: SystemTime, secret: &[u8; 32], ttl: Duration) -> SessionToken {
    let csrf_bytes: [u8; 32] = random();
    let csrf_token = hex::encode(csrf_bytes);
    let expires_at = now.checked_add(ttl).unwrap_or(UNIX_EPOCH);
    let cookie_value = build_cookie_value(&csrf_token, expires_at, secret);

    SessionToken {
        csrf_token,
        cookie_value,
        expires_at,
    }
}

pub fn validate_session_cookie(
    cookie_value: &str,
    secret: &[u8; 32],
    now: SystemTime,
) -> Option<SessionToken> {
    let mut parts = cookie_value.split(COOKIE_SEPARATOR);
    let version = parts.next()?;
    let expires_at = parts.next()?;
    let csrf_token = parts.next()?;
    let signature = parts.next()?;

    if parts.next().is_some() || version != SESSION_COOKIE_VERSION {
        return None;
    }

    let expires_at_secs = expires_at.parse::<u64>().ok()?;
    let expires_at = UNIX_EPOCH.checked_add(Duration::from_secs(expires_at_secs))?;
    if now >= expires_at {
        return None;
    }

    let expected = build_cookie_signature(version, expires_at_secs, csrf_token, secret);
    if !bool::from(signature.as_bytes().ct_eq(expected.as_bytes())) {
        return None;
    }

    Some(SessionToken {
        csrf_token: csrf_token.to_owned(),
        cookie_value: cookie_value.to_owned(),
        expires_at,
    })
}

pub fn session_cookie_value(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(header::COOKIE)?
        .to_str()
        .ok()?
        .split(';')
        .map(str::trim)
        .find_map(|cookie| cookie.strip_prefix(&format!("{SESSION_COOKIE_NAME}=")))
}

pub fn csrf_header_value(headers: &HeaderMap) -> Option<&str> {
    headers.get(INTERNAL_CSRF_HEADER_NAME)?.to_str().ok()
}

pub fn set_session_cookie(
    response: &mut axum::response::Response,
    session: &SessionToken,
    ttl: Duration,
    secure: bool,
) {
    let mut cookie = format!(
        "{}={}; Path=/; SameSite=Strict; HttpOnly; Max-Age={}",
        SESSION_COOKIE_NAME,
        session.cookie_value,
        ttl.as_secs()
    );

    if secure {
        cookie.push_str("; Secure");
    }

    match HeaderValue::from_str(&cookie) {
        Ok(header_value) => {
            response
                .headers_mut()
                .insert(header::SET_COOKIE, header_value);
        }
        Err(err) => {
            tracing::error!(error = %err, "failed to build session cookie header");
        }
    }
}

pub fn set_internal_csrf_header(headers: &mut HeaderMap, token: &str) {
    if let Ok(value) = HeaderValue::from_str(token) {
        headers.insert(HeaderName::from_static(INTERNAL_CSRF_HEADER_NAME), value);
    }
}

pub fn token_matches(expected: &str, submitted: &str) -> bool {
    expected.as_bytes().ct_eq(submitted.as_bytes()).into()
}

fn build_cookie_value(csrf_token: &str, expires_at: SystemTime, secret: &[u8; 32]) -> String {
    let expires_at = expires_at
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let signature = build_cookie_signature(SESSION_COOKIE_VERSION, expires_at, csrf_token, secret);
    format!(
        "{version}.{expires_at}.{csrf_token}.{signature}",
        version = SESSION_COOKIE_VERSION
    )
}

fn build_cookie_signature(
    version: &str,
    expires_at: impl std::fmt::Display,
    csrf_token: &str,
    secret: &[u8; 32],
) -> String {
    let payload = format!("{version}.{expires_at}.{csrf_token}");
    hex::encode(hmac_sha256(secret, payload.as_bytes()))
}

fn hmac_sha256(secret: &[u8; 32], payload: &[u8]) -> [u8; 32] {
    const BLOCK_SIZE: usize = 64;

    let mut key_block = [0u8; BLOCK_SIZE];
    key_block[..secret.len()].copy_from_slice(secret);

    let mut inner_pad = [0x36u8; BLOCK_SIZE];
    let mut outer_pad = [0x5cu8; BLOCK_SIZE];
    for idx in 0..BLOCK_SIZE {
        inner_pad[idx] ^= key_block[idx];
        outer_pad[idx] ^= key_block[idx];
    }

    let mut inner = Sha256::new();
    inner.update(inner_pad);
    inner.update(payload);
    let inner_digest = inner.finalize();

    let mut outer = Sha256::new();
    outer.update(outer_pad);
    outer.update(inner_digest);
    outer.finalize().into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_cookie_is_valid_and_contains_a_unique_csrf_token() {
        let secret = [0x11; 32];
        let ttl = Duration::from_secs(300);
        let now = UNIX_EPOCH + Duration::from_secs(1_700_000_000);

        let first = issue_session_at(now, &secret, ttl);
        let second = issue_session_at(now, &secret, ttl);

        assert_ne!(first.csrf_token, second.csrf_token);
        assert_ne!(first.cookie_value, second.cookie_value);
        assert!(validate_session_cookie(&first.cookie_value, &secret, now).is_some());
        assert!(validate_session_cookie(&second.cookie_value, &secret, now).is_some());
    }

    #[test]
    fn session_cookie_rejects_tampering_and_expiry() {
        let secret = [0x22; 32];
        let ttl = Duration::from_secs(300);
        let now = UNIX_EPOCH + Duration::from_secs(1_700_000_000);
        let session = issue_session_at(now, &secret, ttl);

        assert!(validate_session_cookie("", &secret, now).is_none());

        let mut tampered_cookie = session.cookie_value.clone();
        tampered_cookie.push('x');
        assert!(validate_session_cookie(&tampered_cookie, &secret, now).is_none());

        assert!(
            validate_session_cookie(
                &session.cookie_value,
                &secret,
                now + Duration::from_secs(301)
            )
            .is_none()
        );
    }

    #[test]
    fn csrf_token_validation_requires_the_matching_session_token() {
        let secret = [0x33; 32];
        let ttl = Duration::from_secs(300);
        let now = UNIX_EPOCH + Duration::from_secs(1_700_000_000);
        let session_a = issue_session_at(now, &secret, ttl);
        let session_b = issue_session_at(now, &secret, ttl);

        assert!(token_matches(&session_a.csrf_token, &session_a.csrf_token));
        assert!(!token_matches(&session_a.csrf_token, &session_b.csrf_token));
        assert!(!token_matches(&session_a.csrf_token, ""));
    }
}
