# latency-harness — S1 latency measurement

Measures how long a phone frame takes to appear on the Mac, as p50 / p95 / p99 with a stated uncertainty. It
works with any mirror window (the Tombolo S2 prototype, scrcpy, …). Results go in
[`docs/spikes/s01-latency-harness.md`](../../docs/spikes/s01-latency-harness.md).

| Mode | Needs | Measures | Status |
|---|---|---|---|
| **Software timestamp** | phone + Mac, no camera | phone **render** (browser frame start) → Mac **composited display** (ScreenCaptureKit display time) | built, self-tested on the Mac; phone validation pending |
| **Optical** | a camera filming at ≥ 240 fps | phone **glass** → Mac **glass**, ± one camera frame | built, tested on synthetic video; camera validation pending |

**What the software mode includes and leaves out compared with true glass-to-glass.** It includes the phone
browser's own pipeline (frame start → raster → composite → the phone display, typically 1–3 phone frames), the
whole mirror pipeline (capture, encode, transport, decode, present) and the Mac WindowServer composite. It
leaves out the Mac display's scan-out and pixel response. It also includes, rather than separates out, the phone's
render-to-glass delay, so it is an *upper-bound-ish* proxy and not the optical number. Acceptance numbers for
S2 come from optical mode once a camera is available ([implementation plan](../../docs/implementation-plan.md#0c-spikes-each-produces-a-short-write-up-in-docsspikes),
[protocol §4](../../docs/protocol.md#4-media-framing-video-streams)).

## How it works

```
 phone browser                          Mac
┌──────────────────────┐  GET /time  ┌──────────────────────────────┐
│ web/page.js          │◀──────────▶│ server/serve.py (Python 3)   │  clock: CLOCK_UPTIME_RAW
│  every frame: draw   │  POST /log  │  → runs/X/sync.jsonl         │  (= mach_absolute_time)
│  rAF time as a TLC1  │────────────▶│                              │
│  symbol + counter    │             │ latency-harness capture      │  ScreenCaptureKit display time
└─────────┬────────────┘             │  decodes every frame of the  │  (same clock)
          │ mirrored by the app      │  mirror window → frames.csv  │
          └─────────────────────────▶│ latency-harness analyze      │  → latency.csv, summary.*
                                     └──────────────────────────────┘
```

- **TLC1 symbol** (`Sources/LatencyCore/CodeLayout.swift`, `web/code.js`): 32 × 16 modules. It has four QR-style
  finder squares and 64 data cells (2 × 2 modules each) that carry kind (4 bits), session tag (4 bits) and time
  in 100 µs ticks (32 bits), protected by CRC-24. The decoder handles scale, rotation, perspective, mirror images,
  blur, noise and JPEG/H.264 artefacts. A torn or mid-transition frame fails the CRC: it is reported as "no
  decode" and never as a wrong value. The page draws the *requestAnimationFrame timestamp* of each frame.
- **Clock sync** (`ClockSync.swift`): Cristian/NTP-style round trips every 250 ms (after a 64-trip burst). For
  each 2 s window the analysis keeps the minimum-RTT exchange, then fits offset + drift through the lower-RTT
  half. The uncertainty it states is **± max RTT/2 of the exchanges used**, plus 2 standard errors of the drift
  over half the run. This holds for any asymmetry in the path.
- **Samples**: only the *first* captured frame showing each value counts. Later captures of the same value are
  "repeats": they measure how long a frame stayed on screen, not latency.

## Requirements

- macOS 14 or later, Apple silicon or Intel. Command Line Tools with Swift 6 (no Xcode needed). Python 3.
  ffmpeg/ffprobe for optical mode (`brew install ffmpeg`).
- **One-time: Screen Recording permission** for the app you run the commands from (Terminal, iTerm, …):
  System Settings › Privacy & Security › **Screen & System Audio Recording** › enable the app, then quit and reopen
  it. The first `capture` asks for it if it is missing. Without it the window list is empty.

## Build and test

```sh
cd tools/latency-harness
swift build -c release            # binary: .build/release/latency-harness
swift test                        # encoder/decoder, JS⇄Swift parity, clock sync, statistics, analysis (~20 s)
scripts/optical-synthetic.sh      # optical pipeline end to end through ffmpeg/H.264 on a synthetic 240 fps clip
scripts/selftest.sh               # phone-less self-test (see below; opens windows for ~70 s)
```

## Phone-less self-test

```sh
scripts/selftest.sh [RUN_DIR] [DURATION_S=30]
```

**A — page.** The script starts the server and opens the page in a floating WebKit window
(`latency-harness page-window`), which plays the "mirror". It then captures that window and analyses it.
`BROWSER=chrome` (throwaway profile) or `BROWSER=safari` also work, but you must keep those windows in front.
This validates decoding, the clock-sync maths and the capture timestamps. The number it gives is the Mac
browser's own render → composite latency, **not** phone latency.
**B — Mac reference.** The script captures `latency-harness mac-code`, which shows the Mac clock. Both ends
use the same clock, so no sync is involved: this checks the capture timestamps independently.

Expect a decode rate close to 100 %, small spreads, and on the reference machine A ≈ 12 ms (WebKit page at 60 Hz,
120 Hz display) and B ≈ 17 ms (two 120 Hz refreshes). Keep the display awake (the script runs `caffeinate -d`). Leave the windows uncovered.

## Phone validation (software mode) — run this once the phone is back

Prerequisites: the mirror under test exists (P0-15's prototype in `spikes/s02-mac-video/`, or scrcpy for a
baseline), the phone is charged and on a cable, and USB debugging is authorised. Nothing else on the Mac is heavy.

1. **Phone settings (a person):** unlock; Developer options › *Stay awake* on (plugged in); battery saver off;
   note the display refresh setting (60 / 120 Hz / adaptive) and set it to a fixed rate if the phone allows.
2. **USB tunnel (Mac):** `adb reverse tcp:8765 tcp:8765` (the phone's `localhost:8765` → the Mac; it survives
   server restarts). Over Wi-Fi instead, add `--lan` to the server below and open the printed
   `http://<mac-ip>:8765/` on the phone. That page is not a secure context, so the phone's timer is coarser and
   the wake lock is unavailable.
3. **Mirror (Mac):** start the mirror and keep its window visible, unobstructed and on the current Space. Use at
   least ≈ 300 pt wide; the symbol needs ≥ 2 px per module. Find its window title:
   `.build/release/latency-harness list-windows`.
4. **Three runs of 60 s.** Each run gets its own directory, so the server restarts per run and the page is
   reloaded (a person taps reload, then taps the page once for fullscreen + keep screen on):
   ```sh
   cd tools/latency-harness && swift build -c release
   for i in 1 2 3; do
     RUN="$PWD/runs/phone-$(date +%Y%m%d-%H%M%S)-$i"
     python3 server/serve.py --run-dir "$RUN" & SERVER=$!
     echo "Phone: open/reload http://localhost:8765/ in Chrome, tap once, wait for 'sync: Mac−page … ±', then press Enter"; read -r _
     .build/release/latency-harness capture --run-dir "$RUN" --window "<mirror window title>" --duration 60
     sleep 3 && .build/release/latency-harness analyze --run-dir "$RUN"   # includes the last sync batch
     kill "$SERVER"
   done
   ```
5. Each 60 s run at 60 Hz gives ≈ 3 600 samples; the criterion needs ≥ 300 per result.
6. **Record** `summary.txt` per run in the spike doc: samples, decode rate, p50/p95/p99 with the bootstrap CIs and
   the systematic ±. Also record the phone model, Android build, refresh rate, the mirror's commit and settings
   (codec, resolution, bitrate), USB vs Wi-Fi, and Mac load. Copy the run directories (CSV gzipped) next to the
   spike doc's other results.

Checks: the decode rate should be > 95 % (otherwise use `--save-failures 5` to see why; this saves screen images).
`negative` samples should be 0, and the clock RTT should be small and stable. A
`no clock-sync samples for session tag` note means `sync.jsonl` is not in the run directory or the page was
reloaded after the server started a new run.

## Optical mode — run this once a high-speed camera is available

1. Put the phone (showing the page, as above) next to the Mac screen showing the mirror window. Open
   `.build/release/latency-harness mac-code` next to them; it stays on top on every Space.
2. Film all three for ≥ 10 s at 240 fps (or faster). Lock the exposure, avoid glare, and keep each symbol at
   ≥ 3 px per module in the video.
3. Analyse:
   ```sh
   .build/release/latency-harness optical --video clip.mov --out runs/optical-1 [--fps 240] [--use-mac-fps]
   ```
   The phone and mirror symbols are told apart automatically: the one showing newer values is the phone. If
   that fails, pass `--roi-phone X,Y,W,H --roi-mirror X,Y,W,H [--roi-mac …]` in video pixels.
   **Check `camera fps measured against the Mac clock`.** Slow-motion files often carry playback-rate metadata;
   if it differs from the nominal rate, re-run with `--use-mac-fps` (or `--fps <true rate>`).
4. Each sample is the number of camera frames between the value's first appearance on the phone glass and on the
   mirror: ± one camera frame (4.17 ms at 240 fps). If exactly one undecodable frame (a display mid-transition)
   precedes a first appearance, that frame counts as the appearance. Without this rule, a camera locked to a
   multiple of the display refresh would bias one side by a whole frame. Strict and uncorrected statistics are
   reported alongside.

## Commands

```
latency-harness list-windows [--all]
latency-harness capture --run-dir DIR (--window TEXT | --window-id N | --rect X,Y,W,H) [--duration S]
                        [--source display|window] [--scale F] [--expect N] [--save-failures N] [--no-analyze]
latency-harness analyze --run-dir DIR
latency-harness mac-code [--duration S] [--at X,Y] [--size W,H]
latency-harness page-window --url URL [--title T] [--duration S] [--at X,Y] [--size W,H]
latency-harness optical --video FILE [--fps N] [--scale F] [--out DIR] [--max-frames N] [--use-mac-fps] [--roi-… X,Y,W,H]
latency-harness decode-image FILE…  |  encode-image --out FILE …  |  synth-video …
```

`capture` defaults to `--source display`: the window's region of the composited display, which is closest to "on
screen". `--source window` captures the window's own buffer even when it is covered.

**Run directory:** `sync.jsonl` (raw round trips + page diagnostics, written by the server), `capture.json`,
`frames.csv` (one row per decoded symbol per captured frame: display/arrival time, value, confidence),
`latency.csv` (one row per sample), `summary.json` / `summary.txt`.

**Privacy:** the server binds to 127.0.0.1 unless you pass `--lan`. It serves only the three page files and the
time, and accepts small JSON logs. `capture` saves screen images only with `--save-failures`.

## Layout

| Path | What |
|---|---|
| `Sources/LatencyCore/` | code layout, encoder/renderer, decoder, homography, clock sync, statistics, analysis, synthetic scenes |
| `Sources/latency-harness/` | CLI: ScreenCaptureKit capture, Mac reference window, WebKit page window, optical (ffmpeg) |
| `Tests/LatencyCoreTests/` | swift-testing suite (uses JavaScriptCore to check `web/code.js` against Swift) |
| `web/` | the page that gets mirrored |
| `server/serve.py` | page + clock server (standard library only) |
| `scripts/` | `selftest.sh`, `optical-synthetic.sh` |
| `results/` | committed raw results referenced by the spike doc |

Licence: GPL-3.0-or-later.
