use crate::{docker_client, AppState};
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{Html, Json};
use serde::{Deserialize, Serialize};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
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

    let mut ctx = Context::new();
    ctx.insert("active_page", "secondaries");
    ctx.insert("secondaries", &secondaries);

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
        || !form.name.chars().all(|c| c.is_alphanumeric() || c == '-')
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
        let db = state.db.lock().unwrap();
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
        let db = state.db.lock().unwrap();
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
    let new_token = rand_token();

    {
        let db = state.db.lock().unwrap();
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
    // Use time + pid as entropy source (good enough for LAN tokens)
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
    let pid = std::process::id();
    let mut h = DefaultHasher::new();
    now.as_nanos().hash(&mut h);
    pid.hash(&mut h);
    let a = h.finish();

    // Generate another hash for second half
    let mut h = DefaultHasher::new();
    now.as_micros().hash(&mut h);
    pid.hash(&mut h);
    let b = h.finish();

    format!("{:016x}{:016x}", a, b)
}

async fn update_nats_conf(state: &AppState) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let db = state.db.lock().unwrap();

    // Load all secondaries' nats tokens
    let mut tokens = db
        .prepare("SELECT nats_token FROM secondaries")?
        .query_map([], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;

    // Also include the local token
    tokens.push(state.config.nats_local_token.clone());

    // Build nats.conf content
    let users_block = tokens
        .iter()
        .map(|token| format!("    {{ token: \"{}\" }}", token))
        .collect::<Vec<_>>()
        .join(",\n");

    let nats_conf = format!(
        r#"jetstream {{ store_dir: /data }}

authorization {{
  users: [
{}
  ]
}}
"#,
        users_block
    );

    // Write to file
    std::fs::write(&state.config.nats_conf_path, nats_conf)
        .map_err(|e| format!("Failed to write nats.conf: {}", e).into())
}
