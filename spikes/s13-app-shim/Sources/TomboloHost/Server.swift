// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S13: the host side of the shim IPC — rendezvous, per-shim sessions, frame production, stats.
import AppKit
import CShimIPC
import IOSurface
import ShimCommon

struct HostConfig {
    var apps: [AppSpec] = [AppSpec(package: "com.example.chat", name: "Chat"),
                           AppSpec(package: "org.example.maps", name: "Maps")]
    var fps = 60
    var width = 720, height = 1560
    var mode = FrameMode.ring
    var ringCount = 3
    var duration: Double = 0
    var warmup: Double = 2
    var launch = true
    var generateOnly = false
    var forceRegenerate = false
    var updateShims = true
    var selftestEvents = false
    var launchedByShim: String?
    var statsPath: String?
}

struct SessionSummary: Codable {
    var package: String, sessionID: UInt32, shimPID: Int32, hostVersion: String, shimVersion: String
    var mode: String, fpsTarget: Int, width: Int, height: Int
    var endReason: String, windowSeconds: Double
    var framesSent: Int, framesAcked: Int, droppedNoFreeSlot: Int, sendErrors: Int, reclaimedSlots: Int
    var achievedFps: Double, events: Int
    var recvMs: Percentiles, commitMs: Percentiles, ackRoundTripMs: Percentiles
    var launchToHelloMs: Double?, launchToFirstCommitMs: Double?
}

final class Session {
    enum Slot { case free, inFlight(UInt64, UInt64), displayed(UInt64) } // seq, tSend

    let id: UInt32, package: String, shimVersion: String
    let port: mach_port_t, audit: [UInt32], pid: Int32
    let cfg: HostConfig, hostVersion: String, log: Log
    let queue: DispatchQueue
    let ring: SurfaceRing
    var slots: [Slot]
    var timer: DispatchSourceTimer?
    var seq: UInt64 = 0
    let startNs = nowNs()
    var windowStartNs: UInt64 { startNs + UInt64(cfg.warmup * 1e9) }
    var sent = 0, acked = 0, ackedInWindow = 0, droppedNoSlot = 0, sendErrors = 0, reclaimed = 0, events = 0
    var recv: [Double] = [], commit: [Double] = [], rtt: [Double] = []
    var launchNs: UInt64?, helloNs = nowNs(), firstCommitNs: UInt64?
    var lastAckNs: UInt64 = 0

    init(id: UInt32, package: String, shimVersion: String, port: mach_port_t, audit: [UInt32], pid: Int32,
         cfg: HostConfig, hostVersion: String, log: Log) {
        self.id = id; self.package = package; self.shimVersion = shimVersion
        self.port = port; self.audit = audit; self.pid = pid
        self.cfg = cfg; self.hostVersion = hostVersion; self.log = log
        queue = DispatchQueue(label: "host.session.\(id)", qos: .userInteractive)
        ring = SurfaceRing(width: cfg.width, height: cfg.height, count: cfg.ringCount)
        slots = Array(repeating: .free, count: cfg.ringCount)
    }

