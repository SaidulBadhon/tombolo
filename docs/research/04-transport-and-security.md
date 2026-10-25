# Tombolo — Transport, streaming protocol, discovery, pairing & security (research 04)

Date: 2026-10-25. Scope: Android phone (Kotlin app) ↔ macOS (Swift app): low-latency mirroring + remote control, several concurrent per-app video streams, audio, notifications, clipboard, SMS, file transfer. USB + LAN first, remote later. FOSS and self-hostable only.

Method: primary sources (source code at tagged releases, official docs, RFCs/drafts, maintainer comments), gathered by me and three parallel research passes (scrcpy protocol; QUIC/WebRTC library landscape; discovery/pairing/key storage). The shared web-search budget ran out late in the work, so a few items are marked **unverified**. Anything marked "inference" is our reasoning, not a quoted fact.

**TL;DR:** QUIC everywhere through one shared Rust core (iroh 1.x / noq) exposed to Kotlin and Swift through UniFFI. On USB, tunnel the QUIC packets over an adb-forwarded TCP socket. Pairing is a QR code shown on the Mac, falling back to a 6-digit SPAKE2 code bound to the TLS exporter (the adb Wireless Debugging design). Device identity uses hardware-backed P-256 keys, plus a per-session authorization signature from the Mac's Secure Enclave (Touch ID). Control messages are Protobuf; media packets carry a small hand-rolled binary header. Section 9 gives the full stack.

---

## 1. How existing tools move frames and input

### 1.1 scrcpy (Genymobile, Apache-2.0) — the closest prior art

Current version **v5.0.1 (2026-10-08)**. v5.0 (2026-10-05) added client-side hardware decoding (`--hwdec=videotoolbox` on macOS) with no wire changes. The last protocol break was **v4.0 (2026-05-12)**. Everything below was read from source at tag v5.0.1.

**Launch.** `adb push scrcpy-server /data/local/tmp/scrcpy-server.jar`, then
`adb shell CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process / com.genymobile.scrcpy.Server 5.0.1 scid=1a2b3c4d key=value…` (about 60 keys).
- The server runs as `uid=shell`; nothing is installed.
- `args[0]` must equal the server's `BuildConfig.VERSION_NAME` **exactly**, or it throws (`Options.java`).

**Sockets.**
- Name: `localabstract:scrcpy_%08x`, from a 31-bit random `scid`.
- Default is `adb reverse`: the desktop listens on 27183–27199 and the device connects out.
- Fallback is `adb forward`: the device's `LocalServerSocket` accepts connections and writes **one dummy 0x00 byte** on the first socket only. The byte exists because an adb forward accepts a TCP connection even when nothing listens on the device.
- Up to **three sockets, always in this order: video, audio, control**. Disabled ones are skipped.
- The first socket carries a **64-byte NUL-padded device name**.
- Over adb, all sockets are multiplexed inside one adb transport (24-byte adb message headers, WRITE payloads ≤ 256 KiB). So over *wireless* adb they share one TCP connection (inference from the adb protocol doc).

**Stream framing (big-endian).**
- **Codec id** (`u32`, ASCII):
  - video: `h264` 0x68323634, `h265` 0x68323635, `av1` 0x00617631, `vp8`, `vp9`
  - audio: `opus` 0x6F707573, `aac`, `flac`, `raw` (s16le)
  - `0` = stream disabled, `1` = config error. Audio is assumed to be stereo 48 kHz.
- **Session packet** (since 4.0; 12 bytes; sent at every capture (re)start, e.g. rotation, fold or resize): byte0 MSB = 1, byte3 bit0 = "client resized", then `u32 width`, `u32 height`.
- **Media packet header** (12 bytes):
  - a `u64`: bit63 = 0 (media), **bit62 = config**, **bit61 = key frame**, bits 0–60 = **PTS in µs**
  - then a `u32` payload length
  - Config packets carry only the config flag (PTS 0).
- **Payloads:**
  - H.264/H.265 payloads are **Annex-B**; the client merges the config (SPS/PPS) into the next frame.
  - Opus/FLAC config packets are rewritten to just `OpusHead` / STREAMINFO.
  - `raw_stream=true` strips all framing.

**Control messages (client → device).** Each message is a 1-byte type plus a fixed or length-prefixed payload. There is **no overall length prefix**, so a parser must know every type.

| ID | Type | Payload |
|---|---|---|
| 0 | INJECT_KEYCODE | action, keycode, repeat, metaState |
| 1 | INJECT_TEXT | u32 length + UTF-8 (≤ 300 B) |
| 2 | INJECT_TOUCH_EVENT | 32 B: action, pointerId u64 (-1 mouse, -2 finger, -3 virtual pinch), position {x i32, y i32, frameW u16, frameH u16}, pressure u16 fixed-point, actionButton, buttons |
| 3 | INJECT_SCROLL_EVENT | position, h/v scroll i16 fixed-point, buttons |
| 4 | BACK_OR_SCREEN_ON | action |
| 5/6/7 | EXPAND_NOTIFICATION_PANEL / EXPAND_SETTINGS_PANEL / COLLAPSE_PANELS | — |
| 8 | GET_CLIPBOARD | copyKey |
| 9 | SET_CLIPBOARD | sequence u64, paste flag, text (≤ 256 KiB − 14) |
| 10 | SET_DISPLAY_POWER | on |
| 11 | ROTATE_DEVICE | — |
| 12/13/14 | UHID_CREATE / UHID_INPUT / UHID_DESTROY | virtual HID devices |
| 15 | OPEN_HARD_KEYBOARD_SETTINGS | — |
| 16 | START_APP | name (`+` = force-stop first, `?` = lookup by label) |
| 17 | RESET_VIDEO | — |
| 18/19/20 | camera torch / zoom in / zoom out | (4.0) |
| 21 | RESIZE_DISPLAY | w, h (4.0, flex display) |
| 22 | SCAN_FILE | path (4.1) |

A detail worth copying: **every positional event carries the frame size it was computed against, and the server drops events whose frame size doesn't match the current video size** (`PositionMapper.java`). This prevents mis-taps right after a rotation or resize.

**Device messages (device → client):** 0 CLIPBOARD (u32 length + text) · 1 ACK_CLIPBOARD (u64 sequence) · 2 UHID_OUTPUT.

**Encoder settings** (`SurfaceEncoder.java`):
- 8 Mbit/s default; `KEY_FRAME_RATE` 60 as a placeholder (the actual rate is variable).
- `KEY_I_FRAME_INTERVAL` 10 s; **`KEY_REPEAT_PREVIOUS_FRAME_AFTER` 100 ms**.
- `KEY_PRIORITY` 0 and `KEY_LATENCY` 1 (since 4.0); `max-fps-to-encoder` for `--max-fps`.
- `KEY_LOW_LATENCY` is not used (it is decoder-only anyway).
- No B-frame config; the client sets dts = pts (assumes no B-frames). On encoder errors it retries at smaller sizes.

**Audio:**
- Android 11+ only.
- Default capture is `REMOTE_SUBMIX` (mutes the phone). `playback` capture needs Android 13+, and apps can opt out of it.
- **Opus 128 kbit/s, client audio buffer 50 ms**.

**Virtual displays** (`--new-display`, `--start-app`, `--flex-display`):
- Flags: PUBLIC | PRESENTATION | OWN_CONTENT_ONLY | SUPPORTS_TOUCH | ROTATES_WITH_CONTENT.
- Android 13+ adds TRUSTED | OWN_DISPLAY_GROUP | ALWAYS_UNLOCKED | TOUCH_FEEDBACK_DISABLED.
- Android 14+ adds OWN_FOCUS | DEVICE_DISPLAY_GROUP.
- This is exactly the mechanism behind "individual phone apps as Mac windows", and it depends on shell privileges. How shell obtains `ADD_TRUSTED_DISPLAY` is **unverified**.

**Stability for third parties: explicitly none.** `doc/develop.md`: *"The protocol between the client and the server must be considered internal: it may (and will) change at any time for any reason … there is no backward or forward compatibility."*
- Example break, 3.3.4 → 4.0: the video header shrank to codec id + session packets, flag bits moved (config 63 → 62, key frame 62 → 61), and control types 18–21 were added.
- How other projects cope:
  - per-version adapters: **Tango / ya-webadb** has one `ScrcpyOptionsX_YY` class per protocol-changing version from 1.15 to 4.1; 5.0/5.0.1 alias 4.1 and were added a day after release. It is the best protocol reference.
  - frozen forks: **ws-scrcpy** at 1.19-ws8, **scrcpy-mask**
  - a pinned bundled jar: **QtScrcpy** pins 4.1
  - wrapping the scrcpy binary: Escrcpy, and the macOS wrappers AndroidMirroring and pocketpane

**Privilege is the real constraint, not framing.**
- Shell holds `INJECT_EVENTS`, `CAPTURE_VIDEO_OUTPUT`, `READ_FRAME_BUFFER`, `CAPTURE_AUDIO_OUTPUT`, `MODIFY_AUDIO_ROUTING`, `START_ACTIVITIES_FROM_BACKGROUND` and `MANAGE_ACTIVITY_TASKS`. A normal app can get none of these.
- **MediaProjection:** user consent before **every** session. On Android 14+ the token is single-use, each projection allows one `createVirtualDisplay()`, and a `mediaProjection` foreground service is required. Single-app capture is offered by default. On **Android 15 QPR1+** there is a large status-bar chip, and *"screen projection automatically stops when the device screen is locked"* (verified on the MediaProjection page).
- **Audio:** `AudioPlaybackCaptureConfiguration` captures only MEDIA/GAME/UNKNOWN usages, and apps can opt out.
- **Input:** AccessibilityService `dispatchGesture` allows ≤ 20 strokes and ≤ 60 s per gesture; live drags need `continueStroke` (API 26).
- **Virtual displays:** only *private* ones, which cannot host other apps.
- **Companion App Streaming** (CDM `COMPANION_DEVICE_APP_STREAMING` + VirtualDeviceManager: trusted virtual displays and input injection, Android 13+) has the right shape, but *"Only preinstalled priv-apps are allowed to hold"* the role. It is OEM-only.

→ **Transport implication:** the Tombolo wire protocol must serve **two server modes**:
- **(a) app mode:** the APK, using MediaProjection + Accessibility; one screen; consent prompts; stops when the phone locks.
- **(b) privileged mode:** a shell-uid helper started via USB adb, Wireless debugging, or a Shizuku-style self-adb. This gives virtual displays per app, `injectInputEvent`, UHID and submix audio.

Both modes must authenticate identically. In privileged mode the helper and the APK are separate processes on the phone.

**Latency evidence.**
- The README's "35~70 ms" links to PR #646: 2019, Nexus 5, both screens photographed while a 30 fps counter video played.
  - 1080×1920: ≈ 100 → 67 ms. `-m800`: ≈ 67 → 33 ms. The client rendered frames 12 ms after packet arrival.
  - The PR doesn't say whether this was USB or Wi-Fi. It was annotated in 2026: "these measurements are very old; more recent devices perform better".
