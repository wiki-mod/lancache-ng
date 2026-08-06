//! SPDX-License-Identifier: AGPL-3.0-or-later
//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Environment parsing and validation, mirroring watchdog.sh's own startup
//! section (env var reads, `is_truthy`, the `CHECK_INTERVAL` digit-only
//! guard, and the `CONTAINER_*` fatal-mismatch checks). Every function here
//! is pure (takes an already-read `Option<&str>`/`&str`, never touches
//! `std::env` itself) so tests can exercise every input shape directly
//! without mutating real process environment variables.

use std::time::Duration;

/// Normalizes an already-read env value the way this whole crate treats
/// them: empty and unset are equivalent. Bash's `${VAR:-default}` (the
/// colon form, which every corresponding watchdog.sh env read uses)
/// triggers its default for BOTH an unset variable AND one explicitly set
/// to the empty string -- `std::env::var(name).ok()` alone only captures
/// "unset" (`None`); an operator setting `CONTAINER_PROXY=`,
/// `DOCKER_PROXY_URL=`, or any other knob to an empty string would
/// otherwise survive as `Some("")` and be treated as a real, present
/// value by every function below, diverging from bash for that entire
/// class of input (e.g. an empty `CONTAINER_PROXY` would fail the
/// `!= DEFAULT_PROXY` mismatch check and exit fatally, where bash would
/// silently fall back to the default). Applied at the entry point of
/// every public function in this module that takes a raw `Option<&str>`.
/// Public (not just used internally) so `main.rs`'s own direct env reads
/// for `DOCKER_PROXY_URL`/`STATUS_FILE`/`CACHE_DIR` (which don't route
/// through any function in this module) share the exact same "empty ==
/// unset" logic rather than a second, hand-duplicated copy that could
/// silently drift from this one.
pub fn non_empty(raw: Option<&str>) -> Option<&str> {
    raw.filter(|v| !v.is_empty())
}

/// Canonical truthy-parsing contract shared with the Admin UI's
/// `env_bool()` (`services/ui/src/config.rs`) and watchdog.sh's own
/// `is_truthy()`. Recognizes `1`/`true`/`yes`/`on` as truthy,
/// case-insensitively and after trimming surrounding whitespace -- anything
/// else (including `0`/`false`/`no`/`off`, empty, or unrecognized garbage)
/// is not-truthy. Callers combine this with their own default for the
/// "unset" case, same as `env_bool()`'s `unwrap_or(default)`.
///
/// watchdog.sh defines this same function twice (lines 65 and 169 of the
/// current bash file) with identical bodies -- a leftover duplicate, not two
/// diverging behaviors -- so this single definition is not a behavior
/// change, just the duplicate removed.
pub fn is_truthy(raw: &str) -> bool {
    matches!(
        raw.trim().to_ascii_lowercase().as_str(),
        "1" | "true" | "yes" | "on"
    )
}

/// Resolves a boolean-style env var using [`is_truthy`], falling back to
/// `default` when unset. Mirrors the Admin UI's `env_bool(name, default)`.
pub fn resolve_bool(raw: Option<&str>, default: bool) -> bool {
    match non_empty(raw) {
        Some(v) => is_truthy(v),
        None => default,
    }
}

/// Parses a `u64` env var, using `default` for anything that is not a
/// plain non-negative decimal integer (empty, missing, negative, or
/// non-digit garbage) -- the same `case ''|*[!0-9]*)` idiom watchdog.sh
/// already applies to `CHECK_INTERVAL`/`CACHE_VALID_DAYS`/
/// `SYSLOG_RETENTION_DAYS`/`SYSLOG_MAX_GB`. Returns the resolved value plus
/// an optional warning message the caller should log (mirroring the bash's
/// own `log "Invalid ...; using default ..."` lines), so config parsing
/// stays pure/testable while the caller decides how/whether to surface it.
///
/// Extended here to `RESTART_AFTER`/`DISK_WARN_PCT`/`DISK_ALARM_PCT` too:
/// the current bash does NOT validate these at all (they flow straight into
/// a `set -e` numeric comparison), so a garbage value there crashes the
/// whole daemon today rather than falling back to a sane default. That
/// crash is an accidental bug, not a documented behavior worth preserving
/// -- applying the file's own already-established clamp idiom uniformly is
/// a deliberate, narrow hardening (Rule-Ref: AG-WF-011: same failure class, same
/// fix), not a new invented behavior shape. `CURL_MAX_TIME`/
/// `CURL_MAX_TIME_RESTART` deliberately do NOT go through this digit-only
/// integer guard -- curl (and the bash's own verbatim `curl --max-time`
/// forwarding) accepts fractional seconds for those two knobs, which this
/// guard's all-digits check would wrongly reject; see
/// [`parse_curl_timeout`]'s own doc comment.
pub fn parse_u64_with_default(
    raw: Option<&str>,
    field_name: &str,
    default: u64,
) -> (u64, Option<String>) {
    let Some(raw) = non_empty(raw) else {
        return (default, None);
    };
    if !raw.bytes().all(|b| b.is_ascii_digit()) {
        return (
            default,
            Some(format!(
                "Invalid {field_name}={raw}; using default {default}"
            )),
        );
    }
    match raw.parse::<u64>() {
        Ok(v) => (v, None),
        // All-digits but too large for u64 (e.g. an accidental extra zero
        // run) -- same overflow-guard reasoning as watchdog.sh's
        // SYSLOG_MAX_GB/FLUENT_BIT_SELFLOG_MAX_MB ceilings, just expressed
        // as "does not fit at all" rather than a magnitude ceiling, since
        // none of these five knobs has a documented upper bound of its own
        // to clamp to instead.
        Err(_) => (
            default,
            Some(format!(
                "Invalid {field_name}={raw} (out of range); using default {default}"
            )),
        ),
    }
}

