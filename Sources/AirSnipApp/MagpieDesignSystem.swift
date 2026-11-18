import AppKit
import SwiftUI
import AirSnipCore

// MARK: - SwiftUI AppLanguage Environment Key

private struct AppLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppLanguage = .system
}

public extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageEnvironmentKey.self] }
        set { self[AppLanguageEnvironmentKey.self] = newValue }
    }
}

// MARK: - Magpie Neutral Minimalist Design Tokens

public struct MagpiePalette {
    public let isDark: Bool

    public init(colorScheme: ColorScheme) {
        self.isDark = (colorScheme == .dark)
    }

    public init(isDark: Bool) {
        self.isDark = isDark
    }

    /// Outer window & panel canvas (#F7F7F8 light / #131316 dark)
    public var canvasBg: Color {
        isDark
            ? Color(.sRGB, red: 0.075, green: 0.075, blue: 0.086, opacity: 1.0)
            : Color(.sRGB, red: 0.969, green: 0.969, blue: 0.973, opacity: 1.0)
    }

    /// Primary elevated setting card (#FFFFFF light / #1C1C20 dark)
    public var cardBg: Color {
        isDark
            ? Color(.sRGB, red: 0.110, green: 0.110, blue: 0.125, opacity: 1.0)
            : Color(.sRGB, red: 1.0, green: 1.0, blue: 1.0, opacity: 1.0)
    }

    /// Subtle secondary surface inside cards (e.g. preview strip, code chip)
    public var subtleSurface: Color {
        isDark
            ? Color(.sRGB, red: 0.145, green: 0.145, blue: 0.165, opacity: 1.0)
            : Color(.sRGB, red: 0.965, green: 0.965, blue: 0.972, opacity: 1.0)
    }

    /// Outer 1px card hairline border (#E6E6EA light / #2B2B31 dark)
    public var cardBorder: Color {
        isDark
            ? Color(.sRGB, red: 0.169, green: 0.169, blue: 0.192, opacity: 1.0)
            : Color(.sRGB, red: 0.902, green: 0.902, blue: 0.918, opacity: 1.0)
    }

    /// Focused input border
    public var focusBorder: Color {
        isDark
            ? Color(.sRGB, red: 0.34, green: 0.34, blue: 0.38, opacity: 1.0)
            : Color(.sRGB, red: 0.62, green: 0.62, blue: 0.66, opacity: 1.0)
    }

    /// Full-bleed 1px row divider (#EFEFF2 light / #26262C dark)
    public var rowDivider: Color {
        isDark
            ? Color(.sRGB, red: 0.149, green: 0.149, blue: 0.173, opacity: 1.0)
            : Color(.sRGB, red: 0.937, green: 0.937, blue: 0.949, opacity: 1.0)
    }

    /// Primary ink (#18181B light / #F4F4F6 dark)
    public var inkPrimary: Color {
        isDark
            ? Color(.sRGB, red: 0.957, green: 0.957, blue: 0.965, opacity: 1.0)
            : Color(.sRGB, red: 0.094, green: 0.094, blue: 0.106, opacity: 1.0)
    }

    /// Secondary ink (#71717A light / #9E9EA8 dark)
    public var inkSecondary: Color {
        isDark
            ? Color(.sRGB, red: 0.620, green: 0.620, blue: 0.659, opacity: 1.0)
            : Color(.sRGB, red: 0.443, green: 0.443, blue: 0.478, opacity: 1.0)
    }

    /// Tertiary / placeholder ink (#A1A1AA light / #6E6E77 dark)
    public var inkTertiary: Color {
        isDark
            ? Color(.sRGB, red: 0.431, green: 0.431, blue: 0.467, opacity: 1.0)
            : Color(.sRGB, red: 0.631, green: 0.631, blue: 0.667, opacity: 1.0)
    }

