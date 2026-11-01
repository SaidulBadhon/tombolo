#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Spike S2 (P0-15): one latency run with the S1 harness (software-timestamp mode) against s02-mirror, plus Mac and
# phone CPU sampling and the run conditions. Needs: the phone on USB, unlocked; tools/latency-harness merged into
# this branch; Screen Recording permission for the app running this script.
#
#   scripts/measure.sh PRESENTER [DURATION_S=60] [RUN_ROOT=runs]
#   PRESENTER: metal (CAMetalDisplayLink) | metal-immediate | sbdl
#
# Env: SERIAL (default: the only device), ADB, MIRROR_ARGS (extra s02-mirror flags, e.g. "--bit-rate 16000000").
# Output: RUN_ROOT/<timestamp>-<presenter>/ with the harness files (sync.jsonl, frames.csv, latency.csv,
# summary.*), mirror.log, mirror-stats.json, mac-top.txt, phone-top.txt, phone-battery.csv, conditions-*.txt.
# Nothing here saves screen images. The window list is grepped for the mirror window only, never stored.
set -euo pipefail

PRESENTER="${1:?usage: measure.sh metal|metal-immediate|sbdl [DURATION_S] [RUN_ROOT]}"
DURATION="${2:-60}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
HARNESS="$REPO/tools/latency-harness"
RUN_ROOT="${3:-$HERE/runs}"
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
SERIAL="${SERIAL:-$("$ADB" devices | awk 'NR>1 && $2=="device" {print $1; exit}')}"
[ -n "$SERIAL" ] || { echo "measure: no device in state 'device'" >&2; exit 2; }
A() { "$ADB" -s "$SERIAL" "$@"; }

case "$PRESENTER" in
    metal) PARGS=(--presenter metal --metal-pacing displaylink) ;;
    metal-immediate) PARGS=(--presenter metal --metal-pacing immediate) ;;
    sbdl) PARGS=(--presenter sbdl) ;;
    *) echo "measure: unknown presenter $PRESENTER" >&2; exit 2 ;;
esac

[ -x "$HARNESS/.build/release/latency-harness" ] || (cd "$HARNESS" && swift build -c release >&2)
(cd "$HERE" && swift build -c release --product s02-mirror >&2)
SERVER_FILE="$("$HERE/scripts/fetch-server.sh")"
LH="$HARNESS/.build/release/latency-harness"
MIRROR="$HERE/.build/release/s02-mirror"

if A shell dumpsys window | grep -q "isKeyguardShowing=true"; then
    echo "measure: the phone is locked. Unlock it (a person), then run this again." >&2
    exit 3
fi

RUN="$RUN_ROOT/$(date +%Y%m%d-%H%M%S)-$PRESENTER"
mkdir -p "$RUN"
echo "measure: run directory $RUN" >&2

conditions() { # $1 = before|after
    {
        echo "# $1 — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "mac_loadavg: $(sysctl -n vm.loadavg)"
        echo "mac_uptime: $(uptime)"
        echo "mac_model: $(sysctl -n hw.model) $(sysctl -n machdep.cpu.brand_string)"
        echo "mac_os: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
        pmset -g therm 2>/dev/null | sed 's/^/mac_therm: /'
        pmset -g batt 2>/dev/null | sed 's/^/mac_batt: /'
        top -l 1 -n 0 2>/dev/null | grep -E "^CPU usage|^Load Avg" | sed 's/^/mac_top: /'
        echo "phone_serial: $SERIAL"
        A shell 'echo "phone_model: $(getprop ro.product.model)"; echo "phone_build: $(getprop ro.build.display.id) android $(getprop ro.build.version.release) sdk $(getprop ro.build.version.sdk) patch $(getprop ro.build.version.security_patch)"
            dumpsys battery | grep -E "^  (level|status|temperature|AC powered|USB powered|voltage):" | sed "s/^ */phone_battery_/"
            dumpsys thermalservice | grep -E "Thermal Status" | sed "s/^/phone_/"
            dumpsys thermalservice | grep -E "mName=(battery|CPU0|CPU4|GPU0|skin)" | head -6 | sed "s/^[[:space:]]*/phone_temp: /"
            echo "phone_stay_on_while_plugged_in: $(settings get global stay_on_while_plugged_in)"
            echo "phone_screen_off_timeout_ms: $(settings get system screen_off_timeout)"
            echo "phone_peak_refresh_rate: $(settings get system peak_refresh_rate) min: $(settings get system min_refresh_rate)"
            echo "phone_low_power: $(settings get global low_power)"
            dumpsys display | grep -E "mActiveSfDisplayMode=" | head -1 | sed "s/^[[:space:]]*/phone_display: /"
            dumpsys power | grep -E "mWakefulness=" | sed "s/^[[:space:]]*/phone_power: /"' 2>/dev/null
        echo "usb: $("$ADB" devices -l | grep "^$SERIAL" | tr -s ' ')"
    } > "$RUN/conditions-$1.txt" 2>&1
}

PIDS=()
cleanup() {
    for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
    A reverse --remove tcp:8765 2>/dev/null || true
}
trap cleanup EXIT INT TERM

