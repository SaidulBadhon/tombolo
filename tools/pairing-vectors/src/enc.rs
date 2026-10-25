// SPDX-License-Identifier: GPL-3.0-or-later
//! Canonical transcript encoding, spec §5.2:
//!
//! ```text
//! LP(x)                 = u32be(len(x)) ‖ x
//! enc(label; f1..fn)    = LP(label) ‖ u32be(n) ‖ LP(f1) ‖ … ‖ LP(fn)
//! seq(x1..xk)           = u32be(k) ‖ LP(x1) ‖ … ‖ LP(xk)
//! ```

use serde_json::{json, Value};

pub const MAX_TRANSCRIPT: usize = 64 * 1024;

pub const ROLE_PHONE: u8 = 0x01;
pub const ROLE_MAC: u8 = 0x02;
pub const METHOD_QR: u8 = 0x01;
pub const METHOD_CODE: u8 = 0x02;

pub fn lp(x: &[u8]) -> Vec<u8> {
    let len = u32::try_from(x.len()).expect("field longer than u32");
    let mut v = len.to_be_bytes().to_vec();
    v.extend_from_slice(x);
    v
}

pub fn enc(label: &str, fields: &[Vec<u8>]) -> Vec<u8> {
    let mut out = lp(label.as_bytes());
    out.extend_from_slice(&(fields.len() as u32).to_be_bytes());
    for f in fields {
        out.extend(lp(f));
    }
    assert!(out.len() <= MAX_TRANSCRIPT, "transcript exceeds 64 KiB");
    out
}

pub fn seq(items: &[Vec<u8>]) -> Vec<u8> {
    let mut out = (items.len() as u32).to_be_bytes().to_vec();
    for i in items {
        out.extend(lp(i));
    }
    out
}

pub fn seq_str(items: &[&str]) -> Vec<u8> {
    let v: Vec<Vec<u8>> = items.iter().map(|s| s.as_bytes().to_vec()).collect();
    seq(&v)
}

/// A set is canonical when sorted byte-wise ascending without duplicates (spec §5.2).
pub fn is_canonical_set(items: &[&str]) -> bool {
    items.windows(2).all(|w| w[0].as_bytes() < w[1].as_bytes())
}

/// `seq()` of a set; panics if the set is not canonical (the generator only emits canonical sets).
pub fn set_str(items: &[&str]) -> Vec<u8> {
    assert!(is_canonical_set(items), "non-canonical set {items:?}");
    seq_str(items)
}

pub fn u8b(v: u8) -> Vec<u8> {
    vec![v]
}
pub fn u32be(v: u32) -> Vec<u8> {
    v.to_be_bytes().to_vec()
}
pub fn u64be(v: u64) -> Vec<u8> {
    v.to_be_bytes().to_vec()
}
pub fn i32be(v: i32) -> Vec<u8> {
    v.to_be_bytes().to_vec()
}

/// A transcript with named fields, so the JSON shows every field next to the encoding.
#[derive(Clone)]
pub struct Tr {
    label: String,
    fields: Vec<(String, Vec<u8>)>,
}

impl Tr {
    pub fn new(label: &str) -> Self {
        Tr { label: label.to_string(), fields: Vec::new() }
    }
    pub fn f(mut self, name: &str, v: impl AsRef<[u8]>) -> Self {
        self.fields.push((name.to_string(), v.as_ref().to_vec()));
        self
    }
    pub fn bytes(&self) -> Vec<u8> {
        let f: Vec<Vec<u8>> = self.fields.iter().map(|(_, v)| v.clone()).collect();
        enc(&self.label, &f)
    }
    pub fn json(&self) -> Value {
        let fields: Vec<Value> = self
            .fields
            .iter()
            .map(|(n, v)| json!({ "name": n, "hex": hex::encode(v) }))
            .collect();
        json!({ "label": self.label, "fields": fields, "encoded": hex::encode(self.bytes()) })
    }
}