    /// Technical monospaced value ink (#3F3F46 light / #D4D4D8 dark)
    public var inkMono: Color {
        isDark
            ? Color(.sRGB, red: 0.831, green: 0.831, blue: 0.847, opacity: 1.0)
            : Color(.sRGB, red: 0.247, green: 0.247, blue: 0.275, opacity: 1.0)
    }

    /// Active navigation / sub-tab pill (#EAEAEF light / #2A2A31 dark)
    public var navActivePill: Color {
        isDark
            ? Color(.sRGB, red: 0.165, green: 0.165, blue: 0.192, opacity: 1.0)
            : Color(.sRGB, red: 0.918, green: 0.918, blue: 0.937, opacity: 1.0)
    }

    /// Hover navigation pill
    public var navHoverPill: Color {
        isDark
            ? Color(.sRGB, red: 0.135, green: 0.135, blue: 0.157, opacity: 1.0)
            : Color(.sRGB, red: 0.938, green: 0.938, blue: 0.952, opacity: 1.0)
    }

    /// Segmented control outer track (#F1F1F4 light / #25252B dark)
    public var segmentedTrack: Color {
        isDark
            ? Color(.sRGB, red: 0.145, green: 0.145, blue: 0.169, opacity: 1.0)
            : Color(.sRGB, red: 0.945, green: 0.945, blue: 0.957, opacity: 1.0)
    }

    /// Segmented control selected thumb (#FFFFFF light / #36363E dark)
    public var segmentedThumb: Color {
        isDark
            ? Color(.sRGB, red: 0.212, green: 0.212, blue: 0.243, opacity: 1.0)
            : Color(.sRGB, red: 1.0, green: 1.0, blue: 1.0, opacity: 1.0)
    }

    /// Segmented control thumb border
    public var segmentedThumbBorder: Color {
        isDark
            ? Color(.sRGB, red: 0.285, green: 0.285, blue: 0.325, opacity: 1.0)
            : Color(.sRGB, red: 0.886, green: 0.886, blue: 0.906, opacity: 1.0)
    }

    /// Primary solid CTA button fill (monochrome high-contrast)
    public var solidBtnBg: Color {
        isDark
            ? Color(.sRGB, red: 0.953, green: 0.953, blue: 0.965, opacity: 1.0)
            : Color(.sRGB, red: 0.102, green: 0.102, blue: 0.118, opacity: 1.0)
    }

    /// Primary solid CTA button foreground
    public var solidBtnFg: Color {
        isDark
            ? Color(.sRGB, red: 0.082, green: 0.082, blue: 0.094, opacity: 1.0)
            : Color(.sRGB, red: 1.0, green: 1.0, blue: 1.0, opacity: 1.0)
    }

    /// Semantic status colors (restrained saturation)
    public var statusOk: Color {
        isDark
            ? Color(.sRGB, red: 0.28, green: 0.78, blue: 0.52, opacity: 1.0)
            : Color(.sRGB, red: 0.10, green: 0.56, blue: 0.34, opacity: 1.0)
    }

    public var statusWarn: Color {
        isDark
            ? Color(.sRGB, red: 0.94, green: 0.64, blue: 0.24, opacity: 1.0)
            : Color(.sRGB, red: 0.78, green: 0.44, blue: 0.08, opacity: 1.0)
    }
}

// MARK: - Monochrome Brand Mark (Viewfinder Aperture Silhouette)

public struct MagpieBrandMark: View {
    @Environment(\.colorScheme) private var colorScheme
    var size: CGFloat = 17

    public init(size: CGFloat = 17) {
        self.size = size
    }

