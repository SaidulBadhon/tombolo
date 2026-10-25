# Phase 0 — task-level execution plan

> Status: **ready for approval — not started.** Parent plan: [implementation plan, Phase 0](../implementation-plan.md#phase-0--foundations-spikes--security-design-1217-ew).
> Budget: the task estimates below sum to 58–85 days ≈ **12–17 engineer-weeks** (≈ 6–9 calendar weeks with two
> developers). The parent plan was updated to match.
> Output: measured spike results, a reviewed security design, a re-estimate of Phases 1–4, and a go/no-go for
> Phase 1a. **Spike code is throwaway** — it lives in `spikes/` and is never promoted to production directly.

## Conventions

- **One task = one branch + one git worktree** (`p0/<task-id>-<slug>`), merged to `main` by PR. Tasks in the same
  wave never write the same paths (see "Owns").
- Every spike writes **one result document** `docs/spikes/sNN-<slug>.md` using the template in P0-01:
  question · setup (devices, OS versions, builds) · method · raw numbers · verdict (pass/fail against the
  criteria in the parent plan) · consequences for the plan.
- Identifiers used throughout: Android package `io.github.saidulbadhon.tombolo`, macOS bundle ID
  `io.github.saidulbadhon.Tombolo`, DNS-SD service `_tombolo._udp`.
- **Device-bound tasks** can be driven by an agent over `adb` from the Mac, but physical steps (unlocking,
  pressing power, picking the phone up, travelling between networks) need a person. These tasks list them.
- Tests: spikes are experiments; their "tests" are the measurements in the result document. The exit gate
  (P0-18) reviews every result once, at the end.

## Prerequisites (maintainer actions)

| ID | Action | Needed by |
|---|---|---|
| M1 | Approve starting Phase 0 | everything |
| M2 | Device lab: at least a Pixel on Android 16/17 and a Samsung mid-range; ideally also a Xiaomi/Redmi, an Android 10–12 phone, a dual-SIM phone; a phone that records 240 fps slow-motion video (for S1) | device-bound tasks |
| M3 | Create a free Android Developer Console account (limited distribution) and reserve `io.github.saidulbadhon.tombolo` | P0-02 |
| M4 | Find an external reviewer for the pairing/session design (OSS security community, or funded) | P0-03 review step |

## Task list

| ID | Task | Owns (writes only these paths) | Depends on | Wave | Est. |
|---|---|---|---|---|---|
| P0-01 | Repo skeleton, docs CI, spike template | `apple/README.md`, `android/README.md`, `core/README.md`, `proto/README.md`, `tools/README.md`, `tools/check-links/**`, `spikes/README.md`, `docs/spikes/TEMPLATE.md`, `.github/workflows/**`, `.editorconfig` | — | A | 1–2 d |
| P0-02 | Governance files | `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `.github/ISSUE_TEMPLATE/**`, `.github/pull_request_template.md` | M3 (for the package note only) | A | 1 d |
| P0-03 | Security design: pairing & session state machine + test vectors | `docs/security/**`, `tools/pairing-vectors/**`, `proto/testdata/pairing/**` | — | A | 6–9 d + review wait |
| P0-04 | **S1** optical latency harness | `tools/latency-harness/**`, `docs/spikes/s01-latency-harness.md` | — | A | 4–6 d |
| P0-05 | **S3 + S14** concurrent virtual displays, app compatibility | `spikes/s03-virtual-displays/**`, `docs/spikes/s03-virtual-displays.md`, `docs/spikes/s14-app-compatibility.md` | — | A | 4–6 d |
| P0-06 | **S6** Standard-mode control (Accessibility gestures + input method) | `spikes/s06-a11y-input/**`, `docs/spikes/s06-standard-control.md` | — | A | 4–5 d |
| P0-07 | **S7** fail-closed lifecycle (phone-side lease + cleanup process) | `spikes/s07-lifecycle/**`, `docs/spikes/s07-fail-closed.md` | — | A | 4–6 d |
| P0-08 | **S11** background survival + BLE/CDM wake candidate | `spikes/s11-background/**`, `docs/spikes/s11-background-survival.md` | — | A | 5–7 d (long-running) |
| P0-09 | **S16** call-control API path | `spikes/s16-calls/**`, `docs/spikes/s16-call-control.md` | — | A | 2–3 d |
| P0-10 | **S8 (Mac) + S15** Local Network permission, grant persistence across self-signed updates | `spikes/s08-macos-permissions/**`, `docs/spikes/s08-macos-local-network.md`, `docs/spikes/s15-update-persistence.md` | — | A | 2–3 d |
| P0-11 | **S8 (Android)** Android 17 `ACCESS_LOCAL_NETWORK` incl. adb-forwarded sockets | `spikes/s08-android-local-network/**`, `docs/spikes/s08-android-local-network.md` | — | A | 1–2 d |
| P0-12 | **S10** UniFFI integration (hardware-key callbacks, threading, 60 fps throughput) | `spikes/s10-uniffi/**`, `docs/spikes/s10-uniffi.md` | — | A | 4–6 d |
| P0-13 | **S13** app-shim viewer (IOSurface/XPC) | `spikes/s13-app-shim/**`, `docs/spikes/s13-app-shim.md` | — | A | 3–4 d |
| P0-14 | **S4 + S5** transport per path; iroh API surface; public infrastructure disabled | `spikes/s04-transport/**`, `docs/spikes/s04-transport.md`, `docs/spikes/s05-iroh-api.md` | — | A | 5–7 d |
| P0-15 | **S2** Mac video pipeline (pinned scrcpy-server → VideoToolbox → Metal) | `spikes/s02-mac-video/**`, `docs/spikes/s02-mac-video.md` | P0-04 | B | 4–6 d |
| P0-16 | **S9** keyboard modes (Android-keyboard vs Mac text-commit) | `spikes/s09-keyboard/**`, `docs/spikes/s09-keyboard-modes.md` | P0-15 (reads its code, doesn't modify it) | B | 3–4 d |
| P0-17 | **S12** helper ↔ app relay with bidirectional auth | `spikes/s12-helper-relay/**`, `docs/spikes/s12-helper-relay.md` | P0-07 (reuses the lease design) | B | 3–5 d |
| P0-18 | **Exit gate**: results index, re-estimate, ADR-0003 decision, go/no-go | `docs/spikes/README.md`, `docs/implementation-plan.md`, `docs/decisions/0003-transport.md`, `docs/roadmap.md` | all above | C | 2–3 d |

**Concurrency:** Wave A (14 tasks) can all run in parallel — no shared paths. Wave B starts as each dependency
lands. Wave C runs once, at the end. Balanced two-developer split (≈ 26–38 vs 29–43 days):
**Dev A (Mac + Rust):** P0-01, P0-04, P0-10, P0-12, P0-13, P0-14, P0-15, P0-16 ·
**Dev B (Android + security):** P0-03, P0-05, P0-06, P0-07, P0-08, P0-09, P0-11, P0-17 · **Shared:** P0-02, P0-18.

## Acceptance criteria per task

**P0-01 — skeleton & CI.** Directories exist with a README stating purpose and future owner; `spikes/README.md`
says spike code is throwaway; CI runs the docs link checker on every PR and fails on a broken link or anchor;
`docs/spikes/TEMPLATE.md` exists.

**P0-02 — governance.** CONTRIBUTING (GPL-3.0-or-later inbound = outbound, no CLA, spike vs production code,
how to run the link check), Contributor Covenant code of conduct, SECURITY.md (private reporting via GitHub
security advisories), bug/feature/device-report issue templates, PR template with the definition of done.

**P0-03 — security design.** `docs/security/pairing-and-session.md` specifies: canonical transcript encoding;
roles and nonce ownership; QR and PAKE flows; persisted binding *(peer transport key ↔ identity key ↔ scopes)*;
atomic secret consumption and attempt limits across connections; concurrent pairing attempts; session
establishment and exporter-bound signatures; phone-authoritative scope checks; lease semantics (from S7);
key rotation; device loss and recovery; revocation propagation; downgrade handling. A reference script in
`tools/pairing-vectors/` regenerates the test vectors in `proto/testdata/pairing/`. Review request sent (M4);
findings tracked as issues. **Phase 2 may not implement pairing until the review is closed.**

**P0-04 — S1.** Method: the phone renders a millisecond counter/pattern; a 240 fps camera films the phone and
the Mac mirror side by side; a script extracts the difference per frame. Delivers p50/p95/p99 with stated
uncertainty (± one camera frame ≈ 4.2 ms) from ≥ 300 samples, reproducible by a second person following the
README.

**P0-05 — S3 + S14.** Using the scrcpy CLI as harness: 1 × 1080p60 + 2 × 720p30 virtual displays for 10 min on
the Pixel and Samsung, with fps, dropped frames and device temperature logged; max stable concurrent displays
per device. Top-50 app compatibility table (opens, stays on its display, focus/typing works, dialogs, refuses)
plus proposed fallback rules.

**P0-06 — S6.** Prototype AccessibilityService: tap, long-press, drag, scroll, two-finger pinch; text via the
accessibility input method (Android 13+) and the IME fallback. Pass/fail for typing a sentence and scrolling a
list in 3 popular apps; gesture latency measured; behaviour with Android 17 Advanced Protection on.

**P0-07 — S7.** Patched scrcpy-server (spike-only fork) with a lease the controller renews every ~250 ms and an
independent cleanup process. For each event — link loss, controller kill, Mac sleep, Mac lock, local power
button, local touch, keyguard, helper kill, revocation — input injection and capture stop and display power is
restored within 1 s **with no message from the controller**, on Android 14–17. Physical steps listed in the
result doc.

**P0-08 — S11.** Minimal foreground service (`connectedDevice`) + CDM association + NSD advertisement; a Mac
BLE beacon via CoreBluetooth as the wake candidate. Documented per OEM: survives 24 h idle, Doze, reboot,
network change, force-stop, revoked permissions? Time to reconnect. Recommended mechanism and the "degraded"
UX where it fails.

**P0-09 — S16.** On Pixel + Samsung, Android 14–17: does `acceptRingingCall()`/`endCall()` (deprecated) still
work with `ANSWER_PHONE_CALLS`; can a companion `InCallService` bind for a non-wearable companion; cellular vs
self-managed calls; dual-SIM caller info. Verdict: which path 0.2 uses.

**P0-10 — S8 Mac + S15.** A self-signed menu-bar test app that listens/browses on the LAN: when the Local
Network prompt appears, failure modes when denied, behaviour of incoming-only connections. Then ship version
1.0.1 signed with the same self-signed identity and check whether Local Network, Accessibility and login-item
grants persist.

**P0-11 — S8 Android.** Test app targeting API 37: NSD advertise/discover, LAN TCP/UDP, and a socket reached
through `adb forward` — with `ACCESS_LOCAL_NETWORK` granted, denied, and via the `NsdManager` system picker.

**P0-12 — S10.** Rust crate exposed via UniFFI to a Swift CLI and an Android instrumented test: a Rust → Swift
callback that signs with a Secure Enclave key (Touch ID policy) and a Rust → Kotlin callback that signs with a
Keystore key; async cancellation; 30-min 1080p60-sized byte stream through the FFI with zero-copy buffers;
added latency < 1 frame; thread ownership documented.

**P0-13 — S13.** A generated `.app` shim with its own bundle ID and icon that owns an `NSWindow` and displays
frames sent by a host app over XPC (IOSurface); survives host restart and a host update; TCC prompts recorded;
Dock / ⌘-Tab / Spotlight behaviour verified on macOS 14 and 27.

**P0-14 — S4 + S5.** iroh/noq endpoint with default relays and DNS discovery **disabled**, verified with
outbound Internet blocked; TLS exporter and custom-transport hooks confirmed (or patched). Benchmarks with a
synthetic 1080p60 stream + audio datagrams + a concurrent 1 GB file transfer: Wi-Fi QUIC vs TLS/TCP-per-channel;
USB QUIC-over-one-adb-TCP vs framed TCP channels over adb. p50/p95 frame latency, throughput, CPU. Recommended
transport per path.

**P0-15 — S2.** Swift prototype: push and launch a pinned scrcpy-server via `adb`, decode with VideoToolbox,
present with Metal on `CAMetalDisplayLink`, plus an `AVSampleBufferDisplayLayer` variant. Measured with the S1
harness: p50 ≤ 60 ms / p95 ≤ 90 ms on USB at 1080p60 H.264; CPU and energy impact recorded.

**P0-16 — S9.** On top of P0-15's prototype (imported, not modified): Android-keyboard mode (UHID) and Mac
text-commit mode. Matrix: English, a CJK input method, an RTL language × 3 apps; shortcuts; verdict on what 0.1
ships.

**P0-17 — S12.** Prototype helper (shell, via `app_process`) ↔ app over an abstract local socket: helper checks
the app's UID via peer credentials; app checks a per-launch secret; bounded queues; 1080p60 relay adds ≤ 3 ms
p95; impostor tests in both directions fail.

**P0-18 — exit gate.** `docs/spikes/README.md` indexes every result with pass/fail. The implementation plan's
estimates and scope are updated from evidence; ADR-0003 moves to *Accepted* with the transport per path; the
roadmap is adjusted if any feature changed feasibility; a written go/no-go for Phase 1a with any conditions.

## Verification before execution

Before fanning these tasks out, re-check this plan against the repository at that time (paths still free,
dependencies unchanged) — per the project's process, a plan that references files that don't exist is worse
than no plan.
