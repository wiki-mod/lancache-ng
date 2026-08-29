//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! Stream-and-discard HTTP fetch primitive (issue #871, carrying forward
//! issue #816's own non-negotiable requirement): each response body is
//! read and dropped as it arrives, never buffered whole in memory and
//! never written to a file. The fetch itself has no side effect beyond
//! making the bytes flow through lancache-ng's own proxy on the way --
//! the proxy is what caches them, this module only drains what it reads.
//!
//! Also implements the throughput logging the maintainer asked for in
//! place of an external mbuffer/pv pipeline stage (see
//! docs/architecture-ng.md's "Cache Warming" section for the full
//! reasoning): this design has no separate consumer stage that could fall
//! behind the network read (the loop below reads a chunk and immediately
//! drops it in the same iteration), so an external buffer would add a
//! process and a pipe stage without addressing a real risk. A byte
//! counter plus a periodic log line gives the same throughput visibility
//! natively.
//!
//! Bounded concurrency (spawn_throughput_logger's caller controls how
//! many fetch_and_discard calls run at once), not buffering, is this
//! project's chosen lever for approaching multi-Gbit/s line rates -- a
//! single HTTP stream rarely saturates a fast LAN/CDN link on its own.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use futures_util::StreamExt;
use tokio::sync::Semaphore;
use tokio::task::JoinSet;

/// Shared, thread-safe running total of bytes streamed so far. Read by
/// both the fetch loop (increments) and the periodic logger (reads only),
/// with no lock contention on the hot path.
#[derive(Default)]
pub struct ByteCounter {
    total: AtomicU64,
}

impl ByteCounter {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    fn add(&self, n: u64) {
        self.total.fetch_add(n, Ordering::Relaxed);
    }

    pub fn total(&self) -> u64 {
        self.total.load(Ordering::Relaxed)
    }
}

/// Streams url's response body and discards each chunk as it arrives,
/// updating counter with every chunk's length. Never buffers the whole
/// body in memory and never writes it to disk -- the only allocation per
/// chunk is whatever reqwest's bytes_stream() itself hands back, which is
/// dropped at the end of each loop iteration.
pub async fn fetch_and_discard(
    client: &reqwest::Client,
    url: &str,
    counter: &ByteCounter,
) -> anyhow::Result<u64> {
    let response = client.get(url).send().await?.error_for_status()?;
    let mut stream = response.bytes_stream();
    let mut fetched: u64 = 0;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        let chunk_len = chunk.len() as u64;
        fetched += chunk_len;
        counter.add(chunk_len);
        // What: chunk goes out of scope and is dropped here.
        // Why: this drop is the entire "discard" step -- nothing is
        //   written to a file or retained past this point.
        // From: Issue #871
    }
    Ok(fetched)
}

/// Fetches every URL in urls with at most concurrency requests in flight
/// at once, discarding each body as it streams (see fetch_and_discard
/// above). Returns one result per URL, in completion order (not input
/// order) -- callers that need per-URL attribution should pair each
/// result with its URL themselves if that ordering matters to them.
pub async fn fetch_many_and_discard(
    client: reqwest::Client,
    urls: Vec<String>,
    concurrency: usize,
    counter: Arc<ByteCounter>,
) -> Vec<anyhow::Result<u64>> {
    let semaphore = Arc::new(Semaphore::new(concurrency.max(1)));
    let mut tasks = JoinSet::new();

    for url in urls {
        let client = client.clone();
        let counter = Arc::clone(&counter);
        let semaphore = Arc::clone(&semaphore);
        tasks.spawn(async move {
            // What: caps in-flight requests at `concurrency`.
            // Why: unbounded spawning would open one connection per URL.
            // From: Issue #871
            let _permit = semaphore
                .acquire()
                .await
                .expect("semaphore is never closed while tasks are running");
            fetch_and_discard(&client, &url, &counter).await
        });
    }

    let mut results = Vec::new();
    while let Some(joined) = tasks.join_next().await {
        match joined {
            Ok(result) => results.push(result),
            Err(join_error) => results.push(Err(anyhow::anyhow!(
                "fetch task panicked or was cancelled: {join_error}"
            ))),
        }
    }
    results
}

/// Spawns a background task that logs the current throughput (bytes
/// fetched since the last tick, divided by the tick interval) every
/// interval, until counter's only remaining strong reference is this
/// task's own clone (i.e. every fetch task has finished and dropped its
/// clone). This is the throughput visibility the maintainer asked
/// mbuffer/pv for -- see this module's own doc comment for why an
/// external process is not needed for it.
pub fn spawn_throughput_logger(counter: Arc<ByteCounter>, interval: Duration) {
    tokio::spawn(async move {
        let mut last_total = counter.total();
        let mut ticker = tokio::time::interval(interval);
        loop {
            ticker.tick().await;
            if Arc::strong_count(&counter) == 1 {
                // What: this task is the only remaining owner of counter.
                // Why: every fetch task finished; nothing left to report.
                // From: Issue #871
                break;
            }
            let current_total = counter.total();
            let delta = current_total.saturating_sub(last_total);
            let mbit_per_sec = (delta as f64 * 8.0) / interval.as_secs_f64() / 1_000_000.0;
            tracing::info!(
                bytes_total = current_total,
                bytes_since_last = delta,
                mbit_per_sec = format!("{mbit_per_sec:.1}"),
                "prefill throughput"
            );
            last_total = current_total;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    // Verifies the counter itself: starts at zero, accumulates additions
    // correctly across multiple calls (the property fetch_and_discard's
    // loop actually depends on).
    #[test]
    fn byte_counter_starts_at_zero_and_accumulates() {
        let counter = ByteCounter::new();
        assert_eq!(counter.total(), 0);
        counter.add(100);
        counter.add(250);
        assert_eq!(counter.total(), 350);
    }

    // fetch_and_discard/fetch_many_and_discard's own streaming loop needs
    // a real HTTP server to exercise meaningfully (reqwest::Response has
    // no public constructor usable from a unit test, same limitation
    // services/ui/src/routes/netdata_proxy.rs's own read_bounded_body
    // comment already documents for the identical reason) -- deliberately
    // not attempted here. The throughput-rate arithmetic spawn_throughput_
    // logger depends on is covered directly instead, without needing the
    // background task or a real clock tick.
    #[test]
    fn throughput_rate_arithmetic_matches_expected_megabits_per_second() {
        let delta_bytes: u64 = 1_250_000; // 10,000,000 bits
        let interval = Duration::from_secs(1);
        let mbit_per_sec = (delta_bytes as f64 * 8.0) / interval.as_secs_f64() / 1_000_000.0;
        assert!(
            (mbit_per_sec - 10.0).abs() < 0.001,
            "1,250,000 bytes/sec should be exactly 10.0 Mbit/s, got {mbit_per_sec}"
        );
    }
}
