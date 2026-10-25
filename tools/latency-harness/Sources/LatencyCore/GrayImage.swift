// SPDX-License-Identifier: GPL-3.0-or-later
//
// 8-bit greyscale images. `GrayView` is a borrowed, strided view used by the decoder so that
// ScreenCaptureKit luma planes can be decoded without copying; `GrayImage` owns its pixels and is
// used for tests, still images, video frames and synthetic scenes.

import Foundation

public struct GrayView {
    public let base: UnsafePointer<UInt8>
    public let width: Int
    public let height: Int
    public let stride: Int

    public init(base: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) {
        self.base = base
        self.width = width
        self.height = height
        self.stride = stride
    }

    @inline(__always) public func pixel(_ x: Int, _ y: Int) -> UInt8 {
        base[y * stride + x]
    }

    /// Bilinear sample at continuous image coordinates, where pixel (x, y) covers [x, x+1) × [y, y+1).
    @inline(__always) public func sample(_ u: Double, _ v: Double) -> Double {
        let px = u - 0.5, py = v - 0.5
        var x0 = Int(px.rounded(.down)), y0 = Int(py.rounded(.down))
        var fx = px - Double(x0), fy = py - Double(y0)
        if x0 < 0 { x0 = 0; fx = 0 }
        if y0 < 0 { y0 = 0; fy = 0 }
        if x0 >= width - 1 { x0 = max(0, width - 2); fx = width > 1 ? 1 : 0 }
        if y0 >= height - 1 { y0 = max(0, height - 2); fy = height > 1 ? 1 : 0 }
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let a = Double(pixel(x0, y0)), b = Double(pixel(x1, y0))
        let c = Double(pixel(x0, y1)), d = Double(pixel(x1, y1))
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }
}

public struct GrayImage: Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, fill: UInt8 = 255) {
        self.width = width
        self.height = height
        self.pixels = [UInt8](repeating: fill, count: width * height)
    }

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Copies a strided view.
    public init(copying view: GrayView) {
        self.width = view.width
        self.height = view.height
        var px = [UInt8](repeating: 0, count: view.width * view.height)
        px.withUnsafeMutableBufferPointer { dst in
            for y in 0..<view.height {
                let src = view.base + y * view.stride
                (dst.baseAddress! + y * view.width).update(from: src, count: view.width)
            }
        }
        self.pixels = px
    }

    public func withView<R>(_ body: (GrayView) throws -> R) rethrows -> R {
        try pixels.withUnsafeBufferPointer { buf in
            try body(GrayView(base: buf.baseAddress!, width: width, height: height, stride: width))
        }
    }

    public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    public func cropped(x: Int, y: Int, width w: Int, height h: Int) -> GrayImage {
        let x0 = max(0, min(x, width)), y0 = max(0, min(y, height))
        let x1 = max(x0, min(x + w, width)), y1 = max(y0, min(y + h, height))
        var out = GrayImage(width: x1 - x0, height: y1 - y0)
        for yy in y0..<y1 {
            for xx in x0..<x1 { out[xx - x0, yy - y0] = self[xx, yy] }
        }
        return out
    }

    // MARK: - Synthetic degradations (used by tests and the synthetic video generator)

    /// Bilinear resample by `factor` (0.5 = half size).
    public func scaled(by factor: Double) -> GrayImage {
        let w = max(1, Int((Double(width) * factor).rounded()))
        let h = max(1, Int((Double(height) * factor).rounded()))
        var out = GrayImage(width: w, height: h)
        withView { v in
            for y in 0..<h {
                for x in 0..<w {
                    // Area-ish downsampling: average a few bilinear taps when shrinking.
                    let taps = factor < 1 ? 3 : 1
                    var acc = 0.0
                    for ty in 0..<taps {
                        for tx in 0..<taps {
                            let u = (Double(x) + (Double(tx) + 0.5) / Double(taps)) / factor
                            let vv = (Double(y) + (Double(ty) + 0.5) / Double(taps)) / factor
                            acc += v.sample(u, vv)
                        }
                    }
                    out[x, y] = UInt8(clamping: Int((acc / Double(taps * taps)).rounded()))
                }
            }
        }
        return out
    }

    /// Separable box blur with the given radius, applied `passes` times (3 passes ≈ Gaussian).
    /// Running sums with edge clamping; integer arithmetic.
    public func blurred(radius: Int, passes: Int = 3) -> GrayImage {
        guard radius > 0, width > 0, height > 0 else { return self }
        var cur = pixels.map { Int32($0) }
        var tmp = cur
        let n = Int32(2 * radius + 1)
        cur.withUnsafeMutableBufferPointer { a in
            tmp.withUnsafeMutableBufferPointer { b in
                for _ in 0..<passes {
                    // Horizontal: a → b.
                    for y in 0..<height {
                        let o = y * width
                        var sum: Int32 = 0
                        for d in -radius...radius { sum += a[o + min(max(d, 0), width - 1)] }
                        for x in 0..<width {
                            b[o + x] = (sum + n / 2) / n
                            sum += a[o + min(x + radius + 1, width - 1)] - a[o + max(x - radius, 0)]
                        }
                    }
                    // Vertical: b → a.
                    for x in 0..<width {
                        var sum: Int32 = 0
                        for d in -radius...radius { sum += b[min(max(d, 0), height - 1) * width + x] }
                        for y in 0..<height {
                            a[y * width + x] = (sum + n / 2) / n
                            sum += b[min(y + radius + 1, height - 1) * width + x] - b[max(y - radius, 0) * width + x]
                        }
                    }
                }
            }
        }
        return GrayImage(width: width, height: height, pixels: cur.map { UInt8(clamping: $0) })
    }

    /// Adds zero-mean Gaussian noise with standard deviation `sigma` (grey levels).
    public func withNoise(sigma: Double, seed: UInt64) -> GrayImage {
        var rng = SplitMix64(seed: seed)
        var out = self
        for i in 0..<out.pixels.count {
            let n = rng.nextGaussian() * sigma
            out.pixels[i] = UInt8(clamping: Int((Double(out.pixels[i]) + n).rounded()))
        }
        return out
    }

    /// Maps grey levels so that black → `black` and white → `white` (reduced contrast).
    public func withLevels(black: UInt8, white: UInt8) -> GrayImage {
        var out = self
        let b = Double(black), w = Double(white)
        for i in 0..<out.pixels.count {
            out.pixels[i] = UInt8(clamping: Int((b + (w - b) * Double(out.pixels[i]) / 255).rounded()))
        }
        return out
    }
}

