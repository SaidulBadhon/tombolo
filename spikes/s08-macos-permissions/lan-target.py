#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Print LAN facts for the S08 probe: own IPv4, gateway, and an unused on-link address.

usage: python3 -I lan-target.py [interface]      (default: the default-route interface)
output (shell-friendly):
  IFACE=en0 SELF=172.20.10.14 GATEWAY=172.20.10.1 UNUSED=172.20.10.13

UNUSED is an address on the interface's subnet that is not this Mac, not the gateway,
not the broadcast address and not in the ARP cache. Connecting to it is a genuine
local-network operation (the kernel must ARP for it on-link), yet no device receives
any traffic. Note: the gateway is usually also the DNS server, which TN3179 exempts
from Local Network privacy, and the Mac's own address is routed over lo0, which is
not a local-network destination at all - neither is a valid test target.
"""
import ipaddress
import re
import subprocess
import sys


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout


route = run("/sbin/route", "-n", "get", "default")
iface = sys.argv[1] if len(sys.argv) > 1 else re.search(r"interface: (\S+)", route).group(1)
gm = re.search(r"gateway: (\S+)", route)
gw = gm.group(1) if gm else ""
ifc = run("/sbin/ifconfig", iface)
m = re.search(r"inet (\d+\.\d+\.\d+\.\d+) netmask (0x[0-9a-f]+)", ifc)
if not m:
    sys.exit(f"no IPv4 address on {iface}")
own = ipaddress.IPv4Address(m.group(1))
mask = ipaddress.IPv4Address(int(m.group(2), 16))
net = ipaddress.IPv4Network(f"{own}/{mask}", strict=False)
known = set(re.findall(r"\((\d+\.\d+\.\d+\.\d+)\) at [0-9a-f:]+ ", run("/usr/sbin/arp", "-an")))
candidates = [h for h in reversed(list(net.hosts()))
              if h != own and str(h) != gw and str(h) not in known]
unused = candidates[0] if candidates else ""
print(f"IFACE={iface} SELF={own} GATEWAY={gw} SUBNET={net} UNUSED={unused}")
