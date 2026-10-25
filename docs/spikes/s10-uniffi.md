# S10 — UniFFI integration: hardware-key callbacks, cancellation, threading, 60 fps payloads

- **Task:** P0-12 (Rust + Swift half). Kotlin / Android Keystore half: **blocked — needs Android toolchain (scheduled)**.
- **Date:** 2026-10-26 · **Branch:** `p0/12-uniffi` · **Code:** [`spikes/s10-uniffi/`](../../spikes/s10-uniffi/README.md) (throwaway)
- **Status:** Swift half measured; verdicts below. Two items need a person or other hardware (marked).

## Question

Can `tombolo-core` (Rust, exposed through UniFFI) —

1. call back into the platform to **sign with a hardware key** (Secure Enclave, Touch ID policy) during a session handshake;
2. handle **async cancellation** in both directions (Swift `Task` cancel → Rust future dropped; Rust drop → Swift task cancelled);
3. have a clear, documented **thread ownership** model with known deadlock hazards;
4. carry **1080p60 encoded-video-sized payloads** across the FFI **without per-frame copies** and with **< 1 frame (16.7 ms) added latency** — and is the added latency ≪ 1 ms?

Acceptance criteria (from [`plans/phase-0.md`](../plans/phase-0.md), P0-12): Rust → Swift callback signing
with a Secure Enclave key (Touch ID policy); Rust → Kotlin callback signing with a Keystore key; async
cancellation; 30-min 1080p60-sized byte stream through the FFI with zero-copy buffers; added latency
< 1 frame; thread ownership documented.

## Setup

| Item | Value |
|---|---|
| Mac | Apple M4 Pro (12 cores), 48 GB, macOS 27.0.1 — **shared with other agents' jobs** (load recorded per run) |
| Rust | 1.98.0, edition 2024; `uniffi` 0.32.2 (current release, proc-macro style, library-mode bindgen), `tokio` 1.54.1, `p256` 0.14.0 (`ecdsa`), `async-trait` 0.1.92, `parking_lot` 0.13.0 |
| Swift | 6.4 (swiftlang-6.4.0.34.1), **Command Line Tools only** — SwiftPM, no Xcode / `xcodebuild` / XCFramework |
| Linking | Rust `staticlib` linked through a SwiftPM `systemLibrary` target (`link "s10_core"` + `-L rust-lib`); harness binary 2.6 MB with the core statically linked |
| Crypto | CryptoKit `SecureEnclave.P256.Signing.PrivateKey` (non-persistent); verification in Rust with `p256::ecdsa::VerifyingKey` |
| Swift modes | harness: Swift 6 language mode; generated bindings module: Swift 5 mode (see finding F2) |

## Method

The crate (`spikes/s10-uniffi/core`) owns one process-wide multi-threaded tokio runtime (2 workers,
named `s10-core-rt`). Exported async functions are thin: they spawn the real work onto that runtime
and await an `AbortOnDrop<JoinHandle>`, so whatever thread the foreign side polls from only ever runs
trivial code, and dropping the exported future aborts the work. Probes record `(event, clock, thread)`
— `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` on both sides, so Rust and Swift timestamps are directly
comparable — and `Drop` guards record whether a future was dropped before or after completion.

- **Signing.** Foreign async trait `Signer { fn public_key() -> Vec<u8>; async fn sign(Vec<u8>) -> Result<Vec<u8>, SignerError> }`.
  `handshake()` builds a transcript (`label ‖ 32-byte random nonce ‖ SHA-256(pubkey) ‖ timestamp`),
  calls `sign` from a runtime worker, verifies DER or raw (r‖s) ECDSA-P256/SHA-256 with `p256`. The
  Swift signer runs the blocking SE call on a private serial queue (never on the cooperative pool)
  and invalidates its `LAContext` when its task is cancelled. Negative tests: a signer that signs a
  modified message; `verify_p256` with a bit-flipped signature and with another key.
