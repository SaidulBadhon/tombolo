// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S2: drives the `adb` executable (architecture §3.1 ADBKit: "drives a bundled adb … or the user's install").
import Foundation

public struct ADBDevice: Sendable, Equatable {
    public var serial: String
    public var state: String   // "device", "unauthorized", "offline", …
    public var properties: [String: String]

    public var isUSB: Bool { properties["usb"] != nil }
    public var model: String? { properties["model"] }
}

public final class ADB: @unchecked Sendable {
    public let executable: String

    public init(executable: String) { self.executable = executable }

    /// `$ADB`, then the Android SDK default location, then `$PATH`.
    public static func locate(explicit: String? = nil) throws -> ADB {
        var candidates: [String] = []
        if let e = explicit, !e.isEmpty { candidates.append(e) }
        if let e = ProcessInfo.processInfo.environment["ADB"], !e.isEmpty { candidates.append(e) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let sdk = ProcessInfo.processInfo.environment["ANDROID_HOME"] ?? ProcessInfo.processInfo.environment["ANDROID_SDK_ROOT"] {
            candidates.append(sdk + "/platform-tools/adb")
        }
        candidates.append(home + "/Library/Android/sdk/platform-tools/adb")
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            candidates.append(String(dir) + "/adb")
        }
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return ADB(executable: c) }
        throw MirrorError.adbNotFound
    }

    public struct Result: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    /// Runs adb with `args` and waits for it.
    @discardableResult
    public func run(_ args: [String], serial: String? = nil, check: Bool = true) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = (serial.map { ["-s", $0] } ?? []) + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        // Read both pipes concurrently so a chatty command can't deadlock on a full pipe.
        var errData = Data()
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        g.wait()
        p.waitUntilExit()
        let r = Result(status: p.terminationStatus,
                       stdout: String(decoding: outData, as: UTF8.self),
                       stderr: String(decoding: errData, as: UTF8.self))
        if check && r.status != 0 {
            throw MirrorError.adb("`adb \(p.arguments!.joined(separator: " "))` exited \(r.status): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return r
    }

    /// `adb devices -l`.
    public func devices() throws -> [ADBDevice] {
        try run(["start-server"], check: false)
        return ADB.parseDevices(try run(["devices", "-l"]).stdout)
    }

    static func parseDevices(_ text: String) -> [ADBDevice] {
        var list: [ADBDevice] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("List of devices") || l.hasPrefix("*") { continue }
            let parts = l.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { continue }
            var props: [String: String] = [:]
            for p in parts.dropFirst(2) {
                if let i = p.firstIndex(of: ":") { props[String(p[..<i])] = String(p[p.index(after: i)...]) }
            }
            list.append(ADBDevice(serial: parts[0], state: parts[1], properties: props))
        }
        return list
    }

    /// Picks `serial` if given (must be in state "device"), else `$ANDROID_SERIAL`, else the only device.
    public func selectDevice(serial: String?) throws -> ADBDevice {
        let all = try devices()
        let wanted = serial ?? ProcessInfo.processInfo.environment["ANDROID_SERIAL"]
        if let w = wanted {
            guard let d = all.first(where: { $0.serial == w }) else {
                throw MirrorError.noDevice("\(w) is not connected (adb devices: \(all.map { "\($0.serial)=\($0.state)" }.joined(separator: ", ")))")
            }
            guard d.state == "device" else { throw MirrorError.noDevice("\(w) is \(d.state)") }
            return d
        }
        let ready = all.filter { $0.state == "device" }
        if ready.count == 1 { return ready[0] }
        if ready.isEmpty {
            throw MirrorError.noDevice(all.isEmpty ? "adb lists no devices" : "devices not ready: \(all.map { "\($0.serial)=\($0.state)" }.joined(separator: ", "))")
        }
        throw MirrorError.noDevice("several devices; pass --serial (\(ready.map(\.serial).joined(separator: ", ")))")
    }

    public func push(_ local: String, to remote: String, serial: String) throws {
        try run(["push", local, remote], serial: serial)
    }

    /// `adb forward tcp:0 localabstract:<name>`; returns the local port adb picked.
    public func forwardToAbstract(_ name: String, serial: String) throws -> UInt16 {
        let r = try run(["forward", "tcp:0", "localabstract:" + name], serial: serial)
        guard let port = UInt16(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MirrorError.adb("unexpected `adb forward tcp:0` output: \(r.stdout)")
        }
        return port
    }

    public func removeForward(port: UInt16, serial: String) {
        _ = try? run(["forward", "--remove", "tcp:\(port)"], serial: serial, check: false)
    }

    public func shell(_ command: String, serial: String) throws -> String {
        try run(["shell", command], serial: serial).stdout
    }
}
