//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//! HTTP client for querying nginx stub_status metrics and parsing access logs.

use regex::Regex;
use serde::Serialize;
use std::collections::{HashSet, VecDeque};
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

// nginx's stub_status module always renders exactly this 4-line, fixed-field
// text format (see http://nginx.org/en/docs/http/ngx_http_stub_status_module.html):
//   Active connections: N
//   server accepts handled requests
//    A H R
//   Reading: X Writing: Y Waiting: Z
// The "accepts handled requests" line is a label; its three numbers are on
// the line *after* it, which is why that branch looks at `lines[i + 1]`
// instead of the matched line itself.
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

// Streams the file line-by-line rather than reading it fully into memory,
// keeping only the last `limit` lines in a bounded ring buffer (VecDeque).
// Access logs can grow to gigabytes, so this avoids holding the whole file
// in memory just to show the operator its most recent entries.
pub fn parse_log_tail(path: &str, limit: usize) -> Vec<LogEntry> {
    if limit == 0 {
        return vec![];
    }

    let Ok(file) = File::open(path) else {
        return vec![];
    };

    let reader = BufReader::new(file);
    let re = log_regex();
    let mut tail = VecDeque::with_capacity(limit);

    for line in reader.lines().map_while(Result::ok) {
        if tail.len() == limit {
            tail.pop_front();
        }
        tail.push_back(line);
    }

    tail.iter()
        .filter_map(|line| parse_log_line(re, line))
        .collect()
}

pub fn get_log_stats(standard_log: &str, ssl_log: &str) -> LogStats {
    let re = log_regex();
    let mut stats = LogStats::default();
    let mut total_bytes: u64 = 0;

    // Standard and SSL proxy traffic now share one cache but still write
    // separate access logs. De-duplicate paths so deployments that point both
    // modes at the same log file are not counted twice.
    for path in unique_paths([standard_log, ssl_log]) {
        let Ok(file) = File::open(path) else { continue };
        let reader = BufReader::new(file);
        for line in reader.lines().map_while(Result::ok) {
            let Some(caps) = re.captures(&line) else {
                continue;
            };
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
    // Validate path: must be absolute and within allowed directories
    use std::path::Path;
    let path_obj = Path::new(path);

    // Must be an absolute path
    if !path_obj.is_absolute() {
        return 0.0;
    }

    // Normalize the path to prevent traversal attacks (e.g., /opt/lancache-ng/cache/../evil)
    // Reject any path containing ".." components
    if path.contains("..") {
        return 0.0;
    }

    // Only allow supported cache locations. /opt/lancache-ng is the normal
    // production install path; /var/cache and /data remain container/dev
    // paths. There is only one shared CACHE_DIR as of v0.2.0 (no per-mode
    // standard/ssl subdirectory split), so this list intentionally has no
    // "/standard" or "/ssl" suffixed entries.
    let allowed_prefixes = [
        "/opt/lancache-ng/cache",
        "/var/cache/proxy",
        "/data/lancache",
    ];
    if !allowed_prefixes
        .iter()
        .any(|prefix| path.starts_with(prefix))
    {
        return 0.0;
    }

    // Shells out to `du` rather than walking the tree in Rust: recursively
    // summing file sizes for a cache directory that can hold hundreds of GB
    // across many files is exactly what `du` is optimized for. This blocks
    // the calling thread, which is why routes/dashboard.rs runs it inside
    // `tokio::task::spawn_blocking` instead of calling it directly from an
    // async handler.
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

fn unique_paths<'a>(paths: impl IntoIterator<Item = &'a str>) -> Vec<&'a str> {
    let mut seen = HashSet::new();
    let mut unique = Vec::new();

    for path in paths {
        if seen.insert(path) {
            unique.push(path);
        }
    }

    unique
}

// Matches nginx's custom lancache log_format (see services/proxy/nginx.conf).
// Capture groups, in order:
//   1: client IP        2: timestamp       3: HTTP method
//   4: request path     5: HTTP status     6: response bytes
//   7: cache status (nginx $upstream_cache_status: HIT/MISS/EXPIRED/...)
//   8: request Host header
// `parse_log_line` and `get_log_stats` both index into `caps[N]` using these
// fixed positions, so the group count/order here and the log_format
// directive in nginx.conf must stay in sync.
fn log_regex() -> &'static Regex {
    LOG_REGEX.get_or_init(|| {
        Regex::new(r#"^(\S+) - \[([^\]]+)\] "(\S+) (\S+) [^"]+" (\d+) (\d+) "([^"]*)" "([^"]*)""#)
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::Write;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn shared_log_path_is_counted_once() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before unix epoch")
            .as_nanos();
        let path = std::env::temp_dir().join(format!("lancache-ui-shared-log-{unique}.log"));
        let mut file = File::create(&path).expect("create temp log");
        writeln!(
            file,
            r#"127.0.0.1 - [29/Jun/2026:00:00:00 +0000] "GET /foo HTTP/1.1" 200 1024 "HIT" "example.com""#
        )
        .expect("write temp log");
        drop(file);

        let path = path.to_string_lossy().to_string();
        let stats = get_log_stats(&path, &path);
        assert_eq!(stats.total_requests, 1);
        assert_eq!(stats.hits, 1);
        assert_eq!(stats.misses, 0);

        fs::remove_file(path).expect("remove temp log");
    }
}
