#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Spike S2 (P0-15): connect to the phone over Wi-Fi with Android's Wireless debugging, so run.sh works without a
# cable. Prints the adb serial to use and exits 0 once `adb devices` lists the phone over Wi-Fi.
#
#   spikes/s02-mac-video/scripts/pair-wireless.sh
#   ANDROID_SERIAL="$(spikes/s02-mac-video/scripts/pair-wireless.sh)" spikes/s02-mac-video/run.sh
#
# First time: pairs with adb's QR scheme (the one Android Studio uses). The Mac shows a QR code holding a one-time
# service name and password; on the phone open Settings › System › Developer options › Wireless debugging ›
# "Pair device with QR code" and scan it. adb finds the phone's pairing service over mDNS and pairs. The password
# stays on this Mac (it only appears inside the QR code) and the QR image is deleted afterwards.
#
# Later: pairing persists, so only a connect is needed. Android turns Wireless debugging off when the phone
# restarts or changes network; turn it back on, then rerun this script. Phone and Mac must share a Wi-Fi network
# that allows device-to-device traffic (many guest and office networks don't).
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
say() { printf '%s\n' "$*" >&2; }

# A device adb reaches over TCP: "ip:port" or an mDNS name ending in ._adb-tls-connect._tcp.
wireless_device() {
    "$ADB" devices | awk 'NR > 1 && $2 == "device" && ($1 ~ /:[0-9]+$/ || $1 ~ /_adb-tls-connect\._tcp/) { print $1; exit }'
}
# ip:port of the first mDNS service of type $1 (optionally whose name is $2).
mdns_service() {
    "$ADB" mdns services | awk -v type="$1" -v name="${2:-}" '$2 == type && (name == "" || $1 == name) { print $3; exit }'
}
try_connect() {
    addr="$(mdns_service _adb-tls-connect._tcp)"
    [ -n "$addr" ] || return 1
    "$ADB" connect "$addr" >&2 || return 1
    sleep 1
    [ -n "$(wireless_device)" ]
}
done_with() {
    say "Connected over Wi-Fi as: $1"
    say "Mirror it with:  ANDROID_SERIAL='$1' $HERE/run.sh"
    printf '%s\n' "$1"
    exit 0
}

"$ADB" start-server >/dev/null 2>&1
dev="$(wireless_device)"
[ -n "$dev" ] && done_with "$dev"
if try_connect; then done_with "$(wireless_device)"; fi

# Not paired yet (or the phone's Wireless debugging is off): pair with a QR code.
name="tombolo-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
pass="$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
mkdir -p "$HERE/.build"
if [ ! -x "$HERE/.build/qr" ] || [ "$HERE/scripts/qr.swift" -nt "$HERE/.build/qr" ]; then
    swiftc -O -o "$HERE/.build/qr" "$HERE/scripts/qr.swift"
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
"$HERE/.build/qr" "WIFI:T:ADB;S:$name;P:$pass;;" "$tmp/pair.png"
open "$tmp/pair.png"
say "On the phone: Settings › System › Developer options › Wireless debugging (turn it on) ›"
say "  \"Pair device with QR code\", then scan the QR code now open on this Mac. Waiting up to 3 minutes…"

addr=""
i=0
while [ $i -lt 90 ]; do
    addr="$(mdns_service _adb-tls-pairing._tcp "$name")"
    [ -n "$addr" ] && break
    sleep 2
    i=$((i + 1))
done
[ -n "$addr" ] || { say "No pairing request seen. Are the phone and Mac on the same Wi-Fi network?"; exit 1; }
"$ADB" pair "$addr" "$pass" >&2
rm -f "$tmp/pair.png"

# adb usually connects by itself after pairing; give it a moment, then connect explicitly.
i=0
while [ $i -lt 15 ]; do
    dev="$(wireless_device)"
    [ -n "$dev" ] && done_with "$dev"
    try_connect && done_with "$(wireless_device)"
    sleep 2
    i=$((i + 1))
done
say "Paired, but could not connect. Check that Wireless debugging is still on, then rerun this script."
exit 1
