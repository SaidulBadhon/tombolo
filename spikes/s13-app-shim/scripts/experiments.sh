#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Spike S13 experiments. Raw output goes to results/<name>.txt (+ .json stats, .png window captures).
#   scripts/experiments.sh measure|restart|coldstart|update|integration|security|quarantine|all
# Needs a logged-in GUI session (Aqua). Opens real windows for a few seconds at a time.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
HOST_APP="$ROOT/out/Tombolo Host.app"
HOST_EXE="$HOST_APP/Contents/MacOS/TomboloHost"
SHIMS_DIR="$HOME/Applications/Tombolo Apps"
STATE="$HOME/Library/Application Support/Tombolo-spike-s13"
LOGS="$STATE/logs"
RES="$ROOT/results"
CHAT_ID=io.github.saidulbadhon.Tombolo.shim.com.example.chat
MAPS_ID=io.github.saidulbadhon.Tombolo.shim.org.example.maps
SVC=io.github.saidulbadhon.Tombolo.spike-s13.ipc
HF="$LOGS/host.log"; CF="$LOGS/shim-com.example.chat.log"; MF="$LOGS/shim-org.example.maps.log"
mkdir -p "$RES" "$LOGS"; touch "$HF" "$CF" "$MF"

now_ms() { python3 -c 'import time;print("%.3f"%(time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)/1e6))'; }
host_pid() { pgrep -f "Tombolo Host.app/Contents/MacOS/TomboloHost" | head -1; }
shim_pid() { pgrep -f "Tombolo Apps/$1.app/Contents/MacOS/TomboloShim" | head -1; }
shim_pids() { pgrep -f "Tombolo Apps/.*/TomboloShim"; }
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
# wait_log FILE FROM_LINE REGEX TIMEOUT_S — print the first matching line written after FROM_LINE.
wait_log() {
  local f=$1 from=$2 re=$3 t=${4:-10} i=0 m
  while [ $i -lt $((t * 10)) ]; do
    m=$(tail -n +$((from + 1)) "$f" 2>/dev/null | grep -m1 -E "$re") && { echo "$m" | cut -c1-300; return 0; }
    sleep 0.1; i=$((i + 1))
  done
  echo "TIMEOUT waiting for /$re/ in $(basename "$f")"; return 1
}
t_of() { echo "$1" | awk '{print $1}'; }                 # uptime-ms prefix of a log line
dt() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f ms", b-a}'; }
stop_all() {
  local p; p=$(host_pid); [ -n "$p" ] && kill -TERM "$p" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -z "$(host_pid)" ] && break; sleep 0.2; done
  pkill -TERM -f "Tombolo Apps/.*/TomboloShim" 2>/dev/null; sleep 0.5
  pkill -KILL -f "Tombolo Apps/.*/TomboloShim" 2>/dev/null; pkill -KILL -f "Tombolo Host.app/Contents/MacOS/TomboloHost" 2>/dev/null
  true
}
start_host() { open -g "$HOST_APP" --args "$@"; }
cpu_s() { ps -o time= -p "$1" 2>/dev/null | awk -F: '{ if (NF==3) print $1*3600+$2*60+$3; else print $1*60+$2 }'; }
winid() { "$ROOT/out/winlist" "$1" | grep -m1 'layer=0 ' | sed -E 's/^window ([0-9]+).*/\1/'; }
capture() { # capture PID NAME — window screenshot (needs Screen Recording for the calling terminal; checked first)
  local id; id=$(winid "$1"); [ -n "$id" ] || { echo "no window for pid $1"; return; }
  screencapture -x -o -l"$id" "/tmp/s13-$2.png" && sips -Z 360 "/tmp/s13-$2.png" --out "$RES/$2.png" >/dev/null && echo "captured window $id → results/$2.png"
}

