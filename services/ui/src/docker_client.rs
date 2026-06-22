use anyhow::{Context, Result};
use bollard::Docker;
use bollard::container::{ListContainersOptions, RestartContainerOptions};
use bollard::exec::{CreateExecOptions, StartExecResults};
use futures_util::StreamExt;
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

pub async fn exec_in_container(docker: &Docker, service_name: &str, cmd: Vec<&str>) -> Result<String> {
    let mut filters: HashMap<String, Vec<String>> = HashMap::new();
    filters.insert(
        "label".to_string(),
        vec![format!("com.docker.compose.service={}", service_name)],
    );

    let containers = docker
        .list_containers(Some(ListContainersOptions::<String> {
            all: false,
            filters,
            ..Default::default()
        }))
        .await
        .context("Docker socket not reachable")?;

    let container = containers
        .into_iter()
        .next()
        .with_context(|| format!("No running container found for service '{}'", service_name))?;

    let id = container
        .id
        .as_deref()
        .ok_or_else(|| anyhow::anyhow!("Container for '{}' has no ID", service_name))?
        .to_string();

    let exec = docker
        .create_exec(
            &id,
            CreateExecOptions {
                attach_stdout: Some(true),
                attach_stderr: Some(true),
                cmd: Some(cmd),
                ..Default::default()
            },
        )
        .await
        .context("Failed to create exec")?;

    let mut output = String::new();
    if let StartExecResults::Attached { output: mut stream, .. } = docker
        .start_exec(&exec.id, None)
        .await
        .context("Failed to start exec")?
    {
        while let Some(chunk) = stream.next().await {
            match chunk {
                Ok(bollard::container::LogOutput::StdOut { message }) => {
                    output.push_str(&String::from_utf8_lossy(&message));
                }
                Ok(bollard::container::LogOutput::StdErr { message }) => {
                    output.push_str(&String::from_utf8_lossy(&message));
                }
                _ => {}
            }
        }
    }

    Ok(output)
}
