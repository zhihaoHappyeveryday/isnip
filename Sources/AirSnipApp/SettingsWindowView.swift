import AppKit
import Carbon
import SwiftUI
import AirSnipCore

@MainActor
public final class SettingsWindowController {
    private var window: NSWindow?
    private let appController: AirSnipAppController

    public init(appController: AirSnipAppController) {
        self.appController = appController
    }

    public func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let win = window {
            applyTheme(appController.config.theme, to: win)
            win.orderFrontRegardless()
            win.makeKeyAndOrderFront(nil)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "iSnip"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.minSize = NSSize(width: 760, height: 500)

        let toolbar = NSToolbar(identifier: "io.zzusec.airsnip.settings.toolbar")
        toolbar.showsBaselineSeparator = false
        win.toolbar = toolbar
        win.toolbarStyle = .unified

        win.center()
        win.isReleasedWhenClosed = false
        applyTheme(appController.config.theme, to: win)
        win.contentView = NSHostingView(rootView: SettingsRootView(app: appController))
        self.window = win
        win.orderFrontRegardless()
        win.makeKeyAndOrderFront(nil)
    }

    public func hide() {
        window?.orderOut(nil)
    }

    public func refreshTheme() {
        if let win = window {
            applyTheme(appController.config.theme, to: win)
        }
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

public enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case captureAndPin
    case toolbar
    case hotkeys
    case editor
    case ocr
    case about

    public var id: String { rawValue }

    func title(in lang: AppLanguage) -> String {
        switch self {
        case .general: return lang.isEnglish ? "General" : "通用"
        case .captureAndPin: return lang.isEnglish ? "Capture" : "截图"
        case .toolbar: return lang.isEnglish ? "Toolbar" : "工具栏"
        case .hotkeys: return lang.isEnglish ? "Shortcuts" : "快捷键"
        case .editor: return lang.isEnglish ? "Annotation" : "标注"
        case .ocr: return lang.isEnglish ? "OCR & Translate" : "OCR 与翻译"
        case .about: return lang.isEnglish ? "About" : "关于"
        }
    }
}

@MainActor
final class SettingsUpdateState: ObservableObject {
    @Published var isChecking = false
    @Published var statusKind: StatusKind = .idle
    @Published var latestRelease: UpdateReleaseInfo?

    enum StatusKind: Equatable {
        case idle
        case checking
        case available(String)
        case upToDate
        case noPublishedRelease
        case failed(String)
    }

    func statusText(in lang: AppLanguage) -> String {
        switch statusKind {
        case .idle:
            return ""
        case .checking:
            return lang.isEnglish ? "Checking for updates…" : "正在检查更新…"
        case .available(let ver):
            return lang.isEnglish ? "\(ver) available" : "\(ver) 可更新"
        case .upToDate:
            return lang.isEnglish ? "Up to date" : "已是最新版本"
        case .noPublishedRelease:
            return lang.isEnglish ? "No published releases" : "暂无已发布版本"
        case .failed(let msg):
            return lang.isEnglish ? "Update check failed: \(msg)" : "检查失败：\(msg)"
        }
    }

    func checkNow(lang: AppLanguage, showToast: Bool = false) {
        guard !isChecking else { return }
        isChecking = true
        statusKind = .checking
        latestRelease = nil
        Task { @MainActor in
            let res = await UpdateChecker.checkLatest()
            isChecking = false
            switch res {
            case .success(.available(let info)):
                latestRelease = info
                statusKind = .available(info.version)
                if showToast {
                    ToastHUD.show(
                        L10n.tr("发现新版本 v\(info.version)", "New version v\(info.version) available", in: lang),
                        symbol: "arrow.down.circle"
                    )
                }
            case .success(.upToDate):
                statusKind = .upToDate
                if showToast {
                    ToastHUD.show(
                        L10n.tr("已是最新版本 v\(UpdateChecker.currentVersion)", "Up to date (v\(UpdateChecker.currentVersion))", in: lang),
                        symbol: "checkmark"
                    )
                }
            case .success(.noPublishedRelease):
                statusKind = .noPublishedRelease
                if showToast {
                    ToastHUD.show(statusText(in: lang), symbol: "info.circle")
                }
            case .failure(let err):
                statusKind = .failed(err.localizedDescription)
                if showToast {
                    ToastHUD.show(
                        L10n.tr("检查更新失败", "Update check failed", in: lang),
                        symbol: "exclamationmark.circle"
                    )
                }
            }
        }
    }
}

public struct SettingsRootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var app: AirSnipAppController
    @StateObject private var updateState = SettingsUpdateState()
    @State private var selectedTab: SettingsTab
    @State private var searchQuery: String
    @State private var recordingSlot: String?

    public init(
        app: AirSnipAppController,
        initialTab: SettingsTab = .general,
        initialSearchQuery: String = ""
    ) {
        self.app = app
        self._selectedTab = State(initialValue: initialTab)
        self._searchQuery = State(initialValue: initialSearchQuery)
    }

    private var lang: AppLanguage { app.config.language }

    private var trimmedSearch: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)

        VStack(spacing: 0) {
            // Row 1: Clean Unified Brand Header Bar (Traffic Lights + Brand + Refresh & Settings)
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    MagpieBrandMark(size: 17)
                    Text("iSnip")
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(p.inkPrimary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.leading, 78)

                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    HeaderIconButton(
                        symbol: "arrow.clockwise",
                        isActive: false,
                        spinning: updateState.isChecking,
                        helpText: L10n.tr("检查更新", "Check for Updates", in: lang)
                    ) {
                        updateState.checkNow(lang: lang, showToast: selectedTab != .about || !trimmedSearch.isEmpty)
                    }

                    HeaderIconButton(
                        symbol: "gearshape",
                        isActive: true,
                        helpText: L10n.tr("设置", "Settings", in: lang)
                    ) {
                        if !searchQuery.isEmpty {
                            withAnimation(.easeOut(duration: 0.14)) {
                                searchQuery = ""
                            }
                        }
                    }
                }
                .padding(.trailing, 18)
            }
            .frame(height: 52)

            // Row 2: Secondary Category Pill Tabs + Search Input
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    ForEach(SettingsTab.allCases) { tab in
                        SubTabPillButton(
                            title: tab.title(in: lang),
                            isSelected: trimmedSearch.isEmpty && selectedTab == tab
                        ) {
                            withAnimation(.easeOut(duration: 0.14)) {
                                searchQuery = ""
                                selectedTab = tab
                            }
                        }
                    }
                }

                Spacer(minLength: 12)

                SettingsSearchField(text: $searchQuery, lang: lang)
                    .frame(width: 216)
            }
            .padding(.horizontal, 20)
            .frame(height: 38)

            // Row 3: Continuous White Card Content Area
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !trimmedSearch.isEmpty {
                        SettingsSearchResultsPane(
                            app: app,
                            query: trimmedSearch,
                            updateState: updateState,
                            recordingSlot: $recordingSlot,
                            onSelectTab: { tab in
                                searchQuery = ""
                                selectedTab = tab
                            }
                        )
                    } else {
                        switch selectedTab {
                        case .general:
                            GeneralSettingsPane(app: app)
                        case .captureAndPin:
                            CaptureAndPinPane(app: app)
                        case .toolbar:
                            ToolbarSettingsPane(app: app)
                        case .hotkeys:
                            HotkeysSettingsPane(app: app, recordingSlot: $recordingSlot)
                        case .editor:
                            EditorDefaultsPane(app: app)
                        case .ocr:
                            OCRSettingsPane(app: app)
                        case .about:
                            AboutSettingsPane(app: app, updateState: updateState)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .environment(\.appLanguage, lang)
        .frame(minWidth: 760, idealWidth: 880, maxWidth: .infinity, minHeight: 500, idealHeight: 640, maxHeight: .infinity)
        .background(p.canvasBg)
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct ProjectInfoRow: View {
    @Environment(\.appLanguage) private var lang

    var body: some View {
        MagpieSettingRow(
            title: L10n.tr("项目说明", "Project Info", in: lang),
            subtitle: L10n.tr(
                "本项目基于 zzusec/isnip 二次开发而成，后续暂不持续维护。",
                "This project is based on zzusec/isnip. Ongoing maintenance is currently not planned.",
                in: lang
            )
        ) {
            MagpieTextAction(L10n.tr("原项目", "Original Project", in: lang)) {
                NSWorkspace.shared.open(URL(string: "https://github.com/zzusec/isnip")!)
            }
        }
    }
}

// MARK: - Header & Sub-Navigation Controls

private struct HeaderIconButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let symbol: String
    let isActive: Bool
    var spinning: Bool = false
    let helpText: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive || isHovered ? p.inkPrimary : p.inkSecondary)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 0.85).repeatForever(autoreverses: false) : .default, value: spinning)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isActive ? p.navActivePill : (isHovered ? p.navHoverPill : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityLabel(helpText)
    }
}