# ---------------------------------------------------------------------------------------------------------
measure_one() { # LABEL DURATION host-args...
  local label=$1 dur=$2; shift 2
  stop_all
  local out="$RES/$label.txt"
  { echo "## $label: host args: $*  duration=${dur}s"; echo "uptime: $(uptime)"
    echo "top CPU before run (2nd sample):"; top -l 2 -n 6 -o cpu -stats pid,command,cpu | tail -6
    local ws0 w1 w2 a b; ws0=$(pgrep -x WindowServer); w1=$(cpu_s "$ws0"); a=$(now_ms); sleep 5; w2=$(cpu_s "$ws0"); b=$(now_ms)
    awk -v c1="$w1" -v c2="$w2" -v a="$a" -v b="$b" 'BEGIN{printf "WindowServer baseline (nothing of ours running, 5 s): %.1f %%\n", (c2-c1)/((b-a)/1000)*100}'
  } > "$out"
  start_host --duration "$dur" --stats "$RES/$label.json" "$@"
  sleep 6 # launch (~1 s) + 2 s warm-up; CPU sampling window starts after
  local hp sp ws; hp=$(host_pid); sp=$(shim_pids | tr '\n' ' '); ws=$(pgrep -x WindowServer)
  local s1 s2 t1 t2
  s1=$(for p in $hp $sp $ws; do echo "$p $(cpu_s "$p")"; done); t1=$(now_ms)
  sleep $((dur - 9))
  s2=$(for p in $hp $sp $ws; do echo "$p $(cpu_s "$p")"; done); t2=$(now_ms)
  echo "CPU over $(dt "$t1" "$t2") (100% = one core):" >> "$out"
  while read -r p c1; do
    local c2; c2=$(echo "$s2" | awk -v p="$p" '$1==p{print $2}')
    echo "$p $(ps -o comm= -p "$p" | sed 's#.*/##') $c1 $c2" | awk -v w="$(awk -v a="$t1" -v b="$t2" 'BEGIN{print (b-a)/1000}')" \
      '{printf "  pid %-6s %-22s %6.1f %%\n", $1, $2, ($4-$3)/w*100}' >> "$out"
  done <<< "$s1"
  for _ in $(seq 1 60); do [ -z "$(host_pid)" ] && break; sleep 0.5; done
  stop_all
  python3 - "$RES/$label.json" >> "$out" <<'EOF'
import json, sys
for s in json.load(open(sys.argv[1])):
    r, c, a = s["recvMs"], s["commitMs"], s["ackRoundTripMs"]
    print(f'  {s["package"]:<20} {s["mode"]:<9} {s["width"]}x{s["height"]}@{s["fpsTarget"]} achieved {s["achievedFps"]:.1f} fps '
          f'sent {s["framesSent"]} acked {s["framesAcked"]} skipped-at-source {s["droppedNoFreeSlot"]} sendErr {s["sendErrors"]}')
    print(f'      host→shim receive  p50 {r["p50"]:.3f}  p95 {r["p95"]:.3f}  p99 {r["p99"]:.3f}  max {r["max"]:.3f} ms (n={r["count"]})')
    print(f'      host→layer commit  p50 {c["p50"]:.3f}  p95 {c["p95"]:.3f}  p99 {c["p99"]:.3f}  max {c["max"]:.3f} ms')
    print(f'      ack round trip     p50 {a["p50"]:.3f}  p95 {a["p95"]:.3f}  p99 {a["p99"]:.3f}  max {a["max"]:.3f} ms')
EOF
  cat "$out"
}

measure() {
  measure_one m1-ring-2x60-720x1560 20 --mode ring
  measure_one m2-perframe-2x60-720x1560 20 --mode perframe
  measure_one m3-ring-1x60-1080x2400 20 --mode ring --size 1080x2400 --apps "com.example.chat:Chat"
  measure_one m4-ring-4x60-720x1560 20 --mode ring \
    --apps "com.example.chat:Chat,org.example.maps:Maps,com.example.music:Music,com.example.notes:Notes"
}

