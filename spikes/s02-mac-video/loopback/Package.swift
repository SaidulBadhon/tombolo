// swift-tools-version:6.0
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Spike S2: phone-less loopback source for measuring the Mac half of the pipeline with the S1 harness.
// A separate package so the importable MirrorCore library (in ..) does not depend on the latency harness.
import PackageDescription

let package = Package(
    name: "s02-loopback",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: ".."),
        .package(path: "../../../tools/latency-harness"),
    ],
    targets: [
        .executableTarget(name: "s02-loopback-source", dependencies: [
            .product(name: "MirrorCore", package: "s02-mac-video"),
            .product(name: "LatencyCore", package: "latency-harness"),
        ]),
    ],
    swiftLanguageModes: [.v5]
)
