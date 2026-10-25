# ADR-0007: Licence

- **Status:** **Accepted** (maintainer decision, 2026-10-26)
- **Date:** 2026-10-25 (proposed) · 2026-10-26 (accepted)

## Context
Every planned dependency is permissive: scrcpy (Apache-2.0), droidMirroring-mac (Apache-2.0), iroh/noq
(MIT/Apache-2.0), Shizuku (Apache-2.0), NearDrop (Unlicense), libopus (BSD), Sparkle (MIT). KDE Connect,
KonnectMac, Soduto and Sefirah code is GPL — reusable only if Tombolo is GPL-3.0. The closest competitor
(AirSync) is source-available with terms that forbid redistribution of modified builds and sells mirroring as a
paid add-on — exactly the outcome the project wants to prevent. The Mac App Store is not a planned channel
(sandbox), which removes the usual argument against GPL on Apple platforms.
Evidence: [`research/01` §11](../research/01-existing-solutions.md#11-reusable-pieces-and-license-compatibility).

## Options
| | **GPL-3.0-or-later** | **Apache-2.0** |
|---|---|---|
| Keeps every fork free and open | ✅ copyleft | ❌ closed paid forks allowed |
| Can reuse KDE Connect / Sefirah code | ✅ | ❌ (protocol interop only) |
| Can reuse scrcpy, iroh, droidMirroring | ✅ | ✅ |
| Corporate contributors / embedding in other products | Harder | Easiest |
| Future Mac App Store build | ❌ (GPL vs App Store terms) | ✅ |
| Patent grant | ✅ (GPLv3 §11) | ✅ |

## Recommendation
**GPL-3.0-or-later for the apps**, with the protocol specification (`docs/protocol.md`, `proto/`) under
**CC-BY-4.0 / Apache-2.0** so other projects can implement compatible clients freely. This guarantees Tombolo
can never be turned into a paywalled closed fork while keeping the protocol open for interop.

## Decision
- **Tombolo is licensed under GPL-3.0-or-later** — full text in [`LICENSE`](../../LICENSE).
- **The protocol specification** ([`docs/protocol.md`](../protocol.md)) **and the schemas in `proto/`** (once
  they exist) are licensed under **Apache-2.0** — text in [`LICENSES/Apache-2.0.txt`](../../LICENSES/Apache-2.0.txt) —
  so anyone can build a compatible client or server under any licence.
- Third-party code keeps its own licence and notices (e.g. scrcpy's Apache-2.0 `NOTICE` once the helper is
  forked); every dependency must be GPL-3.0-compatible.
- Contributions are accepted under the same terms (inbound = outbound); no CLA.
