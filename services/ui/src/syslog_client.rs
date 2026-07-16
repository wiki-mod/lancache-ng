//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//! Reader for the central syslog-ng log store (#633 PR4). Sibling to
//! nginx_client.rs, not a patch to it: the two log formats are unrelated
//! (nginx's custom access-log format vs. syslog-ng's own
//! `$ISODATE $HOST $PROGRAM: $MSGONLY` destination template -- see
//! deploy/*/docker-compose.yml's inline-generated `d_lancache` destination).
//!
//! Layout under SYSLOG_LOG_ROOT (written by the `syslog-ng` service, PR2/#756
//! extended which services feed it, PR3/#757 added storage-budget pruning):
//!   <root>/<host>/<YYYYMMDD>.log                          -- active file
//!   <root>/<host>/<YYYYMMDD>.log.<rotated-ts>              -- just rotated
//!   <root>/<host>/<YYYYMMDD>.log.<rotated-ts>.zst|.gz      -- compressed
//! `<rotated-ts>` is `date -u +%Y%m%dT%H%M%SZ`. Compression is zstd by
//! default, falling back to gzip only if zstd could not be installed at
//! container start (no network egress) -- every reader here must therefore
//! transparently handle plain/.zst/.gz, never assume one or the other.

use regex::Regex;
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;
use std::time::SystemTime;

static SYSLOG_LINE_REGEX: OnceLock<Regex> = OnceLock::new();

#[derive(Debug, Serialize, Clone)]
pub struct SyslogEntry {
    pub timestamp: String,
    pub host: String,
    pub program: String,
    pub message: String,
}

#[derive(Debug, Serialize, Default, Clone)]
pub struct SyslogHostStats {
    pub host: String,
    pub files: u64,
    pub size_bytes: u64,
    // Distinct count of YYYYMMDD file-name prefixes seen for this host, i.e.
    // "aggregate by host/day" collapsed to a count rather than a full
    // per-day breakdown table -- the size/file totals above are already
    // per-host, and a full per-day matrix would need line-level timestamp
    // parsing on every compressed file for a dashboard stat nobody asked to
    // drill into, which isn't worth the extra decompression cost.
    //
    // No line count here (deliberately removed, see #758 review): counting
    // non-empty lines requires decompressing every .zst/.gz file, and
    // get_syslog_stats runs on every /dashboard render (no cache, no
    // upper bound while the PR3/#757 storage-budget pruning is out of this
    // branch's scope) -- on an install with GBs of retained history that
    // turned each dashboard load into a full decompress-everything scan.
    // files/size_bytes/days above are metadata/filename-only and stay cheap
    // regardless of retained volume.
    pub days: u64,
}

#[derive(Debug, Serialize, Default, Clone)]
pub struct SyslogStats {
    pub hosts: Vec<SyslogHostStats>,
    pub total_files: u64,
    pub total_size_bytes: u64,
}

