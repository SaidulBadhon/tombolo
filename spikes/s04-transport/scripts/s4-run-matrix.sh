#!/usr/bin/env bash
# Spike S4 — run the Mac-only loopback matrix.
#   SEEDS="1 2 3" ./scripts/s4-run-matrix.sh        (≈ 25 s per run, 20 runs per seed)
# Each run: results/s4/raw/<cond>-<transport>-s<seed>.json; machine load before each run
# goes to results/s4/load.log (other jobs share this Mac — check it when reading numbers).
set -euo pipefail
cd "$(dirname "$0")/.."
SEEDS=${SEEDS:-"1 2 3"}
OUT=results/s4/raw
mkdir -p "$OUT"
cargo build --release -p bench >/dev/null 2>&1
BIN=./target/release/bench
WIFI_CONDS="clean jitter loss1 burst3 cap100"
WIFI_T=("quic cubic" "quic bbr3" "tcp cubic")
USB_T=("tunnel cubic" "tunnel bbr3" "tunnel-lean bbr3" "tcp cubic" "rawtcp cubic")

log_load() {
  { echo "== $(date '+%F %T') $*"; uptime;
    ps -Ao pcpu,comm -r 2>/dev/null | sed -n '2,6p' || true; } >> results/s4/load.log
}

run() { # transport cc cond seed
  log_load "$3 $1 $2 seed=$4"
  "$BIN" run --transport "$1" --cc "$2" --cond "$3" --seed "$4" --out "$OUT" 2>>results/s4/stderr.log \
    | tee -a results/s4/runs.log
}

for seed in $SEEDS; do
  for cond in $WIFI_CONDS; do
    # rotate the transport order per seed so no transport always runs first
    n=${#WIFI_T[@]}
    for i in $(seq 0 $((n - 1))); do
      read -r t cc <<<"${WIFI_T[$(((i + seed) % n))]}"
      run "$t" "$cc" "$cond" "$seed"
    done
  done
  n=${#USB_T[@]}
  for i in $(seq 0 $((n - 1))); do
    read -r t cc <<<"${USB_T[$(((i + seed) % n))]}"
    run "$t" "$cc" usb "$seed"
  done
done
