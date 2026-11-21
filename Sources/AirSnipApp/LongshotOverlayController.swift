import AppKit
import Carbon
import SwiftUI
import AirSnipCore

private final class ControlBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class FullScreenBorderPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

struct LongshotViewport {
    let capture: (Set<Int>) async -> PixelBufferRGBA?
    let scroll: (Int) -> Void
    let positionCursor: (NSRect?) -> Void
    let hasAccessibilityPermission: () -> Bool
}

private extension LongshotStepResult {
    var isStationary: Bool { self == .still || self == .refreshed }
}

@MainActor
public final class LongshotSessionController: ObservableObject {
    @Published public private(set) var pixelWidth: Int = 0
    @Published public private(set) var pixelHeight: Int = 0
    @Published public private(set) var segmentCount: Int = 0
    @Published public private(set) var canUndo: Bool = false
    @Published public private(set) var statusHint: String = "" {
        didSet {
            if statusHint != oldValue { fitControlBar() }
        }
    }
    @Published public private(set) var thumbnailImage: CGImage?
    @Published public private(set) var isAutoScrolling: Bool = false
    @Published public private(set) var needsAccessibilityAuth: Bool = false
    @Published public private(set) var scrollSpeed: LongshotScrollSpeed

    private let screen: NSScreen
    private let viewportTopDown: ASRect
    private let viewport: LongshotViewport
    private let backingScale: Double
    private var config: AirSnipConfig
    private let autoStartRequested: Bool

    private let canvas: LongshotCanvas
    private var borderWindow: NSPanel?
    private var previewWindow: NSPanel?
    private var controlWindow: ControlBarPanel?
    private var captureLoopTask: Task<Void, Never>?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalScrollMonitor: Any?
    private var pendingOutput: ((CGImage) -> Void)?

    private enum ViewportPosition: Equatable {
        case connected
        case settling(LongshotFrameMode)
        case unmatched(LongshotFrameMode)
        case heightLimit

        var isSettling: Bool {
            if case .settling = self { return true }
            return false
        }

        var frameMode: LongshotFrameMode {
            switch self {
            case .settling(let mode), .unmatched(let mode): return mode
            case .connected, .heightLimit: return .manual
            }
        }
    }

    private var viewportPosition: ViewportPosition = .connected
    private var captureRevision = 0
    private var autoScrollStartDelay: UInt64?
    private var adaptiveScale = 1.0
    private var rewoundSinceLastSegment = false

    public var onSpeedChanged: ((LongshotScrollSpeed) -> Void)?
    public var onFinishCopy: ((CGImage, Double) -> Void)?
    public var onFinishSave: ((CGImage, Double, Bool) -> Void)?
    public var onFinishEdit: ((CGImage, Double, NSScreen) -> Void)?
    public var onFinishOCR: ((CGImage) -> Void)?
    public var onCancel: (() -> Void)?

    public convenience init(
        screen: NSScreen,
        viewportTopDown: ASRect,
        initialCrop: PixelBufferRGBA,
        config: AirSnipConfig,
        autoStartScroll: Bool = false
    ) {
        let scrollAnchor = AccessibilityService.globalCGPoint(
            on: screen,
            localTopDownPoint: ASPoint(viewportTopDown.midX, viewportTopDown.minY + viewportTopDown.height * 0.46)
        )
        let viewport = LongshotViewport(
            capture: { windowIDs in
                await ScreenCaptureService.captureDisplayRegion(
                    screen: screen, localTopDownRect: viewportTopDown, excludingWindowNumbers: windowIDs
                )
            },
            scroll: { AccessibilityService.postPixelScroll(at: scrollAnchor, downwardPoints: $0) },
            positionCursor: { avoidRect in
                AccessibilityService.moveCursorIntoViewportIfNeeded(
                    screen: screen, viewportTopDown: viewportTopDown, avoidAppKitRect: avoidRect
                )
            },
            hasAccessibilityPermission: AccessibilityService.hasPermission
        )
        self.init(
            screen: screen, viewportTopDown: viewportTopDown, initialCrop: initialCrop,
            config: config, autoStartScroll: autoStartScroll, viewport: viewport
        )
    }

