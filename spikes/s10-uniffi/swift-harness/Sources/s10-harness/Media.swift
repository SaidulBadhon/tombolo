// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import S10Core

let allDesigns: [(String, Delivery)] = [
    ("vec-pull", .vecPull), ("vec-async", .vecAsync), ("vec-callback", .vecCallback),
    ("handle-pull", .handlePull), ("ring-pull", .ringPull), ("ring-async", .ringAsync), ("ring-callback", .ringCallback),
]

func designName(_ d: Delivery) -> String { allDesigns.first { $0.1 == d }!.0 }

/// Per-frame bookkeeping. Every design ends in `frame(...)`, which does the same work: validate the
/// header/trailer, compare the payload address with the Rust buffer address stamped in the header
/// (equal => Swift is reading Rust's memory, i.e. zero copies), touch one byte per 4 KiB page, and
/// record `now - produced_ns`.
final class FrameRecorder: @unchecked Sendable {
    let capacity: Int
    let lat: UnsafeMutablePointer<UInt64>
    let magic: UInt64
    let sampleMemory: Bool
    var count = 0
    var integrityFailures = 0
    var zeroCopyFrames = 0
    var gaps: UInt64 = 0
    var expectedSeq: UInt64 = 0
    var sink: UInt8 = 0
    var memSamples: [UInt64] = []
    var consumerThread = ""
    var firstNs: UInt64 = 0
    var lastNs: UInt64 = 0
    let done = DispatchSemaphore(value: 0)

    init(capacity: Int, magic: UInt64, sampleMemory: Bool) {
        self.capacity = capacity
        self.magic = magic
        self.sampleMemory = sampleMemory
        lat = .allocate(capacity: max(capacity, 1))
        memSamples.reserveCapacity(capacity / 60 + 16)
    }

    deinit { lat.deallocate() }

    @inline(__always)
    func frame(_ p: UnsafeRawPointer, _ len: Int, seq: UInt64, producedNs: UInt64) {
        if count == 0 {
            consumerThread = swiftThread()
            firstNs = nowNs()
        }
        let hSeq = p.loadUnaligned(as: UInt64.self)
        let addr = p.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
        let hLen = p.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
        let m = p.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
        let tSeq = p.loadUnaligned(fromByteOffset: len - 8, as: UInt64.self)
        var acc: UInt8 = 0
        var i = 0
        while i < len { acc &+= p.load(fromByteOffset: i, as: UInt8.self); i += 4096 }
        sink &+= acc
        if hSeq != seq || tSeq != seq || m != magic || hLen != UInt64(len) { integrityFailures += 1 }
        if addr == UInt64(UInt(bitPattern: p)) { zeroCopyFrames += 1 }
        if seq != expectedSeq { gaps &+= seq &- expectedSeq }
        expectedSeq = seq &+ 1
        let now = nowNs()
        if count < capacity { lat[count] = now &- producedNs }
        count += 1
        lastNs = now
        if sampleMemory && count % 60 == 0 { memSamples.append(physFootprintBytes()) }
    }
}

final class VecSinkSwift: FrameSink, @unchecked Sendable {
    let rec: FrameRecorder
    init(_ rec: FrameRecorder) { self.rec = rec }
    func onFrame(frame: VecFrame) {
        frame.data.withUnsafeBytes { rec.frame($0.baseAddress!, $0.count, seq: frame.seq, producedNs: frame.producedNs) }
    }
    func onEnd() { rec.done.signal() }
}

