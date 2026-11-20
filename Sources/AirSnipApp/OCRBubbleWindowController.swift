import AppKit
import SwiftUI
import NaturalLanguage
import Translation
import AirSnipCore

struct TextTranslationRequest: Equatable {
    let id = UUID()
    let text: String
    let sourceLanguage: String
    let targetLanguage: String

    init(text: String, sourceLanguage: String, targetLanguage: String) {
        self.text = text
        self.targetLanguage = targetLanguage
        if sourceLanguage == "auto" {
            let prose = text.replacingOccurrences(
                of: #"https?://[^\s<>()\[\]，。；！？、]+|(?:[A-Za-z0-9_.~:+-]*[/\\])+[A-Za-z0-9_.~:@%+?=&#!-]*"#,
                with: " ", options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            self.sourceLanguage = NLLanguageRecognizer.dominantLanguage(for: prose)?.rawValue ?? "auto"
        } else {
            self.sourceLanguage = sourceLanguage
        }
    }
}

private final class KeyableBubblePanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

@MainActor
public final class OCRBubbleManager: ObservableObject {
    @Published public var text: String = "" {
        didSet {
            if oldValue != text {
                copiedFeedback = false
                clearTranslation()
            }
        }
    }
    @Published public var barcodes: [String] = []
    @Published public var isRecognizing: Bool = false
    @Published public var errorMessage: String?
    @Published public var sourceImage: CGImage?
    @Published public var isPinnedOnTop: Bool = true {
        didSet {
            panel?.level = isPinnedOnTop ? .floating : .normal
        }
    }
    @Published public var autoCopy: Bool = false {
        didSet {
            guard !suppressCallback else { return }
            onConfigChanged?(selectedLanguage, autoCopy, mergeLineBreaks)
        }
    }
    @Published public var mergeLineBreaks: Bool = false {
        didSet {
            guard !suppressCallback else { return }
            applyLineBreakModeAfterToggle()
            onConfigChanged?(selectedLanguage, autoCopy, mergeLineBreaks)
        }
    }
    @Published public var selectedLanguage: String = "auto" {
        didSet {
            guard !suppressCallback, oldValue != selectedLanguage else { return }
            onConfigChanged?(selectedLanguage, autoCopy, mergeLineBreaks)
            rerunRecognitionIfPossible()
        }
    }
    @Published public var appLanguage: AppLanguage = .system
    @Published public var copiedFeedback: Bool = false
    @Published public private(set) var copiedTranslationFeedback = false
    @Published private(set) var translationRequest: TextTranslationRequest?
    @Published public private(set) var isTranslationVisible = false
    @Published public private(set) var isTranslating = false
    @Published public private(set) var translatedText = ""
    @Published public private(set) var translationError: String?
    @Published public var translationSourceLanguage = "auto" {
        didSet {
            if !suppressCallback, oldValue != translationSourceLanguage, isTranslationVisible { requestTranslation() }
        }
    }
    @Published public var translationTargetLanguage = "zh-Hans" {
        didSet {
            guard !suppressCallback, oldValue != translationTargetLanguage else { return }
            onTranslationTargetChanged?(translationTargetLanguage)
            if isTranslationVisible { requestTranslation() }
        }
    }

    private var rawRecognizedText: String = ""
    private var paragraphRecognizedText: String = ""
    private var detectBarcodesEnabled: Bool = true
    private var suppressCallback: Bool = false
    private var translateAfterRecognition = false

    private var panel: KeyableBubblePanel?
    private var recognitionTask: Task<Void, Never>?
    private var copyFeedbackTask: Task<Void, Never>?
    public var onConfigChanged: ((_ language: String, _ autoCopy: Bool, _ mergeLineBreaks: Bool) -> Void)?
    public var onTranslationTargetChanged: ((String) -> Void)?

    public init() {}

