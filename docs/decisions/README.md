# Architecture decision records

Short, dated records of the decisions that shape Tombolo. Status is one of *Proposed*, *Accepted*,
*Superseded*. Everything is *Proposed* until the maintainer approves the plan.

| # | Decision | Status |
|---|---|---|
| [0001](0001-two-tier-capability-model.md) | Two capability tiers (Standard + Enhanced) behind one protocol | Proposed |
| [0002](0002-native-apps.md) | Native apps: Swift (AppKit + SwiftUI) and Kotlin (Compose) | Proposed |
| [0003](0003-transport.md) | QUIC via a shared Rust core (iroh/noq), TLS-over-TCP fallback | Proposed — gated by spike S4/S5 |
| [0004](0004-enhanced-helper.md) | Enhanced mode helper forked from scrcpy-server | Proposed |
| [0005](0005-pairing-and-identity.md) | QR pairing, PAKE fallback, hardware-backed P-256 identity keys | Proposed |
| [0006](0006-distribution.md) | Distribution without paid services; no Mac App Store | Proposed |
| [0007](0007-license.md) | Licence | **Open — maintainer decision** |
