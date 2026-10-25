// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S13 "Tombolo host": generates app shims, launches them and streams synthetic frames to each.
//
//   tombolo-host [--apps pkg:Name,...] [--fps 60] [--size 720x1560] [--mode ring|perframe]
//                [--duration S] [--warmup S] [--no-launch] [--generate-only] [--force-regenerate]
//                [--no-update-shims] [--selftest-events] [--stats PATH] [--launched-by-shim PKG]
//
// SIGTERM/SIGINT or ⌘Q = graceful quit (shims are told "host quit"); SIGKILL = crash.
import AppKit
import ShimCommon

let log = Log(name: "host", tag: "host")
let hostVersion = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "dev"

func parseArgs() -> HostConfig {
    var c = HostConfig()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--apps":
            c.apps = (it.next() ?? "").split(separator: ",").map {
                let p = $0.split(separator: ":", maxSplits: 1).map(String.init)
                return AppSpec(package: p[0], name: p.count > 1 ? p[1] : p[0])
            }
        case "--fps": c.fps = Int(it.next() ?? "") ?? c.fps
        case "--size":
            let p = (it.next() ?? "").split(separator: "x").compactMap { Int($0) }
            if p.count == 2 { c.width = p[0]; c.height = p[1] }
        case "--mode": c.mode = it.next() == "perframe" ? .perFrame : .ring
        case "--duration": c.duration = Double(it.next() ?? "") ?? 0
        case "--warmup": c.warmup = Double(it.next() ?? "") ?? c.warmup
        case "--no-launch": c.launch = false
        case "--generate-only": c.generateOnly = true
        case "--force-regenerate": c.forceRegenerate = true
        case "--no-update-shims": c.updateShims = false
        case "--selftest-events": c.selftestEvents = true
        case "--stats": c.statsPath = it.next()
        case "--launched-by-shim": c.launchedByShim = it.next()
        default: break // LaunchServices may add its own arguments (e.g. -NSDocumentRevisionsDebugMode)
        }
    }
    return c
}

final class HostDelegate: NSObject, NSApplicationDelegate {
    let cfg = parseArgs()
    lazy var gen = Generator(log: log, hostVersion: hostVersion)
    lazy var server = Server(log: log, cfg: cfg, gen: gen, hostVersion: hostVersion)
    var window: NSWindow?
    var label: NSTextField?
    var signalSources: [DispatchSourceSignal] = []
    var activity: NSObjectProtocol?
    var quitting = false

    func applicationDidFinishLaunching(_ n: Notification) {
        let selfCode = CodeSign.cdhash(ofBundle: Bundle.main.bundleURL) ?? "-"
        log("host v\(hostVersion) starting; bundle=\(Bundle.main.bundlePath) cdhash=\(selfCode) args=\(CommandLine.arguments.dropFirst().joined(separator: " "))")
        if cfg.generateOnly {
            for app in cfg.apps { generateIfNeeded(app, force: cfg.forceRegenerate) }
            exit(0)
        }
        // Keep frame production out of App Nap / timer coalescing while we stream.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "streaming frames to shims")
        guard server.start() else { exit(3) }
        server.onRestartForUpdate = { [weak self] pkg, pid in self?.regenerateAfterExit(pkg, pid: pid) }
        for app in cfg.apps {
            let id = S13.bundleID(forPackage: app.package)
            let running = gen.isRunning(id)
            if running {
                log("\(app.package): shim already running; it reconnects by itself")
            } else {
                generateIfNeeded(app, force: cfg.forceRegenerate)
            }
            if cfg.launch, cfg.launchedByShim == nil, !running { launch(app) }
        }
        installSignals()
        makeWindow()
        if cfg.duration > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + cfg.duration) { [weak self] in self?.quit(reason: "duration elapsed") }
        }
    }

    func generateIfNeeded(_ app: AppSpec, force: Bool) {
        let why = force ? "forced" : gen.needsGeneration(app)
        guard let why else { log("\(app.package): shim up to date"); return }
        log("\(app.package): generating shim (\(why))")
        do { try gen.generate(app) } catch { log("generation failed for \(app.package): \(error)") }
    }

    func launch(_ app: AppSpec) {
        let url = gen.bundleURL(for: app)
        let oc = NSWorkspace.OpenConfiguration()
        oc.activates = false
        oc.addsToRecentItems = false
        if cfg.selftestEvents { oc.arguments = ["--selftest-events"] }
        let t = nowNs()
        server.noteLaunch(app.package, at: t)
        NSWorkspace.shared.openApplication(at: url, configuration: oc) { running, error in
            log(String(format: "launch %@ → pid %d error=%@ (%.1f ms)", url.lastPathComponent, running?.processIdentifier ?? -1,
                       error.map { "\($0)" } ?? "nil", Double(nowNs() - t) / 1e6))
        }
    }

    /// Host-update path: an outdated shim quits on request; regenerate its bundle and relaunch it.
    func regenerateAfterExit(_ pkg: String, pid: pid_t, attempt: Int = 0) {
        guard let app = cfg.apps.first(where: { $0.package == pkg }) ?? gen.store[pkg].map({ AppSpec(package: $0.package, name: $0.name) }) else { return }
        if kill(pid, 0) == 0, attempt < 50 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.regenerateAfterExit(pkg, pid: pid, attempt: attempt + 1) }
            return
        }
        log("\(pkg): old shim pid \(pid) exited after ~\(attempt * 100) ms; regenerating for v\(hostVersion)")
        generateIfNeeded(app, force: true)
        launch(app)
    }

    func installSignals() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in self?.quit(reason: "signal \(sig)") }
            s.resume()
            signalSources.append(s)
        }
    }

    func makeWindow() {
        let w = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 420, height: 160),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Tombolo host (spike S13) v\(hostVersion)"
        let l = NSTextField(wrappingLabelWithString: "")
        l.frame = NSRect(x: 16, y: 16, width: 388, height: 128)
        l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        w.contentView?.addSubview(l)
        w.isReleasedWhenClosed = false
        w.orderFront(nil)
        window = w; label = l
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.label?.stringValue = self.server.statusText
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quit(reason: "⌘Q / terminate")
        return .terminateCancel
    }

    func quit(reason: String) {
        guard !quitting else { return }
        quitting = true
        log("host quitting: \(reason)")
        let summaries = server.shutdown()
        for s in summaries {
            log("summary \(s.package) session \(s.sessionID): fps \(String(format: "%.1f", s.achievedFps)) recv \(s.recvMs.text) commit \(s.commitMs.text)")
        }
        if let path = cfg.statsPath {
            let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? e.encode(summaries).write(to: URL(fileURLWithPath: path))
            log("wrote \(path)")
        }
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = HostDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
let menu = NSMenu(), item = NSMenuItem(), sub = NSMenu()
sub.addItem(withTitle: "Quit Tombolo host", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
item.submenu = sub; menu.addItem(item); app.mainMenu = menu
app.run()