/// Applies a minimum-value floor to a value [`parse_u64_with_default`]
/// already validated as a real, all-digit operator input (as opposed to a
/// value that fell back to `default` for being invalid). Returns `Some`
/// with the *raw* operator-supplied string when flooring occurred, `None`
/// otherwise. Deliberately returns the raw string, not the already-parsed
/// `value`: a leading-zero input like `"00"` parses to the same `0` as a
/// literal `"0"`, but only the raw string preserves what the operator
/// actually wrote in the log message the caller builds from this --
/// watchdog.sh's own `log "...${RAW_VAR}..."` lines always interpolate the
/// literal env var value, never a value bash itself has already massaged.
/// An earlier version of this crate's floor logic used the parsed integer
/// directly, which meant `CHECK_INTERVAL=00` and `CHECK_INTERVAL=0` would
/// have produced an identical, misleading `CHECK_INTERVAL=0` log line --
/// losing exactly the information an operator would need to find what they
/// actually set. A unit test covering only the literal `"0"` case would not
/// catch this -- it needs a separate case for a leading-zero variant like
/// `"00"`.
fn floor_u64_raw(value: u64, floor: u64, raw: Option<&str>) -> (u64, Option<&str>) {
    if value < floor {
        (floor, Some(raw.filter(|s| !s.is_empty()).unwrap_or("0")))
    } else {
        (value, None)
    }
}

/// `CHECK_INTERVAL` gets an additional floor of 1s beyond the generic
/// digit-only guard above -- watchdog.sh floors a literal `0` to `1`
/// because `sleep 0` would turn the main loop into a busy-loop hammering
/// docker-socket-proxy every iteration, never a sane operator intent.
/// Returns the resolved interval plus any warning(s) to log, in the same
/// order watchdog.sh itself would produce them (invalid-value warning
/// first, then the separate below-minimum warning if the digit-guard
/// result is still `0`).
pub fn parse_check_interval(raw: Option<&str>) -> (Duration, Vec<String>) {
    let (value, warning) = parse_u64_with_default(raw, "CHECK_INTERVAL", 30);
    let mut warnings: Vec<String> = warning.into_iter().collect();
    let (value, floored_raw) = floor_u64_raw(value, 1, raw);
    if let Some(raw_display) = floored_raw {
        warnings.push(format!(
            "CHECK_INTERVAL={raw_display} is below the supported minimum (1s); using 1"
        ));
    }
    (Duration::from_secs(value), warnings)
}

/// Resolves a `CURL_MAX_TIME`-style knob (`CURL_MAX_TIME`/
/// `CURL_MAX_TIME_RESTART`) into curl's own timeout semantics: curl
/// documents `--max-time 0`/`CURLOPT_TIMEOUT` set to `0` as "no timeout at
/// all," not "time out immediately" -- the literal opposite of what
/// naively handing `Duration::from_secs(0)` to reqwest's `.timeout()`
/// would produce (an instant timeout on every single request). Returns
/// `None` for "no timeout"; every caller (`docker_client`'s `bounded()`/
/// `apply_timeout()`) must skip its own timeout machinery entirely in that
/// case rather than ever passing a zero-duration timeout through as a
/// stand-in for "unbounded."
///
/// Parses as a floating-point number of seconds, not [`parse_u64_with_default`]'s
/// all-digits integer guard: curl's own `--max-time`/`CURLOPT_TIMEOUT`
/// documents fractional values (e.g. `0.5`) as valid, and the bash
/// implementation forwards `CURL_MAX_TIME`/`CURL_MAX_TIME_RESTART` straight
/// through to `curl --max-time "$CURL_MAX_TIME"` verbatim with no
/// validation of its own. An existing install relying on a fractional
/// value (e.g. `CURL_MAX_TIME=0.5`) would otherwise silently fall back to
/// this crate's whole-second default after the Rust switch -- an integer
/// digit-only guard would reject the decimal point as "invalid" input,
/// changing real, already-configured timeout behavior rather than
/// preserving it.
pub fn parse_curl_timeout(
    raw: Option<&str>,
    field_name: &str,
    default_secs: u64,
) -> (Option<Duration>, Vec<String>) {
    let default = Some(Duration::from_secs(default_secs));
    let Some(raw_str) = non_empty(raw) else {
        return (default, Vec::new());
    };
    match raw_str.parse::<f64>() {
        // An explicit zero (curl's own "no timeout at all" semantics) is
        // valid input, not a warning-worthy fallback.
        Ok(0.0) => (None, Vec::new()),
        Ok(secs) if secs.is_finite() && secs > 0.0 => match Duration::try_from_secs_f64(secs) {
            Ok(duration) => (Some(duration), Vec::new()),
            // Finite but too large to fit in a Duration -- an operator
            // typo (an extra digit or two), not a real timeout intent.
            // Same out-of-range fallback shape parse_u64_with_default uses
            // for its own overflow case.
            Err(_) => (
                default,
                vec![format!(
                    "Invalid {field_name}={raw_str} (out of range); using default {default_secs}"
                )],
            ),
        },
        // Negative, NaN, infinite, or not parseable as a number at all --
        // curl itself rejects a negative --max-time, and none of these has
        // a sane timeout interpretation.
        _ => (
            default,
            vec![format!(
                "Invalid {field_name}={raw_str}; using default {default_secs}"
            )],
        ),
    }
}

/// Like [`parse_u64_with_default`], but for knobs this crate stores as
/// `u32` (`RESTART_AFTER`'s threshold, compared directly against a `u32`
/// `health::FailureCounter`; the two disk-percentage thresholds). A
/// blind `as u32` cast on the resulting `u64` would silently truncate
/// modulo 2^32 instead of rejecting an out-of-range value: an operator
/// setting `RESTART_AFTER=4294967296` (exactly one past `u32::MAX`) is a
/// typo, not an intentional "wrap to zero," but `as u32` would produce
/// exactly `0`, defeating the minimum-one floor this same knob's caller
/// applies right below and restarting the monitored container on *every*
/// unhealthy reading -- the identical zero-debounce failure that floor
/// exists to prevent, reached through a different door. A value that
/// parses cleanly as `u64` but does not fit in `u32` is treated the same
/// as any other out-of-range input: fall back to `default`, with a
/// warning naming the value so an operator can see what was rejected.
pub fn parse_u32_with_default(
    raw: Option<&str>,
    field_name: &str,
    default: u32,
) -> (u32, Vec<String>) {
    let (value, warning) = parse_u64_with_default(raw, field_name, u64::from(default));
    let mut warnings: Vec<String> = warning.into_iter().collect();
    match u32::try_from(value) {
        Ok(v) => (v, warnings),
        Err(_) => {
            warnings.push(format!(
                "{field_name}={value} exceeds the supported maximum ({}); using default {default}",
                u32::MAX
            ));
            (default, warnings)
        }
    }
}

