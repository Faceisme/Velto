import Foundation

public enum BetterFinderAppType: String, Codable, CaseIterable, Hashable, Sendable {
    case terminal
    case editor

    public var label: String {
        switch self {
        case .terminal: "终端"
        case .editor: "编辑器"
        }
    }
}

public struct BetterFinderShortcut: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifierFlags: UInt64
    public var displayName: String

    public init(keyCode: UInt16, modifierFlags: UInt64, displayName: String) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.displayName = displayName
    }
}

public struct BetterFinderApp: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var name: String
    public var path: String?
    public var bundleId: String?
    public var type: BetterFinderAppType

    public var id: String {
        "\(type.rawValue):\(bundleId ?? path ?? name)"
    }

    public init(
        name: String,
        type: BetterFinderAppType,
        path: String? = nil,
        bundleId: String? = nil
    ) {
        self.name = name
        self.type = type
        self.path = path
        self.bundleId = bundleId
    }

    public static func supported(_ app: BetterFinderSupportedApp) -> BetterFinderApp {
        app.app
    }
}

public enum BetterFinderIconStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case simple
    case original

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: "无"
        case .simple: "简单"
        case .original: "原始"
        }
    }
}

public enum BetterFinderQuickAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case openDefaultTerminal
    case openDefaultEditor
    case copyPathToClipboard

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .openDefaultTerminal: "打开默认终端"
        case .openDefaultEditor: "打开默认编辑器"
        case .copyPathToClipboard: "拷贝路径"
        }
    }
}

public struct BetterFinderPreferences: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var defaultTerminal: BetterFinderApp
    public var defaultEditor: BetterFinderApp
    public var customMenuApps: [BetterFinderApp]
    public var appliesCustomMenuToToolbar: Bool
    public var appliesCustomMenuToContextMenu: Bool
    public var hidesContextMenuItems: Bool
    public var iconStyle: BetterFinderIconStyle
    public var escapesCopiedPaths: Bool
    public var quickAction: BetterFinderQuickAction
    public var openTerminalShortcut: BetterFinderShortcut?
    public var openEditorShortcut: BetterFinderShortcut?
    public var copyPathShortcut: BetterFinderShortcut?
    public var debugLoggingEnabled: Bool

    public init(
        isEnabled: Bool,
        defaultTerminal: BetterFinderApp,
        defaultEditor: BetterFinderApp,
        customMenuApps: [BetterFinderApp],
        appliesCustomMenuToToolbar: Bool,
        appliesCustomMenuToContextMenu: Bool,
        hidesContextMenuItems: Bool,
        iconStyle: BetterFinderIconStyle,
        escapesCopiedPaths: Bool,
        quickAction: BetterFinderQuickAction,
        openTerminalShortcut: BetterFinderShortcut?,
        openEditorShortcut: BetterFinderShortcut?,
        copyPathShortcut: BetterFinderShortcut?,
        debugLoggingEnabled: Bool
    ) {
        self.isEnabled = isEnabled
        self.defaultTerminal = defaultTerminal
        self.defaultEditor = defaultEditor
        self.customMenuApps = customMenuApps
        self.appliesCustomMenuToToolbar = appliesCustomMenuToToolbar
        self.appliesCustomMenuToContextMenu = appliesCustomMenuToContextMenu
        self.hidesContextMenuItems = hidesContextMenuItems
        self.iconStyle = iconStyle
        self.escapesCopiedPaths = escapesCopiedPaths
        self.quickAction = quickAction
        self.openTerminalShortcut = openTerminalShortcut
        self.openEditorShortcut = openEditorShortcut
        self.copyPathShortcut = copyPathShortcut
        self.debugLoggingEnabled = debugLoggingEnabled
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled
        case defaultTerminal
        case defaultEditor
        case customMenuApps
        case appliesCustomMenuToToolbar
        case appliesCustomMenuToContextMenu
        case hidesContextMenuItems
        case iconStyle
        case escapesCopiedPaths
        case quickAction
        case openTerminalShortcut
        case openEditorShortcut
        case copyPathShortcut
        case debugLoggingEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaults
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        defaultTerminal = try container.decodeIfPresent(BetterFinderApp.self, forKey: .defaultTerminal) ?? defaults.defaultTerminal
        defaultEditor = try container.decodeIfPresent(BetterFinderApp.self, forKey: .defaultEditor) ?? defaults.defaultEditor
        customMenuApps = try container.decodeIfPresent([BetterFinderApp].self, forKey: .customMenuApps) ?? defaults.customMenuApps
        appliesCustomMenuToToolbar = try container.decodeIfPresent(Bool.self, forKey: .appliesCustomMenuToToolbar) ?? defaults.appliesCustomMenuToToolbar
        appliesCustomMenuToContextMenu = try container.decodeIfPresent(Bool.self, forKey: .appliesCustomMenuToContextMenu) ?? defaults.appliesCustomMenuToContextMenu
        hidesContextMenuItems = try container.decodeIfPresent(Bool.self, forKey: .hidesContextMenuItems) ?? defaults.hidesContextMenuItems
        iconStyle = try container.decodeIfPresent(BetterFinderIconStyle.self, forKey: .iconStyle) ?? defaults.iconStyle
        escapesCopiedPaths = try container.decodeIfPresent(Bool.self, forKey: .escapesCopiedPaths) ?? defaults.escapesCopiedPaths
        quickAction = try container.decodeIfPresent(BetterFinderQuickAction.self, forKey: .quickAction) ?? defaults.quickAction
        openTerminalShortcut = try Self.decodeOptionalShortcut(
            from: container,
            forKey: .openTerminalShortcut,
            defaultValue: defaults.openTerminalShortcut
        )
        openEditorShortcut = try Self.decodeOptionalShortcut(
            from: container,
            forKey: .openEditorShortcut,
            defaultValue: defaults.openEditorShortcut
        )
        copyPathShortcut = try Self.decodeOptionalShortcut(
            from: container,
            forKey: .copyPathShortcut,
            defaultValue: defaults.copyPathShortcut
        )
        debugLoggingEnabled = try container.decodeIfPresent(Bool.self, forKey: .debugLoggingEnabled) ?? defaults.debugLoggingEnabled
    }

    private static func decodeOptionalShortcut(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        defaultValue: BetterFinderShortcut?
    ) throws -> BetterFinderShortcut? {
        guard container.contains(key) else { return defaultValue }
        return try container.decodeIfPresent(BetterFinderShortcut.self, forKey: key)
    }

    public static let defaults = BetterFinderPreferences(
        isEnabled: true,
        defaultTerminal: BetterFinderSupportedApp.terminal.app,
        defaultEditor: BetterFinderSupportedApp.textEdit.app,
        customMenuApps: [],
        appliesCustomMenuToToolbar: false,
        appliesCustomMenuToContextMenu: false,
        hidesContextMenuItems: false,
        iconStyle: .none,
        escapesCopiedPaths: true,
        quickAction: .openDefaultTerminal,
        openTerminalShortcut: nil,
        openEditorShortcut: BetterFinderShortcut(
            keyCode: 1,
            modifierFlags: 0x0010_0000 | 0x0002_0000,
            displayName: "⇧⌘S"
        ),
        copyPathShortcut: BetterFinderShortcut(
            keyCode: 8,
            modifierFlags: 0x0010_0000 | 0x0002_0000,
            displayName: "⇧⌘C"
        ),
        debugLoggingEnabled: false
    )
}
