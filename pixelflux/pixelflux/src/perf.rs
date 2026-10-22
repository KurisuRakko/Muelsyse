/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

//! Per-second end-to-end counters for the KWin host-capture zero-copy path, enabled by a
//! non-empty `RAKKORD_PERF` other than `0`.
//!
//! Every recording call checks one cached flag first, so a disabled build pays a single
//! branch per call site. The compositor thread's once-a-second log block drains everything
//! into one `RD_PERF_PF` line; intervals are microsecond samples between consecutive
//! events, capped per second, summarised as p50/p95/max milliseconds.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::wayland::frontend::TickTrigger;

static ENABLED: LazyLock<bool> = LazyLock::new(|| {
    std::env::var("RAKKORD_PERF").is_ok_and(|v| !v.is_empty() && v != "0")
});

const MAX_SAMPLES: usize = 512;

#[inline]
pub fn enabled() -> bool {
    *ENABLED
}

struct Interval {
    last: Option<Instant>,
    samples: Vec<u32>,
}

impl Interval {
    const fn new() -> Self {
        Self { last: None, samples: Vec::new() }
    }
}

fn mark(interval: &Mutex<Interval>, now: Instant) {
    let mut s = interval.lock().unwrap();
    if let Some(last) = s.last
        && s.samples.len() < MAX_SAMPLES
    {
        let us = now.saturating_duration_since(last).as_micros().min(u32::MAX as u128) as u32;
        s.samples.push(us);
    }
    s.last = Some(now);
}

fn take_samples(interval: &Mutex<Interval>) -> Vec<u32> {
    std::mem::take(&mut interval.lock().unwrap().samples)
}

static KWIN_CB: AtomicU64 = AtomicU64::new(0);
static KWIN_VIDEO: AtomicU64 = AtomicU64::new(0);
static KWIN_CURSOR: AtomicU64 = AtomicU64::new(0);
static KWIN_NOSLOT: AtomicU64 = AtomicU64::new(0);
static KWIN_IV: Mutex<Interval> = Mutex::new(Interval::new());
static HOST_SUPERSEDED: AtomicU64 = AtomicU64::new(0);
static HOST_STALE: AtomicU64 = AtomicU64::new(0);
static TICK_HOST: AtomicU64 = AtomicU64::new(0);
static TICK_TIMER: AtomicU64 = AtomicU64::new(0);
static TICK_INPUT: AtomicU64 = AtomicU64::new(0);
static TICK_DEFER: AtomicU64 = AtomicU64::new(0);
static ENC_NOCHANGE: AtomicU64 = AtomicU64::new(0);
static ENC_BUSY: AtomicU64 = AtomicU64::new(0);
static ENC: AtomicU64 = AtomicU64::new(0);
static ENC_IV: Mutex<Interval> = Mutex::new(Interval::new());
static ENC_BYTES: AtomicU64 = AtomicU64::new(0);
static ENC_BYTES_MAX: AtomicU64 = AtomicU64::new(0);
static ENC_CALLS: AtomicU64 = AtomicU64::new(0);
static ENC_US_SUM: AtomicU64 = AtomicU64::new(0);
static ENC_US_MAX: AtomicU64 = AtomicU64::new(0);
static DELIVER: AtomicU64 = AtomicU64::new(0);
static DELIVER_US_MAX: AtomicU64 = AtomicU64::new(0);
static PTR_CMD: AtomicU64 = AtomicU64::new(0);
static PTR_IV: Mutex<Interval> = Mutex::new(Interval::new());
static PTR_FI: AtomicU64 = AtomicU64::new(0);
static PTR_FI_FAIL: AtomicU64 = AtomicU64::new(0);
static PTR_FI_TOTAL: AtomicU64 = AtomicU64::new(0);
static PTR_FI_AT_FRAME: AtomicU64 = AtomicU64::new(0);
static MV_PER_FRAME: [AtomicU64; 4] =
    [AtomicU64::new(0), AtomicU64::new(0), AtomicU64::new(0), AtomicU64::new(0)];

fn bump(counter: &AtomicU64) {
    counter.fetch_add(1, Ordering::Relaxed);
}

fn duration_us(d: Duration) -> u64 {
    d.as_micros().min(u64::MAX as u128) as u64
}

pub fn kwin_callback() {
    if enabled() {
        bump(&KWIN_CB);
    }
}

