use anyhow::{Context, Result};
use bollard::exec::{CreateExecOptions, StartExecResults};
use bollard::query_parameters::{ListContainersOptionsBuilder, RestartContainerOptionsBuilder};
use bollard::Docker;
use futures_util::StreamExt;
use std::collections::HashMap;

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

pub async fn exec_in_container(
    docker: &Docker,
    service_name: &str,
    cmd: Vec<&str>,
) -> Result<String> {
    let id = find_container_id(docker, service_name, false).await?;

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
    if let StartExecResults::Attached {
        output: mut stream, ..
    } = docker
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

    let inspect = docker
        .inspect_exec(&exec.id)
        .await
        .context("Failed to inspect exec")?;
    if let Some(code) = inspect.exit_code {
        if code != 0 {
            return Err(anyhow::anyhow!("Command exited with code {}", code));
        }
    }

    Ok(output)
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
