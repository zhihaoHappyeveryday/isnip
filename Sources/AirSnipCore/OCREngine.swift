import Foundation
import CoreGraphics
import CoreML
import CoreText
import Vision

public struct OCRTextSegment: Equatable, Sendable {
    public var left: Double
    public var top: Double
    public var bottom: Double
    public var words: [String]

    public init(left: Double, top: Double, bottom: Double, words: [String]) {
        self.left = left
        self.top = top
        self.bottom = bottom
        self.words = words
    }

    public var centerY: Double { (top + bottom) * 0.5 }
    public var height: Double { max(1.0, bottom - top) }
}

public struct OCRRecognitionResult: Equatable, Sendable {
    public var rawText: String
    public var paragraphText: String
    public var barcodes: [String]

    public init(rawText: String, paragraphText: String, barcodes: [String] = []) {
        self.rawText = rawText
        self.paragraphText = paragraphText
        self.barcodes = barcodes
    }

    public var isEmpty: Bool {
        rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && barcodes.isEmpty
    }
}

public enum OCRLinesJoiner {
    public static func joinSegments(_ input: [OCRTextSegment]) -> String {
        let sorted = input.sorted { $0.centerY < $1.centerY }
        var rows: [[OCRTextSegment]] = []

        for seg in sorted {
            if let lastRow = rows.last, let head = lastRow.first,
               abs(seg.centerY - head.centerY) <= max(head.height, seg.height) * 0.5 {
                rows[rows.count - 1].append(seg)
            } else {
                rows.append([seg])
            }
        }

        var output = ""
        var prevBottom: Double?

        for var row in rows {
            row.sort { $0.left < $1.left }
            let words = row
                .flatMap { $0.words }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if words.isEmpty { continue }

            let rowTop = row.map(\.top).min() ?? 0
            let rowBottom = row.map(\.bottom).max() ?? rowTop
            let rowHeight = max(1.0, rowBottom - rowTop)

            if !output.isEmpty {
                if let pb = prevBottom, (rowTop - pb) > rowHeight * 0.95 {
                    output.append("\n\n")
                } else {
                    output.append("\n")
                }
            }
            prevBottom = rowBottom

            for (i, w) in words.enumerated() {
                if i > 0 && needSpace(between: words[i - 1], and: w) {
                    output.append(" ")
                }
                output.append(w)
            }
        }
        return stripCJKSpaces(output)
    }

    /// Merges single-line soft wraps within paragraphs while keeping blank-line paragraph breaks and bullet lists intact.
    public static func mergeWrappedParagraphs(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        var paragraphs: [String] = []
        var current = ""

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current)
                    current = ""
                }
                continue
            }

            if current.isEmpty {
                current = trimmed
            } else if isListItemStart(trimmed) || endsWithHardSentenceStopAndShort(current) {
                paragraphs.append(current)
                current = trimmed
            } else {
                if current.hasSuffix("-") && !current.hasSuffix("--"),
                   let beforeHyphen = current.dropLast().last,
                   beforeHyphen.isLetter && !isCJK(beforeHyphen),
                   let nextFirst = trimmed.first, nextFirst.isLowercase {
                    current.removeLast()
                    current.append(trimmed)
                } else {
                    if needSpace(between: current, and: trimmed) {
                        current.append(" ")
                    }
                    current.append(trimmed)
                }
            }
        }
        if !current.isEmpty {
            paragraphs.append(current)
        }
        return stripCJKSpaces(paragraphs.joined(separator: "\n\n"))
    }

    private static func isListItemStart(_ s: String) -> Bool {
        let bullets: [Character] = ["•", "·", "-", "*", "—", "▪", "▸"]
        if let first = s.first, bullets.contains(first) {
            return true
        }
        // e.g. "1. ", "2) ", "(1)"
        if s.range(of: #"^(\(?\d+[\.\)、\)]|[一二三四五六七八九十]+[、\.])\s*"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func endsWithHardSentenceStopAndShort(_ s: String) -> Bool {
        false
    }

    public static func stripCJKSpaces(_ src: String) -> String {
        let scalars = Array(src)
        var out = ""
        out.reserveCapacity(src.count)
        for i in 0..<scalars.count {
            let c = scalars[i]
            if c == " " {
                if i > 0 && i + 1 < scalars.count && isCJK(scalars[i - 1]) && isCJK(scalars[i + 1]) {
                    continue
                }
            }
            out.append(c)
        }
        return out
    }

    public static func needSpace(between prev: String, and next: String) -> Bool {
        guard let a = prev.last, let b = next.first else { return false }
        return !(isCJK(a) || isCJK(b))
    }

    public static func isCJK(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        switch v {
        case 0x3000...0x303F, // CJK punctuation
             0x3040...0x30FF, // Hiragana & Katakana
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK Unified Ideographs
             0xAC00...0xD7AF, // Hangul Syllables
             0xF900...0xFAFF, // CJK Compatibility Ideographs
             0xFF00...0xFFEF: // Fullwidth forms
            return true
        default:
            return false
        }
    }
}

