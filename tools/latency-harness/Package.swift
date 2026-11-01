// swift-tools-version:6.0
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tombolo latency harness (S1). Builds with the Command Line Tools only:
//   swift build -c release && swift test
import Foundation
import PackageDescription

// With the Command Line Tools only (no Xcode), the compiler does not find the swift-testing macro
// plugin on its own; point it at the CLT copy when that is what is installed.
let cltTestingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSwiftSettings: [SwiftSetting] =
    FileManager.default.fileExists(atPath: cltTestingPlugins + "/libTestingMacros.dylib")
    ? [.unsafeFlags(["-plugin-path", cltTestingPlugins])] : []

let package = Package(
    name: "latency-harness",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "latency-harness", targets: ["latency-harness"]),
        .library(name: "LatencyCore", targets: ["LatencyCore"]),
    ],
    targets: [
        // Pure logic: code layout, encoder/decoder, clock sync, statistics, analysis.
        .target(name: "LatencyCore"),
        // CLI: ScreenCaptureKit capture, Mac reference-code window, optical video analysis.
        .executableTarget(name: "latency-harness", dependencies: ["LatencyCore"]),
        .testTarget(name: "LatencyCoreTests", dependencies: ["LatencyCore"], swiftSettings: testSwiftSettings),
    ]
)
