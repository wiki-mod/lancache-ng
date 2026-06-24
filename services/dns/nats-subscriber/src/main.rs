use async_nats::jetstream;
use futures::StreamExt;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::HashMap;
use std::env;
use std::time::Duration;

#[derive(Debug, Serialize, Deserialize, Clone)]
struct DNSRecord {
    action: String,
    zone: String,
    name: String,
    #[serde(rename = "type")]
    record_type: String,
    ttl: i32,
    records: Vec<HashMap<String, serde_json::Value>>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
struct RRset {
    name: String,
    #[serde(rename = "type")]
    record_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    ttl: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    changetype: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    records: Option<Vec<HashMap<String, serde_json::Value>>>,
}

#[derive(Debug, Serialize, Deserialize)]
struct ZoneUpdate {
    rrsets: Vec<RRset>,
}

#[derive(Debug, Serialize, Deserialize)]
struct ZoneContent {
    content: String,
    disabled: bool,
}

#[derive(Debug, Serialize, Deserialize)]
struct ZoneRecord {
    name: String,
    #[serde(rename = "type")]
    record_type: String,
    ttl: i32,
    records: Vec<ZoneContent>,
}

#[derive(Debug, Serialize, Deserialize)]
struct ZoneInfo {
    rrsets: Vec<RRset>,
}

#[tokio::main]
async fn main() {
    let nats_url = env::var("NATS_URL").unwrap_or_else(|_| "nats://nats:4222".to_string());
    let nats_token = env::var("NATS_TOKEN").ok();
    let nats_consumer = match env::var("NATS_CONSUMER") {
        Ok(val) => val,
        Err(_) => {
            eprintln!("NATS_CONSUMER environment variable is required");
            std::process::exit(1);
        }
    };

    let pdns_api_key = match env::var("PDNS_API_KEY") {
        Ok(val) => val,
        Err(_) => {
            eprintln!("PDNS_API_KEY environment variable is required");
            std::process::exit(1);
        }
    };

    let nats_reconciler = env::var("NATS_RECONCILER").ok();

    // Connect to NATS with reconnect settings
    let mut opts = async_nats::ConnectOptions::new()
        .max_reconnects(None)
        .reconnect_delay_callback(|_| Duration::from_secs(3));

    if let Some(token) = nats_token {
        opts = opts.token(token);
    }

    let client = match opts.connect(&nats_url).await {
        Ok(conn) => conn,
        Err(e) => {
            eprintln!("Failed to connect to NATS: {}", e);
            std::process::exit(1);
        }
    };

    println!("Connected to NATS at {}", nats_url);

    // Get JetStream context
    let js = async_nats::jetstream::new(client);

    // Create or update stream LANCACHE_DNS
    let _stream = match js.get_stream("LANCACHE_DNS").await {
        Ok(s) => s,
        Err(_) => {
            match js
                .create_stream(jetstream::stream::Config {
                    name: "LANCACHE_DNS".to_string(),
                    subjects: vec!["lancache.dns.>".to_string()],
                    storage: jetstream::stream::StorageType::File,
                    max_age: Duration::from_secs(7 * 24 * 60 * 60),
                    discard: jetstream::stream::DiscardPolicy::Old,
                    ..Default::default()
                })
                .await
            {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("Failed to create stream: {}", e);
                    std::process::exit(1);
                }
            }
        }
    };

    println!("Stream LANCACHE_DNS ready");

    // Create or get durable pull consumer
    let consumer: async_nats::jetstream::consumer::Consumer<async_nats::jetstream::consumer::pull::Config> =
        match _stream.get_or_create_consumer(
            &nats_consumer,
            async_nats::jetstream::consumer::pull::Config {
                durable_name: Some(nats_consumer.clone()),
                filter_subject: "lancache.dns.>".to_string(),
                ..Default::default()
            }
        ).await {
            Ok(c) => c,
            Err(e) => {
                eprintln!("Failed to create consumer: {}", e);
                std::process::exit(1);
            }
        };

    println!("Created durable subscriber: {}", nats_consumer);

    // Start reconciler if enabled
    if nats_reconciler.as_deref() == Some("1") {
        let js_clone = js.clone();
        let pdns_api_key_clone = pdns_api_key.clone();
        tokio::spawn(async move {
            reconciler(js_clone, &pdns_api_key_clone).await;
        });
    }

