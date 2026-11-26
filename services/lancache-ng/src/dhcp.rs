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

// What: DHCP page logic: Kea subnets, options, probe.
// Why: one home for the DHCP actions of the ui.
// From: Issue #1683 | PR #2020
use crate::config::{self, Settings};
use crate::dns::*;
use crate::shared::dhcp::{Mode as DhcpMode, option_data};
use crate::shared::{docker, fs, http, secret};
use crate::ui::*;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Duration;

// What: does our NTP server answer.
// Why: General page shows the live state.
// From: Issue #1683 | PR #1980
pub(crate) async fn ntp_answers(s: &Settings) -> Result<bool, String> {
    if !s.flag("NTP_ENABLED")? {
        return Ok(false);
    }
    let ip = s.text("IP_HTTP")?;
    let port = s.uint("NTP_PORT")?;
    let wait = Duration::from_millis(s.uint("NTP_PROBE_WAIT_MS")?);
    let probe = move || crate::shared::ntp::answers(&ip, port, wait);
    tokio::task::spawn_blocking(probe)
        .await
        .map_err(|e| e.to_string())
}

// What: Kea subnets per LAN zone, by domain-name.
// Why: the DNS page shows which subnet uses a domain.
// From: Issue #1683
pub(crate) async fn domain_subnets(s: &Settings) -> BTreeMap<String, Vec<String>> {
    let mut out: BTreeMap<String, Vec<String>> = BTreeMap::new();
    if DhcpMode::from_settings(s).ok() != Some(DhcpMode::Kea) {
        return out;
    }
    // What: no Kea answer leaves the column empty.
    // Why: the DNS page must not fail when dhcp is down.
    // From: Issue #1683
    let Ok(api) = kea_api(s) else { return out };
    let Ok(cfg) = api.config().await else {
        return out;
    };
    for sn in cfg["Dhcp4"]["subnet4"].as_array().into_iter().flatten() {
        let domain = option_data(sn, crate::shared::dhcp::DOMAIN_NAME.name);
        if domain.is_empty() {
            continue;
        }
        let zone = crate::shared::dns::canonical_zone(&domain);
        let net = sn["subnet"].as_str().unwrap_or_default().to_string();
        out.entry(zone).or_default().push(net);
    }
    out
}

// What: Kea control agent of this stack.
// Why: host from env; basic auth with the stack token.
// From: Issue #1683 | PR #1980
pub(crate) fn kea_api(s: &Settings) -> Result<crate::shared::kea::Api, String> {
    let url = format!(
        "http://{}:{}/",
        s.text("DHCP_API_HOST")?,
        s.uint("KEA_CTRL_PORT")?
    );
    let token = secret::get(s, "KEA_CTRL_TOKEN")?;
    Ok(crate::shared::kea::Api::new(
        http::client(s)?,
        &url,
        &s.text("KEA_CTRL_USER")?,
        &token,
    ))
}

// What: one Kea subnet as flat page fields.
// Why: the page shows fields; Kea has option-data.
// From: Issue #1683 | PR #1980
pub(crate) fn subnet_row(sn: &Value) -> Value {
    use crate::shared::dhcp::{DNS_SERVERS, DOMAIN_NAME, NTP_SERVERS, ROUTERS};
    let dns: Vec<String> = option_data(sn, DNS_SERVERS.name)
        .split(',')
        .map(|x| x.trim().to_string())
        .collect();
    let pool = sn["pools"][0]["pool"].as_str().unwrap_or_default();
    let (start, end) = pool.split_once('-').unwrap_or(("", ""));
    let custom: Vec<Value> = crate::shared::kea_conf::coded_options(sn)
        .into_iter()
        .filter(|o| o.get("code").is_some())
        .collect();
    json!({
        "id": sn["id"],
        "subnet": sn["subnet"],
        "gateway": option_data(sn, ROUTERS.name),
        "dns_primary": dns.first().cloned().unwrap_or_default(),
        "dns_secondary": dns.get(1).cloned().unwrap_or_default(),
        "ntp_servers": option_data(sn, NTP_SERVERS.name),
        "domain": option_data(sn, DOMAIN_NAME.name),
        "pool_start": start.trim(),
        "pool_end": end.trim(),
        "lease_time": sn["valid-lifetime"],
        "custom_options": custom,
    })
}

