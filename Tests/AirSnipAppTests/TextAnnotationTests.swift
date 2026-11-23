import AppKit
import Carbon
import XCTest
import AirSnipCore
@testable import AirSnipApp

final class TextAnnotationTests: XCTestCase {
    @MainActor
    func testClickCentersTheFirstCaretAtBothFontSizes() throws {
        for size in [16.0, 32.0] {
            var config = AirSnipConfig()
            config.defaultFontFamily = "PingFang SC"
            config.defaultFontSize = size
            let screenshot = try AnnotationWindow(config: config)
            defer { screenshot.session.cancelSession() }
            try screenshot.clickToolbar(.tool(.text))

            let point = NSPoint(x: 180, y: 220)
            try screenshot.click(at: point)
            let editor = try screenshot.textView()
            let caret = screenshot.caretRect(in: editor)
            XCTAssertEqual(caret.minX, point.x, accuracy: 1 / screenshot.scale)
            XCTAssertEqual(caret.midY, point.y, accuracy: 1 / screenshot.scale, "\(size) pt")

            editor.insertText("中 H", replacementRange: editor.selectedRange())
            XCTAssertEqual(screenshot.caretRect(in: editor).midY, point.y, accuracy: 1 / screenshot.scale)
        }
    }

    @MainActor
    func testClickToTypeWrapsAtTheSelectionEdgeAndCopiesTheSameLayout() throws {
        let screenshot = try AnnotationWindow()
        defer { screenshot.session.cancelSession() }
        try screenshot.clickToolbar(.tool(.text))

        let start = NSPoint(x: 280, y: 163)
        try screenshot.hover(at: start)
        XCTAssertEqual(NSCursor.current, NSCursor.iBeam)
        try screenshot.click(at: start)
        let text = try screenshot.textView()
        XCTAssertEqual(screenshot.caretRect(in: text).midY, start.y, accuracy: 1 / screenshot.scale)
        XCTAssertFalse(text.drawsBackground)
        text.insertText("测试文字测试文字", replacementRange: text.selectedRange())
        try screenshot.pressKey(kVK_Return, characters: "\r")
        text.insertText("iSnip", replacementRange: text.selectedRange())
        XCTAssertEqual(text.string, "测试文字测试文字\niSnip")

        let live = try screenshot.textRows(in: screenshot.preview())
        XCTAssertEqual(live.count, 3)
        let x = Double(start.x - screenshot.selection.minX) * screenshot.scale
        XCTAssertEqual(Double(try XCTUnwrap(live.first).minX), x, accuracy: 4 * screenshot.scale)

        var copied: CGImage?
        screenshot.session.onCompleteCopy = { image, _ in copied = image }
        try screenshot.clickToolbar(.copy)
        let exported = try screenshot.textRows(in: XCTUnwrap(copied))
        assertSameTextRows(live, exported)
    }

    @MainActor
    func testEscapeWhileComposingKeepsTheDraftOpen() throws {
        let screenshot = try AnnotationWindow()
        defer { screenshot.session.cancelSession() }
        try screenshot.clickToolbar(.tool(.text))
        try screenshot.click(at: NSPoint(x: 150, y: 170))
        let text = try screenshot.textView()
        text.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: text.selectedRange())
        XCTAssertTrue(text.hasMarkedText())

        try screenshot.pressKey(kVK_Escape, characters: "\u{1b}")
        XCTAssertTrue(screenshot.window.firstResponder === text)

