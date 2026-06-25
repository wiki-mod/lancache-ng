use crate::{docker_client, AppState};
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{Html, Json};
use rusqlite::OptionalExtension;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tera::Context;

#[derive(Deserialize)]
pub struct RegisterForm {
    pub token: String,
    pub name: String,
}

#[derive(Deserialize)]
pub struct RotateForm {
    pub token: String,
}

#[derive(Serialize)]
pub struct RegisterResponse {
    pub nats_url: String,
    pub nats_token: String,
    pub consumer_name: String,
    pub proxy_ip: String,
    pub pdns_api_key: String,
}

#[derive(Serialize, Clone)]
pub struct Secondary {
    pub name: String,
    pub consumer_name: String,
    pub registered_at: i64,
    pub last_seen: Option<i64>,
}

// ─── Handlers ───

pub async fn secondaries_page(State(state): State<Arc<AppState>>) -> Html<String> {
    let db = state.db.lock().unwrap();

    let secondaries = db
        .prepare("SELECT name, consumer_name, registered_at, last_seen FROM secondaries ORDER BY registered_at DESC")
        .and_then(|mut stmt| {
            stmt.query_map([], |row| {
                Ok(Secondary {
                    name: row.get(0)?,
                    consumer_name: row.get(1)?,
                    registered_at: row.get(2)?,
                    last_seen: row.get(3)?,
                })
            })
            .and_then(|rows| rows.collect::<Result<Vec<_>, _>>())
        })
        .unwrap_or_default();

    let primary_url = format!("http://{}:8080", state.config.standard_ip);
    let reg_token = &state.config.secondary_registration_token;

    let mut ctx = Context::new();
    ctx.insert("active_page", "secondaries");
    ctx.insert("secondaries", &secondaries);
    ctx.insert("primary_url", &primary_url);
    ctx.insert("registration_token", reg_token);

    crate::routes::render(&state.templates, "secondaries.html", &ctx)
}

pub async fn register_secondary(
    State(state): State<Arc<AppState>>,
    axum::extract::Json(form): axum::extract::Json<RegisterForm>,
) -> Result<Json<RegisterResponse>, StatusCode> {
    // Validate token — reject if token is unconfigured (empty) to prevent
    // accidental open registration when SECONDARY_REGISTRATION_TOKEN is unset.
    if state.config.secondary_registration_token.is_empty() {
        return Err(StatusCode::UNAUTHORIZED);
    }
    if form.token != state.config.secondary_registration_token {
        return Err(StatusCode::UNAUTHORIZED);
    }

    // Validate name: alphanumeric + dash, non-empty, ≤32 chars
    if form.name.is_empty()
        || form.name.len() > 32
        || !form.name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
    {
        return Err(StatusCode::BAD_REQUEST);
    }

    // All secondaries share the local NATS token.
    // NOTE: Full per-secondary token isolation requires NATS JetStream user management,
    // which is out of scope. The current shared token approach is a known limitation.
    let nats_token = state.config.nats_local_token.clone();
    let consumer_name = form.name.clone();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;

    // INSERT OR REPLACE INTO secondaries
    {
        let db = state.db.lock().unwrap();
        db.execute(
            "INSERT OR REPLACE INTO secondaries (name, consumer_name, nats_token, registered_at, last_seen)
             VALUES (?1, ?2, ?3, ?4, NULL)",
            rusqlite::params![form.name, consumer_name, nats_token, now],
        )
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    }

    // Update NATS conf (regenerate if needed, though configuration is unchanged)
    update_nats_conf(&state)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    // Send SIGHUP to NATS container
    let _ = docker_client::exec_in_container(
        &state.docker,
        &state.config.nats_service,
        vec!["kill", "-HUP", "1"],
    )
    .await;

    Ok(Json(RegisterResponse {
        nats_url: state.config.nats_url.clone(),
        nats_token,
        consumer_name,
        proxy_ip: state.config.standard_ip.clone(),
        pdns_api_key: state.config.pdns_api_key.clone(),
    }))
}

pub async fn remove_secondary(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let rows_affected = {
        let db = state.db.lock().unwrap();
        db.execute("DELETE FROM secondaries WHERE name = ?", [name])
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
    };

    // Return 404 if the secondary doesn't exist
    if rows_affected == 0 {
        return Err(StatusCode::NOT_FOUND);
    }

    // Update NATS conf
    update_nats_conf(&state)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    // Send SIGHUP to NATS container
    let _ = docker_client::exec_in_container(
        &state.docker,
        &state.config.nats_service,
        vec!["kill", "-HUP", "1"],
    )
    .await;

    Ok(Json(serde_json::json!({"ok": true})))
}

pub async fn rotate_token(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
    axum::extract::Json(form): axum::extract::Json<RotateForm>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    // Validate token — reject if token is unconfigured (empty).
    if state.config.secondary_registration_token.is_empty() {
        return Err(StatusCode::UNAUTHORIZED);
    }
    if form.token != state.config.secondary_registration_token {
        return Err(StatusCode::UNAUTHORIZED);
    }

    // All secondaries share the local NATS token, so return the current token.
    // NOTE: Full per-secondary token isolation requires NATS JetStream user management,
    // which is out of scope. The current shared token approach is a known limitation.
    let nats_token = state.config.nats_local_token.clone();

    // Update the secondary's stored token and verify the secondary exists
    let rows_affected = {
        let db = state.db.lock().unwrap();
        db.execute(
            "UPDATE secondaries SET nats_token = ? WHERE name = ?",
            [nats_token.clone(), name.clone()],
        )
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
    };

    // Return 404 if the secondary doesn't exist
    if rows_affected == 0 {
        return Err(StatusCode::NOT_FOUND);
    }

    // Update NATS conf (regenerate if needed, though configuration is unchanged)
    update_nats_conf(&state)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    // Send SIGHUP to NATS container
    let _ = docker_client::exec_in_container(
        &state.docker,
        &state.config.nats_service,
        vec!["kill", "-HUP", "1"],
    )
    .await;

    Ok(Json(serde_json::json!({"nats_token": nats_token})))
}

// ─── Helper Functions ───

pub async fn update_nats_conf(state: &AppState) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let nats_conf = format!(
        "jetstream {{\n  store_dir: /data\n}}\n\nauthorization {{\n  token: \"{}\"\n}}\n",
        state.config.nats_local_token
    );

    std::fs::write(&state.config.nats_conf_path, nats_conf)
        .map_err(|e| format!("Failed to write nats.conf: {}", e).into())
}
