# Tombolo protocol — draft v0

> Status: **draft for review**. Nothing here is frozen; field numbers and layouts will change during Phase 0
> and Phase 2. The design rationale is in [`research/04-transport-and-security.md`](research/04-transport-and-security.md)
> and [ADR-0003](decisions/0003-transport.md) / [ADR-0005](decisions/0005-pairing-and-identity.md).

## 1. Roles and layering

- **Phone** = media sender and capability provider. **Mac** = controller and media receiver.
- Either side may dial: the phone dials the Mac during QR pairing; afterwards the Mac usually dials the phone
  it discovered via DNS-SD.

```
┌──────────────────────────────────────────────────────────────┐
│ Features: mirroring · app windows · notifications · SMS ·    │
│           calls · clipboard · files · device status          │
├──────────────────────────────────────────────────────────────┤
│ Messages: Protobuf Envelope (control) · media header (video) │
├──────────────────────────────────────────────────────────────┤
│ Channels: control stream · video streams · audio datagrams · │
│           clock datagrams · file streams · bulk streams      │
├──────────────────────────────────────────────────────────────┤
│ Session: QUIC + TLS 1.3, ALPN "tombolo/1", pinned keys,      │
│          exporter-bound identity signatures                  │
├──────────────────────────────────────────────────────────────┤
│ Path: UDP over Wi-Fi  |  length-prefixed QUIC over adb TCP   │
└──────────────────────────────────────────────────────────────┘
```

## 2. Session establishment

1. QUIC handshake. ALPN `tombolo/1` (the major protocol version lives in ALPN; a mismatch fails fast). Each side
   presents its transport key; unknown keys are rejected without a prompt.
2. The dialer opens the **control** stream and sends `Hello`; the listener answers with its own `Hello`.
3. Both sides send `SessionAuth`: a signature by the **device identity key** (P-256, hardware-backed) over
   `TLS-exporter("tombolo/session/v1", 32) ‖ dialer endpoint ID ‖ listener endpoint ID ‖ session nonce`.
4. If the Mac's policy is "ask every time", the Mac's Secure Enclave requires Touch ID before it can sign —
   i.e. before control is possible.
5. The Mac sends `SessionStart{scopes_requested}`; the phone replies with the scopes **the phone owner has
   granted** and starts only the channels those scopes allow.

**Scopes are phone-authoritative.** They are granted on the phone at pairing and editable there at any time.
The phone checks them on **every** command and every outgoing data subscription; the Mac's copy is only a UI
hint. Scopes are split by direction and risk: `screen.view`, `screen.control`, `notifications.read`,
`notifications.act` (reply/dismiss/actions), `sms.read`, `sms.send`, `calls.state`, `calls.control`,
`clipboard.read`, `clipboard.write`, `files.receive` (Mac → phone), `files.send` (phone → Mac).

0-RTT is disabled for the control stream (0-RTT data is replayable).

## 3. Control messages (sketch)

All control messages are wrapped in a length-delimited `Envelope { uint64 id; oneof body {...} }`. Requests
that need answers carry an `id`; replies echo it.

