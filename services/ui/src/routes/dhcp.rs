//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Admin UI DHCP routes. Renders Kea DHCP subnets, leases, reservations, and
//! dual DHCP probe checks, and applies guarded DHCP config mutations through
//! the Kea control-agent with rollback handling for failed persistence.
//!
//! Docker exec is intentionally not used here. The UI talks to a narrowed
//! Docker socket proxy, so DHCP conflict discovery runs through a predeclared
//! one-shot helper container that can only be started, waited on, and logged.

use crate::{docker_client, kea_snapshots, AppState};
use anyhow::Context as AnyhowContext;
use axum::extract::{Form, State};
use axum::http::HeaderMap;
use axum::http::StatusCode;
use axum::response::{Html, IntoResponse, Redirect, Response};
use axum::Json;
use bollard::container::LogOutput;
// The DHCP probe path deliberately uses only start/stop/wait/logs operations
// because Docker exec and generic container creation are banned from the UI's
// Docker API surface for security reasons.
use bollard::query_parameters::{
    LogsOptionsBuilder, StartContainerOptionsBuilder, StopContainerOptionsBuilder,
    WaitContainerOptionsBuilder,
};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs;
use std::future::Future;
use std::net::Ipv4Addr;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tera::Context;

// ─── Constants ───

const MIN_LEASE_TIME: u32 = 60;
const MAX_LEASE_TIME: u32 = 604_800; // 7 days
const CUSTOM_DHCP_OPTION_DATA_MAX_LEN: usize = 1024;

// ─── Error Handling ───

/// Error type for DHCP configuration operations that carries a message
/// and HTTP status code, suitable for surfacing to HTTP responses.
#[derive(Debug)]
pub struct DhcpError {
    status: StatusCode,
    message: String,
}

impl DhcpError {
    fn new(status: StatusCode, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
        }
    }

    // Used for genuine config-mutation/backend failures (a Kea API call
    // failed, a rollback couldn't complete, etc.) -- the request itself was
    // well-formed, but the server-side operation it triggered did not
    // succeed.
    fn config_error(message: impl Into<String>) -> Self {
        Self::new(StatusCode::INTERNAL_SERVER_ERROR, message)
    }

    // Used when the request is well-formed but conflicts with current
    // server state (e.g. a mutation attempted while not in Kea mode) --
    // distinct from config_error's "the operation failed" and from a plain
    // 400 "the input itself was invalid".
    fn conflict(message: impl Into<String>) -> Self {
        Self::new(StatusCode::CONFLICT, message)
    }
}

// Lets `?` convert a bare StatusCode (used for simple input-validation
// failures like a malformed MAC/IP) straight into a DhcpError without every
// call site constructing one by hand.
impl From<StatusCode> for DhcpError {
    fn from(status: StatusCode) -> Self {
        Self::new(status, format!("HTTP {}", status.as_u16()))
    }
}

impl std::fmt::Display for DhcpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for DhcpError {}

// Every DHCP route in this file renders full HTML pages (this is the Admin
// UI, not a JSON API), so an error result is rendered the same way as a
// successful page -- a minimal standalone HTML error page with a link back
// to /dhcp -- rather than a bare status code or a JSON error body an
// operator's browser would show unstyled.
impl IntoResponse for DhcpError {
    fn into_response(self) -> Response {
        let body = format!(
            "<!DOCTYPE html>\n<html>\n<head><title>DHCP Configuration Error</title></head>\n\
             <body><h1>DHCP Configuration Error</h1>\n<p>{}</p>\n\
             <p><a href=\"/dhcp\">Return to DHCP settings</a></p>\n</body>\n</html>",
            html_escape(&self.message)
        );
        (self.status, Html(body)).into_response()
    }
}

// The three-way outcome of Kea's config-write command (see kea_write_config
// further down): Success and ConfirmedFailure are unambiguous, but
// AmbiguousFailure means the request itself errored (network/transport
// issue), so it is genuinely unknown whether Kea applied the write --
// kea_config_modify_with_post's retry-then-rollback logic branches on this
// three-way split, not a plain bool, specifically to keep that distinction.
#[derive(Debug)]
enum KeaWriteOutcome {
    Success,
    ConfirmedFailure(String),
    AmbiguousFailure(String),
}

// Manual escaping instead of a crate dependency: this project's error
// messages are short, server-generated strings (Kea API error text, a
// validation failure description) inserted into a hand-built HTML template,
// not general-purpose HTML rendering -- pulling in a full HTML-escaping
// library for this one call site isn't worth the extra dependency.
fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

// ─── Data Structures ───

// These two enums are the exact response shape of POST /api/dhcp/check (see
// check_dhcp_conflict below): the `tag = "status"` serde attribute means each
// variant serializes as e.g. `{"status": "found", "output": "..."}`, so the
// frontend can discriminate on one flat "status" string instead of
// interpreting a nested Rust-shaped enum. Conflict and client are separate
// enums (not one shared status type) because they come from two independent
// checks the probe container runs (a network DHCP-conflict scan and a
// dhclient dry-run) that can disagree with each other.
#[derive(Debug, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
enum DhcpConflictCheckStatus {
    // `output` stays the bare Server Identifier IP for backward compatibility
    // with the existing `data.conflict.output` usage in dhcp.html. `details`
    // is additive: the extra identifying fields nmap's
    // broadcast-dhcp-discover script reports for the same offer (Router,
    // DNS, lease time, ...), so the Admin UI can show an operator the same
    // "who is this other server" context that was previously only visible
    // by reading the raw probe container logs. Populated by
    // extract_dhcp_offer_details; empty (never absent, so the frontend
    // never has to null-check the field itself) when the full nmap text
    // had none of the known labels.
    Found {
        output: String,
        details: Vec<DhcpProbeDetail>,
    },
    NotFound,
    Unavailable {
        reason: String,
    },
}

// One nmap broadcast-dhcp-discover field (e.g. `label: "Router", value:
// "192.168.1.1"`), serialized as-is for the Admin UI's details list. Kept as
// a plain label/value pair rather than named struct fields per known label,
// since the set of fields present varies per DHCP server and the frontend
// only ever needs to render "label: value" rows in order.
#[derive(Debug, Serialize, Clone, PartialEq, Eq)]
struct DhcpProbeDetail {
    label: String,
    value: String,
}

#[derive(Debug, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
enum DhcpClientCheckStatus {
    // `details` is additive, same rationale as DhcpConflictCheckStatus::Found's
    // own `details` field above: dhclient's own -v transcript (`output`) only
    // ever shows the DHCPDISCOVER/OFFER/REQUEST/ACK/bound protocol exchange,
    // never the negotiated lease's actual fields (router, DNS, lease time,
    // ...) -- those come from a separate source (the dhclient leases file,
    // see extract_dhcp_lease_details) and are populated here so a SUCCESSFUL
    // dry-run is as informative as a found-conflict result already is, not
    // just a bare "it worked". Always present (never absent) so the frontend
    // never has to null-check the field; empty when the leases file had none
    // of the known fields. `Failed` intentionally has no `details`: a failed
    // dry-run never receives a DHCPACK, so dhclient never writes a lease
    // block at all -- there is no partial lease data to extract in that case
    // (confirmed against a real failed run), unlike a conflict scan's
    // `Found`, which always has full DHCPOFFER data available.
    Passed {
        output: String,
        details: Vec<DhcpProbeDetail>,
    },
    Failed {
        output: String,
    },
    Unavailable {
        reason: String,
    },
}

#[derive(Debug)]
struct DhcpCheckReport {
    conflict: DhcpConflictCheckStatus,
    client: DhcpClientCheckStatus,
}

impl DhcpCheckReport {
    // Match arm order IS the priority order, most severe first: a found
    // conflict always wins regardless of the client check's own result
    // (a rogue DHCP server on the LAN matters even if this host's own
    // dhclient dry-run happened to pass), and either check being
    // "unavailable" (the probe container itself failed) outranks a merely
    // "failed" client check, since an operator can't trust a failed result
    // they can't distinguish from "never actually ran".
    fn overall_status(&self) -> &'static str {
        match (&self.conflict, &self.client) {
            (DhcpConflictCheckStatus::Found { .. }, _) => "conflict_found",
            (DhcpConflictCheckStatus::Unavailable { .. }, _) => "unavailable",
            (_, DhcpClientCheckStatus::Unavailable { .. }) => "unavailable",
            (_, DhcpClientCheckStatus::Failed { .. }) => "client_failed",
            (_, DhcpClientCheckStatus::Passed { .. }) => "verified",
        }
    }
}

// Subnet/DhcpOption/Lease/Reservation are the read-model shown on the
// /dhcp settings page -- parsed out of Kea's own JSON config/lease shape by
// parse_subnet_entry/fetch_leases/parse_reservation_entry further down, not
// a direct deserialization of it. Kea's real JSON is far richer
// (option-data arrays keyed by name-or-code, nested pool ranges, etc.);
// these structs only carry what the Admin UI template actually renders via
// Tera's Serialize-based context (see dhcp_page's ctx.insert calls below).
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Subnet {
    pub id: u32,
    pub subnet: String,
    pub pool_start: String,
    pub pool_end: String,
    pub gateway: String,
    pub dns_primary: String,
    pub dns_secondary: String,
    pub ntp_servers: String,
    pub lease_time: u32,
    pub domain: String,
    pub custom_options: Vec<DhcpOption>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct DhcpOption {
    pub code: u16,
    pub data: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Lease {
    pub subnet_id: u32,
    pub ip: String,
    pub mac: String,
    pub hostname: String,
    pub expires: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Reservation {
    pub subnet_id: u32,
    pub ip: String,
    pub mac: String,
    pub hostname: String,
}

// ─── Form Structs ───
//
// Every field arrives (and is kept) as a raw String, even ones with an
// obvious typed meaning like lease_time -- deserializing straight to u32
// would make axum's Form extractor reject a malformed value with a bare
// 422 before this code ever runs, instead of validate_dhcp_form's own
// specific, uniform BAD_REQUEST handling further down. AddSubnetForm and
// UpdateSubnetForm are separate structs (not one form with an
// Option<id>) because only an update targets an existing subnet id; a new
// subnet's id is assigned by add_subnet itself (see its "next_id" logic),
// never supplied by the operator.

// Submitted from the "add subnet" form on /dhcp: creates a brand-new Kea
// subnet4 entry (see add_subnet). No id field -- add_subnet assigns the next
// free id itself, since a new subnet doesn't have one yet.
#[derive(Deserialize)]
pub struct AddSubnetForm {
    pub csrf_token: String,
    pub subnet: String,
    pub pool_start: String,
    pub pool_end: String,
    pub gateway: String,
    pub dns_primary: String,
    pub dns_secondary: String,
    pub ntp_servers: String,
    pub lease_time: String,
    pub domain: String,
}

// Same fields as AddSubnetForm plus `id`, since editing must target one
// specific existing subnet4 entry (see update_subnet).
#[derive(Deserialize)]
pub struct UpdateSubnetForm {
    pub csrf_token: String,
    pub id: u32,
    pub subnet: String,
    pub pool_start: String,
    pub pool_end: String,
    pub gateway: String,
    pub dns_primary: String,
    pub dns_secondary: String,
    pub ntp_servers: String,
    pub lease_time: String,
    pub domain: String,
}

// Deletes a subnet4 entry outright (see remove_subnet) -- irreversible from
// the UI's own state, only recoverable via a Kea config snapshot rollback.
#[derive(Deserialize)]
pub struct RemoveSubnetForm {
    pub csrf_token: String,
    pub id: u32,
}

// Adds one custom DHCP option (by numeric code) to a specific subnet (see
// add_subnet_option) -- distinct from the built-in fields above (gateway,
// DNS, etc.), which map to their own dedicated Kea option codes already.
#[derive(Deserialize)]
pub struct AddSubnetOptionForm {
    pub csrf_token: String,
    pub subnet_id: u32,
    pub code: String,
    pub data: String,
}

// Removes one custom DHCP option from a subnet (see remove_subnet_option).
// Both code and data are required (not just code) because Kea's option-data
// array can hold multiple entries for the same code; matching on code+data
// together is how remove_custom_subnet_option finds the exact one to drop.
#[derive(Deserialize)]
pub struct RemoveSubnetOptionForm {
    pub csrf_token: String,
    pub subnet_id: u32,
    pub code: String,
    pub data: String,
}

// Static host reservations (fixed IP for a given MAC), independent of the
// subnet forms above -- these submit through add_reservation/
// remove_reservation, which match existing entries by normalized MAC.
#[derive(Deserialize)]
pub struct AddReservationForm {
    pub csrf_token: String,
    pub subnet_id: u32,
    pub mac: String,
    pub ip: String,
    pub hostname: String,
}

#[derive(Deserialize)]
pub struct RemoveReservationForm {
    pub csrf_token: String,
    pub subnet_id: u32,
    pub mac: String,
}

// Releases an active (dynamically-assigned, non-reserved) lease early --
// distinct from removing a reservation, which is a permanent config change
// rather than a one-off runtime action against lease4-del.
#[derive(Deserialize)]
pub struct ReleaseLeaseForm {
    pub csrf_token: String,
    pub ip: String,
}

// Toggles Kea's DDNS master switch (Dhcp4.dhcp-ddns.enable-updates)
// independently of the DHCP mode (issue #1076). `enabled` is submitted as an
// explicit "true"/"false" string rather than an HTML checkbox, so an "off"
// state is a real submitted value instead of an omitted field.
#[derive(Deserialize)]
pub struct DdnsToggleForm {
    pub csrf_token: String,
    pub enabled: String,
}

// The remaining forms below configure DHCP at the whole-stack level (which
// backend runs at all, and dnsmasq-proxy's relay settings), not a specific
// subnet/reservation/lease -- see update_dhcp_mode/update_dhcp_proxy.
#[derive(Deserialize)]
pub struct UpdateDhcpModeForm {
    pub csrf_token: String,
    pub dhcp_mode: String,
}

#[derive(Deserialize)]
pub struct UpdateDhcpProxyForm {
    pub csrf_token: String,
    pub dhcp_subnet_start: String,
    pub dhcp_dns_primary: String,
    pub dhcp_dns_secondary: String,
    pub upstream_dhcp_ip: String,
    // Issue #450: additional optional dnsmasq relay/proxy fields. All are
    // allowed to be empty (the feature they configure is simply not
    // rendered into dnsmasq.conf, see entrypoint.sh's
    // `_dhcp_proxy_render_optional_directives`); only non-empty values are
    // validated for shape.
    #[serde(default)]
    pub dhcp_proxy_interface: String,
    #[serde(default)]
    pub dhcp_proxy_router: String,
    #[serde(default)]
    pub dhcp_ntp_servers: String,
    #[serde(default)]
    pub dhcp_proxy_domain: String,
    #[serde(default)]
    pub dhcp_proxy_boot_filename: String,
    #[serde(default)]
    pub dhcp_proxy_boot_server: String,
    #[serde(default)]
    pub dhcp_proxy_custom_options: String,
}

#[derive(Deserialize)]
pub struct RollbackKeaSnapshotForm {
    pub csrf_token: String,
    pub snapshot_id: String,
}

// A known-good Kea config snapshot as rendered in the Admin UI (#614). Only
// the id (for the rollback form) and a Unix-epoch-seconds timestamp (for
// client-side display via the same `Intl.DateTimeFormat`/`.dhcp-expiry`
// pattern `formatDhcpExpiries()` already uses for lease expiries) are
// exposed -- never the config payload itself, which can be arbitrarily large.
#[derive(Debug, Serialize)]
struct KeaSnapshotSummary {
    id: String,
    created_unix: u64,
}

// ─── Handlers ───

// Renders the whole /dhcp settings page: current mode, dnsmasq-proxy fields,
// and (only when Kea is actually reachable) the live subnet/lease/
// reservation tables plus known-good config snapshots. Never errors -- if
// Kea is unreachable or a fetch fails, the affected tables render empty
// instead of taking down the whole page (see the else-branch and the
// `unwrap_or_default()` calls below).
pub async fn dhcp_page(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Html<String> {
    let mut ctx = Context::new();
    let dhcp_mode = state.config.effective_dhcp_mode();
    let dhcp_has_kea = dhcp_mode.is_kea();
    let dhcp_dns_primary = state.config.effective_dhcp_dns_primary();
    let dhcp_dns_secondary = state.config.effective_dhcp_dns_secondary();
    let dhcp_ntp_servers = state.config.effective_dhcp_ntp_servers();
    let dhcp_proxy_subnet_start = state.config.effective_dhcp_proxy_subnet_start();
    let dhcp_upstream_dhcp_ip = state.config.effective_dhcp_upstream_dhcp_ip();
    let dhcp_proxy_interface = state.config.effective_dhcp_proxy_interface();
    let dhcp_proxy_router = state.config.effective_dhcp_proxy_router();
    let dhcp_proxy_domain = state.config.effective_dhcp_proxy_domain();
    let dhcp_proxy_boot_filename = state.config.effective_dhcp_proxy_boot_filename();
    let dhcp_proxy_boot_server = state.config.effective_dhcp_proxy_boot_server();
    let dhcp_proxy_custom_options_form =
        custom_options_storage_to_form(&state.config.effective_dhcp_proxy_custom_options());
    ctx.insert("active_page", "dhcp");
    ctx.insert("dhcp_mode", &dhcp_mode.as_str());
    ctx.insert("dhcp_has_kea", &dhcp_has_kea);
    ctx.insert("dhcp_api_url", &state.config.dhcp_api_url);
    ctx.insert("dhcp_dns_primary", &dhcp_dns_primary);
    ctx.insert("dhcp_dns_secondary", &dhcp_dns_secondary);
    ctx.insert("dhcp_ntp_servers", &dhcp_ntp_servers);
    ctx.insert("dhcp_proxy_subnet_start", &dhcp_proxy_subnet_start);
    ctx.insert("dhcp_upstream_dhcp_ip", &dhcp_upstream_dhcp_ip);
    ctx.insert("dhcp_proxy_interface", &dhcp_proxy_interface);
    ctx.insert("dhcp_proxy_router", &dhcp_proxy_router);
    ctx.insert("dhcp_proxy_domain", &dhcp_proxy_domain);
    ctx.insert("dhcp_proxy_boot_filename", &dhcp_proxy_boot_filename);
    ctx.insert("dhcp_proxy_boot_server", &dhcp_proxy_boot_server);
    ctx.insert(
        "dhcp_proxy_custom_options_form",
        &dhcp_proxy_custom_options_form,
    );
    crate::routes::insert_csrf_token(&mut ctx, &headers);

    // Leases and reservations don't depend on each other, so they're
    // fetched concurrently via tokio::join! rather than two sequential
    // awaits -- this page can otherwise feel slow on a Kea instance with
    // many leases.
    if kea_api_available(
        state.config.effective_dhcp_mode(),
        &state.config.dhcp_api_url,
    ) {
        // One config-get feeds both the subnet list and the DDNS toggle
        // state (issue #1076), rather than a second round-trip just for
        // enable-updates. Leases and reservations are independent and still
        // fetched concurrently below.
        let config = fetch_dhcp_config(&state).await.ok();
        let subnets = config
            .as_ref()
            .map(fetch_subnets_from_config)
            .unwrap_or_default();
        let ddns_enabled = config.as_ref().map(config_ddns_enabled).unwrap_or(false);
        let (leases, reservations) =
            tokio::join!(fetch_leases(&state), fetch_all_reservations(&state));
        ctx.insert("subnets", &subnets);
        ctx.insert("dhcp_ddns_enabled", &ddns_enabled);
        ctx.insert("leases", &leases.unwrap_or_default());
        ctx.insert("reservations", &reservations.unwrap_or_default());
    } else {
        let empty: Vec<Subnet> = Vec::new();
        ctx.insert("subnets", &empty);
        ctx.insert("dhcp_ddns_enabled", &false);
        ctx.insert("leases", &Vec::<Lease>::new());
        ctx.insert("reservations", &Vec::<Reservation>::new());
    }

    ctx.insert("kea_snapshots", &fetch_kea_snapshot_summaries(&state));
    ctx.insert(
        "kea_snapshot_retention",
        &state.config.kea_keep_known_good_configs,
    );

    crate::routes::render(&state.templates, "dhcp.html", &ctx, state.config.dev_mode)
}

// Gate used by every subnet/option/reservation/lease mutation route (add_subnet,
// remove_reservation, release_lease, etc.): rejects the request up front with
// a 409 if the stack isn't actually running in Kea mode, rather than letting
// it fail deeper inside a Kea API call whose error message wouldn't clearly
// say "you're not in Kea mode at all".
fn require_kea_mode(state: &AppState) -> Result<(), DhcpError> {
    if kea_api_available(
        state.config.effective_dhcp_mode(),
        &state.config.dhcp_api_url,
    ) {
        Ok(())
    } else {
        Err(DhcpError::conflict(
            "DHCP mutations require Kea mode with a configured Kea API URL.",
        ))
    }
}

// Both conditions are required: DhcpMode can be set to Kea without an API
// URL configured yet (e.g. right after switching modes, before the operator
// has filled in dhcp_api_url), and that half-configured state must still be
// treated as "Kea not available" everywhere in this file.
fn kea_api_available(mode: crate::config::DhcpMode, api_url: &str) -> bool {
    mode.is_kea() && !api_url.is_empty()
}

// Parses the dhcp_mode form field from update_dhcp_mode into the typed enum.
// Unrecognized input (including empty/garbage) returns None rather than
// defaulting to one of the three modes, so update_dhcp_mode can reject a bad
// submission with a clear error instead of silently switching to an
// unintended mode.
fn parse_dhcp_mode_input(value: &str) -> Option<crate::config::DhcpMode> {
    match value.trim().to_ascii_lowercase().as_str() {
        "disabled" => Some(crate::config::DhcpMode::Disabled),
        "kea" => Some(crate::config::DhcpMode::Kea),
        "dnsmasq-proxy" => Some(crate::config::DhcpMode::DnsmasqProxy),
        _ => None,
    }
}

// Turns a start_service failure into a DhcpError, adding actionable
// create-the-container guidance when the underlying cause is a 404 (see
// docker_client::is_container_not_created's own comment for why that
// specific status code means "never created", not "crashed"). Without this,
// an operator switching to a DHCP mode that was never active before saw only
// "Failed to start 'dhcp-proxy'" with no indication of what to actually do
// (issue #1068 item 6) -- the docker-socket-proxy allowlist this module
// talks through has no create capability, so the Admin UI itself cannot
// bring the missing container up; the operator (or the host's
// lancache-converge.timer, once installed) has to run `docker compose up`
// with the matching profile at least once.
fn start_service_error(err: anyhow::Error, service_name: &str, profile: &str) -> DhcpError {
    if docker_client::is_container_not_created(&err) {
        DhcpError::config_error(format!(
            "The '{service_name}' container has not been created yet: this Compose stack was \
             never started with the '{profile}' profile active, so Docker has no container for \
             the Admin UI to start (it is only allowed to start/stop existing containers, never \
             create new ones). Fix: in the lancache-ng install directory, run \
             `docker compose --profile {profile} up -d {service_name}` once to create it, then \
             switch DHCP mode again here. If a `lancache-converge.timer` is installed, it will \
             also pick this up automatically within a few minutes after that."
        ))
    } else {
        DhcpError::config_error(format!("{err:#}"))
    }
}

async fn reconcile_dhcp_mode(
    state: &AppState,
    mode: crate::config::DhcpMode,
) -> Result<(), DhcpError> {
    // Only predeclared Compose services are controlled here. Missing profile
    // containers stay a visible operator error instead of silently diverging
    // from the UI's persisted DHCP mode.
    match mode {
        crate::config::DhcpMode::Disabled => {
            docker_client::stop_service_if_present(&state.docker, "dhcp")
                .await
                .map_err(|err| DhcpError::config_error(format!("{err:#}")))?;
            docker_client::stop_service_if_present(&state.docker, "dhcp-proxy")
                .await
                .map_err(|err| DhcpError::config_error(format!("{err:#}")))?;
        }
        crate::config::DhcpMode::Kea => {
            docker_client::stop_service_if_present(&state.docker, "dhcp-proxy")
                .await
                .map_err(|err| DhcpError::config_error(format!("{err:#}")))?;
            docker_client::start_service(&state.docker, "dhcp")
                .await
                .map_err(|err| start_service_error(err, "dhcp", "dhcp-kea"))?;
        }
        crate::config::DhcpMode::DnsmasqProxy => {
            docker_client::stop_service_if_present(&state.docker, "dhcp")
                .await
                .map_err(|err| DhcpError::config_error(format!("{err:#}")))?;
            docker_client::start_service(&state.docker, "dhcp-proxy")
                .await
                .map_err(|err| start_service_error(err, "dhcp-proxy", "dhcp-proxy"))?;
        }
    }
    Ok(())
}

// Best-effort pre-flight check that update_dhcp_mode runs BEFORE
// reconcile_dhcp_mode (i.e. before any dhcp/dhcp-proxy container is actually
// stopped/started). It exercises the exact same directory the later
// persist_ui_settings write will target -- create the parent dir, write a
// throwaway probe file into it, remove the probe file -- without touching
// the real settings file, so a full or read-only `ui-data` volume (the
// common failure mode from #671) is caught up front instead of surfacing
// only after the Docker mutation already happened.
//
// This does not fully close the gap: the filesystem can still fail between
// this check and persist_ui_settings' real write (e.g. the volume fills up
// in that exact window), which is why update_dhcp_mode also treats a
// persist_ui_settings failure as a trigger to roll the Docker mutation back
// (see the `rollback` handling there) rather than relying on this check
// alone.
fn check_settings_dir_writable(target: &Path) -> Result<(), DhcpError> {
    let parent = target.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent).map_err(|err| {
        DhcpError::config_error(format!(
            "DHCP settings directory {} is not writable: {}",
            parent.display(),
            err
        ))
    })?;

    // Nanosecond-stamped alongside the process id so concurrent requests (or
    // a leftover probe file from a killed process) never collide on the same
    // probe filename within this directory.
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or_default();
    let probe_path = parent.join(format!(
        ".dhcp-mode-write-check-{}-{}",
        std::process::id(),
        stamp
    ));
    fs::write(&probe_path, b"").map_err(|err| {
        DhcpError::config_error(format!(
            "DHCP settings file {} is not writable: {}",
            target.display(),
            err
        ))
    })?;
    // Cleanup is best-effort: leaving a stray zero-byte probe file behind on
    // the rare removal failure is harmless and must not turn a successful
    // writability check into a reported error.
    let _ = fs::remove_file(&probe_path);
    Ok(())
}

// Writes the whole-stack DHCP settings (mode, dnsmasq-proxy fields) to the
// UI's own settings file, which entrypoint.sh reads on container start to
// decide what to run. Only non-empty values are written, so a field the
// operator never configured stays absent rather than becoming an explicit
// empty string. Written via a temp-file-then-rename so a crash mid-write
// can never leave a half-written settings file behind for entrypoint.sh to
// read on the next start.
fn persist_ui_settings(state: &AppState, values: &[(&str, String)]) -> Result<(), DhcpError> {
    write_ui_settings_file(Path::new(&state.config.ui_settings_file), values)
}

// Carries through every current DHCP_* value unchanged (same reasoning as
// update_dhcp_proxy's own persist_ui_settings call) while writing the two
// release-channel/scheduled-update keys routes/setup.rs's
// update_stack_settings actually lets the operator change. `pub(crate)`
// rather than a routes/setup.rs-local copy of write_ui_settings_file, so
// there is exactly one place that owns this file's whole-write contract
// instead of two whitelists that could silently drift apart.
pub(crate) fn persist_stack_settings(
    state: &AppState,
    lancache_image_channel: &str,
    auto_update_enabled: bool,
) -> Result<(), DhcpError> {
    write_ui_settings_file(
        Path::new(&state.config.ui_settings_file),
        &[
            (
                "DHCP_MODE",
                state.config.effective_dhcp_mode().as_str().to_string(),
            ),
            (
                "DHCP_SUBNET_START",
                state.config.effective_dhcp_proxy_subnet_start(),
            ),
            (
                "DHCP_DNS_PRIMARY",
                state.config.effective_dhcp_dns_primary(),
            ),
            (
                "DHCP_DNS_SECONDARY",
                state.config.effective_dhcp_dns_secondary(),
            ),
            (
                "UPSTREAM_DHCP_IP",
                state.config.effective_dhcp_upstream_dhcp_ip(),
            ),
            (
                "DHCP_NTP_SERVERS",
                state.config.effective_dhcp_ntp_servers(),
            ),
            (
                "DHCP_PROXY_INTERFACE",
                state.config.effective_dhcp_proxy_interface(),
            ),
            (
                "DHCP_PROXY_ROUTER",
                state.config.effective_dhcp_proxy_router(),
            ),
            (
                "DHCP_PROXY_DOMAIN",
                state.config.effective_dhcp_proxy_domain(),
            ),
            (
                "DHCP_PROXY_BOOT_FILENAME",
                state.config.effective_dhcp_proxy_boot_filename(),
            ),
            (
                "DHCP_PROXY_BOOT_SERVER",
                state.config.effective_dhcp_proxy_boot_server(),
            ),
            (
                "DHCP_PROXY_CUSTOM_OPTIONS",
                state.config.effective_dhcp_proxy_custom_options(),
            ),
            ("LANCACHE_IMAGE_CHANNEL", lancache_image_channel.to_string()),
            (
                "AUTO_UPDATE_ENABLED",
                if auto_update_enabled { "1" } else { "0" }.to_string(),
            ),
        ],
    )
}

// Pure filesystem half of persist_ui_settings, split out so unit tests can
// exercise the real write/rename behavior against a temp path without
// needing a full AppState (which otherwise requires a live Docker
// connection to construct -- see the docker_client-backed reconcile_dhcp_mode
// this file also defines).
fn write_ui_settings_file(target: &Path, values: &[(&str, String)]) -> Result<(), DhcpError> {
    let mut map = BTreeMap::new();
    for (key, value) in values {
        let trimmed = value.trim();
        if !trimmed.is_empty() {
            map.insert((*key).to_string(), trimmed.to_string());
        }
    }

    // Iterates this fixed, explicit key list rather than `map`'s own keys so
    // the settings file always comes out in the same, predictable order and
    // never accidentally persists an unrelated key -- `values` is caller-
    // controlled input, not the full set of possible settings.
    let mut content = String::new();
    for key in [
        "DHCP_MODE",
        "DHCP_SUBNET_START",
        "DHCP_DNS_PRIMARY",
        "DHCP_DNS_SECONDARY",
        "UPSTREAM_DHCP_IP",
        "DHCP_NTP_SERVERS",
        // Issue #450's optional relay/PXE fields -- this key list is the
        // authoritative whitelist of what this file can ever contain, so a
        // future field must be added here too or persist_ui_settings will
        // silently drop it even if the caller passes it in `values`.
        "DHCP_PROXY_INTERFACE",
        "DHCP_PROXY_ROUTER",
        "DHCP_PROXY_DOMAIN",
        "DHCP_PROXY_BOOT_FILENAME",
        "DHCP_PROXY_BOOT_SERVER",
        "DHCP_PROXY_CUSTOM_OPTIONS",
        // #819: release channel / scheduled-update settings, written by
        // routes/setup.rs's update_stack_settings (via persist_stack_settings
        // above). Consumed entirely on the host by setup.sh's
        // lancache-converge.service, never inside this container -- see that
        // function's doc comment for the full read path.
        "LANCACHE_IMAGE_CHANNEL",
        "AUTO_UPDATE_ENABLED",
    ] {
        if let Some(value) = map.get(key) {
            content.push_str(key);
            content.push('=');
            content.push_str(value);
            content.push('\n');
        }
    }

    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|err| {
            DhcpError::config_error(format!(
                "Failed to prepare settings directory {}: {}",
                parent.display(),
                err
            ))
        })?;
    }
    let tmp_path = target.with_extension("tmp");
    fs::write(&tmp_path, content).map_err(|err| {
        DhcpError::config_error(format!(
            "Failed to persist DHCP mode to {}: {}",
            tmp_path.display(),
            err
        ))
    })?;
    fs::rename(&tmp_path, target).map_err(|err| {
        DhcpError::config_error(format!(
            "Failed to finalize DHCP mode settings at {}: {}",
            target.display(),
            err
        ))
    })
}

// Switches the whole stack between disabled/Kea/dnsmasq-proxy DHCP: starts
// and stops the matching Docker services (reconcile_dhcp_mode), then
// persists the new mode plus every other current DHCP setting so a later
// container restart comes back up in the same mode instead of reverting to
// whatever DHCP_MODE was in the original env file.
//
// Ordering here is deliberate and has two guards against the two ways this
// can go wrong (#671):
//   1. Before reconcile_dhcp_mode runs at all, check_settings_dir_writable
//      catches the common failure mode (full/read-only ui-data volume, bad
//      permissions) up front, so no Docker container is touched for a save
//      that can't possibly complete.
//   2. If persist_ui_settings still fails afterward (e.g. the volume filled
//      up in the window between the check and the real write), the DHCP
//      containers have already switched to the new mode but
//      effective_dhcp_mode() would keep reporting the previous one. Rather
//      than leave that divergence for an operator to notice, this
//      best-effort rolls the Docker mutation back to the previous mode and
//      surfaces both errors if the rollback attempt itself also fails.
pub async fn update_dhcp_mode(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<UpdateDhcpModeForm>,
) -> Result<Redirect, DhcpError> {
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(DhcpError::from)?;
    let mode = parse_dhcp_mode_input(&form.dhcp_mode)
        .ok_or_else(|| DhcpError::conflict("Invalid DHCP mode requested."))?;

    // Captured before any mutation so a later rollback (if persist still
    // fails despite the pre-check below) knows what to reconcile back to.
    let previous_mode = state.config.effective_dhcp_mode();

    check_settings_dir_writable(Path::new(&state.config.ui_settings_file))?;

    reconcile_dhcp_mode(&state, mode).await?;
    // Re-persists every DHCP setting, not just DHCP_MODE: persist_ui_settings
    // overwrites the whole settings file each call, so any field left out
    // here would be dropped from it (and fall back to its original env
    // default on the next container start) even though the operator never
    // touched that field on this particular save.
    let persist_result = persist_ui_settings(
        &state,
        &[
            ("DHCP_MODE", mode.as_str().to_string()),
            (
                "DHCP_SUBNET_START",
                state.config.effective_dhcp_proxy_subnet_start(),
            ),
            (
                "DHCP_DNS_PRIMARY",
                state.config.effective_dhcp_dns_primary(),
            ),
            (
                "DHCP_DNS_SECONDARY",
                state.config.effective_dhcp_dns_secondary(),
            ),
            (
                "UPSTREAM_DHCP_IP",
                state.config.effective_dhcp_upstream_dhcp_ip(),
            ),
            (
                "DHCP_NTP_SERVERS",
                state.config.effective_dhcp_ntp_servers(),
            ),
            // The remaining entries are issue #450's optional relay/PXE
            // fields; update_dhcp_mode never lets an operator edit these
            // directly, so it just carries the current effective value
            // through unchanged rather than losing it on a mode switch.
            (
                "DHCP_PROXY_INTERFACE",
                state.config.effective_dhcp_proxy_interface(),
            ),
            (
                "DHCP_PROXY_ROUTER",
                state.config.effective_dhcp_proxy_router(),
            ),
            (
                "DHCP_PROXY_DOMAIN",
                state.config.effective_dhcp_proxy_domain(),
            ),
            (
                "DHCP_PROXY_BOOT_FILENAME",
                state.config.effective_dhcp_proxy_boot_filename(),
            ),
            (
                "DHCP_PROXY_BOOT_SERVER",
                state.config.effective_dhcp_proxy_boot_server(),
            ),
            (
                "DHCP_PROXY_CUSTOM_OPTIONS",
                state.config.effective_dhcp_proxy_custom_options(),
            ),
            // #819: this route never edits these, but persist_ui_settings
            // overwrites the whole file each call -- carried through
            // unchanged so a DHCP mode switch never silently reverts an
            // operator's release-channel/scheduled-update choice back to its
            // env default (the exact failure class write_ui_settings_file's
            // own comment already warns about for this file in general).
            (
                "LANCACHE_IMAGE_CHANNEL",
                state.config.effective_lancache_image_channel_override(),
            ),
            (
                "AUTO_UPDATE_ENABLED",
                if state.config.effective_auto_update_enabled() {
                    "1"
                } else {
                    "0"
                }
                .to_string(),
            ),
        ],
    );

    if let Err(persist_err) = persist_result {
        // mode == previous_mode only when the operator re-submits the mode
        // they're already on; reconcile_dhcp_mode is then a no-op repeat of
        // the current state, so there is nothing to roll back to and doing
        // so would just repeat the exact same persist failure.
        if mode != previous_mode {
            if let Err(rollback_err) = reconcile_dhcp_mode(&state, previous_mode).await {
                return Err(DhcpError::config_error(format!(
                    "Failed to persist DHCP mode ({persist_err}), and rolling the '{}' containers \
                     back to the previous '{}' mode also failed ({rollback_err}). DHCP containers \
                     are now running in '{}' mode but the UI may still report '{}' until this is \
                     resolved manually.",
                    mode.as_str(),
                    previous_mode.as_str(),
                    mode.as_str(),
                    previous_mode.as_str()
                )));
            }
        }
        return Err(persist_err);
    }

    Ok(Redirect::to("/dhcp"))
}

// Validates and saves the dnsmasq-proxy mode's settings (relay subnet, DNS,
// upstream DHCP server, plus issue #450's optional PXE/relay fields). Every
// field is checked here so a typo is caught immediately with a specific
// error message, rather than only surfacing later when dnsmasq itself
// rejects the rendered config on container start.
pub async fn update_dhcp_proxy(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<UpdateDhcpProxyForm>,
) -> Result<Redirect, DhcpError> {
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(DhcpError::from)?;
    if form.dhcp_subnet_start.trim().is_empty() || parse_ipv4(&form.dhcp_subnet_start).is_none() {
        return Err(DhcpError::from(StatusCode::BAD_REQUEST));
    }
    if parse_ipv4(&form.dhcp_dns_primary).is_none() {
        return Err(DhcpError::from(StatusCode::BAD_REQUEST));
    }
    if !form.dhcp_dns_secondary.trim().is_empty() && parse_ipv4(&form.dhcp_dns_secondary).is_none()
    {
        return Err(DhcpError::from(StatusCode::BAD_REQUEST));
    }
    if parse_ipv4(&form.upstream_dhcp_ip).is_none() {
        return Err(DhcpError::from(StatusCode::BAD_REQUEST));
    }

    // Issue #450: additional optional fields. Each is only validated when
    // non-empty -- leaving one blank simply means entrypoint.sh renders no
    // directive for it (see `_dhcp_proxy_render_optional_directives`), it is
    // never a form error. This is friendly early feedback only; the
    // authoritative fail-closed gate is still `dnsmasq --test` plus the
    // known-good-snapshot rollback in services/dhcp-proxy/entrypoint.sh.
    if !form.dhcp_proxy_interface.trim().is_empty()
        && !is_valid_interface_name(&form.dhcp_proxy_interface)
    {
        return Err(DhcpError::new(
            StatusCode::BAD_REQUEST,
            "Invalid relay/proxy listen interface: use only letters, digits, '.', '-', or '_'.",
        ));
    }
    if !form.dhcp_proxy_router.trim().is_empty() && parse_ipv4(&form.dhcp_proxy_router).is_none() {
        return Err(DhcpError::new(
            StatusCode::BAD_REQUEST,
            "Invalid router/gateway option: must be a valid IPv4 address.",
        ));
    }
    if !form.dhcp_ntp_servers.trim().is_empty()
        && !form
            .dhcp_ntp_servers
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .all(|s| parse_ipv4(s).is_some())
    {
        return Err(DhcpError::new(
            StatusCode::BAD_REQUEST,
            "Invalid NTP servers option: must be a comma-separated list of IPv4 addresses.",
        ));
    }
    if !form.dhcp_proxy_domain.trim().is_empty() && !is_valid_domain_name(&form.dhcp_proxy_domain) {
        return Err(DhcpError::new(
            StatusCode::BAD_REQUEST,
            "Invalid domain option: use a plain DNS domain name (letters, digits, '-', '.').",
        ));
    }
    if !form.dhcp_proxy_boot_filename.trim().is_empty()
        && !is_valid_boot_filename(&form.dhcp_proxy_boot_filename)
    {
        return Err(DhcpError::new(
            StatusCode::BAD_REQUEST,
            "Invalid PXE boot filename: no whitespace, commas, or control characters.",
        ));
    }
    if !form.dhcp_proxy_boot_server.trim().is_empty()
        && parse_ipv4(&form.dhcp_proxy_boot_server).is_none()
    {
        return Err(DhcpError::new(
            StatusCode::BAD_REQUEST,
            "Invalid PXE boot server address: must be a valid IPv4 address.",
        ));
    }
    // Cross-field check (not just a per-field one like the validations
    // above): a boot server with no filename is meaningless to a PXE client
    // and would render an incomplete `dhcp-boot=` directive, so this is
    // rejected even though both fields individually passed their own
    // per-field validation above.
    if !form.dhcp_proxy_boot_server.trim().is_empty()
        && form.dhcp_proxy_boot_filename.trim().is_empty()
    {
        return Err(DhcpError::new(
            StatusCode::BAD_REQUEST,
            "A PXE boot server address requires a boot filename; a server address alone is not meaningful.",
        ));
    }
    let custom_options_storage = parse_custom_options_form(&form.dhcp_proxy_custom_options)
        .map_err(|message| {
            DhcpError::new(
                StatusCode::BAD_REQUEST,
                format!("Invalid custom DHCP option: {message}"),
            )
        })?;

    // DHCP_MODE is carried through unchanged (this route never switches
    // modes, only edits the dnsmasq-proxy settings) -- it must still be
    // included here since persist_ui_settings overwrites the whole file,
    // same reasoning as update_dhcp_mode's own re-persist above.
    persist_ui_settings(
        &state,
        &[
            (
                "DHCP_MODE",
                state.config.effective_dhcp_mode().as_str().to_string(),
            ),
            ("DHCP_SUBNET_START", form.dhcp_subnet_start),
            ("DHCP_DNS_PRIMARY", form.dhcp_dns_primary),
            ("DHCP_DNS_SECONDARY", form.dhcp_dns_secondary),
            ("UPSTREAM_DHCP_IP", form.upstream_dhcp_ip),
            ("DHCP_NTP_SERVERS", form.dhcp_ntp_servers.trim().to_string()),
            (
                "DHCP_PROXY_INTERFACE",
                form.dhcp_proxy_interface.trim().to_string(),
            ),
            (
                "DHCP_PROXY_ROUTER",
                form.dhcp_proxy_router.trim().to_string(),
            ),
            (
                "DHCP_PROXY_DOMAIN",
                form.dhcp_proxy_domain.trim().to_string(),
            ),
            (
                "DHCP_PROXY_BOOT_FILENAME",
                form.dhcp_proxy_boot_filename.trim().to_string(),
            ),
            (
                "DHCP_PROXY_BOOT_SERVER",
                form.dhcp_proxy_boot_server.trim().to_string(),
            ),
            ("DHCP_PROXY_CUSTOM_OPTIONS", custom_options_storage),
            // #819: same carry-through reasoning as update_dhcp_mode above --
            // this route never edits these either.
            (
                "LANCACHE_IMAGE_CHANNEL",
                state.config.effective_lancache_image_channel_override(),
            ),
            (
                "AUTO_UPDATE_ENABLED",
                if state.config.effective_auto_update_enabled() {
                    "1"
                } else {
                    "0"
                }
                .to_string(),
            ),
        ],
    )?;
    Ok(Redirect::to("/dhcp"))
}

// ─── dnsmasq relay/proxy field validators (issue #450) ───

// Network interface names are short host-controlled identifiers (e.g.
// `eth0`, `br-lan.100`), never arbitrary text -- reject anything containing
// characters that would be meaningless (or unsafe to place unquoted into
// dnsmasq's `interface=` directive).
fn is_valid_interface_name(raw: &str) -> bool {
    let name = raw.trim();
    !name.is_empty()
        && name.len() <= 64
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
}

// Checks the whole dotted name against DNS's own length rules (each label
// max 63 bytes, the full name max 253) before checking each label's
// characters via is_valid_dns_label below.
fn is_valid_domain_name(raw: &str) -> bool {
    let name = raw.trim();
    !name.is_empty()
        && name.len() <= 253
        && name
            .split('.')
            .all(|label| !label.is_empty() && label.len() <= 63 && is_valid_dns_label(label))
}

// RFC 1123 label syntax: letters/digits/hyphens only, and a hyphen may not
// open or close a label (`-lan` / `lan-` are not valid DNS labels, even
// though every individual character in them is allowed). Enforced here
// because this validator's caller only checks character set and length per
// label -- rejecting a bad leading/trailing hyphen must happen per-label,
// not on the domain as a whole, since `is_valid_domain_name` calls this once
// per `.`-separated segment.
fn is_valid_dns_label(label: &str) -> bool {
    let bytes = label.as_bytes();
    let alnum_or_hyphen = |b: u8| b.is_ascii_alphanumeric() || b == b'-';
    bytes.iter().all(|&b| alnum_or_hyphen(b))
        && bytes.first().is_none_or(|&b| b != b'-')
        && bytes.last().is_none_or(|&b| b != b'-')
}

// PXE boot filenames are paths like `pxelinux.0` or `efi/bootx64.efi`. They
// are rendered straight into `dhcp-boot=<filename>,,<server>`, a comma-
// delimited directive, so a comma in the filename would silently misparse
// into the server-name field instead of erroring -- reject it explicitly
// rather than let that happen. Newlines are rejected as they are elsewhere
// in this file (would corrupt the rendered config file).
fn is_valid_boot_filename(raw: &str) -> bool {
    let name = raw.trim();
    !name.is_empty()
        && name.len() <= 255
        && !name
            .chars()
            .any(|c| c.is_whitespace() || c == ',' || c.is_control())
}

// Parses the Admin UI's one-entry-per-line custom option textarea
// (`CODE:VALUE` per line) into the `;`-separated single-line form persisted
// to DHCP_PROXY_CUSTOM_OPTIONS (env/settings files are simple `KEY=value`
// lines with no embedded newlines, matching the constraint
// `validate_custom_dhcp_option_data` already enforces for Kea's per-subnet
// custom options). Reuses the exact same code/data validators as Kea's
// custom subnet options, including the exclusion of codes 3/6/15/42/119 --
// those are already covered by this page's dedicated router/DNS/domain/NTP
// fields, so routing them through the free-form custom list instead would
// create two divergent ways to set the same option.
fn parse_custom_options_form(raw: &str) -> Result<String, String> {
    let mut rendered = Vec::new();
    for (line_no, line) in raw.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let (code_raw, data_raw) = line
            .split_once(':')
            .ok_or_else(|| format!("line {}: expected CODE:VALUE", line_no + 1))?;
        let code = parse_custom_dhcp_option_code(code_raw)
            .map_err(|message| format!("line {}: {message}", line_no + 1))?;
        let data = validate_custom_dhcp_option_data(data_raw)
            .map_err(|message| format!("line {}: {message}", line_no + 1))?;
        // ';' is the top-level entry separator for the persisted
        // DHCP_PROXY_CUSTOM_OPTIONS value (see the storage format doc
        // comment above and entrypoint.sh's `_dhcp_proxy_render_custom_options`);
        // allowing it inside a value would let one entry's data silently
        // split into two entries on the shell side.
        if data.contains(';') {
            return Err(format!(
                "line {}: option data must not contain ';' (used as the entry separator)",
                line_no + 1
            ));
        }
        rendered.push(format!("{code}:{data}"));
    }
    Ok(rendered.join(";"))
}