public enum LocalVisionOCR {
    /// Vision downsizes large images internally, losing small text in long screenshots and even throwing
    /// VNErrorInvalidImage when the short edge collapses to two pixels. Keep native pixels in overlapping
    /// tiles for long/oversized images; ordinary screenshots still use a single request.
    static func recognitionTiles(width: Int, height: Int) -> [CGRect] {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if max(width, height) <= 4096 && max(width, height) <= min(width, height) * 4 {
            return [bounds]
        }
        let tileSize = 2048
        let overlap = 256
        func starts(length: Int) -> [Int] {
            guard length > tileSize else { return [0] }
            var result = [0]
            while let last = result.last, last + tileSize < length {
                result.append(min(last + tileSize - overlap, length - tileSize))
            }
            return result
        }
        return starts(length: height).flatMap { y in
            starts(length: width).map { x in
                CGRect(x: x, y: y, width: min(tileSize, width - x), height: min(tileSize, height - y))
            }
        }
    }

    struct RecognizedLine {
        let text: String
        let bounds: CGRect
        let confidence: Float
        let tileIndex: Int
    }

    /// Horizontal seams can cut a line in half. Match words (or individual CJK characters) by their
    /// actual boxes instead of treating overlapping partial lines as duplicates and losing their tails.
    private static func textRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var wordStart: String.Index?
        for index in text.indices {
            let character = text[index]
            if character.isWhitespace || OCRLinesJoiner.isCJK(character) {
                if let start = wordStart { ranges.append(start..<index) }
                wordStart = nil
                if !character.isWhitespace { ranges.append(index..<text.index(after: index)) }
            } else if wordStart == nil {
                wordStart = index
            }
        }
        if let start = wordStart { ranges.append(start..<text.endIndex) }
        return ranges
    }

    /// Bounding boxes can shift slightly between tiles. Hard ownership cutoffs can drop a line from BOTH
    /// tiles at a seam. Merge spatial duplicates instead, keeping repeated text at different positions.
    static func mergeTileLines(_ lines: [RecognizedLine]) -> [OCRTextSegment] {
        var unique: [RecognizedLine] = []
        for line in lines.sorted(by: {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.text.count > $1.text.count
        }) {
            let isDuplicate = unique.contains { other in
                guard other.tileIndex != line.tileIndex else { return false }
                let overlap = line.bounds.intersection(other.bounds)
                guard !overlap.isNull else { return false }
                let smallerArea = min(line.bounds.width * line.bounds.height, other.bounds.width * other.bounds.height)
                return overlap.width * overlap.height > smallerArea * 0.5
            }
            if !isDuplicate { unique.append(line) }
        }
        return unique.map { line in
            OCRTextSegment(left: Double(line.bounds.minX), top: Double(line.bounds.minY),
                           bottom: Double(line.bounds.maxY), words: [line.text])
        }
    }

    /// Shared request configuration so the real OCR path and the warm-up path load the exact same Vision models.
    static func configure(_ request: VNRecognizeTextRequest, languagePreference: String) {
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        // `automaticallyDetectsLanguage = true` makes Vision compile a model set per candidate language on the
        // first run of every new binary (measured ~52 s vs ~14 s with a fixed list), so "auto" uses a fixed,
        // priority-ordered list instead. zh-Hans first covers Simplified/Traditional Chinese, Japanese and English;
        // Korean text needs the explicit 한국어 option (a Hangul-first list would drop Chinese lines).
        request.automaticallyDetectsLanguage = false
        if languagePreference == "auto" || languagePreference.isEmpty {
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
        } else {
            switch languagePreference {
            case "zh-Hans":
                request.recognitionLanguages = ["zh-Hans", "en-US"]
            case "zh-Hant":
                request.recognitionLanguages = ["zh-Hant", "en-US"]
            default:
                request.recognitionLanguages = [languagePreference, "en-US"]
            }
        }
    }

    private static func pinToCPU(_ request: VNRequest) {
        guard let cpuDevice = MLComputeDevice.allComputeDevices.first(where: {
            if case .cpu = $0 { return true }
            return false
        }), let stages = try? request.supportedComputeStageDevices.keys else {
            return
        }
        for stage in stages {
            request.setComputeDevice(cpuDevice, for: stage)
        }
    }

    private static func performTextRecognition(
        handler: VNImageRequestHandler,
        languagePreference: String
    ) throws -> [VNRecognizedTextObservation] {
        // Tier 1: Default hardware-accelerated .accurate (GPU/ANE on Apple Silicon & supported Intel/AMD GPUs)
        let primary = VNRecognizeTextRequest()
        configure(primary, languagePreference: languagePreference)
        if (try? handler.perform([primary])) != nil {
            return primary.results ?? []
        }

        // Tier 2: Fresh .accurate pinned to MLCPUComputeDevice (handles unsupported Radeon/Metal shader drivers on amd64 Macs)
        let cpuAccurate = VNRecognizeTextRequest()
        configure(cpuAccurate, languagePreference: languagePreference)
        pinToCPU(cpuAccurate)
        if (try? handler.perform([cpuAccurate])) != nil {
            return cpuAccurate.results ?? []
        }

        // Tier 3: Fresh .fast pinned to MLCPUComputeDevice (handles Rosetta 2 x86_64 environments lacking .accurate Espresso slices)
        let fastFallback = VNRecognizeTextRequest()
        fastFallback.recognitionLevel = .fast
        fastFallback.usesLanguageCorrection = true
        if let supported = try? fastFallback.supportedRecognitionLanguages(), !supported.isEmpty {
            let preferred = primary.recognitionLanguages.filter { supported.contains($0) }
            fastFallback.recognitionLanguages = preferred.isEmpty ? [supported[0]] : preferred
        }
        pinToCPU(fastFallback)
        try handler.perform([fastFallback])
        return fastFallback.results ?? []
    }

    /// Vision loads / compiles its recognition models on the first request after boot or cache eviction,
    /// which was measured at 16–25 s. Running one tiny request in the background at launch moves that cost
    /// off the user's critical path so the first real screenshot OCR is fast.
    public static func prewarm(languagePreference: String = "auto") {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let image = makeWarmupImage() else { return }
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            _ = try? performTextRecognition(handler: handler, languagePreference: languagePreference)
        }
    }

    private static func makeWarmupImage() -> CGImage? {
        let width = 480, height = 96
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributed = NSAttributedString(
            string: "截图识字 iSnip OCR 123",
            attributes: [
                .font: CTFontCreateWithName("PingFangSC-Regular" as CFString, 40, nil),
                .foregroundColor: CGColor(gray: 0, alpha: 1)
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: 16, y: 32)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    public static func recognize(cgImage: CGImage, languagePreference: String = "auto") throws -> String {
        let detailed = try recognizeDetailed(
            cgImage: cgImage,
            languagePreference: languagePreference,
            detectBarcodes: false
        )
        return detailed.rawText
    }

    public static func recognizeDetailed(
        cgImage: CGImage,
        languagePreference: String = "auto",
        detectBarcodes: Bool = true
    ) throws -> OCRRecognitionResult {
        // There cannot be legible text or a barcode in a one-/two-pixel-wide image. Vision throws
        // VNErrorInvalidImage for these inputs; return the normal empty result instead.
        guard cgImage.width > 2, cgImage.height > 2 else {
            return OCRRecognitionResult(rawText: "", paragraphText: "")
        }

        var lines: [RecognizedLine] = []
        var detectedPayloads: [String] = []
        let tiles = recognitionTiles(width: cgImage.width, height: cgImage.height)
        let hasHorizontalSeams = tiles.contains { $0.minX > 0 }

        for (tileIndex, tile) in tiles.enumerated() {
            // Release Vision's intermediate images after every tile, not after the entire longshot.
            try autoreleasepool {
                let image: CGImage
                if tiles.count == 1 {
                    image = cgImage
                } else if let crop = cgImage.cropping(to: tile) {
                    image = crop
                } else {
                    throw NSError(domain: VNErrorDomain, code: VNErrorCode.invalidImage.rawValue,
                                  userInfo: [NSLocalizedDescriptionKey: L10n.tr("无法读取识别图片，请重新截图。", "Unable to read image for OCR. Please capture again.")])
                }

                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                let observations = try performTextRecognition(handler: handler, languagePreference: languagePreference)

                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    func append(_ text: String, box: CGRect) {
                        // Convert Vision's bottom-left normalized boxes back to source-image pixels.
                        lines.append(RecognizedLine(
                            text: text,
                            bounds: CGRect(
                                x: tile.minX + box.minX * CGFloat(image.width),
                                y: tile.minY + (1 - box.maxY) * CGFloat(image.height),
                                width: box.width * CGFloat(image.width),
                                height: box.height * CGFloat(image.height)
                            ),
                            confidence: candidate.confidence,
                            tileIndex: tileIndex
                        ))
                    }
                    if hasHorizontalSeams {
                        let fragments = textRanges(in: candidate.string).compactMap { range -> (String, CGRect)? in
                            guard let box = try? candidate.boundingBox(for: range) else { return nil }
                            return (String(candidate.string[range]), box.boundingBox)
                        }
                        if !fragments.isEmpty {
                            for (fragment, box) in fragments { append(fragment, box: box) }
                        } else {
                            append(text, box: observation.boundingBox)
                        }
                    } else {
                        append(text, box: observation.boundingBox)
                    }
                }

                if detectBarcodes {
                    // Barcode detection is optional: a failure must not discard successfully recognized text.
                    let barcodeRequest = VNDetectBarcodesRequest()
                    if (try? handler.perform([barcodeRequest])) == nil {
                        let cpuBarcodeRequest = VNDetectBarcodesRequest()
                        pinToCPU(cpuBarcodeRequest)
                        _ = try? handler.perform([cpuBarcodeRequest])
                        for item in cpuBarcodeRequest.results ?? [] {
                            if let payload = item.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !payload.isEmpty, !detectedPayloads.contains(payload) {
                                detectedPayloads.append(payload)
                            }
                        }
                    } else {
                        for item in barcodeRequest.results ?? [] {
                            if let payload = item.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !payload.isEmpty, !detectedPayloads.contains(payload) {
                                detectedPayloads.append(payload)
                            }
                        }
                    }
                }
            }
        }

        let rawText = OCRLinesJoiner.joinSegments(mergeTileLines(lines))
        let paragraphText = OCRLinesJoiner.mergeWrappedParagraphs(rawText)
        return OCRRecognitionResult(
            rawText: rawText,
            paragraphText: paragraphText,
            barcodes: detectedPayloads
        )
    }
}
