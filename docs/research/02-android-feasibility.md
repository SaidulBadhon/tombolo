# 02: Android-side technical feasibility (Tombolo)

Research date: 2026-10-25. Scope: Android 10 (API 29) through Android 17 (API 37, stable since 2026-06-16).
Level of detail: public developer documentation. This is a planning document, so it records **what is possible,
through which API, and with what user-visible limits**. It does not document setup procedures.

Labels: **[verified]** = checked against official docs or source on 2026-10-25; **[reported]** = stated by a
credible third party (README, news, release notes) but not checked against an official source;
**[unverified]** = prior knowledge, to be confirmed by a prototype.

Nothing here was tested on a device. Every "feasible" below is a desk-research verdict; Phase 0 of the plan
exists to turn the risky ones into measured facts.

---

## 0. TL;DR

1. **There are two realistic implementation paths, and Tombolo needs both.**
   - **Standard mode — a normal app.** MediaProjection for capture, an AccessibilityService for input,
     NotificationListenerService, SMS/telephony APIs, a foreground service for connectivity. Works on any
     phone with no developer settings. Limits: Android asks for screen-capture consent **every session**
     (Android 14+), capture **stops when the phone locks** (Android 15+), input is gesture-level, background
     clipboard reading is blocked (Android 10+), and there are **no per-app windows**.
   - **Enhanced mode — a shell-privileged helper.** The approach scrcpy and Shizuku use: a helper process
     started over ADB (USB or Wireless debugging) runs with the `shell` user's permissions. It unlocks
     virtual displays (→ **one Mac window per phone app**), high-fidelity input (incl. a virtual HID
     keyboard/mouse), background clipboard, system-audio capture without a per-session prompt, and keeping the
     phone's panel off while mirroring. Limits: requires Developer options and USB/Wireless debugging; the
     helper does not survive a reboot; Wireless debugging switches off when the phone changes networks.
