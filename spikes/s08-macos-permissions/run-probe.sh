#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Launch a probe bundle through LaunchServices, run a step script, and record:
#   results/<label>/probe.log     the probe's own log
#   results/<label>/windows.log   windows that appeared (the Local Network alert shows up here)
#   results/<label>/window-<id>.png  screenshot of each new system-alert window (that window only)
#   results/<label>/system.log    unified-log lines from the processes involved (raw, gitignored)
#   results/<label>/system-excerpt.log  the lines of system.log about the probe / Local Network
#   results/<label>/launch.log    `open` output and process status
#
# usage: run-probe.sh <app> <label> <steps> [watch-seconds] [--keep]
#   steps          ";"-separated probe steps, e.g. "listen:52011;sleep:20"
#   watch-seconds  how long to watch for windows / keep logging (default 20)
#   --keep         leave the probe running afterwards (default: quit it)
#
# A probe launched this way is its own responsible process for Local Network
# privacy. It never clicks anything: alerts are left for a human.

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
label="$2"; steps="$3"; watch="${4:-20}"; keep="${5:-}"
dir="$here/results/$label"
mkdir -p "$dir"
# The probe writes its log outside ~/Documents (this repo may live there): writing
# into ~/Documents from the probe triggers a TCC "Documents folder" prompt.
plog="$HOME/Library/Logs/TomboloSpikeS08/$label/probe.log"
mkdir -p "$(dirname "$plog")"
: >"$plog"
exe="$app/Contents/MacOS/TomboloProbe"

"$here/build/windows" --baseline "$dir/.windows-baseline"
/usr/bin/log stream --style compact --info \
  --predicate 'process IN {"nehelper","UserNotificationCenter","TomboloProbe","mDNSResponder","kernel","tccd","runningboardd","launchd","amfid","syspolicyd","CoreServicesUIAgent","backgroundtaskmanagementd","smd"}' \
  >"$dir/system.log" 2>&1 &
logpid=$!
sleep 1

{
  echo "launch: $(date '+%F %T') open -n -g \"$app\" --args --run \"$steps\""
  set +e
  /usr/bin/open -n -g "$app" --args --run "$steps" --log "$plog" 2>&1
  echo "open exit: $?"
  set -e
} | tee "$dir/launch.log"

: >"$dir/.windows-raw"
for ((i = 1; i <= watch; i++)); do
  sleep 1
  d="$("$here/build/windows" --diff "$dir/.windows-baseline")"
  if [[ "$d" != "no new windows" ]]; then
    printf 't+%02ds %s\n' "$i" "$d" | sed '2,$s/^/       /' >>"$dir/.windows-raw"
    # Screenshot only the new system-alert window itself (never the screen), once per window.
    for wid in $(grep -o ' id=[0-9]*' <<<"$d" | cut -d= -f2); do
      [[ -e "$dir/window-$wid.png" ]] || /usr/sbin/screencapture -x -o -l "$wid" "$dir/window-$wid.png" 2>/dev/null || true
    done
  fi
done
[[ -s "$dir/.windows-raw" ]] || echo "no new windows during ${watch}s" >"$dir/.windows-raw"

pids="$(pgrep -f "$exe" || true)"
echo "probe pids after ${watch}s: ${pids:-none}" | tee -a "$dir/launch.log"
if [[ -n "$pids" && "$keep" != "--keep" ]]; then
  kill $pids 2>/dev/null || true
  sleep 2
  d="$("$here/build/windows" --diff "$dir/.windows-baseline")"
  echo "alert windows 2 s after quitting the probe: $(grep -E ' id=' <<<"$d" || echo none)" | tee -a "$dir/launch.log"
fi
kill "$logpid" 2>/dev/null || true
wait "$logpid" 2>/dev/null || true

# Committable excerpt: only lines about the probe or Local Network privacy.
"$here/excerpt.sh" "$dir/system.log" >"$dir/system-excerpt.log"
# Committable window log: only system-alert/probe windows (those carry an id=).
grep -E ' id=|no new windows' "$dir/.windows-raw" >"$dir/windows.log" || echo "no new alert windows during ${watch}s" >"$dir/windows.log"

cp "$plog" "$dir/probe.log"

echo "--- windows"; cat "$dir/windows.log"
echo "--- probe log"; cat "$dir/probe.log"
