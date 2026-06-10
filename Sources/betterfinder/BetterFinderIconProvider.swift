import AppKit
import Foundation

public enum BetterFinderIconProvider {
    private static let cache = BetterFinderIconCache()

    public static func icon(
        for action: BetterFinderMenuEntryAction,
        style: BetterFinderIconStyle
    ) -> NSImage? {
        guard style != .none else { return nil }

        let cacheKey = "\(style.rawValue):\(action.identifier)"
        if let cached = cache.image(for: cacheKey) {
            return cached
        }

        let image: NSImage?
        switch action {
        case .copyPath:
            image = symbol(style == .original ? "doc.on.clipboard.fill" : "doc.on.clipboard")
        case .open(let app):
            if style == .original,
               let bundleURL = BetterFinderApplicationCatalog.bundleURL(for: app) {
                let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
                icon.size = NSSize(width: 18, height: 18)
                image = icon
            } else {
                let symbolName = app.type == .terminal ? "terminal" : "square.and.pencil"
                image = symbol(symbolName)
            }
        }

        if let image {
            cache.set(image, for: cacheKey)
        }
        return image
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        return image
    }
}

private final class BetterFinderIconCache: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: NSImage] = [:]

    func image(for key: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[key]
    }

    func set(_ image: NSImage, for key: String) {
        lock.lock()
        images[key] = image
        lock.unlock()
    }
}
