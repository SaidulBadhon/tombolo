// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import LocalAuthentication
import S10Core

/// Thread observations recorded from inside Swift callbacks.
let threadLog = Locked<[String: String]>([:])

enum SignatureFormat: String, Codable { case der, raw }

/// `Signer` backed by a non-persistent Secure Enclave P-256 key (CryptoKit).
///
/// Signing is a *blocking* call (with `.userPresence` it blocks until the user answers the Touch ID
/// sheet), so it runs on a private serial queue, never on Swift's cooperative pool; Swift task
/// cancellation invalidates the `LAContext`, which dismisses a pending prompt.
final class SecureEnclaveSigner: Signer, @unchecked Sendable {
    let key: SecureEnclave.P256.Signing.PrivateKey
    let format: SignatureFormat
    let context: LAContext?
    private let queue = DispatchQueue(label: "s10.secure-enclave.sign", qos: .userInitiated)

    init(format: SignatureFormat, accessControl: SecAccessControl? = nil, context: LAContext? = nil) throws {
        if let accessControl {
            key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl, authenticationContext: context)
        } else {
            key = try SecureEnclave.P256.Signing.PrivateKey()
        }
        self.format = format
        self.context = context
    }

    func publicKey() -> Data { key.publicKey.x963Representation }

    func sign(message: Data) async throws -> Data {
        threadLog.with { $0["swift_sign_entry"] = swiftThread() }
        let box = Unchecked(value: (key, context))
        let format = self.format
        let queue = self.queue
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                queue.async {
                    threadLog.with { $0["swift_sign_worker"] = swiftThread() }
                    do {
                        let sig = try box.value.0.signature(for: message)
                        cont.resume(returning: format == .der ? sig.derRepresentation : sig.rawRepresentation)
                    } catch let e as LAError where [.userCancel, .appCancel, .systemCancel].contains(e.code) {
                        cont.resume(throwing: SignerError.UserCancelled)
                    } catch {
                        cont.resume(throwing: SignerError.Failed(reason: String(describing: error)))
                    }
                }
            }
        } onCancel: {
            box.value.1?.invalidate()
        }
    }
}

/// Signs a *different* message than the one asked for: Rust must reject the signature.
final class TamperingSigner: Signer, @unchecked Sendable {
    let inner: Signer
    init(_ inner: Signer) { self.inner = inner }
    func publicKey() -> Data { inner.publicKey() }
    func sign(message: Data) async throws -> Data {
        var m = message
        m[m.startIndex] ^= 0x01
        return try await inner.sign(message: m)
    }
}

/// Simulates a user who never answers the prompt; records when Swift observes cancellation.
final class SlowSigner: Signer, @unchecked Sendable {
    let key = P256.Signing.PrivateKey()
    let delayMs: UInt64
    let startedNs = Locked<UInt64>(0)
    let cancelledNs = Locked<UInt64>(0)
    let cancelThread = Locked<String>("")
    init(delayMs: UInt64) { self.delayMs = delayMs }
    func publicKey() -> Data { key.publicKey.x963Representation }
    func sign(message: Data) async throws -> Data {
        startedNs.with { $0 = nowNs() }
        do {
            try await Task.sleep(nanoseconds: delayMs * 1_000_000)
        } catch {
            cancelledNs.with { $0 = nowNs() }
            cancelThread.with { $0 = swiftThread() }
            throw SignerError.UserCancelled
        }
        return try key.signature(for: message).derRepresentation
    }
}

func userPresenceAccessControl() -> SecAccessControl? {
    var err: Unmanaged<CFError>?
    let ac = SecAccessControlCreateWithFlags(kCFAllocatorDefault, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                             [.privateKeyUsage, .userPresence], &err)
    if let err { print("SecAccessControlCreateWithFlags error: \(err.takeRetainedValue())") }
    return ac
}

struct HandshakeRun: Codable {
    var name: String
    var ok: Bool
    var detail: String
    var signUs: UInt64?
    var totalUs: UInt64?
    var signatureFormat: String?
    var signatureLen: UInt32?
    var fingerprint: String?
}

