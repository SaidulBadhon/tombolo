# S8 (Mac) — Local Network privacy with ad-hoc, self-signed and unsigned builds

| | |
|---|---|
| **Spike** | S8 (macOS half; the Android half is P0-11). Combined task with [S15](s15-update-persistence.md) |
| **Task** | P0-10 — see the [Phase 0 task plan](../plans/phase-0.md#acceptance-criteria-per-task) |
| **Pass criteria** | [Implementation plan §0.C](../implementation-plan.md#0c-spikes-each-produces-a-short-write-up-in-docsspikes), S8: "Documented prompts and failure modes" (else: design onboarding around them). P0-10: a self-signed menu-bar test app that listens/browses on the LAN — when the Local Network prompt appears, failure modes when denied, behaviour of incoming-only connections. Brief: ad-hoc, self-signed and unsigned variants; confirm that unsigned is killed |
| **Spike code** | [`spikes/s08-macos-permissions/`](../../spikes/s08-macos-permissions/README.md) at `d7802477501176a3e2cb64ec20d21e93bf10106a` (runs T0–T9 used its ancestors from `54d6b8116f2f866412e1f16fdb1700bf5370874e`; the probe only gained steps, see Method) |
| **Author(s)** | P0-10 agent (Claude), for the maintainer |
| **Date(s) run** | 2026-10-26 (01:23–04:01 local time, UTC+6) |
| **Status** | draft — non-interactive part complete; the deny/re-allow steps are waiting on the maintainer ([manual steps](#manual-steps-for-the-maintainer)) |

## Question

When does macOS 27 show the Local Network alert to a Tombolo-style app that is **not** Developer-ID signed, what
exactly fails while access is pending or denied, and does a design where the phone connects *in* to the Mac
avoid the prompt? The Wi-Fi path, Bonjour discovery and the onboarding flow all depend on the answer.

## Setup

**Devices**

| Role | Model | OS version and build | OEM skin / version | Notes (patch level, settings changed) |
|---|---|---|---|---|
| Mac | Mac16,8 (Apple M4 Pro) | macOS 27.0.1 (26A434) | — | Application Firewall **on** (stealth mode on; "automatically allow built-in / downloaded signed software" on). No settings changed by this task |
| Phone | — | — | — | not used (brief: no phone / adb in this task) |

**Builds and tools**

| Component | Version / commit | How obtained |
|---|---|---|
| Spike code | see header | this repository |
| Swift | 6.4 (swiftlang-6.4.0.34.1), Command Line Tools only, `-swift-version 5`, target `arm64-apple-macos14.0` | Apple CLT |
| Signing | ad-hoc (`codesign -s -`); self-signed RSA-3072 "Tombolo Development (self-signed)", SHA-1 `7DD2BE59…EC32`, via [`tools/signing`](../../tools/signing/README.md); unsigned = linker signature stripped | — |
| Info.plist | `LSUIElement`, `NSLocalNetworkUsageDescription`, `NSBonjourServices` = `_tombolo._udp`, `_tombolo-test._tcp` | `build.sh` |

**Environment:** Wi-Fi only. Runs T0–T8 were on `10.59.232.0/24` (Mac `10.59.232.41`). Between T8 and T9 the Mac
changed networks to `172.20.10.0/28` (Mac `172.20.10.14`); T10 onward used that network. Other agents' spikes
were running on the same Mac (their windows were ignored). **A person was at the Mac** during several runs and
answered some alerts; every such click is listed under [Human interaction observed](#human-interaction-observed).

## Method

1. `./build.sh` builds the bundles. Each variant has its own bundle ID (`io.github.saidulbadhon.tombolo.spike.s08.{adhoc,selfsigned,unsigned}`)
   and its own Mach-O UUID: the variant and version are compiled in, as TN3179 requires unique UUIDs.
2. `run-probe.sh` launches a bundle with `open -n -g` (LaunchServices, so the app is its own responsible
   process) and passes a step script. While it runs, it records:
   - the probe's log (monotonic ms since launch);
   - every new on-screen window, once per second, plus a screenshot of **that window only** when it belongs to a
     system-alert process;
   - the unified log of `nehelper`, `tccd`, `socketfilterfw`, `syspolicyd`, `runningboardd` and others.
   Committed excerpts keep only probe and Local-Network lines.
3. Targets. These were chosen after finding that the Mac's own LAN address is routed over `lo0` (T7):
   - **an unused on-link address** (`10.59.232.254`, later `172.20.10.13` from `lan-target.py`). It is a genuine
     local-network destination: the kernel ARPs for it on-link, and nothing receives traffic.
   - the LAN DNS server (TN3179-exempt) and loopback as controls.
   - `peer.py` on the Mac's own LAN IP, for incoming connections.
4. The Local Network decision per app was read from `/Library/Preferences/com.apple.networkextension.plist`
   (world-readable; read-only) with `lnp-rules.py`.
5. The scripts never click anything. Steps that need a click are in [Manual steps](#manual-steps-for-the-maintainer).

The steps used — `browse`, `advertise`, `listen`, `nwconnect`, `bsdconnect`, `udpconnect`, `udpecho`, `docwrite`,
`ax*`, `login-*` — are documented at the top of `Sources/main.swift`. `docwrite` (after T2), `ax-wait`, the SIGPIPE logger,
`udpconnect-nosigpipe` and `selftest-sigpipe` (at `d780247`) were added during the run; no step changed behaviour.

**Uncertainty:** timings come from the probe's monotonic clock (sub-ms) and 1 s window polling, so "the alert
appeared" is ±1 s. The peer for incoming tests was this Mac itself (see the caveat under T5/T6).

## Raw numbers

Evidence for every row is in [`results/`](../../spikes/s08-macos-permissions/results/), one directory per run.

**Launch and signing variants**

| Run | Variant | Result |
|---|---|---|
| static | all | `spctl -a -t exec` → **rejected** for all three. DRs: ad-hoc `cdhash H"0ade6c3f…"`; self-signed `identifier "…s08.selfsigned" and certificate root = H"7dd2be59…ec32"`; unsigned "code object is not signed at all" |
| T0 | unsigned | `open` → exit 1, `RBSRequestErrorDomain Code=5 "Launch failed"`, underlying POSIX 163; kernel: `AppleSystemPolicy: Security policy would not allow process`; launchd: `spawn failed, error=163: Security policy issue`. No dialog. Direct exec → **exit 137 (SIGKILL)** |
| T1 / T2 | ad-hoc / self-signed, launch only (no network) | **no Local Network alert**. A TCC "Documents folder" prompt appeared instead — caused by the probe's log path inside `~/Documents` (fixed afterwards; [screenshot](../../spikes/s08-macos-permissions/results/t2-selfsigned-launch-only/window-4531.png)) |

**When the alert appears** (fresh bundle, privilege undetermined)

| Run | Variant | First operation | Alert? |
|---|---|---|---|
| T5 | ad-hoc | `NWListener` on TCP 52011, accept 3 incoming connections (own LAN IP ×2, loopback) | **no Local Network alert**; all 3 accepted and answered in < 10 ms. The **Application Firewall** alert appeared instead ("Do you want the application "S08 AdHoc" to accept incoming network connections?", [screenshot](../../spikes/s08-macos-permissions/results/t5-adhoc-incoming-tcp/window-4546.png)) |
| T6 | ad-hoc | UDP socket bound to 52012, receive 3 datagrams and `sendto()` replies | no alert; all 3 replies sent (19 bytes) |
| T7 | ad-hoc | outbound TCP (BSD + Network.framework) and UDP to **this Mac's own LAN IP** | no alert; connected in 0.3 ms; `NWPath` shows `via=lo0` → not a local-network operation |
| T8 | ad-hoc | BSD `connect()` to unused on-link `10.59.232.254:9` | **alert at t+1 s** ("Allow "S08 AdHoc" to find devices on local networks?" with our usage string, [screenshot](../../spikes/s08-macos-permissions/results/t8-adhoc-outbound-lan/window-4603.png)). `nehelper`: `Local network preference not yet set, prompting for S08 AdHoc`, `Showing local network alert … even though not in the foreground`, `No team ID found for (bundleID: …)` |
| T11 | **self-signed** | `NWBrowser` for `_tombolo-test._tcp` | **alert at t+1 s** for "S08 SelfSigned" ([screenshot](../../spikes/s08-macos-permissions/results/t11-selfsigned-undetermined-browse-first/window-4849.png)). The alert **stayed on screen after the probe process had exited** (checked at 03:37:47; a person answered it later) |

**What fails while the alert is pending** (T8 first 3.2 s; T11 whole run, unanswered)

| API | Pending (T8, T11) | Allowed (T10 control, same target) |
|---|---|---|
| BSD TCP `connect()` (non-blocking) | **`EHOSTUNREACH` (65) immediately** (0.1–0.2 ms) | `EINPROGRESS`, still connecting after 4–5 s (ARP timeout) |
| `NWConnection` TCP | `waiting(posix(50 ENETDOWN))`, `currentPath.unsatisfiedReason = localNetworkDenied`, for as long as it waits (8.4 s in T11) | `preparing`/`waiting(posix(65))`, path **satisfied** |
| BSD UDP `connect()` + `send()` | connect = 0, **send → `EPIPE` (32)** (T11) — and the probe process **died 4 ms later** (log ends; no termination line, no crash report). **Probable SIGPIPE**: `EPIPE` raises SIGPIPE, whose default action kills the process. T14 shows the probe dies the same way on a SIGPIPE it provoked itself. Now logged; confirmation in M1 | connect = 0, send → `EHOSTDOWN` (64) |
| `NWBrowser` | `ready`, 0 results; **no `waiting(PolicyDenied)`** in 8.4 s (T11 — but nothing was advertising, so "0 results" is not proof of blocking; T12's attempt to fix that was invalid) | `ready`, found the advertisement (T9) |
| After the user clicks Allow | T8: the waiting `NWConnection` moved to `preparing`, path satisfied, **3.16 s after it started, without a relaunch** | — |

**Allowed state and controls** (T9/T10 after a person clicked Allow; T14 needs no network)

| Run | Variant | Result |
|---|---|---|
| T9 | ad-hoc | `advertise` → registered `S08-adhoc-31695._tombolo-test._tcp.local.` after 0.7 s; `browse` → 1 result. No alert |
| T10 | ad-hoc | control against `172.20.10.13`: see the table above. No alert |
| T14 | ad-hoc | `selftest-sigpipe` (no network: `send()` on a write-shut-down, loopback-connected UDP socket) → `!!! SIGPIPE received`, process terminated — confirms the SIGPIPE logger and the default action |

**Application Firewall** (this Mac has it enabled)

| Run | Variant | Result |
|---|---|---|
| T12 | self-signed | listener + Bonjour advertisement, **no inbound flow** → no firewall prompt |
| T13 | self-signed | first inbound TCP connection (from own LAN IP) → `socketfilterfw`: `Enqueuing new inbound flow for S08 SelfSigned … Prompting for a filtering decision` → alert ([screenshot](../../spikes/s08-macos-permissions/results/t13-selfsigned-listen-firewall/window-5013.png)); the connection was **held — the peer timed out after 5 s** and the app never saw it. "Automatically allow downloaded signed software" did **not** cover the self-signed (or ad-hoc, T5) app |
| U4 | ad-hoc rebuilt 1.0.2, same path | inbound connection accepted in 0.2 ms, no prompt → the "Allow" given to 1.0.1 carried over (see S15) |

**Where the decision is stored** (`lnp-rules.py`, after T8 / T12)

```
io.github.saidulbadhon.tombolo.spike.s08.adhoc: allowed  (MulticastPreferenceSet=True DenyMulticast=False DesignatedRequirement=null AllowEmptyDesignatedRequirement=True)
io.github.saidulbadhon.tombolo.spike.s08.selfsigned: allowed  (MulticastPreferenceSet=True DenyMulticast=False DesignatedRequirement=null AllowEmptyDesignatedRequirement=True)
io.github.saidulbadhon.tombolo.spike.s08.unsigned: undetermined  (MulticastPreferenceSet=False DenyMulticast=True DesignatedRequirement=null AllowEmptyDesignatedRequirement=True)
```

Each app's decision is an `NEPathRule` keyed by **`SigningIdentifier` only**, with no designated requirement.
`nehelper` maps each new executable UUID onto the rule ("Populating the cache with 1 UUID(s) for …"). A rule
already exists before an app's first local-network operation: `nehelper` reacts to LaunchServices'
"apps installed" notification. That happened even for the unsigned bundle, which never ran. The field semantics
are inferred from behaviour, not documented by Apple.

### Human interaction observed

A person at the Mac answered these alerts during the runs. They were not asked to, and nothing was clicked by
the agent:

| Time (local) | Alert | Answer | Evidence |
|---|---|---|---|
| 01:23:50.9 / 01:25:40.6 | TCC Documents folder, S08 AdHoc / S08 SelfSigned | Allow | `tccd AUTHREQ_RESULT … authValue=2, authReason=2` in T1/T2 excerpts. Both grants were reset afterwards with `tccutil` |
| ≈01:29:50 | Firewall, S08 AdHoc | Allow | `socketfilterfw --listapps` → "Allow incoming connections" |
| 01:32:22.8 | **Local Network, S08 AdHoc** | Allow | T8 probe log: path satisfied at +3265 ms; rule `allowed` |
| 03:37:45–03:38:37 | **Local Network, S08 SelfSigned** (left pending by T11) | Allow | rule `allowed` from T12 on |
| 03:41:40–03:47:59 | Firewall, S08 SelfSigned (left pending by T13) | Allow | `--listapps` |

## Verdict

| # | Criterion (as written in the plan) | Verdict | Evidence |
|---|---|---|---|
| 1 | Self-signed menu-bar test app that listens/browses on the LAN (plus ad-hoc and unsigned variants) | **pass** | `Sources/main.swift`, `build.sh`; static signature table |
| 2 | Unsigned variant: expected to be killed on Apple silicon — confirm | **pass** | T0: `open` fails (POSIX 163, "Security policy would not allow process"); direct exec SIGKILL (137); no prompt of any kind |
| 3 | When the Local Network prompt appears | **pass** | Not at launch (T1, T2). Not for listening/accepting TCP or receiving/replying UDP to this Mac (T5, T6). Not for traffic to the Mac's own IP (T7, `lo0`). **Yes at the first outbound on-link connection (T8) and the first Bonjour browse (T11)**, for ad-hoc **and** self-signed. It is shown while the app is in the background (`LSUIElement`), and it stays up after the process exits |
| 4 | Failure modes while undetermined / pending | **pass** | Table "What fails while the alert is pending": BSD `EHOSTUNREACH` immediately; `NWConnection` `waiting` + `localNetworkDenied`; UDP `send` `EPIPE`; browser `ready`/empty (no `PolicyDenied` seen — weak, nothing was advertising); the process probably died of SIGPIPE after the UDP `EPIPE` (T11, T14); a waiting `NWConnection` recovers by itself after Allow (T8) |
| 5 | Failure modes when **denied** (Don't Allow) and after re-allowing in System Settings | **blocked — needs the maintainer** ([M1, M2](#manual-steps-for-the-maintainer)) | Every alert answered so far was answered Allow |
| 6 | Behaviour of incoming-only connections | **partial: pass for "no Local Network prompt" when the peer is this Mac; blocked — needs a second LAN device** for a remote peer | T5/T6 accepted and replied without a prompt, but the peer's traffic went over `lo0`, so a remote phone was not tested. On this Mac **the Application Firewall prompts on the first inbound flow** for ad-hoc and self-signed apps and holds the connection until answered (T13) |

**Coverage:** one Mac, macOS 27.0.1 only. Not covered:

- macOS 14/15/26;
- macOS 27.2 (reset UI);
- a Mac with the firewall off;
- a remote LAN peer, which needs the phone (P0-11/P0-14) or another computer;
- a Developer-ID-signed build (nehelper's "No team ID found" suggests Team-ID apps may be keyed differently).

## Consequences for the plan

- **The fallback "design onboarding around them" applies. Concretely:**
  - Trigger the Local Network alert at a moment of intent, for example the pairing screen. A Bonjour browse or an
    on-link UDP connect (TN3179's trick) does it. Keep the process alive until the user answers, because of
    FB16131937.
  - Detect denial per API:
    - `NWConnection`: `currentPath.unsatisfiedReason == .localNetworkDenied`.
    - BSD sockets (the Rust core: iroh/tokio): **an immediate `EHOSTUNREACH` on an on-link address means "Local
      Network not allowed"**, not "phone unreachable". The core must surface it as a distinct error.
  - Don't rely on `NWBrowser` reporting `PolicyDenied` while the alert is pending.
  - **Ignore SIGPIPE process-wide in the Mac app** (`signal(SIGPIPE, SIG_IGN)` at launch, or `SO_NOSIGPIPE` on every socket). The Rust core will run inside the Swift app through UniFFI, where Rust's usual SIGPIPE-ignore start-up code does not run. A UDP send while Local Network access is pending returned `EPIPE`, and the probe then died (T11, probable SIGPIPE).
- **"The phone connects in" avoids the Local Network alert only for TCP.** On a Mac with the Application Firewall
  on (common, and default on many managed Macs), a self-signed Tombolo gets the **firewall** alert at the first
  inbound connection, and the connection stalls until it is answered. Onboarding must expect a firewall alert,
  and the pairing timeout must outlast it. A Developer-ID build would be auto-allowed by the "downloaded signed
  software" setting (not tested here, because ad-hoc and self-signed are not).
  - Replies over QUIC/UDP are an outgoing unicast; TN3179 lists that as gated, and the same-Mac test (T6) could
    not show it.
- Research/03 corrections: research/03 §3 says unsigned bundles fail with `EHOSTUNREACH`. On Apple-silicon macOS
  27 they don't launch at all. Ad-hoc *and* self-signed bundles both get the alert.
- **Testing guidance for later spikes:** never use the Mac's own IP as the "LAN peer" (it is `lo0`). Use
  `lan-target.py` or a second device. Each fresh Local Network test needs a fresh bundle ID until macOS 27.2.
- Follow-ups:
  1. M1/M2 by the maintainer — denied failure modes, and recovery after re-allowing.
  2. Remote-peer incoming test (UDP replies, QUIC) once the phone is available — P0-14 (S4) is the natural owner.
  3. Repeat T8/T11 on macOS 27.2 and the minimum supported macOS 14 before 1.0.

## Manual steps for the maintainer

Run everything from `spikes/s08-macos-permissions/`. Build first if `build/` is missing: `./build.sh`. Each
script prints what to click, waits, and writes its evidence to `results/<label>/`. No step needs a keychain
trust change.

| # | Run | What to click | What to observe | Evidence |
|---|---|---|---|---|
| M1 | `./checklist.sh m1-lnp-deny` | In "Allow "S15 AdHoc Probe" to find devices on local networks?" click **Don't Allow** | Script prints `rule for s15adhoc is now denied`. Then, for 1.0.0 and after the update to 1.0.1, expect: `udpconnect-nosigpipe … send() = -1 errno 32`, then `!!! SIGPIPE received` on the plain `udpconnect` (confirms T11's cause), BSD connect `EHOSTUNREACH` immediately, `NWConnection` `waiting` with `localNetworkDenied`, and possibly `browse … waiting(dns(-65570 = kDNSServiceErr_PolicyDenied))`. **1.0.1 should still be denied** (rule keyed by identifier) | `results/m1a-…`, `m1b-lnp-denied-1.0.0`, `m1c-lnp-denied-after-update-1.0.1` |
| M2 | `./checklist.sh m2-lnp-reallow` | Within 2 min: **System Settings › Privacy & Security › Local Network**, turn **on** "S15 AdHoc Probe" | Script prints `rule … allowed`. The probe log shows the waiting `nwconnect` change from `localNetworkDenied` to a satisfied path **without a relaunch** | `results/m2-lnp-reallow/` |
| M3 | `./checklist.sh m3-lnp-allow-s15` | In "Allow "S15 Probe" …" click **Allow** | Script prints `rule for =.spike.s15 is now allowed`. For 1.0.1, expect no alert window, BSD connect `EINPROGRESS`/timeout (not `EHOSTUNREACH`), and a satisfied path | `results/m3a-…`, `m3b-lnp-allowed-after-update-1.0.1` |
| M4 | `./checklist.sh m4-ax-grant selfsigned` | In "S15 Probe would like to control this computer using accessibility features" click **Open System Settings**, turn **on** "S15 Probe" under Privacy & Security › Accessibility, then confirm with Touch ID or password | Script prints `ax-wait: AXIsProcessTrusted changed to true` | `results/m4-ax-grant-selfsigned-1.0.0/` |
| M5 | `./checklist.sh m5-ax-update selfsigned` | Nothing for 20 s; then open Privacy & Security › Accessibility | Expected: `AXIsProcessTrusted=true` for 1.0.1, and "S15 Probe" still listed and on | `results/m5-ax-update-selfsigned-1.0.1/` |
| M6 | `./checklist.sh m4-ax-grant adhoc` | As M4, for **"S15 AdHoc Probe"** | `AXIsProcessTrusted changed to true` | `results/m4-ax-grant-adhoc-1.0.0/` |
| M7 | `./checklist.sh m5-ax-update adhoc` | Nothing for 20 s; then look at the Accessibility list | Expected: `AXIsProcessTrusted=false` for 1.0.1 (the DR is the old cdhash). **Note whether the list still shows "S15 AdHoc Probe" as on** — a stale toggle is the user-visible trap | `results/m5-ax-update-adhoc-1.0.1/` |
| M8 | `./checklist.sh status`, then commit: `git add spikes/s08-macos-permissions/results && git commit -m "S08/S15: maintainer checklist evidence"` | — | Hand back to an agent to update the verdicts above and in [S15](s15-update-persistence.md) | the commit |
| M9 | `./cleanup.sh --yes` | Then **System Settings › Network › Firewall › Options…**, select "S08 AdHoc" and "S08 SelfSigned" (and any "S15 …"), click **−** — or run the `sudo socketfilterfw --remove …` lines the script prints | The script prints what it removed: login items, TCC records (`tccutil`), LaunchServices registrations, logs. **Local Network entries can't be removed on 27.0.1**; on 27.2+: Privacy & Security › Local Network, select, **−**. Optional: `tools/signing/remove-identity.sh --yes` | script output |
