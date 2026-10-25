import AppKit

/// Keep native menu tracking, keyboard navigation and accessibility. Formatting
/// adds hierarchy without hosting a SwiftUI tree in each live quote row.
@MainActor
enum TideMenuStyle {
    private static var icons: [String: NSImage] = [:]

    static func icon(_ name: String, color: NSColor? = nil) -> NSImage? {
        let key = name + (color?.description ?? "template")
        if let cached = icons[key] { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        let result = color.flatMap { image?.withSymbolConfiguration(.init(paletteColors: [$0])) } ?? image
        if let result { icons[key] = result }
        return result
    }

    static func columns(_ leading: String, _ trailing: String, emphasized: Bool = false,
                        muted: Bool = false) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        // Native menu sizing still expands for the longest complete contract ID.
        let leadingFont = NSFont.systemFont(ofSize: 13, weight: emphasized ? .semibold : .regular)
        let trailingFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: emphasized ? .semibold : .regular)
        let leadingWidth = (leading as NSString).size(withAttributes: [.font: leadingFont]).width
        let trailingWidth = (trailing as NSString).size(withAttributes: [.font: trailingFont]).width
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: max(208, leadingWidth + trailingWidth + 24))]
        let result = NSMutableAttributedString(string: leading + "\t" + trailing, attributes: [
            .font: NSFont.menuFont(ofSize: 13), .paragraphStyle: paragraph,
        ])
        result.addAttribute(.font, value: leadingFont,
                            range: NSRange(location: 0, length: (leading as NSString).length))
        result.addAttributes([
            .font: trailingFont,
            .foregroundColor: muted ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ], range: NSRange(location: (leading as NSString).length + 1, length: (trailing as NSString).length))
        return result
    }

    /// Explicit attributed paragraphs work on macOS 13 as well. A plain title
    /// containing newlines does not reliably increase the native menu row height.
    static func setQuote(_ item: NSMenuItem, symbol: String, price: String,
                         notes: [String], muted: Bool) {
        let title = ([symbol + "\t" + price] + notes).joined(separator: "\n")
        guard item.attributedTitle?.string != title else { return }
        let result = NSMutableAttributedString(attributedString: columns(symbol, price, emphasized: true, muted: muted))
        appendNotes(notes, to: result)
        item.attributedTitle = result
    }

    static func setStacked(_ item: NSMenuItem, title: String, detail: String, heading: Bool = false) {
        let text = title + "\n" + detail
        guard item.attributedTitle?.string != text else { return }
        let result = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: heading ? 12 : 13, weight: heading ? .medium : .regular),
            .foregroundColor: heading ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        appendNotes([detail], to: result)
        item.attributedTitle = result
    }

    private static func appendNotes(_ notes: [String], to title: NSMutableAttributedString) {
        guard !notes.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 2
        title.append(NSAttributedString(string: "\n" + notes.joined(separator: "\n"), attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]))
    }

    static func setColumns(_ item: NSMenuItem, _ leading: String, _ trailing: String,
                           emphasized: Bool = false, muted: Bool = false) {
        // AppKit mirrors attributedTitle.string back into title (including tabs).
        guard item.attributedTitle?.string != leading + "\t" + trailing else { return }
        item.title = leading + "  " + trailing
        item.attributedTitle = columns(leading, trailing, emphasized: emphasized, muted: muted)
    }
}
