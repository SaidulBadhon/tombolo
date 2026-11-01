#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tombolo latency harness — Mac-side page + clock server (Python 3 standard library only).

Serves the latency page (web/) to the phone's browser and answers clock-sync round trips with
Mac host time. All Mac timestamps use CLOCK_UPTIME_RAW, which on macOS is mach_absolute_time()
in nanoseconds — the same clock as ScreenCaptureKit's frame display times — so the capture tool
and this server share one timebase.

Endpoints
  GET  /             the page (index.html, code.js, page.js only — nothing else is served)
  GET  /time         {"recv_ns": T1, "send_ns": T2}
  POST /log          JSON from the page; appended as one line to <run-dir>/sync.jsonl
  GET  /status       {"sessions": {...}, "lines": N} — for scripts waiting for the page

Default bind is 127.0.0.1 (use `adb reverse tcp:8765 tcp:8765` for a USB-connected phone, or a
local browser for the self-test). --lan binds 0.0.0.0 so a phone on the same Wi-Fi can connect;
the server only serves the three static files and the time, and accepts small JSON logs.
"""

import argparse
import http.server
import json
import os
import socket
import sys
import threading
import time

CLOCK = time.CLOCK_UPTIME_RAW
WEB_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "web")
STATIC = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/code.js": ("code.js", "text/javascript; charset=utf-8"),
    "/page.js": ("page.js", "text/javascript; charset=utf-8"),
}
MAX_BODY = 256 * 1024


def now_ns():
    return time.clock_gettime_ns(CLOCK)


class State:
    def __init__(self, run_dir):
        self.run_dir = run_dir
        self.lock = threading.Lock()
        self.sessions = {}
        self.lines = 0
        os.makedirs(run_dir, exist_ok=True)
        self.path = os.path.join(run_dir, "sync.jsonl")

    def append(self, obj):
        line = json.dumps(obj, separators=(",", ":"))
        with self.lock:
            with open(self.path, "a", encoding="utf-8") as f:
                f.write(line + "\n")
            self.lines += 1
            sid = obj.get("session")
            if isinstance(sid, int):
                s = self.sessions.setdefault(sid, {"sync_samples": 0, "info": None, "last_ns": 0})
                if obj.get("type") == "sync":
                    s["sync_samples"] += len(obj.get("samples", []))
                elif obj.get("type") == "info":
                    s["info"] = obj.get("info")
                s["last_ns"] = now_ns()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "TomboloLatency/1"
    state = None  # set in main()
    quiet = True

    def setup(self):
        super().setup()
        try:
            self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass

    def log_message(self, fmt, *args):
        if not self.quiet:
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _headers(self, code, ctype, length):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store")
        # Cross-origin isolation gives the page a finer performance.now() in secure contexts
        # (localhost / adb reverse); harmless elsewhere.
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.end_headers()

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self._headers(code, "application/json", len(body))
        self.wfile.write(body)

    def do_GET(self):
        recv_ns = now_ns()
        path = self.path.split("?", 1)[0]
        if path == "/time":
            # Take the send timestamp as late as possible; the body is tiny and fixed-format.
            send_ns = now_ns()
            body = ('{"recv_ns":%d,"send_ns":%d}' % (recv_ns, send_ns)).encode()
            self._headers(200, "application/json", len(body))
            self.wfile.write(body)
            return
        if path == "/status":
            with self.state.lock:
                self._json({"lines": self.state.lines, "run_dir": self.state.run_dir,
                            "sessions": {"%08x" % k: v for k, v in self.state.sessions.items()}})
            return
        if path in STATIC:
            name, ctype = STATIC[path]
            with open(os.path.join(WEB_DIR, name), "rb") as f:
                body = f.read()
            self._headers(200, ctype, len(body))
            self.wfile.write(body)
            return
        self._json({"error": "not found"}, 404)

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        length = int(self.headers.get("Content-Length") or 0)
        if path != "/log" or length <= 0 or length > MAX_BODY:
            if 0 < length <= MAX_BODY:
                self.rfile.read(length)
            self._json({"error": "bad request"}, 400)
            return
        try:
            obj = json.loads(self.rfile.read(length))
            if not isinstance(obj, dict) or obj.get("type") not in ("sync", "info") or not isinstance(obj.get("session"), int):
                raise ValueError("unexpected log object")
        except (ValueError, json.JSONDecodeError) as e:
            self._json({"error": str(e)}, 400)
            return
        obj["server_ns"] = now_ns()
        self.state.append(obj)
        self._json({"ok": True})


def lan_addresses():
    addrs = set()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("192.0.2.1", 9))  # no packet is sent; picks the default-route interface
        addrs.add(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    return sorted(addrs)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--run-dir", required=True, help="directory for sync.jsonl (shared with the capture tool)")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--lan", action="store_true", help="listen on all interfaces (phone over Wi-Fi)")
    ap.add_argument("--verbose", action="store_true", help="log every request")
    args = ap.parse_args()

    Handler.state = State(os.path.abspath(args.run_dir))
    Handler.quiet = not args.verbose
    bind = "0.0.0.0" if args.lan else "127.0.0.1"
    httpd = http.server.ThreadingHTTPServer((bind, args.port), Handler)
    httpd.daemon_threads = True
    print("tombolo latency server: clock CLOCK_UPTIME_RAW (mach_absolute_time domain), now %d ns" % now_ns(), flush=True)
    print("run dir: %s" % Handler.state.run_dir, flush=True)
    print("page:    http://127.0.0.1:%d/" % args.port, flush=True)
    if args.lan:
        for a in lan_addresses():
            print("         http://%s:%d/   (phone on the same network)" % (a, args.port), flush=True)
    try:
        httpd.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
