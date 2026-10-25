// SPDX-License-Identifier: GPL-3.0-or-later
//
// TLC1 decoder.
//
// 1. Binarise (global Otsu; tile-adaptive fallback for unevenly lit camera frames).
// 2. Find finder patterns: scan rows for 1:1:3:1:1 black/white runs, cross-check vertically and
//    horizontally, cluster the hits.
// 3. Group four finders of similar module size whose quadrilateral has the symbol's 25 : 9 side
//    ratio; for each candidate corner assignment (rotations and mirror images) build the
//    homography module-space → image and sample the 64 data cells.
// 4. Accept only when the CRC-24 matches. Wrong orientations and torn/mid-transition frames fail
//    the CRC and are reported as "no decode", never as a wrong value.
//
// `CodeDecoder` adds tracking: the previous frame's homographies are tried first, which makes the
// common case (symbol has not moved) cost 64 × 5 bilinear samples.

import Foundation

public struct Detection: Sendable {
    public var payload: CodePayload
    /// Module coordinates → image coordinates.
    public var homography: Homography
    public var centreX: Double
    public var centreY: Double
    /// Mean module size in pixels (from the TL–TR finder distance).
    public var moduleSize: Double
    /// Smallest |cell − threshold| / contrast over the 64 cells (0 … 0.5).
    public var confidence: Double
    /// Mean white − black level measured on the finders (grey levels).
    public var contrast: Double
}

public struct DecoderOptions: Sendable {
    /// How many symbols the caller expects per frame. Tracking skips full detection only when at
    /// least this many symbols decode from the previous frame's positions.
    public var expectedSymbols: Int = 1
    /// Scan every n-th row for finder patterns.
    public var rowStep: Int = 1
    /// Keep at most this many finder clusters (strongest first) for grouping.
    public var maxClusters: Int = 24
    /// Retry with the tile-adaptive binariser when Otsu finds fewer symbols than expected.
    public var tryAdaptive: Bool = true
    /// Minimum finder contrast (white − black), grey levels.
    public var minContrast: Double = 20

    public init(expectedSymbols: Int = 1, rowStep: Int = 1, tryAdaptive: Bool = true) {
        self.expectedSymbols = expectedSymbols
        self.rowStep = rowStep
        self.tryAdaptive = tryAdaptive
    }
}

/// Stateful decoder with frame-to-frame tracking. Not thread-safe; use one per stream.
public final class CodeDecoder {
    public var options: DecoderOptions
    public private(set) var hints: [Homography] = []
    public private(set) var lastUsedFullDetection = false

    public init(options: DecoderOptions = DecoderOptions()) {
        self.options = options
    }

    public func reset() { hints = [] }

    public func decode(_ view: GrayView) -> [Detection] {
        var out: [Detection] = []
        for h in hints {
            if let d = CodeReader.read(view, homography: h, minContrast: options.minContrast) { out.append(d) }
        }
        lastUsedFullDetection = false
        if !out.isEmpty, out.count >= options.expectedSymbols {
            hints = out.map(\.homography)
            return out
        }
        lastUsedFullDetection = true
        for d in CodeReader.detect(view, options: options) where !out.contains(where: { $0.overlaps(d) }) {
            out.append(d)
        }
        if !out.isEmpty { hints = out.map(\.homography) }
        return out
    }
}

extension Detection {
    func overlaps(_ o: Detection) -> Bool {
        let dx = centreX - o.centreX, dy = centreY - o.centreY
        let r = 8 * max(moduleSize, o.moduleSize)
        return dx * dx + dy * dy < r * r
    }
}

public enum CodeReader {
    // MARK: - Public entry points

    /// Full, stateless detection of every symbol in the image.
    public static func detect(_ view: GrayView, options: DecoderOptions = DecoderOptions()) -> [Detection] {
        guard view.width >= 16, view.height >= 8 else { return [] }
        var found = detect(view, binary: binarizeOtsu(view), options: options)
        if found.count < options.expectedSymbols, options.tryAdaptive {
            for d in detect(view, binary: binarizeAdaptive(view), options: options) where !found.contains(where: { $0.overlaps(d) }) {
                found.append(d)
            }
        }
        return found
    }

