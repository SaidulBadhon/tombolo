// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import S10Core

/// The wrapper tombolo's Swift layer would put around every long-running core call: Swift task
/// cancellation -> `CancelToken.cancel()` -> Rust drops the work future (UniFFI 0.32 does not do
/// this on its own).
func cancellable<T: Sendable>(_ body: @Sendable (CancelToken) async throws -> T) async throws -> T {
    let token = CancelToken()
    return try await withTaskCancellationHandler {
        try await body(token)
    } onCancel: {
        token.cancel()
    }
}

struct CancelCase: Codable {
    var name: String
    var pass: Bool
    var expectation: String
    var swiftOutcome: String
    var swiftReturnedAfterMs: Double
    var cancelRequestedAtMs: Double?
    var rustEvents: [String]
    var swiftSignerObservedCancelAtMs: Double?
    var foreignFutureHandlesLeft: Int
}

struct CancelResults: Codable {
    var cases: [CancelCase]
    var tokenCancelToRustDropUs: Percentiles?
    var tokenCancelToRuntimeTaskDropUs: Percentiles?
}

private func describe(_ events: [ProbeEvent], t0: UInt64) -> [String] {
    events.map { "+\(f3(ms($0.tNs &- t0)))ms \($0.event) [\($0.thread.text)]" }
}

private func eventTime(_ events: [ProbeEvent], _ name: String) -> UInt64? {
    events.first { $0.event == name }?.tNs
}

