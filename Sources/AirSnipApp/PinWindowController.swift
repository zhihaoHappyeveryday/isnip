import AppKit
import Carbon
import Combine
import AirSnipCore

@MainActor
public final class PinManager: ObservableObject {
    @Published public private(set) var windows: [PinWindowController] = []
    let pasteboard: NSPasteboard
    private let history: ClosedPinHistory
    private let historyCloseTime: () -> Date
    private let historyRootURL: (AirSnipConfig) -> URL
    private var historyMountObserver: AnyCancellable?
    public var onRequestAnnotatePin: ((PinWindowController) -> Void)?
    public var onRequestOCRPin: ((PinWindowController) -> Void)?
    public var getConfig: (() -> AirSnipConfig)?
    public var updateConfig: (((inout AirSnipConfig) -> Void) -> Void)?

    public convenience init(pasteboard: NSPasteboard = .general) {
        let temporaryHistory = TemporaryPinHistoryDirectory()
        self.init(pasteboard: pasteboard, historyConfigURL: nil) { _ in temporaryHistory.url }
    }

    init(
        pasteboard: NSPasteboard,
        historyConfigURL: URL?,
        historyCloseTime: @escaping () -> Date = Date.init,
        historyRootURL: @escaping (AirSnipConfig) -> URL
    ) {
        self.pasteboard = pasteboard
        self.historyCloseTime = historyCloseTime
        self.historyRootURL = historyRootURL
        history = ClosedPinHistory(configURL: historyConfigURL)
        history.onWriteFailure = { [weak self] in
            self?.showHistoryWarning("贴图历史写入失败，这些贴图无法恢复", "Some closed pins could not be saved for recovery")
        }
        historyMountObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak history] _ in
                history?.cleanUnusedFiles()
            }
    }

    public var count: Int { windows.count }
    public var hasClickThroughPins: Bool { windows.contains { $0.isClickThrough } }

    @discardableResult
    public func createPin(
        cgImage: CGImage,
        backingScale: Double,
        preferredScreenOriginAppKit: CGPoint?,
        config: AirSnipConfig,
        originalText: String? = nil
    ) -> Bool {
        guard canOpenPin(config: config) else { return false }
        let pointW = max(32.0, Double(cgImage.width) / max(1.0, backingScale))
        let pointH = max(32.0, Double(cgImage.height) / max(1.0, backingScale))
        let size = NSSize(width: pointW, height: pointH)

        let screen = NSScreen.main ?? NSScreen.screens.first
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let origin: NSPoint
        if config.pinPosition == .original, let pref = preferredScreenOriginAppKit {
            origin = pref
        } else {
            let cascade = CGFloat(windows.count % 6) * 18.0
            origin = NSPoint(
                x: vis.midX - size.width * 0.5 + cascade,
                y: vis.midY - size.height * 0.5 - cascade
            )
        }

        let controller = PinWindowController(
            cgImage: cgImage,
            baseSize: size,
            backingScale: backingScale,
            origin: origin,
            showBorder: config.pinBorder,
            manager: self,
            originalText: originalText
        )
        windows.append(controller)
        controller.show()
        return true
    }

    public func remove(_ pin: PinWindowController) {
        guard let index = windows.firstIndex(where: { $0 === pin }) else { return }
        let closedAt = historyCloseTime()
        pin.window.orderOut(nil)
        rememberClosedPins([windows.remove(at: index)], closedAt: closedAt)
    }

    private func rememberClosedPins(_ pins: [PinWindowController], closedAt: Date) {
        let config = getConfig?() ?? AirSnipConfig()
        guard config.pinHistoryLimit > 0 else { return }
        history.remember(
            pins.map { $0.snapshot() }, limit: config.pinHistoryLimit, historyRoot: historyRootURL(config), closedAt: closedAt
        )
    }

    func trimClosedHistory(to limit: Int) {
        history.trim(to: limit)
    }

    func finishHistoryWrites() {
        history.finishPendingWrites()
    }

    public func restoreLastClosedPin(config: AirSnipConfig) {
        history.cleanUnusedFiles()
        guard config.pinHistoryLimit > 0, !history.isEmpty, canOpenPin(config: config) else { return }
        let result = history.restoreLast()
        if result.skippedUnreadable {
            showHistoryWarning("部分贴图历史文件无法读取", "Some closed pin files could not be read")
        }
        guard let snapshot = result.snapshot else { return }
        let pin = PinWindowController(restoring: snapshot, manager: self)
        windows.append(pin)
        pin.show()
    }

    private func showHistoryWarning(_ zh: String, _ en: String) {
        ToastHUD.show(L10n.tr(zh, en, in: getConfig?().language), symbol: "exclamationmark.triangle", tint: .systemOrange)
    }

    private func canOpenPin(config: AirSnipConfig) -> Bool {
        guard count < config.pinMaxCount else {
            ToastHUD.show(L10n.tr("已达上限（\(config.pinMaxCount) 张）", "Pin limit reached (\(config.pinMaxCount))", in: config.language))
            return false
        }
        return true
    }

    public func closeAll() {
        guard !windows.isEmpty else { return }
        let closedAt = historyCloseTime()
        let pins = windows
        for pin in pins {
            pin.window.orderOut(nil)
        }
        windows.removeAll()
        rememberClosedPins(pins, closedAt: closedAt)
    }

    public func restoreAllClickThrough() {
        for w in windows where w.isClickThrough {
            w.setClickThrough(false)
        }
        ToastHUD.show(L10n.tr("已恢复贴图交互", "Click-through disabled"))
    }

    public func toggleAllBorders() {
        let target = !(windows.first?.showBorder ?? true)
        for w in windows {
            w.setShowBorder(target)
        }
        updateConfig? { $0.pinBorder = target }
        ToastHUD.show(target ? L10n.tr("边框已开启", "Pin borders shown") : L10n.tr("边框已隐藏", "Pin borders hidden"))
    }
}

