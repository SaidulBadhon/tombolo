# Architecture decision records

Short, dated records of the decisions that shape Tombolo. Status is one of *Proposed*, *Accepted*,
*Superseded*. Technical ADRs stay *Proposed* until Phase 0 evidence confirms them; maintainer decisions are
marked *Accepted* when made. A later decision that changes an ADR is appended to it as a dated amendment; the
original text stays.

| # | Decision | Status |
|---|---|---|
| [0001](0001-two-tier-capability-model.md) | Two capability tiers (Standard + Enhanced) behind one protocol | Proposed |
| [0002](0002-native-apps.md) | Native apps: Swift (AppKit + SwiftUI) and Kotlin (Compose) | Proposed |
| [0003](0003-transport.md) | QUIC via a shared Rust core (iroh/noq), TLS-over-TCP fallback | Proposed — gated by spike S4/S5 |
| [0004](0004-enhanced-helper.md) | Enhanced mode helper forked from scrcpy-server | Proposed (amended 2026-11-02: pinned server / helper Advanced-only, set up from the phone app) |
| [0005](0005-pairing-and-identity.md) | QR pairing, PAKE fallback, hardware-backed P-256 identity keys | Proposed (amended 2026-11-02: implemented behind a flag, nothing ships until the external review closes; pairing in 0.1) |
| [0006](0006-distribution.md) | Distribution without paid services; no Mac App Store; project fees paid once there are users | Proposed (funding timing accepted 2026-10-26; amended 2026-11-02: Android public distribution from 0.1, GitHub/F-Droid first, Play deferred) |
| [0007](0007-license.md) | Licence: GPL-3.0-or-later; protocol spec Apache-2.0 | **Accepted** (2026-10-26) |
| [0008](0008-standard-mode-first.md) | Standard mode first: 0.1 needs no Developer options; Enhanced mode becomes the optional Advanced phase (0.3) | **Accepted** (2026-11-02) |
