// swift-tools-version:5.10
// Spike S13 (P0-13): app-shim viewer. Throwaway code — see README.md.
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "S13AppShim",
    platforms: [.macOS(.v14)],
    targets: [
        // Raw Mach messaging + bootstrap rendezvous (Chromium app-shim pattern).
        .target(name: "CShimIPC", linkerSettings: [.linkedLibrary("bsm")]),
        // Wire protocol, codesign checks, logging shared by host and shim.
        .target(name: "ShimCommon", dependencies: ["CShimIPC"]),
        .executableTarget(name: "tombolo-host", dependencies: ["ShimCommon"], path: "Sources/TomboloHost"),
        .executableTarget(name: "tombolo-shim", dependencies: ["ShimCommon"], path: "Sources/TomboloShim"),
    ]
)
