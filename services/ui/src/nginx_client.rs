//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//! HTTP client for querying nginx stub_status metrics and parsing access logs.

use regex::Regex;
use serde::Serialize;
use std::collections::HashSet;
use std::fs::File;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::process::Command;
use std::sync::OnceLock;

// Backward-read chunk size for `parse_log_tail`. A typical nginx access log
// line here is ~150-300 bytes, so 64 KiB comfortably covers the largest
// `limit` any caller passes today (200, from routes/logs.rs) in a single
// read; larger `limit`s just cost one or two extra reads rather than a full
// linear scan. Small enough to avoid ever reading more than a tiny fraction
// of a multi-GB log for a normal tail request.
const TAIL_CHUNK_SIZE: u64 = 64 * 1024;

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

// Reads only the last `limit` lines of the file, seeking from the end and
// pulling fixed-size chunks backwards (`read_last_lines`) instead of
// scanning every line from byte 0. Issue #75 already fixed the *memory*
// side of this (a bounded ring buffer instead of loading the whole file
// into one String); this fixes the remaining *time* side — every `/logs`
// or dashboard page load used to be O(total log size) even though it only
// ever wants the last 10-200 lines. Access logs can grow to gigabytes, so
// both properties matter.
//
// Returned lines are in the same order the previous forward-scanning
// implementation produced: oldest-first within the tail window (i.e. plain
// file order, restricted to the last `limit` lines). Callers rely on this —
// routes/logs.rs reverses the result itself to show newest-first, and
// templates/dashboard.html documents that this function's output is
// "simply the tail of the file". Do not reverse the order here; that would
// silently double-reverse the logs.rs case.
pub fn parse_log_tail(path: &str, limit: usize) -> Vec<LogEntry> {
    if limit == 0 {
        return vec![];
    }

    let Ok(mut file) = File::open(path) else {
        return vec![];
    };

    let re = log_regex();
    read_last_lines(&mut file, limit)
        .iter()
        .filter_map(|line| parse_log_line(re, line))
        .collect()
}

// Returns up to `limit` complete lines from the end of `file`, in file
// order (oldest of the returned lines first). Never reads more of the file
// than necessary: it seeks to EOF and pulls `TAIL_CHUNK_SIZE` chunks
// backwards, growing a byte buffer leftward, until either enough newlines
// have been seen or byte 0 is reached.
fn read_last_lines(file: &mut File, limit: usize) -> Vec<String> {
    let Ok(file_len) = file.seek(SeekFrom::End(0)) else {
        return vec![];
    };
    if file_len == 0 {
        return vec![];
    }

    let mut buffer: Vec<u8> = Vec::new();
    let mut pos = file_len;

    loop {
        // Requiring strictly MORE than `limit` newlines (not >=) before
        // stopping leaves one line of margin. Without it, the leading
        // segment of `buffer` — which we always discard below because a
        // chunk boundary may have split it mid-line — could be the one
        // that was needed to reach exactly `limit` complete lines,
        // producing an off-by-one short result.
        let newline_count = buffer.iter().filter(|&&b| b == b'\n').count();
        if pos == 0 || newline_count > limit {
            break;
        }

        let chunk_len = TAIL_CHUNK_SIZE.min(pos);
        pos -= chunk_len;

        if file.seek(SeekFrom::Start(pos)).is_err() {
            break;
        }
        let mut chunk = vec![0u8; chunk_len as usize];
        // A short/failed read here would silently corrupt the reconstructed
        // tail (bytes missing from the middle), so bail out to whatever
        // complete lines are already in `buffer` rather than risk that.
        if file.read_exact(&mut chunk).is_err() {
            break;
        }
        chunk.extend_from_slice(&buffer);
        buffer = chunk;
    }

    // `buffer` now holds a contiguous byte range [pos, file_len) of the
    // file, i.e. bytes 0..file_len if we walked all the way to the start.
    let reached_start = pos == 0;
    let ends_with_newline = buffer.last() == Some(&b'\n');

    let mut segments: Vec<&[u8]> = buffer.split(|&b| b == b'\n').collect();

    // A trailing '\n' (the common case: every complete line, including the
    // last, is newline-terminated) produces one spurious empty segment
    // after the final delimiter — drop it, it is not a line.
    if ends_with_newline {
        segments.pop();
    }

    // Unless the buffer starts at byte 0 of the file, its first segment's
    // beginning was cut off by our chunk boundary and is not a real line —
    // the true start of that line is further left, outside `buffer`.
    if !reached_start && !segments.is_empty() {
        segments.remove(0);
    }

    let start_idx = segments.len().saturating_sub(limit);
    segments[start_idx..]
        .iter()
        .map(|s| bytes_to_line(s))
        .collect()
}

