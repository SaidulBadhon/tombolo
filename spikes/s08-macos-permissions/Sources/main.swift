// SPDX-License-Identifier: GPL-3.0-or-later
//
// S08/S15 spike probe — THROWAWAY spike code, never promoted to production.
//
// A menu-bar (LSUIElement) app that performs Local Network operations and logs exactly
// what happens, so we can see when macOS shows the Local Network alert and how each
// operation fails while the privilege is undetermined or denied. It also reports the
// state of grants that S15 checks across updates (Accessibility, login item) and its
// own code-signing identity.
//
// Two ways to drive it:
//   - Menu: click the "S08 …" item in the menu bar.
//   - Script: open -n "X.app" --args --run "step;step;…" [--quit] [--log path]
//     Launch through `open` (LaunchServices). Running Contents/MacOS/<exe> from a
//     terminal makes the terminal the responsible process, and Local Network privacy
//     then judges the terminal, not this app.
//
// Steps (also listed in README.md):
//   info                    signing identity, Mach-O UUID, AX + login-item status
//   listen:PORT             NWListener on TCP PORT, no Bonjour; answers "pong"
//   advertise:PORT          NWListener on TCP PORT advertised as _tombolo-test._tcp
//   browse:TYPE[:SECS]      NWBrowser for TYPE (e.g. _tombolo-test._tcp)
//   nwconnect:HOST:PORT[:SECS]   NWConnection (TCP), sends "ping", reads reply
//   bsdconnect:HOST:PORT[:SECS]  BSD socket TCP connect(), sends "ping", reads reply
//   udpconnect:HOST:PORT    BSD UDP socket connect() + send()
//   udpecho:PORT[:SECS]     BSD UDP socket bound to PORT; replies to each datagram
//   docwrite:PATH           append a line to PATH (e.g. under ~/Documents) and time it:
//                           exercises a TCC file-access grant (Documents folder) for S15
//   sleep:SECS              keep the process alive (FB16131937: no alert for short-lived processes)
//   ax | ax-prompt          AXIsProcessTrusted / ...WithOptions(prompt: true)
//   ax-wait:SECS            poll AXIsProcessTrusted every second; log changes; stop early once true
//   login-status | login-register | login-unregister   SMAppService.mainApp
//   quit

import AppKit
import ApplicationServices
import Darwin
import MachO
import Network
import Security
import ServiceManagement

// MARK: - Logging

let processStart = DispatchTime.now()

func elapsedMs(since t: DispatchTime) -> String {
    let ns = DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds
    return String(format: "%.1fms", Double(ns) / 1e6)
}

final class Log {
    static let shared = Log()
    let url: URL
    private let queue = DispatchQueue(label: "log")
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        if let path = argValue("--log") {
            url = URL(fileURLWithPath: path)
        } else {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/TomboloSpikeS08")
            url = dir.appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "unknown").log")
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
    }

    func callAsFunction(_ message: String) {
        let line = "\(formatter.string(from: Date())) +\(elapsedMs(since: processStart)) "
            + "[\(BuildInfo.variant) \(BuildInfo.version) pid \(getpid())] \(message)\n"
        queue.sync {
            FileHandle.standardError.write(line.data(using: .utf8)!)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8)!)
                try? h.close()
            } else {
                try? line.data(using: .utf8)!.write(to: url)
            }
        }
    }
}

let log = Log.shared

