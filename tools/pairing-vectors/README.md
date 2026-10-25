# pairing-vectors

Deterministic generator for the pairing and session test vectors in
[`proto/testdata/pairing/`](../../proto/testdata/pairing/). It computes every cryptographic value defined in
[`docs/security/pairing-and-session.md`](../../docs/security/pairing-and-session.md) from fixed inputs, so both
apps (and `tombolo-core`) can be tested byte-for-byte against the same expectations.

**Status:** Phase 0 (task P0-03). The specification is a draft under external review; the vectors change whenever
the specification does.

## Commands

Run from this directory (`tools/pairing-vectors/`). Needs a Rust toolchain (tested with Rust 1.98); crates are
downloaded by Cargo on the first build.

```sh
cargo run --release               # regenerate proto/testdata/pairing/*.json
cargo run --release -- --check    # regenerate in memory and compare with the committed files
cargo run --release -- --out DIR  # write to (or, with --check, compare against) DIR instead
cargo test --release              # self-tests, determinism, and "committed vectors are current"
```

Exit status: `0` success; `1` `--check` found a mismatch, a missing file, or a stale `.json` the generator does not
produce (the first differing line is printed); `2` a self-test failed (nothing is written); `64` bad arguments.

Every run first prints its self-tests, for example:

```text
self-test RFC 9382 Appendix B vector 1 (A="server", B="client"): 12/12 values match
…
self-test RFC 9382 Appendix A: M regenerated and matches (iteration 5), N regenerated and matches (iteration 3)
self-test RFC 6979 A.2.5 (P-256, SHA-256): public key matches, 2/2 signatures match
```

## What it checks before generating

- **SPAKE2.** RustCrypto's `spake2` crate (0.4.0, 0.5.0-pre.0) supports only Ed25519 with a python-spake2-style
  transcript, so `src/spake2.rs` implements RFC 9382's SPAKE2-P256-SHA256-HKDF-HMAC directly on `p256`. It must
  reproduce all four RFC 9382 Appendix B vectors (`pA`, `pB`, `K` from both sides, `TT`, `Hash(TT)`, `Ke`, `Ka`,
  `KcA`, `KcB`, `cA`, `cB`), and it regenerates `M` and `N` with the RFC's Appendix A procedure. The RFC values
  are copied into the source from <https://www.rfc-editor.org/rfc/rfc9382.txt>; the report is
  `spake2-rfc9382.json`.
- **ECDSA.** Signing must reproduce RFC 6979 §A.2.5 (P-256, SHA-256, messages `sample` and `test`); report in
  `ecdsa-rfc6979.json`.
- **SPKI.** The hand-built P-256 SubjectPublicKeyInfo (fixed prefix + point) must equal the `pkcs8` encoder's.

## Fixed inputs

There is no live TLS connection, so **every TLS exporter value is a fixed 32-byte stand-in**, as are endpoint IDs
(stand-ins for Ed25519 public keys), nonces, secrets, SPAKE2 scalars `x`/`y` and private keys. They come from

```text
test_bytes(name, len) = first len bytes of  SHA-256("tombolo-test-vector:" ‖ name ‖ ":" ‖ u32be(0))
                                          ‖ SHA-256("tombolo-test-vector:" ‖ name ‖ ":" ‖ u32be(1)) ‖ …
```

with descriptive names such as `qr/exporter-pair` (see `src/vectors.rs`). Every resulting byte string is written
into the JSON next to the values derived from it, so other implementations read inputs from the JSON and never
need `test_bytes`. Signatures use RFC 6979 deterministic nonces so they are reproducible; hardware keys (Secure
Enclave, Android Keystore) sign with random nonces, so implementations test those by **verifying** the vectors'
transcripts and signatures and by checking their own signatures verify.

## Output files

| File | Contents |
|---|---|
| `encoding.json` | `LP`, `enc`, `seq`, canonical sets, integer, key, SPKI and signature encodings; must-reject inputs |
| `spake2-rfc9382.json` | RFC 9382 cross-check report |
| `ecdsa-rfc6979.json` | RFC 6979 cross-check report |
| `qr-pairing.json` | QR payload and URI, pairing key schedule, `T_req`/`T_acc`/`T_cmp`, proofs, signatures, `pair_id`, discovery key; MITM and `k`-mismatch negatives |
| `code-pairing.json` | SPAKE2 run with fixed scalars, identity exchange; wrong code, invalid points, leading-zero `w` |
| `session.json` | `SessionAuth` in both dial directions, session keys, channel binding, elevation, key rotation; negatives |
| `discovery.json` | epochs, tokens, fillers, TXT `t=` values |
| `op-payload.json` | `op_hash` for each side-effect kind, UUIDv7 `op_id`, acceptance window |

Each transcript is given as its label, its named fields and the full `enc()` encoding in hex, so a mismatch can be
traced to a single field.

## Changing the vectors

Change the specification first, then the generator, then run `cargo run --release` and commit the regenerated
JSON in the same change. `--check` (and `cargo test`) fail whenever the committed files and the generator
disagree. Crate versions are pinned exactly in `Cargo.toml` and `Cargo.lock` is committed, so the output does not
drift with dependency updates.

## Licence

The generator is GPL-3.0-or-later, like the rest of the repository's tools. The generated vectors live under
`proto/` and are Apache-2.0 like the protocol specification ([`proto/README.md`](../../proto/README.md)).