    public func recognizeAndPresent(
        rawSelectionImage: CGImage,
        anchorScreenPoint: NSPoint?,
        config: AirSnipConfig,
        translateOnCompletion: Bool = false
    ) {
        recognitionTask?.cancel()
        suppressCallback = true
        self.appLanguage = config.language
        self.autoCopy = config.ocr.autoCopy
        self.mergeLineBreaks = config.ocr.mergeLineBreaks
        self.selectedLanguage = config.ocr.language
        self.detectBarcodesEnabled = config.ocr.detectBarcodes
        self.translationTargetLanguage = config.translation.targetLanguage
        self.translationSourceLanguage = "auto"
        suppressCallback = false
        self.translateAfterRecognition = translateOnCompletion
        self.isTranslationVisible = translateOnCompletion
        clearTranslation()

        self.sourceImage = rawSelectionImage
        self.text = ""
        self.copiedFeedback = false
        self.copiedTranslationFeedback = false
        ensurePanel(near: anchorScreenPoint, theme: config.theme)
        startRecognition(on: rawSelectionImage)
    }

    public func presentSelectedText(_ selectedText: String, anchorScreenPoint: NSPoint?, config: AirSnipConfig) {
        recognitionTask?.cancel()
        suppressCallback = true
        appLanguage = config.language
        translationTargetLanguage = config.translation.targetLanguage
        translationSourceLanguage = "auto"
        suppressCallback = false
        sourceImage = nil
        isRecognizing = false
        errorMessage = nil
        barcodes = []
        copiedFeedback = false
        copiedTranslationFeedback = false
        text = selectedText
        isTranslationVisible = true
        ensurePanel(near: anchorScreenPoint, theme: config.theme)
        requestTranslation()
    }

    public func rerunRecognitionIfPossible() {
        guard let img = sourceImage else { return }
        recognitionTask?.cancel()
        startRecognition(on: img)
    }

    private func startRecognition(on image: CGImage) {
        self.isRecognizing = true
        self.errorMessage = nil
        self.text = ""
        self.barcodes = []
        self.rawRecognizedText = ""
        self.paragraphRecognizedText = ""

        let lang = selectedLanguage
        let wantBarcodes = detectBarcodesEnabled

        recognitionTask = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try LocalVisionOCR.recognizeDetailed(
                        cgImage: image,
                        languagePreference: lang,
                        detectBarcodes: wantBarcodes
                    )
                }.value
                guard !Task.isCancelled, let self else { return }
                self.isRecognizing = false
                self.barcodes = result.barcodes
                self.rawRecognizedText = result.rawText
                self.paragraphRecognizedText = result.paragraphText

