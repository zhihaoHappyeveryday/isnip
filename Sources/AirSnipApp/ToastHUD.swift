import AppKit
import AirSnipCore

@MainActor
enum ToastHUD {
    enum Kind {
        case success
        case information
        case warning

        var symbol: String {
            switch self {
            case .success: "checkmark"
            case .information: "info.circle"
            case .warning: "exclamationmark.triangle"
            }
        }
    }

    private struct Content: Equatable {
        let title: String
        let kind: Kind
        let detail: String?
        let countText: String?
    }

    struct Presentation: Equatable {
        private let id = UUID()
    }

    static var getTheme: () -> ThemeSetting = { .follow }

    private static var active: (content: Content, dark: Bool, panel: NSPanel, presentation: Presentation)?
    private static var dismissTask: Task<Void, Never>?

    @discardableResult
    static func show(
        _ title: String,
        kind: Kind,
        detail: String? = nil,
        countText: String? = nil,
        symbol: String? = nil,
        duration: TimeInterval? = nil,
        above window: NSWindow? = nil
    ) -> Presentation {
        let presentation = Presentation()
        let content = Content(title: title, kind: kind, detail: detail, countText: countText)
        let lifetime = duration ?? (kind == .warning || detail != nil ? 3 : 1.5)
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let maxWidth = min(screenFrame.width - 48, 520)
        let visibleLevel = NSApp.windows.lazy
            .filter { $0 !== active?.panel && $0.isVisible && $0.screen == screen }
            .map { $0.level.rawValue }
            .max() ?? 0
        let level = NSWindow.Level(rawValue: max(
            NSWindow.Level.statusBar.rawValue, max(visibleLevel, window?.level.rawValue ?? 0) + 1
        ))
        let theme = getTheme()
        let dark = theme == .dark || (theme == .follow && NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)

        dismissTask?.cancel()
        if let active, active.content == content, active.dark == dark, active.panel.frame.width <= maxWidth {
            let panel = active.panel
            Self.active?.presentation = presentation
            position(panel, on: screenFrame)
            panel.level = level
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
            }
            scheduleDismissal(of: presentation, panel: panel, after: lifetime)
            return presentation
        }

        active?.panel.orderOut(nil)
        let card = makeCard(content, symbol: symbol ?? kind.symbol, maxWidth: maxWidth, dark: dark)
        let panel = NSPanel(
            contentRect: card.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("iSnip.toast")
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = level
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = card
        position(panel, on: screenFrame)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
        active = (content, dark, panel, presentation)
        scheduleDismissal(of: presentation, panel: panel, after: lifetime)
        return presentation
    }

    static func dismiss(_ presentation: Presentation) {
        guard let active, active.presentation == presentation else { return }
        dismissTask?.cancel()
        dismissTask = nil
        active.panel.orderOut(nil)
        Self.active = nil
    }

