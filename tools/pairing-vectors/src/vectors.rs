// SPDX-License-Identifier: GPL-3.0-or-later
//! Builders for every JSON file in proto/testdata/pairing/. Section numbers refer to
//! docs/security/pairing-and-session.md.
//!
//! FIXED INPUTS. No live TLS session exists here, so every TLS exporter value is a fixed 32-byte stand-in
//! produced by `test_bytes(name, 32)` (see crypto.rs); so are endpoint IDs (stand-ins for Ed25519 public
//! keys — no computation in this spec needs them to be valid points), nonces, secrets and private scalars.
//! Every resulting byte string is written into the JSON, so other implementations never need to reproduce
//! `test_bytes`.

use crate::crypto::{
    b64u, hkdf, hkdf_expand, hkdf_extract, hmac, sha256, sig_to_der, spki_der, spki_der_library,
    test_bytes, verify, Key,
};
use crate::enc::*;
use crate::spake2;
use serde_json::{json, Value};

const ALPNS: [&str; 1] = ["tombolo/1"];
const ALL_SCOPES: [&str; 12] = [
    "calls.control",
    "calls.state",
    "clipboard.read",
    "clipboard.write",
    "files.receive",
    "files.send",
    "notifications.act",
    "notifications.read",
    "screen.control",
    "screen.view",
    "sms.read",
    "sms.send",
];
const SCOPES_HINT: [&str; 10] = [
    "clipboard.read",
    "clipboard.write",
    "files.receive",
    "files.send",
    "notifications.act",
    "notifications.read",
    "screen.control",
    "screen.view",
    "sms.read",
    "sms.send",
];
const GRANTED: [&str; 4] = ["notifications.read", "screen.control", "screen.view", "sms.read"];
const ELEVATION_SCOPES: [&str; 2] = ["screen.control", "screen.view"];

const QR_CREATED_UNIX: u64 = 1_793_000_000;
const TICKET_TTL_S: u64 = 120;

fn h(x: &[u8]) -> String {
    hex::encode(x)
}

fn header(description: &str, section: &str) -> serde_json::Map<String, Value> {
    let mut m = serde_json::Map::new();
    m.insert("description".into(), json!(description));
    m.insert("spec".into(), json!(format!("docs/security/pairing-and-session.md {section}")));
    m.insert("generator".into(), json!("tools/pairing-vectors (cargo run --release)"));
    m.insert(
        "conventions".into(),
        json!("Byte strings are lowercase hex. Transcripts list each field and the full enc() encoding. TLS exporter values, endpoint IDs, nonces, secrets and private scalars are fixed stand-ins (no live TLS session exists in the generator). Signatures use RFC 6979 deterministic nonces; real hardware signatures differ and must be tested by verification."),
    );
    m
}

fn obj(mut head: serde_json::Map<String, Value>, body: Value) -> Value {
    if let Value::Object(b) = body {
        head.extend(b);
    }
    Value::Object(head)
}

/// Endpoint IDs of the two test devices (stand-ins for Ed25519 public keys).
pub struct Devices {
    pub phone_eid: Vec<u8>,
    pub mac_eid: Vec<u8>,
}

pub fn devices() -> Devices {
    Devices { phone_eid: test_bytes("phone/endpoint-id", 32), mac_eid: test_bytes("mac/endpoint-id", 32) }
}

/// Everything a later vector needs from a pairing.
pub struct Binding {
    pub pair_id: Vec<u8>,
    pub discovery_key: Vec<u8>,
    pub phone_key: Key,
    pub mac_key: Key,
    pub presence_key: Key,
}

struct PairInputs<'a> {
    method: u8,
    exporter_pair: &'a [u8],
    method_secret: &'a [u8],
    dev: &'a Devices,
    n_p: &'a [u8],
    n_m: &'a [u8],
    qr_k: &'a [u8],
    phone_key: &'a Key,
    mac_key: &'a Key,
    presence_key: &'a Key,
    phone_name: &'a str,
    phone_model: &'a str,
    phone_os: &'a str,
    mac_name: &'a str,
}

struct PairOut {
    json: Value,
    pair_id: Vec<u8>,
    discovery_key: Vec<u8>,
    prk_pair: Vec<u8>,
    t_req: Tr,
}