pub fn kwin_cursor_only() {
    if enabled() {
        bump(&KWIN_CURSOR);
    }
}

pub fn kwin_no_slot() {
    if enabled() {
        bump(&KWIN_NOSLOT);
    }
}

/// An accepted video frame; also buckets the fake-input moves since the previous one.
pub fn kwin_video() {
    if !enabled() {
        return;
    }
    bump(&KWIN_VIDEO);
    mark(&KWIN_IV, Instant::now());
    let total = PTR_FI_TOTAL.load(Ordering::Relaxed);
    let prev = PTR_FI_AT_FRAME.swap(total, Ordering::Relaxed);
    bump(&MV_PER_FRAME[move_bucket(total.saturating_sub(prev))]);
}

pub fn host_superseded() {
    if enabled() {
        bump(&HOST_SUPERSEDED);
    }
}

pub fn host_stale() {
    if enabled() {
        bump(&HOST_STALE);
    }
}

pub fn host_tick(trigger: TickTrigger) {
    if enabled() {
        bump(match trigger {
            TickTrigger::HostFrame => &TICK_HOST,
            TickTrigger::Timer => &TICK_TIMER,
            TickTrigger::Input => &TICK_INPUT,
        });
    }
}

pub fn host_defer() {
    if enabled() {
        bump(&TICK_DEFER);
    }
}

pub fn enc_nochange() {
    if enabled() {
        bump(&ENC_NOCHANGE);
    }
}

pub fn enc_busy() {
    if enabled() {
        bump(&ENC_BUSY);
    }
}

/// Start time for [`enc_done`], taken only while enabled.
pub fn start() -> Option<Instant> {
    enabled().then(Instant::now)
}

/// One zero-copy encode call that began at `started`; `bytes` is the output of a
/// successful call that produced data.
pub fn enc_done(started: Option<Instant>, bytes: Option<usize>) {
    let Some(started) = started else { return };
    let now = Instant::now();
    let us = duration_us(now.saturating_duration_since(started));
    bump(&ENC_CALLS);
    ENC_US_SUM.fetch_add(us, Ordering::Relaxed);
    ENC_US_MAX.fetch_max(us, Ordering::Relaxed);
    if let Some(bytes) = bytes {
        bump(&ENC);
        ENC_BYTES.fetch_add(bytes as u64, Ordering::Relaxed);
        ENC_BYTES_MAX.fetch_max(bytes as u64, Ordering::Relaxed);
        mark(&ENC_IV, now);
    }
}

/// One delivery to the Python callback that began at `started`.
pub fn deliver_done(started: Option<Instant>) {
    let Some(started) = started else { return };
    bump(&DELIVER);
    DELIVER_US_MAX.fetch_max(duration_us(started.elapsed()), Ordering::Relaxed);
}

pub fn pointer_command() {
    if enabled() {
        bump(&PTR_CMD);
        mark(&PTR_IV, Instant::now());
    }
}

pub fn pointer_fake_input(delivered: bool) {
    if !enabled() {
        return;
    }
    if delivered {
        bump(&PTR_FI);
        bump(&PTR_FI_TOTAL);
    } else {
        bump(&PTR_FI_FAIL);
    }
}

fn move_bucket(moves: u64) -> usize {
    moves.min(3) as usize
}

/// Nearest-rank `p` percentile of an ascending, non-empty slice.
fn percentile(sorted: &[u32], p: f64) -> u32 {
    let rank = (p * sorted.len() as f64).ceil() as usize;
    sorted[rank.clamp(1, sorted.len()) - 1]
}

fn interval_summary(mut samples: Vec<u32>) -> String {
    if samples.is_empty() {
        return "-".to_string();
    }
    samples.sort_unstable();
    let ms = |us: u32| us as f64 / 1000.0;
    format!(
        "{:.1}/{:.1}/{:.1}",
        ms(percentile(&samples, 0.5)),
        ms(percentile(&samples, 0.95)),
        ms(*samples.last().unwrap())
    )
}