// Inverse of the storage join above, for redisplaying the persisted value in
// the Admin UI's textarea as one CODE:VALUE per line.
fn custom_options_storage_to_form(stored: &str) -> String {
    stored
        .split(';')
        .map(str::trim)
        .filter(|entry| !entry.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

// Creates a new Kea subnet4 entry. The new subnet's id is one higher than
// the current highest id (or 1 if there are none yet) -- Kea subnet ids
// just need to be unique, so reusing "max + 1" avoids ever colliding with
// an existing subnet even after subnets have been removed and re-added.
pub async fn add_subnet(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<AddSubnetForm>,
) -> Result<Redirect, DhcpError> {
    require_kea_mode(&state)?;
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(DhcpError::from)?;
    let lease_time = validate_dhcp_form(DhcpFormValidation {
        subnet: &form.subnet,
        pool_start: &form.pool_start,
        pool_end: &form.pool_end,
        gateway: &form.gateway,
        dns_primary: &form.dns_primary,
        dns_secondary: &form.dns_secondary,
        ntp_servers: &form.ntp_servers,
        lease_time: &form.lease_time,
        domain: &form.domain,
    })
    .map_err(DhcpError::from)?;
    // Resolved here, before the sync kea_config_modify closure below (which
    // cannot itself await), so a hostname that doesn't resolve is reported
    // as a clear 400 instead of either reaching Kea unresolved (#670) or
    // requiring build_subnet_options -- called from inside that closure --
    // to become async.
    let ntp_servers = resolve_ntp_servers(&form.ntp_servers)
        .await
        .map_err(|message| DhcpError::new(StatusCode::BAD_REQUEST, message))?;

    kea_config_modify(&state, move |config| {
        // Each `.ok_or(...)?` names exactly which part of the expected
        // `{"Dhcp4": {"subnet4": [...]}}` shape is missing/malformed, rather
        // than one generic "invalid config" error -- useful when debugging a
        // hand-edited or unusually old Kea config that doesn't match what
        // this project's own kea-dhcp4.conf always produces.
        let dhcp4 = config.get_mut("Dhcp4").ok_or("Dhcp4 missing")?;
        let subnets = dhcp4
            .get_mut("subnet4")
            .ok_or("subnet4 missing")?
            .as_array_mut()
            .ok_or("subnet4 not an array")?;

        let next_id = subnets
            .iter()
            .filter_map(|s| s["id"].as_u64())
            .max()
            .map(|m| m + 1)
            .unwrap_or(1) as u32;

        subnets.push(build_subnet_value(SubnetValue {
            id: next_id,
            subnet: form.subnet,
            pool_start: form.pool_start,
            pool_end: form.pool_end,
            gateway: form.gateway,
            dns_primary: form.dns_primary,
            dns_secondary: form.dns_secondary,
            ntp_servers,
            domain: form.domain,
            lease_time,
            editable_options: Vec::new(),
            reservations: None,
        })?);
        Ok(())
    })
    .await
    .map_err(|e| DhcpError::config_error(e.to_string()))?;

    Ok(Redirect::to("/dhcp"))
}

// Edits an existing subnet4 entry in place (found by id). Unlike add_subnet,
// this must carry forward two things the form doesn't submit: the subnet's
// existing custom options (preserved_subnet_options) and its existing
// reservations, filtered down to only the ones still compatible with the
// (possibly changed) subnet CIDR (compatible_reservations_for_subnet) --
// otherwise a reservation for an IP outside the new subnet range would be
// silently kept in a subnet it no longer belongs to.
pub async fn update_subnet(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<UpdateSubnetForm>,
) -> Result<Redirect, DhcpError> {
    require_kea_mode(&state)?;
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(DhcpError::from)?;
    let lease_time = validate_dhcp_form(DhcpFormValidation {
        subnet: &form.subnet,
        pool_start: &form.pool_start,
        pool_end: &form.pool_end,
        gateway: &form.gateway,
        dns_primary: &form.dns_primary,
        dns_secondary: &form.dns_secondary,
        ntp_servers: &form.ntp_servers,
        lease_time: &form.lease_time,
        domain: &form.domain,
    })
    .map_err(DhcpError::from)?;
    let subnet_id = form.id;
    // See add_subnet's identical resolve_ntp_servers call for why this
    // happens here rather than inside the sync kea_config_modify closure
    // below or inside validate_dhcp_form.
    let ntp_servers = resolve_ntp_servers(&form.ntp_servers)
        .await
        .map_err(|message| DhcpError::new(StatusCode::BAD_REQUEST, message))?;

    kea_config_modify(&state, move |config| {
        // Same per-field-named navigation as add_subnet above.
        let dhcp4 = config.get_mut("Dhcp4").ok_or("Dhcp4 missing")?;
        let subnets = dhcp4
            .get_mut("subnet4")
            .ok_or("subnet4 missing")?
            .as_array_mut()
            .ok_or("subnet4 not an array")?;

        let entry = subnets
            .iter_mut()
            .find(|s| s["id"].as_u64() == Some(subnet_id as u64))
            .ok_or("subnet not found")?;
        let reservations = compatible_reservations_for_subnet(entry, &form.subnet)?;
        apply_subnet_value(
            entry,
            SubnetValue {
                id: subnet_id,
                subnet: form.subnet,
                pool_start: form.pool_start,
                pool_end: form.pool_end,
                gateway: form.gateway,
                dns_primary: form.dns_primary,
                dns_secondary: form.dns_secondary,
                ntp_servers,
                domain: form.domain,
                lease_time,
                editable_options: preserved_subnet_options(entry),
                reservations: Some(reservations),
            },
        )?;
        Ok(())
    })
    .await
    .map_err(|e| DhcpError::config_error(e.to_string()))?;

    Ok(Redirect::to("/dhcp"))
}

// Deletes a subnet4 entry (and, implicitly, everything nested inside it in
// Kea's JSON -- its pools, options, and reservations) in one config-modify
// call. There is no separate confirmation step here; the known-good config
// snapshot taken on the previous successful write is the recovery path if
// this was a mistake.
pub async fn remove_subnet(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<RemoveSubnetForm>,
) -> Result<Redirect, DhcpError> {
    require_kea_mode(&state)?;
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(DhcpError::from)?;
    let subnet_id = form.id;
    kea_config_modify(&state, move |config| {
        let dhcp4 = config.get_mut("Dhcp4").ok_or("Dhcp4 missing")?;
        let subnets = dhcp4
            .get_mut("subnet4")
            .ok_or("subnet4 missing")?
            .as_array_mut()
            .ok_or("subnet4 not an array")?;

        subnets.retain(|s| s["id"].as_u64() != Some(subnet_id as u64));
        Ok(())
    })
    .await
    .map_err(|e| DhcpError::config_error(e.to_string()))?;

    Ok(Redirect::to("/dhcp"))
}

// Adds one custom DHCP option to a subnet. The "code" field accepts either a
// numeric option code (e.g. a vendor-specific option, stored in option-data)
// or one of the three top-level PXE subnet fields
// next-server/server-hostname/boot-file-name (stored as a top-level subnet
// key) -- see parse_custom_option_key/validate_custom_option_data further down
// for what makes a code/value acceptable here and PXE_SUBNET_FIELDS for why
// both share one form.
pub async fn add_subnet_option(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<AddSubnetOptionForm>,
) -> Result<Redirect, DhcpError> {
    require_kea_mode(&state)?;
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(DhcpError::from)?;
    let key = parse_custom_option_key(&form.code).map_err(|message| {
        DhcpError::new(
            StatusCode::BAD_REQUEST,
            format!("Invalid DHCP option: {message}"),
        )
    })?;
    let data = validate_custom_option_data(key, &form.data).map_err(|message| {
        DhcpError::new(
            StatusCode::BAD_REQUEST,
            format!("Invalid DHCP option: {message}"),
        )
    })?;
    let subnet_id = form.subnet_id;

    kea_config_modify(&state, move |config| {
        let subnet = find_subnet_mut(config, subnet_id)?;
        match key {
            CustomOptionKey::Numeric(code) => add_custom_subnet_option(subnet, code, &data)?,
            CustomOptionKey::Pxe(field) => set_pxe_subnet_field(subnet, field, &data)?,
        }
        Ok(())
    })
    .await
    .map_err(|e| DhcpError::config_error(e.to_string()))?;

    Ok(Redirect::to("/dhcp"))
}

// Removes one custom DHCP option from a subnet, matched by code AND data
// together (see RemoveSubnetOptionForm's own comment for why both are
// needed) -- the same code/data parsing as add_subnet_option is re-run here
// so the value being removed is normalized the same way the stored value
// was when it was added, and the two compare equal. Routes a PXE field key to
// its top-level subnet field the same way add_subnet_option does.
pub async fn remove_subnet_option(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<RemoveSubnetOptionForm>,
) -> Result<Redirect, DhcpError> {
    require_kea_mode(&state)?;
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(DhcpError::from)?;
    let key = parse_custom_option_key(&form.code).map_err(|message| {
        DhcpError::new(
            StatusCode::BAD_REQUEST,
            format!("Invalid DHCP option: {message}"),
        )
    })?;
    let data = validate_custom_option_data(key, &form.data).map_err(|message| {
        DhcpError::new(
            StatusCode::BAD_REQUEST,
            format!("Invalid DHCP option: {message}"),
        )
    })?;
    let subnet_id = form.subnet_id;

    kea_config_modify(&state, move |config| {
        let subnet = find_subnet_mut(config, subnet_id)?;
        match key {
            CustomOptionKey::Numeric(code) => remove_custom_subnet_option(subnet, code, &data)?,
            CustomOptionKey::Pxe(field) => remove_pxe_subnet_field(subnet, field, &data)?,
        }
        Ok(())
    })
    .await
    .map_err(|e| DhcpError::config_error(e.to_string()))?;

    Ok(Redirect::to("/dhcp"))
}

pub async fn add_reservation(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<AddReservationForm>,
) -> Result<Redirect, DhcpError> {
    require_kea_mode(&state)?;
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(DhcpError::from)?;
    if !is_valid_mac(&form.mac) || !is_valid_ip(&form.ip) {
        return Err(DhcpError::from(StatusCode::BAD_REQUEST));
    }
    // Issue #947: form.hostname used to flow straight into the Kea
    // reservation JSON with zero validation. Only validated when non-empty
    // -- an empty hostname is an existing, already-supported state on the
    // read side (fetch_all_reservations already tolerates a missing/blank
    // hostname), so this must not turn that into a rejection.
    if !form.hostname.trim().is_empty() && !is_valid_domain_name(&form.hostname) {
        return Err(DhcpError::new(
            StatusCode::BAD_REQUEST,
            "Invalid hostname: use a plain DNS domain name (letters, digits, '-', '.').",
        ));
    }
    let mac = normalize_mac(&form.mac);
    kea_config_modify(&state, move |config| {
        // If an operator has hand-edited the *global*
        // Dhcp4.host-reservation-identifiers list to something
        // that excludes "hw-address" (e.g. ["client-id"]), Kea would accept
        // this config-set call but then silently never match the reservation
        // we're about to add -- config-set succeeds, the form redirects as if
        // it worked, and the reservation is permanently dead. This project's
        // own shipped kea-dhcp4.conf never sets this key (relies entirely on
        // Kea's compiled-in default, which does include "hw-address"), so the
        // gap only bites a manually-edited config -- but "silently accepted,
        // never actually works" is exactly the failure class this project
        // refuses to ship (see AG-OP-005: do not silently invert defaults).
        // Fail loudly instead of writing a reservation Kea will never honor.
        if !global_reservation_identifiers_include_hw_address(config) {
            return Err(
                "cannot add a hw-address reservation: this Kea config's global \
                 Dhcp4.host-reservation-identifiers list does not include \
                 \"hw-address\", so Kea would never match it",
            );
        }
        let subnets = dhcp4_subnets_mut(config)?;
        let subnet = subnets
            .iter_mut()
            .find(|s| s["id"].as_u64() == Some(form.subnet_id as u64))
            .ok_or("subnet not found")?;
        // No per-subnet `host-reservation-identifiers` write here (there
        // used to be one): real Kea rejects that parameter at subnet scope
        // outright (see apply_subnet_value's own comment on this), and
        // Kea's compiled-in global default already includes "hw-address" --
        // the only identifier type this form ever submits -- so hw-address
        // reservations already match without this code touching anything.
        let reservations = subnet_reservations_mut(subnet)?;
        upsert_reservation(
            reservations,
            json!({
                "hw-address": mac,
                "ip-address": form.ip,
                "hostname": form.hostname,
                "option-data": [],
                "client-classes": []
            }),
        )?;
        Ok(())
    })
    .await
    .map_err(|e| DhcpError::config_error(e.to_string()))?;
    Ok(Redirect::to("/dhcp"))
}

// Removes a static host reservation by (normalized) MAC address. Unlike
// add_reservation, this has no global-identifiers guard to check: deleting
// an entry is safe regardless of whether Kea would currently match it, so
// there's nothing here that could silently fail to take effect.
pub async fn remove_reservation(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<RemoveReservationForm>,
) -> Result<Redirect, DhcpError> {
    require_kea_mode(&state)?;
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(DhcpError::from)?;
    // Issue #947: mirrors add_reservation/release_lease, which both validate
    // their own identifier field before use. Harmless as a no-op today (a
    // malformed MAC simply matches nothing in remove_reservation_entry's
    // filter), but rejecting it early is consistent with every other
    // mutating route in this file and gives the operator an immediate,
    // specific error instead of a silent no-op redirect.
    if !is_valid_mac(&form.mac) {
        return Err(DhcpError::from(StatusCode::BAD_REQUEST));
    }
    let mac = normalize_mac(&form.mac);
    kea_config_modify(&state, move |config| {
        let subnets = dhcp4_subnets_mut(config)?;
        let subnet = subnets
            .iter_mut()
            .find(|s| s["id"].as_u64() == Some(form.subnet_id as u64))
            .ok_or("subnet not found")?;
        let reservations = subnet_reservations_mut(subnet)?;
        remove_reservation_entry(reservations, &mac);
        Ok(())
    })
    .await
    .map_err(|e| DhcpError::config_error(e.to_string()))?;
    Ok(Redirect::to("/dhcp"))
}

// Ends an active dynamic lease early via Kea's lease4-del command. This
// goes straight through kea_post, not kea_config_modify -- releasing a
// lease is a runtime action against Kea's lease database, not a
// config-file change, so it needs none of config-modify's config-test/
// config-set/config-write/rollback/snapshot machinery.
pub async fn release_lease(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<ReleaseLeaseForm>,
) -> Result<Redirect, DhcpError> {
    require_kea_mode(&state)?;
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(DhcpError::from)?;
    if !is_valid_ip(&form.ip) {
        return Err(DhcpError::new(
            StatusCode::BAD_REQUEST,
            "Lease release requires a valid IPv4 address",
        ));
    }

    // Capture the lease's DDNS hostname BEFORE deleting it (issue #1083):
    // lease4-del removes the lease record this is read from, and it is the
    // exact forward FQDN Kea's D2 used for the A record that must be cleaned
    // up. Best-effort -- a failed/absent read just skips the forward-record
    // delete; the reverse PTR is reconstructed from the IP alone.
    let lease_hostname = fetch_lease_hostname(&state, &form.ip).await;

    let resp = kea_post(
        &state,
        json!({
            "command": "lease4-del",
            "service": ["dhcp4"],
            "arguments": {
                "ip-address": form.ip
            }
        }),
    )
    .await
    .map_err(|e| DhcpError::config_error(e.to_string()))?;

    match kea_lease_del_result(&resp) {
        LeaseDelOutcome::Released => {
            // Kea's lease4-del does NOT trigger a DDNS removal (issue #1083,
            // confirmed against Kea's docs: only a client DHCPRELEASE or Kea's
            // own expired-lease reclamation send a removal NCR to D2, never an
            // admin-issued lease4-del). Clean up the A + PTR records D2 created
            // by publishing deletes on the same lancache.dns.record NATS
            // subject both PowerDNS instances already consume. Best-effort: the
            // address is already freed, so a DNS-cleanup failure must never
            // turn a successful release into an error response.
            cleanup_lease_ddns_records(&state, &form.ip, lease_hostname.as_deref()).await;
            Ok(Redirect::to("/dhcp"))
        }
        // Kea's CONTROL_RESULT_EMPTY (3) for lease4-del means no lease matched
        // the given address -- an ordinary race (the lease expired or was
        // already released between page render and this request), not a
        // server-side failure. Surface it as 404, not 500.
        LeaseDelOutcome::NotFound => Err(DhcpError::new(
            StatusCode::NOT_FOUND,
            format!(
                "No active lease found for {}; it may have already expired or been released.",
                form.ip
            ),
        )),
        LeaseDelOutcome::Error(msg) => Err(DhcpError::config_error(msg)),
    }
}

// Toggles Kea's DDNS master switch, Dhcp4.dhcp-ddns.enable-updates (issue
// #1076). This is deliberately separate from update_dhcp_mode: an operator
// running Kea DHCP may or may not want it also writing DNS records on every
// lease, and that is a distinct decision from issuing addresses. Goes through
// kea_config_modify (config-test/config-set/config-write/rollback/snapshot)
// because it persists a config-file change; Kea applies the new
// enable-updates value live on config-set, so no container restart is needed.
// The value survives a restart via entrypoint.sh's migrate_dhcp4_config
// existing-wins merge.
pub async fn update_dhcp_ddns(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<DdnsToggleForm>,
) -> Result<Redirect, DhcpError> {
    require_kea_mode(&state)?;
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(DhcpError::from)?;
    let enabled = parse_bool_flag(&form.enabled);

    kea_config_modify(&state, move |config| {
        set_config_ddns_enabled(config, enabled)
    })
    .await
    .map_err(|e| DhcpError::config_error(e.to_string()))?;

    Ok(Redirect::to("/dhcp"))
}

// Reads a single lease by IP (lease4-get) and returns its DDNS hostname if
// present and non-empty. Best-effort by design (see release_lease's #1083
// cleanup): any error, a missing lease, or a hostname-less lease yields None,
// and the caller simply skips the forward-record delete.
async fn fetch_lease_hostname(state: &AppState, ip: &str) -> Option<String> {
    let resp = kea_post(
        state,
        json!({
            "command": "lease4-get",
            "service": ["dhcp4"],
            "arguments": {"ip-address": ip}
        }),
    )
    .await
    .ok()?;
    let hostname = resp
        .get(0)?
        .get("arguments")?
        .get("hostname")?
        .as_str()?
        .trim();
    if hostname.is_empty() {
        None
    } else {
        Some(hostname.to_string())
    }
}

// Publishes the forward-A and reverse-PTR record deletes for a just-released
// lease over the lancache.dns.record NATS subject (issue #1083). Best-effort:
// logs and continues on any publish failure. Both records are reconstructed
// from this lease's own IP/hostname, so the worst case of a mismatch is a
// stale record left behind (or a logged PowerDNS 4xx), never the removal of an
// unrelated active record.
async fn cleanup_lease_ddns_records(state: &AppState, ip: &str, hostname: Option<&str>) {
    // Forward A record: keyed by Kea's own FQDN for the lease. Skipped when the
    // lease had no hostname (nothing was ever registered forward).
    if let Some(hostname) = hostname {
        if let Some((zone, name)) = forward_record_zone_and_name(hostname) {
            publish_dns_record_delete(state, &zone, &name, "A").await;
        }
    }
    // Reverse PTR record: name + zone derive purely from the IPv4, so this runs
    // even when the lease carried no hostname.
    if let Some((zone, name)) = reverse_ptr_zone_and_name(ip) {
        publish_dns_record_delete(state, &zone, &name, "PTR").await;
    }
}

// Publishes one record-delete event, mirroring remove_lan_record's payload
// shape exactly -- the DNS subscriber acks malformed delete events (missing
// fields) as unrecoverable, so the schema must match the proven producer. The
// subscriber is record-type-agnostic and applies the delete to whatever zone
// is named by name+type, origin-independent, so it removes a D2-created record
// the same as an Admin-UI-created one.
async fn publish_dns_record_delete(state: &AppState, zone: &str, name: &str, record_type: &str) {
    let msg = json!({
        "action": "delete",
        "zone": zone,
        "name": name,
        "type": record_type
    });
    if let Err(e) = state
        .nats
        .publish(
            "lancache.dns.record",
            serde_json::to_vec(&msg).unwrap().into(),
        )
        .await
    {
        tracing::error!(
            zone = %zone,
            name = %name,
            record_type = %record_type,
            "NATS publish of DDNS record delete failed: {e}"
        );
    }
}

// Splits a fully-qualified lease hostname into (zone, name-with-trailing-dot)
// for a forward-record delete. The zone is the FQDN's parent domain in
// add_lan_record's no-trailing-dot convention (host.lan -> zone "lan", name
// "host.lan."; host.local.lan -> zone "local.lan"). Returns None for a bare
// single-label name, which has no parent zone to delete from.
fn forward_record_zone_and_name(hostname: &str) -> Option<(String, String)> {
    let trimmed = hostname.trim().trim_end_matches('.').to_ascii_lowercase();
    let (_label, zone) = trimmed.split_once('.')?;
    if zone.is_empty() {
        return None;
    }
    Some((zone.to_string(), format!("{trimmed}.")))
}

// Computes the (zone, PTR-name) for an IPv4's reverse record, mirroring the
// RFC1918 private reverse zones services/dns creates (its PRIVATE_REVERSE_ZONES
// list): 10.in-addr.arpa, 168.192.in-addr.arpa, and {16..31}.172.in-addr.arpa.
// Expressed as the three structural rules rather than a copied 18-entry list so
// it cannot drift from that generation. Returns None for any address outside
// those ranges -- no PowerDNS zone hosts it, so there is nothing to delete.
fn reverse_ptr_zone_and_name(ip: &str) -> Option<(String, String)> {
    let [a, b, c, d] = parse_ipv4(ip)?.octets();
    let zone = match (a, b) {
        (10, _) => "10.in-addr.arpa".to_string(),
        (192, 168) => "168.192.in-addr.arpa".to_string(),
        (172, 16..=31) => format!("{b}.172.in-addr.arpa"),
        _ => return None,
    };
    let name = format!("{d}.{c}.{b}.{a}.in-addr.arpa.");
    Some((zone, name))
}

#[derive(Debug, PartialEq, Eq)]
enum LeaseDelOutcome {
    Released,
    NotFound,
    Error(String),
}

// lease4-del uses Kea's generic control-channel result codes: 0 = success,
// 3 = CONTROL_RESULT_EMPTY (no matching lease), anything else = error. This
// is distinct from kea_result() below, which treats any nonzero as failure --
// that's correct for config-modify commands, where "empty" has no special
// meaning, but wrong for lease4-del's "already gone" case.
fn kea_lease_del_result(resp: &Value) -> LeaseDelOutcome {
    let rc = resp
        .get(0)
        .and_then(|r| r.get("result"))
        .and_then(|v| v.as_i64())
        .unwrap_or(1);
    match rc {
        0 => LeaseDelOutcome::Released,
        3 => LeaseDelOutcome::NotFound,
        _ => {
            let msg = resp
                .get(0)
                .and_then(|r| r.get("text"))
                .and_then(|v| v.as_str())
                .unwrap_or("Kea error");
            LeaseDelOutcome::Error(msg.to_string())
        }
    }
}

// Issue #947: this route starts/stops the DHCP conflict-probe container
// (check_dhcp_probe below has a real, non-idempotent side effect), but it
// used to be wired as GET in main.rs -- and this app's CSRF protection (the
// `basic_auth` middleware's `is_mutating_method` check) only covers
// POST/PUT/PATCH/DELETE, so a GET route is completely CSRF-exempt no matter
// what it does. Now POST-only, with the same explicit header-only CSRF check
// (`verify_csrf_header`) secondaries::remove_secondary/rotate_token already
// use for their own header-only, no-form-body routes -- this handler has no
// form body to carry a `csrf_token` field, only the `X-CSRF-Token` header
// dhcp.html's `fetch()` call now sends.
pub async fn check_dhcp_conflict(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, StatusCode> {
    crate::routes::verify_csrf_header(&headers)?;
    let report = check_dhcp_probe(&state).await;
    Ok(Json(json!({
        "status": report.overall_status(),
        "conflict": report.conflict,
        "client": report.client,
    })))
}

// Rolls the live DHCPv4 config back to an operator-selected known-good
// snapshot (#614, follow-up to #415). Unlike the nginx/dnsmasq/PowerDNS
// shell adapters -- which automatically search their stored snapshots
// newest-to-oldest at container startup, because "the config this container
// is about to start with is invalid" is their only rollback trigger -- Kea
// has no equivalent startup moment: its config only ever changes through
// this Admin UI, live, one operator-driven mutation at a time. So this
// route is a single, explicit, operator-selected rollback rather than an
// automatic search: the operator picks one snapshot from the list rendered
// on `/dhcp`, and only that snapshot is validated and applied.
//
// The `known_ids` membership check below is this handler's path-traversal
// guard (see `kea_snapshots::read_snapshot`'s doc comment): `form.snapshot_id`
// is untrusted request input, but it is never used to build a filesystem
// path unless it exactly matches an id `list_snapshot_ids` already found on
// disk.
//
// Reusing `kea_config_modify` for the apply step gives this rollback the
// same `config-test` (validate the selected snapshot) -> `config-set` ->
// `config-write` chain, and the same confirmed/ambiguous-failure handling
// from PR #380, that every other DHCP mutation route already gets --
// including a fresh known-good snapshot of the restored config on success,
// so `docs/known-good-config-snapshots.md`'s "every successful config-write
// is snapshotted" rule has no special case for rollbacks. "Verify runtime
// and persisted state after rollback" (the issue's acceptance criterion) is
// satisfied by that same chain: `config-set` returning success is Kea's own
// confirmation the runtime accepted the restored config, and
// `config-write`'s confirmed/ambiguous handling is exactly the persisted-
// state verification PR #380 already established -- deliberately not
// re-implemented here as a second, fuzzy `config-get` diff, since Kea can
// reorder/normalize JSON on read in ways that would make such a diff noisy
// rather than trustworthy.
pub async fn rollback_kea_snapshot(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<RollbackKeaSnapshotForm>,
) -> Result<Redirect, DhcpError> {
    require_kea_mode(&state)?;
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(DhcpError::from)?;

    let snapshot_root = PathBuf::from(&state.config.kea_config_snapshot_dir);
    let known_ids = kea_snapshots::list_snapshot_ids(&snapshot_root).map_err(|e| {
        DhcpError::config_error(format!(
            "Failed to list known-good Kea config snapshots: {e}"
        ))
    })?;
    if !known_ids.iter().any(|id| id == &form.snapshot_id) {
        return Err(DhcpError::conflict(
            "Unknown or no-longer-available config snapshot.",
        ));
    }

    let snapshot_config =
        kea_snapshots::read_snapshot(&snapshot_root, &form.snapshot_id).map_err(|e| {
            kea_snapshots::kgs_log(
                "REJECT",
                &format!(
                    "rejected known-good snapshot {}: unreadable ({e})",
                    form.snapshot_id
                ),
            );
            DhcpError::config_error(format!("Stored config snapshot could not be read: {e}"))
        })?;

    kea_config_modify(&state, move |config| {
        *config = snapshot_config;
        Ok(())
    })
    .await
    .map_err(|e| {
        kea_snapshots::kgs_log(
            "REJECT",
            &format!(
                "rejected known-good snapshot {}: failed validation/apply ({e})",
                form.snapshot_id
            ),
        );
        DhcpError::config_error(format!(
            "Rollback to snapshot {} failed: {e}",
            form.snapshot_id
        ))
    })?;

    kea_snapshots::kgs_log(
        "SELECT",
        &format!(
            "selected known-good snapshot {} for rollback",
            form.snapshot_id
        ),
    );
    Ok(Redirect::to("/dhcp"))
}

// ─── Kea API Core ───

type KeaResponse = Result<Value, Box<dyn std::error::Error + Send + Sync>>;
type KeaResult = Result<(), Box<dyn std::error::Error + Send + Sync>>;

async fn kea_post(state: &AppState, cmd: Value) -> KeaResponse {
    let url = format!("{}/", state.config.dhcp_api_url);
    Ok(state
        .http_client
        .post(&url)
        .header("Content-Type", "application/json")
        .basic_auth("admin", Some(&state.config.dhcp_api_token))
        .json(&cmd)
        .send()
        .await?
        .json::<Value>()
        .await?)
}

fn kea_result(resp: &Value) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let rc = resp
        .get(0)
        .and_then(|r| r.get("result"))
        .and_then(|v| v.as_i64())
        .unwrap_or(1);
    if rc == 0 {
        Ok(())
    } else {
        let msg = resp
            .get(0)
            .and_then(|r| r.get("text"))
            .and_then(|v| v.as_str())
            .unwrap_or("Kea error");
        Err(msg.to_string().into())
    }
}

// config-get → modify → config-test → config-set → config-write (persists to /var/lib/kea/kea-dhcp4.conf)
// This function implements config rollback logic: if config-write fails after config-set succeeds,
// it attempts to restore the previous config to maintain consistency between runtime and persisted state.
//
// On a confirmed config-write success, it also records a persisted,
// multi-generation known-good snapshot of the applied config (#614, follow-up
// to #415) via `kea_snapshots::create_snapshot`. That snapshot step is
// best-effort: a failure there is logged as a WARNING (rollback protection
// degraded until it succeeds again) rather than turned into an error for
// this call, mirroring the nginx/dnsmasq shell adapters' own non-fatal
// treatment of a failed `kgs_snapshot_create` -- the config mutation itself
// already succeeded and persisted; the only thing at risk is a future
// rollback's baseline, not this request.
async fn kea_config_modify<F>(state: &AppState, modify: F) -> KeaResult
where
    F: FnOnce(&mut Value) -> Result<(), &'static str> + Send,
{
    let snapshot_root = PathBuf::from(&state.config.kea_config_snapshot_dir);
    let keep_n = state.config.kea_keep_known_good_configs;
    kea_config_modify_with_post(
        &state.kea_config_lock,
        |cmd| kea_post(state, cmd),
        modify,
        move |applied_config: &Value| {
            if let Err(e) = kea_snapshots::create_snapshot(&snapshot_root, keep_n, applied_config)
            {
                tracing::warn!(
                    error = %e,
                    "failed to record this valid DHCP config as a known-good snapshot; rollback protection is degraded until this succeeds"
                );
            }
        },
    )
    .await
}

async fn kea_config_modify_with_post<F, P, Fut, S>(
    lock: &tokio::sync::Mutex<()>,
    mut post: P,
    modify: F,
    on_write_success: S,
) -> KeaResult
where
    F: FnOnce(&mut Value) -> Result<(), &'static str> + Send,
    P: FnMut(Value) -> Fut + Send,
    Fut: Future<Output = KeaResponse> + Send,
    S: FnOnce(&Value) + Send,
{
    let _guard = lock.lock().await;

    // Step 1: Fetch current config
    let resp = post(json!({"command": "config-get", "service": ["dhcp4"]})).await?;
    kea_result(&resp)?;

    let mut config = resp
        .get(0)
        .and_then(|r| r.get("arguments"))
        .cloned()
        .ok_or("config-get: missing arguments")?;

    // config-get's response is `{"Dhcp4": {...}, "hash": "<config hash>"}` on
    // the real Kea Control Agent (observed live against Kea 2.6.3, the
    // version this project's `services/dhcp` image ships) -- `hash` is a
    // server-computed digest of the loaded config, not an accepted input.
    // Feeding it straight back as `arguments` to config-test/config-set (as
    // this function previously did) makes Kea reject the request with
    // "Unsupported 'hash' parameter." on every single call, even when the
    // config is otherwise byte-identical to what config-get just returned.
    // Stripped once, immediately after the fetch, so every downstream user
    // of `config` (the `modify` closure, `old_config`'s own rollback
    // config-set, config-test/config-set's request bodies, and the
    // known-good snapshot payload captured further down) works with the
    // clean `{"Dhcp4": {...}}` shape Kea actually accepts back.
    if let Some(map) = config.as_object_mut() {
        map.remove("hash");
    }

    // Step 2: Save old config for potential rollback
    let old_config = config.clone();

    // Step 3: Apply modifications
    modify(&mut config).map_err(|e| -> Box<dyn std::error::Error + Send + Sync> { e.into() })?;

    // Step 4: Validate new config
    let test_resp =
        post(json!({"command": "config-test", "service": ["dhcp4"], "arguments": config.clone()}))
            .await?;
    kea_result(&test_resp)?;

    // Captured before Step 5 moves `config` into the config-set request body,
    // so the exact validated-and-applied config is available for the
    // known-good snapshot on a confirmed config-write success below.
    let snapshot_candidate = config.clone();

    // Step 5: Apply new config at runtime
    let set_resp =
        post(json!({"command": "config-set", "service": ["dhcp4"], "arguments": config})).await?;
    kea_result(&set_resp)?;

    // Step 6: Persist config to disk.
    match kea_write_config(&mut post).await {
        KeaWriteOutcome::Success => {
            on_write_success(&snapshot_candidate);
            Ok(())
        }
        KeaWriteOutcome::ConfirmedFailure(write_err) => {
            tracing::warn!(error = %write_err, "DHCP config-write failed; attempting rollback to previous config");
            rollback_kea_config(&mut post, old_config, &write_err).await
        }
        KeaWriteOutcome::AmbiguousFailure(write_err) => {
            tracing::warn!(
                error = %write_err,
                "DHCP config-write outcome could not be confirmed; retrying before rollback"
            );
            match kea_write_config(&mut post).await {
                KeaWriteOutcome::Success => {
                    on_write_success(&snapshot_candidate);
                    Ok(())
                }
                KeaWriteOutcome::ConfirmedFailure(retry_err) => {
                    let msg = format!(
                        "Config applied at runtime but the first config-write result was ambiguous, \
                         and a retry returned a Kea failure. Runtime and persisted config may now differ. \
                         First error: {}. Retry error: {}",
                        write_err, retry_err
                    );
                    tracing::error!(
                        error = %msg,
                        "DHCP config-write retry failed after ambiguous first write; not rolling back blindly"
                    );
                    Err(msg.into())
                }
                KeaWriteOutcome::AmbiguousFailure(retry_err) => {
                    let msg = format!(
                        "Config applied at runtime but config-write could not be confirmed after retry. \
                         Runtime and persisted config may now differ. First error: {}. Retry error: {}",
                        write_err, retry_err
                    );
                    tracing::error!(error = %msg, "DHCP config-write remained ambiguous after retry");
                    Err(msg.into())
                }
            }
        }
    }
}

// Issues Kea's config-write command, which persists the just-applied
// runtime config to /var/lib/kea/kea-dhcp4.conf. Returns one of three
// outcomes rather than a plain Result -- see KeaWriteOutcome's own comment
// for why the network-error case (AmbiguousFailure) must be distinguished
// from a definite Kea-side rejection (ConfirmedFailure).
async fn kea_write_config<P, Fut>(post: &mut P) -> KeaWriteOutcome
where
    P: FnMut(Value) -> Fut + Send,
    Fut: Future<Output = KeaResponse> + Send,
{
    match post(json!({"command": "config-write", "service": ["dhcp4"]})).await {
        Ok(resp) => match kea_result(&resp) {
            Ok(_) => KeaWriteOutcome::Success,
            Err(err) => KeaWriteOutcome::ConfirmedFailure(err.to_string()),
        },
        Err(err) => KeaWriteOutcome::AmbiguousFailure(err.to_string()),
    }
}

// Called only after a confirmed config-write failure: re-applies the config
// exactly as it was before this request's changes, via the same config-set
// command used for the original (attempted) change. Always returns Err even
// when the rollback itself succeeds -- from the caller's point of view the
// operator's requested change did not happen, so this is never a success
// path, only a "how badly did it fail" distinction (rolled back cleanly vs.
// runtime/persisted state now disagree).
async fn rollback_kea_config<P, Fut>(post: &mut P, old_config: Value, write_err: &str) -> KeaResult
where
    P: FnMut(Value) -> Fut + Send,
    Fut: Future<Output = KeaResponse> + Send,
{
    let rollback_result = post(json!({
        "command": "config-set",
        "service": ["dhcp4"],
        "arguments": old_config
    }))
    .await;

    match rollback_result {
        Ok(resp) => match kea_result(&resp) {
            Ok(_) => {
                let msg =
                    "Config change failed to persist and was rolled back; no change was made."
                        .to_string();
                tracing::warn!(error = %write_err, "DHCP config rollback succeeded");
                Err(msg.into())
            }
            Err(rollback_err) => {
                let msg = format!(
                    "Config applied at runtime but NOT persisted to disk — runtime and persisted config may now differ. \
                     Write failed: {}. Rollback also failed: {}",
                    write_err, rollback_err
                );
                tracing::error!(error = %msg, "DHCP config rollback failed");
                Err(msg.into())
            }
        },
        Err(rollback_err) => {
            let msg = format!(
                "Config applied at runtime but NOT persisted to disk — runtime and persisted config may now differ. \
                 Write failed: {}. Rollback request also failed: {}",
                write_err, rollback_err
            );
            tracing::error!(error = %msg, "DHCP config rollback request failed");
            Err(msg.into())
        }
    }
}

// ─── Data Fetchers ───

// Fetches Kea's live config, the same config-get command kea_config_modify_with_post
// uses -- but as a plain read, not the start of a modify/test/set/write chain.
// Used by the read-only paths: dhcp_page (subnets + the DDNS toggle state via
// fetch_subnets_from_config/config_ddns_enabled) and fetch_all_reservations
// below.
async fn fetch_dhcp_config(
    state: &AppState,
) -> Result<Value, Box<dyn std::error::Error + Send + Sync>> {
    let resp = kea_post(
        state,
        json!({"command": "config-get", "service": ["dhcp4"]}),
    )
    .await?;
    kea_result(&resp)?;

    Ok(resp
        .get(0)
        .and_then(|r| r.get("arguments"))
        .cloned()
        .ok_or("config-get: missing arguments")?)
}

// Converts Kea's raw subnet4 JSON array into the Subnet read-model (see its
// struct comment). A missing/malformed subnet4 array renders as an empty
// list rather than an error -- consistent with dhcp_page's own fail-open
// treatment of an unreachable Kea API.
fn fetch_subnets_from_config(config: &Value) -> Vec<Subnet> {
    dhcp4_subnets(config)
        .map(|subnets| subnets.iter().map(parse_subnet_entry).collect())
        .unwrap_or_default()
}

// Reads Kea's live DDNS master switch (Dhcp4.dhcp-ddns.enable-updates) so the
// settings page can render the "Enable DDNS Updates" toggle in its true state
// (issue #1076). Defaults to false when the key is absent -- matching both
// Kea's own default and this project's fresh-install default -- rather than
// assuming DDNS is on.
fn config_ddns_enabled(config: &Value) -> bool {
    config
        .get("Dhcp4")
        .and_then(|dhcp4| dhcp4.get("dhcp-ddns"))
        .and_then(|ddns| ddns.get("enable-updates"))
        .and_then(|value| value.as_bool())
        .unwrap_or(false)
}

// Sets Dhcp4.dhcp-ddns.enable-updates without disturbing any other dhcp-ddns
// field (server-ip/port/queue/etc. stay as the entrypoint rendered them).
// Creates the dhcp-ddns object if it is somehow absent (a hand-edited config)
// so the toggle always has a target to write.
fn set_config_ddns_enabled(config: &mut Value, enabled: bool) -> Result<(), &'static str> {
    let dhcp4 = config
        .get_mut("Dhcp4")
        .and_then(|dhcp4| dhcp4.as_object_mut())
        .ok_or("Dhcp4 missing")?;
    let ddns = dhcp4
        .entry("dhcp-ddns")
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .ok_or("dhcp-ddns not an object")?;
    ddns.insert("enable-updates".to_string(), json!(enabled));
    Ok(())
}

// Interprets a form flag string as a boolean the same way entrypoint.sh
// normalizes DHCP_DDNS_ENABLED, so the Admin UI toggle and the container agree
// on exactly which spellings count as "on".
fn parse_bool_flag(raw: &str) -> bool {
    matches!(
        raw.trim().to_ascii_lowercase().as_str(),
        "1" | "true" | "yes" | "on"
    )
}

// Flattens every subnet's nested `reservations` array into one flat list of
// Reservation, tagging each with its owning subnet_id (Kea nests
// reservations inside their subnet; the Admin UI's reservations table is
// one flat list across all subnets, so this is the shape conversion between
// the two).
fn fetch_reservations_from_config(config: &Value) -> Vec<Reservation> {
    dhcp4_subnets(config)
        .map(|subnets| {
            subnets
                .iter()
                .flat_map(|subnet| {
                    let subnet_id = subnet.get("id").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
                    subnet
                        .get("reservations")
                        .and_then(|v| v.as_array())
                        .into_iter()
                        .flatten()
                        .filter_map(move |reservation| {
                            parse_reservation_entry(subnet_id, reservation)
                        })
                })
                .collect()
        })
        .unwrap_or_default()
}

// fetch_leases below talks to Kea's lease database directly (lease4-get-all)
// rather than going through fetch_dhcp_config -- leases are runtime state,
// not part of the Dhcp4 config JSON subnets/reservations live in.

// Lists known-good Kea config snapshots (#614) for the DHCP settings page,
// newest first (the order an operator picking a rollback target cares
// about). Missing/unreadable snapshot storage renders as "no snapshots yet"
// rather than failing the whole page -- the same fail-open treatment
// `dhcp_page` already gives its subnet/lease/reservation fetches when the Kea
// API itself is unavailable.
fn fetch_kea_snapshot_summaries(state: &AppState) -> Vec<KeaSnapshotSummary> {
    let snapshot_root = PathBuf::from(&state.config.kea_config_snapshot_dir);
    let mut ids = kea_snapshots::list_snapshot_ids(&snapshot_root).unwrap_or_default();
    ids.reverse(); // newest first for display
    ids.into_iter()
        .map(|id| KeaSnapshotSummary {
            created_unix: kea_snapshots::snapshot_created_unix(&id).unwrap_or(0),
            id,
        })
        .collect()
}

async fn fetch_leases(
    state: &AppState,
) -> Result<Vec<Lease>, Box<dyn std::error::Error + Send + Sync>> {
    let resp = kea_post(
        state,
        json!({"command": "lease4-get-all", "service": ["dhcp4"]}),
    )
    .await?;

    let mut leases = Vec::new();
    if let Some(lease_array) = resp
        .get(0)
        .and_then(|r| r.get("arguments"))
        .and_then(|a| a.get("leases"))
        .and_then(|l| l.as_array())
    {
        for lease in lease_array {
            // Kea reports a lease's client-lease-time (`cltt`, when it was
            // last renewed) and its lease duration (`valid-lft`) separately;
            // their sum is the absolute expiry time the Admin UI's
            // `formatDhcpExpiries()` JS renders as a human-readable
            // countdown/date.
            let cltt = lease.get("cltt").and_then(|v| v.as_i64()).unwrap_or(0);
            let valid_lft = lease.get("valid-lft").and_then(|v| v.as_i64()).unwrap_or(0);
            leases.push(Lease {
                subnet_id: lease.get("subnet-id").and_then(|v| v.as_u64()).unwrap_or(0) as u32,
                ip: lease
                    .get("ip-address")
                    .and_then(|v| v.as_str())
                    .unwrap_or("?")
                    .to_string(),
                mac: lease
                    .get("hw-address")
                    .and_then(|v| v.as_str())
                    .unwrap_or("?")
                    .to_string(),
                hostname: lease
                    .get("hostname")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string(),
                expires: (cltt + valid_lft).to_string(),
            });
        }
    }
    Ok(leases)
}

async fn fetch_all_reservations(
    state: &AppState,
) -> Result<Vec<Reservation>, Box<dyn std::error::Error + Send + Sync>> {
    Ok(fetch_reservations_from_config(
        &fetch_dhcp_config(state).await?,
    ))
}

async fn check_dhcp_probe(state: &AppState) -> DhcpCheckReport {
    // Serializes probe requests against the single predeclared dhcp-probe
    // container — concurrent /api/dhcp/check calls would otherwise race to
    // restart/attach/inspect the same container.
    let _guard = state.dhcp_probe_lock.lock().await;

    let output = match run_dhcp_probe(&state.docker).await {
        Ok(out) => out,
        Err(e) => {
            // Both statuses get the same diagnostic-rich reason -- neither
            // check actually ran, so there is no reason to give one of them
            // less detail than the other (issue #1136's follow-up: a bare
            // "timed out"/"did not complete" must not read the same whether
            // the probe was silently hung or was actively producing output
            // right up to the deadline; see ProbeError's Display impl).
            let reason = e.to_string();
            return DhcpCheckReport {
                conflict: DhcpConflictCheckStatus::Unavailable {
                    reason: reason.clone(),
                },
                client: DhcpClientCheckStatus::Unavailable { reason },
            };
        }
    };

    parse_dhcp_probe_report(&output)
}

// Strips nmap's own output decoration (`|` and `|_` prefixes nmap uses for
// script-result lines) so parse_conflict_probe_result's plain-text fallback
// scan (see below) can match "Server Identifier:" regardless of which
// nmap output line style produced it.
fn normalize_nmap_line(line: &str) -> &str {
    line.trim_start_matches(|ch: char| ch == '|' || ch == '_' || ch.is_whitespace())
        .trim_end()
}

const DHCP_PROBE_SERVICE: &str = "dhcp-probe";
const DHCP_PROBE_START_MARKER: &str = "__LANCACHE_DHCP_PROBE_START__";
const DHCP_CONFLICT_RESULT_MARKER: &str = "__LANCACHE_DHCP_CONFLICT_RESULT__";
const DHCP_CLIENT_RESULT_MARKER: &str = "__LANCACHE_DHCP_CLIENT_RESULT__";

// Bounded ceiling for a single dhcp-probe container wait (issue #1136: the
// previous code awaited Docker's wait_container with no timeout at all, so
// any future hang inside the probe script -- a stuck nmap scan, a dhclient
// behavior change, an unrelated container-runtime hiccup -- would block the
// Admin UI's /api/dhcp/check handler forever). Chosen against the actual
// worst case the probe script (services/ui/dhcp-probe.sh) can legitimately
// take today: nmap's own `broadcast-dhcp-discover.timeout=5` (5s) plus
// dhclient's `-1` built-in no-offer timeout (60s -- dhclient.conf(5)'s
// documented default when no explicit `timeout` statement is configured,
// and this probe script sets none) gives ~65s for a clean run that simply
// finds no DHCP server at all. 100s leaves a comfortable ~35s margin over
// that for container start/log-flush overhead, while still resolving in
// well under the "minutes" of masking the issue's follow-up comment warned
// against, and sits inside the 90-120s range the issue itself suggested.
const DHCP_PROBE_WAIT_TIMEOUT: Duration = Duration::from_secs(100);

// Trailing byte budget for the log tail captured at timeout time (see
// ProbeError::TimedOut / wait_for_probe_container below) -- long enough to
// show real diagnostic content (an operator/future reader can tell "it was
// silent the whole time" apart from "it was actively retrying right up to
// the deadline") without letting a noisy hung nmap/dhclient invocation blow
// up the surfaced Unavailable reason string without bound.
const DHCP_PROBE_TIMEOUT_LOG_TAIL_BYTES: usize = 2000;

// Distinguishes a bounded-timeout hang (DHCP_PROBE_WAIT_TIMEOUT elapsed with
// no result from the container) from every other run_dhcp_probe failure.
// check_dhcp_probe needs this split so a timed-out probe surfaces the
// diagnostic signal actually available at the moment of the timeout
// (elapsed time, whatever log output the container produced, whether the
// presumed-stuck container could even be stopped) instead of collapsing
// into the same bare, contentless "timed out" text every other failure
// would get -- the maintainer's follow-up catch on #1136: a bare timeout
// message must not read the same whether the probe was silently hung the
// whole time or was actively producing output/retrying right up to the
// deadline.
#[derive(Debug)]
enum ProbeError {
    TimedOut {
        elapsed: Duration,
        log_tail: String,
        stop_note: String,
    },
    Other(anyhow::Error),
}

impl std::fmt::Display for ProbeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ProbeError::TimedOut {
                elapsed,
                log_tail,
                stop_note,
            } => write!(
                f,
                "DHCP probe timed out after {:.0}s with no result from the container ({}). \
                 Captured probe output up to the timeout: {}",
                elapsed.as_secs_f64(),
                stop_note,
                log_tail
            ),
            ProbeError::Other(e) => write!(f, "Failed to execute DHCP check: {e}"),
        }
    }
}

