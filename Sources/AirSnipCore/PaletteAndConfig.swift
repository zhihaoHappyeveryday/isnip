import Foundation
import Carbon

public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case zhHans = "zh-Hans"
    case en = "en"

    public var isEnglish: Bool {
        switch self {
        case .zhHans:
            return false
        case .en:
            return true
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "zh-hans"
            return !preferred.hasPrefix("zh")
        }
    }

    public var title: String {
        title(in: L10n.current)
    }

    public func title(in lang: AppLanguage) -> String {
        switch self {
        case .system:
            return lang.isEnglish ? "System" : "跟随系统"
        case .zhHans:
            return "简体中文"
        case .en:
            return "English"
        }
    }
}

public enum L10n {
    private static let lock = NSLock()
    private static var _current: AppLanguage = .system

    public static var current: AppLanguage {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _current
        }
        set {
            lock.lock()
            _current = newValue
            lock.unlock()
        }
    }

    @inline(__always)
    public static func tr(_ zh: String, _ en: String, in lang: AppLanguage? = nil) -> String {
        let resolved = lang ?? current
        return resolved.isEnglish ? en : zh
    }
}

public enum AnnotationTool: Int, Codable, CaseIterable, Sendable {
    case rect = 0
    case arrow = 1
    case text = 2
    case highlight = 3
    case blur = 4
    case glow = 5
    case number = 6
    case line = 7
    case ellipse = 8
    case freehand = 9

    public static let allOrdered: [AnnotationTool] = [
        .rect, .arrow, .text, .highlight, .blur, .glow, .number, .line, .ellipse, .freehand
    ]

    public var displayName: String {
        displayName(in: .zhHans)
    }

    public func displayName(in lang: AppLanguage) -> String {
        switch self {
        case .rect: return lang.isEnglish ? "Rectangle" : "矩形"
        case .arrow: return lang.isEnglish ? "Arrow" : "箭头"
        case .text: return lang.isEnglish ? "Text" : "文本"
        case .highlight: return lang.isEnglish ? "Highlighter" : "荧光笔"
        case .blur: return lang.isEnglish ? "Blur" : "模糊"
        case .glow: return lang.isEnglish ? "Spotlight" : "聚光灯"
        case .number: return lang.isEnglish ? "Counter" : "序号"
        case .line: return lang.isEnglish ? "Line" : "直线"
        case .ellipse: return lang.isEnglish ? "Ellipse" : "椭圆"
        case .freehand: return lang.isEnglish ? "Freehand" : "手绘"
        }
    }

    public var shortLabel: String {
        shortLabel(in: .zhHans)
    }

    public func shortLabel(in lang: AppLanguage) -> String {
        displayName(in: lang)
    }

    public var sfSymbolName: String {
        switch self {
        case .rect: return "rectangle"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .highlight: return "highlighter"
        case .blur: return "aqi.medium"
        case .glow: return "flashlight.on.fill"
        case .number: return "1.circle"
        case .line: return "line.diagonal"
        case .ellipse: return "circle"
        case .freehand: return "scribble"
        }
    }

    public var defaultShortcutDigit: String {
        switch self {
        case .rect: return "1"
        case .arrow: return "2"
        case .text: return "3"
        case .highlight: return "4"
        case .blur: return "5"
        case .glow: return "6"
        case .number: return "7"
        case .line: return "8"
        case .ellipse: return "9"
        case .freehand: return "0"
        }
    }
}

public enum ColorPalette {
    public static let swatchCount = 5

    public static let defaultSwatches: [RGBAColor] = [
        RGBAColor(r: 255, g: 255, b: 255),
        RGBAColor(r: 255, g: 0, b: 0),
        RGBAColor(r: 251, g: 140, b: 0),
        RGBAColor(r: 67, g: 160, b: 71),
        RGBAColor(r: 30, g: 136, b: 229),
    ]

    public static let quickColors: [RGBAColor] = [
        RGBAColor(r: 255, g: 255, b: 255),
        RGBAColor(r: 0, g: 0, b: 0),
        RGBAColor(r: 158, g: 158, b: 158),
        RGBAColor(r: 255, g: 0, b: 0),
        RGBAColor(r: 251, g: 140, b: 0),
        RGBAColor(r: 253, g: 216, b: 53),
        RGBAColor(r: 67, g: 160, b: 71),
        RGBAColor(r: 0, g: 172, b: 193),
        RGBAColor(r: 30, g: 136, b: 229),
        RGBAColor(r: 142, g: 36, b: 170),
        RGBAColor(r: 216, g: 27, b: 96),
        RGBAColor(r: 109, g: 76, b: 65),
    ]

    public static func hsvToRGB(h: Double, s: Double, v: Double) -> RGBAColor {
        var hue = h.truncatingRemainder(dividingBy: 360.0)
        if hue < 0 { hue += 360.0 }
        let sector = hue / 60.0
        let sat = max(0.0, min(1.0, s))
        let val = max(0.0, min(1.0, v))
        let c = val * sat
        let x = c * (1.0 - abs(sector.truncatingRemainder(dividingBy: 2.0) - 1.0))
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(sector) {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        let m = val - c
        func byte(_ f: Double) -> UInt8 {
            UInt8(max(0, min(255, Int(((f + m) * 255.0).rounded()))))
        }
        return RGBAColor(r: byte(r1), g: byte(g1), b: byte(b1), a: 255)
    }

    public static func rgbToHSV(_ c: RGBAColor) -> (h: Double, s: Double, v: Double) {
        let r = Double(c.r) / 255.0
        let g = Double(c.g) / 255.0
        let b = Double(c.b) / 255.0
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let d = maxC - minC
        var h: Double
        if d < 1e-6 {
            h = 0
        } else if maxC == r {
            h = 60.0 * (((g - b) / d).truncatingRemainder(dividingBy: 6.0))
        } else if maxC == g {
            h = 60.0 * (((b - r) / d) + 2.0)
        } else {
            h = 60.0 * (((r - g) / d) + 4.0)
        }
        if h < 0 { h += 360.0 }
        let s = maxC < 1e-6 ? 0.0 : (d / maxC)
        return (h, s, maxC)
    }
}

public enum ToolbarGroup: String, CaseIterable, Sendable {
    case tools
    case colors
    case edit
    case output
    case file

    public var title: String {
        title(in: .zhHans)
    }

