// SPDX-License-Identifier: GPL-3.0-or-later
//! Thread ownership probes, re-entrancy and deadlock-hazard demonstrations, call-overhead benches.

use std::sync::Arc;
use std::time::Duration;

use parking_lot::Mutex;

use crate::cancel::spawn;
use crate::runtime;
use crate::util::{ThreadInfo, now_ns, thread_info};

/// Sync exports run on the caller's thread — this just reports which one.
#[uniffi::export]
pub fn current_thread() -> ThreadInfo {
    thread_info()
}

#[derive(uniffi::Record, Debug)]
pub struct AsyncThreadReport {
    /// Where UniFFI polled the exported future the first time (the Swift caller's executor).
    pub first_poll: ThreadInfo,
    /// Where the spawned work ran (a core runtime worker).
    pub runtime_task: ThreadInfo,
    /// Where the exported future was polled again after being woken by the runtime.
    pub resumed_poll: ThreadInfo,
}

#[uniffi::export]
pub async fn async_poll_threads() -> AsyncThreadReport {
    let first_poll = thread_info();
    let runtime_task = spawn(async {
        tokio::time::sleep(Duration::from_millis(2)).await; // force a real suspension + wake
        thread_info()
    })
    .await
    .expect("join");
    let resumed_poll = thread_info();
    AsyncThreadReport { first_poll, runtime_task, resumed_poll }
}

// ---------- re-entrancy: Rust -> Swift -> Rust on one stack ----------

#[uniffi::export(with_foreign)]
pub trait Reentrant: Send + Sync {
    /// Swift's implementation calls `reenter(self, depth - 1)` back into Rust.
    fn call(&self, depth: u32) -> u32;
}

#[uniffi::export]
pub fn reenter(cb: Arc<dyn Reentrant>, depth: u32) -> u32 {
    if depth == 0 { 0 } else { cb.call(depth) + 1 }
}

// ---------- lock hazard: holding a Rust lock while calling foreign code ----------

static STATE: Mutex<u64> = Mutex::new(0);

#[uniffi::export(with_foreign)]
pub trait LockProbe: Send + Sync {
    /// Swift's implementation calls `try_touch_state` back into Rust and returns its result.
    fn on_callback(&self) -> bool;
}

/// Takes the lock that `STATE` guards. With a plain `lock()` this would deadlock (parking_lot) or
/// panic/deadlock (std) when called re-entrantly; we use a timed try-lock to *detect* it instead.
#[uniffi::export]
pub fn try_touch_state(timeout_ms: u64) -> bool {
    match STATE.try_lock_for(Duration::from_millis(timeout_ms)) {
        Some(mut g) => {
            *g += 1;
            true
        }
        None => false,
    }
}

/// `hold_lock = true`: the anti-pattern — call foreign code while holding a Rust lock; the
/// callback's re-entrant call cannot take the lock. `false`: the safe pattern — copy state out,
/// release, then call out.
#[uniffi::export]
pub fn lock_hazard_demo(probe: Arc<dyn LockProbe>, hold_lock: bool) -> bool {
    if hold_lock {
        let g = STATE.lock();
        let ok = probe.on_callback();
        drop(g);
        ok
    } else {
        let _snapshot = *STATE.lock();
        probe.on_callback()
    }
}

// ---------- main-thread hazard: sync Rust API blocking on a MainActor callback ----------

#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait AsyncWork: Send + Sync {
    async fn run(&self) -> u64;
}

/// A *blocking* Rust API that waits for a foreign async callback. If the caller is the main thread
/// and the callback needs the main thread (MainActor), this deadlocks; we time out to show it.
/// Returns elapsed ms, or -1 on timeout.
#[uniffi::export]
pub fn block_on_foreign(work: Arc<dyn AsyncWork>, timeout_ms: u64) -> i64 {
    let t0 = now_ns();
    let (tx, rx) = std::sync::mpsc::channel();
    runtime().spawn(async move {
        let v = work.run().await;
        let _ = tx.send(v);
    });
    match rx.recv_timeout(Duration::from_millis(timeout_ms)) {
        Ok(_) => ((now_ns() - t0) / 1_000_000) as i64,
        Err(_) => -1,
    }
}

// ---------- call-overhead micro-benchmarks ----------

#[uniffi::export]
pub fn noop() {}

#[uniffi::export]
pub fn echo_u64(x: u64) -> u64 {
    x
}

#[uniffi::export]
pub async fn noop_async() -> u64 {
    0
}

/// Async call that genuinely suspends and is woken from a runtime worker.
#[uniffi::export]
pub async fn yield_async() -> u64 {
    spawn(async { 0u64 }).await.unwrap_or(0)
}

#[uniffi::export(with_foreign)]
pub trait Ping: Send + Sync {
    fn ping(&self, x: u64) -> u64;
}

/// Rust -> Swift sync callback, `n` times; returns total elapsed ns.
#[uniffi::export]
pub fn bench_callbacks(cb: Arc<dyn Ping>, n: u64) -> u64 {
    let t0 = now_ns();
    let mut acc = 0u64;
    for i in 0..n {
        acc = acc.wrapping_add(cb.ping(i));
    }
    std::hint::black_box(acc);
    now_ns() - t0
}

/// Rust -> Swift async callback awaited `n` times on a runtime worker; returns total elapsed ns.
#[uniffi::export]
pub async fn bench_async_callbacks(cb: Arc<dyn AsyncWork>, n: u64) -> u64 {
    spawn(async move {
        let t0 = now_ns();
        for _ in 0..n {
            std::hint::black_box(cb.run().await);
        }
        now_ns() - t0
    })
    .await
    .unwrap_or(0)
}

/// Calibration: ns for one memcpy of `bytes` (median of `iters`), to express costs in "copies".
#[uniffi::export]
pub fn bench_memcpy(bytes: u64, iters: u32) -> u64 {
    let src = vec![0xA5u8; bytes as usize];
    let mut dst = vec![0u8; bytes as usize];
    let mut samples = Vec::with_capacity(iters as usize);
    for _ in 0..iters {
        let t0 = now_ns();
        dst.copy_from_slice(std::hint::black_box(&src));
        std::hint::black_box(&mut dst);
        samples.push(now_ns() - t0);
    }
    samples.sort_unstable();
    samples[samples.len() / 2]
}