# ---------------------------------------------------------------------------------------------------------
restart() {
  stop_all
  local out="$RES/restart.txt" c m h tk tl l
  : > "$out"
  note() { echo "$*" | tee -a "$out"; }
  c=$(lines "$CF"); m=$(lines "$MF")
  start_host
  note "start: $(wait_log "$CF" "$c" 'connected: session' 20)"
  note "start: $(wait_log "$MF" "$m" 'connected: session' 20)"
  sleep 2
  note "$(capture "$(shim_pid Chat)" chat-connected-1)"; sleep 0.5; note "$(capture "$(shim_pid Chat)" chat-connected-2)"

  note "--- A. graceful host quit (SIGTERM), then relaunch"
  c=$(lines "$CF"); m=$(lines "$MF"); tk=$(now_ms); kill -TERM "$(host_pid)"
  l=$(wait_log "$CF" "$c" 'disconnected' 5); note "chat: $l  [+$(dt "$tk" "$(t_of "$l")") after SIGTERM]"
  l=$(wait_log "$MF" "$m" 'disconnected' 5); note "maps: $l  [+$(dt "$tk" "$(t_of "$l")")]"
  sleep 1; note "$(capture "$(shim_pid Chat)" chat-disconnected)"
  note "shims still running: chat=$(shim_pid Chat) maps=$(shim_pid Maps); host=$(host_pid)"
  c=$(lines "$CF"); m=$(lines "$MF"); h=$(lines "$HF"); tl=$(now_ms); start_host
  local claim; claim=$(wait_log "$HF" "$h" 'claimed dynamic bootstrap name' 10); note "host: $claim [+$(dt "$tl" "$(t_of "$claim")") after open]"
  l=$(wait_log "$CF" "$c" 'connected: session' 10); note "chat: $l  [+$(dt "$(t_of "$claim")" "$(t_of "$l")") after host claimed name]"
  l=$(wait_log "$MF" "$m" 'connected: session' 10); note "maps: $l  [+$(dt "$(t_of "$claim")" "$(t_of "$l")")]"
  sleep 2

  note "--- B. host crash (SIGKILL), then relaunch"
  c=$(lines "$CF"); m=$(lines "$MF"); tk=$(now_ms); kill -KILL "$(host_pid)"
  l=$(wait_log "$CF" "$c" 'disconnected' 5); note "chat: $l  [+$(dt "$tk" "$(t_of "$l")") after SIGKILL]"
  l=$(wait_log "$MF" "$m" 'disconnected' 5); note "maps: $l  [+$(dt "$tk" "$(t_of "$l")")]"
  note "launchd name after crash: $(launchctl print gui/$(id -u) | grep -c "$SVC") entries (0 = removed with the receive right)"
  c=$(lines "$CF"); m=$(lines "$MF"); h=$(lines "$HF"); tl=$(now_ms); start_host
  claim=$(wait_log "$HF" "$h" 'claimed dynamic bootstrap name' 10); note "host: $claim [+$(dt "$tl" "$(t_of "$claim")") after open]"
  l=$(wait_log "$CF" "$c" 'connected: session' 10); note "chat: $l  [+$(dt "$(t_of "$claim")" "$(t_of "$l")") after host claimed name]"
  l=$(wait_log "$MF" "$m" 'connected: session' 10); note "maps: $l  [+$(dt "$(t_of "$claim")" "$(t_of "$l")")]"
  sleep 2

  note "--- C. shim crash (SIGKILL Chat), host notices; relaunch Chat via LaunchServices (like a Dock click)"
  m=$(lines "$MF"); h=$(lines "$HF"); tk=$(now_ms); kill -KILL "$(shim_pid Chat)"
  l=$(wait_log "$HF" "$h" 'shim process died' 5); note "host: $l  [+$(dt "$tk" "$(t_of "$l")") after SIGKILL]"
  c=$(lines "$CF"); tl=$(now_ms); open -g -b "$CHAT_ID"
  l=$(wait_log "$CF" "$c" 'connected: session' 15); note "chat: $l  [+$(dt "$tl" "$(t_of "$l")") after open -b]"
  note "maps unaffected: $(tail -n +$((m + 1)) "$MF" | grep -c disconnected) disconnects logged by Maps during step C"
  note "--- D. two hosts: second instance cannot claim the name"
  h=$(lines "$HF"); "$HOST_EXE" --no-launch --duration 5 >/dev/null 2>&1; note "second host exit code $? ; $(wait_log "$HF" "$h" 'could not claim|bootstrap_check_in' 2)"
  stop_all
}

# ---------------------------------------------------------------------------------------------------------
coldstart() {
  stop_all
  local out="$RES/coldstart.txt" c h tl l
  : > "$out"
  note() { echo "$*" | tee -a "$out"; }
  note "host running: '$(host_pid)' (empty = no); name registered: $(launchctl print gui/$(id -u) | grep -c "$SVC")"
  c=$(lines "$CF"); h=$(lines "$HF"); tl=$(now_ms); open -g -b "$CHAT_ID"
  l=$(wait_log "$CF" "$c" 'host not running; launching' 10); note "chat: $l  [+$(dt "$tl" "$(t_of "$l")") after open -b]"
  l=$(wait_log "$HF" "$h" 'starting' 10); note "host: $l"
  l=$(wait_log "$CF" "$c" 'connected: session' 20); note "chat: $l  [+$(dt "$tl" "$(t_of "$l")") after open -b]"
  sleep 1
  note "maps launched too? pid='$(shim_pid Maps)' (expected empty: a shim-started host launches nothing else)"
  stop_all
}

