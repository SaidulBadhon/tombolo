# Contributing to Tombolo

Thanks for your interest. Please read this page before opening a pull request; by taking part you agree to
follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Where the project is

Tombolo is in **research and planning**. There is no application code yet. Phase 0 is in progress: measured
spikes and a reviewed security design that answer the riskiest questions before Phase 1 starts — see the
[Phase 0 task plan](docs/plans/phase-0.md) and the [implementation plan](docs/implementation-plan.md).

The most useful contributions right now:

- **Reviews** of the [architecture](docs/architecture.md), [protocol draft](docs/protocol.md) and
  [implementation plan](docs/implementation-plan.md) — corrections, risks we missed, better approaches.
- **Device knowledge**: how a specific phone, OEM skin or macOS version behaves (see
  [Reporting device-specific findings](#reporting-device-specific-findings)).
- **Spike work and results**, coordinated through the Phase 0 task list.

Security problems — including flaws in the pairing or session design — go through [SECURITY.md](SECURITY.md),
not public issues.

## Licence of contributions

- Tombolo is licensed under the **GNU General Public License v3.0 or later** ([`LICENSE`](LICENSE)).
- The protocol specification ([`docs/protocol.md`](docs/protocol.md)) and the schemas in [`proto/`](proto/README.md)
  are licensed under **Apache-2.0** ([`LICENSES/Apache-2.0.txt`](LICENSES/Apache-2.0.txt)), so anyone can
  implement the protocol. See [ADR-0007](docs/decisions/0007-license.md).
- **Inbound = outbound:** you contribute under the licence of the files you change — GPL-3.0-or-later, or
  Apache-2.0 for the protocol specification and `proto/`. You keep your copyright.
- **No CLA.** There is no contributor licence agreement to sign.
- Only contribute work you have the right to contribute. Third-party code must be **GPL-3.0-compatible**, keep
  its own licence file and copyright notices, and be listed in [`NOTICE`](NOTICE). GPL-only code (for example
  from KDE Connect) may go into the apps but **never** into the Apache-2.0 protocol specification or `proto/`.
  Code from source-available projects with non-free terms can't be used at all.

## Spike code vs production code

| | Spike code | Production code |
|---|---|---|
| Where | `spikes/sNN-<slug>/` — one directory per spike | `apple/`, `android/`, `core/`, `proto/`, `tools/` |
| Purpose | Answer one question with measurements | Ship to users |
| Quality bar | Whatever answers the question; tests and lint optional | The [definition of done](#definition-of-done) |
| Output | A result document `docs/spikes/sNN-<slug>.md` from the [template](docs/spikes/TEMPLATE.md) | Reviewed, tested code |
| Lifetime | Throwaway; **never promoted to production directly** | Maintained |

When a spike succeeds, the production version is written again, with review and tests — not copied. Details:
[`spikes/README.md`](spikes/README.md). No code of either kind may contain secrets (signing keys, keystores,
pairing secrets).

## Branches and pull requests

- **One task per branch, one branch per pull request.** Phase 0 branches are named `p0/<task-id>-<slug>`
  (for example `p0/07-lifecycle`); for other work use a short descriptive name such as `docs/fix-protocol-typo`.
  Separate git worktrees (`git worktree add ../tombolo-wt/<name> -b <branch>`) make parallel tasks easy.
- **Write only the paths your task owns.** Every Phase 0 task lists its paths under "Owns" in the
  [task plan](docs/plans/phase-0.md#task-list); tasks in the same wave never write the same files. If you need to
  change something outside your paths, say so in the pull request or open an issue.
- Branch from an up-to-date `main`; `main` changes only through pull requests.
- Keep commits focused, with messages that say what changed and why.
- In the pull request, reference the task ID or issue, describe how you verified the change (commands and their
  actual output), and work through the checklist in the pull request template. CI must pass.

## Definition of done

From the [implementation plan, §6](docs/implementation-plan.md#6-definition-of-done-every-task) — every task:

- code reviewed;
- tests for new logic;
- no new lint warnings;
- docs updated where behaviour changed;
- optical / device-matrix numbers recorded where the task touches performance;
- accessibility labels for new UI;
- fail-closed behaviour covered where the task touches sessions.

Plus, for every change: the link check passes.

## Checking links

CI checks every relative Markdown link and `#anchor` on each push and pull request. Run the same check locally
(Python 3.8+, no packages needed) from the repository root:

```sh
python3 tools/check-links/check_links.py
```

It prints each problem as `path:line:column: message` and exits non-zero if there are any. If you change the
checker, run its tests too: `python3 -m unittest discover -s tools/check-links`. Details:
[`tools/check-links/README.md`](tools/check-links/README.md).

## Reporting device-specific findings

Android behaviour varies by manufacturer, OEM skin and OS version, so device reports are valuable. Use the
**Device report** issue form and include: phone model, Android version (and build / security patch), OEM skin
and version, Mac model, macOS version, connection type (USB, Wireless debugging, Wi-Fi), what you ran (spike and
commit, scrcpy version, …) and what happened, with steps to reproduce.

- **Remove personal data** from logs and screenshots first — notifications, messages, phone numbers, contact
  names, Wi-Fi network names and device serial numbers.
- Say exactly which device and OS version you observed; one device's result is evidence for that device only.
- For a spike result, write the result document from the [template](docs/spikes/TEMPLATE.md). A criterion you
  couldn't run on the required hardware is **"blocked — needs hardware"**, never "pass".

## Identifiers

Android package `io.github.saidulbadhon.tombolo`, macOS bundle ID `io.github.saidulbadhon.Tombolo`, DNS-SD
service `_tombolo._udp`. Reserving the Android package name under Google's developer verification is a
maintainer action (M3 in the [Phase 0 plan](docs/plans/phase-0.md#prerequisites-maintainer-actions)). If you
distribute your own builds, use your own package name and bundle ID so they can't be confused with official
builds.