func runCancelTests(json: String?) async -> Bool {
    print("== S10 cancel ==")
    var cases: [CancelCase] = []

    // C1: naive — Swift cancels the Task 50 ms into a 1000 ms Rust sleep.
    do {
        let probe: UInt64 = 1001
        let t0 = nowNs()
        let task = Task.detached { () -> String in
            do { return "returned \(try await sleepNaive(ms: 1000, probe: probe)) (Task.isCancelled=\(Task.isCancelled))" }
            catch { return "threw \(error)" }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let tc = nowNs()
        task.cancel()
        let outcome = await task.value
        let td = nowNs()
        let ev = takeProbeEvents(probe: probe)
        let ranToEnd = ev.contains { $0.event == "runtime_task:completed" } && !ev.contains { $0.event.hasSuffix("dropped_before_completion") }
        cases.append(CancelCase(
            name: "C1 Swift Task.cancel() on a plain UniFFI async call",
            pass: ranToEnd && ms(td - t0) > 900,
            expectation: "UniFFI 0.32 does NOT propagate: Rust future runs to completion (~1000 ms)",
            swiftOutcome: outcome, swiftReturnedAfterMs: ms(td - t0), cancelRequestedAtMs: ms(tc - t0),
            rustEvents: describe(ev, t0: t0), swiftSignerObservedCancelAtMs: nil,
            foreignFutureHandlesLeft: uniffiForeignFutureHandleCountS10Core()))
    }

    // C2: token pattern, repeated to get a latency distribution.
    var dropLat: [UInt64] = []
    var taskDropLat: [UInt64] = []
    var c2: CancelCase?
    for i in 0..<30 {
        let probe: UInt64 = 2000 + UInt64(i)
        let t0 = nowNs()
        let task = Task.detached { () -> String in
            do { return "returned \(try await cancellable { try await sleepCancellable(ms: 1000, probe: probe, token: $0) })" }
            catch { return "threw \(error)" }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let tc = nowNs()
        task.cancel()
        let outcome = await task.value
        let td = nowNs()
        try? await Task.sleep(nanoseconds: 5_000_000) // let the aborted runtime task's drop land
        let ev = takeProbeEvents(probe: probe)
        let workDrop = eventTime(ev, "work_future:dropped_before_completion")
        let taskDrop = eventTime(ev, "runtime_task:dropped_before_completion")
        if let workDrop { dropLat.append(workDrop &- tc) }
        if let taskDrop { taskDropLat.append(taskDrop &- tc) }
        if i == 0 {
            c2 = CancelCase(
                name: "C2 Swift Task.cancel() -> CancelToken -> Rust drops work future + aborts runtime task",
                pass: workDrop != nil && taskDrop != nil && outcome.contains("Cancelled") && ms(td - t0) < 200,
                expectation: "Rust drops the work future and the spawned runtime task within ~1 ms; Swift gets CoreError.Cancelled",
                swiftOutcome: outcome, swiftReturnedAfterMs: ms(td - t0), cancelRequestedAtMs: ms(tc - t0),
                rustEvents: describe(ev, t0: t0), swiftSignerObservedCancelAtMs: nil,
                foreignFutureHandlesLeft: uniffiForeignFutureHandleCountS10Core())
        } else if workDrop == nil || taskDrop == nil || !outcome.contains("Cancelled") {
            c2?.pass = false
            c2?.swiftOutcome += " | iteration \(i) failed: \(outcome)"
        }
    }
    if var c2 {
        c2.pass = c2.pass && dropLat.count == 30 && taskDropLat.count == 30
        cases.append(c2)
    }

    // C3: Rust -> Swift: Rust times out a foreign async call; Swift's Task must see cancellation.
    do {
        let probe: UInt64 = 3001
        let slow = SlowSigner(delayMs: 5000)
        let t0 = nowNs()
        var outcome = ""
        do { _ = try await handshake(signer: slow, token: nil, signTimeoutMs: 200, probe: probe); outcome = "returned" }
        catch { outcome = "threw \(error)" }
        let td = nowNs()
        try? await Task.sleep(nanoseconds: 20_000_000)
        let ev = takeProbeEvents(probe: probe)
        let sc = slow.cancelledNs.value
        cases.append(CancelCase(
            name: "C3 Rust drops a pending foreign async future (sign timeout 200 ms)",
            pass: sc != 0 && outcome.contains("TimedOut") && uniffiForeignFutureHandleCountS10Core() == 0,
            expectation: "UniFFI cancels the Swift Task running Signer.sign at ~200 ms; no leaked foreign-future handles",
            swiftOutcome: outcome, swiftReturnedAfterMs: ms(td - t0), cancelRequestedAtMs: nil,
            rustEvents: describe(ev, t0: t0), swiftSignerObservedCancelAtMs: sc == 0 ? nil : ms(sc - t0),
            foreignFutureHandlesLeft: uniffiForeignFutureHandleCountS10Core()))
    }

    // C4: full chain: Swift cancels handshake -> token -> Rust aborts -> drops foreign future -> Swift signer cancelled.
    do {
        let probe: UInt64 = 4001
        let slow = SlowSigner(delayMs: 5000)
        let t0 = nowNs()
        let task = Task.detached { () -> String in
            do { _ = try await cancellable { try await handshake(signer: slow, token: $0, signTimeoutMs: 0, probe: probe) }; return "returned" }
            catch { return "threw \(error)" }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let tc = nowNs()
        task.cancel()
        let outcome = await task.value
        let td = nowNs()
        try? await Task.sleep(nanoseconds: 20_000_000)
        let ev = takeProbeEvents(probe: probe)
        let sc = slow.cancelledNs.value
        cases.append(CancelCase(
            name: "C4 full chain: Swift cancels handshake while Rust awaits the Swift signer",
            pass: sc != 0 && outcome.contains("Cancelled") && ms(td - t0) < 300 && uniffiForeignFutureHandleCountS10Core() == 0,
            expectation: "Swift cancel -> Rust drops handshake task -> foreign sign future dropped -> Swift sign Task cancelled",
            swiftOutcome: outcome, swiftReturnedAfterMs: ms(td - t0), cancelRequestedAtMs: ms(tc - t0),
            rustEvents: describe(ev, t0: t0), swiftSignerObservedCancelAtMs: sc == 0 ? nil : ms(sc - t0),
            foreignFutureHandlesLeft: uniffiForeignFutureHandleCountS10Core()))
        threadLog.with { $0["swift_signer_saw_cancel_on"] = slow.cancelThread.value }
    }

    let res = CancelResults(cases: cases,
                            tokenCancelToRustDropUs: dropLat.isEmpty ? nil : percentilesUs(dropLat),
                            tokenCancelToRuntimeTaskDropUs: taskDropLat.isEmpty ? nil : percentilesUs(taskDropLat))
    for c in cases {
        print("  [\(c.pass ? "PASS" : "FAIL")] \(c.name)")
        print("      expect: \(c.expectation)")
        print("      swift: \(c.swiftOutcome) after \(f1(c.swiftReturnedAfterMs)) ms\(c.cancelRequestedAtMs.map { " (cancel at \(f1($0)) ms)" } ?? "")\(c.swiftSignerObservedCancelAtMs.map { "; Swift signer saw cancellation at \(f1($0)) ms" } ?? "")")
        for e in c.rustEvents { print("      rust: \(e)") }
        print("      foreign-future handles left: \(c.foreignFutureHandlesLeft)")
    }
    if let p = res.tokenCancelToRustDropUs { print("  token cancel -> work future dropped (n=\(p.count)): p50=\(f1(p.p50))µs p95=\(f1(p.p95))µs max=\(f1(p.max))µs") }
    if let p = res.tokenCancelToRuntimeTaskDropUs { print("  token cancel -> runtime task dropped (n=\(p.count)): p50=\(f1(p.p50))µs p95=\(f1(p.p95))µs max=\(f1(p.max))µs") }
    writeJSON(res, to: json)
    let ok = cases.allSatisfy { $0.pass }
    print(ok ? "CANCEL: PASS" : "CANCEL: FAIL")
    return ok
}