    public var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        Canvas { ctx, sz in
            let w = sz.width
            let h = sz.height
            let s = min(w, h) / 18.0
            let minX = 2.2 * s
            let maxX = w - 2.2 * s
            let minY = 2.5 * s
            let maxY = h - 2.5 * s
            let arm = 3.8 * s
            let r = 2.0 * s
            let strokeStyle = StrokeStyle(lineWidth: 1.65 * s, lineCap: .round, lineJoin: .round)

            var corners = Path()
            // Top-left
            corners.move(to: CGPoint(x: minX, y: minY + arm))
            corners.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX + arm, y: minY), radius: r)
            corners.addLine(to: CGPoint(x: minX + arm, y: minY))
            // Top-right
            corners.move(to: CGPoint(x: maxX - arm, y: minY))
            corners.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: minY + arm), radius: r)
            corners.addLine(to: CGPoint(x: maxX, y: minY + arm))
            // Bottom-left
            corners.move(to: CGPoint(x: minX, y: maxY - arm))
            corners.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX + arm, y: maxY), radius: r)
            corners.addLine(to: CGPoint(x: minX + arm, y: maxY))
            // Bottom-right
            corners.move(to: CGPoint(x: maxX - arm, y: maxY))
            corners.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: maxX, y: maxY - arm), radius: r)
            corners.addLine(to: CGPoint(x: maxX, y: maxY - arm))

            ctx.stroke(corners, with: .color(p.inkPrimary), style: strokeStyle)

            let ringSide = 5.4 * s
            let ringRect = CGRect(x: (w - ringSide) * 0.5, y: (h - ringSide) * 0.5, width: ringSide, height: ringSide)
            ctx.stroke(Path(ellipseIn: ringRect), with: .color(p.inkPrimary), lineWidth: 1.4 * s)

            let dotSide = 1.9 * s
            let dotRect = CGRect(x: (w - dotSide) * 0.5, y: (h - dotSide) * 0.5, width: dotSide, height: dotSide)
            ctx.fill(Path(ellipseIn: dotRect), with: .color(p.inkPrimary))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Continuous Elevated Card & Full-Bleed Divider

public struct MagpieCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 12
    @ViewBuilder var content: () -> Content

    public init(cornerRadius: CGFloat = 12, @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content
    }

    public var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(p.cardBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(p.cardBorder, lineWidth: 1)
        )
    }
}

public struct MagpieRowDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        Rectangle()
            .fill(p.rowDivider)
            .frame(height: 1)
    }
}

public struct MagpieSectionGroupRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    var trailingText: String? = nil

    public var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        HStack {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(p.inkSecondary)
            Spacer()
            if let trailingText {
                Text(trailingText)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(p.inkTertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8.5)
        .background(p.subtleSurface.opacity(0.65))
    }
}

// MARK: - Standard Setting Row

public struct MagpieSettingRow<Control: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    var subtitle: String? = nil
    var infoTip: String? = nil
    @ViewBuilder var control: () -> Control

    public init(
        title: String,
        subtitle: String? = nil,
        infoTip: String? = nil,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.subtitle = subtitle
        self.infoTip = infoTip
        self.control = control
    }

    public var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(p.inkPrimary)
                    if let infoTip, !infoTip.isEmpty {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(p.inkTertiary)
                            .help(infoTip)
                    }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(p.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 14)
            control()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, subtitle == nil ? 13.5 : 12.5)
    }
}

// MARK: - Segmented Pill Controls (Boolean [关闭 | 开启] / [Off | On] & Multi-Option)

public struct MagpieBooleanSwitch: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var appLanguage
    @Environment(\.isEnabled) private var isEnabled
    @Binding var isOn: Bool
    var customOffLabel: String?
    var customOnLabel: String?

    public init(isOn: Binding<Bool>, offLabel: String? = nil, onLabel: String? = nil) {
        self._isOn = isOn
        self.customOffLabel = offLabel
        self.customOnLabel = onLabel
    }

    public var body: some View {
        let offText = customOffLabel ?? (appLanguage.isEnglish ? "Off" : "关闭")
        let onText = customOnLabel ?? (appLanguage.isEnglish ? "On" : "开启")
        MagpieSegmentedPicker(
            options: [(false, offText), (true, onText)],
            selection: $isOn
        )
        .opacity(isEnabled ? 1.0 : 0.48)
    }
}

