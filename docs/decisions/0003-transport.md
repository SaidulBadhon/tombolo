# ADR-0003: Transport — QUIC via a shared Rust core, with a TLS/TCP fallback

- **Status:** Proposed — final choice made at the Phase 0 gate (spikes S4, S5)
- **Date:** 2026-10-25

## Context
Tombolo carries several independent flows at once: input (latency-critical, tiny), one video stream per
window, audio, and bulk file transfers. Over TCP a single lost packet stalls everything behind it on that
connection. USB connections go through `adb forward`, which carries **TCP only**. Android has no mature JVM
QUIC library that can act as a server; Apple's Network.framework QUIC datagram API is either mis-modelled or
macOS 26+ with an open bug, and it can't run over an adb TCP tunnel. Evidence:
[`research/04-transport-and-security.md` §2](../research/04-transport-and-security.md#2-transport-options-lan-latency-first-multiple-streams).

## Decision
- Build **`tombolo-core`** in Rust on **iroh 1.x / noq** (MIT/Apache-2.0; official Kotlin and Swift bindings via
  UniFFI). QUIC streams per channel with priorities, RFC 9221 datagrams for audio and clock pings, TLS 1.3
  everywhere.
- Wi-Fi: native UDP. USB: decided by spike S4 between (a) the same QUIC packets length-prefixed over one
  adb-forwarded TCP socket and (b) framed channels over several adb forwards. One TCP stream under QUIC can
  re-introduce cross-channel blocking and makes datagrams effectively reliable, so (b) is the expected USB
  answer unless S4 shows otherwise.
- **Fallback:** if S4 rejects QUIC on a path, that path uses **TLS 1.3 over TCP, one connection per channel,
  implemented with rustls inside `tombolo-core`** — not the platforms' TLS stacks — so authentication and framing
  keep a single owner. Extra connections are bound to the session with an exporter-derived token.
- iroh's **default public relays and DNS address lookup are disabled**; Tombolo must work with outbound
  Internet blocked (CI test). Remote access later uses a self-hosted relay only.
- Rejected for v1: WebRTC (8–12 MB/ABI, SDP/ICE complexity, weak bulk path, no USB path), Network.framework +
  a JVM QUIC library (two stacks, no good Android server), SRT (no multiplexing).

## Consequences
- One implementation of transport, pairing crypto and framing for both apps — fewer security-critical
  divergences. Hardware-key signing must call back from Rust into Swift/Kotlin (Secure Enclave / Keystore);
  spike S10 proves callbacks, cancellation, threading and 60 fps media throughput through UniFFI.
- Costs ≈ 13 MB native per Android ABI and a Rust toolchain in both builds; CI must publish prebuilt bindings so
  app-only contributors don't need Rust.
- The same core extends to remote access later (iroh NAT traversal + self-hosted relay).