struct RingView: @unchecked Sendable {
    let data: UnsafeRawPointer
    let descs: UnsafeRawPointer
    let count: UInt64
    let stride: Int
    init(_ l: RingLayout) {
        data = UnsafeRawPointer(bitPattern: UInt(l.dataBase))!
        descs = UnsafeRawPointer(bitPattern: UInt(l.descBase))!
        count = UInt64(l.descCount)
        stride = Int(l.descStride)
    }
    /// Reads slot `seq`'s descriptor straight out of Rust's memory and hands the payload to `rec`.
    @inline(__always)
    func consume(_ seq: UInt64, _ rec: FrameRecorder) {
        let d = descs + Int(seq % count) * stride
        let frameSeq = d.load(fromByteOffset: 8, as: UInt64.self)
        let produced = d.load(fromByteOffset: 16, as: UInt64.self)
        let offset = d.load(fromByteOffset: 24, as: UInt64.self)
        let len = d.load(fromByteOffset: 32, as: UInt64.self)
        let check = d.load(fromByteOffset: 56, as: UInt64.self)
        if check != seq { rec.integrityFailures += 1 }
        rec.frame(data + Int(offset), Int(len), seq: frameSeq, producedNs: produced)
    }
}

final class SlotSinkSwift: SlotSink, @unchecked Sendable {
    let rec: FrameRecorder
    var stream: MediaStream?
    var view: RingView?
    init(_ rec: FrameRecorder) { self.rec = rec }
    func attach(_ s: MediaStream) {
        stream = s
        view = RingView(s.ringLayout()!)
    }
    func onSlots(fromSeq: UInt64, toSeq: UInt64) {
        guard let stream, let view else { return }
        var s = fromSeq
        while s < toSeq {
            view.consume(s, rec)
            _ = stream.ringRelease(seq: s) // re-entrant Swift -> Rust call from inside the callback
            s += 1
        }
    }
    func onEnd() { rec.done.signal() }
}

func waitDone(_ rec: FrameRecorder) async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            rec.done.wait()
            c.resume()
        }
    }
}

func consume(_ design: Delivery, _ stream: MediaStream, _ rec: FrameRecorder) async {
    switch design {
    case .vecPull:
        await onThread("s10-consumer") {
            while let f = stream.nextVec() {
                f.data.withUnsafeBytes { rec.frame($0.baseAddress!, $0.count, seq: f.seq, producedNs: f.producedNs) }
            }
        }
    case .vecAsync:
        await Task.detached {
            while let f = await stream.nextVecAsync() {
                f.data.withUnsafeBytes { rec.frame($0.baseAddress!, $0.count, seq: f.seq, producedNs: f.producedNs) }
            }
        }.value
    case .handlePull:
        await onThread("s10-consumer") {
            while let r = stream.nextHandle() {
                // The pattern a decoder feed would use: a Data (or CMBlockBuffer) that *borrows* Rust's
                // buffer and keeps the FrameHandle alive until it is released.
                let handle = r.handle
                let data = Data(bytesNoCopy: UnsafeMutableRawPointer(bitPattern: UInt(r.ptr))!, count: Int(r.len),
                                deallocator: .custom { _, _ in withExtendedLifetime(handle) {} })
                data.withUnsafeBytes { rec.frame($0.baseAddress!, $0.count, seq: r.seq, producedNs: r.producedNs) }
            }
        }
    case .ringPull:
        let view = RingView(stream.ringLayout()!)
        await onThread("s10-consumer") {
            var next: UInt64 = 0
            while true {
                let h = stream.ringWait(next: next, timeoutMs: 1000)
                if h == UInt64.max { break }
                while next < h {
                    view.consume(next, rec)
                    _ = stream.ringRelease(seq: next)
                    next += 1
                }
            }
        }
    case .ringAsync:
        let view = RingView(stream.ringLayout()!)
        await Task.detached {
            var next: UInt64 = 0
            while true {
                let h = await stream.ringWaitAsync(next: next)
                if h == UInt64.max { break }
                while next < h {
                    view.consume(next, rec)
                    _ = stream.ringRelease(seq: next)
                    next += 1
                }
            }
        }.value
    case .vecCallback, .ringCallback:
        await waitDone(rec)
    }
}

