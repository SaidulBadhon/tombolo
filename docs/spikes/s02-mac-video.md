# S2 — Mac video pipeline

| | |
|---|---|
| **Spike** | S2 |
| **Task** | P0-15 — see the [Phase 0 task plan](../plans/phase-0.md#acceptance-criteria-per-task) and its [execution notes](../plans/phase-0.md#execution-notes-2026-10-26-after-plan-verification) |
| **Pass criteria** | [Implementation plan, §0.C](../implementation-plan.md#0c-spikes-each-produces-a-short-write-up-in-docsspikes): *1080p60 H.264; p50 ≤ 60 ms / p95 ≤ 90 ms on USB (optical)*; if it fails, *try the `AVSampleBufferDisplayLayer` renderer*. P0-15: Swift prototype that pushes and launches a pinned scrcpy-server via `adb`, decodes with VideoToolbox, presents with Metal on `CAMetalDisplayLink`, plus an `AVSampleBufferDisplayLayer` variant; measured with the S1 harness; CPU and energy impact recorded. Execution notes: no high-speed camera, so the S1 software-timestamp mode is used; an importable Swift library target for P0-16 |
| **Spike code** | [`spikes/s02-mac-video/`](../../spikes/s02-mac-video/README.md). Pipeline code at `280416c55dfcddbd02544225ff1605402c3a4fff`; scripts, loopback source and window options at `c70d5cae0249e2b2e69f5a9d9167dc9e7cf3f869` (see [Method](#method) for which run used which). Harness: `tools/latency-harness` merged from `p0/04-latency-harness` at `e92fe4660070bb455e26116ca494462c60041993` (harness code `85c546a3d4133dee8adee09ed9e61f53758cb0a2`) |
| **Author(s)** | Claude (agent) for the maintainer |
| **Date(s) run** | 2026-11-01 |
| **Status** | draft — Mac half measured; **the phone-path acceptance runs are blocked** (the phone dropped off USB during the first trial runs) |

## Question

Can a native Mac client — pinned scrcpy-server over `adb`, VideoToolbox decode, Metal presentation paced by
`CAMetalDisplayLink` — show the phone at 1080p60 H.264 over USB within p50 ≤ 60 ms / p95 ≤ 90 ms, at an acceptable
CPU and energy cost? And is `AVSampleBufferDisplayLayer` a better presenter? Phase 1a's mirror (0.1) is built on
the answer, and P0-16 builds its keyboard experiments on this prototype.

## Setup

**Devices**

| Role | Model | OS version and build | OEM skin / version | Notes (patch level, settings changed) |
|---|---|---|---|---|
| Phone | Motorola edge 50 pro (`motorola_edge_50_pro`, device `eqe`) | Android 16 (API 36), build `W1UMS36H.52-73-10-7` | Motorola (stock) | security patch 2026-09-01. Panel 1220 × 2712, 450 dpi, 60–144 Hz (`peak_refresh_rate` 144, `min_refresh_rate` 60; it ran at **60 Hz** for the latency page: active mode 60 Hz, page rAF interval 16.7 ms). **No settings changed** (see [phone state](#phone-state-left-behind)). Battery 70–71 %, charging on AC, 30–32 °C |
| Mac | MacBook Pro 14-inch, Apple M4 Pro, 12 cores (8P + 4E), 48 GB (`Mac16,8`) | macOS 27.0.1 (26A434) | — | built-in Liquid Retina XDR, ProMotion up to 120 Hz, 3024 × 1964, 2× backing scale. **On battery** (59–71 %, discharging) for every run |

**Builds and tools**

| Component | Version / commit | How obtained |
|---|---|---|
| Spike code | `280416c…` (pipeline), `c70d5ca…` (scripts, loopback, window options) | this repository |
| scrcpy-server | **v5.0.1**, file `scrcpy-server-v5.0.1`, 733 930 bytes, **SHA-256 `764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536`** | official release [Genymobile/scrcpy v5.0.1](https://github.com/Genymobile/scrcpy/releases/tag/v5.0.1) (published 2026-10-08). The hash matches both the release's `SHA256SUMS.txt` and the asset digest GitHub reports. Downloaded by `scripts/fetch-server.sh` into its own new directory outside the repository (`~/Library/Caches/tombolo-s02/scrcpy-server-v5.0.1/`); not committed. **Licence: Apache-2.0** (© Genymobile, Romain Vimont) |
| scrcpy sources read for the protocol | v5.0.1 tag tarball | `app/src/server.c` (launch command, `validate_string`, tunnel-forward connect + dummy byte, device-name read), `app/src/demuxer.c` (codec id, session packet, 12-byte packet header, config/key-frame flags), `app/src/control_msg.{h,c}`, `app/src/device_msg.{h,c}`, `app/src/util/binary.h` (fixed-point), `app/src/util/str.c` (UTF-8 truncation); `server/src/main/java/com/genymobile/scrcpy/Options.java` (argument parsing, defaults), `…/device/DesktopConnection.java` (socket order, dummy byte, 64-byte device name), `…/device/Streamer.java` (stream framing), `…/video/SurfaceEncoder.java` (MediaFormat keys) |
| Latency harness | `e92fe46` (code `85c546a`), software-timestamp mode | `p0/04-latency-harness`, merged into this branch. The later harness commit `9e9e8f2` (head `8181d1f`), which replaces the "SCK delivery delay" metric, was **not** used; no number below uses that metric |
| Swift | 6.4 (swiftlang-6.4.0.34.1), Command Line Tools only, swift-testing | Apple CLT |
| adb | 1.0.41, platform-tools 37.0.1-15733141 | Android SDK |
| Python | 3.14.6 | Homebrew |
| Phone browser for the page | Chrome 156 | preinstalled |

**Environment:** USB — the phone on the Mac's USB 2.0 port (480 Mb/s), adb forward for the video/control sockets,
adb reverse for the harness page. Mac load average 3–6 on 12 cores throughout (a Virtualization VM at ~19 % of a
core, Chrome helpers, WindowServer ~20–45 %; no builds during captures). Mac on battery, no thermal or performance
warning recorded (`pmset -g therm`). Phone thermal status 0. A person was evidently using the phone and the Mac
during the session (see [phone runs](#phone-runs)).

## Method

**What was built** ([README](../../spikes/s02-mac-video/README.md)):

- `MirrorCore` (SwiftPM library): `ADB` (drives `adb`), `ServerOptions` / `ScrcpyServerPin` (pinned version, hash,
  launch arguments, shell-metacharacter check), `MirrorSession` (push → `adb forward tcp:0 localabstract:scrcpy_<scid>`
  → `adb shell CLASSPATH=… app_process / com.genymobile.scrcpy.Server 5.0.1 …` → connect video, read dummy byte,
  connect control, remove forward, read device name), `StreamDemuxer` (v5 framing), `H264AccessUnitAssembler`
  (Annex-B → AVCC, SPS/PPS → `CMVideoFormatDescription`), `VideoDecoder` (`VTDecompressionSession`, hardware,
  real-time, synchronous, NV12 video-range IOSurface buffers), `MetalPresenterView` (zero-copy `CVMetalTextureCache`,
  YCbCr → RGB shader compiled at runtime from source, newest frame wins; pacing **`CAMetalDisplayLink`** on its own
  thread, or **immediate** — `nextDrawable()` on decode), `SampleBufferPresenterView` (**AVSampleBufferDisplayLayer**,
  the same decoded buffers as display-immediately samples), `ControlChannel` + every scrcpy 5.0.1 control/device
  message codec, `PipelineStats` (Mac-side telemetry), and a synthetic scrcpy-compatible source.
- `s02-mirror` (thin AppKit executable) and `run.sh` (fetch + build + run).
- Server arguments for every run: `scid=… log_level=info audio=false max_size=2400 max_fps=60 tunnel_forward=true
  clipboard_autosync=false` (H.264, 8 Mb/s, control on: the scrcpy defaults). `max_size 2400` gives **1078 × 2400**
  on this panel (1220 × 2712 scaled, then the encoder's size alignment): the "1080p" of the plan read as 1080 on the
  short side, as the project's mockups do (2.59 Mpx, more than 1920 × 1080).
- 32 swift-testing tests: wire formats against the scrcpy byte layouts, Annex-B splitting, VideoToolbox decode of
  real H.264, and a full session over loopback TCP against the synthetic source (see [unit tests](#unit-test-run)).

**Measurements:**

1. **Loopback, Mac half (harness, no phone).** `scripts/loopback.sh PRESENTER 30`: `loopback/s02-loopback-source`
   draws the **Mac host clock** as a TLC1 symbol (harness `CodeLayout`, kind "mac") into 1080 × 2400 frames, encodes
   them with VideoToolbox H.264 at 60 fps and serves them exactly like scrcpy-server on 127.0.0.1. `s02-mirror --port`
   shows them (separate process). The harness captures the mirror window region of the composited display and reads
   the clock back. One clock at both ends, so no sync: the latency is **render → VT encode → TCP → demux → VT decode
   → present → WindowServer composite**. It excludes the phone, USB and adb, and includes ~1–2 ms of Mac-side encode
   that the real path does not have. Two interleaved rounds × {metal (display link), sbdl, metal-immediate} × 30 s,
   code `280416c` + the loopback source of `c70d5ca` (`s02-mirror` differed from `c70d5ca` only in window Space
   behaviour and logging).
2. **CPU and energy, Mac (no harness capture).** `CAPTURE=0 scripts/loopback.sh PRESENTER 60`, code `c70d5ca`:
   `top -l … -stats pid,command,cpu,power` once per second for the mirror process, the synthetic source and
   WindowServer, plus a 60 s WindowServer baseline with no mirror. `power` is top's energy-impact score (the
   Activity Monitor "Energy Impact" scale). The app also logs its own `getrusage` CPU.
3. **Phone runs (harness software-timestamp mode).** `scripts/measure.sh PRESENTER 60`: phone page via
   `adb reverse tcp:8765`, Chrome opened with `am start`, one `input tap` (fullscreen + wake lock), `s02-mirror`
   floating at a fixed position, harness `capture` of its window, `analyze`. Also phone `top` (scrcpy server,
   encoder HAL `media.hwcodec`, SurfaceFlinger, Chrome) and battery sysfs once per second. Planned: 3 rounds ×
   3 presenters × 60 s (`scripts/measure-all.sh 3 60`). **Only 20 s trials ran before the phone disconnected.**
4. **Display-link diagnostics (in-app telemetry only).** `--synthetic` runs comparing `preferredFrameLatency` 1 vs 2,
   `preferredFrameRateRange` 60/60/60, 120/120/120, 30–120 (pref 60), and immediate pacing, recording
   `CAMetalDisplayLink.Update.targetPresentationTimestamp` and `CAMetalDrawable.presentedTime`.

**Physical steps that needed a person:** unlocking the phone (it has a secure keyguard; it was unlocked by someone
at ~23:15); reconnecting USB (not done — the phone disappeared from USB at ~23:25 and had not returned at 23:41).

**Known sources of error.** Loopback: ± 0.05 ms systematic (tick rounding; same clock), plus ScreenCaptureKit's
vsync quantisation (a frame the capture skips shows up one capture interval late); 95 % bootstrap CIs per percentile
in the tables. Software mode with the phone: the clock-sync bound the harness states (± 2.31 ms in the trial) and,
by construction, phone **render → glass** included and Mac **composite → glass** excluded, so it is **not
glass-to-glass** ([S1](s01-latency-harness.md)). Presenter-stage telemetry (`presentedTime`) is the app's own.
Occlusion of the mirror window (a person using the Mac) drops presents; runs where it happened are marked.

## Raw numbers

Raw data: [`spikes/s02-mac-video/results/`](../../spikes/s02-mac-video/results/) — `loopback/` (harness summaries,
capture metadata, gzipped per-frame and per-sample CSVs, mirror statistics, `top` samples), `cpu/`,
`phone-trial/`, `displaylink-diagnostics/`. Tables generated with `python3 -I scripts/summarize.py <run dirs>`.

### Loopback: Mac half of the pipeline, harness-measured (1080 × 2400, 60 fps, 1.87 Mb/s)

| Run | Presenter | n | decoded | p50 [95 % CI] ms | p95 [CI] ms | p99 ms | min–max | recv → decoded p50 / p95 | recv → presented p50 / p95 (app) | Load avg |
|---|---|---|---|---|---|---|---|---|---|---|
| 233019 | Metal, `CAMetalDisplayLink` | 1761 | 100.0 % | **48.39** [46.19, 48.55] | **54.04** [53.94, 54.16] | 54.55 | 42.5–64.2 | 1.31 / 1.99 | 46.09 / 50.94 | 5.19 |
| 233221 | Metal, `CAMetalDisplayLink` | 1582 | 87.7 % | **48.12** [48.09, 48.15] | **52.35** [52.27, 52.57] | 56.56 | 42.6–65.6 | 1.31 / 2.02 | 47.35 / 50.64 | 4.79 |
| 233102 | AVSampleBufferDisplayLayer | 1758 | 96.8 % | **22.57** [22.37, 22.92] | **29.03** [28.92, 29.20] | 29.67 | 14.9–34.8 | 1.32 / 1.96 | – (no presented callback) | 4.68 |
| 233310 | AVSampleBufferDisplayLayer | 1670 | 90.2 % | **23.12** [22.80, 23.44] | **26.98** [26.81, 27.10] | 29.90 | 13.8–38.1 | 1.34 / 2.01 | – | 5.39 |
| 233139 | Metal, immediate (no display link) | 1790 | 100.0 % | **24.60** [24.53, 24.66] | **30.72** [30.31, 30.97] | 33.28 | 15.6–36.2 | 1.34 / 2.01 | 23.45 / 26.89 | 4.85 |
| 233354 | Metal, immediate (no display link) | 1799 | 100.0 % | **24.64** [24.46, 24.96] | **29.98** [29.78, 30.18] | 32.55 | 16.1–38.3 | 1.40 / 2.23 | 22.79 / 27.02 | 5.11 |

Systematic uncertainty ± 0.05 ms for every row (same clock). Run names are `20261101-HHMMSS-loopback-<presenter>`.
Samples are first appearances; every run has ≥ 1 582 samples and 0 negative samples. The app's own
receive → `presentedTime` agrees with the harness to within the 1–2 ms of Mac-side encode the harness also counts,
which cross-checks `presentedTime` against ScreenCaptureKit's display time.

### Why the display link costs ~24 ms (in-app telemetry, synthetic source)

| Diagnostic | display-link callback → `targetPresentationTimestamp` | receive → `presentedTime` p50 |
|---|---|---|
| `preferredFrameLatency` 1, range 60–120 (pref 120) | **41.6 ms** (constant, n 271) | 44.6 ms |
| `preferredFrameLatency` 2, same range | 41.6 ms | 49.1 ms |
| range 120/120/120 | 41.6 ms | 47.9 ms |
| range 60/60/60 | 49.9 ms | 56.2 ms |
| range 30–120, pref 60 | 49.9 ms | 65.3 ms |
| immediate pacing (no display link) | — | 22.7 ms |

`targetTimestamp` (the render deadline) is one refresh after the callback, and `targetPresentationTimestamp` is a
further **33.3 ms** later at every setting. `presentedTime` equals `targetPresentationTimestamp` within 0.02 ms for
≥ 95 % of frames (a few outliers between −25 ms and +17 ms), i.e. the system presents exactly when it said. The
callback fires ~120 times a second when the window is visible. `preferredFrameLatency` reads back as 1.0 but does
not change the target. Data: [`results/displaylink-diagnostics/`](../../spikes/s02-mac-video/results/displaylink-diagnostics/).

### CPU and energy impact, Mac (1080 × 2400 @ 60 fps synthetic stream, 60 s, no capture running)

| Run | Presenter | `s02-mirror` %CPU / energy impact | app `getrusage` | WindowServer %CPU / EI | synthetic source (not part of the client) | Notes |
|---|---|---|---|---|---|---|
| 233508 | none (baseline) | — | — | 20.1 / 21.0 | — | load 4.77 |
| 233636 | Metal, `CAMetalDisplayLink` | **5.5 / 5.6** | 5.7 % | 43.9 / 45.2 | 15.2 / 15.4 | 3 699 of 3 762 presented; window briefly occluded once |
| 233750 | AVSampleBufferDisplayLayer | **3.1 / 3.2** | 3.2 % | 46.6 / 47.9 | 16.9 / 17.1 | window briefly occluded once |
| 233902 | Metal, immediate | **5.9 / 6.0** | 6.0 % | 39.3 / 40.6 | 14.3 / 14.4 | window occluded ~13 s (775 presents dropped) → slightly low |

%CPU is of one core. WindowServer composites everything on the screen (other apps were active), so its numbers are
indicative only: ≈ +20–27 % of a core over the no-mirror baseline. The adb server does not take part in loopback runs;
in the phone trial it used **0.9 %** of a core (below).

### Phone runs

| Run | Condition | n | p50 | p95 | p99 | Notes |
|---|---|---|---|---|---|---|
| 23:11 smoke run | metal, phone home screen, 8 s | — | — | — | — | first live session: `streaming from "motorola edge 50 pro"`, video 1078 × 2400, decoded without errors. Not a latency run |
| trial A, 23:16 | metal, 20 s | 0 | — | — | — | the page never synced (Chrome cold start swallowed the intent); script fixed (wait for the page, re-send once). No data |
| trial B, 23:17 | metal, 20 s | 111 | 148.50 | 150.59 | 154.57 | **invalid**: 8.47 % of 1 487 captured frames decoded, all within 0.9–2.8 s of the capture; then the mirror window showed no symbol. Raw data not kept (deleted with the trial directory); numbers from the harness output. Cause not established; see trial B note |
| trial C, 23:25 ([data](../../spikes/s02-mac-video/results/phone-trial/20261101-232509-metal/summary.txt)) | metal (display link), 20 s planned | **218** | **95.98** [95.38, 96.48] | **101.31** [100.87, 104.08] | 108.38 [101.50, 116.74] | **partial, below the 300-sample minimum**: 43.0 % of 714 frames decoded. Systematic ± 2.31 ms (clock sync ± 2.10, best RTT 2.1 ms). The mirror's display link stopped calling back after ~11 s (484 presented, then 575 frames superseded while decoding continued); the USB link then dropped (`adb shell exited with status 255`) and the phone vanished from USB |

Trial C, Mac-side telemetry: 58.6 fps received, 1.22 Mb/s, receive → decoded p50 1.00 / p95 2.12 ms,
receive → presented p50 47.33 / p95 50.99 ms, arrival-minus-PTS jitter p95 24.3 ms (capture → encode → USB spread),
0 decode errors. Mac CPU: `s02-mirror` 2.8 % (lower than loopback because presenting stopped at ~11 s), adb server
0.9 %, WindowServer 22.0 %. **Phone CPU** (% of one core; the phone has 8): scrcpy server 14.8 %, encoder HAL
(`media.hwcodec`, `vendor.qti.media.c2`) 35.5 %, SurfaceFlinger 35.6 %, Chrome (page + GPU process) 83.4 %, 13
one-second samples. Phone **energy**: not obtainable — the phone was on AC; battery sysfs shows a net −1.56 W
battery flow (driver sign convention, charging), which the charger regulates and which does not measure the device's
draw. Phone battery 70 %, charging, 32.0 °C before the run.

Trial B note: the 148 ms p50 is far above trial C's 96 ms with the same presenter, and the decode stopped after
2.8 s. A later diagnostic capture (images inspected, then deleted — they showed the phone's own content) found the
phone on its **Recents** screen mid-capture, and adb's transport id went from 17 to 27 over the session (repeated
USB re-enumeration). The phone was being handled while the trials ran, so neither B nor C is acceptance evidence.

## Verdict

| # | Criterion (as written in the plan) | Verdict | Evidence |
|---|---|---|---|
| 1 | §0.C / P0-15: p50 ≤ 60 ms / p95 ≤ 90 ms on USB at 1080p60 H.264, measured with the S1 harness (software-timestamp mode, no camera) | **blocked — needs the phone back on USB, unlocked and left alone for ~15 min** (and a 240 fps camera for the optical number) | Only trial C has phone data: metal/`CAMetalDisplayLink` p50 95.98 / p95 101.31 ms ± 2.31, n 218 < 300, run broken by a presenter stall and a USB disconnect. Indicative, not a verdict: with the display link the Mac half alone is p50 48 ms (loopback), so this presenter is unlikely to meet p50 ≤ 60 ms; the other two presenters save ~24 ms |
| 2 | Pushes and launches a **pinned** scrcpy-server via `adb`, receives H.264 through an adb tunnel, decodes with VideoToolbox, presents with Metal on `CAMetalDisplayLink` | **pass** | 23:11 and 23:14 live runs: `streaming from "motorola edge 50 pro" (… usb)`, `video 1078x2400`; trial C 1 072 frames decoded, 0 errors. SHA-256 checked by `fetch-server.sh` (`verified SHA-256 764eb6f7…`) and before every push |
| 3 | `AVSampleBufferDisplayLayer` presenter variant, selectable by a flag; both presenters measured | **pass — Mac half only**; phone path **blocked** (as #1) | `--presenter sbdl`. Loopback (harness): AVSBDL p50 22.57 / 23.12 ms, p95 29.03 / 26.98 ms vs display link 48.39 / 48.12, 54.04 / 52.35 ms |
| 4 | CPU and energy impact recorded, Mac side | **pass** (synthetic 1080 × 2400 @ 60 stream) | `s02-mirror`: display link 5.5 % / EI 5.6, AVSBDL 3.1 % / 3.2, immediate 5.9 % / 6.0; adb server 0.9 % (phone trial); WindowServer indicative |
| 5 | CPU and energy impact recorded, phone side where obtainable | **blocked — needs the phone** for a full run (partial data recorded) | trial C (13 s): scrcpy server 14.8 %, encoder HAL 35.5 %, SurfaceFlinger 35.6 % of one core; energy not obtainable on a charger |
| 6 | Execution notes: an importable library target for P0-16 | **pass** | `MirrorCore` library product; `loopback/Package.swift` imports it by path from another package and builds (`swift build -c release`: `Build complete!`). Public API in the [README](../../spikes/s02-mac-video/README.md#the-library-for-p0-16) |
| 7 | Result document following the template, pass/fail per criterion with evidence | **pass** | this document |
| 8 | One-command run script with exact usage | **pass** | `spikes/s02-mac-video/run.sh` (used for the 23:11 live run) |

**Coverage:** Motorola edge 50 pro / Android 16 only. Not covered: any other phone or Android version (Pixel,
Samsung, Xiaomi, Android 10–12 and 17: **blocked — needs hardware**); optical glass-to-glass (**blocked — needs a
240 fps camera**); Wi-Fi; HEVC/AV1; the phone at 90–144 Hz; macOS 14–26; the Mac on AC power; an external display.

### Unit-test run

`cd spikes/s02-mac-video && swift test`, run once after the last code change (`c70d5ca`). Output trimmed to the
result lines, per-test timings removed. The build printed the harmless Command-Line-Tools linker warnings
`ld: warning: search path '/Library/Developer/CommandLineTools/Developer/…' not found`, as in S1.

```
✔ Suite ServerArguments passed      (defaultsMatchScrcpyConventions, nonDefaultValuesAreEmitted, scidIs31Bit,
                                     shellMetacharactersAreRejected(_:) with 11 test cases)
✔ Suite StreamFraming passed        (sessionHeaderLayout, packetHeaderLayout, demuxesAWholeStream,
                                     disabledAndErrorCodecsThrow, truncatedPacketEndsTheStream,
                                     zeroAndHugePacketSizesAreProtocolErrors, deviceNameIsNulPaddedAndTruncatedOnACodePoint)
✔ Suite AnnexB passed               (splitsThreeAndFourByteStartCodes, emulationPreventionBytesStayInside,
                                     avccLengthPrefixes, assemblerStripsParameterSetsAndWaitsForThem)
✔ Suite ControlMessages passed      (injectKeycode, injectTextIsTruncatedTo300BytesOnACodePoint, injectTouch,
                                     injectScrollNormalisesBy16, clipboardAndPower, uhidMessages,
                                     singleByteMessagesAndTypeOrder, deviceMessagesParseIncrementally)
✔ Suite Geometry passed             (aspectFitLetterboxes, viewPointToDevicePixels)
✔ Suite ADBParsing passed           (devicesList)
✔ Suite Pipeline passed             (syntheticEncoderEmitsConfigThenAnnexBKeyFrame,
                                     assemblerBuildsAFormatDescriptionFromRealParameterSets,
                                     decoderOutputsMetalCompatibleNV12, sessionOverLoopbackDecodesEveryFrameAndCarriesControl,
                                     stopDuringStreamingReportsNoError, connectGivesUpWhenNothingListens)
loopback 1080x2400 decode: receive→decoded n=120 p50=1.55 p95=2.11 p99=3.37 (min 1.30 max 7.17 mean 1.66)
✔ Test run with 32 tests in 7 suites passed after 3.692 seconds.
```

The first run of this suite (before the first commit) failed 3 expectations, which were real bugs, fixed in
`280416c`: a bare `\n` passed the shell-metacharacter check (`"\r\n"` in a Swift `Set<Character>` is one grapheme),
and `devicePoint` rejected points on the top and right edges of the video (`CGRect.contains` is half-open).

## Consequences for the plan

- **Presenter choice (architecture §3.1/§3.2, "VideoToolbox → CAMetalLayer … draw on next CAMetalDisplayLink
  tick").** On macOS 27.0.1, `CAMetalDisplayLink` in a normal window schedules presentation a fixed 33 ms (≈ 4
  ProMotion refreshes) after its render deadline, whatever `preferredFrameLatency` and the frame-rate range are.
  That makes it ~24 ms slower than presenting on decode, with no CPU benefit. **Recommendation: AVSampleBufferDisplayLayer
  as the default mirror presenter** — lowest latency measured (p50 ≈ 23 ms Mac half), lowest CPU (3.1 % of a core),
  and the least code; keep Metal with present-on-decode as the alternative (needed anyway for per-app windows /
  IOSurface sharing in S13, overlays, and colour control), and keep the renderer toggle. This is the plan's own
  fallback ("try `AVSampleBufferDisplayLayer` renderer"), triggered by the presenter comparison rather than by a
  measured end-to-end fail. Open: whether the display-link delay is a macOS 27 behaviour, depends on window state
  (key/front app, full screen, direct-to-display), or would differ on macOS 14–26.
- **Estimate for the phone path (unverified projection).** Trial C suggests ~49 ms from the page's frame to the
  Mac socket (96 ms total minus 47 ms Mac-side receive → presented), which includes the phone's own render → glass
  time. With AVSBDL the software-mode p50 would then be around 72 ms; glass-to-glass removes the phone render →
  glass delay (1–2 frames at 60 Hz) and adds the Mac panel (~1 frame at 120 Hz). Whether p50 ≤ 60 ms holds is
  exactly what the blocked runs must show; if it doesn't, the next levers are phone-side (encoder options such as
  `video_codec_options` / `latency=0`, a 120 Hz phone refresh, bit rate), not the Mac decoder (≈ 1–2 ms).
- **Phone queue.** P0-15's phone runs are still owed (≈ 15 min, scripted), then P0-04's validation can reuse the same
  setup. The USB link to this phone was unstable (repeated re-enumeration, then gone): use a different cable or port
  and keep the phone untouched during runs.
- **P0-16** can start on `MirrorCore` now: session, presenters, the control socket and every control/UHID message
  codec are in place and unit-tested; the coordinate mapping helper is `MirrorGeometry.devicePoint`.
- Follow-ups (owner: P0-15, before P0-18): run `scripts/measure-all.sh 3 60` (3 × 3 presenters); add the phone
  numbers here; then decide #1. Optional: measure `max_size 1920` (864 × 1920) and an encoder `latency=0` option.

### Phone state left behind

No phone setting was changed (`stay_on_while_plugged_in` stayed 0, `screen_off_timeout` 120 000 ms, refresh
settings untouched; `--stay-awake` was never used). During the session the agent: woke the screen once
(`KEYCODE_WAKEUP`), opened `http://localhost:8765/?title=s02` in Chrome (a Chrome tab showing the latency page may
still be open), sent taps on that page (`input tap`), pushed `/data/local/tmp/scrcpy-server.jar` (scrcpy's own path),
and set/removed `adb reverse tcp:8765` and per-session `adb forward`s. One UI-hierarchy dump was written to
`/data/local/tmp` to read Chrome's URL bar and deleted at once. Screen images were captured twice during diagnosis:
one phone screenshot, decoded by the harness without being viewed, and four mirror-window images from a
`--save-failures 3` capture, one of which was viewed (it showed the phone's Recents screen). All were deleted; none
is in the repository.