    /// Samples the data cells through a known homography and validates the CRC.
    public static func read(_ v: GrayView, homography h: Homography, minContrast: Double = 20) -> Detection? {
        let w = Double(v.width), hh = Double(v.height)
        // Whole symbol must be inside the image (1 px slack).
        for (x, y) in [(0.0, 0.0), (32.0, 0.0), (32.0, 16.0), (0.0, 16.0)] {
            let p = h.apply(x, y)
            guard p.x.isFinite, p.y.isFinite, p.x >= -1, p.y >= -1, p.x <= w + 1, p.y <= hh + 1 else { return nil }
        }
        // Per-finder black (3 × 3 core) and white (inner ring) references.
        var thr = [Double](repeating: 0, count: 4)
        var con = [Double](repeating: 0, count: 4)
        for (i, c) in CodeLayout.finderCentres.enumerated() {
            var black = 0.0
            for (dx, dy) in [(0.0, 0.0), (-0.7, -0.7), (0.7, -0.7), (0.7, 0.7), (-0.7, 0.7)] {
                let p = h.apply(c.x + dx, c.y + dy)
                black += v.sample(p.x, p.y)
            }
            black /= 5
            var white = 0.0
            for (dx, dy) in [(-2.0, 0.0), (2.0, 0.0), (0.0, -2.0), (0.0, 2.0), (-2.0, -2.0), (2.0, 2.0), (-2.0, 2.0), (2.0, -2.0)] {
                let p = h.apply(c.x + dx, c.y + dy)
                white += v.sample(p.x, p.y)
            }
            white /= 8
            con[i] = white - black
            thr[i] = (white + black) / 2
        }
        let contrast = con.reduce(0, +) / 4
        guard con.min()! >= minContrast * 0.5, contrast >= minContrast else { return nil }

        var bits = [Bool](repeating: false, count: CodeLayout.bitCount)
        var minMargin = Double.infinity
        let offsets = [(0.0, 0.0), (-0.45, -0.45), (0.45, -0.45), (0.45, 0.45), (-0.45, 0.45)]
        for k in 0..<CodeLayout.bitCount {
            let c = CodeLayout.cellCentre(k)
            var s = 0.0
            for (dx, dy) in offsets {
                let p = h.apply(c.x + dx, c.y + dy)
                s += v.sample(p.x, p.y)
            }
            s /= Double(offsets.count)
            // Bilinear interpolation of the four finder thresholds across the symbol.
            let tx = min(max((c.x - 3.5) / 25, 0), 1), ty = min(max((c.y - 3.5) / 9, 0), 1)
            let t = (thr[0] * (1 - tx) + thr[1] * tx) * (1 - ty) + (thr[3] * (1 - tx) + thr[2] * tx) * ty
            let cc = (con[0] * (1 - tx) + con[1] * tx) * (1 - ty) + (con[3] * (1 - tx) + con[2] * tx) * ty
            bits[k] = s < t
            minMargin = min(minMargin, abs(s - t) / max(cc, 1))
        }
        guard let payload = CodeLayout.payload(fromBits: bits) else { return nil }
        let tl = h.apply(3.5, 3.5), tr = h.apply(28.5, 3.5)
        let module = ((tr.x - tl.x) * (tr.x - tl.x) + (tr.y - tl.y) * (tr.y - tl.y)).squareRoot() / 25
        let centre = h.apply(16, 8)
        return Detection(payload: payload, homography: h, centreX: centre.x, centreY: centre.y,
                         moduleSize: module, confidence: minMargin, contrast: contrast)
    }

    // MARK: - Binarisation (1 = black)