/// `RESTART_AFTER` gets the same treatment: watchdog.sh's bash never
/// validates this knob at all (`[ "$_fcount" -ge "$RESTART_AFTER" ]` under
/// `set -e` either crashes on non-numeric input or, for a literal `0`,
/// restarts the monitored container on *every single* unhealthy reading
/// with no debounce whatsoever -- strictly more destructive than
/// `CHECK_INTERVAL=0`'s busy-loop, and the same "never a sane operator
/// intent" reasoning this crate already applies to `CHECK_INTERVAL`/
/// `SYSLOG_MAX_GB`/`FLUENT_BIT_SELFLOG_MAX_MB`'s floors. Floored to 1
/// (restart on the very first unhealthy reading -- still a real,
/// documented, if aggressive, configuration; just never zero rapid-fire
/// restarts with no debounce at all).
pub fn parse_restart_after(raw: Option<&str>) -> (u32, Vec<String>) {
    let (value, mut warnings) = parse_u32_with_default(raw, "RESTART_AFTER", 3);
    // Floor stays in u32 space here: `value` is already a validated u32
    // (parse_u32_with_default rejected anything that wouldn't fit), so
    // there is no risk of the truncation this function's own doc comment
    // warns against -- unlike parse_check_interval's Duration-based floor,
    // this one never needs to round-trip through u64/floor_u64_raw at all.
    if value < 1 {
        let raw_display = non_empty(raw).unwrap_or("0");
        warnings.push(format!(
            "RESTART_AFTER={raw_display} is below the supported minimum (1); using 1"
        ));
        return (1, warnings);
    }
    (value, warnings)
}

/// The four Docker container names watchdog's health checks/restarts
/// operate on, resolved from `CONTAINER_*` env vars against their fixed
/// defaults. `dns_ssl` is `None` when SSL mode is off, matching
/// watchdog.sh's `C_DNS_SSL=""` (and `status.json`'s corresponding key
/// being omitted entirely -- see `status::WatchdogStatus`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContainerNames {
    pub proxy: String,
    pub dns_standard: String,
    pub dns_ssl: Option<String>,
    pub nats: String,
    /// `docker-socket-proxy`'s own container name. Unlike the four fields
    /// above, this is NOT sourced from a `CONTAINER_*` env var override --
    /// see watchdog.sh's `C_DOCKER_PROXY` comment for why: it is never
    /// used to build a `/containers/<name>/...` Docker-API path (the probe
    /// hits `DOCKER_PROXY_URL`'s own `/_ping` directly), so it is not and
    /// must not be validated against docker-socket-proxy.sh's allowlist
    /// the way the other four are.
    pub docker_socket_proxy: &'static str,
}

