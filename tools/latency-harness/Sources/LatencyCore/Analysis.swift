// SPDX-License-Identifier: GPL-3.0-or-later
//
// Turns raw capture records + clock-sync logs into latency samples and summaries.
//
// Software-timestamp mode ("render → composited display"):
//   sample = Mac composite time of the first captured frame showing a value
//            − Mac-clock equivalent of the phone render time encoded in that value.
// Only the *first* capture of each distinct value is a sample; later captures of the same value
// measure how long a frame stayed on screen, not latency (they are counted as repeats).

import Foundation

// MARK: - Capture records (frames.csv)

public struct FrameRecord: Sendable, Equatable {
    public var frame: Int
    /// Composite/display time reported by ScreenCaptureKit, host-clock nanoseconds.
    public var displayNs: UInt64
    /// Host time when the frame reached our callback.
    public var arrivalNs: UInt64
    public var decodeMicros: Int
    public var fullDetect: Bool
    public var detections: Int
    public var symbol: DecodedSymbol?

    public init(frame: Int, displayNs: UInt64, arrivalNs: UInt64, decodeMicros: Int, fullDetect: Bool, detections: Int, symbol: DecodedSymbol?) {
        self.frame = frame
        self.displayNs = displayNs
        self.arrivalNs = arrivalNs
        self.decodeMicros = decodeMicros
        self.fullDetect = fullDetect
        self.detections = detections
        self.symbol = symbol
    }

    public static let csvHeader = "frame,display_ns,arrival_ns,decode_us,full_detect,n_detections,kind,session,ticks,confidence,module_px,cx,cy"

    public var csvLine: String {
        var s = "\(frame),\(displayNs),\(arrivalNs),\(decodeMicros),\(fullDetect ? 1 : 0),\(detections)"
        if let d = symbol {
            s += ",\(d.kindRaw),\(d.session),\(d.ticks),\(fmt(d.confidence, 3)),\(fmt(d.moduleSize, 2)),\(fmt(d.centreX, 1)),\(fmt(d.centreY, 1))"
        } else {
            s += ",,,,,,,"
        }
        return s
    }

    public init?(csvLine line: String) {
        let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 13, let frame = Int(f[0]), let disp = UInt64(f[1]), let arr = UInt64(f[2]),
              let dus = Int(f[3]), let n = Int(f[5]) else { return nil }
        self.frame = frame
        self.displayNs = disp
        self.arrivalNs = arr
        self.decodeMicros = dus
        self.fullDetect = f[4] == "1"
        self.detections = n
        if let k = UInt8(f[6]), let s = UInt8(f[7]), let t = UInt32(f[8]) {
            symbol = DecodedSymbol(kindRaw: k, session: s, ticks: t, centreX: Double(f[11]) ?? 0, centreY: Double(f[12]) ?? 0,
                                   moduleSize: Double(f[10]) ?? 0, confidence: Double(f[9]) ?? 0)
        } else {
            symbol = nil
        }
    }
}

/// A decoded symbol without the homography (what gets logged).
public struct DecodedSymbol: Sendable, Equatable {
    public var kindRaw: UInt8
    public var session: UInt8
    public var ticks: UInt32
    public var centreX: Double
    public var centreY: Double
    public var moduleSize: Double
    public var confidence: Double

    public init(kindRaw: UInt8, session: UInt8, ticks: UInt32, centreX: Double, centreY: Double, moduleSize: Double, confidence: Double) {
        self.kindRaw = kindRaw
        self.session = session
        self.ticks = ticks
        self.centreX = centreX
        self.centreY = centreY
        self.moduleSize = moduleSize
        self.confidence = confidence
    }

    public init(_ d: Detection) {
        self.init(kindRaw: d.payload.kindRaw, session: d.payload.session, ticks: d.payload.ticks,
                  centreX: d.centreX, centreY: d.centreY, moduleSize: d.moduleSize, confidence: d.confidence)
    }
}