public struct MagpieSegmentedPicker<Value: Hashable>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var compact: Bool = false
    @State private var hoveredValue: Value?

    public init(
        options: [(value: Value, label: String)],
        selection: Binding<Value>,
        compact: Bool = false
    ) {
        self.options = options
        self._selection = selection
        self.compact = compact
    }

    public var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let selected = (selection == opt.value)
                let hovered = (hoveredValue == opt.value && isEnabled)
                Button {
                    guard isEnabled, selection != opt.value else { return }
                    withAnimation(.easeOut(duration: 0.14)) {
                        selection = opt.value
                    }
                } label: {
                    Text(opt.label)
                        .font(.system(size: compact ? 11.5 : 12.5, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? p.inkPrimary : (hovered ? p.inkPrimary.opacity(0.85) : p.inkSecondary))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, compact ? 8.5 : 11)
                        .frame(height: compact ? 21 : 24)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: compact ? 5.0 : 5.5, style: .continuous)
                                    .fill(p.segmentedThumb)
                                    .shadow(
                                        color: .black.opacity(p.isDark ? 0.26 : 0.055),
                                        radius: 1.5,
                                        x: 0,
                                        y: 0.5
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: compact ? 5.0 : 5.5, style: .continuous)
                                            .strokeBorder(p.segmentedThumbBorder, lineWidth: 0.75)
                                    )
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside {
                        hoveredValue = opt.value
                    } else if hoveredValue == opt.value {
                        hoveredValue = nil
                    }
                }
            }
        }
        .padding(2.5)
        .background(
            RoundedRectangle(cornerRadius: compact ? 6.5 : 7.5, style: .continuous)
                .fill(p.segmentedTrack)
        )
        .opacity(isEnabled ? 1.0 : 0.48)
    }
}

// MARK: - Minimal Menu Picker Pill (Custom Crisp Pill + Native NSMenu Popup)

