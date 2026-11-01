// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tombolo latency page — the content that gets mirrored.
//
// * Every animation frame draws the frame's requestAnimationFrame timestamp (page clock =
//   performance.now(), 100 µs ticks) as a TLC1 symbol plus a human-readable counter.
// * In the background it measures the offset between the page clock and the Mac clock with
//   repeated GET /time round trips and posts the raw samples to the server (POST /log), which
//   writes them to <run-dir>/sync.jsonl for offline analysis.
//
// Query parameters: sync=<ms between round trips, default 250>, title=<suffix for the window title>.

(function () {
  "use strict";
  var params = new URLSearchParams(location.search);
  var syncInterval = Math.max(50, Number(params.get("sync") || 250));
  if (params.get("title")) document.title = "Tombolo latency page " + params.get("title");

  var rnd = new Uint32Array(1);
  crypto.getRandomValues(rnd);
  var session = rnd[0] >>> 0;
  var sessionHex = ("00000000" + session.toString(16)).slice(-8);

  var canvas = document.getElementById("c");
  var ctx = canvas.getContext("2d", { alpha: false, desynchronized: false });
  var dpr = 1, W = 0, H = 0, mod = 4, sx = 0, sy = 0;

  function layout() {
    dpr = window.devicePixelRatio || 1;
    W = Math.round(window.innerWidth * dpr);
    H = Math.round(window.innerHeight * dpr);
    canvas.width = W;
    canvas.height = H;
    // 36 × 20 modules including the quiet zone; integer device pixels per module.
    mod = Math.max(2, Math.floor(Math.min(W * 0.94 / 36, H * 0.5 / 20)));
    sx = Math.floor((W - 36 * mod) / 2);
    sy = Math.floor(H * 0.04);
    ctx.fillStyle = "#fff";
    ctx.fillRect(0, 0, W, H);
  }
  window.addEventListener("resize", layout);
  layout();

  // ---- timer resolution -------------------------------------------------------------------
  function timerResolution() {
    var best = Infinity, last = performance.now(), changes = 0;
    for (var i = 0; i < 200000 && changes < 50; i++) {
      var t = performance.now();
      if (t !== last) { best = Math.min(best, t - last); last = t; changes++; }
    }
    return best;
  }
  var timerRes = timerResolution();

  // ---- clock sync -------------------------------------------------------------------------
  var pending = [], recent = [], syncErrors = 0, lastError = "";
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function syncOnce() {
    var t0 = performance.now();
    return fetch("/time", { cache: "no-store" }).then(function (r) {
      var t3 = performance.now();
      return r.json().then(function (j) {
        var s = [t0, t3, j.recv_ns, j.send_ns];
        pending.push(s);
        recent.push(s);
        if (recent.length > 400) recent.shift();
      });
    }).catch(function (e) { syncErrors++; lastError = String(e); });
  }
  async function syncLoop() {
    for (var i = 0; i < 64; i++) await syncOnce();
    for (;;) { await sleep(syncInterval); await syncOnce(); }
  }
  function post(obj) {
    return fetch("/log", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(obj), keepalive: true })
      .catch(function (e) { syncErrors++; lastError = String(e); });
  }
  function flush() {
    if (pending.length) post({ type: "sync", session: session, samples: pending.splice(0) });
  }
  // Live estimate for the status line only (the analysis refits from the raw samples).
  function liveEstimate() {
    var best = null;
    for (var i = 0; i < recent.length; i++) {
      var s = recent[i];
      var rtt = (s[1] - s[0]) - (s[3] - s[2]) / 1e6;
      if (!best || rtt < best.rtt) best = { rtt: rtt, off: ((s[2] / 1e6 - s[0]) + (s[3] / 1e6 - s[1])) / 2 };
    }
    return best;
  }

  // ---- frame pacing stats -------------------------------------------------------------------
  var intervals = [], lastTs = 0, frames = 0, late = 0;
  function medianInterval() {
    if (!intervals.length) return 0;
    var a = intervals.slice().sort(function (x, y) { return x - y; });
    return a[a.length >> 1];
  }
  function postInfo() {
    post({ type: "info", session: session, info: {
      user_agent: navigator.userAgent, device_pixel_ratio: dpr, screen: screen.width + "x" + screen.height,
      viewport_px: W + "x" + H, module_px: mod, timer_resolution_ms: timerRes,
      raf_interval_ms_median: medianInterval(), frames: frames, late_frames: late,
      cross_origin_isolated: !!window.crossOriginIsolated, secure_context: !!window.isSecureContext,
      sync_interval_ms: syncInterval, sync_errors: syncErrors,
    } });
  }

  // ---- render ---------------------------------------------------------------------------------
  var status1 = "", status2 = "", statusAt = 0;
  function frame(ts) {
    if (lastTs) {
      var d = ts - lastTs;
      intervals.push(d);
      if (intervals.length > 240) intervals.shift();
      var med = medianInterval();
      if (med && d > 1.5 * med) late++;
    }
    lastTs = ts;
    frames++;

    var ticks = TLC.ticksFromMs(ts);
    TLC.draw(ctx, sx, sy, mod, TLC.modules(TLC.encodeBits(TLC.KIND_PAGE, session & 15, ticks)));

    var ty = sy + 20 * mod + Math.round(mod * 1.5);
    var big = Math.max(12, Math.round(mod * 3.2));
    ctx.fillStyle = "#fff";
    ctx.fillRect(0, ty, W, H - ty);
    ctx.fillStyle = "#000";
    ctx.textBaseline = "top";
    ctx.font = "bold " + big + "px ui-monospace, Menlo, monospace";
    ctx.fillText((ticks / 10).toFixed(1) + " ms", sx, ty);

    if (ts - statusAt > 250) {
      statusAt = ts;
      var e = liveEstimate();
      var med = medianInterval();
      status1 = e ? "sync: Mac−page " + e.off.toFixed(2) + " ms ± " + (e.rtt / 2).toFixed(2) + " (best RTT " + e.rtt.toFixed(2) + ")" : "sync: waiting for server";
      if (syncErrors) status1 += " · errors " + syncErrors + " " + lastError;
      status2 = "session " + sessionHex + " · " + (med ? (1000 / med).toFixed(1) : "–") + " fps · late " + late +
        " · timer " + timerRes.toFixed(3) + " ms · module " + mod + " px";
    }
    var small = Math.max(10, Math.round(mod * 1.1));
    ctx.font = small + "px ui-monospace, Menlo, monospace";
    ctx.fillText(status1, sx, ty + big * 1.4);
    ctx.fillText(status2, sx, ty + big * 1.4 + small * 1.4);
    ctx.fillText("tap: fullscreen + keep screen on", sx, ty + big * 1.4 + small * 2.8);

    requestAnimationFrame(frame);
  }

  canvas.addEventListener("click", function () {
    var el = document.documentElement;
    if (!document.fullscreenElement && el.requestFullscreen) el.requestFullscreen().catch(function () {});
    if (navigator.wakeLock) navigator.wakeLock.request("screen").catch(function () {});
  });

  requestAnimationFrame(frame);
  syncLoop();
  setInterval(flush, 2000);
  setTimeout(postInfo, 3000);
  setInterval(postInfo, 10000);
  document.addEventListener("visibilitychange", function () { if (document.hidden) { flush(); postInfo(); } });
})();