/// `scripts/docker-socket-proxy.sh`'s HAProxy allowlist hardcodes these
/// exact container names (as does every compose file's `container_name:`
/// and the Admin UI's `docker_client.rs`) -- nothing in the stack actually
/// reads `CONTAINER_PROXY`/`CONTAINER_DNS_STANDARD`/`CONTAINER_DNS_SSL`/
/// `CONTAINER_NATS` to rename anything end-to-end. Honoring a mismatched
/// value would only make health checks silently return "unreachable" and
/// restarts silently 403 through the proxy. Returns `Err` with the exact
/// same fail-loud diagnostic watchdog.sh's `log_err "FATAL: ..."` lines
/// produce, for the first mismatch found, in the same check order the bash
/// uses (proxy, dns-standard, dns-ssl if enabled, nats).
///
/// `container_suffix` mirrors `watchdog.sh`'s `LANCACHE_CONTAINER_SUFFIX`
/// (issue #1415): each `DEFAULT_*` below is compared against the operator
/// override with this same suffix appended, not the bare literal, so a
/// CI-only quickstart-compose run that gave every one of this project's
/// containers a shared, coordinated suffix is still recognized as
/// consistent. This is NOT a relaxation of the single-stack-per-host
/// design (#849 finding #5): `container_suffix` is empty for every real
/// install (nothing sets `LANCACHE_CONTAINER_SUFFIX` outside CI), which
/// makes this function's behavior byte-identical to before this parameter
/// existed, and any override that doesn't carry the exact suffix this
/// process itself was given still hits the `Err` path below. NOTE: this
/// Rust path is not yet watchdog's live entrypoint (`watchdog.sh` still
/// is, per its own Dockerfile `ENTRYPOINT`) -- kept in lockstep here only
/// so the eventual bash-to-Rust cutover does not silently regress this
/// guard.
pub fn resolve_container_names(
    proxy_override: Option<&str>,
    dns_standard_override: Option<&str>,
    dns_ssl_override: Option<&str>,
    nats_override: Option<&str>,
    ssl_enabled: bool,
    container_suffix: Option<&str>,
) -> Result<ContainerNames, String> {
    // Deliberately mirrors watchdog.sh's own two-variable split exactly:
    // an ABSENT override falls back to the bare, unsuffixed literal (this
    // process has no way to know a suffix belongs in its own fallback --
    // the real compose wiring always passes CONTAINER_* explicitly instead
    // of relying on this fallback whenever a suffix is active), while the
    // comparison target is the suffixed "expected" value. Collapsing these
    // into one suffixed default (as an earlier version of this function
    // did) would silently accept an absent override as "correct" even
    // when LANCACHE_CONTAINER_SUFFIX was set but CONTAINER_PROXY was not
    // -- exactly the half-wired-caller mistake this guard exists to catch
    // (caught by resolve_container_names_rejects_mismatched_suffix below).
    const DEFAULT_PROXY: &str = "lancache-proxy";
    const DEFAULT_DNS_STANDARD: &str = "lancache-dns-standard";
    const DEFAULT_DNS_SSL: &str = "lancache-dns-ssl";
    const DEFAULT_NATS: &str = "lancache-nats";
    let container_suffix = non_empty(container_suffix).unwrap_or("");
    let expected_proxy = format!("{DEFAULT_PROXY}{container_suffix}");
    let expected_dns_standard = format!("{DEFAULT_DNS_STANDARD}{container_suffix}");
    let expected_dns_ssl = format!("{DEFAULT_DNS_SSL}{container_suffix}");
    let expected_nats = format!("{DEFAULT_NATS}{container_suffix}");

    // Empty overrides (e.g. CONTAINER_PROXY= set but blank) must resolve
    // to the bare default, not be compared against it as a literal empty
    // string -- see non_empty()'s own doc comment for why an empty env
    // value is not the same thing as "operator explicitly renamed this."
    let proxy_override = non_empty(proxy_override);
    let dns_standard_override = non_empty(dns_standard_override);
    let dns_ssl_override = non_empty(dns_ssl_override);
    let nats_override = non_empty(nats_override);

    let proxy = proxy_override.unwrap_or(DEFAULT_PROXY).to_string();
    if proxy != expected_proxy {
        return Err(format!(
            "FATAL: CONTAINER_PROXY={proxy} is not supported (expected '{expected_proxy}'). scripts/docker-socket-proxy.sh's allowlist only permits the fixed container name '{expected_proxy}'; renaming this container is not wired through the socket-proxy allowlist or the Admin UI, so it cannot work end-to-end yet. Revert CONTAINER_PROXY to the default."
        ));
    }

    let dns_standard = dns_standard_override
        .unwrap_or(DEFAULT_DNS_STANDARD)
        .to_string();
    if dns_standard != expected_dns_standard {
        return Err(format!(
            "FATAL: CONTAINER_DNS_STANDARD={dns_standard} is not supported (expected '{expected_dns_standard}'). scripts/docker-socket-proxy.sh's allowlist only permits the fixed container name '{expected_dns_standard}'; renaming this container is not wired through the socket-proxy allowlist or the Admin UI, so it cannot work end-to-end yet. Revert CONTAINER_DNS_STANDARD to the default."
        ));
    }

    let dns_ssl = if ssl_enabled {
        let dns_ssl = dns_ssl_override.unwrap_or(DEFAULT_DNS_SSL).to_string();
        if dns_ssl != expected_dns_ssl {
            return Err(format!(
                "FATAL: CONTAINER_DNS_SSL={dns_ssl} is not supported (expected '{expected_dns_ssl}'). scripts/docker-socket-proxy.sh's allowlist only permits the fixed container name '{expected_dns_ssl}'; renaming this container is not wired through the socket-proxy allowlist or the Admin UI, so it cannot work end-to-end yet. Revert CONTAINER_DNS_SSL to the default."
            ));
        }
        Some(dns_ssl)
    } else {
        None
    };

    let nats = nats_override.unwrap_or(DEFAULT_NATS).to_string();
    if nats != expected_nats {
        return Err(format!(
            "FATAL: CONTAINER_NATS={nats} is not supported (expected '{expected_nats}'). scripts/docker-socket-proxy.sh's allowlist only permits the fixed container name '{expected_nats}'; renaming this container is not wired through the socket-proxy allowlist or the Admin UI, so it cannot work end-to-end yet. Revert CONTAINER_NATS to the default."
        ));
    }

    Ok(ContainerNames {
        proxy,
        dns_standard,
        dns_ssl,
        nats,
        docker_socket_proxy: "lancache-docker-socket-proxy",
    })
}

/// watchdog.sh's `resolve_cache_dir()`: `CACHE_DIR` wins outright if set;
/// otherwise an older installation may still have the pre-`CACHE_DIR`
/// split `CACHE_DIR_STANDARD`/`CACHE_DIR_SSL` pair set instead. Those two
/// existing only to disagree is fail-closed (an ambiguous "which
/// filesystem is actually the cache" is worse than crashing loudly), a
/// single one of the pair is honored on its own, and the historical
/// `/var/cache/lancache` default applies only once none of the three are
/// set. Returning `Result` rather than silently picking a default mirrors
/// the bash's own `exit 1` on the conflicting-values case -- the caller
/// (`main.rs`) is expected to log the message and exit nonzero exactly
/// like `resolve_container_names`'s fatal-mismatch path.
pub fn resolve_cache_dir(
    cache_dir: Option<&str>,
    cache_dir_standard: Option<&str>,
    cache_dir_ssl: Option<&str>,
) -> Result<String, String> {
    const DEFAULT_CACHE_DIR: &str = "/var/cache/lancache";

    let cache_dir = non_empty(cache_dir);
    let cache_dir_standard = non_empty(cache_dir_standard);
    let cache_dir_ssl = non_empty(cache_dir_ssl);

    if let Some(cache_dir) = cache_dir {
        return Ok(cache_dir.to_string());
    }

    if let (Some(std), Some(ssl)) = (cache_dir_standard, cache_dir_ssl)
        && std != ssl
    {
        return Err(format!(
            "FATAL: CACHE_DIR_STANDARD={std} and CACHE_DIR_SSL={ssl} point to different paths without CACHE_DIR. Set CACHE_DIR to one shared cache directory."
        ));
    }

    if let Some(std) = cache_dir_standard {
        return Ok(std.to_string());
    }

    if let Some(ssl) = cache_dir_ssl {
        return Ok(ssl.to_string());
    }

    Ok(DEFAULT_CACHE_DIR.to_string())
}

