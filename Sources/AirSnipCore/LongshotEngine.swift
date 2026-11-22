import Foundation
import CoreGraphics

public struct LongshotParams: Equatable, Sendable {
    public var minRatio: Double
    public var minFixedRows: Int

    public init(minRatio: Double = 0.88, minFixedRows: Int = 8) {
        self.minRatio = minRatio
        self.minFixedRows = minFixedRows
    }
}

public struct LongshotMatch: Equatable, Sendable {
    /// >0 scrolled down (content moved up); <0 scrolled up (content moved down); 0 still
    public var offset: Int
    /// Inclusive start, exclusive end row in `new` frame to append/prepend
    public var startRow: Int
    public var endRow: Int
    public var confident: Bool
    /// Number of trailing overlap rows to refresh in-place when dynamic/lazy-loaded bottom content finished rendering
    public var overlapRefreshRows: Int

    public init(offset: Int, startRow: Int, endRow: Int, confident: Bool, overlapRefreshRows: Int = 0) {
        self.offset = offset
        self.startRow = startRow
        self.endRow = endRow
        self.confident = confident
        self.overlapRefreshRows = overlapRefreshRows
    }
}

/// Multi-bin perceptual horizontal row signatures (RGB block averages in 1/8-unit fixed point + horizontal edge contrast).
/// Resilient to macOS Retina ColorSync/compositor subpixel noise, right-edge scrollbars, fixed sidebars, and animated avatars,
/// while remaining strict against false matches on sparse white webpages.
struct RowSignatures: Sendable {
    let width: Int
    let height: Int
    let binCount: Int
    let startX: Int
    let endX: Int
    /// Packed `[r8, g8, b8, edge8]` (`UInt16`, 1/8 RGB scale `0..2040`) of length `height * binCount * 4`
    let data: [UInt16]
    /// Per-row dominant background deviation count (how many bins deviate from the row's median/edge tint, used to detect structured rows)
    let structuredBinCount: [UInt8]

    init(rgba: [UInt8], width: Int, height: Int, startX: Int? = nil, endX: Int? = nil) {
        self.width = width
        self.height = height
        guard width > 0, height > 0, rgba.count >= width * height * 4 else {
            self.binCount = 0
            self.startX = 0
            self.endX = 0
            self.data = []
            self.structuredBinCount = []
            return
        }

        let margin = LongshotStitcher.defaultHorizontalMargin(forWidth: width)
        let x0 = max(0, min(width - 1, startX ?? margin))
        let x1 = max(x0 + 1, min(width, endX ?? (width - margin)))
        let innerW = x1 - x0
        let bins = min(32, max(4, innerW / 4))

        self.startX = x0
        self.endX = x1
        self.binCount = bins

        var out = [UInt16](repeating: 0, count: height * bins * 4)
        var structCounts = [UInt8](repeating: 0, count: height)
        let stride = width * 4

        // Precompute `[bx0, bx1, xStep]` per bin
        var binRanges: [(bx0: Int, bx1: Int, step: Int)] = []
        binRanges.reserveCapacity(bins)
        for b in 0..<bins {
            let bx0 = x0 + (b * innerW) / bins
            let bx1 = max(bx0 + 1, x0 + ((b + 1) * innerW) / bins)
            let bw = bx1 - bx0
            let step = max(1, bw / 32)
            binRanges.append((bx0, bx1, step))
        }

        rgba.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            for y in 0..<height {
                let rowPtr = base.advanced(by: y * stride)
                let rowOutBase = y * bins * 4

                for b in 0..<bins {
                    let range = binRanges[b]
                    var rSum = 0
                    var gSum = 0
                    var bSum = 0
                    var edgeSum = 0
                    var samples = 0
                    var prevR = 0
                    var prevG = 0
                    var prevB = 0

                    var x = range.bx0
                    while x < range.bx1 {
                        let o = x * 4
                        let cr = Int(rowPtr[o])
                        let cg = Int(rowPtr[o + 1])
                        let cb = Int(rowPtr[o + 2])
                        rSum += cr
                        gSum += cg
                        bSum += cb
                        if samples > 0 {
                            edgeSum += abs(cr - prevR) + abs(cg - prevG) + abs(cb - prevB)
                        }
                        prevR = cr
                        prevG = cg
                        prevB = cb
                        samples += 1
                        x += range.step
                    }

                    let dst = rowOutBase + b * 4
                    if samples > 0 {
                        out[dst] = UInt16((rSum * 8) / samples)
                        out[dst + 1] = UInt16((gSum * 8) / samples)
                        out[dst + 2] = UInt16((bSum * 8) / samples)
                        let edgeDenom = max(1, samples - 1) * 3
                        out[dst + 3] = UInt16(min(2040, (edgeSum * 8) / edgeDenom))
                    }
                }

                // Count how many bins on this row contain visual structure (either internal crisp edges or color distinct from row endpoints)
                let refIdx0 = rowOutBase
                let refIdx1 = rowOutBase + (bins - 1) * 4
                let bgR = (Int(out[refIdx0]) + Int(out[refIdx1])) / 2
                let bgG = (Int(out[refIdx0 + 1]) + Int(out[refIdx1 + 1])) / 2
                let bgB = (Int(out[refIdx0 + 2]) + Int(out[refIdx1 + 2])) / 2
                var sc: UInt8 = 0
                for b in 0..<bins {
                    let idx = rowOutBase + b * 4
                    let dev = abs(Int(out[idx]) - bgR) + abs(Int(out[idx + 1]) - bgG) + abs(Int(out[idx + 2]) - bgB)
                    // > ~6 RGB channel sum deviation (`6 * 8 = 48`) or internal edge contrast > ~3 RGB (`24`)
                    if dev > 64 || out[idx + 3] > 24 {
                        sc &+= 1
                    }
                }
                structCounts[y] = sc
            }
        }

        self.data = out
        self.structuredBinCount = structCounts
    }

    /// Mean per-channel RGB difference (in `0..255` scale) between `self[rowA]` and `other[rowB]` across `bins`.
    @inline(__always)
    func rowDiff(rowA: Int, other: RowSignatures, rowB: Int, bins: [Int]) -> Double {
        guard !bins.isEmpty else { return 255.0 }
        let baseA = rowA * binCount * 4
        let baseB = rowB * other.binCount * 4
        var diff8 = 0
        for b in bins {
            let ia = baseA + b * 4
            let ib = baseB + b * 4
            diff8 += abs(Int(data[ia]) - Int(other.data[ib]))
            diff8 += abs(Int(data[ia + 1]) - Int(other.data[ib + 1]))
            diff8 += abs(Int(data[ia + 2]) - Int(other.data[ib + 2]))
        }
        return Double(diff8) / Double(bins.count * 24)
    }

    /// Perceptual row match across `bins`: tolerates ±3.5 RGB subpixel noise everywhere, and allows 1–2 outlier bins
    /// (e.g. animated user avatar) ONLY when at least 3 other matching bins carry real horizontal visual structure.
    @inline(__always)
    func rowsMatch(rowA: Int, other: RowSignatures, rowB: Int, bins: [Int]) -> Bool {
        let count = bins.count
        guard count > 0 else { return false }
        let baseA = rowA * binCount * 4
        let baseB = rowB * other.binCount * 4

        // Per-bin threshold in 1/8 RGB units summed across R+G+B (`24` = 1.0 RGB/channel; `216` = 9.0 RGB/channel sum = 3.0 RGB avg/channel)
        let binRGBTol8 = 216
        let binEdgeTol8 = 96

        let refA0 = baseA + bins[0] * 4
        let refA1 = baseA + bins[count - 1] * 4
        let bgR = (Int(data[refA0]) + Int(data[refA1])) / 2
        let bgG = (Int(data[refA0 + 1]) + Int(data[refA1 + 1])) / 2
        let bgB = (Int(data[refA0 + 2]) + Int(data[refA1 + 2])) / 2

        var outlierBins = 0
        var structuredMatchingBins = 0
        var matchedDiffSum8 = 0
        let hardMaxOutliers = count >= 16 ? max(1, count / 12) : 0

        for b in bins {
            let ia = baseA + b * 4
            let ib = baseB + b * 4
            let dr = abs(Int(data[ia]) - Int(other.data[ib]))
            let dg = abs(Int(data[ia + 1]) - Int(other.data[ib + 1]))
            let db = abs(Int(data[ia + 2]) - Int(other.data[ib + 2]))
            let de = abs(Int(data[ia + 3]) - Int(other.data[ib + 3]))
            let rgbDiff = dr + dg + db

            if rgbDiff <= binRGBTol8 && de <= binEdgeTol8 {
                matchedDiffSum8 += rgbDiff
                let dev = abs(Int(data[ia]) - bgR) + abs(Int(data[ia + 1]) - bgG) + abs(Int(data[ia + 2]) - bgB)
                if dev > 64 || data[ia + 3] > 24 {
                    structuredMatchingBins += 1
                }
            } else {
                outlierBins += 1
                if outlierBins > hardMaxOutliers {
                    return false
                }
            }
        }

        if outlierBins > 0 && structuredMatchingBins < 3 {
            // Prevent a short 1-2 word line on a white page from ever falsely matching a blank white row!
            return false
        }

        let matchedCount = max(1, count - outlierBins)
        // Average per-channel diff across matching bins must be <= ~1.8 RGB (`1.8 * 24 = 43.2`)
        return matchedDiffSum8 <= matchedCount * 44
    }

    /// True if row `y` differs perceptually from row `y - 1` in at least one active bin (marks text/UI edges vs uniform background).
    @inline(__always)
    func isVerticalFeature(row y: Int, bins: [Int]) -> Bool {
        guard y > 0, y < height, !bins.isEmpty else { return false }
        let curBase = y * binCount * 4
        let prevBase = (y - 1) * binCount * 4
        var sumDiff8 = 0
        for b in bins {
            let ic = curBase + b * 4
            let ip = prevBase + b * 4
            let d = abs(Int(data[ic]) - Int(data[ip]))
                + abs(Int(data[ic + 1]) - Int(data[ip + 1]))
                + abs(Int(data[ic + 2]) - Int(data[ip + 2]))
            if d > 120 { // > 5.0 RGB/channel change in a single bin
                return true
            }
            sumDiff8 += d
        }
        return sumDiff8 > bins.count * 36 // > 1.5 RGB/channel change across the row
    }

    func samples(in rows: Range<Int>) -> ArraySlice<UInt16> {
        let stride = binCount * 4
        return data[(rows.lowerBound * stride)..<(rows.upperBound * stride)]
    }

    /// Finds a displacement supported by separate parts of the same scrolling content.
    func stableColumnsOffset(
        to next: RowSignatures, rows: Range<Int>, expectedOffset: Int? = nil, minRatio: Double
    ) -> Int? {
        let minimumOverlap = max(8, min(40, rows.count / 4))
        let maximumOffset = rows.count - minimumOverlap
        guard binCount == next.binCount, maximumOffset >= 0 else { return nil }
        let stripWidth = binCount >= 16 ? 4 : 2
        let stride = binCount * 4
        var stripVotes: [Int: [Int]] = [:]

        for start in Swift.stride(from: 0, to: binCount - stripWidth + 1, by: stripWidth) {
            let bins = Array(start..<(start + stripWidth))
            func uniqueFeatures(in signatures: RowSignatures) -> [ArraySlice<UInt16>: Int] {
                var features: [ArraySlice<UInt16>: Int] = [:]
                for row in rows.dropFirst() where signatures.isVerticalFeature(row: row, bins: bins) {
                    let lower = row * stride + start * 4
                    let key = signatures.data[lower..<(lower + stripWidth * 4)]
                    features[key] = features[key] == nil ? row : -1
                }
                return features
            }

            let before = uniqueFeatures(in: self)
            let after = uniqueFeatures(in: next)
            var featureVotes: [Int: Int] = [:]
            for (key, newRow) in after where newRow >= 0 {
                guard let oldRow = before[key], oldRow >= 0 else { continue }
                let offset = oldRow - newRow
                guard abs(offset) <= maximumOffset, expectedOffset == nil || expectedOffset == offset else { continue }
                featureVotes[offset, default: 0] += 1
            }

            for (offset, count) in featureVotes where count >= 4 {
                let oldStart = rows.lowerBound + max(0, offset)
                let newStart = rows.lowerBound + max(0, -offset)
                let overlap = rows.count - abs(offset)
                var matching = 0
                for row in 0..<overlap where rowsMatch(rowA: oldStart + row, other: next, rowB: newStart + row, bins: bins) {
                    matching += 1
                }
                if Double(matching) >= Double(overlap) * minRatio {
                    stripVotes[offset, default: []].append(start)
                }
            }
        }

        let offsets = stripVotes.filter { _, strips in
            guard strips.count >= 2, let left = strips.first, let right = strips.last else { return false }
            // Without an independent offset, a sidebar alone must not establish the body's movement.
            return expectedOffset != nil || right - left >= binCount / 2
        }.keys
        return offsets.count == 1 ? offsets.first : nil
    }

    /// Identifies horizontal bins belonging to the scrolling content area, automatically excluding static sidebars
    /// (including stationary sidebar pills/highlights) and wide empty margins when content columns moved.
    static func detectScrollingBins(prev: RowSignatures, next: RowSignatures, bandTop: Int, bandBottom: Int) -> [Int] {
        let bins = min(prev.binCount, next.binCount)
        guard bins > 0 else { return [] }
        let allBins = Array(0..<bins)
        let y0 = max(0, min(prev.height - 1, bandTop))
        let y1 = max(y0 + 1, min(prev.height, bandBottom))
        let span = y1 - y0
        guard bins >= 8, span >= 16 else { return allBins }

        let yStep = max(1, span / 96)
        var statDiffPerBin = [Double](repeating: 0, count: bins)
        var maxStatDiffPerBin = [Double](repeating: 0, count: bins)

        for b in 0..<bins {
            var statSum = 0
            var maxDiff = 0
            var count = 0
            var y = y0
            while y < y1 {
                let ip = (y * prev.binCount + b) * 4
                let inx = (y * next.binCount + b) * 4
                let d = abs(Int(prev.data[ip]) - Int(next.data[inx]))
                    + abs(Int(prev.data[ip + 1]) - Int(next.data[inx + 1]))
                    + abs(Int(prev.data[ip + 2]) - Int(next.data[inx + 2]))
                statSum += d
                if d > maxDiff { maxDiff = d }
                count += 1
                y += yStep
            }
            statDiffPerBin[b] = Double(statSum) / Double(max(1, count) * 24)
            maxStatDiffPerBin[b] = Double(maxDiff) / 24.0
        }

        let movingBins = allBins.filter { b in
            statDiffPerBin[b] > 1.8 || maxStatDiffPerBin[b] > 12.0
        }
        guard movingBins.count >= max(3, bins / 5) else {
            return allBins
        }
        return movingBins
    }
}

