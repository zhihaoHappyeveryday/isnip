import AppKit
import Carbon
import SwiftUI
import AirSnipCore

@MainActor
public final class AirSnipAppController: NSObject, ObservableObject, NSMenuDelegate {
    @Published public private(set) var config: AirSnipConfig
    @Published public private(set) var hotkeyRegistrationErrors: [String] = []

    public let hotkeyManager = GlobalHotkeyManager()
    public let pinManager = PinManager()
    public let ocrBubbleManager = OCRBubbleManager()
    public var settingsController: SettingsWindowController?

    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu(title: "iSnip")
    private var activeCaptureSession: CaptureSessionCoordinator?
    private var activeLongshotSession: LongshotSessionController?
    private var isCapturingSnapshots = false
    private let selectionTranslation = SelectionTranslationController()
    private var selectionSourceApplication: NSRunningApplication?
    public let configURL: URL

    private static let singleInstanceActivateNotification = Notification.Name("io.zzusec.airsnip.activateSettings")

    public init(configURL: URL = AirSnipConfig.defaultConfigFileURL()) {
        self.configURL = configURL
        let loadedConfig = AirSnipConfig.load(from: configURL)
        L10n.current = loadedConfig.language
        self.config = loadedConfig
        super.init()

        self.ocrBubbleManager.appLanguage = loadedConfig.language
        self.settingsController = SettingsWindowController(appController: self)

        pinManager.getConfig = { [weak self] in
            self?.config ?? AirSnipConfig()
        }
        pinManager.updateConfig = { [weak self] block in
            self?.updateConfig(block)
        }
        pinManager.onRequestAnnotatePin = { [weak self] pin in
            self?.startPinInlineEditSession(pin: pin)
        }
        pinManager.onRequestOCRPin = { [weak self] pin in
            guard let self else { return }
            let f = pin.window.frame
            let anchor = NSPoint(x: f.midX, y: f.midY)
            self.ocrBubbleManager.recognizeAndPresent(
                rawSelectionImage: pin.cgImage,
                anchorScreenPoint: anchor,
                config: self.config
            )
        }

        ocrBubbleManager.onConfigChanged = { [weak self] lang, autoCopy, mergeBreaks in
            self?.updateConfig {
                $0.ocr.language = lang
                $0.ocr.autoCopy = autoCopy
                $0.ocr.mergeLineBreaks = mergeBreaks
            }
        }
        ocrBubbleManager.onTranslationTargetChanged = { [weak self] language in
            self?.updateConfig { $0.translation.targetLanguage = language }
        }
        selectionTranslation.canShowButton = { [weak self] in
            guard let self else { return false }
            return self.activeCaptureSession == nil && self.activeLongshotSession == nil && !self.isCapturingSnapshots
        }
        selectionTranslation.onTranslate = { [weak self] text, anchor in
            guard let self else { return }
            self.ocrBubbleManager.presentSelectedText(text, anchorScreenPoint: anchor, config: self.config)
        }

        hotkeyManager.onTrigger = { [weak self] action in
            guard let self else { return }
            switch action {
            case .screenshot:
                self.triggerCapture()
            case .windowCapture:
                self.triggerDirectWindowCapture()
            case .longshotCapture:
                self.triggerDirectLongshotCapture()
            case .ocrCapture:
                self.triggerDirectOCRCapture()
            case .translateSelection:
                self.triggerSelectionTranslation()
            case .translateCapture:
                self.triggerOCRTranslation()
            case .pin:
                self.triggerGlobalPinFromClipboard()
            case .pinBorderToggle:
                self.pinManager.toggleAllBorders()
            }
        }
    }

