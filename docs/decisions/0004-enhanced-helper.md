# ADR-0004: Enhanced-mode helper forked from scrcpy-server

- **Status:** Proposed
- **Date:** 2026-10-25 · amended 2026-11-02 ([below](#amendment-2026-11-02-standard-mode-first))

## Context
scrcpy (Apache-2.0, very active: 4.0 May 2026, 5.0.1 Oct 2026) already solves shell-privileged capture,
virtual displays with `--new-display`/`--start-app` and resizable `--flex-display`, UHID keyboard/mouse,
playback audio capture and camera streaming. Its client/server protocol is officially internal and the server
refuses mismatched client versions, so every third-party client pins a build. Evidence:
[`research/01-existing-solutions.md` §2](../research/01-existing-solutions.md#2-scrcpy-genymobile).

## Decision
- **Phase 1:** the Mac pushes and drives a **pinned, unmodified `scrcpy-server`** build (fast path to a working
  mirror; also gives a "no phone app needed" USB mode).
- **Phase 3:** fork it as **`tombolo-helper`**, ship it inside the APK, and give it a private protocol to the
  Tombolo app over a UID-checked local socket. The app relays media/input through the authenticated Tombolo
  session. Track upstream and contribute fixes back where possible.
- Keep scrcpy's `NOTICE`/attribution.

## Consequences
- We inherit years of device-quirk fixes instead of rediscovering them.
- We own the helper protocol, so no version-lock with upstream releases.
- Merge work when upstream changes the server internals.
- Reference implementation for the Mac client: droidMirroring-mac (Apache-2.0) — reuse where code quality allows.

## Amendment 2026-11-02: Standard mode first
This is a maintainer decision, recorded in [ADR-0008](0008-standard-mode-first.md)
([re-plan §2](../plans/standard-first.md#2-decision-proposed)). The text above stays as decided on 2026-10-25.
Where it conflicts with this amendment, the amendment applies.

- **The pinned-server / helper path is Advanced-only: Phase 3, release 0.3 Advanced, optional.**
  - The Phase 1 step above no longer ships in Phase 1 or Phase 2. That was the Mac pushing and driving a pinned,
    unmodified `scrcpy-server` through a bundled `adb`.
  - No release before 0.3 contains a bundled `adb`, `ScrcpyBridge` or a dependency on scrcpy's protocol.
  - 0.1 Mirror and 0.2 Connect mirror and control through the Android app (Standard mode).
- **The helper is set up from the phone app.** The `tombolo-helper` fork described above is started through
  Wireless debugging, using on-device pairing (the Shizuku approach, previously "Path C" in Phase 4). Its media and
  input are relayed through the authenticated Tombolo session, as above.
- **No "no phone app needed" mode.** The re-planned releases don't include the USB mode without the phone app.
  Every release uses the Android app, and 0.1 has no USB path. Spike S18 investigates a USB path without debugging
  before 1.0.
- **ADB comes back with the Advanced phase, as a platform authority that Tombolo does not control.** Once Wireless
  debugging is on, any ADB-authorised controller can drive the phone, whatever Tombolo's scopes say. The Advanced
  setup screen must say so, and it must offer to turn debugging off when Advanced mode is off.
- **The helper-related spikes run before 0.3** instead of on Phase 0's critical path: S3 (virtual displays), S9
  (UHID keyboard), S12 (helper ↔ app relay) and S14 (app compatibility).
- **The consequences above still hold, but from 0.3:** the inherited device-quirk fixes, our own helper protocol and
  the merge work. Because the helper's media is relayed through the Tombolo session, the droidMirroring-mac
  reference matters at most for Advanced-phase work.
