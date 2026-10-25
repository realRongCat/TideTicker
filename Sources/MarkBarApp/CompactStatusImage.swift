import AppKit
import CoreText

/// A template image lets the status button supply the correct menu-bar tint,
/// including its highlighted state, while keeping native menu interaction.
@MainActor
enum CompactStatusImage {
    struct Row: Equatable {
        let symbol: String
        let displaySymbol: String
        let price: String
        let isStale: Bool
        let possiblyMissed: Bool

        init(symbol: String, displaySymbol: String? = nil, price: String,
             isStale: Bool, possiblyMissed: Bool = false) {
            self.symbol = symbol
            self.displaySymbol = displaySymbol ?? symbol
            self.price = price
            self.isStale = isStale
            self.possiblyMissed = possiblyMissed
        }

        var hasWarning: Bool { isStale || possiblyMissed }
        var text: String { "\(displaySymbol) \(price)\(hasWarning ? " !" : "")" }
    }

    static let fontSize: CGFloat = 9
    static let height: CGFloat = 20
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
    private static let gap: CGFloat = 3
    private static let warningWidth: CGFloat = 4
    private static let iconWidth: CGFloat = 10
    private static let iconSize: CGFloat = 8

    private static var lastRows: [Row]?
    private static var lastShowIcons = false
    private static var lastImage: NSImage?

    static func make(rows: [Row], showIcons: Bool = false) -> NSImage {
        let rows = Array(rows.prefix(2))
        if rows == lastRows, showIcons == lastShowIcons, let lastImage { return lastImage }
        let icons = rows.map { showIcons ? TideCoinIcon.compactImage(for: $0.symbol, size: iconSize) : nil }
        // Missing mono assets retain the complete symbol, including unit prefixes.
        let symbolWidth = ceil(rows.indices.map { index in
            icons[index] != nil ? iconWidth : width(of: rows[index].displaySymbol)
        }.max() ?? 0)
        // Reserve the usual BTC price width even while loading. Wider prices
        // can expand it, while ordinary ticks and warnings keep a stable width.
        let priceWidth = ceil(max(width(of: "88,888.88"), rows.map { width(of: $0.price) }.max() ?? 0))
        let size = NSSize(width: symbolWidth + gap + priceWidth + warningWidth, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.textMatrix = .identity
            for (index, row) in rows.prefix(2).enumerated() {
                let baseline: CGFloat = index == 0 ? 12.5 : 2.5
                let color = NSColor.black.withAlphaComponent(row.isStale ? 0.45 : 1)
                if let icon = icons[index] {
                    icon.draw(in: NSRect(x: (iconWidth - iconSize) / 2,
                                         y: baseline + (font.capHeight - iconSize) / 2,
                                         width: iconSize, height: iconSize),
                              from: .zero, operation: .sourceOver, fraction: row.isStale ? 0.45 : 1)
                } else {
                    draw(row.displaySymbol, at: CGPoint(x: 0, y: baseline), color: color, in: context)
                }
                draw(row.price, at: CGPoint(x: symbolWidth + gap + priceWidth - width(of: row.price), y: baseline), color: color, in: context)
                if row.hasWarning {
                    draw("!", at: CGPoint(x: size.width - warningWidth + 1, y: baseline), color: color, in: context)
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = rows.map(\.text).joined(separator: ", ")
        lastRows = rows
        lastShowIcons = showIcons
        lastImage = image
        return image
    }

    private static func width(of text: String) -> CGFloat {
        CTLineGetTypographicBounds(line(text, color: .black), nil, nil, nil)
    }

    private static func line(_ text: String, color: NSColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
        ]))
    }

    private static func draw(_ text: String, at point: CGPoint, color: NSColor, in context: CGContext) {
        context.textPosition = point
        CTLineDraw(line(text, color: color), context)
    }
}
