import AppKit

/// One local icon catalogue for SwiftUI, native menus and compact menu-bar rows.
/// Icons are decorative: the complete contract symbol and identity stay intact.
@MainActor
enum TideCoinIcon {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 384
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

    private static let resourceRoot: URL? = {
        if let root = Bundle.main.url(forResource: "CoinIcons", withExtension: nil) { return root }
        // SwiftPM command-line builds use a resource bundle beside the binary.
        // Resolve it optionally so missing resources never make the app crash.
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
        for parent in candidates {
            let bundleURL = parent.appendingPathComponent("TideTicker_MarkBarApp.bundle")
            if let bundle = Bundle(url: bundleURL),
               let root = bundle.url(forResource: "CoinIcons", withExtension: nil) { return root }
        }
        return nil
    }()

    private static let symbols: [String: Set<String>] = {
        guard let url = resourceRoot?.appendingPathComponent("manifest.json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return manifest.mapValues { Set($0) }
    }()

    static func image(for symbol: String, size: CGFloat) -> NSImage {
        asset(for: symbol, variant: "background", size: size) ?? placeholder(for: symbol, size: size)
    }

    /// No shortened or stripped symbol fallback in the compact menu bar.
    static func compactImage(for symbol: String, size: CGFloat) -> NSImage? {
        asset(for: symbol, variant: "mono", size: size)
    }

    private static func asset(for symbol: String, variant: String, size: CGFloat) -> NSImage? {
        guard symbols[variant]?.contains(symbol) == true, let resourceRoot else { return nil }
        let key = "\(variant):\(size):\(symbol)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let url = resourceRoot.appendingPathComponent(variant).appendingPathComponent(symbol).appendingPathExtension("svg")
        guard let source = NSImage(contentsOf: url) else { return nil }
        source.size = NSSize(width: size, height: size)
        // Rasterize once at 2x, rather than parsing/drawing the SVG on quote ticks.
        // A black alpha mask also makes mono assets consistent with native templates.
        let pixels = Int(ceil(size * 2))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        let rect = NSRect(origin: .zero, size: source.size)
        if variant == "background" { NSBezierPath(ovalIn: rect).addClip() }
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        if variant == "mono" {
            NSColor.black.setFill()
            rect.fill(using: .sourceAtop)
        }
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = source.size
        let image = NSImage(size: source.size)
        image.addRepresentation(bitmap)
        image.isTemplate = variant == "mono"
        image.accessibilityDescription = "\(symbol) 币种图标"
        cache.setObject(image, forKey: key, cost: pixels * pixels * 4)
        return image
    }

    private static func placeholder(for symbol: String, size: CGFloat) -> NSImage {
        let key = "placeholder:\(size):\(symbol)" as NSString
        if let image = cache.object(forKey: key) { return image }
        // A neutral code badge is visibly a fallback, not an invented token logo.
        // Keep the full symbol in the surrounding row, including quantity prefixes.
        let code: String
        if symbol.count <= 4 { code = symbol }
        else if symbol.count <= 10 {
            let split = symbol.index(symbol.startIndex, offsetBy: (symbol.count + 1) / 2)
            code = String(symbol[..<split]) + "\n" + String(symbol[split...])
        } else { code = String(symbol.prefix(4)) + "\n" + String(symbol.suffix(4)) }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(calibratedWhite: 0.43, alpha: 0.18).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            let fontSize = size * (code.contains("\n") ? 0.25 : (code.count > 2 ? 0.31 : 0.40))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
            let textSize = (code as NSString).size(withAttributes: attributes)
            (code as NSString).draw(in: NSRect(x: 1, y: (size - textSize.height) / 2, width: size - 2, height: textSize.height),
                                   withAttributes: attributes)
            return true
        }
        image.accessibilityDescription = "\(symbol)（暂无币种图标）"
        cache.setObject(image, forKey: key)
        return image
    }
}
