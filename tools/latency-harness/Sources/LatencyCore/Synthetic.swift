// SPDX-License-Identifier: GPL-3.0-or-later
//
// Synthetic optical scene: what a high-speed camera would see when filming the phone, the Mac
// mirror window and the Mac reference window side by side. Used to test the optical analysis
// end to end (including ffmpeg H.264 round trips) without a camera.

import Foundation

public struct SyntheticOpticalScene: Sendable {
    public var width = 640
    public var height = 360
    /// True camera frame rate (the analysis is told the nominal rate separately).
    public var cameraFps = 240.0
    public var phoneHz = 60.0
    public var macHz = 120.0
    /// Injected glass-to-glass latency: phone glass → Mac glass.
    public var latencyMs = 45.0
    /// Phone render (rAF) → phone glass.
    public var phoneGlassDelayMs = 20.0
    /// Mac render → Mac glass (reference window).
    public var macGlassDelayMs = 10.0
    /// Pixel response: a new frame fades in linearly over this long.
    public var responseMs = 2.0
    public var phoneEpochMs = 123_456.0
    public var macEpochMs = 9_876_543.0
    public var session: UInt8 = 5
    public var noiseSigma = 4.0
    public var blurRadius = 1
    public var seed: UInt64 = 7
    public var phone = Homography.similarity(scale: 5, rotation: 0.07, tx: 50, ty: 110)
    public var mirror = Homography.similarity(scale: 4, rotation: -0.03, tx: 360, ty: 160)
    public var macReference = Homography.similarity(scale: 3, rotation: 0.0, tx: 470, ty: 30)

    public init() {}

    struct Shown { var value: Double; var previous: Double; var blend: Double }

    /// Value displayed by a source that renders frame j at time j·T (its own clock = epoch + j·T)
    /// and shows it from j·T + delay, with a linear fade-in of `responseMs`.
    func shown(t: Double, hz: Double, delay: Double, epoch: Double) -> Shown {
        let period = 1000 / hz
        let j = ((t - delay) / period).rounded(.down)
        let since = t - (j * period + delay)
        let blend = responseMs > 0 ? min(1, since / responseMs) : 1
        return Shown(value: epoch + j * period, previous: epoch + (j - 1) * period, blend: blend)
    }

    public func frame(_ k: Int) -> GrayImage {
        let t = Double(k) / cameraFps * 1000
        var img = GrayImage(width: width, height: height)
        // Background: a soft gradient (uneven lighting).
        for y in 0..<height {
            for x in 0..<width {
                img[x, y] = UInt8(90 + 60 * x / width + 20 * y / height)
            }
        }
        let p = shown(t: t, hz: phoneHz, delay: phoneGlassDelayMs, epoch: phoneEpochMs)
        let m = shown(t: t, hz: phoneHz, delay: phoneGlassDelayMs + latencyMs, epoch: phoneEpochMs)
        let r = shown(t: t, hz: macHz, delay: macGlassDelayMs, epoch: macEpochMs)
        func draw(_ s: Shown, kind: CodeKind, _ h: Homography, black: UInt8, white: UInt8) {
            let cur = CodePayload(kind: kind, session: session, ticks: CodeLayout.ticks(fromMilliseconds: s.value))
            let prev = CodePayload(kind: kind, session: session, ticks: CodeLayout.ticks(fromMilliseconds: s.previous))
            // blend = weight of `other`; here other = previous frame, fading out.
            CodeRenderer.draw(cur, into: &img, homography: h, black: black, white: white, supersample: 2,
                              blendWith: s.blend < 1 ? prev : nil, blend: 1 - s.blend)
        }
        draw(p, kind: .page, phone, black: 25, white: 235)
        draw(m, kind: .page, mirror, black: 35, white: 220)
        draw(r, kind: .macReference, macReference, black: 35, white: 220)
        var out = img
        if blurRadius > 0 { out = out.blurred(radius: blurRadius, passes: 2) }
        if noiseSigma > 0 { out = out.withNoise(sigma: noiseSigma, seed: seed &+ UInt64(k)) }
        return out
    }
}
