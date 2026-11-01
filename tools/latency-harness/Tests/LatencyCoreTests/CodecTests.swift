// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import LatencyCore

/// A cluttered canvas with the symbol pasted at (x, y): random grey boxes and bars as distractors.
func clutteredScene(_ symbol: GrayImage, width: Int = 420, height: Int = 300, x: Int = 60, y: Int = 50, seed: UInt64 = 1) -> GrayImage {
    var img = GrayImage(width: width, height: height, fill: 200)
    var rng = SplitMix64(seed: seed)
    for _ in 0..<30 {
        let w = 5 + Int(rng.next() % 40), h = 5 + Int(rng.next() % 40)
        let x0 = Int(rng.next() % UInt64(width - w)), y0 = Int(rng.next() % UInt64(height - h))
        let v = UInt8(rng.next() % 256)
        for yy in y0..<(y0 + h) { for xx in x0..<(x0 + w) { img[xx, yy] = v } }
    }
    for yy in 0..<symbol.height where y + yy < height {
        for xx in 0..<symbol.width where x + xx < width { img[x + xx, y + yy] = symbol[xx, yy] }
    }
    return img
}

func decodeAll(_ img: GrayImage, expected: Int = 1) -> [Detection] {
    img.withView { CodeReader.detect($0, options: DecoderOptions(expectedSymbols: expected)) }
}

func randomPayloads(_ n: Int, seed: UInt64) -> [CodePayload] {
    var rng = SplitMix64(seed: seed)
    return (0..<n).map { _ in
        CodePayload(kindRaw: UInt8(rng.next() % 3), session: UInt8(rng.next() % 16), ticks: UInt32(truncatingIfNeeded: rng.next()))
    }
}

@Suite struct LayoutTests {
    @Test func bitsRoundTrip() {
        for p in randomPayloads(500, seed: 11) {
            #expect(CodeLayout.payload(fromBits: CodeLayout.bits(for: p)) == p)
        }
    }

    @Test func crcRejectsEverySingleAndDoubleBitError() {
        let p = CodePayload(kind: .page, session: 3, ticks: 0xDEAD_BEEF)
        let bits = CodeLayout.bits(for: p)
        for i in 0..<64 {
            var b = bits
            b[i].toggle()
            #expect(CodeLayout.payload(fromBits: b) == nil)
            for j in (i + 1)..<64 {
                var c = b
                c[j].toggle()
                #expect(CodeLayout.payload(fromBits: c) == nil)
            }
        }
    }

    @Test func knownVector() {
        // CRC-24/OpenPGP check value for "123456789" is 0x21CF02.
        #expect(CodeLayout.crc24(Array("123456789".utf8)) == 0x21CF02)
    }

    @Test func moduleMatrixHasFindersAndQuietSeparators() {
        let m = CodeLayout.modules(for: CodePayload(kind: .page, session: 0, ticks: 0))
        #expect(m.count == 32 * 16)
        // Finder centres black, inner rings white, separators white.
        for (ox, oy) in CodeLayout.finderOrigins {
            #expect(m[(oy + 3) * 32 + ox + 3])
            #expect(!m[(oy + 1) * 32 + ox + 3])
            #expect(m[oy * 32 + ox])
        }
        for y in 0..<16 { #expect(!m[y * 32 + 7]); #expect(!m[y * 32 + 24]) }
    }

    @Test func ticksAndUnwrap() {
        #expect(CodeLayout.ticks(fromMilliseconds: 1234.56) == 12346)
        #expect(CodeLayout.ticks(fromMilliseconds: 429_496_729.6 + 1) == 10)
        #expect(CodeLayout.ticks(fromNanoseconds: 1_000_049_999) == 10000)
        let full = 3 * 4_294_967_296.0 + 123
        #expect(CodeLayout.unwrap(ticks: 123, near: full + 5000) == full)
        #expect(CodeLayout.unwrap(ticks: 4_294_967_290, near: 3 * 4_294_967_296.0 + 10) == 3 * 4_294_967_296.0 - 6)
    }
}

@Suite struct DecoderTests {
    @Test func cleanRenders() {
        for (i, p) in randomPayloads(60, seed: 5).enumerated() {
            let img = clutteredScene(CodeRenderer.render(p, moduleSize: 3 + i % 6), seed: UInt64(i))
            let d = decodeAll(img)
            #expect(d.count == 1)
            #expect(d.first?.payload == p)
        }
    }