public struct MagpieMenuPicker<Value: Hashable>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var minWidth: CGFloat = 104
    var compact: Bool = false
    @State private var isHovered = false

    public init(
        _ title: String = "",
        options: [(value: Value, label: String)],
        selection: Binding<Value>,
        minWidth: CGFloat = 104,
        compact: Bool = false
    ) {
        self.title = title
        self.options = options
        self._selection = selection
        self.minWidth = minWidth
        self.compact = compact
    }

    private var currentLabel: String {
        options.first(where: { $0.value == selection })?.label ?? ""
    }

    public var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        let selectedIdx = options.firstIndex(where: { $0.value == selection }) ?? 0

        HStack(spacing: 7) {
            Text(currentLabel)
                .font(.system(size: compact ? 12 : 12.5, weight: .medium))
                .foregroundStyle(p.inkPrimary)
                .lineLimit(1)
            Spacer(minLength: 2)
            Image(systemName: "chevron.down")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(p.inkSecondary)
        }
        .padding(.horizontal, compact ? 10 : 11)
        .frame(minWidth: minWidth)
        .frame(height: compact ? 26 : 29)
        .background(
            RoundedRectangle(cornerRadius: compact ? 6.5 : 7.5, style: .continuous)
                .fill(isHovered ? p.segmentedTrack : p.cardBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 6.5 : 7.5, style: .continuous)
                .strokeBorder(isHovered ? p.focusBorder.opacity(0.6) : p.cardBorder, lineWidth: 1)
        )
        .overlay(
            NSMenuTriggerOverlay(
                labels: options.map(\.label),
                selectedIndex: selectedIdx,
                accessibilityTitle: title.isEmpty ? currentLabel : title,
                isHovered: $isHovered,
                onSelect: { idx in
                    guard options.indices.contains(idx) else { return }
                    selection = options[idx].value
                }
            )
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct NSMenuTriggerOverlay: NSViewRepresentable {
    let labels: [String]
    let selectedIndex: Int
    let accessibilityTitle: String
    @Binding var isHovered: Bool
    let onSelect: (Int) -> Void

    func makeNSView(context: Context) -> TriggerNSView {
        let v = TriggerNSView()
        v.onHoverChanged = { inside in
            isHovered = inside
        }
        return v
    }

    func updateNSView(_ nsView: TriggerNSView, context: Context) {
        nsView.labels = labels
        nsView.selectedIndex = selectedIndex
        nsView.onSelect = onSelect
        nsView.setAccessibilityLabel(accessibilityTitle)
        nsView.onHoverChanged = { inside in
            isHovered = inside
        }
    }

    final class TriggerNSView: NSView {
        var labels: [String] = []
        var selectedIndex: Int = 0
        var onSelect: ((Int) -> Void)?
        var onHoverChanged: ((Bool) -> Void)?
        private var trackingAreaRef: NSTrackingArea?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityRole(.popUpButton)
        }

        required init?(coder: NSCoder) { nil }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingAreaRef {
                removeTrackingArea(existing)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingAreaRef = area
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChanged?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHoverChanged?(false)
        }

        override func mouseDown(with event: NSEvent) {
            let menu = NSMenu()
            menu.font = NSFont.systemFont(ofSize: 12.5)
            for (idx, text) in labels.enumerated() {
                let item = NSMenuItem(title: text, action: #selector(handlePick(_:)), keyEquivalent: "")
                item.target = self
                item.tag = idx
                item.state = (idx == selectedIndex) ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: self)
            onHoverChanged?(false)
        }

        @objc private func handlePick(_ sender: NSMenuItem) {
            onSelect?(sender.tag)
        }
    }
}

// MARK: - Action Links, Copy Button & Pill Buttons

public struct MagpieTextAction: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    let label: String
    var prominent: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    public init(_ label: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.prominent = prominent
        self.action = action
    }

    public var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        Button(action: action) {
            Text(label)
                .font(.system(size: 12.5, weight: prominent ? .semibold : .regular))
                .foregroundStyle(isHovered ? p.inkPrimary : (prominent ? p.inkPrimary : p.inkSecondary))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .fill(isHovered ? p.segmentedTrack : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .opacity(isEnabled ? 1.0 : 0.45)
    }
}

public struct MagpieCopyButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appLanguage) private var appLanguage
    let valueToCopy: String
    var customHelpText: String?
    @State private var copied = false
    @State private var isHovered = false

    public init(value: String, helpText: String? = nil) {
        self.valueToCopy = value
        self.customHelpText = helpText
    }

    public var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        let tip = customHelpText ?? (appLanguage.isEnglish ? "Copy" : "复制")
        let copiedTip = appLanguage.isEnglish ? "Copied" : "已复制"
        Button {
            OutputService.copyStringToClipboard(valueToCopy)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "square.on.square")
                .font(.system(size: 11, weight: copied ? .semibold : .regular))
                .foregroundStyle(copied ? p.statusOk : (isHovered ? p.inkPrimary : p.inkSecondary))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovered ? p.segmentedTrack : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(copied ? copiedTip : tip)
    }
}

