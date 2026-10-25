// SPDX-License-Identifier: GPL-3.0-or-later
//! Primitive wrappers (spec §5.4) and deterministic fixed inputs.

use base64::Engine;
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use p256::ecdsa::signature::{Signer, Verifier};
use p256::ecdsa::{Signature, SigningKey, VerifyingKey};
use p256::elliptic_curve::sec1::ToEncodedPoint;
use p256::pkcs8::EncodePublicKey;
use p256::{FieldBytes, PublicKey};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

/// Fixed test input: `block_i = SHA-256("tombolo-test-vector:" ‖ name ‖ ":" ‖ u32be(i))`, concatenated and
/// truncated to `len`. Nothing-up-my-sleeve stand-ins for random values; every JSON file also records the
/// resulting bytes, so other implementations never need to reproduce this function.
pub fn test_bytes(name: &str, len: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(len + 32);
    let mut i: u32 = 0;
    while out.len() < len {
        let mut h = Sha256::new();
        h.update(b"tombolo-test-vector:");
        h.update(name.as_bytes());
        h.update(b":");
        h.update(i.to_be_bytes());
        out.extend_from_slice(&h.finalize());
        i += 1;
    }
    out.truncate(len);
    out
}

pub fn sha256(x: &[u8]) -> Vec<u8> {
    Sha256::digest(x).to_vec()
}

pub fn hmac(key: &[u8], msg: &[u8]) -> Vec<u8> {
    let mut m = Hmac::<Sha256>::new_from_slice(key).expect("HMAC accepts any key length");
    m.update(msg);
    m.finalize().into_bytes().to_vec()
}

/// HKDF-Extract. An empty salt is equivalent to 32 zero bytes (RFC 5869; HMAC zero-pads the key).
pub fn hkdf_extract(salt: &[u8], ikm: &[u8]) -> Vec<u8> {
    let (prk, _) = Hkdf::<Sha256>::extract(Some(salt), ikm);
    prk.to_vec()
}

pub fn hkdf_expand(prk: &[u8], info: &[u8], len: usize) -> Vec<u8> {
    let hk = Hkdf::<Sha256>::from_prk(prk).expect("PRK is 32 bytes");
    let mut okm = vec![0u8; len];
    hk.expand(info, &mut okm).expect("length within HKDF limit");
    okm
}

pub fn hkdf(salt: &[u8], ikm: &[u8], info: &[u8], len: usize) -> Vec<u8> {
    hkdf_expand(&hkdf_extract(salt, ikm), info, len)
}

pub fn b64u(x: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(x)
}

/// A P-256 key pair derived from a fixed scalar.
pub struct Key {
    pub name: String,
    pub scalar: Vec<u8>,
    pub sk: SigningKey,
    pub pub65: Vec<u8>,
}

impl Key {
    /// Private scalar = `test_bytes(name, 32)` (asserted to be in [1, n-1]).
    pub fn fixed(name: &str) -> Key {
        Key::from_scalar(name, &test_bytes(name, 32))
    }
    pub fn from_scalar(name: &str, scalar: &[u8]) -> Key {
        let sk = SigningKey::from_bytes(FieldBytes::from_slice(scalar)).expect("scalar in [1, n-1]");
        let pub65 = sk.verifying_key().to_encoded_point(false).as_bytes().to_vec();
        assert_eq!(pub65.len(), 65);
        Key { name: name.to_string(), scalar: scalar.to_vec(), sk, pub65 }
    }
    /// ECDSA P-256 / SHA-256, RFC 6979 deterministic nonce; returns r ‖ s (64 bytes).
    pub fn sign(&self, msg: &[u8]) -> Vec<u8> {
        let sig: Signature = self.sk.sign(msg);
        sig.to_bytes().to_vec()
    }
    pub fn json(&self) -> Value {
        json!({
            "fixed_input_name": self.name,
            "private_scalar": hex::encode(&self.scalar),
            "public_sec1_uncompressed": hex::encode(&self.pub65),
        })
    }
}

/// Verify a 64-byte r ‖ s signature against a 65-byte SEC1 public key.
pub fn verify(pub65: &[u8], msg: &[u8], sig64: &[u8]) -> bool {
    let Ok(vk) = VerifyingKey::from_sec1_bytes(pub65) else { return false };
    let Ok(sig) = Signature::from_slice(sig64) else { return false };
    vk.verify(msg, &sig).is_ok()
}

/// DER form of a 64-byte r ‖ s signature (what the Secure Enclave and Android Keystore return).
pub fn sig_to_der(sig64: &[u8]) -> Vec<u8> {
    Signature::from_slice(sig64).expect("valid signature").to_der().as_bytes().to_vec()
}

/// The fixed SubjectPublicKeyInfo prefix for P-256 (RFC 5480), spec §5.1.
pub const SPKI_PREFIX_HEX: &str = "3059301306072a8648ce3d020106082a8648ce3d030107034200";

/// SPKI(Q) built by hand from the fixed prefix.
pub fn spki_der(pub65: &[u8]) -> Vec<u8> {
    let mut v = hex::decode(SPKI_PREFIX_HEX).unwrap();
    v.extend_from_slice(pub65);
    v
}

/// SPKI(Q) from the `pkcs8` encoder, used to cross-check the hand-built form.
pub fn spki_der_library(pub65: &[u8]) -> Vec<u8> {
    PublicKey::from_sec1_bytes(pub65)
        .expect("valid point")
        .to_public_key_der()
        .expect("encodes")
        .as_bytes()
        .to_vec()
}