private final class TemporaryPinHistoryDirectory {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("isnip-pin-history-\(UUID().uuidString)", isDirectory: true)

    deinit { try? FileManager.default.removeItem(at: url) }
}

private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
public final class PinWindowController: NSObject {
    public let window: NSPanel
    public private(set) var cgImage: CGImage
    public private(set) var baseSize: NSSize
    public let backingScale: Double
    let originalText: String?
    public private(set) var zoomScale: CGFloat = 1.0
    public private(set) var opacity: CGFloat = 1.0
    public private(set) var showBorder: Bool
    public private(set) var isClickThrough: Bool = false

    private weak var manager: PinManager?
    private let contentView: PinCanvasView

    public init(
        cgImage: CGImage,
        baseSize: NSSize,
        backingScale: Double,
        origin: NSPoint,
        showBorder: Bool,
        manager: PinManager,
        originalText: String? = nil
    ) {
        self.cgImage = cgImage
        self.baseSize = baseSize
        self.backingScale = backingScale
        self.originalText = originalText
        self.showBorder = showBorder
        self.manager = manager

        let rect = NSRect(origin: origin, size: baseSize)
        let panel = PinPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false

        self.contentView = PinCanvasView(frame: NSRect(origin: .zero, size: baseSize))
        self.window = panel
        super.init()

        contentView.owner = self
        panel.contentView = contentView
        contentView.needsDisplay = true
    }

    fileprivate convenience init(restoring snapshot: PinSnapshot, manager: PinManager) {
        let display = snapshot.displayState
        self.init(
            cgImage: snapshot.image, baseSize: display.baseSize, backingScale: display.backingScale,
            origin: display.frame.origin, showBorder: display.showBorder, manager: manager, originalText: snapshot.originalText
        )
        zoomScale = display.zoomScale
        opacity = display.preferredOpacity
        isClickThrough = display.isClickThrough
        window.ignoresMouseEvents = display.isClickThrough
        window.alphaValue = display.effectiveWindowOpacity
        window.setFrame(display.frame, display: false)
        contentView.frame = NSRect(origin: .zero, size: display.frame.size)
    }