public enum LongshotStitcher {
    public static func rowHash(_ bytes: UnsafePointer<UInt8>, count: Int) -> UInt64 {
        let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        var h = offsetBasis
        let chunks = count / 8
        for c in 0..<chunks {
            var v: UInt64 = 0
            let base = c * 8
            for b in 0..<8 {
                v |= UInt64(bytes[base + b] & 0xFC) << (b * 8)
            }
            h = (h ^ v) &* prime
        }
        for i in (chunks * 8)..<count {
            h = (h ^ UInt64(bytes[i] & 0xFC)) &* prime
        }
        return h
    }

    public static func defaultHorizontalMargin(forWidth width: Int) -> Int {
        width >= 96 ? min(64, width / 12) : 0
    }

    public static func rowHashes(
        rgba: [UInt8],
        width: Int,
        height: Int,
        startX: Int? = nil,
        endX: Int? = nil
    ) -> [UInt64] {
        guard width > 0, height > 0 else { return [] }
        let stride = width * 4
        let margin = defaultHorizontalMargin(forWidth: width)
        let x0 = max(0, min(width - 1, startX ?? margin))
        let x1 = max(x0 + 1, min(width, endX ?? (width - margin)))
        let byteOffset = x0 * 4
        let byteCount = (x1 - x0) * 4

        var result = [UInt64](repeating: 0, count: height)
        rgba.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            for y in 0..<height {
                result[y] = rowHash(base.advanced(by: y * stride + byteOffset), count: byteCount)
            }
        }
        return result
    }

    static func hasVisualStructure(
        rgba: [UInt8],
        width: Int,
        startRow: Int,
        rowCount: Int,
        startX: Int,
        endX: Int
    ) -> Bool {
        guard rowCount > 0, endX > startX else { return false }
        let stride = width * 4
        let firstIdx = startRow * stride + startX * 4
        guard firstIdx + 2 < rgba.count else { return false }
        let r0 = Int(rgba[firstIdx])
        let g0 = Int(rgba[firstIdx + 1])
        let b0 = Int(rgba[firstIdx + 2])

        let xStep = max(1, (endX - startX) / 28)
        let yStep = max(1, rowCount / 16)
        for y in Swift.stride(from: startRow, to: startRow + rowCount, by: yStep) {
            let rowBase = y * stride
            for x in Swift.stride(from: startX, to: endX, by: xStep) {
                let o = rowBase + x * 4
                if abs(Int(rgba[o]) - r0) > 6
                    || abs(Int(rgba[o + 1]) - g0) > 6
                    || abs(Int(rgba[o + 2]) - b0) > 6 {
                    return true
                }
            }
        }
        return false
    }

    public static func fixedRegions(
        prev: [UInt8],
        next: [UInt8],
        width: Int,
        height: Int,
        params: LongshotParams
    ) -> (top: Int, bottom: Int) {
        let prevSig = RowSignatures(rgba: prev, width: width, height: height)
        let nextSig = RowSignatures(rgba: next, width: width, height: height)
        if let discovered = discoverInitialStep(
            firstSig: prevSig,
            nextSig: nextSig,
            firstRGBA: prev,
            nextRGBA: next,
            params: params
        ) {
            return (discovered.headerHeight, discovered.footerHeight)
        }
        return preliminaryStaticRegions(prevSig: prevSig, nextSig: nextSig, firstRGBA: prev, params: params)
    }

    static func preliminaryStaticRegions(
        prevSig: RowSignatures,
        nextSig: RowSignatures,
        firstRGBA: [UInt8],
        params: LongshotParams
    ) -> (top: Int, bottom: Int) {
        let height = prevSig.height
        let width = prevSig.width
        let allBins = Array(0..<prevSig.binCount)
        guard height > 0, !allBins.isEmpty else { return (0, 0) }

        let maxTop = max(params.minFixedRows, (height * 42) / 100)
        var top = 0
        while top < min(height, maxTop) && prevSig.rowDiff(rowA: top, other: nextSig, rowB: top, bins: allBins) <= 3.2 {
            top += 1
        }
        if top < params.minFixedRows
            || !hasVisualStructure(rgba: firstRGBA, width: width, startRow: 0, rowCount: top, startX: prevSig.startX, endX: prevSig.endX) {
            top = 0
        }

        let maxBottom = max(params.minFixedRows, (height * 35) / 100)
        var bottom = 0
        while bottom < min(height, maxBottom)
            && prevSig.rowDiff(rowA: height - 1 - bottom, other: nextSig, rowB: height - 1 - bottom, bins: allBins) <= 3.2 {
            bottom += 1
        }
        if top + bottom > height {
            bottom = max(0, height - top)
        }
        if bottom < params.minFixedRows
            || !hasVisualStructure(rgba: firstRGBA, width: width, startRow: height - bottom, rowCount: bottom, startX: prevSig.startX, endX: prevSig.endX) {
            bottom = 0
        }
        return (top, bottom)
    }

    /// Detects stationary rounded window corners at the bottom-left / bottom-right of a full-window capture so corner notches
    /// are held in the rolling bottom cap instead of repeating at every stitch seam.
    static func detectBottomCornerCapRows(
        firstRGBA: [UInt8],
        nextRGBA: [UInt8],
        width: Int,
        height: Int,
        headerHeight: Int,
        currentFooter: Int
    ) -> Int {
        guard width >= 400, height >= 400, currentFooter < 64 else { return currentFooter }
        let stride = width * 4
        guard firstRGBA.count >= height * stride, nextRGBA.count >= height * stride else { return currentFooter }

        let midY = max(headerHeight + 24, min(height - 64, height / 2))
        let maxScan = min(64, max(0, height - headerHeight - 96))
        guard maxScan >= 8 else { return currentFooter }

        let edgeProbeCols = [0, 1, 2, 3, 4, 5, width - 6, width - 5, width - 4, width - 3, width - 2, width - 1]
        var highestCornerB = -1

        for b in 0..<maxScan {
            let y = height - 1 - b
            var hasStationaryCornerExterior = false
            for x in edgeProbeCols where x >= 0 && x < width {
                let o = y * stride + x * 4
                let m = midY * stride + x * 4
                let diffFromStraightEdge = abs(Int(firstRGBA[o]) - Int(firstRGBA[m]))
                    + abs(Int(firstRGBA[o + 1]) - Int(firstRGBA[m + 1]))
                    + abs(Int(firstRGBA[o + 2]) - Int(firstRGBA[m + 2]))
                let statDiff = abs(Int(firstRGBA[o]) - Int(nextRGBA[o]))
                    + abs(Int(firstRGBA[o + 1]) - Int(nextRGBA[o + 1]))
                    + abs(Int(firstRGBA[o + 2]) - Int(nextRGBA[o + 2]))
                if diffFromStraightEdge > 84 && statDiff <= 18 {
                    hasStationaryCornerExterior = true
                    break
                }
            }
            if hasStationaryCornerExterior {
                highestCornerB = b
            }
        }

        if highestCornerB + 1 >= 8 {
            return max(currentFooter, min(64, highestCornerB + 3))
        }
        return currentFooter
    }

    /// Detects a stationary structured left sidebar (`0 ..< endX`) and extracts a clean, vertically-invariant background+divider
    /// cross-section row so subsequent appended segments extend a clean sidebar column instead of repeating chopped sidebar menus.
    static func detectLeftSidebarExtrusionRow(
        firstRGBA: [UInt8],
        nextRGBA: [UInt8],
        width: Int,
        height: Int,
        bodyTop: Int,
        bodyBottom: Int
    ) -> (endX: Int, rowBytes: [UInt8])? {
        let bodyH = bodyBottom - bodyTop
        guard width >= 480, height >= 320, bodyH >= 160 else { return nil }
        let stride = width * 4
        guard firstRGBA.count >= height * stride, nextRGBA.count >= height * stride else { return nil }

        let maxSidebarW = (width * 35) / 100
        let stripW = 8
        var stationaryEndX = 0

        var sx = 0
        while sx + stripW <= maxSidebarW {
            var diffSum = 0
            var samples = 0
            for y in Swift.stride(from: bodyTop + 8, to: bodyBottom - 8, by: 4) {
                let rowBase = y * stride
                for x in Swift.stride(from: sx, to: sx + stripW, by: 2) {
                    let o = rowBase + x * 4
                    diffSum += abs(Int(firstRGBA[o]) - Int(nextRGBA[o]))
                        + abs(Int(firstRGBA[o + 1]) - Int(nextRGBA[o + 1]))
                        + abs(Int(firstRGBA[o + 2]) - Int(nextRGBA[o + 2]))
                    samples += 3
                }
            }
            let mad = Double(diffSum) / Double(max(1, samples))
            if mad <= 1.8 {
                stationaryEndX = sx + stripW
                sx += stripW
            } else {
                break
            }
        }

        guard stationaryEndX >= 64 else { return nil }

        // Check that this stationary left region actually contains sidebar text/icons (not just a blank margin)
        var textLikeRows = 0
        for y in Swift.stride(from: bodyTop + 8, to: bodyBottom - 8, by: 2) {
            let rowBase = y * stride
            var transitions = 0
            for x in 6..<(stationaryEndX - 6) {
                let o = rowBase + x * 4
                let p = o - 4
                let stepDiff = abs(Int(firstRGBA[o]) - Int(firstRGBA[p]))
                    + abs(Int(firstRGBA[o + 1]) - Int(firstRGBA[p + 1]))
                    + abs(Int(firstRGBA[o + 2]) - Int(firstRGBA[p + 2]))
                if stepDiff > 24 {
                    transitions += 1
                }
            }
            if transitions >= 8 {
                textLikeRows += 1
            }
        }
        guard textLikeRows >= 8 else { return nil }

        // Find the cleanest vertically-invariant gap row (preserves exact window left edge + sidebar background + vertical divider)
        var bestRow: (y: Int, score: Int)?
        for y in (bodyTop + 10)..<(bodyBottom - 10) {
            let rPrev = (y - 2) * stride
            let rCur = y * stride
            let rNext = (y + 2) * stride

            var maxVertDiff = 0
            var horizTransitions = 0
            for x in 0..<stationaryEndX {
                let c = rCur + x * 4
                let vp = rPrev + x * 4
                let vn = rNext + x * 4
                let vd1 = abs(Int(firstRGBA[c]) - Int(firstRGBA[vp]))
                    + abs(Int(firstRGBA[c + 1]) - Int(firstRGBA[vp + 1]))
                    + abs(Int(firstRGBA[c + 2]) - Int(firstRGBA[vp + 2]))
                let vd2 = abs(Int(firstRGBA[c]) - Int(firstRGBA[vn]))
                    + abs(Int(firstRGBA[c + 1]) - Int(firstRGBA[vn + 1]))
                    + abs(Int(firstRGBA[c + 2]) - Int(firstRGBA[vn + 2]))
                let vd = max(vd1, vd2)
                if vd > maxVertDiff {
                    maxVertDiff = vd
                    if maxVertDiff > 12 { break }
                }
                if x > 0 {
                    let prevPx = c - 4
                    let hd = abs(Int(firstRGBA[c]) - Int(firstRGBA[prevPx]))
                        + abs(Int(firstRGBA[c + 1]) - Int(firstRGBA[prevPx + 1]))
                        + abs(Int(firstRGBA[c + 2]) - Int(firstRGBA[prevPx + 2]))
                    if hd > 18 {
                        horizTransitions += 1
                    }
                }
            }

            guard maxVertDiff <= 12, horizTransitions <= 8 else { continue }
            let score = horizTransitions * 100 + maxVertDiff
            if let current = bestRow {
                if score < current.score {
                    bestRow = (y, score)
                }
            } else {
                bestRow = (y, score)
            }
        }

        guard let chosen = bestRow else { return nil }
        let startByte = chosen.y * stride
        let rowBytes = Array(firstRGBA[startByte..<(startByte + stationaryEndX * 4)])
        return (stationaryEndX, rowBytes)
    }

    /// Atomically discovers fixed/sticky `headerHeight`, `footerHeight`, and initial scroll `LongshotMatch` between `first` and `next`.
    /// Handles opaque browser toolbars (even when active tab spinners/titles update at `y = 0..30`), translucent `backdrop-filter: blur`
    /// sticky site headers, fixed left/right sidebars, and bottom window borders / status bars.
    static func discoverInitialStep(
        firstSig: RowSignatures,
        nextSig: RowSignatures,
        firstRGBA: [UInt8],
        nextRGBA: [UInt8],
        params: LongshotParams,
        includesWindowCorners: Bool = true
    ) -> (headerHeight: Int, footerHeight: Int, activeBins: [Int], match: LongshotMatch)? {
        let height = firstSig.height
        let width = firstSig.width
        guard height >= 16, firstSig.binCount > 0 else { return nil }

        let activeBins = RowSignatures.detectScrollingBins(
            prev: firstSig,
            next: nextSig,
            bandTop: (height * 26) / 100,
            bandBottom: (height * 82) / 100
        )

        let (staticTop, staticBottom) = preliminaryStaticRegions(
            prevSig: firstSig,
            nextSig: nextSig,
            firstRGBA: firstRGBA,
            params: params
        )

        // Probe interior vertical bands so unstripped sticky headers (or tab bars with changing favicons) never poison shift discovery
        var probeBands: [(top: Int, bottom: Int)] = [(staticTop, staticBottom)]
        if height >= 96 {
            let pTop24 = max(staticTop, (height * 24) / 100)
            let pTop36 = max(staticTop, (height * 36) / 100)
            let pBot16 = max(staticBottom, (height * 16) / 100)
            probeBands.append((pTop24, staticBottom))
            probeBands.append((pTop36, staticBottom))
            probeBands.append((pTop24, pBot16))
            probeBands.append((staticTop, pBot16))
        }

        var bestProbe: (match: LongshotMatch, score: Double, probeTop: Int, probeBottom: Int)?
        for band in probeBands {
            if height - band.top - band.bottom < 20 { continue }
            let candidate = locateWithSignaturesScored(
                prev: firstSig,
                next: nextSig,
                fixedTop: band.top,
                fixedBottom: band.bottom,
                activeBins: activeBins,
                params: params
            )
            guard candidate.match.confident, candidate.match.offset != 0 else { continue }
            if let existing = bestProbe {
                if candidate.score > existing.score + 0.012 {
                    bestProbe = (candidate.match, candidate.score, band.top, band.bottom)
                }
            } else {
                bestProbe = (candidate.match, candidate.score, band.top, band.bottom)
            }
            if candidate.score >= 0.94 {
                break
            }
        }

        guard let locked = bestProbe else { return nil }
        let offset = locked.match.offset
        let s = abs(offset)
        let earlier = offset > 0 ? firstSig : nextSig
        let later = offset > 0 ? nextSig : firstSig

        // Refine exact `headerHeight` by scanning for the seam between stationary/sticky header rows and `s`-shifted content rows
        let maxHeader = min((height * 45) / 100, height - staticBottom - s - 8)
        var refinedTop = staticTop
        if maxHeader >= params.minFixedRows {
            var lastStickyRow = -1
            for y in 0..<maxHeader {
                let shiftMatched = earlier.rowsMatch(rowA: y + s, other: later, rowB: y, bins: activeBins)
                if !shiftMatched {
                    let shiftDiff = earlier.rowDiff(rowA: y + s, other: later, rowB: y, bins: activeBins)
                    let statDiff = earlier.rowDiff(rowA: y, other: later, rowB: y, bins: activeBins)
                    if statDiff <= 5.5 || statDiff < shiftDiff * 0.60 {
                        // Require either proximity to another mismatched row or non-trivial diff to ignore single-row noise
                        let prevMismatch = (y > 0) && !earlier.rowsMatch(rowA: y - 1 + s, other: later, rowB: y - 1, bins: activeBins)
                        let nextMismatch = (y + 1 < maxHeader) && !earlier.rowsMatch(rowA: y + 1 + s, other: later, rowB: y + 1, bins: activeBins)
                        if prevMismatch || nextMismatch || shiftDiff > 12.0 {
                            lastStickyRow = y
                        }
                    }
                }
            }
            let candidateTop = max(staticTop, lastStickyRow + 1)
            if candidateTop >= params.minFixedRows
                && hasVisualStructure(
                    rgba: firstRGBA,
                    width: width,
                    startRow: 0,
                    rowCount: candidateTop,
                    startX: firstSig.startX,
                    endX: firstSig.endX
                ) {
                var stationaryLikeRows = 0
                for y in 0..<candidateTop {
                    if firstSig.rowDiff(rowA: y, other: nextSig, rowB: y, bins: activeBins) <= 8.5 {
                        stationaryLikeRows += 1
                    }
                }
                if Double(stationaryLikeRows) / Double(candidateTop) >= 0.45 {
                    refinedTop = candidateTop
                }
            }
        }

        // Refine exact `footerHeight` symmetrically at the bottom
        let maxFooter = min((height * 35) / 100, height - refinedTop - s - 8)
        var refinedBottom = staticBottom
        if maxFooter >= params.minFixedRows {
            var lastStickyBottom = -1
            for b in 0..<maxFooter {
                let pRow = height - 1 - b
                let nRow = pRow - s
                if nRow < refinedTop { break }
                let shiftMatched = earlier.rowsMatch(rowA: pRow, other: later, rowB: nRow, bins: activeBins)
                if !shiftMatched {
                    let shiftDiff = earlier.rowDiff(rowA: pRow, other: later, rowB: nRow, bins: activeBins)
                    let statDiff = earlier.rowDiff(rowA: pRow, other: later, rowB: pRow, bins: activeBins)
                    if statDiff <= 5.5 || statDiff < shiftDiff * 0.60 {
                        let prevMismatch = (b > 0) && !earlier.rowsMatch(rowA: pRow + 1, other: later, rowB: nRow + 1, bins: activeBins)
                        let nextMismatch = (b + 1 < maxFooter && nRow - 1 >= refinedTop)
                            && !earlier.rowsMatch(rowA: pRow - 1, other: later, rowB: nRow - 1, bins: activeBins)
                        if prevMismatch || nextMismatch || shiftDiff > 12.0 {
                            lastStickyBottom = b
                        }
                    }
                }
            }
            let candidateBottom = max(staticBottom, lastStickyBottom + 1)
            if candidateBottom >= params.minFixedRows
                && hasVisualStructure(
                    rgba: firstRGBA,
                    width: width,
                    startRow: height - candidateBottom,
                    rowCount: candidateBottom,
                    startX: firstSig.startX,
                    endX: firstSig.endX
                ) {
                var stationaryLikeRows = 0
                for y in (height - candidateBottom)..<height {
                    if firstSig.rowDiff(rowA: y, other: nextSig, rowB: y, bins: activeBins) <= 8.5 {
                        stationaryLikeRows += 1
                    }
                }
                if Double(stationaryLikeRows) / Double(candidateBottom) >= 0.45 {
                    refinedBottom = candidateBottom
                }
            }
        }

        if includesWindowCorners {
            refinedBottom = detectBottomCornerCapRows(
                firstRGBA: firstRGBA,
                nextRGBA: nextRGBA,
                width: width,
                height: height,
                headerHeight: refinedTop,
                currentFooter: refinedBottom
            )
        }

        let finalResult = locateWithSignaturesScored(
            prev: firstSig,
            next: nextSig,
            fixedTop: refinedTop,
            fixedBottom: refinedBottom,
            activeBins: activeBins,
            params: params
        )
        if finalResult.match.confident && finalResult.match.offset != 0 {
            return (refinedTop, refinedBottom, activeBins, finalResult.match)
        }

        // Fallback to preliminary static regions if refined re-check failed
        let staticResult = locateWithSignaturesScored(
            prev: firstSig,
            next: nextSig,
            fixedTop: staticTop,
            fixedBottom: staticBottom,
            activeBins: activeBins,
            params: params
        )
        if staticResult.match.confident && staticResult.match.offset != 0 {
            return (staticTop, staticBottom, activeBins, staticResult.match)
        }
        return nil
    }

    public static func locate(
        prev: [UInt8],
        next: [UInt8],
        width: Int,
        height: Int,
        fixedTop: Int,
        fixedBottom: Int,
        params: LongshotParams
    ) -> LongshotMatch {
        let prevSig = RowSignatures(rgba: prev, width: width, height: height)
        let nextSig = RowSignatures(rgba: next, width: width, height: height)
        let activeBins = RowSignatures.detectScrollingBins(
            prev: prevSig,
            next: nextSig,
            bandTop: max(fixedTop, (height * 22) / 100),
            bandBottom: min(height - fixedBottom, (height * 82) / 100)
        )
        return locateWithSignaturesScored(
            prev: prevSig,
            next: nextSig,
            fixedTop: fixedTop,
            fixedBottom: fixedBottom,
            activeBins: activeBins,
            params: params
        ).match
    }

    static func locateWithSignaturesScored(
        prev: RowSignatures,
        next: RowSignatures,
        fixedTop: Int,
        fixedBottom: Int,
        activeBins: [Int],
        params: LongshotParams
    ) -> (match: LongshotMatch, score: Double) {
        let height = prev.height
        let ct = fixedTop
        let contentH = max(0, height - fixedTop - fixedBottom)
        let allBins = Array(0..<prev.binCount)
        if contentH < 8 || prev.binCount == 0 || next.binCount != prev.binCount {
            return (LongshotMatch(offset: 0, startRow: height, endRow: height, confident: false), 0)
        }
        let bins = activeBins.isEmpty ? allBins : activeBins

        // 1. Check stationary (`offset == 0`) across `bins`
        var sameTotal = 0
        var featureCount = 0
        var featureSame = 0
        for i in 0..<contentH {
            let idx = ct + i
            let eq = prev.rowsMatch(rowA: idx, other: next, rowB: idx, bins: bins)
            if eq { sameTotal += 1 }
            if i > 0 && (prev.isVerticalFeature(row: idx, bins: bins) || next.isVerticalFeature(row: idx, bins: bins)) {
                featureCount += 1
                if eq { featureSame += 1 }
            }
        }
        let totalZeroRatio = Double(sameTotal) / Double(contentH)
        let minZeroRatio = max(0.90, params.minRatio)
        let minZeroFeatureRatio = max(0.82, params.minRatio - 0.04)
        let zeroFeaturesAgree = (featureCount == 0) || (Double(featureSame) / Double(featureCount) >= minZeroFeatureRatio)
        if totalZeroRatio >= minZeroRatio && zeroFeaturesAgree {
            return (LongshotMatch(offset: 0, startRow: height, endRow: height, confident: true), totalZeroRatio)
        }

        // 2. Search downward (`offset > 0`) and upward (`offset < 0`) scroll shifts up to 92% of `contentH`
        let minOverlap = max(8, min(40, contentH / 12))
        let maxShift = max(1, min((contentH * 92) / 100, contentH - minOverlap))

        let down = bestConsistentShift(
            prev: prev,
            next: next,
            ct: ct,
            ch: contentH,
            maxShift: maxShift,
            minRatio: params.minRatio,
            bins: bins,
            frameHasFeatures: featureCount > 0,
            up: false
        )
        let up = bestConsistentShift(
            prev: prev,
            next: next,
            ct: ct,
            ch: contentH,
            maxShift: maxShift,
            minRatio: params.minRatio,
            bins: bins,
            frameHasFeatures: featureCount > 0,
            up: true
        )

        switch (down, up) {
        case (nil, nil):
            // 3. Infinite-scroll / lazy-load fallback: lock onto upper overlap anchor when bottom skeletons turn into real content
            if let anchored = bestAnchoredUpperBandShift(
                prev: prev,
                next: next,
                ct: ct,
                ch: contentH,
                maxShift: maxShift,
                minRatio: params.minRatio,
                bins: bins
            ) {
                return (
                    LongshotMatch(
                        offset: anchored.shift,
                        startRow: ct + contentH - anchored.shift,
                        endRow: ct + contentH,
                        confident: true,
                        overlapRefreshRows: anchored.refreshRows
                    ),
                    anchored.score
                )
            }
            // Stationary frame where bottom lazy-loaded content expanded in-place (`offset == 0`, upper 60% identical)
            if contentH >= 80 {
                let anchorZeroLen = (contentH * 60) / 100
                var zeroAnchorSame = 0
                var zeroAnchorFeat = 0
                var zeroAnchorFeatSame = 0
                for i in 0..<anchorZeroLen {
                    let idx = ct + i
                    let eq = prev.rowsMatch(rowA: idx, other: next, rowB: idx, bins: bins)
                    if eq { zeroAnchorSame += 1 }
                    if i > 0 && (prev.isVerticalFeature(row: idx, bins: bins) || next.isVerticalFeature(row: idx, bins: bins)) {
                        zeroAnchorFeat += 1
                        if eq { zeroAnchorFeatSame += 1 }
                    }
                }
                if Double(zeroAnchorSame) / Double(anchorZeroLen) >= 0.94
                    && zeroAnchorFeat >= 4
                    && Double(zeroAnchorFeatSame) / Double(zeroAnchorFeat) >= 0.90 {
                    return (
                        LongshotMatch(
                            offset: 0,
                            startRow: ct + contentH,
                            endRow: ct + contentH,
                            confident: true,
                            overlapRefreshRows: contentH - anchorZeroLen
                        ),
                        0.94
                    )
                }
            }
            return (LongshotMatch(offset: 0, startRow: height, endRow: height, confident: false), 0)

        case (let d?, nil):
            return (
                LongshotMatch(offset: d.shift, startRow: ct + contentH - d.shift, endRow: ct + contentH, confident: true),
                d.score
            )
        case (nil, let u?):
            return (
                LongshotMatch(offset: -u.shift, startRow: ct, endRow: ct + u.shift, confident: true),
                u.score
            )
        case (let d?, let u?):
            if d.score > u.score + 0.02 || (abs(d.score - u.score) <= 0.02 && d.shift <= u.shift) {
                return (
                    LongshotMatch(offset: d.shift, startRow: ct + contentH - d.shift, endRow: ct + contentH, confident: true),
                    d.score
                )
            } else {
                return (
                    LongshotMatch(offset: -u.shift, startRow: ct, endRow: ct + u.shift, confident: true),
                    u.score
                )
            }
        }
    }

    private static func bestAnchoredUpperBandShift(
        prev: RowSignatures,
        next: RowSignatures,
        ct: Int,
        ch: Int,
        maxShift: Int,
        minRatio: Double,
        bins: [Int]
    ) -> (shift: Int, refreshRows: Int, score: Double)? {
        guard ch >= 80 else { return nil }
        let strictTotal = max(0.90, min(0.96, minRatio + 0.04))
        let strictFeat = max(0.84, min(0.94, minRatio))
        var best: (shift: Int, refreshRows: Int, score: Double)?

        for s in 1...maxShift {
            let overlap = ch - s
            if overlap < 44 { continue }
            let anchorLen = max(28, (overlap * 55) / 100)
            if anchorLen >= overlap { continue }

            if anchorLen >= 48 {
                let probeStep = anchorLen / 12
                var coarseHits = 0
                for k in 0..<12 {
                    let i = k * probeStep
                    if prev.rowsMatch(rowA: ct + i + s, other: next, rowB: ct + i, bins: bins) {
                        coarseHits += 1
                    }
                }
                if coarseHits < 9 { continue }
            }

            var matches = 0
            var featTotal = 0
            var featMatches = 0
            var diffSum = 0.0
            for i in 0..<anchorLen {
                let pIdx = ct + i + s
                let nIdx = ct + i
                let equal = prev.rowsMatch(rowA: pIdx, other: next, rowB: nIdx, bins: bins)
                if equal { matches += 1 }
                diffSum += prev.rowDiff(rowA: pIdx, other: next, rowB: nIdx, bins: bins)
                if i > 0 && (prev.isVerticalFeature(row: pIdx, bins: bins) || next.isVerticalFeature(row: nIdx, bins: bins)) {
                    featTotal += 1
                    if equal { featMatches += 1 }
                }
            }
            guard featTotal >= 4 else { continue }
            let totalRatio = Double(matches) / Double(anchorLen)
            let featRatio = Double(featMatches) / Double(featTotal)
            if totalRatio < strictTotal || featRatio < strictFeat { continue }

            let avgDiff = diffSum / Double(anchorLen)
            let fidelityBonus = max(0.0, (4.0 - min(4.0, avgDiff)) / 4.0) * 0.04
            let score = featRatio * 0.70 + totalRatio * 0.26 + fidelityBonus
            let refreshRows = overlap - anchorLen
            if let current = best {
                if score > current.score + 0.008 {
                    best = (s, refreshRows, score)
                }
            } else {
                best = (s, refreshRows, score)
            }
        }
        return best
    }

    private static func bestConsistentShift(
        prev: RowSignatures,
        next: RowSignatures,
        ct: Int,
        ch: Int,
        maxShift: Int,
        minRatio: Double,
        bins: [Int],
        frameHasFeatures: Bool,
        up: Bool
    ) -> (shift: Int, score: Double)? {
        let minFeatureRatio = max(0.70, minRatio - 0.14)
        var best: (shift: Int, score: Double)?

        for s in 1...maxShift {
            let overlap = ch - s
            if overlap < 8 { continue }
            let isNarrowSeam = (ch >= 120 && overlap < max(24, ch / 7))

            // Fast coarse pre-filter on tall Retina frames: sample 16 rows across overlap before full scan
            if overlap >= 64 {
                let probeStep = overlap / 16
                var coarseHits = 0
                for k in 0..<16 {
                    let i = k * probeStep
                    let pIdx = up ? (ct + i) : (ct + i + s)
                    let nIdx = up ? (ct + i + s) : (ct + i)
                    if prev.rowsMatch(rowA: pIdx, other: next, rowB: nIdx, bins: bins) {
                        coarseHits += 1
                    }
                }
                if coarseHits < 11 { continue }
            }

            var matches = 0
            var featTotal = 0
            var featMatches = 0
            var diffSum = 0.0
            for i in 0..<overlap {
                let pIdx = up ? (ct + i) : (ct + i + s)
                let nIdx = up ? (ct + i + s) : (ct + i)
                let equal = prev.rowsMatch(rowA: pIdx, other: next, rowB: nIdx, bins: bins)
                if equal { matches += 1 }
                diffSum += prev.rowDiff(rowA: pIdx, other: next, rowB: nIdx, bins: bins)
                if i > 0 && (prev.isVerticalFeature(row: pIdx, bins: bins) || next.isVerticalFeature(row: nIdx, bins: bins)) {
                    featTotal += 1
                    if equal { featMatches += 1 }
                }
            }
            let totalRatio = Double(matches) / Double(overlap)
            let requiredTotal = isNarrowSeam ? max(minRatio, 0.88) : minRatio
            if totalRatio < requiredTotal { continue }

            let rawScore: Double
            if featTotal > 0 {
                if isNarrowSeam && frameHasFeatures && featTotal < 3 { continue }
                let featRatio = Double(featMatches) / Double(featTotal)
                let requiredFeat = isNarrowSeam ? max(minFeatureRatio, 0.82) : minFeatureRatio
                if featRatio < requiredFeat { continue }
                rawScore = featRatio * 0.70 + totalRatio * 0.26
            } else {
                if frameHasFeatures { continue }
                rawScore = totalRatio * 0.96
            }

            let avgDiff = diffSum / Double(overlap)
            let fidelityBonus = max(0.0, (4.0 - min(4.0, avgDiff)) / 4.0) * 0.035
            let overlapBonus = min(0.014, (Double(overlap) / Double(max(1, ch))) * 0.020)
            let score = rawScore + fidelityBonus + overlapBonus

            if let current = best {
                if score > current.score + 0.006 {
                    best = (s, score)
                }
            } else {
                best = (s, score)
            }
        }
        return best
    }
}