impl std::error::Error for ProbeError {}

// Keeps only the trailing `max_bytes` of `text`, cut on a UTF-8 char
// boundary (never mid-codepoint, which would panic a naive byte slice) so a
// truncated timeout-time log capture can never crash the very diagnostic
// path it's meant to make more reliable. The trailing (not leading) bytes
// are kept because the most useful signal at timeout time is what the
// container was doing right before it got stuck, not what it printed first.
fn truncate_log_tail(text: &str, max_bytes: usize) -> String {
    let trimmed = text.trim();
    if trimmed.len() <= max_bytes {
        return trimmed.to_string();
    }
    let mut start = trimmed.len() - max_bytes;
    while start < trimmed.len() && !trimmed.is_char_boundary(start) {
        start += 1;
    }
    format!("...(truncated)... {}", trimmed[start..].trim())
}

// Wraps a single dhcp-probe container-wait future in `timeout` and, only on
// an actual timeout, captures whatever diagnostic signal is cheaply
// available before giving up: the log output the container produced up to
// that point (via `fetch_logs`, reusing collect_container_logs_since) and a
// best-effort stop of the presumed-stuck container (via `stop`, reusing
// stop_container_if_running) so the *next* /api/dhcp/check call isn't left
// fighting over the same wedged container. Generic over the wait future and
// the logs/stop operations (rather than taking `&bollard::Docker` and the
// container id directly) specifically so a test can exercise this real
// timeout-and-diagnostics logic against a wait future that simply never
// resolves -- the exact class of hang #1132/#1136 were about -- without
// needing a fake Docker daemon; see the `wait_for_probe_container_times_out`
// test below.
async fn wait_for_probe_container<T, W, LogsFut, StopFut>(
    wait_next: W,
    timeout: Duration,
    fetch_logs: impl FnOnce() -> LogsFut,
    stop: impl FnOnce() -> StopFut,
) -> Result<T, ProbeError>
where
    W: Future<Output = Option<Result<T, bollard::errors::Error>>>,
    LogsFut: Future<Output = Result<String, anyhow::Error>>,
    StopFut: Future<Output = Result<(), anyhow::Error>>,
{
    let start = Instant::now();
    match tokio::time::timeout(timeout, wait_next).await {
        Ok(Some(Ok(resp))) => Ok(resp),
        Ok(Some(Err(e))) => Err(ProbeError::Other(
            anyhow::Error::new(e).context("read DHCP probe wait response"),
        )),
        Ok(None) => Err(ProbeError::Other(anyhow::anyhow!(
            "DHCP probe container wait stream ended without a result"
        ))),
        Err(_elapsed) => {
            let elapsed = start.elapsed();
            let log_tail = match fetch_logs().await {
                Ok(logs) => {
                    let tail = truncate_log_tail(
                        &current_probe_output(&logs),
                        DHCP_PROBE_TIMEOUT_LOG_TAIL_BYTES,
                    );
                    if tail.is_empty() {
                        "(none -- the container produced no output before the timeout)".to_string()
                    } else {
                        tail
                    }
                }
                Err(e) => format!("(failed to capture probe container logs: {e})"),
            };
            let stop_note = match stop().await {
                Ok(()) => "the presumed-stuck container was stopped".to_string(),
                Err(e) => format!("stopping the presumed-stuck container also failed: {e}"),
            };
            Err(ProbeError::TimedOut {
                elapsed,
                log_tail,
                stop_note,
            })
        }
    }
}

