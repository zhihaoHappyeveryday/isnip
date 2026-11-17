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
                    self.errorMessage = "未识别到文字"
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
                self.errorMessage = "识别失败：\(error.localizedDescription)"
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
        ToastHUD.show("已复制")
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
            translationError = "系统翻译需要 macOS 15 或更新版本。"
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
            let source = request.sourceLanguage == "auto"
                ? NLLanguageRecognizer.dominantLanguage(for: request.text)?.rawValue
                : request.sourceLanguage
            if let source, Locale.Language(identifier: source).languageCode == Locale.Language(identifier: request.targetLanguage).languageCode {
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
                translationError = "无法判断原文语言，请手动选择后重试。"
            case TranslationError.unsupportedLanguagePairing, TranslationError.unsupportedSourceLanguage, TranslationError.unsupportedTargetLanguage:
                translationError = "系统不支持这组语言，请更换原文语言或目标语言。"
            default:
                translationError = "翻译失败：\(error.localizedDescription)\n请检查网络或语言包后重试。"
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
        case .follow: win.appearance = nil
        case .light: win.appearance = NSAppearance(named: .aqua)
        case .dark: win.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

private struct OCRBubbleCardView: View {
    @ObservedObject var manager: OCRBubbleManager
    @FocusState private var editorFocused: Bool

    private func webURL(from payload: String) -> URL? {
        guard let url = URL(string: payload),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    var body: some View {
        VStack(spacing: 12) {
            // Top bar
            HStack(spacing: 8) {
                Image(systemName: manager.sourceImage == nil ? "character.bubble" : "text.viewfinder")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(manager.sourceImage == nil ? "划词翻译" : (manager.isTranslationVisible ? "截图翻译" : "文字识别"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 4)

                if manager.sourceImage != nil {
                    Picker("识别语言", selection: $manager.selectedLanguage) {
                        ForEach(OcrConfig.compactOptions, id: \.tag) { opt in
                            Text(opt.shortLabel).tag(opt.tag)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 88)
                    .help("识别语言")
                }

                Button {
                    manager.isPinnedOnTop.toggle()
                } label: {
                    Image(systemName: manager.isPinnedOnTop ? "pin.fill" : "pin.slash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(manager.isPinnedOnTop ? Color.accentColor : Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(manager.isPinnedOnTop ? Color.accentColor.opacity(0.14) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help(manager.isPinnedOnTop ? "取消置顶" : "置顶")
                .accessibilityLabel(manager.isPinnedOnTop ? "取消置顶" : "置顶")

                Button {
                    manager.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("关闭 (Esc)")
                .accessibilityLabel("关闭")
            }

            // Detected QR / Barcodes banner (if any)
            if !manager.barcodes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(manager.barcodes, id: \.self) { code in
                        HStack(spacing: 6) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                            Text(code)
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            if let url = webURL(from: code) {
                                Button("打开") {
                                    NSWorkspace.shared.open(url)
                                }
                                .controlSize(.mini)
                            }
                            Button("复制") {
                                manager.copyBarcode(code)
                            }
                            .controlSize(.mini)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.10)))
                    }
                }
            }

            if manager.isTranslationVisible {
                languageBar
                HStack(spacing: 8) {
                    Text("原文")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if manager.sourceImage != nil {
                        Toggle("合并换行", isOn: $manager.mergeLineBreaks)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                    }
                    Button(manager.copiedFeedback ? "已复制" : "复制原文") {
                        manager.copyCurrentText()
                    }
                    .controlSize(.small)
                    .disabled(manager.text.isEmpty || manager.isRecognizing)
                }
            }

            // Editable native text area
            ZStack {
                if manager.isRecognizing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("识别中…")
                            .font(.system(size: 12))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = manager.errorMessage {
                    ScrollView {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 18))
                            Text(err)
                                .font(.system(size: 13))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("重试") {
                                manager.rerunRecognitionIfPossible()
                            }
                            .controlSize(.small)
                        }
                        .padding(10)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TextEditor(text: $manager.text)
                        .font(.system(size: 14))
                        .accessibilityLabel("原文")
                        .focused($editorFocused)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.visible)
                        .help("可以编辑原文，按 ⌘Enter 重新翻译")
                        .padding(8)
                        .onAppear {
                            editorFocused = !manager.isTranslationVisible
                        }
                }
            }
            .frame(minHeight: manager.isTranslationVisible ? 54 : 80, maxHeight: manager.isTranslationVisible ? 116 : .infinity)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(editorFocused ? Color.accentColor : Color.primary.opacity(0.14), lineWidth: 1)
            )

            if manager.isTranslationVisible {
                Divider()
                translationSection
            }

            Divider()
            let copyDisabled = manager.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manager.isRecognizing
            HStack(spacing: 8) {
                Button {
                    if manager.isTranslationVisible { manager.copyTranslation() }
                    else { manager.copyCurrentText() }
                } label: {
                    let copied = manager.isTranslationVisible ? manager.copiedTranslationFeedback : manager.copiedFeedback
                    Label(copied ? "已复制" : (manager.isTranslationVisible ? "复制译文" : "复制原文"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .controlSize(.regular)
                .fixedSize(horizontal: true, vertical: false)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(manager.isTranslationVisible ? (manager.translatedText.isEmpty || manager.isTranslating) : copyDisabled)
                .help(manager.isTranslationVisible ? "复制完整译文 (⇧⌘C)" : "复制全部原文 (⇧⌘C)")

                Spacer(minLength: 4)

                if manager.sourceImage != nil && !manager.isTranslationVisible {
                    Toggle("合并换行", isOn: $manager.mergeLineBreaks)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: true, vertical: false)
                }

                Button(manager.translatedText.isEmpty ? "翻译" : "重新翻译") {
                    editorFocused = false
                    manager.requestTranslation()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(copyDisabled || manager.isTranslating)
                .help("翻译原文 (⌘Enter)")
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: manager.isTranslationVisible) { _, visible in
            if visible { editorFocused = false }
        }
    }

    private var languageBar: some View {
        HStack(spacing: 10) {
            Picker("原文语言", selection: $manager.translationSourceLanguage) {
                Text("自动检测").tag("auto")
                ForEach(TranslationConfig.languageOptions, id: \.tag) { option in
                    Text(option.label).tag(option.tag)
                }
            }
            .help("原文语言")
            Image(systemName: "arrow.right")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Picker("目标语言", selection: $manager.translationTargetLanguage) {
                ForEach(TranslationConfig.languageOptions, id: \.tag) { option in
                    Text(option.label).tag(option.tag)
                }
            }
            .help("目标语言")
        }
        .labelsHidden()
        .controlSize(.regular)
    }

    private var translationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("译文")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if manager.isTranslating {
                    ProgressView().controlSize(.mini)
                    Text("翻译中…").font(.system(size: 12))
                }
            }
            ZStack(alignment: .topLeading) {
                ScrollView {
                    if let error = manager.translationError {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("暂时无法翻译", systemImage: "exclamationmark.triangle")
                                .font(.system(size: 13, weight: .medium))
                            Text(error).font(.system(size: 13)).textSelection(.enabled)
                            Button("重试") { manager.requestTranslation() }.controlSize(.small)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if !manager.translatedText.isEmpty {
                        Text(manager.translatedText)
                            .font(.system(size: 16))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(translationHint)
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .scrollIndicators(.visible)
                if #available(macOS 15.0, *), let request = manager.translationRequest {
                    AppleTranslationTaskView(manager: manager, request: request).id(request.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 54)
        }
        .layoutPriority(1)
    }

    private var translationHint: String {
        if manager.isTranslating { return "首次使用可能需要按系统提示下载语言包。" }
        if manager.isRecognizing { return "识别完成后自动翻译" }
        if manager.errorMessage != nil { return "请先重试文字识别，再翻译。" }
        if manager.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "输入或粘贴原文后，点击「翻译」。"
        }
        return "原文已修改，点击「翻译」或按 ⌘Enter 更新译文。"
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
