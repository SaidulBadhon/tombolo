// SPDX-License-Identifier: GPL-3.0-or-later
//
// A small always-on-top window that shows the Mac host clock as a TLC1 symbol (kind = mac),
// updated on every display refresh by a CADisplayLink. Ticks = the display link's `timestamp`
// (CACurrentMediaTime base = mach_absolute_time), so the value is on the same clock as the
// capture tool and the page server.
//
// Uses:
// * optical mode — the camera films it next to the phone and the mirror; the analysis measures
//   the camera's true frame rate against the Mac clock (slow-motion fps metadata is often off).
// * self-test — capturing this window measures Mac render → composited display with no clock
//   sync at all, validating the capture timestamps and the decoder.

import AppKit
import LatencyCore
import QuartzCore

@MainActor
final class CodeView: NSView {
    var modules: [Bool] = CodeLayout.modules(for: CodePayload(kind: .macReference, session: 0, ticks: 0))
    var label = ""
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        let scale = window?.backingScaleFactor ?? 2
        let textH: CGFloat = 22
        // Integer device pixels per module.
        let modPx = max(2, floor(min(bounds.width * scale / 36, (bounds.height - textH) * scale / 20)))
        let mod = modPx / scale
        let ox = floor((bounds.width - 36 * mod) / 2 * scale) / scale
        let oy: CGFloat = 0
        NSColor.black.setFill()
        let w = CodeLayout.widthModules, q = CGFloat(CodeLayout.quietZoneModules)
        for my in 0..<CodeLayout.heightModules {
            var mx = 0
            while mx < w {
                if !modules[my * w + mx] { mx += 1; continue }
                let start = mx
                while mx < w, modules[my * w + mx] { mx += 1 }
                NSRect(x: ox + (CGFloat(start) + q) * mod, y: oy + (CGFloat(my) + q) * mod,
                       width: CGFloat(mx - start) * mod, height: mod).fill()
            }
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .bold), .foregroundColor: NSColor.black]
        (label as NSString).draw(at: NSPoint(x: ox + q * mod, y: oy + 20 * mod), withAttributes: attrs)
    }
}

@MainActor
final class MacCodeController: NSObject, NSWindowDelegate {
    let view: CodeView
    let session: UInt8
    var link: CADisplayLink?
    var frames = 0

    init(view: CodeView) {
        self.view = view
        self.session = UInt8.random(in: 0...15)
    }

    func start() {
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc func tick(_ link: CADisplayLink) {
        let ticks = UInt32(truncatingIfNeeded: Int64((link.timestamp * 10_000).rounded()))
        view.modules = CodeLayout.modules(for: CodePayload(kind: .macReference, session: session, ticks: ticks))
        frames += 1
        view.label = String(format: "Mac %.1f ms  #%d", Double(ticks) / 10, frames)
        view.needsDisplay = true
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}

enum MacCodeWindow {
    @MainActor
    static func run(duration: Double?, at: [Double]?, size: [Double]?) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let w = size?.first ?? 380, h = size.flatMap { $0.count > 1 ? $0[1] : nil } ?? 240
        let window = NSWindow(contentRect: NSRect(x: at?.first ?? 200, y: at.flatMap { $0.count > 1 ? $0[1] : nil } ?? 200, width: w, height: h),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Tombolo Mac reference code"
        window.level = .floating
        let view = CodeView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        window.contentView = view
        let controller = MacCodeController(view: view)
        window.delegate = controller
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        controller.start()
        print("Mac reference code window open (session tag \(controller.session)); close it or press Ctrl-C to quit")
        if let d = duration {
            Timer.scheduledTimer(withTimeInterval: d, repeats: false) { _ in
                MainActor.assumeIsolated {
                    print("mac-code: \(controller.frames) frames drawn")
                    NSApp.terminate(nil)
                }
            }
        }
        withExtendedLifetime(controller) { app.run() }
    }
}
