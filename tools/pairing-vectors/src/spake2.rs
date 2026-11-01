// SPDX-License-Identifier: GPL-3.0-or-later
//! SPAKE2 per RFC 9382, ciphersuite SPAKE2-P256-SHA256-HKDF-HMAC, implemented directly on `p256`.
//!
//! RustCrypto's `spake2` crate (0.4.0, 0.5.0-pre.0) implements only Ed25519 with a python-spake2 style
//! transcript, so it cannot produce RFC 9382 P-256 values. This module is cross-checked against all four
//! RFC 9382 Appendix B vectors, and M/N are regenerated with the RFC's Appendix A procedure.

use crate::crypto::{hkdf, hmac, sha256};
use num_bigint::BigUint;
use p256::elliptic_curve::sec1::{FromEncodedPoint, ToEncodedPoint};
use p256::elliptic_curve::PrimeField;
use p256::{AffinePoint, EncodedPoint, ProjectivePoint, Scalar};
use serde_json::{json, Value};

/// RFC 9382 §6, P-256 M and N (SEC1 compressed).
pub const M_HEX: &str = "02886e2f97ace46e55ba9dd7242579f2993b64e16ef3dcab95afd497333d8fa12f";
pub const N_HEX: &str = "03d8bbd6c639c62937b04d997f38c3770719c629d7014d49a24b4f98baa1292b49";
/// Order of the P-256 group.
pub const ORDER_HEX: &str = "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551";

pub fn decode_any(bytes: &[u8]) -> Option<ProjectivePoint> {
    let ep = EncodedPoint::from_bytes(bytes).ok()?;
    let ap: Option<AffinePoint> = AffinePoint::from_encoded_point(&ep).into();
    ap.map(ProjectivePoint::from)
}

/// Strict decoding for received SPAKE2 messages (spec §7.6): exactly 65 bytes, 0x04 prefix, on the curve,
/// not the identity.
pub fn decode_received(bytes: &[u8]) -> Result<ProjectivePoint, &'static str> {
    if bytes.len() != 65 || bytes[0] != 0x04 {
        return Err("not a 65-byte SEC1 uncompressed point");
    }
    let p = decode_any(bytes).ok_or("not on the curve")?;
    if p == ProjectivePoint::IDENTITY {
        return Err("identity element");
    }
    Ok(p)
}

pub fn m() -> ProjectivePoint {
    decode_any(&hex::decode(M_HEX).unwrap()).unwrap()
}
pub fn n() -> ProjectivePoint {
    decode_any(&hex::decode(N_HEX).unwrap()).unwrap()
}

pub fn enc_point(p: &ProjectivePoint) -> Vec<u8> {
    p.to_affine().to_encoded_point(false).as_bytes().to_vec()
}

pub fn scalar(bytes: &[u8]) -> Scalar {
    let arr: [u8; 32] = bytes.try_into().expect("32-byte scalar");
    Option::from(Scalar::from_repr(arr.into())).expect("scalar < n")
}

/// w = OS2IP(wide) mod n, returned as a 32-byte big-endian scalar (spec §7.6).
pub fn reduce_wide(wide: &[u8]) -> Vec<u8> {
    let order = BigUint::from_bytes_be(&hex::decode(ORDER_HEX).unwrap());
    let r = BigUint::from_bytes_be(wide) % order;
    let b = r.to_bytes_be();
    let mut out = vec![0u8; 32 - b.len()];
    out.extend(b);
    out
}

fn len8(x: &[u8]) -> [u8; 8] {
    (x.len() as u64).to_le_bytes()
}

/// RFC 9382 §3.3 transcript TT (8-byte little-endian lengths; w as a 32-byte big-endian number).
pub fn transcript(a: &[u8], b: &[u8], pa: &[u8], pb: &[u8], k: &[u8], w: &[u8]) -> Vec<u8> {
    let mut tt = Vec::new();
    for part in [a, b, pa, pb, k, w] {
        tt.extend_from_slice(&len8(part));
        tt.extend_from_slice(part);
    }
    tt
}

