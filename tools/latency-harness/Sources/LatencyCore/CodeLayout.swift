// SPDX-License-Identifier: GPL-3.0-or-later
//
// TLC1 — "Tombolo latency code", version 1. A small 2D symbol designed to survive screen mirroring
// (scaling, H.264 compression) and being filmed by a camera (blur, perspective, noise).
//
// Geometry, in modules (the symbol is 32 × 16 modules; renderers add a white quiet zone of at
// least 2 modules on every side):
//
//     x: 0      7 8                     24 25     32
//        +-------+ +---------------------+ +-------+   y = 0
//        |finder | |                     | |finder |
//        |  TL   | |   data: 8 × 8 cells | |  TR   |
//        +-------+ |   of 2 × 2 modules  | +-------+   y = 7
//        +-------+ |   (64 bits)         | +-------+   y = 9
//        |finder | |                     | |finder |
//        |  BL   | |                     | |  BR   |
//        +-------+ +---------------------+ +-------+   y = 16
//
// * Finder patterns are QR-style 7 × 7 squares (1:1:3:1:1 black/white/black/white/black along any
//   line through the centre), each followed by a one-module white separator. Their centres are at
//   module coordinates (3.5, 3.5), (28.5, 3.5), (28.5, 12.5), (3.5, 12.5).
// * Data cell (c, r), c, r ∈ 0…7, covers modules x ∈ [8 + 2c, 10 + 2c), y ∈ [2r, 2r + 2).
//   Bit k = 8r + c of the 64-bit word, most significant bit first. 1 = black.
// * 64-bit word = payload (40 bits) ‖ CRC-24/OpenPGP(payload bytes) (24 bits), XORed with a fixed
//   mask so that no value produces large uniform areas.
// * Payload, most significant first: kind (4 bits) ‖ session (4 bits) ‖ ticks (32 bits).
//   `ticks` is a time in units of 100 µs, modulo 2^32 (wraps after ≈ 4.97 days; the analysis
//   unwraps it against the capture clock).
//
// The JavaScript encoder in `web/code.js` implements the same layout; `JSParityTests` checks that
// both produce identical module matrices.

/// What clock a symbol's `ticks` field refers to.
public enum CodeKind: UInt8, Sendable, CustomStringConvertible {
    /// The phone page: ticks = requestAnimationFrame timestamp (page `performance.now()` clock).
    case page = 0
    /// The Mac reference window: ticks = Mac host time (mach_absolute_time domain).
    case macReference = 1
    /// Synthetic test frames.
    case synthetic = 2

    public var description: String {
        switch self {
        case .page: return "page"
        case .macReference: return "mac"
        case .synthetic: return "synthetic"
        }
    }
}

/// The decoded content of one symbol.
public struct CodePayload: Equatable, Hashable, Sendable {
    public var kindRaw: UInt8   // 4 bits
    public var session: UInt8   // 4 bits
    public var ticks: UInt32    // 100 µs units, mod 2^32

    public init(kind: CodeKind, session: UInt8, ticks: UInt32) {
        self.kindRaw = kind.rawValue
        self.session = session & 0x0F
        self.ticks = ticks
    }

    public init(kindRaw: UInt8, session: UInt8, ticks: UInt32) {
        self.kindRaw = kindRaw & 0x0F
        self.session = session & 0x0F
        self.ticks = ticks
    }

    public var kind: CodeKind? { CodeKind(rawValue: kindRaw) }
}

public enum CodeLayout {
    public static let widthModules = 32
    public static let heightModules = 16
    /// Recommended white margin around the symbol, in modules.
    public static let quietZoneModules = 2
    public static let finderSize = 7
    public static let cellModules = 2
    public static let dataOriginX = 8
    public static let dataColumns = 8
    public static let dataRows = 8
    public static let bitCount = 64

    /// Finder centres in module coordinates: TL, TR, BR, BL.
    public static let finderCentres: [(x: Double, y: Double)] = [
        (3.5, 3.5), (28.5, 3.5), (28.5, 12.5), (3.5, 12.5),
    ]
    /// Finder top-left module positions: TL, TR, BR, BL.
    public static let finderOrigins: [(x: Int, y: Int)] = [(0, 0), (25, 0), (25, 9), (0, 9)]

    /// XOR mask applied to the 8 bytes of the word (the 64-bit golden-ratio constant).
    public static let mask: [UInt8] = [0x9E, 0x37, 0x79, 0xB9, 0x7F, 0x4A, 0x7C, 0x15]

    /// Centre of data cell `k` in module coordinates.
    public static func cellCentre(_ k: Int) -> (x: Double, y: Double) {
        let c = k % dataColumns, r = k / dataColumns
        return (Double(dataOriginX + cellModules * c) + 1.0, Double(cellModules * r) + 1.0)
    }