public struct MagpiePillButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    public enum Role {
        case primary
        case secondary
        case bordered
        case warning
    }

    var role: Role
    var compact: Bool

    public init(role: Role = .secondary, compact: Bool = false) {
        self.role = role
        self.compact = compact
    }

    public func makeBody(configuration: Configuration) -> some View {
        InnerPillButton(configuration: configuration, role: role, compact: compact, isEnabled: isEnabled)
    }

    private struct InnerPillButton: View {
        @Environment(\.colorScheme) private var colorScheme
        let configuration: Configuration
        let role: Role
        let compact: Bool
        let isEnabled: Bool
        @State private var isHovered = false

        var body: some View {
            let p = MagpiePalette(colorScheme: colorScheme)
            let bg: Color = {
                switch role {
                case .primary:
                    return p.solidBtnBg.opacity(configuration.isPressed ? 0.82 : (isHovered ? 0.90 : 1.0))
                case .secondary:
                    return p.segmentedTrack.opacity(configuration.isPressed ? 0.78 : (isHovered ? 0.92 : 1.0))
                case .bordered:
                    return isHovered ? p.segmentedTrack : p.cardBg
                case .warning:
                    return p.statusWarn.opacity(configuration.isPressed ? 0.24 : 0.14)
                }
            }()
            let fg: Color = {
                switch role {
                case .primary:
                    return p.solidBtnFg
                case .secondary, .bordered:
                    return p.inkPrimary
                case .warning:
                    return p.statusWarn
                }
            }()

            configuration.label
                .font(.system(size: compact ? 11.5 : 12.5, weight: role == .primary ? .semibold : .medium))
                .foregroundStyle(fg)
                .padding(.horizontal, compact ? 9 : 12)
                .frame(height: compact ? 25 : 28)
                .background(
                    RoundedRectangle(cornerRadius: compact ? 6.0 : 7.0, style: .continuous)
                        .fill(bg)
                )
                .overlay {
                    if role == .bordered {
                        RoundedRectangle(cornerRadius: compact ? 6.0 : 7.0, style: .continuous)
                            .strokeBorder(isHovered ? p.focusBorder.opacity(0.6) : p.cardBorder, lineWidth: 1)
                    }
                }
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
                .opacity(isEnabled ? 1.0 : 0.42)
                .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Neutral Stepper Pill & Neutral Slider

public struct MagpieStepperPill: View {
    @Environment(\.colorScheme) private var colorScheme
    let displayValue: String
    let canDecrement: Bool
    let canIncrement: Bool
    let onDecrement: () -> Void
    let onIncrement: () -> Void
    @State private var hoverMinus = false
    @State private var hoverPlus = false

    public var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        HStack(spacing: 10) {
            Text(displayValue)
                .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(p.inkMono)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 1) {
                Button(action: onDecrement) {
                    Image(systemName: "minus")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(canDecrement ? p.inkPrimary : p.inkTertiary)
                        .frame(width: 26, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(hoverMinus && canDecrement ? p.segmentedThumb : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canDecrement)
                .onHover { hoverMinus = $0 }

                Rectangle()
                    .fill(p.cardBorder)
                    .frame(width: 1, height: 13)

                Button(action: onIncrement) {
                    Image(systemName: "plus")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(canIncrement ? p.inkPrimary : p.inkTertiary)
                        .frame(width: 26, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(hoverPlus && canIncrement ? p.segmentedThumb : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canIncrement)
                .onHover { hoverPlus = $0 }
            }
            .padding(2.5)
            .background(
                RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                    .fill(p.segmentedTrack)
            )
        }
    }
}

public struct MagpieSlider: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1.0

    public init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 1.0) {
        self._value = value
        self.range = range
        self.step = step
    }

    public var body: some View {
        let p = MagpiePalette(colorScheme: colorScheme)
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let thumbSize: CGFloat = 15
            let usable = max(1, width - thumbSize)
            let span = max(0.0001, range.upperBound - range.lowerBound)
            let progress = max(0, min(1, (value - range.lowerBound) / span))
            let thumbX = CGFloat(progress) * usable

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(p.segmentedTrack)
                    .frame(height: 5)

                Capsule()
                    .fill(p.inkPrimary.opacity(p.isDark ? 0.80 : 0.78))
                    .frame(width: thumbX + thumbSize * 0.5, height: 5)

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(p.isDark ? 0.35 : 0.14), radius: 2, x: 0, y: 1)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.black.opacity(0.14), lineWidth: 0.8)
                    )
                    .offset(x: thumbX)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let clampedX = max(0, min(usable, drag.location.x - thumbSize * 0.5))
                        let raw = range.lowerBound + Double(clampedX / usable) * span
                        let stepped = ((raw - range.lowerBound) / step).rounded() * step + range.lowerBound
                        value = max(range.lowerBound, min(range.upperBound, stepped))
                    }
            )
        }
        .frame(height: 22)
    }
}
