// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S2: a headless scrcpy-compatible source that stamps the Mac host clock into every frame as a TLC1 symbol
// (kind "mac", tools/latency-harness/Sources/LatencyCore/CodeLayout.swift), encodes it with VideoToolbox H.264 and
// serves it on 127.0.0.1. `s02-mirror --port <printed port>` shows it; `latency-harness capture` on that window then
// measures render → encode → loopback TCP → decode → present → WindowServer composite on the Mac clock alone
// (no clock sync). Usage: s02-loopback-source [WxH=1080x2400] [FPS=60] — prints the port, runs until SIGTERM.
import CoreVideo
import Darwin
import Foundation
import LatencyCore
import MirrorCore

let args = CommandLine.arguments
let size = (args.count > 1 ? args[1] : "1080x2400").lowercased().split(separator: "x").compactMap { Int($0) }
guard size.count == 2 else { fatalError("usage: s02-loopback-source [WxH] [FPS]") }
let fps = args.count > 2 ? Int(args[2]) ?? 60 : 60
let (width, height) = (size[0], size[1])

/// Draws the 36 × 20-module symbol (32 × 16 + 2-module quiet zone) near the top, full contrast, neutral chroma.
func stamp(_ pb: CVPixelBuffer, _ frame: Int64, _ host: UInt64) {
    let m = CodeLayout.modules(for: CodePayload(kind: .macReference, session: 5, ticks: CodeLayout.ticks(fromNanoseconds: host)))
    let q = CodeLayout.quietZoneModules, wm = CodeLayout.widthModules, hm = CodeLayout.heightModules
    let mod = max(4, (width * 8 / 10) / (wm + 2 * q))
    let x0 = (width - (wm + 2 * q) * mod) / 2, y0 = height / 20
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
    let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
    let cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
    let wPx = (wm + 2 * q) * mod, hPx = (hm + 2 * q) * mod
    for r in 0..<hPx {
        let row = y + (y0 + r) * ys + x0
        let my = r / mod - q
        for col in 0..<wPx {
            let mx = col / mod - q
            let black = mx >= 0 && mx < wm && my >= 0 && my < hm && m[my * wm + mx]
            row[col] = black ? 16 : 235
        }
    }
    for r in 0..<(hPx / 2) { memset(c + (y0 / 2 + r) * cs + x0, 128, wPx) }
}

let server: SyntheticScrcpyServer
do {
    server = try SyntheticScrcpyServer(width: width, height: height, fps: fps, expectControl: true, deviceName: "S2 loopback source")
} catch { fatalError("\(error)") }
server.overlay = stamp
print(server.port)
fflush(stdout)
server.serve()
var sources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { server.stop(); exit(0) }
    s.resume()
    sources.append(s)
}
withExtendedLifetime(sources) { dispatchMain() }
