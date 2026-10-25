#!/bin/bash
# Renders each mockup HTML file to a 2x JPEG in img/ with headless Chrome.
# Usage: ./render.sh [file.html ...]   (defaults to all mac-*.html and android-*.html)
set -euo pipefail
cd "$(dirname "$0")"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p img
files=("$@")
[ ${#files[@]} -eq 0 ] && files=(mac-*.html android-*.html)
for f in "${files[@]}"; do
  case "$f" in
    android-*) size="1440,1000" ;;
    *) size="1440,900" ;;
  esac
  png="$tmp/${f%.html}.png"
  out="img/${f%.html}.jpg"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --window-size="$size" --virtual-time-budget=2000 --screenshot="$png" "file://$PWD/$f" >/dev/null 2>&1
  sips -s format jpeg -s formatOptions 82 "$png" --out "$out" >/dev/null
  echo "$out $(sips -g pixelWidth -g pixelHeight "$out" | awk '/pixel/{printf "%s ", $2}')"
done
