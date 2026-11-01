# ADR-0006: Distribution without paid services

- **Status:** Proposed
- **Date:** 2026-10-25 · amended 2026-11-02 ([below](#amendment-2026-11-02-android-distribution-from-01))

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
- **Funding timing (maintainer decision, 2026-10-26):** ship free self-signed Mac builds and limited Android
  distribution first; pay Apple's $99/yr Developer ID and Android's one-time $25 full-distribution fee **once
  there are real users** — at the latest before Android developer verification reaches users' regions (2027).

## Consequences
- Install friction on macOS until a Developer ID is funded (documented, illustrated install guide).
- The webcam feature waits for a Developer ID (camera extensions need notarization).

## Amendment 2026-11-02: Android distribution from 0.1
This is recorded in [ADR-0008](0008-standard-mode-first.md)
([re-plan §2](../plans/standard-first.md#2-decision-proposed), [§5](../plans/standard-first.md#5-estimates-provisional-budgeting-ranges-not-commitments),
[§8](../plans/standard-first.md#8-explicitly-not-doing)). The text above stays as decided. Where it conflicts with
this amendment, the amendment applies.

- **Android public distribution is needed for 0.1.**
  - The first release now contains the Android app (previously 0.2), so the `foss` flavour must be publicly
    installable from **0.1 Mirror**.
  - Channels: **GitHub Releases and F-Droid first.** The F-Droid build moves from Phase 4 into 0.1's distribution
    work, together with Android signing and verification.
  - F-Droid's re-signing conflict with developer verification (*Context*) is still unresolved, and the F-Droid
    channel depends on resolving it.
- **Google Play is deferred.** No `play` flavour is decided now, because of the Accessibility policy risk. The
  *Decision* above scheduled `play` "from 1.0"; it is now deferred with no date.
- **The funding timing still holds, but it is reached sooner.**
  - The 2026-10-26 decision is to pay "once there are real users".
  - 0.1 is now the first release with Android users, so that point comes with 0.1, not 0.2.
  - Limited distribution (20 devices) cannot carry a public release. Unregistered apps need ADB or the "advanced
    flow" (*Context*), and a release built to need no developer options should not depend on either.
  - So the one-time $25 full-distribution registration is needed before 0.1 reaches users in regions where
    developer verification is enforced, and everywhere once it goes global (2027).
  - The Mac side is unchanged: the Mac app was already part of 0.1.
- **Sideloading affects 0.1's onboarding** ([re-plan §2, "What it costs"](../plans/standard-first.md#what-it-costs)):
  - Sideloaded installs may need *Allow restricted settings* before Accessibility can be enabled. Whether F-Droid
    installs are exempt is a hypothesis that spike S6 tests.
  - Android 17 Advanced Protection restricts sideloading and revokes non-tool accessibility services.
    Distributing through GitHub and F-Droid does not avoid that.

  Onboarding covers both.
- **Mac: unchanged.** Releases ship as a DMG on GitHub Releases and through our own Homebrew tap. 0.1 adds the Local
  Network and Application Firewall steps to onboarding.
