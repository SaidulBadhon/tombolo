// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S2: end-to-end on the Mac without a phone — VideoToolbox encodes a test pattern, a fake scrcpy-server
// frames it exactly like Streamer.java over loopback TCP, and MirrorSession connects, demuxes and decodes it.
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import MirrorCore

private final class CollectingPresenter: FramePresenter, @unchecked Sendable {
    var stats: PipelineStats?
    private let lock = NSLock()
    private(set) var frames: [DecodedFrame] = []
    func enqueue(_ frame: DecodedFrame) { lock.lock(); frames.append(frame); lock.unlock() }
    func shutdown() {}
    var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
    var snapshot: [DecodedFrame] { lock.lock(); defer { lock.unlock() }; return frames }
}

private func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.01) }
    return cond()
}

@Suite(.serialized) struct Pipeline {
    @Test func syntheticEncoderEmitsConfigThenAnnexBKeyFrame() throws {
        let e = try SyntheticH264Encoder(width: 320, height: 640)
        let first = try e.encodeNext()
        #expect(first.count == 2)
        #expect(first[0].config)
        #expect(H264.splitAnnexB(first[0].payload).map(H264.type(of:)) == [7, 8])
        #expect(first[1].key && !first[1].config)
        #expect(H264.splitAnnexB(first[1].payload).contains { H264.type(of: $0) == 5 })
        let second = try e.encodeNext()
        #expect(second.count == 1 && !second[0].key)
    }

    @Test func assemblerBuildsAFormatDescriptionFromRealParameterSets() throws {
        let e = try SyntheticH264Encoder(width: 1080, height: 2400)
        let pk = try e.encodeNext()
        let a = H264AccessUnitAssembler()
        let cfg = VideoPacket(data: pk[0].payload, pts: nil, isConfig: true, isKeyFrame: false, receivedAt: 0)
        #expect(try a.push(cfg) == nil)
        let dims = CMVideoFormatDescriptionGetDimensions(try #require(a.format))
        #expect(dims.width == 1080 && dims.height == 2400)
        let key = VideoPacket(data: pk[1].payload, pts: pk[1].pts, isConfig: false, isKeyFrame: true, receivedAt: 0)
        let au = try #require(try a.push(key))
        #expect(au.formatGeneration == 1)
        // AVCC must contain no parameter sets.
        var off = 0, types: [UInt8] = []
        while off + 4 <= au.avcc.count {
            let n = Int(au.avcc.be32(off)); types.append(au.avcc[off + 4] & 0x1f); off += 4 + n
        }
        #expect(off == au.avcc.count && !types.contains(7) && !types.contains(8) && types.contains(5))
    }

    @Test func decoderOutputsMetalCompatibleNV12() throws {
        let e = try SyntheticH264Encoder(width: 1080, height: 2400)
        let a = H264AccessUnitAssembler()
        var out: [DecodedFrame] = []
        let d = VideoDecoder { out.append($0) }
        for _ in 0..<10 {
            for p in try e.encodeNext() {
                if let au = try a.push(VideoPacket(data: p.payload, pts: p.config ? nil : p.pts, isConfig: p.config, isKeyFrame: p.key,
                                                   receivedAt: hostNanos())) {
                    try d.decode(au)
                }
            }
        }
        d.invalidate()
        #expect(out.count == 10)
        let f = try #require(out.first)
        #expect(f.width == 1080 && f.height == 2400)
        #expect(CVPixelBufferGetPixelFormatType(f.pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(CVPixelBufferGetIOSurface(f.pixelBuffer) != nil)
        #expect(out.map(\.index) == Array(0..<10))
        #expect(d.usingHardware == true)
    }

    @Test func sessionOverLoopbackDecodesEveryFrameAndCarriesControl() throws {
        let server = try SyntheticScrcpyServer(width: 1080, height: 2400, fps: 60, expectControl: true, deviceName: "Fake phone")
        server.serve(frames: 120, keyFrameEvery: 60)
        var cfg = MirrorSession.Configuration(serverPath: "")
        cfg.existingTunnelPort = server.port
        let session = MirrorSession(configuration: cfg)
        let presenter = CollectingPresenter()
        session.presenter = presenter
        var sizes: [VideoSessionInfo] = []
        session.onVideoSession = { sizes.append($0) }
        let ended = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var endError: Error?
        session.onEnded = { endError = $0; ended.signal() }
        try session.start()
        #expect(session.deviceName == "Fake phone")
        #expect(session.state == .running)
        let control = try #require(session.control)
        try control.send(.injectKeycode(action: .down, keycode: 29))
        try control.send(.injectText("tombolo"))
        // The fake server ends the stream after 120 frames.
        #expect(ended.wait(timeout: .now() + 20) == .success)
        #expect(endError != nil)   // EOF without stop() is reported as an error
        #expect(presenter.count == 120)
        #expect(sizes == [VideoSessionInfo(width: 1080, height: 2400, clientResized: false)])
        let frames = presenter.snapshot
        #expect(frames.filter(\.isKeyFrame).count == 2)
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.pts < $1.pts })
        let s = session.stats.snapshot()
        #expect(s.decoded == 120 && s.configPackets == 1 && s.keyFrames == 2 && s.decodeErrors == 0)
        #expect(s.receiveToDecodedMs.p95 < 50)
        #expect(waitUntil(2) { server.controlBytes.count >= 14 + 12 })
        #expect(server.controlBytes.prefix(14) == ControlMessage.injectKeycode(action: .down, keycode: 29).serialize())
        #expect(server.controlBytes.dropFirst(14).prefix(12) == ControlMessage.injectText("tombolo").serialize())
        session.stop()
        server.stop()
        print("loopback 1080x2400 decode: receive→decoded \(s.receiveToDecodedMs)")
    }

    @Test func stopDuringStreamingReportsNoError() throws {
        let server = try SyntheticScrcpyServer(width: 640, height: 1280, fps: 60, expectControl: false)
        server.serve()
        var opts = ServerOptions(); opts.control = false
        var cfg = MirrorSession.Configuration(serverPath: "", server: opts)
        cfg.existingTunnelPort = server.port
        let session = MirrorSession(configuration: cfg)
        let presenter = CollectingPresenter()
        session.presenter = presenter
        nonisolated(unsafe) var reported: [String] = []
        session.onEnded = { reported.append($0.map { "\($0)" } ?? "nil") }
        try session.start()
        #expect(session.control == nil)
        #expect(waitUntil(5) { presenter.count >= 10 })
        session.stop()
        session.stop()
        #expect(reported == ["nil"])
        #expect(session.state == .ended)
        server.stop()
    }

    @Test func connectGivesUpWhenNothingListens() throws {
        // Grab a free port, then close it so nothing listens there.
        let probe = try SyntheticScrcpyServer(width: 16, height: 16)
        let port = probe.port
        probe.stop()
        var cfg = MirrorSession.Configuration(serverPath: "")
        cfg.existingTunnelPort = port
        cfg.connectAttempts = 3
        cfg.connectDelay = 0.01
        let session = MirrorSession(configuration: cfg)
        #expect(throws: MirrorError.self) { try session.start() }
        #expect(session.state == .ended)
    }
}
