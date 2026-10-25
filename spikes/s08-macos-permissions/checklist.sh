#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Maintainer checklist for S08/S15: the steps that need a person to click.
# Each subcommand launches a probe, tells you exactly what to click, waits for it,
# and records the evidence under results/<label>/. The full list, with expected
# results, is in docs/spikes/s08-macos-local-network.md and s15-update-persistence.md.
#
# usage: checklist.sh <step>
#   m1-lnp-deny             S15 AdHoc Probe asks for Local Network; you click "Don't Allow";
#                           then records denied failure modes for 1.0.0 and after updating to 1.0.1
#   m2-lnp-reallow          you turn "S15 AdHoc Probe" ON in System Settings > Local Network while
#                           a connection is waiting; records whether it recovers without a relaunch
#   m3-lnp-allow-s15        S15 Probe (self-signed) asks; you click "Allow"; then records 1.0.1 (no alert expected)
#   m4-ax-grant <selfsigned|adhoc>   you grant Accessibility to 1.0.0
#   m5-ax-update <selfsigned|adhoc>  installs 1.0.1 in place; records whether Accessibility survived
#   status                  prints the current Local Network rules and firewall entries
#
# Prerequisites: ./build.sh (all bundles) and tools/signing/create-identity.sh once.

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

ask() { printf '\n>>> %s\n\n' "$*"; }
rules() { python3 -I lnp-rules.py "$1"; }
wait_rule() { # wait_rule <identifier> <state> <seconds>
  local id="$1" want="$2" secs="$3" i
  for ((i = 0; i < secs; i += 2)); do
    if rules "$id" | grep -q ": $want "; then echo "rule for $id is now $want (after ~${i}s)"; return 0; fi
    sleep 2
  done
  echo "timed out: rule for $id is not $want after ${secs}s"; rules "$id"; return 1
}
lan() { eval "$(python3 -I lan-target.py)"; echo "LAN: self=$SELF unused=$UNUSED gateway=$GATEWAY"; }
measure() { # measure <variant> <version> <label>  - Local Network failure modes, no clicks needed
  WATCH=30 ./s15-update.sh "$1" "$2" "$3" \
    "browse:_tombolo-test._tcp:5;bsdconnect:$UNUSED:9:4;nwconnect:$UNUSED:9:5;udpconnect-nosigpipe:$UNUSED:9;udpconnect:$UNUSED:9;quit" >/dev/null
  rules "tombolo.spike.s15" >"results/$3/lnp-rules.txt"
  echo "--- $3"; grep -v -E '^\s' "results/$3/probe.log" | grep -E 'browse .*(state|end)|connect\(\)|completed|still connecting|state=waiting|end after|send\(\)|SIGPIPE' | cut -c26- | cut -c1-200
  cat "results/$3/windows.log"
}

case "${1:-}" in
  m1-lnp-deny)
    lan
    rules s15adhoc || true
    ask 'An alert "Allow "S15 AdHoc Probe" to find devices on local networks?" will appear. Click  Don'"'"'t Allow.'
    WATCH=180 ./s15-update.sh adhoc 1.0.0 m1a-lnp-deny-prompt "browse:_tombolo-test._tcp:5;nwconnect:$UNUSED:9:170;quit" >/dev/null &
    probe=$!
    wait_rule s15adhoc denied 180 || true
    pkill -f "installed/adhoc/S15 AdHoc Probe.app/Contents/MacOS/TomboloProbe" 2>/dev/null || true
    wait "$probe" || true
    rules s15adhoc >results/m1a-lnp-deny-prompt/lnp-rules-after.txt
    echo "--- m1a (while you answered)"; grep -v -E '^\s' results/m1a-lnp-deny-prompt/probe.log | grep -E 'browse|nwconnect' | cut -c26- | cut -c1-200
    measure adhoc 1.0.0 m1b-lnp-denied-1.0.0
    measure adhoc 1.0.1 m1c-lnp-denied-after-update-1.0.1
    ;;
  m2-lnp-reallow)
    lan
    ask 'Within 2 minutes: System Settings > Privacy & Security > Local Network > turn ON "S15 AdHoc Probe". Nothing else.'
    WATCH=130 ./s15-update.sh adhoc 1.0.1 m2-lnp-reallow "nwconnect:$UNUSED:9:120;quit" >/dev/null &
    probe=$!
    wait_rule s15adhoc allowed 125 || true
    sleep 5
    pkill -f "installed/adhoc/S15 AdHoc Probe.app/Contents/MacOS/TomboloProbe" 2>/dev/null || true
    wait "$probe" || true
    rules s15adhoc >results/m2-lnp-reallow/lnp-rules-after.txt
    grep -v -E '^\s' results/m2-lnp-reallow/probe.log | grep -E 'nwconnect' | cut -c26- | cut -c1-200
    ;;
  m3-lnp-allow-s15)
    lan
    ask 'An alert "Allow "S15 Probe" to find devices on local networks?" will appear. Click  Allow.'
    WATCH=180 ./s15-update.sh selfsigned 1.0.0 m3a-lnp-allow-prompt "nwconnect:$UNUSED:9:170;quit" >/dev/null &
    probe=$!
    wait_rule =.spike.s15 allowed 180 || true
    sleep 3
    pkill -f "installed/selfsigned/S15 Probe.app/Contents/MacOS/TomboloProbe" 2>/dev/null || true
    wait "$probe" || true
    rules =.spike.s15 >results/m3a-lnp-allow-prompt/lnp-rules-after.txt
    measure selfsigned 1.0.1 m3b-lnp-allowed-after-update-1.0.1
    ;;
  m4-ax-grant)
    v="${2:?selfsigned or adhoc}"; app=$([[ $v == selfsigned ]] && echo "S15 Probe" || echo "S15 AdHoc Probe")
    ask "A prompt \"$app would like to control this computer using accessibility features\" appears. Click  Open System Settings, then turn ON \"$app\" under Privacy & Security > Accessibility (Touch ID / password). The script stops when access is granted (max 3 min)."
    WATCH=190 ./s15-update.sh "$v" 1.0.0 "m4-ax-grant-$v-1.0.0" "ax;ax-prompt;ax-wait:180;quit" >/dev/null
    grep -v -E '^\s' "results/m4-ax-grant-$v-1.0.0/probe.log" | grep -E 'AXIs|ax-wait' | cut -c26- | cut -c1-160
    ;;
  m5-ax-update)
    v="${2:?selfsigned or adhoc}"; app=$([[ $v == selfsigned ]] && echo "S15 Probe" || echo "S15 AdHoc Probe")
    ask "Installing $app 1.0.1 over 1.0.0. Do not click anything for 20 s. Afterwards look at System Settings > Privacy & Security > Accessibility: is \"$app\" still listed and ON?"
    WATCH=30 ./s15-update.sh "$v" 1.0.1 "m5-ax-update-$v-1.0.1" "info;ax;ax-wait:20;quit" >/dev/null
    grep -v -E '^\s' "results/m5-ax-update-$v-1.0.1/probe.log" | grep -E 'AXIs|ax-wait' | cut -c26- | cut -c1-160
    grep -E 'AXIsProcessTrusted' "results/m5-ax-update-$v-1.0.1/probe.log" | head -1
    ;;
  status)
    echo "Local Network rules:"; rules tombolo.spike.s
    echo "Firewall entries:"; /usr/libexec/ApplicationFirewall/socketfilterfw --listapps 2>&1 | grep -A1 's08-macos-permissions' || echo "  none"
    ;;
  *) sed -n '2,22p' "$0"; exit 2 ;;
esac
