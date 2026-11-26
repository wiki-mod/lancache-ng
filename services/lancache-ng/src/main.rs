//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later

// BINDING MAINTAINER DECISION [AG-WF-029]
//
// This Rust source file MUST be restricted exclusively to its
// designated functional responsibility.
//
// Functionality outside its designated responsibility MUST NOT
// be implemented in this file. Shared functionality MUST be
// implemented in the designated shared Rust source file.
//
// This notice is mandatory and MUST be retained verbatim.
//
// Any modification, rewording, shortening, relocation, or removal
// of this notice is explicitly DISACK.

// What: entry of the all-in-one; the role picks the code.
// Why: one binary runs every role and command of the stack.
// From: Issue #1683
mod cachehamster;
mod config;
mod dhcp;
mod dns;
mod shared;
mod ui;
mod watchdog;

#[tokio::main]
async fn main() -> std::process::ExitCode {
    // What: lancache-<role> as program name picks the role.
    // Why: old callers run lancache-ui/-dns/... unchanged.
    // From: Issue #1683 | PR #2020
    let exe = std::env::args().next().unwrap_or_default();
    let exe = std::path::Path::new(&exe)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("");
    let mut argv: Vec<String> = std::env::args().skip(1).collect();
    let role: String = match exe.strip_prefix("lancache-") {
        Some(r) if r != "ng" => r.into(),
        _ if !argv.is_empty() => argv.remove(0),
        _ => String::new(),
    };
    match role.as_str() {
        "ui" => code(ui::run(&argv).await),
        "watchdog" => code(watchdog::run(&argv).await),
        "dns" => code(dns::run(&argv).await),
        "cachehamster" => cachehamster::run(&argv).await,
        other => {
            eprintln!(
                "lancache-ng: unknown role {other:?}; use {}",
                ROLES.join("|")
            );
            std::process::ExitCode::from(2)
        }
    }
}

// What: the roles; argv0 lancache-<role> picks one too.
// Why: the help names the same set as the match.
// From: Issue #1683 | PR #2020
const ROLES: [&str; 4] = ["ui", "watchdog", "dns", "cachehamster"];

// What: turn a role Result into a process exit code.
// Why: roles return Result; cachehamster its own code.
// From: Issue #1683
fn code(r: Result<(), String>) -> std::process::ExitCode {
    match r {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            std::process::ExitCode::FAILURE
        }
    }
}