    // Main fetch loop
    loop {
        let fetch_result = consumer.fetch()
            .max_messages(10)
            .expires(Duration::from_secs(5))
            .messages()
            .await;

        match fetch_result {
            Ok(mut messages) => {
                while let Some(msg_result) = messages.next().await {
                    match msg_result {
                        Ok(msg) => {
                            handle_message(&msg, &pdns_api_key).await;
                            if let Err(e) = msg.ack().await {
                                eprintln!("Error acknowledging message: {}", e);
                            }
                        }
                        Err(e) => eprintln!("Message error: {}", e),
                    }
                }
            }
            Err(e) => eprintln!("Fetch error: {}", e),
        }
    }
}

async fn handle_message(msg: &async_nats::jetstream::Message, pdns_api_key: &str) {
    let subject = msg.subject.as_ref();

    if subject.starts_with("lancache.dns.heartbeat") {
        // Ignore heartbeat messages
        return;
    }

    if subject == "lancache.dns.record" {
        handle_dns_record(msg, pdns_api_key).await;
        return;
    }

    if subject == "lancache.dns.flush" {
        handle_dns_flush(pdns_api_key).await;
        return;
    }

    println!("Unknown subject: {}", subject);
}

async fn handle_dns_record(msg: &async_nats::jetstream::Message, pdns_api_key: &str) {
    let record: DNSRecord = match serde_json::from_slice(&msg.payload) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("Error parsing DNS record: {}", e);
            return;
        }
    };

    let (changetype, ttl_val, records_val) = match record.action.as_str() {
        "delete" => (Some("DELETE".to_string()), None, None),
        "replace" => (
            Some("REPLACE".to_string()),
            Some(record.ttl),
            Some(record.records.clone()),
        ),
        action => {
            eprintln!("Unknown action: {}", action);
            return;
        }
    };

    let rrset = RRset {
        name: record.name.clone(),
        record_type: record.record_type.clone(),
        ttl: ttl_val,
        changetype,
        records: records_val,
    };

    let update = ZoneUpdate {
        rrsets: vec![rrset],
    };

    let payload = match serde_json::to_string(&update) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("Error marshaling PATCH payload: {}", e);
            return;
        }
    };

    let url = format!(
        "http://127.0.0.1:8081/api/v1/servers/localhost/zones/{}",
        record.zone
    );

    let client = Client::new();
    let result = client
        .patch(&url)
        .header("X-API-Key", pdns_api_key)
        .header("Content-Type", "application/json")
        .body(payload)
        .timeout(Duration::from_secs(10))
        .send()
        .await;

    match result {
        Ok(resp) => {
            if resp.status().is_success() {
                println!(
                    "Updated DNS record: zone={} name={} type={} action={}",
                    record.zone, record.name, record.record_type, record.action
                );
            } else {
                eprintln!(
                    "PDNS error: {} {} for zone={} name={} type={}",
                    resp.status(),
                    resp.status().canonical_reason().unwrap_or(""),
                    record.zone,
                    record.name,
                    record.record_type
                );
            }
        }
        Err(e) => {
            eprintln!("Error sending PATCH request: {}", e);
        }
    }
}

async fn handle_dns_flush(pdns_api_key: &str) {
    let url = "http://127.0.0.1:8082/api/v1/servers/localhost/cache/flush?type=packet";

    let client = Client::new();
    let result = client
        .put(url)
        .header("X-API-Key", pdns_api_key)
        .timeout(Duration::from_secs(10))
        .send()
        .await;

    match result {
        Ok(resp) => {
            if resp.status().is_success() {
                println!("Flushed PDNS cache");
            } else {
                eprintln!(
                    "PDNS flush error: {} {}",
                    resp.status(),
                    resp.status().canonical_reason().unwrap_or("")
                );
            }
        }
        Err(e) => {
            eprintln!("Error sending flush request: {}", e);
        }
    }
}

