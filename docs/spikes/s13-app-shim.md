# S13 — App-shim viewer (per-app Dock, ⌘-Tab and Spotlight entries)

| | |
|---|---|
| **Spike** | S13 |
| **Task** | P0-13 — see the [Phase 0 task plan](../plans/phase-0.md#acceptance-criteria-per-task) |
| **Pass criteria** | [§0.C](../implementation-plan.md#0c-spikes-each-produces-a-short-write-up-in-docsspikes): "one generated `.app` owning an `NSWindow`, frames via IOSurface/XPC from the main app — works across app restarts and an update; acceptable TCC prompts" (if it fails: defer shims, per-app windows stay in the main app). P0-13: "a generated `.app` shim with its own bundle ID and icon that owns an `NSWindow` and displays frames sent by a host app over XPC (IOSurface); survives host restart and a host update; TCC prompts recorded; Dock / ⌘-Tab / Spotlight behaviour verified on macOS 14 and 27" |
| **Spike code** | [`spikes/s13-app-shim/`](../../spikes/s13-app-shim/README.md). Measurement run 2 and every lifecycle, update, integration and security run used host and shim sources at `22f76b4966a8eae715e50da6dfaa9c4ea68c6b91`. **Measurement run 1 predates the first commit:** its host was built from the working tree later committed as `88b1af43b39a524fa7d63e1dc18775a292e89475` (no source edits in between, per the session's edit history), and in m1–m3 the Chat/Maps shims still ran a binary generated during the smoke test from earlier, uncommitted source (source not kept; per the edit history it differed only in when a shim relaunches the host and in first-launch window placement). `git diff 88b1af4 22f76b4 -- spikes/s13-app-shim/Sources` shows CShimIPC, ShimCommon, Renderer and the shim unchanged — identical IPC and render code; only the host's shim-version keying changed |
| **Author(s)** | Claude (agent), for the maintainer |
| **Date(s) run** | 2026-10-26 |
| **Status** | draft — verdict rows are still blocked (visual checks, macOS 14), the timings are provisional, and re-runs are pending (see [Verdict](#verdict) and [Re-runs pending](#re-runs-pending)) |

## Question

Can Tombolo give each mirrored Android app its own Dock icon, ⌘-Tab entry and Spotlight entry by generating
small local `.app` shims (Chrome's PWA pattern), where each shim owns its window and shows frames the main app
sends it — robustly across host restarts and host updates, without Xcode, paid signing or new TCC prompts? Phase 4's
`AppShims` module ([architecture §3.1](../architecture.md#31-modules-swift-packages-inside-one-xcode-project)) is
built only if this passes; the alternative is per-app windows inside the main app
([research §5](../research/03-macos-feasibility.md#per-app-dock-icons-cmd-tab-entries-and-spotlight-entries),
risk #13 in the [risk register](../research/03-macos-feasibility.md#risk-register)).

## Setup

**Devices**

| Role | Model | OS version and build | OEM skin / version | Notes |
|---|---|---|---|---|
| Phone | none — frames are synthetic | — | — | not needed for this question |
| Mac | MacBook Pro 14" (Mac16,8, Apple M4 Pro, 12 cores: 8P + 4E), built-in Liquid Retina XDR (ProMotion) | macOS 27.0.1 (26A434) | — | the maintainer's everyday machine, logged in, Spotlight indexing on |

**Builds and tools**

| Component | Version / commit | How obtained |
|---|---|---|
| Spike code | see header | this repository |
| Swift | 6.4 (swiftlang-6.4.0.34.1), SwiftPM, tools-version 5.10 manifest | Command Line Tools (no Xcode) |
| Signing | ad-hoc (`codesign -s -`), hardened runtime, no Team ID | `/usr/bin/codesign` |
| Icons | rendered with Core Graphics, packed with `/usr/bin/iconutil` | base system |

**Environment:** no network involved. **Every measurement ran on a heavily loaded Mac, which breaks the Phase 0
execution rule "performance measurements never run while other heavy jobs load the Mac"**
([execution notes](../plans/phase-0.md#execution-notes-2026-10-26-after-plan-verification)). The load: other Phase 0
agents compiling Swift and Rust, Spotlight indexing, and a Virtualization.framework VM at 171–187 % CPU in run 2
(`top`'s second sample in each `results/m*.txt`; run 1 has no valid per-process sample because its `top` call kept
the first sample, which is all zeros). 1-minute load averages at the start of each run were 10–46 (run 1) and 22–30
(run 2). **All timing and CPU numbers in this document are therefore provisional;** a re-run on a quiet Mac is
scheduled ([Re-runs pending](#re-runs-pending)). During measurement run 2 the user was in a full-screen app, so shim
windows were on another Space (`onscreen=0`) and not composited on the visible display.

## Method

All commands are in [`scripts/experiments.sh`](../../spikes/s13-app-shim/scripts/experiments.sh); the README lists
them. Raw output is in [`results/`](../../spikes/s13-app-shim/results/).

**1. Choosing the IPC (probe [`probes/probe_ipc.c`](../../spikes/s13-app-shim/probes/probe_ipc.c)).** Between two
processes that launchd did *not* start as a job (two ordinary apps):

| Mechanism | Result on macOS 27.0.1 |
|---|---|
| `xpc_connection_create_mach_service(name, …, LISTENER)` in an app | **fails** — listener gets `Connection invalid` |
| same, after claiming the name with `bootstrap_check_in` first | **fails** — `Connection invalid` |
| `bootstrap_check_in` of a dynamic name + `bootstrap_look_up` + raw `mach_msg` | **works**; the name disappears when the owner's receive right dies (lookup → 1102 "Unknown service name") |
| LaunchAgent with `MachServices`, `launchctl bootstrap gui/$UID`, XPC listener in the job | **works** (launchd starts the job on demand); `sfltool dumpbtm` showed no Background Task Management record for a plist outside `~/Library/LaunchAgents`; booted out afterwards |

Source of this table: terminal output in the agent session, **not kept** (the `/tmp` files were deleted by cleanup).
The probe's header lists the commands that reproduce it.

Chrome on this Mac uses the third mechanism for its PWA shims: `launchctl print gui/501` listed
`com.google.Chrome.apps.<hash>` as an unmanaged (`U A`) dynamic service. An installed Chrome web app
(`~/Applications/Chrome Apps.localized/<name>.app`) is ad-hoc signed with hardened runtime, carries only
`com.apple.provenance` (no quarantine) and is `rejected` by `spctl`, yet launches normally. (Source not kept:
terminal output only.)

**Chosen design (Chromium's):** the host claims `io.github.saidulbadhon.Tombolo.spike-s13.ipc` with
`bootstrap_check_in`; shims look it up; everything else is raw Mach messages. **Frames are IOSurfaces passed as Mach
port rights** (`IOSurfaceCreateMachPort` / `IOSurfaceLookupFromMachPort` — public API): in *ring* mode a ring of
three surfaces is sent once per session and each frame message only names a slot; in *per-frame* mode every frame
message carries a fresh port right. The shim sets `CALayer.contents = IOSurface` (zero-copy), flushes the
transaction and acks; an ack frees the previously displayed slot, and the host skips a frame if no slot is free
(latest-frame-wins, never blocks). Dead-name notifications detect a dead peer; `notify(3)` wakes waiting shims when a
host starts. The host verifies each hello's Mach audit token against `identifier "<bundle ID>" and cdhash H"<cdhash
recorded at generation>"`; every later message must carry the same audit token. The shim checks the host against
`identifier "io.github.saidulbadhon.Tombolo.spike-s13.host"`. Rejected alternative: a LaunchAgent broker handing out
XPC endpoints — it works, but adds a persistent launchd job tied to the host's path and signature, a broker process
and cleanup, for no gain the Mach path lacks (XPC's code-signing-requirement API has an audit-token equivalent).
XPC was therefore **not run** as the frame transport. This deviates from the plan's wording "over XPC" (same
IOSurface zero-copy, different transport); the deviation goes to P0-18.

**2. Shim generation** (host, at runtime): `~/Applications/Tombolo Apps/<Name>.app` with
`CFBundleIdentifier = io.github.saidulbadhon.Tombolo.shim.<package>` (`_` → `-`), the shim executable **copied as
bytes** (not `copyItem`, which would copy a quarantine flag), Info.plist (package, host bundle ID, service name,
shim build = host version + SHA-256 prefix of the template), a generated `.icns`, then
`codesign --force --sign - --identifier <bundle ID> --options runtime`, `FileManager.replaceItemAt` (atomic swap),
`LSRegisterURL`, and the bundle's cdhash recorded in `shims.json`. The host launches shims with
`NSWorkspace.openApplication(at:)`.

**3. Measurements** (`experiments.sh measure`, run twice, both under heavy load — provisional): host launched via `open -g` for 20 s; latency stats cover
the 18 s after a 2 s warm-up; CPU = `ps` CPU-time delta over an 11 s window ÷ wall time (100 % = one core).
Timestamps: `CLOCK_UPTIME_RAW` (shared by all processes). *receive* = host stamp just before `mach_msg` send → shim
just after receive (main-thread dispatch source); *commit* = host send → shim after `CATransaction.flush()`. Commit
is **not** on-glass: WindowServer still composites on its next refresh; glass-to-glass belongs to the S1 harness.
Host CPU is dominated by drawing the synthetic frames with Core Graphics (in the product the decoder's
IOSurface-backed buffers would be passed instead); the per-frame vs ring difference isolates the IPC cost.
WindowServer CPU was sampled too but is **not attributable**: with nothing of ours running it swung between 0.4 %
and 42 % in 5 s baselines.

**4. Lifecycle, update, integration, security** (`restart`, `coldstart`, `update`, `integration`, `security`,
`quarantine`): see Raw numbers. Timings come from log lines, prefixed with uptime ms, measured from the shell's
`CLOCK_UPTIME_RAW` at the moment of `kill` / `open`.

**5. Window evidence:** `tools/winlist` (`CGWindowListCopyWindowInfo`) shows which process owns which window;
`screencapture -x -o -l<windowID>` captured shim windows (the terminal already held Screen Recording;
`CGPreflightScreenCaptureAccess()` returned true without prompting) — this works for windows on another Space.

**6. TCC and Gatekeeper:** `log show` over the whole session (01:20 → 03:45) for `tccd` and `syspolicyd`, grouped
per request (service, preflight flag, result) — [`results/tcc-summary.txt`](../../spikes/s13-app-shim/results/tcc-summary.txt).

**Physical steps that needed a person:** none were performed. Everything visual or interactive is listed under
[Manual checks](#manual-checks-needs-a-person).

**Known sources of error:** heavy background load (stated per run; timings provisional); one Mac, one OS version; the synthetic
input self-test calls `NSWindow.sendEvent` with constructed `NSEvent`s, which exercises the shim's handlers and the
IPC but not HID delivery; run-2 windows were not on the visible Space.

## Raw numbers

### Frame delivery latency (ms), per shim, 60 fps target — provisional (measured under load)

Files: [`results/m*.txt`](../../spikes/s13-app-shim/results/m1-ring-2x60-720x1560.txt) (run 2, load 22–30) and
[`results/run1/`](../../spikes/s13-app-shim/results/run1/m1-ring-2x60-720x1560.txt) (run 1, load 10–46). n ≈ 1020–1090
frames per shim per run.

| Condition | Run | receive p50 | receive p95 | receive p99 | commit p50 | commit p95 | commit p99 | worst max | fps achieved |
|---|---|---|---|---|---|---|---|---|---|
| m1 ring, 2 shims, 720×1560 | 1 | 0.046–0.047 | 0.070–0.072 | 0.090–0.109 | 0.182–0.196 | 0.286–0.291 | 0.363–0.365 | 10.5 | 60.0 |
| | 2 | 0.049–0.054 | 0.076–0.079 | 0.089–0.093 | 0.183–0.190 | 0.261–0.288 | 0.318–0.389 | 7.8 | 60.0 |
| m2 per-frame port, 2 shims, 720×1560 | 1 | 0.057–0.058 | 0.092–0.094 | 0.114–0.121 | 0.353–0.358 | 0.578–0.581 | 0.669–0.676 | 4.7 | 60.0 |
| | 2 | 0.064–0.068 | 0.088–0.102 | 0.115–0.117 | 0.363–0.370 | 0.466–0.488 | 0.538–0.556 | 8.8 | 60.0 |
| m3 ring, 1 shim, 1080×2400 | 1 | 0.046 | 0.066 | 0.083 | 0.192 | 0.269 | 0.326 | 0.5 | 60.0 |
| | 2 | 0.052 | 0.082 | 0.093 | 0.189 | 0.285 | 0.322 | 0.8 | 60.0 |
| m4 ring, 4 shims, 720×1560 | 1 | 0.041–0.046 | 0.065–0.079 | 0.088–0.123 | 0.167–0.197 | 0.258–0.339 | 0.326–0.466 | 7.5 | 60.0 (0–1 frames skipped) |
| | 2 | 0.049–0.057 | 0.076–0.093 | 0.104–0.125 | 0.181–0.223 | 0.263–0.370 | 0.346–0.496 | **256** | 58.5–60.0 (26–28 skipped per shim) |

The 256 ms outlier (m4 run 2, at load ≈ 30) hit two shims at the same moment; the flow control skipped frames at
the source instead of queueing them, and the stream continued.

### CPU (% of one core, 11 s window) — provisional (measured under load)

| Condition | Run | Host (renders synthetic frames) | Each shim | WindowServer during / idle baseline |
|---|---|---|---|---|
| m1 ring 2×60 | 1 / 2 | 16.9 / 19.7 | 1.4 / 1.4 | 44.8 / 46.1 vs 11.5 (not attributable) |
| m2 per-frame 2×60 | 1 / 2 | 23.6 / 19.1 | 2.5 / 2.4 | 28.8 / 45.3 vs 42.4 |
| m3 ring 1×60 1080×2400 | 1 / 2 | 18.0 / 18.8 | 1.4 / 1.4 | 46.3 / 12.5 vs 0.8 |
| m4 ring 4×60 | 1 / 2 | 43.1 / 41.8 | 1.3–1.4 / 1.4–1.6 | 46.8 / 45.0 vs 0.4 |

IOSurface memory per 720×1560 ring: 3 × 4.5 MB = 13.5 MB, shared by host, shim and WindowServer (no copies).

### Generation and launch

| Measure | Value | Source |
|---|---|---|
| Generate one shim (bundle + icon + `codesign` + `LSRegisterURL`) | median 171 ms, 156–177 ms (n = 15) | [`results/excerpts.txt`](../../spikes/s13-app-shim/results/excerpts.txt) |
| Shim bundle size | 620 KB (252 KB executable, 356 KB `.icns`) | `du` |
| `openApplication` → first frame on the layer, bundle generated in an earlier run | 134–273 ms (n = 12) | `launchToFirstCommitMs` in `results/m*.json` and `results/run1/m*.json` |
| Same, first launch of a bundle (re)generated in the same run | 358–1036 ms (n = 6); the four above 0.7 s were part of a 4-shim batch | idem; generation events in [`results/session-logs/host.log`](../../spikes/s13-app-shim/results/session-logs/host.log) |

### Host restart and crash — [`results/restart.txt`](../../spikes/s13-app-shim/results/restart.txt), [`results/coldstart.txt`](../../spikes/s13-app-shim/results/coldstart.txt)

| Event | Shim behaviour | Timing |
|---|---|---|
| Host graceful quit (SIGTERM) | both shims: "Disconnected — host quit. Waiting for Tombolo…", last frame kept, dimmed ([capture](../../spikes/s13-app-shim/results/chat-disconnected.png)) | detected 25 ms after SIGTERM |
| Host relaunched | both reconnect automatically (notify(3)) | 6 ms after the new host claimed the name (host claimed it 140 ms after `open`) |
| Host crash (SIGKILL) | both: "host went away" via dead-name notification; launchd shows 0 entries for the name | detected 26 ms after SIGKILL |
| Host relaunched after crash | both reconnect | 5 ms after the name was claimed; 194 ms from disconnect to reconnect incl. host launch |
| Shim crash (SIGKILL Chat) | host ends that session (dead-name); Maps unaffected (0 disconnects) | 27 ms |
| Chat relaunched via `open -b <bundle ID>` (as from Dock/Spotlight) | reconnects | 174 ms after `open` |
| Second host instance | `bootstrap_check_in` = 1100 (`BOOTSTRAP_NOT_PRIVILEGED`, name owned by another process) → exits 3 | — |
| **Cold start:** shim opened while no host runs | shim launches the host via LaunchServices (`--launched-by-shim`), connects; the host launches no other shims | host launch requested 172 ms, session up (config received) 278 ms after `open -b` |

### Host update — [`results/update.txt`](../../spikes/s13-app-shim/results/update.txt)

| Step | Result |
|---|---|
| Host v1 → v2 rebuilt in place (CFBundleVersion 1 → 2) | host cdhash `2e5c19eb…` → `05463abe…` (different ad-hoc signature) |
| v1 shims connect to v2 host | cdhash pins still match (shims unchanged) → host sends restart-for-update |
| Shim quits, host regenerates bundle in place and relaunches it | Chat cdhash `8aa6157a…` → `0789c132…`, Maps `50029577…` → `3fbfdd5b…`; request → v2 shim streaming in **773 ms**; LaunchServices reports `Version="2"`; no quarantine |
| v3 host with `--no-update-shims` | v2 shims connect and stream unchanged (protocol compatible across versions) |

Found while testing: regenerating only on a version bump left stale shim code running after a rebuild with the
same version; the shim build ID now includes a hash of the template executable.

### Dock / ⌘-Tab / Spotlight / windows — [`results/integration.txt`](../../spikes/s13-app-shim/results/integration.txt)

| Check | Result |
|---|---|
| `lsappinfo info <bundle ID>` for each running shim | own ASN, own `bundleID`, bundle path in `~/Applications/Tombolo Apps`, **`type="Foreground"`** (the class that gets a Dock tile and a ⌘-Tab entry), `parentASN="Tombolo Host"` |
| Windows (`winlist`) | Chat, Maps and the host each own their own window (separate owner PIDs) |
| Frames on screen | captures [#195](../../spikes/s13-app-shim/results/chat-connected-1.png) → [#237](../../spikes/s13-app-shim/results/chat-connected-2.png) moments apart; [Maps](../../spikes/s13-app-shim/results/maps-connected.png); also captured from another Space |
| Spotlight, brand-new shim, **no `mdimport`** | found by `kMDItemCFBundleIdentifier` **4.6 s** after generation, also by `kMDItemDisplayName`; `kMDItemKind = Application`, `kMDItemContentType = com.apple.application-bundle` |
| Input forwarding (self-test: mouse down/drag/up, key down/up "a", scroll through `NSWindow.sendEvent`) | all six events logged by the host with normalised coordinates; shim→host 0.05–0.25 ms (smoke test, [`results/excerpts.txt`](../../spikes/s13-app-shim/results/excerpts.txt)) |
| Window placement | a shim launched while the user is in a full-screen app opens on a desktop Space (`onscreen=0`) |

### Gatekeeper, quarantine, signatures — [`results/integration.txt`](../../spikes/s13-app-shim/results/integration.txt), [`results/quarantine.txt`](../../spikes/s13-app-shim/results/quarantine.txt)

| Check | Result |
|---|---|
| xattrs on generated shims | only `com.apple.provenance` — **no `com.apple.quarantine`** |
| `codesign --verify --strict --deep` | valid, satisfies its designated requirement; `flags=0x10002(adhoc,runtime)`, no Team ID |
| `spctl -a -t exec` | `rejected` (expected for ad-hoc) — irrelevant because nothing is quarantined; every launch succeeded with no dialog |
| syspolicyd log | records provenance at first launch of each shim; no block |
| Template inside a "downloaded" (quarantined) host | `cp` keeps the quarantine flag; the generator's byte copy produces a shim **without** it |

### Security of the rendezvous — [`results/security.txt`](../../spikes/s13-app-shim/results/security.txt)

| Attack | Result |
|---|---|
| Bare template binary claims to be `com.example.chat` | rejected (`errSecCSReqFailed` −67050: wrong identifier and cdhash) |
| Copy of `Chat.app`, Info.plist edited, re-signed ad-hoc **with the same identifier** | rejected (cdhash differs from the pin) |
| Same-user process claims the name while the host is down | **claimed the name** (`bootstrap_check_in` = 0). A waiting shim's hello arrived but was discarded: the probe's receive buffer was smaller than a hello (`0x10004004` `MACH_RCV_TOO_LARGE`), so receiving the hello — and the send right to the shim's port it carries — is **inferred**, not observed. A re-run with a 4 KB buffer is prepared (`probe_ipc bs-squat`, [Re-runs pending](#re-runs-pending)). The shim sends no input before a CONFIG passes its host check, but that check is an ad-hoc `identifier` match, which anyone can forge |

### TCC — [`results/tcc-summary.txt`](../../spikes/s13-app-shim/results/tcc-summary.txt)

| Requests naming the host or a shim, whole session | Result |
|---|---|
| `kTCCServiceListenEvent`, `PostEvent`, `ScreenCapture`, `DeveloperTool` | all **`preflight=yes`** (AppKit / WindowServer launch-time checks that never prompt) |
| `appleeventsd` → `TCCCreateDesignatedRequirementIdentityFromAuditTokenForService` | identity lookup at launch, not an access request; tccd notes the hardened runtime lacks `automation.apple-events`, so any Apple Events access would be refused without a prompt |
| 1 × `kTCCServiceSystemPolicyAllFiles`, `preflight=no`, denied | from the impostor test (template binary run from the terminal; TCC subject = the terminal app), not from a generated shim |
| Prompt UI (`UserNotificationCenter`, `universalAccessAuthWarn`, "prompting user") | 0 lines |

## Verdict

| # | Criterion (as written in the plan, split into what was measured and what was not) | Verdict | Evidence |
|---|---|---|---|
| 1 | A generated `.app` shim with its own bundle ID and icon: bundle, bundle ID and `.icns` generated and registered with LaunchServices | pass | [`results/excerpts.txt`](../../spikes/s13-app-shim/results/excerpts.txt) (generation), `lsappinfo` and `mdls` in [`results/integration.txt`](../../spikes/s13-app-shim/results/integration.txt) |
| 2 | The generated icon looks right in the Dock and ⌘-Tab | blocked — needs a person (M1, M2) | nobody looked |
| 3 | …that owns an `NSWindow` and displays frames sent by a host app | pass | `winlist` (separate owner PIDs), captures with an advancing frame counter, 60 fps in all runs |
| 4 | …over XPC (IOSurface) | not run | XPC was not used as the frame transport: an XPC listener needs a launchd job (probe), so IOSurface Mach rights over a dynamic bootstrap name were used instead — a deviation for P0-18 |
| 5 | IOSurface frames delivered zero-copy over the transport actually used (Mach messages) | pass | latency tables (receive p95 ≤ 0.10 ms, commit p95 ≤ 0.58 ms; provisional, measured under load) |
| 6 | Survives host restart | pass | graceful quit, crash, relaunch, cold start, shim crash ([`restart.txt`](../../spikes/s13-app-shim/results/restart.txt), [`coldstart.txt`](../../spikes/s13-app-shim/results/coldstart.txt)) |
| 7 | Survives a host update | pass | v1 → v2 with a new ad-hoc cdhash: shims restart, regenerate, reconnect in 0.8 s; v3 compatibility ([`update.txt`](../../spikes/s13-app-shim/results/update.txt)) |
| 8 | TCC prompts recorded | pass | no prompts: only preflight queries, 0 prompt-UI events ([`tcc-summary.txt`](../../spikes/s13-app-shim/results/tcc-summary.txt)) |
| 9 | Spotlight indexes the shim on macOS 27 | pass | found by bundle ID and display name 4.6 s after generation, without `mdimport` |
| 10 | The shim appears in the Spotlight UI and launches from it on macOS 27 | blocked — needs a person (M3) | nobody looked |
| 11 | LaunchServices registers each running shim as its own foreground app on macOS 27 | pass | `lsappinfo`: separate ASNs, `type="Foreground"` |
| 12 | Each shim has its own Dock tile and ⌘-Tab entry on macOS 27 | blocked — needs a person (M1, M2) | only inferred from row 11 (`Foreground` is the class that gets a Dock tile and a ⌘-Tab entry); nobody looked |
| 13 | Dock / ⌘-Tab / Spotlight behaviour on macOS 14 | blocked — needs a macOS 14 machine | — |
| 14 | (brief) Input forwarding: synthetic events dispatched through `NSWindow.sendEvent` reach the host | pass | [`results/excerpts.txt`](../../spikes/s13-app-shim/results/excerpts.txt) |
| 15 | (brief) Real mouse, keyboard and trackpad input reaches the host | blocked — needs a person (M5) | — |
| 16 | (brief) No Gatekeeper or quarantine for locally created shims | pass | xattrs, launches without a dialog, quarantine-propagation test |

**S13 overall:** the §0.C criteria that could be run on macOS 27.0.1 — works across restarts and an update,
acceptable TCC prompts (there were none) — **pass**, with provisional timings. The result stays **draft**: the
visual Dock/⌘-Tab/Spotlight rows and macOS 14 are blocked, "over XPC" was not run (deviation for P0-18), and the
quiet-Mac and squatting re-runs are pending. Nothing measured so far triggers the fallback.

**Coverage:** macOS 14 (the minimum version) not run. Only one Mac (M4 Pro). Not tested at all: Stage Manager
grouping, Mission Control, notification attribution per shim, Dock pinning across regeneration, multiple displays,
battery/energy impact.

## Manual checks (needs a person)

Do these with the spike built (`spikes/s13-app-shim/scripts/build.sh`), then `open "out/Tombolo Host.app"`; finish
with `scripts/cleanup.sh`.

1. **⌘-Tab:** with Chat and Maps running, hold ⌘-Tab. Expected: separate "Chat" and "Maps" entries with their
   letter icons, plus "Tombolo Host". Selecting one brings its window forward.
2. **Dock:** check that Chat and Maps each have their own running tile with the generated icon (coloured squircle,
   white letter, phone outline). Note how macOS 27 frames a legacy `.icns`: is it placed inside a grey squircle?
3. **Spotlight UI:** press ⌘-Space and type "Chat". Expected: Tombolo's Chat appears under Applications, beside
   any real app of that name. Open it with the host quit. Expected: the host starts and frames appear in about 0.3 s.
4. **Pinning across an update:** right-click Chat's tile → Options → Keep in Dock. Quit everything, run
   `scripts/build.sh 2`, then open the host. Expected: the shim is regenerated and restarts. Check whether the
   pinned tile still launches Chat and still shows its icon. Restore with `scripts/build.sh 1`.
5. **Real input:** click, drag, scroll (trackpad, with momentum) and type in a shim window. Expected: one
   `event … kind=…` line per action in `~/Library/Application Support/Tombolo-spike-s13/logs/host.log`, with
   coordinates in 0…1 and the origin at top-left.
6. **Smoothness:** watch the moving bar and checker band for 30 s in each shim. Note any tearing, stutter, or a
   stale frame showing through.
7. **Stage Manager and Mission Control:** turn on Stage Manager. Check whether each shim gets its own group. In
   Mission Control, check that the windows are labelled with the shim names.
8. **Full-screen Spaces:** while a full-screen app is in front, launch a shim. Note which Space its window opens
   on (here it opened on a desktop Space).
9. **macOS 14:** on a macOS 14 Mac, run `scripts/build.sh && scripts/experiments.sh all`, then steps 1–8.
10. *(Optional)* **Quarantined shim:** add a quarantine flag to a generated shim
    (`xattr -w com.apple.quarantine "0083;$(printf %x $(date +%s));Safari;" ~/Applications/Tombolo\ Apps/Chat.app`)
    and open it. Expected: Gatekeeper blocks it. This confirms why the generator must never copy extended attributes.

## Re-runs pending

1. **Measurements on a quiet Mac** (no other agents, no VM; windows on the visible Space):
   `scripts/build.sh && scripts/experiments.sh measure`. Scheduled; it replaces the provisional timing and CPU
   numbers.
2. **Squatting with a large buffer:** `scripts/build.sh && scripts/experiments.sh security`. Step 3 now uses
   `probe_ipc bs-squat` (4 KB buffer), which reports the received message's ID, size and reply right. It is
   prepared but not yet compiled or run. Expected: `receive = 0`, `msgh_id=1000`, `reply_right=yes`.
3. **macOS 14:** the whole suite (manual check 9).

## Consequences for the plan

- **Phase 4 can build `AppShims`; the fallback (per-app windows inside the main app) is not triggered.** Keep it as
  a user setting regardless ("Show phone apps as separate Mac apps"), because shims put files into
  `~/Applications` and Spotlight.
- **Transport wording:** [architecture §3.1](../architecture.md#31-modules-swift-packages-inside-one-xcode-project)
  says "IOSurface over XPC". Change it to "IOSurface Mach rights over a dynamic bootstrap name (Chromium app-shim
  pattern); LaunchAgent + XPC broker as fallback". Owner: P0-18 (that file is outside this task's paths).
- **Security input for P0-03 / P0-10:** the host-side pin (ad-hoc cdhash recorded at generation, checked against
  the audit token of every message) held against impostors. The shim-side check of the host is weak with ad-hoc
  signing. A same-user process can claim the name while Tombolo is not running (observed), and would then receive
  a waiting shim's hello (inferred; the re-run is pending). Production shims must check
  the host against a **stable identity** (`certificate leaf = H"…"` from P0-10's self-signed identity, or a Team
  ID once paid). They must send no input until that check passes. Add "name squatting / fake host harvesting input
  from shim windows" to the threat model.
- **Design rules for Phase 4**, all learned here:
  - Copy the template as bytes, never with xattrs.
  - Key shim freshness on a hash of the shim code, not on the version.
  - Use a restart-for-update message and regenerate shims in place (about 170 ms each, about 0.8 s visible gap).
  - Pin shims by cdhash.
  - One bundle path per package and phone. Renaming an app must move the bundle: the spike produced two bundles
    with one bundle ID when a name changed.
  - Only a cold-start shim may launch the host. After a disconnect it must just wait.
  - Choose a Space policy for windows opened while a full-screen app is in front.
  - Render phone icons onto the macOS icon grid.
- **Ring vs per-frame:** sending a port right per frame roughly doubles commit latency (p50 0.19 → 0.36 ms) and
  shim CPU (1.4 → 2.4–2.5 %). Both costs are negligible against a 16.7 ms frame. Prefer a fixed IOSurface pool
  shared once per session (a `CVPixelBufferPool` with a bounded count), and fall back to per-frame rights when
  the decoder hands out surfaces outside the pool.
- **Chrome-style loader (open question, Phase 4):** Chrome's shim is a tiny `app_mode_loader` that loads code
  from the browser bundle, so updates rarely regenerate shims. The spike copies the whole viewer (252 KB) and
  regenerates on update instead. That is simpler and was measured to work; a loader would interact with hardened
  runtime's library validation.
- **Estimates:** no change proposed for Phase 4; P0-18 decides.
- **Open follow-ups:**
  - Manual checks M1–M10, owner: maintainer.
  - macOS 14 rerun, owner: whoever has a macOS 14 Mac.
  - On-glass latency through a shim with the S1 harness, owner: P0-04/P0-15 once a phone pipeline exists.
  - Per-shim notification attribution, Phase 4.
