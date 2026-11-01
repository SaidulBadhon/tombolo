# S4 — Transport per path (Mac-only half)

| | |
|---|---|
| **Spike** | S4 (run together with S5 in P0-14) |
| **Task** | P0-14 — see the [Phase 0 task plan](../plans/phase-0.md#acceptance-criteria-per-task) |
| **Pass criteria** | [Implementation plan §0.C](../implementation-plan.md#0c-spikes-each-produces-a-short-write-up-in-docsspikes): *(a) QUIC on Wi-Fi vs TLS/TCP-per-channel on Wi-Fi, (b) on USB: QUIC-over-one-adb-TCP vs framed TCP channels over adb; both with a concurrent 1 GB file transfer. On congested Wi-Fi, QUIC p95 frame latency ≤ TCP; on USB, chosen option adds ≤ 5 ms p95.* P0-14 adds: *p50/p95 frame latency, throughput, CPU; recommended transport per path.* |
| **Spike code** | `spikes/s04-transport/` — loopback matrix measured with the bench built from `d6bf2bba5330df7c81a3de208ab0407c2e9b254f`; `burst3` re-measured and spot checks run with the bench built from `7b73e1b40b3aa1ba5145704401271090f85dd3aa` (results committed in `71cbbca`) |
| **Author(s)** | Claude (agent) for the maintainer |
| **Date(s) run** | 2026-10-26 |
| **Status** | draft — Mac-only half complete; every device criterion **blocked — needs phone** |

## Question

On each path Tombolo uses, which transport keeps video, audio and input latency low while a large file
transfer runs at the same time? Wi-Fi: QUIC (iroh/noq: streams with priorities plus datagrams) or TLS 1.3 over
one TCP connection per channel. USB, where `adb forward` carries TCP only: QUIC packets over one adb TCP
connection, or framed TCP channels over several forwards. [ADR-0003](../decisions/0003-transport.md) stays
*Proposed* until this is answered on real links.

**This document answers it only indicatively.** Everything ran on one Mac over loopback through a
userland impairment proxy. The real Wi-Fi and USB runs are scripted and waiting for the phone (see
[Phone runs](#phone-runs-deferred)).

## Setup

**Devices**

| Role | Model | OS version and build | OEM skin / version | Notes |
|---|---|---|---|---|
| Phone | — (emulated by a process on the Mac) | — | — | real phone runs deferred |
| Mac | Apple M4 Pro, 12 cores, 48 GB | macOS 27.0.1 (`sw_vers` build 26A434) | — | **shared machine**: a Virtualization.framework VM used 2.3–3.2 cores, and other agents' jobs ran during the
runs. The 1-minute load average before each run had a median of 7.2 (12 cores), with peaks of 19–57 during six
seed-1 runs (04:04–04:07). Those six runs fall within or at the edge of the other seeds' range (see the seed
ranges below). Per-run snapshots: [`results/s4/load.log`](../../spikes/s04-transport/results/s4/load.log) |

**Builds and tools**

| Component | Version / commit | How obtained |
|---|---|---|
| Spike code | `d6bf2bb` (matrix), `7b73e1b` (burst3 + spot checks); verified with `cargo build -v` reporting the bench *Fresh* against the committed sources before the runs were committed | this repository |
| iroh / noq | 1.4.1 / 1.4.0, default features + `unstable-custom-transports`; congestion control Cubic (noq default) or BBRv3 (`noq_proto::congestion::Bbr3Config`) | crates.io, `Cargo.lock` |
| TLS for the TCP variants | rustls 0.23.46 + tokio-rustls 0.26, *ring* provider (same as iroh), TLS 1.3 only | crates.io |
| Rust | 1.98.0, `--release` | rustup |

**Environment:** loopback (`lo0`) only. No Wi-Fi, no USB, no phone.

## Method

**Processes.** `bench run` is the driver. It hosts the impairment proxy and spawns two processes of the same
binary: `phone` (listens, sends media, echoes control) and `mac` (connects, receives, sends control pings).
Each side's CPU comes from its own `getrusage`, sampled every second. All timestamps use
`CLOCK_MONOTONIC_RAW`, which is system-wide, so one-way latency on one Mac needs no clock sync. The Mac also
estimates the clock offset from control pings, as it will have to on a phone; on loopback the estimate came
out ≈ 0 ms (self-check, see the spot checks).

**Transports** (`bench/src/session.rs`). Every variant carries the same four channels:

| Label | Control | Video | Audio | Bulk |
|---|---|---|---|---|
| `quic` / `quic+bbr3` | bidi stream, priority 10 | uni stream, priority 5 | RFC 9221 datagrams | uni stream, priority −10 |
| `tcp` | TLS 1.3 / TCP conn. | TLS 1.3 / TCP conn. | TLS 1.3 / TCP conn. (length-prefixed, ≤ 100 ms drop-oldest queue) | TLS 1.3 / TCP conn. |
| `rawtcp` | as `tcp` without TLS — the scrcpy-style baseline for "added latency" on USB | | | |
| `tunnel`, `tunnel+bbr3`, `tunnel-lean+bbr3` | the `quic` layout, but every QUIC packet rides length-prefixed on **one** TCP connection (iroh custom transport from S5). `lean` = small FIFOs under QUIC: 32-packet queue, 16 KB `TCP_NOTSENT_LOWAT`, 16 KB write buffer (default: 128 packets, 128 KB, 256 KB) | | | |

Common settings: iroh endpoints with relays, address lookup and portmapper off (as in S5); identities from
fixed seeds. TCP sockets use `TCP_NODELAY` and `TCP_NOTSENT_LOWAT` = 128 KB.

**Workload** (`bench/src/work.rs`), 20 s per run; the first 2 s are excluded from statistics.

- **Video**, phone → Mac, 60 fps. P-frames uniform 25–40 KB, a keyframe of 200–300 KB every 120 frames
  (≈ 16.5 Mbit/s). Each frame carries the [protocol §4](../protocol.md#4-media-framing-video-streams) 24-byte
  header. Frame sizes come from a seeded generator, so every transport sends the same sequence.
- **Pre-transport queue** of ≤ 2 frames, drop oldest (protocol §4). The sender also applies **frame-level
  flow control**: at most 4 frames (≈ 67 ms) written but not yet acknowledged by the Mac, which acks each
  frame on the control channel. Without it, a QUIC stream accepts frames until its 1.25 MB flow-control window
  is full, and latency grows to ~1 s whenever capacity falls short (seen in a trial run). TCP has
  `TCP_NOTSENT_LOWAT` for this; noq has no per-stream equivalent. This is the protocol's planned
  `ReceiverFeedback`, simplified, and it is applied to every transport alike.
- **Audio**: 20 ms packets of 4 B seq + 8 B capture time + 320 B payload (Opus at 128 kbit/s).
- **Control**: ping every 10 ms from the Mac, echoed by the phone (16 bytes at `d6bf2bb`; 24 bytes from
  `7b73e1b`, which adds the phone's timestamp for clock-offset estimation). Frame acks share the channel.
- **Bulk**, phone → Mac, 64 KB chunks: continuously from t = 6 s to 14 s; for `cap100`, four 1 s bursts at
  t = 4, 8, 12 and 16 s. This scales down the plan's 1 GB transfer: 8 s at up to 300 Mbit/s moves about
  280 MB. The phone runs use 1 GiB.

**Metrics.**

- Frame latency: last byte of the frame at the Mac minus the capture timestamp. It includes pre-transport
  queueing, but not encode or decode.
- Frame p95 under bulk: frames captured between a burst's first send and the arrival of its last byte.
- Frames lost: generated minus received (sender drops).
- Audio: lost or later than 40 ms, the [protocol §5](../protocol.md#5-audio) jitter-buffer target.
- Control RTT; bulk Mbit/s over its receive span.
- CPU: % of one core per process, split into "media only" (2 s → bulk start) and "with bulk" (the bulk windows).

**Conditions** (`bench/src/cond.rs`), applied per direction:

| Name | Delay | Loss | Bottleneck | Bulk |
|---|---|---|---|---|
| `clean` | 0 | 0 | 300 Mbit/s, 10 ms buffer (375 KB) | 6–14 s |
| `jitter` | 5 ms ± 3 ms | 0 | 300 Mbit/s, 10 ms buffer | 6–14 s |
| `loss1` | 5 ms ± 3 ms | 1 % random | none | 6–14 s |
| `burst3` | 5 ms ± 3 ms | 3 %, in bursts: bad periods mean 3 ms, good periods mean 97 ms (exponential) | none | 6–14 s |
| `cap100` | 5 ms ± 3 ms | 0 | 100 Mbit/s, 20 ms buffer (250 KB) | four 1 s bursts |
| `usb` (adb model) | 0.25 ms | 0 | 320 Mbit/s (USB 2-class adb), 256 KB buffer | 6–14 s |

Jitter is drawn once per 5 ms slot and never reorders packets. Loss conditions have no bottleneck: loss
already limits the congestion window.

**How the impairment works — and where it is only a model.**

- **QUIC over UDP** goes through a UDP proxy that really drops, queues (drop-tail) and delays every packet.
  The Mac endpoint binds IPv4 loopback and the phone endpoint IPv6 loopback, so iroh's hole-punching cannot
  open a path around the proxy. Every run's final path was the proxy, and QUIC's lost-packet count equalled the
  proxy's drop count (see [`summary.md`](../../spikes/s04-transport/results/s4/summary.md#path-checks-quic-runs)).
- **TCP** (and QUIC-over-TCP) go through a TCP relay. A relay terminates TCP, so it cannot drop a segment
  without root (`dummynet`/`pf`). It applies the same delay, jitter and shared bottleneck FIFO with
  back-pressure (16 KB socket buffers on the relay keep the hidden queue small). Loss is **modelled**:
  - each "lost" 1448-byte segment stalls its own connection for 1.25 RTT + 1 ms (one RACK fast-recovery
    round) — no tail-loss probe, no RTO;
  - in loss conditions, each connection is limited to the loss-limited TCP rate (Mathis: 1.22·MSS/(RTT·√p),
    with the matching window), because without it the relay would let TCP run at 17 Gbit/s through 1 % loss
    (seen in a trial run).
  This is **optimistic for TCP**: no RTO or TLP, and an idealised congestion window. In the lossless capped
  conditions it is **slightly pessimistic**: a TCP bulk flow keeps the bottleneck buffer full, where real
  Cubic would oscillate below full after drops.
- **USB model:** the adb transport is a single FIFO with a 256 KB buffer shared by all forwarded
  connections. Real adb multiplexes forwards over USB with its own windows, and its buffering is unknown —
  the phone run will measure it.

**Runs.** 20 transport×condition combinations × 3 seeds = 60 runs of ≈ 25 s. The transport order rotates
per seed. Three trial runs and one artifact are kept separately ([below](#trial-runs-and-artifacts)).

Commands: [`spikes/s04-transport/README.md`](../../spikes/s04-transport/README.md#s4-commands).

**Known sources of error.**

- Loopback has no radio and no USB. Absolute numbers say nothing about real links; they compare transports
  under identical emulated conditions.
- The shared Mac (above) adds scheduling noise. The seed-to-seed range is shown for frame p95.
- The proxies add up to ≈ 0.1 ms timer slack per hop.
- tokio timers schedule frame generation with ≈ 1 ms granularity; capture time is the actual time, so it
  does not bias latency.
- Statistics are per run (n ≈ 1080 frames, 900 audio packets, 1800 pings); medians over 3 seeds.

## Raw numbers

Full tables, generated by `scripts/s4-summarize.py`: [`results/s4/summary.md`](../../spikes/s04-transport/results/s4/summary.md).
Raw JSON per run: [`results/s4/raw/`](../../spikes/s04-transport/results/s4/raw/). Run log:
[`runs.log`](../../spikes/s04-transport/results/s4/runs.log). All values are milliseconds unless stated;
each cell is the median of 3 seeds, and frame p95 also shows the seed range.

### Wi-Fi-like conditions — QUIC vs TLS/TCP per channel

| Condition | Transport | Frame p50 | **Frame p95** [range] | Frame p95 under bulk | Frames lost % | Audio lost or > 40 ms % | Control RTT p95 | Bulk Mbit/s | CPU phone / Mac, % of a core (media only → with bulk) |
|---|---|---|---|---|---|---|---|---|---|
| clean | `quic` (Cubic) | 1.4 | **10.7** [10.6–10.7] | 10.9 | 0 | 0 | 9.9 | 276 | 4→38 / 4→35 |
| clean | `quic+bbr3` | 1.5 | **5.0** [4.8–5.5] | 5.3 | 0 | 0 | 5.7 | 269 | 6→22 / 5→22 |
| clean | `tcp` | 1.2 | **15.1** [14.9–15.3] | 15.5 | 0 | 0 | 14.1 | 283 | 1→2 / 2→13 |
| jitter | `quic` | 8.1 | **13.2** [12.6–14.2] | 14.5 | 0 | 0 | 18.8 | 252 | 5→26 / 5→26 |
| jitter | `quic+bbr3` | 15.2 | **60.5** [59.3–66.1] | 47.0 | 2.6 | 0 | 29.9 | **21** | 4→7 / 3→5 |
| jitter | `tcp` | 9.4 | **20.6** [20.5–22.2] | 21.3 | 0 | 0 | 25.8 | 283 | 1→2 / 1→11 |
| loss1 | `quic` | 102.0 | **170.4** [169.6–192.7] | 172.3 | **29.5** | 0.9 | 26.9 | 1 | 3→4 / 3→4 |
| loss1 | `quic+bbr3` | 56.6 | **141.3** [134.7–155.6] | 149.8 | 16.8 | 1.6 | 32.8 | 1 | 4→4 / 3→3 |
| loss1 | `tcp` (model) | 86.5 | **108.8** [107.4–109.5] | 111.2 | 14.8 | 0 | 17.5 | 14 | 1→1 / 2→2 |
| burst3 | `quic` | 23.1 | **127.7** [109.2–130.5] | 134.5 | 8.8 | 3.1 | 41.8 | 5 | 5→4 / 4→4 |
| burst3 | `quic+bbr3` | 85.7 | **163.7** [149.6–178.3] | 199.0 | 32.4 | 3.4 | 66.5 | 2 | 5→5 / 3→3 |
| burst3 | `tcp` (model) | 24.7 | **76.5** [71.3–79.8] | 81.0 | 2.8 | 0 | 26.0 | 17 | 1→1 / 2→3 |
| cap100 | `quic` | 9.3 | **25.4** [25.0–26.2] | **50.0** | 0 | 0.3 | 27.4 | 84 | 4→10 / 3→10 |
| cap100 | `quic+bbr3` | 15.8 | **75.2** [65.4–75.6] | 75.7 | 2.6 | 0 | 27.9 | 16 | 5→5 / 3→4 |
| cap100 | `tcp` | 9.0 | **34.3** [34.1–35.1] | **37.9** | 0 | 0 | 35.4 | 83 | 1→1 / 2→5 |

### USB (adb-forward model) — QUIC over one TCP connection vs framed TCP channels

| Transport | Frame p50 | **Frame p95** [range] | Frame p95 under bulk | **Δ p95 vs `rawtcp`** (all / under bulk) | Audio p95 | Control RTT p95 | Bulk Mbit/s | CPU phone / Mac (media → bulk) |
|---|---|---|---|---|---|---|---|---|
| `rawtcp` (scrcpy-style baseline) | 1.3 | **10.1** [9.8–10.2] | 10.6 | — | 9.1 | 9.4 | 303 | 1→1 / 2→16 |
| `tcp` (TLS 1.3 per channel) | 1.5 | **10.3** [10.3–10.5] | 10.6 | **+0.2 / +0.0** | 9.8 | 10.1 | 303 | 1→2 / 2→11 |
| `tunnel` (Cubic, default buffers) | 1.5 | **25.3** [25.0–25.5] | 26.7 | **+15.2 / +16.1** | 24.3 | 24.8 | 296 | 4→16 / 6→35 |
| `tunnel+bbr3` | 1.4 | **3.5** [2.5–5.0] | 4.1 | **−6.6 / −6.5** | 2.3 | 3.6 | 280 | 2→26 / 3→36 |
| `tunnel-lean+bbr3` | 1.7 | **4.1** [2.6–4.3] | 5.0 | **−5.9 / −5.6** | 2.9 | 5.5 | 259 | 2→15 / 3→29 |

No video frame was lost in any `usb` run, and audio lost-or-late was ≤ 0.11 %.

### Spot checks at the final code (`7b73e1b`, seed 1)

| Run | Frame p95 (matrix range at `d6bf2bb`) | Clock-offset estimate |
|---|---|---|
| clean `quic` | 10.7 (10.6–10.7) | 0.013 ms |
| clean `tcp` | 13.7 (14.9–15.3) | 0.006 ms |
| usb `tunnel+bbr3` | 2.5 (2.5–5.0) | 0.011 ms |
| usb `rawtcp` | 9.9 (9.8–10.2) | 0.007 ms |

The final code reproduces the matrix within run-to-run noise. The clock-offset estimator the phone runs rely
on returns ≈ 0 when both sides share a clock. Raw: [`results/s4/spotcheck/`](../../spikes/s04-transport/results/s4/spotcheck/).

### What the numbers say

1. **With a concurrent bulk transfer on a bottleneck, the queue in front of the bottleneck sets video
   latency.** TCP per channel puts video behind whatever the bulk connection has queued: about 10 ms at
   300 Mbit/s and 20 ms at 100 Mbit/s, plus the sender buffer. QUIC with **Cubic** fills the same buffer, so its
   stream priorities only help on the sender side: clean 10.7 vs 15.1 ms, jitter 13.2 vs 20.6 ms. During
   `cap100` bursts QUIC/Cubic was **worse** (50.0 vs 37.9 ms under bulk). There the drop-tail losses also hit
   video packets, which then wait for retransmission; TCP's per-connection queues in the model never drop video.
2. **QUIC with BBRv3 is excellent where there is no jitter and broken where there is** (noq 1.4.0). It paces at
   the estimated bottleneck rate and keeps the queue short: clean 5.0 ms, USB tunnel 3.5 ms. With ± 3 ms
   jitter, though, it throttled bulk to 16–21 Mbit/s and frame p95 rose to 60–75 ms (jitter, cap100). Real
   Wi-Fi jitters, so noq's BBRv3 is not usable on Wi-Fi as it stands.
3. **Under random or bursty loss, nothing carries 1080p60 at 16.5 Mbit/s** with ~10 ms RTT: frames are lost in
   every variant. One QUIC connection has one loss-limited congestion window, shared by video and bulk:
   about 12–14 Mbit/s at 1 % loss. In the model, TCP per channel gives video a window of its own. This
   is the model's most optimistic area for TCP: no RTO, no tail-loss probe, an idealised window. Even so,
   the structural point stands — a single multiplexed connection is more exposed to random loss. On real Wi-Fi,
   link-layer retransmission hides most loss; whether the phone sees residual loss is what the phone run must show.
4. **Audio**: QUIC datagrams lose exactly what the link loses (≈ 3 % in `burst3`, left to Opus concealment) and
   never wait behind other data. TCP audio retransmits within the 40 ms budget in the model, so 0 % — again
   optimistic. On lossless paths both deliver 100 %, and audio p95 follows the video queue for TCP (it shares
   the bottleneck).
5. **USB:** QUIC over one TCP connection is **only good with a pacing congestion controller.** With Cubic, the
   bulk stream's packets fill every FIFO under QUIC (tunnel queue, write buffer, socket buffer, adb), and video
   waits about 25 ms behind them, because priorities cannot reach below QUIC. With BBRv3 the same tunnel beats
   framed TCP channels by ≈ 6.5 ms under bulk. TLS on the framed channels costs nothing measurable (+0.2 ms).
6. **CPU:** QUIC is userland per-packet work. At 270–280 Mbit/s of bulk it used 22–38 % of a core on the
   sender and 22–36 % on the receiver, against 2 % and 11–13 % for TLS/TCP, where the kernel does
   segmentation and 64 KB writes amortise system calls. At media-only rates (≈ 16.5 Mbit/s) QUIC used 4–6 % of
   a core per side, against 1–2 % for TCP. On a phone this is a battery question that only the phone run can
   answer: Android has UDP GSO, macOS is measured here without it.

### Trial runs and artifacts

| What | Why it matters | Raw |
|---|---|---|
| `clean` without a bottleneck, QUIC/Cubic (trial) | The userland UDP proxy saturated at ≈ 650 Mbit/s, and its 4 MB socket buffer became an unmodelled queue: control RTT p95 14.6 ms under bulk. This is why every lossless Wi-Fi condition has an explicit 300 Mbit/s bottleneck | [`trial/clean-uncapped-quic-s1.json`](../../spikes/s04-transport/results/s4/trial/clean-uncapped-quic-s1.json) |
| `burst3` with a per-packet Gilbert–Elliott chain (artifact) | One Cubic run stalled for ≈ 8 s (control RTT p95 7.66 s, 70 % of audio lost). The likely cause is the model: a quiet sender stays "inside the burst" indefinitely, so each sparse probe is lost with p = 0.75 and the probe timeout keeps doubling. That run also coincided with a load spike (load average 28.8), so CPU starvation cannot be excluded. The model was replaced by bursts in time, and no stall recurred. What it does show: during a multi-second outage, such as Wi-Fi roaming, QUIC backs off exponentially, as TCP's RTO does. Tombolo needs application-level liveness (the S7 lease) and fast reconnect rather than transport recovery | [`trial/burst3-per-packet-ge/`](../../spikes/s04-transport/results/s4/trial/burst3-per-packet-ge/) |
| QUIC without frame-level flow control, `loss1` (trial, JSON not kept) | Frame p95 ≈ 1.06–1.09 s: noq accepted frames into a 1.25 MB stream window, and nothing was dropped at the sender. Tombolo's sender must bound frames in flight (ReceiverFeedback), not rely on the transport | not kept (console output only, before `runs.log` existed) |
| TCP model without a congestion window, `loss1` (trial, JSON not kept) | 17 Gbit/s "through" 1 % loss. This led to the Mathis per-connection limit | as above |

## Verdict

| # | Criterion (as written in the plan) | Verdict | Evidence |
|---|---|---|---|
| 1 | Benchmark **Wi-Fi QUIC vs TLS/TCP-per-channel** with a synthetic 1080p60 stream + audio datagrams + concurrent bulk; p50/p95 frame latency, throughput, CPU | Mac loopback with emulated impairment: **done (indicative)**. Real Wi-Fi: **blocked — needs phone** | Wi-Fi table; `SEEDS="1 2 3" ./scripts/s4-run-matrix.sh` → 60 runs, `results/s4/runs.log` |
| 2 | *On congested Wi-Fi, QUIC p95 frame latency ≤ TCP* | **blocked — needs phone.** Loopback indication: **mixed**. Yes, with Cubic: clean 10.7 ≤ 15.1, jitter 13.2 ≤ 20.6, cap100 overall 25.4 ≤ 34.3. No: under the cap100 bursts (50.0 > 37.9), and under loss (170 > 109; 128 > 77, against an optimistic TCP model) | Wi-Fi table |
| 3 | Benchmark **USB QUIC-over-one-adb-TCP vs framed TCP channels over adb** | adb-forward model on loopback: **done (indicative)**. Real `adb forward`: **blocked — needs phone** | USB table |
| 4 | *On USB, chosen option adds ≤ 5 ms p95* (vs the scrcpy-style baseline) | **blocked — needs phone.** Model: framed TLS/TCP channels **+0.2 ms** (would pass); QUIC tunnel with BBRv3 **−6.6 ms** (would pass); tunnel with Cubic **+15.2 ms** (would fail) | USB table, "Δ p95 vs `rawtcp`" |
| 5 | Concurrent **1 GB** file transfer | **not run at 1 GB** on the Mac: scaled to an 8 s bulk window, up to ≈ 300 MB per run (much less under loss, where video starves the low-priority bulk). The phone procedure uses 1 GiB (`--cond real`) | Method |
| 6 | Recommended transport per path | **provisional**, below | — |

**Coverage:** no phone, no real Wi-Fi, no real USB/adb. Every number above comes from loopback with
userland impairment on a shared Mac, and the TCP loss behaviour is modelled.

## Consequences for the plan

**Provisional recommendation for [ADR-0003](../decisions/0003-transport.md)** (to be confirmed or overturned
by the phone runs at the Phase 0 gate, P0-18):

- **Wi-Fi: keep QUIC (iroh/noq) with Cubic, plus three requirements the spike surfaced:**
  - **the sender bounds frames in flight** with ReceiverFeedback (≤ ~4 frames here); noq gives no per-stream
    back-pressure;
  - **bulk/file transfers are rate-capped** below the estimated capacity, as
    [architecture §6](../architecture.md#6-protocol-summary) already says ("lowest, rate-capped"); with them
    uncapped, Cubic fills the bottleneck and video waits;
  - **video bitrate adapts** to loss and RTT, because one connection's congestion window is shared.

  **Not BBRv3** on Wi-Fi (noq 1.4.0 collapses under jitter). Keep the **TLS/TCP-per-channel fallback**
  ready (the spike's TLS/TCP channel setup is ≈ 150 lines) until the phone shows QUIC p95 ≤ TCP under congestion and loss.
- **USB: provisionally QUIC over one adb TCP connection with BBRv3**, if the phone confirms that the
  tunnel beats framed channels under bulk. That keeps one stack, one security owner and datagram audio.
  Requirements:
  - pin iroh, because the custom transport is unstable (S5);
  - use small FIFOs under QUIC;
  - BBRv3 on this path only.

  **Framed TLS/TCP channels remain the fallback** and the safe default if the device result is close: +0.2 ms
  over the scrcpy baseline and far less CPU. The ADR's expectation that "(b) is the expected USB answer" is
  therefore **open**: the model favours (a) on latency and (b) on CPU and simplicity.
- **CPU/battery** becomes an explicit gate metric for the phone run. At bulk rates on the Mac, QUIC used
  ≈ 10–20× the sender CPU and ≈ 2–3× the receiver CPU of TLS/TCP.
- **Protocol §4 / §8:** add frame-level flow control (frames in flight, from ReceiverFeedback) to the sender
  rules, and keep "bulk yields to media under pressure", which needs an explicit bulk rate cap.
- **Estimate impact:** the transport layer needs a choice of congestion controller per path and a
  rate-capped bulk scheduler. Both are small in tombolo-core, but they should be named tasks in Phase 1a/2.
- Fallback triggered by §0.C: none yet. The Wi-Fi fallback (TLS/TCP per channel, rustls in core) stays live
  until the phone result.

## Phone runs (deferred)

Ready to run; not run, because the phone was not reachable over adb during this task. The full procedure is
in [`spikes/s04-transport/README.md`](../../spikes/s04-transport/README.md#phone-runs-deferred) and
[`scripts/phone-runs.sh`](../../spikes/s04-transport/scripts/phone-runs.sh):

1. **Person:** unlock the phone; connect the USB cable; authorise USB debugging; put phone and Mac on the same
   Wi-Fi (record SSID, band, channel and RSSI).
2. `./scripts/build-android.sh` cross-compiles the bench for `aarch64-linux-android` (NDK 29, API 26).
   **Verified today:** it builds, `target/android/aarch64-linux-android/release/bench: ELF 64-bit LSB pie
   executable, ARM aarch64`, needing only `libc`, `libm` and `libdl`.
   **Also verified today, without a phone:** the procedure's code path (`--path direct`, phone side started
   through a wrapper command as `adb shell` would, relative start, clock-offset estimate, condition `real`)
   ran on loopback for `quic` and `tcp`: 1 GiB delivered (1 074 003 968 B with chunk headers), 2700/2700
   frames, offset estimate 0.012 / 0.006 ms
   ([`results/s4/direct-path-smoke/`](../../spikes/s04-transport/results/s4/direct-path-smoke/); plumbing check
   only, not a measurement).
3. `TAG=quiet ./scripts/phone-runs.sh` pushes the binary and a test certificate to `/data/local/tmp`, then
   runs 3 seeds of:
   - **Wi-Fi** `quic` (Cubic, BBRv3) and `tcp`, with the Mac dialling the phone's `wlan0` address
     (`--path direct`);
   - **USB** `tunnel`, `tunnel+bbr3`, `tunnel-lean+bbr3`, `tcp` and `rawtcp` through `adb forward`
     (`--path adb-forward`).

   Each run is condition `real`: 45 s, with a concurrent 1 GiB transfer. About 25 min in total.
4. **Person:** repeat the Wi-Fi block with `TAG=congested` while another device saturates the same access point,
   and record what it was. This is the "congested Wi-Fi" of the pass criterion.
5. `scripts/s4-summarize.py` writes `results/s4/phone-raw/summary-*.md`. Copy the verdicts into this document
   and update ADR-0003 at P0-18.

**Unverified parts of the procedure:**

- `adb shell` forwarding stdin for the start signal (if it doesn't, the phone falls back to starting 3 s after
  `READY`);
- the phone binding `0.0.0.0` from the shell uid on Android 16;
- `adb forward` carrying 4–5 concurrent connections at full rate;
- the accuracy of the clock-offset estimate across devices: expected within half the minimum-RTT asymmetry,
  about 0.5 ms on USB and 1–3 ms on Wi-Fi.