/// Fixed container names for issue #842's alert-only services (`ui`,
/// `dhcp`, `dhcp-proxy`, `netdata`, `syslog`), plus `ntp` (issue #1296).
/// Deliberately NOT sourced from a `CONTAINER_*` env var override, unlike
/// `ContainerNames`'s four restart-capable fields above -- same reasoning
/// as `ContainerNames::docker_socket_proxy`: none of these are ever
/// restarted (see `main.rs`'s alert-only loop), so there is no
/// `resolve_container_names`-style
/// fatal-mismatch check to apply, and no compose file, the Admin UI's
/// `docker_client.rs`, or `scripts/docker-socket-proxy.sh`'s allowlist
/// support renaming any of them either.
///
/// UPDATED (syslog+fluent-bit consolidation PR, 2026-08, merged concurrently
/// with issue #842/#849 introducing this list): `syslog` (fluent-bit) and
/// `syslog-ng` used to be two separate containers, each with its own fixed
/// name here (`CONTAINER_SYSLOG`, `CONTAINER_SYSLOG_NG`). They are now ONE
/// combined container under `CONTAINER_SYSLOG` alone -- the
/// `CONTAINER_SYSLOG_NG` constant ("lancache-syslog-ng") was removed rather
/// than kept as unused dead code, since no compose file will ever start a
/// container by that name again; keeping it would misleadingly imply
/// syslog-ng is still independently monitorable.
pub const CONTAINER_UI: &str = "lancache-ui";
pub const CONTAINER_NETDATA: &str = "lancache-netdata";
pub const CONTAINER_DHCP: &str = "lancache-dhcp";
pub const CONTAINER_DHCP_PROXY: &str = "lancache-dhcp-proxy";
pub const CONTAINER_SYSLOG: &str = "lancache-syslog";
/// Added for issue #1296: `ntp` was never alert-only monitored at all
/// before this (a real, pre-existing gap this project's own issue #842
/// named -- "watchdog only monitors proxy/dns-standard/dns-ssl"), which
/// meant its new `HealthReading::Degraded` amber dashboard state (see
/// `health.rs`) had no caller that would ever actually query it. Alert-
/// only (never restarted), same as `dhcp`/`dhcp-proxy`/`syslog` above: a
/// genuinely crashed `ntp` container is still worth a dashboard alert, but
/// this project's restart-capable set (`proxy`/`dns-standard`/`dns-ssl`/
/// `nats`) is reserved for services whose own restart is a safe, useful
/// recovery action watchdog already knows how to take -- `ntp` has no
/// established need for that today, and adding it as alert-only closes
/// the real monitoring gap without expanding the restart-capable set's
/// own, separately-reviewed scope.
pub const CONTAINER_NTP: &str = "lancache-ntp";

/// Resolves which (if any) DHCP container should be alert-only-monitored,
/// mirroring `setup.sh`'s own `DHCP_MODE` semantics (see that script's
/// `compose_profiles_for_runtime` and its `is_valid_dhcp_mode` enumeration):
/// `"kea"` activates the `dhcp` Compose profile/container (Kea), while
/// `"dnsmasq-proxy"` and `"dnsmasq-relay"` both activate the `dhcp-proxy`
/// Compose profile/container (dnsmasq, in either ProxyDHCP-only or full
/// relay mode -- issue #844) -- the two DHCP_MODE values never activate both
/// containers at once, so at most one of `dhcp`/`dhcp-proxy` is ever
/// monitored. `"disabled"` (the documented default) and any unrecognized
/// value both resolve to `None`: an unrecognized `DHCP_MODE` is exactly the
/// kind of already-fail-closed-elsewhere condition (`setup.sh` itself
/// rejects it before ever writing `.env`) this function should not guess
/// past -- alert-only monitoring for a container that was never actually
/// provisioned would just manufacture a permanent, misleading "unreachable"
/// alarm out of a service that was never supposed to be running (the same
/// failure mode `ContainerNames::dns_ssl`'s `SSL_ENABLED=0` -> `None`
/// omission already avoids for the restart-capable services).
pub fn dhcp_alert_container(dhcp_mode: &str) -> Option<&'static str> {
    match dhcp_mode {
        "kea" => Some(CONTAINER_DHCP),
        "dnsmasq-proxy" | "dnsmasq-relay" => Some(CONTAINER_DHCP_PROXY),
        _ => None,
    }
}

/// One entry in the data-driven service table the main loop iterates over
/// -- this is the typed per-service definition (health-check kind,
/// restart policy, startup grace period) the maintainer's own rewrite
/// brief asked for, replacing watchdog.sh's four individually-named
/// `C_PROXY`/`C_DNS_STD`/`C_DNS_SSL`/`C_NATS` variables and its
/// hand-written `if`/sequence of `check_and_maybe_restart` calls.
#[derive(Debug, Clone)]
pub struct MonitoredService {
    /// Real Docker container name -- also the `status.json` key and the
    /// name used in log lines, matching watchdog.sh exactly (it never had
    /// a separate stable "service key" distinct from the container name).
    pub container_name: String,
    /// Consecutive unhealthy readings before a restart is triggered. Every
    /// service currently shares watchdog.sh's single `RESTART_AFTER` knob
    /// (no per-service override exists in the bash), but this field being
    /// per-entry rather than a single global is what makes a future
    /// per-service override possible without a struct/loop rewrite.
    pub restart_after: u32,
    /// Structure-only today: watchdog.sh has no real startup-grace-period
    /// timer (see this crate's `lib.rs` module doc comment and
    /// `health::HealthReading`'s own doc comment for why `starting` is
    /// today's only implicit grace signal). Always `None` until a real
    /// timer is implemented; wiring one in is future work, not part of
    /// this 1:1 rewrite.
    pub grace_period: Option<Duration>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    // Pins the exact truthy/falsy contract shared with the Admin UI's
    // env_bool() -- a regression here would silently disagree with the
    // dashboard about whether SSL mode or a boolean knob is "on".
    fn is_truthy_matches_documented_contract() {
        for v in [
            "1", "true", "TRUE", "True", "yes", "YES", "on", " on ", "\ttrue\n",
        ] {
            assert!(is_truthy(v), "expected {v:?} to be truthy");
        }
        for v in ["0", "false", "no", "off", "", "garbage", "2", "onn"] {
            assert!(!is_truthy(v), "expected {v:?} to be falsy");
        }
    }

