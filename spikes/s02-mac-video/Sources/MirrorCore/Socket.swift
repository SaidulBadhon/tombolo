// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S2: a minimal blocking TCP client socket (loopback to the adb forward). POSIX, so the hot path has no
// framework overhead and reads can be timed exactly.
import Darwin
import Foundation

public final class TCPSocket: @unchecked Sendable {
    public let fd: Int32
    private let closeLock = Lock()
    private var closed = false

    init(fd: Int32) { self.fd = fd }

    /// Connects to 127.0.0.1:`port`. Throws on refusal.
    static func connectLoopback(port: UInt16) throws -> TCPSocket {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw MirrorError.connectFailed("socket(): \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if r != 0 {
            let e = String(cString: strerror(errno))
            Darwin.close(fd)
            throw MirrorError.connectFailed("connect 127.0.0.1:\(port): \(e)")
        }
        return TCPSocket(fd: fd)
    }

    func setNoDelay() {
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    func setReceiveBuffer(_ bytes: Int32) {
        var v = bytes
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &v, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Reads exactly `count` bytes into `buffer`. Returns false on EOF or error.
    func readExactly(into buffer: UnsafeMutableRawPointer, count: Int) -> Bool {
        var got = 0
        while got < count {
            let r = Darwin.read(fd, buffer + got, count - got)
            if r > 0 { got += r; continue }
            if r < 0 && errno == EINTR { continue }
            return false
        }
        return true
    }

    func readExactly(_ count: Int) -> Data? {
        var d = Data(count: count)
        let ok = d.withUnsafeMutableBytes { readExactly(into: $0.baseAddress!, count: count) }
        return ok ? d : nil
    }

    /// Reads whatever is available (blocking until at least one byte). Returns 0 on EOF, -1 on error.
    func readSome(into buffer: UnsafeMutableRawPointer, max: Int) -> Int {
        while true {
            let r = Darwin.read(fd, buffer, max)
            if r < 0 && errno == EINTR { continue }
            return r
        }
    }

    func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let r = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if r > 0 { off += r; continue }
                if r < 0 && errno == EINTR { continue }
                throw MirrorError.connectFailed("write: \(String(cString: strerror(errno)))")
            }
        }
    }

    /// Wakes up any blocked reader (like scrcpy's net_interrupt), without releasing the descriptor.
    func interrupt() { _ = Darwin.shutdown(fd, SHUT_RDWR) }

    func close() {
        closeLock.withLock {
            guard !closed else { return }
            closed = true
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    deinit { close() }
}
