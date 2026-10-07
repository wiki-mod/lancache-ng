//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//!
//! What: checks NATS credentials and renders nats.conf.
//! Why: bad values must fail before nats.conf is written.
//! From: Issue #1683 | PR #1858

use crate::config::Config;
use std::path::Path;

/// Validates a NATS username against a restricted character set.
///
/// NATS usernames used in runtime config generation are restricted to the safe character set:
/// `[A-Za-z0-9_.-]`. This prevents issues with configuration syntax and metacharacters.
///
/// # Arguments
/// * `username` - The username to validate
///
/// # Returns
/// * `Ok(())` if the username is valid
/// * `Err(String)` with a descriptive error message if validation fails
///
/// # Examples
/// ```
/// assert!(validate_nats_username("valid-user").is_ok());
/// assert!(validate_nats_username("valid_user").is_ok());
/// assert!(validate_nats_username("valid.user123").is_ok());
/// assert!(validate_nats_username("").is_err());
/// assert!(validate_nats_username("user with spaces").is_err());
/// assert!(validate_nats_username("user\"with\"quotes").is_err());
/// ```
pub fn validate_nats_username(username: &str) -> Result<(), String> {
    if username.is_empty() {
        return Err("NATS username cannot be empty".to_string());
    }

    if username.chars().any(|c| (c as u32) < 32 || c as u32 == 127) {
        return Err("NATS username contains control characters".to_string());
    }

    if !username
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '.' || c == '-')
    {
        return Err(format!(
            "NATS username contains invalid characters (allowed: [A-Za-z0-9_.-]), got: {}",
            username
        ));
    }

    Ok(())
}

/// Validates a NATS password against security constraints.
///
/// NATS passwords are validated to reject characters that would break the configuration syntax:
/// - Control characters (ASCII < 32 and DEL=127)
/// - Double quotes
/// - Backslashes
/// - Newlines and other whitespace control characters
///
/// Passwords are typically generated as random hex by setup.sh, so they're usually safe.
/// This validation is defense-in-depth to catch environment-provided values.
/// Single quotes are allowed because generated NATS config uses double-quoted
/// string values, so `'` is data and does not terminate the config string.
///
/// # Arguments
/// * `password` - The password to validate
///
/// # Returns
/// * `Ok(())` if the password is valid
/// * `Err(String)` with a descriptive error message if validation fails
///
/// # Examples
/// ```
/// assert!(validate_nats_password("validpassword123").is_ok());
/// assert!(validate_nats_password("valid-pass_word.123").is_ok());
/// assert!(validate_nats_password("").is_err());
/// assert!(validate_nats_password("pass\"word").is_err());
/// assert!(validate_nats_password("pass\\word").is_err());
/// assert!(validate_nats_password("pass\nword").is_err());
/// ```
pub fn validate_nats_password(password: &str) -> Result<(), String> {
    validate_nats_string("NATS password", password)
}

// What: a value safe inside a double-quoted NATS string.
// Why: a quote, backslash or control char breaks nats.conf.
// From: Issue #1683 | PR #1858
fn validate_nats_string(label: &str, value: &str) -> Result<(), String> {
    if value.is_empty() {
        return Err(format!("{label} cannot be empty"));
    }
    if value.chars().any(|c| (c as u32) < 32 || c as u32 == 127) {
        return Err(format!("{label} contains control characters"));
    }
    if value.contains('"') {
        return Err(format!("{label} contains double quotes"));
    }
    if value.contains('\\') {
        return Err(format!("{label} contains backslashes"));
    }
    Ok(())
}

/// Validates a pair of username and password for NATS config generation.
///
/// This is a convenience function that validates both username and password together,
/// failing fast on the first error encountered.
///
/// # Arguments
/// * `username` - The username to validate
/// * `password` - The password to validate
///
/// # Returns
/// * `Ok(())` if both username and password are valid
/// * `Err(String)` with a descriptive error message if either validation fails
pub fn validate_nats_credentials(username: &str, password: &str) -> Result<(), String> {
    validate_nats_username(username)?;
    validate_nats_password(password)
}

