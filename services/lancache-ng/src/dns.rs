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

// What: DNS zones, records, secondaries and dns helper.
// Why: one home for DNS logic of ui and the dns role.
// From: Issue #1683 | PR #2020

use crate::config::{self, Settings, process_env};
use crate::shared::dns::Role;
use crate::shared::peer::{self, PeerZone, ZoneState};
use crate::shared::tool;
use crate::shared::{apply, fs, http, render, secret};
use crate::ui::*;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Arc;
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

// What: what is in place so far.
// Why: a step is noted only after it worked.
// From: Issue #1683
#[derive(Default)]
struct Done {
    // What: TSIG key, setup zones and key binding done.
    // Why: once per start; then the primary keeps zones.
    // From: Issue #1683
    seeded: bool,
    // What: a written config not yet reloaded.
    // Why: a failed reload must be retried.
    // From: Issue #1683
    reload_due: bool,
    // What: the serial each zone was last flushed at.
    // Why: a failed flush is retried next round.
    // From: Issue #1683
    flushed: peer::Flushed,
}

// What: TSIG key, setup zones without removal, binding.
// Why: the secondary pulls with its key from the start.
// From: Issue #1683
async fn seed(s: &Settings) -> Result<(), String> {
    let key = peer::ensure_tsigkey(s).await?;
    peer::ensure_secondary_zones(s, &key).await?;
    peer::ensure_tsig(s, &key).await
}

// What: one round towards the wanted state.
// Why: same input changes nothing; a failure retries.
// From: Issue #1683
async fn round(s: &Settings, done: &mut Done) -> Result<(), String> {
    // What: before pdns answers, the setup zone list.
    // Why: pdns and recursors start on the first write.
    // From: Issue #1683
    let live = own_zones(s).await;
    let names: Vec<String> = match &live {
        Ok(zones) => zones.keys().cloned().collect(),
        Err(_) => s.list("DNS_SECONDARY_ZONES"),
    };
    if write_for(s, &names)? {
        done.reload_due = true;
    }
    let zones = live?;
    if !done.seeded {
        seed(s).await?;
        done.seeded = true;
        eprintln!("lancache-dns: TSIG key and setup zones in place");
    }
    if done.reload_due {
        reload(s)?;
        done.reload_due = false;
        eprintln!("lancache-dns: recursors forward {} zones", names.len());
    }
    for (zone, serial) in done.flushed.due(&zones) {
        match peer::flush_zone(s, &zone).await {
            Ok(()) => done.flushed.done(&zone, serial),
            Err(e) => eprintln!("lancache-dns: flush {zone}: {e}"),
        }
    }
    Ok(())
}