/// §7.4 key schedule and §7.7 identity exchange (identical for both flows).
fn identity_exchange(p: &PairInputs) -> PairOut {
    let ikm = Tr::new("tombolo/pair/v1/ikm").f("method", u8b(p.method)).f("method_secret", p.method_secret);
    let prk = hkdf_extract(p.exporter_pair, &ikm.bytes());
    let k_pp = hkdf_expand(&prk, b"tombolo/pair/v1/key/proof-phone", 32);
    let k_pm = hkdf_expand(&prk, b"tombolo/pair/v1/key/proof-mac", 32);
    let dk = hkdf_expand(&prk, b"tombolo/pair/v1/key/discovery", 32);

    let t_req = Tr::new("tombolo/pair/v1/request")
        .f("method", u8b(p.method))
        .f("exporter_pair", p.exporter_pair)
        .f("phone_endpoint_id", &p.dev.phone_eid)
        .f("mac_endpoint_id", &p.dev.mac_eid)
        .f("n_P", p.n_p)
        .f("n_M", p.n_m)
        .f("qr_k", p.qr_k)
        .f("phone_identity_pub", &p.phone_key.pub65)
        .f("name", p.phone_name)
        .f("model", p.phone_model)
        .f("os", p.phone_os)
        .f("phone_session_alpns", set_str(&ALPNS));
    let proof_p = hmac(&k_pp, &t_req.bytes());
    let sig_p = p.phone_key.sign(&t_req.bytes());

    let t_acc = Tr::new("tombolo/pair/v1/accept")
        .f("H(T_req)", sha256(&t_req.bytes()))
        .f("mac_identity_pub", &p.mac_key.pub65)
        .f("mac_presence_pub", &p.presence_key.pub65)
        .f("mac_name", p.mac_name)
        .f("scopes_hint", set_str(&SCOPES_HINT))
        .f("mac_session_alpns", set_str(&ALPNS));
    let proof_m = hmac(&k_pm, &t_acc.bytes());
    let sig_m = p.mac_key.sign(&t_acc.bytes());
    let sig_pm = p.presence_key.sign(&t_acc.bytes());

    let t_cmp = Tr::new("tombolo/pair/v1/complete")
        .f("H(T_acc)", sha256(&t_acc.bytes()))
        .f("scopes", set_str(&GRANTED))
        .f("elevation_required", u8b(1))
        .f("elevation_scopes", set_str(&ELEVATION_SCOPES));
    let sig_c = p.phone_key.sign(&t_cmp.bytes());
    let pair_id = sha256(&t_cmp.bytes())[..16].to_vec();

    let checks = [
        verify(&p.phone_key.pub65, &t_req.bytes(), &sig_p),
        verify(&p.mac_key.pub65, &t_acc.bytes(), &sig_m),
        verify(&p.presence_key.pub65, &t_acc.bytes(), &sig_pm),
        verify(&p.phone_key.pub65, &t_cmp.bytes(), &sig_c),
    ];
    assert!(checks.iter().all(|c| *c), "a generated signature failed to verify");

    let json = json!({
        "key_schedule": {
            "ikm_pair": ikm.json(),
            "PRK_pair": h(&prk),
            "K_proof_phone": h(&k_pp),
            "K_proof_mac": h(&k_pm),
            "discovery_key": h(&dk),
        },
        "PairRequest": {
            "fields": {
                "phone_identity_pub": h(&p.phone_key.pub65),
                "name": p.phone_name, "model": p.phone_model, "os": p.phone_os,
            },
            "T_req": t_req.json(),
            "H(T_req)": h(&sha256(&t_req.bytes())),
            "proof": h(&proof_p),
            "sig": h(&sig_p),
            "sig_der": h(&sig_to_der(&sig_p)),
            "sig_verifies": checks[0],
        },
        "PairAccept": {
            "fields": {
                "mac_identity_pub": h(&p.mac_key.pub65),
                "mac_presence_pub": h(&p.presence_key.pub65),
                "mac_name": p.mac_name,
                "scopes_hint": SCOPES_HINT,
            },
            "T_acc": t_acc.json(),
            "H(T_acc)": h(&sha256(&t_acc.bytes())),
            "proof": h(&proof_m),
            "sig": h(&sig_m),
            "presence_sig": h(&sig_pm),
            "sig_verifies": checks[1],
            "presence_sig_verifies": checks[2],
        },
        "PairComplete": {
            "fields": { "scopes": GRANTED, "elevation_required": true, "elevation_scopes": ELEVATION_SCOPES },
            "T_cmp": t_cmp.json(),
            "sig": h(&sig_c),
            "sig_verifies": checks[3],
        },
        "pair_id": h(&pair_id),
    });
    PairOut { json, pair_id, discovery_key: dk, prk_pair: prk, t_req }
}

// ---------------------------------------------------------------------------------------------------------
// encoding.json

pub fn encoding_json() -> Value {
    let label = "tombolo/example/v1";
    let ab_c = enc(label, &[b"ab".to_vec(), b"c".to_vec()]);
    let a_bc = enc(label, &[b"a".to_vec(), b"bc".to_vec()]);
    assert_ne!(ab_c, a_bc);

    let key = Key::fixed("qr/mac/identity-key");
    let spki = spki_der(&key.pub65);
    let spki_lib = spki_der_library(&key.pub65);
    assert_eq!(spki, spki_lib, "hand-built SPKI differs from the pkcs8 encoder");
    let sig = key.sign(b"tombolo signature encoding example");

    let unsorted = ["screen.view", "screen.control"];
    let duplicate = ["sms.read", "sms.read"];
    assert!(!is_canonical_set(&unsorted) && !is_canonical_set(&duplicate));

    let body = json!({
        "LP": [
            { "input_hex": "", "output": h(&lp(b"")) },
            { "input_utf8": "abc", "output": h(&lp(b"abc")) },
        ],
        "enc": [
            { "label": label, "fields_hex": [], "output": h(&enc(label, &[])) },
            { "label": label, "fields_hex": ["", "01", h(b"abc")], "output": h(&enc(label, &[vec![], vec![1], b"abc".to_vec()])) },
            { "note": "injectivity: moving a byte between fields changes the encoding",
              "label": label, "fields_utf8": ["ab", "c"], "output": h(&ab_c) },
            { "label": label, "fields_utf8": ["a", "bc"], "output": h(&a_bc) },
        ],
        "seq": [
            { "items_utf8": [], "output": h(&seq(&[])) },
            { "items_utf8": ["a", "bc"], "output": h(&seq_str(&["a", "bc"])) },
            { "note": "nested: seq(seq(\"x\"), \"\")", "output": h(&seq(&[seq_str(&["x"]), vec![]])) },
            { "note": "optional value absent vs present-but-empty", "absent": h(&seq(&[])), "present_empty": h(&seq(&[vec![]])) },
        ],
        "canonical_sets": {
            "all_scopes_sorted": { "items": ALL_SCOPES, "output": h(&set_str(&ALL_SCOPES)) },
            "must_reject": [
                { "items": unsorted, "reason": "not sorted byte-wise ascending" },
                { "items": duplicate, "reason": "duplicate element" },
            ],
        },
        "integers": {
            "u8(1)": h(&u8b(1)),
            "u32be(1)": h(&u32be(1)),
            "u64be(1992222)": h(&u64be(1_992_222)),
            "i32be(-1)": h(&i32be(-1)),
            "i32be(2)": h(&i32be(2)),
        },
        "p256_public_key": {
            "key": key.json(),
            "spki_prefix": crate::crypto::SPKI_PREFIX_HEX,
            "SPKI_der": h(&spki),
            "SPKI_matches_pkcs8_encoder": spki == spki_lib,
            "qr_k = H(SPKI)": h(&sha256(&spki)),
            "must_reject": [
                { "encoding": h(&[vec![0x02 | (key.pub65[64] & 1)], key.pub65[1..33].to_vec()].concat()), "reason": "SEC1 compressed form of a valid key: only 65-byte uncompressed is accepted" },
                { "encoding": format!("04{}", "00".repeat(64)), "reason": "not on the curve" },
                { "encoding": "00", "reason": "identity element" },
            ],
        },
        "ecdsa_signature": {
            "message_utf8": "tombolo signature encoding example",
            "r_s": h(&sig),
            "der": h(&sig_to_der(&sig)),
            "verifies": verify(&key.pub65, b"tombolo signature encoding example", &sig),
        },
    });
    obj(header("Canonical transcript encoding (LP, enc, seq), canonical sets, integer encodings, P-256 key and signature encodings.", "sections 5.1-5.2"), body)
}

