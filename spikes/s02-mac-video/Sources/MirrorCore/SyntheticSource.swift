// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S2: a phone-less stand-in for scrcpy-server. It listens on 127.0.0.1, speaks the same v5.0.1 framing
// (dummy byte, 64-byte device name, codec id, session header, config + media packets) and streams H.264 that
// VideoToolbox encodes from a moving test pattern. Used by the unit tests and `s02-mirror --synthetic`; it
// exercises everything after the adb tunnel (sockets → demux → decode → present) on the Mac alone.
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import VideoToolbox

/// H.264 encoder that emits what MediaCodec + Streamer.java would: an Annex-B config packet (SPS + PPS) once,
/// then one Annex-B access unit per frame. PTS = host time in µs at capture.
public final class SyntheticH264Encoder: @unchecked Sendable {
    public let width: Int, height: Int
    private var session: VTCompressionSession?
    private var pool: CVPixelBufferPool?
    private let lock = Lock()
    private var out: [(Data, Int64, Bool, Bool)] = []   // payload, pts, config, key
    private var sentConfig = false
    private var frameNo: Int64 = 0

    public init(width: Int, height: Int, bitRate: Int = 8_000_000, fps: Int = 60) throws {
        self.width = width; self.height = height
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                            encoderSpecification: [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
                                            refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let sess = s else { throw MirrorError.decoder("VTCompressionSessionCreate: \(st)") }
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate as CFNumber)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 10 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(sess)
        session = sess
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    }

    deinit { if let s = session { VTCompressionSessionInvalidate(s) } }

    /// Draws frame `n` (moving bars on a gradient) into an NV12 buffer.
    private func render(_ n: Int64) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pbOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
        guard let pb = pbOut else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let bar = Int(n * 8) % width, band = Int(n * 5) % height
        for r in 0..<height {
            let row = y + r * ys
            let base = UInt8(16 + (r * 200 / height))
            memset(row, Int32(base), width)
            if abs(r - band) < height / 60 { memset(row, 235, width) }
            let x0 = bar, w = max(1, width / 16)
            memset(row + x0, 235, min(w, width - x0))
        }
        let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for r in 0..<(height / 2) {
            let row = c + r * cs
            for x in stride(from: 0, to: width, by: 2) { row[x] = UInt8(128 + (x * 64 / width)); row[x + 1] = UInt8(96 + Int(n % 64)) }
        }
        return pb
    }

    /// Encodes one frame synchronously; returns the packets Streamer.java would send for it.
    public func encodeNext(forceKeyFrame: Bool = false) throws -> [(payload: Data, pts: Int64, config: Bool, key: Bool)] {
        guard let s = session, let pb = render(frameNo) else { throw MirrorError.decoder("encoder not ready") }
        let pts = Int64(hostNanos() / 1000)
        frameNo += 1
        let props: CFDictionary? = forceKeyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let st = VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000),
                                                 duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sb in
            guard let self, status == noErr, let sb else { return }
            self.collect(sb, pts: pts)
        }
        guard st == noErr else { throw MirrorError.decoder("VTCompressionSessionEncodeFrame: \(st)") }
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: CMTime(value: pts, timescale: 1_000_000))
        return lock.withLock { let o = out; out.removeAll(); return o.map { ($0.0, $0.1, $0.2, $0.3) } }
    }

    private func collect(_ sb: CMSampleBuffer, pts: Int64) {
        let startCode: [UInt8] = [0, 0, 0, 1]
        var key = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let a = atts.first, let notSync = a[kCMSampleAttachmentKey_NotSync] as? Bool {
            key = !notSync
        }
        var packets: [(Data, Int64, Bool, Bool)] = []
        if !sentConfig, let fd = CMSampleBufferGetFormatDescription(sb) {
            var config = Data()
            for i in 0..<2 {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil) == noErr, let p = ptr {
                    config.append(contentsOf: startCode); config.append(p, count: size)
                }
            }
            packets.append((config, 0, true, false))
            sentConfig = true
        }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        var len = 0
        var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == noErr,
              let base = ptr else { return }
        var annexB = Data(capacity: len + 16)
        var off = 0
        base.withMemoryRebound(to: UInt8.self, capacity: len) { b in
            while off + 4 <= len {
                let n = Int(UInt32(b[off]) << 24 | UInt32(b[off + 1]) << 16 | UInt32(b[off + 2]) << 8 | UInt32(b[off + 3]))
                off += 4
                guard n > 0, off + n <= len else { break }
                annexB.append(contentsOf: startCode); annexB.append(b + off, count: n)
                off += n
            }
        }
        packets.append((annexB, pts, false, key))
        lock.withLock { out.append(contentsOf: packets) }
    }
}

