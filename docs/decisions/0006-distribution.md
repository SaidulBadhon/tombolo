# ADR-0006: Distribution without paid services

- **Status:** Proposed
- **Date:** 2026-10-25

## Context
- **macOS:** unsigned arm64 code won't run at all; ad-hoc-signed downloads fail Gatekeeper and need *System
  Settings › Privacy & Security › Open Anyway* (the Control-click bypass was removed in macOS 15). Homebrew
  disabled 627 casks that fail Gatekeeper on 2026-09-01; official casks need Developer ID + notarization
  ($99/yr). Third-party taps still work. Every comparable FOSS Mac app checked (Moonlight, Rectangle, Stats,
  AltTab, Ice, LocalSend) pays for a Developer ID. The Mac App Store sandbox blocks spawning `adb`/helper
  tools and locally generated app shims, and makes USB access entitlement-dependent.
- **Android:** developer verification enforcement began 2026-09-30 in four countries and goes global in 2027;
  registering a package name is free; unregistered apps need ADB or the "advanced flow". F-Droid's re-signing
  model conflicts with verification (unresolved). Google Play reviews Accessibility, SMS/Call Log and
  all-files access.
Evidence: [`research/03`](../research/03-macos-feasibility.md#8-distribution-without-paying-apple-critical),
[`research/02`](../research/02-android-feasibility.md#214-distribution-and-policy).

## Decision
- **Mac:** sign every build with one stable self-signed identity (expected to let permission grants survive
  updates — an inference from Apple TN3127, verified by spike S15 before we rely on it);
  distribute via GitHub Releases DMG, an own Homebrew tap, and a build-from-source script; Sparkle 2 (EdDSA)
  for updates. No Mac App Store. Adopt Developer ID + notarization as soon as the project can fund it.
- **Android:** register the package name under developer verification. Limited distribution (free) caps at
  20 devices, so public distribution needs **full distribution: a one-time $25 registration** (a project cost,
  never a user cost). Two flavours — `foss` (GitHub Releases + F-Droid, full features) and `play`
  (policy-adjusted, optional, from 1.0).
- **Users never pay and never create an account.**

## Consequences
- Install friction on macOS until a Developer ID is funded (documented, illustrated install guide).
- The webcam feature waits for a Developer ID (camera extensions need notarization).
