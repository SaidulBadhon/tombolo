// SPDX-License-Identifier: GPL-3.0-or-later
// winlist PID... — list the windows owned by the given processes (CGWindowListCopyWindowInfo), including
// windows on other Spaces (onscreen=0), e.g. while the user is in a full-screen app.
import CoreGraphics
import Foundation
let pids = Set(CommandLine.arguments.dropFirst().compactMap { Int32($0) })
let opts: CGWindowListOption = pids.isEmpty ? [.optionOnScreenOnly] : [.optionAll, .excludeDesktopElements]
let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    let pid = w[kCGWindowOwnerPID as String] as? Int32 ?? -1
    guard pids.isEmpty || pids.contains(pid) else { continue }
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    print(String(format: "window %@ owner=%@ pid=%d title=%@ layer=%@ onscreen=%@ bounds=%.0fx%.0f@%.0f,%.0f",
                 "\(w[kCGWindowNumber as String] ?? "?")", "\(w[kCGWindowOwnerName as String] ?? "?")", pid,
                 "\(w[kCGWindowName as String] ?? "-")", "\(w[kCGWindowLayer as String] ?? "?")",
                 "\(w[kCGWindowIsOnscreen as String] ?? 0)",
                 b["Width"] ?? 0, b["Height"] ?? 0, b["X"] ?? 0, b["Y"] ?? 0))
}
