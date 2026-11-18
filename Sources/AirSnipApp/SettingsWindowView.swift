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

    var title: String {
        switch self {
        case .general: return "通用"
        case .captureAndPin: return "截图"
        case .toolbar: return "工具栏"
        case .hotkeys: return "快捷键"
        case .editor: return "标注"
        case .ocr: return "OCR 与翻译"
        case .about: return "关于"
        }
    }
}

@MainActor
final class SettingsUpdateState: ObservableObject {
    @Published var isChecking = false
    @Published var statusText = ""
    @Published var latestRelease: UpdateReleaseInfo?

    func checkNow(showToast: Bool = false) {
        guard !isChecking else { return }
        isChecking = true
        statusText = "正在检查更新…"
        Task { @MainActor in
            let res = await UpdateChecker.checkLatest()
            isChecking = false
            switch res {
            case .success(let info?):
                latestRelease = info
                statusText = "\(info.version) 可更新"
                if showToast {
                    ToastHUD.show("发现新版本 v\(info.version)", symbol: "arrow.down.circle")
                }
            case .success(nil):
                latestRelease = nil
                statusText = "已是最新版本"
                if showToast {
                    ToastHUD.show("已是最新版本 v\(UpdateChecker.currentVersion)", symbol: "checkmark")
                }
            case .failure(let err):
                statusText = "检查失败：\(err.localizedDescription)"
                if showToast {
                    ToastHUD.show("检查更新失败", symbol: "exclamationmark.circle")
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
    @State private var showQuickActionsBar: Bool = true
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

    private var trimmedSearch: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runScreenAction(_ work: @escaping @MainActor () -> Void) {
        app.settingsController?.hide()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 170_000_000)
            work()
        }
    }

    public var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)

        VStack(spacing: 0) {
            // Row 1: Unified Magpie Header Bar (Traffic Lights + Toggle + Brand + Quick Actions + Refresh/Settings)
            HStack(spacing: 0) {
                HStack(spacing: 10) {
                    HeaderIconButton(
                        symbol: "sidebar.left",
                        isActive: false,
                        helpText: showQuickActionsBar ? "切换为精简顶栏" : "展开顶部快捷功能栏"
                    ) {
                        withAnimation(.easeOut(duration: 0.16)) {
                            showQuickActionsBar.toggle()
                        }
                    }

                    HStack(spacing: 7) {
                        MagpieBrandMark(size: 17)
                        Text("iSnip")
                            .font(.system(size: 14.5, weight: .bold))
                            .foregroundStyle(p.inkPrimary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(.leading, 78)

                if showQuickActionsBar {
                    HStack(spacing: 4) {
                        TopQuickNavButton(title: "截图", tip: "开始区域截图 (\(app.config.hotkeys.screenshot.displayString))") {
                            runScreenAction { app.triggerCapture() }
                        }
                        TopQuickNavButton(title: "窗体", tip: "独立窗体截图 (\(app.config.hotkeys.windowCapture.displayString))") {
                            runScreenAction { app.triggerDirectWindowCapture() }
                        }
                        TopQuickNavButton(title: "长截图", tip: "页面长截图 (\(app.config.hotkeys.longshotCapture.displayString))") {
                            runScreenAction { app.triggerDirectLongshotCapture() }
                        }
                        TopQuickNavButton(title: "识字", tip: "框选文字识别 (\(app.config.hotkeys.ocrCapture.displayString))") {
                            runScreenAction { app.triggerDirectOCRCapture() }
                        }
                        TopQuickNavButton(title: "翻译", tip: "框选截图翻译 (\(app.config.hotkeys.translateCapture.displayString))") {
                            runScreenAction { app.triggerOCRTranslation() }
                        }
                        TopQuickNavButton(title: "贴图", tip: "从剪贴板置顶贴图 (\(app.config.hotkeys.pin.displayString))") {
                            app.triggerGlobalPinFromClipboard()
                        }
                        TopQuickNavButton(title: "图片识字", tip: "选择本地图片文件识别文字") {
                            app.triggerOCRFromFile()
                        }
                    }
                    .padding(.leading, 22)
                    .transition(.opacity)
                }

                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    HeaderIconButton(
                        symbol: "arrow.clockwise",
                        isActive: false,
                        spinning: updateState.isChecking,
                        helpText: "检查更新"
                    ) {
                        updateState.checkNow(showToast: selectedTab != .about)
                    }

                    HeaderIconButton(
                        symbol: "gearshape",
                        isActive: true,
                        helpText: "设置"
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

            // Row 2: Secondary Category Pill Tabs + Search Input ("查找设置")
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    ForEach(SettingsTab.allCases) { tab in
                        SubTabPillButton(
                            title: tab.title,
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

                SettingsSearchField(text: $searchQuery)
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
                            ToolbarVisibilityPane(app: app)
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
        .frame(minWidth: 760, idealWidth: 880, maxWidth: .infinity, minHeight: 500, idealHeight: 640, maxHeight: .infinity)
        .background(p.canvasBg)
        .ignoresSafeArea(.container, edges: .top)
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

private struct TopQuickNavButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let tip: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isHovered ? p.inkPrimary : p.inkSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .fill(isHovered ? p.navHoverPill : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tip)
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
    @FocusState private var isFocused: Bool

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        HStack(spacing: 6) {
            TextField("", text: $text, prompt: Text("查找设置").foregroundStyle(p.inkTertiary))
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
                .help("清空搜索")
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

// MARK: - 1. General (通用)

private struct GeneralSettingsPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var app: AirSnipAppController
    @State private var hasScreenCapture = ScreenCaptureService.hasScreenCapturePermission()
    @State private var hasAccessibility = AccessibilityService.hasPermission()

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)

        MagpieCard {
            MagpieSettingRow(title: "开机自动启动") {
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

            MagpieSettingRow(title: "外观") {
                MagpieSegmentedPicker(
                    options: ThemeSetting.allCases.map { ($0, $0.title) },
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

            MagpieSettingRow(title: "工具栏缩放") {
                MagpieSegmentedPicker(
                    options: UiScaleSetting.allCases.map { ($0, $0.title) },
                    selection: Binding(
                        get: { app.config.uiScale },
                        set: { s in app.updateConfig { $0.uiScale = s } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(
                title: "有标注时按两次 Esc 退出",
                infoTip: "开启后，画布上已有标注对象时首次按 Esc 仅显示确认提示，防止误触丢失内容"
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
                title: "操作完成提示",
                infoTip: "截图复制或保存完成后，在屏幕顶部短暂展示轻量化确认卡片"
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
                title: "屏幕录制权限",
                subtitle: hasScreenCapture ? nil : "截图、独立窗体捕获与页面长截图依赖此系统授权"
            ) {
                if hasScreenCapture {
                    HStack(spacing: 10) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(p.statusOk)
                                .frame(width: 6, height: 6)
                            Text("已授权")
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(p.inkMono)
                        }
                        MagpieTextAction("打开设置") {
                            ScreenCaptureService.openScreenCaptureSystemSettings()
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        Text("未授权")
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(p.statusWarn)
                        MagpieTextAction("打开设置", prominent: true) {
                            ScreenCaptureService.openScreenCaptureSystemSettings()
                        }
                        MagpieTextAction("重置权限") {
                            ScreenCaptureService.resetScreenCapturePermissionAndRelaunch()
                        }
                    }
                }
            }

            MagpieRowDivider()

            MagpieSettingRow(
                title: "辅助功能权限",
                infoTip: "仅用于页面长截图自动平滑滚轮与划词翻译读取公开选中文本"
            ) {
                if hasAccessibility {
                    HStack(spacing: 10) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(p.statusOk)
                                .frame(width: 6, height: 6)
                            Text("已授权")
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(p.inkMono)
                        }
                        MagpieTextAction("打开设置") {
                            AccessibilityService.openSystemSettings()
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        Text("未授权")
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(p.inkSecondary)
                        MagpieTextAction("授权", prominent: true) {
                            _ = AccessibilityService.requestPermissionPrompt()
                            hasAccessibility = AccessibilityService.hasPermission()
                        }
                        MagpieTextAction("打开设置") {
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

// MARK: - 2. Capture, Compression & Pin (截图)

private struct CaptureAndPinPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var app: AirSnipAppController

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        let saveDirURL = OutputService.defaultSaveDirectoryURL(for: app.config)
        let saveDisplayPath = OutputService.displayPath(for: saveDirURL)

        MagpieCard {
            MagpieSettingRow(
                title: "智能无损压缩",
                infoTip: "内置 pngquant + oxipng 双引擎管线，瞬时输出后后台原子精压，体积可缩减 60%–75%"
            ) {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.smartPngCompression },
                        set: { v in app.updateConfig { $0.smartPngCompression = v } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: "压缩档位") {
                MagpieSegmentedPicker(
                    options: PngCompressionQualityPreset.allCases.map { ($0, $0.title) },
                    selection: Binding(
                        get: { app.config.pngCompressionQuality },
                        set: { q in app.updateConfig { $0.pngCompressionQuality = q } }
                    )
                )
                .disabled(!app.config.smartPngCompression)
            }

            MagpieRowDivider()

            MagpieSettingRow(title: "压缩剪贴板图片") {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.compressClipboardPng },
                        set: { v in app.updateConfig { $0.compressClipboardPng = v } }
                    )
                )
                .disabled(!app.config.smartPngCompression)
            }

            MagpieRowDivider()

            MagpieSettingRow(title: "保存位置") {
                HStack(spacing: 6) {
                    Text(saveDisplayPath)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(p.inkMono)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 260, alignment: .trailing)

                    MagpieCopyButton(value: saveDirURL.path, helpText: "复制目录路径")

                    MagpieTextAction("打开") {
                        try? FileManager.default.createDirectory(at: saveDirURL, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(saveDirURL)
                    }

                    MagpieTextAction("更改…") {
                        if let chosen = OutputService.chooseSaveDirectory(initial: saveDirURL) {
                            app.updateConfig { $0.lastSaveDirectory = chosen.path }
                        }
                    }
                }
            }

            MagpieRowDivider()

            MagpieSettingRow(title: "每次询问保存位置") {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.askBeforeSave },
                        set: { v in app.updateConfig { $0.askBeforeSave = v } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: "默认格式") {
                MagpieSegmentedPicker(
                    options: ExportImageFormat.allCases.map { ($0, $0.displayName) },
                    selection: Binding(
                        get: { app.config.lastSaveFormat },
                        set: { f in app.updateConfig { $0.lastSaveFormat = f } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: "文件命名") {
                MagpieSegmentedPicker(
                    options: NameStyle.allCases.map { ($0, $0.title) },
                    selection: Binding(
                        get: { app.config.nameStyle },
                        set: { s in app.updateConfig { $0.nameStyle = s } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: "自动识别窗口") {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.windowSnap },
                        set: { v in app.updateConfig { $0.windowSnap = v } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(
                title: "窗体截图保留阴影",
                infoTip: "窗体截图模式下按住 Option 点击窗口可临时切换无阴影"
            ) {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.windowCaptureShadow },
                        set: { v in app.updateConfig { $0.windowCaptureShadow = v } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: "页面长截图自动翻页") {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.longshotAutoScroll },
                        set: { v in app.updateConfig { $0.longshotAutoScroll = v } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: "长截图翻页速度") {
                MagpieSegmentedPicker(
                    options: LongshotScrollSpeed.allCases.map { ($0, $0.title) },
                    selection: Binding(
                        get: { app.config.longshotScrollSpeed },
                        set: { s in app.updateConfig { $0.longshotScrollSpeed = s } }
                    )
                )
                .disabled(!app.config.longshotAutoScroll)
            }

            MagpieRowDivider()

            MagpieSettingRow(title: "长截图高度上限") {
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

            MagpieSettingRow(title: "贴图初始位置") {
                MagpieSegmentedPicker(
                    options: PinPosition.allCases.map { ($0, $0.title) },
                    selection: Binding(
                        get: { app.config.pinPosition },
                        set: { pos in app.updateConfig { $0.pinPosition = pos } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: "贴图显示边框") {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.pinBorder },
                        set: { b in app.updateConfig { $0.pinBorder = b } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: "贴图数量上限") {
                MagpieStepperPill(
                    displayValue: "\(app.config.pinMaxCount) 张",
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
        }
    }
}

// MARK: - 3. Toolbar Visibility (工具栏)

private struct ToolbarVisibilityPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var app: AirSnipAppController
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        let totalSlots = ToolbarSlot.allOrdered.count
        let visibleSlots = ToolbarSlot.allOrdered.filter { app.config.toolbar.isVisible($0) }.count

        MagpieCard {
            MagpieSettingRow(
                title: "悬浮工具栏槽位",
                subtitle: "当前显示 \(visibleSlots) / \(totalSlots) 项"
            ) {
                MagpieTextAction("全部显示", prominent: visibleSlots < totalSlots) {
                    app.updateConfig { $0.toolbar.hidden.removeAll() }
                }
                .disabled(visibleSlots == totalSlots)
            }

            ForEach(ToolbarGroup.allCases, id: \.rawValue) { group in
                let state = app.config.toolbar.groupState(group)
                MagpieRowDivider()

                VStack(alignment: .leading, spacing: 11) {
                    HStack(alignment: .center) {
                        Text(group.title)
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
                            offLabel: "全隐",
                            onLabel: "显示"
                        )
                    }

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 7) {
                        ForEach(group.slots, id: \.key) { slot in
                            ToolbarSlotChip(
                                label: slot.label,
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

// MARK: - 4. Hotkeys (快捷键)

private struct HotkeysSettingsPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var app: AirSnipAppController
    @Binding var recordingSlot: String?

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        let conflicts = app.config.hotkeyConflicts() + app.hotkeyRegistrationErrors

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
                    title: "快捷键绑定",
                    subtitle: "点击右侧键位录制新组合键或鼠标中键/侧键，按 Esc 取消录制"
                ) {
                    MagpieTextAction("恢复默认") {
                        recordingSlot = nil
                        app.updateConfig {
                            $0.hotkeys = HotkeyConfig()
                            $0.toolKeys = ToolKeysConfig()
                        }
                    }
                }

                MagpieRowDivider()
                MagpieSectionGroupRow(title: "全局热键", trailingText: "系统级常驻响应")

                MagpieRowDivider()
                HotkeyRow(title: "开始截图", slotID: "global.screenshot", binding: app.config.hotkeys.screenshot, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.screenshot = b }
                }
                MagpieRowDivider()
                HotkeyRow(title: "独立窗体截图", slotID: "global.windowCapture", binding: app.config.hotkeys.windowCapture, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.windowCapture = b }
                }
                MagpieRowDivider()
                HotkeyRow(title: "页面长截图", slotID: "global.longshotCapture", binding: app.config.hotkeys.longshotCapture, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.longshotCapture = b }
                }
                MagpieRowDivider()
                HotkeyRow(title: "截图识字", slotID: "global.ocrCapture", binding: app.config.hotkeys.ocrCapture, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.ocrCapture = b }
                }
                MagpieRowDivider()
                HotkeyRow(title: "划词翻译", slotID: "global.translateSelection", binding: app.config.hotkeys.translateSelection, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.translateSelection = b }
                }
                MagpieRowDivider()
                HotkeyRow(title: "截图翻译", slotID: "global.translateCapture", binding: app.config.hotkeys.translateCapture, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.translateCapture = b }
                }
                MagpieRowDivider()
                HotkeyRow(title: "剪贴板贴图", slotID: "global.pin", binding: app.config.hotkeys.pin, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.pin = b }
                }
                MagpieRowDivider()
                HotkeyRow(title: "切换贴图边框", slotID: "global.pinBorder", binding: app.config.hotkeys.pinBorderToggle, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.pinBorderToggle = b }
                }

                MagpieRowDivider()
                MagpieSectionGroupRow(title: "截图会话内", trailingText: "框选期间生效")

                MagpieRowDivider()
                HotkeyRow(title: "重新抓屏", slotID: "ov.recapture", binding: app.config.hotkeys.recapture, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.recapture = b }
                }
                MagpieRowDivider()
                HotkeyRow(title: "进入长截图", slotID: "ov.longshot", binding: app.config.hotkeys.longshot, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.longshot = b }
                }
                MagpieRowDivider()
                HotkeyRow(title: "选区 OCR 识字", slotID: "ov.ocr", binding: app.config.hotkeys.ocr, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.ocr = b }
                }

                MagpieRowDivider()
                MagpieSectionGroupRow(title: "标注工具切换", trailingText: "默认数字键 1–0")

                ForEach(AnnotationTool.allOrdered, id: \.rawValue) { tool in
                    MagpieRowDivider()
                    HotkeyRow(
                        title: tool.shortLabel,
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
                    Text(isRecording ? "按下快捷键…" : binding.displayString)
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
                    .help("清除快捷键")
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

// MARK: - 5. Editor Defaults (标注)

private struct EditorDefaultsPane: View {
    @Environment(\.colorScheme) private var colorScheme
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
            MagpieSettingRow(title: "线宽") {
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

            MagpieSettingRow(title: "模糊强度") {
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

            MagpieSettingRow(title: "默认字号") {
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

            MagpieSettingRow(title: "实心填充") {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.defaultFillEnabled },
                        set: { v in app.updateConfig { $0.defaultFillEnabled = v } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: "预设调色板", subtitle: "选中色槽后可通过右侧取色器自定义对应预设色") {
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

            MagpieSettingRow(title: "标注样式预览") {
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

                        Text("Aa 预览")
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

                    MagpieTextAction("恢复默认") {
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
        }
    }
}

// MARK: - 6. OCR & Translation (OCR 与翻译)

private struct OCRSettingsPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var app: AirSnipAppController

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)

        MagpieCard {
            MagpieSettingRow(
                title: "识别语言",
                infoTip: "基于端侧 Apple Vision 离线文字识别，全程不上传网络"
            ) {
                MagpieMenuPicker(
                    "识别语言",
                    options: OcrConfig.supportedOptions.map { ($0.tag, $0.label) },
                    selection: Binding(
                        get: { app.config.ocr.language },
                        set: { lang in app.updateConfig { $0.ocr.language = lang } }
                    ),
                    minWidth: 124
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: "自动复制识别结果") {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.ocr.autoCopy },
                        set: { ac in app.updateConfig { $0.ocr.autoCopy = ac } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: "合并段落换行") {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.ocr.mergeLineBreaks },
                        set: { mb in app.updateConfig { $0.ocr.mergeLineBreaks = mb } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: "识别二维码与条码") {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.ocr.detectBarcodes },
                        set: { db in app.updateConfig { $0.ocr.detectBarcodes = db } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: "快捷文字识别") {
                HStack(spacing: 6) {
                    Button("框选识字") {
                        app.settingsController?.hide()
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 180_000_000)
                            app.triggerDirectOCRCapture()
                        }
                    }
                    .buttonStyle(MagpiePillButtonStyle(role: .bordered, compact: true))

                    Button("剪贴板识字") {
                        app.triggerOCRFromClipboard()
                    }
                    .buttonStyle(MagpiePillButtonStyle(role: .bordered, compact: true))

                    Button("选择图片…") {
                        app.triggerOCRFromFile()
                    }
                    .buttonStyle(MagpiePillButtonStyle(role: .bordered, compact: true))
                }
            }

            MagpieRowDivider()

            MagpieSettingRow(
                title: "翻译目标语言",
                subtitle: "使用 macOS 15+ 系统 Translation 框架，无需配置 API Key"
            ) {
                MagpieMenuPicker(
                    "目标语言",
                    options: TranslationConfig.languageOptions.map { ($0.tag, $0.label) },
                    selection: Binding(
                        get: { app.config.translation.targetLanguage },
                        set: { language in app.updateConfig { $0.translation.targetLanguage = language } }
                    ),
                    minWidth: 124
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(
                title: "划词后显示翻译按钮",
                subtitle: "仅读取应用公开选中文字，不模拟复制或改写剪贴板；无法取词处请用截图翻译",
                infoTip: "需要辅助功能权限"
            ) {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.translation.showSelectionButton },
                        set: { enabled in app.updateConfig { $0.translation.showSelectionButton = enabled } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(
                title: "快捷翻译入口",
                subtitle: "划词翻译 \(app.config.hotkeys.translateSelection.displayString)  ·  截图翻译 \(app.config.hotkeys.translateCapture.displayString)"
            ) {
                HStack(spacing: 10) {
                    Text("\(app.config.hotkeys.translateSelection.displayString) / \(app.config.hotkeys.translateCapture.displayString)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(p.inkMono)

                    Button("截图翻译") {
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

// MARK: - 7. About (关于 — Direct Homage to Reference Layout)

private struct AboutSettingsPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var app: AirSnipAppController
    @ObservedObject var updateState: SettingsUpdateState

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        let configDirURL = app.configURL.deletingLastPathComponent()
        let configDisplayPath = OutputService.displayPath(for: configDirURL)
        let saveDirURL = OutputService.defaultSaveDirectoryURL(for: app.config)
        let saveDisplayPath = OutputService.displayPath(for: saveDirURL)
        let repoURL = URL(string: "https://github.com/zzusec/isnip")!
        let releasesURL = URL(string: "https://github.com/zzusec/isnip/releases")!

        MagpieCard {
            MagpieSettingRow(
                title: "版本",
                subtitle: updateState.statusText.isEmpty ? nil : updateState.statusText
            ) {
                HStack(spacing: 12) {
                    Text(UpdateChecker.currentVersion)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(p.inkMono)

                    if let rel = updateState.latestRelease {
                        MagpieTextAction("下载 v\(rel.version)", prominent: true) {
                            NSWorkspace.shared.open(rel.downloadURL ?? rel.htmlURL)
                        }
                    } else {
                        MagpieTextAction(updateState.isChecking ? "检查中…" : "检查更新") {
                            updateState.checkNow()
                        }
                        .disabled(updateState.isChecking)
                    }
                }
            }

            MagpieRowDivider()

            MagpieSettingRow(title: "更新内容") {
                MagpieTextAction("打开") {
                    NSWorkspace.shared.open(releasesURL)
                }
            }

            MagpieRowDivider()

            MagpieSettingRow(
                title: "自动更新检查",
                infoTip: "应用启动 3 秒后静默检查一次最新版本，无后台轮询，常驻 0% CPU"
            ) {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.autoCheckUpdate },
                        set: { v in app.updateConfig { $0.autoCheckUpdate = v } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: "操作完成提示") {
                MagpieBooleanSwitch(
                    isOn: Binding(
                        get: { app.config.showCompletionToast },
                        set: { v in app.updateConfig { $0.showCompletionToast = v } }
                    )
                )
            }

            MagpieRowDivider()

            MagpieSettingRow(title: "下载源") {
                HStack(spacing: 10) {
                    Text("github.com/zzusec/isnip")
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(p.inkMono)
                    MagpieTextAction("打开") {
                        NSWorkspace.shared.open(repoURL)
                    }
                }
            }

            MagpieRowDivider()

            MagpieSettingRow(title: "配置目录") {
                HStack(spacing: 6) {
                    Text(configDisplayPath)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(p.inkMono)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 340, alignment: .trailing)
                    MagpieCopyButton(value: configDirURL.path, helpText: "复制配置目录路径")
                    MagpieTextAction("打开") {
                        try? FileManager.default.createDirectory(at: configDirURL, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(configDirURL)
                    }
                }
            }

            MagpieRowDivider()

            MagpieSettingRow(title: "默认保存目录") {
                HStack(spacing: 6) {
                    Text(saveDisplayPath)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(p.inkMono)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 340, alignment: .trailing)
                    MagpieCopyButton(value: saveDirURL.path, helpText: "复制保存目录路径")
                    MagpieTextAction("打开") {
                        try? FileManager.default.createDirectory(at: saveDirURL, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(saveDirURL)
                    }
                }
            }

            MagpieRowDivider()

            MagpieSettingRow(title: "开源协议") {
                HStack(spacing: 10) {
                    Text("GPL-3.0-only")
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(p.inkMono)
                    MagpieTextAction("查看") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/zzusec/isnip/blob/main/LICENSE")!)
                    }
                }
            }
        }
    }
}

// MARK: - Live Cross-Tab Search ("查找设置")

private struct SettingsSearchResultsPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var app: AirSnipAppController
    let query: String
    @ObservedObject var updateState: SettingsUpdateState
    @Binding var recordingSlot: String?
    let onSelectTab: (SettingsTab) -> Void

    private struct SearchEntry: Identifiable {
        let id: String
        let tab: SettingsTab
        let keywords: String
        let render: () -> AnyView
    }

    private func matches(_ keywords: String) -> Bool {
        let needle = query.lowercased()
        return keywords.lowercased().contains(needle)
    }

    var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        let saveDirURL = OutputService.defaultSaveDirectoryURL(for: app.config)
        let configDirURL = app.configURL.deletingLastPathComponent()

        let allEntries: [SearchEntry] = [
            SearchEntry(id: "gen.autostart", tab: .general, keywords: "通用 开机自动启动 登录启动 autostart launch") {
                AnyView(MagpieSettingRow(title: "开机自动启动", subtitle: "通用") {
                    MagpieBooleanSwitch(isOn: Binding(
                        get: { app.config.autoStart },
                        set: { val in
                            _ = LaunchAtLoginManager.setEnabled(val)
                            app.updateConfig { $0.autoStart = val }
                        }
                    ))
                })
            },
            SearchEntry(id: "gen.theme", tab: .general, keywords: "通用 外观 主题 深色 浅色 跟随系统 theme dark light") {
                AnyView(MagpieSettingRow(title: "外观", subtitle: "通用") {
                    MagpieSegmentedPicker(
                        options: ThemeSetting.allCases.map { ($0, $0.title) },
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
            SearchEntry(id: "gen.scale", tab: .general, keywords: "通用 工具栏缩放 大小 比例 scale 100% 125% 150%") {
                AnyView(MagpieSettingRow(title: "工具栏缩放", subtitle: "通用") {
                    MagpieSegmentedPicker(
                        options: UiScaleSetting.allCases.map { ($0, $0.title) },
                        selection: Binding(
                            get: { app.config.uiScale },
                            set: { s in app.updateConfig { $0.uiScale = s } }
                        )
                    )
                })
            },
            SearchEntry(id: "gen.esc", tab: .general, keywords: "通用 有标注时按两次 Esc 退出 取消 确认") {
                AnyView(MagpieSettingRow(title: "有标注时按两次 Esc 退出", subtitle: "通用") {
                    MagpieBooleanSwitch(isOn: Binding(
                        get: { app.config.confirmCancel },
                        set: { v in app.updateConfig { $0.confirmCancel = v } }
                    ))
                })
            },
            SearchEntry(id: "gen.toast", tab: .general, keywords: "通用 操作完成提示 toast 通知 已复制 已保存") {
                AnyView(MagpieSettingRow(title: "操作完成提示", subtitle: "通用") {
                    MagpieBooleanSwitch(isOn: Binding(
                        get: { app.config.showCompletionToast },
                        set: { v in app.updateConfig { $0.showCompletionToast = v } }
                    ))
                })
            },
            SearchEntry(id: "gen.perm.screen", tab: .general, keywords: "通用 权限 屏幕录制 录屏 授权 重置权限") {
                AnyView(MagpieSettingRow(title: "屏幕录制权限", subtitle: "通用") {
                    MagpieTextAction("前往通用查看") { onSelectTab(.general) }
                })
            },
            SearchEntry(id: "gen.perm.ax", tab: .general, keywords: "通用 权限 辅助功能 授权 长截图 划词") {
                AnyView(MagpieSettingRow(title: "辅助功能权限", subtitle: "通用") {
                    MagpieTextAction("前往通用查看") { onSelectTab(.general) }
                })
            },
            SearchEntry(id: "cap.compress", tab: .captureAndPin, keywords: "截图 智能无损压缩 pngquant oxipng png 体积") {
                AnyView(MagpieSettingRow(title: "智能无损压缩", subtitle: "截图") {
                    MagpieBooleanSwitch(isOn: Binding(
                        get: { app.config.smartPngCompression },
                        set: { v in app.updateConfig { $0.smartPngCompression = v } }
                    ))
                })
            },
            SearchEntry(id: "cap.quality", tab: .captureAndPin, keywords: "截图 压缩档位 视觉无损 均衡 高压缩") {
                AnyView(MagpieSettingRow(title: "压缩档位", subtitle: "截图") {
                    MagpieSegmentedPicker(
                        options: PngCompressionQualityPreset.allCases.map { ($0, $0.title) },
                        selection: Binding(
                            get: { app.config.pngCompressionQuality },
                            set: { q in app.updateConfig { $0.pngCompressionQuality = q } }
                        )
                    )
                })
            },
            SearchEntry(id: "cap.clipcompress", tab: .captureAndPin, keywords: "截图 压缩剪贴板图片 复制") {
                AnyView(MagpieSettingRow(title: "压缩剪贴板图片", subtitle: "截图") {
                    MagpieBooleanSwitch(isOn: Binding(
                        get: { app.config.compressClipboardPng },
                        set: { v in app.updateConfig { $0.compressClipboardPng = v } }
                    ))
                })
            },
            SearchEntry(id: "cap.savedir", tab: .captureAndPin, keywords: "截图 保存位置 目录 路径 下载 downloads") {
                AnyView(MagpieSettingRow(title: "保存位置", subtitle: "截图") {
                    HStack(spacing: 6) {
                        Text(OutputService.displayPath(for: saveDirURL))
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(p.inkMono)
                        MagpieTextAction("更改…") {
                            if let chosen = OutputService.chooseSaveDirectory(initial: saveDirURL) {
                                app.updateConfig { $0.lastSaveDirectory = chosen.path }
                            }
                        }
                    }
                })
            },
            SearchEntry(id: "cap.format", tab: .captureAndPin, keywords: "截图 默认格式 PNG JPEG WebP 导出") {
                AnyView(MagpieSettingRow(title: "默认格式", subtitle: "截图") {
                    MagpieSegmentedPicker(
                        options: ExportImageFormat.allCases.map { ($0, $0.displayName) },
                        selection: Binding(
                            get: { app.config.lastSaveFormat },
                            set: { f in app.updateConfig { $0.lastSaveFormat = f } }
                        )
                    )
                })
            },
            SearchEntry(id: "cap.shadow", tab: .captureAndPin, keywords: "截图 窗体截图保留阴影 窗口 自动识别窗口") {
                AnyView(MagpieSettingRow(title: "窗体截图保留阴影", subtitle: "截图") {
                    MagpieBooleanSwitch(isOn: Binding(
                        get: { app.config.windowCaptureShadow },
                        set: { v in app.updateConfig { $0.windowCaptureShadow = v } }
                    ))
                })
            },
            SearchEntry(id: "cap.longshot", tab: .captureAndPin, keywords: "截图 页面长截图 自动翻页 翻页速度 高度上限 滚动拼接") {
                AnyView(MagpieSettingRow(title: "页面长截图自动翻页", subtitle: "截图") {
                    MagpieBooleanSwitch(isOn: Binding(
                        get: { app.config.longshotAutoScroll },
                        set: { v in app.updateConfig { $0.longshotAutoScroll = v } }
                    ))
                })
            },
            SearchEntry(id: "cap.pin", tab: .captureAndPin, keywords: "截图 贴图 边框 初始位置 数量上限 pin") {
                AnyView(MagpieSettingRow(title: "贴图显示边框", subtitle: "截图") {
                    MagpieBooleanSwitch(isOn: Binding(
                        get: { app.config.pinBorder },
                        set: { b in app.updateConfig { $0.pinBorder = b } }
                    ))
                })
            },
            SearchEntry(id: "tb.slots", tab: .toolbar, keywords: "工具栏 槽位 隐藏 显示 按钮 矩形 箭头 模糊 聚光灯") {
                AnyView(MagpieSettingRow(title: "悬浮工具栏槽位定制", subtitle: "工具栏") {
                    MagpieTextAction("打开工具栏设置", prominent: true) { onSelectTab(.toolbar) }
                })
            },
            SearchEntry(id: "hk.shot", tab: .hotkeys, keywords: "快捷键 热键 开始截图 F1 screenshot") {
                AnyView(HotkeyRow(title: "开始截图", subtitle: "快捷键 · 全局", slotID: "s.global.screenshot", binding: app.config.hotkeys.screenshot, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.screenshot = b }
                })
            },
            SearchEntry(id: "hk.win", tab: .hotkeys, keywords: "快捷键 热键 窗体截图 F5 window") {
                AnyView(HotkeyRow(title: "独立窗体截图", subtitle: "快捷键 · 全局", slotID: "s.global.window", binding: app.config.hotkeys.windowCapture, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.windowCapture = b }
                })
            },
            SearchEntry(id: "hk.ls", tab: .hotkeys, keywords: "快捷键 热键 页面长截图 F4 longshot") {
                AnyView(HotkeyRow(title: "页面长截图", subtitle: "快捷键 · 全局", slotID: "s.global.ls", binding: app.config.hotkeys.longshotCapture, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.longshotCapture = b }
                })
            },
            SearchEntry(id: "hk.ocr", tab: .hotkeys, keywords: "快捷键 热键 截图识字 F2 ocr") {
                AnyView(HotkeyRow(title: "截图识字", subtitle: "快捷键 · 全局", slotID: "s.global.ocr", binding: app.config.hotkeys.ocrCapture, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.ocrCapture = b }
                })
            },
            SearchEntry(id: "hk.trans", tab: .hotkeys, keywords: "快捷键 热键 划词翻译 截图翻译 Option D S") {
                AnyView(HotkeyRow(title: "划词翻译", subtitle: "快捷键 · 全局", slotID: "s.global.trans", binding: app.config.hotkeys.translateSelection, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.translateSelection = b }
                })
            },
            SearchEntry(id: "ed.style", tab: .editor, keywords: "标注 线宽 模糊强度 字号 填充 调色板 颜色") {
                AnyView(MagpieSettingRow(title: "标注默认线宽 / 模糊 / 字号 / 颜色", subtitle: "标注") {
                    MagpieTextAction("打开标注设置", prominent: true) { onSelectTab(.editor) }
                })
            },
            SearchEntry(id: "ocr.lang", tab: .ocr, keywords: "OCR 与翻译 识别语言 中文 英文 日语 韩语 离线识字") {
                AnyView(MagpieSettingRow(title: "识别语言", subtitle: "OCR 与翻译") {
                    MagpieMenuPicker(
                        "识别语言",
                        options: OcrConfig.supportedOptions.map { ($0.tag, $0.label) },
                        selection: Binding(
                            get: { app.config.ocr.language },
                            set: { lang in app.updateConfig { $0.ocr.language = lang } }
                        )
                    )
                })
            },
            SearchEntry(id: "ocr.qr", tab: .ocr, keywords: "OCR 与翻译 二维码 条码 自动复制 合并换行") {
                AnyView(MagpieSettingRow(title: "识别二维码与条码", subtitle: "OCR 与翻译") {
                    MagpieBooleanSwitch(isOn: Binding(
                        get: { app.config.ocr.detectBarcodes },
                        set: { db in app.updateConfig { $0.ocr.detectBarcodes = db } }
                    ))
                })
            },
            SearchEntry(id: "ocr.selbtn", tab: .ocr, keywords: "OCR 与翻译 划词后显示翻译按钮 目标语言 翻译") {
                AnyView(MagpieSettingRow(title: "划词后显示翻译按钮", subtitle: "OCR 与翻译") {
                    MagpieBooleanSwitch(isOn: Binding(
                        get: { app.config.translation.showSelectionButton },
                        set: { enabled in app.updateConfig { $0.translation.showSelectionButton = enabled } }
                    ))
                })
            },
            SearchEntry(id: "ab.ver", tab: .about, keywords: "关于 版本 更新 检查更新 自动更新 version update") {
                AnyView(MagpieSettingRow(title: "版本", subtitle: "关于") {
                    HStack(spacing: 12) {
                        Text(UpdateChecker.currentVersion)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(p.inkMono)
                        MagpieTextAction("检查更新") { updateState.checkNow() }
                    }
                })
            },
            SearchEntry(id: "ab.cfg", tab: .about, keywords: "关于 配置目录 config.json 路径 协议 github") {
                AnyView(MagpieSettingRow(title: "配置目录", subtitle: "关于") {
                    HStack(spacing: 6) {
                        Text(OutputService.displayPath(for: configDirURL))
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(p.inkMono)
                        MagpieCopyButton(value: configDirURL.path)
                        MagpieTextAction("打开") { NSWorkspace.shared.open(configDirURL) }
                    }
                })
            }
        ]

        let matched = allEntries.filter { matches($0.keywords) }

        MagpieCard {
            if matched.isEmpty {
                VStack(spacing: 6) {
                    Text("未找到与「\(query)」匹配的设置项")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(p.inkPrimary)
                    Text("请尝试输入关键词，如：压缩、阴影、长截图、翻译、快捷键、配置目录")
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