    public func title(in lang: AppLanguage) -> String {
        switch self {
        case .tools: return lang.isEnglish ? "Tools" : "工具"
        case .colors: return lang.isEnglish ? "Colors" : "颜色"
        case .edit: return lang.isEnglish ? "Edit" : "编辑"
        case .output: return lang.isEnglish ? "Output" : "输出"
        case .file: return lang.isEnglish ? "File" : "文件"
        }
    }

    public var slots: [ToolbarSlot] {
        switch self {
        case .tools:
            return AnnotationTool.allOrdered.map { .tool($0) }
        case .colors:
            return (0..<ColorPalette.swatchCount).map { .color($0) }
        case .edit:
            return [.fill, .undo, .redo, .textRow]
        case .output:
            return [.pin, .longshot, .ocr]
        case .file:
            return [.copy, .save]
        }
    }
}

public enum ToolbarSlot: Equatable, Hashable, Sendable {
    case tool(AnnotationTool)
    case color(Int)
    case fill
    case undo
    case redo
    case textRow
    case pin
    case longshot
    case ocr
    case cancel
    case copy
    case save

    public static var hideableSlots: [ToolbarSlot] {
        ToolbarGroup.allCases.flatMap { $0.slots }
    }

    @available(*, deprecated, renamed: "hideableSlots")
    public static var allOrdered: [ToolbarSlot] { hideableSlots }

    public static let defaultMainOrder: [ToolbarSlot] = [
        .tool(.rect), .tool(.ellipse), .tool(.line), .tool(.arrow), .tool(.freehand),
        .tool(.blur), .tool(.text), .tool(.number), .tool(.glow),
        .pin, .undo, .ocr, .cancel, .longshot, .save, .copy
    ]

    public var key: String {
        switch self {
        case .tool(.rect): return "tool.rect"
        case .tool(.arrow): return "tool.arrow"
        case .tool(.text): return "tool.text"
        case .tool(.highlight): return "tool.highlight"
        case .tool(.blur): return "tool.blur"
        case .tool(.glow): return "tool.glow"
        case .tool(.number): return "tool.number"
        case .tool(.line): return "tool.line"
        case .tool(.ellipse): return "tool.ellipse"
        case .tool(.freehand): return "tool.freehand"
        case .color(let idx) where (0..<ColorPalette.swatchCount).contains(idx):
            return "color.\(idx + 1)"
        case .color:
            return "color.unused"
        case .fill: return "edit.fill"
        case .undo: return "edit.undo"
        case .redo: return "edit.redo"
        case .textRow: return "edit.text_row"
        case .pin: return "output.pin"
        case .longshot: return "output.longshot"
        case .ocr: return "output.ocr"
        case .cancel: return "file.cancel"
        case .copy: return "file.copy"
        case .save: return "file.save"
        }
    }

    public var label: String {
        label(in: .zhHans)
    }

    public func label(in lang: AppLanguage) -> String {
        switch self {
        case .tool(let t): return t.shortLabel(in: lang)
        case .color(let idx) where (0..<ColorPalette.swatchCount).contains(idx):
            return lang.isEnglish ? "Color \(idx + 1)" : "颜色\(idx + 1)"
        case .color: return lang.isEnglish ? "Color" : "颜色"
        case .fill: return lang.isEnglish ? "Fill" : "填充"
        case .undo: return lang.isEnglish ? "Undo" : "撤销"
        case .redo: return lang.isEnglish ? "Redo" : "重做"
        case .textRow: return lang.isEnglish ? "Font Bar" : "字体行"
        case .pin: return lang.isEnglish ? "Pin" : "贴图"
        case .longshot: return lang.isEnglish ? "Longshot" : "长截图"
        case .ocr: return "OCR"
        case .cancel: return lang.isEnglish ? "Cancel" : "取消"
        case .copy: return lang.isEnglish ? "Copy" : "复制"
        case .save: return lang.isEnglish ? "Save" : "保存"
        }
    }

    public var group: ToolbarGroup {
        switch self {
        case .tool: return .tools
        case .color: return .colors
        case .fill, .undo, .redo, .textRow: return .edit
        case .pin, .longshot, .ocr: return .output
        case .cancel, .copy, .save: return .file
        }
    }
}

public enum ToolbarGroupState: Equatable, Sendable {
    case all
    case partial
    case none
}

public struct ToolbarConfig: Codable, Equatable, Sendable {
    public var hidden: [String]
    private var order: [String]?

    public init(hidden: [String] = []) {
        self.hidden = hidden
    }

    public var mainOrder: [ToolbarSlot] {
        get {
            let defaults = ToolbarSlot.defaultMainOrder
            guard let order else { return defaults }
            var remaining = Dictionary(uniqueKeysWithValues: defaults.map { ($0.key, $0) })
            let ordered = order.compactMap { remaining.removeValue(forKey: $0) }
            return ordered + defaults.filter { remaining[$0.key] != nil }
        }
        set {
            order = newValue == ToolbarSlot.defaultMainOrder ? nil : newValue.map(\.key)
        }
    }

    public var hasCustomMainOrder: Bool {
        mainOrder != ToolbarSlot.defaultMainOrder
    }

    public mutating func resetMainOrder() {
        order = nil
    }

    public func isVisible(_ slot: ToolbarSlot) -> Bool {
        slot == .cancel || !hidden.contains(slot.key)
    }

    public mutating func setVisible(_ slot: ToolbarSlot, _ visible: Bool) {
        guard slot != .cancel else { return }
        let k = slot.key
        if visible {
            hidden.removeAll { $0 == k }
        } else if isVisible(slot) {
            hidden.append(k)
        }
    }

    public func visibleCount(in group: ToolbarGroup) -> Int {
        group.slots.filter { isVisible($0) }.count
    }

    public func groupState(_ group: ToolbarGroup) -> ToolbarGroupState {
        let c = visibleCount(in: group)
        if c == 0 { return .none }
        if c == group.slots.count { return .all }
        return .partial
    }

    public mutating func setGroupVisible(_ group: ToolbarGroup, _ visible: Bool) {
        for s in group.slots {
            setVisible(s, visible)
        }
    }

    public var isEntireToolbarHidden: Bool {
        ToolbarSlot.hideableSlots.allSatisfy { !isVisible($0) }
    }

    public func settleTool(_ preferred: AnnotationTool) -> AnnotationTool {
        if isVisible(.tool(preferred)) { return preferred }
        return AnnotationTool.allOrdered.first(where: { isVisible(.tool($0)) }) ?? preferred
    }

