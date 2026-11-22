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

@MainActor
public final class LongshotSessionController: ObservableObject {
    @Published public private(set) var pixelWidth: Int = 0
    @Published public private(set) var pixelHeight: Int = 0
    @Published public private(set) var segmentCount: Int = 0
    @Published public private(set) var canUndo: Bool = false
    @Published public private(set) var statusHint: String = ""
    @Published public private(set) var thumbnailImage: CGImage?
    @Published public private(set) var isAutoScrolling: Bool = false
    @Published public private(set) var needsAccessibilityAuth: Bool = false
    @Published public private(set) var reachedBottom: Bool = false
    @Published public private(set) var scrollSpeed: LongshotScrollSpeed

    private let screen: NSScreen
    private let viewportTopDown: ASRect
    private let backingScale: Double
    private let initialFallbackCrop: PixelBufferRGBA
    private let targetWindow: WindowSnapCandidate?
    private var config: AirSnipConfig
    private let autoStartRequested: Bool

    private var canvas: LongshotCanvas?
    private var borderWindow: NSPanel?
    private var previewWindow: NSPanel?
    private var controlWindow: ControlBarPanel?
    private var captureLoopTask: Task<Void, Never>?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalScrollMonitor: Any?
    private var isFinalizing: Bool = false

    private var frameSource: LongshotCaptureSource?
    private var hasLiveFrame = false
    private var manualScrollUntil: TimeInterval = 0
    private var confirmedPosition: Double?
    private var pendingScroll: Int?
    private var recoveredAtHeight: Int?
    private var scrollGain = 1.0
    private var stepScale = 1.0

    public var onSpeedChanged: ((LongshotScrollSpeed) -> Void)?
    public var onFinishCopy: ((CGImage, Double) -> Void)?
    public var onFinishSave: ((CGImage, Double, Bool) -> Void)?
    public var onFinishEdit: ((CGImage, Double, NSScreen) -> Void)?
    public var onFinishOCR: ((CGImage) -> Void)?
    public var onCancel: (() -> Void)?

