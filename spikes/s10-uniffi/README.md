# Spike S10 — UniFFI integration (Rust ↔ Swift half)

> **Throwaway spike code** (task P0-12). Never promoted to production directly.
> Results, numbers and verdicts: [`docs/spikes/s10-uniffi.md`](../../docs/spikes/s10-uniffi.md).
> The Kotlin / Android Keystore half is deferred until the Android toolchain is ready.

The question: can `tombolo-core` (Rust) call back into the platform for hardware-key signing, handle
async cancellation and thread ownership cleanly, and carry 60 fps media payloads across the FFI
without per-frame copies and with < 1 frame of added latency?

## Layout

| Path | What |
|---|---|
| `core/` | Rust crate `s10-core` (UniFFI 0.32.2, proc-macro style; `staticlib` + `cdylib`) and the `uniffi-bindgen` binary |
| `core/src/handshake.rs` | foreign async trait `Signer`, fake session handshake, `p256` verification |
| `core/src/cancel.rs` | `CancelToken`, `AbortOnDrop`, naive vs cancellable async exports |
| `core/src/media.rs` | seven frame-delivery designs over one simulated producer, shared-memory ring |
| `core/src/threads.rs` | thread probes, re-entrancy, lock/main-thread deadlock demos, call-overhead benches |
| `swift-harness/` | SwiftPM CLI `s10-harness` (Swift 6 language mode) — Secure Enclave signer, consumers, measurements |
| `build.sh` | builds everything; the only build entry point |
| `results/` | raw output (`.txt`) and machine-readable results (`.json`) of the runs quoted in the result doc |

Generated files are **not** committed: `swift-harness/Sources/S10Core/` (Swift bindings),
`swift-harness/Sources/S10CoreFFI/` (C header + modulemap), `swift-harness/rust-lib/` (the static
library) and `swift-harness/.generated/` are produced by `build.sh`.

## Requirements

- Apple silicon Mac with a Secure Enclave (tested: M4 Pro, macOS 27.0.1).
- Rust ≥ 1.85 (edition 2024; tested 1.98). Crates are downloaded by cargo on first build.
- Swift 6.x from the **Command Line Tools** (tested 6.4). No Xcode, no `xcodebuild`, no XCFramework:
  SwiftPM links `rust-lib/libs10_core.a` through a system-library module (`link "s10_core"` in the
  generated modulemap) plus `-L rust-lib`.

## Build

```sh
cd spikes/s10-uniffi
./build.sh
```

`build.sh` runs, in order: `cargo build --release` (lib + `uniffi-bindgen` bin) →
`uniffi-bindgen generate --library target/release/libs10_core.dylib --language swift` (library mode,
run from `core/` so it picks up `core/uniffi.toml`) → copies the bindings, header, modulemap and the
static library into `swift-harness/` → `swift build -c release`. The binary is
`swift-harness/.build/release/s10-harness` (≈ 2.6 MB, Rust core statically linked —
`otool -L` shows no Rust dylib).

The generated `S10Core` module is compiled in **Swift 5 language mode** (see `Package.swift`): UniFFI
0.32.2's generated Swift does not pass Swift 6 strict-concurrency checking when the interface has
async foreign traits. The harness itself is Swift 6 mode.

Linker warnings `search path '/Library/Developer/CommandLineTools/Developer/...' not found` are a
Command-Line-Tools-only artefact and harmless.

## Run

All commands are unattended except `touchid`. Each prints a human summary; `--json PATH` also
writes machine-readable results. Exit status 0 = every check in that command passed.

```sh
H=swift-harness/.build/release/s10-harness

$H sign          --json results/sign.json           # SE signer called from Rust, verified with p256 (+ tamper test)
$H touchid-check --json results/touchid-check.json  # .userPresence SE key + LAContext(interactionNotAllowed) must refuse
$H cancel        --json results/cancel.json         # cancellation: Swift->Rust (naive vs token) and Rust->Swift
$H threads       --json results/threads.json        # thread map, re-entrancy, lock + main-thread deadlock hazards
$H bench         --json results/bench.json          # FFI call overhead (sync, async, callbacks)
$H stress        --json results/stress.json         # prefilled drain: ns/frame by payload size, all 7 designs (~10 s)
$H media --seconds 120 --json results/media-2min-run3.json   # paced 1080p60, 2 min per design (~14 min total)
$H media --design ring-pull --seconds 30            # one design; names: vec-pull, vec-async, vec-callback,
                                                    #   handle-pull, ring-pull, ring-async, ring-callback
```

The media stream is synthetic 1080p60-encoded-video-sized: P-frames uniformly 25–40 KB, a 250 KB
keyframe every 120 frames (2 s). For every frame the harness reports end-to-end added latency and
its split into *wake* (produced → Rust hands the frame over: thread scheduling, async hops) and
*crossing* (hand-over → bytes readable in Swift: the FFI itself). Run media/stress measurements only
when the Mac is otherwise quiet; the harness records the load average at the start and end of each
design.

## Results in `results/`

| File | Run |
|---|---|
| `media-2min-run3.{txt,json,load.txt,env.txt}` | headline 2-min paced run with the wake/crossing split (build of `4f5ae1f`) |
| `media-2min-run2.*`, `media-2min-run1-loaded.*` | earlier 2-min runs without the split; both overlapped heavy load from other jobs |
| `stress.{txt,json}`, `bench.{txt,json}` | prefilled drain by payload size; FFI call overhead |
| `sign`, `touchid-check`, `cancel`, `threads` (`.txt`, `.json`) | functional checks (each `.txt` ends with the exit status) |

### Manual: Touch ID (needs a person at the Mac)

```sh
$H touchid --timeout-ms 30000
```

Creates a non-persistent Secure Enclave key with `[.privateKeyUsage, .userPresence]`, then runs the
handshake. A Touch ID sheet ("sign the Tombolo S10 spike handshake") appears; touch the sensor (or
use the password fallback). Expected: `verified=true` and `TOUCHID: PASS`. Leaving the sheet alone
for 30 s exercises cancellation instead: Rust's sign timeout drops the foreign future, UniFFI cancels
the Swift task and the signer's cancellation handler calls `LAContext.invalidate()`. Expected
`TimedOut` and the sheet closes by itself. Record both outcomes in the result doc.