async fn reconciler(js: async_nats::jetstream::Context, pdns_api_key: &str) {
    let mut interval = tokio::time::interval(Duration::from_secs(60));

    loop {
        interval.tick().await;

        let url = "http://127.0.0.1:8081/api/v1/servers/localhost/zones/lan";

        let client = Client::new();
        let result = client
            .get(url)
            .header("X-API-Key", pdns_api_key)
            .timeout(Duration::from_secs(10))
            .send()
            .await;

        match result {
            Ok(resp) => {
                if !resp.status().is_success() {
                    eprintln!(
                        "Reconciler: PDNS error: {} {}",
                        resp.status(),
                        resp.status().canonical_reason().unwrap_or("")
                    );
                    continue;
                }

                let zone_info: ZoneInfo = match resp.json().await {
                    Ok(zi) => zi,
                    Err(e) => {
                        eprintln!("Reconciler: error decoding zone info: {}", e);
                        continue;
                    }
                };

                for rrset in &zone_info.rrsets {
                    if rrset.record_type == "SOA" || rrset.record_type == "NS" {
                        continue;
                    }

                    let msg_id = format!(
                        "reconcile-lan-{}-{}",
                        rrset.name.trim_end_matches('.'),
                        rrset.record_type
                    );

                    let record_payload = json!({
                        "action": "replace",
                        "zone": "lan",
                        "name": rrset.name,
                        "type": rrset.record_type,
                        "ttl": rrset.ttl,
                        "records": rrset.records,
                    });

                    let payload = match serde_json::to_vec(&record_payload) {
                        Ok(p) => p,
                        Err(e) => {
                            eprintln!("Reconciler: error marshaling record: {}", e);
                            continue;
                        }
                    };

                    let mut headers = async_nats::HeaderMap::new();
                    headers.insert(async_nats::header::NATS_MESSAGE_ID, msg_id.as_str());

                    match js
                        .publish_with_headers("lancache.dns.record", headers, payload.into())
                        .await
                    {
                        Ok(_) => {}
                        Err(e) => {
                            eprintln!("Reconciler: error publishing record: {}", e);
                        }
                    }
                }

                println!("Reconciler: published {} records", zone_info.rrsets.iter().filter(|r| r.record_type != "SOA" && r.record_type != "NS").count());
            }
            Err(e) => {
                eprintln!("Reconciler: error fetching zone: {}", e);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // PDNS GET /zones/{zone} responses do NOT include changetype.
    // This test guards against regressions where changetype becomes
    // a required field again, which would break the reconciler.
    #[test]
    fn zone_info_deserializes_without_changetype() {
        let json = r#"{
            "rrsets": [
                {"name": "test.lan.", "type": "A", "ttl": 300, "records": [{"content": "192.168.1.1", "disabled": false}]},
                {"name": "test.lan.", "type": "SOA", "ttl": 3600, "records": [{"content": "ns1.lan. admin.lan. 1 3600 900 604800 60", "disabled": false}]}
            ]
        }"#;
        let info: ZoneInfo = serde_json::from_str(json).expect("ZoneInfo must deserialize without changetype");
        assert_eq!(info.rrsets.len(), 2);
        assert!(info.rrsets[0].changetype.is_none());
    }

    // PDNS PATCH requests require changetype to be present and serialized.
    #[test]
    fn rrset_serializes_with_changetype_for_patch() {
        let rrset = RRset {
            name: "host.lan.".to_string(),
            record_type: "A".to_string(),
            ttl: Some(300),
            changetype: Some("REPLACE".to_string()),
            records: Some(vec![]),
        };
        let json = serde_json::to_string(&rrset).expect("RRset must serialize");
        assert!(json.contains("changetype"));
        assert!(json.contains("REPLACE"));
    }

    // skip_serializing_if must suppress changetype when None (GET context).
    #[test]
    fn rrset_omits_changetype_when_none() {
        let rrset = RRset {
            name: "host.lan.".to_string(),
            record_type: "A".to_string(),
            ttl: Some(300),
            changetype: None,
            records: None,
        };
        let json = serde_json::to_string(&rrset).expect("RRset must serialize");
        assert!(!json.contains("changetype"));
    }

    #[test]
    fn dns_record_deserializes_from_nats_message() {
        let json = r#"{
            "action": "replace",
            "zone": "lan",
            "name": "myhost.lan.",
            "type": "A",
            "ttl": 60,
            "records": [{"content": "10.0.0.5", "disabled": false}]
        }"#;
        let record: DNSRecord = serde_json::from_str(json).expect("DNSRecord must deserialize");
        assert_eq!(record.action, "replace");
        assert_eq!(record.zone, "lan");
    }
}
