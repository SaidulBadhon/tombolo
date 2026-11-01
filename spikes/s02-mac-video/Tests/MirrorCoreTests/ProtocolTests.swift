// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S2: wire-format tests against the byte layouts in scrcpy v5.0.1 (app/src/demuxer.c, control_msg.c,
// device_msg.c, server.c; server/…/Streamer.java, DesktopConnection.java, Options.java).
import Foundation
import Testing
@testable import MirrorCore

private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

private final class BufferReader {
    var data: Data
    init(_ d: Data) { data = d }
    func read(_ n: Int) -> Data? {
        guard data.count >= n else { return nil }
        let out = Data(data.prefix(n))
        data.removeFirst(n)
        return out
    }
}

@Suite struct ServerArguments {
    @Test func defaultsMatchScrcpyConventions() throws {
        var o = ServerOptions(scid: 0x1234abcd)
        o.maxSize = 2400
        let cmd = try o.remoteCommand()
        #expect(cmd == ["CLASSPATH=/data/local/tmp/scrcpy-server.jar", "app_process", "/", "com.genymobile.scrcpy.Server", "5.0.1",
                        "scid=1234abcd", "log_level=info", "audio=false", "max_size=2400", "max_fps=60", "tunnel_forward=true",
                        "clipboard_autosync=false"])
        #expect(ScrcpyServerPin.socketName(scid: 0x1234abcd) == "scrcpy_1234abcd")
    }

    @Test func nonDefaultValuesAreEmitted() throws {
        var o = ServerOptions(scid: 7)
        o.videoBitRate = 16_000_000; o.control = false; o.stayAwake = true; o.videoCodecOptions = "i-frame-interval=1,latency=0"
        o.videoEncoder = "c2.qti.avc.encoder"; o.maxSize = 0; o.maxFps = 0
        #expect(o.arguments == ["scid=00000007", "log_level=info", "video_bit_rate=16000000", "audio=false", "tunnel_forward=true",
                                "control=false", "stay_awake=true", "video_codec_options=i-frame-interval=1,latency=0",
                                "video_encoder=c2.qti.avc.encoder", "clipboard_autosync=false"])
    }

    @Test func scidIs31Bit() { #expect(ServerOptions(scid: 0xffff_ffff).scid == 0x7fff_ffff) }

    @Test(arguments: ["a b", "x;rm", "$(id)", "`id`", "a|b", "a&b", "q'", "q\"", "a\\b", "{x}", "a\nb"])
    func shellMetacharactersAreRejected(_ bad: String) {
        var o = ServerOptions(scid: 1)
        o.extra = [("crop", bad)]
        #expect(throws: MirrorError.self) { try o.remoteCommand() }
    }
}

@Suite struct StreamFraming {
    @Test func sessionHeaderLayout() {
        let d = ScrcpyFraming.encodeSession(width: 1080, height: 2400, clientResized: true)
        #expect(hex(d) == "80000001" + "00000438" + "00000960")
    }

    @Test func packetHeaderLayout() {
        let key = ScrcpyFraming.encodePacket(Data([0xaa, 0xbb]), pts: 0x0102_0304_0506, keyFrame: true)
        #expect(hex(key) == "2000010203040506" + "00000002" + "aabb")
        let cfg = ScrcpyFraming.encodePacket(Data([1]), pts: 99, config: true)
        #expect(hex(cfg) == "4000000000000000" + "00000001" + "01")
    }

    @Test func demuxesAWholeStream() throws {
        var s = Data()
        s.append(ScrcpyFraming.encodeCodec(.h264))
        s.append(ScrcpyFraming.encodeSession(width: 1080, height: 2400))
        s.append(ScrcpyFraming.encodePacket(Data([0, 0, 0, 1, 0x67, 1]), pts: 0, config: true))
        s.append(ScrcpyFraming.encodePacket(Data([0, 0, 0, 1, 0x65, 2]), pts: 16_666, keyFrame: true))
        s.append(ScrcpyFraming.encodePacket(Data([0, 0, 1, 0x41, 3]), pts: 33_333))
        s.append(ScrcpyFraming.encodeSession(width: 2400, height: 1080))
        let r = BufferReader(s)
        let dm = StreamDemuxer(read: r.read)
        #expect(try dm.readCodec() == .h264)
        var events: [String] = []
        while let e = try dm.next() {
            switch e {
            case .session(let i): events.append("S\(i.width)x\(i.height)")
            case .packet(let p): events.append("P\(p.isConfig ? "c" : "")\(p.isKeyFrame ? "k" : "")\(p.pts.map(String.init) ?? "-"):\(p.data.count)")
            }
        }
        #expect(events == ["S1080x2400", "Pc-:6", "Pk16666:6", "P33333:5", "S2400x1080"])
    }