// ---------------------------------------------------------------------------------------------------------
// ecdsa-rfc6979.json

pub fn rfc6979_crosscheck() -> (Value, bool, Vec<String>) {
    // RFC 6979 Appendix A.2.5 (NIST P-256), SHA-256 cases.
    let x = "c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721";
    let ux = "60fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb6";
    let uy = "7903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299";
    let cases = [
        (
            "sample",
            "efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716",
            "f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8",
        ),
        (
            "test",
            "f1abb023518351cd71d881567b1ea663ed3efcf6c5132b354f28d3b0b7d38367",
            "019f4113742a2b14bd25926b49c649155f267e60d3814b4c0cc84250e46f0083",
        ),
    ];
    let key = Key::from_scalar("rfc6979-a.2.5", &hex::decode(x).unwrap());
    let pub_ok = h(&key.pub65) == format!("04{ux}{uy}");
    let mut ok = pub_ok;
    let mut results = Vec::new();
    let mut matched = 0;
    for (msg, r, s) in cases {
        let sig = key.sign(msg.as_bytes());
        let m = h(&sig[..32]) == r && h(&sig[32..]) == s;
        ok &= m;
        matched += m as usize;
        results.push(json!({
            "message_utf8": msg, "rfc_r": r, "rfc_s": s,
            "computed_r_s": h(&sig), "computed_der": h(&sig_to_der(&sig)), "match": m,
            "verifies": verify(&key.pub65, msg.as_bytes(), &sig),
        }));
    }
    let lines = vec![format!(
        "RFC 6979 A.2.5 (P-256, SHA-256): public key {}, {matched}/{} signatures match",
        if pub_ok { "matches" } else { "DIFFERS" },
        cases.len()
    )];
    let body = json!({
        "source": "https://www.rfc-editor.org/rfc/rfc6979.txt (Appendix A.2.5)",
        "private_key_x": x,
        "public_key_matches": pub_ok,
        "public_sec1_uncompressed": h(&key.pub65),
        "signatures": results,
        "all_match": ok,
    });
    (
        obj(header("Cross-check of the ECDSA signing used for every other vector against RFC 6979 deterministic-nonce test vectors.", "section 5.4"), body),
        ok,
        lines,
    )
}

// ---------------------------------------------------------------------------------------------------------
// qr-pairing.json

pub fn qr_json(dev: &Devices) -> (Value, Binding) {
    let phone_key = Key::fixed("qr/phone/identity-key");
    let mac_key = Key::fixed("qr/mac/identity-key");
    let presence_key = Key::fixed("qr/mac/presence-key");
    let s = test_bytes("qr/secret", 32);
    // Stand-in for TLS-Exporter("tombolo/pair/v1", "", 32) of the pairing connection.
    let exporter_pair = test_bytes("qr/exporter-pair", 32);
    let n_p = test_bytes("qr/nonce-phone", 32);
    let n_m = test_bytes("qr/nonce-mac", 32);

    let spki = spki_der(&mac_key.pub65);
    let k = sha256(&spki);
    let exp = QR_CREATED_UNIX + TICKET_TTL_S;
    let addrs = "192.168.1.20:47100,%5Bfd00::20%5D:47100";
    let uri = format!(
        "tombolo://pair?v=1&id={}&a={}&k={}&s={}&exp={}",
        b64u(&dev.mac_eid),
        addrs,
        b64u(&k),
        b64u(&s),
        exp
    );

    let out = identity_exchange(&PairInputs {
        method: METHOD_QR,
        exporter_pair: &exporter_pair,
        method_secret: &s,
        dev,
        n_p: &n_p,
        n_m: &n_m,
        qr_k: &k,
        phone_key: &phone_key,
        mac_key: &mac_key,
        presence_key: &presence_key,
        phone_name: "Ana\u{2019}s Pixel",
        phone_model: "Pixel 9",
        phone_os: "Android 16",
        mac_name: "Studio Mac",
    });

    // Negative: a man-in-the-middle terminates TLS separately on each side, so the Mac sees a different
    // exporter. The phone's proof, recomputed with that exporter, no longer matches.
    let mitm_exporter = test_bytes("qr/exporter-pair/mitm-side", 32);
    let ikm = Tr::new("tombolo/pair/v1/ikm").f("method", u8b(METHOD_QR)).f("method_secret", &s);
    let prk_mitm = hkdf_extract(&mitm_exporter, &ikm.bytes());
    let k_pp_mitm = hkdf_expand(&prk_mitm, b"tombolo/pair/v1/key/proof-phone", 32);
    let real_proof = hmac(&hkdf_expand(&out.prk_pair, b"tombolo/pair/v1/key/proof-phone", 32), &out.t_req.bytes());
    let real_t_req_hex = out.t_req.json()["encoded"].as_str().unwrap().to_string();
    assert_eq!(real_t_req_hex.matches(&h(&exporter_pair)).count(), 1);
    let mitm_t_req_hex = real_t_req_hex.replace(&h(&exporter_pair), &h(&mitm_exporter));
    let mitm_t_req = hex::decode(&mitm_t_req_hex).unwrap();
    let expected_by_mac = hmac(&k_pp_mitm, &mitm_t_req);
    assert_ne!(real_proof, expected_by_mac);
    let sig_p = hex::decode(out.json["PairRequest"]["sig"].as_str().unwrap()).unwrap();
    let sig_on_mitm = verify(&phone_key.pub65, &mitm_t_req, &sig_p);
    assert!(!sig_on_mitm);

    // Negative: a QR whose k commits to a different key (here the presence key) must fail the phone's check.
    let wrong_k = sha256(&spki_der(&presence_key.pub65));
    assert_ne!(wrong_k, k);

    let body = json!({
        "inputs": {
            "phone_endpoint_id": h(&dev.phone_eid),
            "mac_endpoint_id": h(&dev.mac_eid),
            "phone_identity_key": phone_key.json(),
            "mac_identity_key": mac_key.json(),
            "mac_presence_key": presence_key.json(),
            "s": h(&s),
            "exporter_pair": h(&exporter_pair),
            "exporter_pair_note": "fixed stand-in for TLS-Exporter(\"tombolo/pair/v1\", \"\", 32)",
            "n_P": h(&n_p),
            "n_M": h(&n_m),
            "ticket_created_unix": QR_CREATED_UNIX,
            "ticket_ttl_s": TICKET_TTL_S,
            "addresses": ["192.168.1.20:47100", "[fd00::20]:47100"],
            "session_alpns": ALPNS,
        },
        "qr": {
            "SPKI_der(mac_identity_pub)": h(&spki),
            "k": h(&k),
            "uri": uri,
        },
        "exchange": out.json,
        "negative": {
            "mitm_exporter_mismatch": {
                "description": "The Mac's TLS session is with a relay, so its exporter differs; recomputing the phone's proof and signature check with the Mac-side exporter fails (BAD_PROOF).",
                "mac_side_exporter": h(&mitm_exporter),
                "proof_sent_by_phone": h(&real_proof),
                "proof_expected_by_mac": h(&expected_by_mac),
                "phone_sig_verifies_over_mac_side_T_req": sig_on_mitm,
            },
            "qr_k_mismatch": {
                "description": "PairAccept carries mac_identity_pub whose SPKI hash differs from k: the phone must abort with KEY_MISMATCH.",
                "k_from_qr": h(&k),
                "H(SPKI(other key))": h(&wrong_k),
            },
        },
    });
    let bind = Binding { pair_id: out.pair_id, discovery_key: out.discovery_key, phone_key, mac_key, presence_key };
    (obj(header("QR pairing flow: payload, pairing key schedule, identity exchange transcripts, proofs, signatures, pair_id and discovery key.", "sections 7.4, 7.5, 7.7"), body), bind)
}

