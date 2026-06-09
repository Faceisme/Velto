import Foundation

public enum BetterFinderMenuKind: Sendable {
    case toolbar
    case contextMenu
}

public enum BetterFinderMenuEntryAction: Equatable, Sendable {
    case open(BetterFinderApp)
    case copyPath

    public var identifier: String {
        switch self {
        case .open(let app): "open:\(app.id)"
        case .copyPath: "copyPath"
        }
    }
}

public struct BetterFinderMenuEntry: Equatable, Sendable {
    public var title: String
    public var action: BetterFinderMenuEntryAction

    public var identifier: String {
        action.identifier
    }

    public init(title: String, action: BetterFinderMenuEntryAction) {
        self.title = title
        self.action = action
    }
}

public enum BetterFinderMenuBuilder {
    public static let copyPathTitle = "拷贝路径"

    public static func entries(
        for kind: BetterFinderMenuKind,
        preferences: BetterFinderPreferences
    ) -> [BetterFinderMenuEntry] {
        guard preferences.isEnabled else { return [] }
        if kind == .contextMenu, preferences.hidesContextMenuItems {
            return []
        }

        let useCustomMenu: Bool = switch kind {
        case .toolbar:
            preferences.appliesCustomMenuToToolbar
        case .contextMenu:
            preferences.appliesCustomMenuToContextMenu
        }

        var entries: [BetterFinderMenuEntry]
        if useCustomMenu {
            entries = []
            if kind == .toolbar {
                entries.append(
                    BetterFinderMenuEntry(
                        title: preferences.defaultTerminal.name,
                        action: .open(preferences.defaultTerminal)
                    )
                )
            }
            entries += preferences.customMenuApps
                .filter { app in
                    kind != .toolbar || app != preferences.defaultTerminal
                }
                .map {
                BetterFinderMenuEntry(title: $0.name, action: .open($0))
            }
        } else {
            entries = [
                BetterFinderMenuEntry(
                    title: preferences.defaultTerminal.name,
                    action: .open(preferences.defaultTerminal)
                ),
                BetterFinderMenuEntry(
                    title: preferences.defaultEditor.name,
                    action: .open(preferences.defaultEditor)
                )
            ]
        }

        entries.append(BetterFinderMenuEntry(title: copyPathTitle, action: .copyPath))
        return entries
    }
}
