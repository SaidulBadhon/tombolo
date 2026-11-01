// SPDX-License-Identifier: GPL-3.0-or-later
//
// Cristian/NTP-style clock-offset estimation between the phone page clock (`performance.now()`,
// milliseconds) and the Mac host clock (mach_absolute_time domain, nanoseconds).
//
// Each round trip gives four timestamps: phone send t0, Mac receive T1, Mac send T2, phone
// receive t3. Then
//     rtt    = (t3 − t0) − (T2 − T1)
//     offset = ((T1 − t0) + (T2 − t3)) / 2          (Mac − phone)
// and the true offset lies within offset ± rtt/2 for any split of the network delay. We keep the
// minimum-RTT sample of each time window (the least-queued exchanges), then fit only the
// lower-RTT half of those windows: queueing is rarely symmetric, so higher-RTT windows carry
// larger, load-dependent bias that a drift fit would otherwise mistake for clock drift (seen in
// the self-test). offset(t) = a + b·(t − t_ref) is fitted by weighted least squares when the run
// is long enough to see drift.
//
// Stated uncertainty (systematic, applies equally to every latency sample):
//   bound = max rtt/2 over the windows used — every used exchange confines the true offset to
//           its ± rtt/2, and a weighted mean of them cannot be further off than the worst one;
//   plus, when drift is fitted, 2 standard errors of the slope over half the span.

import Foundation

public struct SyncSample: Sendable, Equatable {
    public var phoneSendMs: Double
    public var phoneRecvMs: Double
    public var macRecvNs: Int64
    public var macSendNs: Int64

    public init(phoneSendMs: Double, phoneRecvMs: Double, macRecvNs: Int64, macSendNs: Int64) {
        self.phoneSendMs = phoneSendMs
        self.phoneRecvMs = phoneRecvMs
        self.macRecvNs = macRecvNs
        self.macSendNs = macSendNs
    }

    public var rttMs: Double { (phoneRecvMs - phoneSendMs) - Double(macSendNs - macRecvNs) / 1e6 }
    public var phoneMidMs: Double { (phoneSendMs + phoneRecvMs) / 2 }
    /// Mac − phone, milliseconds.
    public var offsetMs: Double {
        ((Double(macRecvNs) / 1e6 - phoneSendMs) + (Double(macSendNs) / 1e6 - phoneRecvMs)) / 2
    }
}

public struct ClockModel: Sendable, Codable, Equatable {
    public var referencePhoneMs: Double
    /// Mac − phone at `referencePhoneMs`, milliseconds.
    public var offsetMs: Double
    /// Rate difference, parts per million (positive = Mac clock runs faster).
    public var driftPPM: Double
    /// ± systematic bound from path asymmetry: max rtt/2 of the windows used in the fit.
    public var boundMs: Double
    /// Standard error of the fitted drift (0 when drift is not fitted).
    public var driftSEPPM: Double
    /// 2 · SE(drift) · span/2: how far a wrong drift can move the mapping inside the run.
    public var driftContributionMs: Double
    /// RMS residual of the kept samples about the fit.
    public var residualMs: Double
    public var samplesTotal: Int
    public var windowsUsed: Int
    public var rttMinMs: Double
    public var rttMedianKeptMs: Double
    public var rttMedianAllMs: Double
    public var spanS: Double
    public var fittedDrift: Bool

    public func macMs(fromPhoneMs p: Double) -> Double {
        p + offsetMs + driftPPM * 1e-6 * (p - referencePhoneMs)
    }

    public func phoneMs(fromMacMs m: Double) -> Double {
        let b = driftPPM * 1e-6
        return (m - offsetMs + b * referencePhoneMs) / (1 + b)
    }
}

