# s08-macos-permissions — S8 (Mac) + S15 probe

**Throwaway spike code** (see [`spikes/README.md`](../README.md)). Results:
[S8 — Local Network on macOS](../../docs/spikes/s08-macos-local-network.md) and
[S15 — update persistence](../../docs/spikes/s15-update-persistence.md).

## What it tests

A menu-bar app (`LSUIElement`) that performs each kind of local-network operation and logs exactly what
happens: Bonjour browse (`NWBrowser`), Bonjour advertise and listen (`NWListener`), outbound TCP with
Network.framework and with BSD sockets, UDP connect/send, and UDP receive/reply. It also reports what S15 needs
across updates: its signing identity and DR, Mach-O UUID, `AXIsProcessTrusted`, and `SMAppService.mainApp`
login-item status. It is built in several variants: ad-hoc, stable self-signed
([`tools/signing`](../../tools/signing/README.md)) and unsigned, plus S15 versions 1.0.0 and 1.0.1.

## Files

| File | Purpose |
|---|---|
| `Sources/main.swift` | The probe app. Steps are listed at the top of the file |
| `Sources/windows.swift` | Detects new on-screen windows (the alerts) without reading other apps' titles |
| `build.sh [s08\|s15\|all]` | Builds every bundle with `swiftc` (Command Line Tools only) into `build/` (gitignored) |
| `run-probe.sh <app> <label> <steps> [secs]` | Launches a bundle through LaunchServices and records `results/<label>/` |
| `lan-target.py` | Prints this Mac's LAN address, the gateway and an **unused on-link address** to use as a target |
| `lnp-rules.py [substring\|=suffix]` | Read-only dump of the Local Network decision per app |
| `peer.py` | A LAN peer: TCP server/client, UDP client |
| `s15-dr-check.sh [--impostor]` | DR comparison across 1.0.0 → 1.0.1 (writes `results/s15-dr/`) |
| `s15-update.sh <selfsigned\|adhoc> <version> <label> [steps]` | Installs a version in place (as an updater would), runs it |
| `checklist.sh <step>` | The steps that need a person. Each one tells you what to click and records the evidence |
| `cleanup.sh [--yes]` | Removes leftovers a user can remove; prints the rest |
| `excerpt.sh` | Reduces the raw unified log to lines about the probe / Local Network (for committing) |
| `results/` | Evidence per run: `probe.log`, `windows.log`, `window-<id>.png` (the alert window only), `system-excerpt.log`, `launch.log`. Raw `system.log` files are gitignored |

## Build and run

```sh
tools/signing/create-identity.sh                       # once, from the repo root
cd spikes/s08-macos-permissions
./build.sh                                             # all variants
eval "$(python3 -I lan-target.py)"; echo "$UNUSED"     # e.g. 172.20.10.13
./run-probe.sh "build/s08/S08 SelfSigned.app" demo "browse:_tombolo-test._tcp:5;bsdconnect:$UNUSED:9:4;quit" 20
./s15-dr-check.sh --impostor
```

Rules that matter when you reproduce this:

- **Launch through LaunchServices** (`open`, which `run-probe.sh` uses). Running `Contents/MacOS/TomboloProbe`
  from a terminal makes the terminal the responsible process, and Local Network privacy then judges the terminal.
- **Don't use this Mac's own IP address as the peer.** Traffic to it goes over `lo0` and is not a local-network
  operation (measured, T7). The gateway is usually also the DNS server, which TN3179 exempts. `lan-target.py`
  picks an unused on-link address instead: the kernel has to ARP for it (a real local-network operation), and no
  device receives anything.
- **Keep logs out of `~/Documents`.** This repository may live there. A probe writing into it triggers a TCC
  "Documents folder" prompt (it did, in T1/T2), so the probe logs to `~/Library/Logs/TomboloSpikeS08/` and
  `run-probe.sh` copies the log into `results/`.
- Before macOS 27.2 a Local Network decision **cannot be reset** (TN3179). Each fresh test needs a fresh bundle ID.

## Steps that need a person

Clicking Allow / Don't Allow in a Local Network alert, granting Accessibility in System Settings (Touch ID or
password), and removing firewall entries (`sudo`). Run `./checklist.sh` for each step; the exact list, with what
to click and what to expect, is in the
[S8 result](../../docs/spikes/s08-macos-local-network.md#manual-steps-for-the-maintainer). When finished, run
`./cleanup.sh --yes`.
