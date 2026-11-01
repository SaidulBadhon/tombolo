#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Spike S2 (P0-15): ROUNDS × each presenter, interleaved, DURATION s each (scripts/measure.sh), then the phone is
# sent Home so the latency page releases its screen wake lock. Usage: scripts/measure-all.sh [ROUNDS=3] [DURATION=60]
#   PRESENTERS="metal sbdl metal-immediate" (default) · RUN_ROOT (default runs/)
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROUNDS="${1:-3}"; DURATION="${2:-60}"
PRESENTERS="${PRESENTERS:-metal sbdl metal-immediate}"
RUN_ROOT="${RUN_ROOT:-$HERE/runs}"
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
for r in $(seq "$ROUNDS"); do
    for p in $PRESENTERS; do
        echo "=== round $r/$ROUNDS: $p ===" >&2
        "$HERE/scripts/measure.sh" "$p" "$DURATION" "$RUN_ROOT" || echo "measure-all: run $p (round $r) failed with status $?" >&2
    done
done
"$ADB" ${SERIAL:+-s "$SERIAL"} shell input keyevent KEYCODE_HOME || true
