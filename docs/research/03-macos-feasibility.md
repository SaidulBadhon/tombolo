# 03 — macOS-side technical feasibility and distribution

*Research date: 2026-10-25. Test machine: macOS 27.0.1 (build 26A434), arm64, Command Line Tools only (Swift 6.4), Homebrew 7.0.9.*

## How to read this report

Every claim carries one of three confidence labels:

- **Verified**: checked in this research, either by fetching the primary source (Apple doc JSON, Homebrew source or API, release notes, vendor docs) or by testing on the macOS 27.0.1 machine. The command or source is named.
- **Reported**: comes from a secondary or community source, such as a GitHub issue, forum post, blog or third-party docs. It is linked but I did not reproduce it.
- **Unverified**: inference or recall I could not confirm. Treat these as hypotheses to prototype.

Items 1–7 and 10 were researched by three parallel delegated passes, each citing its own sources. I spot-checked some of their claims; for example, Moonlight 6.2.0 matches the Homebrew API. Items 8, 9, 11 and 12 I researched directly.

The shared web-search quota ran out midway. Later checks therefore used direct fetches of known URLs plus local experiments, which is why a few items stay "unverified".

---

## Executive summary: the decisions that matter

1. **The core features are all technically feasible with public APIs and free signing.** That covers mirroring, control, per-app windows, notifications with reply, clipboard, drag-and-drop, audio, discovery and USB. No paid Apple account is needed to build or run them.
2. **Distribution is the real constraint, and it got stricter in 2025–2026.**
   - **Unsigned code cannot run at all on Apple silicon.** Verified on 27.0.1: an unsigned arm64 binary is SIGKILLed (exit 137). The minimum is an ad-hoc signature, which the Swift linker adds automatically.
   - **Ad-hoc-signed downloads fail Gatekeeper.** Verified on 27.0.1: `spctl` rejects them, `syspolicy_check distribution` reports "Adhoc Signed App" and "Notary Ticket Missing" (fatal), and `gktool scan` fails.
   - **Since macOS 15, the user must use System Settings › Privacy & Security › Open Anyway.** The Control-click override was removed in Sequoia (Apple, Aug 2024).
3. **Official Homebrew casks now require Developer ID + notarization.**
   - Homebrew 5.0.0 (12 Nov 2025) deprecated unsigned casks and the `--no-quarantine` flag.
   - **627 casks are now disabled** with reason `fails_gatekeeper_check`; 597 of them were disabled on 2026-09-01. Examples include `alacritty` and `qbittorrent`.
   - The flag is gone in 7.0.9.
   - The cask audit runs `gktool scan`, which effectively requires Developer ID + notarization.
   - **Third-party taps still work:**
     - They can strip quarantine. AeroSpace's tap does exactly this today, with `postflight_steps … run "/usr/bin/xattr" -d com.apple.quarantine`.
     - Since Homebrew 6.0, users must trust the tap. Installing a fully qualified `user/tap/cask` name trusts that one item.
4. **Every comparable FOSS Mac app I checked pays Apple.** Verified with `spctl -a -vv`: Moonlight, Rectangle, Stats, AltTab, Ice and LocalSend are all "Notarized Developer ID", signed in each maintainer's personal name.
   - Apple's fee waiver is only for registered nonprofits, accredited schools and government, never individuals.
   - SignPath's free OSS certificates are effectively a Windows path. Its macOS support needs your own Apple certificate.
5. **Ad-hoc signing breaks permission persistence.**
   - The designated requirement (DR) of an ad-hoc build is its `cdhash`. Verified locally, and Apple's TN3127 says so.
   - So every update loses Accessibility, Input Monitoring, Local Network, login-item and similar grants.
   - **Mitigation:** sign every build with one *stable* identity. A self-signed certificate or a free "Apple Development" certificate gives a certificate-based DR. That stability is an inference from TN3127; I did not test it.
6. **Things that need a paid account:**
   - The webcam (Camera Extension = system extension): needs a restricted entitlement and notarization.
   - Communication and Time-Sensitive notifications, and APNs.
   - Mac App Store distribution.
   - Developer ID/notarization, which is what removes the Gatekeeper friction.
7. **Changes in macOS 26 and 27 that affect this project:**
   - **macOS 27 is Apple-silicon-only** (Verified, apple.com/os/macos). The 27 release notes say **all Intel software stops working in macOS 28**.
   - macOS 27 adds `spctl --purge`, refuses to load quarantined launchd plists, and denies access to other teams' app containers by default.
   - **New in macOS 27:** the AccessoryAccess USB framework (entitlement "Claim USB Accessory"), `NSApplication` `.disableScreenCornerInteractions`, and VideoToolbox low-latency super-resolution at 1.5×.
   - The Network framework's default minimum TLS version became 1.2 for apps linked on macOS 26.
   - Wi-Fi Aware is **still not available on native macOS** (iOS/iPadOS 26 and Mac Catalyst docs only).
   - Moonlight hit macOS 26 frame-pacing regressions in Metal windowed mode.
   - TN3179 says Local Network privacy reset buttons come in macOS 27.2.
8. **Recommendations:**
   - Swift with AppKit for the mirror window, video and input; SwiftUI for the rest.
   - Minimum macOS 14, arm64-only.
   - No Mac App Store build for v1.
   - Distribute via your own Homebrew tap, a DMG, and a build-from-source script, and budget the $99/yr as soon as the project is real.

---

## 1. Video pipeline

**Feasible: yes, with high confidence.**

### Codecs
- **H.264 and HEVC** decode in hardware on all Apple silicon Macs (Reported/standard).
- **AV1 hardware decode exists only on M3, M4 and M5.** M1 and M2 have none.
  - Apple's spec pages list "AV1 decode" for M5 / M5 Pro / M5 Max (Reported).
  - There is **no VideoToolbox software fallback**. Session creation fails with `kVTCouldNotFindVideoDecoderErr` (Reported, Apple forums).
  - Gate it with `VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)` (macOS 10.13+).
  - For AV1 you must build the `av1C` atom yourself in `SampleDescriptionExtensionAtoms`. There is no AV1 counterpart to `CMVideoFormatDescriptionCreateFromHEVCParameterSets`.
  - Moonlight-qt added M3+ AV1 hardware decode in 6.2.0 (Oct 2026). Verified that 6.2.0 is the current cask version.
- **Codec recommendation:**
  - H.264 as the baseline. scrcpy says H.264 gives the lowest latency.
  - HEVC as an option.
  - AV1 only for an M3+ Mac paired with a phone that has an AV1 *encoder*, which is rare (Unverified).

### Decode settings
- Use `VTDecompressionSession` directly so you own the timing.
- Set `kVTDecompressionPropertyKey_RealTime = true` (10.10+). Require hardware via `kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder`.
- **Do not** set `kVTDecodeFrame_1xRealTimePlayback`. It is a low-power mode that won't decode faster than real time.
- Don't combine RealTime with `MaximizePowerEfficiency`.
- `kVTDecodeFrame_EnableAsynchronousDecompression` is optional. Synchronous decode on a dedicated thread is simpler.
- The phone encoder must emit **no B-frames or reordering**, otherwise the decoder holds frames.
- Output IOSurface-backed `420v`/`x420` buffers with `kCVPixelBufferMetalCompatibilityKey`.
- Measured decode time is about 1–4 ms per frame on M1/M2 (Reported, Moonlight users).

