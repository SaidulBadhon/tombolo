# Re-plan: Standard mode first ("install two apps")

> Status: **approved 2026-11-02** (revision 3 after two independent review rounds — see §11; maintainer decisions in §9). Not yet reflected in
> the [implementation plan](../implementation-plan.md), [roadmap](../roadmap.md) or
> [Phase 0 task plan](phase-0.md) until the tasks in §12 are applied.
>
> **Maintainer decision (2026-11-01):** the first release is the version where a user installs one app on the
> phone and one on the Mac and uses it — no Developer options, no USB/Wireless debugging. Developer-mode
> features (per-app windows, panel-off mirroring, no per-session prompt) come later as an optional *Advanced*
> setting.

## 1. Problem

The current plan ([implementation plan §1](../implementation-plan.md#1-phase-overview)) ships in this order:

| Release | Contents | Needs Developer options |
|---|---|---|
| 0.1 Mirror | Mac app drives a pinned `scrcpy-server` over a bundled `adb`; no phone app | **yes** |
| 0.1.x App windows | virtual displays, per-app windows | **yes** |
| 0.2 Connect | `tombolo-core`, Android app, pairing, notifications, SMS, calls, clipboard, files | no (mirroring still via ADB) |
| 0.3 Standard | mirroring and control without developer options | no |

The first release a typical user could adopt is 0.3. ADR-0001 already makes Standard mode the **default** tier
and Enhanced mode **opt-in**; only the delivery *order* contradicts it. This re-plan changes the order and the
contents of 0.1, not the two-tier architecture.

## 2. Decision (proposed)

| Release | Name | Contents | Developer options |
|---|---|---|---|
| **0.1** | **Mirror** | Android app + Mac app. QR pairing on the local network; Tombolo's authenticated, encrypted transport over Wi-Fi with the protocol hardening of [protocol §8](../protocol.md#8-robustness-rules). Screen mirroring via MediaProjection (fresh consent each session), **control where the device allows it** (Accessibility gestures + text input; view-only is a supported outcome per device/configuration), manual clipboard Mac → phone, phone-side Stop and revoke. | no |
| **0.2** | **Connect** | Notifications with reply, SMS, caller ID / call actions, clipboard both ways (within Android's limits), files, device status, idle/background reconnection — on the session and pairing 0.1 built. | no |
| **0.3** | **Advanced** (optional) | Enhanced mode via a shell-privileged `tombolo-helper` (scrcpy-server fork) started through Wireless debugging, set up **from the phone app** (on-device pairing, the Shizuku approach — previously "Path C" in Phase 4). Per-app windows (virtual displays), **panel-off mirroring of an awake, unlocked phone**, no per-session prompt, UHID keyboard. Media relayed through the authenticated Tombolo session. | yes, opt-in |
| **1.0** | | Hardening, external review of the implementation, fuzzing, distribution polish, app shims (if S13's open checks pass), localisation | no (Advanced optional) |

### What the user does in 0.1

1. Installs the Mac app (DMG / Homebrew) and the Android app (GitHub / F-Droid first).
2. Opens both; the Mac shows a QR code; the phone scans it. Pairing per the
   [security spec](../security/pairing-and-session.md). The phone then asks, separately from pairing, what this Mac
   may do (view, control, clipboard) — pairing never grants permanent screen control by itself.
3. One-time grants on the phone: **Accessibility** for control (Android's standard warning; sideloaded installs may
   need *Allow restricted settings* first); notification permission so the Stop control is visible in the shade (not
   required to run the service, but Tombolo keeps another Stop route — in-app and on the Mac — if it's denied);
   Android 17 targets: *local network* permission. On the Mac: Local Network, and the Application Firewall prompt
   if the Mac listens for the phone.
4. Each session: the user clicks *Mirror* on the Mac. Whether this can raise the phone's consent dialog directly is
   **unproven** (Android restricts background activity starts); the fallback is a notification on the phone that the
   user taps, then *Start* on Android's "Start recording or casting?" dialog. The phone must stay **unlocked**:
   locking ends the session (Android 15 QPR1+), and after unlocking a fresh consent is needed.
5. While mirroring, the user opens other apps **on the phone through the Mac** — Tombolo itself is in the
   background on the phone for the whole session, as a foreground service.

### Why this order is better

- It matches what the product is for; the first release is usable without developer settings.
- **No ADB mirroring path ships in 0.1 or 0.2**, so the old documented bypass — mirroring via ADB, outside
  Tombolo's phone-authoritative scopes (independent review round 2, *High*) — is gone for those releases.
  What removes it is that **all capture and input go through the phone's per-command scope enforcement**; moving
  pairing earlier alone would not.
- No bundled `adb`, no `ScrcpyBridge` and no scrcpy protocol coupling until the Advanced phase.

The Advanced phase reintroduces a platform authority that Tombolo does not control: once Wireless debugging is on,
**any** ADB-authorised controller can drive the phone, whatever Tombolo's scopes say. Relaying the helper's media
through the Tombolo session does not change that; the Advanced setup screen must say so and offer to turn
debugging off when Advanced mode is off.

### What it costs

| Cost | Detail | Mitigation |
|---|---|---|
| Per-session consent | Apps targeting API 34+ must get fresh MediaProjection consent for every capture session and may not reuse the token | Fewest possible taps; rotation and resolution changes resize the existing capture rather than starting a new one |
| No locked-phone mirroring | Projection stops on lock (Android 15 QPR1+); unlocking needs a fresh consent | The session ends cleanly with a message. Advanced mode does **not** remove this either: it allows a dark panel on an *unlocked* phone, not secure locked-phone mirroring |
| Accessibility limits | Gestures are planned strokes (not arbitrary real-time touch streams); accessibility text commit needs Android 13+ (10–12: gestures only, per §9.3); Android 13+ restricted settings for sideloaded apps; Play policy scrutiny; Android 17 **Advanced Protection** revokes non-tool accessibility services and also restricts sideloading | View-only is a supported per-device capability, not a release-wide downgrade; S6 measures every hurdle; GitHub/F-Droid distribution first (does not avoid Advanced Protection) |
| Background constraints | A network command from the Mac does not by itself allow the app to start an activity from the background | S17 proves the start flow; fallback is a tap on the phone's notification |
| Bigger first release | 0.1 needs `tombolo-core`, pairing and identity, protocol hardening, the Android app, Standard capture/input, active-session lifecycle and distribution | Accept; 0.2 becomes smaller (§5) |
| Security review gates 0.1 | Pairing ships in 0.1, so the external review (M4) gates the **first** release | See §9, question 1 — the review-before-implementation rule is a maintainer decision, not silently relaxed |
| Wi-Fi only (scope cut) | No developer options means no `adb`. A no-debugging USB path exists in principle (Android Open Accessory; NCM USB tethering works natively on macOS, RNDIS mostly doesn't) but is unproven with macOS | Phone hotspot as a workaround for client-isolated networks; S18 before 1.0 |
| Latency | MediaProjection → MediaCodec over Wi-Fi is slower than shell capture over USB | Targets = the current Phase 3 Standard targets (§3, S17); optical acceptance stays open until a camera exists |

## 3. Phase 0 changes

### Results that still apply
- **S1** harness: Mac side ready; software-timestamp numbers support development decisions, **not** optical
  acceptance (which stays open).
- **S2** Mac half: VideoToolbox decode; **AVSampleBufferDisplayLayer** recommended as the default presenter —
  Metal on `CAMetalDisplayLink` added ~24 ms *on the tested macOS 27 setup* (not yet a general result).
- **S4/S5** transport: Mac half done; phone runs outstanding and now on the critical path; transport choice stays
  provisional until they run.
- **S8** Mac, **S15** update persistence: done with blocked rows (denied-state behaviour, Accessibility persistence).
- **S10** UniFFI: Swift half done; **Android Keystore callbacks and the 30-minute soak are outstanding** and now gate 0.1.
- **S13** shims: Mac-measured, but visual checks and macOS 14 are **blocked** — not "passed"; it gates 1.0 only.
- Pairing/session spec: draft; external review outstanding.

### New spikes
| ID | Question | Pass criteria | If it fails |
|---|---|---|---|
| **S17** | **Standard capture pipeline**: MediaProjection (whole screen and single-app selection) → MediaCodec H.264 low-latency → Tombolo transport over Wi-Fi → `MirrorCore` decode → AVSampleBufferDisplayLayer. Session start from the Mac (direct activity start vs notification tap); consent cancellation; rotation as a resize of the same capture; lock → stop → fresh consent; encoder capability probing and recovery; adaptive bitrate | Motorola (Android 16), 5 GHz Wi-Fi: p50 ≤ 100 ms, p95 ≤ 180 ms in software-timestamp mode (optical pending a camera); 10 min stable at the panel's nearest supported 1080p-class size, 60 fps; every listed transition handled; phone CPU/thermals recorded. **Single-app capture input safety:** coordinates,
focus and target changes demonstrably cannot deliver input to an app the Mac cannot see — otherwise single-app
sessions are **view-only** | Lower default resolution/bitrate; relax targets only with published evidence |
| **S11a** | **Active-session survival**: foreground service of type `mediaProjection` (+ `connectedDevice` if needed) while the user drives other phone apps from the Mac; OEM battery management; permission loss mid-session; network change; process death | Session survives 30 min of normal use on the Motorola; each failure ends the session fail-closed with a reason shown on both sides | Document OEM settings; shorten sessions |
| **S18** (before 1.0) | No-debugging **USB** path: Android Open Accessory vs NCM USB tethering with macOS | One works without a kernel extension | Wi-Fi / hotspot only |

### Re-scoped spikes (now 0.1 gates)
- **S6 Standard control**: tap, drag, scroll and text in 3 popular apps; Android 13+ accessibility text commit
  (Android 10–12: gestures only, no text input — §9.3); restricted-settings flow for a sideloaded APK (F-Droid's exemption is a
  hypothesis to test); Android 17 Advanced Protection on the emulator; control latency added on top of S17.
  Outcome per device/configuration: *control* or *view-only*.
- **S7 fail-closed, in the app**: the app owns capture and injection. Every injected action re-checks, **at execution
  time** (including queued callbacks), the authenticated session, granted scopes, target display, required elevation
  and a live lease. On any event — link loss, Mac crash/sleep/lock, local takeover on the phone, Stop, revocation,
  Accessibility or projection revoked, service or process death — **already-dispatched and continued gestures, queued
  text and capture are cancelled**, not just future dispatches refused; reconnect requires fresh authorisation. The
  watchdog is tested against a blocked main thread, and the bounded shutdown is tested with **independently
  surviving components** (e.g. the Accessibility service alive while the capture service or main process is dead).
  The **1 s release deadline stays** until a separately approved change; the security draft's 1.25 s lease worst case
  must be brought under it or the change approved explicitly. **If S7 fails, control is disabled** (view-only
  everywhere) — not shipped as a documented limitation. Still required before any release that injects input.
- **S8 Android**: test Tombolo's actual bidirectional transport on an Android 17 (API 37 target) emulator — grant,
  denial, existing nearby-device grants, the system NSD picker — before deciding what denial means for onboarding.
- **S4/S5** phone runs on Wi-Fi; **S10** Keystore callbacks + 30-minute soak.

### Moved to the Advanced phase (before 0.3)
S3 virtual displays, S9 Android-keyboard (UHID) mode, S12 helper ↔ app relay, S14 app compatibility, S2's USB
phone-path measurement. Their effort is counted in §5, not dropped.

### Still before 0.2
**S11b** idle/background survival (24 h idle, Doze, reboot, wake mechanism), **S16** calls.

### Phone queue (one task at a time on the device)
S17 → S11a → S6 → S7 → S4 phone runs (Wi-Fi) → S10 Keystore → S1 end-to-end validation on S17 → S11b → S16.
S8 Android on the Android 17 emulator in parallel.

## 4. Security model changes

- Every release: mirroring and control require a Tombolo pairing **and** separate phone-granted scopes
  (`screen.view`, `screen.control`, clipboard); the phone enforces them per command and at execution time.
- Phone-side controls in 0.1: Android's projection indicator, the foreground-service notification with **Stop**
  (when notifications are allowed), Stop in the app, Stop and Revoke on the Mac. The Accessibility service injects
  nothing unless every execution-time check above passes.
- Disclosure is separate from OS consent: the phone shows which Mac is connected, whether it can view or control,
  clipboard writes, and how to stop and revoke.
- The 0.1 trust-model note (ADB exception) in the implementation plan and [architecture §8](../architecture.md) is
  removed for 0.1/0.2 and re-stated for the Advanced phase (ADB authority outside Tombolo's scopes).
- **External review:** today's documents require the review **before pairing is implemented**. Whether that stays,
  or implementation may start behind a flag with nothing shipped until the review closes (accepting rework risk), is
  open question 1 in §9.

### Protocol and security work that moves from Phase 2 into 0.1 (explicitly)
Capability negotiation; discovery and reconnect; hardware-key persistence (Secure Enclave / Keystore); revocation on
both sides; session log; bounded framing and message limits; pre-authentication resource budgets; replay and
downgrade tests; operation with outbound Internet blocked (no relays/DNS); the robustness rules of
[protocol §8](../protocol.md#8-robustness-rules) that apply to screen sessions; **baseline parser fuzzing** of the
Envelope, media header and pairing messages (continuous from the day each parser lands — broader fuzzing of the
implemented core stays a 1.0 item).

## 5. Estimates (provisional budgeting ranges, not commitments)

Moved work is counted where it now lands; Phase 0's exit gate re-estimates everything from measurements.

| Phase | Was | Proposed | Notes |
|---|---|---|---|
| 0 Foundations | 12–17 | 12–17 | partly done; S17 and S11a added, S3/S9/S12/S14 moved to Advanced (counted there) |
| → 0.1 Mirror | 10–14 (1a) | **34–50** (after §9.3) | Mac app, video, input, packaging (7–10); `tombolo-core` transport, framing, UniFFI incl. media-buffer safety (8–11); pairing, identity and the moved protocol/security work (6–9); Android app shell + service + active-session lifecycle (4–6); Standard capture, input and audio (5–7 after §9.3); fail-closed in the app (3–5); distribution and onboarding — Android signing/verification, F-Droid build, Mac install and firewall onboarding (1–2) |
| → 0.2 Connect | 26–36 | **14–20** | core, pairing and the Android app already exist; adds S11b-based background reconnection |
| → 0.3 Advanced | 12–17 (+ 4–7 for 1b) | **17–27** | helper fork + relay (5–7), on-device Wireless-debugging setup moved from Phase 4 (2–3), per-app windows (4–7), UHID keyboard (1–2), mode switching (2–3), the moved spikes S3/S9/S12/S14 (3–5) |
| → 1.0 | 10–15 | **8–12** | "Path C" moved to Advanced |
| **Total** | **74–106** | **85–126** | larger: no ADB shortcut, and the old plan under-counted lifecycle and moved spikes |

**First usable release:** Phase 0 + 0.1 ≈ **46–67 engineer-weeks from project start** (Phase 0 is partly done),
plus however long the external review takes. With two developers, very roughly 6–9 months to 0.1.

## 6. Release acceptance for 0.1 (restored from the current plan, adapted)

- Mirror and control (or view-only where S6 says so) on the Motorola plus, before release, a Pixel (Android 15–17)
  and a Samsung (One UI 7+) — the latter two are **blocked — needs hardware** until the device lab exists.
- Latency on 5 GHz Wi-Fi: p50 ≤ 100 ms, p95 ≤ 180 ms — **optical** acceptance, published (software-timestamp
  numbers alone do not pass it).
- 30-minute sustained session: no thermally-induced drop below 50 fps; phone battery drain and Mac energy recorded;
  Mac whole-process CPU ≤ 25 % of one core at 1080p60 on an M1.
- Typing matrix (English, a CJK input method, an RTL language) for the shipped text path.
- Every S7 event fails closed (tested), including in-flight gesture and text cancellation.
- Clean recovery or clean failure for Wi-Fi drop, rotation, lock, permission loss, service death.
- Security tests from the current Phase 2 list for the moved work (unknown keys, replayed/concurrent pairing secrets,
  phone-side scope checks, pre-auth budgets, no plaintext path, works with Internet blocked); baseline parser fuzzers
  run in CI with no open crashes.
- Single-app sessions: input-safety tests pass, or single-app sessions are view-only.
- Diagnostics: stats overlay labelled *estimates*, log export.

## 7. Failure modes of this plan

| If… | Then |
|---|---|
| S6 shows Accessibility control is blocked on a device/configuration | That configuration is **view-only** in 0.1, with an explanation; control there comes with Advanced (0.3) |
| S17 can't start capture from the Mac without a phone tap | One extra tap (notification) per session; documented |
| S17 misses the latency targets | Lower default resolution/bitrate; relax targets only with published evidence |
| S11a: the OEM kills the service mid-session | Fail closed with a reason; onboarding covers the OEM's battery setting |
| The external review has not closed when 0.1 is otherwise ready | 0.1 waits |
| Restricted settings block Accessibility for sideloaded installs | Onboarding walks through App info → *Allow restricted settings* |
| Networks isolate clients | Document; phone hotspot; S18 USB path before 1.0 |
| Android 17 local-network denial | Behaviour per S8 Android; onboarding explains |

## 8. Explicitly not doing

- No USB connection in 0.1 (scope cut; S18 later).
- No locked-phone mirroring in any mode (Android does not allow it securely).
- No remote access outside the local network (unchanged).
- Not removing Enhanced mode — it becomes the optional Advanced setting in 0.3.
- Not changing the licence, the pairing design or the transport decision process (ADR-0003, still provisional).
- Not deciding a Google Play flavour now (Accessibility policy risk); GitHub/F-Droid first.
- Notifications are **not** in 0.1 (0.2).

## 9. Maintainer decisions (2026-11-02)

1. **Security review gate:** pairing may be **implemented now behind a feature flag**; **nothing that contains it
   ships until the external review closes** (every finding resolved or explicitly accepted). Rework risk accepted.
   This replaces "review before implementation" in the implementation plan, ADR-0005, protocol §6 and the security
   draft.
2. **Audio in 0.1: yes** — playback capture (media/game audio, same profile, apps may opt out, never call audio).
3. **Typing: Android 13+ only.** Android 10–12 phones mirror and accept gestures but get no keyboard text input; no
   input-method fallback is built. Budget: "Standard capture, input and audio" drops from 6–9 to **5–7** ew, so 0.1
   is **34–50** ew and the total **85–126** ew.

## 10. Documents that change once this is approved

`README.md` (roadmap); [`roadmap.md`](../roadmap.md); [`implementation-plan.md`](../implementation-plan.md) (§0
order-of-value, §1, phases, spikes table and exit criteria, §2 resource schedule, §3 testing, §4 distribution, §9
decisions); [`architecture.md`](../architecture.md) (§§3–7: presenter default, service types, discovery, USB,
Enhanced startup, module phase labels; §8 security model); [`protocol.md`](../protocol.md) (§6 pairing phase
references, §8 hardening timing); ADR-0004 (pinned server becomes Advanced-only), ADR-0005 (review gate, phase
references), ADR-0006 (Android public distribution and F-Droid timing), new ADR-0008 *Standard mode first*;
[`plans/phase-0.md`](phase-0.md) (queue; tasks for S17 and S11a; re-scoped P0-06, P0-07, P0-11, P0-12; P0-05,
P0-16, P0-17 moved); the security draft's phase references; [`design/ui-concepts.md`](../design/ui-concepts.md)
(onboarding order, Stop routes).

## 11. Review log

- **Round 1 (Codex, 2026-11-02): approve with changes.** Applied:
  - corrected platform facts: lock boundary Android 15 QPR1+; Advanced does not enable locked-phone mirroring;
    gesture and text limits; API 34+ token rule; notification permission vs Stop visibility; audio capture limits;
    USB without debugging is possible in principle;
  - added active-session survival (S11a) to 0.1;
  - moved Phase 2 protocol/security deliverables into 0.1 explicitly;
  - restored capture/input detail and the release acceptance list;
  - kept optical acceptance open;
  - made S4/S5/S10 0.1 gates and fixed S13's status;
  - execution-time checks and in-flight cancellation in S7; separate disclosure from consent;
  - qualified "one trust model" for the Advanced phase;
  - turned the review gate into an explicit maintainer question;
  - re-estimated moved work (lifecycle, core, Advanced, Phase 4, moved spikes);
  - counted Phase 0 in time to first release;
  - widened the list of documents to reconcile.
- **Round 2 (Codex, 2026-11-02): approve with changes.** Applied: baseline parser fuzzing gates 0.1; single-app
  capture needs an input-safety pass or is view-only; S7 covers independently surviving components, keeps the 1 s
  deadline until a separate approval, and its failure disables control; audio limits completed (same profile,
  eligible usages); §9 questions state their budget effect. Still open: the three §9 questions.

## 12. Applying this re-plan — tasks

Five tasks, run in parallel, each in its own worktree branched from `plan/standard-first`, each owning distinct
files. **This document is the source of truth**; no task edits it. The orchestrator merges the five branches, runs
`python3 tools/check-links/check_links.py` once over the result, checks each diff against its task, and opens one PR.
Because the link checker checks links, not meaning, the orchestrator also checks the merged result for: files
changed only by their owner; the verbatim headings below; every roadmap feature in its new release; estimates that
match §5/§9 everywhere; and no stale normative wording (`git grep` for "developer preview", "Phase 1a", "0.1–0.2",
"input-method fallback", "before Phase 2 implements"). Documenting a release gate is not passing it: optical and
device-lab acceptance stay **blocked — needs hardware**.

**Rules for every task**
- Touch only the files you own. If another file needs a change, report it instead.
- Keep these headings **verbatim**, because other files link to their anchors: implementation plan
  ``### 0.C Spikes (each produces a short write-up in `docs/spikes/`)``, `## Phase 0 — Foundations, spikes & security
  design (12–17 ew)`, `## 2. Resource-loaded estimate and schedule (two developers)`, `## 6. Definition of done
  (every task)`; every numbered `##`/`###` heading in `architecture.md` and `protocol.md`; and `phase-0.md`'s
  `Prerequisites (maintainer actions)`, `Task list`, `Acceptance criteria per task` and `Execution notes (2026-10-26,
  after plan verification)`.
- The new phase headings in `implementation-plan.md` are exactly:
  `## Phase 1 — Mirror, no developer options (34–50 ew) → release 0.1`,
  `## Phase 2 — Connect (14–20 ew) → release 0.2`,
  `## Phase 3 — Advanced mode, optional (17–27 ew) → release 0.3`,
  `## Phase 4 — 1.0 (8–12 ew)`; `## Phase 5 — Beyond 1.0 (unordered backlog)` is unchanged. Link to these.
- Release names: **0.1 Mirror**, **0.2 Connect**, **0.3 Advanced**, **1.0**. "Enhanced mode" stays the technical name
  of the tier; "Advanced" is the user-facing setting and release name.
- Review logs and decision records are append-only: add entries, never rewrite past ones.
- Don't change the HTML mockups; list mockup changes as follow-ups.
- Commit with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. No push.

| Task | Owns | Depends on | Acceptance |
|---|---|---|---|
| **A1** implementation plan | `docs/implementation-plan.md` | — | Header and §0 order of value reflect §2 and §9; §1 table and every phase section match §2/§3/§5/§6; Phase 0 spikes table adds S11a/S11b (split of S11), S17, S18 and re-scopes S6/S7/S8/S10 per §3; exit criteria and gates updated (S7 fail ⇒ control disabled; 1 s deadline kept); Phase 1 acceptance = §6; the old 0.1 ADB trust-model note removed and the Advanced-phase ADB authority stated in Phase 3; §2 per-track resource table and gantt re-derived from §5 (the totals must add up); §3 testing moves baseline fuzzing to Phase 1; §4 distribution timing; §5 risks and §8 scope cuts updated; §9 records the 2026-11-01/02 decisions; §10 gets a re-plan entry pointing here |
| **A2** roadmap, READMEs, research notes | `docs/roadmap.md`, `README.md`, `apple/README.md`, `android/README.md`, `core/README.md`, `tools/README.md`, `docs/research/README.md`, `docs/research/03-macos-feasibility.md` | — | Roadmap sections become 0.1 Mirror / 0.2 Connect / 0.3 Advanced / 1.0 / Later with every feature in its new release and tier, Android 13+ typing noted, audio in 0.1; README roadmap, estimate line (85–126 ew; first release 46–67 ew from start) and any "0.1 developer preview / needs developer options" wording updated; links to the new phase anchors. Component READMEs: Mac phase, presenter (AVSampleBufferDisplayLayer default) and helper descriptions; Android starts in Phase 1, Play flavour deferred; core starts in Phase 1, pairing built behind a flag and shipped only after review; `tools/README.md` phase labels, and `latency-harness/`, `pairing-vectors/`, `signing/` listed as available. Research: dated *superseded by the 2026-11-02 re-plan* notes where a recommendation changed (pin-first-fork-later order, the old spike scope, Metal as primary presenter) — past measurements and findings unchanged |
| **A3** architecture and protocol | `docs/architecture.md`, `docs/protocol.md` | — | System diagram and tier table (presenter, helper setup from the phone app, no Mac-started helper before Phase 3); Architecture §§3–7: `ADBKit`/`ScrcpyBridge` become Advanced-only (Phase 3), presenter default AVSampleBufferDisplayLayer (measured on macOS 27), foreground-service types, discovery and USB (no USB in 0.1; S18), Enhanced startup from the phone app; §8 security model per §4 here (no ADB exception in 0.1/0.2, Advanced-phase ADB authority, execution-time checks, disclosure separate from consent); the Standard input-method fallback removed (Android 13+ text only, §9.3); the Play flavour deferred; the review-gate wording per §9.1; the `architecture.md:144` link updated to the new Phase 1 anchor. Protocol: evolution/compatibility starts in Phase 1, not Phase 2; §6: pairing implemented behind a flag, ships only after review; §8 hardening applies from 0.1; baseline fuzzing in 0.1 |
| **A4** decisions and security docs | `docs/decisions/0004-enhanced-helper.md`, `docs/decisions/0005-pairing-and-identity.md`, `docs/decisions/0006-distribution.md`, new `docs/decisions/0008-standard-mode-first.md`, `docs/decisions/README.md`, `docs/security/pairing-and-session.md`, `docs/security/review-request.md`, `SECURITY.md` | — | New ADR-0008 (Accepted, 2026-11-02) records the decision, alternatives, consequences and §9; ADR-0004: pinned server/helper is Advanced-only; ADR-0005: review gate per §9.1 and phase references; ADR-0006: Android public distribution needed for 0.1 (GitHub/F-Droid first, Play deferred); README index lists 0008; security draft and review request: "implemented behind a flag, nothing ships until the review closes", ADB path out of scope only as the Advanced phase's platform authority, no "0.1–0.2 ADB" wording left (also in `SECURITY.md`). Security spec lease (§10 there): worst case brought under the 1 s release deadline (e.g. a shorter lease period), no elevation retained after a lease timeout, reconnect needs fresh authorisation, in-flight gesture/text/capture cancellation and the independent-component requirement from §3 here — all marked *to be confirmed by S7*; record the change in its departures/changes list |
| **A5** Phase 0 task plan, spikes index, UI concepts | `docs/plans/phase-0.md`, `spikes/README.md`, `docs/design/ui-concepts.md` | — | Phase 0 plan: new tasks **P0-19 (S17)** and **P0-20 (S11a)** with owned paths, dependencies, estimates and acceptance criteria; P0-06 (S6), P0-07 (S7), P0-08 (now S11b), P0-11 (S8 Android), P0-12 (S10 Keystore + soak) re-scoped per §3; P0-05, P0-16, P0-17 and S2's USB phone path moved to the Advanced phase (kept, marked "moved"); new phone queue per §3; status of finished tasks (P0-01–04, P0-10, P0-12 Swift half, P0-13, P0-14 Mac half, P0-15 Mac half — merged 2026-11-02) recorded; toolchain note (Gradle and Kotlin still needed; JDK is keg-only); P0-03's "no implementation before review" replaced per §9.1; P0-18's dependency limited to the Phase 1 gates (moved Advanced/Connect spikes don't gate it) and its Phase 1a wording updated; waves, developer allocations and the estimate total recomputed; S11b and S16 placed before 0.2, S18 before 1.0. `spikes/README.md`: the spike inventory matches the new table. UI concepts: onboarding order for 0.1 (QR pairing, then per-Mac permissions, Accessibility, consent per session), Stop routes, Advanced as an optional setting; mockup follow-ups listed |