    private static func position(_ panel: NSPanel, on screen: NSRect) {
        let origin = NSPoint(
            x: round(screen.midX - panel.frame.width / 2),
            y: round(screen.maxY - 22 - panel.frame.height)
        )
        if panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
        }
    }

    private static func scheduleDismissal(of presentation: Presentation, panel: NSPanel, after duration: TimeInterval) {
        guard duration.isFinite else { return }
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            dismiss(presentation)
        }
    }

    private static func makeCard(_ content: Content, symbol: String, maxWidth: CGFloat, dark: Bool) -> NSView {
        let ink = color(dark ? 0xF2F5F9 : 0x19232E)
        let detailInk = color(dark ? 0xB7C4D2 : 0x556372)
        let (accent, wash) = accentColors(for: content.kind, dark: dark)
        let guided = content.detail != nil
        let title = label(content.title, font: .systemFont(ofSize: guided ? 18 : 16, weight: .semibold), ink: ink)
        let detail = content.detail.map { label($0, font: .systemFont(ofSize: 14), ink: detailInk) }
        let count = content.countText.map {
            label($0, font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold), ink: accent)
        }
        let inset: CGFloat = 14
        let verticalInset: CGFloat = guided ? 12 : 8
        let iconSide: CGFloat = guided ? 38 : 26
        let iconGap: CGFloat = guided ? 12 : 9
        let textX = inset + iconSide + iconGap
        let detailGap: CGFloat = guided ? 4 : 0
        let badgeWidth = count.map { ceil($0.fittingSize.width) + 10 } ?? 0
        let badgeSpace = badgeWidth > 0 ? badgeWidth + 8 : 0
        let naturalWidth = textX + ceil(title.fittingSize.width) + badgeSpace + inset
        let width = min(maxWidth, guided ? 322 : naturalWidth)
        let textWidth = width - textX - inset
        let titleWidth = textWidth - badgeSpace
        let titleHeight = height(of: title, width: titleWidth)
        let detailHeight = detail.map { height(of: $0, width: textWidth) } ?? 0
        let textHeight = titleHeight + detailGap + detailHeight
        let height = max(guided ? 77 : 47, max(iconSide, textHeight) + 2 * verticalInset)
        let radius: CGFloat = guided ? 15 : 12

        let card = roundedView(
            frame: NSRect(x: 0, y: 0, width: width, height: height),
            radius: radius,
            fill: color(dark ? 0x222B37 : 0xFFFDFA)
        )
        card.layer?.borderWidth = 1
        card.layer?.borderColor = color(dark ? 0x465261 : 0xECEFF3).cgColor

        let icon = roundedView(
            frame: NSRect(x: inset, y: round((height - iconSide) / 2), width: iconSide, height: iconSide),
            radius: guided ? 10 : iconSide / 2,
            fill: wash
        )
        let config = NSImage.SymbolConfiguration(pointSize: guided ? 19 : 14, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [accent]))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: content.kind.symbol, accessibilityDescription: nil)
        if let image = image?.withSymbolConfiguration(config) {
            let imageView = NSImageView(image: image)
            imageView.frame = icon.bounds.insetBy(dx: guided ? 7 : 4, dy: guided ? 7 : 4)
            imageView.imageScaling = .scaleProportionallyDown
            icon.addSubview(imageView)
        }
        card.addSubview(icon)

        let titleY = round((height + textHeight) / 2 - titleHeight)
        title.frame = NSRect(x: textX, y: titleY, width: titleWidth, height: titleHeight)
        card.addSubview(title)
        if let detail {
            detail.frame = NSRect(x: textX, y: titleY - detailGap - detailHeight, width: textWidth, height: detailHeight)
            card.addSubview(detail)
        }
        if let count {
            let badgeHeight: CGFloat = 20
            let badge = roundedView(
                frame: NSRect(x: width - inset - badgeWidth,
                              y: round(title.frame.maxY - badgeHeight),
                              width: badgeWidth, height: badgeHeight),
                radius: badgeHeight / 2,
                fill: wash
            )
            let countHeight = ceil(count.fittingSize.height)
            count.frame = NSRect(x: 0, y: round((badgeHeight - countHeight) / 2), width: badgeWidth, height: countHeight)
            count.alignment = .center
            badge.addSubview(count)
            card.addSubview(badge)
        }
        return card
    }

    private static func label(_ text: String, font: NSFont, ink: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = ink
        label.maximumNumberOfLines = 0
        return label
    }

    private static func height(of label: NSTextField, width: CGFloat) -> CGFloat {
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        return ceil(label.cell?.cellSize(forBounds: bounds).height ?? label.fittingSize.height)
    }

    private static func roundedView(frame: NSRect, radius: CGFloat, fill: NSColor) -> NSView {
        let view = NSView(frame: frame)
        view.wantsLayer = true
        view.layer?.backgroundColor = fill.cgColor
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        return view
    }

    private static func accentColors(for kind: Kind, dark: Bool) -> (ink: NSColor, wash: NSColor) {
        switch kind {
        case .success:
            (color(dark ? 0x88E2B2 : 0x216749), color(dark ? 0x243E34 : 0xE5F4EC))
        case .information:
            (color(dark ? 0xADD0EF : 0x315D7A), color(dark ? 0x2E4359 : 0xE7EFF5))
        case .warning:
            (color(dark ? 0xFFCB98 : 0x86451A), color(dark ? 0x453428 : 0xF9E9D4))
        }
    }

    private static func color(_ rgb: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat(rgb >> 16 & 255) / 255,
            green: CGFloat(rgb >> 8 & 255) / 255,
            blue: CGFloat(rgb & 255) / 255,
            alpha: 1
        )
    }
}