func argValue(_ name: String) -> String? {
    let a = ProcessInfo.processInfo.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

// MARK: - Error descriptions

func describe(_ e: NWError) -> String {
    switch e {
    case .posix(let c):
        return "posix(\(c.rawValue) \(String(cString: strerror(c.rawValue))))"
    case .dns(let c):
        return "dns(\(c)\(c == -65570 ? " = kDNSServiceErr_PolicyDenied" : ""))"
    case .tls(let s):
        return "tls(\(s))"
    default: // e.g. .wifiAware on macOS 26+ SDKs
        return "\(e)"
    }
}

func describe(_ state: NWConnection.State) -> String {
    switch state {
    case .setup: return "setup"
    case .preparing: return "preparing"
    case .ready: return "ready"
    case .cancelled: return "cancelled"
    case .waiting(let e): return "waiting(\(describe(e)))"
    case .failed(let e): return "failed(\(describe(e)))"
    @unknown default: return "\(state)"
    }
}

func describe(_ path: NWPath?) -> String {
    guard let p = path else { return "path=nil" }
    var s = "path.status=\(p.status)"
    if p.status != .satisfied { s += " unsatisfiedReason=\(p.unsatisfiedReason)" }
    if let ifc = p.availableInterfaces.first { s += " via=\(ifc.name)" }
    if let l = p.localEndpoint { s += " local=\(l)" }
    if let r = p.remoteEndpoint { s += " remote=\(r)" }
    return s
}

func errnoString(_ e: Int32) -> String { "errno \(e) \(String(cString: strerror(e)))" }

// MARK: - Probes

/// Keeps network objects alive for the life of the process.
var keepAlive: [AnyObject] = []

func signingInfo() -> String {
    var lines: [String] = []
    let b = Bundle.main
    lines.append("bundle=\(b.bundleIdentifier ?? "-") version=\(b.infoDictionary?["CFBundleShortVersionString"] ?? "-") (\(b.infoDictionary?["CFBundleVersion"] ?? "-")) path=\(b.bundlePath)")
    lines.append("machoUUID=\(mainExecutableUUID() ?? "none")")
    var code: SecCode?
    guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
        lines.append("SecCodeCopySelf failed")
        return lines.joined(separator: "\n    ")
    }
    let validity = SecCodeCheckValidity(code, SecCSFlags(), nil)
    lines.append("dynamicValidity=\(validity == errSecSuccess ? "valid" : "OSStatus \(validity)")")
    var staticCode: SecStaticCode?
    SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode)
    var infoCF: CFDictionary?
    if let staticCode,
       SecCodeCopySigningInformation(staticCode,
                                     SecCSFlags(rawValue: UInt32(kSecCSSigningInformation | kSecCSRequirementInformation)),
                                     &infoCF) == errSecSuccess,
       let info = infoCF as? [String: Any] {
        lines.append("identifier=\(info[kSecCodeInfoIdentifier as String] ?? "-") team=\(info[kSecCodeInfoTeamIdentifier as String] ?? "none")")
        if let flags = info[kSecCodeInfoFlags as String] as? NSNumber {
            lines.append(String(format: "codeFlags=0x%x", flags.uint32Value))
        }
        if let cd = info[kSecCodeInfoUnique as String] as? Data {
            lines.append("cdhash=\(cd.map { String(format: "%02x", $0) }.joined())")
        }
        if let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate] {
            lines.append("certificates=\(certs.map { SecCertificateCopySubjectSummary($0) as String? ?? "?" })")
        }
        if let anyReq = info[kSecCodeInfoDesignatedRequirement as String] {
            let req = anyReq as! SecRequirement
            var s: CFString?
            SecRequirementCopyString(req, SecCSFlags(), &s)
            lines.append("designated=\(s as String? ?? "?")")
        }
    }
    return lines.joined(separator: "\n    ")
}

func mainExecutableUUID() -> String? {
    guard let header = _dyld_get_image_header(0) else { return nil }
    var p = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
    for _ in 0..<header.pointee.ncmds {
        let lc = p.load(as: load_command.self)
        if lc.cmd == UInt32(LC_UUID) {
            let u = p.load(as: uuid_command.self).uuid
            return UUID(uuid: u).uuidString
        }
        p = p.advanced(by: Int(lc.cmdsize))
    }
    return nil
}

func loginItemStatus() -> String {
    switch SMAppService.mainApp.status {
    case .notRegistered: return "notRegistered"
    case .enabled: return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notFound: return "notFound"
    @unknown default: return "unknown(\(SMAppService.mainApp.status.rawValue))"
    }
}

func grantSummary() -> String {
    "AXIsProcessTrusted=\(AXIsProcessTrusted()) loginItem(mainApp)=\(loginItemStatus())"
}