func fmt(_ v: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", v) }

// MARK: - Sync log (sync.jsonl, written by server/serve.py)

public struct SyncSession: Sendable {
    public var session: UInt32
    public var samples: [SyncSample] = []
    /// Page diagnostics posted by the page (user agent, timer resolution, rAF interval, …).
    public var info: [String: String] = [:]
    public var timerResolutionMs: Double?
}

public enum SyncLog {
    /// Parses JSON lines: {"type":"sync","session":N,"samples":[[t0,t3,T1,T2],…]} and
    /// {"type":"info","session":N,"info":{…}}.
    public static func parse(_ text: String) -> [UInt32: SyncSession] {
        var out: [UInt32: SyncSession] = [:]
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sNum = obj["session"] as? NSNumber else { continue }
            let sid = sNum.uint32Value
            var sess = out[sid] ?? SyncSession(session: sid)
            let type = obj["type"] as? String ?? "sync"
            if type == "sync", let arr = obj["samples"] as? [[NSNumber]] {
                for s in arr where s.count >= 4 {
                    sess.samples.append(SyncSample(phoneSendMs: s[0].doubleValue, phoneRecvMs: s[1].doubleValue,
                                                   macRecvNs: s[2].int64Value, macSendNs: s[3].int64Value))
                }
            } else if type == "info", let info = obj["info"] as? [String: Any] {
                for (k, v) in info { sess.info[k] = "\(v)" }
                if let tr = info["timer_resolution_ms"] as? NSNumber { sess.timerResolutionMs = tr.doubleValue }
            }
            out[sid] = sess
        }
        return out
    }
}

// MARK: - Reports

public struct LatencySample: Sendable, Equatable {
    public var kindRaw: UInt8
    public var session: UInt8
    public var ticks: UInt32
    /// Source render time on its own clock (ms).
    public var sourceMs: Double
    /// Source render time mapped to the Mac clock (ms).
    public var sourceMacMs: Double
    public var captureNs: UInt64
    public var frame: Int
    public var latencyMs: Double
}

public struct KindReport: Sendable, Codable {
    public var kind: String
    public var sessionTag: Int
    public var sessionId: String?
    public var samples: Int
    public var repeats: Int
    public var negativeSamples: Int
    public var excludedOutliers: Int
    public var sourceIntervalMedianMs: Double
    public var sourceFramesSkipped: Int
    public var latencyMs: PercentileSummary?
    public var clock: ClockModel?
    public var timerResolutionMs: Double?
    /// Systematic ± applying equally to every sample (clock-sync bound + timer + tick rounding).
    public var systematicUncertaintyMs: Double
    public var uncertaintyNotes: [String]
}

public struct SoftwareReport: Sendable, Codable {
    public var mode = "software-timestamp"
    public var framesTotal: Int
    public var framesDecoded: Int
    public var decodeRate: Double
    public var captureIntervalMedianMs: Double
    public var captureIntervalP99Ms: Double
    public var deliveryDelayMedianMs: Double
    public var decodeMicrosMedian: Double
    public var decodeMicrosP99: Double
    public var kinds: [KindReport]
}

public enum SoftwareAnalysis {
    /// Latencies outside this window are excluded as outliers (and counted): they mean a value was
    /// matched to the wrong session or clock model, not a real latency.
    public static let outlierRangeMs: ClosedRange<Double> = -50...5000

