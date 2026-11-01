// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S2: thin AppKit front end over MirrorCore — one window that mirrors the phone. See README.md.
import AppKit
import MirrorCore

let usage = """
usage: s02-mirror --server PATH [options]
  --server PATH        scrcpy-server v\(ScrcpyServerPin.version) file (run.sh passes it; see scripts/fetch-server.sh)
  --serial SERIAL      device (default: $ANDROID_SERIAL, else the only device)
  --adb PATH           adb executable (default: $ADB, ~/Library/Android/sdk/platform-tools/adb, $PATH)
  --presenter KIND     metal (default: VideoToolbox → Metal on CAMetalDisplayLink) | sbdl (AVSampleBufferDisplayLayer)
  --max-size N         larger video dimension, 0 = native (default 2400 → 1080×2400 on a 1220×2712 panel)
  --max-fps N          encoder frame-rate cap (default 60)
  --bit-rate N         video bit rate in bit/s (default 8000000)
  --codec-options S    MediaCodec options passed to the server (scrcpy syntax, e.g. i-frame-interval=1)
  --encoder NAME       a specific Android encoder (default: the server's choice)
  --no-control         don't open the control socket
  --stay-awake         keep the phone awake while plugged in, for this session only (server restores it)
  --frame-latency N    CAMetalDisplayLink preferredFrameLatency (default 1)
  --metal-pacing P     displaylink (default: draw on CAMetalDisplayLink updates) | immediate (draw on decode)
  --redraw-every-update  diagnostics: re-present the last frame on every display-link update
  --frame-rate MIN:MAX:PREF  CAMetalDisplayLink preferredFrameRateRange (default 60:120:120)
  --height PT          initial window content height in points (default: 85 % of the screen)
  --at X,Y             window origin (bottom-left, points)
  --float              keep the window above others (for latency captures)
  --title TEXT         window title prefix (default "Tombolo S2 mirror")
  --duration S         quit after S seconds of streaming
  --stats-json PATH    write Mac-side pipeline statistics as JSON on exit
  --stats-every S      print statistics to stderr every S seconds (default 5, 0 = off)
  --server-log         echo the scrcpy-server output
  --synthetic WxH      no phone: stream a VideoToolbox-encoded test pattern through a local fake server
  --port N             no adb: connect to a scrcpy-compatible server already listening on 127.0.0.1:N
  --serve-synthetic WxH  headless: run only the fake server (prints its port), for a second s02-mirror --port
"""

struct Options {
    var serverPath: String?
    var serial: String?
    var adb: String?
    var presenter = PresenterKind.metal
    var maxSize = 2400, maxFps = 60, bitRate = 8_000_000
    var codecOptions: String?, encoder: String?
    var control = true, stayAwake = false
    var frameLatency: Float = 1
    var metalPacing = MetalPresenterView.Pacing.displayLink
    var redrawEveryUpdate = false
    var frameRate: [Float]?
    var height: CGFloat?
    var at: CGPoint?
    var float = false
    var title = "Tombolo S2 mirror"
    var duration: Double?
    var statsJSON: String?
    var statsEvery: Double = 5
    var serverLog = false
    var synthetic: (Int, Int)?
    var port: UInt16?
    var serveSynthetic: (Int, Int)?
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("s02-mirror: " + msg + "\n").data(using: .utf8)!)
    exit(2)
}