/// TCP listener; with `advertise`, also registers _tombolo-test._tcp with Bonjour.
func startListener(port: UInt16, advertise: Bool, done: @escaping () -> Void) {
    let tag = advertise ? "advertise" : "listen"
    let started = DispatchTime.now()
    let listener: NWListener
    do {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    } catch {
        log("\(tag):\(port) create failed: \(error)")
        done(); return
    }
    if advertise {
        listener.service = NWListener.Service(name: "S08-\(BuildInfo.variant)-\(getpid())", type: "_tombolo-test._tcp")
        listener.serviceRegistrationUpdateHandler = { change in
            log("\(tag):\(port) service registration: \(change)")
        }
    }
    var finished = false
    let finish = { if !finished { finished = true; done() } }
    listener.stateUpdateHandler = { state in
        switch state {
        case .waiting(let e): log("\(tag):\(port) state=waiting(\(describe(e))) after \(elapsedMs(since: started))")
        case .failed(let e): log("\(tag):\(port) state=failed(\(describe(e))) after \(elapsedMs(since: started))"); finish()
        case .ready: log("\(tag):\(port) state=ready after \(elapsedMs(since: started))"); finish()
        default: log("\(tag):\(port) state=\(state)")
        }
    }
    listener.newConnectionHandler = { conn in
        let accepted = DispatchTime.now()
        log("\(tag):\(port) incoming connection from \(conn.endpoint)")
        conn.stateUpdateHandler = { st in
            log("\(tag):\(port) incoming \(conn.endpoint) state=\(describe(st)) after \(elapsedMs(since: accepted)) \(describe(conn.currentPath))")
            if case .ready = st {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, err in
                    if let data { log("\(tag):\(port) received \(data.count) bytes: \(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))") }
                    if let err { log("\(tag):\(port) receive error: \(describe(err))") }
                    let reply = "pong from \(BuildInfo.variant) \(BuildInfo.version)\n".data(using: .utf8)!
                    conn.send(content: reply, completion: .contentProcessed { sendErr in
                        log("\(tag):\(port) reply sent: \(sendErr.map(describe) ?? "ok")")
                        conn.cancel()
                    })
                }
            }
        }
        conn.start(queue: .main)
    }
    keepAlive.append(listener)
    listener.start(queue: .main)
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
        if !finished { log("\(tag):\(port) not ready after 8 s (state=\(listener.state))") }
        finish()
    }
}

func browse(type: String, seconds: Double, done: @escaping () -> Void) {
    let started = DispatchTime.now()
    let params: NWParameters = type.hasSuffix("._udp") ? .udp : .tcp
    let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: params)
    browser.stateUpdateHandler = { state in
        switch state {
        case .waiting(let e): log("browse \(type) state=waiting(\(describe(e))) after \(elapsedMs(since: started))")
        case .failed(let e): log("browse \(type) state=failed(\(describe(e))) after \(elapsedMs(since: started))")
        default: log("browse \(type) state=\(state) after \(elapsedMs(since: started))")
        }
    }
    browser.browseResultsChangedHandler = { results, changes in
        log("browse \(type) results=\(results.count) changes=\(changes.map { "\($0)" })")
    }
    browser.start(queue: .main)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        log("browse \(type) end after \(elapsedMs(since: started)): state=\(browser.state) results=\(browser.browseResults.count)")
        browser.cancel()
        done()
    }
}

func nwConnect(host: String, port: UInt16, seconds: Double, done: @escaping () -> Void) {
    let started = DispatchTime.now()
    let tag = "nwconnect \(host):\(port)"
    let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    var finished = false
    let finish = {
        if !finished {
            finished = true
            log("\(tag) end after \(elapsedMs(since: started)): state=\(describe(conn.state)) \(describe(conn.currentPath))")
            conn.cancel()
            done()
        }
    }
    conn.stateUpdateHandler = { state in
        log("\(tag) state=\(describe(state)) after \(elapsedMs(since: started)) \(describe(conn.currentPath))")
        switch state {
        case .ready:
            conn.send(content: "ping from \(BuildInfo.variant)\n".data(using: .utf8)!, completion: .contentProcessed { err in
                log("\(tag) send: \(err.map(describe) ?? "ok")")
            })
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, err in
                if let data { log("\(tag) reply: \(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))") }
                if let err { log("\(tag) receive error: \(describe(err))") }
                finish()
            }
        case .failed, .cancelled:
            finish()
        default: break
        }
    }
    conn.start(queue: .main)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finish() }
}