    #[test]
    // Verifies both directions of the default fallback: an unset var uses
    // whichever default the caller passed (true or false), and a present,
    // real value always wins over that default regardless of which way it
    // points.
    fn resolve_bool_falls_back_to_default_when_unset() {
        assert!(resolve_bool(None, true));
        assert!(!resolve_bool(None, false));
        assert!(!resolve_bool(Some("false"), true));
        assert!(resolve_bool(Some("yes"), false));
    }

    #[test]
    // An explicitly empty value (e.g. SSL_ENABLED= set but blank) must be
    // treated exactly like "unset," matching bash's `${VAR:-default}`
    // (the colon form triggers on empty OR unset). Guards against
    // Some("") reaching is_truthy("") directly, which returns false, so an
    // empty SSL_ENABLED would otherwise silently turn SSL mode off instead
    // of falling back to its documented default (true).
    fn resolve_bool_treats_empty_value_as_unset() {
        assert!(resolve_bool(Some(""), true));
        assert!(!resolve_bool(Some(""), false));
    }

    #[test]
    // CHECK_INTERVAL's digit-only guard: unset keeps the default, and any
    // non-digit garbage (including a leading '-') falls back rather than
    // reaching a numeric comparison with an invalid operand. An empty
    // value is deliberately distinguished from garbage below: both fall
    // back to the same default, but only garbage produces a warning.
    fn parse_u64_with_default_rejects_non_digit_input() {
        assert_eq!(parse_u64_with_default(None, "X", 30).0, 30);
        assert_eq!(parse_u64_with_default(Some(""), "X", 30).0, 30);
        assert_eq!(parse_u64_with_default(Some("abc"), "X", 30).0, 30);
        assert_eq!(parse_u64_with_default(Some("-5"), "X", 30).0, 30);
        assert_eq!(parse_u64_with_default(Some("12"), "X", 30).0, 12);
        // A warning is produced only on the fallback path, never on a
        // clean value -- callers rely on `None` to mean "nothing to log".
        assert!(parse_u64_with_default(Some("12"), "X", 30).1.is_none());
        assert!(parse_u64_with_default(Some("abc"), "X", 30).1.is_some());
        // An empty value is treated as "unset," not "invalid" -- bash's
        // `${VAR:-default}` never logs a warning for an empty variable
        // either, only for a value that is present but not a plain
        // integer, so a silent fallback here is the correct parity, not
        // a missed diagnostic.
        assert!(parse_u64_with_default(Some(""), "X", 30).1.is_none());
    }

    #[test]
    // RESTART_AFTER=4294967296 (one past u32::MAX) parses cleanly as u64
    // but does not fit in the u32 this crate stores the threshold as -- a
    // blind `as u32` cast would wrap it to exactly 0, and combined with
    // the floor below (which only ever sees an already-validated u32),
    // that would silently restart the monitored container on every single
    // unhealthy reading. Confirms the checked conversion rejects it and
    // falls back to the caller's default instead of truncating.
    fn parse_u32_with_default_rejects_values_that_overflow_u32() {
        let (value, warnings) = parse_u32_with_default(Some("4294967296"), "RESTART_AFTER", 3);
        assert_eq!(value, 3);
        assert!(
            warnings
                .iter()
                .any(|w| w.contains("RESTART_AFTER=4294967296")),
            "warning must name the rejected out-of-range value, got: {warnings:?}"
        );

        // A value that fits exactly at the boundary must still be honored.
        let (value, warnings) = parse_u32_with_default(Some("4294967295"), "RESTART_AFTER", 3);
        assert_eq!(value, u32::MAX);
        assert!(warnings.is_empty());
    }

    #[test]
    // A literal 0 must floor to 1s (never a busy-loop), and a valid value
    // above the floor must pass through unchanged with no warning at all.
    fn parse_check_interval_floors_zero_to_one_second() {
        let (interval, warnings) = parse_check_interval(Some("0"));
        assert_eq!(interval, Duration::from_secs(1));
        assert!(!warnings.is_empty());

        let (interval, warnings) = parse_check_interval(Some("45"));
        assert_eq!(interval, Duration::from_secs(45));
        assert!(warnings.is_empty());

        let (interval, _) = parse_check_interval(Some("bogus"));
        assert_eq!(interval, Duration::from_secs(30));
    }

    #[test]
    // Distinct from the test above (which only exercises the literal "0"
    // case): the floor warning must name the RAW operator-supplied value,
    // not the post-parse integer --
    // "00" and "0" both parse to 0, but only the raw string tells an
    // operator which one they actually set, matching watchdog.sh's own
    // log lines (always interpolate the literal env var value).
    fn parse_check_interval_floor_warning_preserves_raw_leading_zero_value() {
        let (interval, warnings) = parse_check_interval(Some("00"));
        assert_eq!(interval, Duration::from_secs(1));
        assert!(
            warnings.iter().any(|w| w.contains("CHECK_INTERVAL=00")),
            "warning must name the raw '00' value, got: {warnings:?}"
        );
    }

    #[test]
    // CURL_MAX_TIME=0/CURL_MAX_TIME_RESTART=0 means "no timeout" in curl's
    // own documented semantics -- must resolve to None, never to
    // Some(Duration::ZERO) (which would make reqwest time out almost
    // instantly, the opposite of the operator's intent).
    fn parse_curl_timeout_treats_zero_as_no_timeout() {
        let (timeout, warnings) = parse_curl_timeout(Some("0"), "CURL_MAX_TIME", 5);
        assert_eq!(timeout, None);
        assert!(
            warnings.is_empty(),
            "an explicit 0 is valid input, not a warning-worthy one"
        );

        let (timeout, _) = parse_curl_timeout(Some("10"), "CURL_MAX_TIME", 5);
        assert_eq!(timeout, Some(Duration::from_secs(10)));

        // Unset keeps the documented default, wrapped as Some(..).
        let (timeout, _) = parse_curl_timeout(None, "CURL_MAX_TIME", 5);
        assert_eq!(timeout, Some(Duration::from_secs(5)));
    }

