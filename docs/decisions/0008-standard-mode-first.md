# ADR-0008: Standard mode first

- **Status:** **Accepted** (maintainer decision, 2026-11-02)
- **Date:** 2026-11-02
- **Refines:** [ADR-0001](0001-two-tier-capability-model.md). This ADR fixes the *delivery order* of the two tiers that
  ADR-0001 defines. The tiers, the protocol and the `CaptureProvider` / `InputProvider` split stay as they are.
- **Source:** [Re-plan: Standard mode first ("install two apps")](../plans/standard-first.md), approved 2026-11-02
  (revision 3, after two independent review rounds). Where this summary and the re-plan differ, the re-plan applies.

## Context
ADR-0001 makes Standard mode the default tier and Enhanced mode opt-in. The [implementation
plan](../implementation-plan.md) delivered them in the opposite order
([re-plan §1](../plans/standard-first.md#1-problem)):

- **0.1 Mirror:** the Mac drove a pinned `scrcpy-server` over a bundled `adb`, with no phone app. It needed
  **Developer options**.
- **0.1.x App windows:** virtual displays and per-app windows. It also needed **Developer options**.
- **0.2 Connect:** `tombolo-core`, the Android app, pairing and the continuity features. Mirroring still ran over ADB.
- **0.3 Standard:** mirroring and control without developer options.

So the first two releases needed Developer options and USB or Wireless debugging. The first release a typical
user could adopt was 0.3. Until then, mirroring and control ran under ADB's own authorisation, which Tombolo's
phone-authoritative scopes can't constrain. The plan documented this as an exception, and the second independent
review of the re-plan rated it *High*.

**Maintainer decision (2026-11-01):** the first release is the version where a user installs one app on the
phone and one on the Mac, then uses it. It needs no Developer options and no USB or Wireless debugging.
Developer-mode features come later, as an optional *Advanced* setting.

## Decision
Deliver Standard mode first. Enhanced mode becomes the optional Advanced phase
([re-plan §2](../plans/standard-first.md#2-decision-proposed)):

| Release | Contents | Developer options |
|---|---|---|
| **0.1 Mirror** | The Android app and the Mac app. QR pairing on the local network, then Tombolo's authenticated, encrypted transport over Wi-Fi with the protocol hardening of [protocol §8](../protocol.md#8-robustness-rules). Screen mirroring via MediaProjection, with fresh consent each session. **Control where the device allows it**: Accessibility gestures and text input. View-only is a supported outcome per device or configuration. Playback audio (decision 2 below). Manual clipboard from Mac to phone. Stop and revoke on the phone | no |
| **0.2 Connect** | Notifications with reply, SMS, caller ID and call actions, clipboard both ways (within Android's limits), files, device status, and idle/background reconnection. All of it builds on the session and pairing from 0.1 | no |
| **0.3 Advanced** (optional) | Enhanced mode. A shell-privileged `tombolo-helper` (a scrcpy-server fork) is started through Wireless debugging and **set up from the phone app**. It adds per-app windows (virtual displays), panel-off mirroring of an awake, unlocked phone, no per-session prompt, and a UHID keyboard. The helper's media is relayed through the authenticated Tombolo session | yes, opt-in |
| **1.0** | Hardening, external review of the implementation, fuzzing, distribution polish, app shims (if S13's open checks pass), localisation | no (Advanced optional) |

- "Enhanced mode" stays the technical name of the tier. "Advanced" is the user-facing setting and the name of the
  release.
- **No ADB mirroring path ships in 0.1 or 0.2.** All capture and input go through the phone's per-command scope
  enforcement. There is no bundled `adb`, no `ScrcpyBridge` and no scrcpy protocol coupling before the Advanced
  phase. [ADR-0004](0004-enhanced-helper.md) is amended accordingly.
- Phase 0 changes ([re-plan §3](../plans/standard-first.md#3-phase-0-changes)):
  - **New spikes:** S17 (Standard capture pipeline), S11a (active-session survival) and S18 (USB without debugging,
    before 1.0).
  - **Re-scoped as 0.1 gates:** S6, S7 (fail-closed in the app), S8 Android, S4/S5 phone runs and S10.
  - **Moved to the Advanced phase:** S3, S9, S12, S14 and S2's USB phone path.
  - **Before 0.2:** S11b and S16.
- **If S7 fails, control is disabled** and every device is view-only. The 1 s release deadline stays until a
  separately approved change.
- Protocol and security work moves from Phase 2 into 0.1
  ([re-plan §4](../plans/standard-first.md#protocol-and-security-work-that-moves-from-phase-2-into-01-explicitly)).
  This includes baseline parser fuzzing.

## Alternatives considered
- **Keep the old order** (pinned scrcpy-server over ADB first, Standard mode in 0.3).
  - For: the fastest path to a working mirror, the lowest latency over USB, and scrcpy's device-quirk fixes from
    day one.
  - Rejected because: the first two releases need Developer options, so nothing a typical user can adopt ships
    before 0.3. Mirroring and control run outside Tombolo's scopes until then. And the bundled `adb` and
    `ScrcpyBridge` would be built only to be retired in Phase 3.
- **Standard only, never Enhanced.**
  - For: the simplest product and the smallest attack surface. No ADB authority ever, and one implementation of
    capture and input.
  - Rejected because: it gives up per-app windows, panel-off mirroring, prompt-free sessions and the UHID keyboard.
    These are the features ADR-0001 promises power users. It would also leave every device where S6 finds
    Accessibility control blocked view-only for good, because the re-plan gives those devices control through
    Advanced ([§7](../plans/standard-first.md#7-failure-modes-of-this-plan)). Enhanced mode stays, as an opt-in.

## Consequences
**Costs** ([re-plan §2, "What it costs"](../plans/standard-first.md#what-it-costs)):
- **Per-session consent.** Apps targeting API 34+ need fresh MediaProjection consent for every capture session.
- **No locked-phone mirroring in any mode.** Projection stops on lock (Android 15 QPR1+). Advanced mode allows a
  dark panel only on an *unlocked* phone.
- **Accessibility limits:**
  - Gestures are planned strokes.
  - Text input needs Android 13+ (decision 3 below).
  - Sideloaded apps hit Android 13+ restricted settings.
  - Play policy scrutiny.
  - Android 17 Advanced Protection revokes non-tool accessibility services.

  View-only is a supported per-device outcome.
- **Background-start limits.** Starting a session from the Mac may need a tap on a phone notification (S17).
- **A bigger first release.** 0.1 needs `tombolo-core`, pairing and identity, protocol hardening, the Android app,
  Standard capture and input, the active-session lifecycle and distribution. In return, 0.2 is smaller.
- **The external security review gates the first release,** because pairing ships in 0.1 (decision 1 below).
- **Wi-Fi only in 0.1.** There is no USB path without `adb`. A phone hotspot works around client-isolated
  networks, and S18 investigates USB before 1.0.
- **Latency.** MediaProjection → MediaCodec over Wi-Fi is slower than shell capture over USB. The targets are p50
  ≤ 100 ms and p95 ≤ 180 ms (S17). Optical acceptance stays open until a camera exists.
- **Android distribution starts with 0.1:** GitHub Releases and F-Droid first, Play deferred
  ([ADR-0006](0006-distribution.md) amended).

**Security model** ([re-plan §4](../plans/standard-first.md#4-security-model-changes)):
- In every release, mirroring and control require a Tombolo pairing **and** separate phone-granted scopes
  (`screen.view`, `screen.control`, clipboard). The phone enforces them per command and at execution time.
- **Phone-side controls in 0.1:**
  - Android's projection indicator.
  - The foreground-service notification with **Stop**, when notifications are allowed.
  - Stop in the app.
  - Stop and Revoke on the Mac.

  The phone shows which Mac is connected and what it may do. This disclosure is separate from the OS consent.
- **No ADB exception in 0.1 or 0.2.** The Advanced phase reintroduces a platform authority that Tombolo does not
  control: once Wireless debugging is on, **any** ADB-authorised controller can drive the phone, whatever
  Tombolo's scopes say. The Advanced setup screen must say so, and it must offer to turn debugging off when
  Advanced mode is off.
- **The security specification's lease is tightened** so that its worst case fits the 1 s release deadline. In-flight
  work is cancelled, and no elevation survives a release. All of this is to be confirmed by S7
  ([pairing and session §10](../security/pairing-and-session.md#10-lease-fail-closed-control)).

**Estimates** ([re-plan §5](../plans/standard-first.md#5-estimates-provisional-budgeting-ranges-not-commitments)).
These are provisional budgeting ranges in engineer-weeks, not commitments:

| Phase | Was | Now |
|---|---|---|
| 0 Foundations | 12–17 | 12–17 |
| → 0.1 Mirror | 10–14 | **34–50** |
| → 0.2 Connect | 26–36 | **14–20** |
| → 0.3 Advanced | 12–17 (+ 4–7 for the old app-windows release) | **17–27** |
| → 1.0 | 10–15 | **8–12** |
| **Total** | **74–106** | **85–126** |

The total is larger because there is no ADB shortcut, and because the old plan under-counted the lifecycle work and
the moved spikes. **First usable release:** Phase 0 + 0.1 ≈ **46–67 engineer-weeks from project start**, plus however
long the external review takes. With two developers that is very roughly 6–9 months to 0.1.

## Maintainer decisions (2026-11-02)
From [re-plan §9](../plans/standard-first.md#9-maintainer-decisions-2026-11-02):

1. **Security review gate.** Pairing may be **implemented now, behind a feature flag**. **Nothing that contains it
   ships until the external review closes**, that is, until every finding is resolved or explicitly accepted. The
   rework risk is accepted. This replaces "review before implementation" in the implementation plan,
   [ADR-0005](0005-pairing-and-identity.md) (amended), protocol §6 and the
   [security specification](../security/pairing-and-session.md).
2. **Audio in 0.1: yes.** This means playback capture: media and game audio, from the same profile. Apps may opt
   out, and call audio is never captured.
3. **Typing: Android 13+ only.** Phones on Android 10–12 mirror and accept gestures, but get no keyboard text input,
   and no other text path is built for them. Budget: "Standard capture, input and audio" drops from 6–9 to
   **5–7** ew, so 0.1 is **34–50** ew and the total is **85–126** ew.
