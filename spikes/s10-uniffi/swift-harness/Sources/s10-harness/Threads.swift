// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import S10Core

final class ReentrantImplSwift: Reentrant, @unchecked Sendable {
    let maxDepthThread = Locked<String>("")
    func call(depth: UInt32) -> UInt32 {
        if depth == 1 { maxDepthThread.with { $0 = swiftThread() } }
        return reenter(cb: self, depth: depth - 1) // Swift -> Rust again, same stack
    }
}

final class LockProbeSwift: LockProbe, @unchecked Sendable {
    func onCallback() -> Bool { tryTouchState(timeoutMs: 200) }
}

/// Needs the main actor — like a signer that must present UI.
final class MainActorWork: AsyncWork, @unchecked Sendable {
    func run() async -> UInt64 { await MainActor.run { Thread.isMainThread ? 1 : 0 } }
}

final class NoopAsyncWork: AsyncWork, @unchecked Sendable {
    func run() async -> UInt64 { 0 }
}

final class PingSwift: Ping, @unchecked Sendable {
    func ping(x: UInt64) -> UInt64 { x &+ 1 }
}

struct ThreadResults: Codable {
    var map: [String: String]
    var checks: [String: String]
    var pass: Bool
}

struct OverheadResults: Codable {
    var nsPerCall: [String: Double]
}

@MainActor func mainActorProbes() async -> [String: String] {
    var m: [String: String] = [:]
    m["swift_main_actor_caller"] = swiftThread()
    m["rust_sync_call_from_main_actor"] = currentThread().text
    let r = await asyncPollThreads()
    m["rust_async_from_main_actor.first_poll"] = r.firstPoll.text
    m["rust_async_from_main_actor.runtime_task"] = r.runtimeTask.text
    m["rust_async_from_main_actor.resumed_poll"] = r.resumedPoll.text
    m["swift_main_actor_after_await"] = swiftThread()
    return m
}

func runThreadTests(json: String?) async -> Bool {
    print("== S10 threads ==")
    var map = await mainActorProbes()
    var checks: [String: String] = [:]
    var pass = true

    let detached = await Task.detached { () -> [String: String] in
        var m: [String: String] = [:]
        m["swift_detached_task"] = swiftThread()
        m["rust_sync_call_from_detached_task"] = currentThread().text
        let r = await asyncPollThreads()
        m["rust_async_from_detached_task.first_poll"] = r.firstPoll.text
        m["rust_async_from_detached_task.runtime_task"] = r.runtimeTask.text
        m["rust_async_from_detached_task.resumed_poll"] = r.resumedPoll.text
        return m
    }.value
    map.merge(detached) { a, _ in a }
    map["rust_sync_call_from_swift_Thread"] = await onThreadValue("s10-swift-thread") { currentThread().text }

    // Re-entrancy: Rust -> Swift -> Rust -> ... 64 levels deep on one stack.
    let re = ReentrantImplSwift()
    let depth = await onThreadValue("s10-reenter") { reenter(cb: re, depth: 64) }
    checks["reentrancy_depth_64"] = depth == 64 ? "ok (returned \(depth))" : "FAIL (returned \(depth))"
    map["swift_reentrant_callback_at_depth_1"] = re.maxDepthThread.value
    pass = pass && depth == 64

    // Lock hazard: calling foreign code while holding a Rust lock.
    let probe = LockProbeSwift()
    let held = lockHazardDemo(probe: probe, holdLock: true)
    let released = lockHazardDemo(probe: probe, holdLock: false)
    checks["lock_held_across_callback"] = held ? "UNEXPECTED: re-entrant lock succeeded" : "would deadlock (re-entrant try_lock_for(200ms) failed) — anti-pattern confirmed"
    checks["lock_released_before_callback"] = released ? "ok (re-entrant call took the lock)" : "FAIL"
    pass = pass && !held && released

    // Main-thread hazard: a *blocking* Rust API called on the main thread, whose foreign callback needs the main actor.
    let onMain = await MainActor.run { blockOnForeign(work: MainActorWork(), timeoutMs: 1000) }
    let offMain = await onThreadValue("s10-blocker") { blockOnForeign(work: MainActorWork(), timeoutMs: 1000) }
    checks["blocking_rust_call_on_main_with_mainactor_callback"] = onMain < 0 ? "DEADLOCK (timed out after 1000 ms) — hazard confirmed" : "completed in \(onMain) ms (no deadlock?)"
    checks["blocking_rust_call_off_main_with_mainactor_callback"] = offMain >= 0 ? "ok (completed in \(offMain) ms)" : "FAIL (timed out)"
    pass = pass && onMain < 0 && offMain >= 0
    try? await Task.sleep(nanoseconds: 50_000_000) // let the stale MainActor job drain

    map["process_thread_count"] = String(taskThreadCount())
    for (k, v) in map.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v)") }
    for (k, v) in checks.sorted(by: { $0.key < $1.key }) { print("  check \(k): \(v)") }
    writeJSON(ThreadResults(map: map, checks: checks, pass: pass), to: json)
    print(pass ? "THREADS: PASS" : "THREADS: FAIL")
    return pass
}

func runOverheadBench(json: String?) async {
    print("== S10 bench: FFI call overhead ==")
    var r: [String: Double] = [:]
    func time(_ n: Int, _ body: () -> Void) -> Double {
        let t0 = nowNs()
        body()
        return Double(nowNs() - t0) / Double(n)
    }
    let n = 1_000_000
    for _ in 0..<10_000 { noop() }
    r["swift_to_rust_sync_noop"] = time(n) { for _ in 0..<n { noop() } }
    r["swift_to_rust_sync_echo_u64"] = time(n) { var a: UInt64 = 0; for i in 0..<n { a &+= echoU64(x: UInt64(i)) }; _ = a }
    let tok = CancelToken()
    r["swift_to_rust_object_method"] = time(n) { var c = 0; for _ in 0..<n { if tok.isCancelled() { c += 1 } }; _ = c }
    let ping = PingSwift()
    r["rust_to_swift_sync_callback"] = Double(benchCallbacks(cb: ping, n: UInt64(n))) / Double(n)
    let na = 100_000
    var t0 = nowNs()
    for _ in 0..<na { _ = await noopAsync() }
    r["swift_to_rust_async_ready_immediately"] = Double(nowNs() - t0) / Double(na)
    let ny = 20_000
    t0 = nowNs()
    for _ in 0..<ny { _ = await yieldAsync() }
    r["swift_to_rust_async_with_runtime_wake"] = Double(nowNs() - t0) / Double(ny)
    r["rust_to_swift_async_callback"] = Double(await benchAsyncCallbacks(cb: NoopAsyncWork(), n: UInt64(ny))) / Double(ny)
    for (k, v) in r.sorted(by: { $0.key < $1.key }) { print("  \(k): \(f1(v)) ns/call") }
    writeJSON(OverheadResults(nsPerCall: r), to: json)
}