    init(
        screen: NSScreen,
        viewportTopDown: ASRect,
        initialCrop: PixelBufferRGBA,
        config: AirSnipConfig,
        autoStartScroll: Bool = false,
        viewport: LongshotViewport
    ) {
        self.screen = screen
        self.viewportTopDown = viewportTopDown
        self.viewport = viewport
        self.backingScale = Double(screen.backingScaleFactor)
        self.config = config
        self.scrollSpeed = config.longshotScrollSpeed
        self.autoStartRequested = autoStartScroll
        self.pixelWidth = initialCrop.width
        self.pixelHeight = initialCrop.height

        let stitchCanvas = LongshotCanvas(
            width: initialCrop.width,
            frameHeight: initialCrop.height,
            params: LongshotParams(minRatio: 0.84, minFixedRows: 8),
            maxHeight: config.longshotMaxHeight
        )
        stitchCanvas.seed(initialCrop)
        self.canvas = stitchCanvas
        self.thumbnailImage = stitchCanvas.makeThumbnail(maxWidth: 160, maxHeight: 420)
    }

    public func start() {
        setupWindows()
        installKeyMonitors()
        if autoStartRequested {
            if viewport.hasAccessibilityPermission() {
                beginAutoScrolling(initialDelayMs: 220)
            } else {
                needsAccessibilityAuth = true
                _ = AccessibilityService.requestPermissionPrompt()
                statusHint = L10n.tr("需辅助功能权限", "Accessibility required", in: config.language)
            }
        }
        startSessionLoop()
    }

    public func stopAndCleanup() {
        isAutoScrolling = false
        captureLoopTask?.cancel()
        captureLoopTask = nil
        pendingOutput = nil
        GlobalHotkeyManager.shared?.unregisterTransientHotKeys()
        if let g = globalKeyMonitor { NSEvent.removeMonitor(g); globalKeyMonitor = nil }
        if let l = localKeyMonitor { NSEvent.removeMonitor(l); localKeyMonitor = nil }
        if let s = globalScrollMonitor { NSEvent.removeMonitor(s); globalScrollMonitor = nil }
        borderWindow?.orderOut(nil)
        previewWindow?.orderOut(nil)
        controlWindow?.orderOut(nil)
        borderWindow = nil
        previewWindow = nil
        controlWindow = nil
    }

    public func toggleAutoScroll() {
        if isAutoScrolling {
            pauseAutoScrolling()
        } else {
            beginAutoScrolling(initialDelayMs: 90)
        }
    }

    public func beginAutoScrolling(initialDelayMs: UInt64 = 90) {
        guard pendingOutput == nil, viewportPosition != .heightLimit else { return }
        guard viewport.hasAccessibilityPermission() else {
            needsAccessibilityAuth = true
            isAutoScrolling = false
            _ = AccessibilityService.requestPermissionPrompt()
            statusHint = L10n.tr("需辅助功能权限", "Accessibility required", in: config.language)
            return
        }
        needsAccessibilityAuth = false
        captureRevision += 1
        autoScrollStartDelay = initialDelayMs
        rewoundSinceLastSegment = false
        isAutoScrolling = true
        statusHint = ""
    }

    public func pauseAutoScrolling() {
        guard isAutoScrolling else { return }
        captureRevision += 1
        isAutoScrolling = false
    }

    public func setScrollSpeed(_ speed: LongshotScrollSpeed) {
        guard scrollSpeed != speed else { return }
        scrollSpeed = speed
        config.longshotScrollSpeed = speed
        onSpeedChanged?(speed)
    }

    public func cycleScrollSpeed() {
        setScrollSpeed(scrollSpeed.next)
    }

    public func openAccessibilityAuthorization() {
        _ = AccessibilityService.requestPermissionPrompt()
        AccessibilityService.openSystemSettings()
    }

