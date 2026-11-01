# S1 — Latency harness

| | |
|---|---|
| **Spike** | S1 |
| **Task** | P0-04, *harness ready* half (the *validated end-to-end* half follows P0-15). See the [Phase 0 task plan](../plans/phase-0.md#acceptance-criteria-per-task) and its [execution notes](../plans/phase-0.md#execution-notes-2026-10-26-after-plan-verification) |
| **Pass criteria** | [Implementation plan, §0.C](../implementation-plan.md#0c-spikes-each-produces-a-short-write-up-in-docsspikes): *reproducible p50/p95/p99 with stated measurement uncertainty*. P0-04: phone renders a millisecond counter/pattern, a 240 fps camera films phone and mirror, a script extracts the difference per frame; p50/p95/p99 with stated uncertainty (± one camera frame ≈ 4.2 ms) from ≥ 300 samples, reproducible by a second person following the README. Execution notes: no high-speed camera, so the software-timestamp mode ships now and optical acceptance stays open |
| **Spike code** | [`tools/latency-harness/`](../../tools/latency-harness/README.md); latency results below produced with the code at commit `85c546a3d4133dee8adee09ed9e61f53758cb0a2` on branch `p0/04-latency-harness`; `9e9e8f2` later replaced a misleading diagnostic only (see Method), latency computation unchanged |
| **Author(s)** | Claude (agent) for the maintainer |
| **Date(s) run** | 2026-10-26 |
| **Status** | draft — harness ready on the Mac; phone validation and camera validation pending |

## Question

Can we measure phone → Mac mirror latency as p50/p95/p99 with an honest uncertainty, reproducibly, before the
mirror (S2) is built? Every later latency criterion depends on the answer: S2's p50 ≤ 60 ms / p95 ≤ 90 ms and the
release-time latency regression checks.

## Setup

**Devices**

| Role | Model | OS version and build | OEM skin / version | Notes (patch level, settings changed) |
|---|---|---|---|---|
| Phone | none used: the target device (Motorola edge 50 pro, Android 16) was disconnected (battery flat) | — | — | phone validation is queued after P0-15 |
| Mac | MacBook Pro 14-inch, M4 Pro, 12 cores (`Mac16,8`) | macOS 27.0.1 (26A434) | — | built-in Liquid Retina XDR, ProMotion up to 120 Hz, 1800 × 1169 pt at 2× |

**Builds and tools**

| Component | Version / commit | How obtained |
|---|---|---|
| Harness | `85c546a` (code), this branch | this repository |
| Swift | 6.4 (swiftlang-6.4.0.34.1), Command Line Tools only, swift-testing | Apple CLT |
| Python | 3.14.6 (standard library only) | preinstalled |
| ffmpeg / ffprobe | 9.0.2 (libx264) | Homebrew |
| Self-test browser | WKWebView, AppleWebKit/605.1.15 (`latency-harness page-window`) | macOS |

**Environment:** no phone, no camera. Other agents were running builds on the same Mac: load average 8–12 on 12
cores during the runs, so **all timing numbers are provisional**. The display was kept awake with
`caffeinate -d` for the duration of the self-test. During the runs another task's system alert (a Local Network
prompt) was on screen. It was left untouched and did not overlap the test windows.

## Method

**What was built** ([README](../../tools/latency-harness/README.md) has the details and commands):

- *Software-timestamp mode.* The phone shows a web page served from the Mac (`server/serve.py`). Every animation
  frame draws its `requestAnimationFrame` timestamp as a TLC1 symbol: 32 × 16 modules, four finder squares,
  40-bit payload + CRC-24, plus a readable counter. The page also runs Cristian-style clock sync against the Mac
  (`GET /time`, every 250 ms after a 64-trip burst) and logs the raw round trips. On the Mac,
  `latency-harness capture` records the mirror window with ScreenCaptureKit and decodes every frame. Each frame's
  timestamp is its `SCStreamFrameInfo.displayTime` (mach host clock, the same clock as the server). A sample is
  *displayTime of the first frame showing a value − Mac-clock equivalent of the page's render time*.
- *What `displayTime` is.* It is the presentation vsync that WindowServer scheduled for the composited frame. It
  is **not** the moment ScreenCaptureKit delivered the frame. In self-test A, 1 803 of 1 805 frames (99.89 %)
  reached our callback *before* their `displayTime` (median −3.32 ms); in B, 3 420 of 3 431 (99.68 %, median
  −5.16 ms). The summaries committed with these results print an "SCK delivery delay median" (A 2.68 ms, B
  3.65 ms). That line is the median of only the 2 and 11 frames that arrived late, so it is meaningless; ignore
  it. Commit `9e9e8f2` replaced it with the signed *frame arrival − displayTime* median over all frames plus the
  fraction arriving early. That is a diagnostic only: nothing, including P0-15, should treat it as a delivery or
  pipeline delay, and it is not used for latency.
- *Optical mode (validation deferred).* `latency-harness optical` reads a high-speed video with ffmpeg and decodes
  the phone, mirror and Mac-reference symbols in every frame. It computes, per phone frame, the camera frames
  between first appearance on the phone glass and on the mirror (± one camera frame). It also measures the
  camera's true frame rate against the Mac reference window (`latency-harness mac-code`), because slow-motion
  metadata is often wrong.
- *Uncertainty reported for software mode:* clock-sync bound = max RTT/2 of the exchanges used (holds for any
  path asymmetry), + 2 SE of the drift over half the run, + page timer resolution/2, + 0.05 ms tick rounding.
  These are systematic and apply to every percentile. There are also 95 % bootstrap CIs for each percentile, and
  counts of repeats, skipped source frames, negative samples and excluded outliers.

**What was run:**

1. `swift test`: encoder/decoder on synthetic images (60 random payloads at 3–8 px modules on cluttered
   backgrounds; scaling 0.5–2×; Gaussian noise σ 8/16/25; blur; JPEG quality 0.2/0.4/0.7; combined degradation;
   rotation + perspective; mirror image; low contrast; three symbols per frame). Also: blended (mid-transition)
   frames never decode to a third value, and every 1- and 2-bit error is rejected. JS ⇄ Swift parity (302
   payloads through JavaScriptCore). Clock sync on synthetic offsets, asymmetric delays, drift −60…+120 ppm,
   1 ms timer, queueing bursts and load-dependent asymmetry. Statistics. Analysis on synthetic captures. Optical
   analysis on a rendered 240 fps scene, including the transition-frame rule and wrong-fps detection.
2. `scripts/optical-synthetic.sh`: a 3 s, 640 × 360 synthetic clip at 240 fps. Phone at 60 Hz, mirror 45 ms later,
   Mac reference at 120 Hz, 2 ms pixel response, blur and noise; encoded with libx264 CRF 26, then analysed from
   the MP4.
3. `scripts/selftest.sh … 30`: **A.** the page in a floating WebKit window plays the "mirror": server + capture
   for 30 s, analysis with the logged sync. **B.** capture of the Mac reference window for 30 s (same clock on both
   ends, no sync).

**Physical steps that needed a person:** none for this half. Phone validation needs one (unlock, reload/tap the
page, keep the phone awake); see the README.

**Known sources of error (software mode):** clock-sync bound (stated); the Mac-side timestamp is the scheduled
presentation vsync of the composited frame (pixels then still need scan-out and panel response), and if
ScreenCaptureKit skips a composited frame the first appearance is late by one capture interval. The mode includes the phone browser's render → phone-glass delay and excludes the Mac panel's
scan-out and response, so it is **not** glass-to-glass. Optical mode closes that gap.

## Raw numbers

Raw data: [`tools/latency-harness/results/2026-10-26-selftest/`](../../tools/latency-harness/results/2026-10-26-selftest/page/summary.txt)
(`page/`, `mac/`, `optical-synthetic/`: summaries, capture metadata, sync log, gzipped per-frame and per-sample CSVs).

| Run | Condition | n | p50 | p95 | p99 | Notes |
|---|---|---|---|---|---|---|
| Self-test A | WebKit page window (60 Hz rAF) on the 120 Hz display, captured 30 s | 1 802 samples / 1 805 frames, **100.00 % decoded** | 11.80 ms [11.78, 11.82] | 12.68 ms [12.67, 12.69] | 12.76 ms [12.74, 19.81] | systematic ± 0.56 ms (sync ± 0.49: best RTT 0.88 ms, 9 windows; drift 0.5 ± 0.3 ppm → ± 0.01; timer 0.02 ms; ticks). min 10.49, max 20.95, sd 0.85; 0 negative, 0 outliers; 2 source frames not seen |
| Self-test B | Mac reference window (CADisplayLink, 120 Hz), captured 30 s | 3 431 samples / 3 431 frames, **100.00 % decoded** | 17.15 ms [17.15, 17.16] | 17.20 ms [17.20, 17.20] | 17.21 ms [17.21, 17.21] | same clock, ± 0.05 ms; min 8.78, max 33.85; 171 of the window's own frames not seen (display link or capture skipped them) |
| Optical (synthetic) | 240 fps H.264 clip, injected glass-to-glass latency 45.00 ms | 177 used (2 strict, 178 all) | 45.83 ms | 45.83 ms | 45.83 ms | ± 4.17 ms (one camera frame), check **PASS**. The uncorrected first-decode estimate, 41.67 ms, carries the phase-lock bias the transition-frame rule removes. Both estimates are within the script's ± 4.17 ms tolerance, so the scripted check cannot tell them apart (see below). Camera fps measured against the Mac clock: 239.995 |

[brackets] = 95 % bootstrap CI. Self-test values are from the linked `summary.txt` / `summary.json`. The script
re-runs the analysis after the page's last sync batch; `capture.log` holds the first pass at the end of capture
(A: ± 0.55 ms, sync ± 0.48, p99 CI up to 19.80) and is superseded. Ignore the "SCK delivery delay" line in those
files (see Method). **All self-test numbers are provisional:** they were measured at load average 8–12, against the
"never measure under load" rule; re-run on an idle Mac (scheduled after P0-15). Unit tests: see the verdict table
for the command and its output.

Earlier attempts on the same day, kept for the record:

| Attempt | What happened | Change made |
|---|---|---|
| Self-test A in Chrome (`--app`, throwaway profile) | The test window opened behind the user's own Chrome window and on a Space that ScreenCaptureKit did not list. Chrome throttled it (114 frames in ~40 s): 5 frames captured, 0 decoded | Added `page-window` (floating, all-Spaces WebKit window) as the self-test default. The script waits until the window is on screen. Screenshots from that attempt were deleted because they showed the user's own content, and `capture` now saves no images unless asked (`--save-failures`) |
| Self-test A, first WebKit run (code before `85c546a`) | 99.51 % decoded, p50 11.75 / p95 12.62 / p99 19.84 ms. The clock fit reported **14.8 ppm drift** between two clocks on the same machine | The offset per window tracked that window's RTT (load-dependent asymmetric queueing), and the drift fit absorbed it. The fit now uses the lower-RTT half of the windows, the bound is max RTT/2 of those, and drift SE is added to the uncertainty. Re-analysis of the same data: 2.7 ± 1.0 ppm |
| Optical synthetic, first run | p50 41.67 ms vs injected 45 ms: 3.33 ms low, which is still **inside** the ± 4.17 ms tolerance. The script reported FAIL only because its separate "≥ 50 clean samples" condition failed (2 clean samples); the latency check itself would have passed. The bias was found by inspecting the frames: the phone symbol never decoded on camera frames k ≡ 1 (mod 4) | 240 fps = 4 × 60 Hz phase-locks the camera to the display, so the phone's transition frame never decoded and its first appearance was always one frame late. Added the transition-frame rule (one undecodable frame before a first appearance counts as the appearance); strict and uncorrected stats are still reported. **The scripted synthetic check cannot detect this one-frame bias** (it is smaller than its tolerance). Only the unit test `transitionFrameRuleRemovesPhaseLockBias` does: it requires the corrected p50 to equal the true latency and the uncorrected one to be exactly one frame short |

## Verdict

| # | Criterion (as written in the plan) | Verdict | Evidence |
|---|---|---|---|
| 1 | S1: reproducible p50/p95/p99 with stated measurement uncertainty, from ≥ 300 **phone** samples | **blocked — needs phone (after P0-15)** | no phone connected; procedure ready in the [README](../../tools/latency-harness/README.md#phone-validation-software-mode--run-this-once-the-phone-is-back) |
| 2 | P0-04 optical method: 240 fps camera films phone + mirror, ± one camera frame ≈ 4.2 ms, ≥ 300 samples | **blocked — needs a high-speed camera** | pipeline implemented. Synthetic end-to-end check `scripts/optical-synthetic.sh` printed `check: p50 45.83 ms vs injected 45.00 ms (tolerance ±4.17 ms), used samples 177 -> PASS`. That check would also pass with the one-frame phase-lock bias; only the unit test `transitionFrameRuleRemovesPhaseLockBias` covers it |
| 3 | Reproducible by a second person following the README | **blocked — needs a second person (and the phone)** | README written; self-test and synthetic checks are scripted |
| 4 | Execution notes: software-timestamp mode ships now (harness ready) | **pass** | Mac-only evidence. `swift build -c release` builds; capture, analysis, page, server, Mac reference window and optical analyser all present |
| 5 | (task brief) Self-test without a phone: decode success rate, measured latency small and stable | **pass** | `scripts/selftest.sh`: A 100.00 % decoded, p50 11.80 / p95 12.68 ms ± 0.56; B 100.00 % decoded, p50 17.15 / p95 17.20 ms (table above). "Small and stable" is provisional: measured at load average 8–12; re-run on an idle Mac (scheduled after P0-15) |
| 6 | (task brief) Encoder/decoder unit-tested on synthetic images (noise, 0.5–2× scaling, JPEG-ish blur); clock-sync estimator on synthetic offsets/jitter | **pass** | `swift test`, output recorded in [the next section](#unit-test-run) |

**Coverage:** not covered: any phone or Android version; the S2 prototype and scrcpy as mirrors; USB vs Wi-Fi
transport; a real high-speed camera; a second person reproducing from the README; an unloaded Mac.

### Unit test run

`cd tools/latency-harness && swift test`, run once after the final code change; exit status 0. Output trimmed
to the per-test result lines (per-test timings removed). The build also printed 5 linker warnings of the form
`ld: warning: search path '/Library/Developer/CommandLineTools/Developer/…' not found`: Xcode-style search
paths that do not exist under the Command Line Tools, harmless.

```
✔ Test ticksAndUnwrap()
✔ Test inverse()
✔ Test knownVector()
✔ Test percentilesMatchType7()
✔ Test coarseTimerStillBounded()
✔ Test symmetricConstantOffset()
✔ Test burstOfQueuedSamplesIsRejected()
✔ Test asymmetricDelaysWithDrift(_:_:) with 4 test cases
✔ Test syncLogParsing()
✔ Test loadDependentAsymmetryIsNotMistakenForDrift()
✔ Test moduleMatrixHasFindersAndQuietSeparators()
✔ Test crcAndTicksMatchSwift()
✔ Test missingSyncIsReportedNotGuessed()
✔ Test bitsRoundTrip()
✔ Test csvRoundTrip()
✔ Test shortRunDoesNotFitDrift()
✔ Test mirroredImage()
✔ Test modulesMatchSwift()
✔ Test crcRejectsEverySingleAndDoubleBitError()
✔ Test transitionFrameRuleRemovesPhaseLockBias()
✔ Test emptyAndTinyImagesAreSafe()
✔ Test macReferenceNeedsNoSync()
✔ Test bootstrapIsDeterministicAndBracketsEstimate()
✔ Test recoversInjectedLatency()
✔ Test twoAndThreeSymbolsInOneFrame()
✔ Test noise(_:) with 3 test cases
✔ Test blur(_:) with 2 test cases
✔ Test trackingSkipsFullDetection()
✔ Test lowContrast()
✔ Test jpeg(_:) with 3 test cases
✔ Test rotationAndPerspective()
✔ Test cleanRenders()
✔ Test scaling(_:) with 7 test cases
✔ Test combinedDegradations()
✔ Test blendedFramesNeverDecodeToAThirdValue()
✔ Test syntheticSceneRecoversLatencyWithinOneFrame()
✔ Test wrongNominalFpsIsFlagged()
✔ Test run with 37 tests in 7 suites passed after 20.578 seconds.
```

## Consequences for the plan

- **None to estimates or scope.** The harness is ready for P0-15 to use. P0-15 should report its numbers as
  *software-timestamp (render → composited display)* and not as glass-to-glass, until optical mode is run.
- **S2's acceptance gate (p50 ≤ 60 / p95 ≤ 90 ms, optical) cannot close without a camera.** Maintainer action M2
  (a phone that records 240 fps slow motion) is still outstanding. Until then the software mode is a proxy: it
  includes the phone's render → glass delay (overstates) and excludes the Mac panel (understates).
- **Phone queue:** P0-04 validation runs right after P0-15 (README "Phone validation"), 3 × 60 s runs.
- **Follow-ups:**
  - `tools/README.md` still lists `latency-harness/` as *planned*: a P0-18 follow-up (this task does not own
    that file).
  - Re-run `scripts/selftest.sh` on an idle Mac after P0-15 and replace the provisional self-test numbers.
  - `9e9e8f2` (the arrival − displayTime diagnostic) still needs the `swift test` run scheduled before merge.
  - Under the Command Line Tools alone, swift-testing needs `-plugin-path …/host/plugins/testing`
    (`Package.swift` adds it automatically). Other Swift spikes will hit the same thing.
  - Optical mode should also be used once to measure the phone browser's render → glass delay. That turns
    software-mode numbers into calibrated estimates.
