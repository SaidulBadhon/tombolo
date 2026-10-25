# ADR-0002: Native apps on both platforms

- **Status:** Proposed
- **Date:** 2026-10-25

## Context
The product promise is "feels like Apple built it". The mirror window must decode and present video with the
lowest possible latency and handle trackpad gestures and IME input precisely. Evidence:
[`research/03-macos-feasibility.md` §12](../research/03-macos-feasibility.md#12-language-and-ui-framework).

## Decision
- **Mac:** Swift 6. AppKit for the hot path (mirror `NSWindow`/`NSView`, `CAMetalLayer`, `NSTextInputClient`,
  events, drag and drop, app shims); SwiftUI for onboarding, settings, device list and `MenuBarExtra`.
  Minimum **macOS 14**, **Apple silicon only** (macOS 27 dropped Intel; Intel software stops working in 28).
- **Android:** Kotlin, Jetpack Compose, Material 3 with dynamic colour. Minimum **API 29 (Android 10)**;
  always target the latest API level.
- Rejected: Electron/Tauri (WebView video path adds copies and latency), Flutter (desktop gesture/IME gaps,
  external-texture latency), Compose Multiplatform Desktop (JVM bridge to VideoToolbox), Qt (viable but not
  native-feeling; Moonlight-qt shows it works).

## Consequences
- Two UI codebases. Shared logic lives in `tombolo-core` (Rust) and `proto/` schemas.
- Direct VideoToolbox → Metal zero-copy path, `CAMetalDisplayLink` pacing, Liquid Glass materials on 26+.
