# core/ — tombolo-core (Rust)

> **No code here yet.** This directory is a placeholder from Phase 0 (task P0-01). `tombolo-core` is built in
> Phase 2 ("Connect"); the Phase 0 UniFFI and transport experiments (spikes S4, S5, S10) live in
> [`spikes/`](../spikes/README.md), not here.

**Purpose:** a Rust workspace with `tombolo-core` — the one shared implementation of networking, crypto and
protocol for both apps — and its UniFFI bindings for Swift and Kotlin. Capture, encoding, rendering, input, OS
integration and UI stay native in [`apple/`](../apple/README.md) and [`android/`](../android/README.md).

**Future owner:** the Android + core track (Dev B) — see [implementation plan §2](../docs/implementation-plan.md#2-resource-loaded-estimate-and-schedule-two-developers).

## Planned contents

As proposed in [architecture §5](../docs/architecture.md#5-tombolo-core-rust):

| Area | Responsibility |
|---|---|
| Transport | QUIC with datagrams (iroh / noq), or the per-path fallback chosen by spike S4; public relays and DNS discovery disabled |
| Pairing & identity | QR bootstrap, PAKE fallback, exporter-bound session authentication — implemented only after the security design is reviewed |
| Protocol | Protobuf `Envelope` framing from [`proto/`](../proto/README.md), media headers, capability negotiation, versioning |
| File transfer | Chunked, resumable, BLAKE3-verified transfers |
| Telemetry | RTT and clock-offset pings, latency breakdown for Diagnostics |

Prebuilt bindings are planned as CI artifacts, so app-only contributors don't need a Rust toolchain.

## Licence

GPL-3.0-or-later ([`LICENSE`](../LICENSE), [ADR-0007](../docs/decisions/0007-license.md)).
