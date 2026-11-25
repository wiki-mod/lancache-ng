//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later

// What: dns helper: the recursors follow own zones.
// Why: a secondary has no ui to render after a change.
// From: Issue #1683

use lancache_ng::config::Settings;
use lancache_ng::dns::Role;
use lancache_ng::{apply, http, peer, render, secret, tool};
use std::collections::BTreeMap;
use std::time::Duration;

// What: the zones the own pdns pulls, with serials.
// Why: the primary sets them; the recursors follow.
// From: Issue #1683
async fn own_zones(s: &Settings) -> Result<BTreeMap<String, u32>, String> {
    let key = secret::get(s, "PDNS_API_KEY")?;
    let api = peer::own_api(s, http::client(s)?, &key)?;
    Ok(api
        .zones()
        .await?
        .into_iter()
        .filter(|z| z.kind == "Slave")
        .map(|z| (z.name, z.serial))
        .collect())
}

// What: dns configs for these zones; true if changed.
// Why: one renderer with the render one-shot.
// From: Issue #1683
fn write_for(s: &Settings, zones: &[String]) -> Result<bool, String> {
    let s = s.with("DNS_SECONDARY_ZONES", &zones.join(" "))?;
    let sec = render::secrets(&s)?;
    let files = render::dns_only(&s, &sec).map_err(|e| e.join("; "))?;
    Ok(!render::write_files(&s, &files)?.is_empty())
}

// What: the dns reload commands of the SOT, run here.
// Why: the recursors then read the new forward zones.
// From: Issue #1683
fn reload(s: &Settings) -> Result<(), String> {
    for cmd in apply::exec_cmds(&s.list("RELOAD_EXEC"), "dns") {
        let (program, args) = cmd.split_first().ok_or("empty reload command")?;
        tool::run(std::process::Command::new(program).args(args))?;
    }
    Ok(())
}

// What: what the recursors have taken over so far.
// Why: a step is noted only after it worked.
// From: Issue #1683
#[derive(Default)]
struct Done {
    // What: a written config not yet reloaded.
    // Why: a failed reload must be retried.
    // From: Issue #1683
    reload_due: bool,
    // What: the serial each zone was last flushed at.
    // Why: a failed flush is retried next round.
    // From: Issue #1683
    flushed: Option<BTreeMap<String, u32>>,
}

// What: one round towards the wanted state.
// Why: same input changes nothing; a failure retries.
// From: Issue #1683
async fn round(s: &Settings, done: &mut Done) -> Result<(), String> {
    let zones = own_zones(s).await?;
    let names: Vec<String> = zones.keys().cloned().collect();
    if write_for(s, &names)? {
        done.reload_due = true;
    }
    if done.reload_due {
        reload(s)?;
        done.reload_due = false;
        eprintln!("lancache-dns: recursors forward {} zones", names.len());
    }
    // What: at start the serials are taken as flushed.
    // Why: pdns NOTIFY already wipes a zone it pulls.
    // From: Issue #1683
    let flushed = done.flushed.get_or_insert_with(|| zones.clone());
    flushed.retain(|zone, _| zones.contains_key(zone));
    for (zone, serial) in &zones {
        if flushed.get(zone) == Some(serial) {
            continue;
        }
        match peer::flush_zone(s, zone).await {
            Ok(()) => {
                flushed.insert(zone.clone(), *serial);
            }
            Err(e) => eprintln!("lancache-dns: flush {zone}: {e}"),
        }
    }
    Ok(())
}

// What: idle on a primary, else rounds forever.
// Why: OpenRC keeps the process; the primary's ui renders.
// From: Issue #1683
#[tokio::main]
async fn main() -> Result<(), String> {
    let mut done = Done::default();
    loop {
        let s = Settings::from_process()?;
        let wait = Duration::from_secs(s.uint("DNS_FOLLOW_SECONDS")?);
        if Role::from_settings(&s)? == Role::Secondary
            && let Err(e) = round(&s, &mut done).await
        {
            eprintln!("lancache-dns: {e}");
        }
        tokio::time::sleep(wait).await;
    }
}