// Returns up to `limit` entries from the tail of the syslog-ng store, oldest
// first within the returned window -- same ordering contract as
// nginx_client::parse_log_tail. `host` restricts to one host's subdirectory;
// `None` merges every host under `log_root`.
//
// Unlike parse_log_tail's byte-seek-backward approach, this cannot binary
// seek into a `.zst`/`.gz` file (compressed streams have no random access),
// so instead: list candidate files, sort newest-mtime-first, decode whole
// files starting from the newest until `limit` lines have been collected,
// then stop opening any older file. This keeps the common case (tailing an
// enabled, actively-rotating store) cheap -- it will not decompress
// SYSLOG_MAX_GB's worth of history just to show the last 200 lines.
//
// The collected lines are then merged with a per-host floor (see
// select_fair_window below) rather than a single global sort+truncate: a
// naturally quiet host (e.g. lancache-watchdog, which logs a handful of
// lines at startup and then only on an actual problem) must stay visible
// even once a noisy host (e.g. netdata) has produced far more recent lines
// than `limit` on its own. See #859.
pub fn parse_syslog_tail(log_root: &str, host: Option<&str>, limit: usize) -> Vec<SyslogEntry> {
    if limit == 0 {
        return vec![];
    }

    let host_dirs = match host {
        Some(h) => vec![Path::new(log_root).join(h)],
        None => list_host_dirs(log_root),
    };

    let mut candidates: Vec<(PathBuf, SystemTime)> = Vec::new();
    for dir in &host_dirs {
        let Ok(entries) = fs::read_dir(dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(metadata) = entry.metadata() else {
                continue;
            };
            if !metadata.is_file() {
                continue;
            }
            let mtime = metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH);
            candidates.push((path, mtime));
        }
    }
    // Newest file first, so the loop below can stop as soon as it has
    // collected enough lines without opening older (irrelevant) files.
    candidates.sort_by_key(|(_, mtime)| std::cmp::Reverse(*mtime));

    // Every host dir that has at least one file must contribute before the
    // early-break below fires. Without this, a single noisy/most-recently-
    // touched host's newest file can already satisfy `limit` by itself, so
    // the loop would stop before ever opening any other host's file --
    // silently dropping that host from a multi-host merge rather than
    // interleaving across hosts (see #758 review). This still bounds the
    // worst case to "one file per host dir with data" before the fast path
    // can kick in, not a full-store scan.
    let dirs_with_candidates: HashSet<PathBuf> = candidates
        .iter()
        .filter_map(|(path, _)| path.parent().map(PathBuf::from))
        .collect();
    let mut hosts_seen: HashSet<PathBuf> = HashSet::new();

    let mut collected: Vec<SyslogEntry> = Vec::new();
    for (path, _mtime) in candidates {
        let host_dir = path.parent().map(PathBuf::from).unwrap_or_default();
        let host_name = host_dir
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        hosts_seen.insert(host_dir);
        let Some(content) = read_file_transparent(&path) else {
            continue;
        };
        for line in content.lines() {
            if let Some(entry) = parse_syslog_line(&host_name, line) {
                collected.push(entry);
            }
        }
        if collected.len() >= limit && hosts_seen.len() >= dirs_with_candidates.len() {
            break;
        }
    }

    select_fair_window(collected, limit)
}

