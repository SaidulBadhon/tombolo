// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S2: H.264 Annex-B (what MediaCodec emits and scrcpy forwards) → AVCC sample buffers for VideoToolbox.
import CoreMedia
import Foundation

public enum H264 {
    public enum NALType: UInt8 {
        case slice = 1, idr = 5, sei = 6, sps = 7, pps = 8, aud = 9, filler = 12
    }

    /// Splits an Annex-B byte stream into NAL units (without start codes). Accepts 3- and 4-byte start codes
    /// and strips trailing zero bytes (trailing_zero_8bits / the leading zero of a 4-byte start code).
    public static func splitAnnexB(_ data: Data) -> [Data] {
        var nals: [Data] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            let n = p.count
            var i = 0
            var start = -1
            func flush(_ end: Int) {
                guard start >= 0 else { return }
                var e = end
                while e > start && p[e - 1] == 0 { e -= 1 }
                if e > start { nals.append(Data(bytes: p.baseAddress! + start, count: e - start)) }
            }
            while i + 2 < n {
                if p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1 {
                    flush(i)
                    i += 3
                    start = i
                    continue
                }
                // Fast skip: a start code needs two zeros, so if p[i+2] > 1 we can jump 3.
                if p[i + 2] > 1 { i += 3 } else { i += 1 }
            }
            if start >= 0 { flush(n) } else if n > 0 { nals.append(Data(bytes: p.baseAddress!, count: n)) }
        }
        return nals
    }

    @inline(__always) public static func type(of nal: Data) -> UInt8 { nal.isEmpty ? 0 : nal[nal.startIndex] & 0x1f }

    /// Builds a format description from SPS + PPS (4-byte AVCC length prefixes).
    public static func formatDescription(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        var fd: CMFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let ptrs: [UnsafePointer<UInt8>] = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            }
        }
        guard status == noErr, let f = fd else { throw MirrorError.decoder("CMVideoFormatDescriptionCreateFromH264ParameterSets: \(status)") }
        return f
    }

    /// NAL units → one AVCC buffer (4-byte big-endian lengths).
    public static func avcc(_ nals: [Data]) -> Data {
        var out = Data(capacity: nals.reduce(0) { $0 + $1.count + 4 })
        for n in nals { out.appendBE32(UInt32(n.count)); out.append(n) }
        return out
    }

    /// AVCC bytes → a ready CMSampleBuffer (one sample).
    public static func sampleBuffer(avcc: Data, format: CMVideoFormatDescription, pts: Int64?, displayImmediately: Bool = false) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                                                    blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                    dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard st == noErr, let bb = block else { throw MirrorError.decoder("CMBlockBufferCreateWithMemoryBlock: \(st)") }
        st = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: avcc.count) }
        guard st == noErr else { throw MirrorError.decoder("CMBlockBufferReplaceDataBytes: \(st)") }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: pts.map { CMTime(value: $0, timescale: 1_000_000) } ?? .invalid,
                                        decodeTimeStamp: .invalid)
        var size = avcc.count
        var sb: CMSampleBuffer?
        st = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: format, sampleCount: 1,
                                       sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                       sampleSizeArray: &size, sampleBufferOut: &sb)
        guard st == noErr, let s = sb else { throw MirrorError.decoder("CMSampleBufferCreateReady: \(st)") }
        if displayImmediately, let atts = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: true) as? [NSMutableDictionary], let a = atts.first {
            a[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return s
    }
}

/// Turns scrcpy packets into decodable access units: tracks SPS/PPS from config packets (and in-band parameter
/// sets), rebuilds the format description when they change, and strips parameter sets / AUD / filler from media.
public final class H264AccessUnitAssembler {
    public private(set) var sps: Data?
    public private(set) var pps: Data?
    public private(set) var format: CMVideoFormatDescription?
    /// Incremented whenever `format` is replaced.
    public private(set) var formatGeneration = 0

    public init() {}

    public struct AccessUnit {
        public var avcc: Data
        public var format: CMVideoFormatDescription
        /// Same value as long as the parameter sets are unchanged.
        public var formatGeneration: Int
        public var packet: VideoPacket
    }

    /// Returns an access unit for media packets, nil for config-only packets (or media before any SPS/PPS).
    public func push(_ packet: VideoPacket) throws -> AccessUnit? {
        let nals = H264.splitAnnexB(packet.data)
        var newSPS = sps, newPPS = pps
        var media: [Data] = []
        for n in nals {
            switch H264.type(of: n) {
            case H264.NALType.sps.rawValue: newSPS = n
            case H264.NALType.pps.rawValue: newPPS = n
            case H264.NALType.aud.rawValue, H264.NALType.filler.rawValue: break
            default: media.append(n)
            }
        }
        if let s = newSPS, let p = newPPS, s != sps || p != pps || format == nil {
            format = try H264.formatDescription(sps: s, pps: p)
            sps = s; pps = p
            formatGeneration += 1
        }
        guard !packet.isConfig, !media.isEmpty, let f = format else { return nil }
        return AccessUnit(avcc: H264.avcc(media), format: f, formatGeneration: formatGeneration, packet: packet)
    }
}