pub struct Keys {
    pub hash_tt: Vec<u8>,
    pub ke: Vec<u8>,
    pub ka: Vec<u8>,
    pub kca: Vec<u8>,
    pub kcb: Vec<u8>,
    pub ca: Vec<u8>,
    pub cb: Vec<u8>,
}

/// RFC 9382 §4: Ke ‖ Ka = Hash(TT); KcA ‖ KcB = KDF(Ka, nil, "ConfirmationKeys" ‖ AAD); cX = MAC(KcX, TT).
pub fn key_schedule(tt: &[u8], aad: &[u8]) -> Keys {
    let hash_tt = sha256(tt);
    let (ke, ka) = (hash_tt[..16].to_vec(), hash_tt[16..].to_vec());
    let mut info = b"ConfirmationKeys".to_vec();
    info.extend_from_slice(aad);
    let kc = hkdf(&[], &ka, &info, 32);
    let (kca, kcb) = (kc[..16].to_vec(), kc[16..].to_vec());
    let ca = hmac(&kca, tt);
    let cb = hmac(&kcb, tt);
    Keys { hash_tt, ke, ka, kca, kcb, ca, cb }
}

/// pA = w·M + x·P
pub fn msg_a(w: &Scalar, x: &Scalar) -> ProjectivePoint {
    m() * w + ProjectivePoint::GENERATOR * x
}
/// pB = w·N + y·P
pub fn msg_b(w: &Scalar, y: &Scalar) -> ProjectivePoint {
    n() * w + ProjectivePoint::GENERATOR * y
}
/// A: K = h·x·(pB − w·N), h = 1 for P-256.
pub fn shared_a(w: &Scalar, x: &Scalar, pb: &ProjectivePoint) -> ProjectivePoint {
    (*pb - n() * w) * x
}
/// B: K = h·y·(pA − w·M)
pub fn shared_b(w: &Scalar, y: &Scalar, pa: &ProjectivePoint) -> ProjectivePoint {
    (*pa - m() * w) * y
}

/// One party's complete view of a run.
pub struct View {
    pub tt: Vec<u8>,
    pub k: Vec<u8>,
    pub keys: Keys,
}

pub fn view_a(a: &[u8], b: &[u8], w: &[u8], x: &[u8], pb_bytes: &[u8], aad: &[u8]) -> View {
    let (ws, xs) = (scalar(w), scalar(x));
    let pa = enc_point(&msg_a(&ws, &xs));
    let pb = decode_received(pb_bytes).expect("valid pB");
    let k = shared_a(&ws, &xs, &pb);
    assert!(k != ProjectivePoint::IDENTITY);
    let k = enc_point(&k);
    let tt = transcript(a, b, &pa, pb_bytes, &k, w);
    let keys = key_schedule(&tt, aad);
    View { tt, k, keys }
}

pub fn view_b(a: &[u8], b: &[u8], w: &[u8], y: &[u8], pa_bytes: &[u8], aad: &[u8]) -> View {
    let (ws, ys) = (scalar(w), scalar(y));
    let pb = enc_point(&msg_b(&ws, &ys));
    let pa = decode_received(pa_bytes).expect("valid pA");
    let k = shared_b(&ws, &ys, &pa);
    assert!(k != ProjectivePoint::IDENTITY);
    let k = enc_point(&k);
    let tt = transcript(a, b, pa_bytes, &pb, &k, w);
    let keys = key_schedule(&tt, aad);
    View { tt, k, keys }
}

// ---------------------------------------------------------------------------------------------------------
// RFC 9382 Appendix A: regenerate M and N.

fn iterated_hash(seed: &[u8], n: usize) -> Vec<u8> {
    let mut h = seed.to_vec();
    for _ in 0..n {
        h = sha256(&h);
    }
    h
}

fn bighash(seed: &[u8], start: usize, sz: usize) -> Vec<u8> {
    let n = sz.div_ceil(32);
    let mut out = Vec::new();
    for i in start..start + n {
        out.extend(iterated_hash(seed, i));
    }
    out.truncate(sz);
    out
}

