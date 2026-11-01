# External review request — pairing and session design

> **Status: sent 2026-11-02** as [issue #10](https://github.com/SaidulBadhon/tombolo/issues/10) (label
> `security-design`). Prerequisite M4 of the Phase 0 plan: the maintainer chose a **public** review request. The issue
> body is everything below the line; it uses absolute links, because relative links do not resolve in issues. Later
> revisions of the specification are linked from the issue.

---

## Request for review: Tombolo's pairing and session security design

We are looking for people who know TLS 1.3, PAKEs and protocol design to review the **design** of how
[Tombolo](https://github.com/SaidulBadhon/tombolo) pairs an Android phone with a Mac and authenticates every later
session. No implementation exists yet. Any implementation that starts during the review stays behind a feature
flag and changes with the findings, so this is the moment when a review costs least and changes most.

**Why it matters:** a paired Mac can view the phone's screen, inject input, read and send SMS, act on notifications
and exchange files. A flaw here is a full compromise of the phone.

**Release gate:** this follows a [maintainer decision of 2026-11-02](https://github.com/SaidulBadhon/tombolo/blob/main/docs/plans/standard-first.md#9-maintainer-decisions-2026-11-02).
- **Implementation may start behind a feature flag** while this review is open.
- **Nothing that contains it ships until this review is closed**, that is, until every finding is resolved in the
  specification or explicitly accepted with a written rationale.
- Pairing is part of Tombolo's first release (0.1), so this review gates that release.

- **Specification:** [`docs/security/pairing-and-session.md`](https://github.com/SaidulBadhon/tombolo/blob/main/docs/security/pairing-and-session.md)
  (Apache-2.0, draft 0.2 — please review the version on `main` at the time you read it; we link every revision
  from this issue)
- **Expected effort:** about 1–2 days of reading for someone familiar with TLS 1.3 and PAKEs. Partial reviews of a
  single section are very welcome.
- This is a volunteer project; there is no bounty. Reviewers are credited in the specification unless they prefer
  not to be.

### The system in one paragraph

Two native apps share one Rust core (`tombolo-core`). They talk QUIC (TLS 1.3 via rustls, through iroh/noq) with
mutually pinned Ed25519 raw public keys, over Wi-Fi. Any later USB path is treated as an untrusted tunnel. Pairing is
a QR code shown on the Mac (endpoint ID, addresses, SHA-256 of a fresh P-256 identity key, 256-bit one-time secret)
with exporter-bound HMAC proofs and signatures in both directions, or a 6-digit code through SPAKE2 (RFC 9382, P-256)
with `password = code ‖ TLS exporter`. Each pairing creates per-binding, hardware-backed P-256 identity keys (Secure
Enclave / StrongBox or TEE); every session signs the TLS exporter with them. Scopes are granted and enforced by the
phone only. "Ask every time" is a separate Touch ID–gated signature that the phone verifies. Control is fail-closed
through a phone-side lease.

### In scope

- Pairing: QR flow, code flow (SPAKE2 parameters, `w` derivation, identities, AAD, key confirmation), identity
  exchange and its transcripts (spec §7).
- Ticket handling: one-time consumption, attempt limits across connections, crash safety, concurrent attempts
  (§7.2, §7.8).
- Sessions: key pinning, exporter-bound `SessionAuth`, nonce ownership, 0-RTT and resumption, channel binding for
  the TLS/TCP fallback, concurrent sessions (§6, §8).
- Scopes and their enforcement points; elevation with the Mac presence key (§9).
- The fail-closed lease (§10). The timing values are not final; draft 0.2 revised them to meet a 1 s release
  deadline (§10 rule 7).
- `op_id` payload binding (§11) and discovery-token privacy (§12).
- Key rotation, device loss and recovery, revocation, downgrade handling (§13–§16).
- The canonical transcript encoding and label registry (§5).
- Whether the threat mapping (§17) is honest, and whether our deviations from earlier documents (§19) are sound.

### Out of scope

- Code (none exists yet), UI, media framing, file-transfer integrity.
- ADB, only in its role as the platform authority of the optional Advanced phase (0.3), where it starts the
  Enhanced-mode helper. Once Wireless debugging is on, any ADB-authorised controller can drive the phone outside
  Tombolo's scopes ([architecture §8](https://github.com/SaidulBadhon/tombolo/blob/main/docs/architecture.md#8-security-model)).
  No release before 0.3 uses ADB.
- The helper ↔ app channel and remote access through a relay (v2).
- Rooted phones and same-user Mac malware with TCC grants, which the threat model excludes — comments on cheap
  mitigations are still welcome.

### Questions we most want answered

The specification ends with sixteen open questions (§20). The most important:

1. **Exporter channel binding** with raw-public-key QUIC: is `TLS-Exporter(label, "", 32)` plus our transcripts
   enough (§3, §8.2)? Should our exporter labels carry RFC 5705's `EXPERIMENTAL` prefix, or be registered (Q1, Q2)?
2. **SPAKE2 without a memory-hard function** for `w`, because the password is single-use and bound to one TLS
   connection (Q3); identities = TLS endpoint IDs, AAD = both nonces and both ALPN lists (Q4); identity values MACed
   with PAKE-derived keys inside TLS instead of a second AEAD layer (Q5).
3. **Ticket semantics:** first valid proof wins, a second valid proof marks the QR as compromised, invalid proofs cost
   attempts (a DoS trade-off, Q10), memory-only tickets for crash safety (§7.2). Is the residual risk of a leaked QR
   (T12) acceptable without a confirmation code (Q8)?
4. **Elevation:** a non-presence identity key for sessions plus a presence-gated key for "ask every time", verified by
   the phone; `.userPresence` vs `.biometryCurrentSet` (Q6); presence-key rotation requiring the phone owner's
   approval (§13.2).
5. **Per-binding identity keys** instead of one per device (Q7, D5).
6. **Lease:** phone-paced challenge–response, with the lease measured from the phone's own issue time (§10 rule 2).
   Does it bound the lease against delayed or replayed renewals as claimed? Does the bound still hold with
   independently surviving components (rule 10), and is it right that no elevation survives a release (rule 6, Q9)?
7. **Key rotation** with persisted receipts and exact-retry semantics (§13.2): any rollback or confusion attack left?
8. **Revocation without a peer oracle:** the stale side learns only from rejected connections (§15). Acceptable?
9. **Anything missing** from the threat mapping (§17), or a mechanism listed there that does not mitigate its threat.

### Known gaps and dependencies

The design rests on prototype results that are partly **not in yet**. Please treat these as assumptions, and tell
us if the design is fragile with respect to them:

| Assumption | Prototype ("spike") | Status |
|---|---|---|
| TLS exporter available in iroh/noq (A2) | S5 | Tested on the Mac: pass ([S5 write-up](https://github.com/SaidulBadhon/tombolo/blob/main/docs/spikes/s05-iroh-api.md)) |
| Peer key known and rejectable before application data (A3); per-ALPN peer-key policy (A5); 0-RTT and resumption can be disabled (A6) | S5 | Not yet tested |
| Lease timing: 100 ms ticks, 700 ms lease, 500 ms answer age, ≤ 250 ms release completion, 5 s quiet period; in-flight cancellation; the bound with independently surviving components | S7 | Not started. Revised in draft 0.2: the worst case for events the phone cannot observe is 700 + 250 = 950 ms, within S7's 1 s release deadline (§10 rule 7). Draft 0.1's values gave ~1.25 s |
| Hardware signing via UniFFI; Secure Enclave access-control flags | S10 | Partly: a `.userPresence` key refuses to sign without interaction; reuse duration 0 and a real Touch ID run are untested |
| The Enhanced-mode helper obeys the lease (enforcement point E4, §9.2) | S12 | Not yet run (depends on S7). Moved to the optional Advanced phase (0.3) |

### Materials

| Material | Why |
|---|---|
| [Specification](https://github.com/SaidulBadhon/tombolo/blob/main/docs/security/pairing-and-session.md) | What is under review |
| [Protocol draft](https://github.com/SaidulBadhon/tombolo/blob/main/docs/protocol.md) §2, §6, §8 | Message names and robustness rules it completes |
| [Architecture](https://github.com/SaidulBadhon/tombolo/blob/main/docs/architecture.md) §5, §7, §8 | Where the core, discovery and the security model sit |
| [ADR-0003 (transport)](https://github.com/SaidulBadhon/tombolo/blob/main/docs/decisions/0003-transport.md), [ADR-0005 (pairing)](https://github.com/SaidulBadhon/tombolo/blob/main/docs/decisions/0005-pairing-and-identity.md) | Decisions this design implements |
| [ADR-0008 (Standard mode first)](https://github.com/SaidulBadhon/tombolo/blob/main/docs/decisions/0008-standard-mode-first.md) | Release order (pairing ships in 0.1) and the review gate |
| [Research 04 §5](https://github.com/SaidulBadhon/tombolo/blob/main/docs/research/04-transport-and-security.md#5-pairing-encryption-and-threat-model) | Prior art (KDE Connect, LocalSend, Moonlight, adb Wireless debugging, Quick Share, iPhone Mirroring) and threat model T1–T16 |
| [Test vectors](https://github.com/SaidulBadhon/tombolo/tree/main/proto/testdata/pairing) | Byte-exact values for every computation, including negative cases |
| [Vector generator](https://github.com/SaidulBadhon/tombolo/tree/main/tools/pairing-vectors) | Rust; its SPAKE2 reproduces RFC 9382 Appendix A/B and its ECDSA RFC 6979 §A.2.5 |

To regenerate and verify the vectors: `cd tools/pairing-vectors && cargo run --release --locked -- --check`.

### How to respond

- **Comment on this issue** — one comment per finding, or one comment linking to a document, whichever suits you.
- If you think a finding **should not be public** (for example, it would also affect existing software that uses a
  similar design), report it privately instead via
  [private vulnerability reporting](https://github.com/SaidulBadhon/tombolo/security/advisories/new), as described
  in [`SECURITY.md`](https://github.com/SaidulBadhon/tombolo/blob/main/SECURITY.md).
- Per finding, please give: the section, the problem, an attack or failure scenario, a suggested fix if you have
  one, and a severity:

| Severity | Meaning |
|---|---|
| Critical | An attacker without a paired device gains control or data of a phone or Mac |
| High | A scope, elevation, lease or revocation guarantee can be bypassed, or pairing can be hijacked under realistic conditions |
| Medium | A guarantee weakens under specific conditions, or an implementer following the spec would likely get it wrong |
| Low | Hardening, clarity, or a deviation from best practice without a known attack |

**What happens next:** each finding becomes its own tracked issue, linked from here, and is closed only by a change
to the specification and test vectors, or by a written "accepted risk" rationale posted here. This review is closed
when every finding is in one of those two states.
