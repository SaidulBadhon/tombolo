#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Reduce a raw unified-log capture to the lines about this spike's probes and about
# Local Network privacy, so results can be committed without unrelated system data.
# usage: excerpt.sh <system.log>
grep -E 'tombolo\.spike\.s(08|15)|S08 (AdHoc|SelfSigned|Unsigned)|S15 (AdHoc )?Probe|TomboloProbe|[Ll]ocal ?[Nn]etwork|PolicyDenied|AUTHREQ_RESULT: msgID=424\.' "$1" \
  | grep -v -E 'Tombolo Apps|Tombolo\.shim|spike-s13' \
  | grep -v -E 'runningboardd\[' \
  ; grep -E 'runningboardd\[.*(tombolo\.spike\.s(08|15)).*([Ee]rror|[Ff]ail|Security policy)' "$1"
exit 0
