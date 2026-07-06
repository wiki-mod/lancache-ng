//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Docker API access for the Admin UI, scoped to the explicit
//! docker-socket-proxy allowlist (no EXEC, no container list/create/remove):
//! connecting to the proxy/socket, restarting explicitly named lancache
//! containers, and looking up fixed container names used by the predeclared
//! compose services.

use anyhow::{Context, Result};
use bollard::errors::Error as BollardError;
use bollard::query_parameters::{RestartContainerOptionsBuilder, StopContainerOptionsBuilder};
use bollard::Docker;

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
    let id = container_name_for_service(service_name)?;
    let options = RestartContainerOptionsBuilder::default().t(5).build();
    docker
        .restart_container(id, Some(options))
        .await
        .with_context(|| format!("Failed to restart '{}'", service_name))?;
    tracing::info!("Restarted service '{}'", service_name);
    Ok(())
}

pub async fn start_service(docker: &Docker, service_name: &str) -> Result<()> {
    let id = container_name_for_service(service_name)?;
    docker
        .start_container(id, None)
        .await
        .with_context(|| format!("Failed to start '{}'", service_name))?;
    tracing::info!("Started service '{}'", service_name);
    Ok(())
}

pub async fn stop_service_if_present(docker: &Docker, service_name: &str) -> Result<()> {
    let id = container_name_for_service(service_name)?;
    let options = StopContainerOptionsBuilder::default().t(10).build();
    match docker.stop_container(id, Some(options)).await {
        Ok(()) => {
            tracing::info!("Stopped service '{}'", service_name);
            Ok(())
        }
        Err(BollardError::DockerResponseServerError {
            status_code: 304 | 404,
            ..
        }) => Ok(()),
        Err(err) => Err(err).with_context(|| format!("Failed to stop '{}'", service_name)),
    }
}

pub fn container_name_for_service(service_name: &str) -> Result<&'static str> {
    match service_name {
        "proxy" | "lancache-proxy" => Ok("lancache-proxy"),
        "dns-standard" | "lancache-dns-standard" => Ok("lancache-dns-standard"),
        "dns-ssl" | "lancache-dns-ssl" => Ok("lancache-dns-ssl"),
        "dhcp" | "lancache-dhcp" => Ok("lancache-dhcp"),
        "dhcp-proxy" | "lancache-dhcp-proxy" => Ok("lancache-dhcp-proxy"),
        "dhcp-probe" | "lancache-dhcp-probe" => Ok("lancache-dhcp-probe"),
        "nats" | "lancache-nats" => Ok("lancache-nats"),
        _ => anyhow::bail!(
            "Docker service '{}' is not in the lancache-ng socket-proxy allowlist",
            service_name
        ),
    }
}