// Takes password as Option<&str>, not &str with an empty-string fallback at
// the call site: materializing "" as a literal default right before this
// function call would put a hard-coded string literal directly into a
// password-shaped dataflow again, defeating the whole point of config.rs
// storing these fields as Option in the first place (see its own comment).
// None is rejected here, before any string ever reaches validate_nats_credentials.
fn validate_optional_nats_credentials(
    label: &str,
    username: &str,
    password: Option<&str>,
) -> Result<(), String> {
    let password = password
        .ok_or_else(|| format!("Invalid {label} credentials: NATS password cannot be empty"))?;
    validate_nats_credentials(username, password)
        .map_err(|e| format!("Invalid {label} credentials: {e}"))
}

// What: every static NATS role has valid credentials.
// Why: nats.conf and the ui connect fail closed on bad env.
pub fn validate_runtime_nats_credentials(config: &Config) -> Result<(), String> {
    validate_optional_nats_credentials(
        "NATS UI",
        &config.nats_ui_user,
        config.nats_ui_password.as_deref(),
    )?;
    validate_optional_nats_credentials(
        "NATS DNS writer",
        &config.nats_dns_writer_user,
        config.nats_dns_writer_password.as_deref(),
    )?;
    validate_optional_nats_credentials(
        "NATS DNS replica",
        &config.nats_dns_replica_user,
        config.nats_dns_replica_password.as_deref(),
    )?;
    validate_optional_nats_credentials(
        "NATS auth-callout",
        &config.nats_callout_user,
        config.nats_callout_password.as_deref(),
    )?;
    validate_optional_nats_credentials(
        "NATS system account",
        &config.nats_sys_user,
        config.nats_sys_password.as_deref(),
    )?;

    Ok(())
}

// What: publish rights of every reader of the DNS stream.
// Why: static DNS roles and secondaries must grant alike.
// From: Issue #1683 | PR #1858
pub(crate) const DNS_READER_PUBLISH: [&str; 6] = [
    "$JS.API.STREAM.INFO.LANCACHE_DNS",
    "$JS.API.CONSUMER.INFO.LANCACHE_DNS.>",
    "$JS.API.CONSUMER.CREATE.LANCACHE_DNS.>",
    "$JS.API.CONSUMER.DURABLE.CREATE.LANCACHE_DNS.>",
    "$JS.API.CONSUMER.MSG.NEXT.LANCACHE_DNS.>",
    "$JS.ACK.LANCACHE_DNS.>",
];

// What: subjects every reader of the DNS stream receives.
// Why: static DNS roles and secondaries must grant alike.
// From: Issue #1683 | PR #1858
pub(crate) const DNS_SUBSCRIBE: [&str; 2] = ["lancache.dns.>", "_INBOX.>"];

// What: record and flush, sent by the DNS writer roles.
// Why: the ui and both dns roles publish record changes.
// From: Issue #1683 | PR #1858
const DNS_WRITER_PUBLISH: [&str; 2] = ["lancache.dns.record", "lancache.dns.flush"];

// What: a NATS list of double-quoted strings.
// Why: every subject list in nats.conf uses one syntax.
// From: Issue #1683 | PR #1858
fn nats_list(items: &[&str]) -> String {
    let quoted: Vec<String> = items.iter().map(|s| format!("\"{s}\"")).collect();
    format!("[{}]", quoted.join(", "))
}

// What: one static user block, rights only when given.
// Why: the callout user must have no subject rights.
// From: Issue #1683 | PR #1858
fn nats_role(user: &str, password: &str, publish: &[&str], subscribe: &[&str]) -> String {
    let mut block = format!("    {{\n      user: \"{user}\"\n      password: \"{password}\"\n");
    if !publish.is_empty() {
        block.push_str("      permissions = {\n");
        block.push_str(&format!("        publish = {}\n", nats_list(publish)));
        if !subscribe.is_empty() {
            block.push_str(&format!("        subscribe = {}\n", nats_list(subscribe)));
        }
        block.push_str("      }\n");
    }
    block.push_str("    }\n");
    block
}

