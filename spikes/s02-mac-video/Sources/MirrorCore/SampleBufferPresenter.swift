// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S2: the comparison presenter — the same VideoToolbox output handed to AVSampleBufferDisplayLayer as
// display-immediately samples (implementation plan §0.C S2 fallback; architecture §3.2 renderer toggle).
import AVFoundation
import AppKit
import CoreMedia

open class SampleBufferPresenterView: NSView, FramePresenter {
    public let displayLayer = AVSampleBufferDisplayLayer()
    public var stats: PipelineStats?
    private let lock = Lock()
    private var format: CMVideoFormatDescription?
    public private(set) var flushes = 0

    public override init(frame: NSRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.isOpaque = true
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    open override func makeBackingLayer() -> CALayer { displayLayer }
    open override var isOpaque: Bool { true }

    public func shutdown() { displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil) }

    public func enqueue(_ frame: DecodedFrame) {
        let pb = frame.pixelBuffer
        let fd: CMVideoFormatDescription? = lock.withLock {
            if let f = format, CMVideoFormatDescriptionMatchesImageBuffer(f, imageBuffer: pb) { return f }
            var nf: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &nf)
            format = nf
            return nf
        }
        guard let f = fd else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: frame.pts, timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: f,
                                                       sampleTiming: &timing, sampleBufferOut: &sb) == noErr, let s = sb else { return }
        if let atts = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: true) as? [NSMutableDictionary], let a = atts.first {
            a[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        let r = displayLayer.sampleBufferRenderer
        if r.status == .failed || r.requiresFlushToResumeDecoding {
            r.flush()
            lock.withLock { flushes += 1 }
        }
        r.enqueue(s)
        stats?.enqueuedFrame(frame, at: hostNanos())
    }
}