// Restarts the predeclared dhcp-probe container fresh and runs it to
// completion (an nmap DHCP-conflict scan plus a dhclient dry-run, see
// services/dhcp-probe), then returns only the log output from this run.
// Two layers keep an old run's output from leaking into a new result:
// `started_since` (captured right after stopping the container) is passed
// to Docker's own log API as a `since` filter, and current_probe_output
// further discards anything before this run's own start marker within
// whatever logs that filter still let through.
async fn run_dhcp_probe(docker: &bollard::Docker) -> Result<String, ProbeError> {
    let id = docker_client::container_name_for_service(DHCP_PROBE_SERVICE)
        .context("resolve DHCP probe container")
        .map_err(ProbeError::Other)?;

    stop_container_if_running(docker, id)
        .await
        .map_err(ProbeError::Other)?;
    let started_since = unix_timestamp_seconds();

    docker
        .start_container(id, Some(StartContainerOptionsBuilder::default().build()))
        .await
        .context("start DHCP probe container")
        .map_err(ProbeError::Other)?;

    let mut wait = docker.wait_container(
        id,
        Some(
            WaitContainerOptionsBuilder::default()
                .condition("not-running")
                .build(),
        ),
    );
    let wait_result = wait_for_probe_container(
        wait.next(),
        DHCP_PROBE_WAIT_TIMEOUT,
        || collect_container_logs_since(docker, id, started_since),
        || stop_container_if_running(docker, id),
    )
    .await?;

    let output = collect_container_logs_since(docker, id, started_since)
        .await
        .context("read DHCP probe logs")
        .map_err(ProbeError::Other)?;
    let output = current_probe_output(&output);

    if wait_result.status_code != 0 {
        return Err(ProbeError::Other(anyhow::anyhow!(
            "DHCP probe container exited with code {}: {}",
            wait_result.status_code,
            output.trim()
        )));
    }

    Ok(output)
}

fn parse_dhcp_probe_report(output: &str) -> DhcpCheckReport {
    DhcpCheckReport {
        conflict: parse_conflict_probe_result(output),
        client: parse_client_probe_result(output),
    }
}

// Prefers the probe script's own explicit `__LANCACHE_DHCP_CONFLICT_RESULT__`
// marker line (see parse_probe_result_line) when present, since that's an
// unambiguous status the probe script itself computed (services/ui/dhcp-probe.sh
// always emits it). The raw nmap-output scan below it is a defensive
// fallback for output that doesn't include that marker line at all.
fn parse_conflict_probe_result(output: &str) -> DhcpConflictCheckStatus {
    if let Some((status, detail)) = parse_probe_result_line(output, DHCP_CONFLICT_RESULT_MARKER) {
        return match status {
            // `output` (the full multi-line container log, not `detail`,
            // which is only the marker line's single-word IP) is scanned
            // again here for the richer field list -- it still holds the
            // raw `cat "$nmap_out"` text services/ui/dhcp-probe.sh printed
            // before its own marker line (see current_probe_output, which
            // preserves everything after the run's start marker).
            "found" if !detail.is_empty() => DhcpConflictCheckStatus::Found {
                output: detail.to_string(),
                details: extract_dhcp_offer_details(output),
            },
            "not_found" => DhcpConflictCheckStatus::NotFound,
            "unavailable" => DhcpConflictCheckStatus::Unavailable {
                reason: if detail.is_empty() {
                    "nmap did not return a summary".to_string()
                } else {
                    detail.to_string()
                },
            },
            _ => DhcpConflictCheckStatus::Unavailable {
                reason: format!("unexpected conflict summary: {} {}", status, detail),
            },
        };
    }

    for line in output.lines() {
        let line = normalize_nmap_line(line);
        if let Some(rest) = line.strip_prefix("Server Identifier:") {
            let ip = rest.trim().to_string();
            if !ip.is_empty() {
                return DhcpConflictCheckStatus::Found {
                    output: ip,
                    details: extract_dhcp_offer_details(output),
                };
            }
        }
    }

    DhcpConflictCheckStatus::NotFound
}

// Known field labels nmap's broadcast-dhcp-discover script prints for a
// DHCPOFFER response, in the order the Admin UI should list them (not the
// order they happen to appear on the wire, which nmap does not guarantee is
// stable) -- see extract_dhcp_offer_details.
const DHCP_OFFER_DETAIL_LABELS: &[&str] = &[
    "Server Identifier",
    "IP Offered",
    "DHCP Message Type",
    "IP Address Lease Time",
    "Renewal Time Value",
    "Rebinding Time Value",
    "Subnet Mask",
    "Router",
    "Domain Name Server",
    "Domain Name",
    "Broadcast Address",
    "TFTP Server Name",
    "Vendor Class Identifier",
];

// Pulls the known identifying fields (see DHCP_OFFER_DETAIL_LABELS) nmap's
// broadcast-dhcp-discover script reports for a DHCPOFFER out of the probe
// container's full log text, so the Admin UI can show an operator more than
// just the bare Server Identifier IP already in DhcpConflictCheckStatus::
// Found's `output` field. Only the first response block is scanned:
// nmap prints one "Response N of M:" block per answering DHCP server when
// more than one replies, and mixing fields from a second, different server
// into one details list would misattribute e.g. its Router to the first
// server's Subnet Mask. Output that never has a "Response" line at all (the
// overwhelmingly common single-rogue-server case) has no such boundary and
// is scanned in full. First occurrence of each label wins, same as
// server_identifier's "take the first match" rule elsewhere in this file.
fn extract_dhcp_offer_details(output: &str) -> Vec<DhcpProbeDetail> {
    let mut found: BTreeMap<&'static str, String> = BTreeMap::new();
    let mut response_blocks_seen = 0u32;

    for line in output.lines() {
        let line = normalize_nmap_line(line);

        if let Some(rest) = line.strip_prefix("Response ") {
            if rest.contains(" of ") {
                response_blocks_seen += 1;
                if response_blocks_seen > 1 {
                    break;
                }
                continue;
            }
        }

        // `.iter().copied()` (not a bare `for label in DHCP_OFFER_DETAIL_LABELS`)
        // deliberately keeps `label` a single `&str` rather than `&&str` --
        // `str::strip_prefix` below needs a `Pattern`, which `&str` (but not
        // `&&str`) implements, and using the same single-reference type for
        // both the BTreeMap key and the Pattern argument avoids relying on
        // implicit deref coercion at either call site.
        for label in DHCP_OFFER_DETAIL_LABELS.iter().copied() {
            if found.contains_key(label) {
                continue;
            }
            if let Some(value) = line
                .strip_prefix(label)
                .and_then(|rest| rest.strip_prefix(':'))
            {
                let value = value.trim();
                if !value.is_empty() {
                    found.insert(label, value.to_string());
                }
                break;
            }
        }
    }

    DHCP_OFFER_DETAIL_LABELS
        .iter()
        .copied()
        .filter_map(|label| {
            found.get(label).map(|value| DhcpProbeDetail {
                label: label.to_string(),
                value: value.clone(),
            })
        })
        .collect()
}

// Known fields dhclient's own leases file (`-lf`, ISC "lease { ... }" syntax)
// records for a successfully bound lease, mapped to the human-readable label
// the Admin UI should show -- in display order (see extract_dhcp_lease_details).
// A dedicated table, not a reuse of DHCP_OFFER_DETAIL_LABELS: confirmed live
// (a real dhclient run, see dhcp-probe.sh's own comment on the dhclient
// invocation) that dhclient's stdout transcript never prints a "Label: value"
// breakdown at all -- only protocol-exchange lines -- and the leases file's
// own syntax uses ISC's internal option names (`routers`, `dhcp-lease-time`,
// ...), not nmap's human-readable ones, with some units differing too (e.g.
// `dhcp-lease-time` is a bare integer of seconds, unlike nmap's own
// duration-formatted "1h00m00s" for the equivalent field) -- so reusing
// DHCP_OFFER_DETAIL_LABELS's labels here would misleadingly imply identical
// formatting. The first element of each pair is the exact leases-file field
// name this label maps to (see extract_dhcp_lease_details for how bare vs
// `option`-prefixed keys are both normalized to this same key space).
const DHCP_LEASE_DETAIL_LABELS: &[(&str, &str)] = &[
    ("fixed-address", "Assigned IP Address"),
    ("dhcp-server-identifier", "Server Identifier"),
    ("subnet-mask", "Subnet Mask"),
    ("routers", "Router"),
    ("domain-name-servers", "Domain Name Server"),
    ("domain-name", "Domain Name"),
    ("broadcast-address", "Broadcast Address"),
    ("dhcp-lease-time", "Lease Time (seconds)"),
    ("dhcp-renewal-time", "Renewal Time (seconds)"),
    ("dhcp-rebinding-time", "Rebinding Time (seconds)"),
    ("ntp-servers", "NTP Servers"),
    ("host-name", "Host Name"),
    ("netbios-name-servers", "NetBIOS Name Server"),
];

// Pulls the known lease fields (see DHCP_LEASE_DETAIL_LABELS) out of the
// dhclient leases file text dhcp-probe.sh now cat's alongside a successful
// client dry-run's own stdout transcript (see its comment on the dhclient
// invocation). Only the LAST "lease { ... }" block is kept -- the opposite
// direction from extract_dhcp_offer_details's "first response block wins":
// a renewed/rebound lease appends a new block after the original rather than
// replacing it in place, so the most recent block is the one that reflects
// the lease dhclient is actually holding now. `found` is cleared every time
// a new "lease {" line is seen for exactly this reason: by the time every
// line has been scanned, only the final block's fields remain in it.
fn extract_dhcp_lease_details(output: &str) -> Vec<DhcpProbeDetail> {
    let mut found: BTreeMap<&'static str, String> = BTreeMap::new();

    for line in output.lines() {
        let line = line.trim().trim_end_matches(';');

        if line == "lease {" {
            found.clear();
            continue;
        }

        // Distinguishes `option <name> <value>` lines from the leases
        // file's own bare keyword lines (`fixed-address ...`, `renew ...`)
        // -- both end up compared against the same DHCP_LEASE_DETAIL_LABELS
        // key space below, since dhclient's option names never collide with
        // its bare structural keywords.
        let rest = line.strip_prefix("option ").unwrap_or(line);
        let Some((key, value)) = rest.split_once(char::is_whitespace) else {
            continue;
        };

        // Look up the label FIRST, then check/insert keyed by that
        // `&'static str` label -- not by `key` itself, which only borrows
        // from `output` and would be the wrong (and, for an unknown key,
        // entirely absent) thing to key `found` by. This also gives "first
        // occurrence within the current block wins", same rule as
        // extract_dhcp_offer_details.
        let Some((_, label)) = DHCP_LEASE_DETAIL_LABELS
            .iter()
            .copied()
            .find(|&(known_key, _)| known_key == key)
        else {
            continue;
        };
        if found.contains_key(label) {
            continue;
        }
        // Only a curated subset of fields (see DHCP_LEASE_DETAIL_LABELS) are
        // ever bare-quoted single strings (`domain-name`, `host-name`) --
        // deliberately not e.g. `domain-search`, whose value is itself a
        // comma-separated list of quoted strings that this simple
        // outer-quote strip would mangle. Since none of the curated fields
        // have that shape, stripping one matching outer quote pair here is
        // safe and just tidies up the Admin UI's rendered value.
        let value = value.trim();
        let value = value
            .strip_prefix('"')
            .and_then(|v| v.strip_suffix('"'))
            .unwrap_or(value);
        if !value.is_empty() {
            found.insert(label, value.to_string());
        }
    }

    DHCP_LEASE_DETAIL_LABELS
        .iter()
        .copied()
        .filter_map(|(_, label)| {
            found.get(label).map(|value| DhcpProbeDetail {
                label: label.to_string(),
                value: value.clone(),
            })
        })
        .collect()
}

// Same marker-line-first strategy as parse_conflict_probe_result, but for
// the dhclient dry-run's own result marker. Unlike that function, there is
// no plain-text fallback scan here -- if the marker line is absent, this
// falls straight through to "dhclient summary missing" below.
fn parse_client_probe_result(output: &str) -> DhcpClientCheckStatus {
    if let Some((status, detail)) = parse_probe_result_line(output, DHCP_CLIENT_RESULT_MARKER) {
        return match status {
            "passed" => DhcpClientCheckStatus::Passed {
                output: if detail.is_empty() {
                    "dhclient dry-run succeeded".to_string()
                } else {
                    detail.to_string()
                },
                details: extract_dhcp_lease_details(output),
            },
            "failed" => DhcpClientCheckStatus::Failed {
                output: if detail.is_empty() {
                    "dhclient dry-run failed".to_string()
                } else {
                    detail.to_string()
                },
            },
            "unavailable" => DhcpClientCheckStatus::Unavailable {
                reason: if detail.is_empty() {
                    "dhclient dry-run unavailable".to_string()
                } else {
                    detail.to_string()
                },
            },
            _ => DhcpClientCheckStatus::Unavailable {
                reason: format!("unexpected client summary: {} {}", status, detail),
            },
        };
    }

    DhcpClientCheckStatus::Unavailable {
        reason: "dhclient summary missing".to_string(),
    }
}

// Scans lines in reverse (last line matching the marker wins) so a marker
// that happens to appear earlier in unrelated log noise (e.g. echoed from a
// previous probe run's leftover buffer) never shadows this run's real,
// final result line.
fn parse_probe_result_line<'a>(output: &'a str, marker: &str) -> Option<(&'a str, &'a str)> {
    output.lines().rev().find_map(|line| {
        let line = line.trim();
        let rest = line.strip_prefix(marker)?;
        let rest = rest.trim_start();
        let (status, detail) = rest.split_once(' ').unwrap_or((rest, ""));
        Some((status.trim(), detail.trim()))
    })
}

// Reads every stdout/stderr log chunk emitted since `since` and concatenates
// them into one string for parse_dhcp_probe_report to scan -- Docker's log
// stream is delivered in arbitrary-sized chunks, not whole lines, so this
// must buffer everything before any line-based parsing can happen.
async fn collect_container_logs_since(
    docker: &bollard::Docker,
    id: &str,
    since: i32,
) -> Result<String, anyhow::Error> {
    let mut logs = docker.logs(
        id,
        Some(
            LogsOptionsBuilder::default()
                .stdout(true)
                .stderr(true)
                .since(since)
                .build(),
        ),
    );

    let mut output = String::new();
    while let Some(chunk) = logs.next().await {
        match chunk.context("read container log chunk")? {
            LogOutput::StdOut { message } | LogOutput::StdErr { message } => {
                output.push_str(&String::from_utf8_lossy(&message));
            }
            _ => {}
        }
    }

    Ok(output)
}

// Keeps only the output after the LAST start-marker line -- `rsplit_once`
// (not `split_once`) matters here: if Docker's `since` filter (see
// run_dhcp_probe) still let through part of a previous run's output ending
// in its own start marker, splitting on the first marker would return that
// stale run's output instead of the current one.
fn current_probe_output(output: &str) -> String {
    output
        .rsplit_once(DHCP_PROBE_START_MARKER)
        .map(|(_, current)| current.to_string())
        .unwrap_or_else(|| output.to_string())
}

// Docker's logs API `since` parameter takes an i32 second count, not the u64
// this project's other timestamp helpers use elsewhere -- clamped to
// i32::MAX rather than truncating/wrapping, since a wrapped value could come
// out negative or as an unrelated past timestamp.
fn unix_timestamp_seconds() -> i32 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs().min(i32::MAX as u64) as i32)
        .unwrap_or_default()
}

// Stops the probe container if a previous run left it running (it normally
// exits on its own, so this is the abnormal-state cleanup path before
// starting a fresh run).
async fn stop_container_if_running(
    docker: &bollard::Docker,
    id: &str,
) -> Result<(), anyhow::Error> {
    if let Err(e) = docker
        .stop_container(
            id,
            Some(StopContainerOptionsBuilder::default().t(5).build()),
        )
        .await
    {
        // Docker returns "not modified" if the one-shot helper is already
        // stopped. That is the expected steady state before a probe run.
        let message = e.to_string();
        if !message.contains("304") && !message.to_ascii_lowercase().contains("not modified") {
            return Err(e).context("stop DHCP probe container");
        }
    }

    Ok(())
}

// ─── Validators ───

fn normalize_mac(mac: &str) -> String {
    // Accept common operator input styles (`aa:bb`, `aa-bb`, `aabb`) by keeping
    // only hex digits, then rebuild the canonical colon-separated form used by
    // Kea reservations. Validation remains separate below, so this helper does
    // not silently accept malformed lengths.
    let hex: String = mac
        .to_lowercase()
        .chars()
        .filter(|c| c.is_ascii_hexdigit())
        .collect();

    // Reinsert a colon before every byte boundary after the first byte.
    hex.chars()
        .enumerate()
        .flat_map(|(i, c)| {
            if i > 0 && i % 2 == 0 {
                vec![':', c]
            } else {
                vec![c]
            }
        })
        .collect()
}

fn is_valid_ip(ip: &str) -> bool {
    parse_ipv4(ip).is_some()
}

// Accepts a MAC in either colon- or hyphen-separated form (both are common
// copy-paste sources for an operator entering a device's MAC) -- 12 hex
// digits after stripping either separator is the only shape check; the
// canonical colon form is produced separately by normalize_mac.
fn is_valid_mac(mac: &str) -> bool {
    let cleaned = mac.to_uppercase().replace([':', '-'], "");
    cleaned.len() == 12 && cleaned.chars().all(|c| c.is_ascii_hexdigit())
}

// Groups every field add_subnet/update_subnet must validate together, since
// several checks are cross-field (pool bounds within the subnet's own CIDR,
// pool_start <= pool_end) rather than checkable per-field in isolation.
struct DhcpFormValidation<'a> {
    subnet: &'a str,
    pool_start: &'a str,
    pool_end: &'a str,
    gateway: &'a str,
    dns_primary: &'a str,
    dns_secondary: &'a str,
    ntp_servers: &'a str,
    lease_time: &'a str,
    // Optional, same as update_dhcp_proxy's own `dhcp_proxy_domain` field:
    // an empty value means Kea's subnet4 entry gets no domain-name/
    // domain-search option at all, which is a valid, already-supported
    // state, not a form error.
    domain: &'a str,
}

// Returns the parsed lease_time on success (the one field the caller still
// needs as a typed value afterward; everything else is consumed as owned
// Strings by build_subnet_value/apply_subnet_value instead).
fn validate_dhcp_form(input: DhcpFormValidation<'_>) -> Result<u32, StatusCode> {
    let (subnet_addr, prefix_len) = parse_cidr(input.subnet).ok_or(StatusCode::BAD_REQUEST)?;
    let pool_start_addr = parse_ipv4(input.pool_start).ok_or(StatusCode::BAD_REQUEST)?;
    let pool_end_addr = parse_ipv4(input.pool_end).ok_or(StatusCode::BAD_REQUEST)?;
    let gateway_addr = parse_ipv4(input.gateway).ok_or(StatusCode::BAD_REQUEST)?;
    let dns_primary_addr = parse_ipv4(input.dns_primary).ok_or(StatusCode::BAD_REQUEST)?;
    // An empty secondary DNS field is allowed (it's optional on the form),
    // but if given, it must still be a valid address -- parsed here as
    // `dns_primary_addr` only to reuse the same "is it valid" check, since
    // this function only reports success/failure, not the parsed values
    // themselves.
    let _dns_secondary_addr = if input.dns_secondary.trim().is_empty() {
        dns_primary_addr
    } else {
        parse_ipv4(input.dns_secondary).ok_or(StatusCode::BAD_REQUEST)?
    };

    if !ipv4_in_cidr(subnet_addr, prefix_len, pool_start_addr)
        || !ipv4_in_cidr(subnet_addr, prefix_len, pool_end_addr)
        || !ipv4_in_cidr(subnet_addr, prefix_len, gateway_addr)
        || ipv4_to_u32(pool_start_addr) > ipv4_to_u32(pool_end_addr)
    {
        return Err(StatusCode::BAD_REQUEST);
    }

    if !input.ntp_servers.trim().is_empty() && parse_ntp_server_list(input.ntp_servers).is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }

    // Issue #947: add_subnet/update_subnet used to pass form.domain straight
    // into build_subnet_value/apply_subnet_value with zero validation, even
    // though update_dhcp_proxy already validates its own analogous
    // dhcp_proxy_domain field with this exact check. Only validated when
    // non-empty (see the field's doc comment above) -- an empty domain is an
    // existing, already-supported state, not a rejection case.
    if !input.domain.trim().is_empty() && !is_valid_domain_name(input.domain) {
        return Err(StatusCode::BAD_REQUEST);
    }

    let lease_time = input
        .lease_time
        .parse::<u32>()
        .map_err(|_| StatusCode::BAD_REQUEST)?;
    if !(MIN_LEASE_TIME..=MAX_LEASE_TIME).contains(&lease_time) {
        return Err(StatusCode::BAD_REQUEST);
    }

    Ok(lease_time)
}

fn parse_ipv4(ip: &str) -> Option<Ipv4Addr> {
    Ipv4Addr::from_str(ip).ok()
}

// Parses "a.b.c.d/N" and rejects anything where the host bits aren't
// already zero (e.g. "192.168.1.5/24" is rejected -- the address part must
// be the network's own base address, not an arbitrary host within it) --
// this is what actually enforces that an operator enters a real network
// address in the subnet field, not just any address with a slash after it.
fn parse_cidr(cidr: &str) -> Option<(Ipv4Addr, u8)> {
    let (addr, prefix) = cidr.split_once('/')?;
    let network = parse_ipv4(addr)?;
    let prefix_len = prefix.parse::<u8>().ok()?;
    if prefix_len > 32 {
        return None;
    }
    let network_u32 = ipv4_to_u32(network);
    let mask = if prefix_len == 0 {
        0
    } else {
        u32::MAX << (32 - prefix_len)
    };
    if prefix_len != 0 && network_u32 & !mask != 0 {
        return None;
    }
    Some((Ipv4Addr::from(network_u32 & mask), prefix_len))
}

// `network` here is always parse_cidr's already-masked output (host bits
// zero), so masking `ip` the same way and comparing is a correct
// same-subnet test regardless of which host address within the subnet `ip`
// is.
fn ipv4_in_cidr(network: Ipv4Addr, prefix_len: u8, ip: Ipv4Addr) -> bool {
    let mask = if prefix_len == 0 {
        0
    } else {
        u32::MAX << (32 - prefix_len)
    };
    ipv4_to_u32(network) & mask == ipv4_to_u32(ip) & mask
}

fn ipv4_to_u32(ip: Ipv4Addr) -> u32 {
    u32::from(ip)
}

// Read-only counterpart of dhcp4_subnets_mut below, used by the data
// fetchers (fetch_subnets_from_config, fetch_reservations_from_config)
// which only display config, never modify it -- returns a plain Option
// rather than a Result since a fetch's fail-open convention treats a
// missing/malformed subnet4 array the same as "no subnets" (see
// fetch_subnets_from_config's own comment), not a hard error.
fn dhcp4_subnets(config: &Value) -> Option<&Vec<Value>> {
    config
        .get("Dhcp4")
        .and_then(|dhcp4| dhcp4.get("subnet4"))
        .and_then(|subnets| subnets.as_array())
}

fn dhcp4_subnets_mut(config: &mut Value) -> Result<&mut Vec<Value>, &'static str> {
    config
        .get_mut("Dhcp4")
        .ok_or("Dhcp4 missing")?
        .get_mut("subnet4")
        .ok_or("subnet4 missing")?
        .as_array_mut()
        .ok_or("subnet4 not an array")
}

// Absence of this key means Kea falls back to its own compiled-in default
// list, which includes "hw-address" -- only an explicit, hand-edited global
// list can exclude it (see the call site in add_reservation for why this
// matters: a hw-address reservation Kea will never actually match).
fn global_reservation_identifiers_include_hw_address(config: &Value) -> bool {
    match config
        .get("Dhcp4")
        .and_then(|dhcp4| dhcp4.get("host-reservation-identifiers"))
    {
        None => true,
        Some(value) => value
            .as_array()
            .map(|identifiers| {
                identifiers
                    .iter()
                    .any(|identifier| identifier.as_str() == Some("hw-address"))
            })
            .unwrap_or(false),
    }
}

fn find_subnet_mut(config: &mut Value, subnet_id: u32) -> Result<&mut Value, &'static str> {
    dhcp4_subnets_mut(config)?
        .iter_mut()
        .find(|subnet| subnet["id"].as_u64() == Some(subnet_id as u64))
        .ok_or("subnet not found")
}

struct SubnetValue {
    id: u32,
    subnet: String,
    pool_start: String,
    pool_end: String,
    gateway: String,
    dns_primary: String,
    dns_secondary: String,
    ntp_servers: String,
    domain: String,
    lease_time: u32,
    editable_options: Vec<Value>,
    reservations: Option<Vec<Value>>,
}

fn build_subnet_value(input: SubnetValue) -> Result<Value, &'static str> {
    let mut subnet_value = json!({});
    apply_subnet_value(&mut subnet_value, input)?;
    Ok(subnet_value)
}

fn apply_subnet_value(entry: &mut Value, input: SubnetValue) -> Result<(), &'static str> {
    // Clamp to MAX_LEASE_TIME: doubling the form value alone would let a
    // client at the advertised 7-day cap request up to 14 days from Kea.
    let max_valid_lifetime = input
        .lease_time
        .checked_mul(2)
        .ok_or("lease_time too large")?
        .min(MAX_LEASE_TIME);
    let entry = entry.as_object_mut().ok_or("subnet not an object")?;

    entry.insert("id".to_string(), json!(input.id));
    entry.insert("subnet".to_string(), json!(input.subnet));
    entry.insert(
        "pools".to_string(),
        json!([{"pool": format!("{} - {}", input.pool_start, input.pool_end)}]),
    );
    entry.insert(
        "option-data".to_string(),
        Value::Array(build_subnet_options(
            input.editable_options,
            input.gateway,
            input.dns_primary,
            input.dns_secondary,
            input.ntp_servers,
            input.domain,
        )),
    );
    entry.insert("valid-lifetime".to_string(), json!(input.lease_time));
    entry.insert("max-valid-lifetime".to_string(), json!(max_valid_lifetime));
    entry.remove("default-lease-time");
    entry.remove("max-lease-time");
    // `host-reservation-identifiers` is a Dhcp4-GLOBAL-only parameter in real
    // Kea (confirmed directly against Kea 2.6.3, the version this project
    // ships): setting it here, on the per-subnet object, makes Kea reject
    // the whole config-test/config-set call outright with "spurious
    // 'host-reservation-identifiers' parameter" -- every add_subnet/
    // update_subnet call was broken against real Kea until this was removed.
    // Nothing needs to be written in its place: Kea's own compiled-in
    // global default already includes "hw-address" (confirmed via a live
    // config-get), which is the only identifier type this project's
    // reservation form ever uses, and `kea_config_modify`'s config-get ->
    // config-set round trip already carries that default straight through
    // untouched. The explicit `remove` below is defense-in-depth in case a
    // config ever has this key at subnet scope (e.g. a hand-edited file, or
    // a future regression reintroducing the old write) -- Kea would reject
    // an update to that subnet either way, so stripping it here keeps
    // add_subnet/update_subnet self-healing instead of permanently stuck.
    entry.remove("host-reservation-identifiers");

    if let Some(reservations) = input.reservations {
        entry.insert("reservations".to_string(), Value::Array(reservations));
    }

    Ok(())
}

// Rebuilds a subnet's option-data array: `editable_options` (the subnet's
// custom options, already stripped of UI-managed entries by the caller via
// preserved_subnet_options) plus a fresh "routers"/"domain-name-servers"/
// "domain-name"/"domain-search"/"ntp-servers" entry built from this save's
// form fields. The `retain` call here is a defensive second filter, not the
// primary one -- it makes this function safe to call even if a future
// caller passes an unfiltered options list.
fn build_subnet_options(
    mut editable_options: Vec<Value>,
    gateway: String,
    dns_primary: String,
    dns_secondary: String,
    ntp_servers: String,
    domain: String,
) -> Vec<Value> {
    editable_options.retain(|option| !is_ui_managed_subnet_option(option));

    editable_options.push(json!({"name": "routers", "data": gateway}));
    editable_options.push(json!({
        "name": "domain-name-servers",
        "data": format_dns_server_option(&dns_primary, &dns_secondary)
    }));
    editable_options.push(json!({"name": "domain-name", "data": domain}));
    editable_options.push(json!({"name": "domain-search", "data": domain}));
    if let Some(data) = format_ntp_server_option(&ntp_servers) {
        editable_options.push(json!({"name": "ntp-servers", "data": data}));
    }
    editable_options
}

// Returns a subnet's option-data entries EXCLUDING the ones the dedicated
// gateway/DNS/domain/NTP form fields manage -- these are the operator's own
// custom options (added via add_subnet_option), which update_subnet must
// carry forward untouched since its form has no field for them.
fn preserved_subnet_options(subnet: &Value) -> Vec<Value> {
    subnet
        .get("option-data")
        .and_then(|value| value.as_array())
        .map(|options| {
            options
                .iter()
                .filter(|option| !is_ui_managed_subnet_option(option))
                .cloned()
                .collect()
        })
        .unwrap_or_default()
}

// True for an option-data entry that one of the dedicated subnet form
// fields owns (routers/domain-name/domain-search/domain-name-servers/
// ntp-servers, by name or by their well-known Kea/DHCP option codes
// 3/6/15/42/119) -- matched by name OR code because Kea accepts an option
// specified either way, and an entry this project itself wrote or an
// operator hand-edited one could use either form.
fn is_ui_managed_subnet_option(option: &Value) -> bool {
    if !is_dhcp4_option_space(option) {
        return false;
    }

    let managed_by_name = option
        .get("name")
        .and_then(|value| value.as_str())
        .map(|name| {
            matches!(
                name,
                "routers" | "domain-name" | "domain-search" | "domain-name-servers" | "ntp-servers"
            )
        })
        .unwrap_or(false);
    let managed_by_code = option
        .get("code")
        .and_then(|value| value.as_u64())
        .map(|code| matches!(code, 3 | 6 | 15 | 42 | 119))
        .unwrap_or(false);

    managed_by_name || managed_by_code
}

// Code-only version of the check above, used by add_subnet_option/
// remove_subnet_option (see parse_custom_dhcp_option_code below) to reject a
// custom-option submission for one of these codes before it ever reaches
// the config -- these codes must only ever be set via the dedicated form
// fields, never the free-form custom option list, so there is exactly one
// way to configure each of them.
fn is_ui_managed_subnet_option_code(code: u16) -> bool {
    matches!(code, 3 | 6 | 15 | 42 | 119)
}

// Kea's own convention: an option-data entry inside a Dhcp4 subnet with no
// explicit "space" field implicitly belongs to the "dhcp4" space (that's the
// only space that makes sense there). Absence must default to true, not
// false, or every option this project itself writes without an explicit
// "space" (see build_subnet_options) would be misclassified as non-dhcp4 by
// this same check the moment it reads its own output back.
fn is_dhcp4_option_space(option: &Value) -> bool {
    option
        .get("space")
        .and_then(|value| value.as_str())
        .map(|space| space == "dhcp4")
        .unwrap_or(true)
}

// 0 and 255+ are excluded: DHCPv4 option code 0 is the reserved "Pad"
// option and 255 is "End", neither a real configurable option; the rest of
// the valid DHCPv4 option space (1-254) is otherwise open here except for
// the five codes is_ui_managed_subnet_option_code reserves for the
// dedicated form fields.
fn parse_custom_dhcp_option_code(raw: &str) -> Result<u16, &'static str> {
    let code = raw
        .trim()
        .parse::<u16>()
        .map_err(|_| "option code must be a number")?;
    if code == 0 || code > 254 {
        return Err("option code must be between 1 and 254");
    }
    if is_ui_managed_subnet_option_code(code) {
        return Err("option code is managed by dedicated subnet fields");
    }
    Ok(code)
}

// Data itself is stored as an opaque string (Kea's own option-data "data"
// field accepts whatever encoding the option type expects); only the shape
// constraints that would break this project's own storage/rendering are
// checked here, not the value's meaning for a given option code.
fn validate_custom_dhcp_option_data(raw: &str) -> Result<String, &'static str> {
    let data = raw.trim();
    if data.is_empty() {
        return Err("option data must not be empty");
    }
    if data.len() > CUSTOM_DHCP_OPTION_DATA_MAX_LEN {
        return Err("option data is too long");
    }
    if data.chars().any(|ch| ch == '\n' || ch == '\r') {
        return Err("option data must fit on one line");
    }
    Ok(data.to_string())
}

// The three legacy BOOTP/PXE fields Kea exposes as top-level subnet
// parameters (next-server/server-hostname/boot-file-name -> the BOOTP
// siaddr/sname/file fields), NOT as numbered options in `option-data`. The
// Admin UI groups them into the same "custom options" picker as the numbered
// options for consistency (maintainer's call, 2026-07-22), so the add/remove
// option routes accept these three string keys in addition to a numeric code
// and route them to the subnet's top-level JSON keys instead of its
// option-data array.
const PXE_SUBNET_FIELDS: [&str; 3] = ["next-server", "server-hostname", "boot-file-name"];

// Kea caps server-hostname (BOOTP `sname`) at 64 bytes and boot-file-name
// (BOOTP `file`) at 128 bytes. Rejecting an over-long value here gives the
// operator an immediate, specific error instead of a later Kea config-test
// rejection surfaced only as a config_error from kea_config_modify.
const KEA_SERVER_HOSTNAME_MAX_LEN: usize = 64;
const KEA_BOOT_FILE_NAME_MAX_LEN: usize = 128;

// A parsed custom-option "code" field: either a numbered DHCP option (stored
// in the subnet's option-data array) or one of the three top-level PXE subnet
// fields (stored as a top-level subnet key). See PXE_SUBNET_FIELDS for why
// both share one form field.
#[derive(Clone, Copy)]
enum CustomOptionKey {
    Numeric(u16),
    Pxe(&'static str),
}

// Accepts either one of the three PXE field names verbatim or, failing that,
// a numeric code via the existing numeric validator. The PxeField arm carries
// a &'static str borrowed from PXE_SUBNET_FIELDS (not the caller's input), so
// downstream writes use a known-good key name.
fn parse_custom_option_key(raw: &str) -> Result<CustomOptionKey, &'static str> {
    let trimmed = raw.trim();
    // into_iter() over the &'static str array yields owned &'static str
    // elements, so the matched name can be stored in the Pxe variant directly.
    if let Some(field) = PXE_SUBNET_FIELDS
        .into_iter()
        .find(|&field| field == trimmed)
    {
        return Ok(CustomOptionKey::Pxe(field));
    }
    parse_custom_dhcp_option_code(trimmed).map(CustomOptionKey::Numeric)
}

