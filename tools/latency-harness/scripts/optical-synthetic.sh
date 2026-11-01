#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# End-to-end check of the optical pipeline without a camera: render a synthetic 240 fps clip
# (phone symbol, mirror symbol delayed by a known latency, Mac reference symbol; blur, noise,
# pixel-response blending), encode it with H.264 through ffmpeg, then run `latency-harness optical`
# on the MP4 and compare the recovered latency with the injected one (± one camera frame).
#
# usage: scripts/optical-synthetic.sh [OUT_DIR] [LATENCY_MS=45] [SECONDS=3]
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$here/runs/optical-synthetic}"
latency="${2:-45}"
seconds="${3:-3}"
mkdir -p "$out"
cd "$here"
swift build -c release >/dev/null
bin="$here/.build/release/latency-harness"

"$bin" synth-video --seconds "$seconds" --fps 240 --latency-ms "$latency" --width 640 --height 360 |
  ffmpeg -v error -y -f rawvideo -pix_fmt gray -s 640x360 -r 240 -i - \
    -c:v libx264 -preset veryfast -crf 26 -pix_fmt yuv420p "$out/synthetic.mp4"
echo "encoded $out/synthetic.mp4 (injected latency $latency ms)"

"$bin" optical --video "$out/synthetic.mp4" --out "$out/analysis" | tee "$out/analysis.log"

python3 - "$out/analysis/summary.json" "$latency" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); want = float(sys.argv[2])
lat = s.get("latencyMs") or {}
frame = 1000.0 / s["fpsUsed"]
p50 = float(lat.get("p50", "nan"))
ok = abs(p50 - want) <= frame + 0.01 and s["samplesUsed"] >= 50
print("check: p50 %.2f ms vs injected %.2f ms (tolerance ±%.2f ms), used samples %d -> %s"
      % (p50, want, frame, s["samplesUsed"], "PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
PY
