# s02-mac-video — S2 Mac video pipeline (P0-15)

Throwaway spike code ([rules](../README.md)). It answers: can a native Mac client show an Android phone's screen at
1080p60 H.264 over USB within p50 ≤ 60 ms / p95 ≤ 90 ms, and which presenter should the product use? Results:
[`docs/spikes/s02-mac-video.md`](../../docs/spikes/s02-mac-video.md).

```
phone: scrcpy-server 5.0.1 (pinned) ── adb forward (USB) ──▶ Mac: s02-mirror
  MediaCodec H.264, max_size 2400, 60 fps        TCPSocket → StreamDemuxer → H264AccessUnitAssembler
                                                 → VideoDecoder (VTDecompressionSession, NV12 IOSurface)
                                                 → MetalPresenterView (CAMetalDisplayLink | immediate)
                                                   or SampleBufferPresenterView (AVSampleBufferDisplayLayer)
```

## Run the mirror

Needs: Apple silicon Mac, macOS 14+, Command Line Tools with Swift 6 (no Xcode), the Android SDK `adb`
(`~/Library/Android/sdk/platform-tools/adb`, or set `ADB`), a phone with USB debugging authorised, **unlocked**.

```sh
spikes/s02-mac-video/run.sh                      # Metal on CAMetalDisplayLink, 1080×2400 (max_size 2400), 60 fps, 8 Mb/s
spikes/s02-mac-video/run.sh --presenter sbdl     # AVSampleBufferDisplayLayer presenter
spikes/s02-mac-video/run.sh --presenter metal --metal-pacing immediate   # Metal, drawn on decode (no display link)
spikes/s02-mac-video/run.sh --serial <serial>      # pick a device when several are connected
spikes/s02-mac-video/run.sh --help               # all options
```

`run.sh` downloads the pinned server once (below), builds `s02-mirror` in release mode and opens one window.
Quit with ⌘Q, by closing the window, or Ctrl-C. Every 5 s it prints Mac-side statistics to the terminal (fps,
Mb/s, receive → decoded / presented). It needs no macOS permission prompt. While it runs, Android shows its usual
"USB debugging connected" notification; the server restores the phone when the session ends (scrcpy's cleanup
process). Phone settings are not changed (`--stay-awake` is the only option that touches one, for the session).

Without a phone: `--synthetic 1080x2400` streams a VideoToolbox-encoded test pattern through a local fake server.

