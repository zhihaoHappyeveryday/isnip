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

    private var canvas: LongshotCanvas
    private var captureSource: LongshotViewport.Source?
    private var canUseFrozenReference = true
    private var hasStitchedSegment = false
    private var borderWindow: NSPanel?
    private var previewWindow: NSPanel?
    private var hasFloatingStartPreview = false
    private var controlWindow: ControlBarPanel?
    private var captureLoopTask: Task<Void, Never>?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalScrollMonitor: Any?
    private var pendingOutput: ((CGImage) -> Void)?

    private struct StartPreview {
        let frame: LongshotViewport.Frame?
        let hint: String
        var recheckAfterScroll = false
    }

    private enum ViewportPosition {
        case connected
        case settling(LongshotFrameMode)
        case unmatched(LongshotFrameMode)
        case awaitingStart(StartPreview)
        case heightLimit

        var isSettling: Bool {
            if case .settling = self { return true }
            return false
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        var startPreview: StartPreview? {
            if case .awaitingStart(let preview) = self { return preview }
            return nil
        }

        var frameMode: LongshotFrameMode {
            switch self {
            case .settling(let mode), .unmatched(let mode): return mode
            case .connected, .awaitingStart, .heightLimit: return .manual
            }
        }
    }

    private var viewportPosition: ViewportPosition = .connected
    private var captureRevision = 0
    private var captureContinuation: AsyncStream<LongshotViewport.Frame>.Continuation?
    private var restoreTask: Task<Bool, Never>?
    private var autoScrollStartDelay: UInt64?
    private var adaptiveScale = 1.0
    private var rewoundSinceLastSegment = false
    private var confirmedPosition: LongshotViewport.Position?
    private var lastScroll: (points: Int, pixels: Int)?
    private var nextStepLimit: Int?

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
        autoStartScroll: Bool = false,
        snapshot: CapturedScreenSnapshot? = nil
    ) {
        let viewport = LongshotViewport.desktop(screen: screen, selection: viewportTopDown, snapshot: snapshot)
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
        self.captureSource = viewport.initialSource
        self.autoStartRequested = autoStartScroll
        self.pixelWidth = initialCrop.width
        self.pixelHeight = initialCrop.height

        let stitchCanvas = Self.makeCanvas(startingWith: initialCrop, maxHeight: config.longshotMaxHeight)
        self.canvas = stitchCanvas
        self.thumbnailImage = stitchCanvas.makeThumbnail(maxWidth: 160, maxHeight: 420)
    }

    private static func makeCanvas(
        startingWith frame: PixelBufferRGBA, maxHeight: Int, reference: LongshotReference? = nil
    ) -> LongshotCanvas {
        let canvas = LongshotCanvas(
            width: frame.width,
            frameHeight: frame.height,
            params: LongshotParams(minRatio: 0.84, minFixedRows: 8),
            maxHeight: maxHeight
        )
        canvas.seed(frame, reference: reference)
        return canvas
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
        invalidateCapture()
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
            if canRestartFromPreview, let event = NSApp.currentEvent,
               event.type == .leftMouseUp, event.clickCount > 1 { return }
            beginAutoScrolling(initialDelayMs: 90)
        }
    }

    private func toggleAutoScrollFromKeyboard() {
        guard !canRestartFromPreview else { return }
        toggleAutoScroll()
    }

    public func beginAutoScrolling(initialDelayMs: UInt64 = 90) {
        guard pendingOutput == nil, !heightLimitReached else { return }
        guard viewport.hasAccessibilityPermission() else {
            needsAccessibilityAuth = true
            isAutoScrolling = false
            _ = AccessibilityService.requestPermissionPrompt()
            statusHint = L10n.tr("需辅助功能权限", "Accessibility required", in: config.language)
            return
        }
        needsAccessibilityAuth = false
        invalidateCapture()
        autoScrollStartDelay = initialDelayMs
        isAutoScrolling = true
        statusHint = ""
    }

    public func pauseAutoScrolling() {
        guard isAutoScrolling else { return }
        invalidateCapture()
        isAutoScrolling = false
        if let preview = viewportPosition.startPreview { statusHint = preview.hint }
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
        let previewW = Self.previewWidth
        let previewH = min(max(200, vpAppKit.height), sFrame.height - 80)
        var previewX: CGFloat?
        if rightSpace >= previewW + 20 {
            previewX = vpAppKit.maxX + 12
        } else if leftSpace >= previewW + 20 {
            previewX = vpAppKit.minX - previewW - 12
        }
        if let px = previewX {
            showPreviewWindow(in: NSRect(x: px, y: vpAppKit.minY, width: previewW, height: previewH))
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

    private static let previewWidth: CGFloat = 156

    private func showPreviewWindow(in frame: NSRect) {
        let window = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        applyWindowTheme(to: window)
        window.contentView = NSHostingView(rootView: LongshotPreviewCard(controller: self))
        window.orderFrontRegardless()
        previewWindow = window
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
    var heightLimitReached: Bool {
        if case .heightLimit = viewportPosition { return true }
        return false
    }

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
            case 101: self.toggleAutoScrollFromKeyboard()
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
                if !ev.isARepeat { self.toggleAutoScrollFromKeyboard() }
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
                self?.handleManualScroll()
            }
        }
    }

    func handleManualScroll() {
        pauseAutoScrolling()
        if var preview = viewportPosition.startPreview {
            preview.recheckAfterScroll = true
            viewportPosition = .awaitingStart(preview)
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
            if autoStartRequested && !hasStitchedSegment && viewportPosition.startPreview == nil && !isAutoScrolling {
                beginAutoScrolling(initialDelayMs: 120)
            } else if !isAutoScrolling {
                statusHint = viewportPosition.startPreview?.hint ?? ""
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
        if var preview = viewportPosition.startPreview {
            if preview.recheckAfterScroll {
                preview.recheckAfterScroll = false
                viewportPosition = .awaitingStart(preview)
                let capture = await captureAndMatch(revision: revision, mode: .reconnecting)
                guard isCurrent(revision), let step = capture.result, step != .failed else { return }
                closeFloatingStartPreview()
                refreshPreview()
                applyCaptureResult(step)
            }
            return
        }
        await checkCurrentViewport(revision: revision, retryFailure: false)
    }

    private func checkCurrentViewport(revision: Int, retryFailure: Bool) async {
        let capture = await captureAndMatch(
            revision: revision, mode: viewportPosition.frameMode,
            attempts: retryFailure || viewportPosition.isSettling ? 3 : 1,
            retryStill: viewportPosition.isSettling
        )
        guard isCurrent(revision) else { return }
        applyCaptureResult(capture.result)
    }

    private func invalidateCapture() {
        captureRevision += 1
        captureContinuation?.finish()
        restoreTask?.cancel()
    }

    private func isCurrent(_ revision: Int) -> Bool {
        !Task.isCancelled && captureRevision == revision
    }

    private struct ViewportMatch {
        var frame: LongshotViewport.Frame?
        var result: LongshotStepResult?
        var retried = false
        var position: LongshotViewport.Position? { frame?.position }
    }

    private func captureAndMatch(
        revision: Int, mode: LongshotFrameMode, attempts: Int = 3, retryStill: Bool = false,
        restoring positionToRestore: LongshotViewport.Position? = nil
    ) async -> ViewportMatch {
        let deadline = ContinuousClock.now + .seconds(3)
        var capture = ViewportMatch()
        for attempt in 0..<attempts {
            if attempt > 0 {
                let retryAt = min(deadline, ContinuousClock.now + .milliseconds(110))
                try? await Task.sleep(until: retryAt, clock: .continuous)
            }
            guard isCurrent(revision), ContinuousClock.now < deadline else { break }
            let frame = await captureFrame(until: deadline)
            guard isCurrent(revision) else { break }

            guard let frame else {
                // Keep the latest picture for preview, even if the viewport is no longer confirmed.
                if capture.result != .failed { capture.result = nil }
                continue
            }
            guard !frame.needsTarget, acceptsSource(frame, expected: captureSource),
                  positionToRestore == nil || frame.position == positionToRestore else {
                capture = ViewportMatch(frame: frame, result: .failed, retried: attempt > 0)
                continue
            }
            seedInitialReference(from: frame)
            let step = canvas.push(
                frame.image, mode: mode, reference: frame.reference,
                requireMovement: positionChanged(from: confirmedPosition, to: frame.position)
            )
            recordStitch(step)
            if step != .failed && step != .limitReached { confirm(frame) }
            capture = ViewportMatch(frame: frame, result: step, retried: attempt > 0)
            if step != .failed && (!retryStill || !step.isStationary) { break }
        }
        return capture
    }

    private func prepareFirstFrame(revision: Int) async {
        let preview = viewportPosition.startPreview?.frame
        let startCanvas = preview.map {
            Self.makeCanvas(startingWith: $0.image, maxHeight: canvas.maxHeight, reference: $0.reference)
        } ?? canvas
        let mode = viewportPosition.frameMode
        let deadline = ContinuousClock.now + .seconds(3)
        var latestFrame: LongshotViewport.Frame?
        for delay in [0, 300, 500, 700, 900] {
            let retryAt = min(deadline, ContinuousClock.now + .milliseconds(delay))
            try? await Task.sleep(until: retryAt, clock: .continuous)
            guard isCurrent(revision) else { return }
            guard ContinuousClock.now < deadline else { break }
            let frame = await captureFrame(until: deadline)
            guard isCurrent(revision) else { return }
            guard let frame else { continue }
            if frame.needsTarget {
                statusHint = L10n.tr("把鼠标移到要截的正文上", "Move the pointer over the content to capture", in: config.language)
                autoScrollStartDelay = 150
                return
            }

            latestFrame = frame
            let expected = preview?.source ?? captureSource
            guard acceptsSource(frame, expected: expected) else { continue }
            if preview == nil { seedInitialReference(from: frame) }
            let startingPosition = preview == nil ? (confirmedPosition ?? frame.initialPosition) : preview?.position
            let moved = positionChanged(from: startingPosition, to: frame.position)
            let samePosition = startingPosition != nil && startingPosition == frame.position
            let step: LongshotStepResult
            if preview != nil {
                guard !moved else { continue }
                step = startCanvas.confirmPreview(with: frame.image, reference: frame.reference)
            } else {
                step = startCanvas.confirmStart(with: frame.image, mode: mode, reference: frame.reference,
                                                samePosition: samePosition, requireMovement: moved)
            }
            guard step != .failed else { continue }
            canvas = startCanvas
            confirm(frame)
            closeFloatingStartPreview()
            if preview != nil {
                lastScroll = nil
                nextStepLimit = nil
            }
            recordStitch(step)
            if step == .still || step == .limitReached { refreshPreview() }
            applyCaptureResult(step)
            return
        }
        pauseBeforeFirstSegment(latestFrame: latestFrame, previousPreview: preview)
    }

    private func captureFrame(until deadline: ContinuousClock.Instant) async -> LongshotViewport.Frame? {
        // A system capture may outlast the deadline even after cancellation.
        let (frames, continuation) = AsyncStream<LongshotViewport.Frame>.makeStream()
        captureContinuation = continuation
        let windowIDs = currentOwnWindowIDs()
        let capture = Task { [viewport] in
            if let frame = await viewport.capture(windowIDs) {
                continuation.yield(frame)
            }
            continuation.finish()
        }
        let timeout = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            continuation.finish()
        }
        defer {
            captureContinuation = nil
            capture.cancel()
            timeout.cancel()
        }
        var iterator = frames.makeAsyncIterator()
        guard let frame = await iterator.next(), ContinuousClock.now < deadline,
              frame.image.width == canvas.width, frame.image.height == canvas.frameHeight else { return nil }
        return frame
    }

    private func pauseBeforeFirstSegment(
        latestFrame: LongshotViewport.Frame?, previousPreview: LongshotViewport.Frame? = nil, afterScroll: Bool = false
    ) {
        isAutoScrolling = false
        let preview = latestFrame ?? previousPreview
        if let preview {
            thumbnailImage = preview.image.makeCGImage()
            if previewWindow == nil {
                let visible = screen.visibleFrame
                showPreviewWindow(in: NSRect(
                    x: visible.maxX - Self.previewWidth - 12, y: visible.maxY - 212,
                    width: Self.previewWidth, height: 200
                ))
                hasFloatingStartPreview = true
            }
        }
        let hint: String
        if latestFrame == nil {
            hint = L10n.tr("未抓到画面，点「自动翻页」重试", "No screen captured. Click Auto-Scroll to retry.", in: config.language)
        } else if afterScroll {
            hint = L10n.tr(
                "首段未拼上，可从预览处开始",
                "First segment did not match. You can start from the preview.", in: config.language
            )
        } else {
            hint = L10n.tr(
                "无法确认起点，可从预览处开始",
                "Cannot confirm the start. You can start from the preview.", in: config.language
            )
        }
        viewportPosition = .awaitingStart(StartPreview(frame: preview, hint: hint))
        statusHint = hint
    }

    var canRestartFromPreview: Bool { viewportPosition.startPreview?.frame != nil }

    private func closeFloatingStartPreview() {
        if hasFloatingStartPreview {
            previewWindow?.orderOut(nil)
            previewWindow = nil
            hasFloatingStartPreview = false
        }
    }

    private func acceptsSource(_ frame: LongshotViewport.Frame, expected: LongshotViewport.Source?) -> Bool {
        guard let expected else { return true }
        return frame.source.map(expected.matches) ?? false
    }

    private func confirm(_ frame: LongshotViewport.Frame) {
        canUseFrozenReference = false
        captureSource = frame.source ?? captureSource
        confirmedPosition = frame.position
    }

    private func positionChanged(from previous: LongshotViewport.Position?, to current: LongshotViewport.Position?) -> Bool {
        guard let previous, let current else { return false }
        return previous.targetID == current.targetID && previous.fraction != current.fraction
    }

    private func seedInitialReference(from frame: LongshotViewport.Frame) {
        guard canUseFrozenReference, let reference = frame.initialReference,
              let original = canvas.exportBuffer() else { return }
        canUseFrozenReference = false
        canvas.seed(original, reference: reference)
    }

    private func autoScroll(revision: Int) async {
        if let delay = autoScrollStartDelay {
            autoScrollStartDelay = nil
            try? await Task.sleep(for: .milliseconds(delay))
            guard isCurrent(revision) else { return }
            if hasStitchedSegment {
                let capture = await captureAndMatch(revision: revision, mode: .reconnecting)
                guard isCurrent(revision) else { return }
                applyCaptureResult(capture.result)
                if capture.result == nil || capture.result == .failed { isAutoScrolling = false }
            } else {
                await prepareFirstFrame(revision: revision)
            }
            if isCurrent(revision), isAutoScrolling, autoScrollStartDelay == nil {
                await viewport.positionCursor(controlWindow?.frame) { self.isCurrent(revision) }
                try? await Task.sleep(for: .milliseconds(55))
            }
            return
        }

        if confirmedPosition?.isAtEnd == true {
            stopAtEnd()
            return
        }
        let distance = autoScrollDistance()
        guard distance > 0 else {
            isAutoScrolling = false
            statusHint = L10n.tr("重新框选，多框几行正文", "Select a taller area with more scrolling content", in: config.language)
            return
        }

        await scrollAndSettle(distance, revision: revision)
        let capture = await captureAndMatch(revision: revision, mode: .automatic, retryStill: true)
        guard isCurrent(revision) else { return }

        if capture.result == .failed, !rewoundSinceLastSegment,
           let frame = capture.frame, acceptsSource(frame, expected: captureSource),
           let confirmedPosition, let position = capture.position,
           position.targetID == confirmedPosition.targetID, position.fraction > confirmedPosition.fraction {
            rewoundSinceLastSegment = true
            await recoverAfterScroll(to: confirmedPosition, afterStep: distance, capture: capture, revision: revision)
            return
        }
        guard let result = capture.result, result != .failed else {
            pauseAfterFailedScroll(capture)
            return
        }
        applyCaptureResult(result)
        if case .appended(let offset, _) = result, offset > 0 {
            lastScroll = (distance, offset)
            nextStepLimit = capture.retried ? max(1, distance / 2) : nil
            adaptiveScale = capture.retried ? max(0.30, adaptiveScale * 0.75) : min(1, adaptiveScale * 1.15)
        }
        if capture.position?.isAtEnd == true, result != .limitReached {
            stopAtEnd()
        } else if result.isStationary {
            isAutoScrolling = false
            statusHint = L10n.tr("未检测到新内容", "No new content", in: config.language)
        }
    }

    private func stopAtEnd() {
        isAutoScrolling = false
        statusHint = segmentCount > 0
            ? L10n.tr("已到末尾，可以复制或保存", "Reached the end. Copy or save the capture.", in: config.language)
            : L10n.tr("未检测到新内容", "No new content", in: config.language)
    }

    private func recoverAfterScroll(
        to position: LongshotViewport.Position, afterStep distance: Int, capture: ViewportMatch, revision: Int
    ) async {
        let restore = Task { [viewport] in await viewport.restorePosition(position) }
        restoreTask = restore
        let restored = await restore.value
        restoreTask = nil
        guard isCurrent(revision) else { return }
        guard restored else {
            pauseAfterFailedScroll(capture)
            return
        }
        adaptiveScale = max(0.30, adaptiveScale * 0.60)
        lastScroll = nil
        nextStepLimit = max(1, distance / 2)
        viewportPosition = .settling(.reconnecting)
        try? await Task.sleep(for: .milliseconds(scrollSpeed.settleMilliseconds))
        guard isCurrent(revision) else { return }
        let recovered = await captureAndMatch(revision: revision, mode: .reconnecting, restoring: position)
        guard isCurrent(revision) else { return }
        if let result = recovered.result, result != .failed {
            applyCaptureResult(result)
        } else {
            pauseAfterFailedScroll(ViewportMatch(frame: recovered.frame ?? capture.frame, result: recovered.result))
        }
    }

    private func pauseAfterFailedScroll(_ capture: ViewportMatch) {
        if hasStitchedSegment {
            isAutoScrolling = false
            applyCaptureResult(capture.result)
        } else {
            pauseBeforeFirstSegment(latestFrame: capture.frame, afterScroll: true)
        }
    }

    private func autoScrollDistance() -> Int {
        let bodyHeight = Double(canvas.scrollingBodyHeight) / backingScale
        let overlap = min(40 / backingScale, max(4 / backingScale, bodyHeight / 3))
        let maximum = min(bodyHeight * scrollSpeed.viewportStepFraction * adaptiveScale, bodyHeight - overlap)
        guard maximum >= 1 else { return 0 }
        let pointLimit = min(nextStepLimit ?? Int(maximum), Int(maximum))
        guard let lastScroll else { return min(pointLimit, 6, max(1, Int(maximum / 4))) }
        let pixelsPerPoint = Double(lastScroll.pixels) / Double(lastScroll.points)
        let desired = min(maximum * backingScale, Double(lastScroll.pixels) * 2)
        return max(1, min(pointLimit, Int(desired / pixelsPerPoint)))
    }

    private func scrollAndSettle(_ distance: Int, revision: Int) async {
        while isCurrent(revision), controlWindow?.frame.contains(NSEvent.mouseLocation) == true {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard isCurrent(revision) else { return }

        viewportPosition = .settling(.automatic)
        let tickCount = max(3, Int(ceil(Double(distance) / 220.0)))
        let pointsPerTick = distance / tickCount
        let remainder = distance % tickCount
        for tick in 0..<tickCount {
            guard isCurrent(revision) else { return }
            let points = pointsPerTick + (tick < remainder ? 1 : 0)
            if points > 0 { viewport.scroll(points) }
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
            if !viewportPosition.isConnected { statusHint = "" }
            viewportPosition = .connected
        case .limitReached:
            isAutoScrolling = false
            viewportPosition = .heightLimit
            statusHint = L10n.tr("已达上限", "Height limit reached", in: config.language)
        case .failed, nil:
            let mode: LongshotFrameMode = viewportPosition.frameMode == .manual ? .manual : .reconnecting
            viewportPosition = .unmatched(mode)
            if result == nil {
                statusHint = L10n.tr("未抓到画面，请重试", "Could not capture the view. Try again.", in: config.language)
            } else if hasStitchedSegment {
                statusHint = L10n.tr(
                    "拼接中断，请手动滚到能接上的位置",
                    "Stitch interrupted. Scroll manually to reconnect.", in: config.language
                )
            } else {
                statusHint = L10n.tr(
                    "画面接不上，点「自动翻页」重试",
                    "Cannot match the view. Click Auto-Scroll to retry.", in: config.language
                )
            }
        }
    }

    private func recordStitch(_ step: LongshotStepResult) {
        if case .appended = step {
            hasStitchedSegment = true
            rewoundSinceLastSegment = false
            refreshPreview()
        } else if step == .refreshed {
            refreshPreview()
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
        invalidateCapture()
        isAutoScrolling = false
        confirmedPosition = nil
        if heightLimitReached { viewportPosition = .unmatched(.manual) }
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
        invalidateCapture()
        if viewportPosition.startPreview != nil {
            statusHint = L10n.tr(
                "尚未拼成长截图，请先点「自动翻页」",
                "No long screenshot yet. Click Auto-Scroll first.", in: config.language
            )
            return
        }
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
        guard viewportPosition.isConnected || heightLimitReached else { return }
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
        if controller.canRestartFromPreview {
            return L10n.tr("从这里开始", "Start Here", in: l)
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
