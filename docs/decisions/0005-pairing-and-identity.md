# ADR-0005: Pairing and device identity

- **Status:** Proposed
- **Date:** 2026-10-25

## Context
Pairing grants full remote control of a phone. Common approaches have known weaknesses: trust-on-first-use
(LocalSend), short verification-code comparison that an active attacker can grind (KDE Connect's 32-bit key;
CVE-2025-66270 was an identity-binding bug), and low-entropy PINs used as keys (Moonlight). Android's own
Wireless debugging pairing (QR or 6-digit code → SPAKE2 bound to the TLS exporter) is a proven design. Only
P-256 keys are hardware-backed on both the Secure Enclave and Android StrongBox. Evidence:
[`research/04-transport-and-security.md` §5](../research/04-transport-and-security.md#5-pairing-encryption-and-threat-model).

## Decision
- **Primary:** the Mac shows a QR with its endpoint ID, addresses, SHA-256 of its P-256 identity key and a
  256-bit single-use secret (2–5 min TTL). The phone proves possession with an HMAC bound to the TLS exporter;
  both sides sign the transcript. The Mac user confirms the device with Touch ID; the **phone owner grants
  scopes on the phone**. Scopes are phone-authoritative, split by direction (view/control, read/reply-send,
  receive/send files) and enforced by the phone on every command.
- **Fallback:** a 6-digit code through SPAKE2 (RFC 9382) bound to the TLS exporter; max 3 attempts per code.
- **Identity keys:** P-256 in the Secure Enclave (Mac) and StrongBox/TEE (Android), non-exportable; the Mac key
  can require user presence, so "ask before control" is hardware-enforced. Transport keys are separate
  (encrypted at rest under a hardware-backed wrapping key).
- **Never:** TOFU on Wi-Fi, SAS-only comparison, plaintext mode, 0-RTT for control.
- **Process:** the complete state machine (canonical transcript, nonce ownership, persisted binding of transport
  key ↔ identity key ↔ scopes, atomic secret consumption and attempt limits across connections, concurrent
  attempts, rotation, recovery) is written with test vectors and **externally reviewed in Phase 0, before
  implementation**.

## Consequences
- Stronger than KDE Connect / LocalSend and close to Apple's model.
- A two-key design is more complex; spike S5 may simplify it to one key plus an app-level Touch ID gate.
- PAKE availability: implemented once in `tombolo-core` (RustCrypto `spake2`), which needs an external review
  before 1.0.
