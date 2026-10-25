# 01: Existing solutions survey and gap analysis (Tombolo)

**Project:** Tombolo. A FOSS "iPhone Mirroring"-style experience for Android phones on macOS: an Android app plus a native macOS companion.
**Date of research:** 2026-10-25
**Method:**
- GitHub stats (stars, `pushed_at`, latest release tag and date, license) were pulled live from the GitHub API on 2026-10-25, using `curl` and authenticated `gh api`.
- Product facts come from official docs, READMEs and release pages via WebFetch, plus WebSearch for news coverage.
- Some source code was read directly from GitHub to confirm how a feature works:
  - droidMirroring-mac `FusionLauncher.swift` and `ADBClient.swift`
  - AirSync `ScrcpyServerManager.swift`, `ADBConnector.swift` and its Android manifest
  - KDE Connect Android `MouseReceiverPlugin.kt`
- The WebSearch budget ran out partway through the commercial-apps section. After that point, details come only from direct fetches of vendor pages, or are marked **unverified**.

**Legend used below**
- **[verified]**: confirmed in this pass from a primary source (repo, official doc, release page, or a live HTTP check).
- **[reported]**: from secondary press or a vendor marketing page, not independently confirmed.
- **[unverified]**: from prior knowledge or inference, not re-confirmed in this pass. Treat as a hypothesis.

---

## 0. TL;DR: decision-relevant findings

1. **The "scrcpy + continuity in one native Mac app" idea already exists, but not as FOSS.**
   - **AirSync** (sameerasw; macOS v4.1.0, 2026-09-25; 866 stars on the Mac repo) is a native SwiftUI Mac app with a Jetpack Compose Android app. It has:
     - notification sync with reply
     - clipboard sync
     - media control and call controls
     - file browsing
     - mirroring through scrcpy, including **per-app windows**. It literally runs `scrcpy --new-display --start-app=<pkg> --no-vd-system-decorations -x` [verified in source].
   - Its license is **MPL-2.0 plus "Additional Terms" that forbid publishing modified builds** [verified, LICENSE file]. That makes it source-available, not OSI open source.
   - Mirroring, desktop mode and the file browser sit behind **AirSync+** ($2.49/mo or $50 one-time). Self-compiling for personal use unlocks everything.
   - **Tombolo cannot fork it.** It is the closest competitor and the UX bar to beat.
2. **droidMirroring-mac** (matyle; v1.5.0, 2026-07-06; **Apache-2.0**; 71 stars) is the closest real FOSS piece.
   - It is a *native Swift scrcpy client*: Swift packages `ScrcpyClient`, `MirrorEngine` (VideoToolbox decoder plus Metal renderer) and `ADBKit` (which talks to the adb server on 5037).
   - It also has a Finder FileProvider extension and a work-in-progress "Fusion Mode" that puts each Android app on its own scrcpy virtual display, one Mac window per app [verified in source].
   - It has no Android companion app, so no notifications, SMS or calls.
   - **It is license-compatible and directly reusable.** It is small and single-maintainer, though.
3. **scrcpy is healthy and moving fast, but its protocol is officially unstable.**
   - Releases: 4.0 (2026-05-12, SDL3, `--flex-display`), 4.1 (2026-07-12), and 5.0 / 5.0.1 (2026-10-05 / 10-08, hardware decoding including VideoToolbox) [verified].
   - develop.md says the client/server protocol "must be considered internal: it may (and will) change at any time". The server **refuses to run unless the client version matches exactly**.
   - Every third-party client (AirSync, droidMirroring, Tango, QtScrcpy, scrcpy-mask) handles this the same way: **bundle and pin a specific `scrcpy-server` build, or maintain a fork of it.** Tombolo must do the same.
4. **Individual app windows on any Android phone without OEM privileges is only practical through ADB shell privileges.** That means scrcpy-style virtual displays (`--new-display` / `--start-app`). Phone Link, Phone Hub and the OEM Mac apps get the same result through system-signed OEM components. So Tombolo's "app windows" feature implies a **USB debugging / Wireless debugging setup step**, unless a no-dev-mode fallback tier is built.
   - **LinkMyMac** (commercial, about €15 one-time) already ships exactly this two-tier model [reported]:
     - "Standard Mirroring" with no dev mode, using MediaProjection plus AccessibilityService
     - "Advanced Mirroring" over ADB with audio, screen-off and per-app windows
5. **KDE Connect now has an official stable macOS build.**
   - 26.08.2 is published as an arm64 DMG with a Homebrew cask (`kde-connect`, macOS 13+, arm64 only) [verified via HTTP and the brew API]. The upstream README still says macOS is "not officially supported".
   - It is Qt, not native. There is no mirroring. Clipboard sync from Android to Mac is crippled by Android 10+ background clipboard rules.
   - The protocol is documented and **interoperable**: protocol v8, JSON over TLS, LAN discovery on UDP 1716, ports 1714–1764 [verified].
   - Native Mac KDE Connect clients are weak. Soduto is abandoned (a nightly fork exists). KonnectMac is new and small (GPL-3.0, 30 stars).
6. **Discontinued or dead, so not reusable:**
   - Android File Transfer for Mac: android.com/filetransfer now 301-redirects to the Quick Share for Windows page [verified]
   - Samsung DeX for Mac (ended Jan 2022) and DeX for PC (ended with One UI 7)
   - Intel Unison (June 30, 2025)
   - Dell Mobile Connect (Nov 2022 / Jan 2023)
   - official Syncthing-Android (Dec 2024; the community fork continues)
   - guiscrcpy (archived)
   - Soduto upstream
7. **The platform is moving under us**, and this matters for architecture and distribution:
   - **Android developer verification** begins enforcement 2026-09-30 in BR/ID/SG/TH, then goes global in 2027. Unregistered sideloaded or F-Droid apps then need a one-time "advanced flow" with a 1-day wait [verified].
   - **Android 17 `ACCESS_LOCAL_NETWORK`** runtime permission is required for any LAN socket once targeting SDK 37 [verified].
   - Google Play restricts AccessibilityService and SMS permissions. There *is* an SMS/Call Log exception for "Cross-device synchronization or transfer of SMS or calls" [verified].
   - Android 15+ redacts "sensitive" notifications (OTPs) for listeners unless an appop is granted via adb [reported by Sefirah].
8. **Google, Apple and OEMs are closing parts of the gap themselves.**
   - Quick Share ↔ AirDrop interop now works from Pixel 9/10 and Galaxy S24–S26 / Fold/Flip 6–7 to Macs [reported]. This weakens file transfer as a differentiator.
   - Xiaomi, Honor, vivo and OPPO/OnePlus all ship **official Mac apps** that mirror their own phones [reported].
   - Google's own app streaming targets Googlebooks and Chromebooks, never macOS.
   - Samsung has **no** Mac app and said so in July 2026 [reported].
   - The brand-agnostic, FOSS, native-Mac slot is still empty.

---

## 1. Benchmark: Apple iPhone Mirroring (macOS 15+)

Sources: Apple Support 120421 (current, includes macOS 27 items), heise (2026-06-19), MacRumors guide (Aug 2024).

### Requirements [verified, Apple Support]
- **Mac:** macOS Sequoia 15+ on Apple silicon or a T2 Mac. Live Activities need macOS Tahoe 26+.
- **iPhone:** iOS 18+ with a passcode set.
- **Pairing:** **one Mac ↔ one iPhone** at a time.
- **Account:** the same Apple Account on both devices, with 2FA.
- **Radios:** Bluetooth and Wi-Fi on for both.
- **Phone state:** the iPhone must be **locked** and **near** the Mac. It may be charging or in StandBy.
- **Mac conflicts:** the Mac can't be using **AirPlay, Sidecar, or Internet Sharing** at the same time.
- **Regions:** **Unavailable in the EU.** This is still true with macOS 27; Apple cites DMA "regulatory uncertainties". The suggested alternative there is view-only AirPlay.

### Feature set to match
| Area | Behaviour |
|---|---|
| Mirroring and control | Click = tap, click-hold = touch-and-hold, scroll/swipe with trackpad or mouse, Shift+scroll swipes sideways. Mac keyboard for typing. |
| Shortcuts | ⌘1 Home, ⌘2 App Switcher, ⌘3 Spotlight. macOS 27 adds ⌘4 Control Center. |
| Window | Preset sizes (⌘+, ⌘−, ⌘0). Rotates to landscape automatically. **macOS 27:** freely resizable (⌘9 restores iPhone size); apps must be built with the iOS 27 SDK to benefit. |
| Audio | iPhone audio plays on the Mac with Mac volume, unless headphones are attached to the iPhone. |
| Video/DRM | Before macOS 27, protected video showed black. macOS 27 plays DRM video. |
| Notifications | iPhone notifications and Live Activities appear in the Mac Notification Center, **even when not mirroring** and even if the iPhone isn't nearby. Clicking one opens the app in the mirroring window [reported, MacRumors]. Inline reply is **unverified**. |
| Drag and drop | Files go both ways: Photos/Files/iCloud Drive to the Finder, and Mac files into iPhone apps. This arrived in a macOS 15.x point release in late 2024; the exact version is **unverified**. |
| Clipboard | Universal Clipboard. |
| Launching apps | macOS 26+: Spotlight can find and launch iPhone apps once "iPhone Apps" is enabled. They open in the single mirroring window. |
| Privacy and auth | The iPhone stays locked and shows "in use by <Mac>". Using the iPhone directly ends the session. Settings logs which Mac connected, when, and for how long. Auth can be "Ask every time" (Mac password, Touch ID or Apple Watch) or "Authenticate automatically". "Revoke iPhone Access" resets everything. Sessions pause when idle. |
| Game controllers | Must pair to the iPhone, not the Mac. |
| Multiple iPhones | Selectable (macOS 26.4+ under General → AirDrop & Continuity). |