# ---------------------------------------------------------------------------------------------------------
update() {
  stop_all
  local out="$RES/update.txt" c m h l
  : > "$out"
  note() { echo "$*" | tee -a "$out"; }
  note "=== build v1"; ./scripts/build.sh 1 2>&1 | grep -E '^(built|CDHash)' | tee -a "$out"
  "$HOST_EXE" --generate-only >/dev/null 2>&1 # make sure shims are at v1
  for a in Chat Maps; do note "$a.app v$(defaults read "$SHIMS_DIR/$a.app/Contents/Info" CFBundleVersion) $(codesign -dvvv "$SHIMS_DIR/$a.app" 2>&1 | grep CDHash=)"; done
  c=$(lines "$CF"); m=$(lines "$MF"); start_host
  note "$(wait_log "$CF" "$c" 'connected: session' 20)"; note "$(wait_log "$MF" "$m" 'connected: session' 20)"
  sleep 2
  note "=== quit host v1 (an updater quits the app before replacing it)"
  c=$(lines "$CF"); kill -TERM "$(host_pid)"; note "$(wait_log "$CF" "$c" 'disconnected' 5)"
  note "=== build v2 in place (new Info.plist version → new ad-hoc cdhash)"; ./scripts/build.sh 2 2>&1 | grep -E '^(built|CDHash)' | tee -a "$out"
  c=$(lines "$CF"); m=$(lines "$MF"); h=$(lines "$HF"); start_host
  note "$(wait_log "$HF" "$h" 'host v2 starting' 10)"
  note "$(wait_log "$CF" "$c" 'restart for an update' 15)"
  note "$(wait_log "$HF" "$h" 'com.example.chat: old shim pid' 15)"
  note "$(wait_log "$HF" "$h" 'generated .*Chat.app' 15)"
  note "$(wait_log "$CF" "$c" 'shim v2-[0-9a-f]+ starting' 15)"
  note "$(wait_log "$CF" "$c" 'connected: session.*host v2' 15)"
  note "$(wait_log "$MF" "$m" 'connected: session.*host v2' 20)"
  sleep 1
  for a in Chat Maps; do note "$a.app now v$(defaults read "$SHIMS_DIR/$a.app/Contents/Info" CFBundleVersion) $(codesign -dvvv "$SHIMS_DIR/$a.app" 2>&1 | grep CDHash=) quarantine=$(xattr -p com.apple.quarantine "$SHIMS_DIR/$a.app" 2>/dev/null || echo none)"; done
  note "LaunchServices sees: $(lsappinfo info "$CHAT_ID" 2>&1 | grep -E "bundle path|Version" | tr -s " \n" " ")"
  note "=== v3 host with --no-update-shims: v2 shims keep working against a newer host (protocol compatibility)"
  c=$(lines "$CF"); kill -TERM "$(host_pid)"; wait_log "$CF" "$c" 'disconnected' 5 >/dev/null
  ./scripts/build.sh 3 2>&1 | grep -E '^(built|CDHash)' | tee -a "$out"
  c=$(lines "$CF"); start_host --no-update-shims
  note "$(wait_log "$CF" "$c" 'connected: session.*host v3' 15)"
  stop_all
  note "=== restore v1 build"; ./scripts/build.sh 1 2>&1 | grep -E '^(built|CDHash)' | tee -a "$out"
}

