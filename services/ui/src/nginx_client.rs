use regex::Regex;
use serde::Serialize;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::process::Command;
use std::sync::OnceLock;

static LOG_REGEX: OnceLock<Regex> = OnceLock::new();
static STUB_STATUS_REGEX: OnceLock<Regex> = OnceLock::new();

#[derive(Debug, Serialize, Default, Clone)]
pub struct NginxStatus {
    pub active: u64,
    pub accepts: u64,
    pub handled: u64,
    pub requests: u64,
    pub reading: u64,
    pub writing: u64,
    pub waiting: u64,
}

pub async fn get_stub_status(client: &reqwest::Client, base_url: &str) -> Option<NginxStatus> {
    let url = format!("{}/nginx_status", base_url);
    let text = client
        .get(&url)
        .timeout(std::time::Duration::from_secs(3))
        .send()
        .await
        .ok()?
        .text()
        .await
        .ok()?;
    parse_stub_status(&text)
}

fn parse_stub_status(text: &str) -> Option<NginxStatus> {
    let mut s = NginxStatus::default();
    let lines: Vec<&str> = text.lines().collect();
    for (i, line) in lines.iter().enumerate() {
        if line.starts_with("Active connections:") {
            // unwrap_or so a single bad line doesn't abort parsing all other fields
            s.active = line
                .split_whitespace()
                .last()
                .and_then(|n| n.parse().ok())
                .unwrap_or(0);
        } else if line.contains("accepts") && line.contains("handled") {
            if let Some(nums_line) = lines.get(i + 1) {
                let nums: Vec<u64> = nums_line
                    .split_whitespace()
                    .filter_map(|n| n.parse().ok())
                    .collect();
                if nums.len() >= 3 {
                    s.accepts = nums[0];
                    s.handled = nums[1];
                    s.requests = nums[2];
                }
            }
        } else if line.starts_with("Reading:") {
            let re = stub_status_regex();
            if let Some(caps) = re.captures(line) {
                s.reading = caps[1].parse().unwrap_or(0);
                s.writing = caps[2].parse().unwrap_or(0);
                s.waiting = caps[3].parse().unwrap_or(0);
            }
        }
    }
    Some(s)
}

#[derive(Debug, Serialize, Clone)]
pub struct LogEntry {
    pub ip: String,
    pub time: String,
    pub method: String,
    pub path: String,
    pub host: String,
    pub status: u16,
    pub bytes_human: String,
    pub cache_status: String,
    pub source: String,
}

#[derive(Debug, Serialize, Default, Clone)]
pub struct LogStats {
    pub hits: u64,
    pub misses: u64,
    pub expired: u64,
    pub other: u64,
    pub total_bytes_gb: f64,
    pub total_requests: u64,
    pub hit_pct: f64,
}

pub fn parse_log_tail(path: &str, limit: usize) -> Vec<LogEntry> {
    let Ok(file) = File::open(path) else {
        return vec![];
    };
    let reader = BufReader::new(file);
    let re = log_regex();

    let lines: Vec<String> = reader.lines().filter_map(|l| l.ok()).collect();
    let start = lines.len().saturating_sub(limit);

    lines[start..]
        .iter()
        .filter_map(|line| parse_log_line(re, line))
        .collect()
}

pub fn get_log_stats(standard_log: &str, ssl_log: &str) -> LogStats {
    let re = log_regex();
    let mut stats = LogStats::default();
    let mut total_bytes: u64 = 0;

    for path in [standard_log, ssl_log] {
        let Ok(file) = File::open(path) else { continue };
        let reader = BufReader::new(file);
        for line in reader.lines().filter_map(|l| l.ok()) {
            let Some(caps) = re.captures(&line) else { continue };
            let bytes: u64 = caps[6].parse().unwrap_or(0);
            let cache_status = &caps[7];
            stats.total_requests += 1;
            total_bytes += bytes;
            match cache_status {
                "HIT" => stats.hits += 1,
                "MISS" => stats.misses += 1,
                "EXPIRED" => stats.expired += 1,
                _ => stats.other += 1,
            }
        }
    }

    stats.total_bytes_gb = total_bytes as f64 / 1_073_741_824.0;
    stats.hit_pct = if stats.total_requests > 0 {
        (stats.hits as f64 / stats.total_requests as f64) * 100.0
    } else {
        0.0
    };
    stats
}

pub fn get_cache_size_gb(path: &str) -> f64 {
    let output = Command::new("du").args(["-sb", path]).output();
    match output {
        Ok(out) => {
            let bytes: u64 = String::from_utf8_lossy(&out.stdout)
                .split_whitespace()
                .next()
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
            bytes as f64 / 1_073_741_824.0
        }
        Err(_) => 0.0,
    }
}

fn log_regex() -> &'static Regex {
    LOG_REGEX.get_or_init(|| {
        Regex::new(
            r#"^(\S+) - \[([^\]]+)\] "(\S+) (\S+) [^"]+" (\d+) (\d+) "([^"]*)" "([^"]*)""#,
        )
        .expect("log regex is valid")
    })
}

fn stub_status_regex() -> &'static Regex {
    STUB_STATUS_REGEX.get_or_init(|| {
        Regex::new(r"Reading: (\d+) Writing: (\d+) Waiting: (\d+)").expect("stub regex is valid")
    })
}

fn parse_log_line(re: &Regex, line: &str) -> Option<LogEntry> {
    let caps = re.captures(line)?;
    let bytes: u64 = caps[6].parse().unwrap_or(0);
    Some(LogEntry {
        ip: caps[1].to_string(),
        time: caps[2].to_string(),
        method: caps[3].to_string(),
        path: caps[4].to_string(),
        host: caps[8].to_string(),
        status: caps[5].parse().unwrap_or(0),
        bytes_human: format_bytes(bytes),
        cache_status: caps[7].to_string(),
        source: String::new(),
    })
}

fn format_bytes(b: u64) -> String {
    const KB: u64 = 1_024;
    const MB: u64 = 1_048_576;
    const GB: u64 = 1_073_741_824;
    if b >= GB {
        format!("{:.1} GB", b as f64 / GB as f64)
    } else if b >= MB {
        format!("{:.1} MB", b as f64 / MB as f64)
    } else if b >= KB {
        format!("{:.1} KB", b as f64 / KB as f64)
    } else {
        format!("{} B", b)
    }
}