    public func settleColorIndex(_ preferred: Int) -> Int {
        if isVisible(.color(preferred)) { return preferred }
        return (0..<ColorPalette.swatchCount).first(where: { isVisible(.color($0)) }) ?? preferred
    }
}

@available(*, deprecated, renamed: "ToolbarConfig")
public typealias ToolbarVisibilityConfig = ToolbarConfig

public enum MouseExtraButton: Int, Codable, Equatable, Hashable, Sendable {
    case middle = 2
    case side1 = 3
    case side2 = 4

    public var displayName: String {
        displayName(in: L10n.current)
    }

    public func displayName(in lang: AppLanguage) -> String {
        switch self {
        case .middle: return lang.isEnglish ? "Middle Click" : "鼠标中键"
        case .side1: return lang.isEnglish ? "Mouse Button 4" : "鼠标侧键 1"
        case .side2: return lang.isEnglish ? "Mouse Button 5" : "鼠标侧键 2"
        }
    }
}

public struct HotkeyModifiers: OptionSet, Codable, Equatable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = HotkeyModifiers(rawValue: 1 << 0)
    public static let control = HotkeyModifiers(rawValue: 1 << 1)
    public static let option  = HotkeyModifiers(rawValue: 1 << 2)
    public static let shift   = HotkeyModifiers(rawValue: 1 << 3)

    public var isEmptyModifiers: Bool { rawValue == 0 }

