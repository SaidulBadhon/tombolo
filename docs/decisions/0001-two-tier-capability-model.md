# ADR-0001: Two capability tiers behind one protocol

- **Status:** Proposed
- **Date:** 2026-10-25

## Context
Android lets a normal app capture the screen only with a per-session consent dialog (Android 14+), stops
capture when the phone locks (Android 15+), limits input injection to AccessibilityService gestures, blocks
background clipboard reads (Android 10+), and does not let third-party apps place other apps on separate
displays. A shell-privileged helper started over ADB (the scrcpy approach) removes all of those limits but
requires Developer options and USB/Wireless debugging, and does not survive a reboot.
Evidence: [`research/02-android-feasibility.md`](../research/02-android-feasibility.md).

## Decision
Ship both, behind one protocol:
- **Standard mode** (default): everything a normal app can do — mirroring with consent, Accessibility-based
  control, and all continuity features (notifications, SMS, calls, clipboard, files).
- **Enhanced mode** (opt-in): a shell-privileged helper provides capture, input, virtual displays (per-app
  windows), automatic clipboard and prompt-free audio.

The phone announces `server_mode` and a capability list in `Hello`; the Mac adapts its UI. Capture and input
sit behind `CaptureProvider` / `InputProvider` interfaces on Android so tiers can be swapped per session.

## Consequences
- Two implementations of capture and input on Android (more code, more tests).
- Users who never touch developer settings still get a useful product; power users get iPhone-Mirroring-class
  features, plus per-app windows Apple doesn't offer.
- The UI must explain tiers honestly (Enhanced setup wizard, mockup 7).
- LinkMyMac (closed source) validates the same two-tier model commercially.