/// Returns (compressed point, iteration) following the RFC's `gen_point` for a Weierstrass curve.
pub fn gen_point(seed: &str) -> (Vec<u8>, usize) {
    for i in 1..1000 {
        let mut s = bighash(seed.as_bytes(), i, 33);
        s[0] = (s[0] & 1) | 2;
        if let Some(p) = decode_any(&s) {
            if p != ProjectivePoint::IDENTITY {
                return (s, i);
            }
        }
    }
    panic!("no point found");
}

// ---------------------------------------------------------------------------------------------------------
// RFC 9382 Appendix B vectors (copied from https://www.rfc-editor.org/rfc/rfc9382.txt, line breaks removed).

pub struct RfcVector {
    pub a: &'static str,
    pub b: &'static str,
    pub w: &'static str,
    pub x: &'static str,
    pub pa: &'static str,
    pub y: &'static str,
    pub pb: &'static str,
    pub k: &'static str,
    pub tt: &'static str,
    pub hash_tt: &'static str,
    pub ke: &'static str,
    pub ka: &'static str,
    pub kca: &'static str,
    pub kcb: &'static str,
    pub ca: &'static str,
    pub cb: &'static str,
}

pub const RFC_VECTORS: [RfcVector; 4] = [
    RfcVector {
        a: "server",
        b: "client",
        w: "2ee57912099d31560b3a44b1184b9b4866e904c49d12ac5042c97dca461b1a5f",
        x: "43dd0fd7215bdcb482879fca3220c6a968e66d70b1356cac18bb26c84a78d729",
        pa: "04a56fa807caaa53a4d28dbb9853b9815c61a411118a6fe516a8798434751470f9010153ac33d0d5f2047ffdb1a3e42c9b4e6be662766e1eeb4116988ede5f912c",
        y: "dcb60106f276b02606d8ef0a328c02e4b629f84f89786af5befb0bc75b6e66be",
        pb: "0406557e482bd03097ad0cbaa5df82115460d951e3451962f1eaf4367a420676d09857ccbc522686c83d1852abfa8ed6e4a1155cf8f1543ceca528afb591a1e0b7",
        k: "0412af7e89717850671913e6b469ace67bd90a4df8ce45c2af19010175e37eed69f75897996d539356e2fa6a406d528501f907e04d97515fbe83db277b715d3325",
        tt: "06000000000000007365727665720600000000000000636c69656e74410000000000000004a56fa807caaa53a4d28dbb9853b9815c61a411118a6fe516a8798434751470f9010153ac33d0d5f2047ffdb1a3e42c9b4e6be662766e1eeb4116988ede5f912c41000000000000000406557e482bd03097ad0cbaa5df82115460d951e3451962f1eaf4367a420676d09857ccbc522686c83d1852abfa8ed6e4a1155cf8f1543ceca528afb591a1e0b741000000000000000412af7e89717850671913e6b469ace67bd90a4df8ce45c2af19010175e37eed69f75897996d539356e2fa6a406d528501f907e04d97515fbe83db277b715d332520000000000000002ee57912099d31560b3a44b1184b9b4866e904c49d12ac5042c97dca461b1a5f",
        hash_tt: "0e0672dc86f8e45565d338b0540abe6915bdf72e2b35b5c9e5663168e960a91b",
        ke: "0e0672dc86f8e45565d338b0540abe69",
        ka: "15bdf72e2b35b5c9e5663168e960a91b",
        kca: "00c12546835755c86d8c0db7851ae86f",
        kcb: "a9fa3406c3b781b93d804485430ca27a",
        ca: "58ad4aa88e0b60d5061eb6b5dd93e80d9c4f00d127c65b3b35b1b5281fee38f0",
        cb: "d3e2e547f1ae04f2dbdbf0fc4b79f8ecff2dff314b5d32fe9fcef2fb26dc459b",
    },
    RfcVector {
        a: "",
        b: "client",
        w: "0548d8729f730589e579b0475a582c1608138ddf7054b73b5381c7e883e2efae",
        x: "403abbe3b1b4b9ba17e3032849759d723939a27a27b9d921c500edde18ed654b",
        pa: "04a897b769e681c62ac1c2357319a3d363f610839c4477720d24cbe32f5fd85f44fb92ba966578c1b712be6962498834078262caa5b441ecfa9d4a9485720e918a",
        y: "903023b6598908936ea7c929bd761af6039577a9c3f9581064187c3049d87065",
        pb: "04e0f816fd1c35e22065d5556215c097e799390d16661c386e0ecc84593974a61b881a8c82327687d0501862970c64565560cb5671f696048050ca66ca5f8cc7fc",
        k: "048f83ec9f6e4f87cc6f9dc740bdc2769725f923364f01c84148c049a39a735ebda82eac03e00112fd6a5710682767cff5361f7e819e53d8d3c3a2922e0d837aa6",
        tt: "00000000000000000600000000000000636c69656e74410000000000000004a897b769e681c62ac1c2357319a3d363f610839c4477720d24cbe32f5fd85f44fb92ba966578c1b712be6962498834078262caa5b441ecfa9d4a9485720e918a410000000000000004e0f816fd1c35e22065d5556215c097e799390d16661c386e0ecc84593974a61b881a8c82327687d0501862970c64565560cb5671f696048050ca66ca5f8cc7fc4100000000000000048f83ec9f6e4f87cc6f9dc740bdc2769725f923364f01c84148c049a39a735ebda82eac03e00112fd6a5710682767cff5361f7e819e53d8d3c3a2922e0d837aa620000000000000000548d8729f730589e579b0475a582c1608138ddf7054b73b5381c7e883e2efae",
        hash_tt: "642f05c473c2cd79909f9a841e2f30a70bf89b18180af97353ba198789c2b963",
        ke: "642f05c473c2cd79909f9a841e2f30a7",
        ka: "0bf89b18180af97353ba198789c2b963",
        kca: "c6be376fc7cd1301fd0a13adf3e7bffd",
        kcb: "b7243f4ae60440a49b3f8cab3c1fba07",
        ca: "47d29e6666af1b7dd450d571233085d7a9866e4d49d2645e2df975489521232b",
        cb: "3313c5cefc361d27fb16847a91c2a73b766ffa90a4839122a9b70a2f6bd1d6df",
    },
    RfcVector {
        a: "server",
        b: "",
        w: "626e0cdc7b14c9db3e52a0b1b3a768c98e37852d5db30febe0497b14eae8c254",
        x: "07adb3db6bc623d3399726bfdbfd3d15a58ea776ab8a308b00392621291f9633",
        pa: "04f88fb71c99bfffaea370966b7eb99cd4be0ff1a7d335caac4211c4afd855e2e15a873b298503ad8ba1d9cbb9a392d2ba309b48bfd7879aefd0f2cea6009763b0",
        y: "b6a4fc8dbb629d4ba51d6f91ed1532cf87adec98f25dd153a75accafafedec16",
        pb: "040c269d6be017dccb15182ac6bfcd9e2a14de019dd587eaf4bdfd353f031101e7cca177f8eb362a6e83e7d5e729c0732e1b528879c086f39ba0f31a9661bd34db",
        k: "0445ee233b8ecb51ebd6e7da3f307e88a1616bae2166121221fdc0dadb986afaf3ec8a988dc9c626fa3b99f58a7ca7c9b844bb3e8dd9554aafc5b53813504c1cbe",
        tt: "06000000000000007365727665720000000000000000410000000000000004f88fb71c99bfffaea370966b7eb99cd4be0ff1a7d335caac4211c4afd855e2e15a873b298503ad8ba1d9cbb9a392d2ba309b48bfd7879aefd0f2cea6009763b04100000000000000040c269d6be017dccb15182ac6bfcd9e2a14de019dd587eaf4bdfd353f031101e7cca177f8eb362a6e83e7d5e729c0732e1b528879c086f39ba0f31a9661bd34db41000000000000000445ee233b8ecb51ebd6e7da3f307e88a1616bae2166121221fdc0dadb986afaf3ec8a988dc9c626fa3b99f58a7ca7c9b844bb3e8dd9554aafc5b53813504c1cbe2000000000000000626e0cdc7b14c9db3e52a0b1b3a768c98e37852d5db30febe0497b14eae8c254",
        hash_tt: "005184ff460da2ce59062c87733c299c3521297d736598fc0a1127600efa1afb",
        ke: "005184ff460da2ce59062c87733c299c",
        ka: "3521297d736598fc0a1127600efa1afb",
        kca: "f3da53604f0aeecea5a33be7bddf6edf",
        kcb: "9e3f86848736f159bd92b6e107ec6799",
        ca: "bc9f9bbe99f26d0b2260e6456e05a86196a3307ec6663a18bf6ac825736533b2",
        cb: "c2370e1bf813b086dff0d834e74425a06e6390f48f5411900276dcccc5a297ec",
    },
    RfcVector {
        a: "",
        b: "",
        w: "7bf46c454b4c1b25799527d896508afd5fc62ef4ec59db1efb49113063d70cca",
        x: "8cef65df64bb2d0f83540c53632de911b5b24b3eab6cc74a97609fd659e95473",
        pa: "04a65b367a3f613cf9f0654b1b28a1e3a8a40387956c8ba6063e8658563890f46ca1ef6a676598889fc28de2950ab8120b79a5ef1ea4c9f44bc98f585634b46d66",
        y: "d7a66f64074a84652d8d623a92e20c9675c61cb5b4f6a0063e4648a2fdc02d53",
        pb: "04589f13218822710d98d8b2123a079041052d9941b9cf88c6617ddb2fcc0494662eea8ba6b64692dc318250030c6af045cb738bc81ba35b043c3dcb46adf6f58d",
        k: "041a3c03d51b452537ca2a1fea6110353c6d5ed483c4f0f86f4492ca3f378d40a994b4477f93c64d928edbbcd3e85a7c709b7ea73ee97986ce3d1438e135543772",
        tt: "00000000000000000000000000000000410000000000000004a65b367a3f613cf9f0654b1b28a1e3a8a40387956c8ba6063e8658563890f46ca1ef6a676598889fc28de2950ab8120b79a5ef1ea4c9f44bc98f585634b46d66410000000000000004589f13218822710d98d8b2123a079041052d9941b9cf88c6617ddb2fcc0494662eea8ba6b64692dc318250030c6af045cb738bc81ba35b043c3dcb46adf6f58d4100000000000000041a3c03d51b452537ca2a1fea6110353c6d5ed483c4f0f86f4492ca3f378d40a994b4477f93c64d928edbbcd3e85a7c709b7ea73ee97986ce3d1438e13554377220000000000000007bf46c454b4c1b25799527d896508afd5fc62ef4ec59db1efb49113063d70cca",
        hash_tt: "fc6374762ba5cf11f4b2caa08b2cd1b9907ae0e26e8d6234318d91583cd74c86",
        ke: "fc6374762ba5cf11f4b2caa08b2cd1b9",
        ka: "907ae0e26e8d6234318d91583cd74c86",
        kca: "5dbd2f477166b7fb6d61febbd77a5563",
        kcb: "7689b4654407a5faeffdc8f18359d8a3",
        ca: "dfb4db8d48ae5a675963ea5e6c19d98d4ea028d8e898dad96ea19a80ade95dca",
        cb: "d0f0609d1613138d354f7e95f19fb556bf52d751947241e8c7118df5ef0ae175",
    },
];