// Merges per-host lines into a single `limit`-sized window without letting a
// noisy host fully evict a quiet one (#859). A plain global
// sort-by-timestamp + truncate-to-`limit` (the pre-#859 behavior) is
// host-blind: if every other host's lines are newer, a quiet host's entire
// contribution -- including a real problem it just logged -- can be sorted
// out of the window even though dirs_with_candidates/hosts_seen above
// guaranteed its file got opened. Instead:
//
//   1. Group entries by host, newest-first per host.
//   2. Round-robin across hosts (alphabetical order, for determinism) up to
//      `per_host_floor = max(1, limit / hosts_with_data)` rounds, taking one
//      more line per host per round. This guarantees every host with data
//      keeps at least `per_host_floor` of its own most recent lines in the
//      window, capped by how many lines it actually has.
//   3. Whatever budget remains after every host's floor is exhausted (or
//      every host ran out of lines) is filled with the globally most recent
//      leftover lines across all hosts -- this is where a genuinely noisy,
//      genuinely recent host still dominates the window when it isn't
//      competing against other hosts for space.
//
// Lines that failed to match the expected format get an empty timestamp
// (see parse_syslog_line) and sort as oldest; this is a documented
// best-effort fallback, not a correctness bug, since such lines are kept
// rather than dropped. The final output is re-sorted oldest-first to match
// nginx_client::parse_log_tail's tail-window contract.
//
// Caveat: if there are more hosts with data than `limit` (unusual at this
// project's scale -- a handful of wired services, default limit 200), the
// round-robin's alphabetical tie-break means hosts earlier in sort order are
// slightly favored once the shared floor round runs out of budget
// mid-round. This is a bounded, deterministic edge case, not a starvation
// bug: every host still gets a chance at a line before any host gets a
// second one.
fn select_fair_window(collected: Vec<SyslogEntry>, limit: usize) -> Vec<SyslogEntry> {
    let mut by_host: HashMap<String, Vec<SyslogEntry>> = HashMap::new();
    for entry in collected {
        by_host.entry(entry.host.clone()).or_default().push(entry);
    }
    for entries in by_host.values_mut() {
        entries.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));
    }

    let mut host_names: Vec<String> = by_host.keys().cloned().collect();
    host_names.sort();
    let host_count = host_names.len();
    if host_count == 0 {
        return vec![];
    }

    let per_host_floor = (limit / host_count).max(1);
    let mut kept: Vec<SyslogEntry> = Vec::new();
    let mut taken_per_host: HashMap<String, usize> = HashMap::new();

    'rounds: for round in 0..per_host_floor {
        for host in &host_names {
            if kept.len() >= limit {
                break 'rounds;
            }
            if let Some(entry) = by_host.get(host).and_then(|entries| entries.get(round)) {
                kept.push(entry.clone());
                *taken_per_host.entry(host.clone()).or_insert(0) += 1;
            }
        }
    }

    if kept.len() < limit {
        let mut leftovers: Vec<&SyslogEntry> = Vec::new();
        for host in &host_names {
            let taken = *taken_per_host.get(host).unwrap_or(&0);
            if let Some(entries) = by_host.get(host) {
                leftovers.extend(entries.iter().skip(taken));
            }
        }
        leftovers.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));
        let need = limit - kept.len();
        kept.extend(leftovers.into_iter().take(need).cloned());
    }

    kept.sort_by(|a, b| a.timestamp.cmp(&b.timestamp));
    kept
}

// Aggregates file count / on-disk size per host, plus a distinct-day count
// per host, across every file under `log_root`. Metadata/filename-only
// (fs::read_dir + Metadata::len(), no file content is read), unlike
// nginx_client::get_log_stats's whole-file aggregate read -- content-level
// stats (e.g. line counts) would require decompressing every .zst/.gz file
// on every call, which isn't bounded by anything in this branch (the
// PR3/#757 storage-budget pruning that would cap retained volume is out of
// scope here), so this deliberately stays metadata-only. Not a bounded tail
// read like parse_syslog_tail above either -- this always visits every file.
pub fn get_syslog_stats(log_root: &str) -> SyslogStats {
    let mut stats = SyslogStats::default();

    let Ok(root_entries) = fs::read_dir(log_root) else {
        return stats;
    };
    let mut host_dirs: Vec<PathBuf> = root_entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    host_dirs.sort();

    for dir in host_dirs {
        let host_name = dir
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        let mut host_stats = SyslogHostStats {
            host: host_name,
            ..Default::default()
        };
        let mut days: HashSet<String> = HashSet::new();

        let Ok(files) = fs::read_dir(&dir) else {
            stats.hosts.push(host_stats);
            continue;
        };
        for entry in files.flatten() {
            let path = entry.path();
            let Ok(metadata) = entry.metadata() else {
                continue;
            };
            if !metadata.is_file() {
                continue;
            }

            host_stats.files += 1;
            host_stats.size_bytes += metadata.len();

            if let Some(day) = extract_day(&path) {
                days.insert(day);
            }
        }

        host_stats.days = days.len() as u64;
        stats.total_files += host_stats.files;
        stats.total_size_bytes += host_stats.size_bytes;
        stats.hosts.push(host_stats);
    }

    stats
}

