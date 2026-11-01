// SPDX-License-Identifier: GPL-3.0-or-later
//
// A floating WebKit browser window that shows the latency page — the "mirror" in the phone-less
// self-test. It floats above other apps and joins every Space, so the self-test keeps working
// while someone uses the Mac (a normal browser window behind another app is throttled and
// cannot be captured). The page and the clock sync are exactly what a phone browser runs.

import AppKit
import WebKit

@MainActor
final class PageWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate {
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("page-window: navigation failed: \(error)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("page-window: cannot load page: \(error)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("page-window: loaded \(webView.url?.absoluteString ?? "")")
    }
}

enum PageWindow {
    @MainActor
    static func run(url: URL, title: String, duration: Double?, at: [Double]?, size: [Double]?) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let w = size?.first ?? 480, h = size.flatMap { $0.count > 1 ? $0[1] : nil } ?? 860
        let window = NSWindow(contentRect: NSRect(x: at?.first ?? 60, y: at.flatMap { $0.count > 1 ? $0[1] : nil } ?? 80, width: w, height: h),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h), configuration: config)
        let controller = PageWindowController()
        web.navigationDelegate = controller
        window.contentView = web
        window.delegate = controller
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        web.load(URLRequest(url: url))
        print("page-window: \"\(title)\" → \(url.absoluteString)")
        if let d = duration {
            Timer.scheduledTimer(withTimeInterval: d, repeats: false) { _ in
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
        }
        withExtendedLifetime(controller) { app.run() }
    }
}