public enum LongshotStepResult: Equatable, Sendable {
    case appended(offset: Int, rows: Int)
    case revisited(offset: Int)
    case still
    case failed
    case limitReached
}

/// Pixels from the same window and instant as the output crop. Both rectangles use image pixels.
public struct LongshotContext: Sendable {
    public let image: PixelBufferRGBA
    public let selection: PixelRect
    public let scrollRegion: PixelRect?

    public init(image: PixelBufferRGBA, selection: PixelRect, scrollRegion: PixelRect? = nil) {
        self.image = image
        self.selection = selection
        self.scrollRegion = scrollRegion
    }
}

/// Independent movement in backing pixels, with the visible vertical range of the moving content when available.
public struct LongshotScrollMeasurement: Equatable, Sendable {
    public let offset: Int
    public let viewportRows: Range<Int>?

    public init(offset: Int, viewportRows: Range<Int>? = nil) {
        self.offset = offset
        self.viewportRows = viewportRows
    }
}

public final class LongshotCanvas {
    private struct Checkpoint {
        let offset: Int
        let signatures: RowSignatures
    }

    public let width: Int
    public let frameHeight: Int
    public let params: LongshotParams
    public let maxHeight: Int

    private var firstFrame: [UInt8]?
    private var firstSignatures: RowSignatures?
    private var prevFrame: [UInt8] = []
    private var prevSignatures: RowSignatures?
    private var previousContext: LongshotContext?
    private var contextBody: Range<Int>?
    private var checkpoints: [Checkpoint] = []
    private var currentOffset = 0
    private var earliestOffset = 0
    private var furthestOffset = 0
    private var lockedActiveBins: [Int]?
    private var leftSidebarFill: (endX: Int, rowBytes: [UInt8])?
    private var contextSidebarFills: [(columns: Range<Int>, rowBytes: [UInt8])] = []

