# Research findings — summary

Research date: **2026-10-25** (macOS 27.0.1, Android 17, scrcpy 5.0.1 current). Each report marks claims as
verified, reported or unverified, and lists its sources.

| Report | Question it answers |
|---|---|
| [01 — Existing solutions](01-existing-solutions.md) | What already exists, how it works, what's reusable, where the gap is |
| [02 — Android feasibility](02-android-feasibility.md) | What Android lets us do, through which path, since which version |
| [03 — macOS feasibility](03-macos-feasibility.md) | Video, input, networking, USB, integration and — critically — distribution on macOS |
| [04 — Transport & security](04-transport-and-security.md) | How frames, input and files should move; discovery; pairing; threat model |
| [05 — Naming](05-naming.md) | Why "Tombolo", and the 50 names that were checked |

## The ten findings that shape the plan

1. **The gap is real, but narrower than it looks.** No *free and open-source* native Mac app combines
   mirroring with continuity features. The closest product, **AirSync**, is native and capable (including
   per-app windows via scrcpy) but its licence forbids redistributing modified builds and mirroring is a paid
   add-on. **LinkMyMac** has the full feature list but is closed and paid. KDE Connect now ships an official
   macOS build, but it's Qt-based and has no mirroring. → Tombolo's differentiators: truly FOSS, native,
   per-app windows as real Mac windows, a no-developer-options tier, no paywall.
2. **scrcpy is the engine everyone builds on.** Apache-2.0, very active (5.0.1 on 2026-10-08), with virtual
   displays, resizable "flex" displays, UHID input, audio and camera. Its protocol is officially internal and
   version-locked → pin it first, fork it later.
3. **Per-app windows need shell privileges on stock phones.** Normal apps cannot put other apps on a separate
   display; Microsoft and Google get this through OEM/system privileges. → Enhanced mode.
4. **Normal-app mirroring is constrained**: consent every session (Android 14+), capture stops on lock
   (Android 15+), gesture-level input via Accessibility, which Android 17's Advanced Protection revokes. →
   Standard mode is worth building but cannot be the only tier.
5. **iPhone Mirroring's "phone stays locked" model can't be copied on Android.** Enhanced mode can keep the
   phone's display off while mirroring (device awake), which needs its own security rules (end the session on
   local use).
6. **Android 15+ hides one-time codes** from notification listeners; Android 17 requires a runtime
   **local-network permission**. Both shape onboarding.
7. **macOS distribution is the hardest non-technical problem.** Unsigned apps don't run; ad-hoc apps need
   "Open Anyway"; Homebrew disabled 627 non-notarized casks on 2026-09-01. Own taps still work. Every comparable
   FOSS Mac app pays Apple $99/yr.
8. **Android distribution is tightening too.** Developer verification is enforced in four countries since
   2026-09-30 and goes global in 2027; registering is free; F-Droid's signing model is in conflict with it.
9. **QUIC through a shared Rust core (iroh) is the recommended Wi-Fi transport**: stream isolation, datagrams for
   audio, one implementation of the security-critical code, and a path to remote use. TLS-over-TCP remains the
   proven fallback. Expected latency: ≈ 30–60 ms on USB, ≈ 40–80 ms on Wi-Fi (estimates to be measured).
10. **Pairing must be stronger than the open-source norm.** QR bootstrap with a one-time secret and pinned
    hardware-backed P-256 keys (Secure Enclave / StrongBox), PAKE for the code fallback — the design Android's
    own Wireless debugging uses. No trust-on-first-use, no short-code comparison.

## What is possible, what needs work, what is out of reach

| Already possible (proven by existing software) | Needs development or a spike | Out of reach / not planned |
|---|---|---|
| Low-latency mirroring + control (Enhanced) | Standard-mode control quality (Accessibility) | Call **audio** relay to the Mac (no public Android API; macOS hands-free role unverified) |
| Phone apps as separate windows (Enhanced) | Native Mac windows with own Dock icons (app shims) | Keeping the phone *locked* while mirroring |
| Phone audio on the Mac (Android 11+) | QUIC over the adb USB tunnel | RCS messaging beyond notification reply |
| Notifications with reply, SMS, call control | Concurrent encoder limits on mid-range phones | Capturing `FLAG_SECURE` content (banking, DRM) |
| Clipboard sync, file transfer | Battery/OEM background survival | iMessage/FaceTime or anything Apple-account-bound |
| QR pairing, mDNS discovery | Wireless-debugging self-start on the phone | Mac App Store distribution |
| | Webcam (needs paid Apple Developer ID) | |

## Unverified items carried into Phase 0

Every report ends with an explicit unverified list. The ones that change architecture are turned into Phase 0
spikes in the [implementation plan](../implementation-plan.md#phase-0--foundations-spikes--security-design-1014-ew)
(S1–S15): an optical latency harness, the Mac video pipeline, concurrent virtual displays, transport choice per
path, the iroh API surface, Standard-mode control quality, fail-closed session lifecycle, local-network
permissions, keyboard modes, UniFFI integration, background survival per OEM, the helper ↔ app relay, app-shim
viewers, virtual-display app compatibility, and permission persistence across updates.

## A note on method

Five research agents ran in parallel (landscape, Android, macOS, transport/security, naming), each with web
access, plus local tests on macOS 27.0.1 for signing/Gatekeeper behaviour. The Android report was written by
the coordinating session from official documentation after the delegated write-up failed. Nothing has yet been
tested on an Android device — that is what Phase 0 is for.
