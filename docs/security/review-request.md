# External review request — Tombolo pairing and session design

> Status: **draft, not sent.** The maintainer finds and contacts a reviewer (Phase 0 prerequisite **M4** in the
> [Phase 0 plan](../plans/phase-0.md)); nobody has been contacted. Before sending, the maintainer fills in the
> blanks marked *(maintainer)* and pins the commit to review.

## 1. What we are asking for

An independent review of the **design** — not code, which does not exist yet — of how Tombolo pairs an Android
phone with a Mac and authenticates every later session. A paired Mac can view the phone's screen, inject input,
read and send SMS, act on notifications and exchange files, so a flaw here is a full compromise of the phone.

Per the Phase 0 plan, **Phase 2 may not implement pairing until this review is closed**: every finding resolved in
the specification or explicitly accepted with a written rationale.

| | |
|---|---|
| Specification under review | [`pairing-and-session.md`](pairing-and-session.md), commit *(maintainer: pin SHA)* |
| Expected effort | about 1–2 days of reading for a reviewer familiar with TLS 1.3 and PAKEs *(maintainer: confirm)* |
| Reviewer | *(maintainer)* |
| Terms | volunteer or funded — *(maintainer)*; findings are credited unless the reviewer prefers otherwise |
| Target date | *(maintainer)* |

## 2. The system in one paragraph

Two native apps share one Rust core (`tombolo-core`). They talk QUIC (TLS 1.3 via rustls, through iroh/noq) with
mutually pinned Ed25519 raw public keys, on Wi-Fi or through an untrusted adb USB tunnel. Pairing is a QR code
shown on the Mac (endpoint ID, addresses, SHA-256 of a fresh P-256 identity key, 256-bit one-time secret) with
exporter-bound HMAC proofs and signatures in both directions, or a 6-digit code through SPAKE2 (RFC 9382, P-256)
with `password = code ‖ TLS exporter`. Each pairing creates per-binding, hardware-backed P-256 identity keys
(Secure Enclave / StrongBox or TEE); every session signs the TLS exporter with them. Scopes are granted and
enforced by the phone only. "Ask every time" is a separate Touch ID–gated signature verified by the phone.
Control is fail-closed through a phone-side lease.

## 3. Scope

**In scope**

- Pairing: QR flow, code flow (SPAKE2 parameters, `w` derivation, identities, AAD, key confirmation), identity
  exchange and its transcripts (spec §7).
- Ticket handling: one-time consumption, attempt limits across connections, crash safety, concurrent attempts
  (§7.2, §7.8).
- Session establishment: key pinning, exporter-bound `SessionAuth`, nonce ownership, 0-RTT and resumption,
  channel binding for the TLS/TCP fallback, concurrent sessions (§6, §8).
- Scope model and enforcement points; elevation with the Mac presence key (§9).
- Lease semantics for fail-closed control (§10) — the timing values are not final (see §5 below).
- `op_id` payload binding (§11), discovery-token privacy (§12).
- Key rotation, device loss and recovery, revocation and propagation, downgrade handling (§13–§16).
- The canonical transcript encoding and label registry (§5).
- Whether the threat mapping (§17) is honest, and whether the deviations from earlier documents (§19) are sound.

**Out of scope**

