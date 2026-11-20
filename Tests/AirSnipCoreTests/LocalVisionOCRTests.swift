import XCTest
import CoreGraphics
import CoreText
import CoreImage
import Vision
@testable import AirSnipCore

final class LocalVisionOCRTests: XCTestCase {
    func testAccurateFailureRetriesCPUWithChineseSupport() throws {
        let context = try makeContext(width: 800, height: 200)
        draw("截图识字 Hello 123", at: CGPoint(x: 20, y: 70), in: context)
        let handler = VNImageRequestHandler(cgImage: try XCTUnwrap(context.makeImage()), options: [:])
        var attempts = 0
        let observations = try LocalVisionOCR.performTextRecognition(languagePreference: "zh-Hans") { request in
            attempts += 1
            XCTAssertEqual(request.recognitionLevel, .accurate)
            XCTAssertEqual(request.recognitionLanguages, ["zh-Hans", "en-US"])
            if attempts == 1 { throw NSError(domain: "OCRTest", code: 1) }
            try handler.perform([request])
        }
        XCTAssertEqual(attempts, 2)
        let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        XCTAssertTrue(text.contains("截图识字"), text)
        XCTAssertTrue(text.contains("Hello 123"), text)
    }

    func testAccurateFailuresDoNotSilentlyDiscardUnsupportedLanguages() {
        for language in ["auto", "", "zh-Hans", "zh-Hant", "ja-JP", "ko-KR", "invalid-language"] {
            var attempts = 0
            let failure = NSError(domain: "OCRTest", code: 42)
            XCTAssertThrowsError(try LocalVisionOCR.performTextRecognition(languagePreference: language) { request in
                attempts += 1
                XCTAssertEqual(request.recognitionLevel, .accurate, language)
                throw failure
            }) { error in
                let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
                XCTAssertEqual(underlying?.domain, failure.domain)
                XCTAssertEqual(underlying?.code, failure.code)
            }
            XCTAssertEqual(attempts, 2, language)
        }
    }

    func testFastFallbackStillRecognizesExplicitEnglish() throws {
        let context = try makeContext(width: 800, height: 200)
        draw("Hello 123", at: CGPoint(x: 20, y: 70), in: context)
        let handler = VNImageRequestHandler(cgImage: try XCTUnwrap(context.makeImage()), options: [:])
        var attempts = 0
        let observations = try LocalVisionOCR.performTextRecognition(languagePreference: "en-US") { request in
            attempts += 1
            XCTAssertTrue(request.recognitionLanguages.allSatisfy { $0 == "en-US" })
            if attempts < 3 { throw NSError(domain: "OCRTest", code: attempts) }
            XCTAssertEqual(request.recognitionLevel, .fast)
            try handler.perform([request])
        }
        XCTAssertEqual(attempts, 3)
        XCTAssertTrue(observations.contains { $0.topCandidates(1).first?.string == "Hello 123" })
    }

    func testFastFallbackPropagatesRecognitionFailure() {
        var attempts = 0
        XCTAssertThrowsError(try LocalVisionOCR.performTextRecognition(languagePreference: "en-US") { _ in
            attempts += 1
            throw NSError(domain: "OCRTest", code: attempts)
        }) { error in
            XCTAssertEqual((error as NSError).domain, "OCRTest")
            XCTAssertEqual((error as NSError).code, 3)
        }
        XCTAssertEqual(attempts, 3)
    }