/// Runs every RFC 9382 check. Returns (JSON report, all_ok, human summary lines).
pub fn rfc9382_crosscheck() -> (Value, bool, Vec<String>) {
    let mut all_ok = true;
    let mut lines = Vec::new();
    let mut results = Vec::new();

    for (i, v) in RFC_VECTORS.iter().enumerate() {
        let (a, b) = (v.a.as_bytes(), v.b.as_bytes());
        let w = hex::decode(v.w).unwrap();
        let x = hex::decode(v.x).unwrap();
        let y = hex::decode(v.y).unwrap();
        let (ws, xs, ys) = (scalar(&w), scalar(&x), scalar(&y));
        let pa = enc_point(&msg_a(&ws, &xs));
        let pb = enc_point(&msg_b(&ws, &ys));
        let va = view_a(a, b, &w, &x, &pb, &[]);
        let vb = view_b(a, b, &w, &y, &pa, &[]);

        let checks: Vec<(&str, Vec<u8>, &str)> = vec![
            ("pA", pa.clone(), v.pa),
            ("pB", pb.clone(), v.pb),
            ("K (computed by A)", va.k.clone(), v.k),
            ("K (computed by B)", vb.k.clone(), v.k),
            ("TT", va.tt.clone(), v.tt),
            ("Hash(TT)", va.keys.hash_tt.clone(), v.hash_tt),
            ("Ke", va.keys.ke.clone(), v.ke),
            ("Ka", va.keys.ka.clone(), v.ka),
            ("KcA", va.keys.kca.clone(), v.kca),
            ("KcB", va.keys.kcb.clone(), v.kcb),
            ("cA (A conf)", va.keys.ca.clone(), v.ca),
            ("cB (B conf)", vb.keys.cb.clone(), v.cb),
        ];
        let mut fields = serde_json::Map::new();
        let mut ok_count = 0;
        for (name, got, want) in &checks {
            let ok = hex::encode(got) == *want;
            if ok {
                ok_count += 1;
            } else {
                all_ok = false;
            }
            fields.insert(name.to_string(), json!({ "rfc": want, "computed": hex::encode(got), "match": ok }));
        }
        lines.push(format!(
            "RFC 9382 Appendix B vector {} (A={:?}, B={:?}): {}/{} values match",
            i + 1,
            v.a,
            v.b,
            ok_count,
            checks.len()
        ));
        results.push(json!({
            "vector": i + 1,
            "A": v.a, "B": v.b, "w": v.w, "x": v.x, "y": v.y, "AAD": "",
            "checks": Value::Object(fields),
        }));
    }

    let (m_gen, m_iter) = gen_point("1.2.840.10045.3.1.7 point generation seed (M)");
    let (n_gen, n_iter) = gen_point("1.2.840.10045.3.1.7 point generation seed (N)");
    let m_ok = hex::encode(&m_gen) == M_HEX;
    let n_ok = hex::encode(&n_gen) == N_HEX;
    all_ok &= m_ok && n_ok;
    lines.push(format!(
        "RFC 9382 Appendix A: M regenerated {} (iteration {m_iter}), N regenerated {} (iteration {n_iter})",
        if m_ok { "and matches" } else { "but DIFFERS" },
        if n_ok { "and matches" } else { "but DIFFERS" }
    ));

    let report = json!({
        "description": "Cross-check of this generator's SPAKE2 implementation against RFC 9382 (SPAKE2-P256-SHA256-HKDF-HMAC). Every value must have match = true.",
        "source": "https://www.rfc-editor.org/rfc/rfc9382.txt (Appendix A and Appendix B)",
        "spec": "docs/security/pairing-and-session.md section 7.6",
        "point_generation": {
            "M": { "seed": "1.2.840.10045.3.1.7 point generation seed (M)", "rfc": M_HEX, "regenerated": hex::encode(&m_gen), "iteration": m_iter, "match": m_ok },
            "N": { "seed": "1.2.840.10045.3.1.7 point generation seed (N)", "rfc": N_HEX, "regenerated": hex::encode(&n_gen), "iteration": n_iter, "match": n_ok },
        },
        "appendix_b": results,
        "all_match": all_ok,
    });
    (report, all_ok, lines)
}
