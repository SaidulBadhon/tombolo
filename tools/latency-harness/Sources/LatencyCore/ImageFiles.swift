// SPDX-License-Identifier: GPL-3.0-or-later
//
// Still-image I/O via ImageIO: load PNG/JPEG/… as greyscale, save PNG, JPEG round trips (tests).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageFiles {
    public enum Error: Swift.Error, CustomStringConvertible {
        case cannotRead(String), cannotWrite(String)
        public var description: String {
            switch self {
            case .cannotRead(let p): return "cannot read image \(p)"
            case .cannotWrite(let p): return "cannot write image \(p)"
            }
        }
    }

    public static func gray(from cg: CGImage) -> GrayImage {
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 255, count: w * h)
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return GrayImage(width: w, height: h, pixels: px)
    }

    public static func cgImage(_ img: GrayImage) -> CGImage {
        let data = Data(img.pixels) as CFData
        let provider = CGDataProvider(data: data)!
        return CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: img.width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    public static func load(_ path: String) throws -> GrayImage {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw Error.cannotRead(path) }
        return gray(from: cg)
    }

    public static func savePNG(_ img: GrayImage, to path: String) throws {
        guard let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Error.cannotWrite(path) }
        CGImageDestinationAddImage(dst, cgImage(img), nil)
        guard CGImageDestinationFinalize(dst) else { throw Error.cannotWrite(path) }
    }

    /// Encodes as JPEG at `quality` (0…1) and decodes again.
    public static func jpegRoundTrip(_ img: GrayImage, quality: Double) -> GrayImage? {
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, cgImage(img), [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dst),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return gray(from: cg)
    }
}
