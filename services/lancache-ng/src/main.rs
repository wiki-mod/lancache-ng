// This must be removed when done, this is a reminder to align with ag-law-001 and specially with ag-code-011
//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later

// What: entry of the all-in-one; first arg picks the role.
// Why: one binary runs every role and command of the stack.
// From: Issue #1683
mod cachehamster;
mod config;
mod dns;
mod shared;
mod ui;
mod watchdog;

#[tokio::main]
async fn main() -> std::process::ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let (role, rest) = match argv.split_first() {
        Some((r, rest)) => (r.as_str(), rest.to_vec()),
        None => ("", Vec::new()),
    };
    match role {
        "ui" => code(ui::run(&rest).await),
        "watchdog" => code(watchdog::run(&rest).await),
        "dns" => code(dns::run(&rest).await),
        "cachehamster" => cachehamster::run(&rest).await,
        other => {
            eprintln!("lancache-ng: unknown role {other:?}; use ui|watchdog|dns|cachehamster");
            std::process::ExitCode::from(2)
        }
    }
}

// What: turn a role Result into a process exit code.
// Why: three roles return Result, cachehamster its own code.
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
