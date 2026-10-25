//! One clock for all three processes (driver/proxy, phone, Mac): CLOCK_MONOTONIC_RAW is
//! system-wide on macOS, so one-way latencies between processes on this Mac need no
//! clock-offset estimation.

use std::time::Duration;

pub fn now_ns() -> u64 {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: valid pointer to a timespec.
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC_RAW, &mut ts) };
    ts.tv_sec as u64 * 1_000_000_000 + ts.tv_nsec as u64
}

pub async fn sleep_until_ns(t: u64) {
    let n = now_ns();
    if t > n {
        tokio::time::sleep(Duration::from_nanos(t - n)).await;
    }
}

/// Blocking sleep for proxy threads (sub-millisecond resolution, unlike tokio's timer).
pub fn thread_sleep_until_ns(t: u64) {
    let n = now_ns();
    if t > n + 20_000 {
        std::thread::sleep(Duration::from_nanos(t - n));
    }
}

/// CPU time (user + system) of this process, in microseconds.
pub fn cpu_us() -> u64 {
    // SAFETY: zeroed rusage is a valid out-parameter.
    let mut ru: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut ru) };
    let tv = |t: libc::timeval| t.tv_sec as u64 * 1_000_000 + t.tv_usec as u64;
    tv(ru.ru_utime) + tv(ru.ru_stime)
}

/// Small deterministic PRNG (xorshift64*), so both transports see the same frame sizes.
#[derive(Clone)]
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        Self(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
    }
    pub fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
    /// Uniform in [0, 1).
    pub fn f64(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }
    pub fn range(&mut self, lo: u64, hi: u64) -> u64 {
        lo + self.next_u64() % (hi - lo + 1)
    }
}
