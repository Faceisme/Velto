import AppKit
import Foundation

public enum BetterFinderSupportedApp: String, CaseIterable, Codable, Hashable, Sendable {
    case terminal = "Terminal"
    case iTerm = "iTerm"
    case hyper = "Hyper"
    case alacritty = "Alacritty"
    case kitty = "kitty"
    case wezterm = "WezTerm"
    case tabby = "Tabby"
    case warp = "Warp"
    case githubDesktop = "GitHub Desktop"
    case fork = "Fork"
    case ghostty = "Ghostty"

    case textEdit = "TextEdit"
    case xcode = "Xcode"
    case visualStudioCode = "Visual Studio Code"
    case atom = "Atom"
    case sublimeText = "Sublime Text"
    case vscodium = "VSCodium"
    case bbedit = "BBEdit"
    case visualStudioCodeInsiders = "Visual Studio Code - Insiders"
    case textMate = "TextMate"
    case cotEditor = "CotEditor"
    case macVim = "MacVim"
    case typora = "Typora"
    case nova = "Nova"
    case cursor = "Cursor"
    case neovim = "neovim"
    case appCode = "AppCode"
    case cLion = "CLion"
    case fleet = "Fleet"
    case goLand = "GoLand"
    case intelliJIDEA = "IntelliJ IDEA"
    case phpStorm = "PhpStorm"
    case pyCharm = "PyCharm"
    case rubyMine = "RubyMine"
    case webStorm = "WebStorm"
    case androidStudio = "Android Studio"

    public var name: String { rawValue }

    public var type: BetterFinderAppType {
        switch self {
        case .terminal, .iTerm, .hyper, .alacritty, .kitty, .wezterm, .tabby, .warp, .githubDesktop, .fork, .ghostty:
            .terminal
        default:
            .editor
        }
    }

    public var bundleId: String? {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iTerm: "com.googlecode.iterm2"
        case .hyper: "co.zeit.hyper"
        case .alacritty: "io.alacritty"
        case .kitty: "net.kovidgoyal.kitty"
        case .wezterm: "com.github.wez.wezterm"
        case .tabby: "org.tabby"
        case .warp: "dev.warp"
        case .githubDesktop: nil
        case .fork: nil
        case .ghostty: "com.mitchellh.ghostty"
        case .textEdit: "com.apple.TextEdit"
        case .xcode: "com.apple.Xcode"
        case .visualStudioCode: "com.microsoft.VSCode"
        case .atom: "com.github.atom"
        case .sublimeText: "com.sublimetext.3"
        case .vscodium: "com.visualstudio.code.oss"
        case .bbedit: "com.barebones.bbedit"
        case .visualStudioCodeInsiders: "com.microsoft.VSCodeInsiders"
        case .textMate: "com.macromates.TextMate"
        case .cotEditor: nil
        case .macVim: "org.vim.MacVim"
        case .typora: "abnerworks.Typora"
        case .nova: "com.panic.Nova"
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .neovim: nil
        case .appCode: "com.jetbrains.appcode"
        case .cLion: "com.jetbrains.clion"
        case .fleet: "com.jetbrains.fleet"
        case .goLand: "com.jetbrains.goland"
        case .intelliJIDEA: "com.jetbrains.intellij"
        case .phpStorm: "com.jetbrains.PhpStorm"
        case .pyCharm: "com.jetbrains.pycharm"
        case .rubyMine: "com.jetbrains.rubymine"
        case .webStorm: "com.jetbrains.webstorm"
        case .androidStudio: nil
        }
    }

    public var app: BetterFinderApp {
        BetterFinderApp(name: name, type: type, bundleId: bundleId)
    }

    public static var terminals: [BetterFinderSupportedApp] {
        allCases.filter { $0.type == .terminal }
    }

    public static var editors: [BetterFinderSupportedApp] {
        allCases.filter { $0.type == .editor }
    }

    public static func from(app: BetterFinderApp) -> BetterFinderSupportedApp? {
        allCases.first { $0.name == app.name }
    }
}