2. **Per-app windows are only possible in Enhanced mode** on non-OEM devices. Launching other apps' activities
   onto a separate display needs a public/trusted virtual display, which requires signature-level permissions
   that normal apps cannot hold but the shell user does. Microsoft Phone Link and Google's own app streaming get
   the same result through OEM/system privileges (Companion App Streaming APIs, Android 13+) [verified, via the
   AOSP app-streaming doc linked from Mishaal Rahman's thread].
3. **"Phone stays locked while mirroring" (Apple's model) is not reproducible.** Standard mode loses capture on
   lock (Android 15+). Enhanced mode can turn the **panel off while the device stays awake and unlocked** (as
   scrcpy does) — functionally similar, but the security model differs: Tombolo must end the session and lock
   the phone when someone uses it directly. This needs a prototype (Phase 0).
4. **Android 17 adds a runtime `ACCESS_LOCAL_NETWORK` permission** (NEARBY_DEVICES group) for any LAN traffic
   once an app targets API 37 [verified]. Tombolo must request it in onboarding.
5. **Android 15+ redacts one-time codes** from notifications for "untrusted" listeners [verified]. Exemption
   requires a signature|role permission that third-party apps don't get by default; Enhanced mode can optionally
   grant the corresponding app-op (documented by Sefirah) [reported]. Ship this **opt-in**, off by default.
6. **Distribution is shifting.** Android developer verification enforcement started **2026-09-30** in Brazil,
   Indonesia, Singapore and Thailand for installs from participating stores, and expands to "all apps on
   certified Android devices" in **2027** [verified, Android Developers Blog, June 2026]. Free *limited
   distribution* accounts exist (≤ 20 devices). Unregistered apps remain installable through ADB or the new
   "advanced flow" (one-time, includes a 24-hour wait) [verified/reported]. **Tombolo should register its
   package name** (free) so normal sideloading and F-Droid keep working — but F-Droid's own signing key conflicts
   with the registration model and that conflict is unresolved as of Oct 2026 [reported].
7. **Android 17 Advanced Protection Mode revokes AccessibilityService access** for apps that aren't genuine
   accessibility tools [verified/reported]. Users with APM on cannot use Standard-mode control; Enhanced mode is
   unaffected by that rule (but APM also restricts USB data and sideloading).

---

## 1. Implementation paths

| | **Path A — Standard (plain app)** | **Path B — Enhanced (shell helper via ADB)** | **Path C — Enhanced, self-started on the phone** |
|---|---|---|---|
| What it is | Only public SDK APIs and user-granted permissions | A helper process launched over ADB from the Mac, running as the `shell` user — the scrcpy approach (see scrcpy `doc/develop.md`) | The same helper, started on-device through Wireless debugging without a computer — the approach Shizuku documents for Android 11+ |
| Requires | Nothing special | Developer options + USB debugging or Wireless debugging (Android 11+) + one-time pairing with the Mac | Developer options + Wireless debugging + one-time on-device pairing |
| Survives reboot | Yes | **No** — restart needed | **No** — restart needed |
| Survives network change | Yes | USB: yes. Wireless debugging: **turns off when Wi-Fi changes** [reported]; Android 17 adds auto-reconnect on known networks [reported] | Same as B |
| User friction | Per-session capture consent; Accessibility + notification access grants; "restricted settings" for sideloaded installs (Android 13+) | One-time developer setup; per-boot restart | One-time developer setup; per-boot restart from the phone |
| Side effects | None | Some apps (e.g. some banking apps) refuse to run while Developer options/debugging are on [reported] | Same as B |
| Licence of prior art | — | scrcpy: Apache-2.0 | Shizuku: Apache-2.0 (API: MIT); maintenance slowing (last push 2025-06) [reported] |

**Recommendation.** Build Standard mode as the always-available baseline, Enhanced mode (Path B) as the power
tier, and Path C as a later convenience. Path C lets the phone restart the helper itself after a reboot
without the Mac being present, and Shizuku integration can come for free if the user already runs it.

---

## 2. Capabilities

### 2.1 Screen capture

| | Standard (MediaProjection) | Enhanced (helper) |
|---|---|---|
| Verdict | **Yes, with consent per session** | **Yes** |
| API / approach | `MediaProjectionManager.createScreenCaptureIntent()` → `MediaProjection.createVirtualDisplay()` → encoder input surface | Display mirroring or a dedicated virtual display, as scrcpy does |
| Consent | System dialog **before every capture session**; a token can only create one virtual display; cached intents throw `SecurityException` (apps targeting API 34+) [verified] | None per session after ADB authorisation |
| Partial sharing | Android 14+: user can choose a **single app** or the whole screen by default [verified] | Whole display, or a per-app virtual display |
| Visibility | Android 15+: prominent status-bar chip; tap to stop [verified] | Tombolo shows its own chip/notification (by design, not by requirement) |
| Lock | Android 15+: **projection stops automatically when the screen locks** [verified] | Panel can be turned off while the device stays awake [verified, scrcpy docs]; keyguard on virtual displays needs a prototype [unverified] |
| Secure windows | `FLAG_SECURE` content is black | `FLAG_SECURE` content is black (both paths) [verified, scrcpy FAQ] |
| Foreground service | Must run a foreground service of type `mediaProjection` before obtaining the projection (API 34+) [verified] | Not applicable (helper is not an app component) |

### 2.2 Video encoding

- **Verdict: Yes (both paths).** `MediaCodec` hardware encoders for **H.264** (universal), **H.265/HEVC** (most
  devices since ~2017) and **AV1** (newer flagships) [verified, scrcpy encoder options; per-device availability
  varies]. scrcpy 4.1 added VP8/VP9 [verified].
- Encoder settings available on recent devices: `KEY_PRIORITY` (0 = real-time), `KEY_LATENCY`,
  `KEY_MAX_B_FRAMES = 0`, `KEY_REPEAT_PREVIOUS_FRAME_AFTER` (re-sends a frame when the screen is static),
  `KEY_INTRA_REFRESH_PERIOD`, and on-the-fly bitrate changes via `PARAMETER_KEY_VIDEO_BITRATE` [verified,
  Android `MediaFormat`/`MediaCodec` reference]. Note: `KEY_LOW_LATENCY` (API 30) is a **decoder** key, not an
  encoder one *(corrected after review)*. Vendor support for each key varies; Phase 0/3 tests the actual set.
- Encoders impose resolution/level limits; scrcpy works around them by downscaling and has a flag to ignore
  constraints (4.1) [verified]. Tombolo should **probe encoder capabilities** at session start and negotiate.
- Expect encoder latency in the single-digit-to-low-tens of milliseconds on modern devices [unverified — measure].

### 2.3 Input injection

| | Standard (AccessibilityService) | Enhanced (helper) |
|---|---|---|
| Verdict | **Partial** | **Yes** |
| Touch | `dispatchGesture()` (API 24+), multi-stroke gestures for multi-touch, continued strokes for drags (API 26+) — gesture-level: each gesture is planned in full, so live finger-following has latency and edge cases | Real-time touch events incl. multi-touch, hover, scroll-wheel |
| Navigation | Global actions: Back, Home, Recents, Notifications, Quick Settings, screenshot, lock screen (API 28+) | Key events |
| Text | Android 13+: an AccessibilityService can act as an **input method** (`FLAG_INPUT_METHOD_EDITOR` → `InputConnection`) for committing text [verified, `AccessibilityService.InputMethod` reference]; older: `ACTION_SET_TEXT` (replaces the field) or a Tombolo IME the user switches to | Key events and a **virtual HID keyboard/mouse (UHID)** — scrcpy's `--keyboard=uhid` gives full IME support incl. non-Latin layouts [verified, scrcpy docs] |
| Policy | Google Play: AccessibilityService requires a declaration and prominent disclosure; `isAccessibilityTool` is reserved for disability tools [verified]. Android 13+ "restricted settings" block enabling it for sideloaded apps until the user allows it [reported]. Android 17 Advanced Protection revokes it [verified/reported] | Xiaomi/HyperOS needs an extra "USB debugging (Security settings)" switch for injection [verified, scrcpy docs] |

### 2.4 Individual app windows ("app streaming")

- **Verdict: Enhanced mode only.**
- **How:** create a dedicated virtual display per Mac window, launch the chosen app onto it, encode that display
  separately. scrcpy exposes exactly this: `--new-display` with `--start-app`, and since 4.0 `--flex-display`,
  where the virtual display **resizes with the client window** [verified, scrcpy releases]. Since scrcpy 3.3,
  UHID input devices are associated with virtual displays and a mouse pointer appears on Android 15+ [verified].
- **Why not Standard mode:** a normal app can create a *private* virtual display for its own content, but placing
  *other apps'* activities on a display requires a public/trusted virtual display, which needs signature-level
  permissions granted to the shell user and system components, not to third-party apps [verified by the Android
  research agent against AOSP `android17-release`; permission names not repeated here].
- **Prior art proving it on stock phones:** AirSync and droidMirroring both run one scrcpy virtual display per
  app [verified in their sources, see 01-existing-solutions.md].
- **Open questions (Phase 0):** IME behaviour on virtual displays, apps that refuse secondary displays,
  launcher/home availability on a fresh virtual display, DPI choice, memory/thermal cost of N concurrent
  encoders, behaviour while the phone is locked, Pixel security update that broke virtual displays when desktop
  experience features are enabled (fixed in scrcpy 3.3.2) [verified] — i.e. **OEM/OS updates can break this**.

### 2.5 Keeping the phone dark / locked

- **Standard:** not possible — capture stops on lock (Android 15+) [verified].
- **Enhanced:** the helper can switch the physical panel off while mirroring continues (scrcpy
  `--turn-screen-off`) [verified]. The device is *awake and unlocked* with its panel off. Tombolo must treat any
  local interaction (power button, touch) as "end session and lock the phone". Whether apps on a virtual display
  keep running behind the keyguard is a Phase 0 question [unverified].

### 2.6 Audio forwarding

| | Standard | Enhanced |
|---|---|---|
| Verdict | **Partial** | **Yes (Android 11+)** |
| API | `AudioPlaybackCapture` (Android 10+) — requires a MediaProjection, so it shares the per-session consent [verified] | scrcpy-style capture; 5.0 captures **all audio usages** in playback-capture mode [verified]; Android 11 requires the device unlocked when capture starts [reported, scrcpy docs] |
| App opt-out | Apps can opt out (`allowAudioPlaybackCapture=false`) or be excluded by usage | Same playback-capture rules for that mode |
| Call audio | Not capturable by third-party apps (`VOICE_CALL` source is privileged) [verified, Android docs] | scrcpy 3.2 added a `voice-call` source [verified]; whether it works per device and its legality per jurisdiction are open questions [unverified] |
| Mac mic → phone call | **No** public API to inject into a cellular call uplink [unverified] | Not via the helper either [unverified] |

### 2.7 Notifications

- **Verdict: Yes** (both modes; the helper is not needed).
- `NotificationListenerService`: receive posted/removed notifications, **inline reply via `RemoteInput`**
  actions, invoke actions, dismiss (`cancelNotification`) [verified].
- **Android 15+ sensitive notifications:** notifications detected as containing one-time codes are redacted for
  listeners that don't hold `RECEIVE_SENSITIVE_NOTIFICATIONS` (signature|role; roles such as
  `COMPANION_DEVICE_WATCH`) [verified/reported]. Microsoft's Link to Windows was affected the same way [reported].
  Enhanced mode can optionally grant the app-op that lifts this [reported, Sefirah README] — **opt-in only**.
- Sideloaded installs: Android 13+ "restricted settings" require the user to allow the app before notification
  access can be granted [reported]. Installs from session-based installers (stores, the new F-Droid client) are
  treated differently [unverified per version].
- CompanionDeviceManager offers `requestNotificationAccess()` for associated apps [verified, CDM reference].

### 2.8 SMS / MMS / RCS

- **SMS: Yes; MMS: read yes, send is hard.** `Telephony` content provider (read), `SmsManager` (send, with
  per-subscription selection on dual-SIM phones), `SMS_RECEIVED` broadcast. Sending MMS needs attachment
  encoding, carrier configuration, subscription choice, temporary content URIs and delivery handling — scoped
  out of 0.2 *(added after review)*.
  Google Play allows these permissions for non-default-handler apps under an explicit exception for
  **"cross-device synchronization or transfer of SMS or calls… (such as between phone and laptop)"** — still
  subject to review [verified, Play policy, via 01-existing-solutions.md]. F-Droid/GitHub builds unaffected.
- **RCS: No direct API** for third-party apps [unverified]. Practical fallback: RCS conversations show up as
  Google Messages notifications, which Tombolo can mirror and reply to through `RemoteInput`.

### 2.9 Calls

- **Caller ID, call state, call log: Yes** (`READ_PHONE_STATE`, `READ_CALL_LOG`; Play exception as above).
- **Answer / decline / end: Partial — needs a prototype.** `TelecomManager.acceptRingingCall()` (API 26) and
  `endCall()` (API 28) with `ANSWER_PHONE_CALLS` exist but are **deprecated since API 29**; the documented
  replacement for companion apps is an `InCallService`, whose companion binding requirements must be verified
  on Android 14–17. Self-managed (VoIP) calls are separate from cellular calls *(corrected after review)*.
- **Place a call: Yes** (`CALL_PHONE`).
- **Call audio on the Mac: No in v1.** Two theoretical routes, both need research spikes: (a) the Mac acting as a
  Bluetooth Hands-Free unit to the phone — Phone Link does this on Windows; macOS's IOBluetooth hands-free
  classes exist but their state is unknown [unverified — see 03-macos-feasibility.md]; (b) shell-level
  voice-call capture (2.6), which cannot carry the Mac's microphone back into the call.

### 2.10 Clipboard

| | Standard | Enhanced |
|---|---|---|
| Mac → phone (write) | **Yes** — writing the clipboard is allowed from background | Yes |
| Phone → Mac (read) | **Limited** — Android 10+ only lets the focused app or default IME read the clipboard [verified]. Workarounds: the share sheet ("Send to Mac"), or a Quick Settings tile / button that opens a **transient focused activity** which reads the clipboard and closes (a tile by itself does not have clipboard focus) *(corrected after review)* | **Yes** — the helper can observe clipboard changes in the background (scrcpy and Sefirah do) [verified/reported] |
| Android 13+ | System shows a "copied" confirmation UI; apps can mark clips as sensitive (`EXTRA_IS_SENSITIVE`) — Tombolo should **not sync sensitive clips** by default | Same |

### 2.11 Files and photos

- **Receive into Downloads: Yes** (`MediaStore.Downloads`, API 29+, no storage permission).
- **Send from phone: Yes** via the Android share sheet (Tombolo as a share target) and Storage Access Framework
  pickers.
- **Browse phone storage from the Mac:** Standard needs `MANAGE_EXTERNAL_STORAGE` ("All files access" — Play
  restricts it; fine for F-Droid/GitHub builds) or SAF tree grants per folder; Enhanced can browse shared
  storage through the ADB file-sync protocol [verified, ADB].
- **Photos:** `READ_MEDIA_IMAGES/VIDEO` (Android 13+); Android 14+ users may grant **partial** photo access
  [verified]. Drag-out of photos from a mirrored Gallery window needs Tombolo to resolve the selected item
  (open question).

### 2.12 Background execution and connectivity

- **Foreground service required** for a persistent connection. Android 14+ requires a declared type:
  `connectedDevice` for the link, `mediaProjection` for Standard capture [verified]. Android 15 time-limits the
  `dataSync` type (do not use it for the link) [verified].
- Starting a foreground service from the background is restricted (Android 12+); **CompanionDeviceManager
  associations** grant exemptions (`REQUEST_COMPANION_RUN_IN_BACKGROUND`,
  `REQUEST_COMPANION_START_FOREGROUND_SERVICES_FROM_BACKGROUND`) and device-presence callbacks [verified, CDM
  reference]. CDM also has a `COMPUTER` device profile (`REQUEST_COMPANION_PROFILE_COMPUTER`); **which
  permissions that role grants to third-party apps is unverified** — worth a Phase 0 spike, because it could
  simplify onboarding.
- OEM battery managers kill background apps aggressively (Xiaomi, Huawei, Samsung, OnePlus…). Onboarding must
  request "unrestricted" battery and link to per-OEM guidance (dontkillmyapp.com) [reported].
- **Discovery:** `NsdManager` (mDNS/DNS-SD) to advertise/discover; a multicast lock for raw multicast.
- **Android 17:** `ACCESS_LOCAL_NETWORK` runtime permission (NEARBY_DEVICES group) for any LAN TCP/UDP,
  including mDNS, once targeting API 37; already-granted NEARBY_DEVICES permissions avoid a second prompt; the
  `NsdManager` system device picker is an alternative [verified].

### 2.13 Phone camera as a Mac webcam

- **Enhanced:** scrcpy can stream a camera (`--video-source=camera`, Android 12+) incl. torch/zoom (4.0)
  [verified]. The Mac side then needs a CoreMediaIO camera extension (see 03-macos-feasibility.md).
- **Standard:** Camera2 in a foreground service of type `camera` [verified] — workable but heavier.
- **No-code fallback:** Android 14+ USB webcam mode (UVC) on supporting devices works with Macs natively
  [reported, device-dependent].

### 2.14 Distribution and policy

| Channel | Status for Tombolo |
|---|---|
| **GitHub Releases** (+ Obtainium for updates) | Always available. Needs package registration under developer verification to install normally on certified devices once enforcement reaches the user's region (2027 globally). |
| **F-Droid** | Good fit (FOSS, reproducible builds). F-Droid re-signs apps with its own key, which conflicts with Google's ownership model; unresolved as of Oct 2026 [reported]. F-Droid shipped a rewritten client on 2026-09-24 [reported]. |
| **Google Play** | Optional. Expect review of AccessibilityService (declaration + disclosure), SMS/Call Log (cross-device exception), `MANAGE_EXTERNAL_STORAGE` (likely disallowed → use SAF in the Play flavour), and foreground-service type declarations. |
| **Developer verification** | Register the package name in the Android Developer Console. *Limited distribution* (free, no ID) caps at 20 devices — fine for testers. **Full distribution** (unlimited) costs a **one-time $25** [verified, Google support article 16640817]. |
| **Advanced Protection Mode** | Blocks sideloading (16+) and non-tool accessibility (17) [verified/reported]. Tombolo should detect it (`AdvancedProtectionManager`) and explain. |

Recommendation: ship **two build flavours** — `foss` (F-Droid/GitHub: full feature set) and `play` (feature set
adjusted to Play policy). Register the package under developer verification early.

---

## 3. Capability × path matrix

| Capability | Standard (A) | Enhanced (B/C) | Notes |
|---|---|---|---|
| Mirror whole screen | ✅ consent each session | ✅ | A stops on lock (15+) |
| Mouse/keyboard control | ⚠️ gesture-level, text via IME (13+) | ✅ full, UHID | A blocked by Advanced Protection (17) |
| Per-app windows | ❌ | ✅ (virtual displays) | Can break with OEM/OS updates |
| Phone panel off while mirroring | ❌ | ✅ (awake + unlocked) | Not Apple's locked model |
| System audio | ⚠️ needs projection consent | ✅ (11+) | Apps can opt out |
| Call audio | ❌ | ⚠️ capture only, device-dependent | Spike |
| Notifications + reply | ✅ | ✅ | OTP redaction (15+) unless opted in |
| SMS (read/send), MMS (read) | ✅ | ✅ | RCS via notifications only; MMS send later |
| Caller ID | ✅ | ✅ | |
| Answer / decline | ⚠️ deprecated API or companion `InCallService` — prototype | ⚠️ same | |
| Clipboard Mac→phone | ✅ | ✅ | |
| Clipboard phone→Mac | ⚠️ manual (share / transient activity) | ✅ automatic | |
| Files to/from phone | ✅ | ✅ (+ browse storage) | |
| Camera as webcam | ⚠️ heavy | ✅ | Needs Mac camera extension |
| Works after reboot | ✅ | ❌ restart needed | Path C restarts on-phone |
| Needs Developer options | ❌ | ✅ | Some apps object |

---

## 4. Risk register

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| A1 | Google tightens AccessibilityService further (Play policy or OS), breaking Standard-mode control | Medium | High | Keep Enhanced mode as the full-fidelity path; Standard control isolated behind an `InputProvider` interface |
| A2 | OS/OEM update breaks virtual displays or the helper (as the 2025 Pixel update did) | Medium | High | Pin and test against a device matrix; track scrcpy releases closely; degrade to single-window mirroring |
| A3 | Developer verification makes sideloaded/F-Droid installs painful in 2027 | High | High | Register package name now; ship Play flavour; document advanced flow; follow F-Droid's resolution |
| A4 | Wireless debugging instability (network changes, reboots) frustrates users | High | Medium | USB fallback; Path C self-restart; clear UI state; Android 17 auto-reconnect |
| A5 | Banking/enterprise apps refuse to run with Developer options on | Medium | Medium | Make Enhanced mode optional and reversible; explain up-front |
| A6 | OEM battery killers drop the connection | High | Medium | CDM association, battery-optimisation exemption, per-OEM guide |
| A7 | Android 17 local-network permission denied → no LAN | Medium | High | Request in onboarding with explanation; USB fallback; system picker |
| A8 | Encoder quirks (resolution limits, broken low-latency flags) on some devices | High | Medium | Capability probing, fallbacks (H.264), device quirk table |
| A9 | Security incident: helper or session abused by a LAN attacker or malicious app | Low | Critical | Mutual TLS with pinned keys; helper only accepts the Tombolo app (UID check) and authenticated Macs; visible indicators; one-tap stop |
| A10 | OTP/sensitive notifications leaked to the Mac | Low | High | Redaction respected by default; opt-in only; never log notification content |

---

## Sources

- Android Developers — Android 14 behaviour changes (MediaProjection consent):
  https://developer.android.com/about/versions/14/behavior-changes-14
- Android Developers — Media projection guide: https://developer.android.com/media/grow/media-projection
- Android Developers — Android 15 features (status-bar chip, stop on lock):
  https://developer.android.com/about/versions/15/features
- Android Developers — Android 17 behaviour changes (`ACCESS_LOCAL_NETWORK`):
  https://developer.android.com/about/versions/17/behavior-changes-17
- Android Developers Blog — Android developer verification (June 2026):
  https://android-developers.googleblog.com/2026/06/android-developer-verification.html
- Android Developers Blog — verification rolling out to all developers:
  https://developer.android.com/blog/posts/android-developer-verification-rolling-out-to-all-developers-on-play-console-and-android-developer-console
- XDA — advanced flow rollout:
  https://www.xda-developers.com/googles-controversial-advanced-flow-sideloading-rolling-out-ahead-of-stricter-developer-verification/
- Android Authority — advanced flow: https://www.androidauthority.com/google-android-advanced-flow-sideloading-rollout-begins-3700073/
- Pinggy — F-Droid 2.0 and verification: https://pinggy.io/blog/f_droid_2_0_android_developer_verification/
- Android Authority — Android 15 2FA code protection:
  https://www.androidauthority.com/android-15-two-factor-authentication-codes-3492585/
- TechRadar — Phone Link and Android 15 sensitive notifications:
  https://www.techradar.com/computing/windows/google-and-microsoft-arent-syncing-up-why-phone-link-might-no-longer-show-you-sensitive-notifications-after-installing-android-15
- Security Affairs — Advanced Protection in Android 17 and accessibility:
  https://securityaffairs.com/189497/security/advanced-protection-mode-in-android-17-prevents-apps-from-misusing-accessibility-services.html
- Android Police — Advanced Protection week test: https://www.androidpolice.com/advanced-protection-mode-week-test/
- Android Authority — APM accessibility teardown:
  https://www.androidauthority.com/android-advanced-protection-mode-accessibility-apk-teardown-3640742/
- Google Help — Advanced Protection: https://support.google.com/android/answer/16339980
- Android reference — CompanionDeviceManager: https://developer.android.com/reference/android/companion/CompanionDeviceManager
- AOSP — Companion device profiles: https://source.android.com/docs/core/connect/companion-device-profile
- AOSP — Companion App Streaming: https://source.android.com/docs/core/permissions/app-streaming
- Mishaal Rahman (Threads) — MediaProjection consent and app streaming: https://www.threads.com/@mishaal_rahman/post/C1plYfUvhno
- scrcpy — releases (4.0 flex display, 5.0 audio/hwdec): https://github.com/Genymobile/scrcpy/releases
- scrcpy — docs (virtual display, camera, audio, keyboard, develop.md): https://github.com/Genymobile/scrcpy/tree/master/doc
- Shizuku — docs: https://shizuku.rikka.app/
- Sefirah README (sensitive notifications, restricted settings): see 01-existing-solutions.md sources
- Google Play policy — SMS & Call Log, Accessibility: see 01-existing-solutions.md sources
- dontkillmyapp: https://dontkillmyapp.com/