// Mirrors nginx_client::get_cache_size_gb's allowlist-then-`du` shape, but
// deliberately does NOT extend that function's cache-directory-scoped
// allowlist: the syslog store's container-side mount path is fixed at
// /var/log/lancache-syslog-ng across dev/prod/quickstart (every
// deploy/*/docker-compose.yml mounts logs-syslog-ng or the prod bind source
// at that exact path), unlike CACHE_DIR which legitimately varies by
// deployment mode -- a single-entry allowlist is the correct match for that
// contract, not an oversight.
pub fn get_syslog_size_gb(path: &str) -> f64 {
    let path_obj = Path::new(path);
    if !path_obj.is_absolute() {
        return 0.0;
    }
    if path.contains("..") {
        return 0.0;
    }

    let allowed_prefixes = ["/var/log/lancache-syslog-ng"];
    if !allowed_prefixes
        .iter()
        .any(|prefix| path.starts_with(prefix))
    {
        return 0.0;
    }

    // Blocks the calling thread the same way get_cache_size_gb's `du` call
    // does -- callers (routes/dashboard.rs) must run this inside
    // tokio::task::spawn_blocking.
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

fn list_host_dirs(log_root: &str) -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir(log_root) else {
        return vec![];
    };
    entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect()
}

// Reads `path` fully into memory and transparently decompresses based on
// file extension (".zst"/".gz"), falling back to treating the file as plain
// text for anything else (the active, not-yet-rotated ".log" file, or a
// rotated-but-not-yet-compressed ".log.<ts>" file mid-rotation). Whole-file
// reads, not streaming decompression, since syslog-ng's own rotation
// threshold (SYSLOG_MAX_FILE_MB, default 100) already bounds any single
// file's size.
fn read_file_transparent(path: &Path) -> Option<String> {
    let raw = fs::read(path).ok()?;
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");
    let decoded = match ext {
        "zst" => {
            let mut out = Vec::new();
            zstd::stream::copy_decode(&raw[..], &mut out).ok()?;
            out
        }
        "gz" => {
            let mut decoder = flate2::read::GzDecoder::new(&raw[..]);
            let mut out = Vec::new();
            decoder.read_to_end(&mut out).ok()?;
            out
        }
        _ => raw,
    };
    // Lossy, not strict UTF-8: a single malformed byte sequence anywhere in
    // the file must not make the whole file unreadable, mirroring
    // nginx_client's #657/#663 fix (from_utf8_lossy instead of
    // map_while(Result::ok)'s silent truncation-on-first-bad-line).
    Some(String::from_utf8_lossy(&decoded).into_owned())
}

// Parses one line of syslog-ng's `d_lancache` destination template:
//   "$ISODATE $HOST $PROGRAM: $MSGONLY"
// e.g. "2026-07-13T12:34:56+00:00 lancache-dns-standard pdns_server: query for example.com"
// A line that doesn't match this shape (empty line, a multi-line stack-trace
// continuation, hand-edited content) is kept with the raw text in `message`
// rather than dropped -- same "never truncate/drop on a parse miss"
// principle as nginx_client's #663 fix, just applied to a different format.
fn parse_syslog_line(host_name: &str, line: &str) -> Option<SyslogEntry> {
    if line.trim().is_empty() {
        return None;
    }

    let re = syslog_line_regex();
    if let Some(caps) = re.captures(line) {
        Some(SyslogEntry {
            timestamp: caps[1].to_string(),
            host: host_name.to_string(),
            program: caps[2].to_string(),
            message: caps[3].to_string(),
        })
    } else {
        Some(SyslogEntry {
            timestamp: String::new(),
            host: host_name.to_string(),
            program: String::new(),
            message: line.to_string(),
        })
    }
}

fn syslog_line_regex() -> &'static Regex {
    SYSLOG_LINE_REGEX.get_or_init(|| {
        Regex::new(r"^(\S+)\s+\S+\s+([^:]+):\s(.*)$").expect("syslog line regex is valid")
    })
}