# ---------------------------------------------------------------------------------------------------------
integration() {
  stop_all
  local out="$RES/integration.txt" NID=io.github.saidulbadhon.Tombolo.shim.com.example.spotlight NAME="S13 Spotlight Test" t0 found md c m
  : > "$out"
  note() { echo "$*" | tee -a "$out"; }
  note "=== Spotlight: brand-new shim (package never generated before), no mdimport"
  note "mdutil: $(mdutil -s / 2>&1 | tr '\n' ' ')"
  note "before: mdfind '$(mdfind "kMDItemCFBundleIdentifier == '$NID'")'"
  t0=$(now_ms); open -g -W "$HOST_APP" --args --generate-only --apps "com.example.spotlight:$NAME"
  note "generated at +$(dt "$t0" "$(now_ms)")"
  found=""; md=""
  for i in $(seq 1 120); do
    [ -z "$found" ] && found=$(mdfind "kMDItemCFBundleIdentifier == '$NID'") && [ -n "$found" ] && note "mdfind by bundle ID found '$found' at +$(dt "$t0" "$(now_ms)") (no mdimport)"
    [ -z "$md" ] && md=$(mdls -raw -name kMDItemCFBundleIdentifier "$SHIMS_DIR/$NAME.app" 2>/dev/null | grep -v '(null)') && [ -n "$md" ] && note "mdls has kMDItemCFBundleIdentifier=$md at +$(dt "$t0" "$(now_ms)")"
    [ -n "$found" ] && [ -n "$md" ] && break; sleep 0.5
  done
  [ -z "$found" ] && note "NOT indexed by bundle ID within 60 s without mdimport"
  mdimport "$SHIMS_DIR/$NAME.app" 2>&1 | head -2 | tee -a "$out"
  note "after mdimport: mdfind '$(mdfind "kMDItemCFBundleIdentifier == '$NID'")'"
  note "by display name (what the Spotlight UI matches): '$(mdfind 'kMDItemDisplayName == "S13 Spotlight*"cd')'"
  note "Chat by bundle ID: '$(mdfind "kMDItemCFBundleIdentifier == '$CHAT_ID'")'"
  mdls -name kMDItemCFBundleIdentifier -name kMDItemContentType -name kMDItemDisplayName -name kMDItemVersion -name kMDItemKind "$SHIMS_DIR/$NAME.app" | tee -a "$out"

  note "=== running shims: Dock / ⌘-Tab class (lsappinfo), windows (CGWindowList)"
  c=$(lines "$CF"); m=$(lines "$MF"); start_host
  wait_log "$CF" "$c" 'connected: session' 20 >/dev/null; wait_log "$MF" "$m" 'connected: session' 20 >/dev/null
  sleep 1
  for id in "$CHAT_ID" "$MAPS_ID" io.github.saidulbadhon.Tombolo.spike-s13.host; do
    lsappinfo info "$id" 2>&1 | tee -a "$out"
  done
  note "lsappinfo list entries for shims:"; lsappinfo list | grep -E 'shim\.(com|org)\.example' -A3 | tee -a "$out"
  "$ROOT/out/winlist" "$(shim_pid Chat)" "$(shim_pid Maps)" "$(host_pid)" | tee -a "$out"
  note "(onscreen=0 = the window is on another Space, e.g. while the user is in a full-screen app)"
  note "$(capture "$(shim_pid Maps)" maps-connected)"
  note "=== Gatekeeper / quarantine / signature"
  for a in Chat Maps "S13 Spotlight Test"; do
    note "-- $a.app"; xattr -l "$SHIMS_DIR/$a.app" "$SHIMS_DIR/$a.app/Contents/MacOS/TomboloShim" 2>&1 | tee -a "$out"
    codesign --verify --strict --deep -v "$SHIMS_DIR/$a.app" 2>&1 | tee -a "$out"
    codesign -dvvv "$SHIMS_DIR/$a.app" 2>&1 | grep -E '^(Identifier|CodeDirectory|CDHash|Signature|TeamIdentifier|Runtime)' | tee -a "$out"
    spctl -a -vv -t exec "$SHIMS_DIR/$a.app" 2>&1 | tee -a "$out"
  done
  note "Dock pinned items mentioning Tombolo Apps (read-only): $(defaults read com.apple.dock persistent-apps 2>/dev/null | grep -c 'Tombolo%20Apps')"
  stop_all
  lsregister=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
  "$lsregister" -u "$SHIMS_DIR/S13 Spotlight Test.app" 2>/dev/null; rm -rf "$SHIMS_DIR/S13 Spotlight Test.app"
}