// ---------------------------------------------------------------------------------------------------------
// code-pairing.json

fn pake_inputs(code: &str, exporter_pair: &[u8]) -> (Tr, Vec<u8>, Vec<u8>) {
    let pw = Tr::new("tombolo/pair/v1/pake/password").f("code", code).f("exporter_pair", exporter_pair);
    let wide = hkdf(&[], &pw.bytes(), b"tombolo/pair/v1/pake/w", 40);
    let w = spake2::reduce_wide(&wide);
    assert_ne!(w, vec![0u8; 32]);
    (pw, wide, w)
}

pub fn code_json(dev: &Devices) -> (Value, Vec<u8>) {
    let code = "048213";
    // Stand-in for TLS-Exporter("tombolo/pair/v1", "", 32) of this pairing connection.
    let exporter_pair = test_bytes("code/exporter-pair", 32);
    let n_p = test_bytes("code/nonce-phone", 32);
    let n_m = test_bytes("code/nonce-mac", 32);
    let x = test_bytes("code/spake2/x", 32);
    let y = test_bytes("code/spake2/y", 32);
    let phone_key = Key::fixed("code/phone/identity-key");
    let mac_key = Key::fixed("code/mac/identity-key");
    let presence_key = Key::fixed("code/mac/presence-key");

    let (pw, wide, w) = pake_inputs(code, &exporter_pair);
    let aad = Tr::new("tombolo/pair/v1/pake/aad")
        .f("n_P", &n_p)
        .f("n_M", &n_m)
        .f("phone_session_alpns", set_str(&ALPNS))
        .f("mac_session_alpns", set_str(&ALPNS));
    let (a, b) = (&dev.phone_eid, &dev.mac_eid);
    let (ws, xs, ys) = (spake2::scalar(&w), spake2::scalar(&x), spake2::scalar(&y));
    let pa = spake2::enc_point(&spake2::msg_a(&ws, &xs));
    let pb = spake2::enc_point(&spake2::msg_b(&ws, &ys));
    let va = spake2::view_a(a, b, &w, &x, &pb, &aad.bytes());
    let vb = spake2::view_b(a, b, &w, &y, &pa, &aad.bytes());
    assert_eq!(va.k, vb.k);
    assert_eq!(va.tt, vb.tt);
    assert_eq!(va.keys.ke, vb.keys.ke);
    assert_eq!(va.keys.ca, vb.keys.ca);
    assert_eq!(va.keys.cb, vb.keys.cb);
    let ke = va.keys.ke.clone();

    let out = identity_exchange(&PairInputs {
        method: METHOD_CODE,
        exporter_pair: &exporter_pair,
        method_secret: &ke,
        dev,
        n_p: &n_p,
        n_m: &n_m,
        qr_k: &[],
        phone_key: &phone_key,
        mac_key: &mac_key,
        presence_key: &presence_key,
        phone_name: "Ana\u{2019}s Pixel",
        phone_model: "Pixel 9",
        phone_os: "Android 16",
        mac_name: "Studio Mac",
    });

    // Negative: the owner mistypes the code on the phone. The Mac computes with the right code.
    let wrong = "048214";
    let (_, _, w_wrong) = pake_inputs(wrong, &exporter_pair);
    let pa_wrong = spake2::enc_point(&spake2::msg_a(&spake2::scalar(&w_wrong), &xs));
    let phone_view = spake2::view_a(a, b, &w_wrong, &x, &pb, &aad.bytes());
    let mac_view = spake2::view_b(a, b, &w, &y, &pa_wrong, &aad.bytes());
    assert_ne!(phone_view.keys.ca, mac_view.keys.ca);

    // Negative: invalid encodings of pA that the Mac must reject before computing anything.
    let mut off_curve = pa.clone();
    off_curve[64] ^= 0x01;
    let compressed = {
        let mut c = vec![0x02 | (pa[64] & 1)];
        c.extend_from_slice(&pa[1..33]);
        c
    };
    let invalid: Vec<(Vec<u8>, &str)> = vec![
        (off_curve, "last byte of pA flipped: not on the curve"),
        (compressed, "SEC1 compressed form of a valid pA: only 65-byte uncompressed is accepted"),
        (vec![0x00], "identity element"),
        ([vec![0x04], vec![0u8; 64]].concat(), "0x04 || zeros: not on the curve"),
        (pa[..64].to_vec(), "truncated to 64 bytes"),
    ];
    let invalid_json: Vec<Value> = invalid
        .iter()
        .map(|(enc, why)| {
            let rejected = spake2::decode_received(enc).is_err();
            assert!(rejected, "{why} was accepted");
            json!({ "pA": h(enc), "reason": why, "rejected_by_reference": rejected })
        })
        .collect();

    // Edge case: a w whose top byte is zero must still be encoded as 32 bytes in TT.
    let mut w_lz = vec![0u8];
    w_lz.extend(test_bytes("code/spake2/leading-zero-w", 31));
    let ws_lz = spake2::scalar(&w_lz);
    let pa_lz = spake2::enc_point(&spake2::msg_a(&ws_lz, &xs));
    let pb_lz = spake2::enc_point(&spake2::msg_b(&ws_lz, &ys));
    let va_lz = spake2::view_a(a, b, &w_lz, &x, &pb_lz, &aad.bytes());
    let vb_lz = spake2::view_b(a, b, &w_lz, &y, &pa_lz, &aad.bytes());
    assert_eq!(va_lz.keys.ca, vb_lz.keys.ca);
    assert_eq!(&va_lz.tt[va_lz.tt.len() - 40..va_lz.tt.len() - 32], &32u64.to_le_bytes());

    let body = json!({
        "inputs": {
            "phone_endpoint_id (SPAKE2 identity A)": h(a),
            "mac_endpoint_id (SPAKE2 identity B)": h(b),
            "code": code,
            "exporter_pair": h(&exporter_pair),
            "exporter_pair_note": "fixed stand-in for TLS-Exporter(\"tombolo/pair/v1\", \"\", 32)",
            "n_P": h(&n_p),
            "n_M": h(&n_m),
            "x (phone, fixed instead of random)": h(&x),
            "y (mac, fixed instead of random)": h(&y),
            "phone_identity_key": phone_key.json(),
            "mac_identity_key": mac_key.json(),
            "mac_presence_key": presence_key.json(),
            "session_alpns": ALPNS,
        },
        "spake2": {
            "M": spake2::M_HEX,
            "N": spake2::N_HEX,
            "pw": pw.json(),
            "w_wide (HKDF output, 40 bytes)": h(&wide),
            "w (mod n, 32 bytes)": h(&w),
            "AAD": aad.json(),
            "pA": h(&pa),
            "pB": h(&pb),
            "K": h(&va.k),
            "TT": h(&va.tt),
            "Hash(TT)": h(&va.keys.hash_tt),
            "Ke": h(&va.keys.ke),
            "Ka": h(&va.keys.ka),
            "KcA": h(&va.keys.kca),
            "KcB": h(&va.keys.kcb),
            "cA": h(&va.keys.ca),
            "cB": h(&va.keys.cb),
        },
        "method_secret (= Ke)": h(&ke),
        "exchange": out.json,
        "negative": {
            "wrong_code": {
                "description": "Phone typed 048214, Mac shows 048213: the Mac's expected cA differs from the phone's, so the Mac replies BAD_CONFIRMATION and charges one attempt.",
                "phone_code": wrong,
                "phone_w": h(&w_wrong),
                "phone_pA": h(&pa_wrong),
                "mac_pB": h(&pb),
                "phone_K": h(&phone_view.k),
                "mac_K": h(&mac_view.k),
                "phone_cA": h(&phone_view.keys.ca),
                "mac_expected_cA": h(&mac_view.keys.ca),
            },
            "invalid_pA_encodings": invalid_json,
        },
        "edge_cases": {
            "leading_zero_w": {
                "description": "Raw SPAKE2 run (no HKDF) with a w whose first byte is 0x00: TT must encode w as 32 bytes (len(w) = 32).",
                "w": h(&w_lz),
                "pA": h(&pa_lz),
                "pB": h(&pb_lz),
                "K": h(&va_lz.k),
                "TT": h(&va_lz.tt),
                "Ke": h(&va_lz.keys.ke),
                "cA": h(&va_lz.keys.ca),
                "cB": h(&va_lz.keys.cb),
            },
        },
    });
    (
        obj(header("Code (SPAKE2, RFC 9382 P-256) pairing flow with fixed scalars, followed by the identity exchange; wrong-code and invalid-point negatives; leading-zero w edge case.", "sections 7.4, 7.6, 7.7"), body),
        out.discovery_key,
    )
}

