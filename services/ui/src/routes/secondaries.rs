use crate::{docker_client, AppState};
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{Html, Json};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tera::Context;

#[derive(Deserialize)]
pub struct RegisterForm {
    pub token: String,
    pub name: String,
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
    let db = match state.db.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

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
    // Validate token
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

    // Generate random token
    let nats_token = rand_token();
    let consumer_name = form.name.clone();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;

    // INSERT OR REPLACE INTO secondaries
    {
        let db = match state.db.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        db.execute(
            "INSERT OR REPLACE INTO secondaries (name, consumer_name, nats_token, registered_at, last_seen)
             VALUES (?1, ?2, ?3, ?4, NULL)",
            rusqlite::params![form.name, consumer_name, nats_token, now],
        )
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
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
    {
        let db = match state.db.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        db.execute("DELETE FROM secondaries WHERE name = ?", [name])
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
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
) -> Result<Json<serde_json::Value>, StatusCode> {
    // Check if secondary exists
    {
        let db = state.db.lock().unwrap();
        let exists = db
            .query_row(
                "SELECT 1 FROM secondaries WHERE name = ? LIMIT 1",
                [&name],
                |_| Ok(true),
            )
            .ok()
            .is_some();

        if !exists {
            return Err(StatusCode::NOT_FOUND);
        }
    }

    let new_token = rand_token();

    {
        let db = match state.db.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        db.execute(
            "UPDATE secondaries SET nats_token = ? WHERE name = ?",
            [new_token.clone(), name],
        )
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
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

    Ok(Json(serde_json::json!({"nats_token": new_token})))
}

// ─── Helper Functions ───

fn rand_token() -> String {
    let bytes: [u8; 32] = rand::random();
    hex::encode(bytes)
}

pub async fn update_nats_conf(state: &AppState) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let nats_conf = format!(
        "jetstream {{\n  store_dir: /data\n}}\n\nauthorization {{\n  token: \"{}\"\n}}\n",
        state.config.nats_local_token
    );

    std::fs::write(&state.config.nats_conf_path, nats_conf)
        .map_err(|e| format!("Failed to write nats.conf: {}", e).into())
}
