// SPDX-License-Identifier: GPL-3.0-or-later
//
// ScreenCaptureKit capture + per-frame decoding.
//
// Timestamps: each frame's SCStreamFrameInfo.displayTime (mach_absolute_time of the composited
// display frame) is converted to nanoseconds — the same clock as the page server's
// CLOCK_UPTIME_RAW and CADisplayLink timestamps.
//
// Needs the Screen Recording permission for the app that runs this binary (Terminal, iTerm, …):
// System Settings › Privacy & Security › Screen & System Audio Recording.

import AppKit
import CoreMedia
import CoreVideo
import Foundation
import LatencyCore
import ScreenCaptureKit

let timebase: mach_timebase_info_data_t = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return tb
}()

@inline(__always) func machToNs(_ t: UInt64) -> UInt64 {
    t / UInt64(timebase.denom) * UInt64(timebase.numer) + (t % UInt64(timebase.denom)) * UInt64(timebase.numer) / UInt64(timebase.denom)
}

@inline(__always) func hostNs() -> UInt64 { machToNs(mach_absolute_time()) }

final class CaptureSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let decoder: CodeDecoder
    private let out: FileHandle
    private let runDir: URL
    private var frame = 0
    private var savedFailures = 0
    private let maxSavedFailures: Int
    private let lock = NSLock()
    private(set) var framesSeen = 0
    private(set) var framesDecoded = 0
    private(set) var stopError: Swift.Error?
    private var buffer = ""

    init(runDir: URL, expectedSymbols: Int, saveFailures: Int) throws {
        self.runDir = runDir
        self.maxSavedFailures = saveFailures
        decoder = CodeDecoder(options: DecoderOptions(expectedSymbols: expectedSymbols, rowStep: 1, tryAdaptive: false))
        let path = runDir.appendingPathComponent("frames.csv")
        FileManager.default.createFile(atPath: path.path, contents: (FrameRecord.csvHeader + "\n").data(using: .utf8))
        out = try FileHandle(forWritingTo: path)
        out.seekToEndOfFile()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid else { return }
        let arrival = hostNs()
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = atts.first,
              let statusRaw = info[.status] as? Int, let status = SCFrameStatus(rawValue: statusRaw), status == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let displayNs: UInt64
        if let dt = info[.displayTime] as? UInt64 {
            displayNs = machToNs(dt)
        } else {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            displayNs = UInt64(max(0, CMTimeGetSeconds(pts)) * 1e9)
        }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
        let view = GrayView(base: UnsafePointer(base.assumingMemoryBound(to: UInt8.self)),
                            width: CVPixelBufferGetWidthOfPlane(pb, 0), height: CVPixelBufferGetHeightOfPlane(pb, 0),
                            stride: CVPixelBufferGetBytesPerRowOfPlane(pb, 0))
        let t0 = hostNs()
        let dets = decoder.decode(view)
        let us = Int((hostNs() - t0) / 1000)

        lock.lock()
        defer { lock.unlock() }
        framesSeen += 1
        if !dets.isEmpty { framesDecoded += 1 }
        let full = decoder.lastUsedFullDetection
        if dets.isEmpty {
            buffer += FrameRecord(frame: frame, displayNs: displayNs, arrivalNs: arrival, decodeMicros: us, fullDetect: full,
                                  detections: 0, symbol: nil).csvLine + "\n"
            if savedFailures < maxSavedFailures {
                savedFailures += 1
                let img = GrayImage(copying: view)
                try? ImageFiles.savePNG(img, to: runDir.appendingPathComponent("failed-frame-\(frame).png").path)
            }
        }
        for d in dets {
            buffer += FrameRecord(frame: frame, displayNs: displayNs, arrivalNs: arrival, decodeMicros: us, fullDetect: full,
                                  detections: dets.count, symbol: DecodedSymbol(d)).csvLine + "\n"
        }
        if frame == 0, maxSavedFailures > 0 {
            let img = GrayImage(copying: view)
            try? ImageFiles.savePNG(img, to: runDir.appendingPathComponent("first-frame.png").path)
        }
        frame += 1
        if buffer.utf8.count > 64 * 1024 { flushLocked() }
    }

    private func flushLocked() {
        out.write(buffer.data(using: .utf8)!)
        buffer = ""
    }

    func finish() {
        lock.lock()
        flushLocked()
        try? out.close()
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Swift.Error) {
        lock.lock()
        stopError = error
        lock.unlock()
        FileHandle.standardError.write("capture stopped: \(error)\n".data(using: .utf8)!)
    }
}

enum Capture {
    struct Options: Sendable {
        var runDir: URL
        var windowQuery: String?
        var windowID: UInt32?
        var rect: [Double]?
        var duration: Double
        var sourceIsWindow: Bool
        var scale: Double
        var expectedSymbols: Int
        var saveFailures: Int
        var analyze: Bool
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case noWindow(String), noDisplay, badRect
        var description: String {
            switch self {
            case .noWindow(let q): return "no on-screen window matches \(q) (try `latency-harness list-windows`)"
            case .noDisplay: return "no display contains the capture region"
            case .badRect: return "--rect needs X,Y,W,H in global points"
            }
        }
    }