private struct SubTabPillButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? p.inkPrimary : (isHovered ? p.inkPrimary : p.inkSecondary))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .fill(isSelected ? p.navActivePill : (isHovered ? p.navHoverPill : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct SettingsSearchField: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    let lang: AppLanguage
    @FocusState private var isFocused: Bool

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        let placeholder = L10n.tr("查找设置", "Search settings", in: lang)
        HStack(spacing: 6) {
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(p.inkTertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(p.inkPrimary)
                .focused($isFocused)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(p.inkTertiary)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("清空搜索", "Clear search", in: lang))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(p.cardBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isFocused ? p.focusBorder : p.cardBorder, lineWidth: 1)
        )
    }
}

// MARK: - 1. General (通用 / General)

private struct GeneralSettingsPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var lang
    @ObservedObject var app: AirSnipAppController
    @State private var hasScreenCapture = ScreenCaptureService.hasScreenCapturePermission()
    @State private var hasAccessibility = AccessibilityService.hasPermission()

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)

        MagpieCard {
            MagpieSettingRow(title: L10n.tr("开机自动启动", "Launch at Login", in: lang)) {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.autoStart },
                        set: { val in
                            _ = LaunchAtLoginManager.setEnabled(val)
                            app.updateConfig { $0.autoStart = val }
                        }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("语言", "Language", in: lang)) {
                MagpieSegmentedPicker(
                    options: AppLanguage.allCases.map { ($0, $0.title(in: lang)) },
                    selection: Binding(
                        get: { app.config.language },
                        set: { l in app.updateConfig { $0.language = l } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("外观", "Appearance", in: lang)) {
                MagpieSegmentedPicker(
                    options: ThemeSetting.allCases.map { ($0, $0.title(in: lang)) },
                    selection: Binding(
                        get: { app.config.theme },
                        set: { t in
                            app.updateConfig { $0.theme = t }
                            app.settingsController?.refreshTheme()
                        }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("工具栏缩放", "Toolbar Scale", in: lang)) {
                MagpieSegmentedPicker(
                    options: UiScaleSetting.allCases.map { ($0, $0.title(in: lang)) },
                    selection: Binding(
                        get: { app.config.uiScale },
                        set: { s in app.updateConfig { $0.uiScale = s } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(
                title: L10n.tr("有标注时按两次 Esc 退出", "Press Esc Twice to Cancel", in: lang),
                infoTip: L10n.tr(
                    "开启后，画布上已有标注对象时首次按 Esc 仅显示确认提示，防止误触丢失内容",
                    "When enabled, pressing Esc once shows a confirmation prompt if annotations exist, preventing accidental loss",
                    in: lang
                )
            ) {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.confirmCancel },
                        set: { v in app.updateConfig { $0.confirmCancel = v } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(
                title: L10n.tr("操作完成提示", "Completion Toast", in: lang),
                infoTip: L10n.tr(
                    "截图复制或保存完成后，在屏幕顶部短暂展示轻量化确认卡片",
                    "Briefly show a subtle confirmation toast at the top of the screen after copying or saving",
                    in: lang
                )
            ) {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.showCompletionToast },
                        set: { v in app.updateConfig { $0.showCompletionToast = v } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(
                title: L10n.tr("屏幕录制权限", "Screen Recording", in: lang),
                subtitle: hasScreenCapture ? nil : L10n.tr(
                    "截图、独立窗体捕获与页面长截图依赖此系统授权",
                    "Required for area capture, window capture, and scrolling longshot",
                    in: lang
                )
            ) {
                if hasScreenCapture {
                    HStack(spacing: 10) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(p.statusOk)
                                .frame(width: 6, height: 6)
                            Text(L10n.tr("已授权", "Granted", in: lang))
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(p.inkMono)
                        }
                        MagpieTextAction(L10n.tr("打开设置", "Open Settings", in: lang)) {
                            ScreenCaptureService.openScreenCaptureSystemSettings()
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(L10n.tr("未授权", "Not Granted", in: lang))
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(p.statusWarn)
                        MagpieTextAction(L10n.tr("打开设置", "Open Settings", in: lang), prominent: true) {
                            ScreenCaptureService.openScreenCaptureSystemSettings()
                        }
                        MagpieTextAction(L10n.tr("重置权限", "Reset", in: lang)) {
                            ScreenCaptureService.resetScreenCapturePermissionAndRelaunch()
                        }
                    }
                }
            }

            MagpieRowDivider()

            MagpieSettingRow(
                title: L10n.tr("辅助功能权限", "Accessibility", in: lang),
                infoTip: L10n.tr(
                    "仅用于页面长截图自动平滑滚轮与划词翻译读取公开选中文本",
                    "Used only for automatic scrolling longshot and reading selected text for translation",
                    in: lang
                )
            ) {
                if hasAccessibility {
                    HStack(spacing: 10) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(p.statusOk)
                                .frame(width: 6, height: 6)
                            Text(L10n.tr("已授权", "Granted", in: lang))
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(p.inkMono)
                        }
                        MagpieTextAction(L10n.tr("打开设置", "Open Settings", in: lang)) {
                            AccessibilityService.openSystemSettings()
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(L10n.tr("未授权", "Not Granted", in: lang))
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(p.inkSecondary)
                        MagpieTextAction(L10n.tr("授权", "Grant", in: lang), prominent: true) {
                            _ = AccessibilityService.requestPermissionPrompt()
                            hasAccessibility = AccessibilityService.hasPermission()
                        }
                        MagpieTextAction(L10n.tr("打开设置", "Open Settings", in: lang)) {
                            AccessibilityService.openSystemSettings()
                        }
                    }
                }
            }
        }
        .onAppear {
            hasScreenCapture = ScreenCaptureService.hasScreenCapturePermission()
            hasAccessibility = AccessibilityService.hasPermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasScreenCapture = ScreenCaptureService.hasScreenCapturePermission()
            hasAccessibility = AccessibilityService.hasPermission()
        }
    }
}

// MARK: - 2. Capture, Compression & Pin (截图 / Capture)

private struct CaptureAndPinPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var lang
    @ObservedObject var app: AirSnipAppController

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        let saveDirURL = OutputService.defaultSaveDirectoryURL(for: app.config)
        let saveDisplayPath = OutputService.displayPath(for: saveDirURL)

        MagpieCard {
            MagpieSettingRow(
                title: L10n.tr("智能无损压缩", "Smart Lossless Compression", in: lang),
                infoTip: L10n.tr(
                    "内置 pngquant + oxipng 双引擎管线，瞬时输出后后台原子精压，体积可缩减 60%–75%",
                    "Built-in pngquant + oxipng pipeline reduces PNG size by 60%–75% in the background without blocking output",
                    in: lang
                )
            ) {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.smartPngCompression },
                        set: { v in app.updateConfig { $0.smartPngCompression = v } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("压缩档位", "Compression Level", in: lang)) {
                MagpieSegmentedPicker(
                    options: PngCompressionQualityPreset.allCases.map { ($0, $0.title(in: lang)) },
                    selection: Binding(
                        get: { app.config.pngCompressionQuality },
                        set: { q in app.updateConfig { $0.pngCompressionQuality = q } }
                    )
                )
                .disabled(!app.config.smartPngCompression)
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("压缩剪贴板图片", "Compress Clipboard Images", in: lang)) {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.compressClipboardPng },
                        set: { v in app.updateConfig { $0.compressClipboardPng = v } }
                    )
                )
                .disabled(!app.config.smartPngCompression)
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("保存位置", "Save Location", in: lang)) {
                HStack(spacing: 6) {
                    Text(saveDisplayPath)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(p.inkMono)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 260, alignment: .trailing)

                    MagpieCopyButton(value: saveDirURL.path)

                    MagpieTextAction(L10n.tr("打开", "Open", in: lang)) {
                        try? FileManager.default.createDirectory(at: saveDirURL, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(saveDirURL)
                    }

                    MagpieTextAction(L10n.tr("更改…", "Change…", in: lang)) {
                        if let chosen = OutputService.chooseSaveDirectory(initial: saveDirURL) {
                            app.updateConfig { $0.lastSaveDirectory = chosen.path }
                        }
                    }
                }
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("每次询问保存位置", "Ask Where to Save Each Time", in: lang)) {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.askBeforeSave },
                        set: { v in app.updateConfig { $0.askBeforeSave = v } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("默认格式", "Default Format", in: lang)) {
                MagpieSegmentedPicker(
                    options: ExportImageFormat.allCases.map { ($0, $0.displayName) },
                    selection: Binding(
                        get: { app.config.lastSaveFormat },
                        set: { f in app.updateConfig { $0.lastSaveFormat = f } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("文件命名", "Filename Format", in: lang)) {
                MagpieSegmentedPicker(
                    options: NameStyle.allCases.map { ($0, $0.title(in: lang)) },
                    selection: Binding(
                        get: { app.config.nameStyle },
                        set: { s in app.updateConfig { $0.nameStyle = s } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("自动识别窗口", "Snap to Windows", in: lang)) {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.windowSnap },
                        set: { v in app.updateConfig { $0.windowSnap = v } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(
                title: L10n.tr("窗体截图保留阴影", "Keep Window Shadow", in: lang),
                infoTip: L10n.tr(
                    "窗体截图模式下按住 Option 点击窗口可临时切换无阴影",
                    "Hold Option while clicking a window to temporarily toggle shadow",
                    in: lang
                )
            ) {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.windowCaptureShadow },
                        set: { v in app.updateConfig { $0.windowCaptureShadow = v } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("页面长截图自动翻页", "Auto-Scroll Longshot", in: lang)) {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.longshotAutoScroll },
                        set: { v in app.updateConfig { $0.longshotAutoScroll = v } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("长截图翻页速度", "Longshot Scroll Speed", in: lang)) {
                MagpieSegmentedPicker(
                    options: LongshotScrollSpeed.allCases.map { ($0, $0.title(in: lang)) },
                    selection: Binding(
                        get: { app.config.longshotScrollSpeed },
                        set: { s in app.updateConfig { $0.longshotScrollSpeed = s } }
                    )
                )
                .disabled(!app.config.longshotAutoScroll)
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("长截图高度上限", "Max Longshot Height", in: lang)) {
                MagpieStepperPill(
                    displayValue: "\(app.config.longshotMaxHeight) px",
                    canDecrement: app.config.longshotMaxHeight > 5000,
                    canIncrement: app.config.longshotMaxHeight < 60000,
                    onDecrement: {
                        app.updateConfig { $0.longshotMaxHeight = max(5000, $0.longshotMaxHeight - 5000) }
                    },
                    onIncrement: {
                        app.updateConfig { $0.longshotMaxHeight = min(60000, $0.longshotMaxHeight + 5000) }
                    }
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("贴图初始位置", "Initial Pin Position", in: lang)) {
                MagpieSegmentedPicker(
                    options: PinPosition.allCases.map { ($0, $0.title(in: lang)) },
                    selection: Binding(
                        get: { app.config.pinPosition },
                        set: { pos in app.updateConfig { $0.pinPosition = pos } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("贴图显示边框", "Show Pin Border", in: lang)) {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.pinBorder },
                        set: { b in app.updateConfig { $0.pinBorder = b } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("贴图数量上限", "Max Active Pins", in: lang)) {
                MagpieStepperPill(
                    displayValue: lang.isEnglish ? "\(app.config.pinMaxCount) pins" : "\(app.config.pinMaxCount) 张",
                    canDecrement: app.config.pinMaxCount > 5,
                    canIncrement: app.config.pinMaxCount < 50,
                    onDecrement: {
                        app.updateConfig { $0.pinMaxCount = max(5, $0.pinMaxCount - 5) }
                    },
                    onIncrement: {
                        app.updateConfig { $0.pinMaxCount = min(50, $0.pinMaxCount + 5) }
                    }
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("可恢复贴图数", "Recoverable Pins", in: lang)) {
                MagpieStepperPill(
                    displayValue: lang.isEnglish ? "\(app.config.pinHistoryLimit) pins" : "\(app.config.pinHistoryLimit) 张",
                    canDecrement: app.config.pinHistoryLimit > AirSnipConfig.pinHistoryLimitRange.lowerBound,
                    canIncrement: app.config.pinHistoryLimit < AirSnipConfig.pinHistoryLimitRange.upperBound,
                    onDecrement: {
                        app.updateConfig { $0.pinHistoryLimit -= 5 }
                    },
                    onIncrement: {
                        app.updateConfig { $0.pinHistoryLimit += 5 }
                    }
                )
            }
        }
    }
}

// MARK: - 3. Toolbar (工具栏 / Toolbar)

private struct ToolbarSettingsPane: View {
    private enum Page {
        case visibility
        case order
    }

    @Environment(\.appLanguage) private var lang
    @ObservedObject var app: AirSnipAppController
    @State private var page = Page.visibility

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MagpieSegmentedPicker(
                options: [
                    (.visibility, L10n.tr("显示与隐藏", "Visibility", in: lang)),
                    (.order, L10n.tr("按钮顺序", "Button Order", in: lang))
                ],
                selection: $page
            )

            switch page {
            case .visibility:
                ToolbarVisibilityPane(app: app)
            case .order:
                ToolbarOrderPane(app: app)
            }
        }
    }
}

private struct ToolbarOrderPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var lang
    @ObservedObject var app: AirSnipAppController

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        let toolbar = app.config.toolbar
        let order = toolbar.mainOrder
        let hasCustomOrder = toolbar.hasCustomMainOrder

        MagpieCard {
            MagpieSettingRow(
                title: L10n.tr("拖动调整顺序", "Drag to Reorder", in: lang),
                subtitle: L10n.tr("列表从上到下对应工具栏从左到右", "List order (top to bottom) becomes toolbar order (left to right)", in: lang)
            ) {
                MagpieTextAction(L10n.tr("恢复默认顺序", "Restore Default Order", in: lang), prominent: hasCustomOrder) {
                    app.updateConfig { $0.toolbar.resetMainOrder() }
                }
                .disabled(!hasCustomOrder)
            }

            MagpieRowDivider()
            List {
                ForEach(order, id: \.key) { slot in
                    HStack(spacing: 8) {
                        Text(label(for: slot))
                            .font(.system(size: 13.5))
                            .foregroundStyle(p.inkPrimary)
                        Spacer()
                        if !toolbar.isVisible(slot) {
                            Text(L10n.tr("已隐藏", "Hidden", in: lang))
                                .font(.system(size: 11.5))
                                .foregroundStyle(p.inkSecondary)
                        }
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 11.5))
                            .foregroundStyle(p.inkTertiary)
                            .accessibilityHidden(true)
                    }
                    .listRowInsets(EdgeInsets(top: 7, leading: 20, bottom: 7, trailing: 20))
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(p.rowDivider)
                }
                .onMove(perform: move)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: 300)
        }
    }

    private func label(for slot: ToolbarSlot) -> String {
        switch slot {
        case .tool(let tool): return tool.displayName(in: lang)
        case .copy: return L10n.tr("完成", "Done", in: lang)
        default: return slot.label(in: lang)
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        let currentOrder = app.config.toolbar.mainOrder
        var order = currentOrder
        order.move(fromOffsets: source, toOffset: destination)
        guard order != currentOrder else { return }
        app.updateConfig { $0.toolbar.mainOrder = order }
    }
}

private struct ToolbarVisibilityPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var lang
    @ObservedObject var app: AirSnipAppController
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        let slots = ToolbarSlot.hideableSlots
        let totalSlots = slots.count
        let visibleSlots = slots.filter { app.config.toolbar.isVisible($0) }.count

        MagpieCard {
            MagpieSettingRow(
                title: L10n.tr("悬浮工具栏槽位", "Floating Toolbar Items", in: lang),
                subtitle: L10n.tr(
                    "当前显示 \(visibleSlots) / \(totalSlots) 项",
                    "Showing \(visibleSlots) of \(totalSlots) items",
                    in: lang
                )
            ) {
                MagpieTextAction(L10n.tr("全部显示", "Show All", in: lang), prominent: visibleSlots < totalSlots) {
                    app.updateConfig { $0.toolbar.hidden.removeAll() }
                }
                .disabled(visibleSlots == totalSlots)
            }

            ForEach(ToolbarGroup.allCases, id: \.rawValue) { group in
                let state = app.config.toolbar.groupState(group)
                MagpieRowDivider()

                VStack(alignment: .leading, spacing: 11) {
                    HStack(alignment: .center) {
                        Text(group.title(in: lang))
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(p.inkPrimary)

                        Text("\(app.config.toolbar.visibleCount(in: group))/\(group.slots.count)")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(p.inkTertiary)

                        Spacer()

                        MagpieBooleanSwitch(
                            isOn: Binding(
                                get: { state != .none },
                                set: { turnOn in
                                    app.updateConfig { $0.toolbar.setGroupVisible(group, turnOn) }
                                }
                            ),
                            offLabel: L10n.tr("全隐", "Hide", in: lang),
                            onLabel: L10n.tr("显示", "Show", in: lang)
                        )
                    }

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 7) {
                        ForEach(group.slots, id: \.key) { slot in
                            ToolbarSlotChip(
                                label: slot.label(in: lang),
                                isVisible: app.config.toolbar.isVisible(slot)
                            ) {
                                let cur = app.config.toolbar.isVisible(slot)
                                app.updateConfig { $0.toolbar.setVisible(slot, !cur) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
        }
    }
}

private struct ToolbarSlotChip: View {
    @Environment(\.colorScheme) private var colorScheme
    let label: String
    let isVisible: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isVisible ? "checkmark" : "plus")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(isVisible ? p.inkPrimary : p.inkTertiary)
                Text(label)
                    .font(.system(size: 12, weight: isVisible ? .medium : .regular))
                    .foregroundStyle(isVisible ? p.inkPrimary : p.inkSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                    .fill(isVisible ? p.segmentedThumb : p.segmentedTrack.opacity(isHovered ? 1.0 : 0.65))
                    .shadow(
                        color: .black.opacity(isVisible ? (p.isDark ? 0.22 : 0.04) : 0),
                        radius: 1.5,
                        x: 0,
                        y: 0.5
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                    .strokeBorder(
                        isVisible ? p.segmentedThumbBorder : (isHovered ? p.cardBorder : Color.clear),
                        lineWidth: 0.85
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 4. Hotkeys (快捷键 / Shortcuts)

private struct HotkeysSettingsPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var lang
    @ObservedObject var app: AirSnipAppController
    @Binding var recordingSlot: String?

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        let conflicts = app.config.hotkeyConflicts(in: lang) + app.hotkeyRegistrationErrors

        VStack(alignment: .leading, spacing: 12) {
            if !conflicts.isEmpty {
                MagpieCard(cornerRadius: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(conflicts, id: \.self) { msg in
                            HStack(spacing: 7) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(p.statusWarn)
                                Text(msg)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(p.statusWarn)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                }
            }

            MagpieCard {
                MagpieSettingRow(
                    title: L10n.tr("快捷键绑定", "Keyboard Shortcuts", in: lang),
                    subtitle: L10n.tr(
                        "点击右侧键位录制新组合键或鼠标中键/侧键，按 Esc 取消录制",
                        "Click a shortcut pill to record a new key combination or extra mouse button; press Esc to cancel",
                        in: lang
                    )
                ) {
                    MagpieTextAction(L10n.tr("恢复默认", "Reset Defaults", in: lang)) {
                        recordingSlot = nil
                        app.updateConfig {
                            $0.hotkeys = HotkeyConfig()
                            $0.toolKeys = ToolKeysConfig()
                        }
                    }
                }

                MagpieRowDivider()
                MagpieSectionGroupRow(
                    title: L10n.tr("全局热键", "Global Shortcuts", in: lang),
                    trailingText: L10n.tr("系统级常驻响应", "Always active", in: lang)
                )

                MagpieRowDivider()
                HotkeyRow(title: L10n.tr("开始截图", "Capture Area", in: lang), slotID: "global.screenshot", binding: app.config.hotkeys.screenshot, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.screenshot = b }
                }
                MagpieRowDivider()
                HotkeyRow(title: L10n.tr("独立窗体截图", "Capture Window", in: lang), slotID: "global.windowCapture", binding: app.config.hotkeys.windowCapture, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.windowCapture = b }
                }
                MagpieRowDivider()
                HotkeyRow(title: L10n.tr("页面长截图", "Scrolling Capture", in: lang), slotID: "global.longshotCapture", binding: app.config.hotkeys.longshotCapture, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.longshotCapture = b }
                }
                MagpieRowDivider()
                HotkeyRow(title: L10n.tr("截图识字", "Capture & OCR", in: lang), slotID: "global.ocrCapture", binding: app.config.hotkeys.ocrCapture, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.ocrCapture = b }
                }
                MagpieRowDivider()
                HotkeyRow(title: L10n.tr("划词翻译", "Translate Selection", in: lang), slotID: "global.translateSelection", binding: app.config.hotkeys.translateSelection, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.translateSelection = b }
                }
                MagpieRowDivider()
                HotkeyRow(title: L10n.tr("截图翻译", "Capture & Translate", in: lang), slotID: "global.translateCapture", binding: app.config.hotkeys.translateCapture, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.translateCapture = b }
                }
                MagpieRowDivider()
                HotkeyRow(title: L10n.tr("贴图或恢复", "Pin or Restore", in: lang), slotID: "global.pin", binding: app.config.hotkeys.pin, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.pin = b }
                }
                MagpieRowDivider()
                HotkeyRow(title: L10n.tr("切换贴图边框", "Toggle Pin Borders", in: lang), slotID: "global.pinBorder", binding: app.config.hotkeys.pinBorderToggle, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.pinBorderToggle = b }
                }

                MagpieRowDivider()
                MagpieSectionGroupRow(
                    title: L10n.tr("截图会话内", "In-Capture", in: lang),
                    trailingText: L10n.tr("框选期间生效", "During selection", in: lang)
                )

                MagpieRowDivider()
                HotkeyRow(title: L10n.tr("重新抓屏", "Recapture Screen", in: lang), slotID: "ov.recapture", binding: app.config.hotkeys.recapture, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.recapture = b }
                }
                MagpieRowDivider()
                HotkeyRow(title: L10n.tr("进入长截图", "Enter Longshot", in: lang), slotID: "ov.longshot", binding: app.config.hotkeys.longshot, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.longshot = b }
                }
                MagpieRowDivider()
                HotkeyRow(title: L10n.tr("选区 OCR 识字", "Selection OCR", in: lang), slotID: "ov.ocr", binding: app.config.hotkeys.ocr, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.ocr = b }
                }

                MagpieRowDivider()
                MagpieSectionGroupRow(
                    title: L10n.tr("标注工具切换", "Annotation Tools", in: lang),
                    trailingText: L10n.tr("默认数字键 1–0", "Digits 1–0 by default", in: lang)
                )

                ForEach(AnnotationTool.allOrdered, id: \.rawValue) { tool in
                    MagpieRowDivider()
                    HotkeyRow(
                        title: tool.shortLabel(in: lang),
                        slotID: "tool.\(tool.rawValue)",
                        binding: app.config.toolKeys.binding(for: tool),
                        recordingSlot: $recordingSlot
                    ) { b in
                        app.updateConfig { $0.toolKeys.setBinding(b, for: tool) }
                    }
                }
            }
        }
    }
}

private struct HotkeyRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var lang
    let title: String
    var subtitle: String? = nil
    let slotID: String
    let binding: HotkeyBinding
    @Binding var recordingSlot: String?
    let onUpdate: (HotkeyBinding) -> Void

    @State private var eventMonitor: Any?
    @State private var isHovered = false

    private var isRecording: Bool { recordingSlot == slotID }

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)

        MagpieSettingRow(title: title, subtitle: subtitle) {
            HStack(spacing: 8) {
                Button {
                    if isRecording {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                } label: {
                    Text(isRecording ? L10n.tr("按下快捷键…", "Press shortcut…", in: lang) : binding.displayString(in: lang))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(isRecording ? p.inkPrimary : (binding.isUnbound ? p.inkTertiary : p.inkMono))
                        .padding(.horizontal, 12)
                        .frame(minWidth: 112, minHeight: 27)
                        .background(
                            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                .fill(isRecording ? p.segmentedThumb : (isHovered ? p.segmentedThumb : p.segmentedTrack))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                .strokeBorder(
                                    isRecording ? p.inkPrimary : (isHovered ? p.segmentedThumbBorder : Color.clear),
                                    lineWidth: isRecording ? 1.2 : 0.85
                                )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }

                if !binding.isUnbound {
                    Button {
                        stopRecording()
                        onUpdate(.unbound)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(p.inkTertiary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("清除快捷键", "Clear shortcut", in: lang))
                } else {
                    Spacer().frame(width: 20)
                }
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        recordingSlot = slotID
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { ev in
            if ev.type == .otherMouseDown, let mb = MouseExtraButton(rawValue: ev.buttonNumber) {
                onUpdate(HotkeyBinding(keyCode: nil, modifiers: [], mouseButton: mb))
                stopRecording()
                return nil
            }
            if ev.type == .keyDown {
                let kc = Int(ev.keyCode)
                if kc == kVK_Escape {
                    stopRecording()
                    return nil
                }
                let mods = HotkeyModifiers.fromNSEventFlags(ev.modifierFlags.intersection(.deviceIndependentFlagsMask))
                onUpdate(HotkeyBinding(keyCode: kc, modifiers: mods, mouseButton: nil))
                stopRecording()
                return nil
            }
            return ev
        }
    }

    private func stopRecording() {
        if recordingSlot == slotID { recordingSlot = nil }
        if let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }
    }
}

// MARK: - 5. Editor Defaults (标注 / Annotation)

private struct EditorDefaultsPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var lang
    @ObservedObject var app: AirSnipAppController

    private func swiftUIColor(_ c: RGBAColor) -> Color {
        Color(.sRGB, red: Double(c.r) / 255.0, green: Double(c.g) / 255.0, blue: Double(c.b) / 255.0, opacity: 1.0)
    }

    private func rgbaFromNSColor(_ ns: NSColor) -> RGBAColor {
        let conv = ns.usingColorSpace(.sRGB) ?? ns
        return RGBAColor(
            r: UInt8(max(0, min(255, Int((conv.redComponent * 255.0).rounded())))),
            g: UInt8(max(0, min(255, Int((conv.greenComponent * 255.0).rounded())))),
            b: UInt8(max(0, min(255, Int((conv.blueComponent * 255.0).rounded()))))
        )
    }

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        let clampedActiveIdx = max(0, min(app.config.swatchColors.count - 1, app.config.activeColorIndex))
        let activeRGB = app.config.swatchColors[clampedActiveIdx]
        let activeLum = (0.299 * Double(activeRGB.r) + 0.587 * Double(activeRGB.g) + 0.114 * Double(activeRGB.b)) / 255.0
        let needsDarkPreview = activeLum > 0.80

        MagpieCard {
            MagpieSettingRow(title: L10n.tr("线宽", "Stroke Width", in: lang)) {
                HStack(spacing: 14) {
                    MagpieSlider(
                        value: Binding(
                            get: { app.config.defaultLineWidth },
                            set: { v in app.updateConfig { $0.defaultLineWidth = v.rounded() } }
                        ),
                        in: 1...20,
                        step: 1
                    )
                    .frame(width: 210)

                    Text("\(Int(app.config.defaultLineWidth)) px")
                        .font(.system(size: 12.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(p.inkMono)
                        .frame(width: 52, alignment: .trailing)
                }
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("模糊强度", "Blur Radius", in: lang)) {
                HStack(spacing: 14) {
                    MagpieSlider(
                        value: Binding(
                            get: { app.config.defaultBlurRadius },
                            set: { v in app.updateConfig { $0.defaultBlurRadius = (v / 2.0).rounded() * 2.0 } }
                        ),
                        in: 4...48,
                        step: 2
                    )
                    .frame(width: 210)

                    Text("\(Int(app.config.defaultBlurRadius)) px")
                        .font(.system(size: 12.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(p.inkMono)
                        .frame(width: 52, alignment: .trailing)
                }
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("默认字号", "Default Font Size", in: lang)) {
                HStack(spacing: 14) {
                    MagpieSlider(
                        value: Binding(
                            get: { app.config.defaultFontSize },
                            set: { v in app.updateConfig { $0.defaultFontSize = (v / 2.0).rounded() * 2.0 } }
                        ),
                        in: 12...72,
                        step: 2
                    )
                    .frame(width: 210)

                    Text("\(Int(app.config.defaultFontSize)) pt")
                        .font(.system(size: 12.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(p.inkMono)
                        .frame(width: 52, alignment: .trailing)
                }
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("实心填充", "Solid Fill", in: lang)) {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.defaultFillEnabled },
                        set: { v in app.updateConfig { $0.defaultFillEnabled = v } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(
                title: L10n.tr("预设调色板", "Color Presets", in: lang),
                subtitle: L10n.tr(
                    "选中色槽后可通过右侧取色器自定义对应预设色",
                    "Select a preset slot, then use the color well on the right to customize it",
                    in: lang
                )
            ) {
                HStack(spacing: 14) {
                    HStack(spacing: 11) {
                        ForEach(0..<ColorPalette.swatchCount, id: \.self) { idx in
                            let c = idx < app.config.swatchColors.count ? app.config.swatchColors[idx] : ColorPalette.defaultSwatches[idx]
                            let isActive = (clampedActiveIdx == idx)
                            let lum = (0.299 * Double(c.r) + 0.587 * Double(c.g) + 0.114 * Double(c.b)) / 255.0

                            Button {
                                app.updateConfig { $0.activeColorIndex = idx }
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(swiftUIColor(c))
                                        .frame(width: 24, height: 24)
                                        .overlay(
                                            Circle()
                                                .strokeBorder(
                                                    Color.primary.opacity(lum > 0.80 ? 0.24 : 0.15),
                                                    lineWidth: 1
                                                )
                                        )
                                        .overlay(
                                            Circle()
                                                .strokeBorder(p.inkPrimary, lineWidth: isActive ? 1.8 : 0)
                                                .padding(-3.2)
                                        )

                                    if isActive {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9.5, weight: .bold))
                                            .foregroundStyle(lum > 0.68 ? Color.black.opacity(0.82) : Color.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Rectangle()
                        .fill(p.cardBorder)
                        .frame(width: 1, height: 16)

                    HStack(spacing: 6) {
                        Text(activeRGB.hexString)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(p.inkMono)

                        ColorPicker("", selection: Binding(
                            get: { swiftUIColor(activeRGB) },
                            set: { newCol in
                                let ns = NSColor(newCol)
                                let rgba = rgbaFromNSColor(ns)
                                app.updateConfig {
                                    if clampedActiveIdx < $0.swatchColors.count {
                                        $0.swatchColors[clampedActiveIdx] = rgba
                                    }
                                }
                            }
                        ), supportsOpacity: false)
                        .labelsHidden()
                    }
                }
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("标注样式预览", "Style Preview", in: lang)) {
                HStack(spacing: 14) {
                    HStack(spacing: 14) {
                        Group {
                            if app.config.defaultFillEnabled {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(swiftUIColor(activeRGB))
                            } else {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(
                                        swiftUIColor(activeRGB),
                                        lineWidth: max(1.5, min(7, app.config.defaultLineWidth * 0.6))
                                    )
                            }
                        }
                        .frame(width: 44, height: 22)

                        Capsule()
                            .fill(swiftUIColor(activeRGB))
                            .frame(width: 60, height: max(2, min(14, app.config.defaultLineWidth)))

                        Text(L10n.tr("Aa 预览", "Aa Preview", in: lang))
                            .font(.system(size: max(12, min(20, app.config.defaultFontSize * 0.64)), weight: .semibold))
                            .foregroundStyle(swiftUIColor(activeRGB))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                            .fill(needsDarkPreview ? Color(white: 0.16) : p.subtleSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                            .strokeBorder(p.cardBorder, lineWidth: 1)
                    )

                    MagpieTextAction(L10n.tr("恢复默认", "Reset Defaults", in: lang)) {
                        app.updateConfig {
                            $0.swatchColors = ColorPalette.defaultSwatches
                            $0.activeColorIndex = 1
                            $0.defaultLineWidth = 2.0
                            $0.defaultBlurRadius = 16.0
                            $0.defaultFontSize = 24.0
                            $0.defaultFillEnabled = false
                        }
                    }
                }
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("贴图标注时遮住桌面", "Cover Desktop When Annotating Pins", in: lang)) {
                MagpieBooleanSwitch(isOn: Binding(
                    get: { app.config.pinAnnotationCoversDesktop },
                    set: { enabled in app.updateConfig { $0.pinAnnotationCoversDesktop = enabled } }
                ))
            }
        }
    }
}

// MARK: - 6. OCR & Translation (OCR 与翻译 / OCR & Translate)

private struct OCRSettingsPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var lang
    @ObservedObject var app: AirSnipAppController

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)

        MagpieCard {
            MagpieSettingRow(
                title: L10n.tr("识别语言", "Recognition Language", in: lang),
                infoTip: L10n.tr(
                    "基于端侧 Apple Vision 离线文字识别，全程不上传网络",
                    "Runs 100% offline on-device via Apple Vision; images never leave your Mac",
                    in: lang
                )
            ) {
                MagpieMenuPicker(
                    L10n.tr("识别语言", "Recognition Language", in: lang),
                    options: OcrConfig.supportedOptions(in: lang).map { ($0.tag, $0.label) },
                    selection: Binding(
                        get: { app.config.ocr.language },
                        set: { l in app.updateConfig { $0.ocr.language = l } }
                    ),
                    minWidth: 132
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("自动复制识别结果", "Auto-Copy Result", in: lang)) {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.ocr.autoCopy },
                        set: { ac in app.updateConfig { $0.ocr.autoCopy = ac } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("合并段落换行", "Merge Line Breaks", in: lang)) {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.ocr.mergeLineBreaks },
                        set: { mb in app.updateConfig { $0.ocr.mergeLineBreaks = mb } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("识别二维码与条码", "Detect QR & Barcodes", in: lang)) {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.ocr.detectBarcodes },
                        set: { db in app.updateConfig { $0.ocr.detectBarcodes = db } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("快捷文字识别", "Quick OCR", in: lang)) {
                HStack(spacing: 6) {
                    Button(L10n.tr("框选识字", "Capture Area", in: lang)) {
                        app.settingsController?.hide()
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 180_000_000)
                            app.triggerDirectOCRCapture()
                        }
                    }
                    .buttonStyle(MagpiePillButtonStyle(role: .bordered, compact: true))

                    Button(L10n.tr("剪贴板识字", "From Clipboard", in: lang)) {
                        app.triggerOCRFromClipboard()
                    }
                    .buttonStyle(MagpiePillButtonStyle(role: .bordered, compact: true))

                    Button(L10n.tr("选择图片…", "Choose Image…", in: lang)) {
                        app.triggerOCRFromFile()
                    }
                    .buttonStyle(MagpiePillButtonStyle(role: .bordered, compact: true))
                }
            }

            MagpieRowDivider()

            MagpieSettingRow(
                title: L10n.tr("翻译目标语言", "Target Language", in: lang),
                subtitle: L10n.tr(
                    "使用 macOS 15+ 系统 Translation 框架，无需配置 API Key",
                    "Uses built-in macOS 15+ Translation framework; no API key required",
                    in: lang
                )
            ) {
                MagpieMenuPicker(
                    L10n.tr("目标语言", "Target Language", in: lang),
                    options: TranslationConfig.languageOptions.map { ($0.tag, $0.label) },
                    selection: Binding(
                        get: { app.config.translation.targetLanguage },
                        set: { language in app.updateConfig { $0.translation.targetLanguage = language } }
                    ),
                    minWidth: 132
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(
                title: L10n.tr("划词后显示翻译按钮", "Show Floating Translate Button", in: lang),
                subtitle: L10n.tr(
                    "仅读取应用公开选中文字，不模拟复制或改写剪贴板；无法取词处请用截图翻译",
                    "Reads accessible selection without touching the clipboard; use Capture & Translate for unsupported apps",
                    in: lang
                ),
                infoTip: L10n.tr("需要辅助功能权限", "Requires Accessibility permission", in: lang)
            ) {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.translation.showSelectionButton },
                        set: { enabled in app.updateConfig { $0.translation.showSelectionButton = enabled } }
                    )
                )
            }

            MagpieRowDivider()

            let selKey = app.config.hotkeys.translateSelection.displayString(in: lang)
            let capKey = app.config.hotkeys.translateCapture.displayString(in: lang)
            MagpieSettingRow(
                title: L10n.tr("快捷翻译入口", "Translation Shortcuts", in: lang),
                subtitle: L10n.tr(
                    "划词翻译 \(selKey)  ·  截图翻译 \(capKey)",
                    "Selection \(selKey)  ·  Capture \(capKey)",
                    in: lang
                )
            ) {
                HStack(spacing: 10) {
                    Text("\(selKey) / \(capKey)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(p.inkMono)

                    Button(L10n.tr("截图翻译", "Capture & Translate", in: lang)) {
                        app.settingsController?.hide()
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 180_000_000)
                            app.triggerOCRTranslation()
                        }
                    }
                    .buttonStyle(MagpiePillButtonStyle(role: .bordered, compact: true))
                }
            }
        }
    }
}

// MARK: - 7. About (关于 / About)

private struct PinHistoryDirectoryRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var lang
    @ObservedObject var app: AirSnipAppController
    var subtitle: String? = nil

    var body: some View {
        let historyRoot = OutputService.pinHistoryRootURL(for: app.config)
        MagpieSettingRow(
            title: L10n.tr("贴图历史目录", "Pin History Directory", in: lang),
            subtitle: subtitle,
            infoTip: L10n.tr(
                "按关闭日期存放贴图。默认跟随截图保存目录。",
                "Stores closed pins by date. By default, follows the screenshot save location.", in: lang
            )
        ) {
            HStack(spacing: 6) {
                Text(OutputService.displayPath(for: historyRoot))
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(MagpiePalette(colorScheme: colorScheme).inkMono)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .trailing)
                MagpieCopyButton(value: historyRoot.path)
                MagpieTextAction(L10n.tr("打开", "Open", in: lang)) {
                    do {
                        try ClosedPinHistory.ensureHistoryRootExists(historyRoot)
                        NSWorkspace.shared.open(historyRoot)
                    } catch {
                        ToastHUD.show(L10n.tr("无法打开贴图历史目录", "Could not open the pin history directory", in: lang),
                                      symbol: "exclamationmark.triangle", tint: .systemOrange)
                    }
                }
                MagpieTextAction(L10n.tr("更改…", "Change…", in: lang)) {
                    if let chosen = OutputService.chooseSaveDirectory(initial: historyRoot.deletingLastPathComponent()) {
                        app.updateConfig { $0.pinHistoryDirectory = chosen.path }
                    }
                }
                if app.config.pinHistoryDirectory != nil {
                    MagpieTextAction(L10n.tr("恢复默认", "Restore Default", in: lang)) {
                        app.updateConfig { $0.pinHistoryDirectory = nil }
                    }
                }
            }
        }
    }
}

private struct UpdateVersionRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var lang
    @ObservedObject var updateState: SettingsUpdateState
    var idleSubtitle: String?

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        let status = updateState.statusText(in: lang)
        MagpieSettingRow(
            title: L10n.tr("版本", "Version", in: lang),
            subtitle: status.isEmpty ? idleSubtitle : status
        ) {
            HStack(spacing: 12) {
                Text(UpdateChecker.currentVersion)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(p.inkMono)

                if let rel = updateState.latestRelease {
                    MagpieTextAction(L10n.tr("下载 v\(rel.version)", "Download v\(rel.version)", in: lang), prominent: true) {
                        NSWorkspace.shared.open(rel.downloadURL ?? rel.htmlURL)
                    }
                } else {
                    MagpieTextAction(
                        updateState.isChecking
                            ? L10n.tr("检查中…", "Checking…", in: lang)
                            : L10n.tr("检查更新", "Check for Updates", in: lang)
                    ) {
                        updateState.checkNow(lang: lang)
                    }
                    .disabled(updateState.isChecking)
                }
            }
        }
    }
}

private struct AboutSettingsPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var lang
    @ObservedObject var app: AirSnipAppController
    @ObservedObject var updateState: SettingsUpdateState

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        let configDirURL = app.configURL.deletingLastPathComponent()
        let configDisplayPath = OutputService.displayPath(for: configDirURL)
        let saveDirURL = OutputService.defaultSaveDirectoryURL(for: app.config)
        let saveDisplayPath = OutputService.displayPath(for: saveDirURL)
        let repoURL = UpdateChecker.repositoryURL

        MagpieCard {
            UpdateVersionRow(updateState: updateState)

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("更新内容", "Release Notes", in: lang)) {
                MagpieTextAction(L10n.tr("打开", "Open", in: lang)) {
                    NSWorkspace.shared.open(repoURL.appendingPathComponent("releases"))
                }
            }

            MagpieRowDivider()

            MagpieSettingRow(
                title: L10n.tr("自动更新检查", "Automatic Update Check", in: lang),
                infoTip: L10n.tr(
                    "应用启动 3 秒后静默检查一次最新版本，无后台轮询，常驻 0% CPU",
                    "Checks GitHub Releases once silently 3s after launch; no background polling, 0% idle CPU",
                    in: lang
                )
            ) {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.autoCheckUpdate },
                        set: { v in app.updateConfig { $0.autoCheckUpdate = v } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("操作完成提示", "Completion Toast", in: lang)) {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.showCompletionToast },
                        set: { v in app.updateConfig { $0.showCompletionToast = v } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("下载源", "Repository", in: lang)) {
                HStack(spacing: 10) {
                    Text("github.com/\(UpdateChecker.releaseRepo)")
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(p.inkMono)
                    MagpieTextAction(L10n.tr("打开", "Open", in: lang)) {
                        NSWorkspace.shared.open(repoURL)
                    }
                }
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("配置目录", "Config Directory", in: lang)) {
                HStack(spacing: 6) {
                    Text(configDisplayPath)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(p.inkMono)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 340, alignment: .trailing)
                    MagpieCopyButton(value: configDirURL.path)
                    MagpieTextAction(L10n.tr("打开", "Open", in: lang)) {
                        try? FileManager.default.createDirectory(at: configDirURL, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(configDirURL)
                    }
                }
            }

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("默认保存目录", "Default Save Directory", in: lang)) {
                HStack(spacing: 6) {
                    Text(saveDisplayPath)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(p.inkMono)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 340, alignment: .trailing)
                    MagpieCopyButton(value: saveDirURL.path)
                    MagpieTextAction(L10n.tr("打开", "Open", in: lang)) {
                        try? FileManager.default.createDirectory(at: saveDirURL, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(saveDirURL)
                    }
                }
            }

            MagpieRowDivider()

            PinHistoryDirectoryRow(app: app)

            MagpieRowDivider()

            MagpieSettingRow(title: L10n.tr("开源协议", "License", in: lang)) {
                HStack(spacing: 10) {
                    Text("GPL-3.0-only")
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(p.inkMono)
                    MagpieTextAction(L10n.tr("查看", "View", in: lang)) {
                        NSWorkspace.shared.open(URL(string: "https://github.com/zzusec/isnip/blob/main/LICENSE")!)
                    }
                }
            }

            MagpieRowDivider()

            ProjectInfoRow()
        }
    }
}

