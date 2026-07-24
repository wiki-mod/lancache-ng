//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Docker API access for the Admin UI, scoped to the explicit
//! docker-socket-proxy allowlist (no EXEC, no container list/create/remove):
//! connecting to the proxy/socket, restarting explicitly named lancache
//! containers, and looking up fixed container names used by the predeclared
//! compose services.

use anyhow::{Context, Result};
use bollard::Docker;
use bollard::errors::Error as BollardError;
use bollard::query_parameters::{RestartContainerOptionsBuilder, StopContainerOptionsBuilder};

pub fn connect_from_env() -> Result<Docker> {
    if let Ok(proxy_url) = std::env::var("DOCKER_PROXY_URL") {
        let proxy_url = proxy_url.trim();
        if !proxy_url.is_empty() {
            return Docker::connect_with_http(proxy_url, 120, bollard::API_DEFAULT_VERSION)
                .context("Failed to connect to Docker proxy");
        }
    }

    if let Ok(host) = std::env::var("DOCKER_HOST")
        && let Some(tcp_url) = host.trim().strip_prefix("tcp://")
        && !tcp_url.is_empty()
    {
        return Docker::connect_with_http(tcp_url, 120, bollard::API_DEFAULT_VERSION)
            .context("Failed to connect to Docker host");
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

// A 404 from start/restart means the target container was never created at
// all -- distinct from every other start failure (crash loop, OOM, bad
// config), which always act on an EXISTING container. In this project that
// only happens for a profile-gated Compose service (see docker-compose.yml's
// `dhcp`/`dhcp-proxy` `profiles:`) whose profile was never included in
// COMPOSE_PROFILES at `docker compose up` time -- reconcile_dhcp_mode in
// routes/dhcp.rs hits exactly this the first time an operator switches to a
// DHCP mode that was never active before, since the docker-socket-proxy
// allowlist this module talks through deliberately has no container-create
// capability (see this file's own header). Callers use this to turn an
// opaque "Failed to start 'x'" into the actionable "the container doesn't
// exist yet, here's the exact command to create it" guidance an operator
// (who is not assumed to be a programmer) can actually act on.
pub fn is_container_not_created(err: &anyhow::Error) -> bool {
    err.chain().any(|cause| {
        matches!(
            cause.downcast_ref::<BollardError>(),
            Some(BollardError::DockerResponseServerError {
                status_code: 404,
                ..
            })
        )
    })
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
        "ntp" | "lancache-ntp" => Ok("lancache-ntp"),
        _ => anyhow::bail!(
            "Docker service '{}' is not in the lancache-ng socket-proxy allowlist",
            service_name
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Live-reproduced on a real dev stack (issue #1068 item 6): starting a
    // profile-gated container that was never created returns exactly this
    // 404 shape from the docker-socket-proxy. Confirms is_container_not_created
    // recognizes it so callers can turn it into actionable guidance instead
    // of an opaque "Failed to start 'x'".
    #[test]
    fn is_container_not_created_recognizes_a_404_anywhere_in_the_error_chain() {
        let bollard_err = BollardError::DockerResponseServerError {
            status_code: 404,
            message: "No such container: lancache-dhcp-proxy".to_string(),
        };
        let wrapped: anyhow::Error =
            anyhow::Error::new(bollard_err).context("Failed to start 'dhcp-proxy'");
        assert!(is_container_not_created(&wrapped));
    }

    // A stopped/crash-looping container also surfaces through start_container,
    // but as a different status code (e.g. 500 for an internal daemon error,
    // or 409 for a conflicting operation) -- this must NOT be mistaken for
    // the "never created" case, or an operator would be told to run a
    // `docker compose up --profile ...` command that cannot fix a real
    // runtime failure.
    #[test]
    fn is_container_not_created_rejects_other_status_codes() {
        let bollard_err = BollardError::DockerResponseServerError {
            status_code: 500,
            message: "internal server error".to_string(),
        };
        let wrapped: anyhow::Error =
            anyhow::Error::new(bollard_err).context("Failed to start 'dhcp'");
        assert!(!is_container_not_created(&wrapped));
    }

    // A plain anyhow error with no Docker cause at all (e.g. the
    // container_name_for_service allowlist rejection above) must not
    // false-positive just because is_container_not_created scans the chain.
    #[test]
    fn is_container_not_created_rejects_non_docker_errors() {
        let err = anyhow::anyhow!("Docker service 'bogus' is not in the allowlist");
        assert!(!is_container_not_created(&err));
    }
}
