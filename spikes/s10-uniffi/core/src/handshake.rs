// SPDX-License-Identifier: GPL-3.0-or-later
//! Hardware-key signing callback: Rust calls a foreign `Signer` (Swift: Secure Enclave via CryptoKit;
//! Kotlin: Android Keystore — deferred) during a fake session handshake and verifies the P-256 ECDSA
//! signature with the RustCrypto `p256` crate.

use std::sync::Arc;
use std::time::Duration;

use p256::ecdsa::signature::Verifier;
use p256::ecdsa::{Signature, VerifyingKey};
use sha2::{Digest, Sha256};

use crate::CoreError;
use crate::cancel::{CancelToken, spawn, with_cancel};
use crate::util::{Guard, ThreadInfo, now_ns, record, thread_info};

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum SignerError {
    #[error("user cancelled")]
    UserCancelled,
    #[error("signing failed: {reason}")]
    Failed { reason: String },
}

impl From<uniffi::UnexpectedUniFFICallbackError> for SignerError {
    fn from(e: uniffi::UnexpectedUniFFICallbackError) -> Self {
        SignerError::Failed { reason: format!("unexpected foreign error: {}", e.reason) }
    }
}

/// Implemented by the platform. `sign` is async because a hardware key may wait for Touch ID /
/// BiometricPrompt for seconds; a sync callback would block a runtime worker for that long.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait Signer: Send + Sync {
    /// SEC1 uncompressed P-256 public key (65 bytes, `04 || X || Y`).
    fn public_key(&self) -> Vec<u8>;
    /// ECDSA P-256 / SHA-256 over `message`; DER or raw (r||s, 64 bytes) encoding.
    async fn sign(&self, message: Vec<u8>) -> Result<Vec<u8>, SignerError>;
}

#[derive(uniffi::Record, Debug)]
pub struct HandshakeReport {
    pub verified: bool,
    pub signature_format: String,
    pub transcript_len: u32,
    pub signature_len: u32,
    /// SHA-256 of the SEC1 public key, hex.
    pub public_key_fingerprint: String,
    pub sign_us: u64,
    pub total_us: u64,
    /// Thread that first polled the exported future (= the Swift caller's thread).
    pub export_poll_thread: ThreadInfo,
    /// Runtime worker that invoked `Signer.sign`.
    pub signer_call_thread: ThreadInfo,
    /// Thread that resumed the handshake after the foreign future completed.
    pub after_sign_thread: ThreadInfo,
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn parse_signature(sig: &[u8]) -> Result<(String, Signature), CoreError> {
    let r = if sig.len() == 64 {
        Signature::from_slice(sig).map(|s| ("raw".to_string(), s))
    } else {
        Signature::from_der(sig).map(|s| ("der".to_string(), s))
    };
    r.map_err(|e| CoreError::Verify { reason: format!("malformed signature: {e}") })
}

/// Standalone verification helper (used by the harness for negative tests).
#[uniffi::export]
pub fn verify_p256(public_key: Vec<u8>, message: Vec<u8>, signature: Vec<u8>) -> bool {
    let Ok(vk) = VerifyingKey::from_sec1_bytes(&public_key) else { return false };
    let Ok((_, sig)) = parse_signature(&signature) else { return false };
    vk.verify(&message, &sig).is_ok()
}

/// Fake session handshake: build a transcript, have the platform sign it with its hardware key,
/// verify the signature. `sign_timeout_ms` (0 = none) drops the foreign future on expiry;
/// `token` lets Swift cancel the whole handshake.
#[uniffi::export]
pub async fn handshake(
    signer: Arc<dyn Signer>,
    token: Option<Arc<CancelToken>>,
    sign_timeout_ms: u64,
    probe: u64,
) -> Result<HandshakeReport, CoreError> {
    let t0 = now_ns();
    let export_poll_thread = thread_info();
    let mut outer = Guard::new(probe, "handshake_export_future");
    let work = spawn(handshake_task(signer, sign_timeout_ms, probe));
    let r = with_cancel(token.as_deref(), async move { work.await.map_err(CoreError::internal)? }).await;
    if matches!(r, Err(CoreError::Cancelled)) {
        record(probe, "rust_observed_token_cancel");
    }
    outer.done();
    let (mut report, _) = r?;
    report.export_poll_thread = export_poll_thread;
    report.total_us = (now_ns() - t0) / 1000;
    Ok(report)
}

async fn handshake_task(
    signer: Arc<dyn Signer>,
    sign_timeout_ms: u64,
    probe: u64,
) -> Result<(HandshakeReport, ()), CoreError> {
    let signer_call_thread = thread_info();
    let pk = signer.public_key();
    let vk = VerifyingKey::from_sec1_bytes(&pk)
        .map_err(|e| CoreError::Verify { reason: format!("bad public key: {e}") })?;
    let fp = Sha256::digest(&pk);

    let mut nonce = [0u8; 32];
    getrandom::fill(&mut nonce).map_err(CoreError::internal)?;
    let mut transcript = b"tombolo/s10/handshake/v0\0".to_vec();
    transcript.extend_from_slice(&nonce);
    transcript.extend_from_slice(&fp);
    transcript.extend_from_slice(&now_ns().to_be_bytes());

    let ts = now_ns();
    let mut g = Guard::new(probe, "foreign_sign_future");
    let fut = signer.sign(transcript.clone());
    let sig = if sign_timeout_ms > 0 {
        match tokio::time::timeout(Duration::from_millis(sign_timeout_ms), fut).await {
            Ok(r) => r,
            Err(_) => {
                record(probe, "rust_sign_timeout_dropped_foreign_future");
                return Err(CoreError::TimedOut { ms: sign_timeout_ms });
            }
        }
    } else {
        fut.await
    };
    let sig = sig.map_err(|e| CoreError::Signer { reason: e.to_string() })?;
    g.done();
    let sign_us = (now_ns() - ts) / 1000;
    let after_sign_thread = thread_info();

    let (format, signature) = parse_signature(&sig)?;
    vk.verify(&transcript, &signature)
        .map_err(|e| CoreError::Verify { reason: format!("ECDSA verification failed: {e}") })?;

    Ok((
        HandshakeReport {
            verified: true,
            signature_format: format,
            transcript_len: transcript.len() as u32,
            signature_len: sig.len() as u32,
            public_key_fingerprint: hex(&fp),
            sign_us,
            total_us: 0,
            export_poll_thread: signer_call_thread.clone(),
            signer_call_thread,
            after_sign_thread,
        },
        (),
    ))
}
