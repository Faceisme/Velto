import AppKit
import Foundation

/// 浏览器内核家族 —— 影响地址栏焦点的判定方式(Task 6 用)。
enum BrowserEngine {
  case webkit     // Safari 系
  case chromium   // Chrome/Edge/Brave/Arc/Vivaldi/Opera/Thorium/Dia
  case gecko      // Firefox 系
}

/// 一个受支持的浏览器。
struct SupportedBrowser: Identifiable, Equatable {
  var bundleID: String
  var displayName: String
  var engine: BrowserEngine
  var id: String { bundleID }

  /// 本机是否已安装。
  var isInstalled: Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
  }
}

enum SupportedBrowserCatalog {
  /// v1 支持列表(bundle id 来自 spec §8)。
  static let all: [SupportedBrowser] = [
    .init(bundleID: "com.apple.Safari", displayName: "Safari", engine: .webkit),
    .init(bundleID: "com.apple.SafariTechnologyPreview", displayName: "Safari Technology Preview", engine: .webkit),
    .init(bundleID: "com.google.Chrome", displayName: "Google Chrome", engine: .chromium),
    .init(bundleID: "org.chromium.Chromium", displayName: "Chromium", engine: .chromium),
    .init(bundleID: "company.thebrowser.Browser", displayName: "Arc", engine: .chromium),
    .init(bundleID: "company.thebrowser.dia", displayName: "Dia", engine: .chromium),
    .init(bundleID: "com.microsoft.edgemac", displayName: "Microsoft Edge", engine: .chromium),
    .init(bundleID: "com.brave.Browser", displayName: "Brave", engine: .chromium),
    .init(bundleID: "com.brave.Browser.beta", displayName: "Brave Beta", engine: .chromium),
    .init(bundleID: "com.brave.Browser.nightly", displayName: "Brave Nightly", engine: .chromium),
    .init(bundleID: "com.vivaldi.Vivaldi", displayName: "Vivaldi", engine: .chromium),
    .init(bundleID: "com.operasoftware.Opera", displayName: "Opera", engine: .chromium),
    .init(bundleID: "org.chromium.Thorium", displayName: "Thorium", engine: .chromium),
    .init(bundleID: "org.mozilla.firefox", displayName: "Firefox", engine: .gecko),
    .init(bundleID: "org.mozilla.firefoxdeveloperedition", displayName: "Firefox Developer Edition", engine: .gecko),
    .init(bundleID: "org.mozilla.nightly", displayName: "Firefox Nightly", engine: .gecko),
    .init(bundleID: "app.zen-browser.zen", displayName: "Zen", engine: .gecko),  // Zen 是 Firefox 内核
  ]

  static func browser(forBundleID id: String?) -> SupportedBrowser? {
    guard let id else { return nil }
    return all.first { $0.bundleID == id }
  }

  static func isSupportedBrowser(_ id: String?) -> Bool {
    browser(forBundleID: id) != nil
  }

  /// 本机已安装的受支持浏览器。
  static func installed() -> [SupportedBrowser] {
    all.filter { $0.isInstalled }
  }
}
