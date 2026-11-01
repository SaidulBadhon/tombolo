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
#   3. Phone and Mac on the same Wi-Fi network. Record band, channel, RSSI and link speed in the
#      result doc — not the network name (SSID) or access-point address (BSSID).
#   4. For "congested Wi-Fi": repeat the Wi-Fi block while a second device saturates the same
#      access point (e.g. a large download), and record what it was.
#   5. macOS **Local Network** alert: the Wi-Fi runs make the Mac-side `bench` (started from a
#      terminal) reach the phone's LAN address, which may raise the Local Network privacy alert for
#      the responsible app (the terminal). Watch for it on the first Wi-Fi run, answer "Allow", and
#      record whether and when it appeared (screenshot without other windows). See S8
#      (docs/spikes/s08-macos-local-network.md, written on another branch).
#   6. macOS **Application Firewall** prompt ("Do you want the application "bench" to accept
#      incoming network connections?"): S8 saw it on the first inbound flow for ad-hoc/self-signed
#      binaries, holding the flow until answered. Inbound packets from the phone are possible here
#      (see the note below). Watch for it, answer "Allow", record it, and check
#      `/usr/libexec/ApplicationFirewall/socketfilterfw --listapps` afterwards. These observations
#      are S8's remote-peer incoming test (S8 row 6b), which S8 assigns to this run; a dedicated
#      incoming-only test (phone dials the Mac) is not scripted yet.
#   UNTESTED: iroh always enables multipath and QUIC NAT traversal (S5). An endpoint advertises its
#   local addresses and the peer probes them, so creating/connecting the Mac endpoint may itself
#   trigger the Local Network alert, and the phone may send unsolicited packets to other Mac
#   addresses (firewall prompt). Note which run, and which step, raised each prompt.
#
# Everything written under results/s4/phone-raw/ is passed through scripts/redact.py (global
# IPv6/IPv4, EUI-64 and MAC addresses) on exit; load logging records load averages, benchmark
# processes and one anonymous %CPU total for everything else — never other process names.
set -euo pipefail
cd "$(dirname "$0")/.."
ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
SEEDS=${SEEDS:-"1 2 3"}
TAG=${TAG:-quiet}               # label for the Wi-Fi condition, e.g. quiet | congested
OUT=results/s4/phone-raw
PH=/data/local/tmp
mkdir -p "$OUT"
trap 'find "$OUT" -type f -print0 | xargs -0 python3 -I scripts/redact.py' EXIT

log_load() { # what
  { echo "== $(date '+%F %T') $*"
    echo "mac $(uptime | sed -E 's/.*(load averages?:)/\1/')"
    ps -Ao pcpu=,comm= 2>/dev/null | awk '
      { cmd = $0; sub(/^ *[0-9.]+ +/, "", cmd); n = split(cmd, p, "/"); base = p[n] }
      base ~ /^(bench|iroh-probe|s4-bench)$/ { printf "%6.1f %s\n", $1, base; next }
      { other += $1 }
      END { printf "mac other_cpu_pct=%.0f\n", other }' || true
    echo "phone loadavg $("$ADB" shell cat /proc/loadavg 2>/dev/null || echo n/a)"
  } >> "$OUT/load.log"
}

./scripts/build-android.sh
cargo build --release -p bench >/dev/null
"$ADB" get-state >/dev/null                # fails fast if no authorised device
"$ADB" push target/android/aarch64-linux-android/release/bench $PH/s4-bench >/dev/null
"$ADB" shell chmod 755 $PH/s4-bench
./target/release/bench gen-cert results/tmp/phone-cert
"$ADB" push results/tmp/phone-cert/. $PH/s4-cert/ >/dev/null
"$ADB" shell svc power stayon usb || true
# Device record: model, build and Wi-Fi link quality only (SSID, BSSID, MAC and IP dropped).
{ date; "$ADB" shell getprop ro.product.model; "$ADB" shell getprop ro.build.fingerprint;
  "$ADB" shell dumpsys wifi | grep -m1 "mWifiInfo" \
    | sed -E 's/(SSID|BSSID|MAC|IP): [^,]*/\1: <redacted>/g' || true
} > "$OUT/device-$TAG.txt" 2>&1 || true
PHONE_IP=$("$ADB" shell ip -4 addr show wlan0 | awk '/inet /{print $2}' | cut -d/ -f1)
echo "phone Wi-Fi IP: $PHONE_IP"

common=(--cond real --cert-dir results/tmp/phone-cert --phone-cert-dir $PH/s4-cert
        --phone-cmd "$ADB shell $PH/s4-bench")
for seed in $SEEDS; do
  for t in "quic cubic" "quic bbr3" "tcp cubic"; do
    read -r tr cc <<<"$t"
    log_load "wifi-$TAG $tr $cc seed=$seed"
    ./target/release/bench run --transport "$tr" --cc "$cc" --seed "$seed" "${common[@]}" \
      --path direct --phone-host "$PHONE_IP" --out "$OUT/wifi-$TAG"
  done
  for t in "tunnel cubic" "tunnel bbr3" "tunnel-lean bbr3" "tcp cubic" "rawtcp cubic"; do
    read -r tr cc <<<"$t"
    log_load "usb $tr $cc seed=$seed"
    ./target/release/bench run --transport "$tr" --cc "$cc" --seed "$seed" "${common[@]}" \
      --path adb-forward --adb "$ADB" --out "$OUT/usb"
  done
done
python3 -I scripts/s4-summarize.py "$OUT/wifi-$TAG" > "$OUT/summary-wifi-$TAG.md"
python3 -I scripts/s4-summarize.py "$OUT/usb" > "$OUT/summary-usb.md"