    private func setupWindows() {
        let sFrame = screen.frame
        // Convert local top-down viewport rect to AppKit global coordinates
        let vpAppKit = NSRect(
            x: sFrame.minX + CGFloat(viewportTopDown.minX),
            y: sFrame.maxY - CGFloat(viewportTopDown.maxY),
            width: CGFloat(viewportTopDown.width),
            height: CGFloat(viewportTopDown.height)
        )

        // 1. Click-through viewport frame window covering `screen`
        let bWin = FullScreenBorderPanel(
            contentRect: sFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        bWin.hidesOnDeactivate = false
        bWin.animationBehavior = .none
        bWin.setFrame(sFrame, display: false)
        bWin.isOpaque = false
        bWin.backgroundColor = .clear
        bWin.level = .statusBar
        bWin.ignoresMouseEvents = true
        bWin.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let borderView = LongshotFrameOverlayView(
            frame: NSRect(origin: .zero, size: sFrame.size),
            viewportInView: NSRect(
                x: vpAppKit.minX - sFrame.minX,
                y: vpAppKit.minY - sFrame.minY,
                width: vpAppKit.width,
                height: vpAppKit.height
            )
        )
        bWin.contentView = borderView
        bWin.orderFrontRegardless()
        self.borderWindow = bWin

        // 2. Side live thumbnail preview window (right side if >=176pt space, else left side)
        let rightSpace = sFrame.maxX - vpAppKit.maxX
        let leftSpace = vpAppKit.minX - sFrame.minX
        let previewW: CGFloat = 156
        let previewH = min(max(200, vpAppKit.height), sFrame.height - 80)
        var previewX: CGFloat?
        if rightSpace >= previewW + 20 {
            previewX = vpAppKit.maxX + 12
        } else if leftSpace >= previewW + 20 {
            previewX = vpAppKit.minX - previewW - 12
        }
        if let px = previewX {
            let pRect = NSRect(x: px, y: vpAppKit.minY, width: previewW, height: previewH)
            let pWin = NSPanel(
                contentRect: pRect,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            pWin.hidesOnDeactivate = false
            pWin.isOpaque = false
            pWin.backgroundColor = .clear
            pWin.hasShadow = true
            pWin.level = .statusBar
            pWin.ignoresMouseEvents = true
            pWin.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            applyWindowTheme(to: pWin)
            pWin.contentView = NSHostingView(rootView: LongshotPreviewCard(controller: self))
            pWin.orderFrontRegardless()
            self.previewWindow = pWin
        }

        // 3. Control bar window below (or above / cleanly inside bottom of) viewport, always respecting Dock & menu bar
        let vis = screen.visibleFrame
        let barW = controlBarWidth(in: vis)
        let barH: CGFloat = 42
        let barX = max(vis.minX + 12, min(vis.maxX - barW - 12, vpAppKit.midX - barW * 0.5))
        let barY: CGFloat
        if vpAppKit.minY - barH - 10 >= vis.minY + 6 {
            barY = vpAppKit.minY - barH - 10
        } else if vpAppKit.maxY + 10 + barH <= vis.maxY - 6 {
            barY = vpAppKit.maxY + 10
        } else {
            barY = max(vis.minY + 14, vpAppKit.minY + 14)
        }

        let cWin = ControlBarPanel(
            contentRect: NSRect(x: barX, y: barY, width: barW, height: barH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        cWin.hidesOnDeactivate = false
        cWin.isOpaque = false
        cWin.backgroundColor = .clear
        cWin.hasShadow = true
        cWin.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        cWin.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        applyWindowTheme(to: cWin)
        cWin.contentView = FirstMouseHostingView(rootView: LongshotControlBarView(controller: self))
        cWin.orderFrontRegardless()
        self.controlWindow = cWin
    }

    private func controlBarWidth(in visibleFrame: NSRect) -> CGFloat {
        let base: CGFloat = config.language.isEnglish ? 584 : 544
        let hintWidth = (statusHint as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
        return min(visibleFrame.width - 24, base + (statusHint.isEmpty ? 0 : ceil(hintWidth) + 16))
    }

    private func fitControlBar() {
        guard let controlWindow else { return }
        let visible = screen.visibleFrame
        var frame = controlWindow.frame
        frame.size.width = controlBarWidth(in: visible)
        let center = screen.frame.minX + viewportTopDown.midX
        frame.origin.x = max(visible.minX + 12, min(visible.maxX - frame.width - 12, center - frame.width / 2))
        controlWindow.setFrame(frame, display: true)
    }

    var appLanguage: AppLanguage { config.language }
    var heightLimitReached: Bool { viewportPosition == .heightLimit }

    private func applyWindowTheme(to win: NSWindow) {
        switch config.theme {
        case .follow: win.appearance = nil
        case .light: win.appearance = NSAppearance(named: .aqua)
        case .dark: win.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func installKeyMonitors() {
        // 1. Register Carbon session hotkeys so `Space`, `Enter`, `Esc`, `⌘S`, `⌘C`, `⌘Z` are reliably intercepted
        //    and consumed even when Chrome/Safari is focused (preventing browser PageDown / link click / Save Page As).
        let carbonSpecs: [(id: UInt32, keyCode: Int, modifiers: UInt32)] = [
            (101, kVK_Space, 0),
            (102, kVK_Return, 0),
            (103, kVK_Return, UInt32(optionKey)),
            (104, kVK_ANSI_KeypadEnter, 0),
            (105, kVK_ANSI_KeypadEnter, UInt32(optionKey)),
            (106, kVK_Escape, 0),
            (107, kVK_ANSI_S, UInt32(cmdKey)),
            (108, kVK_ANSI_S, UInt32(cmdKey | shiftKey)),
            (109, kVK_ANSI_S, UInt32(cmdKey | optionKey)),
            (110, kVK_ANSI_C, UInt32(cmdKey)),
            (111, kVK_ANSI_Z, UInt32(cmdKey)),
        ]
        let registeredIDs = GlobalHotkeyManager.shared?.registerTransientHotKeys(carbonSpecs) { [weak self] id in
            guard let self else { return }
            switch id {
            case 101: self.toggleAutoScroll()
            case 102, 104, 107: self.finishAndSave(forceDialog: false)
            case 103, 105, 108, 109: self.finishAndSave(forceDialog: true)
            case 106: self.cancel()
            case 110: self.finishAndCopy()
            case 111: self.undoLastSegment()
            default: break
            }
        } ?? []

        let handleKey: (NSEvent, Bool) -> Bool = { [weak self] ev, fromGlobalMonitor in
            guard let self else { return false }
            let flags = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let cmdOrCtrl = flags.contains(.command) || flags.contains(.control)
            let anyMod = cmdOrCtrl || flags.contains(.option) || flags.contains(.shift)
            switch Int(ev.keyCode) {
            case kVK_Space where !anyMod:
                if fromGlobalMonitor && registeredIDs.contains(101) { return false }
                self.toggleAutoScroll()
                return true
            case kVK_Return:
                let opt = flags.contains(.option)
                if fromGlobalMonitor && registeredIDs.contains(opt ? 103 : 102) { return false }
                self.finishAndSave(forceDialog: opt)
                return true
            case kVK_ANSI_KeypadEnter:
                let opt = flags.contains(.option)
                if fromGlobalMonitor && registeredIDs.contains(opt ? 105 : 104) { return false }
                self.finishAndSave(forceDialog: opt)
                return true
            case kVK_Escape:
                if fromGlobalMonitor && registeredIDs.contains(106) { return false }
                self.cancel()
                return true
            case kVK_ANSI_Z where cmdOrCtrl:
                if fromGlobalMonitor && flags.contains(.command) && registeredIDs.contains(111) { return false }
                self.undoLastSegment()
                return true
            case kVK_ANSI_S where cmdOrCtrl:
                let forceDlg = flags.contains(.shift) || flags.contains(.option)
                if fromGlobalMonitor && flags.contains(.command) && registeredIDs.contains(forceDlg ? 108 : 107) { return false }
                self.finishAndSave(forceDialog: forceDlg)
                return true
            case kVK_ANSI_C where cmdOrCtrl:
                if fromGlobalMonitor && flags.contains(.command) && registeredIDs.contains(110) { return false }
                self.finishAndCopy()
                return true
            case kVK_ANSI_T where !cmdOrCtrl:
                self.finishAndOCR()
                return true
            default:
                return false
            }
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { ev in
            Task { @MainActor in
                _ = handleKey(ev, true)
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            handleKey(ev, false) ? nil : ev
        }

        // 2. Automatically yield auto-scrolling if the user physically touches the trackpad or rolls a mouse wheel
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] ev in
            let isSynthetic = (ev.cgEvent?.getIntegerValueField(.eventSourceUserData) == AccessibilityService.syntheticScrollEventTag)
            guard !isSynthetic else { return }
            let userTouchedTrackpad = (ev.phase == .began)
            let userRolledDiscreteWheel = (ev.phase == [] && ev.momentumPhase == [] && abs(ev.scrollingDeltaY) > 0.5)
            guard userTouchedTrackpad || userRolledDiscreteWheel else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isAutoScrolling else { return }
                self.pauseAutoScrolling()
            }
        }
    }

    private func startSessionLoop() {
        captureLoopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self {
                await self.captureNext()
            }
        }
    }

    private func captureNext() async {
        if let pendingOutput {
            await finishCapture(pendingOutput, revision: captureRevision)
            return
        }

        if needsAccessibilityAuth && viewport.hasAccessibilityPermission() {
            needsAccessibilityAuth = false
            if autoStartRequested && segmentCount == 0 && !isAutoScrolling {
                beginAutoScrolling(initialDelayMs: 120)
            } else if !isAutoScrolling {
                statusHint = ""
            }
        }

        let revision = captureRevision
        if isAutoScrolling {
            await autoScroll(revision: revision)
            return
        }

        let delay = viewportPosition.isSettling ? max(115, scrollSpeed.settleMilliseconds) : 115
        try? await Task.sleep(for: .milliseconds(delay))
        guard isCurrent(revision), !heightLimitReached || segmentCount == 0 else { return }
        await checkCurrentViewport(revision: revision, retryFailure: false)
    }

    private func checkCurrentViewport(revision: Int, retryFailure: Bool) async {
        let result = await captureAndMatch(
            revision: revision, mode: viewportPosition.frameMode,
            attempts: retryFailure || viewportPosition.isSettling ? 3 : 1,
            retryStill: viewportPosition.isSettling
        )
        guard isCurrent(revision) else { return }
        applyCaptureResult(result)
    }

    private func isCurrent(_ revision: Int) -> Bool {
        !Task.isCancelled && captureRevision == revision
    }

    private func captureAndMatch(
        revision: Int, mode: LongshotFrameMode, attempts: Int = 3, retryStill: Bool = false
    ) async -> LongshotStepResult? {
        var result: LongshotStepResult?
        for attempt in 0..<attempts {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(110)) }
            guard isCurrent(revision) else { return nil }
            let frame = await viewport.capture(currentOwnWindowIDs())
            guard isCurrent(revision) else { return nil }

            guard let frame else {
                // A missed capture does not erase evidence that the last available frame did not match.
                if result != .failed { result = nil }
                continue
            }
            let step = canvas.push(frame, mode: mode)
            if case .appended = step {
                rewoundSinceLastSegment = false
                refreshPreview()
            } else if step == .refreshed {
                refreshPreview()
            }
            result = step
            if step != .failed && (!retryStill || !step.isStationary) { break }
        }
        return result
    }

    private func autoScroll(revision: Int) async {
        if let delay = autoScrollStartDelay {
            autoScrollStartDelay = nil
            try? await Task.sleep(for: .milliseconds(delay))
            guard isCurrent(revision) else { return }
            viewport.positionCursor(controlWindow?.frame)
            try? await Task.sleep(for: .milliseconds(55))
            let result = await captureAndMatch(revision: revision, mode: viewportPosition.frameMode)
            guard isCurrent(revision) else { return }
            applyCaptureResult(result)
            if result == nil || result == .failed { isAutoScrolling = false }
            return
        }

        let distance = autoScrollDistance()
        guard distance > 0 else {
            isAutoScrolling = false
            statusHint = L10n.tr("请放大选区", "Enlarge the selection", in: config.language)
            return
        }

        await scrollAndSettle(distance, revision: revision)
        let result = await captureAndMatch(revision: revision, mode: .automatic, retryStill: true)
        guard isCurrent(revision) else { return }

        if result == .failed, !rewoundSinceLastSegment {
            rewoundSinceLastSegment = true
            await recoverAfterScroll(distance, revision: revision)
            return
        }
        applyCaptureResult(result)
        if result == nil || result == .failed {
            isAutoScrolling = false
        } else if result?.isStationary == true {
            isAutoScrolling = false
            statusHint = L10n.tr("未检测到新内容", "No new content", in: config.language)
        }
    }

    private func recoverAfterScroll(_ distance: Int, revision: Int) async {
        adaptiveScale = max(0.30, adaptiveScale * 0.60)
        let rewindDistance = max(1, distance / 3)
        for _ in 0..<4 {
            await scrollAndSettle(-rewindDistance, revision: revision)
            let result = await captureAndMatch(revision: revision, mode: .reconnecting, attempts: 2, retryStill: true)
            guard isCurrent(revision) else { return }

            if let result, result != .failed {
                applyCaptureResult(result)
                return
            }
            if result == nil { break }
        }
        isAutoScrolling = false
        applyCaptureResult(.failed)
    }

    private func autoScrollDistance() -> Int {
        let fixedHeight = Double(canvas.headerHeight + canvas.footerHeight) / backingScale
        let bodyHeight = viewportTopDown.height - fixedHeight
        let fraction = min(segmentCount == 0 ? 0.58 : 0.86, scrollSpeed.viewportStepFraction * adaptiveScale)
        let overlap = max(8 / backingScale, bodyHeight * 0.14)
        return Int(max(0, min(bodyHeight * fraction, bodyHeight - overlap)))
    }

    private func scrollAndSettle(_ distance: Int, revision: Int) async {
        while isCurrent(revision), controlWindow?.frame.contains(NSEvent.mouseLocation) == true {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard isCurrent(revision) else { return }

        viewportPosition = .settling(distance > 0 ? .automatic : .reconnecting)
        let tickCount = max(3, Int(ceil(Double(abs(distance)) / 220.0)))
        let pointsPerTick = abs(distance) / tickCount
        let remainder = abs(distance) % tickCount
        for tick in 0..<tickCount {
            guard isCurrent(revision) else { return }
            let points = pointsPerTick + (tick < remainder ? 1 : 0)
            if points > 0 { viewport.scroll(distance > 0 ? points : -points) }
            if tick + 1 < tickCount { try? await Task.sleep(for: .milliseconds(6)) }
        }
        try? await Task.sleep(for: .milliseconds(scrollSpeed.settleMilliseconds))
    }

    private func applyCaptureResult(_ result: LongshotStepResult?) {
        switch result {
        case .appended:
            viewportPosition = .connected
            statusHint = ""
        case .still, .refreshed, .overlapping:
            if viewportPosition != .connected { statusHint = "" }
            viewportPosition = .connected
        case .limitReached:
            isAutoScrolling = false
            viewportPosition = .heightLimit
            statusHint = L10n.tr("已达上限", "Height limit reached", in: config.language)
        case .failed, nil:
            let mode: LongshotFrameMode = viewportPosition.frameMode == .manual ? .manual : .reconnecting
            viewportPosition = .unmatched(mode)
            statusHint = L10n.tr("拼接中断，请往回滚一点", "Scroll back to reconnect", in: config.language)
        }
    }

    private func refreshPreview() {
        pixelHeight = canvas.totalHeight
        segmentCount = canvas.segmentCount
        canUndo = canvas.canUndo
        thumbnailImage = canvas.makeThumbnail(maxWidth: 160, maxHeight: 420)
    }

    public func undoLastSegment() {
        guard pendingOutput == nil, canvas.undoLast() else { return }
        captureRevision += 1
        isAutoScrolling = false
        if viewportPosition == .heightLimit { viewportPosition = .unmatched(.manual) }
        refreshPreview()
        statusHint = ""
    }

    private func currentOwnWindowIDs() -> Set<Int> {
        var ids = Set<Int>()
        if let id = borderWindow?.windowNumber, id > 0 { ids.insert(id) }
        if let id = previewWindow?.windowNumber, id > 0 { ids.insert(id) }
        if let id = controlWindow?.windowNumber, id > 0 { ids.insert(id) }
        return ids
    }

    private func requestOutput(completion: @escaping (CGImage) -> Void) {
        guard captureLoopTask != nil, pendingOutput == nil else { return }
        isAutoScrolling = false
        captureRevision += 1
        pendingOutput = completion
    }

    private func finishCapture(_ completion: (CGImage) -> Void, revision: Int) async {
        if !heightLimitReached {
            if viewportPosition.isSettling {
                try? await Task.sleep(for: .milliseconds(scrollSpeed.settleMilliseconds))
            }
            await checkCurrentViewport(revision: revision, retryFailure: true)
            guard isCurrent(revision) else { return }
        }

        pendingOutput = nil
        guard segmentCount > 0 else {
            if !heightLimitReached {
                statusHint = L10n.tr("尚未拼成长截图", "No long screenshot yet", in: config.language)
            }
            return
        }
        guard viewportPosition == .connected || viewportPosition == .heightLimit else { return }
        guard let image = canvas.exportBuffer()?.makeCGImage() else {
            statusHint = L10n.tr("无法生成长截图", "Could not create the long screenshot", in: config.language)
            return
        }
        stopAndCleanup()
        completion(image)
    }

    public func finishAndCopy() {
        let scale = backingScale
        requestOutput { [weak self] cg in
            self?.onFinishCopy?(cg, scale)
        }
    }

    public func finishAndSave(forceDialog: Bool = false) {
        let scale = backingScale
        requestOutput { [weak self] cg in
            self?.onFinishSave?(cg, scale, forceDialog)
        }
    }

    public func finishAndAnnotate() {
        let scale = backingScale
        let scr = screen
        requestOutput { [weak self] cg in
            self?.onFinishEdit?(cg, scale, scr)
        }
    }

    public func finishAndOCR() {
        requestOutput { [weak self] cg in
            self?.onFinishOCR?(cg)
        }
    }

    public func cancel() {
        guard captureLoopTask != nil else { return }
        stopAndCleanup()
        onCancel?()
    }
}

private final class LongshotFrameOverlayView: NSView {
    let viewportInView: NSRect

    init(frame: NSRect, viewportInView: NSRect) {
        self.viewportInView = viewportInView
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Subtle outside dim while leaving viewport 100% clear
        ctx.saveGState()
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(viewportInView)
        ctx.addPath(path)
        ctx.clip(using: .evenOdd)
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28))
        ctx.fill(bounds)
        ctx.restoreGState()

        // Crisp dual-contrast neutral border outside viewport (legible on both dark & light pages)
        let outerRim = viewportInView.insetBy(dx: -2.0, dy: -2.0)
        ctx.setStrokeColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 0.72))
        ctx.setLineWidth(2.0)
        ctx.stroke(outerRim)

        let innerRim = viewportInView.insetBy(dx: -0.75, dy: -0.75)
        ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.96))
        ctx.setLineWidth(1.5)
        ctx.stroke(innerRim)
    }
}