    public static func run(frames: [FrameRecord], sessions: [UInt32: SyncSession]) -> (SoftwareReport, [LatencySample]) {
        let byFrame = Dictionary(grouping: frames, by: \.frame)
        let frameIds = byFrame.keys.sorted()
        let decodedFrames = frameIds.filter { byFrame[$0]!.contains { $0.symbol != nil } }.count
        let disp = frameIds.map { byFrame[$0]![0].displayNs }
        var intervals: [Double] = []
        for i in 1..<max(1, disp.count) where disp[i] > disp[i - 1] { intervals.append(Double(disp[i] - disp[i - 1]) / 1e6) }
        let delivery = frameIds.compactMap { id -> Double? in
            let r = byFrame[id]![0]
            return r.arrivalNs >= r.displayNs ? Double(r.arrivalNs - r.displayNs) / 1e6 : nil
        }
        let decodeUs = frameIds.map { Double(byFrame[$0]![0].decodeMicros) }

        var reports: [KindReport] = []
        var allSamples: [LatencySample] = []
        let symbols = frames.compactMap { r -> (FrameRecord, DecodedSymbol)? in r.symbol.map { (r, $0) } }
        let groups = Dictionary(grouping: symbols) { "\($0.1.kindRaw)-\($0.1.session)" }
        for key in groups.keys.sorted() {
            let g = groups[key]!.sorted { $0.0.displayNs < $1.0.displayNs }
            let kindRaw = g[0].1.kindRaw, tag = g[0].1.session
            guard let kind = CodeKind(rawValue: kindRaw), kind != .synthetic else { continue }

            // Pick the clock model.
            var model: ClockModel?
            var sessionId: UInt32?
            var timerRes: Double?
            if kind == .page {
                let candidates = sessions.values.filter { UInt8($0.session & 0xF) == tag }
                var best: (Double, ClockModel, SyncSession)?
                for c in candidates {
                    guard let m = ClockSync.estimate(c.samples) else { continue }
                    // Score: median |latency| implied for the first few frames.
                    let probe = g.prefix(50).map { item -> Double in
                        let capMs = Double(item.0.displayNs) / 1e6
                        let src = CodeLayout.unwrap(ticks: item.1.ticks, near: m.phoneMs(fromMacMs: capMs) * 10) / 10
                        return abs(capMs - m.macMs(fromPhoneMs: src))
                    }
                    let score = Stats.median(probe)
                    if best == nil || score < best!.0 { best = (score, m, c) }
                }
                guard let b = best else {
                    reports.append(KindReport(kind: kind.description, sessionTag: Int(tag), sessionId: nil, samples: 0, repeats: g.count,
                                              negativeSamples: 0, excludedOutliers: 0, sourceIntervalMedianMs: .nan, sourceFramesSkipped: 0,
                                              latencyMs: nil, clock: nil, timerResolutionMs: nil, systematicUncertaintyMs: .nan,
                                              uncertaintyNotes: ["no clock-sync samples for session tag \(tag): is sync.jsonl in the run directory?"]))
                    continue
                }
                model = b.1
                sessionId = b.2.session
                timerRes = b.2.timerResolutionMs
            }

            // First appearance per value.
            var seen: [UInt32: LatencySample] = [:]
            var order: [UInt32] = []
            var repeats = 0
            for (rec, sym) in g {
                if seen[sym.ticks] != nil { repeats += 1; continue }
                let capMs = Double(rec.displayNs) / 1e6
                let srcMs: Double, srcMacMs: Double
                if let m = model {
                    srcMs = CodeLayout.unwrap(ticks: sym.ticks, near: m.phoneMs(fromMacMs: capMs) * 10) / 10
                    srcMacMs = m.macMs(fromPhoneMs: srcMs)
                } else {
                    srcMs = CodeLayout.unwrap(ticks: sym.ticks, near: capMs * 10) / 10
                    srcMacMs = srcMs
                }
                seen[sym.ticks] = LatencySample(kindRaw: kindRaw, session: tag, ticks: sym.ticks, sourceMs: srcMs, sourceMacMs: srcMacMs,
                                                captureNs: rec.displayNs, frame: rec.frame, latencyMs: capMs - srcMacMs)
                order.append(sym.ticks)
            }
            var samples = order.map { seen[$0]! }
            let excluded = samples.filter { !outlierRangeMs.contains($0.latencyMs) }.count
            samples = samples.filter { outlierRangeMs.contains($0.latencyMs) }
            // Source frame pacing (distinct values in source order).
            let src = samples.map(\.sourceMs).sorted()
            var srcIntervals: [Double] = []
            for i in 1..<max(1, src.count) { srcIntervals.append(src[i] - src[i - 1]) }
            let srcMedian = srcIntervals.isEmpty ? Double.nan : Stats.median(srcIntervals)
            let skipped = srcIntervals.filter { $0 > 1.5 * srcMedian }.count

            var notes: [String] = []
            var systematic = 0.05  // tick rounding (100 µs ticks)
            notes.append("tick rounding ±0.05 ms")
            if let m = model {
                systematic += m.boundMs
                notes.append(String(format: "clock sync ±%.2f ms (median kept RTT/2; residual %.2f ms rms, drift %.1f ppm%@)",
                                    m.boundMs, m.residualMs, m.driftPPM, m.fittedDrift ? "" : ", not fitted: run too short"))
                if let t = timerRes {
                    systematic += t / 2
                    notes.append(String(format: "page timer resolution %.3f ms → ±%.3f ms", t, t / 2))
                }
            } else {
                notes.append("same clock as the capture (no clock sync needed)")
            }
            notes.append("capture time = ScreenCaptureKit display time of the composited frame (vsync-quantised; a frame skipped by the capture delays first appearance by one capture interval)")
            reports.append(KindReport(
                kind: kind.description, sessionTag: Int(tag), sessionId: sessionId.map { String(format: "%08x", $0) },
                samples: samples.count, repeats: repeats, negativeSamples: samples.filter { $0.latencyMs < 0 }.count,
                excludedOutliers: excluded, sourceIntervalMedianMs: srcMedian, sourceFramesSkipped: skipped,
                latencyMs: Stats.summarize(samples.map(\.latencyMs)), clock: model, timerResolutionMs: timerRes,
                systematicUncertaintyMs: systematic, uncertaintyNotes: notes))
            allSamples += samples
        }
        let report = SoftwareReport(
            framesTotal: frameIds.count, framesDecoded: decodedFrames,
            decodeRate: frameIds.isEmpty ? 0 : Double(decodedFrames) / Double(frameIds.count),
            captureIntervalMedianMs: intervals.isEmpty ? .nan : Stats.median(intervals),
            captureIntervalP99Ms: intervals.isEmpty ? .nan : Stats.percentile(intervals, 99),
            deliveryDelayMedianMs: delivery.isEmpty ? .nan : Stats.median(delivery),
            decodeMicrosMedian: decodeUs.isEmpty ? .nan : Stats.median(decodeUs),
            decodeMicrosP99: decodeUs.isEmpty ? .nan : Stats.percentile(decodeUs, 99),
            kinds: reports)
        return (report, allSamples)
    }
}

