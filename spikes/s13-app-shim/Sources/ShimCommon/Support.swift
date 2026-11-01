// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S13: logging, code-signing checks and small statistics helpers.
import Foundation
import Security

// MARK: - Log

public final class Log {
    private let handle: FileHandle?
    private let lock = NSLock()
    private let tag: String
    public let path: URL

    public init(name: String, tag: String) {
        self.tag = tag
        try? FileManager.default.createDirectory(at: S13.logDir, withIntermediateDirectories: true)
        path = S13.logDir.appendingPathComponent("\(name).log")
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: path)
        _ = try? handle?.seekToEnd()
    }

    /// Lines start with CLOCK_UPTIME_RAW milliseconds so logs from different processes can be merged.
    public func callAsFunction(_ msg: String) {
        let line = String(format: "%.3f [%@ %d] ", Double(nowNs()) / 1e6, tag, getpid()) + msg + "\n"
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardError.write(Data(line.utf8))
        handle?.write(Data(line.utf8))
    }
}

// MARK: - Code signing

public enum CodeSign {
    /// Verify the sender of a Mach message (by audit token) against a code requirement string.
    /// Returns (ok, description of the peer's signature).
    public static func check(audit: [UInt32], requirement: String) -> (Bool, String) {
        guard audit.count == 8 else { return (false, "no audit token") }
        var token = audit_token_t(val: (audit[0], audit[1], audit[2], audit[3], audit[4], audit[5], audit[6], audit[7]))
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        var code: SecCode?
        var st = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code)
        guard st == errSecSuccess, let code else { return (false, "SecCodeCopyGuestWithAttributes \(st)") }
        var req: SecRequirement?
        st = SecRequirementCreateWithString(requirement as CFString, [], &req)
        guard st == errSecSuccess, let req else { return (false, "bad requirement \(st)") }
        let valid = SecCodeCheckValidity(code, [], req)
        return (valid == errSecSuccess, "\(describe(code)) status=\(valid)")
    }

    static func describe(_ code: SecCode) -> String {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return "?" }
        return describe(staticCode)
    }

    public static func describe(_ s: SecStaticCode) -> String {
        let info = signingInfo(s)
        let id = info[kSecCodeInfoIdentifier as String] as? String ?? "-"
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String ?? "none"
        return "identifier=\(id) team=\(team) cdhash=\(cdhash(info) ?? "-")"
    }

    static func signingInfo(_ s: SecStaticCode) -> [String: Any] {
        var info: CFDictionary?
        SecCodeCopySigningInformation(s, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        return info as? [String: Any] ?? [:]
    }

    static func cdhash(_ info: [String: Any]) -> String? {
        (info[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined()
    }

    /// cdhash of a bundle on disk (used by the host to pin the shims it generated).
    public static func cdhash(ofBundle url: URL) -> String? {
        var s: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &s) == errSecSuccess, let s else { return nil }
        return cdhash(signingInfo(s))
    }
}

// MARK: - Stats

public struct Percentiles: Codable {
    public let count: Int, p50: Double, p95: Double, p99: Double, max: Double, mean: Double
    public init(_ values: [Double]) {
        let v = values.sorted()
        count = v.count
        func q(_ p: Double) -> Double { v.isEmpty ? .nan : v[min(v.count - 1, Int((p * Double(v.count - 1)).rounded()))] }
        p50 = q(0.50); p95 = q(0.95); p99 = q(0.99); max = v.last ?? .nan
        mean = v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count)
    }
    public var text: String { String(format: "n=%d p50=%.3f p95=%.3f p99=%.3f max=%.3f mean=%.3f ms", count, p50, p95, p99, max, mean) }
}