/// Listens on 127.0.0.1:<ephemeral>, accepts the video and (optionally) the control connection, then streams.
public final class SyntheticScrcpyServer: @unchecked Sendable {
    public let port: UInt16
    public let width: Int, height: Int, fps: Int
    public let deviceName: String
    private let listenFD: Int32
    private let expectControl: Bool
    private let lock = Lock()
    private var stopped = false
    private var clientFDs: [Int32] = []
    /// Control-socket bytes received from the client (tests check what was sent).
    public private(set) var controlBytes = Data()
    public private(set) var framesSent = 0

    public init(width: Int = 1080, height: Int = 2400, fps: Int = 60, expectControl: Bool = true, deviceName: String = "Synthetic S2 source") throws {
        self.width = width; self.height = height; self.fps = fps; self.expectControl = expectControl; self.deviceName = deviceName
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw MirrorError.connectFailed("socket") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { p -> Bool in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                bind(fd, sp, len) == 0 && listen(fd, 4) == 0 && getsockname(fd, sp, &len) == 0
            }
        }
        guard ok else { Darwin.close(fd); throw MirrorError.connectFailed("bind/listen: \(String(cString: strerror(errno)))") }
        listenFD = fd
        port = UInt16(bigEndian: addr.sin_port)
    }

    deinit { stop() }

    public func stop() {
        let fds: [Int32] = lock.withLock {
            if stopped { return [] }
            stopped = true
            return clientFDs + [listenFD]
        }
        for f in fds { Darwin.shutdown(f, SHUT_RDWR); Darwin.close(f) }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func write(_ fd: Int32, _ d: Data) -> Bool {
        d.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let r = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if r <= 0 { if r < 0 && errno == EINTR { continue }; return false }
                off += r
            }
            return true
        }
    }

    /// Serves one client session on a background thread: `frames` frames (0 = until stopped) at `fps`.
    public func serve(frames: Int = 0, keyFrameEvery: Int = 0) {
        let t = Thread { [self] in
            var one: Int32 = 1
            let v = accept(listenFD, nil, nil)
            guard v >= 0 else { return }
            setsockopt(v, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            lock.withLock { clientFDs.append(v) }
            guard write(v, Data([0])) else { return }   // dummy byte (DesktopConnection.java)
            if expectControl {
                let c = accept(listenFD, nil, nil)
                guard c >= 0 else { return }
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                lock.withLock { clientFDs.append(c) }
                let r = Thread { [self] in
                    var buf = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let n = Darwin.read(c, &buf, buf.count)
                        if n <= 0 { break }
                        lock.withLock { controlBytes.append(contentsOf: buf[0..<n]) }
                    }
                }
                r.start()
            }
            guard write(v, ScrcpyFraming.encodeDeviceName(deviceName)),
                  write(v, ScrcpyFraming.encodeCodec(.h264)),
                  write(v, ScrcpyFraming.encodeSession(width: width, height: height)),
                  let enc = try? SyntheticH264Encoder(width: width, height: height, fps: fps) else { return }
            let interval = 1_000_000_000 / UInt64(max(1, fps))
            var next = hostNanos()
            var i = 0
            while !isStopped && (frames == 0 || i < frames) {
                let force = keyFrameEvery > 0 && i > 0 && i % keyFrameEvery == 0
                guard let pk = try? enc.encodeNext(forceKeyFrame: force) else { break }
                for p in pk {
                    if !write(v, ScrcpyFraming.encodePacket(p.payload, pts: p.pts, config: p.config, keyFrame: p.key)) { return }
                }
                i += 1
                lock.withLock { framesSent = i }
                next += interval
                let now = hostNanos()
                if next > now { usleep(UInt32((next - now) / 1000)) } else { next = now }
            }
            if frames > 0 { Darwin.shutdown(v, SHUT_WR) }   // end of stream
        }
        t.name = "s02.synthetic-server"
        t.start()
    }
}