// Extracts the YYYYMMDD day prefix from a syslog-ng file name
// (<YYYYMMDD>.log[.rotated-ts][.zst|.gz]) for get_syslog_stats's per-host
// distinct-day count. Returns None for any name that doesn't start with
// exactly 8 digits, rather than guessing.
fn extract_day(path: &Path) -> Option<String> {
    let name = path.file_name()?.to_str()?;
    let day = name.split('.').next()?;
    if day.len() == 8 && day.chars().all(|c| c.is_ascii_digit()) {
        Some(day.to_string())
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;
    use std::io::Write;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    // Unique temp dir per test (nanosecond suffix), mirroring
    // nginx_client.rs's temp-file-per-test convention -- `cargo test` runs
    // tests in parallel threads in the same process, so fixture directories
    // must not collide.
    fn temp_root(label: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before unix epoch")
            .as_nanos();
        std::env::temp_dir().join(format!("lancache-ui-syslog-{label}-{unique}"))
    }

    fn write_plain(dir: &Path, host: &str, name: &str, content: &str) {
        let host_dir = dir.join(host);
        fs::create_dir_all(&host_dir).expect("create host dir");
        let mut file = File::create(host_dir.join(name)).expect("create fixture file");
        file.write_all(content.as_bytes()).expect("write fixture");
    }

    fn write_zst(dir: &Path, host: &str, name: &str, content: &str) {
        let host_dir = dir.join(host);
        fs::create_dir_all(&host_dir).expect("create host dir");
        let encoded = zstd::stream::encode_all(content.as_bytes(), 3).expect("zstd encode");
        fs::write(host_dir.join(name), encoded).expect("write zst fixture");
    }

    fn write_gz(dir: &Path, host: &str, name: &str, content: &str) {
        use flate2::write::GzEncoder;
        use flate2::Compression;
        let host_dir = dir.join(host);
        fs::create_dir_all(&host_dir).expect("create host dir");
        let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
        encoder.write_all(content.as_bytes()).expect("gz write");
        let encoded = encoder.finish().expect("gz finish");
        fs::write(host_dir.join(name), encoded).expect("write gz fixture");
    }

    // Backdates a fixture file's mtime by `secs_ago` from now, so tests can
    // deterministically control the newest-mtime-first ordering that
    // parse_syslog_tail sorts candidates by -- relying on real filesystem
    // write ordering alone is flaky (mtime resolution can be coarser than
    // the time between two fs::write calls in a fast test run).
    fn set_mtime(path: &Path, secs_ago: u64) {
        let time = SystemTime::now() - Duration::from_secs(secs_ago);
        let file = File::options()
            .write(true)
            .open(path)
            .expect("open fixture for mtime backdate");
        file.set_modified(time).expect("set fixture mtime");
    }

    #[test]
    fn parse_syslog_tail_reads_plain_text_lines_in_order() {
        let root = temp_root("plain");
        write_plain(
            &root,
            "hostA",
            "20260713.log",
            "2026-07-13T10:00:00+00:00 hostA nginx: first message\n\
             2026-07-13T10:00:01+00:00 hostA nginx: second message\n",
        );

        let entries = parse_syslog_tail(root.to_str().unwrap(), None, 10);
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].message, "first message");
        assert_eq!(entries[0].program, "nginx");
        assert_eq!(entries[0].host, "hostA");
        assert_eq!(entries[1].message, "second message");

        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn parse_syslog_tail_transparently_decompresses_zst_files() {
        let root = temp_root("zst");
        write_zst(
            &root,
            "hostA",
            "20260710.log.20260710T000000Z.zst",
            "2026-07-10T00:00:00+00:00 hostA pdns_server: zst-compressed entry\n",
        );

        let entries = parse_syslog_tail(root.to_str().unwrap(), Some("hostA"), 10);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].message, "zst-compressed entry");
        assert_eq!(entries[0].program, "pdns_server");

        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn parse_syslog_tail_transparently_decompresses_gz_files() {
        let root = temp_root("gz");
        write_gz(
            &root,
            "hostA",
            "20260710.log.20260710T000000Z.gz",
            "2026-07-10T00:00:00+00:00 hostA kea-dhcp4: gz-compressed entry\n",
        );

        let entries = parse_syslog_tail(root.to_str().unwrap(), Some("hostA"), 10);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].message, "gz-compressed entry");
        assert_eq!(entries[0].program, "kea-dhcp4");

        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn parse_syslog_tail_merges_and_orders_multiple_hosts_by_timestamp() {
        let root = temp_root("multihost");
        write_plain(
            &root,
            "hostA",
            "20260713.log",
            "2026-07-13T10:00:00+00:00 hostA nginx: a1\n\
             2026-07-13T10:00:02+00:00 hostA nginx: a2\n",
        );
        write_plain(
            &root,
            "hostB",
            "20260713.log",
            "2026-07-13T10:00:01+00:00 hostB pdns_server: b1\n",
        );

        let entries = parse_syslog_tail(root.to_str().unwrap(), None, 10);
        assert_eq!(entries.len(), 3);
        // Interleaved by timestamp across hosts, not grouped by host.
        assert_eq!(entries[0].message, "a1");
        assert_eq!(entries[1].message, "b1");
        assert_eq!(entries[2].message, "a2");

        fs::remove_dir_all(root).expect("cleanup");
    }

    // Regression test for #758 review: a single host's newest-mtime file
    // satisfying `limit` on its own must not stop the loop before every
    // other host with data has had a chance to contribute a file. Before
    // the fix, the early break fired as soon as `collected.len() >= limit`
    // regardless of which/how-many hosts had been opened, so hostB below
    // would be silently dropped from the merge even though it has data.
    #[test]
    fn parse_syslog_tail_does_not_starve_other_hosts_when_the_newest_file_alone_satisfies_limit() {
        let root = temp_root("starve");
        write_plain(
            &root,
            "hostA",
            "20260713.log",
            "2026-07-13T10:00:00+00:00 hostA nginx: a1\n\
             2026-07-13T10:00:01+00:00 hostA nginx: a2\n\
             2026-07-13T10:00:02+00:00 hostA nginx: a3\n",
        );
        write_plain(
            &root,
            "hostB",
            "20260713.log",
            "2026-07-13T10:00:03+00:00 hostB pdns_server: b1\n",
        );
        // hostA is the most-recently-touched file in the whole store (mtime
        // "now"), hostB's file is older by mtime -- exactly the scenario
        // that let hostA alone starve hostB pre-fix.
        set_mtime(&root.join("hostA").join("20260713.log"), 0);
        set_mtime(&root.join("hostB").join("20260713.log"), 60);

        let entries = parse_syslog_tail(root.to_str().unwrap(), None, 2);
        let hosts: Vec<&str> = entries.iter().map(|e| e.host.as_str()).collect();
        assert!(
            hosts.contains(&"hostB"),
            "hostB must be represented in the merged tail even though \
             hostA's (newer-mtime) file alone already had >= limit lines; \
             got {hosts:?}"
        );

        fs::remove_dir_all(root).expect("cleanup");
    }

    // Regression test for #859: the #758 fix above only guarantees every
    // host's newest *file* gets opened before collection stops -- it does
    // nothing to protect a quiet host's lines from the final merge step.
    // Before this fix, `collected.sort_by(timestamp)` + truncate-to-`limit`
    // was host-blind: hostQuiet's single old line here would be sorted
    // ahead of every one of hostNoisy's 50 newer lines and truncated away
    // entirely, even though hostQuiet's file was opened and read correctly.
    #[test]
    fn parse_syslog_tail_does_not_starve_a_quiet_host_at_the_final_merge_step() {
        let root = temp_root("quiet-merge");
        write_plain(
            &root,
            "hostQuiet",
            "20260701.log",
            "2026-07-01T00:00:00+00:00 hostQuiet lancache-watchdog: startup banner\n",
        );
        let mut noisy_content = String::new();
        for i in 0..50 {
            noisy_content.push_str(&format!(
                "2026-07-13T10:{i:02}:00+00:00 hostNoisy netdata: chatter-{i}\n"
            ));
        }
        write_plain(&root, "hostNoisy", "20260713.log", &noisy_content);

        let entries = parse_syslog_tail(root.to_str().unwrap(), None, 10);

        // (b) the overall limit is still respected.
        assert_eq!(entries.len(), 10);
        // (a) hostQuiet's only line survives despite being far older than
        // every one of hostNoisy's 50 lines.
        assert!(
            entries.iter().any(|e| e.host == "hostQuiet"),
            "hostQuiet's only line must survive the final merge even though \
             hostNoisy has 50 newer lines; got hosts {:?}",
            entries.iter().map(|e| e.host.as_str()).collect::<Vec<_>>()
        );
        // (c) the remaining budget is still dominated by hostNoisy's most
        // recent lines, not arbitrary older ones.
        assert!(entries.iter().any(|e| e.message == "chatter-49"));

        fs::remove_dir_all(root).expect("cleanup");
    }

    // Companion to the above: when only one host is contributing (or a
    // host has no competing quiet host to protect against), the fair-window
    // merge must degrade to plain most-recent-first behavior -- the
    // per-host floor should never hold back a host's own most recent lines
    // when nothing else is competing for the budget.
    #[test]
    fn parse_syslog_tail_lets_high_volume_activity_dominate_when_uncontested() {
        let root = temp_root("uncontested");
        let mut content = String::new();
        for i in 0..30 {
            content.push_str(&format!(
                "2026-07-13T10:{i:02}:00+00:00 hostNoisy netdata: chatter-{i}\n"
            ));
        }
        write_plain(&root, "hostNoisy", "20260713.log", &content);

        let entries = parse_syslog_tail(root.to_str().unwrap(), None, 5);
        assert_eq!(entries.len(), 5);
        let messages: Vec<&str> = entries.iter().map(|e| e.message.as_str()).collect();
        assert_eq!(
            messages,
            vec![
                "chatter-25",
                "chatter-26",
                "chatter-27",
                "chatter-28",
                "chatter-29"
            ],
            "with a single host contributing, the merge must still keep \
             exactly the most recent `limit` lines; got {messages:?}"
        );

        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn parse_syslog_tail_respects_limit_and_keeps_the_most_recent_lines() {
        let root = temp_root("limit");
        let mut content = String::new();
        for i in 0..20 {
            content.push_str(&format!(
                "2026-07-13T10:{i:02}:00+00:00 hostA nginx: line-{i}\n"
            ));
        }
        write_plain(&root, "hostA", "20260713.log", &content);

        let entries = parse_syslog_tail(root.to_str().unwrap(), Some("hostA"), 5);
        assert_eq!(entries.len(), 5);
        assert_eq!(entries[0].message, "line-15");
        assert_eq!(entries[4].message, "line-19");

        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn parse_syslog_tail_keeps_unparseable_lines_instead_of_dropping_them() {
        let root = temp_root("malformed");
        write_plain(
            &root,
            "hostA",
            "20260713.log",
            "2026-07-13T10:00:00+00:00 hostA nginx: good line\n\
             not a syslog line at all\n\
             2026-07-13T10:00:02+00:00 hostA nginx: another good line\n",
        );

        let entries = parse_syslog_tail(root.to_str().unwrap(), Some("hostA"), 10);
        assert_eq!(entries.len(), 3);
        assert!(entries
            .iter()
            .any(|e| e.message == "not a syslog line at all"));
        assert!(entries.iter().any(|e| e.message == "good line"));
        assert!(entries.iter().any(|e| e.message == "another good line"));

        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn parse_syslog_tail_returns_empty_for_missing_root() {
        let root = temp_root("missing");
        // Deliberately not created.
        let entries = parse_syslog_tail(root.to_str().unwrap(), None, 10);
        assert!(entries.is_empty());
    }

    #[test]
    fn get_syslog_stats_aggregates_files_and_size_per_host() {
        let root = temp_root("stats");
        write_plain(
            &root,
            "hostA",
            "20260713.log",
            "2026-07-13T10:00:00+00:00 hostA nginx: a1\n\
             2026-07-13T10:00:01+00:00 hostA nginx: a2\n",
        );
        write_plain(
            &root,
            "hostA",
            "20260712.log.20260712T235959Z",
            "2026-07-12T23:59:59+00:00 hostA nginx: a3\n",
        );
        write_plain(
            &root,
            "hostB",
            "20260713.log",
            "2026-07-13T10:00:00+00:00 hostB pdns_server: b1\n",
        );

        let stats = get_syslog_stats(root.to_str().unwrap());
        assert_eq!(stats.total_files, 3);
        assert!(stats.total_size_bytes > 0);
        assert_eq!(stats.hosts.len(), 2);

        let host_a = stats
            .hosts
            .iter()
            .find(|h| h.host == "hostA")
            .expect("hostA present");
        assert_eq!(host_a.files, 2);
        assert_eq!(host_a.days, 2);

        let host_b = stats
            .hosts
            .iter()
            .find(|h| h.host == "hostB")
            .expect("hostB present");
        assert_eq!(host_b.files, 1);
        assert_eq!(host_b.days, 1);

        fs::remove_dir_all(root).expect("cleanup");
    }

    // Regression test for #758 review: get_syslog_stats must count
    // compressed files by metadata alone (fs::read_dir + Metadata::len()),
    // never decompress their content, since a dashboard-tile stat running
    // on every render can't afford to decode a whole store's worth of
    // .zst/.gz history per request. There is no line count to assert on
    // anymore (that field was removed for the same reason) -- this test
    // instead confirms file/size/day metadata is still collected correctly
    // for compressed files without needing to read their content.
    #[test]
    fn get_syslog_stats_counts_compressed_files_by_metadata_only() {
        let root = temp_root("stats-compressed");
        write_zst(
            &root,
            "hostA",
            "20260710.log.20260710T000000Z.zst",
            "2026-07-10T00:00:00+00:00 hostA nginx: z1\n\
             2026-07-10T00:00:01+00:00 hostA nginx: z2\n",
        );
        write_gz(
            &root,
            "hostA",
            "20260711.log.20260711T000000Z.gz",
            "2026-07-11T00:00:00+00:00 hostA nginx: g1\n",
        );

        let stats = get_syslog_stats(root.to_str().unwrap());
        assert_eq!(stats.total_files, 2);
        assert!(stats.total_size_bytes > 0);
        let host_a = stats
            .hosts
            .iter()
            .find(|h| h.host == "hostA")
            .expect("hostA present");
        assert_eq!(host_a.days, 2);

        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn get_syslog_stats_returns_empty_default_for_missing_root() {
        let root = temp_root("stats-missing");
        let stats = get_syslog_stats(root.to_str().unwrap());
        assert_eq!(stats.total_files, 0);
        assert_eq!(stats.total_size_bytes, 0);
        assert!(stats.hosts.is_empty());
    }

    #[test]
    fn get_syslog_size_gb_rejects_paths_outside_the_syslog_allowlist() {
        // Deliberately not the syslog allowlist prefix -- must return 0.0
        // without shelling out, same fail-closed behavior as
        // nginx_client::get_cache_size_gb for an out-of-allowlist path.
        assert_eq!(get_syslog_size_gb("/etc/passwd"), 0.0);
        assert_eq!(get_syslog_size_gb("relative/path"), 0.0);
        assert_eq!(
            get_syslog_size_gb("/var/log/lancache-syslog-ng/../etc"),
            0.0
        );
    }
}
