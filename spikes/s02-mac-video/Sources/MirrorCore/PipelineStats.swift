// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S2: Mac-side software telemetry. These are *not* the acceptance numbers (those come from the S1 harness);
// they split the Mac part of the pipeline: socket → decoded → handed to the presenter → presented.
import Darwin
import Foundation

public final class PipelineStats: @unchecked Sendable {
    private let lock = Lock()
    private let startedAt = hostNanos()
    private let cpuAtStart = PipelineStats.processCPUSeconds()
    private var packets = 0, keyFrames = 0, configPackets = 0, bytes = 0
    private var decoded = 0, presented = 0, superseded = 0, enqueued = 0, presentDropped = 0, decodeErrors = 0
    private var firstPacketAt: UInt64 = 0, lastPacketAt: UInt64 = 0
    private var decodeMs: [Double] = []          // decodedAt − receivedAt
    private var enqueueMs: [Double] = []         // handed to presenter − receivedAt
    private var presentMs: [Double] = []         // presented (Metal presentedTime) − receivedAt
    private var tickToPresentMs: [Double] = []   // presented − display-link callback
    private var tickToTargetMs: [Double] = []    // CAMetalDisplayLink targetPresentationTimestamp − callback
    private var targetToPresentMs: [Double] = [] // presented − targetPresentationTimestamp
    private var arrivalMinusPts: [Double] = []   // receivedAt − PTS (arbitrary offset; the spread is what matters)
    private var interArrivalMs: [Double] = []
    private let cap = 2_000_000

    public init() {}

    @inline(__always) private func push(_ a: inout [Double], _ v: Double) { if a.count < cap { a.append(v) } }

    public func packet(_ p: VideoPacket) {
        lock.withLock {
            packets += 1; bytes += p.data.count
            if p.isConfig { configPackets += 1; return }
            if p.isKeyFrame { keyFrames += 1 }
            if firstPacketAt == 0 { firstPacketAt = p.receivedAt }
            if lastPacketAt != 0 { push(&interArrivalMs, Double(p.receivedAt &- lastPacketAt) / 1e6) }
            lastPacketAt = p.receivedAt
            if let pts = p.pts { push(&arrivalMinusPts, Double(Int64(p.receivedAt / 1000) - pts) / 1000) }
        }
    }

    public func decodedFrame(_ f: DecodedFrame) {
        lock.withLock { decoded += 1; push(&decodeMs, Double(f.decodedAt &- f.receivedAt) / 1e6) }
    }

    public func decodeError() { lock.withLock { decodeErrors += 1 } }

    /// A newer frame replaced this one before it was drawn (latest-frame-wins).
    public func supersededFrame() { lock.withLock { superseded += 1 } }

    public func enqueuedFrame(_ f: DecodedFrame, at t: UInt64) {
        lock.withLock { enqueued += 1; push(&enqueueMs, Double(t &- f.receivedAt) / 1e6) }
    }

    public func presentedFrame(_ f: DecodedFrame, presentedAt: UInt64, tickAt: UInt64, targetAt: UInt64 = 0) {
        lock.withLock {
            guard presentedAt > 0 else { presentDropped += 1; return }
            presented += 1
            push(&presentMs, Double(presentedAt &- f.receivedAt) / 1e6)
            push(&tickToPresentMs, Double(presentedAt &- tickAt) / 1e6)
            if targetAt > 0 {
                push(&tickToTargetMs, (Double(targetAt) - Double(tickAt)) / 1e6)
                push(&targetToPresentMs, (Double(presentedAt) - Double(targetAt)) / 1e6)
            }
        }
    }

    public struct Snapshot: Codable, Sendable {
        public var seconds: Double
        public var packets: Int, keyFrames: Int, configPackets: Int
        public var megabitsPerSecond: Double
        public var receivedFps: Double
        public var decoded: Int, decodeErrors: Int
        public var enqueued: Int, presented: Int, superseded: Int, presentDropped: Int
        public var receiveToDecodedMs: Percentiles
        public var receiveToEnqueuedMs: Percentiles
        public var receiveToPresentedMs: Percentiles
        public var displayLinkTickToPresentedMs: Percentiles
        public var displayLinkTickToTargetMs: Percentiles
        public var displayLinkTargetToPresentedMs: Percentiles
        /// receivedAt − PTS, minus its minimum: delay variation of capture → encode → USB → socket.
        public var arrivalJitterMs: Percentiles
        public var interArrivalMs: Percentiles
        /// Process CPU time / wall time (1.0 = one core), this process only (adb server not included).
        public var processCPUCores: Double
    }

    public func snapshot() -> Snapshot {
        lock.withLock {
            let wall = Double(hostNanos() - startedAt) / 1e9
            let active = lastPacketAt > firstPacketAt ? Double(lastPacketAt - firstPacketAt) / 1e9 : 0
            let minOff = arrivalMinusPts.min() ?? 0
            return Snapshot(
                seconds: wall, packets: packets, keyFrames: keyFrames, configPackets: configPackets,
                megabitsPerSecond: active > 0 ? Double(bytes) * 8 / active / 1e6 : 0,
                receivedFps: active > 0 ? Double(interArrivalMs.count) / active : 0,
                decoded: decoded, decodeErrors: decodeErrors,
                enqueued: enqueued, presented: presented, superseded: superseded, presentDropped: presentDropped,
                receiveToDecodedMs: Percentiles(decodeMs), receiveToEnqueuedMs: Percentiles(enqueueMs),
                receiveToPresentedMs: Percentiles(presentMs), displayLinkTickToPresentedMs: Percentiles(tickToPresentMs),
                displayLinkTickToTargetMs: Percentiles(tickToTargetMs), displayLinkTargetToPresentedMs: Percentiles(targetToPresentMs),
                arrivalJitterMs: Percentiles(arrivalMinusPts.map { $0 - minOff }),
                interArrivalMs: Percentiles(interArrivalMs),
                processCPUCores: wall > 0 ? (PipelineStats.processCPUSeconds() - cpuAtStart) / wall : 0)
        }
    }

    static func processCPUSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(u.ru_utime) + s(u.ru_stime)
    }
}
