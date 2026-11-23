import AppKit

public extension RGBAColor {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}

/// A shared TextKit container for inline editing and rendering committed text.
public final class AnnotationTextLayout {
    public let container: NSTextContainer
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()

    public init(wrappingWidth: Double?) {
        container = NSTextContainer(size: NSSize(
            width: max(1, wrappingWidth ?? .greatestFiniteMagnitude),
            height: .greatestFiniteMagnitude
        ))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
    }

    func setText(_ text: String, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        storage.setAttributedString(NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        ))
    }

    var size: NSSize {
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return NSSize(width: max(1, used.maxX), height: used.maxY)
    }

    func draw(in context: CGContext, at origin: ASPoint) {
        let glyphs = layoutManager.glyphRange(for: container)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin.cgPoint)
        NSGraphicsContext.restoreGraphicsState()
    }
}