// What: subnets, reservations, leases from Kea.
// Why: read live; nothing is kept in the ui.
// From: Issue #1683 | PR #1980
pub(crate) async fn kea_view(
    api: &crate::shared::kea::Api,
) -> (Vec<Value>, Vec<Value>, Vec<Value>) {
    let (mut subnets, mut reservations, mut leases) = (Vec::new(), Vec::new(), Vec::new());
    if let Ok(cfg) = api.config().await {
        for sn in cfg["Dhcp4"]["subnet4"].as_array().into_iter().flatten() {
            for r in sn["reservations"].as_array().into_iter().flatten() {
                reservations.push(json!({
                    "subnet_id": sn["id"], "mac": r["hw-address"],
                    "ip": r["ip-address"], "hostname": r["hostname"],
                }));
            }
            subnets.push(subnet_row(sn));
        }
    }
    for l in api.leases().await.unwrap_or_default() {
        let ends = l["cltt"].as_u64().unwrap_or(0) + l["valid-lft"].as_u64().unwrap_or(0);
        leases.push(json!({
            "ip": l["ip-address"], "mac": l["hw-address"], "hostname": l["hostname"],
            "subnet_id": l["subnet-id"], "expires": ends.to_string(),
        }));
    }
    (subnets, reservations, leases)
}

// What: snapshot store of the Kea config.
// Why: each subnet change can be undone.
// From: Issue #1683 | PR #1980
pub(crate) fn kea_store(s: &Settings) -> Result<crate::shared::snapshot::Store, String> {
    let dir = PathBuf::from(s.text("KEA_CONFIG_SNAPSHOT_DIR")?);
    let keep = s.num::<usize>("KEA_SNAPSHOT_KEEP")?;
    Ok(crate::shared::snapshot::Store {
        dir,
        keep,
        owner: fs::Owner::default(),
        file: Some(s.text("KEA_CONFIG_SNAPSHOT_FILE")?),
    })
}

// What: the main subnet form also saves settings.
// Why: the settings are the only source of it.
// From: Issue #1683
pub(crate) async fn main_subnet(
    app: &App,
    s: &Settings,
    op: &str,
    get: &(dyn Fn(&str) -> String + Sync),
) -> Result<(), String> {
    let main = s.uint("DHCP_SUBNET_ID")?.to_string();
    let hit = get("id") == main;
    if hit && op == "UI_ROUTE_SUBNET_REMOVE" {
        return Err(tr("err_main_subnet_remove"));
    }
    kea_action(s, op, get).await?;
    if !(hit && op == "UI_ROUTE_SUBNET_UPDATE") {
        return Ok(());
    }
    let dns = dns_pair(get("dns_primary"), get("dns_secondary"));
    let mut f = Fields::new();
    for (key, field) in [
        ("DHCP_SUBNET", "subnet"),
        ("DHCP_RANGE_START", "pool_start"),
        ("DHCP_RANGE_END", "pool_end"),
        ("DHCP_GATEWAY", "gateway"),
        ("DHCP_NTP_SERVERS", "ntp_servers"),
    ] {
        f.insert(key.into(), get(field));
    }
    // What: main subnet domain sets the main LAN domain.
    // Why: picking an extra swaps it with the old main.
    // From: Issue #1683
    if !get("domain").is_empty() {
        f.extend(main_domain_fields(s, &get("domain"))?);
    }
    if !get("lease_time").is_empty() {
        f.insert("DHCP_LEASE_TIME".into(), get("lease_time"));
    }
    f.insert("DHCP_DNS_SERVERS".into(), dns.join(" "));
    commit(app, f).await
}