// What: idle on a primary, else rounds forever.
// Why: OpenRC keeps the process; the primary's ui renders.
// From: Issue #1683
pub async fn run(_args: &[String]) -> Result<(), String> {
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

// What: remove zones a new LAN domain left behind.
// Why: an old zone would keep answering its names.
// From: Issue #1683 | PR #1980
pub(crate) async fn drop_old_zones(s: &Settings, before: &[String]) {
    let read = (hosted_now(s), Role::from_settings(s), pdns_api(s));
    let (now, role, api) = match read {
        (Ok(now), Ok(role), Ok(api)) => (now, role, api),
        (Err(e), _, _) | (_, Err(e), _) | (_, _, Err(e)) => {
            eprintln!("ui: old zones kept: {e}");
            return;
        }
    };
    if role == Role::Secondary {
        return;
    }
    for zone in before.iter().filter(|z| !now.contains(z)) {
        // What: only zones without own records go.
        // Why: a record the user added is never lost.
        // From: Issue #1683 | PR #1980
        let own = match api.rrsets(zone).await {
            Ok(sets) => !own_rrsets(&sets).is_empty(),
            Err(_) => continue,
        };
        let done = if own {
            Err(tr("err_zone_has_records"))
        } else {
            api.delete_zone(zone).await
        };
        match done {
            Ok(()) => eprintln!("ui: zone {zone} removed"),
            Err(e) => eprintln!("ui: zone {zone} kept: {e}"),
        }
    }
    peers_follow(s);
}

// What: PowerDNS API of this node.
// Why: records live only in PowerDNS.
// From: Issue #1683 | PR #1980
pub(crate) fn pdns_api(s: &Settings) -> Result<crate::shared::pdns::Api, String> {
    peer::own_api(s, http::client(s)?, &secret::get(s, "PDNS_API_KEY")?)
}

// What: reverse DNS name of an address.
// Why: PTR rows live in in-addr.arpa or ip6.arpa.
// From: Issue #1683 | PR #1980
pub(crate) fn reverse_name(ip: &str) -> Result<String, String> {
    use std::net::IpAddr;
    let addr = crate::shared::dns::parse_ip(ip)?;
    Ok(match addr {
        IpAddr::V4(v4) => {
            let mut o = v4.octets();
            o.reverse();
            format!("{}.{}.{}.{}.in-addr.arpa.", o[0], o[1], o[2], o[3])
        }
        IpAddr::V6(v6) => {
            let mut nibbles = Vec::with_capacity(32);
            for b in v6.octets().iter().rev() {
                nibbles.push(format!("{:x}", b & 0x0f));
                nibbles.push(format!("{:x}", b >> 4));
            }
            format!("{}.ip6.arpa.", nibbles.join("."))
        }
    })
}

// What: private reverse zone holding a name.
// Why: the PowerDNS PATCH needs the zone.
// From: Issue #1683 | PR #1980
pub(crate) fn reverse_zone(s: &Settings, name: &str) -> Option<String> {
    crate::shared::dns::zone_of(name, &crate::shared::dns::private_reverse_zones(s))
}

// What: reverse name of an address and its zone.
// Why: every PTR change needs both; None: no such zone.
// From: Issue #1683 | PR #2017
pub(crate) fn reverse_place(s: &Settings, ip: &str) -> Result<Option<(String, String)>, String> {
    let rev = reverse_name(ip)?;
    Ok(reverse_zone(s, &rev).map(|zone| (rev, zone)))
}

// What: the same, only for a zone this stack serves.
// Why: a PTR of a secondary goes into own zones only.
// From: Issue #1683 | PR #2017
pub(crate) fn served_reverse_place(
    s: &Settings,
    ip: &str,
) -> Result<Option<(String, String)>, String> {
    let Some((rev, zone)) = reverse_place(s, ip)? else {
        return Ok(None);
    };
    let served = crate::shared::dns::managed_zones(s)?.contains(&zone);
    Ok(served.then_some((rev, zone)))
}

// What: the LAN zone a form names; empty = main.
// Why: records go only into a configured LAN domain.
// From: Issue #1683
pub(crate) fn chosen_lan_zone(s: &Settings, raw: &str) -> Result<String, String> {
    if raw.trim().is_empty() {
        return crate::shared::dns::lan_zone(s);
    }
    let zone = crate::shared::dns::canonical_zone(raw.trim());
    if crate::shared::dns::lan_domains(s)?.contains(&zone) {
        Ok(zone)
    } else {
        Err(tr("err_not_lan_domain").replace("{x}", raw.trim()))
    }
}

// What: settings that make one domain the main one.
// Why: a former extra leaves the list; swap keeps both.
// From: Issue #1683
pub(crate) fn main_domain_fields(s: &Settings, main: &str) -> Result<Fields, String> {
    let lans = crate::shared::dns::lan_domains(s)?;
    let want = crate::shared::dns::canonical_zone(main.trim());
    let plain = |z: &String| z.trim_end_matches('.').to_string();
    let old = lans.first().cloned().unwrap_or_default();
    let mut extra: Vec<String> = lans
        .iter()
        .skip(1)
        .filter(|z| **z != want)
        .map(plain)
        .collect();
    // What: old main stays as extra only on a swap.
    // Why: a new name renames the main domain as before.
    // From: Issue #1683
    if want != old && lans.iter().skip(1).any(|z| *z == want) {
        extra.push(plain(&old));
    }
    // What: the new set passes the LAN domain rule.
    // Why: one rule; else lan_domains fails everywhere.
    // From: Issue #1683
    crate::shared::dns::validate_lan_domains(&plain(&want), &extra)?;
    Ok(Fields::from([
        ("DHCP_DOMAIN".to_string(), plain(&want)),
        ("DNS_EXTRA_LAN_DOMAINS".to_string(), extra.join(" ")),
    ]))
}

// What: rrsets of a zone besides SOA, NS and DS.
// Why: only these are records a person added.
// From: Issue #1683
pub(crate) fn own_rrsets(rows: &[Value]) -> Vec<Value> {
    rows.iter()
        .filter(|r| !matches!(r["type"].as_str(), Some("SOA" | "NS" | "DS")))
        .cloned()
        .collect()
}

// What: zones that keep snapshots.
// Why: LAN zones plus the private reverse zones.
// From: Issue #1683 | PR #1980
pub(crate) fn snapshot_zones(s: &Settings) -> Result<Vec<String>, String> {
    let mut zones = crate::shared::dns::lan_domains(s)?;
    zones.extend(crate::shared::dns::private_reverse_zones(s));
    Ok(zones)
}

// What: snapshot store of one zone.
// Why: undo a bad change; count from the SOT.
// From: Issue #1683 | PR #1980
pub(crate) fn zone_store(
    s: &Settings,
    zone: &str,
) -> Result<crate::shared::snapshot::Store, String> {
    let dir = Path::new(&s.text("DNS_SNAPSHOT_DIR")?).join(zone.trim_end_matches('.'));
    let keep = s.num::<usize>("DNS_SNAPSHOT_KEEP")?;
    let owner = fs::Owner::default();
    Ok(crate::shared::snapshot::Store {
        dir,
        keep,
        owner,
        file: None,
    })
}

// What: keep the zone's records after a change.
// Why: each change can be undone later.
// From: Issue #1683 | PR #1980
pub(crate) async fn snapshot(
    s: &Settings,
    api: &crate::shared::pdns::Api,
    zone: &str,
) -> Result<(), String> {
    let rows = api.rrsets(zone).await?;
    let body = serde_json::to_vec(&rows).map_err(|e| e.to_string())?;
    let store = zone_store(s, zone)?;
    store.save(&body)?;
    Ok(())
}

// What: snapshots of all zones, newest first.
// Why: DNS page and setup.sh show the same list.
// From: Issue #1683 | PR #1980
pub(crate) fn snapshot_list(s: &Settings) -> Result<Vec<(String, Vec<Value>)>, String> {
    let mut out = Vec::new();
    for zone in snapshot_zones(s)? {
        let store = zone_store(s, &zone)?;
        out.push((zone, snapshot_rows(&store)?));
    }
    Ok(out)
}

// What: print {"zones":{zone:[{id,created_unix}]}}.
// Why: setup.sh reset-config reads this shape.
// From: Issue #1683 | PR #1980
pub(crate) fn zone_snapshots_cli(s: &Settings) -> Result<(), String> {
    let zones: serde_json::Map<String, Value> = snapshot_list(s)?
        .into_iter()
        .map(|(z, rows)| (z, Value::Array(rows)))
        .collect();
    println!("{}", json!({"zones": zones}));
    Ok(())
}

// What: put one zone back to a snapshot.
// Why: PATCH restores; a new snapshot records it.
// From: Issue #1683 | PR #1980
pub(crate) async fn rollback(s: &Settings, zone: &str, id: &str) -> Result<(), String> {
    if !snapshot_zones(s)?.iter().any(|z| z == zone) {
        return Err(tr("err_zone_no_snapshots").replace("{zone}", zone));
    }
    let rows: Vec<Value> = zone_store(s, zone)?.read(id)?;
    let api = pdns_api(s)?;
    api.restore(zone, &rows).await?;
    snapshot(s, &api, zone).await?;
    peer::flush_zone(s, zone).await
}

// What: PTR rows of each private reverse zone.
// Why: the DNS page lists them per zone with the host.
// From: Issue #1683 | PR #1980
pub(crate) async fn ptr_rows(s: &Settings, api: &crate::shared::pdns::Api) -> Vec<Value> {
    let mut out = Vec::new();
    for zone in crate::shared::dns::private_reverse_zones(s) {
        let mut rows = Vec::new();
        for r in api.rrsets(&zone).await.unwrap_or_default() {
            if r["type"] != "PTR" {
                continue;
            }
            let host = r["records"][0]["content"].clone();
            rows.push(json!({"ip": r["name"], "ttl": r["ttl"], "hostname": host}));
        }
        out.push(json!({"zone": zone, "records": rows}));
    }
    out
}

// What: A and AAAA addresses whose PTR is missing.
// Why: one click adds it; DoMe 23.11.
// From: Issue #1683 | PR #2019
pub(crate) fn missing_ptrs(
    s: &Settings,
    records: &mut BTreeMap<String, Vec<Value>>,
    ptr: &[Value],
) -> Vec<Value> {
    let have: Vec<&str> = ptr
        .iter()
        .filter_map(|g| g["records"].as_array())
        .flatten()
        .filter_map(|r| r["ip"].as_str())
        .collect();
    let mut all = Vec::new();
    for rows in records.values_mut() {
        for r in rows.iter_mut() {
            if !matches!(r["type"].as_str(), Some("A" | "AAAA")) {
                continue;
            }
            let ips: Vec<String> = r["records"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|c| c["content"].as_str())
                .filter(|ip| {
                    matches!(served_reverse_place(s, ip), Ok(Some((rev, _)))
                        if !have.contains(&rev.as_str()))
                })
                .map(str::to_string)
                .collect();
            for ip in &ips {
                all.push(json!({"ip": ip, "hostname": r["name"], "ttl": r["ttl"]}));
            }
            r["missing_ptr"] = json!(ips);
        }
    }
    all
}

// What: add, remove or promote one LAN domain.
// Why: each LAN domain is one zone in PowerDNS.
// From: Issue #1683
pub(crate) async fn lan_domain_action(
    app: &App,
    s: &Settings,
    op: &str,
    raw: &str,
) -> Result<(), String> {
    let zone = crate::shared::dns::canonical_zone(raw.trim());
    let name = zone.trim_end_matches('.').to_string();
    let lans = crate::shared::dns::lan_domains(s)?;
    let before = hosted_now(s)?;
    let change = match op {
        "UI_ROUTE_LAN_DOMAIN_ADD" => {
            let mut extra: Vec<String> = lans.iter().skip(1).cloned().collect();
            extra.push(name.clone());
            let main = lans.first().cloned().unwrap_or_default();
            crate::shared::dns::validate_lan_domains(&main, &extra)?;
            list_change(s, "DNS_EXTRA_LAN_DOMAINS", &name, true)
        }
        "UI_ROUTE_LAN_DOMAIN_REMOVE" => {
            if lans.first() == Some(&zone) {
                return Err(tr("err_main_domain_remove").replace("{x}", &name));
            }
            if !lans.contains(&zone) {
                return Err(tr("err_not_lan_domain").replace("{x}", &name));
            }
            // What: a domain with own records stays.
            // Why: removing it would drop names from DNS.
            // From: Issue #1683
            let own = own_rrsets(&pdns_api(s)?.rrsets(&zone).await?).len();
            if own > 0 {
                return Err(tr("err_domain_has_records")
                    .replace("{x}", &name)
                    .replace("{n}", &own.to_string()));
            }
            list_change(s, "DNS_EXTRA_LAN_DOMAINS", &name, false)
        }
        _ => {
            if !lans.contains(&zone) {
                return Err(tr("err_not_lan_domain").replace("{x}", &name));
            }
            main_domain_fields(s, &name)?
        }
    };
    commit(app, change).await?;
    drop_old_zones(&app.settings(), &before).await;
    Ok(())
}

// What: full name inside the LAN zone.
// Why: a short name gets the zone appended.
// From: Issue #1683 | PR #1980
pub(crate) fn in_zone(name: &str, zone: &str) -> String {
    // What: only a whole-label suffix counts as inside.
    // Why: "xhome.lan" is not in zone "home.lan".
    // From: Issue #1683
    let bare = zone.trim_end_matches('.');
    let inside = crate::shared::dns::is_within(name, bare);
    if name.ends_with('.') || inside {
        name.to_string()
    } else {
        format!("{name}.{zone}")
    }
}

// What: content in the form PowerDNS stores.
// Why: TXT needs quotes; target names end in a dot.
// From: Issue #1683 | PR #1980
pub(crate) fn canonical(kind: &str, c: &str) -> String {
    let dot = crate::shared::pdns::zone_id;
    match kind {
        "TXT" if !c.starts_with('"') => format!("\"{}\"", c.replace('"', "\\\"")),
        "CNAME" => dot(c),
        "MX" | "SRV" => match c.rsplit_once(' ') {
            Some((head, target)) => format!("{head} {}", dot(target)),
            None => c.to_string(),
        },
        // What: a DS digest in small hex letters.
        // Why: pdns and its key list may differ in case.
        // From: Issue #1683 | PR #2019
        "DS" => c.to_ascii_lowercase(),
        _ => c.to_string(),
    }
}

// What: add or remove one LAN record set.
// Why: PATCH sets or deletes; NOTIFY follows.
// From: Issue #1683 | PR #1980
pub(crate) async fn record(
    s: &Settings,
    add: bool,
    get: &(dyn Fn(&str) -> String + Sync),
) -> Result<(), String> {
    let zone = chosen_lan_zone(s, &get("zone"))?;
    let kind = get("record_type");
    if !s.list("DNS_LAN_RECORD_TYPES").contains(&kind) {
        return Err(tr("err_record_type").replace("{kind}", &kind));
    }
    let name = in_zone(&get("name"), &zone);
    let mut contents = Vec::new();
    let mut ttl = 0;
    if add {
        let raw = get("content");
        contents = raw
            .split(';')
            .map(str::trim)
            .filter(|c| !c.is_empty())
            .map(|c| canonical(&kind, c))
            .collect();
        ttl = form_ttl(s, get)?;
    }
    let api = pdns_api(s)?;
    let host = crate::shared::pdns::zone_id(&name);
    // What: the place of each wanted PTR, checked first.
    // Why: no A is saved when its PTR cannot follow.
    // From: Issue #1683 | PR #2019
    let mut places = Vec::new();
    if add && kind == "A" && get("ptr") == "1" {
        for ip in &contents {
            let Some((rev, rz)) = served_reverse_place(s, ip)? else {
                return Err(tr("err_ptr_no_zone").replace("{ip}", ip));
            };
            let have = rrset_contents(&api, &rz, &rev, "PTR").await?;
            if let Some(other) = have.iter().find(|h| **h != host) {
                return Err(tr("err_ptr_taken")
                    .replace("{ip}", ip)
                    .replace("{name}", other.trim_end_matches('.')));
            }
            places.push((rev, rz));
        }
    }
    // What: the addresses the name loses with this change.
    // Why: their PTR to this name must not stay behind.
    // From: Issue #1683 | PR #2019
    let mut gone = Vec::new();
    if kind == "A" {
        gone = rrset_contents(&api, &zone, &name, "A").await?;
        gone.retain(|ip| !contents.contains(ip));
    }
    api.set_rrset(&zone, &name, &kind, ttl, &contents).await?;
    snapshot(s, &api, &zone).await?;
    peer::flush_zone(s, &zone).await?;
    for (rev, rz) in &places {
        api.set_rrset(rz, rev, "PTR", ttl, std::slice::from_ref(&host))
            .await?;
        snapshot(s, &api, rz).await?;
        peer::flush_zone(s, rz).await?;
    }
    for ip in &gone {
        let Some((rev, rz)) = served_reverse_place(s, ip)? else {
            continue;
        };
        // What: drop the PTR only when it names this host.
        // Why: a PTR to another name is not ours to drop.
        // From: Issue #1683 | PR #2019
        if rrset_contents(&api, &rz, &rev, "PTR").await? == [host.clone()] {
            api.set_rrset(&rz, &rev, "PTR", 0, &[]).await?;
            snapshot(s, &api, &rz).await?;
            peer::flush_zone(s, &rz).await?;
        }
    }
    Ok(())
}

// What: the contents of one record set; none: empty.
// Why: PTR checks ask what a name holds right now.
// From: Issue #1683 | PR #2019
pub(crate) async fn rrset_contents(
    api: &crate::shared::pdns::Api,
    zone: &str,
    name: &str,
    kind: &str,
) -> Result<Vec<String>, String> {
    let id = crate::shared::pdns::zone_id(name);
    Ok(api
        .rrsets(zone)
        .await?
        .iter()
        .filter(|r| r["name"] == id.as_str() && r["type"] == kind)
        .filter_map(|r| r["records"].as_array())
        .flatten()
        .filter_map(|c| c["content"].as_str().map(str::to_string))
        .collect())
}

// What: the TTL a record form sends, within the limit.
// Why: the LAN and the PTR form take the same field.
// From: Issue #1683 | PR #2019
pub(crate) fn form_ttl(s: &Settings, get: &(dyn Fn(&str) -> String + Sync)) -> Result<u32, String> {
    let max = s.uint("DNS_RECORD_TTL_MAX")?;
    let ttl = get("ttl").parse::<u32>().unwrap_or(0);
    if ttl == 0 || u64::from(ttl) > max {
        return Err(tr("err_ttl_range").replace("{max}", &max.to_string()));
    }
    Ok(ttl)
}

// What: add or remove one PTR record.
// Why: name from the IP; zone from the list.
// From: Issue #1683 | PR #1980
pub(crate) async fn ptr(
    s: &Settings,
    add: bool,
    get: &(dyn Fn(&str) -> String + Sync),
) -> Result<(), String> {
    let ip = get("ip");
    let name = if crate::shared::dns::is_reverse_name(&ip) {
        ip
    } else {
        reverse_name(&ip)?
    };
    let Some(zone) = reverse_zone(s, &name) else {
        return Err(format!("{name} is in no private reverse zone"));
    };
    let mut ttl = 0;
    let mut contents = Vec::new();
    if add {
        ttl = form_ttl(s, get)?;
        contents.push(crate::shared::pdns::zone_id(&get("hostname")));
    }
    let api = pdns_api(s)?;
    api.set_rrset(&zone, &name, "PTR", ttl, &contents).await?;
    snapshot(s, &api, &zone).await?;
    peer::flush_zone(s, &zone).await
}

// What: saves secondaries as name@address rows.
// Why: one SOT key holds the whole list.
// From: Issue #1683 | PR #1980
pub(crate) async fn store_secondaries(app: &App, list: &[(String, String)]) -> Result<(), String> {
    let rows = crate::shared::pdns_conf::secondary_rows(list);
    commit(app, single_field("DNS_SECONDARIES", rows)).await
}

// What: checks a secondary name: one label, SOT length.
// Why: the name becomes a DNS label and file name.
// From: Issue #1683 | PR #2017
pub(crate) fn valid_peer_name(s: &Settings, name: &str) -> Result<bool, String> {
    let max = s.num::<usize>("DNS_SECONDARY_NAME_MAX")?;
    let label = !name.contains('.') && crate::shared::dns::is_dns_name(name, false, false);
    Ok(name.len() <= max && label)
}

// What: everything a new secondary needs.
// Why: setup.sh secondary writes it to its env.
// From: Issue #1683 | PR #1980
pub(crate) fn peer_kit(s: &Settings) -> Result<Value, String> {
    let primary = s.text("IP_HTTP")?;
    Ok(json!({
        "primary": primary,
        // What: the zones the primary serves.
        // Why: the secondary pulls each one by AXFR.
        // From: Issue #1683
        "zones": crate::shared::dns::managed_zones(s)?,
        "pdns_api_key": secret::get(s, "PDNS_API_KEY")?,
        "tsig_name": s.text("DDNS_TSIG_NAME")?,
        "tsig_secret": secret::tsig_secret(s)?,
        "syslog_primary": format!("{primary}:{}", s.uint("LANCACHE_LOG_PORT")?),
        "dns_local_reverse_zones": s.text_or_empty("DNS_LOCAL_REVERSE_ZONES"),
        "image_registry": process_env("LANCACHE_IMAGE_REGISTRY").unwrap_or_default(),
        "image_prefix": process_env("LANCACHE_IMAGE_PREFIX").unwrap_or_default(),
        "image_channel": process_env("LANCACHE_IMAGE_CHANNEL").unwrap_or_default(),
        "image_tag": process_env("LANCACHE_IMAGE_TAG").unwrap_or_default(),
    }))
}

// What: NS lists with a name in, out or in neither.
// Why: Some(true) enters, Some(false) takes it out.
// From: Issue #1683
pub(crate) fn ns_change(s: &Settings, name: &str, entered: Option<bool>) -> Fields {
    let mut form = list_change(s, "DNS_SECONDARY_NS", name, entered == Some(true));
    form.extend(list_change(
        s,
        "DNS_SECONDARY_NS_OFF",
        name,
        entered == Some(false),
    ));
    form
}

// What: serial of each managed zone on both peers.
// Why: shows a lost NOTIFY or AXFR in any zone (RFC 1982).
// From: Issue #1683 | PR #1858
pub(crate) async fn peer_serials(s: &Settings, address: &str) -> Result<Vec<PeerZone>, String> {
    let ours = pdns_api(s)?.zones().await?;
    let theirs = peer::zones_at(s, address).await?;
    peer::peer_zones(s, &ours, &theirs)
}

// What: pdns API of one peer by its address.
// Why: zone list, AXFR request and sync use it.
// From: Issue #1683
pub(crate) fn remote_api(s: &Settings, address: &str) -> Result<crate::shared::pdns::Api, String> {
    peer::api_at(
        s,
        http::client(s)?,
        address,
        &secret::get(s, "PDNS_API_KEY")?,
    )
}

// What: check every secondary; again after a wait.
// Why: the SOT sets a shorter wait while one fails.
// From: Issue #1683
pub(crate) async fn secondary_watch(app: Arc<App>) {
    let mut failing: BTreeMap<String, Failing> = BTreeMap::new();
    loop {
        let s = app.settings();
        let key = match watch_round(&app, &s, &mut failing).await {
            Ok(()) if failing.is_empty() => "DNS_SECONDARY_CHECK_SECONDS",
            Ok(()) => "DNS_SECONDARY_RECHECK_SECONDS",
            // What: own pdns down: no secondary is blamed.
            // Why: at ui start the dns may not run yet.
            // From: Issue #1683
            Err(e) => {
                eprintln!("ui: secondary check skipped: {e}");
                "PDNS_SOA_COLD_RETRY"
            }
        };
        let Some(wait) = or_stop("secondary check", s.uint(key)) else {
            return;
        };
        tokio::time::sleep(Duration::from_secs(wait)).await;
    }
}

// What: one round over all secondaries.
// Why: resync a lag, enter or take out NS names.
// From: Issue #1683
pub(crate) async fn watch_round(
    app: &App,
    s: &Settings,
    failing: &mut BTreeMap<String, Failing>,
) -> Result<(), String> {
    let ours = pdns_api(s)?.zones().await?;
    let peers = crate::shared::pdns_conf::secondaries(s);
    failing.retain(|n, _| peers.iter().any(|(p, _)| p == n));
    let enabled = s.flag("DNS_SECONDARY_NS_ENABLED")?;
    let auto = s.flag("DNS_SECONDARY_NS_AUTO_REMOVE")?;
    let after = Duration::from_secs(s.uint("DNS_SECONDARY_NS_REMOVE_AFTER_SECONDS")?);
    let fails = s.uint("DNS_SECONDARY_NS_REMOVE_FAILS")?;
    let (mut ns, mut off) = (s.list("DNS_SECONDARY_NS"), s.list("DNS_SECONDARY_NS_OFF"));
    for (name, address) in &peers {
        // What: no aa counts as failure only for an NS.
        // Why: an older secondary syncs but is never NS.
        // From: Issue #1683
        let outcome = match check_peer(s, &ours, address).await {
            Ok(Err(e)) if !ns.contains(name) => {
                if enabled {
                    eprintln!("ui: secondary {name}: no NS: {e}");
                }
                Ok(false)
            }
            Ok(aa) => aa.map(|()| true),
            Err(e) => Err(e),
        };
        match outcome {
            Ok(aa) => {
                failing.remove(name);
                // What: first entry; never after take out.
                // Why: re-entry only by hand.
                // From: Issue #1683
                if aa && enabled && !ns.contains(name) && !off.contains(name) {
                    eprintln!("ui: secondary {name}: entered as NS");
                    ns.push(name.clone());
                }
            }
            Err(e) => {
                let f = failing.entry(name.clone()).or_insert(Failing {
                    since: std::time::Instant::now(),
                    count: 0,
                });
                f.count += 1;
                eprintln!("ui: secondary {name}: check {} failed: {e}", f.count);
                let due = f.count >= fails && f.since.elapsed() > after;
                if enabled && auto && due && ns.contains(name) {
                    eprintln!("ui: secondary {name}: NS taken out");
                    ns.retain(|n| n != name);
                    off.push(name.clone());
                }
            }
        }
    }
    let mut form = Fields::new();
    for (key, now) in [("DNS_SECONDARY_NS", ns), ("DNS_SECONDARY_NS_OFF", off)] {
        if now != s.list(key) {
            form.insert(key.into(), now.join(" "));
        }
    }
    if form.is_empty() {
        return Ok(());
    }
    commit(app, form).await
}

// What: one secondary gets our zone list.
// Why: added or removed domains reach it alone.
// From: Issue #1683
pub(crate) async fn peer_follows(
    s: &Settings,
    api: &crate::shared::pdns::Api,
    address: &str,
) -> Result<(), String> {
    let masters = vec![crate::shared::dns::host_port(
        &s.text("IP_HTTP")?,
        s.uint("PDNS_AUTH_PORT")?,
    )];
    let who = format!("ui: secondary {address}");
    let key = s.text("DDNS_TSIG_NAME")?;
    peer::match_zones(api, &hosted_now(s)?, &masters, &key, true, &who).await
}

// What: every secondary follows, in the background.
// Why: a zone change must not wait for the slow check.
// From: Issue #1683
pub(crate) fn peers_follow(s: &Settings) {
    let s = s.clone();
    tokio::spawn(async move {
        for (name, address) in crate::shared::pdns_conf::secondaries(&s) {
            let done = match remote_api(&s, &address) {
                Ok(api) => peer_follows(&s, &api, &address).await,
                Err(e) => Err(e),
            };
            if let Err(e) = done {
                eprintln!("ui: secondary {name}: zones not matched: {e}");
            }
        }
    });
}

// What: serials via pdns-API, lag pulled; aa result.
// Why: an NS must answer aa; AXFR fixes a lost NOTIFY.
// From: Issue #1683
pub(crate) async fn check_peer(
    s: &Settings,
    ours: &[crate::shared::pdns::Zone],
    address: &str,
) -> Result<Result<(), String>, String> {
    let aa = answers_aa(s, address, &crate::shared::dns::lan_zone(s)?).await;
    let api = remote_api(s, address)?;
    peer_follows(s, &api, address).await?;
    let theirs = api.zones().await?;
    for z in peer::peer_zones(s, ours, &theirs)? {
        let state = peer::zone_state(&z);
        let word = state.word();
        // What: ahead: our serial goes past theirs first.
        // Why: a restore sets ours back; AXFR skips lower.
        // From: Issue #1683 | PR #2017
        if let (ZoneState::Ahead, Some(theirs)) = (state, z.secondary)
            && let Err(e) = raise_serial(s, &z.zone, theirs).await
        {
            eprintln!("ui: secondary {address}: {} ahead, raise: {e}", z.zone);
            continue;
        }
        // What: ahead, unknown, behind pulled; missing not.
        // Why: a missing zone has no copy to refresh.
        // From: Issue #1683
        if matches!(
            state,
            ZoneState::Ahead | ZoneState::Unknown | ZoneState::Behind
        ) {
            match api.axfr_retrieve(&z.zone).await {
                Ok(()) => eprintln!("ui: secondary {address}: {} {word}, AXFR asked", z.zone),
                Err(e) => eprintln!("ui: secondary {address}: {} {word}, AXFR: {e}", z.zone),
            }
        }
    }
    Ok(aa)
}

// What: worst state over all zones, each zone in detail.
// Why: in sync only when every managed zone matches.
// From: Issue #1683
pub(crate) async fn secondary_health(s: &Settings, address: &str) -> Value {
    let zones = match peer_serials(s, address).await {
        Ok(z) => z,
        Err(e) => return json!({"status": "unreachable", "detail": e}),
    };
    let worst = peer::worst_state(&zones);
    let mut lines = Vec::new();
    for z in &zones {
        let state = peer::zone_state(z).word();
        let show = |v: Option<u32>| v.map_or_else(|| "-".to_string(), |n| n.to_string());
        lines.push(format!(
            "{}: {} (primary {}, secondary {})",
            z.zone,
            state,
            show(z.primary),
            show(z.secondary)
        ));
    }
    json!({"status": worst.word(), "zones": zones.len(), "detail": lines.join("\n")})
}

// What: flush recursor caches when a serial moves.
// Why: UI, DDNS, AXFR and rollback all bump it.
// From: Issue #1683 | PR #1980
pub(crate) async fn flush_on_transfer(app: Arc<App>) {
    let mut seen = peer::Flushed::default();
    // What: an error only after the grace time.
    // Why: a planned dns restart must log nothing.
    // From: Issue #1683 | PR #1980
    let mut down: Option<std::time::Instant> = None;
    let mut logged = false;
    loop {
        let s = app.settings();
        let Some(wait) = or_stop("cache flush", s.uint("UI_FLUSH_CHECK_SECONDS")) else {
            return;
        };
        let Some(grace) = or_stop("cache flush", s.uint("UI_FLUSH_GRACE_SECONDS")) else {
            return;
        };
        match flush_round(&s, &mut seen).await {
            Err(e) => {
                let since = *down.get_or_insert_with(std::time::Instant::now);
                if !logged && since.elapsed().as_secs() >= grace {
                    eprintln!("ui: cache flush fails for {grace} s: {e}");
                    logged = true;
                }
            }
            Ok(()) => {
                if logged {
                    eprintln!("ui: cache flush works again");
                }
                (down, logged) = (None, false);
            }
        }
        tokio::time::sleep(Duration::from_secs(wait)).await;
    }
}

// What: clears recursor cache for changed zones.
// Why: recursors would serve old answers until TTL.
// From: Issue #1683 | PR #1980
pub(crate) async fn flush_round(s: &Settings, seen: &mut peer::Flushed) -> Result<(), String> {
    let api = pdns_api(s)?;
    let peers = !crate::shared::pdns_conf::secondaries(s).is_empty();
    let zones: BTreeMap<String, u32> = api
        .zones()
        .await?
        .into_iter()
        .map(|z| (z.name, z.serial))
        .collect();
    for (zone, serial) in seen.due(&zones) {
        peer::flush_zone(s, &zone).await?;
        // What: NOTIFY to the secondaries right away.
        // Why: live: pdns alone waited up to 60 s.
        // From: Issue #1683 | PR #2019
        if peers {
            api.notify(&zone).await?;
        }
        seen.done(&zone, serial);
    }
    Ok(())
}

// What: the live chain; on error NTA everywhere.
// Why: no proof must never mean SERVFAIL.
// From: Issue #1683 | PR #2019
pub(crate) async fn dnssec_chain(s: &Settings) -> crate::shared::recursor_conf::Chain {
    match read_chain(s).await {
        Ok(c) => c,
        Err(e) => {
            eprintln!("ui: DNSSEC anchors off: {e}");
            crate::shared::recursor_conf::Chain::default()
        }
    }
}

// What: anchors of top zones; zones chained to them.
// Why: a zone loses its NTA only on a proven chain.
// From: Issue #1683 | PR #2019
pub(crate) async fn read_chain(
    s: &Settings,
) -> Result<crate::shared::recursor_conf::Chain, String> {
    let mut chain = crate::shared::recursor_conf::Chain::default();
    if Role::from_settings(s)? != Role::Primary {
        return Ok(chain);
    }
    let tops = own_tops(s)?;
    if tops.is_empty() {
        return Ok(chain);
    }
    let api = pdns_api(s)?;
    for top in &tops {
        let ds = api.ds(top).await.unwrap_or_default();
        if !ds.is_empty() {
            chain.secured.push(top.clone());
        }
        chain.anchors.push((top.clone(), ds));
    }
    let norm = |rows: Vec<String>| {
        let mut v: Vec<String> = rows.iter().map(|r| canonical("DS", r)).collect();
        v.sort();
        v
    };
    for (zone, parent) in own_links(s, &tops)? {
        let Some(parent) = parent else {
            continue;
        };
        if !chain.secured.contains(&parent) {
            continue;
        }
        let want = norm(api.ds(&zone).await.unwrap_or_default());
        let have = norm(rrset_contents(&api, &parent, &zone, "DS").await?);
        if !want.is_empty() && want == have {
            chain.secured.push(zone);
        }
    }
    Ok(chain)
}

// What: Ok when the address answers zone with aa.
// Why: only an authoritative secondary may be an NS.
// From: Issue #1683
pub(crate) async fn answers_aa(s: &Settings, address: &str, zone: &str) -> Result<(), String> {
    let soa = peer::soa_on_dns_port(s, address, zone).await?;
    if soa.serves_zone() {
        return Ok(());
    }
    Err(format!(
        "{address} answers {zone} with rcode {} and aa {}",
        soa.rcode, soa.authoritative
    ))
}

// What: create missing primary zones; set DDNS meta.
// Why: no other step creates the zones in pdns.
// From: Issue #1683 | PR #1980
pub(crate) async fn ensure_primary_zones(s: &Settings, key: &str) -> Result<(), String> {
    let api = pdns_api(s)?;
    let have = zone_names(&api).await?;
    let edit = vec![s.text("PDNS_SOA_EDIT")?];
    let signed = if s.flag("DDNS_ALLOW_UNSIGNED")? {
        Vec::new()
    } else {
        vec![s.text("DDNS_TSIG_NAME")?]
    };
    let tops = own_tops(s)?;
    let hosted = hosted_zones(s, &tops)?;
    for zone in &hosted {
        let id = crate::shared::pdns::zone_id(zone);
        if !have.contains(&id) {
            api.create_primary(&id, &edit[0], key).await?;
        }
        api.set_metadata(&id, "SOA-EDIT-DNSUPDATE", &edit).await?;
        api.set_metadata(&id, "NOTIFY-DNSUPDATE", &["1".to_string()])
            .await?;
        api.set_metadata(&id, "TSIG-ALLOW-DNSUPDATE", &signed)
            .await?;
    }
    for lan in crate::shared::dns::lan_domains(s)? {
        merge_legacy_zone(s, &api, &have, &lan).await?;
    }
    ensure_own_endings(s, &api, &tops).await?;
    ensure_soa_nameserver(s, &api, &hosted).await
}

// What: top zones of own endings; no PSL, none.
// Why: an ending we cannot check may be public.
// From: Issue #1683 | PR #2019
pub(crate) fn own_tops(s: &Settings) -> Result<Vec<String>, String> {
    match render::psl(s) {
        Ok(psl) => crate::shared::dns::top_zones(s, &psl),
        Err(e) => {
            eprintln!("ui: no own top zones: {e}");
            Ok(Vec::new())
        }
    }
}

// What: the hosted zones with the tops read now.
// Why: drop_old_zones compares before and after.
// From: Issue #1683 | PR #2019
pub(crate) fn hosted_now(s: &Settings) -> Result<Vec<String>, String> {
    hosted_zones(s, &own_tops(s)?)
}

// What: zones the primary keeps: managed plus tops.
// Why: one list creates zones, NS and SOA names.
// From: Issue #1683 | PR #2019
pub(crate) fn hosted_zones(s: &Settings, tops: &[String]) -> Result<Vec<String>, String> {
    let mut zones = crate::shared::dns::managed_zones(s)?;
    for top in tops {
        config::add_once(&mut zones, top);
    }
    Ok(zones)
}

// What: LAN zones of own endings and their parent.
// Why: signing and the resolver chain walk one list.
// From: Issue #1683 | PR #2019
pub(crate) fn own_links(
    s: &Settings,
    tops: &[String],
) -> Result<Vec<(String, Option<String>)>, String> {
    use crate::shared::dns::{is_within, parent_zone};
    let mut signed: Vec<String> = crate::shared::dns::lan_domains(s)?
        .into_iter()
        .filter(|z| tops.iter().any(|t| is_within(z, t)))
        .collect();
    // What: parents before their children.
    // Why: a chain holds only if every link above holds.
    // From: Issue #1683 | PR #2019
    signed.sort_by_key(|z| z.matches('.').count());
    let mut parents = tops.to_vec();
    parents.extend(signed.iter().cloned());
    Ok(signed
        .into_iter()
        .map(|z| {
            let p = parent_zone(&z, &parents);
            (z, p)
        })
        .collect())
}

// What: sign own endings; parents hold NS and DS.
// Why: .lan and .local validate only along a chain.
// From: Issue #1683 | PR #2019
pub(crate) async fn ensure_own_endings(
    s: &Settings,
    api: &crate::shared::pdns::Api,
    tops: &[String],
) -> Result<(), String> {
    let ns = ns_names(s, &soa_names(s)?.0)?;
    let ttl = s.num::<u32>("DNS_RECORD_TTL")?;
    for top in tops {
        api.secure(top).await?;
    }
    let mut wanted: Vec<(String, String)> = Vec::new();
    for (zone, parent) in own_links(s, tops)? {
        let zone = &zone;
        api.secure(zone).await?;
        let Some(parent) = parent else {
            continue;
        };
        ensure_rrset(api, &parent, zone, "NS", ttl, &ns).await?;
        // What: no DS when it cannot be read.
        // Why: no DS is unchecked; a wrong DS is SERVFAIL.
        // From: Issue #1683 | PR #2019
        let ds = api.ds(zone).await.unwrap_or_else(|e| {
            eprintln!("ui: no DS for {zone}: {e}");
            Vec::new()
        });
        ensure_rrset(api, &parent, zone, "DS", ttl, &ds).await?;
        wanted.push((parent, zone.clone()));
    }
    // What: drop delegations of gone zones in top zones.
    // Why: a top zone is ours; a LAN zone keeps all rows.
    // From: Issue #1683 | PR #2019
    for top in tops {
        for r in api.rrsets(top).await? {
            let (Some(name), Some(kind)) = (r["name"].as_str(), r["type"].as_str()) else {
                continue;
            };
            let child = (top.clone(), name.to_string());
            if name != top && matches!(kind, "NS" | "DS") && !wanted.contains(&child) {
                api.set_rrset(top, name, kind, ttl, &[]).await?;
            }
        }
    }
    Ok(())
}

// What: moves local.<domain> records into <domain>.
// Why: zones before multi-domain had this extra zone.
// From: Issue #1683
pub(crate) async fn merge_legacy_zone(
    s: &Settings,
    api: &crate::shared::pdns::Api,
    have: &[String],
    lan: &str,
) -> Result<(), String> {
    let legacy = crate::shared::dns::legacy_local_zone(lan);
    let id = crate::shared::pdns::zone_id(&legacy);
    // What: a LAN domain named local.<x> is kept.
    // Why: then it is a configured zone, not legacy.
    // From: Issue #1683
    if !have.contains(&id) || crate::shared::dns::lan_domains(s)?.contains(&legacy) {
        return Ok(());
    }
    let moved = own_rrsets(&api.rrsets(&legacy).await?);
    let key = |r: &Value| (r["name"].to_string(), r["type"].to_string());
    let parent = own_rrsets(&api.rrsets(lan).await?);
    // What: a clash keeps both zones and logs it.
    // Why: a record must never be overwritten silently.
    // From: Issue #1683
    if let Some(r) = moved
        .iter()
        .find(|r| parent.iter().any(|p| key(p) == key(r)))
    {
        eprintln!(
            "ui: zone {legacy} kept: {} {} also in {lan}",
            r["name"], r["type"]
        );
        return Ok(());
    }
    if !moved.is_empty() {
        snapshot(s, api, &legacy).await?;
        snapshot(s, api, lan).await?;
        let mut saved = api.rrsets(lan).await?;
        saved.extend(moved.iter().cloned());
        api.restore(lan, &saved).await?;
        snapshot(s, api, lan).await?;
    }
    api.delete_zone(&legacy).await?;
    peer::flush_zone(s, lan).await?;
    eprintln!(
        "ui: zone {legacy} merged into {lan} ({} rrsets)",
        moved.len()
    );
    Ok(())
}

// What: NS and A record for the SOA's nameserver.
// Why: the SOA named ns1, but no record held that name.
// From: Issue #1683
pub(crate) async fn ensure_soa_nameserver(
    s: &Settings,
    api: &crate::shared::pdns::Api,
    hosted: &[String],
) -> Result<(), String> {
    let names = soa_names(s)?;
    let mname = names.0.clone();
    let lan = crate::shared::dns::lan_zone(s)?;
    let ttl = s.num::<u32>("DNS_RECORD_TTL")?;
    let ns = ns_names(s, &mname)?;
    for zone in hosted {
        ensure_rrset(api, zone, zone, "NS", ttl, &ns).await?;
        ensure_soa_names(api, zone, &names).await?;
    }
    // What: A or AAAA and PTR of each secondary.
    // Why: an NS name needs an address; logs show names.
    // From: Issue #1683
    for (name, address) in crate::shared::pdns_conf::secondaries(s) {
        let host = peer_host(s, &name)?;
        let kind = crate::shared::dns::address_kind(&address);
        ensure_rrset(api, &lan, &host, kind, ttl, std::slice::from_ref(&address)).await?;
        ensure_ptr(s, api, &address, &host, ttl).await?;
    }
    // What: A and PTR only when ns1 is in the LAN zone.
    // Why: a foreign name has no home in a managed zone.
    // From: Issue #1683
    if crate::shared::dns::is_below(&mname, &lan) {
        let ip = s.text("IP_HTTP")?;
        ensure_rrset(api, &lan, &mname, "A", ttl, std::slice::from_ref(&ip)).await?;
        ensure_ptr(s, api, &ip, &mname, ttl).await?;
    }
    // What: ns2 for the HTTPS IP: A and PTR, never NS.
    // Why: HTTPS is optional and another resolver answers.
    // From: Issue #1683
    let https = primary_https_ip(s)?;
    let ns2 = crate::shared::dns::canonical_zone(&s.text("DNS_NS_HTTPS_NAME")?);
    if !https.is_empty() && crate::shared::dns::is_below(&ns2, &lan) {
        ensure_rrset(api, &lan, &ns2, "A", ttl, std::slice::from_ref(&https)).await?;
        ensure_ptr(s, api, &https, &ns2, ttl).await?;
    }
    Ok(())
}

// What: NS names: ns1, then entered secondaries.
// Why: a secondary is NS only with the switch on.
// From: Issue #1683
pub(crate) fn ns_names(s: &Settings, mname: &str) -> Result<Vec<String>, String> {
    let mut ns = vec![mname.to_string()];
    if !s.flag("DNS_SECONDARY_NS_ENABLED")? {
        return Ok(ns);
    }
    let entered = s.list("DNS_SECONDARY_NS");
    for (name, _) in crate::shared::pdns_conf::secondaries(s) {
        if entered.contains(&name) {
            ns.push(peer_host(s, &name)?);
        }
    }
    Ok(ns)
}

// What: LAN name of a secondary, with trailing dot.
// Why: A, PTR and NS records use the same name.
// From: Issue #1683
pub(crate) fn peer_host(s: &Settings, name: &str) -> Result<String, String> {
    Ok(format!("{name}.{}", crate::shared::dns::lan_zone(s)?))
}

// What: drop address and PTR records of a secondary.
// Why: a removed or moved secondary leaves no record.
// From: Issue #1683
pub(crate) async fn drop_peer_records(
    s: &Settings,
    name: &str,
    address: &str,
) -> Result<(), String> {
    let api = pdns_api(s)?;
    let host = peer_host(s, name)?;
    let kind = crate::shared::dns::address_kind(address);
    api.set_rrset(&crate::shared::dns::lan_zone(s)?, &host, kind, 0, &[])
        .await?;
    let Some((rev, zone)) = served_reverse_place(s, address)? else {
        return Ok(());
    };
    // What: delete the PTR only when it names this host.
    // Why: an own PTR of the admin must stay.
    // From: Issue #1683
    let ours = rrset_contents(&api, &zone, &rev, "PTR")
        .await?
        .contains(&host);
    if ours {
        api.set_rrset(&zone, &rev, "PTR", 0, &[]).await?;
    }
    Ok(())
}

// What: PTR of an address in its managed reverse zone.
// Why: a reverse zone the stack does not serve is left.
// From: Issue #1683
pub(crate) async fn ensure_ptr(
    s: &Settings,
    api: &crate::shared::pdns::Api,
    ip: &str,
    host: &str,
    ttl: u32,
) -> Result<(), String> {
    let Some((rev, zone)) = served_reverse_place(s, ip)? else {
        return Ok(());
    };
    ensure_rrset(api, &zone, &rev, "PTR", ttl, &[host.to_string()]).await
}

// What: writes the fields of a SOA back to its zone.
// Why: every SOA edit ends with the same record write.
// From: Issue #1683 | PR #2017
pub(crate) async fn write_soa(
    api: &crate::shared::pdns::Api,
    zone: &str,
    ttl: u32,
    fields: &[String],
) -> Result<(), String> {
    api.set_rrset(zone, zone, "SOA", ttl, &[fields.join(" ")])
        .await
}

// What: the names of the zones a server holds.
// Why: both zone setups skip a zone that exists.
// From: Issue #1683 | PR #2017
pub(crate) async fn zone_names(api: &crate::shared::pdns::Api) -> Result<Vec<String>, String> {
    Ok(api.zones().await?.into_iter().map(|z| z.name).collect())
}

// What: mname and rname of PDNS_DEFAULT_SOA.
// Why: NS rows and SOA fields read one parse.
// From: Issue #1683 | PR #2019
pub(crate) fn soa_names(s: &Settings) -> Result<(String, String), String> {
    let soa = s.text("PDNS_DEFAULT_SOA")?;
    let mut names = soa
        .split_whitespace()
        .map(crate::shared::dns::canonical_zone);
    let (Some(mname), Some(rname)) = (names.next(), names.next()) else {
        return Err(format!("PDNS_DEFAULT_SOA {soa:?} names no mname and rname"));
    };
    Ok((mname, rname))
}

// What: SOA mname and rname from PDNS_DEFAULT_SOA.
// Why: a zone made before a domain change kept the old ns1.
// From: Issue #1683 | PR #2017
pub(crate) async fn ensure_soa_names(
    api: &crate::shared::pdns::Api,
    zone: &str,
    names: &(String, String),
) -> Result<(), String> {
    let (mname, rname) = names;
    let Some((ttl, mut f)) = soa_fields(api, zone).await? else {
        return Ok(());
    };
    if &f[0] == mname && &f[1] == rname {
        return Ok(());
    }
    f[0] = mname.clone();
    f[1] = rname.clone();
    write_soa(api, zone, ttl, &f).await
}

// What: our SOA serial set past a secondary's.
// Why: a restore sets it back; AXFR wants a higher one.
// From: Issue #1683 | PR #2017
pub(crate) async fn raise_serial(s: &Settings, zone: &str, past: u32) -> Result<(), String> {
    let api = pdns_api(s)?;
    let Some((ttl, mut f)) = soa_fields(&api, zone).await? else {
        return Err(format!("{zone} has no SOA"));
    };
    f[2] = past.wrapping_add(1).to_string();
    write_soa(&api, zone, ttl, &f).await
}

// What: ttl and the seven fields of a zone's SOA.
// Why: name sync and serial lift edit one record.
// From: Issue #1683 | PR #2017
pub(crate) async fn soa_fields(
    api: &crate::shared::pdns::Api,
    zone: &str,
) -> Result<Option<(u32, Vec<String>)>, String> {
    let id = crate::shared::pdns::zone_id(zone);
    let rrsets = api.rrsets(zone).await?;
    let Some(r) = rrsets
        .iter()
        .find(|r| r["name"] == id.as_str() && r["type"] == "SOA")
    else {
        return Ok(None);
    };
    let have = r["records"][0]["content"].as_str().unwrap_or_default();
    let f: Vec<String> = have.split_whitespace().map(str::to_string).collect();
    if f.len() != 7 {
        return Err(format!("SOA of {zone} is not 7 fields: {have:?}"));
    }
    let ttl = r["ttl"]
        .as_u64()
        .and_then(|t| u32::try_from(t).ok())
        .ok_or_else(|| format!("SOA of {zone} has no ttl"))?;
    Ok(Some((ttl, f)))
}

// What: writes one rrset only when it differs.
// Why: an equal PATCH would still raise the serial.
// From: Issue #1683
pub(crate) async fn ensure_rrset(
    api: &crate::shared::pdns::Api,
    zone: &str,
    name: &str,
    kind: &str,
    ttl: u32,
    want: &[String],
) -> Result<(), String> {
    let id = crate::shared::pdns::zone_id(name);
    let rows = api.rrsets(zone).await?;
    let found = rows
        .iter()
        .find(|r| r["name"] == id.as_str() && r["type"] == kind);
    let same = match found {
        // What: an absent rrset that should be absent.
        // Why: a DELETE of nothing still raises the serial.
        // From: Issue #1683 | PR #2019
        None => want.is_empty(),
        Some(r) => {
            let have: Vec<&str> = r["records"]
                .as_array()
                .map(|a| a.iter().filter_map(|c| c["content"].as_str()).collect())
                .unwrap_or_default();
            r["ttl"] == ttl
                && have.len() == want.len()
                && want.iter().all(|w| have.contains(&w.as_str()))
        }
    };
    if same {
        return Ok(());
    }
    api.set_rrset(zone, name, kind, ttl, want).await
}

// What: TSIG key, zones, then binding; one error line.
// Why: the key is known, so no zone exists without it.
// From: Issue #1683
pub(crate) async fn ensure_zones(s: &Settings) -> Result<(), String> {
    let key = peer::ensure_tsigkey(s)
        .await
        .map_err(|e| format!("tsig: {e}"))?;
    if Role::from_settings(s)? == Role::Secondary {
        peer::ensure_secondary_zones(s, &key)
            .await
            .map_err(|e| format!("secondary zones: {e}"))?;
    } else {
        ensure_primary_zones(s, &key)
            .await
            .map_err(|e| format!("primary zones: {e}"))?;
        peers_follow(s);
    }
    peer::ensure_tsig(s, &key)
        .await
        .map_err(|e| format!("tsig: {e}"))
}

// What: replace the TSIG secret and apply.
// Why: shuts out a removed or leaked secondary.
// From: Issue #1683 | PR #1980
pub(crate) async fn rotate_tsig(app: &App) -> Result<(), String> {
    let s = app.settings();
    let file = secret::tsig_file(&s)?;
    fs::remove_if_present(&file).map_err(|e| format!("{}: {e}", file.display()))?;
    secret::load_or_create(&file, secret::new_tsig, fs::Owner::default())
        .map_err(|e| format!("DDNS_TSIG_KEY: {e}"))?;
    for line in apply_all(app, &s, &s, true).await? {
        eprintln!("ui: tsig rotate: {line}");
    }
    Ok(())
}
