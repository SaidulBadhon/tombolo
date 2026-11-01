#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Print macOS Local Network privacy rules (read-only) for matching signing identifiers.

usage: python3 -I lnp-rules.py [substring | =suffix ...]   (default: "tombolo")
       "=suffix" matches identifiers that end with suffix (e.g. "=.spike.s15")

Reads /Library/Preferences/com.apple.networkextension.plist (world-readable, owned by
root; this script never writes it). On macOS 27.0.1 nehelper stores each app's Local
Network state as an NEPathRule keyed by SigningIdentifier. Observed meaning of the
fields (inferred from behaviour in spike S08, not documented by Apple):
  MulticastPreferenceSet=False, DenyMulticast=True   -> undetermined (no answer yet)
  MulticastPreferenceSet=True,  DenyMulticast=False  -> allowed
  MulticastPreferenceSet=True,  DenyMulticast=True   -> denied
"""
import plistlib
import sys

PATH = "/Library/Preferences/com.apple.networkextension.plist"
needles = [a.lower() for a in sys.argv[1:]] or ["tombolo"]

with open(PATH, "rb") as f:
    archive = plistlib.load(f)
objs = archive["$objects"]


def deref(v):
    return objs[v.data] if isinstance(v, plistlib.UID) else v


def classname(o):
    c = deref(o.get("$class")) if isinstance(o, dict) else None
    return c.get("$classname") if isinstance(c, dict) else None


def state(rule):
    if not rule.get("MulticastPreferenceSet"):
        return "undetermined"
    return "denied" if rule.get("DenyMulticast") else "allowed"


for o in objs:
    if not isinstance(o, dict) or classname(o) != "NEPathRule":
        continue
    ident = deref(o.get("SigningIdentifier"))
    if not isinstance(ident, str) or not any(
            ident.lower().endswith(n[1:]) if n.startswith("=") else n in ident.lower() for n in needles):
        continue
    dr = deref(o.get("DesignatedRequirement"))
    dr = "null" if dr in (None, "$null") else (dr.hex() if isinstance(dr, bytes) else dr)
    print(f"{ident}: {state(o)}  (MulticastPreferenceSet={o.get('MulticastPreferenceSet')} "
          f"DenyMulticast={o.get('DenyMulticast')} DesignatedRequirement={dr} "
          f"AllowEmptyDesignatedRequirement={o.get('AllowEmptyDesignatedRequirement')})")