    private var headerBytes: [UInt8] = []
    public private(set) var headerHeight: Int = 0
    private var footerBytes: [UInt8] = []
    public private(set) var footerHeight: Int = 0

    /// Deque-like row chunks: prepended rows in reverse order + appended rows in forward order
    private var topRowsData: [UInt8] = []
    private var topRowCount: Int = 0
    private var bottomRowsData: [UInt8] = []
    private var bottomRowCount: Int = 0
    private var visibleTailRows: Int = 0

    private var segments: [(prepended: Bool, rows: Int, prevFooter: [UInt8]?)] = []

    public init(width: Int, frameHeight: Int, params: LongshotParams = LongshotParams(), maxHeight: Int = 30000) {
        self.width = width
        self.frameHeight = frameHeight
        self.params = params
        self.maxHeight = maxHeight
    }

    public var contentHeight: Int { topRowCount + bottomRowCount }

    public var totalHeight: Int {
        if firstFrame != nil {
            return min(frameHeight, maxHeight) + visibleTailRows
        }
        return headerHeight + contentHeight + footerHeight
    }

    public var canUndo: Bool { visibleTailRows > 0 || !segments.isEmpty }
    public var segmentCount: Int { segments.count }
    public var viewportOffset: Int { currentOffset }
    public var isAtCapturedEnd: Bool { currentOffset == furthestOffset }
    public private(set) var unstitchedOffset: Int?

