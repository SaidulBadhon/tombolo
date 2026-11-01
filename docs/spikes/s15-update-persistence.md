# S15 — Do permission grants survive an update signed with the same self-signed identity?

| | |
|---|---|
| **Spike** | S15 (combined task with [S8 Mac](s08-macos-local-network.md)) |
| **Task** | P0-10 — see the [Phase 0 task plan](../plans/phase-0.md#acceptance-criteria-per-task) |
| **Pass criteria** | [Implementation plan §0.C](../implementation-plan.md#0c-spikes-each-produces-a-short-write-up-in-docsspikes), S15: "Grants persist" for Accessibility / Local Network / login items after an update signed with the same self-signed identity (else: document re-grant UX; prioritise Developer ID). P0-10: ship 1.0.1 signed with the same identity and check Local Network, Accessibility and login-item grants. Brief: show each version's DR and whether 1.0.0's DR is satisfied by 1.0.1; ad-hoc builds for comparison |
| **Spike code** | [`spikes/s08-macos-permissions/`](../../spikes/s08-macos-permissions/README.md) and [`tools/signing/`](../../tools/signing/README.md) at `d7802477501176a3e2cb64ec20d21e93bf10106a` |
| **Author(s)** | P0-10 agent (Claude), for the maintainer |
| **Date(s) run** | 2026-10-26 |
| **Status** | draft — DR, Local Network and login-item *status* results complete; Accessibility and launch-at-login are blocked on a person. M4 was attempted on 2026-10-26 but not granted ([M4–M7](s08-macos-local-network.md#manual-steps-for-the-maintainer)) |

## Question

[ADR-0006](../decisions/0006-distribution.md) relies on one stable self-signed identity so that users don't
lose Accessibility, Local Network and login-item grants on every update. research/03 inferred that from
TN3127 without testing it. Does it actually hold on macOS 27, and how does ad-hoc signing compare?

## Setup

Same Mac and toolchain as [S8](s08-macos-local-network.md#setup): Mac16,8 (Apple M4 Pro), macOS 27.0.1 (26A434),
Swift 6.4 Command Line Tools.

| Identity | How created | Certificate |
|---|---|---|
| Stable self-signed | `tools/signing/create-identity.sh` → `~/Library/Keychains/tombolo-dev.keychain-db` | CN "Tombolo Development (self-signed)", RSA-3072, EKU codeSigning, 2026-10-25 → 2046-10-20, SHA-1 `7DD2BE59BD6F516B6BBB0444C2F0316D7EAEEC32`, **untrusted** (`CSSMERR_TP_NOT_TRUSTED`) |
| Ad-hoc | `codesign -s -` | — |
| Impostor (test only, deleted) | `create-identity.sh` in `/tmp` | CN "S15 Impostor (self-signed)" |

Bundles: `io.github.saidulbadhon.tombolo.spike.s15` (self-signed) and `….s15adhoc` (ad-hoc), versions 1.0.0 and
1.0.1, which differ only in the compiled-in version string (hence a different cdhash and Mach-O UUID), with the
hardened runtime. The live update tests also reused the S8 bundles (`….s08.adhoc`, `….s08.selfsigned`),
rebuilt from 1.0.1 to 1.0.2.

## Method

1. **DR comparison** (`s15-dr-check.sh --impostor`): `codesign -d -r-` for each version, then
   `codesign --verify -v -R <DR of version A> <version B>`. TCC stores the granted version's DR and evaluates each
   later version against it, so this is the same check.
2. **Local Network, live:** with the S8 bundles in the *allowed* state (allowed by a person's clicks during S8),
   rebuild them as 1.0.2 at the same path, run an outbound on-link connection, and compare with the allowed
   and pending signatures from S8. Then re-sign the allowed ad-hoc bundle with the self-signed certificate,
   which is a **change of signer** with the same identifier.
3. **Firewall, live:** the ad-hoc bundle had a firewall "Allow" for 1.0.1. Rebuild as 1.0.2 at the same path
   and connect in.
4. **Login item, live:** `s15-update.sh` installs 1.0.0 at a fixed path and calls
   `SMAppService.mainApp.register()`. It then replaces the bundle in place (delete + copy, as an updater does)
   with 1.0.1 and reads `SMAppService.mainApp.status`. Afterwards it unregisters.
5. **Accessibility:** needs a person to grant it. See [M4–M7](s08-macos-local-network.md#manual-steps-for-the-maintainer).
6. **Signing-identity experiments**, in throwaway keychains in `/tmp`, since deleted: trust requirement,
   `--keychain` without the search list, a private CA plus leaf chain, and an expired certificate.

## Raw numbers

**Designated requirements** ([`results/s15-dr/dr-check.txt`](../../spikes/s08-macos-permissions/results/s15-dr/dr-check.txt), for the bundles built at `d780247`; cdhashes change on every rebuild, the pattern does not)

| Bundle | DR |
|---|---|
| self-signed 1.0.0 and 1.0.1 | `identifier "io.github.saidulbadhon.tombolo.spike.s15" and certificate root = H"7dd2be59bd6f516b6bbb0444c2f0316d7eaeec32"` (identical) |
| ad-hoc 1.0.0 | `cdhash H"02acd9fb8e01692744eae834c0971f0bd2906e1e"` |
| ad-hoc 1.0.1 | `cdhash H"b7103c10a895e14f9616bb896ff68f34ceee3381"` (different) |
| impostor copy of 1.0.1 | `identifier "io.github.saidulbadhon.tombolo.spike.s15" and certificate root = H"d9806d68fbb82b58a566da1fa888b7aa6ae94e54"` |

| Check (`codesign --verify -R`) | Result |
|---|---|
| self-signed 1.0.1 against 1.0.0's DR (update) | **explicit requirement satisfied** |
| self-signed 1.0.0 against 1.0.1's DR (downgrade) | satisfied |
| ad-hoc 1.0.1 against 1.0.0's DR | **failed to satisfy** |
| ad-hoc 1.0.0 against 1.0.1's DR | failed |
| self-signed 1.0.1 against ad-hoc 1.0.0's DR | failed |
| impostor (same identifier, other self-signed cert) against genuine 1.0.0's DR | **failed** |

The same held for the S8 bundles 1.0.0 → 1.0.1 (self-signed satisfied, ad-hoc failed: `cdhash H"0ade6c3f…"` vs
`H"4166a72b…"`).

**Live grant checks**

| Run | Grant | Before | Update | After |
|---|---|---|---|---|
| U1 | Local Network | `s08.adhoc` allowed (since T8) | ad-hoc 1.0.1 → **1.0.2** (new cdhash `8cb82ffd…`, new UUID `E1995F60…`) | **still allowed**: no alert, BSD `EINPROGRESS`, path satisfied, rule unchanged |
| U1 | Local Network | `s08.selfsigned` allowed (since T11/T12) | self-signed 1.0.1 → **1.0.2** (UUID `324C2FC2…`) | **still allowed**: no alert, path satisfied, only ARP errors (`EHOSTDOWN`) |
| U3 | Local Network | `s08.adhoc` allowed | same bundle **re-signed with the self-signed certificate** (DR now `certificate root = H"7dd2…"`) | **still allowed** — the grant ignores the signer |
| U4 | Application Firewall | S08 AdHoc 1.0.1 "Allow incoming connections" | ad-hoc → 1.0.2 at the same path | **still allowed**: inbound accepted in 0.2 ms, no prompt, no `Prompting` in `socketfilterfw` |
| L1 | Login item (`SMAppService.mainApp`) | self-signed 1.0.0: `notFound` → `register()` → `enabled` ("Login Item Added" banner, [screenshot](../../spikes/s08-macos-permissions/results/l1-login-selfsigned-1.0.0/window-35.png)) | in-place 1.0.1 | **`enabled`** |
| L1 | Login item | ad-hoc 1.0.0: `notFound` → `enabled` | in-place 1.0.1 | **`enabled`** |
| L2 | (cleanup) | both 1.0.1 | `unregister()` | `notRegistered` |
| — | TCC Documents folder (incidental, from S8 T1/T2) | allowed by a person for S08 1.0.0 (both variants) | 1.0.1 (both variants) | write succeeded in 0.2 ms with no prompt **for both, ad-hoc included**. `sandboxd` never asked `tccd` (cached decision) → **inconclusive** as a DR test. Both grants were then reset with `tccutil` |
| M4–M7 | Accessibility | M4 (2026-10-26, maintainer): self-signed 1.0.0 requested access; the maintainer stopped before granting | — | `AXIsProcessTrusted=false` for the whole 180 s wait ([M4 notes](../../spikes/s08-macos-permissions/results/m4-ax-grant-selfsigned-1.0.0/NOTE.txt)). M5–M7 not run. **Persistence not measured** |

**Local Network storage.** Decisions are `NEPathRule`s keyed by `SigningIdentifier`, with
`DesignatedRequirement = null` and `AllowEmptyDesignatedRequirement = true` (see
[S8](s08-macos-local-network.md#raw-numbers)). That explains U1 and U3.

**Signing-identity experiments** (details in [`tools/signing/README.md`](../../tools/signing/README.md))

| Experiment | Result |
|---|---|
| Sign with an **untrusted** self-signed certificate, keychain not in the search list (`codesign --keychain`) | works, no prompt; signature verifies; hardened-runtime binary runs. **No trust step is needed** |
| Default DR for a single self-signed certificate | `identifier "<id>" and certificate root = H"<SHA-1 of the certificate>"` |
| Private root CA + leaf | DR pins the **CA** (`certificate root = H"<CA SHA-1>"`). Leaf 2 satisfies leaf 1's DR. Needs the CA in the keychain search list while signing |
| Expired certificate (2020–2021) | `codesign`: "no identity found" — cannot sign |
| Backup → delete → `--import` | same SHA-1, so the same DR |

## Verdict

| # | Criterion (as written in the plan) | Verdict | Evidence |
|---|---|---|---|
| 1 | Build 1.0.0 and 1.0.1 with the stable self-signed identity (and two ad-hoc builds) and show each DR | pass | `dr-check.txt` |
| 2a | Self-signed: 1.0.0's DR is satisfied by 1.0.1 (`codesign --verify -R`, the check TCC applies) | pass | `dr-check.txt` |
| 2b | Ad-hoc, for comparison: 1.0.0's DR is satisfied by 1.0.1 | fail | `dr-check.txt` — expected: an ad-hoc DR is the build's cdhash |
| 2c | A different self-signed certificate with the same identifier does **not** satisfy 1.0.0's DR | pass | `dr-check.txt` (impostor) |
| 3 | Local Network grant persists across the update | pass | Measured live on 1.0.1 → 1.0.2 rebuilds of allowed bundles (U1). It persists for ad-hoc too, and even across a change of signer (U3), because macOS 27.0.1 keys it by bundle identifier only (`lnp-rules.py`). The initial Allow clicks were made by people, not by the agent. Optional confirmation on the S15 bundles: [M3](s08-macos-local-network.md#manual-steps-for-the-maintainer) |
| 4 | Accessibility grant persists across the update | blocked — needs a person | M4–M7. M4 was attempted on 2026-10-26 but stopped before granting. Prediction from 2a/2b, untested: persists for self-signed, lost for ad-hoc |
| 5a | Login item: registration status persists across the update (`SMAppService.mainApp.status`) | pass | L1: `enabled` after an in-place update, self-signed and ad-hoc |
| 5b | Login item: the updated app actually launches at login | blocked — needs a person | Needs a log-out/log-in (or restart) with the item registered, then check the app started. Also untested: a login item the user *disabled* in System Settings, then update |
| 6 | Keys outside Git; scripts to create, sign and remove | pass | `tools/signing/`, lifecycle test in `/tmp`; `git ls-files` contains no key material. Since `3a2524d`, `remove-identity.sh` refuses keychains it did not create (not yet exercised: edit-only window) |

**Coverage:** macOS 27.0.1 only, one Mac.

- Not covered: macOS 14/15/26; Developer-ID-signed builds (the planned migration); notarized or quarantined
  downloads (all builds here were local and not quarantined); a Sparkle-driven update (simulated by an in-place
  replace).

## Consequences for the plan

- **The mechanism ADR-0006 relies on behaves as predicted, but no TCC grant has been confirmed across a live
  update yet.** The stable self-signed identity gives a DR that 1.0.1 satisfies and an impostor certificate does
  not, which is the check TCC applies (2a, 2c). But the only live TCC test (Documents folder) was inconclusive,
  because a cache answered for ad-hoc builds too, and Accessibility (M4–M7) is blocked. Keep "sign every build
  with one stable self-signed identity", hardened runtime on, as the working assumption. S15 stays open until
  M4–M7 confirm it.
- **Local Network grants and login-item registration don't depend on the identity** on macOS 27.0.1: ad-hoc
  keeps them too. Whether the item still launches at login after an update is not measured (5b).
  - Consequence 1: Local Network is not a security boundary against an app that copies our bundle ID. That is
    fine for a privacy prompt, but don't treat it as one.
  - Consequence 2: switching to Developer ID later should keep Local Network and login-item registration. It
    will very likely cost every user **one Accessibility re-grant**, because the DR changes from
    `certificate root = …` to `anchor apple generic … <TeamID>`. Plan a "permissions need re-granting" screen for that release. Re-test
    Local Network then — nehelper's "No team ID found" hints that Team-ID apps may be keyed differently.
- **The release key is now a single point of failure.** Losing it means every user re-grants Accessibility;
  leaking it lets anyone ship code that inherits those grants. Create the release identity with
  `create-identity.sh --backup` to offline storage, keep it in its own keychain, and use 20-year validity, since
  `codesign` refuses expired identities.
  - Option to decide before 1.0: a private root CA plus a rotating leaf. The DR pins the CA, so leaves can be
    rotated without re-grants. This is measured but not implemented.
- **UX:** detect lost grants at launch (`AXIsProcessTrusted()`, Local Network via `localNetworkDenied` /
  immediate `EHOSTUNREACH`) and lead the user back to the right System Settings pane. Ad-hoc dev builds will hit
  this on every rebuild.
- The firewall "Allow" carried over to a rebuilt binary at the same path (U4). Keep the install path stable
  across updates; Sparkle replaces in place.
- Follow-ups:
  1. Maintainer M4–M7 (Accessibility), then update this verdict.
  2. Re-test with a Developer ID build when funded (ADR-0006).
  3. Test the "user disabled the login item" case.
  4. Optionally repeat the TCC file-access test after a reboot, to rule out the cache.
