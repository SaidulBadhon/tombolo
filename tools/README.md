# tools/ — project tooling

**Purpose:** scripts and harnesses used to build, measure and release Tombolo — anything that isn't part of an
app. Each tool lives in its own directory with a README explaining how to run it.

**Future owner:** shared (docs & tooling) — see [implementation plan §2](../docs/implementation-plan.md#2-resource-loaded-estimate-and-schedule-two-developers).
Individual tools are owned by the task that creates them.

## Contents

| Tool | Status | What it does |
|---|---|---|
| [`check-links/`](check-links/README.md) | ✅ available | Checks relative Markdown links and `#anchors`; runs in CI on every push and pull request |
| [`latency-harness/`](latency-harness/README.md) | ✅ available — Phase 0, task P0-04 (spike S1) | Latency measurement (p50/p95/p99 with stated uncertainty): software-timestamp mode in use; optical glass-to-glass mode built, camera validation pending |
| [`pairing-vectors/`](pairing-vectors/README.md) | ✅ available — Phase 0, task P0-03 | Regenerates the pairing test vectors in `proto/testdata/pairing/` |
| [`signing/`](signing/README.md) | ✅ available — Phase 0, task P0-10 (spike S15) | Creates and uses one stable self-signed code-signing identity for Mac builds, so permission grants can survive updates |
| device-matrix scripts | planned — Phase 1 | Smoke tests across the device lab before releases |
| release tooling | planned — Phase 1 onwards | DMG / APK packaging, Homebrew tap, F-Droid build, update feeds |

Phase 1 delivers release 0.1 ([implementation plan](../docs/implementation-plan.md#phase-1--mirror-no-developer-options-3450-ew--release-01)).

Tools are GPL-3.0-or-later ([`LICENSE`](../LICENSE)) unless their directory says otherwise.
