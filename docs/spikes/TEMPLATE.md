# SNN — Spike title

<!--
Copy this file to docs/spikes/sNN-<slug>.md (for example s07-fail-closed.md) and fill in every section.
Write "none" or "not applicable" rather than deleting a section. Delete these HTML comments when done.
Rules that apply to every result:
- Report what was measured, on which hardware. A criterion that could not be run on the required device or
  OS version is "blocked — needs <X>", never "pass".
- Numbers come from the measurement method below, not from software telemetry alone, unless the criterion
  says otherwise. State the uncertainty.
- Keep raw data (CSV, logs, screenshots) in the spike directory, or link to where it is stored.
-->

| | |
|---|---|
| **Spike** | SNN (add any combined spikes, e.g. S3 + S14) |
| **Task** | P0-NN — see the [Phase 0 task plan](../plans/phase-0.md#acceptance-criteria-per-task) |
| **Pass criteria** | Copied from the [implementation plan, §0.C](../implementation-plan.md#0c-spikes-each-produces-a-short-write-up-in-docsspikes) and the task's acceptance criteria |
| **Spike code** | `spikes/sNN-<slug>/` at commit `<full SHA>` |
| **Author(s)** | |
| **Date(s) run** | YYYY-MM-DD – YYYY-MM-DD |
| **Status** | draft · complete · superseded by … |

## Question

The one question this spike answers, in a sentence or two, and why the plan depends on the answer.

## Setup

**Devices**

| Role | Model | OS version and build | OEM skin / version | Notes (patch level, settings changed) |
|---|---|---|---|---|
| Phone | e.g. Motorola edge 50 pro | Android 16, build … | Hello UI … | security patch 2026-MM-01 |
| Mac | e.g. MacBook Pro (M3, 2023) | macOS 27.0.1 (build …) | — | |

**Builds and tools**

| Component | Version / commit | How obtained |
|---|---|---|
| Spike code | `<full SHA>` | this repository |
| e.g. scrcpy-server | v… | pinned release, SHA-256 … |
| e.g. Swift / Rust / JDK / Android SDK | … | … |

**Environment:** connection type (USB cable, Wireless debugging, Wi-Fi network and band), anything else that
could affect the numbers (other load on the Mac, thermal state, battery level, Low Power Mode).

## Method

What was done, step by step, precisely enough that a second person can reproduce it from the spike
directory's README. Include:

- the commands run and the measurement procedure;
- sample sizes and run durations;
- **physical steps that needed a person** (unlocking, pressing power, unplugging, changing networks);
- known sources of error and the stated uncertainty (for example ± one camera frame ≈ 4.2 ms at 240 fps).

## Raw numbers

Tables of measured values, with units and sample counts. Link the raw data files.

| Run | Condition | n | p50 | p95 | p99 | Notes |
|---|---|---|---|---|---|---|
| 1 | | | | | | |

## Verdict

One row per acceptance criterion. Verdict is exactly one of: **pass** · **fail** · **blocked — needs X**
(name what is missing: hardware, OS version, a person, another task) · **not run**.

| # | Criterion (as written in the plan) | Verdict | Evidence |
|---|---|---|---|
| 1 | | | link to the raw numbers or log above |

**Coverage:** list the devices and OS versions the criteria require that were *not* covered.

## Consequences for the plan

- What changes in the implementation plan, the roadmap, an ADR or an estimate — or "none".
- Which fallback (from the "If it fails" column of §0.C) is triggered, if any.
- Follow-up work and open questions, each with an owner or an issue link.
