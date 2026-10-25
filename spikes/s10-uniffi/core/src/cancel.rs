// SPDX-License-Identifier: GPL-3.0-or-later
//! Async cancellation.
//!
//! UniFFI 0.32.2's Swift `uniffiRustCallAsync` polls the Rust future inside `withUnsafeContinuation`
//! and never installs a `withTaskCancellationHandler`, so cancelling the Swift `Task` does **not**
//! reach Rust: the future runs to completion and is only freed afterwards. [`sleep_naive`] proves it.
//!
//! The pattern we propose for tombolo-core: every long-running async export takes a [`CancelToken`]
//! (a UniFFI object). A tiny Swift wrapper cancels the token from `withTaskCancellationHandler`.
//! Rust races the work against the token; on cancel the work future — and the runtime task it
//! spawned, via [`AbortOnDrop`] — is dropped. [`sleep_cancellable`] proves it.
//!
//! The opposite direction already works: when Rust drops the future of a foreign async method,
//! UniFFI calls Swift's "dropped" callback, which cancels the Swift `Task` running the method.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::task::{Context, Poll};
use std::time::Duration;

use tokio::sync::Notify;
use tokio::task::{JoinError, JoinHandle};

use crate::util::{Guard, now_ns, record};
use crate::{CoreError, runtime};

#[derive(uniffi::Object, Default)]
pub struct CancelToken {
    flag: AtomicBool,
    at_ns: AtomicU64,
    notify: Notify,
}

#[uniffi::export]
impl CancelToken {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Idempotent; safe to call from any thread (Swift calls it from the cancellation handler).
    pub fn cancel(&self) {
        if !self.flag.swap(true, Ordering::SeqCst) {
            self.at_ns.store(now_ns(), Ordering::SeqCst);
            self.notify.notify_waiters();
        }
    }

    pub fn is_cancelled(&self) -> bool {
        self.flag.load(Ordering::SeqCst)
    }

    /// `clock_now_ns()` timestamp of the first `cancel()`, 0 if never cancelled.
    pub fn cancelled_at_ns(&self) -> u64 {
        self.at_ns.load(Ordering::SeqCst)
    }
}

impl CancelToken {
    pub async fn cancelled(&self) {
        loop {
            let notified = self.notify.notified();
            let mut notified = std::pin::pin!(notified);
            notified.as_mut().enable(); // register before checking the flag: no lost wake-up
            if self.flag.load(Ordering::SeqCst) {
                return;
            }
            notified.await;
        }
    }
}

/// A `JoinHandle` that aborts its task when dropped, so dropping the awaiting future also stops
/// the work it spawned on the runtime (a bare `JoinHandle` would detach and leak the task).
pub struct AbortOnDrop<T>(pub JoinHandle<T>);

impl<T> Future for AbortOnDrop<T> {
    type Output = Result<T, JoinError>;
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        Pin::new(&mut self.0).poll(cx)
    }
}

impl<T> Drop for AbortOnDrop<T> {
    fn drop(&mut self) {
        self.0.abort();
    }
}

pub fn spawn<F>(f: F) -> AbortOnDrop<F::Output>
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    AbortOnDrop(runtime().spawn(f))
}

/// Runs `fut` until it finishes or `token` fires; on cancel, `fut` is dropped immediately.
pub async fn with_cancel<T>(
    token: Option<&CancelToken>,
    fut: impl Future<Output = Result<T, CoreError>>,
) -> Result<T, CoreError> {
    match token {
        None => fut.await,
        Some(t) => {
            tokio::select! {
                biased;
                _ = t.cancelled() => Err(CoreError::Cancelled),
                r = fut => r,
            }
        }
    }
}

async fn sleep_on_runtime(ms: u64, probe: u64) -> Result<u64, CoreError> {
    spawn(async move {
        let mut g = Guard::new(probe, "runtime_task");
        tokio::time::sleep(Duration::from_millis(ms)).await;
        g.done();
        now_ns()
    })
    .await
    .map_err(CoreError::internal)
}

/// No token: demonstrates that Swift Task cancellation is not propagated by UniFFI 0.32.
#[uniffi::export]
pub async fn sleep_naive(ms: u64, probe: u64) -> Result<u64, CoreError> {
    let mut outer = Guard::new(probe, "export_future");
    let r = sleep_on_runtime(ms, probe).await;
    outer.done();
    r
}

/// With token: Swift's cancellation handler calls `token.cancel()`; the work future and its runtime
/// task are dropped; returns `CoreError::Cancelled`.
#[uniffi::export]
pub async fn sleep_cancellable(ms: u64, probe: u64, token: Arc<CancelToken>) -> Result<u64, CoreError> {
    let mut outer = Guard::new(probe, "export_future");
    let r = with_cancel(Some(&token), async {
        let mut w = Guard::new(probe, "work_future");
        let r = sleep_on_runtime(ms, probe).await;
        w.done();
        r
    })
    .await;
    if matches!(r, Err(CoreError::Cancelled)) {
        record(probe, "rust_observed_token_cancel");
    }
    outer.done();
    r
}