// ---------------------------------------------------------------------------------------------------------
// session.json

fn t_auth(role: u8, exporter: &[u8], dialer: &[u8], listener: &[u8], nd: &[u8], nl: &[u8], pair_id: &[u8]) -> Tr {
    Tr::new("tombolo/session/v1/auth")
        .f("signer_role", u8b(role))
        .f("alpn", "tombolo/1")
        .f("exporter_session", exporter)
        .f("dialer_endpoint_id", dialer)
        .f("listener_endpoint_id", listener)
        .f("n_dialer", nd)
        .f("n_listener", nl)
        .f("pair_id", pair_id)
}

struct SessionCase {
    name: &'static str,
    exporter: Vec<u8>,
    dialer: Vec<u8>,
    listener: Vec<u8>,
    nd: Vec<u8>,
    nl: Vec<u8>,
}

pub fn session_json(dev: &Devices, b: &Binding) -> Value {
    let cases = [
        SessionCase {
            name: "mac_dials_phone",
            exporter: test_bytes("session/mac_dials_phone/exporter", 32),
            dialer: dev.mac_eid.clone(),
            listener: dev.phone_eid.clone(),
            nd: test_bytes("session/mac_dials_phone/n_dialer", 32),
            nl: test_bytes("session/mac_dials_phone/n_listener", 32),
        },
        SessionCase {
            name: "phone_dials_mac",
            exporter: test_bytes("session/phone_dials_mac/exporter", 32),
            dialer: dev.phone_eid.clone(),
            listener: dev.mac_eid.clone(),
            nd: test_bytes("session/phone_dials_mac/n_dialer", 32),
            nl: test_bytes("session/phone_dials_mac/n_listener", 32),
        },
    ];

    let mut case_json = Vec::new();
    let mut sigs = Vec::new();
    for c in &cases {
        let tp = t_auth(ROLE_PHONE, &c.exporter, &c.dialer, &c.listener, &c.nd, &c.nl, &b.pair_id);
        let tm = t_auth(ROLE_MAC, &c.exporter, &c.dialer, &c.listener, &c.nd, &c.nl, &b.pair_id);
        let sp = b.phone_key.sign(&tp.bytes());
        let sm = b.mac_key.sign(&tm.bytes());
        assert!(verify(&b.phone_key.pub65, &tp.bytes(), &sp) && verify(&b.mac_key.pub65, &tm.bytes(), &sm));
        let salt = Tr::new("tombolo/session/v1/salt").f("n_dialer", &c.nd).f("n_listener", &c.nl);
        let prk = hkdf_extract(&salt.bytes(), &c.exporter);
        let sid = hkdf_expand(&prk, b"tombolo/session/v1/key/session-id", 16);
        let kb = hkdf_expand(&prk, b"tombolo/session/v1/key/channel-bind", 32);
        case_json.push(json!({
            "name": c.name,
            "inputs": {
                "exporter_session": h(&c.exporter),
                "exporter_session_note": "fixed stand-in for TLS-Exporter(\"tombolo/session/v1\", \"\", 32)",
                "dialer_endpoint_id": h(&c.dialer),
                "listener_endpoint_id": h(&c.listener),
                "n_dialer": h(&c.nd),
                "n_listener": h(&c.nl),
                "pair_id": h(&b.pair_id),
            },
            "phone_SessionAuth": { "T_auth": tp.json(), "sig": h(&sp), "verifies_with_phone_identity_pub": true },
            "mac_SessionAuth": { "T_auth": tm.json(), "sig": h(&sm), "verifies_with_mac_identity_pub": true },
            "key_schedule": {
                "salt_s": salt.json(),
                "PRK_s": h(&prk),
                "session_id": h(&sid),
                "K_bind": h(&kb),
            },
        }));
        sigs.push((tp, tm, sp, sm, prk, sid, kb));
    }

    let (tp1, tm1, sp1, sm1, _prk1, sid1, kb1) = &sigs[0];
    let (_tp2, tm2, ..) = &sigs[1];
    let c1 = &cases[0];

    // Negatives.
    let reflected = t_auth(ROLE_PHONE, &c1.exporter, &c1.dialer, &c1.listener, &c1.nd, &c1.nl, &b.pair_id);
    let neg_reflect = verify(&b.mac_key.pub65, &reflected.bytes(), sm1);
    let neg_replay = verify(&b.mac_key.pub65, &tm2.bytes(), sm1);
    let neg_wrong_key = verify(&b.mac_key.pub65, &tp1.bytes(), sp1);
    let neg_presence = verify(&b.presence_key.pub65, &tm1.bytes(), sm1);
    assert!(!neg_reflect && !neg_replay && !neg_wrong_key && !neg_presence);

    // Channel binding of an extra TLS/TCP connection (case 1).
    let exporter_channel = test_bytes("session/mac_dials_phone/exporter-channel-1", 32);
    let t_bind = Tr::new("tombolo/session/v1/channel-bind")
        .f("sender_role", u8b(ROLE_MAC))
        .f("session_id", sid1)
        .f("exporter_channel", &exporter_channel)
        .f("channel_index", u32be(1));
    let bind_mac = hmac(kb1, &t_bind.bytes());

    // Elevation (case 1).
    let n_e = test_bytes("session/mac_dials_phone/n_E", 32);
    let elev = |nonce: &[u8]| {
        Tr::new("tombolo/session/v1/elevate")
            .f("exporter_session", &c1.exporter)
            .f("dialer_endpoint_id", &c1.dialer)
            .f("listener_endpoint_id", &c1.listener)
            .f("n_dialer", &c1.nd)
            .f("n_listener", &c1.nl)
            .f("pair_id", &b.pair_id)
            .f("n_E", nonce)
            .f("scopes", set_str(&ELEVATION_SCOPES))
    };
    let t_elev = elev(&n_e);
    let sig_elev = b.presence_key.sign(&t_elev.bytes());
    assert!(verify(&b.presence_key.pub65, &t_elev.bytes(), &sig_elev));
    let n_e2 = test_bytes("session/mac_dials_phone/n_E/second", 32);
    let replay_elev = verify(&b.presence_key.pub65, &elev(&n_e2).bytes(), &sig_elev);
    let elev_by_identity = verify(&b.mac_key.pub65, &t_elev.bytes(), &sig_elev);
    assert!(!replay_elev && !elev_by_identity);

    // Key rotation (case 1): Mac identity key, then Mac presence key.
    let rot = |kind: u8, rid: &[u8], old: &[u8], new: &[u8]| {
        Tr::new("tombolo/session/v1/rotate-key")
            .f("signer_role", u8b(ROLE_MAC))
            .f("kind", u8b(kind))
            .f("rotation_id", rid)
            .f("exporter_session", &c1.exporter)
            .f("dialer_endpoint_id", &c1.dialer)
            .f("listener_endpoint_id", &c1.listener)
            .f("n_dialer", &c1.nd)
            .f("n_listener", &c1.nl)
            .f("pair_id", &b.pair_id)
            .f("old_pub", old)
            .f("new_pub", new)
    };
    let new_id = Key::fixed("session/rotate/mac-identity-new");
    let rid1 = test_bytes("session/rotate/rotation-id-identity", 16);
    let t_rot1 = rot(1, &rid1, &b.mac_key.pub65, &new_id.pub65);
    let (auth1, new1) = (b.mac_key.sign(&t_rot1.bytes()), new_id.sign(&t_rot1.bytes()));
    let new_pres = Key::fixed("session/rotate/mac-presence-new");
    let rid2 = test_bytes("session/rotate/rotation-id-presence", 16);
    let t_rot2 = rot(2, &rid2, &b.presence_key.pub65, &new_pres.pub65);
    let (auth2, new2) = (b.mac_key.sign(&t_rot2.bytes()), new_pres.sign(&t_rot2.bytes()));
    assert!(verify(&b.mac_key.pub65, &t_rot1.bytes(), &auth1) && verify(&new_id.pub65, &t_rot1.bytes(), &new1));
    assert!(verify(&b.mac_key.pub65, &t_rot2.bytes(), &auth2) && verify(&new_pres.pub65, &t_rot2.bytes(), &new2));

    let body = json!({
        "binding": {
            "source": "qr-pairing.json",
            "pair_id": h(&b.pair_id),
            "phone_identity_pub": h(&b.phone_key.pub65),
            "mac_identity_pub": h(&b.mac_key.pub65),
            "mac_presence_pub": h(&b.presence_key.pub65),
        },
        "cases": case_json,
        "negative": {
            "reflection": { "description": "mac_dials_phone: the Mac's signature checked against T_auth with signer_role = PHONE", "verifies": neg_reflect },
            "cross_connection_replay": { "description": "the Mac's mac_dials_phone signature checked against the phone_dials_mac T_auth(MAC)", "verifies": neg_replay },
            "wrong_key": { "description": "the phone's signature checked with the Mac identity key", "verifies": neg_wrong_key },
            "presence_key_is_not_identity_key": { "description": "the Mac's SessionAuth signature checked with the presence key", "verifies": neg_presence },
        },
        "channel_bind": {
            "session": "mac_dials_phone",
            "exporter_channel": h(&exporter_channel),
            "exporter_channel_note": "fixed stand-in for TLS-Exporter(\"tombolo/channel/v1\", \"\", 32) on the extra connection",
            "T_bind": t_bind.json(),
            "mac": h(&bind_mac),
        },
        "elevation": {
            "session": "mac_dials_phone",
            "n_E": h(&n_e),
            "T_elev": t_elev.json(),
            "sig (presence key)": h(&sig_elev),
            "negative": {
                "replay_with_new_challenge_verifies": replay_elev,
                "verifies_with_identity_key": elev_by_identity,
            },
        },
        "rotation": {
            "session": "mac_dials_phone",
            "identity": {
                "rotation_id": h(&rid1),
                "new_key": new_id.json(),
                "T_rot": t_rot1.json(),
                "sig_auth (old identity key)": h(&auth1),
                "sig_new (new identity key)": h(&new1),
            },
            "presence": {
                "rotation_id": h(&rid2),
                "new_key": new_pres.json(),
                "T_rot": t_rot2.json(),
                "sig_auth (identity key)": h(&auth2),
                "sig_new (new presence key)": h(&new2),
                "note": "the phone commits only after the phone owner approves",
            },
        },
    });
    obj(header("Session authentication (exporter-bound SessionAuth in both dial directions), session key schedule, channel binding, elevation and key rotation, with negative cases.", "sections 8.2, 8.3, 9.3, 13.2"), body)
}