    public var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.option)  { flags |= UInt32(optionKey) }
        if contains(.shift)   { flags |= UInt32(shiftKey) }
        return flags
    }

    public var displayPrefix: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option)  { s += "⌥" }
        if contains(.shift)   { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

public struct HotkeyBinding: Codable, Equatable, Hashable, Sendable {
    public var keyCode: Int? // Carbon virtual key code, nil if unbound or mouse button
    public var modifiers: HotkeyModifiers
    public var mouseButton: MouseExtraButton?

    public init(keyCode: Int? = nil, modifiers: HotkeyModifiers = [], mouseButton: MouseExtraButton? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.mouseButton = mouseButton
    }

    public static let unbound = HotkeyBinding(keyCode: nil, modifiers: [], mouseButton: nil)

    public var isUnbound: Bool {
        keyCode == nil && mouseButton == nil
    }

    public var hasNoModifierWarning: Bool {
        guard let kc = keyCode, mouseButton == nil else { return false }
        let _ = kc
        return modifiers.isEmptyModifiers
    }

    public var displayString: String {
        displayString(in: L10n.current)
    }

    public func displayString(in lang: AppLanguage) -> String {
        if let mb = mouseButton {
            return mb.displayName(in: lang)
        }
        guard let kc = keyCode else {
            return lang.isEnglish ? "Not Set" : "未设置"
        }
        return modifiers.displayPrefix + KeyCodeLabels.name(for: kc)
    }
}

public enum KeyCodeLabels {
    public static func name(for keyCode: Int) -> String {
        switch keyCode {
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "Enter"
        case kVK_Escape: return "Esc"
        case kVK_Tab: return "Tab"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_Grave: return "`"
        default: return "Key(\(keyCode))"
        }
    }
}

public struct HotkeyConfig: Codable, Equatable, Sendable {
    public var screenshot: HotkeyBinding
    public var windowCapture: HotkeyBinding
    public var longshotCapture: HotkeyBinding
    public var ocrCapture: HotkeyBinding
    public var translateSelection: HotkeyBinding
    public var translateCapture: HotkeyBinding
    public var pin: HotkeyBinding
    public var pinBorderToggle: HotkeyBinding
    public var recapture: HotkeyBinding
    public var longshot: HotkeyBinding
    public var ocr: HotkeyBinding

    public init(
        screenshot: HotkeyBinding = HotkeyBinding(keyCode: kVK_ANSI_A, modifiers: [.control]),
        windowCapture: HotkeyBinding = HotkeyBinding(keyCode: kVK_ANSI_S, modifiers: [.control]),
        longshotCapture: HotkeyBinding = HotkeyBinding(keyCode: kVK_ANSI_D, modifiers: [.control]),
        ocrCapture: HotkeyBinding = HotkeyBinding(keyCode: kVK_ANSI_F, modifiers: [.control]),
        translateSelection: HotkeyBinding = HotkeyBinding(keyCode: kVK_ANSI_D, modifiers: [.option]),
        translateCapture: HotkeyBinding = HotkeyBinding(keyCode: kVK_ANSI_S, modifiers: [.option]),
        pin: HotkeyBinding = HotkeyBinding(keyCode: kVK_F3, modifiers: []),
        pinBorderToggle: HotkeyBinding = HotkeyBinding(keyCode: kVK_F3, modifiers: [.control]),
        recapture: HotkeyBinding = HotkeyBinding(keyCode: kVK_F1, modifiers: [.shift]),
        longshot: HotkeyBinding = HotkeyBinding(keyCode: kVK_ANSI_S, modifiers: []),
        ocr: HotkeyBinding = HotkeyBinding(keyCode: kVK_ANSI_T, modifiers: [])
    ) {
        self.screenshot = screenshot
        self.windowCapture = windowCapture
        self.longshotCapture = longshotCapture
        self.ocrCapture = ocrCapture
        self.translateSelection = translateSelection
        self.translateCapture = translateCapture
        self.pin = pin
        self.pinBorderToggle = pinBorderToggle
        self.recapture = recapture
        self.longshot = longshot
        self.ocr = ocr
    }

    private enum CodingKeys: String, CodingKey {
        case screenshot, windowCapture, longshotCapture, ocrCapture, translateSelection, translateCapture
        case pin, pinBorderToggle, recapture, longshot, ocr
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = HotkeyConfig()
        let ss = try c.decodeIfPresent(HotkeyBinding.self, forKey: .screenshot) ?? defaults.screenshot
        let oc = try c.decodeIfPresent(HotkeyBinding.self, forKey: .ocrCapture) ?? defaults.ocrCapture
        let pn = try c.decodeIfPresent(HotkeyBinding.self, forKey: .pin) ?? defaults.pin
        let pb = try c.decodeIfPresent(HotkeyBinding.self, forKey: .pinBorderToggle) ?? defaults.pinBorderToggle
        self.screenshot = ss
        self.ocrCapture = oc
        self.pin = pn
        self.pinBorderToggle = pb
        if let decodedLS = try c.decodeIfPresent(HotkeyBinding.self, forKey: .longshotCapture) {
            self.longshotCapture = decodedLS
        } else {
            let existingGlobals = [ss, oc, pn, pb]
            self.longshotCapture = existingGlobals.contains(defaults.longshotCapture) ? .unbound : defaults.longshotCapture
        }
        if let decodedWC = try c.decodeIfPresent(HotkeyBinding.self, forKey: .windowCapture) {
            self.windowCapture = decodedWC
        } else {
            let existingGlobals = [ss, self.longshotCapture, oc, pn, pb]
            self.windowCapture = existingGlobals.contains(defaults.windowCapture) ? .unbound : defaults.windowCapture
        }
        // Preserve old custom bindings when adding the translation shortcuts.
        let existingGlobals = [ss, oc, pn, pb, self.longshotCapture, self.windowCapture]
        let decodedCapture = try c.decodeIfPresent(HotkeyBinding.self, forKey: .translateCapture)
        let decodedSelection = try c.decodeIfPresent(HotkeyBinding.self, forKey: .translateSelection)
        self.translateSelection = decodedSelection
            ?? ((existingGlobals + [decodedCapture ?? .unbound]).contains(defaults.translateSelection) ? .unbound : defaults.translateSelection)
        self.translateCapture = decodedCapture
            ?? ((existingGlobals + [self.translateSelection]).contains(defaults.translateCapture) ? .unbound : defaults.translateCapture)
        self.recapture = try c.decodeIfPresent(HotkeyBinding.self, forKey: .recapture) ?? defaults.recapture
        self.longshot = try c.decodeIfPresent(HotkeyBinding.self, forKey: .longshot) ?? defaults.longshot
        self.ocr = try c.decodeIfPresent(HotkeyBinding.self, forKey: .ocr) ?? defaults.ocr
    }
}

public enum LongshotScrollSpeed: String, Codable, CaseIterable, Sendable {
    case slow = "slow"
    case normal = "normal"
    case fast = "fast"

    public var title: String {
        title(in: L10n.current)
    }

    public func title(in lang: AppLanguage) -> String {
        switch self {
        case .slow: return lang.isEnglish ? "Slow" : "慢"
        case .normal: return lang.isEnglish ? "Standard" : "标准"
        case .fast: return lang.isEnglish ? "Fast" : "快"
        }
    }

    public var viewportStepFraction: Double {
        switch self {
        case .slow: return 0.62
        case .normal: return 0.78
        case .fast: return 0.85
        }
    }

    public var settleMilliseconds: UInt64 {
        switch self {
        case .slow: return 135
        case .normal: return 95
        case .fast: return 75
        }
    }

    public var next: LongshotScrollSpeed {
        switch self {
        case .slow: return .normal
        case .normal: return .fast
        case .fast: return .slow
        }
    }
}

public struct ToolKeysConfig: Codable, Equatable, Sendable {
    public var keys: [Int: HotkeyBinding]

    public init() {
        self.keys = [
            AnnotationTool.rect.rawValue: HotkeyBinding(keyCode: kVK_ANSI_1),
            AnnotationTool.arrow.rawValue: HotkeyBinding(keyCode: kVK_ANSI_2),
            AnnotationTool.text.rawValue: HotkeyBinding(keyCode: kVK_ANSI_3),
            AnnotationTool.highlight.rawValue: HotkeyBinding(keyCode: kVK_ANSI_4),
            AnnotationTool.blur.rawValue: HotkeyBinding(keyCode: kVK_ANSI_5),
            AnnotationTool.glow.rawValue: HotkeyBinding(keyCode: kVK_ANSI_6),
            AnnotationTool.number.rawValue: HotkeyBinding(keyCode: kVK_ANSI_7),
            AnnotationTool.line.rawValue: HotkeyBinding(keyCode: kVK_ANSI_8),
            AnnotationTool.ellipse.rawValue: HotkeyBinding(keyCode: kVK_ANSI_9),
            AnnotationTool.freehand.rawValue: HotkeyBinding(keyCode: kVK_ANSI_0),
        ]
    }

    public func binding(for tool: AnnotationTool) -> HotkeyBinding {
        keys[tool.rawValue] ?? .unbound
    }

    public mutating func setBinding(_ binding: HotkeyBinding, for tool: AnnotationTool) {
        keys[tool.rawValue] = binding
    }
}

public enum ThemeSetting: String, Codable, CaseIterable, Sendable {
    case follow
    case light
    case dark

    public var title: String {
        title(in: L10n.current)
    }

    public func title(in lang: AppLanguage) -> String {
        switch self {
        case .follow: return lang.isEnglish ? "System" : "跟随系统"
        case .light: return lang.isEnglish ? "Light" : "浅色"
        case .dark: return lang.isEnglish ? "Dark" : "深色"
        }
    }
}

public enum PinPosition: String, Codable, CaseIterable, Sendable {
    case original
    case center

    public var title: String {
        title(in: L10n.current)
    }

    public func title(in lang: AppLanguage) -> String {
        switch self {
        case .original: return lang.isEnglish ? "Original" : "原位置"
        case .center: return lang.isEnglish ? "Center" : "屏幕居中"
        }
    }
}

public enum NameStyle: String, Codable, CaseIterable, Sendable {
    case datetime
    case timestamp
    case date

    public var title: String {
        title(in: L10n.current)
    }

    public func title(in lang: AppLanguage) -> String {
        switch self {
        case .datetime: return lang.isEnglish ? "Date & Time" : "日期时间"
        case .timestamp: return lang.isEnglish ? "Timestamp" : "时间戳"
        case .date: return lang.isEnglish ? "Date Only" : "仅日期"
        }
    }

    public func formatBaseName(date: Date = Date()) -> String {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let y = comps.year ?? 2026
        let m = comps.month ?? 1
        let d = comps.day ?? 1
        let hh = comps.hour ?? 0
        let mm = comps.minute ?? 0
        let ss = comps.second ?? 0
        switch self {
        case .datetime:
            return String(format: "isnip-%04d%02d%02d-%02d%02d%02d", y, m, d, hh, mm, ss)
        case .timestamp:
            return "\(Int64(date.timeIntervalSince1970 * 1000.0))"
        case .date:
            return String(format: "isnip-%04d%02d%02d", y, m, d)
        }
    }
}

public enum PngCompressionQualityPreset: String, Codable, CaseIterable, Sendable {
    case visuallyLossless = "default"
    case balanced = "65-90"
    case compact = "45-75"

    public var title: String {
        title(in: L10n.current)
    }

    public func title(in lang: AppLanguage) -> String {
        switch self {
        case .visuallyLossless: return lang.isEnglish ? "Lossless" : "视觉无损"
        case .balanced: return lang.isEnglish ? "Balanced" : "均衡"
        case .compact: return lang.isEnglish ? "Compact" : "高压缩"
        }
    }

    public var shortTitle: String {
        title
    }

    public var qualityArgument: String? {
        switch self {
        case .visuallyLossless: return nil
        case .balanced: return "65-90"
        case .compact: return "45-75"
        }
    }
}

public enum UiScaleSetting: String, Codable, CaseIterable, Sendable {
    case auto = "auto"
    case p100 = "100"
    case p125 = "125"
    case p150 = "150"

    public var title: String {
        title(in: L10n.current)
    }

    public func title(in lang: AppLanguage) -> String {
        switch self {
        case .auto: return lang.isEnglish ? "Auto" : "自动"
        case .p100: return "100%"
        case .p125: return "125%"
        case .p150: return "150%"
        }
    }

    public var factor: Double {
        switch self {
        case .auto, .p100: return 1.0
        case .p125: return 1.25
        case .p150: return 1.5
        }
    }
}

public struct OcrConfig: Codable, Equatable, Sendable {
    public var autoCopy: Bool
    public var language: String // "auto", "zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"
    public var mergeLineBreaks: Bool
    public var detectBarcodes: Bool

    public init(
        autoCopy: Bool = false,
        language: String = "auto",
        mergeLineBreaks: Bool = false,
        detectBarcodes: Bool = true
    ) {
        self.autoCopy = autoCopy
        self.language = language
        self.mergeLineBreaks = mergeLineBreaks
        self.detectBarcodes = detectBarcodes
    }

    private enum CodingKeys: String, CodingKey {
        case autoCopy, language, mergeLineBreaks, detectBarcodes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.autoCopy = try c.decodeIfPresent(Bool.self, forKey: .autoCopy) ?? false
        self.language = try c.decodeIfPresent(String.self, forKey: .language) ?? "auto"
        self.mergeLineBreaks = try c.decodeIfPresent(Bool.self, forKey: .mergeLineBreaks) ?? false
        self.detectBarcodes = try c.decodeIfPresent(Bool.self, forKey: .detectBarcodes) ?? true
    }

    public static let supportedOptions: [(tag: String, label: String)] = [
        ("auto", "自动"),
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁体中文"),
        ("en-US", "English"),
        ("ja-JP", "日本語"),
        ("ko-KR", "한국어"),
    ]

    public static func supportedOptions(in lang: AppLanguage) -> [(tag: String, label: String)] {
        if lang.isEnglish {
            return [
                ("auto", "Auto"),
                ("zh-Hans", "Simplified Chinese"),
                ("zh-Hant", "Traditional Chinese"),
                ("en-US", "English"),
                ("ja-JP", "日本語"),
                ("ko-KR", "한국어"),
            ]
        }
        return supportedOptions
    }

    public static let compactOptions: [(tag: String, shortLabel: String)] = [
        ("auto", "自动"),
        ("zh-Hans", "简中"),
        ("zh-Hant", "繁中"),
        ("en-US", "English"),
        ("ja-JP", "日本語"),
        ("ko-KR", "한국어"),
    ]

    public static func compactOptions(in lang: AppLanguage) -> [(tag: String, shortLabel: String)] {
        if lang.isEnglish {
            return [
                ("auto", "Auto"),
                ("zh-Hans", "ZH-Hans"),
                ("zh-Hant", "ZH-Hant"),
                ("en-US", "English"),
                ("ja-JP", "日本語"),
                ("ko-KR", "한국어"),
            ]
        }
        return compactOptions
    }
}

public struct TranslationConfig: Codable, Equatable, Sendable {
    public var targetLanguage: String
    public var showSelectionButton: Bool

    public static let languageOptions: [(tag: String, label: String)] = [
        ("zh-Hans", "简体中文"), ("en", "English"), ("ja", "日本語"),
        ("ko", "한국어"), ("fr", "Français"), ("de", "Deutsch"), ("es", "Español"),
    ]

    public init(targetLanguage: String = "zh-Hans", showSelectionButton: Bool = false) {
        self.targetLanguage = Self.languageOptions.contains { $0.tag == targetLanguage } ? targetLanguage : "zh-Hans"
        self.showSelectionButton = showSelectionButton
    }

    private enum CodingKeys: String, CodingKey { case targetLanguage, showSelectionButton }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            targetLanguage: try c.decodeIfPresent(String.self, forKey: .targetLanguage) ?? "zh-Hans",
            showSelectionButton: try c.decodeIfPresent(Bool.self, forKey: .showSelectionButton) ?? false
        )
    }
}

