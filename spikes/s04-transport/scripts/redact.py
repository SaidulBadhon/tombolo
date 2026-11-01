#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Redact machine-identifying network data before results are written to the repository.

    python3 -I scripts/redact.py FILE...      # rewrite files in place
    cmd | python3 -I scripts/redact.py        # filter stdin -> stdout

Replaces global IPv6 (2000::/3) -> <redacted-ipv6>, EUI-64 (MAC-derived) IPv6 of any scope ->
<redacted-eui64>, MAC addresses -> <redacted-mac>, global IPv4 -> <redacted-ipv4>. Loopback,
private (RFC 1918 / ULA) and link-local non-EUI-64 addresses are kept: the evidence needs them.
Stdlib only.
"""
import ipaddress
import re
import sys

# Bounded by non-hex characters only: ANSI colour codes put an "m" right before addresses.
V6 = re.compile(r"(?<![0-9A-Fa-f:.])((?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4})(?![0-9A-Fa-f:])")
MAC = re.compile(r"(?<![0-9A-Fa-f:])((?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2})(?![0-9A-Fa-f:])")
V4 = re.compile(r"(?<![0-9.])((?:[0-9]{1,3}\.){3}[0-9]{1,3})(?![0-9])")


def _v6(m):
    tok = m.group(1)
    if tok.startswith(":") or tok.count(":") < 2:
        return tok  # Rust paths such as `iroh::address_lookup` contain "::add"
    try:
        a = ipaddress.IPv6Address(tok)
    except ValueError:
        return tok
    b = a.packed
    if b[11] == 0xFF and b[12] == 0xFE:
        return "<redacted-eui64>"
    if 0x2000 <= int(a) >> 112 <= 0x3FFF:
        return "<redacted-ipv6>"
    return tok


def _v4(m):
    tok = m.group(1)
    try:
        a = ipaddress.IPv4Address(tok)
    except ValueError:
        return tok
    return "<redacted-ipv4>" if a.is_global else tok


def redact(text: str) -> str:
    text = MAC.sub("<redacted-mac>", text)
    text = V6.sub(_v6, text)
    return V4.sub(_v4, text)


def main(argv):
    if len(argv) == 1:
        sys.stdout.write(redact(sys.stdin.read()))
        return 0
    for p in argv[1:]:
        try:
            with open(p, encoding="utf-8", errors="surrogateescape") as f:
                t = f.read()
        except OSError:
            continue
        r = redact(t)
        if r != t:
            with open(p, "w", encoding="utf-8", errors="surrogateescape") as f:
                f.write(r)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
