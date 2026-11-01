# S5 — iroh / noq API surface

| | |
|---|---|
| **Spike** | S5 (run together with S4 in P0-14) |
| **Task** | P0-14 — see the [Phase 0 task plan](../plans/phase-0.md#acceptance-criteria-per-task) |
| **Pass criteria** | [Implementation plan §0.C](../implementation-plan.md#0c-spikes-each-produces-a-short-write-up-in-docsspikes): *TLS exporter, custom transports, default relays and DNS discovery disabled, works with outbound Internet blocked — all available or patchable in a thin crate.* P0-14: *endpoint with default relays and DNS discovery **disabled**, verified with outbound Internet blocked; TLS exporter and custom-transport hooks confirmed (or patched).* |
| **Spike code** | `spikes/s04-transport/` (`iroh-probe/`, `tcp-tunnel/`, `size-*/`, `scripts/s5-egress.sh`): binaries built from `7b73e1b40b3aa1ba5145704401271090f85dd3aa`, egress script and results at `60c0a0d834f339c124f53f6ad1077eb21df4adec` |
| **Author(s)** | Claude (agent) for the maintainer |
| **Date(s) run** | 2026-10-26 |
| **Status** | draft — Mac rows pass; phone rows blocked — needs phone |

## Question

Does iroh 1.x / noq give Tombolo everything the transport design ([ADR-0003](../decisions/0003-transport.md),
[architecture §5](../architecture.md#5-tombolo-core-rust)) assumes — no public infrastructure, a TLS exporter
for session binding, a hook to run QUIC over an adb TCP tunnel, priorities, datagrams, reset and stats — and
at what binary-size cost? Open questions P1–P3 in
[research 04 §10](../research/04-transport-and-security.md#10-open-questions--needs-prototyping).

## Setup

**Devices**

| Role | Model | OS version and build | OEM skin / version | Notes |
|---|---|---|---|---|
| Phone | — | — | — | not used (Mac-only half) |
| Mac | Apple M4 Pro, 12 cores, 48 GB | macOS 27.0.1 (`sw_vers` build 26A434) | — | other jobs were running (a VM at 2–3 cores); S5 measures behaviour, not speed |

**Builds and tools**

| Component | Version / commit | How obtained |
|---|---|---|
| Spike code | `7b73e1b40b3aa1ba5145704401271090f85dd3aa` (binaries), `60c0a0d834f339c124f53f6ad1077eb21df4adec` (egress script + results) | this repository |
| iroh | 1.4.1 (crates.io, published 2026-10-21), `MIT OR Apache-2.0` | `Cargo.lock`, pinned `=1.4.1` |
| noq / noq-proto / noq-udp | 1.4.0 (crates.io, 2026-10-20), `MIT OR Apache-2.0` | pulled by iroh |
| rustls / crypto | rustls 0.23.46 with *ring* (iroh feature `tls-ring`) | `Cargo.lock` |
| iroh-ffi (read only) | 1.2.0, commit `66a8d61` (2026-10-22), depends on `iroh = "1.0.0"` | `git clone --depth 1`, source read, not built |
| Rust | 1.98.0 | rustup |
| Egress detectors | `sandbox-exec`, unified `log`, `lsof`, `nettop` | macOS built-ins |

**Environment:** loopback only. The Mac had Internet access over `en0`, which the positive control uses. The
network changed during the day (Wi-Fi, later a phone hotspot `172.20.10.0/28`), and DNS was failing during
the final egress re-run (04:31–04:33); see the Q2 notes.

## Method

1. **API probe** (`iroh-probe api`): two endpoints in one process, Tombolo configuration (below), the client
   connects to `EndpointAddr { id, [Ip(127.0.0.1:port)] }` only. It checks the exporter on both sides, stream
   priority, a 100 KB bidi echo, a uni stream reset with code 42, datagrams at and above the maximum size,
   50 datagram round trips, `stats()`, `rtt()` and `paths()`.
2. **Egress check** (`scripts/s5-egress.sh`), with two independent detectors and a positive control:
   - The probe runs under `sandbox-exec` with [`deny-non-loopback.sb`](../../spikes/s04-transport/scripts/deny-non-loopback.sb)
     (allow everything except outbound network operations to non-loopback destinations; this also blocks DNS,
     which goes through the `mDNSResponder` socket or UDP 53). The kernel logs every denied attempt as
     `Sandbox: iroh-probe(<pid>) deny(1) network-outbound <dest>`. These lines are counted per PID from
     `log show`. The connection is held for 20 s with keep-alives, so background tasks (net report, address
     lookup, relay actor, portmapper) have time to act.
   - Unsandboxed, `lsof -i` and `nettop -m tcp|udp` snapshots are taken 10 s into the same 20 s hold. They list
     every socket, its interface (`lo0` / `en0`) and its byte counts.
   - **Positive control:** iroh's public preset `presets::N0` under the same two detectors. It must trip them,
     which shows the detectors work.
   - The probe uses iroh's **default features** (incl. `portmapper`, `metrics`), wildcard binds (`0.0.0.0`, `[::]`).
3. **QUIC over one TCP stream** (`iroh-probe tunnel`): the `tcp-tunnel` crate implements iroh's
   `CustomTransport` / `CustomEndpoint` / `CustomSender` over a real loopback TCP connection
   (`u16` length prefix per QUIC packet, bounded send queue that drops when full, `TCP_NODELAY`,
   `TCP_NOTSENT_LOWAT`). Both endpoints run with **IP transports removed** (`clear_ip_transports()`), so the
   tunnel is the only path. The probe checks the exporter, datagrams and RTT idle and under a 1 GiB bulk
   transfer on a low-priority stream, runs in the sandbox, and can run as two processes (`--role`).
4. **Size:** `size-min` (one endpoint pair with a bidi stream, a datagram and an exporter call, so nothing
   is dead-stripped) vs `size-baseline` (tokio current-thread runtime doing a UDP echo). Profile `size` = fat
   LTO, `opt-level = "s"`, `codegen-units = 1`, strip, `panic = "abort"`; also plain `release` + strip.
   Variants: iroh `default-features = false, features = ["tls-ring"]` (min) and iroh default features (full).

The Tombolo configuration (`iroh-probe/src/main.rs`, `tombolo_builder`):

```rust
Endpoint::builder(presets::Minimal)                     // only sets the rustls crypto provider (ring)
    .relay_mode(iroh::RelayMode::Disabled)              // no relays (also the default of Builder::empty)
    .clear_address_lookup()                             // no DNS / pkarr / mDNS address lookup
    .portmapper_config(PortmapperConfig::Disabled)      // no UPnP / NAT-PMP / PCP gateway probing
    .net_report_config(NetReportConfig::minimal())      // no HTTPS latency probes, no captive-portal check
// connect by direct address only:
endpoint.connect(EndpointAddr::from_parts(peer_id, [TransportAddr::Ip(addr)]), b"tombolo/1")
```

## Raw numbers

### Q1 — versions and licence

iroh **1.4.1** and noq **1.4.0**, both `MIT OR Apache-2.0` (crates.io API, checked 2026-10-26;
`iroh-1.4.1/Cargo.toml:35`, `noq-1.4.0/Cargo.toml:30`). Both are GPL-3.0-compatible.

### Q2 — no public infrastructure, outbound Internet blocked

| Run | Detector | Result | Raw file |
|---|---|---|---|
| Tombolo config, sandboxed, 20 s hold | denied outbound attempts (`log show`, reports + "N duplicate reports") | session completed (`exit_code=0`, `exporter_match=true`, `done=true`, final path `127.0.0.1`); **7** denied attempts, **all** `remote:*:1`; none to port 53, 443, 1900 or 3478 | [`egress-sandbox-tombolo.txt`](../../spikes/s04-transport/results/s5/egress-sandbox-tombolo.txt), [`.denials`](../../spikes/s04-transport/results/s5/egress-sandbox-tombolo.txt.denials) |
| `presets::N0` (control), sandboxed | same | **51 843** denied attempts: 50 209 × `:53` (DNS), 1621 × `:443` (relays, HTTPS probes), 12 × `:1`, 1 × `:1900` (UPnP SSDP) | [`egress-sandbox-n0.txt`](../../spikes/s04-transport/results/s5/egress-sandbox-n0.txt) |
| Tombolo config, unsandboxed | `lsof -i` / `nettop` at 10 s | 4 UDP sockets (`*:port`), **no TCP connections**, every `nettop` row `lo0 Loop` (e.g. `udp4 *:50403 … lo0, 136081 B in / 133532 B out`); final path `127.0.0.1:50403` | [`egress-observed-tombolo.txt`](../../spikes/s04-transport/results/s5/egress-observed-tombolo.txt) |
| `presets::N0` (control), unsandboxed | `lsof -i` / `nettop` at 10 s | 100 UDP sockets and 20 TCP connections, the TCP ones to the network's resolver `172.20.10.1:53` and UDP rows on `en0` (DNS was failing at that moment, so no relay was reached). In the first run of the same script (01:31, at `8b63874`): 5 TLS connections to n0 relays `49.13.207.244:443` and `5.223.65.62:443` over `en0`, and the connection **migrated** from `127.0.0.1` to the Mac's public IPv6 address | [`egress-observed-n0.txt`](../../spikes/s04-transport/results/s5/egress-observed-n0.txt); first run: `git show 8b63874:spikes/s04-transport/results/s5/egress-observed-n0.txt` |
| QUIC over the TCP tunnel, sandboxed, 1 GiB | same as row 1 | completed (`exit=0`, `tunnel_exporter_match=true`, 1 073 741 824 B delivered); 1 denied attempt, `remote:*:1` | [`tunnel-sandboxed.txt`](../../spikes/s04-transport/results/s5/tunnel-sandboxed.txt) |

The `remote:*:1` attempts in the Tombolo runs come from `netdev` (via `netwatch`). It finds the default
interface by calling `connect()` on a UDP socket to the non-routable `10.254.254.254:1` (IPv4) and
`[fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]:1` (IPv6). A UDP `connect()` is a routing-table lookup and sends no
packet (`netdev-0.46.3/src/net/ip.rs:15–45`). The sandbox still counts it as an outbound operation. Neither
address is public infrastructure, and the `nettop` run shows no `en0` traffic at all.

### Q3 — TLS exporter

`iroh::endpoint::Connection::export_keying_material(&self, output: &mut [u8], label: &[u8], context: &[u8])`
(`iroh-1.4.1/src/endpoint/connection.rs:1115`, RFC 5705 / RFC 8446 §7.5;
[docs.rs](https://docs.rs/iroh/1.4.1/iroh/endpoint/struct.Connection.html#method.export_keying_material)).
Probe output: `exporter_match=true` on every run (IP and tunnel), e.g. `exporter_client_prefix=8200c60ae98bad4e` ([`egress-observed-tombolo.txt`](../../spikes/s04-transport/results/s5/egress-observed-tombolo.txt)).
Both sides derived the same 32 bytes for label `EXPORTER-tombolo-session-v0`. **Not exposed by iroh-ffi
1.2.0**: `grep export_keying` over its `src/` finds nothing.

### Q4 — custom transport / custom socket (QUIC over an adb TCP tunnel)

| Hook | Where | Status |
|---|---|---|
| iroh `Builder::add_custom_transport(Arc<dyn CustomTransport>)` + traits `CustomTransport` → `CustomEndpoint` (`poll_recv`, `create_sender`, `watch_local_addrs`) → `CustomSender` (`poll_send`), addresses `TransportAddr::Custom(CustomAddr{id, data})` | `iroh-1.4.1/src/endpoint.rs:822`, `src/socket/transports/custom.rs`; example `examples/custom-transport.rs` | **works**, behind the cargo feature **`unstable-custom-transports`**: "not covered by semantic versioning guarantees and may change in any release without a major version bump" |
| iroh `Builder::path_selector(Arc<dyn PathSelector>)` (prefer a transport) | `iroh-1.4.1/src/endpoint.rs:849` | available, same feature gate; not needed when the tunnel is the only transport |
| noq `Endpoint::new_with_abstract_socket(…, Box<dyn AsyncUdpSocket>, …)` + `AsyncUdpSocket` / `UdpSender` traits | `noq-1.4.0/src/endpoint.rs:162`, `src/runtime/mod.rs:45,87` | available (stable API); the fallback if Tombolo drops iroh for plain noq. Not exercised here |

Proof (loopback, a real TCP connection; `--role listen|connect` runs the two ends as separate processes):

| Measure | One process, two tasks, sandboxed, 1 GiB ([`tunnel-sandboxed.txt`](../../spikes/s04-transport/results/s5/tunnel-sandboxed.txt)) | Two processes, 256 MiB ([`listen`](../../spikes/s04-transport/results/s5/tunnel-2proc-listen.txt), [`connect`](../../spikes/s04-transport/results/s5/tunnel-2proc-connect.txt)) |
|---|---|---|
| IP sockets bound by iroh | none (`ip_sockets_bound=[]`); only path `Custom(CustomAddr { id: 0x746f6d62, … }) selected=true` | same configuration |
| Handshake | `tunnel_connect_ms=2.68` | — |
| Exporter equal on both sides | `tunnel_exporter_match=true` | `tunnel_exporter_match=true` |
| Max datagram size | 1382 B (path-MTU discovery over the tunnel) | — |
| Idle RTT, control stream / datagram (µs, p50 / p95) | 121 / 166 · 71 / 103 | 149 / 271 · 89 / 173 |
| Bulk on a priority −10 stream | 1 GiB in 0.987 s = **8.7 Gbit/s** | **9.3 Gbit/s** |
| Control-stream RTT during bulk (µs, p50 / p95 / p99) | 362 / 888 / 1305 (481 samples) | 260 / 600 / 1047 (115 samples) |
| Tunnel queue drops → QUIC loss | 941 drops = 941 QUIC lost packets (of 758 015) | — |

The loopback throughput is far above any USB link (USB 2 adb ≈ 0.3 Gbit/s), so CPU is not the tunnel's
limit. Its latency under load depends on the congestion controller and the FIFOs under it, which S4 measures.


### Q5 — priorities, datagrams, reset, stats

| Need | API (iroh 1.4.1 re-exports noq 1.4.0) | Probe evidence |
|---|---|---|
| Stream priority | `SendStream::set_priority(i32)` / `priority()`; higher first; equal priorities round-robin when `send_fairness` (default true) (`noq-1.4.0/src/send_stream.rs:230`) | `stream_priority_roundtrip=true`. In S4, priorities keep control/video ahead of bulk on the sender (see the S4 result) |
| RFC 9221 datagrams | `send_datagram(Bytes)`, `send_datagram_wait`, `read_datagram()`, `max_datagram_size()`, `datagram_send_buffer_space()` (`connection.rs:995–1050`); oversize → `SendDatagramError::TooLarge` | `max_datagram_size=Some(1414)` on loopback after path-MTU discovery (1452 B UDP payload; starts from the 1200 B minimum); over the tunnel 1288–1382 B; a 1414 B datagram round-tripped; 1415 B → `TooLarge`; send buffer 1 MiB (`1048544`). Opus packets (≈ 330 B) fit with room to spare |
| Per-stream reset / stop | `SendStream::reset(VarInt)`, `RecvStream::stop(VarInt)`, `received_reset()`, `SendStream::stopped()` (`send_stream.rs:213,255`, `recv_stream.rs:288,338`) | client reset with 42 → server `ReadError::Reset(42)` (`server_saw_reset_code=Some(42)`) |
| Stats / RTT | `Connection::stats()` (packets, bytes, lost packets/bytes, frame counts), `rtt(PathId)`, `paths()` → per path `rtt()`, `stats()` (`cwnd`, `congestion_events`, …), `congestion_state(PathId)` (`connection.rs:1056–1197`) | `quic_rtt_path0=Some(105.686µs)`, `stats_sent_packets=204`, `stats_lost_packets=0`, path `rtt=105.686µs cwnd=61026`; in S4, QUIC's lost-packet count matched the proxy's drop count exactly, e.g. `loss1 quic` seed 1: proxy lost 220, QUIC lost 220; `clean quic` seed 1: 5311 queue drops, QUIC lost 5311 ([`summary.md`, path checks](../../spikes/s04-transport/results/s4/summary.md#path-checks-quic-runs)) |
| Congestion controller choice | `QuicTransportConfig::builder().congestion_controller_factory(...)` with noq-proto `CubicConfig` (default), `NewRenoConfig`, `Bbr3Config` | used by S4 (`--cc cubic|bbr3`) |

### Q6 — binary size (macOS arm64, stripped)

| Variant | profile `size` (LTO, opt s, strip, abort) | profile `release` + strip |
|---|---|---|
| `size-baseline` (tokio UDP echo) | 0.35 MiB (370 464 B) | 0.53 MiB (554 032 B) |
| `size-min` (iroh, `tls-ring` only) | **3.30 MiB** (3 458 448 B) → **+2.94 MiB** | 8.70 MiB (9 121 824 B) → +8.2 MiB |
| `size-min --features full` (iroh default features) | 3.85 MiB (4 038 752 B) → +3.5 MiB | 10.63 MiB (11 149 376 B) → +10.1 MiB |
| **Android arm64** (`aarch64-linux-android`, NDK 29, API 26), profile `size`: baseline / min / full | 0.36 MiB (375 568 B) / **4.16 MiB** (4 362 224 B) → **+3.80 MiB** / 4.75 MiB (4 981 880 B) → +4.39 MiB | not measured |

Raw: [`results/s5/size/sizes.txt`](../../spikes/s04-transport/results/s5/size/sizes.txt),
[`results/s5/size/android.txt`](../../spikes/s04-transport/results/s5/size/android.txt) (Android binaries need only
`libc`, `libm`, `libdl`). Linked libraries are
system frameworks only (SystemConfiguration, Security, CoreFoundation, Foundation, libSystem, libobjc,
libiconv). A universal (arm64 + x86_64) Mac binary roughly doubles the Mac figure. These are executables;
a `.so` with UniFFI scaffolding (what the apps load) is S10's measurement. For comparison, research 04 quotes
≈ 12.8 MB for iroh-ffi's arm64 `.so`, built without our size profile.

## Verdict

| # | Criterion (as written in the plan) | Verdict | Evidence |
|---|---|---|---|
| 1a | iroh/noq endpoint with default relays and DNS discovery **disabled** (direct addresses only) — Mac | **pass** | Q2 config; `iroh-probe api` → `connect_ms=1.09`, `done=true`, with an `EndpointAddr` holding only an IP |
| 1b | Same, Android build on the phone | **blocked — needs phone** | the Android binary builds (Q6); not run on a device |
| 2a | Works / verified with **outbound Internet blocked** — Mac | **pass** | Q2: under `sandbox-exec` the session completes. The only denied operations are **seven** packet-less route lookups (`remote:*:1`); nothing goes to DNS, relays, STUN/QAD or UPnP. The control run trips the same detector 51 843 times |
| 2b | Same check from the phone, with the phone offline from the Internet | **blocked — needs phone** | — |
| 3a | TLS exporter available — Mac | **pass** | Q3: `exporter_match=true` (IP and tunnel). Not in iroh-ffi 1.2.0 → needs our own thin UniFFI crate |
| 3b | TLS exporter on the phone (Android build) | **blocked — needs phone** | — |
| 4a | Custom-transport hooks (QUIC over a TCP tunnel) — Mac loopback | **pass** | Q4: one- and two-process runs. Caveat: only behind `unstable-custom-transports` (no semver guarantee) → pin the exact iroh version and keep the tunnel in our crate |
| 4b | QUIC over a real `adb forward` | **blocked — needs phone** | procedure: S4 `scripts/phone-runs.sh` (USB block) |
| 5 | Priorities, RFC 9221 datagrams (max size), per-stream reset, stats/RTT | **pass** | Q5 |
| 6 | Binary size of a minimal endpoint, release + stripped (P3) | **pass** | Q6: macOS arm64 +2.94 MiB (size profile) / +8.2 MiB (plain release + strip); Android arm64 +3.80 MiB (size profile). Executables; a UniFFI `.so` is S10's measurement |

**Overall, §0.C pass criterion "all available or patchable in a thin crate": pass on the Mac.** The phone rows
are still blocked. Everything Tombolo needs is in iroh's Rust API. Three things are missing from the official FFI: the exporter, custom transports
and the portmapper/net-report switches (`grep portmapper|net_report` over iroh-ffi's `src/` finds only a
status field). That is the thin crate the ADR anticipated.

**Coverage:** the phone side of every row was not run: the Android binary builds (Q6), but running it on the
phone without Internet and over a real `adb forward` was not done.

## Consequences for the plan

- **ADR-0003 (iroh 1.x / noq) holds for S5.** The §0.C fallback ("quinn/noq directly") is not triggered.
  noq's `AsyncUdpSocket` remains the escape hatch if the unstable iroh hook breaks.
- **`tombolo-core` needs its own UniFFI crate** on iroh's Rust API (not iroh-ffi as-is). It must expose
  `export_keying_material`, own the tunnel transport and set `PortmapperConfig::Disabled` and
  `NetReportConfig::minimal()`. This matches research 04 §2.5 ("otherwise write a thin crate"). Hand it to S10
  / Phase 1a *(Re-plan 2026-11-02: Phase 1)*.
- **Pin iroh exactly** (`=1.4.x`) while using `unstable-custom-transports`. Each iroh upgrade needs a
  re-run of `iroh-probe tunnel` (add it to CI).
- **The "no public infrastructure" CI test** ([ADR-0003](../decisions/0003-transport.md)) can be this
  sandbox-exec check on macOS runners: zero denials to anything except `:1` route lookups. On Linux, a network
  namespace with only loopback is the equivalent. **Portmapper must be disabled explicitly**: with default
  features it is compiled in and on (the control run shows SSDP `:1900`). Alternatively build with
  `default-features = false`, which also saves ≈ 0.55 MiB.
- **iroh always enables multipath and QUIC NAT traversal.** Values below the minimum are ignored with a warning
  (`max_concurrent_multipath_paths` ≥ 9, `max_remote_nat_traversal_addresses` ≥ 8; `iroh-1.4.1/src/endpoint/quic.rs:473–546`).
  A connection therefore advertises the local addresses and hole-punches to the peer's. The N0 control run
  migrated off the dialled address to a public IPv6 address. For Tombolo this is LAN-only traffic to an
  already-paired peer, but it means: (a) bind to the interfaces we intend to use; (b) the S4 harness had to put
  the two sides on different address families so they could not bypass the impairment proxy; (c) the
  Phase 2 privacy review should note that the peer learns all bound local addresses; (d) **untested:** this
  advertising and probing may itself raise the macOS **Local Network** alert when the endpoint is created or
  connects, and the peer's probes may raise the Application Firewall prompt. The phone runs record both (S4
  `scripts/phone-runs.sh`, prerequisites 5–6).
- Jumbo QUIC packets over the tunnel are **not explored**. A quick try with `initial_mtu(16000)` hung at the
  handshake; the default (path-MTU discovery up to 1452 B) is what S4 measured.
- When the tunnel's TCP socket closes, noq logs `I/O error: All transports failed to receive`. A production
  tunnel needs reconnect handling: a new adb forward means a new session, per
  [protocol §8](../protocol.md#8-robustness-rules).
