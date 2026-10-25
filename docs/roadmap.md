# Feature roadmap

Legend — **Tier**: S = works in Standard mode (no developer options), E = needs Enhanced mode (helper via
USB/Wireless debugging), — = not tier-dependent. **Feasibility** from the research: ✅ proven by existing
software, 🟡 feasible but needs a spike, 🔴 not possible today / out of reach.

## 0.1 — Mirror (developer preview) and 0.1.x — App windows (experimental)

0.1 relies on ADB's own security (USB-debugging authorisation, Wireless-debugging TLS); Tombolo's pairing and
encryption arrive in 0.2.

| Feature | Tier | Feasibility | Notes |
|---|---|---|---|
| Mirror the phone screen in a native Mac window | E | ✅ | scrcpy-proven; VideoToolbox + Metal |
| Mouse, trackpad and keyboard control | E | ✅ | Two keyboard modes: Android-keyboard (UHID) and Mac text-commit (any Mac input method) |
| Phone audio on the Mac | E | ✅ | Android 11+ |
| Phone apps as separate, resizable Mac windows (**0.1.x, experimental**) | E | 🟡 | Virtual display per window; app-compatibility list + fallback (spike S14) |
| App launcher palette (⇧⌘A) (**0.1.x**) | E | ✅ | |
| Clipboard sync, both directions | E | ✅ | |
| Screenshots, rotation, navigation shortcuts | E | ✅ | |
| USB and Wireless debugging connections | E | ✅ | |

## 0.2 — Connect

All Tombolo channels are authenticated and scope-checked by the phone; mirroring/control still runs over the
0.1 ADB path until 0.3 (documented trust boundary).

| Feature | Tier | Feasibility | Notes |
|---|---|---|---|
| Android companion app, QR pairing, always-on link | — | ✅ | No developer options needed |
| Notifications as native Mac notifications, with reply | S | ✅ | One-time codes redacted on Android 15+ unless opted in |
| SMS conversations and sending (dual-SIM aware); MMS viewing | S | ✅ | MMS sending later; RCS only via notification reply |
| Caller ID; decline/answer/text-reply | S | 🟡 | Call-control API path to be prototyped (deprecated APIs vs companion `InCallService`); call **audio** stays on the phone |
| Drag-and-drop files both ways, share sheet | S | ✅ | Resumable, hash-verified |
| Clipboard: Mac → phone automatic, phone → Mac manual | S | ✅ | Automatic both ways in Enhanced |
| Battery/signal status, ring phone, DND sync | S | ✅ | |
| Menu bar extra | — | ✅ | |

## 0.3 — Standard mode

| Feature | Tier | Feasibility | Notes |
|---|---|---|---|
| Mirroring without developer options | S | ✅ | Android asks for consent each session; stops on lock |
| Basic control without developer options | S | 🟡 | AccessibilityService; spike S6 decides quality bar |
| Audio without developer options | S | 🟡 | Tied to the capture consent; apps can opt out |
| Seamless switch Standard ↔ Enhanced | — | 🟡 | Same session, capability-driven UI |

## 1.0

| Feature | Tier | Feasibility | Notes |
|---|---|---|---|
| Each phone app with its own Dock icon / ⌘-Tab / Spotlight entry | E | 🟡 | Locally generated app shims (Chrome PWA pattern) |
| Click a notification → app opens in its own window | E | 🟡 | |
| Touch ID before control (hardware-enforced) | — | ✅ | Secure Enclave key policy |
| Phone restarts Enhanced helper itself after reboot | E | 🟡 | Wireless-debugging self-start (Shizuku approach) |
| Auto-updates, Homebrew tap, F-Droid | — | ✅ | |

## Later (1.x)

| Feature | Tier | Feasibility | Notes |
|---|---|---|---|
| Phone camera as Mac webcam | E | 🟡 | Needs paid Apple Developer ID (camera extension) |
| Use from anywhere (outside home Wi-Fi) | — | 🟡 | Self-hosted relay; off by default |
| Call audio on the Mac | — | 🔴/🟡 | No public Android API; macOS Bluetooth hands-free role is a research item |
| LocalSend / KDE Connect / Quick Share interop | — | ✅ | Open or documented protocols |
| Multiple phones, tablets, foldables | — | ✅ | |
| Mac keyboard/mouse "flowing" onto the phone screen | E | 🟡 | |

## Explicitly not planned

- **iMessage, FaceTime or anything Apple-account-bound** — not possible for third parties.
- **A cloud service or account system** — contradicts the free/self-hosted principle.
- **Mac App Store build** — the sandbox blocks spawning `adb`/helpers and per-app shims, and complicates USB.
- **Rooted-only features** — Tombolo must work on stock phones.
- **Capturing protected content** (`FLAG_SECURE` apps such as banking or DRM video) — Android blocks it, and
  Tombolo respects that.
