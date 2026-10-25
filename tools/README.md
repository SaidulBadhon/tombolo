# tools/ — project tooling

**Purpose:** scripts and harnesses used to build, measure and release Tombolo — anything that isn't part of an
app. Each tool lives in its own directory with a README explaining how to run it.

**Future owner:** shared (docs & tooling) — see [implementation plan §2](../docs/implementation-plan.md#2-resource-loaded-estimate-and-schedule-two-developers).
Individual tools are owned by the task that creates them.

## Contents

| Tool | Status | What it does |
|---|---|---|
| [`check-links/`](check-links/README.md) | ✅ available | Checks relative Markdown links and `#anchors`; runs in CI on every push and pull request |
| `latency-harness/` | planned — Phase 0, task P0-04 (spike S1) | Optical glass-to-glass latency measurement (p50/p95/p99 with stated uncertainty) |
| `pairing-vectors/` | planned — Phase 0, task P0-03 | Regenerates the pairing test vectors in `proto/testdata/pairing/` |
| device-matrix scripts | planned — Phase 1a | Smoke tests across the device lab before releases |
| release tooling | planned — Phase 1a onwards | DMG / APK packaging, Homebrew tap, update feeds |

Tools are GPL-3.0-or-later ([`LICENSE`](../LICENSE)) unless their directory says otherwise.