# ---------------------------------------------------------------------------------------------------------
security() {
  stop_all
  local out="$RES/security.txt" c h l E=/tmp/s13-evil
  : > "$out"
  note() { echo "$*" | tee -a "$out"; }
  c=$(lines "$CF"); start_host --apps "com.example.chat:Chat"; wait_log "$CF" "$c" 'connected: session' 20 >/dev/null
  note "=== 1. bare template binary (same code, not the generated bundle) claims to be com.example.chat"
  h=$(lines "$HF"); "$HOST_APP/Contents/Helpers/tombolo-shim" --package com.example.chat --exit-after 4 --no-launch-host >/dev/null 2>&1
  note "impostor exit code $? (4 = rejected)"; note "$(wait_log "$HF" "$h" 'REJECT' 3)"
  note "=== 2. copy of Chat.app, Info.plist edited, re-signed ad-hoc with the SAME identifier"
  rm -rf "$E"; mkdir -p "$E"; ditto "$SHIMS_DIR/Chat.app" "$E/Chat.app"
  plutil -insert Evil -string yes "$E/Chat.app/Contents/Info.plist"
  codesign --force -s - -i "$CHAT_ID" "$E/Chat.app" 2>&1 | tee -a "$out"
  note "evil $(codesign -dvvv "$E/Chat.app" 2>&1 | grep -E '^(Identifier|CDHash)' | tr '\n' ' ')"
  h=$(lines "$HF"); "$E/Chat.app/Contents/MacOS/TomboloShim" --exit-after 4 --no-launch-host >/dev/null 2>&1
  note "tampered copy exit code $? (4 = rejected)"; note "$(wait_log "$HF" "$h" 'REJECT' 3)"
  note "=== 3. name squatting while the host is down (any same-user process can claim the name)"
  c=$(lines "$CF"); kill -TERM "$(host_pid)"; wait_log "$CF" "$c" 'disconnected' 5 >/dev/null
  "$ROOT/out/probe_ipc" bs-squat "$SVC" > /tmp/s13-squat.log 2>&1 &
  local sq=$!; sleep 3; kill "$sq" 2>/dev/null; wait "$sq" 2>/dev/null
  note "squatter: $(tr '\n' ' ' < /tmp/s13-squat.log)"
  note "(bs-squat: receive = 0 with msgh_id=1000 means the waiting shim's hello reached the squatter, reply_right=yes means it also holds a send right to the shim's port. results/security.txt from 2026-10-26 used bs-checkin, whose small buffer got 0x10004004 MACH_RCV_TOO_LARGE: a message arrived and was discarded.)"
  stop_all; rm -rf "$E" /tmp/s13-squat.log
}

# ---------------------------------------------------------------------------------------------------------
quarantine() {
  stop_all
  local out="$RES/quarantine.txt" Q=/tmp/s13-quarantine T
  : > "$out"
  note() { echo "$*" | tee -a "$out"; }
  rm -rf "$Q"; mkdir -p "$Q"; ditto "$HOST_APP" "$Q/Tombolo Host.app"
  T="$Q/Tombolo Host.app/Contents/Helpers/tombolo-shim"
  xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;" "$T"
  note "template inside a 'downloaded' host: $(xattr -l "$T" | tr '\n' ' ')"
  cp "$T" "$Q/cp-copy"; note "plain cp of the template keeps it: $(xattr -l "$Q/cp-copy" | tr '\n' ' ')"
  "$Q/Tombolo Host.app/Contents/MacOS/TomboloHost" --generate-only --apps "com.example.qtest:S13 QTest" >/dev/null 2>&1
  note "generated shim (bytes copied, not the file):"
  xattr -l "$SHIMS_DIR/S13 QTest.app" "$SHIMS_DIR/S13 QTest.app/Contents/MacOS/TomboloShim" 2>&1 | tee -a "$out"
  note "quarantine on generated shim: $(xattr -p com.apple.quarantine "$SHIMS_DIR/S13 QTest.app/Contents/MacOS/TomboloShim" 2>&1)"
  lsregister=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
  "$lsregister" -u "$SHIMS_DIR/S13 QTest.app" 2>/dev/null; rm -rf "$SHIMS_DIR/S13 QTest.app" "$Q"
}

tcc_and_policy_logs() { # since START (date string)
  local out="$RES/tcc-gatekeeper-logs.txt"
  { echo "log show --start '$1' (TCC + syspolicyd), lines mentioning our bundle IDs / paths:"
    log show --start "$1" --style compact --predicate 'subsystem == "com.apple.TCC" OR process == "tccd" OR process == "syspolicyd"' 2>/dev/null \
      | grep -i -E 'shim\.(com|org)\.example|spike-s13|spike\.s13|Tombolo Apps|TomboloShim|TomboloHost|s13-app-shim' | cut -c1-260 | head -60
    echo "(end; empty = no TCC request and no Gatekeeper assessment logged for our code)"; } | tee "$out"
}

case "${1:-}" in
  measure|restart|coldstart|update|integration|security|quarantine) "$1" ;;
  all)
    START="$(date '+%Y-%m-%d %H:%M:%S')"
    measure; restart; coldstart; integration; security; quarantine; update
    tcc_and_policy_logs "$START" ;;
  logs) tcc_and_policy_logs "${2:?start time}" ;;
  *) echo "usage: $0 measure|restart|coldstart|update|integration|security|quarantine|all|logs START"; exit 2 ;;
esac
