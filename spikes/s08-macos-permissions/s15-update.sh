#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# S15: install a probe version at a fixed path, or replace it in place the way an
# updater does (delete + copy), then launch it and record its grant status.
#
# usage: s15-update.sh <selfsigned|adhoc> <1.0.0|1.0.1> <label> [steps]
#   default steps: "info;login-status;ax;sleep:3"
#
# The installed copy lives at build/s15/installed/<variant>/ (gitignored). Results go to
# results/<label>/ via run-probe.sh. Example (maintainer checklist):
#   ./s15-update.sh selfsigned 1.0.0 m3-ax-selfsigned-1.0.0 "info;ax-prompt;sleep:60"
#   ./s15-update.sh selfsigned 1.0.1 m3-ax-selfsigned-1.0.1

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
variant="$1"; version="$2"; label="$3"; steps="${4:-info;login-status;ax;sleep:3}"
case "$variant" in
  selfsigned) name="S15 Probe.app" ;;
  adhoc) name="S15 AdHoc Probe.app" ;;
  *) echo "variant must be selfsigned or adhoc" >&2; exit 2 ;;
esac
src="$here/build/s15/$variant-$version/$name"
dst_dir="$here/build/s15/installed/$variant"
dst="$dst_dir/$name"
[[ -d "$src" ]] || { echo "missing $src - run ./build.sh s15" >&2; exit 1; }

pkill -f "$dst/Contents/MacOS/TomboloProbe" 2>/dev/null || true
mkdir -p "$dst_dir"
rm -rf "$dst"
cp -R "$src" "$dst"
echo "installed $variant $version at $dst"
codesign -d -r- "$dst" 2>&1 | sed -n -E 's/^#? ?designated => /  DR: /p'
"$here/run-probe.sh" "$dst" "$label" "$steps" "${WATCH:-10}"
