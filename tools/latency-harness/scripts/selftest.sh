#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Phone-less self-test of the software-timestamp mode.
#
#  A. The latency page is opened in a Mac browser window: by default a floating WebKit window
#     (`latency-harness page-window`, stays visible while someone uses the Mac); BROWSER=chrome uses
#     a throwaway Chrome profile in app mode, BROWSER=safari the user's Safari (those must be kept
#     in front by hand). That window plays the part of the "mirror". The capture tool
#     records it with ScreenCaptureKit and decodes every frame; the analysis maps the page's
#     render timestamps to the Mac clock with the logged clock-sync round trips.
#     → validates decoding, clock-sync maths and capture timestamps. The number measured is the
#       browser's own render → composited-display latency, NOT phone latency.
#  B. The Mac reference window (latency-harness mac-code) is captured the same way. Same clock on
#     both ends, so no clock sync is involved: an independent check of the capture timestamps.
#
# Needs: Screen Recording permission for the terminal app (System Settings › Privacy & Security ›
# Screen & System Audio Recording), an awake and unlocked display, and the test windows left
# visible while they run (~2 × DURATION seconds).
#
# usage: scripts/selftest.sh [RUN_DIR] [DURATION_S=30]
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
run="${1:-$here/runs/selftest-$(date +%Y%m%d-%H%M%S)}"
duration="${2:-30}"
port="${PORT:-8799}"
browser="${BROWSER:-webkit}"
token="selftest-$$"
mkdir -p "$run/page" "$run/mac"
cd "$here"
swift build -c release >/dev/null 2>&1 || swift build -c release
bin="$here/.build/release/latency-harness"

pids=()
cleanup() {
  for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  [ -n "${profile:-}" ] && rm -rf "$profile"
}
trap cleanup EXIT
# Keep the display awake while the test runs (a sleeping display stops rendering and capture).
caffeinate -d -w $$ &
pids+=($!)

echo "== A: latency page in $browser =="
python3 "$here/server/serve.py" --run-dir "$run/page" --port "$port" > "$run/page/server.log" 2>&1 &
pids+=($!)
sleep 1
url="http://127.0.0.1:$port/?title=$token"
if [ "$browser" = webkit ]; then
  "$bin" page-window --url "$url" --title "Tombolo latency page $token" --duration $((duration + 30)) \
    --at "${PAGE_AT:-60,80}" --size 480,860 > "$run/page/browser.log" 2>&1 &
  pids+=($!)
elif [ "$browser" = safari ]; then
  open -a Safari "$url"
else
  profile="$(mktemp -d /tmp/tombolo-latency-chrome.XXXXXX)"
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --user-data-dir="$profile" --no-first-run \
    --no-default-browser-check --disable-extensions --app="$url" --window-size=520,900 --window-position=60,60 \
    > "$run/page/browser.log" 2>&1 &
  pids+=($!)
fi
# Wait for the page's first clock-sync batch to reach the server.
for _ in $(seq 1 40); do
  if curl -fsS "http://127.0.0.1:$port/status" | python3 -c 'import json,sys; s=json.load(sys.stdin)["sessions"]; sys.exit(0 if any(v["sync_samples"]>=64 for v in s.values()) else 1)' 2>/dev/null; then
    break
  fi
  sleep 0.5
done
curl -fsS "http://127.0.0.1:$port/status"; echo
# ScreenCaptureKit only sees windows on the active Space, and browsers stop rendering hidden
# windows: wait until the page window is on screen.
for i in $(seq 1 40); do
  "$bin" list-windows | grep -q "$token" && break
  [ "$i" = 1 ] && echo "waiting for the page window to be visible on the current Space (bring it to the front)…"
  sleep 0.5
done
"$bin" capture --run-dir "$run/page" --window "$token" --duration "$duration" | tee "$run/page/capture.log"
curl -fsS "http://127.0.0.1:$port/status" > "$run/page/server-status.json" || true
# The page posts its final sync batch every 2 s; re-run the analysis with everything logged.
sleep 2.5
"$bin" analyze --run-dir "$run/page" > /dev/null

echo "== B: Mac reference window (same clock, no sync) =="
"$bin" mac-code --duration $((duration + 6)) --at "${MAC_CODE_AT:-1200,300}" --size 420,260 > "$run/mac/mac-code.log" 2>&1 &
pids+=($!)
sleep 2
"$bin" capture --run-dir "$run/mac" --window "Tombolo Mac reference code" --duration "$duration" | tee "$run/mac/capture.log"

echo
echo "self-test results in $run/{page,mac}/summary.txt"