// ---------------------------------------------------------------------------------------------------------
// discovery.json

fn token(dk: &[u8], epoch: u64) -> Vec<u8> {
    hmac(dk, &Tr::new("tombolo/discovery/v1/token").f("epoch", u64be(epoch)).bytes())[..8].to_vec()
}

fn filler(fk: &[u8], epoch: u64, i: u8) -> Vec<u8> {
    hmac(fk, &Tr::new("tombolo/discovery/v1/filler").f("epoch", u64be(epoch)).f("slot", u8b(i)).bytes())[..8]
        .to_vec()
}

fn txt(tokens: Vec<Vec<u8>>, fk: &[u8], epoch: u64) -> (Vec<Value>, String) {
    let slots_n = if tokens.len() > 4 { 8 } else { 4 };
    let mut slots = tokens.clone();
    let mut i = 0u8;
    while slots.len() < slots_n {
        slots.push(filler(fk, epoch, i));
        i += 1;
    }
    slots.sort();
    let detail = slots
        .iter()
        .map(|s| json!({ "slot": h(s), "kind": if tokens.contains(s) { "token" } else { "filler" } }))
        .collect();
    (detail, b64u(&slots.concat()))
}

pub fn discovery_json(dk_qr: &[u8], dk_code: &[u8]) -> Value {
    let fk = test_bytes("discovery/filler-key", 32);
    let times = [1_793_000_000u64, 1_793_000_699, 1_793_000_700];
    let epochs: Vec<Value> = times
        .iter()
        .map(|t| json!({ "unix_seconds": t, "epoch": t / 900, "token_qr_binding": h(&token(dk_qr, t / 900)) }))
        .collect();
    let e = times[0] / 900;
    let (one_detail, one_txt) = txt(vec![token(dk_qr, e)], &fk, e);
    let (two_detail, two_txt) = txt(vec![token(dk_qr, e), token(dk_code, e)], &fk, e);
    let window: Vec<Value> =
        [e - 1, e, e + 1].iter().map(|x| json!({ "epoch": x, "token": h(&token(dk_qr, *x)) })).collect();
    let body = json!({
        "inputs": {
            "discovery_key_qr_binding": h(dk_qr),
            "discovery_key_code_binding": h(dk_code),
            "discovery_key_source": "qr-pairing.json and code-pairing.json, exchange.key_schedule.discovery_key",
            "filler_key": h(&fk),
            "epoch_seconds": 900,
        },
        "token_transcript_example": Tr::new("tombolo/discovery/v1/token").f("epoch", u64be(e)).json(),
        "filler_transcript_example": Tr::new("tombolo/discovery/v1/filler").f("epoch", u64be(e)).f("slot", u8b(0)).json(),
        "epochs": epochs,
        "txt_one_binding": { "epoch": e, "slots_sorted": one_detail, "t": one_txt },
        "txt_two_bindings": { "epoch": e, "slots_sorted": two_detail, "t": two_txt },
        "mac_acceptance_window_qr_binding": window,
    });
    obj(header("Rotating DNS-SD discovery token: epochs, per-binding tokens, filler slots and the TXT t= value.", "section 12"), body)
}