                if result.isEmpty {
                    self.errorMessage = L10n.tr("未识别到文字", "No text detected", in: self.appLanguage)
                } else {
                    let chosen: String
                    if result.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        chosen = result.barcodes.joined(separator: "\n")
                        self.rawRecognizedText = chosen
                        self.paragraphRecognizedText = chosen
                    } else {
                        chosen = self.mergeLineBreaks ? result.paragraphText : result.rawText
                    }
                    self.text = chosen
                    if self.autoCopy {
                        OutputService.copyStringToClipboard(chosen)
                        self.triggerCopiedFeedback()
                    }
                    if self.translateAfterRecognition { self.requestTranslation() }
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.isRecognizing = false
                self.errorMessage = L10n.tr("识别失败：\(error.localizedDescription)", "OCR failed: \(error.localizedDescription)", in: self.appLanguage)
            }
        }
    }

    private func applyLineBreakModeAfterToggle() {
        guard !rawRecognizedText.isEmpty else { return }
        if mergeLineBreaks {
            if text == rawRecognizedText {
                text = paragraphRecognizedText
            } else {
                text = OCRLinesJoiner.mergeWrappedParagraphs(text)
            }
        } else {
            if text == paragraphRecognizedText {
                text = rawRecognizedText
            }
        }
    }

    public func copyCurrentText() {
        guard !text.isEmpty else { return }
        OutputService.copyStringToClipboard(text)
        triggerCopiedFeedback()
    }

    public func copyBarcode(_ payload: String) {
        OutputService.copyStringToClipboard(payload)
        ToastHUD.show(L10n.tr("已复制", "Copied", in: appLanguage))
    }

    private func clearTranslation() {
        translationRequest = nil
        translatedText = ""
        copiedTranslationFeedback = false
        translationError = nil
        isTranslating = false
    }

    public func requestTranslation() {
        let wasVisible = isTranslationVisible
        clearTranslation()
        isTranslationVisible = true
        if sourceImage != nil { translateAfterRecognition = true }
        panel?.minSize = NSSize(width: 400, height: 350)
        if !wasVisible, let panel {
            var frame = panel.frame
            let bounds = (panel.screen ?? NSScreen.main)?.visibleFrame ?? frame
            frame.size.width = max(400, frame.width)
            frame.size.height = min(max(frame.height, preferredPanelHeight), bounds.height - 24)
            frame.origin.x = max(bounds.minX + 12, min(frame.origin.x, bounds.maxX - frame.width - 12))
            frame.origin.y = max(bounds.minY + 12, min(panel.frame.maxY - frame.height, bounds.maxY - frame.height - 12))
            panel.setFrame(frame, display: true)
        }
        guard #available(macOS 15.0, *) else {
            translationError = L10n.tr("系统翻译需要 macOS 15 或更新版本。", "System Translation requires macOS 15 or later.", in: appLanguage)
            return
        }
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isRecognizing else { return }
        isTranslating = true
        translationRequest = TextTranslationRequest(
            text: input,
            sourceLanguage: translationSourceLanguage,
            targetLanguage: translationTargetLanguage
        )
    }

    @available(macOS 15.0, *)
    func translate(_ request: TextTranslationRequest, using session: TranslationSession) async {
        guard !Task.isCancelled, translationRequest?.id == request.id else { return }
        do {
            if request.sourceLanguage != "auto",
               Locale.Language(identifier: request.sourceLanguage).languageCode == Locale.Language(identifier: request.targetLanguage).languageCode {
                translatedText = request.text
                isTranslating = false
                return
            }
            let response = try await session.translate(request.text)
            guard !Task.isCancelled, translationRequest?.id == request.id else { return }
            translatedText = response.targetText
            isTranslating = false
        } catch {
            guard !Task.isCancelled, translationRequest?.id == request.id else { return }
            isTranslating = false
            switch error {
            case TranslationError.unableToIdentifyLanguage:
                translationError = L10n.tr(
                    "无法判断原文语言，请手动选择后重试。",
                    "Could not detect source language. Please select it manually and try again.",
                    in: appLanguage
                )
            case TranslationError.unsupportedLanguagePairing, TranslationError.unsupportedSourceLanguage, TranslationError.unsupportedTargetLanguage:
                translationError = L10n.tr(
                    "系统不支持这组语言，请更换原文语言或目标语言。",
                    "This language pair is not supported by macOS Translation.",
                    in: appLanguage
                )
            default:
                translationError = L10n.tr(
                    "翻译失败：\(error.localizedDescription)\n请检查网络或语言包后重试。",
                    "Translation failed: \(error.localizedDescription)\nPlease check your network or installed language packs.",
                    in: appLanguage
                )
            }
        }
    }

    public func copyTranslation() {
        guard !translatedText.isEmpty else { return }
        OutputService.copyStringToClipboard(translatedText)
        triggerCopiedFeedback(translation: true)
    }

    private func triggerCopiedFeedback(translation: Bool = false) {
        copyFeedbackTask?.cancel()
        copiedFeedback = !translation
        copiedTranslationFeedback = translation
        copyFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.copiedFeedback = false
            self?.copiedTranslationFeedback = false
        }
    }

    public func dismiss() {
        recognitionTask?.cancel()
        copyFeedbackTask?.cancel()
        copiedFeedback = false
        copiedTranslationFeedback = false
        clearTranslation()
        panel?.orderOut(nil)
    }

    var preferredPanelHeight: CGFloat {
        guard isTranslationVisible else { return 350 }
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: 392, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 15)]
        ).height
        return min(560, max(370, measured * 2 + 282))
    }

    // ponytail: 在鼠标旁放置并限制到可见屏幕；不引入独立的窗口布局系统。
    static func panelFrame(size: NSSize, near anchor: NSPoint?, visibleFrame: NSRect) -> NSRect {
        let bounds = visibleFrame.insetBy(dx: 12, dy: 12)
        let size = NSSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
        var origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        if let anchor {
            origin.x = anchor.x + 16
            if origin.x + size.width > bounds.maxX { origin.x = anchor.x - size.width - 16 }
            origin.y = anchor.y - size.height - 16
            if origin.y < bounds.minY { origin.y = anchor.y + 16 }
        }
        origin.x = max(bounds.minX, min(origin.x, bounds.maxX - size.width))
        origin.y = max(bounds.minY, min(origin.y, bounds.maxY - size.height))
        return NSRect(origin: origin, size: size)
    }

    private func ensurePanel(near anchor: NSPoint?, theme: ThemeSetting) {
        let screen = anchor.flatMap { point in NSScreen.screens.first { $0.frame.contains(point) } }
            ?? NSScreen.main ?? NSScreen.screens.first
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = Self.panelFrame(
            size: NSSize(width: isTranslationVisible ? 440 : 480, height: preferredPanelHeight),
            near: anchor, visibleFrame: vis
        )

        if let existing = panel {
            existing.minSize = NSSize(width: isTranslationVisible ? 400 : 380, height: isTranslationVisible ? 350 : 250)
            applyTheme(theme, to: existing)
            existing.setFrame(frame, display: true)
            NSApp.activate(ignoringOtherApps: true)
            existing.orderFrontRegardless()
            existing.makeKeyAndOrderFront(nil)
            if isTranslationVisible { existing.makeFirstResponder(nil) }
            return
        }

        let newPanel = KeyableBubblePanel(
            contentRect: frame,
            styleMask: [.titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        newPanel.hidesOnDeactivate = false
        newPanel.isFloatingPanel = isPinnedOnTop
        newPanel.titleVisibility = .hidden
        newPanel.titlebarAppearsTransparent = true
        newPanel.standardWindowButton(.closeButton)?.isHidden = true
        newPanel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        newPanel.standardWindowButton(.zoomButton)?.isHidden = true
        newPanel.isMovableByWindowBackground = true
        newPanel.level = isPinnedOnTop ? .floating : .normal
        newPanel.minSize = NSSize(width: isTranslationVisible ? 400 : 380, height: isTranslationVisible ? 350 : 250)
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.onEscape = { [weak self] in self?.dismiss() }
        applyTheme(theme, to: newPanel)

        newPanel.contentView = NSHostingView(rootView: OCRBubbleCardView(manager: self))
        newPanel.setFrame(frame, display: false)
        self.panel = newPanel

        NSApp.activate(ignoringOtherApps: true)
        newPanel.orderFrontRegardless()
        newPanel.makeKeyAndOrderFront(nil)
        if isTranslationVisible { newPanel.makeFirstResponder(nil) }
    }

    private func applyTheme(_ theme: ThemeSetting, to win: NSWindow) {
        switch theme {
        case .follow:
            win.appearance = nil
            win.backgroundColor = .windowBackgroundColor
        case .light:
            win.appearance = NSAppearance(named: .aqua)
            win.backgroundColor = NSColor(srgbRed: 0.969, green: 0.969, blue: 0.973, alpha: 1.0)
        case .dark:
            win.appearance = NSAppearance(named: .darkAqua)
            win.backgroundColor = NSColor(srgbRed: 0.075, green: 0.075, blue: 0.086, alpha: 1.0)
        }
    }
}

private struct OCRBubbleCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var manager: OCRBubbleManager
    @FocusState private var editorFocused: Bool
    @State private var hoverPin = false
    @State private var hoverClose = false

    private func webURL(from payload: String) -> URL? {
        guard let url = URL(string: payload),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        let lang = manager.appLanguage
        let headerTitle: String = {
            if manager.sourceImage == nil {
                return L10n.tr("划词翻译", "Selection Translate", in: lang)
            }
            if manager.isTranslationVisible {
                return L10n.tr("截图翻译", "Capture & Translate", in: lang)
            }
            return L10n.tr("文字识别", "Text Recognition", in: lang)
        }()

        VStack(spacing: 10) {
            // Top Header Bar
            HStack(spacing: 8) {
                Image(systemName: manager.sourceImage == nil ? "character.bubble" : "text.viewfinder")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(p.inkPrimary)

                Text(headerTitle)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(p.inkPrimary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 4)

                if manager.sourceImage != nil {
                    MagpieMenuPicker(
                        L10n.tr("识别语言", "Recognition Language", in: lang),
                        options: OcrConfig.compactOptions(in: lang).map { ($0.tag, $0.shortLabel) },
                        selection: $manager.selectedLanguage,
                        minWidth: 78,
                        compact: true
                    )
                    .help(L10n.tr("识别语言", "Recognition Language", in: lang))
                }

                let pinLabel = manager.isPinnedOnTop
                    ? L10n.tr("取消置顶", "Unpin", in: lang)
                    : L10n.tr("置顶", "Pin on Top", in: lang)
                Button {
                    manager.isPinnedOnTop.toggle()
                } label: {
                    Image(systemName: manager.isPinnedOnTop ? "pin.fill" : "pin.slash")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(manager.isPinnedOnTop || hoverPin ? p.inkPrimary : p.inkSecondary)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                .fill(manager.isPinnedOnTop ? p.navActivePill : (hoverPin ? p.navHoverPill : Color.clear))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoverPin = $0 }
                .help(pinLabel)
                .accessibilityLabel(pinLabel)

                Button {
                    manager.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(hoverClose ? p.inkPrimary : p.inkSecondary)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                .fill(hoverClose ? p.navHoverPill : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoverClose = $0 }
                .help(L10n.tr("关闭 (Esc)", "Close (Esc)", in: lang))
                .accessibilityLabel(L10n.tr("关闭", "Close", in: lang))
            }

            // Detected QR / Barcodes Card
            if !manager.barcodes.isEmpty {
                MagpieCard(cornerRadius: 9) {
                    ForEach(Array(manager.barcodes.enumerated()), id: \.offset) { idx, code in
                        if idx > 0 {
                            MagpieRowDivider()
                        }
                        HStack(spacing: 8) {
                            Image(systemName: "qrcode")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(p.inkPrimary)
                            Text(code)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(p.inkMono)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            MagpieCopyButton(value: code)
                            if let url = webURL(from: code) {
                                MagpieTextAction(L10n.tr("打开", "Open", in: lang)) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
            }

            if manager.isTranslationVisible {
                languageBar(palette: p, lang: lang)
            }

            // Main Unified Card (Source + Optional Divided Translation)
            MagpieCard(cornerRadius: 10) {
                if manager.isTranslationVisible {
                    HStack(spacing: 8) {
                        Text(L10n.tr("原文", "Source", in: lang))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(p.inkSecondary)
                        Spacer()
                        if manager.sourceImage != nil {
                            MagpieSegmentedPicker(
                                options: [
                                    (false, L10n.tr("逐行", "Lines", in: lang)),
                                    (true, L10n.tr("合并换行", "Merge", in: lang))
                                ],
                                selection: $manager.mergeLineBreaks,
                                compact: true
                            )
                        }
                        MagpieTextAction(
                            manager.copiedFeedback
                                ? L10n.tr("已复制", "Copied", in: lang)
                                : L10n.tr("复制原文", "Copy Source", in: lang)
                        ) {
                            manager.copyCurrentText()
                        }
                        .disabled(manager.text.isEmpty || manager.isRecognizing)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                }

                sourceEditorArea(palette: p, lang: lang)
                    .frame(
                        minHeight: manager.isTranslationVisible ? 52 : 84,
                        maxHeight: manager.isTranslationVisible ? 114 : .infinity
                    )

                if manager.isTranslationVisible {
                    MagpieRowDivider()
                    translationSection(palette: p, lang: lang)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(editorFocused && !manager.isTranslationVisible ? p.focusBorder : Color.clear, lineWidth: 1)
                    .allowsHitTesting(false)
            )

            // Footer Action Bar
            let copyDisabled = manager.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manager.isRecognizing
            HStack(spacing: 8) {
                Button {
                    if manager.isTranslationVisible {
                        manager.copyTranslation()
                    } else {
                        manager.copyCurrentText()
                    }
                } label: {
                    let copied = manager.isTranslationVisible ? manager.copiedTranslationFeedback : manager.copiedFeedback
                    let labelStr: String = {
                        if copied { return L10n.tr("已复制", "Copied", in: lang) }
                        return manager.isTranslationVisible
                            ? L10n.tr("复制译文", "Copy Translation", in: lang)
                            : L10n.tr("复制原文", "Copy Text", in: lang)
                    }()
                    HStack(spacing: 5) {
                        Image(systemName: copied ? "checkmark" : "square.on.square")
                            .font(.system(size: 11, weight: .semibold))
                        Text(labelStr)
                    }
                }
                .buttonStyle(MagpiePillButtonStyle(role: .primary))
                .fixedSize(horizontal: true, vertical: false)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(manager.isTranslationVisible ? (manager.translatedText.isEmpty || manager.isTranslating) : copyDisabled)
                .help(
                    manager.isTranslationVisible
                        ? L10n.tr("复制完整译文 (⇧⌘C)", "Copy Translation (⇧⌘C)", in: lang)
                        : L10n.tr("复制全部原文 (⇧⌘C)", "Copy All Text (⇧⌘C)", in: lang)
                )

                Spacer(minLength: 4)

                if manager.sourceImage != nil && !manager.isTranslationVisible {
                    MagpieSegmentedPicker(
                        options: [
                            (false, L10n.tr("逐行", "Lines", in: lang)),
                            (true, L10n.tr("合并换行", "Merge", in: lang))
                        ],
                        selection: $manager.mergeLineBreaks,
                        compact: true
                    )
                }

                Button(
                    manager.translatedText.isEmpty
                        ? L10n.tr("翻译", "Translate", in: lang)
                        : L10n.tr("重新翻译", "Retranslate", in: lang)
                ) {
                    editorFocused = false
                    manager.requestTranslation()
                }
                .buttonStyle(MagpiePillButtonStyle(role: .bordered))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(copyDisabled || manager.isTranslating)
                .help(L10n.tr("翻译原文 (⌘Enter)", "Translate (⌘Enter)", in: lang))
            }
        }
        .environment(\.appLanguage, lang)
        .padding(14)
        .background(p.canvasBg)
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: manager.isTranslationVisible) { _, visible in
            if visible { editorFocused = false }
        }
    }

    @ViewBuilder
    private func sourceEditorArea(palette p: MagpiePalette, lang: AppLanguage) -> some View {
        ZStack {
            if manager.isRecognizing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.tr("识别中…", "Recognizing…", in: lang))
                        .font(.system(size: 12.5))
                        .foregroundStyle(p.inkSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = manager.errorMessage {
                ScrollView {
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 15))
                            .foregroundStyle(p.inkSecondary)
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundStyle(p.inkPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        MagpieTextAction(L10n.tr("重试", "Retry", in: lang), prominent: true) {
                            manager.rerunRecognitionIfPossible()
                        }
                    }
                    .padding(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let needsScroller = manager.text.count > 100 || manager.text.filter({ $0 == "\n" }).count >= 3
                TextEditor(text: $manager.text)
                    .font(.system(size: 14))
                    .foregroundStyle(p.inkPrimary)
                    .accessibilityLabel(L10n.tr("原文", "Source", in: lang))
                    .focused($editorFocused)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(needsScroller ? .automatic : .never)
                    .help(L10n.tr("可以编辑原文，按 ⌘Enter 重新翻译", "Edit source text and press ⌘Enter to retranslate", in: lang))
                    .padding(.horizontal, 8)
                    .padding(.vertical, manager.isTranslationVisible ? 4 : 8)
                    .onAppear {
                        editorFocused = !manager.isTranslationVisible
                    }
            }
        }
    }

    private func languageBar(palette p: MagpiePalette, lang: AppLanguage) -> some View {
        HStack(spacing: 8) {
            MagpieMenuPicker(
                L10n.tr("原文语言", "Source Language", in: lang),
                options: [("auto", L10n.tr("自动检测", "Auto Detect", in: lang))] + TranslationConfig.languageOptions.map { ($0.tag, $0.label) },
                selection: $manager.translationSourceLanguage,
                minWidth: 112,
                compact: true
            )
            .help(L10n.tr("原文语言", "Source Language", in: lang))

            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(p.inkTertiary)
                .accessibilityHidden(true)

            MagpieMenuPicker(
                L10n.tr("目标语言", "Target Language", in: lang),
                options: TranslationConfig.languageOptions.map { ($0.tag, $0.label) },
                selection: $manager.translationTargetLanguage,
                minWidth: 112,
                compact: true
            )
            .help(L10n.tr("目标语言", "Target Language", in: lang))

            Spacer(minLength: 0)
        }
    }

    private func translationSection(palette p: MagpiePalette, lang: AppLanguage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L10n.tr("译文", "Translation", in: lang))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(p.inkSecondary)
                Spacer()
                if manager.isTranslating {
                    ProgressView().controlSize(.mini)
                    Text(L10n.tr("翻译中…", "Translating…", in: lang))
                        .font(.system(size: 11.5))
                        .foregroundStyle(p.inkSecondary)
                }
            }

            ZStack(alignment: .topLeading) {
                ScrollView {
                    if let error = manager.translationError {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(p.statusWarn)
                                Text(L10n.tr("暂时无法翻译", "Unable to Translate", in: lang))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(p.inkPrimary)
                            }
                            Text(error)
                                .font(.system(size: 12.5))
                                .foregroundStyle(p.inkSecondary)
                                .textSelection(.enabled)
                            MagpieTextAction(L10n.tr("重试", "Retry", in: lang), prominent: true) {
                                manager.requestTranslation()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if !manager.translatedText.isEmpty {
                        Text(manager.translatedText)
                            .font(.system(size: 15.5))
                            .foregroundStyle(p.inkPrimary)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(translationHint(in: lang))
                            .font(.system(size: 12.5))
                            .foregroundStyle(p.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .scrollIndicators(.automatic)

                if #available(macOS 15.0, *), let request = manager.translationRequest {
                    AppleTranslationTaskView(manager: manager, request: request).id(request.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 54)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .layoutPriority(1)
    }

    private func translationHint(in lang: AppLanguage) -> String {
        if manager.isTranslating {
            return L10n.tr("首次使用可能需要按系统提示下载语言包。", "First-time translation may prompt to download a language pack.", in: lang)
        }
        if manager.isRecognizing {
            return L10n.tr("识别完成后自动翻译", "Will translate automatically once OCR completes", in: lang)
        }
        if manager.errorMessage != nil {
            return L10n.tr("请先重试文字识别，再翻译。", "Retry text recognition first, then translate.", in: lang)
        }
        if manager.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.tr("输入或粘贴原文后，点击「翻译」。", "Enter or paste source text, then click Translate.", in: lang)
        }
        return L10n.tr("原文已修改，点击「翻译」或按 ⌘Enter 更新译文。", "Source modified — click Retranslate or press ⌘Enter.", in: lang)
    }
}

@available(macOS 15.0, *)
private struct AppleTranslationTaskView: View {
    let manager: OCRBubbleManager
    let request: TextTranslationRequest

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .translationTask(
                source: request.sourceLanguage == "auto" ? nil : Locale.Language(identifier: request.sourceLanguage),
                target: Locale.Language(identifier: request.targetLanguage)
            ) { session in
                await manager.translate(request, using: session)
            }
    }
}
