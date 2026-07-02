//! NATS configuration validation and escaping helpers.
//!
//! This module provides validation and escaping functions for NATS usernames and passwords
//! to prevent configuration syntax errors when interpolating values into the NATS config file.

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
    // Empty usernames are not allowed
    if username.is_empty() {
        return Err("NATS username cannot be empty".to_string());
    }

    // Check for control characters (ASCII < 32 and DEL=127)
    if username.chars().any(|c| (c as u32) < 32 || c as u32 == 127) {
        return Err("NATS username contains control characters".to_string());
    }

    // Check for quotes and newlines (though control char check above catches newlines)
    if username.contains('"') || username.contains('\'') {
        return Err("NATS username contains quotes".to_string());
    }

    // Restrict to safe character set: [A-Za-z0-9_.-]
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
/// - Quotes (single and double)
/// - Newlines and other whitespace control characters
///
/// Passwords are typically generated as random hex or base64 by setup.sh, so they're usually safe.
/// This validation is defense-in-depth to catch environment-provided values.
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
/// assert!(validate_nats_password("pass\nword").is_err());
/// ```
pub fn validate_nats_password(password: &str) -> Result<(), String> {
    // Empty passwords are not allowed
    if password.is_empty() {
        return Err("NATS password cannot be empty".to_string());
    }

    // Check for control characters (ASCII < 32 and DEL=127)
    if password.chars().any(|c| (c as u32) < 32 || c as u32 == 127) {
        return Err("NATS password contains control characters".to_string());
    }

    // Check for quotes that would break the config syntax
    if password.contains('"') || password.contains('\'') {
        return Err("NATS password contains quotes".to_string());
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
    fn password_with_single_quotes_rejected() {
        assert!(validate_nats_password("pass'word").is_err());
        assert!(validate_nats_password("'password'").is_err());
    }

    #[test]
    fn password_with_newlines_rejected() {
        assert!(validate_nats_password("pass\nword").is_err());
        assert!(validate_nats_password("pass\r\nword").is_err());
    }

    #[test]
    fn password_with_control_characters_rejected() {
        assert!(validate_nats_password("pass\x00word").is_err());
        assert!(validate_nats_password("pass\x1fword").is_err());
        assert!(validate_nats_password("pass\x7fword").is_err()); // DEL character
    }

    // ─── Combined Credentials Tests ───

    #[test]
    fn valid_credentials_pass_together() {
        assert!(validate_nats_credentials("valid-user", "valid-password").is_ok());
    }

    #[test]
    fn invalid_username_fails_combined() {
        assert!(validate_nats_credentials("invalid user", "valid-password").is_err());
    }

    #[test]
    fn invalid_password_fails_combined() {
        assert!(validate_nats_credentials("valid-user", "invalid\"value").is_err());
    }

    #[test]
    fn both_invalid_fails_on_username() {
        let result = validate_nats_credentials("invalid user", "invalid\"value");
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
}