public struct AirSnipConfig: Codable, Equatable, Sendable {
    public var autoStart: Bool
    public var language: AppLanguage
    public var theme: ThemeSetting
    public var hotkeys: HotkeyConfig
    public var hotkeyDefaultsMigratedV2: Bool
    public var toolKeys: ToolKeysConfig
    public var pinPosition: PinPosition
    public var pinBorder: Bool
    public var pinMaxCount: Int
    public var uiScale: UiScaleSetting
    public var swatchColors: [RGBAColor]
    public var activeColorIndex: Int
    public var lastTool: AnnotationTool
    public var defaultLineWidth: Double
    public var defaultFillEnabled: Bool
    public var defaultBlurRadius: Double
    public var defaultFontSize: Double
    public var defaultFontFamily: String
    public var defaultFontBold: Bool
    public var defaultFontItalic: Bool
    public var defaultNumberFontSize: Double
    public var styleDefaultsMigratedV2: Bool
    public var windowSnap: Bool
    public var windowCaptureShadow: Bool
    public var confirmCancel: Bool
    public var showCompletionToast: Bool
    public var toolbar: ToolbarConfig
    public var nameStyle: NameStyle
    public var lastSaveFormat: ExportImageFormat
    public var lastSaveDirectory: String?
    public var askBeforeSave: Bool
    public var smartPngCompression: Bool
    public var pngCompressionQuality: PngCompressionQualityPreset
    public var compressClipboardPng: Bool
    public var longshotMaxHeight: Int
    public var longshotAutoScroll: Bool
    public var longshotScrollSpeed: LongshotScrollSpeed
    public var autoCheckUpdate: Bool
    public var skippedVersion: String?
    public var ocr: OcrConfig
    public var translation: TranslationConfig