public enum BetterFinderApplicationCatalog {
    public static func installedApplicationNames() -> Set<String> {
        var applications: Set<String> = ["Terminal", "TextEdit", "neovim"]
        let fileManager = FileManager.default
        var searchDirs = initialSearchDirectories(fileManager: fileManager)
        var visited = Set<URL>()
        var depth = 0

        while !searchDirs.isEmpty, depth < 20 {
            depth += 1
            let currentDirs = searchDirs
            searchDirs.removeAll()

            for dir in currentDirs where !visited.contains(dir) {
                visited.insert(dir)
                guard let children = try? fileManager.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.isDirectoryKey, .isAliasFileKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continue
                }

                for child in children {
                    if child.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                        applications.insert(normalizedApplicationName(from: child))
                        continue
                    }

                    guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                        continue
                    }
                    if shouldDescend(into: child, fileManager: fileManager) {
                        searchDirs.insert(resolvedDirectoryURL(child, fileManager: fileManager))
                    }
                }
            }
        }

        return applications
    }

    public static func installedSupportedApps(type: BetterFinderAppType? = nil) -> [BetterFinderApp] {
        let installed = installedApplicationNames()
        return BetterFinderSupportedApp.allCases
            .filter { type == nil || $0.type == type }
            .filter { installed.contains($0.name) }
            .map(\.app)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func allSupportedApps(type: BetterFinderAppType? = nil) -> [BetterFinderApp] {
        BetterFinderSupportedApp.allCases
            .filter { type == nil || $0.type == type }
            .map(\.app)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func bundleURL(for app: BetterFinderApp) -> URL? {
        if let path = app.path, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let bundleId = app.bundleId,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return url
        }
        for base in ["/Applications", "\(NSHomeDirectory())/Applications"] {
            let url = URL(fileURLWithPath: base).appendingPathComponent(app.name).appendingPathExtension("app")
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    public static func displayName(forApplicationAt url: URL) -> String {
        if let bundle = Bundle(url: url) {
            let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            return display ?? name ?? fileNameWithoutAppExtension(url)
        }
        return fileNameWithoutAppExtension(url)
    }

    private static func initialSearchDirectories(fileManager: FileManager) -> Set<URL> {
        var result: Set<URL> = [URL(fileURLWithPath: "/Applications")]
        if let userApplications = fileManager.urls(for: .applicationDirectory, in: .userDomainMask).first {
            result.insert(userApplications)
        }
        if let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let toolbox = library
                .appendingPathComponent("Application Support")
                .appendingPathComponent("JetBrains")
                .appendingPathComponent("Toolbox")
            if fileManager.fileExists(atPath: toolbox.path) {
                result.insert(toolbox)
            }
        }
        return result
    }

    private static func normalizedApplicationName(from url: URL) -> String {
        let name = fileNameWithoutAppExtension(url)
        switch name {
        case "iTerm2":
            return "iTerm"
        case "IntelliJ IDEA CE":
            return "IntelliJ IDEA"
        case "PyCharm CE":
            return "PyCharm"
        default:
            return name
        }
    }

    private static func fileNameWithoutAppExtension(_ url: URL) -> String {
        var name = FileManager.default.displayName(atPath: url.path).removingPercentEncoding ?? url.deletingPathExtension().lastPathComponent
        if name.lowercased().hasSuffix(".app") {
            name.removeLast(4)
        }
        return name
    }

    private static func shouldDescend(into url: URL, fileManager: FileManager) -> Bool {
        let isAlias = (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) ?? false
        if isAlias, url.lastPathComponent != "Nix Apps" {
            return false
        }
        return true
    }

    private static func resolvedDirectoryURL(_ url: URL, fileManager: FileManager) -> URL {
        guard url.lastPathComponent == "Nix Apps",
              let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return url
        }
        return URL(fileURLWithPath: destination)
    }
}
