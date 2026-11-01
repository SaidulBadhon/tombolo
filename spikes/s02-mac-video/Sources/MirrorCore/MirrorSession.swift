// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S2: one mirroring session — push + launch the pinned scrcpy-server over adb, connect through an adb
// forward, demux, decode with VideoToolbox, hand frames to a presenter. This is the public surface P0-16 imports.
//
// Connection sequence follows scrcpy v5.0.1 app/src/server.c (run_server, sc_server_connect_to,
// connect_to_server) with tunnel_forward=true: the client connects to the forwarded port, reads one dummy byte to
// tell "adb accepted" from "server listening", opens the control socket second, removes the forward, then reads
// the 64-byte device name from the first socket.
import CryptoKit
import Foundation

public final class MirrorSession: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Device serial; nil → `$ANDROID_SERIAL`, else the only connected device.
        public var serial: String?
        /// adb executable; nil → `$ADB`, the Android SDK default, then `$PATH`.
        public var adbPath: String?
        /// Local scrcpy-server v5.0.1 file (scripts/fetch-server.sh prints its path).
        public var serverPath: String
        public var server: ServerOptions
        /// Refuse to push a server file whose SHA-256 is not the pinned one.
        public var verifyServerHash = true
        public var connectAttempts = 100
        public var connectDelay: TimeInterval = 0.1
        /// Skip adb entirely and connect to an already-listening port (tests, synthetic source, a server started by
        /// hand with `adb forward`).
        public var existingTunnelPort: UInt16?

        public init(serverPath: String, server: ServerOptions = ServerOptions()) {
            self.serverPath = serverPath
            self.server = server
        }
    }

    public enum State: String, Sendable { case idle, starting, running, ended }

    public let configuration: Configuration
    public let stats = PipelineStats()

    private let lock = Lock()
    private var _state: State = .idle
    private var _deviceName = ""
    private var _device: ADBDevice?
    private var _videoSession: VideoSessionInfo?
    private var _control: ControlChannel?
    private var _presenter: FramePresenter?
    private var stopRequested = false
    private var endedReported = false
    private var adb: ADB?
    private var forwardPort: UInt16?
    private var serverProcess: Process?
    private var serverLog: [String] = []
    private var videoSocket: TCPSocket?
    private var videoThreadDone = DispatchSemaphore(value: 0)
    private var videoThreadStarted = false

    // Callbacks. Set them before `start()`. They run on internal threads.
    /// Every decoded frame (decoder thread), after it was handed to the presenter.
    public var onFrame: ((DecodedFrame) -> Void)?
    /// Every compressed packet as received (video thread), including config packets.
    public var onPacket: ((VideoPacket) -> Void)?
    /// The initial video size and every later change (rotation, resize).
    public var onVideoSession: ((VideoSessionInfo) -> Void)?
    /// scrcpy-server stdout/stderr lines.
    public var onServerOutput: ((String) -> Void)?
    /// Once, when the session ends: nil after `stop()`, else the reason.
    public var onEnded: ((Error?) -> Void)?

    public init(configuration: Configuration) { self.configuration = configuration }

    public var state: State { lock.withLock { _state } }
    public var deviceName: String { lock.withLock { _deviceName } }
    public var device: ADBDevice? { lock.withLock { _device } }
    public var videoSession: VideoSessionInfo? { lock.withLock { _videoSession } }
    /// The control socket, once running (nil if `server.control == false`).
    public var control: ControlChannel? { lock.withLock { _control } }
    /// Where decoded frames go. May be swapped while running.
    public var presenter: FramePresenter? {
        get { lock.withLock { _presenter } }
        set { newValue?.stats = stats; lock.withLock { _presenter = newValue } }
    }
    /// The last lines the server printed (for error reports).
    public var recentServerOutput: [String] { lock.withLock { serverLog } }

    // MARK: - Start

    /// Blocking: pushes and starts the server, connects, and starts the video thread. Call off the main thread.
    public func start() throws {
        try lock.withLock {
            guard _state == .idle else { throw MirrorError.protocolError("session already started") }
            _state = .starting
        }
        do {
            let port = try configuration.existingTunnelPort ?? launchServer()
            try connect(port: port)
            lock.withLock { _state = .running }
        } catch {
            teardown()
            lock.withLock { _state = .ended; endedReported = true }
            throw error
        }
    }

    /// Async convenience: runs `start()` on a background queue.
    public func start(completion: @escaping @Sendable (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do { try self.start(); completion(nil) } catch { completion(error) }
        }
    }

    private func launchServer() throws -> UInt16 {
        let adb = try ADB.locate(explicit: configuration.adbPath)
        self.adb = adb
        let dev = try adb.selectDevice(serial: configuration.serial)
        lock.withLock { _device = dev }
        let path = configuration.serverPath
        guard FileManager.default.isReadableFile(atPath: path) else { throw MirrorError.serverFileMissing(path) }
        if configuration.verifyServerHash {
            let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            guard hex == ScrcpyServerPin.sha256 else {
                throw MirrorError.serverFileMissing("\(path) has SHA-256 \(hex), expected the pinned \(ScrcpyServerPin.sha256)")
            }
        }
        try adb.push(path, to: ScrcpyServerPin.devicePath, serial: dev.serial)
        let port = try adb.forwardToAbstract(ScrcpyServerPin.socketName(scid: configuration.server.scid), serial: dev.serial)
        lock.withLock { forwardPort = port }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb.executable)
        p.arguments = ["-s", dev.serial, "shell"] + (try configuration.server.remoteCommand())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        var partial = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            partial.append(d)
            while let nl = partial.firstIndex(of: 0x0a) {
                let line = String(decoding: partial[partial.startIndex..<nl], as: UTF8.self)
                partial.removeSubrange(partial.startIndex...nl)
                self?.serverLine(line)
            }
        }
        p.terminationHandler = { [weak self] proc in
            self?.serverLine("[adb shell exited with status \(proc.terminationStatus)]")
            self?.serverEnded()
        }
        try p.run()
        lock.withLock { serverProcess = p }
        return port
    }

    private func serverLine(_ line: String) {
        lock.withLock {
            serverLog.append(line)
            if serverLog.count > 80 { serverLog.removeFirst(serverLog.count - 80) }
        }
        onServerOutput?(line)
    }

    private func serverEnded() {
        // If the server dies while running, the video socket hits EOF and the video thread reports the end.
        // If it dies while connecting, `connect` notices `serverProcess.isRunning == false`.
    }

    private var serverAlive: Bool { lock.withLock { serverProcess?.isRunning ?? (configuration.existingTunnelPort != nil) } }
    private var stopping: Bool { lock.withLock { stopRequested } }

    private func connect(port: UInt16) throws {
        var first: TCPSocket?
        var lastError = "no attempt"
        for attempt in 0..<max(1, configuration.connectAttempts) {
            if stopping { throw MirrorError.closed }
            do {
                let s = try TCPSocket.connectLoopback(port: port)
                var b: UInt8 = 0
                if s.readExactly(into: &b, count: 1) { first = s; break }
                s.close()
                lastError = "server not listening yet"
            } catch {
                lastError = "\(error)"
            }
            if !serverAlive {
                throw MirrorError.connectFailed("scrcpy-server exited: " + recentServerOutput.suffix(8).joined(separator: " | "))
            }
            if attempt + 1 < configuration.connectAttempts { Thread.sleep(forTimeInterval: configuration.connectDelay) }
        }
        guard let video = first else {
            throw MirrorError.connectFailed("\(lastError) after \(configuration.connectAttempts) attempts; server: "
                                            + recentServerOutput.suffix(8).joined(separator: " | "))
        }
        video.setReceiveBuffer(4 << 20)
        lock.withLock { videoSocket = video }
        var control: ControlChannel?
        if configuration.server.control {
            let c = try TCPSocket.connectLoopback(port: port)
            c.setNoDelay()
            control = ControlChannel(socket: c)
        }
        // The tunnel is no longer needed once both sockets exist (scrcpy closes it here too).
        if let a = adb, let p = lock.withLock({ forwardPort }), let serial = lock.withLock({ _device?.serial }) {
            a.removeForward(port: p, serial: serial)
            lock.withLock { forwardPort = nil }
        }
        guard let meta = video.readExactly(ScrcpyFraming.deviceNameLength) else {
            throw MirrorError.protocolError("stream ended before the device name")
        }
        let name = ScrcpyFraming.parseDeviceName(meta)
        lock.withLock { _deviceName = name; _control = control }
        control?.startReader { }
        startVideoThread(video)
    }

    // MARK: - Video thread

    private func startVideoThread(_ sock: TCPSocket) {
        let t = Thread { [self] in
            var endError: Error?
            do {
                try runVideo(sock)
            } catch {
                endError = error
            }
            videoThreadDone.signal()
            reportEnded(stopping ? nil : (endError ?? MirrorError.protocolError("video stream ended (server stopped or device disconnected)")))
        }
        t.name = "s02.video"
        t.qualityOfService = .userInteractive
        lock.withLock { videoThreadStarted = true }
        t.start()
    }

    private func runVideo(_ sock: TCPSocket) throws {
        let demux = StreamDemuxer(read: { sock.readExactly($0) })
        let codec = try demux.readCodec()
        guard codec == .h264 else { throw MirrorError.protocolError("spike decodes H.264 only, server sent \(codec)") }
        let assembler = H264AccessUnitAssembler()
        let decoder = VideoDecoder { [weak self] frame in
            guard let self else { return }
            self.stats.decodedFrame(frame)
            self.presenter?.enqueue(frame)
            self.onFrame?(frame)
        }
        defer { decoder.invalidate() }
        while let ev = try demux.next() {
            switch ev {
            case .session(let s):
                lock.withLock { _videoSession = s }
                onVideoSession?(s)
            case .packet(let p):
                stats.packet(p)
                onPacket?(p)
                if let au = try assembler.push(p) {
                    do { try decoder.decode(au) } catch {
                        stats.decodeError()
                        // Ask for a fresh key frame, as scrcpy's RESET_VIDEO; keep going.
                        try? control?.send(.resetVideo)
                    }
                }
            }
        }
    }

    private func reportEnded(_ error: Error?) {
        let cb: ((Error?) -> Void)? = lock.withLock {
            if endedReported { return nil }
            endedReported = true
            _state = .ended
            return onEnded
        }
        cb?(error)
    }

    // MARK: - Stop

    /// Stops the session: closes the sockets (the server exits and cleans up), waits up to 1 s, then kills the
    /// adb shell. Safe to call more than once and from any thread except the callbacks' own.
    public func stop() {
        lock.withLock { stopRequested = true }
        teardown()
        reportEnded(nil)
    }

    private func teardown() {
        let (video, control, started) = lock.withLock { (videoSocket, _control, videoThreadStarted) }
        video?.interrupt()
        control?.interrupt()
        if started { _ = videoThreadDone.wait(timeout: .now() + 2); videoThreadDone.signal() }
        video?.close()
        control?.close()
        let proc = lock.withLock { serverProcess }
        if let p = proc, p.isRunning {
            let deadline = Date().addingTimeInterval(1)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if p.isRunning { p.terminate() }
        }
        if let a = adb, let port = lock.withLock({ forwardPort }), let serial = lock.withLock({ _device?.serial }) {
            a.removeForward(port: port, serial: serial)
            lock.withLock { forwardPort = nil }
        }
    }
}