    public init(
        autoStart: Bool = false,
        language: AppLanguage = .system,
        theme: ThemeSetting = .follow,
        hotkeys: HotkeyConfig = HotkeyConfig(),
        hotkeyDefaultsMigratedV2: Bool = true,
        toolKeys: ToolKeysConfig = ToolKeysConfig(),
        pinPosition: PinPosition = .original,
        pinBorder: Bool = true,
        pinMaxCount: Int = 20,
        uiScale: UiScaleSetting = .auto,
        swatchColors: [RGBAColor] = ColorPalette.defaultSwatches,
        activeColorIndex: Int = 1,
        lastTool: AnnotationTool = .rect,
        defaultLineWidth: Double = 2.0,
        defaultFillEnabled: Bool = false,
        defaultBlurRadius: Double = 16.0,
        defaultFontSize: Double = 24.0,
        defaultFontFamily: String = "PingFang SC",
        defaultFontBold: Bool = false,
        defaultFontItalic: Bool = false,
        defaultNumberFontSize: Double = 20.0,
        styleDefaultsMigratedV2: Bool = true,
        windowSnap: Bool = true,
        windowCaptureShadow: Bool = true,
        confirmCancel: Bool = true,
        showCompletionToast: Bool = true,
        toolbar: ToolbarConfig = ToolbarConfig(),
        nameStyle: NameStyle = .datetime,
        lastSaveFormat: ExportImageFormat = .png,
        lastSaveDirectory: String? = nil,
        askBeforeSave: Bool = false,
        smartPngCompression: Bool = true,
        pngCompressionQuality: PngCompressionQualityPreset = .visuallyLossless,
        compressClipboardPng: Bool = true,
        longshotMaxHeight: Int = 30000,
        longshotAutoScroll: Bool = true,
        longshotScrollSpeed: LongshotScrollSpeed = .normal,
        autoCheckUpdate: Bool = true,
        skippedVersion: String? = nil,
        ocr: OcrConfig = OcrConfig(),
        translation: TranslationConfig = TranslationConfig()
    ) {
        self.autoStart = autoStart
        self.language = language
        self.theme = theme
        self.hotkeys = hotkeys
        self.hotkeyDefaultsMigratedV2 = hotkeyDefaultsMigratedV2
        self.toolKeys = toolKeys
        self.pinPosition = pinPosition
        self.pinBorder = pinBorder
        self.pinMaxCount = pinMaxCount
        self.uiScale = uiScale
        self.swatchColors = swatchColors.count == ColorPalette.swatchCount ? swatchColors : ColorPalette.defaultSwatches
        self.activeColorIndex = max(0, min(ColorPalette.swatchCount - 1, activeColorIndex))
        self.lastTool = lastTool
        self.defaultLineWidth = defaultLineWidth
        self.defaultFillEnabled = defaultFillEnabled
        self.defaultBlurRadius = defaultBlurRadius
        self.defaultFontSize = defaultFontSize
        self.defaultFontFamily = defaultFontFamily
        self.defaultFontBold = defaultFontBold
        self.defaultFontItalic = defaultFontItalic
        self.defaultNumberFontSize = defaultNumberFontSize
        self.styleDefaultsMigratedV2 = styleDefaultsMigratedV2
        self.windowSnap = windowSnap
        self.windowCaptureShadow = windowCaptureShadow
        self.confirmCancel = confirmCancel
        self.showCompletionToast = showCompletionToast
        self.toolbar = toolbar
        self.nameStyle = nameStyle
        self.lastSaveFormat = lastSaveFormat
        self.lastSaveDirectory = lastSaveDirectory
        self.askBeforeSave = askBeforeSave
        self.smartPngCompression = smartPngCompression
        self.pngCompressionQuality = pngCompressionQuality
        self.compressClipboardPng = compressClipboardPng
        self.longshotMaxHeight = max(2000, longshotMaxHeight)
        self.longshotAutoScroll = longshotAutoScroll
        self.longshotScrollSpeed = longshotScrollSpeed
        self.autoCheckUpdate = autoCheckUpdate
        self.skippedVersion = skippedVersion
        self.ocr = ocr
        self.translation = translation
    }