    #[test]
    // curl's own --max-time accepts fractional seconds, and the bash
    // implementation forwards CURL_MAX_TIME/CURL_MAX_TIME_RESTART to curl
    // verbatim with no validation -- an existing install relying on a
    // fractional value like 0.5 must still resolve to a sub-second
    // Duration after the Rust switch, not silently fall back to the
    // whole-second default the way an all-digits integer guard would.
    fn parse_curl_timeout_preserves_fractional_seconds() {
        let (timeout, warnings) = parse_curl_timeout(Some("0.5"), "CURL_MAX_TIME", 5);
        assert_eq!(timeout, Some(Duration::from_secs_f64(0.5)));
        assert!(warnings.is_empty());

        let (timeout, warnings) = parse_curl_timeout(Some("2.5"), "CURL_MAX_TIME_RESTART", 30);
        assert_eq!(timeout, Some(Duration::from_secs_f64(2.5)));
        assert!(warnings.is_empty());
    }

    #[test]
    // A negative, non-numeric, or absurdly-oversized value must fall back
    // to the caller's default with a warning naming the rejected value --
    // curl itself rejects a negative --max-time, and none of these has a
    // sane timeout interpretation.
    fn parse_curl_timeout_rejects_invalid_input() {
        let (timeout, warnings) = parse_curl_timeout(Some("bogus"), "CURL_MAX_TIME", 5);
        assert_eq!(timeout, Some(Duration::from_secs(5)));
        assert!(warnings.iter().any(|w| w.contains("CURL_MAX_TIME=bogus")));

        let (timeout, warnings) = parse_curl_timeout(Some("-1.5"), "CURL_MAX_TIME", 5);
        assert_eq!(timeout, Some(Duration::from_secs(5)));
        assert!(warnings.iter().any(|w| w.contains("CURL_MAX_TIME=-1.5")));
    }

    #[test]
    // RESTART_AFTER=0 would otherwise restart the monitored container on
    // every single unhealthy reading with no debounce at all -- floored to
    // 1, matching this crate's own established reasoning for CHECK_INTERVAL's
    // zero-floor (a busy-loop/restart-loop is never a sane operator intent).
    fn parse_restart_after_floors_zero_to_one() {
        let (restart_after, warnings) = parse_restart_after(Some("0"));
        assert_eq!(restart_after, 1);
        assert!(warnings.iter().any(|w| w.contains("RESTART_AFTER=0")));

        let (restart_after, warnings) = parse_restart_after(Some("00"));
        assert_eq!(restart_after, 1);
        assert!(
            warnings.iter().any(|w| w.contains("RESTART_AFTER=00")),
            "warning must name the raw '00' value, got: {warnings:?}"
        );

        let (restart_after, warnings) = parse_restart_after(Some("5"));
        assert_eq!(restart_after, 5);
        assert!(warnings.is_empty());

        // Unset keeps the documented default (matches watchdog.sh's
        // RESTART_AFTER="${RESTART_AFTER:-3}").
        let (restart_after, _) = parse_restart_after(None);
        assert_eq!(restart_after, 3);
    }

    #[test]
    // Baseline: with every CONTAINER_* override unset, every resolved name
    // must be the project's fixed default, including the docker-socket-proxy
    // constant that has no override at all (see ContainerNames's own field
    // doc comment for why it's deliberately not sourced from an env var).
    fn resolve_container_names_defaults_when_unset() {
        let names = resolve_container_names(None, None, None, None, true, None).unwrap();
        assert_eq!(names.proxy, "lancache-proxy");
        assert_eq!(names.dns_standard, "lancache-dns-standard");
        assert_eq!(names.dns_ssl.as_deref(), Some("lancache-dns-ssl"));
        assert_eq!(names.nats, "lancache-nats");
        assert_eq!(names.docker_socket_proxy, "lancache-docker-socket-proxy");
    }

    #[test]
    // An explicitly empty override (e.g. CONTAINER_PROXY= set but blank)
    // must resolve to the default, not be compared against it as a real
    // rename attempt. Guards against Some("") reaching the `!=
    // DEFAULT_PROXY` mismatch check directly and failing it (an empty
    // string is never equal to "lancache-proxy"), which would make an
    // accidentally blank env value a fatal startup error instead of the
    // no-op bash's `${CONTAINER_PROXY:-lancache-proxy}` would produce.
    fn resolve_container_names_treats_empty_overrides_as_unset() {
        let names =
            resolve_container_names(Some(""), Some(""), Some(""), Some(""), true, None).unwrap();
        assert_eq!(names.proxy, "lancache-proxy");
        assert_eq!(names.dns_standard, "lancache-dns-standard");
        assert_eq!(names.dns_ssl.as_deref(), Some("lancache-dns-ssl"));
        assert_eq!(names.nats, "lancache-nats");
    }

    #[test]
    // SSL_ENABLED=0 must omit dns_ssl entirely (None), matching
    // status.json's own omission of the dns-ssl key when SSL mode is off.
    fn resolve_container_names_omits_dns_ssl_when_disabled() {
        let names = resolve_container_names(None, None, None, None, false, None).unwrap();
        assert_eq!(names.dns_ssl, None);
        // An override is not even validated when SSL is off, matching the
        // bash's `if [ "$SSL_ENABLED" = "1" ] && [ "$C_DNS_SSL" != ... ]`
        // short-circuit -- a mismatched override on a disabled service must
        // not fail closed for a service that isn't running at all.
        let names =
            resolve_container_names(None, None, Some("renamed"), None, false, None).unwrap();
        assert_eq!(names.dns_ssl, None);
    }

