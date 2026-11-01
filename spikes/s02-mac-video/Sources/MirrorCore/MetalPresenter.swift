// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S2: CVPixelBuffer (IOSurface) → Metal textures (zero-copy, CVMetalTextureCache) → draw on the next
// CAMetalDisplayLink tick, newest frame wins (architecture §3.2). Shaders are compiled at runtime from source
// (Command Line Tools have no `metal` compiler).
import AppKit
import CoreVideo
import Metal
import QuartzCore

open class MetalPresenterView: NSView, FramePresenter, CAMetalDisplayLinkDelegate {
    public let metalLayer = CAMetalLayer()
    public let device: MTLDevice
    public var stats: PipelineStats?
    public enum Pacing: String, Sendable {
        /// Draw the newest frame on each CAMetalDisplayLink update (the plan's design).
        case displayLink = "displaylink"
        /// Draw as soon as a frame is decoded, with `CAMetalLayer.nextDrawable()` (vsync'd present, no link).
        case immediate
    }
    /// Set before the view goes on screen.
    public var pacing: Pacing = .displayLink
    /// Frames of latency the display link targets (1 = present on the next vsync).
    public var preferredFrameLatency: Float = 1
    public var preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
    /// Diagnostics: re-present the last frame on every display-link update even when nothing new arrived.
    public var redrawEveryUpdate = false
    /// Diagnostics: called with a description of the first few display-link updates.
    public var onDiagnostic: ((String) -> Void)?
    private let renderQueue = DispatchQueue(label: "s02.metal-immediate", qos: .userInteractive)
    private var renderScheduled = false

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private let lock = Lock()
    private var pending: DecodedFrame?
    private var lastDrawn: DecodedFrame?
    private var needsRedraw = false
    private var linkThread: Thread?
    private var link: CAMetalDisplayLink?
    public private(set) var ticks = 0

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut vmain(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
        float2 p[4] = { float2(rect.x, rect.y), float2(rect.z, rect.y), float2(rect.x, rect.w), float2(rect.z, rect.w) };
        float2 t[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
        VOut o; o.pos = float4(p[vid], 0, 1); o.uv = t[vid]; return o;
    }
    struct Conv { float4 r; float4 g; float4 b; float4 offset; };
    fragment float4 fmain(VOut in [[stage_in]], texture2d<float> lum [[texture(0)]], texture2d<float> chroma [[texture(1)]],
                          constant Conv &c [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float3 v = float3(lum.sample(s, in.uv).r, chroma.sample(s, in.uv).rg) - c.offset.xyz;
        return float4(dot(c.r.xyz, v), dot(c.g.xyz, v), dot(c.b.xyz, v), 1.0);
    }
    """

    /// Limited-range ("video range") YCbCr → RGB rows, Y offset 16/255, chroma offset 128/255.
    struct Conversion {
        var r: SIMD4<Float>, g: SIMD4<Float>, b: SIMD4<Float>, offset: SIMD4<Float>
        static let offset = SIMD4<Float>(16.0 / 255, 128.0 / 255, 128.0 / 255, 0)
        static let bt709 = Conversion(r: [1.1644, 0, 1.7927, 0], g: [1.1644, -0.2132, -0.5329, 0], b: [1.1644, 2.1124, 0, 0], offset: offset)
        static let bt601 = Conversion(r: [1.1644, 0, 1.5960, 0], g: [1.1644, -0.3918, -0.8130, 0], b: [1.1644, 2.0172, 0, 0], offset: offset)
    }

    public init(frame: NSRect, device: MTLDevice? = nil) throws {
        guard let dev = device ?? MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else {
            throw MirrorError.decoder("no Metal device")
        }
        self.device = dev
        self.queue = q
        let lib = try dev.makeLibrary(source: MetalPresenterView.shaderSource, options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "vmain")
        pd.fragmentFunction = lib.makeFunction(name: "fmain")
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try dev.makeRenderPipelineState(descriptor: pd)
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
        textureCache = cache
        super.init(frame: frame)
        metalLayer.device = dev
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
        metalLayer.backgroundColor = NSColor.black.cgColor
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    open override func makeBackingLayer() -> CALayer { metalLayer }
    open override var isOpaque: Bool { true }

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
        if window != nil && pacing == .displayLink { startDisplayLink() }
    }

    open override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateDrawableSize() }
    open override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateDrawableSize() }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let s = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if metalLayer.drawableSize != s { metalLayer.drawableSize = s }
        lock.withLock { needsRedraw = true }
    }

    private func startDisplayLink() {
        guard linkThread == nil else { return }
        let t = Thread { [weak self] in
            guard let self else { return }
            let l = CAMetalDisplayLink(metalLayer: self.metalLayer)
            l.delegate = self
            l.preferredFrameLatency = self.preferredFrameLatency
            l.preferredFrameRateRange = self.preferredFrameRateRange
            l.add(to: .current, forMode: .default)
            self.lock.withLock { self.link = l }
            self.onDiagnostic?("CAMetalDisplayLink preferredFrameLatency=\(l.preferredFrameLatency) range=\(l.preferredFrameRateRange.minimum)-\(l.preferredFrameRateRange.maximum) pref \(l.preferredFrameRateRange.preferred ?? 0) maximumDrawableCount=\(self.metalLayer.maximumDrawableCount)")
            // A secondary thread's run loop does not drain autorelease pools by itself; drawables handed out by
            // the display link would pile up and starve it.
            while !Thread.current.isCancelled {
                autoreleasepool { _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25)) }
            }
            l.invalidate()
        }
        t.name = "s02.metal-display-link"
        t.qualityOfService = .userInteractive
        linkThread = t
        t.start()
    }

    public func shutdown() {
        linkThread?.cancel()
        linkThread = nil
    }

    public func enqueue(_ frame: DecodedFrame) {
        let now = hostNanos()
        let schedule: Bool = lock.withLock {
            if pending != nil { stats?.supersededFrame() }
            pending = frame
            if pacing == .immediate && !renderScheduled { renderScheduled = true; return true }
            return false
        }
        stats?.enqueuedFrame(frame, at: now)
        if schedule { renderQueue.async { [weak self] in self?.drainImmediate() } }
    }

    // Immediate pacing: one render loop drains the newest pending frame; nextDrawable() blocks when all drawables
    // are queued, and frames that arrive meanwhile replace each other (newest wins).
    private func drainImmediate() {
        while true {
            let f: DecodedFrame? = lock.withLock {
                if let p = pending { pending = nil; lastDrawn = p; return p }
                renderScheduled = false
                return nil
            }
            guard let frame = f else { return }
            autoreleasepool {
                let t = hostNanos()
                guard let d = metalLayer.nextDrawable() else { return }
                draw(frame, to: d, tick: t, target: 0, record: true)
            }
        }
    }

    // Display-link thread.
    public func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        autoreleasepool { handle(update) }
    }

    private func handle(_ update: CAMetalDisplayLink.Update) {
        let tick = hostNanos()
        let (frame, isNew): (DecodedFrame?, Bool) = lock.withLock {
            ticks += 1
            if let p = pending { pending = nil; lastDrawn = p; needsRedraw = false; return (p, true) }
            if needsRedraw || redrawEveryUpdate, let l = lastDrawn { needsRedraw = false; return (l, false) }
            return (nil, false)
        }
        if ticks <= 3 || ticks == 240 {
            let now = CACurrentMediaTime()
            onDiagnostic?(String(format: "update %d: targetTimestamp %+.2f ms, targetPresentationTimestamp %+.2f ms from now",
                                 ticks, (update.targetTimestamp - now) * 1000, (update.targetPresentationTimestamp - now) * 1000))
        }
        guard let f = frame else { return }
        draw(f, to: update.drawable, tick: tick, target: hostNanos(fromMediaTime: update.targetPresentationTimestamp), record: isNew)
    }

    private func texture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        guard let cache = textureCache else { return nil }
        var t: CVMetalTexture?
        let w = CVPixelBufferGetWidthOfPlane(pb, plane), h = CVPixelBufferGetHeightOfPlane(pb, plane)
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, format, w, h, plane, &t)
        return t
    }

    private func draw(_ f: DecodedFrame, to drawable: CAMetalDrawable, tick: UInt64, target: UInt64, record: Bool) {
        let pb = f.pixelBuffer
        guard let yT = texture(pb, plane: 0, format: .r8Unorm), let cT = texture(pb, plane: 1, format: .rg8Unorm),
              let y = CVMetalTextureGetTexture(yT), let c = CVMetalTextureGetTexture(cT),
              let cb = queue.makeCommandBuffer() else { return }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        let dw = CGFloat(drawable.texture.width), dh = CGFloat(drawable.texture.height)
        let r = MirrorGeometry.aspectFit(content: CGSize(width: f.width, height: f.height), in: CGRect(x: 0, y: 0, width: dw, height: dh))
        var rect = SIMD4<Float>(Float(r.minX / dw * 2 - 1), Float(r.minY / dh * 2 - 1), Float(r.maxX / dw * 2 - 1), Float(r.maxY / dh * 2 - 1))
        var conv = MetalPresenterView.conversion(for: pb)
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        enc.setFragmentTexture(y, index: 0)
        enc.setFragmentTexture(c, index: 1)
        enc.setFragmentBytes(&conv, length: MemoryLayout<Conversion>.size, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        if record, let stats {
            drawable.addPresentedHandler { d in
                stats.presentedFrame(f, presentedAt: hostNanos(fromMediaTime: d.presentedTime), tickAt: tick, targetAt: target)
            }
        }
        cb.present(drawable)
        cb.addCompletedHandler { _ in withExtendedLifetime((yT, cT)) {} }
        cb.commit()
    }

    static func conversion(for pb: CVPixelBuffer) -> Conversion {
        if let m = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String,
           m == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) {
            return .bt601
        }
        return .bt709
    }
}
