// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S13 app shim: one NSWindow that shows IOSurface frames from the Tombolo host and forwards input.
// The same executable is copied into every generated shim bundle; per-app identity comes from Info.plist.
//
//   (inside a generated bundle)  launched by LaunchServices; optional --selftest-events
//   (bare template, for tests)   tombolo-shim --package com.example.chat [--exit-after S]
import AppKit
import CShimIPC
import IOSurface
import ShimCommon

let info = Bundle.main.infoDictionary ?? [:]
let args = CommandLine.arguments
func argValue(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

let package = info["TomboloPackage"] as? String ?? argValue("--package") ?? "unknown"
let appName = info["CFBundleName"] as? String ?? package
let shimVersion = info["TomboloShimVersion"] as? String ?? "dev"
let hostBundleID = info["TomboloHostBundleID"] as? String ?? S13.hostBundleID
let serviceName = info["TomboloServiceName"] as? String ?? S13.serviceName
let log = Log(name: "shim-\(package)", tag: "shim \(package)")

// MARK: - View

final class FrameView: NSView {
    let content = CALayer(), dim = CALayer(), text = CATextLayer()
    var frameSize = CGSize(width: 720, height: 1560)
    var onEvent: ((EventKind, CGPoint, CGFloat, CGFloat, NSEvent) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer!.backgroundColor = NSColor.black.cgColor
        content.contentsGravity = .resizeAspect
        dim.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        text.alignmentMode = .center
        text.isWrapped = true
        text.fontSize = 15
        text.foregroundColor = NSColor.white.cgColor
        for l in [content, dim, text] { layer!.addSublayer(l) }
        setStatus("Connecting to Tombolo…")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        content.frame = bounds; dim.frame = bounds
        text.frame = bounds.insetBy(dx: 20, dy: bounds.height / 2 - 40)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        content.contentsScale = s; text.contentsScale = s
    }

    /// nil = connected (hide overlay); otherwise dim the last frame and show the message.
    func setStatus(_ msg: String?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dim.isHidden = msg == nil; text.isHidden = msg == nil
        text.string = msg ?? ""
        CATransaction.commit()
    }

    func show(_ surface: IOSurface) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        content.contents = surface // zero-copy: WindowServer composites the IOSurface directly
        CATransaction.commit()
        CATransaction.flush()
    }

    /// Point in the frame's pixel space normalised to 0…1, origin top-left (Android convention).
    func normalized(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        let scale = min(bounds.width / frameSize.width, bounds.height / frameSize.height)
        let w = frameSize.width * scale, h = frameSize.height * scale
        let x0 = (bounds.width - w) / 2, y0 = (bounds.height - h) / 2
        return CGPoint(x: (p.x - x0) / w, y: 1 - (p.y - y0) / h)
    }

    private func fwd(_ k: EventKind, _ e: NSEvent, dx: CGFloat = 0, dy: CGFloat = 0) { onEvent?(k, normalized(e), dx, dy, e) }
    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); fwd(.mouseDown, e) }
    override func mouseDragged(with e: NSEvent) { fwd(.mouseDragged, e) }
    override func mouseUp(with e: NSEvent) { fwd(.mouseUp, e) }
    override func rightMouseDown(with e: NSEvent) { fwd(.rightMouseDown, e) }
    override func scrollWheel(with e: NSEvent) { fwd(.scroll, e, dx: e.scrollingDeltaX, dy: e.scrollingDeltaY) }
    override func magnify(with e: NSEvent) { fwd(.magnify, e, dx: e.magnification) }
    override func keyDown(with e: NSEvent) { fwd(.keyDown, e) }
    override func keyUp(with e: NSEvent) { fwd(.keyUp, e) }
}

// MARK: - Client

