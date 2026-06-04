import ApplicationServices
import Foundation

/// 浏览器当前页上下文。
struct BrowserPageContext: Equatable {
  var url: URL?
  var addressBarFocused: Bool
}

/// 在浏览器 app 的 AX 树里读 URL 与地址栏焦点。**必须在后台 AXCallQueue 调用。**
enum BrowserAXReader {
  /// DFS 深度上限 —— AX 树异常时防爆栈/卡死。
  private static let maxDepth = 60

  static func readContext(pid: pid_t, engine: BrowserEngine) -> BrowserPageContext {
    let app = AXUIElementCreateApplication(pid)
    guard let window = focusedWindow(of: app) else {
      return BrowserPageContext(url: nil, addressBarFocused: false)
    }
    let url = findWebAreaURL(in: window, depth: 0)
    let focused = isAddressBarFocused(app: app, engine: engine)
    return BrowserPageContext(url: url, addressBarFocused: focused)
  }

  // MARK: - URL

  private static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
    copyElement(app, kAXFocusedWindowAttribute)
  }

  /// DFS 找 role == AXWebArea,读它的 AXURL。
  private static func findWebAreaURL(in element: AXUIElement, depth: Int) -> URL? {
    if depth > maxDepth { return nil }
    if copyString(element, kAXRoleAttribute) == "AXWebArea" {
      if let url = copyURL(element, "AXURL"), !isIgnoredScheme(url) {
        return normalize(url)
      }
    }
    guard let children = copyChildren(element) else { return nil }
    for child in children {
      if let url = findWebAreaURL(in: child, depth: depth + 1) { return url }
    }
    return nil
  }

  private static func isIgnoredScheme(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return true }
    return scheme == "chrome-extension" || scheme == "moz-extension" || scheme == "safari-web-extension"
  }

  /// 去掉 fragment 规范化。取不到 host 的(如 newtab)原样返回。
  private static func normalize(_ url: URL) -> URL {
    guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
    comps.fragment = nil
    return comps.url ?? url
  }

  // MARK: - 地址栏焦点(脆弱点,见 spec §8)

  /// 判定焦点元素是否地址栏。这是已知脆弱区:靠 role/subrole + 每家浏览器的
  /// identifier 启发式。失效时退化为"不在地址栏",最坏是地址栏没切到默认,不会切错。
  private static func isAddressBarFocused(app: AXUIElement, engine: BrowserEngine) -> Bool {
    guard let focused = copyElement(app, kAXFocusedUIElementAttribute) else { return false }
    let role = copyString(focused, kAXRoleAttribute)
    guard role == "AXTextField" || role == "AXComboBox" else { return false }
    let identifier = copyString(focused, "AXIdentifier") ?? ""
    let desc = copyString(focused, kAXDescriptionAttribute) ?? ""
    switch engine {
    case .chromium:
      // Chromium 地址栏 AXIdentifier 常见 "address_and_search_bar" / desc 含地址栏文案。
      return identifier == "address_and_search_bar"
        || desc.localizedCaseInsensitiveContains("address")
        || desc.localizedCaseInsensitiveContains("地址")
    case .webkit:
      // Safari 地址栏:聚焦后焦点元素是顶层 AXTextField,且 value 常是 URL/搜索词。
      // 退化策略:顶层 AXTextField 即认为是地址栏。
      return true
    case .gecko:
      return identifier.localizedCaseInsensitiveContains("urlbar")
        || desc.localizedCaseInsensitiveContains("address")
        || desc.localizedCaseInsensitiveContains("地址")
    }
  }

  // MARK: - AX 原语

  private static func copyElement(_ element: AXUIElement, _ attr: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
          let v = value, CFGetTypeID(v) == AXUIElementGetTypeID()
    else { return nil }
    return (v as! AXUIElement)
  }

  private static func copyChildren(_ element: AXUIElement) -> [AXUIElement]? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
          let arr = value as? [AXUIElement]
    else { return nil }
    return arr
  }

  private static func copyString(_ element: AXUIElement, _ attr: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
          let s = value as? String
    else { return nil }
    return s
  }

  private static func copyURL(_ element: AXUIElement, _ attr: String) -> URL? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
          let v = value
    else { return nil }
    if let url = v as? URL { return url }
    if let s = v as? String { return URL(string: s) }
    return nil
  }
}
