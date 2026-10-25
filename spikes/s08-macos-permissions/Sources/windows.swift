// SPDX-License-Identifier: GPL-3.0-or-later
//
// Detect new on-screen windows (e.g. the Local Network alert) without clicking anything.
//
// usage: windows --baseline <file>   record the windows that are on screen now
//        windows --diff <file>       print windows that were not in the baseline
//
// Privacy: other apps' window titles are never printed or stored. The baseline holds
// only owner|pid|layer|size keys, and titles are shown only for system-alert and
// probe processes (allowlist below). Titles may be empty without Screen Recording
// permission; owner, pid, layer and bounds are always available.

import CoreGraphics
import Foundation

let titleAllowlist = ["UserNotificationCenter", "TomboloProbe", "CoreServicesUIAgent", "SystemUIServer",
                      "nehelper", "NEHelper", "universalAccessAuthWarn", "SecurityAgent", "System Settings",
                      "System Preferences", "Notification Center", "loginwindow", "Control Center"]

let args = CommandLine.arguments
guard args.count == 3, ["--baseline", "--diff"].contains(args[1]) else {
    print("usage: windows --baseline <file> | --diff <file>"); exit(2)
}
guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] else {
    print("CGWindowListCopyWindowInfo failed"); exit(1)
}

struct Win { let key: String; let line: String }
let wins: [Win] = list.map { w in
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let size = "\(b["Width"] ?? "?")x\(b["Height"] ?? "?")"
    let id = w[kCGWindowNumber as String] as? Int ?? -1
    let key = "\(owner)|\(pid)|\(layer)|\(size)"
    var line = "owner=\(owner) pid=\(pid) layer=\(layer) size=\(size)"
    if titleAllowlist.contains(where: { owner.contains($0) }) {
        // Window id only for allowlisted owners: run-probe.sh screenshots those windows (only).
        line += " id=\(id) title=\(w[kCGWindowName as String] as? String ?? "")"
    }
    return Win(key: key, line: line)
}

let path = args[2]
if args[1] == "--baseline" {
    try! wins.map(\.key).joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
} else {
    let base = Set((try? String(contentsOfFile: path, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? [])
    let new = wins.filter { !base.contains($0.key) }
    if new.isEmpty { print("no new windows") }
    for w in new { print("NEW " + w.line) }
}
