# s04-transport — spikes S4 + S5 (task P0-14)

**Throwaway spike code** (see [`spikes/README.md`](../README.md)). Results:
[`docs/spikes/s04-transport.md`](../../docs/spikes/s04-transport.md) (S4, transport per path) and
[`docs/spikes/s05-iroh-api.md`](../../docs/spikes/s05-iroh-api.md) (S5, iroh/noq API surface).

What runs here today is the **Mac-only half**: everything on one Mac, over loopback, with a userland
impairment proxy (no root, no dummynet). Phone runs (real Wi-Fi, real `adb forward` over USB) are prepared
but **deferred** — see [Phone runs](#phone-runs-deferred).

## Layout

| Path | What |
|---|---|
| `tcp-tunnel/` | iroh **custom transport** that carries QUIC packets length-prefixed (`u16`) over one TCP stream — the adb-forward model (uses iroh's `unstable-custom-transports` feature) |
| `iroh-probe/` | S5 probe: exporter, streams (priority, reset), datagrams, stats/RTT, egress check, QUIC-over-TCP proof |
| `size-min/`, `size-baseline/` | S5 binary-size measurement (minimal iroh endpoint vs a tokio-only baseline) |
| `bench/` | S4 benchmark: driver + impairment proxy + `phone` / `mac` child processes |
| `scripts/` | the commands below, the sandbox profile, the summariser |
| `results/` | raw outputs (`s5/`, `s4/raw/*.json`, `s4/summary.md`, `s4/load.log`) |

Toolchain: Rust 1.98 (`rustup` stable), crates pinned in `Cargo.lock` (iroh `=1.4.1`, noq 1.4.0, rustls
0.23 with *ring*). Nothing else is installed; `sandbox-exec`, `lsof`, `nettop` and `log` ship with macOS.

## S5 commands

```sh
cd spikes/s04-transport
cargo build --release -p iroh-probe

# API surface on loopback (exporter, priority, reset, datagrams, stats); prints RESULT k=v lines
./target/release/iroh-probe api

# Egress check: Tombolo config vs iroh's public preset (positive control), under a sandbox
# that denies all non-loopback outbound traffic, plus lsof/nettop snapshots (≈ 2 min)
./scripts/s5-egress.sh                 # -> results/s5/egress-*.txt

# QUIC over one TCP stream (custom transport) on loopback, same config, sandboxed
sandbox-exec -f scripts/deny-non-loopback.sb ./target/release/iroh-probe tunnel --mb 1024
#   two processes instead of two tasks:
#   ./target/release/iroh-probe tunnel --role listen --port 47000 &
#   ./target/release/iroh-probe tunnel --role connect --port 47000 --mb 256

# Binary size (macOS arm64; profile `size` = fat LTO, opt-level s, strip, panic=abort)
cargo build --profile size -p size-min && cargo build --profile size -p size-baseline
cargo build --profile size -p size-min --features full     # iroh default features
ls -l target/size/size-min target/size/size-baseline
#   Android arm64: same crates through the NDK (env as in scripts/build-android.sh), e.g.
#   CARGO_TARGET_DIR=target/android cargo build --profile size --target aarch64-linux-android -p size-min
#   -> results/s5/size/android.txt
```

## S4 commands

```sh
cd spikes/s04-transport
cargo build --release -p bench

# one run (≈ 25 s): transport ∈ quic | tcp | rawtcp | tunnel | tunnel-lean,
# cond ∈ clean | jitter | loss1 | burst3 | cap100 | usb | clean-uncapped, cc ∈ cubic | bbr3 | newreno
./target/release/bench run --transport quic --cc bbr3 --cond cap100 --seed 1 --out results/s4/raw

# the full Mac-only matrix (20 runs per seed, ≈ 8 min per seed) and the summary
SEEDS="1 2 3" ./scripts/s4-run-matrix.sh
python3 -I scripts/s4-summarize.py results/s4/raw > results/s4/summary.md
```

How a run works: the driver process hosts the impairment proxy (UDP proxy for `quic`, TCP relay for the
others; its CPU is reported as `proxy_cpu_s`) and spawns `bench phone` (listener, media sender) and
`bench mac` (connector, controller) as separate processes, so each side's CPU is measured with `getrusage`.
Timestamps use `CLOCK_MONOTONIC_RAW`, which is system-wide, so loopback one-way latencies need no clock sync
(the Mac still estimates the offset from control pings; on loopback it must come out ≈ 0 — a self-check).

Conditions (per direction): `clean` = 300 Mbit/s bottleneck, 10 ms drop-tail buffer; `jitter` = clean + 5 ms
± 3 ms; `loss1` = 5 ± 3 ms + 1 % random loss; `burst3` = 5 ± 3 ms + 3 % loss in bursts (mean 3 ms);
`cap100` = 5 ± 3 ms + 100 Mbit/s, 20 ms buffer, four 1 s bulk bursts; `usb` = adb model, 0.25 ms, 320 Mbit/s,
lossless. Exact definitions: `bench/src/cond.rs`. The TCP relay cannot drop segments; how it models TCP loss
is documented in `bench/src/proxy.rs` and in the S4 result document.

## Phone runs (deferred)

Needs the phone (USB debugging authorised) and the Android toolchain session; **not run in P0-14's Mac-only
half**. Everything is scripted:

```sh
cd spikes/s04-transport
./scripts/build-android.sh       # cross-compiles bench for aarch64-linux-android (NDK clang, API 26)
TAG=quiet ./scripts/phone-runs.sh      # Wi-Fi (direct) + USB (adb forward), 3 seeds, ≈ 25 min
TAG=congested ./scripts/phone-runs.sh  # repeat while another device saturates the access point
```

Physical steps for a person are listed at the top of `scripts/phone-runs.sh` (unlock, cable, same Wi-Fi,
generate congestion). The phone side runs as an `adb shell` process (shell uid), so no APK is needed. Phone
and Mac clocks differ; the Mac estimates the offset from the lowest-RTT control pings and corrects one-way
latencies (uncertainty ≈ half the minimum RTT asymmetry; recorded per run as `clock_offset_est_ms`).
