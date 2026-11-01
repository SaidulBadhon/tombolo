// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct PercentileSummary: Sendable, Codable, Equatable {
    public var n: Int
    public var mean: Double
    public var sd: Double
    public var min: Double
    public var max: Double
    public var p50: Double
    public var p95: Double
    public var p99: Double
    /// 95 % bootstrap confidence intervals (percentile method), [low, high].
    public var p50CI: [Double]
    public var p95CI: [Double]
    public var p99CI: [Double]
}

public enum Stats {
    /// Linear-interpolation percentile (Hyndman & Fan type 7, the numpy/R default). `q` in 0…100.
    public static func percentile(_ values: [Double], _ q: Double) -> Double {
        percentile(sorted: values.sorted(), q)
    }

    public static func percentile(sorted s: [Double], _ q: Double) -> Double {
        guard !s.isEmpty else { return .nan }
        if s.count == 1 { return s[0] }
        let h = (Double(s.count) - 1) * q / 100
        let lo = Int(h.rounded(.down)), hi = Swift.min(lo + 1, s.count - 1)
        return s[lo] + (h - Double(lo)) * (s[hi] - s[lo])
    }

    public static func median(_ values: [Double]) -> Double { percentile(values, 50) }

    public static func mean(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count) }

    public static func sd(_ v: [Double]) -> Double {
        guard v.count > 1 else { return 0 }
        let m = mean(v)
        return (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count - 1)).squareRoot()
    }

    /// Percentiles with bootstrap CIs. Deterministic for a given seed.
    public static func summarize(_ values: [Double], bootstrap: Int = 1000, seed: UInt64 = 1) -> PercentileSummary? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        var rng = SplitMix64(seed: seed)
        var b50: [Double] = [], b95: [Double] = [], b99: [Double] = []
        b50.reserveCapacity(bootstrap); b95.reserveCapacity(bootstrap); b99.reserveCapacity(bootstrap)
        var res = [Double](repeating: 0, count: s.count)
        for _ in 0..<bootstrap {
            for i in 0..<s.count { res[i] = s[Int(rng.next() % UInt64(s.count))] }
            res.sort()
            b50.append(percentile(sorted: res, 50))
            b95.append(percentile(sorted: res, 95))
            b99.append(percentile(sorted: res, 99))
        }
        func ci(_ b: [Double]) -> [Double] {
            let bs = b.sorted()
            return [percentile(sorted: bs, 2.5), percentile(sorted: bs, 97.5)]
        }
        return PercentileSummary(
            n: s.count, mean: mean(s), sd: sd(s), min: s.first!, max: s.last!,
            p50: percentile(sorted: s, 50), p95: percentile(sorted: s, 95), p99: percentile(sorted: s, 99),
            p50CI: ci(b50), p95CI: ci(b95), p99CI: ci(b99))
    }
}
