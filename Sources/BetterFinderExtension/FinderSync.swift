import Cocoa
import FinderSync
import UniformTypeIdentifiers
import betterfinder

final class FinderSync: FIFinderSync {
    private let store = BetterFinderPreferencesStore.shared

    override init() {
        super.init()
        let controller = FIFinderSyncController.default()
        if let mountedVolumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) {
            controller.directoryURLs = Set(mountedVolumes)
            BetterFinderDebugLog.log("extension init mountedVolumes=\(mountedVolumes.count)")
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                FIFinderSyncController.default().directoryURLs.insert(volumeURL)
                BetterFinderDebugLog.log("volume mounted url=\(volumeURL.path)")
            }
        }

        // 扩展进程会被系统频繁回收再拉起,内存图标缓存随之丢失;启动即后台预热
        // 两种菜单的全部图标,首次开菜单不再现场查 LaunchServices。
        let store = self.store
        DispatchQueue.global(qos: .utility).async {
            let preferences = store.preferences
            let actions = (
                BetterFinderMenuBuilder.entries(for: .toolbar, preferences: preferences)
                    + BetterFinderMenuBuilder.entries(for: .contextMenu, preferences: preferences)
            ).map(\.action)
            BetterFinderIconProvider.warmUp(actions: actions, style: preferences.iconStyle)
        }
    }

    override var toolbarItemName: String {
        "增强Finder"
    }

    override var toolbarItemToolTip: String {
        "打开当前路径到终端、编辑器或拷贝路径。"
    }

    override var toolbarItemImage: NSImage {
        if let image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "增强Finder") {
            image.isTemplate = true
            return image
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let kind: BetterFinderMenuKind
        switch menuKind {
        case .toolbarItemMenu:
            kind = .toolbar
        case .contextualMenuForContainer, .contextualMenuForItems:
            kind = .contextMenu
        default:
            BetterFinderDebugLog.log("menu ignored kind=\(String(describing: menuKind))")
            return NSMenu()
        }

        let preferences = store.preferences
        let entries = BetterFinderMenuBuilder.entries(for: kind, preferences: preferences)
        BetterFinderDebugLog.log(
            "menu kind=\(kind.debugName) enabled=\(preferences.isEnabled) toolbarCustom=\(preferences.appliesCustomMenuToToolbar) contextCustom=\(preferences.appliesCustomMenuToContextMenu) hiddenContext=\(preferences.hidesContextMenuItems) entries=\(entries.map(\.title).joined(separator: ","))"
        )
        let menu = NSMenu(title: "")
        for entry in entries {
            let item = NSMenuItem(title: entry.title, action: #selector(handleMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.identifier = NSUserInterfaceItemIdentifier(entry.identifier)
            item.representedObject = BetterFinderMenuPayload(entry: entry)
            item.image = BetterFinderIconProvider.menuIcon(for: entry.action, style: preferences.iconStyle)
            menu.addItem(item)
        }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        BetterFinderDebugLog.log(String(format: "menu build finished kind=%@ elapsedMs=%.1f", kind.debugName, elapsedMs))
        return menu
    }

    @objc private func handleMenuItem(_ sender: NSMenuItem) {
        guard let entry = resolvedEntry(for: sender) else {
            BetterFinderDebugLog.log("menu click ignored reason=unresolved-entry title=\(sender.title) identifier=\(sender.identifier?.rawValue ?? "-") representedObject=\(String(describing: sender.representedObject))")
            return
        }
        do {
            let urls = selectedURLs()
            let request = BetterFinderActionRequest(
                action: entry.action,
                urls: urls,
                preferences: store.preferences
            )
            BetterFinderDebugLog.log("menu click title=\(entry.title) identifier=\(entry.identifier) action=\(entry.action.debugName) urls=\(request.urlPaths.joined(separator: ","))")
            NSLog("BetterFinder menu clicked: %@ %@", entry.title, request.urlPaths.joined(separator: ","))
            try BetterFinderActionBridge.post(request)
            BetterFinderDebugLog.log("menu click posted title=\(entry.title)")
        } catch {
            BetterFinderDebugLog.log("menu click failed title=\(entry.title) error=\(error.localizedDescription)")
            NSLog("BetterFinder bridge failed: %@", error.localizedDescription)
        }
    }

    private func resolvedEntry(for sender: NSMenuItem) -> BetterFinderMenuEntry? {
        if let payload = sender.representedObject as? BetterFinderMenuPayload {
            BetterFinderDebugLog.log("menu resolve source=representedObject title=\(sender.title)")
            return payload.entry
        }

        let preferences = store.preferences
        let entries = [
            BetterFinderMenuBuilder.entries(for: .toolbar, preferences: preferences),
            BetterFinderMenuBuilder.entries(for: .contextMenu, preferences: preferences)
        ].flatMap { $0 }
        if let identifier = sender.identifier?.rawValue,
           let entry = entries.first(where: { $0.identifier == identifier }) {
            BetterFinderDebugLog.log("menu resolve source=identifier title=\(sender.title) identifier=\(identifier)")
            return entry
        }
        if let entry = entries.first(where: { $0.title == sender.title }) {
            BetterFinderDebugLog.log("menu resolve source=title title=\(sender.title)")
            return entry
        }
        return nil
    }

    private func selectedURLs() -> [URL] {
        let controller = FIFinderSyncController.default()
        if let urls = controller.selectedItemURLs(), !urls.isEmpty {
            BetterFinderDebugLog.log("selectedURLs source=selected count=\(urls.count) paths=\(urls.map(\.path).joined(separator: ","))")
            return urls
        }
        if let url = controller.targetedURL() {
            BetterFinderDebugLog.log("selectedURLs source=targeted path=\(url.path)")
            return [url]
        }
        BetterFinderDebugLog.log("selectedURLs source=empty")
        return []
    }
}

private final class BetterFinderMenuPayload: NSObject {
    let entry: BetterFinderMenuEntry

    init(entry: BetterFinderMenuEntry) {
        self.entry = entry
    }
}

private extension BetterFinderMenuKind {
    var debugName: String {
        switch self {
        case .toolbar: "toolbar"
        case .contextMenu: "contextMenu"
        }
    }
}

private extension BetterFinderMenuEntryAction {
    var debugName: String {
        switch self {
        case .open(let app): "open:\(app.name)"
        case .copyPath: "copyPath"
        }
    }
}