// Strips a trailing '\r' (CRLF logs) to mirror `BufRead::lines()`'s
// line-ending handling, and uses a lossy UTF-8 conversion — rather than
// discarding the line or propagating an error — so a single malformed byte
// sequence anywhere in the tail window can't panic or (as the old
// `map_while(Result::ok)` forward scan effectively did) truncate every line
// after it; invalid sequences become U+FFFD and the line is still returned,
// though `parse_log_line`'s regex will typically then just fail to match it.
fn bytes_to_line(bytes: &[u8]) -> String {
    let bytes = bytes.strip_suffix(b"\r").unwrap_or(bytes);
    String::from_utf8_lossy(bytes).into_owned()
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
        // Handle each line's Result explicitly instead of `map_while(Result::ok)`:
        // that combinator stops the whole iterator dead at the first Err (e.g. a
        // line with invalid UTF-8, which raw/unescaped request paths or user-agents
        // in nginx access logs can produce), silently undercounting every request
        // after it. `continue`-ing past a bad line keeps the aggregate scan going.
        for line in reader.lines() {
            let Ok(line) = line else { continue };
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

// Validates a cache path: must be an absolute path, must not contain ".."
// components (traversal guard, e.g. "/opt/lancache-ng/cache/../evil"), and
// must fall under one of the paths this deployment is actually known to
// mount the cache at. Shared by get_cache_size_gb (below) and
// available_space_mib_at (issue #1069 part 3's resize disk-space check) --
// both need the identical safety check before shelling out a command against
// an operator/config-controlled path.
fn is_allowed_cache_path(path: &str) -> bool {
    use std::path::Path;
    let path_obj = Path::new(path);

    if !path_obj.is_absolute() {
        return false;
    }

    if path.contains("..") {
        return false;
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
    allowed_prefixes
        .iter()
        .any(|prefix| path.starts_with(prefix))
}

pub fn get_cache_size_gb(path: &str) -> f64 {
    if !is_allowed_cache_path(path) {
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

// Free space, in whole MiB, on the filesystem backing `path` -- the Rust
// counterpart to setup.sh's `available_space_mib_at` (issue #1069 part 3:
// the Admin UI resize control re-validates against real free disk space at
// resize time, the same buffer-scaled check setup.sh's initial "Cache size
// in GiB" prompt already enforces at install time). Uses `df -Pk` (POSIX
// output format, 1024-byte blocks) for the same reason setup.sh's version
// does: plain `df`'s column layout can wrap onto a second line for a long
// device/mount source string, which would otherwise shift the field this
// parses.
//
// Unlike setup.sh's version, this does not walk up to the nearest existing
// ancestor directory: the Admin UI only ever calls this with CACHE_DIR
// (`state.config.cache_dir`), which is always an already-mounted, already-
// existing Docker volume by the time this container is running -- there is
// no "not created yet" case here the way there is during setup.sh's initial
// install prompt.
//
// Returns None if the path fails is_allowed_cache_path, `df` cannot run, or
// its output doesn't parse -- callers must fail closed on None (treat it as
// "cannot validate", never as "unlimited free space").
pub fn available_space_mib_at(path: &str) -> Option<u64> {
    if !is_allowed_cache_path(path) {
        return None;
    }

    let output = Command::new("df").args(["-Pk", path]).output().ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout);
    // POSIX `df -P` output: a header line, then "Filesystem 1024-blocks Used
    // Available Capacity Mounted-on" -- the 4th whitespace-separated field
    // (index 3) on the second line is "Available" in KiB.
    let avail_kib: u64 = text
        .lines()
        .nth(1)?
        .split_whitespace()
        .nth(3)?
        .parse()
        .ok()?;
    Some(avail_kib / 1024)
}

// Maintainer-directed safety buffer (issue #1069), kept in exact sync with
// setup.sh's own `cache_size_buffer_mib`: nginx's cache manager sweeps
// periodically rather than enforcing max_size instantaneously
// (manager_sleep/manager_threshold on proxy_cache_path), so actual disk
// usage can transiently overshoot max_size by roughly one sweep's worth of
// writes before cleanup catches up -- and a larger declared cache means more
// concurrent downloads can land in that window before the manager gets to
// them. If this ever changes, update both this function and setup.sh's
// cache_size_buffer_mib together, or the CLI and Admin UI would silently
// enforce different safety margins for the identical operation.
pub fn cache_size_buffer_mib(cache_gb: u64) -> u64 {
    if cache_gb > 6 {
        2048
    } else if cache_gb > 4 {
        1024
    } else {
        512
    }
}

// True if requesting cache_gb GiB still leaves cache_size_buffer_mib's
// required buffer free on a filesystem with avail_mib MiB currently free.
// Signed arithmetic (i64, not u64) mirrors setup.sh's `(( avail_mib -
// buffer_mib >= cache_gb * 1024 ))`: on a nearly-full disk, avail_mib can be
// smaller than buffer_mib, and an unsigned subtraction would panic/wrap
// instead of correctly evaluating to "does not fit".
pub fn cache_size_fits_available_mib(cache_gb: u64, avail_mib: u64) -> bool {
    let buffer_mib = cache_size_buffer_mib(cache_gb) as i64;
    let avail_mib = avail_mib as i64;
    let cache_gb = cache_gb as i64;
    avail_mib - buffer_mib >= cache_gb * 1024
}

// Largest whole-GiB cache size that currently passes
// cache_size_fits_available_mib, for the rejection message -- mirrors
// setup.sh's `largest_valid_cache_gb`. Scans downward from the free-space
// ceiling rather than solving the step-function buffer bands in closed
// form: the buffer only grows as the requested size grows, so the scan is
// short (bounded by the disk's own size in GiB) and this stays obviously
// correct instead of clever. Returns None if even a 1 GiB cache would not
// leave a buffer.
pub fn largest_valid_cache_gb(avail_mib: u64) -> Option<u64> {
    let mut candidate = avail_mib / 1024;
    while candidate >= 1 {
        if cache_size_fits_available_mib(candidate, avail_mib) {
            return Some(candidate);
        }
        candidate -= 1;
    }
    None
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

    // ── Cache-resize disk-space/buffer logic (issue #1069 part 3) ──────────
    // These mirror setup.sh's own bats coverage for cache_size_buffer_mib /
    // cache_size_fits_available_mib / largest_valid_cache_gb (see
    // tests/bats/setup_cache_size_disk_validation.bats on master, #1070) --
    // boundary values must match exactly, since both implementations are
    // supposed to enforce the identical maintainer-directed safety buffer.

    #[test]
    fn buffer_is_2048_mib_above_6_gib() {
        assert_eq!(cache_size_buffer_mib(7), 2048);
        assert_eq!(cache_size_buffer_mib(100), 2048);
    }

    #[test]
    fn buffer_is_1024_mib_at_the_6_gib_boundary_and_down_to_just_above_4() {
        // Exactly 6 is NOT "> 6", so it falls into the 1024 MiB band, not the
        // 2048 MiB one -- this boundary case is the one most likely to get
        // an off-by-one if the comparison operator is ever touched.
        assert_eq!(cache_size_buffer_mib(6), 1024);
        assert_eq!(cache_size_buffer_mib(5), 1024);
    }

    #[test]
    fn buffer_is_512_mib_at_4_gib_and_below() {
        assert_eq!(cache_size_buffer_mib(4), 512);
        assert_eq!(cache_size_buffer_mib(1), 512);
    }

    #[test]
    fn fits_available_true_when_buffer_leaves_room() {
        // 50 GiB requested (buffer 2048 MiB) against 55 GiB free:
        // 55*1024 - 2048 = 54272 >= 50*1024 = 51200.
        assert!(cache_size_fits_available_mib(50, 55 * 1024));
    }

    #[test]
    fn fits_available_false_when_buffer_would_be_violated() {
        // 50 GiB requested against exactly 50 GiB free leaves no room at all
        // for the 2048 MiB buffer.
        assert!(!cache_size_fits_available_mib(50, 50 * 1024));
    }

    // Regression guard for the exact bug the signed-arithmetic comment
    // documents: on a disk with LESS free space than the buffer itself
    // requires, an unsigned subtraction would panic/wrap instead of
    // evaluating to "does not fit".
    #[test]
    fn fits_available_false_without_panicking_when_disk_smaller_than_buffer() {
        assert!(!cache_size_fits_available_mib(10, 100));
    }

    #[test]
    fn largest_valid_scans_down_to_a_passing_value() {
        // 20 GiB free: at cache_gb=20 (buffer 2048), 20*1024-2048=18432 <
        // 20*1024=20480, fails. Keep scanning down until it passes.
        let largest = largest_valid_cache_gb(20 * 1024).expect("some size should fit");
        assert!(cache_size_fits_available_mib(largest, 20 * 1024));
        // One GiB larger must NOT fit, or `largest` was not actually the max.
        assert!(!cache_size_fits_available_mib(largest + 1, 20 * 1024));
    }

    #[test]
    fn largest_valid_none_when_even_1_gib_does_not_fit() {
        // 400 MiB free is less than even the smallest (512 MiB) buffer band.
        assert_eq!(largest_valid_cache_gb(400), None);
    }

    #[test]
    fn allowed_cache_path_rejects_traversal_and_relative_paths() {
        assert!(!is_allowed_cache_path("relative/path"));
        assert!(!is_allowed_cache_path("/var/cache/proxy/../etc/passwd"));
        assert!(!is_allowed_cache_path("/etc/passwd"));
    }

    #[test]
    fn allowed_cache_path_accepts_known_prefixes() {
        assert!(is_allowed_cache_path("/var/cache/proxy"));
        assert!(is_allowed_cache_path("/opt/lancache-ng/cache"));
        assert!(is_allowed_cache_path("/data/lancache"));
    }

    #[test]
    fn available_space_mib_at_rejects_disallowed_path() {
        // Must fail closed via is_allowed_cache_path before ever shelling out
        // to `df`, regardless of whether the path exists on this host.
        assert_eq!(available_space_mib_at("/etc"), None);
    }

    #[test]
    fn available_space_mib_at_parses_a_real_mount() {
        // /var/cache/proxy itself may not exist on the test host, but its
        // parent tree does on any Linux CI runner -- df resolves to the
        // nearest existing mount point either way, same as a real container.
        // This just proves the df-output parsing path works end to end; the
        // exact free-space number is host-dependent and not asserted.
        let result = available_space_mib_at("/var/cache/proxy");
        // On a host where /var doesn't exist at all (never true for a real
        // Linux CI runner, but keeps this test from being flaky if it ever
        // runs somewhere unusual), a None is acceptable -- what must NOT
        // happen is a panic.
        if let Some(mib) = result {
            assert!(mib > 0);
        }
    }

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

    // `reader.lines().map_while(Result::ok)` stops the ENTIRE scan at the first
    // line BufRead can't decode as UTF-8, so every valid line after a single
    // corrupt one would go uncounted. nginx access logs can contain raw,
    // unescaped bytes in request paths/user-agents, so a mid-file invalid-UTF-8
    // line is a realistic occurrence, not an edge case.
    #[test]
    fn bad_line_in_middle_does_not_truncate_stats() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before unix epoch")
            .as_nanos();
        let path = std::env::temp_dir().join(format!("lancache-ui-badline-log-{unique}.log"));

        let mut bytes: Vec<u8> = Vec::new();
        bytes.extend_from_slice(
            b"127.0.0.1 - [29/Jun/2026:00:00:00 +0000] \"GET /a HTTP/1.1\" 200 100 \"HIT\" \"example.com\"\n",
        );
        // Invalid UTF-8 bytes (0xFF, 0xFE are never valid anywhere in UTF-8),
        // simulating a raw byte sequence nginx can log verbatim from a request.
        bytes.extend_from_slice(b"127.0.0.1 - [29/Jun/2026:00:00:01 +0000] \"GET /\xFF\xFE HTTP/1.1\" 200 200 \"MISS\" \"example.com\"\n");
        bytes.extend_from_slice(
            b"127.0.0.1 - [29/Jun/2026:00:00:02 +0000] \"GET /b HTTP/1.1\" 200 300 \"HIT\" \"example.com\"\n",
        );
        bytes.extend_from_slice(
            b"127.0.0.1 - [29/Jun/2026:00:00:03 +0000] \"GET /c HTTP/1.1\" 200 400 \"EXPIRED\" \"example.com\"\n",
        );
        std::fs::write(&path, &bytes).expect("write temp log with invalid utf-8 line");

        let path = path.to_string_lossy().to_string();
        let stats = get_log_stats(&path, &path);

        // Only 3 of the 4 lines are decodable; the invalid-UTF-8 line is skipped,
        // but the two valid lines written AFTER it must still be counted.
        assert_eq!(stats.total_requests, 3);
        assert_eq!(stats.hits, 2);
        assert_eq!(stats.expired, 1);
        assert_eq!(stats.misses, 0);

        fs::remove_file(path).expect("remove temp log");
    }

    // Unique temp-file path per test, mirroring `shared_log_path_is_counted_once`'s
    // pattern above; the nanosecond suffix avoids collisions between tests
    // running in parallel in the same process.
    fn temp_log_path(label: &str) -> std::path::PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before unix epoch")
            .as_nanos();
        std::env::temp_dir().join(format!("lancache-ui-tail-{label}-{unique}.log"))
    }

    #[test]
    fn parse_log_tail_missing_file_returns_empty() {
        // `File::open` fails for a nonexistent path; `parse_log_tail` must
        // return an empty Vec rather than panicking, since a proxy log file
        // may not exist yet on a fresh deployment.
        let result = parse_log_tail("/nonexistent/path/does-not-exist.log", 10);
        assert!(result.is_empty());
    }

    #[test]
    fn read_last_lines_empty_file_returns_empty() {
        let path = temp_log_path("empty");
        File::create(&path).expect("create empty temp log");

        let mut file = File::open(&path).expect("reopen temp log");
        let lines = read_last_lines(&mut file, 10);
        assert!(lines.is_empty());

        fs::remove_file(path).expect("remove temp log");
    }

    #[test]
    fn read_last_lines_smaller_than_chunk_returns_all_in_order() {
        // File is far smaller than TAIL_CHUNK_SIZE, so the whole thing is
        // read in a single backward chunk (`pos` reaches 0 immediately).
        // Requesting more lines than exist must return exactly what exists,
        // in the same oldest-first file order the old forward scan used.
        let path = temp_log_path("small");
        let mut file = File::create(&path).expect("create temp log");
        for i in 0..5 {
            writeln!(
                file,
                r#"127.0.0.1 - [29/Jun/2026:00:00:00 +0000] "GET /foo/{i} HTTP/1.1" 200 1024 "HIT" "example.com""#
            )
            .expect("write temp log");
        }
        drop(file);

        let mut file = File::open(&path).expect("reopen temp log");
        let lines = read_last_lines(&mut file, 100);
        assert_eq!(lines.len(), 5);
        for (i, line) in lines.iter().enumerate() {
            assert!(
                line.contains(&format!("/foo/{i} ")),
                "line {i} out of order or wrong content: {line}"
            );
        }

        fs::remove_file(path).expect("remove temp log");
    }

    #[test]
    fn read_last_lines_handles_missing_trailing_newline() {
        // Access logs are usually append-only with every line
        // newline-terminated, but the very last line at the moment of
        // reading could still be mid-write with no trailing '\n' yet. That
        // final partial line must still come back as its own entry, not be
        // dropped or merged with the previous line.
        let path = temp_log_path("no-trailing-newline");
        let mut file = File::create(&path).expect("create temp log");
        // First line newline-terminated as normal; the second (last) line
        // intentionally has none, simulating an in-progress write.
        writeln!(
            file,
            r#"127.0.0.1 - [29/Jun/2026:00:00:00 +0000] "GET /foo/0 HTTP/1.1" 200 1024 "HIT" "example.com""#
        )
        .expect("write temp log");
        write!(
            file,
            r#"127.0.0.1 - [29/Jun/2026:00:00:01 +0000] "GET /foo/1 HTTP/1.1" 200 1024 "HIT" "example.com""#
        )
        .expect("write temp log");
        drop(file);

        let mut file = File::open(&path).expect("reopen temp log");
        let lines = read_last_lines(&mut file, 10);
        assert_eq!(lines.len(), 2);
        assert!(lines[0].contains("/foo/0 "));
        assert!(lines[1].contains("/foo/1 "));
        assert!(!lines[1].ends_with('\n'));

        fs::remove_file(path).expect("remove temp log");
    }

    #[test]
    fn tail_returns_correct_last_n_lines_from_larger_file() {
        // Checks CONTENT and ORDER, not just count: a bug that returned the
        // right number of lines but the wrong slice (e.g. off-by-one, or
        // the first N instead of the last N) would still pass a
        // count-only assertion.
        let path = temp_log_path("larger");
        let mut file = File::create(&path).expect("create temp log");
        for i in 0..500 {
            writeln!(
                file,
                r#"127.0.0.1 - [29/Jun/2026:00:00:00 +0000] "GET /foo/{i:04} HTTP/1.1" 200 1024 "HIT" "example.com""#
            )
            .expect("write temp log");
        }
        drop(file);

        let mut file = File::open(&path).expect("reopen temp log");
        let lines = read_last_lines(&mut file, 10);
        assert_eq!(lines.len(), 10);
        // Oldest-first within the window: lines 490..499, in that order.
        for (offset, line) in lines.iter().enumerate() {
            let expected_index = 490 + offset;
            assert!(
                line.contains(&format!("/foo/{expected_index:04} ")),
                "position {offset}: expected /foo/{expected_index:04}, got: {line}"
            );
        }

        fs::remove_file(path).expect("remove temp log");
    }

    #[test]
    fn tail_reconstructs_line_split_across_chunk_boundary() {
        // Engineers a file where one specific line's bytes are physically
        // split across the TAIL_CHUNK_SIZE backward-read boundary, then
        // asserts that exact line comes back byte-for-byte intact — not
        // truncated, duplicated, or dropped. Every line is the same fixed
        // byte length, so the split line's index (and thus its expected
        // content) can be computed from real offsets instead of guessed.
        fn make_line(i: usize) -> String {
            format!(
                r#"127.0.0.1 - [29/Jun/2026:00:00:00 +0000] "GET /foo/{i:06} HTTP/1.1" 200 1024 "HIT" "example.com""#
            )
        }

        let line_len = make_line(0).len() + 1; // +1 for the trailing '\n'
        // Enough lines to span a few TAIL_CHUNK_SIZE reads with margin.
        let total_lines = (TAIL_CHUNK_SIZE as usize / line_len) * 3;
        let file_len = (total_lines * line_len) as u64;
        assert!(
            file_len > TAIL_CHUNK_SIZE,
            "fixture must exceed one chunk to exercise multi-chunk reads"
        );

        let boundary_pos = file_len - TAIL_CHUNK_SIZE;
        let split_line_index = (boundary_pos as usize) / line_len;
        // If the boundary landed exactly on a line start there's nothing to
        // split — fail loudly so the fixture gets adjusted rather than
        // silently skip the scenario this test exists to cover.
        assert_ne!(
            (boundary_pos as usize) % line_len,
            0,
            "chunk boundary landed on a line start; adjust the fixture to force a mid-line split"
        );

        let path = temp_log_path("chunk-boundary");
        let mut file = File::create(&path).expect("create temp log");
        for i in 0..total_lines {
            writeln!(file, "{}", make_line(i)).expect("write temp log");
        }
        drop(file);

        // +5 lines of margin beyond the split line so it's comfortably
        // inside the requested window, not right at its edge.
        let limit = total_lines - split_line_index + 5;
        let mut file = File::open(&path).expect("reopen temp log");
        let lines = read_last_lines(&mut file, limit);

        assert_eq!(lines.len(), limit);
        let expected_first_index = total_lines - limit;
        assert_eq!(lines[0], make_line(expected_first_index));
        assert_eq!(lines[lines.len() - 1], make_line(total_lines - 1));

        let split_offset_in_result = split_line_index - expected_first_index;
        assert_eq!(
            lines[split_offset_in_result],
            make_line(split_line_index),
            "line straddling the chunk boundary was not reconstructed correctly"
        );

        fs::remove_file(path).expect("remove temp log");
    }
}
