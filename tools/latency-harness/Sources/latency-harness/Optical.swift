// SPDX-License-Identifier: GPL-3.0-or-later
//
// Optical mode: decode a high-speed camera video that shows the phone screen, the Mac mirror
// window and (optionally) the Mac reference window.
//
// ffprobe reads the stream geometry and nominal frame rate; ffmpeg decodes to raw 8-bit grey
// frames on a pipe (no autorotation — the decoder is rotation-invariant); every frame is decoded
// with frame-to-frame tracking. Latency per phone frame = (first camera frame showing the value
// on the Mac mirror − first camera frame showing it on the phone glass) / fps, ± one camera frame.

import Foundation
import LatencyCore

enum Optical {
    struct Options {
        var video: String
        var fps: Double?
        var scale: Double
        var out: String?
        var maxFrames: Int?
        var useMacFps: Bool
        var roiPhone: [Double]?
        var roiMirror: [Double]?
        var roiMac: [Double]?
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case tool(String), probe(String)
        var description: String {
            switch self {
            case .tool(let s): return "cannot run \(s) (is ffmpeg installed and on PATH?)"
            case .probe(let s): return "ffprobe: \(s)"
            }
        }
    }

    static func which(_ name: String) -> String? {
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") + ["/opt/homebrew/bin", "/usr/local/bin"] {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func probe(_ video: String) throws -> (w: Int, h: Int, fps: Double) {
        guard let ffprobe = which("ffprobe") else { throw Error.tool("ffprobe") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height,avg_frame_rate,r_frame_rate",
                       "-of", "json", video]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = (obj["streams"] as? [[String: Any]])?.first,
              let w = s["width"] as? Int, let h = s["height"] as? Int else { throw Error.probe("no video stream in \(video)") }
        func rate(_ v: Any?) -> Double? {
            guard let str = v as? String else { return nil }
            let parts = str.split(separator: "/").compactMap { Double($0) }
            guard parts.count == 2, parts[1] != 0, parts[0] > 0 else { return nil }
            return parts[0] / parts[1]
        }
        return (w, h, rate(s["r_frame_rate"]) ?? rate(s["avg_frame_rate"]) ?? 0)
    }

    struct ROI {
        var role: OpticalAnalysis.Track
        var x: Int, y: Int, w: Int, h: Int
        var decoder: CodeDecoder
    }

    static func run(_ o: Options) throws {
        let info = try probe(o.video)
        let fps = o.fps ?? info.fps
        guard fps > 0 else { throw Error.probe("unknown frame rate; pass --fps") }
        // Output size (even numbers).
        let w = max(2, Int(Double(info.w) * o.scale / 2) * 2), h = max(2, Int(Double(info.h) * o.scale / 2) * 2)
        guard let ffmpeg = which("ffmpeg") else { throw Error.tool("ffmpeg") }
        let outDir = URL(fileURLWithPath: o.out ?? (o.video as NSString).deletingPathExtension + "-optical")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        var a = ["-v", "error", "-noautorotate", "-i", o.video, "-map", "0:v:0", "-fps_mode", "passthrough"]
        if w != info.w || h != info.h { a += ["-vf", "scale=\(w):\(h):flags=area"] }
        a += ["-f", "rawvideo", "-pix_fmt", "gray", "-"]
        p.arguments = a
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        print("optical: \(o.video) \(info.w)×\(info.h) → \(w)×\(h) grey, \(String(format: "%.3f", fps)) fps\(o.fps != nil ? " (from --fps)" : " (from ffprobe)")")

        var rois: [ROI] = []
        func addROI(_ r: [Double]?, _ role: OpticalAnalysis.Track) {
            guard let r, r.count == 4 else { return }
            rois.append(ROI(role: role, x: Int(r[0]), y: Int(r[1]), w: Int(r[2]), h: Int(r[3]), decoder: CodeDecoder(options: DecoderOptions(expectedSymbols: 1))))
        }
        addROI(o.roiPhone, .phone)
        addROI(o.roiMirror, .mirror)
        addROI(o.roiMac, .macReference)
        let fullDecoder = CodeDecoder(options: DecoderOptions(expectedSymbols: o.roiMac == nil ? 3 : 2))

        let frameBytes = w * h
        let reader = pipe.fileHandleForReading
        var frames: [OpticalFrame] = []
        var csv = "frame,t_ms,kind,session,ticks,cx,cy,module_px,confidence,role\n"
        var index = 0
        var buf = Data(capacity: frameBytes)
        let started = Date()
        while o.maxFrames.map({ index < $0 }) ?? true {
            buf.removeAll(keepingCapacity: true)
            while buf.count < frameBytes {
                let chunk = reader.readData(ofLength: frameBytes - buf.count)
                if chunk.isEmpty { break }
                buf.append(chunk)
            }
            guard buf.count == frameBytes else { break }
            let img = GrayImage(width: w, height: h, pixels: [UInt8](buf))
            var syms: [(DecodedSymbol, String)] = []
            var roles: [OpticalAnalysis.Track] = []
            if rois.isEmpty {
                for d in img.withView({ fullDecoder.decode($0) }) { syms.append((DecodedSymbol(d), "auto")) }
            } else {
                for r in rois {
                    let crop = img.cropped(x: r.x, y: r.y, width: r.w, height: r.h)
                    for d in crop.withView({ r.decoder.decode($0) }) {
                        var s = DecodedSymbol(d)
                        s.centreX += Double(r.x)
                        s.centreY += Double(r.y)
                        let roleName = r.role == .phone ? "phone" : (r.role == .mirror ? "mirror" : "mac")
                        roles.append(r.role)
                        syms.append((s, roleName))
                    }
                }
            }
            for (s, role) in syms {
                csv += "\(index),\(String(format: "%.3f", Double(index) / fps * 1000)),\(s.kindRaw),\(s.session),\(s.ticks),"
                csv += String(format: "%.1f,%.1f,%.2f,%.3f,", s.centreX, s.centreY, s.moduleSize, s.confidence) + role + "\n"
            }
            if syms.isEmpty { csv += "\(index),\(String(format: "%.3f", Double(index) / fps * 1000)),,,,,,,,\n" }
            frames.append(OpticalFrame(index: index, symbols: syms.map(\.0), roles: rois.isEmpty ? nil : roles))
            index += 1
            if index % 500 == 0 { print("  \(index) frames (\(String(format: "%.0f", Double(index) / Date().timeIntervalSince(started))) fps)") }
        }
        p.terminate()
        p.waitUntilExit()
        try csv.write(to: outDir.appendingPathComponent("frames.csv"), atomically: true, encoding: .utf8)

        let (report, samples) = OpticalAnalysis.run(frames: frames, nominalFps: fps, useMacReferenceFps: o.useMacFps)
        var sc = "ticks,phone_frame,mirror_frame,clean,latency_ms\n"
        for s in samples { sc += "\(s.ticks),\(s.phoneFrame),\(s.mirrorFrame),\(s.clean ? 1 : 0),\(String(format: "%.3f", s.latencyMs))\n" }
        try sc.write(to: outDir.appendingPathComponent("latency.csv"), atomically: true, encoding: .utf8)
        try Report.encoder().encode(report).write(to: outDir.appendingPathComponent("summary.json"))
        let text = Report.render(report)
        try text.write(to: outDir.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        print(text, terminator: "")
        print("wrote \(outDir.path)/{frames.csv,latency.csv,summary.json,summary.txt}")
    }
}