**Over Wi-Fi (developers only).** `scripts/pair-wireless.sh` pairs with the phone's Wireless debugging by a QR code
(adb's QR scheme) and prints the adb serial; then `ANDROID_SERIAL=<serial> spikes/s02-mac-video/run.sh`. This is a
convenience for running the spike without a cable, not the product path: customers will not need Developer options
(the first release is Standard mode, decided 2026-11-01). Status: the QR generator round-trips (decoded back to the
input string); pairing with a phone has not been run end to end yet.

## The pinned server

`scripts/fetch-server.sh` downloads `scrcpy-server-v5.0.1` from the official
[Genymobile/scrcpy v5.0.1 release](https://github.com/Genymobile/scrcpy/releases/tag/v5.0.1) into
`~/Library/Caches/tombolo-s02/scrcpy-server-v5.0.1/` (override with `S02_SERVER_DIR`) and checks its SHA-256
against the pinned value `764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536` (from the release's
`SHA256SUMS.txt`). `MirrorSession` checks the hash again before every push. The binary is Apache-2.0 and is never
committed. It is pushed to `/data/local/tmp/scrcpy-server.jar`, as scrcpy does.

## The library (for P0-16)

`MirrorCore` is a SwiftPM library product. Depend on it by path, without modifying it:

```swift
// Package.swift of the consumer (e.g. spikes/s09-keyboard)
.package(path: "../s02-mac-video"),
.target(name: "…", dependencies: [.product(name: "MirrorCore", package: "s02-mac-video")])
```

```swift
import MirrorCore

var server = ServerOptions()               // max_size 2400, max_fps 60, 8 Mb/s, audio off, control on
server.stayAwake = false
let session = MirrorSession(configuration: .init(serverPath: path, server: server))
let view = try PresenterKind.metal.makeView()      // NSView & FramePresenter (open classes: subclass for input)
session.presenter = view
session.onFrame = { frame in /* DecodedFrame: CVPixelBuffer + pts + host-time stamps (decoder thread) */ }
session.onVideoSession = { info in /* video size; changes on rotation */ }
session.onEnded = { error in /* nil after stop() */ }
try session.start()                        // blocking (or start(completion:)); call off the main thread
try session.control?.send(.injectText("hello"))
try session.control?.send(.uhidCreate(id: 1, vendorId: 0, productId: 0, name: "kbd", reportDescriptor: desc))
session.control?.onDeviceMessage = { msg in /* .clipboard, .ackClipboard, .uhidOutput */ }
let p = MirrorGeometry.devicePoint(click, viewBounds: view.bounds, videoSize: size)   // view → device pixels
session.stop()
```

| API | What |
|---|---|
| `MirrorSession` | start/stop, `deviceName`, `device`, `videoSession`, `control`, `presenter`, `stats`, callbacks `onFrame` / `onPacket` / `onVideoSession` / `onServerOutput` / `onEnded`; `Configuration.existingTunnelPort` skips adb |
| `ControlChannel` | the control socket: `send(_ ControlMessage)`, `send(raw:)`, `fileDescriptor`, `onDeviceMessage` |
| `ControlMessage` / `DeviceMessage` | every scrcpy 5.0.1 control message type (keycode, text, touch, scroll, clipboard, display power, UHID create/input/destroy, start app, reset video, …) and the three device messages |
| `ServerOptions`, `ScrcpyServerPin` | server arguments (validated against shell metacharacters), pinned version / hash / paths |
| `MetalPresenterView`, `SampleBufferPresenterView`, `PresenterKind`, `FramePresenter` | presenters; `MirrorGeometry` for aspect-fit and coordinate mapping |
| `StreamDemuxer`, `ScrcpyFraming`, `H264`, `H264AccessUnitAssembler`, `VideoDecoder` | the pipeline stages, usable on their own |
| `SyntheticScrcpyServer`, `SyntheticH264Encoder` | phone-less stand-in speaking the same protocol |

## Measure

```sh
cd spikes/s02-mac-video
swift test                                  # 32 tests: wire formats, Annex-B, decoder, loopback session
scripts/measure.sh metal 60                 # one 60 s S1-harness run (software-timestamp mode) with the phone
scripts/measure-all.sh 3 60                 # 3 rounds × {metal, sbdl, metal-immediate}, interleaved, then Home
scripts/loopback.sh metal 30                # phone-less: the Mac half only (see below)
```

`measure.sh` needs the S1 harness in `tools/latency-harness/` (this branch merges `p0/04-latency-harness`) and the
**Screen Recording** permission for the app running it (System Settings › Privacy & Security › Screen & System
Audio Recording). Per run it: records conditions (Mac load average, thermal state; phone battery level, charging,
temperature, refresh mode); sets `adb reverse tcp:8765`; starts the harness page server; opens the page in Chrome on
the phone (one reused tab) and taps it once (fullscreen + screen wake lock); starts `s02-mirror` floating at a fixed
position; samples Mac CPU / energy impact (`top`: the mirror, the adb server, WindowServer) and phone CPU (`top`:
scrcpy server, encoder HAL, SurfaceFlinger, Chrome) plus battery sysfs; captures the mirror window with the harness
for the given duration; analyses; stops everything. Output in `runs/<time>-<presenter>/` (git-ignored). It saves no
screen images.

`loopback.sh` replaces the phone with `loopback/s02-loopback-source` (a separate package, so `MirrorCore` does not
depend on the harness): it stamps the **Mac** clock as a TLC1 symbol into 1080×2400 @ 60 fps frames, encodes them
with VideoToolbox and serves them like scrcpy-server on 127.0.0.1; `s02-mirror --port` displays them in its own
process. The harness then measures render → encode → TCP → decode → present → composite on one clock (no sync).

### Physical steps that need a person

1. Plug the phone into the Mac with a cable that stays put (a USB disconnect ends the session: `adb shell exited
   with status 255`), accept the USB-debugging prompt once.
2. **Unlock the phone** before each measurement series (`measure.sh` exits with status 3 if the keyguard shows).
3. Don't use the phone during a run: anything on top of the page (Recents, a notification shade) breaks decoding.
4. Grant Screen Recording to the terminal app once (the harness `capture` asks).

## Layout

| Path | What |
|---|---|
| `Sources/MirrorCore/` | the library (adb, server options, socket, demux, H.264, decoder, presenters, control, session, stats, synthetic source) |
| `Sources/s02-mirror/` | the AppKit executable |
| `Tests/MirrorCoreTests/` | swift-testing suite |
| `loopback/` | phone-less clock-stamping source (depends on `tools/latency-harness` LatencyCore) |
| `scripts/` | `fetch-server.sh`, `measure.sh`, `measure-all.sh`, `loopback.sh`, `pair-wireless.sh` + `qr.swift` (Wi-Fi pairing for developers) |
| `results/` | committed raw results referenced by the spike document |

Licence: GPL-3.0-or-later. scrcpy-server (downloaded, not included) is Apache-2.0 © Genymobile and Romain Vimont.
