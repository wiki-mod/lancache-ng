//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Docker API access for the Admin UI: connecting to the proxy/socket,
//! restarting a compose service by its `com.docker.compose.service` label,
//! and running a one-off command inside a service's container via Docker
//! exec.

use anyhow::{Context, Result};
use bollard::query_parameters::{ListContainersOptionsBuilder, RestartContainerOptionsBuilder};
use bollard::Docker;
use std::collections::HashMap;

pub fn connect_from_env() -> Result<Docker> {
    if let Ok(proxy_url) = std::env::var("DOCKER_PROXY_URL") {
        let proxy_url = proxy_url.trim();
        if !proxy_url.is_empty() {
            return Docker::connect_with_http(proxy_url, 120, bollard::API_DEFAULT_VERSION)
                .context("Failed to connect to Docker proxy");
        }
    }

    if let Ok(host) = std::env::var("DOCKER_HOST") {
        if let Some(tcp_url) = host.trim().strip_prefix("tcp://") {
            if !tcp_url.is_empty() {
                return Docker::connect_with_http(tcp_url, 120, bollard::API_DEFAULT_VERSION)
                    .context("Failed to connect to Docker host");
            }
        }
    }

    Docker::connect_with_socket_defaults().context("Failed to connect to Docker socket")
}

pub async fn restart_service(docker: &Docker, service_name: &str) -> Result<()> {
    let id = find_container_id(docker, service_name, true).await?;
    let options = RestartContainerOptionsBuilder::default().t(5).build();
    docker
        .restart_container(&id, Some(options))
        .await
        .with_context(|| format!("Failed to restart '{}'", service_name))?;
    tracing::info!("Restarted service '{}'", service_name);
    Ok(())
}

pub async fn container_image_for_service(docker: &Docker, service_name: &str) -> Result<String> {
    let id = find_container_id(docker, service_name, false).await?;
    let inspect = docker
        .inspect_container(&id, None)
        .await
        .with_context(|| format!("Failed to inspect container for service '{}'", service_name))?;

    inspect
        .image
        .with_context(|| format!("No image recorded for service '{}'", service_name))
}

async fn find_container_id(
    docker: &Docker,
    service_name: &str,
    include_stopped: bool,
) -> Result<String> {
    let mut filters: HashMap<String, Vec<String>> = HashMap::new();
    filters.insert(
        "label".to_string(),
        vec![format!("com.docker.compose.service={}", service_name)],
    );

    let options = ListContainersOptionsBuilder::default()
        .all(include_stopped)
        .filters(&filters)
        .build();

    let containers = docker
        .list_containers(Some(options))
        .await
        .context("Docker socket not reachable")?;

    containers
        .into_iter()
        .next()
        .and_then(|c| c.id)
        .with_context(|| format!("No container found for service '{}'", service_name))
}