    public static func otsuThreshold(_ v: GrayView) -> Int {
        var hist = [Int](repeating: 0, count: 256)
        let step = (v.width * v.height > 2_000_000) ? 2 : 1
        var n = 0
        for y in stride(from: 0, to: v.height, by: step) {
            let row = v.base + y * v.stride
            for x in stride(from: 0, to: v.width, by: step) { hist[Int(row[x])] += 1 }
            n += (v.width + step - 1) / step
        }
        var sumAll = 0.0
        for i in 0..<256 { sumAll += Double(i * hist[i]) }
        var sumB = 0.0, wB = 0.0, best = 0.0, thr = 128
        for t in 0..<256 {
            wB += Double(hist[t])
            if wB == 0 { continue }
            let wF = Double(n) - wB
            if wF == 0 { break }
            sumB += Double(t * hist[t])
            let mB = sumB / wB, mF = (sumAll - sumB) / wF
            let between = wB * wF * (mB - mF) * (mB - mF)
            if between > best { best = between; thr = t }
        }
        return thr
    }

    static func binarizeOtsu(_ v: GrayView) -> [UInt8] {
        let t = UInt8(clamping: otsuThreshold(v))
        var out = [UInt8](repeating: 0, count: v.width * v.height)
        out.withUnsafeMutableBufferPointer { dst in
            for y in 0..<v.height {
                let row = v.base + y * v.stride
                let o = y * v.width
                for x in 0..<v.width { dst[o + x] = row[x] <= t ? 1 : 0 }
            }
        }
        return out
    }

