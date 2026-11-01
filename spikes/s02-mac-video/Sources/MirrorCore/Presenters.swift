// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S2: the presenter seam. Two implementations, picked by a flag (architecture §3.2: "Renderer toggle from
// day one (Metal vs AVSampleBufferDisplayLayer)").
import AppKit

public protocol FramePresenter: AnyObject {
    /// Called on the decoder thread for every decoded frame. Must not block.
    func enqueue(_ frame: DecodedFrame)
    var stats: PipelineStats? { get set }
    /// Stops any display link / releases GPU resources.
    func shutdown()
}

public enum PresenterKind: String, CaseIterable, Sendable {
    /// VideoToolbox NV12 → Metal (YCbCr→RGB shader compiled at runtime) on a CAMetalDisplayLink, latest frame wins.
    case metal
    /// VideoToolbox NV12 → AVSampleBufferDisplayLayer (display-immediately samples).
    case sampleBuffer = "sbdl"

    public func makeView(frame: NSRect = NSRect(x: 0, y: 0, width: 400, height: 880)) throws -> NSView & FramePresenter {
        switch self {
        case .metal: return try MetalPresenterView(frame: frame)
        case .sampleBuffer: return SampleBufferPresenterView(frame: frame)
        }
    }
}

/// Aspect-fit and view → device coordinate mapping (scrcpy sends positions *with* the frame size they refer to).
public enum MirrorGeometry {
    public static func aspectFit(content: CGSize, in bounds: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let s = min(bounds.width / content.width, bounds.height / content.height)
        let w = content.width * s, h = content.height * s
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    /// Maps a point in a (non-flipped, AppKit) view to device video pixels, origin top-left. Nil outside the video.
    public static func devicePoint(_ p: CGPoint, viewBounds: CGRect, videoSize: CGSize, viewIsFlipped: Bool = false) -> CGPoint? {
        let r = aspectFit(content: videoSize, in: viewBounds)
        // Closed rectangle: CGRect.contains excludes the top and right edges.
        guard p.x >= r.minX, p.x <= r.maxX, p.y >= r.minY, p.y <= r.maxY else { return nil }
        let fx = (p.x - r.minX) / r.width
        let fy = viewIsFlipped ? (p.y - r.minY) / r.height : (r.maxY - p.y) / r.height
        return CGPoint(x: min(videoSize.width - 1, (fx * videoSize.width).rounded(.down)),
                       y: min(videoSize.height - 1, (fy * videoSize.height).rounded(.down)))
    }
}
