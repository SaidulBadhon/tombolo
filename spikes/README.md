# spikes/ — throwaway experiments

**Spike code is throwaway.** It exists to answer one question with measurements, and it is **never promoted
to production directly**: when a spike's answer is "yes", the production version is written again in
[`apple/`](../apple/README.md), [`android/`](../android/README.md), [`core/`](../core/README.md) or
[`proto/`](../proto/README.md), with review, tests and the full
[definition of done](../docs/implementation-plan.md#6-definition-of-done-every-task). Copying a spike file into
production code is not allowed; reading it for reference is.

**Future owner:** each spike directory belongs to the task that creates it — see the
[Phase 0 task list](../docs/plans/phase-0.md#task-list).

## Rules

- **One directory per spike**, named `sNN-<slug>/` (for example `s03-virtual-displays/`), written only by the
  task that owns it; a spike split in two adds a letter (`s11a-active-session/`, `s11b-background/`). Spikes in
  the same wave never write each other's directories.
- **The result is a document, not the code.** Every spike writes `docs/spikes/sNN-<slug>.md` from
  [the template](../docs/spikes/TEMPLATE.md): question, setup, method, raw numbers, verdict per acceptance
  criterion, consequences for the plan. Record the commit of the spike code you measured.
- Each spike directory has a short README: what it tests, how to build and run it, and which physical steps
  need a person (unlocking the phone, pressing power, changing networks).
- Spike code may skip tests, lint and polish. It may **not** contain secrets — signing keys, keystores and
  pairing secrets stay outside Git.
- Third-party code keeps its licence: a spike-only fork (for example a patched `scrcpy-server`) keeps its
  `LICENSE` and copyright notices in the spike directory, and every dependency must be GPL-3.0-compatible.
- Spikes are not shipped, not supported and not security-reviewed. Nothing outside `spikes/` may depend on
  them, except a later spike that imports an earlier one without modifying it: P0-19 imports P0-15's
  `MirrorCore` and P0-14's transport; P0-20, P0-06 and P0-07 build on P0-19's Android app; in Phase 3, P0-16
  reads P0-15's library.

## Spike inventory

Spike IDs as re-planned on 2026-11-02 ([re-plan §3](../docs/plans/standard-first.md#3-phase-0-changes)). *Gate*
is what the spike must pass before: **Phase 1** = the Phase 0 exit gate (P0-18), then release 0.1; **0.2 / 0.3 /
1.0** = before that release ([gates by release](../docs/plans/phase-0.md#gates-by-release)). Status as of
2026-11-02; every write-up is still a *draft* with its open rows listed in it.

| Spike | Question | Directory | Task | Gate | Write-up and status |
|---|---|---|---|---|---|
| S1 | Latency harness | [`tools/latency-harness/`](../tools/latency-harness/README.md) | P0-04 | Phase 1 | [s01](../docs/spikes/s01-latency-harness.md) — harness ready; end-to-end validation on S17 pending; optical open |
| S2 | Mac video pipeline | [`s02-mac-video/`](s02-mac-video/README.md) | P0-15 | Phase 1 (Mac half); 0.3 (USB phone path, moved) | [s02](../docs/spikes/s02-mac-video.md) — Mac half measured |
| S3 | Concurrent virtual displays + encoders | `s03-virtual-displays/` | P0-05 | 0.3 (moved) | not started |
| S4 | Transport per path | [`s04-transport/`](s04-transport/README.md) | P0-14 | Phase 1 (Wi-Fi phone runs) | [s04](../docs/spikes/s04-transport.md) — Mac half, timings provisional; phone runs outstanding |
| S5 | iroh/noq API surface | [`s04-transport/`](s04-transport/README.md) | P0-14 | Phase 1 | [s05](../docs/spikes/s05-iroh-api.md) — Mac rows pass; phone rows blocked |
| S6 | Standard control: Accessibility gestures, Android 13+ text commit | `s06-a11y-input/` | P0-06 | Phase 1 | not started |
| S7 | Fail-closed in the app | `s07-lifecycle/` | P0-07 | Phase 1 | not started |
| S8 (Mac) | macOS Local Network permission | [`s08-macos-permissions/`](s08-macos-permissions/README.md) | P0-10 | Phase 1 | [s08 Mac](../docs/spikes/s08-macos-local-network.md) — done; denied-state rows blocked |
| S8 (Android) | Android 17 `ACCESS_LOCAL_NETWORK` with Tombolo's transport (emulator) | `s08-android-local-network/` | P0-11 | Phase 1 | not started |
| S9 | Keyboard modes (UHID vs Mac text commit) | `s09-keyboard/` | P0-16 | 0.3 (moved) | not started |
| S10 | UniFFI integration | [`s10-uniffi/`](s10-uniffi/README.md) | P0-12 | Phase 1 | [s10](../docs/spikes/s10-uniffi.md) — Swift half; Keystore half and 30-minute soak outstanding |
| S11a | Active-session survival | `s11a-active-session/` | P0-20 | Phase 1 | not started |
| S11b | Idle/background survival, BLE/CDM wake | `s11b-background/` | P0-08 | 0.2 | not started |
| S12 | Helper ↔ app relay | `s12-helper-relay/` | P0-17 | 0.3 (moved) | not started |
| S13 | App-shim viewer | [`s13-app-shim/`](s13-app-shim/README.md) | P0-13 | 1.0 | [s13](../docs/spikes/s13-app-shim.md) — blocked rows (visual checks, macOS 14), not "passed" |
| S14 | Virtual-display app compatibility | `s03-virtual-displays/` | P0-05 | 0.3 (moved) | not started |
| S15 | Grant persistence across self-signed updates | [`s08-macos-permissions/`](s08-macos-permissions/README.md) | P0-10 | Phase 1 | [s15](../docs/spikes/s15-update-persistence.md) — Accessibility and launch-at-login rows blocked |
| S16 | Call-control path | `s16-calls/` | P0-09 | 0.2 | not started |
| S17 | Standard capture pipeline | `s17-standard-capture/` | P0-19 | Phase 1 | not started |
| S18 | No-debugging USB path (Android Open Accessory vs NCM tethering) | `s18-usb-no-debugging/` (proposed) | none yet; runs after Phase 0 | 1.0 | not started |

S1 (the latency harness) is a lasting tool, so it lives in `tools/latency-harness/` instead.