        text.unmarkText()
        try screenshot.pressKey(kVK_Escape, characters: "\u{1b}")
        XCTAssertFalse(screenshot.window.firstResponder is NSTextView)
        XCTAssertTrue(screenshot.session.hasVisibleWindows)
    }

    @MainActor
    func testChangingFontSizeKeepsTheTextOriginWhenReopened() throws {
        var config = AirSnipConfig()
        config.defaultFontSize = 16
        let screenshot = try AnnotationWindow(config: config)
        defer { screenshot.session.cancelSession() }
        try screenshot.clickToolbar(.tool(.text))

        let start = NSPoint(x: 180, y: 220)
        try screenshot.click(at: start)
        let text = try screenshot.textView()
        let originalTop = screenshot.caretRect(in: text).minY
        text.insertText("H", replacementRange: text.selectedRange())
        try screenshot.click(at: NSPoint(x: 260, y: 270))
        try screenshot.pressKey(kVK_Escape, characters: "\u{1b}")

        let hit = NSPoint(x: start.x + 4, y: start.y)
        try screenshot.click(at: hit)
        for _ in 0..<8 { try screenshot.clickToolbar(id: "text.size.up") }
        try screenshot.click(at: hit, count: 2)
        let resized = try screenshot.textView()
        XCTAssertEqual(resized.font?.pointSize, 32)
        XCTAssertEqual(screenshot.caretRect(in: resized).minY, originalTop, accuracy: 1 / screenshot.scale)
    }

    @MainActor
    func testTwoClicksPlaceTwoDraftsAndDoubleClickEditsTheMovedTextInPlace() throws {
        let screenshot = try AnnotationWindow()
        defer { screenshot.session.cancelSession() }
        try screenshot.clickToolbar(.tool(.text))

        let start = NSPoint(x: 280, y: 163)
        let content = "测试文字测试文字"
        try screenshot.click(at: start)
        let first = try screenshot.textView()
        let firstLineTop = screenshot.caretRect(in: first).minY
        first.insertText(content, replacementRange: first.selectedRange())
        let nextStart = NSPoint(x: start.x - 2, y: start.y + 5)
        try screenshot.click(at: nextStart)
        let next = try screenshot.textView()
        XCTAssertFalse(first === next)
        XCTAssertEqual(screenshot.caretRect(in: next).midY, nextStart.y, accuracy: 1 / screenshot.scale)
        XCTAssertTrue(next.string.isEmpty)
        next.insertText("取消", replacementRange: next.selectedRange())
        try screenshot.pressKey(kVK_Escape, characters: "\u{1b}")
        XCTAssertTrue(screenshot.session.hasVisibleWindows)
        XCTAssertFalse(screenshot.window.firstResponder is NSTextView)
        let initial = try screenshot.textRows(in: screenshot.preview())
        XCTAssertEqual(initial.count, 2)

        try screenshot.click(at: NSPoint(x: start.x + 10, y: firstLineTop + 20))
        XCTAssertFalse(screenshot.window.firstResponder is NSTextView)
        // Move toward the left edge, then move back. The two wrapped lines keep their spacing.
        let movedLineTop = firstLineTop + 8
        try screenshot.drag(from: NSPoint(x: start.x + 10, y: firstLineTop), to: NSPoint(x: 100, y: movedLineTop))
        try screenshot.drag(from: NSPoint(x: 110, y: movedLineTop), to: NSPoint(x: 190, y: movedLineTop))
        let moved = try screenshot.textRows(in: screenshot.preview())
        XCTAssertEqual(moved, initial.map { $0.offsetBy(dx: -110 * screenshot.scale, dy: 8 * screenshot.scale) })

        let hit = NSPoint(x: 171, y: movedLineTop + 1)
        try screenshot.click(at: hit, count: 2)
        let editing = try screenshot.textView()
        XCTAssertEqual(editing.string, content)
        XCTAssertEqual(screenshot.caretRect(in: editing).minY, movedLineTop, accuracy: 1 / screenshot.scale)
        editing.string = "改"
        XCTAssertEqual(try screenshot.textRows(in: screenshot.preview()).count, 1)
        try screenshot.pressKey(kVK_Escape, characters: "\u{1b}")
        XCTAssertEqual(try screenshot.textRows(in: screenshot.preview()), moved)

        try screenshot.click(at: hit, count: 2)
        try screenshot.textView().string = ""
        try screenshot.click(at: NSPoint(x: 135, y: 290))
        try screenshot.pressKey(kVK_Escape, characters: "\u{1b}")
        XCTAssertTrue(try screenshot.textRows(in: screenshot.preview()).isEmpty)
        try screenshot.clickToolbar(.undo)
        XCTAssertEqual(try screenshot.textRows(in: screenshot.preview()), moved)

        try screenshot.click(at: NSPoint(x: 182, y: movedLineTop + 19))
        let corner = NSPoint(x: 170 + first.bounds.width, y: movedLineTop + first.bounds.height)
        try screenshot.drag(from: corner, to: NSPoint(x: corner.x + 30, y: corner.y + 22))
        let resized = try screenshot.textRows(in: screenshot.preview())
        XCTAssertGreaterThan(try XCTUnwrap(resized.first).height, try XCTUnwrap(moved.first).height)
    }

    @MainActor
    func testTypingAtTheTopKeepsTheClickHeightAndClipsTheOutput() throws {
        let screenshot = try AnnotationWindow()
        defer { screenshot.session.cancelSession() }
        try screenshot.clickToolbar(.tool(.text))
        let halfHeight = try screenshot.unclippedCaretHeight() / 2

        let edge = NSPoint(x: 180, y: screenshot.selection.minY + 2)
        try screenshot.click(at: edge)
        let editor = try screenshot.textView()
        let caret = screenshot.caretRect(in: editor)
        XCTAssertEqual(caret.minY, screenshot.selection.minY, accuracy: 1 / screenshot.scale)
        XCTAssertEqual(caret.maxY, edge.y + halfHeight, accuracy: 1 / screenshot.scale)

        editor.insertText("H", replacementRange: editor.selectedRange())
        let visible = try screenshot.textRows(in: screenshot.preview())
        XCTAssertEqual(try XCTUnwrap(visible.first).minY, 0)
        var copied: CGImage?
        screenshot.session.onCompleteCopy = { image, _ in copied = image }
        try screenshot.clickToolbar(.copy)
        assertSameTextRows(visible, try screenshot.textRows(in: XCTUnwrap(copied)))
    }

    @MainActor
    func testTypingAtTheBottomRightKeepsTheClickHeightEvenWhenAMarkIsClipped() throws {
        let screenshot = try AnnotationWindow()
        defer { screenshot.session.cancelSession() }
        try screenshot.clickToolbar(.tool(.text))
        let halfHeight = try screenshot.unclippedCaretHeight() / 2

        let edge = NSPoint(x: screenshot.selection.maxX - 2, y: screenshot.selection.maxY - 12)
        try screenshot.click(at: edge)
        let editor = try screenshot.textView()
        let caret = screenshot.caretRect(in: editor)
        XCTAssertEqual(caret.minX, edge.x, accuracy: 1 / screenshot.scale)
        XCTAssertEqual(caret.minY, edge.y - halfHeight, accuracy: 1 / screenshot.scale)
        XCTAssertEqual(caret.maxY, screenshot.selection.maxY, accuracy: 1 / screenshot.scale)
        editor.insertText("T", replacementRange: editor.selectedRange())
        let visible = try screenshot.textRows(in: screenshot.preview())
        let first = try XCTUnwrap(visible.first)
        XCTAssertLessThanOrEqual(first.width, 2 * screenshot.scale)

        var copied: CGImage?
        screenshot.session.onCompleteCopy = { image, _ in copied = image }
        try screenshot.clickToolbar(.copy)
        assertSameTextRows(visible, try screenshot.textRows(in: XCTUnwrap(copied)))
    }

    @MainActor
    func testAnnotatingAFittedLongScreenshotSavesTheFullSizeImage() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let image = try Self.whiteImage(width: 500, height: Int(screen.frame.height) * 3)
        let mode = CaptureSessionCoordinator.SessionMode.standaloneImageEdit(image, 1, screen)
        let session = CaptureSessionCoordinator(config: AirSnipConfig(), mode: mode)
        defer { session.cancelSession() }
        session.startStandaloneImageEdit(cgImage: image, backingScale: 1, screen: screen)
        let window = try AnnotationWindow(session: session)
        _ = try XCTUnwrap(session.renderToolbarVerificationSample())
        try window.clickToolbar(.tool(.text))
        let center = NSPoint(x: window.canvas.bounds.midX, y: window.canvas.bounds.midY)
        try window.click(at: center)
        let text = try window.textView()
        XCTAssertEqual(window.caretRect(in: text).midY, center.y, accuracy: 1 / window.window.backingScaleFactor)
        text.insertText("长图", replacementRange: text.selectedRange())
        var saved: CGImage?
        session.onSaveImage = { image, _, _, _ in saved = image; return true }
        try window.clickToolbar(.save)

        let output = try XCTUnwrap(saved)
        XCTAssertEqual(output.width, image.width)
        XCTAssertEqual(output.height, image.height)
        let line = try XCTUnwrap(window.textRows(in: output).first)
        XCTAssertEqual(line.minX, CGFloat(image.width) / 2, accuracy: 10)
        XCTAssertEqual(line.midY, CGFloat(image.height) / 2, accuracy: 15)
    }

    @MainActor
    func testTextOnTheVisibleBottomOfAScrolledPinIsWrittenToThatPartOfTheOriginal() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let image = try Self.whiteImage(width: 700, height: Int(screen.visibleFrame.height) * 4)
        var config = AirSnipConfig()
        config.pinHistoryLimit = 0
        config.pinAnnotationCoversDesktop = false
        let pins = PinManager(pasteboard: .withUniqueName(), historyConfigURL: nil, historyLimit: 0) { _ in
            FileManager.default.temporaryDirectory
        }
        defer {
            pins.closeAll()
            pins.pasteboard.releaseGlobally()
        }
        XCTAssertTrue(pins.createPin(cgImage: image, backingScale: 2, preferredScreenOriginAppKit: nil, config: config))
        let pin = try XCTUnwrap(pins.windows.last)
        for _ in 0..<30 where pin.zoomScale < 1 {
            let size = pin.window.frame.size
            pin.adjustZoom(delta: 1, anchorInWindow: NSPoint(x: size.width / 2, y: size.height))
        }
        XCTAssertEqual(pin.zoomScale, 1)
        let size = pin.window.frame.size
        pin.adjustZoom(delta: 1, anchorInWindow: NSPoint(x: size.width / 2, y: size.height))
        XCTAssertGreaterThan(pin.zoomScale, 1)
        let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                          wheel1: -Int32(image.height), wheel2: 0, wheel3: 0))
        scroll.flags = .maskShift
        pin.window.contentView?.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: scroll)))
        let frame = pin.window.frame
        let imageFrame = pin.projectedImageFrame
        XCTAssertEqual(imageFrame.minY, frame.minY, accuracy: 1)

        let session = CaptureSessionCoordinator(config: config, mode: .pinAnnotation(pin))
        defer { session.cancelSession() }
        session.startPinAnnotation()
        let window = try AnnotationWindow(session: session)
        _ = try XCTUnwrap(session.renderToolbarVerificationSample())
        try window.clickToolbar(.tool(.text))

        let location = NSRect(x: frame.minX + 30, y: frame.maxY - 95, width: 1, height: 1)
        let click = window.canvas.convert(window.window.convertFromScreen(location).origin, from: nil)
        try window.click(at: click)
        let text = try window.textView()
        XCTAssertEqual(window.caretRect(in: text).midY, click.y, accuracy: 1 / window.window.backingScaleFactor)
        text.insertText("H中\nH图", replacementRange: text.selectedRange())

        let sample = NSRect(x: click.x - 4, y: click.y - 25, width: 150, height: 90)
        let preview = try window.preview(in: sample)
        let liveRows = try window.textRows(in: preview)
        XCTAssertEqual(liveRows.count, 2)

        let sampleInWindow = window.canvas.convert(sample.origin, to: nil)
        let sampleOnScreen = window.window.convertToScreen(NSRect(origin: sampleInWindow, size: .zero)).origin
        let previewScale = CGFloat(preview.width) / sample.width
        let sourceScaleX = CGFloat(image.width) / imageFrame.width
        let sourceScaleY = CGFloat(image.height) / imageFrame.height
        let projectedRows = liveRows.map { row in
            CGRect(
                x: (sampleOnScreen.x - imageFrame.minX + row.minX / previewScale) * sourceScaleX,
                y: (imageFrame.maxY - sampleOnScreen.y + row.minY / previewScale) * sourceScaleY,
                width: row.width / previewScale * sourceScaleX,
                height: row.height / previewScale * sourceScaleY
            )
        }
        try window.clickToolbar(.copy)

        XCTAssertEqual(pin.cgImage.width, image.width)
        XCTAssertEqual(pin.cgImage.height, image.height)
        let exportedRows = try window.textRows(in: pin.cgImage)
        assertSameTextRows(projectedRows, exportedRows, accuracy: max(sourceScaleX, sourceScaleY))
    }

    private static func whiteImage(width: Int, height: Int) throws -> CGImage {
        let pixels = PixelBufferRGBA(width: width, height: height, rgba: [UInt8](repeating: 255, count: width * height * 4))
        return try XCTUnwrap(pixels.makeCGImage())
    }

    private func assertSameTextRows(
        _ preview: [CGRect], _ output: [CGRect], accuracy: CGFloat = 1, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(preview.count, output.count, file: file, line: line)
        for (before, after) in zip(preview, output) {
            XCTAssertEqual(before.minX, after.minX, accuracy: accuracy, file: file, line: line)
            XCTAssertEqual(before.minY, after.minY, accuracy: accuracy, file: file, line: line)
            XCTAssertEqual(before.width, after.width, accuracy: accuracy, file: file, line: line)
            XCTAssertEqual(before.height, after.height, accuracy: accuracy, file: file, line: line)
        }
    }

    @MainActor
    private final class AnnotationWindow {
        let session: CaptureSessionCoordinator
        let canvas: OverlayCanvasView
        let window: NSWindow
        let selection: NSRect
        let scale: Double

        convenience init(config: AirSnipConfig = AirSnipConfig()) throws {
            _ = NSApplication.shared
            let screen = try XCTUnwrap(NSScreen.main)
            let scale = screen.backingScaleFactor
            let frame = NSRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY, width: 720, height: 520)
            let width = Int(frame.width * scale)
            let height = Int(frame.height * scale)
            let pixels = PixelBufferRGBA(width: width, height: height, rgba: [UInt8](repeating: 255, count: width * height * 4))
            let snapshot = CapturedScreenSnapshot(
                screen: screen, frameInGlobalAppKit: frame,
                frameTopDown: ASRect(x: 0, y: 0, width: frame.width, height: frame.height),
                cgImage: try XCTUnwrap(pixels.makeCGImage()), rawBuffer: pixels, backingScale: scale,
                windowsLocalTopDown: []
            )
            let session = CaptureSessionCoordinator(config: config)
            session.startWithSnapshots([snapshot])
            let selection = NSRect(x: 96, y: 130, width: 294, height: 235)
            try self.init(session: session, selection: selection, scale: scale)
            try drag(from: selection.origin, to: NSPoint(x: selection.maxX, y: selection.maxY))
            _ = try XCTUnwrap(session.renderToolbarVerificationSample())
        }

        init(session: CaptureSessionCoordinator, selection: NSRect = .zero, scale: Double = 1) throws {
            self.session = session
            self.selection = selection
            self.scale = scale
            window = try XCTUnwrap(NSApp.windows.first { session.activeWindowNumbers.contains($0.windowNumber) })
            canvas = try XCTUnwrap(window.contentView as? OverlayCanvasView)
        }

        func textView() throws -> NSTextView {
            try XCTUnwrap(window.firstResponder as? NSTextView)
        }

        func caretRect(in editor: NSTextView) -> NSRect {
            let screen = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
            return canvas.convert(window.convertFromScreen(screen), from: nil)
        }

        func unclippedCaretHeight() throws -> CGFloat {
            try click(at: NSPoint(x: selection.midX, y: selection.midY))
            let height = caretRect(in: try textView()).height
            try pressKey(kVK_Escape, characters: "\u{1b}")
            return height
        }

        func clickToolbar(_ slot: ToolbarSlot) throws {
            try clickToolbar(id: slot.key)
        }

        func clickToolbar(id: String) throws {
            canvas.display()
            let rect = try XCTUnwrap(canvas.toolbarItemRect(id: id), "Missing toolbar button \(id)")
            try click(at: NSPoint(x: rect.midX, y: rect.midY))
        }

        func click(at point: NSPoint, count: Int = 1) throws {
            let down = try mouseEvent(.leftMouseDown, at: point, count: count)
            let hitPoint = canvas.superview?.convert(down.locationInWindow, from: nil) ?? down.locationInWindow
            let hit = try XCTUnwrap(canvas.hitTest(hitPoint) as? OverlayCanvasView, "Click at \(point) should reach the canvas")
            let up = try mouseEvent(.leftMouseUp, at: point, count: count)
            if session.isPinAnnotation {
                window.sendEvent(down)
                window.sendEvent(up)
            } else {
                // The fullscreen nonactivating panel can drop a synthetic first click in XCTest.
                hit.mouseDown(with: down)
                hit.mouseUp(with: up)
            }
        }

        func hover(at point: NSPoint) throws {
            canvas.mouseMoved(with: try mouseEvent(.mouseMoved, at: point))
        }

        func drag(from start: NSPoint, to end: NSPoint) throws {
            canvas.mouseDown(with: try mouseEvent(.leftMouseDown, at: start))
            canvas.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: end))
            canvas.mouseUp(with: try mouseEvent(.leftMouseUp, at: end))
        }

        func pressKey(_ keyCode: Int, characters: String) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: UInt16(keyCode)
            ))
            window.sendEvent(event)
        }

        func preview(in rect: NSRect? = nil) throws -> CGImage {
            let captureRect = rect ?? selection
            let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: captureRect))
            canvas.cacheDisplay(in: captureRect, to: bitmap)
            return try XCTUnwrap(bitmap.cgImage)
        }

        func textRows(in image: CGImage) throws -> [CGRect] {
            let pixels = try XCTUnwrap(PixelBufferRGBA(cgImage: image))
            var rows: [CGRect] = []
            var line = CGRect.null
            for y in 0..<pixels.height {
                var row = CGRect.null
                for x in 0..<pixels.width {
                    let color = pixels.pixel(x: x, y: y)
                    if Int(color.r) - max(Int(color.g), Int(color.b)) > 65 {
                        row = row.union(CGRect(x: x, y: y, width: 1, height: 1))
                    }
                }
                if row.isNull, !line.isNull {
                    rows.append(line)
                    line = .null
                }
                line = line.union(row)
            }
            if !line.isNull { rows.append(line) }
            return rows
        }

        private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, count: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: canvas.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: count, pressure: 1
            ))
        }
    }
}