### Explicit limitations [verified]
- No camera or microphone access, "including for Face ID or phone calls".
- Calls go through the Mac's own Continuity calling, which needs Wi-Fi Calling on both devices.
- Before macOS 27: no Control Center, Notification Center or Lock Screen.
- Sessions can only be started from the Mac [reported].
- Heavy Wi-Fi/BT use, VPNs or firewalls can break it.

### How it works (high level)
- **Apple-documented:**
  - Continuity trust established once and bound to the device identities (a cryptographic pairing).
  - Bluetooth for proximity and presence.
  - Wi-Fi for the stream.
- **[unverified / inferred]:**
  - The stream uses AWDL / peer-to-peer Wi-Fi. This is consistent with the AirPlay, Sidecar and Internet Sharing mutual exclusions.
  - The locked iPhone renders into a separate remote session, which is why the phone can stay locked.
- Apple has not published a protocol spec.

### Adjacent Continuity features that complete the UX benchmark
These are separate from iPhone Mirroring but are what "it just works" means to a Mac user:
- **Messages:** SMS/iMessage relay.
- **Calls:** Phone app or FaceTime on the Mac. macOS 26 added a Phone app.
- **Universal Clipboard** and **AirDrop**.
- **Continuity Camera:** iPhone as webcam.
- **Instant Hotspot**, **Handoff**, **Live Activities in the menu bar** (macOS 26).

Tombolo's realistic target is the union: mirroring + notifications + SMS + calls + clipboard + files + webcam + hotspot. **One gap Tombolo could beat:** iPhone Mirroring shows a *single* phone window. Separate Mac windows per phone app is something Apple does not offer.

---

## 2. scrcpy (Genymobile)