// ---------------------------------------------------------------------------------------------------------
// op-payload.json

/// UUIDv7 (RFC 9562): 48-bit Unix ms, version 7, variant 10, remaining bits from fixed bytes.
fn uuid_v7(ms: u64, name: &str) -> Vec<u8> {
    let mut u = test_bytes(name, 16);
    u[..6].copy_from_slice(&ms.to_be_bytes()[2..]);
    u[6] = 0x70 | (u[6] & 0x0f);
    u[8] = 0x80 | (u[8] & 0x3f);
    u
}

fn uuid_str(u: &[u8]) -> String {
    let x = h(u);
    format!("{}-{}-{}-{}-{}", &x[..8], &x[8..12], &x[12..16], &x[16..20], &x[20..])
}

fn op_vec(kind: &str, op_id: &[u8], fields: Vec<(&str, Vec<u8>)>, readable: Value) -> Value {
    let mut tr = Tr::new(&format!("tombolo/op/v1/{kind}")).f("op_id", op_id);
    for (n, v) in fields {
        tr = tr.f(n, v);
    }
    json!({
        "kind": kind,
        "op_id": uuid_str(op_id),
        "payload": readable,
        "transcript": tr.json(),
        "op_hash": h(&sha256(&tr.bytes())),
    })
}

pub fn op_json() -> Value {
    let ms = QR_CREATED_UNIX * 1000;
    let day = 86_400_000u64;
    let id = |n: &str| uuid_v7(ms, n);
    let blake_a = test_bytes("op/file-offer/blake3-photo", 32);
    let blake_b = test_bytes("op/file-offer/blake3-notes", 32);
    let transfer_id = test_bytes("op/file-offer/transfer-id", 16);
    let item = |name: &str, size: u64, mime: &str, b3: &[u8]| {
        seq(&[name.as_bytes().to_vec(), u64be(size), mime.as_bytes().to_vec(), b3.to_vec()])
    };
    let ops = vec![
        op_vec(
            "send-sms",
            &id("op/send-sms"),
            vec![
                ("subscription_id", i32be(2)),
                ("addresses", seq_str(&["+15551230001", "+15551230002"])),
                ("text", "Running 5 min late \u{1F642}".as_bytes().to_vec()),
            ],
            json!({ "subscription_id": 2, "address": ["+15551230001", "+15551230002"], "text": "Running 5 min late \u{1F642}" }),
        ),
        op_vec(
            "call-action",
            &id("op/call-action"),
            vec![("call_id", b"call-7".to_vec()), ("action", u8b(3))],
            json!({ "call_id": "call-7", "action": "END (3)" }),
        ),
        op_vec("dial", &id("op/dial"), vec![("number", b"+15551230003".to_vec())], json!({ "number": "+15551230003" })),
        op_vec(
            "notification-action",
            &id("op/notification-action/reply"),
            vec![
                ("key", b"0|com.example.chat|42|null|10123".to_vec()),
                ("action_id", b"reply".to_vec()),
                ("reply_text", seq_str(&["On my way"])),
            ],
            json!({ "key": "0|com.example.chat|42|null|10123", "action_id": "reply", "reply_text": "On my way" }),
        ),
        op_vec(
            "notification-action",
            &id("op/notification-action/no-reply"),
            vec![
                ("key", b"0|com.example.chat|42|null|10123".to_vec()),
                ("action_id", b"mark_read".to_vec()),
                ("reply_text", seq(&[])),
            ],
            json!({ "key": "0|com.example.chat|42|null|10123", "action_id": "mark_read", "reply_text": null }),
        ),
        op_vec(
            "notification-action",
            &id("op/notification-action/empty-reply"),
            vec![
                ("key", b"0|com.example.chat|42|null|10123".to_vec()),
                ("action_id", b"reply".to_vec()),
                ("reply_text", seq(&[vec![]])),
            ],
            json!({ "key": "0|com.example.chat|42|null|10123", "action_id": "reply", "reply_text": "" }),
        ),
        op_vec(
            "file-offer",
            &id("op/file-offer"),
            vec![
                ("transfer_id", transfer_id.clone()),
                (
                    "items",
                    seq(&[
                        item("photo.jpg", 2_345_678, "image/jpeg", &blake_a),
                        item("notes.txt", 512, "text/plain", &blake_b),
                    ]),
                ),
            ],
            json!({
                "transfer_id": uuid_str(&transfer_id),
                "items": [
                    { "name": "photo.jpg", "size": 2_345_678u64, "mime": "image/jpeg", "blake3": h(&blake_a) },
                    { "name": "notes.txt", "size": 512, "mime": "text/plain", "blake3": h(&blake_b) },
                ],
            }),
        ),
    ];
    let accept = |now: u64| now <= ms + 6 * day && now + day >= ms;
    let window: Vec<Value> = [
        (ms + 5 * day, "5 days old"),
        (ms + 6 * day, "exactly 6 days old"),
        (ms + 6 * day + 1, "6 days + 1 ms old"),
        (ms - day, "1 day in the future"),
        (ms - day - 1, "1 day + 1 ms in the future"),
    ]
    .iter()
    .map(|(now, what)| json!({ "op_id_time_ms": ms, "phone_now_ms": now, "case": what, "execute": accept(*now) }))
    .collect();
    let body = json!({
        "op_id_format": "UUIDv7 (RFC 9562): first 48 bits = Unix time in ms",
        "op_id_time_ms": ms,
        "ops": ops,
        "acceptance_window": window,
    });
    obj(header("Side-effect payload hashes (op_hash) for every op kind, UUIDv7 op_id layout and the acceptance window.", "section 11"), body)
}
