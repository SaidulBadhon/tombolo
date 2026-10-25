# android/ — the Android app

> **No code here yet.** This directory is a placeholder from Phase 0 (task P0-01). The Android app starts in
> Phase 2 ("Connect"); Phase 0 Android experiments live in [`spikes/`](../spikes/README.md), not here.

**Purpose:** the Tombolo companion app for Android — Kotlin, Jetpack Compose, Material 3, Android 10
(API 29) or later. Package `io.github.saidulbadhon.tombolo`. Build flavours `foss` (F-Droid / GitHub) and
`play` ([ADR-0006](../docs/decisions/0006-distribution.md)).

**Future owner:** the Android + core track (Dev B) — see [implementation plan §2](../docs/implementation-plan.md#2-resource-loaded-estimate-and-schedule-two-developers).

## Planned contents

One Gradle project, with the modules proposed in [architecture §4.1](../docs/architecture.md#41-modules-gradle):

| Module | Responsibility |
|---|---|
| `:app` | Compose UI, onboarding, permissions in context, settings, Quick Settings tile, share target |
| `:service` | Foreground `ConnectionService`, session state machine, NSD advertisement, CompanionDeviceManager association |
| `:capture` | `CaptureProvider`: MediaProjection capture (Standard mode), helper capture (Enhanced mode) |
| `:input` | `InputProvider`: Accessibility input (Standard mode), helper input (Enhanced mode) |
| `:continuity` | Notifications, SMS, calls, clipboard, files, app list |
| `:helper` | `tombolo-helper`, forked from `scrcpy-server` (Apache-2.0) — its notices go into the repository's `NOTICE` file |
| `:core-bindings` | Generated Kotlin bindings for [`tombolo-core`](../core/README.md) (UniFFI) |

## Licence

GPL-3.0-or-later ([`LICENSE`](../LICENSE), [ADR-0007](../docs/decisions/0007-license.md)); forked third-party
code keeps its own licence and notices.
