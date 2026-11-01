#!/usr/bin/env bash
# Spike S4 — run the Mac-only loopback matrix.
#   SEEDS="1 2 3" ./scripts/s4-run-matrix.sh        (≈ 25 s per run, 20 runs per seed)
#   WIFI_CONDS=burst3 RUN_USB=0 ./scripts/s4-run-matrix.sh   (a subset)
# Each run: results/s4/raw/<cond>-<transport>-s<seed>.json; machine load before each run
# goes to results/s4/load.log (load averages, benchmark processes, and the summed %CPU of all
# other processes — never their names: the log is committed). Measure on a quiet Mac only
# (docs/plans/phase-0.md, Execution notes); a high other_cpu_pct means the run is suspect.
set -euo pipefail
cd "$(dirname "$0")/.."
# Logs are committed: strip global/MAC-derived addresses from them on exit.
trap 'python3 -I scripts/redact.py results/s4/stderr.log results/s4/runs.log' EXIT
SEEDS=${SEEDS:-"1 2 3"}
OUT=results/s4/raw
mkdir -p "$OUT"
cargo build --release -p bench >/dev/null 2>&1
BIN=./target/release/bench
WIFI_CONDS=${WIFI_CONDS:-"clean jitter loss1 burst3 cap100"}
RUN_USB=${RUN_USB:-1}
WIFI_T=("quic cubic" "quic bbr3" "tcp cubic")
USB_T=("tunnel cubic" "tunnel bbr3" "tunnel-lean bbr3" "tcp cubic" "rawtcp cubic")

log_load() {
  { echo "== $(date '+%F %T') $*"
    uptime | sed -E 's/.*(load averages?:)/\1/'
    # benchmark processes by name; everything else only as one anonymous %CPU total
    ps -Ao pcpu=,comm= 2>/dev/null | awk '
      { cmd = $0; sub(/^ *[0-9.]+ +/, "", cmd); n = split(cmd, p, "/"); base = p[n] }
      base ~ /^(bench|iroh-probe|size-min|size-baseline|s4-bench)$/ { printf "%6.1f %s\n", $1, base; next }
      { other += $1 }
      END { printf "other_cpu_pct=%.0f\n", other }' || true
  } >> results/s4/load.log
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
  [ "$RUN_USB" = 1 ] || continue
  n=${#USB_T[@]}
  for i in $(seq 0 $((n - 1))); do
    read -r t cc <<<"${USB_T[$(((i + seed) % n))]}"
    run "$t" "$cc" usb "$seed"
  done
done
