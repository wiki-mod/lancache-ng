use crate::{docker_client, nats_config, AppState};
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
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

#[derive(Deserialize)]
pub struct RotateForm {
    pub token: String,
}

#[derive(Serialize)]
pub struct RegisterResponse {
    pub nats_url: String,
    pub nats_user: String,
    pub nats_password: String,
    pub nats_token: String,
    pub consumer_name: String,
    pub proxy_ip: String,
    pub pdns_api_key: String,
    pub image_tag: String,
}

#[derive(Serialize, Clone)]
pub struct Secondary {
    pub name: String,
    pub consumer_name: String,
    pub registered_at: i64,
    pub last_seen: Option<i64>,
}

// ─── Handlers ───

pub async fn secondaries_page(
    State(state): State<Arc<AppState>>,
) -> Result<Html<String>, StatusCode> {
    let db = state
        .db
        .lock()
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

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
    crate::routes::insert_csrf_token(&mut ctx, &state);

    Ok(crate::routes::render(
        &state.templates,
        "secondaries.html",
        &ctx,
    ))
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
        || !form
            .name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-')
    {
        return Err(StatusCode::BAD_REQUEST);
    }

    // Secondaries use the read-only NATS role credential.
    let nats_user = state.config.nats_dns_reader_user.clone();
    let nats_token = state.config.nats_dns_reader_password.clone();
    let consumer_name = form.name.clone();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;

    // INSERT OR REPLACE INTO secondaries
    {
        let db = state
            .db
            .lock()
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
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
        nats_user,
        nats_password: nats_token.clone(),
        nats_token,
        consumer_name,
        proxy_ip: state.config.standard_ip.clone(),
        pdns_api_key: state.config.pdns_api_key.clone(),
        image_tag: state.config.lancache_image_tag.clone(),
    }))
}

pub async fn remove_secondary(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    crate::routes::verify_csrf_header(&state, &headers)?;
    let rows_affected = {
        let db = state
            .db
            .lock()
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
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
    headers: HeaderMap,
    axum::extract::Json(form): axum::extract::Json<RotateForm>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    crate::routes::verify_csrf_header(&state, &headers)?;
    // Validate token — reject if token is unconfigured (empty).
    if state.config.secondary_registration_token.is_empty() {
        return Err(StatusCode::UNAUTHORIZED);
    }
    if form.token != state.config.secondary_registration_token {
        return Err(StatusCode::UNAUTHORIZED);
    }

    // Secondaries use the read-only NATS role credential.
    let nats_user = state.config.nats_dns_reader_user.clone();
    let nats_token = state.config.nats_dns_reader_password.clone();

    // Update the secondary's stored token and verify the secondary exists
    let rows_affected = {
        let db = state
            .db
            .lock()
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
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

    Ok(Json(serde_json::json!({
        "nats_user": nats_user,
        "nats_password": nats_token.clone(),
        "nats_token": nats_token
    })))
}

// ─── Helper Functions ───

pub async fn update_nats_conf(
    state: &AppState,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // Validate all NATS credentials before interpolating into config
    nats_config::validate_nats_credentials(
        &state.config.nats_ui_user,
        &state.config.nats_ui_password,
    )
    .map_err(|e| format!("Invalid NATS UI credentials: {}", e))?;
    nats_config::validate_nats_credentials(
        &state.config.nats_dns_writer_user,
        &state.config.nats_dns_writer_password,
    )
    .map_err(|e| format!("Invalid NATS DNS writer credentials: {}", e))?;
    nats_config::validate_nats_credentials(
        &state.config.nats_dns_reader_user,
        &state.config.nats_dns_reader_password,
    )
    .map_err(|e| format!("Invalid NATS DNS reader credentials: {}", e))?;

    let nats_conf = format!(
        "jetstream {{\n  store_dir: /data\n}}\n\nauthorization {{\n  users = [\n    {{\n      user: \"{}\"\n      password: \"{}\"\n      permissions = {{\n        publish = [\"lancache.dns.record\", \"lancache.dns.flush\"]\n      }}\n    }}\n    {{\n      user: \"{}\"\n      password: \"{}\"\n      permissions = {{\n        publish = [\n          \"lancache.dns.record\",\n          \"$JS.API.STREAM.INFO.LANCACHE_DNS\",\n          \"$JS.API.STREAM.CREATE.LANCACHE_DNS\",\n          \"$JS.API.CONSUMER.INFO.LANCACHE_DNS.>\",\n          \"$JS.API.CONSUMER.CREATE.LANCACHE_DNS.>\",\n          \"$JS.API.CONSUMER.DURABLE.CREATE.LANCACHE_DNS.>\",\n          \"$JS.API.CONSUMER.MSG.NEXT.LANCACHE_DNS.>\",\n          \"$JS.ACK.LANCACHE_DNS.>\"\n        ]\n        subscribe = [\"lancache.dns.>\", \"_INBOX.>\"]\n      }}\n    }}\n    {{\n      user: \"{}\"\n      password: \"{}\"\n      permissions = {{\n        publish = [\n          \"$JS.API.STREAM.INFO.LANCACHE_DNS\",\n          \"$JS.API.CONSUMER.INFO.LANCACHE_DNS.>\",\n          \"$JS.API.CONSUMER.CREATE.LANCACHE_DNS.>\",\n          \"$JS.API.CONSUMER.DURABLE.CREATE.LANCACHE_DNS.>\",\n          \"$JS.API.CONSUMER.MSG.NEXT.LANCACHE_DNS.>\",\n          \"$JS.ACK.LANCACHE_DNS.>\"\n        ]\n        subscribe = [\"lancache.dns.>\", \"_INBOX.>\"]\n      }}\n    }}\n  ]\n}}\n",
        state.config.nats_ui_user,
        state.config.nats_ui_password,
        state.config.nats_dns_writer_user,
        state.config.nats_dns_writer_password,
        state.config.nats_dns_reader_user,
        state.config.nats_dns_reader_password
    );

    std::fs::write(&state.config.nats_conf_path, nats_conf)
        .map_err(|e| format!("Failed to write nats.conf: {}", e).into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn register_response_serializes_image_tag_for_secondary_setup() {
        let response = RegisterResponse {
            nats_url: "nats://primary:4222".to_string(),
            nats_user: "lancache-dns-reader".to_string(),
            nats_password: "reader-secret".to_string(),
            nats_token: "reader-secret".to_string(),
            consumer_name: "secondary-a".to_string(),
            proxy_ip: "192.168.1.100".to_string(),
            pdns_api_key: "pdns-secret".to_string(),
            image_tag: "v1.2.3".to_string(),
        };

        let value = serde_json::to_value(response).unwrap();
        assert_eq!(value["image_tag"], "v1.2.3");
    }
}
