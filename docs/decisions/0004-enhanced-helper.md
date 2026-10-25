# ADR-0004: Enhanced-mode helper forked from scrcpy-server

- **Status:** Proposed
- **Date:** 2026-10-25

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