    static func shareableContent() async throws -> SCShareableContent {
        if !CGPreflightScreenCaptureAccess() {
            FileHandle.standardError.write("""
            Screen Recording permission is not granted to the app running this command.
            Grant it once in System Settings › Privacy & Security › Screen & System Audio Recording
            (enable your terminal app), then quit and reopen the terminal. Requesting access now…

            """.data(using: .utf8)!)
            _ = CGRequestScreenCaptureAccess()
        }
        return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    }

    static func listWindows(all: Bool = false) async throws {
        let content = all ? try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                          : try await shareableContent()
        for w in content.windows where all || (w.isOnScreen && w.frame.width >= 50 && w.frame.height >= 50) {
            print(String(format: "%6u  %-28@ %@  (%.0f,%.0f %.0f×%.0f)%@", w.windowID,
                         (w.owningApplication?.applicationName ?? "?") as NSString, (w.title ?? "") as NSString,
                         w.frame.minX, w.frame.minY, w.frame.width, w.frame.height,
                         (all ? " layer \(w.windowLayer) \(w.isOnScreen ? "on-screen" : "off-screen")" : "") as NSString))
        }
    }

    static func run(_ o: Options) async throws {
        try FileManager.default.createDirectory(at: o.runDir, withIntermediateDirectories: true)
        let content = try await shareableContent()
        var window: SCWindow?
        var region: CGRect
        if let id = o.windowID {
            window = content.windows.first { $0.windowID == id }
            guard let w = window else { throw Error.noWindow("id \(id)") }
            region = w.frame
        } else if let q = o.windowQuery {
            let ql = q.lowercased()
            let matches = content.windows.filter {
                $0.isOnScreen && $0.frame.width >= 50 &&
                    (($0.title ?? "").lowercased().contains(ql) || ($0.owningApplication?.applicationName ?? "").lowercased().contains(ql))
            }
            window = matches.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            guard let w = window else { throw Error.noWindow("\"\(q)\"") }
            region = w.frame
        } else if let r = o.rect {
            guard r.count == 4 else { throw Error.badRect }
            region = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
        } else {
            throw Error.noWindow("(give --window, --window-id or --rect)")
        }
        guard let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: region.midX, y: region.midY)) }) else {
            throw Error.noDisplay
        }

        let filter: SCContentFilter
        let cfg = SCStreamConfiguration()
        var sourceDesc: String
        if o.sourceIsWindow, let w = window {
            filter = SCContentFilter(desktopIndependentWindow: w)
            sourceDesc = "window (desktop-independent)"
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
            let local = region.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                .intersection(CGRect(origin: .zero, size: display.frame.size))
            cfg.sourceRect = local
            region = local.offsetBy(dx: display.frame.minX, dy: display.frame.minY)
            sourceDesc = "display \(display.displayID) region (composited)"
        }
        let pxScale = Double(filter.pointPixelScale) * o.scale
        cfg.width = max(16, Int((region.width * pxScale).rounded()))
        cfg.height = max(16, Int((region.height * pxScale).rounded()))
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 240)
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        cfg.queueDepth = 6
        cfg.showsCursor = false
        cfg.capturesAudio = false

        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }
        let maxFps = screen?.maximumFramesPerSecond ?? 0
        let meta: [String: Any] = [
            "window_title": window?.title ?? "", "window_app": window?.owningApplication?.applicationName ?? "",
            "window_id": window.map { Int($0.windowID) } ?? -1,
            "region_points": [region.minX, region.minY, region.width, region.height],
            "pixels": [cfg.width, cfg.height], "point_pixel_scale": Double(filter.pointPixelScale), "user_scale": o.scale,
            "source": sourceDesc, "display_id": Int(display.displayID), "display_max_fps": maxFps,
            "macos": ProcessInfo.processInfo.operatingSystemVersionString,
            "start_host_ns": hostNs(), "duration_s": o.duration,
        ]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            .write(to: o.runDir.appendingPathComponent("capture.json"))
        print("capturing \(sourceDesc): \"\(window?.title ?? "")\" [\(window?.owningApplication?.applicationName ?? "")] " +
              "\(Int(region.width))×\(Int(region.height)) pt → \(cfg.width)×\(cfg.height) px, display max \(maxFps) Hz, \(o.duration) s")

        let sink = try CaptureSink(runDir: o.runDir, expectedSymbols: o.expectedSymbols, saveFailures: o.saveFailures)
        let stream = SCStream(filter: filter, configuration: cfg, delegate: sink)
        let queue = DispatchQueue(label: "capture", qos: .userInteractive)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()

        signal(SIGINT, SIG_IGN)
        let stopFlag = StopFlag()
        let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sig.setEventHandler { stopFlag.set() }
        sig.resume()
        let start = Date()
        var lastReport = start
        while Date().timeIntervalSince(start) < o.duration, !stopFlag.isSet, sink.stopError == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
            if Date().timeIntervalSince(lastReport) >= 5 {
                lastReport = Date()
                print(String(format: "  %.0f s: %d frames, %d decoded", Date().timeIntervalSince(start), sink.framesSeen, sink.framesDecoded))
            }
        }
        try? await stream.stopCapture()
        sink.finish()
        print("captured \(sink.framesSeen) frames, \(sink.framesDecoded) decoded → \(o.runDir.path)/frames.csv")
        if let e = sink.stopError { throw e }
        if o.analyze { try Report.analyzeRun(o.runDir) }
    }
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
