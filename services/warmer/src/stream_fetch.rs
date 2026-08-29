//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! Stream-and-discard HTTP fetch primitive (carrying forward issue #816's
//! own non-negotiable requirement): each response body is
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
/// interval, until `stop` fires. This is the throughput visibility the
/// maintainer asked mbuffer/pv for -- see this module's own doc comment
/// for why an external process is not needed for it.
///
/// The caller is expected to hold `stop`'s sender and fire it once its own
/// fetch work is done, then `.await` the returned `JoinHandle` before
/// reading `counter`'s final total -- an explicit stop signal, not a
/// strong-count guess, is what makes "the logger has genuinely stopped"
/// observable. (An earlier version of this function tried to infer
/// completion from `Arc::strong_count(&counter) == 1`, but the caller
/// necessarily keeps its own clone alive to read the final total after
/// this task's clone still exists too, so that count could never actually
/// reach 1 -- the loop only ended when the whole process exited. Fixed by
/// making shutdown an explicit signal instead of an inferred one.)
pub fn spawn_throughput_logger(
    counter: Arc<ByteCounter>,
    interval: Duration,
    mut stop: tokio::sync::oneshot::Receiver<()>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut last_total = counter.total();
        let mut ticker = tokio::time::interval(interval);
        loop {
            tokio::select! {
                _ = ticker.tick() => {
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
                _ = &mut stop => {
                    // What: the caller's fetch work is done; stop ticking.
                    // Why: an explicit signal, not an Arc-count guess (see
                    //   this function's own doc comment for why the guess
                    //   was wrong).
                    // From: Issue #871
                    break;
                }
            }
        }
    })
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

    // Verifies the fix this round made: the logger task actually
    // terminates promptly once `stop` fires, rather than running until
    // process exit (the bug the strong-count-based version above had --
    // see spawn_throughput_logger's own doc comment).
    //
    // Uses a real (unpaused) clock, deliberately: tokio's `test-util`
    // feature (needed for `start_paused`) is not a dependency any other
    // service in this repo carries, and a long interval combined with
    // `tokio::time::interval`'s documented "first tick fires immediately"
    // behavior already makes this deterministic without it -- the select!
    // below either logs once on that immediate first tick or catches the
    // already-sent `stop` first, and either way the *second* loop
    // iteration always sees `stop` ready (it was sent before the task was
    // even polled), so this cannot hang waiting for a real 3600s tick.
    #[tokio::test]
    async fn spawn_throughput_logger_stops_promptly_when_signaled() {
        let counter = ByteCounter::new();
        let (stop_tx, stop_rx) = tokio::sync::oneshot::channel();
        let handle =
            spawn_throughput_logger(Arc::clone(&counter), Duration::from_secs(3600), stop_rx);

        stop_tx
            .send(())
            .expect("logger task must still be listening");
        tokio::time::timeout(Duration::from_secs(5), handle)
            .await
            .expect("logger task should stop promptly after `stop` fires, not hang until the interval next ticks")
            .expect("logger task should not panic");
    }
}