| Item | Value |
|---|---|
| Repo | github.com/Genymobile/scrcpy |
| Stars | ~153.1k |
| Last push | 2026-10-24 |
| License | **Apache-2.0** (© Genymobile 2018, Romain Vimont 2018–2026) [verified] |
| Platforms (host) | Linux, Windows (incl. ARM64 since 5.0), macOS (static builds since 3.0; `brew install scrcpy`) |
| Android min | API 21 (5.0). Audio needs Android 11+. Camera needs Android 12+. |
| Requires | **USB debugging** (or Wireless debugging). No root. Nothing left installed. Xiaomi/MIUI/HyperOS also needs "USB debugging (Security settings)" or input injection fails with INJECT_EVENTS. |
| Cost | Free, no account, no ads, no internet |
| Latency claim | "35~70ms" (PR #646). 30–120 fps. About 1 s to first frame. |

### Release history (recent) [verified, GitHub releases API]
| Version | Date | Highlights |
|---|---|---|
| 3.0 | 2024-11-24 | **Virtual display** (`--new-display[=WxH[/dpi]]`), `--start-app` (`+` force-stop prefix, `?` name search), `--list-apps`, on-device OpenGL filters (crop, `--capture-orientation`, `--angle`), `--screen-off-timeout` |
| 3.3.x | Jun–Dec 2025 | Android 16 fixes; virtual displays made "presentable" |
| 4.0 | 2026-05-12 | Moved to SDL3. **`--flex-display` / `-x`**: the virtual display resizes with the window. Aspect-ratio-locked window. Camera torch/zoom. `--keep-active`. F11 fullscreen. |
| 4.1 | 2026-07-12 | Reworked encoder size constraints. **VP8/VP9 encoders**. Drag-and-drop push triggers a media scan. |
| 5.0 | 2026-10-05 | **Hardware decoding by default** (`--hwdec=auto\|vaapi\|d3d11va\|videotoolbox`), which the notes say cuts CPU use about 10×. Better buffering. `playback` audio source captures all usages. Windows ARM64. FFmpeg 9.0.2, SDL 3.4.18, adb 37.0.1. |
| 5.0.1 | 2026-10-08 | Hardware-decoder fixes: NVIDIA VA-API, H.265 on Windows, EGL only with VA-API (fixes OpenGL on macOS) |

### Features (as of 5.0.1) [verified from README and doc/*.md]
- **Video:**
  - Codecs H.264, H.265, AV1, and VP8/VP9 since 4.1.
  - Size, bitrate, fps, crop and rotation options.
  - Recording to MKV/MP4.
  - Mirroring with the device screen off (`-S`).
- **Audio** (doc/audio.md):
  - Android 12+ works out of the box. Android 11 needs the phone unlocked at start. Android ≤10 has no audio.
  - Sources:
    - `output`: the default. REMOTE_SUBMIX, which mutes the phone.
    - `playback`: Android 13+. Apps can opt out. Used by `--audio-dup`, which keeps sound playing on the phone.
    - `mic`, plus variants including `mic-voice-communication`.
    - `voice-call`, `voice-call-uplink`, `voice-call-downlink`.
    - `voice-performance`.
  - Codecs: Opus (default), AAC, FLAC, raw.
- **Camera mirroring:** Android 12+. Front/back selection, torch and zoom (4.0). **Webcam output (V4L2) is Linux-only.** There is no macOS virtual camera.
- **Virtual display** (doc/virtual-display.md):
  - `--new-display`, `--flex-display`, `--start-app`.
  - `--no-vd-system-decorations` hides launcher and system UI.
  - `--no-vd-destroy-content` moves apps to the main display on close instead of killing them.
  - `--display-ime-policy=local` shows the on-screen keyboard on the virtual display.
  - With no launcher or app, nothing renders. Whether a launcher appears on the virtual display is device-dependent.
  - Minimum Android version is not documented. The 3.0 PR notes it just hangs on Android 6. A **~Android 10+ requirement is unverified**.
  - Samsung One UI 8 brings up the full DeX desktop on a scrcpy virtual display [reported, PhoneArena / Android Authority].
- **Input:**
  - Keyboard modes: `sdk` (default; ASCII-limited), **`uhid`** (recommended; full IME support, works wirelessly), and **`aoa`** (USB only; needs no adb).
  - Mouse modes: `sdk` (absolute; pinch via Ctrl+drag), `uhid` (relative), `aoa`.
  - **Gamepad:** `--gamepad=uhid|aoa`.
- **OTG mode:** HID-only control over USB **without USB debugging** and without mirroring.
- **Clipboard:** automatic in both directions. The server runs as `shell`, so it **sidesteps the Android 10+ background clipboard restriction** that cripples KDE Connect. `--no-clipboard-autosync` and `--legacy-paste` are options. MOD+Shift+V types the clipboard as keystrokes.
- **Files:** drag an APK to install it. Drag other files to push them to `/sdcard/Download/` (`--push-target`). There is no phone-to-Mac direction and no UI feedback.
- **Wireless:**
  - `--tcpip` (needs USB once) or `--tcpip=IP`.
  - Android 11+ Wireless debugging (`adb pair`).
  - mDNS-discovered TCP devices are detected (4.0 fix).
- **Power and screen:** `--stay-awake` (only when plugged in), `--keep-active`, `--screen-off-timeout`, `--power-off-on-close`, `--show-touches`.

### Architecture [verified, doc/develop.md]
- **Server:**
  - A Java "server" is built as an unsigned APK renamed `scrcpy-server.jar`.
  - The client pushes it with `adb push … /data/local/tmp/scrcpy-server.jar`.
  - It runs as the **shell user**: `CLASSPATH=… app_process / com.genymobile.scrcpy.Server <client-version> key=value…`
  - It uses hidden framework APIs through reflection, wrappers and AIDL. Examples: `InputManager.injectInputEvent()`, `DisplayManager` virtual displays, SurfaceControl.
- **Tunnel:**
  - Default is `adb reverse localabstract:scrcpy_<SCID> tcp:27183`, so the host listens.
  - `adb forward` is the fallback.
  - SCID is a random 31-bit ID, so multiple instances can run per device. **This is what makes "one window per app" possible.**
- **Sockets:** up to 3, opened in order: video, audio, control.
  - Each stream starts with a `u32` codec ID.
  - Video carries 12-byte session packets (size changes) plus 12-byte media headers (config/key flags, 61-bit PTS, size).
  - The control socket is bidirectional, using a custom binary `ControlMessage` / `DeviceMessage` format.
  - "The only documentation for this protocol is the set of unit tests on both sides."
- **Client:** C, with SDL3 and FFmpeg. Demuxer → decoder (hardware since 5.0) → display, V4L2 sink or recorder.

### Can a third party embed or reuse the server? [verified]
- **Yes, legally and technically, with one caveat.** develop.md says the server "can be used with any client which uses the same protocol". It also provides `raw_stream=true`, `send_device_meta`, `send_frame_meta` and similar options for simple clients.
- **The caveat is version pinning.** The protocol "may (and will) change at any time". "The server fails if the client and the server do not have the exact same version", and "there is no backward or forward compatibility".
- **Third-party clients that exist today:**
  - **Tango / ya-webadb** (`@yume-chan/scrcpy`, `@yume-chan/adb-scrcpy`; MIT; v3.0.0-beta.4, 2026-10-09). A TypeScript ADB plus scrcpy client with per-server-version option classes such as `AdbScrcpyOptions2_1`. It also implements the ADB protocol itself, including over WebUSB.
  - **AirSync**: Swift, stock server v4.1 [verified in source].
  - **droidMirroring-mac**: Swift; bundles `scrcpy-server.jar`.
  - **QtScrcpy**: C++/Qt with its *own modified* server.
  - **scrcpy-mask**: Rust/Bevy with a forked `scrcpy-mask-server`.
  - **ws-scrcpy**: a web client.
- **Implication for Tombolo:** treat `scrcpy-server` as a vendored, version-pinned dependency, or a friendly fork. Re-validate on every upstream bump. Budget for maintaining a protocol layer in Swift.

### Limitations relevant to Tombolo
- Requires developer options plus USB or Wireless debugging. There is a Xiaomi extra toggle.
- Wireless debugging turns off when Wi-Fi changes, and wireless ADB does not work over the phone's own hotspot [reported, AirSync docs].
- No notifications, SMS, contacts or calls.
- No Mac→phone file browsing UI and no phone→Mac transfer.
- No macOS webcam.
- The UI is an SDL window plus a CLI. There is no Mac-native chrome and no menu bar presence.
- Android 11 audio needs the phone unlocked at start. Android ≤10 has no audio.

---

## 3. scrcpy GUIs, forks and alternative clients

All stats are from the GitHub API on 2026-10-25.

| Project | Platform / tech | License | Stars | Latest release | Notes |
|---|---|---|---|---|---|
| **QtScrcpy** (barry-ran) | Win/macOS/Linux; C++/Qt | Apache-2.0 | 32.6k | v4.2.1, 2026-09-19 | Own client plus **modified server** built from their fork. Key-mapping scripts for games, file and APK drag-drop, wireless helper. The author upsells a separate closed product, "QuickMirror". Not native-looking on Mac. |
| **Escrcpy** (viarotel-org) | Win/macOS/Linux; Electron + Vue | Apache-2.0 | 12.2k | v3.3.1, 2026-10-10 | Wraps the scrcpy binary. Multi-device management, key mapping, automation scripts, an "AI Copilot" over MCP, gnirehtet reverse tethering. **Some advanced features are in a private paid extension, "EscrcpyX".** Homebrew tap available. |
| **scrcpy-gui** (SimonAKing) | Electron | MIT | 4.1k | v2.4.5, 2026-09-14 | Bundles official scrcpy 4.1 and adb; wireless pairing, multi-device. |
| **guiscrcpy** (srevinsaju) | Python/Qt | GPL-3.0 | 3.1k | **Archived** (last push 2023-12-29) | Dead. |
| **scrcpy-mask** (AkiChase) | Rust + Bevy + React | Apache-2.0 | 1.1k | v0.9.0, 2026-06-28 | Game key mapping, forked server, HTTP/WebSocket external-control API. |
| **ws-scrcpy** (NetrisTV) | Web (Node + browser) | MIT | 2.6k | v0.8.1, 2024-03-13 (pushed 2026-10-20) | "Web client prototype". Releases have stalled. |
| **Tango / ya-webadb** (yume-chan) | TypeScript (browser/Node/Electron) | MIT | 3.3k | v3.0.0-beta.4, 2026-10-09 | A library, not an app. ADB-over-WebUSB plus a scrcpy client. A good reference implementation of both protocols. |

---

## 4. Native macOS Android-mirroring apps (the 2025–2026 wave)

A burst of SwiftUI "iPhone Mirroring for Android" apps appeared in 2026. **All of them rely on ADB plus the scrcpy server.** None does no-dev-mode mirroring.

| Project | License | Stars | Latest | Architecture | Notable features | Missing |
|---|---|---|---|---|---|---|
| **AirSync** (sameerasw/airsync-mac + airsync-android) | **MPL-2.0 + "no publishing modified builds" terms (not OSI)** | 866 (mac) / 288 (android) | mac v4.1.0, 2026-09-25 | Own WebSocket protocol (Swifter server on the Mac, AES "end-to-end" via CryptoUtil) for continuity features. Mirroring through a **native Swift scrcpy client** (`ScrcpyStreamClient`, `ScrcpyVideoDecoder`, `MetalVideoView`, server v4.1) *and* by spawning Homebrew `scrcpy`/`adb`. | Notifications (grouped, reply, dismiss), clipboard text, media and call controls, file browser, phone widget, wallpaper. Desktop mode: `new_display=1920x1080` + `flex_display`. **Per-app windows**: an app grid launches `scrcpy --new-display --start-app=<pkg> --no-vd-system-decorations -x` [verified]. Notification → open the matching Mac app or web fallback. Raycast extension. | No SMS (no SMS permissions in the manifest [verified]). No call audio. Needs Homebrew scrcpy/adb for mirroring. Mirroring, desktop and file browser are **paid (AirSync+)** unless self-compiled. macOS 14.5+. |
| **droidMirroring-mac** (matyle) | **Apache-2.0** | 71 | v1.5.0, 2026-07-06 | **Native Swift scrcpy client**: `ScrcpyClient` (control messages, audio stream), `MirrorEngine` (VTDecoder, NALU parser, MetalFrameRenderer, AudioRenderer, ScreenRecorder), `ADBKit` (adb server protocol on :5037, sync protocol, wireless pairing client), `DeviceDiscovery` (mDNS). Bundles `scrcpy-server.jar` and adb. | H.265 via VideoToolbox, Metal, under 80 ms claimed, up to 120 fps. UHID keyboard, two-way clipboard. **Finder FileProvider extension** plus thumbnail extension. File manager with drag-drop and APK install. Desktop Mode (Samsung DeX / Android 14+ freeform virtual display). **"Fusion Mode" (one virtual display per app, one Mac window each) is in progress** in `FusionEngine`. A "ContinueOn" helper exists. Universal binary. | No Android app, so no notifications, SMS or calls. Not notarized. macOS 15+. One maintainer. Changelog partly in Chinese. |
| **MimicOS** (ayushmaninbox/mimic-os) | MIT | 3 | v2.0, 2026-06-20 | SwiftUI controller that spawns bundled **scrcpy v4.0** and adb ("doesn't reimplement screen mirroring"). | Finder-like file manager with Quick Look, menu-bar drop target, audio routing choice, auto-reconnect via the phone's hotspot TCP/IP, hardware-button sidebar. | Not native video. Ad-hoc signed. macOS 14+. |
| **AndroidMirroring** (Enki013) | MIT | 5 | no releases (pushed 2026-06-30) | Spawns bundled scrcpy v4.0; experimental embedded Metal mode. | Pairing wizard, quality presets, drag-drop, recording. | Early stage. |
| **Scrcpy Desk** (umarf2212/scrcpy-desk) | none declared | 0 | v1.3.2, 2026-10-07 | Bundles scrcpy 5.0 and adb. | Wi-Fi discovery, desktop mode. | No license, so not reusable. |
| **ScrcpyHub** (1SZX1) | NOASSERTION | 0 | — | SwiftUI + AppKit. | Multi-device, menu bar. | Unknown license. |
| scrcpyui (pedrofraca), mac-scrcpy-app (madlymad) | — | — | ~2021 | Menu-bar or Automator launchers. | — | Stale. |

**Takeaway:** the mirroring half of Tombolo has been prototyped several times. The hard, differentiating parts are:
- the Android companion app (continuity services)
- polished per-app windows
- the no-dev-mode fallback
- a FOSS license with a sustainable scope

None of the existing native apps solves all four.

---

## 5. KDE Connect family

### 5.1 KDE Connect (Android + desktop)
| Item | Value |
|---|---|
| Repos | invent.kde.org (GitHub mirrors KDE/kdeconnect-android, KDE/kdeconnect-kde) |
| Android license | GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL. The LICENSES/ folder also contains Apache-2.0 for some files [verified]. |
| Desktop license | GPL/LGPL family, mixed per file under REUSE: GPL-2.0-or-later, GPL-3.0, LGPL, MIT, BSD-3 and others [verified LICENSES/ folder] |
| Android app | Master is `1.37.0 Beta 3`, minSdk 23, targetSdk 37 [verified build.gradle.kts]. Distributed on Play, F-Droid and Huawei AppGallery. |
| Desktop releases | Follow KDE Gear. Download page lists release-service **26.08.2**. |
| Activity | Both repos pushed 2026-10-25. Very active. |

**macOS status [verified]**
- The download page now says "A stable release of KDE Connect for macOS is available".
- File: `download.kde.org/stable/release-service/26.08.2/macos/kdeconnect-kde-macos-clang-arm64.dmg`. HTTP 200, 91 MB, Last-Modified 2026-10-12.
- Homebrew cask `kde-connect` 26.08.2: `depends_on macos >= 13`, **arm64 only**.
- Intel Macs only get untested nightlies from cdn.kde.org/ci-builds.
- The upstream kdeconnect-kde README still says other platforms "are not officially supported". The community wiki says it "works fairly well on macOS, however there is no official version as of yet". The messaging is inconsistent.
- Users report SMS is non-functional on macOS (NixOS PR thread citing Reddit) [reported/unverified].
- The UI is Qt/QML: not native and comparatively heavy. The AirSync author cites resource use and reliability on Apple silicon as his reason for starting AirSync.

**Features (plugins in the Android tree) [verified directory listing]**
- battery, clipboard, connectivityreport, contacts
- digitizer (phone as drawing tablet), findmyphone, findremotedevice
- inputdevicesreceiver, **mousereceiver** (desktop controls the phone through an **AccessibilityService** with tap, global HOME/RECENTS/BACK actions and so on; no video) [verified in source]
- mousepad (phone as touchpad), mpris / mprisreceiver
- notifications (send with reply/actions), receivenotifications
- ping, presenter, remotekeyboard / remotekeyboardime, runcommand
- **sftp** (desktop browses the phone filesystem), share (files, text, URLs)
- **sms**, systemvolume, **telephony** (ringing and call notifications, mute ringer; no call audio)
- Desktop `kdeconnect-sms` app: "basic features… works correctly most of the time"

**Protocol [verified, KDE/kdeconnect-meta protocol.md; Valent protocol reference; KDE UserBase]**
- **Current protocol version is 8**; 7 is still accepted.
- Packets are JSON, JSON-RPC-like: `id`, `type: kdeconnect.<plugin>[.<action>]`, `body`.
- **LAN discovery:** the identity packet is broadcast over UDP (port 1716), with `tcpPort`. Devices then connect over **TCP in 1714–1764**.
- **TLS** with self-signed certificates whose CN is the device ID (32–38 alphanumerics). Certificates are pinned after pairing.
- **v8 changes:**
  - A pairing timestamp feeds the verification code.
  - Identity is re-exchanged inside TLS and must match. A third-party implementer ties this to CVE-2025-66270 [reported].
- Payloads (files) travel on a separate TCP port announced as `payloadTransferInfo`.
- A Bluetooth link provider has existed experimentally for years. Its current status is **unverified**.
- **Implementations of the same protocol:** GSConnect (GNOME), Valent (GTK), Zorin Connect (fork), kdeconnect-ios, Soduto / KonnectMac (macOS). The ecosystem is real.

**Known limitations (platform-imposed) [verified via KDE Discuss, UserBase, GSConnect issues]**
- **Android 10+ blocks background clipboard reads.** Android→desktop sync needs a manual "Send clipboard" (notification action, tile, or the app).
- Workarounds exist:
  - grant `READ_LOGS` over adb (`pm grant org.kde.kdeconnect_tp android.permission.READ_LOGS`); Android 13+ then asks the user each time
  - a Shizuku fork
  - root/Magisk modules
- This is exactly where an ADB/shell-privileged helper (scrcpy-style or Shizuku) gives Tombolo an edge.
- No screen mirroring at all.

### 5.2 Other KDE Connect-protocol clients
| Project | Platform | License | Stars | Latest | Status |
|---|---|---|---|---|---|
| **Soduto** (soduto/Soduto) | macOS (Swift) | GPL-3.0 | 429 | no tags; code last changed 2022; README updated 2026-02-27 to say "not under development anymore" | **Abandoned upstream.** Points to a fork without endorsing it. |
| Soduto fork (sannidhyaroy/Soduto) | macOS | GPL-3.0 | 277 | v3.1.0-nightly, 2026-02-07 | Nightlies only. Pushed 2026-09-12. |
| **KonnectMac** (aryarajsingh) | macOS menu bar (Swift/AppKit/SwiftUI) | GPL-3.0 | 30 | v2.7, 2026-05-05 | New, solo. Implements protocol v7 per its announcement (v8 status unverified). KDE devs suggested contributing to kdeconnect-ios instead. |
| **kdeconnect-ios** (KDE) | iOS (Swift) | NOASSERTION (KDE GPL family) | 426 | pushed 2026-10-20 | A Swift codebase of the protocol; potentially reusable as reference (GPL). |
| **GSConnect** | GNOME Shell | GPL-2.0 | 3.7k | v74, 2026-10-18 | Active, Linux only. |
| **Valent** (andyholmes) | GTK/Linux | GPL-3.0-or-later (LICENSES/) | 920 | v1.0.0.alpha.49, 2025-11-17 | Publishes JSON schemas and a protocol reference. |
| **Zorin Connect** | Android + Zorin OS | GPL-2.0 | 301 | pushed 2026-08-25 | Rebranded fork, Linux only. |
| **Sefirah** (shrimqy) | **Windows** (+ limited Linux) + Android | GPL-3.0 | 3.0k | v3.2.0, 2026-10-14 | Own protocol, not KDE Connect. A "Phone Link / KDE Connect alternative": clipboard (auto on Android 10+ via **Shizuku or desktop ADB**), notifications, **SMS**, **calls (view and answer)**, files, Explorer storage integration, **scrcpy mirroring**. **The Windows analogue of Tombolo**, and a good reference for the feature set and the ADB-assisted permission trick. Documents the Android 15 `RECEIVE_SENSITIVE_NOTIFICATIONS` appop workaround. |

---

## 6. Platform-vendor and OEM solutions

### 6.1 Microsoft Phone Link / Link to Windows (Windows only; reference design)
- **Platforms:**
  - Windows 10/11 Phone Link app.
  - Android "Link to Windows" app, which comes **pre-installed and system-integrated** on Samsung, HONOR, OPPO, ASUS, vivo, Xiaomi, OnePlus and Realme devices.
  - **No macOS client.**
- **Features:**
  - Messages (SMS/MMS) and calls (PC as Bluetooth hands-free; **from prior knowledge, unverified in this pass**).
  - Notifications with reply, photos, and mirroring of the "Phone screen".
  - "**Apps**": individual phone apps as Windows windows, pinned to the taskbar/Start. Multiple apps at once need Android 11+, an 8 GB RAM PC, and LTW 1.20104.15+ / Phone Link 1.20104.20+.
  - Cross-device copy/paste and file drag-and-drop.
  - [verified, Microsoft Support "Setting up Apps in the Phone Link" and supported-devices pages]
- **What is OEM-only:** Apps, Phone screen, copy-paste and drag-drop are "exclusive" to OEM-integrated devices. Plain Play Store installs get messages, calls, notifications and photos only.
- **Technique:**
  - Each streamed app runs on a separate Android virtual display created by a privileged, OEM-signed system component, then gets encoded and streamed.
  - This is widely understood but **not officially documented**, so **unverified**. It matches the OEM gating and the Android 11 multi-app requirement.
- **Connectivity:** Wi-Fi, mobile data or instant hotspot. A Microsoft account with a cloud relay is involved.
- **Status:** active. A January 2026 Windows Latest report covers "almost full-screen" app mirroring rolling out [reported].
- **Mac bridge:** a third party sells **Link to Pane** (AENGIX S.L., Mac App Store $14.99, macOS 15+).
  - It impersonates a Windows Phone Link PC against Microsoft's cloud relay so Link to Windows on the phone sees the Mac.
  - Features: SMS/MMS/RCS, notifications, clipboard, photos, contacts, media, plus Wi-Fi file transfer via its own Android companion.
  - No mirroring.
  - Depends on Microsoft's proprietary service [reported, vendor site + Habr write-up].

### 6.2 Samsung
- **Samsung DeX for Mac:** ended **January 2022** [verified, Samsung US support / SamMobile / XDA].
- **DeX for PC (Windows):** not supported on One UI 7+. Samsung redirects users to Link to Windows [verified, Samsung support page].
- **Samsung Flow:** Windows and Android only. No Mac version found [unverified that one never existed].
- **No official Mac app in 2026.** In a July 2026 Samsung Members reply, Samsung said that at present its ecosystem offers Quick Share, DeX and Phone Link (Windows), and that it "can't confirm future products" [reported].
- **One UI 8:** its virtual-display support lets **scrcpy `--new-display` show a full DeX desktop** on Windows, macOS or Linux [reported]. That is relevant to Tombolo's "desktop mode".
- **AirDrop interop via Quick Share:** Galaxy S26 (One UI 8.5, March 2026), then S25/S24/Z Fold-Flip 6–7 (May 2026), with a user toggle [reported, 9to5Google / MacRumors].

### 6.3 Google
- **Chromebook Phone Hub app streaming** [verified, Google Pixel/Chromebook help]:
  - Needs ChromeOS M115+. Phones: Pixel 4a+ on Android 13+, Nothing Phone (1)/(2), Xiaomi 12T/13 series.
  - Same Wi-Fi network (or phone hotspot), Bluetooth on, and proximity.
  - The app runs on the phone, which stays asleep, and appears as a remote window.
  - Apps that "require user identity" (banking, medical) are blocked.
  - Meant for messaging-style use, not games.
- **Googlebook "Better Together"** (launched about late September 2026) [reported, Engadget / 9to5Google / Chrome Unboxed / Android Developers]:
  - **Cast My Apps:** pick any phone app from a dock icon and stream it. DRM and sensitive apps get a privacy screen.
  - Notification sync, phone storage in the Files app, Instant Hotspot, and **Continue On**.
  - Requires **Android 17**. Samsung support arrived around 2026-10-10 via Play services 26.37+ and Cross-device services 1.0.1346+.
  - Reviewers called it messy at launch.
- **Android 17 Handoff / "Continue On":** a developer API (`setHandoffEnabled()`, `onHandoffActivityRequested()`, `HandoffActivityData` with web fallback). Phones, tablets and Googlebooks only, same Google account. **Not available to macOS** [reported, developer.android.com + press].
- **Quick Share** [reported]:
  - Android, Windows and ChromeOS only.
  - **No official macOS app** as of October 2026.
  - **AirDrop interop:** Pixel 10 (Nov 2025), Pixel 9 (Feb 2026), Samsung (Mar–May 2026). The Apple side has to set "Everyone for 10 minutes".
  - Google says it is expanding in 2026, with the Quick Share extension now a Play-updatable APK.
  - **For Tombolo:** many recent phones can already AirDrop straight to a Mac with no app at all.
- **Google "Cross-Device Services":** the system app that powers Phone Hub and Googlebook features. Proprietary, with no third-party API beyond Handoff.

### 6.4 Chinese OEMs: official Mac apps for their own phones only [reported]
| OEM | Mac app | Features (as advertised) | Requirements / limits |
|---|---|---|---|
| **Xiaomi** | "Xiaomi Interconnectivity" (Mac App Store, free; v2.9.0 mentioned May 2026) | Screen mirroring with Mac keyboard and mouse control, file transfer (Mi Share), notification sync, "Home Screen+" (run Xiaomi apps on the Mac, drag content into Mac apps), tap to share | HyperOS 2+, specific service versions, Xiaomi account, model/region-dependent; one guide says M1+ Mac. Xiaomi phones only. |
| **HONOR** | "HONOR Connect" (formerly HONOR WorkStation; Mac App Store) | Mirroring (added 2025-09-22), notifications forwarded and single-touch file transfer (2025-12-16), Connected Files, phone as extended display, one-click hotspot | macOS 12+. A short supported-model list (Magic V5, MagicPad3, "others being adapted"). MagicOS 11 for hotspot. |
| **vivo / iQOO** | "vivo Office Kit" (pc.vivoglobal.com, Mac download) | Screen mirroring and control, drag files out of the mirrored screen, screen extension, task handoff, Super Clipboard (macOS 11+), notifications, Remote PC | macOS 10.14.6+. Selected models. Originally China-only; rolling out more widely with OriginOS 6/7. |
| **OPPO / OnePlus / realme** | "O+ Connect", renamed **OPPO Connect** (connect.oneplus.com / connect.oppo.com) | Site lists file transfer, communication sharing, remote file management, phone screencast, keyboard & mouse share, notification and clipboard sync. Mac support is confirmed for file transfer and clipboard; screencast on Mac is per TechPP. | OxygenOS/ColorOS 16+ for the full set; older versions are file-only. Initially UK/EU rollout. |
| **Huawei** | — | Huawei Share / PC Manager on Windows; a Mac equivalent was **not found / unverified** | — |

**Takeaway:** Xiaomi, Honor and vivo show that OEM system integration lets a Mac get mirroring without dev mode, and in Xiaomi's case app-level windows. Each one is single-brand, closed source, and tied to an account.

### 6.5 Discontinued PC-connect products
- **Intel Unison:** discontinuation announced April 2025. Stopped working **June 30, 2025** (Lenovo Aura kept it through 2025). Downloads and support gone from **Jan 1, 2026**. Built on Screenovate, which Intel acquired in late 2021 [verified, Dell KB / Intel support / Tom's Hardware].
- **Dell Mobile Connect** (Screenovate-based): downloads removed Jul 31 / Nov 30, 2022. Service ended **Nov 30, 2022 (most countries) / Jan 31, 2023 (US, CA, JP)** [verified, Dell Community / How-To Geek].
- **Samsung DeX for Mac:** Jan 2022. DeX for PC: One UI 7. (See 6.2.)

---

## 7. Commercial Mac apps

| App | Cost (as found) | Key features | Technique | Status / notes |
|---|---|---|---|---|
| **LinkMyMac** (Kevin Gnanih; formerly LinkMyDroid) | One-time purchase (€14.99 ME store; $17.99 UA store). Free Android companion. [reported] | **Standard Mirroring** (one tap) vs **Advanced Mirroring** (smoother, phone audio on Mac, screen-off, **individual phone apps in their own Mac windows**; needs USB or Wireless debugging). Tap/scroll control via **AccessibilityService**. Notifications with reply (when Android exposes an action), **SMS/MMS** threads with quick reply, call controls (answer/decline/mute/end; **audio stays on the phone**), contacts, **virtual webcam via a macOS camera extension ("LinkMyMac Camera")**, **virtual mic ("LinkMyMac Mic")**, clipboard (text/images/URLs), files and photos browser, URL handoff, media remote, Cast (beta). USB or local Wi-Fi, QR pairing, **no cloud account**. Also an iPad app. | Two tiers: MediaProjection + Accessibility, or ADB (likely scrcpy-like; **unverified**) | v1.61 (2026). **The most complete Android↔Mac product found. Its feature list is effectively Tombolo's spec, in closed source.** |
| **AirSync / AirSync+** | Free tier; + $2.49/mo or $50 one-time; self-compile free for personal use | See §4 | WebSocket + scrcpy/ADB | Source-available (MPL-2.0 + redistribution ban) |
| **Link to Pane** | $14.99 (Mac App Store) | SMS/MMS/RCS, notifications, clipboard, photos, contacts, media, files | Rides Microsoft's Phone Link cloud | See §6.1 |
| **Vysor** (ClockworkMod / Koushik Dutta) | Free basic. Pro $2.50/mo, $10/yr or $40 lifetime (third-party site; official vysor.io lists the same tiers without saying which features are in which) | Mirroring and control, screenshots. Pro adds HD, fullscreen, wireless, drag-drop file transfer, "Vysor Share" (remote device + ADB sharing via link). Also a browser version (app.vysor.io). | ADB-based [unverified detail] | 5.0.7 (Feb 2026) [reported]. Universal Mac binary. Also supports iOS. |
| **AirDroid Personal** (Sand Studio) | "from $3.99" (period not shown) | File transfer, remote control, remote camera, SMS management, calling management, notification management | Cloud account. Non-root control needs a desktop-assisted setup [unverified] | Active |
| **AirDroid Cast** | "from $2.49"; free = basic mirroring, 1 device | Android/iOS → Mac mirroring with audio. **Control requires premium** (about $3.49/mo per a quoted review). Remote-network casting is premium. USB or QR/code over Wi-Fi. P2P with relay fallback, AES. | App on the phone (MediaProjection); control mechanism unverified | Active; macOS 10.11+, Android 7+ |
| **ApowerMirror** (Apowersoft) | Freemium; free = 1 device, **10-min sessions**, likely watermark; paid LocalCast/AirCast tiers (prices not shown) | Mirroring with audio (Mac uses a virtual audio driver). Android **control is described as "from PC"**; Mac control **unverified**. | Phone app + USB/Wi-Fi | Active |
| **Wondershare MirrorGo → Dr.Fone "Screen Mirror"** | Dr.Fone Basic, 7-day free trial | Mirroring and recording. Mouse control, reply to SMS/WhatsApp, notification management (control features described for Windows) | USB or Wi-Fi (QR) | **mirrorgo.wondershare.com no longer resolves (DNS failure on 2026-10-25)**, so MirrorGo looks retired or folded into Dr.Fone [inferred, unverified] |
| **iMyFone MirrorTo** | $60 one-time, or $3–10/mo (search-result mention) | Mirroring and control | — | **Unverified** beyond a price mention |
| **MacDroid** (Electronic Team) | Free (Android→Mac only); Pro about $20/yr per reviews [reported] | Mounts the phone in Finder over **MTP, ADB or Wi-Fi**, edit in place, SD card support | MTP / ADB | v2.10.1206, 2026-06-30; macOS 11.5+ |
| **AnyDesk** (Android) | Personal/commercial licensing (terms not checked) | Remote view everywhere. **Control needs a "control plugin"**: the universal `ad1` plugin via an **AccessibilityService**, or an OEM-signed vendor plugin. Android 7+ for control. Android 10+ requires the on-device screen-capture prompt even for unattended access (an adb `appops` workaround exists). | MediaProjection + Accessibility or OEM plugin | [verified, AnyDesk docs] Shows the non-ADB control path and its limits. |
| **TeamViewer** (QuickSupport / Host) | Free for personal use [unverified] | Remote view and control | OEM add-ons (e.g. Samsung Knox) or a Universal Add-On based on Accessibility [**unverified**; the KB page fetched was only an index] | — |
| **Duet Display** | Subscription (prices not captured) | Mainly the **reverse direction**: tablet or phone as a second display for the Mac. iOS → Mac casting is mentioned; Android → Mac phone mirroring is **not** advertised. | — | Not a competitor for phone mirroring. |

---

## 8. File, clipboard and sync tools

| Tool | Platforms | License | Latest | What it gives Tombolo |
|---|---|---|---|---|
| **LocalSend** | All (Flutter); Android, macOS, iOS, Windows, Linux | Apache-2.0 (app); protocol repo has **no license file** [verified] | v1.18.2, 2026-08-21; 95.5k stars | **Open, documented REST protocol v2.2:** multicast UDP **224.0.0.167:53317** announce, HTTP(S) on TCP **53317**, `/api/localsend/v2/register`, `prepare-upload`, `upload`, `cancel`, optional PIN, reverse `prepare-download`/`download` for browser receivers. The fingerprint is the SHA-256 of a self-signed certificate. A `v3` folder exists, so v3 is in progress. **Interop target for files.** |
| **NearDrop** (grishka) | macOS menu bar | **Unlicense** | v2.2.2, 2026-09-19; 6.3k stars | A partial **Quick Share** implementation on macOS. Receives (PIN shown on Android, Mac notification). **Sends** from Finder/Safari share menus, but Android discovery requires a QR code because macOS can't send the needed BLE advertisements. Wi-Fi LAN only (no Wi-Fi Direct, since macOS uses AWDL; no Bluetooth). Visible to the whole LAN. Has a **PROTOCOL.md**. Refuses AI-assisted contributions. |
| **rquickshare** (Martichou) | Linux + macOS (Rust/Tauri) | GPL-3.0 | v0.11.5, 2025-02-23 (pushed 2026-05) | Rust Quick Share implementation; slowing down. |
| **Packet** (nozwock) | Linux (GTK) | GPL-3.0 | 0.7.3, 2026-10-02 | Quick Share client for Linux. |
| **OpenMTP** (ganeshrvel) | macOS (Electron + Go "Kalam" MTP kernel via go-mtpx) | MIT | v3.3.0, 2026-08-22 | USB MTP file manager with files over 4 GB and drag-drop. A reference for an MTP fallback with no dev mode. |
| **Android File Transfer** (Google) | macOS | proprietary | — | **Discontinued in effect:** android.com/filetransfer → 301 → /better-together/quick-share-app/ → /quick-share/with-windows-pc/ [verified 2026-10-25] |
| **Syncthing** | All | MPL-2.0 | active | The official **syncthing-android was discontinued Dec 2024** and archived, citing Play publishing difficulty. The community **Syncthing-Fork** (researchxxl/syncthing-android, MPL-2.0) is active, last pushed 2026-10-22. Folder sync rather than ad-hoc transfer. |
| **Pushbullet** | Android, browser extensions, Windows | proprietary, cloud | **unverified**: the site needs JS, and it has long been perceived as stagnant | Notification mirroring, SMS, universal copy-paste (Pro) [unverified]. Cloud-dependent. |
| **Join** (joaoapps) | Android, Chrome/Firefox extensions, desktop app for Win/Mac/Linux, web, API | proprietary | site © 2026, active status **unverified** | Clipboard, SMS, notifications, link push, Tasker integration. Uses Google cloud messaging [unverified]. |
| **Clipt** (OnePlus) | Android, Chrome | proprietary | **unverified**: clipt.app TLS error on 2026-10-25 | Clipboard and file sync through the user's Google Drive [unverified]. |
| **Google Messages for web** | Browser | proprietary | active | The only practical **RCS** path on a Mac today. Third-party apps can't read RCS from the SMS provider [unverified detail]. |


---

## 9. Feature comparison matrix

Key: **Y** = yes, **P** = partial or with caveats, **N** = no, **?** = unverified. Notes are footnoted below the table.

| Feature | Apple iPhone Mirroring (+Continuity) | scrcpy 5.0 (CLI) | droidMirroring-mac 1.5 | AirSync 4.1 (+AirSync+) | KDE Connect 26.08 (macOS) | LinkMyMac 1.61 | MS Phone Link (Windows only) | OEM Mac apps (Xiaomi/Honor/vivo/OPPO) |
|---|---|---|---|---|---|---|---|---|
| Screen mirroring | Y | Y | Y | Y (paid¹) | N | Y | Y (OEM phones) | Y (own brand) |
| Mouse/keyboard control | Y | Y (UHID full IME) | Y (UHID) | Y | P (Accessibility mouse, no video) | Y (Accessibility; ADB tier) | Y | Y |
| Phone audio on Mac | Y | Y (A11+) | Y | ? (scrcpy-capable) | N | Y (advanced tier) | ? | ? |
| Individual app windows | N (one phone window²) | P (one `--new-display --start-app` per process; manual) | P (Fusion Mode in progress) | Y (spawns a scrcpy window per app¹) | N | Y (advanced tier, reported) | Y (OEM, A11+ for multi) | P (Xiaomi "Home Screen+"; others ?) |
| Notifications with reply | Y (reply ?) | N | N | Y | Y | Y | Y | P (forwarding Y; reply ?) |
| Clipboard sync (auto, both ways) | Y | Y (shell bypasses A10 limit) | Y | P (text; Android→Mac auto limited³) | P (Android→Mac manual on A10+) | Y | Y (OEM phones) | P (vivo, OPPO Y; others ?) |
| Files / drag & drop | Y | P (Mac→phone push only) | Y (Finder FileProvider + drag) | Y (browser paid¹) | Y (share + SFTP browse) | Y | Y (OEM drag & drop) | Y |
| SMS | Y (Messages) | N | N | N | P (Linux Y; macOS reported broken) | Y (SMS/MMS) | Y | ? |
| Calls | Y (Mac calling) | N (call-audio capture only) | N | P (controls, no audio) | P (ring/mute notifications) | P (controls, no audio) | Y (PC audio via BT⁴) | ? |
| Phone camera as Mac webcam | Y (Continuity Camera) | N (V4L2 Linux only) | N | N | N | Y (camera extension + virtual mic) | Y (Win 11⁴) | ? |
| Wireless | Y (only) | Y | Y | Y | Y | Y | Y | Y |
| Setup without USB / dev mode | Y | N (OTG HID-only works without) | N | P (continuity Y; mirroring needs Wireless debugging) | Y | P (standard tier Y; advanced N) | Y | Y |
| Native macOS UI | Y | N (SDL) | Y (SwiftUI/Metal) | Y (SwiftUI) | N (Qt) | Y (?) | N/A (Windows) | Y |
| Any Android brand | N/A | Y | Y | Y | Y | Y | N (full set OEM-only) | N (own brand only) |
| FOSS | N | Y (Apache-2.0) | Y (Apache-2.0) | **N** (MPL-2.0 + no-redistribution terms) | Y (GPL) | N | N | N |
| Free (core) | Y (with Apple HW) | Y | Y | P (free tier; mirroring paid or self-compile) | Y | N (~€15 one-time) | Y (MS account) | Y (vendor account) |
| Maintenance (Oct 2026) | Active (macOS 27) | Very active | Active, 1 maintainer | Active | Active | Active | Active | Active |

Footnotes:
1. AirSync+ ($2.49/mo, $50 one-time) covers mirroring, desktop mode, media and call controls, file browser, and wireless ADB. A self-compiled build unlocks everything for personal use. Per-app windows are separate SDL scrcpy windows, not native windows.
2. macOS 26+ can launch iPhone apps from Spotlight, but they open inside the single mirroring window. macOS 27 makes that window freely resizable.
3. AirSync ships a clipboard Quick Settings tile and a share activity, which suggests manual capture on Android 10+ [inferred].
4. From prior knowledge of Phone Link and the Windows 11 phone-as-webcam feature. **Not re-verified** in this pass.

Also in the field, with no column: Vysor (mirroring, control, Pro file drop; no continuity), AirDroid Personal + Cast (cloud account; mirroring, SMS, notifications, files; control is premium), Link to Pane (continuity via Microsoft's cloud; no mirroring), Sefirah (the Windows FOSS analogue), MimicOS and AndroidMirroring (FOSS scrcpy wrappers).

---

## 10. Gap analysis

### What no single FOSS macOS solution provides today
1. **Mirroring + continuity in one native, FOSS app.**
   - The FOSS mirroring side (scrcpy, droidMirroring, MimicOS) has no Android app, so no notifications, SMS or calls.
   - The FOSS continuity side (KDE Connect, KonnectMac, Soduto fork) has no mirroring and is Qt or immature on Mac.
   - **AirSync is the only one that combines both, and it is not FOSS.** The no-redistribution clause forbids forks, and the core mirroring sits behind a paid tier.
2. **Polished per-app Mac windows that work on any Android brand.**
   - Only scrcpy virtual displays make this possible without OEM privileges.
   - AirSync spawns raw scrcpy SDL windows. droidMirroring's Fusion Mode is unfinished.
   - Nobody has the iPhone-Mirroring-grade touches, done FOSS:
     - native NSWindow per app, titled with the app name and icon
     - an app launcher / Spotlight-like picker
     - **click a notification → open that app in its own window**
     - window state persisted
   - Note that this would *exceed* Apple's benchmark, which offers a single window.
3. **A no-dev-mode path.** All FOSS mirroring requires USB or Wireless debugging. A MediaProjection + AccessibilityService tier would give "basic mirror + control" with no developer options. LinkMyMac (closed) proves the two-tier model. Its costs:
   - Android 14+ capture consent each session [unverified detail]
   - Play Accessibility-policy review
   - no virtual displays, so no per-app windows
   - weaker audio
4. **Calls with audio on the Mac.** Nobody does this on macOS. Phone Link does it on Windows over Bluetooth HFP. **Feasibility on macOS (IOBluetooth hands-free APIs, or an audio-routing alternative) is unverified** and needs dedicated technical research.
5. **Phone camera as a macOS webcam, FOSS.** scrcpy can capture the camera, but its virtual webcam output (V4L2) is Linux-only. LinkMyMac does it closed-source through a CoreMediaIO camera extension. A FOSS Swift camera extension fed by scrcpy's camera stream, or by a companion-app encoder, is an open slot. Android 14+ USB "webcam mode" (UVC) works on Macs natively on some devices [unverified per device] and could be a no-code fallback.
6. **SMS on macOS, FOSS.** KDE Connect's SMS reportedly doesn't work on its macOS build [unverified]. No native FOSS Mac SMS client exists. RCS remains out of reach for third parties apart from notification-reply actions [unverified detail].
7. **Reliable automatic clipboard from Android→Mac.** This needs shell privileges: an ADB-launched helper (as in scrcpy) or Shizuku. A FOSS Mac app that does this automatically while also offering continuity features doesn't exist. Sefirah does it on Windows.

### What already comes close (be honest)
- **AirSync** matches a large share of the vision today: native SwiftUI, notifications with reply, clipboard, media and call controls, files, scrcpy mirroring, desktop mode and per-app windows. Tombolo's differentiation versus AirSync is:
  - **true FOSS licensing**, with forkable and redistributable builds
  - no paid gate on mirroring
  - native per-app windows
  - SMS
  - webcam
  - a no-dev-mode tier
  - interop with open protocols
- **LinkMyMac** has nearly the full feature list Tombolo wants (two-tier mirroring, per-app windows, SMS, call controls, webcam, mic). It is closed and paid.
- **KDE Connect** now has an official stable macOS build, and the protocol is mature. If Tombolo only wanted continuity features, contributing to KDE Connect or KonnectMac would be the cheaper path.
- **Quick Share ↔ AirDrop interop** already gives many recent Pixel and Galaxy phones app-free file transfer to Macs.
- **OEM Mac apps** already give Xiaomi, Honor, vivo and OPPO owners mirroring without dev mode.

### What Tombolo would uniquely offer (if executed)
- A single **FOSS** (Apache-2.0 or GPL-3.0, to be decided) native macOS app plus Android app that works across brands and combines:
  - scrcpy-class mirroring (low latency, audio, UHID input)
  - **native per-app windows** with notification click-through
  - continuity services (notifications with reply, SMS, call control, clipboard, files, media)
  - optional webcam
- A **two-tier connection model**:
  - zero-dev-mode basic tier: MediaProjection + Accessibility + LAN protocol
  - power tier: Wireless debugging + shell-privileged helper, giving virtual displays, auto clipboard and sensitive-notification access
- **Open-protocol interop:** LocalSend for files, optionally KDE Connect for continuity, NearDrop-style Quick Share receive. No proprietary cloud.

---

## 11. Reusable pieces and license compatibility

### Directly reusable components
| Component | License | Reuse in Tombolo | Notes |
|---|---|---|---|
| **scrcpy-server** (Java, runs via `app_process` as shell) | Apache-2.0 | Push and launch from the Mac (or from the Android app via Wireless-debugging self-connect) for virtual displays, video/audio/camera capture, UHID input and clipboard | Keep the NOTICE. **Pin the exact version**, since the protocol is unstable. Consider a minimal fork if Tombolo needs extra messages (e.g. per-display app events). |
| **scrcpy client** (C, SDL3/FFmpeg) | Apache-2.0 | Reference only. Tombolo should be a native Swift client. | — |
| **droidMirroring-mac** Swift packages: `ScrcpyClient`, `MirrorEngine` (VTDecoder/Metal/Audio), `ADBKit` (adb server + sync protocol), `DeviceDiscovery` (mDNS), `FusionEngine`, FileProvider extension | **Apache-2.0** | The strongest head start for the Mac side: vendor or fork these packages | One maintainer, 71 stars. Review code quality. Upstreaming improvements is possible. |
| **Tango / ya-webadb** | MIT | Reference for ADB protocol, wireless pairing (SPAKE2 + TLS) and scrcpy option serialization per version | TypeScript. Its pairing implementation is a useful spec if Tombolo drops the `adb` binary [pairing support **unverified**]. |
| **adb** (platform-tools) | Apache-2.0 (AOSP source); prebuilt SDK binaries carry the Android SDK license | Bundle (as scrcpy and droidMirroring do) or replace with a native Swift ADB client | Redistributing Google's prebuilt binary falls under SDK license terms [unverified nuance]. Building from AOSP avoids that. |
| **Shizuku** (RikkaApps) | Apache-2.0 (API: MIT) | Pattern or library for the Android app to obtain a shell-privileged process on-device via Wireless debugging (no PC) | Last push 2025-06-18, so maintenance is slowing. LADB (local adb on device) is another reference; license unclear. |
| **LocalSend** (app) | Apache-2.0 | Interop: implement protocol v2.2 on both sides so Tombolo exchanges files with any LocalSend device | The protocol doc repo has no license, but implementing a protocol from its description is generally fine [legal nuance unverified]. Watch v3. |
| **NearDrop** | **Unlicense** (public domain) | Embed Quick Share receive and send-by-QR on the Mac | Freely usable. Upstream refuses AI-assisted PRs, which matters for upstreaming, not for reuse. Protocol is reverse-engineered, so Google can break it. |
| **KDE Connect** (Android + desktop) | GPL-2.0-only / GPL-3.0-only (Android); GPL/LGPL mix (desktop) | Interop (implement protocol v8) or code reuse | **Reusing KDE Connect Android code forces Tombolo's Android app to GPL.** Apache-2.0 code can go into GPL-3.0 projects but not GPL-2.0-only ones, so pick the GPL-3.0 option. Implementing the protocol from the published spec has no license impact. |
| **KonnectMac**, **Soduto**, **kdeconnect-ios** | GPL-3.0 / GPL family | Swift references for a KDE Connect protocol client | Copying code makes the Mac app GPL-3.0. |
| **Sefirah** (Windows + Android) | GPL-3.0 | Reference architecture for the Android companion (SMS, calls, notifications, Shizuku/ADB clipboard) | Copying code requires GPL-3.0. |
| **OpenMTP / go-mtpx** | MIT (go-mtpx license **unverified**) | USB MTP fallback for file browsing without dev mode | Go via FFI. |
| **Valent JSON schemas** | GPL-3.0-or-later repo (schema licensing **unverified**) | Test fixtures for KDE Connect interop | — |
| **AirSync** | MPL-2.0 + additional no-redistribution terms | **Do not reuse.** Reading it as a competitor is fine. Copying it is incompatible with a FOSS release. | The added terms conflict with MPL's own redistribution grant. Treat it as "all rights reserved for derivatives". |

### License strategy notes
- **Apache-2.0 for Tombolo** keeps compatibility with scrcpy, droidMirroring, LocalSend, Shizuku, NearDrop (Unlicense) and Tango (MIT). It excludes copying any KDE Connect, Soduto, KonnectMac or Sefirah code. Implementing the protocols from their specs is still possible.
- **GPL-3.0 for Tombolo** can absorb all of the above, since Apache-2.0 is one-way compatible with GPLv3. It could also reuse KDE Connect code under its GPL-3.0 option.
- Choosing between them is a **scope decision for the user**. It is not settled here.
- **Distribution friction applies to any license:**
  - macOS: notarization needs a paid Apple Developer ID. Several competitors skip it and ship ad-hoc-signed builds.
  - The Mac App Store sandbox blocks spawning adb/scrcpy.
  - Android: see §12.

### Protocols to interoperate with
| Protocol | Openness | Transport | Value |
|---|---|---|---|
| **KDE Connect v8** | Open spec (kdeconnect-meta protocol.md), many implementations | UDP 1716 discovery, TCP 1714–1764, TLS with pinned self-signed certs, JSON packets, side-channel payload ports | Could let Tombolo's Mac app work with the existing KDE Connect Android app (instant user base), or let Tombolo's Android app work with Linux and Windows desktops. Its plugin model maps well onto Tombolo's features. |
| **LocalSend v2.2** | Open, documented | Multicast 224.0.0.167:53317 + HTTPS REST on 53317 | Cross-platform file drops, including iOS/Windows/Linux peers and browser receivers |
| **Quick Share** | Proprietary, reverse-engineered (NearDrop PROTOCOL.md, rquickshare) | mDNS/LAN on Mac. BLE advertising can't be done from macOS, so sending needs QR. | Receive from any Android with no app installed |
| **AirDrop (via Google's interop)** | Proprietary on both sides | Apple stack | Already works for Pixel 9/10 and Galaxy S24–S26 to Mac. Nothing for Tombolo to build. Mention it in docs. |
| **scrcpy server protocol** | Open source, explicitly unstable | adb tunnel (localabstract) | Mirroring and control engine; version-pinned |
| **Phone Link cloud** | Proprietary (Link to Pane rides it) | Microsoft relay | **Avoid**: violates the "no proprietary services" constraint |

---

## 12. Platform constraints found along the way (feed into the technical-architecture research)
- **Android developer verification** [verified]:
  - Enforcement starts **2026-09-30** for certified Android 7+ devices installing from participating stores in Brazil, Indonesia, Singapore and Thailand, then **globally from 2027**.
  - Open-source apps may register (developer account; register the repository's re-signing key if F-Droid signs).
  - Unregistered apps need the user's one-time **"advanced flow"**: developer mode, a coaching check, reboot, a **1-day wait**, then biometric confirmation.
  - Free "limited distribution" accounts allow up to 20 devices.
  - Whether `adb install` is exempt was **not stated** on the pages read.
- **Google Play policy** [verified]:
  - **AccessibilityService** requires a declaration form, prominent in-app disclosure and consent, and narrow purpose. `isAccessibilityTool` is for disability tools only. Autonomous agent-like use is prohibited.
  - **SMS/Call Log** permissions are allowed for non-default handlers only under listed exceptions. One of them is **"Cross-device synchronization or transfer of SMS or calls… (such as between phone and laptop)"**: READ_SMS, RECEIVE_SMS/MMS/WAP_PUSH, SEND_SMS, READ_CALL_LOG. Review is still required.
- **Android 17 local network protection** [verified]: apps targeting SDK 37 need the runtime `ACCESS_LOCAL_NETWORK` permission (NEARBY_DEVICES group) for *any* LAN TCP/UDP, including mDNS and multicast. The alternative is the `NsdManager` `FLAG_SHOW_PICKER` system picker. KDE Connect already targets 37. AirSync declares the permission.
- **Android 10+ background clipboard block** [verified]: needs shell privileges, the READ_LOGS trick, or user action.
- **Android 13+ "restricted settings"**: sideloaded apps must be allowed manually before Notification Listener or Accessibility can be enabled [reported, Sefirah README].
- **Android 15+ sensitive-notification redaction** (OTPs hidden from listeners): `adb shell appops set <pkg> RECEIVE_SENSITIVE_NOTIFICATIONS allow` [reported, Sefirah README].
- **Xiaomi/HyperOS**: needs "USB debugging (Security settings)" for input injection over ADB [verified, scrcpy and droidMirroring docs].
- **Wireless debugging** turns off when Wi-Fi changes, doesn't work over the phone's own hotspot, and auto-reconnect on known networks is coming in Android 17 [reported, AirSync docs].
- **macOS**: spawning adb/scrcpy is incompatible with the App Store sandbox (MimicOS and AndroidMirroring both disable the sandbox). Notarization needs a paid Developer ID.

---

## 13. Items explicitly unverified
- Minimum Android version for scrcpy `--new-display` (likely about Android 10; undocumented).
- Phone Link's internal technique: per-app virtual displays via OEM-privileged components. Phone Link call audio over Bluetooth HFP and the Windows 11 phone-as-webcam feature are from prior knowledge.
- Inline reply to iPhone notifications on the Mac. Exact macOS version that added drag-and-drop to iPhone Mirroring. AWDL as its transport.
- LinkMyMac's mirroring internals (ADB tier possibly scrcpy-based). AirSync's audio-in-mirroring status and Android→Mac clipboard automation.
- Mac-side Android control for ApowerMirror, AirDroid Cast and Dr.Fone. TeamViewer add-on details. Pushbullet, Join and Clipt current status.
- KDE Connect SMS on macOS (reported broken), the Bluetooth backend status, and KonnectMac v8 support.
- Huawei Mac integration. HONOR, vivo and Xiaomi audio, reply and call features on Mac.
- MirrorGo status (the domain no longer resolves; folding into Dr.Fone is inferred).
- Android 14+ MediaProjection per-session consent, Android 14+ USB UVC webcam mode per device, macOS hands-free (HFP) feasibility, RCS inaccessibility to third parties: prior knowledge, for the technical-research doc.
- Search-budget note: WebSearch hit its per-turn limit during §7. Later facts come only from direct fetches of vendor pages, the GitHub API, or prior knowledge, labelled as such.

---

## Sources

**Apple**
- https://support.apple.com/en-us/120421 (iPhone Mirroring: requirements, features, macOS 26/27 items, EU)
- https://www.heise.de/en/news/macOS-27-iPhone-Mirroring-gets-flexible-windows-and-Control-Center-11339158.html (2026-06-19)
- https://www.macrumors.com/guide/iphone-mirroring/
- https://support.apple.com/guide/personal-safety/manage-iphone-mirroring-on-your-iphone-or-mac-ips70daa1bcf/web

**scrcpy and clients**
- https://github.com/Genymobile/scrcpy (README; releases page and API)
- https://github.com/Genymobile/scrcpy/releases/tag/v3.0
- https://github.com/Genymobile/scrcpy/blob/master/doc/develop.md
- https://raw.githubusercontent.com/Genymobile/scrcpy/master/doc/virtual-display.md
- https://raw.githubusercontent.com/Genymobile/scrcpy/master/doc/audio.md
- https://raw.githubusercontent.com/Genymobile/scrcpy/master/doc/connection.md
- https://raw.githubusercontent.com/Genymobile/scrcpy/master/doc/keyboard.md
- https://github.com/Genymobile/scrcpy/blob/master/doc/control.md
- https://raw.githubusercontent.com/Genymobile/scrcpy/master/doc/device.md
- https://github.com/Genymobile/scrcpy/pull/5370
- https://ubuntuhandbook.org/index.php/2026/10/scrcpy-5-0-hardware-decoding/
- https://www.androidauthority.com/scrcpy-5-0-update-hardware-decoding-3719521/
- https://www.androidauthority.com/scrcpy-4-0-update-flex-display-3667375/
- https://www.phonearena.com/news/samsungs-pc-dex-is-gone-but-a-new-workaround-makes-it-better-than-before_id172799
- https://github.com/barry-ran/QtScrcpy
- https://github.com/viarotel-org/escrcpy
- https://github.com/SimonAKing/scrcpy-gui
- https://github.com/srevinsaju/guiscrcpy
- https://github.com/AkiChase/scrcpy-mask
- https://github.com/NetrisTV/ws-scrcpy
- https://github.com/yume-chan/ya-webadb
- https://tangoadb.dev/scrcpy/

**Native macOS Android-mirroring apps**
- https://github.com/matyle/droidMirroring-mac (README, CHANGELOG.md, LICENSE, source tree)
- https://github.com/sameerasw/airsync-mac (README, LICENSE, source)
- https://github.com/sameerasw/airsync-android
- https://sameerasw.com/airsync
- https://sameerasw.com/docs/airsync/getting-started/adb-mirroring
- https://sameerasw.com/docs/airsync/airsync-plus
- https://github.com/ayushmaninbox/mimic-os
- https://github.com/Enki013/AndroidMirroring
- https://github.com/umarf2212/scrcpy-desk
- https://github.com/1SZX1/ScrcpyHub
- https://github.com/pedrofraca/scrcpyui

**KDE Connect family**
- https://kdeconnect.kde.org/download.html
- https://download.kde.org/stable/release-service/26.08.2/macos/kdeconnect-kde-macos-clang-arm64.dmg (HTTP check)
- https://formulae.brew.sh/api/cask/kde-connect.json
- https://community.kde.org/KDEConnect
- https://userbase.kde.org/KDEConnect
- https://github.com/KDE/kdeconnect-meta/blob/work/protocol-schemas/protocol.md (protocol v8)
- https://valent.andyholmes.ca/documentation/protocol.html
- https://github.com/KDE/kdeconnect-android
- https://github.com/KDE/kdeconnect-kde
- https://github.com/KDE/kdeconnect-ios
- https://github.com/NixOS/nixpkgs/pull/481022
- https://discuss.kde.org/t/konnectmac-a-community-built-native-macos-kde-connect-client/46839
- https://github.com/aryarajsingh/KonnectMac
- https://github.com/soduto/Soduto
- https://github.com/sannidhyaroy/Soduto
- https://github.com/GSConnect/gnome-shell-extension-gsconnect
- https://github.com/andyholmes/valent
- https://github.com/ZorinOS/zorin-connect-android
- https://github.com/shrimqy/Sefirah
- https://discuss.kde.org/t/kde-connect-clipboard-sync/6422
- https://github.com/sreevarshan-xenoz/Pocketdesk/pull/107 (v8 handshake description; third-party)

**Microsoft, Samsung, Google, OEMs**
- https://support.microsoft.com/en-us/windows/apps/phonelink/setting-up-apps-in-the-phone-link
- https://support.microsoft.com/en-us/windows/apps/phonelink/supported-devices-for-phone-link-experiences
- https://www.windowslatest.com/2026/01/07/windows-11s-almost-full-screen-android-apps-mirroring-now-available-for-everyone-via-phone-link-app-with-supported-phones/
- https://link-to-pane.com/
- https://habr.com/ru/articles/1060248/
- https://apps.apple.com/us/app/link-to-pane/id6791965431?mt=12
- https://www.samsung.com/latin_en/support/apps-services/changes-to-the-way-you-connect-samsung-galaxy-mobile-devices-to-pcs/
- https://www.sammobile.com/news/samsung-dex-shutting-down-windows-7-macos/
- https://www.xda-developers.com/samsung-dex-for-windows-7-macos-support-ending/
- https://r1.community.samsung.com/t5/solutions-tips/samsung-macos/td-p/37599301
- https://support.google.com/pixelphone/answer/13883513
- https://support.google.com/chromebook/answer/10480029
- https://9to5google.com/2026/10/10/googlebook-android-sync-updates-samsung-support-rolling-out/
- https://chromeunboxed.com/tested-googlebooks-and-samsung-phones-now-work-seamlessly-together/
- https://www.engadget.com/2263649/googlebooks-a-laptop-that-works-better-with-your-android-phone/
- https://developer.android.com/about/versions/17/features
- https://www.androidauthority.com/android-17-continue-on-3669055/
- https://www.macrumors.com/2026/02/11/airdrop-quick-share-interoperability-more-phones/
- https://9to5google.com/2026/06/03/android-airdrop-list-of-supported-devices/
- https://usefwd.io/blog/quick-share-for-mac/
- https://en.wikipedia.org/wiki/Quick_Share
- https://apps.apple.com/app/xiaomi-interconnectivity/id6673908449
- https://www.gizmochina.com/2024/11/12/locked-into-apples-ecosystem-discover-how-xiaomi-15-connects-with-macbook-ipad-and-iphone/
- https://apps.apple.com/us/app/honor-workstation/id6742048745?mt=12
- https://www.honor.com/global/tech/connect/
- https://pc.vivoglobal.com/
- https://www.xda-developers.com/this-android-phone-connects-with-macbook-in-ways-the-iphone-cant/
- https://connect.oneplus.com/
- https://techpp.com/2025/10/29/how-to-connect-oneplus-phone-to-a-mac-using-o-connect/
- https://www.tomshardware.com/software/intel-discontinues-unison-app-for-connecting-pcs-and-smartphones
- https://www.dell.com/support/kbdoc/en-us/000337603/intel-unison-end-of-service-announcement
- https://www.intel.com/content/www/us/en/support/articles/000102120/software.html
- https://www.dell.com/community/Dell-Mobile-Connect/Dell-Mobile-Connect-to-be-Discontinued/td-p/8214336
- https://www.howtogeek.com/821083/dell-is-shutting-down-its-phone-sync-app/

**Commercial apps**
- https://linkmymac.com/
- https://linkmymac.com/features-guide
- https://apps.apple.com/me/app/linkmymac/id6755784154?platform=mac
- https://www.vysor.io/
- https://vysor.org/pricing/ (third-party)
- https://www.airdroid.com/pricing/
- https://www.airdroid.com/cast/
- https://www.apowersoft.com/phone-mirror
- https://drfone.wondershare.com/android-mirror.html
- https://www.macdroid.app/
- https://support.anydesk.com/docs/android
- https://www.duetdisplay.com/

**File, clipboard and sync**
- https://github.com/localsend/localsend
- https://github.com/localsend/protocol
- https://github.com/grishka/NearDrop
- https://github.com/Martichou/rquickshare
- https://github.com/nozwock/packet
- https://github.com/ganeshrvel/openmtp
- https://www.android.com/filetransfer/ (redirect check)
- https://github.com/syncthing/syncthing-android
- https://github.com/researchxxl/syncthing-android
- https://joaoapps.com/join/
- https://www.pushbullet.com/ (JS-only; not readable)
- https://github.com/RikkaApps/Shizuku
- https://github.com/tytydraco/LADB

**Android platform policy**
- https://developer.android.com/developer-verification
- https://android-developers.googleblog.com/2026/03/android-developer-verification.html
- https://developer.android.com/developer-verification/guides/open-source-app-registration
- https://developer.android.com/privacy-and-security/local-network-permission
- https://support.google.com/googleplay/android-developer/answer/10208820 (SMS/Call Log exceptions)
- https://support.google.com/googleplay/android-developer/answer/10964491 (AccessibilityService policy)