/// Drain this second's counters into one `RD_PERF_PF` line, or `None` when disabled or
/// nothing was recorded.
pub fn take_line() -> Option<String> {
    if !enabled() {
        return None;
    }
    let take = |c: &AtomicU64| c.swap(0, Ordering::Relaxed);
    let kwin_cb = take(&KWIN_CB);
    let kwin_video = take(&KWIN_VIDEO);
    let kwin_cursor = take(&KWIN_CURSOR);
    let kwin_noslot = take(&KWIN_NOSLOT);
    let kwin_iv = take_samples(&KWIN_IV);
    let host_superseded = take(&HOST_SUPERSEDED);
    let host_stale = take(&HOST_STALE);
    let tick_host = take(&TICK_HOST);
    let tick_timer = take(&TICK_TIMER);
    let tick_input = take(&TICK_INPUT);
    let tick_defer = take(&TICK_DEFER);
    let enc_nochange = take(&ENC_NOCHANGE);
    let enc_busy = take(&ENC_BUSY);
    let enc = take(&ENC);
    let enc_iv = take_samples(&ENC_IV);
    let enc_bytes = take(&ENC_BYTES);
    let enc_bytes_max = take(&ENC_BYTES_MAX);
    let enc_calls = take(&ENC_CALLS);
    let enc_us_sum = take(&ENC_US_SUM);
    let enc_us_max = take(&ENC_US_MAX);
    let deliver = take(&DELIVER);
    let deliver_us_max = take(&DELIVER_US_MAX);
    let ptr_cmd = take(&PTR_CMD);
    let ptr_iv = take_samples(&PTR_IV);
    let ptr_fi = take(&PTR_FI);
    let ptr_fi_fail = take(&PTR_FI_FAIL);
    let mv: [u64; 4] = std::array::from_fn(|i| take(&MV_PER_FRAME[i]));
    let counts = [
        kwin_cb, kwin_video, kwin_cursor, kwin_noslot, host_superseded, host_stale, tick_host,
        tick_timer, tick_input, tick_defer, enc_nochange, enc_busy, enc, enc_calls, deliver,
        ptr_cmd, ptr_fi, ptr_fi_fail,
    ];
    if counts.iter().all(|&c| c == 0) {
        return None;
    }
    let unix_ms = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis());
    let enc_ms_avg = if enc_calls == 0 { 0.0 } else { enc_us_sum as f64 / enc_calls as f64 / 1000.0 };
    Some(format!(
        "RD_PERF_PF t={unix_ms} kwin_cb={kwin_cb} kwin_video={kwin_video} kwin_cursor={kwin_cursor} \
         kwin_noslot={kwin_noslot} kwin_iv={} host_superseded={host_superseded} \
         host_stale={host_stale} tick_host={tick_host} tick_timer={tick_timer} \
         tick_input={tick_input} tick_defer={tick_defer} enc_nochange={enc_nochange} \
         enc_busy={enc_busy} enc={enc} enc_iv={} enc_kb={} enc_kb_max={} enc_ms={:.1}/{:.1} \
         deliver={deliver} deliver_ms_max={:.1} ptr_cmd={ptr_cmd} ptr_iv={} ptr_fi={ptr_fi} \
         ptr_fi_fail={ptr_fi_fail} mv_per_frame={}/{}/{}/{}",
        interval_summary(kwin_iv),
        interval_summary(enc_iv),
        enc_bytes / 1024,
        enc_bytes_max / 1024,
        enc_ms_avg,
        enc_us_max as f64 / 1000.0,
        deliver_us_max as f64 / 1000.0,
        interval_summary(ptr_iv),
        mv[0],
        mv[1],
        mv[2],
        mv[3],
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn interval_summary_reports_nearest_rank_percentiles() {
        assert_eq!(interval_summary(Vec::new()), "-");
        assert_eq!(interval_summary(vec![16_700]), "16.7/16.7/16.7");
        let samples: Vec<u32> = (1..=100).rev().map(|i| i * 1000).collect();
        assert_eq!(interval_summary(samples), "50.0/95.0/100.0");
    }

    #[test]
    fn move_bucket_folds_three_and_above() {
        assert_eq!(
            [0, 1, 2, 3, 4, 40].map(move_bucket),
            [0, 1, 2, 3, 3, 3]
        );
    }

    #[test]
    fn mark_caps_samples() {
        let interval = Mutex::new(Interval::new());
        let t0 = Instant::now();
        for i in 0..(MAX_SAMPLES as u64 + 10) {
            mark(&interval, t0 + Duration::from_millis(i));
        }
        assert_eq!(take_samples(&interval).len(), MAX_SAMPLES);
        assert!(take_samples(&interval).is_empty());
    }
}
