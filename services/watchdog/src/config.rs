//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Environment parsing and validation, mirroring watchdog.sh's own startup
//! section (env var reads, `is_truthy`, the `CHECK_INTERVAL` digit-only
//! guard, and the `CONTAINER_*` fatal-mismatch checks). Every function here
//! is pure (takes an already-read `Option<&str>`/`&str`, never touches
//! `std::env` itself) so tests can exercise every input shape directly
//! without mutating real process environment variables.

use std::time::Duration;

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
    match raw {
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
/// Extended here to `RESTART_AFTER`/`CURL_MAX_TIME`/`CURL_MAX_TIME_RESTART`/
/// `DISK_WARN_PCT`/`DISK_ALARM_PCT` too: the current bash does NOT validate
/// these at all (they flow straight into `curl --max-time` or a `set -e`
/// numeric comparison), so a garbage value there crashes the whole daemon
/// today rather than falling back to a sane default. That crash is an
/// accidental bug, not a documented behavior worth preserving -- applying
/// the file's own already-established clamp idiom uniformly is a
/// deliberate, narrow hardening (AG-WF-011: same failure class, same fix),
/// not a new invented behavior shape.
pub fn parse_u64_with_default(
    raw: Option<&str>,
    field_name: &str,
    default: u64,
) -> (u64, Option<String>) {
    let Some(raw) = raw else {
        return (default, None);
    };
    if raw.is_empty() || !raw.bytes().all(|b| b.is_ascii_digit()) {
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
/// actually set. Caught in review before merging, not found by the unit
/// tests (which only exercised the literal `"0"` case).
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
    let (value, warning) = parse_u64_with_default(raw, "RESTART_AFTER", 3);
    let mut warnings: Vec<String> = warning.into_iter().collect();
    let (value, floored_raw) = floor_u64_raw(value, 1, raw);
    if let Some(raw_display) = floored_raw {
        warnings.push(format!(
            "RESTART_AFTER={raw_display} is below the supported minimum (1); using 1"
        ));
    }
    // RESTART_AFTER is used as a small threshold compared directly against
    // a u32 failure counter (see health::FailureCounter) -- truncating a
    // u64 this small is not a real-world concern (no caller ever sets a
    // restart threshold anywhere near u32::MAX), unlike the disk/interval
    // knobs above which stay u64/Duration throughout.
    (value as u32, warnings)
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
pub fn resolve_container_names(
    proxy_override: Option<&str>,
    dns_standard_override: Option<&str>,
    dns_ssl_override: Option<&str>,
    nats_override: Option<&str>,
    ssl_enabled: bool,
) -> Result<ContainerNames, String> {
    const DEFAULT_PROXY: &str = "lancache-proxy";
    const DEFAULT_DNS_STANDARD: &str = "lancache-dns-standard";
    const DEFAULT_DNS_SSL: &str = "lancache-dns-ssl";
    const DEFAULT_NATS: &str = "lancache-nats";

    let proxy = proxy_override.unwrap_or(DEFAULT_PROXY).to_string();
    if proxy != DEFAULT_PROXY {
        return Err(format!(
            "FATAL: CONTAINER_PROXY={proxy} is not supported. scripts/docker-socket-proxy.sh's allowlist only permits the fixed container name '{DEFAULT_PROXY}'; renaming this container is not wired through the socket-proxy allowlist or the Admin UI, so it cannot work end-to-end yet. Revert CONTAINER_PROXY to the default."
        ));
    }

    let dns_standard = dns_standard_override
        .unwrap_or(DEFAULT_DNS_STANDARD)
        .to_string();
    if dns_standard != DEFAULT_DNS_STANDARD {
        return Err(format!(
            "FATAL: CONTAINER_DNS_STANDARD={dns_standard} is not supported. scripts/docker-socket-proxy.sh's allowlist only permits the fixed container name '{DEFAULT_DNS_STANDARD}'; renaming this container is not wired through the socket-proxy allowlist or the Admin UI, so it cannot work end-to-end yet. Revert CONTAINER_DNS_STANDARD to the default."
        ));
    }

    let dns_ssl = if ssl_enabled {
        let dns_ssl = dns_ssl_override.unwrap_or(DEFAULT_DNS_SSL).to_string();
        if dns_ssl != DEFAULT_DNS_SSL {
            return Err(format!(
                "FATAL: CONTAINER_DNS_SSL={dns_ssl} is not supported. scripts/docker-socket-proxy.sh's allowlist only permits the fixed container name '{DEFAULT_DNS_SSL}'; renaming this container is not wired through the socket-proxy allowlist or the Admin UI, so it cannot work end-to-end yet. Revert CONTAINER_DNS_SSL to the default."
            ));
        }
        Some(dns_ssl)
    } else {
        None
    };

    let nats = nats_override.unwrap_or(DEFAULT_NATS).to_string();
    if nats != DEFAULT_NATS {
        return Err(format!(
            "FATAL: CONTAINER_NATS={nats} is not supported. scripts/docker-socket-proxy.sh's allowlist only permits the fixed container name '{DEFAULT_NATS}'; renaming this container is not wired through the socket-proxy allowlist or the Admin UI, so it cannot work end-to-end yet. Revert CONTAINER_NATS to the default."
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

/// One entry in the data-driven service table the main loop iterates over
/// -- this is the "typed per-service definition (health-check kind,
/// restart policy, startup grace period)" issue #842's maintainer follow-up
/// comment (2026-07-15) asked for, replacing watchdog.sh's four
/// individually-named `C_PROXY`/`C_DNS_STD`/`C_DNS_SSL`/`C_NATS` variables
/// and its hand-written `if`/sequence of `check_and_maybe_restart` calls.
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
    fn resolve_bool_falls_back_to_default_when_unset() {
        assert!(resolve_bool(None, true));
        assert!(!resolve_bool(None, false));
        assert!(!resolve_bool(Some("false"), true));
        assert!(resolve_bool(Some("yes"), false));
    }

    #[test]
    // CHECK_INTERVAL's digit-only guard: unset keeps the default, and any
    // non-digit garbage (including a leading '-') falls back rather than
    // reaching a numeric comparison with an invalid operand.
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
    // Regression pin for a bug caught in review (not by the test above,
    // which only exercised the literal "0" case): the floor warning must
    // name the RAW operator-supplied value, not the post-parse integer --
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
    fn resolve_container_names_defaults_when_unset() {
        let names = resolve_container_names(None, None, None, None, true).unwrap();
        assert_eq!(names.proxy, "lancache-proxy");
        assert_eq!(names.dns_standard, "lancache-dns-standard");
        assert_eq!(names.dns_ssl.as_deref(), Some("lancache-dns-ssl"));
        assert_eq!(names.nats, "lancache-nats");
        assert_eq!(names.docker_socket_proxy, "lancache-docker-socket-proxy");
    }

    #[test]
    // SSL_ENABLED=0 must omit dns_ssl entirely (None), matching
    // status.json's own omission of the dns-ssl key when SSL mode is off.
    fn resolve_container_names_omits_dns_ssl_when_disabled() {
        let names = resolve_container_names(None, None, None, None, false).unwrap();
        assert_eq!(names.dns_ssl, None);
        // An override is not even validated when SSL is off, matching the
        // bash's `if [ "$SSL_ENABLED" = "1" ] && [ "$C_DNS_SSL" != ... ]`
        // short-circuit -- a mismatched override on a disabled service must
        // not fail closed for a service that isn't running at all.
        let names = resolve_container_names(None, None, Some("renamed"), None, false).unwrap();
        assert_eq!(names.dns_ssl, None);
    }

    #[test]
    // Any renamed override on an active check is a fatal, fail-closed
    // error -- the socket-proxy allowlist cannot honor it end-to-end, so
    // silently accepting it would just make health checks and restarts
    // silently fail instead of erroring loudly at startup.
    fn resolve_container_names_rejects_renamed_containers() {
        assert!(resolve_container_names(Some("renamed"), None, None, None, true).is_err());
        assert!(resolve_container_names(None, Some("renamed"), None, None, true).is_err());
        assert!(resolve_container_names(None, None, Some("renamed"), None, true).is_err());
        assert!(resolve_container_names(None, None, None, Some("renamed"), true).is_err());
    }
}