    private enum CodingKeys: String, CodingKey {
        case autoStart, language, theme, hotkeys, hotkeyDefaultsMigratedV2, toolKeys, pinPosition, pinBorder, pinMaxCount, uiScale
        case swatchColors, activeColorIndex, lastTool, defaultLineWidth, defaultFillEnabled
        case defaultBlurRadius, defaultFontSize, defaultFontFamily, defaultFontBold, defaultFontItalic, defaultNumberFontSize
        case styleDefaultsMigratedV2
        case windowSnap, windowCaptureShadow, confirmCancel, showCompletionToast
        case toolbar, nameStyle, lastSaveFormat, lastSaveDirectory, askBeforeSave
        case smartPngCompression, pngCompressionQuality, compressClipboardPng
        case longshotMaxHeight, longshotAutoScroll, longshotScrollSpeed
        case autoCheckUpdate, skippedVersion, ocr, translation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AirSnipConfig()
        self.autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? d.autoStart
        self.language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? d.language
        self.theme = try c.decodeIfPresent(ThemeSetting.self, forKey: .theme) ?? d.theme
        var decodedHotkeys = try c.decodeIfPresent(HotkeyConfig.self, forKey: .hotkeys) ?? d.hotkeys
        let hkMigratedV2 = try c.decodeIfPresent(Bool.self, forKey: .hotkeyDefaultsMigratedV2) ?? false
        if !hkMigratedV2 {
            let legacyF1 = HotkeyBinding(keyCode: kVK_F1, modifiers: [])
            let legacyF5 = HotkeyBinding(keyCode: kVK_F5, modifiers: [])
            let legacyF4 = HotkeyBinding(keyCode: kVK_F4, modifiers: [])
            let legacyF2 = HotkeyBinding(keyCode: kVK_F2, modifiers: [])
            let newCtrlA = HotkeyBinding(keyCode: kVK_ANSI_A, modifiers: [.control])
            let newCtrlS = HotkeyBinding(keyCode: kVK_ANSI_S, modifiers: [.control])
            let newCtrlD = HotkeyBinding(keyCode: kVK_ANSI_D, modifiers: [.control])
            let newCtrlF = HotkeyBinding(keyCode: kVK_ANSI_F, modifiers: [.control])

            func others(_ excludeIdx: Int) -> [HotkeyBinding] {
                let all = [
                    decodedHotkeys.screenshot,
                    decodedHotkeys.windowCapture,
                    decodedHotkeys.longshotCapture,
                    decodedHotkeys.ocrCapture,
                    decodedHotkeys.translateSelection,
                    decodedHotkeys.translateCapture,
                    decodedHotkeys.pin,
                    decodedHotkeys.pinBorderToggle,
                ]
                return all.enumerated().compactMap { idx, val in idx == excludeIdx ? nil : val }
            }

            if decodedHotkeys.screenshot == legacyF1 && !others(0).contains(newCtrlA) {
                decodedHotkeys.screenshot = newCtrlA
            }
            if decodedHotkeys.windowCapture == legacyF5 && !others(1).contains(newCtrlS) {
                decodedHotkeys.windowCapture = newCtrlS
            }
            if decodedHotkeys.longshotCapture == legacyF4 && !others(2).contains(newCtrlD) {
                decodedHotkeys.longshotCapture = newCtrlD
            }
            if decodedHotkeys.ocrCapture == legacyF2 && !others(3).contains(newCtrlF) {
                decodedHotkeys.ocrCapture = newCtrlF
            }
        }
        self.hotkeys = decodedHotkeys
        self.hotkeyDefaultsMigratedV2 = true
        self.toolKeys = try c.decodeIfPresent(ToolKeysConfig.self, forKey: .toolKeys) ?? d.toolKeys
        self.pinPosition = try c.decodeIfPresent(PinPosition.self, forKey: .pinPosition) ?? d.pinPosition
        self.pinBorder = try c.decodeIfPresent(Bool.self, forKey: .pinBorder) ?? d.pinBorder
        self.pinMaxCount = try c.decodeIfPresent(Int.self, forKey: .pinMaxCount) ?? d.pinMaxCount
        self.uiScale = try c.decodeIfPresent(UiScaleSetting.self, forKey: .uiScale) ?? d.uiScale
        let alreadyMigratedV2 = try c.decodeIfPresent(Bool.self, forKey: .styleDefaultsMigratedV2) ?? false
        var decodedSwatches = try c.decodeIfPresent([RGBAColor].self, forKey: .swatchColors) ?? d.swatchColors
        if decodedSwatches.count != ColorPalette.swatchCount {
            decodedSwatches = ColorPalette.defaultSwatches
        } else if !alreadyMigratedV2 && decodedSwatches[1] == RGBAColor(r: 229, g: 57, b: 53) {
            decodedSwatches[1] = RGBAColor(r: 255, g: 0, b: 0)
        }
        self.swatchColors = decodedSwatches
        self.activeColorIndex = max(0, min(ColorPalette.swatchCount - 1, try c.decodeIfPresent(Int.self, forKey: .activeColorIndex) ?? d.activeColorIndex))
        self.lastTool = try c.decodeIfPresent(AnnotationTool.self, forKey: .lastTool) ?? d.lastTool
        let rawLineWidth = try c.decodeIfPresent(Double.self, forKey: .defaultLineWidth)
        if !alreadyMigratedV2 && rawLineWidth == 4.0 {
            self.defaultLineWidth = 2.0
        } else {
            self.defaultLineWidth = rawLineWidth ?? d.defaultLineWidth
        }
        self.defaultFillEnabled = try c.decodeIfPresent(Bool.self, forKey: .defaultFillEnabled) ?? d.defaultFillEnabled
        self.defaultBlurRadius = try c.decodeIfPresent(Double.self, forKey: .defaultBlurRadius) ?? d.defaultBlurRadius
        self.defaultFontSize = try c.decodeIfPresent(Double.self, forKey: .defaultFontSize) ?? d.defaultFontSize
        self.defaultFontFamily = try c.decodeIfPresent(String.self, forKey: .defaultFontFamily) ?? d.defaultFontFamily
        self.defaultFontBold = try c.decodeIfPresent(Bool.self, forKey: .defaultFontBold) ?? d.defaultFontBold
        self.defaultFontItalic = try c.decodeIfPresent(Bool.self, forKey: .defaultFontItalic) ?? d.defaultFontItalic
        self.defaultNumberFontSize = try c.decodeIfPresent(Double.self, forKey: .defaultNumberFontSize) ?? d.defaultNumberFontSize
        self.styleDefaultsMigratedV2 = true
        self.windowSnap = try c.decodeIfPresent(Bool.self, forKey: .windowSnap) ?? d.windowSnap
        self.windowCaptureShadow = try c.decodeIfPresent(Bool.self, forKey: .windowCaptureShadow) ?? d.windowCaptureShadow
        self.confirmCancel = try c.decodeIfPresent(Bool.self, forKey: .confirmCancel) ?? d.confirmCancel
        self.showCompletionToast = try c.decodeIfPresent(Bool.self, forKey: .showCompletionToast) ?? d.showCompletionToast
        self.toolbar = try c.decodeIfPresent(ToolbarConfig.self, forKey: .toolbar) ?? d.toolbar
        self.nameStyle = try c.decodeIfPresent(NameStyle.self, forKey: .nameStyle) ?? d.nameStyle
        self.lastSaveFormat = try c.decodeIfPresent(ExportImageFormat.self, forKey: .lastSaveFormat) ?? d.lastSaveFormat
        self.lastSaveDirectory = try c.decodeIfPresent(String.self, forKey: .lastSaveDirectory)
        self.askBeforeSave = try c.decodeIfPresent(Bool.self, forKey: .askBeforeSave) ?? false
        self.smartPngCompression = try c.decodeIfPresent(Bool.self, forKey: .smartPngCompression) ?? true
        self.pngCompressionQuality = try c.decodeIfPresent(PngCompressionQualityPreset.self, forKey: .pngCompressionQuality) ?? .visuallyLossless
        self.compressClipboardPng = try c.decodeIfPresent(Bool.self, forKey: .compressClipboardPng) ?? true
        self.longshotMaxHeight = max(2000, min(100000, try c.decodeIfPresent(Int.self, forKey: .longshotMaxHeight) ?? d.longshotMaxHeight))
        self.longshotAutoScroll = try c.decodeIfPresent(Bool.self, forKey: .longshotAutoScroll) ?? d.longshotAutoScroll
        self.longshotScrollSpeed = try c.decodeIfPresent(LongshotScrollSpeed.self, forKey: .longshotScrollSpeed) ?? d.longshotScrollSpeed
        self.autoCheckUpdate = try c.decodeIfPresent(Bool.self, forKey: .autoCheckUpdate) ?? d.autoCheckUpdate
        self.skippedVersion = try c.decodeIfPresent(String.self, forKey: .skippedVersion)
        self.ocr = try c.decodeIfPresent(OcrConfig.self, forKey: .ocr) ?? d.ocr
        self.translation = try c.decodeIfPresent(TranslationConfig.self, forKey: .translation) ?? d.translation
    }

