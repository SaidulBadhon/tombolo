#!/usr/bin/env bash
# Spike S5 — prove that Tombolo's iroh configuration makes no outbound connections to
# public infrastructure, using two independent detectors:
#   1. sandbox-exec with a profile that denies every non-loopback outbound operation;
#      the kernel logs each denied attempt to the unified log -> we count them per PID.
#   2. lsof + nettop snapshots while the connection is held open (unsandboxed run), which
#      list every socket, its interface (lo0 / en0) and byte counts.
# A positive control (iroh's public `presets::N0`) must trip both detectors.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=./target/release/iroh-probe
OUT=results/s5
HOLD=${HOLD:-20}
mkdir -p "$OUT"
cargo build --release -p iroh-probe >/dev/null 2>&1

run_sandboxed() { # preset
  local preset=$1 log=$OUT/egress-sandbox-$1.txt
  local start; start=$(date '+%Y-%m-%d %H:%M:%S')
  set +e
  sandbox-exec -f scripts/deny-non-loopback.sb "$BIN" api --preset "$preset" --hold "$HOLD" >"$log.stdout" 2>"$log.stderr"
  local rc=$?
  set -e
  local pid; pid=$(sed -n 's/^RESULT pid=//p' "$log.stdout")
  sleep 3 # let the log subsystem flush
  /usr/bin/log show --start "$start" --style compact \
    --predicate "eventMessage CONTAINS \"deny(1) network-outbound\" AND eventMessage CONTAINS \"iroh-probe($pid)\"" \
    | grep -v '^Timestamp' > "$log.denials" || true
  {
    echo "preset=$preset pid=$pid exit_code=$rc hold=${HOLD}s"
    echo "denied_outbound_attempts=$(grep -c 'deny(1)' "$log.denials" || true)"
    echo "--- distinct denied destinations"
    sed -n 's/.*network-outbound //p' "$log.denials" | sort | uniq -c | sort -rn | head -40
    echo "--- probe output"
    cat "$log.stdout"
  } > "$log"
  rm -f "$log.stdout"
  # keep the evidence file small: first 200 kernel reports are plenty
  head -200 "$log.denials" > "$log.denials.tmp" && mv "$log.denials.tmp" "$log.denials"
  echo "== sandboxed $preset: exit=$rc denials=$(grep -c 'deny(1)' "$log.denials" || true)"
}

run_observed() { # preset — unsandboxed, snapshot sockets mid-run
  local preset=$1 log=$OUT/egress-observed-$1.txt
  "$BIN" api --preset "$preset" --hold "$HOLD" >"$log.stdout" 2>"$log.stderr" &
  local bg=$!
  sleep $((HOLD / 2))
  {
    echo "preset=$preset pid=$bg (snapshot at ~$((HOLD / 2))s of a ${HOLD}s hold)"
    echo "--- lsof -i -n -P -a -p $bg"
    lsof -i -n -P -a -p "$bg" || true
    echo "--- nettop -m tcp"
    nettop -L 1 -n -m tcp -p "$bg" 2>/dev/null || true
    echo "--- nettop -m udp"
    nettop -L 1 -n -m udp -p "$bg" 2>/dev/null || true
  } > "$log"
  wait "$bg" || true
  { echo "--- probe output"; cat "$log.stdout"; } >> "$log"
  rm -f "$log.stdout"
  echo "== observed $preset: tcp_conns=$(grep -c 'TCP .*->' "$log" || true) en0_rows=$(grep -c ',en0,' "$log" || true)"
}

run_sandboxed tombolo
run_sandboxed n0
run_observed tombolo
run_observed n0
