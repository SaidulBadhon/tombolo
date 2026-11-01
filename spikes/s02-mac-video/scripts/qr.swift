// SPDX-License-Identifier: GPL-3.0-or-later
//
// Spike S2 (P0-15): write a QR code as a PNG, for adb's Wireless debugging pairing (scripts/pair-wireless.sh).
// Uses Core Image's built-in generator, so nothing needs installing.
//
//   qr <text> <out.png>

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: qr <text> <out.png>\n".utf8))
    exit(2)
}
let filter = CIFilter.qrCodeGenerator()
filter.message = Data(args[1].utf8)
filter.correctionLevel = "M"
guard let code = filter.outputImage else { exit(1) }
let scaled = code.transformed(by: CGAffineTransform(scaleX: 14, y: 14))
// A white quiet zone around the code; phone cameras struggle without one.
let background = CIImage(color: .white).cropped(to: scaled.extent.insetBy(dx: -56, dy: -56))
let image = scaled.composited(over: background)
guard let png = CIContext().pngRepresentation(of: image, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) else {
    exit(1)
}
try png.write(to: URL(fileURLWithPath: args[2]))
