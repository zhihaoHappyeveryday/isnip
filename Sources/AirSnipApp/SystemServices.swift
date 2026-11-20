import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import CoreText
import Darwin
import ImageIO
import QuartzCore
import ScreenCaptureKit
import ServiceManagement
import UniformTypeIdentifiers
import AirSnipCore

public struct CapturedScreenSnapshot {
    public let screen: NSScreen
    public let frameInGlobalAppKit: CGRect
    /// Top-down frame where (0,0) is top-left of primary screen
    public let frameTopDown: ASRect
    public let cgImage: CGImage
    public let rawBuffer: PixelBufferRGBA
    public let backingScale: Double
    /// Visible windows in strict front-to-back Z-order localized to this screen's top-down point coordinates (0,0 = screen top-left)
    public let windowsLocalTopDown: [WindowSnapCandidate]
}

@MainActor
public enum ScreenCaptureService {
    public static func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func requestScreenCapturePermissionIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return CGRequestScreenCaptureAccess()
    }

    public static func openScreenCaptureSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    public static func relaunchApplication(extraArguments: [String] = []) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundlePath = Bundle.main.bundleURL.path
        let script = """
        pid="$1"; app="$2"; shift 2
        while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
        if [ "$#" -gt 0 ]; then
          open "$app" --args "$@"
        else
          open "$app"
        fi
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script, "relaunch", "\(pid)", bundlePath] + extraArguments
        try? proc.run()
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            exit(0)
        }
    }

    public static func resetScreenCapturePermissionAndRelaunch() {
        if let bundleID = Bundle.main.bundleIdentifier {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "ScreenCapture", bundleID]
            try? reset.run()
            reset.waitUntilExit()
        }
        relaunchApplication(extraArguments: ["--request-screen-capture"])
    }

    public static func showPermissionGuidanceAlert(error: Error? = nil) {
        let _ = error
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        if L10n.current.isEnglish {
            alert.messageText = "Screen Recording Permission Required"
            alert.informativeText = """
            Please enable iSnip in System Settings → Privacy & Security → Screen & System Audio Recording:
            • Just enabled: Click "Relaunch" to apply
            • Already enabled: Click "Reset Permission" to repair stale TCC authorization
            """
            alert.addButton(withTitle: "Relaunch")
            alert.addButton(withTitle: "Reset Permission")
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.messageText = "需要「屏幕录制」权限"
            alert.informativeText = """
            请在「系统设置 → 录屏与系统录音」中开启 iSnip：
            • 刚开启开关：点「重启应用」生效
            • 已开启仍提示：点「重置权限」修复旧授权记录
            """
            alert.addButton(withTitle: "重启应用")
            alert.addButton(withTitle: "重置权限")
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "取消")
        }

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            relaunchApplication()
        case .alertSecondButtonReturn:
            resetScreenCapturePermissionAndRelaunch()
        case .alertThirdButtonReturn:
            openScreenCaptureSystemSettings()
        default:
            break
        }
    }

    public struct GlobalWindowDescriptor: Sendable {
        public let windowID: UInt32
        public let ownerName: String
        public let title: String
        public let globalRectTopDown: ASRect
    }

    /// Queries on-screen application windows via CoreGraphics (top-down global coordinates, front-to-back Z-order).
    public static func queryOnScreenWindowsGlobalTopDown(excludingWindowNumbers: Set<Int> = []) -> [GlobalWindowDescriptor] {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let ignoredOwners: Set<String> = [
            "Dock", "程序坞", "Window Server", "WindowManager", "Wallpaper", "墙纸",
            "SystemUIServer", "Control Center", "控制中心", "Notification Center", "通知中心", "Spotlight", "聚焦"
        ]
        var descriptors: [GlobalWindowDescriptor] = []
        for entry in infoList {
            let winID = (entry[kCGWindowNumber as String] as? UInt32)
                ?? UInt32((entry[kCGWindowNumber as String] as? Int) ?? 0)
            if winID == 0 || excludingWindowNumbers.contains(Int(winID)) {
                continue
            }
            let ownerName = (entry[kCGWindowOwnerName as String] as? String) ?? ""
            if ignoredOwners.contains(ownerName) {
                continue
            }
            let layer = (entry[kCGWindowLayer as String] as? Int) ?? 0
            if layer != 0 { continue } // Normal app windows live at layer 0 (excludes overlays/HUDs/pins)
            let alpha = (entry[kCGWindowAlpha as String] as? Double) ?? 1.0
            if alpha <= 0.05 { continue }
            guard let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict),
                  cgRect.width >= 24 && cgRect.height >= 24 else {
                continue
            }
            let title = (entry[kCGWindowName as String] as? String) ?? ""
            descriptors.append(GlobalWindowDescriptor(
                windowID: winID,
                ownerName: ownerName,
                title: title,
                globalRectTopDown: ASRect(x: cgRect.origin.x, y: cgRect.origin.y, width: cgRect.width, height: cgRect.height)
            ))
        }
        return descriptors
    }

    /// Captures a single independent application window at 1:1 native Retina resolution with transparent rounded corners
    /// and zero occlusion from overlapping windows or desktop wallpaper.
    public static func captureSingleWindow(windowID: UInt32, fallbackScale: Double) async -> CGImage? {
        guard windowID != 0 else { return nil }
        do {
            let shareable = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let scWin = shareable.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: scWin)
            let filterScale = Double(filter.pointPixelScale)
            let scale = max(1.0, filterScale > 0.5 ? filterScale : fallbackScale)
            let rect = filter.contentRect.width > 1 && filter.contentRect.height > 1 ? filter.contentRect : scWin.frame
            let cfg = SCStreamConfiguration()
            cfg.width = max(1, Int((rect.width * scale).rounded()))
            cfg.height = max(1, Int((rect.height * scale).rounded()))
            cfg.showsCursor = false
            cfg.capturesAudio = false
            cfg.shouldBeOpaque = false
            cfg.ignoreShadowsSingleWindow = true
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        } catch {
            return nil
        }
    }

    /// Captures all connected displays in parallel at native physical pixel resolution.
    public static func captureAllDisplays(excludingWindowNumbers: Set<Int> = []) async throws -> [CapturedScreenSnapshot] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [] }
        let primaryHeight = screens[0].frame.height
        let globalWindows = queryOnScreenWindowsGlobalTopDown(excludingWindowNumbers: excludingWindowNumbers)

        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let excludedSCWindows = shareable.windows.filter { excludingWindowNumbers.contains(Int($0.windowID)) }

        var results: [CapturedScreenSnapshot] = []
        for screen in screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let scDisplay = shareable.displays.first(where: { $0.displayID == screenNumber }) else {
                continue
            }
            let scale = Double(screen.backingScaleFactor)
            let pixelW = max(1, Int((screen.frame.width * screen.backingScaleFactor).rounded()))
            let pixelH = max(1, Int((screen.frame.height * screen.backingScaleFactor).rounded()))

            let filter = SCContentFilter(display: scDisplay, excludingWindows: excludedSCWindows)
            let cfg = SCStreamConfiguration()
            cfg.width = pixelW
            cfg.height = pixelH
            cfg.showsCursor = false
            cfg.capturesAudio = false

            let cgImg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            guard let rawBuf = PixelBufferRGBA(cgImage: cgImg) else { continue }

            // Convert AppKit screen frame (bottom-left origin) to CG global top-down coordinates
            let topDownY = primaryHeight - screen.frame.maxY
            let screenTopDown = ASRect(
                x: Double(screen.frame.minX),
                y: Double(topDownY),
                width: Double(screen.frame.width),
                height: Double(screen.frame.height)
            )

            let localScreenSize = ASRect(x: 0, y: 0, width: screenTopDown.width, height: screenTopDown.height)
            let localWindows: [WindowSnapCandidate] = globalWindows.compactMap { desc in
                let wr = desc.globalRectTopDown
                let ix0 = max(screenTopDown.minX, wr.minX)
                let iy0 = max(screenTopDown.minY, wr.minY)
                let ix1 = min(screenTopDown.maxX, wr.maxX)
                let iy1 = min(screenTopDown.maxY, wr.maxY)
                let w = ix1 - ix0
                let h = iy1 - iy0
                let localRect = ASRect(
                    x: ix0 - screenTopDown.minX,
                    y: iy0 - screenTopDown.minY,
                    width: w,
                    height: h
                )
                let unclippedLocal = ASRect(
                    x: wr.minX - screenTopDown.minX,
                    y: wr.minY - screenTopDown.minY,
                    width: wr.width,
                    height: wr.height
                )
                return WindowSnapCandidate.make(
                    windowID: desc.windowID,
                    localRect: localRect,
                    unclippedLocalRect: unclippedLocal,
                    ownerName: desc.ownerName,
                    title: desc.title,
                    screenSize: localScreenSize
                )
            }

            results.append(CapturedScreenSnapshot(
                screen: screen,
                frameInGlobalAppKit: screen.frame,
                frameTopDown: screenTopDown,
                cgImage: cgImg,
                rawBuffer: rawBuf,
                backingScale: scale,
                windowsLocalTopDown: localWindows
            ))
        }
        return results
    }

    /// Captures a specific sub-region of a single display for live Longshot scrolling, excluding AirSnip's own windows.
    public static func captureDisplayRegion(
        screen: NSScreen,
        localTopDownRect: ASRect,
        excludingWindowNumbers: Set<Int>
    ) async -> PixelBufferRGBA? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        do {
            let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scDisplay = shareable.displays.first(where: { $0.displayID == screenNumber }) else {
                return nil
            }
            let excluded = shareable.windows.filter { excludingWindowNumbers.contains(Int($0.windowID)) }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: excluded)
            let scale = Double(screen.backingScaleFactor)
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = localTopDownRect.cgRect
            cfg.width = max(1, Int((localTopDownRect.width * scale).rounded()))
            cfg.height = max(1, Int((localTopDownRect.height * scale).rounded()))
            cfg.showsCursor = false
            cfg.capturesAudio = false

            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            return PixelBufferRGBA(cgImage: img)
        } catch {
            return nil
        }
    }
}

@MainActor
public enum AccessibilityService {
    public static func hasPermission() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    public static func requestPermissionPrompt() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    public static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Converts a screen-local top-down point to Quartz global top-down coordinates (`(0,0)` = primary screen top-left).
    public static func globalCGPoint(on screen: NSScreen, localTopDownPoint: ASPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let screenTopDownX = Double(screen.frame.minX)
        let screenTopDownY = Double(primaryHeight - screen.frame.maxY)
        return CGPoint(
            x: screenTopDownX + localTopDownPoint.x,
            y: screenTopDownY + localTopDownPoint.y
        )
    }

    /// Ensures the cursor sits inside the target viewport before emitting synthetic wheel events so WindowServer routes scrolling to the target view.
    public static func moveCursorIntoViewportIfNeeded(
        screen: NSScreen,
        viewportTopDown: ASRect,
        avoidAppKitRect: NSRect? = nil
    ) {
        let sFrame = screen.frame
        let mouseAppKit = NSEvent.mouseLocation
        let localX = Double(mouseAppKit.x - sFrame.minX)
        let localY = Double(sFrame.maxY - mouseAppKit.y)

        let insetX = min(28.0, viewportTopDown.width * 0.18)
        let insetY = min(28.0, viewportTopDown.height * 0.18)
        let inner = ASRect(
            x: viewportTopDown.minX + insetX,
            y: viewportTopDown.minY + insetY,
            width: max(4.0, viewportTopDown.width - insetX * 2.0),
            height: max(4.0, viewportTopDown.height - insetY * 2.0)
        )
        let overlapsAvoid = avoidAppKitRect?.contains(mouseAppKit) ?? false
        if !overlapsAvoid && sFrame.contains(mouseAppKit) && inner.contains(ASPoint(localX, localY)) {
            return
        }

        let targetLocal = ASPoint(
            viewportTopDown.midX,
            viewportTopDown.minY + viewportTopDown.height * 0.46
        )
        let cgPt = globalCGPoint(on: screen, localTopDownPoint: targetLocal)
        CGWarpMouseCursorPosition(cgPt)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    public static let syntheticScrollEventTag: Int64 = 0x4953_4E50

    /// Posts a continuous pixel-accurate downward scroll tick without trackpad momentum tail.
    public static func postPixelScrollDown(at globalCGPoint: CGPoint, deltaPointsDown: Int) {
        guard deltaPointsDown > 0,
              let src = CGEventSource(stateID: .hidSystemState),
              let ev = CGEvent(
                  scrollWheelEvent2Source: src,
                  units: .pixel,
                  wheelCount: 1,
                  wheel1: Int32(-deltaPointsDown),
                  wheel2: 0,
                  wheel3: 0
              ) else {
            return
        }
        ev.setIntegerValueField(.eventSourceUserData, value: syntheticScrollEventTag)
        ev.location = globalCGPoint
        ev.post(tap: .cghidEventTap)
    }
}

@MainActor
public enum OutputService {
    struct SaveOutcome {
        let url: URL
        let updatePreferences: ((inout AirSnipConfig) -> Void)?
    }

    struct SavePanelSelection {
        let url: URL
        let format: ExportImageFormat
        let smartPngCompression: Bool
        let quality: PngCompressionQualityPreset
    }

    typealias ChooseSaveDestination = @MainActor (AirSnipConfig) -> SavePanelSelection?

    public struct ClipboardCopyID: Codable, Equatable {
        fileprivate let bootSessionID: UUID
        fileprivate let pasteboardName: String
        fileprivate let originalCopyRevision: Int

        private enum CodingKeys: String, CodingKey {
            case bootSessionID, pasteboardName
            case originalCopyRevision = "changeCount"
        }
    }

    private struct ClipboardRewrite: Codable {
        let bootSessionID: UUID
        let pasteboardName: String
        let writtenPasteboardRevision: Int
        let originalCopyRevision: Int

        private enum CodingKeys: String, CodingKey {
            case bootSessionID, pasteboardName
            case writtenPasteboardRevision = "changeCount"
            case originalCopyRevision = "originalChangeCount"
        }
    }

    // Scope pasteboard change counts to the system boot that issued them.
    private static let clipboardBootSessionID: UUID = {
        var value = [CChar](repeating: 0, count: 37)
        var size = value.count
        guard sysctlbyname("kern.bootsessionuuid", &value, &size, nil, 0) == 0,
              let id = UUID(uuidString: String(cString: value)) else { return UUID() }
        return id
    }()

    private static let clipboardRewriteType = NSPasteboard.PasteboardType("io.zzusec.airsnip.clipboard-rewrite")

    private static func writePngDataToPasteboard(
        _ pngData: Data, to pasteboard: NSPasteboard, originalCopyRevision: Int? = nil
    ) -> Int? {
        let writtenPasteboardRevision = pasteboard.clearContents()
        let item = NSPasteboardItem()
        // Omitting uncompressed TIFF avoids 10-20 MB of extra clipboard data.
        item.setData(pngData, forType: .png)
        if let originalCopyRevision {
            let rewrite = ClipboardRewrite(
                bootSessionID: clipboardBootSessionID, pasteboardName: pasteboard.name.rawValue,
                writtenPasteboardRevision: writtenPasteboardRevision, originalCopyRevision: originalCopyRevision
            )
            if let data = try? PropertyListEncoder().encode(rewrite) {
                item.setData(data, forType: clipboardRewriteType)
            }
        }
        guard pasteboard.writeObjects([item]) else { return nil }
        return writtenPasteboardRevision
    }

    public static func copyImageToClipboard(
        _ cgImage: CGImage,
        backingScale: Double = 2.0,
        config: AirSnipConfig? = nil,
        to pasteboard: NSPasteboard = .general,
        onCompressed: (@MainActor @Sendable (PngCompressionResult) -> Void)? = nil
    ) {
        let effectiveScale = max(1.0, backingScale.isFinite ? backingScale : 2.0)
        let pointSize = NSSize(
            width: CGFloat(Double(cgImage.width) / effectiveScale),
            height: CGFloat(Double(cgImage.height) / effectiveScale)
        )
        let nsImage = NSImage(cgImage: cgImage, size: pointSize)

        guard let rawPngData = try? ImageEncoder.encode(cgImage, format: .png, scale: effectiveScale) else {
            pasteboard.clearContents()
            pasteboard.writeObjects([nsImage])
            return
        }

        guard let originalCopyRevision = writePngDataToPasteboard(rawPngData, to: pasteboard) else { return }
        let shouldCompress = (config?.smartPngCompression ?? true) && (config?.compressClipboardPng ?? true)
        let qualityPreset = config?.pngCompressionQuality ?? .visuallyLossless

        guard shouldCompress else {
            let passthrough = PngCompressionResult(
                data: rawPngData,
                originalBytes: rawPngData.count,
                compressedBytes: rawPngData.count,
                usedPngquant: false,
                usedOxipng: false
            )
            onCompressed?(passthrough)
            return
        }

        Task.detached(priority: .userInitiated) {
            // Stage 1 (~200ms): fast perceptual quantization (`pngquant --speed 1`)
            let stage1 = PngSmartCompressor.compress(
                rawPngData,
                quality: qualityPreset,
                mode: .fastQuantizeOnly
            )
            let stage1Revision: Int? = await MainActor.run {
                guard pasteboard.changeCount == originalCopyRevision else { return nil }
                let revision = stage1.compressedBytes < rawPngData.count
                    ? writePngDataToPasteboard(stage1.data, to: pasteboard, originalCopyRevision: originalCopyRevision)
                    : originalCopyRevision
                onCompressed?(stage1)
                return revision
            }
            guard let expectedRevision = stage1Revision else { return }

            // Stage 2: lossless `oxipng -o max` bit-stream squeeze in background
            let stage2 = PngSmartCompressor.optimizeWithOxipng(
                stage1.data,
                originalBytes: rawPngData.count,
                usedPngquant: stage1.usedPngquant,
                oxipngMax: true
            )
            guard stage2.compressedBytes < stage1.compressedBytes else { return }
            await MainActor.run {
                guard pasteboard.changeCount == expectedRevision else { return }
                _ = writePngDataToPasteboard(stage2.data, to: pasteboard, originalCopyRevision: originalCopyRevision)
            }
        }
    }

    public static func copyStringToClipboard(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    public static func readImageFromClipboard(
        from pasteboard: NSPasteboard = .general
    ) -> (cgImage: CGImage, pointSize: NSSize)? {
        let changeCount = pasteboard.changeCount
        guard let image = readPasteboardImage(pasteboard), pasteboard.changeCount == changeCount else { return nil }
        return image
    }

    static func readPinFromClipboard(
        from pasteboard: NSPasteboard,
        excluding previousCopy: ClipboardCopyID?
    ) -> (cgImage: CGImage, pointSize: NSSize, copyID: ClipboardCopyID, originalText: String?, isTextPreviewClipped: Bool)? {
        let currentRevision = pasteboard.changeCount
        let copyID = clipboardCopyID(for: pasteboard, currentRevision: currentRevision)
        guard copyID != previousCopy else { return nil }
        if let image = readPasteboardImage(pasteboard) {
            guard pasteboard.changeCount == currentRevision else { return nil }
            return (image.cgImage, image.pointSize, copyID, nil, false)
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty,
              let image = renderPinText(text), pasteboard.changeCount == currentRevision else { return nil }
        return (image.cgImage, image.pointSize, copyID, text, image.isClipped)
    }

    static func clipboardCopyID(for pasteboard: NSPasteboard, currentRevision: Int) -> ClipboardCopyID {
        let name = pasteboard.name.rawValue
        var originalCopyRevision = currentRevision
        // A recopy may carry the marker into a new pasteboard revision.
        if let data = pasteboard.data(forType: clipboardRewriteType),
           let rewrite = try? PropertyListDecoder().decode(ClipboardRewrite.self, from: data),
           rewrite.bootSessionID == clipboardBootSessionID, rewrite.pasteboardName == name,
           rewrite.writtenPasteboardRevision == currentRevision {
            originalCopyRevision = rewrite.originalCopyRevision
        }
        return ClipboardCopyID(
            bootSessionID: clipboardBootSessionID, pasteboardName: name, originalCopyRevision: originalCopyRevision
        )
    }

    private static func readPasteboardImage(_ pasteboard: NSPasteboard) -> (cgImage: CGImage, pointSize: NSSize)? {
        guard let nsImage = NSImage(pasteboard: pasteboard) else { return nil }
        var rect = NSRect(origin: .zero, size: nsImage.size)
        guard let cg = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              cg.width > 0, cg.height > 0 else {
            return nil
        }
        let ptSize = nsImage.size.width > 1 && nsImage.size.height > 1
            ? nsImage.size
            : NSSize(width: CGFloat(cg.width) / 2.0, height: CGFloat(cg.height) / 2.0)
        return (cg, ptSize)
    }

    private static func renderPinText(_ text: String) -> (cgImage: CGImage, pointSize: NSSize, isClipped: Bool)? {
        let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(gray: 0, alpha: 1)
        ]
        let padding: CGFloat = 12
        let scale = max(1, NSScreen.main?.backingScaleFactor ?? 2)
        let maxSide = 8192
        let maxBitmapBytes = 32 * 1024 * 1024

        // Bound typesetting work before shaping the clipboard text.
        let scalars = text.unicodeScalars
        let preview = scalars.prefix(64 * 1024)
        let minimumLineHeight = ceil(font.ascender - font.descender + font.leading)
        let lineLimit = Int((CGFloat(maxSide) / scale - padding * 2) / minimumLineHeight)
        let sourceLines = String(preview).split(
            maxSplits: lineLimit, omittingEmptySubsequences: false, whereSeparator: \.isNewline
        )
        let lines = sourceLines.prefix(lineLimit).map { line in
            CTLineCreateWithAttributedString(NSAttributedString(string: String(line), attributes: attributes))
        }
        var width: CGFloat = 0
        var ascent = font.ascender
        var descent = -font.descender
        var leading = font.leading
        for line in lines {
            var lineAscent: CGFloat = 0
            var lineDescent: CGFloat = 0
            var lineLeading: CGFloat = 0
            let lineWidth = CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, &lineLeading)
            width = max(width, CGFloat(lineWidth))
            ascent = max(ascent, lineAscent)
            descent = max(descent, lineDescent)
            leading = max(leading, lineLeading)
        }

        let lineHeight = ceil(ascent + descent + leading)
        let naturalWidth = max(32, ceil(width) + padding * 2)
        let pixelWidth = Int(min(ceil(naturalWidth * scale), CGFloat(maxSide)))
        // Align the stride explicitly so row padding is included in the budget.
        let bytesPerRow = (pixelWidth * 4 + 63) / 64 * 64
        let maxPixelHeight = min(maxSide, maxBitmapBytes / bytesPerRow)
        let visibleLineCount = min(lines.count, Int((CGFloat(maxPixelHeight) / scale - padding * 2) / lineHeight))
        guard visibleLineCount > 0 else { return nil }
        let pointSize = NSSize(
            width: min(naturalWidth, CGFloat(pixelWidth) / scale),
            height: lineHeight * CGFloat(visibleLineCount) + padding * 2
        )
        let pixelHeight = min(Int(ceil(pointSize.height * scale)), maxPixelHeight)
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        let clipsWidth = pointSize.width < naturalWidth
        if clipsWidth {
            context.clip(to: CGRect(x: 0, y: 0, width: pointSize.width - padding, height: pointSize.height))
        }
        for (index, line) in lines.prefix(visibleLineCount).enumerated() {
            context.textPosition = CGPoint(x: padding, y: pointSize.height - padding - ascent - CGFloat(index) * lineHeight)
            CTLineDraw(line, context)
        }
        guard let cgImage = context.makeImage() else { return nil }
        let isClipped = clipsWidth || visibleLineCount < sourceLines.count || preview.endIndex != scalars.endIndex
        return (cgImage, pointSize, isClipped)
    }

    public static func readImageFromFileDialog() -> CGImage? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = L10n.tr("选择图片", "Choose Image")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
           cg.width > 0 && cg.height > 0 {
            return cg
        }
        if let nsImg = NSImage(contentsOf: url) {
            var rect = NSRect(origin: .zero, size: nsImg.size)
            if let cg = nsImg.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                return cg
            }
        }
        ToastHUD.show(L10n.tr("无法读取图片", "Unable to read image"), symbol: "exclamationmark.triangle.fill", tint: .systemOrange)
        return nil
    }

    public static func defaultSaveDirectoryURL(for config: AirSnipConfig) -> URL {
        let fm = FileManager.default
        if let custom = config.lastSaveDirectory, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        if let sysLoc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
           !sysLoc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (sysLoc as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        if let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            return downloads
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Downloads", isDirectory: true)
    }

    public static func displayPath(for url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    static func pinHistoryRootURL(for config: AirSnipConfig) -> URL {
        if let path = config.pinHistoryDirectory, !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return defaultSaveDirectoryURL(for: config)
            .appendingPathComponent(AirSnipConfig.defaultPinHistoryDirectoryName, isDirectory: true)
    }

    public static func chooseSaveDirectory(initial: URL) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = L10n.tr("选择保存位置", "Choose Save Folder")
        panel.prompt = L10n.tr("选择", "Select")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = initial
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    public static func uniqueSaveDestinationURL(directory: URL, baseName: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent("\(baseName).\(ext)")
        var suffix = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(suffix).\(ext)")
            suffix += 1
        }
        return candidate
    }

    private static func writeEncodedImage(
        _ cgImage: CGImage,
        to url: URL,
        format: ExportImageFormat,
        scale: Double,
        smartCompress: Bool,
        quality: PngCompressionQualityPreset,
        onFinalCompressed: (@MainActor @Sendable (URL, PngCompressionResult) -> Void)?
    ) throws {
        let effectiveScale = max(1.0, scale.isFinite ? scale : 2.0)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if format == .png && smartCompress {
            // Phase 0 (~16-80ms): write valid lossless raw PNG synchronously so the file is guaranteed on disk right away
            let rawPngData = try ImageEncoder.encode(cgImage, format: .png, scale: effectiveScale)
            try rawPngData.write(to: url, options: .atomic)
            let savedURL = url

            // Phase 1 & 2 in background: atomic `pngquant --speed 1` write followed by atomic `oxipng -o max` write
            Task.detached(priority: .userInitiated) {
                let stage1 = PngSmartCompressor.compress(
                    rawPngData,
                    quality: quality,
                    mode: .fastQuantizeOnly
                )
                if stage1.compressedBytes < rawPngData.count {
                    try? stage1.data.write(to: savedURL, options: .atomic)
                }
                let finalRes = PngSmartCompressor.optimizeWithOxipng(
                    stage1.data,
                    originalBytes: stage1.originalBytes,
                    usedPngquant: stage1.usedPngquant,
                    oxipngMax: true
                )
                if finalRes.compressedBytes < stage1.compressedBytes {
                    try? finalRes.data.write(to: savedURL, options: .atomic)
                }
                await MainActor.run {
                    onFinalCompressed?(savedURL, finalRes)
                }
            }
        } else {
            let encoded = try ImageEncoder.encode(cgImage, format: format, scale: effectiveScale)
            try encoded.write(to: url, options: .atomic)
        }
    }

    static func saveImage(
        for cgImage: CGImage,
        backingScale: Double? = nil,
        config: AirSnipConfig,
        forceDialog: Bool = false,
        chooseDestination: ChooseSaveDestination = chooseSaveDestination,
        onFinalCompressed: (@MainActor @Sendable (URL, PngCompressionResult) -> Void)? = nil
    ) -> SaveOutcome? {
        let resolvedScale = max(1.0, backingScale ?? Double(NSScreen.main?.backingScaleFactor ?? 2.0))
        if !forceDialog && !config.askBeforeSave {
            let dir = defaultSaveDirectoryURL(for: config)
            let baseName = config.nameStyle.formatBaseName()
            let fmt: ExportImageFormat = (config.lastSaveFormat == .webp && (cgImage.width > 16384 || cgImage.height > 16384))
                ? .png
                : config.lastSaveFormat
            let dest = uniqueSaveDestinationURL(directory: dir, baseName: baseName, ext: fmt.fileExtension)
            do {
                try writeEncodedImage(
                    cgImage,
                    to: dest,
                    format: fmt,
                    scale: resolvedScale,
                    smartCompress: config.smartPngCompression,
                    quality: config.pngCompressionQuality,
                    onFinalCompressed: onFinalCompressed
                )
                return SaveOutcome(url: dest, updatePreferences: nil)
            } catch {
                // Directory unavailable or read-only -> fall back to Save As panel so screenshot is never lost
            }
        }
        guard let selection = chooseDestination(config) else { return nil }
        var url = selection.url
        if url.pathExtension.lowercased() != selection.format.fileExtension {
            url = url.deletingPathExtension().appendingPathExtension(selection.format.fileExtension)
        }

        do {
            try writeEncodedImage(
                cgImage,
                to: url,
                format: selection.format,
                scale: resolvedScale,
                smartCompress: selection.smartPngCompression,
                quality: selection.quality,
                onFinalCompressed: onFinalCompressed
            )
            let directory = url.deletingLastPathComponent().path
            return SaveOutcome(url: url, updatePreferences: {
                $0.lastSaveFormat = selection.format
                $0.smartPngCompression = selection.smartPngCompression
                $0.pngCompressionQuality = selection.quality
                $0.lastSaveDirectory = directory
            })
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.tr("保存失败", "Failed to Save", in: config.language)
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return nil
        }
    }

    static func chooseSaveDestination(config: AirSnipConfig) -> SavePanelSelection? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = L10n.tr("保存截图", "Save Screenshot")
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        var chosenFormat = config.lastSaveFormat
        var chosenSmartCompress = config.smartPngCompression
        var chosenQuality = config.pngCompressionQuality

        let baseName = config.nameStyle.formatBaseName()
        panel.nameFieldStringValue = "\(baseName).\(chosenFormat.fileExtension)"

        let defaultDir = defaultSaveDirectoryURL(for: config)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: defaultDir.path, isDirectory: &isDir), isDir.boolValue {
            panel.directoryURL = defaultDir
        } else {
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        }

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 386, height: 72))

        let fmtLabel = NSTextField(labelWithString: L10n.tr("格式：", "Format:"))
        fmtLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        fmtLabel.alignment = .right
        fmtLabel.lineBreakMode = .byClipping
        fmtLabel.frame = NSRect(x: 10, y: 41, width: 96, height: 20)

        let fmtPopup = NSPopUpButton(frame: NSRect(x: 112, y: 37, width: 132, height: 28), pullsDown: false)
        for fmt in ExportImageFormat.allCases {
            fmtPopup.addItem(withTitle: fmt.displayName)
        }
        if let idx = ExportImageFormat.allCases.firstIndex(of: chosenFormat) {
            fmtPopup.selectItem(at: idx)
        }

        let compLabel = NSTextField(labelWithString: L10n.tr("无损压缩：", "Compress:"))
        compLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        compLabel.alignment = .right
        compLabel.lineBreakMode = .byClipping
        compLabel.frame = NSRect(x: 10, y: 11, width: 96, height: 20)

        let compSwitch = NSSwitch(frame: NSRect(x: 114, y: 9, width: 42, height: 24))
        compSwitch.state = chosenSmartCompress ? .on : .off

        let qualityPopup = NSPopUpButton(frame: NSRect(x: 164, y: 7, width: 112, height: 28), pullsDown: false)
        for q in PngCompressionQualityPreset.allCases {
            qualityPopup.addItem(withTitle: q.title(in: config.language))
        }
        if let qIdx = PngCompressionQualityPreset.allCases.firstIndex(of: chosenQuality) {
            qualityPopup.selectItem(at: qIdx)
        }

        func syncAccessoryStates() {
            let isPng = (chosenFormat == .png)
            compSwitch.isEnabled = isPng
            compLabel.alphaValue = isPng ? 1.0 : 0.45
            qualityPopup.isEnabled = isPng && chosenSmartCompress
        }
        syncAccessoryStates()

        @MainActor
        final class SaveAccessoryTarget: NSObject {
            let panel: NSSavePanel
            let compSwitch: NSSwitch
            let qualityPopup: NSPopUpButton
            var onFormatChange: (ExportImageFormat) -> Void
            var onCompressToggle: (Bool) -> Void
            var onQualityChange: (PngCompressionQualityPreset) -> Void

            init(
                panel: NSSavePanel,
                compSwitch: NSSwitch,
                qualityPopup: NSPopUpButton,
                onFormatChange: @escaping (ExportImageFormat) -> Void,
                onCompressToggle: @escaping (Bool) -> Void,
                onQualityChange: @escaping (PngCompressionQualityPreset) -> Void
            ) {
                self.panel = panel
                self.compSwitch = compSwitch
                self.qualityPopup = qualityPopup
                self.onFormatChange = onFormatChange
                self.onCompressToggle = onCompressToggle
                self.onQualityChange = onQualityChange
            }

            @objc func formatChanged(_ sender: NSPopUpButton) {
                let idx = max(0, min(ExportImageFormat.allCases.count - 1, sender.indexOfSelectedItem))
                let fmt = ExportImageFormat.allCases[idx]
                onFormatChange(fmt)
                let current = (panel.nameFieldStringValue as NSString).deletingPathExtension
                let stem = current.isEmpty ? "isnip" : current
                panel.nameFieldStringValue = "\(stem).\(fmt.fileExtension)"
            }

            @objc func compressToggled(_ sender: NSSwitch) {
                onCompressToggle(sender.state == .on)
            }

            @objc func qualityChanged(_ sender: NSPopUpButton) {
                let idx = max(0, min(PngCompressionQualityPreset.allCases.count - 1, sender.indexOfSelectedItem))
                onQualityChange(PngCompressionQualityPreset.allCases[idx])
            }
        }

        let helper = SaveAccessoryTarget(
            panel: panel,
            compSwitch: compSwitch,
            qualityPopup: qualityPopup,
            onFormatChange: { newFmt in
                chosenFormat = newFmt
                syncAccessoryStates()
            },
            onCompressToggle: { enabled in
                chosenSmartCompress = enabled
                syncAccessoryStates()
            },
            onQualityChange: { newQ in
                chosenQuality = newQ
            }
        )
        fmtPopup.target = helper
        fmtPopup.action = #selector(SaveAccessoryTarget.formatChanged(_:))
        compSwitch.target = helper
        compSwitch.action = #selector(SaveAccessoryTarget.compressToggled(_:))
        qualityPopup.target = helper
        qualityPopup.action = #selector(SaveAccessoryTarget.qualityChanged(_:))

        accessory.addSubview(fmtLabel)
        accessory.addSubview(fmtPopup)
        accessory.addSubview(compLabel)
        accessory.addSubview(compSwitch)
        accessory.addSubview(qualityPopup)
        panel.accessoryView = accessory

        let response = panel.runModal()
        _ = helper // keep alive during modal loop
        guard response == .OK, let url = panel.url else {
            return nil
        }
        return SavePanelSelection(
            url: url, format: chosenFormat, smartPngCompression: chosenSmartCompress, quality: chosenQuality
        )
    }
}

@MainActor
public final class GlobalHotkeyManager {
    public enum Action: UInt32 {
        case screenshot = 1
        case pin = 2
        case pinBorderToggle = 3
        case ocrCapture = 4
        case longshotCapture = 5
        case windowCapture = 6
        case translateSelection = 7
        case translateCapture = 8
    }

    private static let globalSignature = OSType(0x4153_4E50)    // 'ASNP'
    private static let transientSignature = OSType(0x4C53_4854) // 'LSHT'

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var transientHotKeyRefs: [EventHotKeyRef] = []
    private var transientHandler: ((UInt32) -> Void)?
    private var mouseMonitor: Any?
    private var boundMouseActions: [MouseExtraButton: Action] = [:]
    public var onTrigger: ((Action) -> Void)?

    nonisolated(unsafe) private static weak var sharedInstance: GlobalHotkeyManager?
    public static var shared: GlobalHotkeyManager? { sharedInstance }

    public init() {
        Self.sharedInstance = self
        installCarbonHandler()
    }

    private func installCarbonHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            if status == noErr {
                if hkID.signature == GlobalHotkeyManager.transientSignature {
                    let id = hkID.id
                    Task { @MainActor in
                        GlobalHotkeyManager.sharedInstance?.transientHandler?(id)
                    }
                } else if hkID.signature == GlobalHotkeyManager.globalSignature,
                          let action = Action(rawValue: hkID.id) {
                    Task { @MainActor in
                        GlobalHotkeyManager.sharedInstance?.onTrigger?(action)
                    }
                }
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &eventHandlerRef)
    }

    /// Registers temporary session-scoped Carbon hotkeys (e.g., `Enter`, `Space`, `Esc`, `⌘S` during Longshot)
    /// that reliably intercept and consume keystrokes even when a browser or other app owns focus.
    /// Returns the set of `id`s that were successfully registered via Carbon.
    @discardableResult
    public func registerTransientHotKeys(
        _ specs: [(id: UInt32, keyCode: Int, modifiers: UInt32)],
        onPress: @escaping (UInt32) -> Void
    ) -> Set<UInt32> {
        unregisterTransientHotKeys()
        transientHandler = onPress
        var registered = Set<UInt32>()
        for spec in specs {
            let hkID = EventHotKeyID(signature: Self.transientSignature, id: spec.id)
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(
                UInt32(spec.keyCode),
                spec.modifiers,
                hkID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if st == noErr, let ref {
                transientHotKeyRefs.append(ref)
                registered.insert(spec.id)
            }
        }
        return registered
    }

    public func unregisterTransientHotKeys() {
        for ref in transientHotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        transientHotKeyRefs.removeAll()
        transientHandler = nil
    }

    @discardableResult
    public func apply(hotkeys: HotkeyConfig, lang: AppLanguage = L10n.current) -> [String] {
        unregisterAll()
        var failures: [String] = []

        let items: [(Action, String, HotkeyBinding)] = [
            (.screenshot, L10n.tr("截图", "Capture Area", in: lang), hotkeys.screenshot),
            (.windowCapture, L10n.tr("窗体截图", "Capture Window", in: lang), hotkeys.windowCapture),
            (.longshotCapture, L10n.tr("页面长截图", "Scrolling Capture", in: lang), hotkeys.longshotCapture),
            (.ocrCapture, L10n.tr("截图识字", "Capture & OCR", in: lang), hotkeys.ocrCapture),
            (.translateSelection, L10n.tr("划词翻译", "Translate Selection", in: lang), hotkeys.translateSelection),
            (.translateCapture, L10n.tr("截图翻译", "Capture & Translate", in: lang), hotkeys.translateCapture),
            (.pin, L10n.tr("贴图或恢复", "Pin or Restore", in: lang), hotkeys.pin),
            (.pinBorderToggle, L10n.tr("贴图边框", "Pin Border", in: lang), hotkeys.pinBorderToggle),
        ]

        let signature = OSType(0x4153_4E50) // 'ASNP'
        for (action, title, binding) in items {
            if binding.isUnbound { continue }
            if let mb = binding.mouseButton {
                boundMouseActions[mb] = action
                continue
            }
            guard let kc = binding.keyCode else { continue }
            let hkID = EventHotKeyID(signature: signature, id: action.rawValue)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(kc),
                binding.modifiers.carbonFlags,
                hkID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
            } else {
                let keyStr = binding.displayString(in: lang)
                if lang.isEnglish {
                    failures.append("\(title) (\(keyStr)) is already in use")
                } else {
                    failures.append("\(title)（\(keyStr)）已被占用")
                }
            }
        }

        if !boundMouseActions.isEmpty {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { [weak self] ev in
                guard let btn = MouseExtraButton(rawValue: ev.buttonNumber) else { return }
                Task { @MainActor in
                    if let act = self?.boundMouseActions[btn] {
                        self?.onTrigger?(act)
                    }
                }
            }
        }
        return failures
    }

    public func unregisterAll() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        boundMouseActions.removeAll()
        if let mon = mouseMonitor {
            NSEvent.removeMonitor(mon)
            mouseMonitor = nil
        }
    }
}

public enum LaunchAtLoginManager {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            return false
        }
    }
}

public struct UpdateReleaseInfo: Sendable {
    public let version: String
    public let htmlURL: URL
    public let downloadURL: URL?
    public let body: String
}

public enum UpdateChecker {
    public static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.3.12"
    }

    public static var releaseRepo: String {
        (Bundle.main.infoDictionary?["AirSnipUpdateRepository"] as? String) ?? "zzusec/isnip"
    }

    public static func checkLatest() async -> Result<UpdateReleaseInfo?, Error> {
        guard let apiURL = URL(string: "https://api.github.com/repos/\(releaseRepo)/releases/latest") else {
            return .success(nil)
        }
        var req = URLRequest(url: apiURL)
        req.timeoutInterval = 8
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 404 {
                return .success(nil)
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let htmlStr = json["html_url"] as? String,
                  let htmlURL = URL(string: htmlStr) else {
                return .success(nil)
            }
            let remoteVer = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard isVersionNewer(remoteVer, than: currentVersion) else {
                return .success(nil)
            }
            let notes = (json["body"] as? String) ?? ""
            var dmgURL: URL?
            if let assets = json["assets"] as? [[String: Any]] {
                let parsed: [(name: String, url: String)] = assets.compactMap { asset in
                    guard let name = asset["name"] as? String,
                          let dl = asset["browser_download_url"] as? String else {
                        return nil
                    }
                    return (name: name, url: dl)
                }
                dmgURL = ReleaseAssetSelector.selectDownloadURL(assets: parsed)
            }
            return .success(UpdateReleaseInfo(version: remoteVer, htmlURL: htmlURL, downloadURL: dmgURL, body: notes))
        } catch {
            return .failure(error)
        }
    }

    public static func isVersionNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").compactMap { Int($0) }
        let b = current.split(separator: ".").compactMap { Int($0) }
        let n = max(a.count, b.count)
        for i in 0..<n {
            let va = i < a.count ? a[i] : 0
            let vb = i < b.count ? b[i] : 0
            if va != vb { return va > vb }
        }
        return false
    }
}

@MainActor
public enum ToastHUD {
    private static var activeWindow: NSPanel?
    private static var dismissTask: Task<Void, Never>?

    public static func show(
        _ message: String,
        symbol: String = "checkmark",
        tint: NSColor? = nil,
        duration: Double = 1.45
    ) {
        dismissTask?.cancel()
        activeWindow?.orderOut(nil)

        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bgColor = isDark
            ? NSColor(srgbRed: 0.110, green: 0.110, blue: 0.125, alpha: 0.98)
            : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.98)
        let borderColor = isDark
            ? NSColor(srgbRed: 0.185, green: 0.185, blue: 0.212, alpha: 1.0)
            : NSColor(srgbRed: 0.886, green: 0.886, blue: 0.906, alpha: 1.0)
        let primaryText = isDark
            ? NSColor(srgbRed: 0.957, green: 0.957, blue: 0.965, alpha: 1.0)
            : NSColor(srgbRed: 0.094, green: 0.094, blue: 0.106, alpha: 1.0)
        let iconTint = tint ?? primaryText

        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        let rawTextWidth = ceil((message as NSString).size(withAttributes: [.font: font]).width)
        let maxW = min(screenFrame.width - 48, 520)
        let iconSide: CGFloat = 15
        let iconGap: CGFloat = 7
        let maxTextW = max(60, maxW - 28 - iconSide - iconGap)
        let textWidth = min(rawTextWidth, maxTextW)
        let groupW = iconSide + iconGap + textWidth
        let w = min(maxW, max(116, ceil(groupW + 28)))
        let h: CGFloat = 34

        let targetY = screenFrame.maxY - 56
        let startFrame = NSRect(
            x: round(screenFrame.midX - w * 0.5),
            y: targetY + 5,
            width: w,
            height: h
        )
        let finalFrame = NSRect(
            x: round(screenFrame.midX - w * 0.5),
            y: targetY,
            width: w,
            height: h
        )

        let panel = NSPanel(
            contentRect: startFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let cardView = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        cardView.wantsLayer = true
        cardView.layer?.backgroundColor = bgColor.cgColor
        cardView.layer?.cornerRadius = 9.0
        cardView.layer?.cornerCurve = .continuous
        cardView.layer?.masksToBounds = true
        cardView.layer?.borderWidth = 1.0
        cardView.layer?.borderColor = borderColor.cgColor

        let groupStartX = round((w - groupW) * 0.5)
        let symCfg = NSImage.SymbolConfiguration(pointSize: 12.0, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [iconTint]))
        if let symImg = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(symCfg) {
            let iconView = NSImageView(image: symImg)
            iconView.frame = NSRect(x: groupStartX, y: round((h - iconSide) * 0.5), width: iconSide, height: iconSide)
            cardView.addSubview(iconView)
        }

        let label = NSTextField(labelWithString: message)
        label.font = font
        label.textColor = primaryText
        label.alignment = .left
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.frame = NSRect(
            x: groupStartX + iconSide + iconGap,
            y: round((h - 18) * 0.5),
            width: textWidth + 2,
            height: 18
        )
        cardView.addSubview(label)

        panel.contentView = cardView
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
            panel.animator().setFrame(finalFrame, display: true)
        }
        activeWindow = panel

        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in
                    panel.orderOut(nil)
                }
            })
        }
    }
}
