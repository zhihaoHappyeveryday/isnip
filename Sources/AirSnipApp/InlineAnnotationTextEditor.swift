import AppKit
import AirSnipCore

@MainActor
final class InlineAnnotationTextEditor: NSView, NSTextViewDelegate {
    override var isFlipped: Bool { true }

    let textView: NSTextView
    var onCancel: (() -> Void)?
    private let layout: AnnotationTextLayout

    init(origin: NSPoint, clip: NSRect, wrappingWidth: Double?, text: String, font: NSFont, color: NSColor) {
        layout = AnnotationTextLayout(wrappingWidth: wrappingWidth)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        textView = NSTextView(
            frame: NSRect(x: origin.x - clip.minX, y: origin.y - clip.minY, width: 1, height: lineHeight),
            textContainer: layout.container
        )
        super.init(frame: clip)

        clipsToBounds = true
        textView.delegate = self
        textView.drawsBackground = false
        textView.isRichText = false
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 1, height: lineHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.font = font
        textView.textColor = color
        textView.alignment = .left
        textView.insertionPointColor = .controlAccentColor
        textView.string = text
        textView.sizeToFit()
        addSubview(textView)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point), let hit = super.hitTest(point), hit !== self else { return nil }
        return hit
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(cancelOperation(_:)), !textView.hasMarkedText() else { return false }
        onCancel?()
        return true
    }
}
