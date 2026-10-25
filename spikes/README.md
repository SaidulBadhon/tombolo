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
  task that owns it. Spikes in the same wave never write each other's directories.
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
  them, except a later spike that imports an earlier one without modifying it (P0-16 reads P0-15's library).

## Planned Phase 0 spikes

| Directory | Spike | Task |
|---|---|---|
| `s02-mac-video/` | S2 Mac video pipeline | P0-15 |
| `s03-virtual-displays/` | S3 + S14 concurrent virtual displays, app compatibility | P0-05 |
| `s04-transport/` | S4 + S5 transport per path, iroh API surface | P0-14 |
| `s06-a11y-input/` | S6 Standard-mode control | P0-06 |
| `s07-lifecycle/` | S7 fail-closed lifecycle | P0-07 |
| `s08-macos-permissions/` | S8 (Mac) + S15 Local Network, grant persistence | P0-10 |
| `s08-android-local-network/` | S8 (Android) `ACCESS_LOCAL_NETWORK` | P0-11 |
| `s09-keyboard/` | S9 keyboard modes | P0-16 |
| `s10-uniffi/` | S10 UniFFI integration | P0-12 |
| `s11-background/` | S11 background survival, BLE/CDM wake | P0-08 |
| `s12-helper-relay/` | S12 helper ↔ app relay | P0-17 |
| `s13-app-shim/` | S13 app-shim viewer | P0-13 |
| `s16-calls/` | S16 call-control path | P0-09 |

S1 (the latency harness) is a lasting tool, so it lives in `tools/latency-harness/` instead.
