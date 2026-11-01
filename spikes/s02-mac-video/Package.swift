// swift-tools-version:6.0
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Spike S2 (P0-15): Mac video pipeline — pinned scrcpy-server → VideoToolbox → Metal (CAMetalDisplayLink),
// with an AVSampleBufferDisplayLayer presenter for comparison. Throwaway spike code; see README.md.
// Builds with the Command Line Tools only:  swift build -c release && swift test
import Foundation
import PackageDescription

// With the Command Line Tools only (no Xcode), the compiler does not find the swift-testing macro
// plugin on its own; point it at the CLT copy when that is what is installed (same as tools/latency-harness).
let cltTestingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSwiftSettings: [SwiftSetting] =
    FileManager.default.fileExists(atPath: cltTestingPlugins + "/libTestingMacros.dylib")
    ? [.unsafeFlags(["-plugin-path", cltTestingPlugins])] : []

let package = Package(
    name: "s02-mac-video",
    platforms: [.macOS(.v14)],
    products: [
        // The importable library. P0-16 (S9 keyboard modes) depends on this product without modifying it.
        .library(name: "MirrorCore", targets: ["MirrorCore"]),
        .executable(name: "s02-mirror", targets: ["s02-mirror"]),
    ],
    targets: [
        // adb driver, scrcpy-server launcher, stream demuxer, H.264 → VideoToolbox decoder, presenters,
        // control-socket handle and message codecs.
        .target(name: "MirrorCore"),
        // Thin AppKit executable: one window mirroring the phone.
        .executableTarget(name: "s02-mirror", dependencies: ["MirrorCore"]),
        .testTarget(name: "MirrorCoreTests", dependencies: ["MirrorCore"], swiftSettings: testSwiftSettings),
    ],
    swiftLanguageModes: [.v5]
)