// What: change Kea subnets with a closure.
// Why: get, edit, set, write, snapshot; one path.
// From: Issue #1683 | PR #1980
pub(crate) async fn kea_edit(
    s: &Settings,
    edit: impl FnOnce(&mut Vec<Value>) -> Result<(), String>,
) -> Result<(), String> {
    let api = kea_api(s)?;
    let mut cfg = api.config().await?;
    if let Some(top) = cfg.as_object_mut() {
        top.remove("hash");
    }
    let mut subnets = cfg["Dhcp4"]["subnet4"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    edit(&mut subnets)?;
    cfg["Dhcp4"]["subnet4"] = Value::Array(subnets);
    api.set_config(cfg.clone()).await?;
    let store = kea_store(s)?;
    store.save(&serde_json::to_vec(&cfg).map_err(|e| e.to_string())?)?;
    Ok(())
}

// What: Kea subnet from the subnet form.
// Why: named options; code options and hosts kept.
// From: Issue #1683 | PR #1980
pub(crate) fn subnet_from(
    get: &(dyn Fn(&str) -> String + Sync),
    id: u64,
    old: Option<&Value>,
) -> Value {
    let dns = dns_pair(get("dns_primary"), get("dns_secondary"));
    let hosts: Vec<String> = config::list_items(&get("ntp_servers"))
        .map(str::to_string)
        .collect();
    let ntp = crate::shared::dhcp::ipv4_of(&hosts, "ntp_servers");
    let mut opts = crate::shared::kea_conf::named_rows(&get("gateway"), &dns, &get("domain"), &ntp);
    if let Some(old) = old {
        opts.extend(crate::shared::kea_conf::coded_options(old));
    }
    let pool = crate::shared::kea_conf::pool_text(&get("pool_start"), &get("pool_end"));
    let mut sn = json!({"id": id, "subnet": get("subnet"), "pools": [{"pool": pool}],
                        "option-data": opts});
    if let Ok(life) = get("lease_time").parse::<u64>() {
        sn["valid-lifetime"] = life.into();
    }
    if let Some(hosts) = old.and_then(|o| o.get("reservations")) {
        sn["reservations"] = hosts.clone();
    }
    sn
}

// What: Kea subnet with the given id.
// Why: edits target a subnet by id, not position.
// From: Issue #1683 | PR #1980
pub(crate) fn subnet_mut(list: &mut [Value], id: u64) -> Result<&mut Value, String> {
    let found = list.iter_mut().find(|x| x["id"].as_u64() == Some(id));
    found.ok_or_else(|| tr("err_no_subnet").replace("{id}", &id.to_string()))
}

// What: SOT keys of the proxy and relay forms.
// Why: field dhcp_x maps to key DHCP_X.
// From: Issue #1683 | PR #1980
pub(crate) fn dnsmasq_fields(form: &Fields, proxy: bool) -> Fields {
    let mut out = Fields::new();
    for (k, v) in form {
        let ours = k.starts_with("dhcp_") || k.starts_with("upstream_");
        if !ours || k.starts_with("dhcp_dns_") {
            continue;
        }
        let key = k
            .to_ascii_uppercase()
            .replace("DHCP_PROXY_CUSTOM_OPTIONS", "DHCP_CUSTOM_OPTIONS");
        out.insert(key, v.trim().to_string());
    }
    if proxy {
        let get = |k: &str| field(form, k);
        let dns = dns_pair(get("dhcp_dns_primary"), get("dhcp_dns_secondary"));
        out.insert("DHCP_DNS_SERVERS".into(), dns.join(" "));
    }
    out
}

// What: Kea subnet, option and host edits.
// Why: all go through kea_edit.
// From: Issue #1683 | PR #1980
pub(crate) async fn kea_action(
    s: &Settings,
    op: &str,
    get: &(dyn Fn(&str) -> String + Sync),
) -> Result<(), String> {
    let num = |k: &str| {
        get(k)
            .parse::<u64>()
            .map_err(|_| format!("{k} must be a number"))
    };
    // What: a subnet domain must be a LAN domain.
    // Why: DDNS and DNS answer only for those zones.
    // From: Issue #1683
    if matches!(op, "UI_ROUTE_SUBNET_ADD" | "UI_ROUTE_SUBNET_UPDATE") && !get("domain").is_empty() {
        chosen_lan_zone(s, &get("domain"))?;
    }
    match op {
        "UI_ROUTE_SUBNET_ADD" => {
            kea_edit(s, |l| {
                let next = l.iter().filter_map(|x| x["id"].as_u64()).max().unwrap_or(0) + 1;
                let mut sn = subnet_from(get, next, None);
                crate::shared::kea_conf::subnet_ddns_suffix(s, &mut sn)?;
                l.push(sn);
                Ok(())
            })
            .await
        }
        "UI_ROUTE_SUBNET_UPDATE" => {
            let id = num("id")?;
            kea_edit(s, |l| {
                let sn = subnet_mut(l, id)?;
                *sn = subnet_from(get, id, Some(&sn.clone()));
                crate::shared::kea_conf::subnet_ddns_suffix(s, sn)
            })
            .await
        }
        "UI_ROUTE_SUBNET_REMOVE" => {
            let id = num("id")?;
            kea_edit(s, |l| {
                l.retain(|x| x["id"].as_u64() != Some(id));
                Ok(())
            })
            .await
        }
        "UI_ROUTE_SUBNET_OPTION_ADD" | "UI_ROUTE_SUBNET_OPTION_REMOVE" => {
            let (id, code) = (
                num("subnet_id")?,
                crate::shared::dhcp::option_code(&get("code"))?,
            );
            let data = get("data");
            kea_edit(s, |l| {
                let sn = subnet_mut(l, id)?;
                let mut opts = sn["option-data"].as_array().cloned().unwrap_or_default();
                let same = |o: &Value| o["code"].as_u64() == Some(u64::from(code));
                opts.retain(|o| !same(o) || !crate::shared::kea_conf::is_coded(o));
                if op == "UI_ROUTE_SUBNET_OPTION_ADD" {
                    opts.push(json!({"code": code, "data": data}));
                }
                sn["option-data"] = opts.into();
                Ok(())
            })
            .await
        }
        "UI_ROUTE_STATIC_ADD" | "UI_ROUTE_STATIC_REMOVE" => {
            let id = num("subnet_id")?;
            let (mac, ip, host) = (get("mac"), get("ip"), get("hostname"));
            kea_edit(s, |l| {
                let sn = subnet_mut(l, id)?;
                let mut hosts = sn["reservations"].as_array().cloned().unwrap_or_default();
                hosts.retain(|r| r["hw-address"].as_str() != Some(mac.as_str()));
                if op == "UI_ROUTE_STATIC_ADD" {
                    hosts.push(json!({"hw-address": mac, "ip-address": ip, "hostname": host}));
                }
                sn["reservations"] = hosts.into();
                Ok(())
            })
            .await
        }
        "UI_ROUTE_LEASE_RELEASE" => kea_api(s)?.release(&get("ip")).await,
        "UI_ROUTE_KEA_ROLLBACK" => {
            let cfg: Value = kea_store(s)?.read(&get("snapshot_id"))?;
            kea_api(s)?.set_config(cfg).await
        }
        _ => Err(tr("err_unknown_dhcp_action").replace("{op}", op)),
    }
}

// What: in mode off a running dhcp is stopped again.
// Why: compose up may start it after the ui.
// From: Issue #1683 | PR #1980
pub(crate) async fn dhcp_stays_off(app: &App, s: &Settings) -> Result<Option<String>, String> {
    let Some(service) = crate::shared::dhcp::off_service(s)? else {
        return Ok(None);
    };
    let (grace, limit) = app.limits(s)?;
    let list = project_containers(app, s).await?;
    let running = list.iter().find(|c| {
        docker::service_of(c) == Some(service.as_str()) && c["State"].as_str() == Some("running")
    });
    let Some(name) = running.and_then(docker::name_of) else {
        return Ok(None);
    };
    let r = app
        .docker
        .act(name, docker::Action::Stop, grace, limit)
        .await;
    Ok(Some(format!("mode off, stop {name} {r:?}")))
}

// What: one DHCP probe; the report as JSON.
// Why: runs on the host network, apart from the ui.
// From: Issue #1683 | PR #1985
pub(crate) fn dhcp_probe_cli(s: &Settings) -> Result<(), String> {
    let report = crate::shared::dhcp_probe::run(s);
    println!(
        "{}",
        serde_json::to_string(&report).map_err(|e| e.to_string())?
    );
    Ok(())
}