func makeSockaddr(_ host: String, _ port: UInt16) -> sockaddr_in? {
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    guard inet_pton(AF_INET, host, &a.sin_addr) == 1 else { return nil }
    return a
}

func withSockaddr<T>(_ a: sockaddr_in, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var a = a
    return withUnsafePointer(to: &a) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
}

/// Blocking work runs off the main thread; logging is thread-safe.
func bsdConnect(host: String, port: UInt16, seconds: Double, done: @escaping () -> Void) {
    DispatchQueue.global().async {
        defer { DispatchQueue.main.async(execute: done) }
        let tag = "bsdconnect \(host):\(port)"
        guard let addr = makeSockaddr(host, port) else { log("\(tag) bad IPv4 address"); return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { log("\(tag) socket(): \(errnoString(errno))"); return }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let started = DispatchTime.now()
        let r = withSockaddr(addr) { connect(fd, $0, $1) }
        var err: Int32 = r == 0 ? 0 : errno
        log("\(tag) connect() returned \(r) \(r == 0 ? "" : errnoString(err)) after \(elapsedMs(since: started))")
        if r != 0 && err == EINPROGRESS {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let n = poll(&pfd, 1, Int32(seconds * 1000))
            if n == 0 {
                log("\(tag) still connecting after \(elapsedMs(since: started)) (timeout)")
                return
            }
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
            err = soErr
            log("\(tag) completed after \(elapsedMs(since: started)): \(soErr == 0 ? "connected" : errnoString(soErr))")
        }
        guard err == 0 else { return }
        let msg = "ping from \(BuildInfo.variant) (bsd)\n"
        let sent = msg.withCString { send(fd, $0, strlen($0), 0) }
        log("\(tag) send() = \(sent)\(sent < 0 ? " " + errnoString(errno) : "")")
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = recv(fd, &buf, buf.count, 0)
        if n > 0 {
            log("\(tag) reply: \(String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            log("\(tag) recv() = \(n)\(n < 0 ? " " + errnoString(errno) : "")")
        }
    }
}

func udpConnect(host: String, port: UInt16, done: @escaping () -> Void) {
    DispatchQueue.global().async {
        defer { DispatchQueue.main.async(execute: done) }
        let tag = "udpconnect \(host):\(port)"
        guard let addr = makeSockaddr(host, port) else { log("\(tag) bad IPv4 address"); return }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { log("\(tag) socket(): \(errnoString(errno))"); return }
        defer { close(fd) }
        let r = withSockaddr(addr) { connect(fd, $0, $1) }
        log("\(tag) connect() = \(r)\(r < 0 ? " " + errnoString(errno) : "")")
        let s = "udp ping from \(BuildInfo.variant)".withCString { send(fd, $0, strlen($0), 0) }
        log("\(tag) send() = \(s)\(s < 0 ? " " + errnoString(errno) : "")")
    }
}

func udpEcho(port: UInt16, seconds: Double, ready: @escaping () -> Void) {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { log("udpecho socket(): \(errnoString(errno))"); ready(); return }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    var any = sockaddr_in()
    any.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    any.sin_family = sa_family_t(AF_INET)
    any.sin_port = port.bigEndian
    any.sin_addr.s_addr = INADDR_ANY
    let b = withSockaddr(any) { bind(fd, $0, $1) }
    log("udpecho:\(port) bind() = \(b)\(b < 0 ? " " + errnoString(errno) : "")")
    guard b == 0 else { close(fd); ready(); return }
    var tv = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    ready()
    DispatchQueue.global().async {
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(seconds)
        var buf = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &fromLen) }
            }
            if n < 0 { continue } // timeout tick
            var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &ip, socklen_t(INET_ADDRSTRLEN))
            let peer = "\(String(cString: ip)):\(UInt16(bigEndian: from.sin_port))"
            log("udpecho:\(port) received \(n) bytes from \(peer): \(String(decoding: buf[0..<n], as: UTF8.self))")
            let reply = "udp pong from \(BuildInfo.variant)"
            let s = reply.withCString { r in
                withSockaddr(from) { sendto(fd, r, strlen(r), 0, $0, $1) }
            }
            log("udpecho:\(port) reply sendto(\(peer)) = \(s)\(s < 0 ? " " + errnoString(errno) : "")")
        }
        log("udpecho:\(port) stopped after \(Int(seconds)) s")
    }
}

