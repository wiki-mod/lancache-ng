//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! Pure, no-network logic for the warmer daemon (issue #871): the
//! credential-store (Argon2id-as-KDF + XChaCha20-Poly1305 AEAD) and the
//! stream-fetch byte-counting primitive. Exposed as a library so unit
//! tests can exercise both without a live Steam account or network
//! access, mirroring services/ui's and services/watchdog's own lib.rs
//! pure-module split.
//!
//! Scope note (2026-08-29): this crate currently implements only the
//! credential-store and stream-fetch/throughput primitives described in
//! docs/design-steam-prefill.md's implementation plan (steps covering the
//! data-plane fetch and credential handling). It does NOT yet implement
//! the Steam control-plane login (steam-vent) or depot/manifest parsing
//! (steamroom) -- that integration needs a real Steam account to test
//! against safely and is deliberately deferred (see issue #871 and this
//! crate's own README for the full scope note). `main.rs` currently only
//! exercises the two modules below against an operator-supplied URL list,
//! not real Steam depot URLs resolved from an app ID.

pub mod credential_store;
pub mod stream_fetch;
