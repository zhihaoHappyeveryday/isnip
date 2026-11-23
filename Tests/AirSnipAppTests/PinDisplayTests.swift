import AppKit
import ImageIO
import XCTest
import AirSnipCore
@testable import AirSnipApp

final class PinDisplayTests: XCTestCase {
    @MainActor
    func testRestoringAnOversizedHistoryPinStartsWithTheWholeImageOnScreen() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let visible = screen.visibleFrame
        let image = try makeImage(width: 1_622, height: 30_000)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("isnip-display-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pasteboard = NSPasteboard.withUniqueName()
        defer {
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: directory)
        }

        let configURL = directory.appendingPathComponent("config.json")
        var config = AirSnipConfig()
        config.lastSaveDirectory = directory.path
        try config.save(to: configURL)
        let baseSize = NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
        let oldSize = NSSize(width: baseSize.width * 0.85, height: baseSize.height * 0.85)
        let state = PinDisplayState(
            frame: NSRect(x: visible.midX - oldSize.width / 2, y: visible.midY - oldSize.height / 2,
                          width: oldSize.width, height: oldSize.height),
            baseSize: baseSize, backingScale: 2, zoomScale: 0.85,
            preferredOpacity: 0.8, effectiveWindowOpacity: 0.8, showBorder: true, isClickThrough: false
        )
        let history = ClosedPinHistory(configURL: configURL)
        history.remember([PinSnapshot(image: image, originalText: nil, displayState: state)],
                         historyRoot: OutputService.pinHistoryRootURL(for: config))
        await withCheckedContinuation { done in
            history.finishPendingWrites { done.resume() }
        }

