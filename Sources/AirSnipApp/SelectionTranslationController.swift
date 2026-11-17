import AppKit
import ApplicationServices

enum SelectedTextService {
    enum SelectionError: LocalizedError {
        case permissionRequired
        case noSelection

        var errorDescription: String? {
            switch self {
            case .permissionRequired: return "请在「系统设置 → 隐私与安全性 → 辅助功能」中允许 iSnip 读取选中文字。"
            case .noSelection: return "未读取到选中文字；请先选中文字，或使用「截图翻译」。"
            }
        }
    }

    @discardableResult
    static func requestAccess() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    static func readSelection(processID: pid_t) throws -> String {
        guard AXIsProcessTrusted() else { throw SelectionError.permissionRequired }
        guard processID != ProcessInfo.processInfo.processIdentifier else { throw SelectionError.noSelection }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let focused = attribute(kAXFocusedUIElementAttribute, of: app),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            throw SelectionError.noSelection
        }
        var element = unsafeBitCast(focused, to: AXUIElement.self)
        for _ in 0..<6 {
            AXUIElementSetMessagingTimeout(element, 0.2)
            let role = attribute(kAXRoleAttribute, of: element) as? String
            let subrole = attribute(kAXSubroleAttribute, of: element) as? String
            guard role != kAXSecureTextFieldSubrole, subrole != kAXSecureTextFieldSubrole else {
                throw SelectionError.noSelection
            }
            if let selected = attribute(kAXSelectedTextAttribute, of: element) as? String,
               !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return selected.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let range = attribute(kAXSelectedTextRangeAttribute, of: element),
               CFGetTypeID(range) == AXValueGetTypeID() {
                let value = unsafeBitCast(range, to: AXValue.self)
                var selectedRange = CFRange()
                if AXValueGetType(value) == .cfRange,
                   AXValueGetValue(value, .cfRange, &selectedRange),
                   selectedRange.location >= 0, selectedRange.length > 0 {
                    var result: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, value, &result) == .success,
                       let text = result as? String,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
            guard let parent = attribute(kAXParentAttribute, of: element),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = unsafeBitCast(parent, to: AXUIElement.self)
        }
        throw SelectionError.noSelection
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

@MainActor
final class SelectionTranslationController {
    var onTranslate: ((String, NSPoint) -> Void)?
    var canShowButton: (() -> Bool)?
    private var monitor: Any?
    private var selectionTask: Task<Void, Never>?
    private var mouseDownPoint: NSPoint?
    private var panel: NSPanel?
    private var selectedText = ""
    private var selectedProcessID: pid_t?

    func setEnabled(_ enabled: Bool) {
        selectionTask?.cancel()
        panel?.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard enabled else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouse(event) }
        }
    }

    private func handleMouse(_ event: NSEvent) {
        if event.type != .leftMouseDown && event.type != .leftMouseUp {
            selectionTask?.cancel()
            panel?.orderOut(nil)
            mouseDownPoint = nil
            return
        }
        if event.type == .leftMouseDown {
            selectionTask?.cancel()
            panel?.orderOut(nil)
            mouseDownPoint = NSEvent.mouseLocation
            return
        }
        guard let start = mouseDownPoint else { return }
        mouseDownPoint = nil
        let end = NSEvent.mouseLocation
        guard hypot(end.x - start.x, end.y - start.y) >= 4 || event.clickCount >= 2,
              AXIsProcessTrusted(), canShowButton?() != false,
              let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        selectionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self, self.canShowButton?() != false,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let text = try? SelectedTextService.readSelection(processID: pid) else { return }
            self.selectedText = text
            self.selectedProcessID = pid
            self.showButton(near: end)
        }
    }

    private func showButton(near point: NSPoint) {
        let size = NSSize(width: 70, height: 30)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let bounds = screen?.visibleFrame else { return }
        let frame = NSRect(
            x: max(bounds.minX + 6, min(point.x + 10, bounds.maxX - size.width - 6)),
            y: max(bounds.minY + 6, min(point.y - size.height - 8, bounds.maxY - size.height - 6)),
            width: size.width, height: size.height
        )
        if panel == nil {
            let bubble = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            bubble.hidesOnDeactivate = false
            bubble.level = .floating
            bubble.isOpaque = false
            bubble.backgroundColor = .clear
            bubble.hasShadow = true
            bubble.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let button = NSButton(title: "翻译", target: self, action: #selector(translateSelection))
            button.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: nil)
            button.bezelStyle = .rounded
            button.frame = NSRect(origin: .zero, size: size)
            button.toolTip = "翻译选中文字"
            button.setAccessibilityLabel("翻译选中文字")
            bubble.contentView = button
            panel = bubble
        }
        panel?.setFrame(frame, display: true)
        panel?.orderFrontRegardless()
    }

    @objc private func translateSelection() {
        panel?.orderOut(nil)
        guard !selectedText.isEmpty,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == selectedProcessID else { return }
        onTranslate?(selectedText, NSEvent.mouseLocation)
    }
}