final class ShimClient {
    enum State { case disconnected, helloSent, connected(UInt32) }
    var state = State.disconnected
    var hostPort = mach_port_t(MACH_PORT_NULL)
    var myPort = mach_port_t(MACH_PORT_NULL)
    var surfaces: [IOSurface] = []
    var lastSurface: IOSurface?
    var source: DispatchSourceMachReceive?
    var retryTimer: Timer?
    var helloTimeout: DispatchWorkItem?
    var activity: NSObjectProtocol?
    var triedLaunchingHost = false
    var frames = 0
    var disconnectedAtNs: UInt64?
    let view: FrameView
    weak var window: NSWindow?
    var onConnected: (() -> Void)?

    init(view: FrameView) {
        self.view = view
        sipc_make_port(&myPort, 64)
        // Receive on the main queue: frames go straight onto the layer, no extra thread hop.
        let src = DispatchSource.makeMachReceiveSource(port: myPort, queue: .main)
        let port = myPort
        src.setEventHandler { [weak self] in IPC.drain(port) { self?.handle($0) } }
        src.resume()
        source = src
        // The host posts this as soon as it has claimed its name → reconnect without waiting for the poll.
        _ = sipc_notify_register(S13.hostReadyNotification, .main) { [weak self] in
            log("host-ready notification")
            if case .disconnected = self?.state { self?.connect() }
        }
        view.onEvent = { [weak self] k, p, dx, dy, e in self?.sendEvent(k, p, dx, dy, e) }
    }