private struct LongshotPreviewCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var controller: LongshotSessionController

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        ZStack {
            if let cg = controller.thumbnailImage {
                Image(decorative: cg, scale: 1.0)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(p.cardBorder, lineWidth: 1)
                    )
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(p.cardBg.opacity(0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(p.cardBorder, lineWidth: 1)
        )
    }
}

private struct LongshotBarPillStyle: ButtonStyle {
    var role: Role = .secondary
    @Environment(\.isEnabled) private var isEnabled

    enum Role {
        case secondary
        case activeThumb
        case warning
        case primary
    }

    func makeBody(configuration: Configuration) -> some View {
        InnerBarPill(configuration: configuration, role: role, isEnabled: isEnabled)
    }

    private struct InnerBarPill: View {
        @Environment(\.colorScheme) private var colorScheme
        let configuration: Configuration
        let role: Role
        let isEnabled: Bool
        @State private var isHovered = false

        var body: some View {
            let p = MagpiePalette(colorScheme: colorScheme)
            let bg: Color = {
                switch role {
                case .primary:
                    return p.solidBtnBg.opacity(configuration.isPressed ? 0.82 : (isHovered ? 0.90 : 1.0))
                case .activeThumb:
                    return p.segmentedThumb
                case .warning:
                    return p.statusWarn.opacity(configuration.isPressed ? 0.24 : 0.14)
                case .secondary:
                    return isHovered ? p.navActivePill : p.segmentedTrack
                }
            }()
            let fg: Color = {
                switch role {
                case .primary:
                    return p.solidBtnFg
                case .activeThumb, .secondary:
                    return p.inkPrimary
                case .warning:
                    return p.statusWarn
                }
            }()

            configuration.label
                .font(.system(size: 11.5, weight: role == .primary || role == .activeThumb ? .semibold : .medium))
                .foregroundStyle(fg)
                .padding(.horizontal, 8.5)
                .frame(height: 25)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(bg)
                )
                .overlay {
                    if role == .activeThumb {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(p.segmentedThumbBorder, lineWidth: 0.85)
                    }
                }
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
                .opacity(isEnabled ? 1.0 : 0.38)
                .onHover { isHovered = $0 }
        }
    }
}