    func sendConfig() -> kern_return_t {
        var w = Writer()
        w.u32(id); w.u32(UInt32(cfg.width)); w.u32(UInt32(cfg.height)); w.u32(UInt32(cfg.fps))
        w.u32(cfg.mode.rawValue); w.u32(UInt32(cfg.ringCount)); w.str(hostVersion); w.u32(UInt32(getpid()))
        let ports = cfg.mode == .ring ? ring.surfaces.map { IOSurfaceCreateMachPort($0) } : []
        return IPC.send(port, .config, w, ports: ports, timeoutMs: 100)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let interval = 1.0 / Double(cfg.fps)
        t.schedule(deadline: .now(), repeating: interval, leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func tick() {
        let now = nowNs()
        // Reclaim slots whose ack never came (shim stalled or dropped a message) after 500 ms.
        for i in slots.indices {
            if case let .inFlight(_, ts) = slots[i], now - ts > 500_000_000 { slots[i] = .free; reclaimed += 1 }
        }
        guard let slot = slots.firstIndex(where: { if case .free = $0 { return true } else { return false } }) else {
            droppedNoSlot += 1 // latest-frame-wins: the shim is behind, skip this frame at the source
            return
        }
        seq += 1
        ring.render(slot: slot, seq: seq, title: package.split(separator: ".").last.map(String.init) ?? package,
                    subtitle: "host v\(hostVersion) · \(cfg.mode == .ring ? "ring" : "per-frame") · \(cfg.fps) fps")
        var w = Writer()
        let tSend = nowNs()
        w.u64(seq); w.u32(UInt32(slot)); w.u64(tSend)
        let ports = cfg.mode == .perFrame ? [IOSurfaceCreateMachPort(ring.surfaces[slot])] : []
        let kr = IPC.send(port, .frame, w, ports: ports, timeoutMs: 0)
        if kr == KERN_SUCCESS {
            sent += 1
            slots[slot] = .inFlight(seq, tSend)
        } else {
            sendErrors += 1
            if sendErrors <= 3 { log("session \(id) frame send failed: \(IPC.err(kr))") }
        }
    }

    func onAck(seq ackSeq: UInt64, slot: Int, tSend: UInt64, tRecv: UInt64, tCommit: UInt64) {
        let now = nowNs()
        guard slot >= 0, slot < slots.count else { return }
        acked += 1
        lastAckNs = now
        if firstCommitNs == nil { firstCommitNs = tCommit }
        // The newly displayed surface stays locked; the previously displayed one becomes writable again.
        for i in slots.indices where i != slot {
            if case .displayed = slots[i] { slots[i] = .free }
        }
        slots[slot] = .displayed(ackSeq)
        if tSend >= windowStartNs {
            ackedInWindow += 1
            recv.append(Double(tRecv &- tSend) / 1e6)
            commit.append(Double(tCommit &- tSend) / 1e6)
            rtt.append(Double(now &- tSend) / 1e6)
        }
    }

    func stop() { timer?.cancel(); timer = nil }

    func summary(endReason: String) -> SessionSummary {
        let end = nowNs()
        let window = max(0, Double(Int64(end) - Int64(windowStartNs)) / 1e9)
        return SessionSummary(
            package: package, sessionID: id, shimPID: pid, hostVersion: hostVersion, shimVersion: shimVersion,
            mode: cfg.mode == .ring ? "ring" : "per-frame", fpsTarget: cfg.fps, width: cfg.width, height: cfg.height,
            endReason: endReason, windowSeconds: window, framesSent: sent, framesAcked: acked,
            droppedNoFreeSlot: droppedNoSlot, sendErrors: sendErrors, reclaimedSlots: reclaimed,
            achievedFps: window > 0 ? Double(ackedInWindow) / window : 0, events: events,
            recvMs: Percentiles(recv), commitMs: Percentiles(commit), ackRoundTripMs: Percentiles(rtt),
            launchToHelloMs: launchNs.map { Double(helloNs - $0) / 1e6 },
            launchToFirstCommitMs: launchNs.flatMap { l in firstCommitNs.map { Double($0 &- l) / 1e6 } })
    }
}

final class Server {
    let log: Log, cfg: HostConfig, gen: Generator, hostVersion: String
    private(set) var servicePort = mach_port_t(MACH_PORT_NULL)
    private var notifyPort = mach_port_t(MACH_PORT_NULL)
    private var sources: [DispatchSourceMachReceive] = []
    let ipc = DispatchQueue(label: "host.ipc", qos: .userInteractive)
    // Everything below is confined to `ipc`.
    private var sessions: [UInt32: Session] = [:]
    private var byPort: [mach_port_t: UInt32] = [:]
    private var nextID: UInt32 = 1
    private var launchTimes: [String: UInt64] = [:]
    private(set) var finished: [SessionSummary] = []
    var onRestartForUpdate: ((String, pid_t) -> Void)?

    init(log: Log, cfg: HostConfig, gen: Generator, hostVersion: String) {
        self.log = log; self.cfg = cfg; self.gen = gen; self.hostVersion = hostVersion
    }

    /// Claim the rendezvous name. A second host instance (or a stale one that is still exiting) holds it → retry, then give up.
    func start() -> Bool {
        var kr: kern_return_t = KERN_FAILURE
        for attempt in 0..<30 {
            kr = sipc_checkin(S13.serviceName, &servicePort)
            if kr == KERN_SUCCESS { break }
            if attempt == 0 { log("bootstrap_check_in(\(S13.serviceName)) = \(kr) \(String(cString: sipc_bootstrap_strerror(kr))); retrying") }
            usleep(100_000)
        }
        guard kr == KERN_SUCCESS else { log("could not claim service name; another host is running?"); return false }
        sipc_set_qlimit(servicePort, 1024)
        sipc_make_port(&notifyPort, 64)
        for (port, handler) in [(servicePort, handleService), (notifyPort, handleNotify)] as [(mach_port_t, (Incoming) -> Void)] {
            let src = DispatchSource.makeMachReceiveSource(port: port, queue: ipc)
            src.setEventHandler { IPC.drain(port, handler) }
            src.resume()
            sources.append(src)
        }
        log("claimed dynamic bootstrap name \(S13.serviceName) (port \(servicePort)); posting \(S13.hostReadyNotification)")
        sipc_notify_post(S13.hostReadyNotification)
        return true
    }

    func noteLaunch(_ package: String, at t: UInt64) { ipc.async { self.launchTimes[package] = t } }

    var statusText: String {
        ipc.sync {
            let lines = sessions.values.sorted { $0.id < $1.id }.map { s in
                s.queue.sync { "• \(s.package) [pid \(s.pid)] sent \(s.sent) acked \(s.acked) skipped \(s.droppedNoSlot)" }
            }
            return lines.isEmpty ? "No shims connected" : lines.joined(separator: "\n")
        }
    }

    // MARK: Incoming

    private func handleService(_ m: Incoming) {
        guard let id = MsgID(rawValue: m.id) else {
            log("ignored unknown msgid \(m.id) from pid \(m.senderPID)")
            if m.replyPort != MACH_PORT_NULL { sipc_release(m.replyPort) }
            return
        }
        switch id {
        case .hello: hello(m)
        case .ack: ack(m)
        case .event: event(m)
        case .bye: bye(m)
        default: log("unexpected \(id) from pid \(m.senderPID)")
        }
        // Shims never send port rights except the reply port in hello; drop anything else so nothing leaks.
        m.ports.forEach { sipc_release($0) }
        if id != .hello, m.replyPort != MACH_PORT_NULL { sipc_release(m.replyPort) }
    }

    private func handleNotify(_ m: Incoming) {
        guard m.isKernelNotification else { log("ignored non-kernel message on notify port from pid \(m.senderPID)"); return }
        if m.id == Int32(SIPC_NOTIFY_DEAD_NAME), let sid = byPort[m.notifyName] {
            end(sid, reason: "shim process died (dead-name notification)")
        }
        sipc_release(m.notifyName) // the notification carries its own dead-name reference
    }

    private func hello(_ m: Incoming) {
        var r = m.reader
        let proto = r.u32(), package = r.str(), shimVersion = r.str(), pid = Int32(bitPattern: r.u32())
        let reply = m.replyPort
        guard reply != MACH_PORT_NULL else { log("hello without reply port from pid \(m.senderPID)"); return }
        func reject(_ why: String) {
            log("REJECT hello from pid \(m.senderPID) package=\(package): \(why)")
            var w = Writer(); w.str(why)
            IPC.send(reply, .reject, w, timeoutMs: 50)
            sipc_release(reply)
        }
        guard proto == S13.protocolVersion else { return reject("protocol \(proto) != \(S13.protocolVersion)") }
        guard m.senderPID == pid else { return reject("pid in payload \(pid) != audit pid \(m.senderPID)") }
        // Only accept the exact bundles this host generated: pin the ad-hoc cdhash recorded at generation time.
        guard let rec = gen.store[package] else { return reject("unknown package") }
        let requirement = "identifier \"\(rec.bundleID)\" and cdhash H\"\(rec.cdhash)\""
        let (ok, peer) = CodeSign.check(audit: m.audit, requirement: requirement)
        guard ok else { return reject("code requirement failed: \(peer)") }

        if shimVersion != gen.shimBuild, cfg.updateShims {
            log("shim \(package) pid \(pid) is v\(shimVersion), host installs v\(gen.shimBuild): asking it to restart for update")
            IPC.send(reply, .restartForUpdate, timeoutMs: 50)
            sipc_release(reply)
            let cb = onRestartForUpdate
            DispatchQueue.main.async { cb?(package, pid) }
            return
        }
        let sid = nextID; nextID += 1
        let s = Session(id: sid, package: package, shimVersion: shimVersion, port: reply, audit: m.audit, pid: pid,
                        cfg: cfg, hostVersion: hostVersion, log: log)
        s.launchNs = launchTimes.removeValue(forKey: package)
        let kr = sipc_request_dead_name(reply, notifyPort)
        let ckr = s.sendConfig()
        guard ckr == KERN_SUCCESS else { log("config send failed: \(IPC.err(ckr))"); sipc_release(reply); return }
        sessions[sid] = s
        byPort[reply] = sid
        log("session \(sid) up: \(package) pid \(pid) shim v\(shimVersion) peer[\(peer)] deadNameReq=\(kr)"
            + (s.launchNs.map { String(format: " launch→hello %.1f ms", Double(s.helloNs - $0) / 1e6) } ?? ""))
        s.start()
    }

    private func session(for m: Incoming, _ r: inout Reader) -> Session? {
        let sid = r.u32()
        guard let s = sessions[sid] else { return nil }
        // Every message must come from the process that opened the session (full audit token, incl. pid version).
        guard s.audit == m.audit else { log("dropped msg \(m.id) for session \(sid) from foreign pid \(m.senderPID)"); return nil }
        return s
    }

    private func ack(_ m: Incoming) {
        var r = m.reader
        guard let s = session(for: m, &r) else { return }
        let seq = r.u64(), slot = Int(r.u32()), tSend = r.u64(), tRecv = r.u64(), tCommit = r.u64()
        s.queue.async { s.onAck(seq: seq, slot: slot, tSend: tSend, tRecv: tRecv, tCommit: tCommit) }
    }

    private func event(_ m: Incoming) {
        var r = m.reader
        guard let s = session(for: m, &r) else { return }
        let kind = EventKind(rawValue: r.u32()), x = r.f64(), y = r.f64(), dx = r.f64(), dy = r.f64()
        let key = r.u32(), mods = r.u64(), chars = r.str(), t = r.u64()
        s.queue.async { s.events += 1 }
        log(String(format: "event session=%u pkg=%@ kind=%@ x=%.3f y=%.3f dx=%.1f dy=%.1f key=%u mods=0x%llx chars=%@ ipc=%.3f ms",
                   s.id, s.package, "\(kind.map { "\($0)" } ?? "?")", x, y, dx, dy, key, mods, chars.debugDescription,
                   Double(nowNs() &- t) / 1e6))
    }

    private func bye(_ m: Incoming) {
        var r = m.reader
        let sid = r.u32()
        let reason = ByeReason(rawValue: r.u32())?.text ?? "?"
        guard let s = sessions[sid], s.audit == m.audit else { log("bye (\(reason)) from pid \(m.senderPID) without session"); return }
        end(sid, reason: "shim said bye: \(reason)")
    }

    private func end(_ sid: UInt32, reason: String) {
        guard let s = sessions.removeValue(forKey: sid) else { return }
        byPort.removeValue(forKey: s.port)
        let sum = s.queue.sync { s.stop(); return s.summary(endReason: reason) }
        sipc_release(s.port)
        finished.append(sum)
        log("session \(sid) (\(s.package)) ended: \(reason); recv \(sum.recvMs.text); commit \(sum.commitMs.text); fps \(String(format: "%.1f", sum.achievedFps))")
    }

    /// Graceful host quit: tell every shim, collect stats.
    func shutdown() -> [SessionSummary] {
        ipc.sync {
            for (sid, s) in sessions {
                s.queue.sync { s.stop() }
                var w = Writer(); w.u32(sid); w.u32(ByeReason.hostQuit.rawValue)
                IPC.send(s.port, .bye, w, timeoutMs: 50)
                finished.append(s.queue.sync { s.summary(endReason: "host quit") })
                sipc_release(s.port)
            }
            sessions.removeAll(); byPort.removeAll()
            return finished
        }
    }
}
