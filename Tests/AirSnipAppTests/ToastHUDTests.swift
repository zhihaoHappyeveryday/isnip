import AppKit
import AirSnipCore
import XCTest
@testable import AirSnipApp

final class ToastHUDTests: XCTestCase {
    @MainActor
    func testAnOlderDismissRequestCannotHideARefreshedToast() async throws {
        _ = NSApplication.shared
        let original = ToastHUD.show("Recognizing Text", kind: .information, duration: .infinity)
        let panel = try XCTUnwrap(visibleToast)
        let refreshed = ToastHUD.show("Recognizing Text", kind: .information, duration: .infinity)
        defer { ToastHUD.dismiss(refreshed) }

        XCTAssertTrue(visibleToast === panel)
        ToastHUD.dismiss(original)
        XCTAssertTrue(visibleToast === panel)
    }

    @MainActor
    func testRepeatedToastKeepsItsWindowAndRestartsItsTimer() async throws {
        _ = NSApplication.shared
        ToastHUD.show("贴图已达上限", kind: .warning, detail: "关闭贴图，腾出位置后再试",
                      countText: "4 / 4", duration: 0.5)
        let first = try XCTUnwrap(visibleToast)
        let level = first.level

        try await Task.sleep(for: .milliseconds(250))
        ToastHUD.show("贴图已达上限", kind: .warning, detail: "关闭贴图，腾出位置后再试",
                      countText: "4 / 4", duration: 0.7)
        XCTAssertTrue(visibleToast === first)
        XCTAssertEqual(first.level, level)
        try await Task.sleep(for: .milliseconds(470))
        XCTAssertTrue(visibleToast === first)

        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(visibleToast)
    }

    @MainActor
    func testChangedCountReplacesTheToastAndSurvivesTheOldDeadline() async throws {
        _ = NSApplication.shared
        ToastHUD.show("Pin limit reached", kind: .warning, countText: "4 / 4", duration: 0.25)
        let previous = try XCTUnwrap(visibleToast)
        ToastHUD.show("Pin limit reached", kind: .warning, countText: "7 / 5", duration: 0.8)
        let replacement = try XCTUnwrap(visibleToast)

        XCTAssertFalse(previous.isVisible)
        XCTAssertFalse(previous === replacement)
        try await Task.sleep(for: .milliseconds(520))
        XCTAssertTrue(visibleToast === replacement)
    }

    @MainActor
    func testLongGuidanceWrapsAboveTheCaptureWindowWithoutTakingInput() async throws {
        _ = NSApplication.shared
        let overlay = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        overlay.level = .screenSaver
        let guidance = "Click the window again to retry, or drag a new selection around the content you want to capture across the screen."
        ToastHUD.show("Window capture failed", kind: .warning, detail: guidance, above: overlay)
        let toast = try XCTUnwrap(visibleToast)
        let card = try XCTUnwrap(toast.contentView)
        let detail = try XCTUnwrap(card.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == guidance })

