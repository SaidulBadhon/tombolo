// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S13: synthetic frames (moving bars + frame counter) drawn straight into IOSurfaces.
// In the product these surfaces are the CVPixelBuffers VideoToolbox decodes into (they are IOSurface-backed),
// so the same IPC can hand decoder output to a shim without a copy.
import AppKit
import CoreText
import IOSurface

final class SurfaceRing {
    let surfaces: [IOSurface]
    private let contexts: [CGContext]
    let width: Int, height: Int

    init(width: Int, height: Int, count: Int) {
        self.width = width; self.height = height
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var ss: [IOSurface] = [], cc: [CGContext] = []
        for _ in 0..<count {
            let props: [CFString: Any] = [
                kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 4,
                kIOSurfaceBytesPerRow: IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4),
                kIOSurfacePixelFormat: UInt32(0x4247_5241), // 'BGRA'
            ]
            let s = IOSurfaceCreate(props as CFDictionary)!
            IOSurfaceSetValue(s, kIOSurfaceColorSpace, cs.copyPropertyList()!)
            let ctx = CGContext(data: IOSurfaceGetBaseAddress(s), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: IOSurfaceGetBytesPerRow(s), space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ss.append(s); cc.append(ctx)
        }
        surfaces = ss; contexts = cc
    }

    func render(slot: Int, seq: UInt64, title: String, subtitle: String) {
        let s = surfaces[slot], ctx = contexts[slot]
        IOSurfaceLock(s, [], nil)
        defer { IOSurfaceUnlock(s, [], nil) }
        let w = CGFloat(width), h = CGFloat(height)
        let hue = CGFloat(seq % 600) / 600
        ctx.setFillColor(NSColor(hue: hue, saturation: 0.45, brightness: 0.35, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Checker band that scrolls sideways — makes tearing or stale frames easy to spot by eye.
        let cell: CGFloat = w / 12, off = CGFloat(seq * 6).truncatingRemainder(dividingBy: cell * 2)
        ctx.setFillColor(NSColor(white: 1, alpha: 0.18).cgColor)
        for i in -2..<14 where i % 2 == 0 {
            ctx.fill(CGRect(x: CGFloat(i) * cell + off, y: h * 0.42, width: cell, height: cell))
        }
        ctx.setFillColor(NSColor(white: 1, alpha: 0.9).cgColor)
        ctx.fill(CGRect(x: CGFloat(seq * 12 % UInt64(width)), y: 0, width: w / 14, height: h))
        ctx.setFillColor(NSColor(white: 0, alpha: 0.55).cgColor)
        ctx.fill(CGRect(x: 0, y: CGFloat(seq * 7 % UInt64(height)), width: w, height: h / 40))
        draw(title, size: w / 9, at: CGPoint(x: w * 0.06, y: h * 0.86), ctx)
        draw("#\(seq)", size: w / 5, at: CGPoint(x: w * 0.06, y: h * 0.62), ctx)
        draw(subtitle, size: w / 26, at: CGPoint(x: w * 0.06, y: h * 0.06), ctx)
    }

    private func draw(_ text: String, size: CGFloat, at p: CGPoint, _ ctx: CGContext) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.white.cgColor,
        ]))
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }
}
