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
    let app = AXClient.application(pid: pid)
    guard let window = AXClient.element(kAXFocusedWindowAttribute, of: app) else {
      return BrowserPageContext(url: nil, addressBarFocused: false)
    }
    let url = findWebAreaURL(in: window, depth: 0)
    let focused = isAddressBarFocused(app: app, engine: engine)
    return BrowserPageContext(url: url, addressBarFocused: focused)
  }

  // MARK: - URL

  /// DFS 找 role == AXWebArea,读它的 AXURL。
  private static func findWebAreaURL(in element: AXUIElement, depth: Int) -> URL? {
    if depth > maxDepth { return nil }
    if AXClient.role(of: element) == "AXWebArea" {
      if let url = AXClient.url("AXURL", of: element), !isIgnoredScheme(url) {
        return normalize(url)
      }
    }
    guard let children = AXClient.elements(kAXChildrenAttribute, of: element) else { return nil }
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
    guard let focused = AXClient.element(kAXFocusedUIElementAttribute, of: app) else { return false }
    let role = AXClient.role(of: focused)
    guard role == "AXTextField" || role == "AXComboBox" else { return false }
    let identifier = AXClient.string("AXIdentifier", of: focused) ?? ""
    let desc = AXClient.string(kAXDescriptionAttribute, of: focused) ?? ""
    switch engine {
    case .chromium:
      // Chromium 地址栏 AXIdentifier 常见 "address_and_search_bar" / desc 含地址栏文案。
      return identifier == "address_and_search_bar"
        || desc.localizedCaseInsensitiveContains("address")
        || desc.localizedCaseInsensitiveContains("地址")
    case .webkit:
      // Safari 地址栏在工具栏里,聚焦时焦点元素是 AXTextField。原退化策略"顶层
      // AXTextField 即地址栏"会把网页内的 <input> 误判成地址栏 → 在网页打字被强切。
      // 按 spec §8 的安全取向(失效时退化为"不在地址栏"),这里收紧为:仅当焦点
      // 文本框不在网页内容(AXWebArea)之内时才算地址栏 —— 地址栏的祖先链不含
      // AXWebArea,网页输入框则一定含。
      return !isInsideWebArea(focused)
    case .gecko:
      return identifier.localizedCaseInsensitiveContains("urlbar")
        || desc.localizedCaseInsensitiveContains("address")
        || desc.localizedCaseInsensitiveContains("地址")
    }
  }

  /// 焦点元素是否处于网页内容(AXWebArea)之内 —— 用于把"网页里的输入框"与
  /// "工具栏里的地址栏"区分开。沿 AXParent 向上走,带深度上限防 AX 树异常时卡死。
  private static func isInsideWebArea(_ element: AXUIElement) -> Bool {
    var current: AXUIElement? = element
    var depth = 0
    while let node = current, depth < maxDepth {
      if AXClient.role(of: node) == "AXWebArea" { return true }
      current = AXClient.element(kAXParentAttribute, of: node)
      depth += 1
    }
    return false
  }
}
