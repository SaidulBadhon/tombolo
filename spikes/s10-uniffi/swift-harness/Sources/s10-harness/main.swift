// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S10 harness — see ../../../README.md for commands.
import Foundation
import S10Core

let args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let cmd = args.first ?? "help"
let json = opt("--json")

func design(_ s: String) -> Delivery? { allDesigns.first { $0.0 == s }?.1 }

var ok = true
switch cmd {
case "sign":
    ok = await runSignTests(json: json)
case "touchid-check":
    ok = await runTouchIDCheck(json: json)
case "touchid":
    ok = await runTouchIDManual(timeoutMs: UInt64(opt("--timeout-ms") ?? "30000") ?? 30000)
case "cancel":
    ok = await runCancelTests(json: json)
case "threads":
    ok = await runThreadTests(json: json)
case "bench":
    await runOverheadBench(json: json)
case "media":
    let seconds = Double(opt("--seconds") ?? "120") ?? 120
    let names = (opt("--design") ?? "all") == "all" ? allDesigns.map { $0.0 } : opt("--design")!.split(separator: ",").map(String.init)
    print("== S10 media: synthetic 1080p60 stream, \(seconds) s per design (P 25–40 KB, key 250 KB every 2 s) ==")
    var results: [MediaResult] = []
    for n in names {
        guard let d = design(n) else { print("unknown design \(n)"); exit(2) }
        let r = try await runMedia(d, video1080p60(seconds: seconds), mode: "paced-60fps", sampleMemory: true)
        results.append(r)
        ok = ok && r.integrityFailures == 0 && r.framesConsumed == Int(r.configuredFrames)
    }
    writeJSON(results, to: json)
case "stress":
    let quick = args.contains("--quick")
    let sizes: [(UInt32, UInt64)] = quick
        ? [(65_536, 256)]
        : [(4_096, 16_384), (65_536, 2_048), (262_144, 512), (1_048_576, 128)]
    try await runStress(sizes: sizes, designs: allDesigns.map { $0.1 }, json: json)
default:
    print("""
    usage: s10-harness <command> [--json PATH]
      sign            Secure Enclave signer called from Rust; Rust verifies with p256 (unattended)
      touchid-check   .userPresence SE key with interaction disallowed must refuse to sign (unattended)
      touchid         MANUAL: .userPresence SE key, shows Touch ID [--timeout-ms N]
      cancel          async cancellation in both directions
      threads         thread map, re-entrancy, lock and main-thread deadlock hazards
      bench           FFI call overhead
      media           paced 1080p60 stream [--design NAME[,NAME]|all] [--seconds N]
                      designs: \(allDesigns.map { $0.0 }.joined(separator: ", "))
      stress          prefilled drain cost by payload size [--quick]
    """)
}
exit(ok ? 0 : 1)
