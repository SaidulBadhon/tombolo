#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Remove what the S08/S15 runs left on this Mac, as far as a normal user can, and
# print the exact commands/clicks for the rest. Run it after the maintainer checklist.
#
# usage: cleanup.sh            dry run: show what would be removed
#        cleanup.sh --yes      do it
#
# Removes (user-level, no sudo):
#   - running probe processes
#   - login items registered by the probes (SMAppService.mainApp.unregister via each probe)
#   - TCC records for the spike bundle IDs (tccutil reset All <id>): Documents folder,
#     Accessibility, ...
#   - LaunchServices registrations of the probe bundles (lsregister -u)
#   - probe logs in ~/Library/Logs/TomboloSpikeS08
# Cannot remove (prints instructions):
#   - Application Firewall entries (needs sudo)
#   - Local Network entries (no reset before macOS 27.2, TN3179)
#   - the dev signing identity (kept on purpose; tools/signing/remove-identity.sh --yes)

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
do_it=0; [[ "${1:-}" == --yes ]] && do_it=1
run() { echo "+ $*"; (( do_it )) && "$@"; return 0; }

ids=(io.github.saidulbadhon.tombolo.spike.s08.adhoc io.github.saidulbadhon.tombolo.spike.s08.selfsigned
     io.github.saidulbadhon.tombolo.spike.s08.unsigned io.github.saidulbadhon.tombolo.spike.s15
     io.github.saidulbadhon.tombolo.spike.s15adhoc)
lsreg=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

echo "== probe processes"
run pkill -f 'Contents/MacOS/TomboloProbe'

echo "== login items (unregister through each installed S15 probe)"
for a in "$here/build/s15/installed/selfsigned/S15 Probe.app" "$here/build/s15/installed/adhoc/S15 AdHoc Probe.app"; do
  [[ -d "$a" ]] || continue
  if (( do_it )); then
    "$here/run-probe.sh" "$a" "cleanup-login-$(basename "$(dirname "$a")")" "login-unregister;quit" 6 >/dev/null 2>&1
    grep -h 'login-unregister' "$here/results/cleanup-login-$(basename "$(dirname "$a")")/probe.log" | cut -c26- | cut -c1-120
    rm -rf "$here/results/cleanup-login-$(basename "$(dirname "$a")")"
  else
    echo "+ (would launch $(basename "$a") with login-unregister)"
  fi
done

echo "== TCC records"
for id in "${ids[@]}"; do run /usr/bin/tccutil reset All "$id"; done

echo "== LaunchServices registrations"
while IFS= read -r -d '' app; do run "$lsreg" -u "$app"; done < <(find "$here/build" -name '*.app' -maxdepth 4 -print0 2>/dev/null)

echo "== probe logs"
run rm -rf "$HOME/Library/Logs/TomboloSpikeS08"

cat <<EOF

== Needs you (cannot be done without sudo / a newer macOS):
1. Firewall entries - System Settings > Network > Firewall > Options..., select each
   "S08 AdHoc", "S08 SelfSigned" (and any "S15 ..." entry) and click "-"; or in Terminal:
EOF
/usr/libexec/ApplicationFirewall/socketfilterfw --listapps 2>/dev/null \
  | sed -n -E "s#^[0-9]+ : (.*s08-macos-permissions.*TomboloProbe) *\$#     sudo /usr/libexec/ApplicationFirewall/socketfilterfw --remove \"\1\"#p"
cat <<EOF
2. Local Network entries ("S08 AdHoc", "S08 SelfSigned", "S08 Unsigned", "S15 ...") stay in
   System Settings > Privacy & Security > Local Network. macOS 27.0.1 has no way to remove them
   (TN3179); from macOS 27.2 select each and click "-".
3. Optional: delete the dev signing identity:  tools/signing/remove-identity.sh --yes
EOF