// MARK: - Optical mode

public struct OpticalFrame: Sendable {
    public var index: Int
    public var symbols: [DecodedSymbol]
    /// Optional role per symbol (e.g. from regions of interest); nil = assign automatically.
    public var roles: [OpticalAnalysis.Track]?
    public init(index: Int, symbols: [DecodedSymbol], roles: [OpticalAnalysis.Track]? = nil) {
        self.index = index
        self.symbols = symbols
        self.roles = roles
    }
}

public struct OpticalReport: Sendable, Codable {
    public var mode = "optical"
    public var frames: Int
    public var nominalFps: Double
    public var fpsUsed: Double
    public var framesWithPhone: Int
    public var framesWithMirror: Int
    public var framesWithMacReference: Int
    public var phoneTrackCentre: [Double]?
    public var mirrorTrackCentre: [Double]?
    /// Camera fps measured against the Mac reference clock (first appearances of Mac values).
    public var macReferenceMeasuredFps: Double?
    public var macReferenceResidualMs: Double?
    /// Both first appearances directly follow a frame that decoded with an older value.
    public var samplesStrict: Int
    /// Strict samples plus those where one undecodable transition frame preceded a first
    /// appearance (that frame is taken as the first appearance).
    public var samplesUsed: Int
    /// Every value seen on both tracks, first decoded frame, no correction.
    public var samplesAll: Int
    /// Glass-to-glass latency from the used samples (the headline numbers).
    public var latencyMs: PercentileSummary?
    public var latencyStrictMs: PercentileSummary?
    public var latencyAllMs: PercentileSummary?
    /// Per-frame (phone − mirror) displayed-value difference: coarse cross-check, quantised to the
    /// phone frame interval.
    public var displayedDifferenceMs: PercentileSummary?
    public var perSampleUncertaintyMs: Double
    public var notes: [String]
}

public struct OpticalSample: Sendable, Equatable {
    public var ticks: UInt32
    /// Estimated first-appearance frames (after the transition-frame rule).
    public var phoneFrame: Int
    public var mirrorFrame: Int
    /// Undecodable frames between the last older value and the first decode of this value
    /// (−1 = no older value seen before it).
    public var phoneGap: Int
    public var mirrorGap: Int
    public var latencyMs: Double
    /// Latency from the first *decoded* frames, without the transition-frame rule.
    public var rawLatencyMs: Double

    public var strict: Bool { phoneGap == 0 && mirrorGap == 0 }
    public var used: Bool { (0...1).contains(phoneGap) && (0...1).contains(mirrorGap) }
}

public enum OpticalAnalysis {
    public enum Track: Sendable { case phone, mirror, macReference, ignore }

