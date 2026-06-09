import AppKit
import Foundation

public enum BetterFinderActionError: LocalizedError {
    case cannotAccessFinder(String)
    case cannotLaunch(String)

    public var errorDescription: String? {
        switch self {
        case .cannotAccessFinder(let message):
            "无法读取 Finder 当前路径:\(message)"
        case .cannotLaunch(let message):
            "无法启动应用:\(message)"
        }
    }
}

public enum BetterFinderActionRunner {
    public static func perform(_ request: BetterFinderActionRequest) throws {
        BetterFinderDebugLog.log("runner perform kind=\(request.kind.rawValue) app=\(request.app?.name ?? "-") urls=\(request.urlPaths.joined(separator: ","))")
        switch request.kind {
        case .open:
            guard let app = request.app else {
                BetterFinderDebugLog.log("runner failed reason=missing-app")
                throw BetterFinderActionError.cannotLaunch("缺少目标应用")
            }
            try open(app, urls: request.urls)
        case .copyPath:
            copyPathToClipboard(
                urls: request.urls,
                escapesPaths: request.escapesCopiedPaths
            )
        }
    }

    public static func perform(
        _ action: BetterFinderMenuEntryAction,
        urls: [URL],
        preferences: BetterFinderPreferences
    ) throws {
        BetterFinderDebugLog.log("runner perform action=\(action.debugName) urls=\(urls.map(\.path).joined(separator: ","))")
        switch action {
        case .open(let app):
            try open(app, urls: urls)
        case .copyPath:
            copyPathToClipboard(urls: urls, escapesPaths: preferences.escapesCopiedPaths)
        }
    }

    public static func performQuickAction(
        _ action: BetterFinderQuickAction,
        preferences: BetterFinderPreferences
    ) throws {
        BetterFinderDebugLog.log("quickAction start action=\(action.rawValue)")
        let urls = try finderSelectionOrFrontWindowURLs()
        BetterFinderDebugLog.log("quickAction urls=\(urls.map(\.path).joined(separator: ","))")
        switch action {
        case .openDefaultTerminal:
            try open(preferences.defaultTerminal, urls: urls)
        case .openDefaultEditor:
            try open(preferences.defaultEditor, urls: urls)
        case .copyPathToClipboard:
            copyPathToClipboard(urls: urls, escapesPaths: preferences.escapesCopiedPaths)
        }
    }

    public static func open(_ app: BetterFinderApp, urls: [URL]) throws {
        let effectiveURLs = urls.isEmpty ? [desktopURL()] : urls
        let arguments = launchArguments(for: app, urls: effectiveURLs)
        BetterFinderDebugLog.log("open start app=\(app.name) type=\(app.type.rawValue) urls=\(effectiveURLs.map(\.path).joined(separator: ",")) args=\(arguments.joined(separator: " "))")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        do {
            try process.run()
            BetterFinderDebugLog.log("open launched app=\(app.name) pid=\(process.processIdentifier)")
        } catch {
            BetterFinderDebugLog.log("open failed app=\(app.name) error=\(error.localizedDescription)")
            throw BetterFinderActionError.cannotLaunch("\(app.name): \(error.localizedDescription)")
        }
    }

    public static func copyPathToClipboard(urls: [URL], escapesPaths: Bool) {
        let effectiveURLs = urls.isEmpty ? [desktopURL()] : urls
        var paths = effectiveURLs.map(\.path)
        if escapesPaths {
            paths = paths.map { $0.betterFinderShellEscaped() }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        BetterFinderDebugLog.log("copyPath paths=\(paths.joined(separator: ",")) escaped=\(escapesPaths)")
    }

    public static func finderSelectionOrFrontWindowURLs() throws -> [URL] {
        BetterFinderDebugLog.log("finderAppleScript start")
        let source = """
        tell application "Finder"
            set pathList to {}
            set finderSelList to selection as alias list

            if finderSelList is not {} then
                repeat with theSelected in finderSelList
                    set end of pathList to POSIX path of (contents of theSelected)
                end repeat
            else
                try
                    set end of pathList to POSIX path of ((target of front Finder window) as alias)
                on error
                    set end of pathList to POSIX path of (path to desktop)
                end try
            end if

            return pathList
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            throw BetterFinderActionError.cannotAccessFinder("AppleScript 创建失败")
        }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            BetterFinderDebugLog.log("finderAppleScript failed error=\(error)")
            throw BetterFinderActionError.cannotAccessFinder("\(error)")
        }

        var urls: [URL] = []
        guard result.numberOfItems > 0 else { return [] }
        for index in 1...result.numberOfItems {
            guard let path = result.atIndex(index)?.stringValue, !path.isEmpty else {
                continue
            }
            urls.append(URL(fileURLWithPath: path))
        }
        BetterFinderDebugLog.log("finderAppleScript ok count=\(urls.count) paths=\(urls.map(\.path).joined(separator: ","))")
        return urls
    }

    private static func launchArguments(for app: BetterFinderApp, urls: [URL]) -> [String] {
        if let supported = BetterFinderSupportedApp.from(app: app) {
            switch supported {
            case .alacritty:
                return ["-na", "Alacritty", "--args", "--working-directory", terminalPath(from: urls)]
            case .kitty:
                return ["-na", "kitty", "--args", "--single-instance", "--instance-group", "1", "--directory", terminalPath(from: urls)]
            case .wezterm:
                return ["-na", "wezterm", "--args", "start", "--cwd", terminalPath(from: urls)]
            case .tabby:
                return ["-na", "tabby", "--args", "--directory", terminalPath(from: urls)]
            case .neovim:
                return ["-na", "kitty", "--args", "/opt/homebrew/bin/nvim"] + urls.map(\.path)
            default:
                break
            }
        }

        var arguments: [String]
        if let bundleId = app.bundleId, !bundleId.isEmpty {
            arguments = ["-b", bundleId]
        } else if let path = app.path, !path.isEmpty {
            arguments = ["-a", path]
        } else {
            arguments = ["-a", app.name]
        }

        switch app.type {
        case .terminal:
            arguments.append(terminalPath(from: urls))
        case .editor:
            arguments.append(contentsOf: urls.map(\.path))
        }
        return arguments
    }

    private static func terminalPath(from urls: [URL]) -> String {
        (urls.first ?? desktopURL()).betterFinderDirectoryURLForTerminal().path
    }

    private static func desktopURL() -> URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
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