// MARK: - Step runner

func parseHostPort(_ parts: [Substring]) -> (String, UInt16, Double?)? {
    guard parts.count >= 3, let port = UInt16(parts[2]) else { return nil }
    return (String(parts[1]), port, parts.count > 3 ? Double(parts[3]) : nil)
}

func runStep(_ step: String, done: @escaping () -> Void) {
    let parts = step.split(separator: ":", omittingEmptySubsequences: false)
    let name = parts.first.map(String.init) ?? ""
    log("STEP \(step)")
    switch name {
    case "info":
        log("info\n    \(signingInfo())\n    \(grantSummary())")
        done()
    case "listen", "advertise":
        guard parts.count >= 2, let port = UInt16(parts[1]) else { log("bad step \(step)"); return done() }
        startListener(port: port, advertise: name == "advertise", done: done)
    case "browse":
        guard parts.count >= 2 else { log("bad step \(step)"); return done() }
        browse(type: String(parts[1]), seconds: parts.count > 2 ? Double(parts[2]) ?? 8 : 8, done: done)
    case "nwconnect":
        guard let (h, p, s) = parseHostPort(parts) else { log("bad step \(step)"); return done() }
        nwConnect(host: h, port: p, seconds: s ?? 8, done: done)
    case "bsdconnect":
        guard let (h, p, s) = parseHostPort(parts) else { log("bad step \(step)"); return done() }
        bsdConnect(host: h, port: p, seconds: s ?? 8, done: done)
    case "udpconnect":
        guard let (h, p, _) = parseHostPort(parts) else { log("bad step \(step)"); return done() }
        udpConnect(host: h, port: p, done: done)
    case "udpecho":
        guard parts.count >= 2, let port = UInt16(parts[1]) else { log("bad step \(step)"); return done() }
        udpEcho(port: port, seconds: parts.count > 2 ? Double(parts[2]) ?? 60 : 60, ready: done)
    case "docwrite":
        let path = parts.dropFirst().joined(separator: ":")
        DispatchQueue.global().async {
            let t = DispatchTime.now()
            let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            let e = errno
            if fd >= 0 {
                let line = "docwrite from \(BuildInfo.variant) \(BuildInfo.version) pid \(getpid())\n"
                let n = line.withCString { write(fd, $0, strlen($0)) }
                close(fd)
                log("docwrite \(path): open ok, write=\(n), after \(elapsedMs(since: t))")
            } else {
                log("docwrite \(path): open failed \(errnoString(e)) after \(elapsedMs(since: t))")
            }
            DispatchQueue.main.async(execute: done)
        }
    case "sleep":
        let s = parts.count > 1 ? Double(parts[1]) ?? 1 : 1
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: done)
    case "ax":
        log("AXIsProcessTrusted=\(AXIsProcessTrusted())")
        done()
    case "ax-prompt":
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        log("AXIsProcessTrustedWithOptions(prompt: true) = \(AXIsProcessTrustedWithOptions(opts))")
        done()
    case "ax-wait":
        let secs = parts.count > 1 ? Int(parts[1]) ?? 120 : 120
        var last = AXIsProcessTrusted()
        log("ax-wait: AXIsProcessTrusted=\(last); polling for \(secs) s")
        var remaining = secs
        func tick() {
            let now = AXIsProcessTrusted()
            if now != last {
                log("ax-wait: AXIsProcessTrusted changed to \(now)")
                last = now
                if now { done(); return } // granted: stop waiting
            }
            remaining -= 1
            if remaining <= 0 { log("ax-wait: end, AXIsProcessTrusted=\(now)"); done(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: tick)
        }
        tick()
    case "login-status":
        log("loginItem(mainApp)=\(loginItemStatus())")
        done()
    case "login-register", "login-unregister":
        do {
            if name == "login-register" { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            log("\(name) ok; status=\(loginItemStatus())")
        } catch {
            log("\(name) error: \(error); status=\(loginItemStatus())")
        }
        done()
    case "quit":
        log("quit")
        NSApp.terminate(nil)
    default:
        log("unknown step \(step)")
        done()
    }
}

func runSteps(_ steps: [String], then: @escaping () -> Void) {
    guard let first = steps.first else { return then() }
    runStep(first) { runSteps(Array(steps.dropFirst()), then: then) }
}

// MARK: - Menu-bar UI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var peer = argValue("--peer") ?? "10.0.0.2:52100"
    var listenPort = argValue("--listen-port") ?? "52001"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "S08 \(BuildInfo.variant) \(BuildInfo.version)"
        buildMenu()
        log("launched; args=\(Array(ProcessInfo.processInfo.arguments.dropFirst())) log=\(log.url.path)")
        log("info\n    \(signingInfo())\n    \(grantSummary())")
        if let script = argValue("--run") {
            let steps = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            runSteps(steps) {
                log("script finished")
                if ProcessInfo.processInfo.arguments.contains("--quit") { NSApp.terminate(nil) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { log("terminating") }

    private func item(_ title: String, _ step: @escaping () -> String) -> NSMenuItem {
        let i = ClosureMenuItem(title: title) { runStep(step()) {} }
        return i
    }

    func buildMenu() {
        let m = NSMenu()
        m.addItem(item("Signing info + grant status") { "info" })
        m.addItem(.separator())
        m.addItem(item("Browse Bonjour _tombolo-test._tcp (10 s)") { "browse:_tombolo-test._tcp:10" })
        m.addItem(item("Browse Bonjour _tombolo._udp (10 s)") { "browse:_tombolo._udp:10" })
        m.addItem(item("Listen on TCP (no Bonjour)") { [unowned self] in "listen:\(self.listenPort)" })
        m.addItem(item("Listen + advertise _tombolo-test._tcp") { [unowned self] in "advertise:\(Int(self.listenPort)! + 1)" })
        m.addItem(item("Outbound TCP to peer (Network.framework)") { [unowned self] in "nwconnect:\(self.peer):30" })
        m.addItem(item("Outbound TCP to peer (BSD socket)") { [unowned self] in "bsdconnect:\(self.peer)" })
        m.addItem(item("UDP connect + send to peer (BSD socket)") { [unowned self] in "udpconnect:\(self.peer)" })
        m.addItem(ClosureMenuItem(title: "Set peer host:port…") { [unowned self] in self.askPeer() })
        m.addItem(.separator())
        m.addItem(item("Accessibility: status") { "ax" })
        m.addItem(item("Accessibility: request (opens prompt)") { "ax-prompt" })
        m.addItem(item("Login item: status") { "login-status" })
        m.addItem(item("Login item: register") { "login-register" })
        m.addItem(item("Login item: unregister") { "login-unregister" })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(title: "Open log") { NSWorkspace.shared.open(log.url) })
        m.addItem(ClosureMenuItem(title: "Quit") { NSApp.terminate(nil) })
        statusItem.menu = m
    }

    func askPeer() {
        let alert = NSAlert()
        alert.messageText = "Peer address (IPv4:port)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = peer
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            peer = field.stringValue
            log("peer set to \(peer)")
        }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("unused") }
    @objc private func fire() { handler() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