    @Test(arguments: [0.5, 0.6, 0.75, 1.0, 1.25, 1.5, 2.0])
    func scaling(_ factor: Double) {
        // Base module 6 px → 3 … 12 px after scaling.
        for (i, p) in randomPayloads(8, seed: 21).enumerated() {
            let img = clutteredScene(CodeRenderer.render(p, moduleSize: 6), width: 300, height: 180, x: 20, y: 25, seed: UInt64(i))
                .scaled(by: factor)
            let d = decodeAll(img)
            #expect(d.map(\.payload) == [p], "factor \(factor) payload \(i)")
        }
    }

    @Test(arguments: [8.0, 16.0, 25.0])
    func noise(_ sigma: Double) {
        for (i, p) in randomPayloads(8, seed: 31).enumerated() {
            let img = clutteredScene(CodeRenderer.render(p, moduleSize: 5), seed: UInt64(i)).withNoise(sigma: sigma, seed: UInt64(i))
            #expect(decodeAll(img).map(\.payload) == [p], "sigma \(sigma) payload \(i)")
        }
    }

    @Test(arguments: [1, 2])
    func blur(_ radius: Int) {
        // 3 box passes of radius r ≈ Gaussian σ ≈ r·1.15 px, on 6 px modules.
        for (i, p) in randomPayloads(6, seed: 41).enumerated() {
            let img = clutteredScene(CodeRenderer.render(p, moduleSize: 6), seed: UInt64(i)).blurred(radius: radius)
            #expect(decodeAll(img).map(\.payload) == [p], "radius \(radius) payload \(i)")
        }
    }

    @Test(arguments: [0.2, 0.4, 0.7])
    func jpeg(_ quality: Double) throws {
        for (i, p) in randomPayloads(6, seed: 51).enumerated() {
            let src = clutteredScene(CodeRenderer.render(p, moduleSize: 4), seed: UInt64(i))
            let img = try #require(ImageFiles.jpegRoundTrip(src, quality: quality))
            #expect(decodeAll(img).map(\.payload) == [p], "quality \(quality) payload \(i)")
        }
    }

    @Test func combinedDegradations() throws {
        // Roughly "mirrored at 0.6× then filmed": downscale, blur, low contrast, noise, JPEG.
        for (i, p) in randomPayloads(10, seed: 61).enumerated() {
            let base = clutteredScene(CodeRenderer.render(p, moduleSize: 8), width: 500, height: 300, x: 40, y: 40, seed: UInt64(i))
            let degraded = base.scaled(by: 0.6).blurred(radius: 1).withLevels(black: 50, white: 190).withNoise(sigma: 8, seed: UInt64(i))
            let img = try #require(ImageFiles.jpegRoundTrip(degraded, quality: 0.5))
            #expect(decodeAll(img).map(\.payload) == [p], "payload \(i)")
        }
    }

    @Test func rotationAndPerspective() throws {
        let p = CodePayload(kind: .page, session: 7, ticks: 424_242)
        for (i, angle) in [-0.5, -0.2, 0.1, 0.35, 1.2, 3.0].enumerated() {
            var img = GrayImage(width: 400, height: 400, fill: 150)
            let h0 = Homography.similarity(scale: 7, rotation: angle, tx: 200, ty: 200)
                .composed(with: Homography.similarity(scale: 1, tx: -16, ty: -8))
            // Add a mild perspective term.
            var m = h0.m
            m[6] = 0.0004 * Double(i % 3)
            CodeRenderer.draw(p, into: &img, homography: Homography(m: m))
            #expect(decodeAll(img).map(\.payload) == [p], "angle \(angle)")
        }
    }

