// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S2: scrcpy 5.0.1 video stream framing.
//
// From app/src/demuxer.c and server/.../device/Streamer.java (v5.0.1):
//   stream    := codec_id:u32be  session  { session | packet }*
//   codec_id  := "h264" 0x68323634 | "h265" | "av1"… ; 0 = stream disabled by the device, 1 = configuration error
//   session   := 12 bytes, MSB of byte 0 set: [0x80 0 0 R] width:u32be height:u32be   (R = client-resized flag)
//   packet    := 12-byte header + payload: pts_flags:u64be size:u32be, then `size` bytes
//                pts_flags bit 63 = 0 (media), bit 62 = config packet (SPS/PPS, PTS unused), bit 61 = key frame,
//                bits 0…60 = PTS in µs (MediaCodec presentationTimeUs, phone clock)
// Before the stream, the first socket carries one dummy byte (tunnel_forward) and a 64-byte device name
// (DesktopConnection.java; app/src/server.c device_read_info).
import Foundation

public enum CodecID: UInt32, Sendable {
    case h264 = 0x6832_3634
    case h265 = 0x6832_3635
    case av1 = 0x0061_7631
}

public struct VideoPacket: @unchecked Sendable {
    public var data: Data
    /// Presentation time in µs on the phone's encoder clock; nil for config packets.
    public var pts: Int64?
    public var isConfig: Bool
    public var isKeyFrame: Bool
    /// Host time (ns, CLOCK_UPTIME_RAW) when the last byte of the packet was read from the socket.
    public var receivedAt: UInt64
}

public struct VideoSessionInfo: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var clientResized: Bool
}

public enum StreamEvent: @unchecked Sendable {
    case session(VideoSessionInfo)
    case packet(VideoPacket)
}

public enum ScrcpyFraming {
    public static let headerSize = 12
    public static let deviceNameLength = 64
    static let flagSession: UInt64 = 1 << 63
    static let flagConfig: UInt64 = 1 << 62
    static let flagKeyFrame: UInt64 = 1 << 61
    static let ptsMask: UInt64 = flagKeyFrame - 1
    /// Refuse absurd packet sizes instead of allocating them (a 1080p key frame at 8 Mb/s is ≈ 100–300 kB).
    static let maxPacketSize = 64 << 20

    /// Parses the 64-byte NUL-padded device name.
    public static func parseDeviceName(_ d: Data) -> String {
        let bytes = d.prefix(deviceNameLength - 1)
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return String(decoding: bytes[bytes.startIndex..<end], as: UTF8.self)
    }

    public static func parseCodec(_ raw: UInt32) throws -> CodecID {
        if raw == 0 { throw MirrorError.streamDisabled("video stream disabled by the device") }
        if raw == 1 { throw MirrorError.streamDisabled("video stream configuration error on the device (see server log)") }
        guard let c = CodecID(rawValue: raw) else {
            throw MirrorError.protocolError(String(format: "unknown codec id 0x%08x", raw))
        }
        return c
    }

    public enum Header {
        case session(VideoSessionInfo)
        case packet(ptsFlags: UInt64, size: Int)
    }

    public static func parseHeader(_ h: Data) throws -> Header {
        precondition(h.count == headerSize)
        if h[h.startIndex] & 0x80 != 0 {
            let w = Int(h.be32(4)), ht = Int(h.be32(8))
            guard w > 0, ht > 0 else { throw MirrorError.protocolError("invalid session size \(w)x\(ht)") }
            return .session(VideoSessionInfo(width: w, height: ht, clientResized: h[h.startIndex + 3] & 1 != 0))
        }
        let size = Int(h.be32(8))
        guard size > 0, size <= maxPacketSize else { throw MirrorError.protocolError("invalid packet size \(size)") }
        return .packet(ptsFlags: h.be64(0), size: size)
    }

    static func makePacket(ptsFlags: UInt64, payload: Data, receivedAt: UInt64) -> VideoPacket {
        let config = ptsFlags & flagConfig != 0
        return VideoPacket(data: payload, pts: config ? nil : Int64(ptsFlags & ptsMask), isConfig: config,
                           isKeyFrame: ptsFlags & flagKeyFrame != 0, receivedAt: receivedAt)
    }

    // MARK: Writers (what Streamer.java sends) — used by tests and the synthetic loopback source.

    public static func encodeCodec(_ c: CodecID) -> Data { var d = Data(); d.appendBE32(c.rawValue); return d }

    public static func encodeSession(width: Int, height: Int, clientResized: Bool = false) -> Data {
        var d = Data()
        d.appendBE32(0x8000_0000 | (clientResized ? 1 : 0))
        d.appendBE32(UInt32(width)); d.appendBE32(UInt32(height))
        return d
    }

    public static func encodePacket(_ payload: Data, pts: Int64, config: Bool = false, keyFrame: Bool = false) -> Data {
        var flags: UInt64 = config ? flagConfig : UInt64(pts) & ptsMask
        if !config && keyFrame { flags |= flagKeyFrame }
        var d = Data(capacity: headerSize + payload.count)
        d.appendBE64(flags); d.appendBE32(UInt32(payload.count)); d.append(payload)
        return d
    }

    public static func encodeDeviceName(_ name: String) -> Data {
        var d = Data(count: deviceNameLength)
        let b = Array(name.utf8)
        let n = utf8TruncationIndex(b, maxLen: deviceNameLength - 1)
        d.replaceSubrange(0..<n, with: b[0..<n])
        return d
    }
}

/// Pull-based reader over anything that can "read exactly n bytes" (a socket, or a buffer in tests).
public final class StreamDemuxer {
    public typealias ReadExactly = (_ count: Int) -> Data?
    private let read: ReadExactly
    public private(set) var codec: CodecID?

    public init(read: @escaping ReadExactly) { self.read = read }

    /// Reads the codec id. Must be called once, first.
    public func readCodec() throws -> CodecID {
        guard let d = read(4) else { throw MirrorError.protocolError("stream ended before the codec id") }
        let c = try ScrcpyFraming.parseCodec(d.be32(0))
        codec = c
        return c
    }

    /// Next session change or packet; nil at end of stream.
    public func next() throws -> StreamEvent? {
        guard let h = read(ScrcpyFraming.headerSize) else { return nil }
        switch try ScrcpyFraming.parseHeader(h) {
        case .session(let s):
            return .session(s)
        case .packet(let flags, let size):
            guard let payload = read(size) else { return nil }
            return .packet(ScrcpyFraming.makePacket(ptsFlags: flags, payload: payload, receivedAt: hostNanos()))
        }
    }
}
