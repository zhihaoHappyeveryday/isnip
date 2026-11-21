import AppKit
import Carbon
import CoreGraphics
import CoreImage
import ImageIO
import SwiftUI
import Translation
import AirSnipCore

public enum SmokeTestRunner {
    @MainActor
    public static func runWindowCaptureChecks() -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard CGPreflightScreenCaptureAccess(), let screen = NSScreen.main else {
            fputs("FAIL: Window capture self-test requires screen recording permission\n", stderr)
            return false
        }
        let sourceWindow = NSWindow(
            contentRect: NSRect(x: screen.visibleFrame.minX + 100, y: screen.visibleFrame.minY + 100, width: 260, height: 180),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        sourceWindow.isReleasedWhenClosed = false
        sourceWindow.title = "iSnip window capture test"
        sourceWindow.backgroundColor = .systemBlue
        sourceWindow.orderFrontRegardless()
        defer { sourceWindow.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        let canvasFrame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let background = PixelBufferRGBA(width: 640, height: 480, rgba: [UInt8](repeating: 255, count: 640 * 480 * 4))
        guard let backgroundImage = background.makeCGImage() else { return false }
        let candidateRect = ASRect(x: 80, y: 80, width: sourceWindow.frame.width, height: sourceWindow.frame.height)

        func capture(mode: CaptureSessionCoordinator.SessionMode, windowID: UInt32, shadow: Bool = false,
                     option: Bool = false, drag: Bool = false, snapEnabled: Bool = true) -> (image: CGImage?, completed: Bool) {
            var config = AirSnipConfig()
            config.windowCaptureShadow = shadow
            config.windowSnap = snapEnabled
            let coordinator = CaptureSessionCoordinator(config: config, mode: mode)
            var output: CGImage?
            coordinator.onCompleteCopy = { image, _ in output = image }
            coordinator.onStartOCR = { image, _ in output = image }
            coordinator.onStartLongshot = { _, _, buffer, _ in output = buffer.makeCGImage() }
            let snapshot = CapturedScreenSnapshot(
                screen: screen, frameInGlobalAppKit: canvasFrame,
                frameTopDown: ASRect(x: 0, y: 0, width: 640, height: 480),
                cgImage: backgroundImage, rawBuffer: background, backingScale: 1,
                windowsLocalTopDown: [WindowSnapCandidate(windowID: windowID, rect: candidateRect, isMaximizedLike: false)]
            )
            let overlay = OverlayScreenController(snapshot: snapshot, coordinator: coordinator)
            let canvas = overlay.canvasView
            defer { overlay.panel.close() }
            let startPoint = NSPoint(x: candidateRect.midX, y: candidateRect.midY)
            func mouseEvent(_ type: NSEvent.EventType, point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: option ? [.option] : [], timestamp: 0,
                                   windowNumber: overlay.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            canvas.mouseDown(with: mouseEvent(.leftMouseDown, point: startPoint))
            let endPoint = drag ? NSPoint(x: startPoint.x + 60, y: startPoint.y + 40) : startPoint
            if drag { canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, point: endPoint)) }
            canvas.mouseUp(with: mouseEvent(.leftMouseUp, point: endPoint))
            let deadline = Date().addingTimeInterval(15)
            while canvas.isCapturingIsolatedWindow && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: overlay.panel.windowNumber, context: nil, characters: "\r",
                                                 charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
            return (output, !canvas.isCapturingIsolatedWindow)
        }
        func hasTransparentCorners(_ image: CGImage) -> Bool {
            guard let buffer = PixelBufferRGBA(cgImage: image) else { return false }
            return [(0, 0), (image.width - 1, 0), (0, image.height - 1), (image.width - 1, image.height - 1)].allSatisfy {
                buffer.pixel(x: $0.0, y: $0.1).a == 0
            } && buffer.pixel(x: image.width / 2, y: image.height / 2).a == 255
        }
        let windowID = UInt32(sourceWindow.windowNumber)
        for mode: CaptureSessionCoordinator.SessionMode in [.normalCapture, .directWindowCapture] {
            let result = capture(mode: mode, windowID: windowID)
            guard result.completed, let image = result.image, hasTransparentCorners(image),
                  let png = try? ImageEncoder.encode(image, format: .png, smartPngCompression: true),
                  let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil), hasTransparentCorners(decoded) else {
                fputs("FAIL: Window click or compressed PNG lost native transparent corners\n", stderr)
                return false
            }
            let shadowed = capture(mode: mode, windowID: windowID, shadow: true)
            let toggled = capture(mode: mode, windowID: windowID, shadow: true, option: true)
            guard let shadowImage = shadowed.image, hasTransparentCorners(shadowImage), shadowImage.width > image.width,
                  let toggledImage = toggled.image, hasTransparentCorners(toggledImage), toggledImage.width == image.width else {
                fputs("FAIL: Window shadow setting or Option override changed\n", stderr)
                return false
            }
            let failed = capture(mode: mode, windowID: 0)
            guard failed.completed, failed.image == nil else {
                fputs("FAIL: Failed window capture silently exported the desktop crop\n", stderr)
                return false
            }
            let dragged = capture(mode: mode, windowID: 0, drag: true)
            guard let region = dragged.image, region.width == 60, region.height == 40,
                  PixelBufferRGBA(cgImage: region)?.pixel(x: 0, y: 0).a == 255 else {
                fputs("FAIL: Manual region capture changed\n", stderr)
                return false
            }
        }
        for mode: CaptureSessionCoordinator.SessionMode in [.directOCRCapture, .directLongshotCapture] {
            guard let image = capture(mode: mode, windowID: 0).image,
                  image.width == Int(candidateRect.width), PixelBufferRGBA(cgImage: image)?.pixel(x: 0, y: 0).a == 255 else {
                fputs("FAIL: Direct OCR or longshot no longer uses its original screen region\n", stderr)
                return false
            }
        }
        guard capture(mode: .normalCapture, windowID: windowID, snapEnabled: false).image == nil else {
            fputs("FAIL: Disabled window snap still captured a window\n", stderr)
            return false
        }
        print("[window-capture] PASS: 原生透明四角、PNG 压缩、窗口吸附、独立捕获、阴影切换、失败不回退及手动框选/OCR/长截图边界")
        return true
    }

    @MainActor
    public static func runTranslationChecks() -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard #available(macOS 15.0, *) else {
            print("[translation] SKIP: 系统翻译需要 macOS 15+")
            return true
        }
        let mixedText = """
        M2、M5 均已安装并启动 OCR 修复版，旧版已保留；两机签名、SHA-256 和安装后 --smoke-test 均通过。
        GitHub 已同步至 main：提交 3c9244f (https://github.com/zzusec/isnip/commit/3c9244fc73b5dbf409ad56a315c4ee53c1c57640)，远端已核实，工作区干净；34 项测试通过。本次未发布新 Release。
        记录已写入：交付记录 (.config/records/isnip-delivery.md:1)，并更新了 M2 设备信息 (.config/projects/-Users-example-iSnip/records/m2-deployment-target.md:1) 和安装同步约定 (.config/projects/-Users-example-iSnip/records/install-and-push-workflow.md:1)。
        """
        for (input, expectedLanguage) in [
            (mixedText, "zh-Hans"),
            ("已完成https://example.com/download，安装验证通过，请重新启动应用。", "zh-Hans"),
            ("已安装到 C:\\Applications\\Example\\app.exe，请重新启动应用。", "zh-Hans"),
            ("Hello world", "en"),
            ("The installation is complete. See https://example.com/release for details.", "en"),
            ("", "auto"),
            ("https://example.com/project/release", "auto"),
            ("/Users/example/project/README.md", "auto"),
        ] {
            let request = TextTranslationRequest(text: input, sourceLanguage: "auto", targetLanguage: "en")
            guard request.sourceLanguage == expectedLanguage, request.text == input else {
                fputs("FAIL: Translation language detection: expected=\(expectedLanguage), actual=\(request.sourceLanguage)\n", stderr)
                return false
            }
        }
        let manualRequest = TextTranslationRequest(text: mixedText, sourceLanguage: "ja", targetLanguage: "en")
        guard manualRequest.sourceLanguage == "ja", manualRequest.text == mixedText else {
            fputs("FAIL: Translation must preserve explicit source language and original text\n", stderr)
            return false
        }
        print("[translation] PASS: 中英混排、网址、路径、空文本和手选源语言")
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
        func findSplitView(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView {
                if !split.isVertical, split.arrangedSubviews.count == 2 { return split }
            }
            return view.subviews.lazy.compactMap { findSplitView(in: $0) }.first
        }
        panel.setContentSize(NSSize(width: 800, height: 650))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        panel.contentView?.layoutSubtreeIfNeeded()
        guard let contentView = panel.contentView, let split = findSplitView(in: contentView),
              !split.isVertical, split.arrangedSubviews.count == 2 else {
            fputs("FAIL: Translation requires a native horizontal split view\n", stderr)
            return false
        }
        let panes = split.arrangedSubviews
        let sourceHeight = panes[0].frame.height
        split.setPosition(300, ofDividerAt: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        guard abs(panes[0].frame.height - 300) < 2,
              abs(panes[0].frame.height - sourceHeight) > 10 else {
            fputs("FAIL: Translation divider did not resize source pane\n", stderr)
            return false
        }
        manager.requestTranslation()
        let splitDeadline = Date().addingTimeInterval(10)
        while manager.isTranslating && Date() < splitDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard abs(panes[0].frame.height - 300) < 2 else {
            fputs("FAIL: Retranslating reset the divider position\n", stderr)
            return false
        }
        for position in [CGFloat(0), split.bounds.height] {
            split.setPosition(position, ofDividerAt: 0)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            guard panes[0].frame.height >= 88, panes[1].frame.height >= 96 else {
                fputs("FAIL: Translation split panes collapsed below minimum height\n", stderr)
                return false
            }
        }
        panel.setContentSize(NSSize(width: 400, height: 350))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        guard panes[0].frame.height >= 88, panes[1].frame.height >= 96,
              panes[1].frame.maxY <= split.bounds.height + 1 else {
            fputs("FAIL: Translation split panes escaped the compact window\n", stderr)
            return false
        }
        print("[translation] PASS: 原文/译文分隔线可调整、重译保留位置、最小高度和紧凑窗口")
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
            config.translation.targetLanguage = "en"
            manager.presentSelectedText(mixedText, anchorScreenPoint: nil, config: config)
            let mixedDeadline = Date().addingTimeInterval(60)
            while manager.isTranslating && Date() < mixedDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            guard !manager.isTranslating, manager.translationError == nil,
                  manager.translationRequest?.sourceLanguage == "zh-Hans",
                  manager.text == mixedText, !manager.translatedText.isEmpty,
                  manager.translatedText != mixedText,
                  !manager.translatedText.contains("均已安装并启动"),
                  manager.translatedText.localizedCaseInsensitiveContains("installed"),
                  manager.translatedText.contains("https://github.com/zzusec/isnip/commit/3c9244fc73b5dbf409ad56a315c4ee53c1c57640"),
                  NSPasteboard.general.changeCount == clipboardCount else {
                fputs("FAIL: Mixed Chinese translation: \(manager.translationError ?? manager.translatedText)\n", stderr)
                return false
            }
            print("[translation] PASS: 含网址和文件路径的中文实际译为英文，原文和剪贴板保持不变")
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
    private static func runPinZoomChecks(image: CGImage) -> Bool {
        guard let sample = image.cropping(to: CGRect(x: 0, y: 0, width: 201, height: 151)) else { return false }
        var config = AirSnipConfig()
        config.pinHistoryLimit = 0
        let pins = PinManager()
        pins.getConfig = { config }
        defer { pins.closeAll() }

        for backingScale: Double in [1, 2] {
            guard pins.createPin(cgImage: sample, backingScale: backingScale, preferredScreenOriginAppKit: nil, config: config),
                  let pin = pins.windows.last else { return false }
            let initialSize = pin.window.frame.size
            let originalCanvasSize = NSSize(
                width: Double(sample.width) / backingScale, height: Double(sample.height) / backingScale
            )
            guard pin.window.contentView?.frame.size == originalCanvasSize else {
                fputs("FAIL: Pin canvas should open at the original size \(originalCanvasSize)\n", stderr)
                return false
            }
            for direction in [CGFloat(1), -1, 1, -1] {
                for _ in 0..<10 { pin.adjustZoom(delta: direction, anchorInWindow: .zero) }
                for _ in 0..<10 { pin.adjustZoom(delta: -direction, anchorInWindow: .zero) }
                guard pin.zoomScale == 1, pin.window.frame.size == initialSize,
                      pin.window.contentView?.frame.size == originalCanvasSize else {
                    fputs("FAIL: Pin zoom round trip at \(backingScale)× returned \(pin.zoomScale), \(pin.window.frame.size) instead of 100%, \(initialSize)\n", stderr)
                    return false
                }
            }
            let limits: [(direction: CGFloat, scale: CGFloat, reversedScale: CGFloat)] = [
                (1, 4, 3.7037037037037),
                (-1, 0.2, 0.216),
            ]
            for limit in limits {
                for _ in 0..<30 { pin.adjustZoom(delta: limit.direction, anchorInWindow: .zero) }
                guard pin.zoomScale == limit.scale else {
                    fputs("FAIL: Pin zoom should stop at \(limit.scale)\n", stderr)
                    return false
                }
                pin.adjustZoom(delta: -limit.direction, anchorInWindow: .zero)
                guard abs(pin.zoomScale - limit.reversedScale) < 0.000001 else {
                    fputs("FAIL: Pin zoom should reverse from the clamped scale\n", stderr)
                    return false
                }
                pin.resetTransform()
            }
            pin.closeSelf()
        }
        print("[pins] PASS: 1× 与 2× 贴图在等量滚动后回到原大小，且遵守缩放上下限")
        return true
    }

    @MainActor
    private static func runRestoredPinZoomChecks(image: CGImage, configURL: URL) -> Bool {
        let examples: [(storedScale: CGFloat, direction: CGFloat, nextPercent: Int)] = [
            (1.06, -1, 93),
            (0.98, 1, 108),
            (1.08216, -1, 93), // The next step rounds from 100.2% to 100%.
            (0.924, 1, 108), // The next step rounds from 99.792% to 100%.
            (0.9995, 1, 108),
        ]
        let baseSize = NSSize(width: image.width, height: image.height)
        let origin = NSPoint(x: 60, y: 100)
        let snapshots = examples.map { example in
            let frame = NSRect(origin: origin, size: NSSize(
                width: round(baseSize.width * example.storedScale), height: round(baseSize.height * example.storedScale)
            ))
            let display = PinDisplayState(
                frame: frame, baseSize: baseSize, backingScale: 1, zoomScale: example.storedScale,
                preferredOpacity: 1, effectiveWindowOpacity: 1, showBorder: true, isClickThrough: false
            )
            return PinSnapshot(image: image, originalText: nil, displayState: display)
        }
        let historyRoot = configURL.deletingLastPathComponent().appendingPathComponent(
            AirSnipConfig.defaultPinHistoryDirectoryName, isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: historyRoot, withIntermediateDirectories: true)
        } catch {
            fputs("FAIL: Could not prepare the pin zoom history fixture: \(error)\n", stderr)
            return false
        }
        let history = ClosedPinHistory(configURL: configURL)
        history.remember(Array(snapshots.reversed()), historyRoot: historyRoot)
        waitForPinOperation { history.finishPendingWrites(completion: $0) }

        return withPinRestoreFixture(image: image, configURL: configURL) { _, app, _ in
            let pins = app.pinManager
            for (example, snapshot) in zip(examples, snapshots) {
                waitForPinOperation { pins.restoreLastClosedPin(config: app.config, completion: $0) }
                guard let pin = pins.windows.last, pin.zoomScale == example.storedScale,
                      pin.window.frame.size == snapshot.displayState.frame.size else {
                    let restored = pins.windows.last
                    let actualScale = String(describing: restored?.zoomScale)
                    let actualSize = String(describing: restored?.window.frame.size)
                    fputs("FAIL: Expected restored pin at \(example.storedScale), \(snapshot.displayState.frame.size), got \(actualScale), \(actualSize)\n", stderr)
                    return false
                }
                let previousFrame = pin.window.frame
                let anchor = NSPoint(x: previousFrame.width / 2, y: previousFrame.height / 2)
                pin.adjustZoom(delta: example.direction, anchorInWindow: anchor)
                guard pin.zoomScale == 1, pin.window.frame.size == baseSize,
                      pin.window.contentView?.frame.size == baseSize else {
                    fputs("FAIL: Restored pin at \(example.storedScale) should stop at the original size, got \(pin.zoomScale)\n", stderr)
                    return false
                }
                guard abs(pin.window.frame.midX - previousFrame.midX) <= 1,
                      abs(pin.window.frame.midY - previousFrame.midY) <= 1 else {
                    fputs("FAIL: Zooming to 100% should keep the pin centered on the zoom anchor\n", stderr)
                    return false
                }
                pin.adjustZoom(delta: example.direction, anchorInWindow: .zero)
                guard Int((pin.zoomScale * 100).rounded()) == example.nextPercent else {
                    fputs("FAIL: Pin should keep zooming on the step after reaching 100%\n", stderr)
                    return false
                }
            }
            print("[pins] PASS: 历史贴图按原比例打开，双向停在真实 100%，下一格继续缩放")
            return true
        }
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
            updateConfigAndWait(app) { $0.pinHistoryLimit = 0 }
            app.pinManager.closeAll()
            waitForPinOperation(app.pinManager.finishHistoryWrites)
            app.settingsController = nil
            pasteboard.releaseGlobally()
        }
        return check(image, app, pasteboard)
    }

    @MainActor
    private static func runClipboardCopyBeforePinCloseCheck(
        image: CGImage, app: AirSnipAppController, pasteboard: NSPasteboard
    ) -> Bool {
        let text = "关图前复制的文字"
        OutputService.copyStringToClipboard(text, to: pasteboard)
        let copyRevision = pasteboard.changeCount
        let capture = app.makeSessionCoordinator(mode: .normalCapture)
        capture.finishWithPin(image: image, scale: 1, appKitOrigin: nil)
        guard let screenshot = app.pinManager.windows.last else { return false }
        screenshot.closeSelf()

        triggerPinAndWait(app)
        guard app.pinManager.count == 1, app.pinManager.windows.last?.originalText == text else {
            fputs("FAIL: F3 should pin unused text copied before closing a screenshot\n", stderr)
            return false
        }
        triggerPinAndWait(app)
        guard app.pinManager.count == 2, let restored = app.pinManager.windows.last,
              restored.originalText == nil, restored.cgImage.width == image.width else {
            fputs("FAIL: F3 should restore the closed screenshot after pinning the copied text\n", stderr)
            return false
        }
        triggerPinAndWait(app)
        guard app.pinManager.count == 2, pasteboard.changeCount == copyRevision,
              pasteboard.string(forType: .string) == text else {
            fputs("FAIL: F3 should leave the clipboard intact and stop restoring when history is exhausted\n", stderr)
            return false
        }
        print("[pins] PASS: 关图前尚未贴出的文字优先，接着恢复已关闭的截图")
        return true
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
        triggerPinAndWait(app, from: pasteboard)
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
            triggerPinAndWait(app, from: pasteboard)
            guard pins.count == index + 1, pins.windows.last?.cgImage.width == width else {
                fputs("FAIL: Pin or restore should open the newly copied image followed by the most recently closed pins (press \(index + 1))\n", stderr)
                return false
            }
        }
        triggerPinAndWait(app, from: pasteboard)
        guard pins.count == 3 else {
            fputs("FAIL: Pin or restore should leave the windows alone when history is exhausted\n", stderr)
            return false
        }

        pasteboard.clearContents()
        guard pasteboard.setData(png, forType: .png) else { return false }
        triggerPinAndWait(app, from: pasteboard)
        guard let recopied = pins.windows.last, pins.count == 4, recopied.cgImage.width == copied.width else {
            fputs("FAIL: Copying the same image again should let it be pinned again\n", stderr)
            return false
        }
        recopied.closeSelf()
        pasteboard.clearContents()
        triggerPinAndWait(app, from: pasteboard)
        guard pins.count == 4, pins.windows.last?.cgImage.width == copied.width else {
            fputs("FAIL: An empty clipboard should still allow a pin to be restored\n", stderr)
            return false
        }
        print("[pins] PASS: 新图优先（含图文共存）、最近关闭优先、主动再次复制与空剪贴板")

        app.updateConfig { $0.pinMaxCount = 4 }
        pasteboard.clearContents()
        guard pasteboard.setData(png, forType: .png) else { return false }
        triggerPinAndWait(app, from: pasteboard)
        guard pins.count == 4 else {
            fputs("FAIL: A new clipboard image should respect the visible pin limit\n", stderr)
            return false
        }
        app.updateConfig { $0.pinMaxCount = 5 }
        triggerPinAndWait(app, from: pasteboard)
        guard let retried = pins.windows.last, pins.count == 5, retried.cgImage.width == copied.width else {
            fputs("FAIL: A clipboard image blocked by the visible pin limit should remain available\n", stderr)
            return false
        }
        retried.closeSelf()
        app.updateConfig { $0.pinMaxCount = 4 }
        triggerPinAndWait(app, from: pasteboard)
        guard pins.count == 4 else {
            fputs("FAIL: Restoring a pin should respect the visible pin limit\n", stderr)
            return false
        }
        app.updateConfig { $0.pinMaxCount = 5 }
        triggerPinAndWait(app, from: pasteboard)
        guard pins.count == 5, pins.windows.last?.cgImage.width == copied.width else {
            fputs("FAIL: A closed pin blocked by the visible pin limit should remain available\n", stderr)
            return false
        }
        print("[pins] PASS: 达到同屏上限后仍可重试贴出新图和恢复贴图")
        return true
    }

    @MainActor
    private static func runUsedClipboardImageAfterRelaunchCheck(image: CGImage, configURL: URL) -> Bool {
        guard let copied = image.cropping(to: CGRect(x: 0, y: 0, width: 64, height: 48)),
              let png = try? ImageEncoder.encode(copied, format: .png, scale: 1) else { return false }
        let pasteboard = NSPasteboard.withUniqueName()
        var app = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard)
        app.updateConfig { $0.lastSaveDirectory = configURL.deletingLastPathComponent().path }
        defer {
            updateConfigAndWait(app) { $0.pinHistoryLimit = 0 }
            app.pinManager.closeAll()
            app.settingsController = nil
            pasteboard.releaseGlobally()
        }
        let item = NSPasteboardItem()
        guard item.setData(png, forType: .png), item.setString("Image caption", forType: .string),
              pasteboard.writeObjects([item]) else { return false }
        let copyRevision = pasteboard.changeCount
        triggerPinAndWait(app)
        guard let opened = app.pinManager.windows.last, opened.cgImage.width == copied.width,
              opened.originalText == nil, pasteboard.changeCount == copyRevision else {
            fputs("FAIL: F3 should prefer the clipboard image over the caption and leave the clipboard unchanged\n", stderr)
            return false
        }
        opened.closeSelf()
        for width in [96, 128] {
            guard let sample = image.cropping(to: CGRect(x: 0, y: 0, width: width, height: 48)),
                  app.pinManager.createPin(cgImage: sample, backingScale: 1, preferredScreenOriginAppKit: nil, config: app.config)
            else { return false }
            app.pinManager.windows.last?.closeSelf()
        }
        waitForPinOperation(app.pinManager.finishHistoryWrites)
        app.settingsController = nil
        app = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard)

        for (index, width) in [128, 96, copied.width].enumerated() {
            triggerPinAndWait(app)
            guard app.pinManager.count == index + 1, let restored = app.pinManager.windows.last,
                  restored.window.isVisible, restored.cgImage.width == width else {
                fputs("FAIL: A used clipboard image should restore closed pins in order after relaunch (press \(index + 1))\n", stderr)
                return false
            }
        }
        print("[pins] PASS: 重开后同一次图片复制按顺序恢复已关闭贴图")
        return true
    }

    @MainActor
    private static func runUsedClipboardCompressionAfterRelaunchCheck(image: CGImage, configURL: URL) -> Bool {
        guard let historyImage = image.cropping(to: CGRect(x: 0, y: 0, width: 96, height: 48)) else { return false }
        let pasteboard = NSPasteboard.withUniqueName()
        var app = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard)
        app.updateConfig { $0.lastSaveDirectory = configURL.deletingLastPathComponent().path }
        defer {
            updateConfigAndWait(app) { $0.pinHistoryLimit = 0 }
            app.pinManager.closeAll()
            app.settingsController = nil
            pasteboard.releaseGlobally()
        }
        OutputService.copyImageToClipboard(image, config: app.config, to: pasteboard)
        let originalRevision = pasteboard.changeCount
        guard let originalPNG = pasteboard.data(forType: .png) else { return false }
        triggerPinAndWait(app)
        guard let opened = app.pinManager.windows.last, opened.cgImage.width == image.width else { return false }
        opened.closeSelf()
        guard app.pinManager.createPin(cgImage: historyImage, backingScale: 1, preferredScreenOriginAppKit: nil, config: app.config)
        else { return false }
        app.pinManager.windows.last?.closeSelf()
        waitForPinOperation(app.pinManager.finishHistoryWrites)

        guard waitForPinHistoryWork({ pasteboard.changeCount != originalRevision }),
              let compressedPNG = pasteboard.data(forType: .png), compressedPNG.count < originalPNG.count else {
            fputs("FAIL: The clipboard compression fixture should rewrite the clipboard with a smaller PNG\n", stderr)
            return false
        }
        app.settingsController = nil
        app = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard)
        triggerPinAndWait(app)
        guard app.pinManager.count == 1, app.pinManager.windows.last?.cgImage.width == historyImage.width else {
            fputs("FAIL: After relaunch, compression of a used clipboard image should still let F3 restore history first\n", stderr)
            return false
        }
        triggerPinAndWait(app)
        guard app.pinManager.count == 2, app.pinManager.windows.last?.cgImage.width == image.width,
              let compressedItem = pasteboard.pasteboardItems?.first else { return false }

        // Clipboard managers can recopy the image along with all its pasteboard types.
        let recopied = NSPasteboardItem()
        for type in compressedItem.types {
            guard let data = compressedItem.data(forType: type), recopied.setData(data, forType: type) else { return false }
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([recopied]) else { return false }
        triggerPinAndWait(app)
        guard app.pinManager.count == 3, app.pinManager.windows.last?.cgImage.width == image.width else {
            fputs("FAIL: Recopied compressed clipboard data should allow a new pin\n", stderr)
            return false
        }
        print("[pins] PASS: 重开后后台压缩写回仍属同一次复制，主动复制相同内容可以再贴")
        return true
    }

    @MainActor
    private static func runUsedClipboardTextAfterRelaunchCheck(image: CGImage, configURL: URL) -> Bool {
        let pasteboard = NSPasteboard.withUniqueName()
        var app = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard)
        app.updateConfig {
            $0.lastSaveDirectory = configURL.deletingLastPathComponent().path
            $0.pinMaxCount = 1
        }
        defer {
            updateConfigAndWait(app) { $0.pinHistoryLimit = 0 }
            app.pinManager.closeAll()
            app.settingsController = nil
            pasteboard.releaseGlobally()
        }
        let text = "  贴图原文\n\tkeep this text  "
        OutputService.copyStringToClipboard(text, to: pasteboard)
        let copyRevision = pasteboard.changeCount
        triggerPinAndWait(app)
        guard let textPin = app.pinManager.windows.last, textPin.originalText == text,
              pasteboard.changeCount == copyRevision else {
            fputs("FAIL: F3 should pin the original text and leave the clipboard unchanged\n", stderr)
            return false
        }
        textPin.closeSelf()
        guard app.pinManager.createPin(cgImage: image, backingScale: 1, preferredScreenOriginAppKit: nil, config: app.config)
        else { return false }
        app.pinManager.windows.last?.closeSelf()
        waitForPinOperation(app.pinManager.finishHistoryWrites)
        app.settingsController = nil
        app = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard)
        triggerPinAndWait(app)
        guard app.pinManager.count == 1, let restored = app.pinManager.windows.last,
              restored.originalText == nil, restored.cgImage.width == image.width else {
            fputs("FAIL: After relaunch, a used text copy should let F3 restore history first\n", stderr)
            return false
        }

        OutputService.copyStringToClipboard(text, to: pasteboard)
        triggerPinAndWait(app)
        guard app.pinManager.count == 1 else {
            fputs("FAIL: Recopied text should still respect the on-screen pin limit\n", stderr)
            return false
        }
        restored.closeSelf()
        waitForPinOperation(app.pinManager.finishHistoryWrites)
        app.settingsController = nil
        app = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard)
        triggerPinAndWait(app)
        guard app.pinManager.count == 1, app.pinManager.windows.last?.originalText == text else {
            fputs("FAIL: After relaunch, a recopy previously blocked by the pin limit should still take priority over history\n", stderr)
            return false
        }
        print("[pins] PASS: 重开后已贴过的文字进入历史恢复，重新复制遇到同屏上限后仍可重试")
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
        OutputService.copyStringToClipboard(text, to: pasteboard)
        guard OutputService.readImageFromClipboard(from: pasteboard) == nil,
              let pinItem = statusMenu.item(withTitle: L10n.tr("贴图或恢复", "Pin or Restore")),
              let pinAction = pinItem.action,
              NSApp.sendAction(pinAction, to: pinItem.target, from: pinItem) else {
            fputs("FAIL: Pin or Restore should handle plain text through the status menu\n", stderr)
            return false
        }
        guard waitForPinHistoryWork({ pins.count == 1 }),
              let textPin = pins.windows.last, textPin !== older, textPin !== newer,
              textPin.window.isVisible, textPin.originalText == text, pasteboard.string(forType: .string) == text else {
            fputs("FAIL: New clipboard text should be pinned before restoring closed images\n", stderr)
            return false
        }

        for (index, frame) in [newer.window.frame, older.window.frame].enumerated() {
            triggerPinAndWait(app, from: pasteboard)
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
        triggerPinAndWait(app, from: pasteboard)
        guard pins.count == 3, let restored = pins.windows.last, restored.window.isVisible,
              restored.window.frame == textFrame, restored.window.alphaValue == textOpacity,
              PixelBufferRGBA(cgImage: restored.cgImage) == textImage else {
            fputs("FAIL: A restored text pin should keep its image, frame and opacity\n", stderr)
            return false
        }

        app.updateConfig { $0.pinMaxCount = 3 }
        OutputService.copyStringToClipboard(text, to: pasteboard)
        triggerPinAndWait(app, from: pasteboard)
        guard pins.count == 3 else { return false }
        restored.closeSelf()
        triggerPinAndWait(app, from: pasteboard)
        guard pins.count == 3, let recopied = pins.windows.last,
              recopied.window.alphaValue == 1, PixelBufferRGBA(cgImage: recopied.cgImage) == textImage else {
            fputs("FAIL: Recopied text should still make a new pin after reaching the visible pin limit\n", stderr)
            return false
        }

        let frames = pins.windows.reversed().map { $0.window.frame }
        pins.closeAll()
        for (index, frame) in frames.enumerated() {
            triggerPinAndWait(app, from: pasteboard)
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
            triggerPinAndWait(app, from: pasteboard)
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
        triggerPinAndWait(app)
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
        triggerPinAndWait(app)
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
        app.updateConfig {
            $0.smartPngCompression = false
            $0.pinAnnotationCoversDesktop = false
        }
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
        triggerPinAndWait(app)
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
        triggerPinAndWait(app)
        guard pins.count == 2 else {
            fputs("FAIL: Copying original text should allow it to be pinned as a new copy\n", stderr)
            return false
        }

        guard let edited = image.cropping(to: CGRect(x: 0, y: 0, width: 96, height: 64)) else { return false }
        let frame = pin.window.frame
        let editor = CaptureSessionCoordinator(config: app.config, mode: .pinAnnotation(pin))
        editor.startPinAnnotation()
        guard editor.hasVisibleWindows else { return false }
        editor.finishPrimaryAction(image: edited, scale: pin.backingScale)
        guard pin.window.isVisible, pin.window.frame == frame, verifyCopies(of: pin, image: edited) else {
            fputs("FAIL: Windowed annotation should keep the text pin in place and preserve both copy actions\n", stderr)
            return false
        }

        pin.closeSelf()
        pasteboard.clearContents()
        triggerPinAndWait(app)
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
                triggerPinAndWait(app, from: pasteboard)
                let state = states[index]
                guard let restored = pins.windows.last, pins.count == press + 1, restored.window.isVisible,
                      PixelBufferRGBA(cgImage: restored.cgImage) == PixelBufferRGBA(cgImage: state.image),
                      restored.window.frame == state.frame, restored.window.alphaValue == state.opacity else {
                    fputs("FAIL: Pin or restore should restore one pin in reverse insertion order with its original display state (press \(press + 1))\n", stderr)
                    return false
                }
            }
            triggerPinAndWait(app, from: pasteboard)
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
    private static func runBatchCloseDuringPinAnnotationCheck(image: CGImage) -> Bool {
        let config = AirSnipConfig()
        let pins = PinManager()
        defer { pins.closeAll() }
        guard let edited = image.cropping(to: CGRect(x: 0, y: 0, width: 96, height: 64)),
              pins.createPin(cgImage: image, backingScale: 1, preferredScreenOriginAppKit: nil, config: config),
              let pin = pins.windows.last else { return false }

        let editor = CaptureSessionCoordinator(config: config, mode: .pinAnnotation(pin))
        pins.onWillCloseAll = { [weak editor] in editor?.closeWithAllPins() }
        editor.startPinAnnotation()
        waitForPinOperation { pins.restoreLastClosedPin(config: config, completion: $0) }
        guard editor.hasVisibleWindows, pins.count == 1, !pin.window.isVisible else {
            fputs("FAIL: A pin hidden for annotation should still count as open\n", stderr)
            return false
        }

        pins.closeAll()
        let editorClosed = !editor.hasVisibleWindows
        editor.finishPrimaryAction(image: edited, scale: 1)
        guard editorClosed, pins.count == 0, !pin.window.isVisible else {
            fputs("FAIL: Close All should end full-screen pin annotation without reopening the pin\n", stderr)
            return false
        }

        waitForPinOperation { pins.restoreLastClosedPin(config: config, completion: $0) }
        guard let restored = pins.windows.last, pins.count == 1, restored.window.isVisible,
              PixelBufferRGBA(cgImage: restored.cgImage) == PixelBufferRGBA(cgImage: image) else {
            fputs("FAIL: Restoring a pin closed during annotation should show the image as it was at close time\n", stderr)
            return false
        }
        print("[pins] PASS: 关闭全部后结束标注，贴图保持关闭并可按关闭时的图像恢复")
        return true
    }

    @MainActor
    private static func runClosedPinHistoryLimitCheck(image: CGImage, configURL: URL) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard var now = calendar.date(from: DateComponents(year: 2024, month: 12, day: 20, hour: 12)),
              let later = calendar.date(from: DateComponents(year: 2025, month: 1, day: 6, hour: 12))
        else { return false }
        let pasteboard = NSPasteboard.withUniqueName()
        var app = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard) { now }
        let directory = configURL.deletingLastPathComponent()
        let root = directory.appendingPathComponent("iSnip Pin History", isDirectory: true)
        app.updateConfig {
            $0.lastSaveDirectory = directory.path
            $0.pinMaxCount = 25
        }
        defer {
            updateConfigAndWait(app) { $0.pinHistoryLimit = 0 }
            app.pinManager.closeAll()
            waitForPinOperation(app.pinManager.finishHistoryWrites)
            app.settingsController = nil
            pasteboard.releaseGlobally()
        }

        for width in 32...54 {
            guard let sample = image.cropping(to: CGRect(x: 0, y: 0, width: width, height: 32)),
                  app.pinManager.createPin(cgImage: sample, backingScale: 1, preferredScreenOriginAppKit: nil, config: app.config) else {
                return false
            }
            if width < 36 {
                app.pinManager.windows.last?.closeSelf()
            }
        }
        now = later
        app.pinManager.closeAll()
        waitForPinOperation(app.pinManager.finishHistoryWrites)
        guard pinHistoryPNGCount(at: root.appendingPathComponent("2024-12-20")) == 1,
              pinHistoryPNGCount(at: root.appendingPathComponent("2025-01-06")) == 19 else {
            fputs("FAIL: The default history limit should keep the newest 20 pins across close dates\n", stderr)
            return false
        }

        app.settingsController = nil
        app = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard)
        let pins = app.pinManager
        for width in (35...54).reversed() {
            triggerPinAndWait(app)
            guard pins.windows.last?.cgImage.width == width else {
                fputs("FAIL: Single and batch closes should share the most recent 20 history entries in order\n", stderr)
                return false
            }
        }
        triggerPinAndWait(app)
        guard pins.count == 20 else {
            fputs("FAIL: Pin history should discard the oldest pin after 20 closes\n", stderr)
            return false
        }
        print("[pins] PASS: 跨日期只保留最近 20 张，较早日期的保留记录仍可恢复")
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
    private static func waitForPinOperation(_ start: (@escaping () -> Void) -> Void) {
        var completed = false
        start { completed = true }
        precondition(waitForPinHistoryWork({ completed }), "Timed out waiting for pin history")
    }

    @MainActor
    private static func triggerPinAndWait(_ app: AirSnipAppController, from pasteboard: NSPasteboard? = nil) {
        waitForPinOperation { app.triggerPinOrRestore(from: pasteboard, completion: $0) }
    }

    @MainActor
    private static func updateConfigAndWait(_ app: AirSnipAppController, _ update: @escaping (inout AirSnipConfig) -> Void) {
        waitForPinOperation { app.updateConfig(update, completion: $0) }
    }

    @MainActor
    private static func restoreHistoryAndWait(_ history: ClosedPinHistory) -> PinSnapshot? {
        var snapshot: PinSnapshot?
        waitForPinOperation { done in
            history.restoreLast(if: { _ in true }, accept: { restored in
                snapshot = restored
                return true
            }, completion: { restored, _ in
                if !restored { snapshot = nil }
                done()
            })
        }
        return snapshot
    }

    @MainActor
    private static func runUnavailablePinHistoryCheck(image: CGImage, configURL: URL) throws -> Bool {
        let files = FileManager.default
        let base = configURL.deletingLastPathComponent()
        let previous = base.appendingPathComponent("previous-history", isDirectory: true)
        let current = base.appendingPathComponent("current-history", isDirectory: true)
        let disconnected = base.appendingPathComponent("disconnected-history", isDirectory: true)
        let disconnectedCurrent = base.appendingPathComponent("disconnected-current-history", isDirectory: true)
        try files.createDirectory(at: previous, withIntermediateDirectories: true)
        try files.createDirectory(at: current, withIntermediateDirectories: false)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let closeTime = calendar.date(from: DateComponents(year: 2025, month: 1, day: 2, hour: 12)) else { return false }
        let previousDay = previous.appendingPathComponent("2025-01-02", isDirectory: true)
        let currentDay = current.appendingPathComponent("2025-01-02", isDirectory: true)
        let pasteboard = NSPasteboard.withUniqueName()
        var app = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard) { closeTime }
        defer {
            updateConfigAndWait(app) { $0.pinHistoryLimit = 0 }
            app.pinManager.closeAll()
            waitForPinOperation(app.pinManager.finishHistoryWrites)
            app.settingsController = nil
            pasteboard.releaseGlobally()
        }

        func closePins(_ widths: [Int], in directory: URL) -> Bool {
            app.updateConfig { $0.pinHistoryDirectory = directory.path }
            for width in widths {
                guard let sample = image.cropping(to: CGRect(x: 0, y: 0, width: width, height: 32)),
                      app.pinManager.createPin(cgImage: sample, backingScale: 1, preferredScreenOriginAppKit: nil,
                                               config: app.config, originalText: "Pin \(width)") else { return false }
            }
            app.pinManager.closeAll()
            waitForPinOperation(app.pinManager.finishHistoryWrites)
            return true
        }

        updateConfigAndWait(app) { $0.pinHistoryLimit = 3 }
        guard closePins([32], in: previous), closePins([40], in: current), closePins([48, 56], in: previous),
              pinHistoryPNGCount(at: previousDay) == 2, pinHistoryPNGCount(at: current) == 1 else {
            fputs("FAIL: History directories should share one limit and remove the oldest pin first\n", stderr)
            return false
        }
        try "Keep these notes".write(to: previousDay.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try Data().write(to: previousDay.appendingPathComponent("reference.png"))
        app.updateConfig { $0.pinHistoryDirectory = current.path }
        try files.moveItem(at: previous, to: disconnected)
        try files.createDirectory(at: previous, withIntermediateDirectories: false)

        app.settingsController = nil
        app = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard) { closeTime }
        triggerPinAndWait(app)
        guard app.pinManager.count == 1, app.pinManager.windows.last?.cgImage.width == 40 else {
            fputs("FAIL: After reopening, F3 should skip newer pins on an unavailable path and restore a readable pin\n", stderr)
            return false
        }
        triggerPinAndWait(app)
        guard app.pinManager.count == 1 else { return false }
        updateConfigAndWait(app) { $0.pinHistoryLimit = 1 }
        try files.removeItem(at: previous)
        try files.moveItem(at: disconnected, to: previous)

        triggerPinAndWait(app)
        guard app.pinManager.count == 2, app.pinManager.windows.last?.cgImage.width == 56,
              try Set(files.contentsOfDirectory(atPath: previousDay.path)) == ["notes.txt", "reference.png"] else {
            fputs("FAIL: After reconnecting, F3 should restore the newest retained pin and clean only consumed or evicted files\n", stderr)
            return false
        }
        triggerPinAndWait(app)
        guard app.pinManager.count == 2 else { return false }
        print("[pins] PASS: 多目录共用上限，F3 跳过离线目录，接回后继续恢复并只清理对应文件")

        updateConfigAndWait(app) {
            $0.pinHistoryLimit = 2
            $0.pinHistoryDirectory = previous.path
        }
        app.pinManager.windows.last?.closeSelf()
        app.updateConfig { $0.pinHistoryDirectory = current.path }
        app.pinManager.closeAll()
        waitForPinOperation(app.pinManager.finishHistoryWrites)
        guard pinHistoryPNGCount(at: previousDay) == 2, pinHistoryPNGCount(at: currentDay) == 1,
              let currentImage = try files.contentsOfDirectory(at: currentDay, includingPropertiesForKeys: nil)
                  .first(where: { $0.pathExtension == "png" }) else { return false }
        try "Keep these notes".write(to: currentDay.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try files.moveItem(at: previous, to: disconnected)
        try files.moveItem(at: current, to: disconnectedCurrent)
        try files.createDirectory(at: currentDay, withIntermediateDirectories: true)
        let replacementData = Data("Keep this file on the replacement directory".utf8)
        try replacementData.write(to: currentImage)
        updateConfigAndWait(app) { $0.pinHistoryLimit = 0 }

        app.settingsController = nil
        app = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard)
        waitForPinOperation(app.pinManager.finishHistoryWrites)
        guard (try? Data(contentsOf: currentImage)) == replacementData else {
            fputs("FAIL: Deferred cleanup should leave files in a replacement history directory intact\n", stderr)
            return false
        }
        try files.moveItem(at: disconnected, to: previous)
        triggerPinAndWait(app)
        guard app.pinManager.count == 0,
              try Set(files.contentsOfDirectory(atPath: previousDay.path)) == ["notes.txt", "reference.png"] else {
            fputs("FAIL: Pending deletion should survive a restart and finish when a cleared history directory returns\n", stderr)
            return false
        }
        try files.removeItem(at: current)
        try files.moveItem(at: disconnectedCurrent, to: current)
        let workspace = NSWorkspace.shared
        workspace.notificationCenter.post(name: NSWorkspace.didMountNotification, object: workspace)
        guard waitForPinHistoryWork({ (try? files.contentsOfDirectory(atPath: currentDay.path)) == ["notes.txt"] }) else {
            fputs("FAIL: Mounting an old history volume should finish deferred cleanup even when history is disabled\n", stderr)
            return false
        }
        print("[pins] PASS: 离线清空历史后重开，F3 或磁盘重新挂载会清理待删除的文件")
        return true
    }

    @MainActor
    private static func runDiskPinHistoryCheck(image: CGImage, configURL: URL) -> Bool {
        let files = FileManager.default
        let base = configURL.deletingLastPathComponent()
        let defaultDirectory = base.appendingPathComponent("iSnip Pin History", isDirectory: true)
        let legacyParent = base.appendingPathComponent("previously-selected", isDirectory: true)
        let legacyRoot = legacyParent.appendingPathComponent("iSnip Pin History", isDirectory: true)
        let oldSession = defaultDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let otherDirectory = defaultDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacyRegistry = configURL.deletingPathExtension().appendingPathExtension("pin-history-sessions.json")
        do {
            try files.createDirectory(at: oldSession, withIntermediateDirectories: true)
            try files.createDirectory(at: otherDirectory, withIntermediateDirectories: false)
            try files.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
            try JSONEncoder().encode([oldSession]).write(to: legacyRegistry)
            try JSONEncoder().encode([
                "lastSaveDirectory": base.path,
                "pinHistoryParentDirectory": legacyParent.path,
            ]).write(to: configURL)
        } catch {
            fputs("FAIL: Could not prepare the legacy history fixture\n", stderr)
            return false
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let closeTime = calendar.date(from: DateComponents(year: 2025, month: 1, day: 2, hour: 12)) else { return false }
        let closeDay = defaultDirectory.appendingPathComponent("2025-01-02", isDirectory: true)
        let pasteboard = NSPasteboard.withUniqueName()
        var app = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard) { closeTime }
        var pins = app.pinManager
        defer {
            updateConfigAndWait(app) { $0.pinHistoryLimit = 0 }
            pins.closeAll()
            waitForPinOperation(pins.finishHistoryWrites)
            app.settingsController = nil
            pasteboard.releaseGlobally()
        }
        waitForPinOperation(pins.finishHistoryWrites)
        guard !files.fileExists(atPath: oldSession.path), files.fileExists(atPath: otherDirectory.path) else {
            fputs("FAIL: Legacy cleanup should remove only the registered session directories\n", stderr)
            return false
        }
        guard OutputService.pinHistoryRootURL(for: app.config).path == legacyRoot.path else {
            fputs("FAIL: The old directory setting should keep the history location users used to open\n", stderr)
            return false
        }
        app.updateConfig { $0.pinHistoryDirectory = nil }
        guard OutputService.pinHistoryRootURL(for: app.config).path == defaultDirectory.path else {
            fputs("FAIL: Restoring defaults should use iSnip Pin History under the screenshot save directory\n", stderr)
            return false
        }
        let customDirectory = base.appendingPathComponent("custom-history", isDirectory: true)
        let customDay = customDirectory.appendingPathComponent("2025-01-02", isDirectory: true)
        guard (try? files.createDirectory(at: customDirectory, withIntermediateDirectories: false)) != nil else { return false }

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
                  pins.createPin(cgImage: image, backingScale: 2, preferredScreenOriginAppKit: nil, config: app.config,
                                 originalText: text),
                  let pin = pins.windows.last else { return false }
            pin.updateImage(sample)
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
        guard let saved = try? files.contentsOfDirectory(at: closeDay, includingPropertiesForKeys: nil),
              let png = saved.first(where: { $0.pathExtension == "png" }),
              let original = saved.first(where: { $0.pathExtension == "txt" }),
              saved.count == 2,
              original.lastPathComponent == png.deletingPathExtension().lastPathComponent + ".txt",
              (try? String(contentsOf: original, encoding: .utf8)) == text else {
            fputs("FAIL: A text pin should save paired PNG and TXT files directly inside its close day\n", stderr)
            return false
        }
        let userFile = closeDay.appendingPathComponent("notes.txt")
        guard (try? "Keep these notes".write(to: userFile, atomically: true, encoding: .utf8)) != nil else { return false }

        app.updateConfig { $0.pinHistoryDirectory = customDirectory.path }
        guard OutputService.pinHistoryRootURL(for: app.config).path == customDirectory.path else {
            fputs("FAIL: Pin history settings should open the exact directory selected by the user\n", stderr)
            return false
        }
        weak var secondImage: CGImage?
        let closedSecond = autoreleasepool {
            guard let sample = image.cropping(to: CGRect(x: 0, y: 0, width: 64, height: 48)),
                  pins.createPin(cgImage: sample, backingScale: 1, preferredScreenOriginAppKit: nil, config: app.config),
                  let pin = pins.windows.last else { return false }
            secondImage = sample
            pin.closeSelf()
            return pins.count == 0
        }
        guard closedSecond, waitForPinHistoryWork({ secondImage == nil && pinHistoryPNGCount(at: customDay) == 1 }),
              pinHistoryPNGCount(at: defaultDirectory) == 1 else {
            fputs("FAIL: Changing the history directory should apply to the next close and retain existing history\n", stderr)
            return false
        }

        let invalidDirectory = base.appendingPathComponent("invalid-history")
        guard (try? Data().write(to: invalidDirectory)) != nil else { return false }
        app.updateConfig { $0.pinHistoryDirectory = invalidDirectory.path }
        guard pins.createPin(cgImage: image, backingScale: 1, preferredScreenOriginAppKit: nil, config: app.config) else { return false }
        pins.windows.last?.closeSelf()
        guard pins.count == 0 else { return false }
        app.updateConfig { $0.pinHistoryDirectory = customDirectory.path }

        // Rebuild the app after saving without going through the normal quit callback.
        app.settingsController = nil
        app = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard)
        pins = app.pinManager
        guard OutputService.pinHistoryRootURL(for: app.config).path == customDirectory.path else {
            fputs("FAIL: Reopening should preserve the exact selected pin history directory\n", stderr)
            return false
        }
        triggerPinAndWait(app, from: pasteboard)
        guard pins.count == 1, pins.windows.last?.cgImage.width == 64, pinHistoryPNGCount(at: customDirectory) == 0 else {
            fputs("FAIL: After reopening, F3 should recover the most recently saved pin and consume its file\n", stderr)
            return false
        }
        triggerPinAndWait(app, from: pasteboard)
        guard pins.count == 2, let restored = pins.windows.last,
              restored.cgImage.colorSpace?.isWideGamutRGB == true, PixelBufferRGBA(cgImage: restored.cgImage) == expectedImage,
              restored.window.frame == expectedFrame, restored.backingScale == 2, restored.zoomScale == expectedZoom,
              restored.opacity == expectedOpacity, restored.window.alphaValue == 0.82,
              restored.window.ignoresMouseEvents, !restored.showBorder,
              (try? files.contentsOfDirectory(atPath: closeDay.path)) == ["notes.txt"] else {
            fputs("FAIL: Disk restoration should preserve image color, alpha and display state and remove the consumed file\n", stderr)
            return false
        }
        restored.copyOriginalText()
        guard pasteboard.string(forType: .string) == text else {
            fputs("FAIL: Disk restoration should preserve the complete original text\n", stderr)
            return false
        }
        print("[pins] PASS: 旧路径迁移、自选目录和恢复默认，重开后可跨目录恢复图像、状态和原文")
        return true
    }

    @MainActor
    private static func openFixturePin(
        image: CGImage, width: Int, app: AirSnipAppController, originalText: String? = nil
    ) -> PinWindowController? {
        guard let sample = image.cropping(to: CGRect(x: 0, y: 0, width: width, height: 32)),
              app.pinManager.createPin(
                  cgImage: sample, backingScale: 1, preferredScreenOriginAppKit: nil,
                  config: app.config, originalText: originalText
              ) else { return nil }
        return app.pinManager.windows.last
    }

    @MainActor
    private static func runPinHistoryQuitCheck(image: CGImage, configURL: URL) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard var now = calendar.date(from: DateComponents(year: 2024, month: 12, day: 30, hour: 12)),
              let batchTime = calendar.date(from: DateComponents(year: 2024, month: 12, day: 31, hour: 23, minute: 59, second: 59)),
              let quitTime = calendar.date(from: DateComponents(year: 2025, month: 1, day: 2, hour: 23, minute: 59, second: 59))
        else { return false }

        let pasteboard = NSPasteboard.withUniqueName()
        var app = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard) {
            let closeTime = now
            now.addTimeInterval(2)
            return closeTime
        }
        let directory = configURL.deletingLastPathComponent()
        let root = directory.appendingPathComponent("iSnip Pin History", isDirectory: true)
        updateConfigAndWait(app) {
            $0.lastSaveDirectory = directory.path
            $0.pinHistoryLimit = 5
        }
        defer {
            updateConfigAndWait(app) { $0.pinHistoryLimit = 0 }
            app.pinManager.closeAll()
            waitForPinOperation(app.pinManager.finishHistoryWrites)
            app.settingsController = nil
            pasteboard.releaseGlobally()
        }

        guard let oldest = openFixturePin(image: image, width: 35, app: app),
              let immediatelyRestored = openFixturePin(image: image, width: 40, app: app) else { return false }
        oldest.closeSelf()
        immediatelyRestored.closeSelf()
        triggerPinAndWait(app)
        guard app.pinManager.count == 1, app.pinManager.windows.last?.cgImage.width == 40 else {
            fputs("FAIL: F3 should restore a pin even when closing and restoring immediately\n", stderr)
            return false
        }

        now = batchTime
        guard openFixturePin(image: image, width: 50, app: app) != nil else { return false }
        app.pinManager.closeAll()
        let originalText = "  Quit with this text\n\tstill open  "
        guard let manuallyClosed = openFixturePin(image: image, width: 60, app: app),
              openFixturePin(image: image, width: 70, app: app) != nil,
              let newest = openFixturePin(image: image, width: 80, app: app, originalText: originalText) else { return false }
        newest.adjustZoom(delta: 1, anchorInWindow: NSPoint(x: 24, y: 16))
        newest.adjustOpacity(delta: -1)
        newest.window.setFrameOrigin(NSPoint(x: newest.window.frame.minX + 24, y: newest.window.frame.minY + 16))
        let expectedFrame = newest.window.frame
        let expectedZoom = newest.zoomScale
        let expectedOpacity = newest.window.alphaValue
        let expectedImage = PixelBufferRGBA(cgImage: newest.cgImage)
        manuallyClosed.closeSelf()
        now = quitTime
        waitForPinOperation(app.pinManager.saveOpenPinsOnQuit)

        guard pinHistoryPNGCount(at: root.appendingPathComponent("2025-01-02")) == 2,
              pinHistoryPNGCount(at: root.appendingPathComponent("2025-01-03")) == 0 else {
            fputs("FAIL: Normal quit should save all open pins on the day the quit started\n", stderr)
            return false
        }
        guard pinHistoryPNGCount(at: root.appendingPathComponent("2024-12-30")) == 0,
              pinHistoryPNGCount(at: root.appendingPathComponent("2024-12-31")) == 2,
              pinHistoryPNGCount(at: root.appendingPathComponent("2025-01-01")) == 1 else {
            fputs("FAIL: Normal quit should finish queued writes on their close day and apply the global history limit\n", stderr)
            return false
        }

        app.settingsController = nil
        app = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard)
        for (index, width) in [80, 70, 60, 50, 40].enumerated() {
            triggerPinAndWait(app)
            guard app.pinManager.count == index + 1, app.pinManager.windows.last?.cgImage.width == width else {
                fputs("FAIL: Reopening after normal quit should recover pins newest first across dates\n", stderr)
                return false
            }
        }
        triggerPinAndWait(app)
        guard app.pinManager.count == 5, pinHistoryPNGCount(at: root) == 0 else {
            fputs("FAIL: Restored pins should disappear from history on disk\n", stderr)
            return false
        }
        guard let restored = app.pinManager.windows.first, restored.window.isVisible,
              PixelBufferRGBA(cgImage: restored.cgImage) == expectedImage,
              restored.window.frame == expectedFrame, restored.zoomScale == expectedZoom,
              restored.window.alphaValue == expectedOpacity else {
            fputs("FAIL: Reopening should restore the open pin with its image and display state at quit\n", stderr)
            return false
        }
        restored.copyOriginalText()
        guard pasteboard.string(forType: .string) == originalText else {
            fputs("FAIL: Reopening should preserve the original text of a pin that was open at quit\n", stderr)
            return false
        }

        updateConfigAndWait(app) { $0.pinHistoryLimit = 0 }
        waitForPinOperation(app.pinManager.saveOpenPinsOnQuit)
        guard pinHistoryPNGCount(at: root) == 0 else {
            fputs("FAIL: Quitting should leave pin history empty when its limit is zero\n", stderr)
            return false
        }
        print("[pins] PASS: 退出保存未关闭贴图，重开按顺序恢复图像、状态和原文，并遵守全局上限")
        return true
    }

    @MainActor
    private static func runInterruptedPinHistoryWriteCheck(image: CGImage, configURL: URL) throws -> Bool {
        let pasteboard = NSPasteboard.withUniqueName()
        var app = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard)
        app.updateConfig { $0.lastSaveDirectory = configURL.deletingLastPathComponent().path }
        defer {
            updateConfigAndWait(app) { $0.pinHistoryLimit = 0 }
            app.pinManager.closeAll()
            waitForPinOperation(app.pinManager.finishHistoryWrites)
            app.settingsController = nil
            pasteboard.releaseGlobally()
        }
        let root = OutputService.pinHistoryRootURL(for: app.config)
        let manifest = ClosedPinHistory.manifestURL(for: configURL)

        guard let first = openFixturePin(image: image, width: 48, app: app) else { return false }
        first.closeSelf()
        waitForPinOperation(app.pinManager.finishHistoryWrites)
        guard pinHistoryPNGCount(at: root) == 1,
              let second = openFixturePin(image: image, width: 64, app: app, originalText: "Interrupted write") else {
            fputs("FAIL: Could not stage a second pin after saving the first pin\n", stderr)
            return false
        }
        second.closeSelf()
        waitForPinOperation(app.pinManager.finishHistoryWrites)
        let files = FileManager.default
        let items = files.enumerator(at: root, includingPropertiesForKeys: nil)
        guard pinHistoryPNGCount(at: root) == 2,
              var interrupted = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any],
              var records = interrupted["records"] as? [[String: Any]], records.count == 2,
              let pendingFiles = records.removeLast()["files"],
              let textFile = items?.allObjects.compactMap({ $0 as? URL }).first(where: { $0.pathExtension == "txt" }) else {
            fputs("FAIL: Could not prepare the interrupted pin's PNG and text files\n", stderr)
            return false
        }
        // Recreate the manifest and partial files left by an interruption before the second pin was published.
        interrupted["records"] = records
        interrupted["filesToRemove"] = [pendingFiles]
        try files.removeItem(at: textFile)
        try JSONSerialization.data(withJSONObject: interrupted).write(to: manifest, options: .atomic)

        app.settingsController = nil
        app = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard)
        waitForPinOperation(app.pinManager.finishHistoryWrites)
        guard pinHistoryPNGCount(at: root) == 1 else {
            fputs("FAIL: Reopening should clean up the interrupted pin and preserve the fully saved pin\n", stderr)
            return false
        }
        triggerPinAndWait(app)
        triggerPinAndWait(app)
        guard app.pinManager.count == 1, app.pinManager.windows.last?.cgImage.width == 48,
              pinHistoryPNGCount(at: root) == 0 else {
            fputs("FAIL: F3 should only restore the fully saved pin after an interrupted write\n", stderr)
            return false
        }
        print("[pins] PASS: 写盘中断后重开会清理未保存完成的文件，已保存贴图仍可恢复")
        return true
    }

    @MainActor
    private static func runPinHistoryLimitRecoveryCheck(image: CGImage, configURL: URL) throws -> Bool {
        let pasteboard = NSPasteboard.withUniqueName()
        let directory = configURL.deletingLastPathComponent()
        var app = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard)
        updateConfigAndWait(app) {
            $0.lastSaveDirectory = directory.path
            $0.pinHistoryLimit = 2
        }
        defer {
            updateConfigAndWait(app) { $0.pinHistoryLimit = 0 }
            app.pinManager.closeAll()
            waitForPinOperation(app.pinManager.finishHistoryWrites)
            app.settingsController = nil
            pasteboard.releaseGlobally()
        }
        let root = OutputService.pinHistoryRootURL(for: app.config)
        let manifest = ClosedPinHistory.manifestURL(for: configURL)
        let files = FileManager.default

        func reopenWithTrimBlocked(limit: Int) throws {
            // The setting was saved before interruption, but the history was not trimmed.
            var savedConfig = app.config
            savedConfig.pinHistoryLimit = limit
            try savedConfig.save(to: configURL)
            try files.setAttributes([.immutable: true], ofItemAtPath: manifest.path)
            app.settingsController = nil
            app = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard)
            waitForPinOperation(app.pinManager.finishHistoryWrites)
            try files.setAttributes([.immutable: false], ofItemAtPath: manifest.path)
        }

        guard openFixturePin(image: image, width: 48, app: app) != nil,
              openFixturePin(image: image, width: 64, app: app) != nil else { return false }
        app.pinManager.closeAll()
        waitForPinOperation(app.pinManager.finishHistoryWrites)
        try reopenWithTrimBlocked(limit: 1)
        guard app.config.pinHistoryLimit == 1, pinHistoryPNGCount(at: root) == 2 else {
            fputs("FAIL: Could not reopen with a saved limit and blocked history trim\n", stderr)
            return false
        }
        triggerPinAndWait(app)
        triggerPinAndWait(app)
        guard app.pinManager.count == 1, app.pinManager.windows.last?.cgImage.width == 64,
              pinHistoryPNGCount(at: root) == 0 else {
            fputs("FAIL: F3 should enforce the saved limit when storage is writable again\n", stderr)
            return false
        }

        updateConfigAndWait(app) { $0.pinHistoryLimit = 2 }
        guard openFixturePin(image: image, width: 80, app: app) != nil else { return false }
        app.pinManager.closeAll()
        waitForPinOperation(app.pinManager.finishHistoryWrites)
        try reopenWithTrimBlocked(limit: 0)
        guard app.config.pinHistoryLimit == 0, pinHistoryPNGCount(at: root) == 2 else {
            fputs("FAIL: Could not reopen with history disabled and blocked history trim\n", stderr)
            return false
        }
        waitForPinOperation(app.pinManager.saveOpenPinsOnQuit)
        guard pinHistoryPNGCount(at: root) == 0 else {
            fputs("FAIL: Quitting should retry a blocked history clear when storage is writable again\n", stderr)
            return false
        }
        print("[pins] PASS: 启动时无法裁剪历史，恢复可写后按 F3 和正常退出会执行已保存的上限")
        return true
    }

    @MainActor
    private static func runFailedPinHistoryWriteCheck(image: CGImage, directory: URL) throws -> Bool {
        let files = FileManager.default
        let history = ClosedPinHistory(configURL: nil, limit: 2)
        defer {
            waitForPinOperation { done in history.updateLimit(to: 0, savingConfig: { _ in }, completion: { _ in done() }) }
            waitForPinOperation { history.finishPendingWrites(completion: $0) }
        }
        let workingRoot = directory.appendingPathComponent("write-history", isDirectory: true)
        let failingRoot = directory.appendingPathComponent("unavailable-history", isDirectory: true)
        let closedAt = Date()
        let displayState = PinDisplayState(
            frame: CGRect(x: 0, y: 0, width: 32, height: 32), baseSize: CGSize(width: 32, height: 32),
            backingScale: 1, zoomScale: 1, preferredOpacity: 1, effectiveWindowOpacity: 1,
            showBorder: true, isClickThrough: false
        )
        func snapshot(_ image: CGImage, text: String) -> PinSnapshot {
            PinSnapshot(image: image, originalText: text, displayState: displayState)
        }

        // Replace the expected day directory with a file so the actual write fails.
        weak var seedImage: CGImage?
        let seeded = autoreleasepool {
            guard let sample = image.cropping(to: displayState.frame) else { return false }
            seedImage = sample
            history.remember([snapshot(sample, text: "seed")], historyRoot: failingRoot, closedAt: closedAt)
            return true
        }
        guard seeded, waitForPinHistoryWork({ seedImage == nil }),
              restoreHistoryAndWait(history)?.originalText == "seed",
              let dayDirectory = try files.contentsOfDirectory(
                  at: failingRoot, includingPropertiesForKeys: nil
              ).first else {
            fputs("FAIL: Could not prepare a writable day directory for the pin history failure fixture\n", stderr)
            return false
        }
        try files.removeItem(at: dayDirectory)
        try Data().write(to: URL(fileURLWithPath: dayDirectory.path, isDirectory: false))

        var failures = 0
        history.onFailure = { _ in failures += 1 }
        history.remember(
            [snapshot(image, text: "oldest"), snapshot(image, text: "newest")],
            historyRoot: workingRoot, closedAt: closedAt
        )
        history.remember([snapshot(image, text: "failed")], historyRoot: failingRoot, closedAt: closedAt)
        guard waitForPinHistoryWork({ failures > 0 }), failures == 1,
              restoreHistoryAndWait(history)?.originalText == "newest", restoreHistoryAndWait(history) == nil,
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
        let directory = app.configURL.deletingLastPathComponent().appendingPathComponent("iSnip Pin History", isDirectory: true)

        func openPins(widths: ClosedRange<Int>) -> Bool {
            for width in widths {
                guard let sample = image.cropping(to: CGRect(x: 0, y: 0, width: width, height: 32)),
                      pins.createPin(cgImage: sample, backingScale: 1, preferredScreenOriginAppKit: nil, config: app.config) else { return false }
            }
            return true
        }

        updateConfigAndWait(app) { $0.pinHistoryLimit = 10 }
        guard openPins(widths: 32...41) else { return false }
        pins.closeAll()
        waitForPinOperation(pins.finishHistoryWrites)
        updateConfigAndWait(app) { $0.pinHistoryLimit = 5 }
        updateConfigAndWait(app) { $0.pinHistoryLimit = 10 }
        guard pinHistoryPNGCount(at: directory) == 5 else {
            fputs("FAIL: Shrinking history should remove the oldest saved files\n", stderr)
            return false
        }

        for width in [41, 40, 39, 38, 37] {
            triggerPinAndWait(app, from: pasteboard)
            guard pins.windows.last?.cgImage.width == width else {
                fputs("FAIL: Reducing pin history should keep the most recently closed pins\n", stderr)
                return false
            }
        }
        triggerPinAndWait(app, from: pasteboard)
        guard pins.count == 5 else {
            fputs("FAIL: Increasing the pin history limit should not bring back previously trimmed pins\n", stderr)
            return false
        }
        print("[pins] PASS: 调小可恢复贴图数后立即只保留最近关闭的贴图")

        pins.closeAll()
        waitForPinOperation(pins.finishHistoryWrites)
        func disableHistoryWithWriteBlocked(at url: URL) throws {
            let files = FileManager.default
            let backup = url.appendingPathExtension("fixture-backup")
            try files.moveItem(at: url, to: backup)
            try files.createDirectory(at: url, withIntermediateDirectories: false)
            updateConfigAndWait(app) { $0.pinHistoryLimit = 0 }
            try files.removeItem(at: url)
            try files.moveItem(at: backup, to: url)
        }

        do {
            try disableHistoryWithWriteBlocked(at: app.configURL)
        } catch {
            fputs("FAIL: Could not simulate a settings write failure while disabling pin history: \(error)\n", stderr)
            return false
        }
        guard app.config.pinHistoryLimit == 10, AirSnipConfig.load(from: app.configURL).pinHistoryLimit == 10,
              pinHistoryPNGCount(at: directory) == 5 else {
            fputs("FAIL: A failed settings save should keep the previous limit and leave saved pins intact\n", stderr)
            return false
        }
        print("[pins] PASS: 设置保存失败时保留原上限和贴图历史")

        do {
            let manifest = ClosedPinHistory.manifestURL(for: app.configURL)
            try disableHistoryWithWriteBlocked(at: manifest)
        } catch {
            fputs("FAIL: Could not simulate a manifest write failure while disabling pin history: \(error)\n", stderr)
            return false
        }
        guard app.config.pinHistoryLimit == 10, AirSnipConfig.load(from: app.configURL).pinHistoryLimit == 10,
              pinHistoryPNGCount(at: directory) == 5 else {
            fputs("FAIL: A failed history clear should preserve the previously applied limit and saved pins\n", stderr)
            return false
        }
        print("[pins] PASS: 清空写入失败时保留原上限和历史，可再次停用")

        updateConfigAndWait(app) { $0.pinHistoryLimit = 0 }
        triggerPinAndWait(app, from: pasteboard)
        guard app.config.pinHistoryLimit == 0, pins.count == 0, pinHistoryPNGCount(at: directory) == 0 else {
            fputs("FAIL: Disabling pin history should immediately clear it\n", stderr)
            return false
        }

        guard openPins(widths: 32...33) else { return false }
        pins.windows.last?.closeSelf()
        triggerPinAndWait(app, from: pasteboard)
        guard pins.count == 1 else {
            fputs("FAIL: Closing a pin with history disabled should leave nothing to restore\n", stderr)
            return false
        }
        pins.closeAll()
        triggerPinAndWait(app, from: pasteboard)
        guard pins.count == 0 else {
            fputs("FAIL: Close All should also honor disabled pin history\n", stderr)
            return false
        }

        updateConfigAndWait(app) { $0.pinHistoryLimit = 10 }
        guard openPins(widths: 32...43) else { return false }
        pins.closeAll()
        for _ in 0..<11 { triggerPinAndWait(app, from: pasteboard) }
        guard pins.count == 10, pins.windows.last?.cgImage.width == 34 else {
            fputs("FAIL: Re-enabling pin history should retain future closes up to the new limit\n", stderr)
            return false
        }

        updateConfigAndWait(app) { $0.pinHistoryLimit = 0 }
        pins.closeAll()
        updateConfigAndWait(app) { $0.pinHistoryLimit = 10 }
        waitForPinOperation(pins.finishHistoryWrites)
        let restarted = AirSnipAppController(configURL: app.configURL, pinPasteboard: pasteboard)
        defer { restarted.settingsController = nil }
        triggerPinAndWait(restarted, from: pasteboard)
        guard restarted.config.pinHistoryLimit == 10, restarted.pinManager.count == 0 else {
            fputs("FAIL: Clearing history should also persist across launches after re-enabling it\n", stderr)
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
        defer {
            updateConfigAndWait(app) { $0.pinHistoryLimit = 0 }
            pins.closeAll()
            waitForPinOperation(pins.finishHistoryWrites)
            app.settingsController = nil
        }
        guard pins.createPin(cgImage: image, backingScale: 1, preferredScreenOriginAppKit: nil, config: app.config),
              let pin = pins.windows.last else { return false }
        let previousWindows = Set(NSApp.windows.map(\.windowNumber))
        pin.requestAnnotation()
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

        updateConfigAndWait(app) {
            $0.pinHistoryLimit = 5
            $0.pinHistoryDirectory = directory.path
            $0.pinBorder = false
        }
        pressKey(kVK_ANSI_2, "2")
        let savedConfig = AirSnipConfig.load(from: configURL)
        guard app.config.pinHistoryLimit == 5, app.config.lastTool == .arrow,
              app.config.pinHistoryDirectory == directory.path, savedConfig.pinHistoryDirectory == directory.path,
              savedConfig.pinHistoryLimit == 5, savedConfig.lastTool == .arrow,
              !app.config.pinBorder, !savedConfig.pinBorder else {
            fputs("FAIL: Tool changes from an older capture session should preserve current pin history and border settings\n", stderr)
            return false
        }

        let quickSaveDirectory = directory.appendingPathComponent("quick-save", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: quickSaveDirectory, withIntermediateDirectories: false)) != nil else {
            return false
        }
        updateConfigAndWait(app) {
            $0.pinHistoryLimit = 10
            $0.pinHistoryDirectory = nil
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
              app.config.pinHistoryDirectory == nil, savedAfterQuickSave.pinHistoryDirectory == nil,
              !app.config.pinBorder, !savedAfterQuickSave.pinBorder else {
            fputs("FAIL: Quick save from an older session should preserve the current pin settings\n", stderr)
            return false
        }

        let saveAsURL = directory.appendingPathComponent("save-as.jpg")
        let saveAs = app.makeSessionCoordinator(mode: .normalCapture, chooseSaveDestination: { _ in
            updateConfigAndWait(app) {
                $0.pinHistoryLimit = 15
                $0.pinHistoryDirectory = quickSaveDirectory.path
            }
            return OutputService.SavePanelSelection(url: saveAsURL, format: .jpeg, smartPngCompression: false, quality: .compact)
        })
        saveAs.finishWithSave(image: image, scale: 1, forceDialog: true)
        let savedAfterSaveAs = AirSnipConfig.load(from: configURL)
        guard FileManager.default.fileExists(atPath: saveAsURL.path),
              savedAfterSaveAs.lastSaveDirectory == directory.path, savedAfterSaveAs.lastSaveFormat == .jpeg,
              savedAfterSaveAs.pngCompressionQuality == .compact, savedAfterSaveAs.pinHistoryLimit == 15,
              savedAfterSaveAs.pinHistoryDirectory == quickSaveDirectory.path else {
            fputs("FAIL: Save As should apply its selected preferences without replacing newer pin settings\n", stderr)
            return false
        }
        print("[pins] PASS: 旧编辑会话改工具、快速保存或另存为时保留当前贴图设置")
        return true
    }

    @MainActor
    private static func verifyMagnifierLabels(on screen: NSScreen, scale: Int) -> Bool {
        let frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        let pixelWidth = Int(frame.width) * scale
        let pixelHeight = Int(frame.height) * scale
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let bitmap = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        bitmap.setFillColor(CGColor(srgbRed: 0.12, green: 0.20, blue: 0.31, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        guard let image = bitmap.makeImage(), let pixels = PixelBufferRGBA(cgImage: image) else { return false }

        let snapshot = CapturedScreenSnapshot(
            screen: screen, frameInGlobalAppKit: frame,
            frameTopDown: ASRect(x: 0, y: 0, width: frame.width, height: frame.height),
            cgImage: image, rawBuffer: pixels, backingScale: Double(scale), windowsLocalTopDown: []
        )
        let coordinator = CaptureSessionCoordinator(config: AirSnipConfig())
        let overlay = OverlayScreenController(snapshot: snapshot, coordinator: coordinator)
        let canvas = overlay.canvasView
        defer { overlay.panel.close() }

        bitmap.translateBy(x: 0, y: CGFloat(pixelHeight))
        bitmap.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: overlay.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        func verifyLabels(at cursor: NSPoint, during action: String) -> Bool {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: true)
            canvas.draw(canvas.bounds)
            NSGraphicsContext.restoreGraphicsState()
            guard let rendered = bitmap.makeImage(), let result = PixelBufferRGBA(cgImage: rendered) else { return false }

            // These cursor positions leave room for the card at (+22, +22).
            // Sample label interiors so the swatch and keycap border cannot satisfy the check.
            let regions = [
                ("HEX", CGRect(x: 26, y: 132, width: 46, height: 12)),
                ("C", CGRect(x: 111, y: 134, width: 7, height: 10)),
                ("coordinate or size", CGRect(x: 8, y: 152, width: 96, height: 12)),
            ]
            for (label, region) in regions {
                let x = Int(cursor.x + 22 + region.minX) * scale
                let y = Int(cursor.y + 22 + region.minY) * scale
                let hasInk = (y..<(y + Int(region.height) * scale)).contains { row in
                    (x..<(x + Int(region.width) * scale)).contains { column in
                        let color = result.pixel(x: column, y: row)
                        return color.r > 120 && color.g > 120 && color.b > 120
                    }
                }
                guard hasInk else {
                    fputs("FAIL: Magnifier \(label) missing during \(action) at \(scale)×\n", stderr)
                    return false
                }
            }
            return true
        }

        func drag(from start: NSPoint, to end: NSPoint, action: String) -> Bool {
            canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: start))
            canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: end))
            let rendered = verifyLabels(at: end, during: action)
            canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: end))
            return rendered
        }

        let origin = NSPoint(x: 75, y: 65)
        let corner = NSPoint(x: 198, y: 142)
        let rightEdge = NSPoint(x: corner.x, y: origin.y + 19)
        let widenedEdge = NSPoint(x: rightEdge.x + 20, y: rightEdge.y)
        let widenedCorner = NSPoint(x: widenedEdge.x, y: corner.y)
        let finalCorner = NSPoint(x: widenedCorner.x + 28, y: widenedCorner.y + 35)
        canvas.mouseMoved(with: mouseEvent(.mouseMoved, at: origin))
        guard verifyLabels(at: origin, during: "hover"),
              drag(from: origin, to: corner, action: "selection"),
              drag(from: rightEdge, to: widenedEdge, action: "edge resize"),
              drag(from: widenedCorner, to: finalCorner, action: "corner resize") else { return false }

        var output: CGImage?
        coordinator.onCompleteCopy = { image, _ in output = image }
        canvas.keyDown(with: NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: overlay.panel.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: UInt16(kVK_Return)
        )!)
        guard let output,
              output.width == Int(finalCorner.x - origin.x) * scale,
              output.height == Int(finalCorner.y - origin.y) * scale else {
            fputs("FAIL: Magnifier resize gestures produced an unexpected screenshot size at \(scale)×\n", stderr)
            return false
        }
        return true
    }

    @MainActor
    private static func verifyPinAnnotation(on screen: NSScreen) -> Bool {
        var config = AirSnipConfig()
        config.pinAnnotationCoversDesktop = false
        config.uiScale = .p100
        config.confirmCancel = true
        let pixels = [UInt8](repeating: 0, count: 24 * 120 * 4)
        guard let image = PixelBufferRGBA(width: 24, height: 120, rgba: pixels).makeCGImage() else { return false }
        let manager = PinManager()
        let visible = screen.visibleFrame
        manager.createPin(
            cgImage: image,
            backingScale: 2,
            preferredScreenOriginAppKit: NSPoint(x: visible.midX, y: visible.midY),
            config: config
        )
        guard let pin = manager.windows.first else { return false }
        defer { manager.closeAll() }
        pin.adjustZoom(delta: -1, anchorInWindow: .zero)
        let frame = pin.window.frame
        let zoom = pin.zoomScale
        let originalView = pin.window.contentView

        func key(_ keyCode: Int, _ characters: String, in window: NSWindow) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                keyCode: UInt16(keyCode)
            )
        }

        let coordinator = CaptureSessionCoordinator(config: config, mode: .pinAnnotation(pin))
        coordinator.startPinAnnotation()
        defer { if coordinator.hasVisibleWindows { coordinator.cancelSession() } }
        guard let number = coordinator.activeWindowNumbers.first,
              let editor = NSApp.window(withWindowNumber: number),
              let canvas = editor.contentView as? OverlayCanvasView, !pin.window.isVisible else {
            fputs("FAIL: Pin annotation did not open in place\n", stderr)
            return false
        }
        guard coordinator.renderStandaloneAnnotatedOutputSample() != nil else { return false }

        // Scope WindowServer hit testing to the fixture windows, below any lock screen or system overlays.
        let gutter = NSPoint(x: editor.frame.minX + 3, y: frame.midY)
        func hitTestPanel(levelOffset: Int) -> NSPanel {
            let panel = NSPanel(
                contentRect: NSRect(x: gutter.x - 8, y: gutter.y - 8, width: 16, height: 16),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.backgroundColor = .white
            panel.level = NSWindow.Level(rawValue: editor.level.rawValue + levelOffset)
            panel.orderFrontRegardless()
            panel.display()
            return panel
        }
        let underlying = hitTestPanel(levelOffset: -1)
        let ceiling = hitTestPanel(levelOffset: 1)
        defer {
            ceiling.orderOut(nil)
            underlying.orderOut(nil)
        }
        editor.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))

        let hit = NSWindow.windowNumber(at: gutter, belowWindowWithWindowNumber: ceiling.windowNumber)
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let pinHit = NSWindow.windowNumber(at: center, belowWindowWithWindowNumber: ceiling.windowNumber)
        guard editor.frame.contains(gutter), !frame.contains(gutter), hit == underlying.windowNumber,
              pinHit == editor.windowNumber, canvas.acceptsFirstMouse(for: nil) else {
            fputs("FAIL: Pin annotation hit testing (margin \(hit)/\(underlying.windowNumber), pin \(pinHit)/\(editor.windowNumber))\n", stderr)
            return false
        }
        config.uiScale = .p150
        coordinator.refreshWindowedPinConfig(config)
        editor.resignKey()
        coordinator.refocus()
        canvas.needsDisplay = true
        editor.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        guard let done = canvas.toolbarItemRect(id: "file.copy"), canvas.bounds.contains(done) else {
            fputs("FAIL: Changing toolbar scale clipped Done in the active pin editor\n", stderr)
            return false
        }
        let location = canvas.convert(NSPoint(x: done.midX, y: done.midY), to: nil)
        let screenPoint = editor.convertPoint(toScreen: location)
        guard NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: ceiling.windowNumber) == editor.windowNumber else {
            fputs("FAIL: Done isn't clickable after changing toolbar scale\n", stderr)
            return false
        }
        func mouse(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: editor.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )
        }
        guard let down = mouse(.leftMouseDown), let up = mouse(.leftMouseUp) else { return false }
        canvas.mouseDown(with: down)
        canvas.mouseUp(with: up)
        guard pin.window.isVisible, pin.window.frame == frame, pin.zoomScale == zoom,
              pin.window.contentView === originalView,
              let result = PixelBufferRGBA(cgImage: pin.cgImage),
              result.width == 24, result.height == 120,
              result.pixel(x: 12, y: Int((8 * 120 / frame.height).rounded())).r > 220,
              result.pixel(x: 0, y: 0).a == 0 else {
            fputs("FAIL: Applying pin annotation changed its frame or misaligned the source pixels\n", stderr)
            return false
        }

        let applied = pin.cgImage
        let reopenedSession = CaptureSessionCoordinator(config: config, mode: .pinAnnotation(pin))
        reopenedSession.startPinAnnotation()
        defer { if reopenedSession.hasVisibleWindows { reopenedSession.cancelSession() } }
        guard let reopenedNumber = reopenedSession.activeWindowNumbers.first,
              let reopenedEditor = NSApp.window(withWindowNumber: reopenedNumber),
              let reopened = reopenedEditor.contentView as? OverlayCanvasView,
              let escape = key(kVK_Escape, "\u{1b}", in: reopenedEditor),
              reopenedSession.renderStandaloneAnnotatedOutputSample() != nil else { return false }
        reopened.needsDisplay = true
        reopenedEditor.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        let reopenedDone = reopened.toolbarItemRect(id: "file.copy")
        guard let reopenedDone, reopenedDone.width > done.width else {
            fputs("FAIL: A new pin editor did not use the updated toolbar scale (button \(String(describing: reopenedDone?.width)), previous \(done.width), window \(reopenedEditor.frame.width))\n", stderr)
            return false
        }
        reopened.keyDown(with: escape)
        guard reopenedSession.hasVisibleWindows else {
            fputs("FAIL: First Escape discarded pending pin annotations\n", stderr)
            return false
        }
        reopened.keyDown(with: escape)
        guard !reopenedSession.hasVisibleWindows, pin.window.isVisible, pin.cgImage === applied,
              pin.window.frame == frame, pin.window.contentView === originalView else {
            fputs("FAIL: Cancelling pin annotation did not restore the original pin\n", stderr)
            return false
        }

        do {
            let fullScreen = CaptureSessionCoordinator(config: AirSnipConfig(), mode: .pinAnnotation(pin))
            fullScreen.startPinAnnotation()
            defer { fullScreen.cancelSession() }
            guard fullScreen.hasVisibleWindows, !pin.window.isVisible else {
                fputs("FAIL: Pin annotation did not open in the default full-screen mode\n", stderr)
                return false
            }
        }

        let closingSession = CaptureSessionCoordinator(config: config, mode: .pinAnnotation(pin))
        closingSession.startPinAnnotation()
        var endedWithoutRestoringPin = false
        closingSession.onSessionEnded = { endedWithoutRestoringPin = !pin.window.isVisible }
        manager.onWillCloseAll = { [weak closingSession] in closingSession?.closeWithAllPins() }
        manager.closeAll()
        manager.onWillCloseAll = nil
        guard endedWithoutRestoringPin, !closingSession.hasVisibleWindows, manager.windows.isEmpty else {
            fputs("FAIL: Closing all pins restored the pin or left its editor open\n", stderr)
            return false
        }
        waitForPinOperation { manager.restoreLastClosedPin(config: config, completion: $0) }
        guard let restored = manager.windows.first,
              restored.window.isVisible, restored.window.frame == frame, restored.zoomScale == zoom,
              PixelBufferRGBA(cgImage: restored.cgImage) == result else {
            fputs("FAIL: Restoring a closed windowed annotation should keep the pin's last applied image and frame\n", stderr)
            return false
        }
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
                  cfg.autoCheckUpdate,
                  cfg.longshotAutoScroll == true,
                  cfg.longshotScrollSpeed == .normal,
                  cfg.pinAnnotationCoversDesktop,
                  cfg.swatchColors[1] == RGBAColor(r: 255, g: 0, b: 0),
                  cfg.defaultLineWidth == 2.0,
                  cfg.pngCompressionQuality == .visuallyLossless,
                  cfg.nameStyle.formatBaseName().hasPrefix("isnip-") else {
                fputs("FAIL: Default iSnip config or smartPngCompression default mismatch\n", stderr)
                return false
            }
            cfg.toolbar.setVisible(.tool(.ellipse), false)
            cfg.toolbar.setVisible(.ocr, false)
            cfg.pinAnnotationCoversDesktop = false
            cfg.autoCheckUpdate = false
            try cfg.save(to: cfgURL)
            let loaded = AirSnipConfig.load(from: cfgURL)
            guard !loaded.toolbar.isVisible(.tool(.ellipse)),
                  !loaded.toolbar.isVisible(.ocr),
                  loaded.toolbar.isVisible(.tool(.rect)),
                  !loaded.pinAnnotationCoversDesktop,
                  !loaded.autoCheckUpdate,
                  try JSONDecoder().decode(AirSnipConfig.self, from: Data("{}".utf8)).pinAnnotationCoversDesktop,
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
            for language in ["auto", "zh-Hans"] {
                let detailed = try LocalVisionOCR.recognizeDetailed(
                    cgImage: ocrImg,
                    languagePreference: language,
                    detectBarcodes: true
                )
                let textMatched = detailed.rawText.contains("极速截图") && detailed.rawText.contains("iSnip")
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
                for scale in [1, 2] {
                    guard verifyMagnifierLabels(on: screen, scale: scale) else { return false }
                }
                print("[smoke] PASS: 放大镜标签在 1×、2× 下的悬停、框选、拖边和拖角绘制")
                guard verifyPinAnnotation(on: screen) else {
                    fputs("FAIL: Windowed pin annotation, click-through, or image update mismatch\n", stderr)
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
                let clipboardCount = NSPasteboard.general.changeCount
                let ocrManager = OCRBubbleManager()
                ocrManager.text = "previous result must be replaced"
                ocrManager.recognizeAndPresent(rawSelectionImage: ocrImg, anchorScreenPoint: nil, config: defaultCfg)
                let ocrDeadline = Date().addingTimeInterval(60)
                while ocrManager.isRecognizing && Date() < ocrDeadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                }
                let panelTextOK = ocrManager.text.contains("极速截图") && ocrManager.text.contains("iSnip")
                    && !ocrManager.text.contains("previous result")
                let ocrPanelOK = !ocrManager.isRecognizing && ocrManager.errorMessage == nil
                    && panelTextOK
                    && ocrManager.barcodes.contains("https://github.com/zzusec/isnip")
                    && NSPasteboard.general.changeCount == clipboardCount
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
                guard let sample = coordinator.renderToolbarVerificationSample(selection: sampleSel),
                      sample.buttonIDs == defaultToolbarIDs, !sample.hasSecondaryBar,
                      !hasUniformToolbarSpacing(sample) else {
                    coordinator.cancelSession()
                    fputs("FAIL: Default screenshot toolbar buttons or dividers changed\n", stderr)
                    return false
                }
                coordinator.exportToolbarVerificationPreviews()

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

                var reorderedCfg = defaultCfg
                reorderedCfg.toolbar.mainOrder = [.ocr, .copy] + defaultCfg.toolbar.mainOrder.filter { $0 != .ocr && $0 != .copy }
                var windowedPinCfg = reorderedCfg
                windowedPinCfg.pinAnnotationCoversDesktop = false
                guard verifyReorderedScreenshotToolbar(snapshot: snap, config: reorderedCfg),
                      verifyReorderedPinToolbar(image: baseCG, config: reorderedCfg),
                      verifyReorderedPinToolbar(image: baseCG, config: windowedPinCfg),
                      verifyToolbarPreferencesWriteback(image: baked, snapshot: snap, in: tempDir, toolbar: reorderedCfg.toolbar)
                else {
                    return false
                }

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
                        config: reorderedCfg,
                        mode: .standaloneImageEdit(tallCG, max(1.0, Double(screen.backingScaleFactor)), screen)
                    )
                    tallEditCoord.startStandaloneImageEdit(
                        cgImage: tallCG,
                        backingScale: max(1.0, Double(screen.backingScaleFactor)),
                        screen: screen
                    )
                    defer { tallEditCoord.cancelSession() }
                    let expectedEditOrder = reorderedToolbarIDs.filter { $0 != "output.longshot" }
                    guard tallEditCoord.renderToolbarVerificationSample()?.buttonIDs == expectedEditOrder else {
                        fputs("FAIL: Longshot result annotation toolbar did not follow the saved order\n", stderr)
                        return false
                    }
                    if let tallBaked = tallEditCoord.renderStandaloneAnnotatedOutputSample() {
                        longshotSaveAndEditOK = (lsSavedDims?.0 == tallW)
                            && (lsSavedDims?.1 == tallH)
                            && (tallBaked.width == tallW)
                            && (tallBaked.height == tallH)
                    }
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
                    renderSettingsWindowSnapshot(
                        rootView: SettingsRootView(app: dummyApp, initialSearchQuery: "Project Info"),
                        appearance: .aqua,
                        to: dirURL.appendingPathComponent("13_project_info_search_en.png")
                    )
                    dummyApp.updateConfig { $0.language = .zhHans }
                    renderSettingsWindowSnapshot(
                        rootView: SettingsRootView(app: dummyApp, initialSearchQuery: "项目说明"),
                        appearance: .aqua,
                        to: dirURL.appendingPathComponent("13_project_info_search.png")
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

                guard visibleAndPersistent, !coordinator.hasVisibleWindows, ended else {
                    fputs("FAIL: Capture overlay visibility or session lifecycle changed\n", stderr)
                    return false
                }
                return isolatedWindowOK && firstMouseOK && smartSaveImmediateOK && longshotSaveAndEditOK
            }
            guard overlayOK else {
                fputs("FAIL: App behavior verification failed\n", stderr)
                return false
            }

            // Opening and closing many pin windows can delay async OCR in the smoke process.
            print("[smoke] 验证贴图关闭、恢复与历史设置...")
            let pinSaveConfigURL = tempDir.appendingPathComponent("pin-save", isDirectory: true).appendingPathComponent("config.json")
            let pinRestoreOK = try MainActor.assumeIsolated {
                guard let screen = NSScreen.main ?? NSScreen.screens.first else { return false }
                return try runCroppedPinStorageCheck(on: screen)
                    && runPinZoomChecks(image: baseCG)
                    && runRestoredPinZoomChecks(
                        image: baseCG, configURL: tempDir.appendingPathComponent("pin-zoom-history/config.json")
                    )
                    && withPinRestoreFixture(
                        image: baseCG,
                        configURL: tempDir.appendingPathComponent("clipboard-copy-before-close/config.json"),
                        runClipboardCopyBeforePinCloseCheck
                    )
                    && withPinRestoreFixture(
                        image: baseCG,
                        configURL: tempDir.appendingPathComponent("pin-config.json"),
                        runPinRestoreChecks
                    )
                    && runUsedClipboardImageAfterRelaunchCheck(
                        image: baseCG,
                        configURL: tempDir.appendingPathComponent("used-clipboard-image/config.json")
                    )
                    && runUsedClipboardCompressionAfterRelaunchCheck(
                        image: baked,
                        configURL: tempDir.appendingPathComponent("used-clipboard-compression/config.json")
                    )
                    && runUsedClipboardTextAfterRelaunchCheck(
                        image: baseCG,
                        configURL: tempDir.appendingPathComponent("used-clipboard-text/config.json")
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
                    && runBatchCloseDuringPinAnnotationCheck(image: baseCG)
                    && runClosedPinHistoryLimitCheck(
                        image: baseCG,
                        configURL: tempDir.appendingPathComponent("pin-history-limit/config.json")
                    )
                    && runUnavailablePinHistoryCheck(
                        image: baseCG,
                        configURL: tempDir.appendingPathComponent("pin-history-unavailable/config.json")
                    )
                    && runDiskPinHistoryCheck(
                        image: baseCG,
                        configURL: tempDir.appendingPathComponent("pin-history-disk/config.json")
                    )
                    && runPinHistoryQuitCheck(
                        image: baseCG,
                        configURL: tempDir.appendingPathComponent("pin-history-quit/config.json")
                    )
                    && runInterruptedPinHistoryWriteCheck(
                        image: baseCG,
                        configURL: tempDir.appendingPathComponent("pin-history-interrupted/config.json")
                    )
                    && runPinHistoryLimitRecoveryCheck(
                        image: baseCG,
                        configURL: tempDir.appendingPathComponent("pin-history-limit-recovery/config.json")
                    )
                    && runFailedPinHistoryWriteCheck(image: baseCG, directory: tempDir)
                    && withPinRestoreFixture(
                        image: baseCG,
                        configURL: tempDir.appendingPathComponent("pin-history-config/config.json"),
                        runConfiguredPinHistoryCheck
                    )
                    && runPinHistoryCaptureSaveCheck(image: baseCG, configURL: pinSaveConfigURL)
            }
            guard pinRestoreOK else { return false }

            guard MainActor.assumeIsolated({
                checkUnfocusedPinAcceptsFirstMouse(image: baseCG)
            }) else {
                return false
            }

            print("smoke-test: ok (iSnip v\(UpdateChecker.currentVersion))")
            return true
        } catch {
            fputs("FAIL: Smoke test threw error: \(error)\n", stderr)
            return false
        }
    }

    private static let defaultToolbarIDs = [
        "tool.rect", "tool.ellipse", "tool.line", "tool.arrow", "tool.freehand",
        "tool.blur", "tool.text", "tool.number", "tool.glow",
        "output.pin", "edit.undo", "output.ocr", "file.cancel", "output.longshot", "file.save", "file.copy"
    ]
    private static let reorderedToolbarIDs = ["output.ocr", "file.copy"]
        + defaultToolbarIDs.filter { $0 != "output.ocr" && $0 != "file.copy" }

    private static func hasUniformToolbarSpacing(_ sample: ToolbarVerificationSample) -> Bool {
        let buttons = sample.buttons
        let gaps = zip(buttons, buttons.dropFirst()).map { $1.rect.minX - $0.rect.maxX }
        guard let first = gaps.first else { return false }
        return gaps.allSatisfy { abs($0 - first) < 0.01 }
    }

    @MainActor
    private static func verifyReorderedScreenshotToolbar(snapshot: CapturedScreenSnapshot, config: AirSnipConfig) -> Bool {
        let session = CaptureSessionCoordinator(config: config, mode: .normalCapture)
        session.startWithSnapshots([snapshot])
        defer { session.cancelSession() }
        let selection = ASRect(
            x: 20, y: 20,
            width: Double(snapshot.rawBuffer.width) / snapshot.backingScale / 2,
            height: Double(snapshot.rawBuffer.height) / snapshot.backingScale / 2
        )
        guard let custom = session.renderToolbarVerificationSample(selection: selection),
              custom.buttonIDs == reorderedToolbarIDs, hasUniformToolbarSpacing(custom) else {
            fputs("FAIL: Reordered screenshot toolbar buttons or spacing differ from the saved layout\n", stderr)
            return false
        }

        session.mutateConfig { $0.toolbar.setVisible(.ocr, false) }
        guard session.renderToolbarVerificationSample()?.buttonIDs == reorderedToolbarIDs.filter({ $0 != "output.ocr" }) else {
            fputs("FAIL: Hiding OCR changed the other reordered screenshot buttons\n", stderr)
            return false
        }
        session.mutateConfig { $0.toolbar.resetMainOrder() }
        guard let restored = session.renderToolbarVerificationSample(),
              restored.buttonIDs == defaultToolbarIDs.filter({ $0 != "output.ocr" }),
              !hasUniformToolbarSpacing(restored) else {
            fputs("FAIL: Restoring the default screenshot toolbar changed visibility or dividers\n", stderr)
            return false
        }

        session.mutateConfig { $0.toolbar = config.toolbar }
        guard let visibleAgain = session.renderToolbarVerificationSample(),
              visibleAgain.buttonIDs == reorderedToolbarIDs else {
            fputs("FAIL: OCR did not return to its reordered position\n", stderr)
            return false
        }
        var didRunOCR = false
        session.onStartOCR = { image, _ in didRunOCR = image.width > 0 }
        clickToolbarButton(.ocr, in: session, sample: visibleAgain)
        if !didRunOCR {
            fputs("FAIL: Reordered screenshot OCR button did not start recognition\n", stderr)
        }
        return didRunOCR
    }

    @MainActor
    private static func verifyReorderedPinToolbar(image: CGImage, config: AirSnipConfig) -> Bool {
        let pinManager = PinManager()
        guard pinManager.createPin(cgImage: image, backingScale: 1, preferredScreenOriginAppKit: nil, config: config),
              let pin = pinManager.windows.first else { return false }
        let session = CaptureSessionCoordinator(config: config, mode: .pinAnnotation(pin))
        defer {
            if session.hasVisibleWindows { session.cancelSession() }
            pinManager.closeAll()
        }
        var finished = false
        session.onSessionEnded = { finished = true }
        session.startPinAnnotation()
        let expectedIDs = reorderedToolbarIDs.filter { $0 != "output.pin" && $0 != "output.longshot" }
        guard let sample = session.renderToolbarVerificationSample(), sample.buttonIDs == expectedIDs else {
            fputs("FAIL: Pin annotation toolbar did not follow the saved order\n", stderr)
            return false
        }
        clickToolbarButton(.copy, in: session, sample: sample)
        guard finished, !session.hasVisibleWindows, pin.window.isVisible else {
            fputs("FAIL: Reordered pin annotation Done button did not complete the edit\n", stderr)
            return false
        }
        return true
    }

    @MainActor
    private static func verifyToolbarPreferencesWriteback(
        image: CGImage, snapshot: CapturedScreenSnapshot, in directory: URL, toolbar: ToolbarConfig
    ) -> Bool {
        var currentToolbar = toolbar
        currentToolbar.setVisible(.save, false)
        currentToolbar.setVisible(.tool(.line), false)
        let expectedOrder = currentToolbar.mainOrder
        let expectedHidden = Set(currentToolbar.hidden)

        func startOlderSession(
            _ name: String, mode: CaptureSessionCoordinator.SessionMode = .normalCapture,
            chooseDestination: @escaping OutputService.ChooseSaveDestination = { _ in nil }
        ) -> (app: AirSnipAppController, session: CaptureSessionCoordinator, exportDirectory: URL) {
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            let exportDirectory = folder.appendingPathComponent("images", isDirectory: true)
            let app = AirSnipAppController(configURL: folder.appendingPathComponent("config.json"))
            app.updateConfig {
                $0.theme = .light
                $0.lastSaveDirectory = exportDirectory.path
                $0.lastSaveFormat = .png
                $0.smartPngCompression = false
                $0.showCompletionToast = false
            }
            let session = app.makeSessionCoordinator(mode: mode, chooseSaveDestination: chooseDestination)
            app.updateConfig {
                $0.toolbar = currentToolbar
                $0.theme = .dark
            }
            return (app, session, exportDirectory)
        }

        func preferencesMatch(in app: AirSnipAppController, also matches: (AirSnipConfig) -> Bool) -> Bool {
            let saved = AirSnipConfig.load(from: app.configURL)
            let nextCapture = app.makeSessionCoordinator(mode: .normalCapture)
            return [app.config, saved, nextCapture.config].allSatisfy { config in
                config.toolbar.mainOrder == expectedOrder && Set(config.toolbar.hidden) == expectedHidden
                    && config.theme == .dark && matches(config)
            }
        }

        let quickSave = startOlderSession("quick-save")
        quickSave.session.finishWithSave(image: image, scale: snapshot.backingScale)
        let quickImages = try? FileManager.default.contentsOfDirectory(at: quickSave.exportDirectory, includingPropertiesForKeys: nil)
        guard quickImages?.count == 1, quickImages?.first?.pathExtension == "png",
              preferencesMatch(in: quickSave.app, also: { $0.lastSaveDirectory == quickSave.exportDirectory.path }) else {
            fputs("FAIL: Quick Save from an older session did not save the PNG and preserve current preferences\n", stderr)
            return false
        }

        var selection: OutputService.SavePanelSelection?
        let saveAs = startOlderSession("save-as", chooseDestination: { _ in selection })
        var saveAsFinished = false
        saveAs.session.onSessionEnded = { saveAsFinished = true }
        saveAs.session.finishWithSave(image: image, scale: snapshot.backingScale, forceDialog: true)
        guard !saveAsFinished, preferencesMatch(in: saveAs.app, also: { $0.lastSaveDirectory == saveAs.exportDirectory.path }) else {
            fputs("FAIL: Cancelling Save As changed preferences or closed the session\n", stderr)
            return false
        }
        let folder = saveAs.exportDirectory.appendingPathComponent("chosen", isDirectory: true)
        selection = OutputService.SavePanelSelection(
            url: folder.appendingPathComponent("screenshot.png"), format: .jpeg, smartPngCompression: true, quality: .compact
        )
        saveAs.session.finishWithSave(image: image, scale: snapshot.backingScale, forceDialog: true)
        let jpegURL = folder.appendingPathComponent("screenshot.jpg")
        guard saveAsFinished, NSImage(contentsOf: jpegURL) != nil,
              preferencesMatch(in: saveAs.app, also: {
                  $0.lastSaveDirectory == folder.path && $0.lastSaveFormat == .jpeg
                      && $0.smartPngCompression && $0.pngCompressionQuality == .compact
              }) else {
            fputs("FAIL: Save As did not write the JPEG and merge its preferences into the current toolbar settings\n", stderr)
            return false
        }

        let mode = CaptureSessionCoordinator.SessionMode.standaloneImageEdit(image, snapshot.backingScale, snapshot.screen)
        let annotation = startOlderSession("annotation", mode: mode)
        annotation.session.mutateConfig { $0.defaultLineWidth = 5 }
        guard annotation.session.config.defaultLineWidth == 5,
              annotation.session.config.toolbar.mainOrder == ToolbarSlot.defaultMainOrder,
              preferencesMatch(in: annotation.app, also: { $0.defaultLineWidth == 5 }) else {
            fputs("FAIL: Writing annotation preferences did not preserve the current toolbar and update the line width\n", stderr)
            return false
        }
        print("[smoke]   ↳ Quick Save, Save As, cancellation and annotation writeback preserved the current toolbar and theme")
        return true
    }

    @MainActor
    private static func clickToolbarButton(
        _ slot: ToolbarSlot, in session: CaptureSessionCoordinator, sample: ToolbarVerificationSample
    ) {
        guard let rect = sample.buttons.first(where: { $0.id == slot.key })?.rect,
              let window = NSApp.windows.first(where: { session.activeWindowNumbers.contains($0.windowNumber) }),
              let view = window.contentView as? OverlayCanvasView else { return }
        let point = view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )
        }
        if let down = event(.leftMouseDown), let up = event(.leftMouseUp) {
            view.mouseDown(with: down)
            view.mouseUp(with: up)
        }
    }

    @MainActor
    private static func checkUnfocusedPinAcceptsFirstMouse(image: CGImage) -> Bool {
        _ = NSApplication.shared
        let pinManager = PinManager()
        let size = NSSize(width: image.width, height: image.height)
        let pin = PinWindowController(
            cgImage: image,
            baseSize: size,
            backingScale: 1,
            origin: .zero,
            showBorder: true,
            manager: pinManager
        )
        let window = pin.window
        guard !window.isKeyWindow, let pinView = window.contentView else {
            fputs("FAIL: First-mouse check needs an unfocused pin with a content view\n", stderr)
            return false
        }
        guard let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: size.width / 2, y: size.height / 2),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ) else {
            fputs("FAIL: Could not create the pin's first mouse-down event\n", stderr)
            return false
        }
        guard pinView.acceptsFirstMouse(for: mouseDown) else {
            fputs("FAIL: An unfocused pin should accept the first mouse press\n", stderr)
            return false
        }
        print("[pins] PASS: 失焦贴图接收首次鼠标按下")
        return true
    }
}
