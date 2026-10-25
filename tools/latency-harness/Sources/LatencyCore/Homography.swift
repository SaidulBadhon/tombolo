// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A planar projective transform (3 × 3, row-major, h[8] normalised to 1 where possible).
public struct Homography: Sendable, Equatable {
    public var m: [Double]

    public init(m: [Double]) {
        precondition(m.count == 9)
        self.m = m
    }

    public static let identity = Homography(m: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    /// Similarity transform: scale, rotation (radians) about the origin, then translation.
    public static func similarity(scale: Double, rotation: Double = 0, tx: Double, ty: Double) -> Homography {
        let c = cos(rotation) * scale, s = sin(rotation) * scale
        return Homography(m: [c, -s, tx, s, c, ty, 0, 0, 1])
    }

    @inline(__always) public func apply(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        let w = m[6] * x + m[7] * y + m[8]
        return ((m[0] * x + m[1] * y + m[2]) / w, (m[3] * x + m[4] * y + m[5]) / w)
    }

    /// Solves for the homography mapping `src[i]` → `dst[i]` (exactly four correspondences).
    public static func fromPoints(_ src: [(x: Double, y: Double)], _ dst: [(x: Double, y: Double)]) -> Homography? {
        guard src.count == 4, dst.count == 4 else { return nil }
        // Unknowns h0…h7 with h8 = 1.
        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let (x, y) = src[i], (u, v) = dst[i]
            a[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            a[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        guard let h = solve(&a) else { return nil }
        return Homography(m: h + [1])
    }

    public func inverted() -> Homography? {
        let a = m
        let c00 = a[4] * a[8] - a[5] * a[7]
        let c01 = -(a[3] * a[8] - a[5] * a[6])
        let c02 = a[3] * a[7] - a[4] * a[6]
        let det = a[0] * c00 + a[1] * c01 + a[2] * c02
        guard abs(det) > 1e-15 else { return nil }
        let inv = [
            c00, -(a[1] * a[8] - a[2] * a[7]), a[1] * a[5] - a[2] * a[4],
            c01, a[0] * a[8] - a[2] * a[6], -(a[0] * a[5] - a[2] * a[3]),
            c02, -(a[0] * a[7] - a[1] * a[6]), a[0] * a[4] - a[1] * a[3],
        ].map { $0 / det }
        return Homography(m: inv)
    }

    /// Composition: (self ∘ other)(p) = self(other(p)).
    public func composed(with other: Homography) -> Homography {
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 {
                var s = 0.0
                for k in 0..<3 { s += m[i * 3 + k] * other.m[k * 3 + j] }
                r[i * 3 + j] = s
            }
        }
        return Homography(m: r)
    }

    /// Gaussian elimination with partial pivoting on an n × (n+1) augmented matrix.
    private static func solve(_ a: inout [[Double]]) -> [Double]? {
        let n = a.count
        for col in 0..<n {
            var piv = col
            for r in (col + 1)..<n where abs(a[r][col]) > abs(a[piv][col]) { piv = r }
            guard abs(a[piv][col]) > 1e-12 else { return nil }
            a.swapAt(col, piv)
            for r in 0..<n where r != col {
                let f = a[r][col] / a[col][col]
                if f == 0 { continue }
                for c in col...n { a[r][c] -= f * a[col][c] }
            }
        }
        return (0..<n).map { a[$0][n] / a[$0][$0] }
    }
}