    public func seed(_ frame: PixelBufferRGBA) {
        precondition(frame.width == width && frame.height == frameHeight)
        discardVisibleTail()
        let sig = RowSignatures(rgba: frame.rgba, width: width, height: frameHeight)
        firstFrame = frame.rgba
        firstSignatures = sig
        prevFrame = frame.rgba
        prevSignatures = sig
        lockedActiveBins = nil
        leftSidebarFill = nil
        contextSidebarFills = []
        previousContext = nil
        contextBody = nil
        checkpoints = []
        currentOffset = 0
        earliestOffset = 0
        furthestOffset = 0
    }

    public func seed(_ frame: PixelBufferRGBA, context: LongshotContext) {
        seed(frame)
        previousContext = context
        if let signatures = checkpointSignatures(for: context) {
            checkpoints = [Checkpoint(offset: 0, signatures: signatures)]
        }
    }

    public func push(_ frame: PixelBufferRGBA) -> LongshotStepResult {
        guard frame.width == width && frame.height == frameHeight else { return .failed }
        if totalHeight >= maxHeight { return .limitReached }
        let rgba = frame.rgba
        let nextSig = RowSignatures(rgba: rgba, width: width, height: frameHeight)

        if let first = firstFrame {
            let fSig = firstSignatures ?? RowSignatures(rgba: first, width: width, height: frameHeight)
            let allBins = Array(0..<fSig.binCount)
            let initCheck = LongshotStitcher.locateWithSignaturesScored(
                prev: fSig,
                next: nextSig,
                fixedTop: 0,
                fixedBottom: 0,
                activeBins: allBins,
                params: params
            ).match
            if initCheck.confident && initCheck.offset == 0 {
                // Keep `firstFrame` alive until actual page movement occurs; refresh stationary pixels (e.g. settled lazy images)
                firstFrame = rgba
                firstSignatures = nextSig
                prevFrame = rgba
                prevSignatures = nextSig
                return .still
            }

            // Atomically lock fixed/sticky header + footer and first scroll shift; if unconfident (mid-paint), keep `firstFrame` intact!
            guard let discovered = LongshotStitcher.discoverInitialStep(
                firstSig: fSig,
                nextSig: nextSig,
                firstRGBA: first,
                nextRGBA: rgba,
                params: params
            ) else {
                return .failed
            }

            startContent(first, next: rgba, header: discovered.headerHeight,
                         footer: discovered.footerHeight, activeBins: discovered.activeBins)
            return applyMatch(discovered.match, rgba: rgba, nextSig: nextSig, prepend: discovered.match.offset < 0)
        }

        return pushInner(rgba, nextSig: nextSig)
    }

    public func push(
        _ frame: PixelBufferRGBA, context: LongshotContext, downwardOnly: Bool = false,
        refreshStationaryFrame: Bool = true, measurement: LongshotScrollMeasurement? = nil,
        preserveVerifiedEnd: Bool = false
    ) -> LongshotStepResult {
        push(frame, context: context, allowBacktracking: !downwardOnly, allowPrepending: !downwardOnly,
             refreshStationaryFrame: refreshStationaryFrame, measurement: measurement,
             preserveVerifiedEnd: preserveVerifiedEnd)
    }

    /// Checks the original viewport without changing the captured result.
    public func isAtStart(_ frame: PixelBufferRGBA, context: LongshotContext, positionMatches: Bool) -> Bool {
        guard frame.width == width, frame.height == frameHeight,
              offsetFromStart(in: context) == 0 else { return false }
        return positionMatches || capturedOffset(of: frame) == 0
    }

    /// Measures a nearby displacement from the original viewport, for correcting a scroll back to it.
    public func offsetFromStart(in context: LongshotContext) -> Int? {
        guard let previousContext, sameViewport(previousContext, context),
              let origin = checkpoints.first?.signatures, let current = checkpointSignatures(for: context),
              let body = checkpointBody(in: context, height: current.height) else { return nil }
        if origin.samples(in: body) == current.samples(in: body) { return 0 }
        return origin.stableColumnsOffset(to: current, rows: body, minRatio: params.minRatio)
    }

    /// Locate a viewport in the already captured content before resuming automatic scrolling.
    public func reconnect(
        _ frame: PixelBufferRGBA, context: LongshotContext, positionIsUnchanged: Bool = false
    ) -> LongshotStepResult {
        guard frame.width == width, frame.height == frameHeight,
              let previousContext, sameViewport(previousContext, context) else { return .failed }
        if context.image == previousContext.image {
            return push(frame, context: context, downwardOnly: true, refreshStationaryFrame: false,
                        measurement: positionIsUnchanged ? LongshotScrollMeasurement(offset: 0) : nil)
        }
        if firstFrame != nil {
            return push(frame, context: context, allowBacktracking: false, allowPrepending: false,
                        refreshStationaryFrame: false)
        }
        if let offset = capturedOffset(of: frame) {
            return revisit(frame, context: context, at: offset)
        }
        guard let live = checkpointSignatures(for: context),
              let body = checkpointBody(in: context, height: live.height) else { return .failed }
        let bins = Array(0..<live.binCount)
        let samples = live.samples(in: body)
        guard body.filter({ live.isVerticalFeature(row: $0, bins: bins) }).count >= 4 else { return .failed }
        let matching = checkpoints.filter { checkpoint in
            (earliestOffset...furthestOffset).contains(checkpoint.offset)
                && checkpoint.signatures.samples(in: body) == samples
        }
        guard matching.count == 1, let checkpoint = matching.first else { return .failed }
        return revisit(frame, context: context, at: checkpoint.offset)
    }