        XCTAssertGreaterThan(toast.frame.height, 77)
        XCTAssertTrue(card.bounds.contains(detail.frame))
        XCTAssertGreaterThan(toast.level.rawValue, overlay.level.rawValue)
        XCTAssertFalse(toast.canBecomeKey)
        XCTAssertTrue(toast.ignoresMouseEvents)
    }

    @MainActor
    func testStatusToastIsVisibleAboveAnActiveCaptureOverlay() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let overlay = NSPanel(
            contentRect: NSRect(x: screen.frame.midX, y: screen.frame.midY, width: 24, height: 24),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        overlay.orderFrontRegardless()
        defer { overlay.orderOut(nil) }

        for level in [NSWindow.Level.screenSaver, NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)] {
            overlay.level = level
            ToastHUD.show("Pin borders hidden", kind: .information, symbol: "rectangle.dashed")
            let toast = try XCTUnwrap(visibleToast)
            XCTAssertGreaterThan(toast.level.rawValue, overlay.level.rawValue)
            XCTAssertFalse(toast.canBecomeKey)
        }
    }

    @MainActor
    func testPinLimitShowsActualCountEvenWhenCompletionToastsAreOff() async throws {
        _ = NSApplication.shared
        let pins = PinManager(pasteboard: .withUniqueName())
        defer { pins.closeAll() }
        var config = AirSnipConfig()
        config.pinHistoryLimit = 0
        config.showCompletionToast = false
        config.pinMaxCount = 2
        pins.getConfig = { config }
        let image = try pinImage()
        for _ in 0..<2 {
            XCTAssertTrue(pins.createPin(cgImage: image, backingScale: 1, preferredScreenOriginAppKit: nil, config: config))
        }

        config.pinMaxCount = 1
        XCTAssertFalse(pins.createPin(cgImage: image, backingScale: 1, preferredScreenOriginAppKit: nil, config: config))
        let card = try XCTUnwrap(visibleToast?.contentView)
        XCTAssertTrue(labelTexts(in: card).contains("2 / 1"))
        XCTAssertEqual(pins.count, 2)
    }

    @MainActor
    func testCopyOriginalTextUsesTheCurrentCompletionSetting() async throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        let pins = PinManager(pasteboard: pasteboard)
        defer { pins.closeAll() }
        var config = AirSnipConfig()
        config.pinHistoryLimit = 0
        config.showCompletionToast = false
        pins.getConfig = { config }
        XCTAssertTrue(pins.createPin(cgImage: try pinImage(), backingScale: 1,
                                     preferredScreenOriginAppKit: nil, config: config, originalText: "A pin's text"))
        let pin = try XCTUnwrap(pins.windows.last)
        ToastHUD.show("Pin copy verification", kind: .warning)
        let previous = try XCTUnwrap(visibleToast)
        pin.copyOriginalText()

        XCTAssertEqual(pasteboard.string(forType: .string), "A pin's text")
        XCTAssertTrue(visibleToast === previous)

        config.showCompletionToast = true
        pin.copyOriginalText()
        let card = try XCTUnwrap(visibleToast?.contentView)
        XCTAssertTrue(labelTexts(in: card).contains(L10n.tr("已复制原文", "Original Text Copied")))
    }

    @MainActor
    func testToastFollowsTheAppThemeEvenWhenTheSystemAppearanceDiffers() async throws {
        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            NSApp.appearance = previousAppearance
            try? FileManager.default.removeItem(at: directory)
        }
        let app = AirSnipAppController(configURL: directory.appendingPathComponent("config.json"),
                                     pinPasteboard: .withUniqueName())

        NSApp.appearance = NSAppearance(named: .aqua)
        app.updateConfig { $0.theme = .dark }
        ToastHUD.show("Theme preview", kind: .information)
        XCTAssertLessThan(try visibleBackground().redComponent, 0.3)

        NSApp.appearance = NSAppearance(named: .darkAqua)
        app.updateConfig { $0.theme = .light }
        ToastHUD.show("Theme preview", kind: .information)
        XCTAssertGreaterThan(try visibleBackground().redComponent, 0.8)
        XCTAssertEqual(app.config.theme, .light)
    }

    @MainActor
    private var visibleToast: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "iSnip.toast" && $0.isVisible }
    }

    private func pinImage() throws -> CGImage {
        let pixels = PixelBufferRGBA(width: 16, height: 16, rgba: [UInt8](repeating: 255, count: 16 * 16 * 4))
        return try XCTUnwrap(pixels.makeCGImage())
    }

    @MainActor
    private func visibleBackground() throws -> NSColor {
        let fill = try XCTUnwrap(visibleToast?.contentView?.layer?.backgroundColor)
        return try XCTUnwrap(NSColor(cgColor: fill)?.usingColorSpace(.sRGB))
    }

    @MainActor
    private func labelTexts(in view: NSView) -> [String] {
        if let label = view as? NSTextField { return [label.stringValue] }
        return view.subviews.flatMap { labelTexts(in: $0) }
    }
}
