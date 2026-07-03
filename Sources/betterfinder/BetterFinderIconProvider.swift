import AppKit
import Foundation

public enum BetterFinderIconProvider {
    private static let cache = BetterFinderIconCache()
    private static let warmQueue = DispatchQueue(
        label: "com.velto.betterfinder.icon-warm",
        qos: .userInitiated
    )

    /// 菜单构建专用:**绝不阻塞**。`.original` 风格需要查 LaunchServices/IconServices
    /// (两次跨进程 RPC,冷缓存时可达数百 ms),而 menu(for:) 是 Finder 同步等待的回调,
    /// 在里面等图标就是"正在等待…"。未命中缓存时先回轻量 SF Symbol,后台补真图标,
    /// 下次开菜单即命中。
    public static func menuIcon(
        for action: BetterFinderMenuEntryAction,
        style: BetterFinderIconStyle
    ) -> NSImage? {
        guard style != .none else { return nil }
        if let cached = cache.image(for: cacheKey(action, style)) {
            return cached
        }
        warmQueue.async { _ = icon(for: action, style: style) }
        return placeholderSymbol(for: action, style: style)
    }

    /// 后台预热:把一组动作的图标提前灌进缓存(扩展启动时调用,进程被系统回收后
    /// 重启也能在首次开菜单前备好)。
    public static func warmUp(
        actions: [BetterFinderMenuEntryAction],
        style: BetterFinderIconStyle
    ) {
        guard style != .none else { return }
        warmQueue.async {
            for action in actions {
                _ = icon(for: action, style: style)
            }
        }
    }

    public static func icon(
        for action: BetterFinderMenuEntryAction,
        style: BetterFinderIconStyle
    ) -> NSImage? {
        guard style != .none else { return nil }

        let cacheKey = cacheKey(action, style)
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

    private static func cacheKey(
        _ action: BetterFinderMenuEntryAction,
        _ style: BetterFinderIconStyle
    ) -> String {
        "\(style.rawValue):\(action.identifier)"
    }

    /// 缓存未命中时的即时占位(纯 SF Symbol,无跨进程调用)。不写入缓存,
    /// 以免挡住后台补上的真图标。
    private static func placeholderSymbol(
        for action: BetterFinderMenuEntryAction,
        style: BetterFinderIconStyle
    ) -> NSImage? {
        switch action {
        case .copyPath:
            return symbol(style == .original ? "doc.on.clipboard.fill" : "doc.on.clipboard")
        case .open(let app):
            return symbol(app.type == .terminal ? "terminal" : "square.and.pencil")
        }
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
