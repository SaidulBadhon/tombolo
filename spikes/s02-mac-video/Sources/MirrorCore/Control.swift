// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S2: the scrcpy 5.0.1 control socket — the handle P0-16 (keyboard modes) builds on.
//
// Byte layouts from app/src/control_msg.{h,c} (Mac → phone) and app/src/device_msg.{h,c} (phone → Mac), v5.0.1.
// Integers are big-endian. Strings are UTF-8, length-prefixed, truncated on a code-point boundary.
import Foundation

public enum AndroidKeyAction: UInt8, Sendable { case down = 0, up = 1, multiple = 2 }

/// android/input.h AMOTION_EVENT_ACTION_*.
public enum AndroidMotionAction: UInt8, Sendable {
    case down = 0, up = 1, move = 2, cancel = 3, outside = 4, pointerDown = 5, pointerUp = 6, hoverMove = 7,
         scroll = 8, hoverEnter = 9, hoverExit = 10, buttonPress = 11, buttonRelease = 12
}

public enum CopyKey: UInt8, Sendable { case none = 0, copy = 1, cut = 2 }

/// A position in device video pixels together with the frame size it refers to.
public struct DevicePosition: Sendable, Equatable {
    public var x: Int32, y: Int32, frameWidth: UInt16, frameHeight: UInt16
    public init(x: Int32, y: Int32, frameWidth: UInt16, frameHeight: UInt16) {
        self.x = x; self.y = y; self.frameWidth = frameWidth; self.frameHeight = frameHeight
    }
}

public enum ControlMessage: Sendable, Equatable {
    public static let pointerIdMouse = UInt64.max            // SC_POINTER_ID_MOUSE  (-1)
    public static let pointerIdGenericFinger = UInt64.max - 1 // SC_POINTER_ID_GENERIC_FINGER (-2)
    public static let pointerIdVirtualFinger = UInt64.max - 2 // SC_POINTER_ID_VIRTUAL_FINGER (-3)
    public static let injectTextMaxLength = 300
    public static let clipboardTextMaxLength = (1 << 18) - 14

    case injectKeycode(action: AndroidKeyAction, keycode: Int32, repeatCount: UInt32 = 0, metaState: UInt32 = 0)
    case injectText(String)
    case injectTouch(action: AndroidMotionAction, pointerId: UInt64, position: DevicePosition, pressure: Float,
                     actionButton: UInt32 = 0, buttons: UInt32 = 0)
    case injectScroll(position: DevicePosition, hscroll: Float, vscroll: Float, buttons: UInt32 = 0)
    case backOrScreenOn(action: AndroidKeyAction)
    case expandNotificationPanel
    case expandSettingsPanel
    case collapsePanels
    case getClipboard(copyKey: CopyKey)
    case setClipboard(sequence: UInt64, text: String, paste: Bool)
    case setDisplayPower(on: Bool)
    case rotateDevice
    case uhidCreate(id: UInt16, vendorId: UInt16, productId: UInt16, name: String, reportDescriptor: Data)
    case uhidInput(id: UInt16, data: Data)
    case uhidDestroy(id: UInt16)
    case openHardKeyboardSettings
    case startApp(name: String)
    case resetVideo

    /// enum sc_control_msg_type order.
    var typeByte: UInt8 {
        switch self {
        case .injectKeycode: return 0
        case .injectText: return 1
        case .injectTouch: return 2
        case .injectScroll: return 3
        case .backOrScreenOn: return 4
        case .expandNotificationPanel: return 5
        case .expandSettingsPanel: return 6
        case .collapsePanels: return 7
        case .getClipboard: return 8
        case .setClipboard: return 9
        case .setDisplayPower: return 10
        case .rotateDevice: return 11
        case .uhidCreate: return 12
        case .uhidInput: return 13
        case .uhidDestroy: return 14
        case .openHardKeyboardSettings: return 15
        case .startApp: return 16
        case .resetVideo: return 17
        }
    }

    static func u16fp(_ f: Float) -> UInt16 {
        let u = UInt32(max(0, min(1, f)) * 65536)
        return u >= 0xffff ? 0xffff : UInt16(u)
    }

    static func i16fp(_ f: Float) -> Int16 {
        let i = Int32(max(-1, min(1, f)) * 32768)
        return i >= 0x7fff ? 0x7fff : Int16(i)
    }

    private static func appendPosition(_ d: inout Data, _ p: DevicePosition) {
        d.appendBE32(UInt32(bitPattern: p.x)); d.appendBE32(UInt32(bitPattern: p.y))
        d.appendBE16(p.frameWidth); d.appendBE16(p.frameHeight)
    }

    private static func truncated(_ s: String, _ max: Int) -> [UInt8] {
        let b = Array(s.utf8)
        return Array(b[0..<utf8TruncationIndex(b, maxLen: max)])
    }

