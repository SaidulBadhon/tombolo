// SPDX-License-Identifier: GPL-3.0-or-later
//
// latency-harness — Tombolo S1 latency harness CLI.

import Foundation
import LatencyCore

let usage = """
usage: latency-harness <command> [options]

Software-timestamp mode (no camera):
  list-windows                         list capturable on-screen windows
  capture   --run-dir DIR (--window TEXT | --window-id N | --rect X,Y,W,H)
            [--duration S=30] [--source display|window] [--scale F=1] [--expect N=1]
            [--save-failures N=5] [--no-analyze]
                                       capture a window/region with ScreenCaptureKit, decode every
                                       frame → DIR/frames.csv, then run `analyze`
  analyze   --run-dir DIR              frames.csv + sync.jsonl → latency.csv, summary.json, report
  mac-code  [--duration S] [--at X,Y] [--size W,H]
                                       window showing the Mac host clock as a TLC1 symbol

Optical mode (high-speed camera):
  optical   --video FILE [--fps N] [--scale F=1] [--out DIR] [--max-frames N]
            [--use-mac-fps] [--roi-phone X,Y,W,H --roi-mirror X,Y,W,H [--roi-mac X,Y,W,H]]
                                       decode phone, mirror and Mac-reference symbols in every
                                       frame (ffmpeg) and compute first-appearance latencies

Utilities:
  decode-image FILE…                   decode symbols in still images (PNG/JPEG/…)
  encode-image --out FILE [--kind page|mac|synthetic] [--session N] [--ms T] [--module PX]
  synth-video [--seconds S=2] [--fps N=240] [--latency-ms L=45] [--width W] [--height H]
                                       raw 8-bit grey frames of a synthetic optical scene on stdout
"""

struct Args {
    var items: [String]
    init(_ items: [String]) { self.items = items }

    func value(_ name: String) -> String? {
        guard let i = items.firstIndex(of: name), i + 1 < items.count else { return nil }
        return items[i + 1]
    }
    func double(_ name: String) -> Double? { value(name).flatMap(Double.init) }
    func int(_ name: String) -> Int? { value(name).flatMap(Int.init) }
    func flag(_ name: String) -> Bool { items.contains(name) }
    func numbers(_ name: String) -> [Double]? {
        guard let v = value(name) else { return nil }
        let parts = v.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return parts.isEmpty ? nil : parts
    }
    /// Positional arguments (not options or option values).
    var positionals: [String] {
        var out: [String] = []
        var skip = false
        for (i, a) in items.enumerated() {
            if skip { skip = false; continue }
            if a.hasPrefix("--") {
                if i + 1 < items.count, !items[i + 1].hasPrefix("--"), !["--no-analyze", "--use-mac-fps"].contains(a) { skip = true }
                continue
            }
            out.append(a)
        }
        return out
    }
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("error: " + msg + "\n").data(using: .utf8)!)
    exit(2)
}

func runAsync(_ body: @escaping @Sendable () async throws -> Void) -> Never {
    Task {
        do { try await body(); exit(0) } catch { fail("\(error)") }
    }
    dispatchMain()
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else { print(usage); exit(1) }
let args = Args(Array(argv.dropFirst()))

switch command {
case "list-windows":
    runAsync { try await Capture.listWindows() }
case "capture":
    guard let dir = args.value("--run-dir") else { fail("--run-dir is required") }
    let opts = Capture.Options(
        runDir: URL(fileURLWithPath: dir),
        windowQuery: args.value("--window"), windowID: args.int("--window-id").map(UInt32.init),
        rect: args.numbers("--rect"), duration: args.double("--duration") ?? 30,
        sourceIsWindow: args.value("--source") == "window", scale: args.double("--scale") ?? 1,
        expectedSymbols: args.int("--expect") ?? 1, saveFailures: args.int("--save-failures") ?? 5,
        analyze: !args.flag("--no-analyze"))
    runAsync { try await Capture.run(opts) }
case "analyze":
    guard let dir = args.value("--run-dir") else { fail("--run-dir is required") }
    do { try Report.analyzeRun(URL(fileURLWithPath: dir)) } catch { fail("\(error)") }
case "mac-code":
    MacCodeWindow.run(duration: args.double("--duration"), at: args.numbers("--at"), size: args.numbers("--size"))
case "optical":
    guard let video = args.value("--video") else { fail("--video is required") }
    do {
        try Optical.run(Optical.Options(
            video: video, fps: args.double("--fps"), scale: args.double("--scale") ?? 1,
            out: args.value("--out"), maxFrames: args.int("--max-frames"), useMacFps: args.flag("--use-mac-fps"),
            roiPhone: args.numbers("--roi-phone"), roiMirror: args.numbers("--roi-mirror"), roiMac: args.numbers("--roi-mac")))
    } catch { fail("\(error)") }
case "decode-image":
    let files = args.positionals
    guard !files.isEmpty else { fail("give one or more image files") }
    var anyFound = false
    for f in files {
        do {
            let img = try ImageFiles.load(f)
            let dets = img.withView { CodeReader.detect($0, options: DecoderOptions(expectedSymbols: 4)) }
            if dets.isEmpty { print("\(f): no symbol") }
            for d in dets {
                anyFound = true
                print(String(format: "%@: kind=%@ session=%d ticks=%u (%.1f ms) centre=(%.1f,%.1f) module=%.2f px confidence=%.3f contrast=%.0f",
                             f, d.payload.kind?.description ?? "\(d.payload.kindRaw)", d.payload.session, d.payload.ticks,
                             Double(d.payload.ticks) / 10, d.centreX, d.centreY, d.moduleSize, d.confidence, d.contrast))
            }
        } catch { print("\(f): \(error)") }
    }
    exit(anyFound ? 0 : 1)
case "encode-image":
    guard let out = args.value("--out") else { fail("--out is required") }
    let kind: CodeKind = ["mac": .macReference, "synthetic": .synthetic][args.value("--kind") ?? "page"] ?? .page
    let p = CodePayload(kind: kind, session: UInt8(args.int("--session") ?? 0),
                        ticks: CodeLayout.ticks(fromMilliseconds: args.double("--ms") ?? 12345.6))
    let img = CodeRenderer.render(p, moduleSize: args.int("--module") ?? 8)
    do { try ImageFiles.savePNG(img, to: out) } catch { fail("\(error)") }
    print("wrote \(out): kind=\(kind) session=\(p.session) ticks=\(p.ticks) (\(img.width)×\(img.height) px)")
case "synth-video":
    var scene = SyntheticOpticalScene()
    scene.cameraFps = args.double("--fps") ?? 240
    scene.latencyMs = args.double("--latency-ms") ?? 45
    if let w = args.int("--width") { scene.width = w }
    if let h = args.int("--height") { scene.height = h }
    let n = Int((args.double("--seconds") ?? 2) * scene.cameraFps)
    FileHandle.standardError.write("synth-video: \(n) frames \(scene.width)x\(scene.height) gray @ \(scene.cameraFps) fps, injected latency \(scene.latencyMs) ms\n".data(using: .utf8)!)
    for k in 0..<n {
        FileHandle.standardOutput.write(Data(scene.frame(k).pixels))
    }
case "-h", "--help", "help":
    print(usage)
default:
    print(usage)
    exit(1)
}