    @Test func disabledAndErrorCodecsThrow() {
        #expect(throws: MirrorError.self) { try ScrcpyFraming.parseCodec(0) }
        #expect(throws: MirrorError.self) { try ScrcpyFraming.parseCodec(1) }
        #expect(throws: MirrorError.self) { try ScrcpyFraming.parseCodec(0x1234_5678) }
        #expect((try? ScrcpyFraming.parseCodec(0x6832_3634)) == .h264)
    }

    @Test func truncatedPacketEndsTheStream() throws {
        var s = ScrcpyFraming.encodeCodec(.h264)
        s.append(ScrcpyFraming.encodeSession(width: 8, height: 8))
        s.append(ScrcpyFraming.encodePacket(Data(repeating: 9, count: 100), pts: 1).prefix(50))
        let r = BufferReader(s)
        let dm = StreamDemuxer(read: r.read)
        _ = try dm.readCodec()
        if case .session = try dm.next() {} else { Issue.record("expected session") }
        #expect(try dm.next() == nil)
    }

    @Test func zeroAndHugePacketSizesAreProtocolErrors() {
        var h = Data(); h.appendBE64(1); h.appendBE32(0)
        #expect(throws: MirrorError.self) { try ScrcpyFraming.parseHeader(h) }
        var h2 = Data(); h2.appendBE64(1); h2.appendBE32(0x7fff_ffff)
        #expect(throws: MirrorError.self) { try ScrcpyFraming.parseHeader(h2) }
        let zeroSession = Data([0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(throws: MirrorError.self) { try ScrcpyFraming.parseHeader(zeroSession) }
    }

    @Test func deviceNameIsNulPaddedAndTruncatedOnACodePoint() {
        let d = ScrcpyFraming.encodeDeviceName("motorola edge 50 pro")
        #expect(d.count == 64)
        #expect(ScrcpyFraming.parseDeviceName(d) == "motorola edge 50 pro")
        let long = String(repeating: "é", count: 40)   // 80 bytes
        let t = ScrcpyFraming.parseDeviceName(ScrcpyFraming.encodeDeviceName(long))
        #expect(t == String(repeating: "é", count: 31))  // 62 bytes ≤ 63
    }
}

@Suite struct AnnexB {
    @Test func splitsThreeAndFourByteStartCodes() {
        let d = Data([0, 0, 0, 1, 0x67, 0xaa, 0, 0, 1, 0x68, 0xbb, 0, 0, 0, 1, 0x65, 0xcc, 0xdd, 0])
        let n = H264.splitAnnexB(d)
        #expect(n.map(hex) == ["67aa", "68bb", "65ccdd"])
        #expect(n.map(H264.type(of:)) == [7, 8, 5])
    }

    @Test func emulationPreventionBytesStayInside() {
        let d = Data([0, 0, 1, 0x41, 0, 0, 3, 1, 0x80])
        #expect(H264.splitAnnexB(d).map(hex) == ["4100000301" + "80"])
    }

    @Test func avccLengthPrefixes() {
        #expect(hex(H264.avcc([Data([0x65, 1, 2]), Data([0x06])])) == "00000003650102" + "0000000106")
    }

    @Test func assemblerStripsParameterSetsAndWaitsForThem() throws {
        let a = H264AccessUnitAssembler()
        // Media before any SPS/PPS cannot be decoded: dropped.
        let early = VideoPacket(data: Data([0, 0, 1, 0x41, 1]), pts: 1, isConfig: false, isKeyFrame: false, receivedAt: 0)
        #expect(try a.push(early) == nil)
        #expect(a.format == nil)
    }
}

@Suite struct ControlMessages {
    let pos = DevicePosition(x: 100, y: 200, frameWidth: 1080, frameHeight: 2400)

    @Test func injectKeycode() {
        #expect(hex(ControlMessage.injectKeycode(action: .up, keycode: 66, repeatCount: 5, metaState: 0x1000).serialize())
                == "00" + "01" + "00000042" + "00000005" + "00001000")
    }

    @Test func injectTextIsTruncatedTo300BytesOnACodePoint() {
        #expect(hex(ControlMessage.injectText("hello").serialize()) == "01" + "00000005" + "68656c6c6f")
        let s = String(repeating: "a", count: 299) + "é"   // 301 bytes; é must not be split
        let d = ControlMessage.injectText(s).serialize()
        #expect(d.count == 1 + 4 + 299)
        #expect(d.be32(1) == 299)
    }

    @Test func injectTouch() {
        let d = ControlMessage.injectTouch(action: .down, pointerId: ControlMessage.pointerIdMouse, position: pos, pressure: 1.0,
                                           actionButton: 1, buttons: 1).serialize()
        #expect(d.count == 32)
        #expect(hex(d) == "02" + "00" + "ffffffffffffffff" + "00000064" + "000000c8" + "0438" + "0960" + "ffff" + "00000001" + "00000001")
    }

    @Test func injectScrollNormalisesBy16() {
        let d = ControlMessage.injectScroll(position: pos, hscroll: 16, vscroll: -8, buttons: 0).serialize()
        #expect(d.count == 21)
        #expect(hex(d) == "03" + "00000064" + "000000c8" + "0438" + "0960" + "7fff" + "c000" + "00000000")
    }

    @Test func clipboardAndPower() {
        #expect(hex(ControlMessage.setClipboard(sequence: 2, text: "hi", paste: true).serialize())
                == "09" + "0000000000000002" + "01" + "00000002" + "6869")
        #expect(hex(ControlMessage.getClipboard(copyKey: .copy).serialize()) == "0801")
        #expect(hex(ControlMessage.setDisplayPower(on: false).serialize()) == "0a00")
        #expect(hex(ControlMessage.backOrScreenOn(action: .down).serialize()) == "0400")
    }

