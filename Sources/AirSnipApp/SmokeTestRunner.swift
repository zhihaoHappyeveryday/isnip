import AppKit
import Carbon
import CoreGraphics
import CoreImage
import ImageIO
import SwiftUI
import Translation
import AirSnipCore

public enum SmokeTestRunner {
    private static var isRunningUnderRosetta: Bool {
        var ret: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &ret, &size, nil, 0) == 0 {
            return ret == 1
        }
        return false
    }
    @MainActor
    public static func runTranslationChecks() -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard #available(macOS 15.0, *) else {
            print("[translation] SKIP: 系统翻译需要 macOS 15+")
            return true
        }
        let clipboardCount = NSPasteboard.general.changeCount
        let previousWindows = Set(app.windows.map(\.windowNumber))
        let manager = OCRBubbleManager()
        defer { manager.dismiss() }
        var config = AirSnipConfig()
        config.translation.targetLanguage = "en"
        manager.presentSelectedText("Hello world", anchorScreenPoint: nil, config: config)
        let deadline = Date().addingTimeInterval(20)
        while manager.isTranslating && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard manager.translatedText == "Hello world", !manager.isTranslating,
              NSPasteboard.general.changeCount == clipboardCount else {
            fputs("FAIL: Same-language translation or clipboard preservation failed\n", stderr)
            return false
        }
        guard let panel = app.windows.first(where: { !previousWindows.contains($0.windowNumber) }),
              panel.frame.height < 420,
              !(panel.firstResponder is NSTextView) else {
            fputs("FAIL: Short selection should open compactly without focusing the source editor\n", stderr)
            return false
        }
        for screen in [
            NSRect(x: 0, y: 0, width: 1440, height: 900),
            NSRect(x: -1920, y: 180, width: 1920, height: 1080),
            NSRect(x: 1440, y: -900, width: 1280, height: 800),
        ] {
            for anchor in [
                NSPoint(x: screen.minX, y: screen.minY),
                NSPoint(x: screen.maxX, y: screen.maxY),
                NSPoint(x: screen.midX, y: screen.midY),
            ] {
                let frame = OCRBubbleManager.panelFrame(size: NSSize(width: 440, height: 560), near: anchor, visibleFrame: screen)
                guard screen.insetBy(dx: 12, dy: 12).contains(frame), !frame.contains(anchor) else {
                    fputs("FAIL: Translation panel obscures anchor or escapes visible screen\n", stderr)
                    return false
                }
            }
        }
        panel.setContentSize(NSSize(width: 400, height: 350))
        let resizedFrame = panel.frame
        manager.text = "A new selection"
        guard manager.translatedText.isEmpty, manager.translationRequest == nil else {
            fputs("FAIL: Editing source text retained a stale translation\n", stderr)
            return false
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        guard let translateKey = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ), panel.performKeyEquivalent(with: translateKey), manager.translationRequest != nil else {
            fputs("FAIL: Command-Return did not request translation\n", stderr)
            return false
        }
        let previousRequestID = manager.translationRequest?.id
        manager.translationTargetLanguage = "zh-Hans"
        guard let newRequestID = manager.translationRequest?.id, newRequestID != previousRequestID,
              panel.frame == resizedFrame else {
            fputs("FAIL: Retranslating must replace the request and preserve the resized window\n", stderr)
            return false
        }
        panel.cancelOperation(nil)
        guard manager.translationRequest == nil, !manager.isTranslating else {
            fputs("FAIL: Dismissing the panel retained an active translation\n", stderr)
            return false
        }
        print("[translation] PASS: 紧凑窗口、焦点、屏幕边界、重译保留尺寸、⌘Enter、原文编辑、目标切换、Esc 关闭和剪贴板保护")

        let fixture = NSImage(size: NSSize(width: 640, height: 140), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            ("Hello world" as NSString).draw(at: NSPoint(x: 24, y: 50), withAttributes: [
                .font: NSFont.systemFont(ofSize: 36),
                .foregroundColor: NSColor.black,
            ])
            return true
        }
        guard let image = fixture.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        config.ocr.language = "en-US"
        manager.recognizeAndPresent(rawSelectionImage: image, anchorScreenPoint: nil, config: config, translateOnCompletion: true)
        let ocrDeadline = Date().addingTimeInterval(30)
        while (manager.isRecognizing || manager.isTranslating) && Date() < ocrDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard !manager.isRecognizing, !manager.isTranslating,
              manager.errorMessage == nil, manager.translationError == nil,
              manager.text.contains("Hello world"),
              manager.translatedText == manager.text.trimmingCharacters(in: .whitespacesAndNewlines),
              NSPasteboard.general.changeCount == clipboardCount else {
            fputs("FAIL: OCR translation: recognizing=\(manager.isRecognizing), translating=\(manager.isTranslating), text=\(manager.text.debugDescription), result=\(manager.translatedText.debugDescription), error=\(manager.errorMessage ?? manager.translationError ?? "none")\n", stderr)
            return false
        }
        print("[translation] PASS: 截图 OCR 后自动进入翻译流程（同语言）")
        manager.dismiss()

        var languageStatus: LanguageAvailability.Status?
        let availabilityTask = Task { @MainActor in
            languageStatus = await LanguageAvailability().status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "zh-Hans"))
        }
        let languageDeadline = Date().addingTimeInterval(15)
        while languageStatus == nil && Date() < languageDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        availabilityTask.cancel()
        guard let languageStatus else {
            fputs("FAIL: Language availability check timed out\n", stderr)
            return false
        }
        // ponytail: 自检仅使用已安装语言包，下载由用户首次翻译时通过系统弹窗确认。
        if languageStatus == .installed {
            config.translation.targetLanguage = "zh-Hans"
            manager.presentSelectedText("Hello world", anchorScreenPoint: nil, config: config)
            // 极短原文可能触发系统语言选择弹窗；无人值守自检明确指定英语。
            manager.translationSourceLanguage = "en"
            let translationDeadline = Date().addingTimeInterval(30)
            while manager.isTranslating && Date() < translationDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            guard !manager.isTranslating, manager.translationError == nil,
                  !manager.translatedText.isEmpty, manager.translatedText != manager.text else {
                fputs("FAIL: Apple Translation: \(manager.translationError ?? "no result")\n", stderr)
                return false
            }
            print("[translation] PASS: 系统英译中：\(manager.translatedText)")
        } else {
            config.translation.targetLanguage = "en"
            manager.presentSelectedText("Hello world", anchorScreenPoint: nil, config: config)
            let sameLanguageDeadline = Date().addingTimeInterval(10)
            while manager.isTranslating && Date() < sameLanguageDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            print("[translation] SKIP: 英译中语言包未安装，首次翻译需按系统提示下载")
        }
        if let preview = ProcessInfo.processInfo.environment["ISNIP_TRANSLATION_PREVIEW_PNG"] {
            guard let view = panel.contentView else { return false }
            func capture(_ name: String, size: NSSize, appearance: NSAppearance.Name) -> Bool {
                panel.appearance = NSAppearance(named: appearance)
                panel.setContentSize(size)
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                view.layoutSubtreeIfNeeded()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
                view.cacheDisplay(in: view.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { return false }
                let url = URL(fileURLWithPath: preview).deletingPathExtension()
                do { try png.write(to: URL(fileURLWithPath: url.path + name + ".png")) }
                catch { fputs("FAIL: Translation preview: \(error)\n", stderr); return false }
                return true
            }
            guard capture("", size: NSSize(width: 440, height: 370), appearance: .aqua),
                  capture("-compact-dark", size: NSSize(width: 400, height: 350), appearance: .darkAqua) else { return false }
            config.translation.targetLanguage = "en"
            let longText = Array(repeating: "Select text in any supported app, then press Option-D to translate it. You can edit the source and press Command-Return to translate again.", count: 12).joined(separator: "\n\n")
            manager.presentSelectedText(longText, anchorScreenPoint: nil, config: config)
            let longDeadline = Date().addingTimeInterval(10)
            while manager.isTranslating && Date() < longDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            guard manager.translatedText == longText,
                  capture("-long", size: NSSize(width: 440, height: 560), appearance: .aqua),
                  capture("-long-compact-dark", size: NSSize(width: 400, height: 350), appearance: .darkAqua) else { return false }
            manager.text = "Edited source text. Press Command-Return to update the translation."
            guard capture("-edited", size: NSSize(width: 440, height: 370), appearance: .aqua) else { return false }
            manager.text = ""
            guard capture("-empty", size: NSSize(width: 400, height: 350), appearance: .darkAqua) else { return false }
            manager.recognizeAndPresent(rawSelectionImage: image, anchorScreenPoint: nil, config: config, translateOnCompletion: true)
            let previewDeadline = Date().addingTimeInterval(30)
            while (manager.isRecognizing || manager.isTranslating) && Date() < previewDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            guard capture("-ocr", size: NSSize(width: 440, height: 420), appearance: .aqua) else { return false }
            // 固定的识别等待状态仅用于检查布局，不伪造翻译输出。
            manager.text = ""
            manager.isRecognizing = true
            guard capture("-recognizing", size: NSSize(width: 400, height: 350), appearance: .darkAqua) else { return false }
            manager.isRecognizing = false
            manager.errorMessage = "未识别到文字"
            guard capture("-ocr-error", size: NSSize(width: 440, height: 420), appearance: .aqua) else { return false }
        }
        print("[translation] PASS")
        return true
    }

    @MainActor
    private static func runCroppedPinStorageCheck(on screen: NSScreen) -> Bool {
        let config = AirSnipConfig()
        let pins = PinManager()
        defer { pins.closeAll() }
        weak var screenshot: CGImage?
        var expectedPixels: PixelBufferRGBA?

        let didCapture = autoreleasepool {
            let frame = CGRect(origin: screen.frame.origin, size: CGSize(width: 160, height: 128))
            guard let p3 = CGColorSpace(name: CGColorSpace.displayP3),
                  let context = CGContext(
                      data: nil, width: 320, height: 256, bitsPerComponent: 8, bytesPerRow: 320 * 4,
                      space: p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.setFillColor(NSColor(displayP3Red: 1, green: 0.3, blue: 0, alpha: 0.5).cgColor)
            context.fill(CGRect(x: 42, y: 172, width: 46, height: 26))
            context.setFillColor(NSColor(displayP3Red: 0, green: 0.8, blue: 1, alpha: 1).cgColor)
            context.fill(CGRect(x: 100, y: 155, width: 20, height: 24))
            guard let source = context.makeImage(),
                  let rawBuffer = PixelBufferRGBA(cgImage: source) else { return false }
            screenshot = source
            expectedPixels = rawBuffer.cropped(to: PixelRect(x: 32, y: 40, width: 96, height: 64))
            let snapshot = CapturedScreenSnapshot(
                screen: screen, frameInGlobalAppKit: frame,
                frameTopDown: ASRect(x: 0, y: 0, width: 160, height: 128),
                cgImage: source, rawBuffer: rawBuffer, backingScale: 2, windowsLocalTopDown: []
            )

            let session = CaptureSessionCoordinator(config: config)
            session.onCompletePin = { image, scale, origin in
                pins.createPin(cgImage: image, backingScale: scale, preferredScreenOriginAppKit: origin, config: config)
            }
            let overlay = OverlayScreenController(
                snapshot: snapshot, coordinator: session, lockedInitialSelection: ASRect(x: 16, y: 20, width: 48, height: 32)
            )
            defer { overlay.panel.contentView = nil }
            guard let pinKey = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: overlay.panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: UInt16(kVK_F3)
            ) else { return false }
            overlay.canvasView.keyDown(with: pinKey)
            return true
        }

        guard didCapture, let pin = pins.windows.last, let expectedPixels,
              pin.backingScale == 2, pin.cgImage.colorSpace?.name == CGColorSpace.displayP3,
              PixelBufferRGBA(cgImage: pin.cgImage) == expectedPixels else {
            fputs("FAIL: A pinned crop should keep the selection's pixels, color space and scale\n", stderr)
            return false
        }
        guard screenshot == nil else {
            fputs("FAIL: A pinned crop should release the source screenshot\n", stderr)
            return false
        }
        print("[pins] PASS: 裁剪贴图保留选区像素与色彩空间，释放整屏原图")
        return true
    }

    @MainActor
    private static func withPinRestoreFixture(
        image: CGImage,
        configURL: URL,
        _ check: @MainActor (CGImage, AirSnipAppController, NSPasteboard) -> Bool
    ) -> Bool {
        let pasteboard = NSPasteboard.withUniqueName()
        let app = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard)
        app.updateConfig { $0.lastSaveDirectory = configURL.deletingLastPathComponent().path }
        defer {
            app.updateConfig { $0.pinHistoryLimit = 0 }
            app.pinManager.closeAll()
            app.pinManager.finishHistorySession()
            pasteboard.releaseGlobally()
        }
        return check(image, app, pasteboard)
    }

    @MainActor
    private static func runPinRestoreChecks(image: CGImage, app: AirSnipAppController, pasteboard: NSPasteboard) -> Bool {
        let pins = app.pinManager
        pins.createPin(cgImage: image, backingScale: 2, preferredScreenOriginAppKit: nil, config: app.config)
        guard let pin = pins.windows.last else {
            fputs("FAIL: Pin restore fixture could not open a pin\n", stderr)
            return false
        }
        pin.adjustZoom(delta: 1, anchorInWindow: NSPoint(x: 30, y: 40))
        pin.adjustOpacity(delta: -1)
        pin.window.setFrameOrigin(NSPoint(x: pin.window.frame.minX + 20, y: pin.window.frame.minY + 30))
        let frame = pin.window.frame
        let opacity = pin.window.alphaValue

        pin.closeSelf()
        guard pins.count == 0, !pin.window.isVisible else {
            fputs("FAIL: Closing a pin should remove it from the screen\n", stderr)
            return false
        }
        app.triggerPinOrRestore(from: pasteboard)
        guard let restored = pins.windows.last, restored.window.isVisible,
              restored.window.frame == frame, restored.window.alphaValue == opacity,
              PixelBufferRGBA(cgImage: restored.cgImage) == PixelBufferRGBA(cgImage: image) else {
            fputs("FAIL: Restoring a closed pin should preserve its image, frame and opacity\n", stderr)
            return false
        }
        print("[pins] PASS: 恢复贴图保留图像、位置、大小和透明度")

        guard let second = image.cropping(to: CGRect(x: 0, y: 0, width: 96, height: 64)),
              let copied = image.cropping(to: CGRect(x: 0, y: 0, width: 64, height: 48)),
              let png = try? ImageEncoder.encode(copied, format: .png, scale: 1) else { return false }
        restored.closeSelf()
        pins.createPin(cgImage: second, backingScale: 1, preferredScreenOriginAppKit: nil, config: app.config)
        pins.windows.last?.closeSelf()
        pasteboard.clearContents()
        let imageWithText = NSPasteboardItem()
        guard imageWithText.setData(png, forType: .png),
              imageWithText.setString("Image caption", forType: .string),
              pasteboard.writeObjects([imageWithText]) else { return false }

        for (index, width) in [copied.width, second.width, image.width].enumerated() {
            app.triggerPinOrRestore(from: pasteboard)
            guard pins.count == index + 1, pins.windows.last?.cgImage.width == width else {
                fputs("FAIL: Pin or restore should open the newly copied image followed by the most recently closed pins (press \(index + 1))\n", stderr)
                return false
            }
        }
        app.triggerPinOrRestore(from: pasteboard)
        guard pins.count == 3 else {
            fputs("FAIL: Pin or restore should leave the windows alone when history is exhausted\n", stderr)
            return false
        }

        pasteboard.clearContents()
        guard pasteboard.setData(png, forType: .png) else { return false }
        app.triggerPinOrRestore(from: pasteboard)
        guard let recopied = pins.windows.last, pins.count == 4, recopied.cgImage.width == copied.width else {
            fputs("FAIL: Copying the same image again should let it be pinned again\n", stderr)
            return false
        }
        recopied.closeSelf()
        pasteboard.clearContents()
        app.triggerPinOrRestore(from: pasteboard)
        guard pins.count == 4, pins.windows.last?.cgImage.width == copied.width else {
            fputs("FAIL: An empty clipboard should still allow a pin to be restored\n", stderr)
            return false
        }
        print("[pins] PASS: 新图优先（含图文共存）、最近关闭优先、主动再次复制与空剪贴板")

        app.updateConfig { $0.pinMaxCount = 4 }
        pasteboard.clearContents()
        guard pasteboard.setData(png, forType: .png) else { return false }
        app.triggerPinOrRestore(from: pasteboard)
        guard pins.count == 4 else {
            fputs("FAIL: A new clipboard image should respect the visible pin limit\n", stderr)
            return false
        }
        app.updateConfig { $0.pinMaxCount = 5 }
        app.triggerPinOrRestore(from: pasteboard)
        guard let retried = pins.windows.last, pins.count == 5, retried.cgImage.width == copied.width else {
            fputs("FAIL: A clipboard image blocked by the visible pin limit should remain available\n", stderr)
            return false
        }
        retried.closeSelf()
        app.updateConfig { $0.pinMaxCount = 4 }
        app.triggerPinOrRestore(from: pasteboard)
        guard pins.count == 4 else {
            fputs("FAIL: Restoring a pin should respect the visible pin limit\n", stderr)
            return false
        }
        app.updateConfig { $0.pinMaxCount = 5 }
        app.triggerPinOrRestore(from: pasteboard)
        guard pins.count == 5, pins.windows.last?.cgImage.width == copied.width else {
            fputs("FAIL: A closed pin blocked by the visible pin limit should remain available\n", stderr)
            return false
        }
        print("[pins] PASS: 达到同屏上限后仍可重试贴出新图和恢复贴图")
        return true
    }

    @MainActor
    private static func runClipboardTextPinCheck(image: CGImage, app: AirSnipAppController, pasteboard: NSPasteboard) -> Bool {
        let pins = app.pinManager
        pins.createPin(cgImage: image, backingScale: 1, preferredScreenOriginAppKit: nil, config: app.config)
        pins.createPin(cgImage: image, backingScale: 1, preferredScreenOriginAppKit: nil, config: app.config)
        guard pins.count == 2 else { return false }
        let older = pins.windows[0]
        let newer = pins.windows[1]
        older.closeSelf()
        newer.closeSelf()

        let text = "  iSnip\n\t第二行  "
        let statusMenu = NSMenu()
        app.menuNeedsUpdate(statusMenu)
        guard pasteboard.setString(text, forType: .string),
              OutputService.readImageFromClipboard(from: pasteboard) == nil,
              let pinItem = statusMenu.item(withTitle: L10n.tr("贴图或恢复", "Pin or Restore")),
              let pinAction = pinItem.action,
              NSApp.sendAction(pinAction, to: pinItem.target, from: pinItem) else {
            fputs("FAIL: Pin or Restore should handle plain text through the status menu\n", stderr)
            return false
        }
        guard let textPin = pins.windows.last, pins.count == 1, textPin !== older, textPin !== newer,
              textPin.window.isVisible, pasteboard.string(forType: .string) == text else {
            fputs("FAIL: New clipboard text should be pinned before restoring closed images\n", stderr)
            return false
        }

        for (index, frame) in [newer.window.frame, older.window.frame].enumerated() {
            app.triggerPinOrRestore(from: pasteboard)
            guard pins.count == index + 2, let restored = pins.windows.last,
                  restored.window.frame == frame, restored.window.isVisible else {
                fputs("FAIL: Repeated presses after pinning text should restore the latest closed pin\n", stderr)
                return false
            }
        }
        guard let textImage = PixelBufferRGBA(cgImage: textPin.cgImage) else { return false }
        let middleRow = textImage.width * (textImage.height / 2) * 4
        guard stride(from: 0, to: middleRow, by: 4).contains(where: { textImage.rgba[$0] < 128 }),
              stride(from: middleRow, to: textImage.rgba.count, by: 4).contains(where: { textImage.rgba[$0] < 128 }) else {
            fputs("FAIL: Both lines of the clipboard text should render visible glyphs\n", stderr)
            return false
        }
        textPin.adjustZoom(delta: 1, anchorInWindow: NSPoint(x: 30, y: 30))
        textPin.adjustOpacity(delta: -1)
        let textFrame = textPin.window.frame
        let textOpacity = textPin.window.alphaValue
        textPin.closeSelf()
        app.triggerPinOrRestore(from: pasteboard)
        guard pins.count == 3, let restored = pins.windows.last, restored.window.isVisible,
              restored.window.frame == textFrame, restored.window.alphaValue == textOpacity,
              PixelBufferRGBA(cgImage: restored.cgImage) == textImage else {
            fputs("FAIL: A restored text pin should keep its image, frame and opacity\n", stderr)
            return false
        }

        app.updateConfig { $0.pinMaxCount = 3 }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        app.triggerPinOrRestore(from: pasteboard)
        guard pins.count == 3 else { return false }
        restored.closeSelf()
        app.triggerPinOrRestore(from: pasteboard)
        guard pins.count == 3, let recopied = pins.windows.last,
              recopied.window.alphaValue == 1, PixelBufferRGBA(cgImage: recopied.cgImage) == textImage else {
            fputs("FAIL: Recopied text should still make a new pin after reaching the visible pin limit\n", stderr)
            return false
        }

        let frames = pins.windows.reversed().map { $0.window.frame }
        pins.closeAll()
        for (index, frame) in frames.enumerated() {
            app.triggerPinOrRestore(from: pasteboard)
            guard pins.count == index + 1, pins.windows.last?.window.frame == frame else {
                fputs("FAIL: Close All should restore image and text pins in reverse insertion order\n", stderr)
                return false
            }
        }
        print("[pins] PASS: 新文字优先、屏幕上限重试、文字和图片共享单张与批量恢复")
        return true
    }

    @MainActor
    private static func runTextPinLayoutCheck(image _: CGImage, app: AirSnipAppController, pasteboard: NSPasteboard) -> Bool {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return false }
        let pins = app.pinManager

        func pinSize(for text: String) -> NSSize? {
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else { return nil }
            let count = pins.count
            app.triggerPinOrRestore(from: pasteboard)
            guard pins.count == count + 1 else { return nil }
            return pins.windows.last?.window.frame.size
        }

        let longLine = String(repeating: "M", count: Int(screen.visibleFrame.width / 6) + 32)
        guard let plain = pinSize(for: "iSnip"), let spaced = pinSize(for: "\t iSnip  \n"),
              spaced.width > plain.width, spaced.height > plain.height,
              let long = pinSize(for: longLine), long.height == plain.height, long.width > screen.visibleFrame.width else {
            fputs("FAIL: Text pins should preserve spacing and source lines at their natural size\n", stderr)
            return false
        }
        print("[pins] PASS: 文字贴图保留留白和原行，长行按自然宽度超出屏幕")
        return true
    }

    @MainActor
    private static func runOversizedTextPinCheck(image _: CGImage, app: AirSnipAppController, pasteboard: NSPasteboard) -> Bool {
        let text = String(repeating: "W", count: 360) + String(repeating: "\nx", count: 234) + "\n\t 原文结尾  "
        guard pasteboard.setString(text, forType: .string) else { return false }

        let pins = app.pinManager
        app.triggerPinOrRestore()
        guard let pin = pins.windows.last, pin.window.isVisible else {
            fputs("FAIL: Oversized clipboard text should still open as a pin\n", stderr)
            return false
        }
        let bitmapBytes = pin.cgImage.bytesPerRow * pin.cgImage.height
        guard bitmapBytes <= 32 * 1024 * 1024 else {
            fputs("FAIL: Oversized text pin exceeded the 32 MiB bitmap limit (\(bitmapBytes) bytes)\n", stderr)
            return false
        }

        pin.closeSelf()
        app.triggerPinOrRestore()
        guard let restored = pins.windows.last, restored.window.isVisible,
              restored.cgImage.width == pin.cgImage.width, restored.cgImage.height == pin.cgImage.height else {
            fputs("FAIL: A clipped text pin should still restore from history\n", stderr)
            return false
        }
        restored.copyOriginalText()
        guard pasteboard.string(forType: .string) == text else {
            fputs("FAIL: A restored clipped text pin should copy the complete original text\n", stderr)
            return false
        }
        print("[pins] PASS: 超大文字贴图预览限制在 32 MiB，关闭恢复后仍可复制完整原文")
        return true
    }

    @MainActor
    private static func runTextPinOriginalCopyCheck(image: CGImage, app: AirSnipAppController, pasteboard: NSPasteboard) -> Bool {
        app.updateConfig { $0.smartPngCompression = false }
        let pins = app.pinManager
        let text = "  iSnip\n\t原文  "

        func menu(for pin: PinWindowController) -> NSMenu? {
            guard let event = NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: 24, y: 24),
                modifierFlags: [], timestamp: 0, windowNumber: pin.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { return nil }
            return pin.window.contentView?.menu(for: event)
        }

        func pressCopy(on pin: PinWindowController, modifiers: NSEvent.ModifierFlags) -> Bool {
            guard let view = pin.window.contentView, let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: pin.window.windowNumber, context: nil,
                characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: UInt16(kVK_ANSI_C)
            ) else { return false }
            view.keyDown(with: event)
            return true
        }

        func verifyCopies(of pin: PinWindowController, image: CGImage) -> Bool {
            guard pressCopy(on: pin, modifiers: .command),
                  let clip = OutputService.readImageFromClipboard(from: pasteboard),
                  PixelBufferRGBA(cgImage: clip.cgImage) == PixelBufferRGBA(cgImage: image) else {
                fputs("FAIL: Command-C should copy the current pin image\n", stderr)
                return false
            }
            guard pressCopy(on: pin, modifiers: [.command, .shift]),
                  pasteboard.string(forType: .string) == text else {
                fputs("FAIL: Command-Shift-C should copy the original text including whitespace\n", stderr)
                return false
            }
            return true
        }

        guard pasteboard.setString(text, forType: .string) else { return false }
        app.triggerPinOrRestore()
        let originalTextTitle = L10n.tr("复制原文", "Copy Original Text")
        guard let pin = pins.windows.last,
              let copyOriginal = menu(for: pin)?.item(withTitle: originalTextTitle),
              let action = copyOriginal.action, copyOriginal.keyEquivalentModifierMask == [.command, .shift] else {
            fputs("FAIL: A text pin should offer Copy Original Text in its menu\n", stderr)
            return false
        }
        pasteboard.clearContents()
        guard NSApp.sendAction(action, to: copyOriginal.target, from: copyOriginal),
              pasteboard.string(forType: .string) == text else {
            fputs("FAIL: Copy Original Text should write the pin's original text to the clipboard\n", stderr)
            return false
        }
        app.triggerPinOrRestore()
        guard pins.count == 2 else {
            fputs("FAIL: Copying original text should allow it to be pinned as a new copy\n", stderr)
            return false
        }

        guard let edited = image.cropping(to: CGRect(x: 0, y: 0, width: 96, height: 64)) else { return false }
        let editor = CaptureSessionCoordinator(config: app.config, mode: .inlinePinEdit(pin))
        editor.startPinInlineEdit(pin: pin)
        guard editor.hasVisibleWindows else { return false }
        editor.finishWithCopy(image: edited, scale: pin.backingScale)
        guard verifyCopies(of: pin, image: edited) else { return false }

        pin.closeSelf()
        pasteboard.clearContents()
        app.triggerPinOrRestore()
        guard pins.count == 2, let restored = pins.windows.last, verifyCopies(of: restored, image: edited) else {
            fputs("FAIL: Restoring a text pin should keep both its edited image and original text\n", stderr)
            return false
        }

        pins.createPin(cgImage: image, backingScale: 1, preferredScreenOriginAppKit: nil, config: app.config)
        guard let imagePin = pins.windows.last, let imageMenu = menu(for: imagePin),
              imageMenu.item(withTitle: originalTextTitle) == nil,
              let copyImage = imageMenu.item(withTitle: L10n.tr("复制", "Copy")), let copyAction = copyImage.action,
              NSApp.sendAction(copyAction, to: copyImage.target, from: copyImage),
              let clip = OutputService.readImageFromClipboard(from: pasteboard),
              PixelBufferRGBA(cgImage: clip.cgImage) == PixelBufferRGBA(cgImage: image) else {
            fputs("FAIL: An ordinary image pin should still copy its image and omit Copy Original Text\n", stderr)
            return false
        }
        print("[pins] PASS: 右键和快捷键可复制原文，标注与恢复后也能分别复制当前图像和原文")
        return true
    }

    @MainActor
    private static func runBatchPinRestoreCheck(image: CGImage, app: AirSnipAppController, pasteboard: NSPasteboard) -> Bool {
        let pins = app.pinManager

        for width in [64, 80, 96] {
            guard let sample = image.cropping(to: CGRect(x: 0, y: 0, width: width, height: 48)),
                  pins.createPin(cgImage: sample, backingScale: 1, preferredScreenOriginAppKit: nil, config: app.config),
                  let pin = pins.windows.last else { return false }
            pin.adjustZoom(delta: 1, anchorInWindow: NSPoint(x: 24, y: 24))
            pin.adjustOpacity(delta: -1)
        }
        let opened = pins.windows
        let states = opened.map { (image: $0.cgImage, frame: $0.window.frame, opacity: $0.window.alphaValue) }

        func checkRestoration(indices: [Int]) -> Bool {
            guard pins.count == 0, opened.allSatisfy({ !$0.window.isVisible }) else {
                fputs("FAIL: Close All should hide every pin\n", stderr)
                return false
            }
            for (press, index) in indices.enumerated() {
                app.triggerPinOrRestore(from: pasteboard)
                let state = states[index]
                guard let restored = pins.windows.last, pins.count == press + 1, restored.window.isVisible,
                      PixelBufferRGBA(cgImage: restored.cgImage) == PixelBufferRGBA(cgImage: state.image),
                      restored.window.frame == state.frame, restored.window.alphaValue == state.opacity else {
                    fputs("FAIL: Pin or restore should restore one pin in reverse insertion order with its original display state (press \(press + 1))\n", stderr)
                    return false
                }
            }
            app.triggerPinOrRestore(from: pasteboard)
            guard pins.count == indices.count else {
                fputs("FAIL: Close All should leave one history entry per pin\n", stderr)
                return false
            }
            return true
        }

        let first = opened[0]
        first.show()
        let statusMenu = NSMenu()
        app.menuNeedsUpdate(statusMenu)
        guard let statusClose = statusMenu.item(withTitle: L10n.tr("关闭全部贴图", "Close All Pins")),
              let statusAction = statusClose.action,
              NSApp.sendAction(statusAction, to: statusClose.target, from: statusClose),
              checkRestoration(indices: [2, 1, 0]) else { return false }

        guard let restoredFirst = pins.windows.last,
              let event = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 24, y: 24),
                                             modifierFlags: [], timestamp: 0, windowNumber: restoredFirst.window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let pinMenu = restoredFirst.window.contentView?.menu(for: event),
              let pinClose = pinMenu.item(withTitle: L10n.tr("关闭全部", "Close All")),
              let pinAction = pinClose.action,
              NSApp.sendAction(pinAction, to: pinClose.target, from: pinClose),
              checkRestoration(indices: [0, 1, 2]) else { return false }
        print("[pins] PASS: 两个关闭全部菜单都按最近贴出或恢复的顺序逐张恢复")
        return true
    }

    @MainActor
    private static func runBatchCloseDuringInlineEditCheck(image: CGImage) -> Bool {
        let config = AirSnipConfig()
        let pins = PinManager()
        defer { pins.closeAll() }
        guard let edited = image.cropping(to: CGRect(x: 0, y: 0, width: 96, height: 64)),
              pins.createPin(cgImage: image, backingScale: 1, preferredScreenOriginAppKit: nil, config: config),
              let pin = pins.windows.last else { return false }

        let editor = CaptureSessionCoordinator(config: config, mode: .inlinePinEdit(pin))
        editor.startPinInlineEdit(pin: pin)
        pins.restoreLastClosedPin(config: config)
        guard editor.hasVisibleWindows, pins.count == 1, !pin.window.isVisible else {
            fputs("FAIL: A pin hidden for inline editing should still count as open\n", stderr)
            return false
        }

        pins.closeAll()
        editor.finishWithCopy(image: edited, scale: 1)
        guard pins.count == 0, !pin.window.isVisible, !editor.hasVisibleWindows else {
            fputs("FAIL: Finishing an inline edit should leave a pin closed by Close All hidden\n", stderr)
            return false
        }

        pins.restoreLastClosedPin(config: config)
        guard let restored = pins.windows.last, pins.count == 1, restored.window.isVisible,
              PixelBufferRGBA(cgImage: restored.cgImage) == PixelBufferRGBA(cgImage: image) else {
            fputs("FAIL: Restoring a pin closed during an inline edit should show the image as it was at close time\n", stderr)
            return false
        }
        print("[pins] PASS: 关闭全部后结束标注，贴图保持关闭并可按关闭时的图像恢复")
        return true
    }

    @MainActor
    private static func runClosedPinHistoryLimitCheck(image: CGImage) -> Bool {
        var config = AirSnipConfig()
        config.pinMaxCount = 25
        let pins = PinManager()
        defer { pins.closeAll() }

        for width in 32...54 {
            guard let sample = image.cropping(to: CGRect(x: 0, y: 0, width: width, height: 32)),
                  pins.createPin(cgImage: sample, backingScale: 1, preferredScreenOriginAppKit: nil, config: config) else { return false }
            if width < 36 {
                pins.windows.last?.closeSelf()
            }
        }
        pins.closeAll()
        for width in (35...54).reversed() {
            pins.restoreLastClosedPin(config: config)
            guard pins.windows.last?.cgImage.width == width else {
                fputs("FAIL: Single and batch closes should share the most recent 20 history entries in order\n", stderr)
                return false
            }
        }
        pins.restoreLastClosedPin(config: config)
        guard pins.count == 20 else {
            fputs("FAIL: Pin history should discard the oldest pin after 20 closes\n", stderr)
            return false
        }
        print("[pins] PASS: 单张关闭和关闭全部共用最近 20 张的历史")
        return true
    }

    private static func pinHistoryPNGCount(at directory: URL) -> Int {
        let items = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        return items?.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "png" }.count ?? 0
    }

    @MainActor
    private static func waitForPinHistoryWork(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            autoreleasepool { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }
        return condition()
    }

    @MainActor
    private static func runDiskPinHistoryCheck(image: CGImage, app: AirSnipAppController, pasteboard: NSPasteboard) -> Bool {
        let files = FileManager.default
        let pins = app.pinManager
        let base = app.configURL.deletingLastPathComponent()
        let defaultDirectory = base.appendingPathComponent("iSnip Pin History", isDirectory: true)
        let customParent = base.appendingPathComponent("custom-history", isDirectory: true)
        let customDirectory = customParent.appendingPathComponent("iSnip Pin History", isDirectory: true)
        guard (try? files.createDirectory(at: customParent, withIntermediateDirectories: false)) != nil,
              (try? files.createDirectory(at: defaultDirectory, withIntermediateDirectories: true)) != nil else { return false }

        let text = "  原文 🚀\r\n\t第二行  "
        weak var firstImage: CGImage?
        weak var firstWindow: NSWindow?
        var expectedImage: PixelBufferRGBA?
        var expectedFrame = NSRect.zero
        var expectedZoom: CGFloat = 0
        var expectedOpacity: CGFloat = 0
        let closedFirst = autoreleasepool {
            guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
                  let context = CGContext(
                      data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 96 * 4,
                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.setFillColor(NSColor(displayP3Red: 1, green: 0.3, blue: 0, alpha: 0.5).cgColor)
            context.fill(CGRect(x: 4, y: 8, width: 56, height: 48))
            guard let sample = context.makeImage(),
                  let pixels = PixelBufferRGBA(cgImage: sample),
                  pins.createPin(cgImage: sample, backingScale: 2, preferredScreenOriginAppKit: nil, config: app.config,
                                 originalText: text),
                  let pin = pins.windows.last else { return false }
            pin.adjustZoom(delta: 1, anchorInWindow: .zero)
            pin.adjustOpacity(delta: -1)
            pin.setShowBorder(false)
            pin.setClickThrough(true)
            firstImage = sample
            firstWindow = pin.window
            expectedImage = pixels
            expectedFrame = pin.window.frame
            expectedZoom = pin.zoomScale
            expectedOpacity = pin.opacity
            pin.closeSelf()
            return pins.count == 0
        }
        guard closedFirst, waitForPinHistoryWork({
            firstImage == nil && firstWindow == nil && pinHistoryPNGCount(at: defaultDirectory) == 1
        }) else {
            fputs("FAIL: Closed pins should write under the screenshot save directory and release their windows and bitmaps\n", stderr)
            return false
        }

        app.updateConfig { $0.pinHistoryParentDirectory = customParent.path }
        weak var secondImage: CGImage?
        let closedSecond = autoreleasepool {
            guard let sample = image.cropping(to: CGRect(x: 0, y: 0, width: 64, height: 48)),
                  pins.createPin(cgImage: sample, backingScale: 1, preferredScreenOriginAppKit: nil, config: app.config),
                  let pin = pins.windows.last else { return false }
            secondImage = sample
            pin.closeSelf()
            return pins.count == 0
        }
        guard closedSecond, waitForPinHistoryWork({ secondImage == nil && pinHistoryPNGCount(at: customDirectory) == 1 }),
              pinHistoryPNGCount(at: defaultDirectory) == 1 else {
            fputs("FAIL: Changing the history directory should apply to the next close and retain existing history\n", stderr)
            return false
        }

        let invalidParent = base.appendingPathComponent("invalid-history-parent")
        guard (try? Data().write(to: invalidParent)) != nil else { return false }
        app.updateConfig { $0.pinHistoryParentDirectory = invalidParent.path }
        guard pins.createPin(cgImage: image, backingScale: 1, preferredScreenOriginAppKit: nil, config: app.config) else { return false }
        pins.windows.last?.closeSelf()
        guard pins.count == 0 else { return false }

        app.triggerPinOrRestore(from: pasteboard)
        guard pins.count == 1, pins.windows.last?.cgImage.width == 64, pinHistoryPNGCount(at: customDirectory) == 0 else {
            fputs("FAIL: A failed close should leave the next recoverable pin and its existing file available\n", stderr)
            return false
        }
        app.triggerPinOrRestore(from: pasteboard)
        guard pins.count == 2, let restored = pins.windows.last,
              restored.cgImage.colorSpace?.isWideGamutRGB == true, PixelBufferRGBA(cgImage: restored.cgImage) == expectedImage,
              restored.window.frame == expectedFrame, restored.backingScale == 2, restored.zoomScale == expectedZoom,
              restored.opacity == expectedOpacity, restored.window.alphaValue == 0.82,
              restored.window.ignoresMouseEvents, !restored.showBorder, pinHistoryPNGCount(at: defaultDirectory) == 0 else {
            fputs("FAIL: Disk restoration should preserve image color, alpha and display state and remove the consumed file\n", stderr)
            return false
        }
        restored.copyOriginalText()
        guard pasteboard.string(forType: .string) == text else {
            fputs("FAIL: Disk restoration should preserve the complete original text\n", stderr)
            return false
        }
        print("[pins] PASS: 已关闭贴图释放窗口和位图，换目录即时生效，磁盘恢复保留图像、状态和原文")
        return true
    }

    @MainActor
    private static func runFailedPinHistoryWriteCheck(image: CGImage, directory: URL) throws -> Bool {
        let files = FileManager.default
        let history = ClosedPinHistory(registryURL: nil)
        defer { history.finishSession() }
        let workingRoot = directory.appendingPathComponent("write-history", isDirectory: true)
        let failingRoot = directory.appendingPathComponent("unavailable-history", isDirectory: true)
        let displayState = PinDisplayState(
            frame: CGRect(x: 0, y: 0, width: 32, height: 32), baseSize: CGSize(width: 32, height: 32),
            backingScale: 1, zoomScale: 1, preferredOpacity: 1, effectiveWindowOpacity: 1,
            showBorder: true, isClickThrough: false
        )
        func snapshot(_ image: CGImage, text: String) -> PinSnapshot {
            PinSnapshot(image: image, originalText: text, displayState: displayState)
        }

        // Make a valid session directory first, then replace it with a file so the actual write fails.
        weak var seedImage: CGImage?
        let seeded = autoreleasepool {
            guard let sample = image.cropping(to: displayState.frame) else { return false }
            seedImage = sample
            history.remember([snapshot(sample, text: "seed")], limit: 2, historyRoot: failingRoot)
            return true
        }
        guard seeded, waitForPinHistoryWork({ seedImage == nil }),
              history.restoreLast().snapshot?.originalText == "seed",
              let sessionDirectory = try files.contentsOfDirectory(
                  at: failingRoot, includingPropertiesForKeys: nil
              ).first else {
            fputs("FAIL: Could not prepare a writable pin history session for the failure fixture\n", stderr)
            return false
        }
        try files.removeItem(at: sessionDirectory)
        try Data().write(to: URL(fileURLWithPath: sessionDirectory.path, isDirectory: false))

        var failures = 0
        history.onWriteFailure = { failures += 1 }
        history.remember(
            [snapshot(image, text: "oldest"), snapshot(image, text: "newest")], limit: 2, historyRoot: workingRoot
        )
        history.remember([snapshot(image, text: "failed")], limit: 2, historyRoot: failingRoot)
        guard waitForPinHistoryWork({ failures > 0 }), failures == 1,
              history.restoreLast().snapshot?.originalText == "newest", history.isEmpty,
              pinHistoryPNGCount(at: workingRoot) == 0 else {
            fputs("FAIL: A failed history write should drop its entry and clean up the earlier eviction\n", stderr)
            return false
        }
        print("[pins] PASS: 写盘失败移除失败项，保留其余历史并清理已淘汰的在途文件")
        return true
    }

    @MainActor
    private static func runConfiguredPinHistoryCheck(image: CGImage, app: AirSnipAppController, pasteboard: NSPasteboard) -> Bool {
        let pins = app.pinManager

        func openPins(widths: ClosedRange<Int>) -> Bool {
            for width in widths {
                guard let sample = image.cropping(to: CGRect(x: 0, y: 0, width: width, height: 32)),
                      pins.createPin(cgImage: sample, backingScale: 1, preferredScreenOriginAppKit: nil, config: app.config) else { return false }
            }
            return true
        }

        app.updateConfig { $0.pinHistoryLimit = 10 }
        guard openPins(widths: 32...41) else { return false }
        pins.closeAll()
        app.updateConfig { $0.pinHistoryLimit = 5 }
        app.updateConfig { $0.pinHistoryLimit = 10 }

        for width in [41, 40, 39, 38, 37] {
            app.triggerPinOrRestore(from: pasteboard)
            guard pins.windows.last?.cgImage.width == width else {
                fputs("FAIL: Reducing pin history should keep the most recently closed pins\n", stderr)
                return false
            }
        }
        app.triggerPinOrRestore(from: pasteboard)
        guard pins.count == 5 else {
            fputs("FAIL: Increasing the pin history limit should not bring back previously trimmed pins\n", stderr)
            return false
        }
        print("[pins] PASS: 调小可恢复贴图数后立即只保留最近关闭的贴图")

        pins.closeAll()
        app.updateConfig { $0.pinHistoryLimit = 0 }
        app.triggerPinOrRestore(from: pasteboard)
        guard pins.count == 0 else {
            fputs("FAIL: Disabling pin history should immediately clear it\n", stderr)
            return false
        }

        guard openPins(widths: 32...33) else { return false }
        pins.windows.last?.closeSelf()
        app.triggerPinOrRestore(from: pasteboard)
        guard pins.count == 1 else {
            fputs("FAIL: Closing a pin with history disabled should leave nothing to restore\n", stderr)
            return false
        }
        pins.closeAll()
        app.triggerPinOrRestore(from: pasteboard)
        guard pins.count == 0 else {
            fputs("FAIL: Close All should also honor disabled pin history\n", stderr)
            return false
        }

        app.updateConfig { $0.pinHistoryLimit = 10 }
        guard openPins(widths: 32...43) else { return false }
        pins.closeAll()
        for _ in 0..<11 { app.triggerPinOrRestore(from: pasteboard) }
        guard pins.count == 10, pins.windows.last?.cgImage.width == 34 else {
            fputs("FAIL: Re-enabling pin history should retain future closes up to the new limit\n", stderr)
            return false
        }

        pins.closeAll()
        pins.finishHistorySession()
        let restarted = AirSnipAppController(configURL: app.configURL)
        restarted.triggerPinOrRestore(from: pasteboard)
        guard restarted.config.pinHistoryLimit == 10, restarted.pinManager.count == 0 else {
            fputs("FAIL: A new controller should load the saved history limit and start with empty history\n", stderr)
            return false
        }
        print("[pins] PASS: 停用时清空历史，重新开启后可继续累积，设置保存到下次启动")
        return true
    }

    @MainActor
    private static func runPinHistoryCaptureSaveCheck(image: CGImage, configURL: URL) -> Bool {
        let app = AirSnipAppController(configURL: configURL)
        let directory = configURL.deletingLastPathComponent()
        app.updateConfig {
            $0.lastSaveDirectory = directory.path
            $0.smartPngCompression = false
            $0.showCompletionToast = false
        }
        let pins = app.pinManager
        defer { pins.closeAll() }
        guard pins.createPin(cgImage: image, backingScale: 1, preferredScreenOriginAppKit: nil, config: app.config),
              let pin = pins.windows.last else { return false }
        let previousWindows = Set(NSApp.windows.map(\.windowNumber))
        pin.requestInlineAnnotate()
        guard let editor = NSApp.windows.first(where: { $0.isVisible && !previousWindows.contains($0.windowNumber) }),
              let responder = editor.firstResponder else { return false }

        func pressKey(_ keyCode: Int, _ characters: String, modifiers: NSEvent.ModifierFlags = []) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: editor.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode)
            ) else { return }
            responder.keyDown(with: event)
        }

        app.updateConfig {
            $0.pinHistoryLimit = 5
            $0.pinHistoryParentDirectory = directory.path
            $0.pinBorder = false
        }
        pressKey(kVK_ANSI_2, "2")
        let savedConfig = AirSnipConfig.load(from: configURL)
        guard app.config.pinHistoryLimit == 5, app.config.lastTool == .arrow,
              app.config.pinHistoryParentDirectory == directory.path, savedConfig.pinHistoryParentDirectory == directory.path,
              savedConfig.pinHistoryLimit == 5, savedConfig.lastTool == .arrow,
              !app.config.pinBorder, !savedConfig.pinBorder else {
            fputs("FAIL: Tool changes from an older capture session should preserve current pin history and border settings\n", stderr)
            return false
        }

        let quickSaveDirectory = directory.appendingPathComponent("quick-save", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: quickSaveDirectory, withIntermediateDirectories: false)) != nil else {
            return false
        }
        app.updateConfig {
            $0.pinHistoryLimit = 10
            $0.pinHistoryParentDirectory = nil
            $0.lastSaveDirectory = quickSaveDirectory.path
        }
        pressKey(kVK_ANSI_S, "s", modifiers: .command)
        guard !editor.isVisible, pin.window.isVisible,
              (try? FileManager.default.contentsOfDirectory(atPath: quickSaveDirectory.path))?.contains(where: { $0.hasSuffix(".png") }) == true else {
            fputs("FAIL: Quick save from an older session should use the current save directory\n", stderr)
            return false
        }
        let savedAfterQuickSave = AirSnipConfig.load(from: configURL)
        guard app.config.pinHistoryLimit == 10, savedAfterQuickSave.pinHistoryLimit == 10,
              app.config.pinHistoryParentDirectory == nil, savedAfterQuickSave.pinHistoryParentDirectory == nil,
              !app.config.pinBorder, !savedAfterQuickSave.pinBorder else {
            fputs("FAIL: Quick save from an older session should preserve the current pin settings\n", stderr)
            return false
        }

        let saveAsURL = directory.appendingPathComponent("save-as.jpg")
        let saveAs = app.makeSessionCoordinator(mode: .normalCapture, chooseSaveDestination: { _ in
            app.updateConfig {
                $0.pinHistoryLimit = 15
                $0.pinHistoryParentDirectory = quickSaveDirectory.path
            }
            return OutputService.SavePanelSelection(url: saveAsURL, format: .jpeg, smartPngCompression: false, quality: .compact)
        })
        saveAs.finishWithSave(image: image, scale: 1, forceDialog: true)
        let savedAfterSaveAs = AirSnipConfig.load(from: configURL)
        guard FileManager.default.fileExists(atPath: saveAsURL.path),
              savedAfterSaveAs.lastSaveDirectory == directory.path, savedAfterSaveAs.lastSaveFormat == .jpeg,
              savedAfterSaveAs.pngCompressionQuality == .compact, savedAfterSaveAs.pinHistoryLimit == 15,
              savedAfterSaveAs.pinHistoryParentDirectory == quickSaveDirectory.path else {
            fputs("FAIL: Save As should apply its selected preferences without replacing newer pin settings\n", stderr)
            return false
        }
        print("[pins] PASS: 旧编辑会话改工具、快速保存或另存为时保留当前贴图设置")
        return true
    }

    public static func run() -> Bool {
        do {
            print("[smoke] 1/7 验证配置往返、无损压缩默认开启与 24 项工具栏可见性...")
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("isnip-smoke-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let cfgURL = tempDir.appendingPathComponent("config.json")
            var cfg = AirSnipConfig()
            guard cfg.smartPngCompression == true,
                  cfg.compressClipboardPng == true,
                  cfg.askBeforeSave == false,
                  cfg.longshotAutoScroll == true,
                  cfg.longshotScrollSpeed == .normal,
                  cfg.swatchColors[1] == RGBAColor(r: 255, g: 0, b: 0),
                  cfg.defaultLineWidth == 2.0,
                  cfg.pngCompressionQuality == .visuallyLossless,
                  cfg.nameStyle.formatBaseName().hasPrefix("isnip-") else {
                fputs("FAIL: Default iSnip config or smartPngCompression default mismatch\n", stderr)
                return false
            }
            cfg.toolbar.setVisible(.tool(.ellipse), false)
            cfg.toolbar.setVisible(.ocr, false)
            try cfg.save(to: cfgURL)
            let loaded = AirSnipConfig.load(from: cfgURL)
            guard !loaded.toolbar.isVisible(.tool(.ellipse)),
                  !loaded.toolbar.isVisible(.ocr),
                  loaded.toolbar.isVisible(.tool(.rect)),
                  loaded.smartPngCompression == true else {
                fputs("FAIL: Config roundtrip mismatch\n", stderr)
                return false
            }

            print("[smoke] 2/7 验证 10 大矢量标注烘焙与三次盒式高斯模糊...")
            let baseW = 560
            let baseH = 360
            var rawBytes = [UInt8](repeating: 255, count: baseW * baseH * 4)
            for y in 0..<baseH {
                for x in 0..<baseW {
                    let i = (y * baseW + x) * 4
                    // Rich UI-like multi-band wallpaper + card backdrop so Liquid Glass blur & pngquant both shine
                    if x > 60 && x < 500 && y > 48 && y < 300 {
                        rawBytes[i] = UInt8(242 - (y / 12))
                        rawBytes[i + 1] = UInt8(246 - (x / 40))
                        rawBytes[i + 2] = 252
                    } else {
                        rawBytes[i] = UInt8(24 + (x * 90) / baseW)
                        rawBytes[i + 1] = UInt8(72 + (y * 110) / baseH)
                        rawBytes[i + 2] = UInt8(168 + ((x + y) * 60) / (baseW + baseH))
                    }
                    rawBytes[i + 3] = 255
                }
            }
            guard let baseCG = PixelBufferRGBA(width: baseW, height: baseH, rgba: rawBytes).makeCGImage() else {
                fputs("FAIL: Failed to create synthetic base CGImage\n", stderr)
                return false
            }

            let doc = AnnotationDocument()
            let red = AnnotationStyle(color: RGBAColor(r: 229, g: 57, b: 53), lineWidth: 4)
            doc.add(AnnotationObject(style: red, kind: .rect(a: ASPoint(10, 10), b: ASPoint(90, 60), cornerRadius: 8, filled: true)))
            doc.add(AnnotationObject(style: red, kind: .straightArrow(from: ASPoint(20, 80), to: ASPoint(140, 110))))
            doc.add(AnnotationObject(style: red, kind: .highlight(a: ASPoint(30, 30), b: ASPoint(120, 55), cornerRadius: 4)))
            doc.add(AnnotationObject(style: red, kind: .blur(a: ASPoint(40, 40), b: ASPoint(130, 100), blurRadius: 12, cornerRadius: 6)))
            doc.add(AnnotationObject(style: red, kind: .glow(a: ASPoint(15, 15), b: ASPoint(160, 115), cornerRadius: 8)))
            doc.add(AnnotationObject(style: red, kind: .number(center: ASPoint(50, 95), tip: ASPoint(95, 95), number: 1, fontSize: 20)))
            doc.add(AnnotationObject(style: red, kind: .line(from: ASPoint(10, 110), to: ASPoint(180, 110))))
            doc.add(AnnotationObject(style: red, kind: .ellipse(a: ASPoint(100, 20), b: ASPoint(180, 70), filled: false)))
            doc.add(AnnotationObject(style: red, kind: .freehand(points: [ASPoint(20, 20), ASPoint(40, 35), ASPoint(75, 25)])))
            let m = AnnotationRenderer.measureText("iSnip 极速截图", fontFamily: "PingFang SC", fontSize: 20, bold: true, italic: false)
            doc.add(AnnotationObject(style: red, kind: .text(pos: ASPoint(20, 50), text: "iSnip 极速截图", fontSize: 20, fontFamily: "PingFang SC", bold: true, italic: false, measuredWidth: m.width, measuredHeight: m.height)))

            guard let baked = AnnotationRenderer.bakeOutput(
                rawSelection: baseCG,
                objects: doc.objects,
                selectionOrigin: ASPoint(0, 0),
                pixelScale: 2.0
            ), baked.width == baseW && baked.height == baseH else {
                fputs("FAIL: AnnotationRenderer.bakeOutput failed\n", stderr)
                return false
            }

            print("[smoke] 3/7 验证 PNG / JPEG / 纯 Swift 无损 WebP 编码、144 DPI Retina 1:1 物理比例与逐像素无损校验...")
            let pngData = try ImageEncoder.encode(baked, format: .png, scale: 2.0)
            let jpgData = try ImageEncoder.encode(baked, format: .jpeg, scale: 2.0)
            let webpData = try ImageEncoder.encode(baked, format: .webp, scale: 2.0)
            guard !pngData.isEmpty, !jpgData.isEmpty, !webpData.isEmpty else {
                fputs("FAIL: Image encoding produced empty output\n", stderr)
                return false
            }
            for (label, encodedData) in [("PNG", pngData), ("JPEG", jpgData), ("WebP", webpData)] {
                guard let src = CGImageSourceCreateWithData(encodedData as CFData, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                      let dpiW = props[kCGImagePropertyDPIWidth] as? Double,
                      let dpiH = props[kCGImagePropertyDPIHeight] as? Double,
                      abs(dpiW - 144.0) < 0.5,
                      abs(dpiH - 144.0) < 0.5,
                      let nsImg = NSImage(data: encodedData),
                      abs(Double(nsImg.size.width) - Double(baseW) / 2.0) < 0.5,
                      abs(Double(nsImg.size.height) - Double(baseH) / 2.0) < 0.5 else {
                    fputs("FAIL: \(label) 2x Retina DPI / 1:1 NSImage.size check failed\n", stderr)
                    return false
                }
            }
            guard let webpSrc = CGImageSourceCreateWithData(webpData as CFData, nil),
                  let webpDecoded = CGImageSourceCreateImageAtIndex(webpSrc, 0, nil),
                  let origBuf = PixelBufferRGBA(cgImage: baked),
                  let decBuf = PixelBufferRGBA(cgImage: webpDecoded),
                  origBuf == decBuf else {
                fputs("FAIL: Lossless WebP roundtrip pixel mismatch\n", stderr)
                return false
            }

            print("[smoke] 4/7 验证内置 pngquant + oxipng 智能无损 PNG 压缩管线（保留 144 DPI）...")
            let compRes = try ImageEncoder.encodePNGWithReport(
                baked,
                scale: 2.0,
                smartCompression: true,
                quality: .visuallyLossless,
                mode: .fullPipeline(oxipngMax: true)
            )
            guard compRes.usedPngquant,
                  compRes.usedOxipng,
                  compRes.compressedBytes < compRes.originalBytes,
                  let compSrc = CGImageSourceCreateWithData(compRes.data as CFData, nil),
                  let compProps = CGImageSourceCopyPropertiesAtIndex(compSrc, 0, nil) as? [CFString: Any],
                  let compDpiW = compProps[kCGImagePropertyDPIWidth] as? Double,
                  abs(compDpiW - 144.0) < 0.5,
                  let compDecoded = CGImageSourceCreateImageAtIndex(compSrc, 0, nil),
                  compDecoded.width == baseW && compDecoded.height == baseH else {
                fputs("FAIL: PngSmartCompressor pipeline failed (usedPngquant=\(compRes.usedPngquant), usedOxipng=\(compRes.usedOxipng), \(compRes.originalBytes) -> \(compRes.compressedBytes))\n", stderr)
                return false
            }
            print("[smoke]   ↳ PNG 智能压缩实测：\(compRes.originalBytes) B → \(compRes.compressedBytes) B (-\(compRes.savedRatioPercent)%)")

            print("[smoke] 5/7 验证长截图固定页眉页脚检测与滚动拼接引擎...")
            let w = 80
            let pageRows = 160
            var page = [UInt8](repeating: 255, count: w * pageRows * 4)
            for y in 0..<pageRows {
                for x in 0..<w {
                    let o = (y * w + x) * 4
                    page[o] = UInt8(y & 0xFF)
                    page[o + 1] = UInt8((x * 5 + y * 3) & 0xFF)
                    page[o + 2] = UInt8((y * 11) & 0xFF)
                    page[o + 3] = 255
                }
            }
            func makeFrame(scrollY: Int) -> PixelBufferRGBA {
                let fh = 60
                var buf = [UInt8](repeating: 255, count: w * fh * 4)
                for y in 0..<fh {
                    for x in 0..<w {
                        let dst = (y * w + x) * 4
                        if y < 10 {
                            buf[dst] = 20; buf[dst+1] = 80; buf[dst+2] = UInt8(x * 2); buf[dst+3] = 255
                        } else if y >= 50 {
                            buf[dst] = 90; buf[dst+1] = 30; buf[dst+2] = UInt8(x * 2); buf[dst+3] = 255
                        } else {
                            let srcY = scrollY + (y - 10)
                            let src = (srcY * w + x) * 4
                            buf[dst] = page[src]; buf[dst+1] = page[src+1]; buf[dst+2] = page[src+2]; buf[dst+3] = 255
                        }
                    }
                }
                return PixelBufferRGBA(width: w, height: fh, rgba: buf)
            }

            let lsCanvas = LongshotCanvas(width: w, frameHeight: 60)
            lsCanvas.seed(makeFrame(scrollY: 0))
            let s1 = lsCanvas.push(makeFrame(scrollY: 15))
            let s2 = lsCanvas.push(makeFrame(scrollY: 30))
            guard case .appended(15, 15) = s1,
                  case .appended(15, 15) = s2,
                  lsCanvas.headerHeight == 10,
                  lsCanvas.footerHeight == 10,
                  lsCanvas.totalHeight == 90 else {
                fputs("FAIL: LongshotCanvas stitching height mismatch (got \(lsCanvas.totalHeight))\n", stderr)
                return false
            }

            print("[smoke] 6/7 验证本地离线 Vision OCR 中英文识别与二维码解析...")
            let ocrW = 680
            let ocrH = 180
            guard let ocrCtx = CGContext(
                data: nil,
                width: ocrW,
                height: ocrH,
                bitsPerComponent: 8,
                bytesPerRow: ocrW * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            ocrCtx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ocrCtx.fill(CGRect(x: 0, y: 0, width: ocrW, height: ocrH))
            let nsGfx = NSGraphicsContext(cgContext: ocrCtx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsGfx
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 34, weight: .bold),
                .foregroundColor: NSColor.black
            ]
            ("极速截图 iSnip 2026" as NSString).draw(at: NSPoint(x: 28, y: 65), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()

            if let qrFilter = CIFilter(name: "CIQRCodeGenerator") {
                qrFilter.setValue(Data("https://github.com/zzusec/isnip".utf8), forKey: "inputMessage")
                qrFilter.setValue("M", forKey: "inputCorrectionLevel")
                if let ciOut = qrFilter.outputImage {
                    let scaled = ciOut.transformed(by: CGAffineTransform(scaleX: 4, y: 4))
                    let ciCtx = CIContext(options: nil)
                    if let qrCG = ciCtx.createCGImage(scaled, from: scaled.extent) {
                        ocrCtx.interpolationQuality = .none
                        ocrCtx.draw(qrCG, in: CGRect(x: 510, y: 20, width: 140, height: 140))
                    }
                }
            }

            guard let ocrImg = ocrCtx.makeImage() else {
                fputs("FAIL: Failed to create OCR fixture\n", stderr)
                return false
            }
            let underRosetta = isRunningUnderRosetta
            for language in ["auto", "zh-Hans"] {
                let detailed = try LocalVisionOCR.recognizeDetailed(
                    cgImage: ocrImg,
                    languagePreference: language,
                    detectBarcodes: true
                )
                let textMatched = underRosetta
                    ? detailed.rawText.localizedCaseInsensitiveContains("isnip")
                    : (detailed.rawText.contains("极速截图") && detailed.rawText.contains("iSnip"))
                guard textMatched else {
                    fputs("FAIL: LocalVisionOCR output missing expected text: \(detailed.rawText)\n", stderr)
                    return false
                }
                guard detailed.barcodes.contains("https://github.com/zzusec/isnip") else {
                    fputs("FAIL: LocalVisionOCR barcode missing expected payload: \(detailed.barcodes)\n", stderr)
                    return false
                }
            }

            print("[smoke] 7/7 验证菜单栏常驻 (.accessory) 模式下零抖动覆盖层 NSPanel 与 Studio 设置视图...")
            let overlayOK: Bool = MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                guard let screen = NSScreen.main ?? NSScreen.screens.first,
                      let rawBuf = PixelBufferRGBA(cgImage: baseCG) else {
                    return false
                }
                let sFrame = screen.frame
                let snap = CapturedScreenSnapshot(
                    screen: screen,
                    frameInGlobalAppKit: sFrame,
                    frameTopDown: ASRect(x: 0, y: 0, width: Double(sFrame.width), height: Double(sFrame.height)),
                    cgImage: baseCG,
                    rawBuffer: rawBuf,
                    backingScale: max(1.0, Double(screen.backingScaleFactor)),
                    windowsLocalTopDown: []
                )
                var ended = false
                var defaultCfg = AirSnipConfig()
                defaultCfg.theme = .light
                defaultCfg.lastSaveDirectory = tempDir.path
                var saveCfg = defaultCfg
                saveCfg.smartPngCompression = false
                guard let quickSaved1 = OutputService.saveImage(for: baked, backingScale: snap.backingScale, config: saveCfg)?.url,
                      FileManager.default.fileExists(atPath: quickSaved1.path),
                      let saved1Img = NSImage(contentsOf: quickSaved1),
                      abs(Double(saved1Img.size.width) - Double(baseW) / snap.backingScale) < 0.5,
                      let quickSaved2 = OutputService.saveImage(for: baked, backingScale: snap.backingScale, config: saveCfg)?.url,
                      FileManager.default.fileExists(atPath: quickSaved2.path),
                      quickSaved1 != quickSaved2 else {
                    return false
                }

                // Exercise the same asynchronous recognition and result panel used by F2 / clipboard OCR,
                // not just the synchronous Vision engine. This test uses only the synthetic fixture above.
                let existingWindows = Set(NSApp.windows.map(\.windowNumber))
                let ocrManager = OCRBubbleManager()
                ocrManager.recognizeAndPresent(rawSelectionImage: ocrImg, anchorScreenPoint: nil, config: defaultCfg)
                let ocrDeadline = Date().addingTimeInterval(60)
                while ocrManager.isRecognizing && Date() < ocrDeadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                }
                let panelTextOK = underRosetta
                    ? ocrManager.text.localizedCaseInsensitiveContains("isnip")
                    : (ocrManager.text.contains("极速截图") && ocrManager.text.contains("iSnip"))
                let ocrPanelOK = !ocrManager.isRecognizing && ocrManager.errorMessage == nil
                    && panelTextOK
                    && ocrManager.barcodes.contains("https://github.com/zzusec/isnip")
                defer { ocrManager.dismiss() }
                if let previewPath = ProcessInfo.processInfo.environment["AIRSNIP_SMOKE_OCR_PREVIEW_PNG"] {
                    guard let view = NSApp.windows.first(where: { !existingWindows.contains($0.windowNumber) })?.contentView else {
                        fputs("FAIL: OCR result panel missing for preview\n", stderr)
                        return false
                    }
                    view.layoutSubtreeIfNeeded()
                    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
                    do {
                        try png.write(to: URL(fileURLWithPath: previewPath))
                    } catch {
                        fputs("FAIL: Could not save OCR panel preview: \(error)\n", stderr)
                        return false
                    }
                }
                ocrManager.dismiss()
                guard ocrPanelOK else {
                    fputs("FAIL: OCR result panel did not finish recognition successfully\n", stderr)
                    return false
                }

                let coordinator = CaptureSessionCoordinator(config: defaultCfg, mode: .normalCapture)
                coordinator.onSessionEnded = { ended = true }
                coordinator.startWithSnapshots([snap])
                let visibleAndPersistent = coordinator.hasVisibleWindows
                    && coordinator.allPanelsPersistOnDeactivate
                    && coordinator.allPanelsZeroAnimationAndExactFrame

                let sampleSel = ASRect(
                    x: max(20, Double(sFrame.width) * 0.15),
                    y: max(20, Double(sFrame.height) * 0.20),
                    width: min(640, Double(sFrame.width) * 0.65),
                    height: min(320, Double(sFrame.height) * 0.45)
                )
                let expectedIDs = [
                    "tool.rect", "tool.ellipse", "tool.line", "tool.arrow", "tool.freehand",
                    "tool.blur", "tool.text", "tool.number", "tool.glow",
                    "output.pin", "edit.undo", "output.ocr", "file.cancel",
                    "output.longshot", "file.save", "file.copy"
                ]
                var toolbarExactMatch = false
                if let sample = coordinator.renderToolbarVerificationSample(selection: sampleSel) {
                    toolbarExactMatch = (sample.toolbarIDs == expectedIDs) && !sample.hasSecondaryBar
                    if let previewPath = ProcessInfo.processInfo.environment["AIRSNIP_SMOKE_PREVIEW_PNG"],
                       let cg = sample.croppedImage {
                        let rep = NSBitmapImageRep(cgImage: cg)
                        if let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: previewPath))
                        }
                    }
                }

                // Verify Isolated Window Capture baking (transparent rounded corners + red annotation + macOS drop shadow)
                var isolatedWindowOK = false
                let winPxW = 320
                let winPxH = 200
                if let winCtx = CGContext(
                    data: nil,
                    width: winPxW,
                    height: winPxH,
                    bitsPerComponent: 8,
                    bytesPerRow: winPxW * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) {
                    let rr = CGPath(roundedRect: CGRect(x: 0, y: 0, width: winPxW, height: winPxH), cornerWidth: 24, cornerHeight: 24, transform: nil)
                    winCtx.addPath(rr)
                    winCtx.setFillColor(CGColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 1.0))
                    winCtx.fillPath()
                    if let mockWinCG = winCtx.makeImage(),
                       let shadowedWinCG = coordinator.renderIsolatedWindowVerificationSample(
                           windowImage: mockWinCG,
                           rect: ASRect(x: 80, y: 80, width: 160, height: 100),
                           includeShadow: true
                       ),
                       let shadowedBuf = PixelBufferRGBA(cgImage: shadowedWinCG) {
                        let cornerAlpha = shadowedBuf.pixel(x: 0, y: 0).a
                        let centerPixel = shadowedBuf.pixel(x: shadowedWinCG.width / 2, y: shadowedWinCG.height / 2)
                        isolatedWindowOK = shadowedWinCG.width > winPxW
                            && shadowedWinCG.height > winPxH
                            && cornerAlpha == 0
                            && centerPixel.a == 255
                    }
                }

                coordinator.cancelSession()

                // Verify Longshot first-mouse click acceptance, immediate smart-PNG disk write, and full-res tall Longshot annotation export
                let firstMouseOK = FirstMouseHostingView(rootView: EmptyView()).acceptsFirstMouse(for: nil)
                var smartSaveImmediateCfg = defaultCfg
                smartSaveImmediateCfg.smartPngCompression = true
                var smartSaveImmediateOK = false
                if let immURL = OutputService.saveImage(for: baked, config: smartSaveImmediateCfg)?.url,
                   let immData = try? Data(contentsOf: immURL),
                   immData.count > 64 {
                    smartSaveImmediateOK = true
                }

                var longshotSaveAndEditOK = false
                let tallW = 800
                let tallH = 2800
                let tallBytes = [UInt8](repeating: 248, count: tallW * tallH * 4)
                let tallBuf = PixelBufferRGBA(width: tallW, height: tallH, rgba: tallBytes)
                if let tallCG = tallBuf.makeCGImage() {
                    var lsSavedDims: (Int, Int)?
                    let lsSession = LongshotSessionController(
                        screen: screen,
                        viewportTopDown: ASRect(x: 40, y: 40, width: 400, height: 300),
                        initialCrop: tallBuf,
                        config: defaultCfg,
                        autoStartScroll: false
                    )
                    lsSession.onFinishSave = { cg, _, _ in
                        lsSavedDims = (cg.width, cg.height)
                    }
                    lsSession.finishAndSave()

                    let tallEditCoord = CaptureSessionCoordinator(
                        config: defaultCfg,
                        mode: .standaloneImageEdit(tallCG, max(1.0, Double(screen.backingScaleFactor)), screen)
                    )
                    tallEditCoord.startStandaloneImageEdit(
                        cgImage: tallCG,
                        backingScale: max(1.0, Double(screen.backingScaleFactor)),
                        screen: screen
                    )
                    if let tallBaked = tallEditCoord.renderStandaloneAnnotatedOutputSample() {
                        longshotSaveAndEditOK = (lsSavedDims?.0 == tallW)
                            && (lsSavedDims?.1 == tallH)
                            && (tallBaked.width == tallW)
                            && (tallBaked.height == tallH)
                    }
                    tallEditCoord.cancelSession()
                }

                // Optional Settings window snapshot dump when AIRSNIP_SMOKE_PREVIEW_DIR is active
                if let dirPath = ProcessInfo.processInfo.environment["AIRSNIP_SMOKE_PREVIEW_DIR"] {
                    let dirURL = URL(fileURLWithPath: dirPath)
                    try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                    let dummyApp = AirSnipAppController(configURL: tempDir.appendingPathComponent("preview-config.json"))
                    func renderSettingsWindowSnapshot(
                        rootView: SettingsRootView,
                        appearance: NSAppearance.Name,
                        to outURL: URL
                    ) {
                        let win = NSWindow(
                            contentRect: NSRect(x: -5000, y: -5000, width: 880, height: 640),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                            backing: .buffered,
                            defer: false
                        )
                        win.titleVisibility = .hidden
                        win.titlebarAppearsTransparent = true
                        let tb = NSToolbar(identifier: "preview.tb.\(UUID().uuidString)")
                        tb.showsBaselineSeparator = false
                        win.toolbar = tb
                        win.toolbarStyle = .unified
                        win.appearance = NSAppearance(named: appearance)
                        let host = NSHostingView(rootView: rootView)
                        host.frame = NSRect(x: 0, y: 0, width: 880, height: 640)
                        host.appearance = NSAppearance(named: appearance)
                        win.contentView = host
                        win.layoutIfNeeded()
                        host.layoutSubtreeIfNeeded()
                        let targetView = win.contentView?.superview ?? host
                        targetView.layoutSubtreeIfNeeded()
                        if let rep = targetView.bitmapImageRepForCachingDisplay(in: targetView.bounds) {
                            targetView.cacheDisplay(in: targetView.bounds, to: rep)
                            if let png = rep.representation(using: .png, properties: [:]) {
                                try? png.write(to: outURL)
                            }
                        }
                        win.orderOut(nil)
                    }

                    dummyApp.updateConfig { $0.language = .zhHans }
                    let tabsToDump: [(SettingsTab, String)] = [
                        (.general, "01_general.png"),
                        (.captureAndPin, "02_capture.png"),
                        (.toolbar, "03_toolbar.png"),
                        (.hotkeys, "04_hotkeys.png"),
                        (.editor, "05_editor.png"),
                        (.ocr, "06_ocr.png"),
                        (.about, "07_about.png"),
                    ]
                    for (tab, fileName) in tabsToDump {
                        renderSettingsWindowSnapshot(
                            rootView: SettingsRootView(app: dummyApp, initialTab: tab),
                            appearance: .aqua,
                            to: dirURL.appendingPathComponent(fileName)
                        )
                    }

                    // Dark appearance checks + Search filter + White (#FFFFFF) swatch preview contrast check
                    renderSettingsWindowSnapshot(
                        rootView: SettingsRootView(app: dummyApp, initialTab: .general),
                        appearance: .darkAqua,
                        to: dirURL.appendingPathComponent("01_general_dark.png")
                    )
                    renderSettingsWindowSnapshot(
                        rootView: SettingsRootView(app: dummyApp, initialTab: .about),
                        appearance: .darkAqua,
                        to: dirURL.appendingPathComponent("07_about_dark.png")
                    )
                    renderSettingsWindowSnapshot(
                        rootView: SettingsRootView(app: dummyApp, initialTab: .general, initialSearchQuery: "压缩"),
                        appearance: .aqua,
                        to: dirURL.appendingPathComponent("09_search.png")
                    )

                    dummyApp.updateConfig { $0.activeColorIndex = 0 } // #FFFFFF pure white swatch
                    renderSettingsWindowSnapshot(
                        rootView: SettingsRootView(app: dummyApp, initialTab: .editor),
                        appearance: .aqua,
                        to: dirURL.appendingPathComponent("05_editor_white_swatch.png")
                    )

                    // English UI verification snapshots
                    dummyApp.updateConfig {
                        $0.activeColorIndex = 1
                        $0.language = .en
                    }
                    renderSettingsWindowSnapshot(
                        rootView: SettingsRootView(app: dummyApp, initialTab: .general),
                        appearance: .aqua,
                        to: dirURL.appendingPathComponent("01_general_en.png")
                    )
                    renderSettingsWindowSnapshot(
                        rootView: SettingsRootView(app: dummyApp, initialTab: .hotkeys),
                        appearance: .aqua,
                        to: dirURL.appendingPathComponent("04_hotkeys_en.png")
                    )
                    renderSettingsWindowSnapshot(
                        rootView: SettingsRootView(app: dummyApp, initialTab: .about),
                        appearance: .darkAqua,
                        to: dirURL.appendingPathComponent("07_about_en_dark.png")
                    )
                    dummyApp.updateConfig { $0.language = .zhHans }
                    renderSettingsWindowSnapshot(
                        rootView: SettingsRootView(app: dummyApp, initialTab: .about, initialShowDingDingQR: true),
                        appearance: .aqua,
                        to: dirURL.appendingPathComponent("13_dingding_qr_modal.png")
                    )
                    renderSettingsWindowSnapshot(
                        rootView: SettingsRootView(app: dummyApp, initialTab: .general, initialShowDingDingQR: true),
                        appearance: .darkAqua,
                        to: dirURL.appendingPathComponent("13_dingding_qr_modal_dark.png")
                    )

                    let lsCtrl = LongshotSessionController(
                        screen: screen,
                        viewportTopDown: ASRect(x: 100, y: 100, width: 480, height: 320),
                        initialCrop: rawBuf,
                        config: defaultCfg,
                        autoStartScroll: false
                    )
                    let lsPreviewRoot = ZStack {
                        Color(white: 0.94)
                        LongshotControlBarView(controller: lsCtrl)
                            .padding(8)
                    }
                    let lsHost = NSHostingView(rootView: lsPreviewRoot)
                    lsHost.frame = NSRect(x: 0, y: 0, width: 548, height: 58)
                    lsHost.appearance = NSAppearance(named: .aqua)
                    let offWin = NSWindow(
                        contentRect: NSRect(x: -4000, y: -4000, width: 548, height: 58),
                        styleMask: [.borderless],
                        backing: .buffered,
                        defer: false
                    )
                    offWin.appearance = NSAppearance(named: .aqua)
                    offWin.contentView = lsHost
                    lsHost.layoutSubtreeIfNeeded()
                    if let rep = lsHost.bitmapImageRepForCachingDisplay(in: lsHost.bounds) {
                        lsHost.cacheDisplay(in: lsHost.bounds, to: rep)
                        if let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: dirURL.appendingPathComponent("08_longshot_bar.png"))
                        }
                    }
                    offWin.orderOut(nil)
                }

                return visibleAndPersistent && toolbarExactMatch && isolatedWindowOK && firstMouseOK && smartSaveImmediateOK && longshotSaveAndEditOK && !coordinator.hasVisibleWindows && ended
            }
            guard overlayOK else {
                fputs("FAIL: Overlay panel hidesOnDeactivate / accessory visibility check failed\n", stderr)
                return false
            }

            // Opening and closing many pin windows can delay async OCR in the smoke process.
            print("[smoke] 验证贴图关闭、恢复与历史设置...")
            let pinSaveConfigURL = tempDir.appendingPathComponent("pin-save", isDirectory: true).appendingPathComponent("config.json")
            let pinRestoreOK = try MainActor.assumeIsolated {
                guard let screen = NSScreen.main ?? NSScreen.screens.first else { return false }
                return try runCroppedPinStorageCheck(on: screen)
                    && withPinRestoreFixture(
                        image: baseCG,
                        configURL: tempDir.appendingPathComponent("pin-config.json"),
                        runPinRestoreChecks
                    )
                    && withPinRestoreFixture(
                        image: baseCG,
                        configURL: tempDir.appendingPathComponent("text-pin-config.json"),
                        runClipboardTextPinCheck
                    )
                    && withPinRestoreFixture(
                        image: baseCG,
                        configURL: tempDir.appendingPathComponent("text-pin-layout-config.json"),
                        runTextPinLayoutCheck
                    )
                    && withPinRestoreFixture(
                        image: baseCG,
                        configURL: tempDir.appendingPathComponent("oversized-text-pin-config.json"),
                        runOversizedTextPinCheck
                    )
                    && withPinRestoreFixture(
                        image: baseCG,
                        configURL: tempDir.appendingPathComponent("text-pin-copy-config.json"),
                        runTextPinOriginalCopyCheck
                    )
                    && withPinRestoreFixture(
                        image: baseCG,
                        configURL: tempDir.appendingPathComponent("pin-batch-config.json"),
                        runBatchPinRestoreCheck
                    )
                    && runBatchCloseDuringInlineEditCheck(image: baseCG)
                    && runClosedPinHistoryLimitCheck(image: baseCG)
                    && withPinRestoreFixture(
                        image: baseCG,
                        configURL: tempDir.appendingPathComponent("pin-history-disk-config.json"),
                        runDiskPinHistoryCheck
                    )
                    && runFailedPinHistoryWriteCheck(image: baseCG, directory: tempDir)
                    && withPinRestoreFixture(
                        image: baseCG,
                        configURL: tempDir.appendingPathComponent("pin-history-config.json"),
                        runConfiguredPinHistoryCheck
                    )
                    && runPinHistoryCaptureSaveCheck(image: baseCG, configURL: pinSaveConfigURL)
            }
            guard pinRestoreOK else { return false }

            print("smoke-test: ok (iSnip v\(UpdateChecker.currentVersion))")
            return true
        } catch {
            fputs("FAIL: Smoke test threw error: \(error)\n", stderr)
            return false
        }
    }
}