struct MediaResult: Codable {
    var design: String
    var mode: String
    var fps: UInt32
    var configuredFrames: UInt64
    var wallSeconds: Double
    var framesConsumed: Int
    var produced: UInt64
    var droppedByProducer: UInt64
    var seqGaps: UInt64
    var integrityFailures: Int
    var zeroCopyFrames: Int
    var payloadMB: Double
    var latencyUs: Percentiles
    var framesOver1ms: Int
    var framesOver16_7ms: Int
    var cpuSeconds: Double
    var cpuPercentOfOneCore: Double
    var producerBusyUsPerFrame: Double
    var drainNsPerFrame: Double
    var memAfterWarmupMB: Double?
    var memEndMB: Double?
    var memMaxMB: Double?
    var memGrowthKB: Double?
    var liveFrameHandlesAtEnd: Int64
    var foreignFutureHandlesAtEnd: Int
    var consumerThread: String
    var threadsInProcess: Int
    var loadAvgStart: [Double]
    var loadAvgEnd: [Double]
}

func video1080p60(seconds: Double) -> StreamConfig {
    StreamConfig(fps: 60, frameCount: UInt64(seconds * 60), pFrameMin: 25_000, pFrameMax: 40_000,
                 keyframeBytes: 250_000, keyframeInterval: 120, prefill: false,
                 ringBytes: 8 << 20, ringSlots: 64, queueDepth: 8, seed: 0x5310)
}

func runMedia(_ design: Delivery, _ cfg: StreamConfig, mode: String, sampleMemory: Bool, quiet: Bool = false) async throws -> MediaResult {
    let fmt = frameFormat()
    let rec = FrameRecorder(capacity: Int(cfg.frameCount), magic: fmt.magic, sampleMemory: sampleMemory)
    let vecSink: VecSinkSwift? = design == .vecCallback ? VecSinkSwift(rec) : nil
    let slotSink: SlotSinkSwift? = design == .ringCallback ? SlotSinkSwift(rec) : nil
    let stream = try MediaStream(delivery: design, config: cfg, frameSink: vecSink, slotSink: slotSink)
    slotSink?.attach(stream)
    if cfg.prefill { await onThread("s10-prefill-wait") { stream.waitPrefilled() } }

    let load0 = loadAverage()
    let cpu0 = cpuSeconds()
    let t0 = nowNs()
    stream.start()
    await consume(design, stream, rec)
    let t1 = nowNs()
    let cpu1 = cpuSeconds()
    let threads = taskThreadCount()
    stream.join()
    let st = stream.stats()
    slotSink?.stream = nil

    let n = min(rec.count, rec.capacity)
    let lat = UnsafeBufferPointer(start: rec.lat, count: n)
    var over1 = 0, over16 = 0
    for v in lat { if v > 1_000_000 { over1 += 1 }; if v > 16_700_000 { over16 += 1 } }
    let wall = Double(t1 - t0) / 1e9
    let samples = rec.memSamples
    let warm = samples.count > 3 ? samples[2] : samples.first
    let r = MediaResult(
        design: designName(design), mode: mode, fps: cfg.fps, configuredFrames: cfg.frameCount, wallSeconds: wall,
        framesConsumed: rec.count, produced: st.produced, droppedByProducer: st.droppedFull, seqGaps: rec.gaps,
        integrityFailures: rec.integrityFailures, zeroCopyFrames: rec.zeroCopyFrames,
        payloadMB: Double(st.payloadBytes) / 1e6, latencyUs: percentilesUs(lat), framesOver1ms: over1,
        framesOver16_7ms: over16, cpuSeconds: cpu1 - cpu0, cpuPercentOfOneCore: (cpu1 - cpu0) / wall * 100,
        producerBusyUsPerFrame: st.produced == 0 ? 0 : Double(st.producerBusyNs) / Double(st.produced) / 1000,
        drainNsPerFrame: rec.count == 0 ? 0 : Double(rec.lastNs - t0) / Double(rec.count),
        memAfterWarmupMB: warm.map { Double($0) / 1e6 }, memEndMB: samples.last.map { Double($0) / 1e6 },
        memMaxMB: samples.max().map { Double($0) / 1e6 },
        memGrowthKB: (warm != nil && samples.last != nil) ? (Double(samples.last!) - Double(warm!)) / 1e3 : nil,
        liveFrameHandlesAtEnd: liveFrameHandles(), foreignFutureHandlesAtEnd: uniffiForeignFutureHandleCountS10Core(),
        consumerThread: rec.consumerThread, threadsInProcess: threads, loadAvgStart: load0, loadAvgEnd: loadAverage())
    if !quiet { printMedia(r) }
    return r
}