    public static func defaultConfigFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("iSnip", isDirectory: true).appendingPathComponent("config.json")
    }

    public static func legacyConfigFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AirSnip", isDirectory: true).appendingPathComponent("config.json")
    }

    public static func load(from url: URL = defaultConfigFileURL()) -> AirSnipConfig {
        let fm = FileManager.default
        if url == defaultConfigFileURL(), !fm.fileExists(atPath: url.path) {
            let legacy = legacyConfigFileURL()
            if fm.fileExists(atPath: legacy.path) {
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: legacy, to: url)
            }
        }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AirSnipConfig.self, from: data) else {
            return AirSnipConfig()
        }
        var sanitized = decoded
        if sanitized.swatchColors.count != ColorPalette.swatchCount {
            sanitized.swatchColors = ColorPalette.defaultSwatches
        }
        sanitized.activeColorIndex = max(0, min(ColorPalette.swatchCount - 1, sanitized.activeColorIndex))
        sanitized.pinMaxCount = max(1, min(50, sanitized.pinMaxCount))
        sanitized.longshotMaxHeight = max(2000, min(100000, sanitized.longshotMaxHeight))
        if let rawObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           ((rawObj["styleDefaultsMigratedV2"] as? Bool) != true || (rawObj["hotkeyDefaultsMigratedV2"] as? Bool) != true) {
            try? sanitized.save(to: url)
        }
        L10n.current = sanitized.language
        return sanitized
    }

    public func save(to url: URL = Self.defaultConfigFileURL()) throws {
        L10n.current = self.language
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// Detects duplicate bindings within global scope or within overlay scope.
    public func hotkeyConflicts(in lang: AppLanguage? = nil) -> [String] {
        let l = lang ?? self.language
        var conflicts: [String] = []
        let globalList: [(String, HotkeyBinding)] = [
            (L10n.tr("截图", "Capture Area", in: l), hotkeys.screenshot),
            (L10n.tr("窗体截图", "Capture Window", in: l), hotkeys.windowCapture),
            (L10n.tr("页面长截图", "Scrolling Capture", in: l), hotkeys.longshotCapture),
            (L10n.tr("截图识字", "Capture & OCR", in: l), hotkeys.ocrCapture),
            (L10n.tr("划词翻译", "Translate Selection", in: l), hotkeys.translateSelection),
            (L10n.tr("截图翻译", "Capture & Translate", in: l), hotkeys.translateCapture),
            (L10n.tr("贴图", "Pin", in: l), hotkeys.pin),
            (L10n.tr("贴图边框", "Pin Border", in: l), hotkeys.pinBorderToggle),
        ]
        for i in 0..<globalList.count {
            for j in (i + 1)..<globalList.count {
                if !globalList[i].1.isUnbound && globalList[i].1 == globalList[j].1 {
                    let keyStr = globalList[i].1.displayString(in: l)
                    if l.isEnglish {
                        conflicts.append("\(globalList[i].0) conflicts with \(globalList[j].0) (\(keyStr))")
                    } else {
                        conflicts.append("\(globalList[i].0) 与 \(globalList[j].0) 冲突（\(keyStr)）")
                    }
                }
            }
        }

        var overlayList: [(String, HotkeyBinding)] = [
            (L10n.tr("重新抓屏", "Recapture", in: l), hotkeys.recapture),
            (L10n.tr("长截图", "Longshot", in: l), hotkeys.longshot),
            ("OCR", hotkeys.ocr),
        ]
        for tool in AnnotationTool.allOrdered {
            overlayList.append((tool.shortLabel(in: l), toolKeys.binding(for: tool)))
        }
        for i in 0..<overlayList.count {
            for j in (i + 1)..<overlayList.count {
                if !overlayList[i].1.isUnbound && overlayList[i].1 == overlayList[j].1 {
                    let keyStr = overlayList[i].1.displayString(in: l)
                    if l.isEnglish {
                        conflicts.append("\(overlayList[i].0) conflicts with \(overlayList[j].0) (\(keyStr))")
                    } else {
                        conflicts.append("\(overlayList[i].0) 与 \(overlayList[j].0) 冲突（\(keyStr)）")
                    }
                }
            }
        }
        return conflicts
    }
}

public enum ReleaseAssetSelector {
    public static var currentArchTag: String {
        #if arch(x86_64)
        return "amd64"
        #else
        return "arm64"
        #endif
    }

    public static func selectDownloadURL(
        assets: [(name: String, url: String)],
        arch: String = currentArchTag
    ) -> URL? {
        let normalized = arch.lowercased()
        let dmgAssets = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        guard !dmgAssets.isEmpty else { return nil }

        let isAmd64Name: (String) -> Bool = { n in
            n.contains("amd64") || n.contains("x86_64") || n.contains("x64") || n.contains("intel")
        }
        let isArm64Name: (String) -> Bool = { n in
            n.contains("arm64") || n.contains("aarch64")
        }

        if normalized == "amd64" || normalized == "x86_64" {
            if let hit = dmgAssets.first(where: { isAmd64Name($0.name.lowercased()) }),
               let url = URL(string: hit.url) {
                return url
            }
            if let uni = dmgAssets.first(where: { $0.name.lowercased().contains("universal") }),
               let url = URL(string: uni.url) {
                return url
            }
            return nil
        } else {
            if let hit = dmgAssets.first(where: { isArm64Name($0.name.lowercased()) }),
               let url = URL(string: hit.url) {
                return url
            }
            if let uni = dmgAssets.first(where: { $0.name.lowercased().contains("universal") }),
               let url = URL(string: uni.url) {
                return url
            }
            if let fallback = dmgAssets.first(where: { !isAmd64Name($0.name.lowercased()) }),
               let url = URL(string: fallback.url) {
                return url
            }
            return nil
        }
    }
}
