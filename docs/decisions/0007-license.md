# ADR-0007: Licence

- **Status:** **Open — needs the maintainer's decision** (no LICENSE file is committed until then)
- **Date:** 2026-10-25

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
_Pending._