    public init(
        screen: NSScreen,
        viewportTopDown: ASRect,
        initialCrop: PixelBufferRGBA,
        targetWindow: WindowSnapCandidate? = nil,
        config: AirSnipConfig,
        autoStartScroll: Bool = false
    ) {
        self.screen = screen
        self.viewportTopDown = viewportTopDown
        self.backingScale = Double(screen.backingScaleFactor)
        self.initialFallbackCrop = initialCrop
        self.targetWindow = targetWindow
        self.config = config
        self.scrollSpeed = config.longshotScrollSpeed
        self.autoStartRequested = autoStartScroll
        self.pixelWidth = initialCrop.width
        self.pixelHeight = min(initialCrop.height, config.longshotMaxHeight)

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
            beginAutoScrolling(initialDelayMs: 180)
        } else {
            startSessionLoop()
        }
    }

    public func stopAndCleanup() {
        isAutoScrolling = false
        captureLoopTask?.cancel()
        captureLoopTask = nil
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
            if pendingScroll == nil {
                pauseAutoScrolling()
            } else {
                // Let the wheel event already sent settle before taking the next command.
                isAutoScrolling = false
                statusHint = ""
            }
        } else if pendingScroll != nil, captureLoopTask != nil {
            isAutoScrolling = true
        } else {
            beginAutoScrolling(initialDelayMs: 90)
        }
    }

    public func beginAutoScrolling(initialDelayMs: UInt64 = 90) {
        guard !hasLiveFrame || pixelHeight < config.longshotMaxHeight else {
            stopAtHeightLimit()
            return
        }
        guard AccessibilityService.hasPermission() else {
            needsAccessibilityAuth = true
            isAutoScrolling = false
            _ = AccessibilityService.requestPermissionPrompt()
            statusHint = L10n.tr("需辅助功能权限", "Accessibility required", in: config.language)
            startSessionLoop()
            return
        }
        needsAccessibilityAuth = false
        reachedBottom = false
        isAutoScrolling = true
        statusHint = ""
        startSessionLoop(initialDelayMs: initialDelayMs)
    }

    public func pauseAutoScrolling(customHint: String? = nil) {
        isAutoScrolling = false
        captureLoopTask?.cancel()
        captureLoopTask = nil
        statusHint = customHint ?? ""
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
        let isEn = config.language.isEnglish
        let barW = min(max(isEn ? 536 : 496, vis.width - 24), isEn ? 584 : 544)
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

    var appLanguage: AppLanguage { config.language }

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
            let userTouchedTrackpad = (ev.phase != [] || ev.momentumPhase != []) && abs(ev.scrollingDeltaY) > 0
            let userRolledDiscreteWheel = (ev.phase == [] && ev.momentumPhase == [] && abs(ev.scrollingDeltaY) > 0.5)
            guard userTouchedTrackpad || userRolledDiscreteWheel else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.isFinalizing else { return }
                if self.isAutoScrolling || self.pendingScroll != nil {
                    self.pauseAutoScrolling()
                    self.pendingScroll = nil
                }
                self.manualScrollUntil = ProcessInfo.processInfo.systemUptime + 0.85
                if self.captureLoopTask == nil { self.startSessionLoop() }
            }
        }
    }

    private func startSessionLoop(initialDelayMs: UInt64 = 0) {
        captureLoopTask?.cancel()
        let automatically = isAutoScrolling
        captureLoopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: initialDelayMs * 1_000_000)
                let source = try await self.prepareFrameSource()
                if automatically {
                    source.positionCursor()
                    try await Task.sleep(nanoseconds: 55_000_000)
                }
                if !self.hasLiveFrame {
                    let frame = try await self.readInitialFrame(from: source)
                    try Task.checkCancellation()
                    self.canvas?.seed(frame.image, context: frame.context)
                    self.confirmedPosition = frame.position
                    self.hasLiveFrame = true
                    self.refreshPreview()
                    if self.pixelHeight >= self.config.longshotMaxHeight {
                        self.stopAtHeightLimit()
                        return
                    }
                } else if automatically, !(try await self.resumeAtVerifiedPosition(source)) {
                    return
                }
                if automatically {
                    try await self.runAutomaticScroll(source)
                } else {
                    try await self.followManualScroll(source)
                }
            } catch is CancellationError {
                return
            } catch LongshotCaptureSource.Failure.targetChanged {
                guard !Task.isCancelled else { return }
                self.pauseAutoScrolling(customHint: L10n.tr("目标窗口已变化，请重新框选", "Window changed. Select it again.", in: self.config.language))
            } catch {
                guard !Task.isCancelled else { return }
                self.pauseAutoScrolling(customHint: L10n.tr("暂时无法读取画面", "Could not read the selected area", in: self.config.language))
            }
        }
    }

    private func prepareFrameSource() async throws -> LongshotCaptureSource {
        if let frameSource { return frameSource }
        let source = try await LongshotCaptureSource(
            screen: screen, viewport: viewportTopDown, initialCrop: initialFallbackCrop,
            targetWindow: targetWindow, excludingWindowNumbers: currentOwnWindowIDs()
        )
        try Task.checkCancellation()
        frameSource = source
        return source
    }

    private func readInitialFrame(from source: LongshotCaptureSource) async throws -> LongshotCaptureSource.Frame {
        for delay: UInt64 in [0, 90, 180, 320] {
            try await Task.sleep(nanoseconds: delay * 1_000_000)
            if let frame = try await captureLiveFrame(from: source) { return frame }
        }
        throw LongshotCaptureSource.Failure.frameUnavailable
    }

    private func captureLiveFrame(
        from source: LongshotCaptureSource, measuringOffset: Bool = false
    ) async throws -> LongshotCaptureSource.Frame? {
        do {
            let frame = try await source.capture(measuringOffset: measuringOffset)
            try Task.checkCancellation()
            return frame
        } catch is CancellationError {
            throw CancellationError()
        } catch LongshotCaptureSource.Failure.targetChanged {
            throw LongshotCaptureSource.Failure.targetChanged
        } catch {
            return nil
        }
    }

    private func runAutomaticScroll(_ source: LongshotCaptureSource) async throws {
        var stationarySince: TimeInterval?
        var stationaryCount = 0
        var lastAdvanceWasShort = false
        while isAutoScrolling && !Task.isCancelled {
            if controlWindow?.frame.contains(NSEvent.mouseLocation) == true {
                try await Task.sleep(nanoseconds: 90_000_000)
                continue
            }

            let points = pendingScroll ?? scrollStep(source)
            if pendingScroll == nil {
                await source.rememberScrollAnchor(includeViewport: segmentCount == 0)
                try Task.checkCancellation()
                guard isAutoScrolling else { return }
                guard source.postScroll(points) else { throw LongshotCaptureSource.Failure.targetChanged }
                pendingScroll = points
            }
            let observation = try await observeScroll(source, delays: [scrollSpeed.settleMilliseconds, 75, 150, 260])
            if !isAutoScrolling {
                pendingScroll = nil
                captureLoopTask = nil
                if observation.result == .limitReached { stopAtHeightLimit() }
                return
            }
            switch observation.result {
            case .appended(let offset, _), .revisited(let offset):
                pendingScroll = nil
                recoveredAtHeight = nil
                stationarySince = nil
                stationaryCount = 0
                let expectedOffset = Double(points) * backingScale * scrollGain
                lastAdvanceWasShort = segmentCount > 1
                    && Double(offset) < expectedOffset - max(2, expectedOffset * 0.08)
                if (observation.position ?? 0) < 0.9999 {
                    let gain = Double(offset) / backingScale / Double(points)
                    scrollGain = max(0.5, min(4, gain))
                }
            case .still:
                pendingScroll = nil
                let now = ProcessInfo.processInfo.systemUptime
                stationarySince = stationarySince ?? now
                stationaryCount += 1
                guard stationaryCount >= 3, now - (stationarySince ?? now) >= 1.1 else { continue }
                // With no scrollbar value, a short last advance is evidence that the scroll hit a boundary.
                let measuredEnd = observation.position.map { $0 >= 0.9999 }
                let atEnd = measuredEnd ?? lastAdvanceWasShort
                if !atEnd && segmentCount == 0 && source.tryAnotherScrollPoint() {
                    source.positionCursor()
                    stationarySince = nil
                    stationaryCount = 0
                    continue
                }
                stopWhenStill(atEnd: atEnd, positionAtRegionEnd: measuredEnd == true)
                return
            case .limitReached:
                stopAtHeightLimit()
                return
            case .failed:
                let movedDown = hasMovedDown(to: observation.position) || (canvas?.unstitchedOffset ?? 0) > 0
                if (movedDown || hasChangedPosition(observation.position)) && recoveredAtHeight != pixelHeight {
                    recoveredAtHeight = pixelHeight
                    let recovered = try await recoverLastPosition(source, reverseScroll: movedDown ? -points : nil)
                    guard isAutoScrolling else {
                        pendingScroll = nil
                        captureLoopTask = nil
                        return
                    }
                    if recovered {
                        pendingScroll = nil
                        stepScale = max(0.12, stepScale * 0.5)
                        stationarySince = nil
                        stationaryCount = 0
                        lastAdvanceWasShort = false
                        continue
                    }
                    if pixelHeight >= config.longshotMaxHeight {
                        stopAtHeightLimit()
                        return
                    }
                }
                stopAfterInterruption()
                return
            }
        }
    }

    private func scrollStep(_ source: LongshotCaptureSource) -> Int {
        guard let canvas else { return 1 }
        let body = min(source.selectedBodyHeight, canvas.frameHeight - canvas.headerHeight - canvas.footerHeight)
        let points = Double(body) / backingScale
        if canvas.segmentCount == 0 {
            return max(1, Int(min(16, points * 0.20) * stepScale))
        }
        return max(1, min(220, Int(points * scrollSpeed.viewportStepFraction * 0.75 * stepScale / max(1, scrollGain))))
    }

    private func observeScroll(
        _ source: LongshotCaptureSource, delays: [UInt64]
    ) async throws -> (result: LongshotStepResult, position: Double?) {
        var observation: (LongshotStepResult, Double?) = (.failed, nil)
        for (attempt, delay) in delays.enumerated() {
            try await Task.sleep(nanoseconds: delay * 1_000_000)
            guard let frame = try await captureLiveFrame(from: source, measuringOffset: true) else { continue }
            let finalAttempt = attempt == delays.count - 1
            if segmentCount == 0, source.hasInnerViewportAnchor, frame.measurement?.viewportRows == nil, !finalAttempt {
                continue
            }
            let result = processFrame(frame, automatic: true, verifyStationary: finalAttempt)
            switch result {
            case .appended, .revisited, .limitReached:
                source.confirmViewport(from: frame)
                return (result, frame.position)
            case .still:
                observation = (hasChangedPosition(frame.position) ? .failed : .still, frame.position)
            case .failed:
                observation = (.failed, frame.position)
            }
        }
        return observation
    }

    private func hasMovedDown(to position: Double?) -> Bool {
        guard let confirmedPosition, let position else { return false }
        return position - confirmedPosition > 0.000_001
    }

    private func hasChangedPosition(_ position: Double?) -> Bool {
        guard let confirmedPosition, let position else { return false }
        return abs(position - confirmedPosition) > 0.000_001
    }

    private func isConfirmedPosition(_ position: Double?) -> Bool {
        guard let confirmedPosition, let position else { return false }
        return position == confirmedPosition
    }

    private func recoverLastPosition(_ source: LongshotCaptureSource, reverseScroll: Int?) async throws -> Bool {
        var restored = false
        if let confirmedPosition {
            restored = await source.restorePosition(confirmedPosition)
            try Task.checkCancellation()
        }
        guard isAutoScrolling else { return false }
        if !restored {
            guard let reverseScroll, source.postScroll(reverseScroll) else { return false }
        }
        let observation = try await observeScroll(source, delays: [100, 140, 260])
        switch observation.result {
        case .still:
            return true
        case .appended, .revisited:
            return true
        case .limitReached, .failed:
            return false
        }
    }

    private func resumeAtVerifiedPosition(_ source: LongshotCaptureSource) async throws -> Bool {
        let current = try await readInitialFrame(from: source)
        if reconnect(current) { return isAutoScrolling }

        if let confirmedPosition, await source.restorePosition(confirmedPosition) {
            for delay: UInt64 in [130, 200, 300] {
                try await Task.sleep(nanoseconds: delay * 1_000_000)
                if let frame = try await captureLiveFrame(from: source), reconnect(frame) {
                    return isAutoScrolling
                }
            }
        }
        try Task.checkCancellation()
        stopAfterInterruption()
        return false
    }

    private func reconnect(_ frame: LongshotCaptureSource.Frame) -> Bool {
        guard let canvas else { return false }
        let step = canvas.reconnect(frame.image, context: frame.context, positionIsUnchanged: isConfirmedPosition(frame.position))
        guard step != .failed, step != .still || !hasChangedPosition(frame.position) else { return false }
        accept(step, position: frame.position)
        if step == .limitReached { stopAtHeightLimit() }
        pendingScroll = nil
        return true
    }

    private func followManualScroll(_ source: LongshotCaptureSource) async throws {
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 100_000_000)
            if needsAccessibilityAuth, AccessibilityService.hasPermission() {
                needsAccessibilityAuth = false
                statusHint = ""
                if segmentCount == 0 {
                    frameSource = nil
                    hasLiveFrame = false
                    beginAutoScrolling()
                    return
                }
            }
            guard ProcessInfo.processInfo.systemUptime < manualScrollUntil,
                  let frame = try await captureLiveFrame(from: source) else { continue }
            switch processFrame(frame, automatic: false) {
            case .appended, .revisited:
                pendingScroll = nil
                statusHint = ""
            case .still:
                break
            case .failed:
                statusHint = L10n.tr("拼接中断，可继续或保留结果", "Stitching stopped. Resume or keep the result.", in: config.language)
            case .limitReached:
                stopAtHeightLimit()
                return
            }
        }
    }

    private func processFrame(
        _ frame: LongshotCaptureSource.Frame, automatic: Bool, verifyStationary: Bool = false
    ) -> LongshotStepResult {
        guard let canvas else { return .still }
        let measurement = frame.measurement.flatMap {
            $0.offset != 0 || (verifyStationary && frame.position == nil) ? $0 : nil
        } ?? (isConfirmedPosition(frame.position) ? LongshotScrollMeasurement(offset: 0) : nil)
        let step = canvas.push(frame.image, context: frame.context, downwardOnly: automatic,
                               refreshStationaryFrame: !hasChangedPosition(frame.position),
                               measurement: measurement)
        accept(step, position: frame.position)
        return step
    }

    private func accept(_ step: LongshotStepResult, position: Double?) {
        switch step {
        case .appended, .limitReached:
            confirmedPosition = position
            reachedBottom = false
            refreshPreview()
        case .revisited:
            confirmedPosition = position
        case .still, .failed:
            break
        }
    }

    private func refreshPreview() {
        guard let canvas else { return }
        pixelHeight = canvas.totalHeight
        segmentCount = canvas.segmentCount
        canUndo = canvas.canUndo
        thumbnailImage = canvas.makeThumbnail(maxWidth: 160, maxHeight: 420)
    }

    private func stopAtHeightLimit() {
        pauseAutoScrolling(customHint: L10n.tr("已达高度上限", "Height limit reached", in: config.language))
    }

    private func stopWhenStill(atEnd: Bool, positionAtRegionEnd: Bool) {
        if atEnd {
            canvas?.includeVisibleTail(positionAtRegionEnd: positionAtRegionEnd)
            refreshPreview()
            if pixelHeight >= config.longshotMaxHeight {
                stopAtHeightLimit()
                return
            }
        }
        reachedBottom = atEnd
        pauseAutoScrolling(customHint: atEnd
            ? L10n.tr("已到末尾", "Reached the end", in: config.language)
            : L10n.tr("未检测到继续滚动", "The selected area did not scroll", in: config.language))
    }

    private func stopAfterInterruption() {
        pauseAutoScrolling(customHint: L10n.tr(
            "拼接中断，已保留结果，可重新框选", "Stitching stopped. Result kept. Select again to restart.", in: config.language
        ))
    }

    public func undoLastSegment() {
        if isAutoScrolling { pauseAutoScrolling() }
        guard let canvas, canvas.undoLast() else { return }
        reachedBottom = false
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

    private func exportCurrentCanvasCGImage() -> CGImage? {
        if let cg = canvas?.exportBuffer()?.makeCGImage() {
            return cg
        }
        return initialFallbackCrop.makeCGImage()
    }

    private func finalizeSessionAndExport(completion: @escaping (CGImage) -> Void) {
        guard !isFinalizing else { return }
        if borderWindow != nil && targetWindow != nil && !hasLiveFrame {
            statusHint = L10n.tr("正在读取选区画面", "Reading the selected area", in: config.language)
            return
        }
        isFinalizing = true
        stopAndCleanup()
        if let cg = exportCurrentCanvasCGImage() {
            completion(cg)
        } else {
            onCancel?()
        }
    }

    public func finishAndCopy() {
        let scale = backingScale
        finalizeSessionAndExport { [weak self] cg in
            self?.onFinishCopy?(cg, scale)
        }
    }

    public func finishAndSave(forceDialog: Bool = false) {
        let scale = backingScale
        finalizeSessionAndExport { [weak self] cg in
            self?.onFinishSave?(cg, scale, forceDialog)
        }
    }

    public func finishAndAnnotate() {
        let scale = backingScale
        let scr = screen
        finalizeSessionAndExport { [weak self] cg in
            self?.onFinishEdit?(cg, scale, scr)
        }
    }

    public func finishAndOCR() {
        finalizeSessionAndExport { [weak self] cg in
            self?.onFinishOCR?(cg)
        }
    }

    public func cancel() {
        guard !isFinalizing else { return }
        isFinalizing = true
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
        if controller.segmentCount > 0 && !controller.reachedBottom {
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
                        .fixedSize(horizontal: true, vertical: false)
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