struct SignResults: Codable {
    var secureEnclaveAvailable: Bool
    var runs: [HandshakeRun]
    var signUsPercentiles: Percentiles?
    var threads: [String: String]
    var verifyHelper: [String: Bool]
}

func runHandshake(_ name: String, _ signer: Signer, expectSuccess: Bool, probe: UInt64) async -> HandshakeRun {
    do {
        let r = try await handshake(signer: signer, token: nil, signTimeoutMs: 0, probe: probe)
        _ = takeProbeEvents(probe: probe)
        return HandshakeRun(name: name, ok: expectSuccess && r.verified,
                            detail: "verified=\(r.verified) by Rust p256", signUs: r.signUs, totalUs: r.totalUs,
                            signatureFormat: r.signatureFormat, signatureLen: r.signatureLen,
                            fingerprint: r.publicKeyFingerprint)
    } catch {
        _ = takeProbeEvents(probe: probe)
        return HandshakeRun(name: name, ok: !expectSuccess, detail: "threw \(error)")
    }
}

func runSignTests(json: String?) async -> Bool {
    print("== S10 sign: Secure Enclave signer called from Rust, verified with p256 ==")
    print("SecureEnclave.isAvailable = \(SecureEnclave.isAvailable)")
    var runs: [HandshakeRun] = []
    var signSamples: [UInt64] = []
    var threads: [String: String] = [:]
    var verify: [String: Bool] = [:]
    guard SecureEnclave.isAvailable else {
        writeJSON(SignResults(secureEnclaveAvailable: false, runs: [], signUsPercentiles: nil, threads: [:], verifyHelper: [:]), to: json)
        return false
    }
    do {
        let der = try SecureEnclaveSigner(format: .der)
        let raw = try SecureEnclaveSigner(format: .raw)
        print("SE public key (SEC1, \(der.publicKey().count) bytes): \(der.publicKey().prefix(8).map { String(format: "%02x", $0) }.joined())…")

        // First handshake: also capture the thread map.
        let r = try await handshake(signer: der, token: nil, signTimeoutMs: 0, probe: 1)
        _ = takeProbeEvents(probe: 1)
        threads["rust_export_future_first_poll"] = r.exportPollThread.text
        threads["rust_runtime_task_calls_signer"] = r.signerCallThread.text
        threads["rust_after_foreign_future_completed"] = r.afterSignThread.text
        threads["swift_sign_method_entry"] = threadLog.value["swift_sign_entry"] ?? "?"
        threads["swift_secure_enclave_worker"] = threadLog.value["swift_sign_worker"] ?? "?"
        runs.append(HandshakeRun(name: "SE key, DER signature (first)", ok: r.verified, detail: "verified=\(r.verified)",
                                 signUs: r.signUs, totalUs: r.totalUs, signatureFormat: r.signatureFormat,
                                 signatureLen: r.signatureLen, fingerprint: r.publicKeyFingerprint))

        for i in 0..<50 {
            let rr = try await handshake(signer: i % 2 == 0 ? der : raw, token: nil, signTimeoutMs: 0, probe: 2)
            _ = takeProbeEvents(probe: 2)
            if !rr.verified { runs.append(HandshakeRun(name: "repeat \(i)", ok: false, detail: "not verified")) }
            signSamples.append(rr.signUs * 1000)
        }
        runs.append(HandshakeRun(name: "50 repeated handshakes (25 DER + 25 raw)", ok: runs.allSatisfy { $0.ok },
                                 detail: "all verified"))
        runs.append(await runHandshake("SE key, raw r||s signature", raw, expectSuccess: true, probe: 3))
        runs.append(await runHandshake("NEGATIVE: tampered message (must be rejected)", TamperingSigner(der),
                                       expectSuccess: false, probe: 4))

        // Direct verification helper: positive and bit-flip negative.
        let msg = Data("tombolo s10 verify helper".utf8)
        let sig = try der.key.signature(for: msg).derRepresentation
        verify["valid_signature"] = verifyP256(publicKey: der.publicKey(), message: msg, signature: sig)
        var bad = sig
        bad[bad.count - 1] ^= 0x01
        verify["bit_flipped_signature"] = verifyP256(publicKey: der.publicKey(), message: msg, signature: bad)
        verify["other_key"] = verifyP256(publicKey: raw.publicKey(), message: msg, signature: sig)
    } catch {
        runs.append(HandshakeRun(name: "setup", ok: false, detail: "threw \(error)"))
    }
    let pct = signSamples.isEmpty ? nil : percentilesUs(signSamples)
    for r in runs { print("  [\(r.ok ? "PASS" : "FAIL")] \(r.name): \(r.detail)\(r.signUs.map { " sign=\($0)µs" } ?? "")\(r.signatureFormat.map { " fmt=\($0)" } ?? "")") }
    if let pct { print("  SE sign latency over 50 handshakes (Rust-measured, incl. FFI round trip): p50=\(f1(pct.p50))µs p95=\(f1(pct.p95))µs max=\(f1(pct.max))µs") }
    print("  verify_p256 helper: \(verify)")
    print("  threads:"); for (k, v) in threads.sorted(by: { $0.key < $1.key }) { print("    \(k): \(v)") }
    let ok = runs.allSatisfy { $0.ok } && verify["valid_signature"] == true && verify["bit_flipped_signature"] == false && verify["other_key"] == false
    writeJSON(SignResults(secureEnclaveAvailable: true, runs: runs, signUsPercentiles: pct, threads: threads, verifyHelper: verify), to: json)
    print(ok ? "SIGN: PASS" : "SIGN: FAIL")
    return ok
}

