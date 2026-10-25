// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import S10Core

/// Same clock as the Rust side (`clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`).
@inline(__always) func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

func ms(_ ns: UInt64) -> Double { Double(ns) / 1e6 }
func f1(_ x: Double) -> String { String(format: "%.1f", x) }
func f2(_ x: Double) -> String { String(format: "%.2f", x) }
func f3(_ x: Double) -> String { String(format: "%.3f", x) }

/// Process CPU time (user + system, all threads incl. Rust's), seconds.
func cpuSeconds() -> Double {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
        + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
}

/// `phys_footprint` — the number Activity Monitor shows as "Memory".
func physFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}

func taskThreadCount() -> Int {
    var list: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
    for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
    vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                  vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
    return Int(count)
}

func loadAverage() -> [Double] {
    var l = [Double](repeating: 0, count: 3)
    _ = getloadavg(&l, 3)
    return l.map { ($0 * 100).rounded() / 100 }
}

/// Describes the current thread the same way Rust's `ThreadInfo` does.
func swiftThread() -> String {
    var tid: UInt64 = 0
    pthread_threadid_np(nil, &tid)
    let label = String(cString: __dispatch_queue_get_label(nil))
    var name = [CChar](repeating: 0, count: 64)
    pthread_getname_np(pthread_self(), &name, 64)
    let n = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return "tid=\(tid) main=\(Thread.isMainThread) queue=\(label.isEmpty ? "-" : label)\(n.isEmpty ? "" : " name=\(n)")"
}

extension ThreadInfo {
    var text: String {
        "tid=\(tid) main=\(isMain) queue=\(queueLabel.isEmpty ? "-" : queueLabel)\(osName.isEmpty ? "" : " name=\(osName)")"
    }
}

struct Percentiles: Codable {
    var count: Int
    var min: Double
    var p50: Double
    var p90: Double
    var p95: Double
    var p99: Double
    var p999: Double
    var max: Double
    var mean: Double
}

/// Percentiles of nanosecond samples, reported in microseconds.
func percentilesUs(_ ns: UnsafeBufferPointer<UInt64>) -> Percentiles {
    let s = ns.sorted()
    guard !s.isEmpty else { return Percentiles(count: 0, min: 0, p50: 0, p90: 0, p95: 0, p99: 0, p999: 0, max: 0, mean: 0) }
    func q(_ p: Double) -> Double { Double(s[Swift.min(s.count - 1, Int((Double(s.count) * p).rounded(.down)))]) / 1000 }
    let mean = Double(s.reduce(0, { $0 &+ $1 })) / Double(s.count) / 1000
    return Percentiles(count: s.count, min: Double(s[0]) / 1000, p50: q(0.50), p90: q(0.90), p95: q(0.95),
                       p99: q(0.99), p999: q(0.999), max: Double(s[s.count - 1]) / 1000, mean: mean)
}

func percentilesUs(_ ns: [UInt64]) -> Percentiles {
    ns.withUnsafeBufferPointer { percentilesUs($0) }
}

func writeJSON<T: Encodable>(_ value: T, to path: String?) {
    guard let path else { return }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        let data = try enc.encode(value)
        try data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    } catch {
        print("ERROR writing \(path): \(error)")
    }
}

/// Runs `body` on a dedicated (non-cooperative) thread — the right home for blocking FFI calls.
func onThread(_ name: String, _ body: @escaping @Sendable () -> Void) async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        let t = Thread {
            body()
            c.resume()
        }
        t.name = name
        t.qualityOfService = .userInteractive
        t.start()
    }
}

/// Like `onThread` but returns a value.
func onThreadValue<T: Sendable>(_ name: String, _ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
        let t = Thread { c.resume(returning: body()) }
        t.name = name
        t.start()
    }
}

/// Wraps a non-Sendable value we know is used safely.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    func with<R>(_ f: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return f(&_value)
    }
    var value: T { with { $0 } }
}
