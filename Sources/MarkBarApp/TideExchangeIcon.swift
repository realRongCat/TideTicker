import AppKit
import MarkBarCore

/// Local exchange brand marks used as source identifiers in the settings UI.
@MainActor
enum TideExchangeIcon {
    private static let cache = NSCache<NSString, NSImage>()

    private static let resourceRoot: URL? = {
        if let root = Bundle.main.url(forResource: "ExchangeIcons", withExtension: nil) { return root }
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
        for parent in candidates {
            let bundleURL = parent.appendingPathComponent("TideTicker_MarkBarApp.bundle")
            if let bundle = Bundle(url: bundleURL),
               let root = bundle.url(forResource: "ExchangeIcons", withExtension: nil) { return root }
        }
        return nil
    }()

    static func image(for exchange: Exchange) -> NSImage? {
        let key = exchange.rawValue as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let url = resourceRoot?
            .appendingPathComponent(exchange.rawValue)
            .appendingPathExtension("png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.accessibilityDescription = "\(exchange.title) Logo"
        cache.setObject(image, forKey: key)
        return image
    }
}
