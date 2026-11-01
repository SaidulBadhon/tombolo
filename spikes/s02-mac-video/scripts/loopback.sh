#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Spike S2 (P0-15): phone-less measurement of the Mac half of the pipeline for one presenter.
# loopback/s02-loopback-source stamps the Mac clock into 1080×2400 @ 60 fps H.264 frames; s02-mirror --port shows
# them (separate process, so its CPU is its own); the S1 harness captures the mirror window and reads the clock
# back (kind "mac": same clock on both ends, no sync). Measures render → VT encode → loopback TCP → demux → VT
# decode → present → WindowServer composite. It does not include the phone, USB or adb.
#
#   scripts/loopback.sh PRESENTER [DURATION_S=30] [RUN_ROOT=runs]     PRESENTER: metal | metal-immediate | sbdl
#   CAPTURE=0 scripts/loopback.sh …    no harness capture: only CPU / energy sampling (the capture loads WindowServer)
set -euo pipefail
PRESENTER="${1:?usage: loopback.sh metal|metal-immediate|sbdl [DURATION_S] [RUN_ROOT]}"
DURATION="${2:-30}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
HARNESS="$REPO/tools/latency-harness"
RUN_ROOT="${3:-$HERE/runs}"
case "$PRESENTER" in
    metal) PARGS=(--presenter metal --metal-pacing displaylink) ;;
    metal-immediate) PARGS=(--presenter metal --metal-pacing immediate) ;;
    sbdl) PARGS=(--presenter sbdl) ;;
    *) echo "loopback: unknown presenter $PRESENTER" >&2; exit 2 ;;
esac
[ -x "$HARNESS/.build/release/latency-harness" ] || (cd "$HARNESS" && swift build -c release >&2)
(cd "$HERE" && swift build -c release --product s02-mirror >&2)
(cd "$HERE/loopback" && swift build -c release >&2)
LH="$HARNESS/.build/release/latency-harness"
RUN="$RUN_ROOT/$(date +%Y%m%d-%H%M%S)-loopback-$PRESENTER"
mkdir -p "$RUN"
echo "loopback: run directory $RUN" >&2
PIDS=()
trap 'for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done' EXIT INT TERM
{
    echo "# before — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "mac_loadavg: $(sysctl -n vm.loadavg)"
    echo "mac_model: $(sysctl -n hw.model) $(sysctl -n machdep.cpu.brand_string)"
    echo "mac_os: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    pmset -g therm 2>/dev/null | sed 's/^/mac_therm: /'
    pmset -g batt 2>/dev/null | sed 's/^/mac_batt: /'
    top -l 1 -n 0 2>/dev/null | grep -E "^CPU usage" | sed 's/^/mac_top: /'
} > "$RUN/conditions-before.txt"

"$HERE/loopback/.build/release/s02-loopback-source" 1080x2400 60 > "$RUN/source.port" 2> "$RUN/source.log" &
SPID=$!
PIDS+=($SPID)
for _ in $(seq 50); do [ -s "$RUN/source.port" ] && break; sleep 0.1; done
PORT="$(head -1 "$RUN/source.port")"
"$HERE/.build/release/s02-mirror" --port "$PORT" "${PARGS[@]}" --float --at 1330,60 --height 1000 \
    --title "Tombolo S2 mirror" --stats-every 10 --stats-json "$RUN/mirror-stats.json" \
    --duration $((DURATION + 20)) > "$RUN/mirror.log" 2>&1 &
MPID=$!
PIDS+=($MPID)
for _ in $(seq 100); do grep -q "streaming from" "$RUN/mirror.log" && break; sleep 0.1; done
grep -q "streaming from" "$RUN/mirror.log" || { cat "$RUN/mirror.log" >&2; exit 5; }
sleep 3
top -l $((DURATION + 2)) -s 1 -stats pid,command,cpu,power,threads -pid "$MPID" -pid "$SPID" -pid "$(pgrep -x WindowServer | head -1)" > "$RUN/mac-top.txt" 2>&1 &
PIDS+=($!)
if [ "${CAPTURE:-1}" = 1 ]; then
    "$LH" capture --run-dir "$RUN" --window "Tombolo S2 mirror (" --duration "$DURATION" --no-analyze > "$RUN/capture.stdout" 2>&1
    "$LH" analyze --run-dir "$RUN" > "$RUN/analyze.stdout" 2>&1 || true
else
    sleep "$DURATION"
    echo "no capture (CAPTURE=0): CPU / energy sampling only" > "$RUN/analyze.stdout"
fi
kill -TERM $MPID 2>/dev/null || true
for _ in $(seq 50); do kill -0 $MPID 2>/dev/null || break; sleep 0.1; done
for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
PIDS=()
echo "# after — loadavg $(sysctl -n vm.loadavg)" >> "$RUN/conditions-before.txt"
cat "$RUN/summary.txt" 2>/dev/null || cat "$RUN/analyze.stdout"
echo "loopback: done → $RUN" >&2