    func connect() {
        guard case .disconnected = state else { return }
        var port = mach_port_t(MACH_PORT_NULL)
        let kr = sipc_lookup(serviceName, &port)
        // Only a cold start (first attempt of this process) may start the host; after a disconnect the user
        // may have quit Tombolo on purpose, so just wait.
        let first = !triedLaunchingHost
        triedLaunchingHost = true
        guard kr == KERN_SUCCESS else {
            if first { launchHost() }
            scheduleRetry()
            return
        }
        hostPort = port
        sipc_request_dead_name(hostPort, myPort)
        var w = Writer()
        w.u32(S13.protocolVersion); w.str(package); w.str(shimVersion); w.u32(UInt32(getpid()))
        let skr = IPC.send(hostPort, .hello, w, reply: myPort, timeoutMs: 200)
        guard skr == KERN_SUCCESS else {
            log("hello send failed: \(IPC.err(skr))")
            drop(reason: "hello failed")
            return
        }
        state = .helloSent
        let to = DispatchWorkItem { [weak self] in
            guard let self, case .helloSent = self.state else { return }
            log("no config within 3 s"); self.drop(reason: "host did not answer")
        }
        helloTimeout = to
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: to)
    }

    /// Cold start from Dock/Spotlight while Tombolo is not running: start the host via LaunchServices.
    func launchHost() {
        guard !args.contains("--no-launch-host"),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: hostBundleID) else {
            log("host not running and not launchable (bundle \(hostBundleID) unknown to LaunchServices)")
            view.setStatus("Tombolo is not running.\nWaiting…")
            return
        }
        log("host not running; launching \(url.path)")
        view.setStatus("Starting Tombolo…")
        let oc = NSWorkspace.OpenConfiguration()
        oc.activates = false
        oc.addsToRecentItems = false
        oc.arguments = ["--launched-by-shim", package]
        NSWorkspace.shared.openApplication(at: url, configuration: oc) { _, e in if let e { log("host launch failed: \(e)") } }
    }

    func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, case .disconnected = self.state else { return }
            self.connect()
        }
    }

    func drop(reason: String) {
        helloTimeout?.cancel()
        sipc_release(hostPort)
        hostPort = mach_port_t(MACH_PORT_NULL)
        surfaces = [] // the last displayed surface stays on screen, dimmed, until the host is back
        state = .disconnected
        disconnectedAtNs = nowNs()
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        view.setStatus("Disconnected — \(reason).\nWaiting for Tombolo…")
        log("disconnected: \(reason) (frames this session: \(frames))")
        scheduleRetry()
    }

    func handle(_ m: Incoming) {
        if m.isKernelNotification {
            if m.id == Int32(SIPC_NOTIFY_DEAD_NAME), m.notifyName == hostPort, hostPort != MACH_PORT_NULL {
                sipc_release(m.notifyName) // notification's own dead-name ref; drop() releases the rest
                drop(reason: "host went away")
            } else {
                sipc_release(m.notifyName)
            }
            return
        }
        defer { if m.replyPort != MACH_PORT_NULL { sipc_release(m.replyPort) } }
        guard let id = MsgID(rawValue: m.id) else { m.ports.forEach { sipc_release($0) }; return }
        switch id {
        case .config: config(m)
        case .frame: frame(m)
        case .bye:
            var r = m.reader; _ = r.u32()
            drop(reason: ByeReason(rawValue: r.u32())?.text ?? "bye")
        case .reject:
            var r = m.reader
            log("REJECTED by host: \(r.str())")
            drop(reason: "rejected by host")
            if args.contains("--exit-after") { exit(4) }
        case .restartForUpdate:
            log("host asked us to restart for an update")
            var w = Writer(); w.u32(0); w.u32(ByeReason.update.rawValue)
            IPC.send(hostPort, .bye, w, timeoutMs: 50)
            exit(0)
        default: m.ports.forEach { sipc_release($0) }
        }
    }

    private func config(_ m: Incoming) {
        var r = m.reader
        let sid = r.u32(), w = r.u32(), h = r.u32(), fps = r.u32(), mode = r.u32(), ringCount = r.u32()
        let hostVer = r.str(), hostPID = r.u32()
        // Ad-hoc signatures carry only a self-declared identifier, so this proves little; with the stable
        // self-signed identity from P0-10 this becomes `certificate leaf = H"…"`.
        let (ok, peer) = CodeSign.check(audit: m.audit, requirement: "identifier \"\(hostBundleID)\"")
        guard ok, Int32(hostPID) == m.senderPID else {
            log("host failed verification: \(peer)")
            m.ports.forEach { sipc_release($0) }
            drop(reason: "host failed verification")
            return
        }
        helloTimeout?.cancel()
        surfaces = m.ports.compactMap { p in defer { sipc_release(p) }; return IOSurfaceLookupFromMachPort(p) }
        view.frameSize = CGSize(width: Int(w), height: Int(h))
        state = .connected(sid)
        frames = 0
        retryTimer?.invalidate(); retryTimer = nil
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "showing frames")
        view.setStatus(nil)
        let since = disconnectedAtNs.map { String(format: " %.1f ms after disconnect", Double(nowNs() - $0) / 1e6) } ?? ""
        log("connected: session \(sid) \(w)x\(h)@\(fps) mode=\(mode == 0 ? "ring" : "per-frame") ring=\(ringCount)/\(surfaces.count) host v\(hostVer) pid \(hostPID) peer[\(peer)]\(since)")
        if let win = window {
            win.contentAspectRatio = NSSize(width: Int(w), height: Int(h))
            if !win.isVisible { win.makeKeyAndOrderFront(nil) }
        }
        onConnected?()
    }

    private func frame(_ m: Incoming) {
        let tRecv = nowNs()
        guard case let .connected(sid) = state else { m.ports.forEach { sipc_release($0) }; return }
        var r = m.reader
        let seq = r.u64(), slot = r.u32(), tSend = r.u64()
        let surface: IOSurface?
        if let p = m.ports.first {
            surface = IOSurfaceLookupFromMachPort(p) // per-frame mode: a fresh right each frame
            sipc_release(p)
        } else {
            surface = Int(slot) < surfaces.count ? surfaces[Int(slot)] : nil
        }
        guard let surface else { return }
        view.show(surface)
        lastSurface = surface
        frames += 1
        let tCommit = nowNs()
        var w = Writer()
        w.u32(sid); w.u64(seq); w.u32(slot); w.u64(tSend); w.u64(tRecv); w.u64(tCommit)
        IPC.send(hostPort, .ack, w, timeoutMs: 0)
    }

    func sendEvent(_ k: EventKind, _ p: CGPoint, _ dx: CGFloat, _ dy: CGFloat, _ e: NSEvent) {
        guard case let .connected(sid) = state else { return }
        var w = Writer()
        w.u32(sid); w.u32(k.rawValue); w.f64(p.x); w.f64(p.y); w.f64(dx); w.f64(dy)
        let isKey = e.type == .keyDown || e.type == .keyUp
        w.u32(isKey ? UInt32(e.keyCode) : 0); w.u64(UInt64(e.modifierFlags.rawValue))
        w.str(isKey ? (e.characters ?? "") : "", max: 32); w.u64(nowNs())
        IPC.send(hostPort, .event, w, timeoutMs: 0)
    }

    func goodbye(_ reason: ByeReason) {
        guard case let .connected(sid) = state else { return }
        var w = Writer(); w.u32(sid); w.u32(reason.rawValue)
        IPC.send(hostPort, .bye, w, timeoutMs: 50)
    }
}