| Group | Messages |
|---|---|
| Session | `Hello{proto_minor, app_version, server_mode: STANDARD/ENHANCED, capabilities[], device_info}`, `SessionAuth`, `SessionStart`, `SessionEnd{reason}`, `Ping`/`Pong` (also on datagrams) |
| Displays & video | `OpenDisplay{kind: MIRROR/APP, package?, width, height, dpi, max_fps, codec_prefs[]}` → `DisplayOpened{display_id, video_channel, format}`, `ResizeDisplay`, `CloseDisplay`, `RequestRefresh{display_id}`, `ReceiverFeedback{display_id, received, dropped, decode_ms, queue_ms}`, `SetVideoParams{bitrate, fps}` |
| Input | `Touch{display_id, action, pointer_id, x, y, frame_w, frame_h, pressure, buttons}`, `Scroll{display_id, x, y, dx, dy, phase}`, `Key{display_id, action, keycode, meta, repeat}`, `Text{display_id, utf8, composing?}`, `NavAction{BACK/HOME/RECENTS/NOTIFICATIONS/QS/POWER/VOLUME_UP/…}`, `RotateDisplay` |
| Apps | `ListApps` → `AppList{entries[package, label, icon_ref, last_used]}`, `AppIcon` on a bulk stream |
| Clipboard | `ClipboardChanged{mime, text, sensitive}` (both directions; sensitive clips are not sent by default) |
| Notifications | `NotificationPosted{key, package, app_label, title, text, when, actions[], reply_action?, category, conversation?}`, `NotificationRemoved{key}`, `NotificationAction{key, action_id, reply_text?}`, `NotificationDismiss{key}`, `OpenNotification{key}` (→ opens the app, in its own window when supported) |
| Messages | `SmsThreads` / `SmsThreadHistory` / `SmsMessage` / `SendSms{op_id, subscription_id, address[], text}` / `Subscriptions` (SIM list) — SMS send, MMS read-only; RCS via notifications |
| Calls | `CallState{id, state, number, contact_name}`, `CallAction{id, ANSWER/DECLINE/END/SILENCE}`, `Dial{number}` |
| Files | `FileOffer{transfer_id, items[name, size, mime, blake3]}` → `FileAccept{transfer_id, dest}` / `FileReject`, then data on `file.N`; `FileProgress`, `FileComplete`, `FileCancel`; resume via `FileResume{transfer_id, item, offset}` |
| Device | `DeviceStatus{battery, charging, signal, network, dnd, lock_state}`, `RingDevice`, `SetDnd` |

**Capabilities** are plain strings so they can grow without schema churn, e.g. `display.mirror`,
`display.virtual`, `display.flex`, `input.multitouch`, `input.uhid`, `input.a11y`, `audio.playback`,
`clipboard.read.background`, `notifications`, `notifications.sensitive`, `sms`, `calls`, `files`,
`camera.stream`.

## 4. Media framing (video streams)

One unidirectional QUIC stream per display, phone → Mac. Each packet:

```
 0               1               2               3
 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7
+---------------+---------------+-------------------------------+
|     type      |     flags     |          channel_id           |
+---------------+---------------+-------------------------------+
|                          seq (u32)                            |
+---------------------------------------------------------------+
|                     capture_us (u64) ...                      |
|                                                               |
+---------------------------------------------------------------+
|                       encode_us (u32)                         |
+---------------------------------------------------------------+
|                        length (u32)                           |
+---------------------------------------------------------------+
|                    payload (Annex-B) ...                      |
```

- `type`: 1 = video frame, 2 = codec config (SPS/PPS/VPS), 3 = format change (protobuf: codec, size,
  rotation, colour space/range, dpi), 5 = end of stream.
- `flags`: bit 0 keyframe, bit 1 refresh point (intra-refresh cycle complete), bit 2 discontinuity (frames
  were dropped before this one).
- `capture_us` is the phone's monotonic capture time; the Mac maps it with clock-offset pings to **estimate**
  capture-to-display latency for Diagnostics. This is telemetry, not a glass-to-glass measurement — acceptance
  numbers come only from the optical harness.

**Sender rules:** no B-frames; bounded send queue (at most ~2 frames queued per display; drop stale frames
before they enter the transport, mark the next frame `discontinuity`, and send a refresh); bitrate/fps adapted
from `ReceiverFeedback` and RTT.

**Known limitation:** a long-lived reliable stream still stalls *that* display on packet loss until
retransmission. v1 accepts this on LAN; the v1.x experiment is one stream per frame (reset stale frames, then
refresh), and v2 may move video to datagrams with FEC for lossy paths.

## 5. Audio

Opus, 48 kHz stereo, 10–20 ms frames at 64–128 kbit/s, one frame per QUIC datagram (well under the minimum
1200-byte QUIC datagram budget) with a 4-byte sequence + 8-byte capture-timestamp prefix. Loss is concealed by
Opus PLC; the Mac keeps a small adaptive jitter buffer (target ≤ 40 ms) and corrects clock drift by
occasional sample insertion/removal. On transports without datagrams (TCP fallback), audio uses its own
length-prefixed channel with the same packet format and drop-oldest queueing.

## 6. Pairing messages

Only valid on a connection established with the pairing ALPN `tombolo-pair/1`:

> The complete pairing/session state machine (canonical transcript encoding, nonce ownership, atomic
> secret consumption across connections, concurrent attempts, key rotation, recovery) is specified separately
> in Phase 0 and **externally reviewed before implementation**. The outline below is non-normative.

1. **QR path** — QR payload:
   `tombolo://pair?v=1&id=<mac endpoint id>&a=<ip:port,…>&k=<sha256(mac P-256 SPKI)>&s=<256-bit secret>&exp=<unix>`
   - Phone → `PairRequest{phone_identity_pubkey, name, model, os, hmac(s, exporter ‖ transcript), sig}`
   - Mac verifies; the Mac user confirms the device with Touch ID → `PairAccept{mac_identity_pubkey, hmac, sig}`
   - Phone checks `sha256(mac SPKI) == k`; the **phone owner chooses scopes** on the phone; both sides persist
     the binding *(peer transport key ↔ peer identity key ↔ scopes)*. The secret is consumed atomically —
     a second use from any connection fails.
2. **Code path** — 6-digit code shown on the Mac, typed on the phone; PAKE (SPAKE2, RFC 9382) with
   `password = code ‖ exporter`; then the same `PairRequest`/`PairAccept` exchange inside the PAKE-derived
   channel. Max 3 attempts per code.
3. **USB** — the same flows run over the adb tunnel; the tunnel itself is never treated as authenticated.

## 7. Versioning rules

- **Major** version = ALPN (`tombolo/1`). Incompatible changes bump it; both apps support N and N−1 for one
  release cycle.
- **Minor** version and capabilities in `Hello`. Unknown protobuf fields are ignored; unknown messages get
  `Unsupported{id}`.
- The `tombolo-helper` ↔ app protocol is private and versioned with the APK (they ship together).

## 8. Robustness rules

These are requirements for both implementations, enforced in `tombolo-core` where possible.

| Area | Rule (initial values, tuned in Phase 2) |
|---|---|
| Message size | Control `Envelope` ≤ 64 KiB; larger payloads (icons, thumbnails, MMS parts) go on bulk streams. Media packet payload ≤ 4 MiB. Oversized → close the stream with an error |
| Stream quotas | ≤ 8 concurrent video streams, ≤ 4 concurrent file transfers, ≤ 16 bulk streams per session |
| Outstanding requests | ≤ 64 un-answered requests per side; each request has a deadline (default 10 s); late replies are dropped |
| Rate limits | Input events coalesced to the display's frame rate for moves; pairing attempts ≤ 3 per secret/code, global back-off |
| Pre-authentication budget | Before `SessionAuth` completes: ≤ 4 concurrent unauthenticated connections, ≤ 16 KiB buffered per connection, 5 s handshake deadline, only `Hello`/pairing messages accepted |
| Buffer limits | Per-session aggregate send buffering ≤ 8 MiB; per-display pre-transport queue ≤ 2 frames; audio queue ≤ 100 ms (drop oldest); bulk/file streams yield to media under pressure |
| Side effects | `SendSms`, `CallAction`, `Dial`, `NotificationAction`, `FileOffer` carry an `op_id` (UUID) bound to a hash of the payload. Before executing, the phone **durably records** `op_id → RESERVED`; then `EXECUTING`; then `DONE`/`FAILED`. A repeat `op_id` returns the recorded state and never re-executes; a different payload under the same `op_id` is rejected. After a crash, any op found in `RESERVED`/`EXECUTING` is reported as **`UNKNOWN`** and never retried automatically — the Mac shows "may or may not have been sent". Records are kept 7 days; an `op_id` older than the retention window is rejected, not executed. The Mac never retries side effects on its own |
| Reconnect | A reconnect is a new session: re-authenticate, re-request scopes, re-open displays; in-flight side effects resolved via idempotency keys |
| Files | The receiver chooses the destination; peer-supplied names are sanitised (no path separators, no `..`, no control characters, length-limited), written to an app-owned temp area, verified (BLAKE3), then moved atomically; symlinks never followed; per-transfer and per-day size quotas; partial files deleted on cancel/expiry |
| Clipboard | Size cap (1 MiB text by default); clips marked sensitive are not sent unless opted in |
| Unknown input | Unknown protobuf fields ignored; unknown messages → `Unsupported{id}`; malformed frames → stream reset, repeated → session end |