    @Test func mirroredImage() {
        let p = CodePayload(kind: .macReference, session: 1, ticks: 99)
        let src = CodeRenderer.render(p, moduleSize: 5)
        var flipped = src
        for y in 0..<src.height { for x in 0..<src.width { flipped[x, y] = src[src.width - 1 - x, y] } }
        #expect(decodeAll(clutteredScene(flipped)).map(\.payload) == [p])
    }

    @Test func lowContrast() {
        let p = CodePayload(kind: .page, session: 2, ticks: 1)
        let img = clutteredScene(CodeRenderer.render(p, moduleSize: 5)).withLevels(black: 100, white: 160).withNoise(sigma: 4, seed: 3)
        #expect(decodeAll(img).map(\.payload) == [p])
    }

    @Test func twoAndThreeSymbolsInOneFrame() {
        let a = CodePayload(kind: .page, session: 4, ticks: 1000)
        let b = CodePayload(kind: .page, session: 4, ticks: 950)
        let c = CodePayload(kind: .macReference, session: 9, ticks: 77)
        var img = GrayImage(width: 640, height: 360, fill: 120)
        CodeRenderer.draw(a, into: &img, homography: .similarity(scale: 5, rotation: 0.05, tx: 40, ty: 120))
        CodeRenderer.draw(b, into: &img, homography: .similarity(scale: 4, rotation: -0.04, tx: 360, ty: 160))
        CodeRenderer.draw(c, into: &img, homography: .similarity(scale: 3, tx: 470, ty: 30))
        let got = Set(decodeAll(img, expected: 3).map(\.payload))
        #expect(got == [a, b, c])
    }

    @Test func blendedFramesNeverDecodeToAThirdValue() {
        // A display mid-transition shows a mix of two values. The decoder may return either value
        // or nothing — never anything else.
        var rng = SplitMix64(seed: 99)
        for i in 0..<40 {
            let a = CodePayload(kind: .page, session: 1, ticks: UInt32(truncatingIfNeeded: rng.next()))
            let b = CodePayload(kind: .page, session: 1, ticks: a.ticks &+ 167)
            var img = GrayImage(width: 260, height: 160, fill: 255)
            let blend = Double(i) / 39
            CodeRenderer.draw(a, into: &img, homography: .similarity(scale: 6, tx: 20, ty: 20), blendWith: b, blend: blend)
            for d in decodeAll(img.withNoise(sigma: 6, seed: UInt64(i))) {
                #expect(d.payload == a || d.payload == b, "blend \(blend)")
            }
        }
    }

    @Test func trackingSkipsFullDetection() {
        let dec = CodeDecoder()
        let p1 = CodePayload(kind: .page, session: 1, ticks: 10), p2 = CodePayload(kind: .page, session: 1, ticks: 177)
        let f1 = clutteredScene(CodeRenderer.render(p1, moduleSize: 5), seed: 1)
        let f2 = clutteredScene(CodeRenderer.render(p2, moduleSize: 5), seed: 1)
        #expect(f1.withView { dec.decode($0) }.map(\.payload) == [p1])
        #expect(dec.lastUsedFullDetection)
        #expect(f2.withView { dec.decode($0) }.map(\.payload) == [p2])
        #expect(!dec.lastUsedFullDetection)
    }

    @Test func emptyAndTinyImagesAreSafe() {
        #expect(decodeAll(GrayImage(width: 4, height: 4)).isEmpty)
        #expect(decodeAll(GrayImage(width: 300, height: 200, fill: 0)).isEmpty)
        #expect(decodeAll(GrayImage(width: 300, height: 200).withNoise(sigma: 80, seed: 1)).isEmpty)
    }
}