    /// - Parameters:
    ///   - frames: decoded symbols per camera frame. When frames carry `roles` (from regions of
    ///     interest) those decide phone vs mirror; otherwise the two page-kind tracks are separated
    ///     by position and the one showing newer values is the phone glass.
    ///   - useMacReferenceFps: convert frame counts with the fps measured against the Mac clock.
    public static func run(frames: [OpticalFrame], nominalFps: Double, useMacReferenceFps: Bool = false) -> (OpticalReport, [OpticalSample]) {
        var notes: [String] = []
        let explicitRoles = frames.contains { $0.roles != nil }
        // 1. Assign page-kind symbols to two tracks.
        let pageSyms = frames.flatMap { f in f.symbols.filter { $0.kindRaw == CodeKind.page.rawValue }.map { (f.index, $0) } }
        var assign: (DecodedSymbol, Track?) -> Int  // 0 = phone, 1 = mirror, -1 = ignore
        var centres: [(Double, Double)] = []
        if explicitRoles {
            assign = { _, role in role == .phone ? 0 : (role == .mirror ? 1 : -1) }
        } else {
            let medModule = Stats.median(pageSyms.map(\.1.moduleSize))
            centres = twoMeans(pageSyms.map { ($0.1.centreX, $0.1.centreY) }, minSeparation: 16 * (medModule.isNaN ? 1 : medModule))
            if centres.count < 2 { notes.append("only one page-kind symbol position found: film the phone and the mirror window together") }
            let cs = centres
            assign = { s, _ in
                guard cs.count == 2 else { return 0 }
                let d0 = (s.centreX - cs[0].0) * (s.centreX - cs[0].0) + (s.centreY - cs[0].1) * (s.centreY - cs[0].1)
                let d1 = (s.centreX - cs[1].0) * (s.centreX - cs[1].0) + (s.centreY - cs[1].1) * (s.centreY - cs[1].1)
                return d0 <= d1 ? 0 : 1
            }
        }
        // Per frame, per track value (unwrapped ticks).
        var track: [[Int: Double]] = [[:], [:]]
        var unwrapRef: Double?
        for f in frames {
            for (i, s) in f.symbols.enumerated() where s.kindRaw == CodeKind.page.rawValue {
                let t = assign(s, f.roles?[i])
                guard t == 0 || t == 1 else { continue }
                let u = CodeLayout.unwrap(ticks: s.ticks, near: unwrapRef ?? Double(s.ticks))
                unwrapRef = u
                track[t][f.index] = u
            }
        }
        if !explicitRoles, centres.count == 2 {
            // The phone glass shows newer values than the mirror.
            var newer0 = 0, newer1 = 0
            for (i, a) in track[0] { if let b = track[1][i] { if a > b { newer0 += 1 } else if b > a { newer1 += 1 } } }
            if newer1 > newer0 {
                track.swapAt(0, 1)
                centres.swapAt(0, 1)
            }
            notes.append("tracks separated by position; phone = track showing newer values (\(max(newer0, newer1)) vs \(min(newer0, newer1)) frames)")
        }

        // 2. Mac reference: camera fps against the Mac clock.
        var macFirst: [(frame: Double, ms: Double)] = []
        var macSeen = Set<UInt32>()
        var macFrames = 0
        var macRef: Double?
        for f in frames {
            var had = false
            for s in f.symbols where s.kindRaw == CodeKind.macReference.rawValue {
                had = true
                if macSeen.insert(s.ticks).inserted {
                    let u = CodeLayout.unwrap(ticks: s.ticks, near: macRef ?? Double(s.ticks))
                    macRef = u
                    macFirst.append((Double(f.index), u / 10))
                }
            }
            if had { macFrames += 1 }
        }
        var measuredFps: Double?
        var macResidual: Double?
        if macFirst.count >= 10 {
            // frame = α + β·ms → fps = 1000·β
            let xs = macFirst.map(\.ms), ys = macFirst.map(\.frame)
            let mx = Stats.mean(xs), my = Stats.mean(ys)
            var sxy = 0.0, sxx = 0.0
            for i in xs.indices { sxy += (xs[i] - mx) * (ys[i] - my); sxx += (xs[i] - mx) * (xs[i] - mx) }
            if sxx > 0 {
                let beta = sxy / sxx
                measuredFps = beta * 1000
                var ss = 0.0
                for i in xs.indices { let r = ys[i] - (my + beta * (xs[i] - mx)); ss += r * r }
                macResidual = (ss / Double(xs.count)).squareRoot() / beta  // frames → ms
                if abs(beta * 1000 / nominalFps - 1) > 0.01 {
                    notes.append(String(format: "WARNING: camera fps measured against the Mac clock (%.2f) differs from nominal (%.2f) by more than 1%%", beta * 1000, nominalFps))
                }
            }
        }
        let fps = (useMacReferenceFps ? measuredFps : nil) ?? nominalFps

        // 3. First appearances. A display changes value over a few milliseconds (pixel response),
        // so the camera frame exposed during the change often decodes as neither value. When
        // exactly one undecodable frame separates the last older value from the first decode of a
        // new value, that frame is the first (partial) appearance. Without this rule a camera
        // whose rate is a multiple of the display refresh can phase-lock and bias one track by a
        // whole frame.
        func firsts(_ t: [Int: Double]) -> [Double: (frame: Int, decoded: Int, gap: Int)] {
            var out: [Double: (Int, Int, Int)] = [:]
            var last: (index: Int, value: Double)?
            for i in t.keys.sorted() {
                let v = t[i]!
                if out[v] == nil {
                    if let l = last, l.value < v {
                        let gap = i - l.index - 1
                        out[v] = (gap == 1 ? i - 1 : i, i, gap)
                    } else {
                        out[v] = (i, i, -1)
                    }
                }
                if last == nil || v >= last!.value { last = (i, v) }
            }
            return out
        }
        let fp = firsts(track[0]), fm = firsts(track[1])
        var samples: [OpticalSample] = []
        for (v, m) in fm {
            guard let p = fp[v], m.frame >= p.frame else { continue }
            samples.append(OpticalSample(ticks: UInt32(truncatingIfNeeded: Int64(v)), phoneFrame: p.frame, mirrorFrame: m.frame,
                                         phoneGap: p.gap, mirrorGap: m.gap,
                                         latencyMs: Double(m.frame - p.frame) / fps * 1000,
                                         rawLatencyMs: Double(m.decoded - p.decoded) / fps * 1000))
        }
        samples.sort { $0.phoneFrame < $1.phoneFrame }
        var diffs: [Double] = []
        for (i, a) in track[0] { if let b = track[1][i] { diffs.append((a - b) / 10) } }
        notes.append(String(format: "each sample is quantised to camera frames: ±%.2f ms (one frame at %.2f fps)", 1000 / fps, fps))
        notes.append("used = strict samples + samples where one undecodable transition frame preceded a first appearance (counted as the appearance); strict = no such frame on either track; all = first decoded frames, uncorrected")
        let report = OpticalReport(
            frames: frames.count, nominalFps: nominalFps, fpsUsed: fps,
            framesWithPhone: track[0].count, framesWithMirror: track[1].count, framesWithMacReference: macFrames,
            phoneTrackCentre: centres.count == 2 ? [centres[0].0, centres[0].1] : nil,
            mirrorTrackCentre: centres.count == 2 ? [centres[1].0, centres[1].1] : nil,
            macReferenceMeasuredFps: measuredFps, macReferenceResidualMs: macResidual,
            samplesStrict: samples.filter(\.strict).count, samplesUsed: samples.filter(\.used).count, samplesAll: samples.count,
            latencyMs: Stats.summarize(samples.filter(\.used).map(\.latencyMs)),
            latencyStrictMs: Stats.summarize(samples.filter(\.strict).map(\.latencyMs)),
            latencyAllMs: Stats.summarize(samples.map(\.rawLatencyMs)),
            displayedDifferenceMs: Stats.summarize(diffs),
            perSampleUncertaintyMs: 1000 / fps, notes: notes)
        return (report, samples)
    }

    /// 2-means on points; returns two centres, or one if the points do not separate.
    static func twoMeans(_ pts: [(Double, Double)], minSeparation: Double) -> [(Double, Double)] {
        guard let first = pts.first else { return [] }
        func d2(_ a: (Double, Double), _ b: (Double, Double)) -> Double { (a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) }
        var c0 = first
        var c1 = pts.max { d2($0, first) < d2($1, first) }!
        c0 = pts.max { d2($0, c1) < d2($1, c1) }!
        for _ in 0..<20 {
            var s0 = (0.0, 0.0, 0.0), s1 = (0.0, 0.0, 0.0)
            for p in pts {
                if d2(p, c0) <= d2(p, c1) { s0 = (s0.0 + p.0, s0.1 + p.1, s0.2 + 1) } else { s1 = (s1.0 + p.0, s1.1 + p.1, s1.2 + 1) }
            }
            guard s0.2 > 0, s1.2 > 0 else { return [c0] }
            c0 = (s0.0 / s0.2, s0.1 / s0.2)
            c1 = (s1.0 / s1.2, s1.1 / s1.2)
        }
        return d2(c0, c1) < minSeparation * minSeparation ? [c0] : [c0, c1]
    }
}