    func testDarkTerminalScreenshotRecognizesChineseAndCommands() throws {
        let context = try makeContext(width: 1100, height: 220)
        context.setFillColor(CGColor(srgbRed: 0.13, green: 0.15, blue: 0.19, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        let lines = [
            "可以选择服务器作为中转，这是开放的端口：22,80,443",
            "已确认 HTTP 验证被外部连接超时阻断",
            "python3 -m venv /tmp/example/certbot-env"
        ]
        for (index, text) in lines.enumerated() {
            draw(text, at: CGPoint(x: 20, y: 20 + index * 60), in: context,
                 fontSize: 28, color: CGColor(gray: 0.9, alpha: 1))
        }
        for language in ["auto", "zh-Hans"] {
            let result = try LocalVisionOCR.recognizeDetailed(
                cgImage: XCTUnwrap(context.makeImage()), languagePreference: language, detectBarcodes: false
            )
            XCTAssertTrue(result.rawText.contains("可以选择服务器作为中转"), result.rawText)
            XCTAssertTrue(result.rawText.contains("验证被外部连接超时阻断"), result.rawText)
            XCTAssertTrue(result.rawText.contains(lines[2]), result.rawText)
        }
    }

    func testRecognitionTilesBoundWorkAndCoverImageWithOverlap() {
        for (width, height) in [(800, 200), (4096, 4096), (680, 20_000), (100_000, 40), (8200, 8200)] {
            let tiles = LocalVisionOCR.recognitionTiles(width: width, height: height)
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            XCTAssertEqual(tiles.first?.origin, .zero)
            XCTAssertEqual(tiles.last?.maxX, bounds.maxX)
            XCTAssertEqual(tiles.last?.maxY, bounds.maxY)
            for tile in tiles {
                XCTAssertTrue(bounds.contains(tile))
                XCTAssertLessThanOrEqual(tile.width, tiles.count == 1 ? 4096 : 2048)
                XCTAssertLessThanOrEqual(tile.height, tiles.count == 1 ? 4096 : 2048)
            }
            let firstRow = tiles.filter { $0.minY == 0 }
            for (previous, next) in zip(firstRow, firstRow.dropFirst()) {
                XCTAssertGreaterThanOrEqual(previous.maxX - next.minX, 256)
            }
            let firstColumn = tiles.filter { $0.minX == 0 }
            for (previous, next) in zip(firstColumn, firstColumn.dropFirst()) {
                XCTAssertGreaterThanOrEqual(previous.maxY - next.minY, 256)
            }
            if width == height || (width == 800 && height == 200) {
                if width <= 4096 { XCTAssertEqual(tiles.count, 1) }
            }
        }
    }

    func testMergeTileLinesDeduplicatesPositionsNotRepeatedText() {
        let lines = [
            LocalVisionOCR.RecognizedLine(text: "Hello", bounds: CGRect(x: 10, y: 1790, width: 90, height: 30), confidence: 0.9, tileIndex: 0),
            LocalVisionOCR.RecognizedLine(text: "Helo", bounds: CGRect(x: 11, y: 1792, width: 88, height: 29), confidence: 0.7, tileIndex: 1),
            LocalVisionOCR.RecognizedLine(text: "Hello", bounds: CGRect(x: 10, y: 1850, width: 90, height: 30), confidence: 0.9, tileIndex: 1),
            LocalVisionOCR.RecognizedLine(text: "World", bounds: CGRect(x: 150, y: 1790, width: 90, height: 30), confidence: 0.9, tileIndex: 1)
        ]
        let merged = LocalVisionOCR.mergeTileLines(lines)
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged.filter { $0.words == ["Hello"] }.count, 2)
        XCTAssertFalse(merged.contains { $0.words == ["Helo"] })
        XCTAssertTrue(merged.contains { $0.words == ["World"] })
    }

    func testAutomaticRecognitionWithChineseEnglishAndQRCode() throws {
        let context = try makeContext(width: 800, height: 200)
        draw("截图识字 Hello 123", at: CGPoint(x: 20, y: 70), in: context)
        let payload = "https://example.com/ocr-test"
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let qr = try XCTUnwrap(filter.outputImage)
        let qrImage = try XCTUnwrap(CIContext().createCGImage(qr, from: qr.extent))
        context.interpolationQuality = .none
        context.draw(qrImage, in: CGRect(x: 600, y: 20, width: 160, height: 160))

        let result = try LocalVisionOCR.recognizeDetailed(cgImage: XCTUnwrap(context.makeImage()))
        XCTAssertTrue(result.rawText.contains("截图识字"), result.rawText)
        XCTAssertTrue(result.rawText.contains("Hello 123"), result.rawText)
        XCTAssertEqual(result.barcodes, [payload])
    }

    func testTinyImagesReturnEmptyInsteadOfVisionInvalidImageError() throws {
        for (width, height) in [(1, 1), (1, 1000), (1000, 1), (2, 2)] {
            let context = try makeContext(width: width, height: height)
            for detectBarcodes in [false, true] {
                let result = try LocalVisionOCR.recognizeDetailed(
                    cgImage: XCTUnwrap(context.makeImage()), detectBarcodes: detectBarcodes
                )
                XCTAssertTrue(result.isEmpty, "\(width)x\(height)")
            }
        }
    }

    func testVeryWideImageDoesNotCollapseToTwoPixelsInsideVision() throws {
        // Vision downsizes the old single request to 4032 x 2 and throws Code=13.
        let context = try makeContext(width: 100_000, height: 40)
        draw("Hello 123", at: CGPoint(x: 20, y: 2), in: context, fontSize: 30)
        draw("World 456", at: CGPoint(x: 99_700, y: 2), in: context, fontSize: 30)
        let result = try LocalVisionOCR.recognizeDetailed(
            cgImage: XCTUnwrap(context.makeImage()), detectBarcodes: false
        )
        XCTAssertTrue(result.rawText.contains("Hello 123"), result.rawText)
        XCTAssertTrue(result.rawText.contains("World 456"), result.rawText)
    }

    func testLongScreenshotPreservesOrderAndRepeatedLinesAcrossTileSeams() throws {
        let context = try makeContext(width: 680, height: 20_000)
        // Include a line at an overlap boundary, and identical lines at different positions.
        let lines: [(CGFloat, String)] = [
            (40, "First 123"),
            (1900, "Boundary 456"),
            (3680, "Repeated 789"),
            (7250, "Repeated 789"),
            (19_800, "Last 321")
        ]
        for (top, text) in lines {
            draw(text, at: CGPoint(x: 24, y: top), in: context)
        }
        let result = try LocalVisionOCR.recognizeDetailed(
            cgImage: XCTUnwrap(context.makeImage()), detectBarcodes: false
        )
        XCTAssertEqual(
            result.rawText.components(separatedBy: .newlines).filter { !$0.isEmpty },
            lines.map(\.1)
        )
    }

    func testWideTextLineAcrossHorizontalTilesDoesNotLoseOrRepeatWords() throws {
        let context = try makeContext(width: 5000, height: 200)
        let text = "The quick brown fox jumps over the lazy dog 12345"
        draw(text, at: CGPoint(x: 1550, y: 70), in: context)
        let result = try LocalVisionOCR.recognizeDetailed(
            cgImage: XCTUnwrap(context.makeImage()), languagePreference: "en-US", detectBarcodes: false
        )
        XCTAssertEqual(result.rawText, text)
    }

    private func makeContext(width: Int, height: Int) throws -> CGContext {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    private func draw(_ text: String, at point: CGPoint, in context: CGContext, fontSize: CGFloat = 36,
                      color: CGColor = CGColor(gray: 0, alpha: 1)) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [
                .font: CTFontCreateWithName("PingFangSC-Regular" as CFString, fontSize, nil),
                .foregroundColor: color
            ]
        ))
        context.textPosition = CGPoint(x: point.x, y: CGFloat(context.height) - point.y - fontSize)
        CTLineDraw(line, context)
    }
}
