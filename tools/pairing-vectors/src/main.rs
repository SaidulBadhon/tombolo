// SPDX-License-Identifier: GPL-3.0-or-later
//! Deterministic test-vector generator for docs/security/pairing-and-session.md.
//!
//! ```text
//! pairing-vectors              regenerate proto/testdata/pairing/*.json
//! pairing-vectors --check      regenerate in memory and diff against the committed files (exit 1 on mismatch)
//! pairing-vectors --out DIR    write (or with --check, compare) DIR instead
//! ```
//!
//! Every run first cross-checks the primitives against published vectors (RFC 9382 Appendix A/B, RFC 6979
//! A.2.5) and exits 2 if any value differs.

mod crypto;
mod enc;
mod spake2;
mod vectors;

use serde_json::Value;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const DEFAULT_OUT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../proto/testdata/pairing");

/// Self-tests plus every output file, in a fixed order. Returns (files, self-tests ok, summary lines).
pub fn build() -> (Vec<(String, String)>, bool, Vec<String>) {
    let (spake_report, spake_ok, mut lines) = spake2::rfc9382_crosscheck();
    let (ecdsa_report, ecdsa_ok, l2) = vectors::rfc6979_crosscheck();
    lines.extend(l2);

    let dev = vectors::devices();
    let (qr, binding) = vectors::qr_json(&dev);
    let (code, dk_code) = vectors::code_json(&dev);
    let session = vectors::session_json(&dev, &binding);
    let discovery = vectors::discovery_json(&binding.discovery_key, &dk_code);

    let mut spake_file = serde_json::Map::new();
    spake_file.insert("generator".into(), Value::from("tools/pairing-vectors (cargo run --release)"));
    if let Value::Object(m) = spake_report {
        spake_file.extend(m);
    }

    let files: Vec<(&str, Value)> = vec![
        ("encoding.json", vectors::encoding_json()),
        ("spake2-rfc9382.json", Value::Object(spake_file)),
        ("ecdsa-rfc6979.json", ecdsa_report),
        ("qr-pairing.json", qr),
        ("code-pairing.json", code),
        ("session.json", session),
        ("discovery.json", discovery),
        ("op-payload.json", vectors::op_json()),
    ];
    let rendered = files
        .into_iter()
        .map(|(n, v)| (n.to_string(), serde_json::to_string_pretty(&v).expect("serialises") + "\n"))
        .collect();
    (rendered, spake_ok && ecdsa_ok, lines)
}

fn first_difference(a: &str, b: &str) -> String {
    for (i, (la, lb)) in a.lines().zip(b.lines()).enumerate() {
        if la != lb {
            let cut = |s: &str| s.trim().chars().take(160).collect::<String>();
            return format!("line {}:\n    committed: {}\n    generated: {}", i + 1, cut(la), cut(lb));
        }
    }
    format!("line counts differ ({} committed vs {} generated)", a.lines().count(), b.lines().count())
}

fn check(out: &Path, files: &[(String, String)]) -> bool {
    let mut ok = true;
    for (name, content) in files {
        let path = out.join(name);
        match std::fs::read_to_string(&path) {
            Ok(committed) if committed == *content => println!("ok        {name}"),
            Ok(committed) => {
                ok = false;
                println!("MISMATCH  {name}: {}", first_difference(&committed, content));
            }
            Err(e) => {
                ok = false;
                println!("MISSING   {name}: {e}");
            }
        }
    }
    let expected: BTreeSet<&str> = files.iter().map(|(n, _)| n.as_str()).collect();
    if let Ok(dir) = std::fs::read_dir(out) {
        for entry in dir.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.ends_with(".json") && !expected.contains(name.as_str()) {
                ok = false;
                println!("STALE     {name}: not produced by the generator");
            }
        }
    }
    ok
}

fn main() -> ExitCode {
    let mut check_mode = false;
    let mut out = PathBuf::from(DEFAULT_OUT);
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--check" => check_mode = true,
            "--out" => match args.next() {
                Some(d) => out = PathBuf::from(d),
                None => {
                    eprintln!("--out needs a directory");
                    return ExitCode::from(64);
                }
            },
            "-h" | "--help" => {
                println!("usage: pairing-vectors [--check] [--out DIR]\n  default DIR: {DEFAULT_OUT}");
                return ExitCode::SUCCESS;
            }
            other => {
                eprintln!("unknown argument {other:?} (try --help)");
                return ExitCode::from(64);
            }
        }
    }

    let (files, selftest_ok, lines) = build();
    for l in &lines {
        println!("self-test {l}");
    }
    if !selftest_ok {
        eprintln!("self-test FAILED: the primitives do not reproduce the published vectors; nothing written");
        return ExitCode::from(2);
    }

    if check_mode {
        if check(&out, &files) {
            println!("check passed: {} files in {} match the generator", files.len(), out.display());
            ExitCode::SUCCESS
        } else {
            println!("check FAILED: regenerate with `cargo run --release` and review the diff");
            ExitCode::from(1)
        }
    } else {
        if let Err(e) = std::fs::create_dir_all(&out) {
            eprintln!("cannot create {}: {e}", out.display());
            return ExitCode::from(1);
        }
        for (name, content) in &files {
            if let Err(e) = std::fs::write(out.join(name), content) {
                eprintln!("cannot write {name}: {e}");
                return ExitCode::from(1);
            }
        }
        println!("wrote {} files to {}", files.len(), out.display());
        ExitCode::SUCCESS
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rfc9382_vectors_reproduce() {
        let (_, ok, lines) = spake2::rfc9382_crosscheck();
        assert!(ok, "{lines:?}");
    }

    #[test]
    fn rfc6979_vectors_reproduce() {
        let (_, ok, lines) = vectors::rfc6979_crosscheck();
        assert!(ok, "{lines:?}");
    }

    #[test]
    fn generation_is_deterministic() {
        assert_eq!(build().0, build().0);
    }

    #[test]
    fn committed_vectors_are_current() {
        let (files, ok, _) = build();
        assert!(ok);
        assert!(check(Path::new(DEFAULT_OUT), &files), "committed vectors are stale; run `cargo run --release`");
    }

    #[test]
    fn encoding_is_injective_on_field_boundaries() {
        assert_ne!(enc::enc("l", &[b"ab".to_vec(), b"c".to_vec()]), enc::enc("l", &[b"a".to_vec(), b"bc".to_vec()]));
        assert_ne!(enc::enc("l", &[vec![]]), enc::enc("l", &[]));
        assert_ne!(enc::seq(&[]), enc::seq(&[vec![]]));
    }

    #[test]
    fn strict_point_decoding() {
        assert!(spake2::decode_received(&hex::decode(spake2::M_HEX).unwrap()).is_err()); // compressed
        assert!(spake2::decode_received(&[0u8]).is_err());
        let mut p = spake2::enc_point(&spake2::m());
        assert!(spake2::decode_received(&p).is_ok());
        p[64] ^= 1;
        assert!(spake2::decode_received(&p).is_err());
    }
}