    private func revisit(_ frame: PixelBufferRGBA, context: LongshotContext, at offset: Int) -> LongshotStepResult {
        let movement = offset - currentOffset
        currentOffset = offset
        previousContext = context
        prevFrame = frame.rgba
        prevSignatures = RowSignatures(rgba: frame.rgba, width: width, height: frameHeight)
        unstitchedOffset = nil
        return .revisited(offset: movement)
    }

    private func capturedOffset(of frame: PixelBufferRGBA) -> Int? {
        let body = headerHeight..<(frameHeight - footerHeight)
        let capturedHeight = contentHeight - visibleTailRows
        let lastStart = min(capturedHeight - body.count, furthestOffset - earliestOffset)
        guard body.count >= 8, lastStart >= 0 else { return nil }

        let live = RowSignatures(rgba: frame.rgba, width: width, height: frameHeight)
        let bins = lockedActiveBins ?? Array(0..<live.binCount)
        let features = body.filter { live.isVerticalFeature(row: $0, bins: bins) }
        guard features.count >= 4 else { return nil }
        let probes = [features[0], features[features.count / 3],
                      features[features.count * 2 / 3], features[features.count - 1]]
        let bytes = topRowsData.isEmpty ? bottomRowsData : topRowsData + bottomRowsData
        let captured = RowSignatures(rgba: bytes, width: width, height: capturedHeight)
        let left = contextSidebarFills.first { $0.columns.lowerBound == 0 }?.columns.upperBound ?? live.startX
        let right = contextSidebarFills.first { $0.columns.upperBound == width }?.columns.lowerBound ?? live.endX
        guard left < right else { return nil }
        let stride = width * 4
        let columnBytes = (left * 4)..<(right * 4)
        var likely: Int?
        var exact: Int?
        var ambiguous = false
        for start in 0...lastStart {
            let shift = start - body.lowerBound
            let probeHits = probes.filter { captured.rowsMatch(rowA: $0 + shift, other: live, rowB: $0, bins: bins) }
            guard probeHits.count >= 3 else { continue }
            let matches = body.filter { captured.rowsMatch(rowA: $0 + shift, other: live, rowB: $0, bins: bins) }
            guard matches.count * 100 >= body.count * 98 else { continue }
            let offset = earliestOffset + start
            if body.allSatisfy({ row in
                let previous = (row + shift) * stride
                let visible = row * stride
                return bytes[(previous + columnBytes.lowerBound)..<(previous + columnBytes.upperBound)]
                    == frame.rgba[(visible + columnBytes.lowerBound)..<(visible + columnBytes.upperBound)]
            }) {
                guard exact == nil else { return nil }
                exact = offset
            }
            ambiguous = likely != nil
            likely = offset
        }
        return exact ?? (ambiguous ? nil : likely)
    }

    private func sameViewport(_ before: LongshotContext, _ after: LongshotContext) -> Bool {
        before.selection == after.selection && before.scrollRegion == after.scrollRegion
            && before.image.width == after.image.width && before.image.height == after.image.height
    }

    private func checkpointSignatures(for context: LongshotContext) -> RowSignatures? {
        let sample: PixelBufferRGBA
        if let bounds = context.scrollRegion {
            guard let cropped = context.image.cropped(to: bounds) else { return nil }
            sample = cropped
        } else {
            sample = context.image
        }
        return RowSignatures(rgba: sample.rgba, width: sample.width, height: sample.height)
    }

    private func checkpointBody(in context: LongshotContext, height: Int) -> Range<Int>? {
        let regionTop = context.scrollRegion?.y ?? 0
        let rows = contextBody.map { ($0.lowerBound - regionTop)..<($0.upperBound - regionTop) } ?? 0..<height
        guard rows.count >= 8, rows.lowerBound >= 0, rows.upperBound <= height else { return nil }
        return rows
    }

    private func push(
        _ frame: PixelBufferRGBA, context: LongshotContext, allowBacktracking: Bool, allowPrepending: Bool,
        refreshStationaryFrame: Bool, measurement: LongshotScrollMeasurement? = nil, preserveVerifiedEnd: Bool = false
    ) -> LongshotStepResult {
        unstitchedOffset = nil
        guard frame.width == width, frame.height == frameHeight,
              let previousContext, sameViewport(previousContext, context) else { return .failed }
        if totalHeight >= maxHeight { return .limitReached }

        let region = context.scrollRegion ?? PixelRect(
            x: 0, y: 0, width: context.image.width, height: context.image.height
        )
        let viewport = region.y..<region.maxY
        let measuredViewport = measurement?.viewportRows?.clamped(to: viewport)
        let searchBody = contextBody ?? measuredViewport ?? viewport
        var estimate = estimateMotion(from: previousContext.image, to: context.image, columns: region, rows: searchBody,
                                      measuredOffset: measurement?.offset, includesWindowCorners: measuredViewport == nil)
        if contextBody == nil, estimate?.ambiguous != true,
           estimate?.match.confident != true || estimate?.match.offset == 0 {
            // A parent scroll area may surround a much smaller nested scroller. Try the original rows too.
            let start = max(region.y, context.selection.y)
            let end = min(region.maxY, context.selection.maxY)
            if end - start >= 20, start..<end != searchBody,
               let selected = estimateMotion(from: previousContext.image, to: context.image,
                                             columns: region, rows: start..<end, measuredOffset: measurement?.offset,
                                             includesWindowCorners: measuredViewport == nil),
               selected.match.confident, selected.match.offset != 0 {
                estimate = selected
            }
        }
        guard let estimate, !estimate.ambiguous else { return .failed }
        let motion = estimate.match
        guard motion.confident, allowBacktracking || motion.offset >= 0 else { return .failed }

        let firstBodyRow = estimate.body.lowerBound
        let bodyEnd = estimate.body.upperBound
        let top = max(0, firstBodyRow - context.selection.y)
        let bottom = min(frameHeight, bodyEnd - context.selection.y)
        let refreshStart = max(top, bodyEnd - max(0, motion.offset)
                               - motion.overlapRefreshRows - context.selection.y)
        if motion.offset == 0 {
            guard refreshStationaryFrame, top < bottom else { return .still }
            if frame.rgba == prevFrame {
                self.previousContext = context
                return .still
            }
            let start: Int
            if preserveVerifiedEnd {
                guard let filled = newlyFilledTail(in: frame, rows: top..<bottom) else { return .still }
                start = filled
            } else {
                start = motion.overlapRefreshRows > 0 ? min(bottom, refreshStart) : top
            }
            if firstFrame != nil {
                seed(frame, context: context)
            } else if currentOffset == furthestOffset, visibleTailRows == 0 {
                let refresh = LongshotMatch(offset: 0, startRow: bottom, endRow: bottom, confident: true,
                                            overlapRefreshRows: bottom - start)
                self.previousContext = context
                return applyMatch(refresh, rgba: frame.rgba,
                                  nextSig: RowSignatures(rgba: frame.rgba, width: width, height: frameHeight),
                                  prepend: false)
            }
            return .still
        }
        unstitchedOffset = motion.offset

        let nextOffset = currentOffset + motion.offset
        guard allowPrepending || nextOffset >= earliestOffset else { return .failed }
        let added = nextOffset > furthestOffset ? nextOffset - furthestOffset : min(0, nextOffset - earliestOffset)
        let overlap = bottom - top - max(abs(motion.offset), abs(added))
        guard overlap >= max(4, min(40, (bottom - top) / 4)) else { return .failed }

        // A larger sample can identify motion. Only rows present in the original selection can establish its seam.
        let beforeSelection = prevSignatures ?? RowSignatures(rgba: prevFrame, width: width, height: frameHeight)
        let afterSelection = RowSignatures(rgba: frame.rgba, width: width, height: frameHeight)
        let selectedBins = RowSignatures.detectScrollingBins(
            prev: beforeSelection, next: afterSelection, bandTop: top, bandBottom: bottom
        )
        let seamBins = selectedBins.isEmpty ? Array(0..<afterSelection.binCount) : selectedBins
        let beforeStart = top + max(0, motion.offset)
        let afterStart = top + max(0, -motion.offset)
        let matchingRows = (0..<overlap).filter {
            beforeSelection.rowsMatch(rowA: beforeStart + $0,
                                      other: afterSelection, rowB: afterStart + $0, bins: seamBins)
        }.count
        let matchesAcrossSelection = Double(matchingRows) >= params.minRatio * Double(overlap)
        if !matchesAcrossSelection {
            let widerContextMatches = estimate.usedStableColumns && (estimate.body.lowerBound < context.selection.y
                || estimate.body.upperBound > context.selection.maxY
                || region.x < context.selection.x || region.maxX > context.selection.maxX)
            let verifiedOffset = measurement?.offset == motion.offset || widerContextMatches ? motion.offset : nil
            guard beforeSelection.stableColumnsOffset(to: afterSelection, rows: top..<bottom,
                                                     expectedOffset: verifiedOffset, minRatio: params.minRatio) == motion.offset else {
                return .failed
            }
        }

        if let first = firstFrame {
            discardVisibleTail()
            contextBody = firstBodyRow..<bodyEnd
            startContent(first, next: frame.rgba, header: top, footer: frameHeight - bottom,
                         activeBins: seamBins, preserveFirstFrame: true)
            let left = min(width, max(0, region.x - context.selection.x))
            let right = max(left, min(width, region.maxX - context.selection.x))
            let body = top..<bottom
            let fixedLeft = left > 0 ? 0..<left :
                fixedColumns(in: first, next: frame.rgba, body: body, offset: motion.offset, fromRight: false)
            let fixedRight = right < width ? right..<width :
                fixedColumns(in: first, next: frame.rgba, body: body, offset: motion.offset, fromRight: true)
            contextSidebarFills = [fixedLeft, fixedRight].compactMap { $0 }.map {
                sidebarFill(columns: $0, body: body, in: first)
            }
        }
        currentOffset = nextOffset
        self.previousContext = context
        unstitchedOffset = nil
        if added == 0 {
            prevFrame = frame.rgba
            prevSignatures = afterSelection
            return .revisited(offset: motion.offset)
        }
        discardVisibleTail()
        let startRow = added > 0 ? bottom - added : top
        let match = LongshotMatch(offset: motion.offset, startRow: startRow,
                                  endRow: startRow + abs(added), confident: true,
                                  overlapRefreshRows: matchesAcrossSelection && added > 0 && motion.overlapRefreshRows > 0
                                      ? max(0, startRow - refreshStart) : 0)
        let previousHeight = totalHeight
        let result = applyMatch(match, rgba: frame.rgba, nextSig: afterSelection, prepend: added < 0)
        let growth = totalHeight - previousHeight
        if added > 0 { furthestOffset += growth } else { earliestOffset -= growth }
        if case .appended = result,
           abs(currentOffset - (checkpoints.last?.offset ?? 0)) >= max(8, region.height / 2),
           let signatures = checkpointSignatures(for: context) {
            checkpoints.append(Checkpoint(offset: currentOffset, signatures: signatures))
            if checkpoints.count > 8 { checkpoints.remove(at: 1) }
        }
        return result
    }

