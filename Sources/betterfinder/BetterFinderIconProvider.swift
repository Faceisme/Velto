import AppKit
import Foundation

public enum BetterFinderIconProvider {
    public static func icon(
        for action: BetterFinderMenuEntryAction,
        style: BetterFinderIconStyle
    ) -> NSImage? {
        guard style != .none else { return nil }

        switch action {
        case .copyPath:
            return symbol(style == .original ? "doc.on.clipboard.fill" : "doc.on.clipboard")
        case .open(let app):
            if style == .original,
               let bundleURL = BetterFinderApplicationCatalog.bundleURL(for: app) {
                let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
                icon.size = NSSize(width: 18, height: 18)
                return icon
            }
            let symbolName = app.type == .terminal ? "terminal" : "square.and.pencil"
            return symbol(symbolName)
        }
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        return image
    }
}