// Validates the "data" value against what the chosen key accepts: next-server
// must be a bare IPv4 address (Kea rejects a hostname there);
// server-hostname/boot-file-name are free-form one-line strings bounded to
// their BOOTP field sizes; a numbered option keeps the generic opaque-string
// rules (see validate_custom_dhcp_option_data).
fn validate_custom_option_data(key: CustomOptionKey, raw: &str) -> Result<String, &'static str> {
    match key {
        CustomOptionKey::Pxe("next-server") => {
            let data = raw.trim();
            if !is_valid_ip(data) {
                return Err("next-server must be a valid IPv4 address");
            }
            Ok(data.to_string())
        }
        CustomOptionKey::Pxe(field) => {
            let data = validate_custom_dhcp_option_data(raw)?;
            let max = if field == "server-hostname" {
                KEA_SERVER_HOSTNAME_MAX_LEN
            } else {
                KEA_BOOT_FILE_NAME_MAX_LEN
            };
            if data.len() > max {
                return Err("value is too long for this field");
            }
            Ok(data)
        }
        CustomOptionKey::Numeric(_) => validate_custom_dhcp_option_data(raw),
    }
}

// Writes one of the three top-level PXE subnet fields. Unlike a numbered
// option (which lives in an array and can legitimately repeat), each of these
// is a single-valued subnet key, so this overwrites any existing value; an
// exact-duplicate write is still rejected to guard against a double form
// submission, mirroring add_custom_subnet_option.
fn set_pxe_subnet_field(subnet: &mut Value, field: &str, data: &str) -> Result<(), &'static str> {
    let subnet = subnet.as_object_mut().ok_or("subnet not an object")?;
    if subnet.get(field).and_then(|value| value.as_str()) == Some(data) {
        return Err("custom option already exists");
    }
    subnet.insert(field.to_string(), json!(data));
    Ok(())
}

// Clears a top-level PXE subnet field, but only when its current value
// matches `data`. The remove form echoes back the value being removed, so
// matching on it prevents clearing a field whose value changed between page
// render and submit -- the same code+data match contract
// remove_custom_subnet_option uses for numbered options.
fn remove_pxe_subnet_field(
    subnet: &mut Value,
    field: &str,
    data: &str,
) -> Result<(), &'static str> {
    let subnet = subnet.as_object_mut().ok_or("subnet not an object")?;
    match subnet.get(field).and_then(|value| value.as_str()) {
        Some(current) if current == data => {
            subnet.remove(field);
            Ok(())
        }
        _ => Err("custom option not found"),
    }
}

// True for an option-data entry that is a genuine operator-added custom
// option: dhcp4-space, NOT one of the UI-managed fields (see
// is_ui_managed_subnet_option), has a numeric code in the valid range, and
// has string data. This is the same "does this look like a real custom
// option" test used both to display them (custom_subnet_options) and to
// match one for add/remove (add_custom_subnet_option/
// remove_custom_subnet_option) -- an entry missing "code" or "data" isn't
// something this UI ever wrote, so it's excluded from both.
fn is_custom_dhcp4_option(option: &Value) -> bool {
    is_dhcp4_option_space(option)
        && !is_ui_managed_subnet_option(option)
        && option
            .get("code")
            .and_then(|value| value.as_u64())
            .map(|code| (1..=254).contains(&code))
            .unwrap_or(false)
        && option
            .get("data")
            .and_then(|value| value.as_str())
            .is_some()
}