func printMedia(_ r: MediaResult) {
    let l = r.latencyUs
    print("  \(r.design.padding(toLength: 13, withPad: " ", startingAt: 0)) frames=\(r.framesConsumed)/\(r.configuredFrames) drops=\(r.droppedByProducer) gaps=\(r.seqGaps) bad=\(r.integrityFailures) zero-copy=\(r.zeroCopyFrames)/\(r.framesConsumed)")
    print("                latency µs p50=\(f1(l.p50)) p95=\(f1(l.p95)) p99=\(f1(l.p99)) p99.9=\(f1(l.p999)) max=\(f1(l.max)) | >1ms=\(r.framesOver1ms) >16.7ms=\(r.framesOver16_7ms)")
    print("                cpu=\(f2(r.cpuPercentOfOneCore))% of a core (\(f2(r.cpuSeconds)) s / \(f1(r.wallSeconds)) s) producer=\(f1(r.producerBusyUsPerFrame))µs/frame mem warm=\(r.memAfterWarmupMB.map(f2) ?? "-")MB end=\(r.memEndMB.map(f2) ?? "-")MB max=\(r.memMaxMB.map(f2) ?? "-")MB growth=\(r.memGrowthKB.map(f1) ?? "-")KB handles=\(r.liveFrameHandlesAtEnd) futures=\(r.foreignFutureHandlesAtEnd)")
    print("                consumer: \(r.consumerThread) | load \(r.loadAvgStart) -> \(r.loadAvgEnd)")
}

struct StressRow: Codable {
    var design: String
    var frameBytes: UInt32
    var frames: UInt64
    var drainNsPerFrame: Double
    var drainGBps: Double
    var memcpyNs: UInt64
    var drainCostInMemcpys: Double
    var zeroCopyFrames: Int
    var integrityFailures: Int
}

/// Prefilled, unpaced drain: the producer makes every frame first, then we time how fast Swift can
/// take them across the FFI. Isolates the per-frame FFI cost (no waiting on the producer).
func runStress(sizes: [(UInt32, UInt64)], designs: [Delivery], json: String?) async throws {
    print("== S10 stress: prefilled drain, ns per frame by payload size ==")
    var rows: [StressRow] = []
    for (size, n) in sizes {
        let memcpy = benchMemcpy(bytes: UInt64(size), iters: 200)
        for d in designs {
            let cfg = StreamConfig(fps: 0, frameCount: n, pFrameMin: size, pFrameMax: size, keyframeBytes: size,
                                   keyframeInterval: 0, prefill: true, ringBytes: UInt64(size) * n + (1 << 20),
                                   ringSlots: UInt32(n + 1), queueDepth: 1, seed: 1)
            let r = try await runMedia(d, cfg, mode: "stress", sampleMemory: false, quiet: true)
            let row = StressRow(design: r.design, frameBytes: size, frames: n, drainNsPerFrame: r.drainNsPerFrame,
                                drainGBps: Double(size) / r.drainNsPerFrame, memcpyNs: memcpy,
                                drainCostInMemcpys: r.drainNsPerFrame / Double(max(memcpy, 1)),
                                zeroCopyFrames: r.zeroCopyFrames, integrityFailures: r.integrityFailures)
            rows.append(row)
            print("  \(String(size).padding(toLength: 8, withPad: " ", startingAt: 0)) \(row.design.padding(toLength: 13, withPad: " ", startingAt: 0)) \(f1(row.drainNsPerFrame).padding(toLength: 10, withPad: " ", startingAt: 0)) ns/frame  \(f2(row.drainGBps)) GB/s  memcpy=\(memcpy) ns  = \(f2(row.drainCostInMemcpys)) memcpys  zero-copy=\(row.zeroCopyFrames)/\(n) bad=\(row.integrityFailures)")
        }
    }
    writeJSON(rows, to: json)
}
