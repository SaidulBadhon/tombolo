// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S2: scrcpy-server 5.0.1 launch arguments.
//
// Wire contract taken from the scrcpy v5.0.1 sources (Apache-2.0):
//   app/src/server.c            execute_server(): `adb -s SERIAL shell CLASSPATH=/data/local/tmp/scrcpy-server.jar
//                               app_process / com.genymobile.scrcpy.Server <version> key=value…`, validate_string()
//   server/src/main/java/com/genymobile/scrcpy/Options.java   parse(): the first argument must equal the server
//                               version; every other argument is key=value; defaults (video_bit_rate 8 Mb/s,
//                               h264, audio on, control on, clipboard_autosync on, send_* meta on).
import Foundation

public enum ScrcpyServerPin {
    /// The pinned scrcpy-server release. The server refuses to start if the client passes another version.
    public static let version = "5.0.1"
    /// SHA-256 of `scrcpy-server-v5.0.1` from the release's SHA256SUMS.txt (checked by scripts/fetch-server.sh
    /// and again before every push).
    public static let sha256 = "764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536"
    /// Where scrcpy itself pushes the server (app/src/server.c SC_DEVICE_SERVER_PATH).
    public static let devicePath = "/data/local/tmp/scrcpy-server.jar"
    public static let mainClass = "com.genymobile.scrcpy.Server"
    /// Abstract socket name prefix (DesktopConnection.java SOCKET_NAME_PREFIX + "_%08x").
    public static func socketName(scid: UInt32) -> String { String(format: "scrcpy_%08x", scid) }
}

public struct ServerOptions: Sendable, Equatable {
    /// 31-bit session id; selects the abstract socket name.
    public var scid: UInt32
    public var logLevel: String = "info"
    public var video: Bool = true
    public var audio: Bool = false
    public var control: Bool = true
    public var videoCodec: String = "h264"
    /// Larger dimension of the encoded video (0 = native). 2400 gives 1080×2400 on a 1220×2712 panel.
    public var maxSize: Int = 2400
    public var maxFps: Int = 60
    public var videoBitRate: Int = 8_000_000
    /// Phone → Mac clipboard sync. Off by default: the phone's clipboard is private data this spike doesn't need.
    public var clipboardAutosync: Bool = false
    public var stayAwake: Bool = false
    public var powerOn: Bool = true
    public var showTouches: Bool = false
    public var videoEncoder: String? = nil
    /// MediaCodec options, scrcpy syntax `key[:type]=value[,…]` (e.g. "i-frame-interval=1"). Commas allowed.
    public var videoCodecOptions: String? = nil
    public var displayId: Int = 0
    /// Any other `key=value` pairs, appended verbatim after validation (e.g. ["crop": "1080:2400:0:0"]).
    public var extra: [(String, String)] = []

    public init(scid: UInt32 = ServerOptions.randomScid()) { self.scid = scid & 0x7fff_ffff }

    public static func randomScid() -> UInt32 { UInt32.random(in: 0...UInt32(Int32.max)) }

    public static func == (a: ServerOptions, b: ServerOptions) -> Bool { a.arguments == b.arguments }

    /// The same set of characters scrcpy refuses in server parameters (server.c validate_string): the values
    /// are passed through the device shell.
    /// Checked per Unicode scalar: as `Character`s, "\r\n" would be one grapheme and a bare "\n" would slip through.
    static let forbidden = Set(" ;'\"*$?&`#\\|<>[]{}()!~\r\n".unicodeScalars)

    static func validate(_ s: String) throws {
        if s.isEmpty || s.unicodeScalars.contains(where: { forbidden.contains($0) }) { throw MirrorError.invalidServerOption(s) }
    }

    /// `key=value` arguments after the version, in scrcpy's order, omitting values equal to the server default.
    public var arguments: [String] {
        var a = [String(format: "scid=%08x", scid), "log_level=\(logLevel)"]
        if !video { a.append("video=false") }
        if videoBitRate != 8_000_000 { a.append("video_bit_rate=\(videoBitRate)") }
        if !audio { a.append("audio=false") }
        if videoCodec != "h264" { a.append("video_codec=\(videoCodec)") }
        if maxSize > 0 { a.append("max_size=\(maxSize)") }
        if maxFps > 0 { a.append("max_fps=\(maxFps)") }
        a.append("tunnel_forward=true")
        if !control { a.append("control=false") }
        if displayId != 0 { a.append("display_id=\(displayId)") }
        if showTouches { a.append("show_touches=true") }
        if stayAwake { a.append("stay_awake=true") }
        if let o = videoCodecOptions { a.append("video_codec_options=\(o)") }
        if let e = videoEncoder { a.append("video_encoder=\(e)") }
        if !clipboardAutosync { a.append("clipboard_autosync=false") }
        if !powerOn { a.append("power_on=false") }
        for (k, v) in extra { a.append("\(k)=\(v)") }
        return a
    }

    /// The remote command line (one string, run by the device shell via `adb shell`).
    public func remoteCommand() throws -> [String] {
        for arg in arguments { try ServerOptions.validate(arg) }
        return ["CLASSPATH=\(ScrcpyServerPin.devicePath)", "app_process", "/", ScrcpyServerPin.mainClass,
                ScrcpyServerPin.version] + arguments
    }
}