// Surfaces a subnet's custom (non-UI-managed) options for the read-model
// Subnet struct's `custom_options` field, rendered as a table on the
// settings page.
fn custom_subnet_options(subnet: &Value) -> Vec<DhcpOption> {
    subnet
        .get("option-data")
        .and_then(|value| value.as_array())
        .map(|options| {
            options
                .iter()
                .filter(|option| is_custom_dhcp4_option(option))
                .filter_map(|option| {
                    let code = option.get("code")?.as_u64()?;
                    Some(DhcpOption {
                        code: u16::try_from(code).ok()?,
                        data: option.get("data")?.as_str()?.to_string(),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

// A brand-new subnet (see add_subnet) has no "option-data" key at all yet --
// this creates an empty array in that case so add_custom_subnet_option can
// push into it uniformly, instead of every caller needing its own
// key-missing handling.
fn subnet_options_mut(subnet: &mut Value) -> Result<&mut Vec<Value>, &'static str> {
    let subnet = subnet.as_object_mut().ok_or("subnet not an object")?;
    if !subnet.contains_key("option-data") {
        subnet.insert("option-data".to_string(), Value::Array(Vec::new()));
    }
    subnet
        .get_mut("option-data")
        .and_then(|value| value.as_array_mut())
        .ok_or("option-data not an array")
}

// Rejects an exact code+data duplicate rather than silently accepting a
// second identical entry -- Kea would apply both, which is never useful and
// likely indicates a double form submission.
fn add_custom_subnet_option(subnet: &mut Value, code: u16, data: &str) -> Result<(), &'static str> {
    let options = subnet_options_mut(subnet)?;
    if options.iter().any(|option| {
        is_custom_dhcp4_option(option)
            && option.get("code").and_then(|value| value.as_u64()) == Some(code as u64)
            && option.get("data").and_then(|value| value.as_str()) == Some(data)
    }) {
        return Err("custom option already exists");
    }
    options.push(json!({"space": "dhcp4", "code": code, "data": data}));
    Ok(())
}

fn remove_custom_subnet_option(
    subnet: &mut Value,
    code: u16,
    data: &str,
) -> Result<(), &'static str> {
    let options = subnet_options_mut(subnet)?;
    let before = options.len();
    options.retain(|option| {
        !(is_custom_dhcp4_option(option)
            && option.get("code").and_then(|value| value.as_u64()) == Some(code as u64)
            && option.get("data").and_then(|value| value.as_str()) == Some(data))
    });
    if options.len() == before {
        return Err("custom option not found");
    }
    Ok(())
}

// Kea's option-data "data" string for a multi-value option (like
// domain-name-servers) is comma-separated; this also tolerates
// whitespace-separated input from parse_subnet_entry's read side, since
// that is easier to type/paste in a form field than strict commas.
fn split_option_list(raw: &str) -> Vec<String> {
    raw.split(|ch: char| ch == ',' || ch.is_whitespace())
        .map(str::trim)
        .filter(|item| !item.is_empty())
        .map(str::to_string)
        .collect()
}

// Omits the secondary server entirely when it's blank or identical to the
// primary, rather than writing e.g. "8.8.8.8, 8.8.8.8" -- Kea would accept a
// duplicate, but it adds nothing and would misleadingly imply two distinct
// DNS servers are configured when there's really just one.
fn format_dns_server_option(primary: &str, secondary: &str) -> String {
    if secondary.trim().is_empty() || secondary.trim() == primary.trim() {
        primary.trim().to_string()
    } else {
        format!("{}, {}", primary.trim(), secondary.trim())
    }
}

// Unlike DNS (always written, even if just one server), the NTP option
// itself is entirely omitted from the subnet's option-data when the form
// field is empty -- returning None here (rather than an empty string) is
// what lets build_subnet_options skip adding an "ntp-servers" entry at all.
fn format_ntp_server_option(ntp_servers: &str) -> Option<String> {
    let servers = parse_ntp_server_list(ntp_servers);
    if servers.is_empty() {
        None
    } else {
        Some(servers.join(", "))
    }
}

fn parse_ntp_server_list(raw: &str) -> Vec<String> {
    split_option_list(raw)
}

// One entry of a parsed NTP server list, split into the three shapes
// resolve_ntp_servers below has to handle differently: an entry that is
// already the IPv4 literal Kea's ntp-servers option-42 data requires
// (written straight through), one that names a host and therefore needs a
// DNS lookup first, or one that only looks like a botched IPv4 literal
// (digits and dots, but not a valid a.b.c.d address -- e.g. "1.2.3" or
// "999999999") and must be rejected outright rather than handed to DNS.
// Kept as a separate, pure classification step -- rather than inlining the
// `Ipv4Addr::from_str` check into the async resolver -- so this decision is
// unit-testable without a resolver or network access, mirroring
// nginx_client.rs's split between IO (e.g. get_stub_status) and its pure
// parsing helper (parse_stub_status).
#[derive(Debug, PartialEq)]
enum NtpServerEntry {
    Ipv4(Ipv4Addr),
    Hostname(String),
    MalformedAddress(String),
}

// A digit-and-dot-only token is never a legitimate DNS hostname (real
// hostname labels always contain a letter), so once it has already failed
// strict `Ipv4Addr::from_str` parsing, the only thing it can be is a typo'd
// IPv4 literal (e.g. "1.2.3" or "999999999"). Whether the OS resolver would
// accept such legacy/non-standard numeric syntax and silently return some
// IPv4 for it is platform- and NSS-config-dependent and not something this
// code should rely on either way -- routing it through classify_ntp_entry's
// Hostname branch would risk exactly that: writing an unintended NTP server
// where Kea's own strict "ipv4-address" option-42 validation would
// previously have rejected the config outright with a clear error. Treating
// it as MalformedAddress instead keeps that same fail-fast, typo-catching
// behavior, just surfaced as this project's own 400 instead of Kea's.
//
// Deliberate tradeoff: a bare all-digit token like "123" is also rejected
// here even though it is technically a valid DNS label -- it was never a
// valid Kea ntp-servers entry before this PR either (Kea requires a real
// IPv4 literal), and as a "hostname" it would be exceptionally unusual, so
// failing fast on it matches user intent far more often than not. Hex
// (`0x7f000001`) forms are not covered here -- Rust's `Ipv4Addr::from_str`
// already rejects those as invalid, so they fall into this same digit-only
// check when hex digits happen to be pure ASCII digits, but genuine hex
// letters (a-f) will still be classified as Hostname; this is a known,
// narrow gap, not something #670 or its review asked to be closed.
fn looks_like_malformed_ipv4(entry: &str) -> bool {
    !entry.is_empty() && entry.chars().all(|ch| ch.is_ascii_digit() || ch == '.')
}

fn classify_ntp_entry(entry: &str) -> NtpServerEntry {
    match Ipv4Addr::from_str(entry) {
        Ok(addr) => NtpServerEntry::Ipv4(addr),
        Err(_) if looks_like_malformed_ipv4(entry) => {
            NtpServerEntry::MalformedAddress(entry.to_string())
        }
        Err(_) => NtpServerEntry::Hostname(entry.to_string()),
    }
}

// Resolves every entry of a comma/whitespace-separated NTP server list to an
// IPv4 literal before it is written into Kea's ntp-servers option-data.
// Mirrors entrypoint.sh's resolve_ntp_csv/resolve_ntp_server, which already
// perform this same resolution for the INITIAL Kea config rendered from
// DHCP_NTP_SERVERS (#310/PR#311) -- this is the missing counterpart for the
// Admin UI's live add_subnet/update_subnet mutation path (#670), which
// otherwise writes DHCP_NTP_SERVERS' shipped default
// ("debian.pool.ntp.org,time.nist.gov") straight into Kea's option-42 data
// and lets Kea reject it with its own confusing config-set error instead of
// this project ever resolving it or explaining the failure.
//
// `tokio::net::lookup_host` is used rather than a new resolver dependency:
// it is backed by the OS resolver (getaddrinfo), the same NSS-based lookup
// `getent` performs on the bash side, and `tokio` (with the "full" feature,
// already a dependency here) already ships it. A lookup target needs a port
// per `ToSocketAddrs`'s contract, hence the harmless `:0` suffix -- it is
// never connected to, only resolved.
//
// Only the first IPv4 result of a hostname's lookup is kept: Kea's option 42
// is IPv4-only, so an AAAA-only answer is treated the same as no answer at
// all, producing the same clear, entry-naming error as an NXDOMAIN would --
// surfaced as a 400 from this project's own code, before the value ever
// reaches Kea's Control Agent.
async fn resolve_ntp_servers(raw: &str) -> Result<String, String> {
    let mut resolved = Vec::new();

    for entry in parse_ntp_server_list(raw) {
        let ipv4 = match classify_ntp_entry(&entry) {
            NtpServerEntry::Ipv4(addr) => addr,
            NtpServerEntry::MalformedAddress(bad) => {
                return Err(format!("NTP server '{bad}' is not a valid IPv4 address"));
            }
            NtpServerEntry::Hostname(host) => {
                let lookup_target = format!("{host}:0");
                let mut addrs = tokio::net::lookup_host(lookup_target).await.map_err(|_| {
                    format!("NTP server '{host}' is not an IPv4 address and could not be resolved via DNS")
                })?;
                addrs
                    .find_map(|addr| match addr.ip() {
                        std::net::IpAddr::V4(ip) => Some(ip),
                        std::net::IpAddr::V6(_) => None,
                    })
                    .ok_or_else(|| {
                        format!("NTP server '{host}' resolved but has no IPv4 address")
                    })?
            }
        };
        resolved.push(ipv4.to_string());
    }

    Ok(resolved.join(", "))
}

// Converts one Kea subnet4 JSON entry back into the Subnet read-model for
// display. The inner `opt` closure looks up a built-in option by name OR by
// its well-known code, since a subnet's option-data can specify either form
// (see is_custom_dhcp4_option's own comment on the same ambiguity) -- a
// value written by name must still be found here even though this project's
// own writes always use "name", not "code".
fn parse_subnet_entry(subnet: &Value) -> Subnet {
    // Only the first pool range is read back (Kea allows multiple pools per
    // subnet, but add_subnet/update_subnet only ever write one), in the
    // exact "start - end" format build_subnet_value writes it in.
    let pool = subnet
        .get("pools")
        .and_then(|p| p.get(0))
        .and_then(|p| p.get("pool"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let pool_parts: Vec<&str> = pool.splitn(2, " - ").collect();

    let opt = |name: &str, code: u64| {
        subnet
            .get("option-data")
            .and_then(|od| od.as_array())
            .and_then(|arr| {
                arr.iter().find(|o| {
                    is_dhcp4_option_space(o)
                        && (o.get("name").and_then(|v| v.as_str()) == Some(name)
                            || o.get("code").and_then(|v| v.as_u64()) == Some(code))
                })
            })
            .and_then(|o| o.get("data"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    };
    let dns_servers = split_option_list(&opt("domain-name-servers", 6));
    let ntp_servers = opt("ntp-servers", 42);

    Subnet {
        id: subnet.get("id").and_then(|v| v.as_u64()).unwrap_or(0) as u32,
        subnet: subnet
            .get("subnet")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        pool_start: pool_parts
            .first()
            .map(|s| s.trim().to_string())
            .unwrap_or_default(),
        pool_end: pool_parts
            .get(1)
            .map(|s| s.trim().to_string())
            .unwrap_or_default(),
        gateway: opt("routers", 3),
        dns_primary: dns_servers.first().cloned().unwrap_or_default(),
        dns_secondary: dns_servers.get(1).cloned().unwrap_or_default(),
        ntp_servers,
        // 86400 (24h) matches Kea's own compiled-in default valid-lifetime;
        // this project's own writes always set this field explicitly, so
        // the fallback only matters for a subnet from a hand-edited or
        // externally-managed config that omitted it.
        lease_time: subnet
            .get("valid-lifetime")
            .and_then(|v| v.as_u64())
            .unwrap_or(86400) as u32,
        domain: opt("domain-name", 15),
        custom_options: custom_subnet_options(subnet),
    }
}

// Called from update_subnet when an operator narrows/moves a subnet's CIDR:
// drops any reservation whose static IP would fall outside the new range,
// since Kea rejects a subnet whose own reservations aren't contained in it.
// A reservation with no parseable `ip-address` (e.g. a client-id-only entry
// with no fixed address of its own) has nothing to check against the new
// CIDR, so `.unwrap_or(true)` keeps it rather than dropping it -- there is
// no "outside the subnet" for an entry that was never tied to a specific
// address to begin with.
fn compatible_reservations_for_subnet(
    subnet: &Value,
    cidr: &str,
) -> Result<Vec<Value>, &'static str> {
    let (network, prefix_len) = parse_cidr(cidr).ok_or("invalid subnet")?;
    Ok(subnet
        .get("reservations")
        .and_then(|value| value.as_array())
        .map(|reservations| {
            reservations
                .iter()
                .filter(|reservation| {
                    reservation
                        .get("ip-address")
                        .and_then(|value| value.as_str())
                        .and_then(parse_ipv4)
                        .map(|ip| ipv4_in_cidr(network, prefix_len, ip))
                        .unwrap_or(true)
                })
                .cloned()
                .collect()
        })
        .unwrap_or_default())
}

// Converts one Kea reservation JSON entry into the Reservation read-model.
// Always returns Some (never None) despite the Option return type -- kept
// as Option to match fetch_reservations_from_config's filter_map call site,
// which is written generically enough to skip an entry in the future if a
// stricter reservation shape check is ever added here.
fn parse_reservation_entry(subnet_id: u32, reservation: &Value) -> Option<Reservation> {
    Some(Reservation {
        subnet_id,
        ip: reservation
            .get("ip-address")
            .and_then(|v| v.as_str())
            .map(|ip| ip.to_string())
            .unwrap_or_else(|| "?".to_string()),
        mac: reservation
            .get("hw-address")
            .and_then(|v| v.as_str())
            .map(normalize_mac)
            .unwrap_or_else(|| "?".to_string()),
        hostname: reservation
            .get("hostname")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
    })
}

// Same "create the array if it's the first entry" pattern as
// subnet_options_mut, but for a subnet's reservations array instead of its
// options.
fn subnet_reservations_mut(subnet: &mut Value) -> Result<&mut Vec<Value>, &'static str> {
    let subnet = subnet.as_object_mut().ok_or("subnet not an object")?;
    if !subnet.contains_key("reservations") {
        subnet.insert("reservations".to_string(), Value::Array(Vec::new()));
    }
    subnet
        .get_mut("reservations")
        .and_then(|value| value.as_array_mut())
        .ok_or("reservations not an array")
}

// Called from add_reservation: updates an existing reservation in place if
// one already exists for this MAC (so re-submitting the add-reservation
// form for the same device edits it rather than creating a duplicate
// entry), otherwise appends a new one. Only hw-address/ip-address/hostname
// are touched on an update -- any other fields Kea itself keeps on the
// entry (e.g. option-data, client-classes) are left as-is rather than
// overwritten with the freshly-built entry's empty ones.
fn upsert_reservation(
    reservations: &mut Vec<Value>,
    reservation: Value,
) -> Result<(), &'static str> {
    let normalized_mac = reservation
        .get("hw-address")
        .and_then(|value| value.as_str())
        .map(normalize_mac)
        .ok_or("reservation missing hw-address")?;

    if let Some(existing) = reservations.iter_mut().find(|existing| {
        existing
            .get("hw-address")
            .and_then(|value| value.as_str())
            .map(normalize_mac)
            == Some(normalized_mac.clone())
    }) {
        let existing = existing
            .as_object_mut()
            .ok_or("existing reservation not an object")?;
        existing.insert("hw-address".to_string(), json!(normalized_mac));
        existing.insert(
            "ip-address".to_string(),
            reservation
                .get("ip-address")
                .cloned()
                .ok_or("reservation missing ip-address")?,
        );
        existing.insert(
            "hostname".to_string(),
            reservation
                .get("hostname")
                .cloned()
                .ok_or("reservation missing hostname")?,
        );
    } else {
        reservations.push(reservation);
    }

    Ok(())
}

// Silently does nothing if no reservation matches -- remove_reservation
// doesn't distinguish "removed" from "wasn't there", both redirect back to
// /dhcp the same way, since the end state an operator cares about (no
// reservation for this MAC) is identical either way.
fn remove_reservation_entry(reservations: &mut Vec<Value>, mac: &str) {
    let normalized = normalize_mac(mac);
    reservations.retain(|reservation| {
        reservation
            .get("hw-address")
            .and_then(|value| value.as_str())
            .map(normalize_mac)
            != Some(normalized.clone())
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::error::Error;
    use std::sync::Arc;

    // Issue #1068 item 6: switching to a DHCP mode whose container was never
    // created (the docker-socket-proxy allowlist has no create capability --
    // see docker_client's own module comment) used to surface as a bare
    // "Failed to start 'dhcp-proxy'" with no indication of what to do about
    // it. Confirms the 404 case is rewritten into the actionable
    // create-it-yourself guidance instead of the raw Docker error text.
    #[test]
    fn start_service_error_gives_actionable_guidance_for_a_missing_container() {
        let bollard_err = bollard::errors::Error::DockerResponseServerError {
            status_code: 404,
            message: "No such container: lancache-dhcp-proxy".to_string(),
        };
        let err: anyhow::Error =
            anyhow::Error::new(bollard_err).context("Failed to start 'dhcp-proxy'");
        let dhcp_err = start_service_error(err, "dhcp-proxy", "dhcp-proxy");
        assert_eq!(dhcp_err.status, StatusCode::INTERNAL_SERVER_ERROR);
        assert!(
            dhcp_err.message.contains("has not been created yet"),
            "expected actionable guidance, got: {}",
            dhcp_err.message
        );
        assert!(
            dhcp_err
                .message
                .contains("docker compose --profile dhcp-proxy up -d dhcp-proxy"),
            "expected the exact fix command, got: {}",
            dhcp_err.message
        );
    }

    // A real operational failure (not a missing container) must still
    // surface as an honest error -- this must not be misclassified as the
    // "run this command" bootstrap case, which would send an operator
    // chasing a fix that cannot possibly help.
    #[test]
    fn start_service_error_passes_through_other_failures_unchanged() {
        let bollard_err = bollard::errors::Error::DockerResponseServerError {
            status_code: 500,
            message: "container crashed on start".to_string(),
        };
        let err: anyhow::Error =
            anyhow::Error::new(bollard_err).context("Failed to start 'dhcp'");
        let dhcp_err = start_service_error(err, "dhcp", "dhcp-kea");
        assert!(
            !dhcp_err.message.contains("has not been created yet"),
            "a real failure must not get the missing-container message: {}",
            dhcp_err.message
        );
        assert!(dhcp_err.message.contains("container crashed on start"));
    }

    // Wraps validate_dhcp_form's 9-field DhcpFormValidation struct literal
    // so individual tests below can call it with plain positional
    // arguments instead of repeating every field name at each call site.
    // The 8-argument form (every pre-#947 call site) defaults domain to ""
    // -- an empty domain is always valid, so every existing test's baseline
    // behavior is unchanged; the 9-argument form lets the domain-specific
    // tests below pass an explicit value.
    macro_rules! validate_test_dhcp_form {
        (
            $subnet:expr,
            $pool_start:expr,
            $pool_end:expr,
            $gateway:expr,
            $dns_primary:expr,
            $dns_secondary:expr,
            $ntp_servers:expr,
            $lease_time:expr $(,)?
        ) => {
            validate_test_dhcp_form!(
                $subnet,
                $pool_start,
                $pool_end,
                $gateway,
                $dns_primary,
                $dns_secondary,
                $ntp_servers,
                $lease_time,
                ""
            )
        };
        (
            $subnet:expr,
            $pool_start:expr,
            $pool_end:expr,
            $gateway:expr,
            $dns_primary:expr,
            $dns_secondary:expr,
            $ntp_servers:expr,
            $lease_time:expr,
            $domain:expr $(,)?
        ) => {
            validate_dhcp_form(DhcpFormValidation {
                subnet: $subnet,
                pool_start: $pool_start,
                pool_end: $pool_end,
                gateway: $gateway,
                dns_primary: $dns_primary,
                dns_secondary: $dns_secondary,
                ntp_servers: $ntp_servers,
                lease_time: $lease_time,
                domain: $domain,
            })
        };
    }

    // A scripted step for the mock `post` closure tests below feed into
    // kea_config_modify_with_post: either a canned Kea JSON response
    // (Response) or a simulated transport-level failure (Transport, e.g. a
    // dropped connection) -- letting a test simulate exactly which of the
    // function's config-get/config-test/config-set/config-write/rollback
    // calls fails and how, without a real Kea Control Agent.
    #[derive(Debug)]
    enum MockStep {
        Response(Value),
        Transport(&'static str),
    }

    async fn run_kea_config_modify_with_steps(
        steps: Vec<MockStep>,
        modify: impl FnOnce(&mut Value) -> Result<(), &'static str> + Send,
    ) -> (Result<(), Box<dyn Error + Send + Sync>>, Vec<Value>) {
        run_kea_config_modify_with_steps_and_sink(steps, modify, |_applied: &Value| {}).await
    }

    // Same mock `post` plumbing as `run_kea_config_modify_with_steps`, but
    // also exposes the `on_write_success` snapshot-sink hook so tests can
    // assert exactly when (#614's) known-good snapshot creation is invoked
    // relative to the confirmed/ambiguous/rollback write outcomes.
    async fn run_kea_config_modify_with_steps_and_sink<S>(
        steps: Vec<MockStep>,
        modify: impl FnOnce(&mut Value) -> Result<(), &'static str> + Send,
        on_write_success: S,
    ) -> (Result<(), Box<dyn Error + Send + Sync>>, Vec<Value>)
    where
        S: FnOnce(&Value) + Send,
    {
        let calls = Arc::new(tokio::sync::Mutex::new(Vec::<Value>::new()));
        let steps = Arc::new(tokio::sync::Mutex::new(VecDeque::from(steps)));
        let lock = tokio::sync::Mutex::new(());

        let calls_for_post = Arc::clone(&calls);
        let steps_for_post = Arc::clone(&steps);
        let post = move |cmd: Value| {
            let calls = Arc::clone(&calls_for_post);
            let steps = Arc::clone(&steps_for_post);
            async move {
                calls.lock().await.push(cmd);
                match steps
                    .lock()
                    .await
                    .pop_front()
                    .expect("unexpected Kea command")
                {
                    MockStep::Response(resp) => Ok(resp),
                    MockStep::Transport(message) => Err(std::io::Error::other(message).into()),
                }
            }
        };

        let result = kea_config_modify_with_post(&lock, post, modify, on_write_success).await;
        let calls = calls.lock().await.clone();
        (result, calls)
    }

    fn kea_success_response() -> Value {
        json!([{ "result": 0 }])
    }

    fn kea_config_get_response(config: Value) -> Value {
        json!([{ "result": 0, "arguments": config }])
    }

    // Real on-disk snapshot root for the repeat-run idempotence tests below
    // (`kea_config_modify_repeat_*`), which exercise the real
    // `kea_snapshots::create_snapshot`/`list_snapshot_ids`/`read_snapshot`
    // trio instead of the no-op sink the other tests in this module use --
    // mirrors `kea_snapshots.rs`'s own `temp_dir` test helper (nanosecond-
    // stamped, so parallel test runs never collide on the same path).
    fn temp_snapshot_root(name: &str) -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before unix epoch")
            .as_nanos();
        std::env::temp_dir().join(format!("lancache-ng-dhcp-rs-{name}-{stamp}"))
    }

    // The probe's two result markers (conflict scan, dhclient dry-run) are
    // parsed independently and can disagree (e.g. a conflict found but the
    // client check still passes) -- overall_status() must reflect whichever
    // signal is worse, not just the last one parsed.
    #[test]
    fn parses_dual_dhcp_probe_report_with_conflict_and_client_success() {
        let report = parse_dhcp_probe_report(
            "__LANCACHE_DHCP_PROBE_START__ 1\n\
             __LANCACHE_DHCP_CONFLICT_RESULT__ found 192.168.1.1\n\
             __LANCACHE_DHCP_CLIENT_RESULT__ passed dhclient succeeded on eth0\n",
        );

        assert_eq!(report.overall_status(), "conflict_found");
        match report.conflict {
            DhcpConflictCheckStatus::Found { output, details } => {
                assert_eq!(output, "192.168.1.1");
                // No extra nmap fields in this fixture's single-line input --
                // details must default to empty, not panic or fabricate data.
                assert!(details.is_empty());
            }
            other => panic!("unexpected conflict result: {:?}", other),
        }
        match report.client {
            DhcpClientCheckStatus::Passed { output, details } => {
                assert_eq!(output, "dhclient succeeded on eth0");
                // No leases-file text in this fixture's single-line input --
                // details must default to empty, not panic or fabricate data.
                assert!(details.is_empty());
            }
            other => panic!("unexpected client result: {:?}", other),
        }
    }

    // A real dhcp-probe.sh run prints the full `cat "$nmap_out"` text
    // before its own result marker, so this fixture mirrors that -- the
    // marker line alone only carries the bare Server Identifier IP, but the
    // Admin UI should also get the surrounding nmap fields out of the same
    // container log text.
    #[test]
    fn parses_dhcp_probe_report_extracts_offer_details_alongside_marker_ip() {
        let report = parse_dhcp_probe_report(
            "__LANCACHE_DHCP_PROBE_START__ 1\n\
             Pre-scan script results:\n\
             | broadcast-dhcp-discover: \n\
             |   IP Offered: 192.168.1.50\n\
             |   DHCP Message Type: DHCPOFFER\n\
             |   Server Identifier: 192.168.1.1\n\
             |   IP Address Lease Time: 1d00h00m00s\n\
             |   Subnet Mask: 255.255.255.0\n\
             |   Router: 192.168.1.1\n\
             |_  Domain Name Server: 192.168.1.1\n\
             __LANCACHE_DHCP_CONFLICT_RESULT__ found 192.168.1.1\n\
             __LANCACHE_DHCP_CLIENT_RESULT__ passed dhclient succeeded on eth0\n",
        );

        match report.conflict {
            DhcpConflictCheckStatus::Found { output, details } => {
                assert_eq!(output, "192.168.1.1");
                assert_eq!(
                    details,
                    vec![
                        DhcpProbeDetail {
                            label: "Server Identifier".to_string(),
                            value: "192.168.1.1".to_string(),
                        },
                        DhcpProbeDetail {
                            label: "IP Offered".to_string(),
                            value: "192.168.1.50".to_string(),
                        },
                        DhcpProbeDetail {
                            label: "DHCP Message Type".to_string(),
                            value: "DHCPOFFER".to_string(),
                        },
                        DhcpProbeDetail {
                            label: "IP Address Lease Time".to_string(),
                            value: "1d00h00m00s".to_string(),
                        },
                        DhcpProbeDetail {
                            label: "Subnet Mask".to_string(),
                            value: "255.255.255.0".to_string(),
                        },
                        DhcpProbeDetail {
                            label: "Router".to_string(),
                            value: "192.168.1.1".to_string(),
                        },
                        DhcpProbeDetail {
                            label: "Domain Name Server".to_string(),
                            value: "192.168.1.1".to_string(),
                        },
                    ]
                );
            }
            other => panic!("unexpected conflict result: {:?}", other),
        }
    }

    // Two answering DHCP servers (nmap's "Response N of M:" block separator)
    // must not have their fields merged -- only the first server's details
    // may end up in the list, even though both blocks contain fields this
    // parser knows how to extract.
    #[test]
    fn extract_dhcp_offer_details_stops_at_second_response_block() {
        let details = extract_dhcp_offer_details(
            "| broadcast-dhcp-discover: \n\
             |   Response 1 of 2: \n\
             |     Server Identifier: 192.168.1.1\n\
             |     Router: 192.168.1.1\n\
             |   Response 2 of 2: \n\
             |     Server Identifier: 10.0.0.1\n\
             |_    Router: 10.0.0.1\n",
        );

        assert_eq!(
            details,
            vec![
                DhcpProbeDetail {
                    label: "Server Identifier".to_string(),
                    value: "192.168.1.1".to_string(),
                },
                DhcpProbeDetail {
                    label: "Router".to_string(),
                    value: "192.168.1.1".to_string(),
                },
            ]
        );
    }

    // No known label present anywhere in the input (e.g. a probe run that
    // never got far enough to print nmap's field breakdown) must yield an
    // empty list, not a panic -- the caller (DhcpConflictCheckStatus::Found)
    // relies on this being a safe default.
    #[test]
    fn extract_dhcp_offer_details_returns_empty_for_unrelated_text() {
        assert!(extract_dhcp_offer_details("some unrelated log line\n").is_empty());
    }

    // ─── Issue #1136: bounded dhcp-probe wait timeout ───

    #[test]
    fn truncate_log_tail_returns_input_unchanged_when_within_budget() {
        assert_eq!(truncate_log_tail("  short line  ", 100), "short line");
    }

    // The multi-byte emoji planted in the middle of this fixture would
    // panic a naive `&text[text.len() - max_bytes..]` byte slice if it fell
    // mid-codepoint; truncate_log_tail must walk forward to the next real
    // char boundary instead.
    #[test]
    fn truncate_log_tail_keeps_trailing_bytes_on_a_char_boundary() {
        let long = format!("{}{}{}", "x".repeat(10), '\u{1F600}', "y".repeat(10));
        let truncated = truncate_log_tail(&long, 5);
        assert!(truncated.starts_with("...(truncated)..."));
        assert!(truncated.ends_with("yyyyy"));
        assert!(!truncated.contains('\u{FFFD}'));
    }

    #[test]
    fn probe_error_display_distinguishes_timeout_from_other_failures() {
        let timeout_err = ProbeError::TimedOut {
            elapsed: Duration::from_secs(100),
            log_tail: "dhclient: bound to 192.168.1.50".to_string(),
            stop_note: "the presumed-stuck container was stopped".to_string(),
        };
        let timeout_msg = timeout_err.to_string();
        assert!(timeout_msg.contains("timed out"));
        assert!(timeout_msg.contains("100"));
        assert!(timeout_msg.contains("bound to 192.168.1.50"));
        assert!(timeout_msg.contains("the presumed-stuck container was stopped"));

        // The non-timeout variant keeps the exact prefix pre-#1136 callers
        // already saw, and must never contain "timed out" itself -- a
        // future reader greping a captured reason string for "timed out"
        // must not get a false positive from an unrelated failure.
        let other_err = ProbeError::Other(anyhow::anyhow!("container start failed"));
        let other_msg = other_err.to_string();
        assert!(other_msg.contains("Failed to execute DHCP check"));
        assert!(other_msg.contains("container start failed"));
        assert!(!other_msg.contains("timed out"));
    }

    // Sanity check that wait_for_probe_container's timeout wrapping doesn't
    // interfere with the ordinary, fast-completing case -- only a wait
    // future that resolves before `timeout` elapses should take this path.
    #[tokio::test]
    async fn wait_for_probe_container_returns_ok_when_wait_resolves_before_timeout() {
        let result = wait_for_probe_container(
            async { Some(Ok::<u32, bollard::errors::Error>(0)) },
            Duration::from_secs(5),
            || async { Ok(String::new()) },
            || async { Ok(()) },
        )
        .await;

        assert!(matches!(result, Ok(0)));
    }

    // The core #1136 acceptance criterion: a fixture that simulates a
    // wait_container call that never resolves -- the exact "genuinely hung,
    // zero progress" class confirmed live for #1132 -- and asserts the
    // timeout path actually fires and produces a diagnostic-rich status,
    // not just reasoning about it. `std::future::pending` never completes,
    // standing in for a wait_container stream item that simply never
    // arrives; the real timeout (DHCP_PROBE_WAIT_TIMEOUT) is 100s, but this
    // test injects a 20ms bound so it proves the same logic without
    // actually waiting on it.
    #[tokio::test]
    async fn wait_for_probe_container_times_out_and_captures_diagnostics() {
        let never_resolves = std::future::pending::<Option<Result<u32, bollard::errors::Error>>>();

        let result = wait_for_probe_container(
            never_resolves,
            Duration::from_millis(20),
            || async { Ok("dhclient: still trying to obtain a lease...\n".to_string()) },
            || async { Ok(()) },
        )
        .await;

        match result {
            Err(ProbeError::TimedOut {
                elapsed,
                log_tail,
                stop_note,
            }) => {
                assert!(elapsed >= Duration::from_millis(20));
                assert!(log_tail.contains("still trying to obtain a lease"));
                assert!(stop_note.contains("was stopped"));
            }
            other => panic!("expected ProbeError::TimedOut, got {other:?}"),
        }
    }

    // The maintainer's follow-up catch, tested directly: a timeout must not
    // collapse into a bare "timed out" with nothing else even when the
    // log/stop side-channels themselves fail -- the diagnostic text must
    // say so explicitly rather than silently produce an empty/misleading
    // tail.
    #[tokio::test]
    async fn wait_for_probe_container_timeout_survives_log_and_stop_failures() {
        let never_resolves = std::future::pending::<Option<Result<u32, bollard::errors::Error>>>();

        let result = wait_for_probe_container(
            never_resolves,
            Duration::from_millis(20),
            || async { Err::<String, _>(anyhow::anyhow!("log stream broken")) },
            || async { Err::<(), _>(anyhow::anyhow!("stop also failed")) },
        )
        .await;

        match result {
            Err(ProbeError::TimedOut {
                log_tail,
                stop_note,
                ..
            }) => {
                assert!(log_tail.contains("failed to capture probe container logs"));
                assert!(log_tail.contains("log stream broken"));
                assert!(stop_note.contains("stopping the presumed-stuck container also failed"));
                assert!(stop_note.contains("stop also failed"));
            }
            other => panic!("expected ProbeError::TimedOut, got {other:?}"),
        }
    }

    // No output captured before the timeout must render as an explicit
    // "(none -- ...)" placeholder, not a silently empty reason fragment
    // that would read the same as a formatting bug.
    #[tokio::test]
    async fn wait_for_probe_container_timeout_with_no_captured_output_says_so_explicitly() {
        let never_resolves = std::future::pending::<Option<Result<u32, bollard::errors::Error>>>();

        let result = wait_for_probe_container(
            never_resolves,
            Duration::from_millis(20),
            || async { Ok(String::new()) },
            || async { Ok(()) },
        )
        .await;

        match result {
            Err(ProbeError::TimedOut { log_tail, .. }) => {
                assert!(log_tail.contains("no output"));
            }
            other => panic!("expected ProbeError::TimedOut, got {other:?}"),
        }
    }

    // Fixture text is a real dhclient.leases file captured from a live
    // dhclient -4 -1 -v run against a real DHCP server (see dhcp-probe.sh's
    // own comment on the dhclient invocation for how this was confirmed) --
    // not a hand-guessed approximation of ISC's lease syntax.
    #[test]
    fn extract_dhcp_lease_details_parses_a_real_captured_lease_block() {
        let details = extract_dhcp_lease_details(concat!(
            "lease {\n",
            "  interface \"eth0\";\n",
            "  fixed-address 192.168.1.211;\n",
            "  filename \"boot/grub/i386-pc/core.0\";\n",
            "  server-name \"192.168.1.10\";\n",
            "  option subnet-mask 255.255.255.0;\n",
            "  option routers 192.168.1.2;\n",
            "  option dhcp-lease-time 3600;\n",
            "  option dhcp-message-type 5;\n",
            "  option domain-name-servers 192.168.1.22,192.168.1.23;\n",
            "  option dhcp-server-identifier 192.168.1.19;\n",
            "  option interface-mtu 1500;\n",
            "  option domain-search \"lan.local.\", \"local.\";\n",
            "  option dhcp-renewal-time 1800;\n",
            "  option ntp-servers 192.168.1.10;\n",
            "  option broadcast-address 192.168.1.255;\n",
            "  option dhcp-rebinding-time 3150;\n",
            "  option host-name \"sccache-build-slave-240\";\n",
            "  option netbios-name-servers 192.168.1.22,192.168.1.23;\n",
            "  option domain-name \"lan.local\";\n",
            "  renew 4 2026/07/23 13:03:59;\n",
            "  rebind 4 2026/07/23 13:30:17;\n",
            "  expire 4 2026/07/23 13:37:47;\n",
            "}\n",
        ));

        assert_eq!(
            details,
            vec![
                DhcpProbeDetail {
                    label: "Assigned IP Address".to_string(),
                    value: "192.168.1.211".to_string(),
                },
                DhcpProbeDetail {
                    label: "Server Identifier".to_string(),
                    value: "192.168.1.19".to_string(),
                },
                DhcpProbeDetail {
                    label: "Subnet Mask".to_string(),
                    value: "255.255.255.0".to_string(),
                },
                DhcpProbeDetail {
                    label: "Router".to_string(),
                    value: "192.168.1.2".to_string(),
                },
                DhcpProbeDetail {
                    label: "Domain Name Server".to_string(),
                    value: "192.168.1.22,192.168.1.23".to_string(),
                },
                DhcpProbeDetail {
                    label: "Domain Name".to_string(),
                    value: "lan.local".to_string(),
                },
                DhcpProbeDetail {
                    label: "Broadcast Address".to_string(),
                    value: "192.168.1.255".to_string(),
                },
                DhcpProbeDetail {
                    label: "Lease Time (seconds)".to_string(),
                    value: "3600".to_string(),
                },
                DhcpProbeDetail {
                    label: "Renewal Time (seconds)".to_string(),
                    value: "1800".to_string(),
                },
                DhcpProbeDetail {
                    label: "Rebinding Time (seconds)".to_string(),
                    value: "3150".to_string(),
                },
                DhcpProbeDetail {
                    label: "NTP Servers".to_string(),
                    value: "192.168.1.10".to_string(),
                },
                DhcpProbeDetail {
                    label: "Host Name".to_string(),
                    value: "sccache-build-slave-240".to_string(),
                },
                DhcpProbeDetail {
                    label: "NetBIOS Name Server".to_string(),
                    value: "192.168.1.22,192.168.1.23".to_string(),
                },
            ]
        );
    }

    // A renewed lease appends a NEW "lease { ... }" block after the original
    // rather than replacing it -- only the second (last) block's fields may
    // end up in the result, even though the first block has fields this
    // parser also knows how to extract. Opposite direction from
    // extract_dhcp_offer_details_stops_at_second_response_block, which keeps
    // the FIRST block: documented explicitly on extract_dhcp_lease_details.
    #[test]
    fn extract_dhcp_lease_details_keeps_only_the_last_lease_block() {
        let details = extract_dhcp_lease_details(concat!(
            "lease {\n",
            "  fixed-address 192.168.1.50;\n",
            "  option routers 192.168.1.1;\n",
            "}\n",
            "lease {\n",
            "  fixed-address 192.168.1.211;\n",
            "  option routers 192.168.1.2;\n",
            "}\n",
        ));

        assert_eq!(
            details,
            vec![
                DhcpProbeDetail {
                    label: "Assigned IP Address".to_string(),
                    value: "192.168.1.211".to_string(),
                },
                DhcpProbeDetail {
                    label: "Router".to_string(),
                    value: "192.168.1.2".to_string(),
                },
            ]
        );
    }

    // No "lease {" block at all (e.g. a probe run that never reached the
    // dhclient stage, or a failed dry-run where dhcp-probe.sh never cats an
    // empty leases file) must yield an empty list, not a panic -- the caller
    // (DhcpClientCheckStatus::Passed) relies on this being a safe default.
    #[test]
    fn extract_dhcp_lease_details_returns_empty_for_unrelated_text() {
        assert!(extract_dhcp_lease_details("some unrelated log line\n").is_empty());
    }

    // parse_client_probe_result must wire extract_dhcp_lease_details into a
    // real "passed" marker line's surrounding output, the same way
    // parse_conflict_probe_result already wires extract_dhcp_offer_details in
    // for the conflict path -- this is the actual code path the Admin UI
    // depends on, not just the extractor function in isolation.
    #[test]
    fn parses_dhcp_probe_report_extracts_lease_details_alongside_passed_marker() {
        let report = parse_dhcp_probe_report(concat!(
            "__LANCACHE_DHCP_PROBE_START__ 1\n",
            "__LANCACHE_DHCP_CONFLICT_RESULT__ not_found\n",
            "Internet Systems Consortium DHCP Client 4.4.3-P1\n",
            "DHCPACK of 192.168.1.211 from 192.168.1.19\n",
            "bound to 192.168.1.211 -- renewal in 1572 seconds.\n",
            "lease {\n",
            "  fixed-address 192.168.1.211;\n",
            "  option routers 192.168.1.2;\n",
            "  option domain-name-servers 192.168.1.22,192.168.1.23;\n",
            "}\n",
            "__LANCACHE_DHCP_CLIENT_RESULT__ passed dhclient succeeded on eth0\n",
        ));

        match report.client {
            DhcpClientCheckStatus::Passed { output, details } => {
                assert_eq!(output, "dhclient succeeded on eth0");
                assert_eq!(
                    details,
                    vec![
                        DhcpProbeDetail {
                            label: "Assigned IP Address".to_string(),
                            value: "192.168.1.211".to_string(),
                        },
                        DhcpProbeDetail {
                            label: "Router".to_string(),
                            value: "192.168.1.2".to_string(),
                        },
                        DhcpProbeDetail {
                            label: "Domain Name Server".to_string(),
                            value: "192.168.1.22,192.168.1.23".to_string(),
                        },
                    ]
                );
            }
            other => panic!("unexpected client result: {:?}", other),
        }
    }

    // A probe run that never reaches the dhclient stage (e.g. the container
    // crashed after the conflict scan) must render as "unavailable", not as
    // a silent pass -- an operator must not read a missing client check as
    // "no problems found".
    #[test]
    fn parses_dual_dhcp_probe_report_marks_missing_client_summary_unavailable() {
        let report = parse_dhcp_probe_report("__LANCACHE_DHCP_PROBE_START__ 1\n");

        assert_eq!(report.overall_status(), "unavailable");
        assert!(matches!(report.conflict, DhcpConflictCheckStatus::NotFound));
        assert!(matches!(
            report.client,
            DhcpClientCheckStatus::Unavailable { .. }
        ));
    }

    // Every DHCP-mutating route calls require_kea_mode() first; if this
    // guard ever accepted DnsmasqProxy/Disabled mode or an empty API URL, a
    // mutation route would try to POST to Kea's control agent with no
    // reachable target instead of failing with a clear "wrong mode" error.
    #[test]
    fn kea_mutation_guard_requires_kea_mode_and_api_url() {
        assert!(kea_api_available(
            crate::config::DhcpMode::Kea,
            "http://dhcp:8000"
        ));
        assert!(!kea_api_available(crate::config::DhcpMode::Kea, ""));
        assert!(!kea_api_available(
            crate::config::DhcpMode::Disabled,
            "http://dhcp:8000"
        ));
        assert!(!kea_api_available(
            crate::config::DhcpMode::DnsmasqProxy,
            "http://dhcp:8000"
        ));
    }

    // The mode-switch form is the only writer of DHCP_MODE from the Admin UI,
    // so every supported DhcpMode variant must parse back to its enum, and
    // unrecognized input must be rejected outright rather than silently
    // coerced to a default mode the operator never chose.
    #[test]
    fn parse_dhcp_mode_input_round_trips_supported_modes() {
        use crate::config::DhcpMode;
        // The mode-switch form is the only writer of DHCP_MODE from the UI, so
        // every supported value must parse back to its enum, and unknown input
        // must be rejected rather than silently coerced to a default.
        for mode in [DhcpMode::Disabled, DhcpMode::Kea, DhcpMode::DnsmasqProxy] {
            assert_eq!(parse_dhcp_mode_input(mode.as_str()), Some(mode));
        }
        // Case/whitespace tolerance mirrors the setup.sh prompt handling.
        assert_eq!(
            parse_dhcp_mode_input("  Dnsmasq-Proxy "),
            Some(DhcpMode::DnsmasqProxy)
        );
        assert_eq!(parse_dhcp_mode_input("dnsmasq"), None);
        assert_eq!(parse_dhcp_mode_input(""), None);
    }

    // validate_dhcp_form's containment/range checks are exactly the kind of
    // logic an off-by-one silently breaks (an inclusive bound written as
    // exclusive, or vice versa) without any compiler help to catch it. This
    // group exhaustively pins every boundary: pool/gateway must sit inside
    // the subnet CIDR, the pool range must not be reversed, and
    // MIN_LEASE_TIME/MAX_LEASE_TIME are both inclusive bounds (60s avoids
    // renewal-storm-inducing leases that are too short; 7 days avoids a
    // lease outliving an operator's ability to reclaim an address from a
    // now-offline device).
    #[test]
    fn accepts_valid_dhcp_form() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "86400",
        );

        assert_eq!(lease_time.unwrap(), 86400);
    }

    // Unlike the pool and gateway, DNS servers are explicitly allowed to sit
    // outside the configured subnet -- an operator's DNS server doesn't have
    // to live on this LAN segment, so the containment check must not reject
    // this case the way it would for an out-of-subnet pool or gateway.
    #[test]
    fn accepts_routed_dns_servers_outside_subnet() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "10.0.0.10",
            "203.0.113.53",
            "198.51.100.4",
            "86400",
        );

        assert_eq!(lease_time.unwrap(), 86400);
    }

    // The two tests above establish the accepted baseline (a normal subnet,
    // and one with DNS servers routed outside it -- explicitly allowed
    // since an operator's DNS server doesn't have to live on the LAN
    // segment being configured). Everything below flips exactly one field
    // away from that baseline to confirm each individual geometry check
    // actually rejects on its own.
    #[test]
    fn rejects_pool_outside_subnet() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.101.100",
            "198.51.101.200",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "86400",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    // Both pool endpoints individually lie inside the subnet here -- only
    // their order is flipped (end before start) -- pinning that the range
    // check compares start<=end rather than merely checking each endpoint's
    // subnet membership independently.
    #[test]
    fn rejects_reversed_pool_range() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.200",
            "198.51.100.100",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "86400",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    // From here down: the CIDR/pool/gateway geometry checks above all pass
    // with a fixed valid lease_time, and these tests instead hold the
    // network geometry fixed to isolate lease_time's own parsing and bounds
    // checking.
    #[test]
    fn rejects_invalid_lease_time() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "not-a-number",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    // Flips only the gateway out of the subnet (pool and DNS stay valid) --
    // confirms the gateway has its own containment check enforced
    // independently of the DNS-outside-subnet allowance above, rather than
    // sharing a single relaxed geometry check with DNS servers.
    #[test]
    fn rejects_gateway_outside_subnet() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.101.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "86400",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    // "198.51.100.5/24" has host bits set, so it is not itself a network
    // address even though it parses as a valid CIDR -- pins that the subnet
    // field must be the network address exactly, not silently normalized to
    // one or accepted as an arbitrary host address within the /24.
    #[test]
    fn rejects_non_network_cidr() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.5/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "86400",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    // MIN_LEASE_TIME/MAX_LEASE_TIME are inclusive bounds (`(MIN..=MAX).contains`
    // in validate_dhcp_form), so the exact boundary values themselves (60,
    // 604800) must be accepted, not just values safely inside the range --
    // this group and the one below pin both the inside-the-line and
    // one-past-the-line cases for each bound.
    #[test]
    fn rejects_zero_lease_time() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "0",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    // 59 is one below MIN_LEASE_TIME (60), distinct from rejects_zero_lease_time
    // above -- pins that the lower bound sits exactly at 60 and not looser,
    // rather than only proving that a degenerate 0 is invalid.
    #[test]
    fn rejects_lease_time_below_minimum() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "59",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    // Paired with rejects_lease_time_below_minimum above: 59 rejected, 60
    // accepted -- confirms MIN_LEASE_TIME's boundary sits exactly where the
    // constant says it does, not off-by-one in either direction.
    #[test]
    fn accepts_lease_time_at_minimum() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "60",
        );

        assert_eq!(lease_time.unwrap(), 60);
    }

    // Mirrors accepts_lease_time_at_minimum for the upper bound: 604800 (7
    // days) is MAX_LEASE_TIME itself, and must be accepted because the bound
    // is inclusive, not just values safely below it.
    #[test]
    fn accepts_lease_time_at_maximum() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "604800",
        );

        assert_eq!(lease_time.unwrap(), 604800);
    }

    // 604801 is exactly one second past MAX_LEASE_TIME -- paired with
    // accepts_lease_time_at_maximum above to confirm the upper bound is
    // exact, not off-by-one in either direction.
    #[test]
    fn rejects_lease_time_above_maximum() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "604801",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    // Distinct from rejects_lease_time_above_maximum: this value is not just
    // over MAX_LEASE_TIME, it's large enough to matter for
    // apply_subnet_value's own `lease_time.checked_mul(2)` -- confirming
    // validate_dhcp_form's own bounds check already rejects it here means
    // that overflow-prone doubling can never actually be reached with an
    // attacker/typo-supplied huge value.
    #[test]
    fn rejects_huge_lease_time() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "999999999",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    // Issue #947: add_subnet/update_subnet used to pass form.domain straight
    // into Kea's domain-name/domain-search subnet options with zero
    // validation, unlike update_dhcp_proxy's analogous dhcp_proxy_domain
    // field. These three tests pin the fix at the validate_dhcp_form level
    // (both add_subnet and update_subnet delegate all field validation to
    // it): a syntactically valid non-empty domain is accepted, an invalid
    // one is rejected with 400, and an empty domain -- the default every
    // test above already exercises via the 8-argument macro form -- stays
    // valid rather than becoming a newly-required field.
    #[test]
    fn accepts_valid_non_empty_domain() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "86400",
            "lan.example",
        );

        assert_eq!(lease_time.unwrap(), 86400);
    }

    #[test]
    fn rejects_invalid_non_empty_domain() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "86400",
            "-invalid..domain",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    #[test]
    fn accepts_empty_domain() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "86400",
            "",
        );

        assert_eq!(lease_time.unwrap(), 86400);
    }

    // #670: classify_ntp_entry is the pure decision resolve_ntp_servers
    // relies on to know which entries need a DNS lookup at all -- pinning
    // it directly (IPv4 literal vs. hostname, for both the shipped default
    // hostnames and a bare local hostname with no dots) keeps that decision
    // testable without a resolver or network access, per this file's
    // IO/pure split convention (see resolve_ntp_servers's own doc comment).
    #[test]
    fn classify_ntp_entry_distinguishes_ipv4_literals_from_hostnames() {
        assert_eq!(
            classify_ntp_entry("198.51.100.4"),
            NtpServerEntry::Ipv4(Ipv4Addr::new(198, 51, 100, 4))
        );
        assert_eq!(
            classify_ntp_entry("debian.pool.ntp.org"),
            NtpServerEntry::Hostname("debian.pool.ntp.org".to_string())
        );
        assert_eq!(
            classify_ntp_entry("time.nist.gov"),
            NtpServerEntry::Hostname("time.nist.gov".to_string())
        );
        // No dots at all is still a hostname, not a malformed IPv4 -- e.g. an
        // NTP server reachable by a bare local/mDNS name.
        assert_eq!(
            classify_ntp_entry("ntp-server"),
            NtpServerEntry::Hostname("ntp-server".to_string())
        );
    }

    // Codex review on #749/PR (P2): a digit-and-dot-only token that fails
    // strict IPv4 parsing (a typo'd address, not a hostname -- real hostname
    // labels always contain a letter) must be classified as
    // MalformedAddress, not Hostname, so resolve_ntp_servers rejects it with
    // a clear error up front instead of handing it to the OS resolver, whose
    // handling of non-standard numeric syntax is platform-dependent and not
    // something this project should rely on.
    #[test]
    fn classify_ntp_entry_rejects_malformed_numeric_addresses() {
        assert_eq!(
            classify_ntp_entry("1.2.3"),
            NtpServerEntry::MalformedAddress("1.2.3".to_string())
        );
        assert_eq!(
            classify_ntp_entry("999999999"),
            NtpServerEntry::MalformedAddress("999999999".to_string())
        );
        // Five octets is just as clearly a botched IPv4 literal as three.
        assert_eq!(
            classify_ntp_entry("198.51.100.4.5"),
            NtpServerEntry::MalformedAddress("198.51.100.4.5".to_string())
        );
    }

    // #670: an all-IPv4-literal list must resolve without ever touching the
    // network (classify_ntp_entry keeps every entry on the Ipv4 branch), so
    // this is safe to run in a sandboxed/offline CI runner while still
    // exercising resolve_ntp_servers' actual async path end to end,
    // including the "a, b" join format build_subnet_options expects.
    #[tokio::test]
    async fn resolve_ntp_servers_passes_through_ipv4_literals_without_dns() {
        let resolved = resolve_ntp_servers("198.51.100.4, 198.51.100.5")
            .await
            .expect("all-IPv4 input must resolve");
        assert_eq!(resolved, "198.51.100.4, 198.51.100.5");
    }

    // Codex review on #749/PR (P2): mirrors the classify_ntp_entry test
    // above but through the actual async resolve_ntp_servers entry point,
    // confirming the malformed entry is rejected before any DNS lookup is
    // attempted (classify_ntp_entry keeps it off the Hostname branch
    // entirely), so this is safe to run offline too.
    #[tokio::test]
    async fn resolve_ntp_servers_rejects_malformed_numeric_address() {
        let err = resolve_ntp_servers("198.51.100.4, 1.2.3")
            .await
            .expect_err("malformed numeric address must not resolve");
        assert_eq!(err, "NTP server '1.2.3' is not a valid IPv4 address");
    }

    // Mirrors format_ntp_server_option's own empty-input contract (empty in,
    // empty out, never an error) so add_subnet/update_subnet's "no NTP
    // servers configured" case still ends up with no ntp-servers option in
    // the built Kea subnet, exactly as before this issue's fix.
    #[tokio::test]
    async fn resolve_ntp_servers_empty_input_yields_empty_string() {
        let resolved = resolve_ntp_servers("")
            .await
            .expect("empty input is not an error");
        assert_eq!(resolved, "");
    }

    // This test opens the cluster covering kea_config_modify_with_post's
    // whole write-outcome state machine: a confirmed failure (Kea's own
    // error response) always rolls back, but an ambiguous failure (the
    // request itself errored, so it's unknown whether Kea actually applied
    // it) gets a retry first -- rolling back on an ambiguous failure risks
    // reverting a config-write that actually succeeded, and never retrying
    // risks leaving a genuinely-failed write unconfirmed forever. Each test
    // in this cluster pins one path through that decision tree via the mock
    // command sequence it feeds in.
    #[tokio::test]
    async fn kea_config_modify_succeeds_without_rollback() {
        let initial_config = json!({
            "Dhcp4": {
                "subnet4": [
                    {
                        "id": 1,
                        "valid-lifetime": 3600
                    }
                ]
            }
        });
        let expected_modified = json!({
            "Dhcp4": {
                "subnet4": [
                    {
                        "id": 1,
                        "valid-lifetime": 3600
                    },
                    {
                        "id": 2,
                        "valid-lifetime": 7200
                    }
                ]
            }
        });

        // Four scripted success responses, one per step of the real chain:
        // config-get, config-test, config-set, config-write -- all succeed,
        // so this exercises the plain happy path with no retry/rollback.
        let (result, calls) = run_kea_config_modify_with_steps(
            vec![
                MockStep::Response(kea_config_get_response(initial_config)),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
            ],
            |config| {
                let dhcp4 = config.get_mut("Dhcp4").ok_or("Dhcp4 missing")?;
                let subnets = dhcp4
                    .get_mut("subnet4")
                    .ok_or("subnet4 missing")?
                    .as_array_mut()
                    .ok_or("subnet4 not an array")?;
                subnets.push(json!({
                    "id": 2,
                    "valid-lifetime": 7200
                }));
                Ok(())
            },
        )
        .await;

        assert!(result.is_ok());
        assert_eq!(calls.len(), 4);
        assert_eq!(calls[0]["command"], "config-get");
        assert_eq!(calls[1]["command"], "config-test");
        assert_eq!(calls[2]["command"], "config-set");
        assert_eq!(calls[3]["command"], "config-write");
        // Confirms config-test is called with the SAME modified config
        // config-set then applies -- config-test must validate exactly what
        // will be set, not the pre-modify config or some other value.
        assert_eq!(calls[1]["arguments"], expected_modified);
        assert_eq!(calls[2]["arguments"], expected_modified);
    }

    // #614's snapshot creation is wired in as a single choke-point hook
    // (`on_write_success`) rather than duplicated into every mutation route,
    // so this locks in both that the hook actually fires on a confirmed
    // config-write success, and that it receives the real applied config
    // (post-modify, post-config-test) -- not the stale pre-modify config --
    // since a snapshot of the wrong generation would make rollback silently
    // restore an older, unintended state.
    #[tokio::test]
    async fn kea_config_modify_invokes_snapshot_sink_with_applied_config_on_success() {
        let initial_config = json!({"Dhcp4": {"subnet4": [{"id": 1}]}});
        let sink_calls: Arc<std::sync::Mutex<Vec<Value>>> =
            Arc::new(std::sync::Mutex::new(Vec::new()));
        let sink_calls_for_closure = Arc::clone(&sink_calls);

        let (result, _calls) = run_kea_config_modify_with_steps_and_sink(
            vec![
                MockStep::Response(kea_config_get_response(initial_config)),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
            ],
            |config| {
                config["Dhcp4"]["subnet4"]
                    .as_array_mut()
                    .ok_or("subnet4 not an array")?
                    .push(json!({"id": 2}));
                Ok(())
            },
            move |applied: &Value| {
                sink_calls_for_closure.lock().unwrap().push(applied.clone());
            },
        )
        .await;

        assert!(result.is_ok());
        let sink_calls = sink_calls.lock().unwrap();
        assert_eq!(
            sink_calls.len(),
            1,
            "the snapshot sink must run exactly once on a confirmed config-write success"
        );
        assert_eq!(
            sink_calls[0]["Dhcp4"]["subnet4"][1]["id"],
            json!(2),
            "the sink must see the same applied config that was validated and set, not the pre-modify config"
        );
    }

    // A config-write that gets rolled back was, by definition, just proven
    // to fail persisting -- if the snapshot sink fired anyway, a rejected
    // config would get recorded as "known-good" and poison every future
    // rollback target with something that was never actually good.
    #[tokio::test]
    async fn kea_config_modify_does_not_invoke_snapshot_sink_on_rollback() {
        let initial_config = json!({"Dhcp4": {"subnet4": [{"id": 1}]}});
        let sink_calls: Arc<std::sync::Mutex<Vec<Value>>> =
            Arc::new(std::sync::Mutex::new(Vec::new()));
        let sink_calls_for_closure = Arc::clone(&sink_calls);

        let (result, _calls) = run_kea_config_modify_with_steps_and_sink(
            vec![
                MockStep::Response(kea_config_get_response(initial_config)),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
                MockStep::Response(json!([{ "result": 1, "text": "write failed" }])),
                MockStep::Response(kea_success_response()),
            ],
            |config| {
                config["Dhcp4"]["subnet4"]
                    .as_array_mut()
                    .ok_or("subnet4 not an array")?
                    .push(json!({"id": 2}));
                Ok(())
            },
            move |applied: &Value| {
                sink_calls_for_closure.lock().unwrap().push(applied.clone());
            },
        )
        .await;

        assert!(result.is_err());
        assert!(
            sink_calls.lock().unwrap().is_empty(),
            "a rolled-back config-write must never be recorded as a known-good snapshot"
        );
    }

    // Repeat-run idempotence proof for the Kea snapshot adapter, mirroring
    // `tests/bats/setup_update_idempotence.bats`'s pattern (drive the real
    // writer twice against a realistic fixture, including a deliberately
    // broken candidate, and assert the on-disk store is unaffected) --
    // translated to Rust since Kea's snapshot adapter is Rust-native, not a
    // shell entrypoint function like the nginx/dnsmasq/PowerDNS adapters
    // (see `kea_snapshots.rs`'s module doc comment). Unlike this module's
    // existing `..._does_not_invoke_snapshot_sink_on_rollback` test
    // (single run, no-op sink, no on-disk store), this drives the REAL
    // `kea_snapshots::create_snapshot`/`list_snapshot_ids` against a real
    // temp directory, twice in a row, to prove the invariant holds on repeat
    // runs and not just once.
    //
    // A candidate that fails `config-test` must never reach the
    // `on_write_success` snapshot sink at all (the function returns via `?`
    // before Step 6's config-write/sink call), so the snapshot store must
    // stay completely empty -- not just "no new entries", but genuinely
    // untouched (no root directory even created) -- across repeated attempts
    // to persist the same broken candidate. This is the load-bearing
    // invariant `list_snapshot_ids`' "newest snapshot" contract depends on:
    // if a rejected candidate ever got snapshotted, the newest entry could
    // no longer be assumed valid.
    #[tokio::test]
    async fn kea_config_modify_repeat_broken_candidate_never_snapshots_and_store_stays_empty() {
        let root = temp_snapshot_root("broken-candidate");
        let initial_config = json!({"Dhcp4": {"subnet4": [{"id": 1, "valid-lifetime": 3600}]}});
        let keep_n = 3u32;

        let broken_candidate_steps = || {
            vec![
                MockStep::Response(kea_config_get_response(initial_config.clone())),
                // config-test rejects the candidate -- the real-world analog
                // of PDNS's `--config=check` failing on a deliberately broken
                // candidate config.
                MockStep::Response(json!([{
                    "result": 1,
                    "text": "subnet4: invalid prefix length"
                }])),
            ]
        };
        let break_the_candidate = |config: &mut Value| {
            config["Dhcp4"]["subnet4"]
                .as_array_mut()
                .ok_or("subnet4 not an array")?
                .push(json!({"id": 2, "subnet": "not-a-valid-cidr"}));
            Ok(())
        };
        let root_for_sink = root.clone();
        let real_snapshot_sink = move |applied: &Value| {
            let _ = kea_snapshots::create_snapshot(&root_for_sink, keep_n, applied);
        };

        // Run 1: attempt to persist the broken candidate.
        let (result_1, _calls) = run_kea_config_modify_with_steps_and_sink(
            broken_candidate_steps(),
            break_the_candidate,
            real_snapshot_sink.clone(),
        )
        .await;
        assert!(
            result_1.is_err(),
            "config-test must reject the broken candidate"
        );
        assert!(
            !root.exists(),
            "a rejected candidate must never even create the snapshot root, \
             since the sink (and therefore create_snapshot) must never run"
        );
        assert_eq!(
            kea_snapshots::list_snapshot_ids(&root).unwrap(),
            Vec::<String>::new(),
            "snapshot store must be empty after the first rejected attempt"
        );

        // Run 2: repeat the exact same broken candidate. The store must be
        // byte-for-byte unchanged -- still nonexistent/empty, not just "no
        // growth" -- proving this is stable across repeat runs, not a
        // first-run artifact.
        let (result_2, _calls) = run_kea_config_modify_with_steps_and_sink(
            broken_candidate_steps(),
            break_the_candidate,
            real_snapshot_sink,
        )
        .await;
        assert!(
            result_2.is_err(),
            "config-test must reject the broken candidate again on the repeat run"
        );
        assert!(
            !root.exists(),
            "the repeat run must not create the snapshot root either"
        );
        assert_eq!(
            kea_snapshots::list_snapshot_ids(&root).unwrap(),
            Vec::<String>::new(),
            "snapshot store must still be empty after the second rejected attempt"
        );

        let _ = fs::remove_dir_all(&root);
    }

    // Second half of the Kea repeat-run idempotence proof: a valid
    // mutation followed by a rollback to that same known-good snapshot,
    // repeated twice. Unlike PDNS's automatic startup rescan (where a
    // no-op re-run leaves the snapshot store byte-for-byte identical), Kea's
    // rollback is operator-selected and itself goes through
    // `kea_config_modify`, which mints a brand-new snapshot on every
    // confirmed `config-write` success (see `kea_snapshots::create_snapshot`'s
    // doc comment: no content-dedup, a fresh nanosecond id every call). So
    // repeating the same rollback twice deliberately grows the store by one
    // entry each time -- that is correct, expected behavior, not a bug this
    // test should paper over.
    //
    // What must stay invariant across both runs is the snapshotted CONTENT:
    // every snapshot created from applying the same known-good config must
    // be byte-for-byte identical to the original, regardless of how many
    // times the rollback is repeated or what id it lands under. That is the
    // property "rollback lands on the byte-identical known-good config"
    // actually asserts for an adapter with no content-dedup.
    #[tokio::test]
    async fn kea_config_modify_repeat_rollback_lands_on_byte_identical_known_good_config() {
        let root = temp_snapshot_root("rollback-repeat");
        let keep_n = 3u32;
        let starting_config = json!({"Dhcp4": {"subnet4": [{"id": 1, "valid-lifetime": 3600}]}});

        let root_for_sink = root.clone();
        let real_snapshot_sink = move |applied: &Value| {
            let _ = kea_snapshots::create_snapshot(&root_for_sink, keep_n, applied);
        };

        // Step 1: a valid mutation creates the known-good baseline snapshot.
        let (result, _calls) = run_kea_config_modify_with_steps_and_sink(
            vec![
                MockStep::Response(kea_config_get_response(starting_config.clone())),
                MockStep::Response(kea_success_response()), // config-test
                MockStep::Response(kea_success_response()), // config-set
                MockStep::Response(kea_success_response()), // config-write
            ],
            |config| {
                config["Dhcp4"]["subnet4"]
                    .as_array_mut()
                    .ok_or("subnet4 not an array")?
                    .push(json!({"id": 2, "valid-lifetime": 7200}));
                Ok(())
            },
            real_snapshot_sink.clone(),
        )
        .await;
        assert!(result.is_ok(), "the baseline mutation must succeed");

        let ids_after_baseline = kea_snapshots::list_snapshot_ids(&root).unwrap();
        assert_eq!(ids_after_baseline.len(), 1, "exactly one baseline snapshot");
        let known_good = kea_snapshots::read_snapshot(&root, &ids_after_baseline[0]).unwrap();

        // Roll back to that known-good snapshot twice in a row, exactly the
        // way `rollback_kea_snapshot` does: a config-get for "current" state
        // (assumed here to be the same known-good config, since nothing else
        // changed the runtime config between rollbacks), then re-apply the
        // stored snapshot verbatim.
        for attempt in 1..=2 {
            let known_good_for_modify = known_good.clone();
            let (rollback_result, _calls) = run_kea_config_modify_with_steps_and_sink(
                vec![
                    MockStep::Response(kea_config_get_response(known_good.clone())),
                    MockStep::Response(kea_success_response()), // config-test
                    MockStep::Response(kea_success_response()), // config-set
                    MockStep::Response(kea_success_response()), // config-write
                ],
                move |config| {
                    *config = known_good_for_modify;
                    Ok(())
                },
                real_snapshot_sink.clone(),
            )
            .await;
            assert!(
                rollback_result.is_ok(),
                "rollback attempt {attempt} must succeed"
            );
        }

        let ids_after_rollbacks = kea_snapshots::list_snapshot_ids(&root).unwrap();
        assert_eq!(
            ids_after_rollbacks.len(),
            3,
            "baseline + two rollbacks = three distinct snapshots (no content-dedup by design)"
        );

        // The invariant this test exists for: every one of those three
        // snapshots, despite having three different (nanosecond-id) names,
        // carries byte-for-byte identical content -- the rollback always
        // lands on the exact same known-good config, whether it is the first
        // or the second repeat.
        for id in &ids_after_rollbacks {
            let content = kea_snapshots::read_snapshot(&root, id).unwrap();
            assert_eq!(
                content, known_good,
                "snapshot {id} must be byte-for-byte identical to the known-good baseline"
            );
        }

        let _ = fs::remove_dir_all(&root);
    }

    // Regression test for a bug found via live verification against a real
    // Kea 2.6.3 Control Agent (not caught by any prior test, since all of
    // them mock config-get without a `hash` field): the real Control Agent's
    // config-get response is `{"Dhcp4": {...}, "hash": "<digest>"}`, and
    // feeding that whole object straight back as config-test/config-set's
    // `arguments` makes Kea reject the request with
    // "Unsupported 'hash' parameter." on every call. This asserts `hash` is
    // stripped before it reaches either request body (and is absent from the
    // config the `modify` closure receives).
    #[tokio::test]
    async fn kea_config_modify_strips_hash_from_config_get_before_reuse() {
        let config_get_with_hash = json!([{
            "result": 0,
            "arguments": {
                "Dhcp4": {"subnet4": [{"id": 1}]},
                "hash": "0123456789abcdef0123456789abcdef01234567"
            }
        }]);

        let (result, calls) = run_kea_config_modify_with_steps(
            vec![
                MockStep::Response(config_get_with_hash),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
            ],
            |config| {
                assert!(
                    config.get("hash").is_none(),
                    "the modify closure must never see a leftover hash field"
                );
                config["Dhcp4"]["subnet4"]
                    .as_array_mut()
                    .ok_or("subnet4 not an array")?
                    .push(json!({"id": 2}));
                Ok(())
            },
        )
        .await;

        assert!(result.is_ok());
        assert_eq!(calls[0]["command"], "config-get");
        assert_eq!(calls[1]["command"], "config-test");
        assert_eq!(calls[2]["command"], "config-set");
        assert!(
            calls[1]["arguments"].get("hash").is_none(),
            "config-test's arguments must not carry the config-get hash field"
        );
        assert!(
            calls[2]["arguments"].get("hash").is_none(),
            "config-set's arguments must not carry the config-get hash field"
        );
    }

    // config-write's response itself reports failure (result != 0) -- a
    // ConfirmedFailure, not ambiguous -- so this must roll back on the
    // very first attempt, with no retry in between.
    #[tokio::test]
    async fn kea_config_modify_rolls_back_on_confirmed_write_failure() {
        let initial_config = json!({
            "Dhcp4": {
                "subnet4": [
                    {
                        "id": 1,
                        "valid-lifetime": 3600
                    }
                ]
            }
        });
        let expected_modified = json!({
            "Dhcp4": {
                "subnet4": [
                    {
                        "id": 1,
                        "valid-lifetime": 3600
                    },
                    {
                        "id": 2,
                        "valid-lifetime": 7200
                    }
                ]
            }
        });

        // 5 scripted steps: config-get, config-test, config-set both
        // succeed, but config-write (4th) fails outright, triggering a 5th
        // call -- the rollback's own config-set.
        let (result, calls) = run_kea_config_modify_with_steps(
            vec![
                MockStep::Response(kea_config_get_response(initial_config.clone())),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
                MockStep::Response(json!([{ "result": 1, "text": "write failed" }])),
                MockStep::Response(kea_success_response()),
            ],
            |config| {
                let dhcp4 = config.get_mut("Dhcp4").ok_or("Dhcp4 missing")?;
                let subnets = dhcp4
                    .get_mut("subnet4")
                    .ok_or("subnet4 missing")?
                    .as_array_mut()
                    .ok_or("subnet4 not an array")?;
                subnets.push(json!({
                    "id": 2,
                    "valid-lifetime": 7200
                }));
                Ok(())
            },
        )
        .await;

        let error = result.expect_err("write failure should return error");
        let error_message = error.to_string();

        assert!(error_message.contains("rolled back"));
        assert_eq!(calls.len(), 5);
        assert_eq!(calls[0]["command"], "config-get");
        assert_eq!(calls[3]["command"], "config-write");
        // The rollback's own config-set (call 5) must carry the ORIGINAL
        // pre-modify config, restoring exactly what was there before this
        // request, not some other value.
        assert_eq!(calls[4]["command"], "config-set");
        assert_eq!(calls[4]["arguments"], initial_config);
        assert_eq!(calls[1]["arguments"], expected_modified);
        assert_eq!(calls[2]["arguments"], expected_modified);
    }

    // First config-write is a Transport failure (AmbiguousFailure), so a
    // retry is attempted before any rollback decision; the retry succeeds,
    // so the overall result must be Ok with NO config-set rollback call at
    // all -- confirming an ambiguous-then-successful outcome is treated as
    // a real success, not "success but still roll back to be safe".
    #[tokio::test]
    async fn kea_config_modify_accepts_successful_write_retry_after_ambiguous_failure() {
        let initial_config = json!({
            "Dhcp4": {
                "subnet4": [
                    {
                        "id": 1,
                        "valid-lifetime": 3600
                    }
                ]
            }
        });
        let expected_modified = json!({
            "Dhcp4": {
                "subnet4": [
                    {
                        "id": 1,
                        "valid-lifetime": 3600
                    },
                    {
                        "id": 2,
                        "valid-lifetime": 7200
                    }
                ]
            }
        });

        // Step 4 is a Transport failure (the ambiguous case), step 5 is the
        // retry -- both are config-write attempts, no rollback config-set
        // step exists in this list at all.
        let (result, calls) = run_kea_config_modify_with_steps(
            vec![
                MockStep::Response(kea_config_get_response(initial_config.clone())),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
                MockStep::Transport("config-write transport failure"),
                MockStep::Response(kea_success_response()),
            ],
            |config| {
                let dhcp4 = config.get_mut("Dhcp4").ok_or("Dhcp4 missing")?;
                let subnets = dhcp4
                    .get_mut("subnet4")
                    .ok_or("subnet4 missing")?
                    .as_array_mut()
                    .ok_or("subnet4 not an array")?;
                subnets.push(json!({
                    "id": 2,
                    "valid-lifetime": 7200
                }));
                Ok(())
            },
        )
        .await;

        assert!(result.is_ok());
        assert_eq!(calls.len(), 5);
        assert_eq!(calls[0]["command"], "config-get");
        assert_eq!(calls[3]["command"], "config-write");
        assert_eq!(calls[4]["command"], "config-write");
        // No config-set call anywhere in the whole call log carries the
        // original pre-modify config -- i.e. rollback genuinely never ran,
        // not just that its result was overwritten by the later success.
        assert!(
            !calls.iter().any(|cmd| cmd["command"] == "config-set"
                && cmd.get("arguments") == Some(&initial_config)),
            "successful write retry should not rollback",
        );
        assert_eq!(calls[1]["arguments"], expected_modified);
        assert_eq!(calls[2]["arguments"], expected_modified);
    }

    // First config-write is ambiguous (Transport failure), the retry gets a
    // definite Kea rejection -- kea_config_modify_with_post's own comment on
    // this exact case says not to roll back blindly here, since a config
    // that failed once ambiguously and then failed for real on retry could
    // still be sitting applied-but-unconfirmed at Kea; this locks in that
    // the function reports the error instead of guessing and rolling back.
    #[tokio::test]
    async fn kea_config_modify_does_not_rollback_when_write_retry_confirms_failure() {
        let initial_config = json!({
            "Dhcp4": {
                "subnet4": [
                    {
                        "id": 1,
                        "valid-lifetime": 3600
                    }
                ]
            }
        });

        // Step 4 (first config-write) is Transport, step 5 (the retry) is a
        // real Kea rejection -- both attempts made, neither succeeded.
        let (result, calls) = run_kea_config_modify_with_steps(
            vec![
                MockStep::Response(kea_config_get_response(initial_config.clone())),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
                MockStep::Transport("config-write transport failure"),
                MockStep::Response(json!([{ "result": 1, "text": "write failed on retry" }])),
            ],
            |config| {
                let dhcp4 = config.get_mut("Dhcp4").ok_or("Dhcp4 missing")?;
                let subnets = dhcp4
                    .get_mut("subnet4")
                    .ok_or("subnet4 missing")?
                    .as_array_mut()
                    .ok_or("subnet4 not an array")?;
                subnets.push(json!({
                    "id": 2,
                    "valid-lifetime": 7200
                }));
                Ok(())
            },
        )
        .await;

        let error = result.expect_err("confirmed retry failure after ambiguous write should error");
        let error_message = error.to_string();

        assert!(error_message.contains("first config-write result was ambiguous"));
        assert_eq!(calls.len(), 5);
        assert_eq!(calls[3]["command"], "config-write");
        assert_eq!(calls[4]["command"], "config-write");
        assert!(
            !calls.iter().any(|cmd| cmd["command"] == "config-set"
                && cmd.get("arguments") == Some(&initial_config)),
            "confirmed retry failure after ambiguous first write should not rollback blindly",
        );
    }

    // Both the first config-write AND its retry are Transport failures --
    // the worst case, where it's never confirmed either way whether Kea
    // ever actually wrote the config. Still no rollback: rolling back here
    // could clobber a write that silently succeeded despite the transport
    // error, which is exactly the risk AmbiguousFailure exists to avoid.
    #[tokio::test]
    async fn kea_config_modify_does_not_rollback_on_ambiguous_write_failure() {
        let initial_config = json!({
            "Dhcp4": {
                "subnet4": [
                    {
                        "id": 1,
                        "valid-lifetime": 3600
                    }
                ]
            }
        });

        // Both config-write attempts (step 4 and its retry, step 5) are
        // Transport failures -- Kea's own verdict on the write is never
        // learned either time.
        let (result, calls) = run_kea_config_modify_with_steps(
            vec![
                MockStep::Response(kea_config_get_response(initial_config.clone())),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
                MockStep::Transport("config-write transport failure"),
                MockStep::Transport("config-write transport failure"),
            ],
            |config| {
                let dhcp4 = config.get_mut("Dhcp4").ok_or("Dhcp4 missing")?;
                let subnets = dhcp4
                    .get_mut("subnet4")
                    .ok_or("subnet4 missing")?
                    .as_array_mut()
                    .ok_or("subnet4 not an array")?;
                subnets.push(json!({
                    "id": 2,
                    "valid-lifetime": 7200
                }));
                Ok(())
            },
        )
        .await;

        let error = result.expect_err("ambiguous write should return error");
        let error_message = error.to_string();

        assert!(error_message.contains("could not be confirmed after retry"));
        assert_eq!(calls.len(), 5);
        assert_eq!(calls[3]["command"], "config-write");
        assert_eq!(calls[4]["command"], "config-write");
        assert!(
            !calls.iter().any(|cmd| cmd["command"] == "config-set"
                && cmd.get("arguments") == Some(&initial_config)),
            "ambiguous write failure should not rollback blindly",
        );
    }

    // Reservations live nested inside each subnet4 entry in Kea's config, not
    // in one flat top-level list -- this pins that fetch_reservations_from_config
    // flattens across every subnet (including one with none at all) while
    // still tagging each result with its owning subnet_id, and that a
    // missing hostname renders as "" rather than panicking.
    #[test]
    fn collect_reservations_reads_nested_subnet_entries() {
        let config = json!({
            "Dhcp4": {
                "subnet4": [
                    {
                        "id": 7,
                        "reservations": [
                            {
                                "hw-address": "AA-BB-CC-DD-EE-FF",
                                "ip-address": "10.0.0.50",
                                "hostname": "desktop"
                            },
                            {
                                "hw-address": "11:22:33:44:55:66",
                                "ip-address": "10.0.0.51"
                            }
                        ]
                    },
                    {"id": 8}
                ]
            }
        });

        let reservations = fetch_reservations_from_config(&config);

        assert_eq!(reservations.len(), 2);
        assert_eq!(reservations[0].subnet_id, 7);
        assert_eq!(reservations[0].mac, "aa:bb:cc:dd:ee:ff");
        assert_eq!(reservations[0].hostname, "desktop");
        assert_eq!(reservations[1].mac, "11:22:33:44:55:66");
        assert_eq!(reservations[1].hostname, "");
    }

    // add_reservation's "update by MAC" path (upsert_reservation) must
    // preserve fields it doesn't itself set (option-data, client-classes)
    // when overwriting an existing entry's ip-address/hostname -- otherwise
    // editing a reservation through the Admin UI would silently drop any
    // manually-added Kea options on that host. Matching is by normalized
    // MAC, so "AA-BB-..." must still find "aa:bb:...".
    #[test]
    fn reservation_upsert_and_remove_keep_subnet_state_consistent() {
        let mut subnet = json!({
            "id": 12,
            "reservations": [
                {
                    "hw-address": "aa:bb:cc:dd:ee:ff",
                    "ip-address": "10.0.0.50",
                    "hostname": "old",
                    "option-data": [{"name": "boot-file-name", "data": "pxelinux.0"}],
                    "client-classes": ["known"]
                }
            ]
        });

        {
            let reservations = subnet_reservations_mut(&mut subnet).expect("reservations array");
            upsert_reservation(
                reservations,
                json!({
                    "hw-address": "AA-BB-CC-DD-EE-FF",
                    "ip-address": "10.0.0.60",
                    "hostname": "new"
                }),
            )
            .expect("upsert reservation");
        }

        let reservations = subnet
            .get("reservations")
            .and_then(|value| value.as_array())
            .expect("reservations array");
        assert_eq!(reservations.len(), 1);
        assert_eq!(reservations[0]["ip-address"], "10.0.0.60");
        assert_eq!(reservations[0]["hostname"], "new");
        assert_eq!(reservations[0]["option-data"][0]["data"], "pxelinux.0");
        assert_eq!(reservations[0]["client-classes"][0], "known");

        // Removal is looked up by the same hyphenated MAC form used for the
        // upsert above, confirming remove_reservation_entry normalizes its
        // own `mac` argument rather than requiring an exact stored-form match.
        {
            let reservations = subnet_reservations_mut(&mut subnet).expect("reservations array");
            remove_reservation_entry(reservations, "AA-BB-CC-DD-EE-FF");
        }

        let reservations = subnet
            .get("reservations")
            .and_then(|value| value.as_array())
            .expect("reservations array");
        assert!(reservations.is_empty());
    }

    // max-valid-lifetime must never be computed as double the requested
    // lease time when that would overflow past this project's own
    // MAX_LEASE_TIME cap -- Kea accepts max-valid-lifetime > valid-lifetime,
    // so an uncapped doubling would silently let leases renew past the
    // operator-intended maximum instead of erroring or clamping.
    #[test]
    fn build_subnet_value_clamps_max_valid_lifetime_to_lease_time_cap() {
        let subnet = build_subnet_value(SubnetValue {
            id: 4,
            subnet: "10.0.0.0/24".to_string(),
            pool_start: "10.0.0.10".to_string(),
            pool_end: "10.0.0.200".to_string(),
            gateway: "10.0.0.1".to_string(),
            dns_primary: "10.0.0.2".to_string(),
            dns_secondary: "10.0.0.3".to_string(),
            ntp_servers: "10.0.0.4".to_string(),
            domain: "lan.example".to_string(),
            lease_time: MAX_LEASE_TIME,
            editable_options: Vec::new(),
            reservations: None,
        })
        .expect("subnet value");

        assert_eq!(subnet["valid-lifetime"], MAX_LEASE_TIME);
        assert_eq!(subnet["max-valid-lifetime"], MAX_LEASE_TIME);
    }

    // build_subnet_value is only called from add_subnet (new subnet, always
    // reservations: None) and update_subnet (existing subnet, reservations
    // carried through from compatible_reservations_for_subnet) -- this pins
    // that the Some(...) path actually writes the given reservations into
    // the built JSON rather than silently dropping them on update.
    #[test]
    fn build_subnet_value_preserves_reservations_when_present() {
        let reservations = vec![json!({
            "hw-address": "aa:bb:cc:dd:ee:ff",
            "ip-address": "10.0.0.50",
            "hostname": "host"
        })];
        let subnet = build_subnet_value(SubnetValue {
            id: 3,
            subnet: "10.0.0.0/24".to_string(),
            pool_start: "10.0.0.10".to_string(),
            pool_end: "10.0.0.200".to_string(),
            gateway: "10.0.0.1".to_string(),
            dns_primary: "10.0.0.2".to_string(),
            dns_secondary: "10.0.0.3".to_string(),
            ntp_servers: "10.0.0.4".to_string(),
            domain: "lan.example".to_string(),
            lease_time: 3600,
            editable_options: Vec::new(),
            reservations: Some(reservations.clone()),
        })
        .expect("subnet value");

        assert_eq!(subnet["id"], 3);
        assert_eq!(subnet["valid-lifetime"], 3600);
        assert_eq!(subnet["max-valid-lifetime"], 7200);
        assert_eq!(subnet["reservations"], Value::Array(reservations));
    }

    // update_subnet only ever sends the fields the Admin UI's edit form
    // actually exposes -- anything Kea/an operator set outside that form
    // (ddns-qualifying-suffix, relay, a vendor-space option, reservations)
    // must survive an unrelated edit untouched, not get silently erased by
    // this function rewriting the whole subnet object from scratch. The
    // vendor-space option (code 3 under "vendor-foo", not "dhcp4") is the
    // key case: it shares a numeric code with the UI-managed "routers"
    // option but must never be treated as the same option.
    #[test]
    fn apply_subnet_value_preserves_unmanaged_kea_fields_and_options() {
        let mut subnet = json!({
            "id": 3,
            "subnet": "10.0.0.0/24",
            "pools": [{"pool": "10.0.0.10 - 10.0.0.200"}],
            "option-data": [
                {"name": "routers", "data": "10.0.0.1"},
                {"code": 3, "data": "10.0.0.254"},
                {"name": "domain-name-servers", "data": "10.0.0.2, 10.0.0.3"},
                {"name": "ntp-servers", "data": "10.0.0.4"},
                {"name": "domain-name", "data": "old.lan"},
                {"code": 15, "data": "old-by-code.lan"},
                {"name": "domain-search", "data": "old.lan"},
                {"code": 119, "data": "old-search-by-code.lan"},
                {"space": "vendor-foo", "code": 3, "data": "keep-vendor-route"}
            ],
            "valid-lifetime": 3600,
            "reservations": [
                {
                    "hw-address": "aa:bb:cc:dd:ee:ff",
                    "ip-address": "10.0.0.50"
                }
            ],
            "ddns-qualifying-suffix": "lan",
            "relay": {"ip-addresses": ["10.0.0.1"]}
        });

        // preserved_subnet_options is called BEFORE apply_subnet_value, on
        // the original subnet -- mirroring how update_subnet itself must
        // capture the existing custom options before overwriting the entry,
        // since apply_subnet_value has no other way to see what was there
        // beforehand.
        let preserved_options = preserved_subnet_options(&subnet);

        apply_subnet_value(
            &mut subnet,
            SubnetValue {
                id: 3,
                subnet: "10.0.1.0/24".to_string(),
                pool_start: "10.0.1.10".to_string(),
                pool_end: "10.0.1.200".to_string(),
                gateway: "10.0.1.1".to_string(),
                dns_primary: "10.0.1.2".to_string(),
                dns_secondary: "10.0.1.3".to_string(),
                ntp_servers: "10.0.1.4".to_string(),
                domain: "new.lan".to_string(),
                lease_time: 7200,
                editable_options: preserved_options,
                reservations: None,
            },
        )
        .expect("apply subnet value");

        assert_eq!(subnet["subnet"], "10.0.1.0/24");
        assert_eq!(subnet["valid-lifetime"], 7200);
        assert_eq!(subnet["max-valid-lifetime"], 14400);
        assert_eq!(subnet["reservations"][0]["ip-address"], "10.0.0.50");
        assert_eq!(subnet["ddns-qualifying-suffix"], "lan");
        assert_eq!(subnet["relay"]["ip-addresses"][0], "10.0.0.1");

        // The three assertion groups below: (1) the old dhcp4-space
        // UI-managed entries (by name or by code 3/15/119) are gone, (2)
        // the vendor-space code-3 entry survives untouched despite sharing
        // a code with "routers", and (3) fresh UI-managed entries reflect
        // this save's new form values.
        let options = subnet["option-data"].as_array().expect("option-data array");
        assert!(!options
            .iter()
            .any(|option| option["code"] == 3 && is_dhcp4_option_space(option)));
        assert!(!options
            .iter()
            .any(|option| option["code"] == 15 && is_dhcp4_option_space(option)));
        assert!(!options
            .iter()
            .any(|option| option["code"] == 119 && is_dhcp4_option_space(option)));
        assert!(options.iter().any(|option| option["space"] == "vendor-foo"
            && option["code"] == 3
            && option["data"] == "keep-vendor-route"));
        assert!(options
            .iter()
            .any(|option| option["name"] == "domain-name-servers"
                && option["data"] == "10.0.1.2, 10.0.1.3"));
        assert!(options
            .iter()
            .any(|option| option["name"] == "ntp-servers" && option["data"] == "10.0.1.4"));
        assert!(options
            .iter()
            .any(|option| option["name"] == "routers" && option["data"] == "10.0.1.1"));
        assert!(options
            .iter()
            .any(|option| option["name"] == "domain-name" && option["data"] == "new.lan"));
        assert!(options
            .iter()
            .any(|option| option["name"] == "domain-search" && option["data"] == "new.lan"));
    }

    // Kea's own config-get response identifies well-known options by numeric
    // code, not the human-readable "name" the Admin UI writes -- parse_subnet_entry
    // must recognize both forms, or a subnet fetched straight from Kea (as
    // opposed to one this project itself just wrote) would render its
    // gateway/DNS/NTP/domain fields as empty on the settings page.
    #[test]
    fn parse_subnet_entry_reads_managed_options_by_numeric_code() {
        let subnet = json!({
            "id": 3,
            "subnet": "10.0.0.0/24",
            "pools": [{"pool": "10.0.0.10 - 10.0.0.200"}],
            "option-data": [
                {"code": 3, "data": "10.0.0.1"},
                {"code": 6, "data": "10.0.0.2, 10.0.0.3"},
                {"code": 15, "data": "lan.example"},
                {"code": 42, "data": "10.0.0.4"}
            ],
            "valid-lifetime": 3600
        });

        let parsed = parse_subnet_entry(&subnet);

        assert_eq!(parsed.gateway, "10.0.0.1");
        assert_eq!(parsed.dns_primary, "10.0.0.2");
        assert_eq!(parsed.dns_secondary, "10.0.0.3");
        assert_eq!(parsed.ntp_servers, "10.0.0.4");
        assert_eq!(parsed.domain, "lan.example");
    }

    // Companion to the numeric-code test above: a vendor-space option that
    // happens to share code 3 (or the "domain-name" name) with a managed
    // dhcp4 option must NOT be misread as that managed option -- otherwise
    // an unrelated vendor option's data could silently overwrite the parsed
    // gateway/domain shown in the Admin UI.
    #[test]
    fn parse_subnet_entry_ignores_non_dhcp4_matching_option_codes() {
        let subnet = json!({
            "id": 3,
            "subnet": "10.0.0.0/24",
            "pools": [{"pool": "10.0.0.10 - 10.0.0.200"}],
            "option-data": [
                {"space": "vendor-foo", "code": 3, "data": "not-a-router"},
                {"space": "vendor-foo", "name": "domain-name", "data": "not-a-domain"},
                {"space": "dhcp4", "code": 3, "data": "10.0.0.1"},
                {"name": "domain-name", "data": "lan.example"}
            ],
            "valid-lifetime": 3600
        });

        let parsed = parse_subnet_entry(&subnet);

        assert_eq!(parsed.gateway, "10.0.0.1");
        assert_eq!(parsed.domain, "lan.example");
    }

    // build_subnet_value starts from an empty editable_options list (unlike
    // apply_subnet_value, which is handed the PREVIOUS subnet's preserved
    // options) -- a fresh subnet must only ever get the fields its own form
    // submitted (here: no NTP servers were given, so no ntp-servers option
    // should appear), never carry over state from an unrelated subnet.
    #[test]
    fn build_subnet_value_does_not_inherit_unmanaged_options_from_other_subnets() {
        let subnet = build_subnet_value(SubnetValue {
            id: 4,
            subnet: "10.0.2.0/24".to_string(),
            pool_start: "10.0.2.10".to_string(),
            pool_end: "10.0.2.200".to_string(),
            gateway: "10.0.2.1".to_string(),
            dns_primary: "10.0.2.2".to_string(),
            dns_secondary: "10.0.2.3".to_string(),
            ntp_servers: String::new(),
            domain: "new.lan".to_string(),
            lease_time: 3600,
            editable_options: Vec::new(),
            reservations: None,
        })
        .expect("subnet value");

        let options = subnet["option-data"].as_array().expect("option-data array");
        assert_eq!(options.len(), 4);
        assert!(options
            .iter()
            .any(|option| option["name"] == "routers" && option["data"] == "10.0.2.1"));
        assert!(options
            .iter()
            .any(|option| option["name"] == "domain-name-servers"
                && option["data"] == "10.0.2.2, 10.0.2.3"));
        assert!(!options.iter().any(|option| option["name"] == "ntp-servers"));
    }

    // editable_options (custom, non-UI-managed options like boot-file-name
    // or an arbitrary vendor option) must pass through build_subnet_value
    // unchanged, on top of the UI-managed fields the form itself sets --
    // proves the two option sources are merged, not mutually exclusive.
    #[test]
    fn build_subnet_value_preserves_editable_extra_option_data() {
        let subnet = build_subnet_value(SubnetValue {
            id: 5,
            subnet: "10.0.3.0/24".to_string(),
            pool_start: "10.0.3.10".to_string(),
            pool_end: "10.0.3.200".to_string(),
            gateway: "10.0.3.1".to_string(),
            dns_primary: "10.0.3.2".to_string(),
            dns_secondary: "10.0.3.3".to_string(),
            ntp_servers: "10.0.3.4".to_string(),
            domain: "new.lan".to_string(),
            lease_time: 7200,
            editable_options: vec![
                json!({"name": "boot-file-name", "data": "pxelinux.0"}),
                json!({"name": "vendor-foo", "data": "keep-me"}),
            ],
            reservations: None,
        })
        .expect("subnet value");

        let options = subnet["option-data"].as_array().expect("option-data array");
        assert!(options
            .iter()
            .any(|option| option["name"] == "boot-file-name" && option["data"] == "pxelinux.0"));
        assert!(options
            .iter()
            .any(|option| option["name"] == "vendor-foo" && option["data"] == "keep-me"));
        assert!(options
            .iter()
            .any(|option| option["name"] == "ntp-servers" && option["data"] == "10.0.3.4"));
    }

    // The custom-option form (add_subnet_option) must refuse the 5 codes
    // the dedicated gateway/DNS/domain/NTP fields already own -- otherwise
    // an operator could set the same option two conflicting ways, and
    // whichever write happened last would silently win.
    #[test]
    fn custom_dhcp_option_validation_rejects_managed_codes() {
        for code in ["3", "6", "15", "42", "119"] {
            assert!(parse_custom_dhcp_option_code(code).is_err());
        }

        assert_eq!(
            parse_custom_dhcp_option_code("66").expect("custom code"),
            66
        );
        assert!(validate_custom_dhcp_option_data("pxelinux.0").is_ok());
        assert!(validate_custom_dhcp_option_data("").is_err());
        assert!(validate_custom_dhcp_option_data("line\nbreak").is_err());
    }

    // Issue #1085: the same custom-option "code" field must also accept the
    // three PXE top-level subnet keys verbatim, while still parsing a numeric
    // code and rejecting an arbitrary non-numeric string -- otherwise the PXE
    // keys would hit the numeric-only parser and be rejected as "not a number".
    #[test]
    fn parse_custom_option_key_accepts_pxe_names_and_numeric_codes() {
        for field in PXE_SUBNET_FIELDS {
            match parse_custom_option_key(field).expect("pxe key") {
                CustomOptionKey::Pxe(parsed) => assert_eq!(parsed, field),
                CustomOptionKey::Numeric(_) => panic!("{field} parsed as numeric"),
            }
        }
        // Surrounding whitespace is tolerated (form fields often carry it).
        assert!(matches!(
            parse_custom_option_key("  next-server  ").expect("trimmed pxe key"),
            CustomOptionKey::Pxe("next-server")
        ));
        assert!(matches!(
            parse_custom_option_key("66").expect("numeric key"),
            CustomOptionKey::Numeric(66)
        ));
        // An unrelated non-numeric string is neither a PXE key nor a code.
        assert!(parse_custom_option_key("boot-file").is_err());
        assert!(parse_custom_option_key("tftp-server-name").is_err());
    }

    // Issue #1085: next-server is a bare IPv4 field in Kea (a hostname is
    // rejected), so its data validator must require a parseable IPv4; the two
    // string fields keep the generic one-line rules but gain a BOOTP-accurate
    // byte cap so an over-long value fails here with a clear message instead
    // of surfacing only as a later Kea config-test rejection.
    #[test]
    fn validate_custom_option_data_enforces_per_pxe_field_rules() {
        let next_server = parse_custom_option_key("next-server").expect("key");
        assert_eq!(
            validate_custom_option_data(next_server, " 10.0.0.1 ").expect("valid ip"),
            "10.0.0.1"
        );
        assert!(validate_custom_option_data(next_server, "boot.lan").is_err());

        let server_hostname = parse_custom_option_key("server-hostname").expect("key");
        assert!(validate_custom_option_data(server_hostname, "tftp-01").is_ok());
        assert!(validate_custom_option_data(server_hostname, &"h".repeat(65)).is_err());

        let boot_file = parse_custom_option_key("boot-file-name").expect("key");
        assert!(validate_custom_option_data(boot_file, "pxelinux.0").is_ok());
        assert!(validate_custom_option_data(boot_file, &"f".repeat(129)).is_err());
        // 128 bytes is still accepted (boundary), 65 bytes is fine for a file.
        assert!(validate_custom_option_data(boot_file, &"f".repeat(128)).is_ok());
    }

    // Issue #1085: a PXE field is a single-valued top-level subnet key (not an
    // option-data array entry), so set writes it at the top level and rejects
    // an exact duplicate (double-submit guard) while allowing an overwrite to
    // a new value; remove clears it only when the echoed-back value still
    // matches, and errors otherwise.
    #[test]
    fn pxe_subnet_field_set_and_remove_round_trip() {
        let mut subnet = json!({"id": 1, "option-data": []});

        set_pxe_subnet_field(&mut subnet, "next-server", "10.0.0.5").expect("set");
        assert_eq!(subnet["next-server"], "10.0.0.5");
        // The write lands at the top level, never in option-data.
        assert!(subnet["option-data"].as_array().expect("array").is_empty());

        // Exact duplicate is rejected; a different value overwrites.
        assert!(set_pxe_subnet_field(&mut subnet, "next-server", "10.0.0.5").is_err());
        set_pxe_subnet_field(&mut subnet, "next-server", "10.0.0.6").expect("overwrite");
        assert_eq!(subnet["next-server"], "10.0.0.6");

        // Remove requires the current value to match; a stale value does not.
        assert!(remove_pxe_subnet_field(&mut subnet, "next-server", "10.0.0.5").is_err());
        remove_pxe_subnet_field(&mut subnet, "next-server", "10.0.0.6").expect("remove");
        assert!(subnet.get("next-server").is_none());
        // Removing an absent field is a not-found error, not a silent no-op.
        assert!(remove_pxe_subnet_field(&mut subnet, "next-server", "10.0.0.6").is_err());
    }

    // Issue #1085 regression guard: an operator-set PXE top-level field must
    // survive an unrelated subnet edit. update_subnet runs apply_subnet_value
    // on the existing entry, which only rewrites specific keys -- if that ever
    // changed to rebuild the subnet from scratch, these fields would be
    // silently erased on the next save (the exact "accepted, never persists"
    // failure class this project refuses to ship).
    #[test]
    fn apply_subnet_value_preserves_pxe_top_level_fields() {
        let mut subnet = json!({
            "id": 4,
            "subnet": "10.0.0.0/24",
            "pools": [{"pool": "10.0.0.10 - 10.0.0.200"}],
            "option-data": [],
            "valid-lifetime": 3600,
            "next-server": "10.0.0.9",
            "server-hostname": "tftp-01",
            "boot-file-name": "pxelinux.0"
        });

        let preserved_options = preserved_subnet_options(&subnet);
        apply_subnet_value(
            &mut subnet,
            SubnetValue {
                id: 4,
                subnet: "10.0.0.0/24".to_string(),
                pool_start: "10.0.0.10".to_string(),
                pool_end: "10.0.0.200".to_string(),
                gateway: "10.0.0.1".to_string(),
                dns_primary: "10.0.0.2".to_string(),
                dns_secondary: "10.0.0.3".to_string(),
                ntp_servers: String::new(),
                domain: "lan".to_string(),
                lease_time: 3600,
                editable_options: preserved_options,
                reservations: None,
            },
        )
        .expect("apply subnet value");

        assert_eq!(subnet["next-server"], "10.0.0.9");
        assert_eq!(subnet["server-hostname"], "tftp-01");
        assert_eq!(subnet["boot-file-name"], "pxelinux.0");
    }

    // Issue #1076: the DDNS toggle's read side must report the live
    // enable-updates value, and must default to false (DDNS off) when the key
    // is absent -- reading a config with no dhcp-ddns block must not be
    // mistaken for "DDNS on".
    #[test]
    fn config_ddns_enabled_reads_switch_and_defaults_off() {
        assert!(config_ddns_enabled(&json!({
            "Dhcp4": {"dhcp-ddns": {"enable-updates": true}}
        })));
        assert!(!config_ddns_enabled(&json!({
            "Dhcp4": {"dhcp-ddns": {"enable-updates": false}}
        })));
        // Missing dhcp-ddns block, missing enable-updates key, and a
        // non-boolean value all fall back to false rather than panicking or
        // reporting "on".
        assert!(!config_ddns_enabled(&json!({"Dhcp4": {}})));
        assert!(!config_ddns_enabled(&json!({"Dhcp4": {"dhcp-ddns": {}}})));
        assert!(!config_ddns_enabled(&json!({})));
    }

    // Issue #1076: the toggle must flip only enable-updates and leave every
    // other dhcp-ddns field (server-ip/port/queue/...) exactly as the
    // entrypoint rendered it, since those are not the operator's to change
    // here. It must also self-heal a config whose dhcp-ddns block is missing
    // rather than erroring.
    #[test]
    fn set_config_ddns_enabled_preserves_other_ddns_fields() {
        let mut config = json!({
            "Dhcp4": {
                "dhcp-ddns": {
                    "enable-updates": false,
                    "server-ip": "127.0.0.1",
                    "server-port": 53001,
                    "max-queue-size": 1024
                }
            }
        });
        set_config_ddns_enabled(&mut config, true).expect("set true");
        assert_eq!(config["Dhcp4"]["dhcp-ddns"]["enable-updates"], true);
        // Sibling fields untouched.
        assert_eq!(config["Dhcp4"]["dhcp-ddns"]["server-ip"], "127.0.0.1");
        assert_eq!(config["Dhcp4"]["dhcp-ddns"]["server-port"], 53001);
        assert_eq!(config["Dhcp4"]["dhcp-ddns"]["max-queue-size"], 1024);

        set_config_ddns_enabled(&mut config, false).expect("set false");
        assert_eq!(config["Dhcp4"]["dhcp-ddns"]["enable-updates"], false);

        // A config with no dhcp-ddns block gets one created rather than erroring.
        let mut bare = json!({"Dhcp4": {}});
        set_config_ddns_enabled(&mut bare, true).expect("create block");
        assert_eq!(bare["Dhcp4"]["dhcp-ddns"]["enable-updates"], true);

        // A config with no Dhcp4 object is a real error, not a silent no-op.
        let mut broken = json!({});
        assert!(set_config_ddns_enabled(&mut broken, true).is_err());
    }

    // Issue #1076: the UI toggle and entrypoint.sh's DHCP_DDNS_ENABLED
    // normalization must agree on which spellings mean "on"; anything else
    // (including empty/garbage) must read as off, so a malformed submit can
    // never accidentally enable DDNS.
    #[test]
    fn parse_bool_flag_matches_entrypoint_normalization() {
        for on in ["1", "true", "TRUE", "yes", "On", " true "] {
            assert!(parse_bool_flag(on), "{on:?} should be true");
        }
        for off in ["0", "false", "no", "off", "", "  ", "enabled", "2"] {
            assert!(!parse_bool_flag(off), "{off:?} should be false");
        }
    }

    // Issue #1083: the forward-record cleanup must split Kea's stored FQDN
    // into the right PowerDNS zone (its parent domain) and canonical record
    // name (trailing dot), tolerate an already-dotted/mixed-case input, and
    // refuse a bare single-label name that has no parent zone to delete from.
    #[test]
    fn forward_record_zone_and_name_splits_fqdn() {
        assert_eq!(
            forward_record_zone_and_name("laptop.lan"),
            Some(("lan".to_string(), "laptop.lan.".to_string()))
        );
        assert_eq!(
            forward_record_zone_and_name("Laptop.LAN."),
            Some(("lan".to_string(), "laptop.lan.".to_string()))
        );
        assert_eq!(
            forward_record_zone_and_name("host.local.lan."),
            Some(("local.lan".to_string(), "host.local.lan.".to_string()))
        );
        // A bare label (or empty/whitespace) has no parent zone to target.
        assert_eq!(forward_record_zone_and_name("lan"), None);
        assert_eq!(forward_record_zone_and_name(""), None);
        assert_eq!(forward_record_zone_and_name("   "), None);
    }

    // Issue #1083: the reverse-PTR cleanup must map an IPv4 to the exact
    // private reverse zone services/dns actually hosts and to the canonical
    // PTR name, and must skip any address outside the RFC1918 ranges -- no
    // such zone exists there, so a PTR delete would be a pointless/wrong
    // request. The 172.16-31 boundary is the easy-to-get-wrong case.
    #[test]
    fn reverse_ptr_zone_and_name_covers_rfc1918_and_skips_public() {
        assert_eq!(
            reverse_ptr_zone_and_name("10.1.2.3"),
            Some((
                "10.in-addr.arpa".to_string(),
                "3.2.1.10.in-addr.arpa.".to_string()
            ))
        );
        assert_eq!(
            reverse_ptr_zone_and_name("192.168.1.42"),
            Some((
                "168.192.in-addr.arpa".to_string(),
                "42.1.168.192.in-addr.arpa.".to_string()
            ))
        );
        assert_eq!(
            reverse_ptr_zone_and_name("172.16.5.6"),
            Some((
                "16.172.in-addr.arpa".to_string(),
                "6.5.16.172.in-addr.arpa.".to_string()
            ))
        );
        assert_eq!(
            reverse_ptr_zone_and_name("172.31.9.9"),
            Some((
                "31.172.in-addr.arpa".to_string(),
                "9.9.31.172.in-addr.arpa.".to_string()
            ))
        );
        // 172.15 and 172.32 are just outside the private block; public IPs and
        // non-IPs skip too.
        assert_eq!(reverse_ptr_zone_and_name("172.15.0.1"), None);
        assert_eq!(reverse_ptr_zone_and_name("172.32.0.1"), None);
        assert_eq!(reverse_ptr_zone_and_name("8.8.8.8"), None);
        assert_eq!(reverse_ptr_zone_and_name("not-an-ip"), None);
    }

    // ─── Issue #450: dnsmasq relay/proxy field validators ───
    //
    // These three validators are this project's only defense before an
    // operator-submitted value is rendered unquoted into dnsmasq.conf
    // directives -- the "junk" cases in each test below (a shell metachar,
    // an embedded space/comma/newline) are exactly the inputs that could
    // otherwise corrupt the generated config or, worse, inject a second
    // directive. `dnsmasq --test` is still the authoritative fail-closed
    // gate (see entrypoint.sh), but these validators exist so the Admin UI
    // gives immediate feedback instead of a config-write failure much later.

    // Dots and underscores must be accepted (VLAN sub-interfaces like
    // "br-lan.100", predictable names like "eno1_2"), while a shell
    // metacharacter, an embedded space, or exceeding the 64-byte cap must be
    // rejected -- those are exactly the inputs that could otherwise corrupt
    // or extend the generated dnsmasq interface directive.
    #[test]
    fn interface_name_validator_accepts_typical_names_and_rejects_junk() {
        assert!(is_valid_interface_name("eth0"));
        assert!(is_valid_interface_name("br-lan.100"));
        assert!(is_valid_interface_name("eno1_2"));
        assert!(!is_valid_interface_name(""));
        assert!(!is_valid_interface_name("eth0;rm -rf /"));
        assert!(!is_valid_interface_name("eth 0"));
        assert!(!is_valid_interface_name(&"a".repeat(65)));
    }

    // Exercises is_valid_domain_name's per-label delegation to
    // is_valid_dns_label: a leading hyphen, a trailing hyphen, and an empty
    // label from a doubled dot must each be caught individually, not left to
    // a whole-string character check that wouldn't distinguish them.
    #[test]
    fn domain_name_validator_accepts_typical_domains_and_rejects_junk() {
        assert!(is_valid_domain_name("lan.local"));
        assert!(is_valid_domain_name("example.com"));
        assert!(is_valid_domain_name("a"));
        assert!(!is_valid_domain_name(""));
        assert!(!is_valid_domain_name("-lan.local"));
        assert!(!is_valid_domain_name("lan-.local"));
        assert!(!is_valid_domain_name("lan..local"));
        assert!(!is_valid_domain_name("lan local"));
    }

    // Issue #947: remove_reservation now gates on is_valid_mac before use
    // (mirroring add_reservation/release_lease, which already validate their
    // own identifier fields), so this pure predicate needs its own direct
    // coverage rather than only being exercised indirectly through
    // add_reservation's existing checks. Covers both accepted separator
    // styles (colon and hyphen, the common copy-paste forms an operator
    // might paste in) and rejects wrong-length/non-hex junk.
    #[test]
    fn mac_validator_accepts_colon_and_hyphen_forms_and_rejects_junk() {
        assert!(is_valid_mac("AA:BB:CC:DD:EE:FF"));
        assert!(is_valid_mac("aa-bb-cc-dd-ee-ff"));
        assert!(!is_valid_mac(""));
        assert!(!is_valid_mac("AA:BB:CC:DD:EE"));
        assert!(!is_valid_mac("AA:BB:CC:DD:EE:FF:00"));
        assert!(!is_valid_mac("GG:BB:CC:DD:EE:FF"));
        assert!(!is_valid_mac("not-a-mac-address"));
    }

    // A forward-slash path (e.g. "efi/bootx64.efi") is a legitimate boot
    // filename and must be accepted, while whitespace or a comma must be
    // rejected -- those are exactly the characters that would break or
    // extend the generated dnsmasq dhcp-boot directive.
    #[test]
    fn boot_filename_validator_accepts_paths_and_rejects_whitespace_or_commas() {
        assert!(is_valid_boot_filename("pxelinux.0"));
        assert!(is_valid_boot_filename("efi/bootx64.efi"));
        assert!(!is_valid_boot_filename(""));
        assert!(!is_valid_boot_filename("pxelinux 0"));
        assert!(!is_valid_boot_filename("pxelinux.0,evil"));
        // Trailing/leading whitespace is trimmed before the check (same as
        // is_valid_domain_name), so an *embedded* newline is the meaningful
        // rejection case, not a merely-trailing one.
        assert!(!is_valid_boot_filename("pxelinux\n.0"));
    }

    // The Admin UI's textarea (one CODE:VALUE per line) and the persisted
    // DHCP_PROXY_CUSTOM_OPTIONS storage format (';'-joined single line) are
    // two different shapes for the same data -- this proves converting
    // form -> storage -> form is lossless, and that blank lines in the
    // textarea are simply skipped rather than producing an empty entry.
    #[test]
    fn custom_options_form_parses_valid_lines_and_round_trips_through_storage() {
        let storage = parse_custom_options_form("60:PXEClient\n93:0\n\n").unwrap();
        assert_eq!(storage, "60:PXEClient;93:0");

        let form = custom_options_storage_to_form(&storage);
        assert_eq!(form, "60:PXEClient\n93:0");
    }

    // Each malformed-line shape (a managed code, a missing colon, a
    // non-numeric code, empty data, an embedded ';') is a distinct way an
    // operator-typed textarea line could otherwise corrupt the ';'-joined
    // storage format or silently collide with a dedicated field -- confirms
    // every one is rejected independently, not just the obvious cases.
    #[test]
    fn custom_options_form_rejects_managed_codes_and_malformed_lines() {
        assert!(
            parse_custom_options_form("3:10.0.0.1").is_err(),
            "router code is managed by a dedicated field"
        );
        assert!(parse_custom_options_form("60").is_err(), "missing colon");
        assert!(
            parse_custom_options_form("abc:foo").is_err(),
            "non-numeric code"
        );
        assert!(parse_custom_options_form("60:").is_err(), "empty data");
        assert!(
            parse_custom_options_form("60:foo;bar").is_err(),
            "';' inside option data must be rejected -- it is the entry separator in storage"
        );
    }

    // An operator who has never used the custom-option textarea (or clears
    // it entirely) must get back an empty DHCP_PROXY_CUSTOM_OPTIONS value,
    // not an error or a spurious single empty entry.
    #[test]
    fn custom_options_form_empty_input_yields_empty_storage() {
        assert_eq!(parse_custom_options_form("").unwrap(), "");
        assert_eq!(parse_custom_options_form("   \n  \n").unwrap(), "");
        assert_eq!(custom_options_storage_to_form(""), "");
    }

    // The Admin UI's "custom options" list must show exactly the options
    // this project doesn't already manage through a dedicated field or a
    // different space -- excludes the "routers" name-managed option and a
    // non-dhcp4-space option (vendor-foo), and only ever includes entries
    // that carry an explicit numeric dhcp4 "code": a name-only entry like
    // this fixture's "boot-file-name" (no "code" field at all) never shows
    // up here as if it were a free custom option. Code 66, unmanaged by any
    // dedicated field, IS expected to show through.
    #[test]
    fn custom_subnet_options_only_expose_free_dhcp4_code_options() {
        let subnet = json!({
            "option-data": [
                {"name": "routers", "data": "10.0.0.1"},
                {"code": 6, "data": "10.0.0.2"},
                {"space": "dhcp4", "code": 66, "data": "10.0.0.20"},
                {"space": "vendor-foo", "code": 67, "data": "vendor-value"},
                {"name": "boot-file-name", "data": "legacy-name-only"}
            ]
        });

        let options = custom_subnet_options(&subnet);

        assert_eq!(options.len(), 1);
        assert_eq!(options[0].code, 66);
        assert_eq!(options[0].data, "10.0.0.20");
    }

    // add/remove_custom_subnet_option must operate on option-data as a
    // shared array without disturbing entries neither call touches (the
    // managed "routers" option, and a different custom option this call
    // isn't removing) -- and adding the exact same code+data twice must be
    // rejected, not silently duplicated.
    #[test]
    fn custom_subnet_option_add_and_remove_preserve_managed_options() {
        let mut subnet = json!({
            "option-data": [
                {"name": "routers", "data": "10.0.0.1"},
                {"space": "dhcp4", "code": 67, "data": "bootx64.efi"}
            ]
        });

        add_custom_subnet_option(&mut subnet, 66, "10.0.0.20").expect("add option");
        assert!(add_custom_subnet_option(&mut subnet, 66, "10.0.0.20").is_err());

        let options = custom_subnet_options(&subnet);
        assert_eq!(options.len(), 2);
        assert!(options
            .iter()
            .any(|option| option.code == 66 && option.data == "10.0.0.20"));

        remove_custom_subnet_option(&mut subnet, 67, "bootx64.efi").expect("remove option");
        let raw_options = subnet["option-data"].as_array().expect("option-data array");
        assert!(raw_options
            .iter()
            .any(|option| option["name"] == "routers" && option["data"] == "10.0.0.1"));
        assert!(!raw_options.iter().any(|option| option["code"] == 67));
    }

    // Pins kea_lease_del_result's own documented distinction: Kea's
    // CONTROL_RESULT_EMPTY (3) means "no matching lease" -- an ordinary
    // race, not a server error -- and must map to a different outcome than
    // a genuine error response, so release_lease can return 404 instead of
    // 500 for the empty case.
    #[test]
    fn kea_lease_del_result_reports_success_not_found_and_error_distinctly() {
        let success = json!([{"result": 0, "text": "Lease deleted."}]);
        assert_eq!(kea_lease_del_result(&success), LeaseDelOutcome::Released);

        let empty = json!([{"result": 3, "text": "No lease found."}]);
        assert_eq!(kea_lease_del_result(&empty), LeaseDelOutcome::NotFound);

        let error = json!([{"result": 1, "text": "unable to communicate with the daemon"}]);
        assert_eq!(
            kea_lease_del_result(&error),
            LeaseDelOutcome::Error("unable to communicate with the daemon".to_string())
        );
    }

    // Exercises compatible_reservations_for_subnet's own documented contract
    // (see that function's comment): an in-range reservation is kept, an
    // out-of-range one is dropped, and the client-id-only entry (no
    // ip-address at all) is kept unconditionally since there is nothing to
    // check it against the new CIDR.
    #[test]
    fn compatible_reservations_drop_addresses_outside_new_subnet() {
        let subnet = json!({
            "reservations": [
                {"hw-address": "aa:bb:cc:dd:ee:ff", "ip-address": "10.0.2.50"},
                {"hw-address": "11:22:33:44:55:66", "ip-address": "10.0.3.50"},
                {"client-id": "01:02:03"}
            ]
        });

        let reservations =
            compatible_reservations_for_subnet(&subnet, "10.0.2.0/24").expect("reservations");

        assert_eq!(reservations.len(), 2);
        assert!(reservations
            .iter()
            .any(|reservation| reservation["ip-address"] == "10.0.2.50"));
        assert!(!reservations
            .iter()
            .any(|reservation| reservation["ip-address"] == "10.0.3.50"));
        assert!(reservations
            .iter()
            .any(|reservation| reservation["client-id"] == "01:02:03"));
    }

    // Regression coverage for a real bug found by driving real Kea 2.6.3
    // (not a mock): a previous version of apply_subnet_value wrote a
    // "host-reservation-identifiers" array directly onto the per-subnet
    // JSON object. Confirmed live against Kea's actual Control Agent that
    // this is rejected outright -- "spurious 'host-reservation-identifiers'
    // parameter" -- because that parameter only exists at Dhcp4-GLOBAL
    // scope in Kea's real schema, never per subnet. Every existing test for
    // this function mocked Kea's config-test/config-set responses as a bare
    // `{"result": 0}` regardless of what was actually sent, so none of them
    // could have caught a schema violation like this -- mirroring exactly
    // how the earlier `hash`-field regression in kea_config_modify_with_post
    // went undetected the same way (a mocked config-get response that never
    // included that field). This test asserts directly on the built subnet
    // JSON (not through a mock), matching the shape a real Kea instance
    // would receive and validate.
    #[test]
    fn build_subnet_value_never_sets_host_reservation_identifiers_at_subnet_scope() {
        let subnet = build_subnet_value(SubnetValue {
            id: 6,
            subnet: "10.0.4.0/24".to_string(),
            pool_start: "10.0.4.10".to_string(),
            pool_end: "10.0.4.200".to_string(),
            gateway: "10.0.4.1".to_string(),
            dns_primary: "10.0.4.2".to_string(),
            dns_secondary: "10.0.4.3".to_string(),
            ntp_servers: "10.0.4.4".to_string(),
            domain: "lan.example".to_string(),
            lease_time: 3600,
            editable_options: Vec::new(),
            reservations: Some(vec![json!({
                "hw-address": "aa:bb:cc:dd:ee:ff",
                "ip-address": "10.0.4.50"
            })]),
        })
        .expect("subnet value");

        assert!(
            subnet.get("host-reservation-identifiers").is_none(),
            "subnet4 entries must never carry host-reservation-identifiers -- \
             real Kea rejects it at subnet scope"
        );
    }

    // Same regression, but for an existing subnet that already (incorrectly,
    // from before this fix) has the key set at subnet scope -- apply_subnet_value
    // must actively strip it, not just avoid adding a new one, so an
    // operator's next edit through the Admin UI self-heals instead of
    // staying permanently broken.
    #[test]
    fn apply_subnet_value_strips_pre_existing_host_reservation_identifiers_at_subnet_scope() {
        let mut subnet = json!({
            "id": 6,
            "host-reservation-identifiers": ["hw-address"]
        });

        apply_subnet_value(
            &mut subnet,
            SubnetValue {
                id: 6,
                subnet: "10.0.4.0/24".to_string(),
                pool_start: "10.0.4.10".to_string(),
                pool_end: "10.0.4.200".to_string(),
                gateway: "10.0.4.1".to_string(),
                dns_primary: "10.0.4.2".to_string(),
                dns_secondary: "10.0.4.3".to_string(),
                ntp_servers: "10.0.4.4".to_string(),
                domain: "lan.example".to_string(),
                lease_time: 3600,
                editable_options: Vec::new(),
                reservations: None,
            },
        )
        .expect("apply subnet value");

        assert!(subnet.get("host-reservation-identifiers").is_none());
    }

    // End-to-end regression through the exact real Kea command sequence
    // add_reservation drives (config-get -> config-test -> config-set ->
    // config-write), asserting neither config-test's nor config-set's
    // request body ever contains host-reservation-identifiers on the
    // subnet -- the same assertion style
    // kea_config_modify_strips_hash_from_config_get_before_reuse already
    // uses for the `hash`-field regression, applied to this bug instead.
    #[tokio::test]
    async fn kea_config_modify_reservation_add_never_sends_host_reservation_identifiers_at_subnet_scope(
    ) {
        let config_get_response = kea_config_get_response(json!({
            "Dhcp4": {
                "subnet4": [{"id": 1, "reservations": []}]
            }
        }));

        let (result, calls) = run_kea_config_modify_with_steps(
            vec![
                MockStep::Response(config_get_response),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
            ],
            |config| {
                let subnets = dhcp4_subnets_mut(config)?;
                let subnet = subnets
                    .iter_mut()
                    .find(|s| s["id"].as_u64() == Some(1))
                    .ok_or("subnet not found")?;
                let reservations = subnet_reservations_mut(subnet)?;
                upsert_reservation(
                    reservations,
                    json!({"hw-address": "aa:bb:cc:dd:ee:ff", "ip-address": "10.0.4.50"}),
                )?;
                Ok(())
            },
        )
        .await;

        assert!(result.is_ok());
        assert_eq!(calls[1]["command"], "config-test");
        assert_eq!(calls[2]["command"], "config-set");
        for call in &calls[1..=2] {
            let subnet = &call["arguments"]["Dhcp4"]["subnet4"][0];
            assert!(
                subnet.get("host-reservation-identifiers").is_none(),
                "{} must not send host-reservation-identifiers on the subnet -- real Kea rejects it there",
                call["command"]
            );
        }
    }

    // Regression coverage: removing the per-subnet write (above) means
    // correctness now depends entirely on the *global*
    // Dhcp4.host-reservation-identifiers list still including
    // "hw-address". This project's own shipped config never sets that key
    // (relies on Kea's compiled-in default), but nothing stopped an operator
    // from hand-editing it to something narrower -- these three cases pin the
    // helper's behavior for each state that key can be in.
    #[test]
    fn global_reservation_identifiers_include_hw_address_when_key_absent() {
        let config = json!({"Dhcp4": {"subnet4": []}});
        assert!(global_reservation_identifiers_include_hw_address(&config));
    }

    // The case where an operator explicitly lists hw-address alongside other
    // identifiers -- confirms the check reads the list's contents, not just
    // whether the key is present, so an explicit include isn't confused with
    // the narrowed-list rejection below.
    #[test]
    fn global_reservation_identifiers_include_hw_address_when_explicitly_listed() {
        let config = json!({
            "Dhcp4": {"host-reservation-identifiers": ["duid", "hw-address"]}
        });
        assert!(global_reservation_identifiers_include_hw_address(&config));
    }

    // The narrowed case: hw-address deliberately dropped from an explicit
    // list -- the counterpart to the two accept cases above, pinning that the
    // helper returns false when hw-address is missing from a non-empty
    // explicit list, not only when the key itself is absent entirely.
    #[test]
    fn global_reservation_identifiers_exclude_hw_address_when_narrowed() {
        let config = json!({
            "Dhcp4": {"host-reservation-identifiers": ["client-id"]}
        });
        assert!(!global_reservation_identifiers_include_hw_address(&config));
    }

    // End-to-end: add_reservation's guard must reject the request *before*
    // ever sending config-test/config-set -- otherwise the write would still
    // race Kea's own silent (non-)matching behavior described above. Only a
    // config-get call should happen; asserting `calls.len()` pins that
    // config-test/config-set are never reached.
    #[tokio::test]
    async fn kea_config_modify_rejects_reservation_add_when_global_identifiers_exclude_hw_address()
    {
        let config_get_response = kea_config_get_response(json!({
            "Dhcp4": {
                "host-reservation-identifiers": ["client-id"],
                "subnet4": [{"id": 1, "reservations": []}]
            }
        }));

        let (result, calls) = run_kea_config_modify_with_steps(
            vec![MockStep::Response(config_get_response)],
            |config| {
                if !global_reservation_identifiers_include_hw_address(config) {
                    return Err(
                        "cannot add a hw-address reservation: this Kea config's global \
                         Dhcp4.host-reservation-identifiers list does not include \
                         \"hw-address\", so Kea would never match it",
                    );
                }
                let subnets = dhcp4_subnets_mut(config)?;
                let subnet = subnets
                    .iter_mut()
                    .find(|s| s["id"].as_u64() == Some(1))
                    .ok_or("subnet not found")?;
                let reservations = subnet_reservations_mut(subnet)?;
                upsert_reservation(
                    reservations,
                    json!({"hw-address": "aa:bb:cc:dd:ee:ff", "ip-address": "10.0.4.50"}),
                )?;
                Ok(())
            },
        )
        .await;

        assert!(result.is_err());
        assert_eq!(calls.len(), 1, "only config-get should have been called");
        assert_eq!(calls[0]["command"], "config-get");
    }

    // check_settings_dir_writable is update_dhcp_mode's #671 pre-flight
    // guard: it must succeed for an ordinary writable directory, leaving no
    // trace of the probe file it wrote to test that.
    #[test]
    fn check_settings_dir_writable_succeeds_and_leaves_no_probe_file_behind() {
        let dir = temp_snapshot_root("dhcp-mode-write-check-ok");
        let target = dir.join("lancache-ui-settings.env");

        let result = check_settings_dir_writable(&target);
        assert!(
            result.is_ok(),
            "a fresh writable temp dir must pass: {result:?}"
        );

        let leftover_probes: Vec<_> = fs::read_dir(&dir)
            .expect("temp dir must have been created by the check")
            .filter_map(|entry| entry.ok())
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".dhcp-mode-write-check-")
            })
            .collect();
        assert!(
            leftover_probes.is_empty(),
            "probe file(s) were not cleaned up: {leftover_probes:?}"
        );

        fs::remove_dir_all(&dir).ok();
    }

    // This must not touch reconcile_dhcp_mode (Docker) at all: the whole
    // point of #671's fix is catching an unwritable settings location BEFORE
    // any container is stopped/started. Using a target whose parent path is
    // blocked by an existing regular file (rather than toggling permission
    // bits) keeps this test portable across CI environments that may run as
    // root, where read-only permission bits alone would not reproduce a
    // write failure.
    #[test]
    fn check_settings_dir_writable_rejects_when_parent_path_is_not_a_directory() {
        let base = temp_snapshot_root("dhcp-mode-write-check-blocked");
        fs::write(&base, b"this is a file, not a directory")
            .expect("create blocking file at the would-be parent dir path");
        let target = base.join("lancache-ui-settings.env");

        let result = check_settings_dir_writable(&target);

        fs::remove_file(&base).ok();

        assert!(
            result.is_err(),
            "a settings directory path blocked by a regular file must be reported as not writable"
        );
    }

    // Exercises the actual round-trip write_ui_settings_file/persist_ui_settings
    // uses in production (temp-file-then-rename), confirming the extraction
    // for #671 didn't change its on-disk behavior: only non-empty values are
    // written, in the fixed key order, and the temp file is gone afterward.
    #[test]
    fn write_ui_settings_file_writes_only_nonempty_values_in_fixed_order() {
        let dir = temp_snapshot_root("dhcp-mode-persist-roundtrip");
        fs::create_dir_all(&dir).expect("create temp dir");
        let target = dir.join("lancache-ui-settings.env");

        let result = write_ui_settings_file(
            &target,
            &[
                ("DHCP_MODE", "kea".to_string()),
                ("DHCP_DNS_PRIMARY", "".to_string()),
                ("UPSTREAM_DHCP_IP", "192.168.1.1".to_string()),
            ],
        );
        assert!(result.is_ok(), "expected a clean write: {result:?}");

        let content = fs::read_to_string(&target).expect("settings file must exist");
        assert_eq!(
            content, "DHCP_MODE=kea\nUPSTREAM_DHCP_IP=192.168.1.1\n",
            "empty DHCP_DNS_PRIMARY must be omitted, remaining keys in the fixed key-list order"
        );
        assert!(
            !target.with_extension("tmp").exists(),
            "temp-file-then-rename must not leave the .tmp file behind"
        );

        fs::remove_dir_all(&dir).ok();
    }

    // #819: confirms the two release-channel/scheduled-update keys are on
    // the same whitelist as the DHCP keys above (added to
    // write_ui_settings_file's fixed key list), so routes/setup.rs's
    // update_stack_settings can actually persist them through this same
    // function -- a key left off that list is silently dropped even if a
    // caller passes it in `values`, which is exactly the bug class this test
    // guards against.
    #[test]
    fn write_ui_settings_file_persists_release_channel_and_auto_update_keys() {
        let dir = temp_snapshot_root("stack-settings-persist-roundtrip");
        fs::create_dir_all(&dir).expect("create temp dir");
        let target = dir.join("lancache-ui-settings.env");

        let result = write_ui_settings_file(
            &target,
            &[
                ("LANCACHE_IMAGE_CHANNEL", "nightly".to_string()),
                ("AUTO_UPDATE_ENABLED", "1".to_string()),
            ],
        );
        assert!(result.is_ok(), "expected a clean write: {result:?}");

        let content = fs::read_to_string(&target).expect("settings file must exist");
        assert_eq!(
            content,
            "LANCACHE_IMAGE_CHANNEL=nightly\nAUTO_UPDATE_ENABLED=1\n"
        );

        fs::remove_dir_all(&dir).ok();
    }
}
