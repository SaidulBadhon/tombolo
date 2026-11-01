# android/ — the Android app

> **No code here yet.** This directory is a placeholder from Phase 0 (task P0-01). The Android app starts in
> [Phase 1](../docs/implementation-plan.md#phase-1--mirror-no-developer-options-3450-ew--release-01) ("Mirror, no
> developer options", release 0.1); Phase 0 Android experiments live in [`spikes/`](../spikes/README.md), not here.

**Purpose:** the Tombolo companion app for Android — Kotlin, Jetpack Compose, Material 3, Android 10
(API 29) or later. Package `io.github.saidulbadhon.tombolo`. Distributed through GitHub and F-Droid first (`foss`
flavour); a Google Play flavour is **deferred** — not decided until the Accessibility policy risk is understood
([ADR-0006](../docs/decisions/0006-distribution.md)).

**Future owner:** the Android + core track (Dev B) — see [implementation plan §2](../docs/implementation-plan.md#2-resource-loaded-estimate-and-schedule-two-developers).

## Planned contents

One Gradle project, with the modules proposed in [architecture §4.1](../docs/architecture.md#41-modules-gradle).
Phases 1–4 deliver releases 0.1 Mirror, 0.2 Connect, 0.3 Advanced and 1.0.

| Module | Phase | Responsibility |
|---|---|---|
| `:app` | 1 | Compose UI, onboarding (QR pairing, per-Mac permissions, Accessibility), permissions in context, Stop and Revoke, settings; Quick Settings tile and share target in Phase 2 |
| `:service` | 1 | Foreground service for the active mirroring session, session state machine, NSD advertisement; idle/background reconnection and CompanionDeviceManager association in Phase 2 |
| `:capture` | 1 | `CaptureProvider`: MediaProjection capture with playback-capture audio (Standard mode); helper capture (Enhanced mode) in Phase 3 |
| `:input` | 1 | `InputProvider`: Accessibility gestures, and text on Android 13+ (Standard mode); helper input (Enhanced mode) in Phase 3 |
| `:continuity` | 2 | Notifications, SMS, calls, clipboard, files, app list; Mac → phone paste already in Phase 1 |
| `:helper` | 3 | `tombolo-helper`, forked from `scrcpy-server` (Apache-2.0), for the optional Advanced mode — its notices go into the repository's `NOTICE` file |
| `:core-bindings` | 1 | Generated Kotlin bindings for [`tombolo-core`](../core/README.md) (UniFFI) |

## Licence

GPL-3.0-or-later ([`LICENSE`](../LICENSE), [ADR-0007](../docs/decisions/0007-license.md)); forked third-party
code keeps its own licence and notices.