// MARK: - App

final class ShimDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var client: ShimClient!
    var byeReason = ByeReason.shimQuit
    var selftestDone = false

    func applicationDidFinishLaunching(_ n: Notification) {
        log("shim v\(shimVersion) starting: bundle=\(Bundle.main.bundlePath) id=\(Bundle.main.bundleIdentifier ?? "-") args=\(args.dropFirst().joined(separator: " "))")
        let view = FrameView(frame: NSRect(x: 0, y: 0, width: 300, height: 650))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 650),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = appName
        window.contentView = view
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("S13Shim-\(package)")
        if window.frame.origin == .zero, let vf = NSScreen.main?.visibleFrame {
            // First launch: spread shims out (stable per package) instead of stacking them all in the centre.
            let slot = CGFloat((package.utf8.reduce(5381) { ($0 &* 33) &+ Int($1) } & 0xffff) % 5)
            window.setFrameTopLeftPoint(NSPoint(x: vf.minX + 440 + slot * 250, y: vf.maxY - 20))
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        client = ShimClient(view: view)
        client.window = window
        client.onConnected = { [weak self] in self?.maybeSelftest() }
        log("window number \(window.windowNumber)")
        client.connect()
        if let s = argValue("--exit-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { NSApp.terminate(nil) }
        }
    }

    /// Non-interactive check of the input path: synthesise events and dispatch them through the window,
    /// exactly as AppKit would deliver real HID events (no Accessibility permission needed).
    func maybeSelftest() {
        guard args.contains("--selftest-events"), !selftestDone else { return }
        selftestDone = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            guard let view = window.contentView as? FrameView else { return }
            let t = ProcessInfo.processInfo.systemUptime, wn = window.windowNumber
            let c = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            func mouse(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: t, windowNumber: wn,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            func key(_ type: NSEvent.EventType, _ ch: String, _ code: UInt16) -> NSEvent? {
                NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: t, windowNumber: wn, context: nil,
                                 characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code)
            }
            let events = [mouse(.leftMouseDown, c), mouse(.leftMouseDragged, NSPoint(x: c.x + 40, y: c.y - 60)),
                          mouse(.leftMouseUp, NSPoint(x: c.x + 40, y: c.y - 60)), key(.keyDown, "a", 0), key(.keyUp, "a", 0)]
            log("selftest: dispatching \(events.compactMap { $0 }.count) synthetic events through NSWindow.sendEvent")
            events.compactMap { $0 }.forEach { window.sendEvent($0) }
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -24, wheel2: 0, wheel3: 0),
               let s = NSEvent(cgEvent: cg) {
                view.scrollWheel(with: s) // scroll location would be global; deliver to the view directly
            }
        }
    }

    func windowWillClose(_ n: Notification) { byeReason = .windowClosed }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) {
        client.goodbye(byeReason)
        log("terminating (\(byeReason.text))")
    }
}

let app = NSApplication.shared
let delegate = ShimDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
let menu = NSMenu(), item = NSMenuItem(), sub = NSMenu()
sub.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
item.submenu = sub; menu.addItem(item); app.mainMenu = menu
app.run()
