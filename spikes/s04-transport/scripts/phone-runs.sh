#!/usr/bin/env bash
# Spike S4 on the real phone — DEFERRED (needs the phone + Android toolchain session).
# Runs the same workload as the loopback matrix, phone side as an `adb shell` process
# (shell uid; no app install needed), Mac side local:
#   * Wi-Fi: QUIC (cubic, bbr3) vs TLS/TCP per channel, Mac -> phone's Wi-Fi IP directly;
#   * USB:   QUIC-over-one-adb-TCP (tunnel, tunnel+bbr3, tunnel-lean+bbr3) vs framed TCP
#            channels over adb (tcp = TLS, rawtcp = scrcpy-style baseline), via `adb forward`.
# Condition `real`: 45 s, concurrent 1 GiB bulk transfer from t=6 s (stops at 1 GiB or t=40 s).
# Phone and Mac clocks differ: the Mac estimates the offset from the lowest-RTT control pings
# (reported as mac.clock_offset_est_ms); one-way latencies are corrected with it.
#
# Physical steps for a person (before running):
#   1. Unlock the phone, keep the screen on (`adb shell svc power stayon usb` is done below).
#   2. USB cable connected, USB debugging authorised for this Mac.
#   3. Phone and Mac on the same Wi-Fi network (note SSID, band, channel, RSSI in the result doc).
#   4. For "congested Wi-Fi": repeat the Wi-Fi block while a second device saturates the same
#      access point (e.g. a large download), and record what it was.
set -euo pipefail
cd "$(dirname "$0")/.."
ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
SEEDS=${SEEDS:-"1 2 3"}
TAG=${TAG:-quiet}               # label for the Wi-Fi condition, e.g. quiet | congested
OUT=results/s4/phone-raw
PH=/data/local/tmp

./scripts/build-android.sh
cargo build --release -p bench >/dev/null
"$ADB" get-state >/dev/null                # fails fast if no authorised device
"$ADB" push target/android/aarch64-linux-android/release/bench $PH/s4-bench >/dev/null
"$ADB" shell chmod 755 $PH/s4-bench
./target/release/bench gen-cert results/tmp/phone-cert
"$ADB" push results/tmp/phone-cert/. $PH/s4-cert/ >/dev/null
"$ADB" shell svc power stayon usb || true
{ date; "$ADB" shell getprop ro.product.model; "$ADB" shell getprop ro.build.fingerprint;
  "$ADB" shell dumpsys wifi | grep -m3 -E "mWifiInfo|SSID" || true; } > "$OUT-device-$TAG.txt" 2>&1 || true
PHONE_IP=$("$ADB" shell ip -4 addr show wlan0 | awk '/inet /{print $2}' | cut -d/ -f1)
echo "phone Wi-Fi IP: $PHONE_IP"

common=(--cond real --cert-dir results/tmp/phone-cert --phone-cert-dir $PH/s4-cert
        --phone-cmd "$ADB shell $PH/s4-bench")
for seed in $SEEDS; do
  for t in "quic cubic" "quic bbr3" "tcp cubic"; do
    read -r tr cc <<<"$t"
    ./target/release/bench run --transport "$tr" --cc "$cc" --seed "$seed" "${common[@]}" \
      --path direct --phone-host "$PHONE_IP" --out "$OUT/wifi-$TAG"
  done
  for t in "tunnel cubic" "tunnel bbr3" "tunnel-lean bbr3" "tcp cubic" "rawtcp cubic"; do
    read -r tr cc <<<"$t"
    ./target/release/bench run --transport "$tr" --cc "$cc" --seed "$seed" "${common[@]}" \
      --path adb-forward --adb "$ADB" --out "$OUT/usb"
  done
done
python3 -I scripts/s4-summarize.py "$OUT/wifi-$TAG" > "$OUT/summary-wifi-$TAG.md"
python3 -I scripts/s4-summarize.py "$OUT/usb" > "$OUT/summary-usb.md"