    @Test func uhidMessages() {
        let desc = Data([0x05, 0x01, 0x09, 0x06])
        #expect(hex(ControlMessage.uhidCreate(id: 1, vendorId: 0x18d1, productId: 0x4ee7, name: "kbd", reportDescriptor: desc).serialize())
                == "0c" + "0001" + "18d1" + "4ee7" + "03" + "6b6264" + "0004" + "05010906")
        #expect(hex(ControlMessage.uhidInput(id: 1, data: Data([0, 0, 4, 0, 0, 0, 0, 0])).serialize()) == "0d" + "0001" + "0008" + "0000040000000000")
        #expect(hex(ControlMessage.uhidDestroy(id: 1).serialize()) == "0e0001")
    }

    @Test func singleByteMessagesAndTypeOrder() {
        #expect(hex(ControlMessage.expandNotificationPanel.serialize()) == "05")
        #expect(hex(ControlMessage.expandSettingsPanel.serialize()) == "06")
        #expect(hex(ControlMessage.collapsePanels.serialize()) == "07")
        #expect(hex(ControlMessage.rotateDevice.serialize()) == "0b")
        #expect(hex(ControlMessage.openHardKeyboardSettings.serialize()) == "0f")
        #expect(hex(ControlMessage.startApp(name: "+org.app").serialize()) == "10" + "08" + "2b6f72672e617070")
        #expect(hex(ControlMessage.resetVideo.serialize()) == "11")
    }

    @Test func deviceMessagesParseIncrementally() {
        var stream = Data([0x00, 0, 0, 0, 3]) + Data("abc".utf8)
        stream += Data([0x01, 0, 0, 0, 0, 0, 0, 0, 9])
        stream += Data([0x02, 0, 7, 0, 2, 0xde, 0xad])
        var got: [DeviceMessage] = []
        var buf = Data()
        for b in stream {   // byte by byte, as the worst-case TCP segmentation
            buf.append(b)
            while case let .message(m, n) = DeviceMessage.parse(buf) { got.append(m); buf.removeFirst(n) }
        }
        #expect(got == [.clipboard("abc"), .ackClipboard(sequence: 9), .uhidOutput(id: 7, data: Data([0xde, 0xad]))])
        #expect(DeviceMessage.parse(Data([0x7f])) == .invalid(0x7f))
    }
}

@Suite struct Geometry {
    @Test func aspectFitLetterboxes() {
        let r = MirrorGeometry.aspectFit(content: CGSize(width: 1080, height: 2400), in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        #expect(abs(r.width - 450) < 0.001 && r.height == 1000 && abs(r.minX - 275) < 0.001)
    }

    @Test func viewPointToDevicePixels() {
        let b = CGRect(x: 0, y: 0, width: 540, height: 1200)
        let v = CGSize(width: 1080, height: 2400)
        #expect(MirrorGeometry.devicePoint(CGPoint(x: 0, y: 1200), viewBounds: b, videoSize: v) == CGPoint(x: 0, y: 0))
        #expect(MirrorGeometry.devicePoint(CGPoint(x: 270, y: 600), viewBounds: b, videoSize: v) == CGPoint(x: 540, y: 1200))
        #expect(MirrorGeometry.devicePoint(CGPoint(x: 540, y: 0), viewBounds: b, videoSize: v) == CGPoint(x: 1079, y: 2399))
        #expect(MirrorGeometry.devicePoint(CGPoint(x: 600, y: 0), viewBounds: CGRect(x: 0, y: 0, width: 540, height: 1200), videoSize: v) == nil)
    }
}

@Suite struct ADBParsing {
    @Test func devicesList() {
        let out = """
        List of devices attached
        0123456789ABCDEF       device usb:1-1 product:pdx model:motorola_edge_50_pro device:pdx transport_id:3
        emulator-5554          unauthorized transport_id:1
        * daemon started successfully

        """
        let d = ADB.parseDevices(out)
        #expect(d.count == 2)
        #expect(d[0].serial == "0123456789ABCDEF" && d[0].state == "device" && d[0].isUSB && d[0].model == "motorola_edge_50_pro")
        #expect(d[1].state == "unauthorized" && !d[1].isUSB)
    }
}
