# apple/ — the macOS app

> **No code here yet.** This directory is a placeholder from Phase 0 (task P0-01). The first code lands in
> Phase 1a ("Mirror"); Phase 0 Mac experiments live in [`spikes/`](../spikes/README.md), not here.

**Purpose:** the native Tombolo app for macOS — Swift 6, AppKit + SwiftUI, macOS 14 or later, Apple silicon
only. Bundle ID `io.github.saidulbadhon.Tombolo`.

**Future owner:** the Mac track (Dev A) — see [implementation plan §2](../docs/implementation-plan.md#2-resource-loaded-estimate-and-schedule-two-developers).

## Planned contents

Swift packages, as proposed in [architecture §3.1](../docs/architecture.md#31-modules-swift-packages-inside-one-xcode-project):

| Package | Responsibility |
|---|---|
| `TomboloApp` | App lifecycle, menu bar extra, onboarding, settings, device list |
| `MirrorKit` | Mirror window and per-app windows, window ↔ display mapping |
| `VideoPipeline` | VideoToolbox decode → Metal presentation, display-link pacing; `AVSampleBufferDisplayLayer` fallback |
| `AudioPipeline` | Opus decode, jitter buffer, playback |
| `InputKit` | Trackpad, mouse and keyboard → Android events, including IME / text-commit input |
| `ContinuityKit` | Notifications, clipboard, files, SMS and call UI models |
| `ADBKit` | Bundled `adb` integration: device tracking, Wireless-debugging pairing, loopback-only forwards |
| `ScrcpyBridge` | Client for a pinned `scrcpy-server` (Phases 1a–2 only) |
| `CoreBindings` | Generated Swift bindings for [`tombolo-core`](../core/README.md) (UniFFI) |
| `AppShims` | Per-Android-app `.app` shims — Phase 4, only if spike S13 passes |

## Licence

GPL-3.0-or-later, like the rest of the apps ([`LICENSE`](../LICENSE), [ADR-0007](../docs/decisions/0007-license.md)).
