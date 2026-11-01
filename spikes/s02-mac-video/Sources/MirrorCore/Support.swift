// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S2: small shared helpers — host clock, big-endian byte access, a lock, errors.
import Foundation

/// Host time in nanoseconds on `CLOCK_UPTIME_RAW` (= `mach_absolute_time`). This is the clock the S1 latency
/// harness, ScreenCaptureKit display times and `CACurrentMediaTime()` all use, so timestamps line up.
@inline(__always) public func hostNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// `CACurrentMediaTime()`-style seconds → host nanoseconds.
@inline(__always) func hostNanos(fromMediaTime t: CFTimeInterval) -> UInt64 { t > 0 ? UInt64(t * 1e9) : 0 }

public enum MirrorError: Error, CustomStringConvertible, Sendable {
    case adbNotFound
    case adb(String)
    case noDevice(String)
    case serverFileMissing(String)
    case invalidServerOption(String)
    case connectFailed(String)
    case protocolError(String)
    case streamDisabled(String)
    case decoder(String)
    case closed

    public var description: String {
        switch self {
        case .adbNotFound: return "adb not found (set ADB or install the Android SDK platform-tools)"
        case .adb(let s): return "adb: \(s)"
        case .noDevice(let s): return "no device: \(s)"
        case .serverFileMissing(let s): return "scrcpy-server file missing: \(s) (run scripts/fetch-server.sh)"
        case .invalidServerOption(let s): return "invalid server option: \(s)"
        case .connectFailed(let s): return "could not connect to scrcpy-server: \(s)"
        case .protocolError(let s): return "protocol error: \(s)"
        case .streamDisabled(let s): return "stream disabled by the device: \(s)"
        case .decoder(let s): return "decoder: \(s)"
        case .closed: return "closed"
        }
    }
}

/// A tiny mutex (os_unfair_lock wrapped so it has a stable address).
final class Lock: @unchecked Sendable {
    private let l: UnsafeMutablePointer<os_unfair_lock>
    init() { l = .allocate(capacity: 1); l.initialize(to: os_unfair_lock()) }
    deinit { l.deinitialize(count: 1); l.deallocate() }
    @inline(__always) func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(l); defer { os_unfair_lock_unlock(l) }
        return try body()
    }
}

// MARK: - Big-endian helpers

extension Data {
    @inline(__always) func be16(_ o: Int) -> UInt16 {
        let b = startIndex + o
        return UInt16(self[b]) << 8 | UInt16(self[b + 1])
    }
    @inline(__always) func be32(_ o: Int) -> UInt32 {
        let b = startIndex + o
        return UInt32(self[b]) << 24 | UInt32(self[b + 1]) << 16 | UInt32(self[b + 2]) << 8 | UInt32(self[b + 3])
    }
    @inline(__always) func be64(_ o: Int) -> UInt64 { UInt64(be32(o)) << 32 | UInt64(be32(o + 4)) }

    mutating func appendBE16(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xff)) }
    mutating func appendBE32(_ v: UInt32) { for s in stride(from: 24, through: 0, by: -8) { append(UInt8((v >> UInt32(s)) & 0xff)) } }
    mutating func appendBE64(_ v: UInt64) { appendBE32(UInt32(v >> 32)); appendBE32(UInt32(v & 0xffff_ffff)) }
}

/// Index at which to cut a UTF-8 string so it is at most `maxLen` bytes without splitting a code point
/// (scrcpy `sc_str_utf8_truncation_index`, app/src/util/str.c).
func utf8TruncationIndex(_ bytes: [UInt8], maxLen: Int) -> Int {
    if bytes.count <= maxLen { return bytes.count }
    var len = maxLen
    while len > 0, bytes[len] & 0x80 != 0, bytes[len] & 0xc0 != 0xc0 { len -= 1 }
    return len
}

// MARK: - Percentiles (type 7, as in the S1 harness)

public struct Percentiles: Codable, Sendable, CustomStringConvertible {
    public var n: Int
    public var p50: Double
    public var p95: Double
    public var p99: Double
    public var min: Double
    public var max: Double
    public var mean: Double

    public init(_ values: [Double]) {
        n = values.count
        guard !values.isEmpty else { p50 = .nan; p95 = .nan; p99 = .nan; min = .nan; max = .nan; mean = .nan; return }
        let s = values.sorted()
        func q(_ p: Double) -> Double {
            let h = Double(s.count - 1) * p
            let lo = Int(h.rounded(.down)), hi = Swift.min(lo + 1, s.count - 1)
            return s[lo] + (h - Double(lo)) * (s[hi] - s[lo])
        }
        p50 = q(0.5); p95 = q(0.95); p99 = q(0.99)
        min = s.first!; max = s.last!
        mean = s.reduce(0, +) / Double(s.count)
    }

    public var description: String {
        n == 0 ? "n=0" : String(format: "n=%d p50=%.2f p95=%.2f p99=%.2f (min %.2f max %.2f mean %.2f)", n, p50, p95, p99, min, max, mean)
    }
}