    public func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(contentView)
    }

    fileprivate func snapshot() -> PinSnapshot {
        PinSnapshot(
            image: cgImage, originalText: originalText,
            displayState: PinDisplayState(
                frame: window.frame, baseSize: baseSize, backingScale: backingScale, zoomScale: zoomScale,
                preferredOpacity: opacity, effectiveWindowOpacity: window.alphaValue,
                showBorder: showBorder, isClickThrough: isClickThrough
            )
        )
    }

    func finishInlineEdit(image: CGImage? = nil) {
        guard manager?.windows.contains(where: { $0 === self }) == true else { return }
        if let image {
            updateImage(image)
        }
        show()
    }

    public func updateImage(_ newImage: CGImage) {
        self.cgImage = newImage
        self.baseSize = NSSize(
            width: max(32.0, Double(newImage.width) / max(1.0, backingScale)),
            height: max(32.0, Double(newImage.height) / max(1.0, backingScale))
        )
        self.zoomScale = 1.0
        var frame = window.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        frame.size = baseSize
        frame.origin = NSPoint(x: center.x - baseSize.width * 0.5, y: center.y - baseSize.height * 0.5)
        window.setFrame(frame, display: true)
        contentView.frame = NSRect(origin: .zero, size: baseSize)
        contentView.needsDisplay = true
    }

    public func setShowBorder(_ on: Bool) {
        showBorder = on
        contentView.needsDisplay = true
    }

    public func setClickThrough(_ on: Bool) {
        isClickThrough = on
        window.ignoresMouseEvents = on
        window.alphaValue = on ? min(opacity, 0.82) : opacity
        if on {
            ToastHUD.show(L10n.tr("已开启穿透（菜单栏可恢复）", "Click-through enabled (restore from menu bar)"))
        }
    }

    public func adjustZoom(delta: CGFloat, anchorInWindow: NSPoint) {
        let factor: CGFloat = delta > 0 ? 1.08 : 0.925
        let newScale = max(0.2, min(4.0, zoomScale * factor))
        guard abs(newScale - zoomScale) > 0.001 else { return }

        let oldFrame = window.frame
        let relX = anchorInWindow.x / max(1, oldFrame.width)
        let relY = anchorInWindow.y / max(1, oldFrame.height)

        zoomScale = newScale
        let newW = round(baseSize.width * zoomScale)
        let newH = round(baseSize.height * zoomScale)
        let screenAnchorX = oldFrame.minX + anchorInWindow.x
        let screenAnchorY = oldFrame.minY + anchorInWindow.y
        let newOrigin = NSPoint(x: screenAnchorX - newW * relX, y: screenAnchorY - newH * relY)

        window.setFrame(NSRect(origin: newOrigin, size: NSSize(width: newW, height: newH)), display: true)
        contentView.frame = NSRect(x: 0, y: 0, width: newW, height: newH)
        contentView.showBadgeTemporarily("\(Int((zoomScale * 100).rounded()))%")
        contentView.needsDisplay = true
    }

    public func adjustOpacity(delta: CGFloat) {
        let step: CGFloat = delta > 0 ? 0.06 : -0.06
        opacity = max(0.15, min(1.0, opacity + step))
        window.alphaValue = opacity
        let pct = Int((opacity * 100).rounded())
        contentView.showBadgeTemporarily(L10n.tr("透明度 \(pct)%", "Opacity \(pct)%"))
    }

    public func resetTransform() {
        zoomScale = 1.0
        opacity = 1.0
        window.alphaValue = 1.0
        var f = window.frame
        f.size = baseSize
        window.setFrame(f, display: true)
        contentView.frame = NSRect(origin: .zero, size: baseSize)
        contentView.needsDisplay = true
    }

    public func requestInlineAnnotate() {
        manager?.onRequestAnnotatePin?(self)
    }

    public func requestOCR() {
        manager?.onRequestOCRPin?(self)
    }

    public func copyToClipboard() {
        let cfg = manager?.getConfig?()
        OutputService.copyImageToClipboard(
            cgImage, backingScale: backingScale, config: cfg, to: manager?.pasteboard ?? .general
        ) { _ in
            ToastHUD.show(L10n.tr("已复制", "Copied"))
        }
    }

    func copyOriginalText() {
        guard let originalText else { return }
        OutputService.copyStringToClipboard(originalText, to: manager?.pasteboard ?? .general)
        ToastHUD.show(L10n.tr("已复制原文", "Original Text Copied"))
    }

    public func savePin(forceDialog: Bool = false) {
        guard let config = manager?.getConfig?(),
              let saved = OutputService.saveImage(
                  for: cgImage, backingScale: backingScale, config: config, forceDialog: forceDialog
              ) else { return }
        if let updatePreferences = saved.updatePreferences {
            manager?.updateConfig?(updatePreferences)
        }
        if config.showCompletionToast {
            ToastHUD.show(L10n.tr("已保存", "Saved"))
        }
    }

    public func closeSelf() {
        manager?.remove(self)
    }

    public func closeAllPins() {
        manager?.closeAll()
    }
}