    private func newlyFilledTail(in frame: PixelBufferRGBA, rows: Range<Int>) -> Int? {
        guard let previous = prevSignatures else { return nil }
        let current = RowSignatures(rgba: frame.rgba, width: width, height: frameHeight)
        let bins = Array(0..<previous.binCount)
        guard let start = rows.first(where: { !previous.rowsMatch(rowA: $0, other: current, rowB: $0, bins: bins) }),
              start > rows.lowerBound else { return nil }
        let suffix = (start + 1)..<rows.upperBound
        func detailRows(in signatures: RowSignatures) -> Int {
            suffix.filter { signatures.isVerticalFeature(row: $0, bins: bins) }.count
        }
        return detailRows(in: current) >= max(4, detailRows(in: previous) + 3) ? start : nil
    }

    private func estimateMotion(
        from before: PixelBufferRGBA, to after: PixelBufferRGBA, columns: PixelRect, rows: Range<Int>,
        measuredOffset: Int?, includesWindowCorners: Bool
    ) -> (match: LongshotMatch, body: Range<Int>, ambiguous: Bool, usedStableColumns: Bool)? {
        let sample = PixelRect(x: columns.x, y: rows.lowerBound, width: columns.width, height: rows.count)
        guard let old = before.cropped(to: sample), let new = after.cropped(to: sample) else { return nil }
        let identical = old == new
        let still = LongshotMatch(offset: 0, startRow: 0, endRow: 0, confident: true)
        if identical && measuredOffset == 0 {
            return (still, rows, false, false)
        }
        let oldRows = RowSignatures(rgba: old.rgba, width: old.width, height: old.height)
        let newRows = identical ? oldRows : RowSignatures(rgba: new.rgba, width: new.width, height: new.height)
        func validate(_ match: LongshotMatch, body: Range<Int>, bins: [Int]) -> (LongshotMatch, Range<Int>, Bool, Bool) {
            let bounds = (rows.lowerBound + body.lowerBound)..<(rows.lowerBound + body.upperBound)
            guard match.offset != 0 || measuredOffset != 0 else { return (match, bounds, false, false) }
            let verified = verifyOverlap(before: oldRows, after: newRows, body: body, match: match,
                                         bins: bins, measuredOffset: measuredOffset)
            return (verified ?? match, bounds, verified == nil, false)
        }
        if identical {
            return validate(still, body: 0..<old.height, bins: Array(0..<oldRows.binCount))
        }
        if contextBody == nil, let initial = LongshotStitcher.discoverInitialStep(
            firstSig: oldRows, nextSig: newRows, firstRGBA: old.rgba, nextRGBA: new.rgba, params: params,
            includesWindowCorners: includesWindowCorners
        ) {
            return validate(initial.match, body: initial.headerHeight..<(old.height - initial.footerHeight),
                            bins: initial.activeBins)
        }
        let bins = RowSignatures.detectScrollingBins(
            prev: oldRows, next: newRows, bandTop: old.height / 5, bandBottom: old.height * 4 / 5
        )
        let motion = LongshotStitcher.locateWithSignaturesScored(
            prev: oldRows, next: newRows, fixedTop: 0, fixedBottom: 0, activeBins: bins, params: params
        ).match
        let expectedOffset = measuredOffset == 0 ? nil : measuredOffset
        if !motion.confident, let offset = oldRows.stableColumnsOffset(to: newRows, rows: 0..<old.height,
                                                                      expectedOffset: expectedOffset, minRatio: params.minRatio) {
            return (LongshotMatch(offset: offset, startRow: 0, endRow: 0, confident: true), rows, false, true)
        }
        return validate(motion, body: 0..<old.height, bins: bins)
    }

    private func verifyOverlap(
        before: RowSignatures, after: RowSignatures, body: Range<Int>, match: LongshotMatch,
        bins: [Int], measuredOffset: Int?
    ) -> LongshotMatch? {
        let minimumOverlap = max(8, min(40, body.count / 4))
        let maxOffset = body.count - minimumOverlap
        guard maxOffset > 0, abs(match.offset) <= maxOffset else { return match }
        let stride = before.binCount * 4
        let activeBins = bins.isEmpty ? Array(0..<before.binCount) : bins
        var features = [0]
        for row in body {
            features.append(features[features.count - 1] + (before.isVerticalFeature(row: row, bins: activeBins) ? 1 : 0))
        }
        guard features[features.count - 1] >= 4 else { return match }

        func matches(_ movement: Int) -> Bool {
            let count = body.count - abs(movement)
            let start = max(0, movement)
            // Blank margins alone cannot establish another viable displacement.
            guard features[start + count] - features[start + 1] >= 4 else { return false }
            let oldStart = body.lowerBound + max(0, movement)
            let newStart = body.lowerBound + max(0, -movement)
            let oldIndices = (oldStart * stride)..<((oldStart + count) * stride)
            let newIndices = (newStart * stride)..<((newStart + count) * stride)
            return before.data[oldIndices] == after.data[newIndices]
        }

        let candidates = -maxOffset...maxOffset
        if let measuredOffset, measuredOffset != match.offset, candidates.contains(measuredOffset),
           matches(measuredOffset) {
            return LongshotMatch(offset: measuredOffset, startRow: 0, endRow: 0, confident: true)
        }
        guard candidates.contains(where: { $0 != match.offset && matches($0) }) else { return match }
        // Repeated rows can support several offsets. Resolve them only with a second measurement and matching pixels.
        guard let measuredOffset, candidates.contains(measuredOffset), matches(measuredOffset) else { return nil }
        if match.offset == measuredOffset { return match }
        return LongshotMatch(offset: measuredOffset, startRow: 0, endRow: 0, confident: true)
    }

    private func startContent(
        _ first: [UInt8], next rgba: [UInt8], header t: Int, footer b: Int, activeBins: [Int],
        preserveFirstFrame: Bool = false
    ) {
        let stride = width * 4
        firstFrame = nil
        firstSignatures = nil
        lockedActiveBins = activeBins

        if t > 0 {
            headerBytes = Array(first[0..<(t * stride)])
            headerHeight = t
        }
        if b > 0 {
            footerBytes = Array(first[(first.count - b * stride)..<first.count])
            footerHeight = b
        }
        if !preserveFirstFrame {
            leftSidebarFill = LongshotStitcher.detectLeftSidebarExtrusionRow(
                firstRGBA: first, nextRGBA: rgba, width: width, height: frameHeight,
                bodyTop: headerHeight, bodyBottom: frameHeight - footerHeight
            )
        }
        let bodyStart = headerHeight * stride
        let bodyEnd = (frameHeight - footerHeight) * stride
        if bodyEnd > bodyStart {
            var seedBody = Array(first[bodyStart..<bodyEnd])
            let seedRows = frameHeight - headerHeight - footerHeight
            if let sb = leftSidebarFill, sb.endX > 0, seedRows > 80 {
                // Prevent horizontally slicing through a bottom-pinned sidebar icon/text row right at `bodyEnd`
                let copyLen = sb.endX * 4
                func rowMatchesTemplate(_ r: Int) -> Bool {
                    let base = r * stride
                    var diffPixels = 0
                    for x in 0..<sb.endX {
                        let o = base + x * 4
                        let t = x * 4
                        let d = abs(Int(seedBody[o]) - Int(sb.rowBytes[t]))
                            + abs(Int(seedBody[o + 1]) - Int(sb.rowBytes[t + 1]))
                            + abs(Int(seedBody[o + 2]) - Int(sb.rowBytes[t + 2]))
                        if d > 24 {
                            diffPixels += 1
                            if diffPixels > 6 { return false }
                        }
                    }
                    return true
                }
                if !rowMatchesTemplate(seedRows - 1) {
                    let searchLimit = min(64, seedRows / 6)
                    var cleanBreakRow: Int?
                    for back in 1...searchLimit {
                        let r = seedRows - 1 - back
                        if rowMatchesTemplate(r) {
                            cleanBreakRow = r + 1
                            break
                        }
                    }
                    if let cut = cleanBreakRow, cut < seedRows {
                        seedBody.withUnsafeMutableBytes { dstRaw in
                            sb.rowBytes.withUnsafeBytes { srcRaw in
                                guard let dstBase = dstRaw.baseAddress, let srcBase = srcRaw.baseAddress else { return }
                                for r in cut..<seedRows {
                                    memcpy(dstBase.advanced(by: r * stride), srcBase, copyLen)
                                }
                            }
                        }
                    }
                }
            }
            bottomRowsData.append(contentsOf: seedBody)
            bottomRowCount += seedRows
        }
    }

    private func pushInner(_ rgba: [UInt8], nextSig: RowSignatures) -> LongshotStepResult {
        let pSig = prevSignatures ?? RowSignatures(rgba: prevFrame, width: width, height: frameHeight)
        let activeBins = lockedActiveBins ?? RowSignatures.detectScrollingBins(
            prev: pSig,
            next: nextSig,
            bandTop: max(headerHeight, (frameHeight * 24) / 100),
            bandBottom: min(frameHeight - footerHeight, (frameHeight * 82) / 100)
        )
        let match = LongshotStitcher.locateWithSignaturesScored(
            prev: pSig,
            next: nextSig,
            fixedTop: headerHeight,
            fixedBottom: footerHeight,
            activeBins: activeBins,
            params: params
        ).match

        // Never append unaligned full frames on failure! Preserve `prevFrame` so the settled next frame aligns cleanly.
        guard match.confident else {
            return .failed
        }
        return applyMatch(match, rgba: rgba, nextSig: nextSig, prepend: match.offset < 0)
    }

