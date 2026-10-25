#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# S15, non-interactive part: compare designated requirements (DRs) across an update.
# TCC stores the DR of the version the user granted, and later checks each new
# version against it - `codesign --verify -R <old DR> <new app>` is the same check.
#
# usage: s15-dr-check.sh [--impostor]      (run ./build.sh s15 first)
#   --impostor  also create a throwaway self-signed identity in /tmp (and a temporary
#               login-keychain password item), sign a copy of 1.0.1 with it under the
#               same identifier, check it against 1.0.0's DR, then delete both again.
#
# Writes results/s15-dr/dr-check.txt and prints it.

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="$here/results/s15-dr"
mkdir -p "$out"
exec > >(tee "$out/dr-check.txt") 2>&1

dr_of() { codesign -d -r- "$1" 2>&1 | sed -n -E 's/^#? ?designated => //p'; }
describe() {
  local app="$1"
  echo "  $(basename "$(dirname "$app")")/$(basename "$app")"
  codesign -dvv "$app" 2>&1 | grep -E '^(Identifier=|CodeDirectory |Authority=|TeamIdentifier=)' | sed 's/^/    /'
  echo "    CDHash=$(codesign -dvvv "$app" 2>&1 | sed -n 's/^CDHash=//p')"
  echo "    MachO-UUID=$(dwarfdump --uuid "$app/Contents/MacOS/TomboloProbe" | awk '{print $2}')"
  echo "    DR: $(dr_of "$app")"
}
check() { # check <label> <app whose DR is the requirement> <app under test>
  local req; req="$(mktemp)"; dr_of "$2" >"$req"
  local res; res="$(codesign --verify -v -R "$req" "$3" 2>&1 | tail -1 | sed "s#^.*/\([^/]*\.app\):#\1:#")"
  rm -f "$req"
  printf '  %-58s %s\n' "$1" "$res"
}

echo "S15 DR check - $(date '+%F %T %z') - $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
s100="$here/build/s15/selfsigned-1.0.0/S15 Probe.app"
s101="$here/build/s15/selfsigned-1.0.1/S15 Probe.app"
a100="$here/build/s15/adhoc-1.0.0/S15 AdHoc Probe.app"
a101="$here/build/s15/adhoc-1.0.1/S15 AdHoc Probe.app"
for a in "$s100" "$s101" "$a100" "$a101"; do [[ -d "$a" ]] || { echo "missing $a - run ./build.sh s15"; exit 1; }; done

echo; echo "Bundles"
for a in "$s100" "$s101" "$a100" "$a101"; do describe "$a"; done

echo; echo "Does the update satisfy the DR of the version the user granted?"
check "self-signed: 1.0.1 against 1.0.0's DR (update)" "$s100" "$s101"
check "self-signed: 1.0.0 against 1.0.1's DR (downgrade)" "$s101" "$s100"
check "ad-hoc:      1.0.1 against 1.0.0's DR (update)" "$a100" "$a101"
check "ad-hoc:      1.0.0 against 1.0.1's DR (downgrade)" "$a101" "$a100"
check "cross:       self-signed 1.0.1 against ad-hoc 1.0.0's DR" "$a100" "$s101"

if [[ "${1:-}" == --impostor ]]; then
  echo; echo "Impostor: same identifier, different self-signed certificate"
  tmp="$(mktemp -d -t s15-impostor)"
  export TOMBOLO_SIGNING_KEYCHAIN="$tmp/impostor.keychain-db" TOMBOLO_SIGNING_CN="S15 Impostor (self-signed)"
  "$repo/tools/signing/create-identity.sh" >/dev/null 2>&1 || { echo "  could not create impostor identity"; exit 1; }
  cp -R "$s101" "$tmp/S15 Probe.app"
  "$repo/tools/signing/sign.sh" "$tmp/S15 Probe.app" >/dev/null 2>&1
  describe "$tmp/S15 Probe.app" | sed 's#  [^ ]*/S15 Probe.app#  impostor copy of 1.0.1#'
  check "impostor 1.0.1 against genuine 1.0.0's DR" "$s100" "$tmp/S15 Probe.app"
  "$repo/tools/signing/remove-identity.sh" --yes >/dev/null 2>&1
  rm -rf "$tmp"
  echo "  (impostor keychain and its login-keychain password item deleted)"
fi