    public func serialize() -> Data {
        var d = Data([typeByte])
        switch self {
        case let .injectKeycode(action, keycode, repeatCount, metaState):
            d.append(action.rawValue); d.appendBE32(UInt32(bitPattern: keycode)); d.appendBE32(repeatCount); d.appendBE32(metaState)
        case let .injectText(text):
            let b = ControlMessage.truncated(text, ControlMessage.injectTextMaxLength)
            d.appendBE32(UInt32(b.count)); d.append(contentsOf: b)
        case let .injectTouch(action, pointerId, position, pressure, actionButton, buttons):
            d.append(action.rawValue); d.appendBE64(pointerId); ControlMessage.appendPosition(&d, position)
            d.appendBE16(ControlMessage.u16fp(pressure)); d.appendBE32(actionButton); d.appendBE32(buttons)
        case let .injectScroll(position, hscroll, vscroll, buttons):
            ControlMessage.appendPosition(&d, position)
            // scrcpy accepts [-16, 16] and normalises to [-1, 1] before the fixed-point conversion.
            d.appendBE16(UInt16(bitPattern: ControlMessage.i16fp(hscroll / 16)))
            d.appendBE16(UInt16(bitPattern: ControlMessage.i16fp(vscroll / 16)))
            d.appendBE32(buttons)
        case let .backOrScreenOn(action):
            d.append(action.rawValue)
        case let .getClipboard(copyKey):
            d.append(copyKey.rawValue)
        case let .setClipboard(sequence, text, paste):
            d.appendBE64(sequence); d.append(paste ? 1 : 0)
            let b = ControlMessage.truncated(text, ControlMessage.clipboardTextMaxLength)
            d.appendBE32(UInt32(b.count)); d.append(contentsOf: b)
        case let .setDisplayPower(on):
            d.append(on ? 1 : 0)
        case let .uhidCreate(id, vendorId, productId, name, reportDescriptor):
            d.appendBE16(id); d.appendBE16(vendorId); d.appendBE16(productId)
            let n = ControlMessage.truncated(name, 127)
            d.append(UInt8(n.count)); d.append(contentsOf: n)
            d.appendBE16(UInt16(reportDescriptor.count)); d.append(reportDescriptor)
        case let .uhidInput(id, data):
            d.appendBE16(id); d.appendBE16(UInt16(data.count)); d.append(data)
        case let .uhidDestroy(id):
            d.appendBE16(id)
        case let .startApp(name):
            let n = ControlMessage.truncated(name, 255)
            d.append(UInt8(n.count)); d.append(contentsOf: n)
        case .expandNotificationPanel, .expandSettingsPanel, .collapsePanels, .rotateDevice, .openHardKeyboardSettings, .resetVideo:
            break
        }
        return d
    }
}

public enum DeviceMessage: Sendable, Equatable {
    case clipboard(String)
    case ackClipboard(sequence: UInt64)
    case uhidOutput(id: UInt16, data: Data)

    public enum ParseResult: Equatable { case message(DeviceMessage, consumed: Int), needMoreData, invalid(UInt8) }

    /// sc_device_msg_deserialize: one message from the front of `buf`.
    public static func parse(_ buf: Data) -> ParseResult {
        guard let type = buf.first else { return .needMoreData }
        switch type {
        case 0:
            guard buf.count >= 5 else { return .needMoreData }
            let len = Int(buf.be32(1))
            guard buf.count - 5 >= len else { return .needMoreData }
            let s = buf.startIndex + 5
            return .message(.clipboard(String(decoding: buf[s..<s + len], as: UTF8.self)), consumed: 5 + len)
        case 1:
            guard buf.count >= 9 else { return .needMoreData }
            return .message(.ackClipboard(sequence: buf.be64(1)), consumed: 9)
        case 2:
            guard buf.count >= 5 else { return .needMoreData }
            let id = buf.be16(1), size = Int(buf.be16(3))
            guard buf.count - 5 >= size else { return .needMoreData }
            let s = buf.startIndex + 5
            return .message(.uhidOutput(id: id, data: Data(buf[s..<s + size])), consumed: 5 + size)
        default:
            return .invalid(type)
        }
    }
}

/// The control socket of a running session. Thread-safe for `send`; device messages arrive on a private thread.
public final class ControlChannel: @unchecked Sendable {
    private let socket: TCPSocket
    private let writeLock = Lock()
    private let handlerLock = Lock()
    private var handler: ((DeviceMessage) -> Void)?
    private var reader: Thread?

    /// The raw descriptor (loopback TCP to the adb forward). Prefer `send(_:)`; reading it yourself races the
    /// device-message reader.
    public var fileDescriptor: Int32 { socket.fd }

    init(socket: TCPSocket) { self.socket = socket }

    /// Called on the reader thread for each phone → Mac message (clipboard, clipboard ack, UHID output).
    public var onDeviceMessage: ((DeviceMessage) -> Void)? {
        get { handlerLock.withLock { handler } }
        set { handlerLock.withLock { handler = newValue } }
    }

    public func send(_ message: ControlMessage) throws { try send(raw: message.serialize()) }

    public func send(raw: Data) throws { try writeLock.withLock { try socket.writeAll(raw) } }

    func startReader(onEnd: @escaping @Sendable () -> Void) {
        let t = Thread { [weak self] in
            var buf = Data()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while let self {
                let n = chunk.withUnsafeMutableBytes { self.socket.readSome(into: $0.baseAddress!, max: $0.count) }
                if n <= 0 { break }
                buf.append(contentsOf: chunk[0..<n])
                parse: while true {
                    switch DeviceMessage.parse(buf) {
                    case let .message(m, consumed):
                        buf.removeFirst(consumed)
                        self.onDeviceMessage?(m)
                    case .needMoreData:
                        break parse
                    case .invalid:
                        return onEnd()
                    }
                }
            }
            onEnd()
        }
        t.name = "s02.control-reader"
        reader = t
        t.start()
    }

    func interrupt() { socket.interrupt() }
    func close() { socket.close() }
}
