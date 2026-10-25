#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""LAN peer for the S08 probe (run with `python3 -I peer.py ...`).

  peer.py tcp-server HOST PORT [SECONDS]   accept connections, reply "pong from peer"
  peer.py tcp-client HOST PORT             connect, send "ping from peer", print reply
  peer.py udp-client HOST PORT             send one datagram, print reply (3 s timeout)

Note: when this runs from a shell inside a GUI app (Terminal, an IDE, an agent host),
macOS attributes its outgoing traffic to that app (or exempts it, for Terminal/SSH).
"""
import errno
import socket
import sys
import time


def stamp(msg):
    print(f"{time.strftime('%H:%M:%S')} peer: {msg}", flush=True)


def tcp_server(host, port, seconds=600):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((host, port))
    s.listen(8)
    s.settimeout(1)
    stamp(f"tcp-server listening on {host}:{port} for {seconds}s")
    end = time.time() + seconds
    while time.time() < end:
        try:
            c, addr = s.accept()
        except socket.timeout:
            continue
        c.settimeout(3)
        try:
            data = c.recv(1024)
            stamp(f"tcp-server accepted {addr[0]}:{addr[1]} got {data!r}")
            c.sendall(b"pong from peer\n")
        except OSError as e:
            stamp(f"tcp-server error with {addr}: {e}")
        finally:
            c.close()


def tcp_client(host, port):
    s = socket.socket()
    s.settimeout(5)
    t = time.monotonic()
    try:
        s.connect((host, port))
        s.sendall(b"ping from peer\n")
        stamp(f"tcp-client {host}:{port} connected in {1000*(time.monotonic()-t):.1f}ms, reply {s.recv(1024)!r}")
    except OSError as e:
        stamp(f"tcp-client {host}:{port} error errno={e.errno} {errno.errorcode.get(e.errno)} {e}")


def udp_client(host, port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    try:
        s.sendto(b"udp ping from peer", (host, port))
        data, addr = s.recvfrom(2048)
        stamp(f"udp-client {host}:{port} reply from {addr[0]}:{addr[1]}: {data!r}")
    except OSError as e:
        stamp(f"udp-client {host}:{port} error errno={e.errno} {errno.errorcode.get(e.errno)} {e}")


if __name__ == "__main__":
    mode, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
    if mode == "tcp-server":
        tcp_server(host, port, int(sys.argv[4]) if len(sys.argv) > 4 else 600)
    elif mode == "tcp-client":
        tcp_client(host, port)
    elif mode == "udp-client":
        udp_client(host, port)
    else:
        sys.exit(__doc__)
