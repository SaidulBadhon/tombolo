// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import LatencyCore

/// Simulates round trips: phone clock p, Mac clock m = p·(1 + drift) + offset (both ms).
/// One-way delays: base + exponential queueing, independently per direction (asymmetric).
func simulate(offsetMs: Double, driftPPM: Double, seconds: Double, rateHz: Double, baseUp: Double, baseDown: Double,
              jitterMs: Double, serverMs: Double = 0.15, timerResolutionMs: Double = 0, seed: UInt64 = 1) -> [SyncSample] {
    var rng = SplitMix64(seed: seed)
    func expo(_ mean: Double) -> Double { -mean * log(max(rng.nextDouble(), 1e-12)) }
    func q(_ v: Double) -> Double { timerResolutionMs > 0 ? (v / timerResolutionMs).rounded(.down) * timerResolutionMs : v }
    func mac(_ p: Double) -> Double { p * (1 + driftPPM * 1e-6) + offsetMs }
    var out: [SyncSample] = []
    var p = 1000.0
    let start = p
    while p < start + seconds * 1000 {
        let up = baseUp + expo(jitterMs), down = baseDown + expo(jitterMs)
        let t0 = p
        let T1 = mac(t0 + up)
        let T2 = T1 + serverMs
        let t3 = t0 + up + serverMs / (1 + driftPPM * 1e-6) + down
        out.append(SyncSample(phoneSendMs: q(t0), phoneRecvMs: q(t3), macRecvNs: Int64((T1 * 1e6).rounded()), macSendNs: Int64((T2 * 1e6).rounded())))
        p += 1000 / rateHz
    }
    return out
}

@Suite struct ClockSyncTests {
    @Test func symmetricConstantOffset() throws {
        let s = simulate(offsetMs: 45_000_123.456, driftPPM: 0, seconds: 30, rateHz: 4, baseUp: 0.4, baseDown: 0.4, jitterMs: 0.5)
        let m = try #require(ClockSync.estimate(s))
        #expect(abs(m.macMs(fromPhoneMs: 5000) - (5000 + 45_000_123.456)) < 0.05)
        #expect(m.boundMs > 0.3 && m.boundMs < 1.0)
    }

    @Test(arguments: [(-60.0, UInt64(1)), (0.0, UInt64(2)), (35.0, UInt64(3)), (120.0, UInt64(4))])
    func asymmetricDelaysWithDrift(_ drift: Double, _ seed: UInt64) throws {
        // Up-link 0.3 ms, down-link 1.2 ms base: a 0.45 ms systematic bias that only the bound covers.
        let offset = -12_345.678
        let s = simulate(offsetMs: offset, driftPPM: drift, seconds: 60, rateHz: 4, baseUp: 0.3, baseDown: 1.2, jitterMs: 2, seed: seed)
        let m = try #require(ClockSync.estimate(s))
        #expect(m.fittedDrift)
        #expect(abs(m.driftPPM - drift) < 10, "drift \(m.driftPPM) vs \(drift)")
        for p in stride(from: 2000.0, through: 60_000, by: 7000) {
            let truth = p * (1 + drift * 1e-6) + offset
            let err = m.macMs(fromPhoneMs: p) - truth
            #expect(abs(err) <= m.boundMs + m.residualMs, "error \(err) at \(p) exceeds bound \(m.boundMs)")
        }
    }

    @Test func coarseTimerStillBounded() throws {
        // Safari-like 1 ms timer: individual RTTs can even come out negative.
        let s = simulate(offsetMs: 777.25, driftPPM: 0, seconds: 40, rateHz: 4, baseUp: 0.5, baseDown: 0.5, jitterMs: 0.8, timerResolutionMs: 1)
        let m = try #require(ClockSync.estimate(s))
        let err = m.macMs(fromPhoneMs: 20_000) - (20_000 + 777.25)
        #expect(abs(err) <= m.boundMs + 0.5 + m.residualMs)
    }

    @Test func shortRunDoesNotFitDrift() throws {
        let s = simulate(offsetMs: 5, driftPPM: 50, seconds: 5, rateHz: 10, baseUp: 0.5, baseDown: 0.5, jitterMs: 0.5)
        let m = try #require(ClockSync.estimate(s))
        #expect(!m.fittedDrift)
        #expect(m.driftPPM == 0)
    }

    @Test func burstOfQueuedSamplesIsRejected() throws {
        var s = simulate(offsetMs: 100, driftPPM: 0, seconds: 40, rateHz: 4, baseUp: 0.5, baseDown: 0.5, jitterMs: 0.3)
        // A 6-second stretch where every exchange was delayed 30 ms one way (e.g. Wi-Fi power save).
        for i in s.indices where s[i].phoneSendMs > 10_000 && s[i].phoneSendMs < 16_000 {
            s[i].phoneRecvMs += 30
        }
        let m = try #require(ClockSync.estimate(s))
        #expect(abs(m.macMs(fromPhoneMs: 13_000) - 13_100) < 0.3)
    }

    @Test func inverse() {
        let m = ClockModel(referencePhoneMs: 1000, offsetMs: 55, driftPPM: 80, boundMs: 0, residualMs: 0, samplesTotal: 0, windowsUsed: 0,
                           rttMinMs: 0, rttMedianKeptMs: 0, rttMedianAllMs: 0, spanS: 0, fittedDrift: true)
        for p in [0.0, 1000, 123_456.789] {
            #expect(abs(m.phoneMs(fromMacMs: m.macMs(fromPhoneMs: p)) - p) < 1e-6)
        }
    }
}

@Suite struct StatsTests {
    @Test func percentilesMatchType7() {
        let v = [1.0, 2, 3, 4]
        #expect(Stats.percentile(v, 50) == 2.5)
        #expect(abs(Stats.percentile(v, 95) - 3.85) < 1e-12)
        #expect(Stats.percentile(v, 0) == 1)
        #expect(Stats.percentile(v, 100) == 4)
        let r = (1...100).map(Double.init)
        #expect(abs(Stats.percentile(r, 99) - 99.01) < 1e-9)
    }

    @Test func bootstrapIsDeterministicAndBracketsEstimate() throws {
        var rng = SplitMix64(seed: 3)
        let v = (0..<500).map { _ in 30 + rng.nextGaussian() * 3 }
        let a = try #require(Stats.summarize(v, bootstrap: 300, seed: 9))
        let b = try #require(Stats.summarize(v, bootstrap: 300, seed: 9))
        #expect(a == b)
        #expect(a.p50CI[0] <= a.p50 && a.p50 <= a.p50CI[1])
        #expect(a.p95CI[0] <= a.p95 && a.p95 <= a.p95CI[1])
        #expect(a.p50CI[1] - a.p50CI[0] < 1.5)
    }
}
