use anyhow::{Context, Result};
use bollard::Docker;
use bollard::container::{ListContainersOptions, RestartContainerOptions};
use std::collections::HashMap;

pub async fn restart_service(docker: &Docker, service_name: &str) -> Result<()> {
    let mut filters: HashMap<String, Vec<String>> = HashMap::new();
    filters.insert(
        "label".to_string(),
        vec![format!("com.docker.compose.service={}", service_name)],
    );

    let containers = docker
        .list_containers(Some(ListContainersOptions::<String> {
            all: true,
            filters,
            ..Default::default()
        }))
        .await
        .context("Docker socket not reachable")?;

    let container = containers
        .into_iter()
        .next()
        .with_context(|| format!("No container found for service '{}'", service_name))?;

    let id = container
        .id
        .as_deref()
        .ok_or_else(|| anyhow::anyhow!("Container for '{}' has no ID", service_name))?;
    docker
        .restart_container(id, Some(RestartContainerOptions { t: 5 }))
        .await
        .with_context(|| format!("Failed to restart '{}'", service_name))?;

    tracing::info!("Restarted service '{}'", service_name);
    Ok(())
}
