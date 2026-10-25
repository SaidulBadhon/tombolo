// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import LatencyCore

@Suite struct SoftwareAnalysisTests {
    /// Page renders at 60 Hz; each frame first appears on the Mac at the first 120 Hz vsync at
    /// least `latency` after render, and is captured once more one vsync later (a repeat).
    func makeRun(latencyMs: Double, offsetMs: Double, session: UInt32) -> ([FrameRecord], [UInt32: SyncSession]) {
        var frames: [FrameRecord] = []
        let vsync = 1000.0 / 120
        var idx = 0
        for j in 0..<600 {
            let phoneMs = 5000 + Double(j) * 1000 / 60
            let macRender = phoneMs + offsetMs
            let shown = ((macRender + latencyMs) / vsync).rounded(.up) * vsync
            let sym = DecodedSymbol(kindRaw: 0, session: UInt8(session & 0xF), ticks: CodeLayout.ticks(fromMilliseconds: phoneMs),
                                    centreX: 100, centreY: 50, moduleSize: 6, confidence: 0.4)
            for rep in 0..<2 {
                let ns = UInt64(((shown + Double(rep) * vsync) * 1e6).rounded())
                frames.append(FrameRecord(frame: idx, displayNs: ns, arrivalNs: ns + 3_000_000, decodeMicros: 40, fullDetect: false, detections: 1, symbol: sym))
                idx += 1
            }
        }
        var sess = SyncSession(session: session)
        sess.samples = simulate(offsetMs: offsetMs, driftPPM: 0, seconds: 15, rateHz: 4, baseUp: 0.3, baseDown: 0.3, jitterMs: 0.3)
            .map { var s = $0; s.phoneSendMs += 4000; s.phoneRecvMs += 4000; s.macRecvNs += 4_000_000_000; s.macSendNs += 4_000_000_000; return s }
        sess.timerResolutionMs = 0.1
        return (frames, [session: sess])
    }

    @Test func recoversInjectedLatency() throws {
        let (frames, sessions) = makeRun(latencyMs: 30, offsetMs: 45_000_000.25, session: 0xABCD_1237)
        let (report, samples) = SoftwareAnalysis.run(frames: frames, sessions: sessions)
        let k = try #require(report.kinds.first)
        #expect(report.kinds.count == 1)
        #expect(k.samples == 600)
        #expect(k.repeats == 600)
        #expect(k.sessionId == "abcd1237")
        let l = try #require(k.latencyMs)
        // Vsync quantisation adds 0 … 8.33 ms on top of 30 ms.
        #expect(l.min >= 30 - 0.5 && l.max <= 30 + 8.34 + 0.5)
        #expect(abs(k.sourceIntervalMedianMs - 16.667) < 0.1)
        #expect(samples.count == 600)
        #expect(k.systematicUncertaintyMs > 0.1 && k.systematicUncertaintyMs < 1.5)
    }

    @Test func macReferenceNeedsNoSync() throws {
        var frames: [FrameRecord] = []
        for j in 0..<200 {
            let macMs = 1_000_000 + Double(j) * 1000 / 120
            let sym = DecodedSymbol(kindRaw: 1, session: 3, ticks: CodeLayout.ticks(fromMilliseconds: macMs), centreX: 0, centreY: 0, moduleSize: 4, confidence: 0.5)
            let ns = UInt64(((macMs + 12.5) * 1e6).rounded())
            frames.append(FrameRecord(frame: j, displayNs: ns, arrivalNs: ns, decodeMicros: 1, fullDetect: false, detections: 1, symbol: sym))
        }
        let (report, _) = SoftwareAnalysis.run(frames: frames, sessions: [:])
        let l = try #require(report.kinds.first?.latencyMs)
        #expect(abs(l.p50 - 12.5) < 0.06)
    }

    @Test func missingSyncIsReportedNotGuessed() {
        let (frames, _) = makeRun(latencyMs: 30, offsetMs: 10, session: 5)
        let (report, samples) = SoftwareAnalysis.run(frames: frames, sessions: [:])
        #expect(samples.isEmpty)
        #expect(report.kinds.first?.latencyMs == nil)
        #expect(report.kinds.first?.uncertaintyNotes.first?.contains("no clock-sync") == true)
    }

