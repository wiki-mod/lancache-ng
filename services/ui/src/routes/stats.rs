//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! Route for rendering the cache statistics page.

use crate::AppState;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::IntoResponse;
use std::sync::Arc;
use tera::Context;

pub async fn stats_page(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let mut ctx = Context::new();
    ctx.insert("active_page", "stats");
    // What: makes the beambar's restart-ui form's token valid here
    // Why: base.html renders form on every page (was dashboard-only)
    // From: Issue #1437
    crate::routes::insert_csrf_token(&mut ctx, &headers);
    crate::routes::render(&state.templates, "stats.html", &ctx, state.config.dev_mode)
}