    #[test]
    // Any renamed override on an active check is a fatal, fail-closed
    // error -- the socket-proxy allowlist cannot honor it end-to-end, so
    // silently accepting it would just make health checks and restarts
    // silently fail instead of erroring loudly at startup.
    fn resolve_container_names_rejects_renamed_containers() {
        assert!(resolve_container_names(Some("renamed"), None, None, None, true, None).is_err());
        assert!(resolve_container_names(None, Some("renamed"), None, None, true, None).is_err());
        assert!(resolve_container_names(None, None, Some("renamed"), None, true, None).is_err());
        assert!(resolve_container_names(None, None, None, Some("renamed"), true, None).is_err());
    }

    #[test]
    // Issue #1415: a coordinated LANCACHE_CONTAINER_SUFFIX, with every
    // CONTAINER_* override carrying that same suffix, must resolve
    // successfully to the suffixed names -- not FATAL as an unrelated
    // rename would. Mirrors watchdog.sh's own bats coverage for the same
    // scenario.
    fn resolve_container_names_accepts_coordinated_suffix() {
        let names = resolve_container_names(
            Some("lancache-proxyci7x9q"),
            Some("lancache-dns-standardci7x9q"),
            Some("lancache-dns-sslci7x9q"),
            Some("lancache-natsci7x9q"),
            true,
            Some("ci7x9q"),
        )
        .unwrap();
        assert_eq!(names.proxy, "lancache-proxyci7x9q");
        assert_eq!(names.dns_standard, "lancache-dns-standardci7x9q");
        assert_eq!(names.dns_ssl.as_deref(), Some("lancache-dns-sslci7x9q"));
        assert_eq!(names.nats, "lancache-natsci7x9q");
    }

    #[test]
    // The suffix must not become a general escape hatch: a suffix set
    // without the matching CONTAINER_* override (or vice versa) is exactly
    // the "renamed one container, not the whole coordinated set" case
    // finding #5's guard exists to catch, and must still FATAL.
    fn resolve_container_names_rejects_mismatched_suffix() {
        // Suffix set, but CONTAINER_PROXY left at the bare (unsuffixed) default.
        assert!(resolve_container_names(None, None, None, None, true, Some("ci7x9q")).is_err());
        // CONTAINER_PROXY carries a suffix, but LANCACHE_CONTAINER_SUFFIX was
        // never set (the mirror-image mistake).
        assert!(
            resolve_container_names(Some("lancache-proxyci7x9q"), None, None, None, true, None)
                .is_err()
        );
    }

    #[test]
    // Pins DHCP_MODE's three-way mapping (issue #842): "kea" monitors the
    // Kea container, either dnsmasq mode monitors dhcp-proxy instead, and
    // "disabled" (or anything unrecognized) monitors neither -- mirroring
    // setup.sh's own is_valid_dhcp_mode()/compose_profiles_for_runtime()
    // semantics rather than inventing a separate contract for watchdog.
    fn dhcp_alert_container_maps_each_mode_correctly() {
        assert_eq!(dhcp_alert_container("kea"), Some(CONTAINER_DHCP));
        assert_eq!(
            dhcp_alert_container("dnsmasq-proxy"),
            Some(CONTAINER_DHCP_PROXY)
        );
        assert_eq!(
            dhcp_alert_container("dnsmasq-relay"),
            Some(CONTAINER_DHCP_PROXY)
        );
        assert_eq!(dhcp_alert_container("disabled"), None);
        // An unrecognized value must fail closed to "not monitored", not
        // guess at either container -- setup.sh itself already rejects an
        // invalid DHCP_MODE before it can reach a running install, so this
        // is a defense-in-depth default, not the primary validation path.
        assert_eq!(dhcp_alert_container("bogus"), None);
        assert_eq!(dhcp_alert_container(""), None);
    }

    #[test]
    // CACHE_DIR wins outright over the legacy split pair, matching
    // resolve_cache_dir()'s first branch in the bash.
    fn resolve_cache_dir_prefers_cache_dir_when_set() {
        let dir =
            resolve_cache_dir(Some("/mnt/cache"), Some("/mnt/std"), Some("/mnt/ssl")).unwrap();
        assert_eq!(dir, "/mnt/cache");
    }

    #[test]
    // With CACHE_DIR unset, an older installation's CACHE_DIR_STANDARD/
    // CACHE_DIR_SSL pair must still be honored -- reading only CACHE_DIR
    // and silently defaulting to /var/cache/lancache would report disk
    // usage for the wrong filesystem on any install still using the
    // pre-CACHE_DIR split variables.
    fn resolve_cache_dir_falls_back_to_legacy_split_vars() {
        assert_eq!(
            resolve_cache_dir(None, Some("/mnt/legacy"), None).unwrap(),
            "/mnt/legacy"
        );
        assert_eq!(
            resolve_cache_dir(None, None, Some("/mnt/legacy-ssl")).unwrap(),
            "/mnt/legacy-ssl"
        );
        // Both set but agreeing is fine, not a conflict.
        assert_eq!(
            resolve_cache_dir(None, Some("/mnt/same"), Some("/mnt/same")).unwrap(),
            "/mnt/same"
        );
    }

    #[test]
    // Conflicting legacy values with no CACHE_DIR to arbitrate is
    // fail-closed, matching the bash's own `exit 1` -- an ambiguous "which
    // filesystem is the real cache" must never be silently guessed at.
    fn resolve_cache_dir_rejects_conflicting_legacy_values() {
        let err = resolve_cache_dir(None, Some("/mnt/std"), Some("/mnt/ssl")).unwrap_err();
        assert!(err.contains("/mnt/std"));
        assert!(err.contains("/mnt/ssl"));
    }

    #[test]
    // Nothing set at all falls back to the historical default, and empty
    // env values (e.g. CACHE_DIR= set but blank) are treated as unset, not
    // as a real value -- consistent with every other setting in this
    // module.
    fn resolve_cache_dir_defaults_when_all_unset() {
        assert_eq!(
            resolve_cache_dir(None, None, None).unwrap(),
            "/var/cache/lancache"
        );
        assert_eq!(
            resolve_cache_dir(Some(""), Some(""), Some("")).unwrap(),
            "/var/cache/lancache"
        );
    }
}