    @Test func csvRoundTrip() {
        let r = FrameRecord(frame: 7, displayNs: 123_456_789_012, arrivalNs: 123_456_799_012, decodeMicros: 55, fullDetect: true, detections: 1,
                            symbol: DecodedSymbol(kindRaw: 0, session: 9, ticks: 4_000_000_000, centreX: 10.5, centreY: 20.25, moduleSize: 6.5, confidence: 0.4))
        let back = FrameRecord(csvLine: r.csvLine)
        #expect(back?.symbol?.ticks == 4_000_000_000)
        #expect(back?.displayNs == r.displayNs)
        let empty = FrameRecord(frame: 1, displayNs: 2, arrivalNs: 3, decodeMicros: 4, fullDetect: false, detections: 0, symbol: nil)
        #expect(FrameRecord(csvLine: empty.csvLine) == empty)
    }

    @Test func syncLogParsing() {
        let text = """
        {"type":"sync","session":4294967295,"samples":[[1.5,2.5,45000000000000,45000000100000],[3,4,5,6]],"server_ns":1}
        {"type":"info","session":4294967295,"info":{"timer_resolution_ms":0.1,"user_agent":"x"}}
        not json
        {"type":"sync","session":12,"samples":[[1,2,3,4]]}
        """
        let s = SyncLog.parse(text)
        #expect(s.count == 2)
        #expect(s[4_294_967_295]?.samples.count == 2)
        #expect(s[4_294_967_295]?.timerResolutionMs == 0.1)
        #expect(s[4_294_967_295]?.samples.first?.macRecvNs == 45_000_000_000_000)
    }
}

/// One synthetic optical clip shared by the optical tests (rendering is the expensive part).
/// 0.6 s at a true 240 fps; no blur here — scripts/optical-synthetic.sh covers blur + H.264.
enum SharedOpticalClip {
    static let latencyMs = 52.0
    static let frames: [OpticalFrame] = {
        var scene = SyntheticOpticalScene()
        scene.latencyMs = latencyMs
        scene.blurRadius = 0
        let dec = CodeDecoder(options: DecoderOptions(expectedSymbols: 3))
        return (0..<144).map { k in OpticalFrame(index: k, symbols: scene.frame(k).withView { dec.decode($0) }.map(DecodedSymbol.init)) }
    }()
}

@Suite struct OpticalAnalysisTests {
    @Test func syntheticSceneRecoversLatencyWithinOneFrame() throws {
        let frames = SharedOpticalClip.frames
        let (report, samples) = OpticalAnalysis.run(frames: frames, nominalFps: 240)
        #expect(report.framesWithPhone > 130, "phone decoded in \(report.framesWithPhone) frames")
        #expect(report.framesWithMirror > 130, "mirror decoded in \(report.framesWithMirror) frames")
        #expect(report.samplesClean >= 20, "clean samples \(report.samplesClean)")
        let l = try #require(report.latencyMs)
        let frame = 1000.0 / 240
        #expect(abs(l.p50 - SharedOpticalClip.latencyMs) <= frame + 0.01, "p50 \(l.p50)")
        for s in samples where s.clean { #expect(abs(s.latencyMs - SharedOpticalClip.latencyMs) <= frame + 0.01) }
        let fps = try #require(report.macReferenceMeasuredFps)
        #expect(abs(fps - 240) < 2.4, "measured fps \(fps)")
    }

    @Test func wrongNominalFpsIsFlagged() {
        // Slow-motion files often carry playback-rate metadata (e.g. 30 fps) instead of 240.
        let frames = SharedOpticalClip.frames
        let (report, _) = OpticalAnalysis.run(frames: frames, nominalFps: 30)
        #expect(report.notes.contains { $0.contains("WARNING") })
        let (fixed, _) = OpticalAnalysis.run(frames: frames, nominalFps: 30, useMacReferenceFps: true)
        #expect(abs(fixed.fpsUsed - 240) < 2.4)
    }
}
