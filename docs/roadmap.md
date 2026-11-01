# Feature roadmap

Legend — **Tier**: S = works in Standard mode (no developer options), E = needs Enhanced mode — the optional
*Advanced* setting from 0.3 (a helper started from the phone app through Wireless debugging; needs Developer
options and Android 11+), — = not tier-dependent. **Feasibility** from the research and spikes: ✅ proven by
existing software, 🟡 feasible but needs a spike, 🔴 not possible today / out of reach.

The release order was re-planned on 2026-11-02 so that the first release needs no Developer options
([re-plan](plans/standard-first.md)). Estimates and acceptance criteria per phase:
[implementation plan](implementation-plan.md).

## 0.1 — Mirror

Install one app on the phone and one on the Mac — no Developer options, no USB or Wireless debugging. Local Wi-Fi
only. Mirroring and control run through Tombolo's own pairing and encrypted session, and the phone checks what the
Mac may do on every command. Pairing is built behind a flag; nothing that contains it ships until the external
security review closes. Plan: [Phase 1](implementation-plan.md#phase-1--mirror-no-developer-options-3450-ew--release-01).

| Feature | Tier | Feasibility | Notes |
|---|---|---|---|
| Android app and Mac app, QR pairing on the local network | — | ✅ | After pairing, the phone separately grants this Mac what it may do (view, control, clipboard); pairing alone never grants control |
| Mirror the phone screen in a native Mac window | S | ✅ | MediaProjection → H.264 over Wi-Fi → VideoToolbox → `AVSampleBufferDisplayLayer`. Android asks for consent every session; the phone must stay unlocked — locking ends the session. Spike S17 measures latency (target p50 ≤ 100 ms, p95 ≤ 180 ms) |
| Share one app instead of the whole screen | S | 🟡 | Android 14+ consent dialog; view-only unless S17's input-safety tests pass |
| Mouse and trackpad control (tap, drag, scroll, gestures) | S | 🟡 | AccessibilityService gestures. Spike S6 decides per device and configuration; *view-only* is a supported outcome (e.g. Android 17 Advanced Protection revokes the service). Sideloaded installs may need *Allow restricted settings* first |
| Typing from the Mac keyboard (any Mac input method) | S | 🟡 | **Android 13+ only** (accessibility text commit). Android 10–12 phones get view and gestures, but no keyboard text input (a decision, not a spike outcome) |
| Phone audio on the Mac | S | 🟡 | Playback capture under the same consent (Android 10+): media and game audio only, apps can opt out, never call audio |
| Home, Back and Recents shortcuts; screenshots; rotation | S | ✅ | Navigation through Accessibility global actions (needs control); rotation resizes the same capture |
| Clipboard: paste Mac → phone (manual) | S | ✅ | Both ways from 0.2 |
| Stop from the phone or the Mac; revoke a Mac | — | 🟡 | Stop in the phone's notification (if notifications are allowed) and in the app; Stop and Revoke on the Mac. Every session fails closed (spike S7) — if S7 fails, control is disabled and 0.1 is view-only |
| Install: DMG or own Homebrew tap (Mac); GitHub or F-Droid (Android) | — | ✅ | Self-signed Mac builds need *Open Anyway* once; Google Play flavour deferred |

## 0.2 — Connect

Everyday phone features on the pairing and session 0.1 built; still no Developer options. Plan:
[Phase 2](implementation-plan.md#phase-2--connect-1420-ew--release-02).

| Feature | Tier | Feasibility | Notes |
|---|---|---|---|
| Always-on link: reconnects in the background when idle | — | 🟡 | Spike S11b (24 h idle, Doze, reboot, wake mechanism); OEM battery settings vary |
| Notifications as native Mac notifications, with reply | S | ✅ | One-time codes redacted on Android 15+ unless opted in |
| SMS conversations and sending (dual-SIM aware); MMS viewing | S | ✅ | MMS sending later; RCS only via notification reply |
| Caller ID; decline/answer/text-reply | S | 🟡 | Spike S16 picks the call-control path (deprecated APIs vs companion `InCallService`); call **audio** stays on the phone |
| Drag-and-drop files both ways, share sheet | S | ✅ | Resumable, hash-verified |
| Clipboard both ways: Mac → phone automatic, phone → Mac manual | S | ✅ | Within Android's limits; automatic both ways in Advanced mode |
| Battery/signal status, ring phone, DND sync | S | ✅ | |
| Menu bar extra | — | ✅ | |

## 0.3 — Advanced (optional)

An opt-in setting for users willing to turn on Developer options. Tombolo's helper (a fork of `scrcpy-server`)
runs with the `shell` user's permissions; it is started through Wireless debugging and set up from the phone app,
and its media goes through the authenticated Tombolo session. Once Wireless debugging is on, **any** computer the
phone has authorised for debugging can control it, whatever Tombolo's permissions say — the setup screen says so,
and offers to turn debugging off when Advanced mode is off. Plan:
[Phase 3](implementation-plan.md#phase-3--advanced-mode-optional-1727-ew--release-03).

| Feature | Tier | Feasibility | Notes |
|---|---|---|---|
| Advanced setup from the phone app; the phone starts the helper itself, also after a reboot | E | 🟡 | On-device Wireless-debugging pairing (the Shizuku approach; was planned for 1.0). Android 11+; Wireless debugging turns off when the Wi-Fi network changes |
| Phone apps as separate, resizable Mac windows | E | 🟡 | Virtual display per window; app-compatibility list + fallback (spike S14); concurrent-window cap per device class (S3) |
| App launcher palette (⇧⌘A) | E | ✅ | Opens apps in their own windows |
| Mirroring with the phone's screen off | E | ✅ | An awake, **unlocked** phone with its panel dark (scrcpy-proven); the session ends when someone uses the phone. Not locked-phone mirroring |
| No consent prompt per session (screen and audio) | E | ✅ | scrcpy-proven; audio Android 11+ |
| Real-time multi-touch; Android-keyboard (UHID) mode | E | ✅ | scrcpy-proven; spike S9 tests the keyboard modes |
| Clipboard both ways, automatic | E | ✅ | |
| Switch Standard ↔ Advanced without re-pairing | — | 🟡 | Same session, capability-driven UI |

## 1.0

Hardening and polish, plus an external review of the implementation, fuzzing of all parsers, accessibility of
Tombolo's own controls and localisation. Plan: [Phase 4](implementation-plan.md#phase-4--10-812-ew).

| Feature | Tier | Feasibility | Notes |
|---|---|---|---|
| Each phone app with its own Dock icon / ⌘-Tab / Spotlight entry | E | 🟡 | Locally generated app shims (Chrome PWA pattern); only if spike S13's open checks pass (visual checks and macOS 14 are still blocked) |
| Click a notification → app opens in its own window | E | 🟡 | |
| Touch ID before control (hardware-enforced) | — | ✅ | Secure Enclave key policy |
| Auto-updates (Sparkle) and distribution polish | — | ✅ | Google Play flavour still undecided (Accessibility policy) |

## Later (1.x)

| Feature | Tier | Feasibility | Notes |
|---|---|---|---|
| Phone camera as Mac webcam | E | 🟡 | Needs paid Apple Developer ID (camera extension) |
| Use from anywhere (outside home Wi-Fi) | — | 🟡 | Self-hosted relay; off by default |
| USB connection without Developer options | S | 🟡 | Android Open Accessory or NCM USB tethering; spike S18 runs before 1.0 and decides. Until then: Wi-Fi, or the phone's hotspot on networks that isolate clients |
| Call audio on the Mac | — | 🔴/🟡 | No public Android API; macOS Bluetooth hands-free role is a research item |
| LocalSend / KDE Connect / Quick Share interop | — | ✅ | Open or documented protocols |
| Multiple phones, tablets, foldables | — | ✅ | |
| Mac keyboard/mouse "flowing" onto the phone screen | E | 🟡 | |

## Explicitly not planned

- **Mirroring a locked phone, in any mode** — Android stops screen capture when the phone locks (Android 15
  QPR1+), and Advanced mode only allows a dark screen on an *unlocked* phone. iPhone Mirroring's "phone stays
  locked" model can't be copied securely.
- **iMessage, FaceTime or anything Apple-account-bound** — not possible for third parties.
- **A cloud service or account system** — contradicts the free/self-hosted principle.
- **Mac App Store build** — the sandbox blocks spawning `adb`/helpers and per-app shims, and complicates USB.
- **Rooted-only features** — Tombolo must work on stock phones.
- **Capturing protected content** (`FLAG_SECURE` apps such as banking or DRM video) — Android blocks it, and
  Tombolo respects that.