    public func bootstrap() {
        setupStatusBarItem()
        hotkeyRegistrationErrors = hotkeyManager.apply(hotkeys: config.hotkeys)
        if #available(macOS 15.0, *) {
            selectionTranslation.setEnabled(config.translation.showSelectionButton)
        }
        LocalVisionOCR.prewarm(languagePreference: config.ocr.language)

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(onExternalShowSettings(_:)),
            name: Self.singleInstanceActivateNotification,
            object: nil
        )

        // One-shot silent update check 3 seconds after launch (no polling timer, 0% idle CPU)
        if config.autoCheckUpdate {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                if case .success(let rel?) = await UpdateChecker.checkLatest(),
                   self.config.skippedVersion != rel.version {
                    ToastHUD.show(
                        L10n.tr("发现新版本 v\(rel.version)", "New version v\(rel.version) available", in: self.config.language),
                        symbol: "arrow.down.circle",
                        duration: 3.0
                    )
                }
            }
        }
    }

    @objc private func onExternalShowSettings(_ note: Notification) {
        openSettings()
    }

    public static func notifyExistingInstanceAndExitIfDuplicate() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID && !$0.isTerminated }
        if !others.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(
                singleInstanceActivateNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            exit(0)
        }
    }

    public func updateConfig(_ mutate: (inout AirSnipConfig) -> Void) {
        let oldHotkeys = config.hotkeys
        let oldLang = config.language
        let oldSelectionButton = config.translation.showSelectionButton
        mutate(&config)
        L10n.current = config.language
        try? config.save(to: configURL)
        if config.language != oldLang {
            ocrBubbleManager.appLanguage = config.language
            selectionTranslation.refreshLanguage()
        }
        if config.hotkeys != oldHotkeys || config.language != oldLang {
            hotkeyRegistrationErrors = hotkeyManager.apply(hotkeys: config.hotkeys, lang: config.language)
        }
        if config.translation.showSelectionButton != oldSelectionButton, #available(macOS 15.0, *) {
            if config.translation.showSelectionButton { SelectedTextService.requestAccess() }
            selectionTranslation.setEnabled(config.translation.showSelectionButton)
        }
    }

    // MARK: - Menu Bar Status Item

    private func setupStatusBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = makeMenuBarTemplateIcon()
            button.toolTip = "iSnip"
        }
        statusMenu.delegate = self
        populateStatusMenu(statusMenu)
        item.menu = statusMenu
        self.statusItem = item
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populateStatusMenu(menu)
    }

    public func menuWillOpen(_ menu: NSMenu) {
        selectionSourceApplication = NSWorkspace.shared.frontmostApplication
    }

    private func menuIcon(_ symbolName: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13.0, weight: .medium)
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        img?.isTemplate = true
        return img
    }

    private func applyMenuShortcut(_ binding: HotkeyBinding, to item: NSMenuItem, baseTitle: String) {
        if binding.isUnbound {
            item.title = baseTitle
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        if let mb = binding.mouseButton {
            item.title = "\(baseTitle)  (\(mb.displayName))"
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        guard let kc = binding.keyCode, let keyEq = Self.menuKeyEquivalent(for: kc) else {
            item.title = "\(baseTitle)  (\(binding.displayString))"
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        var mask: NSEvent.ModifierFlags = []
        if binding.modifiers.contains(.command) { mask.insert(.command) }
        if binding.modifiers.contains(.option)  { mask.insert(.option) }
        if binding.modifiers.contains(.control) { mask.insert(.control) }
        if binding.modifiers.contains(.shift)   { mask.insert(.shift) }
        item.title = baseTitle
        item.keyEquivalent = keyEq
        item.keyEquivalentModifierMask = mask
    }

    private static func menuKeyEquivalent(for keyCode: Int) -> String? {
        switch keyCode {
        case kVK_F1:  return String(UnicodeScalar(NSF1FunctionKey)!)
        case kVK_F2:  return String(UnicodeScalar(NSF2FunctionKey)!)
        case kVK_F3:  return String(UnicodeScalar(NSF3FunctionKey)!)
        case kVK_F4:  return String(UnicodeScalar(NSF4FunctionKey)!)
        case kVK_F5:  return String(UnicodeScalar(NSF5FunctionKey)!)
        case kVK_F6:  return String(UnicodeScalar(NSF6FunctionKey)!)
        case kVK_F7:  return String(UnicodeScalar(NSF7FunctionKey)!)
        case kVK_F8:  return String(UnicodeScalar(NSF8FunctionKey)!)
        case kVK_F9:  return String(UnicodeScalar(NSF9FunctionKey)!)
        case kVK_F10: return String(UnicodeScalar(NSF10FunctionKey)!)
        case kVK_F11: return String(UnicodeScalar(NSF11FunctionKey)!)
        case kVK_F12: return String(UnicodeScalar(NSF12FunctionKey)!)
        case kVK_Space:  return " "
        case kVK_Return: return "\r"
        case kVK_Escape: return "\u{1b}"
        case kVK_Tab:    return "\t"
        default:
            let label = KeyCodeLabels.name(for: keyCode)
            if label.count == 1 {
                return label.lowercased()
            }
            return nil
        }
    }

    private func populateStatusMenu(_ menu: NSMenu) {
        let l = config.language
        let capTitle = L10n.tr("截图", "Capture Area", in: l)
        let capItem = NSMenuItem(title: capTitle, action: #selector(menuCapture), keyEquivalent: "")
        applyMenuShortcut(config.hotkeys.screenshot, to: capItem, baseTitle: capTitle)
        capItem.image = menuIcon("viewfinder")
        capItem.target = self
        menu.addItem(capItem)

        let winTitle = L10n.tr("窗体截图", "Capture Window", in: l)
        let winCapItem = NSMenuItem(title: winTitle, action: #selector(menuDirectWindowCapture), keyEquivalent: "")
        applyMenuShortcut(config.hotkeys.windowCapture, to: winCapItem, baseTitle: winTitle)
        winCapItem.image = menuIcon("macwindow")
        winCapItem.target = self
        menu.addItem(winCapItem)

        let lsTitle = L10n.tr("页面长截图", "Scrolling Capture", in: l)
        let lsCapItem = NSMenuItem(title: lsTitle, action: #selector(menuDirectLongshotCapture), keyEquivalent: "")
        applyMenuShortcut(config.hotkeys.longshotCapture, to: lsCapItem, baseTitle: lsTitle)
        lsCapItem.image = menuIcon("arrow.up.and.down.text.horizontal")
        lsCapItem.target = self
        menu.addItem(lsCapItem)

        let ocrTitle = L10n.tr("截图识字", "Capture & OCR", in: l)
        let ocrCapItem = NSMenuItem(title: ocrTitle, action: #selector(menuDirectOCRCapture), keyEquivalent: "")
        applyMenuShortcut(config.hotkeys.ocrCapture, to: ocrCapItem, baseTitle: ocrTitle)
        ocrCapItem.image = menuIcon("text.viewfinder")
        ocrCapItem.target = self
        menu.addItem(ocrCapItem)

        let selTitle = L10n.tr("划词翻译", "Translate Selection", in: l)
        let selectionItem = NSMenuItem(title: selTitle, action: #selector(menuTranslateSelection), keyEquivalent: "")
        applyMenuShortcut(config.hotkeys.translateSelection, to: selectionItem, baseTitle: selTitle)
        selectionItem.image = menuIcon("character.bubble")
        selectionItem.target = self
        menu.addItem(selectionItem)

        let trCapTitle = L10n.tr("截图翻译", "Capture & Translate", in: l)
        let translateCaptureItem = NSMenuItem(title: trCapTitle, action: #selector(menuTranslateCapture), keyEquivalent: "")
        applyMenuShortcut(config.hotkeys.translateCapture, to: translateCaptureItem, baseTitle: trCapTitle)
        translateCaptureItem.image = menuIcon("character.viewfinder")
        translateCaptureItem.target = self
        menu.addItem(translateCaptureItem)

        let pinTitle = L10n.tr("剪贴板贴图", "Pin from Clipboard", in: l)
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(menuPinClipboard), keyEquivalent: "")
        applyMenuShortcut(config.hotkeys.pin, to: pinItem, baseTitle: pinTitle)
        pinItem.image = menuIcon("pin")
        pinItem.target = self
        menu.addItem(pinItem)

        menu.addItem(.separator())

        let ocrClipItem = NSMenuItem(title: L10n.tr("识别剪贴板文字", "OCR from Clipboard", in: l), action: #selector(menuOCRClipboard), keyEquivalent: "")
        ocrClipItem.image = menuIcon("doc.text.viewfinder")
        ocrClipItem.target = self
        menu.addItem(ocrClipItem)

        let ocrFileItem = NSMenuItem(title: L10n.tr("识别图片文字…", "OCR from Image File…", in: l), action: #selector(menuOCRFile), keyEquivalent: "")
        ocrFileItem.image = menuIcon("photo.badge.magnifyingglass")
        ocrFileItem.target = self
        menu.addItem(ocrFileItem)

        if pinManager.count > 0 {
            menu.addItem(.separator())
            if pinManager.hasClickThroughPins {
                let restoreItem = NSMenuItem(title: L10n.tr("取消贴图穿透", "Disable Click-Through", in: l), action: #selector(menuRestoreClickThrough), keyEquivalent: "")
                restoreItem.image = menuIcon("cursorarrow.click.2")
                restoreItem.target = self
                menu.addItem(restoreItem)
            }
            let closePins = NSMenuItem(title: L10n.tr("关闭全部贴图", "Close All Pins", in: l), action: #selector(menuCloseAllPins), keyEquivalent: "")
            closePins.image = menuIcon("xmark.circle")
            closePins.target = self
            menu.addItem(closePins)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: L10n.tr("设置…", "Settings…", in: l), action: #selector(menuSettings), keyEquivalent: ",")
        settingsItem.image = menuIcon("gearshape")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: L10n.tr("退出", "Quit iSnip", in: l), action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.image = menuIcon("power")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func menuCapture() {
        startScreenCaptureOverlay(mode: .normalCapture, fromMenu: true)
    }
    @objc private func menuDirectWindowCapture() {
        startScreenCaptureOverlay(mode: .directWindowCapture, fromMenu: true)
    }
    @objc private func menuDirectLongshotCapture() {
        startScreenCaptureOverlay(mode: .directLongshotCapture, fromMenu: true)
    }
    @objc private func menuDirectOCRCapture() {
        startScreenCaptureOverlay(mode: .directOCRCapture, fromMenu: true)
    }
    @objc private func menuTranslateSelection() {
        triggerSelectionTranslation(from: selectionSourceApplication)
    }
    @objc private func menuTranslateCapture() {
        triggerOCRTranslation(fromMenu: true)
    }
    @objc private func menuPinClipboard() { triggerGlobalPinFromClipboard() }
    @objc private func menuOCRClipboard() { triggerOCRFromClipboard() }
    @objc private func menuOCRFile() { triggerOCRFromFile() }
    @objc private func menuRestoreClickThrough() { pinManager.restoreAllClickThrough() }
    @objc private func menuCloseAllPins() { pinManager.closeAll() }
    @objc private func menuSettings() { openSettings() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    private func makeMenuBarTemplateIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.55)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            // Four precision optical viewfinder corner brackets (matching the iSnip 3D AppIcon)
            let minX: CGFloat = 2.5
            let maxX: CGFloat = 15.5
            let minY: CGFloat = 3.0
            let maxY: CGFloat = 15.0
            let arm: CGFloat = 3.6
            let r: CGFloat = 2.0

            // Top-left
            ctx.move(to: CGPoint(x: minX, y: maxY - arm))
            ctx.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX + arm, y: maxY), radius: r)
            ctx.addLine(to: CGPoint(x: minX + arm, y: maxY))
            // Top-right
            ctx.move(to: CGPoint(x: maxX - arm, y: maxY))
            ctx.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: maxX, y: maxY - arm), radius: r)
            ctx.addLine(to: CGPoint(x: maxX, y: maxY - arm))
            // Bottom-left
            ctx.move(to: CGPoint(x: minX, y: minY + arm))
            ctx.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX + arm, y: minY), radius: r)
            ctx.addLine(to: CGPoint(x: minX + arm, y: minY))
            // Bottom-right
            ctx.move(to: CGPoint(x: maxX - arm, y: minY))
            ctx.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: minY + arm), radius: r)
            ctx.addLine(to: CGPoint(x: maxX, y: minY + arm))
            ctx.strokePath()

            // Center optical aperture ring + subtle focus dot
            ctx.setLineWidth(1.35)
            ctx.strokeEllipse(in: CGRect(x: 6.3, y: 6.3, width: 5.4, height: 5.4))
            ctx.fillEllipse(in: CGRect(x: 8.2, y: 8.2, width: 1.6, height: 1.6))
            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: - Workflows

    public func openSettings() {
        settingsController?.show()
    }

    public func triggerCapture() {
        startScreenCaptureOverlay(mode: .normalCapture)
    }

    public func triggerDirectWindowCapture() {
        startScreenCaptureOverlay(mode: .directWindowCapture)
    }

    public func triggerDirectLongshotCapture() {
        startScreenCaptureOverlay(mode: .directLongshotCapture)
    }

    public func triggerDirectOCRCapture() {
        startScreenCaptureOverlay(mode: .directOCRCapture)
    }

    public func triggerSelectionTranslation(from application: NSRunningApplication? = nil) {
        guard translationAvailable(), activeCaptureSession == nil, activeLongshotSession == nil else { return }
        do {
            guard let app = application ?? NSWorkspace.shared.frontmostApplication else {
                throw SelectedTextService.SelectionError.noSelection
            }
            let text = try SelectedTextService.readSelection(processID: app.processIdentifier)
            ocrBubbleManager.presentSelectedText(text, anchorScreenPoint: NSEvent.mouseLocation, config: config)
        } catch SelectedTextService.SelectionError.permissionRequired {
            SelectedTextService.requestAccess()
            ToastHUD.show(L10n.tr("请开启 iSnip 的辅助功能权限", "Please grant Accessibility access to iSnip", in: config.language), symbol: "hand.raised", tint: .systemOrange, duration: 3)
        } catch {
            ToastHUD.show(L10n.tr("未读取到选中文字，可使用截图翻译", "No selected text found — try Capture & Translate", in: config.language), symbol: "text.viewfinder", tint: .systemOrange, duration: 3)
        }
    }

    public func triggerOCRTranslation(fromMenu: Bool = false) {
        guard translationAvailable() else { return }
        startScreenCaptureOverlay(mode: .directOCRCapture, fromMenu: fromMenu, translateOCR: true)
    }

    private func translationAvailable() -> Bool {
        if #available(macOS 15.0, *) { return true }
        ToastHUD.show(L10n.tr("系统翻译需要 macOS 15 或更新版本", "System Translation requires macOS 15 or later", in: config.language), symbol: "info.circle", tint: .systemOrange, duration: 3)
        return false
    }

    private func cleanupStaleCaptureSessionIfNeeded() {
        if let existing = activeCaptureSession, !existing.hasVisibleWindows {
            existing.cancelSession()
            activeCaptureSession = nil
        }
    }

    private func startScreenCaptureOverlay(mode: CaptureSessionCoordinator.SessionMode, fromMenu: Bool = false, translateOCR: Bool = false) {
        guard activeLongshotSession == nil, !isCapturingSnapshots else { return }

        if let existing = activeCaptureSession {
            if !existing.hasVisibleWindows || fromMenu {
                existing.cancelSession()
                activeCaptureSession = nil
            } else {
                existing.refocus()
                return
            }
        }

        isCapturingSnapshots = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isCapturingSnapshots = false }
            if fromMenu {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            do {
                let snapshots = try await ScreenCaptureService.captureAllDisplays()
                guard !snapshots.isEmpty else { return }
                let coordinator = self.makeSessionCoordinator(mode: mode, translateOCR: translateOCR)
                self.activeCaptureSession = coordinator
                coordinator.startWithSnapshots(snapshots)
            } catch {
                ScreenCaptureService.showPermissionGuidanceAlert(error: error)
            }
        }
    }

    public func triggerOCRFromClipboard() {
        guard let clip = OutputService.readImageFromClipboard() else {
            ToastHUD.show(L10n.tr("剪贴板无图片", "No image in clipboard", in: config.language))
            return
        }
        ocrBubbleManager.recognizeAndPresent(
            rawSelectionImage: clip.cgImage,
            anchorScreenPoint: nil,
            config: config
        )
    }

    public func triggerOCRFromFile() {
        guard let cg = OutputService.readImageFromFileDialog() else {
            return
        }
        ocrBubbleManager.recognizeAndPresent(
            rawSelectionImage: cg,
            anchorScreenPoint: nil,
            config: config
        )
    }

    public func triggerGlobalPinFromClipboard() {
        cleanupStaleCaptureSessionIfNeeded()
        guard activeCaptureSession == nil else { return }
        guard let clip = OutputService.readImageFromClipboard() else {
            // Silent ignore when clipboard contains text or no image (matches AirSnip ADR)
            return
        }
        let scale = Double(clip.cgImage.width) / max(1.0, Double(clip.pointSize.width))
        var pinCfg = config
        pinCfg.pinPosition = .center
        pinManager.createPin(
            cgImage: clip.cgImage,
            backingScale: max(1.0, scale),
            preferredScreenOriginAppKit: nil,
            config: pinCfg
        )
    }

    private func startPinInlineEditSession(pin: PinWindowController) {
        cleanupStaleCaptureSessionIfNeeded()
        guard activeCaptureSession == nil, activeLongshotSession == nil else { return }
        let coordinator = makeSessionCoordinator(mode: .inlinePinEdit(pin))
        activeCaptureSession = coordinator
        coordinator.startPinInlineEdit(pin: pin)
    }

    private func startStandaloneAnnotateSession(image: CGImage, scale: Double, screen: NSScreen) {
        cleanupStaleCaptureSessionIfNeeded()
        guard activeCaptureSession == nil else { return }
        let coordinator = makeSessionCoordinator(mode: .standaloneImageEdit(image, scale, screen))
        activeCaptureSession = coordinator
        coordinator.startStandaloneImageEdit(cgImage: image, backingScale: scale, screen: screen)
    }

    private func makeSessionCoordinator(mode: CaptureSessionCoordinator.SessionMode, translateOCR: Bool = false) -> CaptureSessionCoordinator {
        let coordinator = CaptureSessionCoordinator(config: config, mode: mode)

        coordinator.onConfigMutated = { [weak self] updated in
            self?.config = updated
        }
        coordinator.onCompleteCopy = { [weak self] cgImg, scale in
            let currentCfg = self?.config
            let showToast = currentCfg?.showCompletionToast ?? true
            OutputService.copyImageToClipboard(cgImg, backingScale: scale, config: currentCfg) { _ in
                guard showToast else { return }
                ToastHUD.show(L10n.tr("已复制", "Copied"))
            }
        }
        coordinator.onCompleteSave = { [weak self] cgImg, scale, forceDialog, cfg in
            let showToast = cfg.showCompletionToast
            let cfgSaveURL = self?.configURL ?? AirSnipConfig.defaultConfigFileURL()
            guard OutputService.saveImage(
                for: cgImg,
                backingScale: scale,
                config: &cfg,
                forceDialog: forceDialog,
                configSaveURL: cfgSaveURL
            ) != nil else {
                return false
            }
            self?.config = cfg
            if showToast {
                ToastHUD.show(L10n.tr("已保存", "Saved"))
            }
            return true
        }
        coordinator.onCompletePin = { [weak self] cgImg, scale, origin in
            guard let self else { return }
            self.pinManager.createPin(
                cgImage: cgImg,
                backingScale: scale,
                preferredScreenOriginAppKit: origin,
                config: self.config
            )
        }
        coordinator.onStartOCR = { [weak self] rawImg, anchor in
            guard let self else { return }
            self.ocrBubbleManager.recognizeAndPresent(
                rawSelectionImage: rawImg,
                anchorScreenPoint: anchor,
                config: self.config,
                translateOnCompletion: translateOCR
            )
        }
        coordinator.onStartLongshot = { [weak self] screen, vpRect, initBuf, forceAutoScroll in
            guard let self else { return }
            self.beginLongshotSession(
                screen: screen,
                viewportTopDown: vpRect,
                initialCrop: initBuf,
                forceAutoScroll: forceAutoScroll
            )
        }
        coordinator.onSessionEnded = { [weak self] in
            self?.activeCaptureSession = nil
        }
        return coordinator
    }

    private func beginLongshotSession(
        screen: NSScreen,
        viewportTopDown: ASRect,
        initialCrop: PixelBufferRGBA,
        forceAutoScroll: Bool
    ) {
        let ls = LongshotSessionController(
            screen: screen,
            viewportTopDown: viewportTopDown,
            initialCrop: initialCrop,
            config: config,
            autoStartScroll: forceAutoScroll || config.longshotAutoScroll
        )
        ls.onSpeedChanged = { [weak self] newSpeed in
            self?.updateConfig { $0.longshotScrollSpeed = newSpeed }
        }
        ls.onFinishCopy = { [weak self] cgImg, scale in
            let currentCfg = self?.config
            let showToast = currentCfg?.showCompletionToast ?? true
            self?.activeLongshotSession = nil
            OutputService.copyImageToClipboard(cgImg, backingScale: scale, config: currentCfg) { _ in
                guard showToast else { return }
                ToastHUD.show(L10n.tr("已复制", "Copied"))
            }
        }
        ls.onFinishSave = { [weak self] cgImg, scale, forceDialog in
            guard let self else { return }
            self.activeLongshotSession = nil
            OutputService.copyImageToClipboard(cgImg, backingScale: scale, config: self.config)
            var cfg = self.config
            let showToast = cfg.showCompletionToast
            if OutputService.saveImage(
                for: cgImg,
                backingScale: scale,
                config: &cfg,
                forceDialog: forceDialog,
                configSaveURL: self.configURL
            ) != nil {
                self.config = cfg
                if showToast {
                    ToastHUD.show(L10n.tr("已保存", "Saved"))
                }
            }
        }
        ls.onFinishEdit = { [weak self] cgImg, scale, scr in
            self?.activeLongshotSession = nil
            self?.startStandaloneAnnotateSession(image: cgImg, scale: scale, screen: scr)
        }
        ls.onFinishOCR = { [weak self] cgImg in
            guard let self else { return }
            self.activeLongshotSession = nil
            self.ocrBubbleManager.recognizeAndPresent(
                rawSelectionImage: cgImg,
                anchorScreenPoint: nil,
                config: self.config
            )
        }
        ls.onCancel = { [weak self] in
            self?.activeLongshotSession = nil
        }
        activeLongshotSession = ls
        ls.start()
    }
}

public final class AirSnipAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AirSnipAppController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let ctrl = AirSnipAppController()
        self.controller = ctrl
        ctrl.bootstrap()

        if CommandLine.arguments.contains("--open-settings") {
            ctrl.openSettings()
        }
        if CommandLine.arguments.contains("--request-screen-capture") {
            _ = ScreenCaptureService.requestScreenCapturePermissionIfNeeded()
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.openSettings()
        return true
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
public enum AirSnipMain {
    public static func main() {
        if CommandLine.arguments.contains("--window-capture-self-test") {
            let ok = MainActor.assumeIsolated { SmokeTestRunner.runWindowCaptureChecks() }
            exit(ok ? 0 : 1)
        }
        if CommandLine.arguments.contains("--translation-self-test") {
            let ok = MainActor.assumeIsolated { SmokeTestRunner.runTranslationChecks() }
            exit(ok ? 0 : 1)
        }
        if CommandLine.arguments.contains("--smoke-test") {
            let ok = SmokeTestRunner.run()
            exit(ok ? 0 : 1)
        }

        AirSnipAppController.notifyExistingInstanceAndExitIfDuplicate()

        let app = NSApplication.shared
        let delegate = AirSnipAppDelegate()
        app.delegate = delegate
        app.run()
    }
}