public enum ClockSync {
    /// - Parameters:
    ///   - windowMs: length of the min-RTT selection window (phone time).
    ///   - minSpanForDriftMs: fit drift only when the kept windows span at least this long.
    public static func estimate(_ samples: [SyncSample], windowMs: Double = 2000, minSpanForDriftMs: Double = 10_000) -> ClockModel? {
        // A coarse phone timer (Safari: 1 ms) can make rtt slightly negative; keep those.
        let valid = samples.filter { $0.rttMs > -2.5 && $0.rttMs < 2000 }.sorted { $0.phoneMidMs < $1.phoneMidMs }
        guard !valid.isEmpty else { return nil }

        // Best sample per window. Among near-ties (within 50 µs of the window minimum) take the
        // median offset, which matters when the phone timer is coarse.
        var picks: [(t: Double, off: Double, rtt: Double)] = []
        var i = 0
        while i < valid.count {
            let start = valid[i].phoneMidMs
            var j = i
            while j < valid.count, valid[j].phoneMidMs < start + windowMs { j += 1 }
            let win = valid[i..<j]
            let minRtt = win.map(\.rttMs).min()!
            let ties = win.filter { $0.rttMs <= minRtt + 0.05 }.sorted { $0.offsetMs < $1.offsetMs }
            let m = ties[ties.count / 2]
            picks.append((m.phoneMidMs, m.offsetMs, max(m.rttMs, 0)))
            i = j
        }
        let baseRtt = Stats.median(picks.map(\.rtt))
        let plausible = picks.filter { $0.rtt <= max(2 * baseRtt, baseRtt + 1.0) }
        guard !plausible.isEmpty else { return nil }
        // Lower-RTT half (all windows when there are fewer than six).
        var kept = plausible
        if plausible.count >= 6 {
            let cut = Stats.median(plausible.map(\.rtt))
            kept = plausible.filter { $0.rtt <= cut }
        }

        let span = (kept.last!.t - kept.first!.t)
        let ref = (kept.first!.t + kept.last!.t) / 2
        var a = 0.0, b = 0.0, seB = 0.0
        let weights = kept.map { 1 / (($0.rtt + 0.2) * ($0.rtt + 0.2)) }
        let fitDrift = kept.count >= 4 && span >= minSpanForDriftMs
        if fitDrift {
            var sw = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
            for (k, p) in kept.enumerated() {
                let w = weights[k], x = p.t - ref, y = p.off
                sw += w; sx += w * x; sy += w * y; sxx += w * x * x; sxy += w * x * y
            }
            let den = sw * sxx - sx * sx
            if abs(den) > 1e-12 {
                b = (sw * sxy - sx * sy) / den
                a = (sy - b * sx) / sw
                // SE of the slope with weights treated as relative inverse variances.
                var swr2 = 0.0
                for (k, p) in kept.enumerated() {
                    let r = p.off - (a + b * (p.t - ref))
                    swr2 += weights[k] * r * r
                }
                let xbar = sx / sw
                let sxxc = sxx - sw * xbar * xbar
                if kept.count > 2, sxxc > 0 { seB = (swr2 / Double(kept.count - 2) / sxxc).squareRoot() }
            } else {
                a = sy / sw
            }
        } else {
            var sw = 0.0, sy = 0.0
            for (k, p) in kept.enumerated() { sw += weights[k]; sy += weights[k] * p.off }
            a = sy / sw
        }
        var ss = 0.0
        for p in kept {
            let r = p.off - (a + b * (p.t - ref))
            ss += r * r
        }
        let residual = (ss / Double(kept.count)).squareRoot()
        return ClockModel(
            referencePhoneMs: ref, offsetMs: a, driftPPM: b * 1e6,
            boundMs: kept.map(\.rtt).max()! / 2, driftSEPPM: seB * 1e6, driftContributionMs: 2 * seB * span / 2,
            residualMs: residual,
            samplesTotal: samples.count, windowsUsed: kept.count,
            rttMinMs: kept.map(\.rtt).min()!, rttMedianKeptMs: Stats.median(kept.map(\.rtt)),
            rttMedianAllMs: Stats.median(valid.map { max($0.rttMs, 0) }),
            spanS: span / 1000, fittedDrift: fitDrift)
    }
}