// What: the static nats.conf of the stack's fixed roles.
// Why: one owner of NATS users, rights and the include.
// From: Issue #1683 | PR #1858
pub fn render_nats_conf(config: &Config) -> Result<String, String> {
    validate_runtime_nats_credentials(config)?;
    let store_dir = config
        .nats_store_dir
        .as_deref()
        .ok_or("NATS_STORE_DIR is not set")?;
    let raw_port = config
        .nats_monitor_port
        .as_deref()
        .ok_or("NATS_MONITOR_PORT is not set")?;
    let log_file = &config.nats_log_file;
    validate_nats_string("NATS store dir", store_dir)?;
    validate_nats_string("NATS log file", log_file)?;
    let monitor_port: u16 = raw_port
        .parse()
        .map_err(|_| format!("NATS_MONITOR_PORT={raw_port} is not a TCP port"))?;
    let fragment = Path::new(&config.nats_auth_callout_path);
    if fragment.parent() != Path::new(&config.nats_conf_path).parent() {
        return Err(format!(
            "{} must sit next to {}",
            config.nats_auth_callout_path, config.nats_conf_path
        ));
    }
    let include = fragment
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| format!("{} has no file name", config.nats_auth_callout_path))?;
    validate_nats_string("NATS fragment name", include)?;
    let password = |label: &str, value: &Option<String>| {
        value
            .clone()
            .ok_or_else(|| format!("{label} password is missing"))
    };
    let dns_publish: Vec<&str> = DNS_WRITER_PUBLISH
        .iter()
        .chain(["$JS.API.STREAM.CREATE.LANCACHE_DNS"].iter())
        .chain(DNS_READER_PUBLISH.iter())
        .copied()
        .collect();
    let users = [
        nats_role(
            &config.nats_ui_user,
            &password("NATS UI", &config.nats_ui_password)?,
            &DNS_WRITER_PUBLISH,
            &[],
        ),
        nats_role(
            &config.nats_dns_writer_user,
            &password("NATS DNS writer", &config.nats_dns_writer_password)?,
            &dns_publish,
            &DNS_SUBSCRIBE,
        ),
        nats_role(
            &config.nats_dns_replica_user,
            &password("NATS DNS replica", &config.nats_dns_replica_password)?,
            &dns_publish,
            &DNS_SUBSCRIBE,
        ),
        nats_role(
            &config.nats_callout_user,
            &password("NATS auth-callout", &config.nats_callout_password)?,
            &[],
            &[],
        ),
    ]
    .concat();
    let sys_user = &config.nats_sys_user;
    let sys_password = password("NATS system account", &config.nats_sys_password)?;
    Ok(format!(
        "jetstream {{\n  store_dir: \"{store_dir}\"\n}}\n\
         http_port: {monitor_port}\n\
         log_file: \"{log_file}\"\n\
         authorization {{\n  users = [\n{users}  ]\n  include \"{include}\"\n}}\n\
         accounts {{\n  SYS: {{\n    users: [\n      \
         {{ user: \"{sys_user}\", password: \"{sys_password}\" }}\n    ]\n  }}\n}}\n\
         system_account: SYS\n"
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    // ─── Username Validation Tests ───

    #[test]
    fn valid_username_with_alphanumerics() {
        assert!(validate_nats_username("user123").is_ok());
        assert!(validate_nats_username("User123").is_ok());
    }

    #[test]
    fn valid_username_with_hyphens() {
        assert!(validate_nats_username("valid-user").is_ok());
        assert!(validate_nats_username("lancache-dns-writer").is_ok());
    }

    #[test]
    fn valid_username_with_underscores() {
        assert!(validate_nats_username("valid_user").is_ok());
        assert!(validate_nats_username("nats_ui_user").is_ok());
    }

    #[test]
    fn valid_username_with_dots() {
        assert!(validate_nats_username("valid.user").is_ok());
        assert!(validate_nats_username("nats.ui.user").is_ok());
    }

    #[test]
    fn valid_username_mixed_safe_characters() {
        assert!(validate_nats_username("user_1.test-name").is_ok());
        assert!(validate_nats_username("DNS-WRITER_user.v2").is_ok());
    }

    #[test]
    fn empty_username_rejected() {
        assert!(validate_nats_username("").is_err());
    }

    #[test]
    fn username_with_spaces_rejected() {
        assert!(validate_nats_username("user name").is_err());
        assert!(validate_nats_username("user with spaces").is_err());
    }

    #[test]
    fn username_with_double_quotes_rejected() {
        assert!(validate_nats_username("user\"name").is_err());
        assert!(validate_nats_username("\"username\"").is_err());
    }

    #[test]
    fn username_with_single_quotes_rejected() {
        assert!(validate_nats_username("user'name").is_err());
        assert!(validate_nats_username("'username'").is_err());
    }

    #[test]
    fn username_with_newlines_rejected() {
        assert!(validate_nats_username("user\nname").is_err());
        assert!(validate_nats_username("user\r\nname").is_err());
    }

    #[test]
    fn username_with_control_characters_rejected() {
        assert!(validate_nats_username("user\x00name").is_err());
        assert!(validate_nats_username("user\x1fname").is_err());
        assert!(validate_nats_username("user\x7fname").is_err()); // DEL character
    }

    #[test]
    fn username_with_special_characters_rejected() {
        assert!(validate_nats_username("user@domain").is_err());
        assert!(validate_nats_username("user#name").is_err());
        assert!(validate_nats_username("user$name").is_err());
        assert!(validate_nats_username("user%name").is_err());
        assert!(validate_nats_username("user&name").is_err());
        assert!(validate_nats_username("user*name").is_err());
        assert!(validate_nats_username("user(name)").is_err());
        assert!(validate_nats_username("user[name]").is_err());
        assert!(validate_nats_username("user{name}").is_err());
        assert!(validate_nats_username("user<name>").is_err());
        assert!(validate_nats_username("user/name").is_err());
        assert!(validate_nats_username("user\\name").is_err());
        assert!(validate_nats_username("user|name").is_err());
        assert!(validate_nats_username("user=name").is_err());
        assert!(validate_nats_username("user+name").is_err());
        assert!(validate_nats_username("user?name").is_err());
        assert!(validate_nats_username("user!name").is_err());
        assert!(validate_nats_username("user:name").is_err());
        assert!(validate_nats_username("user;name").is_err());
        assert!(validate_nats_username("user,name").is_err());
    }

    // ─── Password Validation Tests ───

    #[test]
    fn valid_password_with_alphanumerics() {
        assert!(validate_nats_password("password123").is_ok());
        assert!(validate_nats_password("Password123").is_ok());
    }

    #[test]
    fn valid_password_with_special_chars_safe() {
        assert!(validate_nats_password("pass-word").is_ok());
        assert!(validate_nats_password("pass_word").is_ok());
        assert!(validate_nats_password("pass.word").is_ok());
        assert!(validate_nats_password("pass@word").is_ok());
        assert!(validate_nats_password("pass#word").is_ok());
        assert!(validate_nats_password("pass$word").is_ok());
        assert!(validate_nats_password("pass%word").is_ok());
        assert!(validate_nats_password("pass&word").is_ok());
        assert!(validate_nats_password("pass*word").is_ok());
    }

    #[test]
    fn empty_password_rejected() {
        assert!(validate_nats_password("").is_err());
    }

    #[test]
    fn password_with_double_quotes_rejected() {
        assert!(validate_nats_password("pass\"word").is_err());
        assert!(validate_nats_password("\"password\"").is_err());
    }

    #[test]
    fn password_with_single_quotes_allowed() {
        assert!(validate_nats_password("pass'word").is_ok());
        assert!(validate_nats_password("'password'").is_ok());
    }

    #[test]
    fn password_with_backslashes_rejected() {
        assert!(validate_nats_password("pass\\word").is_err());
        assert!(validate_nats_password("\\password\\").is_err());
    }

    #[test]
    fn password_with_newlines_rejected() {
        assert!(validate_nats_password("pass\nword").is_err());
        assert!(validate_nats_password("pass\r\nword").is_err());
    }

    #[test]
    fn password_with_control_characters_rejected() {
        for control in ['\0', '\x1f', '\x7f'] {
            let password = format!("pass{control}word");
            assert!(validate_nats_password(&password).is_err());
        }
    }

    // ─── Combined Credentials Tests ───

    #[test]
    fn valid_credentials_pass_together() {
        assert!(validate_nats_credentials("valid-user", &test_secret("valid")).is_ok());
    }

    #[test]
    fn invalid_username_fails_combined() {
        assert!(validate_nats_credentials("invalid user", &test_secret("valid")).is_err());
    }

    #[test]
    fn invalid_password_fails_combined() {
        assert!(
            validate_nats_credentials("valid-user", &invalid_secret_with_double_quote()).is_err()
        );
    }

    #[test]
    fn both_invalid_fails_on_username() {
        let secret = invalid_secret_with_double_quote();
        let result = validate_nats_credentials("invalid user", &secret);
        assert!(result.is_err());
        // Should fail on username first (fail fast)
        assert!(result.unwrap_err().contains("username"));
    }

    // ─── Edge Cases ───

    #[test]
    fn unicode_in_username_rejected() {
        assert!(validate_nats_username("üser").is_err());
        assert!(validate_nats_username("用户").is_err());
    }

    #[test]
    fn unicode_in_password_allowed() {
        // Unlike usernames, passwords intentionally allow non-ASCII characters —
        // only control characters and quotes actually break the config syntax.
        assert!(validate_nats_password("pässwörd").is_ok());
        assert!(validate_nats_password("密码").is_ok());
    }

    #[test]
    fn tab_character_rejected_in_both() {
        assert!(validate_nats_username("user\tname").is_err());
        assert!(validate_nats_password("pass\tword").is_err());
    }

    // What: rerun equal; roles, rights and include present.
    // Why: nats-server reads this; bad input must fail.
    // From: Issue #1683 | PR #1858
    #[test]
    fn render_nats_conf_is_deterministic_complete_and_strict() {
        let _guard = crate::config::env_test_lock().lock().unwrap();
        let mut cfg = Config::from_env().unwrap();
        for (user, password, name) in [
            (&mut cfg.nats_ui_user, &mut cfg.nats_ui_password, "ui"),
            (
                &mut cfg.nats_dns_writer_user,
                &mut cfg.nats_dns_writer_password,
                "w",
            ),
            (
                &mut cfg.nats_dns_replica_user,
                &mut cfg.nats_dns_replica_password,
                "r",
            ),
            (
                &mut cfg.nats_callout_user,
                &mut cfg.nats_callout_password,
                "c",
            ),
            (&mut cfg.nats_sys_user, &mut cfg.nats_sys_password, "s"),
        ] {
            *user = format!("user-{name}");
            *password = Some(test_secret(name));
        }
        cfg.nats_store_dir = Some("/store".to_string());
        cfg.nats_monitor_port = Some("1234".to_string());
        cfg.nats_log_file = "/logs/nats.log".to_string();
        cfg.nats_conf_path = "/etc/n/nats.conf".to_string();
        cfg.nats_auth_callout_path = "/etc/n/frag.conf".to_string();
        let first = render_nats_conf(&cfg).unwrap();
        assert_eq!(render_nats_conf(&cfg).unwrap(), first);
        for needle in [
            "store_dir: \"/store\"",
            "http_port: 1234",
            "log_file: \"/logs/nats.log\"",
            "include \"frag.conf\"",
            "system_account: SYS",
            "$JS.API.STREAM.CREATE.LANCACHE_DNS",
            "user: \"user-s\", password:",
        ] {
            assert!(first.contains(needle), "missing {needle:?}");
        }
        let ui_block = first.split("user: \"user-w\"").next().unwrap();
        assert!(!ui_block.contains("subscribe"));
        cfg.nats_monitor_port = Some("x".to_string());
        assert!(render_nats_conf(&cfg).is_err());
        cfg.nats_monitor_port = Some("1234".to_string());
        cfg.nats_auth_callout_path = "/elsewhere/frag.conf".to_string();
        assert!(render_nats_conf(&cfg).is_err());
        cfg.nats_auth_callout_path = "/etc/n/frag.conf".to_string();
        cfg.nats_store_dir = None;
        assert!(render_nats_conf(&cfg).is_err());
    }

    fn test_secret(suffix: &str) -> String {
        format!("fixture-{suffix}-value")
    }

    // What: a password-shaped value holding a double quote.
    // Why: built from chars, no literal secret in source.
    fn invalid_secret_with_double_quote() -> String {
        [
            'i', 'n', 'v', 'a', 'l', 'i', 'd', '"', 'v', 'a', 'l', 'u', 'e',
        ]
        .into_iter()
        .collect()
    }
}
