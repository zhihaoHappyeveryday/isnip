import AppKit
import AirSnipCore
import XCTest
@testable import AirSnipApp

final class OCRCopyCloseTests: XCTestCase {
    @MainActor
    func testAutomaticCopyDoesNotShowARecognitionWindowWhenBothSettingsAreOn() async throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let manager = OCRBubbleManager(recognizeImage: { _, _, _ in
            OCRRecognitionResult(rawText: "First line\nSecond line", paragraphText: "First line Second line")
        }, writeText: { OutputService.copyStringToClipboard($0, to: pasteboard) })
        defer { manager.dismiss() }
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))

        var config = AirSnipConfig()
        config.ocr.autoCopy = true
        config.showCompletionToast = false
        manager.recognizeAndPresent(rawSelectionImage: try image(), anchorScreenPoint: nil, config: config)

        XCTAssertNil(newPanel(since: existing), "The panel must stay hidden while OCR runs")
        try await waitForRecognition(manager)
        XCTAssertEqual(pasteboard.string(forType: .string), "First line\nSecond line")
        XCTAssertNil(newPanel(since: existing))
        XCTAssertNil(manager.sourceImage, "Closed OCR must release the screenshot")
    }

    @MainActor
    func testSlowAutomaticCopyShowsProgressUntilRecognitionFinishes() async throws {
        _ = NSApplication.shared
        let recognition = AsyncStream<Void>.makeStream()
        var copiedText: String?
        let manager = OCRBubbleManager(recognizeImage: { _, _, _ in
            var waiting = recognition.stream.makeAsyncIterator()
            _ = await waiting.next()
            return OCRRecognitionResult(rawText: "Recognized text", paragraphText: "Recognized text")
        }, writeText: {
            copiedText = $0
            return true
        })
        defer {
            recognition.continuation.finish()
            manager.dismiss()
        }
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        var config = AirSnipConfig()
        config.language = .en
        config.showCompletionToast = false
        config.ocr.autoCopy = true
        manager.recognizeAndPresent(rawSelectionImage: try image(), anchorScreenPoint: nil, config: config)

        XCTAssertNil(toast(titled: "Recognizing Text"))
        try await waitUntil { self.toast(titled: "Recognizing Text") != nil }
        XCTAssertNotNil(toast(titled: "Recognizing Text"))
        XCTAssertNil(newPanel(since: existing))

        manager.closeAfterCopy = false
        recognition.continuation.yield()
        try await waitForRecognition(manager)
        XCTAssertEqual(copiedText, "Recognized text")
        XCTAssertNil(toast(titled: "Recognizing Text"))
        XCTAssertNil(toast(titled: "Copied"))
        XCTAssertNil(newPanel(since: existing), "A request started in the background stays hidden after a successful copy")
    }

    @MainActor
    func testReplacingBackgroundOCRClearsItsProgressAndCopiesOnlyTheNewResult() async throws {
        _ = NSApplication.shared
        var firstRequest: CheckedContinuation<Void, Never>?
        var oldResultReturned = false
        var attempts = 0
        var copies: [String] = []
        let manager = OCRBubbleManager(recognizeImage: { _, _, _ in
            attempts += 1
            if attempts == 1 {
                await withCheckedContinuation { firstRequest = $0 }
                oldResultReturned = true
                return OCRRecognitionResult(rawText: "Old text", paragraphText: "Old text")
            }
            return OCRRecognitionResult(rawText: "New text", paragraphText: "New text")
        }, writeText: {
            copies.append($0)
            return true
        })
        defer {
            firstRequest?.resume()
            manager.dismiss()
        }
        var config = AirSnipConfig()
        config.language = .en
        config.ocr.autoCopy = true
        config.showCompletionToast = false
        let image = try image()
        manager.recognizeAndPresent(rawSelectionImage: image, anchorScreenPoint: nil, config: config)
        try await waitUntil { self.toast(titled: "Recognizing Text") != nil }
        XCTAssertNotNil(toast(titled: "Recognizing Text"))

        manager.recognizeAndPresent(rawSelectionImage: image, anchorScreenPoint: nil, config: config)
        XCTAssertNil(toast(titled: "Recognizing Text"))
        try await waitForRecognition(manager)
        let staleRequest = try XCTUnwrap(firstRequest)
        firstRequest = nil
        staleRequest.resume()
        try await waitUntil { oldResultReturned }
        XCTAssertTrue(oldResultReturned)
        XCTAssertEqual(copies, ["New text"])
    }

    @MainActor
    func testBackgroundRecognitionFailureOpensPanelAndCanBeRetried() async throws {
        _ = NSApplication.shared
        var shouldFail = true
        var copiedText: String?
        let manager = OCRBubbleManager(recognizeImage: { _, _, _ in
            if shouldFail { throw CocoaError(.fileReadCorruptFile) }
            return OCRRecognitionResult(rawText: "Recovered text", paragraphText: "Recovered text")
        }, writeText: {
            copiedText = $0
            return true
        })
        defer { manager.dismiss() }
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        var config = AirSnipConfig()
        config.ocr.autoCopy = true
        config.showCompletionToast = false
        manager.recognizeAndPresent(rawSelectionImage: try image(), anchorScreenPoint: nil, config: config)

        try await waitForRecognition(manager)
        let panel = try XCTUnwrap(newPanel(since: existing))
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertNil(copiedText)

        shouldFail = false
        manager.rerunRecognitionIfPossible()
        try await waitForRecognition(manager)
        XCTAssertEqual(copiedText, "Recovered text")
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    func testClipboardFailureRevealsTheTextAndAllowsManualCopy() async throws {
        _ = NSApplication.shared
        var clipboardAcceptsText = false
        var copiedText: String?
        let manager = OCRBubbleManager(recognizeImage: { _, _, _ in
            OCRRecognitionResult(rawText: "Recognized text", paragraphText: "Recognized text")
        }, writeText: {
            guard clipboardAcceptsText else { return false }
            copiedText = $0
            return true
        })
        defer { manager.dismiss() }
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        var config = AirSnipConfig()
        config.language = .en
        config.ocr.autoCopy = true
        config.showCompletionToast = false
        manager.recognizeAndPresent(rawSelectionImage: try image(), anchorScreenPoint: nil, config: config)

        try await waitForRecognition(manager)
        let panel = try XCTUnwrap(newPanel(since: existing))
        XCTAssertEqual(manager.text, "Recognized text")
        XCTAssertNil(copiedText)
        XCTAssertNotNil(toast(titled: "Could Not Copy OCR Result"))

        manager.copyCurrentText()
        XCTAssertTrue(panel.isVisible)
        clipboardAcceptsText = true
        manager.copyCurrentText()
        XCTAssertEqual(copiedText, "Recognized text")
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    func testManualCopyRespectsTheCurrentSettingAndCopiesEditedTextFromAPinnedPanel() async throws {
        _ = NSApplication.shared
        var copiedText: String?
        let manager = OCRBubbleManager(recognizeImage: { _, _, _ in
            OCRRecognitionResult(rawText: "Recognized text", paragraphText: "Recognized text")
        }, writeText: {
            copiedText = $0
            return true
        })
        defer { manager.dismiss() }
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        var config = AirSnipConfig()
        config.language = .en
        config.ocr.closeAfterCopy = false
        manager.isPinnedOnTop = true
        manager.recognizeAndPresent(rawSelectionImage: try image(), anchorScreenPoint: nil, config: config)
        try await waitForRecognition(manager)
        let panel = try XCTUnwrap(newPanel(since: existing))
        XCTAssertNil(copiedText)

        manager.text = "Edited first line\nSecond line"
        manager.copyCurrentText()
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(manager.copiedFeedback)
        XCTAssertEqual(copiedText, manager.text)

        manager.closeAfterCopy = true
        manager.copyCurrentText()
        XCTAssertFalse(panel.isVisible)
        XCTAssertNotNil(toast(titled: "Copied"))
    }

    @MainActor
    func testScreenshotTranslationStaysOpenWhenBothSettingsAreOn() async throws {
        _ = NSApplication.shared
        var copies: [String] = []
        let manager = OCRBubbleManager(recognizeImage: { _, _, _ in
            OCRRecognitionResult(rawText: "Hello world", paragraphText: "Hello world")
        }, writeText: {
            copies.append($0)
            return true
        })
        defer { manager.dismiss() }
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        var config = AirSnipConfig()
        config.ocr.autoCopy = true
        config.translation.targetLanguage = "en"
        manager.recognizeAndPresent(
            rawSelectionImage: try image(), anchorScreenPoint: nil, config: config, translateOnCompletion: true
        )

        let panel = try XCTUnwrap(newPanel(since: existing))
        try await waitForRecognition(manager)
        XCTAssertEqual(copies, ["Hello world"])
        XCTAssertTrue(panel.isVisible)
        manager.copyCurrentText()
        XCTAssertEqual(copies, ["Hello world", "Hello world"])
        XCTAssertTrue(panel.isVisible)
    }

    private func image() throws -> CGImage {
        try XCTUnwrap(PixelBufferRGBA(width: 4, height: 4, rgba: [UInt8](repeating: 255, count: 64)).makeCGImage())
    }

    @MainActor
    private func newPanel(since existing: Set<ObjectIdentifier>) -> NSWindow? {
        NSApp.windows.first {
            $0 is NSPanel && $0.isVisible && $0.identifier?.rawValue != "iSnip.toast"
                && !existing.contains(ObjectIdentifier($0))
        }
    }

    @MainActor
    private func toast(titled title: String) -> NSWindow? {
        NSApp.windows.first { window in
            window.isVisible && window.identifier?.rawValue == "iSnip.toast"
                && window.contentView?.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == title } == true
        }
    }

    @MainActor
    private func waitForRecognition(_ manager: OCRBubbleManager) async throws {
        try await waitUntil { !manager.isRecognizing }
        XCTAssertFalse(manager.isRecognizing, "OCR did not finish")
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
