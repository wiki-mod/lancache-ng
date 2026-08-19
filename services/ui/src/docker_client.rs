//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
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

pub async fn restart_service(docker: &Docker, service_name: &str, suffix: &str) -> Result<()> {
    let id = container_name_for_service(service_name, suffix)?;
    let options = RestartContainerOptionsBuilder::default().t(5).build();
    docker
        .restart_container(&id, Some(options))
        .await
        .with_context(|| format!("Failed to restart '{}'", service_name))?;
    tracing::info!("Restarted service '{}'", service_name);
    Ok(())
}

pub async fn start_service(docker: &Docker, service_name: &str, suffix: &str) -> Result<()> {
    let id = container_name_for_service(service_name, suffix)?;
    docker
        .start_container(&id, None)
        .await
        .with_context(|| format!("Failed to start '{}'", service_name))?;
    tracing::info!("Started service '{}'", service_name);
    Ok(())
}

pub async fn stop_service_if_present(
    docker: &Docker,
    service_name: &str,
    suffix: &str,
) -> Result<()> {
    let id = container_name_for_service(service_name, suffix)?;
    let options = StopContainerOptionsBuilder::default().t(10).build();
    match docker.stop_container(&id, Some(options)).await {
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

// What: appends `suffix` to the fixed base name for `service_name`.
// Why: docker-socket-proxy.sh and watchdog.sh both already accept
// LANCACHE_CONTAINER_SUFFIX-suffixed names (issue #1415); this was the one
// remaining hardcoded consumer, breaking every restart/start/stop call in a
// suffixed CI run. `suffix` is "" for every real install.
// From: Issue #1590
pub fn container_name_for_service(service_name: &str, suffix: &str) -> Result<String> {
    let base = match service_name {
        "proxy" | "lancache-proxy" => "lancache-proxy",
        "dns-standard" | "lancache-dns-standard" => "lancache-dns-standard",
        "dns-ssl" | "lancache-dns-ssl" => "lancache-dns-ssl",
        "dhcp" | "lancache-dhcp" => "lancache-dhcp",
        "dhcp-proxy" | "lancache-dhcp-proxy" => "lancache-dhcp-proxy",
        "dhcp-probe" | "lancache-dhcp-probe" => "lancache-dhcp-probe",
        "nats" | "lancache-nats" => "lancache-nats",
        "ntp" | "lancache-ntp" => "lancache-ntp",
        _ => anyhow::bail!(
            "Docker service '{}' is not in the lancache-ng socket-proxy allowlist",
            service_name
        ),
    };
    Ok(format!("{base}{suffix}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Live-reproduced on a real deploy/dev stack (issue #1068 item 6, before
    // that stack was retired in v0.3.0, #766): starting a
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

    // What: an empty suffix (every real install) must be byte-identical to
    // pre-suffix behavior.
    // Why: this is the only regression that matters for production installs.
    // From: Issue #1590
    #[test]
    fn container_name_for_service_with_empty_suffix_matches_pre_suffix_behavior() {
        assert_eq!(
            container_name_for_service("nats", "").unwrap(),
            "lancache-nats"
        );
        assert_eq!(
            container_name_for_service("proxy", "").unwrap(),
            "lancache-proxy"
        );
    }

    // What: a non-empty suffix is appended to the resolved base name.
    // Why: this is exactly what a suffixed CI simulation run needs to
    // restart/start/stop the container it actually created.
    // From: Issue #1590
    #[test]
    fn container_name_for_service_appends_a_non_empty_suffix() {
        assert_eq!(
            container_name_for_service("nats", "-e2e-q88wjq").unwrap(),
            "lancache-nats-e2e-q88wjq"
        );
    }

    #[test]
    fn container_name_for_service_rejects_unknown_service_regardless_of_suffix() {
        assert!(container_name_for_service("bogus", "-e2e-q88wjq").is_err());
    }
}