func parse() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    func val(_ flag: String) -> String { guard let v = it.next() else { fail("\(flag) needs a value") }; return v }
    func int(_ flag: String) -> Int { guard let v = Int(val(flag)) else { fail("\(flag) needs an integer") }; return v }
    while let a = it.next() {
        switch a {
        case "--server": o.serverPath = val(a)
        case "--serial": o.serial = val(a)
        case "--adb": o.adb = val(a)
        case "--presenter":
            let v = val(a)
            guard let k = PresenterKind(rawValue: v) else { fail("--presenter must be metal or sbdl, got \(v)") }
            o.presenter = k
        case "--max-size": o.maxSize = int(a)
        case "--max-fps": o.maxFps = int(a)
        case "--bit-rate": o.bitRate = int(a)
        case "--codec-options": o.codecOptions = val(a)
        case "--encoder": o.encoder = val(a)
        case "--no-control": o.control = false
        case "--stay-awake": o.stayAwake = true
        case "--frame-latency": o.frameLatency = Float(val(a)) ?? 1
        case "--metal-pacing":
            let v = val(a)
            guard let p = MetalPresenterView.Pacing(rawValue: v) else { fail("--metal-pacing must be displaylink or immediate, got \(v)") }
            o.metalPacing = p
        case "--redraw-every-update": o.redrawEveryUpdate = true
        case "--frame-rate":
            let p = val(a).split(separator: ":").compactMap { Float($0) }
            guard p.count == 3 else { fail("--frame-rate MIN:MAX:PREF") }
            o.frameRate = p
        case "--height": o.height = CGFloat(Double(val(a)) ?? 800)
        case "--at":
            let p = val(a).split(separator: ",").compactMap { Double($0) }
            guard p.count == 2 else { fail("--at X,Y") }
            o.at = CGPoint(x: p[0], y: p[1])
        case "--float": o.float = true
        case "--title": o.title = val(a)
        case "--duration": o.duration = Double(val(a))
        case "--stats-json": o.statsJSON = val(a)
        case "--stats-every": o.statsEvery = Double(val(a)) ?? 5
        case "--server-log": o.serverLog = true
        case "--synthetic":
            let p = val(a).lowercased().split(separator: "x").compactMap { Int($0) }
            guard p.count == 2 else { fail("--synthetic WxH") }
            o.synthetic = (p[0], p[1])
        case "--port":
            guard let p = UInt16(val(a)) else { fail("--port N") }
            o.port = p
        case "--serve-synthetic":
            let p = val(a).lowercased().split(separator: "x").compactMap { Int($0) }
            guard p.count == 2 else { fail("--serve-synthetic WxH") }
            o.serveSynthetic = (p[0], p[1])
        case "-h", "--help": print(usage); exit(0)
        default: fail("unknown option \(a)\n\(usage)")
        }
    }
    if o.serverPath == nil && o.synthetic == nil && o.port == nil && o.serveSynthetic == nil { fail("--server PATH is required (run.sh passes it)\n\(usage)") }
    return o
}

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, @unchecked Sendable {
    let opts: Options
    var window: NSWindow!
    var view: (NSView & FramePresenter)!
    var session: MirrorSession!
    var synthetic: SyntheticScrcpyServer?
    var statsTimer: Timer?
    var startedAt: Date?
    var finished = false
    var signalSources: [DispatchSourceSignal] = []

    init(opts: Options) { self.opts = opts }

    var presenterLabel: String {
        opts.presenter == .metal ? "metal-\(opts.metalPacing.rawValue)" : opts.presenter.rawValue
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let h = opts.height ?? floor(screen.height * 0.85)
        let w = floor(h * 1080 / 2400)
        do {
            view = try opts.presenter.makeView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        } catch { fail("presenter: \(error)") }
        if let m = view as? MetalPresenterView {
            m.preferredFrameLatency = opts.frameLatency
            m.pacing = opts.metalPacing
            m.redrawEveryUpdate = opts.redrawEveryUpdate
            if let r = opts.frameRate { m.preferredFrameRateRange = CAFrameRateRange(minimum: r[0], maximum: r[1], preferred: r[2]) }
            m.onDiagnostic = { log("metal: " + $0) }
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "\(opts.title) (\(presenterLabel)) — connecting…"
        window.contentView = view
        window.backgroundColor = .black
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .participatesInCycle]
        if opts.float {
            // Above other windows and on every Space, so a Space switch can't hide it mid-capture.
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        }
        if let at = opts.at { window.setFrameOrigin(at) } else { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in self?.finish(code: 0, reason: "signal \(sig)") }
            s.resume()
            signalSources.append(s)
        }
        startSession()
    }

    func startSession() {
        var server = ServerOptions()
        server.maxSize = opts.maxSize
        server.maxFps = opts.maxFps
        server.videoBitRate = opts.bitRate
        server.videoCodecOptions = opts.codecOptions
        server.videoEncoder = opts.encoder
        server.control = opts.control
        server.stayAwake = opts.stayAwake
        var cfg = MirrorSession.Configuration(serverPath: opts.serverPath ?? "", server: server)
        cfg.serial = opts.serial
        cfg.adbPath = opts.adb
        if let p = opts.port { cfg.existingTunnelPort = p }
        if let (w, h) = opts.synthetic {
            do {
                let s = try SyntheticScrcpyServer(width: w, height: h, fps: max(1, opts.maxFps), expectControl: opts.control)
                s.serve()
                synthetic = s
                cfg.existingTunnelPort = s.port
            } catch { fail("synthetic source: \(error)") }
        }
        let s = MirrorSession(configuration: cfg)
        session = s
        s.presenter = view
        if opts.serverLog { s.onServerOutput = { log("[server] " + $0) } }
        s.onVideoSession = { [weak self] info in
            DispatchQueue.main.async { self?.applyVideoSize(info) }
        }
        s.onEnded = { [weak self] err in
            DispatchQueue.main.async {
                if let e = err { log("s02-mirror: session ended: \(e)") }
                self?.finish(code: err == nil ? 0 : 1, reason: err.map { "\($0)" } ?? "stopped")
            }
        }
        log("s02-mirror: presenter=\(presenterLabel) server args: \((try? server.remoteCommand().joined(separator: " ")) ?? "?")")
        s.start { [weak self] err in
            DispatchQueue.main.async {
                guard let self else { return }
                if let e = err {
                    log("s02-mirror: could not start: \(e)")
                    self.finish(code: 1, reason: "start failed")
                    return
                }
                self.started()
            }
        }
    }

    func started() {
        startedAt = Date()
        let dev = session.device.map { "\($0.serial)\($0.isUSB ? " usb" : "")" } ?? "no adb"
        log("s02-mirror: streaming from \"\(session.deviceName)\" (\(dev))")
        window.title = "\(opts.title) (\(presenterLabel)) — \(session.deviceName)"
        if opts.statsEvery > 0 {
            statsTimer = Timer.scheduledTimer(withTimeInterval: opts.statsEvery, repeats: true) { [weak self] _ in self?.printStats() }
        }
        if let d = opts.duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.finish(code: 0, reason: "duration reached") }
        }
    }

    func applyVideoSize(_ info: VideoSessionInfo) {
        log("s02-mirror: video \(info.width)x\(info.height)\(info.clientResized ? " (client resized)" : "")")
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxH = opts.height ?? floor(screen.height * 0.85)
        let maxW = floor(screen.width * 0.9)
        let fit = MirrorGeometry.aspectFit(content: CGSize(width: info.width, height: info.height),
                                           in: CGRect(x: 0, y: 0, width: maxW, height: maxH))
        let size = NSSize(width: floor(fit.width), height: floor(fit.height))
        window.contentAspectRatio = NSSize(width: info.width, height: info.height)
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setContentSize(size)
        if opts.at == nil { window.setFrameTopLeftPoint(topLeft) }
    }

    func printStats() {
        let s = session.stats.snapshot()
        let ticks = (view as? MetalPresenterView).map { " ticks \($0.ticks)" } ?? ""
        let occluded = window.occlusionState.contains(.visible) ? "" : " WINDOW-OCCLUDED"
        log(String(format: "stats: %.0fs fps %.1f %.2f Mb/s decoded %d presented %d superseded %d | recv→decoded p50 %.2f p95 %.2f | recv→presented p50 %.2f p95 %.2f ms | jitter p95 %.2f ms | cpu %.1f%%",
                   s.seconds, s.receivedFps, s.megabitsPerSecond, s.decoded, s.presented, s.superseded,
                   s.receiveToDecodedMs.p50, s.receiveToDecodedMs.p95, s.receiveToPresentedMs.p50, s.receiveToPresentedMs.p95,
                   s.arrivalJitterMs.p95, s.processCPUCores * 100) + ticks + occluded)
    }

    func windowDidChangeOcclusionState(_ n: Notification) {
        log("s02-mirror: window occlusion state → \(window.occlusionState.contains(.visible) ? "visible" : "occluded")")
    }

    func finish(code: Int32, reason: String) {
        guard !finished else { return }
        finished = true
        statsTimer?.invalidate()
        if let s = session {
            s.onEnded = nil
            s.stop()
            printStats()
            if let path = opts.statsJSON {
                struct Report: Encodable {
                    var presenter: String, reason: String, device: String, serial: String?, video: String?
                    var serverArguments: [String], synthetic: Bool, streamingSeconds: Double?
                    var stats: PipelineStats.Snapshot
                    var metalDisplayLinkTicks: Int?, sampleBufferFlushes: Int?
                }
                let v = s.videoSession.map { "\($0.width)x\($0.height)" }
                let r = Report(presenter: presenterLabel, reason: reason, device: s.deviceName, serial: s.device?.serial,
                               video: v, serverArguments: s.configuration.server.arguments, synthetic: opts.synthetic != nil,
                               streamingSeconds: startedAt.map { Date().timeIntervalSince($0) }, stats: s.stats.snapshot(),
                               metalDisplayLinkTicks: (view as? MetalPresenterView)?.ticks,
                               sampleBufferFlushes: (view as? SampleBufferPresenterView)?.flushes)
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
                if let d = try? enc.encode(r) { try? d.write(to: URL(fileURLWithPath: path)) }
            }
        }
        view?.shutdown()
        synthetic?.stop()
        log("s02-mirror: exit (\(reason))")
        exit(code)
    }

    func windowWillClose(_ n: Notification) { finish(code: 0, reason: "window closed") }
    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        finish(code: 0, reason: "quit")
        return .terminateNow
    }
}

let opts = parse()
if let (w, h) = opts.serveSynthetic {
    // Headless fake scrcpy-server: one client session at --max-fps, until SIGTERM/SIGINT.
    do {
        let srv = try SyntheticScrcpyServer(width: w, height: h, fps: max(1, opts.maxFps), expectControl: opts.control)
        print(srv.port)
        fflush(stdout)
        srv.serve()
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { srv.stop(); exit(0) }
            src.resume()
            sources.append(src)
        }
        withExtendedLifetime(sources) { dispatchMain() }
    } catch { fail("synthetic server: \(error)") }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = AppController(opts: opts)
app.delegate = controller
// Minimal menu so ⌘Q works.
let mainMenu = NSMenu()
let appItem = NSMenuItem()
mainMenu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit s02-mirror", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu
app.mainMenu = mainMenu
app.run()