### Rendering
- **Option (a): `AVSampleBufferDisplayLayer`.** On macOS 14+ you enqueue through `.sampleBufferRenderer` (`AVSampleBufferVideoRenderer`).
  - Pros: least code; colour and HDR handled for you; power-efficient.
  - Con: opaque buffering. Moonlight saw roughly one extra frame of latency (issues #1249, #1885).
- **Option (b): `CAMetalLayer`** with zero-copy `CVMetalTextureCache`, a YUV→RGB shader, and **`CAMetalDisplayLink` (macOS 14+)** with `preferredFrameLatency = 1`.
  - This is Moonlight's `vt_metal.mm` design.
  - It gives cropping, rotation and per-app sub-rects for free.
- **Recommendation:** Metal as the primary path, with AVSBDL as a fallback behind one renderer protocol. **Ship a renderer toggle from day one.** Moonlight had macOS 26 windowed Metal regressions: frame-time spikes up to 100 ms and "Presentation wait timed out" (#1696). In 6.2.0 it added a user-selectable renderer.

### Frame pacing
- `CVDisplayLink` is deprecated in macOS 15.
- Use `NSView`/`NSWindow`/`NSScreen.displayLink(target:selector:)` or `CAMetalDisplayLink` (macOS 14+, Verified via Apple doc JSON), with `preferredFrameRateRange`.
- Use a "latest frame wins" policy and never queue frames.
- **ProMotion:** check `NSScreen.maximumFramesPerSecond` and request 120 Hz when the phone streams at 90 or 120 fps. A 60 fps stream on a 120 Hz panel paces unevenly.

### HDR
- Use `CAMetalLayer.wantsExtendedDynamicRangeContent` plus `CAEDRMetadata.hdr10` and the PQ colour space.
- On a plain `CALayer`, `wantsExtendedDynamicRangeContent` is deprecated in macOS 26 in favour of `preferredDynamicRange`.
- HDR is low priority: Android screen capture is SDR in practice (Unverified).

### macOS 26 and 27 extras
- `VTLowLatencySuperResolutionScalerConfiguration` and `VTLowLatencyFrameInterpolationConfiguration` (macOS 26; VTFrameProcessor itself is 15.4).
- In 27.0 these gained a 1.5× scale factor and arbitrary sizes up to 1080p (Verified, 27 release notes).
- They could upscale a low-bitrate phone stream. Device support is Unverified.

### Latency budget
- scrcpy claims 35–70 ms end to end.
- Mac-side cost is decode (1–4 ms) plus compositor and display (1–2 refreshes, 8–33 ms).
- Over Wi-Fi, AWDL (AirDrop) and Location Services cause periodic stutter. Moonlight's workaround is `ifconfig awdl0 down`.

### Native Swift prior art
- Moonlight-qt is C++/Qt + SDL + FFmpeg + VideoToolbox + Metal.
- Swift-native clients: `mehmetcansahin/glimmer`, `wiedymi/swift-moonlight`, `Eckobrew/moonlight-mac`. Maturity is Unverified.

**Sources:** Moonlight releases and issues #1249, #1696, #1885; `vt_metal.mm`; Apple doc JSON for `kVTDecompressionPropertyKey_RealTime`, `VTIsHardwareDecodeSupported`, `AVSampleBufferVideoRenderer`, `CAMetalDisplayLink.preferredFrameLatency`, `NSView.displayLink`, `CALayer.preferredDynamicRange`; macOS 27 release notes; apple.com/macbook-pro/specs. Full URLs are in the Sources section.

---

## 2. Input capture

**Feasible: yes, inside the window.** Capturing system shortcuts needs Accessibility or private API.

### Mouse → touch
- Map down/drag/up to a single pointer in video-rect coordinates, accounting for rotation. Forward hover.
- scrcpy defaults: right-click = Back, middle-click = Home; pinch/rotate via Ctrl+drag, tilt via Shift+drag.

### Trackpad gestures (NSEvent)
| NSEvent | Available since | Maps to |
|---|---|---|
| `.magnify` / `magnification` | 10.5 | Two synthetic pointers around the cursor (pinch) |
| `.rotate` | | Two-pointer rotate |
| `.smartMagnify` | 10.8 | Double-tap |
| `pressure` / `stage` | 10.10.3 | Long-press |
| Scroll with `phase` / `momentumPhase` | 10.7 | See below |

- For **precise trackpad scroll**, synthesize a one-finger drag and **drop momentum events**, so Android computes its own fling.
- For **wheel mice**, send `ACTION_SCROLL`.

### Raw multitouch
- `NSView.allowedTouchTypes = [.indirect]` (10.12.2) gives true N-finger touches.
- Positions are `normalizedPosition` in trackpad space, so this suits only an optional "trackpad as touchscreen" mode.
- Universal Control-forwarded touches have reportedly thrown on `normalizedPosition` (Reported).

### Keyboard
- `keyDown` / `flagsChanged` / `performKeyEquivalent` cover most keys.
- Cmd-Tab, Cmd-Space, Mission Control and screenshot shortcuts never reach the app. Options:
  1. `presentationOptions.disableProcessSwitching`. Public and needs no permission, but it requires `hideDock` / `autoHideDock`, which means a full-screen mode.
     - **macOS 27 adds `.disableScreenCornerInteractions`** to suppress Hot Corners (Verified, 27 release notes).
  2. A `CGEventTap`.
     - An active tap needs **Accessibility**; a listen-only tap needs **Input Monitoring** (`CGRequestListenEventAccess`, 10.15).
     - Cmd-Tab is consumed by WindowServer before any tap. AltTab and SDL therefore use private `CGSSetSymbolicHotKeyEnabled` / `CGSSetGlobalHotKeyOperatingMode`, which is not allowed on the Mac App Store.
     - Revoking Accessibility while an active tap runs can freeze input.
     - Secure Keyboard Entry blocks taps.
  3. **TCC grants are tied to the code signature.** Ad-hoc updates lose them; see item 8.
- **Keyboard recommendation:**
  - v1 is permission-free: toolbar buttons and menu shortcuts for Home / Back / Recents.
  - Add an opt-in "Capture system shortcuts" mode (Accessibility + event tap) that is active only while the mirror window is key.

### IME / non-Latin text
- Implement `NSTextInputClient` on the mirror view and route keys via `inputContext.handleEvent`.
- Draw marked (composing) text in a local overlay positioned by `firstRect(forCharacterRange:)`, and send the committed string on `insertText`.
- The phone side must accept arbitrary Unicode:
  - scrcpy's "sdk" keyboard is ASCII-only.
  - Use a companion Android IME (`commitText`), Accessibility `ACTION_SET_TEXT`, or a clipboard paste.
  - Keep a raw-HID mode (UHID/AOA) for games and shortcuts.

### Universal Control
- There is no public API to detect or disable it.
- It only matters in pointer-capture mode (`CGAssociateMouseAndMouseCursorPosition(false)`). Document "turn off Push through the edge".

**Sources:** scrcpy docs (mouse, keyboard, control); SDL `SDL_cocoakeyboard.m`; Apple doc JSON for `NSApplication.PresentationOptions` and `NSTextInputClient`; macOS 27 release notes (NSApplication); danielraffel.me on event taps and signing; `macos-trackpad-demo`.

---

## 3. Networking and discovery

**Feasible: yes.** Peer-to-peer Wi-Fi to Android is the one thing that isn't.

### Transport
- **APIs (Network.framework):**
  - `NWListener` / `NWConnection` (10.14+); `NWBrowser` for Bonjour (10.15+).
  - QUIC via `NWProtocolQUIC` with `NWMultiplexGroup` / `NWConnectionGroup` for multiplexed streams (macOS 12+). QUIC datagrams need macOS 13+.
  - New structured-concurrency `NetworkConnection` / `NetworkListener` / `NetworkBrowser` are **macOS 26+ only** (Verified, doc JSON; WWDC25 session 250). They come with a TLV framer and a `Codable` coder.
  - Multipeer Connectivity is deprecated as of Xcode 27. TN3213 points to Network framework (Reported).
- **Recommendation:**
  - Use the `NW*` APIs if the minimum target is below 26.
  - A TCP+TLS control channel; video and audio on separate TCP streams or QUIC.
  - **Android needs a third-party QUIC stack** (quiche or msquic). Interop with Apple QUIC is Unverified, so keep TCP as the baseline.

### Security
- **Use TLS 1.3 with self-signed certificates plus pinning, not PSK.**
  - Apple DTS has repeatedly said Network-framework TLS-PSK is TLS 1.2-only and that QUIC supports PKI only (forum threads 688508, 768961, 751839).
- **Pairing design:**
  - Each side generates an identity.
  - Pin the peer's certificate in `sec_protocol_options_set_verify_block` (10.14+).
  - Exchange fingerprints once via QR code or a short code.
- **macOS 26 change:** apps linked on 26 default to a minimum of TLS 1.2 in Network framework (Verified, 26 release notes).

### Local Network privacy (macOS 15+) — the main constraint

Sourced from TN3179, revised 2026-10-06.

- **Triggers:**
  - Outgoing TCP connects, UDP sends, multicast or broadcast receive, `.local` resolution.
  - Every Bonjour register, browse or resolve.
- **Does not trigger:** listening for and accepting incoming TCP.
  - A design where the **phone scans a QR code (Mac IP and port) and connects in** could avoid the prompt entirely. Bonjour advertising re-introduces it. For QUIC/UDP replies this is Unverified.
- **Info.plist keys:**
  - `NSLocalNetworkUsageDescription`
  - `NSBonjourServices`: our `_xxx._tcp`, plus `_adb-tls-connect._tcp` / `_adb-tls-pairing._tcp` if we browse for ADB.
  - No multicast entitlement is needed on macOS.
- **Exemptions:**
  - Exempt: launchd **daemons**, root processes, and CLI tools run from Terminal or SSH.
  - Not exempt: launchd **agents**.
  - A spawned helper such as a bundled `adb` is attributed to the app.
- **Signing matters:**
  - LNP tracks identity by code signature, and the main executable's Mach-O UUID must be unique.
  - **Unsigned bundles never get a prompt** and fail with `EHOSTUNREACH` (transgui PR #1614).
  - **Ad-hoc signed bundles do get the prompt** (reported working on 26.x).
  - Whether a grant survives an ad-hoc update is Unverified. It probably doesn't, given the cdhash DR.
- **Bugs and gaps:**
  - No prompt for very short-lived processes (FB16131937).
  - Confusion when multiple copies are installed (FB15568200).
  - A macOS 27 beta regression for child processes of GUI apps, mostly fixed in beta 5 (Ghostty #13438 / #13476).
  - No API to query or force the prompt. To detect denial, watch for `kDNSServiceErr_PolicyDenied` (-65570).
  - **Reset UI comes in macOS 27.2** per TN3179. Before that, there is no reset.

### CoreBluetooth
- Central (10.7+) and peripheral (10.9+) roles both work on macOS. Needs `NSBluetoothAlwaysUsageDescription`.
- As a peripheral the Mac can advertise only a local name and service UUIDs: about 28 bytes, best effort, no manufacturer data.
- Good for "phone nearby → connect" and presence.
- **It cannot wake a sleeping Mac.**

### Wi-Fi Aware
- **Not available to native macOS apps** as of macOS 27.0.1. Docs list iOS/iPadOS 26 and Mac Catalyst 26, and `supportedFeatures` returns empty where unsupported. DTS thread 787701 says iOS/iPadOS 26 only.
- A `nan0` interface appeared in macOS 27 betas, but Apple has made no commitment (thread 834091).
- iOS↔Android NAN interop has had issues (thread 801280).
- AWDL (`includePeerToPeer`) is Apple-to-Apple only.
- **Plan for infrastructure Wi-Fi plus USB. Treat Wi-Fi Aware as future work.**

**Sources:** TN3179; WWDC25-250; Apple doc JSON for `NetworkConnection`, `NWProtocolQUIC`, `NWMultiplexGroup`, WiFiAware; forum threads 663874, 688508, 715553, 751839, 768961, 787701, 801280, 818807, 834091; transgui PR #1614; Ghostty discussion #13438; macOS 26 release notes.

---

## 4. USB

**Feasible: yes, with no entitlement when unsandboxed.**

### Option A — bundle `adb`
- Google's prebuilt platform-tools are under the Android SDK License (dated Apr 28 2026).
  - §3.4 bans redistribution of the SDK.
  - §3.5 says open-source components are governed solely by their own license, and adb's source is Apache-2.0.
- scrcpy's macOS static release **does ship Google's prebuilt adb**. Verified by the delegated pass: it listed the tarball and read `app/deps/adb_macos.sh`, which downloads `platform-tools_r37.0.1-darwin.zip`. scrcpy's Homebrew docs instead depend on the `android-platform-tools` cask.
- Cleanest legal options: build adb from AOSP source and ship it with the Apache NOTICE, or depend on the Homebrew cask. The reading of §3.5 is Unverified (not legal advice).

### Option B — native ADB client (better long-term)
- The protocol is documented in AOSP `protocol.txt` and `adb_wifi.md` (TLS via `A_STLS`, SPAKE2 pairing, QR payload `WIFI:T:ADB;S:…;P:…;;`).
- mDNS service types: `_adb._tcp`, `_adb-tls-pairing._tcp`, `_adb-tls-connect._tcp`.
- Existing implementations:

| Project | Language | License | Notes |
|---|---|---|---|
| Tango / ya-webadb | TypeScript | MIT | Mature |
| `adb_client` | Rust | MIT | USB via libusb, plus mDNS |
| `rsadb` | Rust | | Uses `nusb`/IOKit, no libusb |
| DroidMux | Rust | | Claims SPAKE2 pairing |
| ADBKit | Swift | Apache-2.0 | Very early, TCP only |

- Maturity of the Rust and Swift projects is Unverified. Wrapping a Rust core in a Swift package (UniFFI) is the pragmatic path.
- **Gotcha:** only one host can claim the ADB interface. If an Android Studio adb server is running, fall back to talking to it on `:5037`.

### macOS USB access
- libusb or IOKit `IOUSBHost` (10.15+) can open the phone's vendor-specific ADB interface (0xFF/0x42/0x01) from an **unsandboxed** app with no entitlement, kext or DriverKit.
- Sandboxed apps need `com.apple.security.device.usb`.
- Apple-silicon laptops ask "Allow accessory to connect?" for new devices.
- libusb is LGPL-2.1: link it dynamically, or use `nusb`.
- **New in macOS 27: the `AccessoryAccess` framework** (`AAUSBAccessoryManager`, exclusive claim of USB accessories). Verified via doc JSON (macOS 27.0+).
  - Requires the `com.apple.developer.accessory-access.usb` entitlement, which Xcode lists as the "Claim USB Accessory" capability.
  - The manager presents UI and only works from Dock-visible apps. The 27 release notes record a fixed sandbox bug.
  - Whether the capability is free-tier is Unverified. It's not needed: libusb / IOUSBHost still work.

### AOA host
- **Yes.** scrcpy's OTG and `--keyboard=aoa` modes send AOA HID control requests (51–57) via `libusb_control_transfer` from macOS.
- That gives keyboard, mouse and gamepad injection **without USB debugging**, but no video.

**Sources:** developer.android.com/studio/terms; scrcpy `doc/macos.md`, `app/deps/adb_macos.sh`, `app/src/usb/aoa_hid.c`; AOSP `adb_wifi.md`; ya-webadb, adb_client, rsadb, DroidMux, ADBKit repos; Apple doc JSON for `IOUSBHost`, `com.apple.security.device.usb`, `accessoryaccess`, `aausbaccessorymanager`, `com.apple.developer.accessory-access.usb`; macOS 27 release notes (Accessory Access, Virtualization).

---

## 5. System integration

**Feasible: mostly yes, with free signing.** The paid-only exceptions are called out below.

Apple's macOS capability table, parsed by the delegated pass, lists only five capabilities in the free "Apple Developer" column: App Groups, App Sandbox, Hardened Runtime, Keychain Sharing and Maps. Everything else in this table that needs a capability needs a paid team.

| Feature | API (min macOS) | Free signing? | Approach and caveats |
|---|---|---|---|
| Mirrored notifications with reply | `UNUserNotificationCenter`, `UNTextInputNotificationAction` (10.14, Verified) | **Yes**: local notifications, no APNs | Our socket carries events; post them locally. The grant is reportedly keyed to bundle ID (Reported). Needs a real `.app`. **Communication Notifications (avatars) and Time-Sensitive need paid.** |
| Menu bar extra | `MenuBarExtra` (13, Verified); `NSStatusItem` | Yes | |
| Drag phone → Mac | `NSFilePromiseProvider` (10.12) | Yes | File promise, because bytes stream from the phone after the drop |
| Drag Mac → phone | `NSDraggingDestination` / `.dropDestination` | Yes | |
| Share extension | `com.apple.share-services` appex (must be sandboxed) | Probably | Ad-hoc pluginkit loading is Unverified; DTS warns ad-hoc "can cause all sorts of weird issues". Fallback: Services menu. |
| Services menu ("Send to phone") | `NSServices` + `servicesProvider` | Yes | No entitlement |
| Handoff-style "open on phone" | `NSUserActivity` | **No** | Needs the same iCloud account on Apple devices. Use App Intents, Services or a URL scheme instead. |
| Shortcuts / App Intents | AppIntents (13) | Yes, likely | macOS 26: intents appear as **Spotlight actions**. macOS 27: entity/intent schemas, View Annotations, AppIntentsTesting (Verified, WWDC26 macOS guide). Ad-hoc behaviour Unverified. |
| Spotlight | CoreSpotlight; App Intents entities; per-app shim bundles in `~/Applications` (indexed automatically) | Yes | macOS 26 itself lists iPhone apps in Spotlight, so that is the convention to match |
| Login item | `SMAppService.mainApp` (13, Verified) | Yes, with caveat | Registration is pinned to the code signature. After an ad-hoc update, launchd can refuse the new binary while `status` still reads `.enabled` (Reported). Re-`register()` on each launch. **macOS 27: launchd no longer loads quarantined plists** (Verified, release notes), so write any fallback LaunchAgent plist locally. |
| Per-mirrored-app Dock icons | One process = one Dock tile; `NSDockTile` only customises it | **Yes, via generated shim bundles** | See below |
| Stage Manager / window management | No public API; Stage Manager groups by app | Partial | Separate shim processes should appear as separate apps (Unverified) |

### Per-app Dock icons, Cmd-Tab entries and Spotlight entries

This copies Chrome's PWA app-shim pattern:

- Chrome generates tiny `.app` shims in `~/Applications/Chrome Apps/`, **ad-hoc signed locally**. The Chromium feature `kUseAdHocSigningForWebAppShims` is enabled by default.
- Because they are created locally, they are **never quarantined**, so Gatekeeper never assesses them.

For us:
1. Generate one shim per Android app, each with a unique bundle ID and an icon fetched from the phone.
2. Each shim runs a small viewer that owns its `NSWindow`.
3. Frames arrive from the main agent, either IOSurface over XPC or a local socket, or the shim opens its own stream.

Each Android app then gets its own Dock icon, Cmd-Tab entry, Stage Manager group and Spotlight entry, and optionally its own notification attribution. The cost is a permission prompt per shim for anything gated by TCC.

- Safari's "Add to Dock" web apps are executable-less bundles run by Apple's private runtime, so that pattern is not reusable.
- Android side: scrcpy 3.x `--new-display[=WxH/dpi] --start-app=<pkg>` plus `--flex-display` provides one app per virtual display.
- **macOS 27 caveat:** access to *other developer teams'* app containers is now denied by default (Verified, release notes: SIP section). Keep shim ↔ agent IPC in a location we own, not a container.

**Sources:** developer.apple.com/help/account/reference/supported-capabilities-macos; Apple doc JSON for `UNTextInputNotificationAction`, `MenuBarExtra`, `SMAppService`, AppIntents; WWDC25-260; WWDC26 macOS guide; Chromium `chrome_features.cc` and `app_shim/README.md`; developer.chrome.com notification-attribution post; scrcpy `virtual-display.md`; macOS 27 release notes.

---

## 6. Audio

**Feasible: yes.**

### Android source
- **Via an adb-shell server (scrcpy-style):** Android 11+. On Android 11 the screen must be unlocked when capture starts. `output` mutes the phone; Android 13+ adds `playback` with `--audio-dup`, which keeps the phone playing.
- **Without adb:** AudioPlaybackCapture (Android 10+) needs `RECORD_AUDIO` plus MediaProjection consent. It captures only MEDIA, GAME and UNKNOWN usages, apps can opt out, and **call audio is not capturable**.

### Codec
- Opus at 48 kHz / 128 kbps (the scrcpy default), with AAC as fallback.
- Decode with **libopus** (BSD-3-Clause, royalty-free, GPL-compatible) to get packet-loss concealment and FEC.
- AudioToolbox does decode Opus (`kAudioFormatOpus`, 10.13+), but it can't be told a packet was lost.

### Playback
- `AVAudioEngine` + `AVAudioSourceNode` (10.15) pulling from a jitter buffer. Set HAL `kAudioDevicePropertyBufferFrameSize` to 128–256 frames.
- Target 20–50 ms of buffering; scrcpy uses 50 ms plus a 10 ms output buffer. Correct drift by resampling.
- Avoid `AudioQueue`, which adds latency in whole-buffer steps.
- Watch `AVAudioEngineConfigurationChange` for device switches.
- Bluetooth headphones add latency you can't remove (Unverified).

### Mac mic → phone
- **Useful for VoIP apps; not for cellular calls.**
  - Normal Android apps have no virtual-mic API.
  - The adb-shell server on Android 13+ can inject audio through an AudioPolicy injector (`MODIFY_AUDIO_ROUTING` is held by `shell`).
  - scrcpy PR #7004 does this but is still unmerged; the maintainer said "not soon" in Aug 2026. Android 16 needs an attribution workaround.
- **For cellular calls,** the Mac can act as a Bluetooth Hands-Free unit via `IOBluetoothHandsFreeDevice` (10.7+, not deprecated): caller ID, answer, dial, hang up.
  - Whether **SCO call audio** routes through the Mac is **disputed and Unverified**. PhoneBridge says no; PhoneBT says yes on 14+. Prototype this early if calls matter.
  - Capture the mic with `setVoiceProcessingEnabled` (echo cancellation). Needs `NSMicrophoneUsageDescription`.

**Sources:** opus-codec.org/license; Apple doc JSON for `kAudioFormatOpus` and `IOBluetoothHandsFreeDevice`; developer.android.com av-capture; scrcpy audio docs, PR #7004, issue #3880; PhoneBridge and PhoneBT repos.

---

## 7. Webcam (Core Media I/O Camera Extension)

**Technically feasible: yes. Without a paid account: no.**

### API
- `CMIOExtensionProvider`, macOS 12.3+ (Verified, doc JSON).
- Legacy DAL plug-ins stopped loading in macOS 14.1 unless the user re-enables them from Recovery.

### Requirements
- The host app must carry the **restricted** entitlement `com.apple.developer.system-extension.install`. That requires an embedded provisioning profile, which means a paid team: "System Extension" is not in the free capability column.
- With ad-hoc signing, AMFI kills the app at spawn ("Launchd job spawn failed", code 163) (Reported).
- DTS: Developer ID-signed system extensions **must be notarised** to load with SIP on.
- The app must live in `/Applications`.
- The user approves it under System Settings › General › Login Items & Extensions › Camera Extensions (macOS 15+).
- `systemextensionsctl developer on` requires SIP off, so it is not shippable.
- **Reported, unconfirmed:** on macOS 26.7 activation fails unless the extension also embeds its own profile (OBS issue #13995). Plan to embed profiles in both the app and the extension.

### Prior art
- **OBS pays.** It is signed "Developer ID: Wizards of OBS LLC", notarized.
- **Free workaround:** feed the *already-installed* OBS virtual camera's sink stream via `CMIOStreamCopyBufferQueue`. pyvirtualcam and webcam-crop do this, ad-hoc signed, on macOS 15+.
  - It's fragile: it relies on OBS ≥30 being installed and approved, on OBS's device ID and stream order, and on OBS itself being closed.

### Recommendation
- Make the webcam an **optional, later module**.
- Ship the OBS-sink path in a free build only if wanted.
- Build our own camera extension once the project has a Developer ID.

**Sources:** Apple doc JSON for `CMIOExtensionProvider`, `OSSystemExtensionRequest` and the system-extension entitlement; forum threads 710046, 744052, 793731; WWDC22-10022; OBS issue #13995, PR #7777, issue #10381; obsproject.com virtual-camera KB; eclecticlight 2023-10-27; webcam-crop and Pinhole repos.

---

## 8. Distribution without paying Apple (critical)

### 8.1 What macOS 15 / 26 / 27 does with unsigned, ad-hoc and downloaded apps

**Locally verified on macOS 27.0.1:**
- **Unsigned arm64 binary:** killed on exec (exit 137). Unsigned code has never run on Apple silicon; Eclectic Light confirmed this on 26.6.1.
- **Linker default:** `swiftc` output is automatically `adhoc,linker-signed`.
- **Ad-hoc–signed `.app`:**
  - `spctl -a -t exec` → **rejected**, quarantined or not.
  - `syspolicy_check distribution` → "Adhoc Signed App … not suitable for distribution" plus **"Notary Ticket Missing" (Fatal)**.
  - `gktool scan` → "not signed by a distributor that meets the system Gatekeeper requirements".
- **Ad-hoc DR:** `codesign -d -r-` shows `designated => cdhash H"…"`. The identity changes with every build.

**Behaviour by macOS version:**
- **macOS 15 Sequoia:**
  - Control-click → Open no longer overrides Gatekeeper (Verified, Apple developer news, 6 Aug 2024).
  - The user must try to open the app, then go to **System Settings › Privacy & Security › Open Anyway** and confirm. After that the app is saved as an exception (Verified, Apple support 102445, updated 27 May 2026).
  - `spctl --master-disable` is "no longer supported" per `man spctl`. It now only reveals an **"Anywhere"** option that the user must then select in System Settings.
- **macOS 26 Tahoe** (Eclectic Light tests on 26.6.1):
  - "Anywhere" and the `EnableAssessment=false` profile **do not disable Gatekeeper or XProtect**. They only let signed-but-unnotarised apps run.
  - An ad-hoc app **without** quarantine "launched normally, without any warning dialog".
  - An ad-hoc app **with** quarantine under default settings was "directed to the Trash". That article doesn't describe trying Open Anyway, so whether Open Anyway still appears for **ad-hoc** apps on 26/27 is **Unverified by me**. Apple's support page still documents it generically, without version notes. I did not GUI-test it, to avoid popping dialogs on the user's machine.
  - The "Developer Tools" list in Privacy & Security lets *non-quarantined* local builds run but doesn't help quarantined downloads.
- **macOS 27:**
  - The only Gatekeeper release-note item is `spctl --purge` (cleans stale Gatekeeper DB entries).
  - Related changes: launchd ignores quarantined plists; apps can no longer read the TCC database; XProtect may restrict access to commonly targeted app data; other teams' containers are denied by default (all Verified, release notes).
  - No new bypass, and no removal of Open Anyway, is documented.
- **`xattr -dr com.apple.quarantine X.app`** still makes an ad-hoc app launch silently on 26.x (Eclectic Light). That's the mechanism third-party Homebrew taps use. It's the user's (or tap's) explicit choice and is discouraged by security writers.
- **Locally built apps are not quarantined.** Files an app creates aren't quarantined by default. So "build from source" and "app writes its own shim bundles" both avoid Gatekeeper entirely.

### 8.2 Homebrew policy (status as of October 2026)

**Verified from the Homebrew blog, docs, source and live API:**

| Date / version | Change |
|---|---|
| 5.0.0 (12 Nov 2025) | "Casks without codesigning are deprecated". "`--no-quarantine` and `--quarantine` flags have been deprecated" because Homebrew "does not wish to easily provide circumvention to macOS security features". "We will disable all Homebrew/homebrew-cask casks that fail Gatekeeper checks in September 2026." |
| 6.0.0 (11 Jun 2026) | Reaffirmed the September 2026 disable. Introduced **tap trust**: third-party taps must be explicitly trusted (`brew trust user/tap`), but installing a fully qualified `user/tap/cask` trusts that single item. |
| **2026-09-01** | **Executed.** The live cask API shows **627 casks disabled with `fails_gatekeeper_check`** (597 dated 2026-09-01, the rest 2026-10-04 to 2026-10-12), e.g. `alacritty`, `qbittorrent`. Disabled casks can't be installed; they're removed after 12 months (`REMOVE_DISABLED_TIME_WINDOW = 12`). |
| 7.0.0 (13 Sep 2026) | Sandboxed cask operations. Legacy `postflight`/`preflight` hooks deprecated for `*_steps` (third-party taps warned until 2027-12-11). Intel moved to Tier 3. |
| Current 7.0.9 | `brew install --help` has **no** quarantine flag. A grep of the installed Homebrew source finds no `--no-quarantine` handler. |

**What "pass Gatekeeper checks" means in practice:**
- `cask/audit.rb#audit_signing` runs `gktool scan` on `.app`s and `notarization_check` on binaries, but only for **official** taps (`return if !cask.tap&.official? && !signing?`).
- An ad-hoc app fails `gktool scan` (verified above).
- So **official homebrew/cask = Developer ID + notarization in practice.**
- Acceptable-Casks also bans casks that "require … Gatekeeper to be disabled or bypassed".

**Third-party tap (our own) — still works today:**
- AeroSpace, which is not notarized, ships through `nikitabobko/tap` with
  `postflight_steps do run "/usr/bin/xattr", args: ["-d","com.apple.quarantine","{{appdir}}/AeroSpace.app"] end`.
- That is the new sandboxed-steps DSL, so it is compatible with Homebrew 7.
- **Risk:** Homebrew could later forbid `xattr` in steps for third-party taps. No announcement found (Unverified).

**Formula (build from source):**
- homebrew-core rejects formulae "whose primary output is a native macOS `.app` bundle" (Verified, Acceptable-Formulae).
- **Our own tap may contain a from-source formula.** Toolchain caveat, verified locally: Command Line Tools provide `swift build`, but **not** `metal`, `actool` or `ibtool`. A CLT-only build must therefore:
  - compile Metal shaders at runtime (`MTLDevice.makeLibrary(source:)`),
  - use an `.icns` instead of an asset catalog,
  - avoid xibs and storyboards,
  - or the formula must require full Xcode.
- Locally built output isn't quarantined, so there's no Gatekeeper prompt. TCC grants still reset per build (cdhash DR) unless a stable self-signed identity is used.

### 8.3 Which capabilities need a paid team

See the table in the next section.

### 8.4 Free and cheap signing options

| Option | Verdict |
|---|---|
| **Apple fee waiver** | Only for a nonprofit *legal entity* recognised by an authority, an accredited educational institution, or a government entity. **"Not … an individual, sole proprietor, or single-person business."** Must sell nothing. Fee otherwise US$99/yr (Verified, developer.apple.com/help/account/membership/fee-waivers). Viable only if the project lives under a registered foundation. |
| **SignPath Foundation** | Free for OSI-licensed OSS, and "the code signing certificate is issued to SignPath Foundation". SignPath.io's macOS support uses `codesign` via CryptoTokenKit with *your* "Apple Developer Application" certificate created in *your* Apple portal. **No evidence the Foundation provides Apple Developer ID certificates.** Treat it as Windows-only for our purposes (macOS: Unverified/unlikely). |
| **Community sponsorship** | Fund the $99 through GitHub Sponsors or Open Collective, then enroll as an individual (the maintainer's legal name shows as signer, like Moonlight and Rectangle). Or enroll an organisation, which needs a D-U-N-S number. Signing under another org's team: no precedent verified (Unverified). |
| **Free "Apple Development" certificate (Personal Team)** | Gives an Apple-anchored, stable DR, so TCC grants survive updates. **Not accepted by Gatekeeper for distribution.** The certificate's lifetime and terms for distributing builds are Unverified. |
| **Self-signed code-signing certificate** | Stable certificate-based DR. Inferred from TN3127; not tested. Same Gatekeeper treatment as ad-hoc. Free. |

### 8.5 How comparable FOSS apps handle signing

Verified on this machine by downloading each current release and running `spctl -a -vv -t exec`:

| App | Result | Signer |
|---|---|---|
| Moonlight 6.2.0 | Notarized Developer ID | Cameron Gutman (45U78722YL) |
| Rectangle 2.0.4 | Notarized Developer ID | Ryan Hanson |
| Stats 3.0.22 | Notarized Developer ID | Serhiy Mytrovtsiy |
| AltTab 11.10.1 | Notarized Developer ID | Louis Pontoise |
| Ice 0.11.12 | Notarized Developer ID | Jordan Baird |
| LocalSend 1.18.2 | Notarized Developer ID | Tien Do Nam |
| IINA 1.5.0 | Cask not disabled, so passes the Gatekeeper audit (inferred; not downloaded) | |
| OBS 33.0.0 | Developer ID "Wizards of OBS LLC" | |
| AeroSpace | **Not notarized**; own tap strips quarantine | |
| Alacritty, qBittorrent | **Disabled** in homebrew/cask for failing Gatekeeper | |

**Conclusion:** essentially every well-known FOSS Mac utility pays the $99, in the maintainer's personal name.

### 8.6 Recommended distribution plan (free tier → paid)

1. **Always** sign with one stable identity: a self-signed project certificate, never per-build ad-hoc. Enable Hardened Runtime.
2. **Channels while unpaid:**
   - Our own Homebrew tap: a cask that strips quarantine, plus a from-source formula.
   - A GitHub Releases DMG with clear "Open Anyway" instructions.
   - A `build.sh` that works with Command Line Tools only.
   - Updates via Sparkle with EdDSA. Sparkle recommends Developer ID; with ad-hoc signing and Library Validation it may fail to load (Verified, Sparkle docs), so disable Library Validation or embed it statically.
3. **As soon as there are real users,** spend the $99/yr (Sponsors-funded). That gives Developer ID, notarization, the official homebrew/cask, the camera extension, Communication Notifications, and no Gatekeeper friction.

**Sources:**
- brew.sh 5.0.0, 6.0.0, 7.0.0 posts and blog index.
- docs.brew.sh: Acceptable-Casks, Acceptable-Formulae, Tap-Trust.
- Homebrew source: `deprecate_disable.rb`, `cask/audit.rb`, `cask/quarantine.rb`; formulae.brew.sh/api/cask.json.
- AeroSpace README and `nikitabobko/homebrew-tap` `Casks/aerospace.rb`.
- Apple: support 102445, developer news "Updates to runtime protection in macOS Sequoia", TN3127, fee-waivers page, compare-memberships.
- Eclectic Light 2026-08-06 and 2026-08-11.
- signpath.org (home, terms); docs.signpath.io/crypto-providers/macos.
- sparkle-project.org/documentation.
- Local tests listed above.

---

## "Needs a paid Apple account?" table

| Capability | Free (ad-hoc / self-signed / Personal Team)? | Paid ($99/yr) needed? | Notes |
|---|---|---|---|
| Build and run locally | ✅ | — | Unsigned won't run on arm64; ad-hoc is the minimum (Verified) |
| Distribute a download that opens without "Open Anyway" | ❌ | ✅ Developer ID + notarization | Verified via `syspolicy_check` / `gktool` |
| Official Homebrew cask (homebrew/cask) | ❌ (disabled since 2026-09-01) | ✅ | Own tap works without paying |
| Mac App Store | ❌ | ✅ | Also sandbox constraints; see item 9 |
| Hardened Runtime, App Sandbox, App Groups, Keychain Sharing | ✅ | — | The free capability column |
| Network.framework client/server, Bonjour, QUIC, TLS | ✅ | — | Needs at least ad-hoc for the LNP prompt; unsigned fails |
| Local Network permission persisting across updates | ⚠️ only with a stable identity | Not required | Ad-hoc cdhash DR changes each build |
| CoreBluetooth central/peripheral | ✅ | — | |
| USB via libusb / IOUSBHost (unsandboxed), AOA | ✅ | — | |
| AccessoryAccess "Claim USB Accessory" (macOS 27) | ❓ Unverified | possibly | Not needed |
| Local notifications with text reply | ✅ (Reported) | — | |
| Communication Notifications, Time-Sensitive, APNs push | ❌ | ✅ | Not needed for core |
| MenuBarExtra, drag & drop, Services menu | ✅ | — | |
| App Intents / Shortcuts / Spotlight actions | ✅ likely (Unverified with ad-hoc) | — | |
| SMAppService login item | ✅ with caveats | — | Re-register after each update |
| Share extension | ⚠️ Unverified with ad-hoc | — | Services menu fallback |
| Accessibility / Input Monitoring / event taps | ✅ | — | Grants reset per ad-hoc build |
| Per-app shim `.app`s generated locally | ✅ | — | Locally created, so not quarantined |
| Camera Extension (system extension), Network/Endpoint extensions, DriverKit | ❌ | ✅ restricted entitlement + notarization | Webcam is paid-only |
| Associated Domains, iCloud, Handoff, Sign in with Apple | ❌ | ✅ | Not needed |
| Sparkle auto-update | ✅ (EdDSA) | Recommended | Key rotation needs Developer ID |
| Wi-Fi Aware on macOS | n/a | n/a | Not available on native macOS |

---

## 9. Mac App Store feasibility

**Verdict: not realistic for v1. A reduced "Lite" build might be possible later.**

### What App Review 2.4.5 and 2.5.2 require (Verified)
- Mandatory sandbox.
- Self-contained bundle; no installing code into shared locations.
- No auto-launch without consent.
- No downloading or installing standalone apps or code.
- No root.
- Updates only through the Mac App Store.

### How our features fare under the sandbox

| Feature | Under App Sandbox |
|---|---|
| Spawn bundled `adb` | Possible as an embedded helper with `com.apple.security.inherit`. The adb *server daemon* outliving the app conflicts with 2.4.5(iii) "spawn processes that continue to run … after a user has quit". Run it in-process or kill it on quit. |
| USB | `com.apple.security.device.usb` exists, so OK. |
| Network server and client | `network.server` / `network.client` entitlements, so OK. |
| Accessibility / event taps | Listen-only taps with Input Monitoring reportedly work sandboxed. **Private Cmd-Tab APIs are disallowed** (Unverified detail). |
| **Per-app shim bundles** | **Not possible.** The sandbox can't write to `~/Applications`, and generating apps conflicts with 2.4.5(iv) and 2.5.2. |
| Camera extension | Camera extensions can ship via the Mac App Store per WWDC22 (Reported). |

### Guideline 4.2.7 (remote desktop) interpretation risk
4.2.7 applies when a client "acts as a mirror of specific software or services rather than a generic mirror of the host device". If it applies, the host must be "a personal computer or dedicated game console".
- A whole-phone mirror is a generic mirror, so it's arguably fine.
- **Per-app windows could be read as mirroring specific software from a phone,** which fails 4.2.7(a). This is an interpretation (Unverified).

### GPL and the App Store
- The FSF's position (GNU Go case, 2010): App Store terms impose restrictions that GPLv2 §6 forbids, and Apple removed the app.
- A GPL project can only ship on the Mac App Store if all copyright holders grant an exception. That means a CLA, or a GPL licence plus an App Store exception.
- **Recommendation:** Apache-2.0 (matches scrcpy and adb) or MPL-2.0, which keeps the App Store door open. Avoid GPL-only dependencies; libusb is LGPL, link it dynamically or use `nusb`.

**Sources:** developer.apple.com/app-store/review/guidelines (2.4.5, 2.5.2, 4.2.7, 5.2); developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app; fsf.org/news/2010-05-app-store-compliance.

---

## 10. Apple's iPhone Mirroring

### Reusable or hookable?
**No.**
- It is `/System/Applications/iPhone Mirroring.app` plus private ScreenContinuity / ScreenContinuityUI frameworks.
- It is gated by Apple Account, Continuity and eligibility checks. EU-bypass research shows the region check is signed into the iPhone's auth response on 26.x.
- The only developer surface is "UIKit adds new layouts that adapt for iPhone Mirroring" (Verified, WWDC26 macOS guide). That's iOS-side and irrelevant to us.

### Requirements and limits
- macOS 15+ (Apple silicon or T2), iOS 18+, same Apple Account with 2FA, Wi-Fi and Bluetooth on, iPhone locked and nearby.
- The Mac can't be using AirPlay or Sidecar.
- **Still unavailable in the EU.** Apple cites DMA "regulatory uncertainty". **That's a positioning opportunity for an Android equivalent.**

### UX conventions worth copying (Apple support 120421)
- **Pointer:** click = tap; click and hold = long-press; trackpad scroll and swipe; Shift-scroll = horizontal swipe.
- **Shortcuts:** ⌘1 Home, ⌘2 App Switcher, ⌘3 Search, **⌘4 Control Center (macOS 27)**; ⌘+ / ⌘− / ⌘0 to resize.
- **macOS 27:** drag a corner to resize; ⌘9 restores phone size.
- **Window:** phone-shaped, rounded, no title bar. A toolbar appears on hover with Home and App Switcher. Clicking the bottom bar goes Home.
- **Auth:** "Ask every time" (Mac password / Touch ID / Watch) or "Authenticate automatically".
- **Session:**
  - It pauses after inactivity.
  - The phone stays locked and shows "in use by <Mac>". The phone logs which Mac, when and for how long.
  - Unlocking the phone ends the session.
  - "Revoke Access" resets pairing.
- **Content and notifications:**
  - Drag and drop works both ways.
  - Audio plays on the Mac.
  - No camera or mic.
  - Phone notifications appear in Notification Center with a phone badge; clicking one opens that app in the mirror.
- **macOS 26 additions:** iPhone Live Activities in the menu bar; iPhone apps in Spotlight; Phone app on the Mac.

**Sources:** support.apple.com/en-us/120421 and 120684; Apple Newsroom 2025-06 (macOS Tahoe); WWDC26 macOS guide; `nxm/iphone-mirroring-bypass`; Kyle-Ye gist; TechRepublic on the EU delay.

---

## 11. Minimum macOS version recommendation

**Recommendation: macOS 14 Sonoma minimum, Apple-silicon (arm64) only.**

### What each version gives us (availability Verified via Apple doc JSON)

| Version | Gives us |
|---|---|
| 13 | `MenuBarExtra`, `SMAppService`, App Intents, `windowResizability` |
| **14 (floor)** | `CAMetalDisplayLink` and `NSView.displayLink` (the frame-pacing core), `AVSampleBufferVideoRenderer`, the Observation framework, a mature SwiftUI for settings and onboarding |
| 15 (nice-to-have) | SwiftUI `WindowDragGesture`, `PlainWindowStyle`, `windowLevel`. All doable in AppKit on 14, so not worth raising the floor. 15 also starts Local Network privacy, which we must handle either way. |
| 26+ (`if #available`) | `NetworkConnection` / `NetworkListener` / `NetworkBrowser`, Liquid Glass `glassEffect`, `CALayer.preferredDynamicRange`, VT low-latency super-resolution |

### User reach
- TelemetryDeck, end of Sept 2026: macOS 27.0 at 13.1%; 26.6 / 26.5 / 26.3 together at ≈51% (other 26.x builds not listed).
- Shares for 15 and older are not published in the text I could read (Unverified). The Steam survey (Sept 2026) shows a similar pattern.
- A floor of 14 covers essentially all actively updated Apple-silicon Macs, including M1 machines that never moved past 14.

### Why arm64-only
- **macOS 27 dropped Intel Macs entirely** (Verified, apple.com/os/macos compatibility list).
- The 27 release notes state **"All Intel-based software will no longer be compatible with macOS 28.0"** (Verified).
- Homebrew moved Intel to Tier 3 in September 2026 and will stop running on Intel in September 2027 (Verified).
- Universal builds are cheap to compile but double the test matrix. Intel Macs also lack AV1 decode and have different HEVC support.
- Revisit only if users ask.

---

## 12. Language and UI framework

**Recommendation: Swift 6 with AppKit for the "hot path" and SwiftUI for the "chrome".**
- **AppKit:** the mirror `NSWindow`/`NSView` hosting a `CAMetalLayer`, `NSTextInputClient`, event handling, drag sources and destinations, shim apps.
- **SwiftUI:** settings, onboarding/pairing, the device list, `MenuBarExtra`, notification preferences.
- **Optional:** a Rust core for the ADB client (UniFFI).
- **Protocol definitions** shared with Android via schema codegen (protobuf, FlatBuffers or similar). Alternatively Kotlin Multiplatform compiled to a macOS framework (Kotlin/Native); KMP-for-Mac maturity is Unverified.

| Option | Video path / latency | Input and IME fidelity | Native feel | Verdict |
|---|---|---|---|---|
| **Swift + AppKit/SwiftUI** | Direct VideoToolbox → Metal, zero-copy, display-link paced | Full NSEvent, `NSTextInputClient`, gestures | Best: real toolbars, menus, Services, Liquid Glass, App Intents | **Recommended** |
| Qt (C++) | Proven: Moonlight-qt uses VideoToolbox + Metal via SDL/FFmpeg | Good, via SDL/Qt | Medium: non-native widgets, menus approximated | Viable if cross-platform desktop is a goal |
| Tauri (WKWebView) | Must ship frames into a WebView (WebCodecs or canvas). Extra copies and compositing; latency control weak (Unverified) | Web IME is OK; trackpad gestures limited | Low–medium | Not for the mirror window |
| Electron | Same as Tauri, plus Chromium (~150 MB+) | As above | Low | No |
| Flutter (macOS) | External texture registry (`CVPixelBuffer`). Likely an extra frame of latency and a copy (Unverified) | Gesture and IME support weaker on desktop | Medium–low | No |
| Compose Multiplatform Desktop (JVM/Skia) | Needs a JNI bridge to VideoToolbox; JVM GC pauses | Weak trackpad and IME integration | Low | No. KMP for *shared logic* only, maybe. |

### What "native feel" requires
- Standard `NSToolbar` / unified title bar; Liquid Glass materials on 26+.
- A real menu bar with standard shortcuts and a Settings scene.
- Respects light/dark mode and Reduce Motion.
- Full keyboard access and VoiceOver labels for our controls. The phone's accessibility tree is not exposed unless we build that.
- State restoration and correct window tabbing/tiling behaviour.
- Services, drag and drop, Notification Center actions, App Intents / Spotlight actions.
- Low idle CPU, fast cold launch, small binary.
- Per-app Dock presence (via shims) for the "phone apps as Mac apps" illusion.

---

## Risk register

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| 1 | Gatekeeper friction (Open Anyway) for ad-hoc downloads scares or blocks users | **High** | **High** | Own tap with quarantine strip; build-from-source path; illustrated install docs; get Developer ID ($99) as early as feasible |
| 2 | Official homebrew/cask won't accept us unsigned | **Certain** (until paid) | Medium | Own tap; switch to homebrew/cask after notarization |
| 3 | Homebrew forbids quarantine stripping in third-party tap `*_steps`, or tightens tap trust further | Medium | Medium | Keep DMG + docs path; from-source formula; prioritise Developer ID |
| 4 | Apple removes Open Anyway for non-notarized apps in a future macOS | Low–Medium | **Critical** | Developer ID is the only real hedge; monitor betas each June |
| 5 | TCC/LNP/login-item grants reset on every update (ad-hoc cdhash DR) | **High** if ad-hoc | Medium–High | Sign every build with one stable self-signed (or Apple Development) identity; detect lost grants and re-prompt gracefully; minimise TCC-gated features |
| 6 | Local Network privacy: unsigned → silent `EHOSTUNREACH`; prompt bugs; spawned adb attribution; macOS 27 beta child-process regressions | Medium | High | At least ad-hoc sign; phone-initiates-to-Mac pairing (incoming TCP doesn't trigger LNP); detect `PolicyDenied`; in-process ADB client instead of a long-lived `adb` server |
| 7 | Webcam needs a system extension (paid) | Certain | Low–Medium | Defer; optional OBS-sink path; ship after Developer ID |
| 8 | macOS Metal presentation and frame-pacing regressions (Moonlight #1696 on 26) | Medium | High | Renderer abstraction with AVSBDL fallback and user toggle; frame-time telemetry overlay |
| 9 | AV1 only on M3+; phone encoders vary | Certain | Low | H.264 baseline, HEVC option, capability negotiation |
| 10 | Cmd-Tab and system shortcut capture needs private API or Accessibility | Certain | Low–Medium | Opt-in mode; permission-free default bindings; keep private API out of any App Store build |
| 11 | adb redistribution licensing ambiguity | Medium | Medium | Native ADB client (Rust/Swift) or AOSP-source build with NOTICE; or depend on the `android-platform-tools` cask |
| 12 | ADB interface contention with Android Studio's adb server | Medium | Medium | Detect `:5037` server and route through it |
| 13 | Per-app shim apps break (TCC prompt per shim; macOS 27 container rules; future Gatekeeper treatment of locally generated apps) | Medium | Medium | IPC via sockets in our own Application Support dir; shims as thin viewers with no TCC needs; fall back to tabbed windows in one app |
| 14 | App Store rejection (sandbox, 2.4.5, 4.2.7 per-app mirroring reading) | High if attempted | Low (not v1 channel) | Don't target the Mac App Store for v1; permissive licence keeps the option open |
| 15 | GPL licence blocks a future App Store build | Medium | Low–Medium | Apache-2.0 or MPL-2.0; avoid GPL-only deps; dynamic libusb or `nusb` |
| 16 | Wi-Fi Aware unavailable, so no peer-to-peer without a router | Certain (today) | Medium | Infrastructure Wi-Fi plus USB; Android hotspot as fallback; re-check each WWDC |
| 17 | AWDL / Location Services cause periodic Wi-Fi latency spikes | Medium | Medium | Jitter buffer; document `awdl0` workaround; prefer USB for low-latency mode |
| 18 | Intel users excluded | Low | Low | Intel Macs are capped at macOS 26 and Apple ends Intel software in macOS 28 |
| 19 | Bluetooth HFP call-audio routing may not work | Medium | Medium (calls feature) | Prototype `IOBluetoothHandsFreeDevice` early; ship call notifications and controls first, audio later |
| 20 | Universal Control interferes in pointer-capture mode | Low | Low | Document; no API exists |

---

## Sources

The delegated passes captured access dates as of 2026-10-25. Items marked Unverified in the text above stay unverified even where a source is listed.

### Apple — documentation, technotes, news, support
- https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements (fetched as doc JSON)
- https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes (fetched as doc JSON)
- https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes (fetched as doc JSON)
- https://developer.apple.com/news/?id=saqachfa (Updates to runtime protection in macOS Sequoia, 2024-08-06)
- https://support.apple.com/en-us/102445 (Safely open apps on your Mac; published 2026-05-27)
- https://developer.apple.com/help/account/membership/fee-waivers/
- https://developer.apple.com/support/compare-memberships/
- https://developer.apple.com/help/account/reference/supported-capabilities-macos
- https://developer.apple.com/app-store/review/guidelines/
- https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app
- https://developer.apple.com/wwdc26/guides/macos/
- https://developer.apple.com/videos/play/wwdc2025/250/ · https://developer.apple.com/videos/play/wwdc2025/260/ · https://developer.apple.com/videos/play/wwdc2022/10022/
- https://www.apple.com/os/macos/ (macOS 27 compatibility list)
- https://support.apple.com/en-us/120421 · https://support.apple.com/en-us/120684 · https://support.apple.com/en-us/102282
- https://www.apple.com/newsroom/2025/06/macos-tahoe-26-makes-the-mac-more-capable-productive-and-intelligent-than-ever/
- https://www.apple.com/macbook-pro/specs/ · https://support.apple.com/en-us/126318

### Apple — API doc pages (availability checked via `developer.apple.com/tutorials/data/documentation/<path>.json`)
- VideoToolbox: `kvtdecompressionpropertykey_realtime`, `vtishardwaredecodesupported(_:)`, `vtlowlatencysuperresolutionscalerconfiguration`
- AVFoundation: `avsamplebuffervideorenderer`
- QuartzCore / CoreAnimation: `cametaldisplaylink`, `calayer/preferreddynamicrange`
- AppKit: `nsview/displaylink(target:selector:)`, `nsapplication/presentationoptions-swift.struct`, `nstextinputclient`, `nsdocktile`
- CoreVideo: `cvdisplaylinkcreatewithactivecgdisplays(_:)` (deprecated)
- Audio and Bluetooth: `kaudioformatopus`, `iobluetoothhandsfreedevice`
- Network: `networkconnection`, `nwprotocolquic`, `nwmultiplexgroup`, `wifiaware`
- USB: `iousbhost`, `accessoryaccess`, `accessoryaccess/aausbaccessorymanager`, `accessoryaccess/aausbaccessory`
- Entitlements: `bundleresources/entitlements/com.apple.developer.accessory-access.usb`, `com.apple.security.device.usb`
- Notifications, system integration: `usernotifications/untextinputnotificationaction`, `servicemanagement/smappservice`, AppIntents, `cssearchableitem`
- Camera and system extensions: `coremediaio/cmioextensionprovider`, `osSystemExtensionRequest`
- SwiftUI: `menubarextra`, `windowdraggesture`, `plainwindowstyle`, `scene/windowlevel(_:)`, `scene/windowresizability(_:)`, `view/glasseffect(_:in:)`
- Swift: `observation`

### Apple Developer Forums
- https://developer.apple.com/forums/thread/663874 · /688508 · /715553 · /722933 · /739953 · /751839 · /768961 · /787701 · /801280 · /818807 · /834091 · /710046 · /744052 · /793731 · /719749 · /129250 · /699929

### Homebrew
- https://brew.sh/blog/ · https://brew.sh/2025/11/12/homebrew-5.0.0/ · https://brew.sh/2026/06/11/homebrew-6.0.0/ · https://brew.sh/2026/09/13/homebrew-7.0.0/
- https://docs.brew.sh/Acceptable-Casks · https://docs.brew.sh/Acceptable-Formulae · https://docs.brew.sh/Tap-Trust
- https://github.com/Homebrew/brew/blob/master/Library/Homebrew/deprecate_disable.rb · …/cask/audit.rb · …/cask/quarantine.rb
- https://formulae.brew.sh/api/cask.json (live data; 627 `fails_gatekeeper_check` disables)
- https://github.com/nikitabobko/AeroSpace · https://github.com/nikitabobko/homebrew-tap/blob/main/Casks/aerospace.rb

### Signing and distribution
- https://eclecticlight.co/2026/08/11/how-can-you-run-code-that-hasnt-been-notarised/
- https://eclecticlight.co/2026/08/06/can-you-disable-gatekeeper-and-xprotect/
- https://eclecticlight.co/tag/gatekeeper/
- https://signpath.org/ · https://signpath.org/terms · https://docs.signpath.io/crypto-providers/macos
- https://sparkle-project.org/documentation/
- https://www.fsf.org/news/2010-05-app-store-compliance
- Release artefacts inspected:
  - https://github.com/moonlight-stream/moonlight-qt/releases/download/v6.2.0/Moonlight-6.2.0.dmg
  - https://github.com/rxhanson/Rectangle/releases/download/v2.0.4/Rectangle2.0.4.dmg
  - https://github.com/exelban/stats/releases/download/v3.0.22/Stats.dmg
  - https://github.com/lwouis/alt-tab-macos/releases/download/v11.10.1/AltTab-11.10.1.zip
  - https://github.com/jordanbaird/ice-releases/releases/download/0.11.12/Ice.zip
  - https://github.com/localsend/localsend/releases/download/v1.18.2/LocalSend-1.18.2.dmg

### Usage statistics
- https://telemetrydeck.com/survey/apple/macOS/versions/ (updated 2026-10-01)
- https://store.steampowered.com/hwsurvey/ (September 2026)

### Streaming, input and audio prior art
- https://github.com/moonlight-stream/moonlight-qt/releases · /issues/1249 · /issues/1696 · /issues/1885 · /blob/master/app/streaming/video/ffmpeg-renderers/vt_metal.mm
- https://github.com/mehmetcansahin/glimmer · https://github.com/wiedymi/swift-moonlight · https://github.com/Eckobrew/moonlight-mac
- https://github.com/Genymobile/scrcpy/tree/master/doc · /blob/master/doc/macos.md · /blob/master/doc/virtual-display.md · /blob/master/app/deps/adb_macos.sh · /blob/master/app/src/usb/aoa_hid.c · /pull/7004 · /issues/3880
- https://github.com/libsdl-org/SDL/blob/SDL2/src/video/cocoa/SDL_cocoakeyboard.m
- https://danielraffel.me/til/2026/02/19/cgevent-taps-and-code-signing-the-silent-disable-race/ · https://github.com/aahung/Unshaky/issues/157 · https://github.com/ChekTek/cmd-tab
- https://github.com/shaunlebron/macos-trackpad-demo · https://forums.macrumors.com/threads/disable-universal-control.2337942/
- https://opus-codec.org/license/ · https://developer.android.com/media/platform/av-capture · https://github.com/hari157/PhoneBridge · https://github.com/bitandbytes/phonebt
- https://www.cgchannel.com/2025/10/apple-unveils-its-new-m5-chip/

### Networking and USB
- https://developer.android.com/studio/terms · https://android.googlesource.com/platform/packages/modules/adb/+/HEAD/docs/dev/adb_wifi.md
- https://github.com/yume-chan/ya-webadb · https://github.com/cocool97/adb_client · https://github.com/tbraun96/rsadb · https://github.com/poapoauu/DroidMux · https://github.com/DaniilSmirnov/adb-ios
- https://github.com/libusb/libusb/issues/1014
- https://github.com/transmission-remote-gui/transgui/pull/1614 · https://github.com/ghostty-org/ghostty/discussions/13438
- https://www.macobserver.com/news/multipeer-connectivity-deprecated-network-framework/

### System integration, webcam and iPhone Mirroring
- https://chromium.googlesource.com/chromium/src/+/lkgr/chrome/common/chrome_features.cc · https://github.com/chromium/chromium/blob/main/chrome/app_shim/README.md · https://developer.chrome.com/blog/notification-attribution-macos
- https://blog.tomayac.com/2023/06/07/web-apps-on-macos-sonoma-14-beta/ · https://eclecticlight.co/2023/10/05/how-do-sonomas-web-apps-work/
- https://eclecticlight.co/2018/01/22/at-your-service-services-menus/
- https://github.com/obsproject/obs-studio/issues/13995 (unconfirmed) · /pull/7777 · /issues/10381 · https://obsproject.com/kb/virtual-camera-troubleshooting
- https://eclecticlight.co/2023/10/27/how-sonoma-14-1-could-stop-your-camera-working/
- https://github.com/FarhanFDjabari/Pinhole · https://github.com/ahmed-e-abdulaziz/webcam-crop
- https://github.com/nxm/iphone-mirroring-bypass · https://gist.github.com/Kyle-Ye/e16730b59a733af37083873339b0e7a0 · https://www.techrepublic.com/article/news-apple-delays-ios-26-features-eu/

### Local experiments (macOS 27.0.1, 2026-10-25)
- `swiftc` output signature check, `codesign --force -s -`, `spctl -a -vv -t exec`, `syspolicy_check distribution`, `gktool scan`, `codesign -d -r-`.
- Unsigned-binary execution test (exit 137).
- `xcrun --find metal|actool|ibtool` (none with Command Line Tools).
- `brew install --help`; grep of `/opt/homebrew/Library/Homebrew` for quarantine flags.
- Download and `spctl` assessment of six FOSS app releases.
- Temporary files were in `/tmp`. The test app was deleted and the disk images unmounted.