conditions before

# 1. Page + clock server, reachable from the phone through adb reverse.
A reverse tcp:8765 tcp:8765 >/dev/null
python3 "$HARNESS/server/serve.py" --run-dir "$RUN" > "$RUN/server.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 50); do curl -fsS http://127.0.0.1:8765/status >/dev/null 2>&1 && break; sleep 0.1; done

# 2. The phone opens the page in Chrome; one tap = fullscreen + screen wake lock (web/page.js).
open_page() {
    # application_id makes Chrome reuse (and reload) one tab for every run instead of opening a new one.
    A shell am start -a android.intent.action.VIEW -d "http://localhost:8765/?title=s02" \
        --es com.android.browser.application_id io.github.saidulbadhon.tombolo.s02 \
        -n com.android.chrome/com.google.android.apps.chrome.Main >/dev/null 2>&1
}
page_samples() { # largest sync-sample count of any page session seen by this run's server
    curl -fsS http://127.0.0.1:8765/status 2>/dev/null \
        | python3 -c 'import json,sys; s=json.load(sys.stdin)["sessions"]; print(max([v["sync_samples"] for v in s.values()] or [0]))' 2>/dev/null || echo 0
}
wait_samples() { # $1 = minimum, $2 = tries of 0.5 s
    for _ in $(seq "$2"); do [ "$(page_samples)" -ge "$1" ] && return 0; sleep 0.5; done
    return 1
}
open_page
if ! wait_samples 1 30; then echo "measure: page not up yet, re-sending the intent" >&2; open_page; fi
wait_samples 64 60 || { echo "measure: the page never synced (is it open on the phone?)" >&2; exit 4; }
read -r W H < <(A shell wm size | awk -F'[ x]' '/Physical size/ {print $3, $4}')
A shell input tap $((W / 2)) $((H * 3 / 4))
sleep 2

# 3. The mirror: floating, fixed position, unobstructed.
"$MIRROR" --server "$SERVER_FILE" --serial "$SERIAL" "${PARGS[@]}" --float --at 1330,60 --height 1000 \
    --title "Tombolo S2 mirror" --stats-every 10 --stats-json "$RUN/mirror-stats.json" --server-log \
    --duration $((DURATION + 25)) ${MIRROR_ARGS:-} > "$RUN/mirror.log" 2>&1 &
MPID=$!
PIDS+=($MPID)
for _ in $(seq 100); do grep -q "streaming from" "$RUN/mirror.log" && break; kill -0 $MPID 2>/dev/null || break; sleep 0.2; done
grep -q "streaming from" "$RUN/mirror.log" || { echo "measure: mirror did not start:" >&2; cat "$RUN/mirror.log" >&2; exit 5; }
sleep 4   # encoder warm-up, window settled

# 4. CPU / energy sampling during the capture. Mac: the mirror, the adb server (it relays the USB stream),
#    WindowServer (composites everything on screen, so only indicative). Phone: scrcpy server, encoder HAL,
#    SurfaceFlinger, Chrome; plus battery sysfs (net battery flow: the phone is on a charger, see the doc).
ADBPID="$(pgrep -f 'adb.*fork-server' | head -1)"
WSPID="$(pgrep -x WindowServer | head -1)"
top -l $((DURATION + 2)) -s 1 -stats pid,command,cpu,power,threads -pid "$MPID" -pid "$ADBPID" -pid "$WSPID" > "$RUN/mac-top.txt" 2>&1 &
PIDS+=($!)
A shell "top -b -d 1 -n $DURATION -o PID,USER,%CPU,RES,NAME | grep -E 'app_process|media.hwcodec|surfaceflinger|com.android.chrome|^ *PID'" > "$RUN/phone-top.txt" 2>&1 &
PIDS+=($!)
A shell "for i in \$(seq $DURATION); do echo \$(date +%s) \$(cat /sys/class/power_supply/battery/current_now) \$(cat /sys/class/power_supply/battery/voltage_now) \$(cat /sys/class/power_supply/battery/temp); sleep 1; done" > "$RUN/phone-battery.csv" 2>&1 &
PIDS+=($!)

# 5. Capture the mirror window region of the composited display; analyse after the last sync batch lands.
"$LH" capture --run-dir "$RUN" --window "Tombolo S2 mirror (" --duration "$DURATION" --no-analyze > "$RUN/capture.stdout" 2>&1
sleep 3
"$LH" analyze --run-dir "$RUN" > "$RUN/analyze.stdout" 2>&1 || true

kill -TERM $MPID 2>/dev/null || true
for _ in $(seq 50); do kill -0 $MPID 2>/dev/null || break; sleep 0.1; done
for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
PIDS=()
conditions after
# The device serial is an identifier of a personal phone: keep it out of the run files (they may be committed).
for f in "$RUN"/*.txt "$RUN"/*.log "$RUN"/*.json "$RUN"/*.stdout; do [ -f "$f" ] && sed -i '' "s/$SERIAL/<serial>/g" "$f"; done
cat "$RUN/summary.txt" 2>/dev/null || cat "$RUN/analyze.stdout"
echo "measure: done → $RUN" >&2
