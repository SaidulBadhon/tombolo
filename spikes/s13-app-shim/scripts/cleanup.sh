#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Remove everything spike S13 created outside the repository, then verify it is gone.
#   scripts/cleanup.sh            (logs are archived to out/logs-<timestamp>/ first; out/ is git-ignored)
# Recreate afterwards with: scripts/build.sh && open "out/Tombolo Host.app"  (or scripts/experiments.sh all)
set -uo pipefail
cd "$(dirname "$0")/.."
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
SHIMS_DIR="$HOME/Applications/Tombolo Apps"
STATE="$HOME/Library/Application Support/Tombolo-spike-s13"
PATTERN='io\.github\.saidulbadhon\.Tombolo\.(shim\.|spike-s13)'
fail=0

echo "1. stop processes"
pkill -TERM -f "Tombolo Host.app/Contents/MacOS/TomboloHost" 2>/dev/null; sleep 1
pkill -TERM -f "/TomboloShim" 2>/dev/null; sleep 1
pkill -KILL -f "Tombolo Host.app/Contents/MacOS/TomboloHost" 2>/dev/null; pkill -KILL -f "/TomboloShim" 2>/dev/null
pkill -KILL -f "out/probe_ipc|s13probe/probe_ipc" 2>/dev/null

echo "2. launchd: the spike registers no jobs; remove the probe agent if a probe run was interrupted"
launchctl bootout "gui/$(id -u)/io.github.saidulbadhon.Tombolo.spike-s13.probe3agent" 2>/dev/null && echo "   booted out probe3agent"

echo "3. LaunchServices: unregister every shim / host path it knows about, then delete the shims"
paths=$("$LSREG" -dump 2>/dev/null | awk -v pat="$PATTERN" '
  /^path:/ { sub(/^path: +/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); p = $0 }
  /^identifier:/ && $0 ~ pat { print p }' | sort -u)
echo "$paths" | while IFS= read -r p; do [ -n "$p" ] && "$LSREG" -u "$p" 2>/dev/null && echo "   unregistered $p"; done
for b in "$SHIMS_DIR"/*.app "$SHIMS_DIR"/.*.app; do
  [ -d "$b" ] || continue
  if [ "$(defaults read "$b/Contents/Info" TomboloSpike 2>/dev/null)" = s13 ]; then
    "$LSREG" -u "$b" 2>/dev/null; rm -rf "$b"; echo "   removed $b"
  else
    echo "   KEPT (not created by this spike): $b"
  fi
done
rmdir "$SHIMS_DIR" 2>/dev/null && echo "   removed $SHIMS_DIR"

echo "4. state + logs"
if [ -d "$STATE" ]; then
  arch="out/logs-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$arch"; cp -R "$STATE/" "$arch/" && echo "   archived logs to $arch"
  rm -rf "$STATE" && echo "   removed $STATE"
fi
rm -rf /tmp/s13probe /tmp/s13-*.png /tmp/s13-evil /tmp/s13-quarantine /tmp/s13-squat.log

echo "5. verify"
[ -e "$SHIMS_DIR" ] && { echo "   FAIL: $SHIMS_DIR still exists"; fail=1; } || echo "   ok: no $SHIMS_DIR"
[ -e "$STATE" ] && { echo "   FAIL: $STATE still exists"; fail=1; } || echo "   ok: no state dir"
n=$(pgrep -f "TomboloHost|/TomboloShim" | wc -l | tr -d ' '); [ "$n" = 0 ] && echo "   ok: no processes" || { echo "   FAIL: $n processes"; fail=1; }
n=$(launchctl print "gui/$(id -u)" 2>/dev/null | grep -c 'spike-s13'); [ "$n" = 0 ] && echo "   ok: no launchd services/jobs" || { echo "   FAIL: $n launchd entries"; fail=1; }
n=$("$LSREG" -dump 2>/dev/null | grep -E -c "identifier: +$PATTERN"); [ "$n" = 0 ] && echo "   ok: LaunchServices has no shim/host records" || { echo "   FAIL: $n LaunchServices records"; fail=1; }
for i in $(seq 1 30); do
  n=$(mdfind "kMDItemCFBundleIdentifier == 'io.github.saidulbadhon.Tombolo.*'" | wc -l | tr -d ' ')
  [ "$n" = 0 ] && break; sleep 1
done
[ "$n" = 0 ] && echo "   ok: Spotlight returns nothing for io.github.saidulbadhon.Tombolo.*" || { echo "   FAIL: Spotlight still lists $n items"; fail=1; }
exit $fail
