// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S2: VideoToolbox hardware decode (architecture §3.2: "VTDecompressionSession (hardware, async, real-time)
// → CVPixelBuffer (IOSurface)"). Decode on arrival, no reordering, no jitter buffer.
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// One decoded picture plus its timing on the Mac host clock (ns, CLOCK_UPTIME_RAW).
public struct DecodedFrame: @unchecked Sendable {
    /// NV12 (420v), IOSurface-backed and Metal-compatible.
    public let pixelBuffer: CVPixelBuffer
    /// Decode order index, from 0.
    public let index: UInt64
    /// Phone-side presentation time (µs, encoder clock).
    public let pts: Int64
    public let isKeyFrame: Bool
    /// Last byte of the packet read from the socket.
    public let receivedAt: UInt64
    /// VideoToolbox output callback.
    public let decodedAt: UInt64
    public var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
    public var height: Int { CVPixelBufferGetHeight(pixelBuffer) }
}

public final class VideoDecoder: @unchecked Sendable {
    public typealias Output = (DecodedFrame) -> Void

    private var session: VTDecompressionSession?
    private var sessionGeneration = -1
    private var format: CMVideoFormatDescription?
    private var index: UInt64 = 0
    private let output: Output
    public private(set) var errors = 0
    /// Whether VideoToolbox reported a hardware decoder for the current session.
    public private(set) var usingHardware: Bool?

    public init(output: @escaping Output) { self.output = output }

    deinit { invalidate() }

    public func invalidate() {
        if let s = session {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
    }

    private func makeSession(_ fd: CMVideoFormatDescription) throws {
        invalidate()
        let spec: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fd,
                                              decoderSpecification: spec as CFDictionary,
                                              imageBufferAttributes: attrs as CFDictionary,
                                              outputCallback: nil, decompressionSessionOut: &s)
        guard st == noErr, let sess = s else { throw MirrorError.decoder("VTDecompressionSessionCreate: \(st)") }
        VTSessionSetProperty(sess, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        var hw: Unmanaged<CFTypeRef>?
        if VTSessionCopyProperty(sess, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                 allocator: nil, valueOut: &hw) == noErr, let b = hw?.takeRetainedValue() as? Bool {
            usingHardware = b
        }
        session = sess
        format = fd
    }

    /// Decodes one access unit synchronously (the output callback runs before this returns).
    public func decode(_ au: H264AccessUnitAssembler.AccessUnit) throws {
        if session == nil || au.formatGeneration != sessionGeneration {
            if let s = session, VTDecompressionSessionCanAcceptFormatDescription(s, formatDescription: au.format) {
                format = au.format
            } else {
                try makeSession(au.format)
            }
            sessionGeneration = au.formatGeneration
        }
        guard let s = session else { return }
        let sb = try H264.sampleBuffer(avcc: au.avcc, format: au.format, pts: au.packet.pts)
        let packet = au.packet
        let idx = index
        index += 1
        var info = VTDecodeInfoFlags()
        let st = VTDecompressionSessionDecodeFrame(s, sampleBuffer: sb, flags: [], infoFlagsOut: &info) { [output] status, _, image, _, _ in
            let now = hostNanos()
            guard status == noErr, let img = image else { return }
            output(DecodedFrame(pixelBuffer: img, index: idx, pts: packet.pts ?? 0, isKeyFrame: packet.isKeyFrame,
                                receivedAt: packet.receivedAt, decodedAt: now))
        }
        if st != noErr {
            errors += 1
            if st == kVTInvalidSessionErr {
                // e.g. after sleep/GPU change: rebuild on the next frame.
                invalidate()
                sessionGeneration = -1
            }
            throw MirrorError.decoder("VTDecompressionSessionDecodeFrame: \(st)")
        }
    }
}
