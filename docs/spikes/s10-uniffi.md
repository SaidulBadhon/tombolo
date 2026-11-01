# S10 — UniFFI integration: hardware-key callbacks, cancellation, threading, 60 fps payloads

| | |
|---|---|
| **Spike** | S10 (Rust + Swift half; the Kotlin / Android Keystore half is deferred) |
| **Task** | P0-12 — see the [Phase 0 task plan](../plans/phase-0.md#acceptance-criteria-per-task) |
| **Pass criteria** | [§0.C](../implementation-plan.md#0c-spikes-each-produces-a-short-write-up-in-docsspikes): "30 min stable at 1080p60 with < 1 frame added latency" (if it fails: "move media framing out of the core"). P0-12: a Rust → Swift callback that signs with a Secure Enclave key (Touch ID policy) and a Rust → Kotlin callback that signs with a Keystore key; async cancellation; 30-min 1080p60-sized byte stream through the FFI with zero-copy buffers; added latency < 1 frame; thread ownership documented |
| **Spike code** | [`spikes/s10-uniffi/`](../../spikes/s10-uniffi/README.md) at commit `e6c5d6e1b4c66c59e26bb64979967f7370afe9ab`. Results come from three builds; see [Which build produced which result](#which-build-produced-which-result) |
| **Author(s)** | Claude Opus 5.5 (agent), for the maintainer |
| **Date(s) run** | 2026-10-26 – 2026-10-26 |
| **Status** | draft. Swift half measured; **timing numbers provisional** (loaded Mac). Outstanding: quiet re-run + required 30-min soak (scheduled after P0-15), manual Touch ID run, Kotlin half |

## Question

Can `tombolo-core` (Rust, exposed through UniFFI) do four things, which ADR-0003's "one Rust core for
both apps" depends on?

1. Call back into the platform to **sign with a hardware key** (Secure Enclave, Touch ID policy) during a session handshake.
2. Handle **async cancellation** in both directions: Swift `Task` cancel → Rust future dropped, and Rust drop → Swift task cancelled.
3. Follow a clear, documented **thread ownership** model with its deadlock hazards identified.
4. Carry **1080p60 encoded-video-sized payloads** across the FFI **without per-frame copies** and with **< 1 frame (16.7 ms) added latency**. Also: is the added latency ≪ 1 ms?

## Setup

**Devices**

| Role | Model | OS version and build | OEM skin / version | Notes (patch level, settings changed) |
|---|---|---|---|---|
| Phone | none | — | — | not used: the Kotlin half is deferred |
| Mac | Mac16,8 (Apple M4 Pro, 12 cores, 48 GB) | macOS 27.0.1 (26A434) | — | Secure Enclave + Touch ID present (`BiometryType=1`); no settings changed |

**Builds and tools**

| Component | Version / commit | How obtained |
|---|---|---|
| Spike code | `e6c5d6e1b4c66c59e26bb64979967f7370afe9ab` (latest); measured builds listed below | this repository |
| Rust | 1.98.0 (edition 2024) | rustup (preinstalled) |
| `uniffi` | 0.32.2: current release, proc-macro style, library-mode `uniffi-bindgen` | crates.io, `Cargo.lock` committed |
| Other crates | `tokio` 1.54.1, `p256` 0.14.0 (`ecdsa`), `sha2` 0.11.1, `async-trait` 0.1.92, `parking_lot` 0.13.0, `getrandom` 0.4.3 | crates.io |
| Swift | 6.4 (swiftlang-6.4.0.34.1), **Command Line Tools only**: SwiftPM, no Xcode / `xcodebuild` / XCFramework | preinstalled CLT |
| Linking | Rust `staticlib` linked through a SwiftPM `systemLibrary` target (`link "s10_core"` + `-L rust-lib`); harness binary 2.6 MB with the core statically linked (`otool -L` lists no Rust dylib) | `build.sh` |
| Crypto | CryptoKit `SecureEnclave.P256.Signing.PrivateKey` (non-persistent); verification with `p256::ecdsa::VerifyingKey` | system / crates.io |
| Swift language modes | harness: Swift 6; generated bindings module: Swift 5 (finding F2) | `Package.swift` |

<a id="which-build-produced-which-result"></a>**Which build produced which result**

| Result files | Run time (2026-10-26, local) | Build | Notes |
|---|---|---|---|
| `media-2min-run1-loaded.*` | 01:30–01:44 | working tree built at 01:28, identical to the code later committed as `a93ec9e` (core) + `17631c7` (harness) | no wake/crossing split (no `wakeUs` / `crossingUs` fields) |
| first `stress.*` (superseded) | 01:30 | same as run 1 | committed in `7309869`, replaced by the 04:08 re-run in `b49c57c` |
| `media-2min-run2.*` | 03:36–03:50 | `./build.sh` at 03:36 on merge `79b0286`; spike code identical to `17631c7` | no wake/crossing split |
| `media-2min-run3.*` | 03:53–04:07 | `4f5ae1f2339f270ed52f6ff98eea113cb359d243` (HEAD recorded in `media-2min-run3.env.txt`) | first build with the split |
| `sign.*`, `cancel.*`, `threads.*`, `bench.*`, `stress.*` | ≈ 04:08 | same `4f5ae1f` build | |
| `touchid-check.*` | ≈ 04:09 | `e6c5d6e1b4c66c59e26bb64979967f7370afe9ab` | `e6c5d6e` only shortened the signer error text (no BiometryDatabaseHash) |

**Environment:** no network involved; everything is in one process. The Mac was **shared with other
agents' jobs** throughout: SwiftPM test runs, a virtual machine, another spike's host app. The load
average is recorded at the start and end of every media design and sampled every 30–60 s
(`results/*.load.txt`). It ranged from 2 to 60 on 12 cores. AC power; thermal state not recorded.
The plan says performance runs should not overlap heavy jobs; that could not be arranged here, so the
latency split below separates scheduler delay from FFI cost.

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
  *Added latency* runs from producer publish to the bytes being readable and validated in Swift.
  Rust also stamps `delivered_ns` when it hands the frame over (just before a blocking pull returns,
  before invoking a callback, inside the async poll, or in the ring slot descriptor). That splits
  the latency in two:
  - **wake** = delivered − produced: the consumer thread being scheduled, plus, for async, UniFFI's
    waker → continuation → re-poll hop;
  - **crossing** = readable − delivered: lowering, the FFI return or callback, lifting, and Swift's access.

  Two experiments:
  - **paced:** 60 fps, P-frames uniform 25–40 KB, a 250 KB keyframe every 120 frames (2 s), **2 min
    per design** (7 200 frames each, 50 400 per run). Deviation: the plan asks for 30 min; 2 min
    was run as instructed, because other agents share this Mac. Three runs: run 1 (load 2–60, no
    split), run 2 (load 5–27, no split), run 3 (with the split; the headline numbers). CPU is process
    `getrusage` (all threads, both languages) divided by wall time; memory is `phys_footprint`,
    sampled every 60 frames.
  - **stress:** frames are prefilled (the producer runs to completion first), then the drain is
    timed. Fixed sizes: 4 KiB × 16 384, 64 KiB × 2 048, 256 KiB × 512, 1 MiB × 128. This isolates the
    per-frame FFI cost from any waiting.

  **Uncertainty:** clock resolution is 1 ns (`CLOCK_UPTIME_RAW`, shared by both sides). The
  dominant error is scheduling noise from other jobs on the Mac, which is why the wake/crossing split
  is reported. Percentiles come from n = 7 200 per design, so p99.9 rests on about 7 samples and the
  maximum on 1.

  **Physical steps needing a person:** only the manual Touch ID run (`s10-harness touchid`): touch the
  sensor when the sheet appears, then a second run where the sheet is left alone until it times out.

## Raw numbers

> **All timing numbers in this document are provisional.** Every run overlapped other agents'
> jobs on this Mac (load average 2–60 on 12 cores). A re-run on a quiet Mac is scheduled after P0-15,
> together with the required 30-minute soak. Functional results (verified signatures, cancellation
> behaviour, zero-copy address checks, integrity counts, deadlock demonstrations) do not depend on
> load and are not provisional.

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
  `uniffi_…_fn_clone_<type>` (an `Arc` increment) to pass a handle, then the method (9.6 ns vs 5.9 ns
  for a free function, below).

### Signing

Command: `s10-harness sign` and `s10-harness touchid-check` ([`sign.txt`](../../spikes/s10-uniffi/results/sign.txt),
[`sign.json`](../../spikes/s10-uniffi/results/sign.json), [`touchid-check.txt`](../../spikes/s10-uniffi/results/touchid-check.txt)).

| Run | n | Result |
|---|---|---|
| SE key (no access control), DER signature, Rust verifies with `p256` | 1 | `verified=true` |
| 50 handshakes, alternating DER / raw r‖s | 50 | all verified; `Signer.sign` round trip as measured by Rust (Swift task start, hop to the signing queue, SE operation, completion back into Rust) **p50 4 535 µs, p95 4 626 µs, max 4 633 µs** |
| Raw r‖s signature | 1 | `verified=true` |
| Negative: signer signs a modified message | 1 | rejected, `Verify(reason: "ECDSA verification failed: signature error")` |
| `verify_p256` helper: valid / bit-flipped signature / other key | 3 | `true` / `false` / `false` |
| `.userPresence` SE key, `LAContext.interactionNotAllowed = true` | 1 | key created; signing refused: `com.apple.LocalAuthentication -1004: User interaction required.` An earlier, unredacted run also reported `BiometryType=1` (Touch ID) with mechanisms biometry and passcode |
| `.userPresence` key with a person touching the sensor (`s10-harness touchid`) | 0 | **not run: needs a person** |

### Cancellation

Command: `s10-harness cancel` ([`cancel.txt`](../../spikes/s10-uniffi/results/cancel.txt), [`cancel.json`](../../spikes/s10-uniffi/results/cancel.json)).
Times are relative to the start of each case; all four cases passed, with 0 foreign-future handles left afterwards.

| Case | What happened (Swift side) | Rust evidence |
|---|---|---|
| C1 Swift `Task.cancel()` at 51.5 ms on a plain UniFFI async call (1 000 ms Rust sleep) | the call **returned a value after 1 009.8 ms** (`Task.isCancelled = true`) | `runtime_task:completed` at +1 009.75 ms, `export_future:dropped_after_completion` at +1 009.79 ms: **never dropped early** (finding F1) |
| C2 same call wrapped in `cancellable { token in … }` (30 runs) | threw `CoreError.Cancelled` 0.2 ms after the cancel | `work_future:dropped_before_completion`, `runtime_task:dropped_before_completion` (aborted). **Cancel → work future dropped: p50 18.2 µs, p95 21.4 µs, max 26.9 µs; cancel → runtime task dropped: p50 28.0 µs, p95 46.1 µs, max 65.2 µs** (n = 30) |
| C3 Rust 200 ms timeout on a pending foreign `sign` (Swift signer sleeps 5 s) | `TimedOut(ms: 200)` after 201.9 ms; **the Swift signer's `Task.sleep` threw `CancellationError` at 201.8 ms** | `rust_sign_timeout_dropped_foreign_future`, `foreign_sign_future:dropped_before_completion` |
| C4 Swift cancels a handshake at 102.8 ms while Rust awaits the Swift signer | `Cancelled` after 102.8 ms; Swift signer saw cancellation at 102.8 ms | `rust_observed_token_cancel` +102.799 ms → `foreign_sign_future:dropped_before_completion` +102.814 ms (15 µs) |

### Threads and call overhead

Commands: `s10-harness threads`, `s10-harness bench` ([`threads.txt`](../../spikes/s10-uniffi/results/threads.txt),
[`bench.txt`](../../spikes/s10-uniffi/results/bench.txt)). The thread map is interpreted in [Thread ownership](#thread-ownership) below.

| Check | Result |
|---|---|
| Rust → Swift → Rust re-entrancy, 64 levels on one stack | returned 64 |
| Rust lock held while calling Swift, Swift re-enters a Rust API taking the same lock | `try_lock_for(200 ms)` failed (would deadlock) |
| Same with the lock released before the call | succeeded |
| Blocking Rust API on the **main thread** whose foreign async callback needs the main actor | **deadlock**: timed out after 1 000 ms |
| Same API called from a background thread | completed in < 1 ms |
| Process threads during the test | 5 |

FFI call overhead (`bench`, loop-averaged, load ≈ 9):

| Call | ns / call |
|---|---|
| Swift → Rust sync free function (`noop`, `echo_u64`) | 5.9 / 6.9 |
| Swift → Rust object method (includes the `clone` handle call, F4) | 9.6 |
| Rust → Swift sync callback | 25.4 |
| Swift → Rust async, future ready on first poll | 213 |
| Swift → Rust async that suspends and is woken by a runtime worker | 10 808 |
| Rust → Swift async callback (Swift `Task` per call) | 11 767 |

### Media: stress, prefilled drain

Command: `s10-harness stress` ([`stress.txt`](../../spikes/s10-uniffi/results/stress.txt), [`stress.json`](../../spikes/s10-uniffi/results/stress.json)); load ≈ 9 at the time.
Prefilled drain cost per frame in ns, i.e. the CPU cost of moving one frame across the FFI and
touching it, with no waiting. `memcpy` is a hot-cache calibration copy of the same size.

| Frame size | vec-pull | vec-async | vec-callback | handle-pull | ring-pull | ring-async | ring-callback | memcpy |
|---|---|---|---|---|---|---|---|---|
| 4 KiB (n = 16 384) | 3 815 | 4 010 | 3 319 | 1 969 | 54 | 46 | 44 | 42 |
| 64 KiB (n = 2 048) | 30 110 | 29 172 | 27 661 | 2 228 | 151 | 106 | 102 | 625 |
| 256 KiB (n = 512) | 102 062 | 103 728 | 102 596 | 2 517 | 391 | 279 | 274 | 3 584 |
| 1 MiB (n = 128) | 577 959 | 611 384 | 619 499 | 3 707 | 1 576 | 5 334 | 1 092 | 14 209 |

- **Vec designs scale with size at ≈ 0.4 ns/byte (1.7–2.6 GB/s)**, which is 28–48 hot memcpys' worth
  at 64 KiB–1 MiB: the byte-wise Rust serialiser plus two Swift copies and a zero-fill (F3). That is
  ≈ 100 µs of CPU per 250 KB keyframe and ≈ 13 µs per 32 KB P-frame.
- **Handle and ring designs are size-independent**: ≈ 2–3.7 µs (handle: record lift, Swift object,
  `free` FFI call) and ≈ 50–400 ns up to 256 KiB (ring: scalars only, descriptor read in place). The
  1 MiB ring numbers are dominated by the page-touch loop (256 pages per frame).
- Zero-copy check: **0 / n** frames for every Vec design at every size, and **n / n** for every handle
  and ring design. Integrity failures: 0 everywhere.

### Media: paced 1080p60, 2 min per design

Command: `s10-harness media --seconds 120` ×3 ([run 3](../../spikes/s10-uniffi/results/media-2min-run3.txt) with
[JSON](../../spikes/s10-uniffi/results/media-2min-run3.json) and [load log](../../spikes/s10-uniffi/results/media-2min-run3.load.txt); [run 2](../../spikes/s10-uniffi/results/media-2min-run2.txt);
[run 1](../../spikes/s10-uniffi/results/media-2min-run1-loaded.txt)). Each design delivered 7 200 / 7 200 frames (247.2 MB,
2.06 MB/s ≈ 16.5 Mbit/s) in every run, with **0 producer drops, 0 sequence gaps and 0 integrity
failures**. No Rust frame handles or UniFFI foreign-future handles were left at the end.

**Run 3 (headline): end-to-end added latency, split into wake + crossing, µs, n = 7 200 per design**

| Design | e2e p50 | e2e p95 | e2e p99 | e2e p99.9 | e2e max | frames > 1 ms | frames > 16.7 ms | crossing p50 | crossing p99 | crossing p99.9 | crossing max | wake p99 | wake max | load start→end |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| vec-pull | 48.0 | 145.5 | 3 730.5 | 12 452.6 | 16 931.0 | 143 | 2 | 38.2 | 131.0 | 319.4 | 1 336.2 | 3 663.8 | 16 867.4 | 7.1→6.9 |
| vec-async | 92.1 | 188.8 | 559.2 | 6 157.8 | 7 983.0 | 36 | 0 | 58.8 | 222.8 | 659.0 | 1 764.3 | 209.7 | 7 923.8 | 6.9→5.8 |
| vec-callback | 51.8 | 143.9 | 242.0 | 1 140.6 | 2 598.2 | 12 | 0 | 41.4 | 151.8 | 575.1 | 651.5 | 79.4 | 2 564.0 | 5.8→7.1 |
| handle-pull | 27.3 | 64.1 | 156.0 | 1 744.0 | 11 487.4 | 11 | 0 | 18.2 | 50.5 | 106.7 | 446.8 | 110.3 | 11 040.6 | 7.1→6.1 |
| **ring-pull** | **9.0** | **27.0** | **116.7** | 1 909.6 | 6 968.3 | 12 | 0 | **1.0** | **1.8** | **12.3** | **119.8** | 114.8 | 6 967.3 | 6.1→5.9 |
| ring-async | 38.8 | 3 603.0 | 9 766.8 | 15 963.5 | 29 346.5 | 679 | 4 | 4.2 | 9.8 | 52.9 | 1 788.4 | 9 760.2 | 29 340.1 | 5.9→**47.1** |
| ring-callback | 13.2 | 40.7 | 831.4 | 10 585.0 | 13 914.4 | 68 | 0 | 3.6 | 13.0 | 34.8 | 224.1 | 826.2 | 13 904.0 | 47.1→12.4 |

The crossing component never exceeded **1.79 ms** in any of the 50 400 frames, and its p99.9 was
≤ 0.66 ms in every design. So every frame over 16.7 ms end to end — 2 in `vec-pull`, and 4 in
`ring-async` while another job pushed the load average to 47 — spent at least 14.9 ms in **wake**,
waiting for its consumer thread to be scheduled. Per-frame data is not kept, only percentiles, so the
split of individual 1–16.7 ms frames is not available. The wake p99 tracks the e2e p99 in every row.

**Same, e2e only, runs 1 and 2 (no split)**

| Design | run 1 p50 / p99 / max | run 1 load | run 2 p50 / p99 / max | run 2 load |
|---|---|---|---|---|
| vec-pull | 55.0 / 5 671.5 / 17 188.5 (1 frame > 16.7 ms) | 4.8→46.9 | 48.6 / 433.4 / 29 104.3 (1 frame > 16.7 ms) | 5.5→20.6 |
| vec-async | 57.6 / 4 189.5 / 17 196.8 (1 frame > 16.7 ms) | 46.9→60.8 | 61.5 / 901.0 / 12 443.3 | 20.6→27.5 |
| vec-callback | 108.5 / 2 409.5 / 11 069.5 | 60.8→19.6 | 48.9 / 283.3 / 5 709.3 | 27.5→10.4 |
| handle-pull | 51.9 / 166.2 / 4 177.0 | 19.6→7.6 | 28.2 / 228.1 / 14 499.7 | 10.4→7.6 |
| ring-pull | 16.5 / 64.9 / 530.9 | 7.6→2.7 | 11.2 / 382.0 / 12 197.8 | 7.6→8.7 |
| ring-async | 40.6 / 104.6 / 1 350.0 | 2.7→1.8 | 27.5 / 1 214.4 / 14 032.1 | 8.7→7.2 |
| ring-callback | 21.3 / 65.0 / 4 848.9 | 1.8→2.7 | 12.8 / 3 178.5 / 18 788.1 (2 frames > 16.7 ms) | 7.2→6.6 |

**Copies per frame** (after the one reassembly copy every design shares; proven by the address check:
Vec designs 0 / 7 200 zero-copy frames, handle and ring designs 7 200 / 7 200):

| Design | Payload copies at the FFI | Heap allocations per frame (FFI-related) | Per-frame object conversion |
|---|---|---|---|
| vec-pull / vec-async / vec-callback | **3** + 1 zero-fill (byte-wise Rust serialise → `[UInt8]` → `Data`) | 3 (RustBuffer, `[UInt8]`, `Data`) + UniFFI future for async | yes (record → struct, bytes → `Data`) |
| handle-pull | **0** | 2 small (RustBuffer for the record, Swift `FrameHandle` object) | yes (small record + object) |
| ring-pull / ring-callback | **0** | **0** | **no**: scalars only, descriptor read in place |
| ring-async | **0** | UniFFI future per wait (`Arc` + continuation map entry) | no |

**CPU and memory, run 3** (whole process, both languages, producer included):

| Design | CPU (% of one core) | Producer µs / frame | Memory after 2 s warm-up → end (max), MB |
|---|---|---|---|
| vec-pull | 0.41 | 7.3 | 8.57 → 7.47 (9.39) |
| vec-async | 0.73 | 18.7 | 7.85 → 7.62 (9.70) |
| vec-callback | 0.49 | 8.9 | 7.95 → 9.59 (10.11) |
| handle-pull | 0.28 | 7.9 | 9.80 → 7.93 (9.80) |
| ring-pull | **0.13** | 5.5 | 16.43 → 16.40 (16.43); includes the 8 MiB ring |
| ring-async | 0.32 | 20.4 | 16.48 → 16.45 (16.48) |
| ring-callback | 0.17 | 6.3 | 16.53 → 16.55 (16.55) |

Memory moved by −1.9 to +1.6 MB over 2 min with no upward trend in any design. The Vec designs
fluctuate with allocator reuse; the ring designs stay within ±33 KB. (Runs 1 and 2: −1.0 to +0.6 MB.)

### Thread ownership

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

## Verdict

Verdicts use the template's vocabulary, one per row. Kotlin-side criteria are marked as instructed.
Timing figures in the evidence column are **provisional** (see [Raw numbers](#raw-numbers)).

| # | Criterion (as written in the plan) | Verdict | Evidence |
|---|---|---|---|
| 1 | "a Rust → Swift callback that signs with a Secure Enclave key" | **pass** | [Signing](#signing): 51 handshakes, DER and raw, verified by `p256`; tampered message rejected; `verify_p256` negative cases `false`. SE sign round trip p50 4.5 ms |
| 2 | "… (Touch ID policy)" | **blocked — needs a person at the Mac** | Unattended part done: a `.userPresence` SE key refuses to sign without interaction (`LAError -1004`), so the policy is hardware-enforced. The approved path (`s10-harness touchid`: touch the sensor, plus the leave-it-alone timeout run) has not been run |
| 3 | "a Rust → Kotlin callback that signs with a Keystore key" (Android instrumented test) | **blocked — needs Android toolchain (scheduled)** | No JDK, Gradle or Kotlin compiler on this Mac (SDK/NDK present in `~/Library/Android/sdk`); phone disconnected |
| 4 | "async cancellation" | **pass** | [Cancellation](#cancellation) C1–C4. Rust → Swift works natively. Swift → Rust works only through the `CancelToken` pattern, because UniFFI 0.32.2's Swift bindings ignore task cancellation (F1). With the token: cancel → work future dropped in p50 18 µs |
| 5 | "30-min 1080p60-sized byte stream through the FFI"; §0.C "30 min stable at 1080p60" | **not run — scheduled on a quiet Mac after P0-15** | Required; not waived. Only 2-min runs so far (3 runs × 7 designs, 7 200 frames each), as instructed for this pass. Within those: 0 drops, 0 gaps, 0 integrity failures, no memory growth, no leaked handles. Command: `s10-harness media --design ring-pull --seconds 1800` ([README](../../spikes/s10-uniffi/README.md#required-30-minute-soak-scheduled)) |
| 6 | "… with zero-copy buffers"; §0.C "without per-frame object conversion" | **pass** | For the ring designs, the chosen media path. Address check: Swift read Rust's own buffer for 7 200 / 7 200 frames (ring and handle designs) vs 0 / 7 200 (Vec designs). Ring designs also have no per-frame object conversion or allocation. The handle design is zero-copy but converts a small record per frame; the Vec designs fail this criterion and are not chosen |
| 7a | "added latency < 1 frame": the FFI crossing (Rust hand-over → bytes readable in Swift) | **pass** | Run 3 (`4f5ae1f`): crossing max **1.788 ms** (ring-async), the highest over all 50 400 frames; ring-pull crossing p99 1.8 µs, max 0.12 ms. Provisional timing (loaded Mac) |
| 7b | "added latency < 1 frame": end to end (producer publish → bytes readable in Swift, the definition in [Method](#method)) | **blocked — needs a quiet Mac** | On the loaded Mac (load 2–60 on 12 cores), 4 of 7 designs had frames over 16.7 ms in at least one run: vec-pull (runs 1–3), vec-async (run 1), ring-callback (run 2), ring-async (run 3, worst **29.3 ms**). Each such frame in run 3 spent ≥ 14.9 ms waiting to be scheduled. p99 ≤ 9.8 ms in every design and run; the chosen ring-pull had 0 frames over 16.7 ms in all three runs (max 12.2 ms). Re-run scheduled with the soak (row 5) |
| 8 | "thread ownership documented" | **pass** | [Thread ownership](#thread-ownership): ownership table, measured call sites, rules T1–T7, two deadlock hazards reproduced |

**Is the added latency ≪ 1 ms?** This was asked in the task brief; it is not a plan criterion, so it
has no verdict row. Provisionally: the **FFI crossing, yes** (ring-pull p99 1.8 µs and max 120 µs;
the Vec designs p99 131–223 µs). **End to end on this loaded Mac, at p50 yes (9–92 µs); at p99 not
for every design** (0.12–9.8 ms), because of scheduling rather than the FFI. The quiet re-run
decides.

**Coverage:** not covered:
- Android / Kotlin on any device or emulator;
- the required 30-minute soak (scheduled on a quiet Mac after P0-15);
- a quiet Mac: load was 2–60 throughout, so every timing number is provisional (re-run scheduled);
- macOS versions other than 27.0.1, Intel Macs, Swift other than 6.4;
- the Touch ID sheet with a person present.

## Consequences for the plan

Numbers quoted here are the provisional timings from [Raw numbers](#raw-numbers).

- **§0.C fallback ("move media framing out of the core"): the evidence so far does not trigger it.**
  The final call waits for the quiet re-run (rows 5 and 7b). The FFI crossing is not a latency or
  throughput constraint at 1080p60. The rule is to never carry video payloads as UniFFI
  `Vec<u8>` / `Data`. Payloads cross as a Rust-owned shared-memory ring: Swift reads slot descriptors
  and payload in place, and only `u64` scalars cross the FFI. Even the naive Vec path would have met
  the < 1 frame criterion at this bitrate: ≈ 0.4 ns/byte, about 100 µs per 250 KB keyframe and 0.4–0.7 %
  of a core. It is still rejected, for its 3 copies, 3 allocations and the size-proportional CPU.
- **Architecture §5 (for P0-18 to apply; this task doesn't own the file):** split the core's
  platform API into a *control plane* and a *media plane*.
  - The control plane is UniFFI: records, async functions, foreign traits.
  - The media plane is a small unsafe zero-copy API (`ring_layout` / `ring_wait` / `ring_release`)
    behind a hand-written Swift `MediaPlane` type. That type retains the stream and exposes each slot
    as a `CMBlockBuffer` with a custom block source whose free callback releases the slot.
  - The production ring needs out-of-order release (decoders hold buffers), several streams per
    session, a drop-to-next-keyframe overflow policy, and a safety review plus Miri/fuzz tests of the
    unsafe code.
  - Media consumers run on a dedicated thread at user-interactive QoS, not on Swift's cooperative
    pool. The pool adds UniFFI's waker → continuation → re-poll hop (run 3 wake p50: `ring-async`
    34 µs vs `ring-pull` 8 µs) and is shared with all other Swift async work. `ring-async`'s much
    worse run-3 tail (p99 9.8 ms) coincided with the load spike, so this data does not attribute it to
    the pool. The Rust-side delivery thread (`s10-deliver`) ran at default QoS; the production core
    should raise media threads to user-interactive. That is untested here.
- **ADR-0003:** its consequence "spike S10 proves callbacks, cancellation, threading and 60 fps media
  throughput through UniFFI" is confirmed for the **Swift half**. The FFI cost does not
  differentiate the transport options, so S4 can decide on transport merits alone. Pending, from the
  Kotlin half:
  - Kotlin coroutine cancellation semantics in UniFFI's Kotlin bindings;
  - a Keystore/StrongBox `Signer`;
  - how the media plane reaches `MediaCodec`. A direct `ByteBuffer` over the ring needs a small
    hand-written JNI shim (UniFFI has no such type), or else one copy into the codec's input buffer.
- **ADR-0005:** the hardware-key-via-callback shape works. An async foreign `Signer` trait called from
  the core, plus `LAContext.invalidate()` on cancellation, gives hardware-enforced "ask before
  control". Handshake timeouts must allow for human interaction: tens of seconds, not the 4.5 ms an
  unprotected SE signature takes.
- **Implementation plan / estimates (Phase 1 core work, for P0-18):**
  - Add ≈ 2–4 days for a Swift facade over the generated bindings. It wraps every long-running async
    export in a `CancelToken` + `withTaskCancellationHandler` and keeps the generated module in
    Swift 5 mode (F2).
  - Add ≈ 3–5 days for the production media-plane ring with its safety review.
  - The CI job that publishes prebuilt bindings (ADR-0003) must build the bindings module in Swift 5
    mode and pin UniFFI 0.32.x.
- **Threading rules T1–T7** become contributor documentation for `core/`.
- **Follow-ups:**
  - Manual Touch ID run (`s10-harness touchid`): **maintainer**.
  - Kotlin/Keystore half of P0-12: **P0-12, once a JDK + Gradle are installed** (emulator acceptable).
  - **Required** 30-min soak of `ring-pull`, plus a quiet re-run of the 2-min set, `stress` and
    `bench`, to replace the provisional timings and settle row 7b: **P0-12, scheduled on a quiet Mac
    after P0-15** (exact commands in the [README](../../spikes/s10-uniffi/README.md#required-30-minute-soak-scheduled)).
  - Report F1 (Swift cancellation) and F2 (Swift 6 strict concurrency) upstream to UniFFI:
    **maintainer**, since this task does not open external issues.
  - Feed VideoToolbox from ring memory via `CMBlockBuffer`: **P0-15 (S2)**, for reference only.