    private func applyMatch(
        _ match: LongshotMatch, rgba: [UInt8], nextSig: RowSignatures, prepend: Bool
    ) -> LongshotStepResult {
        let stride = width * 4

        if match.overlapRefreshRows > 0 && match.offset >= 0 {
            let refreshRows = min(match.overlapRefreshRows, bottomRowCount)
            let refreshSrcEnd = match.startRow
            let refreshSrcStart = refreshSrcEnd - refreshRows
            if refreshRows > 0 && refreshSrcStart >= headerHeight && refreshSrcEnd <= frameHeight - footerHeight {
                let byteLen = refreshRows * stride
                if bottomRowsData.count >= byteLen {
                    var refreshed = Array(rgba[(refreshSrcStart * stride)..<(refreshSrcEnd * stride)])
                    applySidebarExtrusionIfNeeded(to: &refreshed, rowCount: refreshRows)
                    bottomRowsData.replaceSubrange(
                        (bottomRowsData.count - byteLen)..<bottomRowsData.count,
                        with: refreshed
                    )
                }
            }
        }

        if match.offset == 0 {
            prevFrame = rgba
            prevSignatures = nextSig
            return .still
        }
        let requestedRows = match.endRow - match.startRow
        let rows = min(requestedRows, max(0, maxHeight - totalHeight))
        guard rows > 0 || requestedRows == 0 else { return .limitReached }
        if rows <= 0 {
            prevFrame = rgba
            prevSignatures = nextSig
            return .still
        }
        let start = prepend ? match.endRow - rows : match.startRow
        var sliceBytes = Array(rgba[(start * stride)..<((start + rows) * stride)])
        var savedPrevFooter: [UInt8]? = nil
        if prepend {
            if !contextSidebarFills.isEmpty {
                applySidebarExtrusionIfNeeded(to: &sliceBytes, rowCount: rows)
            }
            sliceBytes.append(contentsOf: topRowsData)
            topRowsData = sliceBytes
            topRowCount += rows
        } else {
            applySidebarExtrusionIfNeeded(to: &sliceBytes, rowCount: rows)
            bottomRowsData.append(contentsOf: sliceBytes)
            bottomRowCount += rows
            if footerHeight > 0 {
                savedPrevFooter = footerBytes
                var newFooter = Array(rgba[((frameHeight - footerHeight) * stride)..<rgba.count])
                // Clean any clipped sidebar text in the upper portion of the rolling bottom cap while preserving bottom corners & border
                if let sb = leftSidebarFill, sb.endX > 32, footerHeight > 6 {
                    let safeStartCol = 32 * 4
                    let safeEndCol = sb.endX * 4
                    if safeEndCol > safeStartCol {
                        let cleanSpan = sb.rowBytes[safeStartCol..<safeEndCol]
                        for fy in 0..<(footerHeight - 4) {
                            let rowStart = fy * stride
                            newFooter.replaceSubrange((rowStart + safeStartCol)..<(rowStart + safeEndCol), with: cleanSpan)
                        }
                    }
                }
                footerBytes = newFooter
            }
        }
        segments.append((prepended: prepend, rows: rows, prevFooter: savedPrevFooter))
        prevFrame = rgba
        prevSignatures = nextSig
        return totalHeight >= maxHeight ? .limitReached : .appended(offset: match.offset, rows: rows)
    }

    private func applySidebarExtrusionIfNeeded(to buffer: inout [UInt8], rowCount: Int) {
        let stride = width * 4
        for fill in contextSidebarFills {
            buffer.withUnsafeMutableBytes { output in
                fill.rowBytes.withUnsafeBytes { row in
                    guard let outputStart = output.baseAddress, let rowStart = row.baseAddress else { return }
                    for y in 0..<rowCount {
                        memcpy(outputStart.advanced(by: y * stride + fill.columns.lowerBound * 4),
                               rowStart, row.count)
                    }
                }
            }
        }
        guard let sb = leftSidebarFill, sb.endX > 0, rowCount > 0 else { return }
        let copyLen = sb.endX * 4
        guard sb.rowBytes.count == copyLen, buffer.count >= rowCount * stride else { return }
        buffer.withUnsafeMutableBytes { dstRaw in
            sb.rowBytes.withUnsafeBytes { srcRaw in
                guard let dstBase = dstRaw.baseAddress, let srcBase = srcRaw.baseAddress else { return }
                for r in 0..<rowCount {
                    memcpy(dstBase.advanced(by: r * stride), srcBase, copyLen)
                }
            }
        }
    }

    private func sidebarFill(
        columns: Range<Int>, body: Range<Int>, in rgba: [UInt8]
    ) -> (columns: Range<Int>, rowBytes: [UInt8]) {
        let stride = width * 4
        let start = columns.lowerBound * 4
        let end = columns.upperBound * 4
        // Extend a quiet background row under the first screen, without repeating fixed buttons or text.
        func changes(in row: Int) -> Int {
            let offset = row * stride
            return Swift.stride(from: start + 4, to: end, by: 4).reduce(into: 0) { count, x in
                let a = offset + x - 4
                let b = offset + x
                let difference = abs(Int(rgba[a]) - Int(rgba[b]))
                    + abs(Int(rgba[a + 1]) - Int(rgba[b + 1])) + abs(Int(rgba[a + 2]) - Int(rgba[b + 2]))
                if difference > 18 { count += 1 }
            }
        }
        var quietRow = body.lowerBound
        var fewest = changes(in: quietRow)
        for row in body.dropFirst() where fewest > 0 {
            let count = changes(in: row)
            if count < fewest { quietRow = row; fewest = count }
        }
        let offset = quietRow * stride
        return (columns, Array(rgba[(offset + start)..<(offset + end)]))
    }

    private func fixedColumns(
        in first: [UInt8], next: [UInt8], body: Range<Int>, offset: Int, fromRight: Bool
    ) -> Range<Int>? {
        let firstRow = body.lowerBound + max(0, -offset)
        let endRow = body.upperBound - max(0, offset)
        let rows = Swift.stride(from: firstRow, to: endRow, by: 2)
        let sampleCount = (endRow - firstRow + 1) / 2
        var columns = 0
        var hasFixedDetail = false
        for distance in 0..<(width / 3) {
            let x = fromRight ? width - 1 - distance : distance
            var samePositionChange = 0
            var shiftedChange = 0
            for y in rows {
                let index = (y * width + x) * 4
                let shifted = index + offset * width * 4
                for channel in 0..<3 {
                    samePositionChange += abs(Int(first[index + channel]) - Int(next[index + channel]))
                    shiftedChange += abs(Int(first[shifted + channel]) - Int(next[index + channel]))
                }
            }
            if samePositionChange > sampleCount * 6 { break }
            if shiftedChange > sampleCount * 18 { hasFixedDetail = true }
            columns += 1
        }
        guard columns >= 8, hasFixedDetail else { return nil }
        return fromRight ? (width - columns)..<width : 0..<columns
    }

    /// Include the final visible body below the original crop after forward scrolling has ended.
    public func includeVisibleTail(positionAtRegionEnd: Bool = false) {
        guard visibleTailRows == 0, isAtCapturedEnd,
              let context = previousContext else { return }
        let confirmedBottom = positionAtRegionEnd && footerHeight == 0 ? context.scrollRegion?.maxY : nil
        guard let bodyEnd = confirmedBottom ?? contextBody?.upperBound else { return }
        let start = context.selection.maxY
        let rows = min(bodyEnd - start, maxHeight - totalHeight)
        guard rows > 0 else { return }
        let rect = PixelRect(x: context.selection.x, y: start, width: width, height: rows)
        guard let tail = context.image.cropped(to: rect), tail.width == width else { return }
        var bytes = tail.rgba
        applySidebarExtrusionIfNeeded(to: &bytes, rowCount: tail.height)
        bottomRowsData.append(contentsOf: bytes)
        bottomRowCount += tail.height
        visibleTailRows = tail.height
    }

    private func discardVisibleTail() {
        guard visibleTailRows > 0 else { return }
        bottomRowsData.removeLast(visibleTailRows * width * 4)
        bottomRowCount -= visibleTailRows
        visibleTailRows = 0
    }

    @discardableResult
    public func undoLast() -> Bool {
        if visibleTailRows > 0 {
            discardVisibleTail()
            return true
        }
        guard let last = segments.popLast() else { return false }
        let byteCount = last.rows * width * 4
        if last.prepended {
            guard topRowsData.count >= byteCount else { return false }
            topRowsData.removeFirst(byteCount)
            topRowCount -= last.rows
            if previousContext != nil { earliestOffset += last.rows }
        } else {
            guard bottomRowsData.count >= byteCount else { return false }
            bottomRowsData.removeLast(byteCount)
            bottomRowCount -= last.rows
            if previousContext != nil { furthestOffset -= last.rows }
            if let oldFooter = last.prevFooter {
                footerBytes = oldFooter
            }
        }
        return true
    }

    public func exportBuffer() -> PixelBufferRGBA? {
        if let first = firstFrame {
            let rows = min(frameHeight, maxHeight)
            var bytes = rows == frameHeight ? first : Array(first.prefix(rows * width * 4))
            bytes.append(contentsOf: bottomRowsData)
            return PixelBufferRGBA(width: width, height: totalHeight, rgba: bytes)
        }
        let totalH = headerHeight + contentHeight + footerHeight
        guard totalH > 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(totalH * width * 4)
        out.append(contentsOf: headerBytes)
        out.append(contentsOf: topRowsData)
        out.append(contentsOf: bottomRowsData)
        out.append(contentsOf: footerBytes)
        return PixelBufferRGBA(width: width, height: totalH, rgba: out)
    }

    public func makeThumbnail(maxWidth: Int, maxHeight: Int) -> CGImage? {
        guard width > 0, maxWidth > 0, maxHeight > 0 else { return nil }
        if firstFrame != nil {
            return exportBuffer()?.makeCGImage()
        }
        let totalH = headerHeight + contentHeight + footerHeight
        guard totalH > 0 else { return nil }

        let scale = min(Double(maxWidth) / Double(width), Double(maxHeight) / Double(totalH))
        let tw = max(1, min(maxWidth, Int((Double(width) * scale).rounded())))
        let th = max(1, min(maxHeight, Int((Double(totalH) * scale).rounded())))
        var thumb = [UInt8](repeating: 0, count: tw * th * 4)
        let stride = width * 4

        func rowSlice(_ y: Int) -> ArraySlice<UInt8>? {
            if y < headerHeight {
                let o = y * stride
                return headerBytes[o..<(o + stride)]
            }
            let cy = y - headerHeight
            if cy < topRowCount {
                let o = cy * stride
                return topRowsData[o..<(o + stride)]
            }
            let by = cy - topRowCount
            if by < bottomRowCount {
                let o = by * stride
                return bottomRowsData[o..<(o + stride)]
            }
            let fy = by - bottomRowCount
            if fy < footerHeight {
                let o = fy * stride
                return footerBytes[o..<(o + stride)]
            }
            return nil
        }

        for ty in 0..<th {
            let sy = (ty * totalH) / th
            guard let row = rowSlice(sy) else { continue }
            let rowStart = row.startIndex
            for tx in 0..<tw {
                let sx = ((tx * width) / tw) * 4
                let dst = (ty * tw + tx) * 4
                thumb[dst] = row[rowStart + sx]
                thumb[dst + 1] = row[rowStart + sx + 1]
                thumb[dst + 2] = row[rowStart + sx + 2]
                thumb[dst + 3] = row[rowStart + sx + 3]
            }
        }
        return PixelBufferRGBA(width: tw, height: th, rgba: thumb).makeCGImage()
    }
}