@MainActor
private final class PinCanvasView: NSView {
    weak var owner: PinWindowController?
    private var dragStartMouseScreen: NSPoint?
    private var dragStartWindowOrigin: NSPoint?
    private var badgeText: String?
    private var badgeClearTask: Task<Void, Never>?

    override var acceptsFirstResponder: Bool { true }

    func showBadgeTemporarily(_ text: String) {
        badgeText = text
        needsDisplay = true
        badgeClearTask?.cancel()
        badgeClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 850_000_000)
            guard !Task.isCancelled else { return }
            self?.badgeText = nil
            self?.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let owner, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r: CGFloat = 6.5
        let clipPath = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)

        ctx.saveGState()
        ctx.addPath(clipPath)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(owner.cgImage, in: bounds)
        ctx.restoreGState()

        if owner.showBorder {
            let outerRect = bounds.insetBy(dx: 0.65, dy: 0.65)
            let outerPath = CGPath(roundedRect: outerRect, cornerWidth: max(1, r - 0.65), cornerHeight: max(1, r - 0.65), transform: nil)
            ctx.addPath(outerPath)
            ctx.setStrokeColor(CGColor(srgbRed: 0.094, green: 0.094, blue: 0.106, alpha: 0.72))
            ctx.setLineWidth(1.3)
            ctx.strokePath()

            let innerRect = bounds.insetBy(dx: 1.55, dy: 1.55)
            let innerPath = CGPath(roundedRect: innerRect, cornerWidth: max(1, r - 1.55), cornerHeight: max(1, r - 1.55), transform: nil)
            ctx.addPath(innerPath)
            ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.85))
            ctx.setLineWidth(0.8)
            ctx.strokePath()
        } else {
            // Subtle crisp hairline rim even when border is toggled off so light-on-light pins stay defined
            let insetRect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let borderPath = CGPath(roundedRect: insetRect, cornerWidth: max(1, r - 0.5), cornerHeight: max(1, r - 0.5), transform: nil)
            ctx.addPath(borderPath)
            ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.14))
            ctx.setLineWidth(0.8)
            ctx.strokePath()
        }

        if let badge = badgeText {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            let fg = isDark
                ? NSColor(srgbRed: 0.957, green: 0.957, blue: 0.965, alpha: 1)
                : NSColor(srgbRed: 0.094, green: 0.094, blue: 0.106, alpha: 1)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
            let sz = (badge as NSString).size(withAttributes: attrs)
            let pill = NSRect(x: 9, y: bounds.height - sz.height - 15, width: sz.width + 16, height: sz.height + 7)
            let path = NSBezierPath(roundedRect: pill, xRadius: 6.0, yRadius: 6.0)
            (isDark ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.125, alpha: 0.96) : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.96)).setFill()
            path.fill()
            (isDark ? NSColor(srgbRed: 0.22, green: 0.22, blue: 0.26, alpha: 1) : NSColor(srgbRed: 0.86, green: 0.86, blue: 0.89, alpha: 1)).setStroke()
            path.lineWidth = 1.0
            path.stroke()
            (badge as NSString).draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + 3.5), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            owner?.closeSelf()
            return
        }
        dragStartMouseScreen = NSEvent.mouseLocation
        dragStartWindowOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startMouse = dragStartMouseScreen,
              let startOrigin = dragStartWindowOrigin,
              let win = window else { return }
        let cur = NSEvent.mouseLocation
        win.setFrameOrigin(NSPoint(
            x: startOrigin.x + (cur.x - startMouse.x),
            y: startOrigin.y + (cur.y - startMouse.y)
        ))
    }

    override func mouseUp(with event: NSEvent) {
        dragStartMouseScreen = nil
        dragStartWindowOrigin = nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard let owner else { return }
        let delta = abs(event.scrollingDeltaY) > 0.01 ? event.scrollingDeltaY : event.deltaY
        guard abs(delta) > 0.01 else { return }
        let flags = event.modifierFlags
        if flags.contains(.control) || flags.contains(.command) {
            owner.adjustOpacity(delta: delta)
        } else {
            let loc = convert(event.locationInWindow, from: nil)
            owner.adjustZoom(delta: delta, anchorInWindow: loc)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let owner, let win = window else { return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 5.0 : 1.0
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if (flags.contains(.command) || flags.contains(.control)), event.keyCode == UInt16(kVK_ANSI_C) {
            if flags.intersection([.command, .control, .option, .shift]) == [.command, .shift],
               owner.originalText != nil {
                owner.copyOriginalText()
            } else {
                owner.copyToClipboard()
            }
            return
        }
        if (flags.contains(.command) || flags.contains(.control)), event.keyCode == UInt16(kVK_ANSI_S) {
            owner.savePin(forceDialog: flags.contains(.shift))
            return
        }

        switch Int(event.keyCode) {
        case kVK_Escape:
            owner.closeSelf()
        case kVK_Space:
            owner.requestInlineAnnotate()
        case kVK_ANSI_T:
            owner.requestOCR()
        case kVK_LeftArrow:
            win.setFrameOrigin(NSPoint(x: win.frame.origin.x - step, y: win.frame.origin.y))
        case kVK_RightArrow:
            win.setFrameOrigin(NSPoint(x: win.frame.origin.x + step, y: win.frame.origin.y))
        case kVK_UpArrow:
            win.setFrameOrigin(NSPoint(x: win.frame.origin.x, y: win.frame.origin.y + step))
        case kVK_DownArrow:
            win.setFrameOrigin(NSPoint(x: win.frame.origin.x, y: win.frame.origin.y - step))
        default:
            super.keyDown(with: event)
        }
    }

    private func pinMenuIcon(_ symbolName: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .medium)
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        img?.isTemplate = true
        return img
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner else { return nil }
        let menu = NSMenu(title: L10n.tr("贴图", "Pin"))
        let editItem = NSMenuItem(title: L10n.tr("标注", "Annotate"), action: #selector(onEdit), keyEquivalent: " ")
        editItem.keyEquivalentModifierMask = []
        editItem.image = pinMenuIcon("paintbrush.pointed")
        editItem.target = self
        menu.addItem(editItem)

        let ocrItem = NSMenuItem(title: L10n.tr("识字", "Extract Text (OCR)"), action: #selector(onOCR), keyEquivalent: "t")
        ocrItem.keyEquivalentModifierMask = []
        ocrItem.image = pinMenuIcon("text.viewfinder")
        ocrItem.target = self
        menu.addItem(ocrItem)

        let copyItem = NSMenuItem(title: L10n.tr("复制", "Copy"), action: #selector(onCopy), keyEquivalent: "c")
        copyItem.image = pinMenuIcon("doc.on.doc")
        copyItem.target = self
        menu.addItem(copyItem)

        if owner.originalText != nil {
            let originalTextItem = NSMenuItem(
                title: L10n.tr("复制原文", "Copy Original Text"), action: #selector(onCopyOriginalText), keyEquivalent: "c"
            )
            originalTextItem.keyEquivalentModifierMask = [.command, .shift]
            originalTextItem.image = pinMenuIcon("doc.plaintext")
            originalTextItem.target = self
            menu.addItem(originalTextItem)
        }

        let saveItem = NSMenuItem(title: L10n.tr("保存", "Save"), action: #selector(onSave), keyEquivalent: "s")
        saveItem.image = pinMenuIcon("square.and.arrow.down")
        saveItem.target = self
        menu.addItem(saveItem)

        let saveAsItem = NSMenuItem(title: L10n.tr("另存为…", "Save As…"), action: #selector(onSaveAs), keyEquivalent: "s")
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        saveAsItem.image = pinMenuIcon("folder")
        saveAsItem.target = self
        menu.addItem(saveAsItem)

        menu.addItem(.separator())

        let borderItem = NSMenuItem(
            title: owner.showBorder ? L10n.tr("隐藏边框", "Hide Border") : L10n.tr("显示边框", "Show Border"),
            action: #selector(onToggleBorder),
            keyEquivalent: ""
        )
        borderItem.image = pinMenuIcon("rectangle.inset.filled")
        borderItem.target = self
        menu.addItem(borderItem)

        let throughItem = NSMenuItem(title: L10n.tr("鼠标穿透", "Click-Through"), action: #selector(onClickThrough), keyEquivalent: "")
        throughItem.image = pinMenuIcon("cursorarrow.rays")
        throughItem.target = self
        menu.addItem(throughItem)

        let resetItem = NSMenuItem(title: L10n.tr("重置大小与透明度", "Reset Size & Opacity"), action: #selector(onReset), keyEquivalent: "")
        resetItem.image = pinMenuIcon("arrow.counterclockwise")
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(.separator())

        let closeItem = NSMenuItem(title: L10n.tr("关闭", "Close"), action: #selector(onClose), keyEquivalent: "\u{1b}")
        closeItem.keyEquivalentModifierMask = []
        closeItem.image = pinMenuIcon("xmark")
        closeItem.target = self
        menu.addItem(closeItem)

        let closeAllItem = NSMenuItem(title: L10n.tr("关闭全部", "Close All"), action: #selector(onCloseAll), keyEquivalent: "")
        closeAllItem.image = pinMenuIcon("xmark.circle")
        closeAllItem.target = self
        menu.addItem(closeAllItem)
        return menu
    }

    @objc private func onEdit() { owner?.requestInlineAnnotate() }
    @objc private func onOCR() { owner?.requestOCR() }
    @objc private func onCopy() { owner?.copyToClipboard() }
    @objc private func onCopyOriginalText() { owner?.copyOriginalText() }
    @objc private func onSave() { owner?.savePin(forceDialog: false) }
    @objc private func onSaveAs() { owner?.savePin(forceDialog: true) }
    @objc private func onToggleBorder() {
        guard let owner else { return }
        owner.setShowBorder(!owner.showBorder)
    }
    @objc private func onClickThrough() { owner?.setClickThrough(true) }
    @objc private func onReset() { owner?.resetTransform() }
    @objc private func onClose() { owner?.closeSelf() }
    @objc private func onCloseAll() { owner?.closeAllPins() }
}
