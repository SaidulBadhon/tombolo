# apple/ — the macOS app

> **No code here yet.** This directory is a placeholder from Phase 0 (task P0-01). The first code lands in
> [Phase 1](../docs/implementation-plan.md#phase-1--mirror-no-developer-options-3450-ew--release-01) ("Mirror, no
> developer options", release 0.1); Phase 0 Mac experiments live in [`spikes/`](../spikes/README.md), not here.

**Purpose:** the native Tombolo app for macOS — Swift 6, AppKit + SwiftUI, macOS 14 or later, Apple silicon
only. Bundle ID `io.github.saidulbadhon.Tombolo`.

**Future owner:** the Mac track (Dev A) — see [implementation plan §2](../docs/implementation-plan.md#2-resource-loaded-estimate-and-schedule-two-developers).

## Planned contents

Swift packages, as proposed in [architecture §3.1](../docs/architecture.md#31-modules-swift-packages-inside-one-xcode-project).
Phases 1–4 deliver releases 0.1 Mirror, 0.2 Connect, 0.3 Advanced and 1.0.

| Package | Phase | Responsibility |
|---|---|---|
| `TomboloApp` | 1 | App lifecycle, onboarding (QR pairing, Local Network and firewall prompts), settings, device list, Stop and Revoke; menu bar extra in Phase 2 |
| `MirrorKit` | 1 | Mirror window, window ↔ display mapping; per-app windows in Phase 3 (Advanced) |
| `VideoPipeline` | 1 | VideoToolbox decode → **`AVSampleBufferDisplayLayer`** presentation (the default — spike S2 measured it ~24 ms faster than Metal on `CAMetalDisplayLink`, on macOS 27 only so far); Metal present-on-decode as the alternative behind a renderer toggle |
| `AudioPipeline` | 1 | Opus decode, jitter buffer, playback |
| `InputKit` | 1 | Trackpad, mouse and keyboard → Android events, including IME / text-commit input (Standard-mode typing needs Android 13+) |
| `ContinuityKit` | 2 | Notifications, clipboard, files, SMS and call UI models; manual Mac → phone paste already in Phase 1 |
| `ADBKit` | 3 | Advanced mode only — `adb` integration, as far as the Advanced setup needs it |
| `ScrcpyBridge` | 3 | Advanced mode only — client for the helper's scrcpy-derived protocol, as far as it is still needed once media is relayed through the Tombolo session |
| `CoreBindings` | 1 | Generated Swift bindings for [`tombolo-core`](../core/README.md) (UniFFI) |
| `AppShims` | 4 | Per-Android-app `.app` shims — only if spike S13's open checks pass |

**No helper before Phase 3.** Releases 0.1 and 0.2 have no bundled `adb`, no `scrcpy-server` and no scrcpy
protocol: the phone app captures the screen and injects input itself. The Enhanced-mode helper arrives with the
optional Advanced mode in [Phase 3](../docs/implementation-plan.md#phase-3--advanced-mode-optional-1727-ew--release-03),
set up from the phone app, with its media relayed through the authenticated Tombolo session.

## Licence

GPL-3.0-or-later, like the rest of the apps ([`LICENSE`](../LICENSE), [ADR-0007](../docs/decisions/0007-license.md)).