        let app = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard)
        defer {
            app.pinManager.windows.forEach { $0.window.orderOut(nil) }
            app.settingsController = nil
        }
        for _ in 0..<2 {
            await withCheckedContinuation { done in
                app.triggerPinOrRestore(completion: { done.resume() })
            }
            weak var closedImage: CGImage?
            weak var closedWindow: NSWindow?
            try autoreleasepool {
                let pin = try XCTUnwrap(app.pinManager.windows.last)
                let frame = pin.window.frame
                XCTAssertTrue(visible.contains(frame))
                XCTAssertEqual(frame.height, visible.height, accuracy: 1)
                XCTAssertEqual(frame.width / frame.height, baseSize.width / baseSize.height, accuracy: 0.002)
                XCTAssertEqual(pin.cgImage.height, image.height)
                XCTAssertEqual(pin.opacity, 0.8, accuracy: 0.001)

                // The next restore must fit again even if the pin is closed while zoomed.
                pin.adjustZoom(delta: 1, anchorInWindow: NSPoint(x: frame.width / 2, y: frame.height / 2))
                closedImage = pin.cgImage
                closedWindow = pin.window
                app.pinManager.closeAll()
            }
            await withCheckedContinuation { done in
                app.pinManager.finishHistoryWrites { done.resume() }
            }
            XCTAssertNil(closedImage)
            XCTAssertNil(closedWindow)
        }
    }

    @MainActor
    func testZoomingATallPinKeepsTheWindowOnScreenAndReturnsToTheWholeImage() throws {
        _ = NSApplication.shared
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        var config = AirSnipConfig()
        config.pinHistoryLimit = 0
        let manager = PinManager(pasteboard: .withUniqueName(), historyConfigURL: nil, historyLimit: 0) { _ in
            FileManager.default.temporaryDirectory
        }
        manager.getConfig = { config }
        defer {
            manager.closeAll()
            manager.pasteboard.releaseGlobally()
        }

        let image = try makeImage(width: 640, height: Int(visible.height * 2 / 0.195))
        XCTAssertTrue(manager.createPin(cgImage: image, backingScale: 2, preferredScreenOriginAppKit: nil, config: config))
        let pin = try XCTUnwrap(manager.windows.last)
        let fitScale = pin.zoomScale
        XCTAssertLessThan(fitScale, 0.2)
        XCTAssertGreaterThan(fitScale, 0.19)

        func scroll(_ delta: CGFloat) -> Bool {
            let frame = pin.window.frame
            pin.adjustZoom(delta: delta, anchorInWindow: NSPoint(x: frame.width / 2, y: frame.height / 2))
            let bounded = visible.contains(pin.window.frame)
            XCTAssertTrue(bounded, "A zoomed pin must stay within the display's available area")
            return bounded
        }

        guard scroll(1) else { return }
        XCTAssertEqual(pin.zoomScale, 0.2)
        var reachedOriginalSize = false
        for _ in 0..<50 {
            guard scroll(1) else { return }
            reachedOriginalSize = reachedOriginalSize || pin.zoomScale == 1
        }
        XCTAssertTrue(reachedOriginalSize)
        XCTAssertEqual(pin.zoomScale, 4)
        for _ in 0..<50 where pin.zoomScale > 0.2 {
            guard scroll(-1) else { return }
        }
        XCTAssertEqual(pin.zoomScale, 0.2)
        guard scroll(-1) else { return }
        XCTAssertEqual(pin.zoomScale, fitScale, accuracy: 0.0001)
        XCTAssertEqual(pin.cgImage.height, image.height)
    }

    @MainActor
    func testBrowsingHintWaitsForTheCurrentToastAndDismissesAfterTheImageMoves() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        var config = AirSnipConfig()
        config.pinHistoryLimit = 0
        let manager = PinManager(pasteboard: .withUniqueName(), historyConfigURL: nil, historyLimit: 0) { _ in
            FileManager.default.temporaryDirectory
        }
        defer {
            manager.closeAll()
            manager.pasteboard.releaseGlobally()
        }
        let image = try makeImage(width: 320, height: Int(screen.visibleFrame.height * 2))
        XCTAssertTrue(manager.createPin(cgImage: image, backingScale: 1, preferredScreenOriginAppKit: nil, config: config))
        let pin = try XCTUnwrap(manager.windows.last)
        func zoomInAtTop() {
            let size = pin.window.frame.size
            pin.adjustZoom(delta: 1, anchorInWindow: NSPoint(x: size.width / 2, y: size.height))
        }
        func visibleToast() -> NSWindow? {
            NSApp.windows.first { $0.identifier?.rawValue == "iSnip.toast" && $0.isVisible }
        }

        let status = ToastHUD.show("Recognizing Text", kind: .information, duration: .infinity)
        defer { ToastHUD.dismiss(status) }
        let statusWindow = try XCTUnwrap(visibleToast())
        zoomInAtTop()
        XCTAssertTrue(visibleToast() === statusWindow)

        ToastHUD.dismiss(status)
        zoomInAtTop()
        let hint = try XCTUnwrap(visibleToast())
        XCTAssertEqual(hint.frame.maxY, screen.visibleFrame.maxY - 22, accuracy: 1)
        let labels = hint.contentView?.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels?.contains(L10n.tr("按住 ⇧ Shift 并滚动滚轮", "Hold ⇧ Shift and scroll")) == true)

        try scrollPin(pin, by: 24, modifiers: .maskShift)
        XCTAssertTrue(visibleToast() === hint)
        let origin = pin.projectedImageFrame.origin
        try scrollPin(pin, by: -24, modifiers: [.maskShift, .maskCommand])
        XCTAssertLessThan(pin.opacity, 1)
        XCTAssertEqual(pin.projectedImageFrame.origin, origin)
        XCTAssertTrue(visibleToast() === hint)

        try scrollPin(pin, by: -24, modifiers: .maskShift)
        XCTAssertGreaterThan(pin.projectedImageFrame.minY, origin.y)
        XCTAssertNil(visibleToast())
        zoomInAtTop()
        XCTAssertNil(visibleToast())
    }

    @MainActor
    func testAnnotatingTheBottomOfAZoomedPinEditsThatPartOfTheFullImage() throws {
        _ = NSApplication.shared
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let image = try makeImage(width: 640, height: Int(visible.height) * 6)
        var config = AirSnipConfig()
        config.pinHistoryLimit = 0
        let manager = PinManager(pasteboard: .withUniqueName(), historyConfigURL: nil, historyLimit: 0) { _ in
            FileManager.default.temporaryDirectory
        }
        manager.getConfig = { config }
        defer {
            manager.closeAll()
            manager.pasteboard.releaseGlobally()
        }
        XCTAssertTrue(manager.createPin(cgImage: image, backingScale: 2, preferredScreenOriginAppKit: nil, config: config))
        let pin = try XCTUnwrap(manager.windows.last)
        for _ in 0..<30 where pin.zoomScale < 1 {
            let frame = pin.window.frame
            pin.adjustZoom(delta: 1, anchorInWindow: NSPoint(x: frame.width / 2, y: frame.height / 2))
        }
        XCTAssertEqual(pin.zoomScale, 1)
        let frame = pin.window.frame
        try scrollPin(pin, by: -Int32(image.height), modifiers: .maskShift)
        XCTAssertEqual(pin.window.frame, frame)
        XCTAssertEqual(pin.zoomScale, 1)
        XCTAssertEqual(pin.projectedImageFrame.minY, frame.minY)

        for coversDesktop in [true, false] {
            config.pinAnnotationCoversDesktop = coversDesktop
            let editor = CaptureSessionCoordinator(config: config, mode: .pinAnnotation(pin))
            editor.startPinAnnotation()
            defer { editor.cancelSession() }
            let output = try XCTUnwrap(editor.renderStandaloneAnnotatedOutputSample())
            guard output.width == image.width, output.height == image.height else {
                XCTFail("Annotation must retain all \(image.width) × \(image.height) pixels")
                continue
            }
            let pixels = try XCTUnwrap(PixelBufferRGBA(cgImage: output))
            let mark = pixels.pixel(x: 48, y: image.height - Int(pin.window.frame.height * 2) + 16)
            XCTAssertGreaterThan(mark.r, 240)
            XCTAssertLessThan(mark.g, 15)
        }
    }

    @MainActor
    func testATallOriginalUsesWindowDraggingEvenWhenOnlyItsWidthIsClipped() throws {
        _ = NSApplication.shared
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        var config = AirSnipConfig()
        config.pinHistoryLimit = 0
        let manager = PinManager(pasteboard: .withUniqueName(), historyConfigURL: nil, historyLimit: 0) { _ in
            FileManager.default.temporaryDirectory
        }
        defer {
            manager.closeAll()
            manager.pasteboard.releaseGlobally()
        }

        let image = try makeImage(width: Int(visible.width * 2), height: Int(visible.height * 1.2))
        XCTAssertTrue(manager.createPin(cgImage: image, backingScale: 1, preferredScreenOriginAppKit: nil, config: config))
        let pin = try XCTUnwrap(manager.windows.last)
        pin.adjustZoom(delta: 1, anchorInWindow: .zero)
        XCTAssertGreaterThan(pin.projectedImageFrame.width, pin.window.frame.width)
        XCTAssertEqual(pin.projectedImageFrame.height, pin.window.frame.height)
        let imageOffsetX = pin.projectedImageFrame.minX - pin.window.frame.minX
        try dragPinImage(pin, dx: -CGFloat(image.width), dy: 0)
        XCTAssertEqual(pin.projectedImageFrame.minX - pin.window.frame.minX, imageOffsetX)
    }

    @MainActor
    func testPanningAWidePinChangesWhatIsDrawnAndExportsTheWholeImage() throws {
        _ = NSApplication.shared
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("isnip-display-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = AirSnipConfig()
        config.lastSaveDirectory = directory.path
        config.askBeforeSave = false
        config.lastSaveFormat = .png
        config.smartPngCompression = false
        config.showCompletionToast = false
        let manager = PinManager(pasteboard: .withUniqueName(), historyConfigURL: nil, historyLimit: 0) { _ in directory }
        manager.getConfig = { config }
        defer {
            manager.closeAll()
            manager.pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: directory)
        }
        let width = Int(visible.width) * 2
        let image = try makeImage(width: width, height: 160) { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: 160))
        }
        OutputService.copyImageToClipboard(image, backingScale: 1, config: config, to: manager.pasteboard)
        let clipboard = try XCTUnwrap(OutputService.readImageFromClipboard(from: manager.pasteboard))
        XCTAssertTrue(manager.createPin(cgImage: clipboard.cgImage, backingScale: 1,
                                        preferredScreenOriginAppKit: nil, config: config))
        let pin = try XCTUnwrap(manager.windows.last)
        XCTAssertEqual(pin.window.frame.width, visible.width)
        XCTAssertEqual(pin.window.frame.height / pin.window.frame.width, 160.0 / CGFloat(width), accuracy: 0.002)
        for _ in 0..<30 where pin.zoomScale < 1 {
            let frame = pin.window.frame
            pin.adjustZoom(delta: 1, anchorInWindow: NSPoint(x: frame.width / 2, y: frame.height / 2))
        }
        let zoomedFrame = pin.window.frame
        try dragPinImage(pin, dx: CGFloat(width), dy: 0)
        let left = try centerColor(of: pin)
        try dragPinImage(pin, dx: -CGFloat(width), dy: 0)
        let right = try centerColor(of: pin)
        XCTAssertEqual(pin.window.frame, zoomedFrame)
        XCTAssertEqual(left.redComponent, left.blueComponent, accuracy: 0.02)
        XCTAssertGreaterThan(right.blueComponent - right.redComponent, 0.65)

        pin.copyToClipboard()
        let copied = try XCTUnwrap(OutputService.readImageFromClipboard(from: manager.pasteboard)).cgImage
        pin.savePin()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let savedURL = try XCTUnwrap(files.first { $0.pathExtension == "png" })
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(savedURL as CFURL, nil))
        let saved = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        for exported in [copied, saved] {
            XCTAssertEqual(exported.width, image.width)
            XCTAssertEqual(exported.height, image.height)
            let pixels = try XCTUnwrap(PixelBufferRGBA(cgImage: exported))
            XCTAssertLessThan(pixels.pixel(x: width / 4, y: 80).b, 160)
            XCTAssertGreaterThan(pixels.pixel(x: width * 3 / 4, y: 80).b, 240)
        }

        for _ in 0..<50 {
            pin.adjustZoom(delta: -1, anchorInWindow: .zero)
        }
        XCTAssertEqual(pin.zoomScale, 0.2)
    }

    @MainActor
    private func scrollPin(_ pin: PinWindowController, by points: Int32, modifiers: CGEventFlags) throws {
        let view = try XCTUnwrap(pin.window.contentView)
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                         wheel1: points, wheel2: 0, wheel3: 0))
        event.flags = modifiers
        view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
    }

    @MainActor
    private func dragPinImage(_ pin: PinWindowController, dx: CGFloat, dy: CGFloat) throws {
        let view = try XCTUnwrap(pin.window.contentView)
        let start = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        let end = NSPoint(x: start.x + dx, y: start.y + dy)
        func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: pin.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }
        view.mouseDown(with: try event(.leftMouseDown, at: start))
        view.mouseDragged(with: try event(.leftMouseDragged, at: end))
        view.mouseUp(with: try event(.leftMouseUp, at: end))
    }

    @MainActor
    private func centerColor(of pin: PinWindowController) throws -> NSColor {
        let view = try XCTUnwrap(pin.window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
        return try XCTUnwrap(color?.usingColorSpace(.deviceRGB))
    }

    private func makeImage(width: Int, height: Int, draw: (CGContext) -> Void = { _ in }) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.45, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        return try XCTUnwrap(context.makeImage())
    }
}