// MARK: - Rendering symbols

public enum CodeRenderer {
    /// Renders a symbol, axis-aligned, with integer module size and the standard quiet zone.
    public static func render(_ payload: CodePayload, moduleSize: Int, quietZone: Int = CodeLayout.quietZoneModules) -> GrayImage {
        let m = CodeLayout.modules(for: payload)
        let w = (CodeLayout.widthModules + 2 * quietZone) * moduleSize
        let h = (CodeLayout.heightModules + 2 * quietZone) * moduleSize
        var img = GrayImage(width: w, height: h)
        for my in 0..<CodeLayout.heightModules {
            for mx in 0..<CodeLayout.widthModules where m[my * CodeLayout.widthModules + mx] {
                let x0 = (mx + quietZone) * moduleSize, y0 = (my + quietZone) * moduleSize
                for y in y0..<(y0 + moduleSize) {
                    for x in x0..<(x0 + moduleSize) { img[x, y] = 0 }
                }
            }
        }
        return img
    }

    /// Draws a symbol into `image` through a homography that maps module coordinates (symbol
    /// spans [0,32) × [0,16)) to image coordinates. The quiet zone is painted white. Each pixel is
    /// supersampled `ss × ss` times for anti-aliasing. `blend` mixes in a second payload (0 = only
    /// `payload`, 1 = only `other`), emulating a display mid-transition.
    public static func draw(
        _ payload: CodePayload, into image: inout GrayImage, homography h: Homography,
        black: UInt8 = 0, white: UInt8 = 255, supersample ss: Int = 2,
        blendWith other: CodePayload? = nil, blend: Double = 0
    ) {
        let m = CodeLayout.modules(for: payload)
        let m2 = other.map { CodeLayout.modules(for: $0) }
        guard let inv = h.inverted() else { return }
        let q = Double(CodeLayout.quietZoneModules)
        // Bounding box of the symbol + quiet zone in the image.
        let corners = [(-q, -q), (32 + q, -q), (32 + q, 16 + q), (-q, 16 + q)].map { h.apply($0.0, $0.1) }
        let minX = max(0, Int(corners.map(\.x).min()!.rounded(.down)))
        let maxX = min(image.width - 1, Int(corners.map(\.x).max()!.rounded(.up)))
        let minY = max(0, Int(corners.map(\.y).min()!.rounded(.down)))
        let maxY = min(image.height - 1, Int(corners.map(\.y).max()!.rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return }
        let b = Double(black), w = Double(white)
        for y in minY...maxY {
            for x in minX...maxX {
                var acc = 0.0
                var inside = 0
                for sy in 0..<ss {
                    for sx in 0..<ss {
                        let u = Double(x) + (Double(sx) + 0.5) / Double(ss)
                        let v = Double(y) + (Double(sy) + 0.5) / Double(ss)
                        let p = inv.apply(u, v)
                        guard p.x >= -q, p.x < 32 + q, p.y >= -q, p.y < 16 + q else { continue }
                        inside += 1
                        let mx = Int(p.x.rounded(.down)), my = Int(p.y.rounded(.down))
                        var dark = 0.0
                        if mx >= 0, mx < 32, my >= 0, my < 16 {
                            let i = my * 32 + mx
                            let d1 = m[i] ? 1.0 : 0.0
                            if let m2 { dark = d1 * (1 - blend) + (m2[i] ? 1.0 : 0.0) * blend } else { dark = d1 }
                        }
                        acc += w + (b - w) * dark
                    }
                }
                guard inside > 0 else { continue }
                let n = Double(ss * ss)
                let existing = Double(image[x, y])
                let value = (acc + existing * Double(ss * ss - inside)) / n
                image[x, y] = UInt8(clamping: Int(value.rounded()))
            }
        }
    }
}

// MARK: - Deterministic RNG

public struct SplitMix64: RandomNumberGenerator, Sendable {
    var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    public mutating func nextDouble() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
    public mutating func nextGaussian() -> Double {
        let u1 = max(nextDouble(), 1e-12), u2 = nextDouble()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
