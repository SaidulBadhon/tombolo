// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import LatencyCore

enum Report {
    enum Error: Swift.Error, CustomStringConvertible {
        case missing(String)
        var description: String {
            switch self { case .missing(let p): return "missing \(p)" }
        }
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }

    static func analyzeRun(_ dir: URL) throws {
        let framesURL = dir.appendingPathComponent("frames.csv")
        guard let text = try? String(contentsOf: framesURL, encoding: .utf8) else { throw Error.missing(framesURL.path) }
        let frames = text.split(separator: "\n").dropFirst().compactMap { FrameRecord(csvLine: String($0)) }
        let syncText = (try? String(contentsOf: dir.appendingPathComponent("sync.jsonl"), encoding: .utf8)) ?? ""
        let sessions = SyncLog.parse(syncText)
        let (report, samples) = SoftwareAnalysis.run(frames: frames, sessions: sessions)

        var csv = "kind,session,ticks,source_ms,source_mac_ms,capture_ns,frame,latency_ms\n"
        for s in samples {
            csv += "\(CodeKind(rawValue: s.kindRaw)?.description ?? "\(s.kindRaw)"),\(s.session),\(s.ticks),"
            csv += String(format: "%.4f,%.4f,", s.sourceMs, s.sourceMacMs)
            csv += "\(s.captureNs),\(s.frame)," + String(format: "%.4f\n", s.latencyMs)
        }
        try csv.write(to: dir.appendingPathComponent("latency.csv"), atomically: true, encoding: .utf8)
        try encoder().encode(report).write(to: dir.appendingPathComponent("summary.json"))
        let text2 = render(report)
        try text2.write(to: dir.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        print(text2, terminator: "")
        print("wrote \(dir.path)/{latency.csv,summary.json,summary.txt}")
    }

    static func f(_ v: Double, _ d: Int = 2) -> String { v.isFinite ? String(format: "%.\(d)f", v) : "–" }

    static func render(_ r: SoftwareReport) -> String {
        var s = "== software-timestamp mode: render → composited display ==\n"
        s += "frames \(r.framesTotal), decoded \(r.framesDecoded) (\(f(r.decodeRate * 100)) %)\n"
        s += "capture interval median \(f(r.captureIntervalMedianMs)) ms (p99 \(f(r.captureIntervalP99Ms))), "
        s += "SCK delivery delay median \(f(r.deliveryDelayMedianMs)) ms, decode median \(f(r.decodeMicrosMedian, 0)) µs (p99 \(f(r.decodeMicrosP99, 0)))\n"
        for k in r.kinds {
            s += "\n[\(k.kind) tag \(k.sessionTag)\(k.sessionId.map { " session \($0)" } ?? "")]\n"
            s += "  samples (first appearances) \(k.samples), repeats \(k.repeats), negative \(k.negativeSamples), outliers excluded \(k.excludedOutliers)\n"
            s += "  source frame interval median \(f(k.sourceIntervalMedianMs)) ms, source frames not seen \(k.sourceFramesSkipped)\n"
            if let l = k.latencyMs {
                s += "  latency ms: p50 \(f(l.p50))  p95 \(f(l.p95))  p99 \(f(l.p99))   (min \(f(l.min)), max \(f(l.max)), mean \(f(l.mean)) ± sd \(f(l.sd)), n \(l.n))\n"
                s += "  95% bootstrap CI: p50 [\(f(l.p50CI[0])), \(f(l.p50CI[1]))]  p95 [\(f(l.p95CI[0])), \(f(l.p95CI[1]))]  p99 [\(f(l.p99CI[0])), \(f(l.p99CI[1]))]\n"
            }
            if let c = k.clock {
                s += "  clock: Mac−page \(f(c.offsetMs, 3)) ms, drift \(f(c.driftPPM, 1)) ± \(f(c.driftSEPPM, 1)) ppm, RTT min \(f(c.rttMinMs, 3)) / median kept \(f(c.rttMedianKeptMs, 3)) / median all \(f(c.rttMedianAllMs, 3)) ms, \(c.windowsUsed) windows over \(f(c.spanS, 1)) s\n"
            }
            s += "  systematic uncertainty ±\(f(k.systematicUncertaintyMs)) ms (applies to every percentile):\n"
            for n in k.uncertaintyNotes { s += "    - \(n)\n" }
        }
        return s
    }

    static func render(_ r: OpticalReport) -> String {
        var s = "== optical mode: glass-to-glass (first appearance) ==\n"
        s += "frames \(r.frames), nominal fps \(f(r.nominalFps)), fps used \(f(r.fpsUsed))\n"
        s += "frames with phone symbol \(r.framesWithPhone), mirror symbol \(r.framesWithMirror), Mac reference \(r.framesWithMacReference)\n"
        if let m = r.macReferenceMeasuredFps {
            s += "camera fps measured against the Mac clock: \(f(m, 3)) (residual \(f(r.macReferenceResidualMs ?? .nan)) ms)\n"
        }
        s += "samples: used \(r.samplesUsed) (strict \(r.samplesStrict)), all \(r.samplesAll); per-sample uncertainty ±\(f(r.perSampleUncertaintyMs)) ms\n"
        if let l = r.latencyMs {
            s += "latency ms (used): p50 \(f(l.p50))  p95 \(f(l.p95))  p99 \(f(l.p99))   (min \(f(l.min)), max \(f(l.max)), mean \(f(l.mean)) ± sd \(f(l.sd)), n \(l.n))\n"
            s += "  95% bootstrap CI: p50 [\(f(l.p50CI[0])), \(f(l.p50CI[1]))]  p95 [\(f(l.p95CI[0])), \(f(l.p95CI[1]))]  p99 [\(f(l.p99CI[0])), \(f(l.p99CI[1]))]\n"
        }
        if let l = r.latencyStrictMs {
            s += "latency ms (strict): p50 \(f(l.p50))  p95 \(f(l.p95))  p99 \(f(l.p99))  n \(l.n)\n"
        }
        if let l = r.latencyAllMs {
            s += "latency ms (all, uncorrected): p50 \(f(l.p50))  p95 \(f(l.p95))  p99 \(f(l.p99))  n \(l.n)\n"
        }
        if let d = r.displayedDifferenceMs {
            s += "displayed-value difference phone − mirror (coarse): p50 \(f(d.p50))  p95 \(f(d.p95))  n \(d.n)\n"
        }
        for n in r.notes { s += "  - \(n)\n" }
        return s
    }
}