- There are no maintainer numbers for Wi-Fi. rom1v (#4386) attributes Wi-Fi stutter to **TCP head-of-line blocking**: a lost packet delays everything behind it, giving a stall and then a burst of frames. His workaround, `--video-buffer`, adds latency.

### 1.2 Browser-based tools: ws-scrcpy, Tango, Vysor
- **ws-scrcpy** (NetrisTV):
  - A Node server launches a forked scrcpy server (1.19-ws8). That server listens on a **WebSocket at 0.0.0.0:8886 on the device**, or is proxied over adb. Video and input share one WebSocket.
  - Decoders: MSE (H.264 → fMP4), Broadway (WASM), TinyH264, WebCodecs.
  - **No encryption or authentication at any level** — a cautionary example.
- **Tango / ya-webadb:**
  - adb over WebUSB + `@yume-chan/scrcpy` + the WebCodecs `VideoDecoder` (H.264/H.265/AV1 Annex-B) rendered through WebGL.
  - Its docs warn that one blocked stream blocks all of them, because adb multiplexes everything.
- **Vysor** (koush): adb (WebUSB in the browser), installs an APK on the phone, streams H.264, decodes in WASM/NaCl. A WebRTC decoder for "Vysor Share" (2023 post) is **unverified**. No published latency.

### 1.3 Game streaming: Moonlight / Sunshine (all GPL-3.0 — borrow the design, not the code)
- **Ports:** TCP 47984 (HTTPS pairing), 47989 (HTTP), 48010 (RTSP); UDP 47998 video, 47999 control, 48000 audio.
- **Flow:**
  1. HTTPS pairing.
  2. RTSP handshake; the SDP carries `x-ss-general.encryptionSupported/Requested`.
  3. Video over RTP/UDP.
  4. Control over **ENet** (reliable UDP, a custom ABI-incompatible fork). ENet has "generic" and "urgent" channels; urgent carries IDR requests and **reference-frame invalidation**.
- **FEC:** Reed–Solomon (nanors). `fec_percentage` defaults to 20 ("percentage of error correcting packets per data packet in each video frame"). Multiple FEC blocks per frame; the client reports FEC status back.
- **Crypto:**
  - Control: AES-GCM (12-byte IV built from the sequence number + a direction byte).
  - Video/audio encryption is optional; Sunshine's defaults are LAN off, WAN on if the client supports it. Input is always encrypted.
  - Pairing: PIN + salt hashed into an AES key, then a certificate exchange and an RSA signature challenge.
- **Latency:** the Moonlight overlay shows ≈ 6 ms "streaming latency" on a direct cable (1 ms network + ≈ 4.8 ms host + decode). That is not glass-to-glass.

### 1.4 Other reference systems (brief)

**Parsec BUD (proprietary).**
- UDP "encrypted with DTLS 1.2 (via OpenSSL)", with TCP-like reliability.
- A "highly tuned and custom congestion control algorithm" tries to "detect a congestion event before it starts", and is tightly coupled to the encoder bitrate.
- Claims 97 % NAT traversal (STUN on 3478, UPnP).
- They tested WebRTC and rejected it, except for the browser client.
- FEC and the bandwidth-estimation details are **unverified** (not public).

**RustDesk (AGPL-3.0).**
- Servers: hbbs (ID/rendezvous) and hbbr (relay). Ports: 21115 TCP (NAT test), 21116 UDP+TCP (register / hole punching), 21117 TCP (relay), 21118/21119 (WebSocket). The per-port purposes come from third-party summaries.
- Protobuf in `rendezvous.proto` (RegisterPeer, PunchHoleRequest, RequestRelay, …) and `message.proto` (LoginRequest, EncodedVideoFrame, MouseEvent, FileAction, …).
- Crypto: Ed25519-signed peer keys; an ephemeral Curve25519 `box_` seals a random `secretbox` session key (XSalsa20-Poly1305).
- Transports: TCP hole punching, KCP over UDP, and webrtc-rs data channels with patched SCTP. The SCTP patch is needed because the "1s RTO floor makes a single loss cost 1-3s".

**Microsoft Phone Link.**
- No public protocol documentation.
- Requires the same Wi-Fi network. Pairing is a QR code tied to the Microsoft account. There is optional "sync over mobile data", which implies a cloud path (inference).
- Screen mirroring uses the MediaProjection consent prompt, and full "Apps" mirroring is limited to OEM phones with Link to Windows preinstalled (details **unverified**).
- Reviews call it "laggy"; no ms measurements were found.

**Apple iPhone Mirroring.**
- Uses a "local wireless peer-to-peer connection" with the same mutually authenticated STS protocol as Auto Unlock: long-term keys exchanged when the feature is enabled, ephemeral session keys per request. The Mac's Secure Enclave enforces the authentication policy (Platform Security guide).
- AWDL as the transport is **unverified**.
- **No published latency measurement**; reviewers describe "virtually no lag".

**Chromecast mirroring (Cast Streaming / Open Screen libcast).**
- Its own RTP/RTCP, written from scratch, with an OFFER/ANSWER negotiation.
- One Sender/Receiver pair per stream; receiver ACKs and retransmission requests; encrypted payloads; a TLS control channel (8010).

**Miracast.**
- Wi-Fi Direct + RTSP (TCP 7236) + MPEG2-TS over RTP/UDP; HDCP; UIBC for input.
- Certification allows up to **250 ms** end-to-end. Microsoft's "low" latency mode SHOULD be < 50 ms; Mersive measures 100–166 ms in practice.

**AirPlay mirroring.**
- Proprietary with FairPlay; H.264/H.265.
- Reverse-engineered by UxPlay/RPiPlay (legacy ports TCP 7000/7001/7100, UDP 6000/6001/7011).
- Reference only.

**Takeaways for Tombolo:**
1. Every serious low-latency system ties transport feedback directly into the encoder: Parsec, Moonlight (IDR/RFI requests over an urgent channel), Cast (ACK/NACK).
2. TCP is fine on USB and acceptable on clean Wi-Fi, but its head-of-line blocking and sender-side buffering are the known failure modes (scrcpy #4386).
3. Nobody's protocol is a stable public contract we could adopt. We design our own and borrow the good ideas:
   - scrcpy's framing and frame-size-stamped input
   - Moonlight's urgent channel and FEC knobs
   - adb's pairing (Section 5)

---

## 2. Transport options (LAN, latency-first, multiple streams)

**Hard constraint (verified, adb.1.md):** `adb forward` / `adb reverse` carry only `tcp`, `localabstract`, `localreserved`, `localfilesystem`, `jdwp`, `vsock`, `acceptfd` and `dev` — **no UDP**. So QUIC, WebRTC and SRT can only use the USB path as packets tunnelled over a TCP stream, which requires a stack that lets you supply your own I/O. The alternatives are user-enabled USB tethering (CDC-NCM works natively on macOS, but only some phones such as Pixel 6+ use NCM; most still use RNDIS, which macOS doesn't support) or Android Open Accessory (Section 2.4).

### 2.1 Comparison

| Option | HOL impact on video | Congestion control | NAT traversal | Encryption | Multi-stream | Android | macOS | Works over adb USB | Effort | License |
|---|---|---|---|---|---|---|---|---|---|---|
| Raw TCP + `TCP_NODELAY` (scrcpy) | Per connection: one loss stalls everything behind it (~1 RTT; an RTO if it is the tail packet) | Kernel (Cubic); sender-buffer bloat unless `TCP_NOTSENT_LOWAT` is set | None | **None** | One connection per channel | Platform | Platform | **Yes** | Lowest | — |
| TLS 1.3 over TCP | Same as TCP | Same | None | Yes (Conscrypt/BoringSSL; Network.framework) | One connection per channel, or a mux | Platform | Platform | **Yes** | Low | — |
| UDP + custom RTP (Moonlight/Parsec style) | None (app decides) | **You build it** (delay-based + FEC + NACK) | STUN-style punching (DIY) | DIY (DTLS / AES-GCM) | Yes | DIY | DIY | Only tunnelled | High | — |
| QUIC, platform-native (Network.framework + Android lib) | None across streams; datagrams have none at all | Library (Cubic/NewReno/BBR) + app-level | None built in | TLS 1.3 built in | Native streams + RFC 9221 datagrams | **No good native server lib** (see 2.2) | `NWProtocolQUIC` 12+; datagrams 13+ but mis-modelled; new `NetworkConnection` API on 26+ has open bug FB25125957 | No (Network.framework can't run over a non-UDP transport — **unverified**) | Medium-high, two different stacks | — |
| **QUIC, shared Rust core (quinn / noq / iroh)** | Same as above | Same on both ends | **iroh: QUIC NAT traversal + relays** | TLS 1.3 (rustls) | Yes | Yes (noq lists Android; iroh ships Kotlin bindings) | Yes (iroh-ffi xcframework) | **Yes, via a custom socket / transport tunnel** | Medium; Rust toolchain in both builds; ~13 MB native per ABI | MIT/Apache-2.0 |
| WebRTC (libwebrtc) | Depends on mode; built-in jitter buffer must be tuned to 0 | **GCC/transport-cc, NACK/RTX, ULPFEC, FlexFEC (receive)** built in | **ICE/STUN/TURN** | DTLS-SRTP | Tracks + SCTP data channels (weak for bulk) | webrtc-sdk/android M150 AAR: 12.3 MB arm64 full, 7.7 MB stripped (uncompressed) | LiveKit xcframework 69 MB zip; stasel M155 45 MB zip | **No** | High: SDP/ICE, field trials, playout-delay tuning | BSD-3 + patent grant |
| SRT (libsrt) | Fixed TSBPD latency buffer (default 120 ms; ~3–4×RTT recommended) | Mostly a bandwidth cap in live mode (**unverified**) | Rendezvous mode | AES | **No stream multiplexing** | Build guides | Build guides | Tunnel only | Medium | MPL-2.0 |
| WebSocket (ws-scrcpy) | Same as TCP | TCP | None | Optional TLS | Single socket | Easy | Easy | Yes | Low | — |

**Head-of-line blocking, concretely:**
- In TCP, one lost segment blocks *all* bytes behind it on that connection: the other windows' video, audio and input if they share it.
- QUIC confines a loss to its own stream, and DATAGRAM frames are never retransmitted (RFC 9221). DATAGRAMs are still congestion-controlled and ACK-eliciting, but not flow-controlled.
- *Within* one video stream, ordered delivery is needed anyway (P-frames reference earlier frames), so the per-stream HOL cost is unavoidable without FEC or reference invalidation. The real wins are isolation between streams and control over what sits in the sender's queue.

### 2.2 QUIC library landscape (as of 2026-10)

| Library | License | Server role | RFC 9221 datagrams | Android | macOS | Notes |
|---|---|---|---|---|---|---|
| Network.framework `NWProtocolQUIC` | Apple | Yes (`NWListener.newConnectionGroupHandler`, 12+) | 13+ via `isDatagram`; DTS: the old group API "doesn't really model datagrams correctly" | — | 12+ | New async `NetworkConnection` (26+) has `openStream`, `inboundStreams`, `datagrams`. Open bug FB25125957 (macOS 27.0.1): `usableDatagramFrameSize` returns 0. Client groups silently own stream 0. Pinning via `sec_protocol_options_set_verify_block`. |
| apple/swift-nio-quic | Apache-2.0 | Yes | not stated | — | 26+, Swift 6.3 | Pre-1.0, "does not offer a stable API yet"; underlying Apple QUIC types are SPI. Not production-ready. |
| Cronet / `android.net.http.HttpEngine` | BSD | **No** | No | Yes | — | HTTP client only (`BidirectionalStream` = HTTP streams). No raw QUIC; WebTransport not found (**unverified**). |
| kwik 0.12.1 | **LGPL-3.0+** | Yes | Yes | not stated | — | Pure Java. The author says performance is "not optimal yet" and his TLS is "not security tested nor reviewed". |
| netty-incubator-codec-quic (quiche JNI) | Apache-2.0 | Yes | Yes | **No Android natives** in current artifacts | yes | Only an old 0.0.22 AAR existed. |
| quiche 0.30.0 (Cloudflare) | BSD-2 | Yes | Yes | Yes (cargo-ndk, API 21+) | yes | C FFI, sans-I/O (you own sockets/timers) → can be tunnelled. BoringSSL. |
| quinn 0.11.12 | MIT/Apache | Yes | Yes | README lists Linux/macOS/Windows only | yes | rustls; supports custom sockets. |
| **noq 1.4.0** (n0's quinn fork) | MIT/Apache | Yes | Yes | **Yes** ("Linux, Windows, macOS, android, iOS and wasm") | yes | Adds QUIC multipath, address discovery, NAT traversal. |
| **iroh 1.x** (1.0 on 2026-06-15; crate 1.4.x) | MIT/Apache | Yes (p2p endpoints) | Yes | **Yes**: official Kotlin bindings; Android JNI init (`IrohAndroid.installAndroidContext`); arm64 `.so` ≈ 12.8 MB | **Yes**: xcframework (iOS + macOS) via SwiftPM/CocoaPods | `iroh-ffi` (UniFFI) exposes `openBi/acceptBi/openUni/acceptUni`, `sendDatagram/readDatagram/maxDatagramSize`, stream `setPriority/reset/stop`, `rtt()`, stats, custom relay maps. Wire-stable within a major version. FFI has **no mDNS** (we do discovery ourselves). Prebuilt Android AAR vs build-it-yourself (NDK + cargo-make) is ambiguous (**unverified**). |
| MsQuic v2.6 | MIT | Yes | Yes | "best-effort … no support guarantee" | best-effort | Officially supported only on Windows/Linux. |
| ngtcp2 / lsquic / s2n-quic / mvfst | MIT / MIT / Apache / MIT | Yes | Yes | DIY / tested on ARM / undocumented / impractical (folly) | — | s2n-quic: reported datagrams > ~1000 B never arrive (#2520). |
| kuicksilver 0.2.0 (KMP) | Apache-2.0 | Yes | Yes | minSdk 24 | — | "experimental. Do not use it in production". |

Real Android apps with an on-device QUIC listener:
- Syncthing (22000/UDP QUIC); whether its Android builds keep the listener on is **unverified**.
- iroh is deployed on Android: 1.0.1 fixed an Android DNS-resolver JNI panic.

### 2.3 WebRTC details (for the record)
- **Prebuilts:** `io.github.webrtc-sdk:android` 150.7871.04 (LiveKit fork, updated 2026-10-23; `-prefixed-stripped` variant drops software codecs). GetStream's `stream-webrtc-android` is slower-moving (last 2025-09). macOS: livekit/webrtc-xcframework, stasel/WebRTC M155. Building from source means depot_tools and a multi-GB checkout.
- **APK cost:** roughly 5–6 MB download and 8–12 MB installed per ABI.
- **Low-latency knobs:**
  - the playout-delay RTP header extension with min = max = 0 ("render as soon as possible", intended for gaming/remote access)
  - `SetJitterBufferMinimumDelay` / `jitterBufferTarget = 0`
  - One report still shows ~100 ms unexplained render lag with min = 0.
- **FlexFEC:** always receivable; sent only with field trial `WebRTC-FlexFEC-03-Advertised`.
- **Alternatives:**
  - webrtc-rs 0.21 (MIT/Apache; being rebuilt on a sans-I/O core)
  - Pion (MIT, Go; gomobile can't bind its API directly)
  - libdatachannel (**MPL-2.0** since 0.18; no CC/jitter buffer per README)
  - GStreamer webrtcbin (LGPL, heavy)

### 2.4 USB link options
1. **adb forward/reverse (TCP / localabstract).**
   - Needs Developer options + USB debugging. Proven by scrcpy; ~1 ms RTT; lossless.
   - Also the only way to start a privileged shell helper.
2. **Android Open Accessory (AOA).**
   - The Mac acts as USB host and sends vendor control requests 51/52/53 (get protocol / send strings / start). The phone re-enumerates as VID 0x18D1, PID 0x2D00 (accessory) or 0x2D01 (accessory + adb), exposing bulk IN/OUT endpoints. The app opens it through `UsbManager`/`UsbAccessory`.
   - USB debugging is not required.
   - **AOA 2.0 HID** (requests 54–57) lets the host register a HID keyboard/mouse that is passed straight to Android's input system. This is input injection **without adb or Accessibility** (scrcpy's OTG mode uses it).
   - AOA audio was deprecated in Android 8.0, and AOA cannot coexist with MTP.
   - Feasibility from a sandboxed macOS app via IOUSBHost/libusb: **needs prototyping**.
   - Wired Android Auto is believed to run H.264 over AOA (prior knowledge, **unverified**).
3. **USB tethering (CDC-NCM).** A real IP link, so UDP/QUIC works natively. It is phone-dependent (Pixel 6+ NCM; most phones RNDIS, which macOS can't use) and hijacks the Mac's routing. Not a primary path.

### 2.5 Recommendation

**v1 (USB + LAN): QUIC through one shared Rust transport core, used on both ends.**
- Base it on **iroh 1.x / noq** (MIT/Apache), exposed to Kotlin and Swift via UniFFI. Use iroh-ffi as-is if it suffices; otherwise write a thin crate of our own on iroh's Rust API (needed for the USB tunnel).
- **Wi-Fi:** native UDP.
- **USB:** the same QUIC packets carried over an adb-forwarded TCP socket (2-byte length prefix per packet) as a custom socket/transport. Over a lossless USB link, QUIC-over-TCP has no HOL penalty. Later, the same framing can run over AOA bulk endpoints.
- **Why one core:**
  - one implementation of CC, datagrams, priorities and bugs on both ends
  - the Android *server* role is first-class
  - per-window streams with priorities, plus datagrams for audio and pings
  - TLS 1.3 everywhere, including USB
  - the same code becomes v2 remote
- **Cost:** ≈ 13 MB native per Android ABI, plus a universal binary on the Mac, and a Rust toolchain in both builds.
- **Fallback if the Rust core or tunnel disappoints in prototyping:** the same channel model on **TLS 1.3 over one TCP connection per channel** (scrcpy-proven), using the platform TLS stacks. The channel layer stays transport-agnostic for exactly this reason.

**v2 (remote):** keep QUIC. Use iroh's NAT traversal and multipath, a **self-hosted `iroh-relay`** (optionally `iroh-dns-server`), and the same pinned identities. WebRTC (+ coturn) is reserved for a possible browser client.
- Rejected for v1: WebRTC (size, SDP/ICE, tuning, weak bulk path, no USB) and Network.framework + a JVM QUIC library (no good Android server library; Mac datagram API broken or 26+ only; can't tunnel over adb).

---

## 3. Latency budget

### 3.1 Published / observed numbers

| System | Path | Number | Kind of measurement | Source |
|---|---|---|---|---|
| scrcpy | not stated (2019, Nexus 5) | ≈ 67 ms at 1080×1920, ≈ 33 ms at `-m800`; README claims "35~70 ms" | Both screens photographed, 30 fps counter video (screen-to-screen) | scrcpy PR #646 |
| scrcpy | Wi-Fi | no maintainer numbers; stutter attributed to TCP retransmission HOL | qualitative | scrcpy #4386 |
| Moonlight + Sunshine | direct cable | ≈ 6 ms "streaming latency" (network 1 ms + host ≈ 4.8 ms + decode) | stats overlay, not glass-to-glass | note.com blog |
| Moonlight + Sunshine | wired LAN / 5 GHz Wi-Fi | ≈ 12–16 ms avg (spikes > 30 ms) / ≈ 24 ms avg (spikes ≈ 60 ms) | overlay; secondary source, **unverified** | tech-insider.org |
| Miracast | Wi-Fi Direct | ≤ 250 ms (certification); MS "low" mode < 50 ms; 100–166 ms in practice | spec / vendor note | Wi-Fi Alliance; Microsoft Learn; Mersive |
| iPhone Mirroring | Apple P2P wireless | **no measurement found** ("virtually no lag") | subjective | Android Authority / Android Police |
| Phone Link | Wi-Fi | **no measurement found** ("laggy") | subjective | How-To Geek |

### 3.2 Budget breakdown (video, phone → Mac, 1080p60)

| Stage | Typical | Worst-case contributors | Levers |
|---|---|---|---|
| Compose → capture surface | 0–16.7 ms (waits for vsync, ≈ ½ frame on average) | virtual display refresh, SurfaceFlinger load | 60–120 Hz virtual displays; no extra GPU copies |
| HW encode (MediaCodec) | ≈ 3–15 ms (SoC-dependent, **unverified**) | B-frames, lookahead, RC buffering, many concurrent encoders | `KEY_MAX_B_FRAMES=0`, `KEY_PRIORITY=0`, `KEY_LATENCY=1` |
| Packetise + kernel send | < 1 ms | **sender-side buffering**: Apple found 2 s of unsent frames in early Mac Screen Sharing (Cheshire, WWDC15 / IETF 122 SBM) | `TCP_NOTSENT_LOWAT`; app-level queue limit; QUIC send-buffer checks |
| Transmit the frame | P-frame 10–40 KB → < 3 ms; **IDR 150–400 KB → 12–32 ms at 100 Mbit/s effective** (arithmetic, not measured) | rate drops, retransmits, IDR bursts | intra-refresh instead of periodic IDR; pacing |
| Network one-way | USB ≈ 1 ms; Wi-Fi LAN 1–5 ms | phone Wi-Fi power save (≈ a beacon interval, ~100 ms), scans, **macOS AWDL channel hops** | low-latency Wi-Fi lock; steady traffic; 5/6 GHz; prefer USB |
| Jitter buffer | **0 ms for video** | any fixed buffer adds its full depth | decode on arrival; latest frame wins |
| HW decode (VideoToolbox) | ≈ 1–5 ms (**unverified**) | software fallback, frame reordering | require the HW decoder; no B-frames upstream |
| Render → photons | 0–16.7 ms (vsync) + panel response | double/triple buffering | `CAMetalLayer` + `CAMetalDisplayLink(preferredFrameLatency = 1)` |

Estimated totals (our arithmetic, **not measurements of Tombolo**):
- **USB ≈ 30–60 ms** glass-to-glass.
- **Wi-Fi ≈ 40–80 ms**, with 100 ms+ tails.

Click-to-photon adds the input path (1–5 ms on a good link; more if the phone radio is dozing) plus 1–2 frames for the phone app to react.

### 3.3 Techniques

**Encoder (Android MediaCodec; key semantics verified against the MediaFormat reference).**
- `KEY_MAX_B_FRAMES = 0` (API 29; "0 … means that no B frames are allowed" — also the default).
- `KEY_PRIORITY = 0` (realtime).
- `KEY_LATENCY = 1` (API 26; ignored if unsupported, so read it back from `getOutputFormat()`).
- **`KEY_INTRA_REFRESH_PERIOD`** (API 24): the docs say it "is recommended for video streaming applications as it provides low-delay and good error-resilience". It only applies with `FEATURE_IntraRefresh`.
  - Combine it with a very long GOP (`KEY_I_FRAME_INTERVAL` negative = "only the first frame is a key frame").
  - Get IDR on demand with `PARAMETER_KEY_REQUEST_SYNC_FRAME` when the Mac reports a gap or decoder error, or opens a new window.
- **Runtime adaptation:** `PARAMETER_KEY_VIDEO_BITRATE`.
- **Background windows:** cap fps with `KEY_MAX_FPS_TO_ENCODER` (API 29).
- **Static screens:** `KEY_REPEAT_PREVIOUS_FRAME_AFTER` (scrcpy uses 100 ms), so a static screen still emits frames.
- **Codec config:** send SPS/PPS/VPS as explicit config packets rather than relying on `KEY_PREPEND_HEADER_TO_SYNC_FRAMES`, which *fails configure* if unsupported.
- **`KEY_LOW_LATENCY`** (API 30) is **decoder-only**, so irrelevant on the phone.
- **Concurrency:** `getMaxSupportedInstances()` is only "a hint for an upper bound".
  - Plan for one high-fps stream (focused window) plus several low-fps, low-bitrate streams (background windows, 5–15 fps).
  - Probe at runtime.
  - No Android public API for reference-frame invalidation / long-term references was found (vendor extensions only, **unverified**).

**Decoder / display (macOS).**
- `VTDecompressionSession` with `RequireHardwareAcceleratedVideoDecoder`, decoding on arrival.
- Moonlight-qt's `vt_metal.mm` (read):
  - FFmpeg VideoToolbox hwaccel into a `CAMetalLayer`
  - `displaySyncEnabled` follows the user's V-Sync setting
  - on macOS 14+ / Apple Silicon, a `CAMetalDisplayLink` with `preferredFrameLatency = 1.0`
  - Simpler path: `AVSampleBufferDisplayLayer` (Moonlight's `vt_avsamplelayer.mm` paces it with `CVDisplayLink`).
- If two decoded frames wait for one vsync, present the newest.

**Network and pacing.**
- `TCP_NODELAY` everywhere TCP exists. **`TCP_NOTSENT_LOWAT`** on phone-side TCP sockets in fallback mode (Linux ≥ 3.12 and macOS; Android availability via `Os.setsockoptInt` is **unverified**).
- In QUIC, check `datagram_send_buffer_space()` and the stream write backlog before writing.
- **Receiver feedback** every 50–100 ms on the control stream: bytes received, inter-arrival jitter, one-way delay gradient (sender capture timestamp vs arrival), losses and decode errors. The sender runs a delay-based estimator (GCC-like). Loss-based QUIC/TCP CC alone reacts too late.
- **Escalation when the per-stream queue exceeds ≈ 1 frame-time:**
  1. cut the bitrate
  2. cut the fps of background windows
  3. as a last resort, drop the queue up to the next refresh point and request a sync frame
- **Phone Wi-Fi:** `WifiManager.WIFI_MODE_FULL_LOW_LATENCY` (API 29). Verified caveat: it is active only when connected to an AP, **with the screen on and the app in the foreground**. `WIFI_MODE_FULL_HIGH_PERF` was deprecated in API 34 and is silently converted to the low-latency lock. With the phone screen off (privileged mode, phone "locked"), keep a heartbeat every 50–100 ms so the radio doesn't doze (**needs measurement**).
- **Mac Wi-Fi:** AWDL (AirDrop/Handoff/Universal Control/iPhone Mirroring) periodically hops the single radio off-channel → regular latency spikes.
  - `ifconfig awdl0 down` needs root, and macOS re-enables AWDL within minutes.
  - Tools like Stop Stutter / WiFriedX exist; per-hop figures (~50–100 ms, ~1/s) are community claims (**unverified**).
  - Ship a diagnostic and recommend USB for latency-critical use.

**Audio.**
- Opus, 10–20 ms frames, sent as QUIC datagrams so video retransmissions never delay audio.
- Adaptive jitter buffer starting around 40–60 ms (scrcpy defaults to 50 ms), with drift compensation.
- No strict lip-sync: video is shown as soon as possible.

---

## 4. Discovery

### 4.1 How existing tools discover peers

| Tool | Mechanism | Details |
|---|---|---|
| **KDE Connect** (GPL) | UDP broadcast on **1716** with identity JSON (`deviceId`, `deviceName`, `protocolVersion`, `tcpPort`), plus **mDNS `_kdeconnect._udp`** (TXT `id`, `name`, `type`, `protocol`) as a hint; TCP **1716–1764** | Newline-terminated JSON packets. Protocol v8 (v7 support dropped on master 2026-09-13). |
| **LocalSend** (app Apache-2.0; protocol repo has **no detected license**) | UDP multicast **224.0.0.167:53317** announce (`alias`, `version`, `deviceModel`, `deviceType`, `fingerprint`, `port`, `protocol`, `announce`) → reply via `POST /api/localsend/v2/register` or multicast `announce:false`; legacy fallback: HTTP `/register` scan of every IP in the subnet; HTTP(S) on TCP 53317 | That group was chosen because "some Android devices reject any other multicast group". |
| **adb Wireless Debugging** | mDNS `_adb-tls-pairing._tcp`, `_adb-tls-connect._tcp` (and `_adb._tcp`) | Service name defaults to the device GUID. |
| **Quick Share** (per NearDrop) | mDNS `_FC9F5ED42C8A._tcp` (from SHA256("NearbySharing")), triggered by a BLE advertisement (UUID 0xFE2C + service data) | macOS can't send BLE service data, so NearDrop uses a QR URL instead. |

### 4.2 Platform realities

**Android NsdManager:**
- On **Android 14+**, `NsdService` uses the mainline Java `MdnsDiscoveryManager`/`MdnsAdvertiser`. On ≤ 13 it uses the legacy mdnsresponder path.
- Only the legacy path returns `FAILURE_ALREADY_ACTIVE` for a second concurrent resolve per client, so **serialize resolves on ≤ 13**.
- `resolveService` was deprecated in API 34 ("may get stale"); use `registerServiceInfoCallback` (API 34 / T-ext).
- **MulticastLock:** required "even when the app is in the foreground" before T-extensions 7. After that the system handles it for foreground apps.

**Android local-network permission:**
- **Android 17 (target API 37):** the runtime permission `ACCESS_LOCAL_NETWORK` (NEARBY_DEVICES group) is required. Without it, TCP, UDP unicast/multicast/broadcast, NsdManager and `.local` resolution are all blocked (TCP → timeouts, UDP → `EPERM`).
- `DiscoveryRequest.FLAG_SHOW_PICKER` grants access to one chosen device without the permission. Advertising always needs it.
- Android 16: opt-in compat flag only.
- Whether loopback/adb-forwarded traffic is exempt: **unverified**.
- jmDNS gives no advantage, since raw multicast needs the same permission.

**macOS (TN3179):**
- Local Network privacy applies from macOS 15. Info.plist needs `NSLocalNetworkUsageDescription` and `NSBonjourServices` (`_tombolo._udp`).

| Operation | Needs Local Network permission on macOS |
|---|---|
| Outgoing TCP | Yes |
| Accepting incoming TCP | **No** |
| Sending UDP (unicast/multicast/broadcast) | Yes |
| Receiving UDP unicast | No |
| Receiving UDP multicast | Yes |

- QUIC from the Mac therefore needs the permission.
- Terminal-launched builds are auto-allowed, which hides missing prompts in testing.
- Sign with an Apple-issued identity.
- Use `NWBrowser` for Bonjour browsing.

**Network isolation:**
- Guest, hotel and enterprise Wi-Fi often block multicast and/or all client-to-client traffic, or put clients on separate VLANs/bands. This is general knowledge (**unverified** specifics); Phone Link troubleshooting lists the same failure causes.
- Detection: the mDNS browse times out, *and* a direct probe to a known or QR-supplied address fails.

**BLE (presence and wake):**
- Android advertising needs `BLUETOOTH_ADVERTISE` (API 31+), and continuous background use needs a foreground service (`connectedDevice` type; CompanionDeviceManager presence is suggested instead).
- macOS `CBPeripheralManager` can advertise only the local name + service UUIDs (**no service data**). So the **phone advertises and the Mac scans**.
- Background-scan behaviour on macOS: **unverified**.
- Treat proximity as a UX hint, not security. Apple doesn't require secure ranging for iPhone Mirroring.

**USB detection:**
- adb: the adb server `host:track-devices` service (what `adb track-devices` uses) gives plug and unplug events.
- AOA: IOKit/IOUSBHost device-matching notifications.

### 4.3 Tombolo discovery design
1. **Phone advertises** DNS-SD `_tombolo._udp` (QUIC port) while a foreground service is running or the app is open. The Mac browses.
   - TXT: `v=1` (protocol major) and `t=<rotating token>`, where the token is HMAC(pairing secret, 15-min epoch) truncated to 8 bytes.
   - Paired Macs recognise the token; strangers can't track the device across networks.
   - **No device name and no static ID in TXT.**
   - Unpaired, pairing-mode advertisement: `p=1` only, shown only while the pairing screen is open.
2. **Last-known addresses** cache per paired device (IPv4/IPv6 + port). Try them in parallel with the browse (happy-eyeballs style).
3. **QR code / manual IP** fallback: the pairing QR includes the Mac's addresses; manual entry is supported for isolated networks and VPN/overlay setups.
4. **USB:** `host:track-devices` → the Mac sets up `adb forward tcp:<p> localabstract:tombolo_<rand>` automatically when the user has enabled "USB via adb".
5. **BLE** (v1.x, optional): the phone advertises a rotating token for "phone is nearby" and to wake or prompt the session. Never trusted for auth.
6. Discovery is only a **hint**. Identity is always proven in the handshake (Section 5); the UI shows the name stored at pairing time.

---

## 5. Pairing, encryption and threat model

### 5.1 How others pair

| System | Pairing UX | Crypto | Weakness / lesson |
|---|---|---|---|
| **KDE Connect** v8 | Request/accept (30 s timeout); both sides show an 8-hex-char "verification key" | Self-signed certs (RSA-2048 default, P-256 optional), **reversed TLS roles** (TCP client = TLS server); key = `sha256(sorted(pubA, pubB) ‖ timestamp)` → first 8 hex chars (32 bits) | 32 bits and no commitment → an active MITM can grind keys to match in ~2^16 work per side (our analysis, not a published finding). Users skip the comparison. **CVE-2025-66270** (critical): pre-TLS and post-TLS device IDs weren't cross-checked → impersonation. **Lesson: bind identity to the key.** |
| **LocalSend** v2.x | None (optional `?pin=` since 2.1) | HTTPS, self-signed RSA-2048 certs that never expire; `fingerprint` = SHA-256 of the cert; the app pins the fingerprint learned from the unauthenticated multicast announce, else "trust on first use" | TOFU from unauthenticated discovery. Fine for file drop, **not a basis for remote control**. A v3 draft (diagrams only) adds nonces, Ed25519-signed tokens and `/pair`. |
| **Moonlight/Sunshine** | 4-digit PIN | PIN + salt → AES key; cert exchange; RSA challenge/response | Low-entropy PIN used as a key (offline-guessable from a transcript). |
| **adb Wireless Debugging** | QR `WIFI:T:ADB;S:<name>;P:<password>;;` or a 6-digit code | TLS 1.3 (cert check off) → export 64 bytes of keying material (label `"adb-label"`) **appended to the password** → BoringSSL **SPAKE2** → HKDF-SHA256 → AES-128-GCM → exchange `PeerInfo` (RSA pubkey / GUID). Later connections use mutual TLS 1.3. | **The template to copy**: a MITM has two TLS sessions → two exporters → SPAKE2 fails; each online try is one guess, so 6 digits suffice. Trusted networks are tracked by BSSID. |
| **Quick Share** (per NearDrop) | 4-digit PIN from the auth string | UKEY2 (P-256) → HKDF → AES-256-CBC + HMAC-SHA256 | Proprietary but documented by NearDrop; Google's own Nearby code is Apache-2.0 (google/nearby). |
| **Apple iPhone Mirroring** | Same Apple Account + 2FA, nearby; "ask every time" (password/Touch ID/Watch) or "authenticate automatically" | STS with long-term keys + ephemeral session keys; **the Mac Secure Enclave enforces the auth policy**; the Mac identity is pinned | Persistent notice on the iPhone lock screen; usage log (which Mac, when, how long); the session ends when the iPhone is unlocked. |

### 5.2 Building blocks compared

- **Mutual TLS 1.3 with pinned self-signed certs.**
  - Platform-native and well tested (Conscrypt/BoringSSL; Network.framework). Supports **hardware P-256 keys**.
  - Both platforms expose the TLS exporter: Android `android.net.ssl.SSLSockets.exportKeyingMaterial` (API 31+; bundled Conscrypt before that), and macOS `sec_protocol_metadata_create_secret[_with_context]`. The latter reportedly matches OpenSSL output under TLS 1.3 (forum evidence).
  - In QUIC (rustls/quinn/noq), exporter access is a library API. That iroh exposes it is **unverified, needs checking**.
- **Noise** (rev 34).
  - `XX` (mutual, no prior knowledge), `IK` (initiator knows the responder's key, e.g. from the QR), `KK` (reconnect with known keys).
  - PSK modes require **256-bit PSKs**; a 6-digit code must not be a PSK.
  - Used by WireGuard (`Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s`) and WhatsApp.
  - Libraries are small and unaudited: JVM noise-java (stale since 2024-03), java-noise (2025-04); Swift swift-noise (libp2p, v0.1.1); best is Rust **snow** (Apache-2.0) via UniFFI.
  - Only 25519/448 curves, so **no Secure Enclave / StrongBox backing**.
- **PAKEs.**
  - SPAKE2 = RFC 9382 (2023). BoringSSL's implementation follows draft-02 and is not public API in swift-crypto; Bouncy Castle has no SPAKE2 or CPace; RustCrypto `spake2` exists (never independently audited).
  - **CPace** = draft-irtf-cfrg-cpace-21, sent to the RFC Editor, no RFC number yet; no Kotlin/Swift implementation found.
  - OPAQUE = RFC 9807, which is client–server shaped and wrong for peer pairing.
- **Key storage.**
  - Android KeyMint requires TEE support for Ed25519/X25519, but "**STRONGBOX … do not support curve 25519**". StrongBox supports P-256 ECDSA/ECDH, RSA-2048, AES and HMAC.
  - Secure Enclave keys are **P-256 only**, non-importable, and gated by `SecAccessControl` (`.privateKeyUsage` + `.userPresence` / `.biometryCurrentSet`) with `LAContext`.
  - ⇒ **P-256 is the only curve with hardware backing on both sides.**
  - Ed25519 Keystore availability by API level, and `setUnlockedDeviceRequired` semantics: **unverified**.

### 5.3 Tombolo pairing design

**Two key layers per device:**
- **Transport key:** the iroh Ed25519 endpoint key. It is the QUIC/TLS raw public key and the "address" for remote use. Software key, stored encrypted at rest under a hardware-backed wrapping key (Android Keystore AES-GCM; macOS Keychain `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
- **Device identity key:** **P-256 in StrongBox/TEE (Android) and the Secure Enclave (Mac)**, non-exportable. At every session start it signs `TLS-exporter("tombolo/session/v1") ‖ both endpoint IDs ‖ session nonce`.
  - The Mac's SE key can carry a `.userPresence` access control, so **"ask every time" is enforced by the Secure Enclave**, as Apple does.
  - If prototyping shows the two-key design isn't worth it, drop to the transport key only, plus an app-level Touch ID gate.

**Primary pairing: QR shown on the Mac, scanned by the phone.**
- QR payload: `tombolo://pair?v=1&id=<Mac endpoint id>&a=<ip:port,…>&k=<SHA-256(Mac P-256 SPKI)>&s=<256-bit one-time secret>&exp=<unix>`.
- Flow:
  1. The phone dials `id` at `a`. QUIC/TLS pins `id` from the QR.
  2. The phone sends `PairRequest{phone P-256 pubkey, name, model, HMAC(s, exporter ‖ transcript), sig_phone(exporter ‖ transcript)}`.
  3. The Mac verifies the HMAC (the phone saw the QR) and the signature, then replies `PairAccept{Mac P-256 pubkey, HMAC, sig_mac}`.
  4. The phone checks `SHA-256(Mac SPKI) == k`.
  5. The secret is single-use with a TTL of about 2–5 min.
- The phone then asks for explicit **scopes** (view/control/notifications/SMS/files/clipboard).

**Fallback pairing: 6-digit code.** Shown on the phone, typed on the Mac. SPAKE2 (RFC 9382) or CPace from the shared Rust core, with `password = code ‖ exporter` (the adb design), at most 3 attempts per code.

**USB.** The adb tunnel is **not** treated as authenticated: an adb-forwarded localabstract socket is reachable by other processes on the phone. The same QR or code flow runs over it.

**Every later connection:**
- pinned endpoint IDs (unknown keys are rejected silently, with no prompts)
- the P-256 session signatures
- a `Hello` with a per-session nonce
- 0-RTT disabled for control

**Re-auth policy** (defaults in brackets):
- Mac "ask every time" for control [on] vs "authenticate automatically"
- idle timeout [15 min]
- phone shows a persistent "Controlled by <Mac>" notification with a kill switch
- session log on the phone (Mac, time, duration)
- in privileged mode, optionally end the session when the phone is unlocked locally (Apple's behaviour) — *Tombolo decision after review: **mandatory**, enforced by a phone-side lease; see [architecture §8](../architecture.md#8-security-model)*
- unpairing on either side revokes both keys

### 5.4 Threat model

| # | Attacker / threat | Asset at risk | Mitigation | Residual risk |
|---|---|---|---|---|
| T1 | Passive LAN eavesdropper (café/hotel/shared Wi-Fi) | Screen, keystrokes (passwords), clipboard, SMS, notifications, files | All channels inside QUIC-TLS 1.3, **including USB** | Traffic analysis: packet size/timing can leak typing cadence. Optional input batching/padding |
| T2 | Active MITM **during pairing** | Long-term trust | The QR carries the Mac's key hash + endpoint ID + a 256-bit one-time secret; the PIN fallback is a PAKE bound to the TLS exporter; never TOFU on Wi-Fi; no short SAS-only comparison (KDE lesson) | The user scans a QR shown by malware on the Mac (T8) |
| T3 | Active LAN attacker **after pairing** (posing as the Mac to gain control, or as the phone to harvest Mac input) | Full phone control | Mutual auth with **pinned** keys on every connection, plus P-256 session signatures; identity bound to the key, never to an advertised ID (CVE-2025-66270 lesson) | Theft of a paired device's private keys |
| T4 | Spoofed or flooded discovery (fake mDNS, name squatting) | User confusion, DoS | Discovery is a hint; rotating tokens; names come from pairing records; rate-limited pairing UI | Discovery DoS → fall back to cached address / QR / manual |
| T5 | **Malicious app on the phone** connecting to our listener (LAN port, or the adb-forwarded localabstract socket) | Phone control (our server injects input!) | Same crypto auth on loopback/abstract sockets; on the USB tunnel, check `LocalSocket.getPeerCredentials()` (adbd connects as `shell`, uid 2000); no unauthenticated local API (ws-scrcpy is the counter-example); no exported components without a signature permission | Rooted/compromised phone is out of scope |
| T6 | Malicious app abusing our privileges via IPC (Accessibility, notification listener, SMS) | Privilege escalation | Non-exported services; least privilege; each feature opt-in | OS vulnerabilities |
| T7 | **Stolen or borrowed unlocked Mac** | Phone control, messages | SE-enforced Touch ID/password for control sessions ("ask every time"); idle timeout; persistent phone notification + kill switch; unpair from the phone | Attacker who knows the Mac password |
| T8 | Same-user malware on the Mac | Mirrored screen, injected input, keychain items | Keys non-exportable (SE) or bound to our code-signing identity via Keychain ACLs; hardened runtime. Malware granted Screen Recording/Accessibility TCC permissions can still watch/drive our window | High if the user grants TCC to malware; acknowledged out of scope |
| T9 | Stolen phone | Mac-side data (clipboard, files, notifications pushed to the Mac) | Keys in Keystore; the Mac can revoke; the Mac auto-accepts files only from an unlocked phone (the phone reports lock state) | Low |
| T10 | Replay (incl. QUIC/TLS **0-RTT**) | Repeated tap/type commands | TLS record protection inside a session; **0-RTT disabled for control** (0-RTT data is replayable, RFC 8446 §8); per-session nonces | — |
| T11 | Online brute force of the 6-digit code | Pairing | PAKE → no offline guessing; ≤ 3 tries per code; TTL 2–5 min | ≈ 3 / 10^6 per code |
| T12 | QR/secret leakage (photo, shoulder-surfing, screen share) | Pairing | One-time, short TTL, consumed on first use; explicit confirmation on both screens | Narrow window |
| T13 | Downgrade (old protocol, weak cipher, "no encryption" debug mode) | Everything | TLS 1.3 only; protocol major in ALPN (`tombolo/1`); no plaintext mode even on USB | — |
| T14 | Relay/rendezvous operator, or a remote attacker (v2) | Metadata, availability, control | E2E with pinned keys (the relay can't decrypt or impersonate); remote access **off by default**, with a separate toggle on the phone; relay allow-list by endpoint ID | IP/timing/volume metadata visible to the relay operator |
| T15 | Sensitive content (banking apps, `FLAG_SECURE`) | Privacy | Respect secure flags (MediaProjection renders them black; scrcpy's `SurfaceControl` path also can't capture secure displays since Android 12); never write frames to disk; clipboard sync opt-in | Privileged-mode behaviour with secure windows: **verify** |
| T16 | Compromised update / supply chain | Everything | Signed releases, reproducible builds where possible, pinned Rust/Gradle deps | Out of scope for this doc |

---

## 6. Serialization for control messages

| Option | Kotlin / Android | Swift / macOS | Schema evolution | Notes |
|---|---|---|---|---|
| **Protobuf** | Square **Wire** 7.1.0 (2026-09-28; KMP) or `protobuf-kotlin-lite` | Apple **swift-protobuf 1.39.0** (2026-10-12; Edition 2026). Wire's Swift output is "beta" | Excellent (field numbers, unknown-field preservation, `oneof`, `reserved`) | Small runtimes; one `.proto` is the contract; `protoc --decode` for debugging. RustDesk uses it too |
| FlatBuffers | Official Kotlin/Java (no KMP activity seen in 2025–26) | Official Swift (v25.12.19) | Good (append-only tables) | Zero-copy: pointless for 30-byte input events; clunkier builders |
| CBOR | `kotlinx-serialization-cbor` | Third-party (SwiftCBOR, PotentCodables; status **unverified**) | Convention only | No shared codegen → drift between two languages |
| Hand-rolled binary (scrcpy) | Trivial | Trivial | Poor (scrcpy requires an exact version match) | Right for the fixed media header; wrong for 40+ evolving message types |

**Decision:**
- **Protobuf** (Wire on Android, swift-protobuf on macOS, `.proto` files shared in one repo directory) for every control, device, clipboard, notification, SMS, file and session message. Varint length-delimited on reliable streams; one `Envelope { uint32 req_id; oneof body {…} }`.
- **Hand-rolled fixed header** for media (Section 9.6).

**Versioning and capabilities:**
- ALPN `tombolo/<major>` fails fast on an incompatible major version.
- The first message is `Hello{protocol_major, protocol_minor, app_version, device_model, capabilities: repeated string, limits{max_streams, codecs, max_resolution, max_fps}, session_nonce, server_mode: APP|PRIVILEGED}`. Both sides take the intersection of capabilities.
- Feature flags are strings (`"video.hevc"`, `"input.uhid"`, `"display.virtual"`, `"files.resume"`), so features can be added without a schema bump.
- Never reuse field numbers; `reserved` for removed fields; every enum has `UNSPECIFIED = 0` with safe handling.
- Unlike scrcpy, minor versions must interoperate.

---

## 7. File transfer

**Own protocol, inside the paired session:**
1. **Offer:** `FileOffer{transfer_id, items[{item_id, name, size, mime, mtime, optional sha256}]}` on the control stream → `FileAccept` / `FileReject`. Auto-accept from a paired device is a per-device setting.
2. **Streams:** each item gets its **own bidirectional QUIC stream** at **lowest priority** (or its own TLS/TCP connection in fallback mode).
   - At most 2–4 items in flight. Parallelism helps with many small files; one large file is not split across parallel streams on a LAN.
3. **Chunking and resume:**
   - Fixed 1 MiB chunks.
   - The receiver keeps a sidecar `{item_id, chunk_size, bitmap, per-chunk SHA-256}`.
   - **Resume** = `FileResume{item_id, offset}` at the first missing chunk. The sender seeks (Android `ParcelFileDescriptor`/`FileChannel.position`; macOS `FileHandle.seek`).
4. **Integrity:** per-chunk SHA-256, plus whole-file SHA-256 in `FileComplete`.
   - SHA-256 is hardware-accelerated on both sides (ARMv8 SHA-2 via Conscrypt/BoringSSL; CryptoKit on the Mac), so it is not the bottleneck at Wi-Fi speeds. This is expected, not benchmarked.
   - BLAKE3 (tree hash, verified streaming; iroh-blobs uses it) is nicer, but the only Kotlin+Swift implementation found is the small third-party `trancee/blake-hash`, plus a 6-year-old JNI binding. Defer.
5. **Coexistence with mirroring:** while a mirroring session is active, cap file throughput to leave ≥ 30–50 % of the estimated link rate for media. Media streams always have strict priority.
6. **Android storage:** receive into `MediaStore.Downloads` (API 29+) or a user-picked SAF tree; send from the share sheet / SAF `content://` URIs.

**LocalSend v2 interop:**
- Feasible and documented: multicast announce, `prepare-upload` → `upload` → `cancel`, and since 2.2 a 422 response on `sha256` mismatch.
- Scope it as an **optional, separately-toggled "LocalSend-compatible receive/send"** that never touches the control trust domain. Its security is TOFU from unauthenticated multicast.
- The protocol repo has no detected license, so clarify that with the maintainers before claiming compatibility (**unverified**).

**Quick Share interop:**
- NearDrop (Unlicense) documents the LAN path: mDNS `_FC9F5ED42C8A._tcp`, BLE trigger, length-prefixed protobuf `offline_wire_formats`, UKEY2, AES-256-CBC + HMAC.
- Google's own Nearby/Quick Share code is Apache-2.0 at google/nearby ("not an officially supported Google product"), which lowers the reverse-engineering risk.
- No DMCA or legal statements were found in NearDrop's issues, and no Google statement was found — **unverified**, not legal advice.
- Technically realistic for file drop only. A v2+ nice-to-have, not core.

---

## 8. Remote (non-LAN) — later, still free and self-hostable

| Option | What it gives | Self-hostable | License | Fit |
|---|---|---|---|---|
| **iroh 1.x** | QUIC (noq) multipath + QUIC NAT traversal (draft-seemann-quic-nat-traversal) + encrypted relay fallback; dial by Ed25519 key; streams + datagrams; official Swift/Kotlin bindings; wire-stable within a major | **Yes**: the `iroh-relay` binary (access control: `everyone`, allow/deny-list by endpoint ID, shared bearer token) and `iroh-dns-server` (pkarr). n0's public relays are free but rate-limited | MIT OR Apache-2.0 | **Best fit**, because it is the same stack as v1. Hole-punch "~90 %" and "95 % of data direct" are **vendor claims**. Relayed traffic is tunnelled over HTTP(S)/TCP, so expect higher latency and HOL when relayed |
| WebRTC ICE + STUN/TURN | Proven internet media | **coturn** (BSD-3; RFC 8656, TCP/TLS/DTLS) + our own signalling | BSD-3 | Only if we add a browser client |
| Overlay VPN: **Headscale** + Tailscale clients, or plain WireGuard | Stable private IPs; our LAN protocol works unchanged | Headscale (BSD-3) self-hosted control server; the official Tailscale apps accept a custom control server | Tailscale is open source **except the macOS/iOS/Windows GUI clients** (Headscale README) | **Free "remote" on day 1**: support manual addresses and document it |
| RustDesk hbbs/hbbr | Rendezvous + TCP relay + hole punching | Yes | **AGPL-3.0** | Architectural reference only |
| libp2p (DCUtR + Circuit Relay v2) | Decentralised hole punching | Yes | MIT/Apache | Measured **70 % ± 7.1 %** conditional success, with ~29 % of attempts failing at earlier stages (IPFS campaign, arXiv 2604.12484). Kotlin/Swift implementations are immature. Heavier than iroh for no gain |

**What keeps it free and self-hostable:**
- **No accounts.** The paired public key *is* the address.
- **Relays never see plaintext** and can't impersonate either side.
- **The relay is one static binary**, runnable on a cheap VPS or a home server.
- **Configurable relay list in the apps.** The default is none; a community relay, if offered, is labelled as such and runs with an endpoint allow-list.
- **Discovery can skip DNS entirely:** pairing records store "my relay URL", so peers dial `{endpoint_id, relay_url}` and need no `iroh-dns-server`.
- **Remote control is off by default** and authorised separately on the phone.
- Note: iroh's public relays for 0.9x and 1.0-rc versions sunset 2026-09-30 (per the 1.0 post). Pin to 1.x.

---

## 9. Recommended Tombolo protocol stack

| Layer | v1 (USB + LAN) | v2 (remote) | Why |
|---|---|---|---|
| **9.1 Discovery** | DNS-SD `_tombolo._udp` advertised by the phone (NsdManager; `registerServiceInfoCallback` on 14+, serialized resolves on ≤ 13), browsed by the Mac (`NWBrowser`); rotating TXT token; cached addresses; QR / manual IP; adb `host:track-devices` for USB | + relay URL in pairing records; optional `iroh-dns-server`; BLE presence token (v1.x) | mDNS is what both OSes support natively; the fallbacks cover client isolation; rotating tokens avoid tracking |
| **9.2 Pairing** | QR on the Mac (endpoint ID + addresses + P-256 key hash + 256-bit one-time secret) → exporter-bound HMAC + mutual P-256 signatures; fallback 6-digit SPAKE2 bound to the exporter | Same records; remote access is a separate opt-in scope | The adb Wireless Debugging design, which is proven; no TOFU; avoids KDE's 32-bit SAS and its CVE |
| **9.3 Session transport** | **QUIC (RFC 9000/9001 + RFC 9221 datagrams)** in a shared Rust core (iroh 1.x / noq) via UniFFI. Wi-Fi: UDP. USB: QUIC packets length-prefixed over an adb-forwarded TCP socket. Later AOA bulk endpoints. 0-RTT off for control. **Fallback:** TLS 1.3 over TCP, one connection per channel | iroh NAT traversal + multipath + self-hosted `iroh-relay` | One implementation on both ends; per-stream isolation; datagrams; priorities; same code LAN → remote; Android server role supported |
| **9.4 Channels** | see the channel map below | same, with tighter bitrate caps | Isolates audio and input from video and file traffic |
| **9.5 Message encoding** | Protobuf (Wire / swift-protobuf), varint-delimited `Envelope`; `Hello` + capability strings; ALPN `tombolo/1` | same | Evolvable for years across two languages |
| **9.6 Media framing** | Own 24-byte header + Annex-B H.264/H.265 (AV1 optional); session/format packets; Opus packets in datagrams | + optional Reed–Solomon FEC for datagram video | Zero-copy into `CMSampleBuffer`; scrcpy-proven shape |

**Channel map:**

| Channel | QUIC primitive | Direction | Priority | Contents |
|---|---|---|---|---|
| control | 1 bidi stream (opened first) | both | highest | Hello/capabilities, session auth signatures, window open/close/resize, **input events** (touch/mouse/keys/scroll, frame-size-stamped as in scrcpy), IDR/refresh requests, receiver feedback (50–100 ms), clipboard, notifications, SMS, app list |
| video.N | 1 uni stream per window or virtual display | phone → Mac | focused > visible > background | media header + Annex-B frames; session packet on (re)config |
| audio | DATAGRAM frames | phone → Mac (mic Mac → phone later) | high | Opus 10–20 ms packets, one per datagram (fits the MTU; loss → Opus PLC) |
| clock/keepalive | DATAGRAM ping/pong | both | high | RTT + clock-offset estimation every 50–100 ms during sessions (also keeps the radio awake) |
| files | 1 bidi stream per item | both | lowest, rate-capped | offer/accept on control; chunks + hashes here |
| bulk | uni streams | both | low | app icons, thumbnails, logs |

If a USB link and Wi-Fi are both available, prefer USB. With multipath (noq), USB can be one path and Wi-Fi another — **needs prototyping**.

**Media packet header (big-endian, 24 bytes)** — a sketch, final layout TBD:
```
u8  type        // 1=video frame, 2=codec config, 3=session/format, 4=audio, 5=end-of-stream
u8  flags       // bit0 keyframe, bit1 refresh-point (intra-refresh cycle complete), bit2 discontinuity (frames dropped before this)
u16 channel_id  // window / virtual display
u32 seq         // per-channel frame counter (gaps => request refresh)
u64 capture_us  // phone monotonic capture time (µs); Mac maps it via clock-offset pings => latency telemetry
u32 encode_us   // encoder time for this frame (telemetry)
u32 length      // payload bytes
```
Session/format packet payload (protobuf, since it is rare): codec, width, height, rotation, color space/range, display ID, the virtual display's dpi. Codec IDs follow scrcpy's ASCII FourCC style for familiarity.

**Video delivery strategy:**
- **v1 (LAN):** one long-lived uni stream per window: reliable, in order, no HOL across windows. Sender-side queue management + bitrate/fps adaptation + on-demand refresh.
- **v1.x experiment:** a stream per frame (MoQ-style), so stale frames can be `reset()` under congestion, followed by a refresh request.
- **v2 internet:** datagrams with RS-FEC (Moonlight's 20 % default as a starting point) if stream-per-frame proves insufficient on lossy paths. The header is self-delimiting, so payloads don't change across these modes.

**Server modes** (same wire protocol, announced in `Hello.server_mode`):
- **APP:** MediaProjection + AccessibilityService + playback capture. Single display; consent every session; stops on screen lock (Android 15 QPR1+).
- **PRIVILEGED:** a shell-uid helper started over USB adb, Wireless debugging or Shizuku-style self-adb. Virtual display per app, `injectInputEvent`/UHID, submix audio. Both modes are reached through the same discovery and authentication.

**What this stack buys and costs:**
- **Buys:** one transport codepath across USB/LAN/remote; strong, hardware-backed auth that mirrors Apple's model; no scrcpy version lock-in; nothing proprietary.
- **Costs:** ~13 MB native per Android ABI, plus Rust in both builds; our own rate control and refresh logic (no WebRTC GCC for free); a two-key identity design; a USB tunnel to build and prove.

---

## 10. Open questions / needs prototyping

| # | Question | Why it matters | How to answer |
|---|---|---|---|
| P1 | **QUIC over an adb TCP tunnel**: can iroh/noq run on a custom socket/transport carrying length-prefixed packets over adb-forwarded TCP, and how do its throughput and latency compare with plain TCP over adb? | Decides the "one stack everywhere" claim | Spike: noq `AsyncUdpSocket`-style adapter or an iroh custom transport; measure 1080p60 + 4×720p15 |
| P2 | Does iroh (Rust and FFI) expose the **TLS exporter** (`export_keying_material`) needed for the session signatures and PAKE binding? | Pairing/auth design | Read the iroh/noq API; quinn has it. Otherwise our own UniFFI crate |
| P3 | Binary size and startup cost of the Rust core: ≈ 12.8 MB arm64 `.so` measured for iroh; Mac universal size; cold-start to first frame | APK size budget | Build with LTO/strip and measure |
| P4 | **Concurrent encoders**: how many simultaneous MediaCodec sessions (1×1080p60 + N×720p15) on Pixel / Samsung / Xiaomi mid-range, and thermal behaviour | The per-app-window feature | Device-lab test of `getMaxSupportedInstances` vs reality |
| P5 | **Intra-refresh** support across vendor encoders, and VideoToolbox behaviour with intra-refresh-only streams (no IDR after the first; recovery points) | Bitrate smoothness, recovery | Test matrix; fall back to periodic or on-demand IDR |
| P6 | Wi-Fi **power save on the phone** with the screen off (privileged mode): input latency after idle; whether heartbeats keep the radio awake given the lock's foreground/screen-on restriction | Click-to-photon | Measure RTT distributions with the screen on/off and with heartbeats at 20/50/100 ms |
| P7 | **AWDL spikes on the Mac**: frequency and magnitude during sessions, and whether anything app-level helps | Wi-Fi experience | ping/RTT histograms with AWDL up/down; consider a diagnostic UI |
| P8 | Rate-control algorithm: GCC-style delay gradient vs simple backlog-based; noq CC choice (Cubic vs BBR) | Latency under load | Trace-driven tests with emulated Wi-Fi impairments |
| P9 | Hardware key signing latency (Secure Enclave with Touch ID; StrongBox is reportedly slow → use TEE?) for per-session signatures | Session start time | Microbenchmarks |
| P10 | Android 17 **`ACCESS_LOCAL_NETWORK`**: does it gate loopback / adb-forwarded sockets? How does the picker flow (`FLAG_SHOW_PICKER`) fit pairing UX? | Day-one permission design for target API 37 | Test on Android 17 |
| P11 | **AOA** from a sandboxed macOS app (IOUSBHost/libusb): mode switch, Android prompt, interaction with charging/MTP; AOA 2.0 HID for input without adb | Developer-options-free USB + input | Spike |
| P12 | Privileged-mode helper: write our own vs pin scrcpy-server; how shell obtains `ADD_TRUSTED_DISPLAY` (**unverified**); secure-window behaviour | Per-app windows | Code reading + device tests |
| P13 | Phone background reachability: foreground-service type (`connectedDevice`?), Doze, CompanionDeviceManager presence to wake the listener for notifications/SMS | "Always connected" features | Device tests across OEMs (battery killers) |
| P14 | Glass-to-glass measurement harness (high-speed camera/photodiode, or an on-screen timestamp with clock sync) to replace every estimate in Section 3 | Evidence | Build early; publish numbers |
| P15 | LocalSend protocol licensing / compatibility claims; Quick Share legal posture | Optional interop | Ask maintainers; legal review |
| P16 | iroh relay over TCP/HTTPS when relayed: latency penalty for remote control | v2 UX | Measure through a self-hosted relay |

---

## Sources

Primary sources unless noted. Items in the text marked **unverified** are not covered by these.

**scrcpy and browser tools**
- scrcpy v5.0.1 release — https://github.com/Genymobile/scrcpy/releases/tag/v5.0.1
- scrcpy `doc/develop.md` (protocol, "must be considered internal") — https://github.com/Genymobile/scrcpy/blob/v5.0.1/doc/develop.md
- scrcpy `app/src/server.c`, `app/src/demuxer.c`, `app/src/control_msg.c` — https://github.com/Genymobile/scrcpy/tree/v5.0.1/app/src
- scrcpy server sources (`Options.java`, `DesktopConnection.java`, `Streamer.java`, `ControlMessage*.java`, `DeviceMessageWriter.java`, `PositionMapper.java`, `SurfaceEncoder.java`) — https://github.com/Genymobile/scrcpy/tree/v5.0.1/server/src/main/java/com/genymobile/scrcpy
- scrcpy virtual display / audio / camera docs — https://github.com/Genymobile/scrcpy/blob/v5.0.1/doc/virtual-display.md · https://github.com/Genymobile/scrcpy/blob/v5.0.1/doc/audio.md · https://github.com/Genymobile/scrcpy/blob/v5.0.1/doc/camera.md
- scrcpy latency PR #646 — https://github.com/Genymobile/scrcpy/pull/646 ; Wi-Fi stutter discussion #4386 — https://github.com/Genymobile/scrcpy/issues/4386
- adb protocol doc — https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/dev/protocol.md ; adb man page (forward/reverse specs) — https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/user/adb.1.md
- Tango / ya-webadb — https://github.com/yume-chan/ya-webadb · https://tangoadb.dev/scrcpy/ · https://tangoadb.dev/scrcpy/versions/
- ws-scrcpy — https://github.com/NetrisTV/ws-scrcpy · https://github.com/NetrisTV/ws-scrcpy/blob/master/docs/scheme.md
- Vysor — https://github.com/koush/vysor.io
- Shizuku — https://github.com/RikkaApps/Shizuku
- AOSP core / Shell manifests (archived mirror) — https://github.com/aosp-mirror/platform_frameworks_base/blob/main/core/res/AndroidManifest.xml · https://github.com/aosp-mirror/platform_frameworks_base/blob/main/packages/Shell/AndroidManifest.xml

**Android platform**
- MediaFormat reference (`KEY_LOW_LATENCY`, `KEY_INTRA_REFRESH_PERIOD`, `KEY_MAX_B_FRAMES`, `KEY_LATENCY`, `KEY_PRIORITY`, `KEY_PREPEND_HEADER_TO_SYNC_FRAMES`) — https://developer.android.com/reference/android/media/MediaFormat
- MediaCodecInfo.CodecCapabilities (`getMaxSupportedInstances`, `FEATURE_IntraRefresh`, `FEATURE_LowLatency`) — https://developer.android.com/reference/android/media/MediaCodecInfo.CodecCapabilities
- WifiManager (`WIFI_MODE_FULL_LOW_LATENCY`, `MulticastLock`) — https://developer.android.com/reference/android/net/wifi/WifiManager
- Media projection (per-session consent, Android 15 QPR1 chip + auto-stop on lock, app screen sharing) — https://developer.android.com/media/grow/media-projection ; Android 14 behaviour changes — https://developer.android.com/about/versions/14/behavior-changes-14
- Companion App Streaming (priv-app only) — https://source.android.com/docs/core/permissions/app-streaming
- Android Open Accessory 1.0 / 2.0 — https://source.android.com/docs/core/interaction/accessories/aoa · https://source.android.com/docs/core/interaction/accessories/aoa2
- NsdManager — https://developer.android.com/reference/android/net/nsd/NsdManager ; NsdService (mainline mDNS switch) — https://android.googlesource.com/platform/packages/modules/Connectivity/+/refs/heads/main/service-t/src/com/android/server/NsdService.java
- Local network permission (Android 16/17) — https://developer.android.com/privacy-and-security/local-network-permission
- SSLSockets.exportKeyingMaterial (API 31) — https://developer.android.com/reference/android/net/ssl/SSLSockets ; Conscrypt — https://javadoc.io/static/org.conscrypt/conscrypt-android/1.4.0/org/conscrypt/Conscrypt.html
- Android Keystore — https://developer.android.com/privacy-and-security/keystore ; KeyMint HAL (curve 25519 / StrongBox) — https://android.googlesource.com/platform/hardware/interfaces/+/refs/heads/main/security/keymint/aidl/android/hardware/security/keymint/IKeyMintDevice.aidl
- Bluetooth permissions — https://developer.android.com/develop/connectivity/bluetooth/bt-permissions ; FGS types — https://developer.android.com/develop/background-work/services/fgs/service-types
- USB tethering / NCM on macOS (community; **secondary**) — https://github.com/connermo/usb-android-tethering

**Apple platform**
- Network.framework QUIC (WWDC21-10094) — https://developer.apple.com/videos/play/wwdc2021/10094/ ; NetworkConnection datagrams — https://developer.apple.com/documentation/network/networkconnection/datagrams ; WWDC25-250 — https://developer.apple.com/videos/play/wwdc2025/250/
- Apple Developer Forums QUIC threads: 813467 (datagram modelling), 850361 (FB25125957), 750808 (stream 0), 831975 (swift-network-evolution SPI) — https://developer.apple.com/forums/thread/813467 · https://developer.apple.com/forums/thread/850361 · https://developer.apple.com/forums/thread/750808 · https://developer.apple.com/forums/thread/831975
- swift-nio-quic — https://github.com/apple/swift-nio-quic
- TLS exporter in Network.framework (forum) — https://developer.apple.com/forums/thread/128938 · https://developer.apple.com/forums/thread/705654
- TN3179 Local network privacy — https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- Secure Enclave keys — https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave
- CBPeripheralManager.startAdvertising — https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager/startadvertising(_:)
- iPhone Mirroring support — https://support.apple.com/en-us/120421 ; Platform Security: iPhone Mirroring — https://support.apple.com/guide/security/iphone-mirroring-security-sec6ab47ebfc/web
- VideoToolbox low-latency encoding (WWDC21-10158) — https://developer.apple.com/videos/play/wwdc2021/10158/ ; kVTDecompressionPropertyKey_RealTime — https://developer.apple.com/documentation/videotoolbox/kvtdecompressionpropertykey_realtime
- TCP_NOTSENT_LOWAT: WWDC15-719 — https://developer.apple.com/videos/play/wwdc2015/719/?time=2199 ; Cheshire IETF 122 SBM slides — https://datatracker.ietf.org/meeting/122/materials/slides-122-quic-ietf-122-stuart-cheshire-source-buffer-management-00 (PDF text not machine-readable for us; the "2 s of unsent frames" detail comes via search summary + apenwarr — https://apenwarr.ca/log/20150414)
- AWDL jitter (community, **secondary**) — https://gyorgy.sh/blog/macos-awdl-network-jitter · https://github.com/burakgon/stop-stutter

**QUIC / WebRTC / SRT**
- RFC 9000, 9001, 9221 — https://www.rfc-editor.org/rfc/rfc9000 · https://www.rfc-editor.org/rfc/rfc9001 · https://www.rfc-editor.org/info/rfc9221/
- RFC 8446 (TLS 1.3; §8 0-RTT replay; §7.5 exporters) — https://datatracker.ietf.org/doc/html/rfc8446
- RTP over QUIC draft (expired at -14; in WG Last Call) — https://datatracker.ietf.org/doc/draft-ietf-avtcore-rtp-over-quic/
- MoQ transport draft-22 — https://datatracker.ietf.org/doc/draft-ietf-moq-transport/
- iroh repo / 1.0 post / noq post / road to 1.0 — https://github.com/n0-computer/iroh · https://www.iroh.computer/blog/v1 · https://www.iroh.computer/blog/noq-announcement · https://www.iroh.computer/blog/the-road-to-iroh-1-0 · https://www.iroh.computer/blog/iroh-1-0-1
- iroh-ffi (Swift/Kotlin bindings; `src/endpoint.rs`, `src/android_init.rs`) — https://github.com/n0-computer/iroh-ffi ; iroh-relay README — https://github.com/n0-computer/iroh/tree/main/iroh-relay ; crates.io — https://crates.io/crates/iroh
- noq — https://github.com/n0-computer/noq ; quinn — https://github.com/quinn-rs/quinn ; quiche — https://github.com/cloudflare/quiche ; kwik — https://github.com/ptrd/kwik ; MsQuic — https://microsoft.github.io/msquic/msquicdocs/docs/Release.html ; ngtcp2 — https://github.com/ngtcp2/ngtcp2 ; s2n-quic — https://github.com/aws/s2n-quic ; lsquic — https://github.com/litespeedtech/lsquic ; mvfst — https://github.com/facebook/mvfst ; kuicksilver — https://github.com/kuicksilver/kuicksilver
- Syncthing firewall ports — https://docs.syncthing.net/users/firewall.html
- WebRTC: webrtc-sdk/android — https://github.com/webrtc-sdk/android ; livekit/webrtc-xcframework — https://github.com/livekit/webrtc-xcframework ; stasel/WebRTC — https://github.com/stasel/WebRTC ; PATENTS — https://webrtc.googlesource.com/src/+/main/PATENTS ; playout-delay extension — https://webrtc.googlesource.com/src/+/main/docs/native-code/rtp-hdrext/playout-delay/README.md ; webrtc-rs — https://github.com/webrtc-rs/webrtc ; Pion gomobile issue — https://github.com/pion/webrtc/issues/1111 ; libdatachannel — https://github.com/paullouisageneau/libdatachannel
- SRT — https://github.com/Haivision/srt · https://github.com/Haivision/srt/discussions/2532

**Reference systems**
- Moonlight / Sunshine: moonlight-common-c — https://github.com/moonlight-stream/moonlight-common-c ; Moonlight-qt macOS renderers — https://github.com/moonlight-stream/moonlight-qt/tree/master/app/streaming/video/ffmpeg-renderers ; Sunshine configuration — https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html ; overlay numbers (**secondary**) — https://note.com/cute_agapan9087/n/n5e400bb52235?hl=en · https://tech-insider.org/parsec-vs-moonlight-vs-steam-link-2026/
- Parsec BUD — https://parsec.app/blog/a-networking-protocol-built-for-the-lowest-latency-interactive-game-streaming-1fd5a03a6007
- RustDesk — https://github.com/rustdesk/rustdesk · https://github.com/rustdesk/rustdesk-server
- Open Screen / Cast Streaming — https://chromium.googlesource.com/openscreen/+/HEAD/cast/streaming/README.md
- Miracast — https://tools.barco.com/kb-downloads/4814/Wi-Fi_CERTIFIED_Miracast_Technical_Overview_20170725.pdf · https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/wireless-projection-receiver-manufacturers · https://documentation.mersive.com/content/pdf/miracastperformancetechnote.pdf
- UxPlay (AirPlay) — https://github.com/FDH2/UxPlay
- Phone Link — https://support.microsoft.com/en-us/phone-link ; reviews (**secondary**) — https://www.howtogeek.com/how-to-mirror-your-android-screen-to-your-pc-using-windows-phone-link/ · https://www.androidpolice.com/iphone-ios-18-mirroring-vs-android-microsoft-link/
- iPhone Mirroring hands-on (**secondary**) — https://www.androidauthority.com/iphone-mirroring-macos-hands-on-3454379/

**Discovery / pairing / crypto**
- KDE Connect protocol — https://github.com/KDE/kdeconnect-meta/blob/work/protocol-schemas/protocol.md ; Valent docs — https://valent.andyholmes.ca/documentation/protocol.html ; kdeconnect-kde — https://github.com/KDE/kdeconnect-kde ; CVE-2025-66270 advisory — https://kde.org/info/security/advisory-20251128-1.txt
- LocalSend protocol — https://github.com/localsend/protocol · https://github.com/localsend/protocol/blob/main/CHANGELOG.md
- AOSP adb (pairing_auth, pairing_connection, adb_mdns) — https://android.googlesource.com/platform/packages/modules/adb/ ; QR format via third-party tools — https://github.com/kristjan/adbqr · https://github.com/LinDevHard/wadb
- Noise spec rev 34 — https://noiseprotocol.org/noise.html ; WireGuard — https://www.wireguard.com/protocol/ ; WhatsApp whitepaper (mirror) — https://www.bitsoffreedom.nl/wp-content/uploads/WhatsApp-Security-Whitepaper.pdf
- Noise libraries — https://github.com/rweather/noise-java · https://github.com/jchambers/java-noise · https://github.com/sander/noise-kotlin · https://github.com/swift-libp2p/swift-noise · https://github.com/mcginty/snow
- SPAKE2 RFC 9382 — https://www.rfc-editor.org/rfc/rfc9382.txt ; CPace draft-21 — https://datatracker.ietf.org/doc/draft-irtf-cfrg-cpace/ ; OPAQUE RFC 9807 — https://datatracker.ietf.org/doc/rfc9807/ ; RustCrypto PAKEs — https://github.com/RustCrypto/PAKEs ; opaque-ke — https://github.com/facebook/opaque-ke
- NearDrop protocol notes — https://github.com/grishka/NearDrop/blob/master/PROTOCOL.md ; google/nearby — https://github.com/google/nearby ; UKEY2 — https://github.com/google/ukey2

**Serialization / hashing**
- Wire changelog — https://square.github.io/wire/changelog/ ; swift-protobuf 1.39.0 — https://github.com/apple/swift-protobuf/releases/tag/1.39.0 ; FlatBuffers releases — https://github.com/google/flatbuffers/releases
- BLAKE3 Kotlin+Swift (third-party) — https://github.com/trancee/blake-hash ; BLAKE3 JNI — https://github.com/semantalytics/BLAKE3jni

**Remote / self-hosting**
- coturn — https://github.com/coturn/coturn ; Headscale — https://github.com/juanfont/headscale
- libp2p DCUtR measurement — https://arxiv.org/html/2604.12484 ; rust-libp2p discussion #5910 — https://github.com/libp2p/rust-libp2p/discussions/5910
