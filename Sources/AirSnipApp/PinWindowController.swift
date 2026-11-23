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
    private var historyActions: [() -> Void] = []
    private var isSubmittingHistoryActions = false
    private var isUpdatingHistoryLimit = false
    private var quitHistoryFailure: ClosedPinHistory.Failure?
    private(set) var isQuitting = false
    public var onRequestAnnotatePin: ((PinWindowController) -> Void)?
    public var onRequestOCRPin: ((PinWindowController) -> Void)?
    var onWillCloseAll: (() -> Void)?
    public var getConfig: (() -> AirSnipConfig)?
    public var updateConfig: ((@escaping (inout AirSnipConfig) -> Void) -> Void)?

    public convenience init(pasteboard: NSPasteboard = .general) {
        let temporaryHistory = TemporaryPinHistoryDirectory()
        self.init(pasteboard: pasteboard, historyConfigURL: nil) { _ in temporaryHistory.url }
    }

    init(
        pasteboard: NSPasteboard,
        historyConfigURL: URL?,
        historyCloseTime: @escaping () -> Date = Date.init,
        historyLimit: Int = AirSnipConfig.defaultPinHistoryLimit,
        historyRootURL: @escaping (AirSnipConfig) -> URL
    ) {
        self.pasteboard = pasteboard
        self.historyCloseTime = historyCloseTime
        self.historyRootURL = historyRootURL
        history = ClosedPinHistory(configURL: historyConfigURL, limit: historyLimit)
        history.onFailure = { [weak self] failure in
            guard let self else { return }
            if self.isQuitting {
                self.quitHistoryFailure = failure
            } else {
                self.showHistoryFailure(failure)
            }
        }
        historyMountObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak history] _ in
                history?.retryCleanup()
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
        guard !isQuitting, canOpenPin(config: config) else { return false }
        let pointW = max(32.0, Double(cgImage.width) / max(1.0, backingScale))
        let pointH = max(32.0, Double(cgImage.height) / max(1.0, backingScale))
        let size = NSSize(width: pointW, height: pointH)

        let preferredOrigin = config.pinPosition == .original ? preferredScreenOriginAppKit : nil
        let screen = preferredOrigin.flatMap { point in NSScreen.screens.first { $0.frame.contains(point) } }
            ?? NSScreen.main ?? NSScreen.screens.first
        let vis = screen?.visibleFrame ?? PinWindowController.defaultVisibleFrame

        let origin: NSPoint
        if let pref = preferredOrigin {
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
            originalText: originalText,
            visibleFrame: vis
        )
        windows.append(controller)
        controller.show()
        return true
    }

    public func remove(_ pin: PinWindowController) {
        guard let index = windows.firstIndex(where: { $0 === pin }) else { return }
        let closedAt = historyCloseTime()
        pin.hide()
        rememberClosedPins([windows.remove(at: index)], closedAt: closedAt)
    }

    private func rememberClosedPins(_ pins: [PinWindowController], closedAt: Date) {
        let snapshots = pins.map { $0.snapshot() }
        performHistoryAction { [weak self] in
            guard let self else { return }
            let config = self.getConfig?() ?? AirSnipConfig()
            self.history.remember(snapshots, historyRoot: self.historyRootURL(config), closedAt: closedAt)
        }
    }

    // A settings change must be applied before submitting any later close or restore.
    func performHistoryAction(_ action: @escaping () -> Void) {
        historyActions.append(action)
        submitHistoryActions()
    }

    private func submitHistoryActions() {
        guard !isSubmittingHistoryActions else { return }
        isSubmittingHistoryActions = true
        defer { isSubmittingHistoryActions = false }
        while !isUpdatingHistoryLimit, !historyActions.isEmpty {
            historyActions.removeFirst()()
        }
    }

    func updateHistoryLimit(to limit: Int, savingConfig: @escaping (Int) throws -> Void, completion: @escaping (Int) -> Void) {
        isUpdatingHistoryLimit = true
        history.updateLimit(to: limit, savingConfig: savingConfig) { [weak self] applied in
            completion(applied)
            self?.isUpdatingHistoryLimit = false
            self?.submitHistoryActions()
        }
    }

    func finishHistoryWrites(completion: @escaping () -> Void) {
        performHistoryAction { [history] in
            history.finishPendingWrites(completion: completion)
        }
    }

    public func restoreLastClosedPin(
        config: AirSnipConfig,
        handleClipboard: @escaping () -> Bool = { false },
        completion: @escaping () -> Void = {}
    ) {
        performHistoryAction { [weak self] in
            guard let self else {
                completion()
                return
            }
            self.restoreAfterSettings(config: config, handleClipboard: handleClipboard, completion: completion)
        }
    }

    private func restoreAfterSettings(
        config: AirSnipConfig,
        handleClipboard: @escaping () -> Bool,
        completion: @escaping () -> Void
    ) {
        var openedPin: PinWindowController?
        history.restoreLast(if: { [weak self] hasHistory in
            guard let self, !self.isQuitting, !handleClipboard() else { return false }
            return !hasHistory || self.canOpenPin(config: self.getConfig?() ?? config)
        }, accept: { [weak self] snapshot in
            guard let self, !self.isQuitting else { return false }
            guard let snapshot else { return true }
            guard self.canOpenPin(config: self.getConfig?() ?? config) else { return false }
            let pin = PinWindowController(restoring: snapshot, manager: self)
            openedPin = pin
            self.windows.append(pin)
            pin.show()
            return true
        }, completion: { [weak self] restored, skippedUnreadable in
            if let self, !restored, let pin = openedPin {
                pin.hide()
                self.windows.removeAll { $0 === pin }
            }
            if skippedUnreadable {
                self?.showHistoryWarning("部分贴图历史文件无法读取", "Some closed pin files could not be read")
            }
            completion()
        })
    }

    private func showHistoryFailure(_ failure: ClosedPinHistory.Failure) {
        let language = getConfig?().language
        switch failure {
        case .savePin:
            showHistoryWarning("部分贴图未存入历史，无法恢复", "Some pins were not saved to history and cannot be restored")
        case .trim:
            ToastHUD.show(
                L10n.tr("无法更新可恢复贴图数", "Could not update the recoverable pin limit", in: language),
                kind: .warning,
                detail: L10n.tr("请再试一次", "Please try again", in: language)
            )
        case .saveLimit:
            ToastHUD.show(
                L10n.tr("无法保存可恢复贴图数", "Could not save the recoverable pin limit", in: language),
                kind: .warning,
                detail: L10n.tr("请再试一次", "Please try again", in: language)
            )
        }
    }

    private func showHistoryWarning(_ zh: String, _ en: String) {
        ToastHUD.show(L10n.tr(zh, en, in: getConfig?().language), kind: .warning)
    }

    private func canOpenPin(config: AirSnipConfig) -> Bool {
        guard count < config.pinMaxCount else {
            ToastHUD.show(
                L10n.tr("贴图已达上限", "Pin limit reached", in: config.language),
                kind: .warning,
                detail: L10n.tr("关闭贴图，腾出位置后再试", "Close pins to make room, then try again", in: config.language),
                countText: "\(count) / \(config.pinMaxCount)"
            )
            return false
        }
        return true
    }

    public func closeAll() {
        onWillCloseAll?()
        guard !windows.isEmpty else { return }
        let closedAt = historyCloseTime()
        let pins = windows
        for pin in pins {
            pin.hide()
        }
        windows.removeAll()
        rememberClosedPins(pins, closedAt: closedAt)
    }

    func saveOpenPinsOnQuit(completion: @escaping () -> Void) {
        isQuitting = true
        closeAll()
        performHistoryAction { [history] in
            history.finishPendingWrites(enforcingLimit: true, completion: completion)
        }
    }

    func showQuitHistoryFailure() -> Bool {
        guard let quitHistoryFailure else { return false }
        showHistoryFailure(quitHistoryFailure)
        return true
    }

    public func restoreAllClickThrough() {
        for w in windows where w.isClickThrough {
            w.setClickThrough(false)
        }
        ToastHUD.show(L10n.tr("已恢复贴图交互", "Click-through disabled"), kind: .information, symbol: "cursorarrow")
    }

    public func toggleAllBorders() {
        let target = !(windows.first?.showBorder ?? true)
        for w in windows {
            w.setShowBorder(target)
        }
        updateConfig? { $0.pinBorder = target }
        ToastHUD.show(
            target ? L10n.tr("边框已开启", "Pin borders shown") : L10n.tr("边框已隐藏", "Pin borders hidden"),
            kind: .information,
            symbol: target ? "rectangle" : "rectangle.dashed"
        )
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

private struct PinViewport {
    let size: NSSize
    private(set) var imageRect: NSRect

    init(baseSize: NSSize, zoom: CGFloat, fitted: Bool, limit: NSSize) {
        var imageSize = NSSize(width: baseSize.width * zoom, height: baseSize.height * zoom)
        if !fitted, zoom != 1 {
            imageSize = NSSize(width: round(imageSize.width), height: round(imageSize.height))
        }
        size = NSSize(width: min(imageSize.width, limit.width), height: min(imageSize.height, limit.height))
        if fitted { imageSize = size }
        imageRect = NSRect(x: 0, y: size.height - imageSize.height, width: imageSize.width, height: imageSize.height)
    }

    var isClipped: Bool { imageRect.size != size }
    var isClippedVertically: Bool { imageRect.height > size.height }

    mutating func pan(to origin: NSPoint) {
        imageRect.origin = NSPoint(
            x: min(0, max(size.width - imageRect.width, origin.x)),
            y: min(0, max(size.height - imageRect.height, origin.y))
        )
    }
}

extension CGImage {
    func drawVisibleRegion(in context: CGContext, projectedTo imageRect: NSRect, clippedTo viewport: NSRect) {
        let visible = viewport.intersection(imageRect)
        guard !visible.isEmpty else { return }
        guard visible != imageRect else {
            context.draw(self, in: imageRect)
            return
        }
        // Core Graphics crops in top-down pixels. The drawing rectangles use bottom-up points.
        let scaleX = CGFloat(width) / imageRect.width
        let scaleY = CGFloat(height) / imageRect.height
        let source = NSRect(
            x: (visible.minX - imageRect.minX) * scaleX,
            y: (imageRect.maxY - visible.maxY) * scaleY,
            width: visible.width * scaleX,
            height: visible.height * scaleY
        ).integral.intersection(NSRect(x: 0, y: 0, width: width, height: height))
        guard let crop = cropping(to: source) else { return }
        let destination = NSRect(
            x: imageRect.minX + source.minX / scaleX,
            y: imageRect.maxY - source.maxY / scaleY,
            width: source.width / scaleX,
            height: source.height / scaleY
        )
        context.draw(crop, in: destination)
    }
}

@MainActor
public final class PinWindowController: NSObject, NSWindowDelegate {
    fileprivate static let defaultVisibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private static let minimumZoom: CGFloat = 0.2

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
    private var historyID: UUID?
    private var visibleFrame: NSRect
    private var isFitToWindow: Bool
    private var browsingHint: ToastHUD.Presentation?
    fileprivate private(set) var viewport: PinViewport

    var projectedImageFrame: NSRect {
        viewport.imageRect.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
    }

    fileprivate var canDragImageHorizontally: Bool {
        baseSize.height <= visibleFrame.height && viewport.isClipped && !viewport.isClippedVertically
    }

    public convenience init(
        cgImage: CGImage,
        baseSize: NSSize,
        backingScale: Double,
        origin: NSPoint,
        showBorder: Bool,
        manager: PinManager,
        originalText: String? = nil
    ) {
        let screen = Self.screen(containing: NSRect(origin: origin, size: baseSize))
        self.init(cgImage: cgImage, baseSize: baseSize, backingScale: backingScale, origin: origin,
                  showBorder: showBorder, manager: manager, originalText: originalText,
                  visibleFrame: screen?.visibleFrame ?? Self.defaultVisibleFrame)
    }

    fileprivate convenience init(
        cgImage: CGImage, baseSize: NSSize, backingScale: Double, origin: NSPoint, showBorder: Bool,
        manager: PinManager, originalText: String?, visibleFrame: NSRect
    ) {
        let frame = NSRect(origin: origin, size: baseSize)
        let display = PinDisplayState(
            frame: frame, baseSize: baseSize, backingScale: backingScale, zoomScale: 1,
            preferredOpacity: 1, effectiveWindowOpacity: 1, showBorder: showBorder, isClickThrough: false
        )
        self.init(cgImage: cgImage, display: display, manager: manager, originalText: originalText, visibleFrame: visibleFrame)
    }

    private init(
        cgImage: CGImage, display: PinDisplayState, manager: PinManager,
        originalText: String?, visibleFrame: NSRect
    ) {
        let fit = Self.fitScale(for: display.baseSize, in: visibleFrame)
        let fitted = fit < 1
        let zoom = fitted ? fit : max(Self.minimumZoom, display.zoomScale)
        var viewport = PinViewport(baseSize: display.baseSize, zoom: zoom, fitted: fitted, limit: visibleFrame.size)
        if !fitted, let origin = display.imageOrigin {
            viewport.pan(to: origin)
        }
        let rect = Self.openingFrame(
            display.frame, size: viewport.size, in: visibleFrame,
            keepPosition: !fitted
        )
        self.cgImage = cgImage
        self.baseSize = display.baseSize
        self.backingScale = display.backingScale
        self.originalText = originalText
        self.zoomScale = zoom
        self.opacity = display.preferredOpacity
        self.showBorder = display.showBorder
        self.isClickThrough = display.isClickThrough
        self.manager = manager
        self.visibleFrame = visibleFrame
        self.isFitToWindow = fitted
        self.viewport = viewport

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
        panel.ignoresMouseEvents = display.isClickThrough
        panel.alphaValue = display.effectiveWindowOpacity

        self.contentView = PinCanvasView(frame: NSRect(origin: .zero, size: rect.size))
        self.window = panel
        super.init()

        contentView.owner = self
        panel.contentView = contentView
        // NSPanel rounds the initial content rect outward. Reapply the size at its current origin.
        setPinFrame(NSRect(origin: panel.frame.origin, size: rect.size))
        panel.delegate = self
    }

    fileprivate convenience init(restoring snapshot: PinSnapshot, manager: PinManager) {
        let display = snapshot.displayState
        self.init(
            cgImage: snapshot.image, display: display, manager: manager, originalText: snapshot.originalText,
            visibleFrame: Self.screen(containing: display.frame)?.visibleFrame ?? Self.defaultVisibleFrame
        )
        historyID = snapshot.historyID
    }

    private static func screen(containing frame: NSRect) -> NSScreen? {
        let screens = NSScreen.screens
        func overlap(_ screen: NSScreen) -> CGFloat {
            let intersection = frame.intersection(screen.frame)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        if let screen = screens.max(by: { overlap($0) < overlap($1) }), overlap(screen) > 0 {
            return screen
        }
        return screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? screens.first
    }

    private static func fitScale(for size: NSSize, in visible: NSRect) -> CGFloat {
        min(1, visible.width / size.width, visible.height / size.height)
    }

    private static func openingFrame(_ frame: NSRect, size: NSSize, in visible: NSRect, keepPosition: Bool) -> NSRect {
        let isOnScreen = frame.intersects(visible)
        if keepPosition, size == frame.size, isOnScreen { return frame }
        let center = isOnScreen ? NSPoint(x: frame.midX, y: frame.midY) : NSPoint(x: visible.midX, y: visible.midY)
        return frameInside(visible, size: size, origin: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    private static func frameInside(_ visible: NSRect, size: NSSize, origin: NSPoint) -> NSRect {
        NSRect(
            x: min(max(visible.minX, origin.x), visible.maxX - size.width),
            y: min(max(visible.minY, origin.y), visible.maxY - size.height),
            width: size.width, height: size.height
        )
    }

    private func setPinFrame(_ frame: NSRect) {
        window.setFrame(frame, display: false)
        contentView.frame = NSRect(origin: .zero, size: frame.size)
        contentView.needsDisplay = true
    }

    private func applyZoom(_ scale: CGFloat, fitted: Bool, anchor: NSPoint, movingToScreen: Bool = false) {
        let oldFrame = window.frame
        let oldImage = viewport.imageRect
        let anchorOnScreen = NSPoint(x: oldFrame.minX + anchor.x, y: oldFrame.minY + anchor.y)
        var next = PinViewport(baseSize: baseSize, zoom: scale, fitted: fitted, limit: visibleFrame.size)
        let origin = NSPoint(
            x: anchorOnScreen.x - next.size.width * anchor.x / viewport.size.width,
            y: anchorOnScreen.y - next.size.height * anchor.y / viewport.size.height
        )
        // Keep the clipped image reachable while zooming.
        let keepOnScreen = fitted || movingToScreen || viewport.isClipped || next.isClipped
        let frame = keepOnScreen
            ? Self.frameInside(visibleFrame, size: next.size, origin: origin)
            : NSRect(origin: origin, size: next.size)
        let nextAnchor = movingToScreen
            ? NSPoint(x: next.size.width / 2, y: next.size.height / 2)
            : NSPoint(x: anchorOnScreen.x - frame.minX, y: anchorOnScreen.y - frame.minY)
        // Keep the same source point under the pointer as the window stops growing.
        next.pan(to: NSPoint(
            x: nextAnchor.x - next.imageRect.width * (anchor.x - oldImage.minX) / oldImage.width,
            y: nextAnchor.y - next.imageRect.height * (anchor.y - oldImage.minY) / oldImage.height
        ))
        zoomScale = scale
        isFitToWindow = fitted
        viewport = next
        setPinFrame(frame)
    }

    fileprivate func panImage(to origin: NSPoint) {
        let previousOrigin = viewport.imageRect.origin
        viewport.pan(to: origin)
        if viewport.imageRect.origin != previousOrigin { contentView.needsDisplay = true }
    }

    fileprivate func browseVertically(by distance: CGFloat) {
        guard viewport.isClippedVertically else { return }
        let origin = viewport.imageRect.origin
        panImage(to: NSPoint(x: origin.x, y: origin.y - distance))
        if origin.y != viewport.imageRect.minY, let browsingHint {
            ToastHUD.dismiss(browsingHint)
        }
    }

    public func windowDidChangeScreen(_ notification: Notification) {
        if !contentView.isMovingWindow { refreshDisplayBounds() }
    }

    fileprivate func refreshDisplayBounds(dropPoint: NSPoint? = nil) {
        let dropScreen = dropPoint.flatMap { point in NSScreen.screens.first { $0.frame.contains(point) } }
        let screen = dropScreen ?? Self.screen(containing: window.frame)
        guard let visible = screen?.visibleFrame, visible != visibleFrame else { return }
        visibleFrame = visible
        let scale = isFitToWindow ? Self.fitScale(for: baseSize, in: visible) : zoomScale
        applyZoom(scale, fitted: isFitToWindow,
                  anchor: NSPoint(x: viewport.size.width / 2, y: viewport.size.height / 2), movingToScreen: true)
    }

    public func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(contentView)
    }

    func hide() {
        if let browsingHint { ToastHUD.dismiss(browsingHint) }
        window.orderOut(nil)
    }

    fileprivate func snapshot() -> PinSnapshot {
        PinSnapshot(
            image: cgImage, originalText: originalText,
            displayState: PinDisplayState(
                frame: window.frame, baseSize: baseSize, backingScale: backingScale, zoomScale: zoomScale,
                preferredOpacity: opacity, effectiveWindowOpacity: window.alphaValue,
                showBorder: showBorder, isClickThrough: isClickThrough,
                imageOrigin: viewport.isClipped ? viewport.imageRect.origin : nil
            ),
            historyID: historyID
        )
    }

    func finishAnnotation(image: CGImage? = nil, preserveGeometry: Bool = false) {
        guard manager?.windows.contains(where: { $0 === self }) == true else { return }
        if let image {
            if preserveGeometry {
                applyAnnotatedImage(image)
            } else {
                updateImage(image)
            }
        }
        show()
    }

    private func applyAnnotatedImage(_ image: CGImage) {
        cgImage = image
        contentView.needsDisplay = true
    }

    public func updateImage(_ newImage: CGImage) {
        applyAnnotatedImage(newImage)
        self.baseSize = NSSize(
            width: max(32.0, Double(newImage.width) / max(1.0, backingScale)),
            height: max(32.0, Double(newImage.height) / max(1.0, backingScale))
        )
        showWholeImage(anchor: NSPoint(x: viewport.size.width / 2, y: viewport.size.height / 2))
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
            ToastHUD.show(
                L10n.tr("已开启穿透", "Click-through enabled"),
                kind: .information,
                detail: L10n.tr("可从菜单栏恢复贴图交互", "Restore pin interaction from the menu bar"),
                symbol: "cursorarrow"
            )
        }
    }

    public func adjustZoom(delta: CGFloat, anchorInWindow: NSPoint) {
        let fit = Self.fitScale(for: baseSize, in: visibleFrame)
        let minimum = Self.minimumZoom
        if fit < minimum, delta < 0, zoomScale <= minimum {
            guard zoomScale != fit else { return }
            applyZoom(fit, fitted: true, anchor: anchorInWindow)
            contentView.showBadgeTemporarily(L10n.tr("适合窗口", "Fit to Window"))
            return
        }
        let step: CGFloat = 1.08
        let proposedScale = if zoomScale < minimum {
            minimum
        } else {
            delta > 0 ? zoomScale * step : zoomScale / step
        }
        let boundedScale = max(minimum, min(4.0, proposedScale))
        let boundedPercent = Int((boundedScale * 100).rounded())
        let crossesOriginalSize = (zoomScale < 1.0 && boundedScale > 1.0)
            || (zoomScale > 1.0 && boundedScale < 1.0)
        let returnsToOriginalSize = crossesOriginalSize || boundedPercent == 100
        let newScale = returnsToOriginalSize ? 1.0 : boundedScale
        guard newScale != zoomScale else { return }

        applyZoom(newScale, fitted: false, anchor: anchorInWindow)
        contentView.showBadgeTemporarily("\(returnsToOriginalSize ? 100 : boundedPercent)%")
        if delta > 0, viewport.isClippedVertically, browsingHint == nil, !ToastHUD.isShowing {
            browsingHint = ToastHUD.show(
                L10n.tr("上下浏览长图", "Scroll Through the Image"),
                kind: .information,
                detail: L10n.tr("按住 ⇧ Shift 并滚动滚轮", "Hold ⇧ Shift and scroll"),
                duration: 15,
                above: window
            )
        }
    }

    public func adjustOpacity(delta: CGFloat) {
        let step: CGFloat = delta > 0 ? 0.06 : -0.06
        opacity = max(0.15, min(1.0, opacity + step))
        window.alphaValue = opacity
        let pct = Int((opacity * 100).rounded())
        contentView.showBadgeTemporarily(L10n.tr("透明度 \(pct)%", "Opacity \(pct)%"))
    }

    public func resetTransform() {
        opacity = 1.0
        window.alphaValue = 1.0
        showWholeImage(anchor: .zero)
    }

    private func showWholeImage(anchor: NSPoint) {
        let scale = Self.fitScale(for: baseSize, in: visibleFrame)
        applyZoom(scale, fitted: scale < 1, anchor: anchor)
    }

    public func requestAnnotation() {
        manager?.onRequestAnnotatePin?(self)
    }

    public func requestOCR() {
        manager?.onRequestOCRPin?(self)
    }

    public func copyToClipboard() {
        let cfg = manager?.getConfig?()
        OutputService.copyImageToClipboard(
            cgImage, backingScale: backingScale, config: cfg, to: manager?.pasteboard ?? .general
        ) { [weak manager] _ in
            guard manager?.getConfig?().showCompletionToast ?? true else { return }
            ToastHUD.show(L10n.tr("已复制", "Copied"), kind: .success)
        }
    }

    func copyOriginalText() {
        guard let originalText else { return }
        OutputService.copyStringToClipboard(originalText, to: manager?.pasteboard ?? .general)
        if manager?.getConfig?().showCompletionToast ?? true {
            ToastHUD.show(L10n.tr("已复制原文", "Original Text Copied"), kind: .success)
        }
    }

    public func savePin(forceDialog: Bool = false) {
        guard let config = manager?.getConfig?(),
              let saved = OutputService.saveImage(
                  for: cgImage, backingScale: backingScale, config: config, forceDialog: forceDialog
              ) else { return }
        if let updatePreferences = saved.updatePreferences {
            manager?.updateConfig?(updatePreferences)
        }
        if manager?.getConfig?().showCompletionToast ?? config.showCompletionToast {
            ToastHUD.show(L10n.tr("已保存", "Saved"), kind: .success)
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
    private enum Drag {
        case window(mouse: NSPoint, origin: NSPoint)
        case image(mouse: NSPoint, origin: NSPoint)
    }

    weak var owner: PinWindowController?
    private var drag: Drag?
    private var badgeText: String?
    private var badgeClearTask: Task<Void, Never>?

    var isMovingWindow: Bool {
        if case .window = drag { return true }
        return false
    }

    private var moveGrip: NSRect {
        let width = min(48, bounds.width)
        return NSRect(x: bounds.midX - width / 2, y: max(0, bounds.height - 20),
                      width: width, height: min(20, bounds.height))
    }

    override var acceptsFirstResponder: Bool { true }

    // Let mouseDown record the drag origin on the press that focuses the pin.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        owner.cgImage.drawVisibleRegion(in: ctx, projectedTo: owner.viewport.imageRect, clippedTo: bounds)
        if owner.canDragImageHorizontally {
            let grip = moveGrip.insetBy(dx: min(4, moveGrip.width / 4), dy: min(4, moveGrip.height / 4))
            ctx.setFillColor(CGColor(gray: 0.1, alpha: 0.7))
            ctx.addPath(CGPath(roundedRect: grip, cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
            let mark = NSRect(x: grip.midX - grip.width / 4, y: grip.midY - 1, width: grip.width / 2, height: 2)
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.9))
            ctx.fill(mark)
        }
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
            guard bounds.contains(pill) else { return }
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
        guard let owner, let window else { return }
        window.makeKey()
        window.makeFirstResponder(self)
        if event.clickCount == 2 {
            owner.closeSelf()
            return
        }
        let mouse = convert(event.locationInWindow, from: nil)
        if owner.canDragImageHorizontally, !moveGrip.contains(mouse) {
            drag = .image(mouse: mouse, origin: owner.viewport.imageRect.origin)
        } else {
            drag = .window(mouse: NSEvent.mouseLocation, origin: window.frame.origin)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        switch drag {
        case .window(let mouse, let origin):
            let point = NSEvent.mouseLocation
            window?.setFrameOrigin(NSPoint(x: origin.x + point.x - mouse.x, y: origin.y + point.y - mouse.y))
        case .image(let mouse, let origin):
            let point = convert(event.locationInWindow, from: nil)
            owner?.panImage(to: NSPoint(x: origin.x + point.x - mouse.x, y: origin.y + point.y - mouse.y))
        }
    }

    override func mouseUp(with event: NSEvent) {
        let endedDrag = drag
        drag = nil
        if case .window(_, let origin) = endedDrag, let window, window.frame.origin != origin {
            owner?.refreshDisplayBounds(dropPoint: NSEvent.mouseLocation)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let owner else { return }
        let flags = event.modifierFlags
        let vertical = abs(event.scrollingDeltaY) > 0.01 ? event.scrollingDeltaY : event.deltaY
        // Some mice report Shift-wheel as horizontal scrolling.
        let delta = flags.contains(.shift) && abs(vertical) <= 0.01 ? event.scrollingDeltaX : vertical
        guard abs(delta) > 0.01 else { return }
        if flags.contains(.control) || flags.contains(.command) {
            owner.adjustOpacity(delta: delta)
        } else if flags.contains(.shift) {
            let distance = event.hasPreciseScrollingDeltas ? delta : delta * 36
            owner.browseVertically(by: distance)
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
            owner.requestAnnotation()
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

    @objc private func onEdit() { owner?.requestAnnotation() }
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
