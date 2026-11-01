# core/ — tombolo-core (Rust)

> **No code here yet.** This directory is a placeholder from Phase 0 (task P0-01). `tombolo-core` is built from
> [Phase 1](../docs/implementation-plan.md#phase-1--mirror-no-developer-options-3450-ew--release-01) ("Mirror, no
> developer options", release 0.1); the Phase 0 UniFFI and transport experiments (spikes S4, S5, S10) live in
> [`spikes/`](../spikes/README.md), not here.

**Purpose:** a Rust workspace with `tombolo-core` — the one shared implementation of networking, crypto and
protocol for both apps — and its UniFFI bindings for Swift and Kotlin. Capture, encoding, rendering, input, OS
integration and UI stay native in [`apple/`](../apple/README.md) and [`android/`](../android/README.md).

**Future owner:** the Android + core track (Dev B) — see [implementation plan §2](../docs/implementation-plan.md#2-resource-loaded-estimate-and-schedule-two-developers).

## Planned contents

As proposed in [architecture §5](../docs/architecture.md#5-tombolo-core-rust):

| Area | Phase | Responsibility |
|---|---|---|
| Transport | 1 | QUIC with datagrams (iroh / noq), or the per-path fallback chosen by spike S4; public relays and DNS discovery disabled; local Wi-Fi only in 0.1 |
| Pairing & identity | 1 | QR bootstrap, PAKE fallback, exporter-bound session authentication, hardware-backed keys, revocation — **built behind a feature flag; nothing that contains it ships until the external review of the security design closes** (every finding resolved or explicitly accepted) |
| Protocol | 1 | Protobuf `Envelope` framing from [`proto/`](../proto/README.md), media headers, capability negotiation, versioning, the robustness rules of [protocol §8](../docs/protocol.md#8-robustness-rules); baseline parser fuzzing from the day each parser lands |
| File transfer | 2 | Chunked, resumable, BLAKE3-verified transfers |
| Telemetry | 1 | RTT and clock-offset pings, latency breakdown for Diagnostics |

Prebuilt bindings are planned as CI artifacts, so app-only contributors don't need a Rust toolchain.

## Licence

GPL-3.0-or-later ([`LICENSE`](../LICENSE), [ADR-0007](../docs/decisions/0007-license.md)).
