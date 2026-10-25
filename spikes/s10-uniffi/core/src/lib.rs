// SPDX-License-Identifier: GPL-3.0-or-later
//! Spike S10 — UniFFI integration. Throwaway spike code: see `docs/spikes/s10-uniffi.md`.
//!
//! Modules:
//! - [`handshake`]: foreign `Signer` trait (async) called by Rust during a fake session handshake,
//!   signature verified with `p256`.
//! - [`cancel`]: async functions and the explicit `CancelToken` needed because UniFFI 0.32's Swift
//!   bindings do not propagate Swift `Task` cancellation to the Rust future.
//! - [`media`]: seven frame-delivery designs (Vec pull/async/callback, handle pull, ring pull/async/callback).
//! - [`threads`]: thread-ownership probes, re-entrancy and deadlock-hazard demos, call-overhead benches.

uniffi::setup_scaffolding!();

pub mod cancel;
pub mod handshake;
pub mod media;
pub mod threads;
pub mod util;

use std::sync::OnceLock;

/// The core owns one process-wide multi-threaded tokio runtime. Exported async functions are thin
/// shims that spawn onto it, so the foreign executor only ever polls trivial futures.
///
/// Kept in a static (not inside an exported object) because dropping a `Runtime` from inside an async
/// context panics — and the last `Arc` of an exported object can be released on any thread.
pub(crate) fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("s10-core-rt")
            .enable_time()
            .build()
            .expect("tokio runtime")
    })
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("cancelled")]
    Cancelled,
    #[error("timed out after {ms} ms")]
    TimedOut { ms: u64 },
    #[error("signer failed: {reason}")]
    Signer { reason: String },
    #[error("signature rejected: {reason}")]
    Verify { reason: String },
    #[error("internal: {reason}")]
    Internal { reason: String },
}

impl CoreError {
    pub(crate) fn internal(e: impl std::fmt::Display) -> Self {
        CoreError::Internal { reason: e.to_string() }
    }
}