- Code (none exists), UI, media framing, file-transfer integrity.
- The 0.1–0.2 ADB trust path ([architecture §8](../architecture.md#8-security-model), "documented exception").
- The helper ↔ app channel (spike S12) and remote access through a relay (v2).
- Rooted phones and same-user Mac malware with TCC grants, which the threat model excludes — though we welcome
  comments if a cheap mitigation exists.

## 4. Specific questions

The specification ends with sixteen open questions (§20). The ones we most want an answer to:

1. **Exporter channel binding** with raw-public-key QUIC: is `TLS-Exporter(label, "", 32)` plus our transcripts
   enough (§3, §8.2)? Should the labels carry RFC 5705's `EXPERIMENTAL` prefix or be registered (Q1, Q2)?
2. **SPAKE2 without a memory-hard function** for `w`, because the password is single-use and bound to one TLS
   connection (Q3); identities = TLS endpoint IDs, AAD = both nonces and both ALPN lists (Q4); identity values
   MACed with PAKE-derived keys inside TLS instead of a second AEAD layer (Q5).
3. **Ticket semantics:** first valid proof wins, a second valid proof marks the QR as compromised, invalid proofs
   cost attempts (DoS trade-off, Q10), memory-only tickets for crash safety (§7.2). Is the T12 (leaked QR) residual
   acceptable without a confirmation code (Q8)?
4. **Elevation design:** a non-presence identity key for sessions plus a presence-gated key for "ask every time",
   verified by the phone; `.userPresence` vs `.biometryCurrentSet` (Q6); presence-key rotation requiring phone
   approval (§13.2).
5. **Per-binding identity keys** instead of one per device (Q7, D5).
6. **Lease:** phone-paced challenge–response with the lease measured from the phone's own issue time (§10 rule 2):
   does it bound the lease against delayed or replayed renewals as claimed?
7. **Revocation without a peer oracle:** the stale side learns only from rejected connections (§15). Acceptable?
8. **Anything missing** from the threat mapping (§17), or a mechanism there that does not actually mitigate the
   threat it is listed against.

## 5. Known gaps and dependencies

The design rests on results that are **not in yet**; please treat these as assumptions and tell us if the design
is fragile with respect to them:

| Dependency | Spike / task | What it must confirm |
|---|---|---|
| TLS exporter and per-ALPN peer-key policy in iroh/noq (assumptions A2, A3, A5) | S5 (P0-14) | Exporter available; unknown client keys acceptable only on `tombolo-pair/1`; peer key known before app data |
| Lease timing (250 ms ticks, 1000 ms lease, 500 ms answer age, 5 s quiet period) | S7 (P0-07) | That the numbers meet "release within 1 s"; §10 rule 7 notes the proposed values give ~1.25 s for events the phone cannot observe |
| Hardware signing through UniFFI, latency, access-control flags | S10 (P0-12) | Secure Enclave and Keystore signing work as assumed in §4.1 |
| Helper obeys the lease | S12 (P0-17) | Enforcement point E4 (§9.2) |

## 6. Materials

| Material | Why |
|---|---|
| [`pairing-and-session.md`](pairing-and-session.md) | The specification under review |
| [`protocol.md`](../protocol.md) §2, §6, §8 | The protocol it completes (message names, robustness rules) |
| [`architecture.md`](../architecture.md) §5, §7, §8 | Where the core, discovery and the security model sit |
| [ADR-0003](../decisions/0003-transport.md), [ADR-0005](../decisions/0005-pairing-and-identity.md) | Transport and pairing decisions |
| [Research 04 §5](../research/04-transport-and-security.md#5-pairing-encryption-and-threat-model) | Prior art compared (KDE Connect, LocalSend, Moonlight, adb Wireless debugging, Quick Share, iPhone Mirroring) and threat model T1–T16 |
| [`proto/testdata/pairing/`](../../proto/testdata/pairing/) | Byte-exact test vectors for every computation, including negative cases |
| [`tools/pairing-vectors/`](../../tools/pairing-vectors/README.md) | The generator (Rust); its SPAKE2 is cross-checked against RFC 9382 Appendix A/B and its ECDSA against RFC 6979 |

To regenerate and verify the vectors: `cd tools/pairing-vectors && cargo run --release -- --check` (see its
README).

## 7. How to report

- **Anything that could be exploitable** — including a design flaw — please report privately as described in
  [`SECURITY.md`](../../SECURITY.md) (GitHub private vulnerability reporting).
- Other design comments can go in the same advisory, or to the maintainer in whatever form you prefer; a single
  document is fine.
- Per finding, please give: the section, the problem, an attack or failure scenario, a suggested fix if you have
  one, and a severity:

| Severity | Meaning |
|---|---|
| Critical | An attacker without a paired device gains control or data of a phone or Mac |
| High | A scope, elevation, lease or revocation guarantee can be bypassed, or pairing can be hijacked under realistic conditions |
| Medium | A guarantee weakens under specific conditions, or an implementer following the spec would likely get it wrong |
| Low | Hardening, clarity, or a deviation from best practice without a known attack |

**What we do with findings:** each one becomes a tracked GitHub issue (private advisory first where it is
sensitive), linked to the change in the specification and test vectors that resolves it, or closed with a written
"accepted risk" rationale that you have seen. The review is **closed** when every finding is in one of those two
states and you agree. We will credit you in the specification unless you ask us not to.
