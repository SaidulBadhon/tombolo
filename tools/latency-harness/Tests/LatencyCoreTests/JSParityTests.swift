// SPDX-License-Identifier: GPL-3.0-or-later
//
// The phone page draws symbols with web/code.js; the decoder and the Mac reference window use the
// Swift layout. Load the JavaScript into JavaScriptCore and check both agree bit for bit.

import Foundation
import JavaScriptCore
import Testing
@testable import LatencyCore

@Suite struct JSParityTests {
    static func context() throws -> JSContext {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("web/code.js")
        let src = try String(contentsOf: url, encoding: .utf8)
        let ctx = try #require(JSContext())
        var jsError: String?
        ctx.exceptionHandler = { _, e in jsError = e?.toString() }
        ctx.evaluateScript(src)
        #expect(jsError == nil, "code.js threw: \(jsError ?? "")")
        return ctx
    }

    @Test func modulesMatchSwift() throws {
        let ctx = try Self.context()
        let fn = try #require(ctx.evaluateScript("(function(k,s,t){return TLC.modules(TLC.encodeBits(k,s,t)).join('');})"))
        var payloads = randomPayloads(300, seed: 77)
        payloads += [CodePayload(kindRaw: 0, session: 0, ticks: 0), CodePayload(kindRaw: 15, session: 15, ticks: .max)]
        for p in payloads {
            let js = fn.call(withArguments: [Int(p.kindRaw), Int(p.session), Double(p.ticks)])?.toString() ?? ""
            let swift = CodeLayout.modules(for: p).map { $0 ? "1" : "0" }.joined()
            #expect(js == swift, "payload \(p)")
        }
    }

    @Test func crcAndTicksMatchSwift() throws {
        let ctx = try Self.context()
        #expect(ctx.evaluateScript("TLC.crc24([49,50,51,52,53,54,55,56,57])")?.toInt32() == 0x21CF02)
        for ms in [0.0, 0.04, 0.05, 16.6667, 1234.56, 98_765.43, 429_496_729.55, 1e9 + 0.3] {
            let js = ctx.evaluateScript("TLC.ticksFromMs(\(ms))")?.toDouble() ?? -1
            #expect(js == Double(CodeLayout.ticks(fromMilliseconds: ms)), "ms \(ms)")
        }
    }
}