// MARK: - Live Cross-Tab Search ("查找设置" / "Search settings")

private struct SettingsSearchResultsPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var lang
    @ObservedObject var app: AirSnipAppController
    let query: String
    @ObservedObject var updateState: SettingsUpdateState
    @Binding var recordingSlot: String?
    let onSelectTab: (SettingsTab) -> Void

    private struct SearchEntry: Identifiable {
        let id: String
        let keywords: String
        let render: () -> AnyView
    }

    private func matches(_ keywords: String) -> Bool {
        keywords.lowercased().contains(query.lowercased())
    }

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        let saveDirURL = OutputService.defaultSaveDirectoryURL(for: app.config)
        let configDirURL = app.configURL.deletingLastPathComponent()

        let allEntries: [SearchEntry] = [
            SearchEntry(id: "gen.autostart", keywords: "通用 general 开机自动启动 登录启动 launch at login autostart") {
                AnyView(MagpieSettingRow(title: L10n.tr("开机自动启动", "Launch at Login", in: lang), subtitle: SettingsTab.general.title(in: lang)) {
                    MagpieBooleanSwitch(isOn: Binding(
                        get: { app.config.autoStart },
                        set: { val in
                            _ = LaunchAtLoginManager.setEnabled(val)
                            app.updateConfig { $0.autoStart = val }
                        }
                    ))
                })
            },
            SearchEntry(id: "gen.lang", keywords: "通用 general 语言 英文 中文 language english chinese") {
                AnyView(MagpieSettingRow(title: L10n.tr("语言", "Language", in: lang), subtitle: SettingsTab.general.title(in: lang)) {
                    MagpieSegmentedPicker(
                        options: AppLanguage.allCases.map { ($0, $0.title(in: lang)) },
                        selection: Binding(
                            get: { app.config.language },
                            set: { l in app.updateConfig { $0.language = l } }
                        )
                    )
                })
            },
            SearchEntry(id: "gen.theme", keywords: "通用 general 外观 主题 深色 浅色 跟随系统 appearance theme dark light") {
                AnyView(MagpieSettingRow(title: L10n.tr("外观", "Appearance", in: lang), subtitle: SettingsTab.general.title(in: lang)) {
                    MagpieSegmentedPicker(
                        options: ThemeSetting.allCases.map { ($0, $0.title(in: lang)) },
                        selection: Binding(
                            get: { app.config.theme },
                            set: { t in
                                app.updateConfig { $0.theme = t }
                                app.settingsController?.refreshTheme()
                            }
                        )
                    )
                })
            },
            SearchEntry(id: "gen.scale", keywords: "通用 general 工具栏缩放 大小 比例 toolbar scale 100% 125% 150%") {
                AnyView(MagpieSettingRow(title: L10n.tr("工具栏缩放", "Toolbar Scale", in: lang), subtitle: SettingsTab.general.title(in: lang)) {
                    MagpieSegmentedPicker(
                        options: UiScaleSetting.allCases.map { ($0, $0.title(in: lang)) },
                        selection: Binding(
                            get: { app.config.uiScale },
                            set: { s in app.updateConfig { $0.uiScale = s } }
                        )
                    )
                })
            },
            SearchEntry(id: "gen.esc", keywords: "通用 general 有标注时按两次 Esc 退出 取消 确认 cancel escape") {
                AnyView(MagpieSettingRow(title: L10n.tr("有标注时按两次 Esc 退出", "Press Esc Twice to Cancel", in: lang), subtitle: SettingsTab.general.title(in: lang)) {
                    MagpieBooleanSwitch(isOn: Binding(
                        get: { app.config.confirmCancel },
                        set: { v in app.updateConfig { $0.confirmCancel = v } }
                    ))
                })
            },
            SearchEntry(id: "gen.toast", keywords: "通用 general 操作完成提示 toast notification 已复制 已保存") {
                AnyView(MagpieSettingRow(title: L10n.tr("操作完成提示", "Completion Toast", in: lang), subtitle: SettingsTab.general.title(in: lang)) {
                    MagpieBooleanSwitch(isOn: Binding(
                        get: { app.config.showCompletionToast },
                        set: { v in app.updateConfig { $0.showCompletionToast = v } }
                    ))
                })
            },
            SearchEntry(id: "gen.perm.screen", keywords: "通用 general 权限 屏幕录制 录屏 授权 screen recording permission") {
                AnyView(MagpieSettingRow(title: L10n.tr("屏幕录制权限", "Screen Recording", in: lang), subtitle: SettingsTab.general.title(in: lang)) {
                    MagpieTextAction(L10n.tr("前往查看", "Open General", in: lang)) { onSelectTab(.general) }
                })
            },
            SearchEntry(id: "gen.perm.ax", keywords: "通用 general 权限 辅助功能 授权 accessibility permission") {
                AnyView(MagpieSettingRow(title: L10n.tr("辅助功能权限", "Accessibility", in: lang), subtitle: SettingsTab.general.title(in: lang)) {
                    MagpieTextAction(L10n.tr("前往查看", "Open General", in: lang)) { onSelectTab(.general) }
                })
            },
            SearchEntry(id: "cap.compress", keywords: "截图 capture 智能无损压缩 pngquant oxipng png compression lossless") {
                AnyView(MagpieSettingRow(title: L10n.tr("智能无损压缩", "Smart Lossless Compression", in: lang), subtitle: SettingsTab.captureAndPin.title(in: lang)) {
                    MagpieBooleanSwitch(isOn: Binding(
                        get: { app.config.smartPngCompression },
                        set: { v in app.updateConfig { $0.smartPngCompression = v } }
                    ))
                })
            },
            SearchEntry(id: "cap.quality", keywords: "截图 capture 压缩档位 视觉无损 均衡 高压缩 compression level quality") {
                AnyView(MagpieSettingRow(title: L10n.tr("压缩档位", "Compression Level", in: lang), subtitle: SettingsTab.captureAndPin.title(in: lang)) {
                    MagpieSegmentedPicker(
                        options: PngCompressionQualityPreset.allCases.map { ($0, $0.title(in: lang)) },
                        selection: Binding(
                            get: { app.config.pngCompressionQuality },
                            set: { q in app.updateConfig { $0.pngCompressionQuality = q } }
                        )
                    )
                })
            },
            SearchEntry(id: "cap.clipcompress", keywords: "截图 capture 压缩剪贴板图片 复制 clipboard compress") {
                AnyView(MagpieSettingRow(title: L10n.tr("压缩剪贴板图片", "Compress Clipboard Images", in: lang), subtitle: SettingsTab.captureAndPin.title(in: lang)) {
                    MagpieBooleanSwitch(isOn: Binding(
                        get: { app.config.compressClipboardPng },
                        set: { v in app.updateConfig { $0.compressClipboardPng = v } }
                    ))
                })
            },
            SearchEntry(id: "cap.savedir", keywords: "截图 capture 保存位置 目录 路径 下载 save location directory downloads") {
                AnyView(MagpieSettingRow(title: L10n.tr("保存位置", "Save Location", in: lang), subtitle: SettingsTab.captureAndPin.title(in: lang)) {
                    HStack(spacing: 6) {
                        Text(OutputService.displayPath(for: saveDirURL))
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(p.inkMono)
                        MagpieTextAction(L10n.tr("更改…", "Change…", in: lang)) {
                            if let chosen = OutputService.chooseSaveDirectory(initial: saveDirURL) {
                                app.updateConfig { $0.lastSaveDirectory = chosen.path }
                            }
                        }
                    }
                })
            },
            SearchEntry(id: "cap.format", keywords: "截图 capture 默认格式 PNG JPEG WebP导出 default format") {
                AnyView(MagpieSettingRow(title: L10n.tr("默认格式", "Default Format", in: lang), subtitle: SettingsTab.captureAndPin.title(in: lang)) {
                    MagpieSegmentedPicker(
                        options: ExportImageFormat.allCases.map { ($0, $0.displayName) },
                        selection: Binding(
                            get: { app.config.lastSaveFormat },
                            set: { f in app.updateConfig { $0.lastSaveFormat = f } }
                        )
                    )
                })
            },
            SearchEntry(id: "cap.shadow", keywords: "截图 capture 窗体截图保留阴影 窗口 自动识别窗口 window shadow snap") {
                AnyView(MagpieSettingRow(title: L10n.tr("窗体截图保留阴影", "Keep Window Shadow", in: lang), subtitle: SettingsTab.captureAndPin.title(in: lang)) {
                    MagpieBooleanSwitch(isOn: Binding(
                        get: { app.config.windowCaptureShadow },
                        set: { v in app.updateConfig { $0.windowCaptureShadow = v } }
                    ))
                })
            },
            SearchEntry(id: "cap.longshot", keywords: "截图 capture 页面长截图 自动翻页 翻页速度 高度上限 scrolling longshot auto-scroll") {
                AnyView(MagpieSettingRow(title: L10n.tr("页面长截图自动翻页", "Auto-Scroll Longshot", in: lang), subtitle: SettingsTab.captureAndPin.title(in: lang)) {
                    MagpieBooleanSwitch(isOn: Binding(
                        get: { app.config.longshotAutoScroll },
                        set: { v in app.updateConfig { $0.longshotAutoScroll = v } }
                    ))
                })
            },
            SearchEntry(id: "cap.pin", keywords: "截图 capture 贴图 边框 初始位置 数量上限 pin border") {
                AnyView(MagpieSettingRow(title: L10n.tr("贴图显示边框", "Show Pin Border", in: lang), subtitle: SettingsTab.captureAndPin.title(in: lang)) {
                    MagpieBooleanSwitch(isOn: Binding(
                        get: { app.config.pinBorder },
                        set: { b in app.updateConfig { $0.pinBorder = b } }
                    ))
                })
            },
            SearchEntry(id: "tb.slots", keywords: "工具栏 toolbar 槽位 隐藏 显示 按钮 矩形 箭头 模糊 聚光灯 items") {
                AnyView(MagpieSettingRow(title: L10n.tr("悬浮工具栏槽位", "Floating Toolbar Items", in: lang), subtitle: SettingsTab.toolbar.title(in: lang)) {
                    MagpieTextAction(L10n.tr("打开工具栏设置", "Open Toolbar", in: lang), prominent: true) { onSelectTab(.toolbar) }
                })
            },
            SearchEntry(id: "hk.shot", keywords: "快捷键 shortcuts 热键 开始截图 ^A ⌃A screenshot hotkey") {
                AnyView(HotkeyRow(title: L10n.tr("开始截图", "Capture Area", in: lang), subtitle: SettingsTab.hotkeys.title(in: lang), slotID: "s.global.screenshot", binding: app.config.hotkeys.screenshot, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.screenshot = b }
                })
            },
            SearchEntry(id: "hk.win", keywords: "快捷键 shortcuts 热键 窗体截图 ^S ⌃S window hotkey") {
                AnyView(HotkeyRow(title: L10n.tr("独立窗体截图", "Capture Window", in: lang), subtitle: SettingsTab.hotkeys.title(in: lang), slotID: "s.global.window", binding: app.config.hotkeys.windowCapture, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.windowCapture = b }
                })
            },
            SearchEntry(id: "hk.ls", keywords: "快捷键 shortcuts 热键 页面长截图 ^D ⌃D longshot hotkey") {
                AnyView(HotkeyRow(title: L10n.tr("页面长截图", "Scrolling Capture", in: lang), subtitle: SettingsTab.hotkeys.title(in: lang), slotID: "s.global.ls", binding: app.config.hotkeys.longshotCapture, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.longshotCapture = b }
                })
            },
            SearchEntry(id: "hk.ocr", keywords: "快捷键 shortcuts 热键 截图识字 ^F ⌃F ocr hotkey") {
                AnyView(HotkeyRow(title: L10n.tr("截图识字", "Capture & OCR", in: lang), subtitle: SettingsTab.hotkeys.title(in: lang), slotID: "s.global.ocr", binding: app.config.hotkeys.ocrCapture, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.ocrCapture = b }
                })
            },
            SearchEntry(id: "hk.trans", keywords: "快捷键 shortcuts 热键 划词翻译 截图翻译 translate selection Option D S") {
                AnyView(HotkeyRow(title: L10n.tr("划词翻译", "Translate Selection", in: lang), subtitle: SettingsTab.hotkeys.title(in: lang), slotID: "s.global.trans", binding: app.config.hotkeys.translateSelection, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.translateSelection = b }
                })
            },
            SearchEntry(id: "ed.style", keywords: "标注 annotation 线宽 模糊强度 字号 填充 调色板 颜色 stroke blur font color") {
                AnyView(MagpieSettingRow(title: L10n.tr("标注默认样式与颜色", "Annotation Style & Colors", in: lang), subtitle: SettingsTab.editor.title(in: lang)) {
                    MagpieTextAction(L10n.tr("打开标注设置", "Open Annotation", in: lang), prominent: true) { onSelectTab(.editor) }
                })
            },
            SearchEntry(id: "ocr.lang", keywords: "OCR 与翻译 识别语言 中文 英文 日语 韩语 离线识字 recognition language") {
                AnyView(MagpieSettingRow(title: L10n.tr("识别语言", "Recognition Language", in: lang), subtitle: SettingsTab.ocr.title(in: lang)) {
                    MagpieMenuPicker(
                        L10n.tr("识别语言", "Recognition Language", in: lang),
                        options: OcrConfig.supportedOptions(in: lang).map { ($0.tag, $0.label) },
                        selection: Binding(
                            get: { app.config.ocr.language },
                            set: { l in app.updateConfig { $0.ocr.language = l } }
                        )
                    )
                })
            },
            SearchEntry(id: "ocr.qr", keywords: "OCR 与翻译 二维码 条码 自动复制 合并换行 qr barcode") {
                AnyView(MagpieSettingRow(title: L10n.tr("识别二维码与条码", "Detect QR & Barcodes", in: lang), subtitle: SettingsTab.ocr.title(in: lang)) {
                    MagpieBooleanSwitch(isOn: Binding(
                        get: { app.config.ocr.detectBarcodes },
                        set: { db in app.updateConfig { $0.ocr.detectBarcodes = db } }
                    ))
                })
            },
            SearchEntry(id: "ocr.selbtn", keywords: "OCR 与翻译 划词后显示翻译按钮 目标语言 翻译 floating translate button") {
                AnyView(MagpieSettingRow(title: L10n.tr("划词后显示翻译按钮", "Show Floating Translate Button", in: lang), subtitle: SettingsTab.ocr.title(in: lang)) {
                    MagpieBooleanSwitch(isOn: Binding(
                        get: { app.config.translation.showSelectionButton },
                        set: { enabled in app.updateConfig { $0.translation.showSelectionButton = enabled } }
                    ))
                })
            },
            SearchEntry(id: "ab.ver", keywords: "关于 about 版本 更新 检查更新 自动更新 version update") {
                AnyView(UpdateVersionRow(updateState: updateState, idleSubtitle: SettingsTab.about.title(in: lang)))
            },
            SearchEntry(id: "ab.cfg", keywords: "关于 about 配置目录 config.json 路径 协议 github directory license") {
                AnyView(MagpieSettingRow(title: L10n.tr("配置目录", "Config Directory", in: lang), subtitle: SettingsTab.about.title(in: lang)) {
                    HStack(spacing: 6) {
                        Text(OutputService.displayPath(for: configDirURL))
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(p.inkMono)
                        MagpieCopyButton(value: configDirURL.path)
                        MagpieTextAction(L10n.tr("打开", "Open", in: lang)) { NSWorkspace.shared.open(configDirURL) }
                    }
                })
            },
            SearchEntry(id: "ab.pin-history", keywords: "关于 贴图历史目录 存储路径 恢复缓存 about pin history directory storage cache") {
                AnyView(PinHistoryDirectoryRow(app: app, subtitle: SettingsTab.about.title(in: lang)))
            },
            SearchEntry(id: "ab.project", keywords: "关于 项目说明 原项目 二次开发 维护 about project info original project maintenance zzusec/isnip") {
                AnyView(ProjectInfoRow())
            }
        ]

        let matched = allEntries.filter { matches($0.keywords) }

        MagpieCard {
            if matched.isEmpty {
                VStack(spacing: 6) {
                    Text(L10n.tr("未找到与「\(query)」匹配的设置项", "No settings matching \"\(query)\"", in: lang))
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(p.inkPrimary)
                    Text(L10n.tr(
                        "请尝试输入关键词，如：压缩、阴影、长截图、翻译、快捷键、配置目录",
                        "Try keywords like: compression, shadow, longshot, translate, shortcuts, config",
                        in: lang
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(p.inkSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 42)
            } else {
                ForEach(Array(matched.enumerated()), id: \.element.id) { idx, item in
                    if idx > 0 {
                        MagpieRowDivider()
                    }
                    item.render()
                }
            }
        }
    }
}
