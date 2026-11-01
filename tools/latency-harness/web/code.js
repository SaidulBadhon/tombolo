// SPDX-License-Identifier: GPL-3.0-or-later
//
// TLC1 encoder ("Tombolo latency code", version 1) — JavaScript twin of
// Sources/LatencyCore/CodeLayout.swift. Keep the two in sync: JSParityTests (swift test) loads this
// file into JavaScriptCore and compares module matrices with the Swift encoder.
//
// Plain script (no modules) so that it works from a <script> tag and inside JavaScriptCore.

var TLC = (function () {
  "use strict";
  var W = 32, H = 16;
  var KIND_PAGE = 0, KIND_MAC = 1, KIND_SYNTHETIC = 2;
  var MASK = [0x9e, 0x37, 0x79, 0xb9, 0x7f, 0x4a, 0x7c, 0x15];
  var FINDER_ORIGINS = [[0, 0], [25, 0], [25, 9], [0, 9]];

  // CRC-24/OpenPGP over an array of bytes.
  function crc24(bytes) {
    var crc = 0xb704ce;
    for (var i = 0; i < bytes.length; i++) {
      crc ^= (bytes[i] & 0xff) << 16;
      for (var b = 0; b < 8; b++) {
        crc <<= 1;
        if (crc & 0x1000000) crc ^= 0x1864cfb;
      }
    }
    return crc & 0xffffff;
  }

  // 100 µs ticks, modulo 2^32, for a time in milliseconds.
  function ticksFromMs(ms) {
    var t = Math.round(ms * 10) % 4294967296;
    if (t < 0) t += 4294967296;
    return t;
  }

  // 64 data bits (index 0 = most significant), mask applied; 1 = black.
  function encodeBits(kind, session, ticks) {
    ticks = ticks >>> 0;
    var bytes = [
      ((kind & 15) << 4) | (session & 15),
      (ticks >>> 24) & 255, (ticks >>> 16) & 255, (ticks >>> 8) & 255, ticks & 255,
    ];
    var crc = crc24(bytes);
    bytes.push((crc >>> 16) & 255, (crc >>> 8) & 255, crc & 255);
    var bits = new Array(64);
    for (var i = 0; i < 64; i++) {
      var byte = bytes[i >> 3] ^ MASK[i >> 3];
      bits[i] = (byte >> (7 - (i & 7))) & 1;
    }
    return bits;
  }

  // Row-major 32 × 16 module matrix (1 = black) for the given data bits.
  function modules(bits) {
    var m = new Array(W * H);
    for (var i = 0; i < m.length; i++) m[i] = 0;
    for (var f = 0; f < 4; f++) {
      var ox = FINDER_ORIGINS[f][0], oy = FINDER_ORIGINS[f][1];
      for (var dy = 0; dy < 7; dy++) {
        for (var dx = 0; dx < 7; dx++) {
          var d = Math.max(Math.abs(dx - 3), Math.abs(dy - 3));
          if (d !== 2) m[(oy + dy) * W + ox + dx] = 1;
        }
      }
    }
    for (var k = 0; k < 64; k++) {
      if (!bits[k]) continue;
      var c = k % 8, r = (k / 8) | 0;
      var x0 = 8 + 2 * c, y0 = 2 * r;
      m[y0 * W + x0] = 1; m[y0 * W + x0 + 1] = 1;
      m[(y0 + 1) * W + x0] = 1; m[(y0 + 1) * W + x0 + 1] = 1;
    }
    return m;
  }

  // Draws the symbol (including its 2-module quiet zone) with its top-left corner at (x, y) in a
  // 2D canvas context, using an integer module size in device pixels.
  function draw(ctx, x, y, moduleSize, mods) {
    var q = 2;
    ctx.fillStyle = "#fff";
    ctx.fillRect(x, y, (W + 2 * q) * moduleSize, (H + 2 * q) * moduleSize);
    ctx.fillStyle = "#000";
    for (var my = 0; my < H; my++) {
      var mx = 0;
      while (mx < W) {
        if (!mods[my * W + mx]) { mx++; continue; }
        var start = mx;
        while (mx < W && mods[my * W + mx]) mx++;
        ctx.fillRect(x + (start + q) * moduleSize, y + (my + q) * moduleSize, (mx - start) * moduleSize, moduleSize);
      }
    }
  }

  return {
    W: W, H: H, QUIET: 2,
    KIND_PAGE: KIND_PAGE, KIND_MAC: KIND_MAC, KIND_SYNTHETIC: KIND_SYNTHETIC,
    crc24: crc24, ticksFromMs: ticksFromMs, encodeBits: encodeBits, modules: modules, draw: draw,
  };
})();
