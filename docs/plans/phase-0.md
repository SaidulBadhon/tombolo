# Phase 0 — task-level execution plan

> Status: **in progress** — approved 2026-10-26; revised 2026-11-02 for the approved
> [Standard-first re-plan](standard-first.md) (release 0.1 needs no Developer options). See the execution notes of
> [2026-10-26](#execution-notes-2026-10-26-after-plan-verification) and
> [2026-11-02](#execution-notes-2026-11-02-after-the-re-plan). Parent plan:
> [implementation plan, Phase 0](../implementation-plan.md#phase-0--foundations-spikes--security-design-1217-ew).
> Budget: the Phase 0 task estimates below sum to 58–85 days ≈ **12–17 engineer-weeks**, as in
> [re-plan §5](standard-first.md#5-estimates-provisional-budgeting-ranges-not-commitments). The work moved to
> Phase 3 (P0-05, P0-16, P0-17 and S2's USB phone path, ≈ 11–16 days, counted there) about equals the work added
> (P0-19, P0-20) and re-scoped (P0-06, P0-07, P0-08, P0-11). S18 is not a Phase 0 task.
> Output: measured spike results; the security design (a draft under external review — pairing may be built behind a
> flag, nothing containing it ships until the review closes); a re-estimate of Phases 1–4; and a go/no-go for
> Phase 1 (release 0.1 Mirror). **Spike code is throwaway** — it lives in `spikes/` and is never promoted to
> production directly.

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
| M2 | Device lab: at least a Pixel on Android 16/17 and a Samsung mid-range; ideally also a Xiaomi/Redmi, an Android 10–12 phone, a dual-SIM phone; a phone that records 240 fps slow-motion video (for S1) | device-bound tasks; 0.1 release acceptance (a Pixel on Android 15–17 and a Samsung on One UI 7+, [re-plan §6](standard-first.md#6-release-acceptance-for-01-restored-from-the-current-plan-adapted)) |
| M3 | Create a free Android Developer Console account (limited distribution) and reserve `io.github.saidulbadhon.tombolo` | P0-02 |
| M4 | Find an external reviewer for the pairing/session design (OSS security community, or funded) | P0-03 review step; **shipping 0.1** — nothing containing pairing ships until the review closes ([re-plan §9.1](standard-first.md#9-maintainer-decisions-2026-11-02)) |

## Task list

*Gate* is what a task must be done before: **Phase 1** = the exit gate P0-18, and so the start of Phase 1
(release 0.1 Mirror); **0.2 / 0.3 / 1.0** = before that release, not before the exit gate
([re-plan §3](standard-first.md#3-phase-0-changes)). See [Gates by release](#gates-by-release).

| ID | Task | Owns (writes only these paths) | Depends on | Wave | Gate | Est. |
|---|---|---|---|---|---|---|
| P0-01 | Repo skeleton, docs CI, spike template | `apple/README.md`, `android/README.md`, `core/README.md`, `proto/README.md`, `tools/README.md`, `tools/check-links/**`, `spikes/README.md`, `docs/spikes/TEMPLATE.md`, `.github/workflows/**`, `.editorconfig` | — | A | Phase 1 | 1–2 d |
| P0-02 | Governance files | `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `.github/ISSUE_TEMPLATE/**`, `.github/pull_request_template.md` | M3 (for the package note only) | A | Phase 1 | 1 d |
| P0-03 | Security design: pairing & session state machine + test vectors | `docs/security/**`, `tools/pairing-vectors/**`, `proto/testdata/pairing/**` | — | A | Phase 1 (the draft); the review closing gates **shipping** 0.1 | 6–9 d + review wait |
| P0-04 | **S1** optical latency harness | `tools/latency-harness/**`, `docs/spikes/s01-latency-harness.md` | — (end-to-end validation: P0-19) | A (validation: B3) | Phase 1 | 4–6 d |
| P0-05 | **S3 + S14** concurrent virtual displays, app compatibility — **moved to Phase 3 (Advanced)** | `spikes/s03-virtual-displays/**`, `docs/spikes/s03-virtual-displays.md`, `docs/spikes/s14-app-compatibility.md` | — | — (moved) | 0.3 | 4–6 d, counted in Phase 3 |
| P0-06 | **S6** Standard control: Accessibility gestures + Android 13+ text commit; restricted settings; Advanced Protection | `spikes/s06-a11y-input/**`, `docs/spikes/s06-standard-control.md` | P0-19 (for the control-latency row; the rest can start earlier) | B3 | Phase 1 | 4–6 d |
| P0-07 | **S7** fail-closed in the app (execution-time checks, in-flight cancellation, independently surviving components) | `spikes/s07-lifecycle/**`, `docs/spikes/s07-fail-closed.md` | P0-19, P0-06 (imports both, modifies neither) | B4 | Phase 1 | 5–7 d |
| P0-08 | **S11b** idle/background survival + BLE/CDM wake candidate (split from S11; the active-session half is P0-20) | `spikes/s11b-background/**`, `docs/spikes/s11b-background-survival.md` | — | A | 0.2 | 4–6 d (long-running) |
| P0-09 | **S16** call-control API path | `spikes/s16-calls/**`, `docs/spikes/s16-call-control.md` | — | A | 0.2 | 2–3 d |
| P0-10 | **S8 (Mac) + S15** Local Network permission, grant persistence across self-signed updates | `spikes/s08-macos-permissions/**`, `docs/spikes/s08-macos-local-network.md`, `docs/spikes/s15-update-persistence.md` | — | A | Phase 1 | 2–3 d |
| P0-11 | **S8 (Android)** Android 17 `ACCESS_LOCAL_NETWORK` with Tombolo's bidirectional transport (emulator) | `spikes/s08-android-local-network/**`, `docs/spikes/s08-android-local-network.md` | P0-14 (imports its transport, doesn't modify it) | B1 | Phase 1 | 2–3 d |
| P0-12 | **S10** UniFFI integration (hardware-key callbacks, threading, 60 fps throughput) | `spikes/s10-uniffi/**`, `docs/spikes/s10-uniffi.md` | — | A | Phase 1 | 4–6 d |
| P0-13 | **S13** app-shim viewer (IOSurface/XPC) | `spikes/s13-app-shim/**`, `docs/spikes/s13-app-shim.md` | — | A | 1.0 | 3–4 d |
| P0-14 | **S4 + S5** transport per path; iroh API surface; public infrastructure disabled | `spikes/s04-transport/**`, `docs/spikes/s04-transport.md`, `docs/spikes/s05-iroh-api.md` | — | A | Phase 1 (Wi-Fi rows) | 5–7 d |
| P0-15 | **S2** Mac video pipeline (pinned scrcpy-server → VideoToolbox → Metal / `AVSampleBufferDisplayLayer`); its USB phone-path measurement **moved to Phase 3 (Advanced)** | `spikes/s02-mac-video/**`, `docs/spikes/s02-mac-video.md` | P0-04 | B1 | Phase 1 (Mac half); 0.3 (USB phone path) | 3–5 d (was 4–6; ≈ 1 d moved) |
| P0-16 | **S9** keyboard modes (Android-keyboard vs Mac text-commit) — **moved to Phase 3 (Advanced)** | `spikes/s09-keyboard/**`, `docs/spikes/s09-keyboard-modes.md` | P0-15 (reads its code, doesn't modify it) | — (moved) | 0.3 | 3–4 d, counted in Phase 3 |
| P0-17 | **S12** helper ↔ app relay with bidirectional auth — **moved to Phase 3 (Advanced)** | `spikes/s12-helper-relay/**`, `docs/spikes/s12-helper-relay.md` | P0-07 (reuses the lease design) | — (moved) | 0.3 | 3–5 d, counted in Phase 3 |
| P0-18 | **Exit gate**: results index, re-estimate, ADR-0003 decision, go/no-go for Phase 1 | `docs/spikes/README.md`, `docs/implementation-plan.md`, `docs/decisions/0003-transport.md`, `docs/roadmap.md` | the **Phase 1 gates only**: P0-01–P0-04, P0-06, P0-07, P0-10, P0-11, P0-12, P0-14, P0-15 (Mac half), P0-19, P0-20 | C | — | 2–3 d |
| P0-19 | **S17** Standard capture pipeline (MediaProjection → MediaCodec → Tombolo transport over Wi-Fi → `MirrorCore` → `AVSampleBufferDisplayLayer`) | `spikes/s17-standard-capture/**`, `docs/spikes/s17-standard-capture.md` | P0-14 (transport) and P0-15 (`MirrorCore`), both imported, not modified; P0-04 (harness) | B2 | Phase 1 | 7–10 d |
| P0-20 | **S11a** active-session survival (foreground service while other phone apps are in use) | `spikes/s11a-active-session/**`, `docs/spikes/s11a-active-session.md` | P0-19 (builds on its app, doesn't modify it) | B3 | Phase 1 | 3–4 d |

**Concurrency:** Wave A (10 tasks, no dependencies) can all run in parallel — no shared paths. Wave B starts as
each dependency lands: **B1** (P0-11, P0-15) → **B2** (P0-19) → **B3** (P0-06's latency row, P0-20, P0-04's
end-to-end validation) → **B4** (P0-07). Wave C (P0-18) runs once, after the Phase 1 gates; the 0.2, 0.3 and 1.0
items don't hold it up. The moved tasks have no Phase 0 wave.

**Phone queue (serialised, one task at a time on the device; replaces the 2026-10-26 queue):** P0-19 (S17) →
P0-20 (S11a) → P0-06 (S6) → P0-07 (S7) → P0-14 phone runs (S4/S5, Wi-Fi) → P0-12 Keystore half (S10) → P0-04
end-to-end validation (S1 on S17) → P0-08 (S11b; needs an uninterrupted 24 h slot) → P0-09 (S16). In parallel,
off the phone: P0-11 (S8 Android) on an Android 17 (API 37) emulator. Per
[re-plan §3](standard-first.md#phone-queue-one-task-at-a-time-on-the-device).

**Developer split** (whole-task estimates: ≈ 29–43 vs 26–38 days, plus 3–4 shared = 58–85):
**Dev A (Mac + Rust + the Standard capture pipeline):** P0-01, P0-04, P0-10, P0-12, P0-13, P0-14, P0-15, P0-19 ·
**Dev B (Android + security):** P0-03, P0-06, P0-07, P0-08, P0-09, P0-11, P0-20 · **Shared:** P0-02, P0-18.
The moved tasks (P0-05, P0-16, P0-17) are allocated with Phase 3. Most of Dev A's tasks are done (see
[Status](#status-2026-11-02)), so Dev A starts P0-19 now, while Dev B starts P0-11 on the emulator and the
device-independent code of P0-06, P0-08 and P0-09, whose device runs come later in the queue.

**Calendar:** each developer's load is ≈ 6–9 weeks of work, but the single phone is now on the critical path:
P0-19 → P0-20 → P0-06 → P0-07 alone is up to 19–27 days of largely serial device work. The remaining Phase 0
calendar time is set by the phone queue (and by M2, a second device), not by the split.

## Gates by release

| Gate | Phase 0 items | Notes |
|---|---|---|
| **Phase 1** — exit gate P0-18, then 0.1 Mirror is built | S1 (P0-04, incl. end-to-end validation on S17), S2 Mac half (P0-15), S4/S5 Wi-Fi phone runs (P0-14), S6 (P0-06), S7 (P0-07), S8 Mac + S15 (P0-10), S8 Android (P0-11), S10 incl. Keystore and soak (P0-12), S11a (P0-20), S17 (P0-19); the security design draft (P0-03) | **S7 must pass before any release that injects input; if it fails, control is disabled** (view-only everywhere) |
| **Shipping 0.1** (not the exit gate) | external review of P0-03 closed (M4); optical latency acceptance; the Pixel and Samsung runs | optical and device-lab acceptance: **blocked — needs hardware** (M2) |
| **Before 0.2** | S11b (P0-08), S16 (P0-09) | still Phase 0 tasks, counted in the Phase 0 total |
| **Before 0.3** (Advanced) | S3 + S14 (P0-05), S9 (P0-16), S12 (P0-17), S2's USB phone path (P0-15, verdict row 1) | moved; effort counted in Phase 3. S4's USB (adb-forward) rows are not a 0.1 question either (no USB in 0.1); whether the Advanced phase still needs them is decided there |
| **Before 1.0** | S13's blocked rows (P0-13); **S18** no-debugging USB path — Android Open Accessory vs NCM USB tethering with macOS. Pass: one works without a kernel extension; if not: Wi-Fi / hotspot only | S18 is not a Phase 0 task: it runs between Phase 1 and 1.0 and has no task ID yet |

## Status (2026-11-02)

Merged to `main` on 2026-11-02. Tasks not listed here have not started.

| Task | PR | Status | Result |
|---|---|---|---|
| P0-01, P0-02 | [#1](https://github.com/SaidulBadhon/tombolo/pull/1) | done | [`spikes/README.md`](../../spikes/README.md), [spike template](../spikes/TEMPLATE.md), governance files |
| P0-03 | [#2](https://github.com/SaidulBadhon/tombolo/pull/2) | **draft, awaiting external review** (M4: request posted as [issue #10](https://github.com/SaidulBadhon/tombolo/issues/10), 2026-11-02); complete only once the review closes | [pairing & session design](../security/pairing-and-session.md) |
| P0-04 | [#3](https://github.com/SaidulBadhon/tombolo/pull/3) | **harness ready** (software-timestamp mode); end-to-end validation pending, now on S17 (P0-19); optical acceptance open (no camera) | [S1](../spikes/s01-latency-harness.md) |
| P0-10 | [#4](https://github.com/SaidulBadhon/tombolo/pull/4) | done, with **blocked rows**: denied-state behaviour, Accessibility and launch-at-login persistence | [S8 Mac](../spikes/s08-macos-local-network.md), [S15](../spikes/s15-update-persistence.md) |
| P0-12 | [#5](https://github.com/SaidulBadhon/tombolo/pull/5) | **Swift half** done (timings provisional, loaded Mac); Keystore half, 30-minute soak, quiet re-run and Touch ID run outstanding | [S10](../spikes/s10-uniffi.md) |
| P0-13 | [#6](https://github.com/SaidulBadhon/tombolo/pull/6) | done, with **blocked rows**: visual checks, macOS 14 — not "passed"; gates 1.0 only | [S13](../spikes/s13-app-shim.md) |
| P0-14 | [#7](https://github.com/SaidulBadhon/tombolo/pull/7) | **Mac half** (timings provisional); every criterion blocked — needs phone; the Wi-Fi phone runs are now on the critical path and the transport choice stays provisional until they run | [S4](../spikes/s04-transport.md), [S5](../spikes/s05-iroh-api.md) |
| P0-15 | [#8](https://github.com/SaidulBadhon/tombolo/pull/8) | **Mac half** measured: `AVSampleBufferDisplayLayer` recommended as the default presenter (Metal on `CAMetalDisplayLink` added ~24 ms on the tested macOS 27 setup — not yet a general result); USB phone path moved to Phase 3 | [S2](../spikes/s02-mac-video.md) |

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
findings tracked as issues. **Pairing may be implemented behind a feature flag before the review closes; nothing
that contains it ships until the external review closes** (every finding resolved or explicitly accepted) — rework
risk accepted ([re-plan §9.1](standard-first.md#9-maintainer-decisions-2026-11-02)).

**P0-04 — S1.** Method: the phone renders a millisecond counter/pattern; a 240 fps camera films the phone and
the Mac mirror side by side; a script extracts the difference per frame. Delivers p50/p95/p99 with stated
uncertainty (± one camera frame ≈ 4.2 ms) from ≥ 300 samples, reproducible by a second person following the
README. *2026-11-02:* the end-to-end validation runs on the S17 pipeline (P0-19) instead of P0-15's USB path.
Software-timestamp numbers support development decisions, not optical acceptance, which stays open.

**P0-05 — S3 + S14.** *Moved to Phase 3 (Advanced), before 0.3
([re-plan §3](standard-first.md#moved-to-the-advanced-phase-before-03)); criteria unchanged; not counted in the
Phase 0 total.* Using the scrcpy CLI as harness: 1 × 1080p60 + 2 × 720p30 virtual displays for 10 min on
the Pixel and Samsung, with fps, dropped frames and device temperature logged; max stable concurrent displays
per device. Top-50 app compatibility table (opens, stays on its display, focus/typing works, dialogs, refuses)
plus proposed fallback rules.

**P0-06 — S6.** *Re-scoped 2026-11-02 ([re-plan §3](standard-first.md#re-scoped-spikes-now-01-gates)); a
Phase 1 gate.* Prototype AccessibilityService: tap, drag and scroll as planned gesture strokes, and text via the
accessibility text commit on **Android 13+ only** — Android 10–12 get gestures and no text input, and no
other text path is built for them ([re-plan §9.3](standard-first.md#9-maintainer-decisions-2026-11-02)). Pass/fail
for typing a sentence and scrolling a list in 3 popular apps. **Restricted settings:** the whole *App info →
Allow restricted settings* flow for an APK installed the way users will install it (a browser download or file
manager, not `adb install`); F-Droid's exemption is a hypothesis to test, not an assumption. **Android 17
Advanced Protection** on the API 37 emulator: is the service revoked or blocked, and what the user sees.
Control latency measured on top of S17 (P0-19). Outcome recorded **per device/configuration: *control* or
*view-only*** — view-only is a supported result. Android 10–12 hardware and the device lab: blocked — needs
hardware (emulator runs are API evidence only).

**P0-07 — S7.** *Re-scoped 2026-11-02: in the app, not in a patched scrcpy-server
([re-plan §3](standard-first.md#re-scoped-spikes-now-01-gates)).* The app owns capture (P0-19) and injection
(P0-06), both imported, not modified. Every injected action re-checks **at execution time** — including queued
callbacks — the authenticated session, granted scopes, target display, required elevation and a live lease. For
each event — link loss, Mac crash/sleep/lock, local takeover on the phone (touch, power button, lock), Stop,
revocation, Accessibility or projection revoked, service or process death — **already-dispatched and continued
gestures, queued text and capture are cancelled**, not just future dispatches refused, within **1 s and with no
message from the Mac**; reconnecting requires fresh authorisation. The watchdog is tested against a blocked main
thread; the bounded shutdown is tested with **independently surviving components** (for example the Accessibility
service alive while the capture service or the main process is dead). The 1 s release deadline stays until a
separately approved change: S7 confirms that the security design's lease worst case is under it (the earlier
draft's 1.25 s must be brought under it, agreed with P0-03), or the change is approved explicitly. **If S7 fails,
control is disabled** — view-only everywhere, not shipped as a documented limitation. Required before any release
that injects input. Documented on Android 14–17: the Motorola (Android 16) now, other versions blocked — needs
hardware. Physical steps listed in the result doc.

**P0-08 — S11b.** *Re-scoped 2026-11-02: idle/background survival only, before 0.2; active-session survival
is S11a (P0-20).* Minimal foreground service (`connectedDevice`) + CDM association + NSD advertisement; a Mac
BLE beacon via CoreBluetooth as the wake candidate. Documented per OEM: survives 24 h idle, Doze, reboot,
network change, force-stop, revoked permissions? Time to reconnect. Recommended wake mechanism and the
"degraded" UX ("open the app to reconnect") where it fails. Pixel, Samsung and Xiaomi rows: blocked — needs
hardware.

**P0-09 — S16.** *Before 0.2.* On Pixel + Samsung, Android 14–17: does `acceptRingingCall()`/`endCall()`
(deprecated) still work with `ANSWER_PHONE_CALLS`; can a companion `InCallService` bind for a non-wearable
companion; cellular vs self-managed calls; dual-SIM caller info. Verdict: which path 0.2 uses.

**P0-10 — S8 Mac + S15.** A self-signed menu-bar test app that listens/browses on the LAN: when the Local
Network prompt appears, failure modes when denied, behaviour of incoming-only connections. Then ship version
1.0.1 signed with the same self-signed identity and check whether Local Network, Accessibility and login-item
grants persist.

**P0-11 — S8 Android.** *Re-scoped 2026-11-02.* Test app targeting API 37 on an Android 17 emulator, running
**Tombolo's actual bidirectional transport** (P0-14's, imported, not modified) — the phone connecting to the
Mac and the Mac connecting to the phone — plus NSD advertise/discover, with `ACCESS_LOCAL_NETWORK` granted,
denied, with an existing nearby-devices grant, and via the `NsdManager` system picker. The result says what
denial breaks, so that onboarding is designed around it; no onboarding decision is made before it. The emulator
sits behind its own NAT, so Mac → phone connections need the emulator's port redirection; the result records how
it was set up. The `adb forward` case from the original criteria is no longer a 0.1 question (0.1 has no adb
path) and moves with the Advanced phase. Emulator evidence is valid for API semantics, not OEM behaviour.

**P0-12 — S10.** Rust crate exposed via UniFFI to a Swift CLI and an Android instrumented test: a Rust → Swift
callback that signs with a Secure Enclave key (Touch ID policy) and a Rust → Kotlin callback that signs with a
Keystore key; async cancellation; 30-min 1080p60-sized byte stream through the FFI with zero-copy buffers;
added latency < 1 frame; thread ownership documented. *2026-11-02:* the Swift half is done
([S10](../spikes/s10-uniffi.md)). Now a Phase 1 gate, outstanding: the Rust → Kotlin Keystore signing callback
and Kotlin-side cancellation, on the Motorola (an emulator run is fine while developing but is not hardware-key
evidence); the required **30-minute soak** and the quiet-Mac re-run of the end-to-end latency row; the manual
Touch ID run.

**P0-13 — S13.** A generated `.app` shim with its own bundle ID and icon that owns an `NSWindow` and displays
frames sent by a host app over XPC (IOSurface); survives host restart and a host update; TCC prompts recorded;
Dock / ⌘-Tab / Spotlight behaviour verified on macOS 14 and 27.

**P0-14 — S4 + S5.** iroh/noq endpoint with default relays and DNS discovery **disabled**, verified with
outbound Internet blocked; TLS exporter and custom-transport hooks confirmed (or patched). Benchmarks with a
synthetic 1080p60 stream + audio datagrams + a concurrent 1 GB file transfer: Wi-Fi QUIC vs TLS/TCP-per-channel;
USB QUIC-over-one-adb-TCP vs framed TCP channels over adb. p50/p95 frame latency, throughput, CPU. Recommended
transport per path. *2026-11-02:* the Wi-Fi phone runs are a Phase 1 gate and on the critical path; the USB
(adb) rows are not a 0.1 question (no USB in 0.1) and are decided with the Advanced phase.

**P0-15 — S2.** Swift prototype: push and launch a pinned scrcpy-server via `adb`, decode with VideoToolbox,
present with Metal on `CAMetalDisplayLink`, plus an `AVSampleBufferDisplayLayer` variant. Measured with the S1
harness: p50 ≤ 60 ms / p95 ≤ 90 ms on USB at 1080p60 H.264; CPU and energy impact recorded. *2026-11-02:* the
Mac half is done. The USB phone-path measurement — verdict row 1 in [S2](../spikes/s02-mac-video.md#verdict),
with the phone-path parts of rows 3 and 5, which come from the same run — is **moved to Phase 3 (Advanced)**.
The phone side of the Standard path is measured by S17 (P0-19), which imports this task's `MirrorCore`.

**P0-16 — S9.** *Moved to Phase 3 (Advanced), before 0.3; not counted in the Phase 0 total. Criteria
unchanged, except that the verdict is now for the Advanced phase: 0.1's text path is S6's Android 13+ text
commit.* On top of P0-15's prototype (imported, not modified): Android-keyboard mode (UHID) and Mac
text-commit mode. Matrix: English, a CJK input method, an RTL language × 3 apps; shortcuts; verdict on which
mode the Advanced phase ships.

**P0-17 — S12.** *Moved to Phase 3 (Advanced), before 0.3; criteria unchanged; not counted in the Phase 0
total.* Prototype helper (shell, via `app_process`) ↔ app over an abstract local socket: helper checks
the app's UID via peer credentials; app checks a per-launch secret; bounded queues; 1080p60 relay adds ≤ 3 ms
p95; impostor tests in both directions fail.

**P0-18 — exit gate.** Runs once the Phase 1 gates in the task list are done; S11b, S16, the moved Advanced
spikes and S13's blocked rows don't hold it up. `docs/spikes/README.md` indexes every result with pass/fail and
the release it gates, including the items still open for 0.2, 0.3 and 1.0. The implementation plan's estimates
and scope are updated from evidence; ADR-0003 moves to *Accepted* with the Wi-Fi transport from the phone runs
(the USB path is decided with the Advanced phase); the roadmap is adjusted if any feature changed feasibility;
a written go/no-go for Phase 1 (release 0.1 Mirror) with any conditions — including which configurations are
*control* and which *view-only* (S6, S7), and that shipping 0.1 still waits for the external review (P0-03) and
for optical and device-lab acceptance (blocked — needs hardware).

**P0-19 — S17 Standard capture pipeline.** *New 2026-11-02 ([re-plan §3](standard-first.md#new-spikes)).* A
spike Android app — the project's first Gradle build: foreground service + MediaProjection, whole screen **and**
single-app selection → MediaCodec H.264 low-latency → Tombolo's transport over Wi-Fi (P0-14's, imported, not
modified) → a Mac receiver that uses P0-15's `MirrorCore` (imported, not modified) for VideoToolbox decode and
`AVSampleBufferDisplayLayer` presentation. Pass criteria, on the Motorola (Android 16) over 5 GHz Wi-Fi:
1. p50 ≤ 100 ms, p95 ≤ 180 ms in the S1 software-timestamp mode (optical: pending a camera);
2. 10 min stable at the panel's nearest supported 1080p-class size, 60 fps;
3. every transition handled: session start from the Mac — a direct activity start vs a notification tap,
   recording which one works; consent cancelled; rotation as a resize of the same capture (no new consent);
   lock → stop → fresh consent; encoder capability probing and recovery; adaptive bitrate;
4. phone CPU and thermals recorded;
5. **single-app capture input safety:** coordinate, focus and target changes demonstrably cannot deliver input
   to an app the Mac cannot see — otherwise single-app sessions are **view-only**. Either verdict is acceptable;
   it must be recorded. The test may use a minimal tap injector; the full control path is S6.

If it fails: a lower default resolution/bitrate; targets are relaxed only with published evidence. The
capture/service code is an importable Gradle module, so P0-20, P0-06 and P0-07 build on it by path without
modifying it. The result records the transport build it used; if the S4 phone runs change the Wi-Fi transport
choice, the latency rows are re-run. Physical steps (consent taps, rotation, locking and unlocking, the Wi-Fi
band) are listed in the result doc.

**P0-20 — S11a active-session survival.** *New 2026-11-02 ([re-plan §3](standard-first.md#new-spikes)).* On
P0-19's app (imported, not modified): a foreground service of type `mediaProjection` — plus `connectedDevice` if
needed; the result says whether it is — stays alive for the whole session while other phone apps are in the
foreground, as in 0.1, where Tombolo is in the background while the user opens other apps through the Mac.
Tested against Motorola's battery management at its default settings, permission loss mid-session (projection
stopped from the system UI, notification permission revoked; Accessibility revocation is S7's, once the
injection path exists), network change and process death. Pass: the session survives **30 min of normal use**
on the Motorola, and each failure ends the session **fail-closed with a reason shown on both sides**. If it fails:
document the OEM settings onboarding must cover; shorten sessions. S11a runs before S6 in the phone queue, so a
person drives the foreground apps on the phone; what is tested is Tombolo surviving in the background, not who
drives the foreground app. Other OEMs: blocked — needs hardware.

## Execution notes (2026-10-26, after plan verification)

Phase 0 was approved on 2026-10-26. A read-only verification pass against the repository and this machine
produced these adjustments; they override the table above where they conflict.

**Environment.** Mac: Apple silicon, macOS 27.0.1, Swift 6.4 with Command Line Tools only (no Xcode) — Mac
spikes build with SwiftPM/`swiftc`, assemble `.app` bundles programmatically and compile Metal shaders at
runtime. Rust 1.98. Android toolchain (Temurin/OpenJDK 21, Android command-line tools, SDK, NDK, `adb`)
installed via Homebrew/`sdkmanager`; the maintainer accepted the Android SDK licence.

**Devices.** One phone: **Motorola edge 50 pro, Android 16**. Results are recorded as Motorola/Android 16
evidence only; Pixel, Samsung, Xiaomi, Android 10–12, Android 17 hardware and dual-SIM coverage are marked
**blocked — needs hardware**, never "passed". No second high-speed camera: S1 ships its software-timestamp
mode now; optical acceptance numbers stay **open** until a camera is available.

**Ownership fixes.** `NOTICE` → P0-02. Stable self-signed signing identity (private key outside Git) → P0-10.
P0-01 stages language builds in CI only once there is buildable output. P0-15 exposes an importable Swift
library target inside `spikes/s02-mac-video/` so P0-16 can depend on it without modifying it. P0-03 agrees the
lease contract with P0-07 before finalising; P0-03 counts as complete only once the external review closes.
P0-04 is split into *harness ready* (now) and *validated end-to-end* (after P0-15).

**Phone queue (serialised, one task at a time on the device):** P0-15 → P0-04 validation → P0-05 → P0-16 →
P0-06 → P0-07 → P0-09 → P0-17 → P0-08 (needs an uninterrupted 24 h slot). P0-11 runs on an Android 17
(API 37) **emulator** — valid for API semantics, not OEM behaviour. Performance measurements never run while
other heavy jobs load the Mac.

**Started immediately (no phone, no Android toolchain):** P0-01 + P0-02 (one branch), P0-03, P0-04 (harness),
P0-10, P0-12 (Rust + Swift half), P0-13, P0-14 (Mac-only half).

## Execution notes (2026-11-02, after the re-plan)

The maintainer approved the [Standard-first re-plan](standard-first.md) on 2026-11-02: release 0.1 needs no
Developer options. This plan was revised for it the same day: the task table, gates, waves, phone queue,
developer split and status, and the criteria of P0-03, P0-04 to P0-09, P0-11, P0-12 and P0-14 to P0-20. Where
the 2026-10-26 notes above conflict with the revision, **the revision wins**. In particular, the 2026-10-26
phone queue is replaced by the one under the [task list](#task-list), and P0-04's end-to-end validation now
follows P0-19, not P0-15. The 2026-10-26 notes are kept as written; the rest of them (environment, devices,
ownership fixes, no performance runs on a loaded Mac) still applies.

**Environment, checked on 2026-11-02.** Android work still needs **Gradle and Kotlin**: `which gradle kotlinc`
finds neither. The JDK is Homebrew `openjdk@21` (21.0.13); it is **keg-only and not on `PATH`** —
`/usr/bin/java -version` answers "Unable to locate a Java Runtime" — so builds set `JAVA_HOME` to
`/opt/homebrew/opt/openjdk@21` (or the formula is linked). P0-19 is the first task with a Gradle build, so
installing Gradle (or adding a Gradle wrapper) and Kotlin is its first step. The SDK in `~/Library/Android/sdk`
has an API 37 `google_apis` arm64 system image for the P0-11 and P0-06 emulator runs; whether Advanced
Protection can be turned on in a `google_apis` image (rather than a Play Store image) is unverified, and P0-06
records it.

**Devices.** Unchanged: one phone, the **Motorola edge 50 pro on Android 16**. Every other device, Android 10–12,
Android 17 hardware and the 240 fps camera are still **blocked — needs hardware** (M2). Because 0.1 runs over
Wi-Fi, phone runs also need the phone and the Mac on the same 5 GHz network, and a person for consent taps,
rotation and locking.

**Ownership.** P0-19 exposes an importable Gradle module for its capture/service code, as P0-15 did with
`MirrorCore`; P0-20, P0-06 and P0-07 depend on it by path and never write `spikes/s17-standard-capture/`. P0-07
likewise imports P0-06's Accessibility service. P0-08's paths are renamed from `s11-background` to
`s11b-background` (nothing existed at the old paths). P0-03 and P0-07 still agree the lease contract. Spikes may
keep using `adb` as a development tool to install and drive builds; what they measure must not depend on it,
because 0.1 ships no adb path.

**Moved work.** P0-05, P0-16, P0-17 and S2's USB phone path keep their rows and criteria, marked moved. They run
in Phase 3 (Advanced), before 0.3, and their effort is counted there
([re-plan §5](standard-first.md#5-estimates-provisional-budgeting-ranges-not-commitments)).

## Verification before execution

Before fanning these tasks out, re-check this plan against the repository at that time (paths still free,
dependencies unchanged) — per the project's process, a plan that references files that don't exist is worse
than no plan.
