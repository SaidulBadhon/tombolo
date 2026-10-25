// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S13 wire protocol between the Tombolo host and its app shims.
import CShimIPC
import Foundation

public enum S13 {
    /// Host bundle ID for the spike (kept separate from the production ID on purpose).
    public static let hostBundleID = "io.github.saidulbadhon.Tombolo.spike-s13.host"
    /// Shim bundle ID prefix, as the production design would use it.
    public static let shimBundleIDPrefix = "io.github.saidulbadhon.Tombolo.shim."
    /// Dynamic bootstrap name the host claims (no launchd plist involved).
    public static let serviceName = "io.github.saidulbadhon.Tombolo.spike-s13.ipc"
    /// notify(3) name posted when the host is ready, so waiting shims reconnect immediately.
    public static let hostReadyNotification = "io.github.saidulbadhon.Tombolo.spike-s13.host-ready"
    public static let protocolVersion: UInt32 = 1

    public static var stateDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tombolo-spike-s13", isDirectory: true)
    }
    public static var logDir: URL { stateDir.appendingPathComponent("logs", isDirectory: true) }
    public static var shimsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Tombolo Apps", isDirectory: true)
    }

    /// Android package → valid CFBundleIdentifier suffix (bundle IDs allow only [A-Za-z0-9.-]).
    public static func bundleID(forPackage pkg: String) -> String {
        let mapped = pkg.unicodeScalars.map { c -> Character in
            (CharacterSet.alphanumerics.contains(c) && c.isASCII) || c == "." || c == "-" ? Character(c) : "-"
        }
        return shimBundleIDPrefix + String(mapped)
    }
}

public enum MsgID: Int32 {
    case hello = 1000       // shim → host: proto, package, shim version, pid (reply port = shim port)
    case config = 1001      // host → shim: session id, frame geometry, mode, ring surfaces (ports)
    case frame = 1002       // host → shim: seq, slot, t_send (+ surface port in per-frame mode)
    case ack = 1003         // shim → host: seq, slot, t_send echo, t_recv, t_commit
    case event = 1004       // shim → host: input event
    case bye = 1005         // either way: reason
    case restartForUpdate = 1006  // host → shim: quit so the host can regenerate the bundle
    case reject = 1007      // host → shim: code-signing check failed
}

public enum FrameMode: UInt32 { case ring = 0, perFrame = 1 }

public enum ByeReason: UInt32 {
    case hostQuit = 1, shimQuit = 2, windowClosed = 3, update = 4, rejected = 5
    public var text: String {
        switch self {
        case .hostQuit: "host quit"
        case .shimQuit: "shim quit"
        case .windowClosed: "window closed"
        case .update: "updating"
        case .rejected: "rejected"
        }
    }
}

public enum EventKind: UInt32 {
    case mouseDown = 1, mouseDragged, mouseUp, rightMouseDown, scroll, keyDown, keyUp, magnify
}

// MARK: - Payload codec (little-endian, fixed order)

public struct Writer {
    public private(set) var bytes: [UInt8] = []
    public init() {}
    public mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes += $0 } }
    public mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { bytes += $0 } }
    public mutating func f64(_ v: Double) { u64(v.bitPattern) }
    public mutating func str(_ s: String, max: Int = 96) {
        let utf8 = Array(s.utf8.prefix(max))
        u32(UInt32(utf8.count))
        bytes += utf8
    }
}

public struct Reader {
    let bytes: [UInt8]
    var off = 0
    public init(_ b: [UInt8]) { bytes = b }
    public mutating func u32() -> UInt32 {
        guard off + 4 <= bytes.count else { return 0 }
        defer { off += 4 }
        return bytes[off..<off + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }
    public mutating func u64() -> UInt64 {
        guard off + 8 <= bytes.count else { return 0 }
        defer { off += 8 }
        return bytes[off..<off + 8].enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }
    public mutating func f64() -> Double { Double(bitPattern: u64()) }
    public mutating func str() -> String {
        let n = Int(u32())
        guard n >= 0, off + n <= bytes.count else { return "" }
        defer { off += n }
        return String(decoding: bytes[off..<off + n], as: UTF8.self)
    }
}

// MARK: - Received message wrapper

public struct Incoming {
    public let id: Int32
    public let replyPort: mach_port_t
    public let ports: [mach_port_t]
    public let payload: [UInt8]
    public let audit: [UInt32]
    public let senderPID: Int32
    public let notifyName: mach_port_name_t
    public var reader: Reader { Reader(payload) }
    public var isKernelNotification: Bool {
        senderPID == 0 && (id == Int32(SIPC_NOTIFY_DEAD_NAME) || id == Int32(SIPC_NOTIFY_PORT_DELETED))
    }
}

public enum IPC {
    /// Drain every message currently queued on `port`.
    public static func drain(_ port: mach_port_t, _ handle: (Incoming) -> Void) {
        var m = sipc_message_t()
        while sipc_receive(port, &m, 0) == KERN_SUCCESS {
            let ports = withUnsafeBytes(of: m.ports) { Array($0.bindMemory(to: mach_port_t.self).prefix(Int(m.nports))) }
            let payload = withUnsafeBytes(of: m.payload) { Array($0.prefix(Int(m.payload_len))) }
            let audit = withUnsafeBytes(of: m.audit) { Array($0.bindMemory(to: UInt32.self)) }
            handle(Incoming(id: m.msgid, replyPort: m.reply_port, ports: ports, payload: payload,
                            audit: audit, senderPID: m.sender_pid, notifyName: m.notify_name))
        }
    }

    @discardableResult
    public static func send(_ dest: mach_port_t, _ id: MsgID, _ w: Writer = Writer(), ports: [mach_port_t] = [],
                            reply: mach_port_t = mach_port_t(MACH_PORT_NULL), timeoutMs: UInt32 = 0) -> kern_return_t {
        w.bytes.withUnsafeBytes { buf in
            ports.withUnsafeBufferPointer { pp in
                sipc_send(dest, reply, id.rawValue, pp.baseAddress, UInt32(ports.count),
                          buf.baseAddress, UInt32(buf.count), timeoutMs)
            }
        }
    }

    public static func err(_ kr: kern_return_t) -> String { "\(kr) (\(String(cString: sipc_strerror(kr))))" }
}

/// One clock for every process: CLOCK_UPTIME_RAW in ns.
@inline(__always) public func nowNs() -> UInt64 { sipc_now_ns() }
