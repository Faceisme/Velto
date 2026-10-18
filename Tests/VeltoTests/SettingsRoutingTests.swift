import Foundation
import Testing

@Test func settingsRootUsesSinglePageHost() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent("Sources/Velto/SettingsRootView.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(source.contains("SettingsPageHost(page: current)"))
    #expect(source.contains("case .betterFinder"))
    #expect(source.contains("AnyView(BetterFinderPage())"))
    #expect(!source.contains("pageContent(.gestures"))
    #expect(!source.contains("pageContent(.inputSourceSwitch"))
}

@Test func inputSourcePageCachesSystemCatalogsAndIcons() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent("Sources/Velto/InputSourceSwitch/InputSourceSwitchPage.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(source.contains("@State private var sources = InputSourceCatalog.all()"))
    #expect(source.contains("@State private var installedBrowsers = SupportedBrowserCatalog.installed()"))
    // App 行(BundleAppRow)已挪到公共组件,和窗口管理例外 App 共用;图标仍缓存在 @State 里。
    #expect(source.contains("BundleAppRow(bundleID:"))
    let components = try String(
        contentsOf: root.appendingPathComponent("Sources/Velto/Components.swift"), encoding: .utf8)
    #expect(components.contains("struct BundleAppRow"))
    #expect(components.contains("@State private var icon: NSImage?"))
    #expect(!source.contains("private var sources: [InputSourceInfo] { InputSourceCatalog.all() }"))
    #expect(!source.contains("let installed = SupportedBrowserCatalog.installed()"))
}