/// Unattended: a `.userPresence` key with an LAContext that forbids UI must refuse to sign.
func runTouchIDCheck(json: String?) async -> Bool {
    print("== S10 touchid-check: .userPresence key, interaction not allowed (unattended) ==")
    guard let ac = userPresenceAccessControl() else { print("TOUCHID-CHECK: FAIL (no access control)"); return false }
    let ctx = LAContext()
    ctx.interactionNotAllowed = true
    var result: [String: String] = [:]
    var ok = false
    do {
        let signer = try SecureEnclaveSigner(format: .der, accessControl: ac, context: ctx)
        result["key_created"] = "yes (SE, .privateKeyUsage + .userPresence)"
        do {
            let r = try await handshake(signer: signer, token: nil, signTimeoutMs: 10_000, probe: 50)
            result["handshake"] = "UNEXPECTED SUCCESS verified=\(r.verified)"
        } catch {
            result["handshake"] = "refused as expected: \(error)"
            ok = true
        }
    } catch {
        result["key_created"] = "failed: \(error)"
    }
    _ = takeProbeEvents(probe: 50)
    for (k, v) in result.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v)") }
    writeJSON(result, to: json)
    print(ok ? "TOUCHID-CHECK: PASS (user-presence policy enforced by the Secure Enclave)" : "TOUCHID-CHECK: FAIL")
    return ok
}

/// MANUAL: needs a person at the Mac to touch the sensor (or type the password).
func runTouchIDManual(timeoutMs: UInt64) async -> Bool {
    print("== S10 touchid (MANUAL): a Touch ID sheet will appear — touch the sensor ==")
    guard let ac = userPresenceAccessControl() else { return false }
    let ctx = LAContext()
    ctx.localizedReason = "sign the Tombolo S10 spike handshake"
    do {
        let signer = try SecureEnclaveSigner(format: .der, accessControl: ac, context: ctx)
        let t0 = nowNs()
        let r = try await handshake(signer: signer, token: nil, signTimeoutMs: timeoutMs, probe: 60)
        print("  verified=\(r.verified) fmt=\(r.signatureFormat) after \(f1(ms(nowNs() - t0))) ms (includes the human)")
        print("TOUCHID: \(r.verified ? "PASS" : "FAIL")")
        return r.verified
    } catch {
        print("  handshake failed: \(error)")
        print("  (TimedOut => Rust dropped the foreign future, Swift invalidated the LAContext and the sheet should have closed)")
        print("TOUCHID: FAIL")
        return false
    }
}
