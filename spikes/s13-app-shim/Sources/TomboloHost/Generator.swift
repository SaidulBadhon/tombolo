// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S13: generates per-Android-app .app shims in ~/Applications/Tombolo Apps.
import AppKit
import CoreServices
import ImageIO
import ShimCommon
import UniformTypeIdentifiers

struct AppSpec { let package: String; let name: String }

struct ShimRecord: Codable {
    var package: String, name: String, bundleID: String, bundlePath: String
    var cdhash: String, shimVersion: String, generatedAt: Date, generateMs: Double
}

final class ShimStore {
    private let url = S13.stateDir.appendingPathComponent("shims.json")
    private(set) var records: [String: ShimRecord] = [:]
    init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: url) { records = (try? dec.decode([String: ShimRecord].self, from: d)) ?? [:] }
    }
    subscript(pkg: String) -> ShimRecord? {
        get { records[pkg] }
        set { records[pkg] = newValue; save() }
    }
    private func save() {
        try? FileManager.default.createDirectory(at: S13.stateDir, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601
        try? e.encode(records).write(to: url, options: .atomic)
    }
}

enum GenError: Error, CustomStringConvertible {
    case noTemplate, tool(String, Int32, String), sign
    var description: String {
        switch self {
        case .noTemplate: "shim template executable not found in host bundle"
        case let .tool(t, c, o): "\(t) exited \(c): \(o)"
        case .sign: "could not read cdhash after signing"
        }
    }
}

final class Generator {
    let log: Log
    let hostVersion: String
    let store = ShimStore()
    init(log: Log, hostVersion: String) { self.log = log; self.hostVersion = hostVersion }

    var templateURL: URL? {
        // Contents/Helpers/tombolo-shim inside the host bundle; next to the binary for `swift run`.
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tombolo-shim"),
            Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("tombolo-shim"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func bundleURL(for app: AppSpec) -> URL {
        // Real product: disambiguate duplicate names and multiple phones (e.g. "Chat (Pixel)").
        S13.shimsDir.appendingPathComponent("\(app.name).app", isDirectory: true)
    }

    func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Whether the shim on disk is missing, unknown to us, or from another host version.
    func needsGeneration(_ app: AppSpec) -> String? {
        let url = bundleURL(for: app)
        guard FileManager.default.fileExists(atPath: url.path) else { return "missing" }
        guard let rec = store[app.package] else { return "no record" }
        if rec.shimVersion != hostVersion { return "outdated (\(rec.shimVersion) → \(hostVersion))" }
        if CodeSign.cdhash(ofBundle: url) != rec.cdhash { return "cdhash changed on disk" }
        return nil
    }

    @discardableResult
    func generate(_ app: AppSpec) throws -> ShimRecord {
        let t0 = nowNs()
        guard let template = templateURL else { throw GenError.noTemplate }
        let fm = FileManager.default
        try fm.createDirectory(at: S13.shimsDir, withIntermediateDirectories: true)
        let bundleID = S13.bundleID(forPackage: app.package)
        let final = bundleURL(for: app)
        // Build next to the destination (same volume) and swap in, so a half-written bundle is never visible.
        let tmp = S13.shimsDir.appendingPathComponent(".\(app.name)-\(UUID().uuidString).app", isDirectory: true)
        let contents = tmp.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)

        // Copy bytes, not the file: FileManager.copyItem would also copy extended attributes, including a
        // com.apple.quarantine flag inherited from a downloaded host — which would make Gatekeeper assess the shim.
        let exe = contents.appendingPathComponent("MacOS/TomboloShim")
        try Data(contentsOf: template).write(to: exe)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let plist: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": "TomboloShim",
            "CFBundleIdentifier": bundleID,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": app.name,
            "CFBundleDisplayName": app.name,
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": "AppIcon",
            "CFBundleShortVersionString": hostVersion,
            "CFBundleVersion": hostVersion,
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": true,
            "NSPrincipalClass": "NSApplication",
            "TomboloPackage": app.package,
            "TomboloHostBundleID": S13.hostBundleID,
            "TomboloServiceName": S13.serviceName,
            "TomboloShimVersion": hostVersion,
            "TomboloSpike": "s13",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))
        try makeIcon(for: app, into: contents.appendingPathComponent("Resources/AppIcon.icns"))

        // Ad-hoc signature, hardened runtime, explicit identifier = bundle ID (what Chrome does for PWA shims).
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", bundleID, "--options", "runtime", tmp.path])

        if fm.fileExists(atPath: final.path) {
            _ = try fm.replaceItemAt(final, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: final)
        }
        let lsStatus = LSRegisterURL(final as CFURL, true)
        guard let cdhash = CodeSign.cdhash(ofBundle: final) else { throw GenError.sign }
        let ms = Double(nowNs() - t0) / 1e6
        let rec = ShimRecord(package: app.package, name: app.name, bundleID: bundleID, bundlePath: final.path,
                             cdhash: cdhash, shimVersion: hostVersion, generatedAt: Date(), generateMs: ms)
        store[app.package] = rec
        log(String(format: "generated %@ (%@) cdhash=%@ LSRegisterURL=%d in %.1f ms", final.path, bundleID, cdhash, lsStatus, ms))
        return rec
    }

    // MARK: Icon (real product: the Android app's icon fetched from the phone)

    private func makeIcon(for app: AppSpec, into icns: URL) throws {
        let fm = FileManager.default
        let set = fm.temporaryDirectory.appendingPathComponent("s13-\(UUID().uuidString).iconset")
        try fm.createDirectory(at: set, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: set) }
        let hue = CGFloat(abs(app.package.hashValueStable) % 360) / 360
        for (base, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
            let px = base * scale
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try writePNG(renderIcon(px: px, hue: hue, letter: String(app.name.prefix(1)).uppercased()),
                         to: set.appendingPathComponent(name))
        }
        try run("/usr/bin/iconutil", ["-c", "icns", "-o", icns.path, set.path])
    }

    private func renderIcon(px: Int, hue: CGFloat, letter: String) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let s = CGFloat(px) / 1024
        // macOS icon grid: 824 pt body centred in 1024, corner radius ≈ 185.
        let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let path = CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
        ctx.addPath(path); ctx.clip()
        let top = NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1).cgColor
        let bottom = NSColor(hue: hue, saturation: 0.85, brightness: 0.65, alpha: 1).cgColor
        let grad = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
        // Letter
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 520 * s, nil)
        let attr = NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: NSColor.white.cgColor])
        let line = CTLineCreateWithAttributedString(attr)
        let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.textPosition = CGPoint(x: body.midX - b.width / 2 - b.minX, y: body.midY - b.height / 2 - b.minY + 30 * s)
        CTLineDraw(line, ctx)
        // "Phone" badge so mirrored apps are distinguishable from native ones.
        let badge = CGRect(x: body.maxX - 250 * s, y: body.minY + 60 * s, width: 130 * s, height: 220 * s)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(max(1, 22 * s))
        ctx.addPath(CGPath(roundedRect: badge, cornerWidth: 30 * s, cornerHeight: 30 * s, transform: nil))
        ctx.strokePath()
        return ctx.makeImage()!
    }

    private func writePNG(_ img: CGImage, to url: URL) throws {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, img, nil)
        CGImageDestinationFinalize(d)
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else { throw GenError.tool(tool, p.terminationStatus, out) }
        return out
    }
}

extension String {
    /// Stable across launches (Swift's hashValue is seeded per process).
    var hashValueStable: Int { utf8.reduce(5381) { ($0 &* 33) &+ Int($1) } }
}
