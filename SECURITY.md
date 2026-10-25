# Security policy

Tombolo will let a Mac view and control an Android phone, so security problems are taken seriously — including
problems in the design, before any code exists.

## Reporting a vulnerability

**Please report privately, not in a public issue, pull request or discussion.**

Use GitHub's private vulnerability reporting: open the repository's **Security** tab and choose
**"Report a vulnerability"** (direct link: <https://github.com/SaidulBadhon/tombolo/security/advisories/new>).
The report is visible only to you and the maintainers. If that option isn't available, contact the maintainer
via GitHub (<https://github.com/SaidulBadhon>) to arrange a private channel — without including any details in
public.

Helpful to include:

- what is affected (document and section, or component, file and commit);
- how to reproduce it, or the attack scenario for a design flaw;
- the impact you expect (for example: the Mac gains a scope the phone never granted);
- devices, OS versions and connection type, if relevant.

This is a volunteer project, so responses are best effort. We will acknowledge the report in the advisory,
keep you updated, agree a disclosure date with you, and credit you in the advisory unless you prefer
otherwise.

**There is no bug bounty.**

## Supported versions

**None yet.** Tombolo has no releases and no application code. This section will list the supported versions
once the first release (0.1) ships.

## Scope

In scope now:

- the security model and threat model — [architecture §8](docs/architecture.md#8-security-model) and the
  [transport and security research, threat model](docs/research/04-transport-and-security.md#54-threat-model);
- the pairing and session design being written in Phase 0 (task P0-03) and the
  [protocol draft](docs/protocol.md);
- this repository's tooling and CI ([`tools/`](tools/README.md), [`.github/`](.github/)).

In scope once they exist: the Mac app, the Android app, the Enhanced-mode helper, `tombolo-core`, release
artifacts and update channels (GitHub Releases, the Homebrew tap, update feeds).

Out of scope:

- **Spike code** in [`spikes/`](spikes/README.md): it is throwaway, never shipped and not security-reviewed.
  Report it only if the flaw would carry over into the design.
- Vulnerabilities in upstream projects (scrcpy, `adb`, iroh, Android, macOS) — please report those upstream;
  tell us too if Tombolo is affected.
- The documented ADB trust model of releases 0.1–0.2, where mirroring runs under ADB's own authorisation
  ([architecture §8](docs/architecture.md#8-security-model)) — unless you find it is weaker than documented.
