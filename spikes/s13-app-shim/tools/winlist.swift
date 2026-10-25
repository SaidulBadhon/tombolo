// SPDX-License-Identifier: GPL-3.0-or-later
// winlist PID... — list on-screen windows owned by the given processes (CGWindowListCopyWindowInfo).
import CoreGraphics
import Foundation
let pids = Set(CommandLine.arguments.dropFirst().compactMap { Int32($0) })
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    let pid = w[kCGWindowOwnerPID as String] as? Int32 ?? -1
    guard pids.isEmpty || pids.contains(pid) else { continue }
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    print(String(format: "window %@ owner=%@ pid=%d title=%@ layer=%@ bounds=%.0fx%.0f@%.0f,%.0f",
                 "\(w[kCGWindowNumber as String] ?? "?")", "\(w[kCGWindowOwnerName as String] ?? "?")", pid,
                 "\(w[kCGWindowName as String] ?? "-")", "\(w[kCGWindowLayer as String] ?? "?")",
                 b["Width"] ?? 0, b["Height"] ?? 0, b["X"] ?? 0, b["Y"] ?? 0))
}