    // MARK: - Payload ⇄ bits

    /// CRC-24/OpenPGP (poly 0x864CFB, init 0xB704CE, no reflection, no final XOR).
    public static func crc24(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xB704CE
        for b in bytes {
            crc ^= UInt32(b) << 16
            for _ in 0..<8 {
                crc <<= 1
                if crc & 0x100_0000 != 0 { crc ^= 0x186_4CFB }
            }
        }
        return crc & 0xFF_FFFF
    }

    static func payloadBytes(_ p: CodePayload) -> [UInt8] {
        [
            (p.kindRaw << 4) | (p.session & 0x0F),
            UInt8(truncatingIfNeeded: p.ticks >> 24),
            UInt8(truncatingIfNeeded: p.ticks >> 16),
            UInt8(truncatingIfNeeded: p.ticks >> 8),
            UInt8(truncatingIfNeeded: p.ticks),
        ]
    }

    /// The 64 data bits (index 0 = most significant), mask applied. `true` = black.
    public static func bits(for payload: CodePayload) -> [Bool] {
        var bytes = payloadBytes(payload)
        let crc = crc24(bytes)
        bytes += [UInt8(truncatingIfNeeded: crc >> 16), UInt8(truncatingIfNeeded: crc >> 8), UInt8(truncatingIfNeeded: crc)]
        var out = [Bool](repeating: false, count: bitCount)
        for i in 0..<bitCount {
            let byte = bytes[i >> 3] ^ mask[i >> 3]
            out[i] = (byte >> (7 - UInt8(i & 7))) & 1 == 1
        }
        return out
    }

    /// Inverse of `bits(for:)`; returns nil when the CRC does not match.
    public static func payload(fromBits bits: [Bool]) -> CodePayload? {
        guard bits.count == bitCount else { return nil }
        var bytes = [UInt8](repeating: 0, count: 8)
        for i in 0..<bitCount where bits[i] {
            bytes[i >> 3] |= 1 << (7 - UInt8(i & 7))
        }
        for i in 0..<8 { bytes[i] ^= mask[i] }
        let crc = crc24(Array(bytes[0..<5]))
        let got = (UInt32(bytes[5]) << 16) | (UInt32(bytes[6]) << 8) | UInt32(bytes[7])
        guard crc == got else { return nil }
        let ticks = (UInt32(bytes[1]) << 24) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 8) | UInt32(bytes[4])
        return CodePayload(kindRaw: bytes[0] >> 4, session: bytes[0] & 0x0F, ticks: ticks)
    }

    // MARK: - Module matrix

    /// Row-major 32 × 16 matrix, `true` = black module.
    public static func modules(for payload: CodePayload) -> [Bool] {
        modules(bits: bits(for: payload))
    }

    public static func modules(bits: [Bool]) -> [Bool] {
        var m = [Bool](repeating: false, count: widthModules * heightModules)
        for (ox, oy) in finderOrigins {
            for dy in 0..<finderSize {
                for dx in 0..<finderSize {
                    let d = max(abs(dx - 3), abs(dy - 3))
                    if d != 2 { m[(oy + dy) * widthModules + ox + dx] = true }
                }
            }
        }
        for k in 0..<bitCount where bits[k] {
            let c = k % dataColumns, r = k / dataColumns
            let x0 = dataOriginX + cellModules * c, y0 = cellModules * r
            for y in y0..<(y0 + cellModules) {
                for x in x0..<(x0 + cellModules) { m[y * widthModules + x] = true }
            }
        }
        return m
    }

    // MARK: - Time helpers

    /// 100 µs ticks for a time in milliseconds, modulo 2^32.
    public static func ticks(fromMilliseconds ms: Double) -> UInt32 {
        let t = (ms * 10).rounded()
        let m = t.truncatingRemainder(dividingBy: 4_294_967_296)
        return UInt32(m < 0 ? m + 4_294_967_296 : m)
    }

    /// 100 µs ticks for a time in nanoseconds, modulo 2^32.
    public static func ticks(fromNanoseconds ns: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: (ns + 50_000) / 100_000)
    }

    /// Unwraps a modulo-2^32 tick value to the full value nearest to `near` (also in ticks).
    public static func unwrap(ticks: UInt32, near: Double) -> Double {
        let period = 4_294_967_296.0
        let base = (near / period).rounded(.down) * period
        var best = base + Double(ticks)
        for cand in [best - period, best + period] where abs(cand - near) < abs(best - near) {
            best = cand
        }
        return best
    }
}