    /// Tile-based threshold: mid-range of each high-contrast tile, low-contrast tiles inherit from
    /// neighbours, then a 3 × 3 smoothing pass.
    static func binarizeAdaptive(_ v: GrayView) -> [UInt8] {
        let tile = max(16, min(v.width, v.height) / 8)
        let tx = (v.width + tile - 1) / tile, ty = (v.height + tile - 1) / tile
        var thr = [Double](repeating: -1, count: tx * ty)
        for j in 0..<ty {
            for i in 0..<tx {
                var lo = 255, hi = 0
                for y in (j * tile)..<min(v.height, (j + 1) * tile) {
                    let row = v.base + y * v.stride
                    for x in (i * tile)..<min(v.width, (i + 1) * tile) {
                        let p = Int(row[x])
                        if p < lo { lo = p }
                        if p > hi { hi = p }
                    }
                }
                if hi - lo >= 40 { thr[j * tx + i] = Double(lo + hi) / 2 }
            }
        }
        let global = Double(otsuThreshold(v))
        // Fill unknown tiles from known neighbours (a few dilation passes), else global.
        for _ in 0..<max(tx, ty) {
            var changed = false
            var next = thr
            for j in 0..<ty {
                for i in 0..<tx where thr[j * tx + i] < 0 {
                    var s = 0.0, n = 0.0
                    for (di, dj) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let a = i + di, b = j + dj
                        if a >= 0, a < tx, b >= 0, b < ty, thr[b * tx + a] >= 0 { s += thr[b * tx + a]; n += 1 }
                    }
                    if n > 0 { next[j * tx + i] = s / n; changed = true }
                }
            }
            thr = next
            if !changed { break }
        }
        for i in 0..<thr.count where thr[i] < 0 { thr[i] = global }
        var smooth = thr
        for j in 0..<ty {
            for i in 0..<tx {
                var s = 0.0, n = 0.0
                for dj in -1...1 {
                    for di in -1...1 {
                        let a = i + di, b = j + dj
                        if a >= 0, a < tx, b >= 0, b < ty { s += thr[b * tx + a]; n += 1 }
                    }
                }
                smooth[j * tx + i] = s / n
            }
        }
        var out = [UInt8](repeating: 0, count: v.width * v.height)
        for y in 0..<v.height {
            let row = v.base + y * v.stride
            let j = y / tile
            for x in 0..<v.width {
                out[y * v.width + x] = Double(row[x]) <= smooth[j * tx + x / tile] ? 1 : 0
            }
        }
        return out
    }

    // MARK: - Finder detection

    struct Finder {
        var x: Double
        var y: Double
        var module: Double
        var count: Int
    }

    @inline(__always) static func ratioOK(_ r0: Int, _ r1: Int, _ r2: Int, _ r3: Int, _ r4: Int, tolerance: Double = 0.6) -> Double? {
        let total = r0 + r1 + r2 + r3 + r4
        guard total >= 7, r2 >= r1, r2 >= r3 else { return nil }
        let m = Double(total) / 7
        let tol = max(m * tolerance, 0.75)
        guard abs(Double(r0) - m) < tol, abs(Double(r1) - m) < tol,
              abs(Double(r2) - 3 * m) < 3 * tol,
              abs(Double(r3) - m) < tol, abs(Double(r4) - m) < tol else { return nil }
        return m
    }

    @inline(__always) static func ratioOK(_ r: [Int]) -> Double? {
        ratioOK(r[0], r[1], r[2], r[3], r[4])
    }

    /// Runs outward from (x, y) along one axis; returns the five run lengths and the centre of the
    /// middle run, or nil.
    static func crossCheck(_ bin: [UInt8], _ w: Int, _ h: Int, x: Int, y: Int, vertical: Bool, maxRun: Int) -> (runs: [Int], centre: Double)? {
        let len = vertical ? h : w
        let pos = vertical ? y : x
        @inline(__always) func at(_ p: Int) -> UInt8 { vertical ? bin[p * w + x] : bin[y * w + p] }
        guard pos >= 0, pos < len, at(pos) == 1 else { return nil }
        var c = [0, 0, 0, 0, 0]
        var p = pos
        while p >= 0, at(p) == 1 { c[2] += 1; p -= 1 }
        let centreStart = p + 1
        guard p >= 0 else { return nil }
        while p >= 0, at(p) == 0, c[1] <= maxRun { c[1] += 1; p -= 1 }
        guard p >= 0, c[1] <= maxRun else { return nil }
        while p >= 0, at(p) == 1, c[0] <= maxRun { c[0] += 1; p -= 1 }
        guard c[0] <= maxRun else { return nil }
        p = pos + 1
        while p < len, at(p) == 1 { c[2] += 1; p += 1 }
        let centreEnd = p
        guard p < len else { return nil }
        while p < len, at(p) == 0, c[3] <= maxRun { c[3] += 1; p += 1 }
        guard p < len, c[3] <= maxRun else { return nil }
        while p < len, at(p) == 1, c[4] <= maxRun { c[4] += 1; p += 1 }
        guard c[4] <= maxRun else { return nil }
        return (c, Double(centreStart + centreEnd) / 2)
    }

    static func findFinders(_ bin: [UInt8], _ w: Int, _ h: Int, rowStep: Int) -> [Finder] {
        var raw: [Finder] = []
        var runLen = [Int](repeating: 0, count: w + 1)
        var runStart = [Int](repeating: 0, count: w + 1)
        var runColour = [UInt8](repeating: 0, count: w + 1)
        for y in stride(from: 0, to: h, by: max(1, rowStep)) {
            var n = 0
            var x = 0
            let o = y * w
            while x < w {
                let col = bin[o + x]
                let s = x
                while x < w, bin[o + x] == col { x += 1 }
                runColour[n] = col; runStart[n] = s; runLen[n] = x - s
                n += 1
            }
            guard n >= 5 else { continue }
            for i in 0...(n - 5) where runColour[i] == 1 {
                guard let m = ratioOK(runLen[i], runLen[i + 1], runLen[i + 2], runLen[i + 3], runLen[i + 4]) else { continue }
                let total = runLen[i] + runLen[i + 1] + runLen[i + 2] + runLen[i + 3] + runLen[i + 4]
                let cx = Double(runStart[i + 2]) + Double(runLen[i + 2]) / 2
                let maxRun = Int(Double(total) * 1.5) + 2
                guard let v = crossCheck(bin, w, h, x: Int(cx), y: y, vertical: true, maxRun: maxRun),
                      let mv = ratioOK(v.runs) else { continue }
                // Vertical and horizontal sizes must roughly agree (tolerates perspective).
                let ratio = mv / m
                guard ratio > 0.5, ratio < 2.0 else { continue }
                let cy = v.centre
                guard let hr = crossCheck(bin, w, h, x: Int(cx), y: Int(cy), vertical: false, maxRun: maxRun),
                      let mh = ratioOK(hr.runs) else { continue }
                raw.append(Finder(x: hr.centre, y: cy, module: (mh + mv) / 2, count: 1))
            }
        }
        // Cluster.
        var clusters: [Finder] = []
        for f in raw {
            var merged = false
            for i in clusters.indices {
                let c = clusters[i]
                let d = max(2 * c.module, 3)
                let r = f.module / c.module
                if abs(f.x - c.x) < d, abs(f.y - c.y) < d, r > 0.6, r < 1.67 {
                    let n = Double(c.count)
                    clusters[i].x = (c.x * n + f.x) / (n + 1)
                    clusters[i].y = (c.y * n + f.y) / (n + 1)
                    clusters[i].module = (c.module * n + f.module) / (n + 1)
                    clusters[i].count += 1
                    merged = true
                    break
                }
            }
            if !merged { clusters.append(f) }
        }
        return clusters
    }

    // MARK: - Grouping

    static func detect(_ v: GrayView, binary bin: [UInt8], options: DecoderOptions) -> [Detection] {
        var finders = findFinders(bin, v.width, v.height, rowStep: options.rowStep)
        finders.sort { $0.count > $1.count }
        if finders.count > options.maxClusters { finders.removeLast(finders.count - options.maxClusters) }
        let n = finders.count
        guard n >= 4 else { return [] }
        var used = [Bool](repeating: false, count: n)
        var out: [Detection] = []
        let target = (CodeLayout.finderCentres.map { (x: $0.x, y: $0.y) })

        for a in 0..<n where !used[a] {
            for b in (a + 1)..<n where !used[b] && !used[a] {
                for c in (b + 1)..<n where !used[c] && !used[a] && !used[b] {
                    for d in (c + 1)..<n where !used[d] && !used[a] && !used[b] && !used[c] {
                        let idx = [a, b, c, d]
                        let mods = idx.map { finders[$0].module }
                        guard mods.max()! / mods.min()! < 1.7 else { continue }
                        // Order by angle around the centroid.
                        let cx = idx.map { finders[$0].x }.reduce(0, +) / 4
                        let cy = idx.map { finders[$0].y }.reduce(0, +) / 4
                        let ordered = idx.sorted {
                            atan2(finders[$0].y - cy, finders[$0].x - cx) < atan2(finders[$1].y - cy, finders[$1].x - cx)
                        }
                        let pts = ordered.map { (x: finders[$0].x, y: finders[$0].y) }
                        guard isConvex(pts) else { continue }
                        let meanModule = mods.reduce(0, +) / 4
                        if let det = tryAssignments(v, pts: pts, target: target, meanModule: meanModule, minContrast: options.minContrast) {
                            out.append(det)
                            for i in idx { used[i] = true }
                        }
                    }
                }
            }
        }
        return out
    }

    static func isConvex(_ p: [(x: Double, y: Double)]) -> Bool {
        var sign = 0.0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) < 1e-9 { return false }
            if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { return false }
        }
        return true
    }

    static func tryAssignments(_ v: GrayView, pts: [(x: Double, y: Double)], target: [(x: Double, y: Double)],
                               meanModule: Double, minContrast: Double) -> Detection? {
        @inline(__always) func dist(_ p: (x: Double, y: Double), _ q: (x: Double, y: Double)) -> Double {
            ((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)).squareRoot()
        }
        for dir in [1, -1] {
            for start in 0..<4 {
                // Candidate (TL, TR, BR, BL).
                let q = (0..<4).map { pts[((start + dir * $0) % 4 + 4) % 4] }
                let top = dist(q[0], q[1]), right = dist(q[1], q[2])
                let bottom = dist(q[2], q[3]), left = dist(q[3], q[0])
                let r1 = top / left, r2 = bottom / right
                guard r1 > 1.5, r1 < 5.5, r2 > 1.5, r2 < 5.5 else { continue }
                guard top / bottom > 0.5, top / bottom < 2, left / right > 0.5, left / right < 2 else { continue }
                let geomModule = (top + bottom) / 50
                guard geomModule / meanModule > 0.55, geomModule / meanModule < 1.8 else { continue }
                guard let h = Homography.fromPoints(target, q) else { continue }
                if let det = read(v, homography: h, minContrast: minContrast) { return det }
            }
        }
        return nil
    }
}