struct LongshotControlBarView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var controller: LongshotSessionController

    private func statusDotColor(palette p: MagpiePalette) -> Color {
        if controller.needsAccessibilityAuth {
            return p.statusWarn
        }
        if controller.isAutoScrolling {
            return p.statusOk
        }
        return p.inkSecondary
    }

    private var autoScrollButtonLabel: String {
        let l = controller.appLanguage
        if controller.isAutoScrolling {
            return L10n.tr("暂停", "Pause", in: l)
        }
        if controller.segmentCount > 0 {
            return L10n.tr("继续", "Resume", in: l)
        }
        return L10n.tr("自动翻页", "Auto-Scroll", in: l)
    }

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        let l = controller.appLanguage

        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusDotColor(palette: p))
                    .frame(width: 6.5, height: 6.5)
                Text("\(controller.pixelWidth) × \(controller.pixelHeight)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(p.inkMono)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                if !controller.statusHint.isEmpty {
                    Text(controller.statusHint)
                        .font(.system(size: 11))
                        .foregroundStyle(p.inkSecondary)
                        .lineLimit(1)
                        .help(controller.statusHint)
                }
            }

            Spacer(minLength: 8)

            if controller.needsAccessibilityAuth {
                Button(L10n.tr("授权", "Grant", in: l)) {
                    controller.openAccessibilityAuthorization()
                }
                .buttonStyle(LongshotBarPillStyle(role: .warning))
                .fixedSize(horizontal: true, vertical: false)
                .help(L10n.tr("打开辅助功能权限设置", "Open Accessibility Settings", in: l))
            }

            Button {
                controller.toggleAutoScroll()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: controller.isAutoScrolling ? "pause.fill" : "play.fill")
                        .font(.system(size: 9.5, weight: .bold))
                    Text(autoScrollButtonLabel)
                        .lineLimit(1)
                }
            }
            .buttonStyle(LongshotBarPillStyle(role: controller.isAutoScrolling ? .activeThumb : .secondary))
            .disabled(controller.heightLimitReached)
            .fixedSize(horizontal: true, vertical: false)
            .help(L10n.tr("自动翻页 / 暂停 (Space)", "Auto-Scroll / Pause (Space)", in: l))

            Button {
                controller.cycleScrollSpeed()
            } label: {
                Text(controller.scrollSpeed.title(in: l))
                    .lineLimit(1)
                    .frame(minWidth: 24)
            }
            .buttonStyle(LongshotBarPillStyle())
            .fixedSize(horizontal: true, vertical: false)
            .help(L10n.tr(
                "翻页速度：\(controller.scrollSpeed.title(in: l))（点击切换）",
                "Scroll speed: \(controller.scrollSpeed.title(in: l)) (click to cycle)",
                in: l
            ))

            Rectangle()
                .fill(p.cardBorder)
                .frame(width: 1, height: 15)
                .padding(.horizontal, 1)

            Button {
                controller.undoLastSegment()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(LongshotBarPillStyle())
            .disabled(!controller.canUndo)
            .help(L10n.tr("撤销上一段 (⌘Z)", "Undo last segment (⌘Z)", in: l))

            Button("OCR") {
                controller.finishAndOCR()
            }
            .buttonStyle(LongshotBarPillStyle())
            .fixedSize(horizontal: true, vertical: false)
            .help(L10n.tr("识字 (T)", "Extract Text (T)", in: l))

            Button(L10n.tr("标注", "Annotate", in: l)) {
                controller.finishAndAnnotate()
            }
            .buttonStyle(LongshotBarPillStyle())
            .fixedSize(horizontal: true, vertical: false)
            .help(L10n.tr("标注", "Annotate", in: l))

            Button(L10n.tr("复制", "Copy", in: l)) {
                controller.finishAndCopy()
            }
            .buttonStyle(LongshotBarPillStyle())
            .fixedSize(horizontal: true, vertical: false)
            .help(L10n.tr("仅复制到剪贴板 (⌘C)", "Copy to Clipboard (⌘C)", in: l))

            Button {
                let forceDialog = NSEvent.modifierFlags.contains(.option)
                controller.finishAndSave(forceDialog: forceDialog)
            } label: {
                HStack(spacing: 3.5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                    Text(L10n.tr("保存", "Save", in: l))
                        .lineLimit(1)
                }
            }
            .buttonStyle(LongshotBarPillStyle(role: .primary))
            .fixedSize(horizontal: true, vertical: false)
            .help(L10n.tr(
                "保存到默认位置并复制（Enter / ⌘S，按住 ⌥ 另存为）",
                "Save to default folder & copy (Enter / ⌘S, hold ⌥ for Save As)",
                in: l
            ))

            Button {
                controller.cancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(p.inkSecondary)
                    .frame(width: 22, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.tr("取消 (Esc)", "Cancel (Esc)", in: l))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10.5, style: .continuous)
                .fill(p.cardBg.opacity(0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10.5, style: .continuous)
                .strokeBorder(p.cardBorder, lineWidth: 1)
        )
    }
}