- **Touch ID policy.** Unattended: an SE key with `[.privateKeyUsage, .userPresence]` plus an
  `LAContext` with `interactionNotAllowed = true` must refuse to sign. Manual: `s10-harness touchid`.
- **Cancellation.** C1 Swift cancels a plain UniFFI async call; C2 the same call with a `CancelToken`
  wrapper (30 repetitions); C3 Rust times out a pending foreign async `sign`; C4 Swift cancels a
  handshake while Rust is awaiting the Swift signer.
- **Threads.** Sync and async calls from the main actor, a detached task and a plain `Thread`;
  64-deep Rust → Swift → Rust re-entrancy; a Rust lock held across a callback that re-enters;
  a blocking Rust API on the main thread whose callback needs the main actor; FFI call overhead.
- **Media.** One producer thread stands in for the QUIC receive task. Per frame it does exactly one
  *reassembly* copy from a static "receive buffer" into the frame's destination, stamps a 32-byte
  header (`seq ‖ address of the Rust buffer ‖ len ‖ magic`) and a trailing `seq`, timestamps it and
  publishes it. Seven delivery designs differ only in what happens next:

  | Design | Rust → Swift | FFI calls / frame |
  |---|---|---|
  | `vec-pull` (a) | blocking `next_vec()` returns `VecFrame { …, data: Vec<u8> }` → Swift `Data` | 2 + RustBuffer free |
  | `vec-async` (a) | `async next_vec_async()` → same record | UniFFI future: new + poll(s) + complete + free |
  | `vec-callback` (b) | Rust thread calls Swift `FrameSink.on_frame(VecFrame)` | 1 callback + RustBuffer free |
  | `handle-pull` (c) | blocking `next_handle()` returns `FrameRef { handle: Arc<FrameHandle>, ptr, len, … }`; Swift wraps `ptr` in `Data(bytesNoCopy:…, deallocator: .custom)` that retains the handle | 2 + RustBuffer free + handle free |
  | `ring-pull` (c) | shared-memory SPSC ring: blocking `ring_wait(next) -> u64` returns the head; Swift reads 128-byte slot descriptors and payload straight from Rust's memory, then `ring_release(seq)` | ≈ 2 per batch + 2 per frame, scalars only |
  | `ring-async` (c) | same, `async ring_wait_async(next)` | UniFFI future per batch + 2 per frame |
  | `ring-callback` (c) | Rust thread calls Swift `SlotSink.on_slots(from, to)` (scalars); Swift releases from inside the callback (re-entrant) | 1 callback per batch + 2 per frame |

  Swift does identical work per frame in every design: validate header/trailer, **compare the
  payload address with the Rust buffer address stamped in the header** (equal ⇒ Swift is reading
  Rust's memory, i.e. zero copies), touch one byte per 4 KiB page, record `now − produced_ns`.
  *Added latency* = producer publish → bytes readable and validated in Swift (includes the
  consumer thread's wake-up). Two experiments:
  - **paced:** 60 fps, P-frames uniform 25–40 KB, a 250 KB keyframe every 120 frames (2 s), **2 min
    per design** (7 200 frames). Deviation: the plan asks for 30 min; 2 min was run because other
    agents share this Mac. CPU = process `getrusage` (all threads, both languages) / wall time;
    memory = `phys_footprint` sampled every 60 frames.
  - **stress:** frames prefilled (producer runs to completion first), then the drain is timed; fixed
    sizes 4 KiB × 16 384, 64 KiB × 2 048, 256 KiB × 512, 1 MiB × 128. Isolates per-frame FFI cost.

## Raw numbers

### Findings from the generated code (UniFFI 0.32.2)

- **F1 — Swift → Rust cancellation is not implemented.** `uniffiRustCallAsync` (template
  `Async.swift`) polls inside `withUnsafeContinuation` and never installs a cancellation handler;
  `rust_future_cancel` is generated but never called, and `CALL_CANCELLED` in `Helpers.swift` is
  `fatalError("Cancellation not supported yet")`. The Rust future is only dropped by
  `rust_future_free`, after it completes.
- **F1b — Rust → Swift cancellation is implemented.** Dropping a foreign-future triggers
  `uniffiForeignFutureDroppedCallback`, which calls `task.cancel()` on the Swift `Task` running the
  foreign async method.
- **F2 — Swift 6 mode fails.** With Swift 6.4 in Swift 6 language mode the generated file does not
  compile when the interface has async foreign traits (`uniffiTraitInterfaceCallAsync` passes
  non-`Sendable` closures to `Task {}` → "passing closure as a 'sending' parameter risks causing data
  races"). Compiling just the generated module in Swift 5 mode works; the app code can stay Swift 6.
- **F3 — `Vec<u8>` crosses by serialisation, byte by byte.** Rust: `Lower for Vec<T>` writes an
  `i32` length then calls `u8::write` per element into a fresh `RustBuffer` (copy 1, not a
  `memcpy`). Swift: `FfiConverterData.read` → `readBytes` allocates a zero-filled `[UInt8]` and copies
  into it (copy 2), then `Data([UInt8])` copies again (copy 3), then frees the `RustBuffer` with
  another FFI call. **3 payload copies + 1 zero-fill + 3 heap allocations per frame**, in both
  directions of a record or callback.
- **F4 — object method calls cost an extra FFI call.** Every method on a UniFFI object first calls
  `uniffi_…_fn_clone_<type>` (an `Arc` increment) to pass a handle, then the method (12.4 ns vs 4 ns
  for a free function, below).

### Signing (`results/sign.txt`, `results/touchid-check.txt`)

SIGN_PLACEHOLDER

### Cancellation (`results/cancel.txt`)

CANCEL_PLACEHOLDER

### Threads and call overhead (`results/threads.txt`, `results/bench.txt`)

THREADS_PLACEHOLDER

### Media — stress, prefilled drain (`results/stress.txt`)

STRESS_PLACEHOLDER

### Media — paced 1080p60, 2 min per design (`results/media-2min.txt`)

MEDIA_PLACEHOLDER

## Thread ownership

Measured with `s10-harness threads` and the thread fields of `sign`/`media` (Rust `ThreadInfo` and
Swift `swiftThread()` report pthread id, main-thread flag, libdispatch queue label and pthread name;
for threads libdispatch does not own, such as Rust's, it reports the default
`com.apple.root.default-qos.overcommit` label, so the pthread name is the authoritative field there).

**Who owns which threads**

| Thread(s) | Owner | Runs |
|---|---|---|
| main thread / main actor | Swift | UI. Never blocks on Rust (rule T4) |
| cooperative pool (`com.apple.root.default-qos.cooperative`) | Swift runtime | Swift async code; **UniFFI's polling of Rust futures**; Swift side of async foreign callbacks |
| `s10-core-rt` × 2 (tokio multi-thread runtime) | Rust core, process-global | all core async work: handshake, timers, (later) QUIC tasks; calls into Swift foreign traits |
| `s10-producer`, `s10-deliver` (std threads) | Rust core | media producer (stand-in for QUIC receive) and the dedicated thread that invokes media callbacks |
| `s10-consumer` (Foundation `Thread`) | Swift app | blocking pulls (`next_vec`, `next_handle`, `ring_wait`) |
| `s10.secure-enclave.sign` (serial `DispatchQueue`) | Swift signer | the blocking CryptoKit / Secure Enclave call (Touch ID wait) |

**Where each kind of call executes**

- *Sync Swift → Rust:* on the caller's thread, including the main thread (`rust_sync_call_from_main_actor: main=true`).
- *Async Swift → Rust:* UniFFI's `uniffiRustCallAsync` calls `rust_future_poll` from the awaiting Swift
  task, so **the Rust future's `poll` runs on a Swift executor thread**. Measured: called from the
  main actor, first and resumed polls ran on the cooperative pool (`main=false`), because the
  generated `uniffiRustCallAsync` is a `nonisolated` async function and hops off the main actor.
  Caveat: if the bindings module is ever compiled with `NonisolatedNonsendingByDefault` (SE-0461),
  nonisolated async functions stay on the caller's actor and these polls would move to the main
  thread — another reason exports must stay thin (T1).
- *Rust wake-ups:* the waker fires on whatever thread completes the work (`s10-core-rt`, producer);
  UniFFI's continuation callback only resumes the Swift continuation there; the next poll is back on
  Swift's executor.
- *Sync Rust → Swift callback:* on the Rust thread that calls it — a runtime worker or a dedicated
  thread (`vec-callback`/`ring-callback` consumers ran on `s10-deliver`). While it runs, that thread
  is blocked.
- *Async Rust → Swift callback:* UniFFI starts an unstructured Swift `Task {}` from the Rust thread
  and returns immediately; the Swift method runs on the cooperative pool; its completion calls back
  into Rust from that Swift thread and wakes the Rust task, which resumes on `s10-core-rt`
  (handshake: `rust_runtime_task_calls_signer` and `rust_after_foreign_future_completed` on
  `s10-core-rt`, `swift_sign_method_entry` on the cooperative pool, the SE call on
  `s10.secure-enclave.sign`).
- *Re-entrancy:* Rust → Swift → Rust → … nests on one stack; 64 levels deep returned correctly.

**Rules for tombolo-core and the apps**

- **T1 — the core owns its runtime; exports are thin.** One process-wide tokio runtime in a static
  (dropping a `Runtime` from an async context panics, and the last `Arc` of an exported object can be
  released on any thread). Exported async functions spawn onto it and await an `AbortOnDrop`
  handle; nothing CPU-heavy runs in a foreign-polled `poll`.
- **T2 — long platform operations are async foreign methods.** Hardware signing can wait seconds for
  Touch ID / BiometricPrompt; as a sync callback it would pin a runtime worker for that long. The
  Swift side then moves the blocking call off the cooperative pool (serial queue + continuation).
- **T3 — sync foreign callbacks must not block and must not hop to the main thread synchronously**
  (`DispatchQueue.main.sync`, `MainActor.assumeIsolated` from a Rust thread): the main thread may
  itself be inside a Rust call.
- **T4 — no blocking Rust calls on the main thread or the cooperative pool.** Blocking pulls run on a
  dedicated thread (or use the async variant). *Demonstrated hazard:* a blocking Rust API called on
  the main thread whose foreign callback needs the main actor **deadlocks** (`block_on_foreign`
  timed out after 1 000 ms; the same call from a background thread completed in < 1 ms).
- **T5 — never hold a lock across a language boundary.** Because re-entrant calls happen on the same
  thread, a non-reentrant lock held while calling Swift deadlocks if Swift calls back into a Rust API
  that takes it. *Demonstrated:* with the lock held the callback's `try_lock_for(200 ms)` failed;
  copy state out and release first, then call out (worked).
- **T6 — cancellation is explicit Swift → Rust** (`CancelToken` + `withTaskCancellationHandler`
  wrapper, finding F1) and automatic Rust → Swift (F1b); Swift implementations of async foreign
  methods must honour task cancellation (the SE signer calls `LAContext.invalidate()`).
- **T7 — media memory is Rust-owned and borrowed by Swift** for exactly the window between "slot
  readable" and `ring_release` (or the life of a `FrameHandle`); the consumer is a dedicated thread
  or the decoder's queue, never the main thread.

## Verdict per criterion

VERDICT_PLACEHOLDER

## Consequences for the plan

CONSEQUENCES_PLACEHOLDER
